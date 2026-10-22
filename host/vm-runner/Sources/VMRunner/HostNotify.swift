import AppKit
import Foundation
import UserNotifications
import VMAppKit

// MARK: - HostNotify — the M108d notify-out lane, host half (ADR 0051 D5)
//
// `--host-notify` arms the lane: the seat forwards every queued kind-12
// toast as a signed NOTIFY_OUT record (payload ≤ 24 bytes — the strip's own
// text budget), and the runner drains them on the shared 250 ms poll,
// posting each as a UNUserNotificationCenter banner. A minimal delegate's
// willPresent returns .banner so a toast shows while the runner is
// frontmost.
//
// M127c (#2601, ADR 0051 V2-D3) closes the loop: a NOTIFY_OUT carries the
// toast's sender tab id; the runner binds it to the banner it posts (the
// sender rides userInfo) and keeps the same bounded consumed-record list
// the `notify-click` bus verb consults. A banner click — didReceive — or
// the verb, the class-B equivalent, fires one click path: raise the VM
// window first (the click's first duty is always "bring the VM forward"),
// then, when the sender is nonzero, emit a signed NOTIFY_FOCUS{sender}
// (plen 0 — the header is the whole request) the seat turns into
// focusHosted(sender). Sender 0 emits no record: a seat-originated toast
// has no tab to focus, so the raise is the whole answer.
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
    /// Consume bound per 250 ms tick: ONE verified record — the seat's own
    /// emit rate (D5). The lane dir is guest-writable and the guest holds
    /// the lane key, so a hostile guest can drop thousands of validly-MAC'd
    /// records at once; the cap means that buys at most one banner (or
    /// named drop) per poll. Verified records past the cap stay on disk
    /// for the next tick rather than being deleted.
    static let perTickMax = 1
    /// The seat's own toast-text budget in bytes (D5; the kind-12 strip's
    /// 24). A verified record can carry up to payloadMax — the body is
    /// clamped to the budget on a UTF-8 boundary before it can reach a
    /// banner.
    static let bodyMax = 24
    /// The consumed-record list's bound (V2-D3): seq→sender for every
    /// verified NOTIFY_OUT this lane consumed — posted or honestly
    /// dropped — so the `notify-click` verb's "most recent" and
    /// didReceive's identifier lookup work with no bundle and no banner.
    /// Generous past the lane's own depth (the strip stages ≤ 4, the
    /// runner drains ≤ 1/250 ms); the cap keeps a hostile guest's
    /// validly-MAC'd flood from growing memory.
    static let postedBound = 16

    /// Internal, not private: the banner router reads the epoch off it to
    /// pick the session a banner click belongs to.
    let session: HostIntSession
    private var laneDir: URL { session.laneDir }
    private var lastSeq: UInt32 = 0      // last consumed NOTIFY_OUT seq
    private var dropped = 0              // cumulative non-posted count
    private var ioLogged = Set<String>() // one io_error per filename
    private var authDenied = false
    /// The bounded consumed list: oldest first, evicted past postedBound.
    private var posted: [(seq: UInt32, sender: UInt16)] = []
    private var focusSeq: UInt32 = 0     // next outbound NOTIFY_FOCUS seq

    /// Banners exist only under an app bundle; the bare gate runner has
    /// none, so the call is gated on identity BEFORE the center is ever
    /// touched (an unbundled .current() must not be attempted). Internal
    /// so a test can force the bare posture — an .xctest bundle HAS an
    /// identifier but no consent-owning app to post through.
    var bundled = Bundle.main.bundleIdentifier != nil

    init(session: HostIntSession) {
        self.session = session
        super.init()
    }

    /// Arm the lane: on a bundle, install the willPresent/didReceive
    /// delegate and ask notification consent once. Bare — the whole
    /// class-B posture — takes the no_bundle path per record instead;
    /// nothing here is needed beyond the verbs.
    func start() {
        // M114c (#2456): the lane-notify bus verb, same seam as the menu.
        // notify-click rides the OWNING session's bus too — a secondary
        // session's verb on the global bus would dispatch the wrong
        // lane's click path.
        HostIntCommands.registerLane(self)
        registerVerbs(on: HostIntCommands.bus(owning: self))
        guard bundled else { return }
        // The center takes ONE delegate: the shared banner router, which
        // dispatches a click to the lane that posted the banner by
        // identifier prefix — an outbox banner's reveal-on-click stays
        // live when this lane is armed too.
        HostBannerRouter.shared.install(self)
        let center = UNUserNotificationCenter.current()
        center.delegate = HostBannerRouter.shared
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard !granted else { return }
            DispatchQueue.main.async {
                self?.authDenied = true
                HostInt.logRefuse(lane: "notify", reason: .authDenied)
            }
        }
    }

    /// The lane's own bus verbs (V2-D6: each lane's file registers its own
    /// — HostRecorder's self-registration precedent — not the shared
    /// HostIntCommands table). `start()` binds the runner's commandBus;
    /// tests bind their own, so the registration itself is class-A.
    ///
    /// `notify-click` is the class-B equivalent of the banner click: it
    /// dispatches the IDENTICAL click path on the most recent consumed
    /// NOTIFY_OUT, so a bare runner exercises the real seam. Nothing
    /// consumed yet, or a suspended lane, receipts `disabled`.
    func registerVerbs(on bus: HostCommandBus) {
        bus.register(.notifyClick, HostCommandBus.Registration(
            isEnabled: { [weak self] in
                guard let self else { return false }
                return self.posted.last != nil && !self.session.isSuspended(HostInt.laneNotify)
            },
            action: { [weak self] in
                guard let self, let last = self.posted.last else { return .disabled }
                self.click(sender: last.sender)
                return .performed
            }))
    }

    /// The 250 ms poll step (hostIntTick): drain NOTIFY_OUT records in seq
    /// order. Refused records are still deleted as met, but only
    /// `perTickMax` verified records are consumed per tick — anything
    /// beyond stays on disk and drains at the lane's own rate.
    ///
    /// M114c: while the session's notify bit is suspended the lane is a
    /// hard off — every record for it is refused `lane_disabled` and
    /// deleted (the seat stops emitting under the revoked mask, so this
    /// is the in-flight/planted sweep, not a queue).
    func tick() {
        if session.isSuspended(HostInt.laneNotify) {
            guard let pending = HostInt.records(laneDir: laneDir, tag: .notifyOut) else { return }
            for (name, _) in pending {
                HostInt.logRefuse(lane: "notify", reason: .laneDisabled)
                remove(laneDir.appendingPathComponent(name))
            }
            return
        }
        guard let files = HostInt.records(laneDir: laneDir, tag: .notifyOut) else { return }
        var consumed = 0
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
            // The per-tick bound: a verified record past it is left for
            // the next tick — consume is the expensive act (banner or
            // named drop), not the refusal sweeps above.
            guard consumed < Self.perTickMax else { break }
            lastSeq = seq
            remove(url)
            // V2-D3: the click path's correlation table — every VERIFIED
            // record is remembered, posted or honestly dropped, so the
            // verb's most-recent answer is the same one the delegate's.
            posted.append((seq: seq, sender: rec.sender))
            if posted.count > Self.postedBound { posted.removeFirst() }
            post(text, seq: seq, sender: rec.sender)
            consumed += 1
        }
    }

    /// One verified toast → one banner, or one named drop. `post` asserts
    /// the hand-off to the center (the pixel is the class-C leg); a bare or
    /// unauthorized runner drops with its reason and the running count.
    /// The sender rides the banner's userInfo so a click can answer it
    /// without the seat ever re-deriving the correlation (V2-D3).
    private func post(_ text: String, seq: UInt32, sender: UInt16) {
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
        content.body = Self.clamped(text)
        content.userInfo = ["sender": NSNumber(value: sender)]
        let req = UNNotificationRequest(
            identifier: "vhi1-notify-\(session.epoch)-\(seq)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
        FileHandle.standardOutput.write(Data("host-notify: post seq=\(seq)\n".utf8))
    }

    /// The shared click path (V2-D3) — didReceive's banner click and the
    /// `notify-click` bus verb land here identically. The raise is the
    /// first duty and happens even when no record follows; a nonzero
    /// sender then emits a signed NOTIFY_FOCUS under the lane's own
    /// books (per-tag seq, the 4-outstanding backpressure bound, the
    /// suspended-mask consent check).
    func click(sender: UInt16) {
        raiseWindow()
        guard sender != 0 else {
            // A seat-originated toast has no tab to focus — the raise is
            // the whole answer; emitting a record could only draw gone.
            FileHandle.standardOutput.write(Data("host-notify: click id=0\n".utf8))
            return
        }
        guard !session.isSuspended(HostInt.laneNotify) else {
            HostInt.logRefuse(lane: "notify", reason: .laneDisabled)
            return
        }
        guard HostInt.outstanding(laneDir: laneDir, tag: .notifyFocus) < HostInt.maxOutstanding else {
            HostInt.logRefuse(lane: "notify", reason: .backpressured)
            return
        }
        let seq = focusSeq + 1
        guard let rec = HostInt.encode(tag: .notifyFocus, flags: 0, sender: sender,
                                       seq: seq, epoch: session.epoch,
                                       payload: Data(), key: session.key),
              HostInt.publish(laneDir: laneDir,
                              name: HostInt.recordName(tag: .notifyFocus, seq: seq), body: rec)
        else {
            HostInt.logRefuse(lane: "notify", reason: .ioError)
            return
        }
        focusSeq = seq
        FileHandle.standardOutput.write(Data("host-notify: click-focus id=\(sender) seq=\(seq)\n".utf8))
    }

    /// The click's first duty: bring the VM forward. Only a bundle owns
    /// windows to raise — the bare gate runner skips it silently (the
    /// `wantPointer` activation pattern main.swift already runs).
    private func raiseWindow() {
        guard bundled else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate()
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// The delegate's seq lookup: `vhi1-notify-<epoch>-<seq>` → the
    /// bounded consumed list's sender, when the banner's own userInfo is
    /// unavailable (a test-built notification, say).
    func consumedSender(seq: UInt32) -> UInt16? {
        posted.first { $0.seq == seq }?.sender
    }

    /// The bodyMax clamp: whole Characters drop off the tail until the
    /// text fits the seat's 24-byte budget — the cut can never split a
    /// UTF-8 scalar.
    static func clamped(_ text: String) -> String {
        var out = text
        while out.utf8.count > bodyMax { out = String(out.dropLast()) }
        return out
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

    /// V2-D3: the banner click. Only the default action counts — rich
    /// notification actions are out of scope. The sender comes off the
    /// banner's own userInfo (the record's correlation bound at post);
    /// the bounded consumed list is the fallback for a banner whose
    /// userInfo is absent.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let req = response.notification.request
        var sender = (req.content.userInfo["sender"] as? NSNumber)?.uint16Value
        if sender == nil {
            // `vhi1-notify-<epoch>-<seq>` → the consumed list.
            let parts = req.identifier.split(separator: "-")
            if parts.count == 4, parts[0] == "vhi1", parts[1] == "notify",
               let seq = UInt32(parts[3]) {
                sender = consumedSender(seq: seq)
            }
        }
        guard let sender else { return } // not one of this lane's banners
        click(sender: sender)
    }
}

// MARK: - HostBannerRouter — the center's single delegate
//
// UNUserNotificationCenter takes one delegate per process, but two lanes
// post banners — this lane's toasts (vhi1-notify-<epoch>-<seq>) and the
// outbox lane's export landings (vhi1-outbox-<epoch>-<seq>). Before the
// router, whichever lane installed last owned every click: with both
// lanes armed the notify delegate dropped outbox clicks outright, so a
// banner's reveal-on-click was dead in the bundled config.
//
// The router is the seam both lanes install onto: a lane registers itself
// at arm, and a click is dispatched by the request identifier's prefix to
// a lane of that family whose session epoch is the one the identifier
// names — a second session's lane can never claim the primary's banner
// (its epoch differs), and an unmatched identifier falls back to the sole
// lane of the family so a test-built banner still lands. Each lane keeps
// its own delegate conformance for the click logic itself; the router
// only picks.
final class HostBannerRouter: NSObject {
    static let shared = HostBannerRouter()

    private let notifyLanes = NSHashTable<HostNotify>.weakObjects()
    private let outboxLanes = NSHashTable<HostOutbox>.weakObjects()

    func install(_ lane: HostNotify) { notifyLanes.add(lane) }
    func install(_ lane: HostOutbox) { outboxLanes.add(lane) }

    /// The lane a banner click belongs to — the delegate that runs it.
    /// Internal so a test can pin the routing without a real
    /// UNNotificationResponse (which has no public constructor).
    func route(_ identifier: String) -> UNUserNotificationCenterDelegate? {
        let parts = identifier.split(separator: "-")
        guard parts.count == 4, parts[0] == "vhi1" else { return nil }
        let epoch = UInt32(parts[2])
        switch parts[1] {
        case "notify":
            return pick(notifyLanes.allObjects, epoch: epoch) { $0.session.epoch }
        case "outbox":
            return pick(outboxLanes.allObjects, epoch: epoch) { $0.session.epoch }
        default:
            return nil
        }
    }

    /// The epoch-named lane wins; without a match the family's only lane
    /// answers (a banner built outside the identifier grammar — a test
    /// one — still reaches its lane).
    private func pick<T>(_ lanes: [T], epoch: UInt32?, keyedBy key: (T) -> UInt32) -> T? {
        if let epoch, let lane = lanes.first(where: { key($0) == epoch }) {
            return lane
        }
        return lanes.count == 1 ? lanes[0] : nil
    }
}

extension HostBannerRouter: UNUserNotificationCenterDelegate {
    /// Both lanes' willPresent is the same answer — D5's frontmost rule —
    /// so the router returns it directly.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    /// The click: route by identifier to the posting lane's own
    /// didReceive — the notify lane's click path for vhi1-notify-…, the
    /// outbox lane's Finder reveal for vhi1-outbox-…. An identifier from
    /// neither family (or no surviving lane) is consumed, not fumbled.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let lane = route(response.notification.request.identifier) else {
            completionHandler()
            return
        }
        lane.userNotificationCenter?(center, didReceive: response,
                                     withCompletionHandler: completionHandler)
    }
}
