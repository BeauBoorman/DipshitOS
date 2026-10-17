//! The GPU3D compute broker behind `sys_gpucomp` — slot 90 (M111b, issue
//! #2409), ADR 0053 D5/D6 and the ADR 0007 M111b amendment.
//!
//! One single-tenant compute session system-wide on the same private
//! Virtio GPU device (1af4:1083) the render path owns: the shared
//! two-context pool, the same one-outstanding-request control queue, the
//! same fence-matched completion and the same timeout→quarantine rules —
//! a timed-out exchange poisons the session and every later op answers
//! ENOENT until the bounded drain releases it. Where cmd-22 is keyed to a
//! registered seat's windows, compute is keyed to the owning pid: the
//! caller's pid is recorded at OPEN and checked on every op, so a handle
//! smuggled to another process is useless, and `owner_exit` (the exit
//! funnel) revokes the session with the handle invalidation first and the
//! bounded drain second — the render broker's own revocation order.
//!
//! Layers: `gpu3d_wire` carries the frozen wire/ABI bytes (VIC1 profile,
//! the 128-byte descriptor, the 64-byte kernel descriptor);
//! `gpu3d_device` owns the transport exchange and the context pool;
//! `gpu3d_submit` owns the resource/transfer encoders this file reuses.
//! A refusal never moves a device counter: every rejected descriptor
//! increments `refusals`, never `submits`.

const std = @import("std");
const builtin = @import("builtin");
const mmu = @import("mmu.zig");
const uaccess = @import("uaccess.zig");
const timer = @import("timer.zig");
const wire = @import("gpu3d_wire.zig");
const stream = @import("gpu3d_stream.zig");
const device = @import("gpu3d_device.zig");
const submit = @import("gpu3d_submit.zig");

// ---------------------------------------------------------------------------
// The frozen slot-90 ABI (ADR 0007 M111b amendment, ADR 0053 D5)
// ---------------------------------------------------------------------------

/// sys_gpucomp descriptors are exactly 128 bytes.
pub const desc_len: usize = 128;
/// The STATS reply block is exactly 64 bytes.
pub const stats_len: usize = 64;

pub const op_open: u32 = 1;
pub const op_close: u32 = 2;
pub const op_buf_alloc: u32 = 3;
pub const op_buf_free: u32 = 4;
pub const op_write: u32 = 5;
pub const op_read: u32 = 6;
pub const op_seal: u32 = 7;
pub const op_run: u32 = 8;
pub const op_stats: u32 = 9;

/// BUF_ALLOC flag bit 0: a WEIGHT buffer backed by the shared 4 MiB
/// staging window (SEAL releases the share). Absent = an I/O buffer with
/// dedicated pages from the 8 MiB pool. No other flag bit exists.
pub const flag_weight: u32 = 1 << 0;

/// The frozen 128-byte slot-90 descriptor (ADR 0053 D5), little-endian.
/// The handler copies it through checked uaccess before dispatch; this
/// file never sees a user pointer for the descriptor itself.
pub const Desc = extern struct {
    op: u32 = 0,
    flags: u32 = 0,
    handle: u64 = 0,
    arg_a: u64 = 0,
    arg_b: u64 = 0,
    arg_c: u64 = 0,
    reserved: [16]u8 = @splat(0),
    reserved2: u64 = 0,
    kdesc: [wire.kernel_desc_len]u8 = @splat(0),
};

/// The frozen 64-byte STATS block (ADR 0053 D6).
pub const Stats = extern struct {
    busy: u32 = 0,
    queued: u32 = 0,
    sessions_live: u32 = 0,
    reserved: u32 = 0,
    last_kernel_us: u64 = 0,
    total_kernel_us: u64 = 0,
    submits: u64 = 0,
    completed: u64 = 0,
    refusals: u64 = 0,
    timeouts: u64 = 0,
};

comptime {
    if (@sizeOf(Desc) != desc_len) @compileError("sys_gpucomp descriptor must stay exactly 128 bytes");
    if (@sizeOf(Stats) != stats_len) @compileError("stats block must stay exactly 64 bytes");
    if (@offsetOf(Desc, "handle") != 8 or @offsetOf(Desc, "kdesc") != 64) @compileError("descriptor offsets moved — the ABI is frozen");
}

/// The op result mirrors the ADR errno set — the syscall layer maps each
/// to a named code and nothing else.
pub const Error = error{
    Invalid, // EINVAL — malformed descriptor / foreign field / bad bounds
    BadHandle, // EBADF — bad or stale handle
    Exhausted, // ENOSPC — session/context/pool exhausted
    Unsupported, // ENXIO — no device or VIC1 ready=0
    Busy, // EAGAIN — the control queue is busy
    TimedOut, // ETIMEDOUT — the exchange deadline elapsed
    LostContext, // ENOENT — the session is poisoned/quarantined
    Access, // EFAULT — a user pointer failed checked access
    DeviceFault, // EIO — device-level protocol/submission fault
};

// ---------------------------------------------------------------------------
// The session — one live compute tenant, generation-bearing handles
// ---------------------------------------------------------------------------

const alloc = @import("alloc.zig");

const max_bufs: usize = wire.vic1_max_buffers;
const io_pool_bytes: usize = 8 * 1024 * 1024; // D4: the I/O pool
const staging_bytes: usize = 4 * 1024 * 1024; // D4: the shared weight staging window
const io_pool_pages: u64 = io_pool_bytes / 4096;
const staging_pages: u64 = staging_bytes / 4096;

/// Backing for I/O-class buffers and the shared weight staging window —
/// physically-contiguous ranges from the page allocator, taken at OPEN
/// and released at drain (never BSS: the loader's KRN2 image ceiling is
/// 16 MiB and 12 MiB of dead statics would spend nearly all of it).
/// `pools_owned` distinguishes an allocator-owned pair from the test
/// seam's injected BSS slices.
var io_pool: []u8 = &.{};
var staging: []u8 = &.{};
var io_pool_pa: u64 = 0;
var staging_pa: u64 = 0;
var pools_owned: bool = false;

/// Claim the two pools at session open. Identity-mapped RAM means the
/// returned PA IS the kernel VA — the same property ATTACH_BACKING needs
/// (the descriptor carries the PA the device DMAs).
fn pools_acquire() bool {
    const io_pa = alloc.alloc_pages(io_pool_pages) orelse return false;
    const st_pa = alloc.alloc_pages(staging_pages) orelse {
        _ = alloc.free_pages(io_pa, io_pool_pages);
        return false;
    };
    io_pool_pa = io_pa;
    staging_pa = st_pa;
    io_pool = @as([*]u8, @ptrFromInt(@as(usize, @intCast(io_pa))))[0..io_pool_bytes];
    staging = @as([*]u8, @ptrFromInt(@as(usize, @intCast(st_pa))))[0..staging_bytes];
    pools_owned = true;
    return true;
}

/// Release the pools once every buffer on them is torn down — the drain
/// ordering guarantee (backing detached first, pages freed last).
fn pools_release() void {
    if (!pools_owned) return;
    _ = alloc.free_pages(io_pool_pa, io_pool_pages);
    _ = alloc.free_pages(staging_pa, staging_pages);
    pools_owned = false;
}

/// A small free-list allocator over `io_pool`: ≤ max_bufs live ranges
/// implies ≤ max_bufs+1 free runs, so the list is fixed-size. First-fit,
/// coalescing on free — bounded walks over ≤ 17 entries.
const Range = struct { off: usize, len: usize };
var io_free: [max_bufs + 1]Range = @splat(.{ .off = 0, .len = 0 });
var io_free_count: usize = 0;

fn io_init() void {
    io_free_count = 1;
    io_free[0] = .{ .off = 0, .len = io_pool.len };
}

fn io_round(len: usize) usize {
    return (len + 4096 - 1) / 4096 * 4096;
}

fn io_alloc(len: usize) ?usize {
    const need = io_round(len);
    if (need == 0 or need > io_pool.len) return null;
    for (io_free[0..io_free_count]) |*r| {
        if (r.len < need) continue;
        const off = r.off;
        if (r.len == need) {
            r.* = io_free[io_free_count - 1];
            io_free_count -= 1;
        } else {
            r.off += need;
            r.len -= need;
        }
        return off;
    }
    return null;
}

fn io_free_range(off: usize, len: usize) void {
    if (len == 0) return;
    // A live buffer's range came out of this list, so a slot always exists.
    std.debug.assert(io_free_count < io_free.len);
    io_free[io_free_count] = .{ .off = off, .len = len };
    io_free_count += 1;
    var i: usize = 0;
    while (i < io_free_count) : (i += 1) {
        var j: usize = i + 1;
        while (j < io_free_count) {
            const a = io_free[i];
            const b = io_free[j];
            if (a.off + a.len == b.off) {
                io_free[i].len += b.len;
                io_free[j] = io_free[io_free_count - 1];
                io_free_count -= 1;
            } else if (b.off + b.len == a.off) {
                io_free[i] = .{ .off = b.off, .len = b.len + a.len };
                io_free[j] = io_free[io_free_count - 1];
                io_free_count -= 1;
            } else {
                j += 1;
            }
        }
    }
}

/// Session state: free → live → (poisoned → quarantined) → free. A
/// poisoned session answers ENOENT on every op but still owns its device
/// context until CLOSE/owner-exit drains it; a quarantined one is
/// logically dead but the drain could not complete — the next OPEN
/// retries the drain before refusing ENOSPC.
const SessState = enum { free, live, poisoned, quarantined };

const Buf = struct {
    live: bool = false,
    generation: u32 = 0,
    weight: bool = false,
    sealed: bool = false,
    size: u32 = 0, // declared bytes (the resource's width)
    res_id: u32 = 0,
    res_created: bool = false,
    res_backed: bool = false,
    res_attached: bool = false,
    io_off: usize = 0, // pool range held (I/O class)
    io_len: usize = 0,
};

const Sess = struct {
    state: SessState = .free,
    generation: u64 = 0, // session-handle gen, bumps on open AND invalidate
    owner: usize = 0,
    ctx: device.Handle = .{ .ctx_id = 0, .generation = 0 },
    bufs: [max_bufs]Buf = @splat(.{}),
};

var sess: Sess = .{};

/// The ADR 0053 D6 counters — `busy` reads 1 only inside a device
/// exchange (the call is synchronous); `queued` stays 0 in v1 (nothing
/// ever queues; the one-outstanding rule turns a second submit into
/// EAGAIN).
pub var counters: Stats = .{};

/// A session handle is `generation:48 | ctx_id:16`; a buffer handle is
/// `generation:32 | slot:8 | ctx_id:16` (ADR 0053 D4) — the buffer's low
/// 32 bits ride the kernel descriptor's u32 `buf` field verbatim.
fn session_handle(s: *const Sess) u64 {
    return (s.generation << 16) | s.ctx.ctx_id;
}

fn buffer_handle(s: *const Sess, slot: usize) u64 {
    const b = &s.bufs[slot];
    return (@as(u64, b.generation) << 24) | (@as(u64, slot + 1) << 16) | s.ctx.ctx_id;
}

/// Decode a session handle for ops that need a LIVE session: ctx id in
/// the low 16, the session generation above. Poisoned/quarantined answer
/// LostContext (a CLOSE reaches them through close_for).
fn session_for(d: *const Desc, caller_pid: usize) Error!*Sess {
    if (sess.state == .free or d.handle == 0) return error.BadHandle;
    const ctx_id: u32 = @as(u16, @truncate(d.handle));
    if (ctx_id != sess.ctx.ctx_id or (d.handle >> 16) != sess.generation) return error.BadHandle;
    if (sess.state != .live) return error.LostContext;
    if (sess.owner != caller_pid) return error.BadHandle;
    return &sess;
}

/// Decode a buffer handle: ctx low 16, slot bits 16..23 (1..16), buffer
/// generation above bit 24. A slot-0 or foreign-ctx handle never names a
/// live buffer; the same session checks (state/owner) apply first.
fn buffer_for(d: *const Desc, caller_pid: usize) Error!*Buf {
    if (sess.state == .free or d.handle == 0) return error.BadHandle;
    if (sess.state != .live) return error.LostContext;
    if (sess.owner != caller_pid) return error.BadHandle;
    const ctx_id: u32 = @as(u16, @truncate(d.handle));
    if (ctx_id != sess.ctx.ctx_id) return error.BadHandle;
    const slot: usize = @intCast((d.handle >> 16) & 0xff);
    const gen: u32 = @truncate(d.handle >> 24);
    if (slot < 1 or slot > max_bufs) return error.BadHandle;
    const b = &sess.bufs[slot - 1];
    if (!b.live or b.generation != gen) return error.BadHandle;
    return b;
}

/// The wire resource id for buffer slot `i` (0-based, 1..16 on the wire)
/// of context `c` — `res = c·256 + i`, disjoint from the render path's
/// 2c-1/2c ids.
fn buf_res_id(ctx_id: u32, slot: usize) u32 {
    return ctx_id * 256 + @as(u32, @intCast(slot + 1));
}

// ---------------------------------------------------------------------------
// The exchange wrapper — counters + poison live here, never in ops
// ---------------------------------------------------------------------------

fn take_fence() Error!u64 {
    device.fence_counter +%= 1;
    if (device.fence_counter == 0) return error.DeviceFault;
    return device.fence_counter;
}

/// Map a device-layer error onto the broker's named set — Timeout also
/// poisons the session (the ADR 0053 quarantine rule: a timed-out
/// exchange never answers EAGAIN again).
fn map_device_error(e: device.Error) Error {
    return switch (e) {
        error.Timeout => blk: {
            counters.timeouts +%= 1;
            if (sess.state == .live) sess.state = .poisoned;
            break :blk error.TimedOut;
        },
        error.Busy => error.Busy,
        error.BadHandle => error.BadHandle,
        error.ContextExhausted => error.Exhausted,
        error.Unsupported, error.CapsNotReady, error.CapsetProfile, error.CapsetVersion, error.CapsetSize, error.CapsetBounds, error.CapsetTruncated => error.Unsupported,
        else => error.DeviceFault,
    };
}

/// One bounded fenced exchange for resource/transfer traffic — internal
/// bookkeeping, no submit counters. The fence match lives inside
/// device.exchange: the reply must echo the request's own fence id.
fn exchange(req: []const u8) Error!void {
    counters.busy = 1;
    defer counters.busy = 0;
    _ = device.exchange(req, wire.resp_ok_nodata, wire.nodata_resp_len) catch |e| {
        return map_device_error(e);
    };
}

/// A RUN that reached the device: submits counts posts, completed the
/// fence-matched finishes, last/total_kernel_us the round-trip time.
fn submit_exchange(req: []const u8) Error!void {
    const t0 = now_us();
    counters.busy = 1;
    defer counters.busy = 0;
    _ = device.exchange(req, wire.resp_ok_nodata, wire.nodata_resp_len) catch |e| {
        // Only a posted request reached the device (Busy/BadRequest/
        // SubmitFailed all fail before the post).
        if (e != error.Busy and e != error.BadRequest and e != error.SubmitFailed) counters.submits +%= 1;
        return map_device_error(e);
    };
    const took = now_us() -% t0;
    counters.submits +%= 1;
    counters.completed +%= 1;
    counters.last_kernel_us = took;
    counters.total_kernel_us +%= took;
}

fn now_us() u64 {
    const f = timer.freq;
    if (f == 0) return 0;
    return timer.cntpct() * std.time.us_per_s / f;
}

// ---------------------------------------------------------------------------
// Ops
// ---------------------------------------------------------------------------

/// The per-op field rules of the ADR table: every field an op does not
/// name must be zero. Runs before any device activity and before the
/// session/handle checks, so a malformed descriptor can never probe
/// liveness.
fn check_descriptor(d: *const Desc) Error!void {
    if (d.reserved2 != 0) return error.Invalid;
    for (d.reserved) |b| {
        if (b != 0) return error.Invalid;
    }
    const kdesc_zero = std.mem.allEqual(u8, &d.kdesc, 0);
    switch (d.op) {
        op_open => {
            if (d.handle != 0 or d.flags != 0 or d.arg_a != 0 or d.arg_b != 0 or d.arg_c != 0 or !kdesc_zero) return error.Invalid;
        },
        op_stats => {
            if (d.handle != 0 or d.flags != 0 or d.arg_b != 0 or d.arg_c != 0 or !kdesc_zero) return error.Invalid;
            if (d.arg_a == 0) return error.Invalid; // STATS needs a dst VA
        },
        op_close => {
            if (d.handle == 0 or d.flags != 0 or d.arg_a != 0 or d.arg_b != 0 or d.arg_c != 0 or !kdesc_zero) return error.Invalid;
        },
        op_buf_alloc => {
            if (d.handle == 0 or (d.flags & ~flag_weight) != 0 or
                d.arg_a == 0 or d.arg_a > wire.vic1_max_buffer_bytes or
                d.arg_b != 0 or d.arg_c != 0 or !kdesc_zero) return error.Invalid;
        },
        op_buf_free, op_seal => {
            if (d.handle == 0 or d.flags != 0 or d.arg_a != 0 or d.arg_b != 0 or d.arg_c != 0 or !kdesc_zero) return error.Invalid;
        },
        op_write, op_read => {
            if (d.handle == 0 or d.flags != 0 or d.arg_a == 0 or d.arg_b == 0 or !kdesc_zero) return error.Invalid;
        },
        op_run => {
            if (d.handle == 0 or d.flags != 0 or d.arg_a != 0 or d.arg_b != 0 or d.arg_c != 0) return error.Invalid;
        },
        else => return error.Invalid,
    }
}

/// Dispatch one validated-length descriptor. Every refusal — at any
/// layer below — counts once in `refusals` and never in `submits`.
pub fn dispatch(d: *const Desc, caller_pid: usize) Error!u64 {
    return dispatch_inner(d, caller_pid) catch |e| {
        counters.refusals +%= 1;
        return e;
    };
}

fn dispatch_inner(d: *const Desc, caller_pid: usize) Error!u64 {
    try check_descriptor(d);
    return switch (d.op) {
        op_open => do_open(d, caller_pid),
        op_close => do_close(d, caller_pid),
        op_buf_alloc => do_buf_alloc(d, caller_pid),
        op_buf_free => do_buf_free(d, caller_pid),
        op_write => do_write(d, caller_pid),
        op_read => do_read(d, caller_pid),
        op_seal => do_seal(d, caller_pid),
        op_run => do_run(d, caller_pid),
        op_stats => do_stats(d),
        else => unreachable,
    };
}

/// OPEN: the one session — VIC1 probed and ready, a free device ctx from
/// the shared pool of 2, a fresh generation. A poisoned/quarantined
/// leftover drains here first; a healthy live session is ENOSPC.
fn do_open(_: *const Desc, caller_pid: usize) Error!u64 {
    if (!device.g3_ready) return error.Unsupported;
    if (!device.caps_valid) _ = device.probe_caps() catch |e| return map_device_error(e);
    if (!device.vic1_valid) _ = device.probe_vic1() catch |e| return map_device_error(e);
    if (device.vic1.ready == 0) return error.Unsupported;

    switch (sess.state) {
        .live => return error.Exhausted, // the single tenancy
        .poisoned, .quarantined => {
            sess.generation +%= 1; // a stale poisoned handle is dead either way
            if (drain_session(&sess)) {
                sess.state = .free;
            } else {
                sess.state = .quarantined;
                return error.Exhausted;
            }
        },
        .free => {},
    }

    if (io_pool.len == 0 and !pools_acquire()) return error.Exhausted; // the 12 MiB backing share
    const slot = device.ctx_free_slot() orelse {
        pools_release();
        return error.Exhausted;
    };
    const ctx = device.ctx_create(slot) catch |e| {
        pools_release();
        return map_device_error(e);
    };
    sess = .{
        .state = .live,
        .generation = sess.generation +% 1,
        .owner = caller_pid,
        .ctx = ctx,
        .bufs = @splat(.{}),
    };
    io_init();
    counters.sessions_live = 1;
    return session_handle(&sess);
}

/// CLOSE reaches live AND poisoned/quarantined sessions — the drain is
/// its job — so it decodes the handle itself instead of session_for.
fn do_close(d: *const Desc, caller_pid: usize) Error!u64 {
    if (sess.state == .free or d.handle == 0) return error.BadHandle;
    const ctx_id: u32 = @as(u16, @truncate(d.handle));
    if (ctx_id != sess.ctx.ctx_id or (d.handle >> 16) != sess.generation) return error.BadHandle;
    if (sess.owner != caller_pid) return error.BadHandle;
    sess.generation +%= 1; // invalidate FIRST — every later op is EBADF
    counters.sessions_live = 0;
    if (drain_session(&sess)) {
        sess.state = .free;
        sess.owner = 0;
        sess.ctx = .{ .ctx_id = 0, .generation = 0 };
        pools_release();
    } else {
        sess.state = .quarantined;
        return error.TimedOut;
    }
    return 0;
}

/// The bounded per-buffer teardown: ctx_detach → detach_backing → unref,
/// then the pool share — identical order to the render drain. A wedged
/// device answers each step with its own named error; teardown keeps
/// going so a late completion can never pin live guest state.
fn drain_buffer(s: *Sess, i: usize) void {
    const b = &s.bufs[i];
    var env: [96]u8 = undefined;
    device.fence_counter +%= 1;
    if (b.res_attached) {
        const n = submit.encode_res_op(&env, submit.cmd_ctx_detach_resource, b.res_id, s.ctx.ctx_id, device.fence_counter);
        _ = device.exchange(env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len) catch {};
        b.res_attached = false;
    }
    device.fence_counter +%= 1;
    if (b.res_backed) {
        const n = submit.encode_res_op(&env, submit.cmd_resource_detach_backing, b.res_id, s.ctx.ctx_id, device.fence_counter);
        _ = device.exchange(env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len) catch {};
        b.res_backed = false;
    }
    device.fence_counter +%= 1;
    if (b.res_created) {
        const n = submit.encode_res_op(&env, submit.cmd_resource_unref, b.res_id, s.ctx.ctx_id, device.fence_counter);
        _ = device.exchange(env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len) catch {};
        b.res_created = false;
    }
    if (b.io_len != 0) {
        io_free_range(b.io_off, b.io_len);
        b.io_off = 0;
        b.io_len = 0;
    }
    // Keep the generation — a freed slot's old handle must stay stale.
    const gen = b.generation;
    b.* = .{ .generation = gen };
}

/// Drain the session's buffers and its device ctx. Returns false when
/// the device could not acknowledge the teardown — the caller parks the
/// session in `quarantined` and the pinned pool pages stay reserved
/// (never recycled under a possible late completion).
fn drain_session(s: *Sess) bool {
    var i: usize = 0;
    while (i < max_bufs) : (i += 1) {
        if (s.bufs[i].live) drain_buffer(s, i);
    }
    device.ctx_destroy(s.ctx) catch return false;
    return true;
}

fn do_buf_alloc(d: *const Desc, caller_pid: usize) Error!u64 {
    const s = try session_for(d, caller_pid);
    const size: u32 = @intCast(d.arg_a);
    const weight = (d.flags & flag_weight) != 0;

    var slot: usize = 0;
    while (slot < max_bufs) : (slot += 1) {
        if (!s.bufs[slot].live) break;
    }
    if (slot == max_bufs) return error.Exhausted;

    var io_off: usize = 0;
    var io_len: usize = 0;
    if (!weight) {
        io_off = io_alloc(size) orelse return error.Exhausted;
        io_len = io_round(size);
    }

    const b = &s.bufs[slot];
    b.* = .{
        .live = true,
        .generation = b.generation +% 1,
        .weight = weight,
        .size = size,
        .res_id = buf_res_id(s.ctx.ctx_id, slot),
        .io_off = io_off,
        .io_len = io_len,
    };

    // create → attach_backing → ctx_attach — the render lifecycle's own
    // order; a mid-sequence failure unwinds through the same drain.
    res_init(s, b, io_off, io_len, weight) catch |e| {
        drain_buffer(s, slot);
        return e;
    };
    return buffer_handle(s, slot);
}

/// The three fenced exchanges a new buffer rides: RESOURCE_CREATE_3D
/// (target_buffer, `width` = declared bytes), ATTACH_BACKING of its
/// guest-resident window (the pool range for I/O, the shared staging
/// window for WEIGHT), then CTX_ATTACH_RESOURCE.
fn res_init(s: *Sess, b: *Buf, io_off: usize, io_len: usize, weight: bool) Error!void {
    var env: [96]u8 = undefined;
    const f1 = try take_fence();
    const n1 = submit.encode_create3d(&env, b.res_id, stream.target_buffer, 0, 0, b.size, 1, s.ctx.ctx_id, f1);
    try exchange(env[0..n1]);
    b.res_created = true;
    const f2 = try take_fence();
    const pa: u64 = if (weight) staging_pa else io_pool_pa + io_off;
    const blen: u32 = if (weight) @intCast(staging.len) else @intCast(io_len);
    const n2 = submit.encode_attach_backing(&env, b.res_id, pa, blen, s.ctx.ctx_id, f2);
    try exchange(env[0..n2]);
    b.res_backed = true;
    const f3 = try take_fence();
    const n3 = submit.encode_res_op(&env, submit.cmd_ctx_attach_resource, b.res_id, s.ctx.ctx_id, f3);
    try exchange(env[0..n3]);
    b.res_attached = true;
}

fn do_buf_free(d: *const Desc, caller_pid: usize) Error!u64 {
    _ = try buffer_for(d, caller_pid);
    const slot: usize = @intCast(((d.handle >> 16) & 0xff) - 1);
    drain_buffer(&sess, slot);
    return 0;
}

/// The WRITE/READ bounds per class: a sealed buffer is EINVAL
/// (bufferSealed); an off/len reaching past the declared size is EINVAL
/// (bufferOverrun); a weight chunk over the staging window is EINVAL
/// (weightChunkTooLarge).
fn rw_bounds(d: *const Desc, b: *const Buf) Error!struct { off: usize, len: usize } {
    if (b.sealed) return error.Invalid;
    if (d.arg_c > b.size or d.arg_b > b.size - d.arg_c) return error.Invalid;
    const len: usize = @intCast(d.arg_b);
    const off: usize = @intCast(d.arg_c);
    if (b.weight and len > staging.len) return error.Invalid;
    return .{ .off = off, .len = len };
}

fn do_write(d: *const Desc, caller_pid: usize) Error!u64 {
    const b = try buffer_for(d, caller_pid);
    const span = try rw_bounds(d, b);
    // Backing window: weight writes stage through the shared window at
    // offset 0; I/O writes land in the buffer's own pool range.
    const dst: []u8 = if (b.weight) staging[0..span.len] else io_pool[b.io_off + span.off ..][0..span.len];
    if (uaccess.copy_in(dst, d.arg_a, span.len) != .ok) return error.Access;
    if (comptime !builtin.is_test) {
        if (b.weight) {
            mmu.clean_dcache_range(@intFromPtr(staging.ptr), span.len);
        } else {
            mmu.clean_dcache_range(@intFromPtr(io_pool.ptr) + b.io_off + span.off, span.len);
        }
    }
    var env: [96]u8 = undefined;
    // box.x = buf_off (the resource offset); `offset` is the offset into
    // the buffer's ATTACHed backing — the pool range for I/O (buf_off),
    // the shared window's start for weight (0).
    const back_off: u64 = if (b.weight) 0 else span.off;
    const f = try take_fence();
    const n = submit.encode_transfer(&env, submit.cmd_transfer_to_host_3d, b.res_id, .{ .x = @intCast(span.off), .y = 0, .z = 0, .w = @intCast(span.len), .h = 1, .d = 1 }, back_off, 0, 0, sess.ctx.ctx_id, f);
    try exchange(env[0..n]);
    return 0;
}

fn do_read(d: *const Desc, caller_pid: usize) Error!u64 {
    const b = try buffer_for(d, caller_pid);
    const span = try rw_bounds(d, b); // the same sealed/overrun/chunk rules
    var env: [96]u8 = undefined;
    const back_off: u64 = if (b.weight) 0 else span.off;
    const f = try take_fence();
    const n = submit.encode_transfer(&env, submit.cmd_transfer_from_host_3d, b.res_id, .{ .x = @intCast(span.off), .y = 0, .z = 0, .w = @intCast(span.len), .h = 1, .d = 1 }, back_off, 0, 0, sess.ctx.ctx_id, f);
    try exchange(env[0..n]);
    const src: []const u8 = if (b.weight) staging[0..span.len] else io_pool[b.io_off + span.off ..][0..span.len];
    if (comptime !builtin.is_test) {
        if (b.weight) {
            mmu.invalidate_dcache_range(@intFromPtr(staging.ptr), span.len);
        } else {
            mmu.invalidate_dcache_range(@intFromPtr(io_pool.ptr) + b.io_off + span.off, span.len);
        }
    }
    if (uaccess.copy_out(d.arg_a, src, span.len) != .ok) return error.Access;
    return 0;
}

/// SEAL: detach the buffer's backing (the guest's DMA share is gone —
/// the resource stays device-side) and release the pool share. A second
/// seal, or WRITE/READ after, is a named refusal.
fn do_seal(d: *const Desc, caller_pid: usize) Error!u64 {
    const b = try buffer_for(d, caller_pid);
    if (b.sealed or !b.res_backed) return error.Invalid;
    var env: [96]u8 = undefined;
    const f = try take_fence();
    const n = submit.encode_res_op(&env, submit.cmd_resource_detach_backing, b.res_id, sess.ctx.ctx_id, f);
    try exchange(env[0..n]);
    b.res_backed = false;
    b.sealed = true;
    if (b.io_len != 0) {
        io_free_range(b.io_off, b.io_len);
        b.io_off = 0;
        b.io_len = 0;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// RUN — the kernel-descriptor validator and handle translator
// ---------------------------------------------------------------------------

/// Resolve a kernel-descriptor buffer slot: `buf` carries the low 32
/// bits of the buffer handle (gen:8 | slot:8 | ctx:16 — the generation's
/// low byte still detects staleness); `need` is the tensor's byte span
/// from byte_off, checked against the declared buffer size (a tensor
/// over-running its buffer refuses before any device submission).
fn resolve_buf(kb: wire.BufSlot, need: u64) Error!u32 {
    if (kb.buf == 0) return error.Invalid; // bufferMissing
    const ctx_id: u32 = kb.buf & 0xffff;
    const slot: usize = @intCast((kb.buf >> 16) & 0xff);
    const gen_lo: u32 = kb.buf >> 24;
    if (ctx_id != sess.ctx.ctx_id or slot < 1 or slot > max_bufs) return error.Invalid;
    const b = &sess.bufs[slot - 1];
    if (!b.live or (b.generation & 0xff) != gen_lo) return error.Invalid;
    if (need > b.size or kb.byte_off > b.size - need) return error.Invalid;
    return b.res_id;
}

fn resolve_absent(kb: wire.BufSlot) Error!void {
    if (kb.buf != 0 or kb.byte_off != 0) return error.Invalid;
}

/// Per-kernel descriptor validation + handle→res_id translation. The
/// pinned bounds come from the VIC1 profile words (validated at probe).
fn translate_kdesc(k: *wire.KernelDesc) Error!void {
    switch (k.kernel_id) {
        wire.kernel_gemm => {
            if ((k.flags & ~(wire.gemm_flag_bias | wire.gemm_flag_b_transposed)) != 0) return error.Invalid;
            if (k.aux != 0 or k.reserved != 0) return error.Invalid;
            const m = k.d0;
            const n = k.d1;
            const kk = k.d2;
            if (m == 0 or n == 0 or kk == 0) return error.Invalid;
            if (m > wire.vic1_max_dim or n > wire.vic1_max_dim or kk > wire.vic1_max_dim) return error.Invalid;
            // ADR 0053 D3 pins the OUTPUT extent M*N <= 2^22; the operand
            // extents are bound by the buffer checks below.
            if (@as(u64, m) * n > wire.vic1_max_2d_elems) return error.Invalid;
            k.bufs[0].buf = try resolve_buf(k.bufs[0], @as(u64, m) * kk * 2); // A f16 [M,K]
            k.bufs[1].buf = try resolve_buf(k.bufs[1], @as(u64, kk) * n * 2); // B f16
            k.bufs[2].buf = try resolve_buf(k.bufs[2], @as(u64, m) * n * 2); // C f16
            if ((k.flags & wire.gemm_flag_bias) != 0) {
                k.bufs[3].buf = try resolve_buf(k.bufs[3], @as(u64, n) * 2); // bias f16 [N]
            } else try resolve_absent(k.bufs[3]);
        },
        wire.kernel_softmax => {
            if ((k.flags & ~wire.softmax_flag_inplace) != 0) return error.Invalid;
            if (k.d2 != 0 or k.aux != 0 or k.reserved != 0) return error.Invalid;
            const rows = k.d0;
            const cols = k.d1;
            if (rows == 0 or cols < 2) return error.Invalid; // D3: cols in 2..49152
            if (rows > wire.vic1_max_dim or cols > wire.vic1_softmax_max_cols) return error.Invalid;
            if (@as(u64, rows) * cols > wire.vic1_max_2d_elems) return error.Invalid;
            const bytes = @as(u64, rows) * cols * 4;
            const in_buf = k.bufs[0].buf;
            const out_buf = k.bufs[1].buf;
            k.bufs[0].buf = try resolve_buf(k.bufs[0], bytes);
            k.bufs[1].buf = try resolve_buf(k.bufs[1], bytes);
            // in = out is legal only when the caller declared it in-place.
            if (in_buf == out_buf and (k.flags & wire.softmax_flag_inplace) == 0) return error.Invalid;
            try resolve_absent(k.bufs[2]);
            try resolve_absent(k.bufs[3]);
        },
        wire.kernel_dequant => {
            if (k.flags != 0 or k.d2 != 0 or k.reserved != 0) return error.Invalid;
            const n = k.d0;
            const group = k.d1;
            const fmt = k.aux & 0xff;
            if ((k.aux >> 8) != 0) return error.Invalid;
            if (n == 0 or n > wire.vic1_max_elems) return error.Invalid;
            var ok_group = false;
            for (wire.dequant_group_sizes) |g| {
                if (group == g) ok_group = true;
            }
            if (!ok_group) return error.Invalid;
            const groups = (@as(u64, n) + group - 1) / group;
            if (groups > wire.vic1_max_groups) return error.Invalid;
            switch (fmt) {
                wire.dequant_fmt_i8_sym => {
                    k.bufs[0].buf = try resolve_buf(k.bufs[0], n); // q8
                    try resolve_absent(k.bufs[2]); // symmetric has no zeros
                },
                wire.dequant_fmt_u4_asym => {
                    k.bufs[0].buf = try resolve_buf(k.bufs[0], (n + 1) / 2); // packed nibbles
                    k.bufs[2].buf = try resolve_buf(k.bufs[2], groups * 4); // zeros f32
                },
                else => return error.Invalid,
            }
            k.bufs[1].buf = try resolve_buf(k.bufs[1], groups * 4); // scales f32
            k.bufs[3].buf = try resolve_buf(k.bufs[3], @as(u64, n) * 2); // out f16
        },
        else => return error.Invalid, // unknownKernel
    }
}

/// RUN: validate + translate the kernel descriptor, then one fenced
/// COMPUTE_SUBMIT — the only op that moves the submits/completed pair.
fn do_run(d: *const Desc, caller_pid: usize) Error!u64 {
    _ = try session_for(d, caller_pid);
    var k = wire.parse_kernel_desc(&d.kdesc) orelse return error.Invalid;
    try translate_kdesc(&k);
    var env: [wire.compute_submit_req_len]u8 = undefined;
    const f = try take_fence();
    const n = wire.encode_compute_submit(&env, &k, sess.ctx.ctx_id, f);
    try submit_exchange(env[0..n]);
    return 0;
}

/// STATS: the fixed 64-byte block, readable without a handle — any
/// process may read it; only the dst VA must be writable.
fn do_stats(d: *const Desc) Error!u64 {
    var block: Stats = counters;
    block.sessions_live = if (sess.state == .live) 1 else 0;
    block.reserved = 0;
    if (uaccess.copy_out(d.arg_a, std.mem.asBytes(&block), stats_len) != .ok) return error.Access;
    return 0;
}

// ---------------------------------------------------------------------------
// Revocation — the exit funnel calls this for every dying pid
// ---------------------------------------------------------------------------

/// Owner exit revokes the session: the handle's generation is bumped
/// FIRST (every later op on it answers EBADF — the same order cmd-22's
/// `revoke_window` runs), then the bounded drain runs. Pure BSS writes;
/// safe in the exception context the exit path runs in.
pub fn owner_exit(pid: usize) void {
    if (sess.state == .free or sess.owner != pid) return;
    sess.generation +%= 1;
    counters.sessions_live = 0;
    if (drain_session(&sess)) {
        sess.state = .free;
        sess.owner = 0;
        sess.ctx = .{ .ctx_id = 0, .generation = 0 };
        pools_release();
    } else {
        sess.state = .quarantined;
    }
}

/// Test support: reset all session/pool/counter state (device reset is
/// the caller's — this module owns none of it).
pub fn reset_state() void {
    sess = .{};
    io_pool = &.{};
    staging = &.{};
    io_pool_pa = 0;
    staging_pa = 0;
    pools_owned = false;
    io_init();
    counters = .{};
}

/// Test seam: inject bounded BSS pool slices so class-A tests need no
/// armed page allocator — the same trick gpu3d_submit's fake transport
/// uses for the DMA staging.
pub fn test_set_pools(io: []u8, st: []u8) void {
    io_pool = io;
    staging = st;
    io_pool_pa = @intFromPtr(io.ptr);
    staging_pa = @intFromPtr(st.ptr);
    pools_owned = false;
    io_init();
}

// ---------------------------------------------------------------------------
// Tests — the fake-device transcripts pin refusal names and lifecycle
// ---------------------------------------------------------------------------

// A fake Virtio GPU3D device over the injectable transport — the same
// shape gpu3d_submit.zig's tests use: requests are recorded, replies are
// synthesized against the pinned contract (fence echo, ctx echo), the
// VIC1 probe is answerable or not, and resource transfers actually DMA
// between attached guest backing and a bounded per-resource store so
// WRITE/READ round-trips are real.
const CFake = struct {
    reqs: [64][device.req_staging_len]u8 = undefined,
    req_lens: [64]usize = @splat(0),
    req_count: usize = 0,
    resp_stash: []u8 = &.{},
    caps_ready: u32 = 1,
    vic1_present: bool = true,
    vic1_ready: u32 = 1,
    never_complete: bool = false,
    // res&31 → attached guest backing (addr is a VA; mmu is identity on
    // host) + a bounded device-side store the DMA model reads/writes.
    backings: [32]struct { addr: u64, len: u64, live: bool } = @splat(.{ .addr = 0, .len = 0, .live = false }),
    store: [32][8192]u8 = @splat(@splat(0)),
    last_compute: [wire.kernel_desc_len]u8 = @splat(0),
    compute_submits: usize = 0,
};

var cfake: CFake = .{};

fn cfake_reset() void {
    cfake = .{};
}

fn cfake_submit(req: []const u8, resp: []u8) ?u32 {
    const h = cfake.req_count;
    if (h >= cfake.reqs.len) return null;
    cfake.req_lens[h] = req.len;
    @memcpy(cfake.reqs[h][0..req.len], req);
    cfake.req_count += 1;
    const n = @min(resp.len, req.len);
    @memcpy(resp[0..n], req[0..n]); // the reply echoes the request's ctx/fence
    cfake.resp_stash = resp;
    return @intCast(h);
}

fn cfake_wait(handle: u32, budget: usize) ?u32 {
    _ = budget;
    if (cfake.never_complete) return null;
    const req = cfake.reqs[handle][0..cfake.req_lens[handle]];
    const resp = cfake.resp_stash;
    var used: usize = wire.nodata_resp_len;
    const cmd = std.mem.readInt(u32, req[0..4], .little);
    switch (cmd) {
        wire.cmd_get_capset_info => {
            const index = std.mem.readInt(u32, req[24..28], .little);
            if (index == wire.capset_index_compute and !cfake.vic1_present) {
                std.mem.writeInt(u32, resp[0..4], wire.resp_err_unspec, .little);
                return wire.nodata_resp_len;
            }
            used = wire.get_capset_info_resp_len;
            const id: u32 = if (index == wire.capset_index_compute) wire.capset_vic1 else wire.capset_vir1;
            const size: u32 = wire.vir1_payload_len;
            std.mem.writeInt(u32, resp[0..4], wire.resp_ok_capset_info, .little);
            std.mem.writeInt(u32, resp[24..28], id, .little);
            std.mem.writeInt(u32, resp[28..32], 1, .little);
            std.mem.writeInt(u32, resp[32..36], size, .little);
            std.mem.writeInt(u32, resp[36..40], 0, .little);
        },
        wire.cmd_get_capset => {
            const id = std.mem.readInt(u32, req[24..28], .little);
            used = wire.capset_resp_hdr_len + wire.vir1_payload_len;
            std.mem.writeInt(u32, resp[0..4], wire.resp_ok_capset, .little);
            if (id == wire.capset_vic1) {
                wire.encode_vic1_caps(resp[24..][0..32], cfake.vic1_ready);
            } else {
                wire.encode_vir1_caps(resp[24..][0..32], cfake.caps_ready);
            }
        },
        submit.cmd_resource_attach_backing => {
            const res = std.mem.readInt(u32, req[24..28], .little);
            const addr = std.mem.readInt(u64, req[32..40], .little);
            const len = std.mem.readInt(u32, req[40..44], .little);
            cfake.backings[res & 31] = .{ .addr = addr, .len = len, .live = true };
            std.mem.writeInt(u32, resp[0..4], wire.resp_ok_nodata, .little);
        },
        submit.cmd_resource_detach_backing, submit.cmd_resource_unref => {
            const res = std.mem.readInt(u32, req[24..28], .little);
            if (cmd == submit.cmd_resource_detach_backing) cfake.backings[res & 31].live = false;
            std.mem.writeInt(u32, resp[0..4], wire.resp_ok_nodata, .little);
        },
        submit.cmd_transfer_to_host_3d => {
            // box.x = resource offset; offset = offset into the backing.
            const box_x = std.mem.readInt(u32, req[24..28], .little);
            const w = std.mem.readInt(u32, req[36..40], .little);
            const off = std.mem.readInt(u64, req[48..56], .little);
            const res = std.mem.readInt(u32, req[56..60], .little);
            const bk = cfake.backings[res & 31];
            const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(bk.addr + off)));
            const take = @min(@as(usize, @intCast(w)), 8192 - box_x);
            @memcpy(cfake.store[res & 31][box_x..][0..take], src[0..take]);
            std.mem.writeInt(u32, resp[0..4], wire.resp_ok_nodata, .little);
        },
        submit.cmd_transfer_from_host_3d => {
            const box_x = std.mem.readInt(u32, req[24..28], .little);
            const w = std.mem.readInt(u32, req[36..40], .little);
            const off = std.mem.readInt(u64, req[48..56], .little);
            const res = std.mem.readInt(u32, req[56..60], .little);
            const bk = cfake.backings[res & 31];
            const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(bk.addr + off)));
            const take = @min(@as(usize, @intCast(w)), 8192 - box_x);
            @memcpy(dst[0..take], cfake.store[res & 31][box_x..][0..take]);
            std.mem.writeInt(u32, resp[0..4], wire.resp_ok_nodata, .little);
        },
        wire.cmd_compute_submit => {
            @memcpy(&cfake.last_compute, req[wire.hdr_len .. wire.hdr_len + wire.kernel_desc_len]);
            cfake.compute_submits += 1;
            std.mem.writeInt(u32, resp[0..4], wire.resp_ok_nodata, .little);
        },
        else => std.mem.writeInt(u32, resp[0..4], wire.resp_ok_nodata, .little),
    }
    return @intCast(used);
}

fn cfake_release(handle: u32, completed: bool) void {
    _ = handle;
    _ = completed;
}

fn compute_setup() void {
    device.reset_state();
    cfake_reset();
    device.transport = .{ .submit = cfake_submit, .wait = cfake_wait, .release = cfake_release };
    device.g3_ready = true;
    reset_state();
    test_set_pools(test_io_pool[0..], test_staging[0..]);
}

var test_io_pool: [256 * 1024]u8 align(4096) = undefined;
var test_staging: [64 * 1024]u8 align(4096) = undefined;

fn open_desc() Desc {
    return .{ .op = op_open };
}

/// A pinned read-write user aperture for WRITE/READ/STATS tests.
fn arm_user(p: anytype) void {
    uaccess.init();
    _ = uaccess.add_read_region(.{ .base = @intFromPtr(p), .len = @sizeOf(@TypeOf(p.*)) });
    _ = uaccess.add_write_region(.{ .base = @intFromPtr(p), .len = @sizeOf(@TypeOf(p.*)) });
}

test "gpu3d_compute: descriptor is exactly the frozen 128-byte layout" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Desc));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Desc, "op"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Desc, "flags"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Desc, "handle"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Desc, "arg_a"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Desc, "arg_b"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Desc, "arg_c"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Desc, "reserved"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Desc, "reserved2"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(Desc, "kdesc"));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Stats));
}

test "gpu3d_compute: open/alloc/write/run/seal/close lifecycle over the fake device" {
    compute_setup();
    const owner: usize = 7;

    const h = try dispatch(&open_desc(), owner);
    try std.testing.expect(h != 0);
    try std.testing.expect(device.vic1_valid);
    try std.testing.expect(device.caps_valid);

    // Alloc an I/O buffer and a weight buffer.
    var bd: Desc = .{ .op = op_buf_alloc, .handle = h, .arg_a = 4096 };
    const b0 = try dispatch(&bd, owner);
    bd.flags = flag_weight;
    const b1 = try dispatch(&bd, owner);
    try std.testing.expect(b0 != b1);

    // WRITE needs a real armed user aperture.
    var src: [256]u8 = @splat(0xAB);
    uaccess.init();
    try std.testing.expect(uaccess.add_read_region(.{ .base = @intFromPtr(&src), .len = src.len }));
    var wd: Desc = .{ .op = op_write, .handle = b0, .arg_a = @intFromPtr(&src), .arg_b = src.len };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&wd, owner));
    // Overrun refuses before the device.
    wd.arg_b = 4097;
    try std.testing.expectError(error.Invalid, dispatch(&wd, owner));
    wd.arg_b = 4096 - 16;
    wd.arg_c = 32; // 32 + 4080 > 4096
    try std.testing.expectError(error.Invalid, dispatch(&wd, owner));

    // RUN: a GEMM descriptor binding the two buffers + a third.
    var bd3: Desc = .{ .op = op_buf_alloc, .handle = h, .arg_a = 4096 };
    const b2 = try dispatch(&bd3, owner);
    var kd: wire.KernelDesc = .{
        .kernel_id = wire.kernel_gemm,
        .d0 = 2,
        .d1 = 2,
        .d2 = 2,
        .bufs = .{
            .{ .buf = @truncate(b0), .byte_off = 0 },
            .{ .buf = @truncate(b1), .byte_off = 0 },
            .{ .buf = @truncate(b2), .byte_off = 0 },
            .{},
        },
    };
    var rd: Desc = .{ .op = op_run, .handle = h };
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&rd, owner));
    try std.testing.expectEqual(@as(u64, 1), counters.submits);
    try std.testing.expectEqual(@as(u64, 1), counters.completed);

    // CLOSE.
    var cd: Desc = .{ .op = op_close, .handle = h };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&cd, owner));
    try std.testing.expectEqual(SessState.free, sess.state);
    // The stale handle stays stale.
    try std.testing.expectError(error.BadHandle, dispatch(&cd, owner));
}

test "gpu3d_compute: refusals move only the refusal counter" {
    compute_setup();
    const owner: usize = 9;
    const h = try dispatch(&open_desc(), owner);
    const before = counters.submits;

    // Unknown kernel id refuses before the device.
    var kd: wire.KernelDesc = .{ .kernel_id = 99 };
    var rd: Desc = .{ .op = op_run, .handle = h };
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));
    try std.testing.expectEqual(before, counters.submits);
    try std.testing.expect(counters.refusals > 0);

    // A foreign pid holding the real handle is refused.
    var cd: Desc = .{ .op = op_close, .handle = h };
    try std.testing.expectError(error.BadHandle, dispatch(&cd, owner + 1));

    // Sealed buffer refuses WRITE.
    var bd: Desc = .{ .op = op_buf_alloc, .handle = h, .arg_a = 64 };
    const b = try dispatch(&bd, owner);
    var sd: Desc = .{ .op = op_seal, .handle = b };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&sd, owner));
    var src: [8]u8 = @splat(0);
    uaccess.init();
    _ = uaccess.add_read_region(.{ .base = @intFromPtr(&src), .len = src.len });
    var wd: Desc = .{ .op = op_write, .handle = b, .arg_a = @intFromPtr(&src), .arg_b = 8 };
    try std.testing.expectError(error.Invalid, dispatch(&wd, owner));

    // Freeing a sealed buffer is legal (the backing already detached);
    // the slot's old handle then goes stale.
    var fd: Desc = .{ .op = op_buf_free, .handle = b };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&fd, owner));
    try std.testing.expectError(error.BadHandle, dispatch(&fd, owner));
}

test "gpu3d_compute: absent VIC1 and ready=0 both answer Unsupported" {
    compute_setup();
    cfake.vic1_present = false;
    try std.testing.expectError(error.Unsupported, dispatch(&open_desc(), 3));

    compute_setup();
    cfake.vic1_ready = 0;
    try std.testing.expectError(error.Unsupported, dispatch(&open_desc(), 3));

    compute_setup();
    device.g3_ready = false;
    try std.testing.expectError(error.Unsupported, dispatch(&open_desc(), 3));
}

test "gpu3d_compute: READ round-trips what WRITE pushed through the fake DMA" {
    compute_setup();
    const owner: usize = 11;
    const h = try dispatch(&open_desc(), owner);
    var bd: Desc = .{ .op = op_buf_alloc, .handle = h, .arg_a = 512 };
    const b = try dispatch(&bd, owner);

    var src: [512]u8 = undefined;
    for (&src, 0..) |*c, i| c.* = @truncate(i *% 31 +% 7);
    var dst: [512]u8 = @splat(0);
    uaccess.init();
    _ = uaccess.add_read_region(.{ .base = @intFromPtr(&src), .len = src.len });
    _ = uaccess.add_write_region(.{ .base = @intFromPtr(&dst), .len = dst.len });

    var wd: Desc = .{ .op = op_write, .handle = b, .arg_a = @intFromPtr(&src), .arg_b = 256, .arg_c = 64 };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&wd, owner));
    var rd: Desc = .{ .op = op_read, .handle = b, .arg_a = @intFromPtr(&dst), .arg_b = 256, .arg_c = 64 };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&rd, owner));
    try std.testing.expectEqualSlices(u8, src[0..256], dst[0..256]);
}

test "gpu3d_compute: STATS reports the live counters to any reader" {
    compute_setup();
    const owner: usize = 13;
    _ = try dispatch(&open_desc(), owner);
    var block: Stats = .{};
    uaccess.init();
    _ = uaccess.add_write_region(.{ .base = @intFromPtr(&block), .len = @sizeOf(Stats) });
    // A DIFFERENT pid reads stats — no handle, no owner check.
    var sd: Desc = .{ .op = op_stats, .arg_a = @intFromPtr(&block) };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&sd, 99));
    try std.testing.expectEqual(@as(u32, 1), block.sessions_live);
}

test "gpu3d_compute: a timed-out exchange poisons; ops answer LostContext until drain" {
    compute_setup();
    const owner: usize = 17;
    const h = try dispatch(&open_desc(), owner);
    cfake.never_complete = true;
    var bd: Desc = .{ .op = op_buf_alloc, .handle = h, .arg_a = 64 };
    try std.testing.expectError(error.TimedOut, dispatch(&bd, owner));
    try std.testing.expectEqual(SessState.poisoned, sess.state);
    try std.testing.expect(counters.timeouts > 0);
    // Every non-CLOSE op is ENOENT now; the device recovers but the
    // session does not.
    cfake.never_complete = false;
    try std.testing.expectError(error.LostContext, dispatch(&bd, owner));
    var cd: Desc = .{ .op = op_close, .handle = h };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&cd, owner));
    try std.testing.expectEqual(SessState.free, sess.state);
    // A fresh OPEN succeeds after the drain.
    const h2 = try dispatch(&open_desc(), owner);
    try std.testing.expect(h2 != 0 and h2 != h);
}

test "gpu3d_compute: second live OPEN is Exhausted; owner-exit revokes" {
    compute_setup();
    const owner: usize = 19;
    const h = try dispatch(&open_desc(), owner);
    try std.testing.expectError(error.Exhausted, dispatch(&open_desc(), owner));
    try std.testing.expectError(error.Exhausted, dispatch(&open_desc(), owner + 1));
    // Owner exit: handles die, the ctx returns to the shared pool.
    owner_exit(owner);
    try std.testing.expectEqual(SessState.free, sess.state);
    try std.testing.expectEqual(@as(usize, 0), device.live_count());
    var cd: Desc = .{ .op = op_close, .handle = h };
    try std.testing.expectError(error.BadHandle, dispatch(&cd, owner));
    const h2 = try dispatch(&open_desc(), owner + 5);
    try std.testing.expect(h2 != 0);
}

test "gpu3d_compute: the D3 shape bounds refuse before any device submission" {
    compute_setup();
    const owner: usize = 29;
    const h = try dispatch(&open_desc(), owner);
    var bd: Desc = .{ .op = op_buf_alloc, .handle = h, .arg_a = 256 * 1024 };
    const big = try dispatch(&bd, owner);

    // SOFTMAX cols must be >= 2 (D3: cols in 2..49152) — cols=1 and
    // cols=49153 are both badKernelShape, and 4097*49152 rows*cols
    // overruns the pinned 2^22 product bound anyway.
    var kd: wire.KernelDesc = .{
        .kernel_id = wire.kernel_softmax,
        .d0 = 1,
        .d1 = 1,
        .bufs = .{ .{ .buf = @truncate(big), .byte_off = 0 }, .{ .buf = @truncate(big), .byte_off = 0 }, .{}, .{} },
    };
    var rd: Desc = .{ .op = op_run, .handle = h };
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    const submits_before = counters.submits;
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));
    kd.flags = wire.softmax_flag_inplace; // same buf twice is legal ONLY in-place
    kd.d1 = 49153;
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));
    kd.d0 = 4097; // rows beyond the per-dim bound
    kd.d1 = 2;
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));

    // GEMM: M*N over the pinned 2^22 output bound refuses; a dim of 0
    // and an out-of-profile dim refuse the same way.
    kd = .{
        .kernel_id = wire.kernel_gemm,
        .d0 = 4096,
        .d1 = 4096,
        .d2 = 1, // M*N = 2^24 > 2^22
        .bufs = .{ .{ .buf = @truncate(big), .byte_off = 0 }, .{ .buf = @truncate(big), .byte_off = 0 }, .{ .buf = @truncate(big), .byte_off = 0 }, .{} },
    };
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));
    kd.d0 = 0;
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));

    // GEMM with an unknown flag bit is badKernelShape, not a bind error.
    kd = .{ .kernel_id = wire.kernel_gemm, .flags = 4, .d0 = 1, .d1 = 1, .d2 = 1 };
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));

    // DEQUANT: fmt 0 and a group size outside {32,64,128} refuse.
    kd = .{ .kernel_id = wire.kernel_dequant, .d0 = 128, .d1 = 96, .aux = wire.dequant_fmt_i8_sym };
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));
    kd.d1 = 64;
    kd.aux = 0; // no such fmt
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));

    try std.testing.expectEqual(submits_before, counters.submits); // nothing posted
    try std.testing.expect(counters.refusals >= 7);
}

test "gpu3d_compute: sixteen buffers then Exhausted; stale buffer refuses RUN binds" {
    compute_setup();
    const owner: usize = 23;
    const h = try dispatch(&open_desc(), owner);
    var handles: [max_bufs]u64 = undefined;
    var bd: Desc = .{ .op = op_buf_alloc, .handle = h, .arg_a = 64 };
    for (&handles) |*hh| hh.* = try dispatch(&bd, owner);
    try std.testing.expectError(error.Exhausted, dispatch(&bd, owner));
    // A stale buffer (freed then rebound) in a kernel desc refuses.
    var fd: Desc = .{ .op = op_buf_free, .handle = handles[0] };
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&fd, owner));
    const reborn = try dispatch(&bd, owner);
    var kd: wire.KernelDesc = .{
        .kernel_id = wire.kernel_softmax,
        .d0 = 1,
        .d1 = 4,
        .bufs = .{
            .{ .buf = @truncate(handles[0]), .byte_off = 0 }, // STALE
            .{ .buf = @truncate(handles[1]), .byte_off = 0 },
            .{},
            .{},
        },
    };
    var rd: Desc = .{ .op = op_run, .handle = h };
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectError(error.Invalid, dispatch(&rd, owner));
    // The translated wire descriptor names resource ids, not handles.
    kd.bufs[0].buf = @truncate(reborn);
    kd.bufs[1].buf = @truncate(handles[1]);
    wire.encode_kernel_desc(&rd.kdesc, &kd);
    try std.testing.expectEqual(@as(u64, 0), try dispatch(&rd, owner));
    const sent = wire.parse_kernel_desc(&cfake.last_compute).?;
    try std.testing.expect(sent.bufs[0].buf != 0 and sent.bufs[0].buf != @as(u32, @truncate(reborn)));
    try std.testing.expectEqual(sess.ctx.ctx_id * 256 + 1, sent.bufs[0].buf);
}
