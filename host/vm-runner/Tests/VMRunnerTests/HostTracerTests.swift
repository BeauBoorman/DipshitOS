import XCTest
import VMAppKit

/// M157b (#2935): the tracer's class-A surface — the ADR 0043 line
/// parser over real trace lines (the `live-strace` render, embedded as
/// a string literal), malformed-candidate counting, the bounded ring,
/// the pid/syscall filters, and pause/resume/clear — all without a VM
/// or a window (the HostInspectorTests precedent: feed lines, read
/// rows).
final class HostTracerTests: XCTestCase {
    /// Real rendered records in the shape `just gate live-strace` puts
    /// on the serial feed — the decoded ring render plus the redacted
    /// and no-return tails and an out-of-table slot number.
    private let straceFeed = """
        [strace 7] sys_file_open(path="/host/TRACE.IN", len=14, flags=READ) = 0
        [strace 7] sys_file_read(fd=0, buf=0x4b3a00, len=4096) = 12
        [strace 7] sys_file_write(fd=0, buf=0x4b3a00, len=13) = 13
        [strace 7] sys_file_close(fd=0) = 0
        [strace 7] sys_pipe_read(fd=1, buf=0x4b3a00, len=4096) = 11
        [strace 7] sys_pipe_write(fd=1, buf=0x4b3a00, len=11) = 11
        [strace 7] sys_ping_poll() = 0
        [strace 7] sys_secret_get(<redacted>)
        [strace 7] sys_tty_net_auth(<redacted>)
        [strace 9] sys_99() = -ENOSYS
        [strace 7] sys_exit(status=0) = <no-return>
        """

    private func feed(_ tracer: HostTracer, _ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            tracer.ingest(line: String(line))
        }
    }

    // MARK: - the parser over real lines

    func testParsesRealStraceLinesIntoRows() {
        let tracer = HostTracer()
        feed(tracer, straceFeed)
        XCTAssertEqual(tracer.rows.count, 11)
        XCTAssertEqual(tracer.ingestedCount, 11)
        XCTAssertEqual(tracer.malformedCount, 0)

        let open = tracer.rows[0]
        XCTAssertEqual(open.sequence, 1)
        XCTAssertEqual(open.pid, 7)
        XCTAssertEqual(open.syscall, "sys_file_open")
        XCTAssertEqual(open.arguments, "path=\"/host/TRACE.IN\", len=14, flags=READ")
        XCTAssertEqual(open.result, "0")

        // A redacted record carries no ` = result` tail at all.
        let redacted = tracer.rows[7]
        XCTAssertEqual(redacted.syscall, "sys_secret_get")
        XCTAssertEqual(redacted.arguments, "<redacted>")
        XCTAssertEqual(redacted.result, "")

        let noReturn = tracer.rows[10]
        XCTAssertEqual(noReturn.syscall, "sys_exit")
        XCTAssertEqual(noReturn.arguments, "status=0")
        XCTAssertEqual(noReturn.result, "<no-return>")

        let unknownSlot = tracer.rows[9]
        XCTAssertEqual(unknownSlot.pid, 9)
        XCTAssertEqual(unknownSlot.syscall, "sys_99")
        XCTAssertEqual(unknownSlot.arguments, "")
        XCTAssertEqual(unknownSlot.result, "-ENOSYS")
    }

    /// The legacy monitor trace prints raw hex args/result and an
    /// em-dash for the never-returning exit — the same envelope.
    func testParsesLegacyMonitorTraceLines() {
        let tracer = HostTracer()
        feed(tracer, """
            [strace 4] sys_write(0x1, 0x4b3a00, 0xd) = 0xd
            [strace 4] sys_exit(0x7) = \u{2014}
            """)
        XCTAssertEqual(tracer.rows.count, 2)
        XCTAssertEqual(tracer.rows[0].arguments, "0x1, 0x4b3a00, 0xd")
        XCTAssertEqual(tracer.rows[0].result, "0xd")
        XCTAssertEqual(tracer.rows[1].result, "\u{2014}")
    }

    // MARK: - malformed candidates

    /// A `[strace ` candidate that fails the shape counts; a line that
    /// is not a candidate is ignored entirely.
    func testMalformedCandidatesAreCountedNeverFatal() {
        let tracer = HostTracer()
        feed(tracer, """
            [strace 7] sys_read(fd=0) = 3
            [strace ] sys_read(fd=0) = 3
            [strace x] sys_read(fd=0) = 3
            [strace 7] sys_read(fd=0) not-a-result
            [strace 7] not-a-syscall(fd=0) = 3
            [strace 7] sys_read(fd=0
            unrelated serial noise
            gosh: line echo [strace 7] sys_read(fd=0) = 3
            """)
        XCTAssertEqual(tracer.rows.count, 1)
        XCTAssertEqual(tracer.ingestedCount, 1)
        XCTAssertEqual(tracer.malformedCount, 5)
        // The noise lines are not candidates — they count nowhere.
        XCTAssertEqual(tracer.ingestedCount + tracer.malformedCount, 6)
    }

    // MARK: - the ring bound

    func testRingKeepsNewestRowsAndCountsEvictions() {
        let tracer = HostTracer(capacity: 4)
        for i in 1...7 {
            tracer.ingest(line: "[strace 7] sys_ping_poll(arg0=\(i)) = 0")
        }
        XCTAssertEqual(tracer.rows.count, 4)
        XCTAssertEqual(tracer.rows.map(\.sequence), [4, 5, 6, 7])
        XCTAssertEqual(tracer.ingestedCount, 7)
        XCTAssertEqual(tracer.droppedCount, 3)
    }

    // MARK: - filters

    func testPidAndSyscallFiltersConjoin() {
        let tracer = HostTracer()
        feed(tracer, straceFeed)

        tracer.pidFilterText = "7"
        XCTAssertEqual(tracer.filteredRows.count, 10)
        XCTAssertEqual(tracer.filterSummary, "pid:7")

        tracer.syscallFilter = "PIPE"
        XCTAssertEqual(tracer.filteredRows.map(\.syscall),
                       ["sys_pipe_read", "sys_pipe_write"])
        XCTAssertEqual(tracer.filterSummary, "pid:7,sys:PIPE")

        tracer.pidFilterText = ""
        tracer.syscallFilter = "secret"
        XCTAssertEqual(tracer.filteredRows.map(\.syscall), ["sys_secret_get"])
        XCTAssertEqual(tracer.filterSummary, "sys:secret")

        tracer.syscallFilter = ""
        XCTAssertEqual(tracer.filteredRows.count, 11)
        XCTAssertEqual(tracer.filterSummary, "-")
    }

    /// An unparseable pid narrows to nothing rather than silently
    /// widening back to every pid.
    func testUnparseablePidFilterMatchesNothing() {
        let tracer = HostTracer()
        feed(tracer, straceFeed)
        tracer.pidFilterText = "abc"
        XCTAssertTrue(tracer.filteredRows.isEmpty)
        XCTAssertEqual(tracer.filterSummary, "pid:abc")
    }

    // MARK: - pause / resume / clear

    func testPauseHoldsRowsResumeAppendsClearEmpties() {
        let tracer = HostTracer()
        tracer.ingest(line: "[strace 7] sys_ping_poll() = 0")
        tracer.paused = true
        tracer.ingest(line: "[strace 7] sys_ping_poll() = 0")
        tracer.ingest(line: "[strace 7] sys_file_close(fd=0) = 0")
        XCTAssertEqual(tracer.rows.count, 1)
        XCTAssertEqual(tracer.pausedCount, 2)
        // Malformed candidates still count while paused.
        tracer.ingest(line: "[strace nope")
        XCTAssertEqual(tracer.malformedCount, 1)
        tracer.paused = false
        tracer.ingest(line: "[strace 7] sys_ping_poll() = 0")
        XCTAssertEqual(tracer.rows.count, 2)
        // Held rows never took a sequence — the next append is seq 2.
        XCTAssertEqual(tracer.rows.map(\.sequence), [1, 2])
        XCTAssertEqual(tracer.ingestedCount, 4)

        tracer.clear()
        XCTAssertTrue(tracer.rows.isEmpty)
        XCTAssertEqual(tracer.clearedCount, 2)
        // Clear is a view operation: counters and sequences keep going.
        tracer.ingest(line: "[strace 7] sys_ping_poll() = 0")
        XCTAssertEqual(tracer.rows.map(\.sequence), [3])
        XCTAssertEqual(tracer.rows.count + tracer.pausedCount
                       + tracer.droppedCount + tracer.clearedCount,
                       tracer.ingestedCount)
    }

    func testStatsSummaryNamesTheCounters() {
        let tracer = HostTracer(capacity: 2)
        feed(tracer, straceFeed)
        tracer.ingest(line: "[strace junk")
        XCTAssertEqual(tracer.statsSummary,
                       "rows=2 dropped=9 malformed=1 skipped=0")
    }
}
