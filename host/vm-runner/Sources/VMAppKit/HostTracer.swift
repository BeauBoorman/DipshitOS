import Foundation

/// M157b (#2935, index #2909): the tracer MODEL — parses the ADR 0043
/// trace lines out of the inspector's serial feed into a bounded ring
/// the drawer's Trace tab renders and the `inspector` verb receipts.
/// It is a sibling of the serial tail inside HostInspector: the same
/// `ingest(serialText:)` feed hands it each complete line, so the
/// class-A seam is the identical one the tail tests use — feed lines,
/// read rows, never touch AppKit.
///
/// The line shape is the kernel/STRACE shared envelope — both the
/// legacy monitor trace (`[strace 5] sys_write(0x1, 0x4b3a00, 0xd) =
/// 0xd`, exit's `= —`) and the ring's decoded render
/// (`[strace 5] sys_file_open(path="…", len=14, flags=READ) = 0`,
/// `[strace 5] sys_secret_get(<redacted>)`) fit:
///
///     [strace <pid>] sys_<name>(<args>)[ = <result>]
///
/// A line starting with `[strace ` that fails the shape is a MALFORMED
/// candidate — counted, never fatal. Any other line is not the
/// tracer's and is ignored entirely.
///
/// Like HostInspector, all access is main-queue, so it takes no lock.
public final class HostTracer {
    /// One decoded row — the ring's element and the tab's display unit.
    public struct Row: Equatable {
        /// 1-based arrival index across the whole run. Sequences are
        /// consumed at append time and never reused: eviction and
        /// clear leave honest gaps rather than renumbering the past.
        public let sequence: UInt64
        public let pid: UInt64
        /// The rendered name — `sys_file_open`, `sys_99` for an
        /// out-of-table slot — kept verbatim, never decoded twice.
        public let syscall: String
        /// The text between the parens, verbatim — `path="…", len=14`
        /// or `<redacted>`.
        public let arguments: String
        /// `0`, `-EINVAL`, `<no-return>`, `—`, or "" — a redacted line
        /// carries no result tail.
        public let result: String
    }

    /// The ring bound: the tab keeps the newest `capacity` rows and
    /// counts the evictions in `droppedCount`.
    public let capacity: Int

    public init(capacity: Int = 2048) {
        self.capacity = max(1, capacity)
    }

    // MARK: The ring.

    /// The buffered rows, oldest first. Bounded by `capacity`.
    public private(set) var rows: [Row] = []
    /// Candidate lines parsed successfully — appended, evicted, held
    /// by pause or discarded by clear: every well-formed `[strace …]`
    /// line the feed saw.
    public private(set) var ingestedCount = 0
    /// Rows evicted by the ring bound.
    public private(set) var droppedCount = 0
    /// Rows discarded by `clear()`.
    public private(set) var clearedCount = 0
    /// Well-formed rows skipped while paused.
    public private(set) var pausedCount = 0
    /// `[strace ` candidates that failed the shape — counted, never
    /// fatal.
    public private(set) var malformedCount = 0

    private var nextSequence: UInt64 = 1

    /// Feed ONE complete serial line. The inspector's ingest calls this
    /// per emitted line; non-`[strace ` lines return early.
    public func ingest(line: String) {
        guard line.hasPrefix("[strace ") else { return }
        guard let parsed = Self.parse(line) else {
            malformedCount += 1
            changed()
            return
        }
        ingestedCount += 1
        if paused {
            pausedCount += 1
            changed()
            return
        }
        rows.append(Row(sequence: nextSequence, pid: parsed.pid,
                        syscall: parsed.syscall, arguments: parsed.arguments,
                        result: parsed.result))
        nextSequence += 1
        if rows.count > capacity {
            let evict = rows.count - capacity
            rows.removeFirst(evict)
            droppedCount += evict
        }
        changed()
    }

    /// The parser, pure for the class-A tests. Returns nil for a
    /// malformed candidate — the caller decides whether nil counts.
    static func parse(_ line: String)
        -> (pid: UInt64, syscall: String, arguments: String, result: String)? {
        guard line.hasPrefix("[strace "), let close = line.firstIndex(of: "]")
        else { return nil }
        let pidStart = line.index(line.startIndex, offsetBy: "[strace ".count)
        guard pidStart < close, let pid = UInt64(line[pidStart..<close]) else { return nil }
        let rest = line[line.index(after: close)...]
        guard rest.hasPrefix(" ") else { return nil }
        let body = rest.dropFirst()
        guard let open = body.firstIndex(of: "(") else { return nil }
        let name = body[..<open]
        guard name.hasPrefix("sys_") else { return nil }
        // The record's closing paren is the LAST ')' on the line: a
        // captured string can itself hold ')' (the guest renderer
        // escapes, never strips it) while the result tail never has
        // one.
        guard let lastParen = body.lastIndex(of: ")"), lastParen > open else { return nil }
        let args = body[body.index(after: open)..<lastParen]
        var result = ""
        let tail = body[body.index(after: lastParen)...]
        if !tail.isEmpty {
            guard tail.hasPrefix(" = ") else { return nil }
            result = String(tail.dropFirst(3))
        }
        return (pid, String(name), String(args), result)
    }

    // MARK: Filter / pause / clear — the tab's controls.

    /// The pid filter's raw field text. A non-empty value restricts
    /// `filteredRows` to that pid; unparseable text matches nothing
    /// rather than silently widening back to every pid.
    public var pidFilterText = "" { didSet { changed() } }

    /// Case-insensitive substring on the syscall name.
    public var syscallFilter = "" { didSet { changed() } }

    /// While set, well-formed lines are counted in `pausedCount`
    /// instead of appended — the ring freezes, the feed keeps flowing.
    public var paused = false { didSet { changed() } }

    /// The rows the tab shows: every row, or the pid + syscall
    /// conjunction while either filter is set.
    public var filteredRows: [Row] {
        guard !pidFilterText.isEmpty || !syscallFilter.isEmpty else { return rows }
        return rows.filter { row in
            if !pidFilterText.isEmpty, UInt64(pidFilterText) != row.pid { return false }
            if !syscallFilter.isEmpty,
               row.syscall.range(of: syscallFilter, options: .caseInsensitive) == nil {
                return false
            }
            return true
        }
    }

    /// Empty the ring. Sequences keep climbing — clear is a view
    /// operation, not a new feed.
    public func clear() {
        clearedCount += rows.count
        rows.removeAll()
        changed()
    }

    /// The `filter=<f>` word of the `host-inspector: trace` receipt —
    /// `-` when unfiltered, else the active `pid:`/`sys:` conjunction.
    public var filterSummary: String {
        var parts: [String] = []
        if !pidFilterText.isEmpty { parts.append("pid:\(pidFilterText)") }
        if !syscallFilter.isEmpty { parts.append("sys:\(syscallFilter)") }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    /// The tab's one-line counter row.
    public var statsSummary: String {
        "rows=\(rows.count) dropped=\(droppedCount) malformed=\(malformedCount) skipped=\(pausedCount)"
    }

    /// Model → view notification. The inspector forwards its own
    /// `onChange` here so a tracer mutation repaints the drawer on the
    /// same cadence a serial ingest does.
    public var onChange: (() -> Void)?

    private func changed() { onChange?() }
}
