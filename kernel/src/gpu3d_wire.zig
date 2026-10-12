//! VirelaiOS experimental GPU3D wire layer (M102b1, issue #2162 — card of
//! the M102 index, issue #2160).
//!
//! Explicit little-endian encoders/decoders for the four virtio-gpu
//! envelope commands the private render channel uses, plus the pinned
//! original byte vectors that pin the encoding. This is the GUEST side of
//! the b1 transport card: wire shapes only — no device state, no rings,
//! no MMIO. gpu3d_device.zig owns discovery, the control queue, the
//! bounded exchange and the context lifecycle on top of these shapes.
//!
//! The device is the owner-approved custom-virtio render channel
//! (virtio device ID 0x43, PCI DID 0x1083 = 0x1040 + 0x43 — the second
//! custom device after the 0x42 host channel). It speaks virtio-gpu
//! CONTROL-queue envelopes carrying the pinned private capability
//! profile; it is NOT a second virtio-gpu (the native 1af4:1050 2D
//! device is untouched) and a standard QEMU virtio-gpu cannot bind this
//! profile unchanged:
//!
//!   * GET_CAPSET_INFO index 0 reports the private capset id `VIR1`
//!     (0x56495231), max_version 1, payload size 32. Any other profile,
//!     version or size is refused.
//!   * GET_CAPSET (capset VIR1, version 1) returns eight LE u32 words:
//!     version=1, max_width=256, max_height=192, contexts=2,
//!     resources_per_context=2, max_submit_bytes=4096, shader_pair=1,
//!     ready=0|1.
//!   * CTX_CREATE/CTX_DESTROY create and retire one of the two bounded
//!     render contexts (system-wide; one per hosted window at the seam
//!     above — this layer only carries the wire).
//!
//! Every private command carries VIRTIO_GPU_FLAG_FENCE and a unique u64
//! fence id; the device echoes request ctx_id + fence_id in the response
//! header. Reply-type-only completion is not completion — the exchange in
//! gpu3d_device.zig matches response type, used descriptor id/length,
//! context and the full fence before a request is considered done.
//!
//! Wire reference: Virtio 1.3 §5.7.6 (the virtio_gpu_ctrl_hdr envelope,
//! GET_CAPSET_INFO/GET_CAPSET and CTX_CREATE/CTX_DESTROY). This is a
//! PRIVATE profile inside those envelopes — not capset 1 (VIRGL),
//! VIRGL2, or VENUS.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");

// ---------------------------------------------------------------------------
// virtio-gpu envelope constants (Virtio 1.3 §5.7.6)
// ---------------------------------------------------------------------------

/// virtio_gpu_ctrl_hdr: type(4) flags(4) fence_id(8) ctx_id(4) ring_idx(4).
pub const hdr_len: usize = 24;

/// Command types on the control queue (the subset this channel uses).
pub const cmd_get_capset_info: u32 = 0x0108;
pub const cmd_get_capset: u32 = 0x0109;
pub const cmd_ctx_create: u32 = 0x0200;
pub const cmd_ctx_destroy: u32 = 0x0201;

/// Response types. 0x1100–0x11ff are OK responses; 0x1200+ are errors.
pub const resp_ok_nodata: u32 = 0x1100;
pub const resp_ok_capset_info: u32 = 0x1102;
pub const resp_ok_capset: u32 = 0x1103;
pub const resp_err_unspec: u32 = 0x1200;

/// virtio_gpu_ctrl_hdr.flags: the request carries a fence the device must
/// echo (and signal) in the response. Every private command sets it — the
/// echoed full u64 fence is half of the completion match.
pub const flag_fence: u32 = 0x1;

/// Command/response sizes on the wire (envelope + payload).
pub const get_capset_info_req_len: usize = 32;
pub const get_capset_info_resp_len: usize = 40;
pub const get_capset_req_len: usize = 32;
pub const capset_resp_hdr_len: usize = 24; // resp = hdr + capset_data[]
pub const ctx_create_req_len: usize = 96;
pub const ctx_destroy_req_len: usize = 24;
pub const nodata_resp_len: usize = 24;

// ---------------------------------------------------------------------------
// The private VIR1 capability profile (owner-approved, issue #2160 §2)
// ---------------------------------------------------------------------------

/// Capset id reported by GET_CAPSET_INFO index 0: ASCII "VIR1" packed as
/// the u32 0x56495231.
pub const capset_vir1: u32 = 0x56495231;
/// The only capset index this device answers for.
pub const capset_index: u32 = 0;
/// The only accepted capset version.
pub const vir1_version: u32 = 1;
/// The only accepted capset payload size (eight LE u32 words).
pub const vir1_payload_len: u32 = 32;

/// The decoded VIR1 profile — the fixed bounds the whole milestone is
/// shaped by (#2160 §3). Fields carry the wire order: version, max_width,
/// max_height, contexts, resources_per_context, max_submit_bytes,
/// shader_pair, ready.
pub const Vir1Caps = struct {
    version: u32,
    max_width: u32,
    max_height: u32,
    contexts: u32,
    resources_per_context: u32,
    max_submit_bytes: u32,
    shader_pair: u32,
    ready: u32,
};

/// The pinned profile values (every word except `ready` is a fixed bound;
/// `ready` is 0|1 — 0 means "device present, renderer not armed").
pub const vir1_max_width: u32 = 256;
pub const vir1_max_height: u32 = 192;
pub const vir1_contexts: u32 = 2;
pub const vir1_resources_per_context: u32 = 2;
pub const vir1_max_submit_bytes: u32 = 4096;
pub const vir1_shader_pair: u32 = 1;

// ---------------------------------------------------------------------------
// Encoders (explicit LE writes; no padding bytes are left uninitialized)
// ---------------------------------------------------------------------------

fn put32(out: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, out[off..][0..4], v, .little);
}

fn put64(out: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, out[off..][0..8], v, .little);
}

fn put_hdr(out: []u8, cmd_type: u32, ctx_id: u32, fence_id: u64) void {
    put32(out, 0, cmd_type);
    put32(out, 4, flag_fence);
    put64(out, 8, fence_id);
    put32(out, 16, ctx_id);
    put32(out, 20, 0); // ring_idx — the private channel uses ring 0 only
}

/// GET_CAPSET_INFO (0x0108): hdr + capset_index + padding = 32 bytes.
/// `fence_id` is the request's unique fence (the device echoes it).
pub fn encode_get_capset_info(out: []u8, index: u32, fence_id: u64) usize {
    std.debug.assert(out.len >= get_capset_info_req_len);
    put_hdr(out, cmd_get_capset_info, 0, fence_id);
    put32(out, 24, index);
    put32(out, 28, 0); // padding
    return get_capset_info_req_len;
}

/// GET_CAPSET (0x0109): hdr + capset_id + capset_version = 32 bytes.
pub fn encode_get_capset(out: []u8, capset_id: u32, capset_version: u32, fence_id: u64) usize {
    std.debug.assert(out.len >= get_capset_req_len);
    put_hdr(out, cmd_get_capset, 0, fence_id);
    put32(out, 24, capset_id);
    put32(out, 28, capset_version);
    return get_capset_req_len;
}

/// CTX_CREATE (0x0200): hdr + nlen + context_init + rname[64] = 96 bytes.
/// The context id travels in the header; `name` is the bounded debug name
/// (≤ 64 bytes, NUL-free zone is zero-filled). `context_init` stays 0 —
/// the private profile negotiates no context-init feature bits.
pub fn encode_ctx_create(out: []u8, ctx_id: u32, context_init: u32, name: []const u8, fence_id: u64) usize {
    std.debug.assert(out.len >= ctx_create_req_len);
    std.debug.assert(name.len <= 64);
    put_hdr(out, cmd_ctx_create, ctx_id, fence_id);
    put32(out, 24, @intCast(name.len));
    put32(out, 28, context_init);
    @memset(out[32..96], 0);
    @memcpy(out[32 .. 32 + name.len], name);
    return ctx_create_req_len;
}

/// CTX_DESTROY (0x0201): the header alone names the context = 24 bytes.
pub fn encode_ctx_destroy(out: []u8, ctx_id: u32, fence_id: u64) usize {
    std.debug.assert(out.len >= ctx_destroy_req_len);
    put_hdr(out, cmd_ctx_destroy, ctx_id, fence_id);
    return ctx_destroy_req_len;
}

// ---------------------------------------------------------------------------
// Decoders (pure parse — the device layer owns the refusal names)
// ---------------------------------------------------------------------------

/// A parsed virtio_gpu_ctrl_hdr from a response buffer.
pub const Hdr = struct {
    type: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    ring_idx: u32,
};

fn get32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn get64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

/// Parse a response header. Returns null when the buffer cannot hold one
/// (a truncated reply is never a partial success).
pub fn parse_hdr(resp: []const u8) ?Hdr {
    if (resp.len < hdr_len) return null;
    return .{
        .type = get32(resp, 0),
        .flags = get32(resp, 4),
        .fence_id = get64(resp, 8),
        .ctx_id = get32(resp, 16),
        .ring_idx = get32(resp, 20),
    };
}

/// A parsed GET_CAPSET_INFO reply (type + the three payload words).
pub const CapsetInfo = struct {
    capset_id: u32,
    max_version: u32,
    max_size: u32,
};

/// Parse a RESP_OK_CAPSET_INFO payload region (bytes 24..40 of the reply).
/// Returns null when the reply is shorter than the pinned 40-byte shape.
pub fn parse_capset_info(resp: []const u8) ?CapsetInfo {
    if (resp.len < get_capset_info_resp_len) return null;
    return .{
        .capset_id = get32(resp, 24),
        .max_version = get32(resp, 28),
        .max_size = get32(resp, 32),
    };
}

/// Parse the VIR1 capset payload (resp bytes 24..56 — exactly eight u32
/// words). Returns null when the payload is short or over-long: the
/// private profile pins the size, so a different length is a different
/// profile, not a slice to tolerate.
pub fn parse_vir1(payload: []const u8) ?Vir1Caps {
    if (payload.len != vir1_payload_len) return null;
    return .{
        .version = get32(payload, 0),
        .max_width = get32(payload, 4),
        .max_height = get32(payload, 8),
        .contexts = get32(payload, 12),
        .resources_per_context = get32(payload, 16),
        .max_submit_bytes = get32(payload, 20),
        .shader_pair = get32(payload, 24),
        .ready = get32(payload, 28),
    };
}

// ---------------------------------------------------------------------------
// Pinned original request vectors (issue #2162 acceptance: the fake-device
// transcript is byte-compared against these). The fence ids are the device
// sequence's first four values — fence_counter starts at 1 and advances
// once per submitted request, so GET_CAPSET_INFO carries fence 1,
// GET_CAPSET fence 2, the first CTX_CREATE (ctx 1, name "vir1c1") fence 3,
// and its CTX_DESTROY fence 4.
// ---------------------------------------------------------------------------

/// GET_CAPSET_INFO index 0, fence 1.
pub const golden_get_capset_info: [get_capset_info_req_len]u8 = .{
    0x08, 0x01, 0x00, 0x00, // type 0x0108
    0x01, 0x00, 0x00, 0x00, // flags = FENCE
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id = 1
    0x00, 0x00, 0x00, 0x00, // ctx_id = 0
    0x00, 0x00, 0x00, 0x00, // ring_idx = 0
    0x00, 0x00, 0x00, 0x00, // capset_index = 0
    0x00, 0x00, 0x00, 0x00, // padding
};

/// GET_CAPSET capset VIR1 version 1, fence 2.
pub const golden_get_capset: [get_capset_req_len]u8 = .{
    0x09, 0x01, 0x00, 0x00, // type 0x0109
    0x01, 0x00, 0x00, 0x00, // flags = FENCE
    0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id = 2
    0x00, 0x00, 0x00, 0x00, // ctx_id = 0
    0x00, 0x00, 0x00, 0x00, // ring_idx = 0
    0x31, 0x52, 0x49, 0x56, // capset_id = 0x56495231 ("VIR1" LE)
    0x01, 0x00, 0x00, 0x00, // capset_version = 1
};

/// CTX_CREATE ctx_id 1, context_init 0, rname "vir1c1", fence 3.
pub const golden_ctx_create: [ctx_create_req_len]u8 = .{
    0x00, 0x02, 0x00, 0x00, // type 0x0200
    0x01, 0x00, 0x00, 0x00, // flags = FENCE
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id = 3
    0x01, 0x00, 0x00, 0x00, // ctx_id = 1
    0x00, 0x00, 0x00, 0x00, // ring_idx = 0
    0x06, 0x00, 0x00, 0x00, // nlen = 6
    0x00, 0x00, 0x00, 0x00, // context_init = 0
    'v', 'i', 'r', '1', 'c', '1', 0, 0, // rname[64] begins
    0,   0,   0,   0,   0,   0,   0, 0,
    0,   0,   0,   0,   0,   0,   0, 0,
    0,   0,   0,   0,   0,   0,   0, 0,
    0,   0,   0,   0,   0,   0,   0, 0,
    0,   0,   0,   0,   0,   0,   0, 0,
    0,   0,   0,   0,   0,   0,   0, 0,
    0,   0,   0,   0,   0,   0,   0, 0,
};

/// CTX_DESTROY ctx_id 1, fence 4.
pub const golden_ctx_destroy: [ctx_destroy_req_len]u8 = .{
    0x01, 0x02, 0x00, 0x00, // type 0x0201
    0x01, 0x00, 0x00, 0x00, // flags = FENCE
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id = 4
    0x01, 0x00, 0x00, 0x00, // ctx_id = 1
    0x00, 0x00, 0x00, 0x00, // ring_idx = 0
};

/// Build the canonical VIR1 capset payload (used by the fake-device
/// transcripts in tests — ready is the only variable word).
pub fn encode_vir1_caps(out: []u8, ready: u32) void {
    std.debug.assert(out.len >= vir1_payload_len);
    put32(out, 0, vir1_version);
    put32(out, 4, vir1_max_width);
    put32(out, 8, vir1_max_height);
    put32(out, 12, vir1_contexts);
    put32(out, 16, vir1_resources_per_context);
    put32(out, 20, vir1_max_submit_bytes);
    put32(out, 24, vir1_shader_pair);
    put32(out, 28, ready);
}

// ---------------------------------------------------------------------------
// Host tests — encoding pins, decode bounds, golden parity
// ---------------------------------------------------------------------------

test "gpu3d_wire: command/response constants are the spec values" {
    try std.testing.expectEqual(@as(u32, 0x0108), cmd_get_capset_info);
    try std.testing.expectEqual(@as(u32, 0x0109), cmd_get_capset);
    try std.testing.expectEqual(@as(u32, 0x0200), cmd_ctx_create);
    try std.testing.expectEqual(@as(u32, 0x0201), cmd_ctx_destroy);
    try std.testing.expectEqual(@as(u32, 0x1100), resp_ok_nodata);
    try std.testing.expectEqual(@as(u32, 0x1102), resp_ok_capset_info);
    try std.testing.expectEqual(@as(u32, 0x1103), resp_ok_capset);
    try std.testing.expectEqual(@as(u32, 0x56495231), capset_vir1);
    try std.testing.expectEqual(@as(u32, 1), vir1_version);
    try std.testing.expectEqual(@as(u32, 32), vir1_payload_len);
}

test "gpu3d_wire: encoders produce the pinned golden bytes" {
    var buf: [128]u8 = undefined;
    const n1 = encode_get_capset_info(&buf, capset_index, 1);
    try std.testing.expectEqualSlices(u8, &golden_get_capset_info, buf[0..n1]);
    const n2 = encode_get_capset(&buf, capset_vir1, vir1_version, 2);
    try std.testing.expectEqualSlices(u8, &golden_get_capset, buf[0..n2]);
    const n3 = encode_ctx_create(&buf, 1, 0, "vir1c1", 3);
    try std.testing.expectEqualSlices(u8, &golden_ctx_create, buf[0..n3]);
    const n4 = encode_ctx_destroy(&buf, 1, 4);
    try std.testing.expectEqualSlices(u8, &golden_ctx_destroy, buf[0..n4]);
}

test "gpu3d_wire: hdr parse reads type/flags/fence/ctx/ring LE" {
    var buf: [24]u8 = undefined;
    _ = encode_ctx_destroy(&buf, 0x11223344, 0x0102030405060708);
    const h = parse_hdr(&buf).?;
    try std.testing.expectEqual(@as(u32, cmd_ctx_destroy), h.type);
    try std.testing.expectEqual(@as(u32, flag_fence), h.flags);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), h.fence_id);
    try std.testing.expectEqual(@as(u32, 0x11223344), h.ctx_id);
    try std.testing.expectEqual(@as(u32, 0), h.ring_idx);
    // Short buffers never parse.
    try std.testing.expectEqual(@as(?Hdr, null), parse_hdr(buf[0..23]));
    try std.testing.expectEqual(@as(?Hdr, null), parse_hdr(buf[0..0]));
}

test "gpu3d_wire: capset-info parse bounds the pinned 40-byte shape" {
    var resp: [40]u8 = @splat(0);
    std.mem.writeInt(u32, resp[0..4], resp_ok_capset_info, .little);
    std.mem.writeInt(u32, resp[24..28], capset_vir1, .little);
    std.mem.writeInt(u32, resp[28..32], 1, .little);
    std.mem.writeInt(u32, resp[32..36], 32, .little);
    const info = parse_capset_info(&resp).?;
    try std.testing.expectEqual(@as(u32, capset_vir1), info.capset_id);
    try std.testing.expectEqual(@as(u32, 1), info.max_version);
    try std.testing.expectEqual(@as(u32, 32), info.max_size);
    // 39 bytes is a truncated reply, not a smaller profile.
    try std.testing.expectEqual(@as(?CapsetInfo, null), parse_capset_info(resp[0..39]));
}

test "gpu3d_wire: vir1 payload round-trips and length is exact" {
    var payload: [32]u8 = undefined;
    encode_vir1_caps(&payload, 1);
    const caps = parse_vir1(&payload).?;
    try std.testing.expectEqual(@as(u32, 1), caps.version);
    try std.testing.expectEqual(@as(u32, 256), caps.max_width);
    try std.testing.expectEqual(@as(u32, 192), caps.max_height);
    try std.testing.expectEqual(@as(u32, 2), caps.contexts);
    try std.testing.expectEqual(@as(u32, 2), caps.resources_per_context);
    try std.testing.expectEqual(@as(u32, 4096), caps.max_submit_bytes);
    try std.testing.expectEqual(@as(u32, 1), caps.shader_pair);
    try std.testing.expectEqual(@as(u32, 1), caps.ready);
    // Length is pinned: 31 short and 33 long are both refused, not sliced.
    try std.testing.expectEqual(@as(?Vir1Caps, null), parse_vir1(payload[0..31]));
    var long: [33]u8 = @splat(0);
    @memcpy(long[0..32], &payload);
    try std.testing.expectEqual(@as(?Vir1Caps, null), parse_vir1(&long));
}

test "gpu3d_wire: ctx_create bounds the name and zero-fills rname" {
    var buf: [96]u8 = undefined;
    const name = "0123456789012345678901234567890123456789012345678901234567890123";
    try std.testing.expectEqual(@as(usize, 64), name.len);
    const n = encode_ctx_create(&buf, 2, 0, name, 0xdead);
    try std.testing.expectEqual(@as(usize, 96), n);
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, buf[24..28], .little));
    try std.testing.expectEqualSlices(u8, name, buf[32..96]);
    // A short name leaves the rname tail zeroed.
    _ = encode_ctx_create(&buf, 1, 0, "x", 5);
    var z: usize = 0;
    for (buf[33..96]) |b| z += b;
    try std.testing.expectEqual(@as(usize, 0), z);
}
