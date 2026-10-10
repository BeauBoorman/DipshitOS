//! VirelaiOS milestone-three syscall ABI (claim 3594).
//!
//! The claim-8215 EL0 boundary owns exception entry and return. This module
//! layers a fixed numbered contract on that seam: x8 is the syscall number,
//! x0..x5 are arguments, `svc #0` is reserved, and x0 receives the result.
//! The 64-slot function-pointer table is built at runtime in BSS (ADR 0005):
//! the flat kernel loader applies no relocations, so a const table would hold
//! invalid link-time function addresses at the runtime-selected image base.
//!
//! No allocation, libc, POSIX, or address-space work lives here (the
//! process registry is only READ — the mailbox is keyed by process id and
//! the recv path resolves the calling task's process). `sys_write` copies
//! user bytes through the claim-6120 uaccess layer (`uaccess.copy_in`),
//! which enforces the ADR 0007 `EFAULT` (-3) contract for bad user
//! pointers (out-of-region, overflow, unmapped, permission) without
//! letting them crash EL1.
//!
//! Card 3f (claim 5965): slots 5/6 — `sys_ipc_send(target, buf, len)` and
//! `sys_ipc_recv(buf, max)` — move bytes between processes through the
//! bounded per-process mailbox (`mailbox.zig`): send copy_in's the
//! caller's region into the TARGET's ring (full → `ENOSPC` -5), recv
//! copies the caller's OWN ring out (empty → 0), and every byte crosses
//! the uaccess window in both directions. The recv path peeks → uaccess
//! copy_out → drops, so a bad recv buffer (`EFAULT`) never loses the
//! message.
//!
//! Card N6 (claim 1384): slots 9/10/11 — `sys_udp_listen(port)`,
//! `sys_udp_send(ip, port, buf, len)` and `sys_udp_recv(port, buf, max)`
//! — expose the milestone-five UDP layer (`udp.zig` / `net_udp_send`) to
//! EL0 through the claim-6120 uaccess window: bind a port on the bounded
//! kernel listen table, send ONE datagram (own-IP → the N5 LOOPBACK
//! path, a peer → the ARP-resolved TX path; fixed source port 7000), and
//! receive the oldest datagram (peek → copy_out → pop — the ipc recv
//! EFAULT-preservation contract). The table is kernel-global: any EL0
//! task may bind or receive on any port (no per-process ownership —
//! honest bound, the ADR 0007 amendment). No protocol logic lives here
//! (the N5 layer owns UDP); these handlers marshal args, copy bytes, and
//! call through.
//!
//! Card G6 (claim 0487): slots 12/13/14 — `sys_win_open` / `sys_win_fill` /
//! `sys_win_present` — expose the G5 window manager's user-window surface
//! to EL0: open a pool-backed kernel-owned window (id 2..9, WM1 #707 —
//! per-window back-buffer carved from the page pool at open, freed at
//! close), fill rects in its back-buffer, and present it (mark dirty
//! for the shell idle loop's compositor). Follow-ons add slot 15
//! `sys_win_close` (teardown), per-process ownership (auto-close on exit +
//! owner-restricted fill/present/close), and slots 16/17 `sys_win_move` /
//! `sys_win_raise` (reposition + restack the caller's window), slot 18
//! `sys_win_get` (copy the caller's window rect out through uaccess — the
//! read-back seam after a clamped move), slot 19 `sys_win_query` (copy the
//! FULL window state — rect + z-order rank + focus/visible/dirty flags), and
//! slot 20 `sys_win_set_visible` (hide/show the caller's window). Those two
//! pointer-taking win slots are the only uaccess users; everything else is
//! plain numbers — the kernel owns the buffers; an EL0 program never touches
//! them directly — no allocation.

const std = @import("std");
pub const abi = @import("syscall_abi.zig");
pub const trace = @import("trace.zig");
pub const sampler = @import("sampler.zig");
pub const memstat = @import("memstat.zig");
pub const console = @import("console.zig");
pub const exceptions = @import("exceptions.zig");
pub const mailbox = @import("mailbox.zig"); // claim 5965: per-process rings
pub const process = @import("process.zig"); // claim 5965: target/current-process lookup
pub const scheduler = @import("scheduler.zig");
// claim 9498 follow-on: per-service-domain locks — syscalls contend only within
// their domain. Exported since M70a (#1453) so a host test can observe the
// dispatch seam's acquire/release symmetry through THIS instance (a separately
// mapped module would be a different copy of the lock state).
pub const svclock = @import("svclock.zig");
pub const arp = @import("arp.zig"); // M26 N2 (issue #400): the ARP table for the net-stats snapshot
pub const dhcp = @import("dhcp.zig"); // M26 N2 (issue #400): DHCP lease state for the net-stats snapshot
pub const udp = @import("udp.zig"); // claim 1384 (card N6): the milestone-five UDP layer
pub const virtio_net = @import("virtio_net.zig"); // claim 1384 (card N6): net_udp_send (TX + loopback)
pub const virtio_entropy = @import("virtio_entropy.zig"); // M97g (#2084): the getrandom lazy reseed
pub const uaccess = @import("uaccess.zig"); // claim 6120: fault-safe copy-in
pub const userspace = @import("userspace.zig");
pub const driving_award = @import("driving_award.zig"); // claim 1543/0487 (cards G5/G6): the window manager this seam renders into
pub const wnd_core = @import("wnd_core.zig");
const klog = @import("klog.zig"); // #990: serial-log seam (hook armed by main.zig) // M32 WMS4 (issue #624): the SET_WINDOW chrome-descriptor ABI (single source with the WM server)
pub const virtio_gpu = @import("virtio_gpu.zig"); // M32 WMS2 (issue #622): the G1 gpu-armed signal for the REGISTER ENXIO check
pub const wm_server = @import("wm_server.zig"); // M32 WMS2 (issue #622): the render-server register backing slot 65
pub const events = @import("events.zig"); // Milestone 9 (claim 1016): application event queues
pub const file_table = @import("file_table.zig"); // Milestone 10 (claim 3570): userland storage ABI
pub const esp_exec = @import("exec.zig"); // Claim 6359 (ADR 0007 slot 28): the EL0 exec seam — reuse the EL1h loader
pub const virtio_file = @import("virtio_file.zig"); // HF6: the host channel's path max is the exec name bound (the ESP window is gone)
pub const trust = @import("trust.zig");
pub const tcp = @import("tcp.zig"); // Milestone 12 (claim 7483): TCP client seam
pub const timer = @import("timer.zig"); // Hardware cycle counter + ticks for TCP timeouts
pub const csprng = @import("csprng.zig"); // ISN generation for TCP connect
pub const clipboard = @import("clipboard.zig"); // Milestone 14 (claim 0169): the shared kernel clipboard
pub const pipe = @import("pipe.zig"); // M19 P1 (issue #290): the bounded pipe buffer behind slots 56/57
pub const terminal = @import("terminal.zig"); // #1072 (ADR 0020): the terminal seam + sys_tty_attach
pub const app_timers = @import("app_timers.zig"); // Milestone 14 (claim 7323): the per-process app timer facility
pub const virtio_snd = @import("virtio_snd.zig"); // Milestone 15 (claim 7636): the virtio-snd playback path behind sys_audio_*
pub const fbtext = @import("text.zig"); // M20-U1 (claim 5127): sys_font_size's terminal font state
pub const shared_region = @import("shared_region.zig"); // M33 SB1 (claim 7418): the D2 shared-anon capability policy (ADR 0016)
pub const shared_mmap = @import("shared_mmap.zig"); // M33 SB2 (claim 8878): the shared-anon MMU wiring (owner RW / WM RO leaves)
pub const secret = @import("secret.zig"); // M50 TS5 (issue #1139, ADR 0024 D8): the SECRETS.TXT secret store behind sys_secret_get

const builtin = @import("builtin");
pub const mmu = @import("mmu.zig");
pub const alloc = @import("alloc.zig");
pub const memmap = @import("memmap.zig"); // host tests: arm the physical allocator for eager shared-anon create

pub const slot_count: usize = abi.slot_count;
/// 56 through M18 + slot 58 `sys_font_size` (M20-U1); 56/57 are Lane A's
/// reserved pipe slots (M19) — the gap is intentional, see
/// docs/archive/agent-concurrency-plan.md §8.
/// M19 P1 (issue #290): slots 56/57 are the bounded pipe.
/// M26 N1 (issue #399): slots 59/60 are ping send/poll.
/// M26 N2 (issue #400): slot 62 is the net-stats snapshot.
/// M29 (issue #598): slots 63/64 are sys_mmap/sys_munmap.
/// M32 WMS2 (issue #622): slot 65 is sys_wmctl (ADR 0015).
/// M50 TS1 (#1135): slot 68 is sys_principal; TS2 (#1136): slot 69 is
/// sys_file_mode; TS5 (#1139): slot 70 is sys_secret_get; TS4 (#1138):
/// slot 71 is sys_tty_net_auth; M51 SSH-P1 (#1166, ADR 0025 D5):
/// slot 72 is sys_getrandom; ADR 0027 (#1214 round 2): slots 73/74 are
/// sys_thread/sys_futex; issue #1228 (phase 0c): slot 75 is sys_exnotify;
/// issue #1163 (phase 2): slot 76 is sys_sock_ready; M66a (#1443): slot 77
/// is sys_file_sync; M83b (#1775): slot 78 is sys_time_set.
/// `implemented_count` is the number of
/// registered rows (rows 0..implemented_count-1).
pub const implemented_count: usize = abi.slots.len;
/// Card G6 (claim 0487) follow-on (slot 18): the fixed `sys_win_get` shape —
/// four u32 LE words (x, y, w, h), 16 bytes, marshaled per call and copy_out'd
/// through uaccess (the procs snapshot pattern).
/// Card G6 (claim 0487) follow-on (slot 19): the fixed `sys_win_query` shape —
/// eight u32 LE words (x, y, w, h, z, focused, visible, dirty), 32 bytes.
pub const write_cap: u64 = 256;
pub const svc_immediate: u16 = 0;

pub const sys_ping: u64 = 0;
pub const sys_write: u64 = 1;
pub const sys_yield: u64 = 2;
pub const sys_exit: u64 = 3;
pub const sys_sleep: u64 = 4;
/// Card 3f (claim 5965): the IPC mailbox slots — the ONLY ABI amendment
/// in the follow-on 3 card set (ADR 0007 stays otherwise frozen).
pub const sys_ipc_send: u64 = 5;
pub const sys_ipc_recv: u64 = 6;
/// Card 4a (claim 5799): process introspection — slot 7, the ONE ABI
/// change in the follow-on 4 card set's first card (ADR 0007 amendment;
/// every existing syscall number 0–6 stays frozen).
pub const sys_procs: u64 = 7;
/// Card 4c (claim 9946): exit-status propagation to a peer — slot 8, the
/// follow-on 4 card set's second ABI change (ADR 0007 slots 7/8 amendment;
/// every existing syscall number 0–7 stays frozen). `sys_wait(target)`
/// blocks the caller until the target process exits and returns its
/// status — bounded, kernel-owned; NOT POSIX wait (no zombies, no fds).
pub const sys_wait: u64 = 8;
/// Card N6 (claim 1384): the UDP syscall seam — slots 9/10/11, the card's
/// ONE ABI change (the ipc slots-5/6 precedent; every existing syscall
/// number 0–8 stays frozen). `sys_udp_listen(port)` binds the bounded
/// kernel listen table; `sys_udp_send(ip, port, buf, len)` transmits ONE
/// datagram (fixed src port 7000, own-IP loopback or the ARP-resolved TX
/// path); `sys_udp_recv(port, buf, max)` copies the oldest datagram out.
pub const sys_udp_listen: u64 = 9;
pub const sys_udp_send: u64 = 10;
pub const sys_udp_recv: u64 = 11;
/// Card G6 (claim 0487): the draw/window syscall seam — slots 12/13/14, the
/// card's ONE ABI change (the ipc slots-5/6, slots-7/8, and udp slots-9/10/11
/// precedents; every existing syscall number 0–11 stays frozen).
/// `sys_win_open(x, y, w, h)` opens a kernel-owned user window (id 2..9) in
/// the G5 window registry; `sys_win_fill(id, x, y, w, h, rgb)` fills a rect
/// in its back-buffer; `sys_win_present(id)` marks it dirty for the
/// compositor. Plain numbers only — no uaccess; the kernel owns the buffers.
pub const sys_win_open: u64 = 12;
pub const sys_win_fill: u64 = 13;
pub const sys_win_present: u64 = 14;
/// Card G6 (claim 0487) follow-on: `sys_win_close(id)` releases a user
/// window (the EL0 half of the teardown seam — the monitor's `win close`
/// is the EL1h half; both call `driving_award.user_close`).
pub const sys_win_close: u64 = 15;
/// Card G6 (claim 0487) follow-on: `sys_win_move(id, x, y)` repositions the
/// caller's window (clamped on-scanout) and `sys_win_raise(id)` raises it to
/// the top — the window manager's move/restack surface from EL0, owner-
/// restricted like fill/present/close.
pub const sys_win_move: u64 = 16;
pub const sys_win_raise: u64 = 17;
/// Card G6 (claim 0487) follow-on: `sys_win_get(id, buf)` copies the CALLER'S
/// user window's geometry (x, y, w, h as four u32 LE words — 16 bytes) OUT
/// through uaccess, so an EL0 program can read its window's rect back after a
/// CLAMPED move (`sys_win_move` clamps silently; this is the read-back seam).
/// The ONE pointer-taking win slot.
pub const sys_win_get: u64 = 18;
pub const win_rect_bytes: usize = 16;
/// Card G6 (claim 0487) follow-on: `sys_win_query(id, buf)` copies the
/// CALLER'S user window's FULL state (x, y, w, h, z, focused, visible, dirty
/// as eight u32 LE words — 32 bytes) OUT through uaccess, so an EL0 program
/// can introspect its window end to end (z-order rank + focus + flags), not
/// just the rect.
pub const sys_win_query: u64 = 19;
pub const win_query_bytes: usize = 32;
/// Card G6 (claim 0487) follow-on: `sys_win_set_visible(id, visible)` hides
/// (0) or shows (1) the CALLER'S user window — the window manager's
/// visibility surface from EL0, owner-restricted like fill/present/close.
/// Plain numbers, no uaccess.
pub const sys_win_set_visible: u64 = 20;
/// Milestone 9 (claim 1016): `sys_poll_event(buf)` non-blocking event poll.
pub const sys_poll_event: u64 = 21;
/// Milestone 9 (claim 1016): `sys_wait_event(buf)` blocking event wait.
pub const sys_wait_event: u64 = 22;
/// Milestone 10 (claim 3570): userland storage ABI slots 23–27.
pub const sys_file_open: u64 = 23;
pub const sys_file_read: u64 = 24;
pub const sys_file_write: u64 = 25;
pub const sys_file_close: u64 = 26;
pub const sys_dir_list: u64 = 27;
/// Claim 6359 / issue #1333: `sys_exec(path_ptr, path_len, argv_ptr, argc)`
/// — the EL0 exec seam. Copies the `.BIN` name through uaccess and runs
/// the EL1h loader (`exec.exec_file_as`) to load the program from the
/// share into a fresh process slot and spawn it at EL0. `argc == 0` means
/// no args; `argc` in 1..=8 copies packed 32-byte NUL-terminated slots
/// (card-3e). Returns the new process's pid on success.
pub const sys_exec: u64 = 28;
/// Claim 7604: `sys_kill(target_pid)` — the EL0 termination seam. Arms the
/// target process's executor through the claim-7786 kill
/// (`scheduler.request_kill`): the ring converts the target's NEXT
/// selection into the existing exit path with the reserved status 137 —
/// the OS, not the program, owns process lifetime. Returns 0 once armed;
/// EINVAL for every refusal.
pub const sys_kill: u64 = 29;
/// Milestone 12 (claim 7483): `sys_tcp_connect(ip, port)` — slot 30.
pub const sys_tcp_connect: u64 = 30;
/// Milestone 12 (claim 7483): `sys_tcp_send(buf, len)` — slot 31.
pub const sys_tcp_send: u64 = 31;
/// Milestone 12 (claim 7483): `sys_tcp_recv(buf, max)` — slot 32.
pub const sys_tcp_recv: u64 = 32;
/// Milestone 12 (claim 7483): `sys_tcp_close()` — slot 33.
pub const sys_tcp_close: u64 = 33;
/// Milestone 13 (claim 5801): `sys_file_delete(path_ptr, path_len)` — slot 34.
pub const sys_file_delete: u64 = 34;
/// Slot 35: old_len bit 63 explicitly selects replacement. Four-argument
/// callers retain no-overwrite; x4/x5 are still unused (legacy gateways do
/// not initialize them). Other length bits remain the bounded byte count.
pub const sys_file_rename: u64 = 35;
pub const file_rename_replace: u64 = @as(u64, 1) << 63;
/// Milestone 13 (claim 5801): `sys_file_truncate(handle, size)` — slot 36.
pub const sys_file_truncate: u64 = 36;
/// Milestone 13 (claim 5801): `sys_file_free(volume)` — slot 37.
pub const sys_file_free: u64 = 37;
/// Milestone 14 (claim 0169): `sys_clipboard_set(buf_ptr, len)` — slot 38.
pub const sys_clipboard_set: u64 = 38;
/// Milestone 14 (claim 0169): `sys_clipboard_get(buf_ptr, max)` — slot 39.
pub const sys_clipboard_get: u64 = 39;
/// Milestone 14 (claim 7323): `sys_timer_set(delay_ticks)` — slot 40.
pub const sys_timer_set: u64 = 40;
/// Milestone 14 (claim 7323): `sys_timer_cancel()` — slot 41.
pub const sys_timer_cancel: u64 = 41;
/// Milestone 15 (claim 7636): `sys_audio_info(out_ptr)` — slot 42.
pub const sys_audio_info: u64 = 42;
/// Milestone 15 (claim 7636): `sys_audio_play(ptr, len)` — slot 43.
pub const sys_audio_play: u64 = 43;
/// M15 follow-up (claim 9297): `sys_audio_volume(vol)` — slot 44.
pub const sys_audio_volume: u64 = 44;
/// M15 follow-up (claim 9297): `sys_audio_mute(muted)` — slot 45.
pub const sys_audio_mute: u64 = 45;
/// Step 2 (Issue #205): `sys_win_fill_batch(buf_ptr, buf_len)` — slot 46.
pub const sys_win_fill_batch: u64 = 46;
/// Arc2 W1 (claim 3589, ADR 0013 D1): `sys_win_resize(id, w, h)` — slot 47.
pub const sys_win_resize: u64 = 47;
/// Arc4 #238 (ADR 0013 D1): `sys_win_raise_front(id)` — slot 49.
pub const sys_win_raise_front: u64 = 49;
/// Arc4 #238 (ADR 0013 D1): `sys_win_lower_back(id)` — slot 50.
pub const sys_win_lower_back: u64 = 50;
/// Arc4 #240 (ADR 0013 D1): `sys_notify(text_ptr, text_len, level)` — slot 51.
pub const sys_notify: u64 = 51;
/// Arc4 #242 (ADR 0013 D1): `sys_win_set_unsaved(id, flag)` — slot 53.
pub const sys_win_set_unsaved: u64 = 53;
/// Arc5 #246: `sys_setrlimit(type, value)` — slot 54 (self-only, ADR 0024 D10).
pub const sys_setrlimit: u64 = 54;
/// M21 W12 (ADR 0013 D1): `sys_win_set_title(id, text_ptr, text_len)` — slot 61.
pub const sys_win_set_title: u64 = 61;
/// Arc4 #237 (ADR 0013 D1): `sys_drag_read(buf_ptr, max_len)` — slot 55.
pub const sys_drag_read: u64 = 55;
pub const sys_pipe_read: u64 = 56;
pub const sys_pipe_write: u64 = 57;
/// M20-U1 (claim 5127): `sys_font_size(window_id, size)` — slot 58.
/// size 0=8×8 small, 1=16×16 medium, 2=24×24 large; EINVAL for anything
/// else. Only window 0 (the terminal) renders through the kernel text
/// layer today; other ids get EINVAL.
pub const sys_font_size: u64 = 58;
/// M26 N1 (issue #399): `sys_ping_send(ip)` — slot 59. Send one ICMP echo
/// request to `ip` (low 32 bits network order). Returns 0 on success;
/// EINVAL for no peer / no IP / not ready.
pub const sys_ping_send: u64 = 59;
/// M26 N1 (issue #399): `sys_ping_poll()` — slot 60. Drain RX and report
/// whether a pong has landed since the last send. Returns the last echo
/// reply sequence (u16) if a pong was observed, else 0.
pub const sys_ping_poll: u64 = 60;
/// M26 N2 (issue #400): `sys_net_stats(buf_ptr, buf_len)` — slot 62.
/// Copy a fixed packed snapshot of the kernel's network state OUT through
/// uaccess (a read-only view, `sys_procs` style): interface MAC/IP/GW,
/// DHCP lease state, the TCP connection state/peer/IP/port + segment
/// counters, UDP listeners + datagram counters, the ARP table, and the
/// virtio-net RX/TX counters. Returns bytes copied; EFAULT for a bad
/// buffer; EINVAL for a non-EL0 caller. `buf_len` floors to whole
/// snapshots; `buf_len < snapshot size` copies nothing (honest
/// truncation, like the process table's whole-rows rule).
pub const sys_net_stats: u64 = 62;
/// M29 (issue #598): sys_mmap(addr, len, prot, flags) — slot 63.
pub const sys_mmap: u64 = 63;
/// M29 (issue #598): sys_munmap(addr, len) — slot 64.
pub const sys_munmap: u64 = 64;
/// M32 WMS2 (issue #622, ADR 0015 seam A): `sys_wmctl(cmd, a0, a1, a2,
/// ptr, len)` — slot 65. The REGISTERED WM server's exclusive control
/// surface over the kernel render server. Subcommand encoding frozen by
/// WMS1 (claim 1484) in the ADR 0007 amendment: 1=REGISTER, 2=SET_WINDOW,
/// 3=REQUEST_PRESENT. Calls from any process other than the registered WM
/// return EACCES; no WM registered → ENOSYS; unknown cmd → EINVAL.
pub const sys_wmctl: u64 = 65;
/// #1058: `sys_time()` returns the current Unix wall-clock seconds (the
/// boot loader's EFI GetTime epoch advanced by 1 Hz uptime). No arguments;
/// ENOSYS when the firmware gave no epoch (the caller's uptime fallback).
/// The first post-WM ADR 0007 slot; the ABI shape is otherwise unchanged.
pub const sys_time: u64 = 66;
/// #1072 (ADR 0020): `sys_tty_attach(front_end)` — attach (or detach) the
/// CALLING process's controlling terminal (`/dev/tty`) to a front-end.
/// a0: 0 = detach, 1 = the serial console. The terminal seam's only new
/// slot; terminal I/O itself reuses `sys_file_*`.
pub const sys_tty_attach: u64 = 67;
/// M50 TS1 (issue #1135, ADR 0024 D2/D10): `sys_principal(buf)` — slot 68.
/// Copy the CALLING process's principal `{ u32 uid, u32 caps }` (8 bytes LE)
/// OUT through uaccess. Read-only: there is no syscall to set uid/caps. The
/// M50 trust milestone's first additive slot.
pub const sys_principal: u64 = 68;
/// The fixed `sys_principal` payload shape: two u32 LE words (uid, caps).
pub const principal_bytes: usize = 8;
/// M50 TS2 (issue #1136, ADR 0024 D3/D4/D10): `sys_file_mode(path, mode)` —
/// slot 69. Owner-only chmod on an existing path, or `CAP_FS_ANY`; there is
/// NO chown. Persists the metadata to `OWNERS.TXT`; a full 64-entry table is
/// `ENOSPC`. The only additive slot TS2 introduces.
pub const sys_file_mode: u64 = 69;
/// M50 TS5 (issue #1139, ADR 0024 D8/D10): `sys_secret_get(buf, len)` —
/// slot 70. Return the CALLING principal's entries from the `SECRETS.TXT`
/// store into caller memory through uaccess. The ONLY in-guest reader of
/// the secret store; there is deliberately NO `sys_secret_set` (provisioning
/// is host-side; a non-echoing set path is deferred per D8). Excluded from
/// strace argument/return tracing (never-logged contract).
pub const sys_secret_get: u64 = 70;
/// M50 TS4 (issue #1138, ADR 0024 D6/D10): `sys_tty_net_auth(op, buf, len)` —
/// slot 71. The delegated net-auth channel: op 0 copies the fresh challenge
/// OUT, op 1 copies the buffered client reply line OUT, op 2 copies the
/// process's accept/reject verdict IN. The caller must own the attached net
/// terminal. Excluded from strace argument/return tracing (never-logged
/// contract).
pub const sys_tty_net_auth: u64 = 71;
/// The op selectors of slot 71 (ADR 0007 amendment).
pub const net_auth_op_challenge: u64 = 0;
pub const net_auth_op_response: u64 = 1;
pub const net_auth_op_verdict: u64 = 2;
/// M51 SSH-P1 (issue #1166, ADR 0025 D5): `sys_getrandom(buf, len)` — slot
/// 72, the EL0 entropy read and the ONLY syscall M51 adds. Fills caller
/// memory from the kernel CSPRNG (`csprng.random_bytes`) through uaccess.
/// READ-ONLY: it can never seed, reseed, or weaken the stream, needs **no
/// capability** (every principal may read entropy), and there is
/// deliberately no `sys_seed`. `len` is clamped to `getrandom_max` (a longer
/// request is never refused — the caller loops), `len == 0` returns 0
/// without touching the buffer, `EFAULT` answers a bad buffer, and `EINVAL`
/// answers a non-process (EL1h) caller. Slot 72 is a SINGLE SHARED CONTRACT:
/// the GOOS=virelai Go runtime (#1163) consumes the same slot for its hash
/// seed rather than adding a second entropy syscall. Registered but never
/// called on the boot path (ADR 0025 D9).
pub const sys_getrandom: u64 = 72;
// ADR 0027 (ACCEPTED 2026-09-12, issue #1214 round 2): slots 73/74 — the
// GOOS=virelai thread + futex seam. Op-based: sys_thread(op, ...), op 0
// create / op 1 exit; sys_futex(op, uaddr, val, timeout_ns), op 0 wait /
// op 1 wake(n). See the ADR 0007 amendment + ADR 0027 D3/D4.
pub const sys_thread: u64 = 73;
pub const sys_futex: u64 = 74;
// Issue #1228 (phase 0c): slot 75 — the EL0 fault-handler register. A
// single argument (no ops): nonzero installs, zero clears. See the ADR
// 0007 amendment + the delivery contract in exceptions.zig
// (`fault_deliverable`).
pub const sys_exnotify: u64 = 75;
// Issue #1163 (phase 2): slot 76 — the socket-readiness seam for the
// GOOS=virelai netpoll. Op-based: sys_sock_ready(op, want, timeout_ns),
// op 0 poll / op 1 park-until-ready-or-deadline. See the ADR 0007
// append-only amendment (2026-09-15, phase 2).
pub const sys_sock_ready: u64 = 76;
// M66a (#1443): slot 77 — sys_file_sync(fd). ADR 0007 append-only
// amendment (2026-09-18): the HF3 FSYNC op (0x08) existed only below the
// syscall seam (kernel-internal consumers); this row hands the durability
// verb to EL0 so a Go app can push its /host writes to the host's live fd
// before it trusts them. One argument (the fd); no ops. See the ADR 0007
// amendment + file_table.sync.
pub const sys_file_sync: u64 = 77;
// M83b (#1775): slot 78 — sys_time_set(epoch_secs). ADR 0007 append-only
// amendment (2026-09-28): slot 66 reads the wall clock and takes no
// arguments, so it cannot also carry a write (existing callers do not
// zero a0). This row hands EL0 one bounded write: re-anchor the wall clock
// so slot 66 reads `epoch_secs` now.
pub const sys_time_set: u64 = 78;
/// B3: one bounded native metadata/contained-filesystem operation family.
pub const sys_fs_metadata: u64 = 79;
pub const sys_socket: u64 = 80;
pub const sys_trace: u64 = abi.number("sys_trace");
pub const sys_profile: u64 = abi.number("sys_profile");
pub const sys_memstat: u64 = abi.number("sys_memstat");
pub const native_socket = @import("socket_native.zig");
var socket_scratch: [tcp.payload_max]u8 = undefined;
/// The fixed per-call fill cap of slot 72 (ADR 0025 D5: "capped at a bounded
/// maximum"). 256 matches `write_cap` — enough for an ephemeral X25519
/// secret (32 B), a KEXINIT cookie (16 B), or a burst of per-packet padding,
/// while keeping the BSS staging buffer and one `copy_out` small. A longer
/// request is clamped, never refused.
pub const getrandom_max: usize = 256;

// ---------------------------------------------------------------------------
// M50 TS3 (#1137, ADR 0024 D5/D10): the capability gate table
// ---------------------------------------------------------------------------

/// One auditable row of the dangerous-syscall gate surface: `number` is an
/// EXISTING slot (ADR 0007 never renumbers) and `cap` the capability its
/// dangerous use requires. The set is bounded and starts at exactly ADR
/// 0024 D10's gated set — one row today. `sys_exec` (28) is allowed for
/// `uid_user` and preserves uid/caps (TS1); the `sys_file_*` family
/// (23–27, 34–37) enforces D3/D4 inside `trust.check`; `sys_tty_attach`
/// (67) keeps its owner checks (TS4); `sys_wmctl` (65) and shared-anon
/// mmap (63/64) already hold; `sys_setrlimit` (54) is self-only. A future
/// gate is one row here plus the handler's explicit `gated()` query —
/// never a silent default.
pub const CapabilityGate = struct {
    /// The gated syscall slot.
    number: u64,
    /// The capability the caller must hold for the gated use.
    cap: u32,
};

/// The D10 gated set. `sys_kill` needs `CAP_PROC_ADMIN` only for a
/// CROSS-principal target: self and same-uid kills are allowed for every
/// principal, so `handle_kill` consumes `gated(sys_kill)` after its
/// same-principal test, when the rule applies. M97g (#2082) gates the two
/// programmatic clipboard slots unconditionally — the kernel-internal
/// paths (chrome chords, the monitor `clip` command) never reach the
/// handlers, so the cap cannot shadow a legitimate gesture. Gated rows are
/// unconditional capabilities; the handler owns the conditional shape.
pub const capability_gates = [_]CapabilityGate{
    .{ .number = sys_kill, .cap = process.cap_proc_admin },
    .{ .number = sys_clipboard_set, .cap = process.cap_clipboard },
    .{ .number = sys_clipboard_get, .cap = process.cap_clipboard },
};

/// The capability `number` requires for its gated use, or null when the
/// syscall is not capability-gated. The ONE lookup consumed at the syscall
/// seam; a linear scan over a bounded, explicit table.
pub fn gated(number: u64) ?u32 {
    for (capability_gates) |gate| {
        if (gate.number == number) return gate.cap;
    }
    return null;
}

pub const ErrorCode = enum(i64) {
    einval = -1,
    ebadf = -2,
    efault = -3,
    enosys = -4,
    enospc = -5,
    enoent = -6,
    eacces = -7,
    enametoolong = -8,
    enxio = -9, // "no such device" — the sys_audio_* seam's honest no-device refusal
    enomem = -10, // "out of memory"
    // ADR 0007 amendment (2026-09-12, issue #1214 round 2 — slots 73/74):
    eagain = -11, // futex wait: the user word no longer holds the expected value
    etimedout = -12, // futex wait or explicit outbound connect deadline expired
};

pub fn error_result(code: ErrorCode) u64 {
    return @bitCast(@intFromEnum(code));
}

pub const Args = [6]u64;
pub const Writer = *const fn ([]const u8) void;
const Handler = *const fn (Args, *exceptions.VectorFrame) u64;

const Entry = struct {
    name: []const u8 = "",
    handler: ?Handler = null,
    reportable: bool = true,
};

pub const EntryInfo = struct {
    number: u64,
    name: []const u8,
    calls: u64,
};

pub var table_storage: [slot_count]Entry = undefined;
var table_ready = false;
var call_counts: [svclock.cores][slot_count]u64 = [_][slot_count]u64{[_]u64{0} ** slot_count} ** svclock.cores;
var write_fn: ?Writer = null;
/// M22 D5 (issue #328): when set, dispatch() prints one line per syscall
/// issued by that pid. Armed by the monitor's `strace` command around an
/// exec; cleared by `strace off`.
pub var strace_pid: ?usize = null;
/// Card 4a (claim 5799): fixed BSS scratch for the process snapshot —
/// `max_processes` rows × 40 bytes, marshaled per call, no allocation.
var procs_scratch: [process.max_processes * process.snapshot_row_bytes]u8 = undefined;
/// M50 TS1 (#1135): fixed BSS scratch for the `sys_principal` reply — two
/// u32 LE words (uid, caps), marshaled per call, no allocation.
var principal_scratch: [principal_bytes]u8 = undefined;
/// M50 TS5 (#1139): fixed BSS scratch for the `sys_secret_get` reply — the
/// caller's entries as fixed `SecretRecord`s, marshaled per call, no
/// allocation. Values live in kernel BSS only long enough to be copied out
/// through uaccess; nothing here is ever logged.
var secret_scratch: [secret.max_secret_entries * secret.record_bytes]u8 = undefined;
/// M51 SSH-P1 (#1166, ADR 0025 D5): fixed BSS staging for the
/// `sys_getrandom` fill — `getrandom_max` bytes generated by the kernel
/// CSPRNG, copied to the caller's memory through uaccess only. No
/// allocation; the buffer is transient kernel BSS and is overwritten on
/// every call (nothing here is ever logged).
var getrandom_scratch: [getrandom_max]u8 = undefined;
/// Card N6 (claim 1384): fixed BSS scratch for the UDP send payload and
/// the recv peek — `payload_max` / `datagram_max` bytes, marshaled per
/// call, no allocation (the ipc staging pattern).
var udp_send_staging: [udp.payload_max]u8 = undefined;
var udp_recv_scratch: [udp.datagram_max]u8 = undefined;
/// Milestone 12 (claim 7483): fixed BSS scratch for TCP send payload.
var tcp_send_staging: [tcp.payload_max]u8 = undefined;
/// Milestone 14 (claim 0169): fixed BSS scratch for the clipboard (set
/// staging + get read-back), marshaled per call, no allocation.
var clipboard_staging: [clipboard.capacity]u8 = undefined;

/// Initialize the writer seam, reset counters and the uaccess regions. The
/// table remains a runtime-built BSS object; rebuilding is unnecessary once
/// its PC-relative addresses have been materialized at the current image
/// base.
pub fn init(writer: Writer) void {
    write_fn = writer;
    trace.init(writer, &strace_pid);
    for (0..svclock.cores) |c| @memset(&call_counts[c], 0);
    uaccess.init();
    clipboard.init();
    _ = ensure_table();
}

/// Configure the two claim-8215 apertures already mapped for EL0 (user text
/// read-only, user stack read-write). Delegated to the claim-6120 uaccess
/// layer, which owns the EFAULT contract and the fault-recovery window.
pub fn set_user_regions(text: userspace.Region, stack: userspace.Region) void {
    uaccess.set_regions(
        .{ .base = text.base, .len = text.len },
        .{ .base = stack.base, .len = stack.len },
    );
}

pub fn ensure_table() *const [slot_count]Entry {
    if (!table_ready) {
        for (&table_storage) |*entry| entry.* = .{};
        inline for (abi.slots, 0..) |slot, index| {
            table_storage[slot.number] = .{
                .name = abi.slots[index].name(),
                .handler = handler_for(slot.number),
                .reportable = switch (slot.number) {
                    sys_trace => trace.implemented,
                    sys_profile => sampler.implemented,
                    sys_memstat => memstat.implemented,
                    else => true,
                },
            };
        }
        table_ready = true;
    }
    return &table_storage;
}

// Compile-time selection, runtime pointer materialization: never a const
// handler-pointer table in the flat kernel image.
fn handler_for(comptime number: u64) Handler {
    return switch (number) {
        sys_ping => handle_ping,
        sys_write => handle_write,
        sys_yield => handle_yield,
        sys_exit => handle_exit,
        sys_sleep => handle_sleep,
        sys_ipc_send => handle_ipc_send,
        sys_ipc_recv => handle_ipc_recv,
        sys_procs => handle_procs,
        sys_wait => handle_wait,
        sys_udp_listen => handle_udp_listen,
        sys_udp_send => handle_udp_send,
        sys_udp_recv => handle_udp_recv,
        sys_win_open => handle_win_open,
        sys_win_fill => handle_win_fill,
        sys_win_present => handle_win_present,
        sys_win_close => handle_win_close,
        sys_win_move => handle_win_move,
        sys_win_raise => handle_win_raise,
        sys_win_get => handle_win_get,
        sys_win_query => handle_win_query,
        sys_win_set_visible => handle_win_set_visible,
        sys_poll_event => handle_poll_event,
        sys_wait_event => handle_wait_event,
        sys_file_open => handle_file_open,
        sys_file_read => handle_file_read,
        sys_file_write => handle_file_write,
        sys_file_close => handle_file_close,
        sys_dir_list => handle_dir_list,
        sys_exec => handle_exec,
        sys_kill => handle_kill,
        sys_tcp_connect => handle_tcp_connect,
        sys_tcp_send => handle_tcp_send,
        sys_tcp_recv => handle_tcp_recv,
        sys_tcp_close => handle_tcp_close,
        sys_file_delete => handle_file_delete,
        sys_file_rename => handle_file_rename,
        sys_file_truncate => handle_file_truncate,
        sys_file_free => handle_file_free,
        sys_clipboard_set => handle_clipboard_set,
        sys_clipboard_get => handle_clipboard_get,
        sys_timer_set => handle_timer_set,
        sys_timer_cancel => handle_timer_cancel,
        sys_audio_info => handle_audio_info,
        sys_audio_play => handle_audio_play,
        sys_audio_volume => handle_audio_volume,
        sys_audio_mute => handle_audio_mute,
        sys_win_fill_batch => handle_win_fill_batch,
        sys_win_resize => handle_win_resize,
        48 => handle_drag_start,
        sys_win_raise_front => handle_win_raise_front,
        sys_win_lower_back => handle_win_lower_back,
        sys_notify => handle_notify,
        52 => handle_win_move_to_workspace,
        sys_win_set_unsaved => handle_win_set_unsaved,
        54 => handle_setrlimit,
        sys_drag_read => handle_drag_read,
        sys_pipe_read => handle_pipe_read,
        sys_pipe_write => handle_pipe_write,
        sys_font_size => handle_font_size,
        sys_ping_send => handle_ping_send,
        sys_ping_poll => handle_ping_poll,
        sys_win_set_title => handle_win_set_title,
        sys_net_stats => handle_net_stats,
        sys_mmap => handle_mmap,
        sys_munmap => handle_munmap,
        sys_wmctl => handle_wmctl,
        sys_time => handle_time,
        sys_tty_attach => handle_tty_attach,
        sys_principal => handle_principal,
        sys_file_mode => handle_file_mode,
        sys_secret_get => handle_secret_get,
        sys_tty_net_auth => handle_tty_net_auth,
        sys_getrandom => handle_getrandom,
        sys_thread => handle_thread,
        sys_futex => handle_futex,
        sys_exnotify => handle_exnotify,
        sys_sock_ready => handle_sock_ready,
        sys_file_sync => handle_file_sync,
        sys_time_set => handle_time_set,
        sys_fs_metadata => handle_fs_metadata,
        sys_socket => handle_socket,
        sys_trace => trace.handle,
        sys_profile => sampler.handle,
        sys_memstat => memstat.handle,
        else => @compileError("ABI row has no handler"),
    };
}

pub fn entry_info(number: u64) ?EntryInfo {
    if (number >= slot_count) return null;
    const entry = ensure_table()[number];
    if (entry.handler == null) return null;
    var total: u64 = 0;
    for (0..svclock.cores) |c| total +%= call_counts[c][number];
    return .{ .number = number, .name = entry.name, .calls = total };
}

pub fn call_count(number: u64) u64 {
    if (number >= slot_count) return 0;
    var total: u64 = 0;
    for (0..svclock.cores) |c| total +%= call_counts[c][number];
    return total;
}

/// The service-domain locks a syscall must hold, as an svclock bitmask
/// (claim 9498 follow-on). FILE/NET/WIN/EV syscalls take exactly their
/// own domain lock and contend only with same-domain work; the kernel
/// lock covers the registry/misc syscalls; sys_exit takes the full set so
/// its teardown runs under every lock it touches; sys_exec loads files
/// (FILE) AND registers a process (KERNEL). Syscalls with no shared
/// service state (ping/yield/sleep — scheduler locks
/// cover them) take nothing.
fn doms_of(number: u64) u5 {
    const f: u5 = svclock.dom_bit(.file);
    const n: u5 = svclock.dom_bit(.net);
    const w: u5 = svclock.dom_bit(.win);
    const e: u5 = svclock.dom_bit(.ev);
    const k: u5 = svclock.dom_bit(.kernel);
    return switch (number) {
        sys_udp_listen, sys_udp_send, sys_udp_recv, sys_tcp_connect, sys_tcp_send, sys_tcp_recv, sys_tcp_close, sys_sock_ready, sys_socket, sys_ping_send, sys_ping_poll, sys_net_stats => n,
        sys_file_open, sys_file_read, sys_file_write, sys_file_close, sys_dir_list, sys_file_delete, sys_file_rename, sys_file_truncate, sys_file_free, sys_file_sync, sys_fs_metadata => f,
        sys_exec => f | k,
        sys_trace => f | k, // M94b's atomic arm-and-exec needs both domains.
        sys_write => f,
        sys_win_open, sys_win_fill, sys_win_present, sys_win_close, sys_win_move, sys_win_raise, sys_win_get, sys_win_query, sys_win_set_visible, sys_win_fill_batch, sys_win_resize, 48, sys_win_raise_front, sys_win_lower_back, 52, sys_win_set_unsaved, sys_win_set_title, sys_drag_read, sys_font_size => w,
        sys_ipc_send, sys_ipc_recv, sys_poll_event, sys_wait_event, sys_timer_set, sys_timer_cancel, sys_notify, sys_wmctl => e,
        sys_procs, sys_wait, sys_kill, sys_clipboard_set, sys_clipboard_get, sys_audio_info, sys_audio_play, sys_audio_volume, sys_audio_mute, sys_pipe_read, sys_pipe_write, 54, sys_mmap, sys_munmap, sys_time, sys_time_set, sys_tty_attach, sys_principal, sys_secret_get, sys_tty_net_auth, sys_getrandom, sys_thread, sys_futex, sys_exnotify, sys_profile, sys_memstat => k,
        sys_exit => svclock.all_bits,
        else => 0,
    };
}

/// Dispatch one already-decoded syscall. In-range reserved slots are counted
/// and return ENOSYS; numbers beyond the fixed namespace return ENOSYS without
/// indexing the table. The caller writes this result into saved x0.
pub fn dispatch(number: u64, args: Args, frame: *exceptions.VectorFrame) u64 {
    if (number >= slot_count) return error_result(.enosys);
    // Service-domain locks (claim 9498 follow-on): take exactly the locks
    // of the subsystems this syscall touches, in canonical order (kernel
    // last). IRQ-masked holders always run to completion, so SVC context
    // may spin; the release lands on this return (a blocking syscall
    // still unwinds here: the scheduler staged another task's frame, and
    // the stub's eret goes to that frame after dispatch returns).
    // Reentrancy (a handler that internally re-dispatches) never happens
    // — handle_svc is the only production caller.
    const doms = doms_of(number);
    if (doms != 0) svclock.acquire_set(doms);
    defer if (doms != 0) svclock.release_set(doms);
    call_counts[svclock.core_id()][number] +%= 1;
    const handler = ensure_table()[number].handler orelse return error_result(.enosys);
    const traced_call = trace.before(number, args, frame);
    const result = handler(args, frame);
    trace.after(traced_call, number, args, result);
    return result;
}

/// Adapter registered through claim 8215's `set_svc_dispatcher` seam.
///
/// Claim 0826 (concurrent processes): arm the uaccess regions from the
/// CURRENT task's TCB at every SVC entry, so `sys_write` bounds always
/// follow the task that actually issued the call — with two live user
/// processes, the module-global regions set by the last root rebuild would
/// otherwise validate one process's stack against another's. EL1h tasks
/// never SVC, so their zero regions are inert. The ABI is untouched.
/// Re-arm the module-global uaccess view from the CURRENT task's TCB —
/// the exact sequence handle_svc runs at every SVC entry, exposed as a
/// seam so host tests can replicate the arming (issue #1163 A1: the
/// mmap-visibility regression test drives this directly).
pub fn arm_task_regions() void {
    const regions = scheduler.current_user_regions();
    if (regions.text.len != 0 or regions.stack.len != 0) {
        set_user_regions(regions.text, regions.stack);
        for (regions.extra_reads[0..regions.extra_read_count]) |r| {
            _ = uaccess.add_read_region(.{ .base = r.base, .len = r.len });
        }
        for (regions.extra_writes[0..regions.extra_write_count]) |r| {
            _ = uaccess.add_write_region(.{ .base = r.base, .len = r.len });
        }
    }
    // ADR 0027 review finding 2: mmap regions are PROCESS-scope. The TCB
    // extras above carry only the task's exec shapes; every mapped region
    // lives once on the process and is merged here, so a mapping made by
    // one M is visible to every other M of the process even when it lands
    // after that M's task was created (the old per-TCB registration missed
    // exactly that case). Capacity: 2 base + exec extras (<= 5) +
    // max_mmap_regions (16) fits the 26-slot per-core lists — the A1
    // tests pin the arithmetic, and the add_* false branch would mean
    // configuration drift.
    if (process.find_by_task(scheduler.current_id())) |pid| {
        var i: usize = 0;
        while (i < process.max_mmap_regions) : (i += 1) {
            const r = process.mmap_region_at(pid, i) orelse continue;
            if ((r.prot & 1) != 0) _ = uaccess.add_read_region(.{ .base = r.base_va, .len = r.len });
            if ((r.prot & 2) != 0) _ = uaccess.add_write_region(.{ .base = r.base_va, .len = r.len });
        }
    }
}

pub fn handle_svc(frame: *exceptions.VectorFrame, immediate: u16) bool {
    arm_task_regions();
    // exc_dispatch already staged this frame into resume_frame; pinning it
    // again here keeps host tests that call handle_svc directly honest, and
    // lets the trailing-write check below observe the caller's frame
    // pointer before a parking handler may publish it to the waker paths.
    exceptions.resume_frame[svclock.core_id()] = @intFromPtr(frame);
    var args: Args = undefined;
    for (&args, 0..) |*arg, reg| arg.* = exceptions.frame_read(frame, @intCast(reg));
    const number = exceptions.frame_read(frame, 8);
    const result = if (immediate == svc_immediate)
        dispatch(number, args, frame)
    else
        error_result(.enosys);
    // M97a F2 (issue #2093): when the handler parked the caller (sleep,
    // wait, wait_event, futex wait, thread join, yield, exit), the
    // rotation staged a SUCCESSOR's frame and resume_frame no longer
    // names this one. The handler pre-published the placeholder into x0
    // before the task became waker-visible; a wake/timeout patch may
    // already have landed — or the frame may already be executing again
    // on another core. The waker's patch must be the last write, so a
    // parked frame is never touched here.
    if (exceptions.resume_frame[svclock.core_id()] == @intFromPtr(frame))
        _ = exceptions.frame_write(frame, 0, result);
    return true;
}

/// Stub for reserved-but-unimplemented slots (ADR 0013). Returns
/// ENOSYS so the dispatch table can include forward-reserved rows
/// without crashing the `syscalls` report.
fn handle_enosys(_: Args, _: *exceptions.VectorFrame) u64 {
    return error_result(.enosys);
}

/// Arc5 issue #246: sys_setrlimit(type, value) — slot 54.
/// type 0 = memory pages limit, type 1 = CPU ticks limit.
/// Returns 0 on success, -1 on error.
fn handle_setrlimit(args: Args, _: *exceptions.VectorFrame) u64 {
    const rtype = args[0];
    const value = args[1];
    const current_pid = process.current() orelse return error_result(.eacces);
    if (process.setrlimit(current_pid, rtype, value)) {
        return 0;
    }
    return error_result(.einval);
}

fn handle_ping(args: Args, _: *exceptions.VectorFrame) u64 {
    return userspace.ping(args[0]);
}

fn handle_write(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] != 1 and args[0] != 2) return error_result(.ebadf);
    const stream = file_table.stream_base + args[0];
    const pid = process.find_by_task(scheduler.current_id());
    if (pid) |p| {
        const access = file_table.stream_access(p, stream, true);
        if (access < 0) return @bitCast(access);
        if (!file_table.stream_is_console(p, stream)) {
            return write_stream(p, stream, args[1], args[2]);
        }
    }
    const address = args[1];
    const len = @min(args[2], write_cap);
    if (len == 0) return 0;
    // Claim 6120: copy the user bytes into a kernel staging buffer through
    // the uaccess layer. A bad user pointer (out-of-region, overflow,
    // unmapped, permission) returns EFAULT without crashing EL1; the writer
    // never touches user memory directly.
    var buf: [write_cap]u8 = undefined;
    if (uaccess.copy_in(&buf, address, @intCast(len)) != .ok) return error_result(.efault);
    const writer = write_fn orelse return error_result(.einval);
    writer(buf[0..@intCast(len)]);
    return len;
}

fn write_stream(pid: usize, fd: u64, address: u64, count: u64) u64 {
    const access = file_table.stream_access(pid, fd, true);
    if (access < 0) return @bitCast(access);
    const is_console = file_table.stream_is_console(pid, fd);
    const take = @min(count, if (is_console) write_cap else 2048);
    if (take == 0) return 0;
    var staging: [2048]u8 = undefined;
    if (uaccess.copy_in(&staging, address, @intCast(take)) != .ok) return error_result(.efault);
    if (is_console) {
        const writer = write_fn orelse return error_result(.einval);
        writer(staging[0..@intCast(take)]);
        return take;
    }
    return @bitCast(file_table.stream_write(pid, fd, staging[0..@intCast(take)]));
}

fn handle_yield(_: Args, frame: *exceptions.VectorFrame) u64 {
    // #2093: yield saves this frame and may be re-selected on another
    // core before the dispatch unwinds; publish the result before the
    // park (same contract as sleep), never after.
    _ = exceptions.frame_write(frame, 0, 0);
    _ = scheduler.yield_current();
    return 0;
}

fn handle_sleep(args: Args, frame: *exceptions.VectorFrame) u64 {
    // Claim 0635: block the calling task for `args[0]` scheduler ticks. On
    // success the scheduler has parked this task (state=blocked) and staged
    // another task's frame, so the SVC exception return resumes the NEXT
    // task; the caller's own frame stays on its kernel stack and the
    // syscall return (0) lands when `wake_expired` moves it back to ready
    // and the ring resumes it — the same resume path as sys_yield.
    // A different core may wake and steal the parked caller before this
    // handler unwinds. Publish its success result before exposing the frame
    // to the scheduler, not after it could already have returned to EL0.
    _ = exceptions.frame_write(frame, 0, 0);
    if (!scheduler.sleep_current(args[0])) return error_result(.einval);
    return 0;
}

fn handle_exit(args: Args, _: *exceptions.VectorFrame) u64 {
    // Returning from this Zig function is only kernel control flow. On
    // success the scheduler has removed the caller from the runnable set and
    // staged another task's frame, so the SVC exception return never returns
    // to the terminated EL0 task.
    // #2098: the reserved statuses are kernel-produced encodings, not a
    // caller's to forge — a user 139 mints a crash receipt, 140/141 mint
    // rlimit receipts, and 137 poses as a kill attribution. The kernel's own
    // exits reach exit_current below this seam unchanged.
    const status = args[0];
    if (status == scheduler.reserved_kill_status or
        status == scheduler.reserved_fault_status or
        status == scheduler.reserved_mem_limit_status or
        status == scheduler.reserved_cpu_limit_status) return error_result(.einval);
    if (!scheduler.exit_current(status)) return error_result(.einval);
    return 0;
}

// ---------------------------------------------------------------------------
// Card 3f (claim 5965): the IPC mailbox — slots 5/6
// ---------------------------------------------------------------------------

/// `sys_ipc_send(target, buf, len)`: copy `len` bytes (≤ `mailbox.message_max`;
/// longer is truncated to the slot bound — documented + host-tested) from
/// the caller's region through uaccess into process `target`'s ring.
///
/// Error precedence: a zero-length send is a no-op returning 0; a target
/// outside the registry, free, or exited is `EINVAL` (a process can only
/// reach a LIVE process's mailbox); a bad user pointer is `EFAULT`; a full
/// ring is `ENOSPC` (-5) — checked before any bytes are copied so the
/// refusal never touches user memory. Returns the sent length on success
/// (the sys_write-style positive result).
fn handle_ipc_send(args: Args, _: *exceptions.VectorFrame) u64 {
    const target = args[0];
    const address = args[1];
    var len = args[2];
    if (len == 0) return 0;
    if (len > mailbox.message_max) len = mailbox.message_max; // documented truncation
    if (target >= process.max_processes) return error_result(.einval);
    const target_info = process.info(@intCast(target)) orelse return error_result(.einval);
    if (target_info.state == .exited) return error_result(.einval); // dead processes have no mailbox
    if (mailbox.pending(@intCast(target)) == mailbox.max_messages) return error_result(.enospc);
    var staging: [mailbox.message_max]u8 = undefined;
    if (uaccess.copy_in(&staging, address, @intCast(len)) != .ok) return error_result(.efault);
    switch (mailbox.send(@intCast(target), staging[0..@intCast(len)])) {
        .ok => return len,
        // Defensive: the full check above makes this unreachable; the ring
        // may only fill between the check and the enqueue if a concurrent
        // sender ran — impossible in this single-core, IRQ-masked SVC.
        .full => return error_result(.enospc),
    }
}

/// `sys_ipc_recv(buf, max)`: copy the caller's OWN oldest message out
/// through uaccess. `max` > `mailbox.message_max` is clamped to it
/// (documented); `max` shorter than the message copies that many bytes and
/// consumes the message (documented truncation). Empty → 0 (nothing
/// copied). The caller's process is resolved from the CURRENT task's
/// binding; an EL1h task (never a process) is `EINVAL`. The message is
/// peeked, copied out, and only then dropped — a bad recv buffer
/// (`EFAULT`) leaves the message queued.
fn handle_ipc_recv(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    var max = args[1];
    if (max == 0) return 0;
    if (max > mailbox.message_max) max = mailbox.message_max; // documented clamp
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (mailbox.pending(pid) == 0) return 0; // empty result
    var staging: [mailbox.message_max]u8 = undefined;
    const got = mailbox.peek(pid, &staging, @intCast(max)) orelse return 0;
    if (uaccess.copy_out(address, staging[0..got], got) != .ok) return error_result(.efault);
    mailbox.drop(pid);
    return got;
}

// ---------------------------------------------------------------------------
// Card 4a (claim 5799): process introspection — slot 7
// ---------------------------------------------------------------------------

/// `sys_procs(buf, max)`: copy a bounded snapshot of the process table
/// (id, name, state, exit status where set — one fixed 40-byte row per
/// NON-FREE descriptor, in id order) OUT into the caller's region through
/// uaccess. A read-only view — there is no write path. `max` truncates to
/// WHOLE rows (`floor(max / 40)`, the documented truncation result like
/// the ipc recv path): a partial row is never copied. `max == 0` → 0
/// rows. Returns the row count written; `EFAULT` for a bad `buf` (the
/// claim-6120 contract — the copy is validated before any state is
/// touched). The snapshot is marshaled into a fixed BSS scratch, so no
/// allocation and no caller-identity requirement (any EL0 task may read
/// the table).
fn handle_procs(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const max = args[1];
    if (max == 0) return 0;
    const rows = process.snapshot(&procs_scratch);
    if (rows == 0) return 0;
    const full_bytes = rows * process.snapshot_row_bytes;
    // Floor the requested byte count to whole rows (honest truncation).
    const take_bytes = @min(full_bytes, @as(usize, @intCast(max))) / process.snapshot_row_bytes * process.snapshot_row_bytes;
    if (take_bytes == 0) return 0;
    if (uaccess.copy_out(address, procs_scratch[0..take_bytes], take_bytes) != .ok) return error_result(.efault);
    return take_bytes / process.snapshot_row_bytes;
}

// ---------------------------------------------------------------------------
// M50 TS1 (issue #1135, ADR 0024 D2/D10): sys_principal — slot 68
// ---------------------------------------------------------------------------

/// `sys_principal(buf)`: copy the CALLING process's principal
/// `{ u32 uid, u32 caps }` (8 bytes LE) OUT through uaccess. READ-ONLY —
/// there is no counterpart that sets uid/caps, because only the kernel
/// assigns a principal (ADR 0024 D2/D5); the process must itself be a
/// process (an EL1h task is `EINVAL`). `EFAULT` for a bad buffer.
fn handle_principal(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const pr = process.principal(pid) orelse return error_result(.einval);
    std.mem.writeInt(u32, principal_scratch[0..4], pr.uid, .little);
    std.mem.writeInt(u32, principal_scratch[4..8], pr.caps, .little);
    if (uaccess.copy_out(address, &principal_scratch, principal_bytes) != .ok) return error_result(.efault);
    return principal_bytes;
}

// ---------------------------------------------------------------------------
// Card 4c (claim 9946): exit-status propagation — slot 8
// ---------------------------------------------------------------------------

/// `sys_wait(target)`: block the calling process until the process with id
/// `target` exits, then return its exit status. The caller must itself be
/// a process (an EL1h task is `EINVAL`); the target must exist and must
/// not be the caller (`EINVAL` — a process waiting on itself would never
/// exit while blocked; the kernel refuses the deadlock). A target that is
/// ALREADY exited returns its stored status immediately (no block); a
/// RUNNING target parks the caller via `scheduler.wait_current`, and the
/// exit path (`wake_waiters`) patches the observed status into the
/// caller's saved frame, so the syscall return lands with the status when
/// the ring resumes it — the same resume path as `sys_sleep`. A `created`
/// (loaded, not yet running) target is `EINVAL`: it has not started and
/// may never run (the exec rollback would leave a waiter blocked
/// forever), so the wait contract is live-or-already-exited only — never
/// a hang. Bounded, kernel-owned: no zombies, no fds, no POSIX wait
/// semantics; the status is a plain kernel-recorded number.
fn handle_wait(args: Args, frame: *exceptions.VectorFrame) u64 {
    const target = args[0];
    if (target >= process.max_processes) return error_result(.einval);
    const target_info = process.info(@intCast(target)) orelse return error_result(.einval);
    const caller = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (caller == target) return error_result(.einval);
    if (target_info.state == .exited) return target_info.exit_status;
    if (target_info.state == .created) return error_result(.einval);
    // #2093: the park publishes this frame to `wake_waiters` — stage the
    // placeholder BEFORE it can be patched so the waker's exit-status
    // write is the last one (handle_svc skips its trailing write once
    // resume_frame names the successor).
    _ = exceptions.frame_write(frame, 0, 0);
    if (!scheduler.wait_current(@intCast(target))) return error_result(.einval);
    // Placeholder: the caller's frame is saved and the next task staged;
    // `wake_waiters` overwrites this slot with the real status at exit.
    return 0;
}

// ---------------------------------------------------------------------------
// Card N6 (claim 1384): the UDP syscall seam — slots 9/10/11
// ---------------------------------------------------------------------------

/// `sys_udp_listen(port)`: bind the bounded kernel listen table
/// (`udp.listen_port` — the SAME table the monitor's `net udp listen`
/// uses) to `port`. Port 0 or > 65535 → EINVAL; a duplicate or full
/// table → EINVAL (the N5 layer's honest bool). Returns 0 on success.
/// No uaccess. Kernel-global: any EL0 task may bind any port (honest
/// bound, documented in the ADR 0007 amendment).
fn handle_udp_listen(args: Args, _: *exceptions.VectorFrame) u64 {
    const port = args[0];
    if (port == 0 or port > 0xffff) return error_result(.einval);
    if (!udp.listen_port(@truncate(port))) return error_result(.einval);
    return 0;
}

/// `sys_udp_send(ip, port, buf, len)`: send ONE UDP datagram to
/// `ip:port` from the FIXED source port 7000 (`udp.default_src_port` —
/// deterministic, the N5 shape). `ip` is the 4 octets in NETWORK byte
/// order in the low 32 bits of x0 (e.g. 10.0.0.2 = 0x0a000002 — the
/// kernel extracts the bytes explicitly, never a bitcast: AArch64 is
/// little-endian). `len` bytes (≤ `udp.payload_max`, truncated honestly
/// at the bound — the ipc send shape) are copied from `buf` through
/// uaccess into a fixed BSS staging buffer, then `net_udp_send` runs the
/// N5 path: an own-IP send takes the LOOPBACK path (no device round
/// trip), a peer send needs its MAC in the ARP table (`.no_peer` /
/// `.not_ready` / `.timeout` → EINVAL — the caller resolves the peer
/// first via `net arp <ip>` and may retry; the seam does NOT resolve
/// ARP). Port 0 → EINVAL. Bad `buf` → EFAULT. Zero length is a no-op
/// returning 0 (the ipc send shape). Returns the payload length sent.
fn handle_udp_send(args: Args, _: *exceptions.VectorFrame) u64 {
    const ip_raw = args[0];
    const dst_port = args[1];
    const address = args[2];
    var len = args[3];
    if (dst_port == 0 or dst_port > 0xffff) return error_result(.einval);
    if (len == 0) return 0;
    if (len > udp.payload_max) len = udp.payload_max; // documented truncation
    const ip: [4]u8 = .{
        @truncate(ip_raw >> 24),
        @truncate(ip_raw >> 16),
        @truncate(ip_raw >> 8),
        @truncate(ip_raw),
    };
    if (uaccess.copy_in(&udp_send_staging, address, @intCast(len)) != .ok) return error_result(.efault);
    var out_len: usize = 0;
    switch (virtio_net.net_udp_send(ip, @truncate(dst_port), udp_send_staging[0..@intCast(len)], &out_len)) {
        .ok => return len,
        .not_ready, .no_peer, .timeout => return error_result(.einval),
    }
}

/// `sys_udp_recv(port, buf, max)`: copy the oldest datagram for the
/// listener on `port` OUT through uaccess — the full 8-byte UDP header
/// + payload (the caller parses the header for the src port; the src IP
/// is not kept — honest bound, documented). Returns the copied length;
/// 0 when the ring is empty; EINVAL when not listening on `port`. `max`
/// clamps to `udp.datagram_max` (72); shorter copies truncate and
/// CONSUME (the ipc recv shape). The datagram is PEEKED, copied out, and
/// only then popped — a bad recv buffer (`EFAULT`) leaves it queued
/// (the claim-5965 contract). The device is DRAINED FIRST (the
/// claim-6076 polled-drain contract — the net device's used-buffer IRQ
/// is unobserved): a recv pulls any waiting frame device → ring
/// synchronously, so an EL0 polling loop is self-sufficient without the
/// shell idle loop (the monitor's drain-before-read pattern — observed
/// live: without the drain the answer sat in the device queue until a
/// `net` command drained it, and the program's poll starved).
fn handle_udp_recv(args: Args, _: *exceptions.VectorFrame) u64 {
    const port = args[0];
    const address = args[1];
    var max = args[2];
    if (max == 0) return 0;
    if (max > udp.datagram_max) max = udp.datagram_max; // documented clamp
    if (port == 0 or port > 0xffff) return error_result(.einval);
    virtio_net.net_rx_drain(); // the polled-drain contract (no-op unarmed)
    if (!udp.is_listening(@truncate(port))) return error_result(.einval);
    const d = udp.peek(@truncate(port)) orelse return 0; // empty ring
    const take = @min(@as(usize, @intCast(max)), d.len);
    if (uaccess.copy_out(address, d.bytes[0..take], take) != .ok) return error_result(.efault);
    _ = udp.pop(@truncate(port)); // consume (the EFAULT path preserved it)
    return @intCast(take);
}

// ---------------------------------------------------------------------------
// Card G6 (claim 0487): the draw/window syscall seam — slots 12/13/14
// ---------------------------------------------------------------------------

/// `sys_win_open(x, y, w, h)`: open a user window (the G5 window registry)
/// at screen position (x, y) with a pool-backed back-buffer exactly w×h
/// (WM1 #707: carved from the kernel page pool, freed at close), OWNED by
/// the calling process. Returns the window id (2..9); `EINVAL` for a
/// coordinate/word-size outside u32, geometry outside the scanout bounds,
/// an unarmed manager (no gpu — the default VM), or a non-process caller
/// (the syscall is only reachable from an EL0 program); `ENOSPC` (-5)
/// when all eight user slots are already open; `ENOMEM` (-10) when the
/// pool has no contiguous run for the buffer. The window auto-closes
/// when the owning process exits (the scheduler's exit path calls
/// `driving_award.close_owner`). No uaccess: plain numbers.
fn handle_win_open(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u32) or args[1] > std.math.maxInt(u32) or args[2] > std.math.maxInt(u32) or args[3] > std.math.maxInt(u32)) {
        return error_result(.einval);
    }
    const owner = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    return switch (driving_award.user_open(@truncate(args[0]), @truncate(args[1]), @truncate(args[2]), @truncate(args[3]), owner)) {
        .opened => |id| id,
        .invalid => error_result(.einval),
        .full => error_result(.enospc),
        .nomem => error_result(.enomem),
    };
}

/// `sys_win_fill(id, x, y, w, h, rgb)`: fill a rect (local coordinates) in
/// the CALLER'S user window's back-buffer with the 24-bit 0xRRGGBB color,
/// marking it dirty. Returns 0 on success; `EINVAL` for an unknown id, a
/// window the caller does NOT own (per-process ownership — a process can
/// only render into its own window), an out-of-range word, or a rect
/// outside the window bounds. No uaccess (the kernel owns the buffer; the
/// program never touches it directly).
fn handle_win_fill(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8) or args[1] > std.math.maxInt(u32) or args[2] > std.math.maxInt(u32) or args[3] > std.math.maxInt(u32) or args[4] > std.math.maxInt(u32) or args[5] > 0xffffff) {
        return error_result(.einval);
    }
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_fill(@truncate(args[0]), @truncate(args[1]), @truncate(args[2]), @truncate(args[3]), @truncate(args[4]), @truncate(args[5]))) {
        return error_result(.einval);
    }
    return 0;
}

/// Step 2 (Issue #205): `sys_win_fill_batch(buf_ptr, buf_len)` — slot 46.
/// Processes a packed array of fill rects in ONE SVC entry. Each rect is
/// 24 bytes: {id: u8, _pad: [3]u8, x: u32, y: u32, w: u32, h: u32, rgb: u32}.
/// Max 32 rects per batch (768 B). Returns the number of rects processed;
/// negative error on bad pointer or oversized batch.
fn handle_win_fill_batch(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_ptr = args[0];
    const buf_len = args[1];
    // Each rect is 24 bytes; max 32 rects (768 B).
    const rect_size: u64 = 24;
    const max_rects: u64 = 32;
    if (buf_len == 0 or buf_len > max_rects * rect_size or (buf_len % rect_size) != 0) {
        return error_result(.einval);
    }
    const num_rects = buf_len / rect_size;
    // Stack buffer for the batch (32 × 24 = 768 B).
    var batch: [32 * 24]u8 = undefined;
    const copy_len: usize = @intCast(buf_len);
    if (uaccess.copy_in(@ptrCast(&batch), buf_ptr, copy_len) == .fault) return error_result(.efault);
    var processed: u64 = 0;
    var i: u64 = 0;
    while (i < num_rects) : (i += 1) {
        const off = i * rect_size;
        const id = batch[off];
        if (id > std.math.maxInt(u8)) continue;
        const x = std.mem.readInt(u32, batch[off + 4 ..][0..4], .little);
        const y = std.mem.readInt(u32, batch[off + 8 ..][0..4], .little);
        const w = std.mem.readInt(u32, batch[off + 12 ..][0..4], .little);
        const h = std.mem.readInt(u32, batch[off + 16 ..][0..4], .little);
        const rgb = std.mem.readInt(u32, batch[off + 20 ..][0..4], .little);
        if (!win_owned_by_caller(id)) continue;
        if (driving_award.user_fill(id, x, y, w, h, rgb)) {
            processed += 1;
        }
    }
    return processed;
}

/// Arc2 W1 (claim 3589, ADR 0013 D1): `sys_win_resize(id, w, h)` — slot 47.
/// Resize the CALLER'S owned user window to (w, h), clamped to
/// 128×64..512×384 and on-scanout (the `user_resize` clamp), and emit
/// `WIN_RESIZE` (kind 10) to the owning pid. Returns 0 on success;
/// `EINVAL` for an unknown id, a non-user window, a window the caller does
/// NOT own, or an out-of-range word. Plain numbers, no uaccess.
fn handle_win_resize(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8) or args[1] > std.math.maxInt(u32) or args[2] > std.math.maxInt(u32)) {
        return error_result(.einval);
    }
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_resize(@truncate(args[0]), @truncate(args[1]), @truncate(args[2]))) {
        return error_result(.einval);
    }
    return 0;
}

/// `sys_win_present(id)`: mark the CALLER'S user window dirty so the
/// compositor blits its back-buffer on the next idle-loop pass (the
/// deferred-present discipline — the syscall never touches the gpu
/// directly; the shell idle loop's `driving_award.drain` composites).
/// Returns 0 on success; `EINVAL` for an unknown id or a window the caller
/// does NOT own.
fn handle_win_present(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_present(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// `sys_win_close(id)`: release a user window OWNED BY THE CALLER (the EL0
/// teardown seam — the monitor's `dui close` is the EL1h PRIVILEGED
/// equivalent that closes any user window; the EL0 syscall is
/// owner-restricted). Returns 0 on success; `EINVAL` for an unknown id, a
/// non-user window (the terminal + clock are fixed), or a window the
/// caller does NOT own.
pub fn handle_win_close(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_close(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// `sys_win_move(id, x, y)`: move the CALLER'S user window's top-left corner
/// to (x, y), CLAMPED inside the scanout (`driving_award.user_move` — a
/// window never moves off-screen). Returns 0 on success; `EINVAL` for an
/// unknown id, a window the caller does NOT own, an out-of-range word, or
/// an unarmed manager. No uaccess (plain numbers).
fn handle_win_move(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8) or args[1] > std.math.maxInt(u32) or args[2] > std.math.maxInt(u32)) {
        return error_result(.einval);
    }
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_move(@truncate(args[0]), @truncate(args[1]), @truncate(args[2]))) {
        return error_result(.einval);
    }
    return 0;
}

/// `sys_win_raise(id)`: raise the CALLER'S user window to the top of the
/// z-order (focus unchanged — tracked by id, the G5 discipline). Returns 0
/// on success; `EINVAL` for an unknown id or a window the caller does NOT
/// own.
fn handle_win_raise(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_raise(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// Arc4 #238 (slot 49): `sys_win_raise_front(id)` — raise the CALLER'S
/// user window to the top of the z-order (focus unchanged). Owner-
/// restricted; refused on fixed layers. Returns 0; EINVAL for unknown id,
/// non-user window, or a window the caller does NOT own.
fn handle_win_raise_front(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_raise_front(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// Arc4 #238 (slot 50): `sys_win_lower_back(id)` — lower the CALLER'S
/// user window to the bottom of the z-order (above fixed windows, below
/// all other user windows). Owner-restricted; refused on fixed layers.
/// Returns 0; EINVAL for unknown id, non-user window, or a window the
/// caller does NOT own.
fn handle_win_lower_back(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_lower_back(@truncate(args[0]))) return error_result(.einval);
    return 0;
}

/// Arc4 #240 (slot 51): `sys_notify(text_ptr, text_len, level)` — post a
/// desktop notification toast. `level` 0=info, 1=warning, 2=error.
/// Copies up to 280 bytes through uaccess into the bounded notification
/// FIFO (4 entries, drop-oldest). Returns 0; EINVAL for a non-process
/// caller or level > 2; EFAULT for a bad pointer.
fn handle_notify(args: Args, _: *exceptions.VectorFrame) u64 {
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    _ = pid;
    const text_addr = args[0];
    const text_len = args[1];
    const level: u8 = @truncate(args[2]);
    if (level > 2) return error_result(.einval);
    if (text_len > driving_award.notify_text_max) return error_result(.einval);
    if (text_len == 0) {
        // Empty notification is a no-op (honest).
        return 0;
    }
    // Copy text through uaccess.
    var buf: [driving_award.notify_text_max]u8 = undefined;
    const copy_len: usize = @min(text_len, driving_award.notify_text_max);
    if (uaccess.copy_in(buf[0..copy_len], text_addr, copy_len) != .ok) return error_result(.efault);
    driving_award.notify_push(buf[0..copy_len], level);
    return 0;
}

/// Arc4 #237 (slot 48): `sys_drag_start(buf_ptr, buf_len)` — store a drag
/// payload (up to 512 B) from the caller through uaccess. The compositor
/// delivers DRAG_ENTER/LEAVE/DROP events as the pointer crosses windows.
fn handle_drag_start(args: Args, _: *exceptions.VectorFrame) u64 {
    const owner = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const buf_addr = args[0];
    const buf_len: usize = @min(args[1], driving_award.drag_payload_max);
    if (buf_len == 0) return error_result(.einval);
    var buf: [driving_award.drag_payload_max]u8 = undefined;
    if (uaccess.copy_in(buf[0..buf_len], buf_addr, buf_len) != .ok) return error_result(.efault);
    driving_award.drag_start(buf[0..buf_len], owner);
    return 0;
}

/// M19 P1 (slot 56): sys_pipe_read — copy unread pipe bytes OUT through
/// uaccess. max_len clamped to capacity; empty pipe → 0; bad buffer → EFAULT.
/// M97g (#2081): reads touch only the CALLER'S per-process pipe — the shared
/// buffer let any app drain another's staged pipeline bytes.
fn handle_pipe_read(args: Args, _: *exceptions.VectorFrame) u64 {
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const buf_addr = args[0];
    const max_len: usize = @min(args[1], pipe.pipe_capacity);
    if (max_len == 0) return 0;
    const unread = pipe.el0_unread(pid) orelse return 0;
    if (unread.len == 0) return 0;
    const take = @min(unread.len, max_len);
    if (uaccess.copy_out(buf_addr, unread[0..take], take) != .ok) return error_result(.efault);
    pipe.el0_advance_read(pid, take);
    return @intCast(take);
}

/// M19 P1 (slot 57): sys_pipe_write — copy bytes into pipe through uaccess.
/// ENOSPC when full; EFAULT for bad buffer; EINVAL for oversized write.
/// M97g (#2081): writes land in the caller's own per-process pipe; a full
/// per-pid table refuses ENOSPC rather than sharing a stranger's buffer.
fn handle_pipe_write(args: Args, _: *exceptions.VectorFrame) u64 {
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const buf_addr = args[0];
    const len = args[1];
    if (len == 0) return 0;
    if (len > pipe.pipe_capacity) return error_result(.einval);
    const room = pipe.el0_append(pid) orelse return error_result(.enospc);
    if (len > room.len) return error_result(.enospc);
    if (uaccess.copy_in(room[0..@intCast(len)], buf_addr, @intCast(len)) != .ok) return error_result(.efault);
    pipe.el0_advance_write(pid, @intCast(len));
    return len;
}

/// M20-U1 (claim 5127, slot 58): `sys_font_size(window_id, size)` —
/// switch the terminal text layer between 8×8/16×16/24×24 and repaint.
/// EINVAL for any window other than the terminal (0) or a bad size.
fn handle_font_size(args: Args, _: *exceptions.VectorFrame) u64 {
    const win_id: u64 = args[0];
    const size: u64 = args[1];
    if (win_id != 0) return error_result(.einval);
    const s: fbtext.FontSize = switch (size) {
        0 => .small,
        1 => .medium,
        2 => .large,
        else => return error_result(.einval),
    };
    fbtext.set_font_size(s);
    driving_award.mark_terminal_dirty();
    _ = driving_award.composite();
    return 0;
}

/// M26 N1 (issue #399, slot 59): `sys_ping_send(ip)` — send one ICMP echo
/// request to `ip` (low 32 bits network order, e.g. 10.0.0.2 = 0x0a000002).
/// Uses the same `net_ping_request` path as the monitor's `net ping`
/// (ARP-resolved, own-IP check, `net_ready` guard). Returns 0 on success;
/// EINVAL when no IP set / peer not in ARP / transport not ready (the
/// caller should `net arp <ip>` first).
fn handle_ping_send(args: Args, _: *exceptions.VectorFrame) u64 {
    const ip_raw = args[0];
    const ip: [4]u8 = .{
        @truncate(ip_raw >> 24),
        @truncate(ip_raw >> 16),
        @truncate(ip_raw >> 8),
        @truncate(ip_raw),
    };
    var out_len: usize = 0;
    switch (virtio_net.net_ping_request(ip, &out_len)) {
        .ok => {
            virtio_net.ipv4.requests_sent += 1;
            virtio_net.ipv4.ping_seq +%= 1;
            return 0;
        },
        .not_ready, .no_peer => return error_result(.einval),
        .timeout => return error_result(.einval),
    }
}

/// M26 N1 (issue #399, slot 60): `sys_ping_poll()` — drain RX and report
/// whether a pong has landed. Returns the last echo reply sequence
/// (`ipv4.last_seq`, u16) if `pongs_observed > 0`, else 0. The caller
/// sends one ping and polls until the expected sequence appears.
fn handle_ping_poll(_: Args, _: *exceptions.VectorFrame) u64 {
    virtio_net.net_rx_drain();
    if (virtio_net.ipv4.pongs_observed == 0) return 0;
    return virtio_net.ipv4.last_seq;
}

// ---------------------------------------------------------------------------
// M26 N2 (issue #400): the net-stats snapshot — slot 62
// ---------------------------------------------------------------------------

/// The fixed packed snapshot exposed by `sys_net_stats`. All integers
/// little-endian; IPs are raw network-order bytes (`[4]u8`); MACs raw
/// bytes (`[6]u8`). Enums are their `@intFromEnum` naturals, pinned in
/// the doc comments. The userland mirror lives in
/// `user/src/lib/netstats.zig` — the host tests on both sides pin
/// `@sizeOf` and the key `@offsetOf`s so drift fails loudly.
pub const NetStats = extern struct {
    // ---- interface ---------------------------------------------------------
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 }, // the virtio-net MAC
    own_ip: [4]u8 = .{ 0, 0, 0, 0 }, // arp.own_ip (`net ip` or DHCP ACK)
    gateway: [4]u8 = .{ 0, 0, 0, 0 }, // dhcp.lease_gw; 0 = unset
    // ---- dhcp ---------------------------------------------------------------
    dhcp_state: u8 = 0, // 0 idle,1 selecting,2 requesting,3 bound,4 renewing,5 rebinding
    lease_ip: [4]u8 = .{ 0, 0, 0, 0 },
    lease_mask: [4]u8 = .{ 0, 0, 0, 0 },
    lease_server: [4]u8 = .{ 0, 0, 0, 0 },
    lease_secs: u32 = 0,
    // ---- TCP ----------------------------------------------------------------
    tcp_state: u8 = 0, // 0 idle,1 listen,2 syn_sent,3 syn_received,4 established,5 fin_sent,6 closed (the tcp.State enum naturals)
    tcp_peer_ip: [4]u8 = .{ 0, 0, 0, 0 },
    tcp_peer_port: u16 = 0,
    // ---- UDP ----------------------------------------------------------------
    udp_count: u8 = 0, // valid listen entries (0..4)
    udp_ports: [4]u16 = .{ 0, 0, 0, 0 }, // ports of the valid entries, packed
    // ---- ARP ----------------------------------------------------------------
    arp_count: u8 = 0, // valid table entries (0..4)
    arp_ips: [4][4]u8 = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } },
    arp_macs: [4][6]u8 = .{ .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 0, 0 } },
    // ---- counters -----------------------------------------------------------
    tx_frames: u64 = 0,
    tx_bytes: u64 = 0,
    rx_frames: u64 = 0,
    rx_bytes: u64 = 0,
    rx_filtered: u64 = 0,
    rx_overflow: u64 = 0,
    // tcp segment counters: syn_sent, synack_recv, ack_sent, data_sent,
    // data_recv, fin_sent, finack_recv, rst_sent
    tcp_segs: [8]u64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    // udp datagram counters: received, sent, loopbacked, dropped
    udp_dgrams: [4]u64 = .{ 0, 0, 0, 0 },
};

pub const net_stats_bytes: usize = @sizeOf(NetStats);
var netstats_scratch: [net_stats_bytes]u8 = undefined;

/// `sys_net_stats(buf, len)` — marshal the live network state into the
/// fixed scratch and copy it OUT through uaccess (read-only view, nobody
/// owns the data). EFAULT on a bad buffer; 0 for a buffer too small for
/// one whole snapshot.
fn handle_net_stats(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const max = args[1];
    if (max < net_stats_bytes) return 0;

    var snap: NetStats = .{};
    snap.mac = virtio_net.net_mac;
    snap.own_ip = arp.own_ip;
    snap.gateway = dhcp.lease_gw;
    snap.dhcp_state = @intFromEnum(dhcp.state);
    snap.lease_ip = dhcp.lease_ip;
    snap.lease_mask = dhcp.lease_mask;
    snap.lease_server = dhcp.lease_server;
    snap.lease_secs = dhcp.lease_time;
    snap.tcp_state = @intFromEnum(tcp.state);
    snap.tcp_peer_ip = tcp.peer_ip;
    snap.tcp_peer_port = tcp.peer_port;
    var udp_i: usize = 0;
    for (udp.listen) |e| {
        if (e.valid and udp_i < 4) {
            snap.udp_ports[udp_i] = e.port;
            udp_i += 1;
        }
    }
    snap.udp_count = @intCast(udp_i);
    var arp_i: usize = 0;
    for (arp.table) |e| {
        if (e.valid and arp_i < arp.table_slots) {
            snap.arp_ips[arp_i] = e.ip;
            snap.arp_macs[arp_i] = e.mac;
            arp_i += 1;
        }
    }
    snap.arp_count = @intCast(arp_i);
    snap.tx_frames = virtio_net.net_dev.tx_frames;
    snap.tx_bytes = virtio_net.net_dev.tx_bytes;
    snap.rx_frames = virtio_net.rx_frames;
    snap.rx_bytes = virtio_net.rx_bytes;
    snap.rx_filtered = virtio_net.rx_filtered;
    snap.rx_overflow = virtio_net.rx_overflow;
    snap.tcp_segs = .{ tcp.syn_sent, tcp.synack_recv, tcp.ack_sent, tcp.data_sent, tcp.data_recv, tcp.fin_sent, tcp.finack_recv, tcp.rst_sent };
    snap.udp_dgrams = .{ udp.received, udp.sent, udp.loopbacked, udp.dropped_badsum + udp.dropped_closed + udp.dropped_len };

    // Marshal through the fixed scratch (no stack copies of untrusted
    // sizes; the struct is comptime-sized).
    @memcpy(&netstats_scratch, std.mem.asBytes(&snap));
    if (uaccess.copy_out(address, netstats_scratch[0..net_stats_bytes], net_stats_bytes) != .ok) return error_result(.efault);
    return net_stats_bytes;
}

/// Arc4 #237 (slot 55): `sys_drag_read(buf_ptr, max_len)` — copy the drag
/// payload OUT to the caller after receiving a DROP event. Consumes the
/// payload (one read only). Returns bytes copied, 0 if no payload.
fn handle_drag_read(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_addr = args[0];
    const max_len: usize = @min(args[1], driving_award.drag_payload_max);
    if (!driving_award.drag_is_active()) return 0;
    const payload = driving_award.drag_get_payload();
    const copy_len = @min(payload.len, max_len);
    if (copy_len == 0) return 0;
    if (uaccess.copy_out(buf_addr, payload[0..copy_len], copy_len) != .ok) return error_result(.efault);
    // Consume: clear the drag state.
    driving_award.drag_cancel();
    return @intCast(copy_len);
}

/// Arc4 #241 (slot 52): `sys_win_move_to_workspace(id, ws)` — move the
/// caller's window to workspace `ws` (0..2). EINVAL for out-of-range or
/// non-user window.
fn handle_win_move_to_workspace(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    const id: u8 = @truncate(args[0]);
    if (!win_owned_by_caller(id)) return error_result(.einval);
    const ws: u8 = @truncate(args[1]);
    if (ws >= driving_award.workspace_max) return error_result(.einval);
    if (!driving_award.user_move_to_workspace(id, ws)) return error_result(.einval);
    return 0;
}

/// `sys_win_set_title(id, text_ptr, text_len)`: set the dynamic title of
/// the caller's user window. Up to 63 bytes are copied from `text_ptr` into
/// the window's title buffer; the title is then visible in the taskbar and
/// Alt+Tab overlay. Returns 0; `EINVAL` for bad id or non-owner; `EFAULT`
/// for bad `text_ptr`.
fn handle_win_set_title(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    const id: u8 = @truncate(args[0]);
    if (!win_owned_by_caller(id)) return error_result(.einval);
    const ptr = args[1];
    const len = args[2];
    if (len > 64) return error_result(.einval);
    if (len > 0 and ptr == 0) return error_result(.einval);
    var buf: [64]u8 = undefined;
    if (len > 0) {
        if (uaccess.copy_in(&buf, ptr, @intCast(len)) != .ok) return error_result(.efault);
    }
    if (!driving_award.set_window_title(id, buf[0..len])) return error_result(.einval);
    return 0;
}

/// `sys_win_set_unsaved(id, flag)`: mark or clear the unsaved-changes flag
/// on the caller's window. When the flag is set and the user clicks the
/// close button, the compositor shows a Save/Don't Save/Cancel dialog
/// instead of closing immediately. `flag` 0 = clear, 1 = set.
fn handle_win_set_unsaved(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (args[1] > 1) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_set_unsaved(@truncate(args[0]), args[1] != 0)) return error_result(.einval);
    return 0;
}

/// `sys_win_get(id, buf)`: copy the CALLER'S user window's geometry
/// (x, y, w, h as four u32 LE words — `win_rect_bytes` 16) OUT through
/// uaccess, so an EL0 program can read its window's rect back after a
/// CLAMPED move (`sys_win_move` clamps silently; this is the read-back
/// seam). Returns 0; `EINVAL` for an unknown id, a non-user window (the
/// terminal + clock are fixed), or a window the caller does NOT own;
/// `EFAULT` for a bad `buf` (the claim-6120 contract — validated before
/// any bytes are written). The first pointer-taking win slot.
fn handle_win_get(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    const rect = driving_award.user_rect(@truncate(args[0])) orelse return error_result(.einval);
    var buf: [win_rect_bytes]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], rect.x, .little);
    std.mem.writeInt(u32, buf[4..8], rect.y, .little);
    std.mem.writeInt(u32, buf[8..12], rect.w, .little);
    std.mem.writeInt(u32, buf[12..16], rect.h, .little);
    if (uaccess.copy_out(args[1], buf[0..win_rect_bytes], win_rect_bytes) != .ok) return error_result(.efault);
    return 0;
}

/// `sys_win_query(id, buf)`: copy the CALLER'S user window's FULL state
/// (x, y, w, h, z, focused, visible, dirty as eight u32 LE words —
/// `win_query_bytes` 32) OUT through uaccess, so an EL0 program can
/// introspect its window end to end (z-order rank + focus + flags), not
/// just the rect. Returns 0; `EINVAL` for an unknown id, a non-user window
/// (the terminal + clock are fixed), or a window the caller does NOT own;
/// `EFAULT` for a bad `buf`. The second pointer-taking win slot.
fn handle_win_query(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    const q = driving_award.user_query(@truncate(args[0])) orelse return error_result(.einval);
    var buf: [win_query_bytes]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], q.x, .little);
    std.mem.writeInt(u32, buf[4..8], q.y, .little);
    std.mem.writeInt(u32, buf[8..12], q.w, .little);
    std.mem.writeInt(u32, buf[12..16], q.h, .little);
    std.mem.writeInt(u32, buf[16..20], q.z, .little);
    std.mem.writeInt(u32, buf[20..24], q.focused, .little);
    std.mem.writeInt(u32, buf[24..28], q.visible, .little);
    std.mem.writeInt(u32, buf[28..32], q.dirty, .little);
    if (uaccess.copy_out(args[1], buf[0..win_query_bytes], win_query_bytes) != .ok) return error_result(.efault);
    return 0;
}

/// `sys_win_set_visible(id, visible)`: hide (`visible` 0) or show (`visible`
/// 1) the CALLER'S user window — the window manager's visibility surface
/// from EL0 (`driving_award.user_set_visible`, owner-restricted like
/// fill/present/close). Hiding marks the terminal dirty so the next
/// composite repaints over the hidden window; showing marks the window
/// dirty so it reappears. Returns 0; `EINVAL` for an unknown id, a non-user
/// window (the terminal + clock are fixed), a window the caller does NOT
/// own, or a `visible` flag that is not 0/1. Plain numbers, no uaccess.
fn handle_win_set_visible(args: Args, _: *exceptions.VectorFrame) u64 {
    if (args[0] > std.math.maxInt(u8)) return error_result(.einval);
    if (args[1] > 1) return error_result(.einval);
    if (!win_owned_by_caller(@truncate(args[0]))) return error_result(.einval);
    if (!driving_award.user_set_visible(@truncate(args[0]), args[1] != 0)) return error_result(.einval);
    return 0;
}

/// True when the window `id` exists AND is owned by the process currently
/// making the syscall (the per-process ownership check behind fill/present/
/// close). False for an unknown id, a fixed (terminal/clock) window, or a
/// non-process caller.
fn win_owned_by_caller(id: u8) bool {
    const owner = process.find_by_task(scheduler.current_id()) orelse return false;
    const wowner = driving_award.user_owner(id) orelse return false;
    return owner == wowner;
}

/// `sys_poll_event(buf)`: non-blocking event poll. If an event is queued for
/// the calling process, pops it, copies the 16-byte `Event` structure to `buf`
/// via `uaccess.copy_out`, and returns `1`. If the queue is empty, returns `0`.
/// Returns `EFAULT` (-3) for an invalid user buffer, `EINVAL` (-1) if the
/// calling task is not a registered process.
fn handle_poll_event(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (events.pending(pid) == 0) return 0;
    const ev = events.peek(pid) orelse return 0;
    const ev_bytes: *const [events.event_bytes]u8 = @ptrCast(&ev);
    if (uaccess.copy_out(address, ev_bytes, events.event_bytes) != .ok) {
        return error_result(.efault);
    }
    events.drop(pid);
    return 1;
}

/// `sys_wait_event(buf)`: blocking event wait. If an event is queued for the
/// calling process, pops it, copies 16 bytes to `buf` via `uaccess.copy_out`,
/// and returns `1`. If the queue is empty, blocks the calling task in the
/// scheduler via `scheduler.wait_event_current` (rewinding PC so SVC re-runs on
/// wakeup). Returns `EFAULT` (-3) or `EINVAL` (-1).
fn handle_wait_event(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (events.pending(pid) == 0) {
        if (!scheduler.wait_event_current(pid)) return error_result(.einval);
        return 0; // Staged next task; will restart upon wakeup
    }
    const ev = events.peek(pid) orelse return 0;
    const ev_bytes: *const [events.event_bytes]u8 = @ptrCast(&ev);
    if (uaccess.copy_out(address, ev_bytes, events.event_bytes) != .ok) {
        return error_result(.efault);
    }
    events.drop(pid);
    return 1;
}

/// Milestone 10 (claim 3570): slot 23 — sys_file_open(path_ptr, path_len, flags)
fn handle_file_open(args: Args, _: *exceptions.VectorFrame) u64 {
    const path_ptr = args[0];
    const path_len = args[1];
    const flags: u32 = @truncate(args[2]);
    if (path_len == 0 or path_len > file_table.max_path_len) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);

    var path_buf: [file_table.max_path_len]u8 = undefined;
    if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);

    const res = file_table.open(pid, path_buf[0..path_len], flags);
    if (res < 0) {
        return @bitCast(res);
    }
    return @intCast(res);
}

/// B5: copies one 1–255-byte name before any lookup or mutation.
fn copy_fs_name(ptr: u64, len: u64, out: *[file_table.directory.name_max]u8) ?ErrorCode {
    if (len == 0) return .einval;
    if (len > out.len) return .enametoolong;
    if (uaccess.copy_in(out, ptr, @intCast(len)) != .ok) return .efault;
    return null;
}

/// Slot 79 B5 ops 8–14: (op, dir, name_ptr, name_len, x4, 0), plus
/// close (9, dir, 0…), handle metadata (10, handle, kind, 0, 0, out_ptr)
/// and rename (14, from_dir, from_ptr, to_dir, to_ptr, lengths|replace).
fn handle_fs_pinned(pid: u64, args: Args) u64 {
    const meta = file_table.metadata;
    const name_max = file_table.directory.name_max;
    switch (args[0]) {
        meta.pin_close_op => {
            if (args[2] != 0 or args[3] != 0 or args[4] != 0 or args[5] != 0) return error_result(.einval);
            return @bitCast(file_table.pin_close(pid, args[1]));
        },
        meta.handle_metadata_op => {
            if (args[3] != 0 or args[4] != 0) return error_result(.einval);
            var value: meta.Wire = undefined;
            const rc = file_table.handle_metadata(pid, args[1], args[2], &value);
            if (rc < 0) return @bitCast(rc);
            if (uaccess.copy_out(args[5], std.mem.asBytes(&value), @sizeOf(meta.Wire)) != .ok) return error_result(.efault);
            return 0;
        },
        meta.rename_op => {
            const packed_lengths = args[5];
            if ((packed_lengths & ~(meta.rename_replace | 0xffff_ffff)) != 0) return error_result(.einval);
            var from: [name_max]u8 = undefined;
            var to: [name_max]u8 = undefined;
            const from_len = packed_lengths & meta.rename_length_mask;
            const to_len = (packed_lengths >> 16) & meta.rename_length_mask;
            if (copy_fs_name(args[2], from_len, &from)) |code| return error_result(code);
            if (copy_fs_name(args[4], to_len, &to)) |code| return error_result(code);
            return @bitCast(file_table.pin_rename(pid, args[1], from[0..@intCast(from_len)], args[3], to[0..@intCast(to_len)], (packed_lengths & meta.rename_replace) != 0));
        },
        else => {},
    }
    if (args[5] != 0 or (args[0] != meta.remove_op and args[4] != 0)) return error_result(.einval);
    var name: [name_max]u8 = undefined;
    if (copy_fs_name(args[2], args[3], &name)) |code| return error_result(code);
    const bytes = name[0..@intCast(args[3])];
    const result: i64 = switch (args[0]) {
        meta.pin_child_op => file_table.pin_child(pid, args[1], bytes),
        meta.create_op => file_table.pin_create(pid, args[1], bytes),
        meta.mkdir_op => file_table.pin_mkdir(pid, args[1], bytes),
        meta.remove_op => file_table.pin_remove(pid, args[1], bytes, args[4]),
        else => return error_result(.einval),
    };
    return @bitCast(result);
}

/// Slot 79. Path operations: (op, root_ptr, root_len, relative_ptr,
/// relative_len, out_ptr). Open returns an ordinary fd. Page:
/// (5, token, offset, limit, out_ptr, 0). Close: (6, token, 0,0,0,0).
/// B5 op 7 pins a directory with the path form and x5 = 0.
fn handle_fs_metadata(args: Args, _: *exceptions.VectorFrame) u64 {
    const meta = file_table.metadata;
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (args[0] >= meta.pin_child_op and args[0] <= meta.rename_op) return handle_fs_pinned(pid, args);
    if (args[0] == meta.dir_page_op) {
        if (args[5] != 0) return error_result(.einval);
        var page: meta.Page = undefined;
        const n = file_table.metadata_dir_page(pid, args[1], args[2], args[3], &page);
        if (n < 0) return @bitCast(n);
        const len = @sizeOf(file_table.directory.Header) + @as(usize, @intCast(n)) * @sizeOf(meta.Entry);
        const bytes: [*]const u8 = @ptrCast(&page);
        if (uaccess.copy_out(args[4], bytes[0..len], len) != .ok) return error_result(.efault);
        return @intCast(n);
    }
    if (args[0] == meta.dir_close_op) {
        if (args[2] != 0 or args[3] != 0 or args[4] != 0 or args[5] != 0) return error_result(.einval);
        return @bitCast(file_table.dir_close(pid, args[1]));
    }
    if (args[0] > meta.dir_open_op and args[0] != meta.pin_open_op) return error_result(.einval);
    if (args[2] == 0) return error_result(.einval);
    if (args[2] > meta.max_guest_path or args[4] > meta.max_relative_path)
        return error_result(.enametoolong);
    if (args[0] >= meta.read_open_op and args[5] != 0) return error_result(.einval);
    var root: [meta.max_guest_path]u8 = undefined;
    var relative: [meta.max_relative_path]u8 = undefined;
    if (uaccess.copy_in(&root, args[1], @intCast(args[2])) != .ok) return error_result(.efault);
    if (args[4] != 0 and uaccess.copy_in(&relative, args[3], @intCast(args[4])) != .ok) return error_result(.efault);
    const root_path = root[0..args[2]];
    const path = relative[0..args[4]];
    const result: i64 = switch (args[0]) {
        meta.stat_op, meta.identity_op => blk: {
            var value: meta.Wire = undefined;
            const rc = file_table.metadata_at(pid, root_path, path, &value);
            if (rc < 0) break :blk rc;
            const bytes = if (args[0] == meta.identity_op) std.mem.asBytes(&value.identity) else std.mem.asBytes(&value);
            if (uaccess.copy_out(args[5], bytes, bytes.len) != .ok) return error_result(.efault);
            break :blk 0;
        },
        meta.read_open_op, meta.write_open_op => file_table.contained_open(pid, root_path, path, args[0] == meta.write_open_op),
        meta.dir_open_op => file_table.metadata_dir_open(pid, root_path, path),
        meta.pin_open_op => file_table.pin_open(pid, root_path, path),
        else => unreachable,
    };
    return @bitCast(result);
}

/// Milestone 10 (claim 3570): slot 24 — sys_file_read(fd, buf_ptr, count)
fn handle_file_read(args: Args, _: *exceptions.VectorFrame) u64 {
    const fd = args[0];
    const buf_ptr = args[1];
    const count = args[2];
    if (fd >= file_table.max_handles_per_process and !file_table.is_stream(fd)) return error_result(.ebadf);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (file_table.is_stream(fd)) {
        const access = file_table.stream_access(pid, fd, false);
        if (access < 0) return @bitCast(access);
    }
    if (count == 0) return 0;

    const take_count = @min(count, 2048);
    var read_staging: [2048]u8 = undefined;
    const res = if (file_table.is_stream(fd))
        file_table.stream_peek(pid, fd, read_staging[0..take_count])
    else if (file_table.is_contained(pid, fd))
        file_table.contained_peek(pid, fd, read_staging[0..take_count])
    else
        file_table.read(pid, fd, read_staging[0..take_count]);
    if (res < 0) {
        return @bitCast(res);
    }
    const bytes_read: usize = @intCast(res);
    if (bytes_read > 0) {
        if (uaccess.copy_out(buf_ptr, read_staging[0..bytes_read], bytes_read) != .ok) return error_result(.efault);
        if (file_table.is_stream(fd)) file_table.stream_advance(pid, fd, bytes_read);
        if (file_table.is_contained(pid, fd)) file_table.contained_advance(pid, fd, bytes_read);
    }
    return @intCast(bytes_read);
}

/// Milestone 10 (claim 3570): slot 25 — sys_file_write(fd, buf_ptr, count)
fn handle_file_write(args: Args, _: *exceptions.VectorFrame) u64 {
    const fd = args[0];
    const buf_ptr = args[1];
    const count = args[2];
    if (file_table.is_stream(fd)) {
        const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
        return write_stream(pid, fd, buf_ptr, count);
    }
    if (fd >= file_table.max_handles_per_process) return error_result(.ebadf);
    if (count > 2048) return error_result(.enospc);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (count == 0) return 0;

    var write_staging: [2048]u8 = undefined;
    if (uaccess.copy_in(&write_staging, buf_ptr, @intCast(count)) != .ok) return error_result(.efault);

    const res = file_table.write(pid, fd, write_staging[0..count]);
    if (res < 0) {
        return @bitCast(res);
    }
    return @intCast(res);
}

/// Milestone 10 (claim 3570): slot 26 — sys_file_close(fd)
fn handle_file_close(args: Args, _: *exceptions.VectorFrame) u64 {
    const fd = args[0];
    if (file_table.is_stream(fd)) {
        const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
        return @bitCast(file_table.stream_close(pid, fd));
    }
    if (fd >= file_table.max_handles_per_process) return error_result(.ebadf);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const res = file_table.close(pid, fd);
    if (res < 0) {
        return @bitCast(res);
    }
    return 0;
}

/// Milestone 10 (claim 3570): slot 27 — sys_dir_list(path_ptr, path_len, buf_ptr, max_entries)
fn handle_dir_list(args: Args, _: *exceptions.VectorFrame) u64 {
    if ((args[3] & file_table.directory.version) != 0) return handle_dir_v2(args);
    const path_ptr = args[0];
    const path_len = args[1];
    const buf_ptr = args[2];
    const max_entries = args[3];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (max_entries == 0) return 0;

    var path_buf: [file_table.max_path_len]u8 = undefined;
    if (path_len > 0) {
        if (path_len > file_table.max_path_len) return error_result(.enametoolong);
        if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);
    }

    const take_entries = @min(max_entries, 16);
    var entries_staging: [16]file_table.DirEntry = undefined;
    const res = file_table.dir_list(pid, if (path_len == 0) "" else path_buf[0..path_len], entries_staging[0..take_entries]);
    if (res < 0) {
        return @bitCast(res);
    }
    const populated: usize = @intCast(res);
    if (populated > 0) {
        const bytes_to_copy = populated * @sizeOf(file_table.DirEntry);
        const raw_bytes: [*]const u8 = @ptrCast(&entries_staging);
        if (uaccess.copy_out(buf_ptr, raw_bytes[0..bytes_to_copy], bytes_to_copy) != .ok) return error_result(.efault);
    }
    return @intCast(populated);
}

fn handle_dir_v2(args: Args) u64 {
    const dir = file_table.directory;
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const res: i64 = switch (args[3]) {
        dir.open_op => blk: {
            if (args[1] > file_table.max_path_len) return error_result(.enametoolong);
            var path: [file_table.max_path_len]u8 = undefined;
            if (args[1] > 0 and uaccess.copy_in(&path, args[0], @intCast(args[1])) != .ok)
                return error_result(.efault);
            break :blk file_table.dir_open(pid, path[0..args[1]]);
        },
        dir.page_op => blk: {
            var page: dir.Page = undefined;
            const count = file_table.dir_page(pid, args[0], args[1], args[4], &page);
            if (count < 0) break :blk count;
            const len = @sizeOf(dir.Header) + @as(usize, @intCast(count)) * @sizeOf(dir.Entry);
            const bytes: [*]const u8 = @ptrCast(&page);
            if (uaccess.copy_out(args[2], bytes[0..len], len) != .ok) return error_result(.efault);
            break :blk count;
        },
        dir.close_op => file_table.dir_close(pid, args[0]),
        else => -1,
    };
    return @bitCast(res);
}

/// Milestone 13 (claim 5801): slot 34 — sys_file_delete(path_ptr, path_len)
fn handle_file_delete(args: Args, _: *exceptions.VectorFrame) u64 {
    const path_ptr = args[0];
    const path_len = args[1];
    if (path_len == 0 or path_len > file_table.max_path_len) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    var path_buf: [file_table.max_path_len]u8 = undefined;
    if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);
    const res = file_table.delete(pid, path_buf[0..path_len]);
    if (res < 0) return @bitCast(res);
    return 0;
}

/// Slot 35 — old_len is the byte count optionally OR'd with
/// file_rename_replace. No extra registers or new syscall are required.
fn handle_file_rename(args: Args, _: *exceptions.VectorFrame) u64 {
    const old_ptr = args[0];
    const old_len = args[1] & ~file_rename_replace;
    const mode: file_table.RenameMode = if ((args[1] & file_rename_replace) != 0) .replace else .preserve_existing;
    const new_ptr = args[2];
    const new_len = args[3];
    if (old_len == 0 or old_len > file_table.max_path_len or new_len == 0 or new_len > file_table.max_path_len) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    var old_buf: [file_table.max_path_len]u8 = undefined;
    var new_buf: [file_table.max_path_len]u8 = undefined;
    if (uaccess.copy_in(&old_buf, old_ptr, @intCast(old_len)) != .ok) return error_result(.efault);
    if (uaccess.copy_in(&new_buf, new_ptr, @intCast(new_len)) != .ok) return error_result(.efault);
    const res = file_table.rename_mode(pid, old_buf[0..old_len], new_buf[0..new_len], mode);
    if (res < 0) return @bitCast(res);
    return 0;
}

/// Milestone 13 (claim 5801): slot 36 — sys_file_truncate(handle, size)
fn handle_file_truncate(args: Args, _: *exceptions.VectorFrame) u64 {
    const handle = args[0];
    const size: u32 = @truncate(args[1]);
    if (handle >= file_table.max_handles_per_process) return error_result(.ebadf);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const res = file_table.truncate(pid, handle, size);
    if (res < 0) return @bitCast(res);
    return 0;
}

/// Milestone 13 (claim 5801): slot 37 — sys_file_free(volume)
fn handle_file_free(args: Args, _: *exceptions.VectorFrame) u64 {
    const volume: u32 = @truncate(args[0]);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const res = file_table.free_space(pid, volume);
    if (res < 0) return @bitCast(res);
    return @intCast(res);
}

/// M66a (#1443): slot 77 — sys_file_sync(fd): FSYNC the handle's host side
/// (the HF op calls synchronize() on the host's live fd). EBADF for a dead
/// fd; the stateless/read-only handles are honest no-ops (file_table.sync).
fn handle_file_sync(args: Args, _: *exceptions.VectorFrame) u64 {
    const fd = args[0];
    if (fd >= file_table.max_handles_per_process) return error_result(.ebadf);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const res = file_table.sync(pid, fd);
    if (res < 0) return @bitCast(res);
    return 0;
}

/// M50 TS2 (#1136, ADR 0024 D3/D4/D10): slot 69 —
/// sys_file_mode(path_ptr, path_len, mode). Owner-only chmod on an existing
/// path, or `CAP_FS_ANY` (no chown). EINVAL bad path/mode or a non-process
/// caller; EACCES not the owner / secret-class denial; ENOENT absent;
/// ENOSPC the 64-entry table is full; EFAULT bad pointer.
fn handle_file_mode(args: Args, _: *exceptions.VectorFrame) u64 {
    const path_ptr = args[0];
    const path_len = args[1];
    const mode: u16 = @truncate(args[2]);
    if (path_len == 0 or path_len > file_table.max_path_len) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    var path_buf: [file_table.max_path_len]u8 = undefined;
    if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);
    const res = file_table.set_mode(pid, path_buf[0..path_len], mode);
    if (res < 0) return @bitCast(res);
    return 0;
}

// ---------------------------------------------------------------------------
// M50 TS5 (issue #1139, ADR 0024 D8/D10): sys_secret_get — slot 70
// ---------------------------------------------------------------------------

/// `sys_secret_get(buf, len)`: copy the CALLING principal's VISIBLE
/// entries from the `SECRETS.TXT` store into caller memory as fixed
/// `SecretRecord`s (ADR 0007 slot 70 wire shape). An entry's optional
/// fourth field binds it to an app allowlist (M97g #2083): the caller's
/// recorded image must be listed AND `uid_system`-owned. Returns the byte
/// length written (a multiple of `secret.record_bytes`); 0 when the
/// principal owns nothing it may read;
/// `EINVAL` for a non-process caller or a `len` too small to hold every
/// caller entry; `EFAULT` for a bad buffer. The ONLY in-guest reader of the
/// secret store; there is NO `sys_secret_set` (provisioning is host-side,
/// D8). The handler and its results are excluded from strace in
/// `dispatch`/`maybe_trace` (never-logged contract).
fn handle_secret_get(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    const buf_len = args[1];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const info = process.info(pid) orelse return error_result(.einval);
    // M97g (#2083): app-bound entries are served only when the caller's
    // recorded image is on the entry's allowlist AND that image is an
    // operator-provisioned (`uid_system`-owned) file — a bare uid match is
    // vacuous across EL0 apps and a bare name is forgeable.
    const reader = secret.Reader{ .uid = info.uid, .image = info.name };
    const needed = secret.count_for(reader) * secret.record_bytes;
    if (buf_len < needed) return error_result(.einval);
    if (needed == 0) return 0;
    var recs: [secret.max_secret_entries]secret.SecretRecord = undefined;
    const n = secret.records_for(reader, &recs);
    const take = n * secret.record_bytes;
    // Marshal the fixed records into BSS scratch, then copy out through
    // uaccess only — the caller's memory is the sole destination of values.
    @memcpy(secret_scratch[0..take], std.mem.asBytes(&recs)[0..take]);
    if (uaccess.copy_out(address, secret_scratch[0..take], take) != .ok) return error_result(.efault);
    return @intCast(take);
}

// ---------------------------------------------------------------------------
// M51 SSH-P1 (issue #1166, ADR 0025 D5): sys_getrandom — slot 72
// ---------------------------------------------------------------------------

/// `sys_getrandom(buf, len)`: fill caller memory from the kernel CSPRNG
/// (`csprng.random_bytes`). READ-ONLY and capability-free — every principal
/// may read entropy, and this can only advance the stream, never seed,
/// reseed, or weaken it. `len` is clamped to `getrandom_max` (256) and the
/// bytes actually written returned (a longer request is never refused; the
/// caller loops). `len == 0` returns 0 without touching the buffer;
/// `EFAULT` for a bad buffer; `EINVAL` for a non-process (EL1h) caller.
/// This is the single shared entropy contract (ADR 0025 D5); the
/// GOOS=virelai runtime (#1163) consumes the same slot. Registered but never
/// called on the boot path (ADR 0025 D9).
///
/// M97g (issue #2084): the slot FAILS CLOSED while the CSPRNG holds only
/// the deterministic boot fallback — a lying or absent host entropy device
/// must never yield bytes that look like real entropy (the fallback tag is
/// source-visible, so every consumer — TCP ISN, DNS ids, auth tokens —
/// would be reproducible). An unseeded call first attempts the lazy
/// reseed; `EAGAIN` (-11) is the honest transient refusal and nothing is
/// written to the buffer.
fn handle_getrandom(args: Args, _: *exceptions.VectorFrame) u64 {
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const address = args[0];
    const raw_len = args[1];
    if (raw_len == 0) return 0;
    if (!csprng.seeded() and !getrandom_reseed()) return error_result(.eagain);
    const take: usize = @intCast(@min(raw_len, @as(u64, getrandom_max)));
    // Generate into bounded kernel BSS, then copy out through uaccess only —
    // caller memory is the sole destination and can never be written to
    // directly by the CSPRNG.
    csprng.random_bytes(getrandom_scratch[0..take]);
    if (uaccess.copy_out(address, getrandom_scratch[0..take], take) != .ok) return error_result(.efault);
    return @intCast(take);
}

/// M97g (issue #2084): the lazy reseed. The boot seeds once; a failed read
/// (or a device the host attached late / reset at ExitBootServices) would
/// otherwise leave slot 72 refusing forever. Each unseeded call re-reads
/// the device — a bounded poll — re-arming the transport once if VZ
/// dropped it. Returns true only when REAL device entropy keyed the
/// stream; a deterministic fallback is never a seed.
fn getrandom_reseed() bool {
    var seed_buf: [csprng.seed_len]u8 align(16) = undefined;
    if (!virtio_entropy.read_seed(&seed_buf)) return false;
    csprng.seed(&seed_buf);
    return true;
}

// ---------------------------------------------------------------------------
// ADR 0027 (ACCEPTED 2026-09-12, issue #1214 round 2): slots 73/74 — the
// GOOS=virelai thread + futex seam (D3/D4)
// ---------------------------------------------------------------------------

/// The ns->tick conversion for a futex timeout. The scheduler tick is the
/// 1 s timer period (ADR 0007 sys_sleep row), so any sub-second timeout
/// rounds UP to one tick — coarse but honest, and documented in the ADR
/// 0007 amendment. `timeout_ns == 0` waits forever (Go's semasleep(-1)).
fn futex_deadline_tick(timeout_ns: u64) u64 {
    if (timeout_ns == 0) return 0;
    const ticks = timeout_ns / timer.period_ns + @intFromBool(timeout_ns % timer.period_ns != 0);
    return scheduler.current_tick() +| @max(ticks, 1);
}

/// `sys_thread(op, ...)` — slot 73 (ADR 0027 D3). Op 0 = create(entry,
/// stack_hi, arg, tls): a NEW task bound to the CALLER'S process (same
/// TTBR0 root, principal inherited, NOT capability-gated — it can only
/// create work inside the caller's own address space), initial EL0 frame
/// at the caller-provided stack with x0=arg, pc=entry; returns the new
/// kernel tid. Op 1 = exit: thread-only teardown (the process dies when
/// its LAST task exits — `sys_exit` slot 3 stays process-exit). Errors:
/// EINVAL for an unknown op, a non-process caller, a bad entry (outside
/// the process's executable aperture), a null/misaligned stack_hi, a
/// invalid TLS prefix, or an exhausted task pool / thread bound
/// (EAGAIN — a transient capacity refusal, the caller may retry).
fn handle_thread(args: Args, frame: *exceptions.VectorFrame) u64 {
    const op = args[0];
    const caller = scheduler.current_id();
    const pid = process.find_by_task(caller) orelse return error_result(.einval);
    switch (op) {
        0 => {
            const entry = args[1];
            const stack_hi = args[2];
            const arg = args[3];
            const tls = args[4];
            if ((tls & 0xf) != 0) return error_result(.einval);
            if (tls != 0 and (!uaccess.read_region_covers(tls, 16) or !uaccess.write_region_covers(tls, 16)))
                return error_result(.efault);
            if (stack_hi == 0 or (stack_hi & 0xf) != 0) return error_result(.einval);
            // Entry validation "like exec": the PC must sit inside the
            // process's executable text aperture.
            const pinfo = process.info(pid) orelse return error_result(.einval);
            const text_base = pinfo.text_va;
            const text_end = text_base + pinfo.text_len;
            if ((entry & 3) != 0 or entry < text_base or entry >= text_end) return error_result(.einval);
            if (tls != 0) {
                if (stack_hi < 16 or !uaccess.write_region_covers(stack_hi - 16, 16))
                    return error_result(.efault);
                return scheduler.spawn_tls_thread(caller, entry, stack_hi, arg, tls) orelse error_result(.eagain);
            }
            return scheduler.spawn_thread(caller, entry, stack_hi, arg) orelse error_result(.eagain);
        },
        1 => {
            // Thread-only exit: the task tears down; the process lives on
            // unless this was its last task.
            const status: u64 = if (scheduler.tasks[caller].join_token != 0) args[1] else 0;
            if (status > 255) return error_result(.einval);
            // Canonical lock order (svclock.zig): the exit teardown takes
            // every domain lock, but KERNEL is LAST in that order and this
            // dispatch already holds it — taking FILE/NET/WIN/EV under the
            // hold would invert the order and close a cycle with the
            // domain->KERNEL takes (uaccess write-page resolution inside
            // socket/file syscalls). Drop this dispatch's hold, let the
            // teardown acquire canonically, then re-take so the
            // dispatcher's paired release stays balanced.
            const outer = svclock.held_bits();
            svclock.release_set(outer);
            const exited = scheduler.exit_thread_status(status);
            svclock.acquire_set(outer);
            if (!exited) return error_result(.einval);
            return 0;
        },
        2 => {
            // #2093: a blocking join publishes this frame to the joinee's
            // exit path — stage the placeholder before the park so the
            // exit-status patch is the last write. A refused or
            // already-zombie join returns through the normal path and
            // overwrites the placeholder with the real result.
            _ = exceptions.frame_write(frame, 0, 0);
            return scheduler.join_thread(pid, args[1]) orelse error_result(.einval);
        },
        3 => {
            const tls = args[1];
            if ((tls & 0xf) != 0) return error_result(.einval);
            if (tls != 0 and (!uaccess.read_region_covers(tls, 16) or !uaccess.write_region_covers(tls, 16)))
                return error_result(.efault);
            scheduler.set_current_tls(tls);
            return 0;
        },
        else => return error_result(.einval),
    }
}

/// `sys_futex(op, uaddr, val, timeout_ns)` — slot 74 (ADR 0027 D4). Op 0 =
/// wait: the kernel VERIFIES `*uaddr == val` under the caller's uaccess
/// window (a direct 4-byte user read, no copy), then sleeps the task with
/// a (pid, uaddr) seat in the bounded BSS wait table. Returns 0 on a real
/// wake, -ETIMEDOUT when the deadline expires, -EAGAIN when the word no
/// longer holds `val` (the Linux futex re-check semantics). Op 1 =
/// wake(n): wake up to `n` waiters of THIS process keyed (pid, uaddr);
/// returns the number woken. timeout_ns is nanoseconds, rounding UP to the
/// 1 s scheduler tick; 0 waits forever.
fn handle_futex(args: Args, frame: *exceptions.VectorFrame) u64 {
    const op = args[0];
    const uaddr = args[1];
    const val = args[2];
    const timeout_ns = args[3];
    const caller = scheduler.current_id();
    const pid = process.find_by_task(caller) orelse return error_result(.einval);
    if ((uaddr & 3) != 0) return error_result(.einval); // the wait word is 4-byte aligned
    switch (op) {
        0, 2 => {
            // Fast path: verify the word and validate the pointer through
            // the caller's own uaccess window. The authoritative re-check
            // runs inside futex_wait_current AFTER the seat is visible
            // (review finding 1) — this first read alone has a
            // store-then-wake lost-wake window.
            const strict_deadline = if (op == 2)
                @import("thread_tls.zig").coarse_deadline(scheduler.current_tick(), timeout_ns) catch
                    return error_result(.einval)
            else
                0;
            const word = uaccess.load_u32(uaddr) orelse return error_result(.efault);
            const expected: u32 = @truncate(val);
            if (word != expected) return error_result(.eagain);
            const deadline = if (op == 2) strict_deadline else futex_deadline_tick(timeout_ns);
            // #2093: stage the wake result slot (0) BEFORE the (pid,uaddr)
            // seat and the parked frame become visible — the wake/timeout
            // patch is the last write; handle_svc never writes a parked
            // frame.
            _ = exceptions.frame_write(frame, 0, 0);
            return switch (scheduler.futex_wait_current(pid, uaddr, expected, deadline, futex_word_matches)) {
                // The task blocked and has been re-selected: the wake/timeout
                // patched x0 in THIS saved frame (0 = woken, -ETIMEDOUT on
                // expiry) — read it back so the value returns exactly once.
                .blocked => exceptions.frame_read(frame, 0),
                // A word that changed under the seat is the Linux re-check
                // contract; a full seat table or a rotation refusal is
                // transient too — both EAGAIN, the caller loops and re-reads.
                .word_changed, .unavailable => error_result(.eagain),
            };
        },
        1 => {
            // Linux semantics: n == 0 wakes nobody.
            const n = @min(val, scheduler.futex_max);
            return scheduler.futex_wake(pid, uaddr, @intCast(n));
        },
        else => return error_result(.einval),
    }
}

/// Slot 76: `sys_sock_ready(op, want, timeout_ns)` — issue #1163 (phase 2),
/// the GOOS=virelai netpoll readiness seam (ADR 0007 append-only amendment).
///
/// op 0 probes: return the readiness mask of the CALLING PROCESS's TCP
/// socket (bit 0 = readable, bit 1 = writable; 0 = nothing yet). op 1 also
/// probes. EL0 owns waiting/deadlines; this handler never parks. The caller
/// must own the socket, and `want` must name at least one bit.
///
/// Deliberately NOT an ADR 0009 event: the per-process event queue is the
/// application's input stream (drop-oldest, 16 deep), and a poller draining
/// it would steal the app's window/keyboard events and could silently lose
/// readiness. A level-triggered mask cannot lose an edge.
fn handle_sock_ready(args: Args, _: *exceptions.VectorFrame) u64 {
    const op = args[0];
    const want = args[1];
    const caller = scheduler.current_id();
    const pid = process.find_by_task(caller) orelse return error_result(.einval);
    if (want == 0 or (want & ~@as(u64, 3)) != 0) return error_result(.einval);
    if (!tcp.owned_by_pid(pid)) return error_result(.eagain);
    // op 0 and op 1 are BOTH a probe. The level-triggered mask IS the
    // readiness signal; the bounded wait belongs to the CALLER (the Go
    // runtime's netpoll re-probes on its own scheduler-aware sleep), not to a
    // loop inside a syscall handler. An earlier draft parked in-handler via
    // scheduler.yield_current() and took an EL1 synchronous exception
    // (observed: `[EXC] sync from EL1h ... unknown-reason`, `no recovery
    // path`) — a syscall handler must not re-enter the scheduler.
    _ = op;
    return @intCast(tcp.ready_mask());
}

fn socket_error(err: native_socket.core.Error) u64 {
    return @bitCast(@as(i64, switch (err) {
        error.InvalidArgument, error.ClockWentBackwards => -1,
        error.InvalidHandle => -2,
        error.Unsupported => -4,
        error.Capacity => -5,
        error.AccessDenied => -7,
        error.WouldBlock => -11,
        error.TimedOut => -12,
        error.PeerReset => -13,
        error.Closed => -14,
    }));
}

/// Slot 80, append-only native handle family. Every operation is bounded
/// and nonblocking, under NET. No legacy singleton state is switched.
fn handle_socket(args: Args, _: *exceptions.VectorFrame) u64 {
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const op = args[0];
    const handle: native_socket.core.Handle = .{ .value = args[1] };
    if (args[4] != 0 or args[5] != 0) return error_result(.einval);
    virtio_net.net_socket_poll(); // deadlines win at equality, before RX
    virtio_net.net_rx_drain();
    defer virtio_net.net_socket_poll();
    switch (op) {
        0 => {
            if (!virtio_net.net_ready or !virtio_net.arp.ip_set()) return error_result(.enxio);
            if (args[1] > 0xffffffff or args[2] == 0 or args[2] > 65535) return error_result(.einval);
            if (native_socket.sockets.next_generation > std.math.maxInt(i64) >> 2) return error_result(.enospc);
            const ip = if (args[1] == 0) virtio_net.arp.own_ip else native_socket.ipBytes(args[1]);
            if (!std.mem.eql(u8, &ip, &virtio_net.arp.own_ip)) return error_result(.einval);
            if (tcp.state != .idle and tcp.state != .closed and
                (tcp.listen_port == args[2] or (!tcp.is_server and args[2] == tcp.default_src_port)))
                return error_result(.enospc);
            const h = native_socket.sockets.listen(pid, .{ .ip = ip, .port = @intCast(args[2]) }, native_socket.now()) catch |err| return socket_error(err);
            return h.value;
        },
        1 => return (native_socket.sockets.accept(pid, handle) catch |err| return socket_error(err)).value,
        2, 3, 9 => {
            const take: usize = @intCast(@min(args[3], if (op == 9) native_socket.dns_max else socket_scratch.len));
            if (op == 3) {
                if (uaccess.copy_in(&socket_scratch, args[2], take) != .ok) return error_result(.efault);
                return native_socket.sockets.send(pid, handle, socket_scratch[0..take], native_socket.now()) catch |err| return socket_error(err);
            }
            if (!uaccess.write_region_covers(args[2], take)) return error_result(.efault);
            if (take != 0) if (uaccess.resolve_write_pages) |resolve| {
                if (!resolve(args[2], take)) return error_result(.efault);
            };
            const n = if (op == 9)
                native_socket.readDns(pid, handle, socket_scratch[0..take]) catch |err| return socket_error(err)
            else
                native_socket.sockets.read(pid, handle, socket_scratch[0..take], native_socket.now()) catch |err| return socket_error(err);
            if (uaccess.copy_out(args[2], socket_scratch[0..n], n) != .ok) return error_result(.efault);
            return n;
        },
        4 => {
            native_socket.close(pid, handle) catch |err| return socket_error(err);
            return 0;
        },
        5 => return native_socket.ready(pid, handle) catch |err| return socket_error(err),
        6 => {
            native_socket.sockets.shutdown(pid, handle, native_socket.now()) catch |err| return socket_error(err);
            return 0;
        },
        7 => return native_socket.peer(pid, handle) catch |err| return socket_error(err),
        8 => {
            if (!virtio_net.net_ready or !virtio_net.arp.ip_set()) return error_result(.enxio);
            if (args[1] > 0xffffffff or args[3] < 17 or args[3] > native_socket.dns_max) return error_result(.einval);
            const len: usize = @intCast(args[3]);
            if (uaccess.copy_in(&socket_scratch, args[2], len) != .ok) return error_result(.efault);
            const server = native_socket.ipBytes(args[1]);
            const h = native_socket.beginDns(pid, server, socket_scratch[0..len]) catch |err| return socket_error(err);
            if (virtio_net.net_socket_dns_send(server, socket_scratch[0..len]) != .ok) {
                native_socket.close(pid, h) catch unreachable;
                return error_result(.enxio);
            }
            return h.value;
        },
        11 => return native_socket.ownedCount(pid),
        else => return error_result(.einval),
    }
}

/// `sys_exnotify(handler)` — slot 75 (issue #1228, phase 0c). A single
/// argument, no ops: nonzero installs the CALLER'S process EL0
/// fault-handler PC — the address the exception path redirects a
/// deliverable EL0 fault to (see `exceptions.fault_deliverable`) with the
/// fault record in x0-x6; zero clears it (the reap path returns). The
/// handler is process-scope (every `sys_thread` task inherits it) and dies
/// with the address space: `create` zeroes it and a new exec image must
/// re-register. Errors: EINVAL for a non-process caller, a misaligned
/// handler (AArch64 instructions are 4-byte aligned), or a handler outside
/// the process's executable text aperture (the slot-73 "like exec" rule).
fn handle_exnotify(args: Args, _: *exceptions.VectorFrame) u64 {
    const handler = args[0];
    const caller = scheduler.current_id();
    const pid = process.find_by_task(caller) orelse return error_result(.einval);
    if (handler == 0) {
        if (!process.set_exnotify_handler(pid, 0)) return error_result(.einval);
        return 0;
    }
    if ((handler & 3) != 0) return error_result(.einval);
    const pinfo = process.info(pid) orelse return error_result(.einval);
    const text_end = pinfo.text_va + pinfo.text_len;
    if (handler < pinfo.text_va or handler >= text_end) return error_result(.einval);
    if (!process.set_exnotify_handler(pid, handler)) return error_result(.einval);
    return 0;
}

/// The re-check `futex_wait_current` runs under sched_lock after seating
/// the waiter: read the 4-byte user word through the same uaccess window
/// the fast path used (the callback keeps the scheduler free of a uaccess
/// import). False means a peer's store landed in the compare-to-seat
/// window — the caller returns EAGAIN and re-reads.
fn futex_word_matches(uaddr: u64, val: u32) bool {
    return (uaccess.load_u32(uaddr) orelse return false) == val;
}

/// M97g (#2082): slots 38/39 admit a caller holding CAP_CLIPBOARD or the
/// registered WM seat. The seat is the user's gesture mediator — it owns
/// the raw input fan-out and renders the clipboard tray indicator — so
/// its probe is user-mediated by construction; every other unprivileged
/// caller gets EACCES before any argument is validated.
fn clipboard_authorized(pid: usize) bool {
    const caller = process.principal(pid) orelse return false;
    if (caller.has(gated(sys_clipboard_get) orelse process.cap_clipboard)) return true;
    if (wm_server.registered_pid()) |seat| return seat == pid;
    return false;
}

/// Milestone 14 (claim 0169): slot 38 — sys_clipboard_set(buf_ptr, len)
/// M97g (#2082): CAP_CLIPBOARD or the registered seat — the buffer is
/// machine-global, so an unprivileged caller could silently overwrite
/// what the user pastes.
fn handle_clipboard_set(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_ptr = args[0];
    const raw_len = args[1];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (!clipboard_authorized(pid)) return error_result(.eacces);
    if (raw_len == 0) {
        _ = clipboard.set("");
        return 0;
    }
    const take: usize = @min(@as(usize, @intCast(raw_len)), clipboard.capacity);
    if (uaccess.copy_in(clipboard_staging[0..take], buf_ptr, take) != .ok) return error_result(.efault);
    return @intCast(clipboard.set(clipboard_staging[0..take]));
}

/// Milestone 14 (claim 0169): slot 39 — sys_clipboard_get(buf_ptr, max)
/// M97g (#2082): CAP_CLIPBOARD or the registered seat — silent reads are
/// the keylogger half of the audit finding; the user's paste path is the
/// kernel chrome chord, which never enters this handler.
fn handle_clipboard_get(args: Args, _: *exceptions.VectorFrame) u64 {
    const buf_ptr = args[0];
    const raw_max = args[1];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (!clipboard_authorized(pid)) return error_result(.eacces);
    if (raw_max == 0) return 0;
    const take: usize = @min(@as(usize, @intCast(raw_max)), clipboard.capacity);
    const n = clipboard.get(clipboard_staging[0..take]);
    if (n > 0) {
        if (uaccess.copy_out(buf_ptr, clipboard_staging[0..n], n) != .ok) return error_result(.efault);
    }
    return @intCast(n);
}

/// `sys_time()` (slot 66, #1058): return the current Unix wall-clock seconds
/// — the boot loader's EFI `GetTime` epoch advanced by 1 Hz uptime. No
/// arguments; ENOSYS when the firmware gave no epoch, so a caller falls back
/// honestly (TABWM's host `.clock` or uptime). No uaccess, no hardware.
fn handle_time(_: Args, _: *exceptions.VectorFrame) u64 {
    return timer.wall_epoch() orelse error_result(.enosys);
}

/// `sys_time_set(epoch_secs)` (slot 78, M83b #1775): re-anchor the wall clock
/// so `sys_time` reads `epoch_secs` (Unix seconds) now. Returns 0. `EINVAL`
/// for a non-process caller or an epoch outside
/// `[timer.wall_epoch_min, timer.wall_epoch_max]` — the clock is untouched on
/// every refusal. Works when the firmware gave no epoch (`sys_time` was
/// `ENOSYS`); it moves the anchor, never the tick count, so uptime and every
/// tick-based deadline are unaffected.
///
/// No capability gate: every EL0 process is `uid_user` with no caps and no
/// syscall elevates (ADR 0024 D5), so a row in `capability_gates` could only
/// ever answer no. The range check is the bound; the monitor's `syscalls`
/// report shows whether anyone has called it.
fn handle_time_set(args: Args, _: *exceptions.VectorFrame) u64 {
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (!timer.set_wall_epoch(args[0])) return error_result(.einval);
    return 0;
}

/// `sys_tty_attach(front_end, arg, mode, reserved, allow_ip)` (slot 67,
/// #1072/ADR 0020): attach (or detach) the CALLING process's controlling
/// terminal — opened as `/dev/tty` — to a front-end. a0: 0 = detach, 1 = the
/// serial console (the kernel console), 2 = a `.user` window front-end
/// (a1 = window id), 3 = a net front-end (a1 = TCP listen port; SH7/
/// Amendment B). The process must have opened `/dev/tty` (else EINVAL).
/// Front-ends are mutually exclusive (serial/window/net, D2) and the console
/// can be held by only one terminal at a time (busy -> EACCES). For selector
/// 2 the caller must OWN the `.user` window; for selector 3 the caller must
/// own the TCP listener (the single-connection seam), a2 is the auth scheme
/// (M50 TS4: 0 = open, 1 = hmac-sha256, 2 = ed25519), and a4 is the optional
/// source-IP allowlist. Returns 0.
fn handle_tty_attach(args: Args, _: *exceptions.VectorFrame) u64 {
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const th = file_table.controlling_terminal(pid) orelse return error_result(.einval);
    const t = terminal.get(th) orelse return error_result(.einval);
    switch (args[0]) {
        0 => {
            if (t.front_end == .net) tcp.reset(); // close the listener/session
            t.detach();
            return 0;
        },
        1 => {
            if (terminal.attachedNet() != null or terminal.anyWindowAttached()) return error_result(.eacces);
            if (terminal.attachedSerial()) |cur| {
                if (cur != t) return error_result(.eacces); // console already held
            }
            if (!t.attach(.serial)) return error_result(.eacces);
            return 0;
        },
        2 => {
            // #1082 (ADR 0020 Amendment A): the caller attaches its OWN
            // `.user` window as the terminal's front-end. No cross-process
            // access: the owner is the single writer of both.
            if (args[1] > std.math.maxInt(u8)) return error_result(.einval);
            const wid: u8 = @truncate(args[1]);
            if (terminal.attachedSerial() != null or terminal.attachedNet() != null) return error_result(.eacces);
            const w = driving_award.find_user_window(wid) orelse return error_result(.einval);
            if (w.owner == null or w.owner.? != pid) return error_result(.eacces);
            if (!t.attachWindow(wid)) return error_result(.eacces);
            return 0;
        },
        3 => {
            // #1083 (ADR 0020 Amendment B): the caller hosts the net
            // front-end — it enters LISTEN on `port` through the single
            // bounded TCP seam and attaches its own terminal. No
            // cross-process terminal capability (B2).
            // M50 TS4 (#1138, ADR 0024 D6): a2 = the auth scheme the pump
            // frames (0 open, 1 hmac-sha256, 2 ed25519). The credential is
            // NEVER an argument — the process reads it from the TS5 store
            // and votes through slot 71. a4 = optional source-IP allowlist
            // (big-endian IPv4 u32; 0 = any).
            if (args[1] == 0 or args[1] > 0xffff) return error_result(.einval);
            if (args[2] > 2) return error_result(.einval);
            if (!virtio_net.net_ready) return error_result(.einval);
            if (!virtio_net.arp.ip_set()) return error_result(.einval);
            const port: u16 = @truncate(args[1]);
            const scheme: terminal.NetAuthScheme = @enumFromInt(@as(u8, @intCast(args[2])));
            var allow: ?[4]u8 = null;
            if (args[4] != 0) {
                allow = .{
                    @truncate((args[4] >> 24) & 0xff),
                    @truncate((args[4] >> 16) & 0xff),
                    @truncate((args[4] >> 8) & 0xff),
                    @truncate(args[4] & 0xff),
                };
            }
            if (terminal.attachedSerial() != null or terminal.anyWindowAttached()) return error_result(.eacces);
            if (terminal.attachedNet()) |cur| {
                if (cur != t) return error_result(.eacces);
            }
            // The single TCP connection may only be (re)claimed by its owner
            // and only from idle/listen.
            if (tcp.owner_pid) |op| {
                if (op != pid) return error_result(.eacces);
            }
            if (tcp.state == .closed) tcp.reset();
            if (tcp.state != .idle and tcp.state != .listen) return error_result(.eacces);
            tcp.reset();
            tcp.listen(port);
            tcp.allow_ip = if (allow) |ip| ip else .{ 0, 0, 0, 0 };
            tcp.allow_ip_set = allow != null;
            tcp.owner_pid = pid;
            if (!t.attachNetAuth(port, scheme, allow)) {
                tcp.reset();
                return error_result(.eacces);
            }
            return 0;
        },
        else => return error_result(.einval),
    }
}

// ---------------------------------------------------------------------------
// M50 TS4 (issue #1138, ADR 0024 D6/D10): sys_tty_net_auth — slot 71
// ---------------------------------------------------------------------------

/// `sys_tty_net_auth(op, buf, len)`: the delegated challenge-response
/// channel between the kernel net pump and the attached process. op 0 copies
/// the fresh 32-byte challenge OUT (returns 32; 0 before it is minted); op 1
/// copies the buffered client reply line OUT (its hex length; 0 when none);
/// op 2 reads the one-byte verdict IN (0 reject, 1 accept) and applies it —
/// accept opens the byte gate, reject sends `auth failed` + reset + detach.
/// The caller must be the process that owns the attached net terminal.
/// `EINVAL` when the terminal is not in auth mode, no reply awaits a
/// verdict, the out buffer is too small, or the op is unknown; `EACCES`
/// when the caller does not own the attached terminal; `EFAULT` for a bad
/// buffer. Excluded from strace in `dispatch`/`maybe_trace` (the
/// never-logged contract).
fn handle_tty_net_auth(args: Args, _: *exceptions.VectorFrame) u64 {
    const op = args[0];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const th = file_table.controlling_terminal(pid) orelse return error_result(.einval);
    const t = terminal.get(th) orelse return error_result(.einval);
    const net_t = terminal.attachedNet() orelse return error_result(.einval);
    // "Caller must own the attached terminal" — the same ownership the
    // attach path recorded (file_table's controlling-terminal registry).
    if (net_t != t) return error_result(.eacces);
    if (!t.net_auth_on) return error_result(.einval);
    switch (op) {
        net_auth_op_challenge => {
            if (t.net_authed or !t.net_challenge_sent) return 0;
            if (args[2] < terminal.net_challenge_len) return error_result(.einval);
            if (uaccess.copy_out(args[1], &t.net_challenge, terminal.net_challenge_len) != .ok) {
                return error_result(.efault);
            }
            return terminal.net_challenge_len;
        },
        net_auth_op_response => {
            if (t.net_authed or !t.net_reply_ready) return 0;
            if (args[1] == 0) return error_result(.efault);
            if (args[2] < t.net_reply_len) return error_result(.einval);
            if (uaccess.copy_out(args[1], t.net_reply[0..t.net_reply_len], t.net_reply_len) != .ok) {
                return error_result(.efault);
            }
            return @intCast(t.net_reply_len);
        },
        net_auth_op_verdict => {
            if (t.net_verdict != null or !t.net_reply_ready or t.net_authed) return error_result(.einval);
            if (args[1] == 0 or args[2] < 1) return error_result(.efault);
            var b: [1]u8 = undefined;
            if (uaccess.copy_in(&b, args[1], 1) != .ok) return error_result(.efault);
            if (b[0] > 1) return error_result(.einval);
            if (!terminal.netAuthVerdict(t, b[0] == 1)) return error_result(.einval);
            return 0;
        },
        else => return error_result(.einval),
    }
}

/// Milestone 14 (claim 7323): slot 40 — sys_timer_set(delay_ticks)
/// Arm the CALLING process's app timer to fire ONE TIMER event (kind 9)
/// into its ADR 0009 queue after `delay_ticks` scheduler ticks. Zero
/// clamps to 1 (the sys_sleep minimum) and an over-long delay truncates
/// honestly at app_timers.max_delay_ticks — both documented. Re-arming
/// replaces any pending timer. Returns 0; EINVAL for a non-process caller.
fn handle_timer_set(args: Args, _: *exceptions.VectorFrame) u64 {
    const delay = args[0];
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    _ = app_timers.set(pid, delay);
    return 0;
}

/// Milestone 14 (claim 7323): slot 41 — sys_timer_cancel()
/// Disarm the calling process's app timer. Returns 1 if a pending timer
/// was canceled, 0 if none was armed; EINVAL for a non-process caller.
fn handle_timer_cancel(args: Args, _: *exceptions.VectorFrame) u64 {
    _ = args;
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    return if (app_timers.cancel(pid)) 1 else 0;
}

/// Milestone 15 (claim 7636): slot 42 — sys_audio_info(out_ptr)
/// Copy the device's negotiated playback state out through uaccess as a
/// 16-byte `AudioInfo` struct {ready, format, rate, channels, period_bytes,
/// max_len}. The app learns the format/rate/channels it must synthesize
/// in (FLOAT 19 / 48000 7 / stereo 2 on the observed VZ device). Returns
/// 0; `EINVAL` for a non-process caller, `EFAULT` for a bad buffer.
///
/// Erratum (M58e, issue #1328): this comment and ADR 0007's slot-42 row
/// said "24-byte" for three milestones. The struct has been 16 bytes since
/// it landed — `virtio_snd.AudioInfo` is `@sizeOf == 16`, and the frozen
/// WAT contract already recorded that (docs/wasm-import-contract.md §5.3).
/// The size matters: an out struct that claims 24 would read 8 bytes the
/// kernel never wrote.
fn handle_audio_info(args: Args, _: *exceptions.VectorFrame) u64 {
    const out_ptr = args[0];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const saved = virtio_snd.audio_lock.lock();
    defer virtio_snd.audio_lock.unlock(saved);
    const info = virtio_snd.snd_audio_info();
    const bytes = std.mem.asBytes(&info);
    if (uaccess.copy_out(out_ptr, bytes, bytes.len) != .ok) return error_result(.efault);
    return 0;
}

/// Milestone 15 (claim 7636): slot 43 — sys_audio_play(ptr, len)
/// Copy the caller's PCM samples in through uaccess in bounded periods
/// (4096 B — the A2 period buffer, zero heap), run the proven control
/// flow (PCM_INFO → SET_PARAMS → PREPARE → START → submit/drain per
/// period → STOP → RELEASE), and return the bytes played. Errors: `EINVAL`
/// for a non-process caller or a zero length, `ENAMETOOLONG` over
/// `audio_max_len`, `EFAULT` for a bad pointer, `ENXIO` when no sound
/// device is attached (the default VM) or a device-level refusal.
fn handle_audio_play(args: Args, _: *exceptions.VectorFrame) u64 {
    const ptr = args[0];
    const raw_len = args[1];
    const owner = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const saved = virtio_snd.audio_lock.lock();
    defer virtio_snd.audio_lock.unlock(saved);
    if (raw_len & virtio_snd.audio_stream_flag != 0) return handle_audio_stream(args, owner);
    if (!virtio_snd.snd_legacy_available()) return error_result(.eagain);
    if (raw_len == 0) return error_result(.einval);
    if (raw_len > virtio_snd.audio_max_len) return error_result(.enametoolong);
    if (!virtio_snd.snd_ready) return error_result(.enxio);
    const len: usize = @intCast(raw_len);
    const st = virtio_snd.snd_audio_start();
    if (st != virtio_snd.S_OK) return error_result(.enxio);
    var off: usize = 0;
    while (off < len) {
        const chunk: usize = @min(len - off, @as(usize, virtio_snd.beep_period_bytes));
        if (uaccess.copy_in(virtio_snd.beep_buf[4..][0..chunk], ptr + off, chunk) != .ok) {
            _ = virtio_snd.snd_audio_stop();
            return error_result(.efault);
        }
        if (virtio_snd.snd_audio_submit(@intCast(chunk)) != virtio_snd.S_OK) {
            _ = virtio_snd.snd_audio_stop();
            return error_result(.enxio);
        }
        off += chunk;
    }
    if (virtio_snd.snd_audio_stop() != virtio_snd.S_OK) return error_result(.enxio);
    return @intCast(len);
}

fn audio_stream_error(err: virtio_snd.playback.pcm.Error) u64 {
    return error_result(switch (err) {
        error.Backpressure, error.Busy => .eagain,
        error.NoDevice, error.InsufficientCapacity, error.Quarantined, error.DeviceFailed, error.MalformedCompletion => .enxio,
        else => .einval,
    });
}

/// B7 additive slot-43 opt-in. Zero acceptance on EAGAIN or failed copy.
/// All operations are serialized with legacy playback and the main pump.
fn handle_audio_stream(args: Args, owner: usize) u64 {
    const pcm = virtio_snd.playback.pcm;
    const len = args[1] & ~virtio_snd.audio_stream_flag;
    const op = std.enums.fromInt(virtio_snd.StreamOp, args[2]) orelse return error_result(.einval);
    const token = pcm.StreamToken{ .owner = owner, .generation = args[3] };
    virtio_snd.snd_stream_drive();
    switch (op) {
        .open => {
            if (len != @sizeOf(virtio_snd.StreamParams) or args[3] != 0) return error_result(.einval);
            var request: virtio_snd.StreamParams = undefined;
            if (uaccess.copy_in(std.mem.asBytes(&request), args[0], @intCast(len)) != .ok) return error_result(.efault);
            const opened = virtio_snd.snd_stream_open(owner, request) catch |err| return audio_stream_error(err);
            return opened.generation;
        },
        .submit => {
            if (len > pcm.period_bytes) return error_result(.enametoolong);
            const current = virtio_snd.stream orelse return error_result(.einval);
            const reservation = current.model.reserve(token, @intCast(len)) catch |err| return audio_stream_error(err);
            var buffer: [pcm.period_bytes]u8 = undefined;
            if (uaccess.copy_in(buffer[0..@intCast(len)], args[0], @intCast(len)) != .ok) {
                current.model.cancel(reservation) catch {};
                return error_result(.efault);
            }
            const request = current.model.params;
            virtio_snd.snd_apply_gain(buffer[0..@intCast(len)], switch (request.format) {
                .s16 => virtio_snd.FMT_S16,
                .s32 => virtio_snd.FMT_S32,
                .float32 => virtio_snd.FMT_FLOAT,
            }, request.channels);
            const accepted = current.model.commit(reservation, buffer[0..@intCast(len)]) catch |err| return audio_stream_error(err);
            virtio_snd.snd_stream_drive();
            return accepted;
        },
        .start, .end, .abort => {
            if (len != 0 or args[0] != 0) return error_result(.einval);
            const now = virtio_snd.snd_stream_now();
            const current = virtio_snd.stream orelse return error_result(.einval);
            const model = &current.model;
            switch (op) {
                .start => model.start(token, now) catch |err| return audio_stream_error(err),
                .end => model.end(token, now) catch |err| return audio_stream_error(err),
                .abort => model.abort(token, now) catch |err| return audio_stream_error(err),
                else => unreachable,
            }
            virtio_snd.snd_stream_drive();
            if (op == .start and model.state != .running) return error_result(.enxio);
            if (model.state == .quarantined) return error_result(.enxio);
            return 0;
        },
        .status => {
            if (len != @sizeOf(virtio_snd.StreamStatus)) return error_result(.einval);
            const status = virtio_snd.snd_stream_status(owner, token.generation) catch |err| return audio_stream_error(err);
            if (uaccess.copy_out(args[0], std.mem.asBytes(&status), @intCast(len)) != .ok) return error_result(.efault);
            return 0;
        },
    }
}

/// M15 follow-up (claim 9297): slot 44 — sys_audio_volume(vol)
/// Set the bounded kernel-side stream gain (0..100 percent) that
/// `sys_audio_play` applies to every period at submit time. Pure kernel
/// state — it works without a device (a later --sound attach inherits
/// it). Returns the volume on success; `EINVAL` for a non-process caller
/// or an out-of-range value (honest refusal, no silent clamping).
fn handle_audio_volume(args: Args, _: *exceptions.VectorFrame) u64 {
    const vol = args[0];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (vol > 100) return error_result(.einval);
    return virtio_snd.snd_set_volume(@intCast(vol));
}

/// M15 follow-up (claim 9297): slot 45 — sys_audio_mute(muted)
/// Set the kernel-side mute state (1 = silent). Same contract as slot 44:
/// pure kernel state, applied at the submit choke point. Returns 0 on
/// success; `EINVAL` for a non-process caller or a value that is not 0/1.
fn handle_audio_mute(args: Args, _: *exceptions.VectorFrame) u64 {
    const muted = args[0];
    _ = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (muted > 1) return error_result(.einval);
    _ = virtio_snd.snd_set_mute(muted == 1);
    return 0;
}

/// Claim 6359 / issue #1333 (ADR 0007 slot 28): `sys_exec(path_ptr,
/// path_len, argv_ptr, argc)` — the EL0 exec seam. Marshals the path
/// (and, when `argc` is 1..=8, a packed card-3e argv block) through the
/// claim-6120 uaccess window, requires a process caller, and reuses the
/// EL1h loader `exec.exec_file_as` to load the named program from the
/// share into a fresh process slot and spawn it at EL0. `argc == 0`
/// means no args (`argv_ptr` ignored). Returns the new process's pid on
/// success (via `exec.last_exec_pid`); the caller may hand it to
/// `sys_wait` or `sys_kill`. Errors: `EINVAL` for a non-process caller,
/// an empty/over-long path, `argc > 8`, or a loader refusal (no disk,
/// bad image, oversize, no args room); `EFAULT` for a bad path or argv
/// pointer; `ENOENT` when the file is absent; `ENOSPC` when a capacity
/// gate refuses (pool, page allocator, page-table carve-out, process
/// registry). B1 adds the opt-in stream request described in ADR 0007:
/// bit 63 in argc, request pointer in x4, exact request size in x5.
pub const exec_stream_flag: u64 = @as(u64, 1) << 63;

fn handle_exec(args: Args, _: *exceptions.VectorFrame) u64 {
    const path_ptr = args[0];
    const path_len = args[1];
    const argv_ptr = args[2];
    const argc = args[3] & ~exec_stream_flag;
    // M34 HF6 (issue #740): the name bound is the host channel's path
    // max (the ESP 8.3 window is gone).
    if (path_len == 0 or path_len > virtio_file.path_max) return error_result(.einval);
    if (argc > esp_exec.max_exec_args) return error_result(.einval);
    // The caller must be a process (an EL1h task cannot exec from EL0).
    const caller = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    var request = file_table.StreamRequest{};
    if ((args[3] & exec_stream_flag) != 0) {
        if (args[5] != @sizeOf(file_table.StreamRequest)) return error_result(.einval);
        if (uaccess.copy_in(std.mem.asBytes(&request), args[4], @sizeOf(file_table.StreamRequest)) != .ok) return error_result(.efault);
    }
    var plan: file_table.StreamPlan = .{};
    const prepared = file_table.prepare_streams(caller, request, &plan);
    if (prepared < 0) return @bitCast(prepared);
    defer file_table.cancel_streams(&plan);

    var path_buf: [virtio_file.path_max]u8 = undefined;
    if (uaccess.copy_in(&path_buf, path_ptr, @intCast(path_len)) != .ok) return error_result(.efault);

    var arg_block: [esp_exec.arg_block_bytes]u8 = [_]u8{0} ** esp_exec.arg_block_bytes;
    var arg_slices: [esp_exec.max_exec_args][]const u8 = undefined;
    var exec_args: []const []const u8 = &.{};
    if (argc > 0) {
        const n: usize = @intCast(argc);
        const nbytes = n * esp_exec.arg_slot_bytes;
        if (uaccess.copy_in(arg_block[0..nbytes], argv_ptr, nbytes) != .ok) return error_result(.efault);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const slot = arg_block[i * esp_exec.arg_slot_bytes ..][0..esp_exec.arg_slot_bytes];
            const end = std.mem.indexOfScalar(u8, slot, 0) orelse return error_result(.einval);
            arg_slices[i] = slot[0..end];
        }
        exec_args = arg_slices[0..n];
    }

    // M50 TS1 (#1135, ADR 0024 D2): exec PRESERVES the caller's principal —
    // no setuid semantics, no elevation path. The spawned process inherits
    // the caller's uid and caps.
    const principal = process.principal(caller) orelse process.default_principal;
    const res = esp_exec.exec_file_streams_as(path_buf[0..path_len], exec_args, principal, &plan);
    return switch (res) {
        .ok => blk: {
            // The pid is set at the loader's success point; a missing
            // value (unreachable in practice) degrades to 0.
            break :blk @as(u64, if (esp_exec.last_exec_pid()) |new_pid| @intCast(new_pid) else 0);
        },
        // M72a (issue #1579): `map_too_large` joins the size refusals — an
        // image whose headers promise more mapped memory than the loader
        // backs is the caller's bad image, like the other two bounds.
        .no_disk, .image_too_large, .staging_too_large, .map_too_large, .bad_magic, .bad_entry, .no_args_room, .too_many_args, .arg_too_long => error_result(.einval),
        // M70b: a pin naming an offline core is the caller's bad argument.
        .bad_core => error_result(.einval),
        // M22 D1 (issue #324): ELF refusals are the caller's bad image.
        // M70c-K (issue #1504) adds the streamed path's truncated-file
        // refusal to the same group — a half-written image is the caller's
        // bad argument, not a kernel condition.
        .bad_elf, .unsupported_arch, .no_pt_load, .too_many_segments, .segment_too_large, .image_truncated => error_result(.einval),
        .not_found => error_result(.enoent),
        .pool_full, .out_of_memory, .table_full, .process_full => error_result(.enospc),
    };
}

/// Claim 7604 (ADR 0007 slot 29): `sys_kill(target_pid)` — the EL0
/// termination seam. Requires a process caller, validates the target
/// through the process registry (range, free, exited, no executor), and
/// arms the kill through the claim-7786 seam (`scheduler.request_kill` —
/// a pure TCB write, safe from SVC context). The target exits with the
/// reserved status 137 at its next ring selection, flowing through the
/// real exit → zombie → idle-reap → page-return lifecycle. Returns 0 once
/// armed; `EINVAL` for every refusal (the `sys_wait` precedent for numeric
/// targets). Self-kill is allowed (the monitor's `kill` is equally
/// general); a permanently blocked target keeps the EL1h kill's
/// documented bound — the arm applies at the target's next selection.
///
/// M50 TS3 (#1137, ADR 0024 D5/D10): the kill gate. Self (the caller's own
/// pid) and same-uid targets are allowed for EVERY principal; a
/// cross-principal kill requires the capability `gated(sys_kill)` names
/// (`CAP_PROC_ADMIN`). The principal check runs BEFORE the target-state
/// checks so an unprivileged caller cannot learn a foreign principal's
/// state through the error code: a cross-principal kill from a principal
/// without the cap is `EACCES`, never the state-dependent `EINVAL`. The
/// EL1h monitor is never a target: it has no process descriptor, so no pid
/// names it, and `scheduler.request_kill` independently refuses the
/// kernel-owned shell/idle executor slots.
fn handle_kill(args: Args, _: *exceptions.VectorFrame) u64 {
    const target = args[0];
    // The caller must be a process (an EL1h task cannot kill from EL0).
    const caller = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    if (target >= process.max_processes) return error_result(.einval);
    const target_pid: usize = @intCast(target);
    const info = process.info(target_pid) orelse return error_result(.einval);
    // The gate: same-principal (including self) is always allowed; a
    // different uid needs the D10 capability. Denial is EACCES.
    if (target_pid != caller) {
        const caller_principal = process.principal(caller) orelse process.default_principal;
        const target_principal = process.principal(target_pid) orelse return error_result(.einval);
        if (caller_principal.uid != target_principal.uid) {
            const required = gated(sys_kill) orelse process.cap_proc_admin;
            if (!caller_principal.has(required)) return error_result(.eacces);
        }
    }
    if (info.state == .exited) return error_result(.einval);
    const task_id = info.task_id orelse return error_result(.einval);
    return switch (scheduler.request_kill(task_id)) {
        .ok => 0,
        .not_found, .already_exited, .refused => error_result(.einval),
    };
}

/// True when the process currently making the syscall owns the single
/// global TCP connection (`tcp.owner_pid` matches the caller's pid). False
/// for a non-process caller or when another process owns it. The connection
/// is process-owned once established — a second process is refused EACCES
/// (the M14 S4 ownership audit; the connection auto-closes on owner exit
/// via `tcp.close_owner`).
fn tcp_owned_by_caller() bool {
    const owner = process.find_by_task(scheduler.current_id()) orelse return false;
    const current = tcp.owner_pid orelse return false;
    return owner == current;
}

/// Slot 30: outbound x1 = port | timeout_ms<<16 (bits 48..63 reserved).
/// Zero timeout keeps the legacy 30 s/EINVAL refusal. Passive open (ip==0)
/// keeps its plain port word and rejects timeout bits.
fn handle_tcp_connect(args: Args, _: *exceptions.VectorFrame) u64 {
    const ip_raw = args[0];
    const port_word = args[1];
    const dst_port: u16 = @truncate(port_word);
    const timeout_ms: u32 = @truncate(port_word >> 16);
    if (dst_port == 0 or port_word >> 48 != 0) return error_result(.einval);
    if (ip_raw == 0 and timeout_ms != 0) return error_result(.einval);
    if (!virtio_net.net_ready) return error_result(.einval);
    if (!virtio_net.arp.ip_set()) return error_result(.einval);

    // Passive open (Listen mode) when ip == 0
    if (ip_raw == 0) {
        if (native_socket.sockets.listener) |l| if (l.local.port == dst_port) return error_result(.enospc);
        if (tcp.state == .closed) {
            tcp.reset();
        }
        if (tcp.state != .idle and tcp.state != .listen) {
            return error_result(.einval);
        }
        tcp.listen(@truncate(dst_port));
        if (process.find_by_task(scheduler.current_id())) |pid| {
            tcp.owner_pid = pid;
        }
        return 0;
    }

    const ip: [4]u8 = .{
        @truncate(ip_raw >> 24),
        @truncate(ip_raw >> 16),
        @truncate(ip_raw >> 8),
        @truncate(ip_raw),
    };
    if (std.mem.eql(u8, &ip, &virtio_net.arp.own_ip)) return error_result(.einval);

    if (tcp.state == .closed) {
        tcp.reset();
    }
    if (tcp.state != .idle) {
        if (tcp.state == .established and std.mem.eql(u8, &ip, &tcp.peer_ip) and dst_port == tcp.peer_port) {
            // Idempotent re-connect to the SAME peer is only allowed for
            // the connection's owner (a second process is refused EACCES).
            if (!tcp_owned_by_caller()) return error_result(.eacces);
            return 0;
        }
        return error_result(.einval);
    }

    virtio_net.net_rx_drain();
    const peer_mac = virtio_net.arp.lookup(ip) orelse return error_result(.einval);
    const start_pct = timer.cntpct();
    const start_ticks = timer.ticks;
    const deadline = tcp.ConnectDeadline.init(start_pct, timer.freq, timeout_ms);
    if (!builtin.is_test and deadline == null) return error_result(.einval);
    const timeout_result = error_result(if (timeout_ms == 0) .einval else .etimedout);
    tcp.now_ticks = start_ticks;
    const isn: u32 = @truncate(csprng.random_u64());
    tcp.start(ip, @truncate(dst_port), isn, peer_mac);
    if (process.find_by_task(scheduler.current_id())) |pid| {
        tcp.owner_pid = pid;
    }

    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len)) {
        .ok => {
            tcp.syn_sent += 1;
            tcp.advance_snd(1);
            tcp.record_pending();
        },
        else => {
            tcp.reset_connection();
            return error_result(.einval);
        },
    }

    var test_iterations: usize = 0;

    while (tcp.state == .syn_sent) {
        if (deadline) |d| {
            const now_pct = timer.cntpct();
            if (d.expired(now_pct)) {
                tcp.abort_timeout();
                return timeout_result;
            }
            tcp.now_ticks = start_ticks +| ((now_pct -% start_pct) / timer.freq);
        }
        virtio_net.net_rx_drain();
        // A SYN-ACK drained after the deadline must not turn expiry into
        // success (or leave its ACK/owner/RTO state behind).
        if (deadline) |d| {
            if (d.expired(timer.cntpct())) {
                tcp.abort_timeout();
                return timeout_result;
            }
        }
        tcp_flush_rst(); // M84f: an over-cap SYN during our connect is refused too
        if (tcp.ack_pending) {
            var ack_len: usize = 0;
            if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &ack_len) == .ok) {
                tcp.ack_pending = false;
                tcp.ack_sent += 1;
            }
        }
        if (tcp.state == .established) return 0;
        if (tcp.state == .closed) {
            tcp.reset_connection();
            return error_result(.einval);
        }

        switch (tcp.poll_rto()) {
            .none => {},
            .retransmit => {
                var retx_len: usize = 0;
                _ = virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &retx_len);
            },
            .abort => {
                tcp.reset_connection();
                return timeout_result;
            },
        }

        if (timer.freq == 0 or comptime builtin.is_test) {
            test_iterations += 1;
            if (test_iterations > 1000) {
                tcp.abort_timeout();
                return timeout_result;
            }
        }

        if (comptime builtin.cpu.arch == .aarch64) {
            var spins: usize = 0;
            while (spins < 1000) : (spins += 1) asm volatile ("nop");
        }
    }

    if (tcp.state == .established) return 0;
    tcp.reset_connection();
    return error_result(.einval);
}

/// M84f (#1836): flush the over-cap refusal's OWN bounded slot
/// (`tcp.rst_msg` — never `tcp.msg`, so the connection's pending segment
/// and retransmit state are undisturbed). Best-effort: a transport
/// refusal keeps the refusal queued for the next TX site (and the shell
/// idle loop). Called at every syscall TCP TX site — the refusal goes
/// out before the connection's own queued segments.
fn tcp_flush_rst() void {
    if (!tcp.rst_pending) return;
    var out_len: usize = 0;
    if (virtio_net.net_tcp_send(tcp.rst_msg[0..tcp.rst_len], &out_len) == .ok) tcp.rst_pending = false;
}

/// Slot 31: `sys_tcp_send(buf, len)`: Send up to payload_max (64) bytes.
fn handle_tcp_send(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    var len = args[1];
    if (len == 0) return 0;
    if (len > tcp.payload_max) len = tcp.payload_max;
    if (tcp.state != .established) return error_result(.einval);
    if (!tcp_owned_by_caller()) return error_result(.eacces);

    if (uaccess.copy_in(&tcp_send_staging, address, @intCast(len)) != .ok) return error_result(.efault);

    // M84f (#1836): TX-site discipline — flush the over-cap refusal's own
    // slot first, then any built segment in the shared `tcp.msg` slot
    // BEFORE the data build would overwrite it (a queued SYN-ACK is an
    // unACKed segment too). A flush failure is the transport's einval —
    // the slot and its occupant stay intact for the caller's retry.
    tcp_flush_rst();
    if (tcp.ack_pending) {
        var ctl_len: usize = 0;
        if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &ctl_len) != .ok) return error_result(.einval);
        tcp.ack_pending = false;
        tcp.ack_sent += 1;
    }

    tcp.build_data_msg(tcp_send_staging[0..@intCast(len)]);
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len)) {
        .ok => {
            tcp.data_sent += 1;
            tcp.advance_snd(@intCast(len));
            tcp.record_pending();
            return len;
        },
        else => return error_result(.einval),
    }
}

/// Slot 32: `sys_tcp_recv(buf, max)`: Receive up to max bytes into user buffer.
fn handle_tcp_recv(args: Args, _: *exceptions.VectorFrame) u64 {
    const address = args[0];
    var max = args[1];
    if (max == 0) return 0;
    if (max > tcp.payload_max) max = tcp.payload_max;
    if (tcp.state != .established and tcp.state != .closed and tcp.state != .fin_sent and tcp.state != .listen and tcp.state != .syn_received) {
        return error_result(.einval);
    }
    if (!tcp_owned_by_caller()) return error_result(.eacces);

    virtio_net.net_rx_drain();

    tcp_flush_rst(); // M84f: the refusal goes before the built ACK
    if (tcp.ack_pending) {
        var out_len: usize = 0;
        if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len) == .ok) {
            tcp.ack_pending = false;
            tcp.ack_sent += 1;
        }
    }

    if (tcp.state != .established and tcp.state != .closed and tcp.state != .fin_sent) {
        return 0;
    }

    if (!tcp.rx_pending) return 0;

    const take = @min(@as(usize, @intCast(max)), tcp.rx_len);
    if (uaccess.copy_out(address, tcp.rx_payload[0..take], take) != .ok) return error_result(.efault);
    if (take == tcp.rx_len) {
        _ = tcp.take_rx();
    } else {
        std.mem.copyForwards(u8, tcp.rx_payload[0 .. tcp.rx_len - take], tcp.rx_payload[take..tcp.rx_len]);
        tcp.rx_len -= take;
        tcp.rx_pending = true;
    }
    return @intCast(take);
}

/// Slot 33: `sys_tcp_close()`: Initiate client FIN teardown.
fn handle_tcp_close(_: Args, _: *exceptions.VectorFrame) u64 {
    if (tcp.state == .idle) return 0;
    if (!tcp_owned_by_caller()) return error_result(.eacces);
    if (tcp.state == .listen) {
        tcp.reset();
        return 0;
    }
    if (tcp.state == .established) {
        // M84f (#1836): the shared-slot discipline — flush the refusal's
        // own slot, then a built segment (a queued SYN-ACK/ACK) before the
        // FIN build overwrites it (as in `handle_tcp_send`).
        tcp_flush_rst();
        if (tcp.ack_pending) {
            var ctl_len: usize = 0;
            if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &ctl_len) != .ok) return error_result(.einval);
            tcp.ack_pending = false;
            tcp.ack_sent += 1;
        }
        tcp.build_fin_msg();
        var out_len: usize = 0;
        if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len) == .ok) {
            tcp.fin_sent += 1;
            tcp.advance_snd(1);
            tcp.record_pending();
            tcp.state = .fin_sent;
        }
    }

    var iterations: usize = 0;
    while (tcp.state == .fin_sent and iterations < 100000) : (iterations += 1) {
        virtio_net.net_rx_drain();
    }

    tcp_flush_rst(); // M84f: a refusal queued by the drains above still goes
    if (tcp.ack_pending or tcp.state == .closed) {
        if (tcp.ack_pending) {
            var out_len: usize = 0;
            if (virtio_net.net_tcp_send(tcp.msg[0..tcp.msg_len], &out_len) == .ok) {
                tcp.ack_pending = false;
                tcp.ack_sent += 1;
            }
        }
        tcp.release_conn();
    }

    if (!tcp.is_server) {
        tcp.owner_pid = null;
    }
    return 0;
}

/// M29 VM Depth: sys_mmap(addr, len, prot, flags) — slot 63.
/// Maps an anonymous memory region into user address space.
/// prot: 1=PROT_READ, 2=PROT_WRITE, 4=PROT_EXEC.
/// flags: 0x20=MAP_ANONYMOUS, 0x02=MAP_PRIVATE, 0x8000=MAP_POPULATE.
///
/// M33 SB1/SB2 (claims 7418/8878): bit 16 (0x10000) `M33_MAP_SHARED` is the
/// seam-B shared-anonymous flag (ADR 0016, ACCEPTED; ABI frozen in ADR 0007).
/// Implemented by SB2: a request carrying bit 16 is handled by
/// `handle_mmap_shared` (owner create / owner re-map keep / registered-WM RO
/// attach by handle); every other call takes the plain M29 path below.
/// Returns allocated virtual address on success, or -error.
fn handle_mmap(args: Args, _: *exceptions.VectorFrame) u64 {
    const addr = args[0];
    const len = args[1];
    const prot = args[2];
    const flags = args[3];

    // Issue #1163 (GOOS=virelai phase 0a): 16 MiB → 1 GiB per call — the
    // gc Go runtime's sbrk layer maps its heap growth in one call (the
    // first-target run straced a 512 MiB sysReserve). Demand-backed: only
    // touched pages are recorded and charged, so a huge reservation costs
    // region bookkeeping, not physical memory.
    if (len == 0 or len > 1024 * 1024 * 1024) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const pinfo = process.info(pid) orelse return error_result(.einval);
    // #2115: a process already over its memory rlimit gets a named ENOMEM —
    // the limit verdict is honest at the door, not silently ignored until
    // the physical pool runs dry. At-limit (not yet over) callers may still
    // reserve: demand populate refuses per-page at the ceiling.
    if (process.check_mem_limit(pid)) return error_result(.enomem);

    // M33 SB2 (claim 8878): seam-B cross-process shared-anonymous surfaces
    // (ADR 0016, the `M33_MAP_SHARED` flag bit 16 — implemented now). Three
    // shapes are resolved in handle_mmap_shared: owner-create, owner re-map
    // (idempotent keep), and the registered WM's RO attach by handle. The
    // plain M29 path below is untouched for every other call.
    if ((flags & m33_map_shared) != 0) {
        return handle_mmap_shared(addr, len, prot, flags, pid, pinfo);
    }

    const aligned_len = (len + 4095) & ~@as(u64, 4095);
    var va: u64 = 0;
    if (addr != 0 and (addr & 4095) == 0) {
        va = addr;
    } else {
        va = process.next_mmap_va(pid, aligned_len);
    }
    // Issue #1214: a mapping may never alias a region the process already
    // owns (text/rodata/data/STACK apertures or an earlier mmap). The hint
    // is honored only when it is honest — the GOOS=virelai sbrk heap once
    // swallowed its own randomized stack aperture here and the runtime's
    // arena trims wiped the live EL0 stack (the go-args boot flake).
    if (process.mmap_collides(pid, va, aligned_len)) return error_result(.einval);
    // #2092: the range must also be committable EL0 under this root. Every
    // user root clones the EL1-only identity overlay verbatim, so a hint
    // whose slot holds a kernel-live leaf (pooled RAM, or a device window
    // above the blanket) would shadow memory the kernel itself dereferences
    // under this TTBR0 — or, for a wrapped hint near 2^64, defeat the
    // collision check above entirely. The mapping layer refuses the same
    // leaves on demand-populate; this is the early EINVAL at registration.
    // A zero root (host tests without a built root) has no leaves to check.
    if (pinfo.root_phys != 0 and !mmu.user_range_free(pinfo.root_phys, va, aligned_len)) return error_result(.einval);

    // ADR 0027 review finding 2: uaccess visibility for mappings is
    // PROCESS-scope. The region is registered once on the process and
    // arm_task_regions merges it into every task's uaccess view at each SVC
    // entry — so a mapping is visible to every M of the process, including
    // mappings made after a thread was created (the old per-TCB
    // registration missed exactly those; sys_mmap added the region to the
    // CALLING task only). The process registry (max_mmap_regions = 16) is
    // the only capacity gate; a full table refuses LOUDLY here rather than
    // half-registering (issue #1163 A1's rule).
    if (!process.add_mmap_region(pid, va, aligned_len, prot, flags)) return error_result(.enomem);

    // MAP_POPULATE (eager allocation)
    if ((flags & 0x8000) != 0) {
        const pages = aligned_len / 4096;
        var i: u64 = 0;
        while (i < pages) : (i += 1) {
            const pa = alloc.alloc_pages(1) orelse break;
            if (!builtin.is_test) {
                @memset(@as([*]u8, @ptrFromInt(pa))[0..4096], 0);
            }
            if (!process.record_dynamic_page(pid, pa)) {
                _ = alloc.free_pages(pa, 1);
                break;
            }
            if (!mmu.map_user_page(pinfo.root_phys, va + i * 4096, pa, (prot & 2) != 0, (prot & 4) != 0)) {
                _ = process.forget_dynamic_page(pid, pa);
                _ = alloc.free_pages(pa, 1);
                break;
            }
        }
        if (i != pages) {
            unmap_dynamic_pages(pid, pinfo.root_phys, va, i);
            _ = process.remove_mmap_region(pid, va, aligned_len);
            return error_result(.enomem);
        }
    }

    return va;
}

/// M29 / M33 flags on `sys_mmap` (slot 63).
const map_anonymous: u64 = 0x20; // M29: MAP_ANONYMOUS
const map_populate: u64 = 0x8000; // M29: MAP_POPULATE (eager allocation)
const m33_map_shared: u64 = 0x10000; // M33 SB1 (claim 7418): M33_MAP_SHARED (ADR 0016 seam B, frozen in ADR 0007)
/// M33 SB3 (claim 9361): when `addr` to a M33_MAP_SHARED `sys_mmap` carries
/// this high tag, the low 8 bits name a USER WINDOW ID the caller owns, and
/// the kernel creates + binds the shared surface AS that window's rendering
/// back-buffer (the surface handoff). The tag is unambiguously outside the
/// page-aligned owner-VA namespace (>= 0x10000000) and the `< 0x1000` handle
/// namespace, so it cannot collide with the SB2 create/keep/attach paths.
pub const m33_surf_win_tag: u64 = 0x8000_0000_0000_0000;

/// M33 SB5 (claim 7397): the SCANOUT tag — when `addr` to a M33_MAP_SHARED
/// `sys_mmap` carries this tag, the REGISTERED WM maps the virtio-gpu
/// framebuffer WRITABLE into its own root (the compose-N target). The WM
/// composites the N migrated surfaces into this view and REQUEST_PRESENT
/// flushes it. WM seat + full-frame + writable only; kernel-owned pages
/// (never ref'd/unref'd). Distinct bit from the SB3 window tag (63 vs 62).
pub const m33_surf_scan_tag: u64 = 0x4000_0000_0000_0000;

/// M33 SB2 (claim 8878): seam-B shared-anonymous mmap (ADR 0016 D1/D2, the
/// frozen `M33_MAP_SHARED` bit 16). The physical pages are allocated ONCE and
/// mapped into two roots: the owner's WRITABLE leaf (its own root) and the
/// registered WM's EL0-RO `sw_cow` leaf (the WM's own root, at its own va).
///
/// Call encoding (the handle is the capability identity per ADR 0016 D1.2 and
/// no new syscall slot exists, so `addr` carries it for a peer attach):
///   - owner CREATE: `sys_mmap(addr=0|<va>, len, prot >= WRITE, MAP_ANON|SHARED)`
///   - owner re-map of its own region: same call at its owner_va -> returns
///     the existing va (idempotent keep; D2 "the creator always retains its
///     own surface").
///   - WM attach: `sys_mmap(addr=<handle>, len, prot=READ, MAP_ANON|SHARED)`
///     -> maps the region RO into the WM's root, returns the WM's own va.
///
/// Error contract (ADR 0007): EINVAL (writable peer view / inapplicable
/// prot-geometry / full-region-only violation), EACCES (unauthorized peer
/// re-map), ENOSPC (region table full), EFAULT (stale/revoked handle),
/// ENOMEM (physical allocation or region-list exhaustion).
fn handle_mmap_shared(addr: u64, len: u64, prot: u64, flags: u64, pid: usize, pinfo: process.ProcessInfo) u64 {
    // The flag means shared-ANONYMOUS: a shared surface without MAP_ANONYMOUS
    // is inapplicable geometry (EINVAL).
    if ((flags & map_anonymous) == 0) return error_result(.einval);
    const aligned_len = (len + 4095) & ~@as(u64, 4095);

    // --- M33 SB3 (claim 9361): window-surface bind (the handoff) --------
    // `addr` carrying the window tag names a USER WINDOW ID the caller owns:
    // the kernel flips that window's rendering onto a freshly-created shared
    // surface (M33_MAP_SHARED), exactly sized to the window's back-buffer, so
    // the app renders with plain stores and composite() blits from the
    // surface's own pages. The frozen sys_win_open/fill/present slots (12-14)
    // are untouched: an unmigrated app never sets the tag and keeps the
    // kernel user_bufs path byte-identically. The surface is created + mapped
    // by the owner-create tail, then bound to the window.
    // --- M33 SB5 (claim 7397): scanout bind (the compose-N target) ------
    // `addr` carrying the scanout tag names the virtio-gpu framebuffer: the
    // REGISTERED WM (and only it) maps it writable into its own root, then
    // composites the N migrated shared surfaces into it and issues the final
    // present (REQUEST_PRESENT = flush). Full-frame only, kernel-owned pages.
    if ((addr & m33_surf_scan_tag) != 0) {
        return bind_scanout_surface(pid, pinfo, len, prot, flags);
    }
    if ((addr & m33_surf_win_tag) != 0) {
        const wid: u8 = @intCast(addr & 0xff);
        return bind_window_surface(wid, len, prot, flags, pid, pinfo);
    }

    // --- Owner re-map (idempotent keep) ---------------------------------
    // An owner re-mapping its own live region keeps it (D2: the creator
    // always retains its own surface); the return is the existing owner va.
    if (addr != 0 and (addr & 4095) == 0) {
        if (shared_region.find_owner(pid, addr) != null) return addr;
    }

    // --- WM (peer) attach by handle -------------------------------------
    // Handles are small kernel integers (1..max_shared_regions); real user
    // vais are page-aligned and >= 0x10000000, so `addr < 0x1000`
    // unambiguously names a handle-based peer attach.
    if (addr != 0 and addr < 0x1000) {
        const handle: u32 = @intCast(addr);
        const r = shared_region.info(handle) orelse return error_result(.efault); // .gone
        // The OWNER attaching by handle keeps its writable surface (D2 "the
        // creator always retains its own surface"); it NEVER maps a redundant
        // RO/COW view of itself (the SB1 review fix: `.grant` for the owner
        // is permission-to-keep, not a leaf to install).
        if (r.owner_pid == @as(u64, pid)) return r.owner_va;
        // One peer seat per region (the D2 trust boundary: the WM only).
        if (r.peer_pid != 0) {
            if (r.peer_pid == @as(u64, pid)) return r.peer_va; // idempotent keep
            return error_result(.eacces); // a second peer seat is refused today
        }
        if ((prot & 1) == 0) return error_result(.einval); // a read view is required
        const want_writable = (prot & 2) != 0;
        const wm_peer = wm_server.registered_pid() orelse 0;
        switch (shared_region.authorize_read(pid, handle, want_writable, wm_peer)) {
            .grant => {},
            .writable_refused => return error_result(.einval),
            .not_authorized => return error_result(.eacces),
            .gone => return error_result(.efault),
            .capacity => return error_result(.enospc),
        }
        // Full-region attach only (teardown is full-region only, D2).
        if (aligned_len != @as(u64, r.page_count) * 4096) return error_result(.einval);
        // The peer maps at ITS OWN va in ITS OWN root (ADR 0016 D1).
        const peer_va = process.next_mmap_va(pid, aligned_len);
        // Issue #1214: a peer mirror may not alias the peer's own regions.
        if (process.mmap_collides(pid, peer_va, aligned_len)) return error_result(.einval);
        // #2092: nor may it land on a kernel-live leaf of the peer's root.
        if (pinfo.root_phys != 0 and !mmu.user_range_free(pinfo.root_phys, peer_va, aligned_len)) return error_result(.einval);
        if (!process.add_mmap_region(pid, peer_va, aligned_len, prot, flags)) return error_result(.enomem);
        if (!shared_mmap.map_peer_leaves(pinfo.root_phys, peer_va, r.page_count, r.pa_base)) {
            // #2114: map_peer_leaves self-unwinds its installed leaves+refs
            // — the attach only drops the region row it reserved.
            _ = process.remove_mmap_region(pid, peer_va, aligned_len);
            return error_result(.enomem);
        }
        _ = shared_region.grant_read(handle);
        _ = shared_region.set_peer(handle, pid, peer_va);
        if (!uaccess.add_read_region(.{ .base = peer_va, .len = aligned_len })) return error_result(.enomem);
        return peer_va;
    }

    // --- Owner create ----------------------------------------------------
    // The shared surface is render-into: the owner's leaf is writable, so a
    // create without PROT_WRITE is inapplicable geometry (EINVAL).
    if ((prot & 2) == 0) return error_result(.einval);
    var va: u64 = 0;
    if (addr != 0 and (addr & 4095) == 0) {
        va = addr;
    } else {
        va = process.next_mmap_va(pid, aligned_len);
    }
    // Issue #1214: the same collision rule as the plain path — a shared
    // surface may not alias the owner's own apertures/regions.
    if (process.mmap_collides(pid, va, aligned_len)) return error_result(.einval);
    // #2092: and the same kernel-live bound — a hinted shared surface may
    // not shadow pooled RAM or a device window under the owner's root.
    if (pinfo.root_phys != 0 and !mmu.user_range_free(pinfo.root_phys, va, aligned_len)) return error_result(.einval);
    const cs = owner_create_shared_surface(pid, pinfo, va, aligned_len, prot, flags);
    return switch (cs) {
        .ok => |o| o.va,
        .enospc => return error_result(.enospc),
        .enomem => return error_result(.enomem),
    };
}

/// The result of an OWNER shared-surface create: either the region physical
/// identity (handle + the contiguous pa set) or the failure code. Used by
/// both the plain `sys_mmap(M33_MAP_SHARED)` owner create and the SB3
/// window-surface bind path — ONE create/map/record implementation.
const OwnerSurface = union(enum) {
    ok: struct { va: u64, handle: u32, pa_base: u64, page_count: u32 },
    enospc: void,
    enomem: void,
};

/// Create + map an OWNER shared surface: establish the `SharedRegion`
/// descriptor, allocate the contiguous pages once, install the owner's
/// WRITABLE leaves into `pinfo.root_phys` at `va`, record the pages in the
/// owner's `dynamic_pages` (so exit frees them), and set the region mapping.
/// `add_mmap_region` was already called by the caller (the va is reserved).
/// Returns the physical identity on success; `.enospc` (region table full)
/// or `.enomem` (allocation / leaf fail). On failure nothing is left
/// recorded: the caller's `mmap_region` row is the caller's to unwind.
fn owner_create_shared_surface(
    pid: usize,
    pinfo: process.ProcessInfo,
    va: u64,
    aligned_len: u64,
    prot: u64,
    flags: u64,
) OwnerSurface {
    const handle = shared_region.create(pid);
    if (handle == 0) return .enospc;
    if (!process.add_mmap_region(pid, va, aligned_len, prot, flags)) {
        _ = shared_region.drop_owner(handle);
        return .enomem;
    }
    const pages = aligned_len / 4096;
    const pa_base = alloc.alloc_pages(pages) orelse {
        _ = shared_region.drop_owner(handle);
        _ = process.remove_mmap_region(pid, va, aligned_len);
        return .enomem;
    };
    if (!builtin.is_test) {
        @memset(@as([*]u8, @ptrFromInt(pa_base))[0..aligned_len], 0);
    }
    const page_count: u32 = @intCast(pages);
    if (!shared_mmap.map_owner_leaves(pinfo.root_phys, va, page_count, pa_base, prot)) {
        var ui: u64 = 0;
        while (ui < pages) : (ui += 1) {
            _ = mmu.unmap_user_page(pinfo.root_phys, va + ui * 4096);
        }
        _ = alloc.free_pages(pa_base, pages);
        _ = shared_region.drop_owner(handle);
        _ = process.remove_mmap_region(pid, va, aligned_len);
        return .enomem;
    }
    var di: u64 = 0;
    while (di < pages) : (di += 1) {
        if (!process.record_dynamic_page(pid, pa_base + di * 4096)) {
            for (0..@intCast(di)) |ri| {
                _ = process.forget_dynamic_page(pid, pa_base + ri * 4096);
            }
            for (0..page_count) |ui| {
                _ = mmu.unmap_user_page(pinfo.root_phys, va + ui * 4096);
            }
            _ = alloc.free_pages(pa_base, pages);
            _ = shared_region.drop_owner(handle);
            _ = process.remove_mmap_region(pid, va, aligned_len);
            return .enomem;
        }
    }
    _ = shared_region.set_mapping(handle, va, page_count, pa_base);
    return .{ .ok = .{ .va = va, .handle = handle, .pa_base = pa_base, .page_count = page_count } };
}

/// M33 SB3 (claim 9361): bind user window `wid` to a freshly-created shared
/// surface THE SAME SIZE as the window's back-buffer, so composite() blits
/// from the surface's own pages and the registered WM mirrors the region RO.
/// `len` is the caller's requested surface size (validated >= the window's
/// back-buffer bytes; the region is sized to the window so composite's source
/// bounds are exact). The surface is owned by `pid`, which must OWN `wid`.
/// Frozen `sys_win_fill`/`sys_win_present`/`sys_win_open` are untouched: an
/// unmigrated window never calls this path.
///
/// The app renders with plain stores into the returned owner va; the WM reads
/// the bytes RO through its peer mirror (SB2 peer attach by handle). Teardown
/// is the same D2 rule: owner exit / window close (+ its surface) revokes the
/// WM mirror and frees at refcount 0.
/// M33 SB5 (claim 7397): bind the virtio-gpu framebuffer (the scanout) as
/// the registered WM's WRITABLE compose-N target. The WM seat is the
/// privilege boundary (EACCES otherwise); full-frame only (EINVAL);
/// compose-into requires PROT_WRITE (EINVAL); the framebuffer must exist
/// (ENXIO). Idempotent — a WM re-binding returns its existing va.
fn bind_scanout_surface(pid: usize, pinfo: process.ProcessInfo, len: u64, prot: u64, flags: u64) u64 {
    if (!wm_server.registered() or wm_server.registered_pid().? != pid) return error_result(.eacces);
    if ((prot & 2) == 0) return error_result(.einval); // compose-into requires a writable leaf
    const aligned_len = (len + 4095) & ~@as(u64, 4095);
    if (aligned_len != virtio_gpu.fb_size) return error_result(.einval); // full-frame only
    if (virtio_gpu.gpu_fb_phys == 0) return error_result(.enxio); // no framebuffer
    _ = flags; // the shared-anon flag bits are validated at the handle_mmap_shared entry
    const va = wm_server.scanout_bind(pid, pinfo);
    if (va == 0) return error_result(.einval); // seat refused / map failure
    return va;
}

fn bind_window_surface(wid: u8, len: u64, prot: u64, flags: u64, pid: usize, pinfo: process.ProcessInfo) u64 {
    const win = driving_award.find_user_window(wid) orelse return error_result(.einval);
    if (win.owner == null or win.owner.? != pid) return error_result(.eacces); // not the caller's window
    if (driving_award.user_is_surface_backed(wid)) return error_result(.einval); // one surface per window
    if ((prot & 2) == 0) return error_result(.einval); // render-into requires a writable leaf
    if (len == 0) return error_result(.einval);
    const aligned_len = (len + 4095) & ~@as(u64, 4095);
    // The surface must hold the window's B8G8R8X8 back-buffer.
    const win_bytes = @as(u64, win.w) * win.h * 4;
    if (aligned_len < win_bytes) return error_result(.einval);

    const va = process.next_mmap_va(pid, aligned_len);
    const cs = owner_create_shared_surface(pid, pinfo, va, aligned_len, prot, flags);
    const ok = switch (cs) {
        .ok => |o| o,
        .enospc => return error_result(.enospc),
        .enomem => return error_result(.enomem),
    };
    if (!driving_award.user_bind_surface(wid, .{
        .handle = ok.handle,
        .pa_base = ok.pa_base,
        .page_count = ok.page_count,
    })) {
        // Binding failed (window changed under us): tear the surface down.
        _ = shared_mmap.revoke_owner_va(pid, va);
        _ = process.remove_mmap_region(pid, va, aligned_len);
        return error_result(.einval);
    }
    // M33 SB3: if a WM is ALREADY registered, grant it the RO mirror now so
    // the surface is immediately compositable (the WM reads the app's bytes
    // through its peer leaf). The WM maps the region at ITS OWN va in ITS OWN
    // root (ADR 0016 D1); its next_mmap_va + mmap_region registration keep the
    // lifetime honest, so owner teardown revokes it via shared_mmap.rs.
    // (Auto-mirror runs only when a WM is genuinely registered; a registered
    // WM always has a live process row whose root the mirror maps into.)
    if (wm_server.registered_pid()) |wm_pid| {
        const wm_len = @as(u64, ok.page_count) * 4096;
        const wm_va = process.next_mmap_va(wm_pid, wm_len);
        const wmi = process.info(wm_pid);
        // #2114: the auto-mirror is a transaction — a failure reports the
        // error instead of returning a va whose mirror does not exist.
        // map_peer_leaves self-unwinds its installed leaves+refs, so the
        // failure path only drops the WM's region row.
        if (wmi == null or !process.add_mmap_region(wm_pid, wm_va, wm_len, 1, flags)) return error_result(.enomem);
        if (!shared_mmap.map_peer_leaves(wmi.?.root_phys, wm_va, ok.page_count, ok.pa_base)) {
            _ = process.remove_mmap_region(wm_pid, wm_va, wm_len);
            return error_result(.enomem);
        }
        _ = shared_region.grant_read(ok.handle);
        _ = shared_region.set_peer(ok.handle, wm_pid, wm_va);
    }
    // uaccess follows the OWNER only (the WM reads through its peer leaf,
    // never a uaccess aperture — the ADR 0016 D2 owner-side-only rule).
    // Shared-region adds cannot exhaust the lists here (the owner seat was
    // pre-checked above); a false means the caller's mapping is refused.
    if ((prot & 2) != 0) {
        if (!uaccess.add_write_region(.{ .base = va, .len = aligned_len })) return error_result(.enomem);
    }
    if ((prot & 1) != 0) {
        if (!uaccess.add_read_region(.{ .base = va, .len = aligned_len })) return error_result(.enomem);
    }
    return va;
}

/// M29 VM Depth: sys_munmap(addr, len) — slot 64.
/// Unmaps an anonymous memory region and frees physical pages.
fn handle_munmap(args: Args, _: *exceptions.VectorFrame) u64 {
    const addr = args[0];
    const len = args[1];

    if (addr == 0 or (addr & 4095) != 0 or len == 0) return error_result(.einval);
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const pinfo = process.info(pid) orelse return error_result(.einval);

    const aligned_len = (len + 4095) & ~@as(u64, 4095);
    // #2113: a wrapping range defeats every overlap check below — a len
    // near 2^64 would wrap aligned_len to a small value and the shared-
    // surface guard would read the wrong window. Refuse the wrap itself.
    if (aligned_len == 0 or addr +% aligned_len <= addr) return error_result(.einval);
    const pages = aligned_len / 4096;

    // M33 SB5 (claim 7397): the scanout grant is full-frame only; munmapping
    // it unbinds the WM's compositing privilege (unmap the leaves WITHOUT
    // unref — the GPU fb pages are kernel-owned — and clear the seat). This
    // MUST come before the generic loop below, which would unref the kernel's
    // framebuffer pages.
    if (wm_server.scanout_va_get()) |sva| {
        if (addr == sva) {
            if (aligned_len != virtio_gpu.fb_size) return error_result(.einval);
            wm_server.scanout_teardown();
            return 0;
        }
    }

    // M33 SB2 (claim 8878): shared-region teardown. munmap of a shared
    // surface is FULL-REGION only (a partial unmap is EINVAL). An OWNER
    // munmap revokes the peer RO seat first — the loop below then unmaps the
    // owner's own leaves and unrefs 1->0 (free), and since the descriptor is
    // already gone the loop never re-enters this path. A PEER munmap detaches
    // its RO seat (per-root teardown, ADR 0016 D1) and returns directly.
    // #2113: the guard is range-aware — `covers` tested only the range
    // START, so a range beginning before a surface and overlapping it fell
    // through to the generic unmap and stripped the shared leaves while the
    // descriptor + WM mirror stayed live.
    switch (shared_region.munmap_match(@as(u64, pid), addr, aligned_len)) {
        .none => {},
        .partial => return error_result(.einval),
        .owner => _ = shared_mmap.revoke_owner_va(pid, addr),
        .peer => {
            _ = shared_mmap.detach_peer(pid, addr);
            _ = process.remove_mmap_region(pid, addr, aligned_len);
            uaccess.remove_region(addr, aligned_len);
            return 0;
        },
    }

    unmap_dynamic_pages(pid, pinfo.root_phys, addr, pages);

    _ = process.remove_mmap_region(pid, addr, aligned_len);
    uaccess.remove_region(addr, aligned_len);
    return 0;
}

fn unmap_dynamic_pages(pid: usize, root: u64, addr: u64, pages: u64) void {
    for (0..@intCast(pages)) |i| {
        const va = addr + i * 4096;
        // The identity overlay and static apertures are not mmap backing.
        if (!mmu.leaf_el0_visible(root, va)) continue;
        const leaf = mmu.get_user_leaf(root, va) orelse continue;
        const pa = leaf.* & 0x0000_ffff_ffff_f000;
        if (!process.forget_dynamic_page(pid, pa)) continue;
        _ = mmu.unmap_user_page(root, va);
        _ = alloc.unref_page(pa);
    }
}

// ---------------------------------------------------------------------------
// M32 WMS2 (issue #622): slot 65 — sys_wmctl, the render-server register
// ---------------------------------------------------------------------------

/// `sys_wmctl(cmd, a0, a1, a2, ptr, len)` — slot 65. The REGISTERED WM
/// server's exclusive control surface over the kernel render server
/// (ADR 0015 seam A). Subcommand encoding frozen by WMS1 (claim 1484):
/// 1=REGISTER, 2=SET_WINDOW, 3=REQUEST_PRESENT.
///
/// Error contract (ADR 0007 slot-65 amendment):
///   - non-process caller (an EL1h task) → EINVAL
///   - REGISTER: second registration → EACCES (seat taken); no GPU /
///     unarmed compositor → ENXIO (the sys_audio_play no-device precedent);
///     success → 0.
///   - SET_WINDOW / REQUEST_PRESENT with no WM registered → ENOSYS.
///   - SET_WINDOW / REQUEST_PRESENT from a process other than the registered
///     WM → EACCES.
///   - SET_WINDOW: reserved — the chrome-descriptor layout is not frozen
///     until WMS4; the opcode validates the caller is the WM then returns
///     EINVAL (no window submission exists in WMS2).
///   - unknown / zero `cmd` → EINVAL.
///
/// Zero-regression: when no WM is registered, SET_WINDOW / REQUEST_PRESENT
/// return ENOSYS and the shell idle shim composites exactly as today. Only
/// REGISTER (which requires an armed compositor) puts the seam to work.
fn handle_wmctl(args: Args, _: *exceptions.VectorFrame) u64 {
    const pid = process.find_by_task(scheduler.current_id()) orelse return error_result(.einval);
    const cmd = args[0];
    switch (cmd) {
        wm_server.wmctl_register => {
            // One seat (ADR 0007: seat taken → EACCES).
            if (wm_server.registered()) return error_result(.eacces);
            // No GPU / unarmed compositor → ENXIO (the no-device precedent).
            // `gpu_setup_ok` is the honest G1-armed signal (a flushed
            // scanout) and is deterministically false in host tests and in
            // the headless default VM.
            if (!virtio_gpu.gpu_setup_ok) return error_result(.enxio);
            // #2079 (M97g seat gate): registering arms the raw key/pointer
            // fan-out and the writable scanout, so the caller must hold a
            // kernel-recorded spawn provenance (kernel-spawned, or a
            // launcher child bearing the configured seat program name) or
            // cap_proc_admin. A process an arbitrary EL0 app can spawn —
            // including one whose file is named like the seat — is refused
            // BEFORE the fan-out hooks arm.
            if (!wm_server.seat_authorized(pid, scheduler.current_id())) return error_result(.eacces);
            _ = wm_server.register(pid);
            // Claim 9498: the registered WM stays on CORE 0 — its
            // COMPOSITE_TICK pacing is delivered from core 0's tick, so
            // floating it to a secondary core would decouple the render
            // server from the pacing clock. (User tasks default to any
            // core; this pins the one tick-coupled process back.)
            _ = scheduler.pin_task(scheduler.current_id(), 0);
            return 0;
        },
        wm_server.wmctl_seat_pid => {
            // #2079: pid-based seat discovery — WM clients resolve the seat
            // from the kernel's register, not from a forgeable name.
            // Unprivileged read-only query; ENOENT when no seat is held.
            return if (wm_server.registered_pid()) |seat| @as(u64, seat) else error_result(.enoent);
        },
        wm_server.wmctl_content_ptr => {
            // #1688: the registered seat forwards one content pointer
            // sample (a0 = x|(y<<16), a1 = button mask) for the kernel's
            // local path — terminal text selection + mouse-tracking
            // reports. Edges derive from the serialized stream in
            // driving_award; consumed chrome never arrives here.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const fwd_x: u32 = @as(u16, @truncate(args[1]));
            const fwd_y: u32 = @truncate(args[1] >> 16);
            driving_award.wm_content_pointer(fwd_x, fwd_y, @truncate(args[2]));
            return 0;
        },
        wm_server.wmctl_set_window => {
            // M32 WMS4 (issue #624): the WM submits a chrome descriptor.
            // M32 WMS5 (issue #625): the frozen ADR 0007 a1/a2 encoding
            // ACTIVATES — the same call carries the WM's proposed rect
            // (a1 = x|(y<<16), a2 = w|(h<<16)) and/or the 40-byte chrome
            // descriptor (len 40; len 0 = chrome unchanged). A nonzero a1
            // or a2 means geometry; the kernel applies it through the
            // clamped user_move/user_resize (WM proposes, kernel clamps).
            // The ALL broadcast stays chrome-only (a0 = 0xFFFFFFFF with
            // geometry is refused — geometry is per-window).
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const window_id = args[1];
            const rect_xy = args[2];
            const rect_wh = args[3];
            const have_geom = (rect_xy != 0 or rect_wh != 0);
            if (have_geom) {
                // Per-window only: the broadcast sets the chrome POLICY, and
                // geometry for every window at once is a WMS6 concern.
                if (window_id == wnd_core.chrome_window_all) return error_result(.einval);
                if (window_id > 0xff) return error_result(.einval);
                const x: u32 = @intCast(rect_xy & 0xffff);
                const y: u32 = @intCast(rect_xy >> 16);
                const w: u32 = @intCast(rect_wh & 0xffff);
                const h: u32 = @intCast(rect_wh >> 16);
                // M32 WMS5 Gate 2 (claim 4278): apply with LAYOUT semantics
                // — on-scanout clamping only (no back-buffer clamp), so the
                // WM can produce the SAME rects the shim's tile/maximize
                // write directly (the W1–W16 registered-matrix parity bar).
                // WM proposes, kernel clamps to the scanout, mirror follows.
                if (!driving_award.wm_apply_rect(@intCast(window_id), x, y, w, h)) return error_result(.einval); // bad id
            }
            // Chrome: len 40 = the frozen v1 descriptor (WMS4, unchanged —
            // zero-extended, rest_alpha reads 0 = the v1 opaque default);
            // len 48 = the WM4 v2 descriptor (rest-opacity tail); len 0 =
            // chrome left as-is (a pure geometry call). Any other length is
            // refused.
            if (args[5] != 0 and args[5] != wnd_core.chrome_desc_bytes and args[5] != wnd_core.chrome_desc_bytes_v2) return error_result(.einval); // frozen lengths
            if (args[5] != 0) {
                const len: usize = @intCast(args[5]);
                var desc: wnd_core.ChromeDesc = undefined;
                const desc_bytes: [*]u8 = @ptrCast(&desc);
                // v1 (40) zero-extends: the rest_alpha tail reads 0, which
                // normalizes to 256 (the v1 behavior, byte-identical).
                @memset(desc_bytes[0..wnd_core.chrome_desc_bytes_v2], 0);
                if (uaccess.copy_in(desc_bytes[0..len], args[4], len) != .ok) {
                    return error_result(.efault); // bad descriptor pointer
                }
                // The one validation rule (single source in wnd_core): unknown
                // kind/flag bits and out-of-range rest alpha are EINVAL.
                // Zero kind disables per-window chrome; zero broadcast is
                // still refused (M91f, ADR 0007 amendment).
                if (!wnd_core.chrome_valid_for_window(window_id, desc)) return error_result(.einval);
                if (!driving_award.set_window_chrome(window_id, desc)) return error_result(.einval); // bad id
            }
            wm_server.note_set_window();
            return 0;
        },
        wm_server.wmctl_set_state => {
            // M32 WMS5 Gate 2 (issue #625, claim 4278): the visibility /
            // workspace / always-on-top channel of the geometry seam.
            // Encoding (frozen in ADR 0007 by this claim):
            //   a0 = window id; 0xFFFFFFFF = GLOBAL (workspace switch)
            //   a1 bits 0-1   = visibility: 0 = hide (minimize), 1 = show
            //                   (restore), 2/3 = no change
            //   a1 bits 8-15  = workspace (0-2), or 0xff = no change
            //   a1 bit 16     = always-on-top toggle (1 = toggle)
            // Per-window: applied through the SAME clamped kernel primitives
            // the shim uses (user_set_visible / user_move_to_workspace /
            // toggle_always_on_top). GLOBAL (a0 = ALL): bits 8-15 name the
            // target workspace and the kernel switches the current workspace
            // (switch_workspace — the W4 ws-switch path); EINVAL if absent.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const window_id = args[1];
            const state = args[2];
            if (window_id == wnd_core.chrome_window_all) {
                const ws = @as(u8, @intCast((state >> 8) & 0xff));
                // `switch_workspace` itself refuses `>= workspace_max` — the
                // handler validates BEFORE the call so the refusal is honest
                // (EINVAL, not a silent no-op).
                if (ws >= driving_award.workspace_max) return error_result(.einval);
                driving_award.switch_workspace(ws);
                wm_server.note_set_state();
                return 0;
            }
            if (window_id > 0xff) return error_result(.einval);
            const visible: ?bool = switch (state & 0x3) {
                0 => false, // explicit hide (minimize)
                1 => true, // explicit show (restore)
                else => null, // 2/3: no visibility change
            };
            const ws = @as(u8, @intCast((state >> 8) & 0xff));
            if (visible) |v| {
                if (!driving_award.user_set_visible(@intCast(window_id), v)) return error_result(.einval); // bad id
            } else if (ws >= driving_award.workspace_max and ws != 0xff) {
                return error_result(.einval); // out-of-range workspace
            } else {
                // No visibility change and no valid workspace: the window id
                // is still validated (a pure state call must name a window).
                if (driving_award.find_user_window(@intCast(window_id)) == null) return error_result(.einval);
            }
            if (ws < driving_award.workspace_max) {
                _ = driving_award.user_move_to_workspace(@intCast(window_id), ws);
            }
            if ((state & (1 << 16)) != 0) {
                _ = driving_award.toggle_always_on_top(@intCast(window_id));
            }
            wm_server.note_set_state();
            return 0;
        },
        wm_server.wmctl_alt_tab => {
            // M32 WMS6 Gate A (issue #626): the WM — not the kernel —
            // decides which window Alt+Tab switches to. a0 = window id,
            // a1 = action: 1/2 activate|cycle (highlight the id in the
            // overlay snapshot), 3 commit (focus + raise + dismiss to the
            // id), 4 dismiss (drop the overlay). The kernel clamps (id must
            // name a live user / alt-tab window, the M21 W3/W4 rules) and
            // repaints the overlay blit from the WM's declared choice.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const window_id = args[1];
            const action = args[2];
            switch (action) {
                wm_server.alt_tab_commit => {
                    if (window_id > 0xff) return error_result(.einval);
                    if (!driving_award.alt_tab_wm_commit(@intCast(window_id))) return error_result(.einval); // bad id
                },
                wm_server.alt_tab_activate, wm_server.alt_tab_cycle => {
                    if (window_id > 0xff) return error_result(.einval);
                    if (!driving_award.alt_tab_overlay_focus(@intCast(window_id))) return error_result(.einval); // not a live alt-tab target
                },
                wm_server.alt_tab_dismiss => driving_award.alt_tab_dismiss(),
                else => return error_result(.einval), // unknown action
            }
            wm_server.note_alt_tab();
            return 0;
        },
        wm_server.wmctl_notif_center => {
            // M32 WMS6 Gate B (issue #626): the WM — not the kernel —
            // decides the notification center's open/close/clear (the raw
            // tray click already fanned to it as kind 19 with the button
            // byte). a0 = 0 close, 1 open, 2 clear-all. The kernel clamps +
            // blits from its own `notif_center_open` / ring.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const action = args[1];
            switch (action) {
                0 => driving_award.notif_center_set_open(false),
                1 => driving_award.notif_center_set_open(true),
                2 => driving_award.notif_center_clear_all(),
                else => return error_result(.einval), // unknown action
            }
            wm_server.note_notif_center();
            return 0;
        },
        wm_server.wmctl_notif_dismiss => {
            // M32 WMS6 Gate B (issue #626): dismiss one notification row.
            // a0 = index; the kernel dismisses it (honestly refusing an
            // out-of-range index).
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const index = args[1];
            if (index > 0xff) return error_result(.einval);
            if (!driving_award.notif_center_dismiss(@intCast(index))) return error_result(.einval); // out of range
            wm_server.note_notif_dismiss();
            return 0;
        },
        wm_server.wmctl_tooltip => {
            // M32 WMS6 Gate C (issue #626): the WM — not the kernel — decides
            // WHEN a tooltip shows and WHAT it says (the raw hover already
            // fanned to it as kind 19). a0 = 0 hide / 1 show; for show,
            // ptr/len carry the text (the 32-byte M27 bound, copied in like
            // the chrome descriptor). The kernel clamps + places + blits the
            // box below its own cursor.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const action = args[1];
            switch (action) {
                0 => driving_award.tooltip_clear(),
                1 => {
                    const len = args[5];
                    if (len == 0 or len > 32) return error_result(.einval); // frozen bound
                    var text: [32]u8 = undefined;
                    const text_bytes: *[32]u8 = @ptrCast(&text);
                    if (uaccess.copy_in(text_bytes, args[4], len) != .ok) {
                        return error_result(.efault); // bad text pointer
                    }
                    driving_award.tooltip_show(text[0..@intCast(len)]);
                },
                else => return error_result(.einval), // unknown action
            }
            wm_server.note_tooltip();
            return 0;
        },
        wm_server.wmctl_dock => {
            // M32 WMS6 Gate D (issue #626): the WM — not the kernel — decides
            // which dock icon a click hits (the raw click already fanned to it
            // as kind 19 with the button byte). a0 = icon index (0..4); the
            // kernel applies the SAME clamped chain the shim runs
            // (restore-first-minimized -> focus/raise -> open), so a WM
            // decision and a shim click are identical actions.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const idx = args[1];
            if (idx > 4) return error_result(.einval); // the bar has 5 icons
            if (!driving_award.dock_icon_click(@intCast(idx))) return error_result(.einval);
            wm_server.note_dock();
            return 0;
        },
        wm_server.wmctl_tray => {
            // M32 WMS6 Gate E (issue #626): the WM — not the kernel — owns
            // the tray widget content (clock string, theme letter, clipboard
            // indicator). a0 = flags (bit 0 clock, bit 1 theme, bit 2
            // clipboard); a1 = the 5-byte "HH:MM" clock text packed
            // little-endian; a2 = theme letter (low byte) | clipboard filled
            // (bit 8). The kernel clamps each declared field to the frozen
            // bounds and repaints; a missing field leaves the shim fallback
            // for that widget (and WM teardown restores all three).
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const flags = args[1];
            if (flags & ~@as(u64, 0b111) != 0) return error_result(.einval); // unknown flag bits
            var clock: ?[]const u8 = null;
            var text: [5]u8 = undefined;
            if ((flags & 0b001) != 0) {
                const clock_packed = args[2];
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    const ch: u8 = @intCast((clock_packed >> @intCast(i * 8)) & 0xff);
                    const ok = (ch >= '0' and ch <= '9') or ch == ':'; // HH:MM charset
                    if (!ok) return error_result(.einval);
                    text[i] = ch;
                }
                clock = text[0..5];
            }
            var theme: ?u8 = null;
            var clip: ?bool = null;
            if ((flags & 0b110) != 0) {
                const letter: u8 = @intCast(args[3] & 0xff);
                if ((flags & 0b010) != 0) {
                    if (letter != 'D' and letter != 'L' and letter != 'A') return error_result(.einval);
                    theme = letter;
                }
                if ((flags & 0b100) != 0) clip = (args[3] >> 8) & 1 != 0;
            }
            driving_award.tray_set(clock, theme, clip);
            wm_server.note_tray();
            return 0;
        },
        wm_server.wmctl_taskbar => {
            // WM3 (issue #707 card 3): the WM — not the kernel — decides
            // which taskbar entry a click hit (the raw DOWN EDGE already
            // fanned to it as kind 19; the entry rects are the shared
            // wnd_core rule). a0 = the entry's window id; the kernel
            // clamps (the id must name a live user window) and applies the
            // SAME chain a shim click would run (restore-if-minimized,
            // else focus + raise), so a WM decision and a click on the
            // same window are identical actions.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const window_id = args[1];
            if (window_id > 0xff) return error_result(.einval);
            if (!driving_award.taskbar_click(@intCast(window_id))) return error_result(.einval); // bad id
            wm_server.note_taskbar();
            return 0;
        },
        wm_server.wmctl_win_close => {
            // M42 UX (2026-09-05, TABWM tab-close seam): the WM — not the
            // kernel — decides WHEN a window closes (the tab 'x' click);
            // the kernel applies its OWN release primitive
            // (`driving_award.user_close`, the shim/dui-close path) so the
            // owner gets the real WIN_CLOSE event push and the WM gets the
            // released kind-20 mirror. a0 = window id; EINVAL for an
            // unknown id / non-user window. WM-seat-only like every cmd.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const window_id = args[1];
            if (window_id > 0xff) return error_result(.einval);
            if (!driving_award.user_close(@intCast(window_id))) return error_result(.einval); // bad id
            wm_server.note_win_close();
            return 0;
        },
        wm_server.wmctl_window_name => {
            // #1056 item 2: the WM resolves a window's display name — the
            // app-set title if any, else the OWNING process's executable
            // name (driving_award.user_display_name). a1 = window id,
            // a2 = destination buffer, a3 = length. Copies the name OUT and
            // returns its byte count (0 bytes is a valid empty name); EINVAL
            // for an unknown/non-user window, EFAULT for a bad buffer.
            // Seat-gated like every other WMCTL command.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            if (args[1] > std.math.maxInt(u8)) return error_result(.einval);
            const name = driving_award.user_display_name(@intCast(args[1])) orelse return error_result(.einval);
            const cap: usize = @intCast(@min(args[3], 64));
            const n = @min(name.len, cap);
            if (n > 0 and uaccess.copy_out(args[2], name[0..n], n) != .ok) return error_result(.efault);
            return n;
        },
        wm_server.wmctl_dialog => {
            // M32 WMS8 Gate 2 (issue #628): the WM — not the kernel — owns
            // the keyboard-driven modal-dialog decision (M27 G2 about,
            // Ctrl+Shift+A). The WM receives kind 21 and issues DIALOG; the
            // kernel applies the SAME clamped primitives the shim runs
            // (`about_dialog_open_dialog` / `about_dialog_close` /
            // `about_dialog_toggle`) so a WM decision and a shim chord are
            // byte-identical (parity by construction). a0 = 0 close,
            // 1 open, 2 toggle. The kernel still blits the modal from its
            // own `about_dialog_open` state.
            // M32 WMS8 Gate 4 (issue #628): the UNSAVED-changes dialog rides
            // the same seam — a0 = 3 show (a1 = target window, validated),
            // 4 save, 5 dont-save, 6 cancel — applied through the kernel's
            // own `unsaved_dialog_*` primitives (parity by construction).
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const action = args[1];
            switch (action) {
                0 => driving_award.about_dialog_close(),
                1 => driving_award.about_dialog_open_dialog(),
                2 => driving_award.about_dialog_toggle(),
                3 => {
                    const target: u8 = @truncate(args[2]);
                    if (driving_award.find_user_window(target) == null) return error_result(.einval);
                    driving_award.unsaved_dialog_show(target);
                },
                4, 5, 6 => {
                    // Review fix (claim 7639): the button actions act on the
                    // OPEN dialog's target — refuse when nothing is open (the
                    // shim's click path returned `.none` first; the stale
                    // BSS-zero `unsaved_dialog_target` must stay unreachable).
                    if (!driving_award.unsaved_dialog_is_open()) return error_result(.einval);
                    switch (action) {
                        4 => driving_award.unsaved_dialog_save(),
                        5 => driving_award.unsaved_dialog_dont_save(),
                        else => driving_award.unsaved_dialog_cancel(),
                    }
                },
                else => return error_result(.einval),
            }
            wm_server.note_dialog();
            return 0;
        },
        wm_server.wmctl_request_present => {
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            // M33 SB5 (claim 7397): REQUEST_PRESENT is now the FINAL
            // present — flush only. The kernel's layer (chrome + unmigrated
            // windows) was already painted at the last COMPOSITE_TICK
            // (wm_server.on_tick -> driving_award.paint_scene), and the WM's
            // compose-N stores of the migrated surfaces landed in the
            // scanout between the tick and this call. The old
            // composite-here behavior would paint chrome AFTER the WM's
            // stores and overdraw them (z-order inversion); the tick-side
            // paint keeps the scanout z-order kernel-under-WM at flush time.
            // request_present advances the present sequence + count and runs
            // the G1 transfer+flush (itself gated `!builtin.is_test` — the
            // live gate runs the real flush).
            if (!wm_server.request_present()) return error_result(.einval); // defensive: registrant vanished
            return 0;
        },
        wm_server.wmctl_attach_tab => {
            // S6 Tab model (Milestone 19, issue #782): attach child window (a0) as a tab of parent (a1).
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const child_id = args[1];
            const parent_id = args[2];
            if (child_id > 0xff or parent_id > 0xff or child_id == parent_id) return error_result(.einval);
            if (child_id == wnd_core.chrome_window_all or parent_id == wnd_core.chrome_window_all) return error_result(.einval);
            wm_server.note_tab_attach();
            // M37 DQ2 (issue #840): mirror the validated grouping fact for
            // the strip paint (facts, not policy — the WM still decides).
            driving_award.note_tab_attach(@truncate(child_id), @truncate(parent_id));
            return 0;
        },
        wm_server.wmctl_detach_tab => {
            // S6 Tab model (Milestone 19, issue #782): detach child window (a0) back to standalone.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const child_id = args[1];
            if (child_id > 0xff or child_id == wnd_core.chrome_window_all) return error_result(.einval);
            wm_server.note_tab_detach();
            // M37 DQ2 (issue #840): mirror the detach (see attach above).
            driving_award.note_tab_detach(@truncate(child_id));
            return 0;
        },
        wm_server.wmctl_activate_tab => {
            // S6 Tab model (Milestone 19, issue #782): activate tab (a0).
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const tab_id = args[1];
            if (tab_id > 0xff or tab_id == wnd_core.chrome_window_all) return error_result(.einval);
            wm_server.note_tab_activate();
            return 0;
        },
        wm_server.wmctl_overview => {
            // WM2 mission-control overview (Self-hosting Lane 1, issue #707
            // card 2): the WM's grid-policy decisions. a0 = action
            // (0 enter, 1 exit, 2 focus with a1 = id, 3 move with a1 = id
            // and a2 = workspace); the kernel applies the SAME clamped
            // primitives the shim runs and repaints. Enter returns the card
            // count; focus/move return the id. Zero new syscall slots.
            if (!wm_server.registered()) return error_result(.enosys);
            if (wm_server.registered_pid() != pid) return error_result(.eacces);
            const action = args[1];
            if (action == wm_server.overview_enter_action) {
                const n = driving_award.overview_enter();
                wm_server.note_overview();
                return n;
            } else if (action == wm_server.overview_exit_action) {
                driving_award.overview_exit();
                wm_server.note_overview();
                return 0;
            } else if (action == wm_server.overview_focus_action) {
                const id = args[2];
                if (id > 0xff or id == wnd_core.chrome_window_all) return error_result(.einval);
                if (!driving_award.overview_focus(@truncate(id))) return error_result(.einval);
                wm_server.note_overview();
                return id;
            } else if (action == wm_server.overview_move_action) {
                const id = args[2];
                const ws = args[3];
                if (id > 0xff or id == wnd_core.chrome_window_all) return error_result(.einval);
                if (ws >= driving_award.workspace_max) return error_result(.einval);
                // #990 (claim #997): the WM prints its decision marker
                // unconditionally, so a refused move looked "applied" — name
                // the refusal site honestly on the serial.
                if (!driving_award.overview_move(@truncate(id), @truncate(ws))) {
                    var kbuf: [64]u8 = undefined;
                    const why = driving_award.overview_move_refusal(@truncate(id), @truncate(ws));
                    const s = std.fmt.bufPrint(&kbuf, "overview: move refused id={d} ws={d} why={s}\n", .{ id, ws, why }) catch "overview: move refused\n";
                    klog.line(s);
                    return error_result(.einval);
                }
                wm_server.note_overview();
                return id;
            } else return error_result(.einval);
        },
        else => return error_result(.einval), // unknown / zero cmd
    }
}

/// Deterministic monitor output for implemented (not reservation-stub) rows.
/// M94a preserves the existing bytes; each shard exposes its row by changing
/// its own module's `implemented` constant, without touching this file.
pub fn report(con: *console.Console) void {
    var live: usize = 0;
    for (ensure_table()) |e| {
        if (e.handler != null and e.reportable) live += 1;
    }
    con.puts("syscalls: slots=64 implemented=");
    con.print_u64(live);
    con.puts("\n");
    // Slots are no longer contiguous (58 is live, 56/57 are Lane A
    // reservations), so walk the whole namespace and skip holes.
    var number: u64 = 0;
    while (number < slot_count) : (number += 1) {
        if (!ensure_table()[number].reportable) continue;
        const info = entry_info(number) orelse continue;
        con.puts("  ");
        con.print_u64(info.number);
        con.puts(" ");
        con.puts(info.name);
        con.puts(" calls=");
        con.print_u64(info.calls);
        con.puts("\n");
    }
}
