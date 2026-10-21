// VMProfile — M115c (issue #2462): the `.virelaivm` profile bundle. Pure
// Foundation, zero Virtualization imports, so `swift test` pins the
// create/load/save/refusal contract on any host — the runner only consumes
// `openOrCreate`, the member URLs, and `config`.
//
// A `.virelaivm` bundle is a directory a machine owns for its whole life:
//
//     <name>.virelaivm/
//         manifest.json     the checked-on-load manifest: format tag, the
//                           stable identity key, and the member map
//         config.json       the machine shape: cpus, ram, base image, devices
//         efi-vars.bin      the EFI variable store (VZ creates it at 1st boot)
//         overlay.asif      the PERSISTENT boot overlay over the base image
//                           (opened read-write on later boots — never the
//                           throwaway tmp layer --overlay-base mints alone)
//         vlfs.img          the guest's VLFS data disk (--data-disk member)
//         machine-id.bin    the VZGenericMachineIdentifier data — one machine
//                           keeps ONE identifier across processes, which is
//                           also what pins the bundle's TCC identity
//         saved-state/      reserved for the VZ saved-state dir (M115d)
//         share/            the host file-channel share (--cvc-file member)
//
// The manifest is the format's gate: load requires it, requires format
// "virelaivm/1", and requires every member to be a bundle-relative name —
// a missing or corrupt manifest refuses BY NAME, and a member that escapes
// the bundle ("../…") refuses the same way.
import Foundation

public struct VMProfile: Equatable {
    /// The format tag a manifest must carry. Bump when the member map or
    /// the config schema changes incompatibly.
    public static let formatID = "virelaivm/1"
    public static let bundleExtension = "virelaivm"
    public static let manifestName = "manifest.json"

    /// Bundle-relative member names. Fixed by the format; stored in the
    /// manifest so the bundle is self-describing and a later format can
    /// move a member without ambiguity.
    public struct Members: Codable, Equatable {
        public var config = "config.json"
        public var efiVars = "efi-vars.bin"
        public var overlay = "overlay.asif"
        public var vlfs = "vlfs.img"
        public var machineIdentifier = "machine-id.bin"
        public var savedState = "saved-state"
        public var share = "share"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            config = try c.decodeIfPresent(String.self, forKey: .config) ?? "config.json"
            efiVars = try c.decodeIfPresent(String.self, forKey: .efiVars) ?? "efi-vars.bin"
            overlay = try c.decodeIfPresent(String.self, forKey: .overlay) ?? "overlay.asif"
            vlfs = try c.decodeIfPresent(String.self, forKey: .vlfs) ?? "vlfs.img"
            machineIdentifier = try c.decodeIfPresent(String.self, forKey: .machineIdentifier) ?? "machine-id.bin"
            savedState = try c.decodeIfPresent(String.self, forKey: .savedState) ?? "saved-state"
            share = try c.decodeIfPresent(String.self, forKey: .share) ?? "share"
        }

        /// Every member name the format requires, for load-time validation.
        public var all: [String] {
            [config, efiVars, overlay, vlfs, machineIdentifier, savedState, share]
        }
    }

    /// Optional devices the profile arms when it boots. All default OFF so
    /// a profile never widens the VM shape silently — the card's bundle
    /// members (share, vlfs) are the two that default ON.
    public struct Devices: Codable, Equatable {
        public var display = false
        public var input = false
        public var sound = false
        public var netNat = false
        public var vsock = false
        public var dataDisk = true
        public var share = true

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            display = try c.decodeIfPresent(Bool.self, forKey: .display) ?? false
            input = try c.decodeIfPresent(Bool.self, forKey: .input) ?? false
            sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? false
            netNat = try c.decodeIfPresent(Bool.self, forKey: .netNat) ?? false
            vsock = try c.decodeIfPresent(Bool.self, forKey: .vsock) ?? false
            dataDisk = try c.decodeIfPresent(Bool.self, forKey: .dataDisk) ?? true
            share = try c.decodeIfPresent(Bool.self, forKey: .share) ?? true
        }
    }

    /// config.json — the machine shape the bundle pins.
    public struct Config: Codable, Equatable {
        /// M157a (#2934): the window-close policy — `stop` ends the run;
        /// `suspend` runs the M115d save path into saved-state/ so
        /// `--resume` continues the machine. Absent means stop; a
        /// foreign word refuses the config load as corrupt (the
        /// manifest's own naming rule).
        public enum CloseAction: String, Codable, Equatable {
            case stop
            case suspend
        }

        /// Same bound the runner's --cpus flag enforces.
        public var cpus = 2
        /// M129a (#2610): 512 MiB is the compiled schema default — a
        /// config.json written before the bump keeps its stored value
        /// (decodeIfPresent honors the field it carries).
        public var memoryMiB = 512
        /// The boot base image the persistent overlay stacks on. Stored as
        /// given (typically absolute); a relative path resolves against the
        /// runner's working directory.
        public var baseImage = "artifacts/disk.img"
        /// M115f (#2465): the pinned Ed25519 public key (64 lowercase hex)
        /// that may sign this machine's staged OS updates. Bundle-side,
        /// guest-unreachable — the share the guest writes cannot move the
        /// pin. Empty = no key configured; --apply-update then needs
        /// --update-key.
        public var updatePubkey: String?
        /// M157a (#2934): the window-close policy — absent means stop.
        public var closeAction = CloseAction.stop
        public var devices = Devices()

        public init() {}

        public init(cpus: Int, memoryMiB: Int, baseImage: String, devices: Devices = Devices()) {
            self.cpus = cpus
            self.memoryMiB = memoryMiB
            self.baseImage = baseImage
            self.devices = devices
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 2
            memoryMiB = try c.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? 512
            baseImage = try c.decodeIfPresent(String.self, forKey: .baseImage) ?? "artifacts/disk.img"
            updatePubkey = try c.decodeIfPresent(String.self, forKey: .updatePubkey)
            closeAction = try c.decodeIfPresent(CloseAction.self, forKey: .closeAction) ?? .stop
            devices = try c.decodeIfPresent(Devices.self, forKey: .devices) ?? Devices()
        }
    }

    /// The bundle directory (its .virelaivm path).
    public let url: URL
    /// The stable bundle-idish key. session.sh stamps it into the session
    /// app's CFBundleIdentifier, so macOS TCC sees ONE responsible process
    /// across sessions (sound/mic/notify grants stop re-prompting).
    public var identity: String
    /// The profile's display name (defaults to the bundle's filename).
    public var name: String
    public var members: Members
    public var config: Config
    /// True only on the `openOrCreate`/`create` call that minted the bundle.
    public let created: Bool

    private init(url: URL, identity: String, name: String, members: Members, config: Config, created: Bool) {
        self.url = url
        self.identity = identity
        self.name = name
        self.members = members
        self.config = config
        self.created = created
    }

    public enum ProfileError: Error, Equatable, CustomStringConvertible {
        /// The path exists and is not a directory.
        case notRegularFile(String)
        /// The path is a directory but carries no manifest.
        case missingManifest(String)
        /// The manifest is not decodable profile JSON, or a member name is
        /// not a safe bundle-relative name.
        case corruptManifest(String)
        /// The manifest decoded but names a format this build does not read.
        case unsupportedFormat(String)
        /// The manifest's config member is absent or not decodable, or a
        /// value fails the shape check (cpus in 1...8, memoryMiB > 0).
        case corruptConfig(String)
        /// setMachineIdentifier got data that is not one uuid_t.
        case invalidMachineIdentifier(Int)
        /// A write or mkdir failed (the underlying reason is carried).
        case couldNotCreate(String)
        case couldNotSave(String)
        /// A member removal failed (the underlying reason is carried).
        case couldNotRemove(String)

        public var description: String {
            switch self {
            case .notRegularFile(let p):
                return "'\(p)' exists and is not a .virelaivm bundle directory"
            case .missingManifest(let p):
                return "no profile manifest at '\(p)' — not a .virelaivm bundle (or the manifest was removed)"
            case .corruptManifest(let p):
                return "corrupt manifest: '\(p)' is not a readable virelaivm/1 manifest"
            case .unsupportedFormat(let s):
                return "unsupported profile format '\(s)' (this build reads \(VMProfile.formatID))"
            case .corruptConfig(let p):
                return "corrupt config: '\(p)' is not a readable profile config"
            case .invalidMachineIdentifier(let n):
                return "machine identifier must be a non-empty byte blob, got \(n) bytes"
            case .couldNotCreate(let s):
                return "could not create profile: \(s)"
            case .couldNotSave(let s):
                return "could not save profile: \(s)"
            case .couldNotRemove(let s):
                return "could not remove profile member: \(s)"
            }
        }
    }

    // MARK: - member URLs

    public var manifestURL: URL { url.appendingPathComponent(Self.manifestName) }
    public var configURL: URL { url.appendingPathComponent(members.config) }
    public var efiVarsURL: URL { url.appendingPathComponent(members.efiVars) }
    public var overlayURL: URL { url.appendingPathComponent(members.overlay) }
    public var vlfsURL: URL { url.appendingPathComponent(members.vlfs) }
    public var machineIdentifierURL: URL { url.appendingPathComponent(members.machineIdentifier) }
    public var savedStateURL: URL { url.appendingPathComponent(members.savedState) }
    public var shareURL: URL { url.appendingPathComponent(members.share) }

    // MARK: - create / load

    /// Mint a fresh bundle at `url`. The path must not exist yet — adopting
    /// an existing directory is never silent; point `--profile` at it and let
    /// `openOrCreate` load (or refuse) it instead.
    @discardableResult
    public static func create(at url: URL, name: String? = nil, identity: String? = nil,
                              config: Config = Config()) throws -> VMProfile {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            throw isDir.boolValue
                ? ProfileError.missingManifest(url.path)
                : ProfileError.notRegularFile(url.path)
        }
        let profileName = name ?? url.deletingPathExtension().lastPathComponent
        let profile = VMProfile(
            url: url,
            identity: identity ?? Self.defaultIdentity(for: profileName),
            name: profileName,
            members: Members(),
            config: config,
            created: true)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try fm.createDirectory(at: profile.shareURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: profile.savedStateURL, withIntermediateDirectories: true)
            // machine-id.bin is deliberately absent until first boot: the
            // identifier's byte shape is VZ's (observed 2026-10-18: a 70-byte
            // dataRepresentation, NOT a uuid_t), so the runner mints it via
            // VZGenericPlatformConfiguration and persists it here. One
            // machine keeps ONE identifier for its whole life.
            try profile.save()
        } catch let e as ProfileError {
            throw e
        } catch {
            throw ProfileError.couldNotCreate("\(error)")
        }
        return profile
    }

    /// Load an existing bundle. The manifest gate refuses by name: absent
    /// manifest, undecodable JSON, a foreign format tag, a member name that
    /// is not bundle-relative, or an undecodable config each get their own
    /// error carrying the offending file.
    public static func load(from url: URL) throws -> VMProfile {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ProfileError.missingManifest(url.path)
        }
        guard isDir.boolValue else { throw ProfileError.notRegularFile(url.path) }

        let manifestURL = url.appendingPathComponent(Self.manifestName)
        guard let manifestData = fm.contents(atPath: manifestURL.path) else {
            throw ProfileError.missingManifest(manifestURL.path)
        }
        struct ManifestFile: Decodable {
            var format: String
            var identity: String
            var name: String
            var members: Members
        }
        let manifest: ManifestFile
        do {
            manifest = try JSONDecoder().decode(ManifestFile.self, from: manifestData)
        } catch {
            throw ProfileError.corruptManifest(manifestURL.path)
        }
        guard manifest.format == Self.formatID else {
            throw ProfileError.unsupportedFormat(manifest.format)
        }
        guard !manifest.identity.isEmpty, !manifest.name.isEmpty,
              manifest.members.all.allSatisfy(Self.isSafeMember) else {
            throw ProfileError.corruptManifest(manifestURL.path)
        }

        var profile = VMProfile(url: url, identity: manifest.identity, name: manifest.name,
                                members: manifest.members, config: Config(), created: false)
        let configURL = profile.configURL
        guard let configData = fm.contents(atPath: configURL.path) else {
            throw ProfileError.corruptConfig(configURL.path)
        }
        do {
            profile.config = try JSONDecoder().decode(Config.self, from: configData)
        } catch {
            throw ProfileError.corruptConfig(configURL.path)
        }
        guard (1...8).contains(profile.config.cpus), profile.config.memoryMiB > 0,
              !profile.config.baseImage.isEmpty else {
            throw ProfileError.corruptConfig(configURL.path)
        }
        return profile
    }

    /// The runner's `--profile` semantics: an absent path is minted, an
    /// existing bundle is loaded, anything else refuses by name.
    @discardableResult
    public static func openOrCreate(at url: URL, name: String? = nil, identity: String? = nil,
                                    config: Config = Config()) throws -> VMProfile {
        if FileManager.default.fileExists(atPath: url.path) {
            return try load(from: url)
        }
        return try create(at: url, name: name, identity: identity, config: config)
    }

    /// Re-write manifest.json + config.json. Each write is write-tmp-then-
    /// rename (Foundation .atomic): a failed save leaves the previous file
    /// byte-identical rather than truncated.
    public func save() throws {
        struct ManifestFile: Encodable {
            var format: String
            var identity: String
            var name: String
            var members: Members
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let manifest = ManifestFile(format: Self.formatID, identity: identity,
                                        name: name, members: members)
            try Self.writeAtomically(encoder.encode(manifest), to: manifestURL)
            try Self.writeAtomically(encoder.encode(config), to: configURL)
        } catch {
            throw ProfileError.couldNotSave("\(error)")
        }
    }

    // MARK: - M128b (#2606): the profile-manager surgery — clone + overlay
    // reset live at the format layer so the bundle rules (member names,
    // manifest, fresh identity) apply identically from the menu verb and
    // any future caller.

    /// Mint a sibling bundle carrying THIS profile's config.json and a
    /// recursive copy of its share/ — and nothing else. The clone is a NEW
    /// machine: fresh identity (derived from `name`), fresh efi-vars/
    /// machine-id/saved-state, NO overlay.asif (the attach point re-mints
    /// it over the base on first boot) and NO vlfs.img (a clean test VM,
    /// not a disk-image fork). `url` must not exist — same refusal as
    /// `create`.
    @discardableResult
    public func clone(to url: URL, name: String? = nil) throws -> VMProfile {
        let clone = try Self.create(at: url, name: name, config: config)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: shareURL.path, isDirectory: &isDir), isDir.boolValue {
            do {
                for child in try fm.contentsOfDirectory(atPath: shareURL.path) {
                    try fm.copyItem(at: shareURL.appendingPathComponent(child),
                                    to: clone.shareURL.appendingPathComponent(child))
                }
            } catch {
                // A half-cloned bundle must not survive to be adopted later —
                // remove it and let the caller's retry mint cleanly.
                try? fm.removeItem(at: url)
                throw ProfileError.couldNotCreate("clone: share copy failed: \(error)")
            }
        }
        return clone
    }

    /// Remove the persistent boot overlay so the next boot re-mints a fresh
    /// ASIF layer over the read-only base (the attach point mints when
    /// absent — the same discard --apply-update performs). Idempotent:
    /// returns whether an overlay existed to remove. The wedged-boot safety
    /// net — no `rm -rf`, the member URL is the format's own.
    @discardableResult
    public func resetOverlay() throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: overlayURL.path) else { return false }
        do {
            try fm.removeItem(at: overlayURL)
        } catch {
            throw ProfileError.couldNotRemove("reset-overlay: \(error)")
        }
        return true
    }

    // MARK: - machine identifier

    /// The persisted machine identifier bytes, or nil when absent/empty —
    /// the caller (which owns Virtualization) mints a fresh one and hands
    /// it to `setMachineIdentifier`. The bytes are opaque here: VZ decides
    /// the shape.
    public func machineIdentifierData() -> Data? {
        guard let data = FileManager.default.contents(atPath: machineIdentifierURL.path),
              !data.isEmpty else { return nil }
        return data
    }

    public func setMachineIdentifier(_ data: Data) throws {
        guard !data.isEmpty else {
            throw ProfileError.invalidMachineIdentifier(data.count)
        }
        do {
            try Self.writeAtomically(data, to: machineIdentifierURL)
        } catch {
            throw ProfileError.couldNotSave("\(error)")
        }
    }

    // MARK: - helpers

    /// A member name must be a single bundle-relative path component —
    /// anything else could redirect a member outside the bundle on load.
    static func isSafeMember(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
    }

    /// The default identity key: bundle-idish, derived from the profile
    /// name, stable for the bundle's whole life once minted.
    public static func defaultIdentity(for name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var slug = name.lowercased().map { allowed.contains($0) ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "org.virelaios.vm.\(slug.isEmpty ? "profile" : slug)"
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
