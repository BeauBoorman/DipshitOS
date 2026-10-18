import AppKit
import XCTest
import VMAppKit
import VMProfile

/// M128b (#2606): the profile manager — `profile-new`/`profile-clone`/
/// `profile-reset-overlay`/`profile-switch` on the bus. Class-A
/// throughout: no window server, no VM — the model's seams
/// (profileURL/profilesDir/vmRunning/confirm/requestStop) stand in for
/// the session. The card's legs: clone preserves share/, reset re-mints
/// the overlay on next boot (the file is gone), switch swaps the armed
/// path's occupant, and reset/switch while running demand a confirm.
final class HostProfilesTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostprofiles-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func bundleURL(_ name: String = "test.virelaivm") -> URL {
        tmpDir.appendingPathComponent(name, isDirectory: true)
    }

    private final class Sink {
        var lines: [String] = []
    }

    /// An armed model+bus: profile minted at `url`, emit captured.
    private func makeBus(_ sink: Sink, armed url: URL,
                         configure: (HostProfilesModel) -> Void = { _ in }) -> HostCommandBus {
        let profiles = HostProfilesModel()
        profiles.profileURL = url
        configure(profiles)
        return HostCommandBus(emit: { sink.lines.append($0) }, profiles: profiles)
    }

    // MARK: Arming

    /// The armed profile resolves from argv like the settings model —
    /// --profile and --resume both arm; a flag-run has no machine.
    func testArmedResolvesFromArgv() {
        let model = HostProfilesModel()
        model.arguments = ["vm-runner", "--profile", "/tmp/my.virelaivm"]
        XCTAssertTrue(model.armed)
        XCTAssertEqual(model.resolvedProfileURL()?.path, "/tmp/my.virelaivm")
        model.arguments = ["vm-runner", "--resume", "/tmp/r.virelaivm"]
        XCTAssertEqual(model.resolvedProfileURL()?.path, "/tmp/r.virelaivm")
        model.arguments = ["vm-runner", "--cpus", "4"]
        XCTAssertFalse(model.armed)
        XCTAssertNil(model.resolvedProfilesDir())
        XCTAssertFalse(model.canCreate)
    }

    // MARK: profile-new

    /// profile-new mints a sibling `untitled.virelaivm` — collision-free
    /// `untitled-2` on the second mint — and receipts `created=<name>`.
    func testProfileNewMintsSibling() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let sink = Sink()
        let bus = makeBus(sink, armed: url)

        XCTAssertEqual(bus.dispatch(.profileNew), .performed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("untitled.virelaivm/manifest.json").path))
        XCTAssertEqual(bus.dispatch(.profileNew), .performed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("untitled-2.virelaivm/manifest.json").path))
        XCTAssertEqual(sink.lines.filter { $0.hasPrefix("host-ui:") }, [
            "host-ui: cmd=profile-new state=performed armed=test created=untitled",
            "host-ui: cmd=profile-new state=performed armed=test created=untitled-2",
        ])
        // The minted bundle loads clean and is its own machine.
        let minted = try VMProfile.load(from: tmpDir.appendingPathComponent("untitled.virelaivm"))
        XCTAssertEqual(minted.name, "untitled")
        XCTAssertEqual(minted.identity, "org.virelaios.vm.untitled")
    }

    /// A flag-run with nowhere to mint receipts disabled — the item greys.
    func testProfileNewDisabledWithoutProfilesDir() {
        let sink = Sink()
        let profiles = HostProfilesModel()
        profiles.arguments = ["vm-runner"] // no --profile
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, profiles: profiles)
        XCTAssertEqual(bus.dispatch(.profileNew), .disabled)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=profile-new state=disabled armed=none none"])
    }

    // MARK: profile-clone — the card's share/-preservation leg.

    /// Clone copies config + share/ recursively — and nothing else:
    /// fresh identity/dirs, no overlay.asif/machine-id/vlfs/efi-vars.
    func testProfileClonePreservesShare() throws {
        let url = bundleURL()
        let src = try VMProfile.create(
            at: url, name: "workstation",
            config: VMProfile.Config(cpus: 4, memoryMiB: 768, baseImage: "/b/disk.img"))
        // Populate the members a lived-in machine has.
        try Data("fake-overlay".utf8).write(to: src.overlayURL)
        try Data("fake-efi".utf8).write(to: src.efiVarsURL)
        try Data("fake-vlfs".utf8).write(to: src.vlfsURL)
        try src.setMachineIdentifier(Data(repeating: 0x42, count: 70))
        let share = src.shareURL
        try Data("user-file".utf8).write(to: share.appendingPathComponent("NOTES.TXT"))
        try FileManager.default.createDirectory(
            at: share.appendingPathComponent("NESTED"), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: share.appendingPathComponent("NESTED/DEEP.BIN"))

        let sink = Sink()
        let bus = makeBus(sink, armed: url)
        XCTAssertEqual(bus.dispatch(.profileClone), .performed)
        XCTAssertEqual(sink.lines.filter { $0.hasPrefix("host-ui:") },
                       ["host-ui: cmd=profile-clone state=performed armed=test clone=workstation-copy"])

        let cloneURL = tmpDir.appendingPathComponent("workstation-copy.virelaivm")
        let clone = try VMProfile.load(from: cloneURL)
        XCTAssertEqual(clone.name, "workstation-copy")
        XCTAssertEqual(clone.config, src.config) // config rides
        XCTAssertNotEqual(clone.identity, src.identity) // a NEW machine
        // share/ survives verbatim — the nested file included.
        XCTAssertEqual(try String(contentsOf: clone.shareURL.appendingPathComponent("NOTES.TXT")),
                       "user-file")
        XCTAssertEqual(try Data(contentsOf: clone.shareURL.appendingPathComponent("NESTED/DEEP.BIN")),
                       Data("deep".utf8))
        // Fresh overlay + no borrowed state: nothing carried over.
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.overlayURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.vlfsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.efiVarsURL.path))
        XCTAssertNil(clone.machineIdentifierData())
        // The source bundle is untouched — clone never mutates its origin.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.overlayURL.path))

        // A second clone is collision-safe.
        XCTAssertEqual(bus.dispatch(.profileClone), .performed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("workstation-copy-2.virelaivm/manifest.json").path))
    }

    /// A corrupt armed bundle fails by name instead of cloning garbage.
    func testProfileCloneFailsOnCorruptSource() throws {
        let url = bundleURL("corrupt.virelaivm")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let sink = Sink()
        let bus = makeBus(sink, armed: url)
        XCTAssertEqual(bus.dispatch(.profileClone), .failed)
        XCTAssertTrue(sink.lines.last?.contains("error=no profile manifest") == true)
    }

    // MARK: profile-reset-overlay — the overlay re-mint leg.

    /// Reset deletes overlay.asif — the attach point re-mints it over the
    /// read-only base next boot. Idempotent: second reset says `absent`.
    func testProfileResetOverlay() throws {
        let url = bundleURL()
        let p = try VMProfile.create(at: url)
        try Data("wedge".utf8).write(to: p.overlayURL)

        let sink = Sink()
        let bus = makeBus(sink, armed: url)
        XCTAssertEqual(bus.dispatch(.profileResetOverlay), .performed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.overlayURL.path),
                       "reset must remove overlay.asif so next boot re-mints it")
        XCTAssertEqual(bus.dispatch(.profileResetOverlay), .performed)
        XCTAssertEqual(sink.lines.filter { $0.hasPrefix("host-ui:") }, [
            "host-ui: cmd=profile-reset-overlay state=performed armed=test overlay=reset",
            "host-ui: cmd=profile-reset-overlay state=performed armed=test overlay=absent",
        ])
        // Only the overlay went — share/ and config survive the reset.
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.configURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.shareURL.path))
    }

    /// While the VM runs, reset/switch demand the confirm seam: a decline
    /// receipts `disabled` and touches nothing; a consent performs.
    func testDestructiveVerbsConfirmWhileRunning() throws {
        let url = bundleURL()
        let p = try VMProfile.create(at: url)
        try Data("wedge".utf8).write(to: p.overlayURL)
        let sink = Sink()
        var confirmed = false
        let bus = makeBus(sink, armed: url) { model in
            model.vmRunning = { true }
            model.confirm = { _ in confirmed }
        }
        XCTAssertEqual(bus.dispatch(.profileResetOverlay), .disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.overlayURL.path),
                       "a declined confirm must leave overlay.asif untouched")
        XCTAssertTrue(sink.lines.last?.contains("confirm=declined") == true)
        confirmed = true
        XCTAssertEqual(bus.dispatch(.profileResetOverlay), .performed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.overlayURL.path))
    }

    // MARK: profile-switch — the armed path is the pointer.

    /// Switch exchanges which bundle lives at the armed path: the chosen
    /// sibling lands there (next launch boots it) and the armed bundle
    /// survives whole at the sibling's old path — no data moves out.
    func testProfileSwitchSwapsTheArmedOccupant() throws {
        let armedURL = bundleURL("session.virelaivm")
        _ = try VMProfile.create(at: armedURL, name: "session",
                                 config: VMProfile.Config(cpus: 1, memoryMiB: 128, baseImage: "/a.img"))
        let targetURL = bundleURL("test-clone.virelaivm")
        _ = try VMProfile.create(at: targetURL, name: "test-clone",
                                 config: VMProfile.Config(cpus: 8, memoryMiB: 2048, baseImage: "/b.img"))

        let sink = Sink()
        let bus = makeBus(sink, armed: armedURL) { model in
            model.switchTarget = targetURL
        }
        XCTAssertEqual(bus.dispatch(.profileSwitch), .performed)
        XCTAssertEqual(sink.lines.filter { $0.hasPrefix("host-ui:") },
                       ["host-ui: cmd=profile-switch state=performed armed=session switch=test-clone"])

        // The armed path now holds the TARGET machine — the next
        // `--profile <armed>` boot loads test-clone's manifest+config.
        let nowArmed = try VMProfile.load(from: armedURL)
        XCTAssertEqual(nowArmed.name, "test-clone")
        XCTAssertEqual(nowArmed.config.cpus, 8)
        // The displaced session bundle survives whole at target's path.
        let displaced = try VMProfile.load(from: targetURL)
        XCTAssertEqual(displaced.name, "session")
        XCTAssertEqual(displaced.config.cpus, 1)
    }

    /// While running, a confirmed switch stops the session — the seam
    /// fires after the swap so the next launch is already retargeted.
    func testProfileSwitchRunningConfirmsThenStops() throws {
        let armedURL = bundleURL("session.virelaivm")
        _ = try VMProfile.create(at: armedURL, name: "session")
        let targetURL = bundleURL("other.virelaivm")
        _ = try VMProfile.create(at: targetURL, name: "other")

        let sink = Sink()
        var stops: [String] = []
        let bus = makeBus(sink, armed: armedURL) { model in
            model.switchTarget = targetURL
            model.vmRunning = { true }
            model.confirm = { _ in true }
            model.requestStop = { stops.append($0) }
        }
        XCTAssertEqual(bus.dispatch(.profileSwitch), .performed)
        XCTAssertEqual(stops, ["profile-switch"])
        XCTAssertEqual(try VMProfile.load(from: armedURL).name, "other")
    }

    /// No target → refused at dispatch (`disabled`, `target=unset`), and
    /// a sibling that will not load fails by name — never swapped.
    func testProfileSwitchRefusals() throws {
        let armedURL = bundleURL("session.virelaivm")
        _ = try VMProfile.create(at: armedURL, name: "session")
        // A sibling exists so the verb is enabled; the unset target is
        // the refusal under test.
        _ = try VMProfile.create(at: bundleURL("sibling.virelaivm"), name: "sibling")
        let sink = Sink()
        let bus = makeBus(sink, armed: armedURL)
        XCTAssertEqual(bus.dispatch(.profileSwitch), .disabled)
        XCTAssertTrue(sink.lines.last?.contains("target=unset") == true)
        // Nothing moved.
        XCTAssertEqual(try VMProfile.load(from: armedURL).name, "session")

        // A non-bundle target fails — the armed path keeps its occupant.
        let foreign = bundleURL("foreign.virelaivm")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        bus.profiles.switchTarget = foreign
        XCTAssertEqual(bus.dispatch(.profileSwitch), .failed)
        XCTAssertEqual(try VMProfile.load(from: armedURL).name, "session")
    }

    /// Disabled posture: flag-run clone/reset/switch receipt `disabled`.
    func testVerbsDisabledWithoutProfile() {
        let sink = Sink()
        let profiles = HostProfilesModel()
        profiles.arguments = ["vm-runner"]
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, profiles: profiles)
        for verb in [HostCommand.profileClone, .profileResetOverlay, .profileSwitch] {
            XCTAssertEqual(bus.dispatch(verb), .disabled, verb.rawValue)
        }
    }

    // MARK: Menu — the Machine menu projects the verbs.

    /// The Machine menu carries the four verbs; "Switch To" is a submenu
    /// the bus repopulates with sibling machines per open.
    func testMenuCarriesProfileVerbsAndSwitchSubmenu() throws {
        let armedURL = bundleURL("session.virelaivm")
        _ = try VMProfile.create(at: armedURL, name: "session")
        let sib1 = bundleURL("alpha.virelaivm")
        let sib2 = bundleURL("beta.virelaivm")
        _ = try VMProfile.create(at: sib1, name: "alpha")
        _ = try VMProfile.create(at: sib2, name: "beta")

        let sink = Sink()
        let bus = makeBus(sink, armed: armedURL)
        let bar = HostMenuBar.build(bus: bus)
        let machine = try XCTUnwrap(bar.items.first { $0.submenu?.title == "Machine" }?.submenu)
        for title in ["New Machine", "Clone This Machine", "Switch To", "Reset Boot Overlay…"] {
            XCTAssertNotNil(machine.items.first { $0.title == title }, "missing \(title)")
        }
        let switchItem = try XCTUnwrap(machine.items.first { $0.title == "Switch To" })
        let sub = try XCTUnwrap(switchItem.submenu)
        XCTAssertTrue(sub.delegate === bus)

        // menuNeedsUpdate lists siblings alphabetically, each leaf
        // carrying its path and the profile-switch verb.
        bus.menuNeedsUpdate(sub)
        XCTAssertEqual(sub.items.map(\.title), ["alpha", "beta"])
        for leaf in sub.items {
            XCTAssertEqual(leaf.representedObject as? HostCommand, .profileSwitch)
            XCTAssertEqual(leaf.action, #selector(HostCommandBus.dispatchSwitchItem(_:)))
            XCTAssertTrue(leaf.target === bus)
            XCTAssertNotNil(leaf.identifier)
        }

        // Dispatching a leaf aims the model's target at that sibling and
        // performs the switch (the target is consumed) — the armed path
        // then holds alpha.
        bus.dispatchSwitchItem(sub.items[0])
        XCTAssertNil(bus.profiles.switchTarget)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=profile-switch state=performed armed=session switch=alpha")
        XCTAssertEqual(try VMProfile.load(from: armedURL).name, "alpha")
    }
}
