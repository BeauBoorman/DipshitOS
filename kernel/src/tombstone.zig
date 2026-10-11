//! VirelaiOS crash tombstone engine (Arc5 issue #243).
//!
//! Writes crash information to `crash/<pid>-<name>.txt` on the host share
//! when a process exits with status 139 (guard page fault) or other
//! non-zero unexpected exits. Bounded: max 8 tombstones, drop-oldest on
//! overflow. M34 HF6 (issue #740): the DATA partition is gone — the file
//! channel (`--cvc-file`) is the tombstone destination.
//!
//! Tombstone contents:
//!   - Process name, PID, exit status
//!   - Fault address (if status 139)
//!   - Last 512 bytes of serial output (from the console ring buffer)
//!   - Timestamp (tick count)
//!
//! No libc, no POSIX, bounded BSS storage, no heap allocation.

const std = @import("std");
const symbol = @import("symbol.zig");
const virtio_file = @import("virtio_file.zig");
const trust = @import("trust.zig"); // M50 TS2 (#1136, ADR 0024 D4): the kernel-actor gate for crash writes
const timer = @import("timer.zig");
const console = @import("console.zig");

/// Maximum number of tombstones to keep (drop-oldest on overflow).
pub const max_tombstones: usize = 8;

/// Directory for crash tombstones on the host share (share-relative).
pub const crash_dir = "crash";

/// Maximum size of a tombstone file content.
pub const tombstone_max_bytes: usize = 1024;

/// A single tombstone record.
pub const Tombstone = struct {
    pid: u64,
    name: [32]u8 = @as([32]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    exit_status: u64,
    fault_addr: u64 = 0,
    /// Faulting PC (ELR) — the code address used for symbol resolution.
    pc: u64 = 0,
    tick: u64,
    serial_snapshot: [512]u8 = @as([512]u8, @splat(@as(u8, 0))),
    serial_len: usize = 0,
    /// "(in name+0xoffset)" note resolved via the kernel symbol table
    /// (M22 D3, issue #326). Empty when nothing matched.
    sym_note: [96]u8 = @as([96]u8, @splat(@as(u8, 0))),
    sym_note_len: usize = 0,
};

/// Ring buffer of tombstones (drop-oldest on overflow).
var tombstones: [max_tombstones]Tombstone = undefined;
var tombstone_head: usize = 0;
var tombstone_count: usize = 0;

/// M97c #2098: bound fault evidence. A fault-status receipt must carry the
/// EXITING task's own far/pc — never the newest entry of the shared fault
/// ring (which may be another process's crash). The exception layer drops
/// a note here right before the fault dispatcher reaps the task;
/// `record` consumes the note keyed on the exiting pid, and a fault-status
/// receipt with no bound note records ZERO fault fields — `sys_exit(139)`
/// from EL0 can no longer stamp a crash receipt with a sibling's far/pc.
const max_fault_evidence: usize = 8;

const FaultEvidence = struct {
    pid: u64,
    far: u64,
    pc: u64,
};

var evidence: [max_fault_evidence]FaultEvidence = undefined;
var evidence_used: [max_fault_evidence]bool = @as([max_fault_evidence]bool, @splat(@as(bool, false)));
var evidence_cursor: usize = 0;

/// Exception-context note: task `pid` just took an EL0 fault at far/pc.
/// Called from the exception dispatch path right before the fault
/// dispatcher reaps the task — pure BSS, no allocation.
pub fn note_fault(pid: u64, far: u64, pc: u64) void {
    // A re-fault on the same pid refreshes its note in place.
    for (&evidence, 0..) |*e, i| {
        if (evidence_used[i] and e.pid == pid) {
            e.* = .{ .pid = pid, .far = far, .pc = pc };
            return;
        }
    }
    for (&evidence, 0..) |*e, i| {
        if (!evidence_used[i]) {
            e.* = .{ .pid = pid, .far = far, .pc = pc };
            evidence_used[i] = true;
            return;
        }
    }
    // Full: drop the slot the cursor names — the table is a bound, never a
    // block.
    evidence[evidence_cursor] = .{ .pid = pid, .far = far, .pc = pc };
    evidence_cursor = (evidence_cursor + 1) % max_fault_evidence;
}

/// Consume the note bound to `pid`, if any.
fn take_evidence(pid: u64) ?FaultEvidence {
    for (&evidence, 0..) |*e, i| {
        if (evidence_used[i] and e.pid == pid) {
            evidence_used[i] = false;
            return e.*;
        }
    }
    return null;
}

/// Initialize the tombstone subsystem.
pub fn init() void {
    tombstone_head = 0;
    tombstone_count = 0;
    evidence_used = @as([max_fault_evidence]bool, @splat(@as(bool, false)));
    evidence_cursor = 0;
}

/// Record a tombstone for a crashed process.
/// `name` is the process name (e.g. "GUARD.BIN").
/// `pid` is the process ID.
/// `status` is the exit status (139 for guard page fault).
/// `fault_addr` is the fault address (only meaningful for status 139).
/// `serial_snapshot` is the last 512 bytes of serial output.
/// `serial_len` is the actual length of the snapshot.
pub fn record(
    name: []const u8,
    pid: u64,
    status: u64,
    fault_addr: u64,
    pc: u64,
    serial_snapshot: []const u8,
    serial_len: usize,
) void {
    // M97c #2098: bind the fault fields to THIS pid's evidence note, which
    // the exception layer drops right before the dispatcher reaps a fault.
    // The kernel-reserved fault statuses (139 = fault, 140 = memory-limit —
    // literals: scheduler owns the names) take their far/pc ONLY from that
    // note: a forged `sys_exit(139)` reaches here with whatever the shared
    // fault ring held — possibly another process's crash — and without a
    // bound note the receipt's fault fields stay zero. The receipt itself
    // still records: the caller persists `get(count() - 1)` unconditionally
    // and the status-forge refusal is the syscall-side half of #2098.
    var bound_fault_addr = fault_addr;
    var bound_pc = pc;
    const evidence_note = take_evidence(pid);
    if (status == 139 or status == 140) {
        if (evidence_note) |e| {
            bound_fault_addr = e.far;
            bound_pc = e.pc;
        } else {
            bound_fault_addr = 0;
            bound_pc = 0;
        }
    }

    // Drop oldest if full
    if (tombstone_count == max_tombstones) {
        tombstone_head = (tombstone_head + 1) % max_tombstones;
        tombstone_count -= 1;
    }

    const idx = (tombstone_head + tombstone_count) % max_tombstones;
    var t = &tombstones[idx];
    t.* = .{
        .pid = pid,
        .exit_status = status,
        .fault_addr = bound_fault_addr,
        .pc = bound_pc,
        .tick = timer.ticks,
    };

    // M22 D3 (issue #326): name the faulting code. The PC anchors CODE
    // symbols (BRK faults carry far=0); fall back to the fault address for
    // data aborts whose PC sits outside every known range.
    if (status == 139) { // reserved_fault_status (kept literal: scheduler owns the name)
        const m = if (bound_pc != 0) symbol.lookup(bound_pc) else null;
        const chosen = m orelse symbol.lookup(bound_fault_addr);
        if (chosen) |hit| {
            const note = "(in ";
            @memcpy(t.sym_note[0..note.len], note);
            var npos = note.len;
            const take_name = @min(hit.name.len, t.sym_note.len - npos - 24);
            @memcpy(t.sym_note[npos..][0..take_name], hit.name[0..take_name]);
            npos += take_name;
            const mid = "+0x";
            @memcpy(t.sym_note[npos..][0..mid.len], mid);
            npos += mid.len;
            npos += write_hex(t.sym_note[npos..], hit.offset);
            if (npos < t.sym_note.len) {
                t.sym_note[npos] = ')';
                npos += 1;
            }
            t.sym_note_len = npos;
        }
    }

    // Copy name (truncate to 31 chars + NUL)
    const name_len = @min(name.len, 31);
    @memcpy(t.name[0..name_len], name[0..name_len]);
    t.name_len = name_len;

    // Copy serial snapshot
    const snap_len = @min(serial_snapshot.len, serial_len, 512);
    @memcpy(t.serial_snapshot[0..snap_len], serial_snapshot[0..snap_len]);
    t.serial_len = snap_len;

    tombstone_count += 1;
}

/// Get the number of recorded tombstones.
pub fn count() usize {
    return tombstone_count;
}

/// Get a tombstone by index (0 = oldest).
pub fn get(index: usize) ?*const Tombstone {
    if (index >= tombstone_count) return null;
    const actual_idx = (tombstone_head + index) % max_tombstones;
    return &tombstones[actual_idx];
}

/// Format a tombstone into a buffer for writing to disk.
/// Returns the number of bytes written.
pub fn format_tombstone(t: *const Tombstone, out: []u8) usize {
    var pos: usize = 0;

    // Header
    const header = "VirelaiOS Crash Tombstone\n========================\n";
    if (header.len <= out.len) {
        @memcpy(out[0..header.len], header);
        pos = header.len;
    }

    // Process info
    pos += write_line(out[pos..], "Process: ");
    pos += write_bytes(out[pos..], t.name[0..t.name_len]);
    pos += write_line(out[pos..], "\n");

    pos += write_line(out[pos..], "PID: ");
    pos += write_u64(out[pos..], t.pid);
    pos += write_line(out[pos..], "\n");

    pos += write_line(out[pos..], "Exit Status: ");
    pos += write_u64(out[pos..], t.exit_status);
    pos += write_line(out[pos..], "\n");

    if (t.exit_status == 139) {
        pos += write_line(out[pos..], "Fault Address: 0x");
        pos += write_hex(out[pos..], t.fault_addr);
        pos += write_line(out[pos..], "\n");
    }

    pos += write_line(out[pos..], "Tick: ");
    pos += write_u64(out[pos..], t.tick);
    pos += write_line(out[pos..], "\n");

    if (t.sym_note_len > 0) {
        pos += write_line(out[pos..], "Symbol: ");
        pos += write_bytes(out[pos..], t.sym_note[0..t.sym_note_len]);
        pos += write_line(out[pos..], "\n");
    }

    // Serial snapshot
    if (t.serial_len > 0) {
        pos += write_line(out[pos..], "\n--- Last Serial Output ---\n");
        const snap = t.serial_snapshot[0..t.serial_len];
        for (snap) |c| {
            if (pos < out.len) {
                out[pos] = c;
                pos += 1;
            }
        }
        pos += write_line(out[pos..], "\n--- End Serial Output ---\n");
    }

    return pos;
}

/// Write a tombstone to the host share (share-relative `crash/<pid>-<name>.txt`).
/// Returns true on success. M34 HF6 (issue #740): the DATA partition is
/// gone — write_whole rides the queue-5 file channel (open-create +
/// truncate + chunked write + close, no allocation).
pub fn write_to_disk(t: *const Tombstone) bool {
    if (!virtio_file.available()) return false;

    // Format filename: crash/<pid>-<name>.txt
    var filename_buf: [64]u8 = undefined;
    var pos: usize = 0;

    // crash/
    const prefix = "crash/";
    @memcpy(filename_buf[0..prefix.len], prefix);
    pos = prefix.len;

    // PID
    pos += write_u64(filename_buf[pos..], t.pid);

    // -
    if (pos < filename_buf.len) {
        filename_buf[pos] = '-';
        pos += 1;
    }

    // Name
    for (t.name[0..t.name_len]) |c| {
        if (pos < filename_buf.len and c != 0) {
            filename_buf[pos] = c;
            pos += 1;
        }
    }

    // .txt
    const suffix = ".txt";
    if (pos + suffix.len <= filename_buf.len) {
        @memcpy(filename_buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
    }

    const filename = filename_buf[0..pos];

    // Format tombstone content
    var content_buf: [tombstone_max_bytes]u8 = undefined;
    const content_len = format_tombstone(t, &content_buf);

    // Write file through the host channel
    // M50 TS2 (ADR 0024 D4): the kernel-actor gate (secret-class paths deny).
    if (trust.check(trust.kernel_actor(), .host, filename, .write) != .allow) return false;
    const result = virtio_file.write_whole(filename, content_buf[0..content_len]);

    return result == virtio_file.st_ok;
}

/// List tombstone filenames for the crash monitor command.
/// Returns the number of tombstones listed.
pub fn list_to_console(con: console.Console) usize {
    var listed: usize = 0;
    var i: usize = 0;
    while (i < tombstone_count) : (i += 1) {
        if (get(i)) |t| {
            // Print: <index>: PID=<pid> <name> status=<status> tick=<tick>
            con.puts("  ");
            con.print_u64(i);
            con.puts(": PID=");
            con.print_u64(t.pid);
            con.puts(" ");
            con.puts(t.name[0..t.name_len]);
            con.puts(" status=");
            con.print_u64(t.exit_status);
            con.puts(" tick=");
            con.print_u64(t.tick);
            if (t.sym_note_len > 0) {
                con.puts(" ");
                con.puts(t.sym_note[0..t.sym_note_len]);
            }
            con.puts("\n");
            listed += 1;
        }
    }
    return listed;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn write_line(out: []u8, s: []const u8) usize {
    const len = @min(s.len, out.len);
    @memcpy(out[0..len], s[0..len]);
    return len;
}

fn write_bytes(out: []u8, s: []const u8) usize {
    const len = @min(s.len, out.len);
    @memcpy(out[0..len], s[0..len]);
    return len;
}

fn write_u64(out: []u8, val: u64) usize {
    if (val == 0) {
        if (out.len > 0) out[0] = '0';
        return 1;
    }
    var buf: [20]u8 = undefined;
    var v = val;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        buf[len] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    // Reverse and copy
    var i: usize = 0;
    while (i < len and i < out.len) : (i += 1) {
        out[i] = buf[len - 1 - i];
    }
    return @min(len, out.len);
}

fn write_hex(out: []u8, val: u64) usize {
    const hex_chars = "0123456789abcdef";
    if (val == 0) {
        if (out.len > 0) out[0] = '0';
        return 1;
    }
    var buf: [16]u8 = undefined;
    var v = val;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        buf[len] = hex_chars[v & 0xf];
        v >>= 4;
    }
    // Reverse and copy
    var i: usize = 0;
    while (i < len and i < out.len) : (i += 1) {
        out[i] = buf[len - 1 - i];
    }
    return @min(len, out.len);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "tombstone: record and retrieve" {
    init();
    try std.testing.expectEqual(@as(usize, 0), count());

    note_fault(1, 0x12345, 0); // #2098: fault evidence binds to the pid
    record("TEST.BIN", 1, 139, 0x12345, 0, "", 0);
    try std.testing.expectEqual(@as(usize, 1), count());

    const t = get(0).?;
    try std.testing.expectEqual(@as(u64, 1), t.pid);
    try std.testing.expectEqual(@as(u64, 139), t.exit_status);
    try std.testing.expectEqual(@as(u64, 0x12345), t.fault_addr);
    try std.testing.expectEqualStrings("TEST.BIN", t.name[0..t.name_len]);
}

test "tombstone: drop-oldest overflow" {
    init();
    for (0..9) |i| {
        const name = [_]u8{ 'A', @as(u8, '0' + @as(u8, @intCast(i % 10))) };
        record(&name, i, 1, 0, 0, "", 0);
    }
    // Should have max_tombstones (8), oldest (PID 0) dropped
    try std.testing.expectEqual(@as(usize, max_tombstones), count());
    const oldest = get(0).?;
    try std.testing.expectEqual(@as(u64, 1), oldest.pid); // PID 0 was dropped
}

test "tombstone: format includes header" {
    init();
    note_fault(42, 0xDEAD, 0x400010);
    record("CRASH.BIN", 42, 139, 0xDEAD, 0x400010, "hello", 5);

    var buf: [tombstone_max_bytes]u8 = undefined;
    const len = format_tombstone(get(0).?, &buf);

    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "VirelaiOS Crash Tombstone") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "CRASH.BIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "PID: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "Exit Status: 139") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "Fault Address: 0x") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "hello") != null);
}

test "tombstone: crash inside a known symbol carries the note" {
    init();
    const sym = @import("symbol.zig");
    sym.reset();
    _ = sym.add("crasher", 0x40000c, 20);

    // BRK-style fault: far=0 but PC lands inside "crasher".
    note_fault(3, 0, 0x400010);
    record("CRASH.ELF", 3, 139, 0, 0x400010, "", 0);
    const t = get(0).?;
    try std.testing.expect(t.sym_note_len > 0);
    try std.testing.expectEqualStrings("(in crasher+0x4)", t.sym_note[0..t.sym_note_len]);

    // The note flows into the formatted report.
    var buf: [tombstone_max_bytes]u8 = undefined;
    const len = format_tombstone(get(0).?, &buf);
    const report = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, report, "(in crasher+0x4)") != null);

    // Data-abort style: pc outside any range falls back to fault_addr.
    sym.reset();
    _ = sym.add("guard_zone", 0x500000, 64);
    note_fault(4, 0x500010, 0x400abc);
    record("GUARD.BIN", 4, 139, 0x500010, 0x400abc, "", 0);
    const t2 = get(count() - 1).?;
    try std.testing.expectEqualStrings("(in guard_zone+0x10)", t2.sym_note[0..t2.sym_note_len]);
}

test "tombstone: #2098 — a forged fault-status exit carries no fault evidence" {
    init();
    // `sys_exit(139)` from EL0, no real fault behind it — the exception
    // layer never bound evidence to pid 9. The receipt still records (the
    // caller persists it unconditionally; the status-forge refusal is the
    // syscall-side half) but its fault fields are zero, not whatever the
    // shared ring held.
    record("FORGED.BIN", 9, 139, 0xdead0000, 0x4000f0, "", 0);
    try std.testing.expectEqual(@as(usize, 1), count());
    const forged = get(0).?;
    try std.testing.expectEqual(@as(u64, 139), forged.exit_status);
    try std.testing.expectEqual(@as(u64, 0), forged.fault_addr);
    try std.testing.expectEqual(@as(u64, 0), forged.pc);
    // Same for the memory-limit receipt.
    record("FORGED.BIN", 9, 140, 0xbeef, 0xcafe, "", 0);
    const forged140 = get(1).?;
    try std.testing.expectEqual(@as(u64, 0), forged140.fault_addr);
    try std.testing.expectEqual(@as(u64, 0), forged140.pc);
    // Ordinary non-zero exits keep the caller's fields.
    record("CLEAN.BIN", 9, 1, 0x55, 0x66, "", 0);
    const clean = get(2).?;
    try std.testing.expectEqual(@as(u64, 0x55), clean.fault_addr);
}

test "tombstone: #2098 — fault fields bind to the crashing pid, never a sibling" {
    init();
    // Process B (pid 7) takes the fault; process A (pid 8) exits with a
    // forged 139 hoping to stamp B's far/pc on its own receipt. B's note
    // is keyed on pid 7 — A's receipt gets zeros.
    note_fault(7, 0xdead0000, 0x4000f0);
    record("A.BIN", 8, 139, 0xdead0000, 0x4000f0, "", 0);
    const forged = get(0).?;
    try std.testing.expectEqual(@as(u64, 8), forged.pid);
    try std.testing.expectEqual(@as(u64, 0), forged.fault_addr);
    try std.testing.expectEqual(@as(u64, 0), forged.pc);

    // B's own exit carries B's fields — the bound note wins over whatever
    // the caller's ring-sourced arguments held.
    record("B.BIN", 7, 139, 0x1111, 0x2222, "", 0);
    const t = get(1).?;
    try std.testing.expectEqual(@as(u64, 7), t.pid);
    try std.testing.expectEqual(@as(u64, 0xdead0000), t.fault_addr);
    try std.testing.expectEqual(@as(u64, 0x4000f0), t.pc);

    // The note was consumed: a second 139 record for the same pid has no
    // evidence and zeroes its fault fields.
    record("B.BIN", 7, 139, 0x9999, 0x8888, "", 0);
    const stale = get(2).?;
    try std.testing.expectEqual(@as(u64, 0), stale.fault_addr);
    try std.testing.expectEqual(@as(u64, 0), stale.pc);
}
