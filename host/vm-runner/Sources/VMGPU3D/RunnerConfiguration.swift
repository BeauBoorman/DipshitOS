// RunnerConfiguration.swift — M102d3 (issue #2168): the runner-facing
// leaf for the experimental custom-Virtio 3D render device. The new
// `--gpu3d-*` option parsing, the pre-attachment validation, the
// device-list contribution and the backend assembly all live HERE —
// main.swift only delegates — so `swift test` pins the whole contract
// on a host that never boots a VM.
//
// Honesty rules carried from the card and the M102 index (#2160):
//
//   * No flag means NOTHING changes: the contributed device list is
//     empty and the runner's device configuration is byte-identical.
//   * The opt-in APPENDS one private render device (0x43 / PCI
//     1af4:1083, VIR1 v1) beside the native 2D GPU and any existing
//     0x42 custom channel — it never replaces a device.
//   * ready=1 is advertised only when c2's real Metal pipeline
//     initialized. A failed init, an unsupported host or a refused
//     device validation is a NAMED failure — never a silent fallback,
//     never a software/non-MIT/QEMU substitute.
//   * `--gpu3d-test-mode` completion-fault selection exists only under
//     SPIKE compilation; the ordinary build rejects the knob by name.
//   * Reporting is identity + lifecycle counters + the virgl coverage
//     matrix (#3176 — verdict lines at attach) only — never token
//     contents, never guest memory bytes.
//
// The VZ/guest-memory glue at the bottom compiles only under -DSPIKE
// (macOS 27 SDK types — the same gate as Device.swift's provider glue).
// Everything above it is pure Swift + Foundation/Metal so the ordinary
// build and `swift test` exercise the full decision surface.

import Foundation
import Metal

/// The `--gpu3d-*` option surface and its testable decisions.
public enum GPU3DRunnerConfiguration {
    /// Opt-in flag spelling, kept here so the runner's parse loop and
    /// the tests cannot drift apart.
    public static let flagMetal = "--gpu3d-metal"
    public static let flagTestMode = "--gpu3d-test-mode"

    /// A completion-fault selection for c2's deterministic knobs. These
    /// alter completion timing/identity only — they never generate
    /// substitute pixels (MetalRenderer.swift documents each knob).
    public enum TestMode: String, Equatable, CaseIterable {
        /// Withhold the fence until releaseCompletion() — a slow GPU.
        case delay
        /// Report ~fenceID so the held element can never match — proves
        /// full-u64 fence correlation.
        case wrongFence = "wrong-fence"
        /// Completions arrive but are never reported — the held element
        /// waits until reset/destroy retires it.
        case stall
    }

    /// Parsed `--gpu3d-*` state. Zero-value means untouched defaults.
    public struct Options: Equatable {
        /// --gpu3d-metal was given: attach the private render device.
        public var metal = false
        /// --gpu3d-test-mode <name>: SPIKE-only fault selection.
        public var testMode: TestMode? = nil
        public init() {}
        /// Anything at all was requested.
        public var requested: Bool { metal || testMode != nil }
    }

    /// Why the requested attachment is refused. Every case is a named
    /// sentence for the runner's fail(), never a silent fallback.
    public enum Rejection: Error, Equatable, CustomStringConvertible {
        /// --gpu3d-test-mode without --gpu3d-metal — no device exists to
        /// carry the fault knobs.
        case testModeWithoutMetal
        /// assemble() was called for options that never opted in.
        case attachmentNotRequested
        /// This binary was built without -DSPIKE, so the custom-virtio
        /// types (and therefore the fault knobs) do not exist in it.
        case requiresSPIKEBuild
        /// No Metal device, or the fixed MSL pipeline failed to build —
        /// the named blocker. Never advertise ready=1 for this.
        case metalBackendUnavailable

        public var description: String {
            switch self {
            case .testModeWithoutMetal:
                return "--gpu3d-test-mode requires --gpu3d-metal (the fault knobs ride the render device's Metal backend)"
            case .attachmentNotRequested:
                return "gpu3d attachment was not requested (--gpu3d-metal absent)"
            case .requiresSPIKEBuild:
                return "--gpu3d-metal/--gpu3d-test-mode require a SPIKE build (macOS 27 SDK custom-virtio types); rebuild with `swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE`. This binary cannot attach the requested device."
            case .metalBackendUnavailable:
                return "--gpu3d-metal: Metal backend initialization failed (no MTLDevice, or the pinned MSL pipeline did not build). No fallback — the run stops here."
            }
        }
    }

    /// Whether this binary carries the custom-virtio glue. The ordinary
    /// build (CI's macOS 26 SDK) compiles no custom-virtio types at all.
    public static var customVirtioSupportCompiled: Bool {
        #if SPIKE
        return true
        #else
        return false
        #endif
    }

    /// The named pre-attachment check — run before any VM configuration
    /// is touched. nil means the requested options may proceed (or
    /// nothing was requested).
    public static func rejection(for options: Options) -> Rejection? {
        if options.testMode != nil, !options.metal {
            return .testModeWithoutMetal
        }
        guard options.metal else { return nil }
        return customVirtioSupportCompiled ? nil : .requiresSPIKEBuild
    }

    /// Pure-Swift identity of one contributed custom-virtio device — the
    /// device-list comparison seam for `swift test` (no Virtualization
    /// types, so the complete list is comparable in the ordinary build).
    public struct DeviceDescriptor: Equatable {
        public var deviceID: UInt16
        /// Transitional PCI DID = 0x1040 + deviceID.
        public var pciDID: UInt16
        public var pciClass: UInt8
        public var pciSubclass: UInt8
        public var queueCount: UInt16
        /// optionalFeatures.subset0 — VIRGL bit 0, offered optionally.
        public var optionalFeaturesSubset0: UInt32
        /// The 16-byte virtio-gpu-shaped config space.
        public var deviceSpecificConfiguration: [UInt8]
    }

    /// The one private render+compute device this leaf can contribute
    /// (0x43 / PCI 1af4:1083, VIR1 v1 + VIC1 v1 — the #2160/#2409
    /// contract). The descriptor mirrors what makeConfiguration emits
    /// once a real Metal backend is attached — the only way --gpu3d-metal
    /// attaches at all — so num_capsets is the two-capset answer.
    public static let renderDeviceDescriptor = DeviceDescriptor(
        deviceID: GPU3DWire.deviceID,
        pciDID: GPU3DWire.pciDID,
        pciClass: GPU3DWire.pciClass,
        pciSubclass: GPU3DWire.pciSubclass,
        queueCount: GPU3DWire.queueCount,
        optionalFeaturesSubset0: GPU3DWire.featureVirgl,
        deviceSpecificConfiguration: GPU3DWire.deviceConfigBytes(numCapsets: 2))

    /// The complete custom-virtio device list after the options apply:
    /// absent flags leave `existing` untouched; the opt-in appends
    /// exactly one private render device.
    public static func customVirtioDevices(existing: [DeviceDescriptor],
                                           options: Options) -> [DeviceDescriptor] {
        options.metal ? existing + [renderDeviceDescriptor] : existing
    }

    /// Apply a parsed test mode to c2's deterministic completion knobs.
    /// Timing/identity only — pixels are never substituted.
    public static func applyTestMode(_ mode: TestMode, to renderer: GPU3DMetalRenderer) {
        switch mode {
        case .delay: renderer.withholdCompletion = true
        case .wrongFence: renderer.reportWrongFence = true
        case .stall: renderer.stallCompletion = true
        }
    }

    /// Build c2's real Metal backend or name the failure. A nil MTLDevice
    /// or a failed pinned-pipeline build is `.metalBackendUnavailable` —
    /// never a mock, never a software rasterizer, never a QEMU path.
    public static func metalBackend(
        memory: GPU3DMemory,
        device mtl: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) -> Result<GPU3DMetalRenderer, Rejection> {
        guard let renderer = GPU3DMetalRenderer(memory: memory, device: mtl) else {
            return .failure(.metalBackendUnavailable)
        }
        return .success(renderer)
    }
}

// MARK: - macOS 27 Virtualization.framework glue (SPIKE builds only)
//
// The assembled opt-in attachment: b2's GPU3DHostDevice + c2's real
// Metal backend + the guest-RAM seam the renderer's transfers DMA
// through. Everything below references custom-virtio types that exist
// only when the toolchain's SDK declares them (macOS 27 SDK, -DSPIKE).

#if SPIKE
import Virtualization

/// Guest-RAM access for the renderer's bounded transfers. The framework
/// maps guest physical memory through the live device once VZ creates it
/// (didCreateDevice) — `device` resolves lazily, so transfers asked for
/// before creation refuse rather than touch freed or wrong memory.
/// Mappings are created per call: no mapping is cached across a reset,
/// so stale frames can never alias a re-created guest.
@available(macOS 27.0, *)
public final class GPU3DGuestMemory: GPU3DMemory {
    /// The host device that owns the live VZCustomVirtioDevice. Weak —
    /// the attachment owns the host for the VM's whole lifetime.
    public weak var hostDevice: GPU3DHostDevice?

    /// Diagnostics: mapping count and unmapped-address refusals. Counts
    /// only — guest bytes are never reported.
    public private(set) var mappings = 0
    public private(set) var unmapped = 0

    public init() {}

    private func map(_ address: UInt64, length: Int) -> VZGuestMemoryMapping? {
        guard let device = hostDevice?.device, length > 0,
              let mapping = device.guestMemoryMapping(
                  atPhysicalAddress: address, length: length),
              mapping.length == length else {
            unmapped += 1
            return nil
        }
        mappings += 1
        return mapping
    }

    public func gpu3dRead(_ address: UInt64, count: Int) -> [UInt8]? {
        guard let mapping = map(address, length: count) else { return nil }
        return Array(UnsafeRawBufferPointer(start: mapping.mutableBytes, count: count))
    }

    public func gpu3dWrite(_ address: UInt64, bytes: [UInt8]) -> Bool {
        guard let mapping = map(address, length: bytes.count) else { return false }
        bytes.withUnsafeBytes { src in
            if let base = src.baseAddress, !src.isEmpty {
                mapping.mutableBytes.copyMemory(from: base, byteCount: bytes.count)
            }
        }
        return true
    }
}

/// The assembled `--gpu3d-metal` attachment: host device, real Metal
/// backend and guest-memory seam, wired together and held for the VM's
/// lifetime. `attach(to:)` APPENDS one configuration — the native 2D
/// GPU, the boot loader and any existing 0x42 channel are untouched.
@available(macOS 27.0, *)
public final class GPU3DRunnerAttachment {
    public let host: GPU3DHostDevice
    public let renderer: GPU3DMetalRenderer
    public let memory: GPU3DGuestMemory
    public let options: GPU3DRunnerConfiguration.Options

    private init(host: GPU3DHostDevice, renderer: GPU3DMetalRenderer,
                 memory: GPU3DGuestMemory, options: GPU3DRunnerConfiguration.Options) {
        self.host = host
        self.renderer = renderer
        self.memory = memory
        self.options = options
    }

    /// Build the full stack or name the failure. On failure NOTHING is
    /// attached and no backend ever claims ready=1. The Metal backend is
    /// initialized BEFORE the device exists, so a guest that sees the
    /// device sees a live renderer.
    ///
    /// Call only for an opted-in `options` (the runner gates the call on
    /// `options.metal`); a refusal-free assemble still requires it.
    public static func assemble(
        options: GPU3DRunnerConfiguration.Options,
        metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) -> Result<GPU3DRunnerAttachment, GPU3DRunnerConfiguration.Rejection> {
        if let why = GPU3DRunnerConfiguration.rejection(for: options) {
            return .failure(why)
        }
        guard options.metal else { return .failure(.attachmentNotRequested) }
        let memory = GPU3DGuestMemory()
        switch GPU3DRunnerConfiguration.metalBackend(memory: memory,
                                                     device: metalDevice) {
        case .failure(let why):
            return .failure(why)
        case .success(let renderer):
            let host = GPU3DHostDevice(backend: renderer)
            memory.hostDevice = host
            renderer.device = host.core
            if let mode = options.testMode {
                GPU3DRunnerConfiguration.applyTestMode(mode, to: renderer)
            }
            let attachment = GPU3DRunnerAttachment(host: host, renderer: renderer,
                                                   memory: memory, options: options)
            // M185a (issue #3176): every attach re-derives the virgl
            // coverage matrix through the real decoder — the printed
            // verdict lines are gate evidence, and a decoder drift
            // lands as a DRIFT line the live-gpu3d matrix leg fails on.
            VirglCoverage.printReport()
            return .success(attachment)
        }
    }

    /// Append this device's configuration to the custom-virtio list.
    /// Purely additive: `existing` devices and every other device array
    /// (graphics, serial, net, ...) are untouched.
    public func attach(to config: VZVirtualMachineConfiguration) {
        config.customVirtioDevices.append(host.makeConfiguration())
    }

    /// Identity line printed at attach: host device identity, the private
    /// profiles and the REAL Metal device name — never token contents.
    public func banner() -> String {
        let mode = options.testMode.map { ", test-mode=\($0.rawValue) (SPIKE fault knob)" } ?? ""
        return "gpu3d-metal: ENABLED (M102d3 #2168) — custom-virtio deviceID 0x43 (PCI 1af4:1083), class 0x03/0x00, 2 queues, VIR1 capset 0x56495231 v1 + VIC1 capset 0x56494331 v1 (M111b #2409); backend Metal \"\(renderer.metalDeviceName)\" ready=1 compute=\(renderer.gpu3dComputeReady ? 1 : 0) (real pipeline initialized)\(mode)"
    }

    /// Lifecycle counters at stop — observed numbers only.
    public func counters() -> String {
        "gpu3d: resets=\(host.core.resetCount) refusals=\(host.core.refusalCount) retired-pending=\(host.core.retiredPending) stale-fences=\(host.core.staleCompletions); renderer draws=\(renderer.drawsEncoded) gpu-completions=\(renderer.gpuCompletions) submit-rejections=\(renderer.submitRejections) orphaned=\(renderer.orphanedCompletions) compute-submits=\(renderer.computeSubmits) compute-refusals=\(renderer.computeRefusals); guest-mem mappings=\(memory.mappings) unmapped=\(memory.unmapped)"
    }
}
#endif
