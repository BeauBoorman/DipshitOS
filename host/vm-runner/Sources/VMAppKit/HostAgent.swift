import CryptoKit
import Foundation

/// M127e (#2603, index #2555, ADR 0051 v2 + 0052): the AGENTD companion
/// MODEL — the host-side mirror of the seat's M109e agentwatch. The
/// companion reads the M109c audit lane (the `--cvc-file`/`--virtio-fs`
/// share's `AGENT/AUDIT/RCPT-*` files) and verifies each receipt under
/// the share's own `agent-hmac` SECRETS.TXT row — the ADR's "the host
/// already reads as a file" double-reader: one provisioned row is the
/// credential on the guest, the seat, and here.
///
/// Three consumers ride the one model:
///
///   - The session window's toolbar pill (HostApplication) shows the
///     live agent state — sessions, rejected receipts, the pause mark.
///   - The inspector drawer's sub-pane (HostInspectorView) lists the
///     receipt rows. A receipt that fails the MAC or fails to parse is
///     FLAGGED as rejected, never dropped and never shown as valid —
///     tamper-evidence is the point of the lane.
///   - The `lane-agent` bus verb is the ADR's host-side choke: pause
///     suspends the runner's `--net-tcp-connect-stream` endpoint child
///     (SIGSTOP) and resume continues it (SIGCONT). The choke is the
///     pipe — the guest-side session survives the freeze, no tag ever
///     carries a host→agent imperative, and AGENTD stays guest-facing.
///
/// Like HostRecorder, the companion finds everything without runner
/// globals: the share resolves from argv, the endpoint is the runner's
/// own child process (identified by inode — the exec file itself, or
/// the script path inside a shebang child's argv), so a bare
/// `HostCommandBus()` in a `--host-cmd-after` run exercises the
/// identical seam the session window does.
///
/// All access is main-queue (the poll, the bus, and the views all are),
/// so the companion takes no lock — the HostCommandBus precedent.
public struct AgentReceipt {
    public let name: String      // RCPT-<epoch:8hex>-<seq:8hex>
    public let agent: String     // the claimed id, "-" while none
    public let verb: String      // "session" for session frames
    public let event: String     // session frames only: open/close/auth_fail
    public let result: String    // "ok" or the dispatch code:detail
    public let args: String      // compact "k=v" summary, never payload bytes
    public let verified: Bool
    /// The rejection cause — "bad_mac", "malformed", "unreadable".
    /// Empty when verified.
    public let reason: String

    /// The one-line row the inspector sub-pane renders. Rejected rows
    /// lead with the flag so a tampered fixture can never pass as a
    /// verified receipt at a glance.
    public var row: String {
        if !verified { return "\(name) ✗ \(reason)" }
        if verb == "session" { return "\(name) ✓ session \(event) \(agent)" }
        let detail = args.isEmpty ? "" : " \(args)"
        return "\(name) ✓ \(agent) \(verb) \(result)\(detail)"
    }
}

public final class HostAgentCompanion {
    /// The lane's file bound is 64 names (M109c D4); the display keeps
    /// twice that so a rotation window never erases a flagged row mid-
    /// triage.
    public static let rowsMax = 128
    /// agentRcptMax's host twin: one receipt is ≈600 bytes; the bound
    /// exists so a foreign file cannot stretch the read.
    public static let receiptMax = 2048
    /// Names never recur (epoch+seq are unique), so the consumed set
    /// cannot be re-fuzzed past twice the live bound.
    public static let seenMax = 256

    static let secretName = "agent-hmac"
    static let secretUID = "2000" // uid_agent — the daemon's principal (M173d)

    // MARK: Seams — every external input is injectable.

    /// argv override: nil reads CommandLine.arguments (production).
    /// Both the share and the agent channel resolve from it.
    public var arguments: [String]?
    /// Direct overrides beat argv resolution — the test seams.
    public var shareDir: URL?
    public var streamExecutable: String?
    /// The endpoint finder: the runner's direct children whose exec
    /// image or argv names the stream executable. Injectable so tests
    /// never enumerate real processes.
    public var endpointPIDs: (String) -> [pid_t]
    /// The signal send: kill(pid, sig) by default.
    public var signalEndpoint: (pid_t, Int32) -> Bool = { kill($0, $1) == 0 }
    /// The marker sink — the runner leaves the default (unbuffered
    /// stdout, the host-*: precedent); HostCommandBus wires it to the
    /// bus's own emit so `host-agent:` and `host-ui:` lines share one
    /// stream a gate greps.
    public var emit: (String) -> Void = {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }
    /// Model → view notification (main queue, the HostInspector rule).
    public var onChange: (() -> Void)?

    public private(set) var receipts: [AgentReceipt] = []
    public private(set) var verifiedCount = 0
    public private(set) var rejectedCount = 0
    /// Verified session opens minus verified closes (floor 0) — the
    /// pill's "an agent is live" truth.
    public private(set) var liveSessions = 0
    public private(set) var authFailures = 0
    /// The lane-agent choke's mark — what the pill and the checkmark
    /// show.
    public private(set) var paused = false
    /// The lane is being read at all (dir + key both resolved once).
    public private(set) var watching = false

    private var key: Data?
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var timer: Timer?

    public init() {
        self.endpointPIDs = HostAgentCompanion.runnerChildren
    }

    // MARK: Arming — argv resolution and posture.

    public static func shareDir(arguments: [String]) -> URL? {
        for flag in ["--cvc-file", "--virtio-fs"] {
            if let i = arguments.firstIndex(of: flag), i + 1 < arguments.count {
                return URL(fileURLWithPath: arguments[i + 1])
            }
        }
        return nil
    }

    public static func streamExecutable(arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "--net-tcp-connect-stream"),
              i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    public func resolvedShareDir() -> URL? {
        shareDir ?? HostAgentCompanion.shareDir(arguments: arguments ?? CommandLine.arguments)
    }

    public func resolvedStreamExecutable() -> String? {
        streamExecutable ?? HostAgentCompanion.streamExecutable(arguments: arguments ?? CommandLine.arguments)
    }

    /// A `--net-tcp-connect-stream` endpoint exists to choke. When it is
    /// absent the `lane-agent` verb answers `unavailable` — the ADR's
    /// vocabulary for "no agent channel is armed".
    public var channelArmed: Bool { resolvedStreamExecutable() != nil }

    /// The audit lane exists on the resolved share — dir present, key
    /// row or not (a missing key makes every row flag rejected, which
    /// is itself evidence the human should see).
    public var auditLanePresent: Bool {
        guard let share = resolvedShareDir() else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: Self.auditDir(share).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Whether the companion surfaces at all — the pill renders when a
    /// channel or the lane exists, and stays hidden on an agent-free
    /// run (the flags-off posture, host side).
    public var companionArmed: Bool { channelArmed || auditLanePresent || watching }

    static func auditDir(_ share: URL) -> URL {
        share.appendingPathComponent("AGENT", isDirectory: true)
            .appendingPathComponent("AUDIT", isDirectory: true)
    }

    // MARK: The credential — the same `agent-hmac` row agentd reads.

    /// `key<TAB>uid<TAB>value[\tapps]` under a `#v1` first line — the
    /// HostInt.loadKey grammar with this lane's row name. The value
    /// bytes are the HMAC key verbatim.
    public static func loadKey(shareDir: URL) -> Data? {
        let url = shareDir.appendingPathComponent("SECRETS.TXT")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines) == "#v1" else {
            return nil
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

    // MARK: The audit scan — the poll's body, also the test entry.

    /// List the lane, verify each fresh receipt, apply the session
    /// trail. Returns the fresh-name count. Idempotent: consumed names
    /// are never re-read (the writer never reuses one).
    @discardableResult
    public func scan() -> Int {
        guard let share = resolvedShareDir() else { return 0 }
        let dir = Self.auditDir(share)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return 0
        }
        // The row is re-read until found — a share whose SECRETS.TXT is
        // provisioned late still arms the verifier.
        if key == nil { key = Self.loadKey(shareDir: share) }
        var armedNow = false
        if !watching {
            watching = true
            armedNow = true
            emit("host-agent: watch")
        }
        let fresh = names.filter { Self.isReceiptName($0) && !seen.contains($0) }.sorted()
        for name in fresh {
            remember(name)
            apply(dir: dir, name: name)
        }
        if armedNow || !fresh.isEmpty { changed() }
        return fresh.count
    }

    /// Read, verify and apply one receipt. Rejected files still land a
    /// row — flagged with the cause, which is the tamper evidence the
    /// sub-pane exists to show.
    private func apply(dir: URL, name: String) {
        let url = dir.appendingPathComponent(name)
        guard let raw = try? Data(contentsOf: url), raw.count <= Self.receiptMax else {
            reject(name, reason: "unreadable")
            return
        }
        guard let nl = raw.firstIndex(of: UInt8(ascii: "\n")),
              raw.count >= nl + 1 + 64 else {
            reject(name, reason: "malformed")
            return
        }
        let line = raw[raw.startIndex..<nl]
        let macHex = raw[(nl + 1)..<(nl + 1 + 64)]
        guard let key else {
            reject(name, reason: "no_key")
            return
        }
        guard Self.verify(line: Data(line), macHex: Data(macHex), key: key) else {
            reject(name, reason: "bad_mac")
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)),
              let fields = obj as? [String: Any],
              let verb = fields["verb"] as? String, !verb.isEmpty else {
            reject(name, reason: "malformed")
            return
        }
        let agent = fields["agent"] as? String ?? "-"
        let result = fields["result"] as? String ?? "-"
        var event = ""
        var argsSummary = ""
        if let args = fields["args"] as? [String: Any] {
            event = args["event"] as? String ?? ""
            argsSummary = Self.argsSummary(args, excluding: "event")
        }
        verifiedCount += 1
        receipts.append(AgentReceipt(name: name, agent: agent, verb: verb,
                                     event: event, result: result,
                                     args: argsSummary, verified: true, reason: ""))
        trimRows()
        if verb == "session" {
            switch event {
            case "open":
                liveSessions += 1
                emit("host-agent: session open agent=\(Self.mark(agent))")
            case "close":
                liveSessions = max(0, liveSessions - 1)
                emit("host-agent: session close agent=\(Self.mark(agent))")
            case "auth_fail":
                authFailures += 1
                emit("host-agent: session auth_fail agent=\(Self.mark(agent))")
            default:
                break
            }
        }
    }

    private func reject(_ name: String, reason: String) {
        rejectedCount += 1
        receipts.append(AgentReceipt(name: name, agent: "", verb: "", event: "",
                                     result: "", args: "", verified: false,
                                     reason: reason))
        trimRows()
        emit("host-agent: rcpt bad \(name) reason=\(reason)")
    }

    private func trimRows() {
        if receipts.count > Self.rowsMax {
            receipts.removeFirst(receipts.count - Self.rowsMax)
        }
    }

    private func remember(_ name: String) {
        seen.insert(name)
        seenOrder.append(name)
        if seenOrder.count > Self.seenMax {
            for stale in seenOrder.prefix(Self.seenMax / 2) { seen.remove(stale) }
            seenOrder.removeFirst(Self.seenMax / 2)
        }
    }

    // MARK: Verification — the forgery check, guest-parity.

    /// The receipt's MAC must match HMAC-SHA256(key, line-1 bytes).
    /// Constant-time over the tag — the HostInt.verify / agentMacEq
    /// discipline, so neither end leaks a timing channel on a forged
    /// row. Hex accepts either case.
    static func verify(line: Data, macHex: Data, key: Data) -> Bool {
        guard macHex.count == 64 else { return false }
        let mac = HMAC<SHA256>.authenticationCode(for: line, using: SymmetricKey(data: key))
        var diff: UInt8 = 0
        for (i, byte) in mac.enumerated() {
            guard let hi = nibble(macHex[i * 2]), let lo = nibble(macHex[i * 2 + 1]) else {
                return false
            }
            diff |= byte ^ (hi << 4 | lo)
        }
        return diff == 0
    }

    static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// `RCPT-<8hex>-<8hex>` — the lane's committed file shape (the "~"
    /// publish temp and foreign files never qualify).
    public static func isReceiptName(_ name: String) -> Bool {
        let b = Array(name.utf8)
        guard b.count == 22, b[0...4].elementsEqual(Array("RCPT-".utf8)), b[13] == UInt8(ascii: "-") else {
            return false
        }
        for i in 5..<22 where i != 13 {
            let c = b[i]
            let hex = (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
                || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f"))
                || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "F"))
            if !hex { return false }
        }
        return true
    }

    /// The args object's one-line summary: `k=v` pairs, key-sorted for
    /// determinism, each value bounded. Session args render through the
    /// event field instead.
    static func argsSummary(_ args: [String: Any], excluding skip: String) -> String {
        var parts: [String] = []
        for key in args.keys.sorted() where key != skip {
            var v = "\(args[key] ?? "")"
            if v.count > 32 { v = String(v.prefix(32)) }
            parts.append("\(key)=\(v)")
        }
        return parts.joined(separator: " ")
    }

    /// Marker-safe field rendering — the guest's agentMark rule: a
    /// receipt's text fields are bounded and control bytes folded so a
    /// newline can never split a line a gate greps.
    static func mark(_ s: String) -> String {
        var s = s
        if s.count > 24 { s = String(s.prefix(24)) }
        return String(s.map { ($0 < " " || $0 == "\u{7f}") ? "?" : $0 })
    }

    // MARK: The poll — the live feed for pill and sub-pane.

    /// Arm the periodic scan on the current (main) run loop. No share
    /// resolved → no timer and no output: the flags-off posture stays
    /// silent rather than polling a void.
    public func startPolling(interval: TimeInterval = 1.0) {
        guard timer == nil, resolvedShareDir() != nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: lane-agent — the host-side choke.

    /// The verb's action: pause suspends the endpoint child (SIGSTOP),
    /// resume continues it (SIGCONT). `unavailable` when no agent
    /// channel is armed, `disabled` when armed but the endpoint is not
    /// running — both are the receipt vocabulary, not silence.
    @discardableResult
    public func togglePause() -> HostCommandBus.Outcome {
        guard let exec = resolvedStreamExecutable() else { return .unavailable }
        let pids = endpointPIDs(exec)
        guard !pids.isEmpty else { return .disabled }
        let sig: Int32 = paused ? SIGCONT : SIGSTOP
        var ok = true
        for pid in pids { ok = signalEndpoint(pid, sig) && ok }
        if ok {
            paused.toggle()
            emit("host-agent: lane \(paused ? "paused" : "resumed") pid=\(pids[0])")
            changed()
        }
        return ok ? .performed : .failed
    }

    /// The menu checkmark reads "the lane is flowing" — armed and not
    /// paused — so the Integration toggles share one convention.
    public var laneFlowing: Bool { channelArmed && !paused }

    // MARK: Surfaces — the pill and the sub-pane projections.

    /// The toolbar pill's title. `●` a session is live, `‖` the lane is
    /// frozen, `○` armed-and-idle; `!N` flags rejected receipts so
    /// tamper evidence is visible without opening the drawer.
    public var pillText: String {
        var t = "AGENT "
        if paused { t += "‖" } else { t += liveSessions > 0 ? "●" : "○" }
        if rejectedCount > 0 { t += " !\(rejectedCount)" }
        return t
    }

    /// The drawer's one-line Agent summary — the HostInt counters'
    /// twin for this lane.
    public var agentSummary: String {
        "Agent sessions=\(liveSessions) rcpts=\(verifiedCount) bad=\(rejectedCount) paused=\(paused ? 1 : 0)"
    }

    /// The `lane-agent` receipt tail — the post-action truth a gate
    /// reads (the `capture=on|off` precedent).
    public var receiptDetail: String {
        "paused=\(paused ? 1 : 0) sessions=\(liveSessions) rcpts=\(verifiedCount) bad=\(rejectedCount)"
    }

    /// The sub-pane's rows — every committed receipt, flagged or not.
    public var receiptRows: [String] { receipts.map(\.row) }

    private func changed() { onChange?() }

    // MARK: Endpoint discovery — the runner's children, by inode.

    /// The runner's direct children whose process image OR argv names
    /// `execPath`. Inode equality throughout: a directly-exec'd child
    /// matches on its image (proc_pidpath); a shebang child's image is
    /// the interpreter, so its argv is scanned for the script path
    /// instead (the kernel places it at argv[1]).
    ///
    /// The runner's only operator-provided child is the stream exec —
    /// Virtualization.framework's helpers never carry its path — so
    /// matching by inode can never freeze a VM-helper process.
    static func runnerChildren(matchingExecutable execPath: String) -> [pid_t] {
        var want = stat()
        guard stat(execPath, &want) == 0 else { return [] }
        func isExec(_ path: String) -> Bool {
            var st = stat()
            return stat(path, &st) == 0 && st.st_dev == want.st_dev && st.st_ino == want.st_ino
        }
        var out: [pid_t] = []
        for pid in childPIDs() {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
               isExec(String(cString: buf)) {
                out.append(pid)
                continue
            }
            if processArgs(pid).contains(where: isExec) { out.append(pid) }
        }
        return out
    }

    /// Direct children of this process (KERN_PROC_ALL filtered by
    /// ppid) — the candidates the exec match narrows.
    static func childPIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let me = getpid()
        let n = size / MemoryLayout<kinfo_proc>.stride
        return (0..<n).filter { procs[$0].kp_eproc.e_ppid == me }.map { procs[$0].kp_proc.p_pid }
    }

    /// One process's argv (KERN_PROCARGS2): int32 argc, the exec path,
    /// NUL padding, then argc NUL-terminated strings.
    static func processArgs(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // Skip the exec path, then the NUL padding to argv[0].
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        for _ in 0..<argc {
            guard i < size else { break }
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if i > start, let s = String(bytes: buf[start..<i], encoding: .utf8) {
                args.append(s)
            }
            i += 1
        }
        return args
    }
}
