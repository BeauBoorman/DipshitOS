import Foundation
import VSCtl
import Virtualization
import VMProfile

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

    /// M115e (#2464): the named-snapshot driver, shared by every session
    /// the listener accepts. Held so the post-reply resume lands on the
    /// same object that paused.
    private let snapshotCtl: SnapshotCtl?

    init(connection: VZVirtioSocketConnection, key: Data,
         suspendHandler: (() -> SuspendVerdict)? = nil,
         onSuspendAccepted: (() -> Void)? = nil,
         snapshotCtl: SnapshotCtl? = nil,
         restoreCtl: RestoreCtl? = nil,
         profileInfo: (() -> ProfileSummary)? = nil,
         onDone: @escaping (VSockCtlSession) -> Void) {
        self.connection = connection
        var rng = SystemRandomNumberGenerator()
        let challenge = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        var session = CTLSession(key: key, challenge: challenge)
        session.suspendHandler = suspendHandler
        session.snapshotHandler = snapshotCtl.map { ctl in { name in ctl.save(name: name) } }
        session.restoreHandler = restoreCtl.map { ctl in { name in ctl.stage(name: name) } }
        session.profileInfoHandler = profileInfo
        self.session = session
        self.snapshotCtl = snapshotCtl
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
            // M115e (#2464): a snapshot reply — accept or refusal — is
            // written while the guest is still frozen (the reply lands in
            // the posted rx buffers, so a later --resume of this image
            // finds the answer already delivered); THEN the machine
            // resumes. A refusal before the driver paused is a no-op.
            if session.answeredSnapshot {
                if let code = Self.replyCode(reply) {
                    print("VSOCK-CTL: reply verb=snapshot code=\(code)")
                } else {
                    print("VSOCK-CTL: reply ok=true verb=snapshot")
                }
                snapshotCtl?.resumeAfterReply()
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

    /// M115e (#2464): the snapshot/restore drivers every session gets.
    private let snapshotCtl: SnapshotCtl?
    private let restoreCtl: RestoreCtl?

    /// M128d (#2608): the `profile-info` answerer every session gets —
    /// samples the armed profile/share at request time.
    private let profileInfo: () -> ProfileSummary

    /// M139a (#2779): the per-session inputs the snapshot/restore drivers
    /// and the `profile-info` answer used to read from main.swift's
    /// globals — packaged so a secondary VMSession arms its own ctl
    /// endpoint with ITS machine, share and saved-state dir.
    struct Context {
        let vm: VZVirtualMachine
        let queue: DispatchQueue
        let shareDirs: [URL]
        let savedStateDir: URL?
        let unsupported: String?
        let overlayBasePath: String?
        let profile: VMProfile?
    }

    init(key: Data, context: Context,
         suspendHandler: (() -> SuspendVerdict)? = nil,
         onSuspendAccepted: (() -> Void)? = nil) {
        self.key = key
        self.suspendHandler = suspendHandler
        self.onSuspendAccepted = onSuspendAccepted
        // M115e (#2464): the snapshot/restore drivers are constructed
        // here rather than handed in — the context carries the same
        // inputs the suspend wiring computes: the session's armed share
        // dirs, its profile's saved-state dir, and its device set's
        // save/restore verdict.
        let snapCtl = SnapshotCtl(vm: context.vm, queue: context.queue,
                                shareDir: context.shareDirs.first,
                                unsupported: context.unsupported)
        let rstCtl = RestoreCtl(shareDir: context.shareDirs.first,
                              savedStateDir: context.savedStateDir)
        snapshotCtl = snapCtl
        restoreCtl = rstCtl
        // M128d (#2608): which machine the guest is. Read-only, so a run
        // without a profile answers "-" fields rather than refusing —
        // the snapshot count still reports from whatever share is armed.
        let infoShare = context.shareDirs.first
        let overlayBasePath = context.overlayBasePath
        let profileName = context.profile?.name
        profileInfo = {
            let baseName = overlayBasePath
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"
            var rollback = false
            if let base = overlayBasePath {
                let u = URL(fileURLWithPath: base)
                let prev = u.deletingLastPathComponent()
                    .appendingPathComponent(u.lastPathComponent + ".prev")
                rollback = FileManager.default.fileExists(atPath: prev.path)
            }
            var snaps: UInt64 = 0
            if let share = infoShare,
               let names = try? FileManager.default.contentsOfDirectory(
                   atPath: share.appendingPathComponent(
                       SnapshotCtl.dirName, isDirectory: true).path) {
                for n in names where n.hasSuffix(SnapshotCtl.fileSuffix) {
                    snaps += 1
                }
            }
            return ProfileSummary(profile: profileName ?? "-",
                                  base: baseName, rollback: rollback,
                                  snapshots: snaps)
        }
        print("VSOCK-CTL: snapshot=\(snapCtl.armState) restore=\(rstCtl.armState)")
    }

    /// The primary session's call-site shape (M115e): the context is
    /// computed from the runner's armed globals, unchanged.
    convenience init(key: Data,
         suspendHandler: (() -> SuspendVerdict)? = nil,
         onSuspendAccepted: (() -> Void)? = nil) {
        let shareDirs = [cvcFileShareDir, virtioFSShareDir].compactMap { $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        var unsupported: String? = nil
        do { try config.validateSaveRestoreSupport() } catch {
            unsupported = "\(error as NSError)"
        }
        self.init(key: key,
                  context: Context(vm: runner.vm, queue: runner.queue,
                                   shareDirs: shareDirs,
                                   savedStateDir: activeProfile?.savedStateURL,
                                   unsupported: unsupported,
                                   overlayBasePath: overlayBasePath,
                                   profile: activeProfile),
                  suspendHandler: suspendHandler,
                  onSuspendAccepted: onSuspendAccepted)
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard sessions.count < VSCtl.maxSessions else { return false }
        let session = VSockCtlSession(connection: connection, key: key,
                                      suspendHandler: suspendHandler,
                                      onSuspendAccepted: onSuspendAccepted,
                                      snapshotCtl: snapshotCtl,
                                      restoreCtl: restoreCtl,
                                      profileInfo: profileInfo) { [weak self] done in
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

    /// M139a (#2779): the post-reply tail's override — a secondary
    /// session installs a hook that stops ITS VM instead of the whole
    /// run (nil keeps the primary's process-finish behavior).
    var onFinish: (() -> Void)?

    /// The post-reply tail: the ok line is on the wire (the guest will
    /// read it on restore), so the run ends through the runner's own
    /// finish path. `suspendStopInFlight` tells scriptPoll the coming
    /// stop is the suspend teardown, never an early-stop failure.
    func finish() {
        queue.async {
            print("VSOCK-CTL: suspend stopping")
            if let onFinish = self.onFinish {
                onFinish()
            } else {
                suspendStopInFlight = true
                VMRunner.finish(success: true)
            }
        }
    }
}

// MARK: - SnapshotCtl / RestoreCtl — the M115e (#2464) named-snapshot actions
//
// `snapshot <name>` parks the RUNNING machine's state on the armed share
// as `SNAPSHOTS/<name>.vzsave` — on the share rather than the profile's
// saved-state/, so the guest's GOSNAP.ELF can list and delete named
// snapshots with plain /host file ops. The save goes to a `.part` name
// first and is renamed into place, so a guest listing never sees a
// half-written snapshot.
//
// The reply contract is the suspend one, mirrored: `save()` leaves the
// machine PAUSED, the session writes the verdict while the guest is
// still frozen (the reply lands in the posted rx buffers — a later
// `--resume` of this image finds the answer already delivered), and
// `resumeAfterReply()` then continues the machine. A refusal issued
// before the pause is a clean no-op.
//
// `restore <name>` stages a named snapshot as the next `--resume`
// target: a host-side copy over the profile's saved-state/state.vzsave —
// the one path the resume guard already reads — so `--resume` needs no
// new shape and the running machine is untouched. The rewind happens on
// the next boot; a later `suspend` supersedes the stage (its save
// overwrites state.vzsave, the same rule a fresh suspend already
// applies to a previous one).

/// The snapshot driver behind the ctl `snapshot <name>` verb.
final class SnapshotCtl {
    /// The share subdirectory both ends agree on — the guest reads it as
    /// `/host/SNAPSHOTS/`.
    static let dirName = "SNAPSHOTS"
    /// The suffix a stored snapshot carries; `ls` shows only these.
    static let fileSuffix = ".vzsave"

    private let vm: VZVirtualMachine
    private let queue: DispatchQueue
    /// The armed share root — the snapshot destination; nil is `no_state`.
    private let shareDir: URL?
    /// A validateSaveRestoreSupport refusal (custom-virtio et al.) —
    /// the `unsupported` code, computed once at arm time.
    private let unsupported: String?
    private var inFlight = false
    /// Set while the machine is held paused between a save and the
    /// post-reply resume — resumeAfterReply's whole contract.
    private var pausedForReply = false

    init(vm: VZVirtualMachine, queue: DispatchQueue,
         shareDir: URL?, unsupported: String?) {
        self.vm = vm
        self.queue = queue
        self.shareDir = shareDir
        self.unsupported = unsupported
    }

    /// The armed-posture word for the listener's marker line.
    var armState: String {
        if unsupported != nil { return "unsupported" }
        return shareDir == nil ? "no_state" : "armed"
    }

    /// The on-share path of name's snapshot file.
    static func snapshotURL(in shareDir: URL, name: String) -> URL {
        shareDir.appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent(name + fileSuffix)
    }

    /// The wire verdict for one `snapshot <name>` request. Runs the VZ
    /// calls on the VM's own queue and waits — the session's serial
    /// queue is the caller, so a semaphore hop is the honest
    /// serialization. On accept the machine stays paused; the session
    /// writes the reply, then resumeAfterReply continues it.
    func save(name: String) -> SuspendVerdict {
        if inFlight { return .refuse("busy") }
        if unsupported != nil { return .refuse("unsupported") }
        guard let shareDir else { return .refuse("no_state") }
        let final = Self.snapshotURL(in: shareDir, name: name)
        if FileManager.default.fileExists(atPath: final.path) {
            // A named snapshot is never silently overwritten — the
            // consent path is `gosnap rm` first.
            return .refuse("exists")
        }
        inFlight = true
        defer { inFlight = false }
        let snapsDir = shareDir.appendingPathComponent(Self.dirName, isDirectory: true)
        let tmp = final.appendingPathExtension("part")
        do {
            try FileManager.default.createDirectory(at: snapsDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: tmp) // a .part left by a killed run
        } catch {
            return .refuse("io_error")
        }
        let done = DispatchSemaphore(value: 0)
        var verdict = SuspendVerdict.refuse("io_error")
        queue.async { [vm] in
            vm.pause { result in
                if case .failure(let error) = result {
                    FileHandle.standardError.write(Data("ERROR: VSOCK-CTL: snapshot pause refused: \(error as NSError)\n".utf8))
                    verdict = .refuse("save_failed")
                    done.signal()
                    return
                }
                self.pausedForReply = true
                vm.saveMachineStateTo(url: tmp) { error in
                    if let error {
                        FileHandle.standardError.write(Data("ERROR: VSOCK-CTL: snapshot save refused: \(error as NSError)\n".utf8))
                        // Nothing was staged — resume now rather than
                        // holding the guest frozen for a refusal.
                        self.pausedForReply = false
                        vm.resume { _ in done.signal() }
                        verdict = .refuse("save_failed")
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: tmp, to: final)
                    } catch {
                        FileHandle.standardError.write(Data("ERROR: VSOCK-CTL: snapshot rename refused: \(error as NSError)\n".utf8))
                        self.pausedForReply = false
                        vm.resume { _ in done.signal() }
                        verdict = .refuse("save_failed")
                        return
                    }
                    print("VSOCK-CTL: snapshot saved \(name)\(Self.fileSuffix)")
                    verdict = .accept
                    done.signal()
                }
            }
        }
        done.wait()
        return verdict
    }

    /// The post-reply tail: the verdict line is on the wire (it landed
    /// in the guest's posted rx buffers while frozen, so a later
    /// `--resume` of this image reads its answer), so the machine
    /// resumes. A no-op when save() never reached the pause.
    func resumeAfterReply() {
        guard pausedForReply else { return }
        pausedForReply = false
        queue.async { [vm] in
            vm.resume { result in
                if case .failure(let error) = result {
                    FileHandle.standardError.write(Data("ERROR: VSOCK-CTL: snapshot resume refused: \(error as NSError)\n".utf8))
                    return
                }
                print("VSOCK-CTL: snapshot resumed")
            }
        }
    }
}

/// The restore driver behind the ctl `restore <name>` verb — a host-side
/// file stage only; it never touches the running machine.
final class RestoreCtl {
    private let shareDir: URL?
    /// The profile's saved-state/ — the `--resume` target dir; nil is
    /// `no_state`.
    private let savedStateDir: URL?

    init(shareDir: URL?, savedStateDir: URL?) {
        self.shareDir = shareDir
        self.savedStateDir = savedStateDir
    }

    var armState: String {
        savedStateDir == nil ? "no_state" : "armed"
    }

    /// Stage `<name>` as the next `--resume`: copy
    /// `SNAPSHOTS/<name>.vzsave` over saved-state/state.vzsave. An
    /// existing state file is replaced — that overwrite is exactly what
    /// the guest-side consent gesture covered.
    func stage(name: String) -> SuspendVerdict {
        guard let shareDir, let savedStateDir else { return .refuse("no_state") }
        let src = SnapshotCtl.snapshotURL(in: shareDir, name: name)
        guard FileManager.default.fileExists(atPath: src.path) else {
            return .refuse("not_found")
        }
        let dst = savedStateDir.appendingPathComponent(SuspendCtl.stateFileName)
        do {
            try FileManager.default.createDirectory(at: savedStateDir, withIntermediateDirectories: true)
            // A staged restore supersedes a previous saved state (a
            // `suspend`'s file or an earlier stage) — the guest consented.
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            FileHandle.standardError.write(Data("ERROR: VSOCK-CTL: restore stage refused: \(error as NSError)\n".utf8))
            return .refuse("io_error")
        }
        print("VSOCK-CTL: restore staged name=\(name)")
        return .accept
    }
}
