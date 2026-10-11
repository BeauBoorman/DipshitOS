//! M51 SSH1 (#1168, ADR 0025 D2/D6): the SSH wire codec (RFC 4251 §5).
//!
//! The SSH-2 data types are all big-endian and length-prefixed:
//!   * `byte`      — one octet;
//!   * `boolean`   — one octet, 0 = false, 1 = true (anything else is
//!                   malformed; we fail closed, RFC 4251 §5);
//!   * `uint32` / `uint64` — big-endian unsigned;
//!   * `string`    — uint32 length + that many octets;
//!   * `mpint`     — a `string` holding a two's-complement bignum, minimal;
//!   * `name-list` — a `string` holding comma-separated ASCII names.
//!
//! The codec never allocates: a `Reader` walks a caller-owned slice and a
//! `Writer` fills one, both bounds-checked. The kernel stays out of this
//! entirely (ADR 0023 D2) — it is pure userland assembly work over bytes.

const std = @import("std");

pub const Error = error{
    /// Not enough bytes left for the requested field.
    ShortRead,
    /// The destination slice cannot hold the requested field.
    Overflow,
    /// A `boolean` octet other than 0 or 1.
    BadBool,
    /// A name-list with an empty member (e.g. a leading/trailing comma).
    BadName,
};

/// Read side: a bounds-checked cursor over a byte slice.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.pos;
    }

    pub fn readByte(self: *Reader) Error!u8 {
        if (self.pos >= self.bytes.len) return error.ShortRead;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    /// RFC 4251 §5: a boolean is a single octet, 0 or 1.
    pub fn readBool(self: *Reader) Error!bool {
        const b = try self.readByte();
        return switch (b) {
            0 => false,
            1 => true,
            else => error.BadBool,
        };
    }

    pub fn readUint32(self: *Reader) Error!u32 {
        if (self.remaining() < 4) return error.ShortRead;
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    pub fn readUint64(self: *Reader) Error!u64 {
        if (self.remaining() < 8) return error.ShortRead;
        const v = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    /// A `string`: uint32 length then that many octets. The returned slice
    /// borrows `self.bytes`.
    pub fn readString(self: *Reader) Error![]const u8 {
        const n = try self.readUint32();
        if (n > self.remaining()) return error.ShortRead;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// An `mpint` as its raw two's-complement octets (borrowed).
    pub fn readMpint(self: *Reader) Error![]const u8 {
        return self.readString();
    }

    /// Decode an `mpint` into a signed integer of type `T`, failing closed
    /// on an over-wide or non-minimal encoding. Zero is the empty string.
    pub fn readMpintInt(self: *Reader, comptime T: type) Error!T {
        const info = @typeInfo(T);
        if (info != .int or info.int.signedness != .signed) @compileError("readMpintInt wants a signed integer");
        const raw = try self.readMpint();
        if (raw.len == 0) return 0;
        if (raw.len > @sizeOf(T)) return error.Overflow;
        // Minimality: a leading 0x00 is only allowed as a positive sign pad
        // (next high bit set); a leading 0xff only as a negative sign pad
        // (next high bit clear). Anything else is overlong.
        if (raw.len > 1) {
            if (raw[0] == 0x00 and (raw[1] & 0x80) == 0) return error.Overflow;
            if (raw[0] == 0xff and (raw[1] & 0x80) != 0) return error.Overflow;
        }
        const UT = @Int(.unsigned, info.int.bits);
        var buf: [@sizeOf(T)]u8 = undefined;
        // Sign-extend the (<= sizeof(T)) raw bytes into the full width.
        const fill: u8 = if ((raw[0] & 0x80) != 0) 0xff else 0x00;
        @memset(&buf, fill);
        @memcpy(buf[buf.len - raw.len ..], raw);
        const uv = std.mem.readInt(UT, &buf, .big);
        return @bitCast(uv);
    }

    /// A `name-list` as its raw comma-separated `string` payload (borrowed).
    /// Use `names()` to iterate and validate the members.
    pub fn readNameList(self: *Reader) Error![]const u8 {
        return self.readString();
    }
};

/// An iterator over a `name-list` payload. Rejects empty members (a stray
/// comma) so a malformed list fails closed rather than yielding "".
pub const NameListIter = struct {
    list: []const u8,
    pos: usize = 0,
    done: bool = false,

    pub fn next(self: *NameListIter) Error!?[]const u8 {
        if (self.done) return null;
        if (self.list.len == 0) {
            self.done = true;
            return null;
        }
        if (self.pos >= self.list.len) {
            // We only arrive here after the final member without a trailing
            // comma sets done — so this is a trailing comma.
            return error.BadName;
        }
        if (std.mem.indexOfScalarPos(u8, self.list, self.pos, ',')) |comma| {
            const name = self.list[self.pos..comma];
            if (name.len == 0) return error.BadName;
            self.pos = comma + 1;
            return name;
        }
        const name = self.list[self.pos..];
        if (name.len == 0) return error.BadName;
        self.done = true;
        return name;
    }
};

pub fn names(list: []const u8) NameListIter {
    return .{ .list = list };
}

/// Write side: a bounds-checked cursor that fills a caller-owned slice.
pub const Writer = struct {
    bytes: []u8,
    pos: usize = 0,

    pub fn init(bytes: []u8) Writer {
        return .{ .bytes = bytes };
    }

    pub fn written(self: *const Writer) []u8 {
        return self.bytes[0..self.pos];
    }

    fn put(self: *Writer, b: u8) Error!void {
        if (self.pos >= self.bytes.len) return error.Overflow;
        self.bytes[self.pos] = b;
        self.pos += 1;
    }

    pub fn writeByte(self: *Writer, v: u8) Error!void {
        try self.put(v);
    }

    pub fn writeBool(self: *Writer, v: bool) Error!void {
        try self.put(@intFromBool(v));
    }

    pub fn writeUint32(self: *Writer, v: u32) Error!void {
        if (self.bytes.len - self.pos < 4) return error.Overflow;
        std.mem.writeInt(u32, self.bytes[self.pos..][0..4], v, .big);
        self.pos += 4;
    }

    pub fn writeUint64(self: *Writer, v: u64) Error!void {
        if (self.bytes.len - self.pos < 8) return error.Overflow;
        std.mem.writeInt(u64, self.bytes[self.pos..][0..8], v, .big);
        self.pos += 8;
    }

    /// A `string`: uint32 length then the octets.
    pub fn writeString(self: *Writer, s: []const u8) Error!void {
        if (s.len > std.math.maxInt(u32)) return error.Overflow;
        try self.writeUint32(@intCast(s.len));
        if (self.bytes.len - self.pos < s.len) return error.Overflow;
        @memcpy(self.bytes[self.pos .. self.pos + s.len], s);
        self.pos += s.len;
    }

    /// A minimal two's-complement `mpint` from a signed integer. Zero is
    /// the empty string; a positive value whose top bit is set gains a
    /// leading 0x00; a negative value gets 0xff sign extension only when
    /// required.
    pub fn writeMpint(self: *Writer, value: anytype) Error!void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (info != .int or info.int.signedness != .signed) @compileError("writeMpint wants a signed integer");
        if (value == 0) return self.writeString(&.{});
        const UT = @Int(.unsigned, info.int.bits);
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(UT, &tmp, @bitCast(value), .big);
        var start: usize = 0;
        if (value < 0) {
            while (start + 1 < tmp.len and tmp[start] == 0xff and (tmp[start + 1] & 0x80) != 0) start += 1;
        } else {
            while (start + 1 < tmp.len and tmp[start] == 0x00 and (tmp[start + 1] & 0x80) == 0) start += 1;
        }
        return self.writeString(tmp[start..]);
    }

    /// A raw `mpint` from already-encoded octets (no re-encoding).
    pub fn writeMpintBytes(self: *Writer, raw: []const u8) Error!void {
        return self.writeString(raw);
    }

    /// A `name-list` from validated member names.
    pub fn writeNameList(self: *Writer, list: []const []const u8) Error!void {
        var total: usize = 0;
        for (list, 0..) |n, i| {
            if (n.len == 0) return error.BadName;
            if (std.mem.indexOfScalar(u8, n, ',') != null) return error.BadName;
            total += n.len;
            if (i != 0) total += 1;
        }
        try self.writeUint32(@intCast(total));
        for (list, 0..) |n, i| {
            if (i != 0) try self.put(',');
            if (self.bytes.len - self.pos < n.len) return error.Overflow;
            @memcpy(self.bytes[self.pos .. self.pos + n.len], n);
            self.pos += n.len;
        }
    }
};

// ---------------------------------------------------------------------------
// Host tests (class A; pure, no syscalls)
// ---------------------------------------------------------------------------

test "wire: byte/bool/uint32/uint64 round-trip" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeByte(0x7f);
    try w.writeBool(true);
    try w.writeBool(false);
    try w.writeUint32(0xdeadbeef);
    try w.writeUint64(0x0102030405060708);
    var r = Reader.init(w.written());
    try std.testing.expectEqual(@as(u8, 0x7f), try r.readByte());
    try std.testing.expectEqual(true, try r.readBool());
    try std.testing.expectEqual(false, try r.readBool());
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), try r.readUint32());
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), try r.readUint64());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "wire: string round-trip (including empty)" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeString("");
    try w.writeString("ssh-ed25519");
    try w.writeString("curve25519-sha256");
    var r = Reader.init(w.written());
    try std.testing.expectEqualStrings("", try r.readString());
    try std.testing.expectEqualStrings("ssh-ed25519", try r.readString());
    try std.testing.expectEqualStrings("curve25519-sha256", try r.readString());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "wire: mpint round-trip of signed values" {
    const cases = [_]i64{ 0, 1, -1, 127, 128, -128, -129, 255, 256, -256, 0x7fffffff, -0x80000000, 0x123456789abcdef };
    for (cases) |v| {
        var buf: [32]u8 = undefined;
        var w = Writer.init(&buf);
        try w.writeMpint(v);
        var r = Reader.init(w.written());
        try std.testing.expectEqual(v, try r.readMpintInt(i64));
        // Raw bytes re-read as a string and compared byte-for-byte.
        var r2 = Reader.init(w.written());
        const raw = try r2.readMpint();
        var buf2: [32]u8 = undefined;
        var w2 = Writer.init(&buf2);
        try w2.writeMpintBytes(raw);
        try std.testing.expectEqualSlices(u8, w.written(), w2.written());
    }
}

test "wire: mpint minimal encodings are exact" {
    // 128 needs a 0x00 sign pad; -128 does not; -129 does get 0xff.
    var buf: [8]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeMpint(@as(i64, 128));
    // length=2, bytes 00 80
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 0x00, 0x80 }, w.written());

    var w2 = Writer.init(&buf);
    try w2.writeMpint(@as(i64, -128));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x80 }, w2.written());

    var w3 = Writer.init(&buf);
    try w3.writeMpint(@as(i64, -129));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 0xff, 0x7f }, w3.written());
}

test "wire: an overlong mpint is rejected" {
    // length=2, 00 7f is overlong for +127.
    const bad = [_]u8{ 0, 0, 0, 2, 0x00, 0x7f };
    var r = Reader.init(&bad);
    try std.testing.expectError(error.Overflow, r.readMpintInt(i64));
}

test "wire: name-list round-trip and iteration" {
    const offered = [_][]const u8{ "curve25519-sha256", "curve25519-sha256@libssh.org" };
    var buf: [128]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeNameList(&offered);
    var r = Reader.init(w.written());
    const list = try r.readNameList();
    try std.testing.expectEqualStrings("curve25519-sha256,curve25519-sha256@libssh.org", list);
    var it = names(list);
    try std.testing.expectEqualStrings("curve25519-sha256", (try it.next()).?);
    try std.testing.expectEqualStrings("curve25519-sha256@libssh.org", (try it.next()).?);
    try std.testing.expect((try it.next()) == null);

    // An empty name-list is legal and yields no members.
    var ebuf: [4]u8 = undefined;
    var ew = Writer.init(&ebuf);
    try ew.writeNameList(&.{});
    var er = Reader.init(ew.written());
    var eit = names(try er.readNameList());
    try std.testing.expect((try eit.next()) == null);
}

test "wire: malformed name-list fails closed" {
    // Build explicit "a," (trailing comma) and ",a" (empty leading member).
    var buf: [8]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeString("a,");
    var r = Reader.init(w.written());
    var it = names(try r.readNameList());
    try std.testing.expectEqualStrings("a", (try it.next()).?);
    try std.testing.expectError(error.BadName, it.next());

    const empty_member = [_]u8{ 0, 0, 0, 2, ',', 'a' };
    var r2 = Reader.init(&empty_member);
    var it2 = names(try r2.readNameList());
    try std.testing.expectError(error.BadName, it2.next());
}

test "wire: short reads and bad booleans fail closed" {
    var r = Reader.init(&.{});
    try std.testing.expectError(error.ShortRead, r.readByte());
    var r2 = Reader.init(&.{ 0, 0, 0, 5, 'a' });
    try std.testing.expectError(error.ShortRead, r2.readString());
    var r3 = Reader.init(&.{2});
    try std.testing.expectError(error.BadBool, r3.readBool());
    var w = Writer.init(&.{});
    try std.testing.expectError(error.Overflow, w.writeUint32(1));
}

test "wire: negative readMpintInt into a narrow type fails closed" {
    // -40000 does not fit in i16.
    var buf: [8]u8 = undefined;
    var w = Writer.init(&buf);
    try w.writeMpint(@as(i64, -40000));
    var r = Reader.init(w.written());
    try std.testing.expectError(error.Overflow, r.readMpintInt(i16));
}
