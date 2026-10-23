//! census (M188e, #3190): SMPNET.BIN — gate-referenced: live-smp-stress.
//! VirelaiOS four-core stress NET hammer — SMPNET.BIN (claim 907,
//! issue #858). Pinned to CORE 2 by the gate (`exec -c2 SMPNET.BIN`);
//! it hammers the NET service domain (slots 9-11 — UDP listen/send/recv)
//! in a tight, bounded loop of OWN-IP LOOPBACK round trips (dst 10.0.0.1
//! = the kernel's own static IP, no device or host peer — the N5
//! loopback path), so its core-2 traffic runs CONCURRENTLY with the FILE
//! hammer on core 1, the WIN hammer on core 3, and the EV hammer on
//! core 0. The gate runs `net ip 10.0.0.1` before the execs.
//!
//! Shape: bind port 7100, then 6 heartbeats x 4 loopback round trips (a
//! 1-byte payload \"N\" sends 9 bytes back: the 8-byte header + payload)
//! = 24 UDP ops, one exact `smpnet: hb=<n>` line per heartbeat (~1 s
//! apart via sys_sleep — the wake is a ring resume on core 2), then
//! `smpnet: done ops=24`, then sys_exit(0). A lost wakeup, a duplicate
//! staging, a cross-domain lock hold, or a wedged NET layer breaks a
//! marker or the clean reap.
//!
//! Plain freestanding Zig (the calc/notepad _start(.c) shape), no libc.
//! The marker/count constants are `pub const`s pinned by host tests so
//! the live gate's grep targets cannot drift from the payload.

const std = @import("std");
const st = @import("lib/smpst.zig");

/// The deterministic own-IP loopback constant (10.0.0.1, network order).
pub const own_ip: u32 = 0x0a000001;
/// The port this hammer binds (slot 9) and round-trips (slots 10/11).
pub const port: u16 = 7100;
/// The 1-byte payload (the recv sees the 9-byte datagram: header+payload).
pub const payload: u8 = 'N';
/// The full loopback datagram length (8-byte header + 1-byte payload).
pub const datagram_len: i64 = 9;
/// Heartbeats x round trips per heartbeat = total UDP ops.
pub const heartbeats: u32 = 6;
pub const ops_per_hb: u32 = 4;
pub const total_ops: u32 = heartbeats * ops_per_hb;
/// The exit status.
pub const exit_status: u32 = 0;

/// A REAL writable global — forces a .bss segment (see smpst_file.zig:
/// the DSK3 loader maps it EL0-RW and the per-process uaccess regions
/// carry it across SVCs; hammering it under load exercises that seam).
var ops: u32 = 0;

pub export fn _start() callconv(.c) noreturn {
    if (st.udp_listen(port) != 0) st.exit_process(121);
    var buf: [16]u8 = undefined;
    var hb: u32 = 1;
    while (hb <= heartbeats) : (hb += 1) {
        var j: u32 = 0;
        while (j < ops_per_hb) : (j += 1) {
            // Loopback send: dst = own ip -> the N5 loopback path returns
            // the sent payload length immediately (no device round trip).
            const sent = st.udp_send(own_ip, port, &[_]u8{payload});
            if (sent != 1) st.exit_process(122);
            // Recv the 9-byte datagram back from our own listen socket.
            const got = st.udp_recv(port, buf[0..]);
            if (got != datagram_len) st.exit_process(123);
            ops += 1;
        }
        st.print("smpnet: ", "hb={d}\n", .{hb});
        st.sleep_ticks(1);
    }
    st.print("smpnet: ", "done ops={d}\n", .{ops});
    st.exit_process(exit_status);
}

test "user smpnet: marker/count/exit constants are pinned (live-gate targets)" {
    try std.testing.expectEqual(@as(u32, 0x0a000001), own_ip);
    try std.testing.expectEqual(@as(u16, 7100), port);
    try std.testing.expectEqual(@as(i64, 9), datagram_len);
    try std.testing.expectEqual(@as(u32, 6), heartbeats);
    try std.testing.expectEqual(@as(u32, 24), total_ops);
    try std.testing.expectEqual(@as(u32, 0), exit_status);
}

test "user smpnet module compiles on the host" {
    _ = @intFromPtr(&_start);
}
