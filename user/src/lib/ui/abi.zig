//! VirelaiOS UI Syscall ABI, IPC Wire Formats & System Helpers (M39 UI1).
const std = @import("std");
const draw = @import("draw.zig");

// ---------------------------------------------------------------------------
// M32 WMS7 Gate B (issue #627): the app↔WM mailbox protocol (WM_RPC) wire.
// This toolkit is compiled into 28 app modules whose module paths cannot
// reach `kernel/src/`, so the wire mirror below is frozen HERE and the
// live gate's byte-level round-trip (ui frame → WND.BIN parse → ack) is the
// integration drift guard: if this ever drifts from `wnd_core.WmRpc`, the
// WM's `wnd: mail` serve + the `wmrpc: *-ack` markers stop matching and the
// gate fails loudly. Layout is byte-identical to kernel/src/wnd_core.zig.
// ---------------------------------------------------------------------------
pub const WmRpc = extern struct {
    kind: u8,
    id: u8,
    seq: u8,
    reply_to: u8,
    applied: u8,
    pad: u8,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    title: [wm_rpc_title_max]u8,
};
pub const wm_rpc_title_max: usize = 24;
pub const wm_rpc_kind_raise: u8 = 1;
pub const wm_rpc_kind_config: u8 = 2;
pub const wm_rpc_kind_register_action: u8 = 3;
pub const wm_rpc_kind_invoke_action: u8 = 4;
pub const wm_rpc_kind_attach_tab: u8 = 5;
pub const wm_rpc_kind_detach_tab: u8 = 6;
pub const wm_rpc_kind_cycle_tab: u8 = 7;
/// M42 SX2 (issue #983): the app declares itself tab-aware — additive kind
/// mirrored from wnd_core (the drift guard test pins the pair).
pub const wm_rpc_kind_declare_fullscreen: u8 = 8;
pub const wm_rpc_reply_flag: u8 = 0x80;
pub const wm_rpc_max: usize = 64;

// ---------------------------------------------------------------------------
// Syscall Numbers & ABI Constants (ADR 0007 / ADR 0009 / ADR 0010)
// ---------------------------------------------------------------------------

pub const sys_write_num: u64 = 1;
pub const sys_yield_num: u64 = 2;
pub const sys_exit_num: u64 = 3;
pub const sys_sleep_num: u64 = 4;
pub const sys_procs_num: u64 = 7;
/// #2158 (ADR 0048): the kernel's self-pid register — the caller's pid
/// resolved from the task table, unspoofable by a same-named sibling.
pub const sys_getpid_num: u64 = 87;
pub const sys_win_open_num: u64 = 12;
pub const sys_win_fill_num: u64 = 13;
pub const sys_win_present_num: u64 = 14;
pub const sys_win_close_num: u64 = 15;
pub const sys_win_move_num: u64 = 16;
pub const sys_ipc_send_num: u64 = 5;
pub const sys_ipc_recv_num: u64 = 6;
pub const sys_win_raise_num: u64 = 17;
pub const sys_win_get_num: u64 = 18;
pub const sys_win_query_num: u64 = 19;
pub const sys_win_set_visible_num: u64 = 20;
pub const sys_poll_event_num: u64 = 21;
pub const sys_wait_event_num: u64 = 22;
pub const sys_file_open_num: u64 = 23;
pub const sys_file_read_num: u64 = 24;
pub const sys_file_write_num: u64 = 25;
pub const sys_file_close_num: u64 = 26;
pub const sys_dir_list_num: u64 = 27;
pub const sys_exec_num: u64 = 28;
pub const sys_kill_num: u64 = 29;
pub const sys_tcp_connect_num: u64 = 30;
pub const sys_tcp_send_num: u64 = 31;
pub const sys_tcp_recv_num: u64 = 32;
pub const sys_tcp_close_num: u64 = 33;
pub const sys_file_delete_num: u64 = 34;
pub const sys_file_rename_num: u64 = 35;
pub const sys_file_truncate_num: u64 = 36;
pub const sys_file_free_num: u64 = 37;
pub const sys_clipboard_set_num: u64 = 38;
pub const sys_clipboard_get_num: u64 = 39;
pub const clipboard_capacity: usize = 512;
pub const sys_timer_set_num: u64 = 40;
pub const sys_audio_info_num: u64 = 42;
pub const sys_audio_play_num: u64 = 43;
pub const sys_audio_volume_num: u64 = 44;
pub const sys_audio_mute_num: u64 = 45;
pub const sys_win_fill_batch_num: u64 = 46;
pub const sys_win_raise_front_num: u64 = 49;
pub const sys_win_lower_back_num: u64 = 50;
pub const sys_notify_num: u64 = 51;
pub const sys_drag_start_num: u64 = 48;
pub const sys_drag_read_num: u64 = 55;
pub const sys_win_move_to_workspace_num: u64 = 52;
pub const sys_win_set_unsaved_num: u64 = 53;
pub const sys_timer_cancel_num: u64 = 41;
pub const sys_udp_listen_num: u64 = 9;
pub const sys_udp_send_num: u64 = 10;
pub const sys_udp_recv_num: u64 = 11;
pub const sys_mmap_num: u64 = 63;
pub const sys_munmap_num: u64 = 64;
/// #1058: slot 66 `sys_time()` — current Unix wall-clock seconds (the boot
/// EFI GetTime epoch + uptime); negative (ENOSYS) when the firmware gave no
/// epoch.
pub const sys_time_num: u64 = 66;
/// #1072 (ADR 0020): slot 67 `sys_tty_attach(front_end)` — attach (0 =
/// detach, 1 = serial console) the calling process's controlling terminal
/// (opened as `/dev/tty`).
pub const sys_tty_attach_num: u64 = 67;
/// M50 TS1 (issue #1135, ADR 0024 D10): slot 68 `sys_principal(buf)` — the
/// read-only principal report: two u32 LE words (uid, caps), 8 bytes.
pub const sys_principal_num: u64 = 68;
pub const principal_bytes: usize = 8;
/// M50 TS2 (issue #1136, ADR 0024 D3/D4/D10): slot 69 `sys_file_mode(path,
/// mode)` — owner-only chmod on an existing path (no chown).
pub const sys_file_mode_num: u64 = 69;
/// M50 TS5 (issue #1139, ADR 0024 D8/D10): slot 70 `sys_secret_get(buf,
/// len)` — the calling principal's entries from the `SECRETS.TXT` store.
/// The ONLY in-guest reader of the secret store; no `sys_secret_set` exists.
pub const sys_secret_get_num: u64 = 70;
/// M50 TS4 (issue #1138, ADR 0024 D6/D10): slot 71 `sys_tty_net_auth(op,
/// buf, len)` — the delegated challenge/response/verdict channel between
/// the kernel net pump and the attached process. Excluded from strace.
pub const sys_tty_net_auth_num: u64 = 71;
/// The slot-71 op selectors (ADR 0007 amendment).
pub const net_auth_op_challenge: u64 = 0;
pub const net_auth_op_response: u64 = 1;
pub const net_auth_op_verdict: u64 = 2;
/// The challenge length the kernel mints (32 bytes), mirrored for the
/// userland verifier.
pub const net_challenge_len: usize = 32;

/// The fixed `sys_secret_get` wire record (key + value per caller entry).
pub const secret_entry_bytes: usize = 4 + 4 + 4 + 32 + 64;
pub const secret_entries_max: usize = 8;
/// ADR 0024 D8: the userland mirror of the store bounds.
pub const secret_max_key_len: usize = 32;
pub const secret_max_val_len: usize = 64;
/// A `sys_secret_get` record — the caller's own entries, fixed-size.
pub const SecretRecord = extern struct {
    uid: u32,
    key_len: u32,
    val_len: u32,
    key: [secret_max_key_len]u8,
    val: [secret_max_val_len]u8,
};
/// ADR 0024 D1/D5: the principal ids and capability bits (mirror of
/// `kernel/src/process.zig`). Duplicated here because the kernel module is
/// not reachable from the userland module graph.
pub const uid_system: u32 = 0;
pub const uid_user: u32 = 1000;
pub const cap_fs_any: u32 = 1 << 0;
pub const cap_proc_admin: u32 = 1 << 1;
pub const kernel_caps: u32 = cap_fs_any | cap_proc_admin;

/// A process principal (`sys_principal` wire shape / ADR 0024 D2).
pub const Principal = extern struct {
    uid: u32,
    caps: u32,
};
pub const PROT_READ: u64 = 1;
pub const PROT_WRITE: u64 = 2;
pub const PROT_EXEC: u64 = 4;
pub const MAP_PRIVATE: u64 = 0x02;
pub const MAP_ANONYMOUS: u64 = 0x20;
pub const MAP_POPULATE: u64 = 0x8000;
pub const datagram_max: usize = 72;
pub const payload_max: usize = 64;

// ---------------------------------------------------------------------------
// Event Kinds & Modifier Masks (ADR 0009)
// ---------------------------------------------------------------------------

pub const KEY_DOWN: u16 = 1;
pub const KEY_UP: u16 = 2;
pub const MOUSE_DOWN: u16 = 3;
pub const MOUSE_UP: u16 = 4;
pub const MOUSE_MOVE: u16 = 5;
pub const WIN_FOCUS: u16 = 6;
pub const WIN_BLUR: u16 = 7;
pub const WIN_CLOSE: u16 = 8;
pub const EVENT_TIMER: u16 = 9;
pub const WIN_RESIZE: u16 = 10;
pub const MOUSE_RIGHT_DOWN: u16 = 11;
pub const MOUSE_RIGHT_UP: u16 = 13;
/// Arc4 #242 (ADR 0013 D2): unsaved-changes warning from compositor.
/// arg0 = 0 (save), 1 (don't save), 2 (cancel).
pub const WIN_UNSAVED: u16 = 17;
/// ADR 0015 (M32 WMS1, claim 1484): composite/present cadence tick for the
/// registered WM server; reserved until the WMS2 kernel push path exists
/// (kernel mirror: kernel/src/events.zig).
pub const COMPOSITE_TICK: u16 = 18;

pub const MOD_SHIFT: u16 = 0x0001;
pub const MOD_CTRL: u16 = 0x0002;
pub const MOD_ALT: u16 = 0x0004;
pub const MOD_CMD: u16 = 0x0008;

pub const BTN_LEFT: u16 = 0x0100;
pub const BTN_RIGHT: u16 = 0x0200;
pub const BTN_MIDDLE: u16 = 0x0400;

pub const Event = extern struct {
    kind: u16,
    flags: u16,
    seq: u32,
    arg0: u32,
    arg1: u32,
};

// ---------------------------------------------------------------------------
// Storage Access Modes & Directory Entry (ADR 0010)
// ---------------------------------------------------------------------------

pub const MODE_READ: u32 = 0x0001;
pub const MODE_WRITE: u32 = 0x0002;
pub const MODE_CREATE: u32 = 0x0004;
pub const MODE_APPEND: u32 = 0x0008;
/// M25 Lane B (claim 2539): with MODE_CREATE|MODE_WRITE, open() creates a
/// real FAT32 directory (kernel-side cluster + dot entries) instead of an
/// empty file. Zero new syscall slots — the slot 23 flag contract extends.
pub const MODE_DIR: u32 = 0x0010;

pub const DirEntry = extern struct {
    name: [32]u8,
    size: u32,
    is_dir: u8,
    reserved: [3]u8,
};

// ---------------------------------------------------------------------------
// Process Descriptor Snapshot (ADR 0007 / slot 7)
// ---------------------------------------------------------------------------

pub const ProcessRow = extern struct {
    pid: u64,
    state: u64,
    exit_status: u64,
    name: [16]u8,
};

// ---------------------------------------------------------------------------
// Syscall Invocation Helpers (AArch64 inline assembly / host fallback)
// ---------------------------------------------------------------------------

pub fn syscall0(num: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
        : .{ .memory = true });
    return res;
}

pub fn syscall1(num: u64, arg0: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
        : .{ .memory = true });
    return res;
}

pub fn syscall2(num: u64, arg0: u64, arg1: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
        : .{ .memory = true });
    return res;
}

pub fn syscall3(num: u64, arg0: u64, arg1: u64, arg2: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
        : .{ .memory = true });
    return res;
}

pub fn syscall4(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
        : .{ .memory = true });
    return res;
}

pub fn syscall6(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    if (@import("builtin").os.tag != .freestanding) return 0;
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
          [arg4] "{x4}" (arg4),
          [arg5] "{x5}" (arg5),
        : .{ .memory = true });
    return res;
}

pub fn write_console(msg: []const u8) void {
    if (msg.len == 0) return;
    _ = syscall3(sys_write_num, 1, @intFromPtr(msg.ptr), msg.len);
}

pub fn yield_task() void {
    _ = syscall0(sys_yield_num);
}

pub fn exit_process(status: u64) noreturn {
    _ = syscall1(sys_exit_num, status);
    while (true) {
        yield_task();
    }
}

pub fn sleep_ticks(ticks: u64) void {
    _ = syscall1(sys_sleep_num, ticks);
}

pub fn win_open(x: u32, y: u32, w: u32, h: u32) i64 {
    _ = draw.init_fonts();
    return syscall4(sys_win_open_num, x, y, w, h);
}

pub fn win_fill(id: u32, x: u32, y: u32, w: u32, h: u32, rgb: u32) void {
    _ = syscall6(sys_win_fill_num, id, x, y, w, h, rgb);
}

pub fn win_present(id: u32) void {
    draw.flush_fills();
    _ = syscall1(sys_win_present_num, id);
}

pub fn win_close(id: u32) void {
    _ = syscall1(sys_win_close_num, id);
}

/// Arc4 #238: raise the window to the top of the z-order — the frozen-syscall
/// path (slot 49). WMS7 Gate B: `wm_raise_front` below is how the toolkit
/// "asks the WM"; this syscall path is the shim-mode / no-WM fallback and
/// stays intact for the frozen render-state ABI.
pub fn win_raise_front(id: u32) bool {
    return syscall1(sys_win_raise_front_num, id) == 0;
}

/// Arc4 #238: lower the window to the bottom of the z-order.
pub fn win_lower_back(id: u32) bool {
    return syscall1(sys_win_lower_back_num, id) == 0;
}

// ---------------------------------------------------------------------------
// M32 WMS7 Gate B (issue #627): the toolkit WM_RPC client.
//
// Apps "ask the WM" instead of "syscall the desktop": these helpers build a
// `WmRpc` frame (single-sourced in wnd_core), send it to the registered WM's
// mailbox (sys_ipc_send, slot 5) and await its ack reply in OUR OWN inbox
// (sys_ipc_recv, slot 6 — recv always reads the caller's own ring, so the
// toolkit needs no separate self-pid). If no WM is registered (the shim
// desktop), they fall back to the frozen syscalls — byte-identical behavior,
// additive back-compat.
//
// The API is synchronized-shaped (send + bounded poll on the reply), the
// issue's "async inversion" note answered explicitly: the WM serves at its
// 1 Hz kind-18 wake, so a mail op takes ≤ 1 s; app code stays a plain call.
// ---------------------------------------------------------------------------

/// The registered WM server's process name (the WMS3 `wnd start` bootstrap
/// execs WND.BIN; a future WM keeps the same name via ADR 0015).
pub const wm_proc_name: []const u8 = "WND.BIN";
/// M42 SX3 (issue #984): TABWM.BIN — the tabbed desktop's WM server — is the
/// second seat the toolkit's app↔WM RPC client resolves. At most ONE WM seat
/// exists (sys_wmctl REGISTER is one-seat), so matching either name is safe;
/// the ack routing is by pid, not by name.
pub const wm_proc_name_tab: []const u8 = "TABWM.BIN";
/// M57c (issue #1318): GOTABWM.ELF — the Go second seat — is the third WM
/// server the toolkit app<->WM RPC client resolves. Additive, exactly like
/// M42 SX3 added TABWM.BIN: at most ONE seat is registered (sys_wmctl
/// REGISTER is one-seat), so matching any known name is safe and the ack
/// routing stays by pid, not by name. Unmodified Zig apps (CALC, NOTEPAD)
/// therefore reach the Go seat with no app-source change.
pub const wm_proc_name_go: []const u8 = "GOTABWM.ELF";
pub const wm_proc_names: [3][]const u8 = .{ wm_proc_name, wm_proc_name_tab, wm_proc_name_go };
/// The proc-snapshot buffer bound (16 rows × 40 B — plenty for any fleet).
pub const wm_procs_buf: usize = 16 * 40;
/// The mailbox slot bound the WM_RPC frame must fit (the frozen 64 B).
pub const wm_rpc_slot_bytes: usize = wm_rpc_max;

/// Scan `sys_procs` for a RUNNING process whose 16-byte name equals `want`
/// (the claim-5799 snapshot row: u64 pid / u64 state / u64 exit / 16-byte
/// NUL-padded name). Returns its pid, or 0 if absent. `sys_procs` returns the
/// ROW COUNT, not bytes (the claim-5799 contract).
pub fn wm_find_pid(want: []const u8) u64 {
    var rows: [wm_procs_buf]u8 align(8) = undefined;
    const row_count = get_procs(&rows);
    if (row_count <= 0) return 0;
    var infos: [16]ProcInfo = undefined;
    const n = parse_procs(&rows, @intCast(row_count), &infos);
    for (infos[0..n]) |p| {
        if (p.state != .running) continue;
        if (std.mem.eql(u8, p.name[0..p.name_len], want)) return p.pid;
    }
    return 0;
}

/// True when `nm` names a WM server seat (either the floating-WM WND.BIN or
/// the tabbed TABWM.BIN — M42 SX3).
pub fn is_wm_name(nm: []const u8) bool {
    for (wm_proc_names) |known| {
        if (std.mem.eql(u8, nm, known)) return true;
    }
    return false;
}

/// Resolve the WM's pid and the caller's own pid — the WM acks to
/// `reply_to`, so the requester must stamp ITS OWN pid. Returns
/// (wm_pid, self_pid); a zero wm_pid means shim mode / no WM.
/// #2158 (ADR 0048): self comes from `sys_getpid` — the kernel's task
/// registry, which a same-named sibling can never be mistaken for. The
/// `sys_procs` name scan survives only as the no-kernel fallback for self
/// and for the WM row itself (matching WND/TABWM/GOTABWM by name is the
/// pre-#2079 shape; the seat register is a separate follow-up).
pub fn wm_peers(self_name: []const u8) struct { wm: u64, self: u64 } {
    var rows: [wm_procs_buf]u8 align(8) = undefined;
    const row_count = get_procs(&rows);
    var wm: u64 = 0;
    var self_pid: u64 = 0;
    {
        const gp = syscall0(sys_getpid_num);
        if (gp > 0) self_pid = @intCast(gp);
    }
    if (row_count > 0) {
        var infos: [16]ProcInfo = undefined;
        const n = parse_procs(&rows, @intCast(row_count), &infos);
        for (infos[0..n]) |p| {
            if (p.state != .running) continue;
            const nm = p.name[0..p.name_len];
            // M42 SX3: either WM server seat resolves (WND.BIN or TABWM.BIN).
            if (is_wm_name(nm)) wm = p.pid;
            if (self_pid == 0 and self_name.len != 0 and std.mem.eql(u8, nm, self_name)) self_pid = p.pid;
        }
    }
    return .{ .wm = wm, .self = self_pid };
}

/// Discover the registered WM's pid (0 = none / shim mode). M42 SX3: either
/// seat counts — whichever WM server process is running.
pub fn wm_available() u64 {
    for (wm_proc_names) |known| {
        const pid = wm_find_pid(known);
        if (pid != 0) return pid;
    }
    return 0;
}

/// Send one WM_RPC request and await its ack in our own inbox. Returns
/// whether the WM applied it. `self_name` identifies THIS process so the
/// WM's ack routes back through `sys_ipc_send(reply_to)`; recv then reads
/// our own ring. With the WM's 1 Hz serve cadence the bounded poll is far
/// more than enough; a timeout returns false (honest — the gate would then
/// fail rather than fake it). No WM reachable → false (caller falls back to
/// the frozen syscall).
pub fn wm_mail_request(kind: u8, id: u32, x: u16, y: u16, w: u16, h: u16, title: []const u8, self_name: []const u8, seq: u8) bool {
    const peers = wm_peers(self_name);
    if (peers.wm == 0 or peers.self == 0) return false;
    var req: WmRpc = .{
        .kind = kind,
        .id = @intCast(id & 0xff),
        .seq = seq,
        .reply_to = @intCast(peers.self & 0xff),
        .applied = 0,
        .pad = 0,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .title = @as([wm_rpc_title_max]u8, @splat(@as(u8, 0))),
    };
    const take = @min(title.len, wm_rpc_title_max);
    @memcpy(req.title[0..take], title[0..take]);
    const req_bytes = std.mem.asBytes(&req);
    _ = syscall3(sys_ipc_send_num, peers.wm, @intFromPtr(req_bytes.ptr), req_bytes.len);
    // Await our own inbox for the ack (recv reads the CALLER's ring, so no
    // self-pid needed): a bounded poll over a sleep+yield.
    var tries: u32 = 0;
    while (tries < 2_000_000) : (tries += 1) {
        var raw: [wm_rpc_slot_bytes]u8 = undefined;
        const got = syscall2(sys_ipc_recv_num, @intFromPtr(&raw), raw.len);
        if (got >= @sizeOf(WmRpc)) {
            var rep: WmRpc = undefined;
            @memcpy(std.mem.asBytes(&rep), raw[0..@sizeOf(WmRpc)]);
            if (rep.kind & wm_rpc_reply_flag != 0 and rep.seq == req.seq) {
                return rep.applied != 0;
            }
        }
        _ = syscall0(sys_yield_num);
    }
    return false; // timeout
}

/// Ask the WM to raise window `id` (WIN_RAISE, kind 1) — the toolkit's
/// "ask the WM" raise. `self_name` is THIS process's own name (its pid is
/// resolved for the ack's `reply_to`). Falls back to the frozen
/// `sys_win_raise_front` when no WM is registered (shim mode), so behavior
/// is identical either way.
pub fn wm_raise_front(id: u32, self_name: []const u8) bool {
    if (wm_mail_request(wm_rpc_kind_raise, id, 0, 0, 0, 0, "", self_name, 1)) return true;
    return win_raise_front(id); // fallback
}

/// Ask the WM to move/resize window `id` to `x,y,w,h` (WIN_CONFIG, kind 2).
/// `self_name` is THIS process's own name (ack routing). Falls back to the
/// frozen `sys_win_move` when no WM is registered.
pub fn wm_config(id: u32, x: u32, y: u32, w: u32, h: u32, self_name: []const u8) bool {
    if (wm_mail_request(wm_rpc_kind_config, id, @intCast(x), @intCast(y), @intCast(w), @intCast(h), "", self_name, 1)) return true;
    // Fallback: `sys_win_move(id, x, y)` takes x and y as SEPARATE args
    // (slot 16 — clamp+move, owner-restricted); there is no syscall resize
    // here, so the byte-identical frozen behavior is the move (static size
    // keeps the shim path honest; a caller wanting resize still uses
    // sys_win_resize when no WM is present).
    return syscall3(sys_win_move_num, id, x, y) == 0;
}

/// S1/S5 Action registry seam: register an action into section `section_id` for window `window_id`.
pub fn wm_register_action(window_id: u32, section_id: u16, action_id: u16, label: []const u8, self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_register_action, window_id, section_id, action_id, 0, 0, label, self_name, 1);
}

/// S5 Action registry seam: invoke a registered action.
pub fn wm_invoke_action(label: []const u8, self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_invoke_action, 0, 0, 0, 0, 0, label, self_name, 2);
}

/// S6 Tab model: attach window `child_id` as a tab of `parent_id`.
pub fn wm_attach_tab(child_id: u32, parent_id: u32, self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_attach_tab, child_id, @intCast(parent_id), 0, 0, 0, "", self_name, 3);
}

/// S6 Tab model: cycle active tab in the focused group.
pub fn wm_cycle_tab(self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_cycle_tab, 0, 0, 0, 0, 0, "", self_name, 4);
}

/// S6 Tab model: detach tab window `child_id` back to standalone.
pub fn wm_detach_tab(child_id: u32, self_name: []const u8) bool {
    return wm_mail_request(wm_rpc_kind_detach_tab, child_id, 0, 0, 0, 0, "", self_name, 5);
}

test "WMS7 Gate B: the toolkit WM_RPC wire mirror matches the frozen wnd_core ABI" {
    // The toolkit's mirror (user/src/lib/ui.zig) must stay byte-identical to
    // kernel/src/wnd_core.zig's WmRpc (the WM server parses this exact
    // layout). The live gate is the integration drift guard, but this host
    // test locks the layout/consts to the frozen ADR-0015 values so a drift
    // is caught WITHOUT a VM.
    try std.testing.expectEqual(@as(u8, 1), wm_rpc_kind_raise);
    try std.testing.expectEqual(@as(u8, 2), wm_rpc_kind_config);
    try std.testing.expectEqual(@as(u8, 3), wm_rpc_kind_register_action);
    try std.testing.expectEqual(@as(u8, 4), wm_rpc_kind_invoke_action);
    try std.testing.expectEqual(@as(u8, 5), wm_rpc_kind_attach_tab);
    try std.testing.expectEqual(@as(u8, 6), wm_rpc_kind_detach_tab);
    try std.testing.expectEqual(@as(u8, 7), wm_rpc_kind_cycle_tab);
    try std.testing.expectEqual(@as(u8, 0x80), wm_rpc_reply_flag);
    try std.testing.expectEqual(@as(u8, 24), wm_rpc_title_max);
    try std.testing.expectEqual(@as(usize, 64), wm_rpc_max);
    // The frozen little-endian layout: kind/id/seq/reply/applied/pad (6 B),
    // x/y/w/h (8 B), 24-byte title = 38 total; the frame fits the 64-B slot.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(WmRpc, "kind"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(WmRpc, "x"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(WmRpc, "title"));
    try std.testing.expectEqual(@as(usize, 38), @sizeOf(WmRpc));
    try std.testing.expect(@sizeOf(WmRpc) <= wm_rpc_max);
}

/// Arc4 #240: post a desktop notification toast. level: 0=info, 1=warn, 2=error.
pub fn notify(text: []const u8, level: u32) bool {
    return syscall3(sys_notify_num, @intFromPtr(text.ptr), text.len, level) == 0;
}

/// Arc4 #237: start a drag with a payload (up to 512B).
pub fn drag_start(payload: []const u8) bool {
    return syscall2(sys_drag_start_num, @intFromPtr(payload.ptr), payload.len) == 0;
}

/// Arc4 #237: read the drag payload after receiving a DROP event.
pub fn drag_read(buf: []u8) usize {
    return @intCast(syscall2(sys_drag_read_num, @intFromPtr(buf.ptr), buf.len));
}

/// Arc4 #241: move the window to a different workspace (0..2).
pub fn win_move_to_workspace(id: u32, ws: u32) bool {
    return syscall2(sys_win_move_to_workspace_num, id, ws) == 0;
}

/// Arc4 #242: mark or clear the unsaved-changes flag on a user window.
/// When set, clicking the close button shows a Save/Don't Save/Cancel dialog.
pub fn win_set_unsaved(id: u32, flag: bool) bool {
    return syscall2(sys_win_set_unsaved_num, id, if (flag) 1 else 0) == 0;
}

pub fn wait_event(ev: *Event) i64 {
    return syscall1(sys_wait_event_num, @intFromPtr(ev));
}

pub fn poll_event(ev: *Event) i64 {
    return syscall1(sys_poll_event_num, @intFromPtr(ev));
}

pub fn file_open(path: []const u8, flags: u32) i64 {
    return syscall3(sys_file_open_num, @intFromPtr(path.ptr), path.len, flags);
}

/// M25 Lane B (claim 2539): create a directory by `/`-path through the
/// slot 23 MODE_DIR flag extension. Returns the fd (close it), or a
/// negative error: -8 name too long, -9 exists, -5 disk full, -6 bad
/// path / no disk. The handle rejects read/write — creation only.
pub fn file_mkdir(path: []const u8) i64 {
    const fd = syscall3(sys_file_open_num, @intFromPtr(path.ptr), path.len, MODE_WRITE | MODE_CREATE | MODE_DIR);
    if (fd >= 0) file_close(@intCast(fd));
    return fd;
}

pub fn file_read(handle: u32, buf: []u8) i64 {
    return syscall3(sys_file_read_num, handle, @intFromPtr(buf.ptr), buf.len);
}

pub fn file_write(handle: u32, data: []const u8) i64 {
    return syscall3(sys_file_write_num, handle, @intFromPtr(data.ptr), data.len);
}

pub fn file_close(handle: u32) void {
    _ = syscall1(sys_file_close_num, handle);
}

/// Claim 3570 (ADR 0010 slot 27): enumerate the entries of a directory
/// ("" or "/data" — the DATA partition; "/esp" — the ESP) into `buf`.
/// Returns the entry count written, or a negative ADR 0007 error. Each
/// `DirEntry` is 40 bytes (`name[32]` NUL-padded + `size` + `is_dir`).
pub fn dir_list(path: []const u8, buf: []DirEntry) i64 {
    return syscall4(sys_dir_list_num, @intFromPtr(path.ptr), path.len, @intFromPtr(buf.ptr), buf.len);
}

/// Claim 5801 (ADR 0007 slot 34): delete a file by path. 0 on success;
/// negative error otherwise (EINVAL bad path, ENOENT absent).
pub fn file_delete(path: []const u8) i64 {
    return syscall2(sys_file_delete_num, @intFromPtr(path.ptr), path.len);
}

/// Claim 5801 (ADR 0007 slot 35): rename a file (same directory). 0 on
/// success; negative error otherwise.
pub fn file_rename(old_path: []const u8, new_path: []const u8) i64 {
    return syscall4(sys_file_rename_num, @intFromPtr(old_path.ptr), old_path.len, @intFromPtr(new_path.ptr), new_path.len);
}

/// Claim 5801 (ADR 0007 slot 36): resize an OPEN handle to `size` bytes.
pub fn file_truncate(handle: u32, size: u32) i64 {
    return syscall2(sys_file_truncate_num, handle, size);
}

/// Claim 5801 (ADR 0007 slot 37): free bytes on a volume (0 = DATA, 1 = ESP).
pub fn file_free(volume: u32) i64 {
    return syscall1(sys_file_free_num, volume);
}

/// M50 TS2 (#1136, ADR 0024 D10, ADR 0007 slot 69): owner-only chmod on an
/// existing path. `mode` is the 3-digit octal permission value (the group
/// triplet is reserved and stored zero). Returns 0, or a negative ADR 0007
/// error (EACCES not the owner, ENOENT absent, EINVAL bad path/mode, ENOSPC
/// the ownership table is full).
pub fn file_mode(path: []const u8, mode: u16) i64 {
    return syscall3(sys_file_mode_num, @intFromPtr(path.ptr), path.len, mode);
}

/// M50 TS5 (#1139, ADR 0024 D8/D10): read the CALLING principal's entries
/// from the `SECRETS.TXT` store (slot 70) into `buf` as fixed
/// `SecretRecord`s. Returns the byte length written (a multiple of
/// `secret_entry_bytes`; 0 when the principal owns nothing), or a negative
/// ADR 0007 error (EINVAL a too-small buffer / non-process caller, EFAULT a
/// bad buffer). The ONLY in-guest reader; values never reach any log.
pub fn secret_get(buf: []u8) i64 {
    if (@import("builtin").os.tag != .freestanding) return -4;
    return syscall2(sys_secret_get_num, @intFromPtr(buf.ptr), buf.len);
}

/// Claim 0169 (ADR 0007 slot 38): store text in the SHARED kernel clipboard
/// (truncated at 512 bytes). Returns the stored length; negative error
/// otherwise (EINVAL non-process caller, EFAULT bad pointer).
pub fn clipboard_set(data: []const u8) i64 {
    return syscall2(sys_clipboard_set_num, @intFromPtr(data.ptr), data.len);
}

/// Claim 0169 (ADR 0007 slot 39): read the SHARED kernel clipboard into
/// `buf` (non-destructive — the clipboard is not consumed). Returns the
/// copied length; 0 when empty; negative error otherwise.
pub fn clipboard_get(buf: []u8) i64 {
    return syscall2(sys_clipboard_get_num, @intFromPtr(buf.ptr), buf.len);
}

/// The negotiated playback state `sys_audio_info` copies out (ADR 0007
/// slot 42). 16 bytes, fixed layout.
pub const AudioInfo = extern struct {
    ready: u32,
    format: u8, // negotiated FMT_* (0xff = none)
    rate: u8, // negotiated RATE_* (0xff = none)
    channels: u8,
    padding: u8,
    period_bytes: u32,
    max_len: u32,
};

/// Claim 7636 (ADR 0007 slot 42): learn the device's negotiated playback
/// state. Returns 0; negative error otherwise (ENXIO when no sound device
/// is attached — the default VM).
pub fn audio_info(out: *AudioInfo) i64 {
    return syscall1(sys_audio_info_num, @intFromPtr(out));
}

/// Claim 7636 (ADR 0007 slot 43): play `data` bytes of PCM samples in the
/// negotiated format (the app synthesizes what `audio_info` reported).
/// Returns the bytes played; negative error otherwise (ENXIO no device,
/// ENAMETOOLONG over the kernel bound, EFAULT bad pointer).
pub fn audio_play(data: []const u8) i64 {
    return syscall2(sys_audio_play_num, @intFromPtr(data.ptr), data.len);
}

/// Claim 9297 (ADR 0007 slot 44): set the bounded kernel-side stream
/// volume (0..100 percent). Returns the volume on success; negative error
/// otherwise (EINVAL for a non-process caller or an out-of-range value —
/// no silent clamping).
pub fn audio_volume(vol: u8) i64 {
    return syscall1(sys_audio_volume_num, vol);
}

/// Claim 9297 (ADR 0007 slot 45): set the kernel-side mute state (1 =
/// silent). Returns 0 on success; negative error otherwise (EINVAL for a
/// non-process caller or a value that is not 0/1).
pub fn audio_mute(muted: u8) i64 {
    return syscall1(sys_audio_mute_num, muted);
}

/// Claim 7323 (ADR 0007 slot 40): arm the CALLING process's app timer to
/// fire ONE `EVENT_TIMER` event into its ADR 0009 queue after `delay_ticks`
/// scheduler ticks (0 clamps to 1; over-long truncates at the kernel bound;
/// re-arming replaces a pending timer). Returns 0; negative error otherwise
/// (EINVAL non-process caller).
pub fn timer_set(delay_ticks: u64) i64 {
    return syscall1(sys_timer_set_num, delay_ticks);
}

/// Claim 7323 (ADR 0007 slot 41): disarm the CALLING process's app timer.
/// Returns 1 if a pending timer was canceled, 0 if none was armed; negative
/// error otherwise (EINVAL non-process caller).
pub fn timer_cancel() i64 {
    return syscall0(sys_timer_cancel_num);
}

pub fn udp_listen(port: u16) i64 {
    return syscall1(sys_udp_listen_num, port);
}

pub fn udp_send(dst_ip: u32, dst_port: u16, payload: []const u8) i64 {
    return syscall4(sys_udp_send_num, dst_ip, dst_port, @intFromPtr(payload.ptr), payload.len);
}

pub fn udp_recv(port: u16, buf: []u8) i64 {
    return syscall3(sys_udp_recv_num, port, @intFromPtr(buf.ptr), buf.len);
}

pub fn tcp_listen(port: u16) i64 {
    return syscall2(sys_tcp_connect_num, 0, port);
}

pub fn tcp_connect(ip: u32, port: u16) i64 {
    return syscall2(sys_tcp_connect_num, ip, port);
}

pub fn tcp_send(data: []const u8) i64 {
    return syscall2(sys_tcp_send_num, @intFromPtr(data.ptr), data.len);
}

pub fn tcp_recv(buf: []u8) i64 {
    return syscall2(sys_tcp_recv_num, @intFromPtr(buf.ptr), buf.len);
}

pub fn tcp_close() i64 {
    return syscall0(sys_tcp_close_num);
}

/// M29 (issue #598): sys_mmap wrapper — allocate anonymous user memory.
pub fn mmap(addr: u64, len: u64, prot: u64, flags: u64) i64 {
    return syscall4(sys_mmap_num, addr, len, prot, flags);
}

/// M29 (issue #598): sys_munmap wrapper — free anonymous user memory.
pub fn munmap(addr: u64, len: u64) i64 {
    return syscall2(sys_munmap_num, addr, len);
}

/// #1058: the current Unix wall-clock seconds (boot EFI GetTime epoch +
/// uptime), or a negative error when the firmware gave no epoch.
pub fn sys_time() i64 {
    return syscall0(sys_time_num);
}

/// #1072 (ADR 0020): attach/detach the caller's controlling terminal to a
/// front-end. `front_end`: 0 = detach, 1 = the serial console.
pub fn tty_attach(front_end: u64) i64 {
    return syscall1(sys_tty_attach_num, front_end);
}

/// #1082 (ADR 0020 Amendment A): attach the caller's OWN `.user` window
/// (`window_id`) as the controlling terminal's window front-end (selector 2).
pub fn tty_attach_window(window_id: u64) i64 {
    return syscall2(sys_tty_attach_num, 2, window_id);
}

/// #1083 (ADR 0020 Amendment B): host the controlling terminal's net
/// front-end — the caller owns a TCP listener on `port` (selector 3).
pub fn tty_attach_net(port: u64) i64 {
    return syscall2(sys_tty_attach_num, 3, port);
}

/// M50 TS1 (#1135, ADR 0024 D10): read the calling process's principal
/// through slot 68. Returns null on the host (no `svc`) or on any non-8-byte
/// result. This is the only EL0 read of identity — there is no setter.
pub fn principal() ?Principal {
    if (@import("builtin").os.tag != .freestanding) return null;
    var buf: [principal_bytes]u8 = undefined;
    const rc = syscall1(sys_principal_num, @intFromPtr(&buf));
    if (rc != principal_bytes) return null;
    return .{
        .uid = std.mem.readInt(u32, buf[0..4], .little),
        .caps = std.mem.readInt(u32, buf[4..8], .little),
    };
}

/// M50 TS4 (#1138, ADR 0024 D6/D10): attach the net front-end with selector
/// 3 in the chosen auth mode — `scheme` (0 = open, 1 = hmac-sha256,
/// 2 = ed25519) and an optional source-IP allowlist (`allow_ip` as a
/// big-endian IPv4 u32; 0 = any). The credential is NEVER an argument: the
/// process reads it from the TS5 store and answers through
/// `tty_net_auth` (slot 71).
pub fn tty_attach_net_mode(port: u64, scheme: u64, allow_ip: u64) i64 {
    return syscall6(sys_tty_attach_num, 3, port, scheme, 0, allow_ip, 0);
}

/// M50 TS4 (#1138, ADR 0024 D6): one slot-71 step. `op` 0 = read the fresh
/// challenge (returns 32, or 0 before it is minted); 1 = read the buffered
/// client reply line (returns its hex length, 0 when none); 2 = vote the
/// verdict — `buf[0]` 0 = reject, 1 = accept (returns 0). Negative ADR 0007
/// error otherwise (EINVAL no reply pending/not auth mode, EACCES the
/// caller does not own the attached terminal, EFAULT a bad buffer).
pub fn tty_net_auth(op: u64, buf: []u8) i64 {
    if (@import("builtin").os.tag != .freestanding) return -4;
    return syscall3(sys_tty_net_auth_num, op, @intFromPtr(buf.ptr), buf.len);
}

/// ADR 0007 slot 8 `sys_wait(target)`: block the calling process until the
/// process with id `target` exits, then return its exit status. The SH2
/// shell uses it to run external commands in the foreground and propagate
/// `$?`. Negative ADR 0007 error on a bad/self/`created` target.
pub const sys_wait_num: u64 = 8;

pub fn wait_process(pid: u64) i64 {
    return syscall1(sys_wait_num, pid);
}

/// M19 P1 (ADR 0007 slots 56/57): the bounded kernel pipe behind the `|`
/// operator — `sys_pipe_write` appends, `sys_pipe_read` drains oldest-first.
pub const sys_pipe_read_num: u64 = 56;
pub const sys_pipe_write_num: u64 = 57;

pub fn pipe_write(data: []const u8) i64 {
    return syscall2(sys_pipe_write_num, @intFromPtr(data.ptr), data.len);
}

pub fn pipe_read(buf: []u8) i64 {
    return syscall2(sys_pipe_read_num, @intFromPtr(buf.ptr), buf.len);
}

pub const sys_ping_send_num: u64 = 59;
pub const sys_ping_poll_num: u64 = 60;
pub const sys_net_stats_num: u64 = 62;

pub fn ping_send(ip: u32) i64 {
    return syscall1(sys_ping_send_num, ip);
}

pub fn ping_poll() i64 {
    return syscall0(sys_ping_poll_num);
}

pub const ProcState = enum(u64) {
    created = 1,
    running = 2,
    exited = 3,
    _,
};

/// Claim 6359 / issue #1333 (ADR 0007 slot 28): load a program from the
/// share into a fresh process slot from EL0. `args` is at most 8 strings,
/// packed as 256-byte NUL-terminated slots (M71m #1572: 255 bytes usable;
/// a longer string is refused). An empty slice is `argc == 0` (no argv).
/// Returns the new process's pid on success; negative ADR 0007 error
/// otherwise (EINVAL bad path/argc/loader refusal, EFAULT bad pointer,
/// ENOENT not on the share, ENOSPC capacity).
pub const exec_max_args: usize = 8;
pub const exec_arg_slot_bytes: usize = 256;

pub fn exec_program_args(name: []const u8, args: []const []const u8) i64 {
    if (name.len == 0) return -1;
    if (args.len > exec_max_args) return -1;
    for (args) |a| {
        if (a.len >= exec_arg_slot_bytes) return -1;
    }
    var block: [exec_max_args * exec_arg_slot_bytes]u8 = @as([(exec_max_args * exec_arg_slot_bytes)]u8, @splat(@as(u8, 0)));
    for (args, 0..) |a, i| {
        @memcpy(block[i * exec_arg_slot_bytes ..][0..a.len], a);
    }
    const argv_ptr: u64 = if (args.len == 0) 0 else @intFromPtr(&block);
    return syscall4(sys_exec_num, @intFromPtr(name.ptr), name.len, argv_ptr, args.len);
}

pub fn exec_program(name: []const u8) i64 {
    return exec_program_args(name, &.{});
}

/// Claim 7604 (ADR 0007 slot 29): arm the target process for termination
/// from EL0 — the kill half of the process-control seam (the EL1h
/// monitor's `kill` is the privileged equivalent). The target exits with
/// the reserved status 137 at its next ring selection. Returns 0 once
/// armed; EINVAL for an out-of-range/free/exited/scheduler-owned target or
/// a non-process caller.
pub fn kill_process(pid: u64) i64 {
    return syscall1(sys_kill_num, pid);
}

pub const ProcInfo = struct {
    pid: u64,
    state: ProcState,
    exit_status: u64,
    name: [16]u8,
    name_len: usize,
};

pub fn get_procs(buf: []u8) i64 {
    return syscall2(sys_procs_num, @intFromPtr(buf.ptr), buf.len);
}

pub fn parse_procs(raw: []const u8, row_count: usize, out: []ProcInfo) usize {
    const row_size: usize = 40;
    const max_rows = @min(row_count, @min(raw.len / row_size, out.len));
    var i: usize = 0;
    while (i < max_rows) : (i += 1) {
        const off = i * row_size;
        const pid = std.mem.readInt(u64, raw[off .. off + 8][0..8], .little);
        const state_raw = std.mem.readInt(u64, raw[off + 8 .. off + 16][0..8], .little);
        const exit_status = std.mem.readInt(u64, raw[off + 16 .. off + 24][0..8], .little);
        var name: [16]u8 = @as([16]u8, @splat(@as(u8, 0)));
        @memcpy(&name, raw[off + 24 .. off + 40]);

        var name_len: usize = 0;
        while (name_len < 16 and name[name_len] != 0) : (name_len += 1) {}

        out[i] = .{
            .pid = pid,
            .state = @fromBackingInt(@intCast(state_raw)),
            .exit_status = exit_status,
            .name = name,
            .name_len = name_len,
        };
    }
    return max_rows;
}
