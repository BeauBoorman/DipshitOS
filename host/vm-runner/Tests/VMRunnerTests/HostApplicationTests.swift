import AppKit
import XCTest
import VMAppKit

/// Hidden UI seams only: no VM, input posts, activation or class-C claim.
final class HostApplicationTests: XCTestCase {
    private final class GuestView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testStartupRunningFocusAndFailurePresentation() throws {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        let view = GuestView()
        host.attach(view)
        XCTAssertEqual(host.window.title, "VirelaiOS — Starting VM")
        XCTAssertTrue(view.isHidden)
        // M114d (#2457): the label now lives inside the split's guest
        // pane — find the field by its content, not its depth.
        func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? fields(in: $0) }
        }
        let status = try XCTUnwrap(fields(in: host.window.contentView!).first { $0.stringValue.contains("/fixture/serial.log") })
        XCTAssertTrue(status.stringValue.contains("/fixture/serial.log"))
        XCTAssertFalse(status.isHidden)
        host.didStart()
        XCTAssertEqual(host.window.title, "VirelaiOS")
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(status.isHidden)
        XCTAssertTrue(host.window.firstResponder === view)
        host.window.makeFirstResponder(nil)
        host.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertTrue(host.window.firstResponder === view)
        host.showFailure("fixture VZ refusal")
        XCTAssertEqual(host.window.title, "VirelaiOS — VM failed")
        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(host.window.firstResponder === view)
        XCTAssertFalse(status.isHidden)
        XCTAssertTrue(status.stringValue.contains("fixture VZ refusal"))
        XCTAssertTrue(status.stringValue.contains("/fixture/serial.log"))
    }

    func testCloseQuitAndLateStartShareOneStopAndKeepWindowUntilCleanup() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        var stops: [String] = []
        host.onStop = { reason, code in
            stops.append(reason)
            XCTAssertEqual(code, 0)
        }
        XCTAssertFalse(host.windowShouldClose(host.window))
        XCTAssertEqual(host.window.title, "VirelaiOS — Stopping VM")
        XCTAssertEqual(host.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        host.didStart()
        XCTAssertEqual(host.window.title, "VirelaiOS — Stopping VM")
        XCTAssertEqual(stops, ["window-close"])
    }

    func testQuitAfterFailureReturnsFailureStatus() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        var stops: [Int32] = []
        host.onStop = { _, code in stops.append(code) }
        host.showFailure("fixture failure")
        XCTAssertEqual(host.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        host.stop("signal", code: 143)
        XCTAssertEqual(stops, [1])
    }

    // MARK: M128c (#2607) — the .virelaivm Finder document surface.

    /// The pre-boot capture records every URL the open-documents event
    /// delivers; the boot target prefers a `.virelaivm` bundle over a
    /// foreign document, and the single-file `openFile` edge lands in
    /// the same capture.
    func testOpenDocumentsCapturePrefersVirelaiVMBundle() {
        let opener = HostOpenDocuments()
        XCTAssertNil(opener.openedURL)
        opener.application(NSApplication.shared, open: [
            URL(fileURLWithPath: "/tmp/notes.txt"),
            URL(fileURLWithPath: "/tmp/clicked.virelaivm"),
        ])
        XCTAssertEqual(opener.openedURL?.path, "/tmp/clicked.virelaivm")
        XCTAssertTrue(opener.application(NSApplication.shared, openFile: "/tmp/second.virelaivm"))
        XCTAssertEqual(opener.documents.count, 3)
        XCTAssertEqual(opener.openedURL?.path, "/tmp/clicked.virelaivm")
    }

    /// A `.virelaivm` click landing on a live session is a second
    /// machine — refused by name through the notify seam, recorded for
    /// the receipt, and reported to AppKit as handled (true) so no
    /// generic LaunchServices dialog stacks on top.
    func testOpenDocumentRefusesSecondProfileWhileSessionRuns() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        var messages: [String] = []
        host.openRefusalNotify = { messages.append($0) }
        host.didStart() // a machine occupies the window

        let clicked = URL(fileURLWithPath: "/tmp/other.virelaivm")
        host.application(NSApplication.shared, open: [clicked])
        XCTAssertEqual(host.refusedOpens, [clicked])
        XCTAssertEqual(host.lastRefusalReason, "a machine already occupies this window")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("other"))
        XCTAssertTrue(host.application(NSApplication.shared, openFile: "/tmp/third.virelaivm"))
        XCTAssertEqual(host.refusedOpens.count, 2)
    }

    /// Refusal holds from the pre-start window too — `starting` already
    /// owns a boot shape — and a foreign (non-.virelaivm) open names its
    /// own reason.
    func testOpenDocumentRefusesWhileStartingAndForeignDocuments() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        host.openRefusalNotify = { _ in }
        host.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/boot.virelaivm")])
        XCTAssertEqual(host.lastRefusalReason, "a machine already occupies this window")
        host.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/readme.txt")])
        XCTAssertEqual(host.lastRefusalReason, "not a .virelaivm bundle")
        XCTAssertEqual(host.refusedOpens.count, 2)
    }

    // MARK: M122d (#2573) — the toolbar's bus surfaces + the ⌘/ sheet.

    private func toolbarItem(_ host: HostApplication,
                             _ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        host.toolbar(host.window.toolbar!, itemForItemIdentifier: id,
                     willBeInsertedIntoToolbar: true)
    }

    /// The default set carries the card's items — the machine/debug
    /// actions left of the spring, the status pills right; the AGENT
    /// pill stays conditional on its companion being armed.
    func testToolbarDefaultSetCarriesTheCardItems() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        let ids = host.toolbarDefaultItemIdentifiers(host.window.toolbar!)
        XCTAssertEqual(ids, [
            HostApplication.inspectorToolbarItem, HostApplication.screenshotToolbarItem,
            HostApplication.recordToolbarItem, HostApplication.sendFileToolbarItem,
            .flexibleSpace, HostApplication.lanesToolbarItem,
            HostApplication.captureKeysToolbarItem,
        ])
        XCTAssertEqual(ids, host.toolbarAllowedItemIdentifiers(host.window.toolbar!))
    }

    /// Each single-verb item is a bus surface: the button's identifier
    /// carries the verb's wire name, the item's target is the window's
    /// validation seam, and enablement is the bus's own — a verb with
    /// no registration greys before any tap.
    func testToolbarItemsAreBusSurfaces() throws {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        var lines: [String] = []
        host.commandBus.emit = { lines.append($0) }
        let expected: [(NSToolbarItem.Identifier, HostCommand, Bool)] = [
            (HostApplication.inspectorToolbarItem, .inspector, true),   // the session registers it
            (HostApplication.screenshotToolbarItem, .screenshot, false),// runner-side, absent here
            (HostApplication.recordToolbarItem, .record, false),        // no view + no share
            (HostApplication.sendFileToolbarItem, .sendFile, false),    // no drop lane
        ]
        for (id, command, enabled) in expected {
            let item = try XCTUnwrap(toolbarItem(host, id), "\(id.rawValue) must build")
            XCTAssertTrue(item.target === host, "\(id.rawValue) must validate on the window")
            let pill = try XCTUnwrap(item.view as? NSButton)
            XCTAssertTrue(pill.target === host)
            XCTAssertEqual(HostCommand(rawValue: pill.identifier!.rawValue), command,
                           "\(id.rawValue) must carry its verb's wire name")
            XCTAssertEqual(pill.isEnabled, enabled, "\(id.rawValue) enablement is the bus's")
        }
        // A click on an enabled item is a dispatch — the inspector pill
        // lands the identical receipt the menu's ⌥⌘I does, and the
        // pill's pressed state mirrors the drawer it opened.
        let item = try XCTUnwrap(toolbarItem(host, HostApplication.inspectorToolbarItem))
        let pill = try XCTUnwrap(item.view as? NSButton)
        pill.performClick(nil)
        XCTAssertTrue(host.inspectorVisible)
        XCTAssertTrue(host.validateToolbarItem(item))
        XCTAssertEqual(pill.state, .on)
        XCTAssertEqual(lines, ["host-ui: cmd=inspector state=performed open=1 tail=0 saw=0"])
    }

    /// The lanes pill greys while the run has no lane, arms on the
    /// first registered lane verb, and counts flowing-of-armed — while
    /// its dropdown leaves are bus items whose checkmark and greying
    /// are validateMenuItem's own projection.
    func testLanesPillArmsOnRegisteredLaneVerbs() throws {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        var lines: [String] = []
        host.commandBus.emit = { lines.append($0) }
        let item = try XCTUnwrap(toolbarItem(host, HostApplication.lanesToolbarItem))
        let pill = try XCTUnwrap(item.view as? NSButton)
        // No lanes in a bare session — the pill is honest chrome about
        // nothing, so it greys (lane-agent's self-registration does not
        // pretend a channel that is not armed).
        XCTAssertFalse(host.lanesArmed)
        XCTAssertEqual(host.lanesPillText, "Lanes 0/0")
        XCTAssertFalse(host.validateToolbarItem(item))
        XCTAssertFalse(pill.isEnabled)
        // The dropdown always names the lane set — each leaf a bus
        // item carrying its verb.
        let menu = host.lanesMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Clipboard", "File Drop", "Notifications", "Agent Channel"])
        XCTAssertEqual(menu.items.compactMap { $0.representedObject as? HostCommand },
                       HostApplication.laneVerbs)
        for leaf in menu.items {
            XCTAssertTrue(leaf.target === host.commandBus)
            XCTAssertEqual(leaf.action, #selector(HostCommandBus.dispatchItem(_:)))
        }
        // A lane registering is what arms the pill — the runner's own
        // registration shape.
        var laneOn = true
        host.commandBus.register(.laneClipboard, HostCommandBus.Registration(
            itemState: { laneOn },
            action: { laneOn.toggle(); return .performed }))
        XCTAssertTrue(host.lanesArmed)
        XCTAssertEqual(host.lanesPillText, "Lanes 1/1")
        XCTAssertTrue(host.validateToolbarItem(item))
        XCTAssertTrue(pill.isEnabled)
        XCTAssertEqual(pill.title, "Lanes 1/1")
        // A leaf's dispatch is the bus's, and the checkmark is the
        // lane's live state — suspending drops the flowing count.
        host.commandBus.dispatchItem(menu.items[0])
        XCTAssertEqual(host.lanesPillText, "Lanes 0/1")
        XCTAssertEqual(lines, ["host-ui: cmd=lane-clipboard state=performed"])
        XCTAssertTrue(host.commandBus.validateMenuItem(menu.items[0]))
        XCTAssertEqual(menu.items[0].state, .off)
    }

    /// The ⌘/ verb is a session verb too — the model's isOpen is the
    /// sheet's truth, and a second dispatch closes it (the settings
    /// panel's precedent, headless-legible).
    func testShortcutsSheetMirrorsTheModel() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        var lines: [String] = []
        host.commandBus.emit = { lines.append($0) }
        XCTAssertFalse(host.shortcutsVisible)
        XCTAssertEqual(host.commandBus.dispatch(.shortcuts), .performed)
        XCTAssertTrue(host.shortcutsVisible)
        XCTAssertEqual(host.commandBus.dispatch(.shortcuts), .performed)
        XCTAssertFalse(host.shortcutsVisible)
        XCTAssertEqual(lines, [
            "host-ui: cmd=shortcuts state=performed open=1 chords=8",
            "host-ui: cmd=shortcuts state=performed open=0 chords=8",
        ])
    }
}
