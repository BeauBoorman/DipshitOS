//! Virelai Monitor command layer (Milestone 1.5, commands & personality).
//!
//! A reusable, host-testable command registry for the future interactive
//! monitor (`virelai>`). It depends only on the console abstraction
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
const osver = @import("osver.zig"); // M115f (#2465): the build-stamped OS version sysinfo reports
pub const alloc = @import("alloc.zig");
pub const console = @import("console.zig");
pub const esp_exec = @import("exec.zig"); // claim 6783: load a user program from the host share and enter it at EL0
pub const svclock = @import("svclock.zig"); // claim 9498 follow-on: per-service-domain locks — commands take the kernel lock plus their domain(s)
pub const syscall_mod = @import("syscall.zig"); // the strace seam (sets syscall_mod.strace_pid)
pub const exceptions = @import("exceptions.zig");
pub const gic = @import("gic.zig");
pub const handoff = @import("handoff.zig");
pub const mailbox = @import("mailbox.zig"); // claim 5965: per-process IPC rings behind `mbox`
pub const measure = @import("measure.zig"); // #2418 (M113b): the digest hex the v4 handoff view prints
pub const memmap = @import("memmap.zig");
pub const mmu = @import("mmu.zig"); // claim 5804: per-task TTBR0 roots + user-root inventory
pub const pci = @import("pci.zig");
pub const process = @import("process.zig"); // milestone four (claim 3848): the process registry behind `procs`
pub const scheduler = @import("scheduler.zig"); // claim 5275: tick-driven round-robin tasks
pub const syscall = @import("syscall.zig"); // claim 3594: syscall table + counters
pub const timer = @import("timer.zig");
pub const uaccess = @import("uaccess.zig"); // claim 6120: fault-safe copy-in/copy-out
pub const userspace = @import("userspace.zig"); // claim 5804: user-VA layout

pub const virtio_file = @import("virtio_file.zig"); // M34 HF1+HF2 (issues #735/#736): the host file channel behind `vf`
pub const csprng = @import("csprng.zig"); // milestone four (claim 2665): the seeded CSPRNG behind `random`
pub const clipboard = @import("clipboard.zig"); // milestone fourteen (claim 0169): the shared kernel clipboard behind `clip`
pub const terminal = @import("terminal.zig"); // M73f-2 (#1632): the tty seam behind `tty` (ADR 0020 D1 drop counters)
pub const virtio_net = @import("virtio_net.zig"); // milestone five card N1 (claim 1373): the net transport behind `net`/`netsend`
pub const virtio_gpu = @import("virtio_gpu.zig"); // milestone six card G1 (claim 6053): the gpu transport + framebuffer behind `screen`
pub const virtio_snd = @import("virtio_snd.zig"); // milestone fifteen card A1 (claim 6140): the virtio-snd transport behind `sound`
pub const virtio_vsock = @import("virtio_vsock.zig"); // M115a (issue #2460): the virtio-vsock transport behind `vsock`
const vsock_ctl = @import("vsock_ctl.zig"); // M115b (issue #2461, ADR 0056): the `vsock ctl` control-channel client
pub const road_pops = @import("road_pops.zig"); // milestone six card G3 (claim 1574): the Road Pops tee console behind `roadpops`
pub const fbtext = @import("text.zig"); // milestone six card G2 (claim 3194): framebuffer text rendering behind `text`
pub const xhci = @import("xhci.zig"); // milestone seven card I1 (claim 4272): the XHCI host-controller transport behind `usb`
pub const input = @import("input.zig"); // milestone seven card I3 (claim 6050): the keyboard/pointer event FIFO behind `input`
pub const usb_msc = @import("usb_msc.zig"); // M43 card U2 (issue #1033): BOT + minimal SCSI over the U1 bulk engine (`usb msc`)
pub const fat32_ro = @import("fat32_ro.zig"); // M70f F1 (issue #1458): the read-only FAT32 volume reader behind `usb vol|ls|cat`
pub const driving_award = @import("driving_award.zig"); // milestone six card G5 (claim 1543): Driving Award, the window manager behind `dui`
pub const wm_server = @import("wm_server.zig"); // M32 WMS2 (issue #622): the render-server register behind `wm`
pub const settings = @import("settings.zig"); // milestone eight card U8 (claim 2649): persistent settings engine
pub const font_metrics = @import("font_metrics.zig"); // M80i (#1725): the grid's zoom ladder, reported by `font`
pub const tombstone = @import("tombstone.zig"); // Arc5 issue #243: crash tombstone engine
pub const forensics = @import("forensics.zig"); // #1278: the last-words recorder behind `forensics`
pub const dns = @import("dns.zig"); // milestone twelve card N2 (claim 7566): DNS resolver
pub const events = @import("events.zig"); // milestone sixteen C3 (claim 0339): per-process event queue bound behind `resources`
pub const file_table = @import("file_table.zig"); // milestone sixteen C3 (claim 0339): per-process handle bound behind `resources`
// M100c (issue #2308, ADR 0050): `vf ls|cat`/`stat` on /disk read the VLFS
// volume through the same mount the file ABI routes `.disk` paths to.
const vlfs = @import("vlfs/vlfs.zig");
const vlfs_disk = @import("vlfs/disk.zig");
pub const serial_ring = @import("serial_ring.zig"); // Arc5 issue #243: serial output ring buffer behind `dmesg`
pub const smp = @import("smp.zig");
pub const trust = @import("trust.zig"); // M50 TS2 (#1136, ADR 0024 D4): the kernel-actor file policy for direct consumers
pub const secret = @import("secret.zig"); // M50 TS5 (#1139, ADR 0024 D8): the SECRETS.TXT store behind the `secrets` command

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
pub const category_order = [_]Category{
    .machine_identity,
    .memory_state,
    .tasks_processes,
    .storage,
    .networking,
    .graphics_input,
    .system,
};

pub fn category_name(cat: Category) []const u8 {
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
    /// Service-domain locks the command's handler touches, as an svclock
    /// bitmask (claim 9498 follow-on): exec() holds the kernel lock (the
    /// command's registry/lifecycle reads) plus these domains, in
    /// canonical order (kernel last).
    dom: u5 = 0,
    handler: *const fn (m: *Monitor, args: []const []const u8) ExecError,
};

/// Number of commands. The registry is built at runtime (not a const
/// table): see `ensure_registry`.
/// Number of commands. The registry is built at runtime (not a const
/// table): see `ensure_registry`. Milestone five card N1 (claim 1373)
/// grows it 32 -> 34 (`net` + `netsend`). Milestone seven card I1
/// (claim 4272) grows it 37 -> 38 (`usb`). Milestone seven card I3
/// (claim 6050) grows it 38 -> 39 (`input`). Milestone six card G5
/// (claim 1543) grows it 39 -> 40 (`dui`). Milestone eight card U6
/// (claim 8323) grows it 40 -> 42 (`welcome`, `tour`). Milestone eight card U7
/// (claim 2990) grows it 42 -> 43 (`sysinfo`). Milestone eight card U8
/// (claim 2649) grows it 43 -> 44 (`settings`). Milestone fourteen card S1
/// (claim 0169) grows it 44 -> 45 (`clip`). Milestone fifteen card A1
/// (claim 6140) grows it 45 -> 46 (`sound`). Milestone fifteen card A2
/// (claim 5877) grows it 46 -> 47 (`beep`). Milestone sixteen card C3
/// (claim 0339) grows it 47 -> 48 (`resources`). Milestone eighteen T5
/// (claim 0163) grows it 50 -> 51 (`color`). Milestone eighteen T16
/// (issue #419) grows it 51 -> 52 (`sh`). Milestone twenty-four K5
/// grows it 52 -> 53 (`calc`). Milestone twenty U1 (issue #307, claim
/// 5127) grows it 53 -> 54 (`font`). Milestone twenty-two D3 (issue #326)
/// grows it 54 -> 55 (`sym`). Milestone twenty-two D5 (issue #328)
/// grows it 55 -> 56 (`strace`). Milestone twenty-two D6 (issue #329)
/// grows it 56 -> 57 (`ps`). M115a (issue #2460) grows it 78 -> 79
/// (`vsock`).
pub const registry_count: usize = 79; // 78 + `vsock` (M115a #2460)

/// `sym <file>` reads at most this many bytes for on-disk symtab inspection
/// (M22 D3). ELF symbol tables live near the file tail; 64 KiB covers every
/// program the D1 loader can run that still fits its own staging contract.
pub const sym_file_max: usize = 64 * 1024;

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

pub fn ensure_registry() []const Command {
    if (!registry_ready) {
        registry_storage = .{
            .{ .name = "addrspaces", .help = "per-task user address spaces: per-task TTBR0, EL1-only kernel overlay, user-root contents", .usage = "addrspaces", .category = .memory_state, .handler = cmd_addrspaces },
            .{ .name = "beep", .help = "synthesize + play a sine through the virtio-snd PCM path ('beep <freq> <ms>' — reports the full control flow + submit/drain accounting)", .usage = "beep <freq> <ms>", .category = .system, .min_args = 2, .max_args = 2, .handler = cmd_beep },
            .{ .name = "about", .help = "explain this questionable system", .usage = "about", .category = .machine_identity, .handler = cmd_about },
            .{ .name = "beans", .help = "count beans, probably", .usage = "beans [count]", .category = .machine_identity, .max_args = 1, .handler = cmd_beans },
            .{ .name = "calc", .dom = svclock.dom_bit(.file), .help = "calculator utilities: 'calc history' shows saved calculation history from /data/calc_hst.txt", .usage = "calc [history]", .category = .system, .max_args = 1, .handler = cmd_calc },
            .{ .name = "cat", .dom = svclock.dom_bit(.file), .help = "print a file from the host share (by name or path)", .usage = "cat <file|path>", .category = .storage, .min_args = 1, .max_args = 1, .handler = cmd_cat },
            .{ .name = "clear", .help = "clean up the crime scene", .usage = "clear", .category = .system, .handler = cmd_clear },
            .{ .name = "font", .dom = svclock.dom_bit(.win), .help = "terminal font size: small 8x8 (default), medium 16x16, large 24x24 (M20-U1); the same rung zooms the bound terminal grid 7x13/8x16/10x21 (M80i)", .usage = "font [small|medium|large]", .category = .graphics_input, .min_args = 0, .max_args = 1, .handler = cmd_font },
            .{ .name = "compose", .help = "list available Alt+key compose sequences for accented characters", .usage = "compose", .category = .system, .handler = cmd_compose },
            .{ .name = "crash", .dom = svclock.dom_bit(.file), .help = "list recent crash tombstones from /data/crash/", .usage = "crash", .category = .system, .handler = cmd_crash },
            .{ .name = "clip", .help = "copy/paste the shared kernel clipboard ('clip <text...>' sets it, 'clip' prints it)", .usage = "clip [<text...>]", .category = .system, .handler = cmd_clip },
            .{ .name = "color", .help = "toggle ANSI terminal colors ('color on'/'color off'; 'color' shows current)", .usage = "color [on|off]", .category = .system, .max_args = 1, .handler = cmd_color },
            .{ .name = "echo", .help = "repeat your regrettable decisions", .usage = "echo <text...>", .category = .system, .handler = cmd_echo },
            .{ .name = "elephant", .help = "operational mascot diagnostics", .usage = "elephant", .category = .machine_identity, .handler = cmd_elephant },
            .{ .name = "sexiburger", .help = "operational mascot diagnostics (the Sexipus burger)", .usage = "sexiburger", .category = .machine_identity, .handler = cmd_sexiburger },
            .{ .name = "exec", .dom = svclock.dom_bit(.file), .help = "load a user program from the host share and enter it at EL0", .usage = "exec [-c<core>] [-u<uid>] [<file> [arg...]]", .category = .tasks_processes, .max_args = 2 + esp_exec.max_exec_args, .handler = cmd_exec },
            .{ .name = "fuzz", .dom = svclock.dom_bit(.file), .help = "seeded EL0 syscall sweep plus live HF-wire corpus (M70a #1466)", .usage = "fuzz <seed|roster>", .category = .tasks_processes, .min_args = 1, .max_args = 1, .handler = cmd_fuzz },
            .{ .name = "fault", .help = "trigger a synchronous exception (diagnostic)", .usage = "fault", .category = .memory_state, .handler = cmd_fault },
            .{ .name = "handoff", .help = "display boot-to-kernel ABI data", .usage = "handoff", .category = .memory_state, .handler = cmd_handoff },
            .{ .name = "help", .help = "grouped command catalog and per-command/per-topic help", .usage = "help [<command>|<topic>]", .category = .system, .max_args = 1, .handler = cmd_help },
            .{ .name = "hex", .help = "format an integer in hexadecimal", .usage = "hex <number>...", .category = .memory_state, .min_args = 1, .handler = cmd_hex },
            .{ .name = "input", .help = "keyboard/pointer event FIFO: armed state, occupancy, drop count, last keyboard + pointer events", .usage = "input", .category = .graphics_input, .handler = cmd_input },
            .{ .name = "kill", .help = "terminate a running process (kernel-owned lifetime)", .usage = "kill <pid|name>", .category = .tasks_processes, .min_args = 1, .max_args = 1, .handler = cmd_kill },
            .{ .name = "ls", .dom = svclock.dom_bit(.file), .help = "list files on the host share (or a directory by path); '-l' for long format (D15)", .usage = "ls [-l] [<dir>]", .category = .storage, .max_args = 2, .handler = cmd_ls },
            .{ .name = "mem", .help = "summarize the EFI memory map", .usage = "mem", .category = .memory_state, .handler = cmd_mem },
            .{ .name = "mbox", .dom = svclock.dom_bit(.ev), .help = "per-process IPC mailbox: pending messages and drain counters", .usage = "mbox [<pid>]", .category = .tasks_processes, .max_args = 1, .handler = cmd_mbox },
            .{ .name = "mount", .dom = svclock.dom_bit(.file), .help = "report the host-share file store (HF6: the FAT volumes are gone)", .usage = "mount", .category = .storage, .max_args = 1, .handler = cmd_mount },
            .{ .name = "net", .dom = svclock.dom_bit(.net), .help = "virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS + IPv6/NDP: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records; 'net ip6' shows the SLAAC address set; 'net ndp [<v6-addr>]' shows/resolves the NDP table; 'net ping6 <v6-addr>' sends an ICMPv6 echo request)", .usage = "net [recv|ip <addr>|arp [<addr>]|ping <addr>|udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]|dhcp|tcp [connect <addr> <port>|send <len>|recv|close|reset]|dns <host> [<server>]|ip6|ndp [<v6-addr>]|ping6 <v6-addr>]", .category = .networking, .max_args = 5, .handler = cmd_net },
            .{ .name = "netsend", .dom = svclock.dom_bit(.net), .help = "send a known Ethernet frame (bounded staging, TX + used-ring drain)", .usage = "netsend <bytes>", .category = .networking, .min_args = 1, .max_args = 1, .handler = cmd_netsend },
            .{ .name = "pages", .help = "physical page allocator pool", .usage = "pages [selftest]", .category = .memory_state, .max_args = 1, .handler = cmd_pages },
            .{ .name = "pci", .help = "enumerate PCI devices on the bus", .usage = "pci", .category = .memory_state, .handler = cmd_pci },
            .{ .name = "vsock", .help = "virtio-vsock transport (M115a/b): 'vsock' reports the arm state, 'vsock <port>' connects to the host listener and reports connected/refused/timeout, 'vsock ctl <verb>' runs one control-channel session", .usage = "vsock [<port>] | vsock ctl [badauth|replay|dup] <verb> [name]", .category = .networking, .max_args = 4, .handler = cmd_vsock },
            .{ .name = "procs", .help = "process registry: image, address space, lifecycle, exit status", .usage = "procs", .category = .tasks_processes, .max_args = 2, .handler = cmd_procs },
            .{ .name = "random", .help = "print n random bytes from the seeded CSPRNG (hex)", .usage = "random [n]", .category = .system, .max_args = 1, .handler = cmd_random },
            .{ .name = "resources", .help = "fixed-pool audit: scheduler tasks, process registry, windows, page-table carve-out, and per-process ring bounds", .usage = "resources", .category = .memory_state, .handler = cmd_resources },
            .{ .name = "reboot", .help = "restart the machine", .usage = "reboot", .category = .system, .handler = cmd_reboot },
            .{ .name = "repeat", .help = "repeat text, safely bounded", .usage = "repeat <count> <text...>", .category = .system, .min_args = 1, .handler = cmd_repeat },
            .{ .name = "sh", .help = "run a script file of shell commands ('sh <script>' executes it line by line; 64 lines max, 256 chars per line; '#' comments; 'exit' stops early)", .usage = "sh <script>", .category = .system, .min_args = 1, .max_args = 1, .handler = cmd_sh },
            .{ .name = "roadpops", .help = "Road Pops framebuffer console: armed/dirty/present counters (the boot terminal on the screen)", .usage = "roadpops", .category = .graphics_input, .handler = cmd_roadpops },
            .{ .name = "screen", .help = "virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)", .usage = "screen [fill <rrggbb>]", .category = .graphics_input, .max_args = 2, .handler = cmd_screen },
            .{ .name = "screenshot", .dom = svclock.dom_bit(.file), .help = "capture the current framebuffer (1280x720) and save as BMP to disk (G27)", .usage = "screenshot [<file>]", .category = .graphics_input, .max_args = 1, .handler = cmd_screenshot },
            .{ .name = "secrets", .dom = svclock.dom_bit(.file), .help = "list the secret store's key NAMES only (never values; ADR 0024 D8)", .usage = "secrets", .category = .system, .handler = cmd_secrets },
            .{ .name = "settings", .dom = svclock.dom_bit(.file) | svclock.dom_bit(.win), .help = "persistent configuration: `settings [list]`, `settings get <key>`, `settings set <key> <val>`, `settings reset`", .usage = "settings [list|get <key>|set <key> <val>|reset]", .category = .system, .max_args = 3, .handler = cmd_settings },
            .{ .name = "shortcuts", .help = "keyboard shortcut reference card (G29)", .usage = "shortcuts", .category = .system, .handler = cmd_shortcuts },
            .{ .name = "sound", .help = "virtio-snd transport: device DID, class, status, control-queue state, device-config counts (jacks/streams/channel-maps), re-arm; stream-state control: 'sound volume <0-100>' and 'sound mute <on|off>'", .usage = "sound [volume <0-100> | mute <on|off>]", .category = .system, .min_args = 0, .max_args = 2, .handler = cmd_sound },
            .{ .name = "text", .dom = svclock.dom_bit(.win), .help = "framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears; 'text putraw' skips the trailing newline; 'text fontdebug [on|off]' missing-glyph stats)", .usage = "text [put <string...>|putraw <string...>|clear|fontdebug [on|off]]", .category = .graphics_input, .min_args = 0, .max_args = 9, .handler = cmd_text },
            .{ .name = "shutdown", .help = "request power-off", .usage = "shutdown", .category = .system, .handler = cmd_shutdown },
            .{ .name = "ps", .help = "process status table: PID, name, state, memory footprint, CPU ticks, and executor task per live/exited process (M22 D6)", .usage = "ps", .category = .tasks_processes, .handler = cmd_ps },
            .{ .name = "spawn", .help = "spawn the lifecycle demo task", .usage = "spawn", .category = .tasks_processes, .handler = cmd_spawn },
            .{ .name = "sysinfo", .help = "comprehensive system and subsystem diagnostic snapshot", .usage = "sysinfo", .category = .machine_identity, .handler = cmd_sysinfo },
            .{ .name = "strace", .dom = svclock.dom_bit(.file), .help = "trace a program's syscalls: 'strace exec APP.BIN [args]' arms the tracer around an exec and prints one line per syscall; 'strace off' disarms", .usage = "strace exec <file> [args...] | off", .category = .tasks_processes, .handler = cmd_strace },
            .{ .name = "sym", .dom = svclock.dom_bit(.file), .help = "crash-report symbol table: 'sym' lists symbols loaded from the last ELF exec; 'sym <file>' parses an ELF's symtab from disk", .usage = "sym [<file>]", .category = .tasks_processes, .max_args = 1, .handler = cmd_sym },
            .{ .name = "syscalls", .help = "numbered syscall table and counters", .usage = "syscalls", .category = .tasks_processes, .handler = cmd_syscalls },
            .{ .name = "wm", .dom = svclock.dom_bit(.win) | svclock.dom_bit(.ev), .help = "M32 WMS2/WMS4/WMS5 render-server register: the registered WM server pid, present-sequence counter, presents, COMPOSITE_TICK count, SET_WINDOW chrome submissions + SET_STATE visibility/workspace calls, and the WMS5 input-seam fan-out counters (ptr_fan = raw pointer samples, win_mirror = registry mirrors, key_fan = raw keyboard samples; 'wm none' means the shell idle shim is compositing)", .usage = "wm", .category = .graphics_input, .handler = cmd_wm },
            .{ .name = "wnd", .dom = svclock.dom_bit(.file) | svclock.dom_bit(.ev), .help = "M32 WMS3 WM server: 'wnd' reports the registered WM server (pid, present seq/count, tick count; 'wnd: none' = shell-shim compositing); 'wnd start' launches the long-lived EL0 WND.BIN server (infrastructure — not in APPS.TXT; the default VM stays shim-only)", .usage = "wnd [start]", .category = .graphics_input, .max_args = 1, .handler = cmd_wnd },
            .{ .name = "tabwm", .dom = svclock.dom_bit(.file) | svclock.dom_bit(.ev), .help = "M39 TWM1 WM server: 'tabwm' reports the registered WM server; 'tabwm start' launches the long-lived EL0 TABWM.BIN server (left-sidebar browser-style window manager)", .usage = "tabwm [start]", .category = .graphics_input, .max_args = 1, .handler = cmd_tabwm },
            .{ .name = "tasks", .help = "tick-driven task scheduler status", .usage = "tasks", .category = .tasks_processes, .handler = cmd_tasks },
            .{ .name = "smp", .help = "multiprocessor topology, online CPU cores, and per-core task state", .usage = "smp", .category = .tasks_processes, .handler = cmd_smp },
            .{ .name = "type", .help = "echo stdin (the pipe source) to stdout — the right half of `a | type`", .usage = "type", .category = .system, .handler = cmd_type },
            .{ .name = "tty", .help = "terminal drop counters (ADR 0020 D1): out_dropped/in_dropped per bound tty ('tty' prints one line per terminal)", .usage = "tty", .category = .system, .handler = cmd_tty },
            .{ .name = "timer", .help = "interrupt controller + timer status", .usage = "timer", .category = .memory_state, .handler = cmd_timer },
            .{ .name = "forensics", .help = "last-words recorder: on|off|dump|reset (off by default)", .usage = "forensics [on|off|dump|reset]", .category = .system, .max_args = 1, .handler = cmd_forensics },
            .{ .name = "tour", .help = "guided tour of the system for new users", .usage = "tour", .category = .machine_identity, .handler = cmd_welcome },
            .{ .name = "uaccess", .help = "user-memory copy diagnostics (valid, fault, recovery)", .usage = "uaccess", .category = .memory_state, .handler = cmd_uaccess },
            .{ .name = "usb", .help = "XHCI host controller: `usb` transport report, `usb devices` enumerated devices, `usb report` last HID report, `usb bulk [probe ...]` bulk engine (U1), `usb msc [probe] [lba]` mass-storage BOT/SCSI probe (U2), `usb vol` MBR partition + FAT32 volume enumeration, `usb ls <vol>[/<dir>]` volume directory listing, `usb cat <vol>/<path> [<max>]` read-only file read (full byte count + FNV-1a 32 of every byte) (M70f F1), `usb rescan` polled lifecycle rescan (U4), `usb detach [slot]` administrative detach (U4)", .usage = "usb [devices|report|bulk [probe ...]|msc [probe] [lba]|vol|ls <vol>[/<dir>]|cat <vol>/<path> [<max>]|rescan|detach [slot]]", .category = .graphics_input, .handler = cmd_usb },
            .{ .name = "uname", .help = "compact system identity", .usage = "uname", .category = .machine_identity, .handler = cmd_uname },
            .{ .name = "version", .help = "display build information", .usage = "version", .category = .machine_identity, .handler = cmd_version },
            .{ .name = "vf", .dom = svclock.dom_bit(.file), .help = "host file channel (M34): 'vf ls/cat/mkdir/rm/mv <path>' read + mutate a macOS share over custom-virtio queue 5; 'vf open/close/write/truncate/fsync <h>' manage write handles (8-slot host cursor table)", .usage = "vf [ls [<path>]|cat <path>|mkdir <path>|rm <path>|mv <from> <to>|open <path> [append]|close <h>|write <h> <n>|truncate <h> <n>|fsync <h>]", .category = .storage, .max_args = 4, .handler = cmd_vf },
            .{ .name = "welcome", .help = "guided tour of the system for new users", .usage = "welcome", .category = .machine_identity, .handler = cmd_welcome },
            .{ .name = "dui", .dom = svclock.dom_bit(.win), .help = "Driving Award window manager: registry (with owner pids), z-order, focus, hit-testing ('dui focus <n>' focuses; 'dui raise <n>' raises; 'dui lower <n>' lowers to back; 'dui move <n> <x> <y>' moves a user window; 'dui close <n>' releases a user window; 'dui list <pid>' filters by owner; 'dui hit <x> <y>' hit-tests; 'dui cycle' cycles focus like Alt+Tab; 'dui tile <n>' toggles a user window floating/tiled (M21 W1); 'dui master' swaps master/detail (M21 W2))", .usage = "dui [focus <n>|raise <n>|lower <n>|move <n> <x> <y>|close <n>|list <pid>|hit <x> <y>|cycle|tile <n>|master]", .category = .graphics_input, .max_args = 4, .handler = cmd_dui },
            .{ .name = "write", .dom = svclock.dom_bit(.file), .help = "write text to a file on the host share", .usage = "write <file> <text...>", .category = .storage, .min_args = 1, .handler = cmd_write },
            .{ .name = "mktemp", .dom = svclock.dom_bit(.file), .help = "create a temporary file (empty, unique name)", .usage = "mktemp [prefix]", .category = .storage, .max_args = 1, .handler = cmd_mktemp },
            .{ .name = "stat", .dom = svclock.dom_bit(.file), .help = "file metadata: size, type, cluster, path (D8)", .usage = "stat <file|path>", .category = .storage, .min_args = 1, .max_args = 1, .handler = cmd_stat },
            .{ .name = "du", .dom = svclock.dom_bit(.file), .help = "recursive directory disk usage (M25 F4)", .usage = "du [<path>]", .category = .storage, .max_args = 1, .handler = cmd_du },
            .{ .name = "find", .dom = svclock.dom_bit(.file), .help = "recursive file search with glob patterns ('find / -name \"*.BIN\"' — bounded 3 levels, 256 results)", .usage = "find <dir> -name <pattern>", .category = .storage, .min_args = 3, .max_args = 3, .handler = cmd_find },
            .{ .name = "dmesg", .help = "system log viewer: last bytes of serial output (D12)", .usage = "dmesg", .category = .system, .handler = cmd_dmesg },
            .{ .name = "time", .help = "command timing: measure elapsed ticks and wall-clock time (D13)", .usage = "time <command> [args...]", .category = .system, .min_args = 1, .handler = cmd_time },
            .{ .name = "which", .dom = svclock.dom_bit(.file), .help = "locate a command: shell builtin, monitor command, or host-share application (D16; HF6: the ESP is gone)", .usage = "which <name>", .category = .system, .min_args = 1, .max_args = 1, .handler = cmd_which },
            .{ .name = "inventory", .dom = svclock.dom_bit(.file), .help = "list all installed applications from APPS.TXT with sizes and types (D16)", .usage = "inventory", .category = .storage, .handler = cmd_inventory },
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

/// Execute an already-tokenized command line: `argv[0]` is the command
/// name, the rest are its arguments. Tokenization and line editing belong
/// to the later Console & Shell Core stream.
pub fn exec(m: *Monitor, argv: []const []const u8) ExecError {
    if (argv.len == 0) {
        // ADR 0008 D3 shape 2: a dispatch-level refusal wears the `error:`
        // prefix like any other. An empty line is not an unknown VERB (there
        // is no verb to quote), so shape 3 would be a lie.
        err_line(m, "no command given; type 'help' for a list of commands");
        return .usage;
    }
    if (argv.len > max_args_limit + 1) {
        err_line(m, too_many_arguments_message);
        return .usage;
    }
    const cmd = lookup(argv[0]) orelse {
        // ADR 0008 D3 shape 3: unknown verb -> `unknown command '<x>' --
        // try 'help'` (the two hyphens are the byte-safe rendering of the
        // ADR's typographic em dash — the framebuffer text layer renders
        // only 0x20..0x7e, so a multi-byte dash would render as blanks).
        m.console.puts("unknown command '");
        m.console.puts(argv[0]);
        m.console.print_line("' -- try 'help'");
        return .unknown_command;
    };
    const args = argv[1..];
    if (args.len < cmd.min_args or args.len > cmd.max_args) {
        print_usage(m, cmd);
        return .usage;
    }
    // Service-domain locks (claim 9498 follow-on): every EL1h command
    // holds the kernel lock (registry/lifecycle state) plus the domain
    // lock(s) of the subsystems it touches — in canonical order, kernel
    // last — so a same-domain core-1 syscall serializes with the command
    // while unrelated-domain syscalls proceed. The holds are IRQ-masked
    // (a command can never be preempted mid-hold). Nested commands
    // (`time`/`sh` re-enter exec) skip re-acquisition via `held_set`.
    const doms = svclock.dom_bit(.kernel) | cmd.dom;
    const taken = if (!svclock.held_set(doms)) svclock.acquire_missing(doms) else 0;
    defer if (taken != 0) svclock.release_set(taken);
    return cmd.handler(m, args);
}

// ---------------------------------------------------------------------------
// Tab completion (ADR 0008 D2)
// ---------------------------------------------------------------------------

/// Given the line being edited and the cursor, return the suffix to insert
/// (a long-lived slice of a string literal), or null when there is no unique
/// completion. The first token completes against command names; a later
/// token completes against the leading command's fixed sub-verb vocabulary.
pub fn complete(line: []const u8, cursor: usize) ?[]const u8 {
    if (cursor > line.len) return null;
    var start = cursor;
    while (start > 0 and line[start - 1] != ' ' and line[start - 1] != '\t') start -= 1;
    const prefix = line[start..cursor];
    if (prefix.len == 0) return null;
    // The first token (the command name) has only whitespace before it.
    var first = true;
    var i: usize = 0;
    while (i < start) : (i += 1) {
        if (line[i] != ' ' and line[i] != '\t') {
            first = false;
            break;
        }
    }
    if (first) return complete_command(prefix);
    // Sub-verb completion: find the leading command (the first token).
    var cmd_start: usize = 0;
    while (cmd_start < line.len and (line[cmd_start] == ' ' or line[cmd_start] == '\t')) cmd_start += 1;
    var cmd_end = cmd_start;
    while (cmd_end < line.len and line[cmd_end] != ' ' and line[cmd_end] != '\t') cmd_end += 1;
    if (cmd_end <= cmd_start) return null;
    return sub_verb_complete(line[cmd_start..cmd_end], prefix);
}

fn complete_command(prefix: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (ensure_registry()) |*cmd| {
        if (std.mem.startsWith(u8, cmd.name, prefix)) {
            if (found != null) return null; // ambiguous
            found = cmd.name;
        }
    }
    return if (found) |name| name[prefix.len..] else null;
}

fn match_one(prefix: []const u8, verbs: []const []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (verbs) |v| {
        if (std.mem.startsWith(u8, v, prefix)) {
            if (found != null) return null; // ambiguous
            found = v;
        }
    }
    return if (found) |v| v[prefix.len..] else null;
}

fn sub_verb_complete(cmd: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, cmd, "net"))
        return match_one(prefix, &.{ "recv", "ip", "arp", "ping", "udp", "udp6", "dhcp", "tcp", "dns", "ip6", "ndp", "ping6", "status", "route", "log" });
    if (std.mem.eql(u8, cmd, "dui"))
        return match_one(prefix, &.{ "focus", "raise", "move", "close", "list", "hit", "cycle" });
    if (std.mem.eql(u8, cmd, "usb"))
        return match_one(prefix, &.{ "devices", "report" });
    if (std.mem.eql(u8, cmd, "screen"))
        return match_one(prefix, &.{"fill"});
    if (std.mem.eql(u8, cmd, "text"))
        return match_one(prefix, &.{ "put", "clear" });
    if (std.mem.eql(u8, cmd, "mount"))
        return match_one(prefix, &.{ "esp", "data" });
    if (std.mem.eql(u8, cmd, "help"))
        return match_one(prefix, &.{ "networking", "windows", "storage", "graphics" });
    return null;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// The one dispatch-level too-many-tokens message, shared by the shell's
/// tokenizer refusal and `exec`'s own guard so the two can never drift.
pub const too_many_arguments_message = "too many arguments (max 17 tokens)";

/// ADR 0008 D3 shape 1: misuse -> `usage: <cmd> <args>` PLUS a one-line
/// hint. The hint is the registry's own blurb for the command, so there is
/// exactly one source for it and no per-handler copy can drift. Sub-verb
/// misuse reuses the command's full usage, so a fourth shape can never slip
/// in on a bad invocation.
fn print_usage(m: *Monitor, cmd: *const Command) void {
    m.console.puts("usage: ");
    m.console.puts(cmd.usage);
    m.console.puts("\n");
    m.console.puts(cmd.help);
    m.console.puts("\n");
}

/// ADR 0008 D3 shape 2: failure -> `error: <actionable message>`. The
/// prefix only; the caller appends the actionable text.
fn err_prefix(m: *Monitor) void {
    m.console.puts("error: ");
}

/// ADR 0008 D3 shape 2 for a fixed message: `error: <text>` on one line.
pub fn err_line(m: *Monitor, text: []const u8) void {
    err_prefix(m);
    m.console.print_line(text);
}

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

pub fn parseSignedInt(text: []const u8) error{ Empty, InvalidDigit, Overflow }!i64 {
    if (text.len == 0) return error.Empty;
    if (text[0] == '-') {
        const u = try parseInt(text[1..]);
        if (u > @as(u64, @intCast(std.math.maxInt(i64))) + 1) return error.Overflow;
        return -@as(i64, @intCast(u));
    }
    const u = try parseInt(text);
    if (u > @as(u64, @intCast(std.math.maxInt(i64)))) return error.Overflow;
    return @as(i64, @intCast(u));
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
            err_prefix(m);
            m.console.puts(verb);
            m.console.print_line(": not implemented - no proven post-ExitBootServices machine-control mechanism; terminal WFE loop continues");
            return .not_implemented;
        },
        .failed => {
            err_prefix(m);
            m.console.puts(verb);
            m.console.print_line(": failed");
            return .machine_failed;
        },
    }
}

// ---------------------------------------------------------------------------
// Identity and inspection commands
// ---------------------------------------------------------------------------

/// `help <topic>` pages (ADR 0008 D1, M27 G28 #471). Bodies are returned as string
/// literals from code (PC-relative at any load base — the claim-0015
/// lesson), never stored in a const table of pointers. Topics are
/// non-command keywords; `syscalls` is a command, so its `help <cmd>` detail
/// is the syscall page rather than a shadowed topic.
fn topic_body(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "networking") or std.mem.eql(u8, name, "network")) {
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
            "  `dui` inspects/focuses/raises/moves/closes; EL0 opens windows through ADR 0007\n" ++
            "  slots 12-20 (open/fill/present/close/move/raise/get/query/set_visible). Windows\n" ++
            "  are process-owned and auto-close when their process exits.\n";
    }
    if (std.mem.eql(u8, name, "storage")) {
        // M34 HF6 (issue #740): the FAT volumes are gone — the macOS host
        // share (custom-virtio queue 5, --cvc-file) is the only store.
        return "storage\n" ++
            "  The macOS host share (custom-virtio queue 5, --cvc-file) is the only\n" ++
            "  store. `vf ls/cat/mkdir/rm/mv` + `vf open/close/write/truncate/fsync`\n" ++
            "  read and mutate it; writes persist on the host disk across reboot.\n";
    }
    if (std.mem.eql(u8, name, "files")) {
        return "files\n" ++
            "  The host share filesystem: `ls`, `cat`, `write`, `find`, `stat`,\n" ++
            "  `du`, and `inventory`. Persistent file operations on the --cvc-file share.\n";
    }
    if (std.mem.eql(u8, name, "graphics")) {
        return "graphics\n" ++
            "  virtio-gpu (DID 0x1050) framebuffer: `screen` reports/fills the scanout,\n" ++
            "  `text` renders the 8x8 font, Road Pops is the on-screen terminal, and Driving\n" ++
            "  Award composites windows over it. 1280x720 B8G8R8X8, 2D blits only.\n";
    }
    if (std.mem.eql(u8, name, "editor")) {
        return "editor\n" ++
            "  Text editing in a TABWM tab: GOEDIT.ELF, and NOTE.ELF -- the dock's\n" ++
            "  editor. Both load a share file and save on Ctrl+S; printable keys insert,\n" ++
            "  backspace/delete remove, Return breaks the line, and NOTE.ELF also takes\n" ++
            "  the arrow keys and saves on close when dirty.\n";
    }
    if (std.mem.eql(u8, name, "calc")) {
        return "calc\n" ++
            "  64-bit integer calculator (GOCALC.ELF): digits, + - * /, equals, clear.\n" ++
            "  `calc history` prints saved calculation history from calc_hst.txt on the host share.\n";
    }
    if (std.mem.eql(u8, name, "system")) {
        return "system\n" ++
            "  Machine management and diagnostic commands: `sysinfo`, `uname`, `version`,\n" ++
            "  `settings` (theme, prompt, font, scrollback), `shutdown`, `reboot`,\n" ++
            "  `dmesg`, `time`, and crash tombstone viewing with `crash`.\n";
    }
    if (std.mem.eql(u8, name, "terminal")) {
        // M80k (#1727): the hygiene chords. They are kernel chrome, not
        // app behaviour — intercepted in input.zig before the tty queue,
        // so they work for ANY tty-bound window and never reach the app as
        // bytes. The clear/reset operations are the ED 3 / DECSTR / RIS
        // seams the parser itself uses, not a second implementation.
        return "terminal\n" ++
            "  A tty-bound window (GOTERM.ELF, GOSH) paints a grid with scrollback.\n" ++
            "  Chrome chords — consumed by the kernel, never typed into the app:\n" ++
            "    Ctrl+Shift+C / V      copy the selection / paste the clipboard\n" ++
            "    Ctrl+Shift+F           open the search bar (Esc closes it)\n" ++
            "    Ctrl+Shift+K           clear the scrollback (ED 3), snap to the tail\n" ++
            "    Ctrl+Shift+R           soft reset: styles and modes, grid intact\n" ++
            "    Ctrl+Shift+Alt+R       full reset (RIS): the grid goes too\n" ++
            "  Scrolling the view: PageUp/PageDown, Shift+Up/Down, Shift+Home/End.\n" ++
            "  The cure for a grid wedged by an app that died mid-escape: the two\n" ++
            "  reset chords, or just close the tab.\n";
    }
    if (std.mem.eql(u8, name, "shortcuts")) {
        return "shortcuts\n" ++
            "  Global: Ctrl+Shift+A (About), Ctrl+Shift+/ (Shortcuts), Alt+Tab (Switch window),\n" ++
            "  Alt+F4 (Close window), F11 (Fullscreen/Tile), Ctrl+Alt+Del (Reboot).\n" ++
            "  Navigation: Tab / Shift+Tab (Focus control), Enter/Space (Activate), Esc (Dismiss).\n" ++
            "  Editing: Ctrl+C (Copy), Ctrl+X (Cut), Ctrl+V (Paste), Ctrl+Z (Undo), Ctrl+S (Save).\n" ++
            "  Run `shortcuts` command for full list.\n";
    }
    if (std.mem.eql(u8, name, "dev") or std.mem.eql(u8, name, "diag")) {
        return "dev / diag\n" ++
            "  Developer tools and diagnostics: `strace` (syscall tracer), `sym` (symbol table),\n" ++
            "  `disas` (AArch64 disassembler), `asm` (assembler), `ps` (process table),\n" ++
            "  `crash` (tombstone viewer), `resources` (pool audit), `which` / `inventory`.\n";
    }
    return null;
}

fn cmd_help(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1) {
        if (std.mem.eql(u8, args[0], "--all")) {
            m.console.print_line("all monitor commands:");
            const reg = ensure_registry();
            for (reg) |cmd| {
                m.console.puts("  ");
                m.console.puts(cmd.name);
                m.console.puts(" - ");
                m.console.puts(cmd.help);
                m.console.puts("\n    usage: ");
                m.console.puts(cmd.usage);
                m.console.puts("\n");
            }
            return .none;
        }
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
        err_prefix(m);
        m.console.puts("no such command or topic: ");
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
    m.console.print_line("VirelaiOS is a from-scratch AArch64 operating system.");
    m.console.print_line("Written in freestanding Zig: no libc, no POSIX.");
    m.console.print_line("Hosted under Apple Virtualization.framework on Apple silicon.");
    m.console.print_line("Core subsystems: identity-map MMU, GICv3 PPI timer, round-robin");
    m.console.print_line("scheduler, per-task TTBR0 address spaces, EL0 processes & SVC (ADR 0007),");
    m.console.print_line("ESP/DATA FAT32 storage, virtio-net (ARP/ICMP/UDP/DHCP/TCP), Driving Award");
    m.console.print_line("window compositor + Road Pops terminal, and Apple xHCI USB HID input.");
    m.console.print_line("Type 'help' for the grouped command catalog, or 'welcome' for a tour.");
    return .none;
}

fn cmd_welcome(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("Welcome to VirelaiOS! Here is a quick tour to get you oriented:");
    m.console.print_line("  1. Discovery: Type 'help' to see grouped commands, or 'help <cmd>' / 'help <topic>' for details.");
    m.console.print_line("  2. System Info: Type 'version', 'uname', or 'about' for architectural details.");
    m.console.print_line("  3. Tasks & Procs: Type 'procs' to view active processes or 'tasks' for scheduler states.");
    m.console.print_line("  4. Storage: Type 'ls' and 'cat <file>' to view files on the host share (--cvc-file).");
    m.console.print_line("  5. Windows & Graphics: Type 'win' to inspect window registry and z-order; 'dui cycle' to cycle focus.");
    m.console.print_line("  6. Networking: Type 'net' for device status, 'net ping <ip>' or 'net dhcp' to configure.");
    m.console.print_line("  7. Documentation: Architecture, decisions, and hardware contracts live in docs/.");
    m.console.print_line("Have fun and break things responsibly.");
    return .none;
}

fn cmd_sysinfo(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const h = &m.state.handoff;
    const map_summary = memmap.summarize(m.state.map);
    const p_stats = alloc.stats();
    const sched_rep = scheduler.stats();
    const win_armed = driving_award.armed();
    const rp_rep = road_pops.report();
    const in_rep = input.report();

    m.console.print_line("sysinfo: VirelaiOS AArch64 support snapshot");

    // System & Handoff
    m.console.puts("  system:     kernel=virelai-kernel handoff=v2 status=");
    if (handoff.validate(h) == .none) {
        m.console.print_line("valid");
    } else {
        m.console.print_line("invalid");
    }

    // OS identity — M115f (#2465): the build-stamped version label
    // (-Dos-version). An applied update carries a new label, so the
    // version line is the in-guest proof the base image changed.
    m.console.puts("  os:         version=");
    m.console.print_line(osver.label);

    // CPU & Timer
    m.console.puts("  cpu:        arch=aarch64 timer_armed=");
    m.console.puts(if (timer.armed()) "1" else "0");
    m.console.puts(" gic=");
    m.console.puts(gic.kind_name());
    m.console.puts(" ticks=");
    m.console.print_u64(timer.ticks);
    m.console.puts(" irq=");
    m.console.print_u64(timer.irq_ticks);
    m.console.puts("\n");

    // Memory & Allocator
    m.console.puts("  memory:     descriptors=");
    m.console.print_u64(m.state.map.count);
    m.console.puts(" usable=");
    m.console.print_hex(map_summary.usable_pages * memmap.page_size);
    m.console.puts(" (");
    m.console.print_hex(map_summary.usable_pages);
    m.console.puts(" pages)\n");

    m.console.puts("  allocator:  armed=");
    m.console.puts(if (p_stats.armed) "1" else "0");
    m.console.puts(" total=");
    m.console.print_hex(p_stats.total_pages);
    m.console.puts(" free=");
    m.console.print_hex(p_stats.free_pages);
    m.console.puts(" excluded=");
    m.console.print_hex(p_stats.excluded_pages);
    m.console.puts(" regions=");
    m.console.print_hex(@intCast(p_stats.region_count));
    m.console.puts("\n");

    // Tasks & Processes
    m.console.puts("  scheduler:  enabled=");
    m.console.puts(if (sched_rep.enabled) "1" else "0");
    m.console.puts(" tasks=");
    m.console.print_u64(sched_rep.count);
    m.console.puts("/");
    m.console.print_u64(scheduler.max_tasks);
    m.console.puts(" switches=");
    m.console.print_u64(sched_rep.switches);
    m.console.puts("\n");

    m.console.puts("  processes:  active=");
    m.console.print_u64(@intCast(process.count()));
    m.console.puts("/");
    m.console.print_u64(process.max_processes);
    m.console.puts("\n");

    // Storage — M34 HF6 (issue #740): the FAT volumes are gone; the host
    // share (--cvc-file) is the only file store.
    m.console.puts("  storage:    host_share=");
    m.console.puts(if (virtio_file.available()) "armed" else "absent");
    if (virtio_file.available()) {
        var lr = virtio_file.ListResult{};
        if (virtio_file.list("", &lr) == virtio_file.st_ok) {
            m.console.puts(" files=");
            m.console.print_u64(@intCast(lr.count));
        }
    }
    m.console.puts("\n");

    // Network
    m.console.puts("  network:    virtio-net=");
    m.console.puts(if (virtio_net.net_ready) "armed" else "unarmed");
    if (virtio_net.net_ready) {
        m.console.puts(" mac=");
        m.console.puts(&virtio_net.net_mac_text);
        m.console.puts(" ip=");
        var ipbuf: [15]u8 = undefined;
        const n = virtio_net.arp.format_ip(virtio_net.arp.own_ip, &ipbuf);
        m.console.puts(ipbuf[0..n]);
    }
    m.console.puts("\n");

    // Graphics & Windows
    m.console.puts("  graphics:   gpu=");
    m.console.puts(if (virtio_gpu.gpu_ready) "armed" else "unarmed");
    m.console.puts(" roadpops=");
    m.console.puts(if (rp_rep.armed) "armed" else "unarmed");
    m.console.puts(" windows=");
    if (win_armed) {
        m.console.print_u64(driving_award.count());
        m.console.puts(" focused=");
        m.console.print_u64(driving_award.focused_window_id());
    } else {
        m.console.puts("unarmed");
    }
    m.console.puts("\n");

    // Input
    m.console.puts("  input:      xhci=");
    m.console.puts(if (xhci.xhci_ready) "armed" else "unarmed");
    m.console.puts(" devices=");
    m.console.print_u64(xhci.enum_count);
    m.console.puts(" fifo=");
    m.console.puts(if (in_rep.armed) "armed" else "unarmed");
    m.console.puts("\n");

    // Uptime
    m.console.puts("  uptime:     ticks=");
    m.console.print_u64(timer.ticks);
    m.console.puts("\n");

    return .none;
}

fn cmd_version(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("virelai-kernel");
    m.console.print_line("milestone-two kernel proper (ADR 0004)");
    m.console.print_line("handoff ABI v2");
    m.console.print_line("build label: m1.5 commands & personality (mock console)");
    return .none;
}

fn cmd_uname(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("VirelaiOS aarch64");
    m.console.print_line("freestanding kernel; no POSIX compatibility");
    return .none;
}

fn cmd_handoff(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const h = &m.state.handoff;
    m.console.print_line("handoff v4");
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
        .{ .label = "boot_epoch", .value = h.boot_epoch_secs },
        .{ .label = "measured_ok", .value = h.measured_ok },
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
    // v4 (#2418, ADR 0054): the loader's boot-stage digests — the receipt
    // the kernel published at boot is these exact values.
    var digest_hex: [64]u8 = undefined;
    _ = measure.hex_digest(&digest_hex, &h.measured_loader);
    m.console.puts("  loader_sha256 ");
    m.console.puts(&digest_hex);
    m.console.puts("\n");
    _ = measure.hex_digest(&digest_hex, &h.measured_kernel);
    m.console.puts("  kernel_sha256 ");
    m.console.puts(&digest_hex);
    m.console.puts("\n");
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
/// M22 D15 (issue #338): `ls [-l] [<dir>]` — list files with optional
/// long listing format showing type, permissions, owner, size, and name.
fn cmd_ls(m: *Monitor, args: []const []const u8) ExecError {
    var long_mode = false;
    var path_arg: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-l")) {
            long_mode = true;
        } else {
            path_arg = arg;
        }
    }
    if (path_arg) |path| return cmd_ls_path_long(m, path, long_mode);
    // Root listing — M34 HF6 (issue #740): the share is the only store.
    var res: virtio_file.ListResult = .{};
    const st = virtio_file.list("", &res);
    if (st != virtio_file.st_ok) {
        m.console.print_line("ls: no host file channel (boot the runner with --cvc-file <host-dir>)");
        return .none;
    }
    m.console.puts("ls: host=");
    m.console.print_hex(@intCast(res.count));
    m.console.puts("\n");
    if (res.count == 0) {
        m.console.print_line("ls: no files on the host share");
        return .none;
    }
    if (long_mode) {
        for (res.entries[0..res.count]) |e| {
            print_ls_long_entry(m, e.name[0..e.name_len], e.size, e.type == virtio_file.dir_type_dir);
        }
    } else {
        var width: usize = 0;
        for (res.entries[0..res.count]) |e| width = @max(width, e.name_len);
        for (res.entries[0..res.count]) |e| {
            m.console.puts("  ");
            m.console.puts(e.name[0..e.name_len]);
            var pad: usize = e.name_len;
            while (pad < width) : (pad += 1) m.console.putc(' ');
            m.console.puts("  ");
            m.console.print_hex(e.size);
            m.console.puts("  [");
            m.console.puts(if (e.type == virtio_file.dir_type_dir) "dir" else "host");
            m.console.puts("]\n");
        }
    }
    return .none;
}

/// List a directory by `/`-path, straight from the FAT volume (the window
/// only snapshots the root). Same row format as the root listing, with a
/// path-aware header. Honest diagnostics distinguish a file ("is a file")
/// from an absent/non-directory path ("not found").
fn cmd_ls_path(m: *Monitor, path: []const u8) ExecError {
    return cmd_ls_path_long(m, path, false);
}

fn cmd_ls_path_long(m: *Monitor, path: []const u8, long_mode: bool) ExecError {
    // M34 HF6 (issue #740): LIST the share directory through the channel.
    var res: virtio_file.ListResult = .{};
    const st = virtio_file.list(path, &res);
    if (st != virtio_file.st_ok) {
        err_prefix(m);
        m.console.puts(path);
        if (st == virtio_file.st_not_found) {
            m.console.print_line(": not found (no such directory on the host share)");
        } else {
            m.console.puts(": ");
            m.console.print_line(vf_status_text(st));
        }
        return .invalid_argument;
    }
    const n = res.count;
    m.console.puts("ls: ");
    m.console.puts(path);
    m.console.puts(" entries=");
    m.console.print_hex(@intCast(n));
    m.console.puts("\n");
    if (long_mode) {
        for (res.entries[0..n]) |e| {
            print_ls_long_entry(m, e.name[0..e.name_len], e.size, e.type == virtio_file.dir_type_dir);
        }
    } else {
        var width: usize = 0;
        for (res.entries[0..n]) |e| width = @max(width, e.name_len);
        for (res.entries[0..n]) |e| {
            m.console.puts("  ");
            m.console.puts(e.name[0..e.name_len]);
            var pad: usize = e.name_len;
            while (pad < width) : (pad += 1) m.console.putc(' ');
            m.console.puts("  ");
            m.console.print_hex(e.size);
            m.console.puts("  [");
            m.console.puts(if (e.type == virtio_file.dir_type_dir) "dir" else "host");
            m.console.puts("]\n");
        }
    }
    return .none;
}

/// M22 D15: print one entry in `ls -l` long format.
fn print_ls_long_entry(m: *Monitor, name: []const u8, size: u64, is_dir: bool) void {
    // Type + permissions
    m.console.putc(if (is_dir) 'd' else '-');
    if (is_dir) {
        m.console.print_line("rwx     1  root");
    } else {
        m.console.print_line("rw-     1  root");
    }
    // Indent + size + name
    m.console.puts("        ");
    m.console.print_u64(size);
    var pad_buf: [20]u8 = undefined;
    var sz_digits: usize = 0;
    var v = size;
    if (v == 0) {
        pad_buf[0] = '0';
        sz_digits = 1;
    }
    while (v > 0) : (v /= 10) {
        pad_buf[sz_digits] = @intCast('0' + v % 10);
        sz_digits += 1;
    }
    // Pad to 8 chars
    var i: usize = sz_digits;
    while (i < 8) : (i += 1) m.console.putc(' ');
    m.console.puts("  ");
    m.console.print_line(name);
}

/// Switch the active FAT volume (milestone four card 2): `mount esp`
/// re-mounts the EFI System Partition by its GPT type GUID; `mount data`
/// mounts the second FAT32 partition (the general-filesystem volume) by
/// its GUID. The window re-snapshots the newly active volume's root,
/// M34 HF6 (issue #740): the FAT volumes are GONE — `mount` reports the
/// host share's state (the command row stays for the storage-category
/// surface; there is nothing to switch).
fn cmd_mount(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    if (!virtio_file.available()) {
        m.console.print_line("mount: no host file channel (boot the runner with --cvc-file <host-dir>)");
        return .none;
    }
    var res: virtio_file.ListResult = .{};
    const st = virtio_file.list("", &res);
    m.console.puts("mount: host share armed files=");
    m.console.print_hex(if (st == virtio_file.st_ok) @as(u64, @intCast(res.count)) else 0);
    m.console.puts("\n");
    return .none;
}

/// Calculator utilities: 'calc history' reads and prints calc_hst.txt on
/// the HOST SHARE (M24 K5 — the persisted calculation history ring; HF6
/// moved it from /data to the share).
fn cmd_calc(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0 or std.mem.eql(u8, args[0], "history")) {
        const path = "calc_hst.txt";
        if (!kernel_vf_allowed(path, .read)) return trust_denied(m, "calc history", path);
        var buf: [2048]u8 = undefined;
        const got = virtio_file.read_whole(path, &buf) orelse {
            err_prefix(m);
            m.console.print_line("calc: no history file found (calc_hst.txt on the host share)");
            return .none;
        };
        if (got == 0) {
            m.console.print_line("calc: history is empty");
            return .none;
        }
        // Count lines for the header
        var lines: u32 = 0;
        for (buf[0..got]) |ch| {
            if (ch == '\n') lines += 1;
        }
        m.console.puts("calc history (");
        m.console.print_u64(lines);
        m.console.print_line(" entries):\n");
        m.console.puts(buf[0..got]);
        if (got > 0 and buf[got - 1] != '\n') m.console.puts("\n");
        return .none;
    }
    // M62h: Zig CALC.BIN (and its CLI `calc <expr>` path) is gone. GOCALC.ELF
    // is GUI-only and treats argv[1] as a result-file path, so do not exec it
    // with an expression. Fall through to the honest unknown-subcommand error.
    err_prefix(m);
    m.console.puts("unknown calc subcommand: ");
    m.console.print_line(args[0]);
    print_usage(m, lookup("calc").?);
    return .invalid_argument;
}

/// Print a file's content from the HOST SHARE (M34 HF6, issue #740: the
/// ESP window and FAT volume are gone — the share is the only store).
/// Honest diagnostics for directories and files larger than the bounded
/// read buffer.
fn cmd_cat(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    // M50 TS2 (ADR 0024 D8): the monitor's own read of a secret-class path
    // is denied for every actor.
    if (!kernel_vf_allowed(name, .read)) return trust_denied(m, "cat", name);
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(name, &st) != virtio_file.st_ok) {
        err_prefix(m);
        m.console.puts(name);
        m.console.print_line(": not found (no such file on the host share)");
        return .invalid_argument;
    }
    if (st.is_dir) {
        err_prefix(m);
        m.console.puts(name);
        m.console.print_line(": is a directory");
        return .invalid_argument;
    }
    var buf: [2048]u8 = undefined;
    if (st.size > @as(u64, @intCast(buf.len))) {
        err_prefix(m);
        m.console.puts(name);
        m.console.puts(": file is ");
        m.console.print_hex(st.size);
        m.console.puts(" bytes; direct read caps at ");
        m.console.print_hex(buf.len);
        m.console.print_line(" bytes");
        return .invalid_argument;
    }
    const got = virtio_file.read_into(name, st.size, &buf) orelse {
        err_prefix(m);
        m.console.puts(name);
        m.console.print_line(": not found (no such file on the host share)");
        return .invalid_argument;
    };
    m.console.puts(buf[0..got]);
    // A trailing newline keeps the shell prompt on its own line; a file
    // that already ends with one is printed verbatim (no double blank).
    if (got == 0 or buf[got - 1] != '\n') m.console.puts("\n");
    return .none;
}

/// Print a file by path, read from the HOST SHARE (kept as the `/`-path
/// entry point — the channel accepts share-relative paths with slashes).
fn cmd_cat_path(m: *Monitor, path: []const u8) ExecError {
    return cmd_cat(m, &.{path});
}

/// Write text to the ESP's FAT32 volume (claim 6420 — the real storage
/// driver replacing claim 3475's NVRAM variables): the file survives
/// reboot because it is on the disk itself. Capacity is checked before the
/// write; a failed sector write is reported honestly, never faked.
// M34 HF1+HF2 (issues #735/#736): the HOST FILE CHANNEL (`vf ls`/`vf cat`).
// The guest userland filesystem is a macOS folder served over custom-virtio
// queue 5 (runner flag --cvc-file <host-dir>); default boots print the
// honest "no host file channel" line and stay byte-identical.
//
// M34 HF3 (issue #737): mutation verbs. OPEN/CLOSE/WRITE/TRUNCATE/FSYNC
// ride the HOST's 8-slot handle table (cursors live there — parity with
// file_table.zig); `vf write <h> <n>` streams n deterministic probe-pattern
// bytes through the cursor (the gate's python verifies the same bytes on
// the host disk). `vf mkdir/rm/mv` are stateless path ops.
// ---------------------------------------------------------------------------

/// M50 TS2 (issue #1136, ADR 0024 D4/D8): the monitor's explicit
/// `kernel_actor()` gate. The monitor is uid_system + CAP_FS_ANY, so ordinary
/// paths pass and secret-class paths are denied for EVERY actor. An empty
/// path is the share root (list); an unparseable/over-long path fails closed.
pub fn kernel_vf_allowed(path: []const u8, want: trust.Want) bool {
    if (path.len == 0) return trust.check(trust.kernel_actor(), .host, "", want) == .allow;
    const parsed = file_table.parse_path(path) orelse return false;
    if (parsed.partition == .tty) return true;
    return trust.check(trust.kernel_actor(), parsed.partition, parsed.path[0..parsed.parsed_len()], want) == .allow;
}

/// The honest refusal line for a policy-denied direct-consumer file op.
fn trust_denied(m: *Monitor, verb: []const u8, path: []const u8) ExecError {
    err_prefix(m);
    m.console.puts(verb);
    m.console.puts(": ");
    m.console.puts(path);
    m.console.print_line(": permission denied");
    return .invalid_argument;
}

fn cmd_vf(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_vf_usage(m);
    // M100d (issue #2309): a /disk path routes to the VLFS volume whether
    // or not the host channel is attached — the mount stands alone, so
    // the availability check fires only for verbs with no disk operand.
    const disk_target = args.len > 1 and arg_is_disk(args[1]);
    if (!virtio_file.available() and !disk_target) {
        m.console.print_line("vf: no host file channel (boot the runner with --cvc-file <host-dir>)");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "ls")) return cmd_vf_ls(m, args[1..]);
    if (std.mem.eql(u8, args[0], "cat")) return cmd_vf_cat(m, args[1..]);
    if (std.mem.eql(u8, args[0], "open")) return cmd_vf_open(m, args[1..]);
    if (std.mem.eql(u8, args[0], "close")) return cmd_vf_close(m, args[1..]);
    if (std.mem.eql(u8, args[0], "write")) return cmd_vf_write(m, args[1..]);
    if (std.mem.eql(u8, args[0], "truncate")) return cmd_vf_truncate(m, args[1..]);
    if (std.mem.eql(u8, args[0], "fsync")) return cmd_vf_fsync(m, args[1..]);
    if (std.mem.eql(u8, args[0], "mkdir")) return cmd_vf_mkdir(m, args[1..]);
    if (std.mem.eql(u8, args[0], "rm")) return cmd_vf_rm(m, args[1..]);
    if (std.mem.eql(u8, args[0], "mv")) return cmd_vf_mv(m, args[1..]);
    if (std.mem.eql(u8, args[0], "clone")) return cmd_vf_clone(m, args[1..]);
    return cmd_vf_usage(m);
}

/// Does this argument name a /disk path? (nil/parse failures are host-side.)
fn arg_is_disk(arg: []const u8) bool {
    const parsed = file_table.parse_path(arg) orelse return false;
    return parsed.partition == .disk;
}

fn cmd_vf_usage(m: *Monitor) ExecError {
    err_prefix(m);
    m.console.print_line("vf usage: vf ls [<path>] | cat <path> | mkdir <path> | rm <path> | mv <from> <to> | clone <from> <to> | open <path> [append] | close <h> | write <h> <n> | truncate <h> <n> | fsync <h>");
    return .invalid_argument;
}

fn vf_status_text(st: u8) []const u8 {
    return switch (st) {
        virtio_file.st_not_found => "not found on the host share",
        virtio_file.st_is_dir => "is a directory",
        virtio_file.st_exists => "already exists on the host share",
        virtio_file.st_handle => "bad handle or host handle table full (8 open handles)",
        virtio_file.st_truncated => "reply truncated (file larger than the 32 KiB per-round-trip cap)",
        else => "host file-channel error",
    };
}

fn vf_err(m: *Monitor, verb: []const u8, path: []const u8, st: u8) ExecError {
    err_prefix(m);
    m.console.puts("vf ");
    m.console.puts(verb);
    m.console.puts(": ");
    m.console.puts(path);
    m.console.puts(": ");
    m.console.print_line(vf_status_text(st));
    return .invalid_argument;
}

/// `vf open <path> [append]` — create-if-missing read+write handle.
fn cmd_vf_open(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_vf_usage(m);
    const path = args[0];
    if (arg_is_disk(path)) {
        // The disk has no monitor handle table — writes go through the
        // whole-file verbs (`write`, `vf write <path> <n>`) or the file ABI.
        err_prefix(m);
        m.console.puts("vf open: ");
        m.console.puts(path);
        m.console.print_line(": no handle form on /disk — use 'vf write <path> <n>'");
        return .invalid_argument;
    }
    if (!kernel_vf_allowed(path, .create)) return trust_denied(m, "vf open", path);
    var flags: u8 = virtio_file.open_flag_create;
    if (args.len > 1 and std.mem.eql(u8, args[1], "append")) flags |= virtio_file.open_flag_append;
    var handle: u16 = 0;
    const st = virtio_file.open(path, flags, &handle);
    if (st != virtio_file.st_ok) return vf_err(m, "open", path, st);
    m.console.puts("vf: open ");
    m.console.puts(path);
    m.console.puts(if ((flags & virtio_file.open_flag_append) != 0) " append" else "");
    m.console.puts(" h=");
    m.console.print_u64(handle);
    m.console.puts("\n");
    return .none;
}

/// `vf close <h>` — flush + free the host slot.
fn cmd_vf_close(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_vf_usage(m);
    const handle = parseInt(args[0]) catch return cmd_vf_usage(m);
    // M97d-F4 (#2089): the host handle is a u16 — a wider console argument
    // is a usage error, never a silent ReleaseSmall truncation onto another
    // process's slot in the host's GLOBAL handle table.
    if (handle > std.math.maxInt(u16)) return cmd_vf_usage(m);
    const st = virtio_file.close(@intCast(handle));
    if (st != virtio_file.st_ok) return vf_err(m, "close", args[0], st);
    m.console.puts("vf: close ");
    m.console.puts(args[0]);
    m.console.print_line(" ok");
    return .none;
}

/// `vf write <h> <n>` — stream n probe-pattern bytes through the cursor;
/// `vf write /disk/<path> <n>` — the same fill on the VLFS volume.
fn cmd_vf_write(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len < 2) return cmd_vf_usage(m);
    if (arg_is_disk(args[0])) {
        const n = parseInt(args[1]) catch return cmd_vf_usage(m);
        if (n == 0) return cmd_vf_usage(m);
        const parsed = file_table.parse_path(args[0]).?;
        return cmd_disk_write(m, parsed.path[0..parsed.parsed_len()], n);
    }
    const handle = parseInt(args[0]) catch return cmd_vf_usage(m);
    const n = parseInt(args[1]) catch return cmd_vf_usage(m);
    if (n == 0) return cmd_vf_usage(m);
    if (handle > std.math.maxInt(u16)) return cmd_vf_usage(m); // #2089
    const res = virtio_file.write_pattern(@intCast(handle), n);
    if (res.status != virtio_file.st_ok) return vf_err(m, "write", args[0], res.status);
    m.console.puts("vf: write ");
    m.console.puts(args[0]);
    m.console.puts(" n=");
    m.console.print_u64(n);
    m.console.puts(" wrote=");
    m.console.print_u64(res.total);
    m.console.puts(" chunks=");
    m.console.print_u64(res.chunks);
    m.console.puts("\n");
    return .none;
}

/// `vf truncate <h> <n>` — set the file size through the handle;
/// `vf truncate /disk/<path> <n>` — the journaled resize on VLFS.
fn cmd_vf_truncate(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len < 2) return cmd_vf_usage(m);
    if (arg_is_disk(args[0])) {
        const size = parseInt(args[1]) catch return cmd_vf_usage(m);
        const parsed = file_table.parse_path(args[0]).?;
        const subpath = parsed.path[0..parsed.parsed_len()];
        const found = vlfs_disk.lookup(subpath) catch |err| return disk_verb_err(m, "vf truncate", subpath, err);
        if (found.kind == vlfs.kind_dir) return disk_verb_err(m, "vf truncate", subpath, error.IsDir);
        vlfs_disk.truncate(found.inode, @intCast(@min(size, std.math.maxInt(u32)))) catch |err| return disk_verb_err(m, "vf truncate", subpath, err);
        m.console.puts("vf: truncate disk:");
        m.console.puts(subpath);
        m.console.puts(" size=");
        m.console.print_u64(size);
        m.console.print_line(" ok");
        return .none;
    }
    const handle = parseInt(args[0]) catch return cmd_vf_usage(m);
    const size = parseInt(args[1]) catch return cmd_vf_usage(m);
    if (handle > std.math.maxInt(u16)) return cmd_vf_usage(m); // #2089
    const st = virtio_file.truncate(@intCast(handle), size);
    if (st != virtio_file.st_ok) return vf_err(m, "truncate", args[0], st);
    m.console.puts("vf: truncate ");
    m.console.puts(args[0]);
    m.console.puts(" size=");
    m.console.print_u64(size);
    m.console.print_line(" ok");
    return .none;
}

/// `vf fsync <h>` — real durability on the host fd; `vf fsync /disk[...]` —
/// the virtio-blk FLUSH barrier on the mounted VLFS volume.
fn cmd_vf_fsync(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_vf_usage(m);
    if (arg_is_disk(args[0])) {
        vlfs_disk.sync() catch |err| return disk_verb_err(m, "vf fsync", args[0], err);
        m.console.puts("vf: fsync ");
        m.console.puts(args[0]);
        m.console.print_line(" ok (FLUSH completed)");
        return .none;
    }
    const handle = parseInt(args[0]) catch return cmd_vf_usage(m);
    if (handle > std.math.maxInt(u16)) return cmd_vf_usage(m); // #2089
    const st = virtio_file.fsync(@intCast(handle));
    if (st != virtio_file.st_ok) return vf_err(m, "fsync", args[0], st);
    m.console.puts("vf: fsync ");
    m.console.puts(args[0]);
    m.console.print_line(" ok");
    return .none;
}

/// `vf mkdir <path>` — one level; parents must exist.
fn cmd_vf_mkdir(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_vf_usage(m);
    const path = args[0];
    if (file_table.parse_path(path)) |parsed| {
        if (parsed.partition == .disk) {
            const subpath = parsed.path[0..parsed.parsed_len()];
            _ = vlfs_disk.create(subpath, vlfs.kind_dir) catch |err| return disk_verb_err(m, "vf mkdir", subpath, err);
            m.console.puts("vf: mkdir disk:");
            m.console.puts(subpath);
            m.console.print_line(" ok");
            return .none;
        }
    }
    if (!kernel_vf_allowed(path, .create)) return trust_denied(m, "vf mkdir", path);
    const st = virtio_file.mkdir(path);
    if (st != virtio_file.st_ok) return vf_err(m, "mkdir", path, st);
    m.console.puts("vf: mkdir ");
    m.console.puts(path);
    m.console.print_line(" ok");
    return .none;
}

/// `vf rm <path>` — delete a file or EMPTY directory.
fn cmd_vf_rm(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_vf_usage(m);
    const path = args[0];
    if (file_table.parse_path(path)) |parsed| {
        if (parsed.partition == .disk) {
            const subpath = parsed.path[0..parsed.parsed_len()];
            _ = vlfs_disk.remove(subpath) catch |err| return disk_verb_err(m, "vf rm", subpath, err);
            m.console.puts("vf: rm disk:");
            m.console.puts(subpath);
            m.console.print_line(" ok");
            return .none;
        }
    }
    if (!kernel_vf_allowed(path, .delete)) return trust_denied(m, "vf rm", path);
    const st = virtio_file.delete(path);
    if (st != virtio_file.st_ok) return vf_err(m, "rm", path, st);
    m.console.puts("vf: rm ");
    m.console.puts(path);
    m.console.print_line(" ok");
    return .none;
}

/// `vf mv <from> <to>` — rename on the host share.
fn cmd_vf_mv(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len < 2) return cmd_vf_usage(m);
    const from = args[0];
    const to = args[1];
    const from_disk = arg_is_disk(from);
    const to_disk = arg_is_disk(to);
    if (from_disk or to_disk) {
        // Same-volume only — a cross-partition move has no rename op.
        if (!(from_disk and to_disk)) {
            err_prefix(m);
            m.console.puts("vf mv: ");
            m.console.puts(from);
            m.console.puts(" -> ");
            m.console.puts(to);
            m.console.print_line(": cross-partition rename refused");
            return .invalid_argument;
        }
        const fp = file_table.parse_path(from).?;
        const tp = file_table.parse_path(to).?;
        const fs = fp.path[0..fp.parsed_len()];
        const ts = tp.path[0..tp.parsed_len()];
        vlfs_disk.rename(fs, ts, false) catch |err| return disk_verb_err(m, "vf mv", fs, err);
        m.console.puts("vf: mv disk:");
        m.console.puts(fs);
        m.console.puts(" -> ");
        m.console.puts(ts);
        m.console.print_line(" ok");
        return .none;
    }
    if (!kernel_vf_allowed(from, .delete)) return trust_denied(m, "vf mv", from);
    if (!kernel_vf_allowed(to, .create)) return trust_denied(m, "vf mv", to);
    const st = virtio_file.rename(from, to);
    if (st != virtio_file.st_ok) return vf_err(m, "mv", from, st);
    m.console.puts("vf: mv ");
    m.console.puts(from);
    m.console.puts(" -> ");
    m.console.puts(to);
    m.console.print_line(" ok");
    return .none;
}

/// `vf clone <from> <to>` — APFS COW clone on the host share (HF7, issue
/// #741): the worktree workflow. `to` must not exist; N clones of one
/// repo share blocks until a worktree actually edits a file (the host
/// clones with clonefile/copyfile(COPYFILE_CLONE) — measured live by the
/// HF7 gate). File or whole directory tree.
fn cmd_vf_clone(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len < 2) return cmd_vf_usage(m);
    const from = args[0];
    const to = args[1];
    if (!kernel_vf_allowed(from, .read)) return trust_denied(m, "vf clone", from);
    if (!kernel_vf_allowed(to, .create)) return trust_denied(m, "vf clone", to);
    const st = virtio_file.clone(from, to);
    if (st != virtio_file.st_ok) return vf_err(m, "clone", from, st);
    m.console.puts("vf: clone ");
    m.console.puts(from);
    m.console.puts(" -> ");
    m.console.puts(to);
    m.console.print_line(" ok");
    return .none;
}

fn cmd_vf_ls(m: *Monitor, args: []const []const u8) ExecError {
    const path: []const u8 = if (args.len > 0) args[0] else "";
    if (!kernel_vf_allowed(path, .list)) return trust_denied(m, "vf ls", path);
    if (file_table.parse_path(path)) |parsed| {
        if (parsed.partition == .disk) return cmd_disk_ls(m, parsed.path[0..parsed.parsed_len()]);
    }
    var res: virtio_file.ListResult = .{};
    const st = virtio_file.list(path, &res);
    if (st != virtio_file.st_ok) {
        err_prefix(m);
        m.console.puts("vf ls: ");
        m.console.puts(if (path.len > 0) path else "/");
        m.console.puts(": ");
        m.console.print_line(vf_status_text(st));
        return .invalid_argument;
    }
    var i: usize = 0;
    while (i < res.count) : (i += 1) {
        const e = res.entries[i];
        m.console.puts(e.name[0..e.name_len]);
        m.console.puts(if (e.type == virtio_file.dir_type_dir) "/ " else "  ");
        m.console.print_u64(e.size);
        m.console.puts("\n");
    }
    return .none;
}

fn cmd_vf_cat(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_vf_usage(m);
    const path = args[0];
    if (!kernel_vf_allowed(path, .read)) return trust_denied(m, "vf cat", path);
    if (file_table.parse_path(path)) |parsed| {
        if (parsed.partition == .disk) return cmd_disk_cat(m, parsed.path[0..parsed.parsed_len()]);
    }
    var st_res: virtio_file.StatResult = .{};
    const st = virtio_file.stat(path, &st_res);
    if (st != virtio_file.st_ok) {
        err_prefix(m);
        m.console.puts("vf cat: ");
        m.console.puts(path);
        m.console.puts(": ");
        m.console.print_line(vf_status_text(st));
        return .invalid_argument;
    }
    if (st_res.is_dir) {
        err_prefix(m);
        m.console.puts("vf cat: ");
        m.console.puts(path);
        m.console.print_line(": is a directory");
        return .invalid_argument;
    }
    // STAT first — the gate asserts the byte count before the stream.
    m.console.puts("vf: cat ");
    m.console.puts(path);
    m.console.puts(" size=");
    m.console.print_u64(st_res.size);
    m.console.puts("\n");
    var acc = virtio_file.StreamCksum{};
    var off: u64 = 0;
    var rts: usize = 0;
    var total: u64 = 0;
    while (true) {
        const rr = virtio_file.read(path, off);
        if (rr.status != virtio_file.st_ok) {
            if (rr.status == virtio_file.st_not_found) break; // raced delete: honest partial
            err_prefix(m);
            m.console.puts("vf cat: ");
            m.console.puts(path);
            m.console.puts(": ");
            m.console.print_line(vf_status_text(rr.status));
            return .invalid_argument;
        }
        if (rr.data.len == 0) break; // EOF
        rts += 1;
        total += rr.data.len;
        acc.add(rr.data);
        off += rr.data.len;
    }
    m.console.puts("vf: cat ok bytes=");
    m.console.print_u64(total);
    m.console.puts(" rts=");
    m.console.print_u64(rts);
    m.console.puts(" cksum=0x");
    m.console.puts(&vf_hex16(acc.finish()));
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// M100c (issue #2308, ADR 0050): `vf ls`, `vf cat` and `stat` on /disk go to
// the mounted VLFS volume — the same reader the EL0 file ABI uses. A missing
// or refused disk prints the ADR refusal name (not_vlfs, io_error, ...)
// rather than leaking the path into the host share.
// ---------------------------------------------------------------------------

/// Readdir staging for `vf ls /disk...` — the sorted smallest-256 live
/// dirents, the same bound file_table's own listing uses.
var disk_ls_entries: [file_table.directory.entry_max]vlfs.Dirent = undefined;
/// `vf cat /disk/...` stream window (the kernel stack cannot hold one).
var disk_cat_buf: [vlfs.block_len]u8 = undefined;

fn disk_verb_err(m: *Monitor, verb: []const u8, path: []const u8, err: vlfs.Error) ExecError {
    err_prefix(m);
    m.console.puts(verb);
    m.console.puts(": disk:");
    m.console.puts(if (path.len == 0) "/" else path);
    m.console.puts(": ");
    m.console.print_line(vlfs.refusalName(err));
    return .invalid_argument;
}

fn cmd_disk_ls(m: *Monitor, subpath: []const u8) ExecError {
    const dir = vlfs_disk.lookup(subpath) catch |err| return disk_verb_err(m, "vf ls", subpath, err);
    if (dir.kind != vlfs.kind_dir) return disk_verb_err(m, "vf ls", subpath, error.NotDir);
    const n = vlfs_disk.listDir(dir.inode, &disk_ls_entries) catch |err| return disk_verb_err(m, "vf ls", subpath, err);
    for (disk_ls_entries[0..n]) |*d| {
        const st = vlfs_disk.statInode(d.inode) catch |err| return disk_verb_err(m, "vf ls", subpath, err);
        m.console.puts(d.nameSlice());
        m.console.puts(if (d.kind == vlfs.kind_dir) "/ " else "  ");
        m.console.print_u64(st.size);
        m.console.puts("\n");
    }
    return .none;
}

fn cmd_disk_cat(m: *Monitor, subpath: []const u8) ExecError {
    const found = vlfs_disk.lookup(subpath) catch |err| return disk_verb_err(m, "vf cat", subpath, err);
    if (found.kind == vlfs.kind_dir) {
        err_prefix(m);
        m.console.puts("vf cat: disk:");
        m.console.puts(subpath);
        m.console.print_line(": is a directory");
        return .invalid_argument;
    }
    const st = vlfs_disk.statInode(found.inode) catch |err| return disk_verb_err(m, "vf cat", subpath, err);
    m.console.puts("vf: cat disk:");
    m.console.puts(subpath);
    m.console.puts(" size=");
    m.console.print_u64(st.size);
    m.console.puts("\n");
    var acc = virtio_file.StreamCksum{};
    var off: u64 = 0;
    var rts: usize = 0;
    var total: u64 = 0;
    while (off < st.size) {
        const n = vlfs_disk.read(found.inode, off, &disk_cat_buf) catch |err| return disk_verb_err(m, "vf cat", subpath, err);
        if (n == 0) break; // defensive EOF
        rts += 1;
        total += n;
        acc.add(disk_cat_buf[0..n]);
        off += n;
    }
    m.console.puts("vf: cat ok bytes=");
    m.console.print_u64(total);
    m.console.puts(" rts=");
    m.console.print_u64(rts);
    m.console.puts(" cksum=0x");
    m.console.puts(&vf_hex16(acc.finish()));
    m.console.puts("\n");
    return .none;
}

/// `vf write /disk/<path> <n>` — write n bytes of a deterministic fill
/// pattern through the journaled write path in reply_cap-sized chunks
/// (each chunk is one committed transaction). A mid-fill refusal reports
/// the named reason AND the confirmed byte count — an honest short write.
fn cmd_disk_write(m: *Monitor, subpath: []const u8, n: u64) ExecError {
    var written: u64 = 0;
    var chunks: u64 = 0;
    while (written < n) {
        const take: usize = @intCast(@min(n - written, cmd_write_buf.len));
        for (cmd_write_buf[0..take], 0..) |*b, i| {
            b.* = @intCast((written + i) % 251);
        }
        vlfs_disk.writeAppend(subpath, cmd_write_buf[0..take]) catch |err| {
            err_prefix(m);
            m.console.puts("vf write: disk:");
            m.console.puts(subpath);
            m.console.puts(": ");
            m.console.puts(vlfs.refusalName(err));
            m.console.puts(" after ");
            m.console.print_u64(written);
            m.console.print_line(" bytes");
            return .invalid_argument;
        };
        written += take;
        chunks += 1;
    }
    vlfs_disk.sync() catch |err| return disk_verb_err(m, "vf write", subpath, err);
    m.console.puts("vf: write disk:");
    m.console.puts(subpath);
    m.console.puts(" n=");
    m.console.print_u64(n);
    m.console.puts(" wrote=");
    m.console.print_u64(written);
    m.console.puts(" chunks=");
    m.console.print_u64(chunks);
    m.console.puts("\n");
    return .none;
}

fn cmd_disk_stat(m: *Monitor, name: []const u8, subpath: []const u8) ExecError {
    const found = vlfs_disk.lookup(subpath) catch |err| return disk_verb_err(m, "stat", subpath, err);
    const st = vlfs_disk.statInode(found.inode) catch |err| return disk_verb_err(m, "stat", subpath, err);
    m.console.puts("  File:    ");
    m.console.print_line(name);
    m.console.puts("  Size:    ");
    m.console.print_u64(st.size);
    m.console.print_line(" bytes");
    m.console.puts("  Type:    ");
    m.console.print_line(if (st.kind == vlfs.kind_dir) "directory" else "regular file");
    m.console.puts("  Inode:   ");
    m.console.print_u64(st.ino);
    m.console.puts("\n");
    m.console.puts("  Volume:  ");
    m.console.print_line("vlfs");
    return .none;
}

/// Compact lowercase 4-digit hex (the vf gate's cksum needle style).
fn vf_hex16(value: u16) [4]u8 {
    const digits = "0123456789abcdef";
    var out: [4]u8 = undefined;
    out[0] = digits[@intCast((value >> 12) & 0xf)];
    out[1] = digits[@intCast((value >> 8) & 0xf)];
    out[2] = digits[@intCast((value >> 4) & 0xf)];
    out[3] = digits[@intCast(value & 0xf)];
    return out;
}

/// Write text to a file on the HOST SHARE (M34 HF5/HF6, issues
/// #739/#740): write_whole = open/create + truncate + chunked write +
/// close through the queue-5 channel — the file persists on the macOS
/// host disk, verified by the gates. Capacity is checked before the
/// write; a failed exchange is reported honestly, never faked.
/// Issue #803: 32 KiB staging can never live on the 16 KiB kernel stack
/// (ADR 0004 D5). The write path is reached from the shell's merged
/// boot_and_park frame; the local buffer overflowed the boot stack and
/// corrupted the console state mid-print. Module BSS, like vf_write_buf.
var cmd_write_buf: [virtio_file.reply_cap]u8 align(16) = undefined;

fn cmd_write(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    const parts = args[1..];
    var len: usize = 0;
    for (parts, 0..) |p, i| len += p.len + (if (i > 0) @as(usize, 1) else 0);
    if (len > virtio_file.reply_cap) {
        err_prefix(m);
        m.console.puts("content too long (max ");
        m.console.print_hex(virtio_file.reply_cap);
        m.console.puts(" bytes, got ");
        m.console.print_hex(@intCast(len));
        m.console.print_line(")");
        return .invalid_argument;
    }
    const buf = &cmd_write_buf;
    var n: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    // M100d (issue #2309): `write /disk/<path> <text>` is a journaled
    // whole-file replace + FLUSH on the mounted volume.
    if (arg_is_disk(name)) {
        const parsed = file_table.parse_path(name).?;
        const subpath = parsed.path[0..parsed.parsed_len()];
        vlfs_disk.writeWhole(subpath, buf[0..n]) catch |err| return disk_verb_err(m, "write", subpath, err);
        m.console.puts("write: ok (journaled ");
        m.console.print_u64(n);
        m.console.puts(" bytes to disk:");
        m.console.puts(subpath);
        m.console.puts(")\n");
        return .none;
    }
    if (!kernel_vf_allowed(name, .write)) return trust_denied(m, "write", name);
    const st = virtio_file.write_whole(name, buf[0..n]);
    if (st == virtio_file.st_ok) {
        m.console.puts("write: ok (persisted ");
        m.console.print_u64(n);
        m.console.puts(" bytes to the host share)\n");
        return .none;
    }
    err_prefix(m);
    m.console.puts(name);
    m.console.puts(": not persisted - ");
    m.console.print_line(vf_status_text(st));
    return .not_implemented;
}

/// M19 P16 (issue #305): create a temporary file with a unique name.
/// Usage: mktemp [prefix] - creates prefix_XXXX.BIN (default TMP_XXXX.BIN).
fn cmd_mktemp(m: *Monitor, args: []const []const u8) ExecError {
    const prefix = if (args.len > 0) args[0] else "TMP";
    // Generate 4 random hex digits.
    var rnd: [2]u8 = undefined;
    csprng.random_bytes(&rnd);
    const hex = "0123456789abcdef";
    var suffix: [4]u8 = undefined;
    suffix[0] = hex[(rnd[0] >> 4) & 0x0f];
    suffix[1] = hex[rnd[0] & 0x0f];
    suffix[2] = hex[(rnd[1] >> 4) & 0x0f];
    suffix[3] = hex[rnd[1] & 0x0f];
    // Build filename: PREFIX_XXXX.BIN
    var name_buf: [32]u8 = undefined;
    var n: usize = 0;
    for (prefix) |b| {
        if (n < name_buf.len - 10) {
            name_buf[n] = b;
            n += 1;
        }
    }
    if (n < name_buf.len - 10) {
        name_buf[n] = '_';
        n += 1;
    }
    @memcpy(name_buf[n..][0..4], &suffix);
    n += 4;
    @memcpy(name_buf[n..][0..4], ".BIN");
    n += 4;
    const name = name_buf[0..n];
    // Create the empty file on the host share (HF6: the ESP window is gone).
    if (!kernel_vf_allowed(name, .create)) return trust_denied(m, "mktemp", name);
    const st = virtio_file.write_whole(name, "");
    if (st == virtio_file.st_ok) {
        m.console.puts(name);
        m.console.puts("\n");
        return .none;
    }
    err_prefix(m);
    m.console.puts(name);
    m.console.puts(": ");
    m.console.print_line(vf_status_text(st));
    return .not_implemented;
}

// ---------------------------------------------------------------------------
// M22 Lane-D: filesystem inspection (D8), log viewer (D12), timing (D13),
// command locator (D16)
// ---------------------------------------------------------------------------

/// M22 D8 (issue #331): `stat <file|path>` — print file metadata from the
/// HOST SHARE (M34 HF6, issue #740: the FAT volume and ESP window are
/// gone): size, type (file/dir), and path.
fn cmd_stat(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    if (!kernel_vf_allowed(name, .read)) return trust_denied(m, "stat", name);
    if (file_table.parse_path(name)) |parsed| {
        if (parsed.partition == .disk) return cmd_disk_stat(m, name, parsed.path[0..parsed.parsed_len()]);
    }
    var st = virtio_file.StatResult{};
    const sst = virtio_file.stat(name, &st);
    if (sst != virtio_file.st_ok or st.is_dir) {
        err_prefix(m);
        m.console.puts("stat: ");
        m.console.puts(name);
        m.console.print_line(": not found");
        return .invalid_argument;
    }
    m.console.puts("  File:    ");
    m.console.print_line(name);
    m.console.puts("  Size:    ");
    m.console.print_u64(st.size);
    m.console.print_line(" bytes");
    m.console.puts("  Type:    ");
    m.console.print_line("regular file");
    m.console.puts("  Volume:  ");
    m.console.print_line("host share");
    return .none;
}

/// M25 F4 (issue #384): `du [<path>]` — estimate file space usage recursively
/// (bounded: 3 levels deep).
/// M25 F4 (issue #384): `du [<path>]` — estimate file space usage
/// recursively on the HOST SHARE (bounded: 3 levels deep, like the FAT
/// walk it replaces — HF6, issue #740).
const du_max_depth: usize = 3;

fn du_walk(m: *Monitor, path: []const u8, depth: usize, bytes: *u64, dirs: *u64) void {
    var res: virtio_file.ListResult = .{};
    if (virtio_file.list(path, &res) != virtio_file.st_ok) return;
    for (res.entries[0..res.count]) |e| {
        if (e.type == virtio_file.dir_type_dir) {
            if (depth < du_max_depth) {
                dirs.* += 1;
                var sub: [128]u8 = undefined;
                const sub_path = if (path.len == 0)
                    e.name[0..@min(e.name_len, sub.len)]
                else blk: {
                    const take = @min(path.len, sub.len - 1 - e.name_len);
                    @memcpy(sub[0..take], path[0..take]);
                    var p = take;
                    if (p < sub.len and sub[p - 1] != '/') {
                        sub[p] = '/';
                        p += 1;
                    }
                    const nt = @min(e.name_len, sub.len - p);
                    @memcpy(sub[p..][0..nt], e.name[0..nt]);
                    p += nt;
                    break :blk sub[0..p];
                };
                du_walk(m, sub_path, depth + 1, bytes, dirs);
            }
        } else {
            bytes.* += e.size;
        }
    }
}

fn cmd_du(m: *Monitor, args: []const []const u8) ExecError {
    const path = if (args.len > 0) args[0] else "";
    var bytes: u64 = 0;
    var dirs: u64 = 0;
    du_walk(m, path, 0, &bytes, &dirs);
    m.console.puts("du: ");
    m.console.puts(if (path.len > 0) path else "/");
    m.console.puts(" ");
    m.console.print_u64(bytes);
    m.console.puts(" bytes (dirs=");
    m.console.print_u64(dirs);
    m.console.print_line(")");
    return .none;
}

/// M22 D8 (issue #331): `find <dir> -name <pattern>` — recursive file
/// search with simple glob patterns (* and ?). Bounded: 3 levels deep,
/// 256 results max.
fn cmd_find(m: *Monitor, args: []const []const u8) ExecError {
    const start_path = args[0];
    // args[1] should be "-name"
    if (!std.mem.eql(u8, args[1], "-name")) {
        err_prefix(m);
        m.console.print_line("find: expected '-name' keyword");
        print_usage(m, lookup("find").?);
        return .usage;
    }
    const pattern = args[2];
    var count: usize = 0;
    find_recursive(m, start_path, pattern, 0, &count);
    if (count == 0) {
        m.console.puts("find: no matches for '");
        m.console.puts(pattern);
        m.console.print_line("'");
    }
    return .none;
}

const find_max_depth: usize = 3;
const find_max_results: usize = 256;

fn find_recursive(m: *Monitor, dir_path: []const u8, pattern: []const u8, depth: usize, count: *usize) void {
    if (depth >= find_max_depth or count.* >= find_max_results) return;
    // M34 HF6 (issue #740): find walks the HOST SHARE (the FAT volume is gone).
    var res: virtio_file.ListResult = .{};
    if (virtio_file.list(dir_path, &res) != virtio_file.st_ok) return;
    for (res.entries[0..res.count]) |e| {
        if (count.* >= find_max_results) break;
        const name = e.name[0..e.name_len];
        // Match against pattern
        if (glob_match(name, pattern)) {
            // Build full path
            var path_buf: [128]u8 = undefined;
            var pos: usize = 0;
            const is_dir = e.type == virtio_file.dir_type_dir;
            if (std.mem.eql(u8, dir_path, "/")) {
                path_buf[0] = '/';
                pos = 1;
            } else {
                const take = @min(dir_path.len, path_buf.len - 1 - name.len);
                @memcpy(path_buf[0..take], dir_path[0..take]);
                pos = take;
                if (pos < path_buf.len and path_buf[pos - 1] != '/') {
                    path_buf[pos] = '/';
                    pos += 1;
                }
            }
            const name_take = @min(name.len, path_buf.len - pos);
            @memcpy(path_buf[pos..][0..name_take], name[0..name_take]);
            pos += name_take;
            m.console.puts(path_buf[0..pos]);
            if (is_dir) m.console.putc('/');
            m.console.putc('\n');
            count.* += 1;
        }
        // Recurse into directories
        if (e.type == virtio_file.dir_type_dir) {
            var sub_path: [128]u8 = undefined;
            var spos: usize = 0;
            if (std.mem.eql(u8, dir_path, "/")) {
                sub_path[0] = '/';
                spos = 1;
            } else {
                const take = @min(dir_path.len, sub_path.len - 1 - name.len);
                @memcpy(sub_path[0..take], dir_path[0..take]);
                spos = take;
                if (spos < sub_path.len and sub_path[spos - 1] != '/') {
                    sub_path[spos] = '/';
                    spos += 1;
                }
            }
            const name_take = @min(name.len, sub_path.len - spos);
            @memcpy(sub_path[spos..][0..name_take], name[0..name_take]);
            spos += name_take;
            find_recursive(m, sub_path[0..spos], pattern, depth + 1, count);
        }
    }
}

/// Simple glob pattern match: * matches any sequence, ? matches one char.
fn glob_match(name: []const u8, pattern: []const u8) bool {
    return glob_match_impl(name, 0, pattern, 0);
}

fn glob_match_impl(name: []const u8, ni: usize, pat: []const u8, pi: usize) bool {
    if (pi == pat.len) return ni == name.len;
    if (pat[pi] == '*') {
        // Try matching zero or more chars
        var j: usize = ni;
        while (j <= name.len) : (j += 1) {
            if (glob_match_impl(name, j, pat, pi + 1)) return true;
        }
        return false;
    }
    if (ni >= name.len) return false;
    if (pat[pi] == '?' or pat[pi] == name[ni]) {
        return glob_match_impl(name, ni + 1, pat, pi + 1);
    }
    return false;
}

/// M22 D12 (issue #335): `dmesg` — print the serial ring buffer contents.
fn cmd_dmesg(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    var buf: [serial_ring.capacity * 2]u8 = undefined;
    const n = serial_ring.snapshot(&buf);
    if (n == 0) {
        m.console.print_line("dmesg: log is empty");
        return .none;
    }
    m.console.puts(buf[0..n]);
    // Ensure trailing newline
    if (n > 0 and buf[n - 1] != '\n') m.console.putc('\n');
    return .none;
}

/// M22 D13 (issue #336): `time <command> [args...]` — measure elapsed
/// ticks and wall-clock time for any command.
fn cmd_time(m: *Monitor, args: []const []const u8) ExecError {
    const start_ticks = timer.ticks;
    // Canonical lock order (svclock.zig): the nested exec acquires
    // KERNEL|dom, and this command already runs under exec's KERNEL hold —
    // KERNEL is LAST in the order, so taking a lower-ranked domain under
    // it would invert the order and close a cycle with the domain->KERNEL
    // takes (uaccess write-page resolution inside socket/file syscalls).
    // Drop the outer hold, let the nested exec acquire canonically, then
    // re-take so exec's paired release stays balanced.
    const outer = svclock.held_bits();
    svclock.release_set(outer);
    const result = exec(m, args);
    svclock.acquire_set(outer);
    const end_ticks = timer.ticks;
    const elapsed = end_ticks - start_ticks;
    // Convert ticks to seconds: the GIC timer fires at 24 MHz, but the
    // kernel counts scheduler ticks (typically ~100 Hz). Use timer.freq
    // if available, else assume 100 ticks/sec.
    const ticks_per_sec: u64 = if (timer.freq > 0) timer.freq else 100;
    const secs = elapsed / ticks_per_sec;
    const rem_ms = (elapsed % ticks_per_sec) * 1000 / ticks_per_sec;
    m.console.puts("real    ");
    m.console.print_u64(secs / 60);
    m.console.puts("m");
    if (rem_ms < 100) m.console.putc('0');
    if (rem_ms < 10) m.console.putc('0');
    m.console.print_u64(rem_ms);
    m.console.print_line("s");
    m.console.puts("ticks   ");
    m.console.print_u64(elapsed);
    m.console.puts("\n");
    return result;
}

/// M22 D16 (issue #339): `which <name>` — locate a command by name.
/// Reports shell builtins, monitor commands, and ESP applications.
fn cmd_which(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    // Check shell builtins first (the list from shell.zig dispatch_line)
    if (is_shell_builtin(name)) {
        m.console.puts(name);
        m.console.print_line(": shell builtin");
        return .none;
    }
    // Check monitor commands
    if (lookup(name)) |_| {
        m.console.puts(name);
        m.console.print_line(": monitor command");
        return .none;
    }
    // Check the host share listing (applications) — HF6: the ESP is gone.
    var res: virtio_file.ListResult = .{};
    if (virtio_file.list("", &res) == virtio_file.st_ok) {
        for (res.entries[0..res.count]) |e| {
            if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
                m.console.puts(name);
                m.console.print_line(": host-share application");
                return .none;
            }
        }
    }
    // Not found
    m.console.puts(name);
    m.console.print_line(": not found");
    return .none;
}

/// Check if a name is a shell builtin (from shell.zig dispatch_line).
///
/// ADR 0005: a const []const u8 table would land in rodata holding
/// ABSOLUTE link-time pointers, which the flat kernel loader never
/// relocates — on real hardware the first comparison dereferenced a
/// garbage pointer and took a data abort (observed live 2026-08-25,
/// claim 5220: far=0x4129a on `which type`). `inline for` keeps the list
/// comptime so every literal is referenced PC-relative.
fn is_shell_builtin(name: []const u8) bool {
    inline for (.{
        "export", "set",     "unset", "env",   "printenv",
        "alias",  "unalias", "exit",  "sh",    "prompt",
        "type",   "true",    "false", "jobs",  "fg",
        "if",     "for",     "while", "break", "continue",
        "fn",     "cd",
    }) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

/// M22 D16 (issue #339): `inventory` — list all installed applications
/// from the HOST SHARE with their sizes and types (HF6: the ESP is gone).
fn cmd_inventory(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    var res: virtio_file.ListResult = .{};
    if (virtio_file.list("", &res) != virtio_file.st_ok or res.count == 0) {
        m.console.print_line("inventory: no applications on the host share");
        return .none;
    }
    m.console.puts("inventory: ");
    m.console.print_u64(@intCast(res.count));
    m.console.print_line(" application(s):\n");
    var width: usize = 0;
    for (res.entries[0..res.count]) |e| width = @max(width, e.name_len);
    for (res.entries[0..res.count]) |e| {
        m.console.puts("  ");
        m.console.puts(e.name[0..e.name_len]);
        var pad: usize = e.name_len;
        while (pad < width + 2) : (pad += 1) m.console.putc(' ');
        m.console.puts("  ");
        m.console.print_hex(e.size);
        m.console.puts(" bytes  [");
        m.console.puts(if (e.type == virtio_file.dir_type_dir) "dir" else "host");
        m.console.puts("]\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Physical page allocator command (next-card milestone)
// ---------------------------------------------------------------------------

fn cmd_pages(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1 and !std.mem.eql(u8, args[0], "selftest")) {
        print_usage(m, lookup("pages").?);
        return .usage;
    }
    const s = alloc.stats();
    if (!s.armed) {
        err_prefix(m);
        if (args.len == 1) {
            m.console.print_line("allocator not armed (no poolable memory in span) — selftest refused");
        } else {
            m.console.print_line("allocator not armed (no poolable memory in span)");
        }
        return .none;
    }
    if (args.len == 1) return pages_selftest(m, s);
    // #2649: ONE write — the live-long-lived gate parses free=, and a
    // mid-token split by a concurrent write loses the hex run.
    m.console.linef("pages: armed=1 total=0x{x:0>16} free=0x{x:0>16} excluded=0x{x:0>16} regions=0x{x:0>16} span=0x{x:0>16}\n", .{
        s.total_pages, s.free_pages, s.excluded_pages, s.region_count, s.span_pages,
    });
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
    // #2649: ONE write for the whole echoed line — the fleet asserts the
    // marker whole-line (serial-exact / serial-contains), and a
    // per-argument composition lets a foreign write split it mid-token.
    var buf: [384]u8 = undefined;
    var len: usize = 0;
    for (args, 0..) |arg, index| {
        if (index > 0) {
            if (len >= buf.len) break;
            buf[len] = ' ';
            len += 1;
        }
        const n = @min(arg.len, buf.len - len);
        @memcpy(buf[len..][0..n], arg[0..n]);
        len += n;
        if (n < arg.len) break; // truncated honestly at the bound
    }
    if (len < buf.len) {
        buf[len] = '\n';
        len += 1;
    }
    m.console.puts(buf[0..len]);
    return .none;
}

/// Milestone fourteen card S1 (claim 0169): the terminal half of the shared
/// clipboard. With no args it pastes the current contents (the EL1h read of
/// the SAME buffer the slots 38/39 syscalls use); with args it joins them
/// (space-separated, the `echo` shape) and stores the result — the
/// M18 T5: toggle ANSI terminal colors on or off.
fn cmd_color(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        m.console.puts("color: ");
        m.console.print_line(if (settings.get_color()) "on" else "off");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "on") or std.mem.eql(u8, args[0], "1") or std.mem.eql(u8, args[0], "true")) {
        _ = settings.set("color", "on");
        _ = settings.set("color", "on");
        m.console.print_line("color: on");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "off") or std.mem.eql(u8, args[0], "0") or std.mem.eql(u8, args[0], "false")) {
        _ = settings.set("color", "off");
        m.console.print_line("color: off");
        return .none;
    }
    m.console.print_line("usage: color [on|off]");
    return .none;
}

/// M73f-2 (#1632): the `tty` line — a pure fn so host tests pin the shape
/// (`tty[<n>]: out_dropped=<n> in_dropped=<n>`), which the class-B serial
/// assert then matches after real activity. No EL0 ABI (D5): the counters
/// stay kernel-side and the monitor is their surface.
pub fn fmtDropLine(buf: []u8, index: usize, out_dropped: u64, in_dropped: u64) []const u8 {
    return std.fmt.bufPrint(buf, "tty[{d}]: out_dropped={d} in_dropped={d}\n", .{ index, out_dropped, in_dropped }) catch "tty: fmt overflow\n";
}

/// M73f-2 (#1632): print both ADR 0020 D1 drop counters for every bound
/// terminal — cheap and on-demand, never per-tick. Reads the existing
/// fields as-is (no getter, no syscall); prints nothing per-tick and
/// `tty: none` when no terminal is allocated.
fn cmd_tty(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    var printed: usize = 0;
    for (0..terminal.max_terminals) |h| {
        const t = terminal.get(h) orelse continue;
        var buf: [96]u8 = undefined;
        m.console.puts(fmtDropLine(&buf, h, t.out_dropped, t.in_dropped));
        printed += 1;
    }
    if (printed == 0) m.console.puts("tty: none\n");
    return .none;
}

/// bounded-copy proof from the shell. Truncation is honest: the staging
/// buffer is the clipboard capacity, so an over-long paste stores exactly
/// `clipboard.capacity` bytes and reports it.
fn cmd_clip(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        var buf: [clipboard.capacity]u8 = undefined;
        const n = clipboard.get(&buf);
        if (n == 0) {
            m.console.puts("clip: empty\n");
        } else {
            m.console.puts("clip: ");
            m.console.puts(buf[0..n]);
            m.console.puts("\n");
        }
        return .none;
    }
    var staging: [clipboard.capacity]u8 = undefined;
    var len: usize = 0;
    for (args, 0..) |arg, index| {
        if (index > 0) {
            if (len < staging.len) {
                staging[len] = ' ';
                len += 1;
            }
        }
        for (arg) |ch| {
            if (len >= staging.len) break;
            staging[len] = ch;
            len += 1;
        }
    }
    const stored = clipboard.set(staging[0..len]);
    m.console.puts("clip: stored ");
    m.console.print_u64(stored);
    m.console.puts(" bytes\n");
    return .none;
}

/// `vsock [<port>]` (M115a, issue #2460) — the guest→host connect half of
/// the `VZVirtioSocketDevice` save/restore probe. With no argument it
/// re-prints the bare arm line — the spec's whole-line witness, identical
/// pre-save and post-restore since it carries no device state. `vsock
/// <port>` issues one stream OP_REQUEST to VMADDR_CID_HOST:<port> on the
/// tx queue and reports the rx-ring answer: `connected` (OP_RESPONSE — the
/// host's VZVirtioSocketListener accepted), `refused` (OP_RST — no
/// listener on that port), or `timeout` (no answer inside the poll budget
/// — the degraded verdict a broken restore would produce). Absent/unarmed
/// device reports honestly.
fn cmd_vsock(m: *Monitor, args: []const []const u8) ExecError {
    // M115b (#2461, ADR 0056): `vsock ctl [badauth|replay|dup] <verb>
    // [name]` runs one virelai-ctl/1 session against the runner's
    // --vsock-ctl-port listener — connect, HMAC-challenge auth, request
    // line, reply verdict, shutdown. The exercise modes exist for the
    // gate's auth negatives.
    if (args.len > 0 and std.mem.eql(u8, args[0], "ctl")) {
        vsock_ctl.run(m.console, args[1..]);
        return .none;
    }
    if (!virtio_vsock.vs_ready) {
        m.console.print_line("vsock: absent (no virtio-vsock device armed)");
        return .none;
    }
    m.console.print_line("vsock: ready did=0x1053");
    if (args.len == 0) {
        m.console.puts("vsock: dev=");
        m.console.print_hex(virtio_vsock.vs_dev);
        m.console.puts(" cid=");
        m.console.print_hex(virtio_vsock.vs_guest_cid);
        m.console.puts("\n");
        return .none;
    }
    const parsed = parseInt(args[0]) catch {
        err_prefix(m);
        m.console.puts("invalid port: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (parsed == 0 or parsed > 0xffff_fffe) {
        err_prefix(m);
        m.console.puts("port out of range: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    }
    const port: u32 = @intCast(parsed);
    m.console.puts("vsock: connect port=");
    m.console.print_u64(port);
    m.console.puts("\n");
    switch (virtio_vsock.connect(port)) {
        .connected => {
            m.console.puts("vsock: connected port=");
            m.console.print_u64(port);
            m.console.puts(" sport=");
            m.console.print_u64(virtio_vsock.vs_last_src_port);
            m.console.puts("\n");
        },
        .refused => {
            m.console.puts("vsock: refused port=");
            m.console.print_u64(port);
            m.console.puts(" (peer RST)\n");
        },
        .timeout => {
            m.console.puts("vsock: timeout port=");
            m.console.print_u64(port);
            m.console.puts(" (no reply inside the poll budget)\n");
        },
    }
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

/// `compose` — list available Alt+key compose sequences (Arc5 #245, ADR 0014).
fn cmd_compose(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    input.compose_list(&m.console);
    return .none;
}

/// `crash` — list recent crash tombstones from /data/crash/.
/// Shows process name, PID, exit status, and tick for each tombstone.
/// M22 D11 (issue #334): `crash` — enhanced crash report viewer with
/// symbol resolution, formatted report, and serial snapshot display.
fn cmd_crash(m: *Monitor, args: []const []const u8) ExecError {
    const n = tombstone.count();
    if (n == 0) {
        m.console.print_line("crash: no tombstones recorded");
        return .none;
    }
    // `crash <index>` shows the detailed report for one tombstone
    if (args.len == 1) {
        const idx = parseInt(args[0]) catch {
            err_prefix(m);
            m.console.puts("crash: invalid index: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (idx >= n) {
            err_prefix(m);
            m.console.puts("crash: index out of range (max ");
            m.console.print_u64(n - 1);
            m.console.puts(")\n");
            return .invalid_argument;
        }
        if (tombstone.get(@intCast(idx))) |t| {
            var buf: [tombstone.tombstone_max_bytes]u8 = undefined;
            const len = tombstone.format_tombstone(t, &buf);
            m.console.puts(buf[0..len]);
            if (len > 0 and buf[len - 1] != '\n') m.console.putc('\n');
        }
        return .none;
    }
    // Default: list all tombstones with summary
    m.console.puts("crash: ");
    m.console.print_u64(n);
    m.console.print_line(" tombstone(s) (use 'crash <index>' for detail): ");
    _ = tombstone.list_to_console(m.console);
    return .none;
}

fn cmd_hex(m: *Monitor, args: []const []const u8) ExecError {
    for (args) |arg| {
        const value = parseInt(arg) catch {
            err_prefix(m);
            m.console.puts("invalid number: ");
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

/// `dui` — report the Driving Award window manager (claim 1543, milestone
/// six G5): the registry (id/title/kind/rect/z-order/dirty/visible/owner),
/// the focused window, and the composite presents. `dui focus <n>` focuses
/// a window, `dui raise <n>` raises it to the top, `dui move <n> <x> <y>`
/// moves a user window (clamped on-scanout), `dui close <n>` releases a
/// user window, `dui list <pid>` filters the registry to one process's
/// windows, and `dui hit <x> <y>` hit-tests a point (focusing the topmost
/// window there).
fn cmd_dui(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "focus")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.focus(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("no such window");
                return .invalid_argument;
            }
            // The focus change may alter the clock's focus line — repaint.
            _ = driving_award.mark_dirty(0);
            _ = driving_award.mark_dirty(1);
            _ = driving_award.composite();
            m.console.puts("dui focus: focused=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "raise")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.raise(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("no such window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui raise: raised=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "lower")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id2 = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id2 > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.user_lower_back(@intCast(id2))) {
                err_prefix(m);
                m.console.print_line("no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui lower: lowered=");
            m.console.print_u64(id2);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "move")) {
            if (args.len != 4) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            const x = parseInt(args[2]) catch {
                err_prefix(m);
                m.console.print_line("invalid x");
                return .invalid_argument;
            };
            const y = parseInt(args[3]) catch {
                err_prefix(m);
                m.console.print_line("invalid y");
                return .invalid_argument;
            };
            if (id > 255 or x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) {
                err_prefix(m);
                m.console.print_line("coordinate out of range");
                return .invalid_argument;
            }
            if (!driving_award.user_move(@intCast(id), @intCast(x), @intCast(y))) {
                err_prefix(m);
                m.console.print_line("no such user window (the terminal + clock are fixed)");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui move: moved=");
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
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.user_close(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("no such user window (the terminal + clock are fixed)");
                return .invalid_argument;
            }
            // The close marked the fixed windows dirty — composite now to
            // reveal whatever sat under the released window.
            _ = driving_award.composite();
            m.console.puts("dui close: closed=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "list")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const pid = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid pid: ");
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
            m.console.puts("dui list: pid=");
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
        if (std.mem.eql(u8, args[0], "cycle")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            if (driving_award.cycle_focus()) |id| {
                m.console.puts("dui: cycle focused=");
                m.console.print_u64(id);
                m.console.puts("\n");
                return .none;
            }
            err_prefix(m);
            m.console.print_line("no window to cycle");
            return .invalid_argument;
        }
        if (std.mem.eql(u8, args[0], "hit")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const x = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.print_line("invalid x");
                return .invalid_argument;
            };
            const y = parseInt(args[2]) catch {
                err_prefix(m);
                m.console.print_line("invalid y");
                return .invalid_argument;
            };
            if (x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) {
                err_prefix(m);
                m.console.print_line("coordinate out of range");
                return .invalid_argument;
            }
            const hit = driving_award.hit_test(@intCast(x), @intCast(y));
            m.console.puts("dui hit: ");
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
        if (std.mem.eql(u8, args[0], "tile")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.focus(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("no such window");
                return .invalid_argument;
            }
            // The EL1h half of M21 W1's Ctrl+T chord: focus the window,
            // then toggle it floating <-> tiled (driving_award owns the
            // max-2 constraint and the layout math).
            driving_award.toggle_tiling();
            _ = driving_award.composite();
            m.console.puts("dui tile: id=");
            m.console.print_u64(id);
            m.console.puts(" mode=");
            m.console.puts(if (driving_award.tile_mode) "on" else "off");
            if (driving_award.tile_master_id) |mid| {
                m.console.puts(" master=");
                m.console.print_u64(mid);
            }
            if (driving_award.tile_stack_id) |sid| {
                m.console.puts(" stack=");
                m.console.print_u64(sid);
            }
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "master")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            // The EL1h half of M21 W2's Ctrl+M chord: swap master/detail
            // (a no-op unless two windows are tiled).
            driving_award.swap_master();
            _ = driving_award.composite();
            m.console.puts("dui master: side=");
            m.console.puts(if (driving_award.tile_master_side) "left" else "right");
            if (driving_award.tile_master_id) |mid| {
                m.console.puts(" master=");
                m.console.print_u64(mid);
            }
            if (driving_award.tile_stack_id) |sid| {
                m.console.puts(" stack=");
                m.console.print_u64(sid);
            }
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "minimize")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.minimize_window(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("minimize failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui minimize: minimized id=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "restore")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.restore_from_dock(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("restore failed: window not minimized or unknown");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui restore: restored id=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "maximize")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.toggle_maximize(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("maximize failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            const w = driving_award.find_user_window(@intCast(id));
            m.console.puts("dui maximize: id=");
            m.console.print_u64(id);
            m.console.puts(" max=");
            m.console.puts(if (w != null and w.?.maximized) "on" else "off");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "fullscreen")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.toggle_fullscreen(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("fullscreen failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui fullscreen: id=");
            m.console.print_u64(id);
            m.console.puts(" on=");
            m.console.puts(if (driving_award.fullscreen_active) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "aot")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.toggle_always_on_top(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("always-on-top failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            const w = driving_award.find_user_window(@intCast(id));
            m.console.puts("dui always-on-top: id=");
            m.console.print_u64(id);
            m.console.puts(" flag=");
            m.console.puts(if (w != null and w.?.always_on_top) "on" else "off");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "kmove")) {
            if (args.len != 4) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const dx = parseSignedInt(args[2]) catch return .invalid_argument;
            const dy = parseSignedInt(args[3]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.move_window_keyboard(@intCast(id), @intCast(dx), @intCast(dy))) {
                err_prefix(m);
                m.console.print_line("keyboard move failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui kmove: id=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "kresize")) {
            if (args.len != 4) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const dw = parseSignedInt(args[2]) catch return .invalid_argument;
            const dh = parseSignedInt(args[3]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.resize_window_keyboard(@intCast(id), @intCast(dw), @intCast(dh))) {
                err_prefix(m);
                m.console.print_line("keyboard resize failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui kresize: id=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "title")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.set_window_title(@intCast(id), args[2])) {
                err_prefix(m);
                m.console.print_line("title update failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui title: id=");
            m.console.print_u64(id);
            m.console.puts(" title=");
            m.console.puts(args[2]);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "modal")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const flag = parseInt(args[2]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.set_modal(@intCast(id), flag != 0)) {
                err_prefix(m);
                m.console.print_line("modal failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui modal: id=");
            m.console.print_u64(id);
            m.console.puts(" flag=");
            m.console.print_u64(flag);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "transient")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const timeout = parseInt(args[2]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.set_transient(@intCast(id), @intCast(timeout))) {
                err_prefix(m);
                m.console.print_line("transient failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui transient: id=");
            m.console.print_u64(id);
            m.console.puts(" timeout=");
            m.console.print_u64(timeout);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            driving_award.notify_push(args[1], 0);
            _ = driving_award.composite();
            m.console.puts("dui notif: pushed=");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif-center")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            driving_award.notif_center_toggle();
            _ = driving_award.composite();
            m.console.puts("dui notif-center: open=");
            m.console.puts(if (driving_award.notif_center_open) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif-center-state")) {
            // WMS6 Gate B (issue #626): a PURE state report (does not toggle)
            // — the live gate reads the panel's open/closed state after an
            // injected tray click to prove the shim (boot A) or the WM
            // (boot B) opened it.
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            m.console.puts("dui notif-center-state: open=");
            m.console.puts(if (driving_award.notif_center_open) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "tooltip-state")) {
            // WMS6 Gate C (issue #626): a PURE state report (does not change
            // anything) — the live gate reads the tooltip's visibility + text
            // after an injected hover to prove the WM showed it.
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            m.console.puts("dui tooltip-state: visible=");
            m.console.puts(if (driving_award.tooltip_visible) "yes" else "no");
            m.console.puts(" text=");
            m.console.puts(driving_award.tooltip_text[0..driving_award.tooltip_text_len]);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "tray-state")) {
            // WMS6 Gate E (issue #626): a PURE state report (does not change
            // anything) — the live gate reads the effective tray widget
            // content after the WM's TRAY decision to prove the WM's values
            // (not the shim's) are what renders.
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            m.console.puts("dui tray-state: clock=");
            m.console.puts(driving_award.wm_tray_clock_text[0..5]);
            m.console.puts(" clock_set=");
            m.console.puts(if (driving_award.wm_tray_clock_set) "yes" else "no");
            m.console.puts(" theme=");
            var tlet: [1]u8 = .{driving_award.wm_tray_theme};
            m.console.puts(tlet[0..1]);
            m.console.puts(" theme_set=");
            m.console.puts(if (driving_award.wm_tray_theme_set) "yes" else "no");
            m.console.puts(" clip=");
            m.console.puts(if (driving_award.wm_tray_clip) "yes" else "no");
            m.console.puts(" clip_set=");
            m.console.puts(if (driving_award.wm_tray_clip_set) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif-dismiss")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const idx = parseInt(args[1]) catch return .invalid_argument;
            const ok = driving_award.notif_center_dismiss(@intCast(idx));
            _ = driving_award.composite();
            m.console.puts("dui notif-dismiss: idx=");
            m.console.print_u64(idx);
            m.console.puts(" ok=");
            m.console.puts(if (ok) "1" else "0");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif-clear")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            driving_award.notif_center_clear_all();
            _ = driving_award.composite();
            m.console.puts("dui notif-clear: cleared\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "ws")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const ws = parseInt(args[1]) catch return .invalid_argument;
            if (ws > 2) return .invalid_argument;
            driving_award.switch_workspace(@intCast(ws));
            _ = driving_award.composite();
            m.console.puts("dui ws: workspace=");
            m.console.print_u64(ws);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "ws-cycle")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            driving_award.cycle_workspace();
            _ = driving_award.composite();
            m.console.puts("dui ws-cycle: workspace=");
            m.console.print_u64(driving_award.current_workspace);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "taskbar")) {
            // WM3 (issue #707 card 3): report the taskbar ENTRY enumeration
            // — the exact id-ascending current-workspace list the `.taskbar`
            // render walks (the render iterates the SAME taskbar_entries()
            // snapshot), so a live gate can grep what the bar draws.
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            _ = driving_award.composite();
            var tb: [driving_award.user_windows_max]driving_award.TaskbarEntry = undefined;
            const tn = driving_award.taskbar_entries(&tb);
            m.console.puts("dui taskbar: ws=");
            m.console.print_u64(driving_award.current_workspace);
            m.console.puts(" entries=");
            m.console.print_u64(tn);
            m.console.puts("\n");
            var ti: usize = 0;
            while (ti < tn) : (ti += 1) {
                m.console.puts("dui taskbar: entry=");
                m.console.print_u64(ti);
                m.console.puts(" id=");
                m.console.print_u64(tb[ti].id);
                m.console.puts(" focused=");
                m.console.print_u64(@intFromBool(tb[ti].focused));
                m.console.puts(" minimized=");
                m.console.print_u64(@intFromBool(tb[ti].minimized));
                m.console.puts("\n");
            }
            return .none;
        }
        if (std.mem.eql(u8, args[0], "unsaved")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const flag = parseInt(args[2]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            _ = driving_award.user_set_unsaved(@intCast(id), flag != 0);
            _ = driving_award.composite();
            m.console.puts("dui unsaved: id=");
            m.console.print_u64(id);
            m.console.puts(" flag=");
            m.console.print_u64(flag);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "dialog-show")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            driving_award.unsaved_dialog_show(@intCast(id));
            _ = driving_award.composite();
            m.console.puts("dui dialog-show: target=");
            m.console.print_u64(id);
            m.console.puts(" open=");
            m.console.puts(if (driving_award.unsaved_dialog_is_open()) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "dialog-click")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const choice = if (std.mem.eql(u8, args[1], "save"))
                driving_award.unsaved_dialog_click(640 - 100 + 40, 360 + 20)
            else if (std.mem.eql(u8, args[1], "dont_save") or std.mem.eql(u8, args[1], "discard"))
                driving_award.unsaved_dialog_click(640 - 100 + 110, 360 + 20)
            else
                driving_award.unsaved_dialog_click(640 - 100 + 175, 360 + 20);
            _ = driving_award.composite();
            m.console.puts("dui dialog-click: result=");
            m.console.puts(@tagName(choice));
            m.console.puts(" open=");
            m.console.puts(if (driving_award.unsaved_dialog_is_open()) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        print_usage(m, lookup("dui").?);
        return .usage;
    }
    if (!driving_award.armed()) {
        m.console.print_line("dui: window manager not armed (no gpu device — the default VM)");
        return .none;
    }
    m.console.puts("dui: windows=");
    m.console.print_u64(driving_award.count());
    m.console.puts(" focused=");
    m.console.print_u64(driving_award.focused_window_id());
    m.console.puts(" presents=");
    m.console.print_u64(driving_award.presents_pushed());
    // M33 SB6 (claim 6864): the composite-cost observables — user windows
    // the kernel blitted vs surface-backed windows skipped (WM-owned).
    m.console.puts(" blits=");
    m.console.print_u64(driving_award.user_blits);
    m.console.puts(" skips=");
    m.console.print_u64(driving_award.migrated_skips);
    m.console.puts("\n");
    // M21 W1/W2 tiling state (the layout the tiled rects obey).
    m.console.puts("dui: tiling=");
    m.console.puts(if (driving_award.tile_mode) "on" else "off");
    if (driving_award.tile_master_id) |mid| {
        m.console.puts(" master=");
        m.console.print_u64(mid);
    }
    if (driving_award.tile_stack_id) |sid| {
        m.console.puts(" stack=");
        m.console.print_u64(sid);
    }
    m.console.puts(" side=");
    m.console.puts(if (driving_award.tile_master_side) "left" else "right");
    m.console.puts("\n");
    var i: usize = 0;
    while (i < driving_award.count()) : (i += 1) {
        print_win_row(m, i, driving_award.window_at(i).?);
    }
    return .none;
}

/// Print one registry row for the window at index `i` — the shared formatter
/// behind the `dui` report and `dui list <pid>`. The trailing `owner=` column
/// is the per-process-ownership visibility (claim 0487 follow-on): a pid for a
/// `.user` window, `-` for the fixed kernel-owned terminal + clock.
fn print_win_row(m: *Monitor, i: usize, w: *const driving_award.Window) void {
    m.console.puts("dui[");
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
    if (w.minimized) m.console.puts(" minimized=1");
    if (w.maximized) m.console.puts(" maximized=1");
    if (w.always_on_top) m.console.puts(" aot=1");
    if (w.modal) m.console.puts(" modal=1");
    if (w.transient) m.console.puts(" transient=1");
    if (w.kind == .user) {
        m.console.puts(" ws=");
        m.console.print_u64(w.workspace);
        // M33 SB4 (claim 2382): the rect-granular damage observable for the
        // damage-tracking gate. `full` when no partial damage is pending
        // (whole-window), else the EXACT pending rect.
        m.console.puts(" damage=");
        if (w.damaged) {
            m.console.print_u64(w.dx);
            m.console.puts(",");
            m.console.print_u64(w.dy);
            m.console.puts(",");
            m.console.print_u64(w.dw);
            m.console.puts(",");
            m.console.print_u64(w.dh);
        } else {
            m.console.puts("full");
        }
        // M33 SB4: the LAST rect composite repainted (consumed damage) —
        // observable even after the drain. 0,0,0,0 = no partial repaint yet.
        m.console.puts(" last=");
        m.console.print_u64(w.last_dx);
        m.console.puts(",");
        m.console.print_u64(w.last_dy);
        m.console.puts(",");
        m.console.print_u64(w.last_dw);
        m.console.puts(",");
        m.console.print_u64(w.last_dh);
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
    if (args.len > 0 and std.mem.eql(u8, args[0], "bulk")) return cmd_usb_bulk(m, args);
    if (args.len > 0 and std.mem.eql(u8, args[0], "msc")) return cmd_usb_msc(m, args);
    // M70f F1 (issue #1458): the read-only FAT32 volume surface.
    if (args.len > 0 and std.mem.eql(u8, args[0], "vol")) return cmd_usb_vol(m, args);
    if (args.len > 0 and std.mem.eql(u8, args[0], "ls")) return cmd_usb_ls(m, args);
    if (args.len > 0 and std.mem.eql(u8, args[0], "cat")) return cmd_usb_cat(m, args);
    if (args.len > 0 and std.mem.eql(u8, args[0], "rescan")) return cmd_usb_rescan(m);
    if (args.len > 0 and std.mem.eql(u8, args[0], "detach")) return cmd_usb_detach(m, args);
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

/// `usb bulk` — the U1 bulk-engine report: the bulk endpoint state of every
/// enumerated device + the last completed bulk IN payload. The U1 probe's
/// evidence verb (no protocol above the engine — the bytes on the wire are
/// the ground truth).
fn cmd_usb_bulk(m: *Monitor, args: []const []const u8) ExecError {
    if (!xhci.xhci_ready) {
        m.console.puts("usb bulk: no XHCI device\n");
        return .none;
    }
    // Optional subcommand `probe <hex byte> ...`: one bulk OUT with the
    // given payload followed by one bulk IN, printed raw. U1 stays BELOW
    // the protocol level — the probe's job is to observe what the device
    // does with arbitrary bulk bytes (the raw evidence for the contract).
    if (args.len > 1 and std.mem.eql(u8, args[1], "probe")) {
        const slot_id = xhci.usb_bulk_dev();
        if (slot_id == 0) {
            m.console.puts("usb bulk probe: no bulk-capable device\n");
            return .none;
        }
        var payload: [xhci.bulk_buf_len]u8 = undefined;
        var plen: usize = 0;
        var i: usize = 2;
        while (i < args.len and plen < xhci.bulk_buf_len) : (i += 1) {
            const v = std.fmt.parseInt(u16, args[i], 0) catch continue;
            if (v > 0xff) continue;
            payload[plen] = @intCast(v);
            plen += 1;
        }
        if (plen == 0) {
            m.console.puts("usb bulk probe: usage: usb bulk probe <hex byte> ...\n");
            return .none;
        }
        const out = xhci.xhci_bulk_transfer(slot_id, false, &payload, @intCast(plen));
        m.console.puts("usb bulk probe: OUT cc=");
        m.console.print_hex(out.cc);
        m.console.puts(" sent=");
        m.console.print_u64(if (out.remaining <= plen) plen - out.remaining else 0);
        m.console.puts("\n");
        var inbuf: [xhci.bulk_buf_len]u8 = undefined;
        const rin = xhci.xhci_bulk_transfer(slot_id, true, &inbuf, xhci.bulk_buf_len);
        m.console.puts("usb bulk probe: IN cc=");
        m.console.print_hex(rin.cc);
        m.console.puts(" got=");
        const got: usize = if (rin.remaining <= xhci.bulk_buf_len) xhci.bulk_buf_len - rin.remaining else 0;
        m.console.print_u64(got);
        m.console.puts(" bytes=");
        var k: usize = 0;
        while (k < got) : (k += 1) {
            if (k > 0) m.console.puts(" ");
            m.console.print_hex_min(inbuf[k]);
        }
        m.console.puts("\n");
        return .none;
    }
    // The state report: one line per enumerated device.
    m.console.puts("usb bulk: devices=");
    m.console.print_u64(xhci.enum_count);
    m.console.puts("\n");
    var di: usize = 0;
    while (di < xhci.EnumMax) : (di += 1) {
        const d = xhci.enum_devs[di];
        if (!d.present) continue;
        m.console.puts("usb bulk: dev");
        m.console.print_u64(di);
        m.console.puts(" slot=");
        m.console.print_u64(d.slot_id);
        m.console.puts(" vid=");
        m.console.print_hex(d.vid);
        m.console.puts(" pid=");
        m.console.print_hex(d.pid);
        m.console.puts(" class=");
        m.console.print_hex(d.class);
        m.console.puts(" bulk=");
        m.console.puts(if (d.bulk_ready) "yes" else "no");
        m.console.puts(" maxpkt=");
        m.console.print_u64(d.bulk_maxpkt);
        m.console.puts(" out_ep=");
        m.console.print_u64(d.bulk_out_num);
        m.console.puts(" in_ep=");
        m.console.print_u64(d.bulk_in_num);
        m.console.puts("\n");
        if (d.bulk_ready and xhci.bulk_recv_len[di] > 0) {
            m.console.puts("usb bulk: last-in len=");
            m.console.print_u64(xhci.bulk_recv_len[di]);
            m.console.puts(" bytes=");
            var k: usize = 0;
            while (k < xhci.bulk_recv_len[di]) : (k += 1) {
                if (k > 0) m.console.puts(" ");
                m.console.print_hex_min(xhci.bulk_last_in(di)[k]);
            }
            m.console.puts("\n");
        }
    }
    return .none;
}

/// `usb msc` — the U2 (M43 card U2) probe-and-record verb: TEST UNIT READY,
/// INQUIRY, READ CAPACITY(10), then a deterministic 512-byte sector
/// write/read-back. Every field is the wire's honest answer (the [observed]
/// rows for docs/hardware-contract.md) — a refused write is recorded, not
/// faked. Optional LBA: `usb msc probe <lba>` (default 100, a gap sector).
fn cmd_usb_msc(m: *Monitor, args: []const []const u8) ExecError {
    if (!xhci.xhci_ready) {
        m.console.puts("usb msc: no XHCI device\n");
        return .none;
    }
    var lba: u32 = usb_msc.probe_default_lba;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "probe")) continue;
        lba = std.fmt.parseInt(u32, a, 0) catch lba;
    }
    const info = usb_msc.probe(lba);
    if (!info.present) {
        m.console.puts("usb msc: no bulk-capable device\n");
        return .none;
    }
    m.console.puts("usb msc: dev slot=");
    m.console.print_u64(info.slot);
    m.console.puts(" tur_status=");
    m.console.print_u64(info.tur.status);
    m.console.puts(" tur_ok=");
    m.console.print_u64(if (info.tur.ok) 1 else 0);
    m.console.puts(" tur_stage=");
    m.console.puts(botStageName(info.tur.stage));
    m.console.puts("\n");
    m.console.puts("usb msc: inquiry ok=");
    m.console.print_u64(if (info.inquiry_ok) 1 else 0);
    m.console.puts(" vendor=");
    m.console.puts(&info.inquiry.vendor);
    m.console.puts(" product=");
    m.console.puts(&info.inquiry.product);
    m.console.puts(" rev=");
    m.console.puts(&info.inquiry.rev);
    m.console.puts("\n");
    m.console.puts("usb msc: capacity ok=");
    m.console.print_u64(if (info.capacity_ok) 1 else 0);
    m.console.puts(" last_lba=");
    m.console.print_u64(info.capacity.last_lba);
    m.console.puts(" block_len=");
    m.console.print_u64(info.capacity.block_len);
    m.console.puts("\n");
    m.console.puts("usb msc: rw lba=");
    m.console.print_u64(info.rw_lba);
    m.console.puts(" byte=");
    m.console.print_hex_min(info.rw_byte);
    m.console.puts(" write_ok=");
    m.console.print_u64(if (info.rw_write.ok) 1 else 0);
    m.console.puts(" read_ok=");
    m.console.print_u64(if (info.rw_read.ok) 1 else 0);
    m.console.puts(" diff=");
    m.console.print_u64(info.rw_diff);
    m.console.puts(" ok=");
    m.console.print_u64(if (info.rw_ok) 1 else 0);
    m.console.puts(" write_stage=");
    m.console.puts(botStageName(info.rw_write.stage));
    m.console.puts(" read_stage=");
    m.console.puts(botStageName(info.rw_read.stage));
    m.console.puts("\n");
    return .none;
}

fn botStageName(s: usb_msc.Stage) []const u8 {
    return switch (s) {
        .none => "none",
        .cbw => "cbw",
        .data => "data",
        .csw => "csw",
        .csw_signature => "csw_sig",
        .csw_tag => "csw_tag",
    };
}

// ---------------------------------------------------------------------------
// M70f F1 (issue #1458): read-only FAT32 volumes on the M43 block seam.
//
// `usb vol` enumerates the MBR and reports each slot's volume geometry,
// `usb ls` lists a volume directory, and `usb cat` reads a file printing a
// bounded prefix plus the FULL byte count and an FNV-1a 32 of every byte. The
// checksum is what makes a byte-exact claim for a file too large to dump: the
// gate's host-side builder stages the content and pins the same value. Nothing
// here writes to the volume.
// ---------------------------------------------------------------------------

/// One sector scratch for the `usb cat` chain walk: the monitor console path is
/// single-threaded (one command at a time), so a static is safe here.
var usb_cat_sector: [fat32_ro.sector_len]u8 align(64) = undefined;

/// `usb cat` bounds. A print bound keeps the serial readable; the scan bound
/// keeps a bogus file size (the FAT's size field is a u32 an image author
/// controls) from holding the shell for hours of BOT round trips — 1 MiB is
/// 2048 sector transfers. A scan that stops at the cap says `capped=1`
/// rather than presenting a partial read as the whole file.
const usb_cat_max_print_bytes: u64 = 4096;
const usb_cat_max_bytes: u64 = 1 << 20;

fn printHexByte(m: *Monitor, b: u8) void {
    const digits = "0123456789abcdef";
    m.console.putc(digits[b >> 4]);
    m.console.putc(digits[b & 0xf]);
}

/// The BPB's 11-byte volume label, trailing padding trimmed (`-` when blank).
fn printVolumeLabel(m: *Monitor, label: [11]u8) void {
    var n: usize = label.len;
    while (n > 0 and (label[n - 1] == ' ' or label[n - 1] == 0)) n -= 1;
    if (n == 0) {
        m.console.puts("-");
        return;
    }
    m.console.puts(label[0..n]);
}

/// Accept both `1/PROBE.TXT` and `usb1/PROBE.TXT` spellings of a volume path.
fn canonicalVolumePath(buf: *[file_table.max_path_len]u8, arg: []const u8) ?[]const u8 {
    if (arg.len == 0 or arg.len > buf.len) return null;
    if (file_table.usbVolumeForm(arg) != null) {
        @memcpy(buf[0..arg.len], arg);
        return buf[0..arg.len];
    }
    if (arg[0] < '1' or arg[0] > '4') return null;
    if (arg.len > 1 and arg[1] != '/') return null;
    const need = arg.len + 3;
    if (need > buf.len) return null;
    @memcpy(buf[0..3], "usb");
    @memcpy(buf[3..need], arg);
    return buf[0..need];
}

const UsbVolume = struct {
    src: fat32_ro.SectorSource = .{ .ctx = null, .readFn = unusableSource },
    parsed: file_table.ParsedPath = .{ .partition = .usb_fat, .path = @as([file_table.max_path_len]u8, @splat(@as(u8, 0))), .path_len = 0 },
    vol: fat32_ro.Volume = .{},

    fn unusableSource(_: ?*anyopaque, _: u32, _: *[fat32_ro.sector_len]u8) bool {
        return false;
    }
};

/// Resolve `<vol>[/path]` down to a mounted volume. Every failure mode is a
/// printed line plus `null` — the caller prints nothing of its own, so the
/// transcript always says exactly why.
fn openUsbVolume(m: *Monitor, arg: []const u8, out: *UsbVolume) bool {
    var path_buf: [file_table.max_path_len]u8 = undefined;
    const canonical = canonicalVolumePath(&path_buf, arg) orelse {
        m.console.print_line("usb: path must be <vol>[/<dir>] or usb<vol>[/<dir>] with vol 1..4");
        return false;
    };
    const parsed = file_table.parse_path(canonical) orelse {
        m.console.print_line("usb: path is not a valid volume path");
        return false;
    };
    if (parsed.partition != .usb_fat) {
        m.console.print_line("usb: path is not a volume path");
        return false;
    }
    if (!xhci.xhci_ready or !usb_msc.present()) {
        m.console.print_line("usb: no bulk-capable device");
        return false;
    }
    const cap = usb_msc.capacity() orelse {
        m.console.print_line("usb: READ CAPACITY(10) failed");
        return false;
    };
    if (cap.block_len != usb_msc.block_len) {
        m.console.print_line("usb: device does not use 512-byte sectors");
        return false;
    }
    const src = usb_msc.source();
    const row = fat32_ro.partitionAt(src, parsed.usb_index) catch |err| {
        switch (err) {
            error.NoPartition => m.console.print_line("usb: no such MBR partition"),
            error.NoMbr => m.console.print_line("usb: no MBR (no 0xaa55 signature at LBA 0)"),
            else => m.console.print_line("usb: LBA 0 read failed"),
        }
        return false;
    };
    if (@as(u64, row.start_lba) + row.sectors > @as(u64, cap.last_lba) + 1) {
        m.console.print_line("usb: partition extends past the end of the device");
        return false;
    }
    out.vol = fat32_ro.mount(src, row.start_lba, row.sectors) catch |err| {
        m.console.puts("usb: partition ");
        m.console.print_u64(parsed.usb_index);
        m.console.puts(" is not a readable FAT32 volume (");
        m.console.puts(switch (err) {
            error.NotFat32 => "not-fat32",
            error.BadBpb => "bad-bpb",
            else => "read-error",
        });
        m.console.print_line(")");
        return false;
    };
    out.src = src;
    out.parsed = parsed;
    return true;
}

/// `usb vol [<n>]` — the MBR walk and each slot's FAT32 geometry. Three
/// distinct honest answers: an empty slot, a slot whose type is not FAT32, and
/// a slot that declares FAT32 but does not parse.
fn cmd_usb_vol(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    if (!xhci.xhci_ready) {
        m.console.print_line("usb vol: no XHCI device");
        return .none;
    }
    if (!usb_msc.present()) {
        m.console.print_line("usb vol: no bulk-capable device");
        return .none;
    }
    const src = usb_msc.source();
    var table: [fat32_ro.max_partitions]?fat32_ro.PartitionRow = .{ null, null, null, null };
    fat32_ro.readMbr(src, &table) catch |err| {
        switch (err) {
            error.NoMbr => m.console.print_line("usb vol: no MBR (no 0xaa55 signature at LBA 0)"),
            else => m.console.print_line("usb vol: LBA 0 read failed"),
        }
        return .none;
    };
    var populated: u64 = 0;
    for (table) |row| {
        if (row != null) populated += 1;
    }
    m.console.puts("usb vol: partitions=");
    m.console.print_u64(populated);
    m.console.puts("\n");
    for (table, 0..) |row, i| {
        if (row == null) {
            m.console.puts("usb vol: part=");
            m.console.print_u64(i + 1);
            m.console.puts(" absent\n");
            continue;
        }
        const r = row.?;
        m.console.puts("usb vol: part=");
        m.console.print_u64(i + 1);
        m.console.puts(" boot=");
        m.console.print_u64(if (r.bootable) 1 else 0);
        m.console.puts(" type=0x");
        printHexByte(m, r.part_type);
        m.console.puts(" start_lba=");
        m.console.print_u64(r.start_lba);
        m.console.puts(" sectors=");
        m.console.print_u64(r.sectors);
        if (!r.isFat32Type()) {
            m.console.puts(" fat=0 reason=type\n");
            continue;
        }
        const vol = fat32_ro.mount(src, r.start_lba, r.sectors) catch |err| {
            m.console.puts(" fat=0 reason=");
            m.console.print_line(switch (err) {
                error.NotFat32 => "bpb-not-fat32",
                error.BadBpb => "bpb-inconsistent",
                else => "read-error",
            });
            continue;
        };
        m.console.puts(" fat=1 label=");
        if (vol.has_label) printVolumeLabel(m, vol.label) else m.console.puts("-");
        m.console.puts(" cluster_bytes=");
        m.console.print_u64(vol.cluster_bytes);
        m.console.puts(" clusters=");
        m.console.print_u64(vol.cluster_count);
        m.console.puts(" root_cluster=");
        m.console.print_u64(vol.root_cluster);
        m.console.puts("\n");
    }
    return .none;
}

/// `usb ls <vol>[/<dir>]` — list a FAT32 directory (the volume root by
/// default). Names print whole; the frozen 40-byte `DirEntry` row the file ABI
/// hands to EL0 truncates at 31 bytes, which is stated in the docs, not hidden.
fn cmd_usb_ls(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len < 2) {
        m.console.print_line("usb ls: usage: usb ls <vol>[/<dir>]");
        return .invalid_argument;
    }
    var v = UsbVolume{};
    if (!openUsbVolume(m, args[1], &v)) return .invalid_argument;
    var dir: fat32_ro.Entry = undefined;
    fat32_ro.lookup(v.src, v.vol, v.parsed.path[0..v.parsed.parsed_len()], &dir) catch |err| {
        m.console.puts("usb ls: ");
        m.console.print_line(switch (err) {
            error.NotFound => "not found",
            error.NotDir => "a path component is not a directory",
            error.BadChain => "the directory chain is unusable",
            else => "read failed",
        });
        return .invalid_argument;
    };
    if (!dir.isDir()) {
        m.console.print_line("usb ls: is a file (use `usb cat`)");
        return .invalid_argument;
    }
    m.console.puts("usb ls: vol=");
    m.console.print_u64(v.parsed.usb_index);
    m.console.puts(" path=");
    if (v.parsed.parsed_len() == 0) m.console.puts("/") else m.console.puts(v.parsed.path[0..v.parsed.parsed_len()]);
    m.console.puts(" label=");
    if (v.vol.has_label) printVolumeLabel(m, v.vol.label) else m.console.puts("-");
    m.console.puts("\n");
    var iter = fat32_ro.dirIter(v.src, v.vol, dir.first_cluster);
    var n: u64 = 0;
    while (iter.next()) |e| {
        n += 1;
        m.console.puts("usb ls: ");
        m.console.puts(e.nameSlice());
        m.console.puts(" size=");
        m.console.print_u64(e.size);
        m.console.puts(" dir=");
        m.console.print_u64(if (e.isDir()) 1 else 0);
        m.console.puts(" cluster=");
        m.console.print_u64(e.first_cluster);
        m.console.puts(" attr=0x");
        printHexByte(m, e.attr);
        m.console.puts("\n");
    }
    m.console.puts("usb ls: entries=");
    m.console.print_u64(n);
    m.console.puts(" broken=");
    m.console.print_u64(if (iter.broken) 1 else 0);
    m.console.puts("\n");
    return .none;
}

/// `usb cat <vol>/<path> [<max-print>]` — read the file, print at most
/// `max-print` bytes (default 256, clamped to 4096), and always report the byte
/// count plus an FNV-1a 32 of every byte read. A short read (broken chain) is
/// reported as `broken=1` with the bytes actually obtained — never padded — and
/// a scan stopped by the 1 MiB bound reports `capped=1`.
fn cmd_usb_cat(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len < 2) {
        m.console.print_line("usb cat: usage: usb cat <vol>/<path> [<max-print>]");
        return .invalid_argument;
    }
    var max_print: u64 = 256;
    if (args.len > 2) max_print = std.fmt.parseInt(u64, args[2], 0) catch 256;
    if (max_print > usb_cat_max_print_bytes) max_print = usb_cat_max_print_bytes;
    var v = UsbVolume{};
    if (!openUsbVolume(m, args[1], &v)) return .invalid_argument;
    var e: fat32_ro.Entry = undefined;
    fat32_ro.lookup(v.src, v.vol, v.parsed.path[0..v.parsed.parsed_len()], &e) catch |err| {
        m.console.puts("usb cat: ");
        m.console.print_line(switch (err) {
            error.NotFound => "not found",
            error.NotDir => "a path component is not a directory",
            error.BadChain => "the directory chain is unusable",
            else => "read failed",
        });
        return .invalid_argument;
    };
    if (e.isDir()) {
        m.console.print_line("usb cat: is a directory (use `usb ls`)");
        return .invalid_argument;
    }
    m.console.puts("usb cat: vol=");
    m.console.print_u64(v.parsed.usb_index);
    m.console.puts(" path=");
    m.console.puts(v.parsed.path[0..v.parsed.parsed_len()]);
    m.console.puts(" size=");
    m.console.print_u64(e.size);
    m.console.puts("\n");
    var reader = fat32_ro.FileReader.init(v.vol, e);
    var buf: [256]u8 = undefined;
    var fnv = fat32_ro.Fnv{};
    var total: u64 = 0;
    var printed: u64 = 0;
    var ends_newline = true;
    while (total < usb_cat_max_bytes) {
        const want: usize = @intCast(@min(@as(u64, buf.len), usb_cat_max_bytes - total));
        const n = fat32_ro.readFile(v.src, &reader, buf[0..want], &usb_cat_sector);
        if (n == 0) break;
        fnv.update(buf[0..n]);
        total += n;
        var off: usize = 0;
        while (off < n and printed < max_print) {
            m.console.putc(buf[off]);
            ends_newline = buf[off] == '\n';
            off += 1;
            printed += 1;
        }
    }
    // A scan that stopped with bytes still claimed is a cap stop, not a clean
    // end — say so instead of presenting a partial read as the whole file.
    const capped = reader.remaining > 0 and !reader.broken;
    if (printed > 0 and !ends_newline) m.console.putc('\n');
    m.console.puts("usb cat: read=");
    m.console.print_u64(total);
    m.console.puts(" sum=");
    m.console.print_hex(fnv.digest());
    m.console.puts(" printed=");
    m.console.print_u64(printed);
    m.console.puts(" of ");
    m.console.print_u64(total);
    m.console.puts(" broken=");
    m.console.print_u64(if (reader.broken) 1 else 0);
    m.console.puts(" capped=");
    m.console.print_u64(if (capped) 1 else 0);
    m.console.puts("\n");
    return .none;
}

/// `usb rescan` — the U4 (M43 card U4) polled lifecycle rescan: diff PORTSC
/// CCS against the registry, enumerate arrivals with the boot path, quiesce
/// removals, reattach quiesced entries whose port still reports connected.
/// One observability row; the arrival path touches hardware like boot does.
fn cmd_usb_rescan(m: *Monitor) ExecError {
    if (!xhci.xhci_ready) {
        m.console.puts("usb rescan: no XHCI device\n");
        return .none;
    }
    const r = xhci.xhci_rescan();
    m.console.puts("usb rescan: added=");
    m.console.print_u64(r.added);
    m.console.puts(" removed=");
    m.console.print_u64(r.removed);
    m.console.puts(" reattached=");
    m.console.print_u64(r.reattached);
    m.console.puts(" count=");
    m.console.print_u64(r.count);
    m.console.puts(" rescans=");
    m.console.print_u64(xhci.rescan_count);
    m.console.puts("\n");
    return .none;
}

/// `usb detach [slot]` — the U4 administrative detach: quiesce the device so
/// every consumer fails cleanly (bulk refuses, BOT fails stage=cbw, `.usb`
/// is ENOENT, HID drain skips) instead of ghosting. No argument detaches the
/// bulk device (the lifecycle spec's subject); a numeric argument names the
/// slot. The HC slot, contexts, and rings stay allocated — a later `usb
/// rescan` with the port still connected reattaches the same entry.
fn cmd_usb_detach(m: *Monitor, args: []const []const u8) ExecError {
    if (!xhci.xhci_ready) {
        m.console.puts("usb detach: no XHCI device\n");
        return .none;
    }
    if (args.len > 1) {
        const slot: u8 = std.fmt.parseInt(u8, args[1], 0) catch {
            m.console.puts("usb detach: usage: usb detach [slot]\n");
            return .none;
        };
        if (slot == 0 or slot > xhci.EnumMax) {
            m.console.puts("usb detach: slot=");
            m.console.print_u64(slot);
            m.console.puts(" not present\n");
            return .none;
        }
        const idx: usize = slot - 1;
        const port = xhci.enum_devs[idx].port;
        if (!xhci.xhci_detach_slot(slot)) {
            m.console.puts("usb detach: slot=");
            m.console.print_u64(slot);
            m.console.puts(" not present\n");
            return .none;
        }
        m.console.puts("usb detach: slot=");
        m.console.print_u64(slot);
        m.console.puts(" port=");
        m.console.print_u64(port);
        m.console.puts(" ok=1\n");
        return .none;
    }
    const slot = xhci.xhci_detach_bulk();
    if (slot == 0) {
        m.console.puts("usb detach: no bulk-capable device\n");
        return .none;
    }
    const port = xhci.enum_devs[slot - 1].port;
    m.console.puts("usb detach: slot=");
    m.console.print_u64(slot);
    m.console.puts(" port=");
    m.console.print_u64(port);
    m.console.puts(" ok=1\n");
    return .none;
}

fn cmd_repeat(m: *Monitor, args: []const []const u8) ExecError {
    const count = parseInt(args[0]) catch {
        err_prefix(m);
        m.console.puts("invalid count: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (count < 1 or count > repeat_max_count) {
        err_prefix(m);
        m.console.puts("count must be between 1 and ");
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
        err_prefix(m);
        m.console.puts("output too large (max ");
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

/// `sh` — M18 T16 (issue #419): registered here for discovery (help,
/// tab completion, usage shape). Actual script execution lives in the
/// interactive shell (`shell.zig` intercepts `sh` before this registry
/// is reached, because scripts must execute through the shell's
/// handle_line). Direct `monitor.exec` of `sh` — host tests only — gets
/// an honest refusal rather than a silent no-op.
/// `type` — M19 P1 (issue #290). The real work is a shell builtin
/// (intercepted before monitor.exec); this registry entry exists for
/// help/usage/completion discovery and refuses direct execution the same
/// way `cmd_sh` does.
fn cmd_type(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    err_prefix(m);
    m.console.print_line("type: echoes the pipe source; use it as the right half of `a | type`");
    return .invalid_argument;
}

fn cmd_sh(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    // ADR 0008 D3 shape 2: a refusal wears the `error:` prefix.
    err_prefix(m);
    m.console.print_line("sh: script execution runs through the interactive shell");
    return .invalid_argument;
}

/// `settings` — report and modify persistent configuration (claim 2649,
/// milestone eight card U8). Backed by `SETTINGS.TXT` on the DATA partition.
/// `settings` / `settings list`: print all active key-value pairs.
/// `settings get <key>`: look up a single key.
/// `settings set <key> <val>`: update in memory and persist immediately.
/// `settings reset`: restore default settings and persist.
fn cmd_settings(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "list"))) {
        m.console.print_line("settings:");
        var i: usize = 0;
        while (i < settings.count()) : (i += 1) {
            if (settings.entry_at(i)) |e| {
                m.console.linef("  {s}={s}\n", .{ e.key, e.val });
            }
        }
        return .none;
    }
    if (std.mem.eql(u8, args[0], "get")) {
        if (args.len != 2) {
            print_usage(m, lookup("settings").?);
            return .usage;
        }
        if (settings.get(args[1])) |val| {
            m.console.linef("settings: {s}={s}\n", .{ args[1], val });
            return .none;
        }
        err_prefix(m);
        m.console.puts("unknown setting: ");
        m.console.puts(args[1]);
        m.console.puts("\n");
        return .invalid_argument;
    }
    if (std.mem.eql(u8, args[0], "set")) {
        if (args.len != 3) {
            print_usage(m, lookup("settings").?);
            return .usage;
        }
        const key = args[1];
        const val = args[2];
        const res = settings.set(key, val);
        if (res != .ok) {
            err_prefix(m);
            m.console.puts("invalid setting key or value: ");
            m.console.puts(key);
            m.console.puts("\n");
            return .invalid_argument;
        }
        const saved = settings.save_to_share();
        // #2649: ONE write — live-shell-default greps `settings: k=v (persisted)`.
        m.console.linef("settings: {s}={s} ({s})\n", .{ key, val, if (saved) "persisted" else "memory only" });
        return .none;
    }
    if (std.mem.eql(u8, args[0], "reset")) {
        if (args.len != 1) {
            print_usage(m, lookup("settings").?);
            return .usage;
        }
        settings.reset();
        const saved = settings.save_to_share();
        m.console.linef("settings: reset to defaults ({s})\n", .{if (saved) "persisted" else "memory only"});
        return .none;
    }
    print_usage(m, lookup("settings").?);
    return .usage;
}

/// `secrets` — list the secret store's key NAMES only (M50 TS5, issue
/// #1139, ADR 0024 D8). Values NEVER leave the store through this command
/// (the monitor may print names only), and the command never mutates — the
/// store is host-provisioned; there is no `sys_secret_set`.
fn cmd_secrets(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("secrets").?);
        return .usage;
    }
    const n = secret.count();
    if (n == 0) {
        m.console.print_line("secrets: (none)");
        return .none;
    }
    m.console.print_line("secrets:");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (secret.entry_at(i)) |e| {
            m.console.puts("  ");
            m.console.puts(e.key); // NAMES only — never values
            m.console.puts("\n");
        }
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
    m.console.print_line("shutdown: initiating graceful shutdown...");

    // Step 1: Post WIN_CLOSE event to every user window (apps can save
    // via the unsaved dialog from #242). The window stays alive until
    // the process exits or is killed below.
    m.console.print_line("shutdown: closing windows...");
    var i: usize = 0;
    while (i < process.max_processes) : (i += 1) {
        if (process.info(@intCast(i))) |info| {
            if (info.state == .running and info.task_id != null) {
                // Post WIN_CLOSE to each user window owned by this process.
                const pid_val: usize = @intCast(info.id);
                var win_id: u8 = driving_award.user_window_id_base;
                while (win_id < driving_award.user_window_id_base + @as(u8, @intCast(driving_award.user_windows_max))) : (win_id += 1) {
                    if (driving_award.user_owner(win_id)) |owner| {
                        if (owner == pid_val) {
                            events.push(pid_val, .{
                                .kind = events.WIN_CLOSE,
                                .flags = 0,
                                .seq = 0,
                                .arg0 = win_id,
                                .arg1 = 0,
                            });
                        }
                    }
                }
            }
        }
    }

    // Step 2: Wait 50 scheduler ticks (~5 seconds) for graceful exit
    m.console.print_line("shutdown: waiting for apps (50 ticks)...");
    _ = scheduler.sleep_current(50);

    // Step 3: Forcibly kill any remaining user processes
    m.console.print_line("shutdown: killing remaining processes...");
    i = 0;
    while (i < process.max_processes) : (i += 1) {
        if (process.info(@intCast(i))) |info| {
            if (info.state == .running) {
                _ = scheduler.request_kill(@intCast(i));
            }
        }
    }

    // Step 4: Flush clipboard to /data/clipboard.txt (persistence across reboot)
    m.console.print_line("shutdown: flushing clipboard...");
    flush_clipboard_to_disk();

    // Step 5: Write shutdown marker to /data/SHUTDOWN.TXT with tick + reason
    m.console.print_line("shutdown: writing marker...");
    write_shutdown_marker("graceful");

    // Step 6: Halt the CPU (WFI loop — no return)
    m.console.print_line("shutdown: halting...");
    return report_machine(m, "shutdown", m.machine.shutdown());
}

/// Write shutdown marker to SHUTDOWN.TXT on the HOST SHARE (M34 HF6,
/// issue #740: the DATA partition is gone). `reason` is a short label
/// ("graceful", "reboot", etc.).
fn write_shutdown_marker(reason: []const u8) void {
    if (!virtio_file.available()) return;

    // Format marker content: tick count + reason
    var buf: [128]u8 = undefined;
    var pos: usize = 0;

    const header = "VirelaiOS Shutdown\n";
    @memcpy(buf[0..header.len], header);
    pos = header.len;

    const tick_prefix = "Tick: ";
    @memcpy(buf[pos..][0..tick_prefix.len], tick_prefix);
    pos += tick_prefix.len;
    pos += write_u64_to(buf[pos..], timer.ticks);
    buf[pos] = '\n';
    pos += 1;

    const reason_prefix = "Reason: ";
    @memcpy(buf[pos..][0..reason_prefix.len], reason_prefix);
    pos += reason_prefix.len;
    const rlen = @min(reason.len, buf.len - pos);
    @memcpy(buf[pos..][0..rlen], reason[0..rlen]);
    pos += rlen;
    buf[pos] = '\n';
    pos += 1;

    // M50 TS2 (ADR 0024 D4): the kernel-actor gate (secret paths deny).
    if (!kernel_vf_allowed("SHUTDOWN.TXT", .write)) return;
    _ = virtio_file.write_whole("SHUTDOWN.TXT", buf[0..pos]);
}

/// Flush the shared clipboard to clipboard.txt on the HOST SHARE for
/// persistence across reboot (Arc5 #244; HF6 moved it from /data).
fn flush_clipboard_to_disk() void {
    if (!virtio_file.available()) return;
    const clip_len = clipboard.current_len();
    if (clip_len == 0) return;
    var buf: [clipboard.capacity]u8 = undefined;
    const n = clipboard.get(&buf);
    if (n == 0) return;
    // M50 TS2 (ADR 0024 D4): the kernel-actor gate (secret paths deny).
    if (!kernel_vf_allowed("clipboard.txt", .write)) return;
    _ = virtio_file.write_whole("clipboard.txt", buf[0..n]);
}

fn write_u64_to(out: []u8, val: u64) usize {
    if (val == 0) {
        if (out.len > 0) out[0] = '0';
        return 1;
    }
    var buf: [20]u8 = undefined;
    var v = val;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        buf[len] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    var i: usize = 0;
    while (i < len and i < out.len) : (i += 1) {
        out[i] = buf[len - 1 - i];
    }
    return @min(len, out.len);
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

/// Fixed Sexiburger mascot art (Milestone 19, issue #677).
/// Sexipus wearing a 6-layer burger with 6 tentacles, under the Covenant of Six.
var sexiburger_diag_storage: [14][]const u8 = undefined;
var sexiburger_diag_ready = false;
pub fn sexiburger_lines() []const []const u8 {
    if (!sexiburger_diag_ready) {
        sexiburger_diag_storage[0] = "           .-------.";
        sexiburger_diag_storage[1] = "          /  *   *  \\    [Crown: System]";
        sexiburger_diag_storage[2] = "        (  .  *   .   ) ";
        sexiburger_diag_storage[3] = "     (~~~\\___________/~~~) [Lettuce: Apps]";
        sexiburger_diag_storage[4] = "      \\   [=========]   /  [Tomato: Active app]";
        sexiburger_diag_storage[5] = "       \\   (=======)   /   [Cheese: Windows & tabs]";
        sexiburger_diag_storage[6] = "        \\  |=======|  /    [Patty: Services]";
        sexiburger_diag_storage[7] = "      __ \\ \\_______/ / __  [Heel: Power]";
        sexiburger_diag_storage[8] = "     (  \\ \\_|_|_|_|_/ /  )";
        sexiburger_diag_storage[9] = "      \\  \\___     ___/  /";
        sexiburger_diag_storage[10] = "       )  (  |   |  )  (";
        sexiburger_diag_storage[11] = "      /  /   |   |   \\  \\";
        sexiburger_diag_storage[12] = "     (_ /    |   |    \\ _)";
        sexiburger_diag_storage[13] = "  [6 tentacles | 6 layers | Covenant invariant intact]";
        sexiburger_diag_ready = true;
    }
    return &sexiburger_diag_storage;
}

// ---------------------------------------------------------------------------
// Last-words recorder command (#1278)
// ---------------------------------------------------------------------------

/// `forensics [on|off|dump|reset]` — the last-words recorder (claim #1278).
///
/// Off by default on purpose: a default boot must be byte-identical, so the
/// recorder is only ever armed by a gate (or a human) that is chasing
/// exactly the kind of death that reports nothing.
fn cmd_forensics(m: *Monitor, args: []const []const u8) ExecError {
    const sub = if (args.len > 0) args[0] else "status";
    if (std.mem.eql(u8, sub, "on")) {
        forensics.enabled = true;
        // Record this very line's arrival, so the trace opens with a mark the
        // reader can anchor on rather than an ambiguous empty prefix.
        forensics.note(.shot, 1);
        m.console.puts("forensics: on (records prefix the next console line)\n");
        return .none;
    }
    if (std.mem.eql(u8, sub, "off")) {
        forensics.enabled = false;
        m.console.puts("forensics: off\n");
        return .none;
    }
    if (std.mem.eql(u8, sub, "reset")) {
        forensics.reset();
        m.console.puts("forensics: reset\n");
        return .none;
    }
    if (std.mem.eql(u8, sub, "dump")) {
        // Force the pending tail out even with recording off, so the last
        // capture can be read after the fact.
        var buf: [forensics.max_per_drain * 64]u8 = undefined;
        const n = forensics.format_pending(buf[0..]);
        m.console.puts("forensics: dump wrote=");
        m.console.print_u64(n);
        m.console.puts("\n");
        if (n > 0) m.console.puts(buf[0..n]);
        return .none;
    }
    m.console.puts("forensics: enabled=");
    m.console.print_u64(if (forensics.enabled) 1 else 0);
    m.console.puts(" pending=");
    m.console.print_u64(forensics.pending());
    m.console.puts(" emitted=");
    m.console.print_u64(forensics.emitted);
    m.console.puts(" truncated=");
    m.console.print_u64(forensics.truncated);
    m.console.puts("\n");
    return .none;
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
    // WMP card 3 (#1274): the reschedule DEMAND. `requests` counts wakes that
    // became runnable while another task was executing — i.e. how often the 1 Hz
    // period tick is the only thing standing between a woken task and running;
    // `coalesced` is the surplus a wake burst absorbed rather than arming again;
    // `discharged` counts the rotations that served one. Nothing here pulls the
    // comparator — these are the numbers that say what such a pull would buy.
    m.console.puts(" resched_requests=");
    m.console.print_u64(scheduler.resched_requests);
    m.console.puts(" resched_coalesced=");
    m.console.print_u64(scheduler.resched_coalesced);
    m.console.puts(" resched_discharged=");
    m.console.print_u64(scheduler.resched_discharged);
    m.console.puts(" acked=");
    m.console.print_u64(gic.acked_total()); // claim 7339: summed across cores
    m.console.puts(" first=");
    m.console.print_hex_min(gic.first_intid[0]); // PE-0 first (SPIs are IROUTER-pinned there)
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

fn cmd_smp(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    // M70b (#1454): every line below is built into one buffer and written
    // once (the claim-881-slice-4 rule) — with wake targeting, secondary
    // cores print concurrently with the monitor, and a split line is
    // exactly what the live gates' per-core placement asserts grep for.
    var online_count: u64 = 0;
    var c: usize = 0;
    while (c < smp.max_cores) : (c += 1) {
        if (smp.core_online[c]) online_count += 1;
    }
    var buf: [160]u8 = undefined;
    m.console.puts(std.fmt.bufPrint(&buf, "smp: cores={d} online={d}\n", .{ smp.num_cores, online_count }) catch return .not_implemented);

    c = 0;
    while (c < smp.max_cores) : (c += 1) {
        if (c >= smp.num_cores and !smp.core_online[c]) continue;
        const cur_tid = scheduler.current_task_for_core(c);
        // The primary exec task has the generic TCB name "user-exec";
        // threads already carry the process name. Report the same identity
        // for either executor, independently of the scheduler report drain.
        const process_name: ?[]const u8 = if (process.find_by_task(cur_tid)) |pid|
            if (process.info(pid)) |info| info.name else null
        else
            null;
        const task_name = if (process_name) |name|
            name
        else if (scheduler.task_info(cur_tid)) |info|
            info.name
        else
            "none";
        const line = std.fmt.bufPrint(&buf, "  core {d}: {s} mpidr=0x{x:0>16} state={s} ticks={d} task={s}\n", .{
            c,
            if (c == 0) @as([]const u8, "bsp ") else @as([]const u8, "ap  "),
            smp.core_mpidr[c],
            if (smp.core_online[c]) @as([]const u8, "online") else @as([]const u8, "offline"),
            smp.core_ticks[c], // per-core tick counter (claim 8477 follow-up)
            task_name,
        }) catch return .not_implemented;
        m.console.puts(line);
    }
    // M70b (#1454): contention evidence for the wake/TCB sched_lock —
    // observed data read at the measurement point, never a threshold.
    m.console.puts(std.fmt.bufPrint(&buf, "smp: sched-lock acquires={d} contended={d} spins={d}\n", .{ scheduler.sched_lock_acquires, scheduler.sched_lock_contended, scheduler.sched_lock_spins }) catch return .not_implemented);
    // M70b (#1454): wake-placement evidence — of all blocked->ready
    // transitions, how many stayed on the calling core, how many landed
    // on a remote (targeted) ring, and how many of those nudged a parked
    // target with the RESCHEDULE SGI.
    m.console.puts(std.fmt.bufPrint(&buf, "smp: wakes={d} local={d} remote={d} nudges={d}\n", .{ scheduler.wake_local + scheduler.wake_remote, scheduler.wake_local, scheduler.wake_remote, scheduler.wake_nudges }) catch return .not_implemented);
    // M133b (#2756): per-task tick attribution + aging state. The
    // scheduler charges each core tick to that core's `current`; the
    // `run=` delta between two `smp` reads is the task's measured share
    // of the window, and `decay=`/`skip=` show the aging penalty the
    // claim scan applies. The hog-share leg diffs these rows.
    var i: usize = 0;
    while (i < scheduler.max_tasks) : (i += 1) {
        const info = scheduler.task_info(i) orelse continue;
        const run_name: []const u8 = if (process.find_by_task(i)) |pid|
            if (process.info(pid)) |pinfo| pinfo.name else info.name
        else
            info.name;
        m.console.puts(std.fmt.bufPrint(&buf, "smp: run task={d} name={s} ticks={d} decay={d} skip={d}\n", .{
            i, run_name, info.run_ticks, info.age_penalty, info.age_skip,
        }) catch return .not_implemented);
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
    // Opt-in diagnostic: leave the catalog, help and ordinary table byte-exact.
    if (args.len > 0) return cmd_runtime_receipt(m, args);
    var buf: [256]u8 = undefined;
    m.console.puts(std.fmt.bufPrint(&buf, "procs: count={d}\n", .{process.count()}) catch return .not_implemented);
    var id: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        const info = process.info(id) orelse continue;
        var task_buf: [20]u8 = undefined;
        var exit_buf: [20]u8 = undefined;
        // Claim 4613: an exited process keeps its executor slot until the
        // lifecycle reap frees its pages — the row still reads `reaped`
        // (the slot is a zombie, no longer executing the program).
        const task_text = if (info.state == .exited)
            @as([]const u8, "reaped")
        else if (info.task_id) |task_id|
            std.fmt.bufPrint(&task_buf, "{d}", .{task_id}) catch return .not_implemented
        else
            "-";
        const exit_text = if (info.state == .exited)
            std.fmt.bufPrint(&exit_buf, "{d}", .{info.exit_status}) catch return .not_implemented
        else
            "-";
        m.console.puts(std.fmt.bufPrint(&buf, "procs: id={d} name={s} uid={d} caps={d} state={s} task={s} stack=0x{x:0>16} exit={s}\n", .{
            info.id,   info.name,     info.uid,  info.caps, process.state_name(info.state),
            task_text, info.stack_va, exit_text,
        }) catch return .not_implemented);
    }
    return .none;
}

/// `procs receipt [pid|name]` reads live or retained final counters. One
/// kernel-domain hold covers identity, counters and reap state, matching the
/// update paths. Live rows always have reaped=0, even if the primary task
/// exited before its siblings. Retention is bounded by procs history.
fn cmd_runtime_receipt(m: *Monitor, args: []const []const u8) ExecError {
    if (!std.mem.eql(u8, args[0], "receipt")) {
        print_usage(m, lookup("procs").?);
        return .usage;
    }
    const taken = svclock.acquire_missing(svclock.dom_bit(.kernel));
    defer svclock.release_set(taken);
    var found = false;
    var id: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        const info = process.info(id) orelse continue;
        if (args.len == 2) {
            const matches = if (parseInt(args[1])) |pid|
                pid == id
            else |_|
                std.mem.eql(u8, args[1], info.name);
            if (!matches) continue;
        }
        const receipt = process.runtime_receipt(id) orelse continue;
        var buf: [384]u8 = undefined;
        m.console.puts(std.fmt.bufPrint(&buf, "runtime-receipt: pid={d} name={s} peak_pages={d} page_cap={d} peak_regions={d} region_cap={d} static_pages={d} page_tracking=extensible page_saturated={d} total_pages={d} record_failures={d} unrecorded_pages=0 reaped={d}\n", .{
            id,                                                           info.name,
            receipt.peak_pages,                                           process.max_dynamic_pages,
            receipt.peak_regions,                                         process.max_mmap_regions,
            receipt.static_pages,                                         @intFromBool(receipt.peak_pages >= process.max_dynamic_pages),
            receipt.total_pages,                                          receipt.record_failures,
            @intFromBool(info.state == .exited and info.task_id == null),
        }) catch return .not_implemented);
        found = true;
    }
    if (!found) m.console.print_line("runtime-receipt: none");
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
        err_prefix(m);
        m.console.puts("no such process: ");
        m.console.puts(arg);
        m.console.puts("\n");
        return .invalid_argument;
    };
    const info = process.info(pid_value).?;
    if (info.state == .exited) {
        err_prefix(m);
        m.console.puts(info.name);
        m.console.puts(" already exited\n");
        return .invalid_argument;
    }
    // A created-but-unbound process (exec's pre-spawn window) has no
    // executor to terminate; a running process names its executor slot.
    const task_id = info.task_id orelse {
        err_prefix(m);
        m.console.puts(info.name);
        m.console.puts(" not running\n");
        return .invalid_argument;
    };
    switch (scheduler.request_kill(task_id)) {
        .ok => {
            // The transport locks each write, not the whole command.
            // Process names are bounded by name_max; include the newline
            // in the same write so another core cannot split this receipt.
            var buf: ["kill: ".len + process.name_max + " armed\n".len]u8 = undefined;
            m.console.puts(std.fmt.bufPrint(&buf, "kill: {s} armed\n", .{info.name}) catch return .not_implemented);
            return .none;
        },
        .not_found => {
            err_prefix(m);
            m.console.puts(info.name);
            m.console.puts(" not found\n");
            return .invalid_argument;
        },
        .already_exited => {
            err_prefix(m);
            m.console.puts(info.name);
            m.console.puts(" already exited\n");
            return .invalid_argument;
        },
        .refused => {
            err_prefix(m);
            m.console.print_line("cannot kill the shell or scheduler-owned idle task");
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
            err_prefix(m);
            m.console.puts("mbox: invalid pid: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (value >= process.max_processes or process.info(@as(usize, @intCast(value))) == null) {
            err_prefix(m);
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
        if (std.mem.eql(u8, args[0], "dns")) return cmd_net_dns(m, args[1..]);
        if (std.mem.eql(u8, args[0], "ip6")) return cmd_net_ip6(m, args[1..]);
        if (std.mem.eql(u8, args[0], "ndp")) return cmd_net_ndp(m, args[1..]);
        if (std.mem.eql(u8, args[0], "ping6")) return cmd_net_ping6(m, args[1..]);
        if (std.mem.eql(u8, args[0], "udp6")) return cmd_net_udp6(m, args[1..]);
        if (std.mem.eql(u8, args[0], "status")) return cmd_net_status(m, args[1..]);
        if (std.mem.eql(u8, args[0], "route")) return cmd_net_route(m, args[1..]);
        if (std.mem.eql(u8, args[0], "log")) return cmd_net_log(m, args[1..]);
        print_usage(m, lookup("net").?);
        return .usage;
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
        .listen => "listen",
        .syn_sent => "syn_sent",
        .syn_received => "syn_received",
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
    // Milestone 12 Card N2 (claim 7566): DNS resolver counters
    m.console.puts(" dns=");
    m.console.puts(switch (dns.state) {
        .idle => "idle",
        .query_sent => "query_sent",
        .resolved => "resolved",
        .failed => "failed",
    });
    m.console.puts(",q=");
    m.console.print_u64(dns.queries_sent);
    m.console.puts(",r=");
    m.console.print_u64(dns.responses_recv);
    m.console.puts(",err=");
    m.console.print_u64(dns.responses_err);
    m.console.puts(",timeout=");
    m.console.print_u64(dns.timed_out);
    m.console.puts("\n");
    // M117b (#2474, ADR 0057 D13): the v6 layer — the address set, the
    // router + on-link records, the NDP and ICMPv6 counters. Appended
    // under the standing append-only convention — existing substring
    // asserts stay green.
    virtio_net.ndp.now_ticks = timer.ticks;
    net_ndp_autonomous(m); // promote/conflict transitions print even here
    m.console.puts(" v6=ll=");
    print_ip6_or_dash(m, virtio_net.ipv6.link_local, virtio_net.ipv6.link_local_state != .none);
    m.console.puts(",g6=");
    print_ip6_or_dash(m, virtio_net.ipv6.global, virtio_net.ipv6.global_state != .none);
    m.console.puts(",rt=");
    print_ip6_or_dash(m, virtio_net.ipv6.router_addr, virtio_net.ipv6.router_valid);
    m.console.puts(",onl=");
    if (virtio_net.ipv6.onlink_valid) {
        var pbuf: [39]u8 = undefined;
        const pn = virtio_net.ipv6.format_ip6(virtio_net.ipv6.onlink_prefix, &pbuf);
        m.console.puts(pbuf[0..pn]);
        m.console.puts("/");
        m.console.print_u64(virtio_net.ipv6.onlink_len);
    } else {
        m.console.puts("-");
    }
    m.console.puts("\n");
    m.console.puts(" ndp=rs=");
    m.console.print_u64(virtio_net.ndp.rs_sent);
    m.console.puts(",dad=");
    m.console.print_u64(virtio_net.ndp.dad_sent);
    m.console.puts(",dadc=");
    m.console.print_u64(virtio_net.ndp.dad_conflicts);
    m.console.puts(",ra=");
    m.console.print_u64(virtio_net.ndp.ra_accepted);
    m.console.puts(",for=");
    m.console.print_u64(virtio_net.ndp.ra_foreign);
    m.console.puts(",mal=");
    m.console.print_u64(virtio_net.ndp.ra_malformed);
    m.console.puts(",opt=");
    m.console.print_u64(virtio_net.ndp.opt_skipped);
    m.console.puts(",ns=");
    m.console.print_u64(virtio_net.ndp.ns_sent);
    m.console.puts(",na=");
    m.console.print_u64(virtio_net.ndp.na_sent);
    m.console.puts(",learn=");
    m.console.print_u64(virtio_net.ndp.learned);
    m.console.puts(",unsol=");
    m.console.print_u64(virtio_net.ndp.na_unsolicited);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.ndp.ndp_drop + virtio_net.ndp.rs_dropped);
    m.console.puts(",redir=");
    m.console.print_u64(virtio_net.ndp.redirect_dropped);
    m.console.puts(",fail=");
    m.console.print_u64(virtio_net.ndp.reply_tx_fail);
    m.console.puts("\n");
    m.console.puts(" icmp6=req=");
    m.console.print_u64(virtio_net.ipv6.requests_sent);
    m.console.puts(",repl=");
    m.console.print_u64(virtio_net.ipv6.replies_sent);
    m.console.puts(",pong=");
    m.console.print_u64(virtio_net.ipv6.pongs_observed);
    m.console.puts(",err=");
    m.console.print_u64(virtio_net.ipv6.icmp6_err);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.ipv6.dropped_short + virtio_net.ipv6.dropped_len + virtio_net.ipv6.dropped_nexthdr + virtio_net.ipv6.dropped_dst + virtio_net.ipv6.dropped_checksum + virtio_net.ipv6.dropped_proto + virtio_net.ipv6.dropped_type);
    m.console.puts(",fail=");
    m.console.print_u64(virtio_net.ipv6.reply_tx_fail);
    m.console.puts(",seq=");
    m.console.print_u64(virtio_net.ipv6.last_seq);
    m.console.puts("\n");
    // M117c (#2475): the v6 UDP row — family-tagged counters so a
    // `udp6=` fragment names the family's own traffic (the v4 ` udp=`
    // row above stays byte-identical for a guest that never sees 0x86dd).
    m.console.puts(" udp6=rx=");
    m.console.print_u64(virtio_net.udp.received6);
    m.console.puts(",tx=");
    m.console.print_u64(virtio_net.udp.sent6);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.udp.dropped6_len + virtio_net.udp.dropped6_badsum + virtio_net.udp.dropped6_closed + virtio_net.udp.dropped6_dst);
    m.console.puts("\n");
    return .none;
}

/// Print a v6 address or "-" (unset). The 39-byte buffer covers the
/// longest uncompressed form.
fn print_ip6_or_dash(m: *Monitor, addr: virtio_net.ipv6.Addr, set: bool) void {
    if (!set) {
        m.console.puts("-");
        return;
    }
    var buf: [39]u8 = undefined;
    const n = virtio_net.ipv6.format_ip6(addr, &buf);
    m.console.puts(buf[0..n]);
}

/// M117b (#2474, ADR 0057 D4/D5): the autonomous NDP transitions —
/// drive the tick-seam poll (the net_dhcp_autonomous shape) and print
/// the DAD promotes + conflicts as they happen, one line per event —
/// the live gate's deterministic stage markers.
pub fn net_ndp_autonomous(m: *Monitor) void {
    const ev = virtio_net.net_ndp_poll();
    var buf: [39]u8 = undefined;
    if (ev.promoted_ll) {
        const n = virtio_net.ipv6.format_ip6(virtio_net.ipv6.link_local, &buf);
        m.console.puts("net: v6 ll=");
        m.console.puts(buf[0..n]);
        m.console.puts(" valid\n");
    }
    if (ev.promoted_g6) {
        const n = virtio_net.ipv6.format_ip6(virtio_net.ipv6.global, &buf);
        m.console.puts("net: v6 g6=");
        m.console.puts(buf[0..n]);
        m.console.puts(" valid\n");
    }
    if (ev.rs_sent) {
        // One bounded line per RS — the live gate's "the train is done"
        // stage marker ('net: v6 rs=3').
        m.console.puts("net: v6 rs=");
        m.console.print_u64(virtio_net.ndp.rs_sent);
        m.console.puts("\n");
    }
    if (virtio_net.ndp.last_conflict) |c| {
        const n = virtio_net.ipv6.format_ip6(c, &buf);
        m.console.puts("net: v6 dad-conflict ");
        m.console.puts(buf[0..n]);
        m.console.puts("\n");
        virtio_net.ndp.last_conflict = null;
    }
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
/// Issue #119 (audit follow-up 3): the autonomous DHCP lease lifecycle —
/// called from the shell idle loop each iteration (AFTER the RX drain,
/// so a pending renewal ACK has restarted the lease clock first):
/// advances T1/T2/expiry WITHOUT a human typing `net dhcp`, printing the
/// SAME transition lines `net dhcp` prints (identical text — the N9
/// gates' regexes/counters/captures are the evidence). Silent on the
/// no-ARP renew path (the client stays BOUND per RFC 2131 §4.4.5;
/// typing `net dhcp` surfaces the diagnostic) and on TX failures (the
/// next `net dhcp` retries — no per-second spam). The re-DISCOVER after
/// expiry stays command-triggered.
pub fn net_dhcp_autonomous(m: *Monitor) void {
    if (!virtio_net.net_ready) return;
    const p = virtio_net.net_dhcp_poll();
    switch (p.step) {
        .none, .renew_no_arp => {},
        .expired => {
            m.console.puts("net dhcp: lease expired (elapsed=");
            m.console.print_u64(p.elapsed);
            m.console.puts(" >= lease=");
            m.console.print_u64(p.lease);
            m.console.puts(") — address released, re-DISCOVER with `net dhcp`\n");
        },
        .rebinding => {
            if (!p.tx_ok) {
                err_prefix(m);
                m.console.print_line("REBINDING TX failed (transport unready)");
                return;
            }
            m.console.puts("net dhcp: rebinding (T2, elapsed=");
            m.console.print_u64(p.elapsed);
            m.console.puts(") request sent (");
            m.console.print_u64(@intCast(p.out_len));
            m.console.puts(" bytes)\n");
        },
        .renewing => {
            if (!p.tx_ok) {
                err_prefix(m);
                m.console.print_line("RENEWING TX failed (transport unready)");
                return;
            }
            m.console.puts("net dhcp: renewing (T1, elapsed=");
            m.console.print_u64(p.elapsed);
            m.console.puts(") request sent to the server (");
            m.console.print_u64(@intCast(p.out_len));
            m.console.puts(" bytes)\n");
        },
    }
}

fn cmd_net_dhcp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.puts("no virtio-net device (");
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
                err_prefix(m);
                m.console.puts("refused (no OFFER after ");
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
                    err_prefix(m);
                    m.console.print_line("DISCOVER TX failed (transport unready)");
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
                    else => {
                        err_prefix(m);
                        m.console.print_line("REQUEST TX failed (transport unready)");
                    },
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
                        err_prefix(m);
                        m.console.print_line("renewing needs the server MAC (net arp <server> first)");
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
                    err_prefix(m);
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
                    else => {
                        err_prefix(m);
                        m.console.print_line("REBINDING TX failed (transport unready)");
                    },
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
                    err_prefix(m);
                    m.console.puts("renewing needs the server MAC (net arp ");
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
                    else => {
                        err_prefix(m);
                        m.console.print_line("RENEWING TX failed (transport unready)");
                    },
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
    print_usage(m, lookup("net").?);
    return .usage;
}

fn cmd_net_dns(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len < 1 or args.len > 2) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const hostname = args[0];
    var server_ip: [4]u8 = .{ 10, 0, 0, 2 }; // default host gateway
    if (args.len == 2) {
        server_ip = virtio_net.arp.parse_ip(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid server address: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
    } else {
        if (virtio_net.dhcp.state == .bound and (virtio_net.dhcp.lease_server[0] != 0 or virtio_net.dhcp.lease_server[1] != 0 or virtio_net.dhcp.lease_server[2] != 0 or virtio_net.dhcp.lease_server[3] != 0)) {
            server_ip = virtio_net.dhcp.lease_server;
        }
    }

    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
        return .none;
    }
    if (!virtio_net.arp.ip_set()) {
        err_prefix(m);
        m.console.print_line("no IP set (net ip <a.b.c.d> first)");
        return .none;
    }

    if (dns.resolve(hostname, server_ip)) |ip| {
        m.console.puts("net dns: ");
        m.console.puts(hostname);
        m.console.puts(" -> ");
        var ipbuf: [15]u8 = undefined;
        const in = virtio_net.arp.format_ip(ip, &ipbuf);
        m.console.puts(ipbuf[0..in]);
        m.console.puts("\n");
    } else |err| {
        err_prefix(m);
        m.console.puts("net dns error: ");
        m.console.puts(@errorName(err));
        m.console.puts(" for '");
        m.console.puts(hostname);
        m.console.puts("'\n");
    }
    return .none;
}

/// M26 N8 (issue #435): `net status` prints a concise one-line summary:
/// IP, Gateway, DNS server, DHCP state, and link connectivity.
fn cmd_net_status(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    var ipbuf: [15]u8 = undefined;
    var gwbuf: [15]u8 = undefined;
    var dnsbuf: [15]u8 = undefined;

    const ip_s: []const u8 = if (virtio_net.arp.ip_set())
        ipbuf[0..virtio_net.arp.format_ip(virtio_net.arp.own_ip, &ipbuf)]
    else
        "0.0.0.0";

    const gw: [4]u8 = if (virtio_net.dhcp.state == .bound and (virtio_net.dhcp.lease_gw[0] != 0 or virtio_net.dhcp.lease_gw[1] != 0 or virtio_net.dhcp.lease_gw[2] != 0 or virtio_net.dhcp.lease_gw[3] != 0))
        virtio_net.dhcp.lease_gw
    else if (virtio_net.arp.ip_set())
        .{ 10, 0, 0, 2 }
    else
        .{ 0, 0, 0, 0 };
    const gw_s: []const u8 = gwbuf[0..virtio_net.arp.format_ip(gw, &gwbuf)];

    const dns_srv: [4]u8 = if (virtio_net.dhcp.state == .bound and (virtio_net.dhcp.lease_server[0] != 0 or virtio_net.dhcp.lease_server[1] != 0 or virtio_net.dhcp.lease_server[2] != 0 or virtio_net.dhcp.lease_server[3] != 0))
        virtio_net.dhcp.lease_server
    else if (virtio_net.arp.ip_set())
        .{ 10, 0, 0, 2 }
    else
        .{ 0, 0, 0, 0 };
    const dns_s: []const u8 = dnsbuf[0..virtio_net.arp.format_ip(dns_srv, &dnsbuf)];

    const dhcp_str = switch (virtio_net.dhcp.state) {
        .idle => "idle",
        .selecting => "selecting",
        .requesting => "requesting",
        .bound => "bound",
        .renewing => "renewing",
        .rebinding => "rebinding",
    };

    const link_status = if (!virtio_net.net_ready)
        "disconnected"
    else if (virtio_net.arp.ip_set())
        "connected"
    else
        "idle";

    m.console.puts("net status: IP: ");
    m.console.puts(ip_s);
    m.console.puts(" Gateway: ");
    m.console.puts(gw_s);
    m.console.puts(" DNS: ");
    m.console.puts(dns_s);
    m.console.puts(" DHCP: ");
    m.console.puts(dhcp_str);
    m.console.puts(" (");
    m.console.puts(link_status);
    m.console.puts(")\n");
    return .none;
}

/// M26 N16 (issue #443): `net route` displays the active IPv4 routing table.
fn cmd_net_route(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    var gwbuf: [15]u8 = undefined;
    const gw: [4]u8 = if (virtio_net.dhcp.state == .bound and (virtio_net.dhcp.lease_gw[0] != 0 or virtio_net.dhcp.lease_gw[1] != 0 or virtio_net.dhcp.lease_gw[2] != 0 or virtio_net.dhcp.lease_gw[3] != 0))
        virtio_net.dhcp.lease_gw
    else if (virtio_net.arp.ip_set())
        .{ 10, 0, 0, 2 }
    else
        .{ 0, 0, 0, 0 };
    const gw_s: []const u8 = gwbuf[0..virtio_net.arp.format_ip(gw, &gwbuf)];

    m.console.puts("net route: table\n");
    m.console.puts("Destination     Gateway         Interface       Metric\n");
    m.console.puts("0.0.0.0/0       ");
    m.console.puts(gw_s);
    var pad: usize = gw_s.len;
    while (pad < 16) : (pad += 1) m.console.putc(' ');
    m.console.puts("eth0            1\n");
    return .none;
}

/// M26 N15 (issue #442): `net log` displays the in-memory ring buffer of network events.
fn cmd_net_log(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const count = virtio_net.net_log.get_count();
    m.console.puts("net log: entries=");
    m.console.print_u64(@intCast(count));
    m.console.puts("\n");

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (virtio_net.net_log.get_entry(i)) |entry| {
            m.console.puts("  [");
            m.console.print_u64(@intCast(i));
            m.console.puts("] ");
            m.console.puts(entry.getText());
            m.console.puts("\n");
        }
    }
    return .none;
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
        .listen => {
            m.console.puts("net tcp: listening on port ");
            m.console.print_u64(virtio_net.tcp.listen_port);
            m.console.puts("\n");
            return .none;
        },
        .syn_received => {
            if (virtio_net.tcp.ack_pending) {
                var out_len: usize = 0;
                if (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len) == .ok) {
                    virtio_net.tcp.ack_pending = false;
                    virtio_net.tcp.ack_sent += 1;
                }
            }
            m.console.puts("net tcp: syn_received (peer=");
            print_tcp_peer(m);
            m.console.puts(")\n");
            return .none;
        },
        .syn_sent => {
            if (virtio_net.tcp.connect_timed_out()) {
                virtio_net.tcp.abort_timeout();
                err_prefix(m);
                m.console.puts("connect refused (no SYN-ACK after ");
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
                    else => {
                        err_prefix(m);
                        m.console.print_line("ACK TX failed (transport unready)");
                    },
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
                    else => {
                        err_prefix(m);
                        m.console.print_line("final ACK TX failed (transport unready)");
                    },
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
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    const port = parse_port(args[1]) orelse {
        err_prefix(m);
        m.console.puts("invalid port: ");
        m.console.puts(args[1]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
        return .none;
    }
    if (virtio_net.tcp.state != .idle) {
        err_prefix(m);
        m.console.print_line("a connection is already in progress (net tcp reset to abort)");
        return .none;
    }
    if (!virtio_net.arp.ip_set()) {
        err_prefix(m);
        m.console.print_line("no IP set (net ip <a.b.c.d> first)");
        return .none;
    }
    if (std.mem.eql(u8, &ip, &virtio_net.arp.own_ip)) {
        err_prefix(m);
        m.console.print_line("own-IP connect refused (no TCP loopback — the bounded client is outward-only)");
        return .none;
    }
    // Drain first (the claim-6076 contract — the ARP reply for `net arp
    // <ip>` may have landed while the shell idled; the peer's MAC must
    // be in the table: the seam resolves nothing).
    virtio_net.net_rx_drain();
    const peer_mac = virtio_net.arp.lookup(ip) orelse {
        err_prefix(m);
        m.console.puts("peer not in ARP table (net arp ");
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
            err_prefix(m);
            m.console.print_line("SYN TX failed (transport unready)");
        },
    }
    return .none;
}

/// `net tcp send <len>` — transmit a data segment (1..payload_max bytes
/// of the deterministic pattern 01 02 03…, ack = rcv_nxt).
fn cmd_net_tcp_send(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const len = parseInt(args[0]) catch {
        err_prefix(m);
        m.console.puts("invalid length: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (len < 1 or len > virtio_net.tcp.payload_max) {
        err_prefix(m);
        m.console.puts("length must be between 1 and ");
        m.console.print_u64(virtio_net.tcp.payload_max);
        m.console.puts("\n");
        return .invalid_argument;
    }
    if (virtio_net.tcp.state != .established) {
        err_prefix(m);
        m.console.print_line("not established (net tcp connect <addr> <port> first)");
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
        else => {
            err_prefix(m);
            m.console.print_line("DATA TX failed (transport unready)");
        },
    }
    return .none;
}

/// `net tcp recv` — print the bounded RX buffer (ONE segment — the
/// honest bound, no reassembly) byte-exact (hex, the net udp recv
/// style) and consume it.
fn cmd_net_tcp_recv(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (virtio_net.tcp.state != .established) {
        err_prefix(m);
        m.console.print_line("not established (net tcp connect <addr> <port> first)");
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
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (virtio_net.tcp.state != .established) {
        err_prefix(m);
        m.console.print_line("not established (net tcp connect <addr> <port> first)");
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
        else => {
            err_prefix(m);
            m.console.print_line("FIN TX failed (transport unready)");
        },
    }
    return .none;
}

/// `net tcp reset` — the client's abort: transmit a RST (the connection
/// dies; the next `net tcp` returns to IDLE).
fn cmd_net_tcp_reset(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (virtio_net.tcp.state == .idle) {
        err_prefix(m);
        m.console.print_line("no connection to reset");
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
        else => {
            err_prefix(m);
            m.console.print_line("RST TX failed (transport unready)");
        },
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
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    virtio_net.arp.own_ip = ip;
    virtio_net.net_log.log_fmt("IP: assigned {d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
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
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
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
            virtio_net.net_log.log_fmt("ARP: request {d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
            m.console.puts("net arp: request for ");
            var ipbuf: [15]u8 = undefined;
            const in = virtio_net.arp.format_ip(ip, &ipbuf);
            m.console.puts(ipbuf[0..in]);
            m.console.puts(" sent (");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes)\n");
        },
        .not_ready => {
            err_prefix(m);
            m.console.print_line("no IP set (net ip <a.b.c.d> first) or transport unready");
        },
        .timeout => {
            err_prefix(m);
            m.console.print_line("request TX timeout (device did not complete within the poll budget)");
        },
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
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
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
        .not_ready => {
            err_prefix(m);
            m.console.print_line("no IP set (net ip <a.b.c.d> first) or transport unready");
        },
        .timeout => {
            err_prefix(m);
            m.console.print_line("echo request TX timeout (device did not complete within the poll budget)");
        },
        .no_peer => {
            err_prefix(m);
            m.console.print_line("peer not in ARP table (net arp <a.b.c.d> first)");
        },
    }
    return .none;
}

/// `net ip6` — M117b (#2474, ADR 0057 D3/D13): report the v6 address
/// set — the link-local and the SLAAC global with their DAD states,
/// the router record, and the on-link prefix. Report-only: the monitor
/// never assigns v6 addresses (SLAAC forms them).
fn cmd_net_ip6(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (!virtio_net.net_ready) {
        m.console.print_line("net ip6: no virtio-net device");
        return .none;
    }
    virtio_net.ndp.now_ticks = timer.ticks;
    virtio_net.net_rx_drain();
    net_ndp_autonomous(m);
    m.console.puts("net ip6: ll=");
    print_ip6_or_dash(m, virtio_net.ipv6.link_local, virtio_net.ipv6.link_local_state != .none);
    m.console.puts(" ");
    m.console.puts(state_name(virtio_net.ipv6.link_local_state));
    m.console.puts(" g6=");
    print_ip6_or_dash(m, virtio_net.ipv6.global, virtio_net.ipv6.global_state != .none);
    m.console.puts(" ");
    m.console.puts(state_name(virtio_net.ipv6.global_state));
    m.console.puts("\n");
    m.console.puts("net ip6: rt=");
    print_ip6_or_dash(m, virtio_net.ipv6.router_addr, virtio_net.ipv6.router_valid);
    m.console.puts(" lt=");
    m.console.print_u64(virtio_net.ipv6.router_lifetime);
    m.console.puts(" onl=");
    if (virtio_net.ipv6.onlink_valid) {
        var pbuf: [39]u8 = undefined;
        const pn = virtio_net.ipv6.format_ip6(virtio_net.ipv6.onlink_prefix, &pbuf);
        m.console.puts(pbuf[0..pn]);
        m.console.puts("/");
        m.console.print_u64(virtio_net.ipv6.onlink_len);
    } else {
        m.console.puts("-");
    }
    m.console.puts("\n");
    return .none;
}

/// The DAD state tag printed beside each address.
fn state_name(s: virtio_net.ipv6.AddrState) []const u8 {
    return switch (s) {
        .none => "-",
        .tentative => "tentative",
        .valid => "valid",
        .conflicted => "conflicted",
    };
}

/// `net ndp [<v6-addr>]` — M117b (#2474, ADR 0057 D5). No argument:
/// drain the RX ring and print the bounded table + the counters (the
/// `net arp` shape). With an argument: resolve — a table hit prints
/// the peer, a miss transmits a Neighbor Solicitation for the NEXT HOP
/// (the literal address on-link, the router off-link; the NA is
/// learned asynchronously by the drain). Named refusals per D3/D9.
fn cmd_net_ndp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        if (!virtio_net.net_ready) {
            m.console.print_line("net ndp: no virtio-net device");
            return .none;
        }
        virtio_net.net_rx_drain();
        var count: usize = 0;
        for (&virtio_net.ndp.table) |*e| {
            if (e.valid) count += 1;
        }
        m.console.puts("net ndp: entries=");
        m.console.print_u64(@intCast(count));
        m.console.puts("\n");
        var abuf: [39]u8 = undefined;
        var macbuf: [17]u8 = undefined;
        for (&virtio_net.ndp.table) |*e| {
            if (!e.valid) continue;
            const an = virtio_net.ipv6.format_ip6(e.addr, &abuf);
            m.console.puts("net ndp: ");
            m.console.puts(abuf[0..an]);
            m.console.puts(" -> ");
            virtio_net.format_mac(&e.mac, &macbuf);
            m.console.puts(&macbuf);
            m.console.puts("\n");
        }
        m.console.puts("net ndp: rs=");
        m.console.print_u64(virtio_net.ndp.rs_sent);
        m.console.puts(",dad=");
        m.console.print_u64(virtio_net.ndp.dad_sent);
        m.console.puts(",dadc=");
        m.console.print_u64(virtio_net.ndp.dad_conflicts);
        m.console.puts(",ra=");
        m.console.print_u64(virtio_net.ndp.ra_accepted);
        m.console.puts(",for=");
        m.console.print_u64(virtio_net.ndp.ra_foreign);
        m.console.puts(",mal=");
        m.console.print_u64(virtio_net.ndp.ra_malformed);
        m.console.puts(",opt=");
        m.console.print_u64(virtio_net.ndp.opt_skipped);
        m.console.puts(",ns=");
        m.console.print_u64(virtio_net.ndp.ns_sent);
        m.console.puts(",na=");
        m.console.print_u64(virtio_net.ndp.na_sent);
        m.console.puts(",learn=");
        m.console.print_u64(virtio_net.ndp.learned);
        m.console.puts(",unsol=");
        m.console.print_u64(virtio_net.ndp.na_unsolicited);
        m.console.puts(",drop=");
        m.console.print_u64(virtio_net.ndp.ndp_drop + virtio_net.ndp.rs_dropped);
        m.console.puts(",redir=");
        m.console.print_u64(virtio_net.ndp.redirect_dropped);
        m.console.puts(",fail=");
        m.console.print_u64(virtio_net.ndp.reply_tx_fail);
        m.console.puts("\n");
        return .none;
    }
    if (args.len != 1) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const addr = virtio_net.ipv6.parse_ip6(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
        return .none;
    }
    virtio_net.ndp.now_ticks = timer.ticks;
    virtio_net.net_rx_drain();
    net_ndp_autonomous(m);
    var abuf: [39]u8 = undefined;
    const an = virtio_net.ipv6.format_ip6(addr, &abuf);
    const target = virtio_net.ipv6.next_hop(&addr);
    if (target) |t| {
        if (virtio_net.ndp.lookup(&t)) |mac| {
            m.console.puts("net ndp: ");
            m.console.puts(abuf[0..an]);
            m.console.puts(" is at ");
            var macbuf: [17]u8 = undefined;
            virtio_net.format_mac(&mac, &macbuf);
            m.console.puts(&macbuf);
            m.console.puts("\n");
            return .none;
        }
    }
    var frame_len: usize = 0;
    switch (virtio_net.net_ndp_solicit(addr, &frame_len)) {
        .ok => {
            virtio_net.ndp.ns_sent += 1;
            m.console.puts("net ndp: request for ");
            m.console.puts(abuf[0..an]);
            m.console.puts(" sent (");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes)\n");
        },
        .bad_dst6 => {
            err_prefix(m);
            m.console.print_line("bad_dst6 (multicast/unspecified/loopback destination)");
        },
        .no_src6 => {
            err_prefix(m);
            m.console.print_line("no_src6 (no valid link-local — net ip6)");
        },
        .no_route6 => {
            err_prefix(m);
            m.console.print_line("no_route6 (off-link destination and no router)");
        },
        .not_ready => {
            err_prefix(m);
            m.console.print_line("transport unready");
        },
        .timeout => {
            err_prefix(m);
            m.console.print_line("request TX timeout (device did not complete within the poll budget)");
        },
        .no_peer => unreachable, // solicitation goes out regardless of the table
    }
    return .none;
}

/// `net ping6 <v6-addr>` — M117b (#2474, ADR 0057 D6/D9): transmit an
/// ICMPv6 echo request — the Ethernet dst is the next hop's learned MAC
/// (the peer on-link, the router off-link), so the next hop must be in
/// the NDP table (`net ndp <addr>` resolves it first). The reply is
/// observed asynchronously by the RX drain (`pongs_observed` + the
/// `net` report's `seq=`). Named refusals per D3/D9.
fn cmd_net_ping6(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const addr = virtio_net.ipv6.parse_ip6(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
        return .none;
    }
    virtio_net.ndp.now_ticks = timer.ticks;
    virtio_net.net_rx_drain();
    net_ndp_autonomous(m);
    var frame_len: usize = 0;
    switch (virtio_net.net_ping6_request(addr, &frame_len)) {
        .ok => {
            virtio_net.ipv6.requests_sent += 1;
            virtio_net.ipv6.ping6_seq +%= 1;
            m.console.puts("net ping6: echo request to ");
            var abuf: [39]u8 = undefined;
            const an = virtio_net.ipv6.format_ip6(addr, &abuf);
            m.console.puts(abuf[0..an]);
            m.console.puts(" sent (");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes)\n");
        },
        .bad_dst6 => {
            err_prefix(m);
            m.console.print_line("bad_dst6 (multicast/unspecified/loopback destination)");
        },
        .no_route6 => {
            err_prefix(m);
            m.console.print_line("no_route6 (off-link destination and no router)");
        },
        .no_src6 => {
            err_prefix(m);
            m.console.print_line("no_src6 (no valid source address — net ip6)");
        },
        .no_peer => {
            err_prefix(m);
            m.console.print_line("peer not in NDP table (net ndp <addr> first)");
        },
        .not_ready => {
            err_prefix(m);
            m.console.print_line("transport unready");
        },
        .timeout => {
            err_prefix(m);
            m.console.print_line("echo request TX timeout (device did not complete within the poll budget)");
        },
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
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const port = parse_port(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (!virtio_net.udp.listen_port(port)) {
            err_prefix(m);
            m.console.print_line("listen failed (table full or duplicate)");
            return .none;
        }
        m.console.puts("net udp: listening on ");
        m.console.print_u64(port);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "close")) {
        if (args.len != 2) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const port = parse_port(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (!virtio_net.udp.close_port(port)) {
            err_prefix(m);
            m.console.puts("not listening on ");
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
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const ip = virtio_net.arp.parse_ip(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid address: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        const port = parse_port(args[2]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[2]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        const len = parseInt(args[3]) catch {
            err_prefix(m);
            m.console.puts("invalid length: ");
            m.console.puts(args[3]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (len < 1 or len > virtio_net.udp.payload_max) {
            err_prefix(m);
            m.console.puts("length must be between 1 and ");
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
            .not_ready => {
                err_prefix(m);
                m.console.print_line("no IP set (net ip <a.b.c.d> first) or transport unready");
            },
            .timeout => {
                err_prefix(m);
                m.console.print_line("datagram TX timeout (device did not complete within the poll budget)");
            },
            .no_peer => {
                err_prefix(m);
                m.console.print_line("peer not in ARP table (net arp <a.b.c.d> first)");
            },
        }
        return .none;
    }
    if (std.mem.eql(u8, args[0], "recv")) {
        if (args.len > 2) {
            print_usage(m, lookup("net").?);
            return .usage;
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
    print_usage(m, lookup("net").?);
    return .usage;
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

/// M117c (#2475, ADR 0057 D8): `net udp6` — the v6 half of `net udp`.
/// Same bounded listen table (family-tagged — a v6 bind never sees a
/// v4 datagram and vice versa) with a v6 literal on `send`. The refuse
/// names are Send6Result's (`bad_dst6`/`no_src6`/`no_route6`/`no_peer`).
fn cmd_net_udp6(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        var count: usize = 0;
        for (&virtio_net.udp.listen) |e| {
            if (e.valid and e.v6) count += 1;
        }
        m.console.puts("net udp6: entries=");
        m.console.print_u64(@intCast(count));
        m.console.puts("\n");
        for (&virtio_net.udp.listen) |e| {
            if (!e.valid or !e.v6) continue;
            m.console.puts("net udp6: port=");
            m.console.print_u64(e.port);
            m.console.puts("\n");
        }
        m.console.puts("net udp6: rx=");
        m.console.print_u64(virtio_net.udp.received6);
        m.console.puts(",tx=");
        m.console.print_u64(virtio_net.udp.sent6);
        m.console.puts(",drop=");
        m.console.print_u64(virtio_net.udp.dropped6_len + virtio_net.udp.dropped6_badsum + virtio_net.udp.dropped6_closed + virtio_net.udp.dropped6_dst);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "listen")) {
        if (args.len != 2) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const port = parse_port(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (!virtio_net.udp.listen_port6(port)) {
            err_prefix(m);
            m.console.print_line("listen failed (table full or duplicate)");
            return .none;
        }
        m.console.puts("net udp6: listening on ");
        m.console.print_u64(port);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "close")) {
        if (args.len != 2) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const port = parse_port(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (!virtio_net.udp.close_port6(port)) {
            err_prefix(m);
            m.console.puts("not listening (v6) on ");
            m.console.print_u64(port);
            m.console.puts("\n");
            return .none;
        }
        m.console.puts("net udp6: closed ");
        m.console.print_u64(port);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "send")) {
        if (args.len != 4) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const addr = virtio_net.ipv6.parse_ip6(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid v6 address: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        const port = parse_port(args[2]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[2]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        const len = parseInt(args[3]) catch {
            err_prefix(m);
            m.console.puts("invalid length: ");
            m.console.puts(args[3]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (len < 1 or len > virtio_net.udp.payload_max) {
            err_prefix(m);
            m.console.puts("length must be between 1 and ");
            m.console.print_u64(virtio_net.udp.payload_max);
            m.console.puts("\n");
            return .invalid_argument;
        }
        // The deterministic payload — bytes 01 02 03 04… (the v4 shape).
        var payload: [virtio_net.udp.payload_max]u8 = undefined;
        var pi: usize = 0;
        while (pi < len) : (pi += 1) payload[pi] = @as(u8, @truncate(pi)) +% 1;
        var frame_len: usize = 0;
        switch (virtio_net.net_udp6_send(addr, port, payload[0..@intCast(len)], &frame_len)) {
            .ok => {
                m.console.puts("net udp6: sent ");
                m.console.print_u64(len);
                m.console.puts(" bytes to ");
                var abuf: [39]u8 = undefined;
                const an = virtio_net.ipv6.format_ip6(addr, &abuf);
                m.console.puts(abuf[0..an]);
                m.console.puts(":");
                m.console.print_u64(port);
                m.console.puts(" (");
                m.console.print_u64(@intCast(frame_len));
                m.console.puts(" bytes)\n");
            },
            .not_ready => {
                err_prefix(m);
                m.console.print_line("transport not ready (no virtio-net device)");
            },
            .timeout => {
                err_prefix(m);
                m.console.print_line("datagram TX timeout (device did not complete within the poll budget)");
            },
            .no_peer => {
                err_prefix(m);
                m.console.print_line("next hop not in NDP table (net ndp <v6-addr> first)");
            },
            .no_src6 => {
                err_prefix(m);
                m.console.print_line("no_src6 (no valid v6 source for this dst — net ip6)");
            },
            .no_route6 => {
                err_prefix(m);
                m.console.print_line("no_route6 (off-link dst and no recorded router)");
            },
            .bad_dst6 => {
                err_prefix(m);
                m.console.print_line("bad_dst6 (multicast/unspecified/loopback/mapped destination)");
            },
        }
        return .none;
    }
    if (std.mem.eql(u8, args[0], "recv")) {
        if (args.len > 2) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        virtio_net.net_rx_drain();
        if (args.len == 2) {
            const port = parse_port(args[1]) orelse {
                m.console.puts("net udp6: invalid port: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            _ = cmd_net_udp6_recv_port(m, port);
            return .none;
        }
        var total: usize = 0;
        for (&virtio_net.udp.listen) |e| {
            if (!e.valid or !e.v6) continue;
            total += cmd_net_udp6_recv_port(m, e.port);
        }
        m.console.puts("net udp6 recv: total=");
        m.console.print_u64(@intCast(total));
        m.console.puts("\n");
        return .none;
    }
    print_usage(m, lookup("net").?);
    return .usage;
}

/// Drain + print the datagrams buffered for ONE v6 listener — the
/// `net udp6 recv` shape: the peer's v6 address is part of the record.
fn cmd_net_udp6_recv_port(m: *Monitor, port: u16) usize {
    var count: usize = 0;
    while (virtio_net.udp.pop6(port)) |d| {
        if (count == 0) {
            m.console.puts("net udp6 recv: port=");
            m.console.print_u64(port);
            m.console.puts("\n");
        }
        m.console.puts("net udp6 recv: [");
        m.console.print_u64(@intCast(count));
        m.console.puts("] len=");
        m.console.print_u64(@intCast(d.len));
        m.console.puts(" from=");
        var abuf: [39]u8 = undefined;
        const an = virtio_net.ipv6.format_ip6(d.src6, &abuf);
        m.console.puts(abuf[0..an]);
        m.console.puts("\n");
        m.console.puts("net udp6 recv: ");
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
        m.console.puts("net udp6 recv: no datagrams for port ");
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
        err_prefix(m);
        m.console.puts("invalid byte count: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("transport not ready (no virtio-net device)");
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
        .not_ready => {
            err_prefix(m);
            m.console.print_line("transport not ready (no virtio-net device)");
        },
        .timeout => {
            err_prefix(m);
            m.console.print_line("tx timeout (device did not complete within the poll budget)");
        },
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
        print_usage(m, lookup("screen").?);
        return .usage;
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
        print_usage(m, lookup("screen").?);
        return .usage;
    }
    const rgb = parseHex(args[0]) catch {
        err_prefix(m);
        m.console.puts("invalid color: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (rgb > 0xffffff) {
        err_prefix(m);
        m.console.print_line("color out of range (max 0xffffff)");
        return .invalid_argument;
    }
    if (!virtio_gpu.gpu_ready) {
        err_prefix(m);
        m.console.print_line("transport not ready (no virtio-gpu device)");
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
        err_prefix(m);
        m.console.print_line("transport not ready (no virtio-gpu device)");
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

/// M34 HF5 (issue #739): stream the framebuffer as a BMP to the HOST
/// SHARE through queue 5 when the channel is armed (chunked WRITE round
/// trips ≤ 32 KiB; a 1280×720 BMP is ~2.7 MiB ≈ 86 chunks — assembled in
/// the module's BSS chunk_staging, never the 16 KiB boot stack). The 54-
/// byte header layout is byte-identical to fat.write_fb_bmp (the host
/// verifies the file on disk). Returns true on a fully-written file.
fn vf_write_fb_bmp(path: []const u8, width: u32, height: u32, fb: [*]const u8) bool {
    // M50 TS2 (ADR 0024 D4): the kernel-actor gate (secret paths deny).
    if (!kernel_vf_allowed(path, .write)) return false;
    const row_raw: usize = @as(usize, width) * 3;
    const row_pad: usize = (4 - (row_raw % 4)) % 4;
    const row_stride: usize = row_raw + row_pad;
    const total_pixel_bytes: usize = row_stride * @as(usize, height);
    const total_file_size: usize = 54 + total_pixel_bytes;

    var h: u16 = 0;
    if (virtio_file.open(path, virtio_file.open_flag_create, &h) != virtio_file.st_ok) return false;
    defer _ = virtio_file.close(h);
    _ = virtio_file.truncate(h, 0);

    const chunk = &virtio_file.chunk_staging;
    var off: usize = 0;
    // 54-byte standard BMP header (mirror of fat.write_fb_bmp).
    @memset(chunk[0..54], 0);
    chunk[0] = 'B';
    chunk[1] = 'M';
    std.mem.writeInt(u32, chunk[2..6], @intCast(total_file_size), .little);
    std.mem.writeInt(u32, chunk[10..14], 54, .little);
    std.mem.writeInt(u32, chunk[14..18], 40, .little);
    std.mem.writeInt(i32, chunk[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, chunk[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, chunk[26..28], 1, .little);
    std.mem.writeInt(u16, chunk[28..30], 24, .little);
    std.mem.writeInt(u32, chunk[30..34], 0, .little);
    std.mem.writeInt(u32, chunk[34..38], @intCast(total_pixel_bytes), .little);
    std.mem.writeInt(i32, chunk[38..42], 2835, .little);
    std.mem.writeInt(i32, chunk[42..46], 2835, .little);
    off = 54;

    const fb_stride = @as(usize, width) * 4;
    var cur_y: usize = height;
    while (cur_y > 0) {
        cur_y -= 1;
        const row_start = cur_y * fb_stride;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const px_off = row_start + x * 4;
            if (off + 3 > chunk.len) {
                if (!vf_flush_chunk(h, chunk, &off)) return false;
            }
            chunk[off] = fb[px_off];
            chunk[off + 1] = fb[px_off + 1];
            chunk[off + 2] = fb[px_off + 2];
            off += 3;
        }
        var pad: usize = 0;
        while (pad < row_pad) : (pad += 1) {
            if (off + 1 > chunk.len) {
                if (!vf_flush_chunk(h, chunk, &off)) return false;
            }
            chunk[off] = 0;
            off += 1;
        }
    }
    return vf_flush_chunk(h, chunk, &off);
}

/// WRITE the assembled chunk and reset the offset (a zero-length flush is
/// a no-op success).
fn vf_flush_chunk(h: u16, chunk: []u8, off: *usize) bool {
    if (off.* == 0) return true;
    var flushed: usize = 0;
    while (flushed < off.*) {
        const take = @min(off.* - flushed, virtio_file.write_chunk_limit());
        var written: u64 = 0;
        const st = virtio_file.write(h, chunk[flushed .. flushed + take], &written);
        if (st != virtio_file.st_ok or written == 0 or written > take) {
            off.* = 0;
            return false;
        }
        flushed += @intCast(written);
    }
    off.* = 0;
    return true;
}

/// M27 G27 (Issue #470): capture current framebuffer and save as BMP — to
/// the HOST SHARE when the channel is armed (M34 HF5, issue #739), else
/// to FAT (dual path until HF6).
fn cmd_screenshot(m: *Monitor, args: []const []const u8) ExecError {
    if (!virtio_gpu.gpu_ready) {
        err_prefix(m);
        m.console.print_line("screenshot: GPU framebuffer not ready");
        return .none;
    }
    const path = if (args.len > 0) args[0] else "SCREEN.BMP";
    const row_raw: usize = @as(usize, virtio_gpu.fb_width) * 3;
    const row_pad: usize = (4 - (row_raw % 4)) % 4;
    const row_stride: usize = row_raw + row_pad;
    const total_bytes: usize = 54 + row_stride * @as(usize, virtio_gpu.fb_height);

    // M34 HF6 (issue #740): the FAT BMP writer is gone — screenshots
    // always ride the host share.
    if (!vf_write_fb_bmp(path, virtio_gpu.fb_width, virtio_gpu.fb_height, @ptrCast(&virtio_gpu.gpu_fb))) {
        err_prefix(m);
        m.console.print_line("screenshot: host write failed");
        return .none;
    }
    m.console.puts("screenshot: saved ");
    m.console.print_u64(virtio_gpu.fb_width);
    m.console.puts("x");
    m.console.print_u64(virtio_gpu.fb_height);
    m.console.puts(" BMP to ");
    m.console.puts(path);
    m.console.puts(" (");
    m.console.print_u64(total_bytes);
    m.console.puts(" bytes)\n");
    return .none;
}

/// M27 G29 (Issue #472): display keyboard shortcuts reference table.
fn cmd_shortcuts(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("Keyboard Shortcut Reference:");
    m.console.print_line("  Global:");
    m.console.print_line("    Ctrl+Shift+A   About VirelaiOS dialog");
    m.console.print_line("    Ctrl+Shift+/   Display this shortcut reference");
    m.console.print_line("    Alt+Tab        Cycle open windows (Hold Alt, press Tab/Shift+Tab)");
    m.console.print_line("    Alt+F4         Close active window");
    m.console.print_line("    F11            Toggle window fullscreen / tile");
    m.console.print_line("    Ctrl+Alt+Del   Reboot system");
    m.console.print_line("  Window & Navigation:");
    m.console.print_line("    Tab            Focus next control");
    m.console.print_line("    Shift+Tab      Focus previous control");
    m.console.print_line("    Enter / Space  Activate focused button or toggle control");
    m.console.print_line("    Escape         Dismiss modal dialog / cancel action");
    m.console.print_line("    Ctrl+Q / Ctrl+W Close current window / quit application");
    m.console.print_line("  Editing & Clipboard:");
    m.console.print_line("    Ctrl+C         Copy selected text to clipboard");
    m.console.print_line("    Ctrl+X         Cut selected text to clipboard");
    m.console.print_line("    Ctrl+V         Paste text from clipboard");
    m.console.print_line("    Ctrl+Z         Undo last action");
    m.console.print_line("    Ctrl+Y         Redo last undone action");
    m.console.print_line("    Ctrl+S         Save file");
    m.console.print_line("    Ctrl+O         Open file");
    m.console.print_line("    Ctrl+N         New file");
    m.console.print_line("    Ctrl+F         Find in file");
    m.console.print_line("  Shell / Console:");
    m.console.print_line("    Ctrl+L         Clear screen");
    m.console.print_line("    Ctrl+C         Interrupt current command");
    m.console.print_line("    Up / Down      Navigate command history");
    m.console.print_line("    Ctrl+R         Reverse search command history");
    m.console.print_line("  Terminal Window:");
    m.console.print_line("    Ctrl+Shift+C   Copy the selected text to clipboard");
    m.console.print_line("    Ctrl+Shift+V   Paste clipboard into the terminal");
    m.console.print_line("    Ctrl+Shift+F   Search the scrollback");
    m.console.print_line("    Ctrl+Shift+K   Clear the scrollback (see 'help terminal')");
    m.console.print_line("    Ctrl+Shift+R   Soft reset the terminal");
    m.console.print_line("    Ctrl+Shift+Alt+R  Full reset (RIS)");
    return .none;
}

/// `sound` — report the virtio-snd transport: the OBSERVED device ID and
/// class (a differing DID is a claim-time finding, recorded as the
/// hardware truth), the device status (0x0f = DRIVER_OK post-rearm; 0xff =
/// never discovered), the control-queue state, and the device-config
/// counts (jacks/streams/channel-maps — only when actually captured,
/// never guessed). Honest without the device: `ready=no` with the failure
/// reason.
fn cmd_sound(m: *Monitor, args: []const []const u8) ExecError {
    // Stream-state control (claim 9297): `sound volume <0-100>` sets the
    // bounded playback gain; `sound mute <on|off>` silences the stream.
    // Both are pure kernel state — they work without a device, and the
    // report below shows them. `sound` with no args is the transport
    // report.
    if (args.len == 2) {
        if (std.mem.eql(u8, args[0], "volume")) {
            const vol = parseInt(args[1]) catch {
                m.console.puts("sound: volume must be 0..100\n");
                return .none;
            };
            if (vol > 100) {
                m.console.puts("sound: volume must be 0..100\n");
                return .none;
            }
            const set = virtio_snd.snd_set_volume(@intCast(vol));
            m.console.puts("sound: volume=");
            m.console.print_u64(set);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "mute")) {
            const on = std.mem.eql(u8, args[1], "on");
            const off = std.mem.eql(u8, args[1], "off");
            if (!on and !off) {
                m.console.puts("sound: mute must be 'on' or 'off'\n");
                return .none;
            }
            _ = virtio_snd.snd_set_mute(on);
            m.console.puts(if (on) "sound: mute=on\n" else "sound: mute=off\n");
            return .none;
        }
        print_usage(m, lookup("sound").?);
        return .usage;
    }
    if (args.len > 2) {
        print_usage(m, lookup("sound").?);
        return .usage;
    }
    if (!virtio_snd.snd_ready) {
        m.console.puts("sound: no virtio-snd device (");
        m.console.puts(if (virtio_snd.snd_fail.len > 0) virtio_snd.snd_fail else "DID 0x1059 not found on bus 0");
        m.console.puts(")\n");
    } else {
        m.console.puts("sound: ready\n");
    }
    m.console.puts("sound: did=");
    m.console.print_hex(virtio_snd.snd_did);
    m.console.puts(" cls=");
    m.console.print_hex(virtio_snd.snd_class);
    m.console.puts(" st=");
    m.console.print_hex(virtio_snd.snd_status());
    m.console.puts("\n");
    m.console.puts("sound: feats=");
    m.console.print_hex(virtio_snd.snd_feats);
    m.console.puts(" qsz=");
    m.console.print_hex(virtio_snd.queue_size);
    m.console.puts(" qoff=");
    m.console.print_hex(virtio_snd.snd_queue_notify_off);
    m.console.puts(" common=");
    m.console.print_hex(virtio_snd.snd_common);
    m.console.puts(" notify=");
    m.console.print_hex(virtio_snd.snd_notify);
    m.console.puts(" devcfg=");
    m.console.print_hex(virtio_snd.snd_devcfg);
    m.console.puts("\n");
    m.console.puts("sound: ctrl_armed=");
    m.console.print_u64(if (virtio_snd.ctrl_armed) 1 else 0);
    m.console.puts(" tx_armed=");
    m.console.print_u64(if (virtio_snd.tx_armed) 1 else 0);
    m.console.puts(" notify_mult=");
    m.console.print_hex(virtio_snd.snd_notify_mult);
    m.console.puts(" ctl_qoff=");
    m.console.print_hex(virtio_snd.snd_queue_notify_off);
    m.console.puts(" tx_qoff=");
    m.console.print_hex(virtio_snd.tx_queue_notify_off);
    m.console.puts(" fail_stage=");
    m.console.print_u64(virtio_snd.ctl_fail_stage);
    m.console.puts(" spins=");
    m.console.print_u64(virtio_snd.ctl_spins);
    m.console.puts(" used_idx=");
    m.console.print_u64(virtio_snd.ctl_used_idx);
    m.console.puts(" used_id=");
    m.console.print_u64(virtio_snd.ctl_used_id);
    m.console.puts(" used_len=");
    m.console.print_u64(virtio_snd.ctl_used_len);
    m.console.puts("\n");
    m.console.puts("sound: cfg=");
    if (virtio_snd.snd_cfg()) |cfg| {
        m.console.puts("jacks=");
        m.console.print_u64(cfg.jacks);
        m.console.puts(" streams=");
        m.console.print_u64(cfg.streams);
        m.console.puts(" chmaps=");
        m.console.print_u64(cfg.chmaps);
    } else {
        m.console.puts("not-captured (config read never landed)");
    }
    // Fresh post-exit read of the devcfg window (safe: the identity map
    // covers snd_bar0..+0x10000 and the devcfg capability resolved inside
    // it — 0x100001000 on the live runs). Pre-exit vs post-exit values
    // are compared so a firmware-mapping artifact is distinguishable from
    // the device's true report.
    m.console.puts(" fresh=");
    if (virtio_snd.snd_devcfg >= virtio_snd.snd_bar0 and
        virtio_snd.snd_devcfg + virtio_snd.cfg_bytes < virtio_snd.snd_bar0 + 0x10000)
    {
        m.console.puts("jacks=");
        m.console.print_u64(virtio_snd.snd_read32(virtio_snd.cfg_jacks_off));
        m.console.puts(" streams=");
        m.console.print_u64(virtio_snd.snd_read32(virtio_snd.cfg_streams_off));
        m.console.puts(" chmaps=");
        m.console.print_u64(virtio_snd.snd_read32(virtio_snd.cfg_chmaps_off));
    } else {
        m.console.puts("devcfg-outside-bar0 (not re-readable post-exit)");
    }
    // The bounded stream-state (claim 9297): vol=0..100, mute=0|1.
    m.console.puts("\nsound: vol=");
    m.console.print_u64(virtio_snd.stream_volume);
    m.console.puts(" mute=");
    m.console.print_u64(if (virtio_snd.stream_muted) 1 else 0);
    m.console.puts("\n");
    return .none;
}

/// `beep <freq> <ms>` — synthesize a sine and play it through the
/// virtio-snd PCM path (claim 5877, milestone fifteen card A2). The full
/// flow runs: PCM_INFO (the A1-finding workaround — VZ does not populate
/// the config counts, so the stream is enumerated by asking) →
/// SET_PARAMS → PREPARE → START → TX-queue submit → used-ring drain →
/// STOP → RELEASE. Every step's status + the submitted/drained accounting
/// are printed — the live gate's evidence. Honest without the device:
/// `beep` refuses with a clear reason.
fn cmd_beep(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 2) {
        print_usage(m, lookup("beep").?);
        return .usage;
    }
    const freq = parseInt(args[0]) catch {
        err_prefix(m);
        m.console.puts("beep: invalid frequency: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    const ms = parseInt(args[1]) catch {
        err_prefix(m);
        m.console.puts("beep: invalid duration: ");
        m.console.puts(args[1]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (freq < 1 or freq > 20000 or ms < 1 or ms > 650) {
        err_prefix(m);
        m.console.puts("beep: freq must be 1..20000 Hz and ms 1..650\n");
        return .invalid_argument;
    }
    if (!virtio_snd.snd_ready) {
        err_prefix(m);
        m.console.puts("beep: no virtio-snd device (");
        m.console.puts(if (virtio_snd.snd_fail.len > 0) virtio_snd.snd_fail else "DID 0x1059 not found on bus 0");
        m.console.puts(")\n");
        return .none;
    }
    const st = virtio_snd.snd_beep(@intCast(freq), @intCast(ms));
    m.console.puts("beep: reply=");
    var ri: usize = 0;
    while (ri < 9) : (ri += 1) {
        if (ri > 0) m.console.puts(" ");
        m.console.print_hex(std.mem.readInt(u32, virtio_snd.ctl_reply_buf[ri * 4 ..][0..4], .little));
    }
    m.console.puts("\n");
    m.console.puts("beep: info st=");
    m.console.print_hex(virtio_snd.beep_info_status);
    m.console.puts(" formats=");
    m.console.print_hex(virtio_snd.beep_obs_formats);
    m.console.puts(" rates=");
    m.console.print_hex(virtio_snd.beep_obs_rates);
    m.console.puts(" ch=");
    m.console.print_u64(virtio_snd.beep_obs_ch_min);
    m.console.puts("..");
    m.console.print_u64(virtio_snd.beep_obs_ch_max);
    m.console.puts(" dir=");
    m.console.print_u64(virtio_snd.beep_obs_dir);
    m.console.puts("\n");
    m.console.puts("beep: params fmt=");
    m.console.print_u64(virtio_snd.beep_format);
    m.console.puts(" rate=");
    m.console.print_u64(virtio_snd.beep_rate);
    m.console.puts(" ch=");
    m.console.print_u64(virtio_snd.beep_channels);
    m.console.puts(" st=");
    m.console.print_hex(virtio_snd.beep_params_status);
    m.console.puts(" prepare=");
    m.console.print_hex(virtio_snd.beep_prepare_status);
    m.console.puts(" start=");
    m.console.print_hex(virtio_snd.beep_start_status);
    m.console.puts("\n");
    m.console.puts("beep: tx submitted=");
    m.console.print_u64(virtio_snd.beep_submitted);
    m.console.puts(" drained=");
    m.console.print_u64(virtio_snd.beep_drained);
    m.console.puts(" frames=");
    m.console.print_u64(virtio_snd.beep_frames);
    m.console.puts(" pcm_status=");
    m.console.print_hex(virtio_snd.beep_last_status);
    m.console.puts(" latency=");
    m.console.print_u64(virtio_snd.beep_last_latency);
    m.console.puts("\n");
    m.console.puts("beep: stop=");
    m.console.print_hex(virtio_snd.beep_stop_status);
    m.console.puts(" release=");
    m.console.print_hex(virtio_snd.beep_release_status);
    m.console.puts("\n");
    if (st != virtio_snd.S_OK) {
        m.console.puts("beep: FAILED (");
        m.console.puts(if (virtio_snd.beep_fail.len > 0) virtio_snd.beep_fail else "unknown");
        m.console.puts(")\n");
    } else {
        m.console.puts("beep: ok\n");
    }
    return .none;
}

/// `font` — report or switch the terminal's font size (M20-U1). The
/// same setter slot 58 drives; the compositor repaints immediately.
/// M80i (#1725): one key, two ladders — the report shows both. They
/// can disagree at boot (the text layer's default is small, the grid's
/// MEDIUM), so neither is inferred from the other.
fn cmd_font(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        m.console.print_line("font:");
        m.console.puts("  text=");
        m.console.print_line(switch (fbtext.font_size) {
            .small => "small (8x8)",
            .medium => "medium (16x16)",
            .large => "large (24x24)",
        });
        m.console.puts("  grid=");
        m.console.print_line(switch (font_metrics.size) {
            .small => "small (7x13)",
            .medium => "medium (8x16)",
            .large => "large (10x21)",
        });
        return .none;
    }
    const target: ?fbtext.FontSize = if (std.mem.eql(u8, args[0], "small"))
        .small
    else if (std.mem.eql(u8, args[0], "medium"))
        .medium
    else if (std.mem.eql(u8, args[0], "large"))
        .large
    else
        null;
    if (target == null) {
        print_usage(m, lookup("font").?);
        return .usage;
    }
    // The store's font_size apply chain moves BOTH ladders in one pass
    // (settings.set -> apply_font_size -> text + driving_award grid; the
    // flats' single writer is set_size BY CONVENTION — see its note) and
    // publishes the row before the grid's WIN_RESIZE goes out (M80i).
    // When the store refuses the row, NOTHING moves — the ladders never
    // disagree.
    const res = settings.set("font_size", @tagName(target.?));
    if (res != .ok) {
        // Report the store's actual reason — table_full is the only one
        // this call site can reach today (the key and value lengths are
        // bounded by the table above), but SetResult has three failures
        // and the message must not assume which one arrived.
        err_prefix(m);
        m.console.puts("font_size not set: ");
        m.console.puts(switch (res) {
            .table_full => "settings table full",
            .invalid_key => "invalid key",
            .invalid_value => "value too long",
            .ok => "not set",
        });
        m.console.puts("\n");
        return .invalid_argument;
    }
    // Repaint through the compositor when the gpu is up.
    if (virtio_gpu.gpu_ready) {
        driving_award.mark_terminal_dirty();
        _ = driving_award.composite();
    }
    m.console.print_line("font: set (text + grid)");
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
        // M20-U1: rows/cols/cell report the LIVE font-size geometry
        // (visible grid at the current size), not the ring constants.
        m.console.puts("text: rows=");
        m.console.print_u64(fbtext.visible_rows());
        m.console.puts(" cols=");
        m.console.print_u64(fbtext.visible_cols());
        m.console.puts(" cell=");
        m.console.print_u64(fbtext.cur_cell_w());
        m.console.puts("x");
        m.console.print_u64(fbtext.cur_cell_h());
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
    if (std.mem.eql(u8, args[0], "put") or std.mem.eql(u8, args[0], "putraw")) {
        // M20-U14 gate seam: `putraw` skips the trailing newline so a
        // follow-up `text` report shows the exact landing column.
        const raw = std.mem.eql(u8, args[0], "putraw");
        if (args.len < 2) {
            print_usage(m, lookup("text").?);
            return .usage;
        }
        if (!virtio_gpu.gpu_ready) {
            err_prefix(m);
            m.console.print_line("transport not ready (no virtio-gpu device)");
            return .none;
        }
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (i > 1) fbtext.putc(' ');
            // M20-U10 gate seam: "\t" expands to a real TAB — raw TAB
            // bytes cannot survive the line editor's completion.
            const arg = args[i];
            var j: usize = 0;
            while (j < arg.len) : (j += 1) {
                if (arg[j] == '\\' and j + 1 < arg.len and arg[j + 1] == 't') {
                    fbtext.putc('\t');
                    j += 1;
                } else {
                    fbtext.putc(arg[j]);
                }
            }
        }
        if (!raw) fbtext.putc('\n');
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
            err_prefix(m);
            m.console.print_line("transport not ready (no virtio-gpu device)");
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
    if (std.mem.eql(u8, args[0], "fontdebug")) {
        // M20-U11: toggle the missing-glyph dev setting and report stats.
        if (args.len > 1) {
            if (std.mem.eql(u8, args[1], "on")) {
                fbtext.debug_font = true;
            } else if (std.mem.eql(u8, args[1], "off")) {
                fbtext.debug_font = false;
            } else {
                print_usage(m, lookup("text").?);
                return .usage;
            }
        }
        m.console.print_line("fontdebug:");
        m.console.puts("  state=");
        m.console.print_line(if (fbtext.debug_font) "on" else "off");
        m.console.puts("  missing=");
        m.console.print_u64(fbtext.missing_glyph_count);
        // U+XXXX, four hex digits, matching the serial log format of the
        // missing-glyph hook ("text: no glyph for U+XXXX").
        m.console.puts(" last=U+");
        const shifts = [_]u4{ 12, 8, 4, 0 };
        for (shifts) |sh| {
            const d: u8 = @intCast((fbtext.last_missing_cp >> sh) & 0xf);
            m.console.putc(if (d < 10) '0' + d else 'a' + d - 10);
        }
        m.console.puts("\n");
        return .none;
    }
    print_usage(m, lookup("text").?);
    return .usage;
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
// M70a-live (#1466): seeded EL0 fuzz + live queue-5 wire corpus
// ---------------------------------------------------------------------------

fn cmd_fuzz(m: *Monitor, args: []const []const u8) ExecError {
    const token = args[0];
    const is_roster = std.mem.eql(u8, token, "roster");
    if (!is_roster) {
        _ = parseInt(token) catch {
            err_line(m, "fuzz: seed must be roster or an integer (0x… hex or decimal)");
            return .invalid_argument;
        };
    }

    if (!virtio_file.available()) {
        m.console.print_line("fuzz: wire skipped (no queue-5)");
    } else {
        var first_stat = true;
        const run_one = struct {
            fn go(mon: *Monitor, seed: u64, print_stat: *bool) void {
                const r = virtio_file.fuzz_live_wire(seed);
                if (print_stat.*) {
                    print_stat.* = false;
                    var sbuf: [96]u8 = undefined;
                    const sl = std.fmt.bufPrint(&sbuf, "fuzz: wire-stat USER.BIN ok={d} size={d}\n", .{
                        @intFromBool(r.stat_ok),
                        r.stat_size,
                    }) catch "fuzz: wire-stat USER.BIN\n";
                    mon.console.puts(sl);
                }
                var buf: [128]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "fuzz: wire seed=0x{x} decoded={d} violations={d}\n", .{
                    seed, r.decoded, r.violations,
                }) catch "fuzz: wire\n";
                mon.console.puts(line);
            }
        }.go;
        if (is_roster) {
            for (virtio_file.fuzz_seeds) |seed| run_one(m, seed, &first_stat);
        } else {
            const seed = parseInt(token) catch 0;
            run_one(m, seed, &first_stat);
        }
    }

    return cmd_exec(m, &.{ "EL0EXEC.BIN", "fuzz", token });
}

// ---------------------------------------------------------------------------
// ESP exec command (claim 6783 — milestone-three card 6)
// ---------------------------------------------------------------------------

/// Load a user program from the ESP and enter it at EL0. `exec [<file>
/// [arg...]]` defaults to `USER.BIN` (the image builder embeds it at the
/// volume root; it can also be written at runtime through the FAT `write`
/// path). The program must be a DSK1 flat image; the kernel reads it
/// through the claim-6420 FAT path, rebuilds the EL0 user root around its
/// page, and spawns it as an EL0t task. Flags: `-c<core>` pins the spawned
/// task (SMP, claim 2369); `-u<uid>` is the M50 TS3 (#1137, ADR 0024 D5)
/// ADMIN SPAWN — `-u0` assigns `uid_system` + `kernel_caps`, `-u1000` the
/// default `uid_user` + no caps. It is the only path that can name a
/// principal; EL0 `sys_exec` inherits the caller's (no elevation).
/// Arguments (card 3e, claim 4636)
/// are packed into the program's text page and passed at entry (argc in
/// x0, argv block VA in x1) — bounded to `max_exec_args`; more than that
/// is refused honestly. Every failure mode is reported honestly.
fn cmd_exec(m: *Monitor, args: []const []const u8) ExecError {
    // SMP user tasks (claim 2369): `exec -c<core> <file>` pins the spawned
    // task to one core (console TX is locked, so a pinned program may print
    // from there). Claim 907 (#858): `-c0` is now legal too — an explicit
    // pin to CORE 0 (secondary_ok off), so a fourth task can be pinned to
    // core 0 alongside the shell for the four-core four-domain gate. The
    // unpinned default (no flag) stays distinct: `pinned` tracks the flag's
    // presence because `pin == 0` is now a VALID explicit pin.
    //
    // M50 TS3 (#1137, ADR 0024 D5): `exec -u<uid> <file>` is the monitor's
    // ADMIN SPAWN — the EL1h monitor (and only the monitor; EL0 `sys_exec`
    // has no principal argument and always inherits the caller) may name a
    // spawn principal. The two ADR D1 principals are the whole vocabulary:
    // `-u0` assigns `uid_system` + `kernel_caps` (the administrative
    // principal), `-u1000` assigns `uid_user` + no caps (the default), and
    // any other uid is refused. This is a control surface on the raw
    // console — an EL0 process has no path to request a principal.
    var pinned = false;
    var pin: usize = 0;
    var spawn_principal = process.default_principal;
    var rest = args;
    while (rest.len >= 1 and rest[0].len > 2 and rest[0][0] == '-') {
        const flag = rest[0][1];
        if (flag == 'c') {
            var value: usize = 0;
            for (rest[0][2..]) |ch| {
                if (ch < '0' or ch > '9') {
                    err_prefix(m);
                    m.console.print_line("-c<core>: core must be a decimal number");
                    return .invalid_argument;
                }
                value = value * 10 + (ch - '0');
            }
            if (value >= smp.max_cores) {
                err_prefix(m);
                m.console.puts("-c<core>: core must be in 0..");
                m.console.print_u64(smp.max_cores - 1);
                m.console.puts("\n");
                return .invalid_argument;
            }
            // M70b review: an offline core is rejected up front — a task
            // pinned to an offline core's ring is unreachable (steal
            // rejects it everywhere else, and the core never claims).
            if (!smp.core_online[value]) {
                err_prefix(m);
                var cbuf: [96]u8 = undefined;
                m.console.puts(std.fmt.bufPrint(&cbuf, "-c<core>: core {d} is not online (smp: cores={d})\n", .{ value, smp.num_cores }) catch "-c<core>: core is not online\n");
                return .invalid_argument;
            }
            pinned = true;
            pin = value;
        } else if (flag == 'u') {
            var value: u32 = 0;
            for (rest[0][2..]) |ch| {
                if (ch < '0' or ch > '9') {
                    err_prefix(m);
                    m.console.print_line("-u<uid>: uid must be 0 (system) or 1000 (user)");
                    return .invalid_argument;
                }
                const digit: u32 = ch - '0';
                // Reject a decimal that cannot fit a u32 BEFORE it wraps
                // (an overflowed value must never be mistaken for a valid
                // principal).
                if (value > (0xffff_ffff - digit) / 10) {
                    err_prefix(m);
                    m.console.print_line("-u<uid>: uid must be 0 (system) or 1000 (user)");
                    return .invalid_argument;
                }
                value = value * 10 + digit;
            }
            if (value == process.uid_system) {
                spawn_principal = .{ .uid = process.uid_system, .caps = process.kernel_caps };
            } else if (value == process.uid_user) {
                spawn_principal = .{ .uid = process.uid_user, .caps = 0 };
            } else {
                err_prefix(m);
                m.console.print_line("-u<uid>: uid must be 0 (system) or 1000 (user)");
                return .invalid_argument;
            }
        } else break;
        rest = rest[1..];
    }
    const name = if (rest.len >= 1) rest[0] else esp_exec.default_name;
    const prog_args = if (rest.len >= 2) rest[1..] else &.{};
    const result = if (pinned)
        esp_exec.exec_file_pinned_as(name, prog_args, pin, spawn_principal)
    else
        esp_exec.exec_file_as(name, prog_args, spawn_principal);
    switch (result) {
        .ok => {
            const info = esp_exec.loaded().?;
            // One write per line (the claim-881-slice-4 discipline): with
            // M70b wake targeting the exec'd task starts on a remote core
            // the moment it is published, and its first output can
            // otherwise land between these puts and split the very line
            // the live gates byte-match (observed: `exec: loaded ` +
            // SMPNET's first heartbeat + ` size=`).
            const head = esp_exec.head();
            var head_value: u64 = 0;
            for (head, 0..) |byte, i| head_value |= @as(u64, byte) << @intCast(56 - i * 8);
            var buf: [256]u8 = undefined;
            const line = if (info.data_len > 0)
                // M171a (card #3032): datapages is the RESIDENT count at
                // exec, mappedpages the VIRTUAL span — the demand-zero
                // tail counts in the second only.
                std.fmt.bufPrint(&buf, "exec: loaded {s} size=0x{x:0>16} entry=0x{x:0>16} stack=0x{x:0>16} head=0x{x:0>16} data=0x{x:0>16} datapages={d} mappedpages={d}\n", .{ info.name, info.content_len, info.entry_va, info.stack_va, head_value, info.data_len, info.data_pages, info.data_map_pages }) catch return .not_implemented
            else
                std.fmt.bufPrint(&buf, "exec: loaded {s} size=0x{x:0>16} entry=0x{x:0>16} stack=0x{x:0>16} head=0x{x:0>16}\n", .{ info.name, info.content_len, info.entry_va, info.stack_va, head_value }) catch return .not_implemented;
            m.console.puts(line);
            return .none;
        },
        .no_disk => {
            err_prefix(m);
            m.console.print_line("no host file channel (boot the runner with --cvc-file <host-dir>)");
            return .not_implemented;
        },
        .not_found => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not found on the host share (must be a DSK1/DSK3/ELF image)");
            return .invalid_argument;
        },
        // M70c-K (issue #1504): the two size refusals name the bound each
        // one crossed, so a log says WHY the image was refused: a file past
        // the acceptance bound is refused whatever its shape, while a shape
        // that must be STAGED is capped by the staging buffer (the streamed
        // gap-layout path is not).
        .image_too_large => {
            err_prefix(m);
            m.console.puts(name);
            m.console.puts(": image too large (acceptance bound ");
            m.console.print_hex(esp_exec.exec_image_max);
            m.console.print_line(" bytes)");
            return .invalid_argument;
        },
        .staging_too_large => {
            err_prefix(m);
            m.console.puts(name);
            m.console.puts(": image too large for the ");
            m.console.print_hex(esp_exec.exec_program_max);
            m.console.print_line("-byte staging buffer (only a gap-layout static ELF streams past it)");
            return .invalid_argument;
        },
        // M72a (issue #1579): the third size refusal, and the one a large
        // zero-filled `.bss`/`.noptrbss` crosses. It says MEMORY, because
        // that is what the bound is: the loader allocates and zero-fills
        // every mapped page, so this image is refused for what it would
        // have taken out of the guest, not for its size on disk and not for
        // a buffer it would never have transited.
        .map_too_large => {
            err_prefix(m);
            m.console.puts(name);
            m.console.puts(": image maps too much memory (map bound ");
            m.console.print_hex(esp_exec.map_max);
            m.console.print_line(" bytes; every PT_LOAD page is allocated and zeroed)");
            return .invalid_argument;
        },
        .bad_magic => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not a DSK1 program image (bad magic)");
            return .invalid_argument;
        },
        .bad_entry => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": bad entry offset (outside the loaded content)");
            return .invalid_argument;
        },
        .out_of_memory => {
            err_prefix(m);
            m.console.print_line("out of physical pages (text/stack/exception stack)");
            return .machine_failed;
        },
        .pool_full => {
            m.console.puts("error: no free scheduler pool slot\n");
            return .machine_failed;
        },
        .table_full => {
            err_prefix(m);
            m.console.print_line("page-table carve-out exhausted (too many user-root rebuilds)");
            return .machine_failed;
        },
        .process_full => {
            err_prefix(m);
            m.console.print_line("process registry exhausted (all processes live; wait for one to exit)");
            return .machine_failed;
        },
        .too_many_args => {
            err_prefix(m);
            m.console.puts("too many arguments (max ");
            m.console.print_u64(esp_exec.max_exec_args);
            m.console.print_line(")");
            return .invalid_argument;
        },
        .arg_too_long => {
            err_prefix(m);
            m.console.puts("argument longer than ");
            m.console.print_u64(esp_exec.arg_slot_bytes - 1);
            m.console.print_line(" bytes");
            return .invalid_argument;
        },
        .no_args_room => {
            err_prefix(m);
            m.console.print_line("image leaves no room for the argv block");
            return .invalid_argument;
        },
        // M70b review: defensive backstop for the -c parse above (the
        // exec-file choke point refuses an offline pin for every caller).
        .bad_core => {
            err_prefix(m);
            m.console.print_line("-c<core>: core is not online");
            return .invalid_argument;
        },
        // M22 D1 (issue #324): honest ELF refusals.
        .bad_elf => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not a valid ELF file");
            return .invalid_argument;
        },
        .unsupported_arch => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": unsupported architecture (AArch64 only)");
            return .invalid_argument;
        },
        .no_pt_load => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": no PT_LOAD segments");
            return .invalid_argument;
        },
        .too_many_segments => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": too many segments (max 2)");
            return .invalid_argument;
        },
        .segment_too_large => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": segment too large or bad segment layout");
            return .invalid_argument;
        },
        // M70c-K (issue #1504): the streamed load reads each segment's
        // bytes straight from the file, so a file that ends before its own
        // header promises is refused BY NAME instead of mapping a
        // half-filled segment (distinct from `too_large`, which is about
        // what the loader accepts, and from `not_found`).
        .image_truncated => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": truncated image (file ends before the bytes its header promises)");
            return .invalid_argument;
        },
        // M113c (#2419, ADR 0054 D8): a grant row names this image but
        // the measured digest mismatched — refused by name, never
        // fell open.
        .grant_stale => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": exec refused (grant_stale — a named grant row's sha256 does not match this image)");
            return .invalid_argument;
        },
    }
}

// ---------------------------------------------------------------------------
// Syscall ABI command (claim 3594)
// ---------------------------------------------------------------------------

/// M22 D3 (issue #326): `sym` — list the crash-report symbol table loaded
/// by the most recent ELF exec, or parse an ELF's symtab straight from the
/// volume without loading it.
fn cmd_sym(m: *Monitor, args: []const []const u8) ExecError {
    const symbol = @import("symbol.zig");
    const elf_mod = @import("elf.zig");
    if (args.len == 0) {
        const n = symbol.count();
        if (n == 0) {
            m.console.print_line("sym: no symbols loaded (exec an ELF image)");
            return .none;
        }
        m.console.puts("sym: ");
        m.console.print_u64(n);
        m.console.print_line(" symbol(s):");
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const sym = symbol.get(i).?;
            m.console.puts("  ");
            m.console.puts(sym.name_slice());
            m.console.puts(" addr=");
            m.console.print_hex(sym.addr);
            m.console.puts(" size=");
            m.console.print_hex(sym.size);
            m.console.print_line("");
        }
        return .none;
    }

    // File inspection: read up to sym_file_max bytes and walk sections
    // (HF6: from the host share — the FAT volume is gone).
    const name = args[0];
    if (!kernel_vf_allowed(name, .read)) return trust_denied(m, "sym", name);
    const got = virtio_file.read_whole(name, &sym_file_buf) orelse {
        err_prefix(m);
        m.console.puts(name);
        m.console.print_line(": not found on the host share");
        return .invalid_argument;
    };
    var infos: [symbol.max_symbols]elf_mod.SymInfo = undefined;
    const n = elf_mod.collect_symbols(sym_file_buf[0..got], &infos);
    if (n == 0) {
        m.console.puts(name);
        m.console.print_line(": no symbols (stripped or not an AArch64 ELF)");
        return .none;
    }
    m.console.puts(name);
    m.console.puts(": ");
    m.console.print_u64(n);
    m.console.print_line(" symbol(s):");
    for (infos[0..n]) |si| {
        m.console.puts("  ");
        m.console.puts(si.name);
        m.console.puts(" addr=");
        m.console.print_hex(si.addr);
        m.console.puts(" size=");
        m.console.print_hex(si.size);
        m.console.print_line("");
    }
    return .none;
}

/// Staging buffer for `sym <file>` disk inspection.
var sym_file_buf: [sym_file_max]u8 = undefined;

/// M22 D5 (issue #328): `strace exec <file> [args...]` arms the kernel
/// tracer for the process the exec spawns (the loader records its pid at
/// the success point, before the task first runs, so every syscall is
/// seen). `strace off` disarms. Anything else prints usage honestly.
fn cmd_strace(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1 and std.mem.eql(u8, args[0], "off")) {
        syscall_mod.strace_pid = null;
        m.console.print_line("strace: off");
        return .none;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[0], "exec")) {
        const res = esp_exec.exec_file(args[1], args[2..]);
        if (res != .ok) {
            err_prefix(m);
            m.console.puts("strace: exec refused (");
            m.console.print_u64(@backingInt(res));
            m.console.print_line(")");
            return .invalid_argument;
        }
        syscall_mod.strace_pid = esp_exec.last_exec_pid();
        m.console.print_line("strace: armed");
        return .none;
    }
    err_prefix(m);
    m.console.print_line("usage: strace exec <file> [args...] | strace off");
    return .invalid_argument;
}

/// M22 D6 (issue #329): `ps` — the process status table. One row per
/// non-free registry entry: PID, name, state, memory footprint (text +
/// data + stack + kernel-stack pages), CPU ticks (via the executor task
/// when bound), and the task id. `procs` remains the verbose view; this is
/// the scannable table.
fn cmd_ps(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("  PID  NAME                 STATE     MEM       CPU  TASK\n");
    var id: usize = 0;
    var rows: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        const info = process.info(id) orelse continue;
        if (info.state == .free) continue;
        rows += 1;
        var line: [96]u8 = undefined;
        var pos: usize = 0;
        pos = pad_left(&line, pos, id, 5);
        pos = append_str(&line, pos, "  ");
        pos = pad_right(&line, pos, info.name, 20);
        pos = append_str(&line, pos, " ");
        pos = pad_right(&line, pos, @tagName(info.state), 9);
        pos = append_str(&line, pos, " ");
        // Memory: owned pages only (boot payload reports its static stack).
        const mem_kib = ((info.text_pages + info.data_pages + info.stack_pages + info.kernel_stack_pages) * 4);
        pos = pad_left(&line, pos, mem_kib, 5);
        line[pos] = 'K';
        pos += 1;
        pos = append_str(&line, pos, "   ");
        pos = pad_left_u64(&line, pos, info.cpu_usage, 6);
        pos = append_str(&line, pos, "  ");
        if (info.task_id) |tid| {
            pos = pad_left(&line, pos, tid, 4);
        } else {
            pos = append_str(&line, pos, "   -");
        }
        if (pos < line.len) {
            line[pos] = '\n';
            m.console.write(line[0 .. pos + 1]);
        } else {
            m.console.write(line[0..pos]);
            m.console.print_line("");
        }
    }
    if (rows == 0) m.console.print_line("ps: no processes");
    return .none;
}

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    const take = @min(src.len, buf.len - pos);
    @memcpy(buf[pos..][0..take], src[0..take]);
    return pos + take;
}

fn pad_left(buf: []u8, pos: usize, v: usize, width: usize) usize {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var v2 = v;
    if (v2 == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (v2 > 0) : (v2 /= 10) {
        tmp[n] = @intCast('0' + v2 % 10);
        n += 1;
    }
    var written: usize = 0;
    while (n + written < width) : (written += 1) buf[pos + written] = ' ';
    var i: usize = 0;
    while (i < n) : (i += 1) buf[pos + written + i] = tmp[n - 1 - i];
    return pos + written + n;
}

fn pad_left_u64(buf: []u8, pos: usize, v_in: u64, width: usize) usize {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var v = v_in;
    if (v == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (v > 0) : (v /= 10) {
        tmp[n] = @intCast('0' + v % 10);
        n += 1;
    }
    var written: usize = 0;
    while (n + written < width) : (written += 1) buf[pos + written] = ' ';
    var i: usize = 0;
    while (i < n) : (i += 1) buf[pos + written + i] = tmp[n - 1 - i];
    return pos + written + n;
}

fn pad_right(buf: []u8, pos: usize, src: []const u8, width: usize) usize {
    const take = @min(src.len, width);
    @memcpy(buf[pos..][0..take], src[0..take]);
    var written = take;
    while (written < width) : (written += 1) buf[pos + written] = ' ';
    return pos + written;
}

fn cmd_syscalls(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    syscall.report(&m.console);
    return .none;
}

/// M32 WMS2 (issue #622): the render-server register report row. The
/// present-sequence counter is the parity-cards' observability primitive
/// (WMS4–WMS6 assert against it), so `wm` reports it from day one. When no
/// WM is registered it reports shim mode ("/ none").
fn cmd_wm(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const info = wm_server.info();
    if (info.pid) |pid| {
        m.console.puts("wm: registered pid=");
        m.console.print_u64(pid);
        m.console.puts(" present=");
        m.console.puts("\n");
        // present_seq is u32; report it as a fixed decimal for grep-ability.
        m.console.puts("wm: present_seq=");
        m.console.print_u64(info.present_seq);
        m.console.puts(" presents=");
        m.console.print_u64(info.present_count);
        m.console.puts(" ticks=");
        m.console.print_u64(info.tick_count);
        m.console.puts("\n");
        // M53 card 1 (#1247): the MEASURED cadence, and the two halves of the
        // input->scanout latency (WM loop turn | kernel+GPU present cost).
        // Integer pps is an average over the register's life; tick_pps is
        // printed beside it so the comparison is stated, not assumed.
        m.console.puts("wm: rate window_ms=");
        m.console.print_u64(info.present_window_ms);
        m.console.puts(" present_avg_ms=");
        m.console.print_u64(info.present_avg_ms);
        m.console.puts(" tick_avg_ms=");
        m.console.print_u64(info.tick_avg_ms);
        m.console.puts(" lat_n=");
        m.console.print_u64(info.lat_count);
        m.console.puts(" lat_avg_us=");
        m.console.print_u64(info.lat_avg_ns / 1000);
        m.console.puts(" lat_max_us=");
        m.console.print_u64(info.lat_max_ns / 1000);
        m.console.puts(" flush_n=");
        m.console.print_u64(info.flush_count);
        m.console.puts(" flush_avg_us=");
        m.console.print_u64(info.flush_avg_ns / 1000);
        m.console.puts(" flush_max_us=");
        m.console.print_u64(info.flush_max_ns / 1000);
        // WMP card 3 (#1274): the scheduling half of this same latency, on the
        // row that reports the latency. The pacing gate reads THIS row, so a
        // latency figure can now be attributed to the wake demand behind it
        // instead of standing on its own. `requests > 0` is the non-vacuity
        // proof: the demand is real and it is not being served by the tick.
        m.console.puts(" resched_requests=");
        m.console.print_u64(scheduler.resched_requests);
        m.console.puts(" resched_coalesced=");
        m.console.print_u64(scheduler.resched_coalesced);
        m.console.puts(" resched_discharged=");
        m.console.print_u64(scheduler.resched_discharged);
        m.console.puts("\n");
        // M32 WMS4 (issue #624): chrome observability — SET_WINDOW
        // submissions counted, the broadcast policy's chrome kind, and the
        // effective last chrome kind of every user window (0 = shim rules).
        m.console.puts("wm: chrome submissions=");
        m.console.print_u64(info.set_window_count);
        m.console.puts(" policy_kind=");
        m.console.print_hex_min(driving_award.wm_chrome_policy_kind());
        m.console.puts("\n");
        // M32 WMS5 (issue #625): the input-seam observability — how many
        // raw pointer samples (kind 19) and registry mirrors (kind 20) the
        // kernel has fanned out to the registered WM. The gate greps these
        // to prove the WM — not the kernel — received the stream.
        m.console.puts("wm: ptr_fan=");
        m.console.print_u64(info.pointer_fan_count);
        m.console.puts(" win_mirror=");
        m.console.print_u64(info.window_mirror_count);
        // M32 WMS5 Gate 2 (issue #625, claim 4278): the keyboard half of
        // the input seam — raw key fan-out (kind 21) and SET_STATE (cmd 4)
        // visibility/workspace changes applied by the registered WM.
        m.console.puts(" key_fan=");
        m.console.print_u64(info.key_fan_count);
        m.console.puts(" set_state=");
        m.console.print_u64(info.set_state_count);
        // M32 WMS6 Gate A (issue #626): the desktop-chrome observability —
        // ALT_TAB (cmd 5) decisions the WM made (activate/cycle/commit/
        // dismiss), applied by the kernel (the gate greps `alt_tab=`).
        m.console.puts(" alt_tab=");
        m.console.print_u64(info.alt_tab_apply_count);
        // M32 WMS6 Gate B (issue #626): the notification-center observability
        // — NOTIF_CENTER (cmd 6) and NOTIF_DISMISS (cmd 7) decisions applied.
        m.console.puts(" notif=");
        m.console.print_u64(info.notif_center_count);
        m.console.puts(" notif_dismiss=");
        m.console.print_u64(info.notif_dismiss_count);
        // M32 WMS6 Gate C (issue #626): the tooltip observability — TOOLTIP
        // (cmd 8) show/hide decisions applied.
        m.console.puts(" tooltip=");
        m.console.print_u64(info.tooltip_count);
        // M32 WMS6 Gate D (issue #626): the dock observability — DOCK (cmd 9)
        // icon-click decisions applied.
        m.console.puts(" dock=");
        m.console.print_u64(info.dock_count);
        // M32 WMS6 Gate E (issue #626): the tray observability — TRAY (cmd 10)
        // widget-content decisions applied (the gate greps `tray=`).
        m.console.puts(" tray=");
        m.console.print_u64(info.tray_count);
        // M32 WMS8 Gate 2 (issue #628): the dialog observability — DIALOG
        // (cmd 11) modal-dialog decisions (about open/close/toggle) applied.
        m.console.puts(" dialog=");
        m.console.print_u64(info.dialog_count);
        // WM3 (issue #707 card 3): the taskbar observability — TASKBAR
        // (cmd 12) entry-click decisions applied (the gate greps
        // `taskbar=`).
        m.console.puts(" taskbar=");
        m.console.print_u64(info.taskbar_count);
        // WM2 mission-control overview (Self-hosting Lane 1, issue #707
        // card 2): the overview observability — OVERVIEW (cmd 21) grid
        // decisions (enter/exit/focus/move) applied (the gate greps
        // `overview=`).
        m.console.puts(" overview=");
        m.console.print_u64(info.overview_count);
        m.console.puts("\n");
        var rows: [driving_award.max_windows]driving_award.ChromeRow = undefined;
        const n = driving_award.wm_chrome_rows(&rows);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            m.console.puts("wm: chrome window id=");
            m.console.print_u64(rows[i].id);
            m.console.puts(" kind=");
            m.console.print_hex_min(rows[i].kind);
            // WM4 (issue #707 card 4): the effective rest alpha (256 =
            // opaque; below = the at-rest unfocused client blend) — the
            // gate greps `rest=` for the policy proof.
            m.console.puts(" rest=");
            m.console.print_u64(rows[i].rest_alpha);
            m.console.puts("\n");
        }
    } else {
        m.console.print_line("wm: none (shim compositing)");
    }
    return .none;
}

/// M32 WMS3 (issue #623): the WM-server command. `wnd start` execs the
/// long-lived EL0 WND.BIN server (the DEFINED bootstrap — infrastructure,
/// not in APPS.TXT; the default VM stays shim-only because nothing
/// auto-starts it). Bare `wnd` reports the same seated-server state as
/// `wm` (registered pid + present/tick counters; `wnd: none` when the
/// shell idle shim is still compositing). Because WND.BIN never exits, the
/// crash story uses `kill <pid>` (claim 7786) + WMS2 exit-path teardown
/// (claim 0622) + a fresh `wnd start` — re-registering into the freed seat.
fn cmd_wnd(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "start")) {
        // The bootstrap: launch the long-lived WM server. Go through the
        // exec seam DIRECTLY with a fixed file name — the same pattern as
        // `calc`'s old exec_file (a direct string literal,
        // no argv indirection): an argv handoff to cmd_exec showed garbage
        // in the exec error path under ReleaseSmall, so this is the honest,
        // proven shape. WND.BIN becomes process WND.BIN on the ESP.
        switch (esp_exec.exec_file("WND.BIN", &.{})) {
            .ok => {
                m.console.puts("wnd: starting ");
                const info = esp_exec.loaded().?;
                m.console.puts(info.name);
                m.console.puts("\n");
                return .none;
            },
            .no_disk => {
                err_prefix(m);
                m.console.print_line("no disk (ESP FAT volume unavailable)");
                return .not_implemented;
            },
            .not_found => {
                err_prefix(m);
                m.console.print_line("WND.BIN not found on the ESP (must be a DSK1 flat image)");
                return .invalid_argument;
            },
            else => {
                err_prefix(m);
                m.console.print_line("WND.BIN failed to load (see `exec WND.BIN` for the full diagnosis)");
                return .invalid_argument;
            },
        }
    }
    const info = wm_server.info();
    if (info.pid) |pid| {
        m.console.puts("wnd: registered pid=");
        m.console.print_u64(pid);
        m.console.puts(" present_seq=");
        m.console.print_u64(info.present_seq);
        m.console.puts(" presents=");
        m.console.print_u64(info.present_count);
        m.console.puts(" ticks=");
        m.console.print_u64(info.tick_count);
        m.console.puts("\n");
    } else {
        m.console.print_line("wnd: none (shim compositing)");
    }
    return .none;
}

/// M39 TWM1 tabbed window manager server command (issue #928).
/// 'tabwm' reports the current WM server; 'tabwm start' launches TABWM.BIN.
fn cmd_tabwm(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "start")) {
        switch (esp_exec.exec_file("TABWM.BIN", &.{})) {
            .ok => {
                const info = esp_exec.loaded().?;
                var line: ["tabwm: starting ".len + process.name_max + 1]u8 = undefined;
                m.console.puts(std.fmt.bufPrint(&line, "tabwm: starting {s}\n", .{info.name}) catch return .not_implemented);
                return .none;
            },
            .no_disk => {
                err_prefix(m);
                m.console.print_line("no disk (ESP FAT volume unavailable)");
                return .not_implemented;
            },
            .not_found => {
                err_prefix(m);
                m.console.print_line("TABWM.BIN not found on the ESP (must be a DSK1 flat image)");
                return .invalid_argument;
            },
            else => {
                err_prefix(m);
                m.console.print_line("TABWM.BIN failed to load (see `exec TABWM.BIN` for the full diagnosis)");
                return .invalid_argument;
            },
        }
    }
    const info = wm_server.info();
    if (info.pid) |pid| {
        m.console.puts("tabwm: registered pid=");
        m.console.print_u64(pid);
        m.console.puts(" present_seq=");
        m.console.print_u64(info.present_seq);
        m.console.puts(" presents=");
        m.console.print_u64(info.present_count);
        m.console.puts(" ticks=");
        m.console.print_u64(info.tick_count);
        m.console.puts("\n");
    } else {
        m.console.print_line("tabwm: none (shim compositing)");
    }
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
    var buf: [256]u8 = undefined;
    m.console.puts(std.fmt.bufPrint(&buf, "addrspaces: ttbr1=0x{x:0>16} root=0x{x:0>16} tcr=0x{x:0>16} t0sz=16\n", .{
        mmu.read_ttbr1(), mmu.kernel_root_phys(), mmu.read_tcr(),
    }) catch return .not_implemented);
    var i: usize = 0;
    while (i < scheduler.max_tasks) : (i += 1) {
        const info = scheduler.task_info(i) orelse continue;
        m.console.puts(std.fmt.bufPrint(&buf, "addrspaces: task {s} ttbr0=0x{x:0>16}\n", .{ info.name, scheduler.task_ttbr0(i) }) catch return .not_implemented);
    }
    // Claim 6729: the user task's root is a fixed MMU fact (built at boot),
    // not a task-table fact — the lifecycle's idle task reaps the exited
    // user task, so the `task user-el0` row above may legitimately be gone
    // by the time this command runs. Report the root directly so the
    // ownership assertion (user root != kernel root) survives the reap.
    m.console.puts(std.fmt.bufPrint(&buf, "addrspaces: user root=0x{x:0>16}\n", .{mmu.user_root_phys()}) catch return .not_implemented);
    // Claim 0826: the per-process-root budget — table pages consumed out of
    // the fixed 512-page carve-out (grown by claim 2714 for the M16
    // composition). Card 3g (claim 5795): FOUR live user roots (~15 each +
    // leaf tables) stay well inside it; the scale live gate reads this line
    // for the headroom assertion.
    m.console.puts(std.fmt.bufPrint(&buf, "addrspaces: tables={d}/{d}\n", .{ mmu.tables_used(), mmu.tables_capacity() }) catch return .not_implemented);
    const leaves = mmu.walk_leaves(mmu.user_root_phys());
    m.console.puts(std.fmt.bufPrint(&buf, "addrspaces: user text=0x{x:0>16} stack=0x{x:0>16} leaves={d} device={d} el0={d} el0_device={d}\n", .{
        userspace.text_va, userspace.user_stack_va(), leaves.leaves, leaves.device_leaves, leaves.el0_leaves, leaves.el0_device_leaves,
    }) catch return .not_implemented);
    return .none;
}

// ---------------------------------------------------------------------------
// Resources command (milestone sixteen C3, claim 0339)
// ---------------------------------------------------------------------------

/// The fixed-pool audit: one line per bounded kernel pool with its live
/// occupancy vs its comptime bound. This is the C3 "measure, then grow
/// only what the apps exhaust" evidence — the live gate reads these lines
/// BEFORE filling the pool and AFTER, so the growth is pinned in the serial
/// log rather than asserted from code alone. The pools left bounded
/// (windows, mailbox rings, event queues, file handles, app timers, the
/// single TCP client) are printed with their bounds so the audit records
/// that they were checked and NOT grown (no demo app exhausts them).
fn cmd_resources(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const s = scheduler.stats();
    var buf: [256]u8 = undefined;
    m.console.puts(std.fmt.bufPrint(&buf, "resources: tasks={d}/{d} zombies={d}\n", .{ s.count, scheduler.max_tasks, s.zombies }) catch return .not_implemented);
    m.console.puts(std.fmt.bufPrint(&buf, "resources: procs={d}/{d}\n", .{ process.count(), process.max_processes }) catch return .not_implemented);
    m.console.puts(std.fmt.bufPrint(&buf, "resources: windows={d}/{d}\n", .{ driving_award.count(), driving_award.max_windows }) catch return .not_implemented);
    m.console.puts(std.fmt.bufPrint(&buf, "resources: tables={d}/{d}\n", .{ mmu.tables_used(), mmu.tables_capacity() }) catch return .not_implemented);
    m.console.puts(std.fmt.bufPrint(&buf, "resources: events={d} mbox={d} fds={d} timers=1 tcp=1\n", .{ events.max_events, mailbox.max_messages, file_table.max_handles_per_process }) catch return .not_implemented);
    // Arc5 issue #246: per-process resource usage vs limits
    var id: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        if (process.getrusage(id)) |ru| {
            if (ru.mem_limit != 0 or ru.cpu_limit != 0 or ru.mem_usage != 0 or ru.cpu_usage != 0) {
                const info = process.info(id).?;
                m.console.puts(std.fmt.bufPrint(&buf, "resources: pid={d} {s}\n", .{ id, info.name }) catch return .not_implemented);
                var mem_buf: [20]u8 = undefined;
                var cpu_buf: [20]u8 = undefined;
                const mem_limit = if (ru.mem_limit == 0) "unlimited" else std.fmt.bufPrint(&mem_buf, "{d}", .{ru.mem_limit}) catch return .not_implemented;
                const cpu_limit = if (ru.cpu_limit == 0) "unlimited" else std.fmt.bufPrint(&cpu_buf, "{d}", .{ru.cpu_limit}) catch return .not_implemented;
                m.console.puts(std.fmt.bufPrint(&buf, "  mem={d}/{s} cpu={d}/{s}\n", .{ ru.mem_usage, mem_limit, ru.cpu_usage, cpu_limit }) catch return .not_implemented);
            }
        }
    }
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
    // Issue #1391: kernel->user copies refused because a destination page
    // was not the process's to write. Always 0 in a healthy boot; a
    // non-zero count means a store would have been swallowed by the
    // EL1-only identity overlay (or a caller passed a foreign page).
    m.console.puts(" unbacked=");
    m.console.print_u64(d.unbacked);
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

fn cmd_sexiburger(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    for (sexiburger_lines()) |line| m.console.print_line(line);
    m.console.print_line("SEXIBURGER ONLINE");
    print_plain_field(m, "mascot", "Sexipus (hexapus clade)");
    m.console.puts("\n");
    print_plain_field(m, "tentacles", "6 (3 left, 3 right, lower pair curling inward)");
    m.console.puts("\n");
    print_plain_field(m, "layers", "6 (Crown, Lettuce, Tomato, Cheese, Patty, Heel)");
    m.console.puts("\n");
    print_plain_field(m, "covenant", "the tentacle count is load-bearing");
    m.console.puts("\n");
    print_plain_field(m, "status", "all 6 invariants intact");
    m.console.puts("\n");
    return .none;
}

fn cmd_beans(m: *Monitor, args: []const []const u8) ExecError {
    var count: u64 = 42;
    if (args.len == 1) {
        count = parseInt(args[0]) catch {
            err_prefix(m);
            m.console.puts("beans: invalid count: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (count < 1 or count > beans_max_count) {
            err_prefix(m);
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
            storage[0] = "VirelaiOS: the elephant has left the building.";
            storage[1] = "VirelaiOS: 42 beans, zero dignity.";
            storage[2] = "VirelaiOS: memory is a map, not a territory.";
            storage[3] = "VirelaiOS: no libc was harmed in the making of this kernel.";
            storage[4] = "VirelaiOS: terminal loop, meet the monitor.";
            storage[5] = "VirelaiOS: from scratch, with love and beans.";
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
/// does not print "VIRELAIOS 0.1" (the repository defines no release
/// number) or a hardcoded "256 MiB detected" (memory must be derived from
/// the captured map — `mem` does exactly that).
/// Arc5 #244: read SHUTDOWN.TXT from the HOST SHARE (HF6: the DATA
/// partition is gone) and print the last shutdown reason on boot. Silent
/// no-op when the file is absent or empty.
fn show_last_shutdown(m: *Monitor) void {
    if (!virtio_file.available()) return;
    var file_buf: [256]u8 = undefined;
    if (!kernel_vf_allowed("SHUTDOWN.TXT", .read)) return;
    const n = virtio_file.read_whole("SHUTDOWN.TXT", &file_buf) orelse return;
    const bytes = file_buf[0..n];
    // Extract the Reason: line if present
    var found_reason = false;
    var pos: usize = 0;
    while (pos < bytes.len) {
        var end = pos;
        while (end < bytes.len and bytes[end] != '\n') : (end += 1) {}
        const line = file_buf[pos..end];
        if (std.mem.startsWith(u8, line, "Reason: ")) {
            m.console.puts("Last shutdown: ");
            m.console.print_line(line[8..]);
            found_reason = true;
            break;
        }
        pos = end + 1;
    }
    if (!found_reason and bytes.len > 0) {
        m.console.print_line("Last shutdown: unknown (marker present)");
    }
}

pub fn banner(m: *Monitor) void {
    m.console.print_line("VirelaiOS - AArch64 firmware-assisted kernel monitor");
    m.console.puts(BootMessages.pick(m.state.handoff.image_handle));
    m.console.puts("\n");
    m.console.print_line("motd: aarch64 el1 kernel live; scheduler, uaccess, fs, net, gfx, xhci armed.");
    // Arc5 #244: display last shutdown reason on boot if SHUTDOWN.TXT exists
    show_last_shutdown(m);
    m.console.print_line("Type 'help' before touching anything expensive.");
}
