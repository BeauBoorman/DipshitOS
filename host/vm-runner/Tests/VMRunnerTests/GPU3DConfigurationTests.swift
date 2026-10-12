// GPU3DConfigurationTests.swift — M102d3 (issue #2168): contract tests
// for the runner-attachment leaf (Sources/VMGPU3D/RunnerConfiguration.swift).
//
//   * Device lists are compared COMPLETELY against an independent table
//     written down here — absent flags leave the list byte-identical,
//     the opt-in appends exactly one private render device and never
//     replaces the native GPU or touches the boot loader.
//   * Failed Metal initialization is the named refusal
//     .metalBackendUnavailable — nothing ever advertises ready=1 for a
//     backend that did not initialize, and no software/QEMU substitute
//     exists to fall back to.
//   * The ordinary build rejects the SPIKE-only fault knobs by name;
//     under -DSPIKE the same options select c2's real hooks.
//   * Revert-fails seam exercised by the owner: removing the opt-in
//     append turns testOptInAppendsExactlyOnePrivateDevice red while
//     testAbsentFlagsLeaveDeviceListUntouched stays green.
import XCTest
@testable import VMGPU3D

final class GPU3DConfigurationTests: XCTestCase {
    private typealias RC = GPU3DRunnerConfiguration

    // MARK: - Independent expected device table (#2160 contract)

    /// The existing 0x42 custom channel, written down here so a list
    /// comparison proves the opt-in left it alone.
    private var existingDevice: RC.DeviceDescriptor {
        RC.DeviceDescriptor(deviceID: 0x42, pciDID: 0x1082,
                            pciClass: 0x00, pciSubclass: 0x00,
                            queueCount: 2, optionalFeaturesSubset0: 0,
                            deviceSpecificConfiguration: [])
    }

    /// The private render device, written down independently of the
    /// leaf's constants (deviceID 0x43, PCI 1af4:1083, VIRGL offered
    /// optionally, 16-byte config space: 0 scanouts, 1 capset).
    private var expectedRenderDevice: RC.DeviceDescriptor {
        RC.DeviceDescriptor(deviceID: 0x43, pciDID: 0x1083,
                            pciClass: 0x03, pciSubclass: 0x00,
                            queueCount: 2, optionalFeaturesSubset0: 0x1,
                            deviceSpecificConfiguration: [
                                0, 0, 0, 0, 0, 0, 0, 0,
                                0, 0, 0, 0, 1, 0, 0, 0,
                            ])
    }

    // MARK: - Device list behavior (the revert-fails assertions)

    /// Control: no flags -> the contributed list is byte-identical to
    /// the input. Default boot behavior stays exactly what it was.
    func testAbsentFlagsLeaveDeviceListUntouched() {
        let existing = [existingDevice]
        XCTAssertEqual(RC.customVirtioDevices(existing: existing,
                                              options: RC.Options()),
                       existing)
        XCTAssertEqual(RC.customVirtioDevices(existing: [],
                                              options: RC.Options()),
                       [])
    }

    /// The enabled-device assertion: --gpu3d-metal appends exactly one
    /// private render device at the END of the list — the existing 0x42
    /// channel is not moved, replaced or re-identified.
    func testOptInAppendsExactlyOnePrivateDevice() {
        var options = RC.Options()
        options.metal = true
        let list = RC.customVirtioDevices(existing: [existingDevice],
                                          options: options)
        XCTAssertEqual(list.count, 2, "opt-in must add exactly one device")
        XCTAssertEqual(list[0], existingDevice, "existing device changed")
        XCTAssertEqual(list[1], expectedRenderDevice,
                       "the appended device is not the pinned VIR1 identity")
    }

    /// The same opt-in on an empty list contributes exactly the private
    /// device — the runner can attach it without --custom-virtio.
    func testOptInOnEmptyListContributesOnlyRenderDevice() {
        var options = RC.Options()
        options.metal = true
        XCTAssertEqual(RC.customVirtioDevices(existing: [], options: options),
                       [expectedRenderDevice])
    }

    // MARK: - Named rejections (parse-level and attachment-level)

    /// A fault knob without the device is a named usage error.
    func testTestModeWithoutMetalIsNamed() {
        var options = RC.Options()
        options.testMode = .stall
        XCTAssertEqual(RC.rejection(for: options), .testModeWithoutMetal)
    }

    /// The mode vocabulary is exactly the three c2 knobs — anything else
    /// fails the runner's rawValue conversion with the mode echoed.
    func testTestModeVocabularyIsClosed() {
        XCTAssertEqual(RC.TestMode(rawValue: "delay"), .delay)
        XCTAssertEqual(RC.TestMode(rawValue: "wrong-fence"), .wrongFence)
        XCTAssertEqual(RC.TestMode(rawValue: "stall"), .stall)
        for bogus in ["", "none", "delayed", "wrongfence", "STALL", "0"] {
            XCTAssertNil(RC.TestMode(rawValue: bogus), "'\(bogus)' parsed")
        }
        XCTAssertEqual(RC.TestMode.allCases.map(\.rawValue),
                       ["delay", "wrong-fence", "stall"])
    }

    /// Ordinary build: both flags parse, and attachment is refused by
    /// NAME (the custom-virtio types are not compiled in). SPIKE build:
    /// the same options are accepted and select real hooks below.
    func testBuildGateNamesTheRefusal() {
        var metalOnly = RC.Options()
        metalOnly.metal = true
        var withFault = RC.Options()
        withFault.metal = true
        withFault.testMode = .delay
        #if SPIKE
        XCTAssertTrue(RC.customVirtioSupportCompiled)
        XCTAssertNil(RC.rejection(for: metalOnly))
        XCTAssertNil(RC.rejection(for: withFault))
        #else
        XCTAssertFalse(RC.customVirtioSupportCompiled)
        XCTAssertEqual(RC.rejection(for: metalOnly), .requiresSPIKEBuild,
                       "ordinary build must reject --gpu3d-metal by name")
        XCTAssertEqual(RC.rejection(for: withFault), .requiresSPIKEBuild,
                       "ordinary build must reject the fault knobs by name")
        #endif
    }

    /// Every rejection prints a sentence that names the flags involved —
    /// the runner relays it verbatim through fail().
    func testRejectionsNameThemselves() {
        let cases: [RC.Rejection] = [.testModeWithoutMetal, .attachmentNotRequested,
                                     .requiresSPIKEBuild, .metalBackendUnavailable]
        for r in cases {
            let text = r.description
            XCTAssertTrue(text.contains("gpu3d") || text.contains("SPIKE"),
                          "rejection text does not name the surface: \(text)")
            XCTAssertGreaterThan(text.count, 20)
        }
    }

    // MARK: - Metal backend honesty

    /// No Metal device -> the named refusal, and the device it could
    /// have served still reports ready=0 (the null backend is honest).
    /// Nothing manufactures ready=1 without a real initialized pipeline.
    func testFailedMetalInitCannotAdvertiseReady() {
        let memory = FlatRAM(bytes: 0x1000)
        switch RC.metalBackend(memory: memory, device: nil) {
        case .success:
            XCTFail("a nil MTLDevice produced a backend")
        case .failure(let why):
            XCTAssertEqual(why, .metalBackendUnavailable)
        }
        // The capset payload's ready word (word 8) is 0 with no backend.
        let payload = GPU3DWire.capsetPayload(ready: false)
        XCTAssertEqual(payload.count, 32)
        XCTAssertEqual(Array(payload[28..<32]), [0, 0, 0, 0])
    }

    /// A real Metal host produces the real backend — ready=1 only ever
    /// rides on an actual initialized pipeline (device identity printed
    /// for the evidence comment).
    func testRealMetalBackendInitializesOrNamesTheBlocker() {
        let memory = FlatRAM(bytes: 0x1000)
        switch RC.metalBackend(memory: memory) {
        case .failure(let why):
            // A Metal-less host is legal; the refusal is the contract.
            XCTAssertEqual(why, .metalBackendUnavailable)
        case .success(let renderer):
            print("GPU3D runner Metal device: \(renderer.metalDeviceName)")
            XCTAssertTrue(renderer.gpu3dReady)
        }
    }

    /// Test modes set exactly the expected c2 hook and nothing else —
    /// deterministic timing/identity knobs, never pixel substitution.
    func testFaultKnobsSelectExpectedC2Hooks() throws {
        let memory = FlatRAM(bytes: 0x1000)
        let modes: [(RC.TestMode, KeyPath<GPU3DMetalRenderer, Bool>,
                     KeyPath<GPU3DMetalRenderer, Bool>, KeyPath<GPU3DMetalRenderer, Bool>)] = [
            (.delay, \.withholdCompletion, \.reportWrongFence, \.stallCompletion),
            (.wrongFence, \.reportWrongFence, \.withholdCompletion, \.stallCompletion),
            (.stall, \.stallCompletion, \.withholdCompletion, \.reportWrongFence),
        ]
        for (mode, on, offA, offB) in modes {
            let fresh = try XCTUnwrap(GPU3DMetalRenderer(memory: memory),
                                      "no Metal device on this host (named blocker)")
            RC.applyTestMode(mode, to: fresh)
            XCTAssertTrue(fresh[keyPath: on], "\(mode) did not set its knob")
            // The other two knobs stay off and the fence-ordering seam
            // is untouched.
            XCTAssertFalse(fresh[keyPath: offA], "\(mode) set a second knob")
            XCTAssertFalse(fresh[keyPath: offB], "\(mode) set a second knob")
            XCTAssertTrue(fresh.fenceCompletionIsGPUCompletion)
        }
    }

    // MARK: - Lifecycle: reset/stop retire once, no double-free

    /// A deferred element held at reset returns exactly once with an
    /// honest error; a following stop retires the backend exactly once
    /// more — never double-returned, never double-retired.
    func testResetAndStopRetireExactlyOnce() {
        let backend = GPU3DTestBackend()
        let device = GPU3DDevice(backend: backend)

        let ctx = FakeElement(ctxCreateRequest(1))
        let sub = FakeElement(fencedSubmitRequest(ctx: 1))
        device.handleQueueNotification(FakeQueue([ctx, sub]))
        XCTAssertFalse(sub.returned, "deferred submit must hold the element")

        device.reset()
        XCTAssertEqual(backend.resets, 1, "one reset must retire once")
        XCTAssertEqual(sub.returns, 1, "held element returned more than once")
        XCTAssertEqual(responseType(sub), GPU3DWire.respErrUnspec)

        device.shutdown() // VZ willStop path — the VM is stopping
        XCTAssertEqual(backend.resets, 2, "stop must retire exactly once more")
        XCTAssertEqual(sub.returns, 1, "stop re-returned a retired element")
        XCTAssertTrue(device.liveContextIDs.isEmpty)
    }

    // MARK: - Queue fakes (same seam as the b2/c2 suites)

    final class FlatRAM: GPU3DMemory {
        var mem: [UInt8]
        init(bytes: Int) { mem = [UInt8](repeating: 0, count: bytes) }
        func gpu3dRead(_ address: UInt64, count: Int) -> [UInt8]? {
            let a = Int(address)
            guard a >= 0, a + count <= mem.count else { return nil }
            return Array(mem[a..<(a + count)])
        }
        func gpu3dWrite(_ address: UInt64, bytes: [UInt8]) -> Bool {
            let a = Int(address)
            guard a >= 0, a + bytes.count <= mem.count else { return false }
            mem.replaceSubrange(a..<(a + bytes.count), with: bytes)
            return true
        }
    }

    final class FakeElement: GPU3DQueueElement {
        let request: [UInt8]
        private(set) var written: [UInt8] = []
        private(set) var returns = 0
        var returned: Bool { returns > 0 }
        init(_ request: [UInt8]) { self.request = request }
        var gpu3dReadByteCount: Int { request.count }
        var gpu3dWriteByteCount: Int { 8192 }
        func gpu3dReadAll() -> [UInt8] { request }
        func gpu3dWrite(_ bytes: [UInt8]) -> Bool {
            written.append(contentsOf: bytes); return true
        }
        func gpu3dReturn() { returns += 1 }
    }

    final class FakeQueue: GPU3DQueue {
        var elements: [FakeElement]
        init(_ elements: [FakeElement]) { self.elements = elements }
        var gpu3dQueueIndex: Int { 0 }
        func gpu3dNextElement() -> GPU3DQueueElement? {
            elements.isEmpty ? nil : elements.removeFirst()
        }
    }

    private func header(_ type: UInt32, ctx: UInt32, fence: UInt64 = 0,
                        fenced: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<4 { out.append(UInt8((type >> (8 * i)) & 0xff)) }
        let flags: UInt32 = fenced ? GPU3DWire.flagFence : 0
        for i in 0..<4 { out.append(UInt8((flags >> (8 * i)) & 0xff)) }
        for i in 0..<8 { out.append(UInt8((fence >> (8 * i)) & 0xff)) }
        for i in 0..<4 { out.append(UInt8((ctx >> (8 * i)) & 0xff)) }
        out += [0, 0, 0, 0]
        return out
    }

    private func push32(_ v: UInt32, into out: inout [UInt8]) {
        for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
    }

    private func ctxCreateRequest(_ ctx: UInt32) -> [UInt8] {
        var r = header(GPU3DWire.cmdCtxCreate, ctx: ctx)
        push32(3, into: &r)
        push32(0, into: &r)
        r += Array("ctx".utf8) + [UInt8](repeating: 0, count: 61)
        return r
    }

    private func fencedSubmitRequest(ctx: UInt32) -> [UInt8] {
        // A 4-byte NOP-only stream (VirGL NOP = a zero word) — the
        // envelope's minimum legal size is 4 and the test backend never
        // decodes the payload.
        var r = header(GPU3DWire.cmdSubmit3D, ctx: ctx,
                       fence: 0xD3, fenced: true)
        push32(4, into: &r)
        push32(0, into: &r)
        push32(0, into: &r) // the NOP command word
        return r
    }

    private func responseType(_ el: FakeElement) -> UInt32 {
        guard el.written.count >= 4 else { return 0xffff_ffff }
        return UInt32(el.written[0]) | UInt32(el.written[1]) << 8
            | UInt32(el.written[2]) << 16 | UInt32(el.written[3]) << 24
    }
}

// MARK: - SPIKE build: the real VZ attachment
//
// With -DSPIKE (macOS 27 SDK) the tests below attach the assembled
// device to a real VZVirtualMachineConfiguration and prove the wiring
// the runner performs: one appended custom-virtio configuration, the
// real Metal backend behind the host device, the guest-memory seam
// resolving through it, and lifecycle counters that report numbers.

#if SPIKE
import Virtualization

extension GPU3DConfigurationTests {

    /// Opt-in on a REAL configuration: one device appended, the existing
    /// custom device and the native GPU/boot loader untouched.
    @available(macOS 27.0, *)
    func testAttachAppendsToRealVZConfiguration() throws {
        var options = RC.Options()
        options.metal = true
        let attachment = try XCTUnwrap(
            GPU3DRunnerAttachment.assemble(options: options).successOrNil(),
            "assemble failed on a Metal host")

        let config = VZVirtualMachineConfiguration()
        // Stand-in for the existing 0x42 channel + a native 2D GPU:
        // both must survive the attachment untouched.
        let prior = VZCustomVirtioDeviceConfiguration()
        prior.deviceID = 0x42
        prior.virtioQueueCount = 2
        config.customVirtioDevices = [prior]
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        config.graphicsDevices = [gpu]
        let efi = VZEFIBootLoader()
        config.bootLoader = efi

        attachment.attach(to: config)

        XCTAssertEqual(config.customVirtioDevices.count, 2,
                       "opt-in must append exactly one device")
        XCTAssertIdentical(config.customVirtioDevices[0], prior,
                           "existing custom device was replaced")
        let added = config.customVirtioDevices[1]
        XCTAssertEqual(added.deviceID, 0x43)
        XCTAssertEqual(added.pciClassID, 0x03)
        XCTAssertEqual(added.pciSubclassID, 0x00)
        XCTAssertEqual(added.virtioQueueCount, 2)
        // VZ unions its own transport bits into optionalFeatures on
        // readback (observed: bits 28-29 set, subset0 = 0x30000001).
        // The bit we own is bit 0 — the optional VIRGL offer.
        XCTAssertEqual(added.optionalFeatures.subset0 & 0x1, 0x1)
        XCTAssertEqual(added.deviceSpecificConfiguration?.configurationData,
                       Data(expectedRenderDevice.deviceSpecificConfiguration))
        XCTAssertIdentical(config.graphicsDevices.first, gpu,
                           "native 2D GPU was replaced")
        XCTAssertIdentical(config.bootLoader, efi, "boot loader changed")
    }

    /// The assembled attachment is the real wiring: b2's host device
    /// serving c2's Metal backend, the memory seam bound to the host,
    /// and an identity banner that reports names — never secrets.
    @available(macOS 27.0, *)
    func testAssembleWiresRealBackendAndReportsIdentity() throws {
        var options = RC.Options()
        options.metal = true
        let attachment = try XCTUnwrap(
            GPU3DRunnerAttachment.assemble(options: options).successOrNil(),
            "assemble failed on a Metal host")
        XCTAssertTrue(attachment.host.core.backend === attachment.renderer)
        XCTAssertTrue(attachment.renderer.device === attachment.host.core)
        XCTAssertTrue(attachment.memory.hostDevice === attachment.host)
        XCTAssertTrue(attachment.renderer.gpu3dReady)

        let banner = attachment.banner()
        XCTAssertTrue(banner.contains("1af4:1083"), banner)
        XCTAssertTrue(banner.contains("VIR1"), banner)
        XCTAssertTrue(banner.contains("ready=1"), banner)
        XCTAssertTrue(banner.contains(attachment.renderer.metalDeviceName),
                      "banner must name the real Metal device: \(banner)")
        print(banner)
        // Lifecycle counters report numbers only.
        XCTAssertTrue(attachment.counters().contains("resets=0"),
                      attachment.counters())
        attachment.host.core.reset()
        XCTAssertTrue(attachment.counters().contains("resets=1"),
                      "reset must retire renderer state once")
    }

    /// SPIKE fault selection reaches c2's real knobs on the assembled
    /// backend — the ordinary build never gets this far.
    @available(macOS 27.0, *)
    func testAssembleAppliesTestModeToRealBackend() throws {
        var options = RC.Options()
        options.metal = true
        options.testMode = .stall
        let attachment = try XCTUnwrap(
            GPU3DRunnerAttachment.assemble(options: options).successOrNil(),
            "assemble failed on a Metal host")
        XCTAssertTrue(attachment.renderer.stallCompletion)
        XCTAssertFalse(attachment.renderer.withholdCompletion)
        XCTAssertFalse(attachment.renderer.reportWrongFence)
    }

    /// No Metal device -> assemble is the named refusal; nothing is
    /// attached, no ready=1 is possible.
    @available(macOS 27.0, *)
    func testAssembleWithoutMetalDeviceIsNamed() {
        var options = RC.Options()
        options.metal = true
        switch GPU3DRunnerAttachment.assemble(options: options, metalDevice: nil) {
        case .success:
            XCTFail("a nil MTLDevice produced an attachment")
        case .failure(let why):
            XCTAssertEqual(why, .metalBackendUnavailable)
        }
    }

    /// Before VZ creates the device the memory seam refuses honestly —
    /// an unmapped guest address is nil/false, never fabricated bytes.
    @available(macOS 27.0, *)
    func testGuestMemoryRefusesBeforeDeviceExists() throws {
        var options = RC.Options()
        options.metal = true
        let attachment = try XCTUnwrap(
            GPU3DRunnerAttachment.assemble(options: options).successOrNil(),
            "assemble failed on a Metal host")
        XCTAssertNil(attachment.host.device, "device exists before VZ creates it")
        XCTAssertNil(attachment.memory.gpu3dRead(0x1000, count: 16))
        XCTAssertFalse(attachment.memory.gpu3dWrite(0x1000, bytes: [1, 2, 3, 4]))
        XCTAssertEqual(attachment.memory.unmapped, 2)
        XCTAssertEqual(attachment.memory.mappings, 0)
    }
}

private extension Result {
    func successOrNil() -> Success? {
        if case .success(let v) = self { return v }
        return nil
    }
}
#endif
