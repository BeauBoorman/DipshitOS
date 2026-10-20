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
