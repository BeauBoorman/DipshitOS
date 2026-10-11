// stdz fmt (issue #759): u64 -> decimal / hex into a caller buffer.
// Pure — no syscalls, no heap, no comptime. `out` must hold 20 bytes for
// fmt_dec and 16 for fmt_hex; each returns the byte count written. Written
// in the zc dialect (dual-valid under host Zig 0.17: byte stores carry
// @intCast, which zc lowers as an identity cast). Plain // comments, not
// //! — these modules are host-checked CONCATENATED (flat namespace), and
// a mid-file //! block is not valid Zig.

pub fn fmt_dec(v: u64, out: [*]u8) u64 {
    var buf: [20]u8 = undefined;
    var i: u64 = 0;
    var x: u64 = v;
    while (x >= 10) {
        // digit = x % 10, emulated without the modulo operator
        buf[i] = @intCast(48 + (x - (x / 10) * 10));
        i = i + 1;
        x = x / 10;
    }
    buf[i] = @intCast(48 + x);
    i = i + 1;
    var n: u64 = 0;
    while (n < i) {
        out[n] = buf[i - 1 - n];
        n = n + 1;
    }
    return i;
}

pub fn fmt_hex(v: u64, out: [*]u8) u64 {
    var buf: [16]u8 = undefined;
    var i: u64 = 0;
    var x: u64 = v;
    while (x >= 16) {
        const d: u64 = x - (x / 16) * 16;
        if (d < 10) {
            buf[i] = @intCast(48 + d);
        } else {
            buf[i] = @intCast(87 + d);
        }
        i = i + 1;
        x = x / 16;
    }
    if (x < 10) {
        buf[i] = @intCast(48 + x);
    } else {
        buf[i] = @intCast(87 + x);
    }
    i = i + 1;
    var n: u64 = 0;
    while (n < i) {
        out[n] = buf[i - 1 - n];
        n = n + 1;
    }
    return i;
}
