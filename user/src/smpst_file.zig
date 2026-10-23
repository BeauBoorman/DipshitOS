//! census (M188e, #3190): SMPFILE.BIN — gate-referenced: live-smp-stress.
//! VirelaiOS four-core stress FILE hammer — SMPFILE.BIN (claim 907,
//! issue #858). Pinned to CORE 1 by the gate (`exec -c1 SMPFILE.BIN`);
//! it hammers the FILE service domain (slots 23-26 — the host file
//! channel) in a tight, bounded loop so its core-1 traffic runs
//! CONCURRENTLY with the NET hammer on core 2, the WIN hammer on core 3,
//! and the EV hammer on core 0. A syscall that accidentally held a second
//! domain's lock would serialize against that domain's hammer and the
//! gate's heartbeat/done markers would stall or fault.
//!
//! Shape: 6 heartbeats x (2 read round-trips + 2 write round-trips of
//! the planted fixture) = 24 file ops, one exact `smpfile: hb=<n>` line
//! per heartbeat (each ~1 s apart via sys_sleep — the wake is a ring
//! resume on core 1), then `smpfile: done ops=24`, then sys_exit(0).
//! A lost wakeup, a duplicate staging, a cross-domain lock hold, or a
//! corrupt file-channel exchange breaks a marker or the clean reap.
//!
//! Plain freestanding Zig (the calc/notepad _start(.c) shape), no libc.
//! The marker/count constants are `pub const`s pinned by host tests so
//! the live gate's grep targets cannot drift from the payload.

const std = @import("std");
const st = @import("lib/smpst.zig");

/// The fixture the gate plants at /host/STRESS.TXT (40 bytes).
pub const fixture_path: []const u8 = "/host/STRESS.TXT";
/// The scratch target the hammer rewrites each boot (host-verifiable).
pub const out_path: []const u8 = "/host/SMPST-OUT.TXT";
/// The exact planted fixture bytes (the gate writes them verbatim; 40
/// bytes, no trailing newline — the length is the read assertion).
pub const fixture: []const u8 = "smpst stress fixture 0123456789abcdefghi";
/// Heartbeats x ops-per-heartbeat = total file ops (4 ops each).
pub const heartbeats: u32 = 6;
pub const ops_per_hb: u32 = 4;
pub const total_ops: u32 = heartbeats * ops_per_hb;
/// The exit status.
pub const exit_status: u32 = 0;

/// A REAL writable global — it forces a .bss segment (the DSK3 segmented
/// image the loader maps EL0-RW + UXN and adds to the task's uaccess
/// regions), and hammering it across SVC boundaries exercises that
/// per-process data-region handling under load.
var ops: u32 = 0;

pub export fn _start() callconv(.c) noreturn {
    var buf: [64]u8 = undefined;
    var hb: u32 = 1;
    while (hb <= heartbeats) : (hb += 1) {
        var j: u32 = 0;
        while (j < 2) : (j += 1) {
            // Read round trip: open -> read (fixture.len bytes) -> close.
            const rfd = st.file_open(fixture_path, st.MODE_READ);
            if (rfd < 0) st.exit_process(111);
            const got = st.file_read(@intCast(rfd), buf[0..]);
            st.file_close(@intCast(rfd));
            if (got != fixture.len) st.exit_process(112);
            ops += 1;
            // Write round trip: open (create/truncate) -> write -> close.
            const wfd = st.file_open(out_path, st.MODE_WRITE | st.MODE_CREATE);
            if (wfd < 0) st.exit_process(113);
            const sent = st.file_write(@intCast(wfd), buf[0..@intCast(got)]);
            st.file_close(@intCast(wfd));
            if (sent != got) st.exit_process(114);
            ops += 1;
        }
        st.print("smpfile: ", "hb={d}\n", .{hb});
        st.sleep_ticks(1);
    }
    st.print("smpfile: ", "done ops={d}\n", .{ops});
    st.exit_process(exit_status);
}

test "user smpfile: marker/count/exit constants are pinned (live-gate targets)" {
    try std.testing.expectEqualStrings(fixture_path, "/host/STRESS.TXT");
    try std.testing.expectEqualStrings(out_path, "/host/SMPST-OUT.TXT");
    try std.testing.expectEqual(@as(usize, 40), fixture.len);
    try std.testing.expectEqual(@as(u32, 6), heartbeats);
    try std.testing.expectEqual(@as(u32, 24), total_ops);
    try std.testing.expectEqual(@as(u32, 0), exit_status);
}

test "user smpfile module compiles on the host" {
    _ = @intFromPtr(&_start);
}
