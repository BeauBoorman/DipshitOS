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
    /// M115d (#2463): runs AFTER the reply is written when the request
    /// was an accepted suspend — the runner's stop+exit tail. The reply
    /// ordering is the wire contract: `ok:true` lands first so the saved
    /// guest's first post-restore read is its answer.
    private let onSuspendAccepted: (() -> Void)?

    init(connection: VZVirtioSocketConnection, key: Data,
         suspendHandler: (() -> SuspendVerdict)? = nil,
         onSuspendAccepted: (() -> Void)? = nil,
         onDone: @escaping (VSockCtlSession) -> Void) {
        self.connection = connection
        var rng = SystemRandomNumberGenerator()
        let challenge = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        var session = CTLSession(key: key, challenge: challenge)
        session.suspendHandler = suspendHandler
        self.session = session
        self.onSuspendAccepted = onSuspendAccepted
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
            // M115d (#2463): an accepted suspend replies ok FIRST (the
            // guest freezes mid-read and finds the answer on restore),
            // then the runner stops the VM and the run ends.
            if session.acceptedSuspend {
                print("VSOCK-CTL: reply ok=true verb=suspend")
                onSuspendAccepted?()
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
    /// M115d (#2463): the suspend driver + the post-reply tail, shared
    /// by every session the listener accepts.
    private let suspendHandler: (() -> SuspendVerdict)?
    private let onSuspendAccepted: (() -> Void)?

    init(key: Data,
         suspendHandler: (() -> SuspendVerdict)? = nil,
         onSuspendAccepted: (() -> Void)? = nil) {
        self.key = key
        self.suspendHandler = suspendHandler
        self.onSuspendAccepted = onSuspendAccepted
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard sessions.count < VSCtl.maxSessions else { return false }
        let session = VSockCtlSession(connection: connection, key: key,
                                      suspendHandler: suspendHandler,
                                      onSuspendAccepted: onSuspendAccepted) { [weak self] done in
            self?.sessions.removeAll { $0 === done }
        }
        sessions.append(session)
        session.start()
        return true
    }
}

// MARK: - SuspendCtl — the M115d (#2463) suspend action

/// The runner's suspend driver behind the ctl `suspend` verb.
/// `begin()` runs synchronously on the session's serial queue — pause
/// the VM, save machine state into the profile's `saved-state/`, and
/// report the verdict so the reply means what it says: `ok:true` only
/// ever follows a state file that exists. `finish()` runs after the
/// reply is written: stop the VM and exit — a suspended run is done,
/// and `--resume` is the continuation.
final class SuspendCtl {
    /// The machine-state file inside a profile's saved-state/ — the one
    /// name both the save and `--resume` agree on.
    static let stateFileName = "state.vzsave"

    private let vm: VZVirtualMachine
    private let queue: DispatchQueue
    /// The profile's saved-state directory; nil when no profile is
    /// armed — the `no_state` refusal.
    private let savedStateDir: URL?
    /// A validateSaveRestoreSupport refusal (custom-virtio et al.) —
    /// the `unsupported` code, computed once at arm time.
    private let unsupported: String?
    private var inFlight = false

    init(vm: VZVirtualMachine, queue: DispatchQueue,
         savedStateDir: URL?, unsupported: String?) {
        self.vm = vm
        self.queue = queue
        self.savedStateDir = savedStateDir
        self.unsupported = unsupported
    }

    /// The wire verdict for one `suspend` request. Runs the VZ calls on
    /// the VM's own queue and waits — the session's serial queue is the
    /// caller, so a semaphore hop is the honest serialization.
    func begin() -> SuspendVerdict {
        if inFlight { return .refuse("busy") }
        if unsupported != nil { return .refuse("unsupported") }
        guard let dir = savedStateDir else { return .refuse("no_state") }
        inFlight = true
        let stateURL = dir.appendingPathComponent(Self.stateFileName)
        // A fresh suspend SUPERSEDES the previous saved state — VZ
        // refuses to create the file over an existing one (observed
        // live-suspend-resume sv2: VZErrorDomain Code=11 "File exists").
        try? FileManager.default.removeItem(at: stateURL)
        let done = DispatchSemaphore(value: 0)
        var verdict = SuspendVerdict.refuse("io_error")
        queue.async { [vm] in
            vm.pause { result in
                if case .failure(let error) = result {
                    FileHandle.standardError.write(Data("ERROR: VSOCK-CTL: suspend pause refused: \(error as NSError)\n".utf8))
                    verdict = .refuse("save_failed")
                    done.signal()
                    return
                }
                print("VSOCK-CTL: suspend paused; saving \(stateURL.path)")
                vm.saveMachineStateTo(url: stateURL) { error in
                    if let error {
                        FileHandle.standardError.write(Data("ERROR: VSOCK-CTL: suspend save refused: \(error as NSError)\n".utf8))
                        // The guest is paused mid-request and the freeze
                        // it asked for never landed — bring it back.
                        vm.resume { _ in done.signal() }
                        verdict = .refuse("save_failed")
                        return
                    }
                    print("VSOCK-CTL: suspend saved \(Self.stateFileName)")
                    verdict = .accept
                    done.signal()
                }
            }
        }
        done.wait()
        return verdict
    }

    /// The post-reply tail: the ok line is on the wire (the guest will
    /// read it on restore), so the run ends through the runner's own
    /// finish path. `suspendStopInFlight` tells scriptPoll the coming
    /// stop is the suspend teardown, never an early-stop failure.
    func finish() {
        queue.async {
            print("VSOCK-CTL: suspend stopping")
            suspendStopInFlight = true
            VMRunner.finish(success: true)
        }
    }
}
