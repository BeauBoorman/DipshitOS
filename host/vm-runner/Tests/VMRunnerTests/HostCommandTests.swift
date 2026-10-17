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

    func testActionCanReportFailure() {
        let sink = Sink()
        let bus = makeBus(sink)
        bus.register(.screenshot, HostCommandBus.Registration { .failed })
        XCTAssertEqual(bus.dispatch(.screenshot), .failed)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=screenshot state=failed"])
    }

    func testMenuBarIsTheFiveMenusOfBusActions() throws {
        let bus = HostCommandBus()
        let bar = HostMenuBar.build(bus: bus)
        XCTAssertEqual(bar.items.compactMap { $0.submenu?.title },
                       ["VirelaiOS", "Machine", "View", "Integration", "Debug"])
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
}
