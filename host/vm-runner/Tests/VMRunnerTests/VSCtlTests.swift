// VSCtlTests — the virelai-ctl/1 session matrix (M115b, issue #2461, ADR
// 0056): greeting/auth/request/reply plus every named refusal — forged
// MAC, replayed auth line, replayed request id, unknown verb, bad NAME —
// driven VM-free against the pure VSCtl module.
import CryptoKit
import Foundation
import XCTest
@testable import VSCtl

final class VSCtlTests: XCTestCase {
    /// ADR 0056 D2's pinned vector: key = ASCII "a5" x 32, challenge =
    /// 00 01 .. 1f — the same bytes the Zig and Go tests pin.
    private let pinKey = Data(String(repeating: "a5", count: 32).utf8)
    private let pinChallenge = [UInt8](0..<32)
    private let pinMAC = "87b459ff70564dd354e1415d16618cc768bf5f2181124a2b495c73b01e274b6c"

    private func authLine(mac: String) -> String { "{\"auth\":\"\(mac)\"}" }

    private func macFor(key: Data, challenge: [UInt8]) -> String {
        var msg = Data(VSCtl.authDomain.utf8)
        msg.append(0)
        msg.append(contentsOf: challenge)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func code(of data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8),
              let at = s.range(of: "\"code\":\"") else { return nil }
        let rest = s[at.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    func testGreetingCarriesPinnedChallenge() {
        let s = CTLSession(key: pinKey, challenge: pinChallenge)
        let g = String(decoding: s.greetingLine(), as: UTF8.self)
        XCTAssertEqual(g, "{\"proto\":\"virelai-ctl/1\",\"auth\":\"hmac-sha256\",\"challenge\":\"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\"}\n")
    }

    func testPinnedVectorAuthenticates() {
        var s = CTLSession(key: pinKey, challenge: pinChallenge)
        let (reply, fatal) = s.feed(line: authLine(mac: pinMAC))
        XCTAssertFalse(fatal)
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("\"ok\":true"))
        XCTAssertTrue(s.authedForMarker)
    }

    func testForgedMACIsAuthFailed() {
        var s = CTLSession(key: pinKey, challenge: pinChallenge)
        // Every-zero MAC is well-formed hex, wrong answer.
        let (reply, fatal) = s.feed(line: authLine(mac: String(repeating: "00", count: 32)))
        XCTAssertTrue(fatal)
        XCTAssertEqual(code(of: reply), "auth_failed")
        XCTAssertFalse(s.authedForMarker)
    }

    func testReplayedAuthDiesWithItsChallenge() {
        // Session A: capture the auth line that answered challenge A.
        var a = CTLSession(key: pinKey, challenge: pinChallenge)
        _ = a.feed(line: authLine(mac: pinMAC))
        // Session B (a fresh connection, a fresh challenge): replay the
        // captured line verbatim — it is a MAC against the wrong
        // challenge, so the refusal is auth_failed.
        var b = CTLSession(key: pinKey, challenge: [UInt8](32..<64))
        let (reply, fatal) = b.feed(line: authLine(mac: pinMAC))
        XCTAssertTrue(fatal)
        XCTAssertEqual(code(of: reply), "auth_failed")
    }

    func testRequestBeforeAuthIsAuthRequired() {
        var s = CTLSession(key: pinKey, challenge: pinChallenge)
        let (reply, fatal) = s.feed(line: "{\"id\":1,\"verb\":\"suspend\"}")
        XCTAssertTrue(fatal)
        XCTAssertEqual(code(of: reply), "auth_required")
    }

    func testMalformedFirstLineIsRefused() {
        var s = CTLSession(key: pinKey, challenge: pinChallenge)
        var r = s.feed(line: "not json")
        XCTAssertTrue(r.fatal)
        XCTAssertEqual(code(of: r.reply), "bad_json")
        s = CTLSession(key: pinKey, challenge: pinChallenge)
        r = s.feed(line: "{\"auth\":\"zz\"}")
        XCTAssertTrue(r.fatal)
        XCTAssertEqual(code(of: r.reply), "auth_failed")
    }

    private func authedSession() -> CTLSession {
        var s = CTLSession(key: pinKey, challenge: pinChallenge)
        _ = s.feed(line: authLine(mac: pinMAC))
        return s
    }

    func testVerbsRoundTripAsUnimplemented() {
        var s = authedSession()
        var r = s.feed(line: "{\"id\":1,\"verb\":\"suspend\"}")
        XCTAssertFalse(r.fatal)
        XCTAssertEqual(code(of: r.reply), "unimplemented")
        XCTAssertTrue(String(decoding: r.reply, as: UTF8.self).contains("\"id\":1"))
        r = s.feed(line: "{\"id\":2,\"verb\":\"snapshot\",\"name\":\"BEFORE-1\"}")
        XCTAssertEqual(code(of: r.reply), "unimplemented")
    }

    func testUnknownVerb() {
        var s = authedSession()
        let r = s.feed(line: "{\"id\":1,\"verb\":\"frobnicate\"}")
        XCTAssertFalse(r.fatal)
        XCTAssertEqual(code(of: r.reply), "unknown_verb")
    }

    func testReplayedRequestID() {
        var s = authedSession()
        _ = s.feed(line: "{\"id\":1,\"verb\":\"suspend\"}")
        let r = s.feed(line: "{\"id\":1,\"verb\":\"suspend\"}")
        XCTAssertEqual(code(of: r.reply), "replay")
        // A skipped id is the same refusal.
        let r2 = s.feed(line: "{\"id\":5,\"verb\":\"suspend\"}")
        XCTAssertEqual(code(of: r2.reply), "replay")
        // And the counter resumes where it should.
        let r3 = s.feed(line: "{\"id\":2,\"verb\":\"suspend\"}")
        XCTAssertEqual(code(of: r3.reply), "unimplemented")
    }

    func testNameGrammar() {
        var s = authedSession()
        for (i, name) in [".hidden", "..", "a/b", "x y", String(repeating: "n", count: 32)].enumerated() {
            let r = s.feed(line: "{\"id\":\(i + 1),\"verb\":\"snapshot\",\"name\":\"\(name)\"}")
            XCTAssertEqual(code(of: r.reply), "name_rejected", "name \(name)")
        }
        var s2 = authedSession()
        let r = s2.feed(line: "{\"id\":1,\"verb\":\"suspend\",\"name\":\"X\"}")
        XCTAssertEqual(code(of: r.reply), "bad_request")
        s2 = authedSession()
        let r2 = s2.feed(line: "{\"id\":1,\"verb\":\"snapshot\"}")
        XCTAssertEqual(code(of: r2.reply), "bad_request")
        s2 = authedSession()
        let r3 = s2.feed(line: "{\"id\":1,\"verb\":\"suspend\",\"extra\":1}")
        XCTAssertEqual(code(of: r3.reply), "bad_request")
    }

    // M115d (#2463): the armed suspend — an injected driver answers the
    // verb; `ok:true` names state=saved and sets acceptedSuspend for the
    // transport's post-reply tail.
    func testArmedSuspendAccepts() {
        var s = authedSession()
        var calls = 0
        s.suspendHandler = {
            calls += 1
            return .accept
        }
        let r = s.feed(line: "{\"id\":1,\"verb\":\"suspend\"}")
        XCTAssertFalse(r.fatal)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(s.acceptedSuspend)
        let line = String(decoding: r.reply, as: UTF8.self)
        XCTAssertTrue(line.contains("\"id\":1"))
        XCTAssertTrue(line.contains("\"ok\":true"))
        XCTAssertTrue(line.contains("\"verb\":\"suspend\""))
        XCTAssertTrue(line.contains("\"state\":\"saved\""))
    }

    func testArmedSuspendRefusalCodes() {
        for want in ["no_state", "unsupported", "save_failed", "busy"] {
            var s = authedSession()
            s.suspendHandler = { .refuse(want) }
            let r = s.feed(line: "{\"id\":1,\"verb\":\"suspend\"}")
            XCTAssertEqual(code(of: r.reply), want, want)
            XCTAssertFalse(s.acceptedSuspend)
            XCTAssertTrue(String(decoding: r.reply, as: UTF8.self)
                .contains(VSCtl.messages[want]!), want)
        }
    }

    func testArmedSuspendConsumesTheIdOnRefusal() {
        var s = authedSession()
        s.suspendHandler = { .refuse("no_state") }
        _ = s.feed(line: "{\"id\":1,\"verb\":\"suspend\"}")
        let r = s.feed(line: "{\"id\":1,\"verb\":\"suspend\"}")
        XCTAssertEqual(code(of: r.reply), "replay")
        let r2 = s.feed(line: "{\"id\":2,\"verb\":\"suspend\"}")
        XCTAssertEqual(code(of: r2.reply), "no_state")
    }

    func testBadRequestShapes() {
        let cases: [(String, String)] = [
            ("{\"id\":1}", "bad_request"),                       // verb absent
            ("{\"verb\":\"suspend\"}", "bad_request"),          // id absent
            ("{\"id\":1,\"verb\":3}", "bad_request"),           // verb not a string
            ("{\"id\":0,\"verb\":\"suspend\"}", "bad_request"), // id out of range
            ("{\"id\":1,\"verb\":\"suspend\"} trailing", "bad_request"), // object-shaped, grammar-broken
            ("[1,2]", "bad_json"),
            ("{\"id\":1,\"verb\":\"suspend\",\"id\":2}", "bad_request"), // duplicate key -> not an object
        ]
        for (line, want) in cases {
            var s = authedSession()
            let r = s.feed(line: line)
            XCTAssertEqual(code(of: r.reply), want, line)
        }
    }

    func testLoadKeyRow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = "#v1\nvsock-ctl\t0\t" + String(repeating: "a5", count: 32) + "\n"
        try secrets.write(to: dir.appendingPathComponent("SECRETS.TXT"), atomically: true, encoding: .utf8)
        XCTAssertEqual(VSCtl.loadKey(shareDir: dir), pinKey)
        // A row bound to uid_user does NOT answer a uid_system lookup.
        try "#v1\nvsock-ctl\t1000\tbeef\tVSCTL.ELF\n".write(
            to: dir.appendingPathComponent("SECRETS.TXT"), atomically: true, encoding: .utf8)
        XCTAssertNil(VSCtl.loadKey(shareDir: dir))
        // A non-#v1 file refuses whole.
        try ("vsock-ctl\t0\t" + String(repeating: "a5", count: 32)).write(
            to: dir.appendingPathComponent("SECRETS.TXT"), atomically: true, encoding: .utf8)
        XCTAssertNil(VSCtl.loadKey(shareDir: dir))
    }
}
