import CryptoKit
import Foundation

// VSCtl — the host half of the virelai-ctl/1 control channel (M115b,
// issue #2461, ADR 0056). The guest connects over virtio-vsock to the
// runner's --vsock-ctl-port listener; the server sends a greeting with a
// fresh 32-byte challenge, the guest answers HMAC-SHA256(key, domain ||
// 0x00 || challenge), and newline-delimited request objects get one reply
// line each. This module is pure Swift/Foundation — zero Virtualization
// imports — so `swift test` drives the whole refusal matrix without a VM.
// VSockCtl.swift in the VMRunner target glues it to the
// VZVirtioSocketConnection fd.
//
// Never-logged contract (ADR 0044 D6, verbatim): keys, challenges, MACs
// and request payloads never reach stdout — markers carry codes and ids.

public enum VSCtl {
    public static let proto = "virelai-ctl/1"
    /// The auth domain — distinct from VIRELAIOS-AUTH/1 and
    /// VIRELAI-AGENT/1 so a captured MAC cannot cross services.
    public static let authDomain = "VIRELAI-CTL/1 hmac-sha256"
    /// The SECRETS.TXT row both ends read: `vsock-ctl<TAB>0<TAB><value>` —
    /// uid_system, app-unbound (the kernel's own ctl client is the only
    /// in-guest consumer; no EL0 principal holds uid 0).
    public static let secretName = "vsock-ctl"
    public static let secretUID = "0"
    /// The default --vsock-ctl-port; distinct from the M115a probe
    /// listener on 1208.
    public static let defaultPort: UInt32 = 1209
    /// Line bounds count the LF (ADR 0056 D1).
    public static let preAuthLimit = 256
    public static let lineLimit = 1024
    /// Concurrent sessions are bounded; past this the listener refuses.
    public static let maxSessions = 4
    /// 10 s to complete auth; 60 s between requests.
    public static let authTimeoutSeconds: TimeInterval = 10
    public static let idleTimeoutSeconds: TimeInterval = 60

    /// The refusal vocabulary (ADR 0056 D4): one fixed English sentence
    /// per code; request bytes are never echoed.
    public static let messages: [String: String] = [
        "bad_json": "line is not one JSON object",
        "bad_request": "request fields are missing, mistyped, or out of range",
        "unknown_verb": "no such verb",
        "name_rejected": "snapshot name fails the NAME grammar",
        "replay": "id must be exactly the previous id plus one",
        "unimplemented": "verb is wired; the action lands with M115d/e",
        "auth_required": "requests precede authentication",
        "auth_failed": "the MAC does not answer this challenge",
        "auth_timeout": "no auth answer inside the budget",
        "line_too_long": "line exceeds its byte limit",
        "idle_timeout": "no request inside the idle budget",
        "io_error": "transport failure",
        // M115d (#2463): the suspend verb's refusal names — a request
        // with no armed destination, a device set VZ cannot save, a
        // failed save, and a suspend already in flight. M115e (#2464)
        // reuses them for snapshot/restore and adds two of its own.
        "no_state": "no save destination is armed",
        "unsupported": "this device set cannot be saved",
        "save_failed": "the machine-state save refused",
        "busy": "a suspend is already in flight",
        // M115e (#2464): named-snapshot refusals — a snapshot that is
        // already stored is never silently overwritten (the consent path
        // is `rm` first), and a restore of a name the share does not
        // hold refuses by name.
        "exists": "a snapshot by that name already exists",
        "not_found": "no snapshot by that name",
    ]

    /// Load the `vsock-ctl` row's value from the share's SECRETS.TXT —
    /// the M108 double-reader pattern (the guest side reads the same row
    /// through the kernel's secret store). nil = `no_credential`.
    public static func loadKey(shareDir: URL) -> Data? {
        let url = shareDir.appendingPathComponent("SECRETS.TXT")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines) == "#v1" else {
            return nil // a differently-schemed file is refused whole
        }
        lines.removeFirst()
        for line in lines {
            let line = line.replacingOccurrences(of: "\r", with: "")
            if line.isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, fields[0] == secretName, fields[1] == secretUID else { continue }
            let key = Data(fields[2].utf8)
            guard !key.isEmpty else { continue }
            return key
        }
        return nil
    }
}

// MARK: - The flat-object reader
//
// The ctl grammar (ADR 0056 D1): one JSON object per line; values are
// strings (escapes resolved), unsigned integers, or true/false. null,
// arrays, nested objects, duplicate keys and trailing bytes are refused —
// the strictness IS the gate's bad_request surface.

public enum FlatValue: Equatable {
    case str(String)
    case uint(UInt64)
    case bool(Bool)
}

public enum FlatParse {
    public enum Result {
        case ok([String: FlatValue])
        /// The line does not start with `{` — the bad_json code.
        case notObject
        /// Object-shaped but outside the grammar (dupes, nulls, nesting,
        /// trailing bytes, bad escapes) — the bad_request code.
        case malformed
    }

    /// Classify one line against the flat-object grammar.
    public static func object(_ s: String) -> Result {
        var p = Cursor(s)
        p.ws()
        guard p.take(UInt8(ascii: "{")) else { return .notObject }
        var out: [String: FlatValue] = [:]
        p.ws()
        if p.take(UInt8(ascii: "}")) { return p.atEnd ? .ok(out) : .malformed }
        while true {
            p.ws()
            guard let key = p.string() else { return .malformed }
            if out[key] != nil { return .malformed } // duplicate key
            p.ws()
            guard p.take(UInt8(ascii: ":")) else { return .malformed }
            p.ws()
            guard let v = p.value() else { return .malformed }
            out[key] = v
            p.ws()
            if p.take(UInt8(ascii: "}")) { return p.atEnd ? .ok(out) : .malformed }
            guard p.take(UInt8(ascii: ",")) else { return .malformed }
        }
    }

    private struct Cursor {
        let chars: [UInt8]
        var i = 0
        init(_ s: String) { chars = Array(s.utf8) }
        var atEnd: Bool { i >= chars.count }
        mutating func ws() { while i < chars.count && (chars[i] == 0x20 || chars[i] == 0x09) { i += 1 } }
        mutating func take(_ b: UInt8) -> Bool {
            if i < chars.count && chars[i] == b { i += 1; return true }
            return false
        }
        mutating func string() -> String? {
            guard take(UInt8(ascii: "\"")) else { return nil }
            var out = [UInt8]()
            while i < chars.count {
                let c = chars[i]
                i += 1
                if c == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    guard i < chars.count else { return nil }
                    let e = chars[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                    case UInt8(ascii: "n"): out.append(0x0a)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0d)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0c)
                    case UInt8(ascii: "u"):
                        guard i + 4 <= chars.count else { return nil }
                        var v: UInt32 = 0
                        for j in 0..<4 {
                            let d = chars[i + j]
                            let nib: UInt32
                            switch d {
                            case UInt8(ascii: "0")...UInt8(ascii: "9"): nib = UInt32(d - UInt8(ascii: "0"))
                            case UInt8(ascii: "a")...UInt8(ascii: "f"): nib = UInt32(d - UInt8(ascii: "a") + 10)
                            case UInt8(ascii: "A")...UInt8(ascii: "F"): nib = UInt32(d - UInt8(ascii: "A") + 10)
                            default: return nil
                            }
                            v = v << 4 | nib
                        }
                        i += 4
                        out.append(v < 0x80 ? UInt8(v) : UInt8(ascii: "?"))
                    default: return nil
                    }
                    continue
                }
                if c < 0x20 { return nil }
                out.append(c)
            }
            return nil
        }
        mutating func value() -> FlatValue? {
            guard i < chars.count else { return nil }
            switch chars[i] {
            case UInt8(ascii: "\""):
                return string().map { .str($0) }
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                var v: UInt64 = 0
                while i < chars.count, chars[i] >= UInt8(ascii: "0"), chars[i] <= UInt8(ascii: "9") {
                    let d = UInt64(chars[i] - UInt8(ascii: "0"))
                    let (nv, ov) = v.multipliedReportingOverflow(by: 10)
                    let (nv2, ov2) = nv.addingReportingOverflow(d)
                    if ov || ov2 { return nil }
                    v = nv2
                    i += 1
                }
                return .uint(v)
            case UInt8(ascii: "t"):
                guard i + 4 <= chars.count, String(decoding: chars[i..<i+4], as: UTF8.self) == "true" else { return nil }
                i += 4
                return .bool(true)
            case UInt8(ascii: "f"):
                guard i + 5 <= chars.count, String(decoding: chars[i..<i+5], as: UTF8.self) == "false" else { return nil }
                i += 5
                return .bool(false)
            default:
                return nil
            }
        }
    }
}

// MARK: - Session
//
// The server-side state machine behind one accepted connection. Lines
// arrive already LF-stripped; feed returns the reply line to write and
// whether the session dies after it (fatal codes close the connection).

/// M115d (#2463): the suspend driver's verdict — `accepted` means the
/// machine-state file exists on disk and the reply may say `ok:true`;
/// a refusal carries the ADR 0056 code the guest should read.
public struct SuspendVerdict {
    public var accepted: Bool
    public var code: String

    public static var accept: SuspendVerdict { SuspendVerdict(accepted: true, code: "") }
    public static func refuse(_ code: String) -> SuspendVerdict { SuspendVerdict(accepted: false, code: code) }
}

public struct CTLSession {
    public enum Verdict {
        case reply(Data)      // write this line, keep going
        case close(Data)      // write this line, then close
        case closeSilently    // transport-level end, nothing to write
    }

    private let key: Data
    private let challenge: [UInt8]
    private var authed = false
    private var lastID: UInt64 = 0

    /// Whether the handshake completed — the glue's timeout-refusal picks
    /// its code off this (auth_timeout vs idle_timeout).
    public var authedForMarker: Bool { authed }

    /// M115d (#2463): the suspend driver, injected by the glue. It runs
    /// AFTER the request is judged and BEFORE the reply is written, so an
    /// `ok:true` reply only ever follows a save that actually landed.
    /// Nil keeps the M115b stub answer (`unimplemented`).
    public var suspendHandler: (() -> SuspendVerdict)?

    /// M115e (#2464): the named-snapshot drivers, injected the same way.
    /// `snapshot` parks the RUNNING machine's state on the share as
    /// `SNAPSHOTS/<name>.vzsave` and then continues it; `restore` stages
    /// a named file as the next `--resume` target. Nil keeps the M115b
    /// stub answer (`unimplemented`).
    public var snapshotHandler: ((String) -> SuspendVerdict)?
    public var restoreHandler: ((String) -> SuspendVerdict)?

    /// Set when the last judged request was an ACCEPTED suspend — the
    /// transport's post-reply hook (write-then-stop) reads it. Reset on
    /// every feed.
    public private(set) var acceptedSuspend = false

    /// Set when the last judged request ran the snapshot driver, accept
    /// or refuse — the transport's post-reply hook (write-then-resume)
    /// reads it. The reply ordering is the suspend contract: the verdict
    /// is on the wire before the machine continues, so a `--resume` of
    /// this image finds its answer already delivered. Reset on every
    /// feed.
    public private(set) var answeredSnapshot = false

    /// The session's 32-byte challenge is injected — the glue supplies
    /// SecRandomCopyBytes; tests pin it.
    public init(key: Data, challenge: [UInt8]) {
        precondition(challenge.count == 32)
        self.key = key
        self.challenge = challenge
    }

    /// `{"proto":"virelai-ctl/1","auth":"hmac-sha256","challenge":"<hex>"}`
    public func greetingLine() -> Data {
        var hex = ""
        for b in challenge { hex += String(format: "%02x", b) }
        return Data("{\"proto\":\"\(VSCtl.proto)\",\"auth\":\"hmac-sha256\",\"challenge\":\"\(hex)\"}\n".utf8)
    }

    private func errorLine(_ code: String, id: UInt64?) -> Data {
        let msg = VSCtl.messages[code] ?? "refused"
        if let id {
            return Data("{\"id\":\(id),\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"\(msg)\"}}\n".utf8)
        }
        return Data("{\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"\(msg)\"}}\n".utf8)
    }

    private func hmac(_ challenge: [UInt8]) -> [UInt8] {
        var msg = Data(VSCtl.authDomain.utf8)
        msg.append(0)
        msg.append(contentsOf: challenge)
        return Array(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    private func hexBytes(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        var idx = s.startIndex
        while idx < s.endIndex {
            let b = s[idx...s.index(after: idx)]
            guard let v = UInt8(b, radix: 16) else { return nil }
            out.append(v)
            idx = s.index(idx, offsetBy: 2)
        }
        return out
    }

    /// Feed one LF-stripped line. The reply is written verbatim; on fatal
    /// the caller closes after the write.
    public mutating func feed(line: String) -> (reply: Data, fatal: Bool) {
        if !authed { return feedAuth(line: line) }
        return feedRequest(line: line)
    }

    private mutating func feedAuth(line: String) -> (Data, Bool) {
        let obj: [String: FlatValue]
        switch FlatParse.object(line) {
        case .ok(let o): obj = o
        case .notObject: return (errorLine("bad_json", id: nil), true)
        case .malformed: return (errorLine("bad_request", id: nil), true)
        }
        if obj["verb"] != nil || obj["id"] != nil {
            return (errorLine("auth_required", id: nil), true)
        }
        guard obj.count == 1, case .str(let hex) = obj["auth"] else {
            return (errorLine("bad_request", id: nil), true)
        }
        guard let mac = hexBytes(hex), mac.count == 32 else {
            return (errorLine("auth_failed", id: nil), true)
        }
        let expected = hmac(challenge)
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= mac[i] ^ expected[i] }
        if diff != 0 {
            return (errorLine("auth_failed", id: nil), true)
        }
        authed = true
        return (Data("{\"ok\":true,\"session\":\"ready\",\"verbs\":[\"suspend\",\"snapshot\",\"restore\"]}\n".utf8), false)
    }

    /// `name` passes the ADR 0044 NAME grammar: 1-31 bytes of
    /// [A-Za-z0-9._-], first alphanumeric, never "." or "..".
    private func validName(_ s: String) -> Bool {
        if s.isEmpty || s.utf8.count > 31 || s == "." || s == ".." { return false }
        for (n, c) in s.utf8.enumerated() {
            let ok = (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
                (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) ||
                (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) ||
                c == UInt8(ascii: ".") || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
            if !ok { return false }
            if n == 0 && c == UInt8(ascii: ".") { return false }
        }
        return true
    }

    private mutating func feedRequest(line: String) -> (Data, Bool) {
        acceptedSuspend = false
        answeredSnapshot = false
        let obj: [String: FlatValue]
        switch FlatParse.object(line) {
        case .ok(let o): obj = o
        case .notObject: return (errorLine("bad_json", id: nil), false)
        case .malformed: return (errorLine("bad_request", id: nil), false)
        }
        guard case .uint(let id) = obj["id"], id > 0, id <= UInt32.max else {
            return (errorLine("bad_request", id: nil), false)
        }
        if id != lastID + 1 {
            // The refusal names the rejected id — an honest answer about
            // which request did not sequence.
            return (errorLine("replay", id: id), false)
        }
        guard case .str(let verb) = obj["verb"] else {
            return (errorLine("bad_request", id: nil), false)
        }
        let known = Set(["id", "verb", "name"])
        if obj.keys.contains(where: { !known.contains($0) }) {
            return (errorLine("bad_request", id: nil), false)
        }
        switch verb {
        case "suspend":
            guard obj["name"] == nil else { return (errorLine("bad_request", id: nil), false) }
            lastID = id
            // M115d (#2463): the armed verb asks the injected driver —
            // an ok reply means the save exists; a refusal carries its
            // own name. A nil handler is the M115b stub posture.
            if let suspendHandler {
                let verdict = suspendHandler()
                guard verdict.accepted else {
                    return (errorLine(verdict.code, id: id), false)
                }
                acceptedSuspend = true
                return (Data("{\"id\":\(id),\"ok\":true,\"result\":{\"verb\":\"suspend\",\"state\":\"saved\"}}\n".utf8), false)
            }
            return (errorLine("unimplemented", id: id), false)
        case "snapshot":
            guard case .str(let name) = obj["name"] else {
                return (errorLine("bad_request", id: nil), false)
            }
            lastID = id
            guard validName(name) else {
                return (errorLine("name_rejected", id: id), false)
            }
            // M115e (#2464): the armed verb asks the injected driver —
            // pause, save `SNAPSHOTS/<name>.vzsave` on the share, reply
            // ok while the guest is still frozen, then resume (the glue's
            // post-reply hook). A nil handler is the M115b stub posture.
            if let snapshotHandler {
                let verdict = snapshotHandler(name)
                answeredSnapshot = true
                guard verdict.accepted else {
                    return (errorLine(verdict.code, id: id), false)
                }
                return (Data("{\"id\":\(id),\"ok\":true,\"result\":{\"verb\":\"snapshot\",\"name\":\"\(name)\",\"state\":\"saved\"}}\n".utf8), false)
            }
            return (errorLine("unimplemented", id: id), false)
        case "restore":
            // M115e (#2464): stage a named share snapshot as the next
            // `--resume` target — a host-side copy over the profile's
            // saved-state file, the one path the resume guard reads. The
            // running machine is untouched; the rewind happens next boot.
            guard case .str(let name) = obj["name"] else {
                return (errorLine("bad_request", id: nil), false)
            }
            lastID = id
            guard validName(name) else {
                return (errorLine("name_rejected", id: id), false)
            }
            if let restoreHandler {
                let verdict = restoreHandler(name)
                guard verdict.accepted else {
                    return (errorLine(verdict.code, id: id), false)
                }
                return (Data("{\"id\":\(id),\"ok\":true,\"result\":{\"verb\":\"restore\",\"name\":\"\(name)\",\"state\":\"staged\"}}\n".utf8), false)
            }
            return (errorLine("unimplemented", id: id), false)
        default:
            lastID = id
            return (errorLine("unknown_verb", id: id), false)
        }
    }
}
