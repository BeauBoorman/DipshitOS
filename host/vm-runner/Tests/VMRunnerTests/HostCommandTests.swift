import AppKit
import XCTest
import VMAppKit

/// M114a (#2454): the bus is the seam — menus and `--host-cmd-after`
/// share it, so dispatch, receipts, trigger parsing and menu validation
/// are all class-A (no window, no VM, no synthesized clicks).
final class HostCommandTests: XCTestCase {
    private final class Sink {
        var lines: [String] = []
    }

    private func makeBus(_ sink: Sink) -> HostCommandBus {
        HostCommandBus { sink.lines.append($0) }
    }

    private func item(_ menu: NSMenu, _ title: String, in submenu: String) -> NSMenuItem? {
        menu.items.first { $0.submenu?.title == submenu }?.submenu?.items.first { $0.title == title }
    }

    func testTriggerParsesMarkerAndVerb() throws {
        let plain = try XCTUnwrap(HostCommandTrigger("boot done:screenshot"))
        XCTAssertEqual(plain.marker, "boot done")
        XCTAssertEqual(plain.command, .screenshot)
        // The verb is the suffix after the LAST colon — serial markers
        // carry colons of their own.
        let colon = try XCTUnwrap(HostCommandTrigger("gofiles:done:quit"))
        XCTAssertEqual(colon.marker, "gofiles:done")
        XCTAssertEqual(colon.command, .quit)
        XCTAssertNil(HostCommandTrigger("no-colon"))
        XCTAssertNil(HostCommandTrigger("marker:no-such-verb"))
        XCTAssertNil(HostCommandTrigger(":quit"))
    }

    func testDispatchUnregisteredVerbReceiptsUnavailable() {
        let sink = Sink()
        let bus = makeBus(sink)
        XCTAssertEqual(bus.dispatch(.fullscreen), .unavailable)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=fullscreen state=unavailable"])
    }

    func testDispatchRunsActionAndWritesReceipt() {
        let sink = Sink()
        let bus = makeBus(sink)
        var ran = 0
        bus.register(.stop, HostCommandBus.Registration {
            ran += 1
            return .performed
        })
        XCTAssertEqual(bus.dispatch(.stop), .performed)
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=stop state=performed"])
    }

    func testDisabledVerbSkipsTheAction() {
        let sink = Sink()
        let bus = makeBus(sink)
        var enabled = false
        var ran = 0
        bus.register(.stop, HostCommandBus.Registration(isEnabled: { enabled }) {
            ran += 1
            return .performed
        })
        XCTAssertEqual(bus.dispatch(.stop), .disabled)
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=stop state=disabled"])
        enabled = true
        XCTAssertEqual(bus.dispatch(.stop), .performed)
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(sink.lines, [
            "host-ui: cmd=stop state=disabled",
            "host-ui: cmd=stop state=performed",
        ])
    }

    func testReceiptDetailAppendsThePostActionState() {
        let sink = Sink()
        let bus = makeBus(sink)
        var on = false
        bus.register(.captureKeys, HostCommandBus.Registration(
            itemState: { on },
            receiptDetail: { "capture=\(on ? "on" : "off")" }
        ) {
            on.toggle()
            return .performed
        })
        // M114b: a toggle's receipt carries the property it toggled, so a
        // gate asserting the receipt reads the real post-action state.
        XCTAssertEqual(bus.dispatch(.captureKeys), .performed)
        XCTAssertEqual(bus.dispatch(.captureKeys), .performed)
        XCTAssertEqual(sink.lines, [
            "host-ui: cmd=capture-keys state=performed capture=on",
            "host-ui: cmd=capture-keys state=performed capture=off",
        ])
    }

    func testReceiptDetailOnADisabledVerbStillReportsLiveState() {
        let sink = Sink()
        let bus = makeBus(sink)
        bus.register(.captureKeys, HostCommandBus.Registration(
            isEnabled: { false },
            receiptDetail: { "capture=off" }
        ) { .performed })
        XCTAssertEqual(bus.dispatch(.captureKeys), .disabled)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=capture-keys state=disabled capture=off"])
        // Unregistered stays detail-free.
        XCTAssertEqual(bus.dispatch(.laneNotify), .unavailable)
        XCTAssertEqual(sink.lines, [
            "host-ui: cmd=capture-keys state=disabled capture=off",
            "host-ui: cmd=lane-notify state=unavailable",
        ])
    }

    func testActionCanReportFailure() {
        let sink = Sink()
        let bus = makeBus(sink)
        bus.register(.screenshot, HostCommandBus.Registration { .failed })
        XCTAssertEqual(bus.dispatch(.screenshot), .failed)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=screenshot state=failed"])
    }

    func testMenuBarIsTheSixMenusOfBusActions() throws {
        let bus = HostCommandBus()
        let bar = HostMenuBar.build(bus: bus)
        XCTAssertEqual(bar.items.compactMap { $0.submenu?.title },
                       ["VirelaiOS", "Machine", "View", "Integration", "Debug", "Help"])
        for top in bar.items {
            for entry in top.submenu?.items ?? [] where !entry.isSeparatorItem {
                XCTAssertTrue(entry.target === bus, "\(entry.title) must dispatch on the bus")
                XCTAssertEqual(entry.action, #selector(HostCommandBus.dispatchItem(_:)))
                XCTAssertNotNil(entry.representedObject as? HostCommand, "\(entry.title) must carry its verb")
            }
        }
        let quit = try XCTUnwrap(item(bar, "Quit VirelaiOS", in: "VirelaiOS"))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        XCTAssertEqual(quit.representedObject as? HostCommand, .quit)
        // M122d (#2573): Help → Keyboard Shortcuts rides the ⌘/ chord
        // onto the `shortcuts` verb like every other leaf.
        let sheet = try XCTUnwrap(item(bar, "Keyboard Shortcuts", in: "Help"))
        XCTAssertEqual(sheet.keyEquivalent, "/")
        XCTAssertEqual(sheet.keyEquivalentModifierMask, .command)
        XCTAssertEqual(sheet.representedObject as? HostCommand, .shortcuts)
    }

    func testMenuValidationMirrorsRegistration() throws {
        let bus = HostCommandBus()
        let bar = HostMenuBar.build(bus: bus)
        let fullscreen = try XCTUnwrap(item(bar, "Enter Full Screen", in: "View"))
        let stop = try XCTUnwrap(item(bar, "Stop VM", in: "Machine"))
        // Unregistered verbs render disabled — later cards wire them.
        XCTAssertFalse(bus.validateMenuItem(fullscreen))
        XCTAssertFalse(bus.validateMenuItem(stop))
        var stoppable = false
        bus.register(.stop, HostCommandBus.Registration(isEnabled: { stoppable }) { .performed })
        XCTAssertFalse(bus.validateMenuItem(stop))
        stoppable = true
        XCTAssertTrue(bus.validateMenuItem(stop))
        // A toggle item reads its checkmark from the registration.
        bus.register(.laneClipboard, HostCommandBus.Registration(itemState: { true }) { .performed })
        let clip = try XCTUnwrap(item(bar, "Clipboard", in: "Integration"))
        XCTAssertTrue(bus.validateMenuItem(clip))
        XCTAssertEqual(clip.state, .on)
    }

    func testMenuItemDispatchesItsVerb() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        var stops = 0
        bus.register(.stop, HostCommandBus.Registration {
            stops += 1
            return .performed
        })
        let bar = HostMenuBar.build(bus: bus)
        let stop = try XCTUnwrap(item(bar, "Stop VM", in: "Machine"))
        bus.dispatchItem(stop)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=stop state=performed"])
    }

    // MARK: M122d (#2573) — the ⌘/ cheat sheet.

    /// `shortcuts` is a self-registered companion verb: a bare bus
    /// receipts `performed` with the open state + row count, and the
    /// menu item's checkmark mirrors the model's isOpen.
    func testShortcutsVerbReceiptsAndFlipsOpen() throws {
        let sink = Sink()
        let bus = makeBus(sink)
        XCTAssertTrue(bus.isRegistered(.shortcuts), "shortcuts must self-register on the bus")
        XCTAssertEqual(bus.dispatch(.shortcuts), .performed)
        XCTAssertTrue(bus.shortcuts.isOpen)
        XCTAssertEqual(bus.dispatch(.shortcuts), .performed)
        XCTAssertFalse(bus.shortcuts.isOpen)
        XCTAssertEqual(sink.lines, [
            "host-ui: cmd=shortcuts state=performed open=1 chords=8",
            "host-ui: cmd=shortcuts state=performed open=0 chords=8",
        ])
        // The checkmark is the model's own state — the Help item
        // validates on while the sheet is up.
        let bar = HostMenuBar.build(bus: bus)
        let sheet = try XCTUnwrap(item(bar, "Keyboard Shortcuts", in: "Help"))
        bus.shortcuts.isOpen = true
        XCTAssertTrue(bus.validateMenuItem(sheet))
        XCTAssertEqual(sheet.state, .on)
    }

    /// The cheat sheet's rows are GENERATED from the menu's command
    /// table: every chorded leaf, in menu order, so the sheet can
    /// never advertise a chord the menus do not know.
    func testShortcutRowsAreTheMenuTableChords() {
        let rows = HostShortcutsModel().rows
        XCTAssertEqual(rows.count, HostMenuBar.chords.count)
        XCTAssertEqual(rows.map { ($0.title, $0.chord, $0.command) }.map { "\($0.0)|\($0.1)|\($0.2.rawValue)" }, [
            "Machine Settings…|⌘,|settings",
            "Quit VirelaiOS|⌘Q|quit",
            "Enter Full Screen|⌃⌘F|fullscreen",
            "Capture System Keys|⌥⌘K|capture-keys",
            "Inspector|⌥⌘I|inspector",
            "Take Screenshot|⇧⌘5|screenshot",
            "Record Window|⇧⌘6|record",
            "Keyboard Shortcuts|⌘/|shortcuts",
        ])
    }

    /// The sheet's view is the model's projection — one grid row per
    /// model row, title + chord glyphs, nothing hand-kept.
    func testShortcutsViewRendersTheModelRows() {
        let model = HostShortcutsModel()
        let view = HostShortcutsView(model: model)
        XCTAssertEqual(view.titleText, "Keyboard Shortcuts")
        XCTAssertEqual(view.rowCount, model.rows.count)
        for (i, row) in model.rows.enumerated() {
            XCTAssertEqual(view.rowTitle(i), row.title)
            XCTAssertEqual(view.rowChord(i), row.chord)
        }
    }

    func testSessionCommandsRouteThroughTheBus() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        for verb in [HostCommand.about, .quit, .stop] {
            XCTAssertTrue(host.commandBus.isRegistered(verb), "\(verb.rawValue) must be a session verb")
        }
        var reasons: [String] = []
        host.onStop = { reason, _ in reasons.append(reason) }
        XCTAssertEqual(host.commandBus.dispatch(.stop), .performed)
        XCTAssertEqual(reasons, ["menu-stop"])
        // Once stopping, the same verb reports disabled — the receipt
        // names the state instead of repeating the stop.
        XCTAssertEqual(host.commandBus.dispatch(.stop), .disabled)
    }
    /// M157a (#2934): `close@vm=<k>` — the verb parses like every other
    /// `@`-operand trigger, and a bare `close` receipts the named
    /// no_target refusal rather than guessing a window.
    func testCloseVerbParsesAndNeedsATarget() throws {
        let bound = try XCTUnwrap(HostCommandTrigger("vm2:virelai> :close@vm=2"))
        XCTAssertEqual(bound.session, 2)
        XCTAssertEqual(bound.marker, "virelai> ")
        XCTAssertEqual(bound.command, .close)
        XCTAssertEqual(bound.argument, "vm=2")
        let bare = try XCTUnwrap(HostCommandTrigger("done:close@3"))
        XCTAssertEqual(bare.command, .close)
        XCTAssertEqual(bare.argument, "3")
        // An unregistered bus — the verb reports unavailable like any
        // other until the registry wires it.
        let sink = Sink()
        let bus = makeBus(sink)
        XCTAssertEqual(bus.dispatch(.close), .unavailable)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=close state=unavailable"])
    }
}
