//! Virelai Monitor console abstraction (Milestone 1.5, commands & personality).
//!
//! A tiny, transport-agnostic console interface. The command layer never
//! knows whether bytes eventually reach a PL011, a 16550, a virtio-console,
//! or a host-side test mock: it only holds a `Console` value with a
//! function-pointer vtable and an opaque context pointer.
//!
//! Kernel wiring: the later Console & Shell Core stream supplies an adapter
//! over the milestone-two polled TX `uart_*` console (ADR 0004 D4).
//! Host tests: `MockConsole` captures output into a bounded buffer.
//!
//! No libc, no POSIX, no allocation, no dynamic registration, no global
//! mutable state. All formatting is byte-streamed so output stays bounded.

const std = @import("std");

/// Value-type console handle: `ctx` plus a stateless function-pointer vtable.
/// Every method below degrades to `write`, so a transport only has to
/// provide one function (plus a no-op-friendly `flush`).
/// Forensics drain seam (claim #1278). A hook the console calls immediately
/// before each write, so a recorder can prefix pending trace records to an
/// ordinary line. A seam rather than an import because the recorder needs
/// `Console` to print, and `Console` would need the recorder to call it — the
/// same wiring pattern `exceptions.init(writer)` and `set_irq_dispatcher` use.
///
/// Null by default, so a default boot has no hook and no recorder.
var drain_hook: ?*const fn (Console) void = null;

pub fn set_drain_hook(f: *const fn (Console) void) void {
    drain_hook = f;
}

pub const Console = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Append `bytes` to the console. A bounded transport drops the tail
        /// (and may flag overflow) rather than blocking forever.
        write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
        /// Push any buffered output; a no-op for polled byte-at-a-time TX.
        flush: *const fn (ctx: *anyopaque) void,
        /// Polled, non-blocking input: the next received byte, or null when
        /// no input is available right now. A transport with no RX path
        /// (the milestone-two uart, until the VZ serial gate proves a
        /// device) returns null always. Never blocks, never allocates.
        readByte: *const fn (ctx: *anyopaque) ?u8,
        /// Optional input pushback: transports that can requeue a byte for a
        /// future readByte implement it (the serial front-end's detach path
        /// returns input its dying session pumped but never read). Null =
        /// the transport cannot take input back; the byte drops.
        pushByte: ?*const fn (ctx: *anyopaque, b: u8) bool = null,
    };

    pub fn write(self: Console, bytes: []const u8) void {
        // Claim #1278: let the recorder emit pending trace records ahead of
        // this line. The hook is responsible for its own reentrancy guard —
        // it prints, which lands back here.
        if (drain_hook) |h| h(self);
        self.vtable.write(self.ctx, bytes);
    }

    /// Poll one input byte; null means "no input available now". The shell
    /// loop waits between polls (WFE in the parked no-RX case; a bounded
    /// delay when RX is wired — claim 6684), so a no-RX transport idles
    /// instead of spinning.
    pub fn readByte(self: Console) ?u8 {
        return self.vtable.readByte(self.ctx);
    }

    /// Requeue one input byte for a future readByte; false when the
    /// transport cannot take input back.
    pub fn pushByte(self: Console, b: u8) bool {
        const f = self.vtable.pushByte orelse return false;
        return f(self.ctx, b);
    }

    pub fn putc(self: Console, byte: u8) void {
        const one = [1]u8{byte};
        self.write(&one);
    }

    pub fn puts(self: Console, text: []const u8) void {
        self.write(text);
    }

    pub fn print_line(self: Console, text: []const u8) void {
        self.write(text);
        self.write("\n");
    }

    /// Format one whole line into a bounded stack buffer and emit it as a
    /// SINGLE write. A line assembled over several `write` calls can be
    /// interrupted mid-composition by a foreign writer on another core —
    /// the M119f K-pass console defect (#2649; the claim-881-slice-4 rule
    /// already applied open-coded in the scheduler drains) — so lines the
    /// live gates grep on are built once and written once. An oversized
    /// format drops the line honestly at the bounded buffer.
    pub fn linef(self: Console, comptime fmt: []const u8, args: anytype) void {
        var buf: [384]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(line);
    }

    pub fn flush(self: Console) void {
        self.vtable.flush(self.ctx);
    }

    /// "0x" followed by exactly 16 lowercase hex digits. This matches the
    /// milestone-two kernel's own `uart_hex` format (kernel/src/main.zig),
    /// so monitor output and kernel probe output stay visually consistent.
    pub fn print_hex(self: Console, value: u64) void {
        self.write("0x");
        var shift: u6 = 60;
        while (true) : (shift -= 4) {
            const digit: u8 = @intCast((value >> shift) & 0xf);
            self.putc(if (digit < 10) '0' + digit else 'a' + digit - 10);
            if (shift == 0) break;
        }
    }

    /// "0x" followed by minimal lowercase hex digits ("0x0" for zero).
    /// Used by the `hex` shell utility for human-readable output.
    pub fn print_hex_min(self: Console, value: u64) void {
        self.write("0x");
        var started = false;
        var shift: u6 = 60;
        while (true) : (shift -= 4) {
            const digit: u8 = @intCast((value >> shift) & 0xf);
            if (digit != 0 or started or shift == 0) {
                self.putc(if (digit < 10) '0' + digit else 'a' + digit - 10);
                started = true;
            }
            if (shift == 0) break;
        }
    }

    /// Decimal digits with no leading zeros ("0" for zero).
    pub fn print_u64(self: Console, value: u64) void {
        var buffer: [20]u8 = undefined;
        var index: usize = buffer.len;
        var v = value;
        if (v == 0) {
            self.putc('0');
            return;
        }
        while (v != 0) : (v /= 10) {
            index -= 1;
            buffer[index] = '0' + @as(u8, @intCast(v % 10));
        }
        self.write(buffer[index..]);
    }
};

/// Bounded capture console for host-side tests.
/// `MockConsole(4096)` captures into a fixed 4096-byte buffer. Writes that
/// do not fit are truncated at the buffer boundary and set `overflowed`;
/// they never wrap, block, or crash. This is also how the monitor's
/// output-budget behavior is exercised without a real serial device.
pub fn MockConsole(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const vtable = Console.VTable{
            .write = writeFn,
            .flush = flushFn,
            .readByte = readByteFn,
            .pushByte = pushByteFn,
        };

        // Output capture (existing).
        buffer: [capacity]u8 = undefined,
        len: usize = 0,
        overflowed: bool = false,
        flush_count: usize = 0,
        // Scripted input (M1.5 console & shell core): a fixed byte queue
        // the tests feed; readByte pops it in order. Sized at least one
        // byte so a zero-capacity mock still type-checks; `feed` refuses
        // everything for capacity 0 (available == 0), so the semantics of
        // a zero-capacity console are unchanged. Note: the input queue
        // shares the same `capacity` as the output buffer, so a test with
        // a large scripted session (e.g. the shell's 8192-byte e2e) sizes
        // both directions together.
        input: [@max(capacity, 1)]u8 = undefined,
        input_len: usize = 0,
        input_pos: usize = 0,
        input_overflowed: bool = false,
        // Pushed-back input (pushByte): a separate lane read BEFORE the fed
        // queue, matching the serial lane's inject-first ordering — fed
        // bytes model host input that arrives after the handback.
        inject: [64]u8 = undefined,
        inject_len: usize = 0,

        pub fn console(self: *Self) Console {
            return .{ .ctx = self, .vtable = &vtable };
        }

        /// Captured bytes in write order (possibly truncated at overflow).
        pub fn contents(self: *const Self) []const u8 {
            return self.buffer[0..self.len];
        }

        /// Script input bytes for `readByte` to consume in order. Bytes
        /// beyond the fixed queue are refused (flagged), never wrapped.
        pub fn feed(self: *Self, bytes: []const u8) void {
            const available = capacity - self.input_len;
            if (available == 0) {
                if (bytes.len > 0) self.input_overflowed = true;
                return;
            }
            const n = @min(bytes.len, available);
            @memcpy(self.input[self.input_len..][0..n], bytes[0..n]);
            self.input_len += n;
            if (n < bytes.len) self.input_overflowed = true;
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.overflowed = false;
            self.flush_count = 0;
            self.input_len = 0;
            self.input_pos = 0;
            self.input_overflowed = false;
            self.inject_len = 0;
        }

        fn writeFn(ctx: *anyopaque, bytes: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const available = capacity - self.len;
            if (available == 0) {
                self.overflowed = true;
                return;
            }
            const n = @min(bytes.len, available);
            @memcpy(self.buffer[self.len..][0..n], bytes[0..n]);
            self.len += n;
            if (n < bytes.len) self.overflowed = true;
        }

        fn flushFn(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.flush_count += 1;
        }

        fn readByteFn(ctx: *anyopaque) ?u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.inject_len > 0) {
                const byte = self.inject[0];
                std.mem.copyForwards(u8, self.inject[0 .. self.inject_len - 1], self.inject[1..self.inject_len]);
                self.inject_len -= 1;
                return byte;
            }
            if (self.input_pos >= self.input_len) return null;
            const byte = self.input[self.input_pos];
            self.input_pos += 1;
            return byte;
        }

        fn pushByteFn(ctx: *anyopaque, b: u8) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.inject_len >= self.inject.len) return false;
            self.inject[self.inject_len] = b;
            self.inject_len += 1;
            return true;
        }
    };
}

test "console: mock captures writes in order" {
    var mock = MockConsole(64){};
    const con = mock.console();
    con.puts("ab");
    con.putc('c');
    con.print_line("de");
    try std.testing.expectEqualStrings("abcde\n", mock.contents());
    try std.testing.expect(!mock.overflowed);
}

test "console: reset clears capture and flags" {
    var mock = MockConsole(64){};
    mock.console().putc('x');
    mock.console().flush();
    try std.testing.expectEqualStrings("x", mock.contents());
    try std.testing.expectEqual(@as(usize, 1), mock.flush_count);
    mock.reset();
    try std.testing.expectEqualStrings("", mock.contents());
    try std.testing.expectEqual(@as(usize, 0), mock.flush_count);
    try std.testing.expect(!mock.overflowed);
}

test "console: overflow truncates, flags, and never wraps" {
    var mock = MockConsole(8){};
    mock.console().puts("hello world"); // 11 bytes into 8
    try std.testing.expectEqualStrings("hello wo", mock.contents());
    try std.testing.expect(mock.overflowed);
    mock.console().puts("more"); // dropped: buffer is full
    try std.testing.expectEqualStrings("hello wo", mock.contents());
    try std.testing.expect(mock.overflowed);
    mock.reset();
    try std.testing.expect(!mock.overflowed);
    try std.testing.expectEqualStrings("", mock.contents());
}

test "console: zero-capacity mock flags every write" {
    var mock = MockConsole(0){};
    mock.console().puts("x");
    try std.testing.expect(mock.overflowed);
}

test "console: print_hex prints fixed 16 lowercase digits" {
    var mock = MockConsole(64){};
    mock.console().print_hex(0x324b5344);
    try std.testing.expectEqualStrings("0x00000000324b5344", mock.contents());
    mock.reset();
    mock.console().print_hex(0);
    try std.testing.expectEqualStrings("0x0000000000000000", mock.contents());
    mock.reset();
    mock.console().print_hex(std.math.maxInt(u64));
    try std.testing.expectEqualStrings("0xffffffffffffffff", mock.contents());
}

test "console: print_hex_min prints minimal lowercase hex" {
    var mock = MockConsole(64){};
    mock.console().print_hex_min(0);
    try std.testing.expectEqualStrings("0x0", mock.contents());
    mock.reset();
    mock.console().print_hex_min(0xff);
    try std.testing.expectEqualStrings("0xff", mock.contents());
    mock.reset();
    mock.console().print_hex_min(0x324b5344);
    try std.testing.expectEqualStrings("0x324b5344", mock.contents());
    mock.reset();
    mock.console().print_hex_min(std.math.maxInt(u64));
    try std.testing.expectEqualStrings("0xffffffffffffffff", mock.contents());
}

test "console: print_u64 prints decimal without leading zeros" {
    var mock = MockConsole(64){};
    mock.console().print_u64(0);
    try std.testing.expectEqualStrings("0", mock.contents());
    mock.reset();
    mock.console().print_u64(1);
    try std.testing.expectEqualStrings("1", mock.contents());
    mock.reset();
    mock.console().print_u64(42);
    try std.testing.expectEqualStrings("42", mock.contents());
    mock.reset();
    mock.console().print_u64(123456789);
    try std.testing.expectEqualStrings("123456789", mock.contents());
    mock.reset();
    mock.console().print_u64(std.math.maxInt(u64));
    try std.testing.expectEqualStrings("18446744073709551615", mock.contents());
}

test "console: mock readByte returns scripted input in order" {
    var mock = MockConsole(64){};
    const con = mock.console();
    try std.testing.expect(con.readByte() == null); // empty queue
    mock.feed("ab");
    mock.feed("c");
    try std.testing.expectEqual(@as(u8, 'a'), con.readByte().?);
    try std.testing.expectEqual(@as(u8, 'b'), con.readByte().?);
    try std.testing.expectEqual(@as(u8, 'c'), con.readByte().?);
    try std.testing.expect(con.readByte() == null); // drained
}

test "console: mock feed overflow is refused and flagged, never wraps" {
    var mock = MockConsole(4){};
    mock.feed("abcdef"); // 6 bytes into a 4-byte queue
    try std.testing.expect(mock.input_overflowed);
    const con = mock.console();
    try std.testing.expectEqual(@as(u8, 'a'), con.readByte().?);
    try std.testing.expectEqual(@as(u8, 'b'), con.readByte().?);
    try std.testing.expectEqual(@as(u8, 'c'), con.readByte().?);
    try std.testing.expectEqual(@as(u8, 'd'), con.readByte().?);
    try std.testing.expect(con.readByte() == null);
    mock.reset();
    try std.testing.expect(!mock.input_overflowed);
}

test "console: reset clears the scripted input queue too" {
    var mock = MockConsole(16){};
    mock.feed("xyz");
    mock.reset();
    try std.testing.expect(mock.console().readByte() == null);
    try std.testing.expect(!mock.input_overflowed);
}
