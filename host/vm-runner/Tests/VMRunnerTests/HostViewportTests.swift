import AppKit
import XCTest
import VMAppKit

/// M114b (#2455, index #2447): the viewport chrome — a resizable,
/// fullscreen-capable window whose content is aspect-locked to the 16:9
/// guest scanout, and the `capturesSystemKeys` toggle (menu / toolbar
/// pill / --host-capture-keys all dispatch `capture-keys` on the bus)
/// with its visible "keys captured" affordance. All class-A: no VM, no
/// activation, no synthesized clicks — the bus is the seam.
final class HostViewportTests: XCTestCase {
    private final class Sink {
        var lines: [String] = []
    }

    /// Stands in for the runner's TraceView — the HostKeyCapturing seam
    /// keeps Virtualization out of the test process entirely.
    private final class FakeMachineView: NSView, HostKeyCapturing {
        var capturesSystemKeys = false
    }

    private func makeHost() -> (HostApplication, Sink) {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        let sink = Sink()
        host.commandBus.emit = { sink.lines.append($0) }
        return (host, sink)
    }

    func testWindowIsResizableFullscreenCapableAndAspectLocked() {
        let (host, _) = makeHost()
        XCTAssertTrue(host.window.styleMask.contains(.resizable))
        XCTAssertTrue(host.window.collectionBehavior.contains(.fullScreenPrimary))
        // The content aspect is locked to the guest's 16:9 scanout — host
        // scaling can never distort the framebuffer.
        XCTAssertEqual(host.window.contentAspectRatio, NSSize(width: 16, height: 9))
        XCTAssertEqual(host.window.contentMinSize, NSSize(width: 640, height: 360))
    }

    func testViewportVerbsAreSessionRegistrations() {
        let (host, _) = makeHost()
        for verb in [HostCommand.fullscreen, .captureKeys] {
            XCTAssertTrue(host.commandBus.isRegistered(verb), "\(verb.rawValue) must be a session verb")
        }
    }

    func testCaptureKeysTogglesTheAttachedViewAndReceiptsItsState() throws {
        let (host, sink) = makeHost()
        let view = FakeMachineView()
        host.attach(view)
        XCTAssertFalse(view.capturesSystemKeys)
        XCTAssertFalse(host.keysCaptureAffordanceVisible)
        XCTAssertEqual(host.commandBus.dispatch(.captureKeys), .performed)
        XCTAssertTrue(view.capturesSystemKeys)
        XCTAssertTrue(host.keysCaptureAffordanceVisible)
        XCTAssertEqual(host.commandBus.dispatch(.captureKeys), .performed)
        XCTAssertFalse(view.capturesSystemKeys)
        XCTAssertFalse(host.keysCaptureAffordanceVisible)
        XCTAssertEqual(sink.lines, [
            "host-ui: cmd=capture-keys state=performed capture=on",
            "host-ui: cmd=capture-keys state=performed capture=off",
        ])
        // The menu item's checkmark reads the same live property.
        let bar = HostMenuBar.build(bus: host.commandBus)
        let item = try XCTUnwrap(bar.items.first { $0.submenu?.title == "View" }?
            .submenu?.items.first { $0.title == "Capture System Keys" })
        XCTAssertEqual(item.keyEquivalent, "k")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .command])
        view.capturesSystemKeys = true
        XCTAssertTrue(host.commandBus.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        view.capturesSystemKeys = false
        XCTAssertTrue(host.commandBus.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    func testCaptureKeysIsDisabledWithoutAMachineView() {
        let (host, sink) = makeHost()
        // A plain NSView attach (never the case in the runner, but the
        // class-A seam) leaves the verb disabled rather than crashing.
        host.attach(NSView())
        XCTAssertEqual(host.commandBus.dispatch(.captureKeys), .disabled)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=capture-keys state=disabled"])
    }

    func testFullscreenVerbGatesOnWindowVisibility() {
        let (host, sink) = makeHost()
        // A never-presented window reports disabled — the verb refuses
        // rather than toggling fullscreen into the void. The performed
        // path is the class-B leg's job (the evidence window is ordered
        // front, so it is enabled there).
        XCTAssertEqual(host.commandBus.dispatch(.fullscreen), .disabled)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=fullscreen state=disabled"])
    }

    func testToolbarPillIsABusSurface() throws {
        let (host, sink) = makeHost()
        let view = FakeMachineView()
        host.attach(view)
        let toolbar = try XCTUnwrap(host.window.toolbar)
        XCTAssertTrue(host.toolbarDefaultItemIdentifiers(toolbar)
            .contains(HostApplication.captureKeysToolbarItem))
        let item = try XCTUnwrap(host.toolbar(
            toolbar,
            itemForItemIdentifier: HostApplication.captureKeysToolbarItem,
            willBeInsertedIntoToolbar: false))
        let pill = try XCTUnwrap(item.view as? NSButton)
        pill.performClick(nil)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=capture-keys state=performed capture=on"])
        XCTAssertTrue(view.capturesSystemKeys)
        XCTAssertEqual(pill.state, .on)
        XCTAssertTrue(host.keysCaptureAffordanceVisible)
    }
}
