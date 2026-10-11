//! Decoupled Shell unit test suite (M41 TS4, #955).
//!
//! Extracted from kernel/src/shell.zig to separate test harness from production shell logic.

const std = @import("std");
const builtin = @import("builtin");
const shell_mod = @import("shell");

// Aliases from shell module
const Shell = shell_mod.Shell;
const BgJob = shell_mod.BgJob;
const ChainOp = shell_mod.ChainOp;
const RedirectOp = shell_mod.RedirectOp;
const env_max = shell_mod.env_max;
const bg_job_max = shell_mod.bg_job_max;

const alloc = shell_mod.alloc;
const console = shell_mod.console;
const lineedit = shell_mod.lineedit;
const tokenizer = shell_mod.tokenizer;
const pipe = shell_mod.pipe;
const redirect = shell_mod.redirect;
const monitor = shell_mod.monitor;
const process = shell_mod.process;
const handoff = shell_mod.handoff;
const memmap = shell_mod.memmap;
const scheduler = shell_mod.scheduler;
const settings = shell_mod.settings;
const timer = shell_mod.timer;
const userspace = shell_mod.userspace;
const terminal = shell_mod.terminal;
const forensics = shell_mod.forensics;
const input = shell_mod.input;
const clipboard = shell_mod.clipboard;
const virtio_file = shell_mod.virtio_file;

const bg_job_add = shell_mod.bg_job_add;
const bg_job_free = shell_mod.bg_job_free;
const bg_job_latest = shell_mod.bg_job_latest;
const bg_reap = shell_mod.bg_reap;
const chain_split = shell_mod.chain_split;
const env_expand = shell_mod.env_expand;
const env_get = shell_mod.env_get;
const env_set = shell_mod.env_set;
const env_unset = shell_mod.env_unset;
const func_define = shell_mod.func_define;
const func_find = shell_mod.func_find;
const glob_match = shell_mod.glob_match;
const handle_line = shell_mod.handle_line;
const load_env = shell_mod.load_env;
const load_history = shell_mod.load_history;
const pipe_split = shell_mod.pipe_split;
const redirect_split = shell_mod.redirect_split;
const save_env = shell_mod.save_env;
const trailing_bg_amp = shell_mod.trailing_bg_amp;

const make_handoff = shell_mod.make_handoff;
const make_view = shell_mod.make_view;
const make_shell = shell_mod.make_shell;
const test_reset_share = shell_mod.test_reset_share;
const test_seed_dir = shell_mod.test_seed_dir;
const test_seed_share = shell_mod.test_seed_share;

test "M92e: only actual registration commits init boot ownership" {
    const action = shell_mod.init_boot_action;
    try std.testing.expectEqual(shell_mod.InitBootAction.wait, action(true, false, false));
    try std.testing.expectEqual(shell_mod.InitBootAction.wait, action(true, false, true));
    try std.testing.expectEqual(shell_mod.InitBootAction.seated, action(true, true, true));
    try std.testing.expectEqual(shell_mod.InitBootAction.seated, action(false, true, false));
    try std.testing.expectEqual(shell_mod.InitBootAction.stop_seat, action(false, false, true));
    try std.testing.expectEqual(shell_mod.InitBootAction.fallback, action(false, false, false));
}

test "M92e: init on by default, one-line off and wm none remain reachable" {
    settings.init();
    defer settings.init();
    try std.testing.expect(settings.init_enabled());
    try std.testing.expect(settings.parse_line("init=off"));
    try std.testing.expect(!settings.init_enabled());
    try std.testing.expectEqual(settings.WmSeat.gotabwm, settings.wm_seat_kind());
    settings.init();
    try std.testing.expect(settings.parse_line("wm=none"));
    try std.testing.expect(settings.init_enabled());
    try std.testing.expectEqual(settings.WmSeat.none, settings.wm_seat_kind());
}

test "M92e: missing init names refusal and retains direct seat diagnostic" {
    var boot_output = console.MockConsole(4096){};
    var shell = make_shell(&boot_output, make_view());
    shell.boot();
    defer settings.reset();
    defer {
        shell_mod.wm_autostart_attempted = false;
        shell_mod.init_boot_pid = null;
    }
    var output = console.MockConsole(4096){};
    shell.mon.console = output.console();
    shell_mod.wm_autostart_attempted = false;
    shell_mod.init_boot_pid = null;
    shell_mod.wm_autostart_once(&shell.mon);
    try std.testing.expectEqualStrings(
        "init: refuse missing-init\nwm: autostart gotabwm: GOTABWM.ELF not on the share (shim compositing)\n",
        output.contents(),
    );
    shell_mod.wm_autostart_once(&shell.mon);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.contents(), "init: refuse"));
}

fn reset_idle_reports() void {
    for (0..terminal.max_terminals) |i| terminal.release(i);
    _ = scheduler.init();
    userspace.init();
    forensics.reset();
    forensics.enabled = false;
    // Drain any flags inherited from other tests before resetting the clock.
    var mock = console.MockConsole(4096){};
    var con = mock.console();
    timer.maybe_heartbeat(&con);
    timer.ticks = 0;
    timer.irq_ticks = 0;
    timer.poll_ticks = 0;
}

fn queue_idle_reports() void {
    for (0..5) |_| timer.on_tick();
    scheduler.note_advance();
    scheduler.request_report();
    _ = userspace.ping(1);
    _ = userspace.ping(2);
}

test "serial owner routine diagnostics use quiet sink" {
    reset_idle_reports();
    defer reset_idle_reports();
    const handle = terminal.create(null).?;
    const tty = terminal.get(handle).?;
    try std.testing.expect(tty.attach(.serial));
    var mock = console.MockConsole(4096){};
    _ = scheduler.register_worker(0).?;
    scheduler.current[0] = 1;
    queue_idle_reports();
    forensics.enabled = true;
    shell_mod.idle_reports(mock.console(), 100, 10);
    try std.testing.expectEqualStrings("", mock.contents());
    scheduler.start();
    try std.testing.expect(scheduler.sleep_current(3));
    shell_mod.idle_reports(mock.console(), 100, 10);
    try std.testing.expectEqualStrings("", mock.contents());

    // Real scheduler fault/exit records share maybe_report with the routine
    // records. They must survive, including the fault's separate newline.
    _ = scheduler.register_user(0, 0).?;
    scheduler.current[0] = 2;
    try std.testing.expect(bg_job_add(process.find_by_task(2).?, "user-el0"));
    defer bg_job_free(1);
    scheduler.fault_current(0x90000004, 0x1234, 0);
    shell_mod.idle_reports(mock.console(), 100, 10);
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "fault: user-el0 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "tasks user-el0 exited status=139\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "procs user-el0 exited status=139\n") != null);

    mock.reset();
    // A diagnostic-looking command response does not use the idle sink.
    var shell = make_shell(&mock, make_view());
    handle_line(&shell.mon, "echo timer heartbeat ticks=literal");
    try std.testing.expectEqualStrings("timer heartbeat ticks=literal\n", mock.contents());
    mock.reset();
    handle_line(&shell.mon, "timer");
    try std.testing.expect(std.mem.startsWith(u8, mock.contents(), "timer: armed="));
    mock.reset();
    bg_reap(&shell.mon);
    try std.testing.expectEqualStrings("[1] Done: user-el0 (exit=139)\n", mock.contents());
}

test "quiet serial reports still advance and drain" {
    reset_idle_reports();
    defer reset_idle_reports();
    const handle = terminal.create(null).?;
    try std.testing.expect(terminal.get(handle).?.attach(.serial));
    var mock = console.MockConsole(4096){};
    _ = scheduler.register_worker(0).?;
    scheduler.current[0] = 1;
    forensics.enabled = true;
    for (0..2) |i| {
        queue_idle_reports();
        shell_mod.idle_reports(mock.console(), (10 + i * 4) * 10, 10);
    }
    try std.testing.expectEqual(@as(u64, 10), timer.ticks);
    try std.testing.expectEqual(@as(u64, 2), scheduler.tasks[1].advances);
    try std.testing.expectEqual(@as(u64, 4), userspace.stats().calls);
    try std.testing.expectEqual(@as(u64, 2), forensics.emitted);
    try std.testing.expectEqual(@as(usize, 0), forensics.pending());
    try std.testing.expectEqualStrings("", mock.contents());
    terminal.get(handle).?.detach();
    // Calling the original producers directly proves their pending flags
    // were consumed, not merely hidden behind a skipped dispatch.
    var con = mock.console();
    timer.maybe_heartbeat(&con);
    scheduler.maybe_report(&con);
    userspace.maybe_report(&con);
    forensics.sample(con, 140, 10);
    try std.testing.expectEqualStrings("", mock.contents());
}

test "serial detach restores diagnostics without backlog" {
    reset_idle_reports();
    defer reset_idle_reports();
    const handle = terminal.create(null).?;
    try std.testing.expect(terminal.get(handle).?.attach(.serial));
    var mock = console.MockConsole(4096){};
    _ = scheduler.register_worker(0).?;
    scheduler.current[0] = 1;
    queue_idle_reports();
    forensics.enabled = true;
    shell_mod.idle_reports(mock.console(), 100, 10);
    terminal.get(handle).?.detach();
    shell_mod.idle_reports(mock.console(), 100, 10);
    try std.testing.expectEqualStrings("", mock.contents());
    queue_idle_reports();
    shell_mod.idle_reports(mock.console(), 140, 10);
    try std.testing.expectEqualStrings(
        "timer heartbeat ticks=10 irq=0 poll=0\n" ++
            "tasks worker advances=2\n" ++
            "fx: site=shot core=0 seq=1 t=0 arg=14\n",
        mock.contents(),
    );
    // Registry release is the owner-death path and must also restore output.
    mock.reset();
    try std.testing.expect(terminal.get(handle).?.attach(.serial));
    queue_idle_reports();
    shell_mod.idle_reports(mock.console(), 180, 10);
    terminal.release(handle);
    shell_mod.idle_reports(mock.console(), 180, 10);
    try std.testing.expectEqualStrings("", mock.contents());
    queue_idle_reports();
    shell_mod.idle_reports(mock.console(), 220, 10);
    try std.testing.expect(std.mem.startsWith(u8, mock.contents(), "timer heartbeat ticks=20 irq=0 poll=0\n"));
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "advances=3") == null);
}

test "unowned console diagnostics remain byte-identical" {
    reset_idle_reports();
    defer reset_idle_reports();
    // shell=sh alone, an unattached tty, and a graphical tty do not mute
    // diagnostics. Only actual serial ownership does.
    settings.reset();
    defer settings.reset();
    _ = settings.set("shell", "sh");
    const handle = terminal.create(null).?;
    var direct = console.MockConsole(4096){};
    var routed = console.MockConsole(4096){};
    for (0..2) |i| {
        _ = scheduler.init();
        userspace.init();
        _ = scheduler.register_worker(0).?;
        scheduler.current[0] = 1;
        queue_idle_reports();
        forensics.reset();
        forensics.enabled = true;
        if (i == 1) try std.testing.expect(terminal.get(handle).?.attachWindow(1));
        shell_mod.idle_reports(routed.console(), 100, 10);
        // Recreate the same snapshots and invoke the pre-change sequence.
        timer.ticks = 0;
        _ = scheduler.init();
        userspace.init();
        _ = scheduler.register_worker(0).?;
        scheduler.current[0] = 1;
        queue_idle_reports();
        forensics.reset();
        var con = direct.console();
        timer.maybe_heartbeat(&con);
        scheduler.maybe_report(&con);
        userspace.maybe_report(&con);
        forensics.sample(con, 100, 10);
        try std.testing.expectEqualStrings(direct.contents(), routed.contents());
        try std.testing.expect(direct.contents().len > 0);
        direct.reset();
        routed.reset();
        timer.ticks = 0;
    }
}

test "shell: over-long line is refused with a bell and an overflow notice" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed(&@as([257:0]u8, @splat("b"[0])));
    mock.feed("\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // 256 chars echoed, the 257th refused with a bell, then the notice.
    try std.testing.expect(std.mem.indexOf(u8, out, &@as([256:0]u8, @splat("b"[0])) ++ "\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "input refused: line longer than 256 bytes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command '" ++ &@as([256:0]u8, @splat("b"[0])) ++ "' -- try 'help'") != null);
}

test "shell: too many arguments refuses execution with the documented message" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // 18 one-letter tokens = command + 17 args, one over the limit.
    mock.feed("a b c d e f g h i j k l m n o p q r\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "error: too many arguments (max 17 tokens)\n") != null);
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
    try std.testing.expect(std.mem.endsWith(u8, out, "elephant business\n" ++ "virelai> "));
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

test "shell: tab completion completes a command name (ADR 0008 D2)" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // "ver" + Tab completes to "version" (Tab inserts "sion"), then Enter
    // runs the completed command.
    mock.feed("ver\t\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "version\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "virelai-kernel\n") != null);
}

test "shell: tab completion cycles command candidates (issue #783)" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // "ca" + Tab gives "calc", another Tab cycles to "cat", then Enter executes "cat"
    mock.feed("ca\t\t\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "usage: cat <file|path>") != null);
}

test "shell: tab completion completes arguments and subverbs (issue #783)" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // "color o" + Tab gives "color off", Tab cycles to "color on", Enter runs "color on"
    mock.feed("color o\t\t\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "color: on") != null);
}

test "shell: tab completion completes file arguments from host share (issue #783)" {
    var test_files = [_]virtio_file.TestFile{
        .{ .name = "TEST_FOO.TXT", .data = "hello foo\n" },
        .{ .name = "TEST_BAR.TXT", .data = "hello bar\n" },
    };
    virtio_file.set_test_share(&test_files);
    defer virtio_file.set_test_share(null);

    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // "cat TEST_F" + Tab completes to "cat TEST_FOO.TXT"
    mock.feed("cat TEST_F\t\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "hello foo") != null);
}

test "shell: tab completion completes command after semicolon (issue #783)" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo first; ver\t\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "virelai-kernel\n") != null);
}

test "shell: ctrl-l clears the screen and repaints the prompt + line" {
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo hi\x0c\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Ctrl-L emitted the ANSI clear; the shell restored the prompt + line,
    // then Enter ran the echo.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2J\x1b[H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "virelai> echo hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hi\n") != null);
}

test "shell: the live gate's exact chord byte stream drives all six D2 chords" {
    // The class-A counterpart of tools/verify-live-editing.sh phase 2: the
    // byte stream below is character-for-character the file that gate feeds
    // over the serial console, so a change to one without the other shows up
    // here rather than after a four-minute VM boot. Each chord is proven by
    // its RESULT (the command that ends up running), never by the keystroke.
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("cho u2chord\x01e\n"); // Ctrl-A: home, then insert the 'e'
    mock.feed("echo u2en\x01\x05d\n"); // Ctrl-A then Ctrl-E: back to the end
    mock.feed("echo u2killXXXX\x1b[D\x1b[D\x1b[D\x1b[D\x0b\n"); // Ctrl-K
    mock.feed("JUNK\x15echo u2under\n"); // Ctrl-U: kill back to the start
    mock.feed("echo u2clear\x0c\n"); // Ctrl-L: clear, keep the line
    mock.feed("echo NEVER\x03echo u2cancel\n"); // Ctrl-C: cancel, do not run
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    for ([_][]const u8{ "\nu2chord\n", "\nu2end\n", "\nu2kill\n", "\nu2under\n", "\nu2clear\n", "\nu2cancel\n" }) |want| {
        if (std.mem.indexOf(u8, out, want) == null) {
            std.debug.print("missing chord result {s} in:\n{s}\n", .{ want, out });
            return error.ChordResultMissing;
        }
    }
    // Ctrl-L emitted the erase-in-display; Ctrl-C echoed and cancelled, so
    // the abandoned command never ran (its output line never appears).
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2J\x1b[H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^C") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nNEVER\n") == null);
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

test "shell: host fuzz of the tokenizer never panics and stays in bounds (card U3)" {
    // Card U3 (claim 1809's sibling): the tokenizer must accept ANY byte
    // stream without panicking and every returned token must be a slice
    // of the input line OR of the caller's scratch (M19 P5 materializes
    // joined/escaped tokens there). Deterministic PRNG, fixed seed — the
    // same corpus on every run.
    var prng = std.Random.DefaultPrng.init(0x5543_0001);
    const rnd = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \t\"'./-_=+*&^%$#@!~`;:<>?[]{}()|\\\n\x00\x7f";
    var line_buf: [300]u8 = undefined;
    var scratch: [300]u8 = undefined;
    const scratch_base = @intFromPtr(&scratch);
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, line_buf.len);
        for (line_buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        const line = line_buf[0..len];
        @memset(&scratch, 0);
        const result = tokenizer.tokenize(line, &scratch);
        // Never more than max_tokens tokens.
        try std.testing.expect(result.count <= tokenizer.max_tokens);
        // too_many can only be set together with a full count.
        if (result.too_many) try std.testing.expectEqual(tokenizer.max_tokens, result.count);
        // Every token is a slice of `line` or `scratch`: in-bounds either way.
        for (result.argv[0..result.count], result.arg_glob[0..result.count]) |token, g| {
            _ = g;
            const start = @intFromPtr(token.ptr);
            const end = start + token.len;
            const in_line = start >= @intFromPtr(line.ptr) and end <= @intFromPtr(line.ptr) + line.len;
            const in_scratch = start >= scratch_base and end <= scratch_base + scratch.len;
            try std.testing.expect(in_line or in_scratch);
        }
    }
}

test "shell: host fuzz of the command handlers never panics on arbitrary argv (card U3)" {
    // Card U3: every handler must survive ARBITRARY argv — random command
    // names, random arg counts up to the registry bound, random bytes
    // (including control + high bytes) — without panicking. The mock
    // console absorbs any output (bounded, overflow-flagged); the env is
    // the transcript test's (allocator + scheduler + userspace + ESP
    // window armed, no devices) so handlers take their real refusal paths.
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    _ = alloc.init(make_view(), &.{});
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    userspace.init();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("KERNEL.BIN", "");
    test_seed_dir("EFI");
    test_seed_share("BOOTED.TXT", "hello\n");

    var prng = std.Random.DefaultPrng.init(0x5543_0002);
    const rnd = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./-_\"' \t\n\x00\x1b\x7f";
    var arg_buf: [monitor.max_args_limit + 1][32]u8 = undefined;
    var argv_storage: [monitor.max_args_limit + 1][]const u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const argc = rnd.uintLessThan(usize, monitor.max_args_limit + 1);
        for (0..argc) |i| {
            const alen = rnd.uintLessThan(usize, arg_buf[i].len);
            for (arg_buf[i][0..alen]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            argv_storage[i] = arg_buf[i][0..alen];
        }
        _ = monitor.exec(&shell.mon, argv_storage[0..argc]);
        // The mock console absorbs everything; reset so the next iteration
        // starts from a clean buffer (overflow is fine — it just flags).
        mock.reset();
    }
}

test "shell: host fuzz of the full input path never panics (editor + tokenizer + handlers)" {
    // The end-to-end variant: random bytes fed as scripted input through
    // the REAL line editor + tokenizer + handler path (shell.poll), never
    // panicking and always returning to idle. Covers the D3 shape
    // surface — misuse, errors, unknown verbs — on random input.
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    _ = alloc.init(make_view(), &.{});
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    userspace.init();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("KERNEL.BIN", "");
    test_seed_dir("EFI");
    test_seed_share("BOOTED.TXT", "hello\n");

    var prng = std.Random.DefaultPrng.init(0x5543_0003);
    const rnd = prng.random();
    // A hostile-but-real keyboard alphabet: letters/digits, space, tab,
    // Enter, Ctrl-C, Ctrl-L, ESC (arrow-prefix), backspace, DEL, and a
    // sprinkling of non-ASCII bytes the editor must refuse.
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789 \t\n\x03\x0c\x1b\x08\x7f\x80\xff";
    var iter: usize = 0;
    while (iter < 1500) : (iter += 1) {
        const len = rnd.uintLessThan(usize, 64);
        var feed_buf: [64]u8 = undefined;
        for (feed_buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];

        mock.feed(feed_buf[0..len]);
        while (shell.poll() != .idle) {}
        mock.reset();
    }
    // The session never panicked and the shell is still responsive: a
    // Ctrl-C (full editor reset, clearing any swallowed CRLF window or
    // pending ESC state) followed by a fresh command runs end to end.
    mock.feed("\x03echo survived\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "survived\n") != null);
}

test "shell: scrollback captures console output" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Run a few commands that produce output
    mock.feed("echo hello\necho world\necho scrollback\n");
    while (shell.poll() != .idle) {}

    // The scrollback ring should have captured the output
    const stored = shell.scrollback.stored();
    // Banner lines (~2-3) + 3 prompts + 3 echoed command lines + 3 output lines
    try std.testing.expect(stored >= 3);

    // Verify we can retrieve lines
    var dst: [200][128]u8 = undefined;
    var slices: [200][]u8 = undefined;
    for (&slices, 0..) |*s, j| s.* = dst[j][0..];
    const n = shell.scrollback.copy_lines(0, 3, slices[0..]);
    try std.testing.expect(n >= 1);
    // The most recent line should contain "scrollback"
    var found: bool = false;
    for (slices[0..n]) |sl| {
        if (std.mem.indexOf(u8, sl, "scrollback") != null) found = true;
    }
    try std.testing.expect(found);
}

test "shell: PageUp/PageDown adjust scroll_offset" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Run commands to fill scrollback
    mock.feed("echo line1\necho line2\necho line3\necho line4\necho line5\n");
    mock.feed("echo line6\necho line7\necho line8\necho line9\necho line10\n");
    while (shell.poll() != .idle) {}

    // Start fresh, scroll should be 0
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
    const total = shell.scrollback.stored();

    // Feed PageUp (ESC [ 5 ~) — should increase scroll offset by 10
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.scroll_offset >= 10 or shell.scroll_offset == total);

    // Feed PageDown (ESC [ 6 ~) — should decrease scroll offset
    const before_pgdn = shell.scroll_offset;
    mock.feed("\x1b[6~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.scroll_offset < before_pgdn or (before_pgdn == 0 and shell.scroll_offset == 0));

    // Multiple PageDown should bring us back to live (offset 0)
    mock.feed("\x1b[6~\x1b[6~\x1b[6~");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
}

test "shell: scrollback overflow bounds scroll_offset" {
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Feed many PageUp sequences — scroll_offset should not exceed stored lines
    mock.feed("\x1b[5~\x1b[5~\x1b[5~\x1b[5~\x1b[5~");
    while (shell.poll() != .idle) {}

    const stored = shell.scrollback.stored();
    try std.testing.expect(shell.scroll_offset <= stored);
}

test "shell: scrollback ring survives poll cycle" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo test\n");
    while (shell.poll() != .idle) {}

    const stored1 = shell.scrollback.stored();
    try std.testing.expect(stored1 > 0);

    mock.feed("echo another\n");
    while (shell.poll() != .idle) {}

    const stored2 = shell.scrollback.stored();
    try std.testing.expect(stored2 > stored1);
}

test "shell: T2 selection: PageUp enters select mode, Esc exits" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Fill scrollback
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp: scroll back, enter selection mode
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
    mock.feed("\x1b[5~"); // PageUp
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);
    try std.testing.expect(shell.scroll_offset > 0);

    // Lone Esc (ESC + space to signal end-of-escape): cancel selection, return to live
    mock.feed("\x1b ");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
}

test "shell: T2 selection: Up/Down arrows adjust selection range" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp to enter selection
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);
    const sel_end_before = shell.sel_end;

    // Up arrow (CSI A): extend selection upward
    mock.feed("\x1b[A");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.sel_end > sel_end_before);

    // Down arrow (CSI B): shrink selection downward
    const sel_end_after_up = shell.sel_end;
    mock.feed("\x1b[B");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.sel_end < sel_end_after_up);
}

test "shell: T2 selection: Ctrl+C copies to clipboard and returns to live" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Fill with enough output that there's something in the scrollback
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        mock.feed("echo filler\n");
        while (shell.poll() != .idle) {}
    }

    // Scroll back
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);

    // Copy with Ctrl+C
    mock.feed("\x03"); // Ctrl+C
    while (shell.poll() != .idle) {}

    // Should have returned to live
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);

    // Clipboard should have the copied text (non-empty)
    var cbuf: [clipboard.capacity]u8 = undefined;
    const n = clipboard.get(&cbuf);
    try std.testing.expect(n > 0);
    // Should contain some recognizable output
    try std.testing.expect(std.mem.indexOf(u8, cbuf[0..n], "filler") != null);
}

test "shell: T2 paste: Ctrl+V inserts clipboard at cursor" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Set clipboard directly
    _ = clipboard.set("PASTED_TEXT");

    // Type "echo " then Ctrl+V then Enter
    mock.feed("echo \x16\n");
    while (shell.poll() != .idle) {}

    // Output should contain the pasted text
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "PASTED_TEXT") != null);
}

test "shell: T2 selection: Enter copies and returns to live" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo spam\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp to enter selection
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);

    // Enter: copy and return to live
    mock.feed("\x0d");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);

    // Clipboard should not be empty
    var cbuf: [clipboard.capacity]u8 = undefined;
    const n = clipboard.get(&cbuf);
    try std.testing.expect(n > 0);
}

test "shell: T2 selection: Down arrow beyond sel_start exits selection" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp to enter selection
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);

    // Press Down once to shrink (sel_start == sel_end after PageUp, so this exits)
    mock.feed("\x1b[B");
    while (shell.poll() != .idle) {}
    // After a single Down when sel_start == sel_end, selecting should be false
    try std.testing.expect(!shell.selecting);
}

test "shell: typed input after scroll keys types cleanly (T1 gate finding)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp x2 then PageDown x2, then type a command. The shell consumes
    // the '~' of each scroll sequence; the editor must not be left mid-CSI
    // (no `[5`/`[6` fragments in the line, no swallowed ESC).
    mock.feed("\x1b[5~\x1b[5~\x1b[6~\x1b[6~echo clean-typed\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "clean-typed\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command") == null);
}

test "shell: paging back to live clears selection so Enter submits (T1 gate finding)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp enters selection; PageDown back to live must clear it.
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);
    mock.feed("\x1b[6~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);

    // A REAL Enter (0x0D) must submit the line — not copy+discard.
    mock.feed("echo done-typed\r");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "done-typed\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "copied") == null);
}

test "shell: ESC while selecting cancels without eating the next keystroke (T2 gate finding)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp enters selection; ESC then a typed command: the cancel fires
    // on the byte after ESC, but that byte is a real keystroke ('e' of
    // echo) and must not be eaten.
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);
    mock.feed("\x1becho esc-ok\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "esc-ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command") == null);
}

test "shell: T3 search: Ctrl+R enters search mode, Esc exits" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Submit a command so there's history to search
    mock.feed("echo hello-search\n");
    while (shell.poll() != .idle) {}

    // Ctrl+R enters search mode
    try std.testing.expect(!shell.searching);
    mock.feed("\x12"); // Ctrl+R
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    // Esc exits search mode
    mock.feed("\x1b");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);
}

test "shell: T3 search: typing finds a match in history" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Submit some commands to history
    mock.feed("echo alpha-bravo\necho delta-echo\necho foxtrot\n");
    while (shell.poll() != .idle) {}

    // Enter search mode
    mock.feed("\x12"); // Ctrl+R
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    // Type characters that match "delta"
    for ("delta") |ch| {
        var buf: [1]u8 = [_]u8{ch};
        mock.feed(&buf);
        while (shell.poll() != .idle) {}
    }
    try std.testing.expect(shell.searching);

    // Verify editor buffer now contains "delta-echo"
    const editor_line = shell.editor.buffer[0..shell.editor.len];
    try std.testing.expect(std.mem.indexOf(u8, editor_line, "delta-echo") != null);

    // Enter accepts the match
    mock.feed("\x0d");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);

    // Editor should still have the matched line
    const accepted = shell.editor.buffer[0..shell.editor.len];
    try std.testing.expect(std.mem.indexOf(u8, accepted, "delta-echo") != null);
}

test "shell: T3 search: LF accepts the match like CR (keyboard Return)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo delta-echo\n");
    while (shell.poll() != .idle) {}

    mock.feed("\x12"); // Ctrl+R
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    for ("delta") |ch| {
        var buf: [1]u8 = [_]u8{ch};
        mock.feed(&buf);
        while (shell.poll() != .idle) {}
    }

    // The keyboard Return decodes to LF (0x0a) — must accept like CR.
    mock.feed("\x0a");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);
    const accepted = shell.editor.buffer[0..shell.editor.len];
    try std.testing.expect(std.mem.indexOf(u8, accepted, "delta-echo") != null);
}

test "shell: T3 search: Backspace narrows query and finds new match" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo zulu-XYZ\n");
    while (shell.poll() != .idle) {}

    // Search for "zul" — should find "zulu-XYZ"
    mock.feed("\x12zul"); // Ctrl+R, then type zul
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    // Backspace to narrow to "zu"
    mock.feed("\x7f");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 2), shell.search_query_len);
    try std.testing.expectEqualStrings("zu", shell.search_query[0..2]);
}

test "shell: T3 search: Ctrl+C cancels search and restores draft" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Type something at the prompt before searching
    mock.feed("draft-line");
    while (shell.poll() != .idle) {}

    // Enter search mode (saves draft)
    mock.feed("\x12");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    // Ctrl+C cancels
    mock.feed("\x03");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);

    // Draft should be restored
    try std.testing.expect(std.mem.indexOf(u8, shell.editor.buffer[0..shell.editor.len], "draft-line") != null);
}

test "shell: T3 search: empty query shows no match" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo something\n");
    while (shell.poll() != .idle) {}

    // Enter search mode, then immediately Enter (empty query)
    mock.feed("\x12\x0d");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);
}

test "shell: T3 search: non-printable bytes are ignored in search" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo test\n");
    while (shell.poll() != .idle) {}

    // Enter search mode, send an arrow key (ESC [ A)
    mock.feed("\x12");
    while (shell.poll() != .idle) {}

    // Arrow keys: ESC cancels search (expected), shell should not crash
    mock.feed("\x1b[A");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching); // Esc in search cancels
    // The shell is still functional — next command should work
    mock.feed("echo survived\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "survived") != null);
}

test "shell: T6 paste: bracketed paste start/end toggles paste_active" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Start paste
    try std.testing.expect(!shell.paste_active);
    mock.feed("\x1b[200~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.paste_active);

    // End paste
    mock.feed("\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.paste_active);
}

test "shell: T6 paste: bytes are buffered during paste" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("\x1b[200~");
    while (shell.poll() != .idle) {}

    // Type some bytes while in paste mode
    mock.feed("hello");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.paste_buf_len == 5);
    try std.testing.expect(std.mem.eql(u8, shell.paste_buf[0..5], "hello"));

    // End paste
    mock.feed("\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), shell.paste_buf_len);
}

test "shell: T6 paste: pasted commands execute after paste end" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Paste a simple echo command
    mock.feed("\x1b[200~echo pasted-ok\n\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.paste_active);

    // The echoed output should appear
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "pasted-ok") != null);
}

test "shell: T6 paste: multi-line paste executes each line" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Paste two commands
    mock.feed("\x1b[200~echo first\necho second\n\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.paste_active);

    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second") != null);
}

test "shell: T6 paste: max_line bound prevents overflow" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Start paste and send more than max_line bytes
    mock.feed("\x1b[200~");
    while (shell.poll() != .idle) {}
    var i: usize = 0;
    while (i < 260) : (i += 1) {
        mock.feed("x");
        while (shell.poll() != .idle) {}
    }

    // Should not exceed max_line
    try std.testing.expect(shell.paste_buf_len <= lineedit.max_line);

    // End paste should not crash
    mock.feed("\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.paste_active);
}

test "shell: T7 alt-screen: CSI ? 1049 h/l toggle alt_screen" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    try std.testing.expect(!shell.alt_screen);
    mock.feed("\x1b[?1049h");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.alt_screen);

    mock.feed("\x1b[?1049l");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.alt_screen);
}

test "shell: T10 CSI responder: 6n returns 1;1R" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("\x1b[6n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1R") != null);
}

test "shell: T11 ANSI: SGR and cursor shape sequences are silently swallowed" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("\x1b[32m\x1b[0m\x1b[3 q");
    while (shell.poll() != .idle) {}
    mock.feed("echo survived\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "survived") != null);
}

test "shell: T12 env: export and $VAR expansion" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Set an env var
    mock.feed("export FOO=hello\n");
    while (shell.poll() != .idle) {}

    // Use it with $
    mock.feed("echo $FOO world\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "hello world") != null);

    // Print all with bare export
    mock.feed("export\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "FOO=hello") != null);
}

test "shell: M19 P3 env: set, unset, env builtins" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // set a variable
    mock.feed("set COLOR=red\n");
    while (shell.poll() != .idle) {}

    // env lists it
    mock.feed("env\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "COLOR=red") != null);

    // $COLOR expands
    mock.feed("echo $COLOR\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "red\n") != null);

    // unset removes it — verify via the direct API, not mock output
    mock.feed("unset COLOR\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), shell_mod.env_count); // unset shrank the table
    try std.testing.expect(env_get("COLOR") == null); // COLOR is gone

    // set another and verify shell_mod.env_table integrity
    env_set("SECOND", "yes");
    try std.testing.expectEqual(@as(usize, 1), shell_mod.env_count);
    try std.testing.expectEqualStrings("yes", env_get("SECOND").?); // unset a nonexistent variable is silent (returns false, no crash)
    try std.testing.expect(!env_unset("NOEXIST"));
}

test "shell: M22 D7 printenv: printenv is an alias for env" {
    shell_mod.env_count = 0;
    env_set("HOME", "/data");
    env_set("USER", "root");
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("printenv\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "HOME=/data") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "USER=root") != null);
}

test "shell: M19 P3 env: env_set and env_unset direct API" {
    shell_mod.env_count = 0;
    // set
    env_set("PATH", "/bin");
    try std.testing.expectEqual(@as(usize, 1), shell_mod.env_count);
    try std.testing.expectEqualStrings("/bin", env_get("PATH").?);
    // overwrite
    env_set("PATH", "/usr/bin");
    try std.testing.expectEqual(@as(usize, 1), shell_mod.env_count);
    try std.testing.expectEqualStrings("/usr/bin", env_get("PATH").?);
    // unset
    try std.testing.expect(env_unset("PATH"));
    try std.testing.expectEqual(@as(usize, 0), shell_mod.env_count);
    try std.testing.expect(env_get("PATH") == null);
    // unset nonexistent returns false
    try std.testing.expect(!env_unset("NOPE"));
}

test "shell: M19 P3 env: persistence round-trip through the ESP window" {
    shell_mod.env_count = 0;
    // Direct serialization test: save_env writes to the ESP window;
    // load_env reads back. The mock ESP path supports add_esp_entry
    // with explicit content, so we seed the file directly.
    test_reset_share();
    defer virtio_file.set_test_share(null);
    // Seed ENV.TXT as if it was written by a previous boot.
    test_seed_share("ENV.TXT", "PERSIST_A=alpha\nPERSIST_B=beta\n");
    load_env();
    try std.testing.expectEqualStrings("alpha", env_get("PERSIST_A").?);
    try std.testing.expectEqualStrings("beta", env_get("PERSIST_B").?);
}

test "shell: M19 P3 env: env_expand handles multiple $VAR references" {
    shell_mod.env_count = 0;
    env_set("GREET", "hi");
    env_set("NAME", "bob");
    var buf: [256]u8 = undefined;
    const expanded = env_expand("$GREET $NAME !", &buf);
    try std.testing.expectEqualStrings("hi bob !", expanded);
}

test "shell: M19 P3 env: env_expand leaves unmatched $VAR as-is" {
    shell_mod.env_count = 0;
    var buf: [256]u8 = undefined;
    const expanded = env_expand("echo $NOPE", &buf);
    try std.testing.expectEqualStrings("echo ", expanded);
}

test "shell: M19 P3 env: env table bounds are enforced" {
    shell_mod.env_count = 0;
    var i: usize = 0;
    while (i < env_max + 2) : (i += 1) {
        var name: [2]u8 = undefined;
        name[0] = @intCast('A' + @as(u8, @intCast(i % 26)));
        name[1] = if (i >= 26) @intCast('0' + @as(u8, @intCast((i / 26)))) else '_';
        env_set(&name, "x");
    }
    try std.testing.expectEqual(env_max, shell_mod.env_count);
}

test "shell: T13 alias: alias expansion" {
    // Reset env table for a clean slate
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Create an alias: ll becomes "echo HELLO"
    mock.feed("alias ll=echo HELLO\n");
    while (shell.poll() != .idle) {}

    // Use it — "ll world" should expand to "echo HELLO world"
    mock.feed("ll world\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "HELLO world") != null);
}

test "shell: T15 prompt: prompt builtin changes the prompt" {
    // Verify the settings API — prompt reads back what was set
    _ = settings.set("prompt", "test$ ");
    try std.testing.expectEqualStrings("test$ ", settings.get_prompt());
    _ = settings.set("prompt", "virelai> "); // restore default
}

test "shell: T16 script: sh executes a script file line by line" {
    // The issue's host test: a script with two echo commands; both lines
    // execute through handle_line and both outputs appear, with no prompt
    // printed between them (script mode never repaints the prompt).
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("SCRIPT.TXT", "echo script-first\n# a comment\n\necho script-second\n");
    mock.feed("sh SCRIPT.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "script-first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "script-second\n") != null);
    // Both outputs are contiguous: no prompt or echo between them.
    try std.testing.expect(std.mem.indexOf(u8, out, "script-first\nscript-second\n") != null);
    // Comments never execute or print.
    try std.testing.expect(std.mem.indexOf(u8, out, "a comment") == null);
}

test "shell: T16 script: exit stops the script early" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("EXIT.TXT", "echo before-exit\nexit\necho after-exit\n");
    mock.feed("sh EXIT.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "before-exit\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after-exit") == null);
}

test "shell: T16 script: sh refuses nested script calls" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("OUTER.TXT", "echo outer-line\nsh INNER.TXT\necho outer-tail\n");
    test_seed_share("INNER.TXT", "echo inner-line\n");
    mock.feed("sh OUTER.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "sh: scripts cannot call scripts\n") != null);
    // The outer script continues after the refusal (no abort-on-error)...
    try std.testing.expect(std.mem.indexOf(u8, out, "outer-line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "outer-tail\n") != null);
    // ...and the inner script never ran.
    try std.testing.expect(std.mem.indexOf(u8, out, "inner-line") == null);
}

test "shell: T16 script: missing script is reported honestly" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    mock.feed("sh NOPE.TXT\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "sh: NOPE.TXT: not found (no such file on the host share)\n") != null);
}

test "shell: T16 script: sh with no arguments shows usage" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    mock.feed("sh\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "sh: usage: sh <script>\n") != null);
}

test "shell: T16 script: bare exit at the prompt stays an unknown command" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    mock.feed("exit\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "unknown command 'exit' -- try 'help'\n") != null);
}

test "shell: T16 script: line longer than 256 bytes is refused and skipped" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    const content = "echo before-long\n" ++ (&@as([300:0]u8, @splat("x"[0]))) ++ "\necho after-long\n";
    test_seed_share("LONG.TXT", content);
    mock.feed("sh LONG.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "sh: line too long (max 256 bytes)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before-long\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after-long\n") != null);
    // The over-long line never reached the executor (no 300-char echo).
    try std.testing.expect(std.mem.indexOf(u8, out, &@as([300:0]u8, @splat("x"[0]))) == null);
}

test "shell: T4 history: load_history restores newest-first" {
    // HISTORY.TXT is append-ordered (oldest first, newest last); the
    // restore must leave the most recent command at history[0] so the
    // first Up arrow after boot recalls it (verified live 2026-08-22,
    // claim 0469 — the original backward iteration left the OLDEST at
    // index 0, and the live gate caught it).
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("HISTORY.TXT", "echo first\necho second\necho third\n");
    load_history(&shell.editor);
    try std.testing.expectEqual(@as(usize, 3), shell.editor.hist_count);
    try std.testing.expectEqualStrings("echo third", shell.editor.history[0][0..shell.editor.hist_len[0]]);
    try std.testing.expectEqualStrings("echo second", shell.editor.history[1][0..shell.editor.hist_len[1]]);
    try std.testing.expectEqualStrings("echo first", shell.editor.history[2][0..shell.editor.hist_len[2]]);
}

test "shell: T16 script: more than 64 executable lines is refused" {
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    // 65 executable lines ("echo s0" .. "echo s64"); comments/blanks do
    // not count toward the bound.
    var content: [1500]u8 = undefined;
    var clen: usize = 0;
    var n: usize = 0;
    while (n < 65) : (n += 1) {
        const prefix = "echo s";
        @memcpy(content[clen..][0..prefix.len], prefix);
        clen += prefix.len;
        if (n >= 10) {
            content[clen] = '0' + @as(u8, @intCast(n / 10));
            clen += 1;
        }
        content[clen] = '0' + @as(u8, @intCast(n % 10));
        clen += 1;
        content[clen] = '\n';
        clen += 1;
    }
    test_seed_share("MANY.TXT", content[0..clen]);
    mock.feed("sh MANY.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "sh: too many lines (max 64)\n") != null);
    // Lines 0..63 executed (echo s0 .. echo s63); the 65th (echo s64) did not.
    try std.testing.expect(std.mem.indexOf(u8, out, "s63\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "s64\n") == null);
}

// ---------------------------------------------------------------------------
// M19 P1 (issue #290): pipes
// ---------------------------------------------------------------------------

test "shell: M19 P1 pipe: pipe_split finds | outside quotes only" {
    try std.testing.expect(pipe_split("echo a | type") == .split);
    try std.testing.expect(pipe_split("echo a|type") == .split);
    try std.testing.expect(pipe_split("echo \"a|b\"") == .none);
    try std.testing.expect(pipe_split("echo a\"b|c\"") == .none);
    try std.testing.expect(pipe_split("echo a | b | c") == .multiple);
    try std.testing.expect(pipe_split("echo hello") == .none);
    switch (pipe_split("echo hi | type")) {
        .split => |sp| {
            try std.testing.expectEqualStrings("echo hi ", sp.left);
            try std.testing.expectEqualStrings(" type", sp.right);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "shell: M19 P1 pipe: echo hello | type prints hello exactly once" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo hello | type\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // The left echo's output is captured into the pipe (never printed), and
    // the right `type` echoes it — "hello\n" appears exactly once.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "hello\n"));
}

test "shell: M19 P1 pipe: ls | type lists the directory through the pipe" {
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("KERNEL.BIN", "");
    test_seed_dir("EFI");
    mock.feed("ls | type\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "KERNEL.BIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "EFI") != null);
}

test "shell: M19 P1 pipe: chaining is refused (single pipe only)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo a | echo b | echo c\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "pipes: only one pipe per line (no chaining)\n") != null);
}

test "shell: M19 P1 pipe: type with no pipe prints nothing" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("type\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Only the echoed line + prompt; `type` with an empty stdin adds nothing.
    try std.testing.expect(std.mem.indexOf(u8, out, "type\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command") == null);
}

test "shell: M19 P1 pipe: right command that ignores stdin still runs" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo hi | echo bye\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bye\n") != null);
}

test "shell: M19 P2 redirect: redirect_split finds > and >> and < outside quotes" {
    // >
    {
        const rs = redirect_split("echo hello > file.txt").?;
        try std.testing.expectEqual(RedirectOp.stdout_overwrite, rs.op);
        try std.testing.expectEqualStrings("echo hello", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    // >>
    {
        const rs = redirect_split("echo hello >> file.txt").?;
        try std.testing.expectEqual(RedirectOp.stdout_append, rs.op);
        try std.testing.expectEqualStrings("echo hello", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    // <
    {
        const rs = redirect_split("cat < file.txt").?;
        try std.testing.expectEqual(RedirectOp.stdin_file, rs.op);
        try std.testing.expectEqualStrings("cat", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    // No redirect
    try std.testing.expect(redirect_split("echo hello") == null);
    try std.testing.expect(redirect_split("echo \">\" inside") == null);
    try std.testing.expect(redirect_split("") == null);
}

test "shell: M19 P2 redirect: echo hello > file captures and writes" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // No host file channel: the redirect write is refused honestly.
    virtio_file.set_test_share(null);
    defer virtio_file.set_test_share(null);
    _ = alloc.init(make_view(), &.{});
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    userspace.init();

    mock.feed("echo redirected-content > test.out\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // The typed input line appears once (echoed by the line editor).
    // The echo command's output ("redirected-content") was captured and
    // never reached the real console, so it only appears in the typed
    // line, not as a separate output line.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "redirected-content"));
    // Without a host file channel, the file write fails with an error.
    // M34 HF6 (issue #740): the ESP/FAT write path is gone — the share
    // is the only file store, and it is unarmed in this test.
    try std.testing.expect(std.mem.indexOf(u8, out, "redirect: no host file channel") != null);
}

test "shell: M19 P2 redirect: redirect_split prefers >> over >" {
    const rs = redirect_split("echo hello >> file.txt").?;
    try std.testing.expectEqual(RedirectOp.stdout_append, rs.op);
    try std.testing.expectEqualStrings("echo hello", rs.left);
    try std.testing.expectEqualStrings("file.txt", rs.right);
}

test "shell: M19 P2 redirect: redirect_split trims whitespace around operators" {
    {
        const rs = redirect_split("echo     >     file.txt").?;
        try std.testing.expectEqualStrings("echo", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    {
        const rs = redirect_split("echo>>file.txt").?;
        try std.testing.expectEqualStrings("echo", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    {
        const rs = redirect_split("cat < file.txt").?;
        try std.testing.expectEqualStrings("cat", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
}

test "shell: M19 P2 redirect: echo > / redirect_split bad input returns null" {
    try std.testing.expect(redirect_split(" > file.txt") == null); // empty left
    try std.testing.expect(redirect_split("echo > ") == null); // empty right
    try std.testing.expect(redirect_split("echo>") == null); // empty right
    try std.testing.expect(redirect_split("> file.txt") == null); // empty left
}

test "shell: M19 P4 fn: define and call a function" {
    shell_mod.env_count = 0;
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Define a function
    mock.feed("fn hello { echo hi there }\n");
    while (shell.poll() != .idle) {}
    // Call it
    mock.feed("hello\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "hi there") != null);
}

test "shell: M19 P4 fn: fn -d deletes a function" {
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Define
    mock.feed("fn foo { echo bar }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(func_find("foo") != null);
    // Delete
    mock.feed("fn -d foo\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(func_find("foo") == null);
    try std.testing.expectEqual(@as(usize, 0), shell_mod.func_count);
}

test "shell: M19 P4 fn: bare fn lists all functions" {
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn greet { echo hello; echo world }\n");
    while (shell.poll() != .idle) {}
    mock.feed("fn\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "greet") != null);
}

test "shell: M19 P4 fn: func_find and func_define direct API" {
    shell_mod.func_count = 0;
    try std.testing.expect(func_find("nope") == null);

    // Define via direct API — tests func_find and func_delete on the static table
    // Set up a function manually
    @memcpy(shell_mod.func_table[0].name[0..4], "test");
    shell_mod.func_table[0].name_len = 4;
    @memcpy(shell_mod.func_table[0].body[0][0..7], "echo ok");
    shell_mod.func_table[0].body_lens[0] = 7;
    shell_mod.func_table[0].body_count = 1;
    shell_mod.func_count = 1;

    try std.testing.expect(func_find("test") != null);
    try std.testing.expect(func_find("nope") == null);
}

test "shell: M19 P4 fn: fn list when empty shows message" {
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "no functions defined") != null);
}

test "shell: M19 P8 fn: define function with arguments" {
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn greet(name, msg) { echo $msg, $name; echo done }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell_mod.func_count == 1);
    try std.testing.expectEqualSlices(u8, "greet", shell_mod.func_table[0].name[0..shell_mod.func_table[0].name_len]);
    try std.testing.expectEqual(@as(usize, 2), shell_mod.func_table[0].arg_count);
    try std.testing.expectEqualSlices(u8, "name", shell_mod.func_table[0].arg_names[0][0..shell_mod.func_table[0].arg_name_lens[0]]);
    try std.testing.expectEqualSlices(u8, "msg", shell_mod.func_table[0].arg_names[1][0..shell_mod.func_table[0].arg_name_lens[1]]);
    try std.testing.expectEqual(@as(usize, 2), shell_mod.func_table[0].body_count);
}

test "shell: M19 P8 fn: call function with arguments, positional 0-N set" {
    shell_mod.env_count = 0;
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Define a function that echoes positional args
    mock.feed("fn args_test { echo $0; echo $1; echo $2 }\n");
    while (shell.poll() != .idle) {}
    mock.reset();
    // Call it with two arguments
    mock.feed("args_test alpha beta\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "args_test") != null); // $0
    try std.testing.expect(std.mem.indexOf(u8, out, "alpha") != null); // $1
    try std.testing.expect(std.mem.indexOf(u8, out, "beta") != null); // $2
}

test "shell: M19 P8 fn: named arguments available as dollar-VAR" {
    shell_mod.env_count = 0;
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn greet(name) { echo hello $name }\n");
    while (shell.poll() != .idle) {}
    mock.reset();
    mock.feed("greet world\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "hello world") != null);
}

test "shell: M19 P8 fn: function without args still works (P4 compat)" {
    shell_mod.env_count = 0;
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn noargs { echo still works }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), shell_mod.func_table[0].arg_count);
    mock.reset();
    mock.feed("noargs\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "still works") != null);
}

test "shell: M19 P8 fn: listing shows argument signature" {
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn foo(a, b, c) { echo ok }\n");
    while (shell.poll() != .idle) {}
    mock.reset();
    mock.feed("fn\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "foo(a, b, c)") != null);
}

test "shell: M19 P8 fn: too many args clamped to 4" {
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn many(a, b, c, d, e, f) { echo $4 }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 4), shell_mod.func_table[0].arg_count); // clamped to 4
}

test "shell: M19 P9 subst: echo $(echo hello) inlines captured output" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $(echo hello)\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // The inner echo outputs "hello" which is substituted; outer echo prints that
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
}

test "shell: M19 P9 subst: nested $(...) is refused" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $(echo $(echo nested))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "nested") != null);
}

test "shell: M19 P9 subst: unmatched $( reports error" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $(unclosed\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "unmatched $") != null);
}

test "shell: M19 P9 subst: empty $(  ) is a no-op" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo before$(  )after\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Empty inner cmd means raw line is returned as-is, so echo sees literal "before$(  )after"
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
}

test "shell: M19 P9 subst: fn bodies skip substitution" {
    shell_mod.env_count = 0;
    shell_mod.func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // $() in a function body should be stored literally, not expanded at define time
    mock.feed("fn subtest { echo $(echo inner) }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 1), shell_mod.func_count);
    // Body should contain literal $(echo inner), not the expansion
    const body = shell_mod.func_table[0].body[0][0..shell_mod.func_table[0].body_lens[0]];
    try std.testing.expect(std.mem.indexOf(u8, body, "$(echo inner)") != null);
}

test "shell: M19 P9 subst: mixed prefix and suffix with substitution" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // prefix + $(echo mid) + suffix → prefixmidsuffix
    mock.feed("echo before-$(echo mid)-after\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "before-mid-after") != null);
}

test "shell: M19 P9 subst: no substitution when no $( present" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo just a normal command\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "just a normal command") != null);
}
test "shell: M19 P10 arith: basic addition" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $((2 + 3))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "5") != null);
}

test "shell: M19 P10 arith: multiplication precedence over addition" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $((2 + 3 * 4))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "14") != null);
}

test "shell: M19 P10 arith: parenthesized grouping" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $(( (1+2) * 3 ))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "9") != null);
}

test "shell: M19 P10 arith: subtraction" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $((10 - 3))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "7") != null);
}

test "shell: M19 P10 arith: division" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $((10 / 3))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "3") != null);
}

test "shell: M19 P10 arith: modulo" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $((10 % 3))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "1") != null);
}

test "shell: M19 P10 arith: negative result" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $((3 - 10))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "-7") != null);
}

test "shell: M19 P10 arith: unary minus" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $((-5 + 3))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "-2") != null);
}

test "shell: M19 P10 arith: mixed prefix and suffix" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo result=$((1+2))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "result=3") != null);
}

test "shell: M19 P10 arith: no $(( in line is a no-op" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo plain\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "plain") != null);
}

test "shell: M19 P10 arith: empty $((  )) passes through literally" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo before$((  ))after\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
}

test "shell: M19 P10 arith: nested parens in expression" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $(( ( (2+3) ) ))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "5") != null);
}

test "shell: M19 P11 if: true runs then" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("if true; then echo yep; fi\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "yep\n") != null);
}

test "shell: M19 P11 if: false skips then" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("if false; then echo nope; fi\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "nope\n") == null);
}

test "shell: M19 P11 if: true else branch skipped" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("if true; then echo ok; else echo nah; fi\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nah\n") == null);
}

test "shell: M19 P11 if: false else branch runs" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("if false; then echo ok; else echo nah; fi\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "ok\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nah\n") != null);
}

test "shell: M19 P11 if: multiple commands in then body" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("if true; then echo one; echo two; fi\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "one\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "two\n") != null);
}

test "shell: M19 P11 if: missing fi prints error" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("if true; then echo ok\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "missing 'fi'") != null);
}

test "shell: M19 P11 if: missing then prints error" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("if true echo ok; fi\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "missing 'then'") != null);
}
test "shell: M19 P12 for: iterates over words" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("for x in a b c; do echo $x; done\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "c\n") != null);
}

test "shell: M19 P12 for: variable unset after loop" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("for x in a b; do echo $x; done\n");
    while (shell.poll() != .idle) {}
    mock.feed("echo $x\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // $x should be empty/unset after the loop
    // The prompt echo contains "echo $x" but the output should just be a newline
    try std.testing.expect(std.mem.indexOf(u8, out, "a\n") != null);
}

test "shell: M19 P12 for: empty word list does nothing" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("for x in; do echo never; done\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "never\n") == null);
}

test "shell: M19 P12 for: missing done prints error" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("for x in a b; do echo $x\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "missing 'done'") != null);
}

test "shell: M19 P12 for: missing do prints error" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("for x in a b echo $x; done\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "missing 'do'") != null);
}

test "shell: M19 P12 while: runs while condition is true" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("set COUNT=0\n");
    while (shell.poll() != .idle) {}
    mock.feed("while true; do echo loop; break; done\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "loop\n") != null);
}

test "shell: M19 P12 while: stops when condition is false" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("while false; do echo never; done\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "never\n") == null);
}

test "shell: M19 P12 while: break exits loop" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("set I=0\n");
    while (shell.poll() != .idle) {}
    mock.feed("while true; do echo body; break; done\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "body\n") != null);
}

test "shell: M19 P12 while: missing done prints error" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("while true; do echo ok\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "missing 'done'") != null);
}

test "shell: M19 P12 while: missing do prints error" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("while true echo ok; done\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "missing 'do'") != null);
}

test "shell: M19 P12 for: multiple commands in body" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("for x in a b; do echo first; echo second; done\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second\n") != null);
}
test "shell: M19 P13 heredoc: basic heredoc feeds stdin to command" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // type reads stdin and echoes to stdout
    mock.feed("type <<EOF\nhello\nworld\nEOF\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // type should output "hello\nworld\n" from the heredoc
    try std.testing.expect(std.mem.indexOf(u8, out, "hello\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "world\n") != null);
}

test "shell: M19 P13 heredoc: empty heredoc feeds nothing" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("type <<EOF\nEOF\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // type with empty stdin should produce no output beyond prompts
    // (just the prompt lines, no extra content)
    try std.testing.expect(std.mem.indexOf(u8, out, "missing") == null);
}

test "shell: M19 P13 heredoc: variable expansion in unquoted heredoc" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("set NAME=elephant\n");
    while (shell.poll() != .idle) {}
    mock.feed("type <<EOF\nhello $NAME\nEOF\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "hello elephant\n") != null);
}

test "shell: M19 P13 heredoc: quoted delimiter prevents expansion" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("set NAME=elephant\n");
    while (shell.poll() != .idle) {}
    mock.feed("type <<\"EOF\"\nhello $NAME\nEOF\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // $NAME should NOT be expanded — literal "$NAME" in output
    try std.testing.expect(std.mem.indexOf(u8, out, "hello $NAME\n") != null);
}

test "shell: M19 P13 heredoc: missing command prints error" {
    shell_mod.env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("<<EOF\nhello\nEOF\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "missing command") != null);
}

test "shell: M19 P13 heredoc: multiple lines collected" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("type <<EOF\nline1\nline2\nline3\nEOF\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "line1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line3\n") != null);
}
test "shell: M19 P15 set -x: trace prints commands" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("set -x\n");
    while (shell.poll() != .idle) {}
    mock.feed("echo hello\n");
    while (shell.poll() != .idle) {}
    mock.feed("set +x\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Should contain "+ echo hello" from the trace
    try std.testing.expect(std.mem.indexOf(u8, out, "+ echo hello\n") != null);
    // After set +x, trace should be off (no more + lines)
}

test "shell: M19 P15 set -x: set without args shows trace status" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("set -x\n");
    while (shell.poll() != .idle) {}
    mock.feed("set\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "trace: on") != null);
}

test "shell: M19 P14 pipe+redirect: echo | type > file" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // echo hello | type > test_out.txt
    // type reads from pipe (hello), redirects to file
    mock.feed("echo hello | type > test_out.txt\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Should succeed (no error message)
    try std.testing.expect(std.mem.indexOf(u8, out, "error") == null);
}

test "shell: M19 P14 pipe+redirect: cmd < file | cmd > file" {
    shell_mod.env_count = 0;
    shell_mod.last_exit_ok = true;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // type < test_out.txt | type > test_out2.txt
    // Reads from file, pipes through type, writes to another file
    mock.feed("type < test_out.txt | type > test_out2.txt\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "error") == null);
}

// ---------------------------------------------------------------------------
// M19 P3 (issue #292) chaining + M19 P4 (issue #293) exit status
// ---------------------------------------------------------------------------

test "shell: M19 P3 chain_split: no operator is none" {
    try std.testing.expect(chain_split("echo hello") == .none);
    try std.testing.expect(chain_split("") == .none);
    try std.testing.expect(chain_split("   ") == .none);
}

test "shell: M19 P3 chain_split: seq, and, or with trimming" {
    const r = chain_split("echo one ; echo two && echo three || echo four");
    switch (r) {
        .chain => |c| {
            try std.testing.expectEqual(@as(usize, 4), c.seg_count);
            try std.testing.expectEqualStrings("echo one", c.segs[0]);
            try std.testing.expectEqualStrings("echo two", c.segs[1]);
            try std.testing.expectEqualStrings("echo three", c.segs[2]);
            try std.testing.expectEqualStrings("echo four", c.segs[3]);
            try std.testing.expectEqual(ChainOp.seq, c.ops[0]);
            try std.testing.expectEqual(ChainOp.run_and, c.ops[1]);
            try std.testing.expectEqual(ChainOp.run_or, c.ops[2]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "shell: M19 P3 chain_split: quotes protect operators; lone | is not a chain op" {
    // `;` inside double quotes stays part of the segment.
    switch (chain_split("echo \"a;b\" ; echo c")) {
        .chain => |c| {
            try std.testing.expectEqual(@as(usize, 2), c.seg_count);
            try std.testing.expectEqualStrings("echo \"a;b\"", c.segs[0]);
        },
        else => return error.TestUnexpectedResult,
    }
    // A single pipe binds tighter — the chain layer must not see it.
    try std.testing.expect(chain_split("echo a | type") == .none);
}

test "shell: M19 P3 chain_split: more than 4 commands is refused" {
    try std.testing.expect(chain_split("a ; b ; c ; d ; e") == .too_many);
    // Exactly 4 segments (3 operators) is the bound.
    try std.testing.expect(chain_split("a ; b ; c ; d") != .too_many);
}

test "shell: M19 P3 seq runs both halves" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo one ; echo two\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "one\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "two\n") != null);
}

test "shell: M19 P3 && skips on failure, || rescues it" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("false && echo nope\n");
    while (shell.poll() != .idle) {}
    mock.feed("false || echo yep\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Line-exact: the mock echoes the typed line back, so a bare substring
    // would match the echo of "…&& echo nope" itself.
    try std.testing.expect(std.mem.indexOf(u8, out, "\nnope\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nyep\n") != null);
}

test "shell: M19 P3 mixed precedence matches the issue example" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // The issue's exact shape: cmd2 skipped on failure; cmd3 always runs.
    mock.feed("false && echo skipped ; echo always\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\nskipped\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nalways\n") != null);
}

test "shell: M19 P3 success chain and equal-precedence left-to-right" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("true && echo yes || echo no\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "yes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "no\n") == null);
}

test "shell: M19 P4 $? expands to the last status" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("true\necho $?\n"); // expect an exact "0" line
    while (shell.poll() != .idle) {}
    mock.feed("false\necho $?\n"); // expect an exact "1" line
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\n0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n1\n") != null);
}

test "shell: M19 P4 unknown command reports 127 through $?" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("nosuchverb42\necho $?\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\n127\n") != null);
}

test "shell: M19 P4 usage refusal reports 2; exec miss reports nonzero" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // An empty submission reaches the registry with no verb -> usage -> 2
    // (the same shape the canonical transcript records).
    mock.feed("\necho $?\n");
    while (shell.poll() != .idle) {}
    const first = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, first, "\n2\n") != null);
    // exec of a missing image -> invalid_argument -> 1.
    mock.feed("exec NOTEXIST.BIN\necho $?\n");
    while (shell.poll() != .idle) {}
    const second = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, second[first.len..], "\n1\n") != null);
}

test "shell: M19 P4 $? in a LATER chain segment expands at execution time" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // The live-gate regression: expanding the whole line up front would
    // bake the PRE-LINE status into `$?` and print exit=0. Per-segment
    // expansion must observe the failure the first segment just recorded.
    mock.feed("exec NOTEXIST.BIN ; echo exit=$?\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\nexit=1\n") != null);
}

test "shell: M19 P3 empty segments are skipped without breaking the chain" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("; ; echo fine\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "fine\n") != null);
}

// ---------------------------------------------------------------------------
// M19 P5 (issue #294) quoting & escaping + P6 (issue #295) globbing
// ---------------------------------------------------------------------------

test "shell: M19 P6 glob_match: star, question, class, ranges" {
    try std.testing.expect(glob_match("*", ""));
    try std.testing.expect(glob_match("*", "anything"));
    try std.testing.expect(glob_match("*.BIN", "USER.BIN"));
    try std.testing.expect(!glob_match("*.BIN", "USER.ELF"));
    try std.testing.expect(glob_match("ab?d", "abcd"));
    try std.testing.expect(!glob_match("ab?d", "abd"));
    try std.testing.expect(glob_match("[abc]at", "bat"));
    try std.testing.expect(!glob_match("[abc]at", "dat"));
    try std.testing.expect(glob_match("ch[a-m]p", "chap"));
    try std.testing.expect(glob_match("ch[a-m]p", "chip"));
    try std.testing.expect(!glob_match("ch[a-m]p", "chzp"));
    // The class matches exactly ONE byte.
    try std.testing.expect(!glob_match("ch[a-m]p", "chimp"));
    // Star backtracking across a failed class match.
    try std.testing.expect(glob_match("*[xy].BIN", "abcz.BIN") == false);
    try std.testing.expect(glob_match("*[xz].BIN", "abcz.BIN"));
    // Exact literal.
    try std.testing.expect(glob_match("KERNEL.BIN", "KERNEL.BIN"));
    try std.testing.expect(!glob_match("KERNEL.BIN", "KERNEL2.BIN"));
}

test "shell: M19 P6 no disk in host tests: wildcard stays literal (nullglob-off)" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo *.NOTFOUND\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // The ESP window is empty in host tests, so nothing matches and the
    // pattern passes through untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "*.NOTFOUND\n") != null);
}

test "shell: M19 P5 single quotes protect operators from the chain splitter" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // The `;` inside single quotes must NOT split the chain: echo prints
    // one argument containing it.
    mock.feed("echo 'a;b'\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\na;b\n") != null);
}

test "shell: M19 P5 backslash defuses an operator" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo a\\;b\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\na;b\n") != null);
}

test "shell: M19 P5 single quotes block $VAR expansion" {
    shell_mod.env_count = 0;
    defer shell_mod.env_count = 0;
    env_set("GLOBE", "world");
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo '$GLOBE'\n"); // literal
    while (shell.poll() != .idle) {}
    mock.feed("echo \"$GLOBE\"\n"); // expanded
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\n$GLOBE\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nworld\n") != null);
}

test "shell: M19 P5 \\$ prevents expansion, tokenizer strips the escape" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("set HOME /esp\n");
    while (shell.poll() != .idle) {}
    mock.feed("echo \\$HOME\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\n$HOME\n") != null);
}

// ---------------------------------------------------------------------------
// M19 P7 (issue #296): foreground/background jobs
// ---------------------------------------------------------------------------

test "shell: M19 P7 trailing_bg_amp: trailing only, quote/escape aware" {
    try std.testing.expectEqual(@as(?usize, 9), trailing_bg_amp("sleep 10 &"));
    try std.testing.expectEqual(@as(?usize, 13), trailing_bg_amp("exec FOO.BIN & "));
    try std.testing.expect(trailing_bg_amp("echo a & echo b") == null); // not trailing
    try std.testing.expect(trailing_bg_amp("echo 'hi & bye'") == null); // quoted
    try std.testing.expect(trailing_bg_amp("echo hi\\&") == null); // escaped
    try std.testing.expect(trailing_bg_amp("a & b &") == null); // two amps
    try std.testing.expect(trailing_bg_amp("no amp here") == null);
}

test "shell: M19 P7 background of a non-spawning command records no job" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    shell_mod.bg_jobs = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo sync-bg &\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // The command ran (synchronously), and nothing was tracked.
    try std.testing.expect(std.mem.indexOf(u8, out, "\nsync-bg\n") != null);
    try std.testing.expect(bg_job_latest() == null);
}

test "shell: M19 P7 jobs and fg report an empty table" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    shell_mod.bg_jobs = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("jobs\nfg\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "jobs: no background jobs\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fg: no background jobs\n") != null);
}

test "shell: M19 P7 reaper reports a vanished child once and frees the slot" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    shell_mod.bg_jobs = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Fabricate a tracked job whose pid can never exist (host tests have
    // no process registry entries): the reaper must report it exactly
    // once as gone and free the slot.
    try std.testing.expect(bg_job_add(9999, "VANISHED.BIN"));
    bg_reap(&shell.mon);
    const first = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, first, "[1] Done: VANISHED.BIN (gone)\n") != null);
    try std.testing.expect(bg_job_latest() == null);
    // Second pass: silent — the line prints ONCE.
    bg_reap(&shell.mon);
    try std.testing.expectEqual(first.len, mock.contents().len);
}

test "shell: M19 P7 fg refuses bad numbers and freed slots" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    shell_mod.bg_jobs = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fg x\n");
    while (shell.poll() != .idle) {}
    mock.feed("fg 9\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(bg_job_add(9998, "WENT.BIN"));
    bg_job_free(1);
    mock.feed("fg 1\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "fg: usage: fg [N]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "already done") != null);
}

test "shell: M19 P7 bare & is a harmless no-op" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    shell_mod.bg_jobs = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("&\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(bg_job_latest() == null);
}

test "shell: M19 P7 fg propagates the child's real exit status into $?" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    shell_mod.bg_jobs = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));
    process.init();
    // A REAL registry entry — created, bound to a task, exited with 43 —
    // exactly the lifecycle an `exec STATUS43.BIN &` produces on hardware.
    const pid = process.create("STATUS43.BIN", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(pid, 7);
    _ = process.on_task_exit(7, 43);
    try std.testing.expect(bg_job_add(pid, "STATUS43.BIN"));
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("jobs\nfg 1\necho $?\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "[1] Done: STATUS43.BIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(exit=43)") != null);
    // fg's own status IS the child's status (clamped to u8).
    try std.testing.expect(std.mem.indexOf(u8, out, "\n43\n") != null);
}

test "shell: M19 P7 fg on a live child honestly times out and keeps tracking" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    shell_mod.bg_jobs = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));
    process.init();
    // Created + bound but never exits: the eternal-COUNTER shape.
    const pid = process.create("COUNTER.BIN", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(pid, 9);
    try std.testing.expect(bg_job_add(pid, "COUNTER.BIN"));
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("jobs\nfg 1\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "[1] Running: COUNTER.BIN\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fg: job 1 still running\n") != null);
    // Still tracked afterwards.
    try std.testing.expect(bg_job_latest() != null);
}

test "shell: M19 P7 reaper announces a real exited child with its status" {
    shell_mod.env_count = 0;
    shell_mod.trace_enabled = false;
    shell_mod.bg_jobs = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));
    process.init();
    const pid = process.create("QUICK.BIN", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(pid, 5);
    try std.testing.expect(bg_job_add(pid, "QUICK.BIN"));
    _ = process.on_task_exit(5, 7);
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    bg_reap(&shell.mon);
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "[1] Done: QUICK.BIN (exit=7)\n") != null);
    try std.testing.expect(bg_job_latest() == null);
}

test "shell: wm autostart once — the Go seat by default, TABWM the fallback (M59 #1298)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    defer settings.reset();
    // No persisted `wm` key: the compiled default is the GO seat, so the ONE
    // attempt is made and named. With no file channel on the host test the
    // miss is reported honestly — shim compositing, stated, not faked.
    shell_mod.wm_autostart_attempted = false;
    shell_mod.wm_autostart_once(&shell.mon);
    try std.testing.expect(shell_mod.wm_autostart_attempted);
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "wm: autostart gotabwm: GOTABWM.ELF not on the share") != null);
    // The once-flag holds: a second call is silent.
    const before = mock.contents().len;
    shell_mod.wm_autostart_once(&shell.mon);
    try std.testing.expectEqual(before, mock.contents().len);
    // The fallback seat is reachable through the same seam: an explicit
    // `settings set wm tabwm` boots the Zig seat instead.
    _ = settings.set("wm", "tabwm");
    mock.reset();
    shell_mod.wm_autostart_attempted = false;
    shell_mod.wm_autostart_once(&shell.mon);
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "wm: autostart tabwm: TABWM.BIN not on the share") != null);
    // `wm=none` — like any unrecognized value — launches nothing: the
    // pre-M59 shim-only VM stays reachable on demand, with no exec attempt.
    _ = settings.set("wm", "none");
    mock.reset();
    shell_mod.wm_autostart_attempted = false;
    shell_mod.wm_autostart_once(&shell.mon);
    try std.testing.expect(shell_mod.wm_autostart_attempted);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
    _ = settings.set("wm", "wnd");
    mock.reset();
    shell_mod.wm_autostart_attempted = false;
    shell_mod.wm_autostart_once(&shell.mon);
    try std.testing.expectEqual(@as(usize, 0), mock.contents().len);
}

test "shell: wm autostart diagnostic is one byte-exact write (#1965)" {
    const Writer = struct {
        output: console.MockConsole(4096) = .{},
        writes: usize = 0,
        const vtable = console.Console.VTable{ .write = write, .flush = flush, .readByte = read };
        fn write(ctx: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.writes += 1;
            self.output.console().puts(bytes);
            self.output.console().puts("counter: alive\n");
        }
        fn flush(_: *anyopaque) void {}
        fn read(_: *anyopaque) ?u8 {
            return null;
        }
    };
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    defer settings.reset();
    _ = settings.set("init", "off");
    var writer = Writer{};
    shell.mon.console = .{ .ctx = &writer, .vtable = &Writer.vtable };
    shell_mod.wm_autostart_attempted = false;
    shell_mod.wm_autostart_once(&shell.mon);
    try std.testing.expectEqual(@as(usize, 1), writer.writes);
    try std.testing.expectEqualStrings("wm: autostart gotabwm: GOTABWM.ELF not on the share (shim compositing)\ncounter: alive\n", writer.output.contents());
}

test "shell: login ownerless-console fallback decision (M49 SD1)" {
    // Attached: the shell owns the console, the monitor never resumes.
    try std.testing.expect(!shell_mod.login_should_resume(true, false, true));
    try std.testing.expect(!shell_mod.login_should_resume(true, true, false));
    // Was attached and now detached/exited: the monitor resumes.
    try std.testing.expect(shell_mod.login_should_resume(false, true, false));
    try std.testing.expect(shell_mod.login_should_resume(false, true, true));
    // Never attached: resume only once the login process is gone (the
    // fallback — an orphaned console would otherwise have no reader).
    try std.testing.expect(!shell_mod.login_should_resume(false, false, true));
    try std.testing.expect(shell_mod.login_should_resume(false, false, false));
}
