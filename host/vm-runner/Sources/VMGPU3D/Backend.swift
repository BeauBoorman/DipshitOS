// Backend.swift — M102b2 (issue #2163): the injected renderer boundary
// for the custom-Virtio 3D device. The device core owns the virtio
// envelope, context lifecycle, bounds and fences; a backend owns actual
// rendering. c2's Metal implementation conforms to GPU3DBackend in its
// own files; this card ships only the boundary and a deterministic test
// hook.
//
// THE NULL BACKEND IS HONEST: with no backend attached the device
// advertises ready=0 in the VIR1 capability payload and refuses every
// draw/transfer/submit with GPU3DRefusal.backendUnavailable. No path
// manufactures a successful-render receipt.

import Foundation

/// Why a backend declined work. Maps to an ERR_UNSPEC wire response; the
/// precise name stays on the host side.
public enum GPU3DBackendFailure: Error, Equatable {
    /// The backend cannot or will not perform this operation.
    case refused
    /// The backend faulted mid-operation; the context is poisoned.
    case faulted
}

/// What a submit/transfer produced. Deferred work completes later through
/// `GPU3DDevice.noteFenceCompleted(_:)` or `gpu3dPoll()` — consumption
/// without the request's fence is not rendering completion (#2160 item 4).
public enum GPU3DWorkResult: Equatable {
    /// The operation finished synchronously; the device answers OK now.
    case done
    /// The operation is in flight; the device holds the element until the
    /// request's fence is reported complete.
    case deferred
    /// The backend declined the work.
    case failed(GPU3DBackendFailure)
}

/// The renderer seam. All methods run on the device serial queue (the
/// same discipline VZ applies to queue-element access). Default
/// implementations do nothing and succeed, so a minimal backend only
/// implements readiness, resource creation, transfer and submit.
public protocol GPU3DBackend: AnyObject {
    /// Reported verbatim in capability word 8 (ready=0|1).
    var gpu3dReady: Bool { get }

    /// Drop all GPU-side state for a device reset.
    func gpu3dReset()

    /// Context lifecycle mirrors the device's; a refusal fails the
    /// guest's CTX_CREATE with no context recorded.
    func gpu3dCreateContext(_ ctxID: UInt32, name: String) -> GPU3DBackendFailure?
    func gpu3dDestroyContext(_ ctxID: UInt32)

    /// Resource bookkeeping. `spec` is already bounds-checked against the
    /// profile (1...256 × 1...192, single plane, single sample).
    func gpu3dCreateResource(context ctxID: UInt32, spec: GPU3DWire.ResourceCreate) -> GPU3DBackendFailure?
    func gpu3dUnrefResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure?
    func gpu3dAttachBacking(context ctxID: UInt32, resourceID: UInt32, entries: [GPU3DWire.BackingEntry]) -> GPU3DBackendFailure?
    func gpu3dDetachBacking(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure?
    func gpu3dAttachResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure?
    func gpu3dDetachResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure?

    /// TRANSFER_TO_HOST_3D (toHost == true) uploads into a resource;
    /// TRANSFER_FROM_HOST_3D reads back. Either may defer.
    func gpu3dTransfer(context ctxID: UInt32, transfer: GPU3DWire.Transfer, toHost: Bool) -> GPU3DWorkResult

    /// SUBMIT_3D: one bounded, word-aligned VirGL command stream
    /// (<= 4,096 bytes). Deferred completion is reported against the
    /// request's fence ID.
    func gpu3dSubmit(context ctxID: UInt32, stream: [UInt8]) -> GPU3DWorkResult

    /// Reported in VIC1 word 7 (ready=0|1) — a backend attached without a
    /// working compute pipeline advertises the capset but answers 0, so
    /// the guest's compute ops take the honest ENXIO (M111, ADR 0053 D1).
    var gpu3dComputeReady: Bool { get }

    /// COMPUTE_SUBMIT (0x0400): one frozen 64-byte kernel descriptor,
    /// already shape- and binding-validated by the device dispatcher.
    /// Deferred completion is the same fence contract as gpu3dSubmit —
    /// the held element returns when this request's fence is reported.
    func gpu3dComputeSubmit(context ctxID: UInt32, desc: GPU3DWire.KernelDesc) -> GPU3DWorkResult

    /// Polling completion channel: fence IDs that finished since the last
    /// call. The device drains this at the top of every queue batch —
    /// the polling model of #2160 item 4, no long waits anywhere.
    func gpu3dPoll() -> [UInt64]
}

/// No-op defaults: a backend only needs ready/reset/createResource/
/// transfer/submit to be real.
public extension GPU3DBackend {
    func gpu3dCreateContext(_ ctxID: UInt32, name: String) -> GPU3DBackendFailure? { nil }
    func gpu3dDestroyContext(_ ctxID: UInt32) {}
    func gpu3dUnrefResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure? { nil }
    func gpu3dAttachBacking(context ctxID: UInt32, resourceID: UInt32, entries: [GPU3DWire.BackingEntry]) -> GPU3DBackendFailure? { nil }
    func gpu3dDetachBacking(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure? { nil }
    func gpu3dAttachResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure? { nil }
    func gpu3dDetachResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure? { nil }
    /// Default: no compute — the VIC1 payload reports ready=0 and every
    /// COMPUTE_SUBMIT declines. The Metal backend overrides both.
    var gpu3dComputeReady: Bool { false }
    func gpu3dComputeSubmit(context ctxID: UInt32, desc: GPU3DWire.KernelDesc) -> GPU3DWorkResult {
        .failed(.refused)
    }
    func gpu3dPoll() -> [UInt64] { [] }
}

/// The deterministic test hook c2 develops against (the card's
/// "deterministic test-hook capability"): scriptable readiness, deferred
/// vs synchronous work, call recording, and a poll queue the test fills.
/// It renders nothing and claims nothing — it exists so device behavior
/// can be pinned without a GPU.
public final class GPU3DTestBackend: GPU3DBackend {
    /// Whether GET_CAPSET advertises ready=1.
    public var ready = true
    /// When true, submit/transfer return `.deferred`; when false, `.done`.
    public var deferWork = true
    /// Fence IDs reported complete by the next gpu3dPoll() call.
    public var polledFences: [UInt64] = []
    /// Called at the top of every gpu3dPoll() — lets a test arm a
    /// completion from inside the poll itself, on whatever queue the
    /// caller ran it on (the fence pump's serial queue), instead of
    /// racing the pump from the test thread.
    public var onPoll: (() -> Void)?
    /// When set, the next fallible call returns this failure once.
    public var nextFailure: GPU3DBackendFailure?
    /// Every call the device made, in order ("createContext:1", ...).
    public private(set) var calls: [String] = []
    /// How many times gpu3dReset ran.
    public private(set) var resets = 0

    public init() {}

    public var gpu3dReady: Bool { ready }
    /// VIC1's ready word — off by default so an existing test backend
    /// keeps advertising a render-only profile unless the test opts in.
    public var computeReady = false
    public var gpu3dComputeReady: Bool { computeReady }

    private func fail() -> GPU3DBackendFailure? {
        defer { nextFailure = nil }
        return nextFailure
    }

    public func gpu3dReset() {
        resets += 1
        calls.append("reset")
    }

    public func gpu3dCreateContext(_ ctxID: UInt32, name: String) -> GPU3DBackendFailure? {
        calls.append("createContext:\(ctxID):\(name)")
        return fail()
    }

    public func gpu3dDestroyContext(_ ctxID: UInt32) {
        calls.append("destroyContext:\(ctxID)")
    }

    public func gpu3dCreateResource(context ctxID: UInt32, spec: GPU3DWire.ResourceCreate) -> GPU3DBackendFailure? {
        calls.append("createResource:\(ctxID):\(spec.resourceID)")
        return fail()
    }

    public func gpu3dUnrefResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure? {
        calls.append("unref:\(ctxID):\(resourceID)")
        return fail()
    }

    public func gpu3dAttachBacking(context ctxID: UInt32, resourceID: UInt32, entries: [GPU3DWire.BackingEntry]) -> GPU3DBackendFailure? {
        calls.append("attachBacking:\(ctxID):\(resourceID):\(entries.count)")
        return fail()
    }

    public func gpu3dDetachBacking(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure? {
        calls.append("detachBacking:\(ctxID):\(resourceID)")
        return fail()
    }

    public func gpu3dAttachResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure? {
        calls.append("attachResource:\(ctxID):\(resourceID)")
        return fail()
    }

    public func gpu3dDetachResource(context ctxID: UInt32, resourceID: UInt32) -> GPU3DBackendFailure? {
        calls.append("detachResource:\(ctxID):\(resourceID)")
        return fail()
    }

    public func gpu3dTransfer(context ctxID: UInt32, transfer: GPU3DWire.Transfer, toHost: Bool) -> GPU3DWorkResult {
        calls.append("transfer:\(toHost ? "to" : "from"):\(ctxID):\(transfer.resourceID)")
        if let f = nextFailure { nextFailure = nil; return .failed(f) }
        return deferWork ? .deferred : .done
    }

    public func gpu3dSubmit(context ctxID: UInt32, stream: [UInt8]) -> GPU3DWorkResult {
        calls.append("submit:\(ctxID):\(stream.count)")
        if let f = nextFailure { nextFailure = nil; return .failed(f) }
        return deferWork ? .deferred : .done
    }

    public func gpu3dComputeSubmit(context ctxID: UInt32, desc: GPU3DWire.KernelDesc) -> GPU3DWorkResult {
        calls.append("compute:\(ctxID):\(desc.kernelID)")
        if let f = nextFailure { nextFailure = nil; return .failed(f) }
        return deferWork ? .deferred : .done
    }

    public func gpu3dPoll() -> [UInt64] {
        onPoll?()
        let out = polledFences
        polledFences = []
        if !out.isEmpty { calls.append("poll:\(out.count)") }
        return out
    }
}
