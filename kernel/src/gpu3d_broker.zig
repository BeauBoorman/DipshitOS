//! VirelaiOS experimental GPU3D — the slot-65 cmd-22 typed bridge (M102d1,
//! issue #2166 — card of the M102 index, issue #2160).
//!
//! This module is the kernel-side broker between the registered window-
//! manager seat and c1's bounded submission layer (gpu3d_submit.zig on top
//! of gpu3d_device.zig). It owns the contract the index's §7 pins:
//!
//!   * ONE typed 64-byte descriptor per call (layout + per-op field rules
//!     frozen in ADR 0007). The syscall layer copies it through checked
//!     uaccess BEFORE dispatch; this file never sees a user pointer and
//!     never retains one.
//!   * Seven operations: CREATE, CLEAR, TRIANGLE, PRESENT, POLL, PUBLISH,
//!     CLOSE. Unknown operations fail closed. a0..a2 of the syscall are
//!     reserved-zero for cmd 22.
//!   * Generation-bearing handles (gen:48 << 16 | ctx_id:16). A stale or
//!     dead handle is EBADF; a handle resolving to a quarantined session
//!     is ENOENT (lost context) — never the same name twice.
//!   * Verification on EVERY operation: registered seat, live window,
//!     unchanged window owner, descriptor bounds, context ownership and
//!     generation. The caller's pid is never trusted as an identity input
//!     beyond the seat match, and no caller-supplied physical address
//!     exists anywhere in the contract.
//!   * PUBLISH draws nothing: it copies the staged readback for the
//!     CURRENT completed frame into the window's ordinary pixel store
//!     (bound surface or kernel back-buffer) at the client origin, with
//!     the destination's row stride, clipped to the client rect, and
//!     clears the rest through ordinary 2D drawing (#2160 §8). Window,
//!     owner, surface capacity and the seat's captured geometry are all
//!     re-validated immediately before the copy.
//!   * Window close / owner exit / WM unregister revoke contexts
//!     immediately and non-blockingly: the handle is invalidated FIRST
//!     (generation bump), then the bounded drain runs. A device that
//!     cannot drain leaves the session quarantined — pinned backing
//!     preserved for late DMA — and the next CREATE retries the drain
//!     before refusing pool exhaustion.
//!
//! Pending, unsupported, invalid, exhausted, timeout and lost-context
//! stay DISTINCT named errors (the Error set below → the frozen ADR
//! 0007 errno table). No syscall slot is added; cmd 22 rides the
//! existing slot-65 WM-exclusive surface.
//!
//! No libc, no POSIX, no allocation — pure kernel BSS on top of c1's
//! pinned pools.

const std = @import("std");
const builtin = @import("builtin");
const device = @import("gpu3d_device.zig");
const submit = @import("gpu3d_submit.zig");
const stream = @import("gpu3d_stream.zig");
const wire = @import("gpu3d_wire.zig");
const driving_award = @import("driving_award.zig");
const wm_server = @import("wm_server.zig");

// ---------------------------------------------------------------------------
// Frozen descriptor (ADR 0007 amendment — M102d1) — 64 bytes, little-endian.
// Copied in through checked uaccess by the slot-65 handler BEFORE dispatch;
// every field not listed for an operation is reserved and must be zero.
// ---------------------------------------------------------------------------

pub const desc_len: usize = 64;

/// Operations (desc.op). 0 and anything past CLOSE fail closed.
pub const op_create: u32 = 1;
pub const op_clear: u32 = 2;
pub const op_triangle: u32 = 3;
pub const op_present: u32 = 4;
pub const op_poll: u32 = 5;
pub const op_publish: u32 = 6;
pub const op_close: u32 = 7;

/// The app-facing wire vertex (#2160 §5), as it appears INSIDE the
/// descriptor: i16 LE normalized x/y, u16 LE normalized z, u16 LE
/// RGB565 — exactly 8 bytes. Converted field-by-field into c1's
/// stream.WireVertex at TRIANGLE time (no layout is ever assumed).
pub const Vert = extern struct {
    x: i16 = 0,
    y: i16 = 0,
    z: u16 = 0,
    rgb565: u16 = 0,
};

/// The frozen 64-byte cmd-22 descriptor (ptr/len args of sys_wmctl):
///   off  size  field      per-op rules (all others must be 0)
///   0    4     op         1..7, required
///   4    4     flags      always 0
///   8    8     handle     CREATE: 0 — all other ops: the CREATE result
///   16   4     window_id  the bound user window, required on every op
///   20   4     width      CREATE: render extent; PUBLISH: captured
///                         client width; else 0
///   24   4     height     same rule as width
///   28   4     rgb        CLEAR: 0x00RRGGBB; else 0
///   32   24    verts      TRIANGLE: exactly three wire vertices; else
///                         every byte 0
///   56   8     reserved   always 0
pub const Desc = extern struct {
    op: u32 = 0,
    flags: u32 = 0,
    handle: u64 = 0,
    window_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    rgb: u32 = 0,
    verts: [3]Vert = .{ .{}, .{}, .{} },
    reserved: u64 = 0,
};

comptime {
    if (@sizeOf(Desc) != desc_len) @compileError("cmd-22 descriptor must stay exactly 64 bytes");
    if (@sizeOf(Vert) != 8) @compileError("wire vertex must stay exactly 8 bytes");
    if (@offsetOf(Desc, "verts") != 32 or @offsetOf(Desc, "reserved") != 56) @compileError("descriptor offsets moved — the ABI is frozen");
}

/// The named error contract (ADR 0007): each maps to exactly one errno at
/// the syscall boundary so pending/unsupported/invalid/exhausted/timeout/
/// lost-context never collapse into each other.
pub const Error = error{
    /// Malformed descriptor or window state: bad op, nonzero reserved,
    /// out-of-bounds geometry, foreign window binding, stale publish
    /// geometry, absent/revoked/undersized destination. → EINVAL
    Invalid,
    /// Handle is zero/out-of-range, generation-stale or names a dead
    /// context. → EBADF
    BadHandle,
    /// No WM is registered. → ENOSYS
    NoSeat,
    /// The caller is not the registered seat. → EACCES
    ForeignSeat,
    /// The bound window is gone or its owner changed. → EINVAL
    BadWindow,
    /// Context pool exhausted or a quarantined slot cannot drain. → ENOSPC
    Exhausted,
    /// Render device absent, caps unprobed, renderer not ready, or the
    /// device does not speak the VIR1 profile. → ENXIO
    Unsupported,
    /// No completed frame / staged pixels for this op, or the device is
    /// busy with the one outstanding request. → EAGAIN
    Pending,
    /// A device exchange hit its completion deadline. → ETIMEDOUT
    TimedOut,
    /// The handle resolved but its session is quarantined (post-timeout)
    /// or its backing was revoked. → ENOENT
    LostContext,
    /// Device-level protocol/submission fault. → EIO
    DeviceFault,
};

// ---------------------------------------------------------------------------
// Context pool — one record per device context slot (VIR1 `contexts` = 2),
// one context per hosted window. The record index IS the ctx_id (index+1),
// so a handle's low 16 bits name the record and the high 48 name its
// generation — a recycled slot can never be driven by a stale handle.
// ---------------------------------------------------------------------------

pub const max_contexts: usize = device.max_contexts; // 2

const Rec = struct {
    /// A usable context lives here (the descriptor-facing lifetime).
    live: bool = false,
    /// The slot still owns a submit-layer session (close may have failed
    /// and left it quarantined — retried by alloc_slot).
    owned: bool = false,
    /// Bumped on every open and every kill; high bits of the handle.
    generation: u64 = 0,
    window_id: u8 = 0,
    /// The window's owner pid captured at CREATE — re-verified per op so a
    /// window-id recycling app can never inherit the context.
    owner: usize = 0,
    extent_w: u32 = 0,
    extent_h: u32 = 0,
    session: submit.Session = .{ .ctx_id = 0, .generation = 0, .ctx_generation = 0 },
    /// The pending frame's clear color — floats for the stream, u32
    /// 0xRRGGBB for the 2D clear-rest fill at PUBLISH.
    clear: [4]f32 = .{ 0, 0, 0, 1 },
    clear_rgb: u32 = 0,
    verts: [3]stream.WireVertex = @splat(.{ .x = 0, .y = 0, .z = 0, .rgb565 = 0 }),
};

var recs: [max_contexts]Rec = .{ .{}, .{} };

/// Total live contexts (observability + the rejection counter tests).
pub fn live_count() usize {
    var n: usize = 0;
    for (recs) |r| {
        if (r.live) n += 1;
    }
    return n;
}

fn verts_zero(v: *const [3]Vert) bool {
    for (v) |w| {
        if (w.x != 0 or w.y != 0 or w.z != 0 or w.rgb565 != 0) return false;
    }
    return true;
}

/// Descriptor bound authority (the revert-fails seam): every operation's
/// allowed fields are checked here — unknown ops, nonzero reserved bytes,
/// out-of-profile geometry and fields used outside their op all refuse
/// before any device submission. Flipping this to false lets malformed
/// descriptors reach the device; the no-submit test goes red.
pub const enforce_descriptor_bounds: bool = true;

/// Handle/window generation authority (the revert-fails seam): a handle's
/// generation must match the live record and the descriptor's window must
/// be the bound window. Flipping this to false resolves a stale handle
/// onto the recycled slot; the stale-handle test goes red.
pub const enforce_generations: bool = true;

fn check_descriptor(d: *const Desc) Error!void {
    if (d.flags != 0 or d.reserved != 0) return error.Invalid;
    if (d.window_id == 0 or d.window_id > 0xff) return error.Invalid;
    switch (d.op) {
        op_create => {
            if (d.handle != 0 or d.rgb != 0 or !verts_zero(&d.verts)) return error.Invalid;
            if (d.width == 0 or d.width > wire.vir1_max_width or
                d.height == 0 or d.height > wire.vir1_max_height) return error.Invalid;
        },
        op_clear => {
            if (d.width != 0 or d.height != 0 or !verts_zero(&d.verts)) return error.Invalid;
            if (d.rgb > 0xffffff) return error.Invalid; // 0x00RRGGBB only
        },
        op_triangle => {
            if (d.rgb != 0 or d.width != 0 or d.height != 0) return error.Invalid;
        },
        op_present, op_poll, op_close => {
            if (d.rgb != 0 or d.width != 0 or d.height != 0 or !verts_zero(&d.verts)) return error.Invalid;
        },
        op_publish => {
            if (d.rgb != 0 or !verts_zero(&d.verts)) return error.Invalid;
            if (d.width == 0 or d.width > driving_award.user_win_max_w or
                d.height == 0 or d.height > driving_award.user_win_max_h) return error.Invalid;
        },
        else => return error.Invalid,
    }
}

/// Resolve a handle-bearing descriptor to its live record — the per-op
/// identity + last lifetime check (#2166 design 2 + acceptance 4):
/// generation, bound window, window still extant, owner unchanged.
fn verify(d: *const Desc) Error!*Rec {
    const ctx_id: u32 = @truncate(d.handle & 0xffff);
    if (ctx_id == 0 or ctx_id > max_contexts) return error.BadHandle;
    const rec = &recs[ctx_id - 1];
    if (!rec.live) return error.BadHandle;
    if (enforce_generations) {
        const gen = d.handle >> 16;
        if (gen != (rec.generation & 0xffffffffffff)) return error.BadHandle;
        if (d.window_id != rec.window_id) return error.BadHandle;
    } else {
        // REVERT SEAM — generation + window-binding verification bypassed
        // (must never ship): a stale handle silently resolves the recycled
        // slot and drives someone else's context.
    }
    const win = driving_award.find_user_window(rec.window_id) orelse return error.BadWindow;
    if (win.owner == null or win.owner.? != rec.owner) return error.BadWindow;
    return rec;
}

fn handle_of(r: *const Rec) u64 {
    return ((r.generation & 0xffffffffffff) << 16) | r.session.ctx_id;
}

fn bound_slot(wid: u8) ?usize {
    for (&recs, 0..) |*r, i| {
        if (r.live and r.window_id == wid) return i;
    }
    return null;
}

/// Invalidate the handle BEFORE any device wait (revocation is immediate),
/// then run c1's bounded drain. A failed drain leaves the session
/// quarantined — `owned` stays set so the pinned backing is never freed
/// under a device that may still be writing it, and the next CREATE
/// retries the drain through alloc_slot.
fn kill_rec(r: *Rec) void {
    r.live = false;
    r.generation +%= 1;
    submit.close(r.session) catch {
        return; // quarantined — late-DMA pages preserved
    };
    r.owned = false;
}

/// First free slot: clean slots take no work; a slot whose submit session
/// still owns resources retries its drain NOW (a confirmed-recovery
/// close, then c1's retire for failed-open residue). Returns null only
/// when every slot is either live or still quarantined.
fn alloc_slot() ?usize {
    for (&recs, 0..) |*r, i| {
        if (r.live) continue;
        if (r.owned) {
            submit.close(r.session) catch continue;
            r.owned = false;
        } else {
            submit.retire(@intCast(i + 1)) catch continue;
        }
        return i;
    }
    return null;
}

/// Map every device/submit-layer error onto the broker's frozen set — the
/// one place device vocabulary becomes the syscall's named errors.
fn map(e: anyerror) Error {
    return switch (e) {
        error.Unsupported, error.CapsNotReady, error.NotReady, error.CapsetProfile, error.CapsetVersion, error.CapsetSize, error.CapsetBounds => error.Unsupported,
        error.BadRequest, error.BadGeometry, error.BadStream, error.OutTooSmall => error.Invalid,
        error.BadSession, error.StaleSession, error.BadHandle, error.StaleHandle, error.ZeroContext => error.BadHandle,
        error.DuplicateHandle, error.ContextExhausted, error.FenceExhausted => error.Exhausted,
        error.Poisoned => error.LostContext,
        error.NoFrame, error.NoPixels, error.Busy => error.Pending,
        error.Timeout => error.TimedOut,
        error.SubmitFailed, error.ResponseTruncated, error.ResponseOversized, error.BadResponse, error.CapsetTruncated, error.StreamTooBig => error.DeviceFault,
        else => error.DeviceFault,
    };
}

// ---------------------------------------------------------------------------
// Entry — seat check → descriptor bounds → per-op verify → device work.
// Nothing below this line may touch user memory: the descriptor is the
// handler's kernel-owned copy.
// ---------------------------------------------------------------------------

pub fn dispatch(d: *const Desc, caller_pid: usize) Error!u64 {
    // The broker re-verifies the registered seat on EVERY operation (#2166
    // design 2) — it never trusts that a layer above already checked.
    const seat = wm_server.registered_pid() orelse return error.NoSeat;
    if (seat != caller_pid) return error.ForeignSeat;

    if (enforce_descriptor_bounds) {
        try check_descriptor(d);
    } else {
        // REVERT SEAM — descriptor bound check bypassed (must never ship):
        // unknown ops still fail closed, but reserved bytes, out-of-profile
        // geometry and op-foreign fields pass straight to the device.
        if (d.op == 0 or d.op > op_close) return error.Invalid;
    }

    return switch (d.op) {
        op_create => create(d),
        op_clear => clear_op(d),
        op_triangle => triangle_op(d),
        op_present => present_op(d),
        op_poll => poll_op(d),
        op_publish => publish_op(d),
        op_close => close_op(d),
        else => error.Invalid,
    };
}

/// CREATE — bind a bounded render context to a live user window. Returns
/// the generation-bearing handle. Idempotent on the same extent; an
/// extent change invalidates the old generation and re-opens (#2160 §8).
fn create(d: *const Desc) Error!u64 {
    const wid: u8 = @truncate(d.window_id);
    const win = driving_award.find_user_window(wid) orelse return error.BadWindow;
    const owner = win.owner orelse return error.BadWindow;

    if (!device.g3_ready) return error.Unsupported;
    if (!device.caps_valid) {
        _ = device.probe_caps() catch |e| return map(e);
    }

    if (bound_slot(wid)) |i| {
        const rec = &recs[i];
        if (rec.extent_w == d.width and rec.extent_h == d.height) return handle_of(rec);
        kill_rec(rec);
    }

    const slot = alloc_slot() orelse return error.Exhausted;
    const sess = submit.open(@intCast(slot + 1), d.width, d.height) catch |e| return map(e);
    const rec = &recs[slot];
    rec.live = true;
    rec.owned = true;
    rec.generation +%= 1;
    rec.window_id = wid;
    rec.owner = owner;
    rec.extent_w = d.width;
    rec.extent_h = d.height;
    rec.session = sess;
    rec.clear = .{ 0, 0, 0, 1 };
    rec.clear_rgb = 0;
    rec.verts = @splat(.{ .x = 0, .y = 0, .z = 0, .rgb565 = 0 });
    return handle_of(rec);
}

/// CLEAR — stage the pending frame's clear color (no device work: the
/// color rides the next PRESENT's stream, and doubles as the 2D
/// clear-rest fill at PUBLISH).
fn clear_op(d: *const Desc) Error!u64 {
    const rec = try verify(d);
    rec.clear_rgb = d.rgb;
    rec.clear = .{
        @as(f32, @floatFromInt((d.rgb >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((d.rgb >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(d.rgb & 0xff)) / 255.0,
        1.0,
    };
    return 0;
}

/// TRIANGLE — stage the one bounded triangle (replaces the pending
/// frame's geometry; no accumulation, no device work).
fn triangle_op(d: *const Desc) Error!u64 {
    const rec = try verify(d);
    for (&rec.verts, d.verts) |*dst, src| {
        dst.* = .{ .x = src.x, .y = src.y, .z = src.z, .rgb565 = src.rgb565 };
    }
    return 0;
}

/// PRESENT — upload + SUBMIT_3D; returns only after the fence-matched
/// response marks the frame complete (c1's bounded wait — never a syscall
/// sleep).
fn present_op(d: *const Desc) Error!u64 {
    const rec = try verify(d);
    submit.submit_frame(rec.session, rec.clear, &rec.verts) catch |e| return map(e);
    return 0;
}

/// POLL — 1 when a completed frame's pixels are staged for PUBLISH, 0
/// when no completed frame exists (pending). Stages the bounce readback
/// for the newest completed frame — device work belongs here, never in
/// PUBLISH.
fn poll_op(d: *const Desc) Error!u64 {
    const rec = try verify(d);
    const ready = submit.frame_pending(rec.session) catch |e| return map(e);
    if (!ready) return 0;
    _ = submit.pixels(rec.session) catch |e| {
        if (e == error.NoPixels) {
            _ = submit.readback(rec.session) catch |e2| return map(e2);
        } else {
            return map(e);
        }
    };
    return 1;
}

/// PUBLISH — copy ONLY the staged readback of the current completed frame
/// into the window's ordinary pixels. No new draw, no DMA into app pages:
/// a bounded CPU copy at the client origin with the destination's real
/// row stride, clipped to the client rect; the rest is cleared through
/// ordinary 2D drawing (#2160 §8). Destination window, owner, captured
/// geometry and surface capacity are all re-validated immediately before
/// the copy — the last lifetime check, not the first.
fn publish_op(d: *const Desc) Error!u64 {
    const rec = try verify(d);
    const px = submit.pixels(rec.session) catch |e| {
        if (e == error.NoPixels or e == error.NoFrame) return error.Pending;
        return map(e);
    };
    const win = driving_award.find_user_window(rec.window_id) orelse return error.BadWindow;
    if (win.owner == null or win.owner.? != rec.owner) return error.BadWindow;
    // Stale captured geometry: the seat's client-extent snapshot must
    // equal the window's THIS-MOMENT rect (resize between capture and
    // publish invalidates the capture, #2160 §8).
    if (d.width != win.w or d.height != win.h) return error.Invalid;
    const dest = driving_award.user_paint_dest(rec.window_id) orelse return error.Invalid;
    const cw: usize = @min(rec.extent_w, dest.w);
    const ch: usize = @min(rec.extent_h, dest.h);
    const stride: usize = dest.stride;
    const clears_rest = (cw < dest.w) or (ch < dest.h);
    if (clears_rest) {
        if (cw < dest.w) driving_award.fill_rect(dest.base, stride, cw, 0, dest.w - cw, dest.h, rec.clear_rgb);
        if (ch < dest.h) driving_award.fill_rect(dest.base, stride, 0, ch, cw, dest.h - ch, rec.clear_rgb);
    }
    var y: usize = 0;
    while (y < ch) : (y += 1) {
        @memcpy(dest.base[y * stride ..][0 .. cw * 4], px[y * @as(usize, rec.extent_w) * 4 ..][0 .. cw * 4]);
    }
    _ = driving_award.mark_damage(rec.window_id, 0, 0, if (clears_rest) dest.w else @intCast(cw), if (clears_rest) dest.h else @intCast(ch));
    return 0;
}

/// CLOSE — drain the context (bounded; c1's order: detach resources,
/// detach backing, unref, destroy context). The handle is invalidated
/// FIRST; a device that cannot drain leaves the session quarantined —
/// backing pinned for late DMA — and the refusal stays named.
fn close_op(d: *const Desc) Error!u64 {
    const rec = try verify(d);
    kill_rec(rec);
    if (rec.owned) return error.DeviceFault; // drain refused — quarantined
    return 0;
}

// ---------------------------------------------------------------------------
// Lifetime revocation — the three seams the card owns:
//   * window close / owner exit → driving_award.remove_user_at → revoke_window
//   * WM unregister → wm_server.unregister → revoke_all
//   * registry/seam resets → driving_award.arm + wm_server.init → reset_state
// All non-blocking: the handle dies before the bounded drain starts.
// ---------------------------------------------------------------------------

/// Revoke every context bound to window `id` (called from remove_user_at —
/// the one funnel for user_close, close_owner and surface_revoked).
pub fn revoke_window(id: u8) void {
    for (&recs) |*r| {
        if (r.live and r.window_id == id) kill_rec(r);
    }
}

/// Revoke every context — the seat died, so nothing may publish again.
pub fn revoke_all() void {
    for (&recs) |*r| {
        if (r.live) kill_rec(r);
    }
}

/// Pure BSS wipe (boot + host-test resets; mirrors c1's reset_state —
/// no device I/O). Live contexts, if any, are dropped handle-side; the
/// device-side teardown stays c1's problem.
pub fn reset_state() void {
    recs = .{ .{}, .{} };
}

// ---------------------------------------------------------------------------
// Tests — a fake device over the SAME injectable transport seam b1/c1's
// suites drive (class A), plus real wm_server/driving_award seams so the
// lifetime proofs exercise the production call paths.
// ---------------------------------------------------------------------------

const testing = std.testing;

const FakeDev = struct {
    reqs: [64][device.req_staging_len]u8 = undefined,
    req_lens: [64]usize = @splat(0),
    req_count: usize = 0,
    resp_stash: []u8 = &.{},
    wait_calls: usize = 0,
    never_complete: bool = false,
    die_at: ?u32 = null,
    caps_ready: u32 = 1,
    backings: [8]Backing = @splat(.{ .addr = 0, .len = 0, .live = false }),
    dma_marker: u8 = 0x5a,
};

const Backing = struct { addr: u64, len: u32, live: bool };

var fake_dev: FakeDev = .{};

fn fake_type() u32 {
    return std.mem.readInt(u32, fake_dev.resp_stash[0..4], .little);
}
fn fake_ctx() u32 {
    return std.mem.readInt(u32, fake_dev.resp_stash[16..20], .little);
}
fn fake_fence() u64 {
    return std.mem.readInt(u64, fake_dev.resp_stash[8..16], .little);
}

fn fake_submit(req: []const u8, resp: []u8) ?u32 {
    const h = fake_dev.req_count;
    if (h >= fake_dev.reqs.len) return null;
    fake_dev.req_lens[h] = req.len;
    @memcpy(fake_dev.reqs[h][0..req.len], req);
    fake_dev.req_count += 1;
    const n = @min(resp.len, req.len);
    @memcpy(resp[0..n], req[0..n]);
    fake_dev.resp_stash = resp;
    return @intCast(h);
}

fn backing_slot(res: u32) *Backing {
    return &fake_dev.backings[res & 7];
}

fn fake_wait(handle: u32, budget: usize) ?u32 {
    _ = budget;
    fake_dev.wait_calls += 1;
    if (fake_dev.never_complete) return null;
    if (fake_dev.die_at) |d| if (handle >= d) return null;
    const req = fake_dev.reqs[handle][0..fake_dev.req_lens[handle]];
    const cmd = fake_type();
    const resp = fake_dev.resp_stash;

    var used: usize = wire.nodata_resp_len;
    switch (cmd) {
        wire.cmd_get_capset_info => used = wire.get_capset_info_resp_len,
        wire.cmd_get_capset => used = wire.capset_resp_hdr_len + wire.vir1_payload_len,
        submit.cmd_transfer_to_host_3d => {
            const res = std.mem.readInt(u32, req[56..60], .little);
            const len = std.mem.readInt(u32, req[36..40], .little);
            _ = backing_slot(res);
            _ = len;
        },
        submit.cmd_transfer_from_host_3d => {
            const res = std.mem.readInt(u32, req[56..60], .little);
            const w = std.mem.readInt(u32, req[36..40], .little);
            const h = std.mem.readInt(u32, req[40..44], .little);
            const slot = backing_slot(res);
            const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(slot.addr)));
            const len = @min(@as(usize, w) * @as(usize, h) * 4, slot.len);
            for (0..len) |i| dst[i] = fake_dev.dma_marker ^ @as(u8, @truncate(i & 0x3f));
        },
        submit.cmd_resource_attach_backing => {
            const res = std.mem.readInt(u32, req[24..28], .little);
            const addr = std.mem.readInt(u64, req[32..40], .little);
            const len = std.mem.readInt(u32, req[40..44], .little);
            fake_dev.backings[res & 7] = .{ .addr = addr, .len = len, .live = true };
        },
        submit.cmd_resource_unref => {
            const res = std.mem.readInt(u32, req[24..28], .little);
            fake_dev.backings[res & 7].live = false;
        },
        else => {},
    }

    const want_type = switch (cmd) {
        wire.cmd_get_capset_info => wire.resp_ok_capset_info,
        wire.cmd_get_capset => wire.resp_ok_capset,
        else => wire.resp_ok_nodata,
    };
    const u: u32 = @intCast(used);
    if (u >= wire.hdr_len and u <= resp.len) {
        std.mem.writeInt(u32, resp[0..4], want_type, .little);
        std.mem.writeInt(u32, resp[4..8], 0, .little);
        std.mem.writeInt(u64, resp[8..16], fake_fence(), .little);
        std.mem.writeInt(u32, resp[16..20], fake_ctx(), .little);
        std.mem.writeInt(u32, resp[20..24], 0, .little);
        if (want_type == wire.resp_ok_capset_info and resp.len >= 36) {
            std.mem.writeInt(u32, resp[24..28], wire.capset_vir1, .little);
            std.mem.writeInt(u32, resp[28..32], wire.vir1_version, .little);
            std.mem.writeInt(u32, resp[32..36], wire.vir1_payload_len, .little);
        } else if (want_type == wire.resp_ok_capset and resp.len >= 24 + wire.vir1_payload_len) {
            wire.encode_vir1_caps(resp[24..], fake_dev.caps_ready);
        }
    }
    return u;
}

fn fake_release(handle: u32, completed: bool) void {
    _ = handle;
    _ = completed;
}

fn fake_transport() device.Transport {
    return .{ .submit = fake_submit, .wait = fake_wait, .release = fake_release };
}

const seat_pid: usize = 77;
const owner_pid: usize = 55;

/// Full test environment: fresh device + submit + broker + window registry
/// + a registered seat. Returns the opened window id.
fn env_up(w: u32, h: u32) !u8 {
    device.reset_state();
    submit.reset_state();
    reset_state();
    fake_dev = .{};
    device.transport = fake_transport();
    device.g3_ready = true;
    wm_server.init();
    _ = wm_server.register(seat_pid);
    driving_award.arm();
    const r = driving_award.user_open(64, 64, w, h, owner_pid);
    return switch (r) {
        .opened => |id| id,
        else => error.BadWindow,
    };
}

fn desc(op: u32) Desc {
    return .{ .op = op };
}

fn expect_err(want: Error, got: Error!u64) !void {
    if (got) |_| return error.UnexpectedOk else |e| try testing.expectEqual(want, e);
}

test "gpu3d_broker: descriptor is exactly the frozen 64-byte layout and round-trips the pinned table" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(Desc));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Vert));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Desc, "op"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Desc, "flags"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Desc, "handle"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Desc, "window_id"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(Desc, "width"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Desc, "height"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(Desc, "rgb"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(Desc, "verts"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(Desc, "reserved"));

    // Pinned byte table — a TRIANGLE descriptor encoded by hand; the
    // struct must serialize byte-identically and read the same fields.
    const pinned: [64]u8 = blk: {
        var b: [64]u8 = @splat(0);
        std.mem.writeInt(u32, b[0..4], op_triangle, .little);
        std.mem.writeInt(u64, b[8..16], 0x1122_3344_5566_0002, .little);
        std.mem.writeInt(u32, b[16..20], 4, .little);
        // v0: x=-0x4000, y=-0x2d00, z=0x7fff, rgb565=0xf800
        std.mem.writeInt(i16, b[32..34], -0x4000, .little);
        std.mem.writeInt(i16, b[34..36], -0x2d00, .little);
        std.mem.writeInt(u16, b[36..38], 0x7fff, .little);
        std.mem.writeInt(u16, b[38..40], 0xf800, .little);
        // v1
        std.mem.writeInt(i16, b[40..42], 0x4000, .little);
        std.mem.writeInt(i16, b[42..44], -0x2d00, .little);
        std.mem.writeInt(u16, b[44..46], 0x1000, .little);
        std.mem.writeInt(u16, b[46..48], 0x07e0, .little);
        // v2
        std.mem.writeInt(i16, b[48..50], 0, .little);
        std.mem.writeInt(i16, b[50..52], 0x5200, .little);
        std.mem.writeInt(u16, b[52..54], 0xffff, .little);
        std.mem.writeInt(u16, b[54..56], 0x001f, .little);
        break :blk b;
    };
    var d: Desc = undefined;
    @memcpy(std.mem.asBytes(&d), &pinned);
    try testing.expectEqual(@as(u32, op_triangle), d.op);
    try testing.expectEqual(@as(u64, 0x1122_3344_5566_0002), d.handle);
    try testing.expectEqual(@as(u32, 4), d.window_id);
    try testing.expectEqual(@as(i16, -0x4000), d.verts[0].x);
    try testing.expectEqual(@as(i16, -0x2d00), d.verts[0].y);
    try testing.expectEqual(@as(u16, 0x7fff), d.verts[0].z);
    try testing.expectEqual(@as(u16, 0xf800), d.verts[0].rgb565);
    try testing.expectEqual(@as(u16, 0xffff), d.verts[2].z);
    // Serialize back — byte-identical round-trip.
    try testing.expectEqualSlices(u8, &pinned, std.mem.asBytes(&d));
    // No physical-address field exists anywhere in the ABI.
    try testing.expect(!@hasField(Desc, "pa") and !@hasField(Desc, "phys") and !@hasField(Desc, "addr"));
}

test "gpu3d_broker: seat gating precedes everything — no seat, foreign seat" {
    const wid = try env_up(64, 48);
    var d = desc(op_create);
    d.window_id = wid;
    d.width = 64;
    d.height = 48;

    // Foreign seat: registered pid is seat_pid, a different caller is refused.
    try expect_err(error.ForeignSeat, dispatch(&d, owner_pid));
    // No seat at all: unregister, then even the real seat pid is refused.
    _ = wm_server.unregister(seat_pid);
    try expect_err(error.NoSeat, dispatch(&d, seat_pid));
    // Neither attempt touched the device.
    try testing.expectEqual(@as(usize, 0), fake_dev.req_count);
    try testing.expectEqual(@as(usize, 0), live_count());
}

test "gpu3d_broker: malformed descriptors refuse before device submission (the revert-fails bound test)" {
    const wid = try env_up(64, 48);
    const reqs0 = fake_dev.req_count;

    // Unknown ops fail closed.
    var d = desc(0);
    d.window_id = wid;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));
    d = desc(9);
    d.window_id = wid;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));

    // Reserved bytes must be zero.
    d = desc(op_create);
    d.window_id = wid;
    d.width = 64;
    d.height = 48;
    d.flags = 1;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));
    d.flags = 0;
    d.reserved = 0x100;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));
    d.reserved = 0;

    // Op-foreign fields must be zero.
    d.rgb = 0x112233;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));
    d.rgb = 0;
    d.handle = 0x1_0001;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));
    d.handle = 0;
    d.verts[1].x = 5;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));
    d.verts[1].x = 0;

    // Over-cap geometry refuses at the descriptor, before the device.
    d.width = wire.vir1_max_width + 1;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));
    d.width = 0;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));
    d.width = 64;
    d.height = wire.vir1_max_height + 1;
    try expect_err(error.Invalid, dispatch(&d, seat_pid));

    // CLEAR's rgb carries no alpha byte.
    d.height = 48;
    var c = desc(op_clear);
    c.window_id = wid;
    c.rgb = 0x01_00_00_00;
    try expect_err(error.Invalid, dispatch(&c, seat_pid));

    try testing.expectEqual(reqs0, fake_dev.req_count);
    try testing.expectEqual(@as(usize, 0), live_count());
}

test "gpu3d_broker: create/clear/triangle/present/poll/publish/close lifecycle paints the window" {
    const wid = try env_up(64, 48);

    // CREATE — probes caps (2 requests) then runs the 6-step session
    // bring-up + ctx create against the fake device.
    var d = desc(op_create);
    d.window_id = wid;
    d.width = 32;
    d.height = 24;
    const h = try dispatch(&d, seat_pid);
    try testing.expect(h != 0);
    try testing.expectEqual(@as(usize, 1), live_count());
    try testing.expect(fake_dev.req_count >= 8);

    // Idempotent same-extent CREATE returns the same handle.
    try testing.expectEqual(h, try dispatch(&d, seat_pid));
    try testing.expectEqual(@as(usize, 1), live_count());

    // CLEAR + TRIANGLE stage the frame, PRESENT submits it.
    var c = desc(op_clear);
    c.window_id = wid;
    c.handle = h;
    c.rgb = 0x204060;
    try testing.expectEqual(@as(u64, 0), try dispatch(&c, seat_pid));
    var t = desc(op_triangle);
    t.window_id = wid;
    t.handle = h;
    t.verts[0] = .{ .x = -0x4000, .y = -0x2d00, .z = 0, .rgb565 = 0xf800 };
    t.verts[1] = .{ .x = 0x4000, .y = -0x2d00, .z = 0, .rgb565 = 0x07e0 };
    t.verts[2] = .{ .x = 0, .y = 0x5200, .z = 0, .rgb565 = 0x001f };
    try testing.expectEqual(@as(u64, 0), try dispatch(&t, seat_pid));
    var p = desc(op_present);
    p.window_id = wid;
    p.handle = h;
    try testing.expectEqual(@as(u64, 0), try dispatch(&p, seat_pid));

    // PUBLISH before POLL is pending — the pixels are not staged.
    var pubd = desc(op_publish);
    pubd.window_id = wid;
    pubd.handle = h;
    pubd.width = 64;
    pubd.height = 48;
    try expect_err(error.Pending, dispatch(&pubd, seat_pid));

    // POLL stages the bounce readback (returns 1 = publishable).
    var q = desc(op_poll);
    q.window_id = wid;
    q.handle = h;
    try testing.expectEqual(@as(u64, 1), try dispatch(&q, seat_pid));
    try testing.expectEqual(@as(u64, 1), try dispatch(&q, seat_pid)); // idempotent

    // PUBLISH writes the staged frame into the window's back-buffer at the
    // client origin — render extent 32x24 inside the 64x48 client, rest
    // cleared to the frame's clear color, damage recorded.
    try testing.expectEqual(@as(u64, 0), try dispatch(&pubd, seat_pid));
    const win = driving_award.find_user_window(wid).?;
    const kb = driving_award.kbuf_ptr(win);
    const marker_row0 = kb[0..4];
    try testing.expectEqual(@as(u8, 0x5a), marker_row0[0]); // fake DMA marker pattern
    // Right of the extent: the clear-rest band (rgb 0x204060 → BGRA8).
    try testing.expectEqual(@as(u8, 0x60), kb[32 * 4 + 0]);
    try testing.expectEqual(@as(u8, 0x40), kb[32 * 4 + 1]);
    try testing.expectEqual(@as(u8, 0x20), kb[32 * 4 + 2]);
    // Below the extent: same clear fill.
    const below = kb[24 * 64 * 4 + 0 ..][0..4];
    try testing.expectEqual(@as(u8, 0x60), below[0]);
    try testing.expect(win.damaged);

    // CLOSE drains the session; the handle dies with it.
    var z = desc(op_close);
    z.window_id = wid;
    z.handle = h;
    try testing.expectEqual(@as(u64, 0), try dispatch(&z, seat_pid));
    try testing.expectEqual(@as(usize, 0), live_count());
    try expect_err(error.BadHandle, dispatch(&p, seat_pid));
}

test "gpu3d_broker: stale handles and foreign bindings refuse (the revert-fails generation test)" {
    const wid = try env_up(64, 48);
    var d = desc(op_create);
    d.window_id = wid;
    d.width = 32;
    d.height = 24;
    const h1 = try dispatch(&d, seat_pid);
    const reqs_after_first_open = fake_dev.req_count;

    // A fabricated handle — right slot, wrong generation → EBADF.
    var p = desc(op_present);
    p.window_id = wid;
    p.handle = h1 + (1 << 16); // generation + 1
    try expect_err(error.BadHandle, dispatch(&p, seat_pid));
    // Out-of-range ctx slot → EBADF.
    p.handle = (h1 & ~@as(u64, 0xffff)) | 3;
    try expect_err(error.BadHandle, dispatch(&p, seat_pid));
    // Zero handle → EBADF.
    p.handle = 0;
    try expect_err(error.BadHandle, dispatch(&p, seat_pid));
    // Foreign window binding on a valid handle → EBADF (not the bound window).
    p.handle = h1;
    p.window_id = wid + 1;
    try expect_err(error.BadHandle, dispatch(&p, seat_pid));
    p.window_id = wid;

    // Close + reopen: the recycled slot gets a new generation; the OLD
    // handle must never drive the new context (the stale-handle proof).
    var z = desc(op_close);
    z.window_id = wid;
    z.handle = h1;
    try testing.expectEqual(@as(u64, 0), try dispatch(&z, seat_pid));
    const h2 = try dispatch(&d, seat_pid);
    try testing.expect(h2 != h1);
    const reqs_before_stale = fake_dev.req_count;
    var stale = desc(op_present);
    stale.window_id = wid;
    stale.handle = h1;
    try expect_err(error.BadHandle, dispatch(&stale, seat_pid));
    // Under the revert seam this PRESENT would land a SUBMIT_3D on the
    // NEW context — the request counter is the observable proof it did not.
    try testing.expectEqual(reqs_before_stale, fake_dev.req_count);

    // A SECOND stale op (different call path) same proof.
    var stale2 = desc(op_poll);
    stale2.window_id = wid;
    stale2.handle = h1;
    try expect_err(error.BadHandle, dispatch(&stale2, seat_pid));
    try testing.expectEqual(reqs_before_stale, fake_dev.req_count);
    _ = reqs_after_first_open;
}

test "gpu3d_broker: window close, owner exit and WM death revoke contexts immediately" {
    const wid = try env_up(64, 48);
    var d = desc(op_create);
    d.window_id = wid;
    d.width = 32;
    d.height = 24;
    const h = try dispatch(&d, seat_pid);

    // Window close (remove_user_at's funnel) revokes immediately.
    _ = driving_award.user_close(wid);
    try testing.expectEqual(@as(usize, 0), live_count());
    var p = desc(op_present);
    p.window_id = wid;
    p.handle = h;
    try expect_err(error.BadHandle, dispatch(&p, seat_pid));

    // A recycled window id cannot be driven by the dead handle.
    const wid2 = (driving_award.user_open(64, 64, 64, 48, owner_pid + 1)).opened;
    p.window_id = wid2;
    try expect_err(error.BadHandle, dispatch(&p, seat_pid));

    // Owner exit revokes: new window + context, then close_owner.
    const h2 = blk: {
        var d2 = desc(op_create);
        d2.window_id = wid2;
        d2.width = 16;
        d2.height = 16;
        break :blk try dispatch(&d2, seat_pid);
    };
    try testing.expectEqual(@as(usize, 1), live_count());
    _ = driving_award.close_owner(owner_pid + 1);
    try testing.expectEqual(@as(usize, 0), live_count());
    var c = desc(op_clear);
    c.window_id = wid2;
    c.handle = h2;
    c.rgb = 0x101010;
    try expect_err(error.BadHandle, dispatch(&c, seat_pid));

    // WM unregister revokes every live context.
    const wid3 = (driving_award.user_open(64, 64, 64, 48, owner_pid)).opened;
    var d3 = desc(op_create);
    d3.window_id = wid3;
    d3.width = 16;
    d3.height = 16;
    const h3 = try dispatch(&d3, seat_pid);
    _ = wm_server.unregister(seat_pid);
    try testing.expectEqual(@as(usize, 0), live_count());
    try expect_err(error.NoSeat, dispatch(&c, seat_pid));
    _ = h3;
}

test "gpu3d_broker: publish refuses stale geometry and revoked backing — the last lifetime check" {
    const wid = try env_up(64, 48);
    var d = desc(op_create);
    d.window_id = wid;
    d.width = 32;
    d.height = 24;
    const h = try dispatch(&d, seat_pid);
    var p = desc(op_present);
    p.window_id = wid;
    p.handle = h;
    try testing.expectEqual(@as(u64, 0), try dispatch(&p, seat_pid));
    var q = desc(op_poll);
    q.window_id = wid;
    q.handle = h;
    try testing.expectEqual(@as(u64, 1), try dispatch(&q, seat_pid));

    var pubd = desc(op_publish);
    pubd.window_id = wid;
    pubd.handle = h;
    pubd.width = 64;
    pubd.height = 48;

    // Captured geometry no longer matches the live client rect.
    pubd.width = 63;
    try expect_err(error.Invalid, dispatch(&pubd, seat_pid));
    pubd.width = 64;
    pubd.height = 47;
    try expect_err(error.Invalid, dispatch(&pubd, seat_pid));
    pubd.height = 48;

    // Resize the window between POLL and PUBLISH: the captured extent
    // disagrees with the live rect → refused (no paint, no new draw).
    const win = driving_award.find_user_window(wid).?;
    try testing.expect(driving_award.reflow(win, 64, 64, 80, 48));
    try expect_err(error.Invalid, dispatch(&pubd, seat_pid));
    // The window kept its old pixels (reflow preserved rows; nothing was
    // painted by the refused publish).
    pubd.width = 80;
    try testing.expectEqual(@as(u64, 0), try dispatch(&pubd, seat_pid));

    // Close the window mid-flight: a second publish names dead context.
    _ = driving_award.user_close(wid);
    try expect_err(error.BadHandle, dispatch(&pubd, seat_pid));

    // Poison the session: a device timeout revokes backing access — the
    // same handle now reports lost context, never pending.
    const wid2 = (driving_award.user_open(64, 64, 64, 48, owner_pid)).opened;
    var d2 = desc(op_create);
    d2.window_id = wid2;
    d2.width = 16;
    d2.height = 16;
    const h2 = try dispatch(&d2, seat_pid);
    fake_dev.never_complete = true;
    var p2 = desc(op_present);
    p2.window_id = wid2;
    p2.handle = h2;
    try expect_err(error.TimedOut, dispatch(&p2, seat_pid));
    fake_dev.never_complete = false;
    var q2 = desc(op_poll);
    q2.window_id = wid2;
    q2.handle = h2;
    try expect_err(error.LostContext, dispatch(&q2, seat_pid));
}

test "gpu3d_broker: pool exhaustion is a named refusal and counters stay put on rejection" {
    const wid = try env_up(64, 48);
    var d = desc(op_create);
    d.window_id = wid;
    d.width = 16;
    d.height = 16;
    const h1 = try dispatch(&d, seat_pid);
    const wid2 = (driving_award.user_open(300, 64, 64, 48, owner_pid)).opened;
    d.window_id = wid2;
    const h2 = try dispatch(&d, seat_pid);
    try testing.expectEqual(@as(usize, 2), live_count());

    // Third window, no slots left → the named exhaustion, no device churn.
    const wid3 = (driving_award.user_open(64, 200, 64, 48, owner_pid)).opened;
    d.window_id = wid3;
    const reqs0 = fake_dev.req_count;
    try expect_err(error.Exhausted, dispatch(&d, seat_pid));
    try testing.expectEqual(reqs0, fake_dev.req_count);
    try testing.expectEqual(@as(usize, 2), live_count());

    // Extent change re-opens the same window's context — the old
    // generation dies with the re-open (new handle, same live count).
    var g = desc(op_create);
    g.window_id = wid;
    g.width = 32;
    g.height = 24;
    const h1b = try dispatch(&g, seat_pid);
    try testing.expect(h1b != h1);
    try testing.expectEqual(@as(usize, 2), live_count());
    var p = desc(op_present);
    p.window_id = wid;
    p.handle = h1;
    try expect_err(error.BadHandle, dispatch(&p, seat_pid));

    // CLOSE frees a slot for the refused window.
    var z = desc(op_close);
    z.window_id = wid2;
    z.handle = h2;
    try testing.expectEqual(@as(u64, 0), try dispatch(&z, seat_pid));
    d.window_id = wid3;
    _ = try dispatch(&d, seat_pid);
    try testing.expectEqual(@as(usize, 2), live_count());
}

test "gpu3d_broker: unsupported device and unarmed renderer stay distinct" {
    const wid = try env_up(64, 48);
    var d = desc(op_create);
    d.window_id = wid;
    d.width = 16;
    d.height = 16;

    // Device absent entirely → Unsupported (never a probe attempt).
    device.g3_ready = false;
    try expect_err(error.Unsupported, dispatch(&d, seat_pid));
    device.g3_ready = true;

    // Renderer not ready (VIR1 profile present, ready=0) → still
    // Unsupported, distinctly NOT exhausted or pending.
    fake_dev.caps_ready = 0;
    try expect_err(error.Unsupported, dispatch(&d, seat_pid));
    try testing.expectEqual(@as(usize, 0), live_count());
}

test "gpu3d_broker: publish writes into a bound surface with its real stride" {
    const wid = try env_up(64, 48);
    // Migrate the window to a surface whose "pa" is a real host buffer.
    var surf: [64 * 48 * 4]u8 = @splat(0xcc);
    const pa = @intFromPtr(&surf);
    const pages: u32 = @intCast((surf.len + 4095) / 4096);
    try testing.expect(driving_award.user_bind_surface(wid, .{ .handle = 9, .pa_base = pa, .page_count = pages }));

    var d = desc(op_create);
    d.window_id = wid;
    d.width = 16;
    d.height = 16;
    const h = try dispatch(&d, seat_pid);
    var p = desc(op_present);
    p.window_id = wid;
    p.handle = h;
    try testing.expectEqual(@as(u64, 0), try dispatch(&p, seat_pid));
    var q = desc(op_poll);
    q.window_id = wid;
    q.handle = h;
    try testing.expectEqual(@as(u64, 1), try dispatch(&q, seat_pid));
    var pubd = desc(op_publish);
    pubd.window_id = wid;
    pubd.handle = h;
    pubd.width = 64;
    pubd.height = 48;
    try testing.expectEqual(@as(u64, 0), try dispatch(&pubd, seat_pid));
    // The SURFACE pages received the frame (marker at origin), not the kbuf.
    try testing.expectEqual(@as(u8, 0x5a), surf[0]);
    const win = driving_award.find_user_window(wid).?;
    const kb = driving_award.kbuf_ptr(win);
    try testing.expectEqual(@as(u8, 0), kb[0]); // unmigrated buffer untouched

    // An undersized surface refuses the copy — never a partial paint.
    const win2 = driving_award.find_user_window(wid).?;
    win2.surface_pages = 1; // cannot cover 64x48x4
    try expect_err(error.Invalid, dispatch(&pubd, seat_pid));
}
