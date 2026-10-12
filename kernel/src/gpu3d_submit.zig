//! VirelaiOS experimental GPU3D — bounded resources, submission, fenced
//! completion, readback and safe retirement (M102c1, issue #2164 — card
//! of the M102 index, issue #2160).
//!
//! This module sits ON TOP of b1's injectable exchange (gpu3d_device.zig)
//! and the pinned stream encoder (gpu3d_stream.zig). It encodes the
//! virtio-gpu 3D envelopes b1 did not carry (RESOURCE_CREATE_3D,
//! ATTACH/DETACH_BACKING, CTX_ATTACH/DETACH_RESOURCE, TRANSFER_TO/FROM_
//! HOST_3D, SUBMIT_3D, RESOURCE_UNREF), drives them as ordinary fenced
//! control exchanges, and owns the guest-side lifetime rules:
//!
//!   * Two sessions max (the VIR1 `contexts` bound), each owning one
//!     color target (<= 256x192 BGRA8, opaque, single sample) and one
//!     96-byte vertex buffer (three float4+float4 vertices).
//!   * Backing is kernel-owned BSS, pinned for the life of the device
//!     reference — it is never freed, so a timeout can never become a
//!     freed-memory access. Readback pixels land in the session's own
//!     pinned backing; it is not the scanout.
//!   * Completion is the fence-matched SUBMIT_3D response (used id +
//!     length + response type + ctx echo + full u64 fence — b1's
//!     exchange). Queue consumption alone NEVER completes a frame.
//!   * A timed-out exchange POISONS its session: render/readback ops
//!     refuse, the backing stays quarantined, and `close`/`retire`
//!     drains the owed teardown steps until a responsive device
//!     (confirmed reset) returns the pools to baseline.
//!   * One logical deadline per exchange (b1's bounded poll), never a
//!     syscall wait — polling here leaves 2D presents and other windows
//!     free to run.
//!
//! Wire reference: Virtio 1.3 §5.7.6.10+ (the 3D request shapes inside
//! the same virtio_gpu_ctrl_hdr envelope b1's gpu3d_wire.zig pins).
//! No libc, no POSIX, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const mmu = @import("mmu.zig");
const wire = @import("gpu3d_wire.zig");
const device = @import("gpu3d_device.zig");
const stream = @import("gpu3d_stream.zig");

// ---------------------------------------------------------------------------
// Envelope command ids + request sizes (Virtio 1.3 §5.7.6.10/§5.7.6.11)
// ---------------------------------------------------------------------------

pub const cmd_resource_unref: u32 = 0x0102;
pub const cmd_resource_attach_backing: u32 = 0x0106;
pub const cmd_resource_detach_backing: u32 = 0x0107;
pub const cmd_ctx_attach_resource: u32 = 0x0202;
pub const cmd_ctx_detach_resource: u32 = 0x0203;
pub const cmd_resource_create_3d: u32 = 0x0204;
pub const cmd_transfer_to_host_3d: u32 = 0x0205;
pub const cmd_transfer_from_host_3d: u32 = 0x0206;
pub const cmd_submit_3d: u32 = 0x0207;

/// virtio_gpu_resource_create_3d: hdr + 12 payload words = 72 bytes.
pub const create3d_req_len: usize = 72;
/// virtio_gpu_resource_attach_backing with ONE virtio_gpu_mem_entry:
/// hdr + resource_id + nr_entries + (addr + length + padding) = 48 bytes.
pub const attach_backing_req_len: usize = 48;
/// hdr + resource_id = 28 bytes (the VIR1 res-op shape the device decodes).
pub const detach_backing_req_len: usize = 28;
/// hdr + resource_id = 28 bytes (attach and detach share it).
pub const ctx_res_req_len: usize = 28;
/// virtio_gpu_transfer_host_3d: hdr + box(24) + offset(8) + four words.
pub const transfer_req_len: usize = 72;
/// virtio_gpu_cmd_submit header (hdr + size + padding); data follows.
pub const submit_env_len: usize = 32;
/// hdr + resource_id = 28 bytes.
pub const unref_req_len: usize = 28;

/// The largest color backing the profile allows (256x192 x BGRA8).
pub const max_color_bytes: usize = 256 * 192 * 4;
/// The only vertex-buffer payload (three 32-byte vertices).
pub const vbo_bytes: usize = stream.vbuf_len;

// ---------------------------------------------------------------------------
// Named refusals — busy, incomplete, timed-out, reset and failed are
// distinct outcomes (the transport names come from device.Error).
// ---------------------------------------------------------------------------

/// Every refusal the device layer can name (Unsupported, CapsNotReady,
/// Busy, Timeout, BadResponse, the capset and handle refusals) plus the
/// session-level names below — busy, incomplete/timeout, reset and
/// failed stay distinct all the way up.
pub const Error = device.Error || error{
    /// The device reported a renderer that is not armed (ready == 0).
    NotReady,
    /// Render extent outside the VIR1 profile bounds.
    BadGeometry,
    /// A session handle naming a dead or out-of-range slot.
    BadSession,
    /// A session handle whose generation no longer matches.
    StaleSession,
    /// The session is quarantined after a timed-out exchange.
    Poisoned,
    /// Readback/publish requested with no completed frame.
    NoFrame,
    /// No matching readback has landed yet for the current frame.
    NoPixels,
    /// The caller's destination is smaller than the frame bytes.
    OutTooSmall,
    /// The stream cannot fit the SUBMIT_3D envelope bound.
    StreamTooBig,
    /// The stream's own counts/alignment fail validation.
    BadStream,
    /// The u64 fence space would wrap into reuse.
    FenceExhausted,
};

/// Completion authority (the revert-fails seam): a frame becomes
/// publishable ONLY through the fence-matched SUBMIT_3D response — the
/// reply IS the device's backend-completion signal (#2160 §4). Queue
/// consumption alone is never rendering completion. Flipping this to
/// false posts the same bytes and marks the frame ready at post time;
/// the delayed-backend ordering test goes red while the rest stays green.
pub const completion_is_fenced_response: bool = true;

// ---------------------------------------------------------------------------
// Envelope encoders — explicit LE writes, every byte initialized
// ---------------------------------------------------------------------------

fn put32(out: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, out[off..][0..4], v, .little);
}

fn put64(out: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, out[off..][0..8], v, .little);
}

fn put_hdr(out: []u8, cmd_type: u32, ctx_id: u32, fence_id: u64) void {
    put32(out, 0, cmd_type);
    put32(out, 4, wire.flag_fence);
    put64(out, 8, fence_id);
    put32(out, 16, ctx_id);
    put32(out, 20, 0);
}

/// RESOURCE_CREATE_3D (0x0204): hdr + resource_id + target + format +
/// bind + width + height + depth + array_size + last_level + nr_samples +
/// flags + padding = 72 bytes. The VIR1 device scopes resources to the
/// creating context — every resource command carries its live ctx_id.
pub fn encode_create3d(out: []u8, res_id: u32, target: u32, format: u32, bind: u32, width: u32, height: u32, ctx_id: u32, fence_id: u64) usize {
    std.debug.assert(out.len >= create3d_req_len);
    put_hdr(out, cmd_resource_create_3d, ctx_id, fence_id);
    put32(out, 24, res_id);
    put32(out, 28, target);
    put32(out, 32, format);
    put32(out, 36, bind);
    put32(out, 40, width);
    put32(out, 44, height);
    put32(out, 48, 1); // depth
    put32(out, 52, 1); // array_size
    put32(out, 56, 0); // last_level
    put32(out, 60, 0); // nr_samples — single sample only
    put32(out, 64, 0); // flags
    put32(out, 68, 0); // padding
    return create3d_req_len;
}

/// RESOURCE_ATTACH_BACKING (0x0106) with a single mem entry:
/// hdr + resource_id + nr_entries + {addr, length, padding} = 48 bytes.
pub fn encode_attach_backing(out: []u8, res_id: u32, addr: u64, len: u32, ctx_id: u32, fence_id: u64) usize {
    std.debug.assert(out.len >= attach_backing_req_len);
    put_hdr(out, cmd_resource_attach_backing, ctx_id, fence_id);
    put32(out, 24, res_id);
    put32(out, 28, 1); // nr_entries
    put64(out, 32, addr);
    put32(out, 40, len);
    put32(out, 44, 0);
    return attach_backing_req_len;
}

/// RESOURCE_DETACH_BACKING (0x0107) / CTX_ATTACH_RESOURCE (0x0202) /
/// CTX_DETACH_RESOURCE (0x0203) / RESOURCE_UNREF (0x0102): the same
/// 28-byte shape, ctx_id per the command family. The VIR1 device
/// decodes hdr + resource_id only — a stock padding word would land
/// as trailing bytes.
pub fn encode_res_op(out: []u8, cmd_type: u32, res_id: u32, ctx_id: u32, fence_id: u64) usize {
    std.debug.assert(out.len >= 28);
    put_hdr(out, cmd_type, ctx_id, fence_id);
    put32(out, 24, res_id);
    return 28;
}

/// A 3D transfer box (x, y, z, w, h, d).
pub const Box = struct { x: u32, y: u32, z: u32, w: u32, h: u32, d: u32 };

/// TRANSFER_TO_HOST_3D (0x0205) / TRANSFER_FROM_HOST_3D (0x0206):
/// hdr + box + offset + resource_id + level + stride + layer_stride =
/// 72 bytes. `stride` is the guest backing's row stride in bytes;
/// `offset` is the byte offset into the backing.
pub fn encode_transfer(out: []u8, cmd_type: u32, res_id: u32, box: Box, offset: u64, stride: u32, layer_stride: u32, ctx_id: u32, fence_id: u64) usize {
    std.debug.assert(out.len >= transfer_req_len);
    put_hdr(out, cmd_type, ctx_id, fence_id);
    put32(out, 24, box.x);
    put32(out, 28, box.y);
    put32(out, 32, box.z);
    put32(out, 36, box.w);
    put32(out, 40, box.h);
    put32(out, 44, box.d);
    put64(out, 48, offset);
    put32(out, 56, res_id);
    put32(out, 60, 0); // level
    put32(out, 64, stride);
    put32(out, 68, layer_stride);
    return transfer_req_len;
}

/// SUBMIT_3D (0x0207): hdr + size + padding + stream bytes. The stream
/// must be nonempty, word-aligned, count-consistent and within the
/// 4096-byte profile bound — 32 + 4096 = 4128 = the staging bound.
pub fn encode_submit3d(out: []u8, stream_bytes: []const u8, ctx_id: u32, fence_id: u64) Error!usize {
    _ = try stream.validate_stream(stream_bytes);
    const total = submit_env_len + stream_bytes.len;
    if (out.len < total) return error.StreamTooBig;
    put_hdr(out, cmd_submit_3d, ctx_id, fence_id);
    put32(out, 24, @intCast(stream_bytes.len));
    put32(out, 28, 0);
    @memcpy(out[submit_env_len..total], stream_bytes);
    return total;
}

// ---------------------------------------------------------------------------
// The session pool — one render context per slot, pinned BSS backing
// ---------------------------------------------------------------------------

pub const max_sessions: usize = device.max_contexts;

/// A generation-bearing session handle (mirrors b1's Handle: the slot
/// generation proves a recycled slot can't be driven by a stale caller,
/// and the ctx generation guards the device-side context the same way).
pub const Session = struct {
    ctx_id: u32,
    generation: u32,
    ctx_generation: u32,
};

/// Which device-side objects a slot owes teardown for — the drain mask.
const res_color_created: u6 = 1 << 0;
const res_color_backed: u6 = 1 << 1;
const res_color_attached: u6 = 1 << 2;
const res_vbo_created: u6 = 1 << 3;
const res_vbo_backed: u6 = 1 << 4;
const res_vbo_attached: u6 = 1 << 5;
const res_all: u6 = 0x3f;

const Sess = struct {
    live: bool = false,
    poisoned: bool = false,
    generation: u32 = 0,
    ctx: device.Handle = .{ .ctx_id = 0, .generation = 0 },
    width: u32 = 0,
    height: u32 = 0,
    res_color: u32 = 0,
    res_vbo: u32 = 0,
    res_state: u6 = 0,
    frame_ready: bool = false,
    frame_fence: u64 = 0,
    frame_seq: u64 = 0,
    pixels_ready: bool = false,
    vbo: [vbo_bytes]u8 align(16) = undefined,
    color: [max_color_bytes]u8 align(16) = undefined,
};

var sessions: [max_sessions]Sess = .{ .{}, .{} };

/// Shared staging for envelope encode + the stream build. Serialized by
/// the one-outstanding-request rule (callers enter under the same
/// discipline as the control exchange — a contested exchange names Busy).
var env: [device.req_staging_len]u8 align(16) = undefined;
var stream_scratch: [stream.max_stream_bytes]u8 align(4) = undefined;
var seam_resp: [wire.nodata_resp_len]u8 align(16) = undefined;

fn take_fence() Error!u64 {
    if (device.fence_counter == std.math.maxInt(u64)) return error.FenceExhausted;
    device.fence_counter += 1;
    return device.fence_counter;
}

/// One fenced control exchange, honoring the session's poison rule: a
/// Timeout quarantines the session's backing until the teardown drain
/// completes against a responsive device.
fn guarded(s: *Sess, req: []const u8, want_type: u32, resp_cap: usize) Error!device.Completion {
    return device.exchange(req, want_type, resp_cap) catch |e| {
        if (e == error.Timeout) s.poisoned = true;
        return e;
    };
}

fn sess_of(h: Session, allow_poisoned: bool) Error!*Sess {
    if (h.ctx_id == 0 or h.ctx_id > max_sessions) return error.BadSession;
    const s = &sessions[h.ctx_id - 1];
    if (s.generation != h.generation) return error.StaleSession;
    if (!s.live) return error.BadSession;
    if (s.ctx.generation != h.ctx_generation) return error.StaleSession;
    if (s.poisoned and !allow_poisoned) return error.Poisoned;
    return s;
}

// ---------------------------------------------------------------------------
// Open — create the context, the two bounded resources, their pinned
// backing and the context attach order. A mid-sequence failure drains
/// what was created best-effort; a slot that cannot drain is quarantined
/// (poisoned, never live) until `retire` completes against a reset device.
// ---------------------------------------------------------------------------

pub fn open(ctx_id: u32, width: u32, height: u32) Error!Session {
    if (!device.g3_ready) return error.Unsupported;
    if (!device.caps_valid) return error.CapsNotReady;
    if (device.caps.ready == 0) return error.NotReady;
    if (ctx_id == 0) return error.ZeroContext;
    if (ctx_id > max_sessions) return error.ContextExhausted;
    if (width == 0 or width > device.caps.max_width or
        height == 0 or height > device.caps.max_height) return error.BadGeometry;
    const s = &sessions[ctx_id - 1];
    if (s.live) return error.DuplicateHandle;
    if (s.poisoned or s.res_state != 0) return error.Poisoned; // quarantined — retire it first

    const ctx = try device.ctx_create(ctx_id);
    s.res_color = stream.res_color_id(ctx_id);
    s.res_vbo = stream.res_vbo_id(ctx_id);
    s.res_state = 0;
    s.width = width;
    s.height = height;
    s.frame_ready = false;
    s.frame_fence = 0;
    s.frame_seq = 0;
    s.pixels_ready = false;
    s.poisoned = false;
    s.ctx = ctx;

    const color_len: u32 = width * height * 4;
    // The sequence: create color -> attach backing -> ctx-attach ->
    // create vbo -> attach backing -> ctx-attach. Each step's refusal
    // leaves `res_state` naming what the device still owes.
    const steps = struct {
        fn run(ss: *Sess, clen: u32) Error!void {
            // color target: 2D, BGRA8, RENDER_TARGET
            var n = encode_create3d(env[0..], ss.res_color, stream.target_2d, stream.fmt_bgra8_unorm, stream.bind_render_target, ss.width, ss.height, ss.ctx.ctx_id, try take_fence());
            _ = try guarded(ss, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
            ss.res_state |= res_color_created;
            n = encode_attach_backing(env[0..], ss.res_color, mmu.to_phys(@intFromPtr(&ss.color)), clen, ss.ctx.ctx_id, try take_fence());
            _ = try guarded(ss, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
            ss.res_state |= res_color_backed;
            n = encode_res_op(env[0..], cmd_ctx_attach_resource, ss.res_color, ss.ctx.ctx_id, try take_fence());
            _ = try guarded(ss, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
            ss.res_state |= res_color_attached;
            // vertex buffer: PIPE_BUFFER, VERTEX_BUFFER, 96 bytes wide
            n = encode_create3d(env[0..], ss.res_vbo, stream.target_buffer, 0, stream.bind_vertex_buffer, vbo_bytes, 1, ss.ctx.ctx_id, try take_fence());
            _ = try guarded(ss, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
            ss.res_state |= res_vbo_created;
            n = encode_attach_backing(env[0..], ss.res_vbo, mmu.to_phys(@intFromPtr(&ss.vbo)), vbo_bytes, ss.ctx.ctx_id, try take_fence());
            _ = try guarded(ss, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
            ss.res_state |= res_vbo_backed;
            n = encode_res_op(env[0..], cmd_ctx_attach_resource, ss.res_vbo, ss.ctx.ctx_id, try take_fence());
            _ = try guarded(ss, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
            ss.res_state |= res_vbo_attached;
        }
    };
    steps.run(s, color_len) catch |e| {
        // Partial bring-up: drain what was created best-effort. A device
        // that cannot drain leaves the slot quarantined (never live).
        drain(s, true) catch {};
        if (s.res_state != 0 or s.ctx.ctx_id != 0) s.poisoned = true;
        return e;
    };
    s.live = true;
    s.generation += 1;
    return .{ .ctx_id = ctx_id, .generation = s.generation, .ctx_generation = ctx.generation };
}

/// Drain the owed teardown steps in reverse creation order. Each step
/// is skipped when its mask bit is clear, so a resumed drain after a
/// recovered device only re-issues what is still owed. `best_effort`
/// swallows per-step refusals (unwind paths); strict callers see the
/// first named failure and may retry — completed steps stay cleared.
fn drain(s: *Sess, best_effort: bool) Error!void {
    const Step = struct { bit: u6, cmd: u32, res: u32, ctx: u32 };
    const order = [_]Step{
        .{ .bit = res_vbo_attached, .cmd = cmd_ctx_detach_resource, .res = 0, .ctx = 0 },
        .{ .bit = res_color_attached, .cmd = cmd_ctx_detach_resource, .res = 0, .ctx = 0 },
        .{ .bit = res_vbo_backed, .cmd = cmd_resource_detach_backing, .res = 0, .ctx = 0 },
        .{ .bit = res_color_backed, .cmd = cmd_resource_detach_backing, .res = 0, .ctx = 0 },
        .{ .bit = res_vbo_created, .cmd = cmd_resource_unref, .res = 0, .ctx = 0 },
        .{ .bit = res_color_created, .cmd = cmd_resource_unref, .res = 0, .ctx = 0 },
    };
    var first: ?Error = null;
    for (order) |st| {
        if ((s.res_state & st.bit) == 0) continue;
        const res = if (st.bit == res_vbo_attached or st.bit == res_vbo_backed or st.bit == res_vbo_created) s.res_vbo else s.res_color;
        // The device scopes resources per context — every owed op
        // carries the session's live ctx_id (ctx 0 is refused).
        const ctx: u32 = s.ctx.ctx_id;
        const f = take_fence() catch |e| {
            if (first == null) first = e;
            if (best_effort) continue else return e;
        };
        const n = encode_res_op(env[0..], st.cmd, res, ctx, f);
        _ = device.exchange(env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len) catch |e| {
            if (first == null) first = e;
            if (best_effort) continue else return e;
        };
        s.res_state &= ~st.bit;
    }
    if (s.ctx.ctx_id != 0) {
        if (device.ctx_destroy(s.ctx)) |_| {
            s.ctx = .{ .ctx_id = 0, .generation = 0 };
        } else |e| {
            if (first == null) first = e;
            if (!best_effort) return e;
        }
    }
    if (first) |e| return e;
}

// ---------------------------------------------------------------------------
// Frame submission — upload + SUBMIT_3D, completion by fenced response
// ---------------------------------------------------------------------------

/// Upload the three wire vertices into the pinned vbo backing and submit
/// the pinned frame stream. Returns only after the SUBMIT_3D exchange
/// produced its fence-matched response — the frame is then publishable.
/// A new frame replaces the pending one; a timed-out exchange poisons
/// the session instead of pretending pixels exist.
pub fn submit_frame(h: Session, clear: [4]f32, verts: *const [3]stream.WireVertex) Error!void {
    const s = try sess_of(h, false);
    if (!device.g3_ready) return error.Unsupported;

    // Stage the upload payload BEFORE posting anything.
    stream.encode_vertices(verts, &s.vbo);
    if (comptime !builtin.is_test) {
        mmu.clean_dcache_range(@intFromPtr(&s.vbo), vbo_bytes);
    }
    s.pixels_ready = false; // a new frame replaces any staged readback

    // 1. TRANSFER_TO_HOST_3D: the 96-byte vbo backing into the resource.
    var n = encode_transfer(env[0..], cmd_transfer_to_host_3d, s.res_vbo, .{ .x = 0, .y = 0, .z = 0, .w = vbo_bytes, .h = 1, .d = 1 }, 0, 0, 0, s.ctx.ctx_id, try take_fence());
    _ = try guarded(s, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);

    // 2. SUBMIT_3D: the pinned stream for this extent/clear/resources.
    const sn = try stream.encode_frame(&stream_scratch, .{
        .width = s.width,
        .height = s.height,
        .clear = clear,
        .res_color = s.res_color,
        .res_vbo = s.res_vbo,
    });
    const fence = try take_fence();
    n = try encode_submit3d(env[0..], stream_scratch[0..sn], s.ctx.ctx_id, fence);
    if (completion_is_fenced_response) {
        const comp = try guarded(s, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
        s.frame_fence = comp.fence_id;
        s.frame_ready = true;
        s.frame_seq += 1;
    } else {
        // REVERT SEAM — consumption-as-completion (must never ship): the
        // same bytes posted, the fenced wait dropped. The delayed-backend
        // ordering test proves this publishes unrendered frames.
        const post = device.transport.submit(env[0..n], seam_resp[0..]) orelse return error.SubmitFailed;
        device.transport.release(post, true);
        s.frame_fence = fence;
        s.frame_ready = true;
        s.frame_seq += 1;
    }
}

// ---------------------------------------------------------------------------
// Readback — TRANSFER_FROM_HOST_3D into the pinned color backing,
// ordered after the matching completed fence
// ---------------------------------------------------------------------------

/// DMA the rendered color target into the session's pinned backing.
/// Only valid after a completed frame; the fenced response (not queue
/// consumption) is what makes the bytes meaningful. On success the
/// backing is invalidated for reading and `pixels` exposes it:
/// BGRA8, row stride width*4, row 0 = the frame's first/top row,
/// opaque alpha by contract. The buffer is not the scanout.
pub fn readback(h: Session) Error![]const u8 {
    const s = try sess_of(h, false);
    if (!device.g3_ready) return error.Unsupported;
    if (!s.frame_ready) return error.NoFrame;
    const stride: u32 = s.width * 4;
    const n = encode_transfer(env[0..], cmd_transfer_from_host_3d, s.res_color, .{ .x = 0, .y = 0, .z = 0, .w = s.width, .h = s.height, .d = 1 }, 0, stride, 0, s.ctx.ctx_id, try take_fence());
    _ = try guarded(s, env[0..n], wire.resp_ok_nodata, wire.nodata_resp_len);
    const len: usize = s.width * s.height * 4;
    if (comptime !builtin.is_test) {
        mmu.invalidate_dcache_range(@intFromPtr(&s.color), len);
    }
    s.pixels_ready = true;
    return s.color[0..len];
}

/// The staged readback bytes for the LAST completed transfer — what a
/// publisher copies (bounded, clipped, CPU-side). Refuses when no
/// matching readback has landed for the current frame.
pub fn pixels(h: Session) Error![]const u8 {
    const s = try sess_of(h, false);
    if (!s.pixels_ready) return error.NoPixels;
    return s.color[0 .. s.width * s.height * 4];
}

/// Copy the staged readback into a caller buffer — bounded by the
/// pinned extent, refused early when the destination cannot hold it.
pub fn copy_pixels(h: Session, out: []u8) Error!usize {
    const s = try sess_of(h, false);
    if (!s.pixels_ready) return error.NoPixels;
    const len: usize = s.width * s.height * 4;
    if (out.len < len) return error.OutTooSmall;
    @memcpy(out[0..len], s.color[0..len]);
    return len;
}

/// Whether a completed frame's fence matched the device echo — the
/// public record a publisher may check without touching device state.
pub fn frame_pending(h: Session) Error!bool {
    const s = try sess_of(h, false);
    return s.frame_ready;
}

// ---------------------------------------------------------------------------
// Close + retirement — detach/unref/destroy in order, quarantine on
// failure, baseline on a confirmed drain
// ---------------------------------------------------------------------------

/// Detach both resources, detach backing, unref, destroy the context —
/// in that order. The first failure poisons the session and stops
/// (remaining steps stay owed); calling again on a recovered device
/// resumes the drain. A fully-drained session frees its slot and bumps
/// the generation so stale handles can never ride a recycled context.
pub fn close(h: Session) Error!void {
    const s = try sess_of(h, true);
    drain(s, false) catch |e| {
        s.poisoned = true;
        return e;
    };
    s.live = false;
    s.poisoned = false;
    s.frame_ready = false;
    s.pixels_ready = false;
    s.generation += 1;
}

/// Drain a slot that a FAILED open left quarantined (poisoned, never
/// live — no session handle exists for it). This is the confirmed-reset
/// path: when every owed teardown step completes, the pool returns to
/// baseline and `open` may be retried.
pub fn retire(ctx_id: u32) Error!void {
    if (ctx_id == 0 or ctx_id > max_sessions) return error.BadSession;
    const s = &sessions[ctx_id - 1];
    if (s.live) return error.BadSession; // live sessions close by handle
    if (s.res_state == 0 and s.ctx.ctx_id == 0) {
        s.poisoned = false;
        return;
    }
    try drain(s, false);
    s.poisoned = false;
}

/// Session-state snapshot for diagnostics/tests (live, poisoned, owed
/// teardown bits, last completed fence).
pub fn sess_state(h: Session) Error!struct { live: bool, poisoned: bool, res_state: u6, frame_fence: u64, pixels_ready: bool } {
    const s = try sess_of(h, true);
    return .{ .live = s.live, .poisoned = s.poisoned, .res_state = s.res_state, .frame_fence = s.frame_fence, .pixels_ready = s.pixels_ready };
}

/// Quarantined non-live slot count (failed-open residue).
pub fn quarantined_count() usize {
    var n: usize = 0;
    for (sessions) |s| {
        if (!s.live and (s.poisoned or s.res_state != 0)) n += 1;
    }
    return n;
}

/// Reset every piece of module state (host tests; the boot path builds
/// its state once). Does NOT touch device-layer state.
pub fn reset_state() void {
    sessions = .{ .{}, .{} };
}

// ---------------------------------------------------------------------------
// Tests — an in-process fake device over the SAME injectable seam b1's
// gpu3d_device.zig tests exercise (class A: injected transport). The
// fake records the raw transcript, synthesizes the DMA the custom
// renderer contract implies, and models a backend that completes work
// only when its fenced reply is produced. Nothing here proves real
// hardware rendering — that evidence belongs to the c-series live gates.
// ---------------------------------------------------------------------------

const testing = std.testing;

const FakeDev = struct {
    reqs: [48][device.req_staging_len]u8 = undefined,
    req_lens: [48]usize = @splat(0),
    req_count: usize = 0,
    resp_stash: []u8 = &.{},
    wait_calls: usize = 0,
    submit3d_waits: usize = 0,
    never_complete: bool = false,
    /// When set, request handles >= this index never complete (a device
    /// that dies mid-sequence, then recovers when cleared).
    die_at: ?u32 = null,
    backend_pending: bool = false,
    reply_type_override: ?u32 = null,
    reply_ctx_override: ?u32 = null,
    reply_fence_override: ?u64 = null,
    reply_used_override: ?u32 = null,
    caps_ready: u32 = 1,
    release_completed: bool = false,
    /// Attached backing per resource id (addr is the guest VA — mmu is
    /// identity and the test runs on host, so the fake can DMA into it).
    backings: [8]Backing = @splat(.{ .addr = 0, .len = 0, .live = false }),
    last_stream: [stream.max_stream_bytes]u8 = undefined,
    last_stream_len: usize = 0,
    last_upload: [vbo_bytes]u8 = undefined,
    last_upload_len: usize = 0,
    /// Deterministic "rendered" pixel pattern marker.
    dma_marker: u8 = 0x5a,
};

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
fn fake_res() u32 {
    return std.mem.readInt(u32, fake_dev.resp_stash[24..28], .little);
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
    if (fake_type() == cmd_submit_3d) fake_dev.backend_pending = true;
    return @intCast(h);
}

/// The fake backend: a reply is produced when the device completes the
/// command. For SUBMIT_3D that moment IS the backend finishing the
/// frame — `backend_pending` flips at reply time, never at post time.
/// For transfers the fake performs the DMA the contract implies.
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
        cmd_submit_3d => {
            // The stream trails the 32-byte envelope.
            const size = std.mem.readInt(u32, req[24..28], .little);
            fake_dev.last_stream_len = size;
            @memcpy(fake_dev.last_stream[0..size], req[32 .. 32 + size]);
            fake_dev.backend_pending = false;
            fake_dev.submit3d_waits += 1;
        },
        cmd_transfer_to_host_3d => {
            const res = std.mem.readInt(u32, req[56..60], .little);
            const len = std.mem.readInt(u32, req[36..40], .little);
            const slot = backing_slot(res);
            const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(slot.addr)));
            const take = @min(len, vbo_bytes);
            @memcpy(fake_dev.last_upload[0..take], src[0..take]);
            fake_dev.last_upload_len = take;
        },
        cmd_transfer_from_host_3d => {
            const res = std.mem.readInt(u32, req[56..60], .little);
            const w = std.mem.readInt(u32, req[36..40], .little);
            const h = std.mem.readInt(u32, req[40..44], .little);
            const slot = backing_slot(res);
            const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(slot.addr)));
            const len = @min(@as(usize, w) * @as(usize, h) * 4, slot.len);
            for (0..len) |i| dst[i] = fake_dev.dma_marker ^ @as(u8, @truncate(i & 0x3f));
        },
        cmd_resource_attach_backing => {
            const res = std.mem.readInt(u32, req[24..28], .little);
            const addr = std.mem.readInt(u64, req[32..40], .little);
            const len = std.mem.readInt(u32, req[40..44], .little);
            fake_dev.backings[res & 7] = .{ .addr = addr, .len = len, .live = true };
        },
        cmd_resource_unref => {
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
    const t = fake_dev.reply_type_override orelse want_type;
    const c = fake_dev.reply_ctx_override orelse fake_ctx();
    const f = fake_dev.reply_fence_override orelse fake_fence();
    const u = fake_dev.reply_used_override orelse @as(u32, @intCast(used));
    if (u >= wire.hdr_len and u <= resp.len) {
        std.mem.writeInt(u32, resp[0..4], t, .little);
        std.mem.writeInt(u32, resp[4..8], 0, .little);
        std.mem.writeInt(u64, resp[8..16], f, .little);
        std.mem.writeInt(u32, resp[16..20], c, .little);
        std.mem.writeInt(u32, resp[20..24], 0, .little);
        if (t == wire.resp_ok_capset_info and resp.len >= 36) {
            std.mem.writeInt(u32, resp[24..28], wire.capset_vir1, .little);
            std.mem.writeInt(u32, resp[28..32], wire.vir1_version, .little);
            std.mem.writeInt(u32, resp[32..36], wire.vir1_payload_len, .little);
        } else if (t == wire.resp_ok_capset and resp.len >= 24 + wire.vir1_payload_len) {
            wire.encode_vir1_caps(resp[24..], fake_dev.caps_ready);
        }
    }
    return u;
}

const Backing = struct { addr: u64, len: u32, live: bool };

fn backing_slot(res: u32) *Backing {
    return &fake_dev.backings[res & 7];
}

fn fake_release(handle: u32, completed: bool) void {
    _ = handle;
    fake_dev.release_completed = completed;
}

fn fake_transport() device.Transport {
    return .{ .submit = fake_submit, .wait = fake_wait, .release = fake_release };
}

fn attach_fake() void {
    device.reset_state();
    reset_state();
    fake_dev = .{};
    device.transport = fake_transport();
    device.g3_ready = true;
}

fn req_type(idx: usize) u32 {
    return std.mem.readInt(u32, fake_dev.reqs[idx][0..4], .little);
}

fn expect_types(want: []const u32) !void {
    try testing.expectEqual(want.len, fake_dev.req_count);
    for (want, 0..) |t, i| try testing.expectEqual(t, req_type(i));
}

const wire_verts: [3]stream.WireVertex = .{
    .{ .x = -0x4000, .y = -0x2d00, .z = 0, .rgb565 = 0xf800 },
    .{ .x = 0x4000, .y = -0x2d00, .z = 0, .rgb565 = 0x07e0 },
    .{ .x = 0, .y = 0x5200, .z = 0, .rgb565 = 0x001f },
};

const clear_black: [4]f32 = .{ 0, 0, 0, 1 };

fn open_session(ctx: u32) !Session {
    _ = try device.probe_caps();
    return open(ctx, 256, 192);
}

test "gpu3d_submit: envelope encoders produce the spec byte shapes" {
    var buf: [128]u8 = @splat(0xee);
    var n = encode_create3d(&buf, 9, stream.target_2d, stream.fmt_bgra8_unorm, stream.bind_render_target, 256, 192, 7, 0x1122334455667788);
    try testing.expectEqual(@as(usize, 72), n);
    try testing.expectEqual(cmd_resource_create_3d, std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(wire.flag_fence, std.mem.readInt(u32, buf[4..8], .little));
    try testing.expectEqual(@as(u64, 0x1122334455667788), std.mem.readInt(u64, buf[8..16], .little));
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, buf[16..20], .little)); // creating ctx
    try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, buf[24..28], .little));
    try testing.expectEqual(@as(u32, stream.target_2d), std.mem.readInt(u32, buf[28..32], .little));
    try testing.expectEqual(@as(u32, stream.fmt_bgra8_unorm), std.mem.readInt(u32, buf[32..36], .little));
    try testing.expectEqual(@as(u32, stream.bind_render_target), std.mem.readInt(u32, buf[36..40], .little));
    try testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, buf[40..44], .little));
    try testing.expectEqual(@as(u32, 192), std.mem.readInt(u32, buf[44..48], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[48..52], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[52..56], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[56..60], .little)); // last_level
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[60..64], .little)); // nr_samples
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[64..68], .little)); // flags

    n = encode_attach_backing(&buf, 9, 0xdeadbeef, 0x3000, 4, 7);
    try testing.expectEqual(@as(usize, 48), n);
    try testing.expectEqual(cmd_resource_attach_backing, std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, buf[16..20], .little)); // owning ctx
    try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, buf[24..28], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[28..32], .little));
    try testing.expectEqual(@as(u64, 0xdeadbeef), std.mem.readInt(u64, buf[32..40], .little));
    try testing.expectEqual(@as(u32, 0x3000), std.mem.readInt(u32, buf[40..44], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[44..48], .little));

    // The VIR1 res-op shape is hdr + resource_id = 28 bytes; byte 28
    // onward must stay untouched (a pad word lands as trailing bytes
    // and the device refuses the request).
    var op: [32]u8 = @splat(0xee);
    n = encode_res_op(&op, cmd_ctx_attach_resource, 3, 5, 9);
    try testing.expectEqual(@as(usize, 28), n);
    try testing.expectEqual(cmd_ctx_attach_resource, std.mem.readInt(u32, op[0..4], .little));
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, op[16..20], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, op[24..28], .little));
    try testing.expectEqual(@as(u32, 0xeeeeeeee), std.mem.readInt(u32, op[28..32], .little));

    n = encode_transfer(&buf, cmd_transfer_from_host_3d, 4, .{ .x = 1, .y = 2, .z = 3, .w = 64, .h = 48, .d = 1 }, 0x80, 256, 0, 2, 11);
    try testing.expectEqual(@as(usize, 72), n);
    try testing.expectEqual(cmd_transfer_from_host_3d, std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[16..20], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[24..28], .little));
    try testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, buf[36..40], .little));
    try testing.expectEqual(@as(u32, 48), std.mem.readInt(u32, buf[40..44], .little));
    try testing.expectEqual(@as(u64, 0x80), std.mem.readInt(u64, buf[48..56], .little));
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, buf[56..60], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[60..64], .little));
    try testing.expectEqual(@as(u32, 256), std.mem.readInt(u32, buf[64..68], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[68..72], .little));

    // SUBMIT_3D envelope pins size + stream bytes after the header —
    // the payload is a one-word command (opcode 0x21, len 1).
    const str = [_]u8{ 0x21, 0, 1, 0, 5, 6, 7, 8 };
    n = try encode_submit3d(&buf, &str, 7, 99);
    try testing.expectEqual(@as(usize, 40), n);
    try testing.expectEqual(cmd_submit_3d, std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, buf[16..20], .little));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, buf[24..28], .little));
    try testing.expectEqualSlices(u8, &str, buf[32..40]);

    // Refusals: a NOP-padded 4096-byte stream fits the staging bound
    // exactly (32 + 4096 = 4128); aligned bytes beyond 4096 and
    // misaligned lengths refuse BEFORE any submission.
    var big: [4200]u8 align(4) = @splat(0);
    var wide: [device.req_staging_len]u8 = @splat(0);
    const full = try stream.encode_frame(stream_scratch[0..], .{
        .width = 256,
        .height = 192,
        .clear = clear_black,
        .res_color = 1,
        .res_vbo = 2,
    });
    const padded_len = try stream.pad_stream(stream_scratch[0..], full, stream.max_stream_bytes);
    try testing.expectEqual(@as(usize, stream.max_stream_bytes), padded_len);
    try testing.expectEqual(@as(usize, 32 + stream.max_stream_bytes), try encode_submit3d(&wide, stream_scratch[0..padded_len], 1, 1));
    try testing.expectError(error.StreamTooBig, encode_submit3d(&wide, big[0..4100], 1, 1));
    try testing.expectError(error.BadStream, encode_submit3d(&wide, stream_scratch[0..6], 1, 1));
}

test "gpu3d_submit: lifecycle transcript — create/attach/upload/submit/readback/detach/unref/destroy" {
    attach_fake();
    const h = try open_session(1);
    try expect_types(&.{
        wire.cmd_get_capset_info,    wire.cmd_get_capset,
        wire.cmd_ctx_create,         cmd_resource_create_3d,
        cmd_resource_attach_backing, cmd_ctx_attach_resource,
        cmd_resource_create_3d,      cmd_resource_attach_backing,
        cmd_ctx_attach_resource,
    });
    try testing.expectEqual(@as(usize, 1), device.live_count());
    const st = try sess_state(h);
    try testing.expect(st.live);
    try testing.expectEqual(res_all, st.res_state);

    try submit_frame(h, clear_black, &wire_verts);
    // TRANSFER_TO_HOST_3D carried the converted floats; SUBMIT_3D carried
    // the exact pinned stream.
    try testing.expectEqual(cmd_transfer_to_host_3d, req_type(9));
    try testing.expectEqual(cmd_submit_3d, req_type(10));
    var want_vbo: [vbo_bytes]u8 = undefined;
    stream.encode_vertices(&wire_verts, &want_vbo);
    try testing.expectEqualSlices(u8, &want_vbo, fake_dev.last_upload[0..fake_dev.last_upload_len]);
    var want_stream: [stream.max_stream_bytes]u8 = undefined;
    const wsn = try stream.encode_frame(&want_stream, .{
        .width = 256,
        .height = 192,
        .clear = clear_black,
        .res_color = stream.res_color_id(1),
        .res_vbo = stream.res_vbo_id(1),
    });
    try testing.expectEqualSlices(u8, want_stream[0..wsn], fake_dev.last_stream[0..fake_dev.last_stream_len]);
    try testing.expect(try frame_pending(h));

    const px = try readback(h);
    try testing.expectEqual(cmd_transfer_from_host_3d, req_type(11));
    try testing.expectEqual(@as(usize, 256 * 192 * 4), px.len);
    // The fake's DMA marker landed in the pinned backing.
    try testing.expectEqual(@as(u8, fake_dev.dma_marker ^ 0x0a), px[10]);
    try testing.expectEqualSlices(u8, px, try pixels(h));
    var copy_buf: [256 * 192 * 4]u8 = undefined;
    const cn = try copy_pixels(h, &copy_buf);
    try testing.expectEqualSlices(u8, px, copy_buf[0..cn]);
    try testing.expectError(error.OutTooSmall, copy_pixels(h, copy_buf[0..8]));

    try close(h);
    try expect_types(&.{
        wire.cmd_get_capset_info,    wire.cmd_get_capset,
        wire.cmd_ctx_create,         cmd_resource_create_3d,
        cmd_resource_attach_backing, cmd_ctx_attach_resource,
        cmd_resource_create_3d,      cmd_resource_attach_backing,
        cmd_ctx_attach_resource,     cmd_transfer_to_host_3d,
        cmd_submit_3d,               cmd_transfer_from_host_3d,
        cmd_ctx_detach_resource,     cmd_ctx_detach_resource,
        cmd_resource_detach_backing, cmd_resource_detach_backing,
        cmd_resource_unref,          cmd_resource_unref,
        wire.cmd_ctx_destroy,
    });
    try testing.expectEqual(@as(usize, 0), device.live_count());
    // The stale handle can't touch anything — not even readback.
    try testing.expectError(error.StaleSession, readback(h));
    try testing.expectError(error.StaleSession, submit_frame(h, clear_black, &wire_verts));
}

test "gpu3d_submit: bounds refuse before any device traffic" {
    attach_fake();
    try testing.expectError(error.CapsNotReady, open(1, 256, 192));
    _ = try device.probe_caps();
    try testing.expectError(error.ZeroContext, open(0, 256, 192));
    try testing.expectError(error.ContextExhausted, open(3, 256, 192));
    try testing.expectError(error.BadGeometry, open(1, 0, 192));
    try testing.expectError(error.BadGeometry, open(1, 257, 192));
    try testing.expectError(error.BadGeometry, open(1, 256, 193));
    const h = try open(1, 256, 192);
    try testing.expectError(error.DuplicateHandle, open(1, 64, 48));
    // Both profile contexts may coexist.
    const h2 = try open(2, 128, 96);
    // Smaller extents get bounded transfers.
    try submit_frame(h2, clear_black, &wire_verts);
    try close(h2);
    try close(h);
    // A renderer that is not armed refuses.
    attach_fake();
    fake_dev.caps_ready = 0;
    _ = try device.probe_caps();
    try testing.expectError(error.NotReady, open(1, 256, 192));
    // Unsupported when the feature is off.
    device.g3_ready = false;
    try testing.expectError(error.Unsupported, open(1, 256, 192));
}

test "gpu3d_submit: delayed backend — completion follows the fence, never the post" {
    attach_fake();
    const h = try open_session(1);
    fake_dev.req_count = 0;
    try submit_frame(h, clear_black, &wire_verts);
    // The fenced SUBMIT_3D reply was produced (backend completed during
    // the wait — never merely consumed at post time). REVERT-FAILS TARGET:
    // under the consumption-as-completion seam, submit3d_waits stays 0
    // and backend_pending stays true — this test goes red while the
    // byte-order assertions above stay green.
    try testing.expectEqual(@as(usize, 1), fake_dev.submit3d_waits);
    try testing.expect(!fake_dev.backend_pending);
    try testing.expect(try frame_pending(h));
    try testing.expect((try sess_state(h)).frame_fence != 0);
    try close(h);
}

test "gpu3d_submit: completion negatives — wrong ctx/fence/type/used refuse" {
    attach_fake();
    const h = try open_session(1);

    fake_dev.reply_ctx_override = 7;
    try testing.expectError(error.BadResponse, submit_frame(h, clear_black, &wire_verts));
    try testing.expectError(error.NoFrame, readback(h));
    fake_dev.reply_ctx_override = null;

    fake_dev.reply_fence_override = 0x1111111111111111;
    try testing.expectError(error.BadResponse, submit_frame(h, clear_black, &wire_verts));
    fake_dev.reply_fence_override = null;

    fake_dev.reply_type_override = wire.resp_ok_capset;
    try testing.expectError(error.BadResponse, submit_frame(h, clear_black, &wire_verts));
    fake_dev.reply_type_override = null;

    fake_dev.reply_used_override = wire.nodata_resp_len - 1;
    try testing.expectError(error.ResponseTruncated, submit_frame(h, clear_black, &wire_verts));
    fake_dev.reply_used_override = null;

    fake_dev.reply_used_override = wire.nodata_resp_len + 4;
    try testing.expectError(error.ResponseOversized, submit_frame(h, clear_black, &wire_verts));
    fake_dev.reply_used_override = null;

    // The handle is still good — the device recovers.
    try submit_frame(h, clear_black, &wire_verts);
    _ = try readback(h);
    try close(h);
}

test "gpu3d_submit: timeout poisons; ops refuse; close quarantines until drain completes" {
    attach_fake();
    const h = try open_session(1);
    fake_dev.never_complete = true;
    try testing.expectError(error.Timeout, submit_frame(h, clear_black, &wire_verts));
    // Poisoned: everything but close refuses; the frame is not ready.
    try testing.expectError(error.Poisoned, submit_frame(h, clear_black, &wire_verts));
    try testing.expectError(error.Poisoned, readback(h));
    try testing.expectError(error.Poisoned, pixels(h));
    // Close against the still-dead device: the drain can't finish, the
    // slot stays quarantined (backing pinned, teardown still owed).
    try testing.expectError(error.Timeout, close(h));
    const s = &sessions[0];
    try testing.expect(s.live and s.poisoned);
    try testing.expect(s.res_state != 0);
    // The device recovers (confirmed reset): a resumed close drains the
    // remaining steps and returns the pool to baseline.
    fake_dev.never_complete = false;
    try close(h);
    try testing.expectEqual(@as(u6, 0), s.res_state);
    try testing.expect(!s.live);
    try testing.expectEqual(@as(usize, 0), device.live_count());
    // Pools are baseline — a fresh open on the same ctx works.
    const h2 = try open(1, 128, 96);
    try close(h2);
}

test "gpu3d_submit: stale generation and replayed fences cannot drive a recycled session" {
    attach_fake();
    const h = try open_session(1);
    try submit_frame(h, clear_black, &wire_verts);
    const old_fence = (try sess_state(h)).frame_fence;
    try close(h);
    try testing.expectError(error.StaleSession, readback(h));

    const h2 = try open(1, 256, 192);
    // A late/echoed fence from the dead generation mismatches the live
    // request — the exchange refuses before any frame is marked ready.
    fake_dev.reply_fence_override = old_fence;
    try testing.expectError(error.BadResponse, submit_frame(h2, clear_black, &wire_verts));
    try testing.expect(!(try frame_pending(h2)));
    fake_dev.reply_fence_override = null;
    try submit_frame(h2, clear_black, &wire_verts);
    try close(h2);
}

test "gpu3d_submit: failed open quarantines; retire drains to baseline" {
    attach_fake();
    const h2 = try open_session(2); // baseline probe on ctx 2
    try close(h2);
    device.reset_state();
    reset_state();
    device.g3_ready = true;
    _ = try device.probe_caps();

    // Die at the first backing attach — the context and the color
    // resource exist device-side when the timeout hits.
    fake_dev.req_count = 0;
    fake_dev.die_at = 4;
    try testing.expectError(error.Timeout, open(1, 256, 192));
    const s = &sessions[0];
    // Quarantined: not live, poisoned, teardown still owed, backing pinned.
    try testing.expect(!s.live);
    try testing.expect(s.poisoned);
    try testing.expect(s.res_state != 0 or s.ctx.ctx_id != 0);
    try testing.expectEqual(@as(usize, 1), quarantined_count());
    fake_dev.die_at = null;
    try testing.expectError(error.Poisoned, open(1, 256, 192));
    // Confirmed reset: retire drains the owed steps, pools return to baseline.
    try retire(1);
    try testing.expectEqual(@as(u6, 0), s.res_state);
    try testing.expect(!s.poisoned);
    try testing.expectEqual(@as(usize, 0), quarantined_count());
    const h = try open(1, 256, 192);
    try submit_frame(h, clear_black, &wire_verts);
    _ = try readback(h);
    try close(h);
}

test "gpu3d_submit: readback before any completed frame refuses" {
    attach_fake();
    const h = try open_session(1);
    try testing.expectError(error.NoFrame, readback(h));
    try testing.expectError(error.NoPixels, pixels(h));
    try testing.expect(!(try frame_pending(h)));
    try close(h);
}
