import AppKit
import Foundation
import UserNotifications
import VMAppKit

// MARK: - HostOutbox — the M127d export lane, host half (ADR 0051 V2-D5)
//
// The reverse drop. A guest app stages /host/OUTBOX/<name> + a REQ-<8hex>
// intent marker; the seat (the only guest signer) emits one signed OUTBOX
// record per REQ-marked payload. This lane drains those records on the
// shared 250 ms poll and moves each verified payload from <share>/OUTBOX/
// to the run's --host-outbox-dir (default ~/Downloads — the flag is the
// gate redirect, so a class-B run never touches a real Downloads).
//
// The rules (ADR 0051 V2-D5):
//   - What the host trusts is the signed record — the REQ is unsigned
//     intent. Per verified record: the named payload must exist (gone),
//     be regular (unsupported_kind) and fit ≤ 64 MiB at move time
//     (payload_too_large — the live fstat rules the move, not the
//     record's attest-time size). The name is re-validated against the
//     D4 charset — a verified record can still carry a name that would
//     walk off the destination, and name_rejected is the answer.
//   - ≤ 64 exports per epoch (quota_exceeded): a hostile or buggy guest
//     can mint valid records at the emit bound forever; the cap is the
//     honest wall. ≤ 1 verified record consumed per tick, the notify
//     drain's cadence.
//   - Success moves OUTBOX/<name> to the destination, collision-suffixed
//     -2…-9 then name_rejected, and prints `host-outbox: file
//     seq=<n> name=<name> size=<n>`. A bundled session additionally
//     posts a banner whose click (or the reveal-export bus verb) reveals
//     the landing in Finder; bare runners take only the move.
final class HostOutbox: NSObject {
    static let fileMax: Int64 = 64 * 1024 * 1024 // per file at move time
    static let epochMax = 64                     // verified exports per epoch
    static let perTickMax = 1                    // consume bound per 250 ms tick
    static let nameMax = 48                      // payload basename bytes (D4)
    static let outboxName = "OUTBOX"

    /// Internal, not private: the banner router reads the epoch off it
    /// (session(owning:) covers the lane, the identifier's epoch picks
    /// the session a click belongs to).
    let session: HostIntSession
    private var laneDir: URL { session.laneDir }
    private let outboxDir: URL
    let destDir: URL
    private var lastSeq: UInt32 = 0      // last consumed OUTBOX seq
    private var exported = 0             // per-epoch export count
    private var ioLogged = Set<String>() // one io_error per filename
    private(set) var lastLanding: URL?   // the reveal target

    /// Banners and Finder reveals exist only under an app bundle; the
    /// bare gate runner takes the move only (the no_bundle posture the
    /// notify lane names per record — here the lane simply never posts).
    private let bundled = Bundle.main.bundleIdentifier != nil

    init(session: HostIntSession, destDir: URL) {
        self.session = session
        outboxDir = session.shareDir.appendingPathComponent(Self.outboxName, isDirectory: true)
        self.destDir = destDir
        super.init()
    }

    /// Create <share>/OUTBOX/ — the runner owns it at arm time (the guest
    /// SDK has no mkdir, the same posture AGENT/ and INBOX/ take) — and
    /// registers the lane's bus verbs (the V2-D7 seam: lane-outbox toggles
    /// the ARMED bit like the M114c toggles, reveal-export reveals the
    /// most recent landing in Finder). Registration goes through
    /// HostIntCommands like the other lanes, so the verbs land on the
    /// OWNING session's bus and toggle that session's mask — never a
    /// global's (M139a).
    @discardableResult
    func start() -> Bool {
        HostIntCommands.registerLane(self)
        do {
            try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        } catch {
            HostInt.logRefuse(lane: "outbox", reason: .ioError)
            return false
        }
        // The banner half is bundle-only. The center's delegate is the
        // shared banner router: a click is dispatched to the lane that
        // posted the banner by identifier prefix, so arming the notify
        // lane can never mute an export banner's reveal-on-click.
        if bundled {
            HostBannerRouter.shared.install(self)
            let center = UNUserNotificationCenter.current()
            center.delegate = HostBannerRouter.shared
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        return true
    }

    /// The reveal-export verb's action and the banner click's: reveal the
    /// most recent landing in Finder.
    func revealLast() -> HostCommandBus.Outcome {
        guard let landing = lastLanding else { return .disabled }
        NSWorkspace.shared.activateFileViewerSelecting([landing])
        return .performed
    }

    /// The 250 ms poll step (hostIntTick): drain OUTBOX records in seq
    /// order — the same verify-then-consume shape the notify lane runs.
    /// Refused records are deleted as met; only `perTickMax` verified
    /// records are consumed per tick.
    ///
    /// While the session's outbox bit is suspended the lane is a hard
    /// off — every record for it is refused `lane_disabled` and deleted.
    func tick() {
        if session.isSuspended(HostInt.laneOutbox) {
            guard let pending = HostInt.records(laneDir: laneDir, tag: .outbox) else { return }
            for (name, _) in pending {
                HostInt.logRefuse(lane: "outbox", reason: .laneDisabled)
                remove(laneDir.appendingPathComponent(name))
            }
            return
        }
        guard let files = HostInt.records(laneDir: laneDir, tag: .outbox) else { return }
        var consumed = 0
        for (name, seq) in files {
            let url = laneDir.appendingPathComponent(name)
            guard let raw = try? Data(contentsOf: url) else {
                if ioLogged.insert(name).inserted {
                    HostInt.logRefuse(lane: "outbox", reason: .ioError)
                }
                continue
            }
            ioLogged.remove(name)
            guard let rec = HostInt.decode(raw), rec.tag == .outbox else {
                HostInt.logRefuse(lane: "outbox", reason: .badRecord)
                remove(url)
                continue
            }
            guard HostInt.verify(rec, key: session.key) else {
                HostInt.logRefuse(lane: "outbox", reason: .badMAC)
                remove(url)
                continue
            }
            guard rec.epoch == session.epoch else {
                HostInt.logRefuse(lane: "outbox", reason: .staleEpoch)
                remove(url)
                continue
            }
            guard seq > lastSeq else {
                HostInt.logRefuse(lane: "outbox", reason: .staleSeq)
                remove(url)
                continue
            }
            // The per-tick bound: a verified record past it is left for
            // the next tick — consume is the expensive act (the move),
            // not the refusal sweeps above.
            guard consumed < Self.perTickMax else { break }
            lastSeq = seq
            remove(url)
            export(rec, seq: seq)
            consumed += 1
        }
    }

    /// One verified record → one move. Payload is the DROP shape
    /// reversed: [name_len u8][name][size u64le].
    private func export(_ rec: HostInt.Record, seq: UInt32) {
        let p = rec.payload
        guard p.count >= 10, Int(p[0]) > 0, p.count == 1 + Int(p[0]) + 8 else {
            HostInt.logRefuse(lane: "outbox", reason: .badRecord)
            return
        }
        let n = Int(p[0])
        guard let name = String(data: p.subdata(in: 1..<1 + n), encoding: .utf8),
              Self.validName(name) else {
            HostInt.logRefuse(lane: "outbox", reason: .nameRejected)
            return
        }
        let src = outboxDir.appendingPathComponent(name)
        var st = stat()
        guard stat(src.path, &st) == 0 else {
            HostInt.logRefuse(lane: "outbox", reason: .gone)
            return
        }
        guard st.st_mode & S_IFMT == S_IFREG else {
            HostInt.logRefuse(lane: "outbox", reason: .unsupportedKind)
            return
        }
        guard st.st_size <= Self.fileMax else {
            HostInt.logRefuse(lane: "outbox", reason: .payloadTooLarge)
            return
        }
        guard exported < Self.epochMax else {
            HostInt.logRefuse(lane: "outbox", reason: .quotaExceeded)
            return
        }
        guard let dst = landingURL(name) else {
            HostInt.logRefuse(lane: "outbox", reason: .nameRejected)
            return
        }
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            HostInt.logRefuse(lane: "outbox", reason: .ioError)
            return
        }
        exported += 1
        lastLanding = dst
        FileHandle.standardOutput.write(Data(
            "host-outbox: file seq=\(seq) name=\(dst.lastPathComponent) size=\(st.st_size)\n".utf8))
        post(seq: seq, name: dst.lastPathComponent)
    }

    /// The destination name: `name` lands unless it exists; then
    /// `base-2.ext` … `base-9.ext` cut so the total stays ≤ 48 — the
    /// INBOX collision rule mirrored. nil after nine tries — the caller's
    /// name_rejected.
    private func landingURL(_ name: String) -> URL? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.appendingPathComponent(name).path) {
            return destDir.appendingPathComponent(name)
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
            if !fm.fileExists(atPath: destDir.appendingPathComponent(cand).path) {
                return destDir.appendingPathComponent(cand)
            }
        }
        return nil
    }

    /// The D4 name rule, re-checked against a verified record: ≤ 48 bytes
    /// of [A-Za-z0-9._-], leading alnum — a name that could walk off the
    /// destination never reaches moveItem (the traversal defense).
    static func validName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count >= 1, bytes.count <= nameMax, isAlnum(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlnum($0) || $0 == UInt8(ascii: ".") ||
            $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ||
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) ||
        (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
    }

    /// The bundled half: a banner naming the landing. The bare runner —
    /// every class-B gate — never reaches here (bundled is checked by the
    /// caller: post runs only when bundled).
    private func post(seq: UInt32, name: String) {
        guard bundled, let landing = lastLanding else { return }
        let content = UNMutableNotificationContent()
        content.title = "VirelaiOS"
        content.body = "Exported \(name)"
        content.userInfo = ["path": landing.path]
        let req = UNNotificationRequest(
            identifier: "vhi1-outbox-\(session.epoch)-\(seq)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension HostOutbox: UNUserNotificationCenterDelegate {
    /// v2: a click on an export banner reveals the landing in Finder —
    /// the same action the reveal-export bus verb runs (the click's
    /// first duty is still "bring the VM forward").
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix("vhi1-outbox-"),
           let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }
}
