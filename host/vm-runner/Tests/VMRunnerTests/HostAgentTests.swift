import AppKit
import CryptoKit
import XCTest
import VMAppKit

/// M127e (#2603, index #2555): the AGENTD companion's class-A surface —
/// the audit-lane reader, the HMAC-SHA256 verification (tampered and
/// forged fixtures must flag rejected, never render as valid), the
/// session trail behind the pill, the `lane-agent` choke's receipts
/// through the bus, and the drawer sub-pane's projection — all without
/// a VM or a presented window (the HostCommandTests precedent: the bus
/// is the seam).
final class HostAgentTests: XCTestCase {
    /// The go-agentd spec's pinned-vector secret (ASCII "a5" x 32) —
    /// the receipt key both ends read from the same SECRETS.TXT row.
    private let key = String(repeating: "a5", count: 32)

    private final class Sink {
        var lines: [String] = []
    }

    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        dirs = []
        super.tearDown()
    }

    // MARK: - fixtures

    /// A share staged exactly like the go-agentd spec's: #v1
    /// SECRETS.TXT with the agent-hmac row (uid 2000, app-bound), and
    /// the AGENT/AUDIT lane.
    private func makeShare(secrets: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostagent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("AGENT/AUDIT", isDirectory: true),
            withIntermediateDirectories: true)
        let rows = secrets ?? "#v1\nagent-hmac\t2000\t\(key)\tAGENTD.ELF,GOTOP.ELF\n"
        try rows.write(to: dir.appendingPathComponent("SECRETS.TXT"),
                       atomically: true, encoding: .utf8)
        dirs.append(dir)
        return dir
    }

    /// The M109c receipt shape: the JSON line, then 64 lowercase hex of
    /// HMAC-SHA256(key, line-1 bytes).
    private func receiptBody(_ line: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(line.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return line + "\n" + mac.map { String(format: "%02x", $0) }.joined() + "\n"
    }

    private func writeReceipt(_ share: URL, name: String, body: String) {
        try? body.write(to: share.appendingPathComponent("AGENT/AUDIT/\(name)"),
                        atomically: true, encoding: .utf8)
    }

    private func sessionLine(_ seq: Int, event: String, agent: String = "-") -> String {
        "{\"seq\":\(seq),\"epoch\":\"0000000a\",\"agent\":\"\(agent)\",\"verb\":\"session\",\"args\":{\"event\":\"\(event)\"},\"ts\":1,\"mono\":1,\"result\":\"ok\"}"
    }

    private func companion(_ share: URL, sink: Sink = Sink()) -> HostAgentCompanion {
        let agent = HostAgentCompanion()
        agent.shareDir = share
        agent.arguments = ["vm-runner"] // never resolves the process argv
        agent.emit = { sink.lines.append($0) }
        return agent
    }

    // MARK: - the receipt reader + HMAC verification

    func testValidReceiptVerifiesAndRenders() throws {
        let share = try makeShare()
        let line = "{\"seq\":1,\"epoch\":\"0000000a\",\"agent\":\"devin\",\"verb\":\"fs.read\",\"args\":{\"path\":\"APP/main.go\"},\"ts\":1,\"mono\":1,\"result\":\"ok\"}"
        writeReceipt(share, name: "RCPT-0000000a-00000001", body: receiptBody(line))
        let agent = companion(share)
        XCTAssertEqual(agent.scan(), 1)
        XCTAssertEqual(agent.verifiedCount, 1)
        XCTAssertEqual(agent.rejectedCount, 0)
        XCTAssertEqual(agent.receipts.count, 1)
        let rcpt = try XCTUnwrap(agent.receipts.first)
        XCTAssertTrue(rcpt.verified)
        XCTAssertEqual(rcpt.agent, "devin")
        XCTAssertEqual(rcpt.verb, "fs.read")
        XCTAssertEqual(rcpt.result, "ok")
        XCTAssertEqual(rcpt.args, "path=APP/main.go")
        XCTAssertEqual(rcpt.row, "RCPT-0000000a-00000001 ✓ devin fs.read ok path=APP/main.go")
    }

    /// The card's core promise: a receipt edited after signing is
    /// flagged rejected — a row that says ✗, never one that says ✓.
    func testTamperedReceiptIsFlaggedRejected() throws {
        let share = try makeShare()
        let good = "{\"seq\":1,\"epoch\":\"0000000a\",\"agent\":\"devin\",\"verb\":\"fs.read\",\"args\":{},\"ts\":1,\"mono\":1,\"result\":\"ok\"}"
        // The writer signs "ok"; the tamperer flips it to a refusal
        // replay without re-signing — the MAC cannot cover the edit.
        var tampered = receiptBody(good)
        tampered = tampered.replacingOccurrences(
            of: "\"result\":\"ok\"", with: "\"result\":\"refuse:auth\"")
        writeReceipt(share, name: "RCPT-0000000a-00000001", body: tampered)
        let agent = companion(share)
        XCTAssertEqual(agent.scan(), 1)
        XCTAssertEqual(agent.verifiedCount, 0)
        XCTAssertEqual(agent.rejectedCount, 1)
        let rcpt = try XCTUnwrap(agent.receipts.first)
        XCTAssertFalse(rcpt.verified)
        XCTAssertEqual(rcpt.reason, "bad_mac")
        XCTAssertEqual(rcpt.row, "RCPT-0000000a-00000001 ✗ bad_mac")
        // The tampered result never reaches the model — the row keeps
        // the name only, flagged.
        XCTAssertFalse(agent.receiptRows.joined().contains("refuse:auth"))
    }

    func testForgedAndMalformedReceiptsFlagRejected() throws {
        let share = try makeShare()
        let line = "{\"seq\":1,\"epoch\":\"0000000a\",\"agent\":\"x\",\"verb\":\"fs.read\",\"args\":{},\"ts\":1,\"mono\":1,\"result\":\"ok\"}"
        // A forged MAC — the right shape, the wrong bytes.
        writeReceipt(share, name: "RCPT-0000000a-00000001",
                     body: line + "\n" + String(repeating: "00", count: 32) + "\n")
        // A truncated file — the MAC line never landed.
        writeReceipt(share, name: "RCPT-0000000a-00000002", body: line + "\n")
        // Not a receipt at all.
        writeReceipt(share, name: "RCPT-0000000a-00000003", body: "garbage\n")
        let agent = companion(share)
        XCTAssertEqual(agent.scan(), 3)
        XCTAssertEqual(agent.verifiedCount, 0)
        XCTAssertEqual(agent.rejectedCount, 3)
        XCTAssertEqual(agent.receipts.map(\.reason), ["bad_mac", "malformed", "malformed"])
        XCTAssertTrue(agent.receiptRows.allSatisfy { $0.contains("✗") })
    }

    /// A lane with no agent-hmac row cannot verify anything — rows
    /// still land, flagged no_key rather than mistaken for valid.
    func testMissingKeyFlagsNoKey() throws {
        let share = try makeShare(secrets: "#v1\n")
        let line = "{\"seq\":1,\"epoch\":\"0000000a\",\"agent\":\"x\",\"verb\":\"fs.read\",\"args\":{},\"ts\":1,\"mono\":1,\"result\":\"ok\"}"
        writeReceipt(share, name: "RCPT-0000000a-00000001", body: receiptBody(line))
        let agent = companion(share)
        XCTAssertEqual(agent.scan(), 1)
        XCTAssertEqual(agent.receipts.first?.reason, "no_key")
        XCTAssertEqual(agent.rejectedCount, 1)
    }

    /// Foreign files in the lane — the publish temp, other names —
    /// are neither receipts nor rejections.
    func testNonReceiptNamesAreIgnored() throws {
        let share = try makeShare()
        writeReceipt(share, name: "RCPT-0000000a-00000001~", body: "x\n")
        writeReceipt(share, name: "NOTES.TXT", body: "x\n")
        writeReceipt(share, name: "RCPT-bad", body: "x\n")
        let agent = companion(share)
        XCTAssertEqual(agent.scan(), 0)
        XCTAssertEqual(agent.receipts.count, 0)
    }

    // MARK: - the session trail behind the pill

    func testSessionEventsDriveSessionsAndThePill() throws {
        let share = try makeShare()
        writeReceipt(share, name: "RCPT-0000000a-00000001",
                     body: receiptBody(sessionLine(1, event: "open", agent: "devin")))
        writeReceipt(share, name: "RCPT-0000000a-00000002",
                     body: receiptBody(sessionLine(2, event: "auth_fail", agent: "mallory")))
        writeReceipt(share, name: "RCPT-0000000a-00000003",
                     body: receiptBody(sessionLine(3, event: "close", agent: "devin")))
        let agent = companion(share)
        XCTAssertEqual(agent.scan(), 3)
        // open then close nets zero live sessions; the auth failure is
        // its own count, never a session.
        XCTAssertEqual(agent.liveSessions, 0)
        XCTAssertEqual(agent.authFailures, 1)
        XCTAssertEqual(agent.pillText, "AGENT ○")
        XCTAssertEqual(agent.agentSummary,
                       "Agent sessions=0 rcpts=3 bad=0 paused=0")
    }

    func testOpenSessionShowsTheLiveDot() throws {
        let share = try makeShare()
        writeReceipt(share, name: "RCPT-0000000a-00000001",
                     body: receiptBody(sessionLine(1, event: "open", agent: "devin")))
        let agent = companion(share)
        agent.scan()
        XCTAssertEqual(agent.liveSessions, 1)
        XCTAssertEqual(agent.pillText, "AGENT ●")
    }

    /// Rejected receipts surface on the pill — tamper evidence without
    /// opening the drawer.
    func testRejectedReceiptsMarkThePill() throws {
        let share = try makeShare()
        writeReceipt(share, name: "RCPT-0000000a-00000001",
                     body: "forged\n" + String(repeating: "00", count: 32) + "\n")
        let agent = companion(share)
        agent.scan()
        XCTAssertEqual(agent.pillText, "AGENT ○ !1")
    }

    // MARK: - lane-agent through the bus

    /// The `cmd=lane-agent` receipt leg: an armed channel + a live
    /// endpoint toggles the choke and the receipt names the new state.
    func testLaneAgentPauseResumeThroughTheBus() {
        let sink = Sink()
        let agent = HostAgentCompanion()
        agent.arguments = ["vm-runner", "--net-tcp-connect-stream", "/fixture/agent.py"]
        var signals: [(pid_t, Int32)] = []
        agent.endpointPIDs = { _ in [4242] }
        agent.signalEndpoint = { pid, sig in signals.append((pid, sig)); return true }
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, agent: agent)
        defer { agent.stopPolling() }

        XCTAssertEqual(bus.dispatch(.laneAgent), .performed)
        XCTAssertTrue(agent.paused)
        XCTAssertEqual(signals.count, 1)
        XCTAssertTrue(signals.first?.0 == 4242 && signals.first?.1 == SIGSTOP)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=lane-agent state=performed paused=1 sessions=0 rcpts=0 bad=0")

        XCTAssertEqual(bus.dispatch(.laneAgent), .performed)
        XCTAssertFalse(agent.paused)
        XCTAssertEqual(signals.count, 2)
        XCTAssertTrue(signals.last?.0 == 4242 && signals.last?.1 == SIGCONT)
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=lane-agent state=performed paused=0 sessions=0 rcpts=0 bad=0")
    }

    /// ADR 0051 v2: `unavailable` when no agent channel is armed.
    func testLaneAgentUnarmedReceiptsUnavailable() {
        let sink = Sink()
        let agent = HostAgentCompanion()
        agent.arguments = ["vm-runner"] // no --net-tcp-connect-stream
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, agent: agent)
        defer { agent.stopPolling() }
        XCTAssertEqual(bus.dispatch(.laneAgent), .unavailable)
        // A registered verb reports its live state even on unavailable —
        // the bus's disabled/failed detail precedent.
        XCTAssertEqual(sink.lines.last,
                       "host-ui: cmd=lane-agent state=unavailable paused=0 sessions=0 rcpts=0 bad=0")
    }

    /// Armed but the endpoint child is not running — the choke refuses
    /// rather than pretending a freeze happened.
    func testLaneAgentArmedEndpointDeadReceiptsDisabled() {
        let sink = Sink()
        let agent = HostAgentCompanion()
        agent.arguments = ["vm-runner", "--net-tcp-connect-stream", "/fixture/agent.py"]
        agent.endpointPIDs = { _ in [] }
        let bus = HostCommandBus(emit: { sink.lines.append($0) }, agent: agent)
        defer { agent.stopPolling() }
        XCTAssertEqual(bus.dispatch(.laneAgent), .disabled)
        XCTAssertFalse(agent.paused)
    }

    /// The Integration menu projects the verb — item present, dispatches
    /// on the bus, checkmark reads "the lane is flowing".
    func testAgentChannelMenuItemMirrorsTheChoke() throws {
        let agent = HostAgentCompanion()
        agent.arguments = ["vm-runner", "--net-tcp-connect-stream", "/fixture/agent.py"]
        agent.endpointPIDs = { _ in [4242] }
        agent.signalEndpoint = { _, _ in true }
        let bus = HostCommandBus(emit: { _ in }, agent: agent)
        defer { agent.stopPolling() }
        let bar = HostMenuBar.build(bus: bus)
        let item = try XCTUnwrap(
            bar.items.first { $0.submenu?.title == "Integration" }?.submenu?.items
                .first { $0.title == "Agent Channel" })
        XCTAssertEqual(item.representedObject as? HostCommand, .laneAgent)
        XCTAssertTrue(bus.validateMenuItem(item))
        XCTAssertEqual(item.state, NSControl.StateValue.on) // flowing
        bus.dispatchItem(item)
        XCTAssertTrue(agent.paused)
        XCTAssertTrue(bus.validateMenuItem(item))
        XCTAssertEqual(item.state, NSControl.StateValue.off) // frozen
    }

    // MARK: - the drawer sub-pane

    /// The sub-pane lists verified rows beside flagged ones — the
    /// tampered fixture is visible AS a rejection, not hidden.
    func testDrawerSubPaneProjectsReceipts() throws {
        let share = try makeShare()
        writeReceipt(share, name: "RCPT-0000000a-00000001",
                     body: receiptBody(sessionLine(1, event: "open", agent: "devin")))
        var tampered = receiptBody(sessionLine(2, event: "close"))
        tampered = tampered.replacingOccurrences(of: "close", with: "op3n")
        writeReceipt(share, name: "RCPT-0000000a-00000002", body: tampered)
        let agent = companion(share)
        let bus = HostCommandBus(emit: { _ in }, agent: agent)
        defer { agent.stopPolling() }
        let view = HostInspectorView(model: HostInspector(), bus: bus)
        view.reload()
        XCTAssertTrue(view.agentSubpaneVisible)
        XCTAssertEqual(view.agentSummaryText,
                       "AGENTD — Agent sessions=1 rcpts=1 bad=1 paused=0")
        XCTAssertEqual(view.renderedAgentText, """
            RCPT-0000000a-00000001 ✓ session open devin
            RCPT-0000000a-00000002 ✗ bad_mac
            """)
    }

    /// No share, no channel — the sub-pane is absent chrome, not an
    /// empty list claiming a lane exists.
    func testDrawerSubPaneHiddenWhenUnarmed() {
        let agent = HostAgentCompanion()
        agent.arguments = ["vm-runner"] // neither flag
        let bus = HostCommandBus(emit: { _ in }, agent: agent)
        defer { agent.stopPolling() }
        let view = HostInspectorView(model: HostInspector(), bus: bus)
        view.reload()
        XCTAssertFalse(view.agentSubpaneVisible)
        XCTAssertEqual(view.renderedAgentText, "")
    }

    // MARK: - the pill's visibility (HostApplication seams)

    func testAgentPillFollowsCompanionArming() {
        let host = HostApplication(serialLog: "/fixture/serial.log", presentWindow: false)
        // The test process's argv arms nothing — the pill is absent.
        XCTAssertFalse(host.agentPillVisible)
        XCTAssertEqual(host.agentPillText, "AGENT ○")
    }

    // MARK: - grammar pins

    func testReceiptNameGrammar() {
        XCTAssertTrue(HostAgentCompanion.isReceiptName("RCPT-0000000a-00000001"))
        XCTAssertTrue(HostAgentCompanion.isReceiptName("RCPT-FFFFFFFF-00000001"))
        XCTAssertFalse(HostAgentCompanion.isReceiptName("RCPT-0000000a-00000001~"))
        XCTAssertFalse(HostAgentCompanion.isReceiptName("RCPT-0000000a-0000001"))   // short
        XCTAssertFalse(HostAgentCompanion.isReceiptName("RCPT-0000000g-00000001"))   // non-hex
        XCTAssertFalse(HostAgentCompanion.isReceiptName("RCPT-0000000aX00000001"))   // wrong dash
        XCTAssertFalse(HostAgentCompanion.isReceiptName("rcpt-0000000a-00000001"))
    }

    /// The key row must carry uid 2000 — the uid_agent row agentd
    /// reads — and live under a #v1 header.
    func testKeyRowGrammar() throws {
        let share = try makeShare()
        XCTAssertEqual(HostAgentCompanion.loadKey(shareDir: share), Data(key.utf8))
        let wrongUID = try makeShare(secrets: "#v1\nagent-hmac\t0\t\(key)\n")
        XCTAssertNil(HostAgentCompanion.loadKey(shareDir: wrongUID))
        let noScheme = try makeShare(secrets: "agent-hmac\t2000\t\(key)\n")
        XCTAssertNil(HostAgentCompanion.loadKey(shareDir: noScheme))
    }
}
