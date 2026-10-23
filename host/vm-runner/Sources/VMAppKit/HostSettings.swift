import Foundation
import VMProfile

/// M128a (#2605, index #2556): the machine settings panel's MODEL — the
/// part `swift test` pins. Settings are profile writes, not flag edits
/// (index thesis 1): the draft below edits `VMProfile.Config` — cpus,
/// memoryMiB, baseImage and the device toggles — and `save()` writes the
/// bundle's config.json through `VMProfile.save()` (write-tmp-then-
/// rename), never into a running VM's live configuration.
///
/// Like the recorder and the AGENTD companion, the model finds its
/// profile without runner globals: the bundle path resolves from the
/// runner's own argv (`--profile`, or `--resume` — a resume IS a
/// profile boot), so a bare `HostCommandBus()` in a `--host-cmd-after`
/// run exercises the identical seam the ⌘, panel does. Tests inject
/// `profileURL`/`arguments` instead of the process's argv.
///
/// Every field a Config carries is consumed when the runner builds the
/// VZ configuration — none hot-plug — so each row's effect marker is
/// `.nextRestart`. The marker is per-row state (not a panel footnote)
/// so a future live-take-effect field slots in without a shape change.
///
/// All access is main-queue (the bus, the menu and the panel all are),
/// so the model takes no lock — the HostCommandBus precedent.
public final class HostSettingsModel {
    /// When a row's edit reaches the VM.
    public enum Effect: String, Sendable {
        /// Applies the next time the machine boots (every Config field —
        /// the VZ configuration is built once at boot).
        case nextRestart
        /// Would apply without a reboot. No Config field qualifies
        /// today; the case exists so the marker vocabulary is honest
        /// when one does.
        case live
    }

    /// One editable row: the stable key, the panel label, and its
    /// effect marker. The view renders this list verbatim.
    public struct SettingRow: Equatable {
        public let key: String
        public let title: String
        public let effect: Effect
    }

    /// The panel's rows in display order. A row's `key` is the Config
    /// member it edits (`devices.*` for the toggles).
    public static let rows: [SettingRow] = [
        SettingRow(key: "cpus", title: "CPUs", effect: .nextRestart),
        SettingRow(key: "memoryMiB", title: "Memory (MiB)", effect: .nextRestart),
        SettingRow(key: "baseImage", title: "Base image", effect: .nextRestart),
        SettingRow(key: "display", title: "Display", effect: .nextRestart),
        SettingRow(key: "input", title: "Input", effect: .nextRestart),
        SettingRow(key: "sound", title: "Sound", effect: .nextRestart),
        SettingRow(key: "netNat", title: "Network (NAT)", effect: .nextRestart),
        SettingRow(key: "vsock", title: "vsock", effect: .nextRestart),
        SettingRow(key: "dataDisk", title: "Data disk (VLFS)", effect: .nextRestart),
        SettingRow(key: "share", title: "Host share", effect: .nextRestart),
    ]

    // MARK: Seams — every external input is injectable.

    /// argv override: nil reads CommandLine.arguments (production). The
    /// profile path resolves from `--profile`/`--resume`.
    public var arguments: [String]?
    /// Direct override beats argv resolution — the test seam.
    public var profileURL: URL?
    /// The marker sink — the bus wires it to its own emit so
    /// `host-settings:` and `host-ui:` lines share one stream a gate
    /// greps (the HostAgentCompanion precedent).
    public var emit: (String) -> Void = {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }
    /// Model → view notification (main queue, the HostInspector rule).
    public var onChange: (() -> Void)?

    // MARK: State — the loaded profile, the draft, the panel.

    /// The loaded profile (nil until `ensureLoaded` succeeds — the panel
    /// loads on open, not at arm, so a corrupt bundle refuses at the
    /// moment of the edit it would have shadowed).
    public private(set) var profile: VMProfile?
    /// Why the last load failed, if it did — the panel renders this
    /// instead of an empty form.
    public private(set) var loadError: String?
    /// Why the last save failed, if it did.
    public private(set) var lastSaveError: String?
    /// Successful saves this run — the `saved=N` receipt detail.
    public private(set) var savedCount = 0
    /// The config the draft last matched (post-load, post-save). Dirty
    /// compares against this — a field returned to its loaded value is
    /// not dirty.
    private var baseline: VMProfile.Config?

    /// Numeric drafts stay TEXT: the panel's validation mirrors the
    /// profile shape check (`cpus in 1...8`, `memoryMiB > 0`) on parse,
    /// so an unparseable or out-of-range entry is representable — and
    /// refusable — instead of being clamped by a formatter.
    public var cpusText = "2" { didSet { changed() } }
    public var memoryText = "256" { didSet { changed() } }
    public var baseImageText = "artifacts/disk.img" { didSet { changed() } }
    public var devices = VMProfile.Devices() { didSet { changed() } }

    /// Open/closed — the `settings` verb toggles it in every mode: the
    /// session's hook also orders the panel window; headless it is still
    /// honest model state a gate reads in the receipt.
    public var isOpen = false { didSet { changed() } }

    public init() {}

    // MARK: M183c (#3173) — host preferences (process-local, live)

    /// The host-preference rows — the panel's second section, rendered
    /// below the Config rows with the `.live` marker: these write the
    /// host store at commit time and never ride `save()` into the
    /// profile (the guest settings table is full — M183a — and a host
    /// pref is not a guest-visible config anyway).
    public static let hostRows: [SettingRow] = [
        SettingRow(key: "idlePause", title: "Pause VM when hidden", effect: .live),
        SettingRow(key: "idlePauseMinutes", title: "Hidden pause after (min)", effect: .live),
    ]

    /// The store's get/set — UserDefaults in production, an in-memory
    /// stub in tests (the model never touches real defaults under
    /// `swift test`).
    public var prefStore: (get: (String) -> Any?, set: (String, Any?) -> Void) = (
        get: { UserDefaults.standard.object(forKey: $0) },
        set: { UserDefaults.standard.set($1, forKey: $0) }
    )

    public static let idlePauseEnabledKey = "idlePause.enabled"
    public static let idlePauseMinutesKey = "idlePause.minutes"
    /// The card's "say 5" default.
    public static let defaultIdlePauseMinutes = 5
    /// The accepted minutes range — a clamp the panel field shares.
    public static let idlePauseMinutesRange = 1...120

    /// The idle-pause policy toggle — persisted host-side, read live by
    /// the machine model's `idlePauseEnabled` seam. Default ON.
    public var idlePauseEnabled: Bool {
        get { (prefStore.get(Self.idlePauseEnabledKey) as? Bool) ?? true }
        set { prefStore.set(Self.idlePauseEnabledKey, newValue); changed() }
    }

    /// The occluded stretch before the pause fires, in minutes.
    public var idlePauseMinutes: Int {
        get {
            (prefStore.get(Self.idlePauseMinutesKey) as? Int)
                ?? Self.defaultIdlePauseMinutes
        }
        set { prefStore.set(Self.idlePauseMinutesKey, newValue); changed() }
    }

    /// The minutes field's draft — a text field like cpusText, so an
    /// unparseable entry is representable and refusable instead of
    /// clamped by a formatter. A valid commit writes through to the
    /// store immediately (the row is `.live`).
    public var idlePauseMinutesText: String = String(HostSettingsModel.defaultIdlePauseMinutes) {
        didSet {
            let t = idlePauseMinutesText.trimmingCharacters(in: .whitespaces)
            if let m = Int(t), Self.idlePauseMinutesRange.contains(m) {
                idlePauseMinutes = m
                idlePauseMinutesError = nil
            } else {
                idlePauseMinutesError =
                    "hidden pause minutes must be \(Self.idlePauseMinutesRange.lowerBound)–\(Self.idlePauseMinutesRange.upperBound)"
            }
            changed()
        }
    }
    /// Why the minutes draft is refused, if it is — the panel's error
    /// line carries it.
    public private(set) var idlePauseMinutesError: String?

    /// Sync the minutes draft to the stored value — the panel's revert/
    /// reload edge for the host rows.
    public func reloadHostPrefs() {
        idlePauseMinutesText = String(idlePauseMinutes)
    }

    // MARK: Arming — argv resolution and posture.

    /// The bundle path from argv: `--profile <path>`, else `--resume
    /// <path>` (a resume boots the named bundle).
    public static func profileURL(arguments: [String]) -> URL? {
        for flag in ["--profile", "--resume"] {
            if let i = arguments.firstIndex(of: flag), i + 1 < arguments.count {
                return URL(fileURLWithPath: arguments[i + 1])
            }
        }
        return nil
    }

    public func resolvedProfileURL() -> URL? {
        profileURL ?? Self.profileURL(arguments: arguments ?? CommandLine.arguments)
    }

    /// A profile exists to edit. When absent the `settings` verb
    /// receipts `disabled` and the menu item greys — there is no
    /// bundle for a flag-run's edits to land in.
    public var armed: Bool { resolvedProfileURL() != nil }

    /// Load the resolved bundle. The panel LOADS (never mints): ⌘, is
    /// an edit surface, so openOrCreate's minting would surprise. On
    /// success the draft resets to the loaded config.
    @discardableResult
    public func ensureLoaded() -> Bool {
        if profile != nil { return true }
        guard let url = resolvedProfileURL() else {
            loadError = "no profile (--profile or --resume) armed"
            return false
        }
        do {
            let p = try VMProfile.load(from: url)
            profile = p
            baseline = p.config
            cpusText = String(p.config.cpus)
            memoryText = String(p.config.memoryMiB)
            baseImageText = p.config.baseImage
            devices = p.config.devices
            loadError = nil
            changed()
            return true
        } catch {
            loadError = "\(error)"
            return false
        }
    }

    // MARK: Draft — validation mirroring the profile shape check.

    /// The draft as a Config, or nil while a numeric field is not a
    /// number. Unedited Config members (updatePubkey, anything a later
    /// format adds) carry over from the baseline — a save never drops
    /// what the panel does not show.
    public var validatedConfig: VMProfile.Config? {
        let cpusText = self.cpusText.trimmingCharacters(in: .whitespaces)
        let memoryText = self.memoryText.trimmingCharacters(in: .whitespaces)
        guard let cpus = Int(cpusText), let memory = Int(memoryText) else { return nil }
        var config = baseline ?? VMProfile.Config()
        config.cpus = cpus
        config.memoryMiB = memory
        config.baseImage = baseImageText
        config.devices = devices
        return config
    }

    /// The shape-check mirror — VMProfile.load's own rule (`cpus in
    /// 1...8`, `memoryMiB > 0`, non-empty baseImage) expressed per field
    /// so the panel can point at the offending row. An entry that is not
    /// a number is reported here too (load would refuse the same file).
    public var errors: [String] {
        var out: [String] = []
        let cpusText = self.cpusText.trimmingCharacters(in: .whitespaces)
        if let cpus = Int(cpusText) {
            if !(1...8).contains(cpus) { out.append("cpus must be in 1...8 (the runner's --cpus bound)") }
        } else {
            out.append("cpus must be a number")
        }
        let memoryText = self.memoryText.trimmingCharacters(in: .whitespaces)
        if let memory = Int(memoryText) {
            if memory <= 0 { out.append("memoryMiB must be > 0") }
        } else {
            out.append("memoryMiB must be a number")
        }
        if baseImageText.isEmpty { out.append("baseImage must not be empty") }
        return out
    }

    /// The draft differs from the last loaded/saved config. Compared on
    /// the field text so an unparseable edit still counts as unsaved
    /// work (revert is the honest way back).
    public var dirty: Bool {
        guard let baseline else { return false }
        return cpusText != String(baseline.cpus)
            || memoryText != String(baseline.memoryMiB)
            || baseImageText != baseline.baseImage
            || devices != baseline.devices
    }

    /// Save is armed when a profile is loaded, the draft passes the
    /// shape-check mirror, and there is something to write.
    public var canSave: Bool { profile != nil && errors.isEmpty && dirty }

    /// Write the draft into the bundle's config.json (atomic — the
    /// VMProfile.save write-tmp-then-rename). False when the draft is
    /// invalid, nothing is loaded, or the write fails; the failure
    /// reason lands in `lastSaveError`/`loadError`.
    @discardableResult
    public func save() -> Bool {
        guard var p = profile else { loadError = loadError ?? "no profile loaded"; return false }
        guard errors.isEmpty, let config = validatedConfig else { return false }
        p.config = config
        do {
            try p.save()
        } catch {
            lastSaveError = "\(error)"
            emit("host-settings: save failed \(error)")
            changed()
            return false
        }
        profile = p
        baseline = config
        savedCount += 1
        lastSaveError = nil
        emit("host-settings: saved \(p.url.path) cpus=\(config.cpus) memoryMiB=\(config.memoryMiB)")
        changed()
        return true
    }

    /// Drop the draft back to the last loaded/saved config.
    public func revert() {
        guard let baseline else { return }
        cpusText = String(baseline.cpus)
        memoryText = String(baseline.memoryMiB)
        baseImageText = baseline.baseImage
        devices = baseline.devices
        changed()
    }

    // MARK: The verb + receipts.

    /// The `settings` verb's action: toggling the panel is the dispatch.
    /// Opening loads the profile first — a bundle that will not load
    /// receipts `failed` with `loadError` set rather than presenting an
    /// editor over nothing.
    @discardableResult
    public func toggle() -> HostCommandBus.Outcome {
        if isOpen {
            isOpen = false
            return .performed
        }
        guard ensureLoaded() else { return .failed }
        isOpen = true
        return .performed
    }

    /// The `settings` receipt tail — the post-action truth a gate reads
    /// (the `capture=on|off` precedent): open state plus whether unsaved
    /// edits exist.
    public var receiptDetail: String {
        "open=\(isOpen ? 1 : 0) dirty=\(dirty ? 1 : 0) saved=\(savedCount)"
    }

    private func changed() { onChange?() }
}
