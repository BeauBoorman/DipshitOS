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
}
