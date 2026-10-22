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
        var requested: [String] = []
        if mask & HostInt.laneNotify != 0 { requested.append("notify") }
        if mask & HostInt.laneOutbox != 0 { requested.append("outbox") }
        let session = try XCTUnwrap(HostIntSession.arm(shareDir: dir, mask: mask, requested: requested))
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

    // MARK: - the shared banner delegate + outbox lane verbs

    /// An armed outbox lane on a temp share: session + lane + dest dir,
    /// bundled left false — the bare-runner posture.
    private func makeOutboxLane() throws -> (URL, HostIntSession, HostOutbox) {
        let (dir, session) = try makeSession(mask: HostInt.laneOutbox)
        let dest = dir.appendingPathComponent("landing", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return (dir, session, HostOutbox(session: session, destDir: dest))
    }

    func testBannerRouterRoutesByPrefixAndEpoch() throws {
        // The center's one delegate dispatches a click to the lane whose
        // family and session epoch the request identifier names.
        let (_, notifySession) = try makeSession()
        let (_, outboxSession, outbox) = try makeOutboxLane()
        let notify = makeLane(notifySession)
        let router = HostBannerRouter()
        router.install(notify)
        router.install(outbox)

        XCTAssertTrue(router.route("vhi1-notify-\(notifySession.epoch)-1") as AnyObject === notify)
        XCTAssertTrue(router.route("vhi1-outbox-\(outboxSession.epoch)-7") as AnyObject === outbox)
        // An unknown prefix or a non-identifier consumes, never misroutes.
        XCTAssertNil(router.route("vhi1-bogus-\(notifySession.epoch)-1"))
        XCTAssertNil(router.route("not-a-banner"))
        // An epoch the family doesn't hold falls back to its only lane —
        // a banner built outside the identifier grammar still lands.
        XCTAssertTrue(router.route("vhi1-outbox-0-1") as AnyObject === outbox)
    }

    func testBannerRouterEpochPicksTheSession() throws {
        // Two sessions, two outbox lanes: the identifier's epoch is what
        // binds a click to the lane that posted it.
        let (_, s1, outbox1) = try makeOutboxLane()
        let (_, s2, outbox2) = try makeOutboxLane()
        let router = HostBannerRouter()
        router.install(outbox1)
        router.install(outbox2)

        XCTAssertTrue(router.route("vhi1-outbox-\(s1.epoch)-3") as AnyObject === outbox1)
        XCTAssertTrue(router.route("vhi1-outbox-\(s2.epoch)-3") as AnyObject === outbox2)
        // An epoch neither holds: two lanes, no sole fallback → nil.
        XCTAssertNil(router.route("vhi1-outbox-0-1"))
    }

    func testOutboxVerbsRideTheOwningSessionsBus() throws {
        // lane-outbox/reveal-export resolve the lane's OWNING session —
        // its bus, its mask — never the global.
        let registry = VMSessionRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }

        let (_, session, lane) = try makeOutboxLane()
        let s = registry.mint()
        s.hostInt = session
        s.outbox = lane
        HostIntCommands.registerLane(lane)

        let bus = registry.bus(for: s)
        XCTAssertTrue(bus.isRegistered(.laneOutbox))
        XCTAssertTrue(bus.isRegistered(.revealExport))
        // The toggle flips THIS session's mask bit.
        XCTAssertFalse(session.isSuspended(HostInt.laneOutbox))
        XCTAssertEqual(bus.dispatch(.laneOutbox), .performed)
        XCTAssertTrue(session.isSuspended(HostInt.laneOutbox))
        XCTAssertEqual(bus.dispatch(.laneOutbox), .performed)
        XCTAssertFalse(session.isSuspended(HostInt.laneOutbox))
        // reveal-export is registered but disabled until a landing exists.
        XCTAssertFalse(bus.isEnabled(.revealExport))
        XCTAssertEqual(bus.dispatch(.revealExport), .disabled)
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
