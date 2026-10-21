import Foundation
import VMPostmortem

/// M114d (#2457, index #2447): the inspector drawer's MODEL — the part
/// every surface shares and the part `swift test` pins. The session
/// window's drawer view renders it; the `inspector`/`send-serial` bus
/// verbs act on it; the runner's serial polls feed it. It lives in the
/// model precisely so a headless `--host-cmd-after` run exercises the
/// identical seam the open drawer does (index thesis 1).
///
/// One instance per run, owned by main.swift, passed into HostApplication
/// when a session window exists. All access is main-queue (the polls and
/// the bus both are), so it takes no lock — the HostCommandBus precedent.
///
/// The HostInt counters are OBSERVED counters: guest-side `hostint` lines
/// arrive on the serial stream itself, and the runner forwards the
/// `host-*:`/`host-int:` marker lines it prints itself plus a lane-dir
/// seq scan. Refusals a lane driver logs internally reach runner stdout
/// only — a limit the counter names honestly rather than a gap it
/// papers over.
public final class HostInspector {
    /// The ring bound: the tail keeps the newest `capacity` lines and
    /// counts the evictions in `droppedCount`.
    public let capacity: Int

    /// M157b (#2935): the ADR 0043 tracer — a sibling ring fed by the
    /// same ingest: every complete serial line the tail keeps also goes
    /// through the tracer's `[strace …]` parse. It needs no runner hook
    /// of its own — the feed is already this model's.
    public let tracer = HostTracer()

    public init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
        // A tracer mutation (new rows, a filter edit, pause/clear)
        // repaints on the model's existing cadence.
        tracer.onChange = { [weak self] in self?.onChange?() }
    }

    // MARK: Serial tail — the bounded ring buffer + search/filter.

    /// The buffered lines, oldest first. Bounded by `capacity`.
    public private(set) var lines: [String] = []
    /// Total complete lines ever ingested (lines.count + droppedCount).
    public private(set) var ingestedCount = 0
    /// Lines evicted by the ring bound.
    public private(set) var droppedCount = 0

    /// The live search/filter string the drawer's field edits.
    public var filter = "" { didSet { changed() } }

    /// The tail as the drawer shows it: every line, or the
    /// case-insensitive substring match while a filter is set.
    public var filteredLines: [String] {
        guard !filter.isEmpty else { return lines }
        return lines.filter { $0.range(of: filter, options: .caseInsensitive) != nil }
    }

    /// How many characters of the serial snapshot have been emitted as
    /// complete lines. The polls re-read the WHOLE log each tick, so
    /// ingest is incremental by offset: a call processes only the bytes
    /// appended since the last one, and a line is emitted only once its
    /// newline arrives (the trailing partial waits for more text).
    private var consumed = 0

    /// Feed the newest serial-log snapshot. Shrinking input (a rotated or
    /// rewritten log) restarts the offset rather than straddling two
    /// different texts.
    public func ingest(serialText text: String) {
        if text.count < consumed { consumed = 0 }
        let fresh = text.dropFirst(consumed)
        // Emit only through the LAST newline: a trailing fragment stays
        // un-consumed — the next ingest re-reads it with growth appended.
        guard let nl = fresh.lastIndex(of: "\n") else { return }
        consumed += fresh.distance(from: fresh.startIndex, to: fresh.index(after: nl))
        var sawAny = false
        // The region before the last newline splits into complete lines
        // (an empty element between two newlines is a real empty line).
        for line in fresh[fresh.startIndex..<nl].split(separator: "\n", omittingEmptySubsequences: false) {
            var line = line
            if line.hasSuffix("\r") { line.removeLast() }
            let text = String(line)
            lines.append(text)
            ingestedCount += 1
            sawAny = true
            scanHostIntLine(text)
            tracer.ingest(line: text)
        }
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        droppedCount = ingestedCount - lines.count
        if sawAny { changed() }
    }

    // MARK: Command injector — the send-serial verb's write path.

    /// The armed line: the drawer's input field edits it live, and
    /// `--host-serial-send` seeds it headlessly. One line — the card's
    /// "single-line command injector", not a terminal.
    public var inputLine = ""

    /// The runner-provided write end of the console pipe. Receives the
    /// line text (no terminator — the sink appends the newline, the same
    /// shape --script forwards). nil when no guest RX path exists; the
    /// verb then receipts `disabled` rather than writing into a void.
    public var serialSink: ((String) -> Bool)?

    /// Lines successfully injected this run — the `sent=N` receipt
    /// detail and the "the drawer model saw it" bookkeeping.
    public private(set) var sentCount = 0
    public private(set) var lastSent: String?

    /// Write `inputLine` into the console pipe. False when no sink is
    /// armed or the write failed — the verb receipts `disabled` for the
    /// former, `failed` for the latter.
    @discardableResult
    public func inject() -> Bool {
        guard let sink = serialSink, sink(inputLine) else { return false }
        sentCount += 1
        lastSent = inputLine
        changed()
        return true
    }

    /// Whether the tail has seen the last injected line come back (the
    /// guest's console echo wraps it — `gosh: line echo …` — so a plain
    /// containment check is the honest test). The `saw=` receipt detail.
    public var sawLastSent: Bool {
        guard let sent = lastSent, !sent.isEmpty else { return false }
        return lines.contains { $0.contains(sent) }
    }

    // MARK: HostInt counters — seq high-water + refusal count, observed.

    /// Highest `seq=` observed on hostint-shaped lines (serial guest
    /// markers, runner-forwarded `host-*:` markers, lane-dir scans).
    public private(set) var hostIntSeq: UInt32 = 0
    /// Refusal lines observed: `…refuse…` or a `reason=` verdict on a
    /// hostint-shaped line.
    public private(set) var hostIntRefusals = 0

    /// A host-side marker line the runner prints and forwards verbatim —
    /// `host-clip: in seq=…`, `host-int: refuse …` — counted by the same
    /// rules as serial guest lines.
    public func noteHostMarker(_ line: String) {
        scanHostIntLine(line)
    }

    /// The lane-directory feed: a record filename's seq counts even if
    /// the file is consumed before the next scan (high-water never
    /// regresses).
    public func noteHostIntSeq(_ seq: UInt32) {
        if seq > hostIntSeq { hostIntSeq = seq }
    }

    /// The drawer's one-line HostInt summary.
    public var hostIntSummary: String {
        "HostInt seq=\(hostIntSeq) refusals=\(hostIntRefusals)"
    }

    private func scanHostIntLine(_ line: String) {
        // HostInt-shaped: guest `hostint …` markers or the runner's own
        // `host-clip:`/`host-drop:`/`host-notify:`/`host-int:` lines.
        let shaped = line.contains("hostint ")
            || line.contains("host-clip:") || line.contains("host-drop:")
            || line.contains("host-notify:") || line.contains("host-int:")
        guard shaped else { return }
        if line.contains("refuse") || line.contains("reason=") {
            hostIntRefusals += 1
        }
        if let range = line.range(of: "seq=") {
            var digits = ""
            for ch in line[range.upperBound...] {
                guard ch.isNumber else { break }
                digits.append(ch)
            }
            if let seq = UInt32(digits) { noteHostIntSeq(seq) }
        }
    }

    // MARK: Postmortem — the in-window card on stop/crash.

    /// Set on VM end; the drawer renders it and opens itself so a dead
    /// guest is never a silently empty window.
    public private(set) var postmortem: PostmortemCard?

    /// M120e (#2562): the receipt sink — the `host-inspector: postmortem`
    /// and (M157b #2935) `host-inspector: trace` lines a live leg greps,
    /// on the same stdout stream the bus's `host-ui:` receipts and the
    /// models' `host-*:` lines share (the HostMachineModel emit
    /// precedent).
    public var emit: (String) -> Void = {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }

    /// M120e (#2562): the first end noted wins. The card is a capture of
    /// the moment the VM left running; the polls' repeated observation of
    /// a still-dead VM is not a new end — it must not re-emit the
    /// receipt, re-open a drawer the operator closed, or churn the view.
    public func noteStop(_ card: PostmortemCard) {
        guard postmortem == nil else { return }
        postmortem = card
        isOpen = true
        emit("host-inspector: postmortem ending=\(card.ending.rawValue) state=\(card.state) open=1")
        changed()
    }

    // MARK: Drawer state + receipts.

    /// Open/closed — the `inspector` verb toggles it in every mode: the
    /// session's registration also slides the real split pane; headless
    /// it is still honest model state a gate can read in the receipt.
    /// The flip is the verb's only model action, so it is also the M157b
    /// (#2935) trace receipt's moment: `host-inspector: trace rows=<n>
    /// filter=<f>` on the same stream the postmortem receipt rides.
    public var isOpen = false {
        didSet {
            emit("host-inspector: trace rows=\(tracer.rows.count) filter=\(tracer.filterSummary)")
            changed()
        }
    }

    /// The `inspector` verb's receipt tail: `open=N tail=N saw=N` — the
    /// drawer's live state, not just that an action ran (the M114b
    /// capture=on|off precedent).
    public var receiptDetail: String {
        "open=\(isOpen ? 1 : 0) tail=\(lines.count) saw=\(sawLastSent ? 1 : 0)"
    }

    /// Model → view notification. Called on the main queue after each
    /// mutation batch (one per ingest call, not per line).
    public var onChange: (() -> Void)?

    private func changed() { onChange?() }
}
