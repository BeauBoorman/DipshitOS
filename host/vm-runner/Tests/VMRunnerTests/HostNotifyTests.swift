import Foundation
import XCTest
@testable import VMAppKit
@testable import VMRunner

/// M127c (#2601, ADR 0051 V2-D3): notify click-through, host half. The
/// whole lane is files — a real `HostIntSession.arm` on a temp share gives
/// the lane dir, the epoch and the key, so consume → click → emit runs
/// class-A with the bare-runner posture forced (`bundled = false`: the
/// xctest bundle has an identifier but no consent-owning app).
final class HostNotifyTests: XCTestCase {
    private let key = String(repeating: "k", count: 64)

    private func makeSession(mask: UInt8 = HostInt.laneNotify) throws -> (URL, HostIntSession) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostnotify-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try "#v1\nhost-int\t1000\t\(key)\tGOTABWM.ELF\n".write(
            to: dir.appendingPathComponent("SECRETS.TXT"), atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(HostIntSession.arm(shareDir: dir, mask: mask, requested: ["notify"]))
        return (dir, session)
    }

    private func makeLane(_ session: HostIntSession) -> HostNotify {
        let lane = HostNotify(session: session)
        lane.bundled = false // the bare gate runner's posture
        return lane
    }

    /// Plant one signed NOTIFY_OUT the way the seat emits it.
    private func plantNotifyOut(_ session: HostIntSession, sender: UInt16, seq: UInt32, text: String) throws {
        let rec = try XCTUnwrap(HostInt.encode(tag: .notifyOut, flags: 0, sender: sender, seq: seq,
                                               epoch: session.epoch, payload: Data(text.utf8),
                                               key: session.key))
        try rec.write(to: session.laneDir.appendingPathComponent(
            HostInt.recordName(tag: .notifyOut, seq: seq)))
    }

    private func nfocusFiles(_ session: HostIntSession) -> [String] {
        (HostInt.records(laneDir: session.laneDir, tag: .notifyFocus) ?? []).map(\.0)
    }

    private func decodeNFocus(_ session: HostIntSession, seq: UInt32) throws -> HostInt.Record {
        let url = session.laneDir.appendingPathComponent(HostInt.recordName(tag: .notifyFocus, seq: seq))
        return try XCTUnwrap(HostInt.decode(try Data(contentsOf: url)))
    }

    func testConsumeRemembersSender() throws {
        let (_, session) = try makeSession()
        let lane = makeLane(session)
        try plantNotifyOut(session, sender: 7, seq: 1, text: "build done")
        lane.tick()
        XCTAssertEqual(lane.consumedSender(seq: 1), 7)
        // The record was consumed (deleted), not just read.
        XCTAssertTrue((HostInt.records(laneDir: session.laneDir, tag: .notifyOut) ?? []).isEmpty)
    }

    func testClickEmitsSignedNotifyFocus() throws {
        let (_, session) = try makeSession()
        let lane = makeLane(session)
        lane.click(sender: 7)
        let rec = try decodeNFocus(session, seq: 1)
        XCTAssertEqual(rec.tag, .notifyFocus)
        XCTAssertEqual(rec.sender, 7)
        XCTAssertEqual(rec.epoch, session.epoch)
        XCTAssertEqual(rec.payload.count, 0) // plen MUST be 0 — the header is the whole request
        XCTAssertTrue(HostInt.verify(rec, key: session.key))
    }

    func testClickSenderZeroEmitsNoRecord() throws {
        // V2-D3: a seat-originated toast has no tab to focus — the runner
        // raises its window and stops; emitting could only draw `gone`.
        let (_, session) = try makeSession()
        let lane = makeLane(session)
        lane.click(sender: 0)
        XCTAssertTrue(nfocusFiles(session).isEmpty)
    }

    func testClickSuspendedLaneEmitsNoRecord() throws {
        let (_, session) = try makeSession()
        let lane = makeLane(session)
        XCTAssertTrue(session.setSuspended(HostInt.laneNotify, true))
        lane.click(sender: 7)
        XCTAssertTrue(nfocusFiles(session).isEmpty)
    }

    func testClickBackpressuredEmitsNoRecord() throws {
        // Four unconsumed NFOCUS records fill the outbound bound — a fifth
        // click waits for the seat to drain, like every h→g emit.
        let (_, session) = try makeSession()
        let lane = makeLane(session)
        for seq in 1...UInt32(HostInt.maxOutstanding) {
            let rec = try XCTUnwrap(HostInt.encode(tag: .notifyFocus, flags: 0, sender: 1, seq: seq,
                                                   epoch: session.epoch, payload: Data(),
                                                   key: session.key))
            try rec.write(to: session.laneDir.appendingPathComponent(
                HostInt.recordName(tag: .notifyFocus, seq: seq)))
        }
        lane.click(sender: 7)
        XCTAssertEqual(nfocusFiles(session).count, HostInt.maxOutstanding)
    }

    func testNotifyClickVerbDispatchesClickPath() throws {
        let (_, session) = try makeSession()
        let lane = makeLane(session)
        var lines: [String] = []
        let bus = HostCommandBus { lines.append($0) }
        lane.registerVerbs(on: bus)

        // Nothing consumed yet — the verb receipts `disabled`, never a
        // record it cannot correlate.
        XCTAssertEqual(bus.dispatch(.notifyClick), .disabled)
        XCTAssertTrue(nfocusFiles(session).isEmpty)

        try plantNotifyOut(session, sender: 9, seq: 1, text: "build done")
        lane.tick()
        XCTAssertEqual(bus.dispatch(.notifyClick), .performed)
        XCTAssertTrue(lines.contains("host-ui: cmd=notify-click state=performed"))

        // The verb answered the most recent consumed record's sender.
        let rec = try decodeNFocus(session, seq: 1)
        XCTAssertEqual(rec.sender, 9)
        XCTAssertTrue(HostInt.verify(rec, key: session.key))
    }

    func testVerbTargetsMostRecentConsumed() throws {
        // The verb answers the NEWEST consumed record — two consumed
        // senders, one click, the latest wins.
        let (_, session) = try makeSession()
        let lane = makeLane(session)
        var lines: [String] = []
        let bus = HostCommandBus { lines.append($0) }
        lane.registerVerbs(on: bus)

        try plantNotifyOut(session, sender: 3, seq: 1, text: "first")
        lane.tick()
        try plantNotifyOut(session, sender: 8, seq: 2, text: "second")
        lane.tick()
        XCTAssertEqual(bus.dispatch(.notifyClick), .performed)
        let rec = try decodeNFocus(session, seq: 1)
        XCTAssertEqual(rec.sender, 8)
    }
}
