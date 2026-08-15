//! Dipshit Monitor command layer (Milestone 1.5, commands & personality).
//!
//! A reusable, host-testable command registry for the future interactive
//! monitor (`dipshit>`). It depends only on the console abstraction
//! (`console.zig`), the handoff-v2 contract (`handoff.zig`), and the
//! captured EFI map view (`memmap.zig`); it never touches hardware, so it
//! runs unchanged under `zig test` against a mock console and, later,
//! inside the kernel once the Console & Shell Core stream wires the real
//! serial transport.
//!
//! Constraints honored: no heap allocation, no libc, no POSIX, no dynamic
//! command registration, no unbounded recursion or output, and no hidden
//! global mutable state. All state lives in the caller-owned `Monitor`
//! value (console, system state, machine control).
//!
//! `kernel/src/main.zig` is intentionally untouched by this stream.

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("alloc.zig");
const console = @import("console.zig");
const esp = @import("esp.zig");
const esp_exec = @import("exec.zig"); // claim 6783: load a user program from the ESP and enter it at EL0
const fat = @import("fat.zig"); // claim 6420: FAT write diagnostics (last failing LBA)
const exceptions = @import("exceptions.zig");
const gic = @import("gic.zig");
const handoff = @import("handoff.zig");
const mailbox = @import("mailbox.zig"); // claim 5965: per-process IPC rings behind `mbox`
const memmap = @import("memmap.zig");
const mmu = @import("mmu.zig"); // claim 5804: per-task TTBR0 roots + user-root inventory
const pci = @import("pci.zig");
const process = @import("process.zig"); // milestone four (claim 3848): the process registry behind `procs`
const scheduler = @import("scheduler.zig"); // claim 5275: tick-driven round-robin tasks
const syscall = @import("syscall.zig"); // claim 3594: syscall table + counters
const timer = @import("timer.zig");
const uaccess = @import("uaccess.zig"); // claim 6120: fault-safe copy-in/copy-out
const userspace = @import("userspace.zig"); // claim 5804: user-VA layout
const virtio_blk = @import("virtio_blk.zig"); // claim 6420: the sector interface behind `mount` (milestone four card 2)
const csprng = @import("csprng.zig"); // milestone four (claim 2665): the seeded CSPRNG behind `random`
const virtio_net = @import("virtio_net.zig"); // milestone five card N1 (claim 1373): the net transport behind `net`/`netsend`
const virtio_gpu = @import("virtio_gpu.zig"); // milestone six card G1 (claim 6053): the gpu transport + framebuffer behind `screen`
const road_pops = @import("road_pops.zig"); // milestone six card G3 (claim 1574): the Road Pops tee console behind `roadpops`
const fbtext = @import("text.zig"); // milestone six card G2 (claim 3194): framebuffer text rendering behind `text`
const xhci = @import("xhci.zig"); // milestone seven card I1 (claim 4272): the XHCI host-controller transport behind `usb`
const input = @import("input.zig"); // milestone seven card I3 (claim 6050): the keyboard/pointer event FIFO behind `input`
const driving_award = @import("driving_award.zig"); // milestone six card G5 (claim 1543): Driving Award, the window manager behind `win`

// ---------------------------------------------------------------------------
// Limits (fixed-size, explicit bounds)
// ---------------------------------------------------------------------------

/// Maximum arguments after the command name for any single invocation.
pub const max_args_limit: u8 = 16;
/// `repeat` refuses counts outside 1..repeat_max_count.
pub const repeat_max_count: u64 = 64;
/// `repeat` refuses outputs larger than this many bytes.
pub const repeat_max_bytes: usize = 4096;
/// `beans` refuses counts outside 1..beans_max_count.
pub const beans_max_count: u64 = 100;
/// `random` refuses counts outside 1..random_max_bytes (milestone four,
/// claim 2665).
pub const random_max_bytes: usize = 256;

// ---------------------------------------------------------------------------
// Execution result
// ---------------------------------------------------------------------------

pub const ExecError = enum {
    none,
    unknown_command,
    usage,
    invalid_argument,
    not_implemented,
    machine_failed,
};

// ---------------------------------------------------------------------------
// System state handed to the monitor
// ---------------------------------------------------------------------------

/// Everything the commands may read. Caller-owned, immutable from the
/// command layer's point of view.
pub const SystemState = struct {
    handoff: handoff.HandoffV2,
    map: memmap.MapView,
    /// Human-readable transport name ("mock", later "virtio-console",
    /// "pl011", ...). Reported by `elephant` diagnostics.
    console_name: []const u8,
};

// ---------------------------------------------------------------------------
// Machine control (reboot / shutdown)
// ---------------------------------------------------------------------------

pub const MachineResult = enum { ok, not_implemented, failed };

/// Interface behind which `reboot`/`shutdown` live, so command behavior can
/// be host-tested without rebooting the test process. The kernel's real
/// post-ExitBootServices mechanism (Runtime Services `ResetSystem`) is not
/// proven by any gate, so the default is `MachineControl.disabled()`, which
/// honestly reports `not_implemented`; a later stream that proves a
/// mechanism supplies a real implementation.
pub const MachineControl = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reboot: *const fn (ctx: *anyopaque) MachineResult,
        shutdown: *const fn (ctx: *anyopaque) MachineResult,
    };

    pub fn reboot(self: MachineControl) MachineResult {
        return self.vtable.reboot(self.ctx);
    }

    pub fn shutdown(self: MachineControl) MachineResult {
        return self.vtable.shutdown(self.ctx);
    }

    /// Honest default: no proven post-exit machine-control mechanism.
    /// The vtable is built at runtime (not a const table) so its function
    /// pointers resolve PC-relatively at the kernel's runtime load base
    /// (claim 0015 root cause).
    pub fn disabled() MachineControl {
        ensure_disabled_vtable();
        return .{
            .ctx = @ptrCast(@constCast(&NoopDisabled)),
            .vtable = &disabled_vtable,
        };
    }
};

/// Storage + builder for `MachineControl.disabled()`'s vtable (module-level
/// so the pointer outlives the call).
const NoopDisabled = struct {
    fn reboot(_: *anyopaque) MachineResult {
        return .not_implemented;
    }
    fn shutdown(_: *anyopaque) MachineResult {
        return .not_implemented;
    }
};
var disabled_vtable: MachineControl.VTable = undefined;
var disabled_vtable_ready = false;
fn ensure_disabled_vtable() void {
    if (!disabled_vtable_ready) {
        disabled_vtable = .{ .reboot = NoopDisabled.reboot, .shutdown = NoopDisabled.shutdown };
        disabled_vtable_ready = true;
    }
}

/// Host-test double: records calls and returns scripted results.
pub const MockMachineControl = struct {
    reboot_result: MachineResult = .ok,
    shutdown_result: MachineResult = .ok,
    reboot_calls: usize = 0,
    shutdown_calls: usize = 0,

    /// Runtime-built vtable (claim 0015 root cause): a const table would
    /// hold link-time absolute addresses, wrong at the runtime load base.
    /// Module-level storage so the returned pointer outlives the call.
    pub fn control(self: *MockMachineControl) MachineControl {
        ensure_mock_vtable();
        return .{ .ctx = self, .vtable = &mock_vtable };
    }

    fn rebootFn(ctx: *anyopaque) MachineResult {
        const self: *MockMachineControl = @ptrCast(@alignCast(ctx));
        self.reboot_calls += 1;
        return self.reboot_result;
    }

    fn shutdownFn(ctx: *anyopaque) MachineResult {
        const self: *MockMachineControl = @ptrCast(@alignCast(ctx));
        self.shutdown_calls += 1;
        return self.shutdown_result;
    }
};

/// Storage + builder for `MockMachineControl.control()`'s vtable.
var mock_vtable: MachineControl.VTable = undefined;
var mock_vtable_ready = false;
fn ensure_mock_vtable() void {
    if (!mock_vtable_ready) {
        mock_vtable = .{ .reboot = MockMachineControl.rebootFn, .shutdown = MockMachineControl.shutdownFn };
        mock_vtable_ready = true;
    }
}

// ---------------------------------------------------------------------------
// Monitor context
// ---------------------------------------------------------------------------

pub const Monitor = struct {
    console: console.Console,
    state: SystemState,
    machine: MachineControl,

    pub fn init(con: console.Console, state: SystemState, machine: MachineControl) Monitor {
        return .{ .console = con, .state = state, .machine = machine };
    }
};

// ---------------------------------------------------------------------------
// Command registry
// ---------------------------------------------------------------------------

/// Command category (ADR 0008 D1): the seven groups `help` lists.
pub const Category = enum {
    machine_identity,
    memory_state,
    tasks_processes,
    storage,
    networking,
    graphics_input,
    system,
};

/// The fixed group order `help` lists (ADR 0008 D1). Enum values only — no
/// string-literal pointers in a const table, because the kernel's flat loader
/// applies no relocations (the claim-0015 lesson): `category_name` returns the
/// display strings PC-relatively at the call site instead.
const category_order = [_]Category{
    .machine_identity,
    .memory_state,
    .tasks_processes,
    .storage,
    .networking,
    .graphics_input,
    .system,
};

fn category_name(cat: Category) []const u8 {
    return switch (cat) {
        .machine_identity => "machine / identity",
        .memory_state => "memory / machine state",
        .tasks_processes => "tasks / processes",
        .storage => "storage",
        .networking => "networking",
        .graphics_input => "graphics / input",
        .system => "system",
    };
}

pub const Command = struct {
    name: []const u8,
    help: []const u8,
    usage: []const u8,
    category: Category,
    min_args: u8 = 0,
    max_args: u8 = max_args_limit,
    handler: *const fn (m: *Monitor, args: []const []const u8) ExecError,
};

/// Number of commands. The registry is built at runtime (not a const
/// table): see `ensure_registry`.
/// Number of commands. The registry is built at runtime (not a const
/// table): see `ensure_registry`. Milestone five card N1 (claim 1373)
/// grows it 32 -> 34 (`net` + `netsend`). Milestone seven card I1
/// (claim 4272) grows it 37 -> 38 (`usb`). Milestone seven card I3
/// (claim 6050) grows it 38 -> 39 (`input`). Milestone six card G5
/// (claim 1543) grows it 39 -> 40 (`win`).
pub const registry_count: usize = 40;

/// Command registry, built at runtime into BSS. A `const` table would hold
/// link-time absolute addresses for BOTH the string slices and the handler
/// function pointers, which are wrong at the kernel's runtime-chosen load
/// base (claim 0015 root cause: the first vtable dispatch crashed; the
/// flat loader applies no relocations, unlike macOS for host tests). Built
/// once here in RAM so every pointer resolves PC-relatively (ADRP) and is
/// correct at any load base. `help` derives its listing from this table,
/// so the two cannot drift.
var registry_storage: [registry_count]Command = undefined;
var registry_ready = false;

fn ensure_registry() []const Command {
    if (!registry_ready) {
        registry_storage = .{
            .{ .name = "addrspaces", .help = "per-task user address spaces: per-task TTBR0, EL1-only kernel overlay, user-root contents", .usage = "addrspaces", .category = .memory_state, .handler = cmd_addrspaces },
            .{ .name = "about", .help = "explain this questionable system", .usage = "about", .category = .machine_identity, .handler = cmd_about },
            .{ .name = "beans", .help = "count beans, probably", .usage = "beans [count]", .category = .machine_identity, .max_args = 1, .handler = cmd_beans },
            .{ .name = "cat", .help = "print a file from the ESP (by name or /path)", .usage = "cat <file|path>", .category = .storage, .min_args = 1, .max_args = 1, .handler = cmd_cat },
            .{ .name = "clear", .help = "clean up the crime scene", .usage = "clear", .category = .system, .handler = cmd_clear },
            .{ .name = "echo", .help = "repeat your regrettable decisions", .usage = "echo <text...>", .category = .system, .handler = cmd_echo },
            .{ .name = "elephant", .help = "operational mascot diagnostics", .usage = "elephant", .category = .machine_identity, .handler = cmd_elephant },
            .{ .name = "exec", .help = "load a user program from the ESP and enter it at EL0", .usage = "exec [<file> [arg...]]", .category = .tasks_processes, .max_args = 1 + esp_exec.max_exec_args, .handler = cmd_exec },
            .{ .name = "fault", .help = "trigger a synchronous exception (diagnostic)", .usage = "fault", .category = .memory_state, .handler = cmd_fault },
            .{ .name = "handoff", .help = "display boot-to-kernel ABI data", .usage = "handoff", .category = .memory_state, .handler = cmd_handoff },
            .{ .name = "help", .help = "grouped command catalog and per-command/per-topic help", .usage = "help [<command>|<topic>]", .category = .system, .max_args = 1, .handler = cmd_help },
            .{ .name = "hex", .help = "format an integer in hexadecimal", .usage = "hex <number>...", .category = .memory_state, .min_args = 1, .handler = cmd_hex },
            .{ .name = "input", .help = "keyboard/pointer event FIFO: armed state, occupancy, drop count, last keyboard + pointer events", .usage = "input", .category = .graphics_input, .handler = cmd_input },
            .{ .name = "kill", .help = "terminate a running process (kernel-owned lifetime)", .usage = "kill <pid|name>", .category = .tasks_processes, .min_args = 1, .max_args = 1, .handler = cmd_kill },
            .{ .name = "ls", .help = "list files on the ESP (or a directory by path)", .usage = "ls [<dir>]", .category = .storage, .max_args = 1, .handler = cmd_ls },
            .{ .name = "mem", .help = "summarize the EFI memory map", .usage = "mem", .category = .memory_state, .handler = cmd_mem },
            .{ .name = "mbox", .help = "per-process IPC mailbox: pending messages and drain counters", .usage = "mbox [<pid>]", .category = .tasks_processes, .max_args = 1, .handler = cmd_mbox },
            .{ .name = "mount", .help = "switch the active FAT volume (esp or data)", .usage = "mount <esp|data>", .category = .storage, .min_args = 1, .max_args = 1, .handler = cmd_mount },
            .{ .name = "net", .help = "virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client)", .usage = "net [recv|ip <addr>|arp [<addr>]|ping <addr>|udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]|dhcp|tcp [connect <addr> <port>|send <len>|recv|close|reset]]", .category = .networking, .max_args = 5, .handler = cmd_net },
            .{ .name = "netsend", .help = "send a known Ethernet frame (bounded staging, TX + used-ring drain)", .usage = "netsend <bytes>", .category = .networking, .min_args = 1, .max_args = 1, .handler = cmd_netsend },
            .{ .name = "pages", .help = "physical page allocator pool", .usage = "pages [selftest]", .category = .memory_state, .max_args = 1, .handler = cmd_pages },
            .{ .name = "pci", .help = "enumerate PCI devices on the bus", .usage = "pci", .category = .memory_state, .handler = cmd_pci },
            .{ .name = "procs", .help = "process registry: image, address space, lifecycle, exit status", .usage = "procs", .category = .tasks_processes, .handler = cmd_procs },
            .{ .name = "random", .help = "print n random bytes from the seeded CSPRNG (hex)", .usage = "random [n]", .category = .system, .max_args = 1, .handler = cmd_random },
            .{ .name = "reboot", .help = "restart the machine", .usage = "reboot", .category = .system, .handler = cmd_reboot },
            .{ .name = "repeat", .help = "repeat text, safely bounded", .usage = "repeat <count> <text...>", .category = .system, .min_args = 1, .handler = cmd_repeat },
            .{ .name = "roadpops", .help = "Road Pops framebuffer console: armed/dirty/present counters (the boot terminal on the screen)", .usage = "roadpops", .category = .graphics_input, .handler = cmd_roadpops },
            .{ .name = "screen", .help = "virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)", .usage = "screen [fill <rrggbb>]", .category = .graphics_input, .max_args = 2, .handler = cmd_screen },
            .{ .name = "text", .help = "framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears)", .usage = "text [put <string...>|clear]", .category = .graphics_input, .min_args = 0, .max_args = 9, .handler = cmd_text },
            .{ .name = "shutdown", .help = "request power-off", .usage = "shutdown", .category = .system, .handler = cmd_shutdown },
            .{ .name = "spawn", .help = "spawn the lifecycle demo task", .usage = "spawn", .category = .tasks_processes, .handler = cmd_spawn },
            .{ .name = "syscalls", .help = "numbered syscall table and counters", .usage = "syscalls", .category = .tasks_processes, .handler = cmd_syscalls },
            .{ .name = "tasks", .help = "tick-driven task scheduler status", .usage = "tasks", .category = .tasks_processes, .handler = cmd_tasks },
            .{ .name = "timer", .help = "interrupt controller + timer status", .usage = "timer", .category = .memory_state, .handler = cmd_timer },
            .{ .name = "uaccess", .help = "user-memory copy diagnostics (valid, fault, recovery)", .usage = "uaccess", .category = .memory_state, .handler = cmd_uaccess },
            .{ .name = "usb", .help = "XHCI host controller: `usb` transport report, `usb devices` enumerated HID devices, `usb report` last HID report", .usage = "usb [devices|report]", .category = .graphics_input, .handler = cmd_usb },
            .{ .name = "uname", .help = "compact system identity", .usage = "uname", .category = .machine_identity, .handler = cmd_uname },
            .{ .name = "version", .help = "display build information", .usage = "version", .category = .machine_identity, .handler = cmd_version },
            .{ .name = "win", .help = "Driving Award window manager: registry (with owner pids), z-order, focus, hit-testing ('win focus <n>' focuses; 'win raise <n>' raises; 'win move <n> <x> <y>' moves a user window; 'win close <n>' releases a user window; 'win list <pid>' filters by owner; 'win hit <x> <y>' hit-tests)", .usage = "win [focus <n>|raise <n>|move <n> <x> <y>|close <n>|list <pid>|hit <x> <y>]", .category = .graphics_input, .max_args = 4, .handler = cmd_win },
            .{ .name = "write", .help = "write text to a file on the ESP", .usage = "write <file> <text...>", .category = .storage, .min_args = 1, .handler = cmd_write },
        };
        registry_ready = true;
    }
    return &registry_storage;
}

pub fn lookup(name: []const u8) ?*const Command {
    for (ensure_registry()) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tab completion (milestone eight card U2, ADR 0008 D2)
// ---------------------------------------------------------------------------

/// One sub-verb word: `verb sub word` (sub = "" for depth-1 sub-verbs).
/// Mirrors the usage strings of the multi-verb commands; bounded — a word
/// missing from this table simply does not complete.
const SubWord = struct {
    verb: []const u8,
    sub: []const u8 = "",
    word: []const u8,
};

const sub_words_count: usize = 30;

/// Runtime-built BSS table (the claim-0015 lesson: per-element code
/// assignments with string literals stay PC-relative at any load base;
/// a const table of slice pointers would not).
var sub_words_storage: [sub_words_count]SubWord = undefined;
var sub_words_ready = false;

fn ensure_sub_words() []const SubWord {
    if (!sub_words_ready) {
        sub_words_storage = .{
            .{ .verb = "mount", .word = "esp" },
            .{ .verb = "mount", .word = "data" },
            .{ .verb = "net", .word = "arp" },
            .{ .verb = "net", .word = "dhcp" },
            .{ .verb = "net", .word = "ip" },
            .{ .verb = "net", .word = "ping" },
            .{ .verb = "net", .word = "recv" },
            .{ .verb = "net", .word = "tcp" },
            .{ .verb = "net", .word = "udp" },
            .{ .verb = "net", .sub = "tcp", .word = "close" },
            .{ .verb = "net", .sub = "tcp", .word = "connect" },
            .{ .verb = "net", .sub = "tcp", .word = "reset" },
            .{ .verb = "net", .sub = "tcp", .word = "send" },
            .{ .verb = "net", .sub = "udp", .word = "close" },
            .{ .verb = "net", .sub = "udp", .word = "listen" },
            .{ .verb = "net", .sub = "udp", .word = "recv" },
            .{ .verb = "net", .sub = "udp", .word = "send" },
            .{ .verb = "pages", .word = "selftest" },
            .{ .verb = "screen", .word = "fill" },
            .{ .verb = "screen", .word = "peek" },
            .{ .verb = "text", .word = "clear" },
            .{ .verb = "text", .word = "put" },
            .{ .verb = "usb", .word = "devices" },
            .{ .verb = "usb", .word = "report" },
            .{ .verb = "win", .word = "close" },
            .{ .verb = "win", .word = "focus" },
            .{ .verb = "win", .word = "hit" },
            .{ .verb = "win", .word = "list" },
            .{ .verb = "win", .word = "move" },
            .{ .verb = "win", .word = "raise" },
        };
        sub_words_ready = true;
    }
    return &sub_words_storage;
}

/// Scratch for the returned extension (longest command name + trailing
/// space; bounded, reused per call — the caller inserts before any
/// reentry).
var completion_scratch: [24]u8 = undefined;

/// The line editor's tab completer (ADR 0008 D2: bounded completion of
/// verbs and sub-verbs; no match or ambiguity returns null so the editor
/// bells — there is no alternative listing). `line` is the buffer up to
/// the cursor; the completed token is its last (possibly partial) word.
pub fn complete_line(line: []const u8) ?[]const u8 {
    // The word being completed: after the last space.
    var word_start: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ' ') word_start = i + 1;
    }
    const word = line[word_start..];

    if (word_start == 0) {
        // First token: complete a registry verb.
        var match: ?[]const u8 = null;
        var matches: usize = 0;
        for (ensure_registry()) |*cmd| {
            if (!std.mem.startsWith(u8, cmd.name, word)) continue;
            matches += 1;
            match = cmd.name;
        }
        return extension(word, matches, match);
    }

    // A later token: complete a sub-verb where the table knows one. argv[0]
    // is the verb; argv[1] (when the word is the third token) selects a
    // depth-2 list.
    var argv: [2][]const u8 = undefined;
    var argv_len: usize = 0;
    var token_start: usize = 0;
    var in_token = false;
    var j: usize = 0;
    while (j < word_start) : (j += 1) {
        if (line[j] == ' ') {
            if (in_token and argv_len < 2) {
                argv[argv_len] = line[token_start..j];
                argv_len += 1;
            }
            in_token = false;
        } else {
            if (!in_token) token_start = j;
            in_token = true;
        }
    }
    if (argv_len == 0) return null;
    const sub: []const u8 = if (argv_len == 2) argv[1] else "";
    var match: ?[]const u8 = null;
    var matches: usize = 0;
    for (ensure_sub_words()) |row| {
        if (!std.mem.eql(u8, row.verb, argv[0])) continue;
        if (!std.mem.eql(u8, row.sub, sub)) continue;
        if (!std.mem.startsWith(u8, row.word, word)) continue;
        matches += 1;
        match = row.word;
    }
    return extension(word, matches, match);
}

/// Unique-prefix rule: exactly one candidate → its remaining suffix plus a
/// space (a fully-typed unique word completes to itself + space); anything
/// else (zero or 2+) → null (bell).
fn extension(word: []const u8, matches: usize, match: ?[]const u8) ?[]const u8 {
    if (matches != 1) return null;
    const name = match.?;
    if (word.len >= name.len) return " "; // fully typed: just the space
    const suffix = name[word.len..];
    if (suffix.len + 1 > completion_scratch.len) return null;
    @memcpy(completion_scratch[0..suffix.len], suffix);
    completion_scratch[suffix.len] = ' ';
    return completion_scratch[0 .. suffix.len + 1];
}

/// Execute an already-tokenized command line: `argv[0]` is the command
/// name, the rest are its arguments. Tokenization and line editing belong
/// to the later Console & Shell Core stream.
pub fn exec(m: *Monitor, argv: []const []const u8) ExecError {
    if (argv.len == 0) {
        m.console.print_line("no command given; type 'help' for a list of commands");
        return .usage;
    }
    if (argv.len > max_args_limit + 1) {
        m.console.print_line("too many arguments; type 'help' for a list of commands");
        return .usage;
    }
    const cmd = lookup(argv[0]) orelse {
        m.console.puts("unknown command: ");
        m.console.puts(argv[0]);
        m.console.puts("\ntype 'help' for a list of commands\n");
        return .unknown_command;
    };
    const args = argv[1..];
    if (args.len < cmd.min_args or args.len > cmd.max_args) {
        m.console.puts("usage: ");
        m.console.puts(cmd.usage);
        m.console.puts("\n");
        return .usage;
    }
    return cmd.handler(m, args);
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Parse a u64 from an optional "0x"/"0X"-prefixed hexadecimal string or a
/// bare decimal string. Explicit bounds: empty input, invalid digits, and
/// overflow are all errors; nothing wraps silently.
pub fn parseInt(text: []const u8) error{ Empty, InvalidDigit, Overflow }!u64 {
    if (text.len == 0) return error.Empty;
    var index: usize = 0;
    const radix: u64 = if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) blk: {
        index = 2;
        break :blk 16;
    } else 10;
    if (index >= text.len) return error.Empty;
    var value: u64 = 0;
    while (index < text.len) : (index += 1) {
        const c = text[index];
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidDigit,
        };
        if (radix == 10 and digit >= 10) return error.InvalidDigit;
        value = std.math.mul(u64, value, radix) catch return error.Overflow;
        value = std.math.add(u64, value, digit) catch return error.Overflow;
    }
    return value;
}

/// Hex-only parse (an optional 0x/0X prefix is accepted; the documented
/// `screen fill <rrggbb>` form is bare hex) — used for the color argument.
pub fn parseHex(text: []const u8) error{ Empty, InvalidDigit, Overflow }!u64 {
    if (text.len == 0) return error.Empty;
    var start: usize = 0;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) start = 2;
    if (start >= text.len) return error.Empty;
    var value: u64 = 0;
    for (text[start..]) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidDigit,
        };
        value = std.math.mul(u64, value, 16) catch return error.Overflow;
        value = std.math.add(u64, value, digit) catch return error.Overflow;
    }
    return value;
}

/// "  <label>: <value>"
fn print_plain_field(m: *Monitor, label: []const u8, value: []const u8) void {
    m.console.puts("  ");
    m.console.puts(label);
    m.console.puts(": ");
    m.console.puts(value);
}

/// "  <label>: <hex bytes> bytes (<hex pages> pages)"
fn print_mem_row(m: *Monitor, label: []const u8, pages: u64) void {
    m.console.puts("  ");
    m.console.puts(label);
    m.console.puts(": ");
    m.console.print_hex(memmap.bytes_of(pages));
    m.console.puts(" bytes (");
    m.console.print_hex(pages);
    m.console.puts(" pages)\n");
}

fn report_machine(m: *Monitor, verb: []const u8, result: MachineResult) ExecError {
    switch (result) {
        .ok => {
            m.console.puts(verb);
            m.console.puts(": ok\n");
            return .none;
        },
        .not_implemented => {
            m.console.puts(verb);
            m.console.puts(": not implemented - no proven post-ExitBootServices machine-control mechanism; terminal WFE loop continues\n");
            return .not_implemented;
        },
        .failed => {
            m.console.puts(verb);
            m.console.puts(": failed\n");
            return .machine_failed;
        },
    }
}

// ---------------------------------------------------------------------------
// Identity and inspection commands
// ---------------------------------------------------------------------------

/// `help <topic>` pages (ADR 0008 D1). Bodies are returned as string
/// literals from code (PC-relative at any load base — the claim-0015
/// lesson), never stored in a const table of pointers. Topics are
/// non-command keywords; `syscalls` is a command, so its `help <cmd>` detail
/// is the syscall page rather than a shadowed topic.
fn topic_body(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "networking")) {
        return "networking\n" ++
            "  virtio-net (DID 0x1041), flag-gated by the runner's --net mode: TX + RX,\n" ++
            "  ARP, IPv4/ICMP, UDP, a bounded DHCP client, and an outward-only bounded TCP\n" ++
            "  client with NAT. `net` drives it (recv/ip/arp/ping/udp/dhcp/tcp); `netsend`\n" ++
            "  sends a known frame. EL0 reaches UDP through ADR 0007 slots 9-11.\n" ++
            "  Bounds: static IP, no DNS, TCP is client-only (no listen or loopback).\n";
    }
    if (std.mem.eql(u8, name, "windows")) {
        return "windows\n" ++
            "  Driving Award (G5) owns the window registry: z-order, focus, hit-testing,\n" ++
            "  dirty-rect compositing. Road Pops is window 0; a 1 Hz clock is window 1.\n" ++
            "  `win` inspects/focuses/raises/moves/closes; EL0 opens windows through ADR 0007\n" ++
            "  slots 12-20 (open/fill/present/close/move/raise/get/query/set_visible). Windows\n" ++
            "  are process-owned and auto-close when their process exits.\n";
    }
    if (std.mem.eql(u8, name, "storage")) {
        return "storage\n" ++
            "  GPT + FAT32 over virtio-blk (DID 0x1042): the ESP boot volume and a second\n" ++
            "  DATA partition. `mount <esp|data>` switches volumes; `ls`/`cat`/`write` read\n" ++
            "  and write files, and writes persist on the disk across reboot.\n";
    }
    if (std.mem.eql(u8, name, "graphics")) {
        return "graphics\n" ++
            "  virtio-gpu (DID 0x1050) framebuffer: `screen` reports/fills the scanout,\n" ++
            "  `text` renders the 8x8 font, Road Pops is the on-screen terminal, and Driving\n" ++
            "  Award composites windows over it. 1280x720 B8G8R8X8, 2D blits only.\n";
    }
    return null;
}

fn cmd_help(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1) {
        if (lookup(args[0])) |cmd| {
            m.console.puts(cmd.name);
            m.console.puts(" - ");
            m.console.puts(cmd.help);
            m.console.puts("\nusage: ");
            m.console.puts(cmd.usage);
            m.console.puts("\n");
            return .none;
        }
        if (topic_body(args[0])) |body| {
            m.console.puts(body);
            return .none;
        }
        m.console.puts("help: no such command: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    }
    m.console.print_line("available commands:");
    const reg = ensure_registry();
    var width: usize = 0;
    for (reg) |cmd| width = @max(width, cmd.name.len);
    for (category_order) |cat| {
        m.console.puts(category_name(cat));
        m.console.puts("\n");
        for (reg) |cmd| {
            if (cmd.category != cat) continue;
            m.console.puts("  ");
            m.console.puts(cmd.name);
            var pad: usize = cmd.name.len;
            while (pad < width) : (pad += 1) m.console.putc(' ');
            m.console.puts("  ");
            m.console.puts(cmd.help);
            m.console.puts("\n");
        }
    }
    m.console.print_line("type 'help <command>' for details on a single command.");
    m.console.print_line("type 'help <topic>' for a topic page (networking, windows, storage, graphics).");
    return .none;
}

fn cmd_about(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("DipshitOS is a from-scratch AArch64 operating system.");
    m.console.print_line("Written in freestanding Zig: no libc, no POSIX.");
    m.console.print_line("Hosted under Apple Virtualization.framework on Apple silicon.");
    m.console.print_line("Milestone-two kernel proper: ExitBootServices, identity-map MMU,");
    m.console.print_line("polled serial console (ADR 0004). Handoff ABI v2 (ADR 0004 D5).");
    m.console.print_line("The interactive monitor command layer is tested against a mock");
    m.console.print_line("console; live serial input is not wired yet.");
    m.console.print_line("Type 'help' for a list of commands.");
    return .none;
}

fn cmd_version(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("dipshit-kernel");
    m.console.print_line("milestone-two kernel proper (ADR 0004)");
    m.console.print_line("handoff ABI v2");
    m.console.print_line("build label: m1.5 commands & personality (mock console)");
    return .none;
}

fn cmd_uname(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("DipshitOS aarch64");
    m.console.print_line("freestanding kernel; no POSIX compatibility");
    return .none;
}

fn cmd_handoff(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const h = &m.state.handoff;
    m.console.print_line("handoff v2");
    const fields = [_]struct { label: []const u8, value: u64 }{
        .{ .label = "magic", .value = h.magic },
        .{ .label = "version", .value = h.version },
        .{ .label = "kernel_base", .value = h.kernel_base },
        .{ .label = "kernel_size", .value = h.kernel_size },
        .{ .label = "system_table", .value = h.system_table },
        .{ .label = "image_handle", .value = h.image_handle },
        .{ .label = "stack_base", .value = h.stack_base },
        .{ .label = "stack_size", .value = h.stack_size },
        .{ .label = "flags", .value = h.flags },
    };
    for (fields) |field| {
        m.console.puts("  ");
        m.console.puts(field.label);
        var pad: usize = field.label.len;
        while (pad < 12) : (pad += 1) m.console.putc(' ');
        m.console.puts(" ");
        m.console.print_hex(field.value);
        m.console.puts("\n");
    }
    m.console.puts("  status");
    var pad: usize = "status".len;
    while (pad < 12) : (pad += 1) m.console.putc(' ');
    m.console.puts(" ");
    const err = handoff.validate(h);
    if (err == .none) {
        m.console.print_line("valid");
    } else {
        m.console.puts("invalid (");
        m.console.puts(handoff.error_name(err));
        m.console.puts(")\n");
    }
    return .none;
}

fn cmd_mem(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const view = m.state.map;
    const summary = memmap.summarize(view);
    m.console.puts("mem: descriptors=");
    m.console.print_hex(@intCast(view.count));
    m.console.puts(" size=");
    m.console.print_hex(@intCast(view.descriptor_size));
    m.console.puts(" version=");
    m.console.print_hex(view.descriptor_version);
    m.console.puts(" key=");
    m.console.print_hex(view.key);
    m.console.puts("\n");
    print_mem_row(m, "usable", summary.usable_pages);
    print_mem_row(m, "conventional", summary.conventional_pages);
    print_mem_row(m, "loader", summary.loader_pages);
    print_mem_row(m, "boot_services", summary.boot_services_pages);
    print_mem_row(m, "runtime", summary.runtime_pages);
    print_mem_row(m, "reserved", summary.reserved_pages);
    print_mem_row(m, "mmio", summary.mmio_pages);
    // Kernel image bounds come from the handoff record, not the map. The
    // end address is computed with a checked add so a hostile handoff can
    // never wrap (or panic a Debug build) — the same saturating policy as
    // the map summary.
    const h = &m.state.handoff;
    const kernel_end = std.math.add(u64, h.kernel_base, h.kernel_size) catch std.math.maxInt(u64);
    m.console.puts("  kernel: ");
    m.console.print_hex(h.kernel_base);
    m.console.puts("..");
    m.console.print_hex(kernel_end);
    m.console.puts(" (");
    m.console.print_hex(h.kernel_size);
    m.console.puts(" bytes)\n");
    return .none;
}

// ---------------------------------------------------------------------------
// ESP file-window commands (claim 3475 hard gate 5; FAT-backed since
// claim 6420)
// ---------------------------------------------------------------------------

/// List files: no argument lists the ESP root window (unchanged behavior);
/// a `/`-path lists a subdirectory straight from the FAT volume (milestone
/// four card 2 Stage C). Deterministic and grep-able.
fn cmd_ls(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0) return cmd_ls_path(m, args[0]);
    m.console.puts("ls: ");
    m.console.puts(esp.volume());
    m.console.puts("=");
    m.console.print_hex(@intCast(esp.esp_count()));
    m.console.puts("\n");
    const list = esp.entries();
    if (list.len == 0) {
        m.console.print_line("ls: no files on the ESP (FAT volume unavailable or empty)");
        return .none;
    }
    var width: usize = 0;
    for (list) |e| width = @max(width, e.name_len);
    for (list) |e| {
        m.console.puts("  ");
        m.console.puts(e.name[0..e.name_len]);
        var pad: usize = e.name_len;
        while (pad < width) : (pad += 1) m.console.putc(' ');
        m.console.puts("  ");
        m.console.print_hex(e.size);
        m.console.puts("  [");
        m.console.puts(switch (e.kind) {
            .esp_dir => "dir",
            .esp_file => esp.volume(),
        });
        m.console.puts("]\n");
    }
    return .none;
}

/// List a directory by `/`-path, straight from the FAT volume (the window
/// only snapshots the root). Same row format as the root listing, with a
/// path-aware header. Honest diagnostics distinguish a file ("is a file")
/// from an absent/non-directory path ("not found").
fn cmd_ls_path(m: *Monitor, path: []const u8) ExecError {
    var list: [esp.entries_max]fat.DirEntry = undefined;
    const n = fat.list_path(path, &list);
    if (n == 0) {
        m.console.puts("ls: ");
        m.console.puts(path);
        if (fat.file_size(path) != null) {
            m.console.print_line(": is a file, not a directory");
        } else {
            m.console.print_line(": not found (no such directory on the FAT volume)");
        }
        return .invalid_argument;
    }
    m.console.puts("ls: ");
    m.console.puts(path);
    m.console.puts(" entries=");
    m.console.print_hex(@intCast(n));
    m.console.puts("\n");
    var width: usize = 0;
    for (list[0..n]) |e| width = @max(width, e.name_len);
    for (list[0..n]) |e| {
        m.console.puts("  ");
        m.console.puts(e.name[0..e.name_len]);
        var pad: usize = e.name_len;
        while (pad < width) : (pad += 1) m.console.putc(' ');
        m.console.puts("  ");
        m.console.print_hex(e.size);
        m.console.puts("  [");
        m.console.puts(if (e.is_dir) "dir" else esp.volume());
        m.console.puts("]\n");
    }
    return .none;
}

/// Switch the active FAT volume (milestone four card 2): `mount esp`
/// re-mounts the EFI System Partition by its GPT type GUID; `mount data`
/// mounts the second FAT32 partition (the general-filesystem volume) by
/// its GUID. The window re-snapshots the newly active volume's root,
/// labeled honestly (`ls: <volume>=..`, `[<volume>]`).
fn cmd_mount(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    const is_data = std.mem.eql(u8, name, "data");
    if (!is_data and !std.mem.eql(u8, name, "esp")) {
        m.console.puts("mount: unknown volume: ");
        m.console.puts(name);
        m.console.print_line(" (expected esp or data)");
        return .invalid_argument;
    }
    const r = if (is_data) fat.mount_data(virtio_blk.disk_ops()) else fat.mount(virtio_blk.disk_ops());
    switch (r) {
        .ok => {
            esp.set_volume(if (is_data) "data" else "esp");
            esp.resnapshot();
            m.console.puts("mount: ");
            m.console.puts(name);
            m.console.puts(" vol_lba=");
            m.console.print_hex(fat.geometry().vol_lba);
            m.console.puts(" files=");
            m.console.print_hex(@intCast(esp.entry_count()));
            m.console.puts("\n");
            return .none;
        },
        .no_disk => {
            m.console.puts("mount: ");
            m.console.puts(name);
            m.console.print_line(": no disk (FAT volume unavailable)");
            return .not_implemented;
        },
        .bad_gpt => {
            m.console.puts("mount: ");
            m.console.puts(name);
            m.console.print_line(": partition not found (bad GPT or no such type GUID)");
            return .machine_failed;
        },
        .bad_bpb => {
            m.console.puts("mount: ");
            m.console.puts(name);
            m.console.print_line(": not a FAT32 volume (bad BPB)");
            return .machine_failed;
        },
        .io_failed => {
            m.console.puts("mount: ");
            m.console.puts(name);
            m.console.puts(": sector I/O failed (last lba=");
            m.console.print_hex_min(fat.last_fail_lba());
            m.console.print_line(")");
            return .machine_failed;
        },
    }
}

/// Print a file's content — a bare name serves the ESP window (unchanged
/// behavior); a `/`-path reads the FAT volume directly (milestone four
/// card 2 Stage C). Honest diagnostics for directories, files larger than
/// the bounded read buffer, and unknown paths.
fn cmd_cat(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return cmd_cat_path(m, name);
    const e = esp.lookup(name) orelse {
        m.console.puts("cat: ");
        m.console.puts(name);
        m.console.print_line(": not found (no such file on the ESP)");
        return .invalid_argument;
    };
    switch (e.kind) {
        .esp_dir => {
            m.console.puts("cat: ");
            m.console.puts(name);
            m.console.print_line(": is a directory");
            return .invalid_argument;
        },
        .esp_file => {
            if (e.len == 0 and e.size > 0) {
                m.console.puts("cat: ");
                m.console.puts(name);
                m.console.puts(": content not loaded (file is ");
                m.console.print_hex(e.size);
                m.console.puts(" bytes; the window keeps files up to ");
                m.console.print_hex(esp.esp_content_max);
                m.console.print_line(" bytes)");
                return .invalid_argument;
            }
        },
    }
    const content = esp.content_of(e);
    m.console.puts(content);
    // A trailing newline keeps the shell prompt on its own line; a file
    // that already ends with one is printed verbatim (no double blank).
    if (content.len == 0 or content[content.len - 1] != '\n') m.console.puts("\n");
    return .none;
}

/// Print a file by `/`-path, read straight from the FAT volume. The file's
/// size is checked first: a file larger than the bounded read buffer is
/// reported honestly (never silently truncated).
fn cmd_cat_path(m: *Monitor, path: []const u8) ExecError {
    const size = fat.file_size(path) orelse {
        m.console.puts("cat: ");
        m.console.puts(path);
        m.console.print_line(": not found (no such file on the FAT volume)");
        return .invalid_argument;
    };
    var buf: [esp.write_content_max]u8 = undefined;
    if (size > @as(u32, @intCast(buf.len))) {
        m.console.puts("cat: ");
        m.console.puts(path);
        m.console.puts(": file is ");
        m.console.print_hex(size);
        m.console.puts(" bytes; direct read caps at ");
        m.console.print_hex(esp.write_content_max);
        m.console.print_line(" bytes");
        return .invalid_argument;
    }
    const got = fat.read_file(path, &buf) orelse {
        m.console.puts("cat: ");
        m.console.puts(path);
        m.console.print_line(": not found (no such file on the FAT volume)");
        return .invalid_argument;
    };
    m.console.puts(buf[0..got]);
    if (got == 0 or buf[got - 1] != '\n') m.console.puts("\n");
    return .none;
}

/// Write text to the ESP's FAT32 volume (claim 6420 — the real storage
/// driver replacing claim 3475's NVRAM variables): the file survives
/// reboot because it is on the disk itself. Capacity is checked before the
/// write; a failed sector write is reported honestly, never faked.
fn cmd_write(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    const parts = args[1..];
    var len: usize = 0;
    for (parts, 0..) |p, i| len += p.len + (if (i > 0) @as(usize, 1) else 0);
    if (len > esp.write_content_max) {
        m.console.puts("write: content too long (max ");
        m.console.print_hex(esp.write_content_max);
        m.console.puts(" bytes, got ");
        m.console.print_hex(@intCast(len));
        m.console.print_line(")");
        return .invalid_argument;
    }
    var buf: [esp.write_content_max]u8 = undefined;
    var n: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    switch (esp.write_file(name, buf[0..n])) {
        .ok => {
            m.console.puts("write: ok (persisted ");
            m.console.print_u64(n);
            m.console.puts(" bytes to FAT on the ");
            m.console.puts(esp.volume());
            m.console.puts(")\n");
            return .none;
        },
        .no_disk => {
            m.console.puts("write: ");
            m.console.puts(name);
            m.console.print_line(": not persisted - no disk (FAT volume unavailable)");
            return .not_implemented;
        },
        .name_invalid => {
            m.console.puts("write: invalid file name: ");
            m.console.puts(name);
            m.console.puts(" (max ");
            m.console.print_u64(esp.name_max);
            m.console.puts(" printable ASCII chars, no '/' or '\\')\n");
            return .invalid_argument;
        },
        .name_too_long => {
            m.console.puts("write: ");
            m.console.puts(name);
            m.console.print_line(": does not fit FAT 8.3 (max 8 chars + 3-char extension)");
            return .invalid_argument;
        },
        .content_too_long => {
            m.console.puts("write: content too long (max ");
            m.console.print_hex(esp.write_content_max);
            m.console.puts(" bytes, got ");
            m.console.print_hex(@intCast(n));
            m.console.print_line(")");
            return .invalid_argument;
        },
        .bad_path => {
            m.console.puts("write: ");
            m.console.puts(name);
            m.console.print_line(": parent directory not found");
            return .invalid_argument;
        },
        .disk_full => {
            m.console.puts("write: ");
            m.console.puts(name);
            m.console.print_line(": not persisted - disk full (no free cluster or root-directory slot)");
            return .invalid_argument;
        },
        .write_failed => {
            m.console.puts("write: ");
            m.console.puts(name);
            m.console.puts(": FAT write failed (last lba=");
            m.console.print_hex_min(fat.last_fail_lba());
            m.console.print_line(") - file NOT persisted");
            return .machine_failed;
        },
    }
}

// ---------------------------------------------------------------------------
// Physical page allocator command (next-card milestone)
// ---------------------------------------------------------------------------

fn cmd_pages(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1 and !std.mem.eql(u8, args[0], "selftest")) {
        m.console.puts("usage: pages [selftest]\n");
        return .usage;
    }
    const s = alloc.stats();
    if (!s.armed) {
        if (args.len == 1) {
            m.console.print_line("pages selftest: allocator not armed");
        } else {
            m.console.print_line("pages: allocator not armed (no poolable memory in span)");
        }
        return .none;
    }
    if (args.len == 1) return pages_selftest(m, s);
    m.console.puts("pages: armed=1 total=");
    m.console.print_hex(s.total_pages);
    m.console.puts(" free=");
    m.console.print_hex(s.free_pages);
    m.console.puts(" excluded=");
    m.console.print_hex(s.excluded_pages);
    m.console.puts(" regions=");
    m.console.print_hex(@intCast(s.region_count));
    m.console.puts(" span=");
    m.console.print_hex(s.span_pages);
    m.console.puts("\n");
    return .none;
}

/// Deterministic bounded alloc/free battery against the module allocator:
/// alloc 1 / free, alloc 8 / free, alloc 3 + alloc 5 (contiguous) / free
/// both, alloc the largest free run / free, alloc total+1 -> none. Leaves
/// the pool exactly as it found it. The pool may be fragmented across
/// regions (real VZ maps are), so the "big" step allocates the largest
/// contiguous free run — which is guaranteed to fit — rather than the
/// whole pool (which need not be contiguous).
fn pages_selftest(m: *Monitor, s: alloc.Stats) ExecError {
    const total = s.total_pages;
    const initial_free = s.free_pages;
    var failed = false;
    if (pages_alloc_line(m, 1)) |base| failed = failed or !pages_free_line(m, base, 1, "free");
    if (pages_alloc_line(m, 8)) |base| failed = failed or !pages_free_line(m, base, 8, "free");
    const a3 = pages_alloc_line(m, 3);
    const a5 = pages_alloc_line(m, 5);
    if (a3 != null and a5 != null) {
        const ok3 = alloc.free_pages(a3.?, 3);
        const ok5 = alloc.free_pages(a5.?, 5);
        m.console.print_line(if (ok3 and ok5) "pages selftest: free both ok" else "pages selftest: free both FAILED");
        failed = failed or !(ok3 and ok5);
    } else {
        failed = true;
    }
    const largest = alloc.largest_free_run();
    if (pages_alloc_line(m, largest)) |base| failed = failed or !pages_free_line(m, base, largest, "free");
    // Allocating one more than the whole pool must fail.
    if (pages_alloc_line(m, total + 1) != null) failed = true;
    const after = alloc.stats();
    // The pool is "restored" when free is back to where the battery found
    // it (with exclusions, free < total by design — claim 5162).
    const restored = after.free_pages == initial_free;
    m.console.puts("pages selftest: ");
    m.console.puts(if (failed or !restored) "FAILED" else "ok");
    m.console.puts(" free=");
    m.console.print_hex(after.free_pages);
    m.console.puts("\n");
    return .none;
}

/// Print "alloc <n> -> <base>" (or "-> none (out of memory)") and return
/// the base on success.
fn pages_alloc_line(m: *Monitor, n: u64) ?u64 {
    m.console.puts("pages selftest: alloc ");
    m.console.print_u64(n);
    m.console.puts(" -> ");
    const base = alloc.alloc_pages(n);
    if (base) |b| {
        m.console.print_hex(b);
    } else {
        m.console.puts("none (out of memory)");
    }
    m.console.puts("\n");
    return base;
}

fn pages_free_line(m: *Monitor, base: u64, n: u64, label: []const u8) bool {
    const ok = alloc.free_pages(base, n);
    m.console.puts("pages selftest: ");
    m.console.puts(label);
    m.console.puts(if (ok) " ok" else " FAILED");
    m.console.puts("\n");
    return ok;
}

// ---------------------------------------------------------------------------
// Shell-style utility commands
// ---------------------------------------------------------------------------

fn cmd_echo(m: *Monitor, args: []const []const u8) ExecError {
    for (args, 0..) |arg, index| {
        if (index > 0) m.console.putc(' ');
        m.console.puts(arg);
    }
    m.console.puts("\n");
    return .none;
}

fn cmd_clear(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    // ANSI erase-in-display + cursor home. On terminals without ANSI
    // support this sequence is ignored harmlessly; the fallback is a
    // documented no-op. Deterministic and testable at the byte level.
    m.console.puts("\x1b[2J\x1b[H");
    return .none;
}

fn cmd_hex(m: *Monitor, args: []const []const u8) ExecError {
    for (args) |arg| {
        const value = parseInt(arg) catch {
            m.console.puts("hex: invalid number: ");
            m.console.puts(arg);
            m.console.puts("\n");
            return .invalid_argument;
        };
        m.console.print_hex_min(value);
        m.console.puts("\n");
    }
    return .none;
}

/// `roadpops` — report the Road Pops tee console (claim 1574, milestone
/// six G3): armed (the framebuffer target is wired — the boot terminal is
/// on the screen), dirty (a console write batch is waiting for the idle
/// loop's drain-present), and the presents pushed since arm.
fn cmd_roadpops(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const r = road_pops.report();
    m.console.puts("roadpops: armed=");
    m.console.puts(if (r.armed) "1" else "0");
    m.console.puts(" dirty=");
    m.console.puts(if (r.dirty) "1" else "0");
    m.console.puts(" presents=");
    m.console.print_u64(r.presents);
    m.console.puts("\n");
    return .none;
}

/// `win` — report the Driving Award window manager (claim 1543, milestone
/// six G5): the registry (id/title/kind/rect/z-order/dirty/visible/owner),
/// the focused window, and the composite presents. `win focus <n>` focuses
/// a window, `win raise <n>` raises it to the top, `win move <n> <x> <y>`
/// moves a user window (clamped on-scanout), `win close <n>` releases a
/// user window, `win list <pid>` filters the registry to one process's
/// windows, and `win hit <x> <y>` hit-tests a point (focusing the topmost
/// window there).
fn cmd_win(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "focus")) {
            if (args.len != 2) {
                m.console.print_line("usage: win focus <n>");
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                m.console.puts("win focus: invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                m.console.print_line("win focus: id out of range");
                return .invalid_argument;
            }
            if (!driving_award.focus(@intCast(id))) {
                m.console.print_line("win focus: no such window");
                return .invalid_argument;
            }
            // The focus change may alter the clock's focus line — repaint.
            _ = driving_award.mark_dirty(0);
            _ = driving_award.mark_dirty(1);
            _ = driving_award.composite();
            m.console.puts("win focus: focused=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "raise")) {
            if (args.len != 2) {
                m.console.print_line("usage: win raise <n>");
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                m.console.puts("win raise: invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                m.console.print_line("win raise: id out of range");
                return .invalid_argument;
            }
            if (!driving_award.raise(@intCast(id))) {
                m.console.print_line("win raise: no such window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("win raise: raised=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "move")) {
            if (args.len != 4) {
                m.console.print_line("usage: win move <n> <x> <y>");
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                m.console.puts("win move: invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            const x = parseInt(args[2]) catch {
                m.console.print_line("win move: invalid x");
                return .invalid_argument;
            };
            const y = parseInt(args[3]) catch {
                m.console.print_line("win move: invalid y");
                return .invalid_argument;
            };
            if (id > 255 or x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) {
                m.console.print_line("win move: coordinate out of range");
                return .invalid_argument;
            }
            if (!driving_award.user_move(@intCast(id), @intCast(x), @intCast(y))) {
                m.console.print_line("win move: no such user window (the terminal + clock are fixed)");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("win move: moved=");
            m.console.print_u64(id);
            m.console.puts(" to ");
            m.console.print_u64(x);
            m.console.puts(",");
            m.console.print_u64(y);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "close")) {
            if (args.len != 2) {
                m.console.print_line("usage: win close <n>");
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                m.console.puts("win close: invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                m.console.print_line("win close: id out of range");
                return .invalid_argument;
            }
            if (!driving_award.user_close(@intCast(id))) {
                m.console.print_line("win close: no such user window (the terminal + clock are fixed)");
                return .invalid_argument;
            }
            // The close marked the fixed windows dirty — composite now to
            // reveal whatever sat under the released window.
            _ = driving_award.composite();
            m.console.puts("win close: closed=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "list")) {
            if (args.len != 2) {
                m.console.print_line("usage: win list <pid>");
                return .usage;
            }
            const pid = parseInt(args[1]) catch {
                m.console.puts("win list: invalid pid: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            const want: usize = @intCast(pid); // aarch64: usize == u64, lossless
            var matches: usize = 0;
            var i: usize = 0;
            while (i < driving_award.count()) : (i += 1) {
                const w = driving_award.window_at(i).?;
                if (w.owner == want) matches += 1;
            }
            m.console.puts("win list: pid=");
            m.console.print_u64(pid);
            m.console.puts(" matches=");
            m.console.print_u64(matches);
            m.console.puts("\n");
            i = 0;
            while (i < driving_award.count()) : (i += 1) {
                const w = driving_award.window_at(i).?;
                if (w.owner == want) print_win_row(m, i, w);
            }
            return .none;
        }
        if (std.mem.eql(u8, args[0], "hit")) {
            if (args.len != 3) {
                m.console.print_line("usage: win hit <x> <y>");
                return .usage;
            }
            const x = parseInt(args[1]) catch {
                m.console.print_line("win hit: invalid x");
                return .invalid_argument;
            };
            const y = parseInt(args[2]) catch {
                m.console.print_line("win hit: invalid y");
                return .invalid_argument;
            };
            if (x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) {
                m.console.print_line("win hit: coordinate out of range");
                return .invalid_argument;
            }
            const hit = driving_award.hit_test(@intCast(x), @intCast(y));
            m.console.puts("win hit: ");
            m.console.print_u64(x);
            m.console.puts(",");
            m.console.print_u64(y);
            m.console.puts(" -> ");
            if (hit) |hid| {
                m.console.print_u64(hid);
                _ = driving_award.focus(hid);
            } else {
                m.console.puts("none");
            }
            m.console.puts("\n");
            return .none;
        }
        m.console.print_line("win: unknown subcommand (try 'win', 'win focus <n>', 'win raise <n>', 'win move <n> <x> <y>', 'win close <n>', 'win list <pid>', or 'win hit <x> <y>')");
        return .invalid_argument;
    }
    if (!driving_award.armed()) {
        m.console.print_line("win: window manager not armed (no gpu device — the default VM)");
        return .none;
    }
    m.console.puts("win: windows=");
    m.console.print_u64(driving_award.count());
    m.console.puts(" focused=");
    m.console.print_u64(driving_award.focused_window_id());
    m.console.puts(" presents=");
    m.console.print_u64(driving_award.presents_pushed());
    m.console.puts("\n");
    var i: usize = 0;
    while (i < driving_award.count()) : (i += 1) {
        print_win_row(m, i, driving_award.window_at(i).?);
    }
    return .none;
}

/// Print one registry row for the window at index `i` — the shared formatter
/// behind the `win` report and `win list <pid>`. The trailing `owner=` column
/// is the per-process-ownership visibility (claim 0487 follow-on): a pid for a
/// `.user` window, `-` for the fixed kernel-owned terminal + clock.
fn print_win_row(m: *Monitor, i: usize, w: *const driving_award.Window) void {
    m.console.puts("win[");
    m.console.print_u64(i);
    m.console.puts("]: ");
    m.console.puts(w.title);
    m.console.puts(" ");
    m.console.puts(driving_award.kind_name(w.kind));
    m.console.puts(" rect=");
    m.console.print_u64(w.x);
    m.console.puts(",");
    m.console.print_u64(w.y);
    m.console.puts(",");
    m.console.print_u64(w.w);
    m.console.puts(",");
    m.console.print_u64(w.h);
    m.console.puts(" dirty=");
    m.console.puts(if (w.dirty) "1" else "0");
    m.console.puts(" visible=");
    m.console.puts(if (w.visible) "1" else "0");
    m.console.puts(" z=");
    m.console.print_u64(i);
    m.console.puts(" owner=");
    if (w.owner) |pid| {
        m.console.print_u64(@intCast(pid));
    } else {
        m.console.puts("-");
    }
    m.console.puts("\n");
}

/// `input` — report the keyboard/pointer event FIFO (claim 6050, milestone
/// seven I3): armed state, FIFO occupancy + drop count, the last decoded
/// keyboard event, and the last recorded pointer report.
fn cmd_input(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const r = input.report();
    m.console.puts("input: armed=");
    m.console.puts(if (r.armed) "1" else "0");
    m.console.puts(" fifo=");
    m.console.print_u64(r.fifo_used);
    m.console.puts("/");
    m.console.print_u64(r.fifo_max);
    m.console.puts(" dropped=");
    m.console.print_u64(r.dropped);
    m.console.puts(" events=");
    m.console.print_u64(r.events);
    m.console.puts(" kb-mods=");
    m.console.print_hex_min(r.kb_mods);
    m.console.puts(" kb-usage=");
    m.console.print_hex_min(r.kb_last_usage);
    m.console.puts(" kb-byte=");
    if (r.kb_last_byte != 0 and r.kb_last_byte >= 0x20 and r.kb_last_byte <= 0x7e) {
        m.console.putc(r.kb_last_byte);
    } else {
        m.console.print_hex_min(r.kb_last_byte);
    }
    m.console.puts(" ptr-btns=");
    m.console.print_u64(r.ptr_buttons);
    m.console.puts(" ptr-x=");
    m.console.print_u64(r.ptr_x);
    m.console.puts(" ptr-y=");
    m.console.print_u64(r.ptr_y);
    m.console.puts(" ptr-reports=");
    m.console.print_u64(r.ptr_reports);
    m.console.puts("\n");
    return .none;
}

fn cmd_usb(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0 and std.mem.eql(u8, args[0], "devices")) return cmd_usb_devices(m);
    if (args.len > 0 and std.mem.eql(u8, args[0], "report")) return cmd_usb_report(m, args);
    if (!xhci.xhci_ready) {
        m.console.puts("usb: no XHCI device (");
        m.console.puts(if (xhci.xhci_fail.len > 0) xhci.xhci_fail else "DID 0x1a06 not found on bus 0");
        m.console.puts(")\n");
        return .none;
    }
    m.console.puts("usb: did=");
    m.console.print_hex(xhci.xhci_did);
    m.console.puts(" class=");
    m.console.print_hex(xhci.xhci_class);
    m.console.puts(" dev=");
    m.console.print_u64(xhci.xhci_dev);
    m.console.puts("\n");
    m.console.puts("usb: bar0=");
    m.console.print_hex(xhci.xhci_bar0);
    m.console.puts(" bar1=");
    m.console.print_hex(xhci.xhci_bar1);
    m.console.puts(" base=");
    m.console.print_hex(xhci.xhci_base);
    m.console.puts("\n");
    m.console.puts("usb: caplen=");
    m.console.print_hex(xhci.xhci_caplen);
    m.console.puts(" hciver=");
    m.console.print_hex(xhci.xhci_hciver);
    m.console.puts(" dboff=");
    m.console.print_hex(xhci.xhci_dboff);
    m.console.puts(" rtsoff=");
    m.console.print_hex(xhci.xhci_rtsoff);
    m.console.puts("\n");
    m.console.puts("usb: hcsparams1=");
    m.console.print_hex(xhci.xhci_hcsparams1);
    m.console.puts(" hcsparams2=");
    m.console.print_hex(xhci.xhci_hcsparams2);
    m.console.puts(" hcsparams3=");
    m.console.print_hex(xhci.xhci_hcsparams3);
    m.console.puts(" hccparams1=");
    m.console.print_hex(xhci.xhci_hccparams1);
    m.console.puts("\n");
    m.console.puts("usb: maxslots=");
    m.console.print_u64(xhci.hcsparams1_max_slots(xhci.xhci_hcsparams1));
    m.console.puts(" maxintrs=");
    m.console.print_u64(xhci.hcsparams1_max_intrs(xhci.xhci_hcsparams1));
    m.console.puts(" maxports=");
    m.console.print_u64(xhci.hcsparams1_max_ports(xhci.xhci_hcsparams1));
    m.console.puts("\n");
    m.console.puts("usb: pre-reset sts=");
    m.console.print_hex(xhci.xhci_pre_reset_usbsts);
    m.console.puts(" cmd=");
    m.console.print_hex(xhci.xhci_pre_reset_usbcmd);
    m.console.puts("\n");
    m.console.puts("usb: usbsts=");
    m.console.print_hex(xhci.xhci_usbsts());
    m.console.puts(" noop_cc=");
    m.console.print_hex(xhci.xhci_noop_cc);
    m.console.puts(" noop=");
    m.console.puts(if (xhci.xhci_noop_done) "ok" else "fail");
    m.console.puts("\n");
    // Live port status: one line per port, with the connect/enable/power
    // bits decoded (the I1 report — I2 turns these into enumerated devices).
    const max_ports = xhci.hcsparams1_max_ports(xhci.xhci_hcsparams1);
    var port: u8 = 1;
    while (port <= max_ports) : (port += 1) {
        const psc = xhci.xhci_port_status(port);
        m.console.puts("usb: port");
        m.console.print_u64(port);
        m.console.puts("=");
        m.console.print_hex(psc);
        m.console.puts(" ccs=");
        m.console.puts(if ((psc & 0x1) != 0) "1" else "0");
        m.console.puts(" ped=");
        m.console.puts(if ((psc & 0x2) != 0) "1" else "0");
        m.console.puts(" pp=");
        m.console.puts(if ((psc & 0x200) != 0) "1" else "0");
        m.console.puts(" ps=");
        m.console.print_u64((psc >> 10) & 0xf);
        m.console.puts("\n");
    }
    return .none;
}

/// `usb devices` — the enumerated HID device table (I2). One line per
/// enumerated device: slot/port/speed + VID/PID/class/protocol + the
/// interrupt-IN endpoint + the HID boot-protocol negotiation result.
fn cmd_usb_devices(m: *Monitor) ExecError {
    if (!xhci.xhci_ready) {
        m.console.puts("usb devices: no XHCI device\n");
        return .none;
    }
    if (!xhci.enum_done) {
        m.console.puts("usb devices: enumeration incomplete (");
        m.console.puts(if (xhci.enum_fail.len > 0) xhci.enum_fail else "no devices enumerated");
        m.console.puts(")\n");
        return .none;
    }
    m.console.puts("usb devices: count=");
    m.console.print_u64(xhci.enum_count);
    m.console.puts("\n");
    var i: usize = 0;
    while (i < xhci.EnumMax) : (i += 1) {
        const d = xhci.enum_devs[i];
        if (!d.present) continue;
        m.console.puts("usb dev");
        m.console.print_u64(i);
        m.console.puts(": slot=");
        m.console.print_u64(d.slot_id);
        m.console.puts(" port=");
        m.console.print_u64(d.port);
        m.console.puts(" speed=");
        m.console.print_u64(d.speed);
        m.console.puts(" vid=");
        m.console.print_hex_min(d.vid);
        m.console.puts(" pid=");
        m.console.print_hex_min(d.pid);
        m.console.puts(" class=");
        m.console.print_u64(d.class);
        m.console.puts(" protocol=");
        m.console.print_u64(d.protocol);
        m.console.puts(" epin=");
        m.console.print_u64(d.ep_in_num);
        m.console.puts(" maxpkt=");
        m.console.print_u64(d.ep_in_maxpkt);
        m.console.puts(" interval=");
        m.console.print_u64(d.ep_in_interval);
        m.console.puts(" boot=");
        m.console.puts(if (d.hid_boot) "1" else "0");
        m.console.puts("\n");
    }
    return .none;
}

/// `usb report [<dev>]` — poll the device's interrupt-IN endpoint for the
/// last HID report and print it raw + a boot-protocol decode (I2). Defaults
/// to device 0 (the keyboard, if present).
fn cmd_usb_report(m: *Monitor, args: []const []const u8) ExecError {
    if (!xhci.xhci_ready) {
        m.console.puts("usb report: no XHCI device\n");
        return .none;
    }
    var dev_idx: usize = 0;
    if (args.len > 1) {
        dev_idx = parseInt(args[1]) catch 0;
    }
    if (dev_idx >= xhci.EnumMax or !xhci.enum_devs[dev_idx].present) {
        m.console.puts("usb report: no device ");
        m.console.print_u64(dev_idx);
        m.console.puts("\n");
        return .none;
    }
    const d = xhci.enum_devs[dev_idx];
    if (d.ep_in_num == 0) {
        m.console.puts("usb report: device has no interrupt-IN endpoint\n");
        return .none;
    }
    const got = xhci.xhci_poll_intr(d.slot_id);
    if (!got) {
        m.console.puts("usb report: dev");
        m.console.print_u64(dev_idx);
        m.console.puts(" no report (timeout)\n");
        return .none;
    }
    const rep = xhci.xhci_report(d.slot_id);
    m.console.puts("usb report: dev");
    m.console.print_u64(dev_idx);
    m.console.puts(" seq=");
    m.console.print_u64(d.report_seq);
    m.console.puts(" len=");
    m.console.print_u64(rep.len);
    m.console.puts(" bytes=");
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        if (i > 0) m.console.puts(" ");
        m.console.print_hex_min(rep.bytes[i]);
    }
    m.console.puts("\n");
    // Boot-protocol decode: keyboard = modifier byte + up to 6 keycodes;
    // mouse = buttons + X + Y. Raw bytes are the ground truth.
    if (xhci.hid_kind[dev_idx] == .keyboard and rep.len >= 8) {
        m.console.puts("usb report: kb mod=");
        m.console.print_hex_min(rep.bytes[0]);
        m.console.puts(" keys=");
        var k: usize = 2;
        while (k < 8) : (k += 1) {
            if (rep.bytes[k] != 0) {
                m.console.print_hex_min(rep.bytes[k]);
                m.console.puts(" ");
            }
        }
        m.console.puts("\n");
    } else if (xhci.hid_kind[dev_idx] == .mouse and rep.len >= 3) {
        m.console.puts("usb report: ptr btn=");
        m.console.print_u64(rep.bytes[0]);
        m.console.puts(" x=");
        m.console.print_u64(rep.bytes[1]);
        m.console.puts(" y=");
        m.console.print_u64(rep.bytes[2]);
        m.console.puts("\n");
    }
    return .none;
}

fn cmd_repeat(m: *Monitor, args: []const []const u8) ExecError {
    const count = parseInt(args[0]) catch {
        m.console.puts("repeat: invalid count: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (count < 1 or count > repeat_max_count) {
        m.console.puts("repeat: count must be between 1 and ");
        m.console.print_u64(repeat_max_count);
        m.console.puts("\n");
        return .invalid_argument;
    }
    // Measure the joined text length (saturating) before printing anything.
    const parts = args[1..];
    var text_len: usize = 0;
    for (parts) |part| {
        text_len = @min(repeat_max_bytes, text_len +| part.len);
    }
    if (parts.len > 1) text_len = @min(repeat_max_bytes, text_len + parts.len - 1);
    const per_line = text_len + 1; // + the trailing newline
    if (per_line > repeat_max_bytes or count > @as(u64, repeat_max_bytes / per_line)) {
        m.console.puts("repeat: output too large (max ");
        m.console.print_u64(repeat_max_bytes);
        m.console.puts(" bytes)\n");
        return .invalid_argument;
    }
    var n: u64 = 0;
    while (n < count) : (n += 1) {
        for (parts, 0..) |part, index| {
            if (index > 0) m.console.putc(' ');
            m.console.puts(part);
        }
        m.console.puts("\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Machine control commands
// ---------------------------------------------------------------------------

fn cmd_reboot(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    return report_machine(m, "reboot", m.machine.reboot());
}

fn cmd_shutdown(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    return report_machine(m, "shutdown", m.machine.shutdown());
}

// ---------------------------------------------------------------------------
// Personality commands
// ---------------------------------------------------------------------------

/// Fixed mascot art (bounded, deterministic, no state). Runtime-built into
/// module storage (not a const table): a const array of string slices would
/// hold link-time absolute pointers, wrong at the kernel's runtime load
/// base (claim 0015 root cause — the flat loader applies no relocations).
var elephant_storage: [12][]const u8 = undefined;
var elephant_ready = false;
pub fn elephant_lines() []const []const u8 {
    if (!elephant_ready) {
        elephant_storage[0] = "      _    _";
        elephant_storage[1] = "     (o)  (o)";
        elephant_storage[2] = "       \\  /";
        elephant_storage[3] = "       _||_";
        elephant_storage[4] = "      /    \\";
        elephant_storage[5] = "     |  __  |";
        elephant_storage[6] = "     | |  | |";
        elephant_storage[7] = "     |_|  |_|";
        elephant_storage[8] = "    /  |  |  \\";
        elephant_storage[9] = "   /   |  |   \\";
        elephant_storage[10] = "  |    |  |    |";
        elephant_storage[11] = "  |____|  |____|";
        elephant_ready = true;
    }
    return &elephant_storage;
}

// ---------------------------------------------------------------------------
// Interrupt-controller + timer command (claim 7948)
// ---------------------------------------------------------------------------

/// Report the GIC + generic-timer state. Hardware-free: reads the discovery
/// globals (pre-exit ACPI values) and the timer counters, so it runs
/// unchanged in a host test process (armed=0, gic=none there).
fn cmd_timer(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("timer: armed=");
    m.console.print_u64(if (gic.armed() and timer.armed()) 1 else 0);
    m.console.puts(" gic=");
    m.console.puts(gic.kind_name());
    m.console.puts(" dist=");
    m.console.print_hex_min(gic.dist_base);
    m.console.puts(" ppi=");
    m.console.print_hex_min(timer.ppi);
    m.console.puts(" freq=");
    m.console.print_hex_min(timer.freq);
    m.console.puts(" ticks=");
    m.console.print_u64(timer.ticks);
    m.console.puts(" irq=");
    m.console.print_u64(timer.irq_ticks);
    m.console.puts(" poll=");
    m.console.print_u64(timer.poll_ticks);
    m.console.puts(" acked=");
    m.console.print_u64(gic.irqs_acked);
    m.console.puts(" first=");
    m.console.print_hex_min(gic.first_intid);
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// Tick-driven task scheduler command (claim 5275)
// ---------------------------------------------------------------------------

/// Report the round-robin scheduler state: enabled/current/switches plus
/// per-task saves/resumes/advances. Deterministic and grep-able; runs
/// unchanged in a host test process (tasks may be registered but never
/// started there, so the counters read 0).
fn cmd_tasks(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const s = scheduler.stats();
    m.console.puts("tasks: enabled=");
    m.console.print_u64(if (s.enabled) 1 else 0);
    m.console.puts(" current=");
    m.console.print_u64(@intCast(s.current));
    m.console.puts(" switches=");
    m.console.print_u64(s.switches);
    // Claim 6729: the lifecycle's pool/zombie counts (registered slots vs
    // the fixed pool; zombies awaiting the idle task's reap).
    m.console.puts(" pool=");
    m.console.print_u64(@intCast(s.count));
    m.console.puts("/");
    m.console.print_u64(@intCast(scheduler.max_tasks));
    m.console.puts(" zombies=");
    m.console.print_u64(@intCast(s.zombies));
    m.console.puts("\n");
    // Scan the full pool: reaped (free) slots are skipped, so a freed mid
    // slot never hides later-registered tasks.
    var width: usize = 0;
    var i: usize = 0;
    while (i < scheduler.max_tasks) : (i += 1) {
        if (scheduler.task_info(i)) |t| width = @max(width, t.name.len);
    }
    i = 0;
    while (i < scheduler.max_tasks) : (i += 1) {
        const info = scheduler.task_info(i) orelse continue;
        m.console.puts("  ");
        m.console.puts(info.name);
        var pad: usize = info.name.len;
        while (pad <= width) : (pad += 1) m.console.putc(' ');
        m.console.puts("saves=");
        m.console.print_u64(info.saves);
        m.console.puts(" resumes=");
        m.console.print_u64(info.resumes);
        m.console.puts(" advances=");
        m.console.print_u64(info.advances);
        m.console.puts(" state=");
        m.console.puts(scheduler.state_name(info.state));
        m.console.puts("\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Process command (claim 3848)
// ---------------------------------------------------------------------------

/// Report the process table (claim 3848): one line per non-free process
/// descriptor — id, name, lifecycle state, the bound executor task ("reaped"
/// once exited), the user stack VA, and the exit status (only for exited
/// processes). The process owns the PROGRAM (image + address space + state
/// + exit status) above the task pool: after the idle task reaps the
/// executor slot, `procs` still shows the program's exit status — the
/// information the task lifecycle alone throws away. Deterministic and
/// grep-able.
fn cmd_procs(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("procs: count=");
    m.console.print_u64(@intCast(process.count()));
    m.console.puts("\n");
    var id: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        const info = process.info(id) orelse continue;
        m.console.puts("procs: id=");
        m.console.print_u64(@intCast(info.id));
        m.console.puts(" name=");
        m.console.puts(info.name);
        m.console.puts(" state=");
        m.console.puts(process.state_name(info.state));
        m.console.puts(" task=");
        // Claim 4613: an exited process keeps its executor slot until the
        // lifecycle reap frees its pages — the row still reads `reaped`
        // (the slot is a zombie, no longer executing the program).
        if (info.state == .exited) {
            m.console.puts("reaped");
        } else if (info.task_id) |task_id| {
            m.console.print_u64(@intCast(task_id));
        } else {
            m.console.puts("-");
        }
        m.console.puts(" stack=");
        m.console.print_hex(info.stack_va);
        m.console.puts(" exit=");
        if (info.state == .exited) {
            m.console.print_u64(info.exit_status);
        } else {
            m.console.puts("-");
        }
        m.console.puts("\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Kill command (milestone-four follow-on 3, card 3c — claim 7786)
// ---------------------------------------------------------------------------

/// `kill <pid|name>` — the kernel, not the program, owns process lifetime.
/// The target is looked up in the process registry (by `procs` id or by
/// process name), then ARMED for termination: `scheduler.request_kill`
/// marks its TCB, and the ring converts the target's NEXT selection into
/// the existing exit path with the reserved status 137 (the counter's
/// `exit=137` in `procs` / `tasks user-exec exited status=137`). No new
/// syscall — ADR 0007 stays frozen. Every refusal is clean and exact
/// (host-tested strings).
fn cmd_kill(m: *Monitor, args: []const []const u8) ExecError {
    const arg = args[0];
    // Resolve the target process: by numeric `procs` id, else by name.
    const pid: ?usize = if (parseInt(arg)) |value| blk: {
        if (value < process.max_processes and process.info(@as(usize, @intCast(value))) != null) {
            break :blk @as(usize, @intCast(value));
        }
        break :blk null;
    } else |_| blk: {
        var id: usize = 0;
        while (id < process.max_processes) : (id += 1) {
            const info = process.info(id) orelse continue;
            if (std.mem.eql(u8, info.name, arg)) break :blk id;
        }
        break :blk null;
    };
    const pid_value = pid orelse {
        m.console.puts("kill: no such process: ");
        m.console.puts(arg);
        m.console.puts("\n");
        return .invalid_argument;
    };
    const info = process.info(pid_value).?;
    if (info.state == .exited) {
        m.console.puts("kill: ");
        m.console.puts(info.name);
        m.console.puts(" already exited\n");
        return .invalid_argument;
    }
    // A created-but-unbound process (exec's pre-spawn window) has no
    // executor to terminate; a running process names its executor slot.
    const task_id = info.task_id orelse {
        m.console.puts("kill: ");
        m.console.puts(info.name);
        m.console.puts(" not running\n");
        return .invalid_argument;
    };
    switch (scheduler.request_kill(task_id)) {
        .ok => {
            m.console.puts("kill: ");
            m.console.puts(info.name);
            m.console.puts(" armed\n");
            return .none;
        },
        .not_found => {
            m.console.puts("kill: ");
            m.console.puts(info.name);
            m.console.puts(" not found\n");
            return .invalid_argument;
        },
        .already_exited => {
            m.console.puts("kill: ");
            m.console.puts(info.name);
            m.console.puts(" already exited\n");
            return .invalid_argument;
        },
        .refused => {
            m.console.print_line("kill: cannot kill the shell or scheduler-owned idle task");
            return .invalid_argument;
        },
    }
}

// ---------------------------------------------------------------------------
// IPC mailbox command (milestone-four follow-on 3, card 3f — claim 5965)
// ---------------------------------------------------------------------------

/// `mbox [<pid>]` — dump the per-process IPC mailboxes: for every live
/// process (or just the one named by `pid`), the pending message count
/// and the enqueue/dequeue counters, then the queued bytes themselves.
/// The counters are the draining proof: a process whose ring is drained
/// has `recv` tracking `sent` and `pending` back at 0. Deterministic and
/// grep-able (the live IPC gate greps `mbox: id=` and `pending=` rows).
fn cmd_mbox(m: *Monitor, args: []const []const u8) ExecError {
    const wanted: ?usize = if (args.len > 0) blk: {
        const value = parseInt(args[0]) catch {
            m.console.puts("mbox: invalid pid: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (value >= process.max_processes or process.info(@as(usize, @intCast(value))) == null) {
            m.console.puts("mbox: no such process: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        }
        break :blk @as(usize, @intCast(value));
    } else null;
    var id: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        const info = process.info(id) orelse continue;
        if (wanted) |w| if (w != id) continue;
        const mbox_info = mailbox.info(id);
        m.console.puts("mbox: id=");
        m.console.print_u64(@intCast(id));
        m.console.puts(" name=");
        m.console.puts(info.name);
        m.console.puts(" pending=");
        m.console.print_u64(@intCast(mbox_info.pending));
        m.console.puts(" sent=");
        m.console.print_u64(mbox_info.sent);
        m.console.puts(" recv=");
        m.console.print_u64(mbox_info.recv);
        m.console.puts("\n");
        // Raw dump of the queued bytes (messages are text here; the ring
        // bound caps the total at 8 × 64 B per process).
        var index: usize = 0;
        while (mailbox.message(id, index)) |bytes| : (index += 1) {
            m.console.puts("mbox:   ");
            m.console.print_u64(@intCast(index));
            m.console.puts(": ");
            m.console.puts(bytes);
            m.console.puts("\n");
        }
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Net commands (milestone five card N1 — claim 1373)
// ---------------------------------------------------------------------------

/// `net` — report the virtio-net transport: the OBSERVED device DID +
/// class + bus slot, the MAC (with its source: the VIRTIO_NET_F_MAC
/// feature read or the fixed BSS fallback), the negotiated feature bits
/// (low/high), the two queues (q0 RX / q1 TX) with their sizes, the
/// device status + post-exit re-arm state, the TX counters, and (card
/// N2, claim 6076) the RX counters (frames received into the FIFO,
/// filtered/dropped, FIFO overflow + occupancy) + the rx-obs record
/// (last device-written length + first 16 bytes — the claim-time header
/// question). Grep-able and deterministic (the mbox/procs observability
/// shape). Honest when the device is absent: the default runner attaches
/// no network device. `net recv` is the card-N2 subcommand: drain the RX
/// used ring and print the received frame(s) byte-exact.
fn cmd_net(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "recv")) return cmd_net_recv(m, args[1..]);
        if (std.mem.eql(u8, args[0], "ip")) return cmd_net_ip(m, args[1..]);
        if (std.mem.eql(u8, args[0], "arp")) return cmd_net_arp(m, args[1..]);
        if (std.mem.eql(u8, args[0], "ping")) return cmd_net_ping(m, args[1..]);
        if (std.mem.eql(u8, args[0], "udp")) return cmd_net_udp(m, args[1..]);
        if (std.mem.eql(u8, args[0], "dhcp")) return cmd_net_dhcp(m, args[1..]);
        if (std.mem.eql(u8, args[0], "tcp")) return cmd_net_tcp(m, args[1..]);
        m.console.print_line("net: unknown subcommand (try 'net', 'net recv', 'net ip <a.b.c.d>', 'net arp [<a.b.c.d>]', 'net ping <a.b.c.d>', 'net udp [listen|close|send|recv]', 'net dhcp' or 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]')");
        return .invalid_argument;
    }
    if (!virtio_net.net_ready) {
        m.console.puts("net: no virtio-net device (");
        m.console.puts(if (virtio_net.net_fail.len > 0) virtio_net.net_fail else "DID 0x1041 not found on bus 0");
        m.console.puts(")\n");
        // The offered features as observed (the honest claim-time record
        // when negotiation fails).
        m.console.puts("net: device-features=");
        m.console.print_hex(virtio_net.net_dev_feats_lo);
        m.console.puts("/");
        m.console.print_hex(virtio_net.net_dev_feats_hi);
        m.console.puts("\n");
        // The honest claim-time record when negotiation fails: the status
        // the device returned after the FEATURES_OK write (0x03 = it
        // rejected the accepted features; 0x00 = the status writes never
        // landed), what we actually accepted, and where the regions
        // resolved (so a BAR/capability walk mistake is visible).
        m.console.puts("net: status=");
        m.console.print_hex(virtio_net.net_status_last);
        m.console.puts(" accepted=");
        m.console.print_hex(virtio_net.net_dev.feats_lo);
        m.console.puts("/");
        m.console.print_hex(virtio_net.net_dev.feats_hi);
        m.console.puts("\n");
        m.console.puts("net: common=");
        m.console.print_hex(virtio_net.net_common);
        m.console.puts(" notify=");
        m.console.print_hex(virtio_net.net_notify);
        m.console.puts(" devcfg=");
        m.console.print_hex(virtio_net.net_devcfg);
        m.console.puts(" bar0=");
        m.console.print_hex(virtio_net.net_bar0);
        m.console.puts("\n");
        return .none;
    }
    // print_hex already emits "0x" + full 16 hex digits (the mbox/procs
    // observability shape) — no manual prefix.
    m.console.puts("net: did=");
    m.console.print_hex(virtio_net.net_did);
    m.console.puts(" class=");
    m.console.print_hex(virtio_net.net_class);
    m.console.puts(" dev=");
    m.console.print_u64(@intCast(virtio_net.net_dev_no));
    m.console.puts("\n");
    m.console.puts("net: mac=");
    m.console.puts(&virtio_net.net_mac_text);
    m.console.puts(" source=");
    m.console.puts(switch (virtio_net.net_mac_source) {
        .feature => "feature",
        .fallback => "fallback",
    });
    m.console.puts("\n");
    // The raw device-config MAC bytes captured pre-exit (the claim-1373
    // record: whether the host-set address is exposed at config offset 0
    // even without the MAC feature).
    if (virtio_net.net_devcfg_mac_seen) {
        m.console.puts("net: cfgmac=");
        var ci: usize = 0;
        while (ci < 6) : (ci += 1) {
            if (ci > 0) m.console.puts(":");
            const b = virtio_net.net_devcfg_mac_obs[ci];
            const hex = "0123456789abcdef";
            var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
            m.console.puts(&two);
        }
        m.console.puts("\n");
    }
    m.console.puts("net: feat=");
    m.console.print_hex(virtio_net.net_dev.feats_lo);
    m.console.puts("/");
    m.console.print_hex(virtio_net.net_dev.feats_hi);
    m.console.puts(" q0=rx:size=");
    m.console.print_u64(@intCast(virtio_net.queue_size));
    m.console.puts(" q1=tx:size=");
    m.console.print_u64(@intCast(virtio_net.queue_size));
    m.console.puts("\n");
    m.console.puts("net: status=");
    m.console.print_hex(virtio_net.net_status_last);
    m.console.puts(" rearm=");
    m.console.print_u64(if (virtio_net.net_rearmed) 1 else 0);
    m.console.puts(" tx=frames=");
    m.console.print_u64(virtio_net.net_dev.tx_frames);
    m.console.puts(",bytes=");
    m.console.print_u64(virtio_net.net_dev.tx_bytes);
    m.console.puts("\n");
    // Card N2 (claim 6076): RX counters + the rx-obs record. The drain is
    // idempotent (also run from the shell idle loop) so the report is
    // current when the frame has already landed.
    virtio_net.net_rx_drain();
    m.console.puts("net: rx=frames=");
    m.console.print_u64(virtio_net.rx_frames);
    m.console.puts(",bytes=");
    m.console.print_u64(virtio_net.rx_bytes);
    m.console.puts(",filtered=");
    m.console.print_u64(virtio_net.rx_filtered);
    m.console.puts(",overflow=");
    m.console.print_u64(virtio_net.rx_overflow);
    m.console.puts(",fifo=");
    m.console.print_u64(@intCast(virtio_net.fifo_occupancy()));
    m.console.puts("\n");
    // The raw ring state (the claim-time record): the guest's avail.idx
    // vs the device's used.idx tell whether a delivery ever completed.
    m.console.puts("net: rx-rings avail=");
    m.console.print_u64(@intCast(virtio_net.net_dev.rx_avail.idx));
    m.console.puts(" used=");
    m.console.print_u64(@intCast(virtio_net.net_dev.rx_used.idx));
    m.console.puts(" armed=");
    m.console.print_u64(if (virtio_net.rx_armed) 1 else 0);
    m.console.puts("\n");
    // The claim-time observation record: the last device-written length +
    // the first 16 bytes pin the RX-header question (12 zero bytes + dst
    // MAC = header present; dst MAC at 0 = none). Recorded even when the
    // filter dropped the frame, so a drop is distinguishable from a
    // failed delivery.
    m.console.puts("net: rx-obs len=");
    m.console.print_u64(virtio_net.rx_last_len);
    m.console.puts(" first16=");
    var oi: usize = 0;
    while (oi < 16) : (oi += 1) {
        if (oi > 0) m.console.puts(" ");
        const b = virtio_net.rx_first16[oi];
        const hex = "0123456789abcdef";
        var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
        m.console.puts(&two);
    }
    m.console.puts("\n");
    // Card N3 (claim 7293): the ARP layer — our static IP (0.0.0.0 when
    // unset — DHCP is a later card, honest bound) + the counters
    // (requests sent, replies answered, replies learned, dropped,
    // reply TX failures). Grep-able and deterministic.
    m.console.puts("net: ip=");
    var ipbuf: [15]u8 = undefined;
    const ipn = virtio_net.arp.format_ip(virtio_net.arp.own_ip, &ipbuf);
    m.console.puts(ipbuf[0..ipn]);
    m.console.puts(" arp=req=");
    m.console.print_u64(virtio_net.arp.requests_sent);
    m.console.puts(",repl=");
    m.console.print_u64(virtio_net.arp.replies_sent);
    m.console.puts(",learn=");
    m.console.print_u64(virtio_net.arp.replies_learned);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.arp.dropped);
    m.console.puts(",fail=");
    m.console.print_u64(virtio_net.arp.reply_tx_fail);
    m.console.puts("\n");
    // Card N4 (claim 0148): the IPv4/ICMP layer — echo requests sent
    // (`net ping`), echo replies answered, pongs observed (an echo
    // reply's id/seq echoed back — the ping proof), drops by cause, and
    // the last observed sequence. Grep-able and deterministic.
    m.console.puts(" icmp=req=");
    m.console.print_u64(virtio_net.ipv4.requests_sent);
    m.console.puts(",repl=");
    m.console.print_u64(virtio_net.ipv4.replies_sent);
    m.console.puts(",pong=");
    m.console.print_u64(virtio_net.ipv4.pongs_observed);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.ipv4.dropped_short + virtio_net.ipv4.dropped_frag + virtio_net.ipv4.dropped_checksum + virtio_net.ipv4.dropped_proto + virtio_net.ipv4.dropped_other);
    m.console.puts(",fail=");
    m.console.print_u64(virtio_net.ipv4.reply_tx_fail);
    m.console.puts(",seq=");
    m.console.print_u64(virtio_net.ipv4.last_seq);
    m.console.puts("\n");
    // Card N5 (claim 8552): the UDP layer — datagrams received (into a
    // listener's buffer, incl. loopback), sent (device TX + loopback),
    // loopbacked (the no-device path), and dropped (the sum of the three
    // counted causes). Grep-able and deterministic.
    m.console.puts(" udp=rx=");
    m.console.print_u64(virtio_net.udp.received);
    m.console.puts(",tx=");
    m.console.print_u64(virtio_net.udp.sent);
    m.console.puts(",loop=");
    m.console.print_u64(virtio_net.udp.loopbacked);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.udp.dropped_badsum + virtio_net.udp.dropped_closed + virtio_net.udp.dropped_len);
    m.console.puts("\n");
    // Card N8 (claim 0351) + card N9 (claim 9489): the DHCP client — the
    // state (bound/unbound/renewing/rebinding), the lease
    // (ip/mask/gw/server/lease — zeros when unbound), the handshake
    // counters (discover sent, offer recv, request sent, ack recv, nack,
    // timeout, malformed), and the lease-lifecycle counters (renewing
    // REQUESTs sent, rebinding REQUESTs sent, renewals ACKed, expiries
    // enforced). Grep-able and deterministic. The lifecycle counters
    // APPEND at the end — the N8 gate's substring assertions stay green.
    m.console.puts(" dhcp=");
    m.console.puts(switch (virtio_net.dhcp.state) {
        .idle => "idle",
        .selecting => "selecting",
        .requesting => "requesting",
        .bound => "bound",
        .renewing => "renewing",
        .rebinding => "rebinding",
    });
    m.console.puts(",ip=");
    var dibuf: [15]u8 = undefined;
    const din = virtio_net.arp.format_ip(virtio_net.dhcp.lease_ip, &dibuf);
    m.console.puts(dibuf[0..din]);
    m.console.puts(",mask=");
    const dmn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_mask, &dibuf);
    m.console.puts(dibuf[0..dmn]);
    m.console.puts(",gw=");
    const dgn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_gw, &dibuf);
    m.console.puts(dibuf[0..dgn]);
    m.console.puts(",server=");
    const dsn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_server, &dibuf);
    m.console.puts(dibuf[0..dsn]);
    m.console.puts(",lease=");
    m.console.print_u64(virtio_net.dhcp.lease_time);
    m.console.puts(",discover=");
    m.console.print_u64(virtio_net.dhcp.discover_sent);
    m.console.puts(",offer=");
    m.console.print_u64(virtio_net.dhcp.offer_recv);
    m.console.puts(",request=");
    m.console.print_u64(virtio_net.dhcp.request_sent);
    m.console.puts(",ack=");
    m.console.print_u64(virtio_net.dhcp.ack_recv);
    m.console.puts(",nack=");
    m.console.print_u64(virtio_net.dhcp.nack_recv);
    m.console.puts(",timeout=");
    m.console.print_u64(virtio_net.dhcp.timed_out);
    m.console.puts(",mal=");
    m.console.print_u64(virtio_net.dhcp.dropped_malformed);
    // Card N9 (claim 9489): the lease lifecycle counters (append-only).
    m.console.puts(",renew=");
    m.console.print_u64(virtio_net.dhcp.renew_sent);
    m.console.puts(",rebind=");
    m.console.print_u64(virtio_net.dhcp.rebind_sent);
    m.console.puts(",renewed=");
    m.console.print_u64(virtio_net.dhcp.renewed);
    m.console.puts(",expired=");
    m.console.print_u64(virtio_net.dhcp.expired);
    m.console.puts("\n");
    // Card N10 (claim 7026): the bounded TCP client — the state
    // (idle/syn_sent/established/fin_sent/closed), the peer (zeros when
    // unbound), and the counters (SYNs sent, SYN-ACKs recv, ACKs sent,
    // data sent/recv, FINs sent, FIN-ACKs recv, RSTs sent/recv, the
    // connect-timeout refusals, and the drop sum — badsum + malformed).
    // Grep-able and deterministic.
    m.console.puts(" tcp=");
    m.console.puts(switch (virtio_net.tcp.state) {
        .idle => "idle",
        .syn_sent => "syn_sent",
        .established => "established",
        .fin_sent => "fin_sent",
        .closed => "closed",
    });
    m.console.puts(",peer=");
    var tibuf: [15]u8 = undefined;
    const tin = virtio_net.arp.format_ip(virtio_net.tcp.peer_ip, &tibuf);
    m.console.puts(tibuf[0..tin]);
    m.console.puts(":");
    m.console.print_u64(virtio_net.tcp.peer_port);
    m.console.puts(",syn=");
    m.console.print_u64(virtio_net.tcp.syn_sent);
    m.console.puts(",synack=");
    m.console.print_u64(virtio_net.tcp.synack_recv);
    m.console.puts(",ack=");
    m.console.print_u64(virtio_net.tcp.ack_sent);
    m.console.puts(",data_s=");
    m.console.print_u64(virtio_net.tcp.data_sent);
    m.console.puts(",data_r=");
    m.console.print_u64(virtio_net.tcp.data_recv);
    m.console.puts(",fin=");
    m.console.print_u64(virtio_net.tcp.fin_sent);
    m.console.puts(",finack=");
    m.console.print_u64(virtio_net.tcp.finack_recv);
    m.console.puts(",rst_s=");
    m.console.print_u64(virtio_net.tcp.rst_sent);
    m.console.puts(",rst_r=");
    m.console.print_u64(virtio_net.tcp.rst_recv);
    m.console.puts(",timedout=");
    m.console.print_u64(virtio_net.tcp.timed_out);
    m.console.puts(",mal=");
    m.console.print_u64(virtio_net.tcp.dropped_badsum + virtio_net.tcp.dropped_malformed);
    // Card N11 (claim 5357): the retransmission counters APPENDED at the
    // end (the N9 append-never-change convention — the N10 gate's
    // substring assertions stay green). retx = segment retransmissions,
    // abort = the retransmission-bound aborts.
    m.console.puts(",retx=");
    m.console.print_u64(virtio_net.tcp.retransmitted);
    m.console.puts(",abort=");
    m.console.print_u64(virtio_net.tcp.retx_aborted);
    m.console.puts("\n");
    return .none;
}

/// `net dhcp` — card N8 (claim 0351) + card N9 (claim 9489): drive the
/// bounded RFC 2131 client ONE STEP per invocation. INIT (idle): build
/// + transmit the DISCOVER (a CSPRNG transaction id), print it;
/// SELECTING: wait for the OFFER (already processed by a drain if it
/// landed); REQUESTING: transmit the built REQUEST exactly once, then
/// wait for the ACK; BOUND (N9): check the lease timer each invocation
/// — expiry -> release the address (INIT), T2 -> REBINDING (broadcast
/// REQUEST), T1 -> RENEWING (unicast REQUEST to the server), else print
/// the lease (the ACK's drain processing already set `arp.own_ip` — THE
/// one copy). The RX drain processes OFFER/ACK/NAK replies on port 68 (the
/// udp dispatch), so the handshake advances between invocations; each
/// command drains first (the claim-6076 polled-drain contract). Bounded
/// retry: `max_attempts` DISCOVERs without an OFFER -> an honest refuse
/// (the `timeout` counter). Deterministic, monitor-driven, no interrupts.
fn cmd_net_dhcp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        m.console.print_line("net dhcp: usage: net dhcp");
        return .invalid_argument;
    }
    if (!virtio_net.net_ready) {
        m.console.puts("net dhcp: no virtio-net device (");
        m.console.puts(if (virtio_net.net_fail.len > 0) virtio_net.net_fail else "DID 0x1041 not found on bus 0");
        m.console.puts(")\n");
        return .none;
    }
    // Card N9 (claim 9489): stamp the lease clock BEFORE the drain — a
    // pending renewal ACK processed below restarts the lease from THIS
    // instant (the shell idle loop keeps it current between commands).
    virtio_net.dhcp.now_ticks = timer.ticks;
    // Deliver any pending OFFER/ACK before deciding (polled-drain
    // contract — the frame may have landed while the shell idled).
    virtio_net.net_rx_drain();
    switch (virtio_net.dhcp.state) {
        .idle => {
            if (virtio_net.dhcp.attempts >= virtio_net.dhcp.max_attempts) {
                virtio_net.dhcp.timed_out += 1;
                m.console.puts("net dhcp: refused (no OFFER after ");
                m.console.print_u64(@intCast(virtio_net.dhcp.max_attempts));
                m.console.puts(" DISCOVER attempts)\n");
                return .none;
            }
            // A fresh transaction id from the seeded CSPRNG (claim 2665).
            const xid: u32 = @truncate(csprng.random_u64());
            virtio_net.dhcp.start(&virtio_net.net_mac, xid);
            var out_len: usize = 0;
            switch (virtio_net.net_dhcp_send(virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len)) {
                .ok => {
                    virtio_net.dhcp.discover_sent += 1;
                    virtio_net.dhcp.attempts += 1;
                    m.console.puts("net dhcp: discover sent xid=");
                    m.console.print_hex_min(xid);
                    m.console.puts(" (");
                    m.console.print_u64(@intCast(out_len));
                    m.console.puts(" bytes)\n");
                },
                else => {
                    virtio_net.dhcp.state = .idle; // the DISCOVER never went out
                    m.console.print_line("net dhcp: DISCOVER TX failed (transport unready)");
                },
            }
            return .none;
        },
        .selecting => {
            m.console.puts("net dhcp: waiting for OFFER (xid=");
            m.console.print_hex_min(virtio_net.dhcp.xid);
            m.console.puts(")\n");
            return .none;
        },
        .requesting => {
            if (!virtio_net.dhcp.request_transmitted) {
                // The OFFER was accepted (the drain built the REQUEST into
                // dhcp.msg) — transmit it exactly once.
                var out_len: usize = 0;
                switch (virtio_net.net_dhcp_send(virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.dhcp.request_transmitted = true;
                        virtio_net.dhcp.request_sent += 1;
                        m.console.puts("net dhcp: request sent xid=");
                        m.console.print_hex_min(virtio_net.dhcp.xid);
                        m.console.puts(" (");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => m.console.print_line("net dhcp: REQUEST TX failed (transport unready)"),
                }
            } else {
                m.console.puts("net dhcp: waiting for ACK (xid=");
                m.console.print_hex_min(virtio_net.dhcp.xid);
                m.console.puts(")\n");
            }
            return .none;
        },
        .renewing, .rebinding => {
            // Card N9 (claim 9489): the renewal REQUEST went out (or the
            // initial transmit failed — retry once). A pending renewal
            // never outlives its lease: if the ACK has not landed and the
            // lease expired meanwhile, release the address honestly.
            const lease = virtio_net.dhcp.lease_time;
            if (lease > 0 and virtio_net.dhcp.elapsed() >= lease) {
                virtio_net.dhcp.expire();
                m.console.puts("net dhcp: lease expired while waiting for the renewal ACK (elapsed=");
                m.console.print_u64(virtio_net.dhcp.elapsed());
                m.console.puts(" >= lease=");
                m.console.print_u64(lease);
                m.console.puts(") — address released\n");
                return .none;
            }
            if (!virtio_net.dhcp.request_transmitted) {
                var out_len: usize = 0;
                const r = if (virtio_net.dhcp.state == .renewing) blk: {
                    const srv_mac = virtio_net.arp.lookup(virtio_net.dhcp.lease_server) orelse {
                        m.console.print_line("net dhcp: renewing needs the server MAC (net arp <server> first)");
                        break :blk .no_peer;
                    };
                    break :blk virtio_net.net_dhcp_send_unicast(virtio_net.dhcp.lease_server, srv_mac, virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len);
                } else virtio_net.net_dhcp_send_bound(virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len);
                if (r == .ok) {
                    virtio_net.dhcp.request_transmitted = true;
                    if (virtio_net.dhcp.state == .renewing) virtio_net.dhcp.renew_sent += 1 else virtio_net.dhcp.rebind_sent += 1;
                    m.console.puts("net dhcp: ");
                    m.console.puts(if (virtio_net.dhcp.state == .renewing) "renewing" else "rebinding");
                    m.console.puts(" request sent (");
                    m.console.print_u64(@intCast(out_len));
                    m.console.puts(" bytes)\n");
                } else {
                    m.console.puts("net dhcp: ");
                    m.console.puts(if (virtio_net.dhcp.state == .renewing) "RENEWING" else "REBINDING");
                    m.console.print_line(" TX failed (transport unready)");
                }
            } else {
                m.console.puts("net dhcp: waiting for the renewal ACK (xid=");
                m.console.print_hex_min(virtio_net.dhcp.xid);
                m.console.puts(")\n");
            }
            return .none;
        },
        .bound => {
            // Card N9 (claim 9489): the lease lifecycle (RFC 2131
            // §4.4.5). Each invocation checks the elapsed lease time and
            // advances ONE step: expiry -> release the address (INIT);
            // T2 -> REBINDING (broadcast REQUEST); T1 -> RENEWING
            // (unicast REQUEST to the server — its MAC must be resolved;
            // the seam resolves nothing). The transition + transmit
            // happen in the SAME invocation (the polled-drain contract).
            const lease = virtio_net.dhcp.lease_time;
            const el = virtio_net.dhcp.elapsed();
            if (lease > 0 and el >= lease) {
                virtio_net.dhcp.expire();
                m.console.puts("net dhcp: lease expired (elapsed=");
                m.console.print_u64(el);
                m.console.puts(" >= lease=");
                m.console.print_u64(lease);
                m.console.puts(") — address released, re-DISCOVER with `net dhcp`\n");
                return .none;
            }
            if (lease > 0 and el >= virtio_net.dhcp.t2(lease)) {
                // REBINDING: the broadcast REQUEST (any server on the
                // link can answer — the lease is almost over).
                virtio_net.dhcp.enter_rebinding();
                var out_len: usize = 0;
                switch (virtio_net.net_dhcp_send_bound(virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.dhcp.request_transmitted = true;
                        virtio_net.dhcp.rebind_sent += 1;
                        m.console.puts("net dhcp: rebinding (T2, elapsed=");
                        m.console.print_u64(el);
                        m.console.puts(") request sent (");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => m.console.print_line("net dhcp: REBINDING TX failed (transport unready)"),
                }
                return .none;
            }
            if (lease > 0 and el >= virtio_net.dhcp.t1(lease)) {
                // RENEWING: the unicast REQUEST to the server (RFC 2131
                // §4.4.5). The server MAC must be in the ARP table — the
                // guest resolves it with `net arp <server>` (the host's
                // --net-arp-respond answers); without it the client
                // honestly stays BOUND until T2 (RFC-compliant
                // degradation, never faked).
                const srv_mac = virtio_net.arp.lookup(virtio_net.dhcp.lease_server) orelse {
                    m.console.puts("net dhcp: renewing needs the server MAC (net arp ");
                    var srvbuf: [15]u8 = undefined;
                    const sn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_server, &srvbuf);
                    m.console.puts(srvbuf[0..sn]);
                    m.console.puts(" first) — the client stays BOUND until T2\n");
                    return .none;
                };
                virtio_net.dhcp.enter_renewing();
                var out_len: usize = 0;
                switch (virtio_net.net_dhcp_send_unicast(virtio_net.dhcp.lease_server, srv_mac, virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.dhcp.request_transmitted = true;
                        virtio_net.dhcp.renew_sent += 1;
                        m.console.puts("net dhcp: renewing (T1, elapsed=");
                        m.console.print_u64(el);
                        m.console.puts(") request sent to the server (");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => m.console.print_line("net dhcp: RENEWING TX failed (transport unready)"),
                }
                return .none;
            }
            // The lease is still young — the existing bound print
            // (unchanged; the N8 gate asserts it byte-exact).
            m.console.puts("net: dhcp bound ip=");
            var ibuf: [15]u8 = undefined;
            const in = virtio_net.arp.format_ip(virtio_net.dhcp.lease_ip, &ibuf);
            m.console.puts(ibuf[0..in]);
            m.console.puts(" mask=");
            const mn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_mask, &ibuf);
            m.console.puts(ibuf[0..mn]);
            m.console.puts(" gw=");
            const gn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_gw, &ibuf);
            m.console.puts(ibuf[0..gn]);
            m.console.puts(" server=");
            const sn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_server, &ibuf);
            m.console.puts(ibuf[0..sn]);
            m.console.puts(" lease=");
            m.console.print_u64(virtio_net.dhcp.lease_time);
            m.console.puts("\n");
            return .none;
        },
    }
}

/// `net tcp` — card N10 (claim 7026): drive the bounded RFC 793 CLIENT
/// ONE STEP per invocation. `connect <addr> <port>` starts the
/// three-way handshake (build + transmit the SYN — the peer's MAC must
/// be in the ARP table: `net arp <addr>` resolves it first; an own-IP
/// connect is REFUSED — the bounded client is outward-only, no TCP
/// loopback); the bare `net tcp` drives: SYN_SENT — the bounded connect
/// timeout (30 s of guest ticks, the card-N9 timer pattern) refuses
/// honestly (`timed_out`), ESTABLISHED — transmit the pending ACK the
/// drain built (the polled-drain contract) then print the established
/// state, FIN_SENT — wait for the FIN-ACK, CLOSED — transmit the final
/// ACK after the FIN-ACK (or return to IDLE after a reset); `send <len>`
/// transmits a data segment (the deterministic payload 01 02 03…, ack =
/// rcv_nxt); `recv` prints the bounded RX buffer (ONE segment); `close`
/// transmits the FIN (ESTABLISHED -> FIN_SENT); `reset` transmits a RST
/// (the client's abort). The RX drain processes the peer's segments on
/// our port 8000 (the ipv4 protocol-6 dispatch -> tcp), so the
/// connection advances between invocations; each command drains first
/// (the claim-6076 polled-drain contract). Deterministic,
/// monitor-driven, no interrupts.
fn cmd_net_tcp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_net_tcp_drive(m);
    if (std.mem.eql(u8, args[0], "connect")) return cmd_net_tcp_connect(m, args[1..]);
    if (std.mem.eql(u8, args[0], "send")) return cmd_net_tcp_send(m, args[1..]);
    if (std.mem.eql(u8, args[0], "recv")) return cmd_net_tcp_recv(m, args[1..]);
    if (std.mem.eql(u8, args[0], "close")) return cmd_net_tcp_close(m, args[1..]);
    if (std.mem.eql(u8, args[0], "reset")) return cmd_net_tcp_reset(m, args[1..]);
    m.console.print_line("net tcp: unknown subcommand (try 'net tcp', 'net tcp connect <addr> <port>', 'net tcp send <len>', 'net tcp recv', 'net tcp close' or 'net tcp reset')");
    return .invalid_argument;
}

/// Print the TCP connection's peer as `a.b.c.d:port`.
fn print_tcp_peer(m: *Monitor) void {
    var tibuf: [15]u8 = undefined;
    const tin = virtio_net.arp.format_ip(virtio_net.tcp.peer_ip, &tibuf);
    m.console.puts(tibuf[0..tin]);
    m.console.puts(":");
    m.console.print_u64(virtio_net.tcp.peer_port);
}

/// The bare `net tcp` drive (one step per invocation — see cmd_net_tcp).
fn cmd_net_tcp_drive(m: *Monitor) ExecError {
    if (!virtio_net.net_ready) {
        m.console.print_line("net tcp: no virtio-net device");
        return .none;
    }
    // Card N10: stamp the connect clock BEFORE the drain — a pending
    // SYN-ACK processed below starts the connection from THIS instant
    // (the shell idle loop keeps it current between commands).
    virtio_net.tcp.now_ticks = timer.ticks;
    // Deliver any pending segment before deciding (polled-drain
    // contract — the frame may have landed while the shell idled).
    virtio_net.net_rx_drain();
    switch (virtio_net.tcp.state) {
        .idle => {
            m.console.print_line("net tcp: no connection (net tcp connect <addr> <port>)");
            return .none;
        },
        .syn_sent => {
            if (virtio_net.tcp.connect_timed_out()) {
                virtio_net.tcp.abort_timeout();
                m.console.puts("net tcp: connect refused (no SYN-ACK after ");
                m.console.print_u64(@intCast(virtio_net.tcp.connect_timeout));
                m.console.puts("s) — run 'net tcp connect <addr> <port>' to retry\n");
                return .none;
            }
            m.console.puts("net tcp: waiting for SYN-ACK (peer=");
            print_tcp_peer(m);
            m.console.puts(")\n");
            return .none;
        },
        .established => {
            if (virtio_net.tcp.ack_pending) {
                // The drain built an ACK (the handshake, a data echo, or
                // a server FIN) — transmit it exactly once.
                var out_len: usize = 0;
                switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.tcp.ack_pending = false;
                        virtio_net.tcp.ack_sent += 1;
                        m.console.puts("net tcp: ack sent (ack=");
                        m.console.print_hex_min(virtio_net.tcp.rcv_nxt);
                        m.console.puts(", ");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => m.console.print_line("net tcp: ACK TX failed (transport unready)"),
                }
            }
            m.console.puts("net tcp: established (peer=");
            print_tcp_peer(m);
            m.console.puts(")\n");
            return .none;
        },
        .fin_sent => {
            // The FIN-ACK, when it lands, is processed by the drain into
            // CLOSED with the final ACK built — the CLOSED branch sends
            // it. While still FIN_SENT, just wait.
            m.console.puts("net tcp: waiting for the FIN-ACK (peer=");
            print_tcp_peer(m);
            m.console.puts(")\n");
            return .none;
        },
        .closed => {
            if (virtio_net.tcp.ack_pending) {
                // The drain processed the FIN-ACK — transmit the final
                // ACK (the close completes).
                var out_len: usize = 0;
                switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.tcp.ack_pending = false;
                        virtio_net.tcp.ack_sent += 1;
                        m.console.puts("net tcp: final ack sent (ack=");
                        m.console.print_hex_min(virtio_net.tcp.rcv_nxt);
                        m.console.puts(", ");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => m.console.print_line("net tcp: final ACK TX failed (transport unready)"),
                }
                virtio_net.tcp.state = .idle; // the close completed — a fresh connect is possible
                m.console.print_line("net tcp: connection closed");
                return .none;
            }
            // A clean close or a reset already handled — back to IDLE.
            m.console.print_line("net tcp: connection closed — idle again");
            virtio_net.tcp.state = .idle;
            return .none;
        },
    }
}

/// `net tcp connect <addr> <port>` — start the three-way handshake.
fn cmd_net_tcp_connect(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 2) {
        m.console.print_line("net tcp: usage: net tcp connect <a.b.c.d> <port>");
        return .invalid_argument;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        m.console.puts("net tcp: invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    const port = parse_port(args[1]) orelse {
        m.console.puts("net tcp: invalid port: ");
        m.console.puts(args[1]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        m.console.print_line("net tcp: no virtio-net device");
        return .none;
    }
    if (virtio_net.tcp.state != .idle) {
        m.console.print_line("net tcp: a connection is already in progress (net tcp reset to abort)");
        return .none;
    }
    if (!virtio_net.arp.ip_set()) {
        m.console.print_line("net tcp: no IP set (net ip <a.b.c.d> first)");
        return .none;
    }
    if (std.mem.eql(u8, &ip, &virtio_net.arp.own_ip)) {
        m.console.print_line("net tcp: own-IP connect refused (no TCP loopback — the bounded client is outward-only)");
        return .none;
    }
    // Drain first (the claim-6076 contract — the ARP reply for `net arp
    // <ip>` may have landed while the shell idled; the peer's MAC must
    // be in the table: the seam resolves nothing).
    virtio_net.net_rx_drain();
    const peer_mac = virtio_net.arp.lookup(ip) orelse {
        m.console.puts("net tcp: peer not in ARP table (net arp ");
        var ipbuf: [15]u8 = undefined;
        const in = virtio_net.arp.format_ip(ip, &ipbuf);
        m.console.puts(ipbuf[0..in]);
        m.console.puts(" first)\n");
        return .none;
    };
    // A fresh ISN from the seeded CSPRNG (claim 2665) — real TCP
    // randomizes ISNs; the fixtures assert the seq/ack chain, not values.
    const isn: u32 = @truncate(csprng.random_u64());
    virtio_net.tcp.start(ip, port, isn, peer_mac);
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
        .ok => {
            virtio_net.tcp.syn_sent += 1;
            virtio_net.tcp.advance_snd(1); // the SYN consumes one sequence number
            virtio_net.tcp.record_pending(); // card N11: the unacked SYN is retransmittable
            m.console.puts("net tcp: syn sent (peer=");
            print_tcp_peer(m);
            m.console.puts(", seq=");
            m.console.print_hex_min(isn);
            m.console.puts(", ");
            m.console.print_u64(@intCast(out_len));
            m.console.puts(" bytes)\n");
        },
        else => {
            virtio_net.tcp.state = .idle; // the SYN never went out
            m.console.print_line("net tcp: SYN TX failed (transport unready)");
        },
    }
    return .none;
}

/// `net tcp send <len>` — transmit a data segment (1..payload_max bytes
/// of the deterministic pattern 01 02 03…, ack = rcv_nxt).
fn cmd_net_tcp_send(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        m.console.print_line("net tcp: usage: net tcp send <len>");
        return .invalid_argument;
    }
    const len = parseInt(args[0]) catch {
        m.console.puts("net tcp: invalid length: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (len < 1 or len > virtio_net.tcp.payload_max) {
        m.console.puts("net tcp: length must be between 1 and ");
        m.console.print_u64(virtio_net.tcp.payload_max);
        m.console.puts("\n");
        return .invalid_argument;
    }
    if (virtio_net.tcp.state != .established) {
        m.console.print_line("net tcp: not established (net tcp connect <addr> <port> first)");
        return .none;
    }
    // The deterministic payload — bytes 01 02 03 04… (byte i + 1,
    // bounded ≤ 64) — the live gate's byte-exact fixtures pin it.
    var payload: [virtio_net.tcp.payload_max]u8 = undefined;
    var pi: usize = 0;
    while (pi < len) : (pi += 1) payload[pi] = @as(u8, @truncate(pi)) +% 1;
    const seq = virtio_net.tcp.snd_una;
    virtio_net.tcp.build_data_msg(payload[0..@intCast(len)]);
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
        .ok => {
            virtio_net.tcp.data_sent += 1;
            virtio_net.tcp.advance_snd(@intCast(len));
            virtio_net.tcp.record_pending(); // card N11: the unacked data is retransmittable
            m.console.puts("net tcp: data sent (seq=");
            m.console.print_hex_min(seq);
            m.console.puts(", ");
            m.console.print_u64(@intCast(len));
            m.console.puts(" bytes)\n");
        },
        else => m.console.print_line("net tcp: DATA TX failed (transport unready)"),
    }
    return .none;
}

/// `net tcp recv` — print the bounded RX buffer (ONE segment — the
/// honest bound, no reassembly) byte-exact (hex, the net udp recv
/// style) and consume it.
fn cmd_net_tcp_recv(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        m.console.print_line("net tcp: usage: net tcp recv");
        return .invalid_argument;
    }
    if (virtio_net.tcp.state != .established) {
        m.console.print_line("net tcp: not established (net tcp connect <addr> <port> first)");
        return .none;
    }
    // A segment may have landed while the shell idled — drain first.
    virtio_net.net_rx_drain();
    if (!virtio_net.tcp.rx_pending) {
        m.console.print_line("net tcp recv: no data");
        return .none;
    }
    const p = virtio_net.tcp.take_rx();
    m.console.puts("net tcp recv: ");
    var bi: usize = 0;
    while (bi < p.len) : (bi += 1) {
        if (bi > 0) m.console.puts(" ");
        const b = p[bi];
        const hex = "0123456789abcdef";
        var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
        m.console.puts(&two);
    }
    m.console.puts("\n");
    return .none;
}

/// `net tcp close` — the client-driven close: transmit the FIN
/// (ESTABLISHED -> FIN_SENT; the FIN-ACK is processed by the drain, the
/// final ACK by the next `net tcp`).
fn cmd_net_tcp_close(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        m.console.print_line("net tcp: usage: net tcp close");
        return .invalid_argument;
    }
    if (virtio_net.tcp.state != .established) {
        m.console.print_line("net tcp: not established (net tcp connect <addr> <port> first)");
        return .none;
    }
    const seq = virtio_net.tcp.snd_una;
    virtio_net.tcp.build_fin_msg();
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
        .ok => {
            virtio_net.tcp.fin_sent += 1;
            virtio_net.tcp.advance_snd(1); // the FIN consumes one sequence number
            virtio_net.tcp.record_pending(); // card N11: the unacked FIN is retransmittable
            virtio_net.tcp.state = .fin_sent;
            m.console.puts("net tcp: fin sent (seq=");
            m.console.print_hex_min(seq);
            m.console.puts(", ");
            m.console.print_u64(@intCast(out_len));
            m.console.puts(" bytes)\n");
        },
        else => m.console.print_line("net tcp: FIN TX failed (transport unready)"),
    }
    return .none;
}

/// `net tcp reset` — the client's abort: transmit a RST (the connection
/// dies; the next `net tcp` returns to IDLE).
fn cmd_net_tcp_reset(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        m.console.print_line("net tcp: usage: net tcp reset");
        return .invalid_argument;
    }
    if (virtio_net.tcp.state == .idle) {
        m.console.print_line("net tcp: no connection to reset");
        return .none;
    }
    const seq = virtio_net.tcp.snd_una;
    virtio_net.tcp.build_rst_msg();
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
        .ok => {
            virtio_net.tcp.rst_sent += 1;
            virtio_net.tcp.clear_pending(); // card N11: the connection died — the timer stops
            virtio_net.tcp.state = .closed; // the connection died
            m.console.puts("net tcp: reset sent (seq=");
            m.console.print_hex_min(seq);
            m.console.puts(", ");
            m.console.print_u64(@intCast(out_len));
            m.console.puts(" bytes)\n");
        },
        else => m.console.print_line("net tcp: RST TX failed (transport unready)"),
    }
    return .none;
}

/// `net recv` — the card-N2 receive path: drain the RX used ring (polled
/// — the frame may have landed while the shell idled), then print every
/// frame currently in the bounded FIFO byte-exact (hex, the
/// netsend-style report) and consume it. The frames are the RAW
/// device-written buffer bytes (the 12-byte virtio_net_hdr headroom
/// included — the claim-time header question is pinned by `rx-obs`, not
/// stripped blindly). Honest when empty: a filtered frame shows as `net
/// recv: no frames` + the `net` report's filtered= counter.
fn cmd_net_recv(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    if (!virtio_net.net_ready) {
        m.console.puts("net recv: no virtio-net device (");
        m.console.puts(if (virtio_net.net_fail.len > 0) virtio_net.net_fail else "DID 0x1041 not found on bus 0");
        m.console.puts(")\n");
        return .none;
    }
    virtio_net.net_rx_drain();
    const count = virtio_net.fifo_occupancy();
    m.console.puts("net recv: frames=");
    m.console.print_u64(@intCast(count));
    m.console.puts("\n");
    if (count == 0) {
        m.console.puts("net recv: no frames (filtered or nothing injected)\n");
        return .none;
    }
    var idx: usize = 0;
    while (virtio_net.fifo_peek()) |frame| {
        m.console.puts("net recv: [");
        m.console.print_u64(@intCast(idx));
        m.console.puts("] len=");
        m.console.print_u64(@intCast(frame.len));
        m.console.puts("\n");
        m.console.puts("net recv: ");
        var bi: usize = 0;
        while (bi < frame.len) : (bi += 1) {
            if (bi > 0) m.console.puts(" ");
            const b = frame[bi];
            const hex = "0123456789abcdef";
            var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
            m.console.puts(&two);
        }
        m.console.puts("\n");
        virtio_net.fifo_pop_advance();
        idx += 1;
    }
    return .none;
}

/// `net ip <a.b.c.d>` — card N3 (claim 7293): set our static IPv4
/// address (fixed BSS, no heap — DHCP is a later card). The echo line
/// `net ip: ip=<a.b.c.d>` is the live gate's injection trigger (the
/// runner's `--net-inject-after` marker — deterministic, not a sleep).
fn cmd_net_ip(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        m.console.print_line("net ip: usage: net ip <a.b.c.d>");
        return .invalid_argument;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        m.console.puts("net ip: invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    virtio_net.arp.own_ip = ip;
    m.console.puts("net ip: ip=");
    var ipbuf: [15]u8 = undefined;
    const n = virtio_net.arp.format_ip(ip, &ipbuf);
    m.console.puts(ipbuf[0..n]);
    m.console.puts("\n");
    return .none;
}

/// `net arp [<a.b.c.d>]` — card N3 (claim 7293). With no argument:
/// drain the RX ring (idempotent — a reply may have landed while the
/// shell idled) and print the bounded table + the counters. With an
/// argument: resolve — a table hit prints the peer, a miss transmits an
/// ARP request (the reply is learned asynchronously by the RX drain) and
/// reports it; refused honestly when no static IP is set or the
/// transport is unready.
fn cmd_net_arp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        if (!virtio_net.net_ready) {
            m.console.print_line("net arp: no virtio-net device");
            return .none;
        }
        virtio_net.net_rx_drain();
        var count: usize = 0;
        for (&virtio_net.arp.table) |*e| {
            if (!e.valid) continue;
            count += 1;
        }
        m.console.puts("net arp: entries=");
        m.console.print_u64(@intCast(count));
        m.console.puts("\n");
        var ipbuf: [15]u8 = undefined;
        var macbuf: [17]u8 = undefined;
        for (&virtio_net.arp.table) |*e| {
            if (!e.valid) continue;
            const in = virtio_net.arp.format_ip(e.ip, &ipbuf);
            m.console.puts("net arp: ");
            m.console.puts(ipbuf[0..in]);
            m.console.puts(" -> ");
            virtio_net.format_mac(&e.mac, &macbuf);
            m.console.puts(&macbuf);
            m.console.puts("\n");
        }
        m.console.puts("net arp: req=");
        m.console.print_u64(virtio_net.arp.requests_sent);
        m.console.puts(",repl=");
        m.console.print_u64(virtio_net.arp.replies_sent);
        m.console.puts(",learn=");
        m.console.print_u64(virtio_net.arp.replies_learned);
        m.console.puts(",drop=");
        m.console.print_u64(virtio_net.arp.dropped);
        m.console.puts(",fail=");
        m.console.print_u64(virtio_net.arp.reply_tx_fail);
        m.console.puts("\n");
        return .none;
    }
    if (args.len != 1) {
        m.console.print_line("net arp: usage: net arp [<a.b.c.d>]");
        return .invalid_argument;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        m.console.puts("net arp: invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        m.console.print_line("net arp: no virtio-net device");
        return .none;
    }
    virtio_net.net_rx_drain();
    if (virtio_net.arp.lookup(ip)) |mac| {
        m.console.puts("net arp: ");
        var ipbuf: [15]u8 = undefined;
        const in = virtio_net.arp.format_ip(ip, &ipbuf);
        m.console.puts(ipbuf[0..in]);
        m.console.puts(" is at ");
        var macbuf: [17]u8 = undefined;
        virtio_net.format_mac(&mac, &macbuf);
        m.console.puts(&macbuf);
        m.console.puts("\n");
        return .none;
    }
    var frame_len: usize = 0;
    switch (virtio_net.net_arp_request(ip, &frame_len)) {
        .ok => {
            virtio_net.arp.requests_sent += 1;
            m.console.puts("net arp: request for ");
            var ipbuf: [15]u8 = undefined;
            const in = virtio_net.arp.format_ip(ip, &ipbuf);
            m.console.puts(ipbuf[0..in]);
            m.console.puts(" sent (");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes)\n");
        },
        .not_ready => m.console.print_line("net arp: no IP set (net ip <a.b.c.d> first) or transport unready"),
        .timeout => m.console.print_line("net arp: request TX timeout (device did not complete within the poll budget)"),
        .no_peer => unreachable,
    }
    return .none;
}

/// `net ping <a.b.c.d>` — card N4 (claim 0148): transmit an ICMP echo
/// request to a peer already in the ARP table (the table is drained
/// first — a reply may have landed while the shell idled). The peer's
/// MAC must be known (`net arp <ip>` resolves it first — an echo needs a
/// unicast dst; refused honestly otherwise). The reply is observed
/// asynchronously by the RX drain (`pongs_observed` + the `net` report's
/// `seq=`).
fn cmd_net_ping(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        m.console.print_line("net ping: usage: net ping <a.b.c.d>");
        return .invalid_argument;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        m.console.puts("net ping: invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        m.console.print_line("net ping: no virtio-net device");
        return .none;
    }
    virtio_net.net_rx_drain();
    var frame_len: usize = 0;
    switch (virtio_net.net_ping_request(ip, &frame_len)) {
        .ok => {
            virtio_net.ipv4.requests_sent += 1;
            virtio_net.ipv4.ping_seq +%= 1;
            m.console.puts("net ping: echo request to ");
            var ipbuf: [15]u8 = undefined;
            const in = virtio_net.arp.format_ip(ip, &ipbuf);
            m.console.puts(ipbuf[0..in]);
            m.console.puts(" sent (");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes)\n");
        },
        .not_ready => m.console.print_line("net ping: no IP set (net ip <a.b.c.d> first) or transport unready"),
        .timeout => m.console.print_line("net ping: echo request TX timeout (device did not complete within the poll budget)"),
        .no_peer => m.console.print_line("net ping: peer not in ARP table (net arp <a.b.c.d> first)"),
    }
    return .none;
}

/// `net udp [...]` — card N5 (claim 8552). No argument: the bounded
/// listen table + the counters. `listen <port>` / `close <port>`: add /
/// remove a listener (a full or duplicate table is refused honestly).
/// `send <ip> <port> <len>`: transmit ONE UDP datagram to the peer (peer
/// MAC from the ARP table; `.no_peer` refused — `net arp <ip>` resolves
/// first) from the fixed source port 7000, the byte-index payload (≤ 64,
/// honest truncation); a send to OUR OWN IP takes the LOOPBACK path (no
/// device round trip). `recv [<port>]`: drain the RX ring (a datagram
/// may have landed while the shell idled) and print + consume the
/// datagram(s) in the listener's bounded buffer byte-exact (hex, the
/// net-recv style).
fn cmd_net_udp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        var count: usize = 0;
        for (&virtio_net.udp.listen) |e| {
            if (e.valid) count += 1;
        }
        m.console.puts("net udp: entries=");
        m.console.print_u64(@intCast(count));
        m.console.puts("\n");
        for (&virtio_net.udp.listen) |e| {
            if (!e.valid) continue;
            m.console.puts("net udp: port=");
            m.console.print_u64(e.port);
            m.console.puts("\n");
        }
        m.console.puts("net udp: rx=");
        m.console.print_u64(virtio_net.udp.received);
        m.console.puts(",tx=");
        m.console.print_u64(virtio_net.udp.sent);
        m.console.puts(",loop=");
        m.console.print_u64(virtio_net.udp.loopbacked);
        m.console.puts(",drop=");
        m.console.print_u64(virtio_net.udp.dropped_badsum + virtio_net.udp.dropped_closed + virtio_net.udp.dropped_len);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "listen")) {
        if (args.len != 2) {
            m.console.print_line("net udp: usage: net udp listen <port>");
            return .invalid_argument;
        }
        const port = parse_port(args[1]) orelse {
            m.console.puts("net udp: invalid port: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (!virtio_net.udp.listen_port(port)) {
            m.console.print_line("net udp: listen failed (table full or duplicate)");
            return .none;
        }
        m.console.puts("net udp: listening on ");
        m.console.print_u64(port);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "close")) {
        if (args.len != 2) {
            m.console.print_line("net udp: usage: net udp close <port>");
            return .invalid_argument;
        }
        const port = parse_port(args[1]) orelse {
            m.console.puts("net udp: invalid port: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (!virtio_net.udp.close_port(port)) {
            m.console.puts("net udp: not listening on ");
            m.console.print_u64(port);
            m.console.puts("\n");
            return .none;
        }
        m.console.puts("net udp: closed ");
        m.console.print_u64(port);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "send")) {
        if (args.len != 4) {
            m.console.print_line("net udp: usage: net udp send <a.b.c.d> <port> <len>");
            return .invalid_argument;
        }
        const ip = virtio_net.arp.parse_ip(args[1]) orelse {
            m.console.puts("net udp: invalid address: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        const port = parse_port(args[2]) orelse {
            m.console.puts("net udp: invalid port: ");
            m.console.puts(args[2]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        const len = parseInt(args[3]) catch {
            m.console.puts("net udp: invalid length: ");
            m.console.puts(args[3]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (len < 1 or len > virtio_net.udp.payload_max) {
            m.console.puts("net udp: length must be between 1 and ");
            m.console.print_u64(virtio_net.udp.payload_max);
            m.console.puts("\n");
            return .invalid_argument;
        }
        // The deterministic payload — bytes 01 02 03 04… (byte i + 1,
        // bounded ≤ 64) — the live gate's byte-exact fixtures pin it.
        var payload: [virtio_net.udp.payload_max]u8 = undefined;
        var pi: usize = 0;
        while (pi < len) : (pi += 1) payload[pi] = @as(u8, @truncate(pi)) +% 1;
        var frame_len: usize = 0;
        switch (virtio_net.net_udp_send(ip, port, payload[0..@intCast(len)], &frame_len)) {
            .ok => {
                m.console.puts("net udp: sent ");
                m.console.print_u64(len);
                m.console.puts(" bytes to ");
                var ipbuf: [15]u8 = undefined;
                const in = virtio_net.arp.format_ip(ip, &ipbuf);
                m.console.puts(ipbuf[0..in]);
                m.console.puts(":");
                m.console.print_u64(port);
                m.console.puts(" (");
                m.console.print_u64(@intCast(frame_len));
                m.console.puts(" bytes)\n");
            },
            .not_ready => m.console.print_line("net udp: no IP set (net ip <a.b.c.d> first) or transport unready"),
            .timeout => m.console.print_line("net udp: datagram TX timeout (device did not complete within the poll budget)"),
            .no_peer => m.console.print_line("net udp: peer not in ARP table (net arp <a.b.c.d> first)"),
        }
        return .none;
    }
    if (std.mem.eql(u8, args[0], "recv")) {
        if (args.len > 2) {
            m.console.print_line("net udp: usage: net udp recv [<port>]");
            return .invalid_argument;
        }
        // A datagram may have landed while the shell idled — drain first.
        virtio_net.net_rx_drain();
        if (args.len == 2) {
            const port = parse_port(args[1]) orelse {
                m.console.puts("net udp: invalid port: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            _ = cmd_net_udp_recv_port(m, port);
            return .none;
        }
        var total: usize = 0;
        for (&virtio_net.udp.listen) |e| {
            if (!e.valid) continue;
            total += cmd_net_udp_recv_port(m, e.port);
        }
        m.console.puts("net udp recv: total=");
        m.console.print_u64(@intCast(total));
        m.console.puts("\n");
        return .none;
    }
    m.console.print_line("net udp: unknown subcommand (try 'net udp', 'net udp listen <port>', 'net udp close <port>', 'net udp send <a.b.c.d> <port> <len>' or 'net udp recv [<port>]')");
    return .invalid_argument;
}

/// Drain + print the datagrams buffered for ONE listener, byte-exact
/// (hex, the net-recv style). Returns how many were printed.
fn cmd_net_udp_recv_port(m: *Monitor, port: u16) usize {
    var count: usize = 0;
    while (virtio_net.udp.pop(port)) |d| {
        if (count == 0) {
            m.console.puts("net udp recv: port=");
            m.console.print_u64(port);
            m.console.puts("\n");
        }
        m.console.puts("net udp recv: [");
        m.console.print_u64(@intCast(count));
        m.console.puts("] len=");
        m.console.print_u64(@intCast(d.len));
        m.console.puts("\n");
        m.console.puts("net udp recv: ");
        var bi: usize = 0;
        while (bi < d.len) : (bi += 1) {
            if (bi > 0) m.console.puts(" ");
            const b = d.bytes[bi];
            const hex = "0123456789abcdef";
            var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
            m.console.puts(&two);
        }
        m.console.puts("\n");
        count += 1;
    }
    if (count == 0) {
        m.console.puts("net udp recv: no datagrams for port ");
        m.console.print_u64(port);
        m.console.puts("\n");
    }
    return count;
}

/// Parse a decimal (or 0x-prefixed hex) port in 0..65535, the `net udp`
/// subcommands' bound.
fn parse_port(text: []const u8) ?u16 {
    const v = parseInt(text) catch return null;
    if (v > 0xffff) return null;
    return @intCast(v);
}

/// `netsend <bytes>` — build the N1 known frame in the fixed staging
/// buffer (broadcast dst, own MAC src, ethertype 0x0800, a deterministic
/// byte-index payload), submit it on the TX queue, drain the used ring
/// (polled), and report exact byte counts. Over-limit requests truncate
/// honestly at the 1500-byte payload bound (the reply names the drop);
/// an absent/unarmed transport is refused honestly. This is the live
/// gate's byte-exact TX proof: the host's file-handle attachment captures
/// exactly the frame bytes reported here.
fn cmd_netsend(m: *Monitor, args: []const []const u8) ExecError {
    const requested = parseInt(args[0]) catch {
        m.console.puts("netsend: invalid byte count: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        m.console.print_line("netsend: transport not ready (no virtio-net device)");
        return .none;
    }
    m.console.puts("netsend: n=");
    m.console.print_u64(requested);
    if (requested > virtio_net.payload_max) {
        m.console.puts(" truncated to ");
        m.console.print_u64(virtio_net.payload_max);
        m.console.puts(" (payload bound)");
    }
    m.console.puts("\n");
    var frame_len: usize = 0;
    switch (virtio_net.net_send_frame(requested, &frame_len)) {
        .ok => {
            m.console.puts("netsend: tx ok frames=");
            m.console.print_u64(virtio_net.net_dev.tx_frames);
            m.console.puts(" bytes=");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts("\n");
            m.console.puts("netsend: sent ");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes\n");
        },
        .not_ready => m.console.print_line("netsend: transport not ready (no virtio-net device)"),
        .timeout => m.console.print_line("netsend: tx timeout (device did not complete within the poll budget)"),
        .no_peer => unreachable,
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Milestone six card G1 (claim 6053) — `screen` / `screen fill`
// ---------------------------------------------------------------------------

fn print_cmd_result(m: *Monitor, r: virtio_gpu.CmdResult) void {
    m.console.puts(switch (r) {
        .ok => "ok",
        .not_ready => "not-ready",
        .timeout => "timeout",
        .bad_response => "bad-response",
    });
}

/// `screen` — report the virtio-gpu transport: the OBSERVED device DID +
/// class + bus slot, the negotiated feature bits (low/high), the device's
/// num_scanouts, the scanout mode GET_DISPLAY_INFO reported (width x
/// height, enabled), the device status + post-exit re-arm state, the 2D
/// setup state, and the command counters. Grep-able and deterministic
/// (the net/mbox/procs observability shape). Honest when the device is
/// absent: the default runner attaches no graphics device. `screen fill
/// <rrggbb>` is the card-G1 subcommand: fill the framebuffer with the
/// 0xRRGGBB color, then TRANSFER_TO_HOST_2D + RESOURCE_FLUSH — the first
/// non-blank framebuffer the host `--screenshot` captures.
fn cmd_screen(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "fill")) return cmd_screen_fill(m, args[1..]);
        if (std.mem.eql(u8, args[0], "peek")) return cmd_screen_peek(m);
        m.console.print_line("screen: unknown subcommand (try 'screen' or 'screen fill <rrggbb>')");
        return .invalid_argument;
    }
    if (!virtio_gpu.gpu_ready) {
        m.console.puts("screen: no virtio-gpu device (");
        m.console.puts(if (virtio_gpu.gpu_fail.len > 0) virtio_gpu.gpu_fail else "DID 0x1050 not found on bus 0");
        m.console.puts(")\n");
        m.console.puts("screen: device-features=");
        m.console.print_hex(virtio_gpu.gpu_dev_feats_lo);
        m.console.puts("/");
        m.console.print_hex(virtio_gpu.gpu_dev_feats_hi);
        m.console.puts("\n");
        m.console.puts("screen: status=");
        m.console.print_hex(virtio_gpu.gpu_status_last);
        m.console.puts(" accepted=");
        m.console.print_hex(virtio_gpu.gpu_feats_lo);
        m.console.puts("/");
        m.console.print_hex(virtio_gpu.gpu_feats_hi);
        m.console.puts("\n");
        m.console.puts("screen: common=");
        m.console.print_hex(virtio_gpu.gpu_common);
        m.console.puts(" notify=");
        m.console.print_hex(virtio_gpu.gpu_notify);
        m.console.puts(" devcfg=");
        m.console.print_hex(virtio_gpu.gpu_devcfg);
        m.console.puts(" bar0=");
        m.console.print_hex(virtio_gpu.gpu_bar0);
        m.console.puts("\n");
        return .none;
    }
    m.console.puts("screen: did=");
    m.console.print_hex(virtio_gpu.gpu_did);
    m.console.puts(" class=");
    m.console.print_hex(virtio_gpu.gpu_class);
    m.console.puts(" dev=");
    m.console.print_u64(virtio_gpu.gpu_dev);
    m.console.puts("\n");
    m.console.puts("screen: devfeat=");
    m.console.print_hex(virtio_gpu.gpu_dev_feats_lo);
    m.console.puts("/");
    m.console.print_hex(virtio_gpu.gpu_dev_feats_hi);
    m.console.puts("\n");
    m.console.puts("screen: feat=");
    m.console.print_hex(virtio_gpu.gpu_feats_lo);
    m.console.puts("/");
    m.console.print_hex(virtio_gpu.gpu_feats_hi);
    m.console.puts(" scanouts=");
    m.console.print_hex(virtio_gpu.gpu_num_scanouts);
    m.console.puts("\n");
    m.console.puts("screen: scanout=");
    m.console.print_hex(virtio_gpu.gpu_scanout_w);
    m.console.puts("x");
    m.console.print_hex(virtio_gpu.gpu_scanout_h);
    m.console.puts(" enabled=");
    m.console.print_hex(virtio_gpu.gpu_scanout_enabled);
    m.console.puts("\n");
    m.console.puts("screen: status=");
    m.console.print_hex(virtio_gpu.gpu_status_last);
    m.console.puts(" rearm=");
    m.console.print_u64(if (virtio_gpu.gpu_rearmed) 1 else 0);
    m.console.puts(" setup=");
    m.console.print_u64(if (virtio_gpu.gpu_setup_ok) 1 else 0);
    m.console.puts(" cmds=");
    m.console.print_u64(virtio_gpu.gpu_cmds);
    m.console.puts(" errors=");
    m.console.print_u64(virtio_gpu.gpu_errors);
    m.console.puts(" timeouts=");
    m.console.print_u64(virtio_gpu.gpu_timeouts);
    m.console.puts("\n");
    // The timeout diagnostics (the claim-time record of a stuck queue).
    m.console.puts("screen: diag avail=");
    m.console.print_u64(virtio_gpu.gpu_diag_avail);
    m.console.puts(" used=");
    m.console.print_u64(virtio_gpu.gpu_diag_used);
    m.console.puts(" st=");
    m.console.print_hex(virtio_gpu.gpu_diag_st);
    m.console.puts(" qen=");
    m.console.print_u64(virtio_gpu.gpu_diag_qen);
    m.console.puts(" qoff=");
    m.console.print_u64(virtio_gpu.gpu_diag_qoff);
    m.console.puts(" mult=");
    m.console.print_u64(virtio_gpu.gpu_diag_mult);
    m.console.puts(" notify=");
    m.console.print_hex(virtio_gpu.gpu_diag_notify);
    m.console.puts("\n");
    m.console.puts("screen: rings desc=");
    m.console.print_hex(virtio_gpu.gpu_diag_desc_phys);
    m.console.puts(" avail=");
    m.console.print_hex(virtio_gpu.gpu_diag_avail_phys);
    m.console.puts(" used=");
    m.console.print_hex(virtio_gpu.gpu_diag_used_phys);
    m.console.puts("\n");
    m.console.puts("screen: diag cmd0=");
    m.console.print_hex(virtio_gpu.gpu_diag_cmd0);
    m.console.puts(" cmd1=");
    m.console.print_hex(virtio_gpu.gpu_diag_cmd1);
    m.console.puts(" isr=");
    m.console.print_hex(virtio_gpu.gpu_diag_isr);
    m.console.puts(" qsz=");
    m.console.print_u64(virtio_gpu.gpu_diag_qsz);
    m.console.puts(" bar0=");
    m.console.print_hex(virtio_gpu.gpu_bar0);
    m.console.puts(" common=");
    m.console.print_hex(virtio_gpu.gpu_common);
    m.console.puts(" devcfg=");
    m.console.print_hex(virtio_gpu.gpu_devcfg);
    m.console.puts(" fb=");
    m.console.print_hex(virtio_gpu.gpu_fb_phys);
    m.console.puts("\n");
    return .none;
}

/// `screen fill <rrggbb>` — fill the framebuffer with the 0xRRGGBB color
/// (out-of-range colors are refused honestly), then TRANSFER_TO_HOST_2D +
/// RESOURCE_FLUSH so the host scanout shows it. The live gate's marker:
/// the `--screenshot` pixels then match the fill.
fn cmd_screen_fill(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        m.console.print_line("usage: screen fill <rrggbb>");
        return .usage;
    }
    const rgb = parseHex(args[0]) catch {
        m.console.puts("screen fill: invalid color: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (rgb > 0xffffff) {
        m.console.print_line("screen fill: color out of range (max 0xffffff)");
        return .invalid_argument;
    }
    if (!virtio_gpu.gpu_ready) {
        m.console.print_line("screen fill: transport not ready (no virtio-gpu device)");
        return .none;
    }
    virtio_gpu.fill_framebuffer(@truncate(rgb));
    const tx = virtio_gpu.gpu_transfer();
    const fl = virtio_gpu.gpu_flush();
    m.console.puts("screen fill: fill=");
    m.console.print_hex(rgb);
    m.console.puts(" transfer=");
    print_cmd_result(m, tx);
    m.console.puts(" flush=");
    print_cmd_result(m, fl);
    m.console.puts("\n");
    return .none;
}

/// `screen peek` — dump the first 8 bytes of the framebuffer (B,G,R,X for
/// the first pixel) + a checksum of the first 4096 bytes, so the gate can
/// prove the GUEST-side fill landed before blaming the host display.
fn cmd_screen_peek(m: *Monitor) ExecError {
    if (!virtio_gpu.gpu_ready) {
        m.console.print_line("screen peek: transport not ready (no virtio-gpu device)");
        return .none;
    }
    m.console.puts("screen peek: fb=");
    m.console.print_hex(virtio_gpu.gpu_fb_phys);
    m.console.puts(" bytes=");
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < 4096 and i < virtio_gpu.fb_size) : (i += 1) {
        sum +%= virtio_gpu.gpu_fb[i];
    }
    m.console.print_hex(sum);
    m.console.puts(" p0=");
    m.console.print_hex(virtio_gpu.gpu_fb[0]);
    m.console.puts(" p1=");
    m.console.print_hex(virtio_gpu.gpu_fb[1]);
    m.console.puts(" p2=");
    m.console.print_hex(virtio_gpu.gpu_fb[2]);
    m.console.puts(" p3=");
    m.console.print_hex(virtio_gpu.gpu_fb[3]);
    m.console.puts("\n");
    return .none;
}

/// `text` — report the framebuffer text layer: the region (rows/cols at
/// the cell size), the cursor (row/col), the scrollback depth, and the
/// colors. `text put <string...>` renders the string and pushes it to
/// the scanout (transfer + flush — the live gate's driver); `text clear`
/// clears + pushes. Honest without the gpu: the report works with no
/// device, `put`/`clear` refuse.
fn cmd_text(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        m.console.puts("text: rows=");
        m.console.print_u64(fbtext.rows);
        m.console.puts(" cols=");
        m.console.print_u64(fbtext.cols);
        m.console.puts(" cell=");
        m.console.print_u64(fbtext.cell_w);
        m.console.puts("x");
        m.console.print_u64(fbtext.cell_h);
        m.console.puts(" cur=");
        m.console.print_u64(fbtext.cursor_row());
        m.console.puts(",");
        m.console.print_u64(fbtext.cursor_col());
        m.console.puts(" lines=");
        m.console.print_u64(fbtext.line_count());
        m.console.puts(" fg=");
        m.console.print_hex(fbtext.fg_rgb);
        m.console.puts(" bg=");
        m.console.print_hex(fbtext.bg_rgb);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "put")) {
        if (args.len < 2) {
            m.console.print_line("usage: text put <string...>");
            return .usage;
        }
        if (!virtio_gpu.gpu_ready) {
            m.console.print_line("text put: transport not ready (no virtio-gpu device)");
            return .none;
        }
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (i > 1) fbtext.putc(' ');
            fbtext.puts(args[i]);
        }
        fbtext.putc('\n');
        // Card G5 (claim 1543): present through the Driving Award
        // compositor so the clock overlay stays composited over the
        // repainted terminal.
        driving_award.mark_terminal_dirty();
        const r = driving_award.composite();
        m.console.puts("text put: ");
        print_cmd_result(m, r);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "clear")) {
        if (!virtio_gpu.gpu_ready) {
            m.console.print_line("text clear: transport not ready (no virtio-gpu device)");
            return .none;
        }
        fbtext.clear();
        // Card G5 (claim 1543): present through the compositor (see put).
        driving_award.mark_terminal_dirty();
        const r = driving_award.composite();
        m.console.puts("text clear: ");
        print_cmd_result(m, r);
        m.console.puts("\n");
        return .none;
    }
    m.console.print_line("text: unknown subcommand (try 'text', 'text put <string...>', or 'text clear')");
    return .invalid_argument;
}

// ---------------------------------------------------------------------------
// Task lifecycle command (claim 6729)
// ---------------------------------------------------------------------------

/// Spawn the lifecycle demo task (the scheduler owns the demo stack and
/// refuses a second spawn). Proves a runtime spawn enters the ring: the
/// demo task's `tasks spawn-demo advances=N` report lines follow. The
/// EL0 task's own exit + the idle task's reap prove the rest of the
/// lifecycle.
fn cmd_spawn(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    if (scheduler.spawn_demo()) |id| {
        m.console.puts("spawn: spawn-demo id=");
        m.console.print_u64(@intCast(id));
        m.console.puts("\n");
    } else {
        m.console.puts("spawn: pool full or demo already running\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// ESP exec command (claim 6783 — milestone-three card 6)
// ---------------------------------------------------------------------------

/// Load a user program from the ESP and enter it at EL0. `exec [<file>
/// [arg...]]` defaults to `USER.BIN` (the image builder embeds it at the
/// volume root; it can also be written at runtime through the FAT `write`
/// path). The program must be a DSK1 flat image; the kernel reads it
/// through the claim-6420 FAT path, rebuilds the EL0 user root around its
/// page, and spawns it as an EL0t task. Arguments (card 3e, claim 4636)
/// are packed into the program's text page and passed at entry (argc in
/// x0, argv block VA in x1) — bounded to `max_exec_args`; more than that
/// is refused honestly. Every failure mode is reported honestly.
fn cmd_exec(m: *Monitor, args: []const []const u8) ExecError {
    const name = if (args.len >= 1) args[0] else esp_exec.default_name;
    const prog_args = if (args.len >= 2) args[1..] else &.{};
    switch (esp_exec.exec_file(name, prog_args)) {
        .ok => {
            const info = esp_exec.loaded().?;
            m.console.puts("exec: loaded ");
            m.console.puts(info.name);
            m.console.puts(" size=");
            m.console.print_hex(@intCast(info.content_len));
            m.console.puts(" entry=");
            m.console.print_hex(info.entry_va);
            // Claim 0826: the process's OWN stack placement, not the
            // static boot stack's.
            m.console.puts(" stack=");
            m.console.print_hex(info.stack_va);
            const head = esp_exec.head();
            var head_value: u64 = 0;
            for (head, 0..) |byte, i| head_value |= @as(u64, byte) << @intCast(56 - i * 8);
            m.console.puts(" head=");
            m.console.print_hex(head_value);
            m.console.puts("\n");
            return .none;
        },
        .no_disk => {
            m.console.print_line("exec: no disk (ESP FAT volume unavailable)");
            return .not_implemented;
        },
        .not_found => {
            m.console.puts("exec: ");
            m.console.puts(name);
            m.console.print_line(": not found on the ESP (must be a DSK1 flat image)");
            return .invalid_argument;
        },
        .too_large => {
            m.console.puts("exec: ");
            m.console.puts(name);
            m.console.puts(": image larger than the ");
            m.console.print_hex(esp_exec.exec_program_max);
            m.console.print_line("-byte load buffer");
            return .invalid_argument;
        },
        .bad_magic => {
            m.console.puts("exec: ");
            m.console.puts(name);
            m.console.print_line(": not a DSK1 program image (bad magic)");
            return .invalid_argument;
        },
        .bad_entry => {
            m.console.puts("exec: ");
            m.console.puts(name);
            m.console.print_line(": bad entry offset (outside the loaded content)");
            return .invalid_argument;
        },
        .out_of_memory => {
            m.console.print_line("exec: out of physical pages (text/stack/exception stack)");
            return .machine_failed;
        },
        .pool_full => {
            m.console.print_line("exec: no free scheduler pool slot");
            return .machine_failed;
        },
        .table_full => {
            m.console.print_line("exec: page-table carve-out exhausted (too many user-root rebuilds)");
            return .machine_failed;
        },
        .process_full => {
            m.console.print_line("exec: process registry exhausted (all processes live; wait for one to exit)");
            return .machine_failed;
        },
        .too_many_args => {
            m.console.puts("exec: too many arguments (max ");
            m.console.print_u64(esp_exec.max_exec_args);
            m.console.print_line(")");
            return .invalid_argument;
        },
        .no_args_room => {
            m.console.print_line("exec: image leaves no room for the argv block (256 bytes)");
            return .invalid_argument;
        },
    }
}

// ---------------------------------------------------------------------------
// Syscall ABI command (claim 3594)
// ---------------------------------------------------------------------------

fn cmd_syscalls(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    syscall.report(&m.console);
    return .none;
}

// ---------------------------------------------------------------------------
// Per-task address-space command (claim 5804)
// ---------------------------------------------------------------------------

/// Report the address-space split (claim 5804, VZ fallback): TTBR1 must
/// be 0 (unused — the kernel is identity-mapped in TTBR0), every task's
/// TTBR0 root, and the user root's leaf inventory. The user root is the
/// identity clone + user leaves: `el0` leaves must be EXACTLY the
/// text+stack leaves, and `el0_device` must be 0 (MMIO excluded from EL0
/// by the EL1-only AP bits on the overlay's Device leaves). Deterministic
/// and grep-able; on host test processes the roots are never built, so it
/// honestly prints zeros for the register/root values and 0 leaves.
fn cmd_addrspaces(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("addrspaces: ttbr1=");
    m.console.print_hex(mmu.read_ttbr1());
    m.console.puts(" root=");
    m.console.print_hex(mmu.kernel_root_phys());
    m.console.puts(" tcr=");
    m.console.print_hex(mmu.read_tcr());
    m.console.puts(" t0sz=16\n");
    var i: usize = 0;
    while (i < scheduler.max_tasks) : (i += 1) {
        const info = scheduler.task_info(i) orelse continue;
        m.console.puts("addrspaces: task ");
        m.console.puts(info.name);
        m.console.puts(" ttbr0=");
        m.console.print_hex(scheduler.task_ttbr0(i));
        m.console.puts("\n");
    }
    // Claim 6729: the user task's root is a fixed MMU fact (built at boot),
    // not a task-table fact — the lifecycle's idle task reaps the exited
    // user task, so the `task user-el0` row above may legitimately be gone
    // by the time this command runs. Report the root directly so the
    // ownership assertion (user root != kernel root) survives the reap.
    m.console.puts("addrspaces: user root=");
    m.console.print_hex(mmu.user_root_phys());
    m.console.puts("\n");
    // Claim 0826: the per-process-root budget — table pages consumed out of
    // the fixed 256-page carve-out. Card 3g (claim 5795): FOUR live user
    // roots (~15 each + leaf tables) stay well inside it; the scale live
    // gate reads this line for the headroom assertion.
    m.console.puts("addrspaces: tables=");
    m.console.print_u64(@intCast(mmu.tables_used()));
    m.console.puts("/");
    m.console.print_u64(@intCast(mmu.tables_capacity()));
    m.console.puts("\n");
    const leaves = mmu.walk_leaves(mmu.user_root_phys());
    m.console.puts("addrspaces: user text=");
    m.console.print_hex(userspace.text_va);
    m.console.puts(" stack=");
    m.console.print_hex(userspace.user_stack_va());
    m.console.puts(" leaves=");
    m.console.print_u64(leaves.leaves);
    m.console.puts(" device=");
    m.console.print_u64(leaves.device_leaves);
    m.console.puts(" el0=");
    m.console.print_u64(leaves.el0_leaves);
    m.console.puts(" el0_device=");
    m.console.print_u64(leaves.el0_device_leaves);
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// Uaccess diagnostic command (claim 6120)
// ---------------------------------------------------------------------------

/// Prove both uaccess paths on live hardware: the validated copy from the
/// user text aperture succeeds, and a raw copy from an unmapped address
/// above the identity blanket takes a REAL EL1 data abort that the
/// exception path recovers into EFAULT (recoveries >= 1). Honest on host
/// test processes (no vectors): `recovered=0` there. Gates on the real
/// recovery count, so the class-B gate can assert `recovered=1` exactly
/// when it drives this command once.
fn cmd_uaccess(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const d = uaccess.diag();
    m.console.puts("uaccess: valid=");
    m.console.print_u64(if (d.valid_copy) 1 else 0);
    m.console.puts(" fault=");
    m.console.print_u64(if (d.fault_copy) 1 else 0);
    m.console.puts(" recovered=");
    m.console.print_u64(d.recoveries);
    m.console.puts(" copies=");
    m.console.print_u64(d.copies);
    m.console.puts(" validation_faults=");
    m.console.print_u64(d.validation_faults);
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// Randomness command (milestone four, claim 2665)
// ---------------------------------------------------------------------------

/// Print `n` (1..256, default 16) random bytes from the seeded CSPRNG as
/// lowercase hex on one grep-able line: `random: n=<count> hex=<2n hex>`.
/// The CSPRNG is seeded at boot from the REAL virtio entropy device; the
/// class-B gate proves the real path by requiring two boots to produce
/// different output.
fn cmd_random(m: *Monitor, args: []const []const u8) ExecError {
    var count: usize = 16; // fixed-size sample when no argument
    if (args.len == 1) {
        count = @intCast(parseInt(args[0]) catch {
            m.console.puts("random: invalid count: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        });
        if (count < 1 or count > random_max_bytes) {
            m.console.puts("random: count must be between 1 and ");
            m.console.print_u64(random_max_bytes);
            m.console.puts("\n");
            return .invalid_argument;
        }
    }
    var buf: [random_max_bytes]u8 = undefined;
    csprng.random_bytes(buf[0..count]);
    m.console.puts("random: n=");
    m.console.print_u64(count);
    m.console.puts(" hex=");
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < count) : (i += 1) {
        m.console.putc(hex[@as(usize, buf[i] >> 4)]);
        m.console.putc(hex[@as(usize, buf[i] & 0xf)]);
    }
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// PCI enumeration command (macOS 27 custom-virtio spike, audit step 3)
// ---------------------------------------------------------------------------

/// Live bus-0 PCI enumeration through the ECAM window discovered pre-exit
/// (claim 0013). Post-exit ECAM reads work — the virtio console transport
/// does config-space reads post-MMU (claims 1517/6684); the historical
/// "pre-exit only" note predates the T0SZ=16 + TLBI fix. Aligned u32 reads
/// only (claim 0013: byte reads of config space return shifted/garbage
/// fields on VZ). This is the guest-side evidence for the custom virtio
/// spike device at DID 0x1082 (deviceID 0x42; host runner: `zig build
/// spike-virtio`).
fn cmd_pci(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const ecam = pci.pci_ecam;
    m.console.puts("pci: ecam=");
    m.console.print_hex(ecam);
    m.console.puts("\n");
    if (ecam == 0 or ecam > 4 * 1024 * 1024 * 1024) {
        m.console.print_line("pci: no ECAM (not discovered pre-exit)");
        return .none;
    }
    var found: usize = 0;
    var dev: u32 = 0;
    while (dev < 32 and found < 48) : (dev += 1) {
        var func: u32 = 0;
        var funcs: u32 = 1;
        while (func < funcs and found < 48) : (func += 1) {
            const id = pci.pci_read32(ecam, 0, dev, func, 0);
            const vid = id & 0xffff;
            if (vid == 0xffff) continue;
            const hdr = pci.pci_read32(ecam, 0, dev, func, 0x0c);
            const ht = (hdr >> 8) & 0xff;
            if (func == 0 and (ht & 0x80) != 0) funcs = 8;
            const did = id >> 16;
            m.console.puts("PCI D=");
            m.console.print_hex(@intCast(dev));
            m.console.puts(" F=");
            m.console.print_hex(@intCast(func));
            m.console.puts(" VID=");
            m.console.print_hex(vid);
            m.console.puts(" DID=");
            m.console.print_hex(did);
            m.console.puts(" CLS=");
            m.console.print_hex((pci.pci_read32(ecam, 0, dev, func, 8) >> 8) & 0xffffff);
            var b: u32 = 0;
            while (b < 6) : (b += 1) {
                m.console.puts(" B");
                m.console.print_hex(@intCast(b));
                m.console.puts("=");
                m.console.print_hex(pci.pci_read32(ecam, 0, dev, func, 0x10 + b * 4));
            }
            m.console.puts("\n");
            found += 1;
        }
    }
    m.console.puts("pci: found=");
    m.console.print_hex(@intCast(found));
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// Exception-vector diagnostic command (claim 9746)
// ---------------------------------------------------------------------------

/// Deliberately trigger a synchronous exception (`udf`) with the resume
/// flag armed: the kernel's exception handler (installed at boot, claim
/// 9746) reports the fault, skips the faulting instruction, and the shell
/// resumes. Gates on `exceptions.installed()` — a host test process has no
/// vectors (even on an aarch64 host, where executing `udf` would SIGILL),
/// so the command honestly reports that instead.
fn cmd_fault(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    if (!exceptions.installed()) {
        m.console.print_line("fault: exception vectors not installed; nothing to trigger");
        return .not_implemented;
    }
    m.console.print_line("fault: triggering udf (synchronous exception)...");
    exceptions.trigger_test_fault();
    m.console.print_line("fault: handled, resumed after faulting instruction");
    return .none;
}

fn cmd_elephant(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    for (elephant_lines()) |line| m.console.print_line(line);
    m.console.print_line("ELEPHANT ONLINE");
    print_plain_field(m, "trunk", "up");
    m.console.puts("\n");
    print_plain_field(m, "ears", "floppy");
    m.console.puts("\n");
    print_plain_field(m, "console", m.state.console_name);
    m.console.puts("\n");
    const err = handoff.validate(&m.state.handoff);
    if (err == .none) {
        print_plain_field(m, "handoff", "valid");
    } else {
        m.console.puts("  handoff: invalid (");
        m.console.puts(handoff.error_name(err));
        m.console.puts(")");
    }
    m.console.puts("\n");
    print_plain_field(m, "memory", "descriptors=");
    m.console.print_hex(@intCast(m.state.map.count));
    m.console.puts("\n");
    return .none;
}

fn cmd_beans(m: *Monitor, args: []const []const u8) ExecError {
    var count: u64 = 42;
    if (args.len == 1) {
        count = parseInt(args[0]) catch {
            m.console.puts("beans: invalid count: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (count < 1 or count > beans_max_count) {
            m.console.puts("beans: count must be between 1 and ");
            m.console.print_u64(beans_max_count);
            m.console.puts("\n");
            return .invalid_argument;
        }
    }
    m.console.print_line("beans");
    m.console.puts("counting beans... ");
    m.console.print_u64(count);
    m.console.print_line(" beans in a trench coat.");
    m.console.print_line("that's it. that's the command.");
    return .none;
}

// ---------------------------------------------------------------------------
// Boot-message personality and banner (step 18)
// ---------------------------------------------------------------------------

pub const BootMessages = struct {
    /// Runtime-built message table into module storage (not a const array
    /// of string slices: those hold link-time absolute pointers, wrong at
    /// the kernel's runtime load base — claim 0015 root cause).
    var storage: [6][]const u8 = undefined;
    var ready = false;
    pub fn messages() []const []const u8 {
        if (!ready) {
            storage[0] = "DipshitOS: the elephant has left the building.";
            storage[1] = "DipshitOS: 42 beans, zero dignity.";
            storage[2] = "DipshitOS: memory is a map, not a territory.";
            storage[3] = "DipshitOS: no libc was harmed in the making of this kernel.";
            storage[4] = "DipshitOS: terminal loop, meet the monitor.";
            storage[5] = "DipshitOS: from scratch, with love and beans.";
            ready = true;
        }
        return &storage;
    }

    /// Deterministic, stateless "rotation": the choice depends only on the
    /// boot's image handle, so it is stable within a boot, varies across
    /// boots, and needs no hidden mutable state.
    pub fn pick(image_handle: u64) []const u8 {
        const msgs = messages();
        return msgs[@as(usize, @intCast(image_handle % msgs.len))];
    }
};

/// Banner text the later shell-core stream prints at boot. Deliberately
/// does not print "DIPSHITOS 0.1" (the repository defines no release
/// number) or a hardcoded "256 MiB detected" (memory must be derived from
/// the captured map — `mem` does exactly that).
pub fn banner(m: *Monitor) void {
    m.console.print_line("DipshitOS - AArch64 firmware-assisted kernel monitor");
    m.console.puts(BootMessages.pick(m.state.handoff.image_handle));
    m.console.puts("\n");
    m.console.print_line("Type 'help' before touching anything expensive.");
}

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
    mock: console.MockConsole(4096) = .{},
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

fn test_syscall_writer(_: []const u8) void {}

test "monitor: command lookup" {
    try std.testing.expect(lookup("echo") != null);
    try std.testing.expectEqualStrings("echo", lookup("echo").?.name);
    try std.testing.expect(lookup("beans") != null);
    try std.testing.expect(lookup("help") != null);
    try std.testing.expect(lookup("frobnicate") == null);
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
    try std.testing.expectEqualStrings("mbox: no such process: 7\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "mbox", "nope" }));
    try std.testing.expectEqualStrings("mbox: invalid pid: nope\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("help: no such command: bogus\n", env.mock.contents());
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

test "monitor: card U2 — complete_line completes verbs by unique prefix" {
    try std.testing.expectEqualStrings("sion ", complete_line("ver").?);
    // "he" is genuinely ambiguous (help + hex) — use the longer prefix.
    try std.testing.expectEqual(@as(?[]const u8, null), complete_line("he"));
    try std.testing.expectEqualStrings("p ", complete_line("hel").?);
    try std.testing.expectEqualStrings("ces ", complete_line("addrspa").?);
    // A fully-typed unique verb completes to just the space.
    try std.testing.expectEqualStrings(" ", complete_line("echo").?);
    // Ambiguity: net + netsend (and more) share the "n" prefix.
    try std.testing.expectEqual(@as(?[]const u8, null), complete_line("n"));
    // Even "net" is ambiguous (netsend): bell, not a wrong completion.
    try std.testing.expectEqual(@as(?[]const u8, null), complete_line("net"));
    try std.testing.expectEqualStrings("nd ", complete_line("netse").?);
    // No match at all.
    try std.testing.expectEqual(@as(?[]const u8, null), complete_line("zz"));
}

test "monitor: card U2 — complete_line completes sub-verbs by table" {
    try std.testing.expectEqualStrings("dp ", complete_line("net u").?);
    try std.testing.expectEqualStrings("ing ", complete_line("net p").?);
    try std.testing.expectEqualStrings(" ", complete_line("net udp").?); // fully typed + space
    // The word after a completed verb: "net udp " completes nothing at
    // depth 2 with an empty word unless a row starts with "" — all do,
    // so an empty word is ambiguous (4 udp words): bell.
    try std.testing.expectEqual(@as(?[]const u8, null), complete_line("net udp "));
}

test "monitor: card U2 — complete_line completes depth-2 sub-verbs" {
    try std.testing.expectEqualStrings("sten ", complete_line("net udp li").?);
    try std.testing.expectEqualStrings("ect ", complete_line("net tcp conn").?);
    try std.testing.expectEqualStrings("ocus ", complete_line("win f").?);
    try std.testing.expectEqualStrings("ata ", complete_line("mount d").?);
    // Ambiguous sub-verbs: net udp c (close) vs nothing else? close is
    // unique; but net tcp c is ambiguous (close/connect).
    try std.testing.expectEqual(@as(?[]const u8, null), complete_line("net tcp c"));
    // Unknown verb: no sub-verb completion.
    try std.testing.expectEqual(@as(?[]const u8, null), complete_line("echo tr"));
    // A verb with no sub-verbs at depth 2: "mount esp x" has no table rows.
    try std.testing.expectEqual(@as(?[]const u8, null), complete_line("mount esp x"));
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
    try std.testing.expectEqualStrings("unknown command: frobnicate\ntype 'help' for a list of commands\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("usage: hex <number>...\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{"repeat"}));
    try std.testing.expectEqualStrings("usage: repeat <count> <text...>\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "beans", "1", "2" }));
    try std.testing.expectEqualStrings("usage: beans [count]\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client)", lookup("net").?.help);
    try std.testing.expect(lookup("netsend") != null);
}

test "monitor: screen reports no device honestly when the transport is absent" {
    var env = TestEnv.init();
    var mon = env.monitor();
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
    try std.testing.expectEqualStrings("screen fill: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    // An out-of-range color is refused honestly even before the transport
    // check.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "screen", "fill", "0x1000000" }));
    try std.testing.expectEqualStrings("screen fill: color out of range (max 0xffffff)\n", env.mock.contents());
    // `screen` is registered (the registry-row shape).
    try std.testing.expect(lookup("screen") != null);
    try std.testing.expectEqualStrings("virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)", lookup("screen").?.help);
}

test "monitor: text reports the region and refuses put/clear without the transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
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
    try std.testing.expectEqualStrings("text put: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "text", "clear" }));
    try std.testing.expectEqualStrings("text clear: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    // An unknown subcommand is refused honestly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "text", "bogus" }));
    // `text` is registered (the registry-row shape).
    try std.testing.expect(lookup("text") != null);
    try std.testing.expectEqualStrings("framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears)", lookup("text").?.help);
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
    try std.testing.expectEqualStrings("XHCI host controller: `usb` transport report, `usb devices` enumerated HID devices, `usb report` last HID report", lookup("usb").?.help);
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
    try std.testing.expectEqualStrings("net ip: invalid address: 999.0.0.1\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "ip" }));
    try std.testing.expectEqualStrings("net ip: usage: net ip <a.b.c.d>\n", env.mock.contents());
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
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
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
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
}

test "monitor: net arp resolve — miss sends the request, no-IP refuses honestly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
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
    try std.testing.expectEqualStrings("net arp: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.arp.requests_sent); // nothing sent
    // Malformed addresses refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "arp", "nope" }));
    try std.testing.expectEqualStrings("net arp: invalid address: nope\n", env.mock.contents());
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
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
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
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ping", "10.0.0.3" }));
    try std.testing.expectEqualStrings("net ping: peer not in ARP table (net arp <a.b.c.d> first)\n", env.mock.contents());
    // Without a static IP the ping is refused honestly.
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ping", "10.0.0.2" }));
    try std.testing.expectEqualStrings("net ping: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
    // Malformed addresses refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "ping", "nope" }));
    try std.testing.expectEqualStrings("net ping: invalid address: nope\n", env.mock.contents());
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
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
    try std.testing.expectEqualStrings("net udp: not listening on 7000\n", env.mock.contents());
    // A duplicate listen and a malformed port refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    try std.testing.expectEqualStrings("net udp: listen failed (table full or duplicate)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "listen", "nope" }));
    try std.testing.expectEqualStrings("net udp: invalid port: nope\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("net udp: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
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
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
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
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.3", "9999", "4" }));
    try std.testing.expectEqualStrings("net udp: peer not in ARP table (net arp <a.b.c.d> first)\n", env.mock.contents());
    // Length bounds refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "0" }));
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "65" }));
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: netsend refuses cleanly without a transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = false;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "netsend", "32" }));
    try std.testing.expectEqualStrings("netsend: transport not ready (no virtio-net device)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "netsend", "abc" }));
    try std.testing.expectEqualStrings("netsend: invalid byte count: abc\n", env.mock.contents());
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
    var frame: [virtio_net.rx_buf_len]u8 = .{0} ** virtio_net.rx_buf_len;
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
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "bogus" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net: unknown subcommand (try 'net', 'net recv', 'net ip <a.b.c.d>', 'net arp [<a.b.c.d>]', 'net ping <a.b.c.d>', 'net udp [listen|close|send|recv]', 'net dhcp' or 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]')\n") != null);
    virtio_net.net_ready = false;
    virtio_net.rx_fifo_head = 0;
    virtio_net.rx_fifo_count = 0;
}

test "monitor: identity commands produce fixed output" {
    var env = TestEnv.init();
    var mon = env.monitor();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"version"}));
    try std.testing.expectEqualStrings(
        "dipshit-kernel\nmilestone-two kernel proper (ADR 0004)\nhandoff ABI v2\nbuild label: m1.5 commands & personality (mock console)\n",
        env.mock.contents(),
    );
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"uname"}));
    try std.testing.expectEqualStrings("DipshitOS aarch64\nfreestanding kernel; no POSIX compatibility\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"about"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "from-scratch AArch64 operating system") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "no libc, no POSIX") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Apple Virtualization.framework") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mock") != null);
}

test "monitor: handoff formatting is deterministic and validated" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"handoff"}));
    try std.testing.expectEqualStrings(
        "handoff v2\n" ++
            "  magic        0x00000000324b5344\n" ++
            "  version      0x0000000000000002\n" ++
            "  kernel_base  0x000000007e4df000\n" ++
            "  kernel_size  0x00000000000823e8\n" ++
            "  system_table 0x000000000feed000\n" ++
            "  image_handle 0x0000000000000002\n" ++
            "  stack_base   0x000000007e520000\n" ++
            "  stack_size   0x0000000000004000\n" ++
            "  flags        0x0000000000000000\n" ++
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
    try std.testing.expectEqualStrings("hex: invalid number: zz\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "-1" }));
    try std.testing.expectEqualStrings("hex: invalid number: -1\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "18446744073709551616" }));
    try std.testing.expectEqualStrings("hex: invalid number: 18446744073709551616\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("repeat: count must be between 1 and 64\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "65", "x" }));
    try std.testing.expectEqualStrings("repeat: count must be between 1 and 64\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "zz", "x" }));
    try std.testing.expectEqualStrings("repeat: invalid count: zz\n", env.mock.contents());
    env.mock.reset();
    // Count with no text repeats blank lines, deterministically.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "3" }));
    try std.testing.expectEqualStrings("\n\n\n", env.mock.contents());

    // 70-char line: 57 repetitions fit (57*71 = 4047 <= 4096), 58 do not.
    const long = "a" ** 70;
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "57", long }));
    try std.testing.expectEqual(@as(usize, 57 * 71), env.mock.contents().len);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "58", long }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "repeat: output too large (max 4096 bytes)") != null);
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
    try std.testing.expectEqualStrings("shutdown: ok\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("reboot: failed\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("beans: count must be between 1 and 100\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "beans", "101" }));
    try std.testing.expectEqualStrings("beans: count must be between 1 and 100\n", env.mock.contents());
}

test "monitor: random prints a deterministic hex line from the seeded CSPRNG and bounds count" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("random") != null);
    try std.testing.expectEqualStrings("print n random bytes from the seeded CSPRNG (hex)", lookup("random").?.help);
    // Seed with a fixed value so the output is deterministic in the test.
    csprng.seed(&[_]u8{0x5a} ** csprng.seed_len);
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
        "timer: armed=0 gic=none dist=0x0 ppi=0x1e freq=0x0 ticks=0 irq=0 poll=0 acked=0 first=0xffffffff\n",
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
        "tasks: enabled=0 current=0 switches=0 pool=4/7 zombies=0\n" ++
            "  shell    saves=0 resumes=0 advances=0 state=ready\n" ++
            "  worker   saves=0 resumes=0 advances=0 state=ready\n" ++
            "  user-el0 saves=0 resumes=0 advances=0 state=ready\n" ++
            "  idle     saves=0 resumes=0 advances=0 state=ready\n",
        env.mock.contents(),
    );
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
            "procs: id=0 name=user-el0 state=exited task=reaped stack=0x0000000080000000 exit=7\n" ++
            "procs: id=1 name=USER.BIN state=running task=2 stack=0x000000001a400000 exit=-\n",
        env.mock.contents(),
    );
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
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user -> killed -> spawn-demo
    try std.testing.expectEqual(@as(?u64, scheduler.reserved_kill_status), scheduler.terminated_status(2));
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
    try std.testing.expectEqualStrings("kill: BOOTED already exited\n", env.mock.contents());
    // A CREATED (loaded, not yet bound) process: no executor to terminate.
    env.mock.reset();
    _ = process.create("ROLLBACK.BIN", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{});
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "ROLLBACK.BIN" }));
    try std.testing.expectEqualStrings("kill: ROLLBACK.BIN not running\n", env.mock.contents());
    // Unknown name and unknown numeric id.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "NOPE.BIN" }));
    try std.testing.expectEqualStrings("kill: no such process: NOPE.BIN\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "9" }));
    try std.testing.expectEqualStrings("kill: no such process: 9\n", env.mock.contents());
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
        "syscalls: slots=64 implemented=21\n" ++
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
            "  20 sys_win_set_visible calls=0\n",
        env.mock.contents(),
    );
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
        "uaccess: valid=0 fault=1 recovered=0 copies=0 validation_faults=1\n",
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
    const long = "x" ** 100;
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
    try std.testing.expect(std.mem.indexOf(u8, out, "DipshitOS - AArch64 firmware-assisted kernel monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, BootMessages.messages()[2]) != null); // image_handle=2
    try std.testing.expect(std.mem.indexOf(u8, out, "Type 'help' before touching anything expensive.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "256 MiB") == null);
}

test "monitor: ls lists the ESP files deterministically" {
    esp.reset();
    try std.testing.expect(esp.add_esp_entry("KERNEL.BIN", 0x88b38, ""));
    try std.testing.expect(esp.add_dir_entry("EFI"));
    try std.testing.expect(esp.add_esp_entry("BOOTED.TXT", 0x29, "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n"));
    try std.testing.expect(esp.add_esp_entry("HELLO.TXT", 11, "hello world"));

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"ls"}));
    // Entries are listed in the window's order (the FAT root walk) —
    // deterministic per boot. The name column pads to the widest entry;
    // sizes are 0x + 16 hex digits.
    try std.testing.expectEqualStrings(
        "ls: esp=0x0000000000000004\n" ++
            "  KERNEL.BIN  0x0000000000088b38  [esp]\n" ++
            "  EFI         0x0000000000000000  [dir]\n" ++
            "  BOOTED.TXT  0x0000000000000029  [esp]\n" ++
            "  HELLO.TXT   0x000000000000000b  [esp]\n",
        env.mock.contents(),
    );
}

test "monitor: cat prints ESP content with honest errors" {
    esp.reset();
    try std.testing.expect(esp.add_esp_entry("BOOTED.TXT", 0x29, "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n"));
    try std.testing.expect(esp.add_esp_entry("KERNEL.BIN", 0x88b38, ""));
    try std.testing.expect(esp.add_dir_entry("EFI"));
    try std.testing.expect(esp.add_esp_entry("hello.txt", 11, "hello world"));

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "BOOTED.TXT" }));
    // The file already ends with a newline — cat prints it verbatim.
    try std.testing.expectEqualStrings("DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n", env.mock.contents());
    env.mock.reset();
    // Case-insensitive lookup.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "HELLO.TXT" }));
    try std.testing.expectEqualStrings("hello world\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "KERNEL.BIN" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "content not loaded") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "EFI" }));
    try std.testing.expectEqualStrings("cat: EFI: is a directory\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "NOPE.TXT" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "not found") != null);
}

test "monitor: ls/cat accept /-paths (honest no-volume errors in a test process)" {
    esp.reset();
    var env = TestEnv.init();
    var mon = env.monitor();
    // No FAT volume in a host test process: the path branches resolve
    // nothing and report it honestly (the success path is exercised live
    // by verify-live-fs.sh — `ls EFI/BOOT` + `cat EFI/BOOT/BOOTAA64.EFI`).
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "ls", "EFI/BOOT" }));
    try std.testing.expectEqualStrings("ls: EFI/BOOT: not found (no such directory on the FAT volume)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "EFI/BOOT/BOOTAA64.EFI" }));
    try std.testing.expectEqualStrings("cat: EFI/BOOT/BOOTAA64.EFI: not found (no such file on the FAT volume)\n", env.mock.contents());
    env.mock.reset();
    // The no-arg ls still lists the (empty) window.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"ls"}));
    try std.testing.expectEqualStrings("ls: esp=0x0000000000000000\nls: no files on the ESP (FAT volume unavailable or empty)\n", env.mock.contents());
}

test "monitor: mount is registered and reports honest transport errors in a test process" {
    esp.reset();
    var env = TestEnv.init();
    var mon = env.monitor();
    // No virtio-blk transport in a host test process (blk_ready=false): the
    // sector ops fail, so both volumes report the I/O result honestly (the
    // success path is the live gate).
    try std.testing.expectEqual(ExecError.machine_failed, exec(&mon, &.{ "mount", "data" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "mount: data: sector I/O failed") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "mount", "nvme0" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "unknown volume") != null);
    env.mock.reset();
    // The registry documents the command.
    try std.testing.expectEqualStrings("switch the active FAT volume (esp or data)", lookup("mount").?.help);
}

test "monitor: write joins arguments and honestly reports no disk in a test process" {
    esp.reset();
    var env = TestEnv.init();
    var mon = env.monitor();
    // In a host test process there is no disk (no FAT volume mounted); the
    // write must be refused honestly, never faked.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "write", "hello.txt", "hello", "world" }));
    try std.testing.expectEqualStrings(
        "write: hello.txt: not persisted - no disk (FAT volume unavailable)\n",
        env.mock.contents(),
    );
    // Bounds are validated before any persistence attempt.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "write", "bad/name.txt", "x" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "invalid file name") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "write", "verylongname.txt", "x" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "does not fit FAT 8.3") != null);
    env.mock.reset();
    // Empty content is allowed (a zero-length file); still refused honestly.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "write", "n.txt" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "content too long") == null);
}

test "monitor: exec is registered and refuses honestly without a disk" {
    esp.reset();
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("exec") != null);
    try std.testing.expectEqualStrings("load a user program from the ESP and enter it at EL0", lookup("exec").?.help);
    // No FAT volume in a host test process: refused honestly, never faked.
    // (The full load+spawn path is covered by exec.zig's own tests, which
    // mount the in-memory FAT fixture and retire the static user task.)
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"exec"}));
    try std.testing.expectEqualStrings("exec: no disk (ESP FAT volume unavailable)\n", env.mock.contents());
}
