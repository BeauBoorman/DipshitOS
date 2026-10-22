//! Interactive `virelai>` shell loop (Milestone 1.5, console & shell core).
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
//! No libc, no POSIX, no allocation, no global mutable state.

const std = @import("std");
const builtin = @import("builtin");
pub const alloc = @import("alloc.zig");
pub const console = @import("console.zig");
pub const lineedit = @import("lineedit.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const pipe = @import("pipe.zig"); // M19 P1 (issue #290): the bounded pipe behind the `|` operator
pub const redirect = @import("redirect.zig"); // M19 P2 (issue #291): capture/feed adapters behind `>`, `>>`, `<`
pub const monitor = @import("monitor.zig");
pub const exec_mod = @import("exec.zig"); // M19 P7 (issue #296): last_exec_pid for job tracking
pub const terminal = @import("terminal.zig"); // #1072 (ADR 0020): console handover guard
pub const process = @import("process.zig"); // M19 P7 (issue #296): live job state + real exit statuses
pub const handoff = @import("handoff.zig");
pub const memmap = @import("memmap.zig");
pub const scheduler = @import("scheduler.zig"); // claim 5275: worker progress printing (main context only)
pub const settings = @import("settings.zig"); // milestone eight card U8 (claim 2649): persistent settings
pub const timer = @import("timer.zig"); // claim 7948: heartbeat printing (main context only)
pub const userspace = @import("userspace.zig"); // claim 8215: deferred EL0/SVC evidence line
const virtio_net = @import("virtio_net.zig"); // claim 6076 (card N2): polled RX drain in the idle loop
const road_pops = @import("road_pops.zig"); // claim 1574 (milestone six G3): Road Pops framebuffer drain in the idle loop
pub const input = @import("input.zig"); // claim 6050 (milestone seven I3): keyboard/pointer event FIFO drain in the idle loop
const driving_award = @import("driving_award.zig"); // claim 1543 (milestone six G5): Driving Award window-manager drain (clock refresh + composite)
const wm_server = @import("wm_server.zig"); // M32 WMS2 (issue #622): when a WM registers, pacing moves off this idle drain to the tick path
const mailbox = @import("mailbox.zig");
const scrollback_mod = @import("scrollback.zig"); // M18 T1 (issue #404): terminal scrollback ring
pub const clipboard = @import("clipboard.zig"); // M18 T2 (issue #405): shared clipboard for copy/paste
// M34 HF5 (issue #739): shell history + env persist to the HOST SHARE
// when the file channel is armed (ESP fallback otherwise — dual path
// until HF6).
pub const virtio_file = @import("virtio_file.zig");
const svclock = @import("svclock.zig"); // claim 9498 follow-on: the idle loop's service-state brackets (NET/WIN+EV/FILE)
const trust = @import("trust.zig"); // M50 TS2 (#1136, ADR 0024 D4): the kernel-actor gate for history/env
pub const forensics = @import("forensics.zig"); // #1261: console-free liveness sample from the idle loop

/// M18 T4: path for persistent shell history file.
const history_path = "HISTORY.TXT";
/// M19 P3: path for persistent environment variables.
const env_path = "ENV.TXT";
/// M18 T4: max lines stored in the history file.
const history_file_max: usize = 50;
/// M18 T12: max shell environment variables.
pub const env_max: usize = 16;
const env_name_max: usize = 32;
const env_val_max: usize = 64;
/// M19 P4: max shell functions.
const func_max: usize = 8;
const func_name_max: usize = 32;
const func_cmds_per_func: usize = 4;
const func_cmd_max: usize = 64;
const func_arg_max: usize = 4;
const func_arg_name_max: usize = 16;
/// M19 P9 (issue #298): command substitution — max captured output.
const subst_max_output: usize = 256;
/// M18 T16 (issue #419): script bounds — at most 64 executable lines,
/// at most 256 chars per line, staged into 64 × 256 = 16384 bytes.
const script_max_lines: usize = 64;
const script_line_max: usize = 256;
const script_staging_max: usize = script_max_lines * script_line_max;

/// M18 T16: true while a script is executing — the nesting guard that
/// refuses `sh` inside a script (`sh: scripts cannot call scripts`).
/// Module scope, like env_table: the execution path (handle_line) is
/// module-level, so a flag on the Shell struct would be unreachable
/// there. Never set while another script runs (nesting is refused), so
/// no reentrancy is possible.
var script_active: bool = false;
/// M18 T16: a running script asked to stop early via `exit`.
var script_stop: bool = false;
/// M18 T16: BSS staging for the script file. Deliberately NOT stack: the
/// kernel stack is 16 KiB (ADR 0004 D5) and the LineEditor ring already
/// crowds it (claim 1809's lesson).
var script_staging: [script_staging_max]u8 = undefined;

/// M19 P11 (issue #300): exit status of the last command — `true` sets
/// it to true, `false` to false, `monitor.exec` sets it based on
/// success/error. Module scope so `handle_line` can read it.
pub var last_exit_ok: bool = true;

/// M19 P4 (issue #293): numeric exit status of the last command, 0–255.
/// Kept in sync with `last_exit_ok` through the helpers below — never
/// write either global directly from execution paths.
var last_exit: u8 = 0;

/// M19 P4 (issue #293): record a boolean outcome — 0 on success, 1 on
/// failure — and keep the P11 bool and the P4 number in lockstep.
fn set_exit_ok(ok: bool) void {
    last_exit_ok = ok;
    last_exit = if (ok) 0 else 1;
}

/// M19 P4 (issue #293): record a specific exit code (0 means success).
fn set_exit_code(code: u8) void {
    last_exit = code;
    last_exit_ok = (code == 0);
}

/// M19 P4 (issue #293): map a monitor dispatch result to a conventional
/// shell-style status. Dispatch-level only: external programs are spawned
/// fire-and-forget (the interactive shell does not block on them), so this
/// reflects whether the command was found, well-formed, and spawnable —
/// not the child's own exit status (that lands in the process registry).
fn exec_error_code(e: monitor.ExecError) u8 {
    return switch (e) {
        .none => 0,
        .unknown_command => 127,
        .usage => 2,
        .invalid_argument => 1,
        .not_implemented => 1,
        .machine_failed => 1,
    };
}

/// M19 P15 (issue #304): shell trace mode — when enabled, each command
/// is printed to the console (prefixed with `+ `) before execution.
pub var trace_enabled: bool = false;

/// M19 P5 (issue #294): BSS backing for tokenizer materialization —
/// joined/escaped tokens are not contiguous slices of the input line.
/// Module scope, not the 16 KiB kernel stack (claim 1809's lesson); safe
/// under the single-active-dispatch invariant every other shell staging
/// buffer relies on (scripts, heredocs, substitutions never nest).
var tokenize_scratch: [lineedit.max_line]u8 = undefined;

/// M19 P6 (issue #295): bounded glob expansion — at most 64 matches per
/// line TOTAL, so `ls *.BIN *.ELF` cannot blow past the argv rebuild.
const glob_max_matches: usize = 64;

/// M19 P6: BSS storage for the expanded argv rebuild (original slots plus
/// the match bound; see glob_expand_argv for why this size always fits).
var glob_argv_storage: [tokenizer.max_tokens + glob_max_matches][]const u8 = undefined;
/// M19 P6: scratch for one wildcard argument's sorted matches.
var glob_match_storage: [glob_max_matches][]const u8 = undefined;
/// M19 P6 / #965: BSS storage for matching glob entry names so argv slices
/// remain valid across dispatch (single-active-dispatch invariant).
var glob_name_storage: [glob_max_matches][32]u8 = undefined;
var glob_list_res: virtio_file.ListResult = .{};

// ---------------------------------------------------------------------------
// M19 P7 (issue #296): foreground/background jobs.
//
// Honest scope: only program launches spawn processes (the registry `exec`
// path) — builtins are synchronous EL1 calls with nothing to background.
// A trailing `&` marks the launch; the job table tracks the child pid and
// the reaper reports its REAL registry exit status exactly once.
// ---------------------------------------------------------------------------

/// Bounded table per the issue: at most 4 background jobs.
pub const bg_job_max: usize = 4;
const bg_name_max: usize = 32;

pub const BgJob = struct {
    /// null = free slot. Registry pids start at 0, so a plain integer
    /// sentinel would collide with the first real process.
    pid: ?usize = null,
    name: [bg_name_max]u8 = @as([bg_name_max]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    /// The `[N] Done:` line has been printed — the slot stays occupied
    /// until then so `jobs`/`fg` never observe a half-registered entry.
    done_reported: bool = false,
};

pub var bg_jobs: [bg_job_max]BgJob = @as([bg_job_max]BgJob, @splat(@as(BgJob, .{})));

/// Set by expand_and_dispatch when the line carried a trailing unquoted
/// `&`; consumed by the registry-dispatch fall-through (or dropped when
/// the command could not spawn anything).
var bg_pending: bool = false;

/// Register a freshly spawned child as background job N (slot number is
/// the job number). Returns false when the table is full — the caller has
/// already refused honestly and the child runs untracked.
pub fn bg_job_add(pid: usize, name: []const u8) bool {
    for (&bg_jobs) |*job| {
        if (job.pid != null) continue;
        job.pid = pid;
        const n = @min(name.len, bg_name_max);
        @memcpy(job.name[0..n], name[0..n]);
        job.name_len = n;
        job.done_reported = false;
        return true;
    }
    return false;
}

/// Free slot `n` (1-based job number).
pub fn bg_job_free(n: usize) void {
    if (n == 0 or n > bg_job_max) return;
    bg_jobs[n - 1] = .{};
}

/// The reaper: print `[N] Done: NAME (exit=CODE)` once per finished job.
/// Called from the shell idle path. A vanished descriptor (registry
/// recycled under us) reports `(gone)` — honest about what was observed.
/// M42 SX5 (issue #986): the default-manager seam state — the shell idle
/// attempts the settings-driven WM boot at most ONCE per session.
pub var wm_autostart_attempted: bool = false;
pub var init_boot_pid: ?usize = null;
var init_boot_owned = false;
var init_boot_deadline: u64 = 0;
var init_boot_seat: settings.WmSeat = .none;
var init_boot_preexisting: [process.max_processes]bool = @as([process.max_processes]bool, @splat(@as(bool, false)));

pub const InitBootAction = enum { wait, seated, stop_seat, fallback };

/// Registration, not exec success, commits the handoff. Even after init dies,
/// a pending seat must relinquish its tasks before another seat may start.
pub fn init_boot_action(init_alive: bool, registered: bool, pending_seat: bool) InitBootAction {
    if (registered) return .seated;
    if (init_alive) return .wait;
    if (pending_seat) return .stop_seat;
    return .fallback;
}

fn init_boot_poll(m: *monitor.Monitor) void {
    const pid = init_boot_pid orelse return;
    if (init_boot_owned) return;
    const domains = svclock.dom_bit(.win) | svclock.dom_bit(.ev) | svclock.dom_bit(.kernel);
    svclock.acquire_set(domains);
    const owner = process.info(pid);
    const alive = if (owner) |info|
        std.mem.eql(u8, info.name, "INIT.ELF") and (info.state == .running or info.state == .created)
    else
        false;
    const registered = wm_server.registered();
    var pending_tasks: [3]?usize = .{ null, null, null };
    var pending_count: usize = 0;
    if (!registered) {
        const program = init_boot_seat.program();
        for (0..process.max_processes) |candidate| {
            if (init_boot_preexisting[candidate]) continue;
            const info = process.info(candidate) orelse continue;
            if (info.state != .running) continue;
            var owned_name = std.mem.eql(u8, info.name, "INITPRE.BIN") or
                std.mem.eql(u8, info.name, "INITDEP.BIN");
            if (program) |name| {
                owned_name = owned_name or std.mem.eql(u8, info.name, name);
            }
            if (owned_name and pending_count < pending_tasks.len) {
                pending_tasks[pending_count] = info.task_id;
                pending_count += 1;
            }
        }
    }
    const action = init_boot_action(alive, registered, pending_count != 0);
    if (action == .seated) {
        // The existing mailbox is boot-local and reset on pid creation.
        // The guest owns its own ring; no new syscall or persisted marker.
        if (mailbox.send(pid, "M92E:seated") == .ok) init_boot_owned = true;
    }
    const owner_task = if (alive) owner.?.task_id else null;
    svclock.release_set(domains);
    switch (action) {
        .seated => {},
        .wait => {
            if (init_boot_deadline != 0 and timer.ticks >= init_boot_deadline) {
                init_boot_deadline = 0;
                m.console.puts("init: refuse init-timeout\n");
                if (owner_task) |task| _ = scheduler.request_kill(task);
            }
        },
        .stop_seat => {
            for (pending_tasks) |pending| {
                if (pending) |task| _ = scheduler.request_kill(task);
            }
        },
        .fallback => {
            init_boot_pid = null;
            m.console.puts("init: fallback direct (init exited)\n");
            wm_autostart_direct(m);
        },
    }
}

/// The persisted-default WM boot. M59 (issue #1298) flipped what "no
/// explicit choice" means: `settings wm` now defaults to `gotabwm`, so a
/// boot with no `wm` key — a fresh share, or a pre-v2 settings file — lands
/// in the GO seat (`GOTABWM.ELF`, the M57a-c second seat) from the shell
/// idle, at most once per session and only while no WM server is
/// registered yet. `settings set wm tabwm` keeps the Zig `TABWM.BIN` seat
/// reachable as the fallback; `settings set wm none` (or an unrecognized
/// value) launches nothing and leaves the pre-M59 shim-compositing VM.
///
/// The seat program lives on the HOST SHARE, so a boot whose share carries
/// no seat binary gets an honest one-line miss and stays shim-only — never
/// a silent pretend-desktop. That is the load-bearing gate invariant
/// (M42 SX5): the fleet that never staged a Go seat is unchanged but is
/// now TOLD why it is shim-only.
pub fn wm_autostart_once(m: *monitor.Monitor) void {
    if (wm_autostart_attempted) {
        init_boot_poll(m);
        return;
    }
    wm_autostart_attempted = true;
    if (wm_server.registered()) return;
    settings.ensure_init();
    // wm=none remains the explicit shim-only boot, including serial-shell
    // gates. It never allocates init merely to discover there is no seat.
    const program = settings.wm_seat_kind().program() orelse return;
    if (settings.init_enabled()) {
        init_boot_seat = settings.wm_seat_kind();
        svclock.kernel.acquire();
        for (0..process.max_processes) |candidate| {
            const info = process.info(candidate);
            init_boot_preexisting[candidate] = if (info) |p| p.state == .running or p.state == .created else false;
        }
        svclock.kernel.release();
        var init_env: [1][]const u8 = undefined;
        init_env[0] = "GOMAXPROCS=1";
        exec_mod.set_envp(&init_env);
        var init_args: [2][]const u8 = undefined;
        init_args[0] = program;
        init_args[1] = settings.login_shell();
        switch (exec_mod.exec_file("INIT.ELF", &init_args)) {
            .ok => {
                init_boot_pid = exec_mod.last_exec_pid();
                init_boot_owned = false;
                init_boot_deadline = timer.ticks + 90;
                m.console.puts("init: autostart INIT.ELF (settings init=on)\n");
                return;
            },
            .no_disk, .not_found => m.console.puts("init: refuse missing-init\n"),
            else => m.console.puts("init: refuse init-load\n"),
        }
    }
    wm_autostart_direct(m);
}

/// Keep the direct path's markers byte-for-byte for init=off and fallback.
fn wm_autostart_direct(m: *monitor.Monitor) void {
    const seat = settings.wm_seat_kind();
    const program = seat.program() orelse return;
    var buf: [192]u8 = undefined;
    switch (exec_mod.exec_file(program, &.{})) {
        .ok => {
            m.console.puts(std.fmt.bufPrint(&buf, "wm: autostart {s} (settings wm={s})\n", .{ seat.name(), settings.wm_seat() }) catch return);
        },
        // No share, or the seat's program is not on it: shim compositing is
        // the outcome and it is reported as such.
        .no_disk, .not_found => {
            m.console.puts(std.fmt.bufPrint(&buf, "wm: autostart {s}: {s} not on the share (shim compositing)\n", .{ seat.name(), program }) catch return);
        },
        else => {
            m.console.puts(std.fmt.bufPrint(&buf, "wm: autostart {s} failed: {s} did not load (see `exec` for the diagnosis)\n", .{ seat.name(), program }) catch return);
        },
    }
}

pub fn bg_reap(mon: *monitor.Monitor) void {
    for (&bg_jobs, 0..) |*job, i| {
        const jpid = job.pid orelse continue;
        if (job.done_reported) continue;
        const info = process.info(jpid);
        const state = if (info) |inf| inf.state else .free;
        if (state != .exited and state != .free) continue; // still running
        // #2649: ONE write per marker line — the live jobs gate
        // whole-line greps `[N] Done: NAME (exit=C)`, so a composition
        // interrupted by a concurrent process write loses the match.
        if (info) |inf| {
            if (state == .exited) {
                mon.console.linef("[{d}] Done: {s} (exit={d})\n", .{ i + 1, inf.name, inf.exit_status });
            } else {
                mon.console.linef("[{d}] Done: {s} (gone)\n", .{ i + 1, inf.name });
            }
        } else {
            mon.console.linef("[{d}] Done: {s} (gone)\n", .{ i + 1, job.name[0..job.name_len] });
        }
        bg_job_free(i + 1);
    }
}

/// Find the most recently added occupied slot (highest job number), for
/// bare `fg`.
pub fn bg_job_latest() ?usize {
    var i = bg_job_max;
    while (i > 0) : (i -= 1) {
        if (bg_jobs[i - 1].pid != null) return i;
    }
    return null;
}

/// M19 P7 (issue #296): the index of a TRAILING unquoted/unescaped `&`
/// (only whitespace follows it), or null. More than one unquoted `&`, or
/// one that is not trailing, leaves the line untouched — the tokenizer
/// refuses it exactly as before this card. Scanner states match the
/// chain/pipe/redirect scanners (single quote, double quote, backslash).
pub fn trailing_bg_amp(line: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var esc = false;
    var amp_count: usize = 0;
    var trailing: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (c == '\\') {
            esc = true;
            continue;
        }
        if (in_single) {
            if (c == '\'') in_single = false;
            continue;
        }
        if (c == '\'') {
            in_single = true;
            continue;
        }
        if (in_double) {
            if (c == '"') in_double = false;
            continue;
        }
        if (c == '"') {
            in_double = true;
            continue;
        }
        if (c != '&') continue;
        amp_count += 1;
        // Trailing candidate: every byte after must be space/tab.
        var rest = i + 1;
        while (rest < line.len and (line[rest] == ' ' or line[rest] == '\t')) rest += 1;
        if (rest == line.len) trailing = i;
    }
    if (amp_count == 1) return trailing;
    return null;
}

/// M19 P12 (issue #301): loop state — bounded iteration counter and
/// break/continue flags. Module scope so `shell_handle_expanded` builtins
/// can set them and `run_for`/`run_while` can read them.
var loop_iter: usize = 0;
var break_flag: bool = false;
var continue_flag: bool = false;
const loop_max_iter: usize = 256;

/// M19 P13 (issue #302): here-document state. After detecting `<<DELIM`
/// in a command line, the shell collects subsequent lines until it finds
/// the delimiter. The collected content is fed as stdin to the command.
var heredoc_active: bool = false;
var heredoc_delim: [32]u8 = undefined;
var heredoc_delim_len: usize = 0;
var heredoc_buf: [4096]u8 = undefined;
var heredoc_len: usize = 0;
var heredoc_line_count: usize = 0;
var heredoc_expand: bool = true;
var heredoc_cmd: [lineedit.max_line]u8 = undefined;
var heredoc_cmd_len: usize = 0;
const heredoc_max_lines: usize = 64;

const EnvEntry = struct {
    name: [env_name_max]u8 = @as([env_name_max]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    val: [env_val_max]u8 = @as([env_val_max]u8, @splat(@as(u8, 0))),
    val_len: usize = 0,
    exported: bool = false, // T12: export flag for child processes
};
pub var env_table: [env_max]EnvEntry = undefined;
pub var env_count: usize = 0;

/// Issue #1226: format the kernel env table as KEY=VALUE slices for the
/// gap-path exec envp block. Lives in BSS so the slices outlive this
/// call; `exec.set_envp` copies them again into its own storage.
var exec_envp_buf: [exec_mod.max_exec_envs][exec_mod.env_slot_bytes]u8 = undefined;
var exec_envp_ptr: [exec_mod.max_exec_envs][]const u8 = undefined;

fn arm_exec_envp() void {
    var n: usize = 0;
    var i: usize = 0;
    while (i < env_count and n < exec_mod.max_exec_envs) : (i += 1) {
        const e = &env_table[i];
        const slot = &exec_envp_buf[n];
        @memset(slot, 0);
        const nl = e.name_len;
        const vl = e.val_len;
        if (nl == 0 or nl + 1 >= exec_mod.env_slot_bytes) continue;
        @memcpy(slot[0..nl], e.name[0..nl]);
        slot[nl] = '=';
        const take = @min(vl, exec_mod.env_slot_bytes - 1 - nl - 1);
        if (take > 0) @memcpy(slot[nl + 1 ..][0..take], e.val[0..take]);
        exec_envp_ptr[n] = slot[0 .. nl + 1 + take];
        n += 1;
    }
    exec_mod.set_envp(exec_envp_ptr[0..n]);
}

/// M19 P4: shell function storage (8 functions × 4 commands × 64 chars).
const FuncEntry = struct {
    name: [func_name_max]u8 = @as([func_name_max]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    arg_names: [func_arg_max][func_arg_name_max]u8 = @as([func_arg_max][func_arg_name_max]u8, @splat(@as([func_arg_name_max]u8, @as([func_arg_name_max]u8, @splat(@as(u8, 0)))))),
    arg_name_lens: [func_arg_max]usize = @as([func_arg_max]usize, @splat(@as(usize, 0))),
    arg_count: usize = 0,
    body: [func_cmds_per_func][func_cmd_max]u8 = @as([func_cmds_per_func][func_cmd_max]u8, @splat(@as([func_cmd_max]u8, @as([func_cmd_max]u8, @splat(@as(u8, 0)))))),
    body_lens: [func_cmds_per_func]usize = @as([func_cmds_per_func]usize, @splat(@as(usize, 0))),
    body_count: usize = 0,
};
pub var func_table: [func_max]FuncEntry = undefined;
pub var func_count: usize = 0;

/// Look up an environment variable.
pub fn env_get(name: []const u8) ?[]const u8 {
    for (env_table[0..env_count]) |*e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            return e.val[0..e.val_len];
        }
    }
    return null;
}

/// Set (or create) an environment variable.
pub fn env_set(name: []const u8, val: []const u8) void {
    if (name.len == 0 or name.len > env_name_max) return;
    const vlen = @min(val.len, env_val_max);
    for (env_table[0..env_count]) |*e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            @memcpy(e.val[0..vlen], val[0..vlen]);
            e.val_len = vlen;
            return;
        }
    }
    if (env_count >= env_max) return;
    const e = &env_table[env_count];
    @memcpy(e.name[0..name.len], name);
    e.name_len = name.len;
    @memcpy(e.val[0..vlen], val[0..vlen]);
    e.val_len = vlen;
    env_count += 1;
}

/// Remove an environment variable (M19 P3). Returns true if it existed.
pub fn env_unset(name: []const u8) bool {
    var i: usize = 0;
    while (i < env_count) : (i += 1) {
        if (std.mem.eql(u8, env_table[i].name[0..env_table[i].name_len], name)) {
            // Shift remaining entries down.
            var j = i;
            while (j + 1 < env_count) : (j += 1) {
                env_table[j] = env_table[j + 1];
            }
            env_count -= 1;
            return true;
        }
    }
    return false;
}

/// Safe file-channel lock helpers for in-kernel shell tasks (issue #846):
/// bracket EL1 file access with svclock so shell reads/writes serialize
/// cleanly with EL0 file syscalls on secondary cores.
fn acquire_file_lock() u5 {
    return svclock.acquire_missing(svclock.dom_bit(.file));
}

fn release_file_lock(taken: u5) void {
    svclock.release_set(taken);
}

/// M19 P3: persist the full env table (one NAME=VAL per line) to the HOST
/// SHARE. M34 HF6 (issue #740): the ESP fallback is gone — the share is
/// the only file store; without a channel the read is an honest 0.
fn env_read_existing(buf: []u8) usize {
    if (trust.check(trust.kernel_actor(), .host, env_path, .read) != .allow) return 0;
    const taken = acquire_file_lock();
    defer release_file_lock(taken);
    return virtio_file.read_whole(env_path, buf) orelse 0;
}

/// HF5/HF6: write the whole env file to the share.
fn env_write_all(bytes: []const u8) void {
    if (trust.check(trust.kernel_actor(), .host, env_path, .write) != .allow) return;
    const taken = acquire_file_lock();
    defer release_file_lock(taken);
    _ = virtio_file.write_whole(env_path, bytes);
}

pub fn save_env() void {
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < env_count and pos < buf.len - 2) : (i += 1) {
        const e = &env_table[i];
        const name = e.name[0..e.name_len];
        const val = e.val[0..e.val_len];
        const space_needed = name.len + 1 + val.len + 1; // name=val\n
        if (pos + space_needed > buf.len) break;
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
        buf[pos] = '=';
        pos += 1;
        @memcpy(buf[pos..][0..val.len], val);
        pos += val.len;
        buf[pos] = '\n';
        pos += 1;
    }
    env_write_all(buf[0..pos]);
}

/// M19 P3: restore the env table on boot (share first when armed, ESP
/// fallback).
pub fn load_env() void {
    var content_buf: [2048]u8 = undefined;
    const content = content_buf[0..env_read_existing(&content_buf)];
    if (content.len == 0) return;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len and env_count < env_max) : (i += 1) {
        if (content[i] == '\n' or content[i] == '\r') {
            if (i > start) {
                const line = content[start..i];
                if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                    env_set(line[0..eq], line[eq + 1 ..]);
                }
            }
            start = i + 1;
            if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') i += 1;
        }
    }
    if (start < content.len) {
        const line = content[start..];
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            env_set(line[0..eq], line[eq + 1 ..]);
        }
    }
}

/// Expand $VAR references in a command line. Returns a stack-local buffer.
/// M19 P5 (issue #294): single quotes protect everything — inside `'...'`
/// no `$` ever expands (the quote bytes themselves are copied through; the
/// tokenizer still sees them). A backslash pair outside single quotes is
/// copied verbatim so `\$VAR` survives to the tokenizer, which strips the
/// backslash — the escape prevents expansion without env_expand needing to
/// interpret escapes.
pub fn env_expand(line: []const u8, out: []u8) []u8 {
    var opos: usize = 0;
    var i: usize = 0;
    var in_single = false;
    while (i < line.len and opos < out.len) : (i += 1) {
        if (line[i] == '\'') {
            in_single = !in_single;
            out[opos] = '\'';
            opos += 1;
            continue;
        }
        if (!in_single and line[i] == '\\' and i + 1 < line.len) {
            // Escape pair passes through untouched (tokenizer consumes it).
            out[opos] = '\\';
            opos += 1;
            if (opos < out.len) {
                out[opos] = line[i + 1];
                opos += 1;
            }
            i += 1; // loop's +1 covers the escaped byte
            continue;
        }
        if (!in_single and line[i] == '$' and i + 1 < line.len and line[i + 1] == '?') {
            // M19 P4 (issue #293): `$?` — the read-only numeric exit
            // status of the last command, substituted here (NOT stored
            // in the env table). Structured bodies (fn/for/while) skip
            // pre-expansion by design, so their `$?` expands at body
            // execution time when handle_line re-enters.
            var num: [3]u8 = undefined; // u8 prints in ≤3 digits
            var nlen: usize = 0;
            var v = last_exit;
            if (v == 0) {
                num[0] = '0';
                nlen = 1;
            } else {
                while (v > 0) {
                    num[nlen] = '0' + v % 10;
                    nlen += 1;
                    v /= 10;
                }
            }
            var d = nlen;
            while (d > 0 and opos < out.len) : (d -= 1) {
                out[opos] = num[d - 1];
                opos += 1;
            }
            i += 1; // consume the '?' too (loop's +1 covers '$')
            continue;
        }
        if (!in_single and line[i] == '$' and i + 1 < line.len) {
            // Collect variable name
            var ns: usize = i + 1;
            while (ns < line.len and
                ((line[ns] >= 'a' and line[ns] <= 'z') or
                    (line[ns] >= 'A' and line[ns] <= 'Z') or
                    (line[ns] >= '0' and line[ns] <= '9') or
                    line[ns] == '_'))
            {
                ns += 1;
            }
            const vname = line[i + 1 .. ns];
            if (vname.len > 0) {
                if (env_get(vname)) |val| {
                    for (val) |b| {
                        if (opos < out.len) {
                            out[opos] = b;
                            opos += 1;
                        }
                    }
                }
                i = ns - 1;
                continue;
            }
        }
        if (opos < out.len) {
            out[opos] = line[i];
            opos += 1;
        }
    }
    return out[0..opos];
}

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

/// M18 T15: expand $VAR references in the prompt string.
/// Uses a static buffer so the returned slice remains valid across calls.
var prompt_expansion_buf: [128]u8 = undefined;
fn expanded_prompt() []const u8 {
    const raw = settings.get_prompt();
    return env_expand(raw, &prompt_expansion_buf);
}

/// Context for the scrollback Console wrapper. Lives in Shell BSS so the
/// Console's opaque ctx pointer stays valid for the shell's lifetime.
const ScrollbackCtx = struct {
    inner: console.Console,
    sb: *scrollback_mod.Scrollback,
};

fn sbWrite(ctx: *anyopaque, bytes: []const u8) void {
    const sc: *ScrollbackCtx = @ptrCast(@alignCast(ctx));
    sc.sb.append(bytes);
    sc.inner.write(bytes);
}
fn sbFlush(ctx: *anyopaque) void {
    const sc: *ScrollbackCtx = @ptrCast(@alignCast(ctx));
    sc.inner.flush();
}
fn sbReadByte(ctx: *anyopaque) ?u8 {
    const sc: *ScrollbackCtx = @ptrCast(@alignCast(ctx));
    return sc.inner.readByte();
}
fn sbPushByte(ctx: *anyopaque, b: u8) bool {
    const sc: *ScrollbackCtx = @ptrCast(@alignCast(ctx));
    return sc.inner.pushByte(b);
}

/// M18 T1: the scrollback wrapper's vtable is built at runtime into BSS,
/// NOT a const table — a const table holds link-time absolute function
/// addresses, wrong at the kernel's runtime-chosen load base (claim 0015
/// root cause, ADR 0005; the same reason MachineControl's vtable and the
/// monitor registry are built at runtime). A const vtable here faulted on
/// the first banner write through the wrapped console and silently hung
/// every M18 boot at the aslr seam (observed 2026-08-22, claim 0469).
var scrollback_vtable: console.Console.VTable = undefined;
var scrollback_vtable_ready = false;
fn ensure_scrollback_vtable() *const console.Console.VTable {
    if (!scrollback_vtable_ready) {
        scrollback_vtable = .{
            .write = sbWrite,
            .flush = sbFlush,
            .readByte = sbReadByte,
            .pushByte = sbPushByte,
        };
        scrollback_vtable_ready = true;
    }
    return &scrollback_vtable;
}

// ---------------------------------------------------------------------------
// Shell tab completion (Self-hosting #20, issue #783)
// ---------------------------------------------------------------------------

pub const max_completion_candidates: usize = 32;
var completion_names: [max_completion_candidates][64]u8 = undefined;
var completion_lens: [max_completion_candidates]u8 = undefined;
var completion_count: usize = 0;

fn completion_reset() void {
    completion_count = 0;
}

fn completion_add(name: []const u8) void {
    if (completion_count >= max_completion_candidates) return;
    if (name.len == 0 or name.len > 64) return;
    for (0..completion_count) |i| {
        if (std.mem.eql(u8, completion_names[i][0..completion_lens[i]], name)) return;
    }
    @memcpy(completion_names[completion_count][0..name.len], name);
    completion_lens[completion_count] = @intCast(name.len);
    completion_count += 1;
}

fn completion_match(prefix: []const u8, name: []const u8) void {
    if (name.len < prefix.len) return;
    if (std.mem.startsWith(u8, name, prefix)) {
        completion_add(name);
        return;
    }
    if (std.ascii.startsWithIgnoreCase(name, prefix)) {
        completion_add(name);
        return;
    }
}

fn completion_sort() void {
    if (completion_count <= 1) return;
    var i: usize = 1;
    while (i < completion_count) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = completion_names[j - 1][0..completion_lens[j - 1]];
            const b = completion_names[j][0..completion_lens[j]];
            if (std.mem.order(u8, a, b) == .gt) {
                var tmp_name: [64]u8 = undefined;
                @memcpy(tmp_name[0..a.len], a);
                const tmp_len = completion_lens[j - 1];

                @memcpy(completion_names[j - 1][0..b.len], b);
                completion_lens[j - 1] = completion_lens[j];

                @memcpy(completion_names[j][0..tmp_len], tmp_name[0..tmp_len]);
                completion_lens[j] = tmp_len;
            } else {
                break;
            }
        }
    }
}

pub fn shell_complete(line: []const u8, cursor: usize, index: usize) ?lineedit.CompletionMatch {
    if (cursor > line.len) return null;

    var start = cursor;
    while (start > 0 and line[start - 1] != ' ' and line[start - 1] != '\t') start -= 1;
    const prefix = line[start..cursor];

    var is_cmd = true;
    var j = start;
    while (j > 0) : (j -= 1) {
        const c = line[j - 1];
        if (c == ';' or c == '|' or c == '&') break;
        if (c != ' ' and c != '\t') {
            is_cmd = false;
            break;
        }
    }

    completion_reset();
    const taken = acquire_file_lock();
    defer release_file_lock(taken);

    if (is_cmd) {
        if (prefix.len == 0) return null;

        inline for (&.{
            "alias",    "break",  "continue", "env", "exit", "export",
            "false",    "fg",     "fn",       "for", "if",   "jobs",
            "printenv", "prompt", "set",      "sh",  "true", "type",
            "unalias",  "unset",  "while",
        }) |b| completion_match(prefix, b);

        inline for (&.{
            "about",  "addrspaces", "beans",    "beep",       "calc",    "cat",       "clear",
            "clip",   "color",      "compose",  "crash",      "dmesg",   "du",        "dui",
            "echo",   "elephant",   "exec",     "fault",      "find",    "font",      "handoff",
            "help",   "hex",        "input",    "inventory",  "kill",    "ls",        "mbox",
            "mem",    "mktemp",     "mount",    "net",        "netsend", "pages",     "pci",
            "procs",  "ps",         "random",   "reboot",     "repeat",  "resources", "roadpops",
            "screen", "screenshot", "settings", "sexiburger", "sh",      "shortcuts", "shutdown",
            "smp",    "sound",      "spawn",    "stat",       "strace",  "sym",       "syscalls",
            "tabwm",  "tasks",      "text",     "time",       "timer",   "tour",      "tty",
            "type",   "uname",      "usb",      "version",    "vf",      "welcome",   "which",
            "wm",     "wnd",        "write",
        }) |cmd_name| completion_match(prefix, cmd_name);

        var fi: usize = 0;
        while (fi < func_count) : (fi += 1) {
            completion_match(prefix, func_table[fi].name[0..func_table[fi].name_len]);
        }

        var ei: usize = 0;
        while (ei < env_count) : (ei += 1) {
            completion_match(prefix, env_table[ei].name[0..env_table[ei].name_len]);
        }

        var list_res: virtio_file.ListResult = .{};
        if (virtio_file.list("", &list_res) == virtio_file.st_ok) {
            for (list_res.entries[0..list_res.count]) |e| {
                const ename = e.name[0..e.name_len];
                completion_match(prefix, ename);
                if (std.mem.endsWith(u8, ename, ".ELF") or std.mem.endsWith(u8, ename, ".BIN")) {
                    const base = ename[0 .. ename.len - 4];
                    completion_match(prefix, base);
                }
            }
        }
    } else {
        var seg_start: usize = 0;
        var s = start;
        while (s > 0) : (s -= 1) {
            const c = line[s - 1];
            if (c == ';' or c == '|' or c == '&') {
                seg_start = s;
                break;
            }
        }
        while (seg_start < line.len and (line[seg_start] == ' ' or line[seg_start] == '\t')) seg_start += 1;
        var cmd_end = seg_start;
        while (cmd_end < line.len and line[cmd_end] != ' ' and line[cmd_end] != '\t') cmd_end += 1;
        const verb = if (cmd_end > seg_start) line[seg_start..cmd_end] else "";

        var arg_idx: usize = 0;
        var scan = cmd_end;
        while (scan < start) {
            while (scan < start and (line[scan] == ' ' or line[scan] == '\t')) scan += 1;
            if (scan >= start) break;
            arg_idx += 1;
            while (scan < start and line[scan] != ' ' and line[scan] != '\t') scan += 1;
        }

        if (std.mem.eql(u8, verb, "exec")) {
            var list_res: virtio_file.ListResult = .{};
            if (virtio_file.list("", &list_res) == virtio_file.st_ok) {
                for (list_res.entries[0..list_res.count]) |e| {
                    const ename = e.name[0..e.name_len];
                    completion_match(prefix, ename);
                }
            }
        } else if (std.mem.eql(u8, verb, "which")) {
            inline for (&.{
                "alias",    "break",  "continue", "env", "exit", "export",
                "false",    "fg",     "fn",       "for", "if",   "jobs",
                "printenv", "prompt", "set",      "sh",  "true", "type",
                "unalias",  "unset",  "while",
            }) |b| completion_match(prefix, b);
            inline for (&.{
                "about",  "addrspaces", "beans",    "beep",       "calc",    "cat",       "clear",
                "clip",   "color",      "compose",  "crash",      "dmesg",   "du",        "dui",
                "echo",   "elephant",   "exec",     "fault",      "find",    "font",      "handoff",
                "help",   "hex",        "input",    "inventory",  "kill",    "ls",        "mbox",
                "mem",    "mktemp",     "mount",    "net",        "netsend", "pages",     "pci",
                "procs",  "ps",         "random",   "reboot",     "repeat",  "resources", "roadpops",
                "screen", "screenshot", "settings", "sexiburger", "sh",      "shortcuts", "shutdown",
                "smp",    "sound",      "spawn",    "stat",       "strace",  "sym",       "syscalls",
                "tabwm",  "tasks",      "text",     "time",       "timer",   "tour",      "tty",
                "type",   "uname",      "usb",      "version",    "vf",      "welcome",   "which",
                "wm",     "wnd",        "write",
            }) |cmd_name| completion_match(prefix, cmd_name);
            var list_res: virtio_file.ListResult = .{};
            if (virtio_file.list("", &list_res) == virtio_file.st_ok) {
                for (list_res.entries[0..list_res.count]) |e| {
                    completion_match(prefix, e.name[0..e.name_len]);
                }
            }
        } else if (std.mem.eql(u8, verb, "help")) {
            inline for (&.{
                "about",  "addrspaces", "beans",    "beep",       "calc",    "cat",       "clear",
                "clip",   "color",      "compose",  "crash",      "dmesg",   "du",        "dui",
                "echo",   "elephant",   "exec",     "fault",      "find",    "font",      "handoff",
                "help",   "hex",        "input",    "inventory",  "kill",    "ls",        "mbox",
                "mem",    "mktemp",     "mount",    "net",        "netsend", "pages",     "pci",
                "procs",  "ps",         "random",   "reboot",     "repeat",  "resources", "roadpops",
                "screen", "screenshot", "settings", "sexiburger", "sh",      "shortcuts", "shutdown",
                "smp",    "sound",      "spawn",    "stat",       "strace",  "sym",       "syscalls",
                "tabwm",  "tasks",      "text",     "time",       "timer",   "tour",      "tty",
                "type",   "uname",      "usb",      "version",    "vf",      "welcome",   "which",
                "wm",     "wnd",        "write",
            }) |cmd_name| completion_match(prefix, cmd_name);
            inline for (&.{
                "system",  "memory_state", "tasks_processes",  "graphics_input",
                "storage", "networking",   "machine_identity", "syscalls",
            }) |t| completion_match(prefix, t);
        } else if (std.mem.eql(u8, verb, "color")) {
            completion_match(prefix, "on");
            completion_match(prefix, "off");
        } else if (std.mem.eql(u8, verb, "font")) {
            completion_match(prefix, "small");
            completion_match(prefix, "medium");
            completion_match(prefix, "large");
        } else if (std.mem.eql(u8, verb, "settings")) {
            completion_match(prefix, "list");
            completion_match(prefix, "get");
            completion_match(prefix, "set");
            completion_match(prefix, "reset");
        } else if (std.mem.eql(u8, verb, "vf")) {
            if (arg_idx == 0) {
                inline for (&.{
                    "ls", "cat", "mkdir", "rm", "mv", "open", "close", "write", "truncate", "fsync",
                }) |sv| completion_match(prefix, sv);
            } else {
                var list_res: virtio_file.ListResult = .{};
                if (virtio_file.list("", &list_res) == virtio_file.st_ok) {
                    for (list_res.entries[0..list_res.count]) |e| {
                        completion_match(prefix, e.name[0..e.name_len]);
                    }
                }
            }
        } else if (std.mem.eql(u8, verb, "dui")) {
            inline for (&.{
                "focus", "raise", "lower", "move", "close", "list", "hit", "cycle", "tile", "master",
            }) |sv| completion_match(prefix, sv);
        } else if (std.mem.eql(u8, verb, "net")) {
            inline for (&.{
                "recv", "ip", "arp", "ping", "udp", "dhcp", "tcp", "dns",
            }) |sv| completion_match(prefix, sv);
        } else if (std.mem.eql(u8, verb, "usb")) {
            completion_match(prefix, "devices");
            completion_match(prefix, "report");
            completion_match(prefix, "bulk");
        } else if (std.mem.eql(u8, verb, "screen")) {
            completion_match(prefix, "fill");
        } else if (std.mem.eql(u8, verb, "cat") or std.mem.eql(u8, verb, "write") or
            std.mem.eql(u8, verb, "sh") or std.mem.eql(u8, verb, "stat") or
            std.mem.eql(u8, verb, "du") or std.mem.eql(u8, verb, "ls"))
        {
            var list_res: virtio_file.ListResult = .{};
            if (virtio_file.list("", &list_res) == virtio_file.st_ok) {
                for (list_res.entries[0..list_res.count]) |e| {
                    completion_match(prefix, e.name[0..e.name_len]);
                }
            }
        }
    }

    completion_sort();

    if (completion_count == 0) return null;
    const idx = index % completion_count;
    const cand = completion_names[idx][0..completion_lens[idx]];
    return lineedit.CompletionMatch{
        .replace_start = start,
        .text = cand,
        .match_count = completion_count,
        .has_trailing_space = false,
    };
}

pub const Shell = struct {
    mon: monitor.Monitor,
    editor: lineedit.LineEditor = .{},
    prompt_shown: bool = false,
    /// Scrollback ring capturing all console output.
    scrollback: scrollback_mod.Scrollback = .{},
    /// Context for the wrapped Console; lives here (BSS) for lifetime.
    scrollback_ctx: ScrollbackCtx = undefined,
    /// Number of lines scrolled back from live view (0 = live mode).
    scroll_offset: usize = 0,
    /// Mini CSI parser for intercepting scroll keys before the editor.
    scroll_csi: u8 = 0,
    scroll_csi_param: u16 = 0,
    csi_private: bool = false, // ESC [ ? sequences (DEC private modes)
    /// M18 T2: selection state for copy-from-scrollback.
    selecting: bool = false,
    sel_start: usize = 0, // line offset (from newest) where selection begins
    sel_end: usize = 0, // line offset (from newest) where selection ends
    /// M18 T3: reverse-i-search state.
    searching: bool = false,
    search_query: [64]u8 = undefined,
    search_query_len: usize = 0,
    /// Saved editor state from before search started.
    search_draft: [lineedit.max_line]u8 = undefined,
    search_draft_len: usize = 0,
    search_draft_cursor: usize = 0,
    /// M18 T5: whether ANSI color escapes are emitted.
    /// Set true in boot_and_park(), false in host tests (preserves transcript).
    color_enabled: bool = false,
    /// M18 T6: bracketed paste mode — accumulating pasted text.
    paste_active: bool = false,
    paste_buf: [lineedit.max_line]u8 = undefined,
    paste_buf_len: usize = 0,
    /// M18 T7: alternate screen active (CSI ? 1049 h/l)
    alt_screen: bool = false,

    pub fn init(con: console.Console, state: monitor.SystemState, machine: monitor.MachineControl) Shell {
        var shell = Shell{
            .mon = monitor.Monitor.init(con, state, machine),
            .scrollback = scrollback_mod.Scrollback{},
            .scrollback_ctx = undefined,
            .scroll_offset = 0,
        };
        shell.scrollback.reset();
        // Self-hosting #20 (issue #783): command + argument completion with Tab cycling.
        shell.editor.completer = shell_complete;
        shell.editor.completion = monitor.complete;
        return shell;
    }

    /// Print the boot banner once (`monitor.banner`). Also wraps the
    /// console with scrollback capture (must happen here, not in init(),
    /// so that self-referential pointers within the Shell remain valid —
    /// init() returns by value and would leave dangling pointers).
    pub fn boot(self: *Shell) void {
        self.scrollback_ctx = ScrollbackCtx{
            .inner = self.mon.console,
            .sb = &self.scrollback,
        };
        self.mon.console = console.Console{
            .ctx = &self.scrollback_ctx,
            .vtable = ensure_scrollback_vtable(),
        };
        monitor.banner(&self.mon);
    }

    /// M19 P4 (issue #293): print the prompt in the color that reports the
    /// last exit status — green on 0, red otherwise (T5/T15 seam). No-ops
    /// the escape bytes when colors are disabled.
    fn puts_colored_prompt(self: *Shell) void {
        if (self.color_enabled) self.mon.console.puts(if (last_exit_ok) "\x1b[32m" else "\x1b[31m");
        self.mon.console.puts(expanded_prompt());
        if (self.color_enabled) self.mon.console.puts("\x1b[0m");
    }

    /// Drive one byte of input. Prints the prompt exactly once
    /// per line (on the poll that starts it). Returns `.idle` when no byte
    /// is available — callers park between polls; tests drive until idle.
    pub fn poll(self: *Shell) PollResult {
        // #1072 (ADR 0020 D4): while a process owns the serial console via an
        // attached terminal, the kernel shell must not steal its input. The
        // console's RX FIFO buffers keys for the terminal's next read.
        if (terminal.attachedSerial() != null) return .idle;
        if (!self.prompt_shown) {
            self.puts_colored_prompt();
            self.prompt_shown = true;
        }
        const byte = self.mon.console.readByte() orelse return .idle;
        // M18 T6: bracketed paste mode — buffer bytes until 201~.
        // Newlines inside paste are kept as-is; the whole buffer is
        // submitted as one multi-line block when paste ends.
        if (self.paste_active) {
            if (self.scroll_csi_track(byte)) {
                self.editor.csi_reset(); // tracker consumed a byte mid-CSI
                return .pending;
            }
            if (self.paste_buf_len < lineedit.max_line) {
                self.paste_buf[self.paste_buf_len] = byte;
                self.paste_buf_len += 1;
            }
            return .pending;
        }
        // M18 T2: intercept Ctrl+C / Enter when selecting in scrollback.
        // (Esc is NOT intercepted here — it must pass through to the CSI
        //  tracker so Up/Down arrows work. A lone Esc cancels selection
        //  in the tracker's state machine.)
        if (self.selecting) {
            switch (byte) {
                0x03 => { // Ctrl+C: copy and return to live
                    self.selection_copy_and_exit();
                    self.prompt_shown = false;
                    return .processed;
                },
                0x0D => { // Enter: copy and return to live
                    self.mon.console.puts("\n");
                    self.selection_copy_and_exit();
                    self.prompt_shown = false;
                    return .processed;
                },
                else => {},
            }
        }
        // M18 T2: intercept Ctrl+V at the prompt to paste clipboard
        // (only in live mode, not during scrollback selection).
        if (!self.selecting and !self.searching and byte == 0x16) { // Ctrl+V
            self.paste_clipboard();
            return .pending;
        }
        // M18 T3: intercept Ctrl+R to enter reverse-i-search.
        if (byte == 0x12) { // Ctrl+R
            if (!self.selecting) {
                self.search_enter();
                return .pending;
            }
            return .pending;
        }
        // M18 T3: search mode — every byte feeds the query matcher.
        if (self.searching) {
            return self.search_handle(byte);
        }
        // M18 T1: shadow-track CSI state for PageUp/PageDown scroll keys.
        // Only the final '~' byte of a scroll sequence is consumed; all
        // other bytes (including arrow-key sequences) pass through to
        // the editor unchanged.
        if (self.scroll_csi_track(byte)) {
            // The tracker consumed the final byte of a sequence the editor
            // was mid-way through (scroll keys' '~', selection arrows,
            // swallowed CSI finals). Reset the editor's CSI state so the
            // next keystroke types cleanly — without this, `[5`/`[6`
            // fragments from a scroll key insert into the line and the
            // following ESC is swallowed (T1 live-gate finding).
            self.editor.csi_reset();
            return .pending;
        }
        switch (self.editor.feed(self.mon.console, byte)) {
            .none => return .pending,
            .repaint => {
                // Ctrl-L: the editor cleared the screen; restore the prompt
                // + the in-progress line (the editor does not own the prompt).
                self.puts_colored_prompt();
                self.editor.reprint(self.mon.console);
                return .pending;
            },
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
                    // ADR 0008 D3 shape 2 (a refusal is a failure).
                    monitor.err_line(&self.mon, "input refused: line longer than 256 bytes");
                }
                handle_line(&self.mon, line);
                // M18 T4: persist non-empty lines.
                if (line.len > 0) save_to_history(line);
                return .processed;
            },
        }
    }

    /// M18 T1: shadow-track CSI sequences to detect PageUp (CSI 5 ~) and
    /// PageDown (CSI 6 ~). All bytes always reach the line editor except
    /// the final '~' of a scroll sequence, which is consumed. Returns true
    /// only when a scroll key's final byte was consumed.
    fn scroll_csi_track(self: *Shell, byte: u8) bool {
        switch (self.scroll_csi) {
            0 => {
                if (byte == 0x1B) self.scroll_csi = 1;
                return false; // always pass through
            },
            1 => {
                if (byte == '[') {
                    self.scroll_csi = 2;
                    self.scroll_csi_param = 0;
                    self.csi_private = false;
                } else if (byte == ']') {
                    // M18 T11: OSC — swallow until BEL or ST (ESC \)
                    self.scroll_csi = 4;
                } else {
                    self.scroll_csi = 0; // lone ESC — pass through for editor
                    // M18 T2: a lone ESC in selection mode cancels
                    // selection. The cancel fires on the byte AFTER the
                    // ESC (the tracker cannot know a lone ESC until
                    // something else arrives), but that byte is a real
                    // keystroke — it must NOT be eaten (lineedit: "a lone
                    // ESC does not eat the next keystroke"; live-gate
                    // finding: the chord after ESC lost its first char).
                    if (self.selecting) {
                        self.selection_cancel();
                        self.prompt_shown = false;
                    }
                }
                return false; // always pass through
            },
            // M18 T11: OSC mode — swallow all bytes until BEL (0x07) or ST (ESC \)
            4 => {
                if (byte == 0x07) { // BEL terminates OSC
                    self.scroll_csi = 0;
                } else if (byte == 0x1B) { // might be start of ST (ESC \)
                    self.scroll_csi = 5;
                }
                return false; // pass through (they're harmless)
            },
            5 => {
                // After ESC in OSC: '\' = ST terminator, anything else = resume OSC
                self.scroll_csi = if (byte == '\\') 0 else 4;
                return false;
            },
            2 => {
                // M18 T7: CSI ? prefix for DEC private modes
                if (byte == '?') {
                    self.csi_private = true;
                    self.scroll_csi = 3;
                    return false;
                }
                if (byte >= '0' and byte <= '9') {
                    self.scroll_csi_param = byte - '0';
                    self.scroll_csi = 3;
                    return false; // pass digit through
                }
                // M18 T2: intercept Up/Down arrows when selecting in scrollback.
                if (self.selecting) {
                    if (byte == 'A') { // Up: extend selection upward
                        const max_off = self.scrollback.stored();
                        if (self.sel_end < max_off) {
                            self.sel_end += 1;
                        }
                        self.scroll_csi = 0;
                        return true;
                    }
                    if (byte == 'B') { // Down: shrink selection toward live
                        if (self.sel_end > self.sel_start) {
                            self.sel_end -= 1;
                        } else {
                            // Single-line selection: Down exits to live
                            self.selection_cancel();
                        }
                        self.scroll_csi = 0;
                        return true;
                    }
                }
                // single-char final (A/B/C/D etc) — editor handles arrow keys
                self.scroll_csi = 0;
                return false; // pass through
            },
            3 => {
                if (byte >= '0' and byte <= '9') {
                    const scaled: u16 = self.scroll_csi_param * 10;
                    self.scroll_csi_param = @min(scaled + (byte - '0'), 9999);
                    return false;
                }
                // ; separator in multi-param sequences (e.g. ESC [ 8; H; W; t)
                if (byte == ';') {
                    self.scroll_csi_param = 0;
                    return false; // restart param collection
                }
                if (byte == '~') {
                    const p = self.scroll_csi_param;
                    self.scroll_csi = 0;
                    self.csi_private = false;
                    return self.scroll_handle(p);
                }
                // M18 T7–T11: CSI final handlers
                const handled = self.csi_final(byte);
                self.scroll_csi = 0;
                self.csi_private = false;
                return handled;
            },
            else => {
                self.scroll_csi = 0;
                self.csi_private = false;
                return false;
            },
        }
    }

    /// Handle a completed CSI parameter for scroll keys + paste.
    /// Returns true if the key was consumed.
    fn scroll_handle(self: *Shell, param: u16) bool {
        switch (param) {
            5 => { // PageUp: scroll up one page (10 lines)
                const max_off = self.scrollback.stored();
                self.scroll_offset = @min(self.scroll_offset + 10, max_off);
                if (self.scroll_offset > 0 and !self.selecting) {
                    self.selecting = true;
                    self.sel_start = self.scroll_offset;
                    self.sel_end = self.scroll_offset;
                }
                return true;
            },
            6 => { // PageDown: scroll down one page (10 lines)
                if (self.scroll_offset > 10) {
                    self.scroll_offset -= 10;
                } else {
                    self.scroll_offset = 0;
                }
                if (self.scroll_offset == 0) {
                    // Back at the live view: selection is over. Without
                    // this, a real Enter (0x0D) after scrolling back to
                    // live hits the selection branch and copies+discards
                    // the line instead of submitting it (T1 live-gate
                    // finding — only serial '\n' slipped past before).
                    self.selecting = false;
                    self.sel_start = 0;
                    self.sel_end = 0;
                } else if (!self.selecting) {
                    self.selecting = true;
                    self.sel_start = self.scroll_offset;
                    self.sel_end = self.scroll_offset;
                }
                return true;
            },
            200 => { // Bracketed paste start
                self.paste_active = true;
                self.paste_buf_len = 0;
                return true;
            },
            201 => { // Bracketed paste end — submit accumulated buffer
                self.paste_active = false;
                const saved_len = self.paste_buf_len;
                self.paste_buf_len = 0;
                // Execute each line through the normal shell path
                var start: usize = 0;
                var i: usize = 0;
                while (i < saved_len) : (i += 1) {
                    if (self.paste_buf[i] == '\n' or self.paste_buf[i] == '\r') {
                        if (i > start) {
                            handle_line(&self.mon, self.paste_buf[start..i]);
                        }
                        start = i + 1;
                        // Skip the LF of a CRLF pair
                        if (self.paste_buf[i] == '\r' and i + 1 < saved_len and self.paste_buf[i + 1] == '\n') {
                            i += 1;
                            start = i + 1;
                        }
                    }
                }
                if (start < saved_len) {
                    handle_line(&self.mon, self.paste_buf[start..saved_len]);
                }
                self.prompt_shown = false;
                return true;
            },
            else => return false,
        }
    }

    /// M18 T7–T11: handle CSI single-char final byte after param
    /// collection. Returns true if consumed (no bytes reach the editor).
    fn csi_final(self: *Shell, byte: u8) bool {
        switch (byte) {
            // M18 T7: alternate screen toggle (CSI ? 1049 h/l)
            'h' => {
                if (self.csi_private and self.scroll_csi_param == 1049) {
                    self.alt_screen = true;
                    // Clear screen on entering alt screen
                    self.mon.console.puts("\x1b[2J\x1b[H");
                    self.prompt_shown = false;
                }
                return true;
            },
            'l' => {
                if (self.csi_private and self.scroll_csi_param == 1049) {
                    self.alt_screen = false;
                    self.mon.console.puts("\x1b[2J\x1b[H");
                    self.prompt_shown = false;
                }
                return true;
            },
            // CSI n responder — only reply to DSR (6n = cursor position)
            'n' => {
                if (self.scroll_csi_param == 6) {
                    self.mon.console.puts("\x1b[1;1R");
                }
                return true;
            },
            // Swallow: SGR (m), cursor shape (q), window ops (t/s),
            // cursor-pos reply (R), DECSET/DECRST (h/l without ?)
            'm', 't', 's', 'q', 'R' => return true,
            // Single-char finals: arrows — already handled in state 2.
            // A/B/C/D from state 3 (with param) are swallowed.
            'A', 'B', 'C', 'D', 'H', 'J', 'K', 'G', 'd', 'f', 'r', 'u', 'c' => return true,
            else => return false, // pass through to editor
        }
    }

    /// Called when the user presses Ctrl+C or Enter while selecting in the
    /// scrollback view. Copies the selected lines to the clipboard and
    /// returns to live mode. Returns true if consumed.
    fn selection_copy_and_exit(self: *Shell) void {
        if (!self.selecting or self.scroll_offset == 0) return;
        // Build the selected text from scrollback lines
        const start = if (self.sel_start < self.sel_end) self.sel_start else self.sel_end;
        const end = if (self.sel_start > self.sel_end) self.sel_start else self.sel_end;
        const count = end - start + 1;

        // Retrieve the selected lines into a stack buffer
        const buflen: usize = 512;
        var buf: [buflen]u8 = undefined;
        var pos: usize = 0;
        var dst: [128][]u8 = undefined;
        var dst_bufs: [128][128]u8 = undefined;
        for (&dst, 0..) |*d, j| d.* = dst_bufs[j][0..];

        const n = self.scrollback.copy_lines(start, @min(count, 128), dst[0..]);
        var i: usize = 0;
        while (i < n and pos < buflen - 2) : (i += 1) {
            const line = dst[i];
            for (line) |ch| {
                if (ch == 0 or pos >= buflen - 2) break;
                buf[pos] = ch;
                pos += 1;
            }
            if (i + 1 < n and pos < buflen - 1) {
                buf[pos] = '\n';
                pos += 1;
            }
        }
        _ = clipboard.set(buf[0..pos]);
        self.mon.console.print_line("copied");

        // Return to live mode
        self.selecting = false;
        self.scroll_offset = 0;
    }

    /// Cancel selection and return to live mode (Esc key).
    fn selection_cancel(self: *Shell) void {
        self.selecting = false;
        self.scroll_offset = 0;
    }

    /// Paste clipboard contents into the editor at cursor position.
    fn paste_clipboard(self: *Shell) void {
        var cbuf: [clipboard.capacity]u8 = undefined;
        const n = clipboard.get(&cbuf);
        if (n == 0) return;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = self.editor.feed(self.mon.console, cbuf[i]);
        }
    }

    /// M18 T3: reverse-i-search — search backward through scrollback +
    /// editor history for lines containing the query string.
    /// Returns the search result line and its length, or null on no match.
    fn search_match(self: *Shell, query: []const u8) ?[]const u8 {
        if (query.len == 0) return null;

        // Search the editor's session history ring first (newest first).
        var hi: usize = 0;
        while (hi < self.editor.hist_count) : (hi += 1) {
            const line = self.editor.history[hi][0..self.editor.hist_len[hi]];
            if (std.mem.indexOf(u8, line, query) != null) return line;
        }

        // Search the scrollback ring lines (newest first).
        const sb_stored = self.scrollback.stored();
        if (sb_stored > 0) {
            var dst: [128][128]u8 = undefined;
            var slices: [128][]u8 = undefined;
            for (&slices, 0..) |*s, j| s.* = dst[j][0..];
            const n = self.scrollback.copy_lines(0, @min(sb_stored, 128), slices[0..]);
            var si: usize = 0;
            while (si < n) : (si += 1) {
                if (std.mem.indexOf(u8, slices[si], query) != null) return slices[si];
            }
        }

        return null;
    }

    /// Enter reverse-i-search mode. Saves the current editor state so
    /// we can restore it on cancel.
    fn search_enter(self: *Shell) void {
        // Save current editor state
        @memcpy(self.search_draft[0..self.editor.len], self.editor.buffer[0..self.editor.len]);
        self.search_draft_len = self.editor.len;
        self.search_draft_cursor = self.editor.cursor;

        self.searching = true;
        self.search_query_len = 0;
        self.search_redraw();
    }

    /// Redraw the search prompt + current match.
    fn search_redraw(self: *Shell) void {
        // Move to a new line and show the search UI
        self.mon.console.puts("\r\n");
        self.mon.console.puts("(reverse-i-search)`");
        if (self.search_query_len > 0) {
            self.mon.console.puts(self.search_query[0..self.search_query_len]);
        } else {
            self.mon.console.puts("_");
        }
        self.mon.console.puts("`: ");

        // Show the current match (if any)
        const query = if (self.search_query_len > 0) self.search_query[0..self.search_query_len] else &[0]u8{};
        if (self.search_match(query)) |match| {
            self.mon.console.puts(match);
            // Load it into the editor so Enter accepts it
            self.editor.len = @min(match.len, lineedit.max_line);
            @memcpy(self.editor.buffer[0..self.editor.len], match[0..self.editor.len]);
            self.editor.cursor = self.editor.len;
        } else {
            self.mon.console.puts("(no match)");
        }
    }

    /// Handle a keypress in search mode.
    fn search_handle(self: *Shell, byte: u8) PollResult {
        switch (byte) {
            0x1B => { // Esc: cancel, restore draft
                self.search_exit(false);
                return .processed;
            },
            0x0D, 0x0A => { // Enter: accept the current match. The
                // keyboard Return decodes to LF (input.zig), and the line
                // editor already treats CR and LF alike — search accepts
                // both (T3 live-gate finding: a synthesized Return chord
                // was ignored in search mode).
                self.search_exit(true);
                return .processed;
            },
            0x7F, 0x08 => { // Backspace / Delete: remove last query char
                if (self.search_query_len > 0) {
                    self.search_query_len -= 1;
                    self.search_redraw();
                }
                return .pending;
            },
            0x03 => { // Ctrl+C: cancel
                self.search_exit(false);
                self.prompt_shown = false;
                return .processed;
            },
            0x0C => { // Ctrl+L: ignore the clear
                return .pending;
            },
            else => {
                // Only accept printable ASCII
                if (byte >= 0x20 and byte <= 0x7E and self.search_query_len < 64) {
                    self.search_query[self.search_query_len] = byte;
                    self.search_query_len += 1;
                    self.search_redraw();
                }
                return .pending;
            },
        }
    }

    /// Exit search mode, restoring or accepting.
    fn search_exit(self: *Shell, accept: bool) void {
        self.searching = false;
        if (!accept) {
            // Restore the saved draft
            @memcpy(self.editor.buffer[0..self.search_draft_len], self.search_draft[0..self.search_draft_len]);
            self.editor.len = self.search_draft_len;
            self.editor.cursor = self.search_draft_cursor;
        }
        // Redraw the prompt
        self.mon.console.puts("\r\n");
        self.prompt_shown = false;
    }
};

/// HF5/HF6: read the existing history file from the HOST SHARE into
/// `buf`. Returns the byte count (0 = absent/empty / no channel).
fn history_read_existing(buf: []u8) usize {
    if (trust.check(trust.kernel_actor(), .host, history_path, .read) != .allow) return 0;
    const taken = acquire_file_lock();
    defer release_file_lock(taken);
    return virtio_file.read_whole(history_path, buf) orelse 0;
}

/// HF5/HF6: write the whole history file to the share.
fn history_write_all(bytes: []const u8) void {
    if (trust.check(trust.kernel_actor(), .host, history_path, .write) != .allow) return;
    const taken = acquire_file_lock();
    defer release_file_lock(taken);
    _ = virtio_file.write_whole(history_path, bytes);
}

/// M18 T4: append a command line to the persistent history file.
fn save_to_history(line: []const u8) void {
    // Read existing history, trim oldest if at capacity, append new line.
    var existing: [2048]u8 = undefined;
    const existing_len = history_read_existing(&existing);
    var line_count: usize = 0;
    var i: usize = 0;
    while (i < existing_len) : (i += 1) {
        if (existing[i] == '\n') line_count += 1;
    }
    if (existing_len > 0 and existing[existing_len - 1] != '\n') line_count += 1;
    var start: usize = 0;
    if (line_count >= history_file_max) {
        while (start < existing_len and existing[start] != '\n') start += 1;
        if (start < existing_len) start += 1;
    }
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    const tail = existing[start..existing_len];
    @memcpy(buf[pos..][0..tail.len], tail);
    pos += tail.len;
    @memcpy(buf[pos..][0..line.len], line);
    pos += line.len;
    buf[pos] = '\n';
    pos += 1;
    history_write_all(buf[0..pos]);
}

/// M18 T4: load persistent history from HISTORY.TXT into editor ring.
pub fn load_history(editor: *lineedit.LineEditor) void {
    var content_buf: [2048]u8 = undefined;
    const content = content_buf[0..history_read_existing(&content_buf)];
    if (content.len == 0) return;
    var line_starts: [64]usize = undefined;
    var line_lens: [64]usize = undefined;
    var line_count: usize = 0;
    var i: usize = 0;
    while (i < content.len and line_count < 64) : (i += 1) {
        const start = i;
        while (i < content.len and content[i] != '\n') i += 1;
        const len = i - start;
        if (len > 0 and len < lineedit.max_line) {
            line_starts[line_count] = start;
            line_lens[line_count] = len;
            line_count += 1;
        }
    }
    // HISTORY.TXT is append-ordered (oldest first, newest last), so the
    // file's LAST line is the most recent command. Insert lines in file
    // order at index 0, leaving the newest at history[0] — the same
    // newest-first shape the session ring has, so the first Up arrow
    // after boot recalls the most recent command (the T4 intent; the
    // original backward iteration left the OLDEST at index 0 — fixed
    // 2026-08-22 while bringing up the live gate, claim 0469).
    var li: usize = 0;
    while (li < line_count) : (li += 1) {
        const line = content[line_starts[li]..][0..line_lens[li]];
        if (editor.hist_count > 0 and std.mem.eql(u8, line, editor.history[0][0..editor.hist_len[0]])) continue;
        const keep: usize = @min(editor.hist_count, lineedit.hist_capacity - 1);
        var j = keep;
        while (j > 0) : (j -= 1) {
            @memcpy(editor.history[j][0..editor.hist_len[j - 1]], editor.history[j - 1][0..editor.hist_len[j - 1]]);
            editor.hist_len[j] = editor.hist_len[j - 1];
        }
        const n = @min(line.len, lineedit.max_line);
        @memcpy(editor.history[0][0..n], line[0..n]);
        editor.hist_len[0] = n;
        editor.hist_count = keep + 1;
    }
}

/// M18 T16 (issue #419): load a script file into the staging buffer from
/// the HOST SHARE (STAT for the size, then read_into up to the 16 KiB
/// staging bound). Prints the honest refusal and returns null on any
/// miss. M34 HF6 (issue #740): the ESP/FAT read paths are gone.
fn script_load(mon: *monitor.Monitor, name: []const u8) ?[]const u8 {
    // M50 TS2 (ADR 0024 D4/D8): the kernel-actor content-read gate —
    // `sh <script>` must not read a secret-class path (the monitor `sh`
    // command, and EL0 `source`/pipes routed through it, inherit this).
    if (trust.check(trust.kernel_actor(), .host, name, .read) != .allow) {
        mon.console.puts("sh: ");
        mon.console.puts(name);
        mon.console.print_line(": permission denied");
        return null;
    }
    const taken = acquire_file_lock();
    defer release_file_lock(taken);
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(name, &st) != virtio_file.st_ok or st.is_dir) {
        mon.console.puts("sh: ");
        mon.console.puts(name);
        mon.console.print_line(": not found (no such file on the host share)");
        return null;
    }
    if (st.size > @as(u64, @intCast(script_staging_max))) {
        mon.console.puts("sh: ");
        mon.console.puts(name);
        mon.console.puts(": file is ");
        mon.console.print_hex(st.size);
        mon.console.puts(" bytes; scripts cap at ");
        mon.console.print_hex(script_staging_max);
        mon.console.print_line(" bytes");
        return null;
    }
    const got = virtio_file.read_into(name, st.size, &script_staging) orelse {
        mon.console.puts("sh: ");
        mon.console.puts(name);
        mon.console.print_line(": not found (no such file on the host share)");
        return null;
    };
    return script_staging[0..got];
}

/// M18 T16 (issue #419): execute a script file of shell commands, one
/// line at a time, through handle_line() — the same path interactive
/// input takes, so env expansion, aliases, and builtins all apply inside
/// scripts. Bounds: file ≤ 16 KiB staging, ≤ 64 executable lines,
/// ≤ 256 chars per line. A failing command never aborts the script (no
/// abort-on-error by default); `exit` stops it early; scripts cannot
/// call scripts.
fn run_script(mon: *monitor.Monitor, name: []const u8) void {
    if (script_active) {
        mon.console.print_line("sh: scripts cannot call scripts");
        return;
    }
    const content = script_load(mon, name) orelse return;
    script_active = true;
    defer script_active = false;
    script_stop = false;
    var exec_lines: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n' or content[i] == '\r') {
            if (i > start) {
                const raw = content[start..i];
                // Skip leading whitespace so comments and blank lines
                // are recognized wherever they start.
                var t: usize = 0;
                while (t < raw.len and (raw[t] == ' ' or raw[t] == '\t')) t += 1;
                const line = raw[t..];
                if (line.len > 0 and line[0] != '#') {
                    if (exec_lines >= script_max_lines) {
                        mon.console.puts("sh: too many lines (max ");
                        mon.console.print_u64(script_max_lines);
                        mon.console.print_line(")");
                        break;
                    }
                    if (line.len > script_line_max) {
                        mon.console.puts("sh: line too long (max ");
                        mon.console.print_u64(script_line_max);
                        mon.console.print_line(" bytes)");
                    } else {
                        handle_line(mon, line);
                        exec_lines += 1;
                        if (script_stop) break;
                    }
                }
            }
            start = i + 1;
            // Skip the LF of a CRLF pair.
            if (i < content.len and content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') i += 1;
        }
    }
}

pub fn handle_line(mon: *monitor.Monitor, raw_line: []const u8) void {
    // M19 P13: here-document collection mode. When `heredoc_active` is
    // true, each line is collected until the delimiter is found.
    if (heredoc_active) {
        // Trim the line for delimiter comparison.
        var trimmed = raw_line;
        while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) trimmed = trimmed[1..];
        var tend = trimmed.len;
        while (tend > 0 and (trimmed[tend - 1] == ' ' or trimmed[tend - 1] == '\t')) tend -= 1;
        const t = trimmed[0..tend];

        if (std.mem.eql(u8, t, heredoc_delim[0..heredoc_delim_len])) {
            // Delimiter found — execute the command with collected content.
            heredoc_active = false;
            // Add trailing newline after last line.
            if (heredoc_len > 0 and heredoc_len < heredoc_buf.len) {
                heredoc_buf[heredoc_len] = '\n';
                heredoc_len += 1;
            }
            var content = heredoc_buf[0..heredoc_len];
            // Expand $VAR if unquoted delimiter.
            if (heredoc_expand) {
                var exp_buf: [4096]u8 = undefined;
                content = env_expand(content, &exp_buf);
            }
            const saved = mon.console;
            mon.console = redirect.feed_console(saved, content);
            shell_handle_expanded(mon, heredoc_cmd[0..heredoc_cmd_len]);
            mon.console = saved;
            return;
        }
        // Append line to heredoc buffer.
        heredoc_line_count += 1;
        if (heredoc_line_count > heredoc_max_lines) {
            heredoc_active = false;
            mon.console.print_line("heredoc: too many lines (max 64)");
            return;
        }
        if (raw_line.len > 0) {
            if (heredoc_len > 0 and heredoc_len < heredoc_buf.len) {
                heredoc_buf[heredoc_len] = '\n';
                heredoc_len += 1;
            }
            const copy_len = @min(raw_line.len, heredoc_buf.len - heredoc_len);
            @memcpy(heredoc_buf[heredoc_len..][0..copy_len], raw_line[0..copy_len]);
            heredoc_len += copy_len;
        }
        return;
    }

    // M19 P13: detect `<<DELIM` in the raw line (before any expansions).
    if (std.mem.indexOf(u8, raw_line, "<<")) |dl_pos| {
        // Extract delimiter after `<<`.
        var dstart = dl_pos + 2;
        while (dstart < raw_line.len and raw_line[dstart] == ' ') dstart += 1;
        if (dstart < raw_line.len) {
            var dend = dstart;
            while (dend < raw_line.len and raw_line[dend] != ' ' and raw_line[dend] != ';' and raw_line[dend] != '\t') dend += 1;
            var delim = raw_line[dstart..dend];
            // Check for quoted delimiter (no expansion).
            heredoc_expand = true;
            if (delim.len >= 2 and delim[0] == '"' and delim[delim.len - 1] == '"') {
                delim = delim[1..][0 .. delim.len - 2];
                heredoc_expand = false;
            }
            if (delim.len == 0 or delim.len > 31) {
                mon.console.print_line("heredoc: invalid delimiter");
                return;
            }
            // Extract the command part (before `<<`).
            var cmd_end = dl_pos;
            while (cmd_end > 0 and (raw_line[cmd_end - 1] == ' ' or raw_line[cmd_end - 1] == '\t')) cmd_end -= 1;
            if (cmd_end == 0) {
                mon.console.print_line("heredoc: missing command before <<");
                return;
            }
            // Enter heredoc collection mode.
            @memcpy(heredoc_delim[0..delim.len], delim);
            heredoc_delim_len = delim.len;
            @memcpy(heredoc_cmd[0..cmd_end], raw_line[0..cmd_end]);
            heredoc_cmd_len = cmd_end;
            heredoc_len = 0;
            heredoc_line_count = 0;
            heredoc_active = true;
            return;
        }
    }

    // M19 P3 (issue #292): chaining is decided on the RAW line, BEFORE
    // any expansion — each segment then expands at its own execution
    // time, so `$?`, `$(cmd)`, and `$VAR` in later segments observe the
    // state earlier segments left behind (the POSIX ordering; expanding
    // the whole line up front would bake in stale values).
    //
    // Structured forms keep their internal `;` semantics (function
    // definitions, loop headers, if/then/else) and are dispatched un-split.
    const structured_form = std.mem.startsWith(u8, raw_line, "if ") or
        std.mem.startsWith(u8, raw_line, "if\t") or
        std.mem.startsWith(u8, raw_line, "fn ") or
        std.mem.startsWith(u8, raw_line, "fn\t") or
        std.mem.startsWith(u8, raw_line, "for ") or
        std.mem.startsWith(u8, raw_line, "for\t") or
        std.mem.startsWith(u8, raw_line, "while ") or
        std.mem.startsWith(u8, raw_line, "while\t");
    if (!structured_form) {
        switch (chain_split(raw_line)) {
            .too_many => {
                mon.console.print_line("chains: too many commands (max 4 per chain)");
                return;
            },
            .chain => |c| {
                run_chain(mon, c.segs[0..c.seg_count], c.ops[0..c.op_count]);
                return;
            },
            .none => {},
        }
    }

    expand_and_dispatch(mon, raw_line);
}

/// The per-command expansion pipeline every submitted line used to run
/// through before dispatch: arithmetic substitution, command substitution,
/// `$VAR` expansion (skipped wholesale for `fn`/`for`/`while` lines so
/// body references expand at execution time), then the alias check and
/// the builtin/registry path. M19 P3 chains call this once PER SEGMENT.
fn expand_and_dispatch(mon: *monitor.Monitor, raw_line: []const u8) void {
    // P10: arithmetic expansion `$((expr))` — evaluate and substitute.
    // Skip for fn definitions (preserve $((...)  in function bodies).
    var arith_buf: [lineedit.max_line]u8 = undefined;
    // P12: skip expansions for `for`/`while`/`fn` — their bodies contain
    // $VAR references that should be expanded at execution time, not parse time.
    const skip_expansions = subst_active or
        std.mem.startsWith(u8, raw_line, "fn ") or
        std.mem.startsWith(u8, raw_line, "fn\t") or
        std.mem.startsWith(u8, raw_line, "for ") or
        std.mem.startsWith(u8, raw_line, "for\t") or
        std.mem.startsWith(u8, raw_line, "while ") or
        std.mem.startsWith(u8, raw_line, "while\t");

    const line_after_arith = if (skip_expansions)
        raw_line
    else
        arith_expand(raw_line, &arith_buf);

    // P9: command substitution `$(cmd)` — execute inner command, capture
    // stdout, substitute back into the line.  Skip for fn/for/while.
    // Also skip when subst_active (prevent nesting).
    var subst_buf: [lineedit.max_line]u8 = undefined;
    const line_after_subst = if (skip_expansions)
        line_after_arith
    else
        cmd_subst(mon, line_after_arith, &subst_buf);

    // M18 T12: expand $VAR references before tokenizing.
    // P8/P12: skip expansion for `fn`/`for`/`while` so $VAR in bodies
    // stays literal — expanded at invocation/iteration time.
    var expanded: [lineedit.max_line]u8 = undefined;
    const line = if (skip_expansions)
        line_after_subst
    else
        env_expand(line_after_subst, &expanded);

    // M19 P7 (issue #296): one trailing unquoted `&` backgrounds the
    // command — strip it, dispatch the rest, and clear the flag no matter
    // how the dispatch returns (a non-spawning command simply records no
    // job: there was nothing asynchronous to track).
    if (trailing_bg_amp(line)) |idx| {
        const cmd = trim_end(line[0..idx]);
        if (cmd.len == 0) return; // bare `&`: nothing to run
        bg_pending = true;
        dispatch_line(mon, cmd);
        bg_pending = false;
        return;
    }

    dispatch_line(mon, line);
}

/// M19 P3 (issue #292): dispatch one already-expanded command segment —
/// the M18 T13 first-word alias check followed by the normal builtin /
/// registry path. Extracted verbatim from handle_line's tail so chains,
/// scripts, and plain lines share one dispatch seam.
fn dispatch_line(mon: *monitor.Monitor, line: []const u8) void {
    // M18 T13: check for alias expansion (only first word)
    if (line.len > 0) {
        var aname: [env_name_max]u8 = undefined;
        var anlen: usize = 0;
        var ai: usize = 0;
        while (ai < line.len and line[ai] != ' ' and line[ai] != '\t' and anlen < env_name_max) : (ai += 1) {
            aname[anlen] = line[ai];
            anlen += 1;
        }
        if (anlen > 0) {
            if (env_get(aname[0..anlen])) |alias_val| {
                var sub: [lineedit.max_line]u8 = undefined;
                var sp: usize = 0;
                for (alias_val) |b| {
                    if (sp < sub.len) {
                        sub[sp] = b;
                        sp += 1;
                    }
                }
                if (sp < sub.len - 1) {
                    sub[sp] = ' ';
                    sp += 1;
                }
                while (ai < line.len and line[ai] == ' ') ai += 1;
                while (ai < line.len and sp < sub.len) : (ai += 1) {
                    sub[sp] = line[ai];
                    sp += 1;
                }
                // Re-run once through the expanded path (no alias-of-alias loops)
                shell_handle_expanded(mon, sub[0..sp]);
                return;
            }
        }
    }

    shell_handle_expanded(mon, line);
}

/// M19 P3 (issue #292): a chaining operator between two segments.
/// `;` always runs the next segment; `&&` runs it only when the last
/// actual status is success; `||` only on failure. `&&`/`||` have equal
/// precedence, left to right; a SKIPPED segment leaves the status
/// untouched, which yields the POSIX behavior for mixed chains
/// (`a && b || c` runs `c` exactly when everything so far failed).
pub const ChainOp = enum { seq, run_and, run_or };

/// M19 P3 (issue #292): bounded chains — at most 4 commands (3 operators).
const chain_max_cmds: usize = 4;

const ChainSplitResult = union(enum) {
    /// No top-level operator — a single command (the common case).
    none,
    /// More than chain_max_cmds segments — refused honestly, nothing runs.
    too_many,
    chain: struct {
        segs: [chain_max_cmds][]const u8,
        ops: [chain_max_cmds - 1]ChainOp,
        seg_count: usize,
        op_count: usize,
    },
};

/// M19 P3 (issue #292): split a line on `;`, `&&`, `||` OUTSIDE double
/// quotes (the same quote rule as pipe_split — a quote opens only where
/// the tokenizer would open one, so a quote byte mid-token is literal).
/// A lone `|` is NOT an operator here; pipes bind tighter and are handled
/// per-segment by shell_handle_expanded. Segments are trimmed; empty
/// segments are kept by the split and skipped at run time.
pub fn chain_split(line: []const u8) ChainSplitResult {
    var in_quote = false;
    var in_single = false;
    var esc = false; // M19 P5: a backslashed byte has no operator meaning
    var segs: [chain_max_cmds][]const u8 = undefined;
    var ops: [chain_max_cmds - 1]ChainOp = undefined;
    var seg_count: usize = 0;
    var op_count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (esc) {
            esc = false;
            continue;
        }
        if (line[i] == '\\') {
            esc = true;
            continue;
        }
        if (line[i] == '\'') {
            in_single = !in_single;
            continue;
        }
        if (line[i] == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (in_quote or in_single) continue;
        var op: ?ChainOp = null;
        var op_width: usize = 1;
        if (line[i] == '&' and i + 1 < line.len and line[i + 1] == '&') {
            op = .run_and;
            op_width = 2;
        } else if (line[i] == '|' and i + 1 < line.len and line[i + 1] == '|') {
            op = .run_or;
            op_width = 2;
        } else if (line[i] == ';') {
            op = .seq;
        }
        if (op) |o| {
            // This operator opens segment seg_count + 1; the bound caps
            // segments at chain_max_cmds, so operators at chain_max_cmds - 1.
            if (seg_count >= chain_max_cmds - 1) return .too_many;
            segs[seg_count] = trim_start(trim_end(line[start..i]));
            ops[op_count] = o;
            seg_count += 1;
            op_count += 1;
            start = i + op_width;
            i += op_width - 1; // the loop's +1 covers the rest of a two-char op
        }
    }
    segs[seg_count] = trim_start(trim_end(line[start..]));
    seg_count += 1;
    // No operator found — the ordinary single-command path, unchanged.
    if (op_count == 0) return .none;
    return .{ .chain = .{ .segs = segs, .ops = ops, .seg_count = seg_count, .op_count = op_count } };
}

/// M19 P3 (issue #292): evaluate a chain left to right. Each segment runs
/// through the full per-command pipeline (expansions → alias → builtins →
/// registry), so pipes, redirection, and `$?` compose within any segment
/// and expand at segment execution time. Short-circuit decisions read the
/// live status; a skipped segment changes nothing.
fn run_chain(mon: *monitor.Monitor, segs: []const []const u8, ops: []const ChainOp) void {
    var idx: usize = 0;
    while (idx < segs.len) : (idx += 1) {
        const should_run = if (idx == 0) true else switch (ops[idx - 1]) {
            .seq => true,
            .run_and => last_exit_ok,
            .run_or => !last_exit_ok,
        };
        if (!should_run) continue;
        if (segs[idx].len == 0) continue; // empty segment: no-op, status preserved
        expand_and_dispatch(mon, segs[idx]);
        if (script_stop) break; // M18 T16: `exit` stops the script mid-chain
    }
}

/// M19 P1 (issue #290): the split of a line at its first `|` outside
/// double quotes (matching the tokenizer's quote rule — a quote opens only
/// at the start of an argument, so a `"` mid-token is a literal byte).
const PipeSplit = struct { left: []const u8, right: []const u8 };

const PipeSplitResult = union(enum) {
    none,
    split: PipeSplit,
    multiple, // more than one `|` outside quotes — refused (single-pipe only)
};

pub fn pipe_split(line: []const u8) PipeSplitResult {
    var in_quote = false;
    var in_single = false;
    var esc = false; // M19 P5: a backslashed byte has no operator meaning
    var first: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (esc) {
            esc = false;
            continue;
        }
        if (line[i] == '\\') {
            esc = true;
            continue;
        }
        if (line[i] == '\'') {
            in_single = !in_single;
            continue;
        }
        if (line[i] == '"') in_quote = !in_quote;
        if (!in_single and !in_quote and line[i] == '|') {
            if (first == null) {
                first = i;
            } else {
                return .multiple;
            }
        }
    }
    const idx = first orelse return .none;
    return .{ .split = .{ .left = line[0..idx], .right = line[idx + 1 ..] } };
}

/// M19 P1 (issue #290): run `left | right`. Sequential model — the left
/// command runs to completion with its stdout captured into the pipe, then
/// the right command runs with its stdin fed from the pipe and its stdout
/// passing through to the real console (so right-side output still reaches
/// the scrollback wrapper). The console is swapped for each half and
/// restored after; the pipe is reset before the left command runs.
fn run_pipe(mon: *monitor.Monitor, left: []const u8, right: []const u8) void {
    pipe.reset();
    const saved = mon.console;
    // Left: stdout → pipe.
    mon.console = pipe.sink_console();
    shell_handle_expanded(mon, left);
    // Right: stdin ← pipe, stdout → real console.
    mon.console = pipe.source_console(saved);
    shell_handle_expanded(mon, right);
    mon.console = saved;
}

/// M19 P2 (issue #291): the kind of redirection found by `redirect_split`.
pub const RedirectOp = enum { stdout_overwrite, stdout_append, stdin_file };
const RedirectSplit = struct { left: []const u8, right: []const u8, op: RedirectOp };

/// M19 P2 (issue #291): look for `>`, `>>`, or `<` outside double quotes
/// on the line (after the first token — the command name). Returns the
/// split of the line into the left side (the command + its args) and the
/// right side (the filename), plus the operator kind. Returns null when
/// no redirect operator is found.
///
/// The operator is matched right-to-left so `>>` is preferred over `>`.
pub fn redirect_split(line: []const u8) ?RedirectSplit {
    // Scan for `>>`, then `>`, then `<` outside quoted regions.
    var in_quote = false;
    var in_single = false;
    var esc = false; // M19 P5: a backslashed byte has no operator meaning
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (esc) {
            esc = false;
            continue;
        }
        if (line[i] == '\\') {
            esc = true;
            continue;
        }
        if (line[i] == '\'') {
            in_single = !in_single;
            continue;
        }
        if (line[i] == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (in_single or in_quote) continue;
        if (line[i] == '>') {
            // Check for `>>`
            if (i + 1 < line.len and line[i + 1] == '>') {
                const left = trim_end(line[0..i]);
                const right = trim_start(line[i + 2 ..]);
                if (left.len > 0 and right.len > 0) {
                    return .{ .left = left, .right = right, .op = .stdout_append };
                }
                continue;
            }
            // Single `>`
            const left = trim_end(line[0..i]);
            const right = trim_start(line[i + 1 ..]);
            if (left.len > 0 and right.len > 0) {
                return .{ .left = left, .right = right, .op = .stdout_overwrite };
            }
            continue;
        }
        if (line[i] == '<') {
            const left = trim_end(line[0..i]);
            const right = trim_start(line[i + 1 ..]);
            if (left.len > 0 and right.len > 0) {
                return .{ .left = left, .right = right, .op = .stdin_file };
            }
            continue;
        }
    }
    return null;
}

/// Trim trailing whitespace.
fn trim_end(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[0..end];
}

/// Trim leading whitespace.
fn trim_start(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    return s[start..];
}

// ---------------------------------------------------------------------------
// M19 P6 (issue #295): globbing — `*`, `?`, `[abc]`, `[a-z]` expansion
// against the ESP window listing.
// ---------------------------------------------------------------------------

/// One `[...]` class against byte `c`. `pattern[p]` must be `'['`; on a
/// match returns the index just past the closing `']'`, else null. An
/// unclosed class never matches (the pattern then stays literal via the
/// no-match path). A `]` directly after `[` is a member, not the closer.
fn glob_class(pattern: []const u8, p: usize, c: u8) ?usize {
    var j = p + 1;
    var matched = false;
    var first = true;
    while (j < pattern.len and (pattern[j] != ']' or first)) {
        first = false;
        if (j + 2 < pattern.len and pattern[j + 1] == '-' and pattern[j + 2] != ']') {
            if (c >= pattern[j] and c <= pattern[j + 2]) matched = true;
            j += 3;
        } else {
            if (pattern[j] == c) matched = true;
            j += 1;
        }
    }
    if (j >= pattern.len or !matched) return null;
    return j + 1; // past ']'
}

/// fnmatch-style matcher: `*` any run (greedy with explicit backtrack
/// points — iterative, no recursion, no allocation), `?` one byte,
/// `[...]` classes per glob_class. Everything else is a literal byte.
pub fn glob_match(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star_p = p;
                    star_n = n;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    n += 1;
                    continue;
                },
                '[' => {
                    if (glob_class(pattern, p, name[n])) |np| {
                        p = np;
                        n += 1;
                        continue;
                    }
                },
                else => {
                    if (pattern[p] == name[n]) {
                        p += 1;
                        n += 1;
                        continue;
                    }
                },
            }
        }
        // Mismatch: resume inside the last `*`, one byte further.
        if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// M19 P6: rebuild argv for dispatch. Arguments flagged by the tokenizer
/// expand against the ESP window listing (bounded scope: the ESP root —
/// the same listing bare `ls` prints); everything else copies through.
/// No match → the literal pattern passes (nullglob-off). More than
/// glob_max_matches matches ACROSS the whole line → honest refusal, null,
/// nothing executes. Matches are byte-sorted (insertion sort).
fn glob_expand_argv(
    mon: *monitor.Monitor,
    argv: []const []const u8,
    wild: []const bool,
    out: [][]const u8,
) ?usize {
    var any_wild = false;
    for (wild) |w| {
        if (w) {
            any_wild = true;
            break;
        }
    }
    if (!any_wild) {
        for (argv, 0..) |arg, i| out[i] = arg;
        return argv.len;
    }

    // M34 HF6 (issue #740) / #965: globbing enumerates the HOST SHARE root.
    // Enumerate once into module-level BSS storage if any wildcard is present.
    const list_st = blk: {
        const taken = acquire_file_lock();
        defer release_file_lock(taken);
        break :blk virtio_file.list("", &glob_list_res);
    };
    if (list_st != virtio_file.st_ok) {
        for (argv, 0..) |arg, i| out[i] = arg;
        return argv.len;
    }

    var count: usize = 0;
    var total_matched: usize = 0;
    for (argv, wild) |arg, is_wild| {
        if (!is_wild) {
            out[count] = arg;
            count += 1;
            continue;
        }
        var m: usize = 0;
        for (glob_list_res.entries[0..glob_list_res.count]) |*e| {
            const ename = e.name[0..e.name_len];
            if (!glob_match(arg, ename)) continue;
            // Insertion sort by name (byte-wise ascending).
            var pos = m;
            while (pos > 0 and std.mem.lessThan(u8, ename, glob_match_storage[pos - 1])) : (pos -= 1) {
                glob_match_storage[pos] = glob_match_storage[pos - 1];
            }
            glob_match_storage[pos] = ename;
            m += 1;
            if (m >= glob_max_matches) break; // storage bound; sorted insert kept order
        }
        if (total_matched + m > glob_max_matches) {
            mon.console.print_line("glob: too many matches (max 64)");
            set_exit_ok(false);
            return null;
        }
        if (m == 0) {
            out[count] = arg; // no match: literal passthrough
            count += 1;
            continue;
        }
        for (glob_match_storage[0..m], 0..) |name, mi| {
            const dst = &glob_name_storage[total_matched + mi];
            @memcpy(dst[0..name.len], name);
            out[count] = dst[0..name.len];
            count += 1;
        }
        total_matched += m;
    }
    return count;
}

/// M19 P2 (issue #291): run `cmd > file` or `cmd >> file`. The command
/// runs with its stdout captured, then the captured content is written
/// to the file (overwrite) or appended to the existing content (append).
fn run_redirect_out(mon: *monitor.Monitor, left: []const u8, file: []const u8, op: RedirectOp) void {
    redirect.reset_capture();
    const saved = mon.console;
    // Command: stdout → capture buffer.
    mon.console = redirect.capture_console();
    shell_handle_expanded(mon, left);
    mon.console = saved;

    // Now write the captured output to the file.
    var content_to_write = redirect.captured();
    if (op == .stdout_append) {
        // Read existing file content, then append.
        var existing_buf: [4096]u8 = undefined;
        if (redirect.read_file_into(file, &existing_buf)) |existing| {
            // Build combined: existing + newline + captured
            var combined: [4096]u8 = undefined;
            var pos: usize = 0;
            const ex_take = @min(existing.len, 3968); // leave room for newline + capture
            @memcpy(combined[pos..][0..ex_take], existing[0..ex_take]);
            pos += ex_take;
            // If the capture has content, prepend a newline separator
            const cap = redirect.captured();
            if (cap.len > 0) {
                if (pos < combined.len) {
                    combined[pos] = '\n';
                    pos += 1;
                }
                const cap_take = @min(cap.len, combined.len - pos);
                @memcpy(combined[pos..][0..cap_take], cap[0..cap_take]);
                pos += cap_take;
            }
            content_to_write = combined[0..pos];
        }
    }

    if (redirect.write_captured_to_file(file, content_to_write)) |err| {
        mon.console.print_line(err);
    }
}

/// M19 P2 (issue #291): run `cmd < file`. The file is pre-loaded, then
/// the command runs with its stdin feeding from that content and stdout
/// passing through to the real console.
fn run_redirect_in(mon: *monitor.Monitor, left: []const u8, file: []const u8) void {
    var file_buf: [4096]u8 = undefined;
    const data = redirect.read_file_into(file, &file_buf) orelse {
        mon.console.puts("redirect: ");
        mon.console.puts(file);
        mon.console.print_line(": not found or unreadable");
        return;
    };

    const saved = mon.console;
    mon.console = redirect.feed_console(saved, data);
    shell_handle_expanded(mon, left);
    mon.console = saved;
}

/// M19 P4: find a function by name. Returns the table index or null.
pub fn func_find(name: []const u8) ?usize {
    var i: usize = 0;
    while (i < func_count) : (i += 1) {
        if (std.mem.eql(u8, func_table[i].name[0..func_table[i].name_len], name)) return i;
    }
    return null;
}

/// M19 P4: define a function from `NAME { cmd1; cmd2 }` text.
pub fn func_define(mon: *monitor.Monitor, text: []const u8) void {
    // Parse: name(a, b) { commands... }
    var i: usize = 0;
    while (i < text.len and text[i] != ' ' and text[i] != '{' and text[i] != '(') i += 1;
    const name = if (i > 0) text[0..i] else "";
    if (name.len == 0 or name.len > func_name_max) {
        mon.console.print_line("fn: invalid function name");
        return;
    }
    // Parse argument list: (a, b, c)
    var arg_names: [func_arg_max][func_arg_name_max]u8 = undefined;
    var arg_name_lens: [func_arg_max]usize = @as([func_arg_max]usize, @splat(@as(usize, 0)));
    var arg_count: usize = 0;
    if (i < text.len and text[i] == '(') {
        i += 1; // skip (
        while (i < text.len and text[i] != ')' and arg_count < func_arg_max) {
            // Skip whitespace/comma
            while (i < text.len and (text[i] == ' ' or text[i] == ',')) i += 1;
            const a_start = i;
            while (i < text.len and text[i] != ' ' and text[i] != ',' and text[i] != ')') i += 1;
            const aname = text[a_start..i];
            if (aname.len > 0) {
                const n = @min(aname.len, func_arg_name_max);
                @memcpy(arg_names[arg_count][0..n], aname[0..n]);
                arg_name_lens[arg_count] = n;
                arg_count += 1;
            }
        }
        if (i < text.len and text[i] == ')') i += 1;
    }
    // Find `{
    while (i < text.len and text[i] != '{') i += 1;
    var start = i + 1;
    while (start < text.len and text[start] == ' ') start += 1;
    // Find closing }
    var end: ?usize = null;
    i = text.len;
    while (i > start) {
        i -= 1;
        if (text[i] == '}') {
            end = i;
            break;
        }
    }
    const body = if (end) |e| text[start..e] else text[start..];

    // Parse body into commands separated by `;`
    var cmds: [func_cmds_per_func][func_cmd_max]u8 = undefined;
    var cmd_lens: [func_cmds_per_func]usize = @as([func_cmds_per_func]usize, @splat(@as(usize, 0)));
    var cmd_count: usize = 0;
    var bpos: usize = 0;
    while (bpos < body.len and cmd_count < func_cmds_per_func) : (cmd_count += 1) {
        // Skip leading whitespace
        while (bpos < body.len and (body[bpos] == ' ' or body[bpos] == '\t')) bpos += 1;
        // Find next `;` or end
        var cmd_end: usize = bpos;
        while (cmd_end < body.len and body[cmd_end] != ';') cmd_end += 1;
        const cmd = body[bpos..cmd_end];
        // Trim trailing whitespace
        var ct = cmd.len;
        while (ct > 0 and (cmd[ct - 1] == ' ' or cmd[ct - 1] == '\t')) ct -= 1;
        const trimmed = cmd[0..ct];
        const n = @min(trimmed.len, func_cmd_max);
        @memcpy(cmds[cmd_count][0..n], trimmed[0..n]);
        cmd_lens[cmd_count] = n;
        bpos = cmd_end + 1; // skip the semicolon
    }

    if (cmd_count == 0) {
        mon.console.print_line("fn: empty function body");
        return;
    }

    // Upsert: replace existing or append
    if (func_find(name)) |idx| {
        const f = &func_table[idx];
        f.arg_names = arg_names;
        f.arg_name_lens = arg_name_lens;
        f.arg_count = arg_count;
        f.body = cmds;
        f.body_lens = cmd_lens;
        f.body_count = cmd_count;
        mon.console.print_line("fn: ok (redefined)");
        return;
    }
    if (func_count >= func_max) {
        mon.console.print_line("fn: too many functions (max 8)");
        return;
    }
    const f = &func_table[func_count];
    @memcpy(f.name[0..name.len], name);
    f.name_len = name.len;
    f.arg_names = arg_names;
    f.arg_name_lens = arg_name_lens;
    f.arg_count = arg_count;
    f.body = cmds;
    f.body_lens = cmd_lens;
    f.body_count = cmd_count;
    func_count += 1;
    mon.console.print_line("fn: ok");
}

/// M19 P4+P8: call a function by name, with optional arguments.
fn func_call(mon: *monitor.Monitor, argv: []const []const u8) void {
    const idx = func_find(argv[0]) orelse return;
    const f = &func_table[idx];

    // P8: set positional $0 (function name) and $1..$N (caller args).
    env_set("0", f.name[0..f.name_len]);

    // $1..$N = caller arguments
    var ai: usize = 1;
    while (ai < argv.len and ai <= func_arg_max) : (ai += 1) {
        // Build positional name: "1", "2", ...
        var pos_name: [4]u8 = undefined;
        var pnl: usize = 0;
        const pn: usize = ai;
        if (pn >= 100) {
            pos_name[pnl] = @as(u8, @intCast('0' + (pn / 100) % 10));
            pnl += 1;
        }
        if (pn >= 10) {
            pos_name[pnl] = @as(u8, @intCast('0' + (pn / 10) % 10));
            pnl += 1;
        }
        pos_name[pnl] = @as(u8, @intCast('0' + pn % 10));
        pnl += 1;
        env_set(pos_name[0..pnl], argv[ai]);
    }

    // Also set named args ($name = caller value) if function declares them
    ai = 1;
    while (ai < argv.len and ai - 1 < f.arg_count) : (ai += 1) {
        const an = f.arg_names[ai - 1][0..f.arg_name_lens[ai - 1]];
        env_set(an, argv[ai]);
    }

    // Execute each command in the body sequentially.
    // P8: expand $VAR in body lines before execution (function bodies
    // are stored raw, so $name references expand at invocation time).
    var ci: usize = 0;
    while (ci < f.body_count) : (ci += 1) {
        var exp_buf: [func_cmd_max * 2]u8 = undefined;
        const cmd = env_expand(f.body[ci][0..f.body_lens[ci]], &exp_buf);
        shell_handle_expanded(mon, cmd);
    }
}

/// M19 P9 (issue #298): true while executing a command substitution's
/// inner command — guards against nesting (refused by the scanner) and
/// prevents cmd_subst from calling itself.
var subst_active: bool = false;

/// M19 P9 (issue #298): scan `raw` for `$(...)`.  If found, execute the
/// inner command with stdout captured, then substitute the captured output
/// into the line.  Returns the substituted line (may be the same as `raw`
/// if no substitution was found).
fn cmd_subst(mon: *monitor.Monitor, raw: []const u8, out: []u8) []const u8 {
    // Find first `$(`
    const dollar_lp = std.mem.indexOf(u8, raw, "$(") orelse return raw;
    const start = dollar_lp + 2;

    // Find matching `)` — reject nested `$(`
    var depth: usize = 1;
    var i: usize = start;
    while (i < raw.len and depth > 0) : (i += 1) {
        if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '(') {
            mon.console.print_line("cmdsubst: nested $(...) not supported");
            return raw;
        }
        if (raw[i] == '(') {
            depth += 1;
        } else if (raw[i] == ')') {
            depth -= 1;
        }
    }
    if (depth != 0) {
        mon.console.print_line("cmdsubst: unmatched $(");
        return raw;
    }
    const end = i - 1; // index of the closing `)`
    const inner_cmd = raw[start..end];
    // Trim whitespace
    var cs = inner_cmd;
    while (cs.len > 0 and (cs[0] == ' ' or cs[0] == '\t')) cs = cs[1..];
    var ce = cs.len;
    while (ce > 0 and (cs[ce - 1] == ' ' or cs[ce - 1] == '\t')) ce -= 1;
    const cmd = cs[0..ce];

    if (cmd.len == 0) return raw;

    // Capture the inner command's stdout.
    redirect.reset_capture();
    const saved = mon.console;
    mon.console = redirect.capture_console();
    subst_active = true;
    handle_line(mon, cmd);
    subst_active = false;
    mon.console = saved;

    const captured = redirect.captured();
    const cap_len = @min(captured.len, subst_max_output);

    // Build substituted line: prefix + captured output + suffix.
    // Trim trailing newlines from captured output (commands often end
    // with a newline, but we want the inline substitution to be clean).
    var cend = cap_len;
    while (cend > 0 and (captured[cend - 1] == '\n' or captured[cend - 1] == '\r')) cend -= 1;
    const trimmed = captured[0..cend];

    const prefix = raw[0..dollar_lp];
    const suffix = raw[end + 1 ..];

    // #1690: every copy is BOUNDED by out.len. subst_max_output equals
    // out.len (lineedit.max_line), so prefix + capture + suffix overflows
    // the buffer whenever the capture fills and the line carries any
    // prefix at all — observed as a safe-mode panic at index 261 of 256
    // from an 11-byte `clip $(help)`, and as an unchecked write past the
    // stack buffer in the ReleaseSmall image. Structural bytes win:
    // prefix and suffix (the command's own text around the substitution)
    // are laid down first, each clamped, and the captured output is
    // truncated to the room that is left — nothing is written out of
    // bounds and the tail of the line is never silently dropped (the old
    // suffix-only guard dropped it). A truncation is announced, in the
    // family of the cmdsubst refusals above.
    const plen = @min(prefix.len, out.len);
    const slen = @min(suffix.len, out.len - plen);
    const clen = @min(trimmed.len, out.len - plen - slen);
    if (clen < trimmed.len) {
        mon.console.print_line("cmdsubst: output truncated to fit the line buffer");
    }
    var op: usize = 0;
    if (plen > 0) {
        @memcpy(out[op..][0..plen], prefix[0..plen]);
        op += plen;
    }
    if (clen > 0) {
        @memcpy(out[op..][0..clen], trimmed[0..clen]);
        op += clen;
    }
    if (slen > 0) {
        @memcpy(out[op..][0..slen], suffix[0..slen]);
        op += slen;
    }
    return out[0..op];
}

/// M19 P10 (issue #299): arithmetic expansion — `$((expr))` evaluates
/// a 64-bit signed integer expression and substitutes the decimal result.
/// Supports +, -, *, /, %, parentheses, and unary minus. Recursive
/// descent handles precedence: () > unary - > * / % > + -.
const ArithToken = enum { num, plus, minus, star, slash, percent, lparen, rparen, eof };

const ArithLexer = struct {
    src: []const u8,
    pos: usize,
    peek_token: ArithToken,
    peek_val: i64,

    fn init(src: []const u8) ArithLexer {
        var l = ArithLexer{ .src = src, .pos = 0, .peek_token = .eof, .peek_val = 0 };
        l.advance();
        return l;
    }

    fn advance(self: *ArithLexer) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t'))
            self.pos += 1;
        if (self.pos >= self.src.len) {
            self.peek_token = .eof;
            return;
        }
        switch (self.src[self.pos]) {
            '+' => {
                self.peek_token = .plus;
                self.pos += 1;
            },
            '-' => {
                self.peek_token = .minus;
                self.pos += 1;
            },
            '*' => {
                self.peek_token = .star;
                self.pos += 1;
            },
            '/' => {
                self.peek_token = .slash;
                self.pos += 1;
            },
            '%' => {
                self.peek_token = .percent;
                self.pos += 1;
            },
            '(' => {
                self.peek_token = .lparen;
                self.pos += 1;
            },
            ')' => {
                self.peek_token = .rparen;
                self.pos += 1;
            },
            '0'...'9' => {
                var val: i64 = 0;
                while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                    val = val * 10 + @as(i64, self.src[self.pos] - '0');
                    self.pos += 1;
                }
                self.peek_token = .num;
                self.peek_val = val;
            },
            else => {
                self.peek_token = .eof;
            },
        }
    }

    fn next(self: *ArithLexer) ArithToken {
        const t = self.peek_token;
        self.advance();
        return t;
    }
};

fn arith_parse_expr(lexer: *ArithLexer) i64 {
    var left = arith_parse_term(lexer);
    while (true) {
        switch (lexer.peek_token) {
            .plus => {
                _ = lexer.next();
                left += arith_parse_term(lexer);
            },
            .minus => {
                _ = lexer.next();
                left -= arith_parse_term(lexer);
            },
            else => break,
        }
    }
    return left;
}

fn arith_parse_term(lexer: *ArithLexer) i64 {
    var left = arith_parse_factor(lexer);
    while (true) {
        switch (lexer.peek_token) {
            .star => {
                _ = lexer.next();
                left *= arith_parse_factor(lexer);
            },
            .slash => {
                _ = lexer.next();
                const r = arith_parse_factor(lexer);
                if (r != 0) left = @divTrunc(left, r) else left = 0;
            },
            .percent => {
                _ = lexer.next();
                const r = arith_parse_factor(lexer);
                if (r != 0) left = @mod(left, r) else left = 0;
            },
            else => break,
        }
    }
    return left;
}

fn arith_parse_factor(lexer: *ArithLexer) i64 {
    if (lexer.peek_token == .minus) {
        _ = lexer.next();
        return -arith_parse_factor(lexer);
    }
    if (lexer.peek_token == .plus) {
        _ = lexer.next();
        return arith_parse_factor(lexer);
    }
    if (lexer.peek_token == .num) {
        const val = lexer.peek_val;
        _ = lexer.next();
        return val;
    }
    if (lexer.peek_token == .lparen) {
        _ = lexer.next();
        const val = arith_parse_expr(lexer);
        _ = lexer.next(); // consume )
        return val;
    }
    return 0;
}

/// Scan `raw` for `$((expr))`, evaluate the expression, and splice the
/// decimal result back into the line.  Returns the substituted line.
fn arith_expand(raw: []const u8, out: []u8) []const u8 {
    const dollar_lparen = std.mem.indexOf(u8, raw, "$((") orelse return raw;
    const expr_start = dollar_lparen + 3;

    var depth: usize = 0;
    var i: usize = expr_start;
    while (i < raw.len - 1) : (i += 1) {
        if (raw[i] == '(') {
            depth += 1;
        } else if (raw[i] == ')') {
            if (depth == 0 and raw[i + 1] == ')') break;
            if (depth > 0) depth -= 1;
        }
    }
    if (i >= raw.len - 1) return raw;
    const expr_end = i;
    const suffix_start = i + 2;

    const expr = raw[expr_start..expr_end];
    if (expr.len == 0) return raw;

    var lexer = ArithLexer.init(expr);
    const result = arith_parse_expr(&lexer);

    var buf: [24]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{result}) catch return raw;

    const prefix = raw[0..dollar_lparen];
    const suffix = raw[suffix_start..];
    var op: usize = 0;
    if (prefix.len > 0) {
        @memcpy(out[op..][0..prefix.len], prefix);
        op += prefix.len;
    }
    if (str.len > 0) {
        @memcpy(out[op..][0..str.len], str);
        op += str.len;
    }
    if (suffix.len > 0 and op + suffix.len <= out.len) {
        @memcpy(out[op..][0..suffix.len], suffix);
        op += suffix.len;
    }
    return out[0..op];
}

/// M19 P11 (issue #300): find a whole-word keyword in a slice.
/// Returns the index of the first byte of the keyword if found as a
/// standalone word (preceded by start-or-whitespace, followed by
/// end-or-whitespace-or-`;`), or null otherwise.
fn find_if_keyword(text: []const u8, kw: []const u8) ?usize {
    var i: usize = 0;
    while (i + kw.len <= text.len) : (i += 1) {
        if (!std.mem.eql(u8, text[i..][0..kw.len], kw)) continue;
        // Check word boundary before.
        if (i > 0 and text[i - 1] != ' ' and text[i - 1] != '\t' and text[i - 1] != ';') continue;
        // Check word boundary after.
        const after = i + kw.len;
        if (after < text.len and text[after] != ' ' and text[after] != '\t' and text[after] != ';') continue;
        return i;
    }
    return null;
}

/// M19 P11 (issue #300): execute the body of an if/then/else block.
/// Splits `body` on `;` and executes each sub-command via
/// `shell_handle_expanded`. Each sub-command goes through the full
/// builtin/pipeline/redirect path.
fn run_if_body(mon: *monitor.Monitor, body: []const u8) void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        if (i == body.len or body[i] == ';') {
            if (i > start) {
                // Trim leading/trailing whitespace.
                var lo = start;
                while (lo < i and (body[lo] == ' ' or body[lo] == '\t')) lo += 1;
                var hi = i;
                while (hi > lo and (body[hi - 1] == ' ' or body[hi - 1] == '\t')) hi -= 1;
                if (hi > lo) shell_handle_expanded(mon, body[lo..hi]);
            }
            start = i + 1;
        }
    }
}

/// M19 P11 (issue #300): execute `if COND; then BODY; [else BODY]; fi`.
/// Parses the raw line (already expanded) to find the keywords, evaluates
/// the condition, then executes the appropriate body.
fn run_if(mon: *monitor.Monitor, line: []const u8) void {
    // Strip "if " prefix.
    const rest = if (line.len > 3 and line[3] == ' ') line[4..] else line[3..];

    // Find `then`.
    const then_pos = find_if_keyword(rest, "then") orelse {
        mon.console.print_line("if: missing 'then'");
        return;
    };
    // Trim trailing whitespace/semicolons from the condition.
    var cond_end = then_pos;
    while (cond_end > 0 and (rest[cond_end - 1] == ' ' or rest[cond_end - 1] == '\t' or rest[cond_end - 1] == ';')) cond_end -= 1;
    const condition = rest[0..cond_end];

    // Find `else` and `fi` after `then`.
    const after_then = rest[then_pos + 4 ..];
    // Skip past "then" to find the body start (after "then ").
    var body_start: usize = 0;
    while (body_start < after_then.len and after_then[body_start] != ' ' and after_then[body_start] != ';') body_start += 1;
    // Skip whitespace/semicolons.
    while (body_start < after_then.len and (after_then[body_start] == ' ' or after_then[body_start] == ';')) body_start += 1;
    const then_rest = after_then[body_start..];

    const else_pos = find_if_keyword(then_rest, "else");
    const fi_pos = find_if_keyword(then_rest, "fi") orelse {
        mon.console.print_line("if: missing 'fi'");
        return;
    };

    const then_body = if (else_pos) |ep|
        then_rest[0..ep]
    else
        then_rest[0..fi_pos];

    // Execute condition.
    shell_handle_expanded(mon, condition);

    if (last_exit_ok) {
        run_if_body(mon, then_body);
    } else if (else_pos) |ep| {
        // Skip past "else" to get the else body.
        var eb_start: usize = ep + 4;
        while (eb_start < then_rest.len and then_rest[eb_start] != ' ' and then_rest[eb_start] != ';') eb_start += 1;
        while (eb_start < then_rest.len and (then_rest[eb_start] == ' ' or then_rest[eb_start] == ';')) eb_start += 1;
        const else_body = then_rest[eb_start..fi_pos];
        run_if_body(mon, else_body);
    }
}

/// M19 P12 (issue #301): find a whole-word keyword in a slice (same as
/// find_if_keyword but named for loop context). Returns the index of
/// the first byte of the keyword if found as a standalone word.
fn find_loop_keyword(text: []const u8, kw: []const u8) ?usize {
    var i: usize = 0;
    while (i + kw.len <= text.len) : (i += 1) {
        if (!std.mem.eql(u8, text[i..][0..kw.len], kw)) continue;
        if (i > 0 and text[i - 1] != ' ' and text[i - 1] != '\t' and text[i - 1] != ';') continue;
        const after = i + kw.len;
        if (after < text.len and text[after] != ' ' and text[after] != '\t' and text[after] != ';') continue;
        return i;
    }
    return null;
}

/// M19 P12 (issue #301): execute the body of a for/while loop.
/// Splits `body` on `;` and executes each sub-command. Returns true
/// if break was triggered (loop should stop).
fn run_loop_body(mon: *monitor.Monitor, body: []const u8) bool {
    continue_flag = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        if (i == body.len or body[i] == ';') {
            if (i > start) {
                var lo = start;
                while (lo < i and (body[lo] == ' ' or body[lo] == '\t')) lo += 1;
                var hi = i;
                while (hi > lo and (body[hi - 1] == ' ' or body[hi - 1] == '\t')) hi -= 1;
                if (hi > lo) handle_line(mon, body[lo..hi]);
            }
            if (break_flag or continue_flag) return break_flag;
            start = i + 1;
        }
    }
    return false;
}

/// M19 P12 (issue #301): execute `for VAR in WORD1 WORD2 ...; do BODY; done`.
/// The words after `in` are the loop items. For each, set $VAR and
/// execute the body. $VAR is temporary (env_set/env_unset).
fn run_for(mon: *monitor.Monitor, line: []const u8) void {
    // Strip "for " prefix.
    const rest = if (line.len > 4 and line[4] == ' ') line[5..] else line[4..];

    // Find "in" keyword.
    const in_pos = find_loop_keyword(rest, "in") orelse {
        mon.console.print_line("for: usage: for VAR in WORD1 WORD2 ...; do CMD; done");
        return;
    };
    // Trim trailing whitespace from var_name.
    var vn_end = in_pos;
    while (vn_end > 0 and (rest[vn_end - 1] == ' ' or rest[vn_end - 1] == '\t')) vn_end -= 1;
    if (vn_end == 0) {
        mon.console.print_line("for: missing variable name");
        return;
    }
    const var_trimmed = rest[0..vn_end];

    // Find "do" keyword after "in".
    const after_in = rest[in_pos + 2 ..];
    const do_pos = find_loop_keyword(after_in, "do") orelse {
        mon.console.print_line("for: missing 'do'");
        return;
    };
    const words_str = after_in[0..do_pos];

    // Find "done" keyword after "do".
    const after_do = after_in[do_pos + 2 ..];
    var bd_start: usize = 0;
    while (bd_start < after_do.len and after_do[bd_start] != ' ' and after_do[bd_start] != ';') bd_start += 1;
    while (bd_start < after_do.len and (after_do[bd_start] == ' ' or after_do[bd_start] == ';')) bd_start += 1;
    const body_and_done = after_do[bd_start..];
    const done_pos = find_loop_keyword(body_and_done, "done") orelse {
        mon.console.print_line("for: missing 'done'");
        return;
    };
    const body = body_and_done[0..done_pos];

    // Parse words: split on whitespace and semicolons.
    var words: [16][]const u8 = undefined;
    var word_count: usize = 0;
    {
        var ws: usize = 0;
        while (ws < words_str.len and word_count < 16) : (ws += 1) {
            while (ws < words_str.len and (words_str[ws] == ' ' or words_str[ws] == '\t' or words_str[ws] == ';')) ws += 1;
            if (ws >= words_str.len) break;
            var we = ws;
            while (we < words_str.len and words_str[we] != ' ' and words_str[we] != '\t' and words_str[we] != ';') we += 1;
            words[word_count] = words_str[ws..we];
            word_count += 1;
            ws = we;
        }
    }

    // Execute the loop.
    loop_iter = 0;
    break_flag = false;
    while (loop_iter < word_count and loop_iter < loop_max_iter and !break_flag) : (loop_iter += 1) {
        env_set(var_trimmed, words[loop_iter]);
        if (run_loop_body(mon, body)) break;
    }
    // Unset the loop variable after the loop.
    _ = env_unset(var_trimmed);
}

/// M19 P12 (issue #301): execute `while CMD; do BODY; done`.
/// Run the condition command. If exit=0, run body, repeat.
/// If exit!=0, stop. `break` exits early, `continue` skips to next.
fn run_while(mon: *monitor.Monitor, line: []const u8) void {
    // Strip "while " prefix.
    const rest = if (line.len > 6 and line[6] == ' ') line[7..] else line[6..];

    // Find "do" keyword.
    const do_pos = find_loop_keyword(rest, "do") orelse {
        mon.console.print_line("while: missing 'do'");
        return;
    };
    const condition = rest[0..do_pos];

    // Find "done" after "do".
    const after_do = rest[do_pos + 2 ..];
    var bd_start: usize = 0;
    while (bd_start < after_do.len and after_do[bd_start] != ' ' and after_do[bd_start] != ';') bd_start += 1;
    while (bd_start < after_do.len and (after_do[bd_start] == ' ' or after_do[bd_start] == ';')) bd_start += 1;
    const body_and_done = after_do[bd_start..];
    const done_pos = find_loop_keyword(body_and_done, "done") orelse {
        mon.console.print_line("while: missing 'done'");
        return;
    };
    const body = body_and_done[0..done_pos];

    // Execute the loop.
    loop_iter = 0;
    break_flag = false;
    while (loop_iter < loop_max_iter and !break_flag) : (loop_iter += 1) {
        // Trim condition.
        var cond_end = condition.len;
        while (cond_end > 0 and (condition[cond_end - 1] == ' ' or condition[cond_end - 1] == '\t' or condition[cond_end - 1] == ';')) cond_end -= 1;
        if (cond_end == 0) break;
        shell_handle_expanded(mon, condition[0..cond_end]);
        if (!last_exit_ok) break;
        if (run_loop_body(mon, body)) break;
    }
}

fn shell_handle_expanded(mon: *monitor.Monitor, line: []const u8) void {
    // M19 P4 (issue #293): optimistic success default — builtins that
    // complete normally propagate 0 without every return site having to
    // record it; failure paths below overwrite explicitly.
    set_exit_ok(true);
    // M19 P2 (issue #291): the redirect operators — `>`, `>>`, `<` —
    // split before tokenizing so the command half goes through the
    // normal builtin/registry path and the file half is used by the
    // capture/feed adapters.
    if (redirect_split(line)) |rs| {
        switch (rs.op) {
            .stdout_overwrite, .stdout_append => run_redirect_out(mon, rs.left, rs.right, rs.op),
            .stdin_file => run_redirect_in(mon, rs.left, rs.right),
        }
        return;
    }
    // M19 P1 (issue #290): the pipe operator — split before tokenizing so
    // both halves go through the normal builtin/registry path.
    switch (pipe_split(line)) {
        .multiple => {
            set_exit_ok(false); // M19 P4: a refusal is a failed command
            mon.console.print_line("pipes: only one pipe per line (no chaining)");
            return;
        },
        .split => |sp| {
            run_pipe(mon, sp.left, sp.right);
            return;
        },
        .none => {},
    }
    // M18 T12–T15: intercept shell builtins before monitor.exec.
    // M19 P5: the tokenizer materializes joined/escaped tokens into the
    // BSS scratch (single-active-dispatch invariant, script_staging rule).
    const tokens = tokenizer.tokenize(line, &tokenize_scratch);
    if (tokens.too_many) {
        monitor.err_line(mon, monitor.too_many_arguments_message);
        return;
    }
    if (tokens.unbalanced_quote) {
        mon.console.print_line("unterminated quote: rest of line treated as literal");
    }
    // M19 P6 (issue #295): expand unquoted wildcard arguments against the
    // ESP listing before anything executes — builtins and registry
    // commands see already-expanded argv.
    var gargv = glob_argv_storage;
    const gcount = glob_expand_argv(mon, tokens.argv[0..tokens.count], tokens.arg_glob[0..tokens.count], &gargv) orelse return;
    const argv = gargv[0..gcount];
    if (argv.len == 0) {
        set_exit_code(exec_error_code(monitor.exec(mon, argv))); // M19 P4
        return;
    }
    // M19 P15: trace mode — print command before execution.
    if (trace_enabled) {
        mon.console.puts("+ ");
        mon.console.print_line(line);
    }
    // Builtin: export VAR[=VAL]
    if (std.mem.eql(u8, argv[0], "export")) {
        if (argv.len < 2) {
            // Print all env vars
            var ei: usize = 0;
            while (ei < env_count) : (ei += 1) {
                const e = &env_table[ei];
                mon.console.puts(e.name[0..e.name_len]);
                mon.console.puts("=");
                mon.console.print_line(e.val[0..e.val_len]);
            }
        } else {
            var eq: usize = 0;
            while (eq < argv[1].len and argv[1][eq] != '=') eq += 1;
            if (eq < argv[1].len) {
                env_set(argv[1][0..eq], argv[1][eq + 1 ..]);
            } else {
                env_set(argv[1], "");
            }
            save_env();
        }
        return;
    }
    // Builtin: set VAR=VAL (M19 P3)
    if (std.mem.eql(u8, argv[0], "set")) {
        // M19 P15: set -x / set +x for trace mode.
        if (argv.len == 2 and std.mem.eql(u8, argv[1], "-x")) {
            trace_enabled = true;
            mon.console.print_line("trace: on");
            return;
        }
        if (argv.len == 2 and std.mem.eql(u8, argv[1], "+x")) {
            trace_enabled = false;
            mon.console.print_line("trace: off");
            return;
        }
        if (argv.len < 2) {
            // Print all env vars (like export / env)
            var ei: usize = 0;
            while (ei < env_count) : (ei += 1) {
                const e = &env_table[ei];
                mon.console.puts(e.name[0..e.name_len]);
                mon.console.puts("=");
                mon.console.print_line(e.val[0..e.val_len]);
            }
            // Also show trace status.
            mon.console.puts("trace: ");
            mon.console.print_line(if (trace_enabled) "on" else "off");
        } else {
            var eq: usize = 0;
            while (eq < argv[1].len and argv[1][eq] != '=') eq += 1;
            if (eq < argv[1].len) {
                env_set(argv[1][0..eq], argv[1][eq + 1 ..]);
            } else {
                env_set(argv[1], "");
            }
            save_env();
        }
        return;
    }
    // Builtin: unset VAR (M19 P3)
    if (std.mem.eql(u8, argv[0], "unset")) {
        if (argv.len < 2) {
            mon.console.print_line("unset: usage: unset VAR");
        } else {
            if (env_unset(argv[1])) {
                save_env();
            }
        }
        return;
    }
    // Builtin: env / printenv (M19 P3 + M22 D7, issue #330)
    if (std.mem.eql(u8, argv[0], "env") or std.mem.eql(u8, argv[0], "printenv")) {
        var ei: usize = 0;
        while (ei < env_count) : (ei += 1) {
            const e = &env_table[ei];
            mon.console.puts(e.name[0..e.name_len]);
            mon.console.puts("=");
            mon.console.print_line(e.val[0..e.val_len]);
        }
        return;
    }
    // Builtin: alias NAME=VALUE [MORE...]
    if (std.mem.eql(u8, argv[0], "alias")) {
        if (argv.len < 2) {
            mon.console.print_line("alias: usage: alias NAME=VALUE [MORE...]");
        } else {
            var eq: usize = 0;
            while (eq < argv[1].len and argv[1][eq] != '=') eq += 1;
            if (eq > 0 and eq < argv[1].len) {
                // Build value: argv[1][eq+1..] + remaining args joined by space
                var valbuf: [env_val_max]u8 = undefined;
                var vp: usize = 0;
                for (argv[1][eq + 1 ..]) |b| {
                    if (vp < valbuf.len) {
                        valbuf[vp] = b;
                        vp += 1;
                    }
                }
                var ai: usize = 2;
                while (ai < argv.len) : (ai += 1) {
                    if (vp < valbuf.len) {
                        valbuf[vp] = ' ';
                        vp += 1;
                    }
                    for (argv[ai]) |b| {
                        if (vp < valbuf.len) {
                            valbuf[vp] = b;
                            vp += 1;
                        }
                    }
                }
                env_set(argv[1][0..eq], valbuf[0..vp]);
                mon.console.print_line("alias: ok");
            } else {
                mon.console.print_line("alias: usage: alias NAME=VALUE [MORE...]");
            }
        }
        return;
    }
    // Builtin: unalias NAME
    if (std.mem.eql(u8, argv[0], "unalias")) {
        mon.console.print_line("unalias: not implemented (aliases are just env vars)");
        return;
    }
    // M18 T16 (issue #419): 'exit' inside a running script stops it
    // early. Outside a script it is not a command — it falls through to
    // the registry's unknown-command shape below.
    if (std.mem.eql(u8, argv[0], "exit") and script_active) {
        script_stop = true;
        return;
    }
    // Builtin: sh SCRIPT (M18 T16, issue #419) — run a script file of
    // shell commands line by line. Intercepted here (like export/alias)
    // because execution must go through handle_line; the monitor registry
    // entry exists for help/usage/completion discovery.
    if (std.mem.eql(u8, argv[0], "sh")) {
        if (argv.len != 2) {
            mon.console.print_line("sh: usage: sh <script>");
            return;
        }
        run_script(mon, argv[1]);
        return;
    }
    // Builtin: prompt NEW_PROMPT (M18 T15)
    if (std.mem.eql(u8, argv[0], "prompt")) {
        if (argv.len < 2) {
            mon.console.print_line("prompt: usage: prompt NEW_PROMPT");
        } else {
            _ = settings.set("prompt", argv[1]);
            mon.console.print_line("prompt: ok");
        }
        return;
    }
    // M19 P1 (issue #290): `type` — echo stdin (the pipe source) to
    // stdout. With no pipe the console has no input, so it prints nothing;
    // as the RIGHT half of `a | type` it echoes the left command's output.
    if (std.mem.eql(u8, argv[0], "type")) {
        while (mon.console.readByte()) |b| {
            mon.console.putc(b);
        }
        return;
    }
    // M19 P11: `true` — set exit status to success.
    if (std.mem.eql(u8, argv[0], "true")) {
        set_exit_ok(true);
        return;
    }
    // M19 P11: `false` — set exit status to failure.
    if (std.mem.eql(u8, argv[0], "false")) {
        set_exit_ok(false);
        return;
    }
    // M19 P7 (issue #296): `jobs` — list background jobs with LIVE state
    // read from the process registry.
    if (std.mem.eql(u8, argv[0], "jobs")) {
        var any = false;
        for (&bg_jobs, 0..) |*job, i| {
            const jpid = job.pid orelse continue;
            any = true;
            const inf = process.info(jpid);
            const st = if (inf) |x| x.state else .free;
            const running = st != .exited and st != .free;
            // #2649: ONE write per row — the jobs gate whole-line greps.
            const name = job.name[0..job.name_len];
            if (running) {
                mon.console.linef("[{d}] Running: {s}\n", .{ i + 1, name });
            } else if (inf != null and inf.?.state == .exited) {
                mon.console.linef("[{d}] Done: {s} (exit={d})\n", .{ i + 1, name, inf.?.exit_status });
            } else {
                mon.console.linef("[{d}] Done: {s} (gone)\n", .{ i + 1, name });
            }
        }
        if (!any) mon.console.print_line("jobs: no background jobs");
        return;
    }
    // M19 P7 (issue #296): `fg [N]` — wait/report a background job.
    if (std.mem.eql(u8, argv[0], "fg")) {
        fg_run(mon, argv);
        return;
    }
    // M19 P11: `if COND; then BODY; [else BODY]; fi`.
    if (std.mem.eql(u8, argv[0], "if")) {
        run_if(mon, line);
        return;
    }
    // M19 P12: `for VAR in WORD1 WORD2 ...; do BODY; done`.
    if (std.mem.eql(u8, argv[0], "for")) {
        run_for(mon, line);
        return;
    }
    // M19 P12: `while CMD; do BODY; done`.
    if (std.mem.eql(u8, argv[0], "while")) {
        run_while(mon, line);
        return;
    }
    // M19 P12: `break` — exit the innermost loop.
    if (std.mem.eql(u8, argv[0], "break")) {
        break_flag = true;
        return;
    }
    // M19 P12: `continue` — skip to next iteration of the innermost loop.
    if (std.mem.eql(u8, argv[0], "continue")) {
        continue_flag = true;
        return;
    }
    // Builtin: fn (M19 P4) — list, define, delete shell functions.
    if (std.mem.eql(u8, argv[0], "fn")) {
        if (argv.len == 1) {
            // Bare `fn` lists all functions.
            if (func_count == 0) {
                mon.console.print_line("fn: no functions defined");
            } else {
                var fi: usize = 0;
                while (fi < func_count) : (fi += 1) {
                    const f = &func_table[fi];
                    mon.console.puts(f.name[0..f.name_len]);
                    mon.console.puts("(");
                    var ai: usize = 0;
                    while (ai < f.arg_count) : (ai += 1) {
                        if (ai > 0) mon.console.puts(", ");
                        mon.console.puts(f.arg_names[ai][0..f.arg_name_lens[ai]]);
                    }
                    mon.console.puts(") { ");
                    var ci: usize = 0;
                    while (ci < f.body_count) : (ci += 1) {
                        if (ci > 0) mon.console.puts("; ");
                        mon.console.puts(f.body[ci][0..f.body_lens[ci]]);
                    }
                    mon.console.print_line(" }");
                }
            }
        } else if (std.mem.eql(u8, argv[1], "-d")) {
            // fn -d NAME: delete a function.
            if (argv.len < 3) {
                mon.console.print_line("fn: usage: fn -d NAME");
            } else {
                const found = func_find(argv[2]);
                if (found) |idx| {
                    var j = idx;
                    while (j + 1 < func_count) : (j += 1) func_table[j] = func_table[j + 1];
                    func_count -= 1;
                } else {
                    mon.console.puts("fn: ");
                    mon.console.puts(argv[2]);
                    mon.console.print_line(": no such function");
                }
            }
        } else if (std.mem.eql(u8, argv[1], "-h")) {
            mon.console.print_line("fn: usage: fn NAME(a, b) { cmd1; cmd2 }");
            mon.console.print_line("fn:        fn              list all functions");
            mon.console.print_line("fn:        fn -d NAME       delete a function");
        } else {
            // fn NAME { cmd1; cmd2 } — define a function.
            // Rebuild the original line to parse `{ cmd1; cmd2 }`.
            var raw: [lineedit.max_line]u8 = undefined;
            var rp: usize = 0;
            var ai: usize = 1;
            while (ai < argv.len) : (ai += 1) {
                if (ai > 1 and rp < raw.len) {
                    raw[rp] = ' ';
                    rp += 1;
                }
                for (argv[ai]) |b| {
                    if (rp < raw.len) {
                        raw[rp] = b;
                        rp += 1;
                    }
                }
            }
            func_define(mon, raw[0..rp]);
        }
        return;
    }
    // M19 P4: call a function by name (if a function matches the command verb).
    if (func_find(argv[0])) |_| {
        func_call(mon, argv);
        return;
    }
    // M19 P4 (issue #293): fall-through registry dispatch records the
    // conventional numeric status (0 / 127 unknown / 2 usage / 1 failure).
    // M19 P7 (issue #296): when a trailing `&` asked for the background,
    // a launch that produced a NEW pid becomes a tracked job; anything
    // else consumed the flag without one.
    const pid_before = exec_mod.last_exec_pid();
    if (std.mem.eql(u8, argv[0], "exec")) arm_exec_envp();
    const exec_err = monitor.exec(mon, argv);
    set_exit_code(exec_error_code(exec_err));
    if (bg_pending) {
        const pid_after = exec_mod.last_exec_pid();
        if (exec_err == .none and pid_after != null and pid_after.? != pid_before) {
            const pinfo = process.info(pid_after.?);
            const pname: []const u8 = if (pinfo) |pi| pi.name else "job";
            if (bg_job_add(pid_after.?, pname)) {
                for (&bg_jobs, 0..) |*job, i| {
                    if (job.pid == null or job.pid.? != pid_after.?) continue;
                    // #2649: ONE write per row — the jobs gate greps it whole-line.
                    mon.console.linef("[{d}] running: {s}\n", .{ i + 1, job.name[0..job.name_len] });
                    break;
                }
            } else {
                mon.console.print_line("jobs: too many background jobs (max 4)");
                set_exit_ok(false);
            }
        }
    }
}

/// M19 P7 (issue #296): `fg [N]` — report a finished job (propagating its
/// REAL registry exit status into `$?` via P4), or bounded-wait ~5 timer
/// ticks (1 Hz cadence) and honestly report `still running` on timeout,
/// leaving it backgrounded. No argument targets the most recent job.
const fg_wait_ticks: u64 = 5;

fn fg_parse_job_number(text: []const u8) ?usize {
    if (text.len == 0 or text.len > 2) return null;
    var n: usize = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n < 1 or n > bg_job_max) return null;
    return n;
}

fn fg_report_done(mon: *monitor.Monitor, n: usize, name: []const u8, inf: ?process.ProcessInfo) void {
    // #2649: ONE write per marker line — the jobs gate greps it whole-line.
    if (inf) |pi| {
        if (pi.state == .exited) {
            mon.console.linef("[{d}] Done: {s} (exit={d})\n", .{ n, pi.name, pi.exit_status });
        } else {
            mon.console.linef("[{d}] Done: {s} (gone)\n", .{ n, pi.name });
        }
        // The child's own status becomes fg's status ($? sees it next).
        if (pi.state == .exited) set_exit_code(@intCast(@min(pi.exit_status, 255)));
    } else {
        mon.console.linef("[{d}] Done: {s} (gone)\n", .{ n, name[0..name.len] });
    }
    bg_job_free(n);
}

fn fg_run(mon: *monitor.Monitor, argv: []const []const u8) void {
    const n: usize = if (argv.len >= 2) blk: {
        break :blk fg_parse_job_number(argv[1]) orelse {
            mon.console.print_line("fg: usage: fg [N] (N is a background job number)");
            set_exit_ok(false);
            return;
        };
    } else bg_job_latest() orelse {
        mon.console.print_line("fg: no background jobs");
        set_exit_ok(false);
        return;
    };
    const job = &bg_jobs[n - 1];
    const jpid = job.pid orelse {
        mon.console.linef("fg: job {d} already done\n", .{n});
        set_exit_ok(false);
        return;
    };
    // Bounded wait while the child is live. WFE parks until the next IRQ —
    // the 1 Hz comparator and every scheduler tick both wake it, so the
    // child progresses while we wait. Host tests skip the spin entirely:
    // this repo's host IS aarch64, so is_test (not the arch) discriminates.
    if (!comptime builtin.is_test and builtin.cpu.arch == .aarch64) {
        const start = timer.ticks;
        while (true) {
            const winfo = process.info(jpid);
            const wst = if (winfo) |x| x.state else .free;
            if (wst == .exited or wst == .free) break;
            if (timer.ticks -% start >= fg_wait_ticks) break;
            asm volatile ("wfe");
        }
    }
    const inf = process.info(jpid);
    const st = if (inf) |x| x.state else .free;
    if (st == .exited or st == .free) {
        fg_report_done(mon, n, job.name[0..job.name_len], inf);
    } else {
        mon.console.linef("fg: job {d} still running\n", .{n});
        set_exit_ok(false);
    }
}

/// The kernel's ONE shell instance lives in BSS, not on the kernel stack:
/// the LineEditor's bounded history ring (hist_capacity × max_line bytes,
/// ADR 0008 D2) would crowd the 16 KiB kernel stack (ADR 0004 D5) once
/// kernel_main's boot frame is also live — observed as silently dropped
/// keyboard input when the shell was stack-allocated (milestone eight card
/// U2, claim 1809). Host tests still build their own stack `Shell` values;
/// only the kernel seam touches this storage.
var boot_shell_storage: Shell = undefined;

/// Issue #814 (the #803/#810 stack-overflow family): the shell's RX path
/// must NOT run on the 16 KiB handoff boot stack (ADR 0004 D5). Measured
/// in the disassembly (2026-09-02, claim 8554): even the SETUP-ONLY path
/// — Shell.init's by-value return staging inlined at sp+0x3c40, rc_buf,
/// and the restore/dispatch locals — is an unconditional prologue
/// `sub sp, #0x3000 + #0xfb0` (+ the callee-save stp) = ~0x4010, the full
/// 16 KiB stack before kernel_main's live frame is even counted. The
/// pre-fix merged frame (setup + loop inlined) measured 0x4750 = 18,256
/// bytes, whose bottom and every IRQ frame pushed while parked land in
/// the loader-data pocket BELOW the stack (handoff record / early-boot
/// structures), silently corrupting state; deeper dips fault (issue
/// #814's elr 0x8d44/0x8f54 corrupted-callee-saved class, observed in the
/// verify-live-zc plain-exec boots ~50% of the time).
///
/// The fix runs the WHOLE RX path — init, setup, .virelairc AND the park
/// loop — on a dedicated static task stack, the worker/idle/user standard
/// ("one task, one stack" discipline, as `worker_stack`/`idle_stack`). 64
/// KiB, not the 32 KiB task standard: LLVM keeps the deepest
/// command-dispatch frames (~0x4000 each) as separate functions that NEST
/// under park_body's merged frame rather than inlining them, and IRQ
/// frames land on the task stack too; ~40 KiB worst measured depth fits
/// with margin. BSS cost (+64 KiB against ~510 KiB headroom) is inside
/// the verify-bss-budget allowance. Only the no-RX path (banner + prompt,
/// ~0x100 of locals) still runs on the boot stack.
var park_stack: [64 * 1024]u8 align(16) = undefined;

// ---------------------------------------------------------------------------
// M45 SH8 (#1084, ADR 0021 D5): the boot login seam. When `settings shell=sh`
// the monitor hands the raw console to the login shell at boot: it execs it
// (which opens /dev/tty and attaches the serial front-end) and stops reading
// the console itself, so the terminal pump owns the RX. The default `monitor`
// is byte-identical. If the shell exits/detaches, the monitor resumes.
//
// M68b (#1450): the seat moved from SH.BIN to the Go shell, so the image name
// and the argument that selects its serial front-end live in one pair here.
// The settings VALUE stays `sh` — it names the shell seat, not the binary, and
// changing it would be a SETTINGS.TXT schema change for every persisted
// share.
// ---------------------------------------------------------------------------
const login_shell_image = "GOSH.ELF";
const login_shell_arg = "serial";

var login_relinquished = false;
var login_was_attached = false;
/// M49 SD1 (#1128): the login shell's pid, so the monitor can reclaim the
/// console if it dies before ever attaching serial.
var login_pid: ?usize = null;

/// M49 SD1 (#1128): the ownerless-console decision, split pure for host
/// tests. The monitor resumes reading the console when the login shell has
/// detached after having attached (`was_attached`), or when its process is
/// gone without having attached at all (the fallback — otherwise the
/// console has no reader). While attached, or while a not-yet-attached
/// login shell is still alive, the monitor stays off the RX.
pub fn login_should_resume(attached_now: bool, was_attached: bool, owner_alive: bool) bool {
    if (attached_now) return false;
    if (was_attached) return true;
    return !owner_alive;
}

/// True when `pid` still names a live login shell in the process registry.
/// The name check guards against slot reuse by an unrelated program while the
/// console is relinquished.
fn login_owner_alive(pid: usize) bool {
    const info = process.info(pid) orelse return false;
    if (info.state == .exited) return false;
    return std.mem.eql(u8, info.name, login_shell_image);
}

/// The pending boot login. Called once, after `.virelairc`, before the loop.
fn login_handoff(mon: *monitor.Monitor) void {
    if (!settings.login_shell_is_sh()) return;
    // The args array is built at runtime rather than passed as an anonymous
    // comptime literal. Observed on VZ: with `&[_][]const u8{login_shell_arg}`
    // the pack put six bytes into argv slot 1 that appear nowhere in
    // KERNEL.BIN (stable across the pack, the exec, and the guest's own read),
    // so GOSH never saw `serial` and fell through to its window path. This
    // form packs `serial` correctly — the same shape every other caller uses,
    // since their args come from a parsed line. Follow-up owed on #1450.
    var login_args: [1][]const u8 = undefined;
    login_args[0] = login_shell_arg;
    switch (exec_mod.exec_file(login_shell_image, &login_args)) {
        .ok => {
            login_relinquished = true;
            login_was_attached = false;
            login_pid = exec_mod.last_exec_pid();
            mon.console.puts("login: shell=sh -> GOSH.ELF serial\n");
        },
        else => {
            // Honest fallback: the share/image is unavailable — keep the
            // monitor rather than leaving the console ownerless.
            mon.console.puts("login: shell=sh but GOSH.ELF unavailable; staying in the monitor\n");
        },
    }
}

/// True while the monitor must not read the console (the login shell owns
/// it). Resumes the monitor once the login shell has detached, or when it
/// died before attaching and would otherwise leave the console ownerless.
fn login_console_relinquished(mon: *monitor.Monitor) bool {
    if (!login_relinquished) return false;
    const attached_now = terminal.attachedSerial() != null;
    if (attached_now) {
        login_was_attached = true;
        return true;
    }
    const alive = if (login_pid) |p| login_owner_alive(p) else false;
    if (login_should_resume(false, login_was_attached, alive)) {
        if (!login_was_attached) {
            mon.console.puts("login: shell died before attaching; monitor resumed\n");
        }
        login_relinquished = false;
        login_was_attached = false;
        login_pid = null;
    }
    return login_relinquished;
}

/// Only the idle report dispatch uses this adapter. Scheduler reports mix
/// routine, single-write records with fault/exit/audit evidence, so unknown
/// writes pass through there. Commands, jobs and exceptions never use it.
const IdleReportSink = struct {
    output: console.Console,
    scheduler_only: bool = false,

    // ADR 0005: construct function-pointer tables at runtime in BSS, not
    // const data (whose absolute pointers do not follow the kernel load).
    var vtable: console.Console.VTable = undefined;
    var vtable_ready = false;

    fn console_handle(self: *IdleReportSink) console.Console {
        if (!vtable_ready) {
            vtable = .{ .write = write, .flush = flush, .readByte = readByte };
            vtable_ready = true;
        }
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const self: *IdleReportSink = @ptrCast(@alignCast(ctx));
        if (!self.scheduler_only or routine_scheduler_write(bytes)) return;
        // Console.write already ran the recorder hook on this sink. Forward
        // the evidence bytes without invoking that hook a second time.
        self.output.vtable.write(self.output.ctx, bytes);
    }

    fn flush(ctx: *anyopaque) void {
        const self: *IdleReportSink = @ptrCast(@alignCast(ctx));
        if (self.scheduler_only) self.output.flush();
    }

    fn readByte(_: *anyopaque) ?u8 {
        return null;
    }
};

fn decimal_report_tail(bytes: []const u8, separator: []const u8, suffix: []const u8) bool {
    if (!std.mem.endsWith(u8, bytes, suffix)) return false;
    const at = std.mem.lastIndexOf(u8, bytes, separator) orelse return false;
    const digits = bytes[at + separator.len .. bytes.len - suffix.len];
    if (digits.len == 0) return false;
    for (digits) |b| if (b < '0' or b > '9') return false;
    return true;
}

fn routine_scheduler_write(bytes: []const u8) bool {
    // These producers format a complete record in one write. In particular,
    // do not discard the fragmented fault symbol note or audit error fields,
    // nor task/process exit and reap receipts.
    if (std.mem.startsWith(u8, bytes, "smp: secondary runs=") or
        std.mem.startsWith(u8, bytes, "smp: steal runs=")) return true;
    if (!std.mem.startsWith(u8, bytes, "tasks ")) return false;
    return decimal_report_tail(bytes, " advances=", "\n") or
        decimal_report_tail(bytes, " sleeping ", " ticks\n");
}

/// M87c: discard routine writes, not calls. Drain pending reports and advance
/// sampling even while serial is owned, so handback has no deferred burst.
/// The actual terminal registry, not the login setting, selects the sink.
pub fn idle_reports(output: console.Console, counter: u64, freq: u64) void {
    var quiet = IdleReportSink{ .output = output };
    var scheduler_sink = IdleReportSink{ .output = output, .scheduler_only = true };
    const owned = terminal.attachedSerial() != null;
    var routine_con = if (owned) quiet.console_handle() else output;
    var scheduler_con = if (owned) scheduler_sink.console_handle() else output;
    timer.maybe_heartbeat(&routine_con);
    scheduler.maybe_report(&scheduler_con);
    userspace.maybe_report(&routine_con);
    forensics.sample(routine_con, counter, freq);
}

/// Park-path body: the ENTIRE RX-wired shell path — init, history/env/
/// window restore, .virelairc, then the interactive loop that never
/// returns. Runs on park_stack: `boot_and_park` (aarch64) SP-switches to
/// park_stack and `bl`s this AAPCS64 body; host builds call it directly
/// (the comptime aarch64 branch is elided). Only `boot_and_park` reaches
/// it — nothing else in the kernel touches the shell seam.
fn park_body(mon: *monitor.Monitor) callconv(.c) void {
    const shell: *Shell = &boot_shell_storage;
    shell.* = Shell.init(mon.console, mon.state, mon.machine);
    shell.boot();
    shell.color_enabled = settings.get_color();
    load_history(&shell.editor);
    load_env(); // M19 P3: restore persistent environment
    // M21 W11: restore window state from previous session.
    restore_windows();

    // M18 T14: run startup file (.virelairc) if present on the host
    // share (HF6: the ESP window is gone).
    var rc_buf: [2048]u8 = undefined;
    const rc_len_opt = blk: {
        if (trust.check(trust.kernel_actor(), .host, ".virelairc", .read) != .allow) break :blk null;
        const taken = acquire_file_lock();
        defer release_file_lock(taken);
        break :blk virtio_file.read_whole(".virelairc", &rc_buf);
    };
    if (rc_len_opt) |rc_len| {
        const rc = rc_buf[0..rc_len];
        var start: usize = 0;
        var i: usize = 0;
        while (i < rc.len) : (i += 1) {
            if (rc[i] == '\n' or rc[i] == '\r') {
                if (i > start) handle_line(mon, rc[start..i]);
                start = i + 1;
                if (rc[i] == '\r' and i + 1 < rc.len and rc[i + 1] == '\n') i += 1;
            }
        }
        if (start < rc.len) handle_line(mon, rc[start..rc.len]);
    }
    // M45 SH8: hand the console to the login shell when `settings shell=sh`.
    login_handoff(mon);
    while (true) {
        // While the login shell owns the serial console, the monitor must
        // NOT read it (the terminal pump feeds the shell's /dev/tty instead).
        if (login_console_relinquished(mon) or shell.poll() == .idle) {
            // Claim 9187: the timer is serviced only through the IRQ path.
            // Claim 7948's main-loop comparator poll raced real delivery
            // after the GICR frame fix, double-consuming some periods.
            // Output remains here because the polled virtio TX path is not
            // reentrancy-safe in IRQ context. Claim 5275: the worker task's
            // progress report prints the same way (the worker never touches
            // the console itself).
            idle_reports(mon.console, timer.cntpct(), timer.freq);
            // M19 P7 (issue #296): reap finished background jobs — the
            // `[N] Done:` line prints from the same idle path as every
            // other asynchronous report above.
            bg_reap(mon);
            // Claim 6076 (card N2): the polled RX drain — the net device's
            // used-buffer IRQ is not yet observed on this platform, so the
            // shell idle loop is the drain point (the card-3d shell-idle-
            // drain pattern). Idempotent; a no-op when the transport is
            // unarmed or the buffer is empty.
            // Card N9 (claim 9489): stamp the DHCP lease clock from the 1
            // Hz generic timer before the drain — a renewal ACK processed
            // below restarts the lease from the CURRENT instant (honest
            // wall-clock seconds, the same clock `net dhcp` uses).
            // Claim 9498 follow-on: the polled drain + lease engine below
            // mutate virtio_net's shared transport state, which net-domain
            // syscalls on other cores hold the NET lock for — bracket the
            // whole drain (spinning is safe: holders run IRQ-masked to
            // completion, and no parked task holds a domain lock).
            svclock.net.acquire();
            virtio_net.dhcp.now_ticks = timer.ticks;
            // Card N10 (claim 7026): stamp the TCP connect clock the same
            // way — a SYN-ACK processed below starts the connection from
            // the CURRENT instant (the bounded connect timeout is honest
            // wall-clock seconds).
            virtio_net.tcp.now_ticks = timer.ticks;
            virtio_net.net_rx_drain();
            virtio_net.net_socket_poll();
            // M117b (#2474, ADR 0057 D4/D5): stamp the NDP clock and drive
            // the bounded RS train + one-probe DAD on the same polled-
            // drain time engine; the promote/conflict transitions print
            // (the net_dhcp_autonomous shape).
            virtio_net.ndp.now_ticks = timer.ticks;
            monitor.net_ndp_autonomous(mon);
            // Issue #2436: conn-death tombstones + counter transitions —
            // captured under the bracket, printed after release (the
            // retransmit-print lock order precedent below).
            var diag_tombs: [4]virtio_net.ConnTomb = undefined;
            var diag_ntombs: usize = 0;
            while (virtio_net.net_diag_tomb()) |t| {
                if (diag_ntombs < diag_tombs.len) {
                    diag_tombs[diag_ntombs] = t;
                    diag_ntombs += 1;
                }
            }
            const diag_diff = virtio_net.net_diag_counters();
            // Issue #119 (audit follow-up 3): the autonomous DHCP lease
            // lifecycle — advance T1/T2/expiry from the idle loop (the
            // polled-drain time engine, the same seam as tcp.poll_rto)
            // instead of requiring a human to type `net dhcp`. AFTER the
            // drain: a renewal ACK just processed restarts the lease
            // clock first. Prints the SAME transition lines the command
            // prints; silent otherwise (and on the no-ARP renew path —
            // the client stays BOUND per RFC 2131 §4.4.5; `net dhcp`
            // surfaces the diagnostic). The re-DISCOVER after expiry
            // stays command-triggered.
            monitor.net_dhcp_autonomous(mon);
            svclock.net.release();
            for (diag_tombs[0..diag_ntombs]) |t| {
                var tbuf: [256]u8 = undefined;
                const tline = std.fmt.bufPrint(&tbuf, "net: conn-diag slot={d} lport={d} rport={d} owner={d} state={s} outcome={s} retries={d} txlen={d} rxlen={d} pwnd={d} flight={d} lasttx={d}ms rto={d}ms txpollt={d}\n", .{ t.slot, t.local_port, t.remote_port, t.owner, @tagName(t.state), @tagName(t.outcome), t.retries, t.tx_len, t.rx_len, t.peer_window, t.in_flight, t.last_tx_age_ms, t.rto_ms, t.tx_poll_timeouts }) catch continue;
                mon.console.puts(tline);
            }
            if (diag_diff) |d| {
                var cbuf: [384]u8 = undefined;
                // M135c (#2765): the appended lbound/lsat fields name the
                // per-listener child bound and count saturation refusals
                // (the append-only convention keeps existing substring
                // assertions green). obound/osat do the same for the
                // owner bound the SYN path enforces.
                const cline = std.fmt.bufPrint(&cbuf, "net: sock-diag malformed={d} foreign={d} dup={d} rxfull={d} capref={d} refdrop={d} txref={d} retx={d} timedout={d} badopt={d} ooo={d} txpollt={d} rm1={d} lbound={d} lsat={d} obound={d} osat={d}\n", .{ d.c.malformed, d.c.foreign, d.c.duplicates, d.c.rx_full, d.c.capacity_refused, d.c.refusal_dropped, d.c.tx_refused, d.c.retransmitted, d.c.timed_out, d.c.dropped_options, d.c.ooo_held, d.tpt, d.rm1, virtio_net.native_socket.core.child_limit, d.c.listen_saturated, virtio_net.native_socket.core.owner_limit, d.c.owner_saturated }) catch "";
                mon.console.puts(cline);
                if (d.probe) |p| {
                    var pbuf: [256]u8 = undefined;
                    const pline = std.fmt.bufPrint(&pbuf, "net: ready-diag mask1 rxlen={d} peerfin={} state={s} outcome={s} lport={d} rport={d} flight={d}\n", .{ p.rx_len, p.peer_fin, @tagName(p.state), @tagName(p.outcome), p.lport, p.rport, p.in_flight }) catch continue;
                    mon.console.puts(pline);
                }
            }
            // Claim 6050 (milestone seven I3): drain the keyboard/pointer
            // event FIFO — poll the XHCI interrupt-IN endpoints, decode the
            // HID reports, and push decoded bytes for the NEXT shell poll
            // (the same polled-drain discipline as net RX). No-op when the
            // input path is unarmed (default VM). Drains BEFORE the Road
            // Pops present so a report is never starved behind a slow
            // full-frame present.
            // Claim 9498 follow-on: the drain + dui block below read/mutate
            // driving_award (WIN) and push app events (EV) — take win+ev in
            // canonical order for the whole span (input.drain's keyboard
            // decode self-gates with acquire_missing and takes nothing).
            svclock.acquire_set(svclock.dom_bit(.win) | svclock.dom_bit(.ev));
            input.drain();
            // M15 C2 (Alt+Tab overlay, #225): hold-Alt+Tab shows preview.
            // Card U4/U5 (claims 4993/0935, ADR 0008 D4): the pointer tick
            // (click = focus + raise; the cursor follows the pointer) and
            // the focus-cycle chord. The outcomes print here — the serial
            // evidence the live gate asserts.
            if (input.take_alt_tab_shift()) |shift| {
                if (!driving_award.alt_tab_is_active()) {
                    if (driving_award.alt_tab_activate()) {
                        mon.console.puts("dui: alt-tab active count=");
                        mon.console.print_u64(driving_award.alt_tab_count());
                        mon.console.puts(" selected=");
                        mon.console.print_u64(driving_award.alt_tab_selected_id() orelse 0xff);
                        mon.console.puts("\n");
                    } else {
                        if (driving_award.cycle_focus()) |id| {
                            mon.console.puts("dui: cycle focused=");
                            mon.console.print_u64(id);
                            mon.console.puts("\n");
                        }
                    }
                } else {
                    driving_award.alt_tab_cycle(shift);
                    mon.console.puts("dui: alt-tab cycle selected=");
                    mon.console.print_u64(driving_award.alt_tab_selected_id() orelse 0xff);
                    mon.console.puts(" shift=");
                    mon.console.print_u64(if (shift) 1 else 0);
                    mon.console.puts("\n");
                }
            }
            if (driving_award.alt_tab_is_active() and !input.alt_held()) {
                if (driving_award.alt_tab_commit()) |id| {
                    mon.console.puts("dui: alt-tab commit focused=");
                    mon.console.print_u64(id);
                    mon.console.puts("\n");
                } else {
                    driving_award.alt_tab_dismiss();
                }
            }
            if (driving_award.pointer_tick(input.pointer_state(), input.take_click())) |id| {
                mon.console.puts("dui: pointer focus=");
                mon.console.print_u64(id);
                mon.console.puts("\n");
            }
            // Arc4 #238: Ctrl+Shift+B lowers focused window to back.
            if (input.take_lower_back()) {
                const fid = driving_award.focused_window_id();
                if (driving_award.user_lower_back(fid)) {
                    mon.console.puts("dui: lower-back id=");
                    mon.console.print_u64(fid);
                    mon.console.puts("\n");
                }
            }
            // M32 WMS8 Gate 5 (issue #628): the idle-loop consumers for the
            // drained geometry chords are DELETED — WMS5 Gate 2 moved those
            // decisions to the WM (tile/master/minimize/maximize/fullscreen/
            // always-on-top/workspace switch+cycle); the applied primitives
            // remain, driven by the `dui` monitor commands + SET_STATE, and
            // the matrix re-runs green through them.
            // M21 W10: Alt+arrow keyboard window movement (KEPT — no WM
            // coverage yet).
            if (input.take_move()) |mv| {
                const fid = driving_award.focused_window_id();
                if (driving_award.move_window_keyboard(fid, mv.dx, mv.dy)) {
                    mon.console.puts("dui: move id=");
                    mon.console.print_u64(fid);
                    mon.console.puts(" dx=");
                    mon.console.print_u64(@as(u64, @intCast(mv.dx + 32))); // offset for display
                    mon.console.puts(" dy=");
                    mon.console.print_u64(@as(u64, @intCast(mv.dy + 32))); // offset for display
                    mon.console.puts("\n");
                }
            }
            // M27 G2: the Ctrl+Shift+A about-dialog self-toggle is DELETED
            // (M32 WMS8 Gate 3, issue #628) — the WM owns the about-dialog
            // decision via slot-65 DIALOG (cmd 11); the kernel no longer
            // self-toggles it (Ctrl+Shift+A is WM-only now).
            // Claim 1574 (milestone six G3): Road Pops — one full-frame
            // present per dirty output batch (the card-3d drain pattern).
            // No-op when the tee is unarmed (default VM) or clean. #1592:
            // keep draining after a seat registers. paint_scene skips the
            // kernel terminal blit while the seat owns the layer (M71c);
            // the present still has to flush, or the pre-seat console frame
            // stays on the pixels the seat does not repaint.
            road_pops.drain();
            // Card G5 (claim 1543): Driving Award — refresh the clock
            // window from the 1 Hz generic timer and composite any dirty
            // windows. This is the clock-only present path (the tee's
            // present above already composites terminal output); no-op
            // when the manager is unarmed (default VM) or clean. M32 WMS2
            // (issue #622): when a WM is registered, composite pacing moves
            // to the scheduler tick path (the WM drives presents from its
            // COMPOSITE_TICK events) — this idle drain becomes a no-op so
            // it does not fight the WM. One flag check on the hot path;
            // no WM registered → runs exactly as before (zero-regression).
            if (!wm_server.registered()) _ = driving_award.drain(timer.ticks);
            // M32 WMS2 (issue #622): drain the once-per-teardown report —
            // the exit path is IRQ context so the fallback is surfaced here
            // (the process-exit-report pattern).
            if (wm_server.take_fallback_report()) {
                mon.console.print_line("wm: unregistered, shim resumed");
            }
            svclock.release_set(svclock.dom_bit(.win) | svclock.dom_bit(.ev));
            // M42 SX5 (issue #986): the default-manager seam, flipped by
            // M59 (issue #1298). The `wm` seat boots ONCE per session from
            // the shell idle (after the input drain so the boot keystrokes
            // have settled): the Go seat by default, `settings set wm
            // tabwm` for the Zig fallback seat, `settings set wm none` for
            // no seat at all. A share without the seat program reports the
            // miss and stays shim-only (the load-bearing gate invariant).
            wm_autostart_once(mon);
            // Card N11 (claim 5357): the bounded retransmission timer —
            // polled here (the idle loop is the time engine — the
            // card-N9 clock pattern). AFTER the drain, so an ACK the
            // drain just processed has cleared the pending state — a
            // retransmission never follows an acknowledged segment. The
            // poll advances ONE step: an expired RTO (3 s) retransmits
            // the pending SYN/data/FIN byte-exact (counted, printed); the
            // exhausted bound (10) aborts the connection honestly
            // (counted, printed). Bare ACKs are never pending.
            // Claim 9498 follow-on: poll_rto + the retransmit/abort paths
            // mutate virtio_net's TCP state — the same NET-domain bracket
            // as the RX drain above.
            svclock.net.acquire();
            // M84f (#1836): flush the over-cap refusal's own slot — a RST+ACK
            // staged by the drain above goes out from the idle loop (the same
            // transmit-from-idle precedent as the retransmit below), so every
            // driving seam (syscall / `net tcp` / net front-end) answers an
            // over-cap SYN within one idle tick.
            if (virtio_net.tcp.rst_pending) {
                var rst_out: usize = 0;
                if (virtio_net.net_tcp_send(virtio_net.tcp.rst_msg[0..virtio_net.tcp.rst_len], &rst_out) == .ok) {
                    virtio_net.tcp.rst_pending = false;
                }
            }
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
            svclock.net.release();
            // M21 W11: save window state every ~300 idle cycles.
            // Claim 9498 follow-on: serialize_state reads WIN state and the
            // WINDOWS.SAV write hits the FILE transport — both locked
            // (canonical file < win; a no-op when nothing changed).
            svclock.acquire_set(svclock.dom_bit(.file) | svclock.dom_bit(.win));
            persist_window_state_tick();
            svclock.release_set(svclock.dom_bit(.file) | svclock.dom_bit(.win));
            idle_wait_rx();
        }
    }
}

/// Boot presentation for the kernel seam. Prints the banner; with an RX
/// source wired it SP-switches to `park_stack` FIRST (issue #814: even
/// the setup-only path measures ~0x4010, the entire 16 KiB handoff boot
/// stack, so NO part of the RX path may run there) and `park_body` takes
/// over forever (never returns); without RX it prints the prompt and
/// returns so the caller parks in WFE. Never spins hot, never reads a
/// device register.
pub fn boot_and_park(mon: *monitor.Monitor, rx_wired: bool) void {
    if (!rx_wired) {
        monitor.banner(mon);
        mon.console.puts(expanded_prompt());
        return;
    }
    // Issue #814: everything from here runs on the dedicated park stack
    // (aarch64). One self-contained asm block: save boot SP/LR in
    // callee-saved x19/x20, load the two arguments (AAPCS64: x0 = mon,
    // x1 = park_stack top), `bl` the AAPCS64 body, restore. All operands
    // are registers — no symbol fixups, no fn-pointer call, nothing for
    // the optimizer to outline into a wrong-ABI shape (claim 8554: the
    // naked-fn + fn-pointer first attempt was tail-merged with leftover
    // registers and `mov sp, x2` ran with rc-remaining instead of the
    // stack top — the silent-death regression this inline form avoids).
    // The body never returns; the restore tail is the safety net.
    // Host tests keep the plain Zig call below — the same body on the
    // caller's stack, no asm on the host.
    if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile (
            \\mov x19, sp
            \\mov x20, x30
            \\mov x0, %[mon]
            \\mov x1, %[top]
            \\mov sp, x1
            \\bl %[body]
            \\mov sp, x19
            \\mov x30, x20
            :
            : [mon] "r" (mon),
              [top] "r" (@as(usize, @intFromPtr(&park_stack) + park_stack.len)),
              [body] "X" (&park_body),
            : .{ .x19 = true, .x20 = true, .x30 = true, .memory = true });
        unreachable;
    }
    park_body(mon);
}

/// M21 W11: BSS counter for periodic window state persistence.
var persist_save_counter: usize = 0;
const persist_save_every: usize = 300; // ~30 seconds at ~10 Hz poll rate

/// M21 W11: tick the persist counter and save if it wraps.
fn persist_window_state_tick() void {
    persist_save_counter +%= 1;
    if (persist_save_counter % persist_save_every == 0) {
        save_windows();
    }
}

/// M21 W11: save current window state to ESP as WINDOWS.SAV.
///
/// #563: skip the write when the serialized state is byte-identical to the
/// last one actually written. The persist tick fires every 300 idle cycles
/// — at the real (~250 Hz) idle-loop rate that is roughly once a second —
/// and each write's cluster-allocation scan reads ~170 FAT sectors (the
/// ESP's file region spans ~21.8k clusters). A stable desktop was rewriting
/// identical WINDOWS.SAV content every tick, keeping the virtio-blk
/// transport continuously busy and starving concurrent reads (the
/// verify-live-desktop CALC exec hit a transport timeout and surfaced as
/// ENOENT). Unchanged state is not persisted: no disk traffic, same
/// restore semantics.
var last_saved_windows: [driving_award.persist_max_bytes]u8 = undefined;
var last_saved_windows_len: usize = 0;
var have_last_saved_windows: bool = false;
fn save_windows() void {
    var buf: [driving_award.persist_max_bytes]u8 = undefined;
    const n = driving_award.serialize_state(&buf);
    if (have_last_saved_windows and last_saved_windows_len == n and std.mem.eql(u8, last_saved_windows[0..n], buf[0..n])) return;
    // M34 HF6 (issue #740): WINDOWS.SAV lives on the host share.
    // M50 TS2 (ADR 0024 D4): the kernel-actor gate (secret paths deny).
    // #2865: an empty live set is persisted TOO — restored phantoms are
    // never re-serialized, so a stale file would otherwise replay the
    // same dead rows every boot forever (a fixed-point leak, not
    // accumulation but the same ghost). Delete it; absent is already the
    // goal state.
    if (n == 0) {
        if (trust.check(trust.kernel_actor(), .host, "WINDOWS.SAV", .delete) != .allow) return;
        const dst = virtio_file.delete("WINDOWS.SAV");
        if (dst == virtio_file.st_ok or dst == virtio_file.st_not_found) {
            last_saved_windows_len = 0;
            have_last_saved_windows = true;
        }
        return;
    }
    if (trust.check(trust.kernel_actor(), .host, "WINDOWS.SAV", .write) != .allow) return;
    if (virtio_file.write_whole("WINDOWS.SAV", buf[0..n]) == virtio_file.st_ok) {
        @memcpy(last_saved_windows[0..n], buf[0..n]);
        last_saved_windows_len = n;
        have_last_saved_windows = true;
    }
}

/// M21 W11: restore window state from the share's WINDOWS.SAV (if it
/// exists). HF6: the ESP window is gone.
fn restore_windows() void {
    var content: [driving_award.persist_max_bytes]u8 = undefined;
    const n_opt = blk: {
        if (trust.check(trust.kernel_actor(), .host, "WINDOWS.SAV", .read) != .allow) break :blk null;
        const taken = acquire_file_lock();
        defer release_file_lock(taken);
        break :blk virtio_file.read_whole("WINDOWS.SAV", &content);
    };
    const n = n_opt orelse return;
    if (n == 0) return;
    _ = driving_award.restore_state(content[0..n], 99);
}

/// Idle between input polls in RX-wired mode: a bounded nop delay, not WFE.
/// The GIC/timer path IS live since claim 9187 (a real CNTP PPI preempts
/// this very loop every second), but the console RX, net RX, and XHCI input
/// are polled devices with no interrupt of their own, and a WFE would only
/// wake on the 1 s tick — capping input/net polling at 1 s granularity.
/// The bounded delay keeps the loop responsive without a timer (claim
/// 6684's original rationale), at the cost of a hot spin while idle (see
/// issue #122 — a WFE-with-tick-wake experiment is the recorded option).
/// Elided entirely on non-aarch64 hosts so the module stays host-testable
/// on x86_64 CI.
fn idle_wait_rx() void {
    if (comptime builtin.cpu.arch == .aarch64) {
        var spins: usize = 0;
        while (spins < 100_000) : (spins += 1) asm volatile ("nop");
    }
}

// ---------------------------------------------------------------------------
// Tests (host-side; mock console, no hardware)
// ---------------------------------------------------------------------------

pub fn make_handoff() handoff.HandoffV2 {
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

pub fn make_view() memmap.MapView {
    var view = memmap.MapView.init(std.mem.asBytes(&test_descriptors), @sizeOf(memmap.MemoryDescriptor), test_descriptors.len);
    view.key = 0x42;
    view.descriptor_version = 2;
    return view;
}

pub fn make_shell(mock: anytype, view: memmap.MapView) Shell {
    return Shell.init(
        mock.console(),
        .{ .handoff = make_handoff(), .map = view, .console_name = "mock" },
        monitor.MachineControl.disabled(),
    );
}

/// M34 HF6 (issue #740): shell persistence tests serve files through
/// virtio_file's in-memory share override (the ESP window is gone). Same
/// upsert pattern as exec.zig's seam; `test_reset_share()` arms an EMPTY
/// share, `set_test_share(null)` restores the no-channel state.
var test_share_files: [8]virtio_file.TestFile = undefined;
var test_share_n: usize = 0;
pub fn test_seed_share(name: []const u8, content: []const u8) void {
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
pub fn test_seed_dir(name: []const u8) void {
    if (test_share_n < test_share_files.len) {
        test_share_files[test_share_n] = .{ .name = name, .data = "", .is_dir = true };
        test_share_n += 1;
        virtio_file.set_test_share(test_share_files[0..test_share_n]);
    }
}
pub fn test_reset_share() void {
    test_share_n = 0;
    virtio_file.set_test_share(test_share_files[0..0]);
}

test "shell: mock-fed end-to-end session produces the exact transcript" {
    const long = &@as([256:0]u8, @splat("a"[0]));
    // 18 tokens: one past the 17-token limit (verb + 16 args), so the
    // tokenizer refuses the line before any handler sees it.
    const too_many_tokens = "echo t t t t t t t t t t t t t t t t t";
    const expected =
        "VirelaiOS - AArch64 firmware-assisted kernel monitor\n" ++
        "VirelaiOS: memory is a map, not a territory.\n" ++
        "motd: aarch64 el1 kernel live; scheduler, uaccess, fs, net, gfx, xhci armed.\n" ++
        "Type 'help' before touching anything expensive.\n" ++
        "virelai> help\r\n" ++
        "available commands:\n" ++
        "machine / identity\n" ++
        "  about       explain this questionable system\n" ++
        "  beans       count beans, probably\n" ++
        "  elephant    operational mascot diagnostics\n" ++
        "  sexiburger  operational mascot diagnostics (the Sexipus burger)\n" ++
        "  sysinfo     comprehensive system and subsystem diagnostic snapshot\n" ++
        "  tour        guided tour of the system for new users\n" ++
        "  uname       compact system identity\n" ++
        "  version     display build information\n" ++
        "  welcome     guided tour of the system for new users\n" ++
        "memory / machine state\n" ++
        "  addrspaces  per-task user address spaces: per-task TTBR0, EL1-only kernel overlay, user-root contents\n" ++
        "  fault       trigger a synchronous exception (diagnostic)\n" ++
        "  handoff     display boot-to-kernel ABI data\n" ++
        "  hex         format an integer in hexadecimal\n" ++
        "  mem         summarize the EFI memory map\n" ++
        "  pages       physical page allocator pool\n" ++
        "  pci         enumerate PCI devices on the bus\n" ++
        "  resources   fixed-pool audit: scheduler tasks, process registry, windows, page-table carve-out, and per-process ring bounds\n" ++
        "  timer       interrupt controller + timer status\n" ++
        "  uaccess     user-memory copy diagnostics (valid, fault, recovery)\n" ++
        "tasks / processes\n" ++
        "  exec        load a user program from the host share and enter it at EL0\n" ++
        "  fuzz        seeded EL0 syscall sweep plus live HF-wire corpus (M70a #1466)\n" ++
        "  kill        terminate a running process (kernel-owned lifetime)\n" ++
        "  mbox        per-process IPC mailbox: pending messages and drain counters\n" ++
        "  procs       process registry: image, address space, lifecycle, exit status\n" ++
        "  ps          process status table: PID, name, state, memory footprint, CPU ticks, and executor task per live/exited process (M22 D6)\n" ++
        "  spawn       spawn the lifecycle demo task\n" ++
        "  strace      trace a program's syscalls: 'strace exec APP.BIN [args]' arms the tracer around an exec and prints one line per syscall; 'strace off' disarms\n" ++
        "  sym         crash-report symbol table: 'sym' lists symbols loaded from the last ELF exec; 'sym <file>' parses an ELF's symtab from disk\n" ++
        "  syscalls    numbered syscall table and counters\n" ++
        "  tasks       tick-driven task scheduler status\n" ++
        "  smp         multiprocessor topology, online CPU cores, and per-core task state\n" ++
        "storage\n" ++
        "  cat         print a file from the host share (by name or path)\n" ++
        "  ls          list files on the host share (or a directory by path); '-l' for long format (D15)\n" ++
        "  mount       report the host-share file store (HF6: the FAT volumes are gone)\n" ++
        "  vf          host file channel (M34): 'vf ls/cat/mkdir/rm/mv <path>' read + mutate a macOS share over custom-virtio queue 5; 'vf open/close/write/truncate/fsync <h>' manage write handles (8-slot host cursor table)\n" ++
        "  write       write text to a file on the host share\n" ++
        "  mktemp      create a temporary file (empty, unique name)\n" ++
        "  stat        file metadata: size, type, cluster, path (D8)\n" ++
        "  du          recursive directory disk usage (M25 F4)\n" ++
        "  find        recursive file search with glob patterns ('find / -name \"*.BIN\"' — bounded 3 levels, 256 results)\n" ++
        "  inventory   list all installed applications from APPS.TXT with sizes and types (D16)\n" ++
        "networking\n" ++
        "  net         virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS + IPv6/NDP: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records; 'net ip6' shows the SLAAC address set; 'net ndp [<v6-addr>]' shows/resolves the NDP table; 'net ping6 <v6-addr>' sends an ICMPv6 echo request)\n" ++
        "  netsend     send a known Ethernet frame (bounded staging, TX + used-ring drain)\n" ++
        "  vsock       virtio-vsock transport (M115a/b): 'vsock' reports the arm state, 'vsock <port>' connects to the host listener and reports connected/refused/timeout, 'vsock ctl <verb>' runs one control-channel session\n" ++
        "graphics / input\n" ++
        "  font        terminal font size: small 8x8 (default), medium 16x16, large 24x24 (M20-U1); the same rung zooms the bound terminal grid 7x13/8x16/10x21 (M80i)\n" ++
        "  input       keyboard/pointer event FIFO: armed state, occupancy, drop count, last keyboard + pointer events\n" ++
        "  roadpops    Road Pops framebuffer console: armed/dirty/present counters (the boot terminal on the screen)\n" ++
        "  screen      virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)\n" ++
        "  screenshot  capture the current framebuffer (1280x720) and save as BMP to disk (G27)\n" ++
        "  text        framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears; 'text putraw' skips the trailing newline; 'text fontdebug [on|off]' missing-glyph stats)\n" ++
        "  wm          M32 WMS2/WMS4/WMS5 render-server register: the registered WM server pid, present-sequence counter, presents, COMPOSITE_TICK count, SET_WINDOW chrome submissions + SET_STATE visibility/workspace calls, and the WMS5 input-seam fan-out counters (ptr_fan = raw pointer samples, win_mirror = registry mirrors, key_fan = raw keyboard samples; 'wm none' means the shell idle shim is compositing)\n" ++
        "  wnd         M32 WMS3 WM server: 'wnd' reports the registered WM server (pid, present seq/count, tick count; 'wnd: none' = shell-shim compositing); 'wnd start' launches the long-lived EL0 WND.BIN server (infrastructure — not in APPS.TXT; the default VM stays shim-only)\n" ++
        "  tabwm       M39 TWM1 WM server: 'tabwm' reports the registered WM server; 'tabwm start' launches the long-lived EL0 TABWM.BIN server (left-sidebar browser-style window manager)\n" ++
        "  usb         XHCI host controller: `usb` transport report, `usb devices` enumerated devices, `usb report` last HID report, `usb bulk [probe ...]` bulk engine (U1), `usb msc [probe] [lba]` mass-storage BOT/SCSI probe (U2), `usb vol` MBR partition + FAT32 volume enumeration, `usb ls <vol>[/<dir>]` volume directory listing, `usb cat <vol>/<path> [<max>]` read-only file read (full byte count + FNV-1a 32 of every byte) (M70f F1), `usb rescan` polled lifecycle rescan (U4), `usb detach [slot]` administrative detach (U4)\n" ++
        "  dui         Driving Award window manager: registry (with owner pids), z-order, focus, hit-testing ('dui focus <n>' focuses; 'dui raise <n>' raises; 'dui lower <n>' lowers to back; 'dui move <n> <x> <y>' moves a user window; 'dui close <n>' releases a user window; 'dui list <pid>' filters by owner; 'dui hit <x> <y>' hit-tests; 'dui cycle' cycles focus like Alt+Tab; 'dui tile <n>' toggles a user window floating/tiled (M21 W1); 'dui master' swaps master/detail (M21 W2))\n" ++
        "system\n" ++
        "  beep        synthesize + play a sine through the virtio-snd PCM path ('beep <freq> <ms>' — reports the full control flow + submit/drain accounting)\n" ++
        "  calc        calculator utilities: 'calc history' shows saved calculation history from /data/calc_hst.txt\n" ++
        "  clear       clean up the crime scene\n" ++
        "  compose     list available Alt+key compose sequences for accented characters\n" ++
        "  crash       list recent crash tombstones from /data/crash/\n" ++
        "  clip        copy/paste the shared kernel clipboard ('clip <text...>' sets it, 'clip' prints it)\n" ++
        "  color       toggle ANSI terminal colors ('color on'/'color off'; 'color' shows current)\n" ++
        "  echo        repeat your regrettable decisions\n" ++
        "  help        grouped command catalog and per-command/per-topic help\n" ++
        "  random      print n random bytes from the seeded CSPRNG (hex)\n" ++
        "  reboot      restart the machine\n" ++
        "  repeat      repeat text, safely bounded\n" ++
        "  sh          run a script file of shell commands ('sh <script>' executes it line by line; 64 lines max, 256 chars per line; '#' comments; 'exit' stops early)\n" ++
        "  secrets     list the secret store's key NAMES only (never values; ADR 0024 D8)\n" ++
        "  settings    persistent configuration: `settings [list]`, `settings get <key>`, `settings set <key> <val>`, `settings reset`\n" ++
        "  shortcuts   keyboard shortcut reference card (G29)\n" ++
        "  sound       virtio-snd transport: device DID, class, status, control-queue state, device-config counts (jacks/streams/channel-maps), re-arm; stream-state control: 'sound volume <0-100>' and 'sound mute <on|off>'\n" ++
        "  shutdown    request power-off\n" ++
        "  type        echo stdin (the pipe source) to stdout — the right half of `a | type`\n" ++
        "  tty         terminal drop counters (ADR 0020 D1): out_dropped/in_dropped per bound tty ('tty' prints one line per terminal)\n" ++
        "  forensics   last-words recorder: on|off|dump|reset (off by default)\n" ++
        "  dmesg       system log viewer: last bytes of serial output (D12)\n" ++
        "  time        command timing: measure elapsed ticks and wall-clock time (D13)\n" ++
        "  which       locate a command: shell builtin, monitor command, or host-share application (D16; HF6: the ESP is gone)\n" ++
        "type 'help <command>' for details on a single command.\n" ++
        "type 'help <topic>' for a topic page (networking, windows, storage, graphics).\n" ++
        "virelai> version\r\n" ++
        "virelai-kernel\n" ++
        "milestone-two kernel proper (ADR 0004)\n" ++
        "handoff ABI v2\n" ++
        "build label: m1.5 commands & personality (mock console)\n" ++
        "virelai> mem\r\n" ++
        "mem: descriptors=0x0000000000000006 size=0x0000000000000028 version=0x0000000000000002 key=0x0000000000000042\n" ++
        "  usable: 0x0000000000480000 bytes (0x0000000000000480 pages)\n" ++
        "  conventional: 0x00000000003c0000 bytes (0x00000000000003c0 pages)\n" ++
        "  loader: 0x0000000000040000 bytes (0x0000000000000040 pages)\n" ++
        "  boot_services: 0x0000000000080000 bytes (0x0000000000000080 pages)\n" ++
        "  runtime: 0x0000000000008000 bytes (0x0000000000000008 pages)\n" ++
        "  reserved: 0x0000000000009000 bytes (0x0000000000000009 pages)\n" ++
        "  mmio: 0x0000000000010000 bytes (0x0000000000000010 pages)\n" ++
        "  kernel: 0x000000007e4df000..0x000000007e5613e8 (0x00000000000823e8 bytes)\n" ++
        "virelai> pages\r\n" ++
        "pages: armed=1 total=0x0000000000000480 free=0x0000000000000480 excluded=0x0000000000000000 regions=0x0000000000000003 span=0x0000000000007f80\n" ++
        "virelai> pages selftest\r\n" ++
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
        "virelai> tasks\r\n" ++
        "tasks: enabled=0 current=0 switches=0 pool=4/64 zombies=0\n" ++
        "  shell    saves=0 resumes=0 advances=0 state=ready\n" ++
        "  worker   saves=0 resumes=0 advances=0 state=ready\n" ++
        "  user-el0 saves=0 resumes=0 advances=0 state=ready\n" ++
        "  idle     saves=0 resumes=0 advances=0 state=ready\n" ++
        "virelai> echo \"elephant business\"\r\n" ++
        "elephant business\n" ++
        "virelai> ls\r\n" ++
        "ls: host=0x0000000000000003\n" ++
        "  KERNEL.BIN  0x0000000000000000  [host]\n" ++
        "  EFI         0x0000000000000000  [dir]\n" ++
        "  BOOTED.TXT  0x0000000000000036  [host]\n" ++
        "virelai> cat BOOTED.TXT\r\n" ++
        "VIRELAIOS BOOTLOADER\n" ++
        "firmware has agreed to cooperate\n" ++
        "virelai> write hello.txt hello world\r\n" ++
        "error: hello.txt: not persisted - host file-channel error\n" ++
        "virelai> cat hello.txt\r\n" ++
        "error: hello.txt: not found (no such file on the host share)\n" ++
        // ADR 0008 D3: the three shapes are gate-tested here byte-exactly,
        // so a command that invents a fourth shape fails CI.
        // Shape 1 (misuse): the usage line PLUS the registry's one-line hint.
        "virelai> pages bogus\r\n" ++
        "usage: pages [selftest]\n" ++
        "physical page allocator pool\n" ++
        // Shape 3 (unknown verb).
        "virelai> " ++ long ++ "\r\n" ++
        "unknown command '" ++ long ++ "' -- try 'help'\n" ++
        // Shape 2 (failure), from the dispatch layer: an over-long argv.
        "virelai> " ++ too_many_tokens ++ "\r\n" ++
        "error: too many arguments (max 17 tokens)\n" ++
        "virelai> ^C\r\n" ++
        // Enter pressed after the cancel submits an empty line, which the
        // registry answers in shape 2 (then a new prompt).
        "virelai> \r\n" ++
        "error: no command given; type 'help' for a list of commands\n" ++
        "virelai> ";

    var mock = console.MockConsole(16384){};
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
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("KERNEL.BIN", "");
    test_seed_dir("EFI");
    test_seed_share("BOOTED.TXT", "VIRELAIOS BOOTLOADER\nfirmware has agreed to cooperate\n");
    mock.feed("help\nversion\nmem\npages\npages selftest\ntasks\necho \"elephant business\"\nls\ncat BOOTED.TXT\nwrite hello.txt hello world\ncat hello.txt\npages bogus\n");
    mock.feed(long);
    mock.feed("\n");
    mock.feed(too_many_tokens);
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

// #1690: the substitution copies are bounded to subst_buf. Before the
// bound, `clip $(help)` panicked at index 261 of 256 in this safe-mode
// build (prefix 5 + capture 256 > out.len 256) and wrote past the stack
// buffer in the ReleaseSmall image. The pins: the run COMPLETES (an
// out-of-bounds copy would abort this test before any assert runs), the
// truncation notice fires, clip stores the byte-exact bounded line, and
// the suffix survives to the end of the clipboard readback — structural
// bytes are never dropped.
test "shell: cmd_subst output is bounded to the line buffer (#1690)" {
    var mock = console.MockConsole(16384){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    _ = alloc.init(make_view(), &.{});
    _ = scheduler.init();
    userspace.init();
    test_reset_share();
    defer virtio_file.set_test_share(null);
    // A 250-byte capture with no interior whitespace: one token, so the
    // dispatch layer (17-token cap) passes it straight to clip. prefix
    // "clip " (5) + suffix " TAILMARK" (10) reserve 15 bytes of the
    // 256-byte buffer, so the capture truncates to 241 and clip stores
    // 241 + 1 (join space) + 9 = 251 bytes — byte-exact.
    test_seed_share("SUBSTBIG.TXT", &@as([250:0]u8, @splat("X"[0])));
    mock.feed("clip $(cat SUBSTBIG.TXT) TAILMARK\n");
    mock.feed("clip\n"); // read the clipboard back
    var rounds: usize = 0;
    while (shell.poll() != .idle and rounds < 10000) : (rounds += 1) {}
    const transcript = mock.contents();
    try std.testing.expect(std.mem.indexOf(
        u8,
        transcript,
        "cmdsubst: output truncated to fit the line buffer\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        transcript,
        "clip: stored 251 bytes\n",
    ) != null);
    // No substitution refusal fired: this line is well-formed.
    try std.testing.expect(std.mem.indexOf(u8, transcript, "cmdsubst: unmatched") == null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "nested $(...)") == null);
    // The readback is the last output before the final prompt and ends
    // with the suffix — byte-anchored on the tail.
    try std.testing.expect(std.mem.endsWith(
        u8,
        transcript,
        "TAILMARK\nvirelai> ",
    ));
}
