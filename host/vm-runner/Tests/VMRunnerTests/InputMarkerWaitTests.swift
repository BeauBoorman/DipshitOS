import Foundation
import XCTest

@testable import VMRunner

// #2703: the --input-string marker watch must reach a marker deep into a
// long session — go-dogfood boot 04's `gotabwm: tab close id=` lands ~160 s
// in, past the old fixed 40 s window. The policy (shared with --input-key
// since M73z / #1638) is max(40 s, --timeout): a 40 s floor so existing
// short-timeout gates keep their window, and the session timeout as the
// ceiling since no marker can arrive after the VM is gone.
final class InputMarkerWaitTests: XCTestCase {
    func testDefaultTimeoutKeepsFortySecondFloor() {
        XCTAssertEqual(inputMarkerWaitSeconds(sessionTimeout: 30), 40)
    }

    func testLongSessionExtendsTheWatchToTheRunDeadline() {
        // boot 04 passes --timeout 300; the ~160 s marker must be inside.
        XCTAssertEqual(inputMarkerWaitSeconds(sessionTimeout: 300), 300)
    }

    func testFloorBoundaryAndZero() {
        XCTAssertEqual(inputMarkerWaitSeconds(sessionTimeout: 40), 40)
        XCTAssertEqual(inputMarkerWaitSeconds(sessionTimeout: 0), 40)
    }
}
