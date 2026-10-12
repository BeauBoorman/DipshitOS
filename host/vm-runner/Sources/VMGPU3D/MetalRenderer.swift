// MetalRenderer.swift — M102c2 (issue #2165): the real renderer behind
// b2's injected GPU3DBackend seam. Submitted streams are decoded and
// FULLY validated by VirglStreamDecoder before any Metal work exists
// (a malformed tail executes no prefix), then rendered with first-party
// Metal: an actual render target, render pipeline and vertex buffer
// with a non-indexed three-vertex draw. No ANGLE, no virglrenderer
// runtime, no MoltenVK, no CPU rasterizer, no software fallback.
//
// Completion is honest: a deferred submit's fence is reported through
// gpu3dPoll() ONLY after the Metal command buffer's completion handler
// ran — never at decode or queue consumption. The fence value itself is
// read back from the device (pendingFenceID, the only channel the
// frozen b2 interface exposes for the guest's u64 fence) so the reply
// matches the full fence, not a renderer-side approximation. At most
// one render submission is in flight at a time, mirroring the device's
// single-outstanding-request rule.
//
// Deterministic SPIKE knobs for d3 (issue #2168): withholdCompletion
// (a delayed backend), reportWrongFence and stallCompletion alter
// completion timing/content only — they never generate substitute
// pixels. fenceCompletionIsGPUCompletion is the revert-fails seam for
// this card's fence proof: shipping false would report completion at
// queue consumption; the delayed-backend test goes red.
//
// Guest memory is a seam, not a shortcut: TRANSFER_TO_HOST_3D uploads
// bytes read through GPU3DMemory out of the resource's attached
// backing, TRANSFER_FROM_HOST_3D writes the rendered BGRA8 back the
// same way — ordered strictly after the draw's fence. d3 wires this to
// the VM's real guest RAM; tests inject a flat array.

import Foundation
import Metal

/// The guest-RAM seam transfers DMA through. Addresses are guest
/// physical addresses exactly as RESOURCE_ATTACH_BACKING declared
/// them; the renderer flattens entries and adds transfer offsets.
public protocol GPU3DMemory {
    /// Read `count` bytes at guest `address`; nil when unmapped.
    func gpu3dRead(_ address: UInt64, count: Int) -> [UInt8]?
    /// Write `bytes` at guest `address`; false when unmapped/short.
    func gpu3dWrite(_ address: UInt64, bytes: [UInt8]) -> Bool
}

/// Original host MSL implementing the pinned TGSI pair: position +
/// color passthrough, exactly the two MOV bodies the fixture shaders
/// carry. Written for this card — not a transpiled copy of any third
/// party shader.
private let virelaiMSL = """
#include <metal_stdlib>
using namespace metal;

struct VirglIn {
    float4 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct VirglOut {
    float4 position [[position]];
    float4 color;
};

vertex VirglOut virelai_vertex(VirglIn in [[stage_in]]) {
    VirglOut out;
    out.position = in.position;   /* TGSI: MOV OUT[0], IN[0] */
    out.color    = in.color;      /* TGSI: MOV OUT[1], IN[1] */
    return out;
}

fragment float4 virelai_fragment(VirglOut in [[stage_in]]) {
    return in.color;              /* TGSI: MOV OUT[0], IN[0] */
}
"""

/// The Metal backend for the VIR1 render device. Failable: no Metal
/// device means the card's named BLOCKED — `init` returns nil, the
/// device keeps advertising ready=0, and nothing manufactures a
/// successful-render receipt.
public final class GPU3DMetalRenderer: GPU3DBackend {
    /// One live resource: the created spec, its Metal object, attached
    /// guest backing, ctx attachment and upload watermark.
    private struct Resource {
        let spec: GPU3DWire.ResourceCreate
        var texture: MTLTexture?
        var buffer: MTLBuffer?
        var backing: [GPU3DWire.BackingEntry] = []
        var attached = false
        var uploadedBytes = 0
    }

    /// A render submission whose fence is not yet reported. Retains the
    /// Metal objects the in-flight command buffer references until the
    /// completion handler runs — a reset/close cannot free memory the
    /// GPU still touches.
    private final class InFlight {
        let serial: UInt64
        let ctxID: UInt32
        let texture: MTLTexture
        let buffer: MTLBuffer?
        var arrived = false    // Metal completion handler ran
        var completed = false  // completion is reportable (release gates)
        init(serial: UInt64, ctxID: UInt32, texture: MTLTexture, buffer: MTLBuffer?) {
            self.serial = serial; self.ctxID = ctxID
            self.texture = texture; self.buffer = buffer
        }
    }

    private let mtlDevice: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let memory: GPU3DMemory
    /// The device core this backend serves — the read-only channel for
    /// the held request's fence id (b2's frozen interface carries the
    /// guest's u64 fence only in the held element).
    public weak var device: GPU3DDevice?

    private let lock = NSLock()
    private var contexts: [UInt32: [UInt32: Resource]] = [:]
    private var inFlight: InFlight?
    private var nextSerial: UInt64 = 1

    // MARK: - Deterministic completion knobs (d3's SPIKE seam; tests)

    /// Delayed-backend mode: the Metal completion still arrives but the
    /// fence is withheld until `releaseCompletion()` — a deterministic
    /// slow GPU, never substitute pixels.
    public var withholdCompletion = false
    /// Wrong-fence mode: the reported fence id is inverted, so the held
    /// element can never match — proves full-u64 fence correlation.
    public var reportWrongFence = false
    /// Stall mode: completions are recorded but never reported; the
    /// held element waits until reset/destroy retires it.
    public var stallCompletion = false
    /// REVERT-FAILS SEAM (#2165): completion follows the Metal
    /// completion handler. Flipping to false returns .done at queue
    /// consumption — the delayed-backend ordering test goes red while
    /// every other assertion stays green.
    public var fenceCompletionIsGPUCompletion = true

    // MARK: - Diagnostics (observed, not inferred)

    /// Draw calls actually encoded to Metal.
    public private(set) var drawsEncoded = 0
    /// Render command buffers that reached GPU completion.
    public private(set) var gpuCompletions = 0
    /// Submissions rejected before any Metal work (decode/refusal).
    public private(set) var submitRejections = 0
    /// The last decode rejection, for evidence comments.
    public private(set) var lastRejection: VirglStreamRejection?
    /// In-flight completions dropped because the held element retired
    /// (reset/destroy raced the GPU).
    public private(set) var orphanedCompletions = 0

    public let metalDeviceName: String

    /// Nil when this host has no Metal device or the fixed pipeline
    /// cannot build — the named blocker, never a mock substitute.
    public init?(memory: GPU3DMemory, device mtl: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let mtl,
              let queue = mtl.makeCommandQueue(),
              let library = try? mtl.makeLibrary(source: virelaiMSL, options: nil),
              let vertex = library.makeFunction(name: "virelai_vertex"),
              let fragment = library.makeFunction(name: "virelai_fragment") else {
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        // The pinned vertex_elements object: float4 position @0 and
        // float4 color @16 over buffer 0 at stride 32.
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float4
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float4
        vd.attributes[1].offset = 16
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 32
        desc.vertexDescriptor = vd
        let color = desc.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = false // pinned blend word: blend disabled
        desc.rasterSampleCount = 1
        guard let pipeline = try? mtl.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        self.mtlDevice = mtl
        self.queue = queue
        self.pipeline = pipeline
        self.memory = memory
        self.metalDeviceName = mtl.name
    }

    public var gpu3dReady: Bool { true }

    // MARK: - Lifecycle

    public func gpu3dReset() {
        lock.lock()
        contexts.removeAll()
        // The in-flight command buffer keeps its own Metal references;
        // dropping our record does not free anything the GPU touches.
        // The late handler finds no serial and lands nowhere.
        inFlight = nil
        lock.unlock()
    }

    public func gpu3dCreateContext(_ ctxID: UInt32, name: String) -> GPU3DBackendFailure? {
        lock.lock(); defer { lock.unlock() }
        contexts[ctxID] = [:]
        return nil
    }

    public func gpu3dDestroyContext(_ ctxID: UInt32) {
        lock.lock()
        contexts.removeValue(forKey: ctxID)
        lock.unlock()
    }

    // MARK: - Resources

    public func gpu3dCreateResource(context ctxID: UInt32,
                                    spec: GPU3DWire.ResourceCreate) -> GPU3DBackendFailure? {
        lock.lock(); defer { lock.unlock() }
        guard contexts[ctxID] != nil else { return .refused }
        var res = Resource(spec: spec)
        switch spec.target {
        case VirglStreamConst.target2D:
            guard spec.format == VirglStreamConst.formatBGRA8 else { return .refused }
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: Int(spec.width), height: Int(spec.height), mipmapped: false)
            td.storageMode = .shared
            td.usage = [.renderTarget, .shaderRead]
            guard let texture = mtlDevice.makeTexture(descriptor: td) else {
                return .faulted
            }
            res.texture = texture
        case VirglStreamConst.targetBuffer:
            guard let buffer = mtlDevice.makeBuffer(length: Int(spec.width),
                                                    options: .storageModeShared) else {
                return .faulted
            }
            res.buffer = buffer
        default:
            return .refused
        }
        contexts[ctxID]?[spec.resourceID] = res
        return nil
    }

    public func gpu3dUnrefResource(context ctxID: UInt32,
                                   resourceID: UInt32) -> GPU3DBackendFailure? {
        lock.lock(); defer { lock.unlock() }
        // Safe while in-flight: the InFlight record retains the Metal
        // objects until the completion handler retires them.
        contexts[ctxID]?[resourceID] = nil
        return nil
    }

    public func gpu3dAttachBacking(context ctxID: UInt32, resourceID: UInt32,
                                   entries: [GPU3DWire.BackingEntry]) -> GPU3DBackendFailure? {
        lock.lock(); defer { lock.unlock() }
        guard var res = contexts[ctxID]?[resourceID], !entries.isEmpty else {
            return .refused
        }
        res.backing = entries
        contexts[ctxID]?[resourceID] = res
        return nil
    }

    public func gpu3dDetachBacking(context ctxID: UInt32,
                                   resourceID: UInt32) -> GPU3DBackendFailure? {
        lock.lock(); defer { lock.unlock() }
        contexts[ctxID]?[resourceID]?.backing = []
        return nil
    }

    public func gpu3dAttachResource(context ctxID: UInt32,
                                    resourceID: UInt32) -> GPU3DBackendFailure? {
        lock.lock(); defer { lock.unlock() }
        guard contexts[ctxID]?[resourceID] != nil else { return .refused }
        contexts[ctxID]?[resourceID]?.attached = true
        return nil
    }

    public func gpu3dDetachResource(context ctxID: UInt32,
                                    resourceID: UInt32) -> GPU3DBackendFailure? {
        lock.lock(); defer { lock.unlock() }
        contexts[ctxID]?[resourceID]?.attached = false
        return nil
    }

    // MARK: - Transfers (guest DMA through the memory seam)

    /// Total attached backing bytes for a resource.
    private func backingBytes(_ res: Resource) -> UInt64 {
        entriesTotal(res.backing)
    }
    private func entriesTotal(_ entries: [GPU3DWire.BackingEntry]) -> UInt64 {
        entries.reduce(0) { $0 + UInt64($1.length) }
    }

    /// Read `count` bytes starting `offset` bytes into `backing`.
    private func readBacking(_ backing: [GPU3DWire.BackingEntry],
                             offset: UInt64, count: Int) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var remaining = offset
        var need = count
        for e in backing {
            let len = UInt64(e.length)
            if remaining >= len { remaining -= len; continue }
            let here = min(need, Int(len - remaining))
            guard let bytes = memory.gpu3dRead(e.address + remaining, count: here) else {
                return nil
            }
            out.append(contentsOf: bytes)
            need -= here
            remaining = 0
            if need == 0 { return out }
        }
        return need == 0 ? out : nil
    }

    /// Write `bytes` starting `offset` bytes into `backing`.
    private func writeBacking(_ backing: [GPU3DWire.BackingEntry],
                              offset: UInt64, bytes: [UInt8]) -> Bool {
        var remaining = offset
        var cursor = bytes.startIndex
        for e in backing {
            let len = UInt64(e.length)
            if remaining >= len { remaining -= len; continue }
            let here = min(bytes.endIndex - cursor, Int(len - remaining))
            guard memory.gpu3dWrite(e.address + remaining,
                                    bytes: Array(bytes[cursor..<(cursor + here)])) else {
                return false
            }
            cursor += here
            remaining = 0
            if cursor == bytes.endIndex { return true }
        }
        return cursor == bytes.endIndex
    }

    public func gpu3dTransfer(context ctxID: UInt32, transfer: GPU3DWire.Transfer,
                              toHost: Bool) -> GPU3DWorkResult {
        lock.lock(); defer { lock.unlock() }
        guard let res = contexts[ctxID]?[transfer.resourceID] else {
            return .failed(.refused)
        }
        let t = transfer
        if toHost {
            // The only profile upload: a linear buffer range into the
            // vertex buffer. Box must be a flat run at offset 0..len.
            guard res.buffer != nil, t.box.x == 0, t.box.y == 0, t.box.z == 0,
                  t.box.h == 1, t.box.d == 1, t.stride == 0, t.layerStride == 0,
                  UInt64(t.box.w) + t.offset <= backingBytes(res),
                  t.offset + UInt64(t.box.w) <= UInt64(res.spec.width) else {
                return .failed(.refused)
            }
            guard let bytes = readBacking(res.backing, offset: t.offset,
                                          count: Int(t.box.w)) else {
                return .failed(.faulted)
            }
            var updated = res
            let dst = updated.buffer!.contents().advanced(by: Int(t.offset))
            dst.copyMemory(from: bytes, byteCount: bytes.count)
            updated.uploadedBytes = max(updated.uploadedBytes,
                                        Int(t.offset) + bytes.count)
            contexts[ctxID]?[t.resourceID] = updated
            return .done
        }

        // Readback: BGRA8 ordered AFTER the draw — in-flight incomplete
        // work for this context means the pixels are not final; refuse
        // rather than return a prefix of the frame.
        if let f = inFlight, !f.completed { return .failed(.refused) }
        guard let texture = res.texture, t.box.x == 0, t.box.y == 0, t.box.z == 0,
              t.box.d == 1, t.box.w == res.spec.width, t.box.h == res.spec.height,
              t.offset == 0, t.stride == res.spec.width * 4, t.layerStride == 0,
              UInt64(t.stride) * UInt64(t.box.h) <= backingBytes(res) else {
            return .failed(.refused)
        }
        var pixels = [UInt8](repeating: 0,
                             count: Int(t.box.w * t.box.h * 4))
        pixels.withUnsafeMutableBytes { dst in
            texture.getBytes(dst.baseAddress!,
                             bytesPerRow: Int(res.spec.width) * 4,
                             from: MTLRegionMake2D(0, 0,
                                                   Int(res.spec.width),
                                                   Int(res.spec.height)),
                             mipmapLevel: 0)
        }
        // `stride` is the guest backing's row stride; the pinned
        // profile always sends exactly width*4 (linear), enforced above.
        guard writeBacking(res.backing, offset: t.offset, bytes: pixels) else {
            return .failed(.faulted)
        }
        return .done
    }

    // MARK: - Submit: whole-stream validation, then real Metal work

    public func gpu3dSubmit(context ctxID: UInt32, stream: [UInt8]) -> GPU3DWorkResult {
        lock.lock()
        // One render submission in flight at a time — the device's
        // single-outstanding rule, enforced backend-side so a second
        // submit never starts GPU work it cannot fence.
        guard inFlight == nil else {
            lock.unlock(); return .failed(.refused)
        }
        guard let table = contexts[ctxID] else {
            lock.unlock(); return .failed(.refused)
        }
        // WHOLE-STREAM validation first: decode builds the frame plan
        // or names a rejection; nothing below can run a prefix.
        let specs = table.mapValues { $0.spec }
        let frame: VirglDecodedFrame
        switch VirglStreamDecoder.decode(stream, resources: specs) {
        case .failure(let why):
            lastRejection = why
            submitRejections += 1
            lock.unlock()
            return .failed(.refused)
        case .success(let f): frame = f
        }

        // A stream with no render work needs no GPU round-trip.
        guard frame.clearColor != nil || frame.drawsTriangle else {
            lock.unlock()
            return .done
        }
        guard let color = table[frame.colorResourceID], let texture = color.texture,
              color.attached, color.spec.width == frame.width,
              color.spec.height == frame.height else {
            submitRejections += 1
            lock.unlock()
            return .failed(.refused)
        }
        var vertexBuffer: MTLBuffer? = nil
        if frame.drawsTriangle {
            guard let vbo = table[frame.vertexResourceID], let buf = vbo.buffer,
                  vbo.attached, vbo.uploadedBytes >= 96 else {
                submitRejections += 1
                lock.unlock()
                return .failed(.refused)
            }
            vertexBuffer = buf
        }

        // Encode the real render: one pass, loadAction .clear with the
        // stream's clear color, then the pinned non-indexed draw.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        if let c = frame.clearColor {
            pass.colorAttachments[0].clearColor =
                MTLClearColorMake(Double(c.x), Double(c.y), Double(c.z), Double(c.w))
        } else {
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        }
        pass.colorAttachments[0].storeAction = .store
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            lock.unlock()
            return .failed(.faulted)
        }
        // The pinned contract maps NDC (-1,-1) to readback pixel
        // (0,0) — the FIRST backing row. Metal's default transform
        // sends NDC +y to row 0; a negative viewport height is the
        // standard Metal way to flip that convention, keeping the
        // host MSL a pure TGSI passthrough.
        enc.setViewport(MTLViewport(originX: 0,
                                    originY: Double(frame.height),
                                    width: Double(frame.width),
                                    height: -Double(frame.height),
                                    znear: 0, zfar: 1))
        if frame.drawsTriangle, let vb = vertexBuffer {
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: Int(VirglStreamConst.vertexCount),
                               instanceCount: 1)
            drawsEncoded += 1
        }
        enc.endEncoding()

        let serial = nextSerial
        nextSerial += 1
        let record = InFlight(serial: serial, ctxID: ctxID,
                              texture: texture, buffer: vertexBuffer)
        cb.addCompletedHandler { [weak self] _ in
            // The Metal completion callback is the ONLY source of a
            // reportable fence. Stall mode records the arrival but
            // never reports; withhold mode waits for release.
            self?.noteGPUCompletion(record)
        }
        inFlight = record
        cb.commit()
        lock.unlock()
        return fenceCompletionIsGPUCompletion ? .deferred : .done
    }

    /// The Metal completion handler's landing pad (any thread).
    private func noteGPUCompletion(_ record: InFlight) {
        lock.lock(); defer { lock.unlock() }
        record.arrived = true
        gpuCompletions += 1
        // A completion for a record reset/close already retired is
        // orphaned — it must never acknowledge a recycled context.
        guard inFlight === record else {
            orphanedCompletions += 1
            return
        }
        if !withholdCompletion { record.completed = true }
    }

    /// Release a withheld (delayed-backend) completion: the fence
    /// becomes reportable on the next poll. No-op unless a completion
    /// actually arrived — pixels are never fabricated, only timing.
    public func releaseCompletion() {
        lock.lock(); defer { lock.unlock() }
        if let f = inFlight, f.arrived { f.completed = true }
    }

    /// The poll channel: a fence is reported ONLY for a completed
    /// in-flight submission, and it is the fence the device is actually
    /// holding — read back from the held request so the full u64 match
    /// stays honest. A completion whose element already retired lands
    /// nowhere (generation safety lives in the device).
    public func gpu3dPoll() -> [UInt64] {
        lock.lock(); defer { lock.unlock() }
        guard !stallCompletion else { return [] }
        guard let f = inFlight, f.completed else { return [] }
        guard let fence = device?.pendingFenceID else {
            inFlight = nil
            orphanedCompletions += 1
            return []
        }
        inFlight = nil
        return [reportWrongFence ? ~fence : fence]
    }
}
