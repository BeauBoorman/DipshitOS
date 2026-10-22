//! Host-side & in-guest prelude for zc (DipshitOS self-hosting compiler).
//! Exposes syscall wrappers and helpers that match in-guest zc semantics.

pub fn exit(status: u64) noreturn {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 3)),
          [code] "{x0}" (status),
    );
    while (true) {}
}

pub fn write(fd: u64, buf: []const u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 1)),
          [fd] "{x0}" (fd),
          [ptr] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [len] "{x2}" (@as(u64, buf.len)),
    );
}

pub fn print(msg: []const u8) void {
    _ = write(1, msg);
}

pub fn write_ptr(fd: u64, ptr: [*]const u8, len: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 1)),
          [fd] "{x0}" (fd),
          [ptr] "{x1}" (@as(u64, @intFromPtr(ptr))),
          [len] "{x2}" (len),
    );
}

pub fn print_ptr(ptr: [*]const u8, len: u64) void {
    _ = write_ptr(1, ptr, len);
}

pub fn print_array(buf: anytype) void {
    _ = write(1, buf[0..]);
}

pub fn print_struct(buf: anytype) void {
    const bytes: []const u8 = @as([*]const u8, @ptrCast(&buf))[0..@sizeOf(@TypeOf(buf))];
    _ = write(1, bytes);
}

pub fn yield() void {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 2)),
    );
}

pub fn sleep(ticks: u64) void {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 4)),
          [ticks] "{x0}" (ticks),
    );
}

/// card #3036 (ADR 0007 X1): slot 94 — block at least `ns` nanoseconds on
/// the deadline overlay. A pre-card-#3036 kernel answers ENOSYS (-4) and
/// the call falls back to slot 4, rounding up to whole ticks.
pub fn sleep_ns(ns: u64) i64 {
    const r: i64 = asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 94)),
          [ns] "{x0}" (ns),
    );
    if (r != -4) return r;
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 4)),
          [ticks] "{x0}" ((ns + 999_999_999) / 1_000_000_000),
    );
}

/// Z2a (issue #756): file ops take explicit ptr+len (the in-guest reg ABI is
/// fd in x0, ptr in x1, count in x2); fds and byte counts are u64 so the
/// dialect never needs int casts. Error returns (-errno) surface as huge u64.
pub fn file_open(path: []const u8, flags: u32) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 23)),
          [p] "{x0}" (@as(u64, @intFromPtr(path.ptr))),
          [l] "{x1}" (@as(u64, path.len)),
          [f] "{x2}" (@as(u64, flags)),
    );
}

pub fn file_read(fd: u64, buf: [*]u8, len: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 24)),
          [h] "{x0}" (@as(u64, fd)),
          [p] "{x1}" (@as(u64, @intFromPtr(buf))),
          [n] "{x2}" (@as(u64, len)),
    );
}

pub fn file_write(fd: u64, buf: [*]const u8, len: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 25)),
          [h] "{x0}" (@as(u64, fd)),
          [p] "{x1}" (@as(u64, @intFromPtr(buf))),
          [n] "{x2}" (@as(u64, len)),
    );
}

pub fn file_close(fd: u64) void {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 26)),
          [h] "{x0}" (@as(u64, fd)),
    );
}

/// Z2a (issue #756): anonymous RW private heap via sys_mmap (slot 63). The
/// eager MAP_POPULATE flag (0x8000) is set so the kernel allocates the pages
/// up front — kernel-side file copy_in/copy_out can then touch the region.
pub fn mmap(len: u64) [*]u8 {
    const va: u64 = asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 63)),
          [a0] "{x0}" (@as(u64, 0)),
          [a1] "{x1}" (@as(u64, len)),
          [a2] "{x2}" (@as(u64, 3)),
          [a3] "{x3}" (@as(u64, 0x8022)),
    );
    return @as([*]u8, @ptrFromInt(va));
}

pub fn win_open(x: u64, y: u64, w: u64, h: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 12)),
          [x] "{x0}" (x),
          [y] "{x1}" (y),
          [w] "{x2}" (w),
          [h] "{x3}" (h),
    );
}

pub fn win_fill(wid: u64, x: u64, y: u64, w: u64, h: u64, rgb: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 13)),
          [wid] "{x0}" (wid),
          [x] "{x1}" (x),
          [y] "{x2}" (y),
          [w] "{x3}" (w),
          [h] "{x4}" (h),
          [rgb] "{x5}" (rgb),
    );
}

pub fn win_present(wid: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 14)),
          [wid] "{x0}" (wid),
    );
}

pub fn win_close(wid: u64) void {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 15)),
          [wid] "{x0}" (wid),
    );
}

/// The raw syscall escape hatch (`zc.svc(<literal>, ...)`): `num` is the
/// ADR 0007 slot, `arg0` a bare u64 OR a pointer to a buffer the syscall
/// reads/writes (e.g. `zc.svc(21, &ev)` polls the ADR 0009 event queue
/// into a struct — the VL6 snake demo). The in-guest compiler emits the
/// argument address directly and never reads this file; the arg is widened
/// to `anytype` so host zig 0.17 type-checks both shapes (the Z4b corpus
/// host build analyzes every fixture body against this shim).
pub fn svc(comptime num: u16, arg0: anytype) i64 {
    const a0: u64 = if (@TypeOf(arg0) == u64) arg0 else @intFromPtr(arg0);
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, num)),
          [a0] "{x0}" (a0),
    );
}
