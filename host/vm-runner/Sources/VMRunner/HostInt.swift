import CryptoKit
import Foundation

// MARK: - HostInt — the M108 host-integration lane codec (ADR 0051)
//
// The lanes are signed VHI1 records carried as FILES in the --cvc-file
// share's HOSTINT/ directory — no new virtqueue, no new syscall, no kernel
// diff. One record per file: an 18-byte fixed header, a ≤512-byte payload,
// then an HMAC-SHA256 tag over the header+payload under the share's
// SECRETS.TXT `host-int` row (value bytes verbatim — the credential both
// ends read; the guest side gets it through sys_secret_get bound to the
// seat's image).
//
// This file is the shared half every lane builds on: the wire codec, the
// filename grammar, the refusal vocabulary, the record file IO (temp+rename
// publish, delete on consume), the epoch/seq books and the stdout marker
// shapes. HostClipboard (M108b), HostDrop (M108c) and HostNotify (M108d)
// each add their lane driver on top.
//
// Never-logged contract (ADR 0044 D6, verbatim): the key, MACs and payload
// bytes never reach stdout/stderr — every marker carries tag, seq, len and
// sha256[:8] only.

enum HostInt {
    /// ADR 0051 D2 record layout.
    static let headerLen = 18
    static let payloadMax = 512
    static let macLen = 32
    static let recordMax = headerLen + payloadMax + macLen
    /// A producer never holds more than this many unconsumed records per
    /// tag — over that it refuses `backpressured` and counts.
    static let maxOutstanding = 4

    static let dirName = "HOSTINT"
    static let secretName = "host-int"
    static let secretUID = "1000" // uid_user — the seat's principal

    /// Lane mask bits carried in the ARMED record's payload byte.
    static let laneClip: UInt8 = 1 << 0
    static let laneDrop: UInt8 = 1 << 1
    static let laneNotify: UInt8 = 1 << 2
    /// v2: the OUTBOX export lane. NOTIFY_FOCUS needs no bit of its own —
    /// it rides lane_notify (both directions of a lane share one bit).
    static let laneOutbox: UInt8 = 1 << 3

    /// The lane name a mask bit names ("clip"/"drop"/"notify"/"outbox") —
    /// the `lane=` word refusal markers carry.
    static func laneName(_ bit: UInt8) -> String {
        switch bit {
        case laneClip: return "clip"
        case laneDrop: return "drop"
        case laneNotify: return "notify"
        case laneOutbox: return "outbox"
        default: return "?"
        }
    }

    enum Tag: UInt8 {
        case armed = 0       // h→g runner → seat:  payload [lane_mask u8]
        case clipOut = 1     // g→h seat → runner:  clipboard bytes (0 = clear)
        case clipIn = 2      // h→g runner → seat:  UTF-8 text ≤ 512
        case notifyOut = 3   // g→h seat → runner:  toast text ≤ 24
        case drop = 4        // h→g runner → seat:  [name_len][name][size u64le]
        case outbox = 5      // g→h seat → runner:  the DROP shape, reversed (v2)
        case notifyFocus = 6 // h→g runner → seat:  plen MUST be 0 (v2)
        // M124c (#2582): typed clip — payload `u8 mime_len|mime|blob`.
        // Dedicated tags keep raw-text records byte-identical.
        case clipOutT = 7    // g→h seat → runner:  typed clipboard item
        case clipInT = 8     // h→g runner → seat:  typed clipboard item
        // M184b (#3175): the drag-out notice — the DROP shape reversed,
        // naming a payload the seat staged in OUTBOX/; sender is the
        // source window id. Rides the outbox lane bit.
        case dragOut = 9     // g→h seat → runner:  the DROP shape, reversed

        var stem: String {
            switch self {
            case .armed: return "ARMED"
            case .clipOut: return "CLIPOUT"
            case .clipIn: return "CLIPIN"
            case .notifyOut: return "NOTIFY"
            case .drop: return "DROP"
            case .outbox: return "OUTBOX"
            case .notifyFocus: return "NFOCUS"
            case .clipOutT: return "CLIPTOUT"
            case .clipInT: return "CLIPTIN"
            case .dragOut: return "DRAGOUT"
            }
        }

        /// The lane name the refusal markers carry ("clip", "drop",
        /// "notify", "outbox"). ARMED is the handshake, not a lane.
        var lane: String {
            switch self {
            case .clipIn, .clipOut, .clipInT, .clipOutT: return "clip"
            case .drop: return "drop"
            case .notifyOut, .notifyFocus: return "notify"
            case .outbox: return "outbox"
            case .dragOut: return "dragout"
            case .armed: return ""
            }
        }

        /// The tag's ARMED lane_mask bit (one bit per lane, both
        /// directions share it). ARMED has none.
        var laneBit: UInt8 {
            switch self {
            case .clipIn, .clipOut, .clipInT, .clipOutT: return HostInt.laneClip
            case .drop: return HostInt.laneDrop
            case .notifyOut, .notifyFocus: return HostInt.laneNotify
            case .outbox, .dragOut: return HostInt.laneOutbox
            case .armed: return 0
            }
        }

        static func fromStem(_ stem: String) -> Tag? {
            switch stem {
            case "ARMED": return .armed
            case "CLIPOUT": return .clipOut
            case "CLIPIN": return .clipIn
            case "NOTIFY": return .notifyOut
            case "DROP": return .drop
            case "OUTBOX": return .outbox
            case "NFOCUS": return .notifyFocus
            case "CLIPTOUT": return .clipOutT
            case "CLIPTIN": return .clipInT
            case "DRAGOUT": return .dragOut
            default: return nil
            }
        }
    }

    /// The ADR 0051 D2 refusal vocabulary — the `reason=` names both ends
    /// print. Raw values ARE the wire names.
    enum Refusal: String {
        case laneDisabled = "lane_disabled"
        case noCredential = "no_credential"
        case badRecord = "bad_record"
        case badMAC = "bad_mac"
        case staleEpoch = "stale_epoch"
        case staleSeq = "stale_seq"
        case backpressured = "backpressured"
        case payloadTooLarge = "payload_too_large"
        case payloadNotText = "payload_not_text"
        case nameRejected = "name_rejected"
        case unsupportedKind = "unsupported_kind"
        case consentDenied = "consent_denied"
        case noBundle = "no_bundle"
        case authDenied = "auth_denied"
        case ioError = "io_error"
        // v2 additions (ADR 0051 V2-D6): gone names a target that no
        // longer exists; quotaExceeded is the per-epoch OUTBOX cap.
        case gone = "gone"
        case quotaExceeded = "quota_exceeded"
    }

    struct Record {
        var tag: Tag
        var flags: UInt8
        /// The v2 sender_id — the kernel window id the record is about
        /// (0 = none; v1 records carry 0 here by construction).
        var sender: UInt16
        var seq: UInt32
        var epoch: UInt32
        var payload: Data
        /// bytes[0..18+plen) of the wire form — the MAC'd region.
        var signed: Data
        var mac: Data
    }

    static func hmacSHA256(key: Data, msg: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    /// The markers' payload stand-in: sha256[:8] — 8 hex chars, never the
    /// payload itself.
    static func sha256_8(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The lane filename for (tag, seq): "<STEM>-<seq:8hex>" — lowercase
    /// hex, matching the Go side's emit form (the share fs is
    /// case-insensitive regardless).
    static func recordName(tag: Tag, seq: UInt32) -> String {
        String(format: "%@-%08x", tag.stem, seq)
    }

    /// Parse a lane filename back to (tag, seq). Anything that is not a
    /// record — `~` publish temps, foreign files — is nil and never
    /// consumed.
    static func parseName(_ name: String) -> (Tag, UInt32)? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let stem = String(name[..<dash])
        let digits = name[name.index(after: dash)...]
        guard let tag = Tag.fromStem(stem), digits.count == 8,
              let seq = UInt32(digits, radix: 16) else { return nil }
        return (tag, seq)
    }

    /// Build one wire record: header + payload + HMAC tag. nil when the
    /// payload exceeds the bound — the producer truncates first (and sets
    /// the TRUNCATED flag) rather than emit an unreadable record. v2:
    /// `sender` is the window-id correlation field; every v1-shaped call
    /// leaves it 0. A NOTIFY_FOCUS record is refused unless plen is 0
    /// and sender is nonzero — the header is its whole payload.
    static func encode(tag: Tag, flags: UInt8, sender: UInt16 = 0, seq: UInt32, epoch: UInt32, payload: Data, key: Data) -> Data? {
        guard payload.count <= payloadMax else { return nil }
        if tag == .notifyFocus, payload.count != 0 || sender == 0 { return nil }
        var out = Data()
        out.append(contentsOf: [0x56, 0x48, 0x49, 0x31]) // "VHI1"
        out.append(tag.rawValue)
        out.append(flags)
        out.append(UInt8(sender & 0xff))
        out.append(UInt8((sender >> 8) & 0xff))
        for shift in [0, 8, 16, 24] { out.append(UInt8((seq >> shift) & 0xff)) }
        for shift in [0, 8, 16, 24] { out.append(UInt8((epoch >> shift) & 0xff)) }
        out.append(UInt8(payload.count & 0xff))
        out.append(UInt8((payload.count >> 8) & 0xff))
        out.append(payload)
        out.append(hmacSHA256(key: key, msg: out))
        return out
    }

    /// Parse the wire form. nil is a bad_record refusal — wrong magic, bad
    /// tag, plen > 512, a NOTIFY_FOCUS with a nonempty payload, or a
    /// total size that does not equal header+payload+mac. v2: bytes 6..7
    /// are sender_id, not reserved zeros.
    static func decode(_ raw: Data) -> Record? {
        guard raw.count >= headerLen + macLen, raw.count <= recordMax else { return nil }
        guard raw[0] == 0x56, raw[1] == 0x48, raw[2] == 0x49, raw[3] == 0x31,
              let tag = Tag(rawValue: raw[4]) else { return nil }
        let plen = Int(raw[16]) | (Int(raw[17]) << 8)
        guard plen <= payloadMax, raw.count == headerLen + plen + macLen else { return nil }
        guard tag != .notifyFocus || plen == 0 else { return nil }
        let rec = Record(
            tag: tag,
            flags: raw[5],
            sender: UInt16(raw[6]) | (UInt16(raw[7]) << 8),
            seq: UInt32(raw[8]) | (UInt32(raw[9]) << 8) | (UInt32(raw[10]) << 16) | (UInt32(raw[11]) << 24),
            epoch: UInt32(raw[12]) | (UInt32(raw[13]) << 8) | (UInt32(raw[14]) << 16) | (UInt32(raw[15]) << 24),
            payload: raw.subdata(in: headerLen..<headerLen + plen),
            signed: raw.subdata(in: 0..<headerLen + plen),
            mac: raw.subdata(in: headerLen + plen..<raw.count))
        if rec.mac.count != macLen { return nil }
        return rec
    }

    /// The forgery check: the record's MAC must match under key. The
    /// compare is constant-time — an XOR-accumulate over the fixed 32-byte
    /// tag, matching the guest side's Verify so neither end leaks a
    /// timing channel on the refusal.
    static func verify(_ rec: Record, key: Data) -> Bool {
        let mac = hmacSHA256(key: key, msg: rec.signed)
        guard mac.count == rec.mac.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<mac.count { diff |= mac[i] ^ rec.mac[i] }
        return diff == 0
    }

    // MARK: Lane-directory IO

    /// The lane directory inside the share.
    static func laneDir(shareDir: URL) -> URL {
        shareDir.appendingPathComponent(dirName, isDirectory: true)
    }

    /// Read the `host-int` SECRETS.TXT row: `key<TAB>uid<TAB>value[\tapps]`.
    /// The runner reads the SAME row the seat gets through sys_secret_get —
    /// one provisioned row is the credential on both ends. nil = the
    /// `no_credential` refusal. The value bytes are the key verbatim.
    static func loadKey(shareDir: URL) -> Data? {
        let url = shareDir.appendingPathComponent("SECRETS.TXT")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines) == "#v1" else {
            return nil // a differently-schemed file is refused whole
        }
        lines.removeFirst()
        for line in lines {
            let line = line.replacingOccurrences(of: "\r", with: "")
            if line.isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, fields[0] == secretName, fields[1] == secretUID else { continue }
            let key = Data(fields[2].utf8)
            guard !key.isEmpty else { continue }
            return key
        }
        return nil
    }

    /// Publish one record file: write `<name>~`, fsync, then rename over —
    /// the share's established WriteFileSafe convention, host side.
    /// Returns false on any failure (the caller's io_error).
    @discardableResult
    static func publish(laneDir: URL, name: String, body: Data) -> Bool {
        let tmp = laneDir.appendingPathComponent(name + "~")
        let dst = laneDir.appendingPathComponent(name)
        do {
            try body.write(to: tmp)
            if let fh = try? FileHandle(forWritingTo: tmp) {
                try? fh.synchronize()
                try? fh.close()
            }
            // Names are unique per seq so dst never exists; the remove is
            // the belt for a rerun against a reused share.
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// List a tag's record files in the lane dir, ascending by seq.
    /// (name, seq) pairs; nil on a directory read failure.
    static func records(laneDir: URL, tag: Tag) -> [(String, UInt32)]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: laneDir.path) else { return nil }
        var out: [(String, UInt32)] = []
        for name in names {
            guard let (t, seq) = parseName(name), t == tag else { continue }
            out.append((name, seq))
        }
        return out.sorted { $0.1 < $1.1 }
    }

    /// Count a tag's unconsumed record files — the producer backpressure
    /// view. 0 on a missing dir (nothing is outstanding).
    static func outstanding(laneDir: URL, tag: Tag) -> Int {
        records(laneDir: laneDir, tag: tag)?.count ?? 0
    }

    // MARK: Markers

    /// `host-int: refuse lane=<l> reason=<code>` — the runner-side half of
    /// the shared refusal vocabulary.
    static func logRefuse(lane: String, reason: Refusal) {
        FileHandle.standardOutput.write(Data("host-int: refuse lane=\(lane) reason=\(reason.rawValue)\n".utf8))
    }

    /// `host-int: armed lanes=<csv> epoch=<n>` — the one arming line.
    static func logArmed(mask: UInt8, epoch: UInt32) {
        var names: [String] = []
        if mask & laneClip != 0 { names.append("clip") }
        if mask & laneDrop != 0 { names.append("drop") }
        if mask & laneNotify != 0 { names.append("notify") }
        if mask & laneOutbox != 0 { names.append("outbox") }
        let lanes = names.isEmpty ? "-" : names.joined(separator: ",")
        FileHandle.standardOutput.write(Data("host-int: armed lanes=\(lanes) epoch=\(epoch)\n".utf8))
    }
}

// MARK: - HostIntSession — the shared lane session every M108 lane rides
//
// ONE credential load, ONE epoch, ONE ARMED record naming every live lane
// (ADR 0051 D2): the seat adopts (epoch, mask) and accepts only records
// bearing them, so two lanes armed by independent epochs would refuse each
// other stale_epoch forever. M108b carried the session inside
// HostClipboard.arm; M108c hoisted it so --host-clipboard and --host-drop
// arm together.
final class HostIntSession {
    let shareDir: URL
    let laneDir: URL
    let key: Data
    let epoch: UInt32
    let mask: UInt8

    /// M114c (#2456): runtime lane suspension — the bits the operator
    /// pulled out of the published mask. A suspend republishes ARMED
    /// (next seq, same epoch) with the lane's bit cleared; the seat's
    /// seq-gated adoption re-reads the mask and its emit path then
    /// refuses the lane `lane_disabled` — the re-ARMED revocation the
    /// engine was built for. The suspended mask is authoritative: lane
    /// objects ask `isSuspended` rather than keeping their own flag.
    private(set) var suspendedMask: UInt8 = 0
    /// The next ARMED seq — the arm-time publish consumed seq 1.
    private var armedSeq: UInt32 = 1

    /// The mask as currently published: armed bits minus suspended bits.
    var effectiveMask: UInt8 { mask & ~suspendedMask }

    func isSuspended(_ bit: UInt8) -> Bool { suspendedMask & bit != 0 }

    private init(shareDir: URL, key: Data, epoch: UInt32, mask: UInt8) {
        self.shareDir = shareDir
        self.laneDir = HostInt.laneDir(shareDir: shareDir)
        self.key = key
        self.epoch = epoch
        self.mask = mask
    }

    /// Arm the session: load the `host-int` credential, create HOSTINT/,
    /// mint the epoch, publish the one ARMED record naming every live lane
    /// in mask. `requested` is the lane names the operator asked for — a
    /// refused arm logs each lane's own refusal and returns nil (fail
    /// closed per lane, never a boot failure).
    static func arm(shareDir: URL, mask: UInt8, requested: [String]) -> HostIntSession? {
        guard let key = HostInt.loadKey(shareDir: shareDir) else {
            for lane in requested { HostInt.logRefuse(lane: lane, reason: .noCredential) }
            return nil
        }
        let laneDir = HostInt.laneDir(shareDir: shareDir)
        do {
            try FileManager.default.createDirectory(at: laneDir, withIntermediateDirectories: true)
        } catch {
            for lane in requested { HostInt.logRefuse(lane: lane, reason: .ioError) }
            return nil
        }
        let epoch = UInt32.random(in: 1...UInt32.max)
        guard let rec = HostInt.encode(tag: .armed, flags: 0, seq: 1, epoch: epoch,
                                       payload: Data([mask]), key: key),
              HostInt.publish(laneDir: laneDir, name: HostInt.recordName(tag: .armed, seq: 1), body: rec)
        else {
            for lane in requested { HostInt.logRefuse(lane: lane, reason: .ioError) }
            return nil
        }
        HostInt.logArmed(mask: mask, epoch: epoch)
        return HostIntSession(shareDir: shareDir, key: key, epoch: epoch, mask: mask)
    }

    /// M114c: flip one lane's published bit and republish ARMED under the
    /// same epoch — the seat's seq-gated adoption reads the new mask on
    /// its next poll (the serial `armed` lines narrate both directions).
    /// false (after the lane's own io_error refusal) when the republish
    /// fails — the flag rolls back so it never disagrees with the mask
    /// the seat actually saw. A no-op toggle (setting a bit already in
    /// that state) succeeds without republishing.
    @discardableResult
    func setSuspended(_ bit: UInt8, _ on: Bool) -> Bool {
        guard bit != 0, mask & bit != 0 else { return false }
        let prior = suspendedMask
        if on { suspendedMask |= bit } else { suspendedMask &= ~bit }
        if suspendedMask == prior { return true }
        armedSeq += 1
        guard let rec = HostInt.encode(tag: .armed, flags: 0, seq: armedSeq, epoch: epoch,
                                       payload: Data([effectiveMask]), key: key),
              HostInt.publish(laneDir: laneDir, name: HostInt.recordName(tag: .armed, seq: armedSeq), body: rec)
        else {
            suspendedMask = prior
            armedSeq -= 1
            HostInt.logRefuse(lane: HostInt.laneName(bit), reason: .ioError)
            return false
        }
        HostInt.logArmed(mask: effectiveMask, epoch: epoch)
        return true
    }
}
