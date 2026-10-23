//! census (M188e, #3190): SCHEDINT.BIN — gate-referenced: live-sched-ring, live-vm-depth.
//! VirelaiOS scheduler-aging interactive — SCHEDINT.BIN (M133b,
//! issue #2756).
//!
//! The interactive half of the live-sched-ring aging leg: TWO copies are
//! exec'd pinned to core 1 (`exec -c1 SCHEDINT.BIN`) alongside the
//! SCHEDHOG.BIN hog. Each cycle burns a bounded spin (it holds the CPU
//! and accrues aging penalty like real interactive work), then
//! `sys_sleep(1)` blocks — the committed block resets its decay to 0,
//! so it always re-enters the ready ring at full priority. That is the
//! "recovers on block" half of the card's contract: queue-mates that
//! block stay un-penalized while the hog decays to `age_max`.
//!
//! One `schedint: hb=<n>` line per cycle paces the gate: the spec's
//! --scriptN-after markers wait on exact heartbeat counts to bracket the
//! measurement window. It never exits; the VM stops at the end marker.
//!
//! Plain freestanding Zig (the smpst shape), no libc. The marker and
//! count constants are `pub const`s pinned by the host test so the live
//! gate's grep targets cannot drift from the payload.

const std = @import("std");
const st = @import("lib/smpst.zig");

/// Written once at startup.
pub const armed_marker: []const u8 = "schedint: armed\n";
/// Spin iterations per cycle — the interactive burn phase. The
/// scheduler ticks at 1 Hz and `run_ticks` credits whoever holds the
/// core AT a tick boundary, so the burn must SPAN boundaries to be
/// measured: the dependent-chain inner op runs ~0.6-0.75 Giter/s of held
/// CPU on VZ, so 1.5e9 iterations is ~2-2.5 CPU-s — the task holds
/// across ~2 boundaries per cycle (accruing up to ~2 penalty before its
/// committed block resets it), long enough that it wins most boundary
/// charges against the `age_max`-capped hog but short of the cap itself.
/// A sub-tick burn (<1 s of CPU) is invisible to the measurement — the
/// hog fills every post-burn interval tail and soaks ~all ticks.
pub const burn_iters: u64 = 1_500_000_000;
/// Scheduler-tick sleeps per cycle — the committed block that resets
/// the task's aging penalty.
pub const sleep_ticks: u64 = 1;

/// A REAL writable global — the burn's sink (same rule as schedhog's).
var sink: u64 = 0;

pub export fn _start() callconv(.c) noreturn {
    st.print("schedint: ", "armed\n", .{});
    var hb: u64 = 0;
    while (true) {
        var i: u64 = 0;
        while (i < burn_iters) : (i += 1) {
            sink +%= i ^ (sink >> 7);
        }
        hb += 1;
        st.print("schedint: ", "hb={d}\n", .{hb});
        st.sleep_ticks(sleep_ticks);
    }
}

test "user schedint module compiles and exports the EL0 entry" {
    _ = @intFromPtr(&_start);
}

test "user schedint: marker/count constants are pinned (live-gate targets)" {
    try std.testing.expectEqualStrings("schedint: armed\n", armed_marker);
    try std.testing.expectEqual(@as(u64, 1_500_000_000), burn_iters);
    try std.testing.expectEqual(@as(u64, 1), sleep_ticks);
}
