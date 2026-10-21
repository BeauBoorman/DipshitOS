import AppKit
import CryptoKit
import XCTest
import VMAppKit
import VMProfile

/// M120c (#2560): the machine lifecycle model is the part `swift test`
/// pins — the five Machine-menu verbs' dispatch, live enablement
/// (posture absent → `disabled`, driver refusal → `failed` with the
/// wire code), receipt tails, and the staged-update banner. No VM, no
/// window server: the VZ drivers are stubs returning the wire verdict
/// vocabulary, the share/base/profile fixtures are tempdir files.
final class HostMachineTests: XCTestCase {
    private final class Sink {
        var lines: [String] = []
    }

    /// The fleet's pinned Ed25519 test seed — the same RFC 8032 §7.1
    /// TEST 1 OSUpdateTests signs staged sets with.
    private let testSeed = Data([
        0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60,
        0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
        0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19,
        0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
    ])

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        super.tearDown()
    }

    /// A created tempdir, queued for teardown — the model's share
    /// resolution requires the armed dir to exist (the no_state
    /// posture), so the fixture is real.
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeBus(_ sink: Sink) -> HostCommandBus {
        HostCommandBus { sink.lines.append($0) }
    }

    private func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Compose a signed UPDATE/ under `share` — the OSUpdateTests
    /// fixture, shrunk: three members + a manifest signed over its own
    /// bytes with the pinned seed.
    @discardableResult
    private func stageUpdate(in share: URL, version: String = "test-b",
                             image: Data = Data("new-base".utf8)) throws -> URL {
        let fm = FileManager.default
        let update = share.appendingPathComponent("UPDATE")
        try fm.createDirectory(at: update, withIntermediateDirectories: true)
        let k = Data("KRN2".utf8)
        let e = Data("EFI2".utf8)
        try k.write(to: update.appendingPathComponent("KERNEL.BIN"))
        try e.write(to: update.appendingPathComponent("BOOTAA64.EFI"))
        try image.write(to: update.appendingPathComponent("OS.IMG"))
        let mf = """
        #v1 os-update
        OS.IMG\tkind=image\tsha256=\(sha256Hex(image))\tbytes=\(image.count)\tversion=\(version)
        KERNEL.BIN\tkind=member\tsha256=\(sha256Hex(k))\tbytes=\(k.count)\tesp=KERNEL.BIN
        BOOTAA64.EFI\tkind=member\tsha256=\(sha256Hex(e))\tbytes=\(e.count)\tesp=EFI/BOOT/BOOTAA64.EFI

        """
        let mfData = Data(mf.utf8)
        try mfData.write(to: update.appendingPathComponent("UPDATE.MF"))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: testSeed)
        try key.signature(for: mfData).write(to: update.appendingPathComponent("UPDATE.SIG"))
        return update
    }

    private var pubHex: String {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: testSeed)
        return key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// A minted .virelaivm fixture — manifest + share/ + saved-state/ —
    /// the armed-machine half of the suspend/snapshot posture.
    private func mintProfile(in dir: URL, name: String = "test") throws -> VMProfile {
        try VMProfile.create(
            at: dir.appendingPathComponent("\(name).\(VMProfile.bundleExtension)",
                                           isDirectory: true),
            name: name)
    }

    // MARK: - bare-bus posture

    func testLifecycleVerbsRegisteredAndDisabledOnFlagRun() {
        let sink = Sink()
        let bus = makeBus(sink)
        bus.machine.arguments = ["VMRunner"] // no profile, no share, no base
        for verb in [HostCommand.suspend, .snapshot, .applyUpdate,
                     .rollbackUpdate, .revealShare] {
            XCTAssertTrue(bus.isRegistered(verb), "\(verb.rawValue) must be a registered verb")
            XCTAssertFalse(bus.isEnabled(verb), "\(verb.rawValue) must be disabled without its posture")
            XCTAssertEqual(bus.dispatch(verb), .disabled)
        }
        XCTAssertEqual(sink.lines, [
            "host-ui: cmd=suspend state=disabled save=unsupported none",
            "host-ui: cmd=snapshot state=disabled save=unsupported none",
            "host-ui: cmd=apply-update state=disabled staged=0 none",
            "host-ui: cmd=rollback-update state=disabled prev=0 none",
            "host-ui: cmd=reveal-share state=disabled share=none none",
        ])
    }

    // MARK: - suspend

    func testSuspendDispatchEnablementAndRefusal() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let model = bus.machine
        model.arguments = ["VMRunner"]
        let profile = try mintProfile(in: tempDir())
        model.profileURL = profile.url
        var running = true
        var capable = true
        var calls = 0
        var verdict: String? = nil
        model.saveCapable = { capable }
        model.vmRunning = { running }
        model.suspendDriver = {
            calls += 1
            return verdict
        }
        // No driver before arming → disabled; then every leg of the
        // enablement is its own toggle.
        model.suspendDriver = nil
        XCTAssertFalse(model.canSuspend)
        model.suspendDriver = { calls += 1; return verdict }
        XCTAssertTrue(model.canSuspend)
        capable = false
        XCTAssertFalse(model.canSuspend)
        capable = true
        running = false
        XCTAssertFalse(model.canSuspend)
        running = true
        // No profile → the no_state posture greys the verb.
        model.profileURL = nil
        XCTAssertNil(model.resolvedSavedStateDir())
        XCTAssertFalse(model.canSuspend)
        model.profileURL = profile.url
        XCTAssertTrue(model.canSuspend)

        // Accept → performed; the receipt carries the armed posture +
        // the suspended word.
        XCTAssertEqual(bus.dispatch(.suspend), .performed)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=suspend state=performed save=armed suspended")
        // A wire refusal → failed, the code named.
        verdict = "save_failed"
        XCTAssertEqual(bus.dispatch(.suspend), .failed)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=suspend state=failed save=armed error error=refuse=save_failed")
        // A stopped machine greys the verb — disabled, not dispatched —
        // and the receipt still names the last live reason (the M114b
        // detail-on-disabled rule).
        running = false
        XCTAssertEqual(bus.dispatch(.suspend), .disabled)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=suspend state=disabled save=stopped error error=refuse=save_failed")
    }

    // MARK: - snapshot

    func testSnapshotDispatchAndCollisionFreeNaming() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let model = bus.machine
        let share = tempDir()
        model.shareDir = share
        model.saveCapable = { true }
        model.vmRunning = { true }
        var saved: [String] = []
        model.snapshotDriver = { name in
            saved.append(name)
            // The real driver writes <name>.vzsave; mint it so the next
            // dispatch exercises the collision path.
            let snaps = share.appendingPathComponent("SNAPSHOTS", isDirectory: true)
            try? FileManager.default.createDirectory(at: snaps, withIntermediateDirectories: true)
            try? Data().write(to: snaps.appendingPathComponent(name + ".vzsave"))
            return nil
        }
        XCTAssertTrue(model.canSnapshot)
        XCTAssertEqual(bus.dispatch(.snapshot), .performed)
        XCTAssertEqual(sink.lines.last?.hasPrefix(
            "host-ui: cmd=snapshot state=performed save=armed name=menu-"), true)
        XCTAssertEqual(model.snapshotCount, 1)
        // Same-second second dispatch mints a fresh name — never an
        // `exists` consent refusal.
        XCTAssertEqual(bus.dispatch(.snapshot), .performed)
        XCTAssertEqual(saved.count, 2)
        XCTAssertNotEqual(saved[0], saved[1])
        XCTAssertTrue(saved[1].hasPrefix("menu-"))
        XCTAssertEqual(model.snapshotCount, 2)
        // The collision path itself is deterministic: in a fresh share
        // the first offer is the plain stamp; plant it and the next
        // offer carries -2.
        let fresh = tempDir()
        let first = model.nextSnapshotName(in: fresh)
        let snapsDir = fresh.appendingPathComponent("SNAPSHOTS", isDirectory: true)
        try FileManager.default.createDirectory(at: snapsDir, withIntermediateDirectories: true)
        try Data().write(to: snapsDir.appendingPathComponent(first + ".vzsave"))
        XCTAssertEqual(model.nextSnapshotName(in: fresh), first + "-2")
        // A refusal code surfaces as failed, not performed.
        model.snapshotDriver = { _ in "exists" }
        XCTAssertEqual(bus.dispatch(.snapshot), .failed)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=snapshot state=failed save=armed error error=refuse=exists")
    }

    func testSnapshotEnablementLegs() {
        let sink = Sink()
        let bus = makeBus(sink)
        let model = bus.machine
        model.arguments = ["VMRunner"]
        model.snapshotDriver = { _ in nil }
        // No share → disabled even on a capable, running posture.
        model.saveCapable = { true }
        model.vmRunning = { true }
        XCTAssertFalse(model.canSnapshot)
        model.shareDir = tempDir()
        XCTAssertTrue(model.canSnapshot)
        model.vmRunning = { false }
        XCTAssertFalse(model.canSnapshot)
        model.vmRunning = { true }
        model.saveCapable = { false }
        XCTAssertFalse(model.canSnapshot)
    }

    // MARK: - apply / rollback

    func testApplyUpdateSwapsTheBaseThroughTheBus() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let model = bus.machine
        model.arguments = ["VMRunner"]
        let dir = tempDir()
        let share = dir.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("base.img")
        try Data("old-base".utf8).write(to: base)
        model.shareDir = share
        model.baseImageURL = base
        model.updateKeyHex = pubHex
        // Nothing staged → disabled, and the staged=0 leg says why.
        XCTAssertFalse(model.canApplyUpdate)
        XCTAssertEqual(bus.dispatch(.applyUpdate), .disabled)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=apply-update state=disabled staged=0 none")
        // Stage the signed set — the same files GOUPD writes.
        try stageUpdate(in: share, version: "m120c-a")
        XCTAssertNotNil(model.stagedUpdate)
        XCTAssertEqual(model.stagedVersion, "m120c-a")
        XCTAssertTrue(model.canApplyUpdate)
        XCTAssertEqual(bus.dispatch(.applyUpdate), .performed)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=apply-update state=performed staged=0 version=m120c-a")
        // The swap landed: new base in place, old base at .prev, the
        // staged set consumed (the strip's truth flips with it).
        XCTAssertEqual(try String(contentsOf: base), "new-base")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("base.img.prev").path))
        XCTAssertNil(model.stagedUpdate)
        XCTAssertFalse(model.canApplyUpdate)
        // The applied base is now the rollback target.
        XCTAssertTrue(model.canRollbackUpdate)
        XCTAssertEqual(bus.dispatch(.rollbackUpdate), .performed)
        XCTAssertEqual(sink.lines.last?.hasPrefix(
            "host-ui: cmd=rollback-update state=performed prev=1 restored sha256="), true)
        XCTAssertEqual(try String(contentsOf: base), "old-base")
    }

    /// The gate harness prepends its own --overlay-base before the leg's
    /// (tools/lib/gate-run.sh GATE_RUNNER_ARGS), and the runner's flag
    /// loop resolves a repeated flag LAST-wins — the boot attaches the
    /// leg's base. The model must resolve the same occurrence: the
    /// first-match read this regressed from swapped the harness default
    /// while the booted base stayed untouched (the receipt still read
    /// `applied`).
    func testApplyUpdateResolvesLastOverlayBaseFlag() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let model = bus.machine
        let dir = tempDir()
        let share = dir.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let harnessBase = dir.appendingPathComponent("harness.img")
        let legBase = dir.appendingPathComponent("base.img")
        try Data("harness-base".utf8).write(to: harnessBase)
        try Data("old-base".utf8).write(to: legBase)
        try stageUpdate(in: share, version: "m120c-dup")
        model.arguments = ["VMRunner",
                           "--overlay-base", harnessBase.path,
                           "--virtio-fs", share.path,
                           "--overlay-base", legBase.path,
                           "--update-key", pubHex]
        XCTAssertEqual(model.resolvedBaseImage()?.path, legBase.path)
        XCTAssertTrue(model.canApplyUpdate)
        XCTAssertEqual(bus.dispatch(.applyUpdate), .performed)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=apply-update state=performed staged=0 version=m120c-dup")
        // The swap lands on the leg's base — the harness default is
        // never the target.
        XCTAssertEqual(try String(contentsOf: legBase), "new-base")
        XCTAssertEqual(try String(contentsOf: harnessBase), "harness-base")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("base.img.prev").path))
    }

    func testApplyUpdateRefusesByName() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let model = bus.machine
        model.arguments = ["VMRunner"]
        let dir = tempDir()
        let share = dir.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("base.img")
        try Data("old-base".utf8).write(to: base)
        try stageUpdate(in: share)
        model.shareDir = share
        model.baseImageURL = base
        // Staged but no trust pin → disabled, not failed.
        XCTAssertNotNil(model.stagedUpdate)
        XCTAssertNil(model.resolvedUpdateKey())
        XCTAssertFalse(model.canApplyUpdate)
        // The wrong pin still gates the verb OFF — the dispatch never
        // reaches verify (canApplyUpdate needs a resolvable key, but a
        // wrong-shaped hex is no key at all).
        model.updateKeyHex = "deadbeef"
        XCTAssertFalse(model.canApplyUpdate)
        // A real-but-wrong key: enablement holds (a pin resolves), the
        // VERIFY refuses — failed with sig_invalid named.
        model.updateKeyHex = String(repeating: "ab", count: 32)
        XCTAssertTrue(model.canApplyUpdate)
        XCTAssertEqual(bus.dispatch(.applyUpdate), .failed)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=apply-update state=failed staged=1 error error=sig_invalid")
        XCTAssertEqual(try String(contentsOf: base), "old-base")
    }

    func testRollbackNeedsPrev() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let model = bus.machine
        model.arguments = ["VMRunner"]
        let dir = tempDir()
        let base = dir.appendingPathComponent("base.img")
        try Data("old-base".utf8).write(to: base)
        model.baseImageURL = base
        XCTAssertFalse(model.canRollbackUpdate)
        XCTAssertEqual(bus.dispatch(.rollbackUpdate), .disabled)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=rollback-update state=disabled prev=0 none")
    }

    // MARK: - reveal-share

    func testRevealShareDispatchesTheArmedShare() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let model = bus.machine
        model.arguments = ["VMRunner"]
        let share = tempDir().appendingPathComponent("theshare", isDirectory: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        var revealed: [URL] = []
        model.reveal = { revealed.append($0); return true }
        model.shareDir = share
        XCTAssertTrue(model.canRevealShare)
        XCTAssertEqual(bus.dispatch(.revealShare), .performed)
        XCTAssertEqual(revealed, [share])
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=reveal-share state=performed share=theshare revealed")
        // The argv resolution seams: --virtio-fs and --cvc-file both
        // resolve, flag order is the runner's own precedence.
        model.shareDir = nil
        model.arguments = ["VMRunner", "--virtio-fs", share.path]
        XCTAssertEqual(model.resolvedShareDir()?.path, share.path)
        model.arguments = ["VMRunner", "--cvc-file", share.path]
        XCTAssertEqual(model.resolvedShareDir()?.path, share.path)
        // A missing dir is the no_state posture, not a destination.
        model.arguments = ["VMRunner", "--virtio-fs",
                           share.appendingPathComponent("absent").path]
        XCTAssertNil(model.resolvedShareDir())
        XCTAssertFalse(model.canRevealShare)
    }

    // MARK: - menu + banner surfaces

    func testMachineMenuCarriesTheLifecycleVerbs() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let bar = HostMenuBar.build(bus: bus)
        func leaf(_ title: String) throws -> NSMenuItem {
            let machine = try XCTUnwrap(bar.items.first { $0.submenu?.title == "Machine" }?.submenu)
            return try XCTUnwrap(machine.items.first { $0.title == title },
                                 "Machine menu must carry '\(title)'")
        }
        XCTAssertEqual(try leaf("Suspend").representedObject as? HostCommand, .suspend)
        XCTAssertEqual(try leaf("Snapshot").representedObject as? HostCommand, .snapshot)
        XCTAssertEqual(try leaf("Apply OS Update").representedObject as? HostCommand, .applyUpdate)
        XCTAssertEqual(try leaf("Roll Back OS Update").representedObject as? HostCommand, .rollbackUpdate)
        XCTAssertEqual(try leaf("Reveal Share in Finder").representedObject as? HostCommand, .revealShare)
        // Menu validation IS the bus's enablement — a posture-less run
        // greys every verb.
        for title in ["Suspend", "Snapshot", "Apply OS Update",
                      "Roll Back OS Update", "Reveal Share in Finder"] {
            XCTAssertFalse(bus.validateMenuItem(try leaf(title)),
                           "\(title) must grey without its posture")
        }
    }

    func testStagedUpdateBannerFollowsTheModel() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        let host = HostApplication(serialLog: "/fixture/serial.log",
                                   presentWindow: false)
        // The session window owns its own bus — arm the test's model on
        // it, and point BOTH emit channels at the sink (model.emit was
        // bound at bus init; host-ui: receipts ride the bus's own).
        let model = host.commandBus.machine
        model.emit = { sink.lines.append($0) }
        host.commandBus.emit = { sink.lines.append($0) }
        let dir = tempDir()
        let share = dir.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("base.img")
        try Data("old".utf8).write(to: base)
        model.shareDir = share
        model.baseImageURL = base
        model.updateKeyHex = pubHex
        host.syncUpdateBanner()
        XCTAssertFalse(host.updateBannerVisible)
        // The stage lands mid-run (guest-written — the poll's domain):
        // sync is the surface the timer drives.
        try stageUpdate(in: share, version: "m120c-b")
        host.syncUpdateBanner()
        XCTAssertTrue(host.updateBannerVisible)
        XCTAssertTrue(host.updateBannerText.contains("OS update staged"))
        XCTAssertTrue(host.updateBannerText.contains("m120c-b"))
        // The apply lands through the SAME bus the menu uses — the
        // model change hides the strip (the set is consumed).
        XCTAssertEqual(host.commandBus.dispatch(.applyUpdate), .performed)
        host.syncUpdateBanner()
        XCTAssertFalse(host.updateBannerVisible)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=apply-update state=performed staged=0 version=m120c-b")
        _ = bus
    }
    // MARK: - M157a (#2934): the stats line + the close-policy words.

    /// The line carries configured figures only; a figure it cannot
    /// show is dropped and named in the tooltip.
    func testStatsLineConfiguredFiguresAndTooltip() {
        let stats = HostStatsModel()
        stats.vcpus = 2
        stats.memoryMiB = 512
        stats.stateProvider = { "running" }
        XCTAssertEqual(stats.line, "2 vCPU · 512 MiB · running")
        XCTAssertTrue(stats.tooltip.contains("uptime (machine not yet started)"))
        stats.startedAt = Date().addingTimeInterval(-183)
        XCTAssertEqual(stats.line, "2 vCPU · 512 MiB · running · up 3m")
        XCTAssertEqual(stats.tooltip, "Configured shape — no usage metrics collected.")
        // Bare model: every unshown figure is named in the tooltip.
        let bare = HostStatsModel()
        XCTAssertEqual(bare.line, "starting")
        XCTAssertTrue(bare.tooltip.contains("vCPU count"))
        XCTAssertTrue(bare.tooltip.contains("RAM"))
        XCTAssertTrue(bare.tooltip.contains("uptime"))
    }

    func testStatsUptimeFormatting() {
        XCTAssertEqual(HostStatsModel.uptime(5), "0m")
        XCTAssertEqual(HostStatsModel.uptime(61), "1m")
        XCTAssertEqual(HostStatsModel.uptime(183), "3m")
        XCTAssertEqual(HostStatsModel.uptime(3720), "1h2m")
    }

    /// The refusal word — the static Code=2 class when argv arms a
    /// custom-virtio share, else the driver's wire code verbatim.
    func testCloseRefusalCodeNamesTheCustomVirtioClass() {
        let model = HostMachineModel()
        model.arguments = ["VMRunner", "--cvc-file", "/x"]
        XCTAssertEqual(model.closeRefusalCode("unsupported"), "2")
        model.arguments = ["VMRunner", "--virtio-fs", "/x"]
        XCTAssertEqual(model.closeRefusalCode("unsupported"), "unsupported")
        model.arguments = ["VMRunner", "--cvc-file", "/x"]
        XCTAssertEqual(model.closeRefusalCode("busy"), "busy")
        XCTAssertEqual(model.closeRefusalCode("save_failed"), "save_failed")
    }

    /// The named messages carry the code, the --resume continuation
    /// and the Code=12 bound.
    func testCloseMessagesNameTheCodeAndBound() {
        let refused = HostMachineModel.closeRefusalMessage(code: "2")
        XCTAssertTrue(refused.contains("code=2"))
        XCTAssertTrue(refused.contains("--resume"))
        XCTAssertTrue(refused.contains("Code=12"))
        XCTAssertTrue(HostMachineModel.closeSavedMessage.contains("--resume"))
        XCTAssertTrue(HostMachineModel.closeSavedMessage.contains("Code=12"))
    }
}
