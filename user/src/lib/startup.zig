//! VirelaiOS userland startup/profile runner (M49 SD2 — issue #1129,
//! ADR 0021 D5 follow-on).
//!
//! The unified startup contract for every userland shell presentation
//! (`SH.BIN` on the serial console, `TERM.BIN` in a window):
//!
//!   1. `STARTUP.SH` — the shell's own startup (system/user configuration;
//!      runs first on **every** presentation).
//!   2. `PROFILE.SH` — the optional host-share user profile (runs after
//!      `STARTUP.SH`, so a profile can override what startup set).
//!
//! Both live on the host share. A missing file is silent (the common case).
//! The kernel monitor's `.virelairc` is deliberately **out of this scope**:
//! it is the recovery/diagnostic console's own file and runs in the monitor
//! before any shell is spawned (documented in `docs/status.md`).
//!
//! The module is pure logic over an injected file seam so the whole
//! parse/order surface is host-testable; `SH.BIN`/`TERM.BIN` wire the seam
//! to the existing `sys_file_open`/`read`/`close` calls.

const std = @import("std");

/// The shell-scope startup file, run first (both shell presentations).
pub const startup_path: []const u8 = "STARTUP.SH";
/// The optional host-share user profile, run after `STARTUP.SH`.
pub const profile_path: []const u8 = "PROFILE.SH";
/// The most bytes read from either file (bounded fixed buffer, no alloc).
pub const max_file: usize = 2048;

/// The file access seam: the shell glue implements it over slots 23/24/26 —
/// host tests implement it over a memory map. `open` returns a read handle
/// (>= 0) or a negative error; `read` returns bytes or a negative error.
pub const Files = struct {
    ctx: ?*anyopaque = null,
    open_fn: *const fn (ctx: ?*anyopaque, path: []const u8) i64,
    read_fn: *const fn (ctx: ?*anyopaque, handle: u32, buf: []u8) i64,
    close_fn: *const fn (ctx: ?*anyopaque, handle: u32) void,

    pub fn open(self: Files, path: []const u8) ?u32 {
        const r = self.open_fn(self.ctx, path);
        if (r < 0) return null;
        return @intCast(r);
    }

    pub fn read(self: Files, handle: u32, buf: []u8) usize {
        const r = self.read_fn(self.ctx, handle, buf);
        if (r <= 0) return 0;
        return @intCast(r);
    }

    pub fn close(self: Files, handle: u32) void {
        self.close_fn(self.ctx, handle);
    }
};

/// The per-line sink: one call per non-empty CR/LF-terminated line.
pub const LineFn = *const fn (ctx: ?*anyopaque, line: []const u8) void;

/// Read `path` through `files` and call `line` for every line, in order.
/// A missing/empty file is a silent no-op. Returns true when the file was
/// opened and at least one line was delivered.
pub fn runFile(path: []const u8, files: Files, ctx: ?*anyopaque, line: LineFn) bool {
    const handle = files.open(path) orelse return false;
    var data: [max_file]u8 = undefined;
    const got = files.read(handle, &data);
    files.close(handle);
    if (got == 0) return false;
    var delivered = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= got) : (i += 1) {
        if (i == got or data[i] == '\n' or data[i] == '\r') {
            if (i > start) {
                line(ctx, data[start..i]);
                delivered = true;
            }
            // Swallow the LF half of a CRLF pair (one newline = one line).
            if (i < got and data[i] == '\r' and i + 1 < got and data[i + 1] == '\n') i += 1;
            start = i + 1;
        }
    }
    return delivered;
}

/// The unified order: `STARTUP.SH`, then `PROFILE.SH`.
pub fn runAll(files: Files, ctx: ?*anyopaque, line: LineFn) void {
    _ = runFile(startup_path, files, ctx, line);
    _ = runFile(profile_path, files, ctx, line);
}

// ---------------------------------------------------------------------------
// Host tests (pure; the memory file seam executes no syscalls)
// ---------------------------------------------------------------------------

const FakeFiles = struct {
    var startup_buf: []const u8 = "";
    var profile_buf: []const u8 = "";
    /// 0 = absent, 1 = startup, 2 = profile.
    var startup_present: bool = true;
    var profile_present: bool = true;
    var reads: [4]u8 = @as([4]u8, @splat(@as(u8, 0)));
    var read_count: usize = 0;
    var open_order: [2]u8 = @as([2]u8, @splat(@as(u8, 0)));
    var open_count: usize = 0;

    fn reset() void {
        startup_buf = "";
        profile_buf = "";
        startup_present = false;
        profile_present = false;
        read_count = 0;
        open_count = 0;
    }

    fn open(ctx: ?*anyopaque, path: []const u8) i64 {
        _ = ctx;
        if (std.mem.eql(u8, path, "STARTUP.SH")) {
            if (!startup_present) return -1;
            open_order[open_count] = 1;
            open_count += 1;
            return 1;
        }
        if (std.mem.eql(u8, path, "PROFILE.SH")) {
            if (!profile_present) return -1;
            open_order[open_count] = 2;
            open_count += 1;
            return 2;
        }
        return -1;
    }

    fn read(ctx: ?*anyopaque, handle: u32, buf: []u8) i64 {
        _ = ctx;
        const src = if (handle == 1) startup_buf else profile_buf;
        const n = @min(src.len, buf.len);
        @memcpy(buf[0..n], src[0..n]);
        read_count += 1;
        return @intCast(n);
    }

    fn close(ctx: ?*anyopaque, handle: u32) void {
        _ = ctx;
        _ = handle;
    }

    fn seam() Files {
        return .{ .open_fn = open, .read_fn = read, .close_fn = close };
    }
};

const LineLog = struct {
    var buf: [512]u8 = undefined;
    var len: usize = 0;

    fn reset() void {
        len = 0;
    }

    fn line(ctx: ?*anyopaque, l: []const u8) void {
        _ = ctx;
        if (len > 0 and len < buf.len) {
            buf[len] = '|';
            len += 1;
        }
        const n = @min(l.len, buf.len - len);
        @memcpy(buf[len..][0..n], l[0..n]);
        len += n;
    }

    fn contents() []const u8 {
        return buf[0..len];
    }
};

test "startup: runs STARTUP.SH then PROFILE.SH in order" {
    FakeFiles.reset();
    LineLog.reset();
    FakeFiles.startup_present = true;
    FakeFiles.profile_present = true;
    FakeFiles.startup_buf = "echo startup\n";
    FakeFiles.profile_buf = "echo profile\n";
    runAll(FakeFiles.seam(), null, LineLog.line);
    try std.testing.expectEqualStrings("echo startup|echo profile", LineLog.contents());
    try std.testing.expectEqual(@as(usize, 2), FakeFiles.open_count);
    try std.testing.expectEqual(@as(u8, 1), FakeFiles.open_order[0]);
    try std.testing.expectEqual(@as(u8, 2), FakeFiles.open_order[1]);
}

test "startup: missing files are silent no-ops" {
    FakeFiles.reset();
    LineLog.reset();
    try std.testing.expect(!runFile("STARTUP.SH", FakeFiles.seam(), null, LineLog.line));
    runAll(FakeFiles.seam(), null, LineLog.line);
    try std.testing.expectEqualStrings("", LineLog.contents());
    try std.testing.expectEqual(@as(usize, 0), FakeFiles.open_count);
}

test "startup: only the profile present still runs it" {
    FakeFiles.reset();
    LineLog.reset();
    FakeFiles.profile_present = true;
    FakeFiles.profile_buf = "set P=1\n";
    runAll(FakeFiles.seam(), null, LineLog.line);
    try std.testing.expectEqualStrings("set P=1", LineLog.contents());
}

test "startup: CRLF terminates one line and empty lines are skipped" {
    FakeFiles.reset();
    LineLog.reset();
    FakeFiles.startup_present = true;
    FakeFiles.startup_buf = "a\r\n\r\nb\n";
    _ = runFile("STARTUP.SH", FakeFiles.seam(), null, LineLog.line);
    try std.testing.expectEqualStrings("a|b", LineLog.contents());
}

test "startup: a file without a trailing newline still runs its last line" {
    FakeFiles.reset();
    LineLog.reset();
    FakeFiles.startup_present = true;
    FakeFiles.startup_buf = "tail";
    _ = runFile("STARTUP.SH", FakeFiles.seam(), null, LineLog.line);
    try std.testing.expectEqualStrings("tail", LineLog.contents());
}

test "startup: the path constants are the documented contract" {
    try std.testing.expectEqualStrings("STARTUP.SH", startup_path);
    try std.testing.expectEqualStrings("PROFILE.SH", profile_path);
}
