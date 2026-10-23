import Foundation
import XCTest
@testable import VMAppKit
@testable import VMRunner

/// M184b (#3175): the DRAGOUT drain — a verified record moves its named
/// OUTBOX payload into DRAGOUT/ staging and parks it for the pointer's
/// next host dragged event; a refused one names its lane reason.
final class HostDragOutTests: XCTestCase {
    private let key = String(repeating: "k", count: 64)

    /// An armed lane on a temp share: session + lane, bundled left off —
    /// the bare-runner posture (no monitor, no banner; staging only).
    private func makeLane() throws -> (URL, HostIntSession, HostOutbox) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostdragout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try "#v1\nhost-int\t1000\t\(key)\tGOTABWM.ELF\n".write(
            to: dir.appendingPathComponent("SECRETS.TXT"), atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(
            HostIntSession.arm(shareDir: dir, mask: HostInt.laneOutbox,
                               requested: ["outbox"]))
        let lane = HostOutbox(session: session, destDir: dir.appendingPathComponent("landing"))
        // Not start(): the bus half of arming reaches process globals a
        // test lane lacks (registerLane → the global session). The unit
        // surface here is the drain, so create the dirs the lane reads.
        let fm = FileManager.default
        try fm.createDirectory(at: HostInt.laneDir(shareDir: dir), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("OUTBOX"), withIntermediateDirectories: true)
        return (dir, session, lane)
    }

    /// The seat's half, replayed: stage OUTBOX/<name> then publish the
    /// signed DRAGOUT record naming it ([name_len][name][size]).
    private func plantDrag(_ dir: URL, session: HostIntSession, name: String,
                           seq: UInt32, payload: Data) throws {
        try payload.write(to: dir.appendingPathComponent("OUTBOX/\(name)"))
        var p = Data([UInt8(name.utf8.count)])
        p.append(name.data(using: .utf8)!)
        var size = UInt64(payload.count).littleEndian
        p.append(Data(bytes: &size, count: 8))
        let rec = try XCTUnwrap(HostInt.encode(
            tag: .dragOut, flags: 0, sender: 7, seq: seq,
            epoch: session.epoch, payload: p, key: Data(key.utf8)))
        XCTAssertTrue(HostInt.publish(
            laneDir: HostInt.laneDir(shareDir: dir),
            name: "DRAGOUT-0000000\(seq)", body: rec))
    }

    func testVerifiedDragOutStagesPayload() throws {
        let (dir, session, lane) = try makeLane()
        let blob = Data("through the glass".utf8)
        try plantDrag(dir, session: session, name: "GuestDrag.txt", seq: 1,
                      payload: blob)
        lane.tick()
        let staged = dir.appendingPathComponent("DRAGOUT/GuestDrag.txt")
        XCTAssertEqual(try Data(contentsOf: staged), blob)
        XCTAssertEqual(lane.pendingDrags, [staged])
        XCTAssertEqual(lane.takePendingDrag(), staged)
        XCTAssertNil(lane.takePendingDrag())
        // The record consumed, the payload moved — neither lingers.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("OUTBOX/GuestDrag.txt").path))
    }

    func testPayloadMissingRefusesGone() throws {
        let (dir, session, lane) = try makeLane()
        // The signed record names a file nobody staged: gone, and the
        // record is still consumed (the refusal is the verdict).
        var p = Data([UInt8("MISSING.TXT".utf8.count)])
        p.append("MISSING.TXT".data(using: .utf8)!)
        var size = UInt64(11).littleEndian
        p.append(Data(bytes: &size, count: 8))
        let rec = try XCTUnwrap(HostInt.encode(
            tag: .dragOut, flags: 0, sender: 7, seq: 1,
            epoch: session.epoch, payload: p, key: Data(key.utf8)))
        XCTAssertTrue(HostInt.publish(
            laneDir: HostInt.laneDir(shareDir: dir),
            name: "DRAGOUT-00000001", body: rec))
        lane.tick()
        XCTAssertTrue(lane.pendingDrags.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: HostInt.laneDir(shareDir: dir)
                .appendingPathComponent("DRAGOUT-00000001").path))
    }

    func testUnsignedRecordIsRefused() throws {
        let (dir, session, lane) = try makeLane()
        let blob = Data("x".utf8)
        try blob.write(to: dir.appendingPathComponent("OUTBOX/A.TXT"))
        // Bad MAC: a plant, never the seat's signature.
        let rec = try XCTUnwrap(HostInt.encode(
            tag: .dragOut, flags: 0, sender: 7, seq: 1,
            epoch: session.epoch, payload: Data(count: 11), key: Data("wrong".utf8)))
        XCTAssertTrue(HostInt.publish(
            laneDir: HostInt.laneDir(shareDir: dir),
            name: "DRAGOUT-00000001", body: rec))
        lane.tick()
        XCTAssertTrue(lane.pendingDrags.isEmpty)
        // The planted payload stays — a refused record never moves a file.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("OUTBOX/A.TXT").path))
    }
}
