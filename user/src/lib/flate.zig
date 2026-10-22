//! VirelaiOS Freestanding RFC 1951 DEFLATE & RFC 1950 Zlib Inflator.
//!
//! Milestone 23 / Issue #823 (IMG2).
//! Pure freestanding Zig decompressor with zero heap allocation.
//! Decompresses raw DEFLATE or zlib-wrapped streams into a caller-provided buffer.

const std = @import("std");

pub const InflateError = error{
    InvalidBlockType, // BTYPE == 11
    InvalidHuffmanTree, // corrupt code length alphabet or tree structure
    InvalidDistance, // distance code exceeds output extent
    InvalidZlibHeader, // CMF/FLG mismatch or unsupported options (zlib mode only)
    Adler32Mismatch, // checksum mismatch (zlib mode only)
    CorruptStream, // truncated input, invalid symbols, or premature stream end
    BufferTooSmall, // output buffer overflow
};

pub const LENGTH_BASE = [_]u16{
    3,  4,  5,  6,  7,  8,  9,  10,  11,  13,  15,  17,  19,  23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
};

pub const LENGTH_EXTRA_BITS = [_]u4{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
};

pub const DIST_BASE = [_]u16{
    1,   2,   3,   4,   5,    7,    9,    13,   17,   25,   33,   49,    65,    97,    129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};

pub const DIST_EXTRA_BITS = [_]u4{
    0, 0, 0, 0, 1, 1, 2,  2,  3,  3,  4,  4,  5,  5,  6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

pub const CODE_LENGTH_ORDER = [_]u5{
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
};

pub const BitReader = struct {
    bytes: []const u8,
    byte_pos: usize = 0,
    bit_buf: u64 = 0,
    bit_count: u6 = 0,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    pub fn read_bit(self: *BitReader) InflateError!u1 {
        while (self.bit_count < 1) {
            if (self.byte_pos >= self.bytes.len) return error.CorruptStream;
            self.bit_buf |= @as(u64, self.bytes[self.byte_pos]) << self.bit_count;
            self.byte_pos += 1;
            self.bit_count += 8;
        }
        const bit: u1 = @truncate(self.bit_buf & 1);
        self.bit_buf >>= 1;
        self.bit_count -= 1;
        return bit;
    }

    pub fn read_bits(self: *BitReader, comptime count: u6) InflateError!u32 {
        if (count == 0) return 0;
        while (self.bit_count < count) {
            if (self.byte_pos >= self.bytes.len) return error.CorruptStream;
            self.bit_buf |= @as(u64, self.bytes[self.byte_pos]) << self.bit_count;
            self.byte_pos += 1;
            self.bit_count += 8;
        }
        const mask: u64 = (@as(u64, 1) << count) - 1;
        const val: u32 = @truncate(self.bit_buf & mask);
        self.bit_buf >>= count;
        self.bit_count -= count;
        return val;
    }

    pub fn read_bits_var(self: *BitReader, count: u6) InflateError!u32 {
        if (count == 0) return 0;
        while (self.bit_count < count) {
            if (self.byte_pos >= self.bytes.len) return error.CorruptStream;
            self.bit_buf |= @as(u64, self.bytes[self.byte_pos]) << self.bit_count;
            self.byte_pos += 1;
            self.bit_count += 8;
        }
        const mask: u64 = (@as(u64, 1) << count) - 1;
        const val: u32 = @truncate(self.bit_buf & mask);
        self.bit_buf >>= count;
        self.bit_count -= count;
        return val;
    }

    pub fn align_to_byte(self: *BitReader) void {
        const discard = self.bit_count % 8;
        self.bit_buf >>= @intCast(discard);
        self.bit_count -= discard;
    }

    pub fn read_u16_le(self: *BitReader) InflateError!u16 {
        self.align_to_byte();
        const low = try self.read_bits(8);
        const high = try self.read_bits(8);
        return @intCast(low | (high << 8));
    }
};

pub const HuffmanTree = struct {
    bl_count: [16]u16 = @as([16]u16, @splat(@as(u16, 0))),
    first_code: [16]u16 = @as([16]u16, @splat(@as(u16, 0))),
    start_idx: [16]u16 = @as([16]u16, @splat(@as(u16, 0))),
    symbols: [288]u16 = @as([288]u16, @splat(@as(u16, 0))),

    pub fn build(self: *HuffmanTree, lengths: []const u8) InflateError!void {
        if (lengths.len > self.symbols.len) return error.InvalidHuffmanTree;
        self.bl_count = @as([16]u16, @splat(@as(u16, 0)));
        for (lengths) |len| {
            if (len > 15) return error.InvalidHuffmanTree;
            if (len > 0) self.bl_count[len] += 1;
        }

        // Check if tree is valid: the Kraft inequality — sum of
        // 2^(15-len) <= 2^15, counted as the code space left at each
        // depth. An oversubscribed tree cannot decode. RFC 1951 permits
        // only the empty distance alphabet and a single one-bit code as
        // INCOMPLETE trees; anything else is refused here too (the same
        // boundary the Go port at user/go/flate holds).
        var left: i32 = 1;
        var max_bits: usize = 0;
        var depth: usize = 1;
        while (depth <= 15) : (depth += 1) {
            left = left * 2 - @as(i32, self.bl_count[depth]);
            if (left < 0) return error.InvalidHuffmanTree;
            if (self.bl_count[depth] != 0) max_bits = depth;
        }
        if (left != 0 and max_bits > 1) return error.InvalidHuffmanTree;

        var code: u16 = 0;
        var bits: usize = 1;
        while (bits <= 15) : (bits += 1) {
            code = (code + self.bl_count[bits - 1]) << 1;
            self.first_code[bits] = code;
        }

        // Compute start_idx for each bit length
        var total: u16 = 0;
        bits = 1;
        while (bits <= 15) : (bits += 1) {
            self.start_idx[bits] = total;
            total += self.bl_count[bits];
        }

        // Assign symbols
        var offsets = self.start_idx;
        for (lengths, 0..) |len, sym| {
            if (len > 0) {
                const off = offsets[len];
                offsets[len] += 1;
                self.symbols[off] = @intCast(sym);
            }
        }
    }

    pub fn decode_symbol(self: *const HuffmanTree, reader: *BitReader) InflateError!u16 {
        var cur_code: u16 = 0;
        var len: u8 = 1;
        while (len <= 15) : (len += 1) {
            const bit = try reader.read_bit();
            cur_code = (cur_code << 1) | bit;
            const count = self.bl_count[len];
            if (count > 0) {
                const first = self.first_code[len];
                if (cur_code >= first and cur_code < first + count) {
                    const idx = self.start_idx[len] + (cur_code - first);
                    return self.symbols[idx];
                }
            }
        }
        return error.InvalidHuffmanTree;
    }
};

/// Calculate RFC 1950 Adler-32 checksum.
pub fn calc_adler32(data: []const u8) u32 {
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (data) |b| {
        s1 = (s1 + b) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    return (s2 << 16) | s1;
}

/// Freestanding RFC 1951 DEFLATE inflator.
/// If `raw` is false, expects an RFC 1950 zlib container (CMF/FLG header + Adler-32 trailer).
/// If `raw` is true, processes raw DEFLATE stream directly.
/// Returns the total decompressed bytes written to `out_buf`.
pub fn inflate(in_bytes: []const u8, out_buf: []u8, raw: bool) InflateError!usize {
    var in_slice = in_bytes;
    var expected_adler: ?u32 = null;

    if (!raw) {
        if (in_slice.len < 6) return error.CorruptStream; // 2 header + at least 4 adler
        const cmf = in_slice[0];
        const flg = in_slice[1];

        // CM must be 8 (DEFLATE), CINFO <= 7 (32K window)
        const cm = cmf & 0x0F;
        const cinfo = (cmf >> 4) & 0x0F;
        if (cm != 8 or cinfo > 7) return error.InvalidZlibHeader;

        // FCHECK verification: (CMF * 256 + FLG) % 31 == 0
        const header_check: u32 = (@as(u32, cmf) << 8) | @as(u32, flg);
        if (header_check % 31 != 0) return error.InvalidZlibHeader;

        // FDICT not supported
        if ((flg & 0x20) != 0) return error.InvalidZlibHeader;

        // Extract Adler-32 from the end of the slice (4 bytes big-endian)
        const adler_bytes = in_slice[in_slice.len - 4 ..];
        expected_adler = std.mem.readInt(u32, adler_bytes[0..4], .big);

        in_slice = in_slice[2 .. in_slice.len - 4];
    }

    var reader = BitReader.init(in_slice);
    var out_pos: usize = 0;

    var fixed_lit_tree: ?HuffmanTree = null;
    var fixed_dist_tree: ?HuffmanTree = null;

    var is_final: bool = false;
    while (!is_final) {
        is_final = (try reader.read_bit()) == 1;
        const btype = try reader.read_bits(2);

        if (btype == 0b00) { // Non-compressed
            reader.align_to_byte();
            const len = try reader.read_u16_le();
            const nlen = try reader.read_u16_le();
            if (len != (~nlen & 0xFFFF)) return error.CorruptStream;

            if (out_pos + len > out_buf.len) return error.BufferTooSmall;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                out_buf[out_pos] = @truncate(try reader.read_bits(8));
                out_pos += 1;
            }
        } else if (btype == 0b01) { // Fixed Huffman
            if (fixed_lit_tree == null) {
                var lit_lens: [288]u8 = undefined;
                for (0..144) |sym| lit_lens[sym] = 8;
                for (144..256) |sym| lit_lens[sym] = 9;
                for (256..280) |sym| lit_lens[sym] = 7;
                for (280..288) |sym| lit_lens[sym] = 8;
                var tree = HuffmanTree{};
                try tree.build(&lit_lens);
                fixed_lit_tree = tree;

                var dist_lens = @as([32]u8, @splat(@as(u8, 5)));
                var dtree = HuffmanTree{};
                try dtree.build(&dist_lens);
                fixed_dist_tree = dtree;
            }

            try decode_block(&reader, &fixed_lit_tree.?, &fixed_dist_tree.?, out_buf, &out_pos);
        } else if (btype == 0b10) { // Dynamic Huffman
            const hlit = (try reader.read_bits(5)) + 257; // 257..288 on the wire
            if (hlit > 286) return error.InvalidHuffmanTree; // RFC 1951 §3.2.7 caps HLIT at 286
            const hdist = (try reader.read_bits(5)) + 1; // 1..32 on the wire
            if (hdist > 30) return error.InvalidHuffmanTree; // the distance alphabet is 30 codes
            const hclen = (try reader.read_bits(4)) + 4; // 4..19

            var code_len_lens = @as([19]u8, @splat(@as(u8, 0)));
            var i: usize = 0;
            while (i < hclen) : (i += 1) {
                code_len_lens[CODE_LENGTH_ORDER[i]] = @truncate(try reader.read_bits(3));
            }

            var cl_tree = HuffmanTree{};
            try cl_tree.build(&code_len_lens);

            var full_lens: [288 + 32]u8 = undefined;
            const total_codes = hlit + hdist;
            var code_idx: usize = 0;

            while (code_idx < total_codes) {
                const sym = try cl_tree.decode_symbol(&reader);
                if (sym < 16) {
                    full_lens[code_idx] = @truncate(sym);
                    code_idx += 1;
                } else if (sym == 16) {
                    if (code_idx == 0) return error.InvalidHuffmanTree;
                    const prev_val = full_lens[code_idx - 1];
                    const repeat = (try reader.read_bits(2)) + 3;
                    if (code_idx + repeat > total_codes) return error.InvalidHuffmanTree;
                    for (0..repeat) |_| {
                        full_lens[code_idx] = prev_val;
                        code_idx += 1;
                    }
                } else if (sym == 17) {
                    const repeat = (try reader.read_bits(3)) + 3;
                    if (code_idx + repeat > total_codes) return error.InvalidHuffmanTree;
                    for (0..repeat) |_| {
                        full_lens[code_idx] = 0;
                        code_idx += 1;
                    }
                } else if (sym == 18) {
                    const repeat = (try reader.read_bits(7)) + 11;
                    if (code_idx + repeat > total_codes) return error.InvalidHuffmanTree;
                    for (0..repeat) |_| {
                        full_lens[code_idx] = 0;
                        code_idx += 1;
                    }
                } else {
                    return error.InvalidHuffmanTree;
                }
            }

            var dyn_lit_tree = HuffmanTree{};
            // A block whose literal tree has no end-of-block code (256)
            // can never terminate — refuse at the header, not mid-decode.
            if (full_lens[256] == 0) return error.InvalidHuffmanTree;
            try dyn_lit_tree.build(full_lens[0..hlit]);

            var dyn_dist_tree = HuffmanTree{};
            try dyn_dist_tree.build(full_lens[hlit .. hlit + hdist]);

            try decode_block(&reader, &dyn_lit_tree, &dyn_dist_tree, out_buf, &out_pos);
        } else {
            return error.InvalidBlockType;
        }
    }

    if (expected_adler) |adler| {
        const computed = calc_adler32(out_buf[0..out_pos]);
        if (computed != adler) return error.Adler32Mismatch;
    }

    return out_pos;
}

fn decode_block(
    reader: *BitReader,
    lit_tree: *const HuffmanTree,
    dist_tree: *const HuffmanTree,
    out_buf: []u8,
    out_pos: *usize,
) InflateError!void {
    while (true) {
        const sym = try lit_tree.decode_symbol(reader);
        if (sym < 256) {
            if (out_pos.* >= out_buf.len) return error.BufferTooSmall;
            out_buf[out_pos.*] = @truncate(sym);
            out_pos.* += 1;
        } else if (sym == 256) {
            // End of block
            break;
        } else if (sym <= 285) {
            const len_code = sym - 257;
            const extra_bits = LENGTH_EXTRA_BITS[len_code];
            const extra_val = try reader.read_bits_var(extra_bits);
            const match_len = LENGTH_BASE[len_code] + extra_val;

            const dist_sym = try dist_tree.decode_symbol(reader);
            if (dist_sym >= 30) return error.CorruptStream;
            const dist_extra_bits = DIST_EXTRA_BITS[dist_sym];
            const dist_extra_val = try reader.read_bits_var(dist_extra_bits);
            const distance = DIST_BASE[dist_sym] + dist_extra_val;

            if (distance > out_pos.*) return error.InvalidDistance;
            if (out_pos.* + match_len > out_buf.len) return error.BufferTooSmall;

            // Byte-by-byte copy handles overlapping source and destination (e.g. RLE runs)
            var src_idx = out_pos.* - distance;
            var i: usize = 0;
            while (i < match_len) : (i += 1) {
                out_buf[out_pos.*] = out_buf[src_idx];
                out_pos.* += 1;
                src_idx += 1;
            }
        } else {
            return error.CorruptStream;
        }
    }
}

// ---------------------------------------------------------------------------
// Host Unit Tests
// ---------------------------------------------------------------------------

test "flate: uncompressed block" {
    const fixture_bytes = @embedFile("fixtures/deflate/uncompressed.bin");
    var out: [64]u8 = undefined;
    const len = try inflate(fixture_bytes, &out, true);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("Hello", out[0..len]);
}

test "flate: zlib wrapped hello" {
    const fixture_bytes = @embedFile("fixtures/zlib/hello.zlib");
    var out: [128]u8 = undefined;
    const len = try inflate(fixture_bytes, &out, false);
    try std.testing.expectEqualStrings("Hello VirelaiOS! Decompress me with flate.", out[0..len]);
}

test "flate: raw deflate hello" {
    const fixture_bytes = @embedFile("fixtures/deflate/hello_raw.bin");
    var out: [128]u8 = undefined;
    const len = try inflate(fixture_bytes, &out, true);
    try std.testing.expectEqualStrings("Hello VirelaiOS! Decompress me with flate.", out[0..len]);
}

test "flate: zlib large repetitive dynamic Huffman and LZ77" {
    const fixture_bytes = @embedFile("fixtures/zlib/large.zlib");
    var out: [2048]u8 = undefined;
    const len = try inflate(fixture_bytes, &out, false);

    const unit = "The quick brown fox jumps over the lazy dog. 0123456789! ";
    try std.testing.expectEqual(unit.len * 20, len);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try std.testing.expectEqualStrings(unit, out[i * unit.len .. (i + 1) * unit.len]);
    }
}

test "flate: buffer too small rejection" {
    const fixture_bytes = @embedFile("fixtures/zlib/hello.zlib");
    var small_buf: [10]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, inflate(fixture_bytes, &small_buf, false));
}

test "flate: invalid zlib header and adler mismatch" {
    var bad_header = [_]u8{ 0x78, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var out: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidZlibHeader, inflate(&bad_header, &out, false));

    const fixture_bytes = @embedFile("fixtures/zlib/hello.zlib");
    var corrupt_adler: [fixture_bytes.len]u8 = undefined;
    @memcpy(&corrupt_adler, fixture_bytes);
    corrupt_adler[corrupt_adler.len - 1] ^= 0xFF; // Corrupt trailer
    try std.testing.expectError(error.Adler32Mismatch, inflate(&corrupt_adler, &out, false));
}

test "flate: dynamic header bounds — HLIT > 286 and HDIST > 30 refuse" {
    var out: [128]u8 = undefined;
    // BFINAL=1, BTYPE=10 (dynamic); the field carries HLIT-257, so a
    // wire value of 30 declares 287 literals — past the RFC's 286 cap.
    const too_many_lits = [_]u8{0xf5};
    try std.testing.expectError(error.InvalidHuffmanTree, inflate(&too_many_lits, &out, true));
    // HLIT=0 (257 lits), HDIST=31 on the wire -> 32 distances.
    const too_many_dists = [_]u8{ 0x05, 0x1f };
    try std.testing.expectError(error.InvalidHuffmanTree, inflate(&too_many_dists, &out, true));
}

test "flate: oversubscribed code-length tree refuses" {
    var out: [128]u8 = undefined;
    // Dynamic block; three code-length codes (16/17/18) all length 1 —
    // the alphabet oversubscribes the 1-bit code space.
    const oversub = [_]u8{ 0x05, 0x00, 0x92, 0x00 };
    try std.testing.expectError(error.InvalidHuffmanTree, inflate(&oversub, &out, true));
}

test "flate: dynamic block with no end-of-block code refuses" {
    var out: [128]u8 = undefined;
    // A single-code CL alphabet (symbol 18) fills all 258 declared
    // lengths with zero — literal tree legal (empty alphabet rules do
    // not apply to literals) but symbol 256 has no code.
    const no_eob = [_]u8{ 0x05, 0x00, 0x80, 0xc0, 0x5f, 0x1b };
    try std.testing.expectError(error.InvalidHuffmanTree, inflate(&no_eob, &out, true));
}
