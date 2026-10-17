// Device.swift — M102b2 (issue #2163): the host device core for the
// experimental custom-Virtio 3D render device (ID 0x43 / PCI 1af4:1083).
// It validates every guest request against the frozen VIR1 profile,
// owns the two-context lifecycle with generation-safe reset, defers
// fenced completions, and forwards render work to an injected
// GPU3DBackend — which is nil until c2's Metal renderer lands.
//
// Concurrency: every entry point runs on the device's single serial
// queue (the provider's deviceQueue, exactly like the existing
// custom-virtio spike). Tests drive the core through the GPU3DQueue
// seam; no lock is taken anywhere.
//
// The Virtualization.framework glue at the bottom compiles only under
// -DSPIKE (the macOS 27 SDK types don't exist on the CI toolchain's
// macOS 26 SDK — same gate as VMRunner/main.swift). Plain `swift test`
// exercises the entire device contract through the seam below.

import Foundation

/// One dequeued virtqueue element, abstracted so host tests inject fakes
/// and the SPIKE build adapts VZVirtioQueueElement 1:1. The device reads
/// the request bytes ONCE (guest memory is untrusted — re-reading is a
/// TOCTOU bug), writes the response, then returns the element.
public protocol GPU3DQueueElement: AnyObject {
    /// Total request bytes available to read.
    var gpu3dReadByteCount: Int { get }
    /// Total response bytes the element can accept.
    var gpu3dWriteByteCount: Int { get }
    /// Consume every read buffer and return the request bytes.
    func gpu3dReadAll() -> [UInt8]
    /// Write the response. Returns false when it would not fit.
    func gpu3dWrite(_ bytes: [UInt8]) -> Bool
    /// Return the element to the guest (advances the used ring, asserts
    /// the device interrupt). Called exactly once per dequeued element.
    func gpu3dReturn()
}

/// One virtqueue, abstracted the same way.
public protocol GPU3DQueue {
    var gpu3dQueueIndex: Int { get }
    /// nil when no more elements are available.
    func gpu3dNextElement() -> GPU3DQueueElement?
}

/// The render-device core: wire validation + two-generation-safe
/// contexts + deferred fenced completion, all backend-agnostic.
public final class GPU3DDevice {
    /// A live render context. `generation` rises every time a ctx_id is
    /// created, so a delayed completion for a retired generation can
    /// never be applied to a recycled ID (#2160 item 4).
    public struct Context {
        public let id: UInt32
        public let generation: UInt64
        public internal(set) var resources: [UInt32: GPU3DWire.ResourceCreate] = [:]
        public internal(set) var attached: Set<UInt32> = []
    }

    /// A deferred device request: the guest's element is held until the
    /// fence completes. At most ONE is ever outstanding (#2160 item 3).
    struct Pending {
        let header: GPU3DWire.Header
        let ctxID: UInt32
        let generation: UInt64
        let element: GPU3DQueueElement
    }

    /// The injected renderer. Nil means the honest null backend:
    /// ready=0 is advertised and all render work refuses.
    public var backend: GPU3DBackend?

    /// Diagnostics for host tests and gates — observed, not inferred.
    public private(set) var lastRefusal: GPU3DRefusal?
    public private(set) var refusalCount = 0
    /// Fence completions that matched no outstanding request.
    public private(set) var staleCompletions = 0
    /// Held elements retired early by CTX_DESTROY or device reset.
    public private(set) var retiredPending = 0
    public private(set) var resetCount = 0

    public private(set) var contexts: [UInt32: Context] = [:]
    /// ctx_id → next generation counter. Survives destroy AND reset, so
    /// generations only ever increase within a device instance.
    private var nextGeneration: [UInt32: UInt64] = [:]
    private var pending: Pending?

    public init(backend: GPU3DBackend? = nil) {
        self.backend = backend
    }

    public var pendingFenceID: UInt64? { pending?.header.fenceID }
    public var liveContextIDs: [UInt32] { contexts.keys.sorted() }
    public func generation(of ctxID: UInt32) -> UInt64? { contexts[ctxID]?.generation }

    /// The serial queue the device runs on — set by the host shell to
    /// the queue the virtio provider was created with. While a deferred
    /// element holds its fence the device re-polls the backend here on
    /// a timer: a Metal completion lands between guest notifications,
    /// and the guest may not ring the doorbell again until its fence
    /// wait times out (#2223). MUST be the same serial queue that
    /// drives every other entry point — the pump takes no lock.
    public var completionQueue: DispatchQueue?

    /// Re-poll cadence while a deferred element's fence is in flight.
    static let fencePumpInterval: DispatchTimeInterval = .milliseconds(5)

    private var pumpArmed = false

    /// Drain any completed backend fences without a queue notification —
    /// a deferred element's completion lands between guest posts.
    public func pumpFences() {
        for fence in backend?.gpu3dPoll() ?? [] {
            noteFenceCompleted(fence)
        }
    }

    /// Arm the fence pump: while `pending` is set, poll the backend on
    /// `completionQueue` every `fencePumpInterval`. At most one tick is
    /// ever scheduled; each tick re-arms only if a fence is still held,
    /// so the pump stops itself on completion, retirement or reset.
    private func armFencePump() {
        guard !pumpArmed, pending != nil, let queue = completionQueue else { return }
        pumpArmed = true
        queue.asyncAfter(deadline: .now() + Self.fencePumpInterval) { [weak self] in
            guard let self else { return }
            self.pumpArmed = false
            self.pumpFences()
            self.armFencePump()
        }
    }

    // MARK: - Queue drain

    /// Service every element on the queue until it is empty — the same
    /// drain discipline as the existing custom-virtio delegate.
    public func handleQueueNotification(_ queue: GPU3DQueue) {
        // Poll the backend first: a fence that finished since the last
        // batch retires the held element before new work is examined.
        pumpFences()
        while let element = queue.gpu3dNextElement() {
            serve(element)
        }
    }

    private func serve(_ element: GPU3DQueueElement) {
        let bytes = element.gpu3dReadAll()
        let request: GPU3DWire.Request
        switch GPU3DWire.decode(bytes) {
        case .failure(let refusal):
            // Echo whatever header fields decoded — a malformed request
            // still gets a matched error response, never silence.
            refuse(element, refusal, request: GPU3DWire.peekHeader(bytes))
            return
        case .success(let req):
            request = req
        }
        switch dispatch(request) {
        case .reply(let type, let payload):
            answer(element, type: type, request: request.header, payload: payload)
            element.gpu3dReturn()
        case .refuse(let refusal):
            refuse(element, refusal, request: request.header)
        case .deferred:
            // The element is HELD, not returned; the response is written
            // when the backend reports this request's fence complete.
            pending = Pending(header: request.header, ctxID: request.header.ctxID,
                              generation: contexts[request.header.ctxID]?.generation ?? 0,
                              element: element)
            armFencePump()
        }
    }

    /// The per-command decision. `.deferred` is only produced after the
    /// busy/fence checks below, so `serve` can safely stash the element.
    private enum Outcome {
        case reply(type: UInt32, payload: [UInt8])
        case refuse(GPU3DRefusal)
        case deferred
    }

    private func dispatch(_ req: GPU3DWire.Request) -> Outcome {
        let W = GPU3DWire.self
        let ctxID = req.header.ctxID
        switch req.command {
        case .getCapsetInfo(let index):
            switch index {
            case W.capsetIndex:
                return .reply(type: W.respOkCapsetInfo, payload: W.capsetInfoPayload())
            case W.vic1Index:
                // M111 (ADR 0053 D1): index 1 is answered only when a
                // backend is attached — a backend-less device advertises
                // num_capsets=1 and this probe is the refusal.
                guard backend != nil else { return .refuse(.invalidCapset) }
                return .reply(type: W.respOkCapsetInfo,
                              payload: W.capsetInfoPayload(capsetID: W.capsetVIC1,
                                                           version: W.vic1Version,
                                                           size: W.vic1PayloadSize))
            default:
                return .refuse(.invalidCapset)
            }

        case .getCapset(let id, let version):
            if id == W.capsetVIC1 {
                guard backend != nil, version == W.vic1Version else {
                    return .refuse(.invalidCapset)
                }
                return .reply(type: W.respOkCapset,
                              payload: W.vic1CapsetPayload(ready: backend?.gpu3dComputeReady ?? false))
            }
            guard id == W.capsetID, version == W.capsetVersion else {
                return .refuse(.invalidCapset)
            }
            return .reply(type: W.respOkCapset,
                          payload: W.capsetPayload(ready: backend?.gpu3dReady ?? false))

        case .ctxCreate(let spec):
            guard ctxID != 0, contexts[ctxID] == nil else {
                return .refuse(ctxID == 0 ? .invalidContext : .duplicateContext)
            }
            guard contexts.count < W.maxContexts else {
                return .refuse(.contextSlotsFull)
            }
            // Clean unwind: nothing is recorded when the backend
            // declines the create.
            if backend?.gpu3dCreateContext(ctxID, name: spec.name) != nil {
                return .refuse(.backendRefused)
            }
            let gen = (nextGeneration[ctxID] ?? 0) + 1
            nextGeneration[ctxID] = gen
            contexts[ctxID] = Context(id: ctxID, generation: gen)
            return .reply(type: W.respOkNoData, payload: [])

        case .ctxDestroy:
            guard let ctx = contexts[ctxID] else { return .refuse(.invalidContext) }
            retirePending(of: ctxID)
            contexts.removeValue(forKey: ctxID)
            backend?.gpu3dDestroyContext(ctx.id)
            return .reply(type: W.respOkNoData, payload: [])

        case .ctxAttachResource(let resourceID):
            return forward(req) { backend, ctx in
                guard ctx.resources[resourceID] != nil else { return .refuse(.invalidResource) }
                guard !ctx.attached.contains(resourceID) else { return .refuse(.invalidParameter) }
                if backend.gpu3dAttachResource(context: ctxID, resourceID: resourceID) != nil {
                    return .refuse(.backendRefused)
                }
                contexts[ctxID]?.attached.insert(resourceID)
                return .reply(type: W.respOkNoData, payload: [])
            }

        case .ctxDetachResource(let resourceID):
            return forward(req) { backend, ctx in
                guard ctx.attached.contains(resourceID) else { return .refuse(.invalidResource) }
                if backend.gpu3dDetachResource(context: ctxID, resourceID: resourceID) != nil {
                    return .refuse(.backendRefused)
                }
                contexts[ctxID]?.attached.remove(resourceID)
                return .reply(type: W.respOkNoData, payload: [])
            }

        case .resourceCreate3D(let spec):
            return forward(req) { backend, ctx in
                guard ctx.resources[spec.resourceID] == nil else {
                    return .refuse(.duplicateResource)
                }
                // Two resource budgets, one per profile (ADR 0053 D1/D3):
                // render resources keep VIR1's pinned 2/context while
                // target_buffer byte windows answer to VIC1's 16/context.
                let buffers = ctx.resources.values.filter {
                    $0.target == VirglStreamConst.targetBuffer
                }.count
                let renderResources = ctx.resources.count - buffers
                if spec.target == VirglStreamConst.targetBuffer {
                    guard buffers < W.vic1MaxBuffersPerCtx else {
                        return .refuse(.resourceLimit)
                    }
                } else {
                    guard renderResources < W.maxResourcesPerContext else {
                        return .refuse(.resourceLimit)
                    }
                }
                if backend.gpu3dCreateResource(context: ctxID, spec: spec) != nil {
                    return .refuse(.backendRefused)
                }
                contexts[ctxID]?.resources[spec.resourceID] = spec
                return .reply(type: W.respOkNoData, payload: [])
            }

        case .resourceUnref(let resourceID):
            return forward(req) { backend, ctx in
                guard ctx.resources[resourceID] != nil else {
                    return .refuse(.invalidResource)
                }
                if backend.gpu3dUnrefResource(context: ctxID, resourceID: resourceID) != nil {
                    return .refuse(.backendRefused)
                }
                contexts[ctxID]?.resources.removeValue(forKey: resourceID)
                contexts[ctxID]?.attached.remove(resourceID)
                return .reply(type: W.respOkNoData, payload: [])
            }

        case .resourceAttachBacking(let resourceID, let entries):
            return forward(req) { backend, ctx in
                guard ctx.resources[resourceID] != nil else {
                    return .refuse(.invalidResource)
                }
                if backend.gpu3dAttachBacking(context: ctxID, resourceID: resourceID,
                                              entries: entries) != nil {
                    return .refuse(.backendRefused)
                }
                return .reply(type: W.respOkNoData, payload: [])
            }

        case .resourceDetachBacking(let resourceID):
            return forward(req) { backend, ctx in
                guard ctx.resources[resourceID] != nil else {
                    return .refuse(.invalidResource)
                }
                if backend.gpu3dDetachBacking(context: ctxID, resourceID: resourceID) != nil {
                    return .refuse(.backendRefused)
                }
                return .reply(type: W.respOkNoData, payload: [])
            }

        case .transferToHost3D(let t):
            return forward(req) { backend, ctx in
                guard let res = ctx.resources[t.resourceID] else {
                    return .refuse(.invalidResource)
                }
                // The box must lie inside the created extent; the
                // backend owns stride/level semantics beyond that.
                guard t.box.x + t.box.w <= res.width,
                      t.box.y + t.box.h <= res.height,
                      t.box.z + t.box.d <= max(res.depth, 1),
                      t.level <= res.lastLevel else {
                    return .refuse(.invalidParameter)
                }
                return work(backend.gpu3dTransfer(context: ctxID, transfer: t,
                                                  toHost: true), req)
            }

        case .transferFromHost3D(let t):
            return forward(req) { backend, ctx in
                guard let res = ctx.resources[t.resourceID] else {
                    return .refuse(.invalidResource)
                }
                guard t.box.x + t.box.w <= res.width,
                      t.box.y + t.box.h <= res.height,
                      t.box.z + t.box.d <= max(res.depth, 1),
                      t.level <= res.lastLevel else {
                    return .refuse(.invalidParameter)
                }
                return work(backend.gpu3dTransfer(context: ctxID, transfer: t,
                                                  toHost: false), req)
            }

        case .submit3D(let stream):
            return forward(req) { backend, _ in
                work(backend.gpu3dSubmit(context: ctxID, stream: stream), req)
            }

        case .computeSubmit(let kd):
            return forward(req) { backend, ctx in
                // The one-outstanding rule outranks per-request
                // validation: a busy device never examined this
                // descriptor (deviceBusy, same as a second deferred
                // submit reaching work() below).
                guard pending == nil else { return .refuse(.deviceBusy) }
                // The frozen kernel library's own validation (ADR 0053
                // D3): kernel id, dims, flags, aux and buffer bindings
                // all refuse by name BEFORE the backend sees work.
                if let why = validateKernelDesc(kd, ctx: ctx) {
                    return .refuse(why)
                }
                return work(backend.gpu3dComputeSubmit(context: ctxID, desc: kd), req)
            }
        }
    }

    /// The D3 kernel-descriptor checks the dispatcher owns: shape rules
    /// (dims/flags/aux — `badKernelShape`, an id outside the mask —
    /// `unknownKernel`) and buffer bindings (`badKernelBinding` — a slot
    /// naming no attached target_buffer of THIS context, or a tensor
    /// whose byte span overruns the buffer's extent). The wire decoder
    /// already proved the envelope shape and reserved==0.
    private func validateKernelDesc(_ kd: GPU3DWire.KernelDesc, ctx: Context) -> GPU3DRefusal? {
        let W = GPU3DWire.self

        // A used slot must name an attached target_buffer resource of this
        // context and the declared tensor must fit its byte extent.
        func bind(_ s: GPU3DWire.KernelDesc.Buf, need: UInt64) -> GPU3DRefusal? {
            guard s.buf != 0,
                  let res = ctx.resources[s.buf],
                  ctx.attached.contains(s.buf),
                  res.target == VirglStreamConst.targetBuffer else {
                return .badKernelBinding
            }
            guard need <= UInt64(res.width),
                  UInt64(s.byteOff) <= UInt64(res.width) - need else {
                return .badKernelBinding
            }
            return nil
        }

        // An absent slot must be the all-zero pair — anything else is a
        // shape violation, not a binding miss.
        func absent(_ s: GPU3DWire.KernelDesc.Buf) -> GPU3DRefusal? {
            (s.buf == 0 && s.byteOff == 0) ? nil : .badKernelShape
        }

        switch kd.kernelID {
        case W.kernelGEMM:
            guard kd.flags & ~(W.gemmFlagBias | W.gemmFlagBTransposed) == 0,
                  kd.aux == 0, kd.reserved == 0 else { return .badKernelShape }
            let m = UInt64(kd.d0), n = UInt64(kd.d1), k = UInt64(kd.d2)
            guard m >= 1, n >= 1, k >= 1,
                  m <= UInt64(W.vic1MaxDim), n <= UInt64(W.vic1MaxDim), k <= UInt64(W.vic1MaxDim),
                  m * n <= UInt64(W.vic1Max2DElems) else { return .badKernelShape }
            if let r = bind(kd.bufs[0], need: m * k * 2) { return r } // A f16 [M,K]
            if let r = bind(kd.bufs[1], need: k * n * 2) { return r } // B f16
            if let r = bind(kd.bufs[2], need: m * n * 2) { return r } // C f16 out
            if kd.flags & W.gemmFlagBias != 0 {
                if let r = bind(kd.bufs[3], need: n * 2) { return r } // bias f16 [N]
            } else if let r = absent(kd.bufs[3]) { return r }

        case W.kernelSoftmax:
            guard kd.flags & ~W.softmaxFlagInPlace == 0,
                  kd.d2 == 0, kd.aux == 0, kd.reserved == 0 else { return .badKernelShape }
            let rows = UInt64(kd.d0), cols = UInt64(kd.d1)
            guard rows >= 1, cols >= 2,
                  rows <= UInt64(W.vic1MaxDim), cols <= UInt64(W.vic1SoftmaxMaxCols),
                  rows * cols <= UInt64(W.vic1Max2DElems) else { return .badKernelShape }
            let bytes = rows * cols * 4
            if let r = bind(kd.bufs[0], need: bytes) { return r } // in f32
            if let r = bind(kd.bufs[1], need: bytes) { return r } // out f32
            // in == out is legal only when the caller declared it in-place.
            if kd.bufs[0].buf == kd.bufs[1].buf,
               kd.flags & W.softmaxFlagInPlace == 0 { return .badKernelShape }
            if let r = absent(kd.bufs[2]) { return r }
            if let r = absent(kd.bufs[3]) { return r }

        case W.kernelDequant:
            guard kd.flags == 0, kd.d2 == 0, kd.reserved == 0,
                  kd.aux >> 8 == 0 else { return .badKernelShape }
            let n = UInt64(kd.d0)
            guard n >= 1, n <= UInt64(W.vic1MaxElems),
                  W.dequantGroupSizes.contains(kd.d1) else { return .badKernelShape }
            let group = UInt64(kd.d1)
            let groups = (n + group - 1) / group
            guard groups <= UInt64(W.vic1MaxGroups) else { return .badKernelShape }
            switch kd.aux & 0xff {
            case W.dequantFmtI8Sym:
                if let r = bind(kd.bufs[0], need: n) { return r } // packed q8
                if let r = absent(kd.bufs[2]) { return r } // symmetric: no zeros
            case W.dequantFmtU4Asym:
                if let r = bind(kd.bufs[0], need: (n + 1) / 2) { return r } // packed nibbles
                if let r = bind(kd.bufs[2], need: groups * 4) { return r } // zeros f32
            default:
                return .badKernelShape
            }
            if let r = bind(kd.bufs[1], need: groups * 4) { return r } // scales f32
            if let r = bind(kd.bufs[3], need: n * 2) { return r } // out f16

        default:
            return .unknownKernel
        }
        return nil
    }

    /// Shared gate for every render-path command: a backend must exist
    /// and the context must be live. Bookkeeping-level envelope checks
    /// (dup/limit/bounds) happen inside each dispatch arm.
    private func forward(_ req: GPU3DWire.Request,
                         _ body: (GPU3DBackend, Context) -> Outcome) -> Outcome {
        guard let backend else { return .refuse(.backendUnavailable) }
        guard let ctx = contexts[req.header.ctxID] else {
            return .refuse(.invalidContext)
        }
        return body(backend, ctx)
    }

    /// Map a backend work result onto an outcome. Deferred completion
    /// requires the guest's FENCE flag — consumption without a fence is
    /// not rendering completion — and at most one request is ever
    /// outstanding.
    private func work(_ result: GPU3DWorkResult, _ req: GPU3DWire.Request) -> Outcome {
        switch result {
        case .done:
            return .reply(type: GPU3DWire.respOkNoData, payload: [])
        case .failed:
            return .refuse(.backendRefused)
        case .deferred:
            guard pending == nil else { return .refuse(.deviceBusy) }
            guard req.header.fenceRequested else { return .refuse(.fenceRequired) }
            return .deferred
        }
    }

    // MARK: - Completion and lifetime

    /// The backend reports a fence finished (called on the device serial
    /// queue, or drained through `gpu3dPoll()`). A fence that matches no
    /// outstanding request is stale and dropped — it can never retire an
    /// element twice or target a recycled context generation.
    public func noteFenceCompleted(_ fenceID: UInt64) {
        guard let p = pending, p.header.fenceID == fenceID else {
            staleCompletions += 1
            return
        }
        pending = nil
        if contexts[p.ctxID]?.generation == p.generation {
            answer(p.element, type: GPU3DWire.respOkNoData, request: p.header, payload: [])
        } else {
            // The context was retired under the fence — the completion is
            // honestly an error, never a manufactured success receipt.
            answer(p.element, type: GPU3DWire.respErrUnspec, request: p.header, payload: [])
        }
        p.element.gpu3dReturn()
    }

    /// Device reset (guest-initiated or `requestDeviceReset`). Retires
    /// the held element with an error response, drops every context —
    /// generations keep rising, so a recycled ctx_id can never be hit by
    /// a completion issued before the reset — and resets the backend.
    /// Only THIS device's state is touched; the native 2D GPU is a
    /// separate device entirely.
    public func reset() {
        resetCount += 1
        if let p = pending {
            retiredPending += 1
            answer(p.element, type: GPU3DWire.respErrUnspec, request: p.header, payload: [])
            p.element.gpu3dReturn()
            pending = nil
        }
        contexts.removeAll()
        backend?.gpu3dReset()
    }

    /// The VM is stopping: drop all bookkeeping WITHOUT touching queue
    /// elements — the framework tears the rings down itself.
    func shutdown() {
        pending = nil
        contexts.removeAll()
        backend?.gpu3dReset()
    }

    /// Retire a context's held element (destroy path): it gets an error
    /// response and returns to the guest — a descriptor is never leaked
    /// or left to hang.
    private func retirePending(of ctxID: UInt32) {
        guard let p = pending, p.ctxID == ctxID else { return }
        retiredPending += 1
        answer(p.element, type: GPU3DWire.respErrUnspec, request: p.header, payload: [])
        p.element.gpu3dReturn()
        pending = nil
    }

    // MARK: - Answering

    /// Write a refusal: record the name, answer with the mapped
    /// virtio-gpu error, and return the element.
    private func refuse(_ element: GPU3DQueueElement, _ refusal: GPU3DRefusal,
                        request hdr: GPU3DWire.Header?) {
        lastRefusal = refusal
        refusalCount += 1
        // With no decodable header the error is always ERR_UNSPEC.
        let type = hdr == nil ? GPU3DWire.respErrUnspec : errorType(for: refusal)
        answer(element, type: type, request: hdr, payload: [])
        element.gpu3dReturn()
    }

    /// Write the response. If the element's write buffers cannot hold it
    /// the exchange is a named `.responseSpaceShort` refusal — and a bare
    /// ERR_UNSPEC header is written instead whenever even that fits.
    private func answer(_ element: GPU3DQueueElement, type: UInt32,
                        request hdr: GPU3DWire.Header?, payload: [UInt8]) {
        let bytes = GPU3DWire.encodeResponse(type: type, request: hdr, payload: payload)
        if element.gpu3dWriteByteCount >= bytes.count, element.gpu3dWrite(bytes) {
            return
        }
        lastRefusal = .responseSpaceShort
        refusalCount += 1
        guard type != GPU3DWire.respErrUnspec,
              element.gpu3dWriteByteCount >= GPU3DWire.hdrLen else { return }
        _ = element.gpu3dWrite(
            GPU3DWire.encodeResponse(type: GPU3DWire.respErrUnspec, request: nil))
    }

    private func errorType(for refusal: GPU3DRefusal) -> UInt32 {
        switch refusal {
        case .invalidContext, .duplicateContext:
            return GPU3DWire.respErrInvalidContextID
        case .contextSlotsFull, .resourceLimit:
            return GPU3DWire.respErrOutOfMemory
        case .invalidResource, .duplicateResource:
            return GPU3DWire.respErrInvalidResourceID
        case .invalidCapset, .invalidParameter, .reservedBits,
             .trailingBytes, .truncatedRequest,
             .unknownKernel, .badKernelShape:
            return GPU3DWire.respErrInvalidParameter
        case .badKernelBinding:
            return GPU3DWire.respErrInvalidResourceID
        default:
            return GPU3DWire.respErrUnspec
        }
    }
}

// MARK: - macOS 27 Virtualization.framework glue (SPIKE builds only)
//
// Everything below is the thin adapter onto VZCustomVirtioDevice: the
// configuration factory d3 will attach under --gpu3d-metal, the
// configuration delegate capturing the created device, and the device
// delegate forwarding queue notifications onto the same serial
// deviceQueue the core requires. It compiles only when the toolchain's
// SDK declares the custom-virtio types (macOS 27 SDK, -Xswiftc -DSPIKE).

#if SPIKE
import Virtualization

@available(macOS 27.0, *)
extension VZVirtioQueueElement: GPU3DQueueElement {
    public var gpu3dReadByteCount: Int { readBuffersByteCount }
    public var gpu3dWriteByteCount: Int { writeBuffersByteCount }

    public func gpu3dReadAll() -> [UInt8] {
        var out: [UInt8] = []
        for buffer in readBuffers() { out.append(contentsOf: buffer) }
        return out
    }

    public func gpu3dWrite(_ bytes: [UInt8]) -> Bool {
        do {
            try write(Data(bytes))
            return writtenByteCount == bytes.count
        } catch {
            return false
        }
    }

    public func gpu3dReturn() { returnToQueue() }
}

@available(macOS 27.0, *)
private struct GPU3DVZQueue: GPU3DQueue {
    let underlying: VZVirtioQueue
    var gpu3dQueueIndex: Int { Int(underlying.queueIndex) }
    func gpu3dNextElement() -> GPU3DQueueElement? { underlying.nextElement() }
}

/// Owns a GPU3DDevice plus the framework delegates that keep the device
/// alive for the VM's lifetime (VZ holds both delegates weakly — the
/// spike documents that, so they are stored strongly here).
@available(macOS 27.0, *)
public final class GPU3DHostDevice: NSObject {
    /// THE serial queue: the provider is created with it, so every
    /// delegate callback and all element access is single-threaded.
    public let deviceQueue = DispatchQueue(label: "virelaios.gpu3d")
    /// The testable core — plain `swift test` exercises everything but
    /// this shell.
    public let core: GPU3DDevice

    fileprivate let configDelegate = GPU3DConfigDelegate()
    fileprivate let deviceDelegate = GPU3DDeviceDelegate()

    /// The live framework device (strong reference — lives as long as
    /// the VM once created).
    public fileprivate(set) var device: VZCustomVirtioDevice?
    /// Set when the guest finishes feature negotiation (DRIVER_OK).
    public fileprivate(set) var driverOK = false

    public init(backend: GPU3DBackend? = nil) {
        core = GPU3DDevice(backend: backend)
        super.init()
        // The pump rides the same serial queue VZ delivers delegate
        // callbacks on — fence polling never leaves it.
        core.completionQueue = deviceQueue
        configDelegate.owner = self
        deviceDelegate.owner = self
    }

    /// One custom-Virtio device: ID 0x43 (PCI 1af4:1083), display class,
    /// two virtio-gpu-shaped queues, VIRGL offered as an OPTIONAL bit
    /// (the mandatory private VIR1 capability match is what actually
    /// binds the profile), and the 16-byte config space reporting zero
    /// scanouts and one cap-set per attached profile — VIR1 always, VIC1
    /// when a backend is attached (M111, ADR 0053 D1). d3 attaches this
    /// under --gpu3d-metal; nothing here changes the default VM shape.
    public func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        let config = VZCustomVirtioDeviceConfiguration()
        config.deviceID = GPU3DWire.deviceID
        config.pciClassID = GPU3DWire.pciClass
        config.pciSubclassID = GPU3DWire.pciSubclass
        config.virtioQueueCount = GPU3DWire.queueCount
        config.optionalFeatures.subset0 = GPU3DWire.featureVirgl
        config.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(
            configurationData: Data(GPU3DWire.deviceConfigBytes(
                numCapsets: core.backend != nil ? 2 : 1)))
        config.provider = VZCustomVirtioDeviceDelegateProvider(
            deviceQueue: deviceQueue, delegate: configDelegate)
        return config
    }
}

@available(macOS 27.0, *)
private final class GPU3DConfigDelegate: NSObject, VZCustomVirtioDeviceConfigurationDelegate {
    weak var owner: GPU3DHostDevice?

    func customVirtioConfiguration(_ deviceConfiguration: VZCustomVirtioDeviceConfiguration,
                                   didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = owner?.deviceDelegate
        owner?.device = device
    }
}

@available(macOS 27.0, *)
private final class GPU3DDeviceDelegate: NSObject, VZCustomVirtioDeviceDelegate {
    weak var owner: GPU3DHostDevice?

    func customVirtioDevice(_ device: VZCustomVirtioDevice,
                            didReceiveNotificationFor queue: VZVirtioQueue) {
        owner?.core.handleQueueNotification(GPU3DVZQueue(underlying: queue))
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        owner?.driverOK = true
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        owner?.core.reset()
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        owner?.core.shutdown()
    }
}
#endif
