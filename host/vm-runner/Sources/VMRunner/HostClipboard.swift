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
// M124c (#2582) widened the lane from flat text to negotiated types: the
// dedicated CLIP_OUT_T / CLIP_IN_T tags carry `u8 mime_len|mime|blob`, and
// the pasteboard read negotiates by what is actually offered — image/png,
// text/uri-list (file URLs), text/html — before falling back to .string.
// Text stays on the original tags byte-identical; a text payload can never
// be misread as an envelope because the tag, not a magic prefix, names the
// shape.
//
// Bounds are the kernel clipboard's own (512 bytes): inbound text is cut
// on a scalar boundary and marked TRUNCATED, never silently cut; a typed
// item that cannot fit its envelope whole is refused too_large rather than
// delivered half-decodeable. The echo guards are symmetric: the runner
// skips the changeCount bump its own apply produced, and the seat skips
// its own CLIP_IN apply.
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
    private var clipInTSeq: UInt32 = 0      // next outbound CLIP_IN_T seq
    private var lastClipOutSeq: UInt32 = 0  // last consumed CLIP_OUT seq
    private var lastClipOutTSeq: UInt32 = 0 // last consumed CLIP_OUT_T seq
    private var lastChangeCount: Int = 0
    /// The emission-form payload the runner's last apply would re-encode
    /// to: text applies guard on the utf8 body, typed applies on the
    /// `mime_len|mime|blob` envelope — one compare covers both, the same
    /// shape a poll produces.
    private var echoPayload: Data?
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
            for tag in [HostInt.Tag.clipOut, .clipOutT] {
                guard let files = HostInt.records(laneDir: laneDir, tag: tag) else { continue }
                for (name, _) in files {
                    HostInt.logRefuse(lane: "clip", reason: .laneDisabled)
                    remove(laneDir.appendingPathComponent(name))
                }
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

    /// The M124c test hook (`--host-clip-in-file` + `--host-clip-in-mime`):
    /// write a TYPED item the way a real host copy would offer it — a PNG
    /// lands as .png data, a uri-list as file-URL objects, html as .html
    /// data + a .string fallback. Returns the pasteboard changeCount (or
    /// -1 when the file is unreadable/the mime is unnegotiable) so the
    /// caller's marker can prove the write happened.
    func injectTyped(path: String, mime: String) -> Int {
        if session.isSuspended(HostInt.laneClip) {
            HostInt.logRefuse(lane: "clip", reason: .laneDisabled)
            return board.changeCount
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            HostInt.logRefuse(lane: "clip", reason: .ioError)
            return -1
        }
        board.clearContents()
        switch mime {
        case "image/png":
            board.setData(data, forType: .png)
        case "text/uri-list":
            guard let urls = Self.uriListURLs(data), !urls.isEmpty else { return -1 }
            board.writeObjects(urls as [NSPasteboardWriting])
        case "text/html":
            board.setData(data, forType: .html)
            board.setString(String(decoding: data, as: UTF8.self), forType: .string)
        default:
            HostInt.logRefuse(lane: "clip", reason: .unsupportedKind)
            return -1
        }
        return board.changeCount
    }

    // MARK: guest → host

    private func drainClipOut(key: Data) {
        drainTag(.clipOut, lastSeq: &lastClipOutSeq, key: key)
        drainTag(.clipOutT, lastSeq: &lastClipOutTSeq, key: key)
    }

    private func drainTag(_ tag: HostInt.Tag, lastSeq: inout UInt32, key: Data) {
        guard let files = HostInt.records(laneDir: laneDir, tag: tag) else { return }
        for (name, seq) in files {
            let url = laneDir.appendingPathComponent(name)
            guard let raw = try? Data(contentsOf: url) else {
                if ioLogged.insert(name).inserted {
                    HostInt.logRefuse(lane: "clip", reason: .ioError)
                }
                continue
            }
            ioLogged.remove(name)
            guard let rec = HostInt.decode(raw), rec.tag == tag else {
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
            guard seq > lastSeq else {
                HostInt.logRefuse(lane: "clip", reason: .staleSeq)
                remove(url)
                continue
            }
            if tag == .clipOut {
                guard let text = String(data: rec.payload, encoding: .utf8) else {
                    HostInt.logRefuse(lane: "clip", reason: .payloadNotText)
                    remove(url)
                    continue
                }
                applyText(text)
            } else {
                guard let (mime, blob) = Self.decodeTyped(rec.payload) else {
                    HostInt.logRefuse(lane: "clip", reason: .badRecord)
                    remove(url)
                    continue
                }
                if !applyTyped(mime: mime, blob: blob) {
                    HostInt.logRefuse(lane: "clip", reason: .unsupportedKind)
                    remove(url)
                    continue
                }
            }
            // Book our own write before the marker — the next changeCount
            // poll sees this bump and the guard swallows it once. The
            // guard is the emission-form payload: what a fresh poll of the
            // board would re-encode to.
            echoPayload = rec.payload
            lastChangeCount = board.changeCount
            lastSeq = seq
            remove(url)
            if tag == .clipOut {
                FileHandle.standardOutput.write(Data("host-clip: out seq=\(seq) sha256=\(HostInt.sha256_8(rec.payload)) len=\(rec.payload.count)\n".utf8))
            } else {
                let mime = Self.decodeTyped(rec.payload)?.0 ?? "?"
                FileHandle.standardOutput.write(Data("host-clip: out seq=\(seq) mime=\(mime) sha256=\(HostInt.sha256_8(rec.payload)) len=\(rec.payload.count)\n".utf8))
            }
        }
    }

    /// Mirror a text CLIP_OUT to the pasteboard.
    private func applyText(_ text: String) {
        board.clearContents()
        if !text.isEmpty {
            board.setString(text, forType: .string)
        }
    }

    /// Mirror a typed CLIP_OUT_T: the mime negotiates which pasteboard
    /// type(s) get the bytes. False when the mime is one the host cannot
    /// offer honestly.
    private func applyTyped(mime: String, blob: Data) -> Bool {
        board.clearContents()
        switch mime {
        case "image/png":
            board.setData(blob, forType: .png)
        case "text/uri-list":
            guard let urls = Self.uriListURLs(blob), !urls.isEmpty else { return false }
            board.writeObjects(urls as [NSPasteboardWriting])
        case "text/html":
            board.setData(blob, forType: .html)
            board.setString(String(decoding: blob, as: UTF8.self), forType: .string)
        default:
            // An image/* the host cannot name, octet-stream — declare the
            // raw type string so a matching paste still sees SOMETHING;
            // never pretend it is text.
            board.setData(blob, forType: NSPasteboard.PasteboardType(mime))
        }
        return true
    }

    // MARK: host → guest

    /// uri_list -> [NSURL fileURL]: the RFC 2483 read — every non-empty
    /// line a file:// URI. nil when no line parses (caller treats it as a
    /// mislabel, not an empty list).
    static func uriListURLs(_ data: Data) -> [NSURL]? {
        let text = String(decoding: data, as: UTF8.self)
        var urls: [NSURL] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            guard let u = URL(string: line), u.scheme != nil else { return nil }
            urls.append(u as NSURL)
        }
        return urls.isEmpty ? nil : urls
    }

    /// The `mime_len|mime|blob` envelope — the mirror of the Go side's
    /// hostint.EncodeTypedClip / DecodeTypedClip.
    static func encodeTyped(mime: String, blob: Data) -> Data? {
        let m = mime.utf8
        guard !m.isEmpty, m.count <= 24, 1 + m.count + blob.count <= HostInt.payloadMax else { return nil }
        var out = Data([UInt8(m.count)])
        out.append(contentsOf: m)
        out.append(blob)
        return out
    }

    static func decodeTyped(_ payload: Data) -> (String, Data)? {
        guard payload.count >= 2 else { return nil }
        let ml = Int(payload[payload.startIndex])
        guard ml > 0, ml <= 24, payload.count > 1 + ml else { return nil }
        let mime = String(decoding: payload[payload.startIndex + 1 ..< payload.startIndex + 1 + ml], as: UTF8.self)
        return (mime, payload.subdata(in: payload.startIndex + 1 + ml ..< payload.endIndex))
    }

    /// Read the pasteboard's offered types in negotiation order and return
    /// the record to publish: (tag, payload). nil when nothing the lane
    /// carries is on the board.
    private func readBoard() -> (HostInt.Tag, Data)? {
        if let png = board.data(forType: .png), !png.isEmpty,
           let env = Self.encodeTyped(mime: "image/png", blob: png) {
            return (.clipInT, env)
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL], !urls.isEmpty {
            let lines = urls.compactMap { $0.absoluteString }.joined(separator: "\n")
            if let env = Self.encodeTyped(mime: "text/uri-list", blob: Data(lines.utf8)) {
                return (.clipInT, env)
            }
        }
        if let html = board.data(forType: .html), !html.isEmpty,
           let env = Self.encodeTyped(mime: "text/html", blob: html) {
            return (.clipInT, env)
        }
        return nil
    }

    private func pollPasteboard(key: Data) {
        let cc = board.changeCount
        if cc == lastChangeCount { return }
        lastChangeCount = cc

        if let (tag, payload) = readBoard() {
            if payload == echoPayload {
                // Our own apply echoing back — swallow it once.
                echoPayload = nil
                return
            }
            emit(key: key, tag: tag, payload: payload, truncated: false)
            return
        }

        guard let text = board.string(forType: .string) else {
            // A bump with no string payload: nothing the lane carries.
            HostInt.logRefuse(lane: "clip", reason: .payloadNotText)
            return
        }
        let body = Data(text.utf8)
        if body == echoPayload {
            // Our own CLIP_OUT apply echoing back — swallow it once.
            echoPayload = nil
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
        emit(key: key, tag: .clipIn, payload: payload, truncated: truncated)
    }

    private func emit(key: Data, tag: HostInt.Tag, payload: Data, truncated: Bool) {
        let outTag = tag
        let seqField = outTag == .clipIn ? clipInSeq : clipInTSeq
        if HostInt.outstanding(laneDir: laneDir, tag: outTag) >= HostInt.maxOutstanding {
            HostInt.logRefuse(lane: "clip", reason: .backpressured)
            return
        }
        let seq = seqField + 1
        let flags: UInt8 = truncated ? 1 : 0
        guard let rec = HostInt.encode(tag: outTag, flags: flags, seq: seq, epoch: epoch, payload: payload, key: key),
              HostInt.publish(laneDir: laneDir, name: HostInt.recordName(tag: outTag, seq: seq), body: rec) else {
            HostInt.logRefuse(lane: "clip", reason: .ioError)
            return
        }
        if outTag == .clipIn { clipInSeq = seq } else { clipInTSeq = seq }
        if outTag == .clipIn {
            FileHandle.standardOutput.write(Data("host-clip: in seq=\(seq) sha256=\(HostInt.sha256_8(payload)) len=\(payload.count) truncated=\(truncated ? 1 : 0)\n".utf8))
        } else {
            let mime = Self.decodeTyped(payload)?.0 ?? "?"
            FileHandle.standardOutput.write(Data("host-clip: in seq=\(seq) mime=\(mime) sha256=\(HostInt.sha256_8(payload)) len=\(payload.count) truncated=\(truncated ? 1 : 0)\n".utf8))
        }
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
