//! VirelaiOS experimental GPU3D — VirGL command-stream encoder
//! (M102c1, issue #2164 — card of the M102 index, issue #2160).
//!
//! This module emits the ONE pinned command stream the private VIR1
//! profile carries inside SUBMIT_3D: the allowlisted fixed state, the
//! two original TGSI texts, a color clear and a single non-indexed
//! TRIANGLES draw of three vertices. It never emits sampler/texture,
//! query, index-buffer, indirect, tessellation, compute, sub-context or
//! MSAA commands — the host decoder (c2) recognizes exactly this frozen
//! shape and the two exact shader texts.
//!
//! Wire ground truth (pinned MIT reference — virgl_protocol.h and
//! virgl_hw.h at utmapp/virglrenderer 9fbc538ac6441fb305d5963e09c70890fec0216b,
//! read-only; MIT licensed, nothing vendored): a command stream is
//! little-endian 32-bit words; word 0 of each command packs
//! cmd[7:0] | object[15:8] | payload_words[31:16] (the count EXCLUDES
//! the header word). Object handles, resource ids and context ids are
//! three distinct namespaces. NOP is a zero-payload command and is the
//! ONLY padding this profile allows — it cannot mutate state or draw.
//!
//! Pinned namespaces and order (the triangle.words fixture pins the
//! canonical instance byte-for-byte):
//!
//!   object handles: surface=1, vertex-elements=2, blend=3, rasterizer=4,
//!                   dsa=5, vertex-shader=6, fragment-shader=7
//!   resources     : res_color = 2*ctx_id - 1, res_vbo = 2*ctx_id
//!                   (globally unique across the two bounded contexts;
//!                   the fixture pins ctx 1's ids 1 and 2)
//!   stream order  : CREATE surface, vertex-elements, blend, rasterizer,
//!                   dsa, vshader, fshader; BIND_SHADER v/f;
//!                   BIND_OBJECT blend, rasterizer, dsa, vertex-elements;
//!                   SET_FRAMEBUFFER_STATE (1 cbuf, no depth),
//!                   SET_VIEWPORT_STATE (one viewport),
//!                   SET_VERTEX_BUFFERS (one buffer),
//!                   CLEAR (color buffer 0), DRAW_VBO (TRIANGLES, 3 verts,
//!                   1 instance, non-indexed); DESTROY_OBJECT in reverse
//!                   creation order so each frame leaves the host object
//!                   table at baseline.
//!
//!   viewport      : scale = {w/2, h/2, 1.0}, translate = {w/2, h/2, 0.0}
//!                   — NDC (-1,-1) maps to readback pixel (0,0), the
//!                   FIRST row of the backing; +y NDC maps to increasing
//!                   row index (top-left origin).
//!   vertex buffer : 3 vertices x 32 bytes: float4 position {x,y,z,1}
//!                   then float4 color {r,g,b,a=1}, declared by the two
//!                   vertex elements (offset 0 and 16, stride 32,
//!                   VIRGL_FORMAT_R32G32B32A32_FLOAT).
//!   TGSI payload  : the file bytes, one NUL terminator byte, zero pad
//!                   to the 4-byte boundary. OFFSET and NUM_TOKENS both
//!                   carry the padded dword count — the text is exactly
//!                   the committed fixture, terminated for the decoder.
//!
//! Vertex wire format (the app-facing 8 bytes from #2160 §5 — apps never
//! see this module): i16 LE normalized x/y, u16 LE normalized z,
//! u16 LE RGB565. The trusted encoder converts positions and color to
//! floats deterministically; no raw streams, shader handles or GPU
//! addresses escape upward.
//!
//! No libc, no POSIX, no allocation.

const std = @import("std");

// ---------------------------------------------------------------------------
// virgl command ids + object types (virgl_protocol.h, pinned revision)
// ---------------------------------------------------------------------------

pub const ccmd_nop: u32 = 0;
pub const ccmd_create_object: u32 = 1;
pub const ccmd_bind_object: u32 = 2;
pub const ccmd_destroy_object: u32 = 3;
pub const ccmd_set_viewport_state: u32 = 4;
pub const ccmd_set_framebuffer_state: u32 = 5;
pub const ccmd_set_vertex_buffers: u32 = 6;
pub const ccmd_clear: u32 = 7;
pub const ccmd_draw_vbo: u32 = 8;

/// The pinned frame's only geometry command is always emitted — the
/// revert-fails proof flips this and watches the byte-exact and
/// draw-count assertions go red while clear encoding stays green.
pub const emit_draw: bool = true;
pub const ccmd_bind_shader: u32 = 30;

pub const obj_blend: u32 = 1;
pub const obj_rasterizer: u32 = 2;
pub const obj_dsa: u32 = 3;
pub const obj_shader: u32 = 4;
pub const obj_vertex_elements: u32 = 5;
pub const obj_surface: u32 = 8;

/// Formats on the wire (virgl_hw.h, same pinned revision).
pub const fmt_bgra8_unorm: u32 = 1;
pub const fmt_r32g32b32a32_float: u32 = 31;

/// Resource bind flags (virgl_hw.h).
pub const bind_render_target: u32 = 1 << 1;
pub const bind_vertex_buffer: u32 = 1 << 4;

/// Texture targets (gallium pipe_texture_target numbering).
pub const target_buffer: u32 = 0;
pub const target_2d: u32 = 2;

/// Shader stages (gallium pipe_shader_type numbering).
pub const shader_vertex: u32 = 0;
pub const shader_fragment: u32 = 1;

/// Primitive modes (gallium pipe_prim_type numbering).
pub const prim_triangles: u32 = 4;

/// CLEAR buffers word bit for color buffer 0 (gallium PIPE_CLEAR_COLOR0).
pub const clear_color0: u32 = 1;

// ---------------------------------------------------------------------------
// The pinned object handle / resource namespace + profile bounds
// ---------------------------------------------------------------------------

pub const h_surface: u32 = 1;
pub const h_velements: u32 = 2;
pub const h_blend: u32 = 3;
pub const h_rasterizer: u32 = 4;
pub const h_dsa: u32 = 5;
pub const h_vshader: u32 = 6;
pub const h_fshader: u32 = 7;

/// Resource ids are globally unique across the two bounded contexts:
/// ctx 1 owns 1 (color) and 2 (vbo), ctx 2 owns 3 and 4.
pub fn res_color_id(ctx_id: u32) u32 {
    return ctx_id * 2 - 1;
}
pub fn res_vbo_id(ctx_id: u32) u32 {
    return ctx_id * 2;
}

/// VIR1 profile bounds (#2160 §3): the stream may never exceed the
/// device's max_submit_bytes and always sits inside the 4128-byte
/// SUBMIT_3D staging (32-byte envelope + stream).
pub const max_stream_bytes: usize = 4096;
pub const max_width: u32 = 256;
pub const max_height: u32 = 192;

/// The two original TGSI texts — pinned verbatim as literals because a
/// leaf module compiled standalone (`zig test kernel/src/gpu3d_stream.zig`)
/// cannot @embedFile outside its package root. The committed fixtures
/// test/fixtures/gpu3d/{vertex,fragment}.tgsi carry the SAME bytes for
/// c2's independent decode; the suite loads them at runtime and asserts
/// byte equality, so the two can never drift. The Metal backend
/// recognizes these exact texts.
pub const vertex_shader_text: []const u8 =
    "VERT\n" ++
    "DCL IN[0]\n" ++
    "DCL IN[1]\n" ++
    "DCL OUT[0], POSITION\n" ++
    "DCL OUT[1], COLOR\n" ++
    "MOV OUT[0], IN[0]\n" ++
    "MOV OUT[1], IN[1]\n" ++
    "END\n";
pub const fragment_shader_text: []const u8 =
    "FRAG\n" ++
    "DCL IN[0], COLOR\n" ++
    "DCL OUT[0], COLOR\n" ++
    "MOV OUT[0], IN[0]\n" ++
    "END\n";

// ---------------------------------------------------------------------------
// Low-level emitters
// ---------------------------------------------------------------------------

pub const Error = error{
    /// The result would exceed out.len or the 4096-byte stream bound.
    StreamTooBig,
    /// Render extent outside the VIR1 profile (1..256 x 1..192).
    BadGeometry,
    /// Stream walk found a truncated/over-declaring command.
    BadStream,
};

fn put32(out: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, out[off..][0..4], v, .little);
}

fn cmd0(cmd: u32, obj: u32, len: u32) u32 {
    return cmd | (obj << 8) | (len << 16);
}

/// A cursor over `out` that appends whole commands; every overflow path
/// is the named StreamTooBig, never a partial write returned as success.
const Cursor = struct {
    buf: []u8,
    at: usize = 0,

    fn words(c: *Cursor, cmd: u32, obj: u32, payload: []const u32) Error!void {
        const need = (payload.len + 1) * 4;
        if (c.at + need > c.buf.len or c.at + need > max_stream_bytes) return error.StreamTooBig;
        put32(c.buf, c.at, cmd0(cmd, obj, @intCast(payload.len)));
        for (payload, 0..) |w, i| put32(c.buf, c.at + 4 + i * 4, w);
        c.at += need;
    }
};

// ---------------------------------------------------------------------------
// The pinned fixed-state values
// ---------------------------------------------------------------------------

/// Blend word per render target: blend disabled, rgb/alpha src factor
/// ONE (1) at bits 4/17, all other factors ZERO, colormask RGBA (0xf at
/// bits 27..30). logicop disabled -> the func word stays 0.
pub const blend_rt_word: u32 = (1 << 4) | (1 << 17) | (0xf << 27);

/// Rasterizer s0: depth_clip (bit 1) + front_ccw (bit 15); no cull, fill
/// both faces, no offsets, GL half-pixel/bottom-edge convention (0).
pub const rasterizer_s0: u32 = (1 << 1) | (1 << 15);

const f32_1: u32 = @bitCast(@as(f32, 1.0));

// ---------------------------------------------------------------------------
// The frame stream
// ---------------------------------------------------------------------------

/// Everything that varies in the pinned stream. `clear` is the RGBA
/// clear color (opaque alpha is an upper-layer contract — the encoder
/// writes what it is given). Resource ids come from res_*_id(ctx_id).
pub const FrameSpec = struct {
    width: u32,
    height: u32,
    clear: [4]f32,
    res_color: u32,
    res_vbo: u32,
};

/// The canonical instance the triangle.words fixture pins: the full
/// 256x192 profile extent, opaque-black clear, ctx 1's resources.
pub const canonical_spec: FrameSpec = .{
    .width = 256,
    .height = 192,
    .clear = .{ 0, 0, 0, 1 },
    .res_color = 1,
    .res_vbo = 2,
};

/// dword count the shader text occupies: bytes + NUL terminator, padded
/// to the word boundary.
fn text_words(text: []const u8) usize {
    return (text.len + 1 + 3) / 4;
}

/// Emit one CREATE_SHADER: payload = handle, type, offset (= padded
/// dword count, the full length per VIRGL_OBJ_SHADER_OFFSET), num_tokens
/// (same — the private profile carries text words, not binary tokens),
/// so_num_outputs = 0, then the text bytes + NUL + zero pad.
fn emit_shader(c: *Cursor, handle: u32, shader_type: u32, text: []const u8) Error!void {
    const words = text_words(text);
    const payload_words = 5 + words;
    const need = (payload_words + 1) * 4;
    if (c.at + need > c.buf.len or c.at + need > max_stream_bytes) return error.StreamTooBig;
    put32(c.buf, c.at, cmd0(ccmd_create_object, obj_shader, @intCast(payload_words)));
    put32(c.buf, c.at + 4, handle);
    put32(c.buf, c.at + 8, shader_type);
    put32(c.buf, c.at + 12, @intCast(words)); // offset: full length in dwords
    put32(c.buf, c.at + 16, @intCast(words)); // num_tokens: text dword count
    put32(c.buf, c.at + 20, 0); // stream-output count
    const text_start = c.at + 24;
    const text_end = text_start + words * 4;
    @memset(c.buf[text_start..text_end], 0);
    @memcpy(c.buf[text_start .. text_start + text.len], text);
    // The byte after the text stays 0 — the pinned NUL terminator.
    c.at += need;
}

/// Encode the full pinned frame stream for `spec` into `out`.
/// Returns the byte length used (a multiple of 4). Nothing is written
/// beyond the returned length; a too-small buffer or out-of-profile
/// geometry is refused BEFORE any bytes are produced.
pub fn encode_frame(out: []u8, spec: FrameSpec) Error!usize {
    if (spec.width == 0 or spec.width > max_width or
        spec.height == 0 or spec.height > max_height) return error.BadGeometry;
    var c: Cursor = .{ .buf = out };

    // --- creates (object table at baseline before and after) ---
    try c.words(ccmd_create_object, obj_surface, &.{
        h_surface, spec.res_color, fmt_bgra8_unorm, 0, 0, // level 0, single layer
    });
    try c.words(ccmd_create_object, obj_vertex_elements, &.{
        h_velements,
        // element 0: position float4 at offset 0, buffer 0, stride 32
        0,
        0,
        0,
        fmt_r32g32b32a32_float,
        // element 1: color float4 at offset 16
        16,
        0,
        0,
        fmt_r32g32b32a32_float,
    });
    try c.words(ccmd_create_object, obj_blend, &.{
        h_blend,       0,             0,
        blend_rt_word, blend_rt_word, blend_rt_word,
        blend_rt_word, blend_rt_word, blend_rt_word,
        blend_rt_word, blend_rt_word,
    });
    try c.words(ccmd_create_object, obj_rasterizer, &.{
        h_rasterizer, rasterizer_s0, f32_1, 0, 0, f32_1, 0, 0, 0,
    });
    try c.words(ccmd_create_object, obj_dsa, &.{
        h_dsa, 0, 0, 0, 0,
    });
    try emit_shader(&c, h_vshader, shader_vertex, vertex_shader_text);
    try emit_shader(&c, h_fshader, shader_fragment, fragment_shader_text);

    // --- binds ---
    try c.words(ccmd_bind_shader, 0, &.{ h_vshader, shader_vertex });
    try c.words(ccmd_bind_shader, 0, &.{ h_fshader, shader_fragment });
    try c.words(ccmd_bind_object, obj_blend, &.{h_blend});
    try c.words(ccmd_bind_object, obj_rasterizer, &.{h_rasterizer});
    try c.words(ccmd_bind_object, obj_dsa, &.{h_dsa});
    try c.words(ccmd_bind_object, obj_vertex_elements, &.{h_velements});

    // --- fixed render state ---
    const w2: u32 = @bitCast(@as(f32, @floatFromInt(spec.width)) / 2.0);
    const h2: u32 = @bitCast(@as(f32, @floatFromInt(spec.height)) / 2.0);
    try c.words(ccmd_set_framebuffer_state, 0, &.{
        1, // nr_cbufs
        0, // no depth/stencil surface
        h_surface,
    });
    try c.words(ccmd_set_viewport_state, 0, &.{
        0, // start slot
        w2, h2, f32_1, // scale  {w/2, h/2, 1}
        w2, h2, 0, //     translate {w/2, h/2, 0}
    });
    try c.words(ccmd_set_vertex_buffers, 0, &.{
        vbuf_vertex_len, // stride 32
        0, //             offset 0
        spec.res_vbo,
    });

    // --- clear + the one draw ---
    const depth: u64 = @bitCast(@as(f64, 1.0));
    try c.words(ccmd_clear, 0, &.{
        clear_color0,
        @bitCast(spec.clear[0]),
        @bitCast(spec.clear[1]),
        @bitCast(spec.clear[2]),
        @bitCast(spec.clear[3]),
        @truncate(depth),
        @truncate(depth >> 32),
        0, // stencil
    });
    // REVERT-FAILS SEAM (#2164): the pinned DRAW_VBO is the frame's only
    // geometry. Flipping `emit_draw` to false drops it — the exact-byte
    // and draw-count assertions go red while clear encoding stays green.
    if (emit_draw) {
        try c.words(ccmd_draw_vbo, 0, &.{
            0, //             start
            3, //             count — the pinned triangle
            prim_triangles, // mode
            0, //             non-indexed
            1, //             one instance
            0, 0, 0, 0, //    index bias, start instance, restart off/index
            0, 2, //          min/max index over the three vertices
            0, //             count_from_so — no stream-output draw
        });
    }

    // --- destroys, reverse creation order: object table back to baseline ---
    try c.words(ccmd_destroy_object, obj_shader, &.{h_fshader});
    try c.words(ccmd_destroy_object, obj_shader, &.{h_vshader});
    try c.words(ccmd_destroy_object, obj_dsa, &.{h_dsa});
    try c.words(ccmd_destroy_object, obj_rasterizer, &.{h_rasterizer});
    try c.words(ccmd_destroy_object, obj_blend, &.{h_blend});
    try c.words(ccmd_destroy_object, obj_vertex_elements, &.{h_velements});
    try c.words(ccmd_destroy_object, obj_surface, &.{h_surface});

    return c.at;
}

/// Pad a produced stream with NOP dwords (cmd 0, obj 0, len 0 — a zero
/// word that cannot mutate state or draw) out to `target` bytes.
/// `target` must be a multiple of 4, >= `used`, and within the
/// 4096-byte profile bound. This is the ONLY sanctioned way to reach
/// the limit fixture — never extra draws or invented commands.
pub fn pad_stream(out: []u8, used: usize, target: usize) Error!usize {
    if (target > max_stream_bytes or target > out.len or
        (target & 3) != 0 or target < used) return error.StreamTooBig;
    var at = used;
    while (at < target) : (at += 4) put32(out, at, 0);
    return target;
}

/// Walk a stream's command headers checking every declared payload
/// count stays inside the buffer — an over-declaring or truncated
/// stream is refused BEFORE submission, never passed to the device.
/// Returns the byte length consumed by whole commands (must equal
/// stream.len for a strict caller).
pub fn validate_stream(stream_bytes: []const u8) Error!usize {
    if ((stream_bytes.len & 3) != 0 or stream_bytes.len == 0) return error.BadStream;
    if (stream_bytes.len > max_stream_bytes) return error.StreamTooBig;
    var at: usize = 0;
    while (at < stream_bytes.len) {
        const h = std.mem.readInt(u32, stream_bytes[at..][0..4], .little);
        const len: usize = h >> 16;
        const advance = (len + 1) * 4;
        if (at + advance > stream_bytes.len) return error.BadStream;
        at += advance;
    }
    return at;
}

// ---------------------------------------------------------------------------
// The vertex buffer (resource upload payload — outside the stream)
// ---------------------------------------------------------------------------

/// The app-facing wire vertex (#2160 §5): i16 LE normalized x/y,
/// u16 LE normalized z, u16 LE RGB565 — exactly 8 bytes.
pub const WireVertex = struct {
    x: i16,
    y: i16,
    z: u16,
    rgb565: u16,
};

pub const vbuf_vertex_len: u32 = 32;
pub const vbuf_len: usize = 3 * vbuf_vertex_len; // 96

fn snorm16(v: i16) f32 {
    const f = @as(f32, @floatFromInt(v)) / 32767.0;
    return @max(-1.0, @min(1.0, f));
}

fn unorm16(v: u16) f32 {
    return @as(f32, @floatFromInt(v)) / 65535.0;
}

/// Convert the three 8-byte wire vertices into the pinned float4
/// position + float4 color layout (96 bytes total). Deterministic:
/// x/y are signed-normalized and clamped to [-1,1], z is unsigned
/// normalized [0,1], RGB565 channels expand to 0..1 floats, alpha is
/// always 1.0, position w is always 1.0.
pub fn encode_vertices(verts: *const [3]WireVertex, out: []u8) void {
    std.debug.assert(out.len >= vbuf_len);
    for (verts, 0..) |v, i| {
        const base = i * vbuf_vertex_len;
        const r = @as(f32, @floatFromInt((v.rgb565 >> 11) & 0x1f)) / 31.0;
        const g = @as(f32, @floatFromInt((v.rgb565 >> 5) & 0x3f)) / 63.0;
        const b = @as(f32, @floatFromInt(v.rgb565 & 0x1f)) / 31.0;
        const words = [8]u32{
            @bitCast(snorm16(v.x)), @bitCast(snorm16(v.y)),
            @bitCast(unorm16(v.z)), f32_1,
            @bitCast(r),            @bitCast(g),
            @bitCast(b),            f32_1,
        };
        for (words, 0..) |w, j| put32(out, base + j * 4, w);
    }
}

// ---------------------------------------------------------------------------
// Host tests — golden byte fixture, field tables, bounds, the
// revert-fails draw assertion.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fixture(path: []const u8, comptime cap: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(cap));
}

/// Parse the committed hex-words fixture (one `0x%08x` line per stream
/// word) into little-endian bytes.
fn parse_words(text: []const u8, out: []u8) !usize {
    var tokens = std.mem.tokenizeAny(u8, text, " \r\n\t");
    var n: usize = 0;
    while (tokens.next()) |tok| {
        if (tok.len != 10 or tok[0] != '0' or tok[1] != 'x') return error.BadFixture;
        const w = try std.fmt.parseInt(u32, tok[2..], 16);
        if (n + 4 > out.len) return error.FixtureTooLarge;
        std.mem.writeInt(u32, out[n..][0..4], w, .little);
        n += 4;
    }
    return n;
}

/// Structural decode of one command: returns cmd, object, payload slice
/// (dword view over the stream bytes).
const Decoded = struct { cmd: u32, obj: u32, payload: []const u32 };

fn next_cmd(stream_bytes: []const u8, at: *usize) ?Decoded {
    if (at.* >= stream_bytes.len) return null;
    const h = std.mem.readInt(u32, stream_bytes[at.*..][0..4], .little);
    const payload_words = h >> 16;
    const payload: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, stream_bytes[at.* + 4 .. at.* + 4 + payload_words * 4]));
    at.* += 4 + payload_words * 4;
    return .{ .cmd = h & 0xff, .obj = (h >> 8) & 0xff, .payload = payload };
}

test "gpu3d_stream: canonical stream is byte-exact against triangle.words" {
    var enc: [max_stream_bytes]u8 align(4) = undefined;
    const n = try encode_frame(&enc, canonical_spec);
    const golden_text = try fixture("test/fixtures/gpu3d/triangle.words", 16384);
    defer testing.allocator.free(golden_text);
    var golden: [max_stream_bytes]u8 = undefined;
    const glen = try parse_words(golden_text, &golden);
    try testing.expectEqual(n, glen);
    try testing.expectEqualSlices(u8, golden[0..glen], enc[0..n]);
    try testing.expectEqual(@as(usize, 660), n);
}

test "gpu3d_stream: field table pins counts, namespaces and shader texts" {
    var enc: [max_stream_bytes]u8 align(4) = undefined;
    const n = try encode_frame(&enc, canonical_spec);
    const s = enc[0..n];
    try testing.expectEqual(@as(usize, n), try validate_stream(s));
    var at: usize = 0;

    // 1. CREATE surface: handle 1, res 1, BGRA8, level 0, single layer.
    var d = next_cmd(s, &at).?;
    try testing.expectEqualSlices(u32, &.{ 1, 1, fmt_bgra8_unorm, 0, 0 }, d.payload);
    try testing.expectEqual(@as(u32, ccmd_create_object), d.cmd);
    try testing.expectEqual(@as(u32, obj_surface), d.obj);

    // 2. CREATE vertex-elements: stride-implicit offsets 0/16, buffer 0,
    //    both R32G32B32A32_FLOAT.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, obj_vertex_elements), d.obj);
    try testing.expectEqualSlices(u32, &.{ 2, 0, 0, 0, fmt_r32g32b32a32_float, 16, 0, 0, fmt_r32g32b32a32_float }, d.payload);

    // 3. CREATE blend: handle 3, all-rt word identical and disabled.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, obj_blend), d.obj);
    try testing.expectEqual(@as(usize, 11), d.payload.len);
    try testing.expectEqual(@as(u32, 3), d.payload[0]);
    for (d.payload[3..11]) |w| try testing.expectEqual(blend_rt_word, w);

    // 4. CREATE rasterizer: handle 4, pinned s0, point/line 1.0.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, obj_rasterizer), d.obj);
    try testing.expectEqualSlices(u32, &.{ 4, rasterizer_s0, f32_1, 0, 0, f32_1, 0, 0, 0 }, d.payload);

    // 5. CREATE dsa: handle 5, everything disabled.
    d = next_cmd(s, &at).?;
    try testing.expectEqualSlices(u32, &.{ 5, 0, 0, 0, 0 }, d.payload);

    // 6/7. CREATE shaders: header count, type, equal OFFSET/NUM_TOKENS,
    //    text region = literal + NUL + pad.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, obj_shader), d.obj);
    try testing.expectEqual(@as(usize, 5 + text_words(vertex_shader_text)), d.payload.len);
    try testing.expectEqualSlices(u32, &.{ 6, shader_vertex, @intCast(text_words(vertex_shader_text)), @intCast(text_words(vertex_shader_text)), 0 }, d.payload[0..5]);
    const vs_text_bytes = std.mem.sliceAsBytes(d.payload[5..]);
    try testing.expectEqual(@as(usize, text_words(vertex_shader_text) * 4), vs_text_bytes.len);
    try testing.expectEqualSlices(u8, vertex_shader_text, vs_text_bytes[0..vertex_shader_text.len]);
    try testing.expectEqual(@as(u8, 0), vs_text_bytes[vertex_shader_text.len]); // NUL terminator
    for (vs_text_bytes[vertex_shader_text.len..]) |b| try testing.expectEqual(@as(u8, 0), b);

    d = next_cmd(s, &at).?;
    try testing.expectEqualSlices(u32, &.{ 7, shader_fragment, @intCast(text_words(fragment_shader_text)), @intCast(text_words(fragment_shader_text)), 0 }, d.payload[0..5]);
    const fs_text_bytes = std.mem.sliceAsBytes(d.payload[5..]);
    try testing.expectEqualSlices(u8, fragment_shader_text, fs_text_bytes[0..fragment_shader_text.len]);
    for (fs_text_bytes[fragment_shader_text.len..]) |b| try testing.expectEqual(@as(u8, 0), b);

    // 8/9. BIND_SHADER vertex then fragment.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, ccmd_bind_shader), d.cmd);
    try testing.expectEqualSlices(u32, &.{ 6, shader_vertex }, d.payload);
    d = next_cmd(s, &at).?;
    try testing.expectEqualSlices(u32, &.{ 7, shader_fragment }, d.payload);

    // 10-13. BIND_OBJECT blend, rasterizer, dsa, vertex-elements.
    const bind_seq = [_]u32{ obj_blend, obj_rasterizer, obj_dsa, obj_vertex_elements };
    const bind_handles = [_]u32{ h_blend, h_rasterizer, h_dsa, h_velements };
    for (bind_seq, bind_handles) |obj, h| {
        d = next_cmd(s, &at).?;
        try testing.expectEqual(@as(u32, ccmd_bind_object), d.cmd);
        try testing.expectEqual(@as(u32, obj), d.obj);
        try testing.expectEqualSlices(u32, &.{h}, d.payload);
    }

    // 14. Framebuffer: one color attachment (surface 1), no depth.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, ccmd_set_framebuffer_state), d.cmd);
    try testing.expectEqualSlices(u32, &.{ 1, 0, 1 }, d.payload);

    // 15. Viewport: 256x192 convention — scale {128,96,1} translate {128,96,0}.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, ccmd_set_viewport_state), d.cmd);
    try testing.expectEqualSlices(u32, &.{ 0, 0x43000000, 0x42c00000, f32_1, 0x43000000, 0x42c00000, 0 }, d.payload);

    // 16. Vertex buffers: stride 32, offset 0, res 2.
    d = next_cmd(s, &at).?;
    try testing.expectEqualSlices(u32, &.{ 32, 0, 2 }, d.payload);

    // 17. CLEAR: color0, opaque black, depth 1.0, stencil 0.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, ccmd_clear), d.cmd);
    try testing.expectEqualSlices(u32, &.{ 1, 0, 0, 0, f32_1, 0, 0x3ff00000, 0 }, d.payload);

    // 18. DRAW_VBO: TRIANGLES start 0 count 3 one instance non-indexed.
    d = next_cmd(s, &at).?;
    try testing.expectEqual(@as(u32, ccmd_draw_vbo), d.cmd);
    try testing.expectEqualSlices(u32, &.{ 0, 3, prim_triangles, 0, 1, 0, 0, 0, 0, 0, 2, 0 }, d.payload);

    // 19-25. Destroys reverse the creation order; stream ends there.
    const dead = [_]struct { obj: u32, h: u32 }{
        .{ .obj = obj_shader, .h = 7 },  .{ .obj = obj_shader, .h = 6 },
        .{ .obj = obj_dsa, .h = 5 },     .{ .obj = obj_rasterizer, .h = 4 },
        .{ .obj = obj_blend, .h = 3 },   .{ .obj = obj_vertex_elements, .h = 2 },
        .{ .obj = obj_surface, .h = 1 },
    };
    for (dead) |e| {
        d = next_cmd(s, &at).?;
        try testing.expectEqual(@as(u32, ccmd_destroy_object), d.cmd);
        try testing.expectEqual(@as(u32, e.obj), d.obj);
        try testing.expectEqualSlices(u32, &.{e.h}, d.payload);
    }
    try testing.expectEqual(@as(?Decoded, null), next_cmd(s, &at));
}

test "gpu3d_stream: committed TGSI fixtures equal the emitted texts byte-for-byte" {
    const vs = try fixture("test/fixtures/gpu3d/vertex.tgsi", 4096);
    defer testing.allocator.free(vs);
    try testing.expectEqualSlices(u8, vertex_shader_text, vs);
    const fs = try fixture("test/fixtures/gpu3d/fragment.tgsi", 4096);
    defer testing.allocator.free(fs);
    try testing.expectEqualSlices(u8, fragment_shader_text, fs);
}

test "gpu3d_stream: vertex conversion is deterministic and byte-exact" {
    var vbuf: [vbuf_len]u8 align(4) = undefined;
    const verts = [3]WireVertex{
        .{ .x = -26214, .y = 26214, .z = 0, .rgb565 = 0xf800 }, // red
        .{ .x = 26214, .y = 26214, .z = 0, .rgb565 = 0x07e0 }, //  green
        .{ .x = 0, .y = -26214, .z = 65535, .rgb565 = 0x001f }, // blue
    };
    encode_vertices(&verts, &vbuf);
    const w = std.mem.bytesAsSlice(u32, &vbuf);
    // x = -26214/32767 ≈ -0.800024 (float bits below), y = +same, z = 0.
    const xf: u32 = @bitCast(@as(f32, @floatFromInt(@as(i32, -26214))) / 32767.0);
    const yf: u32 = @bitCast(@as(f32, @floatFromInt(@as(i32, 26214))) / 32767.0);
    const red: u32 = @bitCast(@as(f32, 31.0 / 31.0));
    const green: u32 = @bitCast(@as(f32, 63.0 / 63.0));
    const blue: u32 = @bitCast(@as(f32, 31.0 / 31.0));
    try testing.expectEqualSlices(u32, &.{
        xf, yf, 0,     f32_1, red, 0,     0,    f32_1,
        yf, yf, 0,     f32_1, 0,   green, 0,    f32_1,
        0,  xf, f32_1, f32_1, 0,   0,     blue, f32_1,
    }, w);
    // i16 -32768 clamps to exactly -1.0; u16 65535 is exactly 1.0.
    const edge = [3]WireVertex{
        .{ .x = -32768, .y = 32767, .z = 65535, .rgb565 = 0xffff },
        .{ .x = 0, .y = 0, .z = 0, .rgb565 = 0 },
        .{ .x = 0, .y = 0, .z = 0, .rgb565 = 0 },
    };
    encode_vertices(&edge, &vbuf);
    const ew = std.mem.bytesAsSlice(u32, &vbuf);
    try testing.expectEqual(@as(u32, 0xbf800000), ew[0]); // -1.0
    try testing.expectEqual(@as(u32, f32_1), ew[2]); //      z = 1.0
}

test "gpu3d_stream: geometry and staging bounds refuse before any bytes" {
    var enc: [max_stream_bytes]u8 align(4) = undefined;
    try testing.expectError(error.BadGeometry, encode_frame(&enc, .{ .width = 0, .height = 192, .clear = .{ 0, 0, 0, 1 }, .res_color = 1, .res_vbo = 2 }));
    try testing.expectError(error.BadGeometry, encode_frame(&enc, .{ .width = 257, .height = 192, .clear = .{ 0, 0, 0, 1 }, .res_color = 1, .res_vbo = 2 }));
    try testing.expectError(error.BadGeometry, encode_frame(&enc, .{ .width = 256, .height = 0, .clear = .{ 0, 0, 0, 1 }, .res_color = 1, .res_vbo = 2 }));
    try testing.expectError(error.BadGeometry, encode_frame(&enc, .{ .width = 256, .height = 193, .clear = .{ 0, 0, 0, 1 }, .res_color = 1, .res_vbo = 2 }));
    // A smaller in-profile extent still encodes and validates.
    const n = try encode_frame(&enc, .{ .width = 64, .height = 48, .clear = .{ 1, 0, 0, 1 }, .res_color = 3, .res_vbo = 4 });
    try testing.expectEqual(@as(usize, n), try validate_stream(enc[0..n]));
    // A too-small output buffer refuses by name.
    var tiny: [64]u8 = undefined;
    try testing.expectError(error.StreamTooBig, encode_frame(&tiny, canonical_spec));
}

test "gpu3d_stream: NOP padding reaches the cap; over-cap and misalignment refuse" {
    var enc: [max_stream_bytes]u8 align(4) = undefined;
    const n = try encode_frame(&enc, canonical_spec);
    // Pad the canonical stream to the exact 4096-byte bound.
    const end = try pad_stream(&enc, n, 4096);
    try testing.expectEqual(@as(usize, 4096), end);
    try testing.expectEqual(@as(usize, 4096), try validate_stream(enc[0..end]));
    // The pad words are all zero NOPs — no commands, no state, no draw.
    for (enc[n..end]) |b| try testing.expectEqual(@as(u8, 0), b);
    // Over-cap, misaligned, below-used and too-small targets refuse.
    try testing.expectError(error.StreamTooBig, pad_stream(&enc, n, 4100));
    try testing.expectError(error.StreamTooBig, pad_stream(&enc, n, 4097));
    try testing.expectError(error.StreamTooBig, pad_stream(&enc, n, 4098));
    try testing.expectError(error.StreamTooBig, pad_stream(&enc, n, n - 4));
    var small: [128]u8 = undefined;
    try testing.expectError(error.StreamTooBig, pad_stream(&small, 64, 4096));
}

test "gpu3d_stream: validate_stream refuses over-declared and truncated commands" {
    var enc: [max_stream_bytes]u8 align(4) = undefined;
    const n = try encode_frame(&enc, canonical_spec);
    try testing.expectEqual(@as(usize, n), try validate_stream(enc[0..n]));
    // Truncated streams refuse at the cut point, whatever the cut.
    try testing.expectError(error.BadStream, validate_stream(enc[0 .. n - 4]));
    try testing.expectError(error.BadStream, validate_stream(enc[0..13]));
    // A header whose count over-declares the buffer refuses.
    var bogus: [8]u8 = @splat(0);
    std.mem.writeInt(u32, bogus[0..4], cmd0(ccmd_clear, 0, 8), .little);
    try testing.expectError(error.BadStream, validate_stream(&bogus));
    // Empty and unaligned streams refuse; a stream past the 4096-byte
    // profile bound refuses by name.
    try testing.expectError(error.BadStream, validate_stream(&.{}));
    try testing.expectError(error.BadStream, validate_stream(enc[0 .. n - 1]));
    var big: [4100]u8 = @splat(0);
    try testing.expectError(error.StreamTooBig, validate_stream(&big));
}

test "gpu3d_stream: exactly one DRAW_VBO with the pinned fields (revert-fails target)" {
    var enc: [max_stream_bytes]u8 align(4) = undefined;
    const n = try encode_frame(&enc, canonical_spec);
    var at: usize = 0;
    var draws: usize = 0;
    while (next_cmd(enc[0..n], &at)) |d| {
        if (d.cmd == ccmd_draw_vbo) {
            draws += 1;
            try testing.expectEqual(@as(u32, 0), d.obj);
            try testing.expectEqual(@as(usize, 12), d.payload.len);
            try testing.expectEqual(@as(u32, 0), d.payload[0]); // start
            try testing.expectEqual(@as(u32, 3), d.payload[1]); // count
            try testing.expectEqual(@as(u32, prim_triangles), d.payload[2]);
            try testing.expectEqual(@as(u32, 0), d.payload[3]); // non-indexed
            try testing.expectEqual(@as(u32, 1), d.payload[4]); // one instance
        }
    }
    try testing.expectEqual(@as(usize, 1), draws);
    // A stream that emits no DRAW_VBO fails this assertion while the
    // clear-encoding control below stays green.
}

test "gpu3d_stream: clear encoding control stays green independently" {
    var enc: [max_stream_bytes]u8 align(4) = undefined;
    const spec: FrameSpec = .{ .width = 256, .height = 192, .clear = .{ 0.25, 0.5, 0.75, 1.0 }, .res_color = 1, .res_vbo = 2 };
    const n = try encode_frame(&enc, spec);
    var at: usize = 0;
    var clears: usize = 0;
    while (next_cmd(enc[0..n], &at)) |d| {
        if (d.cmd == ccmd_clear) {
            clears += 1;
            const r: u32 = @bitCast(@as(f32, 0.25));
            const g: u32 = @bitCast(@as(f32, 0.5));
            const b: u32 = @bitCast(@as(f32, 0.75));
            try testing.expectEqualSlices(u32, &.{ 1, r, g, b, f32_1, 0, 0x3ff00000, 0 }, d.payload);
        }
    }
    try testing.expectEqual(@as(usize, 1), clears);
}
