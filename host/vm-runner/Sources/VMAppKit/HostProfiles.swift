import Foundation
import VMProfile

/// M128b (#2606, index #2556): the profile manager's MODEL — the part
/// `swift test` pins. Four Machine-menu verbs ride it through the bus:
///
///   - `profile-new`           mints a sibling bundle (`untitled`,
///                             `untitled-2`, …) in the profiles dir.
///   - `profile-clone`         clones the ARMED bundle: config + a
///                             recursive share/ copy, fresh overlay —
///                             `VMProfile.clone` owns the surgery.
///   - `profile-reset-overlay` deletes the armed bundle's overlay.asif;
///                             the attach point re-mints it over the
///                             read-only base on next boot — the wedged-
///                             boot safety net, no `rm -rf`.
///   - `profile-switch`        exchanges the ARMED bundle's path with a
///                             chosen sibling's — the launcher's armed
///                             path IS the current-machine pointer (the
///                             session always boots `--profile <path>`),
///                             so swapping which bundle lives there is
///                             switching. The running VM's open files
///                             follow the moved inode — its writes still
///                             land in its own bundle — then the verb
///                             asks the session to stop.
///
/// Destructive posture: reset/switch while the VM is running demand a
/// confirmation the model cannot itself produce — the `confirm` seam is
/// an NSAlert in the session window (HostApplication wires it) and a
/// test's stub; the fail-closed default declines, so a bare bus receipts
/// `disabled`. `vmRunning`/`requestStop` are injected for the same reason:
/// the model never reaches for runner globals.
///
/// Like the settings model and the AGENTD companion, the armed bundle
/// resolves from the runner's own argv (`--profile`/`--resume`), so a
/// bare `HostCommandBus()` in a `--host-cmd-after` run dispatches the
/// identical seam the menu does. The profiles dir is the armed bundle's
/// parent — siblings are the other machines.
///
/// All access is main-queue (the bus, the menu and the panel all are),
/// so the model takes no lock — the HostCommandBus precedent.
public final class HostProfilesModel {
    // MARK: Seams — every external input is injectable.

    /// argv override: nil reads CommandLine.arguments (production). The
    /// armed profile resolves from `--profile`/`--resume` — the same rule
    /// HostSettingsModel applies (a resume IS a profile boot).
    public var arguments: [String]?
    /// Direct override beats argv resolution — the test seam.
    public var profileURL: URL?
    /// Where new/cloned bundles land and where `Switch To` looks for
    /// siblings. nil = the armed bundle's parent directory.
    public var profilesDir: URL?
    /// Live VM check for the confirm gate — HostApplication wires the
    /// session lifecycle; the fail-safe default says nothing is running.
    public var vmRunning: () -> Bool = { false }
    /// The confirmation ask — an NSAlert in the session, a stub in tests.
    /// The default declines: a headless dispatch of a destructive verb
    /// while running receipts `disabled`, never performs.
    public var confirm: (String) -> Bool = { _ in false }
    /// `profile-switch`'s session-stop request — HostApplication wires
    /// `stop("profile-switch")`; a bare bus's no-op leaves the swap as
    /// the whole action (next launch boots the target).
    public var requestStop: (String) -> Void = { _ in }
    /// The marker sink — the bus wires it to its own emit so
    /// `host-profiles:` and `host-ui:` lines share one stream.
    public var emit: (String) -> Void = {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }
    /// Model → view notification (main queue, the HostInspector rule).
    public var onChange: (() -> Void)?

    // MARK: State — what the receipts read.

    /// Why the last action failed, if it did — refused loads and failed
    /// mints name their file through here and the `error=` receipt leg.
    public private(set) var lastError: String?
    /// The bundle the last `profile-new`/`profile-clone` minted.
    public private(set) var lastMinted: URL?
    /// The one-word result of the last verb — the receipt tail a gate
    /// greps (`created=untitled`, `clone=test-copy`, `overlay=reset`,
    /// `switch=test-clone`, `confirm=declined`).
    public private(set) var lastAction: String = "none"
    /// The bundle `profile-switch` acts on — the Switch To submenu sets
    /// it per item (the item identifier carries the path); a test sets
    /// it directly.
    public var switchTarget: URL?
    /// M139a (#2779): the bundle `new-window` opens — the "New Window for
    /// Profile" submenu leaf sets it from its identifier; a
    /// `--host-cmd-after <marker>:new-window@<path>` trigger sets it from
    /// the spec's `@` operand before dispatching.
    public var newWindowTarget: URL?
    /// M139a: the session registry's already-open check, injected by the
    /// runner — the "New Window for Profile" submenu drops bundles that
    /// are already live in a window (the dispatch's `profile_in_use`
    /// refusal is the same seam headlessly).
    public var sessionOpenCheck: ((URL) -> Bool)?

    public init() {}

    // MARK: Arming — argv resolution and posture.

    public func resolvedProfileURL() -> URL? {
        profileURL ?? HostSettingsModel.profileURL(arguments: arguments ?? CommandLine.arguments)
    }

    public func resolvedProfilesDir() -> URL? {
        profilesDir ?? resolvedProfileURL()?.deletingLastPathComponent()
    }

    /// A profile is armed for clone/reset/switch to act on — the same
    /// `disabled`-on-flag-run posture the settings verb carries.
    public var armed: Bool { resolvedProfileURL() != nil }

    /// `profile-new` needs only somewhere to mint — a flag-run with an
    /// injected profilesDir may still create.
    public var canCreate: Bool { resolvedProfilesDir() != nil }

    /// The sibling bundles `Switch To` lists — `*.virelaivm` directories
    /// in the profiles dir that are not the armed path. Loadability is
    /// checked at dispatch, not here: the menu stays a cheap projection.
    public var switchTargets: [URL] {
        guard let dir = resolvedProfilesDir() else { return [] }
        let armed = resolvedProfileURL()?.standardizedFileURL
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [URL] = []
        for child in children where child.hasSuffix(".\(VMProfile.bundleExtension)") {
            let url = dir.appendingPathComponent(child, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  url.standardizedFileURL != armed else { continue }
            out.append(url)
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public var canSwitch: Bool { armed && !switchTargets.isEmpty }

    /// M139a (#2779): the "New Window for Profile" leaf set — the sibling
    /// bundles minus any a live session already has open. Without an
    /// injected sessionOpenCheck every sibling lists (the dispatch still
    /// refuses a duplicate by name).
    public var windowTargets: [URL] {
        let open = sessionOpenCheck ?? { _ in false }
        return switchTargets.filter { !open($0.standardizedFileURL) }
    }

    /// The submenu parent's enablement: grey when every sibling is
    /// already open (or none exists) — there is nothing a new window
    /// could boot.
    public var canOpenWindow: Bool { !windowTargets.isEmpty }

    // MARK: The verbs.

    /// `profile-new`: mint `untitled.virelaivm` (collision-free
    /// `untitled-2`, …) in the profiles dir. Never adopts an existing
    /// path — `VMProfile.create` refuses by name.
    @discardableResult
    public func newProfile() -> HostCommandBus.Outcome {
        guard let dir = resolvedProfilesDir() else {
            lastError = "no profiles dir (no --profile/--resume armed)"
            lastAction = "error"
            return .failed
        }
        let name = freeName("untitled", in: dir)
        do {
            let minted = try VMProfile.create(at: dir.appendingPathComponent(
                "\(name).\(VMProfile.bundleExtension)", isDirectory: true), name: name)
            lastMinted = minted.url
            lastError = nil
            lastAction = "created=\(name)"
            emit("host-profiles: created \(minted.url.path)")
            changed()
            return .performed
        } catch {
            return fail("\(error)")
        }
    }

    /// `profile-clone`: the armed bundle clones to `<name>-copy`
    /// (collision-free `-copy-2`, …) — config + share/ ride, the overlay
    /// stays behind (`VMProfile.clone`). A corrupt armed bundle fails by
    /// name instead of cloning garbage.
    @discardableResult
    public func cloneProfile() -> HostCommandBus.Outcome {
        guard let armedURL = resolvedProfileURL(), let dir = resolvedProfilesDir() else {
            lastError = "no profile (--profile or --resume) armed"
            lastAction = "error"
            return .failed
        }
        let source: VMProfile
        do {
            source = try VMProfile.load(from: armedURL)
        } catch {
            return fail("\(error)")
        }
        let name = freeName("\(source.name)-copy", in: dir)
        do {
            let clone = try source.clone(to: dir.appendingPathComponent(
                "\(name).\(VMProfile.bundleExtension)", isDirectory: true), name: name)
            lastMinted = clone.url
            lastError = nil
            lastAction = "clone=\(name)"
            emit("host-profiles: cloned \(armedURL.path) -> \(clone.url.path)")
            changed()
            return .performed
        } catch {
            return fail("\(error)")
        }
    }

    /// `profile-reset-overlay`: delete the armed bundle's overlay.asif —
    /// next boot re-mints over the read-only base. While the VM runs the
    /// confirm seam decides; a decline receipts `disabled` (refused at
    /// dispatch), never a partial reset. Idempotent: an absent overlay is
    /// already-reset, `overlay=absent`.
    @discardableResult
    public func resetOverlay() -> HostCommandBus.Outcome {
        guard let armedURL = resolvedProfileURL() else {
            lastError = "no profile (--profile or --resume) armed"
            lastAction = "error"
            return .failed
        }
        let p: VMProfile
        do {
            p = try VMProfile.load(from: armedURL)
        } catch {
            return fail("\(error)")
        }
        guard confirmed(
            "Reset the boot overlay? The next boot starts from a fresh overlay — the running VM keeps running but its boot-disk writes are discarded.") else { return .disabled }
        do {
            let removed = try p.resetOverlay()
            lastError = nil
            lastAction = removed ? "overlay=reset" : "overlay=absent"
            emit("host-profiles: overlay \(removed ? "reset" : "absent") \(p.overlayURL.path)")
            changed()
            return .performed
        } catch {
            return fail("\(error)")
        }
    }

    /// `profile-switch`: exchange the armed bundle's path with
    /// `switchTarget`'s — the armed path is the launcher's pointer, so
    /// the swap IS the switch (next `just session` boots the target; the
    /// armed bundle survives whole at the target's old path). While the
    /// VM runs, confirm first, then ask the session to stop. Both renames
    /// stage through a temp name: a failure mid-swap leaves each bundle
    /// at a real path, never lost.
    @discardableResult
    public func switchProfile() -> HostCommandBus.Outcome {
        guard let armedURL = resolvedProfileURL() else {
            lastError = "no profile (--profile or --resume) armed"
            lastAction = "error"
            return .failed
        }
        // The target is consumed: a stale selection must never re-switch
        // on a later bare dispatch of the verb.
        let chosen = switchTarget
        switchTarget = nil
        guard let target = chosen?.standardizedFileURL,
              target != armedURL.standardizedFileURL else {
            lastError = nil
            lastAction = "target=unset"
            return .disabled
        }
        let targetProfile: VMProfile
        do {
            targetProfile = try VMProfile.load(from: target)
        } catch {
            return fail("\(error)")
        }
        guard confirmed(
            "Switch this session's profile to '\(targetProfile.name)'? The running VM stops and the next launch boots \(targetProfile.name).") else { return .disabled }
        let fm = FileManager.default
        let staging = armedURL.deletingLastPathComponent()
            .appendingPathComponent(".switch-\(UUID().uuidString).\(VMProfile.bundleExtension)",
                                    isDirectory: true)
        do {
            try fm.moveItem(at: armedURL, to: staging)
            try fm.moveItem(at: target, to: armedURL)
            try fm.moveItem(at: staging, to: target)
        } catch {
            // The middle leg leaving armed empty is the only asymmetric
            // failure — try to put the armed bundle back before reporting.
            if fm.fileExists(atPath: staging.path),
               !fm.fileExists(atPath: armedURL.path) {
                try? fm.moveItem(at: staging, to: armedURL)
            }
            return fail("switch: \(error)")
        }
        lastMinted = nil
        lastError = nil
        lastAction = "switch=\(targetProfile.name)"
        emit("host-profiles: switched \(armedURL.path) -> \(targetProfile.name) (was \(target.lastPathComponent))")
        if vmRunning() { requestStop("profile-switch") }
        changed()
        return .performed
    }

    /// The `host-ui:` receipt tail — the post-action truth a gate reads:
    /// the armed bundle's basename plus the last verb's one-word result.
    public var receiptDetail: String {
        let armedName = resolvedProfileURL()?.deletingPathExtension().lastPathComponent ?? "none"
        var tail = "armed=\(armedName) \(lastAction)"
        if let lastError { tail += " error=\(lastError.components(separatedBy: .newlines).first ?? lastError)" }
        return tail
    }

    // MARK: helpers

    /// The confirm gate: armed only when the VM is running — a stopped
    /// session has nothing to disrupt. A decline leaves a receipt word.
    private func confirmed(_ question: String) -> Bool {
        guard vmRunning() else { return true }
        if confirm(question) { return true }
        lastError = nil
        lastAction = "confirm=declined"
        emit("host-profiles: confirm declined")
        changed()
        return false
    }

    private func fail(_ message: String) -> HostCommandBus.Outcome {
        lastError = message
        lastAction = "error"
        emit("host-profiles: failed \(message)")
        changed()
        return .failed
    }

    /// `base`, `base-2`, `base-3`, … — the first name not present in dir.
    private func freeName(_ base: String, in dir: URL) -> String {
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while fm.fileExists(
            atPath: dir.appendingPathComponent(
                "\(candidate).\(VMProfile.bundleExtension)").path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    private func changed() { onChange?() }
}
