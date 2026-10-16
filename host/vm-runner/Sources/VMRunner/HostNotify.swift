import Foundation
import UserNotifications

// MARK: - HostNotify — the M108d notify-out lane, host half (ADR 0051 D5)
//
// `--host-notify` arms the lane: the seat forwards every queued kind-12
// toast as a signed NOTIFY_OUT record (payload ≤ 24 bytes — the strip's own
// text budget), and the runner drains them on the shared 250 ms poll,
// posting each as a UNUserNotificationCenter banner. A minimal delegate's
// willPresent returns .banner so a toast shows while the runner is
// frontmost; v1 is one-way FYI — a banner click lands nowhere (no delegate
// action, no VM focus, no deep link).
//
// The bundle split is named, not waved: UNUserNotificationCenter requires
// a bundle identity, which only `just session` packaging provides
// (org.virelaios.host). A bare runner — every class-B gate — consumes
// records normally (decode, MAC, epoch, seq, delete) and logs
// `host-notify: dropped reason=no_bundle seq=<n> n=<count>` instead of
// ever touching the center. Only the banner pixel is bundle-gated; the
// lane machinery stays fully class-B observable.
//
// Consent: at arm the bundled runner calls requestAuthorization; a denial
// refuses `auth_denied` at the lane and every later record drops by that
// name. Never-logged holds: toast text never reaches stdout — seq plus the
// cumulative dropped count is the whole marker story.
final class HostNotify: NSObject {
    private let session: HostIntSession
    private var laneDir: URL { session.laneDir }
    private var lastSeq: UInt32 = 0      // last consumed NOTIFY_OUT seq
    private var dropped = 0              // cumulative non-posted count
    private var ioLogged = Set<String>() // one io_error per filename
    private var authDenied = false

    /// Banners exist only under an app bundle; the bare gate runner has
    /// none, so the call is gated on identity BEFORE the center is ever
    /// touched (an unbundled .current() must not be attempted).
    private let bundled = Bundle.main.bundleIdentifier != nil

    init(session: HostIntSession) {
        self.session = session
        super.init()
    }

    /// Arm the lane: on a bundle, install the willPresent delegate and ask
    /// notification consent once. Bare — the whole class-B posture — takes
    /// the no_bundle path per record instead; nothing here is needed.
    func start() {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard !granted else { return }
            DispatchQueue.main.async {
                self?.authDenied = true
                HostInt.logRefuse(lane: "notify", reason: .authDenied)
            }
        }
    }

    /// The 250 ms poll step (hostIntTick): drain NOTIFY_OUT records in seq
    /// order. Every verified record is consumed — the runner side has no
    /// rate bound of its own; the seat's 1/tick + 4-outstanding is the
    /// whole flood story.
    func tick() {
        guard let files = HostInt.records(laneDir: laneDir, tag: .notifyOut) else { return }
        for (name, seq) in files {
            let url = laneDir.appendingPathComponent(name)
            guard let raw = try? Data(contentsOf: url) else {
                if ioLogged.insert(name).inserted {
                    HostInt.logRefuse(lane: "notify", reason: .ioError)
                }
                continue
            }
            ioLogged.remove(name)
            guard let rec = HostInt.decode(raw), rec.tag == .notifyOut else {
                HostInt.logRefuse(lane: "notify", reason: .badRecord)
                remove(url)
                continue
            }
            guard HostInt.verify(rec, key: session.key) else {
                HostInt.logRefuse(lane: "notify", reason: .badMAC)
                remove(url)
                continue
            }
            guard rec.epoch == session.epoch else {
                HostInt.logRefuse(lane: "notify", reason: .staleEpoch)
                remove(url)
                continue
            }
            guard seq > lastSeq else {
                HostInt.logRefuse(lane: "notify", reason: .staleSeq)
                remove(url)
                continue
            }
            guard let text = String(data: rec.payload, encoding: .utf8) else {
                HostInt.logRefuse(lane: "notify", reason: .payloadNotText)
                remove(url)
                continue
            }
            lastSeq = seq
            remove(url)
            post(text, seq: seq)
        }
    }

    /// One verified toast → one banner, or one named drop. `post` asserts
    /// the hand-off to the center (the pixel is the class-C leg); a bare or
    /// unauthorized runner drops with its reason and the running count.
    private func post(_ text: String, seq: UInt32) {
        if !bundled {
            dropped += 1
            FileHandle.standardOutput.write(Data("host-notify: dropped reason=no_bundle seq=\(seq) n=\(dropped)\n".utf8))
            return
        }
        if authDenied {
            dropped += 1
            FileHandle.standardOutput.write(Data("host-notify: dropped reason=auth_denied seq=\(seq) n=\(dropped)\n".utf8))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "VirelaiOS"
        content.body = text
        let req = UNNotificationRequest(
            identifier: "vhi1-notify-\(session.epoch)-\(seq)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
        FileHandle.standardOutput.write(Data("host-notify: post seq=\(seq)\n".utf8))
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension HostNotify: UNUserNotificationCenterDelegate {
    /// D5's frontmost rule: the default presentation suppresses banners
    /// while the app is active, which is exactly when a session runs —
    /// return .banner so the toast is actually visible.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
