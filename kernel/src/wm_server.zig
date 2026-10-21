//! VirelaiOS M32 WMS2 render-server register (issue #622) — the kernel half
//! of the ADR 0015 seam-A render-server boundary, implemented BESIDE the
//! unchanged shim (`kernel/src/driving_award.zig`).
//!
//! This module owns the render-server seam's minimal observable state:
//! the single WM registrant (one seat), the present-sequence counter (the
//! parity-cards' observability primitive), and the kind-18 `COMPOSITE_TICK`
//! tick-delivery seam. It deliberately holds NO desktop policy — that stays
//! in the shim until the WM-server drain-out cards (WMS4–WMS6); this card
//! only puts the register the future userland WM will drive in place.
//!
//! Zero-regression contract (the WMS2 binding rule): when no WM is
//! registered nothing changes — the shell idle `drain` keeps compositing
//! exactly as today and every pre-M32 gate stays byte-identical. Only after
//! `REGISTER` does composite pacing move to the tick path (the shell guards
//! its idle `drain` call on `registered()`, one flag check on the hot path).
//!
//! Routing restriction (ADR 0009 D2): kind 18 `COMPOSITE_TICK` is the FIRST
//! routing-restricted kernel event kind — delivered EXCLUSIVELY to the
//! registered WM's process queue via `events.push`, never generated when no
//! WM is registered.
//!
//! No allocation, no libc, no POSIX — pure kernel BSS + the existing
//! `events` / `virtio_gpu` seams (both leaf modules, no import cycle).
//! WM-death teardown mirrors the `close_owner(pid)` window-teardown semantic
//! in the scheduler exit path: on WM process exit the kernel unregisters it
//! and pacing automatically falls back to the shell idle shim.
//!
//! M52 card 2 (#1239) adds the seat's INPUT-CAPTURE discipline to that
//! teardown. The WMS6/WMS8 drains moved the DECISION for the Alt+Tab
//! overlay, the mission-control grid, the tooltip, the notification panel
//! and the two modals into the WM while leaving the kernel holding the
//! applied state — so each is a CAPTURE held on the WM's behalf, and the
//! resumed shim has no path left to dismiss it (the shim decision was
//! drained/deleted). Seat release therefore clears them all, and every
//! routing point refuses a seat whose process descriptor says the process
//! is dead, so no event is ever delivered to a dead pid.

const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");
const process = @import("process.zig"); // the seat's process row: the registry bound (max_processes) + the M52 dead-seat routing gate
const timer = @import("timer.zig"); // M53 card 1 (#1247): the counter clock behind the rate/latency figures
const virtio_gpu = @import("virtio_gpu.zig");
const mmu = @import("mmu.zig");
const driving_award = @import("driving_award.zig"); // M32 WMS4: the renderer owns the chrome state the seam's teardown clears
const scheduler = @import("scheduler.zig"); // M97g (#2079): the spawn provenance behind the seat gate
const settings = @import("settings.zig"); // M97g (#2079): the configured seat program for the launcher class
const gpu3d_broker = @import("gpu3d_broker.zig"); // M102d1 (#2166): the seat's GPU3D contexts die with it

/// Slot-65 subcommand encoding — frozen by WMS1 (claim 1484) in the ADR 0007
/// amendment. Do NOT renumber these; WMS4+ implement `SET_WINDOW` against
/// the same opcode.
pub const wmctl_register: u64 = 1;
pub const wmctl_set_window: u64 = 2;
pub const wmctl_request_present: u64 = 3;
/// M32 WMS5 Gate 2 (claim 4278): SET_STATE — the visibility/workspace
/// channel of the geometry seam. a0 = window id, a1 = visible (bit 0) |
/// workspace (bits 8-11); applied through the same clamped kernel
/// primitives the shim uses (user_set_visible + move-to-workspace).
pub const wmctl_set_state: u64 = 4;
/// M32 WMS6 Gate A (issue #626): ALT_TAB — the desktop-chrome drain's first
/// read-mostly surface. a0 = window id, a1 = action: the WM (not the kernel)
/// decides WHICH window Alt+Tab switches to; the kernel clamps + repaints
/// the overlay blit from WM-declared state. The action encoding is frozen
/// here (ADR 0007 amendment by this claim).
pub const wmctl_alt_tab: u64 = 5;
/// ALT_TAB actions (a1) — mirror the kernel shim's overlay state machine
/// (activate/cycle/commit/dismiss) but driven by the WM's chosen id.
pub const alt_tab_activate: u64 = 1;
pub const alt_tab_cycle: u64 = 2;
pub const alt_tab_commit: u64 = 3;
pub const alt_tab_dismiss: u64 = 4;
/// M32 WMS6 Gate B (issue #626): NOTIF_CENTER — the notification-center
/// surface. a0 = 0 close, 1 open, 2 clear-all. The WM decides the panel's
/// open/close/clear; the kernel clamps + blits from its own `notif_center_open`.
pub const wmctl_notif_center: u64 = 6;
/// NOTIF_DISMISS — a0 = row index; the WM dismisses one notification.
pub const wmctl_notif_dismiss: u64 = 7;
/// M32 WMS6 Gate C (issue #626): TOOLTIP — the read-mostly hover chrome. a0 =
/// 0 hide / 1 show (text via ptr/len, the 32-byte M27 bound). The WM decides
/// WHEN/what; the kernel clamps + blits the box below its own cursor.
pub const wmctl_tooltip: u64 = 8;
/// M32 WMS6 Gate D (issue #626): DOCK — a0 = icon index (0..4). The WM decides
/// which dock icon a click hits (restore/focus/open); the kernel applies the
/// same clamped chain the shim runs.
pub const wmctl_dock: u64 = 9;
/// M32 WMS6 Gate E (issue #626): TRAY — the final chrome gate. The WM owns
/// the tray WIDGET CONTENT: the clock string, theme letter, and clipboard
/// indicator. a0 = flags (bit 0 clock, bit 1 theme, bit 2 clipboard), a1 =
/// the 5-byte "HH:MM" clock text packed little-endian, a2 = theme letter
/// (low byte) | clipboard filled (bit 8). The kernel clamps + stores +
/// repaints; the shim fallback re-derives all three from its own state.
pub const wmctl_tray: u64 = 10;
/// M32 WMS8 Gate 2 (issue #628): DIALOG — the keyboard-driven modal dialogs
/// (M27 G2 about, Ctrl+Shift+A). The WM — not the kernel — decides WHEN to
/// open/close/toggle the about dialog (it owns the kind-21 keyboard stream);
/// the kernel applies the SAME clamped primitives the shim runs
/// (`about_dialog_open_dialog` / `about_dialog_close` / `about_dialog_toggle`)
/// and blits the modal from its own `about_dialog_open` state. a0 = action:
/// 0 close, 1 open, 2 toggle. A WM decision and a shim chord are identical
/// kernel actions (parity by construction).
pub const wmctl_dialog: u64 = 11;
/// WM3 (issue #707 card 3): TASKBAR — a taskbar-entry click decision. The
/// WM — not the kernel — hit-tests the entry rects (the shared wnd_core
/// layout rule) and decides WHICH entry a click landed on; a0 = the
/// entry's window id. The kernel clamps (the id must name a live user
/// window) and applies the SAME chain a shim click would run
/// (restore-if-minimized, else focus + raise) — a WM decision and a click
/// on the same window are identical actions.
pub const wmctl_taskbar: u64 = 12;
/// S6 Tab model (Milestone 19, issue #782): ATTACH_TAB (cmd 18), DETACH_TAB
/// (cmd 19), ACTIVATE_TAB (cmd 20). The WM — not the kernel — owns tab
/// grouping and layout; the kernel tracks the calls and validates IDs.
pub const wmctl_attach_tab: u64 = 18;
pub const wmctl_detach_tab: u64 = 19;
pub const wmctl_activate_tab: u64 = 20;
/// WM2 mission-control overview (Self-hosting Lane 1, issue #707 card 2):
/// OVERVIEW (cmd 21). The WM — not the kernel — decides overview policy
/// from its kind-19/21 input streams (which card was clicked, which
/// workspace a drag targets); the kernel applies the SAME clamped
/// primitives the shim runs (snapshot/enter, focus+raise, move-to-
/// workspace + switch, exit) and blits the grid from its own
/// `overview_open` state. a0 = action: 0 enter, 1 exit, 2 focus (a1 = id),
/// 3 move (a1 = id, a2 = workspace). Zero new syscall slots (slot 65).
pub const wmctl_overview: u64 = 21;
/// M42 UX (2026-09-05, TABWM tab-close seam): WIN_CLOSE — a0 = window id.
/// The registered WM closes a live user window through the kernel's OWN
/// release primitive (`driving_award.user_close`) — the same path a shim
/// close or `dui close <n>` runs — so the owner receives the kernel's
/// real `WIN_CLOSE` event (the remove_user_at push) and the WM receives
/// the released kind-20 mirror (flags bit 13). An EL0 process cannot
/// write another process's event queue and the IPC mailbox is a separate
/// FIFO no tabapp drains — this syscall is the seam that makes
/// "click the tab 'x' -> the app actually exits" true end to end.
pub const wmctl_win_close: u64 = 13;
/// #1056 item 2: the WM queries a window's display name (the app-set title
/// or the owner process's executable name). a0 = cmd, a1 = window id,
/// a2 = destination buffer, a3 = buffer length. The kernel copies the name
/// OUT and returns its byte count, so a WM whose kind-20 mirror cannot
/// carry title bytes can still name non-tabapp windows. Seat-gated
/// (registered WM only), like every other WMCTL command.
pub const wmctl_window_name: u64 = 14;
/// #1688: CONTENT pointer forward (ADR 0015 additive — changelog entry
/// 2026-09-23; numbering note there: the never-merged tray-clock 15 was
/// dropped for `sys_time`, leaving 15 free until this card takes it).
/// The registered seat relays pointer samples into the kernel's LOCAL
/// content path — terminal text selection and mouse-tracking reports —
/// which WMS5 made dormant under a seat by returning from `pointer_tick`
/// before every selection site. Chrome (start surface, rail, launcher)
/// is consumed seat-side and never forwarded. a0 = x|(y<<16), a1 =
/// button mask (bit0 left, bit1 right); press/release edges derive from
/// the seat-serialized sample stream itself. Seat-gated like every other
/// subcommand; no existing opcode or arg layout changes.
pub const wmctl_content_ptr: u64 = 15;
/// #2079 (M97g seat gate): SEAT_PID (cmd 16) — the pid-discovery query.
/// Returns the kernel-registered WM pid (ENOENT when no seat is held) so
/// WM_RPC clients bind to the kernel's own record instead of resolving a
/// forgeable process name through `sys_procs`. Unprivileged and
/// read-only: the seat pid was always observable; the fix is that the
/// answer can no longer be impersonated.
pub const wmctl_seat_pid: u64 = 16;
/// M102d1 (issue #2166): GPU3D (cmd 22) — the bounded experimental 3D
/// bridge on the existing seat-exclusive slot. a0..a2 are reserved-zero;
/// ptr/len carry exactly one frozen 64-byte typed descriptor (op /
/// generation-bearing handle / window id / bounded geometry + vertices /
/// reserved-zero — ADR 0007). The seat relays an authenticated app's
/// bounded ops; apps never call it directly. The kernel side verifies
/// seat, window, owner, bounds and context generation on EVERY operation
/// and revokes contexts on window close, owner exit and unregister —
/// gpu3d_broker.zig owns the state machine, this file only names the op
/// and counts accepted submissions.
pub const wmctl_gpu3d: u64 = 22;
/// OVERVIEW actions (a0).
pub const overview_enter_action: u64 = 0;
pub const overview_exit_action: u64 = 1;
pub const overview_focus_action: u64 = 2;
pub const overview_move_action: u64 = 3;

/// The single registered WM server process id; null = no WM registered
/// (shim mode, the default — every pre-M32 gate runs in this state).
var wm_pid: ?usize = null;
/// Monotonic present sequence (arg0 of every COMPOSITE_TICK), wraps at 2³².
/// Advanced only by REQUEST_PRESENT — a stalled WM shows a frozen sequence,
/// so parity gates can detect that it stopped presenting.
var present_seq: u32 = 0;
/// Total REQUEST_PRESENT calls accepted (the observable present counter).
var present_count: u64 = 0;
/// Total COMPOSITE_TICK events delivered to the registered WM.
var tick_count: u64 = 0;

// --- M53 card 1 (#1247): frame observability ---------------------------------
//
// Two questions no gate could answer before this: **how often does the desktop
// actually present**, and **how long does an input sample wait to reach the
// screen**. The kind-18 COMPOSITE_TICK is 1 Hz (timer.zig `period_ns`), but in
// WM mode the present is the WM's own decision (`pointer_tick` returns early
// once a seat is registered, and REQUEST_PRESENT is what transfers+flushes), so
// 1 Hz is the heartbeat, not necessarily the cadence. These counters measure
// rather than assume.
//
// The latency is deliberately split into its two halves, because they have
// different owners and different fixes:
//   * input sample -> REQUEST_PRESENT  = how long the WM's loop took to answer
//     (the WM's responsiveness; a WM that only presents on the tick shows ~1 s)
//   * REQUEST_PRESENT -> flushed       = the kernel + GPU cost of a present
// A single end-to-end number would hide which half is slow.

/// Injectable ns clock. Host tests drive it (they cannot read CNTPCT_EL0:
/// `timer.cntpct` returns 0 under `builtin.is_test`), which is the same reason
/// the hook exists — the math is testable only against a clock we choose.
/// The kernel path reads the counter and converts with CNTFRQ_EL0, in u128 so
/// no uptime can overflow the multiply.
pub var now_ns_hook: ?*const fn () u64 = null;

fn now_ns() u64 {
    if (now_ns_hook) |h| return h();
    const f = timer.freq;
    if (f == 0) return 0;
    return @intCast(@as(u128, timer.cntpct()) * 1_000_000_000 / f);
}

/// The rate window's edges (ns): first/last present, first/last tick.
var first_present_ns: u64 = 0;
var last_present_ns: u64 = 0;
var first_tick_ns: u64 = 0;
var last_tick_ns: u64 = 0;
/// Arrival of the OLDEST input sample not yet answered by a present; 0 = none
/// outstanding. Only the oldest is kept: it is the sample whose visible delay
/// is the longest, which is the number that matters.
var input_stamp_ns: u64 = 0;
/// input sample -> present. `sum`/`max` in ns; `count` is the sample count.
var lat_count: u64 = 0;
var lat_sum_ns: u64 = 0;
var lat_max_ns: u64 = 0;
/// present -> transfer+flush complete (the kernel/GPU half).
var flush_count: u64 = 0;
var flush_sum_ns: u64 = 0;
var flush_max_ns: u64 = 0;

/// Timestamp an input sample if none is outstanding (see `input_stamp_ns`).
/// Gated on `present_count > 0` so shim-mode fan-out (no presenter yet) does
/// not manufacture a latency sample for a present that never answers it.
fn note_input() void {
    if (input_stamp_ns == 0 and present_count > 0) input_stamp_ns = now_ns();
}

fn record_latency(ns: u64) void {
    lat_count +%= 1;
    lat_sum_ns +%= ns;
    if (ns > lat_max_ns) lat_max_ns = ns;
}

fn record_flush(ns: u64) void {
    flush_count +%= 1;
    flush_sum_ns +%= ns;
    if (ns > flush_max_ns) flush_max_ns = ns;
}

/// The cadence is reported as an AVERAGE INTERVAL in ms, not as a
/// presents-per-second integer: the live run measured 15 presents over ~31 s,
/// and `15/31` truncates to 0 pps — a row that reads `present_pps=0` beside
/// `presents=15` is worse than useless, it is a lie by rounding. An interval
/// is lossless at this granularity and is the thing both questions actually
/// need (present interval vs tick interval; a rate is 1000/interval).
/// 0 means "no positive window yet" — never an invented figure.
pub fn present_window_ms() u64 {
    if (present_count < 2 or last_present_ns <= first_present_ns) return 0;
    return (last_present_ns - first_present_ns) / 1_000_000;
}

pub fn present_avg_ms() u64 {
    if (present_count < 2 or last_present_ns <= first_present_ns) return 0;
    return (last_present_ns - first_present_ns) / (present_count - 1) / 1_000_000;
}

/// The tick interval by the same arithmetic — printed beside the present
/// interval so the row states the heartbeat it is being compared against,
/// rather than leaving 1 Hz as folklore. Note it needs a span of MANY ticks to
/// read as 1000 ms: a 30-tick span that drifted 2% short truncates a pps form
/// to 0, which is exactly how this field was caught being wrong.
pub fn tick_avg_ms() u64 {
    if (tick_count < 2 or last_tick_ns <= first_tick_ns) return 0;
    return (last_tick_ns - first_tick_ns) / (tick_count - 1) / 1_000_000;
}
/// M32 WMS4 (issue #624): total SET_WINDOW chrome-descriptor submissions
/// accepted (the `wm` observability counter — submissions counted). The
/// descriptors themselves live in `driving_award` (per-window + policy);
/// this seam only counts, per its no-policy charter.
var set_window_count: u64 = 0;
/// M32 WMS6 Gate A (issue #626): total ALT_TAB submissions accepted (the
/// observability counter — how many desktop-chrome decisions the WM made).
var alt_tab_apply_count: u64 = 0;
/// M32 WMS6 Gate B (issue #626): NOTIF_CENTER / NOTIF_DISMISS submissions
/// accepted — the notification-center decisions the WM made.
var notif_center_count: u64 = 0;
var notif_dismiss_count: u64 = 0;
/// M32 WMS6 Gate C (issue #626): TOOLTIP submissions accepted (show/hide).
var tooltip_count: u64 = 0;
/// M32 WMS6 Gate D (issue #626): DOCK submissions accepted (icon clicks).
var dock_count: u64 = 0;
/// M32 WMS6 Gate E (issue #626): TRAY submissions accepted — the WM's tray
/// widget-content decisions (clock/theme/clipboard) applied.
var tray_count: u64 = 0;
/// M32 WMS8 Gate 2 (issue #628): DIALOG (cmd 11) submissions accepted — the
/// WM's keyboard-driven modal-dialog decisions (about open/close/toggle)
/// applied by the kernel.
var dialog_count: u64 = 0;
/// WM3 (issue #707 card 3): TASKBAR (cmd 12) submissions accepted — the
/// taskbar-entry click decisions the WM made (restore/focus), applied.
var taskbar_count: u64 = 0;
/// M42 UX (2026-09-05): WIN_CLOSE (cmd 13) closes applied by the kernel.
var win_close_count: u64 = 0;
/// S6 Tab model (Milestone 19, issue #782): counters for tab operations.
var tab_attach_count: u64 = 0;
var tab_detach_count: u64 = 0;
var tab_activate_count: u64 = 0;
/// WM2 mission-control overview (issue #707 card 2): OVERVIEW (cmd 21)
/// submissions accepted — the WM's grid-policy decisions applied.
var overview_count: u64 = 0;
/// M102d1 (issue #2166): GPU3D (cmd 22) submissions accepted — the
/// bounded render decisions the seat relayed. Refusals never count.
var gpu3d_count: u64 = 0;
/// Set when the registered WM exits (teardown) — the shell idle loop drains
/// this into the `wm: unregistered, shim resumed` report (the exit path is
/// IRQ context and console-free, so the report is drained like the process
/// exit reports, not printed inline).
var fallback_pending: bool = false;
/// M33 SB5 (claim 7397): the SCANOUT grant — the registered WM's WRITABLE
/// view of the virtio-gpu framebuffer (the compose-N target). One seat
/// (the WM seat), kernel-owned pages: the GPU fb is never alloc'd to the
/// WM, so these pages are NEVER ref'd/unref'd — teardown unmaps the leaves
/// without touching the refcount. `wm_owns_user_layer` (driving_award)
/// mirrors this: set on bind, cleared on teardown.
var scanout_pid: u64 = 0;
var scanout_va: u64 = 0;
var scanout_pages: u32 = 0;

/// M52 card 2 (#1239): the captures a registered WM leaves to the kernel.
///
/// Each of these is applied by the kernel but DECIDED by the WM — the WM's
/// slot-65 command is the only producer (the shim's own path for it was
/// drained in WMS6 or deleted in WMS8), which makes each one a modality the
/// kernel is holding on the WM's behalf. A dead WM must not strand one: the
/// resumed shim cannot dismiss what it no longer decides, so an Alt+Tab
/// snapshot, a grid, a tooltip box, a panel or a modal would stay up (and
/// stay PAINTED) for the rest of the boot. Seat release is the one moment
/// that knows the WM is gone, so the release lives here.
fn release_wm_captures() void {
    // Alt+Tab overlay snapshot (cmd 5 ALT_TAB activate/cycle).
    driving_award.alt_tab_dismiss();
    // Mission-control grid (cmd 21 OVERVIEW enter).
    driving_award.overview_exit();
    // Tooltip box (cmd 8 TOOLTIP show).
    driving_award.tooltip_clear();
    // Notification-center panel (cmd 6 NOTIF_CENTER open).
    driving_award.notif_center_set_open(false);
    // About modal (cmd 11 DIALOG open/toggle) — closes and restores the
    // focus it saved, so the modal cannot strand the pre-modal focus either.
    driving_award.about_dialog_close();
    // Unsaved-changes modal (cmd 11 DIALOG actions 3-6): DISMISS it. The
    // WM's pending choice dies with the WM — the kernel never auto-applies
    // a dead compositor's save/discard decision to a live client window.
    driving_award.unsaved_dialog_cancel();
}

/// Reset the seam (kernel boot + host-test setups).
pub fn init() void {
    wm_pid = null;
    present_seq = 0;
    present_count = 0;
    tick_count = 0;
    // M53 card 1 (#1247): a reset is a fresh window — every rate/latency
    // accumulator starts empty (the hook itself is the test's to own).
    first_present_ns = 0;
    last_present_ns = 0;
    first_tick_ns = 0;
    last_tick_ns = 0;
    input_stamp_ns = 0;
    lat_count = 0;
    lat_sum_ns = 0;
    lat_max_ns = 0;
    flush_count = 0;
    flush_sum_ns = 0;
    flush_max_ns = 0;
    set_window_count = 0;
    set_state_count = 0;
    alt_tab_apply_count = 0;
    notif_center_count = 0;
    notif_dismiss_count = 0;
    tooltip_count = 0;
    dock_count = 0;
    tray_count = 0;
    dialog_count = 0;
    tab_attach_count = 0;
    tab_detach_count = 0;
    tab_activate_count = 0;
    overview_count = 0;
    gpu3d_count = 0;
    // M102d1 (#2166): a seam reset strands no GPU3D context (records bind
    // to windows/seat — pure BSS wipe, no device I/O).
    gpu3d_broker.reset_state();
    pointer_fan_count = 0;
    window_mirror_count = 0;
    key_fan_count = 0;
    fallback_pending = false;
    // M33 SB5: a reset unbinds the scanout grant (unmap leaves without
    // unref — kernel pages) and the user-layer ownership goes back to the
    // kernel shim.
    scanout_teardown();
    // M32 WMS5: a reset is a teardown — input ownership returns to the
    // shim and the fan-out hooks are detached (a stale `wm_owns_input=true`
    // stranded by a mid-test re-init would silently gate the kernel's
    // geometry off in later aggregated tests). init() is the one place
    // every setup path converges, so the reset is complete here.
    driving_award.wm_owns_input = false;
    driving_award.wm_pointer_hook = null;
    driving_award.wm_window_hook = null;
    // M32 WMS5 Gate 2 (claim 4278): the keyboard fan-out hook detaches too.
    driving_award.wm_key_hook = null;
    // M52 card 2 (#1239): a reset is a seat release — no WM-owned capture
    // may leak into the next boot/test (the same reasoning as the hooks).
    release_wm_captures();
}

/// True when a WM is registered (composite pacing has moved to the tick path).
pub fn registered() bool {
    return wm_pid != null;
}

/// The registered WM's process id, if any.
pub fn registered_pid() ?usize {
    return wm_pid;
}

/// #2079 (M97g seat gate): may `pid` claim the WM seat? REGISTER arms the
/// raw key/pointer fan-out and the writable scanout bind, so eligibility is
/// bound to kernel-recorded spawn provenance, never to a caller-chosen
/// name:
///   * `cap_proc_admin` holders (the operator's `exec -u0` channel);
///   * kernel-spawned tasks — `spawned_by == null` (boot autostart and
///     monitor `exec` are the desktop/test-seat launchers);
///   * launcher children — a direct `sys_exec` child of a kernel-spawned
///     process (INIT's service spawn) — ONLY when the image name is the
///     configured seat program (`wm` setting). The name check narrows the
///     launcher class; it is never the sole credential, so an arbitrary
///     EL0 process exec'ing a file it named `GOTABWM.ELF` still fails —
///     its task is not launcher-spawned.
/// Everything else (any process an EL0 app can spawn) is refused. `task_id`
/// is the caller's task slot; a stale/freed provenance fails closed.
pub fn seat_authorized(pid: usize, task_id: usize) bool {
    const principal = process.principal(pid) orelse return false;
    if (principal.has(process.cap_proc_admin)) return true;
    const prov = scheduler.spawn_provenance(task_id);
    if (!prov.valid) return false;
    if (prov.parent == null) return true;
    if (!prov.launcher) return false;
    const seat_prog = settings.wm_seat_kind().program() orelse return false;
    const pinfo = process.info(pid) orelse return false;
    return std.ascii.eqlIgnoreCase(pinfo.name, seat_prog);
}

/// Accept the registering process as the active compositor. One seat: a
/// second registration while a WM is already registered is refused (the
/// handler maps that to `EACCES` — seat taken). The gpu/unarmed check is
/// the handler's (it needs the module-level error result); this is the pure
/// state transition. Returns true on success.
pub fn register(pid: usize) bool {
    if (wm_pid != null) return false;
    wm_pid = pid;
    fallback_pending = false;
    // M32 WMS5: the WM now owns input — the kernel stops consuming pointer
    // geometry (the flag gate in driving_award.pointer_tick). The cursor
    // stays a kernel blit; only the geometry DECISIONS move out. The raw
    // pointer + registry mirrors fan out through these hooks (set at
    // register, nulled at unregister — null hook = no WM = no-op).
    driving_award.wm_owns_input = true;
    driving_award.wm_pointer_hook = fan_pointer;
    driving_award.wm_window_hook = fan_window;
    // M32 WMS5 Gate 2 (claim 4278): the keyboard half of the input seam —
    // the raw key stream fans out to the WM (the shell idle's keyboard
    // geometry consumers are gated off behind `wm_owns_input`).
    driving_award.wm_key_hook = fan_key;
    return true;
}

/// M33 SB5 (claim 7397): grant the registered WM a WRITABLE view of the
/// virtio-gpu framebuffer (the compose-N target). WM seat only; full-frame
/// (the whole fb); idempotent (a re-bind by the same WM returns the same
/// va). The GPU fb pages are kernel-owned — they are mapped WITHOUT ref and
/// torn down WITHOUT unref. Returns the WM's va, or 0 on refusal
/// (not-the-WM / already granted elsewhere / no framebuffer / map failure).
pub fn scanout_bind(pid: usize, pinfo: process.ProcessInfo) u64 {
    if (wm_pid == null or wm_pid.? != pid) return 0; // the WM seat is the privilege
    if (scanout_va != 0) {
        // Idempotent keep: the same WM re-binding its scanout is a no-op
        // (mirrors the D2 creator-retains-its-surface rule).
        return if (scanout_pid == @as(u64, pid)) scanout_va else 0;
    }
    const len = virtio_gpu.fb_size;
    const pages: u32 = @intCast(len / 4096);
    const pa_base = virtio_gpu.gpu_fb_phys;
    if (pa_base == 0 or pages == 0) return 0; // no framebuffer (unarmed)
    const va = process.next_mmap_va(pid, len);
    if (!process.add_mmap_region(pid, va, len, 3, 0x20)) return 0; // prot RW + MAP_ANON
    var i: u32 = 0;
    while (i < pages) : (i += 1) {
        const pa = pa_base + @as(u64, i) * 4096;
        if (!mmu.map_user_page(pinfo.root_phys, va + @as(u64, i) * 4096, pa, true, false)) { // writable, NOT executable
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                _ = mmu.unmap_user_page(pinfo.root_phys, va + @as(u64, j) * 4096);
            }
            _ = process.remove_mmap_region(pid, va, len);
            return 0;
        }
    }
    scanout_pid = @as(u64, pid);
    scanout_va = va;
    scanout_pages = pages;
    // The WM now owns the migrated user layer: paint_scene skips
    // surface-backed windows (their bytes land here via compose-N).
    driving_award.wm_owns_user_layer = true;
    driving_award.splash_hold = false;
    driving_award.presentation_trace_arm();
    return va;
}

/// True when the scanout is currently granted to `pid` (the WM seat).
pub fn scanout_bound(pid: usize) bool {
    return scanout_pid == @as(u64, pid) and scanout_va != 0;
}

/// The granted scanout va, if any (for the munmap special-case + tests).
pub fn scanout_va_get() ?u64 {
    return if (scanout_va != 0) scanout_va else null;
}

/// Tear the scanout grant down: unmap the WM's leaves WITHOUT unref (the GPU
/// fb pages are kernel-owned and never ref-counted to the WM), drop the mmap
/// region, clear the seat, and give the user layer back to the kernel shim.
/// Called from WM unregister/exit, a full-frame munmap, and init().
pub fn scanout_teardown() void {
    if (scanout_va == 0) return;
    driving_award.cursor_restore();
    const pid: usize = @intCast(scanout_pid);
    if (process.info(pid)) |pinfo| {
        var i: u32 = 0;
        while (i < scanout_pages) : (i += 1) {
            _ = mmu.unmap_user_page(pinfo.root_phys, scanout_va + @as(u64, i) * 4096);
        }
    }
    _ = process.remove_mmap_region(pid, scanout_va, @as(u64, scanout_pages) * 4096);
    scanout_pid = 0;
    scanout_va = 0;
    scanout_pages = 0;
    driving_award.wm_owns_user_layer = false;
    // Tick-side rendering consumed fixed-layer damage while the seat owned
    // scanout. Recovery must repaint that layer, not retain the dead seat.
    for (driving_award.windows[0..driving_award.win_count]) |*w| w.dirty = true;
}

/// WM-death teardown: unregister `pid`. Returns true only when `pid` WAS the
/// registrant (mirrors the `close_owner(caller)` window-teardown contract in
/// the scheduler exit path, which calls this per exiting process) — a false
/// return is a no-op for unrelated exits.
pub fn unregister(pid: usize) bool {
    if (wm_pid != pid) return false;
    wm_pid = null;
    fallback_pending = true;
    // M33 SB5: the WM's scanout grant dies with it — unmap the leaves (no
    // unref; kernel pages) and give the user layer back to the shim.
    scanout_teardown();
    // M102d1 (#2166): the seat's GPU3D contexts die with it — handles are
    // invalidated before the bounded drain, so nothing can ever publish
    // for a dead compositor; a device that cannot drain leaves each
    // session quarantined (backing pinned for late DMA).
    gpu3d_broker.revoke_all();
    // M32 WMS4: the WM's chrome decisions die with it — the shim fallback
    // must restore its own chrome rules (a dead WM's look must not stay
    // painted). driving_award imports only wnd_core, so this import is
    // cycle-free (the seam delegates render-state teardown to the renderer).
    driving_award.clear_wm_chrome();
    // M52 card 2 (#1239): the WM's INPUT CAPTURES die with it too. The
    // chrome above is the dead WM's LOOK; these are its MODALITY — see
    // release_wm_captures for why the resumed shim cannot drop them itself.
    release_wm_captures();
    // M32 WMS5: the WM's input ownership dies with it — the kernel resumes
    // consuming pointer geometry (shim fallback, byte-identical to pre-WMS5).
    driving_award.wm_owns_input = false;
    driving_award.wm_pointer_hook = null;
    driving_award.wm_window_hook = null;
    driving_award.wm_key_hook = null;
    return true;
}

/// Consolidate (drain-as-report): true ONCE after a teardown fallback, then
/// false until the next unregister. Called by the shell idle loop to print
/// `wm: unregistered, shim resumed` — the exit path itself (IRQ context,
/// claim 9187) cannot print; this is the report-drain pattern shared with
/// the process exit reports.
pub fn take_fallback_report() bool {
    if (!fallback_pending) return false;
    fallback_pending = false;
    return true;
}

/// Scheduler tick seam (the SAME host-testable tick seam `app_timers.on_tick`
/// fires from — WMS1 frozen decision 3): while a WM is registered, deliver
/// ONE `COMPOSITE_TICK` (kind 18) into the registrant's process event queue,
/// arg0 = present sequence, arg1 = reserved (0). Routing restritriction:
/// this is delivered ONLY to `wm_pid`. A no-op when no WM is registered
/// (nothing changes in shim mode). `events.push` wakes a blocked
/// `sys_wait_event` caller via the `on_event_pushed` hook.
/// M52 card 2 (#1239): true when the seat's process descriptor says the
/// process is DEAD. `.exited` is the state that outlives the process (the
/// descriptor stays for the `procs` exit record), so it is the one a seat
/// can be left pointing at. A MISSING descriptor is NOT dead: the host-test
/// register contract binds bare pids with no process row at all, and a
/// reaped slot's descriptor is gone entirely — treating absence as death
/// would make the gate reject the tests' own seats. The gate only refuses
/// to ROUTE to a dead seat; releasing it stays `unregister`'s job (the
/// scheduler exit seam calls it for every exiting process).
pub fn seat_dead(pid: usize) bool {
    const p = process.info(pid) orelse return false;
    return p.state == .exited;
}

pub fn on_tick() void {
    const pid = wm_pid orelse return;
    if (seat_dead(pid)) return; // M52 card 2: never route a tick to a dead pid
    tick_count +%= 1;
    // M53 card 1 (#1247): the tick rate's window (printed beside the present
    // rate so the comparison is stated, not assumed).
    const t = now_ns();
    if (first_tick_ns == 0) first_tick_ns = t;
    last_tick_ns = t;
    // M33 SB5 (claim 7397): the kernel paints its layer (chrome + unmigrated
    // windows) at TICK time, BEFORE the WM's compose-N stores land — so at
    // flush time the scanout z-order is kernel-layer UNDER the WM's user
    // surfaces. The damage mask is captured BEFORE the paint consumes it, so
    // the WM's compose hint still reflects what changed this tick.
    const damage_mask = driving_award.user_damage_mask();
    _ = driving_award.paint_scene();
    events.push(pid, .{
        .kind = events.COMPOSITE_TICK,
        .flags = 0,
        .seq = 0,
        .arg0 = present_seq,
        // M33 SB4 (claim 2382): arg1 is the COMPOSITE_TICK damage payload — a
        // per-surface dirty bitmask (bit i <=> user surface i +
        // user_window_id_base) telling the registered WM WHICH surfaces have
        // pending rect damage this tick (the rects come via
        // `driving_award.user_damage(id)`). SB5's compose-N repaints only
        // those. 0 when the scene is clean.
        .arg1 = damage_mask,
    });
}

/// REQUEST_PRESENT (cmd 3): transfer+flush the scanout now through the G1
/// seam and advance the present-sequence counter (the parity-cards'
/// observability primitive) + the present count. Returns false when no WM is
/// registered (the handler refuses the caller EACCES BEFORE this). The
/// Sequence/count/rate advance only after a successful transfer AND flush.
/// Host tests inject transport results without executing device maintenance.
pub fn request_present() bool {
    const pid = wm_pid orelse return false;
    if (seat_dead(pid)) return false;
    // The G1 transfer+flush is real-hardware work: exec_cmd runs `dc ivac`
    // cache-maintenance asm, which is illegal at EL0 in host test binaries
    // (and other tests in an aggregated binary may have armed the transport).
    // present_completed injects transport results in host tests; the live
    // gate runs the real transfer+flush on the kernel image.
    //
    // M53 card 1 (#1247): the present is timed on both edges. `t0..t1` is the
    // kernel+GPU half of the latency (on a host test the work is skipped, so
    // that figure is the clock's resolution, not a GPU cost — the live gate is
    // the one that measures hardware).
    const t0 = now_ns();
    driving_award.cursor_draw();
    const result = driving_award.present_completed("seat");
    // The GPU resource has the completed frame; the compose target must not
    // retain the cursor for the next seat paint/upload.
    driving_award.cursor_restore();
    if (result != .ok) return false;
    driving_award.cursor_damage_clear();
    present_seq +%= 1;
    present_count +%= 1;
    const t1 = now_ns();
    record_flush(t1 -% t0);
    // The present is the right edge of the rate window, and it ANSWERS the
    // oldest outstanding input sample — that wait is the WM's half.
    if (first_present_ns == 0) first_present_ns = t1;
    last_present_ns = t1;
    if (input_stamp_ns != 0) {
        record_latency(t1 -% input_stamp_ns);
        input_stamp_ns = 0;
    }
    return true;
}

/// Read-only snapshot for the monitor `wm` report row.
pub const WmInfo = struct {
    pid: ?usize,
    present_seq: u32,
    present_count: u64,
    tick_count: u64,
    set_window_count: u64,
    set_state_count: u64,
    alt_tab_apply_count: u64,
    notif_center_count: u64,
    notif_dismiss_count: u64,
    tooltip_count: u64,
    dock_count: u64,
    tray_count: u64,
    dialog_count: u64,
    taskbar_count: u64,
    win_close_count: u64,
    overview_count: u64,
    /// M102d1 (#2166): accepted GPU3D (cmd 22) submissions.
    gpu3d_count: u64,
    pointer_fan_count: u64,
    window_mirror_count: u64,
    key_fan_count: u64,
    // M53 card 1 (#1247): measured cadence + latency. Cadence is an average
    // INTERVAL in ms (see `present_avg_ms` — a pps integer truncates sub-1
    // rates to 0). `window_ms` is 0 until a positive window exists;
    // `lat_avg_ns`/`flush_avg_ns` are 0 with no samples (never a fabricated
    // 0-sample average).
    present_window_ms: u64,
    present_avg_ms: u64,
    tick_avg_ms: u64,
    lat_count: u64,
    lat_avg_ns: u64,
    lat_max_ns: u64,
    flush_count: u64,
    flush_avg_ns: u64,
    flush_max_ns: u64,
};

pub fn info() WmInfo {
    return .{
        .pid = wm_pid,
        .present_seq = present_seq,
        .present_count = present_count,
        .tick_count = tick_count,
        .set_window_count = set_window_count,
        .set_state_count = set_state_count,
        .alt_tab_apply_count = alt_tab_apply_count,
        .notif_center_count = notif_center_count,
        .notif_dismiss_count = notif_dismiss_count,
        .tooltip_count = tooltip_count,
        .dock_count = dock_count,
        .tray_count = tray_count,
        .dialog_count = dialog_count,
        .taskbar_count = taskbar_count,
        .win_close_count = win_close_count,
        .overview_count = overview_count,
        .gpu3d_count = gpu3d_count,
        .pointer_fan_count = pointer_fan_count,
        .window_mirror_count = window_mirror_count,
        .key_fan_count = key_fan_count,
        .present_window_ms = present_window_ms(),
        .present_avg_ms = present_avg_ms(),
        .tick_avg_ms = tick_avg_ms(),
        .lat_count = lat_count,
        .lat_avg_ns = if (lat_count == 0) 0 else lat_sum_ns / lat_count,
        .lat_max_ns = lat_max_ns,
        .flush_count = flush_count,
        .flush_avg_ns = if (flush_count == 0) 0 else flush_sum_ns / flush_count,
        .flush_max_ns = flush_max_ns,
    };
}

/// M32 WMS4: count one accepted SET_WINDOW submission (the syscall layer
/// calls this AFTER the descriptor was validated and stored).
pub fn note_set_window() void {
    set_window_count +%= 1;
}

/// M102d1 (#2166): count one accepted GPU3D submission — called by the
/// syscall layer AFTER the broker accepted the descriptor. Refusals are
/// never counted.
pub fn note_gpu3d() void {
    gpu3d_count +%= 1;
}

// ---------------------------------------------------------------------------
// M32 WMS5 (issue #625): the INPUT SEAM — the registered WM receives the raw
// pointer stream (kind 19 WM_POINTER) and the window-registry mirrors (kind
// 20 WM_WINDOW); the kernel stops consuming pointer geometry while a WM is
// registered (cursor stays a kernel blit surface). Routing restriction = the
// kind-18 discipline: every fan-out is a no-op when no WM is registered.
// ---------------------------------------------------------------------------

/// Total WM_POINTER raw-stream events fanned out to the registered WM.
var pointer_fan_count: u64 = 0;
/// Total WM_WINDOW registry-mirror events fanned out to the registered WM.
var window_mirror_count: u64 = 0;
/// Total WM_KEY raw-keyboard events fanned out to the registered WM (WMS5
/// Gate 2, claim 4278 — the keyboard half of the input seam).
var key_fan_count: u64 = 0;
/// Total SET_STATE (cmd 4) calls applied by the registered WM (visibility /
/// workspace changes — the geometry seam's state channel, claim 4278).
var set_state_count: u64 = 0;

/// Fan ONE raw absolute-pointer sample to the registered WM (the input
/// handover): kind 19, `arg0` = x|(y<<16) in fb pixels, `flags` low byte =
/// the raw HID button byte, `arg1` = the keyboard modifier byte live at
/// the sample's decode (#2896 — the capture-time snapshot the seat echoes
/// back through slot-65 cmd 15, so a queued sample is judged on what was
/// held when it was captured, not on drain-time kb_mods). No-op when no
/// WM is registered (shim mode — the kernel's own pointer_tick keeps
/// consuming geometry exactly as before; zero regression). Caller maps
/// HID logicals to pixels first.
pub fn fan_pointer(x: u32, y: u32, buttons: u8, mods: u8) void {
    const pid = wm_pid orelse return;
    if (seat_dead(pid)) return; // M52 card 2: never route to a dead pid
    note_input(); // M53 card 1 (#1247): the left edge of the latency sample
    pointer_fan_count +%= 1;
    events.push(pid, .{
        .kind = events.WM_POINTER,
        .flags = buttons,
        .seq = 0,
        .arg0 = x | (y << 16),
        .arg1 = mods,
    });
}

/// Fan ONE window-registry mirror to the registered WM (so it can
/// hit-test): kind 20, `flags` = id | visible<<8 | focused<<9 |
/// workspace<<10 | unsaved<<12 | released<<13, `arg0` = x|(y<<16),
/// `arg1` = w|(h<<16). `released` (M42 UX, 2026-09-05, additive bit 13)
/// marks the RELEASE mirror fanned from `driving_award.remove_user_at` —
/// the window left the registry (app self-exit / close_owner / user_close),
/// as opposed to a plain state mirror. No-op when no WM is registered.
pub fn fan_window(id: u8, x: u32, y: u32, w: u32, h: u32, visible: bool, focused: bool, workspace: u8, unsaved: bool, released: bool) void {
    const pid = wm_pid orelse return;
    if (seat_dead(pid)) return; // M52 card 2: never route to a dead pid
    window_mirror_count +%= 1;
    var flags: u16 = id;
    if (visible) flags |= 1 << 8;
    if (focused) flags |= 1 << 9;
    flags |= @as(u16, workspace & 0x3) << 10;
    if (unsaved) flags |= 1 << 12;
    if (released) flags |= 1 << 13;
    events.push(pid, .{
        .kind = events.WM_WINDOW,
        .flags = flags,
        .seq = 0,
        .arg0 = x | (y << 16),
        .arg1 = w | (h << 16),
    });
}

/// Fan ONE raw keyboard sample to the registered WM (the input handover's
/// keyboard half): kind 21, `arg0` = the raw HID keyboard usage byte,
/// `flags` = ADR 0009 modifier bits. No-op when no WM is registered (shim
/// mode — the kernel's own keyboard geometry consumers keep working exactly
/// as before; zero regression). Caller edge-detects (key-DOWN only).
pub fn fan_key(usage: u8, flags: u16) void {
    const pid = wm_pid orelse return;
    if (seat_dead(pid)) return; // M52 card 2: never route to a dead pid
    note_input(); // M53 card 1 (#1247): the left edge of the latency sample
    key_fan_count +%= 1;
    events.push(pid, .{
        .kind = events.WM_KEY,
        .flags = flags,
        .seq = 0,
        .arg0 = usage,
        .arg1 = 0,
    });
}

/// Note a SET_STATE (cmd 4) call — the WM's visibility/workspace change.
pub fn note_set_state() void {
    set_state_count +%= 1;
}

/// Note an ALT_TAB (cmd 5) submission — a desktop-chrome decision the WM
/// made (activate/cycle/commit/dismiss).
pub fn note_alt_tab() void {
    alt_tab_apply_count +%= 1;
}

/// Note a NOTIF_CENTER (cmd 6) submission — the WM's open/close/clear call.
pub fn note_notif_center() void {
    notif_center_count +%= 1;
}

/// Note a NOTIF_DISMISS (cmd 7) submission — the WM dismissing a row.
pub fn note_notif_dismiss() void {
    notif_dismiss_count +%= 1;
}

/// Note a TOOLTIP (cmd 8) submission — the WM's show/hide decision.
pub fn note_tooltip() void {
    tooltip_count +%= 1;
}

/// Note a DOCK (cmd 9) submission — the WM's dock-icon click decision.
pub fn note_dock() void {
    dock_count +%= 1;
}

/// Note a TRAY (cmd 10) submission — the WM's tray widget-content decision.
pub fn note_tray() void {
    tray_count +%= 1;
}

/// Note a DIALOG (cmd 11) submission — the WM's modal-dialog decision.
pub fn note_dialog() void {
    dialog_count +%= 1;
}

/// WM3 (issue #707 card 3): note a TASKBAR (cmd 12) submission — the WM's
/// taskbar-entry click decision (restore/focus), applied by the kernel.
pub fn note_taskbar() void {
    taskbar_count +%= 1;
}

/// M42 UX (2026-09-05): note one WIN_CLOSE (cmd 13) close — the WM's
/// close decision, applied by the kernel through `user_close`.
pub fn note_win_close() void {
    win_close_count +%= 1;
}

/// S6 Tab model (Milestone 19, issue #782): notes for tab operations.
pub fn note_tab_attach() void {
    tab_attach_count +%= 1;
}
pub fn note_tab_detach() void {
    tab_detach_count +%= 1;
}
pub fn note_tab_activate() void {
    tab_activate_count +%= 1;
}

/// WM2 mission-control overview (issue #707 card 2): note one accepted
/// OVERVIEW submission — the WM's grid-policy decision applied.
pub fn note_overview() void {
    overview_count +%= 1;
}

// ---------------------------------------------------------------------------
// Host tests (Class A) — the pure register/teardown/tick/present contracts
// ---------------------------------------------------------------------------

test "wm_server: register is one-seat and teardown falls back to the shim" {
    init();
    // No WM registered: shim mode.
    try std.testing.expect(!registered());
    try std.testing.expect(registered_pid() == null);

    // First register wins; a second is refused (the handler maps it to EACCES).
    try std.testing.expect(register(3));
    try std.testing.expect(registered());
    try std.testing.expectEqual(@as(?usize, 3), registered_pid());
    try std.testing.expect(!register(5));

    // WMS5 (issue #625): registering hands input ownership to the WM — the
    // kernel stops consuming pointer geometry and the raw-stream fan-out
    // hooks go live (they no-op when no WM is registered).
    try std.testing.expect(driving_award.wm_owns_input);
    try std.testing.expect(driving_award.wm_pointer_hook != null);
    try std.testing.expect(driving_award.wm_window_hook != null);
    // WMS5 Gate 2 (claim 4278): the keyboard fan-out hook goes live too.
    try std.testing.expect(driving_award.wm_key_hook != null);

    // Teardown unregisters the registrant; a non-owner exit is a no-op.
    try std.testing.expect(!unregister(4));
    try std.testing.expect(unregister(3));
    try std.testing.expect(!registered());
    try std.testing.expect(registered_pid() == null);

    // WMS5: input ownership and the fan-out hooks die with the WM (shim
    // fallback — the kernel resumes consuming pointer geometry exactly as
    // before; zero regression).
    try std.testing.expect(!driving_award.wm_owns_input);
    try std.testing.expect(driving_award.wm_pointer_hook == null);
    try std.testing.expect(driving_award.wm_window_hook == null);
    try std.testing.expect(driving_award.wm_key_hook == null);

    // The fallback report is drained exactly once after a teardown.
    try std.testing.expect(take_fallback_report());
    try std.testing.expect(!take_fallback_report());
    // ... and re-registering clears the pending flag (then tear down so the
    // aggregated test binary does not leak input ownership into later tests).
    try std.testing.expect(register(7));
    try std.testing.expect(!take_fallback_report());
    try std.testing.expect(unregister(7));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "wm_server: WMS5 raw-pointer and window-mirror fan-out is WM-only (kind 19/20 routing)" {
    events.init();
    init();
    events.on_event_pushed = null;

    // No WM: fan-outs are no-ops (nothing is generated, nothing changes).
    fan_pointer(100, 200, 0x01, 0);
    fan_window(2, 10, 20, 30, 40, true, true, 0, false, false);
    fan_key(0x17, events.MOD_CTRL); // Gate 2: Ctrl+T usage
    try std.testing.expectEqual(@as(u64, 0), info().pointer_fan_count);
    try std.testing.expectEqual(@as(u64, 0), info().window_mirror_count);
    try std.testing.expectEqual(@as(u64, 0), info().key_fan_count);

    // Register pid 3: the fan-outs deliver kind 19/20/21 ONLY to the WM.
    try std.testing.expect(register(3));
    fan_pointer(100, 200, 0x01, 0x02);
    fan_window(2, 10, 20, 30, 40, true, true, 0, false, false);
    fan_key(0x17, events.MOD_CTRL); // Gate 2: Ctrl+T usage
    try std.testing.expectEqual(@as(u64, 1), info().pointer_fan_count);
    try std.testing.expectEqual(@as(u64, 1), info().window_mirror_count);
    try std.testing.expectEqual(@as(u64, 1), info().key_fan_count);

    const p = events.pop(3).?;
    try std.testing.expectEqual(events.WM_POINTER, p.kind);
    try std.testing.expectEqual(@as(u16, 0x01), p.flags); // button byte
    try std.testing.expectEqual(@as(u32, 100 | (200 << 16)), p.arg0); // x|(y<<16)
    try std.testing.expectEqual(@as(u32, 0x02), p.arg1); // capture-time modifier byte (#2896)

    const w = events.pop(3).?;
    try std.testing.expectEqual(events.WM_WINDOW, w.kind);
    try std.testing.expectEqual(@as(u16, 2 | (1 << 8) | (1 << 9)), w.flags); // id | visible | focused
    try std.testing.expectEqual(@as(u32, 10 | (20 << 16)), w.arg0);
    try std.testing.expectEqual(@as(u32, 30 | (40 << 16)), w.arg1);

    // Gate 2 (claim 4278): kind 21 WM_KEY carries the raw usage + modifier
    // bits — the WM's chord decoder input.
    const k = events.pop(3).?;
    try std.testing.expectEqual(events.WM_KEY, k.kind);
    try std.testing.expectEqual(@as(u16, events.MOD_CTRL), k.flags);
    try std.testing.expectEqual(@as(u32, 0x17), k.arg0); // Ctrl+T usage

    // WMS8 Gate 4 (issue #628): the unsaved bit (12) rides the mirror —
    // the WM's dirty-window decision input (pushed after the key so the
    // FIFO pops in order).
    fan_window(2, 10, 20, 30, 40, true, true, 0, true, false);
    const wu = events.pop(3).?;
    try std.testing.expectEqual(events.WM_WINDOW, wu.kind);
    try std.testing.expectEqual(@as(u16, 2 | (1 << 8) | (1 << 9) | (1 << 12)), wu.flags); // + unsaved
    try std.testing.expectEqual(@as(u64, 2), info().window_mirror_count);

    // No other process's queue received anything (the kind-18 discipline).
    var i: usize = 0;
    while (i < process.max_processes) : (i += 1) {
        if (i != 3) try std.testing.expectEqual(@as(usize, 0), events.pending(i));
    }
    // Teardown: fan-outs stop again (and the flag is clean for later tests).
    try std.testing.expect(unregister(3));
    fan_pointer(100, 200, 0x01, 0);
    fan_key(0x17, events.MOD_CTRL);
    try std.testing.expectEqual(@as(u64, 1), info().pointer_fan_count); // unchanged
    try std.testing.expectEqual(@as(u64, 1), info().key_fan_count); // unchanged
}

test "wm_server: remove_user_at fans a RELEASED mirror to the WM (M42 UX, flags bit 13)" {
    events.init();
    init();
    events.on_event_pushed = null;
    driving_award.arm();
    try std.testing.expect(register(4));

    // user_open fans the plain open mirror TWICE — focus() mirrors the
    // newly focused window (WMS5) and user_open mirrors the opened one.
    // Both are open-shaped: visible set, bit 13 CLEAR.
    const first = switch (driving_award.user_open(10, 10, 100, 80, 9)) {
        .opened => |id| id,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 2), first);
    const open_m = events.pop(4).?;
    try std.testing.expectEqual(events.WM_WINDOW, open_m.kind);
    try std.testing.expect((open_m.flags & (1 << 8)) != 0); // visible
    try std.testing.expect((open_m.flags & (1 << 13)) == 0); // NOT released
    const open_m2 = events.pop(4).?;
    try std.testing.expectEqual(events.WM_WINDOW, open_m2.kind);
    try std.testing.expect((open_m2.flags & (1 << 8)) != 0);
    try std.testing.expect((open_m2.flags & (1 << 13)) == 0);

    // user_close -> remove_user_at fans exactly ONE mirror: visible=false,
    // focused (the window held focus), RELEASED (bit 13) — the WM learns
    // the window LEFT the registry, not merely hid.
    try std.testing.expect(driving_award.user_close(2));
    const rel = events.pop(4).?;
    try std.testing.expectEqual(events.WM_WINDOW, rel.kind);
    try std.testing.expectEqual(@as(u16, 2 | (1 << 9) | (1 << 13)), rel.flags);
    try std.testing.expectEqual(@as(u32, 10 | (10 << 16)), rel.arg0);
    try std.testing.expectEqual(@as(u32, 100 | (80 << 16)), rel.arg1);
    try std.testing.expect(events.pop(4) == null); // exactly ONE mirror per release

    // The app self-exit path fans the same mirror: close_owner (the exit
    // path's teardown seam) releases the owner's remaining window.
    const second = switch (driving_award.user_open(20, 20, 64, 64, 9)) {
        .opened => |id| id,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 2), second); // the released slot is reused
    _ = events.pop(4).?; // drain the two plain open mirrors
    _ = events.pop(4).?;
    try std.testing.expectEqual(@as(usize, 1), driving_award.close_owner(9));
    const rel2 = events.pop(4).?;
    try std.testing.expectEqual(events.WM_WINDOW, rel2.kind);
    try std.testing.expectEqual(@as(u16, 2 | (1 << 9) | (1 << 13)), rel2.flags);
    try std.testing.expect(events.pop(4) == null); // exactly ONE mirror per release

    // Teardown: the WM seat and hooks are clean for later tests.
    try std.testing.expect(unregister(4));
}

test "wm_server: SET_STATE counter + keyboard fan-out (claim 4278, WMS5 Gate 2)" {
    events.init();
    init();
    events.on_event_pushed = null;
    // The SET_STATE counter is monotonically incremented by the syscall
    // layer's handler; here we just pin the note contract (no WM needed).
    note_set_state();
    try std.testing.expectEqual(@as(u64, 1), info().set_state_count);
    init();
    try std.testing.expectEqual(@as(u64, 0), info().set_state_count);
    // Fan-out of a raw key with NO WM registered is a silent no-op (shim).
    fan_key(0x17, events.MOD_CTRL);
    try std.testing.expectEqual(@as(u64, 0), info().key_fan_count);
}

test "wm_server: OVERVIEW counter + opcode freeze (WM2, issue #707 card 2)" {
    init();
    // The opcode is frozen at 21 (slot 65, zero new slots).
    try std.testing.expectEqual(@as(u64, 21), wmctl_overview);
    try std.testing.expectEqual(@as(u64, 0), info().overview_count);
    note_overview();
    note_overview();
    try std.testing.expectEqual(@as(u64, 2), info().overview_count);
    init();
    try std.testing.expectEqual(@as(u64, 0), info().overview_count);
}

test "wm_server: COMPOSITE_TICK is delivered only to the registered WM with the present sequence" {
    events.init();
    init();
    events.on_event_pushed = null;

    // No WM registered: on_tick is a no-op, nothing is generated.
    on_tick();
    var i: usize = 0;
    while (i < process.max_processes) : (i += 1) {
        try std.testing.expectEqual(@as(usize, 0), events.pending(i));
    }

    // Register pid 3; the next tick delivers kind 18 with arg0 = present seq.
    try std.testing.expect(register(3));
    on_tick();
    on_tick();
    try std.testing.expectEqual(@as(usize, 2), events.pending(3));
    const ev = events.pop(3).?;
    try std.testing.expectEqual(events.COMPOSITE_TICK, ev.kind);
    try std.testing.expectEqual(@as(u32, present_seq), ev.arg0);
    try std.testing.expectEqual(@as(u32, 0), ev.arg1);

    // No other process's queue received a tick (the routing restriction).
    var j: usize = 0;
    while (j < process.max_processes) : (j += 1) {
        if (j != 3) try std.testing.expectEqual(@as(usize, 0), events.pending(j));
    }
    try std.testing.expectEqual(@as(u64, 2), info().tick_count);
    // Tear down so the aggregated test binary does not leak input ownership.
    try std.testing.expect(unregister(3));
    try std.testing.expect(!driving_award.wm_owns_input);
}

test "wm_server: the scanout grant is WM-seat-only; teardown clears the seat (claim 7397)" {
    init();
    try std.testing.expect(!scanout_bound(1));
    try std.testing.expect(scanout_va_get() == null);
    // A non-WM caller is refused BEFORE any MMU work (the seat is the
    // privilege) — the dummy ProcessInfo is never read on this path.
    const dummy: process.ProcessInfo = undefined;
    try std.testing.expectEqual(@as(u64, 0), scanout_bind(1, dummy));
    try std.testing.expectEqual(@as(u64, 0), scanout_bind(2, dummy));
    // Teardown with nothing bound is a safe no-op.
    scanout_teardown();
    try std.testing.expect(!driving_award.wm_owns_user_layer);
}

test "wm_server: REQUEST_PRESENT advances the present sequence and count" {
    init();
    try std.testing.expect(!request_present()); // no WM registered
    try std.testing.expect(register(3));
    try std.testing.expect(request_present());
    try std.testing.expect(request_present());
    const inf = info();
    try std.testing.expectEqual(@as(?usize, 3), inf.pid);
    try std.testing.expectEqual(@as(u32, 2), inf.present_seq);
    try std.testing.expectEqual(@as(u64, 2), inf.present_count);
    // Tear down so the aggregated test binary does not leak input ownership.
    try std.testing.expect(unregister(3));
    try std.testing.expect(!driving_award.wm_owns_input);
}

var m91_transfer_result: virtio_gpu.CmdResult = .ok;
var m91_flush_result: virtio_gpu.CmdResult = .ok;
var m91_transfer_n: usize = 0;
var m91_flush_n: usize = 0;
var m91_frame_valid: bool = false;
fn m91_transfer() virtio_gpu.CmdResult {
    m91_transfer_n += 1;
    const c = driving_award.cursor_pos().?;
    const off = (c.y * virtio_gpu.fb_width + c.x) * 4;
    m91_frame_valid = std.mem.readInt(u32, virtio_gpu.gpu_fb[off..][0..4], .little) ==
        (driving_award.cursor_outline_rgb | 0xff000000) and
        std.mem.readInt(u32, virtio_gpu.gpu_fb[0..4], .little) == 0x42424242;
    return m91_transfer_result;
}
fn m91_flush() virtio_gpu.CmdResult {
    m91_flush_n += 1;
    return m91_flush_result;
}

test "wm_server: M91 presents completed seat stores and cursor exactly once; failed frames do not advance" {
    events.init();
    process.init();
    init();
    driving_award.arm();
    try std.testing.expect(register(3));
    driving_award.wm_owns_user_layer = true;
    driving_award.transfer_hook = m91_transfer;
    driving_award.flush_hook = m91_flush;
    defer {
        driving_award.transfer_hook = null;
        driving_award.flush_hook = null;
        _ = unregister(3);
        driving_award.wm_owns_user_layer = false;
    }
    m91_transfer_n = 0;
    m91_flush_n = 0;
    m91_transfer_result = .ok;
    m91_flush_result = .ok;
    _ = driving_award.pointer_tick(.{ .x = 16384, .y = 16384, .buttons = 0, .valid = true }, null);
    on_tick(); // kernel layer preparation is NOT a present
    @memset(&virtio_gpu.gpu_fb, 0x42); // the seat's completed chrome/client stores
    try std.testing.expectEqual(virtio_gpu.CmdResult.ok, driving_award.composite());
    try std.testing.expectEqual(@as(usize, 0), m91_transfer_n);
    try std.testing.expect(request_present());
    try std.testing.expect(m91_frame_valid);
    try std.testing.expectEqual(@as(usize, 1), m91_transfer_n);
    try std.testing.expectEqual(@as(usize, 1), m91_flush_n);
    try std.testing.expectEqual(@as(u32, 1), info().present_seq);
    for (virtio_gpu.gpu_fb) |byte| try std.testing.expectEqual(@as(u8, 0x42), byte);

    // The next tick carries the COMPLETED sequence, not an attempted frame.
    _ = events.pop(3); // pointer fan
    _ = events.pop(3); // first tick
    on_tick();
    const tick = events.pop(3).?;
    try std.testing.expectEqual(events.COMPOSITE_TICK, tick.kind);
    try std.testing.expectEqual(@as(u32, 1), tick.arg0);
    @memset(&virtio_gpu.gpu_fb, 0x42);
    m91_transfer_result = .timeout;
    try std.testing.expect(!request_present());
    try std.testing.expectEqual(@as(usize, 1), m91_flush_n); // failed transfer never flushes
    m91_transfer_result = .ok;
    m91_flush_result = .not_ready;
    try std.testing.expect(!request_present());
    try std.testing.expectEqual(@as(u32, 1), info().present_seq);
    try std.testing.expectEqual(@as(u64, 1), info().present_count);
    try std.testing.expectEqual(@as(u64, 1), info().flush_count);
    for (virtio_gpu.gpu_fb) |byte| try std.testing.expectEqual(@as(u8, 0x42), byte);
    m91_flush_result = .ok;
    try std.testing.expect(request_present());
    try std.testing.expectEqual(@as(u32, 2), info().present_seq);
}

test "wm_server: M91 bind/unbind/rebind and seat death return damaged scanout to shim" {
    init();
    process.init();
    mmu.reset();
    driving_award.arm();
    const root = mmu.build_user_root(0x400000, 0x3000, 64, 0x70000000, 0x4000, 8192).?;
    const seat = process.create("WM.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{ .root_phys = root }, .{}).?;
    _ = process.bind(seat, 9);
    const old_phys = virtio_gpu.gpu_fb_phys;
    virtio_gpu.gpu_fb_phys = 0x90000000;
    defer {
        _ = unregister(seat);
        virtio_gpu.gpu_fb_phys = old_phys;
        process.init();
        mmu.reset();
    }
    try std.testing.expect(register(seat));
    const va = scanout_bind(seat, process.info(seat).?);
    try std.testing.expect(va != 0);
    try std.testing.expectEqual(va, scanout_bind(seat, process.info(seat).?));
    try std.testing.expect(driving_award.wm_owns_user_layer);
    _ = driving_award.paint_scene(); // fixed-layer damage consumed under the seat
    scanout_teardown();
    try std.testing.expect(!driving_award.wm_owns_user_layer);
    try std.testing.expect(!mmu.leaf_el0_visible(root, va));
    try std.testing.expect(driving_award.windows[0].dirty);
    _ = driving_award.paint_scene();
    try std.testing.expect(driving_award.scene_dirty); // shim recovery actually paints
    const next = scanout_bind(seat, process.info(seat).?);
    try std.testing.expect(next != 0 and next != va);
    _ = process.on_task_exit(9, 0);
    const before = info().present_seq;
    try std.testing.expect(!request_present());
    try std.testing.expectEqual(before, info().present_seq);
    try std.testing.expect(unregister(seat));
    try std.testing.expect(!driving_award.wm_owns_user_layer);
    try std.testing.expect(!driving_award.wm_owns_input);
    try std.testing.expect(driving_award.windows[0].dirty);
    try std.testing.expect(take_fallback_report());
    try std.testing.expect(!take_fallback_report());
}

/// M53 card 1 (#1247): the injected clock. `step` lets a test advance time per
/// read (which is how the kernel+GPU half gets a nonzero figure) or hold it
/// still and position it by hand (which is how the latency math is pinned
/// exactly).
var test_clock_ns: u64 = 0;
var test_clock_step: u64 = 0;
fn test_clock() u64 {
    test_clock_ns += test_clock_step;
    return test_clock_ns;
}

test "wm_server: M53 frame observability — cadence + both latency halves from an injected clock" {
    events.init();
    init();
    events.on_event_pushed = null;
    process.init();
    const seat = process.create("WND.BIN", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(seat, 9);
    try std.testing.expect(register(seat));

    now_ns_hook = &test_clock;
    defer now_ns_hook = null;
    test_clock_step = 0; // hold time still; position it by hand
    test_clock_ns = 1_000;

    // Present 1: the rate window's left edge. No input is outstanding, so it
    // records a flush but NO latency sample (never fabricate a sample).
    try std.testing.expect(request_present());
    try std.testing.expectEqual(@as(u64, 0), info().lat_count);

    // An input sample 10 ms later, answered 30 ms after that: the WM's half of
    // the latency — how long the sample waited for the WM's own present.
    test_clock_ns += 10_000_000;
    fan_pointer(1, 2, 0, 0);
    test_clock_ns += 30_000_000;
    try std.testing.expect(request_present());
    try std.testing.expectEqual(@as(u64, 1), info().lat_count);
    try std.testing.expectEqual(@as(u64, 30_000_000), info().lat_avg_ns);
    try std.testing.expectEqual(@as(u64, 30_000_000), info().lat_max_ns);

    // A second sample (keyboard rides the same seam) that waits only 5 ms: the
    // average moves, the max does not.
    test_clock_ns += 1;
    fan_key(0x04, 0);
    test_clock_ns += 5_000_000;
    try std.testing.expect(request_present());
    try std.testing.expectEqual(@as(u64, 2), info().lat_count);
    try std.testing.expectEqual(@as(u64, 17_500_000), info().lat_avg_ns);
    try std.testing.expectEqual(@as(u64, 30_000_000), info().lat_max_ns);

    // A present nobody was waiting for adds no sample and does not move max.
    test_clock_ns += 1_000_000;
    try std.testing.expect(request_present());
    try std.testing.expectEqual(@as(u64, 2), info().lat_count);
    // 4 presents over a 46.000001 ms window -> 3 gaps -> 46 ms window,
    // 15 ms average interval (the pps form would have read 65; the interval
    // form is what a sub-1 pps desktop needs to be legible at all).
    try std.testing.expectEqual(@as(u64, 46), info().present_window_ms);
    try std.testing.expectEqual(@as(u64, 15), info().present_avg_ms);
    // No ticks yet: the tick interval is 0, not a fabricated 1 s.
    try std.testing.expectEqual(@as(u64, 0), info().tick_avg_ms);
    try std.testing.expectEqual(@as(u64, 4), info().flush_count);

    // Now advance the clock per read: the present's own t0..t1 span becomes a
    // real 1 ms, which is the SHAPE of the kernel+GPU half (the figure is a
    // hardware number only on the live gate — this pins the accounting).
    test_clock_step = 1_000_000;
    try std.testing.expect(request_present());
    try std.testing.expectEqual(@as(u64, 5), info().flush_count);
    try std.testing.expectEqual(@as(u64, 200_000), info().flush_avg_ns);
    try std.testing.expectEqual(@as(u64, 1_000_000), info().flush_max_ns);
    try std.testing.expectEqual(@as(u64, 2), info().lat_count); // still nothing outstanding

    // The tick interval is measured the same way — one tick per second.
    test_clock_step = 0;
    test_clock_ns = 1_000_000_000;
    on_tick();
    test_clock_ns = 2_000_000_000;
    on_tick();
    try std.testing.expectEqual(@as(u64, 1000), info().tick_avg_ms);
    // And it SURVIVES drift: a third tick 20 ms late reads as a 1010 ms
    // average interval. The pps form read 0 for the same span (2/2.02
    // truncates) — which is exactly how the live run's `tick_pps=0` beside
    // `ticks=31` was caught.
    test_clock_ns = 3_020_000_000;
    on_tick();
    try std.testing.expectEqual(@as(u64, 1010), info().tick_avg_ms);

    // Tear down for the aggregated binary.
    try std.testing.expect(unregister(seat));
    process.init();
}

test "wm_server: seat release drops every WM-owned input capture (M52 card 2, #1239)" {
    events.init();
    init();
    events.on_event_pushed = null;
    driving_award.arm();

    // Two live windows: the Alt+Tab snapshot and the overview grid both need
    // more than one alt-tab-able card to open.
    const a = switch (driving_award.user_open(10, 10, 200, 120, 3)) {
        .opened => |id| id,
        else => return error.TestUnexpectedResult,
    };
    const b = switch (driving_award.user_open(240, 10, 200, 120, 3)) {
        .opened => |id| id,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(a != b);

    try std.testing.expect(register(3));
    // Open every capture through the SAME applied primitive the WM's slot-65
    // command reaches: cmd 5 activate / cmd 21 enter / cmd 8 show /
    // cmd 6 open / cmd 11 (about + unsaved).
    try std.testing.expect(driving_award.alt_tab_activate());
    try std.testing.expect(driving_award.overlay_active);
    _ = driving_award.overview_enter();
    try std.testing.expect(driving_award.overview_is_open());
    driving_award.tooltip_show("Clock");
    try std.testing.expect(driving_award.tooltip_visible);
    driving_award.notif_center_set_open(true);
    try std.testing.expect(driving_award.notif_center_open);
    driving_award.about_dialog_open_dialog();
    try std.testing.expect(driving_award.about_dialog_open);
    driving_award.unsaved_dialog_show(a);
    try std.testing.expect(driving_award.unsaved_dialog_is_open());

    // A non-owner exit is a no-op for the seat AND its captures.
    try std.testing.expect(!unregister(4));
    try std.testing.expect(driving_award.overlay_active);
    try std.testing.expect(driving_award.tooltip_visible);

    // The SEAT RELEASE drops all six — the resumed shim never inherits a
    // modality it has no path to dismiss.
    try std.testing.expect(unregister(3));
    try std.testing.expect(!driving_award.overlay_active);
    try std.testing.expect(!driving_award.overview_is_open());
    try std.testing.expect(!driving_award.tooltip_visible);
    try std.testing.expect(!driving_award.notif_center_open);
    try std.testing.expect(!driving_award.about_dialog_open);
    try std.testing.expect(!driving_award.unsaved_dialog_is_open());
}

test "wm_server: a dead seat routes nothing — no tick, no fan-out (M52 card 2, #1239)" {
    events.init();
    init();
    events.on_event_pushed = null;
    process.init();
    const seat = process.create("WND.BIN", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(seat, 9);
    try std.testing.expectEqual(process.State.running, process.info(seat).?.state);
    try std.testing.expect(register(seat));

    // Baseline: a LIVE seat takes the tick and all three fans.
    on_tick();
    fan_pointer(1, 2, 0, 0);
    fan_window(2, 3, 4, 5, 6, true, true, 0, false, false);
    fan_key(0x17, events.MOD_CTRL);
    try std.testing.expectEqual(@as(usize, 4), events.pending(seat));
    const tick0 = info().tick_count;
    try std.testing.expectEqual(@as(u64, 1), tick0);

    // The process dies WITHOUT the register being told. The scheduler exit
    // seam is the seat-release authority (it calls `unregister`); this pins
    // the NET for any path that reaches a dead pid with the seat still bound.
    _ = process.on_task_exit(9, 0);
    try std.testing.expectEqual(process.State.exited, process.info(seat).?.state);
    try std.testing.expect(seat_dead(seat));

    const ptr0 = info().pointer_fan_count;
    const win0 = info().window_mirror_count;
    const key0 = info().key_fan_count;
    on_tick();
    fan_pointer(9, 9, 1, 0);
    fan_window(2, 9, 9, 9, 9, true, false, 0, false, true);
    fan_key(0x04, events.MOD_SHIFT);
    // Nothing was routed to the dead pid, and no counter claimed a delivery.
    try std.testing.expectEqual(@as(usize, 4), events.pending(seat));
    try std.testing.expectEqual(tick0, info().tick_count);
    try std.testing.expectEqual(ptr0, info().pointer_fan_count);
    try std.testing.expectEqual(win0, info().window_mirror_count);
    try std.testing.expectEqual(key0, info().key_fan_count);
    // The gate refuses to ROUTE; it does not silently release the seat.
    try std.testing.expectEqual(@as(?usize, seat), registered_pid());

    // Tear down for the aggregated binary: release the seat, then the row.
    try std.testing.expect(unregister(seat));
    try std.testing.expect(!driving_award.wm_owns_input);
    process.init();
    try std.testing.expect(!seat_dead(seat)); // no descriptor is NOT death
}
