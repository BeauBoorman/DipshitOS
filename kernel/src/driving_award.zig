//! Milestone six card G5 (claim 1543) — Driving Award, the window manager.
//!
//! A bounded window registry (fixed BSS, no heap) with z-order, focus,
//! hit-testing, and a dirty-rect compositor that blits window buffers into
//! the G1 framebuffer (kernel/src/virtio_gpu.zig). Road Pops — the G3 boot
//! terminal (kernel/src/text.zig, kernel/src/road_pops.zig) — is the FIRST
//! window (window 0, a full-screen terminal); a second demo window (a 1 Hz
//! clock) overlaps its top-right corner and proves multiple windows with
//! distinct content + focus.
//!
//! Z-order is the registry array order (index 0 = bottom, the last index =
//! top). `raise` moves a window to the top; focus is tracked by window id
//! (stable across raises), and `hit_test` returns the TOPMOST visible window
//! containing a point. The compositor repaints from the lowest dirty window
//! upward — a genuine dirty-rect redraw: a window whose content did not
//! change is never repainted, and the scanout transfer + flush run once per
//! dirty batch (the G1/G2/G3 full-frame present discipline).
//!
//! Window 0 (the terminal) renders the shared text layer straight into the
//! scanout framebuffer (its "buffer" IS the framebuffer — a terminal
//! redraws its full client area, which here is the whole screen). Window 1
//! (the clock) renders into its own fixed BSS back-buffer, which the
//! compositor blits over the terminal. Because the terminal's repaint
//! covers the clock's region, the compositor repaints from the lowest dirty
//! window UP, so the clock is always re-blitted over a freshly repainted
//! terminal — the classic overlay-preserving order.
//!
//! Input routing (the I3 path): keyboard bytes reach the Road Pops line
//! editor only while the terminal window is focused (`terminal_focused`);
//! when another window holds focus the keystrokes simply queue in the input
//! FIFO until the terminal regains focus. Serial (the scripted evidence
//! channel) stays an always-wired fallback, unchanged.
//!
//! No libc, no POSIX, no allocation, no function pointers in any const
//! table (the claim-0015 discipline — the registry is a BSS array built at
//! runtime).
//!
//! Host tests pin the pure contracts: hit-test, z-order/raise, focus, the
//! repaint-from-lowest-dirty plan, the clock rendering, and the blit.

const std = @import("std");
const font = @import("font8x8.zig");
const input = @import("input.zig"); // card U4 (claim 4993): the pointer reports
const virtio_gpu = @import("virtio_gpu.zig");
const fbtext = @import("text.zig");

// ---------------------------------------------------------------------------
// Geometry + colors (fixed constants — the live record lives in the claim)
// ---------------------------------------------------------------------------

/// Bounded window registry size (fixed BSS).
pub const max_windows: usize = 8;

/// The clock window: an overlay in the terminal's top-right corner. 304x192
/// at (960,16) — inside the 1280x720 scanout, overlapping the terminal.
pub const clock_x: u32 = 960;
pub const clock_y: u32 = 16;
pub const clock_w: u32 = 304;
pub const clock_h: u32 = 192;

/// Clock palette (0xRRGGBB) — deliberately distinct from the terminal's
/// green-on-dark so the live gate can tell the two windows apart by pixel.
pub const clock_border_rgb: u32 = 0x8899aa;
pub const clock_title_bg_rgb: u32 = 0xb58900; // amber title bar
pub const clock_title_fg_rgb: u32 = 0x141414;
pub const clock_bg_rgb: u32 = 0x0a1a2e; // dark navy body
pub const clock_fg_rgb: u32 = 0xd8dee9; // light body text
pub const clock_accent_rgb: u32 = 0xffaa00; // amber accent (mascot line)

/// Card U5 (claim 0935, ADR 0008 D4): the HIG chrome palette. The focus
/// ring is white (distinct from every window fill); the user title bar
/// reuses the window-manager's dark blue with white text. The U4 cursor
/// is magenta — a color nothing else renders, so the pixel gates can find
/// it unambiguously.
pub const focus_ring_rgb: u32 = 0xffffff;
pub const focus_ring_w: usize = 3;
pub const user_title_h: usize = 16;
pub const user_title_bg_rgb: u32 = 0x1a2b3c;
pub const user_title_fg_rgb: u32 = 0xffffff;
pub const cursor_rgb: u32 = 0xff00ff;
pub const cursor_w: usize = 8;
pub const cursor_h: usize = 8;

/// Card G6 (claim 0487): user windows — the draw/window syscall seam.
/// Bounded: TWO user windows (ids 2 and 3, `user_window_id_base`), each a
/// fixed BSS back-buffer `user_buf_w` × `user_buf_h` B8G8R8X8 that the
/// kernel owns and an EL0 program renders into through `sys_win_open` /
/// `sys_win_fill` / `sys_win_present`. The buffers never outgrow this
/// bound (no heap, no allocation).
pub const user_window_id_base: u8 = 2;
pub const user_windows_max: usize = 2;
pub const user_buf_w: u32 = 256;
pub const user_buf_h: u32 = 192;

/// The window-kind tags (the terminal and the demo window).
pub const Kind = enum {
    terminal,
    clock,
    user,
};

/// One window in the registry. Value type; the registry is a fixed BSS
/// array. `title` is a static string literal (data, never a function
/// pointer — safe at any load base).
pub const Window = struct {
    id: u8,
    title: []const u8,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    kind: Kind,
    visible: bool,
    dirty: bool,
    /// Card G6 teardown follow-on (per-process ownership): the owning
    /// process id for a `.user` window (null for the fixed terminal +
    /// clock, which are kernel-owned). The syscall layer records the
    /// caller here at `sys_win_open`, restricts fill/present/close to the
    /// owner, and the exit path auto-closes the owner's windows via
    /// `close_owner` — a real teardown semantic instead of a window that
    /// leaks until reboot.
    owner: ?usize = null,
};

// ---------------------------------------------------------------------------
// Registry state (fixed BSS)
// ---------------------------------------------------------------------------

var windows: [max_windows]Window = undefined;
var win_count: usize = 0;
/// Focused window id (stable across raises); 0xff = none.
var focused_id: u8 = 0xff;
var armed_global: bool = false;
/// Scanout presents pushed by the compositor since arm.
var presents: usize = 0;

/// The clock's back-buffer (fixed BSS, contiguous B8G8R8X8). The
/// compositor blits it over the terminal.
var clock_buf: [clock_w * clock_h * 4]u8 = undefined;
/// Card G6 (claim 0487): the user windows' back-buffers (fixed BSS).
var user_bufs: [user_windows_max][user_buf_w * user_buf_h * 4]u8 = undefined;
/// The clock's displayed tick (so it only repaints when the second changes).
var clock_shown_tick: u64 = 0;
var clock_has_tick: bool = false;

/// Card U4 (claim 4993): the pointer cursor's framebuffer position. Hidden
/// until the first pointer report arrives (the default VM has no pointer).
var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var cursor_shown: bool = false;

// ---------------------------------------------------------------------------
// Arm / query
// ---------------------------------------------------------------------------

/// Arm the window manager: register the terminal (window 0, full screen)
/// and the clock (window 1, the overlay), focus the terminal, and mark
/// both dirty so the first composite paints the full scene.
pub fn arm() void {
    win_count = 0;
    windows[win_count] = .{
        .id = 0,
        .title = "roadpops",
        .x = 0,
        .y = 0,
        .w = virtio_gpu.fb_width,
        .h = virtio_gpu.fb_height,
        .kind = .terminal,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    windows[win_count] = .{
        .id = 1,
        .title = "clock",
        .x = clock_x,
        .y = clock_y,
        .w = clock_w,
        .h = clock_h,
        .kind = .clock,
        .visible = true,
        .dirty = true,
    };
    win_count += 1;
    focused_id = 0;
    armed_global = true;
    presents = 0;
    clock_shown_tick = 0;
    clock_has_tick = false;
}

pub fn armed() bool {
    return armed_global;
}

pub fn count() usize {
    return win_count;
}

pub fn presents_pushed() usize {
    return presents;
}

pub fn window_at(i: usize) ?*const Window {
    if (i >= win_count) return null;
    return &windows[i];
}

pub fn kind_name(kind: Kind) []const u8 {
    return switch (kind) {
        .terminal => "terminal",
        .clock => "clock",
        .user => "user",
    };
}

// ---------------------------------------------------------------------------
// Z-order, focus, hit-testing (pure — host-testable)
// ---------------------------------------------------------------------------

/// The index of the focused window, or null when none.
pub fn focused_index() ?usize {
    if (!armed_global) return null;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == focused_id) return i;
    }
    return null;
}

/// The focused window's id, or 0xff when none.
pub fn focused_window_id() u8 {
    return focused_id;
}

/// True when the focused window is the terminal (the I3 keyboard sink).
pub fn terminal_focused() bool {
    const fi = focused_index() orelse return false;
    return windows[fi].kind == .terminal;
}

/// Focus a window by id. Returns false for an unknown id.
pub fn focus(id: u8) bool {
    if (!armed_global) return false;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            // Card U5 (ADR 0008 D4): focus is ALWAYS VISIBLE — a focus
            // change must repaint so the ring moves.
            if (focused_id != id) _ = mark_dirty(0);
            focused_id = id;
            return true;
        }
    }
    return false;
}

/// Raise a window to the top of the z-order (the end of the array). Focus
/// is unchanged (tracked by id). Returns false for an unknown id.
pub fn raise(id: u8) bool {
    if (!armed_global) return false;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            const moved = windows[i];
            var j = i;
            while (j + 1 < win_count) : (j += 1) windows[j] = windows[j + 1];
            windows[win_count - 1] = moved;
            // Re-blit the raised window (z-order changed).
            windows[win_count - 1].dirty = true;
            return true;
        }
    }
    return false;
}

/// The topmost visible window containing (x, y), or null when none does.
pub fn hit_test(x: u32, y: u32) ?u8 {
    var i: usize = win_count;
    while (i > 0) {
        i -= 1;
        const w = &windows[i];
        if (!w.visible) continue;
        if (x >= w.x and x < w.x + w.w and y >= w.y and y < w.y + w.h) return w.id;
    }
    return null;
}

/// Focus the topmost window at (x, y). Returns false when nothing is there.
pub fn focus_at(x: u32, y: u32) bool {
    const id = hit_test(x, y) orelse return false;
    return focus(id);
}

// ---------------------------------------------------------------------------
// Dirty tracking
// ---------------------------------------------------------------------------

/// Mark a window dirty (by id) so the next composite repaints it. Returns
/// false for an unknown id.
pub fn mark_dirty(id: u8) bool {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id) {
            windows[i].dirty = true;
            return true;
        }
    }
    return false;
}

/// Mark the terminal (window 0) dirty — the Road Pops tee's write path.
pub fn mark_terminal_dirty() void {
    if (win_count > 0) windows[0].dirty = true;
}

// ---------------------------------------------------------------------------
// Card G6 (claim 0487): the draw/window syscall seam — user windows
// ---------------------------------------------------------------------------

pub const UserOpenResult = union(enum) {
    opened: u8,
    invalid: void,
    full: void,
};

/// Find a user window by id (only `.user` kinds — the terminal/clock ids
/// are fixed and never match the user id base).
fn find_user_window(id: u8) ?*Window {
    const idx = find_user_window_index(id) orelse return null;
    return &windows[idx];
}

/// The registry index of a user window, or null.
fn find_user_window_index(id: u8) ?usize {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].id == id and windows[i].kind == .user) return i;
    }
    return null;
}

/// Open a kernel-owned user window at screen position (x, y) with a
/// back-buffer w×h (≤ `user_buf_w` × `user_buf_h`), OWNED by the process
/// `owner` (the syscall layer records the caller's pid here). The window
/// is appended at the top of the z-order and focused. Returns `.opened`
/// with the id (2..3), `.invalid` for geometry outside the
/// back-buffer/scanout bounds (or when the manager is unarmed — no gpu),
/// and `.full` when both user slots are already open. The window is
/// OWNED by `owner` — it auto-closes when that process exits (the
/// scheduler's exit path calls `close_owner`).
pub fn user_open(x: u32, y: u32, w: u32, h: u32, owner: usize) UserOpenResult {
    if (!armed_global) return .invalid;
    if (w == 0 or h == 0 or w > user_buf_w or h > user_buf_h) return .invalid;
    if (x >= virtio_gpu.fb_width or y >= virtio_gpu.fb_height) return .invalid;
    if (w > virtio_gpu.fb_width - x or h > virtio_gpu.fb_height - y) return .invalid;
    var i: usize = 0;
    while (i < user_windows_max) : (i += 1) {
        const id = user_window_id_base + @as(u8, @intCast(i));
        var used = false;
        var j: usize = 0;
        while (j < win_count) : (j += 1) {
            if (windows[j].id == id) {
                used = true;
                break;
            }
        }
        if (used) continue;
        @memset(&user_bufs[i], 0);
        windows[win_count] = .{
            .id = id,
            .title = "user",
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .kind = .user,
            .visible = true,
            .dirty = true,
            .owner = owner,
        };
        win_count += 1;
        focused_id = id;
        return .{ .opened = id };
    }
    return .full;
}

/// Fill a rect in the user window's back-buffer (local coordinates,
/// 0..window w/h) and mark it dirty. Returns false for an unknown id or a
/// rect outside the window bounds.
pub fn user_fill(id: u8, x: u32, y: u32, w: u32, h: u32, rgb: u32) bool {
    const win = find_user_window(id) orelse return false;
    if (w == 0 or h == 0) return false;
    if (x >= win.w or y >= win.h) return false;
    if (w > win.w - x or h > win.h - y) return false;
    const idx = id - user_window_id_base;
    if (idx >= user_windows_max) return false;
    fill_rect(@ptrCast(&user_bufs[idx]), user_buf_w * 4, x, y, w, h, rgb);
    win.dirty = true;
    return true;
}

/// Mark a user window dirty so the compositor blits its back-buffer on the
/// next idle-loop pass (the deferred-present discipline — the syscall never
/// touches the gpu directly; the shell idle loop's `drain` composites).
/// Returns false for an unknown id.
pub fn user_present(id: u8) bool {
    const win = find_user_window(id) orelse return false;
    win.dirty = true;
    return true;
}

/// Move a user window's top-left corner to (x, y), CLAMPED so the whole
/// window stays inside the scanout (a window is never allowed off-screen —
/// the honest bound). Marks the moved window dirty and the terminal dirty
/// (its old rect is revealed) so the next composite repaints over the old
/// position and blits at the new one. Returns false for an unknown id, a
/// non-user window (the terminal + clock are fixed), or an unarmed manager.
/// The EL0 `sys_win_move` enforces ownership on top of this.
pub fn user_move(id: u8, x: u32, y: u32) bool {
    const win = find_user_window(id) orelse return false;
    const max_x = virtio_gpu.fb_width - win.w;
    const max_y = virtio_gpu.fb_height - win.h;
    win.x = @min(x, max_x);
    win.y = @min(y, max_y);
    win.dirty = true;
    // Reveal whatever sat under the window's old rect (the terminal repaint).
    _ = mark_dirty(0);
    return true;
}

/// Raise a user window to the top of the z-order (the EL0 `sys_win_raise`
/// primitive — ownership is enforced at the syscall layer). Focus is
/// unchanged (tracked by id, the G5 discipline). Returns false for an
/// unknown id or a non-user window (the terminal + clock are fixed).
pub fn user_raise(id: u8) bool {
    if (find_user_window_index(id) == null) return false;
    return raise(id);
}

/// Close (release) a user window: remove it from the registry (the z-order
/// stays compact — later windows shift down), fall the focus back to the
/// terminal when the closed window held it, and mark the fixed windows
/// (terminal + clock) dirty so the next composite repaints over the
/// released window's pixels. Returns false for an unknown id or a non-user
/// window (the terminal + clock are fixed and never closable). The
/// back-buffer slot is freed for the next `user_open` (which re-clears it).
/// This is the PRIVILEGED release path (the monitor's `win close <n>`); the
/// EL0 `sys_win_close` enforces ownership on top of it.
pub fn user_close(id: u8) bool {
    const idx = find_user_window_index(id) orelse return false;
    remove_user_at(idx);
    return true;
}

/// The owner of a user window, or null for an unknown id / non-user window
/// (the syscall layer compares this to the caller to enforce ownership).
pub fn user_owner(id: u8) ?usize {
    const win = find_user_window(id) orelse return null;
    return win.owner;
}

/// Card G6 (claim 0487) follow-on (slot 18): the geometry of a user window
/// — the `sys_win_get` result. The syscall layer marshals this into the
/// caller's buffer (four u32 LE words) through uaccess so an EL0 program
/// can read its window's rect back after a CLAMPED move (the move is
/// silent; this is the read-back seam).
pub const WinRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// The rect of a user window, or null for an unknown id / non-user window
/// (the terminal + clock are fixed and never match).
pub fn user_rect(id: u8) ?WinRect {
    const win = find_user_window(id) orelse return null;
    return .{ .x = win.x, .y = win.y, .w = win.w, .h = win.h };
}

/// Card G6 (claim 0487) follow-on (slot 19): the FULL state of a user
/// window — the `sys_win_query` result. The rect (like `user_rect`) plus the
/// z-order rank (`z` = the registry index, 0 = bottom — the SAME number the
/// monitor's `win` report prints), and the focus/visible/dirty flags (1/0).
/// The syscall layer marshals this into the caller's buffer (eight u32 LE
/// words) so an EL0 program can introspect its window end to end.
pub const WinQuery = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    z: u32,
    focused: u32,
    visible: u32,
    dirty: u32,
};

/// The full state of a user window, or null for an unknown id / non-user
/// window. `z` is the registry index (0 = bottom of the z-order).
pub fn user_query(id: u8) ?WinQuery {
    const idx = find_user_window_index(id) orelse return null;
    const win = windows[idx];
    return .{
        .x = win.x,
        .y = win.y,
        .w = win.w,
        .h = win.h,
        .z = @intCast(idx),
        .focused = if (focused_id == id) 1 else 0,
        .visible = if (win.visible) 1 else 0,
        .dirty = if (win.dirty) 1 else 0,
    };
}

/// Card G6 (claim 0487) follow-on (slot 20): set a user window's visibility
/// (hide/show). Returns false for an unknown id or a non-user window (the
/// terminal + clock are fixed and never hideable). Hiding marks the window
/// hidden + dirty (inert while hidden) and marks the terminal dirty so the
/// next composite repaints over the hidden window's pixels; showing marks the
/// window dirty so it reappears. Idempotent (same-flag calls are a no-op — no
/// dirty churn). The EL0 `sys_win_set_visible` enforces ownership on top of
/// this; focus is unchanged (tracked by id, the G5 discipline).
pub fn user_set_visible(id: u8, visible: bool) bool {
    const win = find_user_window(id) orelse return false;
    if (win.visible == visible) return true;
    win.visible = visible;
    win.dirty = true;
    if (!visible) _ = mark_dirty(0); // reveal whatever sat under the hidden window
    return true;
}

/// Auto-close every user window owned by the process `owner` (the exit
/// path's teardown seam — `scheduler.exit_current` calls this with the
/// exited process's pid). Returns how many windows were released. Pure
/// BSS writes (safe in the exception context the exit path runs in).
pub fn close_owner(owner: usize) usize {
    var closed: usize = 0;
    while (true) {
        var idx: ?usize = null;
        var i: usize = 0;
        while (i < win_count) : (i += 1) {
            if (windows[i].kind == .user and windows[i].owner == owner) {
                idx = i;
                break;
            }
        }
        const found = idx orelse break;
        remove_user_at(found);
        closed += 1;
    }
    return closed;
}

/// Remove the user window at registry index `idx` (the shared release
/// primitive behind `user_close` and `close_owner`): compact the z-order,
/// fall the focus back to the terminal when the removed window held it,
/// and mark the fixed windows dirty so the next composite repaints over
/// the released window's pixels.
fn remove_user_at(idx: usize) void {
    const removed_id = windows[idx].id;
    var j = idx;
    while (j + 1 < win_count) : (j += 1) windows[j] = windows[j + 1];
    win_count -= 1;
    if (focused_id == removed_id) focused_id = 0; // fall back to the terminal
    // Reveal whatever sat under the released window.
    _ = mark_dirty(0);
    _ = mark_dirty(1);
}

/// Card U5 (claim 0935, ADR 0008 D4): cycle focus to the next visible
/// window in z-order (wrapping). Returns the newly focused id, or null
/// when no window is cyclable. A focus change repaints the whole scene
/// (mark_dirty(0) — the compositor repaints everything above the lowest
/// dirty window, so the ring moves correctly under any overlay).
pub fn cycle_focus() ?u8 {
    if (win_count == 0) return null;
    const start = focused_index() orelse 0;
    var i: usize = 1;
    while (i <= win_count) : (i += 1) {
        const idx = (start + i) % win_count;
        if (!windows[idx].visible) continue;
        focused_id = windows[idx].id;
        _ = mark_dirty(0);
        return focused_id;
    }
    return null;
}

/// Card U4 (claim 4993): the pointer tick — consume the pointer state from
/// the input path (motion + click edges). Returns the newly focused window
/// id when a CLICK landed on a window (D4: click = focus + raise), null
/// otherwise. Called from the shell idle loop; a no-op when the input path
/// is unarmed (the default VM).
pub fn pointer_tick(st: input.PointerState, click: ?input.Click) ?u8 {
    if (!armed_global) return null;
    if (st.valid) {
        const nx = map_pointer_axis(st.x, virtio_gpu.fb_width);
        const ny = map_pointer_axis(st.y, virtio_gpu.fb_height);
        if (!cursor_shown or nx != cursor_x or ny != cursor_y) {
            cursor_x = nx;
            cursor_y = ny;
            cursor_shown = true;
            _ = mark_dirty(0); // the cursor moves over a full repaint
        }
    }
    if (click != null) {
        if (focus_at(cursor_x, cursor_y)) {
            const id = focused_id;
            _ = raise(id);
            _ = mark_dirty(0);
            return id;
        }
    }
    return null;
}

/// HID absolute pointers report 0..32767 logical; map onto the framebuffer
/// axis. Pure — host-testable.
pub fn map_pointer_axis(v: u16, span: u32) u32 {
    const scaled = (@as(u32, v) * span + 16384) / 32768;
    return if (scaled >= span) span - 1 else scaled;
}

/// Card U4: the cursor's current framebuffer cell (for reports + tests).
pub fn cursor_pos() ?struct { x: u32, y: u32 } {
    if (!cursor_shown) return null;
    return .{ .x = cursor_x, .y = cursor_y };
}

// ---------------------------------------------------------------------------
// Pixel helpers (pure — host-testable)
// ---------------------------------------------------------------------------

fn put_px(buf: [*]u8, stride: usize, x: usize, y: usize, rgb: u32) void {
    const off = y * stride + x * 4;
    buf[off] = @truncate(rgb & 0xff); // B
    buf[off + 1] = @truncate((rgb >> 8) & 0xff); // G
    buf[off + 2] = @truncate((rgb >> 16) & 0xff); // R
    buf[off + 3] = 0xff; // X — opaque (the claim-6053 lesson)
}

fn fill_rect(buf: [*]u8, stride: usize, x0: usize, y0: usize, w: usize, h: usize, rgb: u32) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) put_px(buf, stride, x0 + x, y0 + y, rgb);
    }
}

/// Draw one 8x8 glyph at (x0, y0) in the given 0xRRGGBB color. Non-printable
/// bytes are skipped (no invented pixels).
fn draw_glyph(buf: [*]u8, stride: usize, x0: usize, y0: usize, c: u8, rgb: u32) void {
    if (c < 0x20 or c > 0x7e) return;
    const glyph = font.glyphs[c - 0x20];
    var gy: usize = 0;
    while (gy < 8) : (gy += 1) {
        var bits = glyph[gy];
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            if ((bits & 0x80) != 0) put_px(buf, stride, x0 + gx, y0 + gy, rgb);
            bits <<= 1;
        }
    }
}

fn draw_string(buf: [*]u8, stride: usize, x0: usize, y0: usize, s: []const u8, rgb: u32) void {
    for (s, 0..) |c, i| draw_glyph(buf, stride, x0 + i * 8, y0, c, rgb);
}

/// Minimal unsigned-decimal formatting (no heap, no failure modes) — the
/// clock's dynamic text. Returns the filled slice.
pub fn fmt_decimal(buf: []u8, v: u64) []const u8 {
    if (buf.len == 0) return "";
    if (v == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0 and n < tmp.len) : (n += 1) {
        tmp[n] = @as(u8, @intCast(x % 10)) + '0';
        x /= 10;
    }
    const out = @min(n, buf.len);
    var i: usize = 0;
    while (i < out) : (i += 1) buf[i] = tmp[n - 1 - i];
    return buf[0..out];
}

/// Copy a B8G8R8X8 rect from `src` (stride `src_stride` bytes) into `dst`
/// (stride `dst_stride` bytes) at (dx, dy). Pure — host-testable.
pub fn blit_rect(
    dst: [*]u8,
    dst_stride: usize,
    src: [*]const u8,
    src_stride: usize,
    dx: usize,
    dy: usize,
    w: usize,
    h: usize,
) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const drow = dst + (dy + y) * dst_stride + dx * 4;
        const srow = src + y * src_stride;
        @memcpy(drow[0 .. w * 4], srow[0 .. w * 4]);
    }
}

// ---------------------------------------------------------------------------
// Window painting
// ---------------------------------------------------------------------------

fn fb_canvas() fbtext.Canvas {
    return .{
        .base = @ptrCast(&virtio_gpu.gpu_fb),
        .width = virtio_gpu.fb_width,
        .height = virtio_gpu.fb_height,
        .stride = virtio_gpu.fb_width * 4,
    };
}

/// Render the clock window's content into a buffer. `focused` selects the
/// focus-status line. Pure — host-testable with an injectable buffer.
pub fn render_clock_content(buf: [*]u8, stride: usize, w: usize, h: usize, ticks: u64, focused: bool) void {
    // Background + border (2 px), then the amber title bar.
    fill_rect(buf, stride, 0, 0, w, h, clock_bg_rgb);
    fill_rect(buf, stride, 0, 0, w, 2, clock_border_rgb);
    fill_rect(buf, stride, 0, h - 2, w, 2, clock_border_rgb);
    fill_rect(buf, stride, 0, 0, 2, h, clock_border_rgb);
    fill_rect(buf, stride, w - 2, 0, 2, h, clock_border_rgb);
    fill_rect(buf, stride, 2, 2, w - 4, 16, clock_title_bg_rgb);

    draw_string(buf, stride, 8, 6, "clock", clock_title_fg_rgb);

    var nb: [24]u8 = undefined;
    // Body lines (8 px grid, origin 8 px inside the border).
    draw_string(buf, stride, 8, 26, "DRIVING AWARD", clock_accent_rgb);
    draw_string(buf, stride, 8, 42, "ticks=", clock_fg_rgb);
    draw_string(buf, stride, 8 + 6 * 8, 42, fmt_decimal(&nb, ticks), clock_fg_rgb);
    draw_string(buf, stride, 8, 58, if (focused) "focus=clock" else "focus=roadpops", clock_fg_rgb);
    draw_string(buf, stride, 8, 74, "windows=2", clock_fg_rgb);
}

/// Paint one window into the framebuffer. The terminal renders the shared
/// text layer straight into the scanout framebuffer; the clock renders its
/// back-buffer and blits it over the terminal.
fn paint(w: *Window) void {
    switch (w.kind) {
        .terminal => fbtext.render(fb_canvas()),
        .clock => {
            render_clock_content(
                @ptrCast(&clock_buf),
                clock_w * 4,
                clock_w,
                clock_h,
                if (clock_has_tick) clock_shown_tick else 0,
                focused_id == w.id,
            );
            blit_rect(
                @ptrCast(&virtio_gpu.gpu_fb),
                virtio_gpu.fb_width * 4,
                @ptrCast(&clock_buf),
                clock_w * 4,
                w.x,
                w.y,
                w.w,
                w.h,
            );
        },
        .user => {
            const idx = w.id - user_window_id_base;
            if (idx >= user_windows_max) return;
            blit_rect(
                @ptrCast(&virtio_gpu.gpu_fb),
                virtio_gpu.fb_width * 4,
                @ptrCast(&user_bufs[idx]),
                user_buf_w * 4,
                w.x,
                w.y,
                w.w,
                w.h,
            );
        },
    }
}

/// The repaint plan: the index of the LOWEST dirty visible window, or null
/// when the scene is clean. Pure — host-testable.
fn repaint_start() ?usize {
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        if (windows[i].visible and windows[i].dirty) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The compositor
// ---------------------------------------------------------------------------

/// Composite: repaint every visible window from the lowest dirty one UP (so
/// the clock is always re-blitted over a freshly repainted terminal), then
/// push one transfer + flush. Returns the flush result; `.ok` with no work
/// when the scene is clean (dirty-rect: unchanged windows are never
/// repainted).
pub fn composite() virtio_gpu.CmdResult {
    if (!armed_global) return .not_ready;
    const start = repaint_start() orelse return .ok;
    var i = start;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (!w.visible) continue;
        paint(w);
        w.dirty = false;
    }
    draw_chrome();
    if (!virtio_gpu.gpu_ready) return .not_ready;
    presents += 1;
    if (virtio_gpu.gpu_transfer() != .ok) return .timeout;
    return virtio_gpu.gpu_flush();
}

/// Card U5/U4: the chrome pass, drawn on the framebuffer AFTER the window
/// paints and BEFORE the transfer — user title bars, the focus ring on the
/// focused window, and the pointer cursor. Chrome never touches a window's
/// back-buffer (user buffers stay EL0-owned).
fn draw_chrome() void {
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const stride = virtio_gpu.fb_width * 4;
    const wspan = virtio_gpu.fb_width;
    const hspan = virtio_gpu.fb_height;
    var i: usize = 0;
    while (i < win_count) : (i += 1) {
        const w = &windows[i];
        if (w.kind != .user or !w.visible) continue;
        // Title bar: "win<id> pid=<pid>" (the owning pid when known).
        fill_rect(fb, stride, w.x, w.y, w.w, user_title_h, user_title_bg_rgb);
        var tb: [24]u8 = undefined;
        var n: usize = 0;
        const label = "win";
        @memcpy(tb[0..3], label);
        n = 3;
        const idstr = fmt_decimal(tb[n..], w.id);
        @memcpy(tb[n..][0..idstr.len], idstr);
        n += idstr.len;
        if (w.owner) |pid| {
            const ps = " pid=";
            @memcpy(tb[n..][0..ps.len], ps);
            n += ps.len;
            const pids = fmt_decimal(tb[n..], pid);
            @memcpy(tb[n..][0..pids.len], pids);
            n += pids.len;
        }
        draw_string(fb, stride, w.x + 4, w.y + 4, tb[0..n], user_title_fg_rgb);
    }
    // The focus ring: on the focused window's rect (D4 — focus is always
    // visible). 0xff = none (no ring).
    if (focused_id != 0xff) {
        var idx: usize = 0;
        while (idx < win_count) : (idx += 1) {
            if (windows[idx].id != focused_id) continue;
            const w = &windows[idx];
            const rx: usize = w.x;
            const ry: usize = w.y;
            const rw: usize = if (w.w > wspan) wspan else w.w;
            const rh: usize = if (w.h > hspan) hspan else w.h;
            fill_rect(fb, stride, rx, ry, rw, focus_ring_w, focus_ring_rgb);
            fill_rect(fb, stride, rx, ry + rh - focus_ring_w, rw, focus_ring_w, focus_ring_rgb);
            fill_rect(fb, stride, rx, ry, focus_ring_w, rh, focus_ring_rgb);
            fill_rect(fb, stride, rx + rw - focus_ring_w, ry, focus_ring_w, rh, focus_ring_rgb);
            break;
        }
    }
    // The pointer cursor (card U4) — topmost, only once a report arrived.
    if (cursor_shown) {
        const cx: usize = cursor_x;
        const cy: usize = cursor_y;
        const cw = if (cx + cursor_w > wspan) wspan - cx else cursor_w;
        const ch = if (cy + cursor_h > hspan) hspan - cy else cursor_h;
        fill_rect(fb, stride, cx, cy, cw, ch, cursor_rgb);
    }
}

/// Refresh the clock from the 1 Hz generic timer and composite any dirty
/// windows. The shell idle loop is the drain site (the card-3d pattern).
pub fn drain(ticks: u64) virtio_gpu.CmdResult {
    if (!armed_global) return .not_ready;
    if (!clock_has_tick or ticks != clock_shown_tick) {
        clock_has_tick = true;
        clock_shown_tick = ticks;
        _ = mark_dirty(1);
    }
    return composite();
}

// ---------------------------------------------------------------------------
// Host tests — the pure contracts (hit-test, z-order, focus, repaint plan,
// clock rendering, blit)
// ---------------------------------------------------------------------------

test "driving_award: arm registers the terminal (window 0) and the clock (window 1)" {
    arm();
    try std.testing.expectEqual(@as(usize, 2), win_count);
    try std.testing.expectEqual(@as(u8, 0), windows[0].id);
    try std.testing.expectEqual(Kind.terminal, windows[0].kind);
    try std.testing.expectEqual(@as(u8, 1), windows[1].id);
    try std.testing.expectEqual(Kind.clock, windows[1].kind);
    try std.testing.expectEqual(@as(u8, 0), focused_id);
    try std.testing.expect(terminal_focused());
    // The terminal is full-screen; the clock is the top-right overlay.
    try std.testing.expectEqual(@as(u32, 0), windows[0].x);
    try std.testing.expectEqual(@as(u32, 0), windows[0].y);
    try std.testing.expectEqual(virtio_gpu.fb_width, windows[0].w);
    try std.testing.expectEqual(virtio_gpu.fb_height, windows[0].h);
    try std.testing.expectEqual(@as(u32, clock_x), windows[1].x);
    try std.testing.expectEqual(@as(u32, clock_y), windows[1].y);
}

test "driving_award: hit_test returns the topmost window containing the point" {
    arm();
    // Inside the clock overlay: the clock (window 1) is on top.
    try std.testing.expectEqual(@as(?u8, 1), hit_test(clock_x + 10, clock_y + 10));
    // Outside the clock, inside the terminal: the terminal.
    try std.testing.expectEqual(@as(?u8, 0), hit_test(100, 400));
    try std.testing.expectEqual(@as(?u8, 0), hit_test(clock_x - 1, clock_y + 10));
    // Outside every window.
    try std.testing.expectEqual(@as(?u8, null), hit_test(virtio_gpu.fb_width, virtio_gpu.fb_height));
}

test "driving_award: raise moves a window to the top and hit_test follows" {
    arm();
    // Raise the terminal above the clock: now the full-screen terminal
    // covers the clock everywhere.
    try std.testing.expect(raise(0));
    try std.testing.expectEqual(@as(u8, 0), windows[win_count - 1].id);
    try std.testing.expectEqual(@as(?u8, 0), hit_test(clock_x + 10, clock_y + 10));
    // Focus is unchanged by raise (tracked by id).
    try std.testing.expectEqual(@as(u8, 0), focused_id);
}

test "driving_award: focus + focus_at switch the focused window" {
    arm();
    try std.testing.expect(focus(1));
    try std.testing.expectEqual(@as(u8, 1), focused_id);
    try std.testing.expect(!terminal_focused());
    // A point in the clock focuses the clock; a point below focuses the
    // terminal.
    try std.testing.expect(focus_at(clock_x + 5, clock_y + 5));
    try std.testing.expectEqual(@as(u8, 1), focused_id);
    try std.testing.expect(focus_at(50, 400));
    try std.testing.expectEqual(@as(u8, 0), focused_id);
    try std.testing.expect(terminal_focused());
    // Unknown ids are refused.
    try std.testing.expect(!focus(99));
}

test "driving_award: repaint_start is the lowest dirty visible window" {
    arm();
    // Both dirty at arm: the lowest is window 0.
    try std.testing.expectEqual(@as(?usize, 0), repaint_start());
    // Clean everything.
    var i: usize = 0;
    while (i < win_count) : (i += 1) windows[i].dirty = false;
    try std.testing.expectEqual(@as(?usize, null), repaint_start());
    // Only the clock dirty: repaint starts at window 1 (the terminal is
    // untouched — the dirty-rect contract).
    windows[1].dirty = true;
    try std.testing.expectEqual(@as(?usize, 1), repaint_start());
    // A hidden dirty window is skipped.
    windows[0].dirty = true;
    windows[0].visible = false;
    try std.testing.expectEqual(@as(?usize, 1), repaint_start());
}

test "driving_award: mark_dirty targets a window by id" {
    arm();
    var i: usize = 0;
    while (i < win_count) : (i += 1) windows[i].dirty = false;
    try std.testing.expect(mark_dirty(1));
    try std.testing.expect(!windows[0].dirty);
    try std.testing.expect(windows[1].dirty);
    try std.testing.expect(!mark_dirty(9));
}

test "driving_award: fmt_decimal formats unsigned values without leading zeros" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", fmt_decimal(&buf, 0));
    try std.testing.expectEqualStrings("1", fmt_decimal(&buf, 1));
    try std.testing.expectEqualStrings("42", fmt_decimal(&buf, 42));
    try std.testing.expectEqualStrings("123456789", fmt_decimal(&buf, 123456789));
}

test "driving_award: render_clock_content paints the title bar and body colors" {
    const W = 304;
    const H = 192;
    var buf: [W * H * 4]u8 = undefined;
    @memset(&buf, 0);
    render_clock_content(&buf, W * 4, W, H, 42, false);
    // Title bar (inside the border): amber.
    try std.testing.expectEqual(@as(u8, 0x00), buf[(6 * W + 8) * 4 + 0]); // B of amber 0xb58900
    try std.testing.expectEqual(@as(u8, 0x89), buf[(6 * W + 8) * 4 + 1]); // G
    try std.testing.expectEqual(@as(u8, 0xb5), buf[(6 * W + 8) * 4 + 2]); // R
    try std.testing.expectEqual(@as(u8, 0xff), buf[(6 * W + 8) * 4 + 3]); // opaque
    // Border: gray-blue (top-left pixel is border).
    try std.testing.expectEqual(@as(u8, 0xaa), buf[0 + 0]); // B of 0x8899aa
    // Body background: navy (a pixel inside, away from text/border).
    try std.testing.expectEqual(@as(u8, 0x2e), buf[(170 * W + 300) * 4 + 0]); // B of 0x0a1a2e
    try std.testing.expectEqual(@as(u8, 0x1a), buf[(170 * W + 300) * 4 + 1]); // G
}

test "driving_award: blit_rect copies a sub-rect at the destination offset" {
    const SW = 4;
    const DW = 10;
    var src: [SW * SW * 4]u8 = undefined;
    var dst: [DW * DW * 4]u8 = undefined;
    @memset(&src, 0);
    @memset(&dst, 0);
    // Source pixel (1,1) = green.
    src[(1 * SW + 1) * 4 + 0] = 0x00; // B
    src[(1 * SW + 1) * 4 + 1] = 0xff; // G
    src[(1 * SW + 1) * 4 + 2] = 0x00; // R
    src[(1 * SW + 1) * 4 + 3] = 0xff;
    blit_rect(&dst, DW * 4, &src, SW * 4, 3, 3, SW, SW);
    try std.testing.expectEqual(@as(u8, 0xff), dst[((3 + 1) * DW + (3 + 1)) * 4 + 1]);
    // A pixel outside the blit region is still zero.
    try std.testing.expectEqual(@as(u8, 0), dst[(0 * DW + 0) * 4 + 0]);
}

test "driving_award: user_open/fill/present round-trips a bounded user window" {
    arm();
    // Open window 2 at (64, 64) 256x192 — the first free user slot.
    const r = user_open(64, 64, 256, 192, 7);
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, r);
    try std.testing.expectEqual(@as(usize, 3), win_count);
    try std.testing.expectEqual(@as(u8, 2), windows[2].id);
    try std.testing.expectEqual(Kind.user, windows[2].kind);
    try std.testing.expectEqual(@as(?usize, 7), user_owner(2));
    try std.testing.expect(user_owner(1) == null); // the clock is unowned
    // The new window is on top and focused.
    try std.testing.expectEqual(@as(u8, 2), focused_id);
    try std.testing.expect(!terminal_focused());
    try std.testing.expectEqual(@as(?u8, 2), hit_test(64 + 10, 64 + 10));
    // Fill a rect: the back-buffer pixel carries the B8G8R8X8 rgb.
    try std.testing.expect(user_fill(2, 8, 8, 48, 48, 0xff0000));
    try std.testing.expectEqual(@as(u8, 0x00), user_bufs[0][(8 * user_buf_w + 8) * 4 + 0]); // B
    try std.testing.expectEqual(@as(u8, 0x00), user_bufs[0][(8 * user_buf_w + 8) * 4 + 1]); // G
    try std.testing.expectEqual(@as(u8, 0xff), user_bufs[0][(8 * user_buf_w + 8) * 4 + 2]); // R
    try std.testing.expectEqual(@as(u8, 0xff), user_bufs[0][(8 * user_buf_w + 8) * 4 + 3]); // opaque
    // The unfilled corner is zero (the back-buffer starts cleared).
    try std.testing.expectEqual(@as(u8, 0), user_bufs[0][(100 * user_buf_w + 200) * 4 + 0]);
    try std.testing.expect(user_present(2));
    try std.testing.expect(windows[2].dirty);
}

test "driving_award: user_open bounds and the second slot fill the registry" {
    arm();
    // Invalid geometry: zero size, oversize back-buffer, off-scanout.
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 0, 10, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 257, 10, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(0, 0, 10, 193, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(virtio_gpu.fb_width, 0, 10, 10, 7));
    try std.testing.expectEqual(UserOpenResult.invalid, user_open(virtio_gpu.fb_width - 4, 0, 10, 10, 7));
    // Two opens fill both slots; the third is ENOSPC-shaped (.full).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 256, 192, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 256, 192, 8));
    try std.testing.expectEqual(UserOpenResult.full, user_open(0, 0, 10, 10, 9));
    try std.testing.expectEqual(@as(usize, 4), win_count);
    try std.testing.expectEqual(@as(?usize, 7), user_owner(2));
    try std.testing.expectEqual(@as(?usize, 8), user_owner(3));
}

test "driving_award: user_fill refuses unknown ids and out-of-bounds rects" {
    arm();
    _ = user_open(64, 64, 256, 192, 7);
    try std.testing.expect(!user_fill(0, 0, 0, 10, 10, 0xffffff)); // terminal is not a user window
    try std.testing.expect(!user_fill(1, 0, 0, 10, 10, 0xffffff)); // clock is not a user window
    try std.testing.expect(!user_fill(9, 0, 0, 10, 10, 0xffffff)); // unknown
    try std.testing.expect(!user_fill(2, 0, 0, 0, 10, 0xffffff)); // zero size
    try std.testing.expect(!user_fill(2, 255, 191, 2, 2, 0xffffff)); // past the window edge
    try std.testing.expect(!user_present(3)); // never opened
    try std.testing.expect(!user_present(0));
    try std.testing.expect(!user_present(1));
}

test "driving_award: user_close releases a user window and frees its slot" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 256, 192, 7));
    try std.testing.expectEqual(@as(usize, 3), win_count);
    try std.testing.expectEqual(@as(u8, 2), focused_id);
    // The terminal and the clock are fixed — never closable.
    try std.testing.expect(!user_close(0));
    try std.testing.expect(!user_close(1));
    try std.testing.expect(!user_close(9));
    // Close window 2: count decrements, focus falls back to the terminal,
    // and the slot is reusable by the next open.
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(@as(usize, 2), win_count);
    try std.testing.expectEqual(@as(u8, 0), focused_id);
    try std.testing.expect(terminal_focused());
    try std.testing.expect(find_user_window(2) == null);
    // Re-opening reuses id 2 (the freed slot — the "release, not leak" proof).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 256, 192, 7));
    try std.testing.expectEqual(@as(usize, 3), win_count);
    // Two opens, one close, one re-open: slot 3 is still free for a second
    // window, and closing BOTH user windows returns the registry to the
    // two fixed windows.
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 256, 192, 8));
    try std.testing.expect(user_close(3));
    try std.testing.expect(user_close(2));
    try std.testing.expectEqual(@as(usize, 2), win_count);
    try std.testing.expectEqual(@as(u8, 0), focused_id);
}

test "driving_award: user_move clamps on-scanout and user_raise reorders z" {
    arm();
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 256, 192, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 256, 192, 8));
    // The terminal + clock are fixed — never movable or raisable.
    try std.testing.expect(!user_move(0, 10, 10));
    try std.testing.expect(!user_move(1, 10, 10));
    try std.testing.expect(!user_raise(0));
    try std.testing.expect(!user_raise(1));
    try std.testing.expect(!user_move(9, 0, 0));
    try std.testing.expect(!user_raise(9));
    // Move window 2 to a new in-bounds position overlapping window 3 and
    // confirm the rect.
    try std.testing.expect(user_move(2, 100, 50));
    try std.testing.expectEqual(@as(u32, 100), find_user_window(2).?.x);
    try std.testing.expectEqual(@as(u32, 50), find_user_window(2).?.y);
    try std.testing.expect(find_user_window(2).?.dirty);
    // Z-order: (321, 65) is inside BOTH windows; window 3 (opened last) is
    // on top. Raising window 2 puts it above window 3, without changing the
    // focus (tracked by id, stays 3).
    try std.testing.expectEqual(@as(u8, 3), hit_test(321, 65).?);
    try std.testing.expect(user_raise(2));
    try std.testing.expectEqual(@as(u8, 2), hit_test(321, 65).?);
    try std.testing.expectEqual(@as(u8, 3), focused_id);
    // The clamp keeps the window fully on-scanout (bottom-right corner).
    try std.testing.expect(user_move(2, 1200, 700));
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_width - 256), find_user_window(2).?.x);
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_height - 192), find_user_window(2).?.y);
}

test "driving_award: user_rect reads back the clamped geometry (the sys_win_get seam)" {
    arm();
    _ = user_open(64, 64, 256, 192, 7);
    // The fixed windows are never user windows -> null.
    try std.testing.expect(user_rect(0) == null);
    try std.testing.expect(user_rect(1) == null);
    try std.testing.expect(user_rect(9) == null);
    // The open rect.
    var r = user_rect(2).?;
    try std.testing.expectEqual(@as(u32, 64), r.x);
    try std.testing.expectEqual(@as(u32, 64), r.y);
    try std.testing.expectEqual(@as(u32, 256), r.w);
    try std.testing.expectEqual(@as(u32, 192), r.h);
    // After a CLAMPED move the read-back reports the clamped position — the
    // exact seam the EL0 `sys_win_get` exposes (the move is silent).
    try std.testing.expect(user_move(2, 1200, 700));
    r = user_rect(2).?;
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_width - 256), r.x);
    try std.testing.expectEqual(@as(u32, virtio_gpu.fb_height - 192), r.y);
    try std.testing.expectEqual(@as(u32, 256), r.w);
    try std.testing.expectEqual(@as(u32, 192), r.h);
}

test "driving_award: user_query reports the full window state (z-order + focus + flags)" {
    arm();
    try std.testing.expect(user_query(0) == null);
    try std.testing.expect(user_query(1) == null);
    try std.testing.expect(user_query(9) == null);
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 256, 192, 7));
    // The single user window sits at the TOP of the z-order (registry index
    // 2, above the terminal 0 + clock 1), holds focus, is visible, and is
    // dirty from the open (the compositor has not run in a host test).
    var q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 64), q.x);
    try std.testing.expectEqual(@as(u32, 64), q.y);
    try std.testing.expectEqual(@as(u32, 256), q.w);
    try std.testing.expectEqual(@as(u32, 192), q.h);
    try std.testing.expectEqual(@as(u32, 2), q.z);
    try std.testing.expectEqual(@as(u32, 1), q.focused);
    try std.testing.expectEqual(@as(u32, 1), q.visible);
    try std.testing.expectEqual(@as(u32, 1), q.dirty);
    // A second window takes focus (id 3) and the z-order: window 2 drops to
    // rank 1 (bottom of the two user windows), unfocused.
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 256, 192, 8));
    q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 2), q.z);
    try std.testing.expectEqual(@as(u32, 0), q.focused);
    q = user_query(3).?;
    try std.testing.expectEqual(@as(u32, 3), q.z);
    try std.testing.expectEqual(@as(u32, 1), q.focused);
    // Raising window 2 moves it to the top (rank 3) without changing focus
    // (still id 3).
    try std.testing.expect(user_raise(2));
    q = user_query(2).?;
    try std.testing.expectEqual(@as(u32, 3), q.z);
    try std.testing.expectEqual(@as(u32, 0), q.focused);
}

test "driving_award: user_set_visible hides and shows a user window (fixed windows refused)" {
    arm();
    _ = user_open(64, 64, 256, 192, 7);
    // The terminal + clock are fixed — never hideable.
    try std.testing.expect(!user_set_visible(0, false));
    try std.testing.expect(!user_set_visible(1, false));
    try std.testing.expect(!user_set_visible(9, false));
    // Hide window 2: its visible flag flips, it stays in the registry, and
    // the terminal is marked dirty (the reveal repaint).
    try std.testing.expect(user_set_visible(2, false));
    try std.testing.expectEqual(@as(u32, 0), user_query(2).?.visible);
    try std.testing.expect(find_user_window(2) != null);
    try std.testing.expect(windows[0].dirty);
    // The hide is idempotent (a second hide is a no-op — no dirty churn).
    windows[0].dirty = false;
    try std.testing.expect(user_set_visible(2, false));
    try std.testing.expectEqual(@as(u32, 0), user_query(2).?.visible);
    try std.testing.expect(!windows[0].dirty);
    // Show it again: the window reappears (visible=1, dirty for the blit).
    try std.testing.expect(user_set_visible(2, true));
    try std.testing.expectEqual(@as(u32, 1), user_query(2).?.visible);
    try std.testing.expect(find_user_window(2).?.dirty);
}

test "driving_award: close_owner auto-closes exactly the owning process's windows" {
    arm();
    // Process 7 opens both slots; process 8 owns nothing yet.
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 256, 192, 7));
    try std.testing.expectEqual(UserOpenResult{ .opened = 3 }, user_open(320, 64, 256, 192, 7));
    try std.testing.expectEqual(@as(usize, 4), win_count);
    try std.testing.expectEqual(@as(u8, 3), focused_id);
    // Closing a process with no windows is a no-op (returns 0).
    try std.testing.expectEqual(@as(usize, 0), close_owner(8));
    try std.testing.expectEqual(@as(usize, 4), win_count);
    // Closing process 7 releases BOTH of its windows and falls the focus
    // back to the terminal.
    try std.testing.expectEqual(@as(usize, 2), close_owner(7));
    try std.testing.expectEqual(@as(usize, 2), win_count);
    try std.testing.expectEqual(@as(u8, 0), focused_id);
    try std.testing.expect(find_user_window(2) == null);
    try std.testing.expect(find_user_window(3) == null);
    // The slots are free again (id 2 re-opens for a different owner).
    try std.testing.expectEqual(UserOpenResult{ .opened = 2 }, user_open(64, 64, 256, 192, 9));
    try std.testing.expectEqual(@as(?usize, 9), user_owner(2));
}

// ---------------------------------------------------------------------------
// Card U4/U5 host tests (claims 0935/4993)
// ---------------------------------------------------------------------------

test "driving_award: card U5 — cycle_focus walks the z-order and wraps" {
    arm();
    try std.testing.expectEqual(@as(?u8, 1), cycle_focus()); // 0 -> 1
    try std.testing.expectEqual(@as(?u8, 0), cycle_focus()); // 1 -> 0 (wrap)
    try std.testing.expectEqual(@as(?u8, 1), cycle_focus());
}

test "driving_award: card U4 — map_pointer_axis scales 0..32767 onto the span" {
    try std.testing.expectEqual(@as(u32, 0), map_pointer_axis(0, 1280));
    try std.testing.expectEqual(@as(u32, 640), map_pointer_axis(16384, 1280));
    try std.testing.expectEqual(@as(u32, 1279), map_pointer_axis(32767, 1280));
    try std.testing.expectEqual(@as(u32, 719), map_pointer_axis(32767, 720));
}

test "driving_award: card U5 — the chrome draws the focus ring on the focused window" {
    arm();
    // Focus the clock; composite (returns not_ready on the host after
    // drawing — the pixels are inspectable in the BSS framebuffer).
    try std.testing.expect(focus(1));
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    // The clock's top-left ring pixel is white.
    const px = struct {
        fn at(f: [*]u8, st: usize, x: usize, y: usize) u32 {
            const o = y * st + x * 4;
            return @as(u32, f[o + 2]) << 16 | @as(u32, f[o + 1]) << 8 | f[o];
        }
    };
    try std.testing.expectEqual(focus_ring_rgb, px.at(fb, stride, clock_x, clock_y));
    // ...and just inside the ring, the clock's own border (not white).
    try std.testing.expect(px.at(fb, stride, clock_x + focus_ring_w, clock_y + focus_ring_w) != focus_ring_rgb);
    // Focus back to the terminal: the ring is at the screen edges now.
    try std.testing.expect(focus(0));
    _ = composite();
    try std.testing.expectEqual(focus_ring_rgb, px.at(fb, stride, 0, 0));
    // The clock's corner is NOT ringed anymore.
    try std.testing.expect(px.at(fb, stride, clock_x, clock_y) == clock_border_rgb);
}

test "driving_award: card U4 — pointer motion moves the cursor; a click focuses + raises" {
    arm();
    // Move to the clock's area (mapped coordinates), no click yet.
    const st_no: input.PointerState = .{ .x = 26000, .y = 8000, .buttons = 0, .valid = true };
    try std.testing.expectEqual(@as(?u8, null), pointer_tick(st_no, null));
    const c = cursor_pos().?;
    try std.testing.expectEqual(hit_test(c.x, c.y).?, 1); // the cursor is over the clock
    // Click: D4 click = focus + raise on the topmost window under it.
    try std.testing.expectEqual(@as(?u8, 1), pointer_tick(st_no, .{ .x = st_no.x, .y = st_no.y }));
    try std.testing.expectEqual(@as(u8, 1), focused_window_id());
    try std.testing.expectEqual(@as(u8, 1), windows[win_count - 1].id); // raised on top
    // Move to the terminal area and click: focus returns to window 0.
    const st_term: input.PointerState = .{ .x = 4000, .y = 30000, .buttons = 0, .valid = true };
    try std.testing.expectEqual(@as(?u8, 0), pointer_tick(st_term, .{ .x = 4000, .y = 30000 }));
    // The cursor renders magenta at its cell after a composite.
    _ = composite();
    const stride = virtio_gpu.fb_width * 4;
    const fb: [*]u8 = @ptrCast(&virtio_gpu.gpu_fb);
    const o = c.y * stride + c.x * 4; // NOTE: st_no's cursor cell (over the clock)
    _ = o;
    const cc = cursor_pos().?;
    const off = cc.y * stride + cc.x * 4;
    try std.testing.expectEqual(@as(u8, 0xff), fb[off + 2]); // R (0xff00ff)
    try std.testing.expectEqual(@as(u8, 0x00), fb[off + 1]); // G
    try std.testing.expectEqual(@as(u8, 0xff), fb[off]); // B
}
