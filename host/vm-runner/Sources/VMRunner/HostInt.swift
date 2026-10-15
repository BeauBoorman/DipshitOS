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

    enum Tag: UInt8 {
        case armed = 0     // h→g runner → seat:  payload [lane_mask u8]
        case clipOut = 1   // g→h seat → runner:  clipboard bytes (0 = clear)
        case clipIn = 2    // h→g runner → seat:  UTF-8 text ≤ 512
        case notifyOut = 3 // g→h seat → runner:  toast text ≤ 24
        case drop = 4      // h→g runner → seat:  [name_len][name][size u64le]

        var stem: String {
            switch self {
            case .armed: return "ARMED"
            case .clipOut: return "CLIPOUT"
            case .clipIn: return "CLIPIN"
            case .notifyOut: return "NOTIFY"
            case .drop: return "DROP"
            }
        }

        /// The lane name the refusal markers carry ("clip", "drop",
        /// "notify"). ARMED is the handshake, not a lane.
        var lane: String {
            switch self {
            case .clipIn, .clipOut: return "clip"
            case .drop: return "drop"
            case .notifyOut: return "notify"
            case .armed: return ""
            }
        }

        /// The tag's ARMED lane_mask bit (one bit per lane, both
        /// directions share it). ARMED has none.
        var laneBit: UInt8 {
            switch self {
            case .clipIn, .clipOut: return HostInt.laneClip
            case .drop: return HostInt.laneDrop
            case .notifyOut: return HostInt.laneNotify
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
    }

    struct Record {
        var tag: Tag
        var flags: UInt8
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
    /// the TRUNCATED flag) rather than emit an unreadable record.
    static func encode(tag: Tag, flags: UInt8, seq: UInt32, epoch: UInt32, payload: Data, key: Data) -> Data? {
        guard payload.count <= payloadMax else { return nil }
        var out = Data()
        out.append(contentsOf: [0x56, 0x48, 0x49, 0x31]) // "VHI1"
        out.append(tag.rawValue)
        out.append(flags)
        out.append(contentsOf: [0, 0])
        for shift in [0, 8, 16, 24] { out.append(UInt8((seq >> shift) & 0xff)) }
        for shift in [0, 8, 16, 24] { out.append(UInt8((epoch >> shift) & 0xff)) }
        out.append(UInt8(payload.count & 0xff))
        out.append(UInt8((payload.count >> 8) & 0xff))
        out.append(payload)
        out.append(hmacSHA256(key: key, msg: out))
        return out
    }

    /// Parse the wire form. nil is a bad_record refusal — wrong magic, bad
    /// tag, reserved nonzero, plen > 512, or a total size that does not
    /// equal header+payload+mac.
    static func decode(_ raw: Data) -> Record? {
        guard raw.count >= headerLen + macLen, raw.count <= recordMax else { return nil }
        guard raw[0] == 0x56, raw[1] == 0x48, raw[2] == 0x49, raw[3] == 0x31,
              let tag = Tag(rawValue: raw[4]),
              raw[6] == 0, raw[7] == 0 else { return nil }
        let plen = Int(raw[16]) | (Int(raw[17]) << 8)
        guard plen <= payloadMax, raw.count == headerLen + plen + macLen else { return nil }
        let rec = Record(
            tag: tag,
            flags: raw[5],
            seq: UInt32(raw[8]) | (UInt32(raw[9]) << 8) | (UInt32(raw[10]) << 16) | (UInt32(raw[11]) << 24),
            epoch: UInt32(raw[12]) | (UInt32(raw[13]) << 8) | (UInt32(raw[14]) << 16) | (UInt32(raw[15]) << 24),
            payload: raw.subdata(in: headerLen..<headerLen + plen),
            signed: raw.subdata(in: 0..<headerLen + plen),
            mac: raw.subdata(in: headerLen + plen..<raw.count))
        if rec.mac.count != macLen { return nil }
        return rec
    }

    /// The forgery check: the record's MAC must match under key.
    static func verify(_ rec: Record, key: Data) -> Bool {
        hmacSHA256(key: key, msg: rec.signed) == rec.mac
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
        let lanes = names.isEmpty ? "-" : names.joined(separator: ",")
        FileHandle.standardOutput.write(Data("host-int: armed lanes=\(lanes) epoch=\(epoch)\n".utf8))
    }
}
