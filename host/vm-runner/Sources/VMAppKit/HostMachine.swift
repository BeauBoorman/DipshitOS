import AppKit
import Foundation
import VMProfile

/// M120c (#2560, index #2548): the persistence lifecycle's MODEL — the
/// part `swift test` pins. Five Machine-menu verbs ride it through the
/// bus:
///
///   - `suspend`          pauses the machine, saves its state into the
///                        profile's `saved-state/`, and stops the run —
///                        the M115d ctl `suspend` verb's host-side twin
///                        (`--resume` is the continuation either way).
///   - `snapshot`         parks a `menu-<stamp>.vzsave` machine-state
///                        snapshot under the armed share's `SNAPSHOTS/` —
///                        the same file GOSNAP's `save` writes, so the
///                        guest can `gosnap restore` what the menu took.
///   - `apply-update`     verifies the guest-staged signed set in
///                        `<share>/UPDATE/` and swaps it in as the base —
///                        the `--apply-update` flag's surgery as a verb.
///   - `rollback-update`  swaps `<base>.prev` back — `--rollback-update`
///                        as a verb.
///   - `reveal-share`     opens the armed host share in Finder.
///
/// The update verbs are pure host file operations — a rename keeps the
/// running VM's open inodes valid (the profile-switch precedent), so
/// their enablement is the POSTURE (set staged? `.prev` present? trust
/// pin resolvable?) and never the VM's state; the swap takes effect on
/// the next boot. Suspend/snapshot need the live machine, so their
/// enablement adds `vmRunning` + the device set's save/restore verdict —
/// the two reads only the runner can answer, injected as `saveCapable`/
/// `vmRunning`/`suspendDriver`/`snapshotDriver` at arm time. The model
/// resolves everything else from the runner's own argv (`--profile`/
/// `--resume`, `--cvc-file`/`--virtio-fs`, `--overlay-base`,
/// `--update-key`), so a bare `HostCommandBus()` in a scripted
/// `--host-cmd-after` run dispatches the identical seam the menu does
/// and a flag-less run receipts `disabled` from the verbs' own posture.
///
/// The drivers return the wire's refusal vocabulary (`nil` = accept,
/// else the ADR 0056 code — `busy`/`unsupported`/`no_state`/`exists`/
/// `save_failed`) without VMAppKit importing VSCtl or Virtualization.
///
/// All access is main-queue (the bus, the menu and the banner all are),
/// so the model takes no lock — the HostCommandBus precedent.
public final class HostMachineModel {
    /// The share subdirectory the snapshot verb mints into and
    /// `stagedUpdate` reads — the same `SNAPSHOTS/` name VMRunner's
    /// SnapshotCtl and the guest's `/host/SNAPSHOTS/` agree on.
    public static let snapshotsDirName = "SNAPSHOTS"
    /// The stored-snapshot suffix — SnapshotCtl.fileSuffix's twin; a
    /// menu snapshot must read as a GOSNAP name to `gosnap ls`.
    public static let snapshotSuffix = ".vzsave"

    // MARK: Seams — every external input is injectable.

    /// argv override: nil reads CommandLine.arguments (production).
    public var arguments: [String]?
    /// Direct override beats argv resolution — the test seam, and the
    /// document-launch arm M128c established (`profileURL` is set on the
    /// settings/profiles models the same way).
    public var profileURL: URL?
    /// Direct share override; else `--cvc-file`/`--virtio-fs` argv, else
    /// the armed profile's share/.
    public var shareDir: URL?
    /// Direct base-image override; else `--overlay-base` argv, else the
    /// armed profile's `config.baseImage`.
    public var baseImageURL: URL?
    /// Direct overlay override; else the armed profile's overlay.asif.
    public var overlayURL: URL?
    /// Direct saved-state override; else the armed profile's
    /// saved-state/.
    public var savedStateDir: URL?
    /// Direct trust-pin override; else `--update-key` argv, else the
    /// armed profile's `config.updatePubkey`.
    public var updateKeyHex: String?
    /// The device set's save/restore verdict — the runner injects its
    /// `validateSaveRestoreSupport()` result; the flags-off default says
    /// not save-capable so a bare bus receipts `disabled` (the
    /// "device absent" posture the card names).
    public var saveCapable: () -> Bool = { false }
    /// Live VM check — the runner injects `runner.vm.state == .running`;
    /// a not-running machine has nothing to freeze.
    public var vmRunning: () -> Bool = { false }
    /// The VZ suspend driver — the runner injects SuspendCtl's
    /// begin+finish. Returns nil on accept, else the wire refusal code.
    public var suspendDriver: (() -> String?)?
    /// The VZ snapshot driver — the runner injects SnapshotCtl's
    /// save+resume-after-reply for one name. Returns nil on accept, else
    /// the wire refusal code.
    public var snapshotDriver: ((String) -> String?)?
    /// The Finder reveal — a real NSWorkspace ask in production, a stub
    /// in tests. Fire-and-forget like every orderFront: the request's
    /// delivery is not the receipt's business.
    public var reveal: (URL) -> Bool = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
    /// The marker sink — the bus wires it to its own emit so
    /// `host-machine:` and `host-ui:` lines share one stream.
    public var emit: (String) -> Void = {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }
    /// Model → view notification (main queue, the HostInspector rule) —
    /// the staged-update banner refreshes on it.
    public var onChange: (() -> Void)?

    // MARK: State — what the receipts read.

    /// Why the last action failed, if it did — the receipt's `error=`
    /// leg (the refusal code or the first line of the thrown error).
    public private(set) var lastError: String?
    /// The one-word result of the last verb — the receipt tail a gate
    /// greps (`suspended`, `name=menu-…`, `version=<v>`,
    /// `restored sha256=<8>`, `share=<name>`).
    public private(set) var lastAction: String = "none"
    /// Successful menu snapshots this run.
    public private(set) var snapshotCount = 0
    /// The loaded armed profile, cached — the member URLs (share/,
    /// saved-state/, overlay.asif) are manifest names, so the load is
    /// the honest resolution and one open is enough.
    private var profileCache: (url: URL, profile: VMProfile)?

    public init() {}

    // MARK: Arming — argv resolution and posture.

    /// The armed bundle path — `--profile`, else `--resume` (a resume IS
    /// a profile boot; the HostSettingsModel rule).
    public func resolvedProfileURL() -> URL? {
        profileURL ?? HostSettingsModel.profileURL(arguments: arguments ?? CommandLine.arguments)
    }

    private func resolvedProfile() -> VMProfile? {
        guard let url = resolvedProfileURL() else { return nil }
        if let cached = profileCache, cached.url == url { return cached.profile }
        guard let p = try? VMProfile.load(from: url) else { return nil }
        profileCache = (url, p)
        return p
    }

    /// Last occurrence wins — the runner's flag loop overwrites the
    /// slot per hit, so a repeated flag resolves to its LAST value (the
    /// gate harness prepends its own --overlay-base before the leg's,
    /// and the boot attaches the leg's). Resolving the FIRST instead
    /// makes the apply-update swap land on the harness's default base —
    /// the receipt reads `applied` while the booted base never changed.
    private func argvValue(_ flag: String) -> String? {
        let args = arguments ?? CommandLine.arguments
        guard let i = args.lastIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func isDir(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// The armed host share — the flag channel first (`--cvc-file` or
    /// `--virtio-fs`, the runner's own precedence), else the profile's
    /// share/. nil when nothing is armed or the dir is absent — a share
    /// that is not there is the `no_state` posture, not a destination.
    public func resolvedShareDir() -> URL? {
        let url: URL? = shareDir
            ?? argvValue("--cvc-file").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? argvValue("--virtio-fs").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resolvedProfile()?.shareURL
        guard let url, Self.isDir(url) else { return nil }
        return url
    }

    /// The boot base image — `--overlay-base` wins over the profile's
    /// `config.baseImage` (the runner's own precedence).
    public func resolvedBaseImage() -> URL? {
        baseImageURL
            ?? argvValue("--overlay-base").map { URL(fileURLWithPath: $0) }
            ?? resolvedProfile().map { URL(fileURLWithPath: $0.config.baseImage) }
    }

    /// The persistent overlay the update swap discards (the profile's
    /// overlay.asif when one is armed).
    public func resolvedOverlay() -> URL? {
        overlayURL ?? resolvedProfile()?.overlayURL
    }

    /// The suspend destination — the profile's saved-state/; nil (or an
    /// absent dir) is the `no_state` posture the ctl verb reports.
    public func resolvedSavedStateDir() -> URL? {
        guard let dir = savedStateDir ?? resolvedProfile()?.savedStateURL,
              Self.isDir(dir) else { return nil }
        return dir
    }

    /// The update trust pin — `--update-key`, else the bundle's own
    /// `config.updatePubkey` (a host-side value the guest cannot reach).
    public func resolvedUpdateKey() -> Data? {
        guard let hex = updateKeyHex ?? argvValue("--update-key")
                ?? resolvedProfile()?.config.updatePubkey,
              let key = Self.dataFromHex(hex), key.count == 32 else { return nil }
        return key
    }

    /// The `<base>.prev` a rollback would restore, when one exists.
    public var rollbackTarget: URL? {
        guard let base = resolvedBaseImage() else { return nil }
        let prev = base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + ".prev")
        return FileManager.default.fileExists(atPath: prev.path) ? prev : nil
    }

    /// The guest-staged update set on the armed share, when present —
    /// the staged-update banner's truth and `apply-update`'s posture.
    public var stagedUpdate: URL? {
        resolvedShareDir().flatMap { OSUpdate.stagedDir(shareDir: $0) }
    }

    /// The staged set's version label, when its manifest parses — the
    /// banner's "(v)" parenthetical; the signature is the apply's job,
    /// not the banner's.
    public var stagedVersion: String? {
        guard let updateDir = stagedUpdate,
              let mf = try? Data(contentsOf: updateDir
                    .appendingPathComponent(OSUpdate.manifestName)),
              let manifest = try? OSUpdate.parseManifest(mf) else { return nil }
        return manifest.version
    }

    /// The save/restore posture word — the VSOCK-CTL arming line's
    /// vocabulary (`unsupported`/`stopped`/`armed`), so a `save=` receipt
    /// leg reads the same truth the ctl listener prints.
    public var savePosture: String {
        guard saveCapable() else { return "unsupported" }
        guard vmRunning() else { return "stopped" }
        return "armed"
    }

    // MARK: Enablement — the live posture each verb greys on.

    /// `suspend`: save-capable device set, a running machine, a real
    /// saved-state destination, and an armed driver.
    public var canSuspend: Bool {
        saveCapable() && vmRunning()
            && resolvedSavedStateDir() != nil && suspendDriver != nil
    }

    /// `snapshot`: same running/capable core, but the destination is the
    /// armed share's SNAPSHOTS/.
    public var canSnapshot: Bool {
        saveCapable() && vmRunning()
            && resolvedShareDir() != nil && snapshotDriver != nil
    }

    /// `apply-update`: a staged set to verify, a base to swap, and a
    /// resolvable trust pin. VM state is not posture — the swap lands on
    /// the next boot either way.
    public var canApplyUpdate: Bool {
        stagedUpdate != nil && resolvedBaseImage() != nil && resolvedUpdateKey() != nil
    }

    /// `rollback-update`: a `<base>.prev` to restore.
    public var canRollbackUpdate: Bool { rollbackTarget != nil }

    /// `reveal-share`: a share to show.
    public var canRevealShare: Bool { resolvedShareDir() != nil }

    // MARK: The verbs.

    /// `suspend`: freeze, save into saved-state/, stop the run. The
    /// driver's own verdicts map to the receipt — a dispatch-time refusal
    /// is `failed` with the wire code in `error=`.
    @discardableResult
    public func suspend() -> HostCommandBus.Outcome {
        releaseIdlePause() // M183c: SuspendCtl pauses first — a policy-held pause must lift or the save's pause step refuses.
        guard let driver = suspendDriver else { return fail("no_driver") }
        if let code = driver() { return fail("refuse=\(code)") }
        lastError = nil
        lastAction = "suspended"
        emit("host-machine: suspend saved; run stopping (--resume continues it)")
        changed()
        return .performed
    }

    /// `snapshot`: mint `menu-<stamp>.vzsave` (collision-free `-2`, …)
    /// under the armed share's SNAPSHOTS/ and freeze into it; the
    /// driver's post-save resume is part of the injected pair.
    @discardableResult
    public func snapshot() -> HostCommandBus.Outcome {
        releaseIdlePause() // M183c: the save path pauses first — lift a policy pause before it.
        guard let share = resolvedShareDir(), let driver = snapshotDriver else {
            return fail("no_driver")
        }
        let name = nextSnapshotName(in: share)
        if let code = driver(name) { return fail("refuse=\(code)") }
        snapshotCount += 1
        lastError = nil
        lastAction = "name=\(name)"
        emit("host-machine: snapshot saved \(name)\(Self.snapshotSuffix)")
        changed()
        return .performed
    }

    /// `apply-update`: the M115f verify+swap as a verb — same
    /// refusals-by-name the flag reports (`sig_invalid`, `hash_mismatch`,
    /// …), same `.prev` retention and overlay discard.
    @discardableResult
    public func applyUpdate() -> HostCommandBus.Outcome {
        guard let updateDir = stagedUpdate else {
            lastError = nil
            lastAction = "none_staged"
            return .disabled
        }
        guard let base = resolvedBaseImage() else { return fail("no_base") }
        guard let key = resolvedUpdateKey() else { return fail("no_key") }
        do {
            let manifest = try OSUpdate.apply(updateDir: updateDir, baseImage: base,
                                              publicKey: key, overlay: resolvedOverlay())
            lastError = nil
            lastAction = "version=\(manifest.version)"
            emit("host-machine: applied version=\(manifest.version) image=\(OSUpdate.imageName)")
            changed()
            return .performed
        } catch {
            return fail(updateCode(error))
        }
    }

    /// `rollback-update`: the M115f one-step `.prev` restore as a verb.
    @discardableResult
    public func rollbackUpdate() -> HostCommandBus.Outcome {
        guard let base = resolvedBaseImage() else { return fail("no_base") }
        do {
            let sha = try OSUpdate.rollback(baseImage: base, overlay: resolvedOverlay())
            lastError = nil
            lastAction = "restored sha256=\(sha.prefix(8))"
            emit("host-machine: rollback restored sha256=\(sha)")
            changed()
            return .performed
        } catch {
            return fail(updateCode(error))
        }
    }

    /// `reveal-share`: open the armed share in Finder. Read-only — the
    /// only posture is the share existing.
    @discardableResult
    public func revealShare() -> HostCommandBus.Outcome {
        guard let share = resolvedShareDir() else {
            lastError = nil
            lastAction = "none"
            return .disabled
        }
        guard reveal(share) else { return fail("reveal_refused") }
        lastError = nil
        lastAction = "revealed"
        emit("host-machine: reveal \(share.path)")
        changed()
        return .performed
    }

    // MARK: Receipts — one tail per verb.

    /// The `error=<word>` leg every detail appends — read after the
    /// action like the M114b rule wants, so a `failed`/`disabled`
    /// receipt still reports the live reason (the HostProfilesModel
    /// precedent).
    private var errorTail: String { lastError.map { " error=\($0)" } ?? "" }

    public var suspendDetail: String { "save=\(savePosture) \(lastAction)\(errorTail)" }
    public var snapshotDetail: String { "save=\(savePosture) \(lastAction)\(errorTail)" }
    public var applyUpdateDetail: String {
        "staged=\(stagedUpdate != nil ? 1 : 0) \(lastAction)\(errorTail)"
    }
    public var rollbackUpdateDetail: String {
        "prev=\(rollbackTarget != nil ? 1 : 0) \(lastAction)\(errorTail)"
    }
    public var revealShareDetail: String {
        "share=\(resolvedShareDir()?.lastPathComponent ?? "none") \(lastAction)\(errorTail)"
    }

    // MARK: helpers

    /// The collision-free snapshot name — `menu-<yyyyMMdd-HHmmss>`,
    /// `-2`/`-3`… on a same-second repeat, so two quick dispatches never
    /// trip SnapshotCtl's `exists` consent refusal.
    public func nextSnapshotName(in share: URL) -> String {
        let snaps = share.appendingPathComponent(Self.snapshotsDirName, isDirectory: true)
        let stamp = Self.stampFormatter.string(from: Date())
        var name = "menu-\(stamp)"
        var n = 2
        while FileManager.default.fileExists(
            atPath: snaps.appendingPathComponent(name + Self.snapshotSuffix).path) {
            name = "menu-\(stamp)-\(n)"
            n += 1
        }
        return name
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// The UpdateError description's leading refusal word —
    /// "sig_invalid (UPDATE.SIG does not verify)" → "sig_invalid".
    private func updateCode(_ error: Error) -> String {
        let s = "\(error)"
        return s.components(separatedBy: " ").first ?? s
    }

    private func fail(_ message: String) -> HostCommandBus.Outcome {
        lastError = message
        lastAction = "error"
        emit("host-machine: failed \(message)")
        changed()
        return .failed
    }

    private func changed() { onChange?() }

    // MARK: M183c (#3173) — the idle-pause policy
    //
    // A VM window the user cannot see stops burning a vCPU: when every
    // window this machine owns has been occluded for the configured
    // interval the policy runs `vm.pause()` — the cheap transition, no
    // state save, never a suspend (suspend-on-close keeps its own path).
    // Refocus or any user input event resumes. Host-side only — the
    // guest never knows.

    /// The VZ pause/resume drivers — the runner injects a semaphore hop
    /// onto the VM's queue (the SuspendCtl.begin precedent); nil return
    /// is accept, else a wire-style refusal word. No driver pair → the
    /// policy is unarmed and evaluate holds `no_driver`.
    public var pauseDriver: (() -> String?)?
    public var resumeDriver: (() -> String?)?
    /// The activity vets a pause must never interrupt: guest audio
    /// playing (the runner wires the CoreAudio process check) and a
    /// live capture/recording (the bus wires the recorder's isRecording).
    /// The defaults say quiet so a bare bus exercises the pause path.
    public var audioActive: () -> Bool = { false }
    public var captureActive: () -> Bool = { false }
    /// The host-preference reads — persisted by the settings model's
    /// host store (UserDefaults), injected here so a test owns them.
    /// Defaults: policy on, 5 minutes.
    public var idlePauseEnabled: () -> Bool = { true }
    public var idlePauseSeconds: () -> TimeInterval = { 300 }
    /// The clock — a test pins it to drive the interval edge.
    public var now: () -> Date = { Date() }

    /// True while THIS policy holds the pause — the "paused (idle)"
    /// indicator's truth, and what keeps noteActivity from resuming a
    /// machine something else paused.
    public private(set) var idlePaused = false
    /// When the all-occluded stretch began — nil while any known window
    /// is visible or none have ever reported.
    public private(set) var idleOccludedSince: Date?
    /// Why the last elapsed-interval evaluation did not pause, once per
    /// reason — the `held` marker line's tail.
    public private(set) var idleHoldReason: String?
    /// The `idle-occlude@<seconds>` trigger's staged operand — how long
    /// the scripted stretch has already run (the fireHostCmdTriggers
    /// slot, the closeTargetVM precedent). Consumed by the dispatch.
    public var idleOccludeElapsed: TimeInterval = 0

    /// Each known window's current occlusion bit. The policy requires
    /// at least one window AND all of them occluded — a windowless run
    /// (every scripted headless leg) can never idle-pause.
    private var windowOccluded: [ObjectIdentifier: Bool] = [:]
    /// The scripted edge's token — `idle-occlude` dispatches a window
    /// that lives only in this map, so the gate drives the identical
    /// policy path a real NSWindow reports through.
    private let scriptedWindow = NSObject()
    /// The 1 Hz evaluation tick — armed by the runner's wiring, never
    /// in tests (they call idlePauseEvaluate directly).
    private var idleTimer: Timer?

    deinit { idleTimer?.invalidate() }

    /// Every known window occluded right now — and at least one window
    /// must exist, so a headless run is never "all occluded".
    public var allWindowsOccluded: Bool {
        !windowOccluded.isEmpty && windowOccluded.values.allSatisfy { $0 }
    }

    /// A session window's occlusion edge — its delegate reports the
    /// occlusionState change (and once at arm). Becoming visible is the
    /// focus edge: it resumes a policy-held pause.
    public func noteWindowOcclusion(_ window: AnyObject, occluded: Bool) {
        let id = ObjectIdentifier(window)
        windowOccluded[id] = occluded
        if occluded {
            if idleOccludedSince == nil { idleOccludedSince = now() }
        } else {
            noteActivity()
        }
    }

    /// The resume edge — refocus, a window un-occluding, or any user
    /// input event. Restarts the occlusion clock so a still-occluded
    /// stretch cannot immediately re-pause, and resumes a machine THIS
    /// policy paused. A refused resume keeps the hold (the next
    /// activity retries) and names the code.
    public func noteActivity() {
        if idleOccludedSince != nil { idleOccludedSince = now() }
        guard idlePaused else { return }
        if let code = resumeDriver?() {
            emit("host-machine: idle-pause resume refused code=\(code)")
            return
        }
        idlePaused = false
        idleHoldReason = nil
        emit("host-machine: idle-pause resumed")
        changed()
    }

    /// Lift a policy-held pause — the suspend/snapshot/close/stop paths
    /// call this so a frozen machine never wedges a save's pause step or
    /// a teardown. A no-op unless the policy holds the pause.
    public func releaseIdlePause() {
        guard idlePaused else { return }
        idlePaused = false
        if let code = resumeDriver?() {
            emit("host-machine: idle-pause resume refused code=\(code)")
            idlePaused = true // still frozen — say so
            return
        }
        emit("host-machine: idle-pause resumed")
        changed()
    }

    /// The policy evaluation — the tick's body, also run synchronously
    /// inside the scripted occlusion edge. Pauses only when every known
    /// window has been occluded at least the configured interval, the
    /// preference is on, the VM is running, both drivers are armed, and
    /// neither activity vet objects. `held` reasons emit once each.
    @discardableResult
    public func idlePauseEvaluate() -> Bool {
        guard !idlePaused else { return false }
        guard allWindowsOccluded, let since = idleOccludedSince else {
            idleHoldReason = nil
            return false
        }
        // Inside the grace stretch — waiting, not held.
        guard now().timeIntervalSince(since) >= idlePauseSeconds() else { return false }
        guard idlePauseEnabled() else { return hold("off") }
        guard vmRunning() else { return hold("stopped") }
        guard let pause = pauseDriver, resumeDriver != nil else { return hold("no_driver") }
        guard !audioActive() else { return hold("audio") }
        guard !captureActive() else { return hold("capture") }
        if let code = pause() {
            if idleHoldReason != "refused" {
                idleHoldReason = "refused"
                emit("host-machine: idle-pause refused code=\(code)")
            }
            return false
        }
        idlePaused = true
        idleHoldReason = nil
        emit("host-machine: idle-pause paused occluded=\(Int(now().timeIntervalSince(since)))s")
        changed()
        return true
    }

    private func hold(_ reason: String) -> Bool {
        if idleHoldReason != reason {
            idleHoldReason = reason
            emit("host-machine: idle-pause held reason=\(reason)")
        }
        return false
    }

    /// The `idle-occlude` verb's edge — the scripted twin of "every
    /// window occluded for <idleOccludeElapsed> seconds" (a gate cannot
    /// produce a real NSWindow occlusion change; the close@vm=
    /// precedent). The sentinel window shares the real map, so a
    /// genuinely-visible window still vetoes the pause.
    public func scriptedOcclusion() {
        let elapsed = idleOccludeElapsed
        idleOccludeElapsed = 0
        let id = ObjectIdentifier(scriptedWindow)
        windowOccluded[id] = true
        if let since = idleOccludedSince {
            idleOccludedSince = min(since, now().addingTimeInterval(-elapsed))
        } else {
            idleOccludedSince = now().addingTimeInterval(-elapsed)
        }
        idlePauseEvaluate()
    }

    /// The `idle-focus` verb's edge — the scripted twin of the focus /
    /// user-input resume.
    public func scriptedFocus() { noteActivity() }

    /// Arm the policy — the runner calls this after injecting the
    /// drivers so the armed line names the live interval. The 1 Hz
    /// tick covers "still occluded when the interval elapsed"; the
    /// occlusion/focus events drive the edges. Idempotent.
    public func armIdlePause() {
        guard idleTimer == nil else { return }
        emit("host-machine: idle-pause armed interval=\(Int(idlePauseSeconds()))s")
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.idlePauseEvaluate()
        }
    }

    /// The idle-pause receipt tail — the post-action truth a gate reads
    /// (`paused`/`armed`/`off`, plus the live hold reason).
    public var idleDetail: String {
        var s = "idle=\(idlePaused ? "paused" : (idlePauseEnabled() ? "armed" : "off"))"
        s += " after=\(Int(idlePauseSeconds()))s"
        if let r = idleHoldReason { s += " held=\(r)" }
        return s
    }

    // MARK: M157a (#2934) — the close policy's named messages + refusal word.

    /// The named message a window shows when its `closeAction = suspend`
    /// close is refused — the code, the stop it still runs, and the
    /// `--resume` continuation with the M119e Code=12 bound.
    public static func closeRefusalMessage(code: String) -> String {
        "Suspend on close refused (code=\(code)) — this device set cannot save machine state; the VM is stopping instead. Relaunch with --resume to continue a saved machine (restore saturates at VZErrorDomain Code=12 on this host)."
    }

    /// The saved leg's window message — names the continuation path and
    /// the same bound.
    public static let closeSavedMessage =
        "Suspended on close — saved into the profile's saved-state/. Relaunch with --resume to continue (restore saturates at VZErrorDomain Code=12 on this host)."

    /// The close-policy refusal word — the static Code=2 class when a
    /// custom-virtio flag armed the share (ADR 0059 D8: Code=2 is
    /// decided statically; a boot is never needed to classify it), else
    /// the driver's own wire code.
    public func closeRefusalCode(_ wireCode: String) -> String {
        if wireCode == "unsupported",
           Self.argvArmsCustomVirtio(arguments ?? CommandLine.arguments) {
            return "2"
        }
        return wireCode
    }

    static func argvArmsCustomVirtio(_ args: [String]) -> Bool {
        args.contains { Self.customVirtioFlags.contains($0) }
    }

    /// Every flag that arms a VZCustomVirtioDevice — the
    /// validateSaveRestoreSupport Code=2 set (the vgate_checkpoint
    /// refusal list, ADR 0059 D1/D8).
    static let customVirtioFlags: Set<String> = [
        "--custom-virtio", "--cvc-echo", "--via-virtio", "--pointer-virtio",
        "--cvc-snap", "--cvc-file", "--cvc-console-file", "--snapshot-after",
        "--gpu3d-metal",
    ]

    /// The runner's `dataFromHex`, duplicated so VMAppKit stays free of
    /// the VMRunner target (the HostSettings/HostProfiles argv-resolution
    /// precedent).
    private static func dataFromHex(_ hex: String) -> Data? {
        var out = Data()
        out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard j > i, let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}

// MARK: - HostStatsModel — M157a (#2934): the per-window stats line

/// The stats line every VM window carries: configured vCPUs, RAM, the
/// live state word, and uptime. Configured figures ONLY — no usage
/// metrics; a figure the line cannot show is dropped from it and named
/// in the tooltip (the honesty rule the card sets).
public final class HostStatsModel {
    /// The configured vCPU count — nil until the owner arms it (the
    /// runner knows its own VZ configuration; a test injects it).
    public var vcpus: Int?
    /// The configured RAM in MiB — same arming rule.
    public var memoryMiB: Int?
    /// The live state word — "starting"/"running"/"paused"/"stopping"/
    /// "stopped"/"failed". The owner injects its own state read.
    public var stateProvider: () -> String = { "starting" }
    /// The VM-start timestamp — nil until the machine reports started,
    /// so a not-started window shows no uptime.
    public var startedAt: Date?
    /// The clock — a test pins it to read a fixed uptime.
    public var now: () -> Date = { Date() }

    public init() {}

    /// The line — "2 vCPU · 512 MiB · running · up 3m" with unshowable
    /// figures dropped (and named in `tooltip`).
    public var line: String {
        var parts: [String] = []
        if let vcpus { parts.append("\(vcpus) vCPU") }
        if let memoryMiB { parts.append("\(memoryMiB) MiB") }
        parts.append(stateProvider())
        if let startedAt { parts.append("up \(Self.uptime(now().timeIntervalSince(startedAt)))") }
        return parts.joined(separator: " · ")
    }

    /// The tooltip — says the line is configured-only and names every
    /// figure the line cannot currently show.
    public var tooltip: String {
        var missing: [String] = []
        if vcpus == nil { missing.append("vCPU count") }
        if memoryMiB == nil { missing.append("RAM") }
        if startedAt == nil { missing.append("uptime (machine not yet started)") }
        let head = "Configured shape — no usage metrics collected"
        return missing.isEmpty ? head + "."
            : head + ". Missing: " + missing.joined(separator: ", ") + "."
    }

    /// Compact uptime — "0m" under a minute, then "Nm" / "HhMm".
    public static func uptime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "0m" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\(s % 3600 / 60)m"
    }

    // The live-item seams — refresh() repaints after state/uptime moves.
    private weak var statsField: NSTextField?
    private weak var statsItem: NSToolbarItem?

    /// One toolbar item — the session toolbar (HostApplication) and a
    /// sibling window's lone-item bar (HostStatsBar) both vend it.
    public func makeToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        let field = NSTextField(labelWithString: line)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.toolTip = tooltip
        item.view = field
        item.label = "Machine"
        item.paletteLabel = "Machine Stats"
        item.toolTip = tooltip
        statsField = field
        statsItem = item
        return item
    }

    /// Repaint the live item — cheap enough to run on a poll tick.
    public func refreshItem() {
        statsField?.stringValue = line
        statsField?.toolTip = tooltip
        statsItem?.toolTip = tooltip
    }
}

/// A sibling window's lone-item toolbar — the stats line is the only
/// chrome a session window gets (the menu bar stays process-global).
public final class HostStatsBar: NSObject, NSToolbarDelegate {
    public static let itemID = NSToolbarItem.Identifier("virelai.stats")
    public let model: HostStatsModel
    public init(model: HostStatsModel) { self.model = model }
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.itemID] }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.itemID] }
    public func toolbar(_ toolbar: NSToolbar,
                        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == Self.itemID ? model.makeToolbarItem(itemIdentifier) : nil
    }
}
