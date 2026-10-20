//! Road Pops (milestone six, card G3 — claim 1574): the boot terminal
//! goes graphical.
//!
//! A *tee* console adapter. The M1.5 console (line editor, tokenizer,
//! command registry, shell idle loop) never changes: it holds a
//! `console.Console` value, and the kernel seam hands it a Road Pops
//! console whose `write` forwards every byte to BOTH:
//!   * the underlying serial console (`base`) — the shared seam; every
//!     byte still reaches serial FIRST, so the transcript gates and the
//!     byte-identical fixture stay exactly as they were; and
//!   * an injectable framebuffer `Target` (put_bytes/present/clear),
//!     armed only when the virtio-gpu transport is ready — the text
//!     layer paints the same banner + prompt + replies on the screen.
//!
//! The framebuffer side is batched: `write` only marks the ring dirty
//! (cheap — G2's text layer), and `present_if_dirty` pushes ONE
//! full-frame transfer + flush per output batch. The shell idle loop is
//! the drain point (the card-3d shell-idle-drain pattern, next to the
//! net RX drain), so a multi-line command reply costs one present.
//!
//! The FIRST present emits `text: boot banner presented` on the base
//! console — honestly: the boot banner (the shell's own banner, which
//! renders through the tee) IS presented to the framebuffer at that
//! moment. This keeps the G2 (claim 3194) evidence line, now produced by
//! the real terminal path rather than a one-shot boot paint.
//!
//! Degradation: with no target armed (no gpu device — the default VM),
//! write/flush/readByte behave EXACTLY like the base console; the
//! default VM stays byte-identical (proven by the verify-vz sweep).
//! Input stays on serial (`readByte` delegates) until card G4.
//!
//! No libc, no POSIX, no allocation, no unbounded state. The console
//! vtable is built in RAM (claim 0015: `&fn` in a const table holds
//! link-time absolute addresses, wrong at the kernel's runtime load
//! base; building the table at runtime resolves PC-relatively).

const std = @import("std");
const console = @import("console.zig");

/// The framebuffer text target (injectable for host tests; the kernel
/// wires G2's text.zig through these three functions).
pub const Target = struct {
    ctx: *anyopaque,
    put_bytes: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    present: *const fn (ctx: *anyopaque) void,
    clear: *const fn (ctx: *anyopaque) void,
};

pub const Report = struct {
    armed: bool,
    dirty: bool,
    presents: usize,
};

/// Tee console state. Value type (host tests use their own instances);
/// the kernel seam keeps ONE global instance (see `arm`/`console`/`drain`
/// below).
pub const State = struct {
    base: console.Console,
    /// null = serial-only degradation (no gpu device / default VM).
    target: ?Target = null,
    /// Optional keyboard-input source (milestone seven card I3, claim
    /// 6050): consulted before the base console in readByteFn. null = the
    /// default VM's serial-only input (byte-identical).
    read_source: ?*const fn () ?u8 = null,
    /// A console write reached the framebuffer side since the last
    /// present; the idle loop drains it.
    dirty: bool = false,
    /// Full-frame presents pushed since arm.
    presents: usize = 0,
    /// The first present emits the boot-banner evidence exactly once.
    boot_evidence_emitted: bool = false,

    // Claim 0015: RAM-built vtable (see module comment).
    vtable_storage: console.Console.VTable = undefined,
    vtable_ready: bool = false,

    pub fn init(base: console.Console, target: ?Target) State {
        return .{ .base = base, .target = target };
    }

    fn writeFn(ctx: *anyopaque, bytes: []const u8) void {
        const self: *State = @ptrCast(@alignCast(ctx));
        // Serial first — the shared seam (transcript gates unchanged).
        self.base.write(bytes);
        if (self.target) |t| {
            t.put_bytes(t.ctx, bytes);
            self.dirty = true;
        }
    }

    fn flushFn(ctx: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ctx));
        self.base.flush();
        self.present_if_dirty();
    }

    fn readByteFn(ctx: *anyopaque) ?u8 {
        const self: *State = @ptrCast(@alignCast(ctx));
        // Card I3 (claim 6050): screen-side keyboard input first, then the
        // serial fallback (the default VM has no input source → serial-only).
        if (self.read_source) |src| {
            if (src()) |b| return b;
        }
        return self.base.readByte();
    }

    fn pushByteFn(ctx: *anyopaque, b: u8) bool {
        const self: *State = @ptrCast(@alignCast(ctx));
        // The tee reads its base when the keyboard source is dry, so handed
        // back serial input requeues on the base's own lane.
        return self.base.pushByte(b);
    }

    fn ensure_vtable(self: *State) *const console.Console.VTable {
        if (!self.vtable_ready) {
            self.vtable_storage = .{
                .write = writeFn,
                .flush = flushFn,
                .readByte = readByteFn,
                .pushByte = pushByteFn,
            };
            self.vtable_ready = true;
        }
        return &self.vtable_storage;
    }

    pub fn to_console(self: *State) console.Console {
        return .{ .ctx = self, .vtable = self.ensure_vtable() };
    }

    /// One full-frame present per dirty batch. No-op when unarmed
    /// (serial-only) or clean. The shell idle loop is the drain point.
    pub fn present_if_dirty(self: *State) void {
        const t = self.target orelse return;
        if (!self.dirty) return;
        self.dirty = false;
        self.presents += 1;
        t.present(t.ctx);
        if (!self.boot_evidence_emitted) {
            self.boot_evidence_emitted = true;
            // The G2 evidence line, now honest: the boot banner (the
            // shell's banner) WAS presented by this present.
            self.base.write("text: boot banner presented\n");
        }
    }

    /// Attach the keyboard-input source (card I3); null restores the
    /// serial-only read path.
    pub fn set_read_source(self: *State, src: ?*const fn () ?u8) void {
        self.read_source = src;
    }

    /// Forward a framebuffer clear to the target (the `text clear`
    /// path); the serial side is untouched.
    pub fn clear_framebuffer(self: *State) void {
        const t = self.target orelse return;
        t.clear(t.ctx);
        self.dirty = true;
    }

    pub fn report(self: *const State) Report {
        return .{ .armed = self.target != null, .dirty = self.dirty, .presents = self.presents };
    }
};

// ---------------------------------------------------------------------------
// Kernel seam: ONE global instance, armed by kernel/src/main.zig after the
// gpu transport is up. `drain()` is called by the shell idle loop.
// ---------------------------------------------------------------------------

var global: State = undefined;
var global_ready = false;

/// Arm (or re-arm) the global tee with the base serial console + an
/// optional framebuffer target. `null` target = serial-only degradation.
pub fn arm(base: console.Console, target: ?Target) void {
    global = State.init(base, target);
    global_ready = true;
}

/// The tee console for Monitor.init (the shell + monitor then render to
/// serial AND the screen).
pub fn tee_console() console.Console {
    return global.to_console();
}

/// Attach the keyboard-input source to the global tee (card I3); null
/// restores the serial-only read path (the default VM).
pub fn set_read_source(src: ?*const fn () ?u8) void {
    if (global_ready) global.set_read_source(src);
}

/// Shell idle-loop drain: one present per dirty output batch.
pub fn drain() void {
    if (global_ready) global.present_if_dirty();
}

pub fn is_armed() bool {
    return global_ready and global.target != null;
}

pub fn report() Report {
    if (!global_ready) return .{ .armed = false, .dirty = false, .presents = 0 };
    return global.report();
}

// ---------------------------------------------------------------------------
// Tests (host-side; injectable mocks, no hardware)
// ---------------------------------------------------------------------------

/// Combined capture: the base (serial) console + the framebuffer target
/// share one byte buffer so tests can assert ORDER (serial first).
const MockTee = struct {
    capture: [512]u8 = undefined,
    len: usize = 0,
    presents: usize = 0,
    clears: usize = 0,

    pub const vtable = console.Console.VTable{
        .write = writeFn,
        .flush = flushFn,
        .readByte = readByteFn,
    };

    var feed: []const u8 = "";

    pub fn to_console(self: *MockTee) console.Console {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn append(self: *MockTee, bytes: []const u8) void {
        const n = @min(bytes.len, self.capture.len - self.len);
        @memcpy(self.capture[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    fn writeFn(ctx: *anyopaque, bytes: []const u8) void {
        const self: *MockTee = @ptrCast(@alignCast(ctx));
        self.append(bytes);
    }

    fn flushFn(_: *anyopaque) void {}

    fn readByteFn(_: *anyopaque) ?u8 {
        if (feed.len == 0) return null;
        const b = feed[0];
        feed = feed[1..];
        return b;
    }

    fn putBytesFn(ctx: *anyopaque, bytes: []const u8) void {
        const self: *MockTee = @ptrCast(@alignCast(ctx));
        self.append("|fb|"); // marker: this chunk reached the framebuffer
        self.append(bytes);
    }

    fn presentFn(ctx: *anyopaque) void {
        const self: *MockTee = @ptrCast(@alignCast(ctx));
        self.presents += 1;
        self.append("<present>");
    }

    fn clearFn(ctx: *anyopaque) void {
        const self: *MockTee = @ptrCast(@alignCast(ctx));
        self.clears += 1;
        self.append("<clear>");
    }

    pub fn target(self: *MockTee) Target {
        return .{ .ctx = self, .put_bytes = putBytesFn, .present = presentFn, .clear = clearFn };
    }
};

test "road_pops: write tees to serial first, then the framebuffer" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), mock.target());
    state.to_console().puts("hi");
    // Serial copy first, then the framebuffer copy (marker-delimited).
    try std.testing.expectEqualStrings("hi|fb|hi", mock.capture[0..mock.len]);
    mock.len = 0;
    state.to_console().print_line("yo"); // write("yo") + write("\n"), two chunks
    try std.testing.expectEqualStrings("yo|fb|yo\n|fb|\n", mock.capture[0..mock.len]);
}

test "road_pops: drain presents once per dirty batch" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), mock.target());
    const con = state.to_console();
    con.puts("a");
    con.puts("b");
    con.puts("c");
    try std.testing.expectEqual(@as(usize, 0), mock.presents);
    state.present_if_dirty();
    try std.testing.expectEqual(@as(usize, 1), mock.presents);
    // Clean after the drain: no second present without new output.
    state.present_if_dirty();
    try std.testing.expectEqual(@as(usize, 1), mock.presents);
    con.puts("d");
    state.present_if_dirty();
    try std.testing.expectEqual(@as(usize, 2), mock.presents);
}

test "road_pops: the first present emits the boot-banner evidence once" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), mock.target());
    const con = state.to_console();
    con.puts("banner line");
    state.present_if_dirty();
    const first = mock.capture[0..mock.len];
    // The banner reached the framebuffer (|fb| marker) and the evidence
    // line followed on the serial console.
    try std.testing.expect(std.mem.indexOf(u8, first, "|fb|") != null);
    try std.testing.expect(std.mem.endsWith(u8, first, "text: boot banner presented\n"));
    con.puts("more");
    state.present_if_dirty();
    try std.testing.expectEqual(@as(usize, 2), mock.presents);
    // The evidence line appears exactly once across the whole capture.
    const all = mock.capture[0..mock.len];
    var count: usize = 0;
    var i: usize = 0;
    const ev = "text: boot banner presented\n";
    while (std.mem.indexOfPos(u8, all, i, ev)) |pos| {
        count += 1;
        i = pos + ev.len;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "road_pops: no target degrades to serial-only (default VM)" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), null);
    const con = state.to_console();
    con.puts("x");
    try std.testing.expectEqualStrings("x", mock.capture[0..mock.len]);
    state.present_if_dirty();
    try std.testing.expectEqual(@as(usize, 0), mock.presents);
    try std.testing.expect(!state.report().armed);
}

test "road_pops: flush flushes the base and drains" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), mock.target());
    state.to_console().puts("z");
    state.to_console().flush();
    try std.testing.expectEqual(@as(usize, 1), mock.presents);
}

test "road_pops: readByte delegates to the base (input stays on serial)" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), mock.target());
    MockTee.feed = "ab";
    const con = state.to_console();
    try std.testing.expectEqual(@as(u8, 'a'), con.readByte().?);
    try std.testing.expectEqual(@as(u8, 'b'), con.readByte().?);
    try std.testing.expect(con.readByte() == null);
    MockTee.feed = "";
}

// File-scope scripted keyboard source for the card-I3 read-source test
// (a file-scope function + var, so no mutable-local capture is needed).
var test_kb_feed: []const u8 = "";
fn testKbPop() ?u8 {
    if (test_kb_feed.len == 0) return null;
    const b = test_kb_feed[0];
    test_kb_feed = test_kb_feed[1..];
    return b;
}

test "road_pops: a keyboard read source is consulted before serial (card I3)" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), mock.target());
    test_kb_feed = "XY";
    state.set_read_source(testKbPop);
    MockTee.feed = "ab"; // the serial fallback
    const con = state.to_console();
    try std.testing.expectEqual(@as(u8, 'X'), con.readByte().?);
    try std.testing.expectEqual(@as(u8, 'Y'), con.readByte().?);
    // Keyboard exhausted → the serial fallback resumes.
    try std.testing.expectEqual(@as(u8, 'a'), con.readByte().?);
    try std.testing.expectEqual(@as(u8, 'b'), con.readByte().?);
    try std.testing.expect(con.readByte() == null);
    MockTee.feed = "";
    test_kb_feed = "";
    state.set_read_source(null);
}

test "road_pops: clear_framebuffer forwards to the target only" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), mock.target());
    state.clear_framebuffer();
    try std.testing.expectEqual(@as(usize, 1), mock.clears);
    try std.testing.expectEqualStrings("<clear>", mock.capture[0..mock.len]);
    try std.testing.expect(state.report().dirty);
}

test "road_pops: report reflects armed/dirty/presents" {
    var mock = MockTee{};
    var state = State.init(mock.to_console(), mock.target());
    var r = state.report();
    try std.testing.expect(r.armed);
    try std.testing.expect(!r.dirty);
    try std.testing.expectEqual(@as(usize, 0), r.presents);
    state.to_console().puts("x");
    r = state.report();
    try std.testing.expect(r.dirty);
    state.present_if_dirty();
    r = state.report();
    try std.testing.expectEqual(@as(usize, 1), r.presents);
    try std.testing.expect(!r.dirty);
}
