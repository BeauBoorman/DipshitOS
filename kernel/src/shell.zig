//! Interactive `dipshit>` shell loop (Milestone 1.5, console & shell core).
//!
//! Wires the bounded line editor (`lineedit.zig`) and the fixed-arity
//! tokenizer (`tokenizer.zig`) to the existing monitor registry
//! (`monitor.lookup`/`exec`), which this stream does not rebuild. The
//! whole loop is transport-agnostic: it only ever calls
//! `Console.readByte`/`write`, so it is proven against a scripted
//! `MockConsole` in `zig test` and runs unchanged on the real console
//! once the VZ serial gate (claim 0002) proves a device.
//!
//! Kernel seam (`kernel/src/main.zig`): `boot_and_park` prints the banner;
//! if an RX source is wired it runs the loop forever (never returns),
//! idling between polls with a bounded nop delay (the virtio device
//! delivers input with no interrupt, so WFE would never wake — claim
//! 6684); without RX it prints the prompt and returns so the kernel parks
//! in WFE. No device register is read by this module.
//!
//! No libc, no POSIX, no allocation. The single piece of global mutable
//! state is `shell_state` — the kernel-path Shell parked in BSS so the
//! editor's history ring (card U2) does not ride the 16 KiB boot stack;
//! host tests construct their own Shells and never touch it.

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("alloc.zig");
const console = @import("console.zig");
const esp = @import("esp.zig"); // claim 3475: ESP file window (ls/cat/write)
const lineedit = @import("lineedit.zig");
const tokenizer = @import("tokenizer.zig");
const monitor = @import("monitor.zig");
const handoff = @import("handoff.zig");
const memmap = @import("memmap.zig");
const scheduler = @import("scheduler.zig"); // claim 5275: worker progress printing (main context only)
const timer = @import("timer.zig"); // claim 7948: heartbeat printing (main context only)
const userspace = @import("userspace.zig"); // claim 8215: deferred EL0/SVC evidence line
const virtio_net = @import("virtio_net.zig"); // claim 6076 (card N2): polled RX drain in the idle loop
const road_pops = @import("road_pops.zig"); // claim 1574 (milestone six G3): Road Pops framebuffer drain in the idle loop
const input = @import("input.zig"); // claim 6050 (milestone seven I3): keyboard/pointer event FIFO drain in the idle loop
const driving_award = @import("driving_award.zig"); // claim 1543 (milestone six G5): Driving Award window-manager drain (clock refresh + composite)

pub const PollResult = enum {
    /// No input byte is available right now; the caller should wait before
    /// polling again (the kernel parks in WFE between polls).
    idle,
    /// A byte was consumed while a line is still being edited.
    pending,
    /// A full line was submitted or cancelled and handled (prompt output,
    /// echo, notices, and command results are all in the console).
    processed,
};

pub const Shell = struct {
    mon: monitor.Monitor,
    editor: lineedit.LineEditor = .{},
    prompt_shown: bool = false,

    pub fn init(con: console.Console, state: monitor.SystemState, machine: monitor.MachineControl) Shell {
        // Card U2 (ADR 0008 D2): the editor gets the monitor's tab
        // completer (verbs + sub-verbs) and the prompt string, so Ctrl-L
        // can repaint the full line.
        return .{
            .mon = monitor.Monitor.init(con, state, machine),
            .editor = .{ .completer = monitor.complete_line, .prompt = "dipshit> " },
        };
    }

    /// Print the boot banner once (`monitor.banner`).
    pub fn boot(self: *Shell) void {
        monitor.banner(&self.mon);
    }

    /// Drive one byte of input. Prints the `dipshit> ` prompt exactly once
    /// per line (on the poll that starts it). Returns `.idle` when no byte
    /// is available — callers park between polls; tests drive until idle.
    pub fn poll(self: *Shell) PollResult {
        if (!self.prompt_shown) {
            self.mon.console.puts("dipshit> ");
            self.prompt_shown = true;
        }
        const byte = self.mon.console.readByte() orelse return .idle;
        switch (self.editor.feed(self.mon.console, byte)) {
            .none => return .pending,
            .cancelled => {
                self.editor.reset();
                self.prompt_shown = false;
                return .processed;
            },
            .submitted => {
                const line = self.editor.buffer[0..self.editor.len];
                const rejected = self.editor.rejected;
                self.editor.next_line();
                self.prompt_shown = false;
                if (rejected) {
                    self.mon.console.print_line("input refused: line longer than 256 bytes");
                }
                handle_line(&self.mon, line);
                return .processed;
            },
        }
    }
};

/// The kernel-path Shell storage (see boot_and_park). Host tests never
/// touch it — they build their own Shells against a mock console.
var shell_state: Shell = undefined;

fn handle_line(mon: *monitor.Monitor, line: []const u8) void {
    const tokens = tokenizer.tokenize(line);
    if (tokens.too_many) {
        mon.console.print_line("too many arguments; type 'help' for a list of commands");
        return;
    }
    if (tokens.unbalanced_quote) {
        mon.console.print_line("unterminated quote: rest of line treated as literal");
    }
    _ = monitor.exec(mon, tokens.argv[0..tokens.count]);
}

/// Boot presentation for the kernel seam. Prints the banner; with an RX
/// source wired it runs the interactive loop forever (never returns);
/// without RX it prints the prompt and returns so the caller parks in WFE.
/// Never spins hot, never reads a device register.
pub fn boot_and_park(mon: *monitor.Monitor, rx_wired: bool) void {
    monitor.banner(mon);
    if (!rx_wired) {
        mon.console.puts("dipshit> ");
        return;
    }
    // Card U2: the kernel-path Shell lives in fixed BSS, not on the boot
    // stack — the editor's history ring (16 x 256 B + draft, ADR 0008 D2)
    // would eat over half of the 16 KiB stack ADR 0004 D5 allocates.
    // boot_and_park never returns, so the storage is effectively
    // single-assignment; host tests construct their own Shells.
    shell_state = Shell.init(mon.console, mon.state, mon.machine);
    const shell = &shell_state;
    while (true) {
        if (shell.poll() == .idle) {
            // Claim 9187: the timer is serviced only through the IRQ path.
            // Claim 7948's main-loop comparator poll raced real delivery
            // after the GICR frame fix, double-consuming some periods.
            // Output remains here because the polled virtio TX path is not
            // reentrancy-safe in IRQ context. Claim 5275: the worker task's
            // progress report prints the same way (the worker never touches
            // the console itself).
            timer.maybe_heartbeat(&mon.console);
            scheduler.maybe_report(&mon.console);
            userspace.maybe_report(&mon.console);
            // Claim 6076 (card N2): the polled RX drain — the net device's
            // used-buffer IRQ is not yet observed on this platform, so the
            // shell idle loop is the drain point (the card-3d shell-idle-
            // drain pattern). Idempotent; a no-op when the transport is
            // unarmed or the buffer is empty.
            // Card N9 (claim 9489): stamp the DHCP lease clock from the 1
            // Hz generic timer before the drain — a renewal ACK processed
            // below restarts the lease from the CURRENT instant (honest
            // wall-clock seconds, the same clock `net dhcp` uses).
            virtio_net.dhcp.now_ticks = timer.ticks;
            // Card N10 (claim 7026): stamp the TCP connect clock the same
            // way — a SYN-ACK processed below starts the connection from
            // the CURRENT instant (the bounded connect timeout is honest
            // wall-clock seconds).
            virtio_net.tcp.now_ticks = timer.ticks;
            virtio_net.net_rx_drain();
            // Claim 6050 (milestone seven I3): drain the keyboard/pointer
            // event FIFO — poll the XHCI interrupt-IN endpoints, decode the
            // HID reports, and push decoded bytes for the NEXT shell poll
            // (the same polled-drain discipline as net RX). No-op when the
            // input path is unarmed (default VM). Drains BEFORE the Road
            // Pops present so a report is never starved behind a slow
            // full-frame present.
            input.drain();
            // Claim 1574 (milestone six G3): Road Pops — one full-frame
            // present per dirty output batch (the card-3d drain pattern).
            // No-op when the tee is unarmed (default VM) or clean.
            road_pops.drain();
            // Card G5 (claim 1543): Driving Award — refresh the clock
            // window from the 1 Hz generic timer and composite any dirty
            // windows. This is the clock-only present path (the tee's
            // present above already composites terminal output); no-op
            // when the manager is unarmed (default VM) or clean.
            _ = driving_award.drain(timer.ticks);
            // Card N11 (claim 5357): the bounded retransmission timer —
            // polled here (the idle loop is the time engine — the
            // card-N9 clock pattern). AFTER the drain, so an ACK the
            // drain just processed has cleared the pending state — a
            // retransmission never follows an acknowledged segment. The
            // poll advances ONE step: an expired RTO (3 s) retransmits
            // the pending SYN/data/FIN byte-exact (counted, printed); the
            // exhausted bound (10) aborts the connection honestly
            // (counted, printed). Bare ACKs are never pending.
            switch (virtio_net.tcp.poll_rto()) {
                .none => {},
                .retransmit => {
                    var out_len: usize = 0;
                    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
                        .ok => {
                            mon.console.puts("net tcp: ");
                            mon.console.puts(switch (virtio_net.tcp.state) {
                                .syn_sent => "syn",
                                .established => "data",
                                .fin_sent => "fin",
                                else => "segment",
                            });
                            mon.console.puts(" retransmitted (");
                            mon.console.print_u64(virtio_net.tcp.retx_count);
                            mon.console.puts("/");
                            mon.console.print_u64(virtio_net.tcp.retx_max);
                            mon.console.puts(")\n");
                        },
                        else => mon.console.print_line("net tcp: retransmit TX failed (transport unready)"),
                    }
                },
                .abort => {
                    mon.console.puts("net tcp: retransmission limit reached (");
                    mon.console.print_u64(virtio_net.tcp.retx_max);
                    mon.console.puts(") — connection aborted\n");
                },
            }
            idle_wait_rx();
        }
    }
}

/// Idle between input polls in RX-wired mode: a bounded nop delay, not WFE.
/// The device delivers input with no interrupt (ADR 0004: no GIC
/// programming this milestone), so a WFE would sleep forever and the kernel
/// would never re-poll (claim 6684). The bounded delay keeps the loop
/// responsive without a timer. Elided entirely on non-aarch64 hosts so the
/// module stays host-testable on x86_64 CI.
fn idle_wait_rx() void {
    if (comptime builtin.cpu.arch == .aarch64) {
        var spins: usize = 0;
        while (spins < 100_000) : (spins += 1) asm volatile ("nop");
    }
}

// ---------------------------------------------------------------------------
// Tests (host-side; mock console, no hardware)
// ---------------------------------------------------------------------------

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

/// File-level descriptor fixture: the map view's data slice points into
/// this constant, which lives for the whole test binary (never a dead
/// stack frame), so the view stays valid for the shell's lifetime.
const test_descriptors = [_]memmap.MemoryDescriptor{
    .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 960, .attribute = 0 },
    .{ .type = .loader_code, .physical_start = 0x7000000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    .{ .type = .boot_services_data, .physical_start = 0x8000000, .virtual_start = 0, .number_of_pages = 128, .attribute = 0 },
    .{ .type = .runtime_services_data, .physical_start = 0x9000000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0 },
    .{ .type = .memory_mapped_io, .physical_start = 0x1000000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
    .{ .type = .reserved_memory_type, .physical_start = 0x1ff00000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
};

fn make_view() memmap.MapView {
    var view = memmap.MapView.init(std.mem.asBytes(&test_descriptors), @sizeOf(memmap.MemoryDescriptor), test_descriptors.len);
    view.key = 0x42;
    view.descriptor_version = 2;
    return view;
}

fn make_shell(mock: anytype, view: memmap.MapView) Shell {
    return Shell.init(
        mock.console(),
        .{ .handoff = make_handoff(), .map = view, .console_name = "mock" },
        monitor.MachineControl.disabled(),
    );
}

test "shell: mock-fed end-to-end session produces the exact transcript" {
    const long = "a" ** 256;
    const expected =
        "DipshitOS - AArch64 firmware-assisted kernel monitor\n" ++
        "DipshitOS: memory is a map, not a territory.\n" ++
        "Type 'help' before touching anything expensive.\n" ++
        "dipshit> help\r\n" ++
        "available commands:\n" ++
        "machine / identity\n" ++
        "  about       explain this questionable system\n" ++
        "  beans       count beans, probably\n" ++
        "  elephant    operational mascot diagnostics\n" ++
        "  uname       compact system identity\n" ++
        "  version     display build information\n" ++
        "memory / machine state\n" ++
        "  addrspaces  per-task user address spaces: per-task TTBR0, EL1-only kernel overlay, user-root contents\n" ++
        "  fault       trigger a synchronous exception (diagnostic)\n" ++
        "  handoff     display boot-to-kernel ABI data\n" ++
        "  hex         format an integer in hexadecimal\n" ++
        "  mem         summarize the EFI memory map\n" ++
        "  pages       physical page allocator pool\n" ++
        "  pci         enumerate PCI devices on the bus\n" ++
        "  timer       interrupt controller + timer status\n" ++
        "  uaccess     user-memory copy diagnostics (valid, fault, recovery)\n" ++
        "tasks / processes\n" ++
        "  exec        load a user program from the ESP and enter it at EL0\n" ++
        "  kill        terminate a running process (kernel-owned lifetime)\n" ++
        "  mbox        per-process IPC mailbox: pending messages and drain counters\n" ++
        "  procs       process registry: image, address space, lifecycle, exit status\n" ++
        "  spawn       spawn the lifecycle demo task\n" ++
        "  syscalls    numbered syscall table and counters\n" ++
        "  tasks       tick-driven task scheduler status\n" ++
        "storage\n" ++
        "  cat         print a file from the ESP (by name or /path)\n" ++
        "  ls          list files on the ESP (or a directory by path)\n" ++
        "  mount       switch the active FAT volume (esp or data)\n" ++
        "  write       write text to a file on the ESP\n" ++
        "networking\n" ++
        "  net         virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client)\n" ++
        "  netsend     send a known Ethernet frame (bounded staging, TX + used-ring drain)\n" ++
        "graphics / input\n" ++
        "  input       keyboard/pointer event FIFO: armed state, occupancy, drop count, last keyboard + pointer events\n" ++
        "  roadpops    Road Pops framebuffer console: armed/dirty/present counters (the boot terminal on the screen)\n" ++
        "  screen      virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)\n" ++
        "  text        framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears)\n" ++
        "  usb         XHCI host controller: `usb` transport report, `usb devices` enumerated HID devices, `usb report` last HID report\n" ++
        "  win         Driving Award window manager: registry (with owner pids), z-order, focus, hit-testing ('win focus <n>' focuses; 'win raise <n>' raises; 'win move <n> <x> <y>' moves a user window; 'win close <n>' releases a user window; 'win list <pid>' filters by owner; 'win hit <x> <y>' hit-tests)\n" ++
        "system\n" ++
        "  clear       clean up the crime scene\n" ++
        "  echo        repeat your regrettable decisions\n" ++
        "  help        grouped command catalog and per-command/per-topic help\n" ++
        "  random      print n random bytes from the seeded CSPRNG (hex)\n" ++
        "  reboot      restart the machine\n" ++
        "  repeat      repeat text, safely bounded\n" ++
        "  shutdown    request power-off\n" ++
        "type 'help <command>' for details on a single command.\n" ++
        "type 'help <topic>' for a topic page (networking, windows, storage, graphics).\n" ++
        "dipshit> version\r\n" ++
        "dipshit-kernel\n" ++
        "milestone-two kernel proper (ADR 0004)\n" ++
        "handoff ABI v2\n" ++
        "build label: m1.5 commands & personality (mock console)\n" ++
        "dipshit> mem\r\n" ++
        "mem: descriptors=0x0000000000000006 size=0x0000000000000028 version=0x0000000000000002 key=0x0000000000000042\n" ++
        "  usable: 0x0000000000480000 bytes (0x0000000000000480 pages)\n" ++
        "  conventional: 0x00000000003c0000 bytes (0x00000000000003c0 pages)\n" ++
        "  loader: 0x0000000000040000 bytes (0x0000000000000040 pages)\n" ++
        "  boot_services: 0x0000000000080000 bytes (0x0000000000000080 pages)\n" ++
        "  runtime: 0x0000000000008000 bytes (0x0000000000000008 pages)\n" ++
        "  reserved: 0x0000000000009000 bytes (0x0000000000000009 pages)\n" ++
        "  mmio: 0x0000000000010000 bytes (0x0000000000000010 pages)\n" ++
        "  kernel: 0x000000007e4df000..0x000000007e5613e8 (0x00000000000823e8 bytes)\n" ++
        "dipshit> pages\r\n" ++
        "pages: armed=1 total=0x0000000000000480 free=0x0000000000000480 excluded=0x0000000000000000 regions=0x0000000000000003 span=0x0000000000007f80\n" ++
        "dipshit> pages selftest\r\n" ++
        "pages selftest: alloc 1 -> 0x0000000000100000\n" ++
        "pages selftest: free ok\n" ++
        "pages selftest: alloc 8 -> 0x0000000000100000\n" ++
        "pages selftest: free ok\n" ++
        "pages selftest: alloc 3 -> 0x0000000000100000\n" ++
        "pages selftest: alloc 5 -> 0x0000000000103000\n" ++
        "pages selftest: free both ok\n" ++
        "pages selftest: alloc 960 -> 0x0000000000100000\n" ++
        "pages selftest: free ok\n" ++
        "pages selftest: alloc 1153 -> none (out of memory)\n" ++
        "pages selftest: ok free=0x0000000000000480\n" ++
        "dipshit> tasks\r\n" ++
        "tasks: enabled=0 current=0 switches=0 pool=4/7 zombies=0\n" ++
        "  shell    saves=0 resumes=0 advances=0 state=ready\n" ++
        "  worker   saves=0 resumes=0 advances=0 state=ready\n" ++
        "  user-el0 saves=0 resumes=0 advances=0 state=ready\n" ++
        "  idle     saves=0 resumes=0 advances=0 state=ready\n" ++
        "dipshit> echo \"elephant business\"\r\n" ++
        "elephant business\n" ++
        "dipshit> ls\r\n" ++
        "ls: esp=0x0000000000000003\n" ++
        "  KERNEL.BIN  0x0000000000088b38  [esp]\n" ++
        "  EFI         0x0000000000000000  [dir]\n" ++
        "  BOOTED.TXT  0x0000000000000029  [esp]\n" ++
        "dipshit> cat BOOTED.TXT\r\n" ++
        "DIPSHITOS BOOTLOADER\n" ++
        "firmware has agreed to cooperate\n" ++
        "dipshit> write hello.txt hello world\r\n" ++
        "write: hello.txt: not persisted - no disk (FAT volume unavailable)\n" ++
        "dipshit> cat hello.txt\r\n" ++
        "cat: hello.txt: not found (no such file on the ESP)\n" ++
        "dipshit> " ++ long ++ "\r\n" ++
        "unknown command: " ++ long ++ "\n" ++
        "type 'help' for a list of commands\n" ++
        "dipshit> ^C\r\n" ++
        // Enter pressed after the cancel submits an empty line, which the
        // registry answers with its no-command message (then a new prompt).
        "dipshit> \r\n" ++
        "no command given; type 'help' for a list of commands\n" ++
        "dipshit> ";

    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Arm the module allocator from the same fixture map the monitor sees,
    // exactly as kernel_main does — the `pages` command reports/exercises
    // that pool.
    _ = alloc.init(make_view(), &.{});
    // Claims 5275/8215: register all scheduler tasks exactly as kernel_main
    // does (without `start`, so no preemption happens in the test process)
    // — the `tasks` command then reports the real mixed-EL shape.
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    userspace.init();
    // Claim 3475/6420: populate the ESP file window the way kernel_main's
    // FAT snapshot does (KERNEL.BIN listed-but-unloaded, an EFI directory,
    // BOOTED.TXT content-loaded). A test process has no disk (no FAT
    // volume mounted), so `write` honestly reports it cannot persist.
    esp.reset();
    _ = esp.add_esp_entry("KERNEL.BIN", 0x88b38, "");
    _ = esp.add_dir_entry("EFI");
    _ = esp.add_esp_entry("BOOTED.TXT", 0x29, "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n");
    mock.feed("help\nversion\nmem\npages\npages selftest\ntasks\necho \"elephant business\"\nls\ncat BOOTED.TXT\nwrite hello.txt hello world\ncat hello.txt\n");
    mock.feed(long);
    mock.feed("\n\x03\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqualStrings(expected, mock.contents());
    // Emit the captured transcript so the automated gate
    // (tools/verify-transcript.sh, `zig build test-console`) can diff it
    // byte-for-byte against the checked-in canonical fixture
    // (tests/transcript-console.txt). Host-test-only: kernel builds never
    // execute tests, so std.Io never appears in the freestanding image.
    // Zig 0.16 moved file I/O out of std.fs into the std.Io interface; the
    // single-threaded instance is the minimal one for a plain write.
    var io_impl = std.Io.Threaded.init_single_threaded;
    try std.Io.Dir.cwd().writeFile(io_impl.io(), .{
        .sub_path = "artifacts/m15-mock-transcript.txt",
        .data = mock.contents(),
    });
}

test "shell: over-long line is refused with a bell and an overflow notice" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("b" ** 257);
    mock.feed("\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // 256 chars echoed, the 257th refused with a bell, then the notice.
    try std.testing.expect(std.mem.indexOf(u8, out, "b" ** 256 ++ "\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "input refused: line longer than 256 bytes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command: " ++ "b" ** 256) != null);
}

test "shell: too many arguments refuses execution with the documented message" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // 18 one-letter tokens = command + 17 args, one over the limit.
    mock.feed("a b c d e f g h i j k l m n o p q r\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "too many arguments; type 'help' for a list of commands\n") != null);
    // And it must not have executed anything.
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command:") == null);
}

test "shell: unbalanced quote warns and executes the literal" {
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo \"elephant business\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "unterminated quote: rest of line treated as literal\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "elephant business\n" ++ "dipshit> "));
}

test "shell: empty line reports no command via the registry" {
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "no command given; type 'help' for a list of commands\n") != null);
}

test "shell: ctrl-c on an empty line cancels without executing" {
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("\x03");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "^C\r\n") != null);
    // Cancelling must not execute anything — and, with no Enter after it,
    // must not submit an empty line either.
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "no command given") == null);
}
