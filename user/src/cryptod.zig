//! census (M188e, #3190): CRYPTOD.BIN — gate-referenced: live-crypto.
//! VirelaiOS M47 CP5 EL0 demo — CRYPTOD.BIN (#1119, ADR 0023).
//!
//! Reads a file through the M10/M34 file channel (slots 23/24/26), streams
//! it in fixed 256-byte chunks into both a SHA-256 context and an
//! HMAC-SHA256 context (fixed demo key — the "fixed vectors first" rule),
//! and prints ONE line in a SINGLE `sys_write` (slot 1):
//!
//!     cryptod: sha256=<64 hex> hmac=<64 hex>
//!
//! Memory is O(1): the hash/MAC contexts and the I/O and output buffers all
//! live on the EL0 stack; nothing is allocated and the whole file is never
//! buffered. The M47 `live-crypto` gate recomputes both values on the host
//! and asserts the guest's bytes match — guest bytes == host KAT.
//!
//! Usage: exec CRYPTOD.BIN <file>

const std = @import("std");
const crypto = @import("lib/crypto.zig");

const Sha256 = crypto.sha256.Sha256;
const HmacSha256 = crypto.hmac.HmacSha256;

// Fixed demo key (bytes from this literal). Randomness is deliberately not
// used here: the KAT must be reproducible on the host. A later tranche can
// key the demo from the kernel CSPRNG once the fixed path is proven.
const demo_key = "VIRELAIOS-M47-CRYPTO-DEMO-KEY";

const MODE_READ: u32 = 0x1;

fn sys_write(buf: []const u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 1)),
          [fd] "{x0}" (@as(u64, 1)),
          [ptr] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [len] "{x2}" (@as(u64, buf.len)),
    );
}

fn console_puts(text: []const u8) void {
    if (text.len == 0) return;
    _ = sys_write(text);
}

fn sys_exit(status: u64) noreturn {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 3)),
          [code] "{x0}" (status),
    );
    unreachable;
}

fn file_open(path: []const u8, flags: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 23)),
          [p] "{x0}" (@as(u64, @intFromPtr(path.ptr))),
          [l] "{x1}" (@as(u64, path.len)),
          [f] "{x2}" (@as(u64, flags)),
    );
}

fn file_read(fd: u32, buf: []u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 24)),
          [h] "{x0}" (@as(u64, fd)),
          [p] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [n] "{x2}" (@as(u64, buf.len)),
    );
}

fn file_close(fd: u32) void {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 26)),
          [h] "{x0}" (@as(u64, fd)),
    );
}

pub export fn _start(argc: usize, argv: ?[*]const [256]u8) callconv(.c) noreturn {
    var path_buf: [40]u8 = @as([40]u8, @splat(@as(u8, 0)));
    var path_len: usize = 0;
    if (argc >= 1) {
        if (argv) |slots| copy_arg(&path_buf, &path_len, slots[0]);
    }
    if (path_len == 0) {
        console_puts("cryptod: usage: CRYPTOD.BIN <file>\n");
        sys_exit(2);
    }
    run(path_buf[0..path_len]);
}

fn copy_arg(dst: *[40]u8, len: *usize, slot: [256]u8) void {
    const n = std.mem.indexOfScalar(u8, &slot, 0) orelse slot.len;
    const take = @min(n, dst.len);
    @memcpy(dst[0..take], slot[0..take]);
    len.* = take;
}

fn run(path: []const u8) noreturn {
    const fd = file_open(path, MODE_READ);
    if (fd < 0) {
        console_puts("cryptod: cannot open file\n");
        sys_exit(1);
    }

    var sha = Sha256.init();
    var mac = HmacSha256.init(demo_key);
    var chunk: [256]u8 = undefined;

    while (true) {
        const n = file_read(@intCast(fd), &chunk);
        if (n < 0) {
            file_close(@intCast(fd));
            console_puts("cryptod: read error\n");
            sys_exit(3);
        }
        if (n == 0) break;
        const used: usize = @intCast(n);
        sha.update(chunk[0..used]);
        mac.update(chunk[0..used]);
    }
    file_close(@intCast(fd));

    var digest: [32]u8 = undefined;
    var tag: [32]u8 = undefined;
    sha.final(&digest);
    mac.final(&tag);

    var out: [160]u8 = undefined;
    var pos: usize = 0;
    pos = appendStr(&out, pos, "cryptod: sha256=");
    pos = appendHex(&out, pos, &digest);
    pos = appendStr(&out, pos, " hmac=");
    pos = appendHex(&out, pos, &tag);
    out[pos] = '\n';
    pos += 1;

    // ONE write for the whole line (the CP5 contract).
    _ = sys_write(out[0..pos]);
    sys_exit(0);
}

fn appendStr(buf: []u8, pos: usize, src: []const u8) usize {
    const take = @min(src.len, buf.len - pos);
    @memcpy(buf[pos .. pos + take], src[0..take]);
    return pos + take;
}

fn appendHex(buf: []u8, pos: usize, bytes: []const u8) usize {
    const digits = "0123456789abcdef";
    var p = pos;
    for (bytes) |b| {
        buf[p] = digits[b >> 4];
        buf[p + 1] = digits[b & 0x0f];
        p += 2;
    }
    return p;
}
