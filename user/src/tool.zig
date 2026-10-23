//! census (M188e, #3190): TOOL.BIN — gate-referenced: live-sh-tools, live-trust-grants.
//! TOOL.BIN — the M49 SD3 (#1130) standalone busybox-style multicall.
//!
//! One freestanding EL0 binary, many tools: the first argument selects from
//! `head`, `tail`, `wc`, `grep`, `sort`, `cut`, `test`, `[` and `printf`,
//! and the rest are the tool's arguments. Standard input is the kernel pipe
//! (slots 56/57, fed by the shell's `|`/`<` handling); file arguments are
//! read through the existing host-share file ABI; stdout is the raw serial
//! console (the EL0 external-app convention).
//!
//! The engine itself is `lib/toolbox.zig` — the same code `SH.BIN`/`TERM.BIN`
//! run as builtins, so the standalone and in-shell behaviour cannot drift.
//! `SH.BIN head FILE` does NOT exec this binary (builtins capture into pipes
//! and redirection); `exec TOOL.BIN head FILE` runs the same logic out of
//! process, which is the honest busybox shape.
//!
//! Markers are single writes (SMP-heartbeat safe): `tool: ready`, then the
//! tool's output, then `tool: done status=N`.

const std = @import("std");
const ui = @import("lib/ui.zig");
const abi = @import("lib/ui/abi.zig");
const toolbox = @import("lib/toolbox.zig");

pub const ready_marker: []const u8 = "tool: ready\n";
pub const done_marker: []const u8 = "tool: done status=";
pub const max_args: usize = 12;
// M71m (#1572) grew the kernel's argv slots to 256 B (kernel/src/exec.zig
// arg_slot_bytes) and this stayed 32 -- so every argument past argv[0]
// read zero padding inside slot 0. Observed #1648: `exec TOOL.BIN wc -l
// DATA.TXT` arrived as two empty strings (`wc: : no such file`, done
// status=1), which never matched the gate's `tool: done status=0` chain
// trigger and kept live-sh-tools red. Must mirror exec.zig exactly.
pub const arg_bytes: usize = 256;

fn pipeStream() toolbox.Stream {
    const S = struct {
        fn read(ctx: ?*anyopaque, buf: []u8) usize {
            _ = ctx;
            const n = abi.pipe_read(buf);
            if (n <= 0) return 0;
            return @intCast(n);
        }
    };
    return .{ .read_fn = S.read };
}

fn consoleWriter() toolbox.Writer {
    const W = struct {
        fn write(ctx: ?*anyopaque, bytes: []const u8) void {
            _ = ctx;
            ui.write_console(bytes);
        }
    };
    return .{ .write_fn = W.write };
}

fn toolOpen(ctx: ?*anyopaque, name: []const u8) u64 {
    _ = ctx;
    const r = abi.file_open(name, abi.MODE_READ);
    if (r < 0) return 0;
    // Handles are encoded +1 so a valid fd 0 is not mistaken for "absent".
    return @intCast(r + 1);
}

fn toolRead(ctx: ?*anyopaque, handle: u64, buf: []u8) usize {
    _ = ctx;
    const n = abi.file_read(@intCast(handle - 1), buf);
    if (n <= 0) return 0;
    return @intCast(n);
}

fn toolClose(ctx: ?*anyopaque, handle: u64) void {
    _ = ctx;
    abi.file_close(@intCast(handle - 1));
}

fn toolStat(ctx: ?*anyopaque, name: []const u8) u8 {
    _ = ctx;
    const r = abi.file_open(name, abi.MODE_READ);
    if (r < 0) return 0;
    abi.file_close(@intCast(r));
    return 1;
}

fn hostSeam() toolbox.Host {
    return .{
        .open_fn = toolOpen,
        .read_fn = toolRead,
        .close_fn = toolClose,
        .stat_fn = toolStat,
    };
}

fn usage() void {
    ui.write_console("tool: usage: TOOL.BIN <head|tail|wc|grep|sort|cut|test|[|printf> [args...]\n");
}

pub export fn _start(argc: usize, argv: ?[*]const [arg_bytes]u8) callconv(.c) noreturn {
    ui.write_console(ready_marker);
    if (argc == 0 or argv == null) {
        usage();
        ui.exit_process(2);
    }
    const slots = argv.?;
    const n = @min(argc, max_args);
    var args: [max_args][]const u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const len = std.mem.indexOfScalar(u8, &slots[i], 0) orelse arg_bytes;
        args[i] = slots[i][0..len];
    }
    const tool = toolbox.lookup(args[0]) orelse {
        usage();
        ui.exit_process(2);
    };
    const status = toolbox.run(tool, args[0..n], pipeStream(), hostSeam(), consoleWriter());
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}{d}\n", .{ done_marker, status }) catch "tool: done\n";
    ui.write_console(msg);
    ui.exit_process(status);
}
