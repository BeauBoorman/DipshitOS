//! Decoupled unit tests for kernel monitor (M41 TS4, #955)

const std = @import("std");
const builtin = @import("builtin");
const monitor = @import("monitor");
const console = monitor.console;
const gic = monitor.gic;
const handoff = monitor.handoff;
const mailbox = monitor.mailbox;
const memmap = monitor.memmap;
const mmu = monitor.mmu;
const pci = monitor.pci;
const process = monitor.process;
const scheduler = monitor.scheduler;
const syscall = monitor.syscall;
const timer = monitor.timer;
const uaccess = monitor.uaccess;
const virtio_file = monitor.virtio_file;
const csprng = monitor.csprng;
const clipboard = monitor.clipboard;
const virtio_net = monitor.virtio_net;
const virtio_gpu = monitor.virtio_gpu;
const virtio_snd = monitor.virtio_snd;
const fbtext = monitor.fbtext;
const xhci = monitor.xhci;
const input = monitor.input;
const settings = monitor.settings;
const dns = monitor.dns;
const events = monitor.events;
const secret = monitor.secret;
const tombstone = monitor.tombstone;

// Monitor types and symbols
const Monitor = monitor.Monitor;
const Command = monitor.Command;
const Category = monitor.Category;
const ExecError = monitor.ExecError;
const MachineResult = monitor.MachineResult;
const MachineControl = monitor.MachineControl;
const MockMachineControl = monitor.MockMachineControl;
const BootMessages = monitor.BootMessages;
const lookup = monitor.lookup;
const exec = monitor.exec;
const alloc = monitor.alloc;
const esp_exec = monitor.esp_exec;
const complete = monitor.complete;
const ensure_registry = monitor.ensure_registry;
const category_order = monitor.category_order;
const category_name = monitor.category_name;
const max_args_limit = monitor.max_args_limit;
const repeat_max_count = monitor.repeat_max_count;
const repeat_max_bytes = monitor.repeat_max_bytes;
const beans_max_count = monitor.beans_max_count;
const random_max_bytes = monitor.random_max_bytes;
const elephant_lines = monitor.elephant_lines;
const sexiburger_lines = monitor.sexiburger_lines;
const net_dhcp_autonomous = monitor.net_dhcp_autonomous;
const banner = monitor.banner;
const fmtDropLine = monitor.fmtDropLine;

// ===========================================================================
// Tests (host-side; no hardware, no Virtualization.framework)
// ===========================================================================

fn make_handoff() handoff.HandoffV2 {
    return .{
        .magic = handoff.magic,
        .version = handoff.version,
        .kernel_base = 0x7e4df000,
        .kernel_size = 0x823e8,
        .system_table = 0xfeed000,
        .image_handle = 0x2,
        .stack_base = 0x7e520000,
        .stack_size = handoff.expected_stack_size,
        .flags = 0,
    };
}

const MapFixture = struct {
    descriptors: [6]memmap.MemoryDescriptor,
    view: memmap.MapView,

    fn init() MapFixture {
        var f: MapFixture = undefined;
        f.descriptors = .{
            .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 960, .attribute = 0 },
            .{ .type = .loader_code, .physical_start = 0x7000000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
            .{ .type = .boot_services_data, .physical_start = 0x8000000, .virtual_start = 0, .number_of_pages = 128, .attribute = 0 },
            .{ .type = .runtime_services_data, .physical_start = 0x9000000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0 },
            .{ .type = .memory_mapped_io, .physical_start = 0x1000000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
            .{ .type = .reserved_memory_type, .physical_start = 0x1ff00000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
        };
        f.view = memmap.MapView.init(std.mem.asBytes(&f.descriptors), @sizeOf(memmap.MemoryDescriptor), f.descriptors.len);
        f.view.key = 0x42;
        f.view.descriptor_version = 2;
        return f;
    }
};

const TestEnv = struct {
    // 12288: the `help` listing of the full command registry must fit with its
    // footer. This buffer is a capture bound, not a design limit — the real
    // console writes one line per command into the TX ring, so the listing has
    // no total-size ceiling there — and it was at 8192 since the registry held
    // 46 commands. At 76 (#1278 added `forensics`) the listing no longer fit
    // and the footer was silently dropped, which is what this bound now needs
    // headroom for: a new command grows the listing, so leave slack rather than
    // re-tuning this to the exact byte count every time.
    mock: console.MockConsole(12288) = .{},
    machine: MockMachineControl = .{},
    fixture: MapFixture = undefined,

    fn init() TestEnv {
        var env = TestEnv{};
        env.fixture = MapFixture.init();
        return env;
    }

    fn monitor(self: *TestEnv) Monitor {
        return Monitor.init(
            self.mock.console(),
            .{ .handoff = make_handoff(), .map = self.fixture.view, .console_name = "mock" },
            self.machine.control(),
        );
    }
};

// A concurrent writer may acquire the transport between any two writes.
// Inject one complete foreign line at exactly those boundaries.
const InterleavingConsole = struct {
    mock: console.MockConsole(16384) = .{},
    fragments: usize = 0,

    const vtable = console.Console.VTable{
        .write = write,
        .flush = flush,
        .readByte = read,
    };

    fn handle(self: *InterleavingConsole) console.Console {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const self: *InterleavingConsole = @ptrCast(@alignCast(ctx));
        if (!std.mem.endsWith(u8, bytes, "\n")) self.fragments += 1;
        self.mock.console().puts(bytes);
        self.mock.console().puts("counter: alive\n");
    }

    fn flush(_: *anyopaque) void {}
    fn read(_: *anyopaque) ?u8 {
        return null;
    }
};

const RecordingConsole = struct {
    mock: console.MockConsole(256) = .{},
    writes: usize = 0,

    const vtable = console.Console.VTable{
        .write = write,
        .flush = flush,
        .readByte = read,
    };

    fn handle(self: *RecordingConsole) console.Console {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const self: *RecordingConsole = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        self.mock.console().write(bytes);
    }

    fn flush(_: *anyopaque) void {}
    fn read(_: *anyopaque) ?u8 {
        return null;
    }
};

test "monitor: tabwm startup is exactly one complete console write" {
    try arm_allocator(&gap_test_ram);
    mmu.reset();
    _ = scheduler.init();
    defer uaccess.init();
    const image = one_segment_gap_elf(0x30_0000);
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("TABWM.BIN", &image);
    var env = TestEnv.init();
    var mon = env.monitor();
    var recorded = RecordingConsole{};
    mon.console = recorded.handle();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "tabwm", "start" }));
    try std.testing.expectEqualStrings("tabwm: starting TABWM.BIN\n", recorded.mock.contents());
    try std.testing.expectEqual(@as(usize, 1), recorded.writes);
}

test "monitor: accounting rows survive a foreign write at every boundary (#1965)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    _ = scheduler.init();
    mmu.reset();
    const pid = process.create("COUNTER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{ .stack_va = 0x1a400000, .stack_len = 8192 }, .{}).?;
    try std.testing.expect(process.bind(pid, 2));
    try std.testing.expect(process.setrlimit(pid, 0, 64));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"procs"}));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"resources"}));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"addrspaces"}));
    const expected = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, expected, "resources: pid=0 COUNTER.BIN\n  mem=0/64 cpu=0/unlimited\n") != null);

    var interleaved = InterleavingConsole{};
    mon.console = interleaved.handle();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"procs"}));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"resources"}));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"addrspaces"}));
    try std.testing.expectEqual(@as(usize, 0), interleaved.fragments);
    try std.testing.expect(!interleaved.mock.overflowed);
    var restored: [12288]u8 = undefined;
    var used: usize = 0;
    var lines = std.mem.splitScalar(u8, interleaved.mock.contents(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.eql(u8, line, "counter: alive")) continue;
        @memcpy(restored[used..][0..line.len], line);
        used += line.len;
        restored[used] = '\n';
        used += 1;
    }
    try std.testing.expectEqualStrings(expected, restored[0..used]);
}

test "monitor: smp names a primary exec task by its process, not its generic TCB (#1965)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    _ = scheduler.init();
    const task = scheduler.spawn("user-exec", 0x2000, scheduler.spsr_el0t_irqs, &scheduler.worker_stack, 0, 0).?;
    const pid = process.create("GOSCALE.ELF", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    try std.testing.expect(process.bind(pid, task));
    try std.testing.expect(scheduler.pin_task(task, 1));
    try std.testing.expectEqual(@as(?usize, task), scheduler.ring_claim(1, scheduler.idle_id));
    scheduler.tasks[task].state = .running;
    const old_current = scheduler.current[1];
    const old_online = scheduler.smp.core_online[1];
    const old_cores = scheduler.smp.num_cores;
    scheduler.current[1] = task;
    scheduler.smp.core_online[1] = true;
    scheduler.smp.num_cores = 2;
    defer scheduler.current[1] = old_current;
    defer scheduler.smp.core_online[1] = old_online;
    defer scheduler.smp.num_cores = old_cores;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"smp"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "task=GOSCALE.ELF\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "task=user-exec") == null);
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "task=shell\n") != null);
}

fn test_syscall_writer(_: []const u8) void {}

test "monitor: command lookup" {
    try std.testing.expect(lookup("echo") != null);
    try std.testing.expectEqualStrings("echo", lookup("echo").?.name);
    try std.testing.expect(lookup("beans") != null);
    try std.testing.expect(lookup("help") != null);
    try std.testing.expect(lookup("frobnicate") == null);
}

test "monitor: tab completion completes command names and sub-verbs (ADR 0008 D2)" {
    // Unique command-name completion: "ver" -> "sion".
    try std.testing.expectEqualStrings("sion", complete("ver", 3).?);
    // Ambiguous command prefix: "s" matches several commands -> null.
    try std.testing.expect(complete("s", 1) == null);
    // No match -> null.
    try std.testing.expect(complete("zz", 2) == null);
    // Sub-verb completion on the second token: "net t" -> "cp".
    try std.testing.expectEqualStrings("cp", complete("net t", 5).?);
    // "text c" -> "lear" (clear); a sub-verb with no match -> null.
    try std.testing.expectEqualStrings("lear", complete("text c", 6).?);
    try std.testing.expect(complete("dui z", 5) == null);
    // `help <topic>` completes against the topic pages.
    try std.testing.expectEqualStrings("etworking", complete("help n", 6).?);
    // Empty token -> null.
    try std.testing.expect(complete("", 0) == null);
}

test "monitor: mbox dumps pending messages and drain counters" {
    // Card 3f (claim 5965): the `mbox [<pid>]` monitor view. Rings are
    // seeded directly here (the live send/recv flow is the class-B gate);
    // the dump proves pending depth, the sent/recv drain counters, the
    // single-pid view, and the exact refusals.
    mailbox.init();
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("mbox") != null);
    try std.testing.expectEqualStrings("per-process IPC mailbox: pending messages and drain counters", lookup("mbox").?.help);
    // The pids are whatever `process.create` returns (earlier tests may
    // already occupy low ids — never assume a fixed pid).
    const counter_pid = process.create("COUNTER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    _ = mailbox.send(counter_pid, "ipc: ping 1\n");
    _ = mailbox.send(counter_pid, "ipc: ping 2\n");
    _ = mailbox.send(peer_pid, "ipc: ping 3\n");
    mailbox.drop(peer_pid); // the peer consumed one: recv=1
    _ = mailbox.send(peer_pid, "ipc: ping 4\n"); // then a fresh send: sent=2, pending=1
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"mbox"}));
    const out = env.mock.contents();
    const counter_row = std.fmt.allocPrint(std.testing.allocator, "mbox: id={d} name=COUNTER.BIN pending=2 sent=2 recv=0\n", .{counter_pid}) catch unreachable;
    defer std.testing.allocator.free(counter_row);
    const peer_row = std.fmt.allocPrint(std.testing.allocator, "mbox: id={d} name=PEER.BIN pending=1 sent=2 recv=1\n", .{peer_pid}) catch unreachable;
    defer std.testing.allocator.free(peer_row);
    try std.testing.expect(std.mem.indexOf(u8, out, counter_row) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mbox:   0: ipc: ping 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mbox:   1: ipc: ping 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, peer_row) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mbox:   0: ipc: ping 4\n") != null);
    // Single-pid view.
    env.mock.reset();
    const single_arg = std.fmt.allocPrint(std.testing.allocator, "{d}", .{counter_pid}) catch unreachable;
    defer std.testing.allocator.free(single_arg);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "mbox", single_arg }));
    const single = env.mock.contents();
    // The single-pid view prints exactly the counter's row (the same
    // formatted row asserted above) and nothing for the peer.
    try std.testing.expect(std.mem.indexOf(u8, single, counter_row) != null);
    try std.testing.expect(std.mem.indexOf(u8, single, "name=PEER.BIN") == null);
    // Unknown and malformed pids refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "mbox", "7" }));
    try std.testing.expectEqualStrings("error: mbox: no such process: 7\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "mbox", "nope" }));
    try std.testing.expectEqualStrings("error: mbox: invalid pid: nope\n", env.mock.contents());
}

test "monitor: registry is well-formed" {
    const reg = ensure_registry();
    try std.testing.expect(reg.len >= 10);
    for (reg, 0..) |cmd, index| {
        try std.testing.expect(cmd.name.len > 0);
        try std.testing.expect(cmd.help.len > 0);
        try std.testing.expect(cmd.usage.len > 0);
        try std.testing.expect(cmd.min_args <= cmd.max_args);
        try std.testing.expect(cmd.max_args <= max_args_limit);
        for (reg[0..index]) |other| {
            try std.testing.expect(!std.mem.eql(u8, cmd.name, other.name));
        }
    }
}

// M73f-2 (#1632): the `tty` drop-counter line — pure formatter pinned for
// shape and width; the class-B serial assert matches this line after real
// activity, and the registry entry keeps it reachable from `help`.
test "monitor: fmtDropLine shape + widths + registry entry (tty drop counters)" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "tty[0]: out_dropped=0 in_dropped=0\n",
        fmtDropLine(&buf, 0, 0, 0),
    );
    try std.testing.expectEqualStrings(
        "tty[3]: out_dropped=18446744073709551615 in_dropped=4294967296\n",
        fmtDropLine(&buf, 3, std.math.maxInt(u64), 4294967296),
    );
    var found = false;
    for (ensure_registry()) |cmd| {
        if (std.mem.eql(u8, cmd.name, "tty")) found = true;
    }
    try std.testing.expect(found);
}

test "monitor: every misusable command prints exactly the D3 misuse shape (registry walk)" {
    // ADR 0008 D3: misuse is `usage: <cmd> <args>` PLUS a one-line hint,
    // and "a new command that prints a fourth shape fails CI". A curated
    // list of commands cannot enforce that — a command added later would
    // simply not be on it. This walks the registry instead, so the
    // enforcement covers every present and future command.
    //
    // Only INVALID arities are fed: `exec` checks arity before dispatch, so
    // no handler body runs and the walk has no side effects.
    var env = TestEnv.init();
    var mon = env.monitor();
    const filler = [_][]const u8{ "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0" };
    var argv_buf: [max_args_limit + 2][]const u8 = undefined;
    var checked: usize = 0;
    for (ensure_registry()) |*cmd| {
        // Too FEW arguments (only possible when the command requires some).
        if (cmd.min_args > 0) {
            env.mock.reset();
            argv_buf[0] = cmd.name;
            try std.testing.expectEqual(ExecError.usage, exec(&mon, argv_buf[0..1]));
            try expectMisuseShape(env.mock.contents(), cmd);
            checked += 1;
        }
        // Too MANY arguments (only possible below the global token limit).
        if (cmd.max_args < max_args_limit) {
            env.mock.reset();
            argv_buf[0] = cmd.name;
            const extra = @as(usize, cmd.max_args) + 1;
            for (0..extra) |i| argv_buf[1 + i] = filler[i];
            try std.testing.expectEqual(ExecError.usage, exec(&mon, argv_buf[0 .. 1 + extra]));
            try expectMisuseShape(env.mock.contents(), cmd);
            checked += 1;
        }
    }
    // The walk is only evidence if it actually exercised commands.
    try std.testing.expect(checked >= 20);
}

/// Assert one misuse transcript is EXACTLY shape 1: the registry's usage
/// line, then the registry's blurb as the hint, and nothing else.
fn expectMisuseShape(out: []const u8, cmd: *const Command) !void {
    var buf: [1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "usage: {s}\n{s}\n", .{ cmd.usage, cmd.help });
    try std.testing.expectEqualStrings(expected, out);
}

test "monitor: every REFUSAL wears a D3 shape (registry x garbage argv)" {
    // ADR 0008 D3's CI clause: "a new command that prints a fourth shape
    // fails CI". A no-panic fuzz cannot enforce that, and a curated list of
    // commands silently exempts whatever is added next -- which is how
    // `mbox` (claim 5965, added after U3's sweep) came to print a bare
    // `mbox: invalid pid: ...` line. This walks the registry with garbage
    // argv and shape-checks EVERY line of output from any invocation that
    // actually refused. Invocations that succeed are skipped: an honest
    // STATUS report is not a D3 shape and is not meant to be.
    var env = TestEnv.init();
    var mon = env.monitor();
    // Side-effecting commands are excluded by name: they reboot, spawn,
    // write, or consume entropy rather than refuse.
    const skip = [_][]const u8{
        "reboot", "shutdown", "spawn",  "kill", "exec", "write",
        "mount",  "fault",    "random", "time",
    };
    const garbage = [_][]const u8{ "zzz", "-1", "0x", "99999999999999999999", "" };
    var refusals: usize = 0;
    for (ensure_registry()) |*cmd| {
        var skipped = false;
        for (skip) |s| {
            if (std.mem.eql(u8, s, cmd.name)) skipped = true;
        }
        if (skipped) continue;
        for (garbage) |g| {
            var argv: [3][]const u8 = .{ cmd.name, g, g };
            const n: usize = if (cmd.max_args >= 2) 3 else if (cmd.max_args >= 1) 2 else 1;
            env.mock.reset();
            const rc = exec(&mon, argv[0..n]);
            if (rc == .none) continue;
            refusals += 1;
            var it = std.mem.splitScalar(u8, env.mock.contents(), '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                const ok = std.mem.startsWith(u8, line, "usage: ") or
                    std.mem.startsWith(u8, line, "error: ") or
                    std.mem.startsWith(u8, line, "unknown command '") or
                    std.mem.eql(u8, line, cmd.help); // the shape-1 hint line
                if (!ok) {
                    std.debug.print("non-D3 line from `{s} {s}`: {s}\n", .{ cmd.name, g, line });
                    return error.FourthShape;
                }
            }
        }
    }
    try std.testing.expect(refusals >= 10);
}

test "monitor: dispatch-level refusals wear a sanctioned D3 prefix" {
    // The shell's own diagnostics are not exempt from D3: an empty line and
    // an over-long argv are failures, so they take shape 2 rather than a
    // bare sentence (which is what a fourth shape looks like in practice).
    var env = TestEnv.init();
    var mon = env.monitor();
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{}));
    try std.testing.expectEqualStrings("error: no command given; type 'help' for a list of commands\n", env.mock.contents());
    env.mock.reset();
    var many: [max_args_limit + 2][]const u8 = undefined;
    for (&many) |*slot| slot.* = "x";
    try std.testing.expectEqual(ExecError.usage, exec(&mon, many[0..]));
    try std.testing.expectEqualStrings("error: too many arguments (max 17 tokens)\n", env.mock.contents());
}

test "monitor: help listing is generated from the registry" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"help"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "available commands:") != null);
    for (ensure_registry()) |cmd| {
        try std.testing.expect(std.mem.indexOf(u8, out, cmd.name) != null);
        try std.testing.expect(std.mem.indexOf(u8, out, cmd.help) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "type 'help <command>' for details on a single command.") != null);
}

test "monitor: help for a specific command" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "echo" }));
    try std.testing.expectEqualStrings("echo - repeat your regrettable decisions\nusage: echo <text...>\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "help", "bogus" }));
    try std.testing.expectEqualStrings("error: no such command or topic: bogus\n", env.mock.contents());
}

test "monitor: help opens topic pages (and commands win over topics)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    // Each documented topic opens its page, headered by the topic name.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "networking" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "networking\n"));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "virtio-net (DID 0x1041)") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "windows" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "windows\n"));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "storage" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "storage\n"));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "graphics" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "graphics\n"));
    // `syscalls` and `input` are commands, not topics: their detail wins.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "syscalls" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "syscalls - "));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "input" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "input - "));
}

test "monitor: help listing is grouped by category in the ADR 0008 order" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"help"}));
    const out = env.mock.contents();
    // Group headers appear in the fixed D1 order.
    var prev: usize = 0;
    for (category_order) |cat| {
        // Headers sit at the start of a line; a bare substring search would
        // collide with help text (e.g. "system" inside `about`), so anchor on
        // the newline before and after the header.
        var buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\n{s}\n", .{category_name(cat)}) catch unreachable;
        const idx = std.mem.indexOf(u8, out, needle) orelse
            return error.TestExpectedEqual;
        try std.testing.expect(idx >= prev);
        prev = idx;
    }
    // The footer still names the topic surface.
    try std.testing.expect(std.mem.indexOf(u8, out, "type 'help <topic>' for a topic page") != null);
}

test "monitor: pci command reports no-ECAM honestly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"pci"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "pci: ecam=0x0000000000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pci: no ECAM") != null);
}

test "monitor: unknown command is diagnosed" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.unknown_command, exec(&mon, &.{"frobnicate"}));
    try std.testing.expectEqualStrings("unknown command 'frobnicate' -- try 'help'\n", env.mock.contents());
}

test "monitor: empty and over-long argv" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "no command given") != null);
}

test "monitor: argument-count validation" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{"hex"}));
    try std.testing.expectEqualStrings("usage: hex <number>...\nformat an integer in hexadecimal\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{"repeat"}));
    try std.testing.expectEqualStrings("usage: repeat <count> <text...>\nrepeat text, safely bounded\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "beans", "1", "2" }));
    try std.testing.expectEqualStrings("usage: beans [count]\ncount beans, probably\n", env.mock.contents());
}

// Monitor-test mock transport for the armed netsend path (the virtio_net
// module's own tests cover the same path with their fuller mock; here the
// fake device completes every TX by advancing the driver's real used ring
// on the kick, so the full build -> submit -> drain -> report shape runs on
// the host).
fn mnet_dev_read32(_: u32) u32 {
    return 0;
}
fn mnet_cfg_read8(_: u32) u8 {
    return 0;
}
fn mnet_cfg_read16(_: u32) u16 {
    return 0;
}
fn mnet_cfg_read32(_: u32) u32 {
    return 0;
}
fn mnet_cfg_write8(_: u32, _: u8) void {}
fn mnet_cfg_write16(_: u32, _: u16) void {}
fn mnet_cfg_write32(_: u32, _: u32) void {}
fn mnet_notify(_: u16) void {
    // The fake device completes the TX: advance the driver's real used
    // ring so the drain poll sees the completion.
    virtio_net.net_dev.tx_used.idx +%= 1;
}
fn mnet_to_phys(va: usize) u64 {
    return va; // host test: identity
}
fn mnet_clean(_: usize, _: usize) void {}
fn mnet_invalidate(_: usize, _: usize) void {}

fn mnet_ops() virtio_net.Ops {
    return .{
        .dev_read32 = mnet_dev_read32,
        .cfg_read8 = mnet_cfg_read8,
        .cfg_read16 = mnet_cfg_read16,
        .cfg_read32 = mnet_cfg_read32,
        .cfg_write8 = mnet_cfg_write8,
        .cfg_write16 = mnet_cfg_write16,
        .cfg_write32 = mnet_cfg_write32,
        .notify = mnet_notify,
        .to_phys = mnet_to_phys,
        .clean = mnet_clean,
        .invalidate = mnet_invalidate,
    };
}

test "monitor: net reports no device honestly when the transport is absent" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = false;
    virtio_net.net_devcfg_mac_seen = false;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"net"}));
    try std.testing.expectEqualStrings(
        "net: no virtio-net device (DID 0x1041 not found on bus 0)\n" ++
            "net: device-features=0x0000000000000000/0x0000000000000000\n" ++
            "net: status=0x00000000000000ff accepted=0x0000000000000000/0x0000000000000000\n" ++
            "net: common=0x0000000000000000 notify=0x0000000000000000 devcfg=0x0000000000000000 bar0=0x0000000000000000\n",
        env.mock.contents(),
    );
    // `net` is registered (the prompt's registry-row shape).
    try std.testing.expect(lookup("net") != null);
    try std.testing.expectEqualStrings("virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS + IPv6/NDP: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records; 'net ip6' shows the SLAAC address set; 'net ndp [<v6-addr>]' shows/resolves the NDP table; 'net ping6 <v6-addr>' sends an ICMPv6 echo request)", lookup("net").?.help);
    try std.testing.expect(lookup("netsend") != null);
}

test "monitor: screen reports no device honestly when the transport is absent" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ready = virtio_gpu.gpu_ready;
    defer virtio_gpu.gpu_ready = saved_ready;
    virtio_gpu.gpu_ready = false;
    virtio_gpu.gpu_fail = "";
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"screen"}));
    try std.testing.expectEqualStrings(
        "screen: no virtio-gpu device (DID 0x1050 not found on bus 0)\n" ++
            "screen: device-features=0x0000000000000000/0x0000000000000000\n" ++
            "screen: status=0x00000000000000ff accepted=0x0000000000000000/0x0000000000000000\n" ++
            "screen: common=0x0000000000000000 notify=0x0000000000000000 devcfg=0x0000000000000000 bar0=0x0000000000000000\n",
        env.mock.contents(),
    );
    // `screen fill` is refused honestly with no transport.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "screen", "fill", "0x112233" }));
    try std.testing.expectEqualStrings("error: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    // An out-of-range color is refused honestly even before the transport
    // check.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "screen", "fill", "0x1000000" }));
    try std.testing.expectEqualStrings("error: color out of range (max 0xffffff)\n", env.mock.contents());
    // `screen` is registered (the registry-row shape).
    try std.testing.expect(lookup("screen") != null);
    try std.testing.expectEqualStrings("virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)", lookup("screen").?.help);
}

test "monitor: text reports the region and refuses put/clear without the transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ready = virtio_gpu.gpu_ready;
    defer virtio_gpu.gpu_ready = saved_ready;
    virtio_gpu.gpu_ready = false;
    // The report is device-independent: it names the region + cursor.
    fbtext.init();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"text"}));
    try std.testing.expectEqualStrings(
        "text: rows=90 cols=160 cell=8x8 cur=0,0 lines=0 fg=0x000000000000ff00 bg=0x0000000000101418\n",
        env.mock.contents(),
    );
    // `text put` / `text clear` are refused honestly with no transport.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "text", "put", "hello" }));
    try std.testing.expectEqualStrings("error: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "text", "clear" }));
    try std.testing.expectEqualStrings("error: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    // An unknown subcommand is refused honestly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "text", "bogus" }));
    // `text` is registered (the registry-row shape).
    try std.testing.expect(lookup("text") != null);
    try std.testing.expectEqualStrings("framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears; 'text putraw' skips the trailing newline; 'text fontdebug [on|off]' missing-glyph stats)", lookup("text").?.help);
}

test "monitor: roadpops reports the tee state honestly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    // The global tee is unarmed in host tests → serial-only degradation
    // (the default VM's behavior).
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"roadpops"}));
    try std.testing.expectEqualStrings("roadpops: armed=0 dirty=0 presents=0\n", env.mock.contents());
    // `roadpops` is registered (the registry-row shape).
    try std.testing.expect(lookup("roadpops") != null);
    try std.testing.expectEqualStrings("Road Pops framebuffer console: armed/dirty/present counters (the boot terminal on the screen)", lookup("roadpops").?.help);
}

test "monitor: usb reports no device honestly when the XHCI transport is absent" {
    var env = TestEnv.init();
    var mon = env.monitor();
    xhci.xhci_ready = false;
    xhci.xhci_fail = "";
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"usb"}));
    try std.testing.expectEqualStrings("usb: no XHCI device (DID 0x1a06 not found on bus 0)\n", env.mock.contents());
    // `usb` is registered (the registry-row shape).
    try std.testing.expect(lookup("usb") != null);
    try std.testing.expectEqualStrings("XHCI host controller: `usb` transport report, `usb devices` enumerated devices, `usb report` last HID report, `usb bulk [probe ...]` bulk engine (U1), `usb msc [probe] [lba]` mass-storage BOT/SCSI probe (U2), `usb vol` MBR partition + FAT32 volume enumeration, `usb ls <vol>[/<dir>]` volume directory listing, `usb cat <vol>/<path> [<max>]` read-only file read (full byte count + FNV-1a 32 of every byte) (M70f F1), `usb rescan` polled lifecycle rescan (U4), `usb detach [slot]` administrative detach (U4)", lookup("usb").?.help);
}

test "monitor: net report shape with an armed transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    // Populate the driver state as the live init + re-arm would: observed
    // DID 0x1041, class 0x020000, dev 6, the host-set MAC from the feature
    // path, VER1|MAC negotiated, both queues armed, DRIVER_OK (0xf) after
    // the re-arm, one drained TX of 46 bytes.
    virtio_net.net_ready = true;
    virtio_net.net_rearmed = true;
    virtio_net.net_did = 0x1041;
    virtio_net.net_class = 0x020000;
    virtio_net.net_dev_no = 6;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.net_mac_source = .feature;
    virtio_net.format_mac(&virtio_net.net_mac, &virtio_net.net_mac_text);
    virtio_net.net_dev.feats_lo = 0x20;
    virtio_net.net_dev.feats_hi = 0x1;
    virtio_net.net_dev.q0_enabled = true;
    virtio_net.net_dev.q1_enabled = true;
    virtio_net.net_status_last = 0xf;
    virtio_net.net_dev.tx_frames = 1;
    virtio_net.net_dev.tx_bytes = 46;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"net"}));
    const out = env.mock.contents();
    // The grep-able shape the live gate asserts (full 16-digit hex, the
    // mbox/procs observability shape).
    try std.testing.expect(std.mem.indexOf(u8, out, "net: did=0x0000000000001041 class=0x0000000000020000 dev=6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net: mac=02:00:00:00:00:01 source=feature\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net: feat=0x0000000000000020/0x0000000000000001 q0=rx:size=4 q1=tx:size=4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net: status=0x000000000000000f rearm=1 tx=frames=1,bytes=46\n") != null);
    // The fallback source is reported honestly too.
    env.mock.reset();
    virtio_net.net_mac_source = .fallback;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"net"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "source=fallback") != null);
    // Card N3: the ARP layer line (static IP + counters) is part of the
    // report — 0.0.0.0 when unset, the counters reported honestly.
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.requests_sent = 2;
    virtio_net.arp.replies_sent = 3;
    virtio_net.arp.replies_learned = 1;
    virtio_net.arp.dropped = 4;
    virtio_net.arp.reply_tx_fail = 0;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"net"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net: ip=10.0.0.1 arp=req=2,repl=3,learn=1,drop=4,fail=0\n") != null);
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.net_ready = false;
}

test "monitor: net ip sets the static address and echoes the marker" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ip", "10.0.0.1" }));
    try std.testing.expectEqualStrings("net ip: ip=10.0.0.1\n", env.mock.contents());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 1 }, &virtio_net.arp.own_ip);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "ip", "999.0.0.1" }));
    try std.testing.expectEqualStrings("error: invalid address: 999.0.0.1\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "net", "ip" }));
    try std.testing.expectEqualStrings("usage: net [recv|ip <addr>|arp [<addr>]|ping <addr>|udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]|dhcp|tcp [connect <addr> <port>|send <len>|recv|close|reset]|dns <host> [<server>]|ip6|ndp [<v6-addr>]|ping6 <v6-addr>]\nvirtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS + IPv6/NDP: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records; 'net ip6' shows the SLAAC address set; 'net ndp [<v6-addr>]' shows/resolves the NDP table; 'net ping6 <v6-addr>' sends an ICMPv6 echo request)\n", env.mock.contents());
    // The echo line is the live gate's injection trigger marker.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ip", "10.0.0.2" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net ip: ip=10.0.0.2\n") != null);
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
}

test "monitor: net arp prints the table + counters" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = true;
    virtio_net.rx_armed = false; // the drain is a no-op without a supplied buffer
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
    virtio_net.arp.upsert(.{ 10, 0, 0, 2 }, .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    virtio_net.arp.requests_sent = 1;
    virtio_net.arp.replies_sent = 0;
    virtio_net.arp.replies_learned = 1;
    virtio_net.arp.dropped = 0;
    virtio_net.arp.reply_tx_fail = 0;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "arp" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "net arp: entries=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net arp: 10.0.0.2 -> 02:00:00:00:00:02\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net arp: req=1,repl=0,learn=1,drop=0,fail=0\n") != null);
    // A table hit reports the peer without sending anything.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "arp", "10.0.0.2" }));
    try std.testing.expectEqualStrings("net arp: 10.0.0.2 is at 02:00:00:00:00:02\n", env.mock.contents());
    virtio_net.net_ready = false;
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
}

test "monitor: net arp resolve — miss sends the request, no-IP refuses honestly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
    virtio_net.arp.requests_sent = 0;
    virtio_net.net_dev = .{};
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "arp", "10.0.0.2" }));
    try std.testing.expectEqualStrings("net arp: request for 10.0.0.2 sent (42 bytes)\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.arp.requests_sent);
    // Without a static IP the resolve is refused honestly (no 0.0.0.0
    // sender — we cannot answer for an address we do not own).
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "arp", "10.0.0.3" }));
    try std.testing.expectEqualStrings("error: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.arp.requests_sent); // nothing sent
    // Malformed addresses refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "arp", "nope" }));
    try std.testing.expectEqualStrings("error: invalid address: nope\n", env.mock.contents());
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: net ping sends an echo request to a resolved peer" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
    virtio_net.arp.upsert(.{ 10, 0, 0, 2 }, .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    virtio_net.ipv4.requests_sent = 0;
    virtio_net.ipv4.ping_seq = 1;
    virtio_net.net_dev = .{};
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ping", "10.0.0.2" }));
    try std.testing.expectEqualStrings("net ping: echo request to 10.0.0.2 sent (46 bytes)\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.ipv4.requests_sent);
    try std.testing.expectEqual(@as(u16, 2), virtio_net.ipv4.ping_seq);
    // A peer NOT in the ARP table refuses honestly (an echo needs a
    // unicast dst — `net arp <ip>` resolves first).
    env.mock.reset();
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ping", "10.0.0.3" }));
    try std.testing.expectEqualStrings("error: peer not in ARP table (net arp <a.b.c.d> first)\n", env.mock.contents());
    // Without a static IP the ping is refused honestly.
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ping", "10.0.0.2" }));
    try std.testing.expectEqualStrings("error: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
    // Malformed addresses refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "ping", "nope" }));
    try std.testing.expectEqualStrings("error: invalid address: nope\n", env.mock.contents());
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: net udp — listen, close, and the report" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    try std.testing.expectEqualStrings("net udp: listening on 7000\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp: entries=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp: port=7000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp: rx=0,tx=0,loop=0,drop=0\n") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "close", "7000" }));
    try std.testing.expectEqualStrings("net udp: closed 7000\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "close", "7000" }));
    try std.testing.expectEqualStrings("error: not listening on 7000\n", env.mock.contents());
    // A duplicate listen and a malformed port refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    try std.testing.expectEqualStrings("error: listen failed (table full or duplicate)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "listen", "nope" }));
    try std.testing.expectEqualStrings("error: invalid port: nope\n", env.mock.contents());
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "listen", "70000" }));
}

test "monitor: net udp send — loopback to our own IP, no device" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.net_ready = false; // the loopback path must NOT need a device
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.1", "7000", "4" }));
    try std.testing.expectEqualStrings("net udp: sent 4 bytes to 10.0.0.1:7000 (12 bytes)\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.sent);
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.loopbacked);
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.received);
    // The loopbacked datagram is observable via net udp recv.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "recv", "7000" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp recv: port=7000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp recv: [0] len=12\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1b 58 1b 58 00 0c ") != null); // src 7000, dst 7000, len 12
    // A loopback to a CLOSED port is dropped (counted), never assumed away.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.1", "9998", "1" }));
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.dropped_closed);
    // Without a static IP the send is refused honestly.
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "4" }));
    try std.testing.expectEqualStrings("error: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
}

test "monitor: net udp send — to a resolved peer on the mock transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
    virtio_net.arp.upsert(.{ 10, 0, 0, 2 }, .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.net_dev = .{};
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "4" }));
    try std.testing.expectEqualStrings("net udp: sent 4 bytes to 10.0.0.2:9999 (46 bytes)\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.sent);
    try std.testing.expectEqual(@as(u64, 0), virtio_net.udp.loopbacked);
    // An unresolved peer refuses honestly (an echo/udp needs a unicast dst).
    env.mock.reset();
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.3", "9999", "4" }));
    try std.testing.expectEqualStrings("error: peer not in ARP table (net arp <a.b.c.d> first)\n", env.mock.contents());
    // Length bounds refuse exactly (M99i #2187 raised payload_max to 512,
    // so 65 is a legal length now and 513 is the first refusal).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "0" }));
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "513" }));
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.arp.table = @as([virtio_net.arp.table_slots]virtio_net.arp.ArpEntry, @splat(@as(virtio_net.arp.ArpEntry, .{})));
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: netsend refuses cleanly without a transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = false;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "netsend", "32" }));
    try std.testing.expectEqualStrings("error: transport not ready (no virtio-net device)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "netsend", "abc" }));
    try std.testing.expectEqualStrings("error: invalid byte count: abc\n", env.mock.contents());
}

test "monitor: netsend builds + submits a known frame (armed, mock transport)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    // Reset the driver's TX counters/rings so earlier tests' state cannot
    // leak into the exact assertions.
    virtio_net.net_dev = .{};
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "netsend", "32" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "netsend: n=32\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "netsend: tx ok frames=1 bytes=46\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "netsend: sent 46 bytes\n") != null);
    // Over-limit requests truncate honestly at the 1500-byte payload bound.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "netsend", "5000" }));
    const out2 = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out2, "netsend: n=5000 truncated to 1500 (payload bound)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "netsend: tx ok frames=2 bytes=1514\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "netsend: sent 1514 bytes\n") != null);
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: net recv prints the received frame byte-exact and drains the FIFO" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = true;
    virtio_net.net_fail = "";
    virtio_net.rx_fifo_head = 0;
    virtio_net.rx_fifo_count = 0;
    // The claim-time RX contract: the OBSERVED 12-byte virtio_net_hdr
    // (all zero except num_buffers=1 at bytes 10-11) + a 46-byte
    // broadcast frame (dst ff*6, src 02:00:00:00:00:01, ethertype 0x0800,
    // payload 00..1f) — the exact layout the class-B gate pins from
    // observation (net recv prints the RAW device-written bytes).
    var frame: [virtio_net.rx_buf_len]u8 = @splat(0);
    frame[10] = 0x01; // virtio_net_hdr num_buffers = 1 (observed)
    const dst = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const src = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    @memcpy(frame[virtio_net.rx_hdr_len .. virtio_net.rx_hdr_len + 6], &dst);
    @memcpy(frame[virtio_net.rx_hdr_len + 6 .. virtio_net.rx_hdr_len + 12], &src);
    frame[virtio_net.rx_hdr_len + 12] = 0x08;
    frame[virtio_net.rx_hdr_len + 13] = 0x00;
    var i: usize = 0;
    while (i < 32) : (i += 1) frame[virtio_net.rx_hdr_len + 14 + i] = @truncate(i);
    try std.testing.expect(virtio_net.fifo_push(frame[0 .. virtio_net.rx_hdr_len + 46]));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "recv" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "net recv: frames=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net recv: [0] len=58\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net recv: 00 00 00 00 00 00 00 00 00 00 01 00 ff ff ff ff ff ff 02 00 00 00 00 01 08 00 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f\n") != null);
    // Consumed: the FIFO is empty again (recv drains it).
    try std.testing.expectEqual(@as(usize, 0), virtio_net.fifo_occupancy());
    // Empty case: honest report.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "recv" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net recv: frames=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net recv: no frames (filtered or nothing injected)\n") != null);
    // Unknown subcommand: documented refusal.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "net", "bogus" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "usage: net [recv|ip <addr>|arp [<addr>]|ping <addr>|udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]|dhcp|tcp [connect <addr> <port>|send <len>|recv|close|reset]|dns <host> [<server>]|ip6|ndp [<v6-addr>]|ping6 <v6-addr>]\nvirtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS + IPv6/NDP: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records; 'net ip6' shows the SLAAC address set; 'net ndp [<v6-addr>]' shows/resolves the NDP table; 'net ping6 <v6-addr>' sends an ICMPv6 echo request)\n") != null);
    virtio_net.net_ready = false;
    virtio_net.rx_fifo_head = 0;
    virtio_net.rx_fifo_count = 0;
}

test "monitor: identity commands produce fixed output" {
    var env = TestEnv.init();
    var mon = env.monitor();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"version"}));
    try std.testing.expectEqualStrings(
        "virelai-kernel\nmilestone-two kernel proper (ADR 0004)\nhandoff ABI v2\nbuild label: m1.5 commands & personality (mock console)\n",
        env.mock.contents(),
    );
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"uname"}));
    try std.testing.expectEqualStrings("VirelaiOS aarch64\nfreestanding kernel; no POSIX compatibility\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"about"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "from-scratch AArch64 operating system") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "no libc, no POSIX") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Apple Virtualization.framework") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Driving Award") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Type 'help' for the grouped command catalog, or 'welcome' for a tour.") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"welcome"}));
    const tour_out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "Welcome to VirelaiOS!") != null);
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "1. Discovery: Type 'help'") != null);
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "docs/") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"tour"}));
    try std.testing.expectEqualStrings(tour_out, env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sysinfo"}));
    const sys_out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "sysinfo: VirelaiOS AArch64 support snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "kernel=virelai-kernel handoff=v2 status=valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "arch=aarch64") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "descriptors=") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "scheduler:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "processes:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "storage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "network:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "graphics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "input:") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"settings"}));
    const set_out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, set_out, "settings:") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_out, "hostname=") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_out, "prompt=") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "settings", "get", "hostname" }));
    try std.testing.expectEqualStrings("settings: hostname=virelai\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "settings", "set", "hostname", "testnode" }));
    try std.testing.expectEqualStrings("settings: hostname=testnode (memory only)\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "settings", "get", "hostname" }));
    try std.testing.expectEqualStrings("settings: hostname=testnode\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "settings", "reset" }));
    try std.testing.expectEqualStrings("settings: reset to defaults (memory only)\n", env.mock.contents());
    env.mock.reset();
}

test "monitor: secrets lists NAMES only and never mutates (M50 TS5 #1139)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(secret.LoadResult.ok, secret.parse(
        "#v1\n" ++
            "netkey\t1000\tsupersecretvalue\n" ++
            "audkey\t0\tsystemsecretvalue\n",
    ));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"secrets"}));
    const out = env.mock.contents();
    // NAMES are listed, for both principals.
    try std.testing.expect(std.mem.indexOf(u8, out, "secrets:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  netkey\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  audkey\n") != null);
    // VALUES never appear in the monitor output (the never-logged contract).
    try std.testing.expect(std.mem.indexOf(u8, out, "supersecretvalue") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "systemsecretvalue") == null);
    env.mock.reset();

    // The command never mutates the store: it is still intact after a call.
    var recs: [secret.max_secret_entries]secret.SecretRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), secret.records_for(.{ .uid = process.uid_user }, &recs));
    try std.testing.expectEqualStrings("netkey", recs[0].key[0..recs[0].key_len]);

    // Empty store: an honest `(none)`, and an argument is a usage error.
    secret.init();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"secrets"}));
    try std.testing.expectEqualStrings("secrets: (none)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "secrets", "netkey" }));
}

test "monitor: redaction — secret VALUES absent from procs + tombstones while NAMES show (D8)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(secret.LoadResult.ok, secret.parse("#v1\nnetkey\t1000\tsupersecretvalue\n"));

    // The `procs` report (the registry view behind the sys_procs snapshot)
    // never carries the value.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"procs"}));
    const procs_out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, procs_out, "supersecretvalue") == null);
    env.mock.reset();

    // A crash tombstone whose serial snapshot captured the monitor `secrets`
    // output — the NAME may appear there, the VALUE must not.
    tombstone.init();
    const snap = "secrets:\n  netkey\n"; // exactly what `secrets` prints
    tombstone.record("CRASH.BIN", 7, 139, 0, 0, snap, snap.len);
    var tbuf: [tombstone.tombstone_max_bytes]u8 = undefined;
    const tlen = tombstone.format_tombstone(tombstone.get(0).?, &tbuf);
    const report = tbuf[0..tlen];
    try std.testing.expect(std.mem.indexOf(u8, report, "netkey") != null); // name present
    try std.testing.expect(std.mem.indexOf(u8, report, "supersecretvalue") == null); // value absent
}

test "monitor: handoff formatting is deterministic and validated" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"handoff"}));
    try std.testing.expectEqualStrings(
        "handoff v4\n" ++
            "  magic        0x00000000324b5344\n" ++
            "  version      0x0000000000000004\n" ++
            "  kernel_base  0x000000007e4df000\n" ++
            "  kernel_size  0x00000000000823e8\n" ++
            "  system_table 0x000000000feed000\n" ++
            "  image_handle 0x0000000000000002\n" ++
            "  stack_base   0x000000007e520000\n" ++
            "  stack_size   0x0000000000004000\n" ++
            "  flags        0x0000000000000000\n" ++
            "  boot_epoch   0xffffffffffffffff\n" ++
            "  measured_ok  0x0000000000000000\n" ++
            "  loader_sha256 0000000000000000000000000000000000000000000000000000000000000000\n" ++
            "  kernel_sha256 0000000000000000000000000000000000000000000000000000000000000000\n" ++
            "  status       valid\n",
        env.mock.contents(),
    );

    // A corrupted handoff is reported, not silently trusted.
    const fixture = MapFixture.init();
    var bad = make_handoff();
    bad.magic = 0xdeadbeef;
    var mon2 = Monitor.init(
        env.mock.console(),
        .{ .handoff = bad, .map = fixture.view, .console_name = "mock" },
        env.machine.control(),
    );
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon2, &.{"handoff"}));
    try std.testing.expect(std.mem.endsWith(u8, env.mock.contents(), "  status       invalid (bad magic)\n"));
}

test "monitor: mem summarizes the captured map deterministically" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"mem"}));
    try std.testing.expectEqualStrings(
        "mem: descriptors=0x0000000000000006 size=0x0000000000000028 version=0x0000000000000002 key=0x0000000000000042\n" ++
            "  usable: 0x0000000000480000 bytes (0x0000000000000480 pages)\n" ++
            "  conventional: 0x00000000003c0000 bytes (0x00000000000003c0 pages)\n" ++
            "  loader: 0x0000000000040000 bytes (0x0000000000000040 pages)\n" ++
            "  boot_services: 0x0000000000080000 bytes (0x0000000000000080 pages)\n" ++
            "  runtime: 0x0000000000008000 bytes (0x0000000000000008 pages)\n" ++
            "  reserved: 0x0000000000009000 bytes (0x0000000000000009 pages)\n" ++
            "  mmio: 0x0000000000010000 bytes (0x0000000000000010 pages)\n" ++
            "  kernel: 0x000000007e4df000..0x000000007e5613e8 (0x00000000000823e8 bytes)\n",
        env.mock.contents(),
    );
}

test "monitor: mem handles an overflowing handoff without wrapping" {
    var env = TestEnv.init();
    var bad = make_handoff();
    bad.kernel_base = std.math.maxInt(u64) - 0xfff;
    bad.kernel_size = 0x2000; // base + size overflows u64
    var mon = Monitor.init(
        env.mock.console(),
        .{ .handoff = bad, .map = env.fixture.view, .console_name = "mock" },
        env.machine.control(),
    );
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"mem"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "  kernel: 0xfffffffffffff000..0xffffffffffffffff") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0x0000000000002000 bytes") != null);
}

test "monitor: echo joins arguments" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "echo", "hello", "world" }));
    try std.testing.expectEqualStrings("hello world\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"echo"}));
    try std.testing.expectEqualStrings("\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "echo", "a", "", "b" }));
    try std.testing.expectEqualStrings("a  b\n", env.mock.contents());
}

test "monitor: clear emits the documented ANSI sequence" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"clear"}));
    try std.testing.expectEqualStrings("\x1b[2J\x1b[H", env.mock.contents());
}

test "monitor: hex parses and formats with explicit errors" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "hex", "255" }));
    try std.testing.expectEqualStrings("0xff\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "hex", "0xff", "0X10", "0" }));
    try std.testing.expectEqualStrings("0xff\n0x10\n0x0\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "zz" }));
    try std.testing.expectEqualStrings("error: invalid number: zz\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "-1" }));
    try std.testing.expectEqualStrings("error: invalid number: -1\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "18446744073709551616" }));
    try std.testing.expectEqualStrings("error: invalid number: 18446744073709551616\n", env.mock.contents());
}

test "monitor: repeat enforces count and byte bounds" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "2", "hello", "world" }));
    try std.testing.expectEqualStrings("hello world\nhello world\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "1", "x" }));
    try std.testing.expectEqualStrings("x\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "0", "x" }));
    try std.testing.expectEqualStrings("error: count must be between 1 and 64\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "65", "x" }));
    try std.testing.expectEqualStrings("error: count must be between 1 and 64\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "zz", "x" }));
    try std.testing.expectEqualStrings("error: invalid count: zz\n", env.mock.contents());
    env.mock.reset();
    // Count with no text repeats blank lines, deterministically.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "3" }));
    try std.testing.expectEqualStrings("\n\n\n", env.mock.contents());

    // 70-char line: 57 repetitions fit (57*71 = 4047 <= 4096), 58 do not.
    const long = &@as([70:0]u8, @splat("a"[0]));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "57", long }));
    try std.testing.expectEqual(@as(usize, 57 * 71), env.mock.contents().len);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "58", long }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "error: output too large (max 4096 bytes)") != null);
}

test "monitor: reboot and shutdown through a mock machine control" {
    var env = TestEnv.init();
    env.machine.reboot_result = .ok;
    env.machine.shutdown_result = .ok;
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"reboot"}));
    try std.testing.expectEqualStrings("reboot: ok\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"shutdown"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "shutdown: ok") != null);
    try std.testing.expectEqual(@as(usize, 1), env.machine.reboot_calls);
    try std.testing.expectEqual(@as(usize, 1), env.machine.shutdown_calls);
}

test "monitor: machine control failures are reported honestly" {
    var env = TestEnv.init();
    env.machine.reboot_result = .not_implemented;
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"reboot"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "reboot: not implemented") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "no proven post-ExitBootServices machine-control mechanism") != null);

    env.machine.reboot_result = .failed;
    env.mock.reset();
    try std.testing.expectEqual(ExecError.machine_failed, exec(&mon, &.{"reboot"}));
    try std.testing.expectEqualStrings("error: reboot: failed\n", env.mock.contents());
}

test "monitor: disabled machine control is the honest default" {
    var mock = console.MockConsole(4096){};
    const fixture = MapFixture.init();
    var mon = Monitor.init(
        mock.console(),
        .{ .handoff = make_handoff(), .map = fixture.view, .console_name = "mock" },
        MachineControl.disabled(),
    );
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"shutdown"}));
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "shutdown: not implemented") != null);
}

test "monitor: elephant is deterministic and reports diagnostics" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"elephant"}));
    const first = env.mock.contents();
    try std.testing.expect(std.mem.startsWith(u8, first, elephant_lines()[0]));
    const expected_tail = "ELEPHANT ONLINE\n" ++
        "  trunk: up\n" ++
        "  ears: floppy\n" ++
        "  console: mock\n" ++
        "  handoff: valid\n" ++
        "  memory: descriptors=0x0000000000000006\n";
    try std.testing.expect(std.mem.endsWith(u8, first, expected_tail));

    // Same input, same output: fully deterministic.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"elephant"}));
    try std.testing.expectEqualStrings(first, env.mock.contents());
}

test "monitor: sexiburger is deterministic and reports diagnostics" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sexiburger"}));
    const first = env.mock.contents();
    try std.testing.expect(std.mem.startsWith(u8, first, sexiburger_lines()[0]));
    const expected_tail = "SEXIBURGER ONLINE\n" ++
        "  mascot: Sexipus (hexapus clade)\n" ++
        "  tentacles: 6 (3 left, 3 right, lower pair curling inward)\n" ++
        "  layers: 6 (Crown, Lettuce, Tomato, Cheese, Patty, Heel)\n" ++
        "  covenant: the tentacle count is load-bearing\n" ++
        "  status: all 6 invariants intact\n";
    try std.testing.expect(std.mem.endsWith(u8, first, expected_tail));

    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sexiburger"}));
    try std.testing.expectEqualStrings(first, env.mock.contents());
}

test "monitor: beans is deterministic and bounded" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"beans"}));
    try std.testing.expectEqualStrings(
        "beans\ncounting beans... 42 beans in a trench coat.\nthat's it. that's the command.\n",
        env.mock.contents(),
    );
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "beans", "7" }));
    try std.testing.expectEqualStrings(
        "beans\ncounting beans... 7 beans in a trench coat.\nthat's it. that's the command.\n",
        env.mock.contents(),
    );
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "beans", "0" }));
    try std.testing.expectEqualStrings("error: beans: count must be between 1 and 100\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "beans", "101" }));
    try std.testing.expectEqualStrings("error: beans: count must be between 1 and 100\n", env.mock.contents());
}

test "monitor: random prints a deterministic hex line from the seeded CSPRNG and bounds count" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("random") != null);
    try std.testing.expectEqualStrings("print n random bytes from the seeded CSPRNG (hex)", lookup("random").?.help);
    // Seed with a fixed value so the output is deterministic in the test.
    csprng.seed(&@as([csprng.seed_len]u8, @splat(@as(u8, 0x5a))));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "random", "32" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.startsWith(u8, out, "random: n=32 hex="));
    const hex = out["random: n=32 hex=".len..];
    // 64 hex chars then the line terminator.
    try std.testing.expectEqual(@as(usize, 65), hex.len);
    try std.testing.expectEqual(@as(u8, '\n'), hex[64]);
    for (hex[0..64]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
    // No-arg prints the fixed 16-byte sample (32 hex chars).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"random"}));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "random: n=16 hex="));
    // Bounds: 1..256.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "random", "0" }));
    try std.testing.expectEqualStrings("random: count must be between 1 and 256\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "random", "257" }));
    try std.testing.expectEqualStrings("random: count must be between 1 and 256\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "random", "zz" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "random: invalid count: "));
}

test "monitor: fault is registered and honestly reports no vectors in a test process" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("fault") != null);
    try std.testing.expectEqualStrings("trigger a synchronous exception (diagnostic)", lookup("fault").?.help);
    // Test processes never install the vectors (even on an aarch64 host,
    // where executing `udf` would SIGILL); the command must say so and must
    // not fault the test process.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"fault"}));
    try std.testing.expectEqualStrings(
        "fault: exception vectors not installed; nothing to trigger\n",
        env.mock.contents(),
    );
}

test "monitor: timer is registered and reports the unarmed host state" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("timer") != null);
    try std.testing.expectEqualStrings("interrupt controller + timer status", lookup("timer").?.help);
    // In a test process the GIC/timer are never programmed (the init paths
    // are aarch64-only); the command must report the honest unarmed state
    // with the conventional PPI default.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"timer"}));
    try std.testing.expectEqualStrings(
        "timer: armed=0 gic=none dist=0x0 ppi=0x1e freq=0x0 ticks=0 irq=0 poll=0 deadline_irqs=0 resched_requests=0 resched_coalesced=0 resched_discharged=0 acked=0 first=0xffffffff\n",
        env.mock.contents(),
    );
}

test "monitor: tasks is registered and reports the deterministic host state" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("tasks") != null);
    try std.testing.expectEqualStrings("tick-driven task scheduler status", lookup("tasks").?.help);
    // Register the tasks exactly as kernel_main does (the idle task is
    // scheduler-owned and auto-registered by init); without `start` the
    // scheduler never preempts, so every counter reads 0 — the same shape
    // a live boot reports once ticks begin.
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"tasks"}));
    try std.testing.expectEqualStrings(
        "tasks: enabled=0 current=0 switches=0 pool=4/64 zombies=0\n" ++
            "  shell    saves=0 resumes=0 advances=0 state=ready\n" ++
            "  worker   saves=0 resumes=0 advances=0 state=ready\n" ++
            "  user-el0 saves=0 resumes=0 advances=0 state=ready\n" ++
            "  idle     saves=0 resumes=0 advances=0 state=ready\n",
        env.mock.contents(),
    );
}

test "monitor: resources audits the fixed pools at their bounds (C3 claim 0339)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("resources") != null);
    try std.testing.expectEqualStrings("fixed-pool audit: scheduler tasks, process registry, windows, page-table carve-out, and per-process ring bounds", lookup("resources").?.help);
    // Reset the pools the way kernel_main + a fresh boot do (scheduler.init
    // also clears the process registry; mmu.reset clears the table cursor),
    // then register the same shell/worker/user shape the `tasks` test uses.
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    mmu.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"resources"}));
    const out = env.mock.contents();
    // The occupancy lines are exact (4 tasks, 0 procs, 0 tables); the
    // windows line only asserts the shape (other tests in this binary may
    // have armed the window manager, leaving a non-zero win_count).
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: tasks=4/64 zombies=0\n") != null);
    // register_user also registers the boot payload as a PROCESS (claim
    // 3848), so the registry holds exactly one descriptor here.
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: procs=1/64\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: windows=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/64\n") != null); // M129b: 3 kernel + 61 user
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: tables=0/512\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: events=64 mbox=32 fds=8 timers=1 tcp=1\n") != null);
}

test "monitor: procs reports the process table with lifecycle and exit status" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("procs") != null);
    try std.testing.expectEqualStrings("process registry: image, address space, lifecycle, exit status", lookup("procs").?.help);
    // Seed the registry deterministically: an EXITED boot payload (status 7,
    // executor reaped) and a RUNNING exec'd program bound to task 2 — the
    // exact two-process table a live boot shows right after `exec`.
    process.init();
    const p0 = process.create("user-el0", .{ .entry_va = 0x400000, .content_len = 0x100 }, .{ .stack_va = 0x80000000, .stack_len = 8192 }, .{}).?;
    _ = process.bind(p0, 2);
    _ = process.on_task_exit(2, 7);
    _ = process.take_exit_report();
    const p1 = process.create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{ .stack_va = 0x1a400000, .stack_len = 8192 }, .{}).?;
    _ = process.bind(p1, 2);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"procs"}));
    // The exited process keeps its status past the executor's reap; the
    // running one shows its bound task and stack VA.
    try std.testing.expectEqualStrings(
        "procs: count=2\n" ++
            "procs: id=0 name=user-el0 uid=1000 caps=0 state=exited task=reaped stack=0x0000000080000000 exit=7\n" ++
            "procs: id=1 name=USER.BIN uid=1000 caps=0 state=running task=2 stack=0x000000001a400000 exit=-\n",
        env.mock.contents(),
    );
}

test "monitor: live runtime receipts retain identity and peaks across exit and resource release" {
    var env = TestEnv.init();
    var mon = env.monitor();
    process.init();
    const pid = process.create("GOSTRESS.ELF", .{}, .{ .text_len = 4097, .data_len = 1 }, .{}).?;
    try std.testing.expect(process.bind(pid, 2));
    try std.testing.expect(process.record_dynamic_page(pid, 0));
    try std.testing.expect(process.record_dynamic_page(pid, 0));
    try std.testing.expect(process.add_mmap_region(pid, 0x10000000, 4096, 3, 0));
    try std.testing.expect(process.add_mmap_region(pid, 0x10001000, 4096, 3, 0));
    try std.testing.expect(process.remove_mmap_region(pid, 0x10000000, 4096));
    const live = "runtime-receipt: pid=0 name=GOSTRESS.ELF peak_pages=2 page_cap=4096 peak_regions=2 region_cap=16 static_pages=3 page_tracking=extensible page_saturated=0 total_pages=2 record_failures=0 unrecorded_pages=0 reaped=0\n";
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt" }));
    try std.testing.expectEqualStrings(live, env.mock.contents());
    const before = process.runtime_receipt(pid).?;
    _ = process.on_task_exit(2, 0);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "0" }));
    try std.testing.expectEqualStrings(live, env.mock.contents()); // exited, not yet task-reaped
    try std.testing.expect(process.release_pages_on_reap(2));
    try std.testing.expectEqualDeep(before, process.runtime_receipt(pid).?);
    const expected = "runtime-receipt: pid=0 name=GOSTRESS.ELF peak_pages=2 page_cap=4096 peak_regions=2 region_cap=16 static_pages=3 page_tracking=extensible page_saturated=0 total_pages=2 record_failures=0 unrecorded_pages=0 reaped=1\n";
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "GOSTRESS.ELF" }));
    try std.testing.expectEqualStrings(expected, env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "0" }));
    try std.testing.expectEqualStrings(expected, env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"procs"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "runtime-receipt:") == null);
    try std.testing.expectEqualStrings("procs", lookup("procs").?.usage);
    try std.testing.expectEqualStrings("process registry: image, address space, lifecycle, exit status", lookup("procs").?.help);
    try std.testing.expect(process.reap(pid));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt" }));
    try std.testing.expectEqualStrings("runtime-receipt: none\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "GOSTRESS.ELF" }));
    try std.testing.expectEqualStrings("runtime-receipt: none\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "procs", "bogus" }));
    try std.testing.expectEqualStrings("usage: procs\nprocess registry: image, address space, lifecycle, exit status\n", env.mock.contents());
}

test "monitor: sibling exits keep saturated live receipts unreaped until the last task is reaped" {
    const Capture = struct {
        mock: console.MockConsole(4096) = .{},
        all_locked: bool = true,
        const vtable = console.Console.VTable{ .write = write, .flush = flush, .readByte = read };
        fn write(ctx: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.all_locked = self.all_locked and monitor.svclock.kernel.held();
            self.mock.console().puts(bytes);
        }
        fn flush(_: *anyopaque) void {}
        fn read(_: *anyopaque) ?u8 {
            return null;
        }
    };
    var env = TestEnv.init();
    var mon = env.monitor();
    var capture = Capture{};
    mon.console = .{ .ctx = &capture, .vtable = &Capture.vtable };
    process.init();
    const pid = process.create("PDFPROOF.ELF", .{}, .{}, .{}).?;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "PDFPROOF.ELF" }));
    try std.testing.expectEqualStrings("runtime-receipt: none\n", capture.mock.contents()); // created
    capture.mock.reset();
    try std.testing.expect(process.bind(pid, 2));
    try std.testing.expect(process.bind_thread(pid, 3));
    for (0..process.max_dynamic_pages) |_| try std.testing.expect(process.record_dynamic_page(pid, 0));
    try std.testing.expect(process.add_mmap_region(pid, 0x10000000, 4096, 3, 0));
    const before = process.runtime_receipt(pid).?;
    const live = "runtime-receipt: pid=0 name=PDFPROOF.ELF peak_pages=4096 page_cap=4096 peak_regions=1 region_cap=16 static_pages=0 page_tracking=extensible page_saturated=1 total_pages=4096 record_failures=0 unrecorded_pages=0 reaped=0\n";
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "0" }));
    try std.testing.expectEqualStrings(live, capture.mock.contents());
    // A sibling exit does not exit or reap the process.
    try std.testing.expect(process.on_task_exit(3, 7) == null);
    try std.testing.expect(!process.release_pages_on_reap(3));
    capture.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "PDFPROOF.ELF" }));
    try std.testing.expectEqualStrings(live, capture.mock.contents());
    // Nor does a primary exit while a sibling still runs, even though its
    // task_id becomes null. The receipt must remain reaped=0.
    try std.testing.expect(process.bind_thread(pid, 3));
    try std.testing.expect(process.on_task_exit(2, 0) == null);
    try std.testing.expectEqual(process.State.running, process.info(pid).?.state);
    try std.testing.expect(process.info(pid).?.task_id == null);
    try std.testing.expect(!process.release_pages_on_reap(2));
    try std.testing.expect(process.forget_dynamic_page(pid, 0));
    try std.testing.expect(process.remove_mmap_region(pid, 0x10000000, 4096));
    capture.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "0" }));
    try std.testing.expectEqualStrings(live, capture.mock.contents()); // high-water, not live count
    try std.testing.expectEqual(@as(?usize, pid), process.on_task_exit(3, 0));
    capture.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "0" }));
    try std.testing.expectEqualStrings(live, capture.mock.contents()); // final, before reap
    try std.testing.expect(process.release_pages_on_reap(3));
    try std.testing.expectEqualDeep(before, process.runtime_receipt(pid).?);
    capture.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "procs", "receipt", "0" }));
    try std.testing.expectEqualStrings(
        "runtime-receipt: pid=0 name=PDFPROOF.ELF peak_pages=4096 page_cap=4096 peak_regions=1 region_cap=16 static_pages=0 page_tracking=extensible page_saturated=1 total_pages=4096 record_failures=0 unrecorded_pages=0 reaped=1\n",
        capture.mock.contents(),
    );
    try std.testing.expect(capture.all_locked); // handler, not dispatch's shorter scope
    try std.testing.expect(!monitor.svclock.kernel.held());
}

test "monitor: kill is registered and arms a running process by id and by name" {
    // Card 3c (claim 7786): `kill <pid|name>` resolves the process and
    // ARMS its executor task; the ring converts the next selection into
    // the existing exit path with the reserved status 137.
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("kill") != null);
    try std.testing.expectEqualStrings("terminate a running process (kernel-owned lifetime)", lookup("kill").?.help);
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    // The boot payload's process (id 0) is RUNNING on task 2; the demo
    // spawn fills slot 3 so a second process can bind a real executor.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"spawn"}));
    env.mock.reset();
    const p1 = process.create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 1), p1);
    _ = process.bind(p1, 3);
    // By id (the `procs` id).
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "kill", "0" }));
    try std.testing.expectEqualStrings("kill: user-el0 armed\n", env.mock.contents());
    // By name (the FAT file name).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "kill", "USER.BIN" }));
    try std.testing.expectEqualStrings("kill: USER.BIN armed\n", env.mock.contents());
    // The armed kill flows through the REAL lifecycle at the next ring
    // selection: user-el0 (task 2) exits with the reserved status 137.
    scheduler.start();
    try std.testing.expect(scheduler.yield_current()); // shell -> user -> killed -> spawn-demo
    try std.testing.expectEqual(@as(?u64, scheduler.reserved_kill_status), scheduler.terminated_status(2));
}

test "monitor: kill receipt survives a foreign write at every boundary" {
    for ([_][]const u8{ "INIT.ELF", "0123456789abcdef-extra" }) |name| {
        var env = TestEnv.init();
        var mon = env.monitor();
        _ = scheduler.init();
        _ = scheduler.register_worker(0);
        const task = scheduler.spawn("user-exec", 0x2000, scheduler.spsr_el0t_irqs, &scheduler.worker_stack, 0, 0).?;
        const pid = process.create(name, .{}, .{}, .{}).?;
        try std.testing.expect(process.bind(pid, task));
        const stored_name = process.info(pid).?.name;
        // The longest stored name fits the exact production buffer bound.
        try std.testing.expect(stored_name.len <= process.name_max);
        var interleaved = InterleavingConsole{};
        mon.console = interleaved.handle();
        try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "kill", stored_name }));
        var expected_buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "kill: {s} armed\ncounter: alive\n", .{stored_name});
        try std.testing.expectEqualStrings(expected, interleaved.mock.contents());
        try std.testing.expectEqual(@as(usize, 0), interleaved.fragments);
    }
}

test "monitor: kill refuses unknown, already-exited, and not-running targets exactly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    // An EXITED process (the exited state's exact refusal).
    const exited_p = process.create("BOOTED", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(exited_p, 4);
    _ = process.on_task_exit(4, 7);
    _ = process.take_exit_report();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "BOOTED" }));
    try std.testing.expectEqualStrings("error: BOOTED already exited\n", env.mock.contents());
    // A CREATED (loaded, not yet bound) process: no executor to terminate.
    env.mock.reset();
    _ = process.create("ROLLBACK.BIN", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{});
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "ROLLBACK.BIN" }));
    try std.testing.expectEqualStrings("error: ROLLBACK.BIN not running\n", env.mock.contents());
    // Unknown name and unknown numeric id.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "NOPE.BIN" }));
    try std.testing.expectEqualStrings("error: no such process: NOPE.BIN\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "9" }));
    try std.testing.expectEqualStrings("error: no such process: 9\n", env.mock.contents());
}

test "monitor: spawn is registered and reports the demo spawn or the bound" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("spawn") != null);
    try std.testing.expectEqualStrings("spawn the lifecycle demo task", lookup("spawn").?.help);
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"spawn"}));
    try std.testing.expectEqualStrings("spawn: spawn-demo id=3\n", env.mock.contents());
    // One demo spawn per boot: the second reports the bound.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"spawn"}));
    try std.testing.expectEqualStrings("spawn: pool full or demo already running\n", env.mock.contents());
}

test "monitor: syscalls is registered and reports deterministic rows" {
    var env = TestEnv.init();
    var mon = env.monitor();
    syscall.init(test_syscall_writer);
    try std.testing.expect(lookup("syscalls") != null);
    try std.testing.expectEqualStrings("numbered syscall table and counters", lookup("syscalls").?.help);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"syscalls"}));
    try std.testing.expectEqualStrings(
        "syscalls: slots=64 implemented=96\n" ++
            "  0 sys_ping calls=0\n" ++
            "  1 sys_write calls=0\n" ++
            "  2 sys_yield calls=0\n" ++
            "  3 sys_exit calls=0\n" ++
            "  4 sys_sleep calls=0\n" ++
            "  5 sys_ipc_send calls=0\n" ++
            "  6 sys_ipc_recv calls=0\n" ++
            "  7 sys_procs calls=0\n" ++
            "  8 sys_wait calls=0\n" ++
            "  9 sys_udp_listen calls=0\n" ++
            "  10 sys_udp_send calls=0\n" ++
            "  11 sys_udp_recv calls=0\n" ++
            "  12 sys_win_open calls=0\n" ++
            "  13 sys_win_fill calls=0\n" ++
            "  14 sys_win_present calls=0\n" ++
            "  15 sys_win_close calls=0\n" ++
            "  16 sys_win_move calls=0\n" ++
            "  17 sys_win_raise calls=0\n" ++
            "  18 sys_win_get calls=0\n" ++
            "  19 sys_win_query calls=0\n" ++
            "  20 sys_win_set_visible calls=0\n" ++
            "  21 sys_poll_event calls=0\n" ++
            "  22 sys_wait_event calls=0\n" ++
            "  23 sys_file_open calls=0\n" ++
            "  24 sys_file_read calls=0\n" ++
            "  25 sys_file_write calls=0\n" ++
            "  26 sys_file_close calls=0\n" ++
            "  27 sys_dir_list calls=0\n" ++
            "  28 sys_exec calls=0\n" ++
            "  29 sys_kill calls=0\n" ++
            "  30 sys_tcp_connect calls=0\n" ++
            "  31 sys_tcp_send calls=0\n" ++
            "  32 sys_tcp_recv calls=0\n" ++
            "  33 sys_tcp_close calls=0\n" ++
            "  34 sys_file_delete calls=0\n" ++
            "  35 sys_file_rename calls=0\n" ++
            "  36 sys_file_truncate calls=0\n" ++
            "  37 sys_file_free calls=0\n" ++
            "  38 sys_clipboard_set calls=0\n" ++
            "  39 sys_clipboard_get calls=0\n" ++
            "  40 sys_timer_set calls=0\n" ++
            "  41 sys_timer_cancel calls=0\n" ++
            "  42 sys_audio_info calls=0\n" ++
            "  43 sys_audio_play calls=0\n" ++
            "  44 sys_audio_volume calls=0\n" ++
            "  45 sys_audio_mute calls=0\n" ++
            "  46 sys_win_fill_batch calls=0\n" ++
            "  47 sys_win_resize calls=0\n" ++
            "  48 sys_drag_start calls=0\n" ++
            "  49 sys_win_raise_front calls=0\n" ++
            "  50 sys_win_lower_back calls=0\n" ++
            "  51 sys_notify calls=0\n" ++
            "  52 sys_win_move_to_workspace calls=0\n" ++
            "  53 sys_win_set_unsaved calls=0\n" ++
            "  54 sys_setrlimit calls=0\n" ++
            "  55 sys_drag_read calls=0\n" ++
            "  56 sys_pipe_read calls=0\n" ++
            "  57 sys_pipe_write calls=0\n" ++
            "  58 sys_font_size calls=0\n" ++
            "  59 sys_ping_send calls=0\n" ++
            "  60 sys_ping_poll calls=0\n" ++
            "  61 sys_win_set_title calls=0\n" ++
            "  62 sys_net_stats calls=0\n" ++
            "  63 sys_mmap calls=0\n" ++
            "  64 sys_munmap calls=0\n" ++
            "  65 sys_wmctl calls=0\n" ++
            "  66 sys_time calls=0\n" ++
            "  67 sys_tty_attach calls=0\n" ++
            "  68 sys_principal calls=0\n" ++
            "  69 sys_file_mode calls=0\n" ++
            "  70 sys_secret_get calls=0\n" ++
            "  71 sys_tty_net_auth calls=0\n" ++
            "  72 sys_getrandom calls=0\n" ++
            "  73 sys_thread calls=0\n" ++
            "  74 sys_futex calls=0\n" ++
            "  75 sys_exnotify calls=0\n" ++
            "  76 sys_sock_ready calls=0\n" ++
            "  77 sys_file_sync calls=0\n" ++
            "  78 sys_time_set calls=0\n" ++
            "  79 sys_fs_metadata calls=0\n" ++
            "  80 sys_socket calls=0\n" ++
            "  81 sys_trace calls=0\n" ++
            "  82 sys_profile calls=0\n" ++
            "  83 sys_memstat calls=0\n" ++
            "  84 sys_udp_send_from calls=0\n" ++
            "  85 sys_udp_recv_from calls=0\n" ++
            "  86 sys_udp_close calls=0\n" ++
            "  87 sys_getpid calls=0\n" ++
            "  88 sys_scanout_read calls=0\n" ++
            // M113c (#2419): slot 89 is implemented and reportable —
            // the grant-admin seam is a live syscall.
            "  89 sys_grant_admin calls=0\n" ++
            "  90 sys_gpucomp calls=0\n" ++
            "  91 sys_audio_rec_info calls=0\n" ++
            "  92 sys_audio_rec calls=0\n" ++
            "  93 sys_vsock_ctl calls=0\n" ++
            "  94 sys_sleep_ns calls=0\n" ++
            "  95 sys_timer_set_ns calls=0\n",
        env.mock.contents(),
    );
}

test "monitor: clip copies and pastes the shared clipboard (claim 0169)" {
    clipboard.init();
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("clip") != null);
    try std.testing.expectEqualStrings("copy/paste the shared kernel clipboard ('clip <text...>' sets it, 'clip' prints it)", lookup("clip").?.help);

    // Empty clipboard pastes the honest empty marker.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"clip"}));
    try std.testing.expectEqualStrings("clip: empty\n", env.mock.contents());

    // Copy joins args space-separated and stores them.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "clip", "hello", "world" }));
    try std.testing.expectEqualStrings("clip: stored 11 bytes\n", env.mock.contents());

    // Paste reads the SAME bytes back.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"clip"}));
    try std.testing.expectEqualStrings("clip: hello world\n", env.mock.contents());

    // A new copy overwrites; an empty-arg copy clears.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "clip", "second" }));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"clip"}));
    try std.testing.expectEqualStrings("clip: second\n", env.mock.contents());
}

test "monitor: uaccess command is honest on a host process (no vectors)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("uaccess") != null);
    try std.testing.expectEqualStrings("user-memory copy diagnostics (valid, fault, recovery)", lookup("uaccess").?.help);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"uaccess"}));
    // Host process: no regions configured and no exception vectors, so the
    // validated copy is rejected at range check and the raw probe returns
    // fault without dereferencing (recovered=0). On VZ the class-B gate
    // asserts the real recovery line instead.
    try std.testing.expectEqualStrings(
        // `unbacked` (issue #1391) counts copy-outs refused because a
        // destination page was not the process's to write: 0 is healthy.
        "uaccess: valid=0 fault=1 recovered=0 copies=0 validation_faults=1 unbacked=0\n",
        env.mock.contents(),
    );
}

test "monitor: output overflow is bounded and flagged, never fatal" {
    var small = console.MockConsole(16){};
    var machine = MockMachineControl{};
    const fixture = MapFixture.init();
    var mon = Monitor.init(
        small.console(),
        .{ .handoff = make_handoff(), .map = fixture.view, .console_name = "mock" },
        machine.control(),
    );
    const long = &@as([100:0]u8, @splat("x"[0]));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "echo", long }));
    try std.testing.expect(small.overflowed);
    try std.testing.expectEqual(@as(usize, 16), small.len);

    small.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "64", "abcdefgh" }));
    try std.testing.expect(small.overflowed);
    try std.testing.expectEqual(@as(usize, 16), small.len);
}

test "monitor: boot message selection is deterministic" {
    const msgs = BootMessages.messages();
    try std.testing.expectEqualStrings(msgs[0], BootMessages.pick(0));
    try std.testing.expectEqualStrings(msgs[1], BootMessages.pick(1));
    try std.testing.expectEqualStrings(msgs[5], BootMessages.pick(5));
    try std.testing.expectEqualStrings(msgs[0], BootMessages.pick(6));
}

test "monitor: banner is deterministic and avoids invented claims" {
    var env = TestEnv.init();
    var mon = env.monitor();
    banner(&mon);
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "VirelaiOS - AArch64 firmware-assisted kernel monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, BootMessages.messages()[2]) != null); // image_handle=2
    try std.testing.expect(std.mem.indexOf(u8, out, "Type 'help' before touching anything expensive.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "256 MiB") == null);
}

/// M34 HF6 (issue #740): monitor file-surface tests serve the in-memory
/// share override (the ESP window and FAT volume are gone). Same upsert
/// pattern as exec.zig's seam; `test_reset_share()` arms an EMPTY share
/// (honest not_found for every name), `set_test_share(null)` restores the
/// no-channel state.
var test_share_files: [8]virtio_file.TestFile = undefined;
var test_share_n: usize = 0;
fn test_seed_share(name: []const u8, content: []const u8) void {
    for (test_share_files[0..test_share_n]) |*f| {
        if (std.mem.eql(u8, f.name, name)) {
            f.* = .{ .name = name, .data = content };
            virtio_file.set_test_share(test_share_files[0..test_share_n]);
            return;
        }
    }
    if (test_share_n < test_share_files.len) {
        test_share_files[test_share_n] = .{ .name = name, .data = content };
        test_share_n += 1;
        virtio_file.set_test_share(test_share_files[0..test_share_n]);
    }
}
fn test_reset_share() void {
    test_share_n = 0;
    virtio_file.set_test_share(test_share_files[0..0]);
}

// ---------------------------------------------------------------------------
// Issue #1163 I1: single-segment GAP images (legal per elf.parse — any
// sane declared base) must not alias the text allocation into the
// data-segment descriptor. Before the fix, exec_static_elf_gap set
// .data_phys/.data_pages to segment 0's pages (a double free at reap) and
// registered the R+X text as a copy-out WRITE region.
// ---------------------------------------------------------------------------

const gap_elf_aarch64: u16 = 0xB7;

/// Build a minimal ELF64 with ONE R+X PT_LOAD at `vaddr` (the entry sits
/// in its initialized bytes) — a legal 1-segment gap image when
/// `vaddr != text_base`.
fn one_segment_gap_elf(comptime vaddr: u64) [256]u8 {
    var img = @as([256]u8, @splat(@as(u8, 0)));
    const magic4 = [4]u8{ 0x7f, 'E', 'L', 'F' };
    @memcpy(img[0..4], &magic4);
    img[4] = 2; // ELF64
    img[5] = 1; // little-endian
    img[6] = 1; // EV_CURRENT
    std.mem.writeInt(u16, img[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, img[18..20], gap_elf_aarch64, .little); // EM_AARCH64
    std.mem.writeInt(u32, img[20..24], 1, .little); // e_version
    std.mem.writeInt(u64, img[24..32], vaddr, .little); // e_entry (at code)
    std.mem.writeInt(u64, img[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, img[52..54], 64, .little); // e_ehsize
    std.mem.writeInt(u16, img[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, img[56..58], 1, .little); // e_phnum
    // phdr @64: PT_LOAD R+X, offset 120, filesz 32, memsz 32.
    std.mem.writeInt(u32, img[64..68], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, img[68..72], 5, .little); // PF_R | PF_X
    std.mem.writeInt(u64, img[72..80], 120, .little); // p_offset
    std.mem.writeInt(u64, img[80..88], vaddr, .little); // p_vaddr
    std.mem.writeInt(u64, img[96..104], 32, .little); // p_filesz
    std.mem.writeInt(u64, img[104..112], 32, .little); // p_memsz
    // Entry code at file offset 120 (mov x0, #42; ret).
    std.mem.writeInt(u32, img[120..124], 0xD2800540, .little);
    std.mem.writeInt(u32, img[124..128], 0xD65F03C0, .little);
    return img;
}

// Host-test RAM: the exec path memcpies into allocated pages through the
// identity map (phys == kernel pointer), so the fixture's "physical" base
// must be a real host-writable buffer.
var gap_test_ram: [512 * 4096]u8 align(4096) = undefined;

test "exec: single-segment gap image owns no data alias (issue #1163 I1)" {
    // Arm the physical allocator the way kernel_main does at boot (the
    // exec path allocates the program's own text/stack/kstack pages).
    var descs = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&gap_test_ram), .virtual_start = 0, .number_of_pages = 512, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descs), @sizeOf(memmap.MemoryDescriptor), descs.len);
    try std.testing.expect(alloc.init(view, &.{}));

    // A declared base != the text aperture makes the 1-segment image a
    // GAP layout (the shape the fix guards).
    const img = one_segment_gap_elf(0x30_0000);
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("GAP1.ELF", img[0..]);

    _ = scheduler.init();
    const result = esp_exec.exec_file("GAP1.ELF", &.{});
    try std.testing.expectEqual(esp_exec.ExecResult.ok, result);
    const pid = esp_exec.last_exec_pid().?;
    const info = process.info(pid).?;
    // The alias guard: the process owns its text and NOTHING else —
    // data_pages == 0 means reap frees each page exactly once.
    try std.testing.expect(info.text_pages > 0);
    try std.testing.expectEqual(@as(u64, 0), info.data_pages);
    try std.testing.expectEqual(@as(u64, 0), info.data_len);
    try std.testing.expectEqual(@as(u64, 0), info.data_phys);
}

// ---------------------------------------------------------------------------
// M70c-K (issue #1504): a gap-layout ELF larger than the 2 MiB staging
// buffer is loaded by STREAMING its segments straight from the share into
// the pages that get mapped. These tests pin the three acceptance shapes:
// a multi-MiB image loads (and its far-from-the-header bytes really arrive
// at the mapped page), a file that ends before its own header promises is
// refused by name, and a shape that still needs staging keeps its refusal.
// ---------------------------------------------------------------------------

/// RAM for the streamed-load fixture: 8 MiB of pages (the image is ~3 MiB
/// of PT_LOAD memory plus the 192 KiB task stack and its kernel twin).
var big_test_ram: [2048 * 4096]u8 align(4096) = undefined;

/// Arm the physical allocator over `ram` (the shape kernel_main sets up at
/// boot: one conventional-memory descriptor).
fn arm_allocator(ram: []u8) !void {
    var descs = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(ram.ptr), .virtual_start = 0, .number_of_pages = ram.len / 4096, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descs), @sizeOf(memmap.MemoryDescriptor), descs.len);
    try std.testing.expect(alloc.init(view, &.{}));
}

/// M70c-K fixture: an ELF32 with three PT_LOADs in the Go linker's
/// R+X / R / RW shape and a ~3 MiB read-only middle segment.
///
/// `contiguous` moves that middle segment flush against segment 0's memory
/// end, which makes the image a CONTIGUOUS shape — the streamed path must
/// not take it (it still needs the staging buffer), so the exec refuses it.
///
/// `drop_tail` returns the header and program headers only, i.e. a file
/// that ends long before the 3 MiB its own header promises.
///
/// The banner bytes (`MARK`) sit 1 MiB into the middle segment's payload —
/// far outside the 16 KiB header window, so finding them in the mapped
/// page is proof the payload was streamed from the right file offset.
const big_elf_ro_vaddr: u64 = 0x40_2000;
const big_elf_ro_filesz: usize = 0x30_0000;
const big_elf_ro_off: usize = 0x1000;
const big_elf_ro_marker: usize = 0x10_0000; // 1 MiB into the payload
/// Offset of the banner inside the DATA segment's payload (which starts at
/// `big_elf_ro_off + big_elf_ro_filesz` in the file).
const big_elf_data_marker: usize = 0x40;
const big_elf_mark = [8]u8{ 'M', '7', '0', 'c', 'K', '!', '!', '!' };
const big_elf_file_size: usize = big_elf_ro_off + big_elf_ro_filesz + 0x100;

/// The fixture buffer (module-level: a 3 MiB array must not land on a test
/// thread's stack).
var big_elf_image: [big_elf_file_size]u8 align(4096) = undefined;

fn fill_big_gap_elf(comptime contiguous: bool) void {
    const img = &big_elf_image;
    @memset(img[0..], 0);
    const magic4 = [4]u8{ 0x7f, 'E', 'L', 'F' };
    @memcpy(img[0..4], &magic4);
    img[4] = 1; // ELF32
    img[5] = 1; // little-endian
    img[6] = 1; // EV_CURRENT
    std.mem.writeInt(u16, img[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, img[18..20], 0xB7, .little); // EM_AARCH64
    std.mem.writeInt(u32, img[20..24], 1, .little); // e_version
    std.mem.writeInt(u32, img[24..28], 0x40_0000, .little); // e_entry (at the code)
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[40..42], 52, .little); // e_ehsize
    std.mem.writeInt(u16, img[42..44], 32, .little); // e_phentsize
    std.mem.writeInt(u16, img[44..46], 3, .little); // e_phnum
    // phdr 0 @52: text R+X at the fixed aperture (the kernel text base).
    std.mem.writeInt(u32, img[52..56], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, img[56..60], 148, .little); // p_offset
    std.mem.writeInt(u32, img[60..64], 0x40_0000, .little); // p_vaddr
    std.mem.writeInt(u32, img[68..72], 0x100, .little); // p_filesz
    std.mem.writeInt(u32, img[72..76], 0x1000, .little); // p_memsz
    std.mem.writeInt(u32, img[76..80], 5, .little); // PF_R | PF_X
    // phdr 1 @84: the ~3 MiB read-only middle segment.
    const ro_vaddr: u32 = if (contiguous) 0x40_1000 else @intCast(big_elf_ro_vaddr);
    std.mem.writeInt(u32, img[84..88], 1, .little);
    std.mem.writeInt(u32, img[88..92], big_elf_ro_off, .little);
    std.mem.writeInt(u32, img[92..96], ro_vaddr, .little);
    std.mem.writeInt(u32, img[100..104], @intCast(big_elf_ro_filesz), .little);
    std.mem.writeInt(u32, img[104..108], @intCast(big_elf_ro_filesz), .little);
    std.mem.writeInt(u32, img[108..112], 4, .little); // PF_R
    // phdr 2 @116: data RW. The contiguous variant sits flush against the
    // read-only segment's memory end (0x401000 + 0x300000); the gap variant
    // leaves one page between them.
    const data_vaddr: u32 = if (contiguous) 0x70_1000 else 0x70_3000;
    std.mem.writeInt(u32, img[116..120], 1, .little);
    std.mem.writeInt(u32, img[120..124], @intCast(big_elf_ro_off + big_elf_ro_filesz), .little);
    std.mem.writeInt(u32, img[124..128], data_vaddr, .little);
    std.mem.writeInt(u32, img[132..136], 0x100, .little); // p_filesz
    std.mem.writeInt(u32, img[136..140], 0x2000, .little); // p_memsz (bss tail)
    std.mem.writeInt(u32, img[140..144], 6, .little); // PF_R | PF_W
    // Segment 0's code (mov x0, #42; ret) and the marker deep inside the
    // read-only segment's payload.
    std.mem.writeInt(u32, img[148..152], 0xD2800540, .little);
    std.mem.writeInt(u32, img[152..156], 0xD65F03C0, .little);
    @memcpy(img[big_elf_ro_off + big_elf_ro_marker ..][0..big_elf_mark.len], &big_elf_mark);
    // The same banner inside the LAST (data) segment's payload, which sits
    // ~3 MiB into the file — the region whose mapped page this test can
    // read back through `ProcessInfo.data_phys`.
    @memcpy(img[big_elf_ro_off + big_elf_ro_filesz + big_elf_data_marker ..][0..big_elf_mark.len], &big_elf_mark);
}

/// Page counts the loader must take for this fixture: 1 text + 768 rodata +
/// the data segment's RESIDENT runs (1 file-backed page + the argv/envp
/// headroom page — M171a: the second image page is a demand-zero tail, not
/// allocated at exec) + the 192 KiB (48-page) task stack and its kernel twin.
const big_elf_pages = 1 + (big_elf_ro_filesz / 4096) + 1 + 1 + 48 + 48;

test "exec: a 3 MiB gap ELF streams from the share into its mapped pages (M70c-K #1504)" {
    try arm_allocator(&big_test_ram);
    fill_big_gap_elf(false);
    const img = big_elf_image[0..];
    // The fixture must really be too big for the staging buffer, or this
    // test would silently exercise the staged path instead.
    try std.testing.expect(img.len > esp_exec.exec_program_max);

    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("BIG.ELF", img);

    const free_before = alloc.stats().free_pages;
    _ = scheduler.init();
    try std.testing.expectEqual(esp_exec.ExecResult.ok, esp_exec.exec_file("BIG.ELF", &.{}));
    const pid = esp_exec.last_exec_pid().?;
    const info = process.info(pid).?;
    try std.testing.expectEqual(@as(u64, 1), info.text_pages);
    // M171a: resident is the file page + the argv/envp headroom page; the
    // second image page is the demand-zero tail (mapped, not allocated).
    try std.testing.expectEqual(@as(u64, 2), info.data_pages);
    try std.testing.expectEqual(@as(u64, 3), info.data_map_pages);
    try std.testing.expect(process.find_zero_region(pid, 0x70_4000) != null);

    // The image is BIG: every segment was really allocated (the 768-page
    // read-only segment is the only way this delta can come out right).
    try std.testing.expectEqual(free_before - big_elf_pages, alloc.stats().free_pages);
    // Its declared-vaddr aperture covers the read-only payload and STOPS at
    // the image's end — the page between it and the data segment is a real
    // gap, exactly as the linker laid it out.
    try std.testing.expect(process.mmap_collides(pid, big_elf_ro_vaddr, big_elf_ro_filesz));
    try std.testing.expect(!process.mmap_collides(pid, big_elf_ro_vaddr + big_elf_ro_filesz, 4096));

    // The byte-level proof: the banner sits 3 MiB into the file, far outside
    // the 16 KiB header window, and it is in the page the load mapped (the
    // identity map makes `data_phys` a readable host pointer). The whole
    // data payload matches the file, so the streamed reads neither skipped
    // nor duplicated one. (The read-only segment's bytes are proven the same
    // way by the class-B gate, which runs an image that reads its own
    // globals — there is no host-side seam that exposes those pages.)
    const data_bytes: [*]const u8 = @ptrFromInt(info.data_phys);
    try std.testing.expectEqualSlices(u8, &big_elf_mark, data_bytes[big_elf_data_marker..][0..big_elf_mark.len]);
    try std.testing.expectEqualSlices(u8, img[big_elf_ro_off + big_elf_ro_filesz ..][0..0x100], data_bytes[0..0x100]);

    // The `exec` reply's `head=` prints these bytes, so a streamed load must
    // report THIS image's first instruction, not the staging buffer's
    // leftovers from an earlier exec.
    try std.testing.expectEqualSlices(u8, img[148..156], &esp_exec.head());
}

test "exec: a file that shrinks under the loader is refused image_truncated (M70c-K #1504)" {
    try arm_allocator(&big_test_ram);
    fill_big_gap_elf(false);
    const free_before = alloc.stats().free_pages;
    // The share is a LIVE host directory, so the interesting truncation is
    // not a file that was always short (the header check refuses that) but
    // one that changes between STAT and the streamed READ: STAT reports the
    // whole 3 MiB while only the first 4 KiB is on the volume. That is
    // exactly what an interrupted copy looks like, and it is the ONLY path
    // to `image_truncated` — the refusal must come from the segment read
    // hitting EOF, never from mapping what did arrive.
    var shrank = [_]virtio_file.TestFile{.{ .name = "TRUNC.ELF", .data = big_elf_image[0..0x1000], .stat_size = big_elf_file_size }};
    virtio_file.set_test_share(&shrank);
    defer virtio_file.set_test_share(null);

    _ = scheduler.init();
    try std.testing.expectEqual(esp_exec.ExecResult.image_truncated, esp_exec.exec_file("TRUNC.ELF", &.{}));
    // The refused load left nothing behind: the page segment 0 had already
    // taken is back in the allocator, and no process was created (a leak
    // here would be invisible until the pool emptied, so it is asserted).
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    try std.testing.expectEqual(@as(usize, 0), process.count());
}

test "exec: a file that was always short is refused image_truncated (M70c-K #1504)" {
    try arm_allocator(&big_test_ram);
    fill_big_gap_elf(false);
    const free_before = alloc.stats().free_pages;
    // The same short payload WITHOUT the STAT lie. This file is 4 KiB, so it
    // never enters the streamed path at all — it is the staged parse that
    // refuses it, because its header promises 3 MiB of payload the file does
    // not hold. The refusal is deliberately the SAME name as the streamed
    // shrink above: both are "this file ends before its own header says it
    // does", and a caller should not have to know which check noticed. What
    // is pinned here is that the two detections of one condition agree, and
    // that neither is confused with a size refusal.
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("SHORT.ELF", big_elf_image[0..0x1000]);

    _ = scheduler.init();
    try std.testing.expectEqual(esp_exec.ExecResult.image_truncated, esp_exec.exec_file("SHORT.ELF", &.{}));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    try std.testing.expectEqual(@as(usize, 0), process.count());
}

test "exec: a file past the acceptance bound is refused image_too_large (M70c-K #1504)" {
    try arm_allocator(&big_test_ram);
    const free_before = alloc.stats().free_pages;
    // The bound the streamed path DOES have: the file itself. The content is
    // the small valid three-segment image, so every shape check would pass
    // and the ONLY reason to refuse is the file's size — which the fake STAT
    // reports as one byte past `exec_image_max`. It is asserted separately
    // from the staging bound because the messages differ (acceptance bound
    // vs staging buffer), and a caller reading the log must be able to tell
    // "the loader does not take files this big" from "this shape cannot be
    // staged".
    const img = small_contiguous_three_segment_elf();
    var oversized = [_]virtio_file.TestFile{.{ .name = "HUGE.ELF", .data = img[0..], .stat_size = esp_exec.exec_image_max + 1 }};
    virtio_file.set_test_share(&oversized);
    defer virtio_file.set_test_share(null);

    _ = scheduler.init();
    try std.testing.expectEqual(esp_exec.ExecResult.image_too_large, esp_exec.exec_file("HUGE.ELF", &.{}));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    try std.testing.expectEqual(@as(usize, 0), process.count());
}

test "exec: an oversized CONTIGUOUS ELF keeps its refusal (M70c-K #1504)" {
    try arm_allocator(&big_test_ram);
    // Same size, but the middle segment sits flush against segment 0, so
    // this is the contiguous shape — it still has to transit the staging
    // buffer, and `staging_too_large` is the honest answer (the streamed
    // path is for gap layouts only).
    fill_big_gap_elf(true);
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("FLAT.ELF", big_elf_image[0..]);

    _ = scheduler.init();
    try std.testing.expectEqual(esp_exec.ExecResult.staging_too_large, esp_exec.exec_file("FLAT.ELF", &.{}));
    // Refused, not partially loaded: nothing ran and no pages were taken.
    try std.testing.expectEqual(@as(usize, 0), process.count());
}

/// A SMALL three-segment image in the CONTIGUOUS shape (each segment flush
/// against the previous one's memory end, segment 0 at the fixed text
/// aperture). Nothing about it is odd to the parser, but the staging path
/// only ever copies [text][data] — so before the M70c-K guard this image
/// loaded "successfully" with its rodata and data segments missing.
fn small_contiguous_three_segment_elf() [0x2100]u8 {
    var img = @as([0x2100]u8, @splat(@as(u8, 0)));
    const magic4 = [4]u8{ 0x7f, 'E', 'L', 'F' };
    @memcpy(img[0..4], &magic4);
    img[4] = 1; // ELF32
    img[5] = 1; // little-endian
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], 2, .little);
    std.mem.writeInt(u16, img[18..20], 0xB7, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u32, img[24..28], 0x40_0000, .little); // e_entry
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[42..44], 32, .little);
    std.mem.writeInt(u16, img[44..46], 3, .little);
    const offs = [_]u32{ 148, 0x1000, 0x2000 };
    const vaddrs = [_]u32{ 0x40_0000, 0x40_1000, 0x40_2000 };
    const flags = [_]u32{ 5, 4, 6 }; // R+X, R, RW
    for (offs, vaddrs, flags, 0..) |off, va, fl, i| {
        const rec = 52 + i * 32;
        std.mem.writeInt(u32, img[rec..][0..4], 1, .little); // PT_LOAD
        std.mem.writeInt(u32, img[rec + 4 ..][0..4], off, .little);
        std.mem.writeInt(u32, img[rec + 8 ..][0..4], va, .little);
        std.mem.writeInt(u32, img[rec + 16 ..][0..4], 0x100, .little); // p_filesz
        std.mem.writeInt(u32, img[rec + 20 ..][0..4], 0x1000, .little); // p_memsz
        std.mem.writeInt(u32, img[rec + 24 ..][0..4], fl, .little);
    }
    std.mem.writeInt(u32, img[148..152], 0xD2800540, .little);
    std.mem.writeInt(u32, img[152..156], 0xD65F03C0, .little);
    return img;
}

test "exec: a small contiguous three-segment image is refused, never partly loaded (M70c-K #1504)" {
    try arm_allocator(&big_test_ram);
    const free_before = alloc.stats().free_pages;
    var img = small_contiguous_three_segment_elf();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("FLAT3.ELF", img[0..]);

    _ = scheduler.init();
    try std.testing.expectEqual(esp_exec.ExecResult.staging_too_large, esp_exec.exec_file("FLAT3.ELF", &.{}));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    try std.testing.expectEqual(@as(usize, 0), process.count());
}

/// M72a (#1579): the SAME small three-segment image in the GAP shape — each
/// later segment one page clear of the previous one's memory end — with the
/// writable segment's `p_memsz` raised to 3 MiB, so the image's MAPPED total
/// (~3.01 MiB) is past the 2 MiB staging buffer while its FILE (0x2100 B) is
/// nowhere near it.
fn small_gap_three_segment_elf() [0x2100]u8 {
    var img = small_contiguous_three_segment_elf();
    std.mem.writeInt(u32, img[52 + 1 * 32 + 8 ..][0..4], 0x40_2000, .little); // seg1 vaddr: a gap
    std.mem.writeInt(u32, img[52 + 2 * 32 + 8 ..][0..4], 0x40_4000, .little); // seg2 vaddr: a gap
    std.mem.writeInt(u32, img[52 + 2 * 32 + 20 ..][0..4], 0x30_0000, .little); // seg2 memsz: 3 MiB
    return img;
}

test "exec: a STAGED gap image is bounded by map_max, not by the staging buffer (M72a #1579)" {
    try arm_allocator(&big_test_ram);
    const free_before = alloc.stats().free_pages;
    var img = small_gap_three_segment_elf();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("GAP3.ELF", img[0..]);

    _ = scheduler.init();
    // What is large here is the writable segment's MAPPED size, not anything
    // that transits the buffer: the file is 0x2100 B, every segment's FILE
    // bytes are inside it, and the gap path copies exactly those. Charging
    // `mem_total` against `exec_program_max` refused this image with a
    // message about a buffer no part of it fills (the second instance of the
    // lie the map bound replaced); the mapped total is `elf.map_max`'s to
    // bound, and 3 MiB is well inside it.
    try std.testing.expectEqual(esp_exec.ExecResult.ok, esp_exec.exec_file("GAP3.ELF", &.{}));
    const pid = esp_exec.last_exec_pid().?;
    const info = process.info(pid).?;
    // M171a: the VIRTUAL span is the full 768 writable pages + the argv/envp
    // headroom page — but RESIDENT is only the file page + that headroom
    // page; the 767-page zero-fill tail is a demand region, not allocated.
    try std.testing.expectEqual(@as(u64, 769), info.data_map_pages);
    try std.testing.expectEqual(@as(u64, 2), info.data_pages);
    try std.testing.expectEqual(@as(u64, 1), info.text_pages);
    try std.testing.expect(process.find_zero_region(pid, 0x40_5000) != null);
    // And only the resident pages were REALLY taken: text + the one rodata
    // page + the 2 resident writable pages + the 192 KiB task stack and its
    // kernel twin. The tail costs nothing until EL0 touches it.
    try std.testing.expectEqual(free_before - (1 + 1 + 2 + 48 + 48), alloc.stats().free_pages);
}

test "monitor: ls lists the host-share files deterministically" {
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("KERNEL.BIN", "abcd");
    test_seed_share("BOOTED.TXT", "VIRELAIOS BOOTLOADER\nfirmware has agreed to cooperate\n");
    test_seed_share("HELLO.TXT", "hello world");

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"ls"}));
    // Entries are listed in share order — deterministic per boot. The
    // name column pads to the widest entry; sizes are 0x + 16 hex digits.
    try std.testing.expectEqualStrings(
        "ls: host=0x0000000000000003\n" ++
            "  KERNEL.BIN  0x0000000000000004  [host]\n" ++
            "  BOOTED.TXT  0x0000000000000036  [host]\n" ++
            "  HELLO.TXT   0x000000000000000b  [host]\n",
        env.mock.contents(),
    );
}

test "monitor: cat prints share content with honest errors" {
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("BOOTED.TXT", "VIRELAIOS BOOTLOADER\nfirmware has agreed to cooperate\n");
    test_seed_share("KERNEL.BIN", "");
    test_seed_share("hello.txt", "hello world");

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "BOOTED.TXT" }));
    // The file already ends with a newline — cat prints it verbatim.
    try std.testing.expectEqualStrings("VIRELAIOS BOOTLOADER\nfirmware has agreed to cooperate\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "hello.txt" }));
    try std.testing.expectEqualStrings("hello world\n", env.mock.contents());
    env.mock.reset();
    // An empty file prints just the trailing newline (no error).
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "KERNEL.BIN" }));
    try std.testing.expectEqualStrings("\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "NOPE.TXT" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "not found") != null);
}

test "monitor: ls/cat accept /-paths (honest not-found on the share)" {
    test_reset_share(); // armed, empty — every path is an honest not_found
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    // No host file channel in a host test process: the path branches
    // resolve nothing and report it honestly (the success path is the
    // live vf gate — `ls`/`cat` on a seeded share).
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "ls", "EFI/BOOT" }));
    try std.testing.expectEqualStrings("error: EFI/BOOT: not found (no such directory on the host share)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "EFI/BOOT/BOOTAA64.EFI" }));
    try std.testing.expectEqualStrings("error: EFI/BOOT/BOOTAA64.EFI: not found (no such file on the host share)\n", env.mock.contents());
    env.mock.reset();
    // The no-arg ls lists the (empty) share.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"ls"}));
    try std.testing.expectEqualStrings("ls: host=0x0000000000000000\nls: no files on the host share\n", env.mock.contents());
}

test "monitor: mount reports the host-share state (HF6)" {
    virtio_file.set_test_share(null); // no channel
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    // No host file channel: mount reports it honestly (there are no FAT
    // volumes to switch anymore — HF6 deleted them).
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "mount", "data" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "mount: no host file channel") != null);
    env.mock.reset();
    // The registry documents the command.
    try std.testing.expectEqualStrings("report the host-share file store (HF6: the FAT volumes are gone)", lookup("mount").?.help);
}

test "monitor: write joins arguments and honestly reports no channel in a test process" {
    virtio_file.set_test_share(null); // no channel
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    // In a host test process there is no file channel; the write must be
    // refused honestly, never faked (the live vf gate exercises the real
    // host-disk write).
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "write", "hello.txt", "hello", "world" }));
    try std.testing.expectEqualStrings(
        "error: hello.txt: not persisted - host file-channel error\n",
        env.mock.contents(),
    );
    env.mock.reset();
    // Empty content is still refused without a channel.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "write", "n.txt" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "not persisted") != null);
}

test "monitor: M97d-F4 (#2089) — vf handle arguments beyond u16 are usage errors, never truncated casts" {
    // The share override makes the channel "available" so `vf` dispatches
    // to the subcommand handlers; the queue itself stays unarmed, so any
    // op that reaches the transport fails honestly.
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("F.TXT", "x");
    var env = TestEnv.init();
    var mon = env.monitor();
    // The console's handle argument parses as u64 then casts to the u16
    // wire handle. Pre-fix, `vf close 65537` silently truncated to handle
    // 1 under ReleaseSmall and acted on another process's slot in the
    // host's GLOBAL handle table. Now every handler prints usage and
    // returns before the cast — nothing reaches virtio_file.
    for ([_][]const []const u8{
        &.{ "vf", "close", "65537" },
        &.{ "vf", "fsync", "65537" },
        &.{ "vf", "truncate", "65537", "0" },
        &.{ "vf", "write", "65537", "1" },
        &.{ "vf", "close", "0x10001" }, // same truncation via the hex form
    }) |argv| {
        try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, argv));
    }
    const out = env.mock.contents();
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, out, "vf usage:"));
    try std.testing.expect(std.mem.indexOf(u8, out, "vf close: 65537") == null);

    // An in-range handle still reaches the transport (which reports the
    // honest unarmed-queue error here): the check gates out-of-range
    // values only, it does not shadow real handles.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "vf", "close", "1" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "vf close: 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "vf usage:") == null);
}

test "monitor: exec is registered and refuses honestly without a channel" {
    virtio_file.set_test_share(null); // no channel
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("exec") != null);
    try std.testing.expectEqualStrings("load a user program from the host share and enter it at EL0", lookup("exec").?.help);
    // No host file channel in a host test process: refused honestly, never
    // faked. (The full load+spawn path is covered by exec.zig's own tests,
    // which serve the in-memory share fixture.)
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"exec"}));
    try std.testing.expectEqualStrings("error: no host file channel (boot the runner with --cvc-file <host-dir>)\n", env.mock.contents());
}

test "monitor: exec -u<uid> admin-spawn flag validates the principal vocabulary" {
    virtio_file.set_test_share(null); // no channel: the flag parsing is pinned
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    // M50 TS3 (#1137, ADR 0024 D5): the documented admin-spawn CLI.
    try std.testing.expectEqualStrings("exec [-c<core>] [-u<uid>] [<file> [arg...]]", lookup("exec").?.usage);
    // The two ADR 0024 D1 principals parse; without a channel the loader's
    // honest no-disk refusal proves the flag was CONSUMED (never treated as
    // a filename) and the command reached the principal-taking exec path.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "exec", "-u0", "USER.BIN" }));
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "exec", "-u1000", "USER.BIN" }));
    // Combined with the SMP pin, in either order.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "exec", "-c0", "-u0", "USER.BIN" }));
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "exec", "-u1000", "-c0", "USER.BIN" }));
    // Any other uid is refused with the documented D3 shape — never a
    // silent default principal, never a wrap from an over-long decimal.
    for ([_][]const u8{ "-u1", "-u999", "-ux", "-u99999999999999999999" }) |flag| {
        env.mock.reset();
        try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "exec", flag, "USER.BIN" }));
        try std.testing.expectEqualStrings("error: -u<uid>: uid must be 0 (system) or 1000 (user)\n", env.mock.contents());
    }
    // An unknown leading flag stays a filename (the pre-existing -c shape).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "exec", "-x", "USER.BIN" }));
}

test "monitor: net dns command validation and execution" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = false;
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };

    // Missing arguments
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "net", "dns" }));

    // No device
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "dns", "example.com" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "error: no virtio-net device\n") != null);

    // Invalid server IP
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "dns", "example.com", "999.0.0.1" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "error: invalid server address: 999.0.0.1\n") != null);
}

test "monitor: sound volume/mute drive the bounded stream state (claim 9297)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("sound") != null);
    try std.testing.expectEqualStrings("sound [volume <0-100> | mute <on|off>]", lookup("sound").?.usage);

    // Defaults: full volume, unmuted.
    virtio_snd.stream_volume = 100;
    virtio_snd.stream_muted = false;

    // `sound volume <0-100>` sets the bounded gain and echoes it.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "sound", "volume", "30" }));
    try std.testing.expectEqualStrings("sound: volume=30\n", env.mock.contents());
    try std.testing.expectEqual(@as(u8, 30), virtio_snd.stream_volume);

    // Out-of-range is refused honestly (no silent clamping).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "sound", "volume", "101" }));
    try std.testing.expectEqualStrings("sound: volume must be 0..100\n", env.mock.contents());
    try std.testing.expectEqual(@as(u8, 30), virtio_snd.stream_volume);

    // `sound mute on|off` sets the flag.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "sound", "mute", "on" }));
    try std.testing.expectEqualStrings("sound: mute=on\n", env.mock.contents());
    try std.testing.expect(virtio_snd.stream_muted);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "sound", "mute", "off" }));
    try std.testing.expectEqualStrings("sound: mute=off\n", env.mock.contents());
    try std.testing.expect(!virtio_snd.stream_muted);

    // A bad subcommand is a usage error.
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "sound", "bogus", "1" }));

    // The `sound` report shows the stream state (works without a device).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sound"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "sound: vol=30 mute=0\n") != null);

    // Restore the honest default.
    virtio_snd.stream_volume = 100;
    virtio_snd.stream_muted = false;
}

test "monitor: which resolves builtin, monitor, app, and not-found names (D16)" {
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("NOTE.ELF", "x");

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "type" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "stat" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "NOTE.ELF" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "nope.bin" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "type: shell builtin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "stat: monitor command") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NOTE.ELF: host-share application") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nope.bin: not found") != null);
}

test "monitor: du reports recursive directory size (M25 F4)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"du"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "du: /") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bytes (dirs=") != null);
}
