import AppKit
import Darwin
import Foundation

// MARK: - HostDrop — the M108c file-drop lane, host half (ADR 0051 D4)
//
// `--host-drop` arms the lane: the display view registers `.fileURL` and a
// drag of files onto the VM window lands each one in <share>/INBOX/, then a
// signed DROP record names it for the seat's toast. Delivery is an fd→fd
// stream off an O_NOFOLLOW open — the runner already owns the share folder,
// so there is no transport to bound beyond the per-gesture caps; the fd is
// what keeps the kind check and the copy on the same inode.
//
// The rules (ADR 0051 D4):
//   - ≤ 64 MiB per file (payload_too_large), ≤ 16 files per gesture —
//     bound exists so a drop is refused honestly before the runner streams
//     a disk image into a share, not because the transport needs it.
//   - Regular files only (unsupported_kind); the basename is sanitized to
//     ≤ 48 bytes of [A-Za-z0-9._-] with other bytes folded to `_`, a leading
//     non-alphanumeric prefixed `F`, collisions getting `-2`…`-9` before
//     the extension, then name_rejected.
//   - The payload lands `INBOX/<name>~` then renames — the share's
//     WriteFileSafe atomicity rule, so the guest never reads a partial
//     file. The payload itself is UNSIGNED bulk content; provenance is the
//     signed notice, so a guest-planted INBOX file produces no toast.
//   - The DROP notice rides the 4-outstanding backpressure bound like
//     every record: backpressure refuses the NOTICE, never un-drops the
//     file (delivery and notice are independent).
//
// `--host-drop-file <path>` + `--host-drop-after <marker>` are the gate
// hooks — they feed paths through `drop(urls:)`, the SAME function the
// NSView's performDragOperation calls, so the class-B run exercises the
// real handler (the --input-string precedent).
final class HostDrop {
    static let fileMax: Int64 = 64 * 1024 * 1024 // 64 MiB per file (D4)
    static let gestureMax = 16                   // files per gesture (D4)
    static let nameMax = 48                      // sanitized basename bytes
    static let inboxName = "INBOX"

    private let session: HostIntSession
    private var laneDir: URL { session.laneDir }
    private let inboxDir: URL
    private var dropSeq: UInt32 = 0 // next outbound DROP seq

    init(session: HostIntSession) {
        self.session = session
        inboxDir = session.shareDir.appendingPathComponent(Self.inboxName, isDirectory: true)
    }

    /// Create <share>/INBOX/ — the runner owns it at arm time (D4).
    /// Also registers the lane-drop + send-file bus verbs (M114c #2456).
    @discardableResult
    func start() -> Bool {
        HostIntCommands.registerLane(self)
        do {
            try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
            return true
        } catch {
            HostInt.logRefuse(lane: "drop", reason: .ioError)
            return false
        }
    }

    /// The one drop entry point: the NSView's performDragOperation and the
    /// --host-drop-file hook both land here. Items past the gesture bound
    /// are refused by name; the rest each take dropOne's per-file rules.
    /// A suspended lane (M114c) refuses every item `lane_disabled` —
    /// same refusal name the arm-time dead-lane path already uses.
    func drop(urls: [URL]) {
        if session.isSuspended(HostInt.laneDrop) {
            for _ in urls { HostInt.logRefuse(lane: "drop", reason: .laneDisabled) }
            return
        }
        if urls.count > Self.gestureMax {
            for _ in Self.gestureMax..<urls.count {
                HostInt.logRefuse(lane: "drop", reason: .payloadTooLarge)
            }
        }
        for url in urls.prefix(Self.gestureMax) { dropOne(url) }
    }

    private func dropOne(_ url: URL) {
        // Open the source O_NOFOLLOW and fstat it: the kind/size check and
        // the payload copy then act on the SAME inode — the check-then-copy
        // window closes, and a final-component symlink (planted or swapped
        // in) refuses ELOOP at open rather than copyItem preserving it as
        // a link in the guest-visible INBOX.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            HostInt.logRefuse(lane: "drop", reason: errno == ELOOP ? .unsupportedKind : .ioError)
            return
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            HostInt.logRefuse(lane: "drop", reason: .ioError)
            return
        }
        guard st.st_mode & S_IFMT == S_IFREG else {
            HostInt.logRefuse(lane: "drop", reason: .unsupportedKind)
            return
        }
        let size = Int64(st.st_size)
        guard size <= Self.fileMax else {
            HostInt.logRefuse(lane: "drop", reason: .payloadTooLarge)
            return
        }
        guard let base = Self.sanitizedName(url.lastPathComponent),
              let name = inboxName(base) else {
            HostInt.logRefuse(lane: "drop", reason: .nameRejected)
            return
        }
        // Publish the payload: copy fd→fd into <name>~ then rename — the
        // share's atomicity rule (the WriteFileSafe/HF3 pattern, host
        // side). O_EXCL on the temp means a guest-planted `<name>~` can
        // only fail the drop, never redirect it.
        let tmp = inboxDir.appendingPathComponent(name + "~")
        let dst = inboxDir.appendingPathComponent(name)
        let tfd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 0o777)
        guard tfd >= 0, Self.copyFd(fd, to: tfd) else {
            if tfd >= 0 { close(tfd) }
            try? FileManager.default.removeItem(at: tmp)
            HostInt.logRefuse(lane: "drop", reason: .ioError)
            return
        }
        fsync(tfd)
        close(tfd)
        do {
            try FileManager.default.moveItem(at: tmp, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            HostInt.logRefuse(lane: "drop", reason: .ioError)
            return
        }
        // The notice is what carries provenance — bounded like every
        // record. Backpressure refuses the notice, not the file.
        if HostInt.outstanding(laneDir: laneDir, tag: .drop) >= HostInt.maxOutstanding {
            HostInt.logRefuse(lane: "drop", reason: .backpressured)
            return
        }
        // D4 payload: [name_len u8][name][size u64le].
        var payload = Data([UInt8(name.utf8.count)])
        payload.append(contentsOf: name.utf8)
        var le = UInt64(size).littleEndian
        payload.append(Data(bytes: &le, count: 8))
        let seq = dropSeq + 1
        guard let rec = HostInt.encode(tag: .drop, flags: 0, seq: seq, epoch: session.epoch,
                                       payload: payload, key: session.key),
              HostInt.publish(laneDir: laneDir, name: HostInt.recordName(tag: .drop, seq: seq), body: rec)
        else {
            HostInt.logRefuse(lane: "drop", reason: .ioError)
            return
        }
        dropSeq = seq
        FileHandle.standardOutput.write(Data("host-drop: file seq=\(seq) name=\(name) size=\(size)\n".utf8))
    }

    /// The payload copy itself: fd→fd through one bounce buffer. The
    /// source is the O_NOFOLLOW-opened inode the kind/size check ran on,
    /// so a path swap between check and copy cannot redirect it.
    private static func copyFd(_ src: Int32, to dst: Int32) -> Bool {
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        return buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            while true {
                let n = read(src, base, ptr.count)
                if n == 0 { return true }
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                var done = 0
                while done < n {
                    let w = write(dst, base + done, n - done)
                    if w < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    done += w
                }
            }
        }
    }

    /// The D4 name rule: fold every byte outside [A-Za-z0-9._-] to `_`,
    /// prefix `F` when the result does not start alphanumerically, cut at
    /// 48 bytes. nil means no honest name exists (empty after folding —
    /// the caller's name_rejected).
    static func sanitizedName(_ base: String) -> String? {
        var out = [UInt8]()
        for b in base.utf8 {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                out.append(b)
            default:
                out.append(UInt8(ascii: "_"))
            }
        }
        if out.isEmpty { return nil }
        if let first = out.first, !isAlnum(first) {
            out.insert(UInt8(ascii: "F"), at: 0)
        }
        if out.count > nameMax {
            out = Array(out.prefix(nameMax))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Collision rule: `name` lands unless it exists; then `base-2.ext` …
    /// `base-9.ext` (the suffix rides before the extension so the sniff's
    /// extension fallback survives), the base cut so the total stays ≤ 48.
    /// nil after nine tries — the caller's name_rejected.
    private func inboxName(_ name: String) -> String? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: inboxDir.appendingPathComponent(name).path) {
            return name
        }
        let stem: String
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[dot...])
        } else {
            stem = name
            ext = ""
        }
        for n in 2...9 {
            var cand = "\(stem)-\(n)\(ext)"
            if cand.utf8.count > Self.nameMax {
                let room = Self.nameMax - "-\(n)".utf8.count - ext.utf8.count
                if room <= 0 { continue }
                cand = String(decoding: stem.utf8.prefix(room), as: UTF8.self) + "-\(n)" + ext
            }
            if !fm.fileExists(atPath: inboxDir.appendingPathComponent(cand).path) {
                return cand
            }
        }
        return nil
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ||
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) ||
        (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
    }
}
