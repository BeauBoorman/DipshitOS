import AppKit
import XCTest
import VMAppKit
import VMProfile

/// M128a (#2605): the ⌘, settings panel — HostSettingsModel edits
/// VMProfile.Config on the bus (load → edit → save → reload round
/// trip), the `settings` verb receipts `host-ui: cmd=settings`, and the
/// view projects it all. Class-A throughout: no window server, no VM.
final class HostSettingsTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostsettings-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // The refusal test marks the bundle read-only; restore so cleanup works.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: tmpDir.path)
        for child in (try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)) ?? [] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: tmpDir.appendingPathComponent(child).path)
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func bundleURL(_ name: String = "test.virelaivm") -> URL {
        tmpDir.appendingPathComponent(name, isDirectory: true)
    }

    private final class Sink {
        var lines: [String] = []
    }

    // MARK: Arming — the profile resolves from argv, injectably.

    func testProfileResolvesFromArgv() {
        let model = HostSettingsModel()
        model.arguments = ["vm-runner", "--profile", "/tmp/my.virelaivm", "--cpus", "4"]
        XCTAssertEqual(model.resolvedProfileURL()?.path, "/tmp/my.virelaivm")
        XCTAssertTrue(model.armed)
        // --resume IS a profile boot — it arms the panel the same way.
        model.profileURL = nil
        model.arguments = ["vm-runner", "--resume", "/tmp/resume.virelaivm"]
        XCTAssertEqual(model.resolvedProfileURL()?.path, "/tmp/resume.virelaivm")
        // A flag-only run has no bundle for an edit to land in.
        model.arguments = ["vm-runner", "--cpus", "4"]
        XCTAssertNil(model.resolvedProfileURL())
        XCTAssertFalse(model.armed)
        // The direct override beats argv — the test seam.
        model.profileURL = URL(fileURLWithPath: "/tmp/direct.virelaivm")
        XCTAssertEqual(model.resolvedProfileURL()?.path, "/tmp/direct.virelaivm")
    }

    // MARK: Round trip — load → edit → save → reload.

    /// The card's core leg: the model loads a bundle, the draft edits
    /// the Config fields, save() writes config.json atomically, and a
    /// fresh VMProfile.load reads every edit back.
    func testRoundTripEditSaveReload() throws {
        let url = bundleURL("workstation.virelaivm")
        var devices = VMProfile.Devices()
        devices.share = true
        let minted = try VMProfile.create(
            at: url, name: "workstation",
            config: VMProfile.Config(cpus: 2, memoryMiB: 256,
                                     baseImage: "/base/disk.img", devices: devices))

        let model = HostSettingsModel()
        model.profileURL = url
        XCTAssertTrue(model.armed)
        XCTAssertTrue(model.ensureLoaded())
        XCTAssertEqual(model.profile?.name, "workstation")
        XCTAssertEqual(model.cpusText, "2")
        XCTAssertEqual(model.memoryText, "256")
        XCTAssertFalse(model.dirty)
        XCTAssertFalse(model.canSave) // nothing to write yet

        model.cpusText = "6"
        model.memoryText = "1024"
        model.devices.sound = true
        model.devices.netNat = true
        model.devices.vsock = true
        model.devices.display = true
        model.baseImageText = "/base/new-disk.img"
        XCTAssertTrue(model.dirty)
        XCTAssertTrue(model.errors.isEmpty)
        XCTAssertTrue(model.canSave)

        XCTAssertTrue(model.save())
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(model.savedCount, 1)

        let reloaded = try VMProfile.load(from: url)
        XCTAssertEqual(reloaded.config.cpus, 6)
        XCTAssertEqual(reloaded.config.memoryMiB, 1024)
        XCTAssertEqual(reloaded.config.baseImage, "/base/new-disk.img")
        XCTAssertTrue(reloaded.config.devices.sound)
        XCTAssertTrue(reloaded.config.devices.netNat)
        XCTAssertTrue(reloaded.config.devices.vsock)
        XCTAssertTrue(reloaded.config.devices.display)
        XCTAssertTrue(reloaded.config.devices.share)
        XCTAssertEqual(reloaded.identity, minted.identity)
    }

    /// A save never drops what the panel does not show: the pinned
    /// updatePubkey survives a panel edit of the other fields.
    func testSavePreservesUneditedConfigMembers() throws {
        let url = bundleURL()
        var minted = try VMProfile.create(at: url)
        minted.config.updatePubkey = String(repeating: "ab", count: 32)
        try minted.save()

        let model = HostSettingsModel()
        model.profileURL = url
        XCTAssertTrue(model.ensureLoaded())
        model.cpusText = "4"
        XCTAssertTrue(model.save())

        let reloaded = try VMProfile.load(from: url)
        XCTAssertEqual(reloaded.config.cpus, 4)
        XCTAssertEqual(reloaded.config.updatePubkey, String(repeating: "ab", count: 32))
    }

    // MARK: Validation — the shape-check mirror.

    /// The panel refuses what VMProfile.load would refuse: cpus outside
    /// 1...8, memoryMiB <= 0, an empty baseImage, plus the not-a-number
    /// cases a free-form field admits.
    func testValidationMirrorsProfileShapeCheck() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let model = HostSettingsModel()
        model.profileURL = url
        XCTAssertTrue(model.ensureLoaded())

        for bad in ["0", "9", "-2", "abc", "1.5", ""] {
            model.cpusText = bad
            XCTAssertFalse(model.errors.isEmpty, "cpus '\(bad)' must fail the shape check")
            XCTAssertFalse(model.canSave)
            XCTAssertFalse(model.save())
        }
        model.cpusText = "8"
        XCTAssertTrue(model.errors.isEmpty)

        for bad in ["0", "-256", "abc", ""] {
            model.memoryText = bad
            XCTAssertFalse(model.errors.isEmpty, "memoryMiB '\(bad)' must fail the shape check")
            XCTAssertFalse(model.save())
        }
        model.memoryText = "512"
        XCTAssertTrue(model.errors.isEmpty)

        model.baseImageText = ""
        XCTAssertFalse(model.errors.isEmpty)
        XCTAssertFalse(model.save())
        model.baseImageText = "artifacts/disk.img"
        XCTAssertTrue(model.errors.isEmpty)
    }

    /// Dirty is field-accurate: an edit flags it, reverting (or retyping
    /// the loaded value) clears it.
    func testDirtyAndRevert() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url, config: VMProfile.Config(cpus: 3, memoryMiB: 512,
                                                                  baseImage: "/b.img"))
        let model = HostSettingsModel()
        model.profileURL = url
        XCTAssertTrue(model.ensureLoaded())
        XCTAssertFalse(model.dirty)

        model.cpusText = "5"
        XCTAssertTrue(model.dirty)
        model.cpusText = "3" // back to the loaded value — not dirty
        XCTAssertFalse(model.dirty)

        model.devices.vsock = true
        XCTAssertTrue(model.dirty)
        model.revert()
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(model.cpusText, "3")
        XCTAssertEqual(model.memoryText, "512")
        XCTAssertFalse(model.devices.vsock)
    }

    /// A failed save is honest: the bundle stays byte-identical, the
    /// model names the failure, and dirty stays set — nothing was
    /// written.
    func testSaveFailurePreservesBundleAndFlagsError() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let configBefore = try Data(contentsOf: url.appendingPathComponent("config.json"))

        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: url.path)
        }
        let model = HostSettingsModel()
        model.profileURL = url
        XCTAssertTrue(model.ensureLoaded())
        model.cpusText = "7"
        XCTAssertTrue(model.dirty)
        XCTAssertFalse(model.save())
        XCTAssertNotNil(model.lastSaveError)
        XCTAssertTrue(model.dirty)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("config.json")),
                       configBefore, "a refused save leaves config.json intact")
    }

    // MARK: The bus — cmd=settings receipts.

    /// The `settings` verb toggles the model and receipts the live
    /// state — open=1 then open=0 — the leg a gate greps.
    func testSettingsVerbReceiptsOnTheBus() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let sink = Sink()
        let settings = HostSettingsModel()
        settings.profileURL = url
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, settings: settings)

        XCTAssertEqual(bus.dispatch(.settings), .performed)
        XCTAssertTrue(settings.isOpen)
        XCTAssertEqual(bus.dispatch(.settings), .performed)
        XCTAssertFalse(settings.isOpen)
        XCTAssertEqual(sink.lines, [
            "host-ui: cmd=settings state=performed open=1 dirty=0 saved=0",
            "host-ui: cmd=settings state=performed open=0 dirty=0 saved=0",
        ])
    }

    /// No profile armed → the verb receipts `disabled` and the menu
    /// item validates off — the flags-off posture.
    func testSettingsVerbDisabledWithoutProfile() {
        let sink = Sink()
        let settings = HostSettingsModel()
        settings.arguments = ["vm-runner"] // no --profile/--resume
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, settings: settings)
        XCTAssertEqual(bus.dispatch(.settings), .disabled)
        XCTAssertFalse(settings.isOpen)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=settings state=disabled open=0 dirty=0 saved=0"])

        let bar = HostMenuBar.build(bus: bus)
        let item = bar.items.first { $0.submenu?.title == "VirelaiOS" }?.submenu?
            .items.first { $0.representedObject as? HostCommand == .settings }
        XCTAssertNotNil(item)
        XCTAssertFalse(bus.validateMenuItem(item!))
    }

    /// A bundle that will not load receipts `failed` — the panel opens
    /// over a real profile or not at all.
    func testSettingsVerbFailsOnCorruptProfile() throws {
        let url = bundleURL("corrupt.virelaivm")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // A directory with no manifest: load refuses missingManifest.
        let sink = Sink()
        let settings = HostSettingsModel()
        settings.profileURL = url
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, settings: settings)
        XCTAssertEqual(bus.dispatch(.settings), .failed)
        XCTAssertFalse(settings.isOpen)
        XCTAssertNotNil(settings.loadError)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=settings state=failed open=0 dirty=0 saved=0"])
    }

    /// The dirty flag reaches the receipt: an edited-but-unsaved draft
    /// shows up in `dirty=1`.
    func testReceiptDetailCarriesDirty() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let sink = Sink()
        let settings = HostSettingsModel()
        settings.profileURL = url
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, settings: settings)
        XCTAssertEqual(bus.dispatch(.settings), .performed)
        settings.cpusText = "8"
        XCTAssertEqual(bus.dispatch(.settings), .performed)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=settings state=performed open=0 dirty=1 saved=0")
    }

    // MARK: Menu — the ⌘, item dispatches on the bus.

    func testMenuCarriesSettingsChord() throws {
        let bus = HostCommandBus()
        let bar = HostMenuBar.build(bus: bus)
        let item = try XCTUnwrap(bar.items.first { $0.submenu?.title == "VirelaiOS" }?.submenu?
            .items.first { $0.title == "Machine Settings…" })
        XCTAssertEqual(item.keyEquivalent, ",")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertEqual(item.representedObject as? HostCommand, .settings)
        XCTAssertTrue(item.target === bus)
        XCTAssertEqual(item.action, #selector(HostCommandBus.dispatchItem(_:)))
    }

    // MARK: Rows — the restart-vs-live markers.

    /// Every row carries an effect marker and every Config field the
    /// panel exposes is next-boot — no field hot-plugs today. The
    /// marker list is what M128e's acceptance reads.
    func testRowsCarryEffectMarkers() {
        let keys = HostSettingsModel.rows.map(\.key)
        for expected in ["cpus", "memoryMiB", "baseImage", "display", "input",
                         "sound", "netNat", "vsock", "dataDisk", "share"] {
            XCTAssertTrue(keys.contains(expected), "missing row \(expected)")
        }
        for row in HostSettingsModel.rows {
            XCTAssertEqual(row.effect, .nextRestart,
                           "\(row.key) is a boot-time Config field — it cannot be live")
            XCTAssertEqual(HostSettingsView.effectMarkerText(row.effect), "next boot")
        }
        XCTAssertEqual(HostSettingsView.effectMarkerText(.live), "live")
    }

    // MARK: The view — a pure projection of the model.

    func testViewProjectsModelAndSaves() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url, config: VMProfile.Config(cpus: 2, memoryMiB: 256,
                                                                  baseImage: "/b.img"))
        let model = HostSettingsModel()
        model.profileURL = url
        _ = model.ensureLoaded()
        let view = HostSettingsView(model: model)

        XCTAssertEqual(view.cpusText, "2")
        XCTAssertEqual(view.memoryText, "256")
        XCTAssertEqual(view.baseImageText, "/b.img")
        XCTAssertEqual(view.markerText("cpus"), "next boot")
        XCTAssertEqual(view.markerText("sound"), "next boot")
        XCTAssertFalse(view.toggleState("sound"))
        XCTAssertFalse(view.saveEnabled)

        // Field edits land in the draft through commitFields — the same
        // path a real field commit takes.
        view.cpusText = "4"
        view.memoryText = "768"
        view.commitFields()
        XCTAssertTrue(model.dirty)
        XCTAssertTrue(view.saveEnabled)

        // An out-of-shape entry disables Save and names the problem.
        view.cpusText = "99"
        view.commitFields()
        XCTAssertFalse(view.saveEnabled)
        XCTAssertTrue(view.errorText.contains("1...8"))
        view.cpusText = "4"
        view.commitFields()
        view.reload()
        XCTAssertTrue(view.errorText.isEmpty)

        // Save through the view writes the profile file.
        XCTAssertTrue(model.save())
        let reloaded = try VMProfile.load(from: url)
        XCTAssertEqual(reloaded.config.cpus, 4)
        XCTAssertEqual(reloaded.config.memoryMiB, 768)
    }
}
