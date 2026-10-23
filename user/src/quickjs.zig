//! census (M188e, #3190): QJS.BIN — gate-referenced: live-quickjs; built by tools/js-client/build.py, not build.zig.
//! ADR 0039's sole product adapter. JS owns no native handles.
const std = @import("std");
const sdk = @import("sdk").runtime;
const qjs = if (@import("build_options").engine) @import("qjs") else struct {};
const policy = @import("product_policy");
pub const os = sdk.os;
pub const std_options = sdk.std_options;
pub const panic = std.debug.FullPanic(sdk.panic);
pub const virelai = sdk.platform;
pub const std_options_debug_io = sdk.std_options_debug_io;
pub const std_options_FilePermissions = sdk.std_options_FilePermissions;
pub const std_options_cwd = sdk.std_options_cwd;

comptime {
    @import("sdk").entry.exportEntry(dispatch);
}

fn diagnosticChunk(bytes: []const u8) i64 {
    return sdk.native.call(1, .{ 2, @intFromPtr(bytes.ptr), bytes.len, 0, 0, 0 });
}

fn fail(name: []const u8, status: u8) noreturn {
    sdk.console.writeAll(diagnosticChunk, name) catch {};
    sdk.console.writeAll(diagnosticChunk, "\n") catch {};
    sdk.native.exit(status);
}

fn dispatch(args: *const sdk.startup.Startup) !void {
    run(args) catch |err| fail(@errorName(err), 70);
}

const Session = struct {
    runtime: *qjs.Runtime,
    receipt: ?std.Io.File = null,
    tty: ?u64 = null,
    attached: bool = false,
    queue: []u8,
    queued: usize = 0,
    queue_read: usize = 0,
    queue_overflow: bool = false,
    drain_pending: bool = false,
    io_failure: ?anyerror = null,
    first_output: u64 = 0,
    cancel_counter: u64 = 0,
    peak_files: usize = 0,
    peak_resources: usize = 4,
    metadata: [768]u8 = undefined,

    fn resources(self: *Session) !void {
        const files = sdk.filesystem().liveFiles() + @intFromBool(self.tty != null);
        const records = sdk.filesystem().liveResources() + @intFromBool(self.tty != null);
        try self.runtime.checkResources(files, records);
        self.peak_files = @max(self.peak_files, files);
        self.peak_resources = @max(self.peak_resources, records);
    }

    fn mirror(self: *Session, kind: u8, bytes: []const u8) !void {
        if (self.receipt) |file| {
            var header: [40]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&header, "{c} {d}\n", .{ kind, bytes.len });
            try self.runtime.chargeReceipt(prefix.len + bytes.len);
            try file.writeStreamingAll(sdk.io, prefix);
            try file.writeStreamingAll(sdk.io, bytes);
        }
    }

    fn write(context: *anyopaque, bytes: []const u8) !usize {
        const self: *Session = @ptrCast(@alignCast(context));
        if (self.io_failure != null) return error.WriteFailed;
        const count = sdk.native.consoleChunk(bytes);
        if (count <= 0 or count > bytes.len) return error.WriteFailed;
        const confirmed: usize = @intCast(count);
        if (self.first_output == 0)
            self.first_output = self.runtime.control.clock.counter(self.runtime.control.clock.context);
        self.mirror('O', bytes[0..confirmed]) catch |err| {
            self.io_failure = err;
            return err;
        };
        return confirmed;
    }

    fn diagnostic(context: *anyopaque, bytes: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(context));
        try sdk.console.writeAll(diagnosticChunk, bytes);
        self.mirror('D', bytes) catch |err| {
            self.io_failure = err;
            return err;
        };
    }

    fn notice(self: *Session, bytes: []const u8) !void {
        try self.runtime.control.chargeDiagnostic(bytes.len);
        try diagnostic(self, bytes);
    }

    fn terminal(self: *Session, bytes: []const u8) !void {
        if (bytes.len > qjs.limits.terminal_diagnostic or
            bytes.len > qjs.limits.diagnostics - self.runtime.control.diagnostic_bytes)
            return error.DiagnosticLimit;
        self.runtime.control.diagnostic_bytes += bytes.len;
        try diagnostic(self, bytes);
    }

    fn sink(self: *Session) qjs.Sink {
        return .{ .context = self, .write = write, .diagnostic = diagnostic, .poll = poll };
    }

    fn poll(context: *anyopaque) bool {
        const self: *Session = @ptrCast(@alignCast(context));
        const fd = self.tty orelse return false;
        var bytes: [128]u8 = undefined;
        const n = sdk.native.call(24, .{ fd, @intFromPtr(&bytes), bytes.len, 0, 0, 0 });
        if (n < 0 or n > bytes.len) {
            self.io_failure = error.ReadFailed;
            self.runtime.control.refuse(error.WriteFailed);
            return false;
        }
        var cancel = false;
        for (bytes[0..@intCast(n)]) |byte| {
            if (byte == 3 and self.runtime.control.running) {
                if (self.cancel_counter == 0)
                    self.cancel_counter = self.runtime.control.clock.counter(self.runtime.control.clock.context);
                cancel = true;
            } else if (self.drain_pending) {
                if (byte == '\n' or byte == '\r') self.drain_pending = false;
            } else if (self.queued < self.queue.len) {
                self.queue[self.queued] = byte;
                self.queued += 1;
            } else {
                self.queue_overflow = true;
                self.queued = 0;
                self.queue_read = 0;
                // Discard the queued prefix, never evaluate a clipped line.
                // If this byte terminates the oversized line, preserve later
                // lines in subsequent reads instead of dropping them forever.
                self.drain_pending = byte != '\n' and byte != '\r';
                self.runtime.control.refuse(error.LineLimit);
            }
        }
        return cancel;
    }

    fn evaluate(self: *Session, source: []const u8, filename: []const u8, interactive: bool) !bool {
        if (self.queue_read != 0) {
            std.mem.copyForwards(u8, self.queue[0 .. self.queued - self.queue_read], self.queue[self.queue_read..self.queued]);
            self.queued -= self.queue_read;
            self.queue_read = 0;
        }
        self.first_output = 0;
        self.cancel_counter = 0;
        var kept: usize = 0;
        for (self.queue[0..self.queued]) |byte| {
            if (byte == 3) {
                self.cancel_counter = self.runtime.control.clock.counter(self.runtime.control.clock.context);
                self.runtime.cancel();
            } else {
                self.queue[kept] = byte;
                kept += 1;
            }
        }
        self.queued = kept;
        const result = try self.runtime.eval(source, filename, self.sink(), interactive);
        // The poll discarded the oversized prefix and preserved only bytes
        // after its terminator. Refusal already reset the context.
        self.queue_overflow = false;
        const stack = sdk.stackHighWater();
        if (stack > qjs.limits.stack) return error.StackLimit;
        const row = try std.fmt.bufPrint(&self.metadata, "eval={d} failure={s} reset={d} output={d} arena_peak={d} stack={d} c_stack={d} sites={d} gap={d} frequency={d} start={d} end={d} first={d} files={d} resources={d}\n", .{ self.runtime.control.evals, if (result.failure) |err| @errorName(err) else "none", @intFromBool(result.context_reset), result.output_bytes, result.arena_peak_bytes, stack, result.c_stack_high_water, result.work_sites, result.maximum_unchecked_ticks, result.counter_frequency, result.start_counter, result.end_counter, self.first_output, self.peak_files, self.peak_resources });
        try self.mirror('R', row);
        if (result.failure) |failure| {
            var message: [96]u8 = undefined;
            try self.notice(try std.fmt.bufPrint(&message, "qjs: {s}\n", .{@errorName(failure)}));
            if (result.context_reset) try self.notice("qjs: ContextReset\n");
        }
        const completion = self.runtime.control.clock.counter(self.runtime.control.clock.context);
        var timing: [160]u8 = undefined;
        try self.mirror('T', try std.fmt.bufPrint(&timing, "eval={d} completion={d} cancel={d}\n", .{ self.runtime.control.evals, completion, self.cancel_counter }));
        if (self.io_failure) |err| return err;
        return result.failure == null;
    }

    fn openReceipt(self: *Session, name: []const u8) !void {
        try policy.path(name);
        const slash = std.mem.lastIndexOfScalar(u8, name, '/').?;
        const parent = if (slash == 5) "" else name[6..slash];
        const directory = try sdk.filesystem().openDirectory("/host", parent);
        var pinned = true;
        defer if (pinned) sdk.filesystem().closeDirectory(directory) catch {};
        try self.resources();
        self.receipt = sdk.filesystem().createExclusive(directory, name[slash + 1 ..]) catch |err|
            return if (err == error.PathAlreadyExists) error.ReceiptExists else err;
        try self.resources();
        try sdk.filesystem().closeDirectory(directory);
        pinned = false;
        try self.mirror('H', "QJS/1\n");
    }

    fn close(self: *Session) !void {
        var failure: ?anyerror = null;
        if (self.attached) {
            if (sdk.native.call(67, .{ 0, 0, 0, 0, 0, 0 }) != 0) failure = error.DetachFailed;
            self.attached = false;
        }
        if (self.tty) |fd| {
            if (sdk.native.call(26, .{ fd, 0, 0, 0, 0, 0 }) != 0) failure = error.CloseFailed;
            self.tty = null;
        }
        if (self.receipt) |file| {
            file.sync(sdk.io) catch {
                failure = error.SyncFailed;
            };
            sdk.filesystem().closeChecked(file) catch {
                failure = error.CloseFailed;
            };
            self.receipt = null;
        }
        if (failure) |err| return err;
    }

    fn evalFile(self: *Session, name: []const u8) !void {
        const input = try sdk.filesystem().openContained("/host", name[6..], .read);
        var opened = true;
        defer if (opened) sdk.filesystem().closeChecked(input) catch {};
        try self.resources();
        const buffer = try self.runtime.allocate(qjs.limits.source);
        defer self.runtime.release(buffer);
        const source = try sdk.io_helpers.readBounded(input, sdk.io, buffer);
        try sdk.filesystem().closeChecked(input);
        opened = false;
        try self.notice("qjs: file-ready\n");
        if (!try self.evaluate(source, name, false)) return error.EvaluationFailed;
    }

    fn repl(self: *Session) !void {
        const name = "/dev/tty";
        const fd = sdk.native.call(23, .{ @intFromPtr(name.ptr), name.len, 3, 0, 0, 0 });
        if (fd < 0 or fd >= 8) return error.TerminalUnavailable;
        self.tty = @intCast(fd);
        try self.resources();
        if (sdk.native.call(67, .{ 1, 0, 0, 0, 0, 0 }) != 0) return error.TerminalUnavailable;
        self.attached = true;
        const line = try self.runtime.allocate(qjs.limits.line);
        defer self.runtime.release(line);
        var used: usize = 0;
        var draining = false;
        var idle = self.runtime.control.clock.counter(self.runtime.control.clock.context);
        try self.ready();
        while (true) {
            if (self.queue_read == self.queued) {
                self.queue_read = 0;
                self.queued = 0;
                _ = poll(self);
                if (self.io_failure) |err| return err;
                if (self.queued == 0) {
                    try self.runtime.control.checkIdle(idle);
                    _ = sdk.native.call(2, .{ 0, 0, 0, 0, 0, 0 });
                    continue;
                }
            }
            // Poll removes Ctrl-C during active eval. At line input it is
            // read explicitly below so a partial line is discarded.
            const byte = self.queue[self.queue_read];
            self.queue_read += 1;
            idle = self.runtime.control.clock.counter(self.runtime.control.clock.context);
            if (byte == 3) {
                used = 0;
                draining = false;
                try self.notice("qjs: LineCancelled\n");
                try self.ready();
            } else if (byte == 4 and used == 0 and !draining) {
                break;
            } else if (byte == '\n' or byte == '\r') {
                if (draining or self.queue_overflow) {
                    self.queue_overflow = false;
                    self.runtime.control.recovered();
                    try self.notice("qjs: LineLimit\n");
                } else if (std.mem.eql(u8, line[0..used], ":quit")) {
                    break;
                } else if (std.mem.eql(u8, line[0..used], ":reset")) {
                    try self.runtime.reset();
                    try self.notice("qjs: ContextReset\n");
                } else if (used != 0) {
                    _ = try self.evaluate(line[0..used], "repl", true);
                }
                used = 0;
                draining = false;
                try self.ready();
            } else if (byte == 8 or byte == 127) {
                if (!draining and used != 0) used -= 1;
            } else if (!draining) {
                if (used == line.len) {
                    draining = true;
                } else {
                    line[used] = byte;
                    used += 1;
                }
            }
        }
        try self.notice("qjs: quit\n");
    }

    fn ready(self: *Session) !void {
        var message: [64]u8 = undefined;
        try self.notice(try std.fmt.bufPrint(&message, "qjs: ready eval={d}\n", .{self.runtime.control.evals}));
    }
};

fn run(args: *const sdk.startup.Startup) !void {
    const options = policy.parse(args.args[0..args.argc], args.env[0..args.envc]) catch |err|
        fail(@errorName(err), 64);
    if (!@import("build_options").engine) return;
    try sdk.initialize(qjs.limits.arena);
    const arena = sdk.currentArena();
    const base = arena.used();
    const runtime = try qjs.Runtime.create(arena, try qjs.nativeClock());
    var alive = true;
    defer if (alive) runtime.destroy() catch {};
    const queue = try runtime.allocate(qjs.limits.line + 1);
    var session: Session = .{ .runtime = runtime, .queue = queue };
    var status: u8 = 0;
    if (options.receipt) |name| session.openReceipt(name) catch |err| {
        session.close() catch {};
        runtime.release(queue);
        try runtime.destroy();
        alive = false;
        fail(@errorName(err), 70);
    };
    const operation = if (options.repl) session.repl() else session.evalFile(options.script.?);
    operation catch |err| {
        status = 70;
        var message: [96]u8 = undefined;
        session.terminal(std.fmt.bufPrint(&message, "qjs: {s}\n", .{@errorName(err)}) catch unreachable) catch {};
    };
    var summary: [192]u8 = undefined;
    const row = try std.fmt.bufPrint(&summary, "status={d} evals={d} source={d} output={d} diagnostics={d} receipt={d}\n", .{ status, runtime.control.evals, runtime.control.session_source, runtime.control.session_output, runtime.control.diagnostic_bytes, runtime.control.receipt_bytes });
    session.mirror('Z', row) catch {
        status = 70;
    };
    session.close() catch |err| {
        try sdk.console.writeAll(diagnosticChunk, @errorName(err));
        try sdk.console.writeAll(diagnosticChunk, "\n");
        status = 70;
    };
    const diagnostic_left = qjs.limits.diagnostics - runtime.control.diagnostic_bytes;
    runtime.release(queue);
    runtime.destroy() catch |err| {
        alive = false;
        fail(@errorName(err), 70);
    };
    alive = false;
    if (arena.used() != base or sdk.filesystem().liveFiles() != 0) return error.ResourceLeak;
    const final_stack = sdk.stackHighWater();
    if (final_stack > qjs.limits.stack) return error.StackLimit;
    var final_buffer: [160]u8 = undefined;
    const final = try std.fmt.bufPrint(&final_buffer, "qjs: final stack={d} arena_peak={d} files=0\nqjs: clean\n", .{ final_stack, arena.peak() });
    if (final.len > diagnostic_left) return error.DiagnosticLimit;
    try sdk.console.writeAll(diagnosticChunk, final);
    sdk.finish(status);
}
