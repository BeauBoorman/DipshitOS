import Foundation
import VSCtl
import Virtualization

// MARK: - VSockCtl — the M115b (#2461, ADR 0056) control-channel endpoint
//
// Glue between VSCtl (the pure wire/session module) and the
// VZVirtioSocketDevice listener armed under `--vsock-ctl`. Each accepted
// connection is one CTLSession on a dedicated serial queue: greeting,
// challenge auth, one reply per request line, close on fatal codes. The
// connection's fd is a real socket — SO_RCVTIMEO gives the auth (10 s)
// and idle (60 s) budgets; a timed-out read is the named refusal, never
// a hang.
//
// Markers print codes/ids/ports only — keys, challenges, MACs and request
// payloads are never logged.

/// One accepted connection's session driver.
final class VSockCtlSession {
    private let connection: VZVirtioSocketConnection
    private var session: CTLSession
    private let queue = DispatchQueue(label: "vsock-ctl-session")
    private let onDone: (VSockCtlSession) -> Void

    init(connection: VZVirtioSocketConnection, key: Data, onDone: @escaping (VSockCtlSession) -> Void) {
        self.connection = connection
        var rng = SystemRandomNumberGenerator()
        let challenge = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        self.session = CTLSession(key: key, challenge: challenge)
        self.onDone = onDone
    }

    /// Run the session on its own queue: greeting, then the line loop.
    func start() {
        queue.async { [self] in self.run() }
    }

    private func setRecvTimeout(_ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        let fd = connection.fileDescriptor
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // The guest ends sessions with OP_SHUTDOWN both-ways — a write
        // into that stream must be an EPIPE, not a process-killing
        // SIGPIPE. Both spellings are armed: SO_NOSIGPIPE when the fd is
        // a socket, F_SETNOSIGPIPE when it is not (the console-tcp and
        // script-feeder paths use the same belt-and-suspenders).
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }

    /// Write all of `data`; a short write loops, a failure ends the
    /// session silently (the peer is already gone).
    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(connection.fileDescriptor, raw.baseAddress! + sent, data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private enum ReadResult {
        case line([UInt8])
        case overLimit   // a line that cannot fit its LF inside the cap
        case closed      // peer ended the stream (or an io error)
        case timedOut    // the SO_RCVTIMEO budget expired
    }

    /// Read one LF-terminated line (stripped).
    private func readLine(limit: Int, pending: inout [UInt8]) -> ReadResult {
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            if let nl = pending.firstIndex(of: 0x0a) {
                var line = Array(pending[..<nl])
                pending.removeFirst(nl + 1)
                if line.last == 0x0d { line.removeLast() }
                return .line(line)
            }
            if pending.count >= limit {
                // Discard the runaway prefix; the refusal names the bound.
                pending.removeAll(keepingCapacity: true)
                return .overLimit
            }
            let n = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(connection.fileDescriptor, raw.baseAddress!, min(raw.count, limit))
            }
            if n == 0 { return .closed }
            if n < 0 {
                return (errno == EAGAIN || errno == EWOULDBLOCK) ? .timedOut : .closed
            }
            pending.append(contentsOf: chunk[..<n])
        }
    }

    private func run() {
        print("VSOCK-CTL: session opened dport=\(connection.destinationPort) sport=\(connection.sourcePort)")
        defer {
            connection.close()
            onDone(self)
        }
        setRecvTimeout(Int(VSCtl.authTimeoutSeconds))
        guard writeAll(session.greetingLine()) else { return }
        var pending = [UInt8]()
        var limit = VSCtl.preAuthLimit
        while true {
            let line: [UInt8]
            switch readLine(limit: limit, pending: &pending) {
            case .line(let l):
                line = l
            case .overLimit:
                _ = writeAll(Data("{\"ok\":false,\"error\":{\"code\":\"line_too_long\",\"message\":\"line exceeds its byte limit\"}}\n".utf8))
                print("VSOCK-CTL: refuse code=line_too_long")
                return
            case .timedOut:
                // A recv budget expired — pre-auth is auth_timeout,
                // post-auth idle_timeout; the peer may still be there.
                let code = session.authedForMarker ? "idle_timeout" : "auth_timeout"
                _ = writeAll(Data("{\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"timeout\"}}\n".utf8))
                print("VSOCK-CTL: refuse code=\(code)")
                return
            case .closed:
                // The peer ended the stream — a clean close (the guest's
                // session-end SHUTDOWN) or an io failure; either way the
                // session just ends, nothing to refuse.
                print("VSOCK-CTL: session ended")
                return
            }
            let str = String(decoding: line, as: UTF8.self)
            let (reply, fatal) = session.feed(line: str)
            _ = writeAll(reply)
            if let code = Self.replyCode(reply) {
                print("VSOCK-CTL: reply code=\(code)\(fatal ? " (session closed)" : "")")
            }
            if fatal { return }
            // Post-auth lines relax to the session limit and the idle
            // budget.
            limit = VSCtl.lineLimit
            setRecvTimeout(Int(VSCtl.idleTimeoutSeconds))
        }
    }

    /// Pull `"code":"<word>"` out of a reply line for the marker print —
    /// nil on a success line.
    static func replyCode(_ reply: Data) -> String? {
        guard let s = String(data: reply, encoding: .utf8),
              let at = s.range(of: "\"code\":\"") else { return nil }
        let rest = s[at.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

/// The ctl-port listener delegate. Accepts up to VSCtl.maxSessions live
/// sessions; past the bound the accept is refused (the guest sees the
/// same RST an unlistened port gives).
final class VSockCtlListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private let key: Data
    private var sessions: [VSockCtlSession] = []

    init(key: Data) { self.key = key }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard sessions.count < VSCtl.maxSessions else { return false }
        let session = VSockCtlSession(connection: connection, key: key) { [weak self] done in
            self?.sessions.removeAll { $0 === done }
        }
        sessions.append(session)
        session.start()
        return true
    }
}
