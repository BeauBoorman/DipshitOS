//! VirelaiOS scheduler-aging hog — SCHEDHOG.BIN (M133b, issue #2756).
//!
//! The CPU hog half of the live-sched-ring aging leg: exec'd pinned to
//! core 1 (`exec -c1 SCHEDHOG.BIN`) alongside two SCHEDINT.BIN
//! interactives. It burns every slice it is given — a pure spin, no
//! sleep, no yield, no exit — so the scheduler's full-slice aging
//! (`age_penalty`) converges it to `age_max` and stays there: the
//! measured decay the leg's `smp: run` rows carry. It never exits; the
//! gate ends on the script marker and the VM stops with it running.
//!
//! Plain freestanding Zig (the smpst shape), no libc. The marker
//! constants are `pub const`s pinned by the host test so the live
//! gate's grep targets cannot drift from the payload.

const std = @import("std");
const st = @import("lib/smpst.zig");

/// Written once at startup — proves the hog's task is live before the
/// leg's measurement window opens.
pub const armed_marker: []const u8 = "schedhog: armed\n";

/// Spin iterations per outer lap. The hog's lap length is irrelevant to
/// the measurement (ticks attribute whoever holds the core when they
/// fire); the counter only has to defeat dead-code elimination.
pub const lap_iters: u64 = 1_000_000;

/// A REAL writable global — the spin's sink. `doNotOptimizeAway` keeps
/// it materialized (an optimize-away sink leaves no writable segment at
/// all, and elf2bin's --segments boundary then fails the page-aligned
/// text_size check).
var sink: u64 = 0;

pub export fn _start() callconv(.c) noreturn {
    st.print("schedhog: ", "armed\n", .{});
    while (true) {
        var i: u64 = 0;
        while (i < lap_iters) : (i += 1) {
            sink +%= i ^ (sink >> 7);
        }
        std.mem.doNotOptimizeAway(&sink);
    }
}

test "user schedhog module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user schedhog: the armed marker is pinned (live-gate grep target)" {
    try std.testing.expectEqualStrings("schedhog: armed\n", armed_marker);
}
