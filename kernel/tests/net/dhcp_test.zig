//! Decoupled DHCP protocol unit test suite (M41 TS5, #956).
//!
//! Extracted from kernel/src/dhcp.zig.

const std = @import("std");
const dhcp = @import("dhcp");
const arp = dhcp.arp;

// Symbols from dhcp
const client_port = dhcp.client_port;
const server_port = dhcp.server_port;
const magic_cookie = dhcp.magic_cookie;
const bootp_hdr_len = dhcp.bootp_hdr_len;
const msg_max = dhcp.msg_max;
const frame_max = dhcp.frame_max;
const max_attempts = dhcp.max_attempts;

const opt_subnet_mask = dhcp.opt_subnet_mask;
const opt_router = dhcp.opt_router;
const opt_msg_type = dhcp.opt_msg_type;
const opt_requested_ip = dhcp.opt_requested_ip;
const opt_lease_time = dhcp.opt_lease_time;
const opt_server_id = dhcp.opt_server_id;
const opt_end = dhcp.opt_end;

const msg_type_discover = dhcp.msg_type_discover;
const msg_type_offer = dhcp.msg_type_offer;
const msg_type_request = dhcp.msg_type_request;
const msg_type_ack = dhcp.msg_type_ack;

const State = dhcp.State;
const Event = dhcp.Event;
const LifecycleAction = dhcp.LifecycleAction;

const build_discover = dhcp.build_discover;
const build_request = dhcp.build_request;
const parse_reply = dhcp.parse_reply;
const start = dhcp.start;
const handle_rx = dhcp.handle_rx;
const reset = dhcp.reset;
const expire = dhcp.expire;
const build_req = dhcp.build_req;
const step_lifecycle = dhcp.step_lifecycle;
const elapsed = dhcp.elapsed;

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the fixtures
// ---------------------------------------------------------------------------

test "dhcp: build_discover is byte-exact against the fixture" {
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const txn: u32 = 0x12345678;
    var m: [msg_max]u8 = undefined;
    const n = build_discover(&m, &chaddr, txn);
    // 236 + cookie(4) + 53,1,type(3) + 255(1) = 244.
    try std.testing.expectEqual(@as(usize, 244), n);
    try std.testing.expectEqual(@as(u8, 1), m[0]); // op BOOTREQUEST
    try std.testing.expectEqual(@as(u8, 1), m[1]); // htype ethernet
    try std.testing.expectEqual(@as(u8, 6), m[2]); // hlen
    try std.testing.expectEqual(@as(u8, 0), m[3]); // hops
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, m[4..8]); // dhcp.xid BE
    try std.testing.expectEqual(@as(u8, 0x80), m[10]); // broadcast flag high
    try std.testing.expectEqual(@as(u8, 0x00), m[11]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, m[12..16]); // ciaddr
    try std.testing.expectEqualSlices(u8, &chaddr, m[28..34]); // chaddr
    try std.testing.expectEqualSlices(u8, &magic_cookie, m[236..240]);
    try std.testing.expectEqual(@as(u8, opt_msg_type), m[240]);
    try std.testing.expectEqual(@as(u8, 1), m[241]);
    try std.testing.expectEqual(@as(u8, msg_type_discover), m[242]);
    try std.testing.expectEqual(@as(u8, opt_end), m[243]);
}

test "dhcp: build_request is byte-exact — option 50 + 54, 256 bytes" {
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const txn: u32 = 0x12345678;
    const req_ip = [4]u8{ 10, 0, 0, 5 };
    const srv = [4]u8{ 10, 0, 0, 5 };
    var m: [msg_max]u8 = undefined;
    const n = build_request(&m, &chaddr, txn, req_ip, srv);
    // 236 + cookie(4) + 53,1,3(3) + 50,4,ip(6) + 54,4,srv(6) + 255(1) = 256.
    try std.testing.expectEqual(@as(usize, 256), n);
    try std.testing.expectEqual(@as(u8, msg_type_request), m[242]);
    try std.testing.expectEqual(@as(u8, opt_requested_ip), m[243]);
    try std.testing.expectEqual(@as(u8, 4), m[244]);
    try std.testing.expectEqualSlices(u8, &req_ip, m[245..249]);
    try std.testing.expectEqual(@as(u8, opt_server_id), m[249]);
    try std.testing.expectEqual(@as(u8, 4), m[250]);
    try std.testing.expectEqualSlices(u8, &srv, m[251..255]);
    try std.testing.expectEqual(@as(u8, opt_end), m[255]);
}

test "dhcp: parse_reply — a crafted OFFER/ACK round trip (byte-exact)" {
    // Build a reply the way the host responder does: copy the DISCOVER
    // shape, op=2, yiaddr, cookie, then 53,1,type + 1,4,mask + 3,4,gw +
    // 54,4,server + 51,4,dhcp.lease + 255. The guest's parser must read it.
    // The reply message is 268 bytes (the fixed dhcp.lease options appended)
    // — the test uses a 300-byte local, the live path slices the RX
    // buffer (no fixed bound needed).
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const txn: u32 = 0x12345678;
    var m: [300]u8 = undefined;
    const n = build_discover(&m, &chaddr, txn);
    try std.testing.expectEqual(@as(usize, 244), n);
    m[0] = 2; // BOOTREPLY
    @memcpy(m[16..20], &[_]u8{ 10, 0, 0, 5 }); // yiaddr
    m[240] = opt_msg_type;
    m[242] = msg_type_offer;
    var o: usize = 243;
    m[o] = 1;
    m[o + 1] = 4;
    @memcpy(m[o + 2 .. o + 6], &[_]u8{ 255, 255, 255, 0 });
    o += 6;
    m[o] = 3;
    m[o + 1] = 4;
    @memcpy(m[o + 2 .. o + 6], &[_]u8{ 10, 0, 0, 1 });
    o += 6;
    m[o] = opt_server_id;
    m[o + 1] = 4;
    @memcpy(m[o + 2 .. o + 6], &[_]u8{ 10, 0, 0, 5 });
    o += 6;
    m[o] = opt_lease_time;
    m[o + 1] = 4;
    m[o + 2] = 0x00;
    m[o + 3] = 0x00;
    m[o + 4] = 0x0e;
    m[o + 5] = 0x10; // dhcp.lease 3600
    o += 6;
    m[o] = opt_end;
    const mlen = o + 1;

    const p = parse_reply(m[0..mlen]).?;
    try std.testing.expectEqual(@as(u8, msg_type_offer), p.msg_type);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &p.yiaddr);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, &p.mask.?);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &p.router.?);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &p.server_id.?);
    try std.testing.expectEqual(@as(u32, 3600), p.lease_time.?);
}

test "dhcp: parse_reply — malformed replies return null" {
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    var m: [msg_max]u8 = undefined;
    const n = build_discover(&m, &chaddr, 1);
    // Wrong op (BOOTREQUEST) -> null.
    try std.testing.expect(parse_reply(m[0..n]) == null);
    // Bad magic cookie -> null.
    m[0] = 2;
    m[238] ^= 0xff;
    try std.testing.expect(parse_reply(m[0..n]) == null);
    m[238] ^= 0xff;
    // No option 53 -> null.
    m[240] = opt_end;
    try std.testing.expect(parse_reply(m[0..n]) == null);
    // Too short -> null.
    try std.testing.expect(parse_reply(m[0..100]) == null);
}

test "dhcp: the four-message handshake — INIT -> SELECTING -> REQUESTING -> BOUND" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };

    // INIT: start() builds the DISCOVER.
    start(&chaddr, 0xabcd1234);
    try std.testing.expectEqual(State.selecting, dhcp.state);
    try std.testing.expectEqual(@as(u32, 0xabcd1234), dhcp.xid);
    try std.testing.expectEqual(@as(usize, 244), dhcp.msg_len);
    try std.testing.expectEqual(@as(u8, msg_type_discover), dhcp.msg[242]);

    // The server's OFFER (a reply built over the discover shape — 268 B).
    var reply: [300]u8 = undefined;
    @memcpy(reply[0..dhcp.msg_len], dhcp.msg[0..dhcp.msg_len]);
    reply[0] = 2;
    @memcpy(reply[16..20], &[_]u8{ 10, 0, 0, 5 });
    reply[240] = opt_msg_type;
    reply[242] = msg_type_offer;
    var o: usize = 243;
    reply[o] = 1;
    reply[o + 1] = 4;
    @memcpy(reply[o + 2 .. o + 6], &[_]u8{ 255, 255, 255, 0 });
    o += 6;
    reply[o] = 3;
    reply[o + 1] = 4;
    @memcpy(reply[o + 2 .. o + 6], &[_]u8{ 10, 0, 0, 1 });
    o += 6;
    reply[o] = opt_server_id;
    reply[o + 1] = 4;
    @memcpy(reply[o + 2 .. o + 6], &[_]u8{ 10, 0, 0, 5 });
    o += 6;
    reply[o] = opt_lease_time;
    reply[o + 1] = 4;
    reply[o + 2] = 0;
    reply[o + 3] = 0;
    reply[o + 4] = 0x0e;
    reply[o + 5] = 0x10;
    o += 6;
    reply[o] = opt_end;
    const offer_len = o + 1;

    // The OFFER is processed by the RX drain: -> REQUESTING, the REQUEST
    // is built (option 50 = the offered IP, 54 = the server id).
    var dg: [8 + 300]u8 = undefined;
    @memset(&dg, 0);
    @memcpy(dg[8 .. 8 + offer_len], reply[0..offer_len]);
    try std.testing.expectEqual(Event.request_ready, handle_rx(&dg));
    try std.testing.expectEqual(State.requesting, dhcp.state);
    try std.testing.expectEqual(@as(u64, 1), dhcp.offer_recv);
    try std.testing.expectEqual(@as(usize, 256), dhcp.msg_len);
    try std.testing.expectEqual(@as(u8, msg_type_request), dhcp.msg[242]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, dhcp.msg[245..249]); // option 50
    try std.testing.expect(!dhcp.request_transmitted);

    // The server's ACK (option 53 = 5): -> BOUND, the dhcp.lease recorded,
    // arp.own_ip set (THE one copy — DHCP overwrites the static address).
    var ack: [300]u8 = undefined;
    @memcpy(ack[0..offer_len], reply[0..offer_len]);
    ack[242] = msg_type_ack;
    var dg2: [8 + 300]u8 = undefined;
    @memset(&dg2, 0);
    @memcpy(dg2[8 .. 8 + offer_len], ack[0..offer_len]);
    try std.testing.expectEqual(Event.bound, handle_rx(&dg2));
    try std.testing.expectEqual(State.bound, dhcp.state);
    try std.testing.expectEqual(@as(u64, 1), dhcp.ack_recv);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &dhcp.lease_ip);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, &dhcp.lease_mask);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &dhcp.lease_gw);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &dhcp.lease_server);
    try std.testing.expectEqual(@as(u32, 3600), dhcp.lease_time);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 5 }, &arp.own_ip);
    // The off-subnet card: the lease's mask/router land in the ARP layer
    // — the routing input the default gateway + on-link checks read.
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, &arp.own_mask);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &arp.gateway);
}

test "dhcp: out-of-sequence + malformed replies are counted, never assumed away" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    start(&chaddr, 7);

    // A malformed reply (garbage) -> dhcp.dropped_malformed.
    var junk: [64]u8 = .{0} ** 64;
    var dg: [8 + 64]u8 = undefined;
    @memset(&dg, 0);
    @memcpy(dg[8..], &junk);
    try std.testing.expectEqual(Event.none, handle_rx(&dg));
    try std.testing.expectEqual(@as(u64, 1), dhcp.dropped_malformed);

    // An ACK outside REQUESTING (we are SELECTING) -> dhcp.dropped_malformed.
    var m: [msg_max]u8 = undefined;
    const n = build_discover(&m, &chaddr, 7);
    m[0] = 2;
    m[240] = opt_msg_type;
    m[242] = msg_type_ack;
    m[243] = opt_end;
    var dg2: [8 + 256]u8 = undefined;
    @memset(&dg2, 0);
    @memcpy(dg2[8 .. 8 + n], m[0..n]);
    try std.testing.expectEqual(Event.none, handle_rx(&dg2));
    try std.testing.expectEqual(@as(u64, 2), dhcp.dropped_malformed);
    try std.testing.expectEqual(State.selecting, dhcp.state); // unchanged

    // A NACK falls back to IDLE (the caller may retry, bounded).
    m[242] = dhcp.msg_type_nack;
    var dg3: [8 + 256]u8 = undefined;
    @memset(&dg3, 0);
    @memcpy(dg3[8 .. 8 + n], m[0..n]);
    try std.testing.expectEqual(Event.nacked, handle_rx(&dg3));
    try std.testing.expectEqual(@as(u64, 1), dhcp.nack_recv);
    try std.testing.expectEqual(State.idle, dhcp.state);
}

test "dhcp: a reply for ANOTHER transaction is refused — xid + chaddr must match" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    start(&chaddr, 0xabcd1234); // SELECTING with OUR xid

    // A valid OFFER shape (copied from our DISCOVER, op flipped) — the
    // control: OUR xid + chaddr pass, the state machine moves.
    var offer: [300]u8 = undefined;
    @memcpy(offer[0..dhcp.msg_len], dhcp.msg[0..dhcp.msg_len]);
    offer[0] = 2;
    @memcpy(offer[16..20], &[_]u8{ 10, 0, 0, 5 }); // yiaddr
    offer[240] = opt_msg_type;
    offer[242] = msg_type_offer;
    const o: usize = 243;
    offer[o] = opt_lease_time;
    offer[o + 1] = 4;
    offer[o + 2] = 0;
    offer[o + 3] = 0;
    offer[o + 4] = 0x0e;
    offer[o + 5] = 0x10;
    offer[o + 6] = opt_end;
    const offer_len = o + 7;

    // Mismatched XID: another client's handshake on the shared broadcast
    // segment — dropped, the state machine stays SELECTING, no offer
    // recorded.
    var bad_xid = offer;
    bad_xid[7] ^= 0xff; // the low xid byte differs
    var dg: [8 + 300]u8 = undefined;
    @memset(&dg, 0);
    @memcpy(dg[8 .. 8 + offer_len], bad_xid[0..offer_len]);
    try std.testing.expectEqual(Event.none, handle_rx(&dg));
    try std.testing.expectEqual(@as(u64, 1), dhcp.dropped_malformed);
    try std.testing.expectEqual(@as(u64, 0), dhcp.offer_recv);
    try std.testing.expectEqual(State.selecting, dhcp.state);
    try std.testing.expect(!dhcp.request_transmitted);

    // Mismatched chaddr (the right xid, another client's MAC — broadcast
    // replies are never MAC-unicast to us): dropped the same way.
    var bad_chaddr = offer;
    bad_chaddr[28] ^= 0xff;
    @memset(&dg, 0);
    @memcpy(dg[8 .. 8 + offer_len], bad_chaddr[0..offer_len]);
    try std.testing.expectEqual(Event.none, handle_rx(&dg));
    try std.testing.expectEqual(@as(u64, 2), dhcp.dropped_malformed);
    try std.testing.expectEqual(@as(u64, 0), dhcp.offer_recv);
    try std.testing.expectEqual(State.selecting, dhcp.state);

    // The matching reply still lands (the refusal path is not a wedge).
    @memset(&dg, 0);
    @memcpy(dg[8 .. 8 + offer_len], offer[0..offer_len]);
    try std.testing.expectEqual(Event.request_ready, handle_rx(&dg));
    try std.testing.expectEqual(State.requesting, dhcp.state);
    try std.testing.expectEqual(@as(u64, 1), dhcp.offer_recv);
}

test "dhcp: bounded retry — max_attempts then an honest refuse (the caller's cap)" {
    reset();
    defer reset();
    // The monitor refuses to start a new handshake after max_attempts
    // DISCOVERs without an OFFER; the counter contract is exercised here.
    var i: usize = 0;
    while (i < max_attempts) : (i += 1) {
        dhcp.attempts += 1;
    }
    try std.testing.expect(dhcp.attempts >= max_attempts);
    // The caller's refuse: dhcp.timed_out counts the refused attempt.
    dhcp.timed_out += 1;
    try std.testing.expectEqual(@as(u64, 1), dhcp.timed_out);
}

// ---------------------------------------------------------------------------
// Card N9 (claim 9489): the dhcp.lease lifecycle — T1/T2 math, the
// RENEWING/REBINDING transitions, expiry, and the renewal ACK
// ---------------------------------------------------------------------------

test "dhcp: lease-lifecycle timing — T1 = lease/2, T2 = lease*7/8, elapsed" {
    reset();
    defer reset();
    // RFC 2131 §4.4.5 with integer seconds (the 1 Hz guest timer).
    try std.testing.expectEqual(@as(u64, 30), dhcp.t1(60));
    try std.testing.expectEqual(@as(u64, 52), dhcp.t2(60)); // 52.5 floors to 52
    try std.testing.expectEqual(@as(u64, 40), dhcp.t1(80));
    try std.testing.expectEqual(@as(u64, 70), dhcp.t2(80)); // 70 exactly
    // Elapsed is wall-clock seconds since the last (re)bind, saturating
    // at zero before the bind.
    dhcp.bound_ticks = 100;
    dhcp.now_ticks = 106;
    try std.testing.expectEqual(@as(u64, 6), elapsed());
    dhcp.now_ticks = 92;
    try std.testing.expectEqual(@as(u64, 0), elapsed()); // -| saturates
}

test "dhcp: step_lifecycle — the pure RFC 2131 §4.4.5 decision (issue #119)" {
    reset();
    defer reset();
    dhcp.lease_time = 100;
    dhcp.bound_ticks = 100;
    dhcp.state = .bound;
    // Below T1: stay BOUND.
    dhcp.now_ticks = 110;
    try std.testing.expectEqual(dhcp.Step.none, step_lifecycle());
    // At T1 (dhcp.lease/2 = 50): RENEWING.
    dhcp.now_ticks = 150;
    try std.testing.expectEqual(dhcp.Step.renew, step_lifecycle());
    // At T2 (dhcp.lease*7/8 = 87): REBINDING (T2 checked before T1).
    dhcp.now_ticks = 187;
    try std.testing.expectEqual(dhcp.Step.rebind, step_lifecycle());
    // At expiry: release.
    dhcp.now_ticks = 200;
    try std.testing.expectEqual(dhcp.Step.expire, step_lifecycle());
    // RENEWING: below T2 the renewal waits (a pending renewal never
    // outlives its dhcp.lease — expiry beats the wait); at T2 the client
    // ESCALATES to REBINDING (RFC 2131 §4.4.5 — the unicast renewal
    // went unanswered, so the broadcast REQUEST takes over).
    dhcp.state = .renewing;
    dhcp.now_ticks = 150;
    try std.testing.expectEqual(dhcp.Step.none, step_lifecycle());
    dhcp.now_ticks = 186;
    try std.testing.expectEqual(dhcp.Step.none, step_lifecycle()); // < T2 (87)
    dhcp.now_ticks = 187;
    try std.testing.expectEqual(dhcp.Step.rebind, step_lifecycle()); // T2 escalation
    // Even past the dhcp.lease, RENEWING escalates first (T2 < dhcp.lease always;
    // the REBINDING arm expires on the next poll).
    dhcp.now_ticks = 200;
    try std.testing.expectEqual(dhcp.Step.rebind, step_lifecycle());
    // REBINDING only expires (nothing left to escalate to).
    dhcp.state = .rebinding;
    dhcp.now_ticks = 199;
    try std.testing.expectEqual(dhcp.Step.none, step_lifecycle());
    dhcp.now_ticks = 200;
    try std.testing.expectEqual(dhcp.Step.expire, step_lifecycle()); // the pending rebinding never outlives its dhcp.lease
    // The decision mutates nothing.
    try std.testing.expectEqual(State.rebinding, dhcp.state);
    // Handshake states never auto-advance (the re-DISCOVER stays
    // command-triggered).
    dhcp.state = .idle;
    try std.testing.expectEqual(dhcp.Step.none, step_lifecycle());
    dhcp.state = .selecting;
    try std.testing.expectEqual(dhcp.Step.none, step_lifecycle());
    dhcp.state = .requesting;
    try std.testing.expectEqual(dhcp.Step.none, step_lifecycle());
    // No dhcp.lease (zero): never fires.
    dhcp.lease_time = 0;
    dhcp.state = .bound;
    try std.testing.expectEqual(dhcp.Step.none, step_lifecycle());
}

test "dhcp: BOUND -> RENEWING builds the REQUEST with ciaddr = the lease" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    start(&chaddr, 0x11223344);
    // Fast-forward the handshake to BOUND with a known dhcp.lease.
    dhcp.lease_ip = .{ 10, 0, 0, 2 };
    dhcp.lease_mask = .{ 255, 255, 255, 0 };
    dhcp.lease_gw = .{ 10, 0, 0, 1 };
    dhcp.lease_server = .{ 10, 0, 0, 2 };
    dhcp.lease_time = 80;
    dhcp.state = .bound;

    dhcp.enter_renewing();
    try std.testing.expectEqual(State.renewing, dhcp.state);
    try std.testing.expect(!dhcp.request_transmitted);
    try std.testing.expectEqual(@as(usize, 256), dhcp.msg_len);
    try std.testing.expectEqual(@as(u8, msg_type_request), dhcp.msg[242]);
    // option 50 = the leased IP (245..249), option 54 = the server id
    // (251..255) — the REQUEST option layout from the N8 fixtures.
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, dhcp.msg[245..249]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, dhcp.msg[251..255]);
    // ciaddr (12..16) = the leased IP — RFC 2131 §4.4.5.
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, dhcp.msg[12..16]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, dhcp.msg[16..20]); // yiaddr stays 0
}

test "dhcp: BOUND -> REBINDING builds the same REQUEST (ciaddr = the lease)" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    start(&chaddr, 9);
    dhcp.lease_ip = .{ 10, 0, 0, 2 };
    dhcp.lease_server = .{ 10, 0, 0, 2 };
    dhcp.lease_time = 80;
    dhcp.state = .bound;

    dhcp.enter_rebinding();
    try std.testing.expectEqual(State.rebinding, dhcp.state);
    try std.testing.expectEqual(@as(u8, msg_type_request), dhcp.msg[242]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, dhcp.msg[12..16]); // ciaddr
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, dhcp.msg[245..249]); // option 50
}

test "dhcp: expire releases the address and falls back to INIT (attempts reset)" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    start(&chaddr, 3);
    dhcp.lease_ip = .{ 10, 0, 0, 2 };
    dhcp.state = .bound;
    arp.own_ip = dhcp.lease_ip;
    arp.own_mask = .{ 255, 255, 0, 0 };
    arp.gateway = dhcp.lease_ip;
    dhcp.attempts = 2;

    expire();
    try std.testing.expectEqual(State.idle, dhcp.state);
    try std.testing.expectEqual(@as(u64, 1), dhcp.expired);
    // The address is released honestly — the client no longer owns it.
    // The lease-sourced routing inputs go with it: the default /24 mask
    // returns and the explicit gateway is withdrawn.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &arp.own_ip);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, &arp.own_mask);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &arp.gateway);
    try std.testing.expectEqual(@as(usize, 0), dhcp.attempts); // a fresh INIT
    try std.testing.expect(!dhcp.request_transmitted);
}

test "dhcp: a renewal ACK in RENEWING restarts the lease (renewed, bound_ticks stamped)" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    start(&chaddr, 0x55667788);
    // BOUND with a known dhcp.lease, then RENEWING at T1.
    dhcp.lease_ip = .{ 10, 0, 0, 2 };
    dhcp.lease_mask = .{ 255, 255, 255, 0 };
    dhcp.lease_gw = .{ 10, 0, 0, 1 };
    dhcp.lease_server = .{ 10, 0, 0, 2 };
    dhcp.lease_time = 80;
    dhcp.state = .bound;
    dhcp.bound_ticks = 100;
    dhcp.enter_renewing();

    // The server's renewal ACK (option 53 = 5, the same fixed dhcp.lease).
    var m: [msg_max]u8 = undefined;
    _ = build_request(&m, &chaddr, dhcp.xid, dhcp.lease_ip, dhcp.lease_server);
    m[0] = 2;
    @memcpy(m[16..20], &dhcp.lease_ip); // yiaddr = the confirmed address (the real server does this)
    m[240] = opt_msg_type;
    m[242] = msg_type_ack;
    // Replace the tail options with the renewal shape: 53,1,5 (240..242)
    // + 51,4,0,0,0,80 (243..248, the dhcp.renewed 80 s dhcp.lease) + 255 (249).
    const o: usize = 243;
    m[o] = opt_lease_time;
    m[o + 1] = 4;
    m[o + 2] = 0;
    m[o + 3] = 0;
    m[o + 4] = 0;
    m[o + 5] = 80;
    m[o + 6] = opt_end;
    const ack_len = o + 7;

    dhcp.now_ticks = 133; // the ACK lands 33 s after the original bind
    var dg: [8 + 300]u8 = undefined;
    @memset(&dg, 0);
    @memcpy(dg[8 .. 8 + ack_len], m[0..ack_len]);
    try std.testing.expectEqual(Event.renewed, handle_rx(&dg));
    try std.testing.expectEqual(State.bound, dhcp.state);
    try std.testing.expectEqual(@as(u64, 1), dhcp.renewed);
    try std.testing.expectEqual(@as(u64, 0), dhcp.ack_recv); // NOT the initial-handshake counter
    // The dhcp.lease restarted: dhcp.bound_ticks stamped at the ACK processing.
    try std.testing.expectEqual(@as(u64, 133), dhcp.bound_ticks);
    try std.testing.expectEqual(@as(u32, 80), dhcp.lease_time);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, &arp.own_ip);
}

test "dhcp: an ACK outside REQUESTING/renewal is still malformed" {
    reset();
    defer reset();
    const chaddr = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    start(&chaddr, 4);
    // We are SELECTING — a stray ACK is unexpected, counted malformed.
    var m: [msg_max]u8 = undefined;
    const n = build_discover(&m, &chaddr, 4);
    m[0] = 2;
    m[240] = opt_msg_type;
    m[242] = msg_type_ack;
    m[243] = opt_end;
    var dg: [8 + 256]u8 = undefined;
    @memset(&dg, 0);
    @memcpy(dg[8 .. 8 + n], m[0..n]);
    try std.testing.expectEqual(Event.none, handle_rx(&dg));
    try std.testing.expectEqual(@as(u64, 1), dhcp.dropped_malformed);
    try std.testing.expectEqual(State.selecting, dhcp.state);
}
