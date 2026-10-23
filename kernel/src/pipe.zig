//! M19 P1 (issue #290): the kernel pipe — a bounded, single-buffer conduit
//! between two commands.
//!
//! Two consumer classes, now separated (M97g #2081):
//!   * The shell's `|` operator (M19 P1) uses the console adapters below:
//!     the LEFT command runs with `sink_console()` (its writes land in the
//!     private kernel pipe), then the RIGHT command runs with
//!     `source_console(real)` (its reads pull from the pipe, its writes
//!     pass through to the real console). Sequential model — cmd1 runs to
//!     completion, then cmd2.
//!   * EL0 processes use `sys_pipe_read` (slot 56) / `sys_pipe_write`
//!     (slot 57) through the uaccess layer. These operate on a PER-PROCESS
//!     slot from the bounded `el0` table — before #2081 one global buffer
//!     let any app read or poison another app's staged pipeline bytes.
//!
//! Bounded and heap-free: a 4 KiB BSS buffer per pipe, no allocation, no
//! synchronization (single-core, IRQ-masked command execution; the syscall
//! handlers run under the service locks). Overflow is dropped (the writer's
//! `write` returns the bytes actually stored).

const std = @import("std");
const console = @import("console.zig");
const process = @import("process.zig");

/// The pipe buffer size (docs/archive/march-m19.md P1: max 4 KiB).
pub const pipe_capacity: usize = 4096;

var buf: [pipe_capacity]u8 = undefined;
var len: usize = 0; // total bytes written
var read_pos: usize = 0; // consumed prefix

/// M97g (#2081): the EL0 side is a small fixed table of per-process pipes.
/// A slot binds to the pid that first wrote (or read-allocated) it and is
/// released as soon as it drains or its owner exits — the sequential
/// `a | b` staging model only ever needs a slot for one hand-off, so four
/// concurrent pipelines is ample and a full table refuses ENOSPC honestly
/// instead of letting one app starve the machine.
pub const max_el0_pipes: usize = 4;

const El0Pipe = struct {
    owner: usize = 0,
    used: bool = false,
    len: usize = 0,
    read_pos: usize = 0,
};
var el0_bufs: [max_el0_pipes][pipe_capacity]u8 = undefined;
var el0: [max_el0_pipes]El0Pipe = @as([max_el0_pipes]El0Pipe, @splat(@as(El0Pipe, .{})));

fn freeable(i: usize) bool {
    const p = &el0[i];
    if (!p.used) return true;
    if (p.read_pos == p.len) {
        p.* = .{};
        return true;
    }
    if (process.principal(p.owner) == null) {
        // The owner exited mid-hand-off; its staged bytes die with it.
        p.* = .{};
        return true;
    }
    return false;
}

/// The slot index `pid` may use: its own live slot, else a free/reclaimable
/// one. `allocate=false` never takes a slot — reads of an unbound pid are
/// simply empty. Null means every slot is live-owned by another process.
fn slot_for(pid: usize, allocate: bool) ?usize {
    var free_slot: ?usize = null;
    for (&el0, 0..) |*p, i| {
        if (p.used and p.owner == pid) return i;
        if (free_slot == null and freeable(i)) free_slot = i;
    }
    if (!allocate) return null;
    const i = free_slot orelse return null;
    el0[i] = .{ .owner = pid, .used = true };
    return i;
}

/// `sys_pipe_read`: the caller's unread slice, or null when the pid holds
/// no slot (an empty pipe — the handler returns 0 bytes).
pub fn el0_unread(pid: usize) ?[]const u8 {
    const i = slot_for(pid, false) orelse return null;
    const p = &el0[i];
    return el0_bufs[i][p.read_pos..p.len];
}

/// `sys_pipe_read` post-copy: consume `n` bytes; a drained slot releases.
pub fn el0_advance_read(pid: usize, n: usize) void {
    const i = slot_for(pid, false) orelse return;
    const p = &el0[i];
    p.read_pos += n;
    if (p.read_pos == p.len) p.* = .{};
}

/// `sys_pipe_write`: the caller's append region, or null when the pid
/// cannot hold a slot (ENOSPC) — either its own pipe is full or the table
/// is exhausted by other live processes.
pub fn el0_append(pid: usize) ?[]u8 {
    const i = slot_for(pid, true) orelse return null;
    const p = &el0[i];
    return el0_bufs[i][p.len..];
}

/// `sys_pipe_write` post-copy: publish `n` bytes appended to `el0_append`.
pub fn el0_advance_write(pid: usize, n: usize) void {
    const i = slot_for(pid, false) orelse return;
    el0[i].len += n;
}

/// Clear the kernel pipe before a new `a | b`.
pub fn reset() void {
    len = 0;
    read_pos = 0;
}

/// Unread bytes still in the kernel pipe.
pub fn available() usize {
    return len - read_pos;
}

/// Free write space left in the kernel pipe.
pub fn capacity_left() usize {
    return pipe_capacity - len;
}

/// Append `bytes` to the kernel pipe; returns the number stored (drops
/// overflow).
pub fn write(bytes: []const u8) usize {
    const n = @min(bytes.len, capacity_left());
    @memcpy(buf[len..][0..n], bytes[0..n]);
    len += n;
    return n;
}

// ---------------------------------------------------------------------------
// Sink console — the LEFT command's stdout during `a | b`
// ---------------------------------------------------------------------------

const SinkCtx = struct {};
var sink_ctx: SinkCtx = .{};
// ADR 0005 (claim 0015): vtables are built at runtime into BSS — a const
// table holds link-time absolute addresses, wrong at the kernel's
// runtime-chosen load base.
var sink_vtable: console.Console.VTable = undefined;
var sink_vtable_ready = false;
fn ensure_sink_vtable() *const console.Console.VTable {
    if (!sink_vtable_ready) {
        sink_vtable = .{
            .write = sink_write,
            .flush = sink_flush,
            .readByte = sink_read,
        };
        sink_vtable_ready = true;
    }
    return &sink_vtable;
}
fn sink_write(_: *anyopaque, bytes: []const u8) void {
    _ = write(bytes);
}
fn sink_flush(_: *anyopaque) void {}
fn sink_read(_: *anyopaque) ?u8 {
    return null; // the left command has no stdin
}

/// A console whose writes land in the pipe and whose reads return nothing.
pub fn sink_console() console.Console {
    return .{ .ctx = &sink_ctx, .vtable = ensure_sink_vtable() };
}

// ---------------------------------------------------------------------------
// Source console — the RIGHT command's stdin during `a | b`
// ---------------------------------------------------------------------------

const SourceCtx = struct { inner: console.Console };
var source_ctx: SourceCtx = undefined;
var source_vtable: console.Console.VTable = undefined;
var source_vtable_ready = false;
fn ensure_source_vtable() *const console.Console.VTable {
    if (!source_vtable_ready) {
        source_vtable = .{
            .write = source_write,
            .flush = source_flush,
            .readByte = source_read,
        };
        source_vtable_ready = true;
    }
    return &source_vtable;
}
fn source_write(ctx: *anyopaque, bytes: []const u8) void {
    const sc: *SourceCtx = @ptrCast(@alignCast(ctx));
    sc.inner.write(bytes);
}
fn source_flush(ctx: *anyopaque) void {
    const sc: *SourceCtx = @ptrCast(@alignCast(ctx));
    sc.inner.flush();
}
fn source_read(_: *anyopaque) ?u8 {
    if (available() == 0) return null;
    const b = buf[read_pos];
    read_pos += 1;
    return b;
}

/// A console whose reads pull from the pipe and whose writes pass through
/// to `inner`. Used as the RIGHT command's console during `a | b`.
pub fn source_console(inner: console.Console) console.Console {
    source_ctx.inner = inner;
    return .{ .ctx = &source_ctx, .vtable = ensure_source_vtable() };
}

// ---------------------------------------------------------------------------
// Tests (host-side; no hardware)
// ---------------------------------------------------------------------------

test "pipe: write/read round-trips through the buffer" {
    reset();
    try std.testing.expectEqual(@as(usize, 0), available());
    const n = write("hello pipe");
    try std.testing.expectEqual(@as(usize, 10), n);
    try std.testing.expectEqual(@as(usize, 10), available());
    var out: [pipe_capacity]u8 = undefined;
    const got = read_into_for_test(&out);
    try std.testing.expectEqualStrings("hello pipe", out[0..got]);
    try std.testing.expectEqual(@as(usize, 0), available());
}

test "pipe: overflow is dropped, never wraps" {
    reset();
    const big = &@as([(pipe_capacity + 100):0]u8, @splat("x"[0]));
    const n = write(big);
    try std.testing.expectEqual(@as(usize, pipe_capacity), n);
    try std.testing.expectEqual(@as(usize, pipe_capacity), available());
    // A second write finds no room.
    try std.testing.expectEqual(@as(usize, 0), write("y"));
}

test "pipe: sink console captures writes, source console feeds reads" {
    reset();
    var mock = console.MockConsole(256){};
    const real = mock.console();
    const sink = sink_console();
    sink.write("left-out");
    sink.putc('\n');
    try std.testing.expectEqual(@as(usize, 9), available());
    // The source console reads the pipe and passes writes through.
    const source = source_console(real);
    var got: [32]u8 = undefined;
    var n: usize = 0;
    while (source.readByte()) |b| : (n += 1) {
        if (n < got.len) got[n] = b;
    }
    try std.testing.expectEqualStrings("left-out\n", got[0..n]);
    source.puts("right-out");
    try std.testing.expectEqualStrings("right-out", mock.contents());
}

/// Host-test helper mirroring the kernel-pipe read path (copy unread out).
fn read_into_for_test(out: []u8) usize {
    const avail = available();
    const take = @min(avail, out.len);
    @memcpy(out[0..take], buf[read_pos..][0..take]);
    read_pos += take;
    return take;
}
