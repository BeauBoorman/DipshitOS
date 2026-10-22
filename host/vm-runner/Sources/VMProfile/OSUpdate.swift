// OSUpdate — M115f (issue #2465): the apply half of the guest-staged OS
// self-update. The guest (GOUPD.ELF) writes a signed update set to
// <share>/UPDATE/:
//
//     OS.IMG            the in-guest-assembled GPT+FAT32 boot image
//     KERNEL.BIN        the staged kernel (also inside the image)
//     BOOTAA64.EFI      the staged loader (also inside the image)
//     UPDATE.MF         the manifest — one row per artifact
//     UPDATE.SIG        64-byte Ed25519 signature over UPDATE.MF's bytes
//
// The runner's `--apply-update` verifies the signature against the pinned
// key, hash-checks every manifest-named file, then swaps the base image.
// The staged set sits in the share the guest writes, so the image is
// first copied to a host-side <base>.next and THAT copy is hash-checked
// — an in-place hash cannot bind the bytes a second read installs. Then
// the current base moves to <base>.prev, the verified copy moves in, and
// a profile's persistent overlay.asif is discarded — its stale sectors
// belong to the old base and must not shadow the new one. A refused set
// is left in place (evidence, and a later --apply-update keeps failing
// closed on it).
//
// `--rollback-update` swaps <base>.prev back — the same one-step shape
// STORE uses for apps (M101d).
//
// Pure Foundation + CryptoKit, zero Virtualization imports, so
// `swift test` pins the manifest grammar, the refusal names, and the
// swap/rollback ordering without a VM.
import CryptoKit
import Foundation

public enum OSUpdate {

    /// The staged-set directory the guest writes, relative to the share.
    public static let stagedDirName = "UPDATE"
    /// An applied set is renamed here — the record survives, and a repeat
    /// --apply-update sees "none staged".
    public static let appliedDirName = "UPDATE.APPLIED"
    public static let manifestName = "UPDATE.MF"
    public static let signatureName = "UPDATE.SIG"
    public static let imageName = "OS.IMG"

    /// UPDATE.MF is a small signed document; a hostile share staging a
    /// memory soak is refused at the bound.
    public static let maxManifestBytes = 64 * 1024

    public struct Member: Equatable {
        public var name: String     // file inside UPDATE/
        public var kind: Kind       // image | member
        public var sha256: String   // 64 lowercase hex
        public var bytes: UInt64
        public var version: String? // image row only
        public var esp: String?     // member rows: the image-internal path
    }

    public enum Kind: String, Equatable {
        case image
        case member
    }

    public struct Manifest: Equatable {
        public var members: [Member]
        /// The image row's version= (a "-" label is honest "unlabeled").
        public var version: String {
            members.first(where: { $0.kind == .image })?.version ?? "-"
        }
        public var image: Member? { members.first(where: { $0.kind == .image }) }
    }

    public enum UpdateError: Error, Equatable, CustomStringConvertible {
        /// UPDATE/ exists but UPDATE.MF is absent.
        case manifestMissing
        /// UPDATE.MF is over the byte bound, unparseable, or fails the
        /// grammar (header, row shape, sha/bytes fields, dup/absent
        /// image row, missing member rows, unsafe file name).
        case manifestMalformed(String)
        /// UPDATE.SIG is absent or not 64 bytes.
        case sigMissing
        /// The signature does not verify over UPDATE.MF's bytes.
        case sigInvalid
        /// A manifest-named file is absent from UPDATE/.
        case memberMissing(String)
        /// A manifest-named file's size or sha256 disagrees with the row.
        case hashMismatch(String)
        /// --apply-update had no resolvable Ed25519 public key.
        case noKey
        /// There is no base image to swap (no --overlay-base/--profile base).
        case noBase
        /// --rollback-update found no <base>.prev.
        case noRollbackTarget
        /// A filesystem step failed (detail carries the underlying error).
        case io(String)

        public var description: String {
            switch self {
            case .manifestMissing:
                return "manifest_missing (UPDATE/ exists but UPDATE.MF does not)"
            case .manifestMalformed(let d):
                return "manifest_malformed (\(d))"
            case .sigMissing:
                return "sig_missing (UPDATE.SIG absent or not 64 bytes)"
            case .sigInvalid:
                return "sig_invalid (UPDATE.SIG does not verify UPDATE.MF)"
            case .memberMissing(let n):
                return "member_missing (\(n))"
            case .hashMismatch(let n):
                return "hash_mismatch (\(n))"
            case .noKey:
                return "no_key (--update-key <64-hex> or profile config updatePubkey required)"
            case .noBase:
                return "no_base (no base image to update — needs --overlay-base or --profile)"
            case .noRollbackTarget:
                return "rollback_none (no .prev to restore)"
            case .io(let d):
                return "io (\(d))"
            }
        }
    }

    // MARK: - manifest parse

    /// Parse UPDATE.MF bytes. Grammar, mirroring the guest writer
    /// (user/go/goupd/stage.go):
    ///
    ///     #v1 os-update
    ///     OS.IMG        kind=image   sha256=<64hex> bytes=<n> version=<v>
    ///     KERNEL.BIN    kind=member  sha256=<64hex> bytes=<n> esp=KERNEL.BIN
    ///     BOOTAA64.EFI  kind=member  sha256=<64hex> bytes=<n> esp=EFI/BOOT/BOOTAA64.EFI
    public static func parseManifest(_ data: Data) throws -> Manifest {
        if data.count > maxManifestBytes {
            throw UpdateError.manifestMalformed("over \(maxManifestBytes) bytes")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.manifestMalformed("not UTF-8")
        }
        var sawHeader = false
        var members: [Member] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line == "#v1 os-update" { sawHeader = true }
                continue
            }
            if !sawHeader {
                throw UpdateError.manifestMalformed("rows before the #v1 os-update header")
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard let name = fields.first, fields.count >= 2 else {
                throw UpdateError.manifestMalformed("row lacks name/kind")
            }
            try checkMemberName(name)
            var m = Member(name: name, kind: .member, sha256: "", bytes: 0)
            for kv in fields.dropFirst() {
                let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    throw UpdateError.manifestMalformed("\(name): bad field \(kv)")
                }
                switch parts[0] {
                case "kind":
                    guard let k = Kind(rawValue: parts[1]) else {
                        throw UpdateError.manifestMalformed("\(name): kind=\(parts[1])")
                    }
                    m.kind = k
                case "sha256":
                    guard parts[1].count == 64,
                          parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                        throw UpdateError.manifestMalformed("\(name): sha256 not 64 lowercase hex")
                    }
                    m.sha256 = parts[1]
                case "bytes":
                    guard let n = UInt64(parts[1]) else {
                        throw UpdateError.manifestMalformed("\(name): bad bytes=\(parts[1])")
                    }
                    m.bytes = n
                case "version":
                    m.version = parts[1]
                case "esp":
                    m.esp = parts[1]
                default:
                    // Additive: unknown signed fields are ignored (the
                    // signature still covers them).
                    continue
                }
            }
            guard !m.sha256.isEmpty else {
                throw UpdateError.manifestMalformed("\(name): no sha256")
            }
            members.append(m)
        }
        guard sawHeader else {
            throw UpdateError.manifestMalformed("no #v1 os-update header")
        }
        let images = members.filter { $0.kind == .image }
        guard images.count == 1, images[0].name == imageName else {
            throw UpdateError.manifestMalformed("expected exactly one kind=image row named \(imageName)")
        }
        for required in ["KERNEL.BIN", "BOOTAA64.EFI"] {
            guard members.contains(where: { $0.kind == .member && $0.name == required }) else {
                throw UpdateError.manifestMalformed("no kind=member row for \(required)")
            }
        }
        return Manifest(members: members)
    }

    /// A manifest names files inside UPDATE/ only — no separators, no
    /// traversal, no dot names.
    private static func checkMemberName(_ name: String) throws {
        if name.isEmpty || name.count > 64 || name.hasPrefix(".") ||
            name.contains("/") || name.contains("\\") {
            throw UpdateError.manifestMalformed("unsafe member name \(name)")
        }
    }

    // MARK: - verify

    /// Verify a staged UPDATE dir end to end: manifest parses, signature
    /// verifies over the manifest's bytes, and every manifest-named file
    /// exists with the recorded size + sha256.
    @discardableResult
    public static func verify(updateDir: URL, publicKey: Data) throws -> Manifest {
        let fm = FileManager.default
        let mfURL = updateDir.appendingPathComponent(manifestName)
        guard let mfData = try? Data(contentsOf: mfURL) else {
            throw UpdateError.manifestMissing
        }
        let manifest = try parseManifest(mfData)

        let sigURL = updateDir.appendingPathComponent(signatureName)
        guard let sig = try? Data(contentsOf: sigURL), sig.count == 64 else {
            throw UpdateError.sigMissing
        }
        guard publicKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(sig, for: mfData) else {
            throw UpdateError.sigInvalid
        }

        for m in manifest.members {
            let f = updateDir.appendingPathComponent(m.name)
            guard fm.fileExists(atPath: f.path) else {
                throw UpdateError.memberMissing(m.name)
            }
            let actual = try sha256File(f)
            if UInt64(actual.count) != m.bytes || actual.hex != m.sha256 {
                throw UpdateError.hashMismatch(m.name)
            }
        }
        return manifest
    }

    // MARK: - apply / rollback

    /// The staged-set dir under a share, or nil when nothing is staged.
    public static func stagedDir(shareDir: URL) -> URL? {
        let dir = shareDir.appendingPathComponent(stagedDirName)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
            && isDir.boolValue ? dir : nil
    }

    /// Verify + swap: the staged OS.IMG becomes the base image; the old
    /// base moves to <base>.prev and a profile's persistent overlay.asif
    /// is discarded. The image is copied out of the guest-writable share
    /// before it is trusted: the private <base>.next copy is the file
    /// hash-checked and swapped in. Returns the verified manifest.
    @discardableResult
    public static func apply(updateDir: URL, baseImage: URL, publicKey: Data,
                             overlay: URL? = nil) throws -> Manifest {
        let manifest = try verify(updateDir: updateDir, publicKey: publicKey)
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseImage.path) else {
            throw UpdateError.noBase
        }
        guard let image = manifest.image else {
            throw UpdateError.manifestMalformed("no kind=image row")
        }
        let next = sibling(baseImage, ".next")
        let prev = sibling(baseImage, ".prev")

        // Stage the new base beside the old (same directory => the rename
        // is atomic on the same volume), fsync'd before the swap. The
        // share is guest-writable, so the staged file's in-place hash
        // above cannot bind the bytes this second read consumes — the
        // guest can swap UPDATE/OS.IMG in between. Hash the private copy
        // instead; only bytes matching the signed row may be installed.
        do {
            if fm.fileExists(atPath: next.path) { try fm.removeItem(at: next) }
            try fm.copyItem(at: updateDir.appendingPathComponent(imageName), to: next)
            let copied = try sha256File(next)
            guard UInt64(copied.count) == image.bytes, copied.hex == image.sha256 else {
                try? fm.removeItem(at: next)
                throw UpdateError.hashMismatch(image.name)
            }
            let fh = try FileHandle(forWritingTo: next)
            try fh.synchronize()
            try fh.close()
            if fm.fileExists(atPath: prev.path) { try fm.removeItem(at: prev) }
            try fm.moveItem(at: baseImage, to: prev)
            try fm.moveItem(at: next, to: baseImage)
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.io("\(error.localizedDescription)")
        }

        // A profile's persistent overlay belongs to the old base — its
        // stale ESP sectors must not shadow the new image. The next boot
        // mints a fresh layer.
        if let overlay, fm.fileExists(atPath: overlay.path) {
            try? fm.removeItem(at: overlay)
        }
        // Mark the set consumed; a rename failure leaves it staged — a
        // repeat apply is idempotent, so warn-but-continue.
        try? fm.moveItem(at: updateDir,
                         to: updateDir.deletingLastPathComponent()
                                .appendingPathComponent(appliedDirName))
        return manifest
    }

    /// One-step rollback: <base>.prev swaps back in. Returns the sha256
    /// of the restored base image.
    @discardableResult
    public static func rollback(baseImage: URL, overlay: URL? = nil) throws -> String {
        let fm = FileManager.default
        let prev = sibling(baseImage, ".prev")
        guard fm.fileExists(atPath: prev.path) else {
            throw UpdateError.noRollbackTarget
        }
        let cur = sibling(baseImage, ".cur")
        do {
            if fm.fileExists(atPath: baseImage.path) {
                if fm.fileExists(atPath: cur.path) { try fm.removeItem(at: cur) }
                try fm.moveItem(at: baseImage, to: cur)
            }
            try fm.moveItem(at: prev, to: baseImage)
            if fm.fileExists(atPath: cur.path) {
                try fm.moveItem(at: cur, to: prev)
            }
        } catch {
            throw UpdateError.io("\(error.localizedDescription)")
        }
        if let overlay, fm.fileExists(atPath: overlay.path) {
            try? fm.removeItem(at: overlay)
        }
        return try sha256File(baseImage).hex
    }

    // MARK: - helpers

    private static func sibling(_ url: URL, _ suffix: String) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + suffix)
    }

    private static func sha256File(_ url: URL) throws -> (hex: String, count: Int) {
        var hasher = SHA256()
        var count = 0
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        while true {
            let chunk = try fh.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            count += chunk.count
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}
