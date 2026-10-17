import AppKit
import Foundation

// MARK: - HostClipboard — the M108b clipboard lane, host half (ADR 0051 D3)
//
// `--host-clipboard` arms BOTH directions — one lane, one flag, one consent
// story. Guest→host: the seat emits signed CLIP_OUT records the runner
// mirrors to the target pasteboard as text. Host→guest: NSPasteboard has no
// change notification, so the runner polls changeCount every 250 ms; a bump
// that is not the lane's own write becomes a signed CLIP_IN the seat
// applies through slot 38.
//
// Bounds are the kernel clipboard's own (512 bytes): inbound text is cut
// on a scalar boundary and marked TRUNCATED, never silently cut. The echo
// guards are symmetric: the runner skips the changeCount bump its own
// CLIP_OUT apply produced, and the seat skips its own CLIP_IN apply.
//
// Consent (the M97g posture the ADR maps): the lane exists only while the
// flag AND the provisioned host-int credential agree — a missing row is a
// named `no_credential` refusal at arm and the boot continues with the
// lane dead (fail closed per lane, never a boot failure).

final class HostClipboard {
    private let session: HostIntSession
    private var laneDir: URL { session.laneDir }
    private var key: Data { session.key }
    private var epoch: UInt32 { session.epoch }
    private let board: NSPasteboard
    private var armed = false

    private var clipInSeq: UInt32 = 0       // next outbound CLIP_IN seq
    private var lastClipOutSeq: UInt32 = 0  // last consumed CLIP_OUT seq
    private var lastChangeCount: Int = 0
    private var echoGuard: String?          // the last string this lane wrote
    private var ioLogged = Set<String>()    // one io_error per filename

    init(session: HostIntSession, pasteboardName: String?) {
        self.session = session
        if let name = pasteboardName {
            board = NSPasteboard(name: NSPasteboard.Name(name))
        } else {
            board = NSPasteboard.general
        }
    }

    /// Begin the lane on an already-armed session: the ARMED record naming
    /// the clip bit is published, so all that remains is the pasteboard
    /// baseline — only changeCount bumps from here are lane events (a gate
    /// stages the named board AFTER arming).
    func start() {
        lastChangeCount = board.changeCount
        armed = true
        // M114c (#2456): the lane-clipboard bus verb — the Integration
        // menu's toggle and --host-cmd-after dispatch on the same seam.
        HostIntCommands.registerLane(self)
    }

    /// The 250 ms poll step: drain CLIP_OUT (guest→host), then check the
    /// pasteboard (host→guest). Both halves run every tick while armed.
    ///
    /// M114c: while the session's clip bit is suspended the lane is a
    /// hard off — inbound records are refused `lane_disabled` (and
    /// deleted: a plant or an in-flight record cannot outlive the lane's
    /// own posture) and the pasteboard is left alone. On resume the
    /// changeCount baseline is re-taken: suspended-era host copies do
    /// NOT retro-deliver — the lane was off.
    func tick() {
        guard armed else { return }
        if session.isSuspended(HostInt.laneClip) {
            resumeBaseline = true
            guard let files = HostInt.records(laneDir: laneDir, tag: .clipOut) else { return }
            for (name, _) in files {
                HostInt.logRefuse(lane: "clip", reason: .laneDisabled)
                remove(laneDir.appendingPathComponent(name))
            }
            return
        }
        if resumeBaseline {
            resumeBaseline = false
            lastChangeCount = board.changeCount
        }
        drainClipOut(key: key)
        pollPasteboard(key: key)
    }

    private var resumeBaseline = false

    /// The `--host-clip-in` test hook: write text to the lane's pasteboard
    /// exactly as a user's host copy would — the next poll's changeCount
    /// bump carries it into a CLIP_IN. Deliberately does NOT set the echo
    /// guard (this is a genuine host change, not a lane reflection).
    /// M114c: injecting into a suspended lane refuses `lane_disabled` —
    /// nothing stages while the lane is off.
    func inject(_ text: String) -> Int {
        if session.isSuspended(HostInt.laneClip) {
            HostInt.logRefuse(lane: "clip", reason: .laneDisabled)
            return board.changeCount
        }
        board.clearContents()
        board.setString(text, forType: .string)
        return board.changeCount
    }

    // MARK: guest → host

    private func drainClipOut(key: Data) {
        guard let files = HostInt.records(laneDir: laneDir, tag: .clipOut) else { return }
        for (name, seq) in files {
            let url = laneDir.appendingPathComponent(name)
            guard let raw = try? Data(contentsOf: url) else {
                if ioLogged.insert(name).inserted {
                    HostInt.logRefuse(lane: "clip", reason: .ioError)
                }
                continue
            }
            ioLogged.remove(name)
            guard let rec = HostInt.decode(raw), rec.tag == .clipOut else {
                HostInt.logRefuse(lane: "clip", reason: .badRecord)
                remove(url)
                continue
            }
            guard HostInt.verify(rec, key: key) else {
                HostInt.logRefuse(lane: "clip", reason: .badMAC)
                remove(url)
                continue
            }
            guard rec.epoch == epoch else {
                HostInt.logRefuse(lane: "clip", reason: .staleEpoch)
                remove(url)
                continue
            }
            guard seq > lastClipOutSeq else {
                HostInt.logRefuse(lane: "clip", reason: .staleSeq)
                remove(url)
                continue
            }
            guard let text = String(data: rec.payload, encoding: .utf8) else {
                HostInt.logRefuse(lane: "clip", reason: .payloadNotText)
                remove(url)
                continue
            }
            board.clearContents()
            if !text.isEmpty {
                board.setString(text, forType: .string)
            }
            // Book our own write before the marker — the next changeCount
            // poll sees this bump and the guard swallows it once.
            echoGuard = text
            lastChangeCount = board.changeCount
            lastClipOutSeq = seq
            remove(url)
            FileHandle.standardOutput.write(Data("host-clip: out seq=\(seq) sha256=\(HostInt.sha256_8(rec.payload)) len=\(rec.payload.count)\n".utf8))
        }
    }

    // MARK: host → guest

    private func pollPasteboard(key: Data) {
        let cc = board.changeCount
        if cc == lastChangeCount { return }
        lastChangeCount = cc
        guard let text = board.string(forType: .string) else {
            // A bump with no string payload: the lane is UTF-8 text only.
            HostInt.logRefuse(lane: "clip", reason: .payloadNotText)
            return
        }
        if text == echoGuard {
            // Our own CLIP_OUT apply echoing back — swallow it once.
            echoGuard = nil
            return
        }
        // UTF-8-scalar-boundary truncation at the 512 lane bound.
        var payload = Data()
        var truncated = false
        for scalar in text.unicodeScalars {
            let enc = Array(String(scalar).utf8)
            if payload.count + enc.count > HostInt.payloadMax {
                truncated = true
                break
            }
            payload.append(contentsOf: enc)
        }
        if HostInt.outstanding(laneDir: laneDir, tag: .clipIn) >= HostInt.maxOutstanding {
            HostInt.logRefuse(lane: "clip", reason: .backpressured)
            return
        }
        let seq = clipInSeq + 1
        let flags: UInt8 = truncated ? 1 : 0
        guard let rec = HostInt.encode(tag: .clipIn, flags: flags, seq: seq, epoch: epoch, payload: payload, key: key),
              HostInt.publish(laneDir: laneDir, name: HostInt.recordName(tag: .clipIn, seq: seq), body: rec) else {
            HostInt.logRefuse(lane: "clip", reason: .ioError)
            return
        }
        clipInSeq = seq
        FileHandle.standardOutput.write(Data("host-clip: in seq=\(seq) sha256=\(HostInt.sha256_8(payload)) len=\(payload.count) truncated=\(truncated ? 1 : 0)\n".utf8))
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
