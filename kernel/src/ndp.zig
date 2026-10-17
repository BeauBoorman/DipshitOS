//! NDP (RFC 4861, bounded) — M117b (issue #2474, ADR 0057 D4/D5):
//! NS/NA/RS/RA, the 4-slot neighbor table, solicited-only learning,
//! one-probe DAD, and the bounded 3-send Router Solicitation train — in
//! `arp.zig`'s exact shape. PURE protocol logic + host tests (the
//! fat.zig pattern); virtio_net.zig drives the sends (`net_ndp_poll`)
//! and ipv6.zig's ICMPv6 dispatch delivers inbound NDP messages here.
//!
//! Honest bounds: no NUD state machine (INCOMPLETE/REACHABLE/STALE/
//! DELAY/PROBE are documented-not-implemented — the ARP no-expiry
//! precedent; the table bound and the pending slot are the whole
//! state); ONE pending solicitation — a Neighbor Advertisement is
//! learned only when it carries S=1 and its target matches it (the
//! M97e-F3 precedent: an on-link host cannot overwrite the router
//! mapping); unsolicited NAs and Redirects are counted drops, never
//! learned; RSs are never answered (the guest is a host, not a router);
//! the router record is RA-only; DAD is ONE probe per formed address
//! and ONE bounded wait on the tick seam.

const std = @import("std");
const ipv6 = @import("ipv6.zig");

pub const icmpv6_rs: u8 = 133;
pub const icmpv6_ra: u8 = 134;
pub const icmpv6_ns: u8 = 135;
pub const icmpv6_na: u8 = 136;
pub const icmpv6_redirect: u8 = 137;

pub const eth_hdr_len: usize = 14;
pub const ipv6_hdr_len: usize = 40;
/// ICMPv6 message lengths (type + code + checksum included).
pub const rs_msg_len: usize = 8 + 8; // reserved(4) + SLLA(8)
pub const ns_msg_len: usize = 8 + 16 + 8; // reserved(4) + target(16) + SLLA(8)
pub const dad_ns_msg_len: usize = 8 + 16; // DAD: src ::, no SLLA (no source to advertise)
pub const na_msg_len: usize = 8 + 16 + 8; // flags(4) + target(16) + TLLA(8)
/// D4: the bounded RA option walk — a malformed length or a longer walk
/// refuses the whole RA, never a partial trust.
pub const ra_opt_max: usize = 8;
/// D4: the bounded Router Solicitation train.
pub const rs_max: u64 = 3;
/// D5: the bounded neighbor table (the ARP `table_slots` precedent).
pub const ndp_slots: usize = 4;
/// D5: the one bounded DAD wait on the tick seam (1 Hz ticks).
pub const dad_wait_ticks: u64 = 1;

/// The largest NDP frame we build: eth(14) + v6(40) + NS msg(32) = 86.
pub const frame_len_max: usize = eth_hdr_len + ipv6_hdr_len + ns_msg_len;

// ---------------------------------------------------------------------------
// The bounded neighbor table + the ONE pending solicitation (D5)
// ---------------------------------------------------------------------------

pub const NdpEntry = struct {
    valid: bool = false,
    addr: ipv6.Addr = @splat(0),
    mac: [6]u8 = @splat(0),
};

/// The bounded peer table (v6 address -> hardware address): round-robin
/// drop-oldest, no expiry (the ARP precedent — documented, not assumed).
pub var table: [ndp_slots]NdpEntry = @as([ndp_slots]NdpEntry, @splat(@as(NdpEntry, .{})));
pub var table_cursor: usize = 0;

/// The ONE outstanding solicitation — set by `build_ns` (the wire-
/// request funnel: every resolve asks "who has THIS target", already
/// the NEXT-HOP resolution for an off-link destination) and cleared
/// when its matching NA is learned. M97e-F3: a solicited NA is learned
/// ONLY against this; an unsolicited NA (gratuitous or forged — an
/// on-link host racing to overwrite the router mapping) is counted and
/// dropped, never upserted.
pub var pending_na: ?ipv6.Addr = null;

// ---------------------------------------------------------------------------
// The bounded RS train + one-probe DAD state (D4/D5 — the tick seam)
// ---------------------------------------------------------------------------

/// The 1 Hz tick clock — stamped by the caller each poll (the
/// `dhcp.now_ticks` precedent).
pub var now_ticks: u64 = 0;

/// The bounded RS train: armed once RX arms (`net: rx-armed`); one RS
/// per tick poll while `rs_sent < rs_max` and the link-local is valid
/// (it is the RS's source — a tentative source never goes on the wire).
pub var rs_active: bool = false;
pub var rs_last_tick: u64 = 0;

/// The one-probe DAD records: per address, whether its NS went out and
/// at which tick. A tentative address promotes once the wait elapsed
/// unanswered (D5's one probe, one wait — not the full RFC retransmit
/// schedule; the controlled links make deeper paranoia unobservable).
pub var dad_ll_sent: bool = false;
pub var dad_ll_tick: u64 = 0;
pub var dad_g6_sent: bool = false;
pub var dad_g6_tick: u64 = 0;

/// The recorded-never-acted RA fields (D4): the last accepted RA's M/O
/// flags and the global-forming PIO's lifetimes — report-only (no
/// DHCPv6 client exists; address/router expiry timers are
/// documented-not-implemented, the ARP no-expiry precedent).
pub var ra_flags: u8 = 0;
pub var pio_valid_lifetime: u32 = 0;
pub var pio_preferred_lifetime: u32 = 0;

/// The last DAD conflict observed (the address claimed twice) — the
/// autonomous poll's transition print consumes it.
pub var last_conflict: ?ipv6.Addr = null;

// ---------------------------------------------------------------------------
// Counters (the `net` report's ndp= line)
// ---------------------------------------------------------------------------

pub var rs_sent: u64 = 0; // Router Solicitations transmitted (the bounded train)
pub var rs_dropped: u64 = 0; // inbound RSs — hosts never answer solicitations
pub var ra_accepted: u64 = 0; // RAs passing every D4 check
pub var ra_foreign: u64 = 0; // RAs from a different source once a router is recorded
pub var ra_malformed: u64 = 0; // non-link-local src, bad option length, >8 options
pub var opt_skipped: u64 = 0; // non-/64-A / non-first / unknown options
pub var ns_sent: u64 = 0; // resolution solicitations (DAD probes count in dad_sent)
pub var na_sent: u64 = 0; // answers to NSs for owned addresses
pub var learned: u64 = 0; // table upserts from solicited NAs
pub var na_unsolicited: u64 = 0; // NAs not matching the pending solicitation
pub var ndp_drop: u64 = 0; // malformed / hop!=255 / not-for-us NDP messages
pub var redirect_dropped: u64 = 0; // Redirects — never honored (RA-only router record)
pub var dad_sent: u64 = 0; // DAD probes transmitted
pub var dad_conflicts: u64 = 0; // a peer's NS/NA claimed a tentative target
pub var reply_tx_fail: u64 = 0; // replies we built but could not transmit

// ---------------------------------------------------------------------------
// Table (arp.zig's exact shape)
// ---------------------------------------------------------------------------

/// The learned MAC for a v6 address — already the next-hop answer for
/// an off-link destination (the caller resolves `ipv6.next_hop` first).
pub fn lookup(addr: *const ipv6.Addr) ?[6]u8 {
    for (&table) |*e| {
        if (e.valid and std.mem.eql(u8, &e.addr, addr)) return e.mac;
    }
    return null;
}

/// Upsert (v6 address -> hardware address): update in place on a hit,
/// else the first free slot, else drop the oldest via the round-robin
/// cursor. No expiry (the documented honest bound).
pub fn upsert(addr: *const ipv6.Addr, mac: [6]u8) void {
    for (&table) |*e| {
        if (e.valid and std.mem.eql(u8, &e.addr, addr)) {
            e.mac = mac;
            return;
        }
    }
    for (&table) |*e| {
        if (!e.valid) {
            e.valid = true;
            e.addr = addr.*;
            e.mac = mac;
            return;
        }
    }
    const slot = &table[table_cursor];
    table_cursor = (table_cursor + 1) % ndp_slots;
    slot.valid = true;
    slot.addr = addr.*;
    slot.mac = mac;
}

// ---------------------------------------------------------------------------
// Builders (byte-exact; hop_limit 255 in every NDP message — D5)
// ---------------------------------------------------------------------------

/// The shared frame prefix: Ethernet dst/src + the 40-byte fixed header
/// (version 6, payload_len, next-header 58, hop_limit 255 — the NDP
/// standing check in both directions).
fn build_hdr(buf: []u8, dst_mac: *const [6]u8, own_mac: *const [6]u8, src: *const ipv6.Addr, dst: *const ipv6.Addr, msg_len: u16) void {
    @memset(buf[0 .. eth_hdr_len + ipv6_hdr_len + msg_len], 0);
    @memcpy(buf[0..6], dst_mac);
    @memcpy(buf[6..12], own_mac);
    buf[12] = 0x86;
    buf[13] = 0xdd;
    buf[14] = 0x60; // version 6, TC/flow zero
    std.mem.writeInt(u16, buf[18..20], msg_len, .big);
    buf[20] = ipv6.nexthdr_icmpv6;
    buf[21] = 255;
    @memcpy(buf[22..38], src);
    @memcpy(buf[38..54], dst);
}

/// Recompute the ICMPv6 pseudo-header checksum over the message just
/// built (the checksum field stays zeroed during the computation).
fn finish_checksum(buf: []u8, msg_len: usize) void {
    var src: ipv6.Addr = undefined;
    var dst: ipv6.Addr = undefined;
    @memcpy(&src, buf[22..38]);
    @memcpy(&dst, buf[38..54]);
    const chk = ipv6.icmp6_checksum(&src, &dst, buf[54 .. 54 + msg_len], ipv6.nexthdr_icmpv6);
    std.mem.writeInt(u16, buf[56..58], chk, .big);
}

/// Build a ROUTER SOLICITATION (ICMPv6 type 133): dst all-routers
/// ff02::2 / 33:33:00:00:00:02, src our link-local, hop 255, SLLA = our
/// MAC. D4's bounded train — the caller counts `rs_sent` on TX ok.
/// Returns the frame length (70).
pub fn build_rs(buf: []u8, own_mac: *const [6]u8, src_ll: *const ipv6.Addr) usize {
    const frame_len = eth_hdr_len + ipv6_hdr_len + rs_msg_len; // 70
    build_hdr(buf, &ipv6.all_routers_mac, own_mac, src_ll, &ipv6.all_routers, rs_msg_len);
    const m = buf[54 .. 54 + rs_msg_len];
    m[0] = icmpv6_rs;
    // code 0, checksum (recomputed below), reserved 4 — zeroed by build_hdr.
    m[8] = 1; // SLLA option type
    m[9] = 1; // length 1 (units of 8)
    @memcpy(m[10..16], own_mac);
    finish_checksum(buf, rs_msg_len);
    return frame_len;
}

/// Build a NEIGHBOR SOLICITATION (ICMPv6 type 135) resolving `target`:
/// dst the target's solicited-node group (33:33:ff:xx:xx:xx /
/// ff02::1:ffXX:XXXX), src our link-local, hop 255, the target field,
/// SLLA = our MAC. Sets `pending_na` — the ONE outstanding solicitation
/// (a second request supersedes the first, the `arp.pending_reply`
/// precedent). Returns the frame length (86).
pub fn build_ns(buf: []u8, own_mac: *const [6]u8, src_ll: *const ipv6.Addr, target: *const ipv6.Addr) usize {
    const dst_ip = ipv6.snm_addr(target);
    const dst_mac = ipv6.snm_mac(target);
    const frame_len = eth_hdr_len + ipv6_hdr_len + ns_msg_len; // 86
    build_hdr(buf, &dst_mac, own_mac, src_ll, &dst_ip, ns_msg_len);
    const m = buf[54 .. 54 + ns_msg_len];
    m[0] = icmpv6_ns;
    @memcpy(m[8..24], target);
    m[24] = 1; // SLLA
    m[25] = 1;
    @memcpy(m[26..32], own_mac);
    pending_na = target.*; // the solicitation for `target` is now outstanding (M97e-F3)
    finish_checksum(buf, ns_msg_len);
    return frame_len;
}

/// Build a DAD NEIGHBOR SOLICITATION (D5's one probe): v6 src ::, dst
/// the tentative address's solicited-node group, NO SLLA (the
/// unspecified source advertises nothing — the Ethernet src stays our
/// MAC), hop 255, target = the tentative address. Does NOT touch
/// `pending_na` — DAD is not a resolution. Returns 78.
pub fn build_dad_ns(buf: []u8, own_mac: *const [6]u8, target: *const ipv6.Addr) usize {
    const dst_ip = ipv6.snm_addr(target);
    const dst_mac = ipv6.snm_mac(target);
    const frame_len = eth_hdr_len + ipv6_hdr_len + dad_ns_msg_len; // 78
    build_hdr(buf, &dst_mac, own_mac, &ipv6.addr_unspecified, &dst_ip, dad_ns_msg_len);
    const m = buf[54 .. 54 + dad_ns_msg_len];
    m[0] = icmpv6_ns;
    @memcpy(m[8..24], target);
    finish_checksum(buf, dad_ns_msg_len);
    return frame_len;
}

/// Build the NEIGHBOR ADVERTISEMENT (ICMPv6 type 136) answering the NS
/// in `req` (a received frame): dst = the request's observed Ethernet
/// source — never a parsed option (D5); dst addr = the NS's src (the
/// all-nodes group ff02::1 when it was :: — the DAD answer shape); src
/// = the solicited target (OUR address), flags S|O, target echoed,
/// TLLA = our MAC, hop 255. Returns the frame length (86).
pub fn build_na_reply(buf: []u8, own_mac: *const [6]u8, req: []const u8) usize {
    const req_src = ipv6.src_addr(req);
    var target: ipv6.Addr = undefined;
    @memcpy(&target, req[62..78]);
    const unspecified = ipv6.is_unspecified(req_src);
    const dst_ip = if (unspecified) ipv6.all_nodes else req_src;
    var dst_mac: [6]u8 = undefined;
    if (unspecified) {
        dst_mac = ipv6.all_nodes_mac;
    } else {
        @memcpy(&dst_mac, req[6..12]);
    }
    const frame_len = eth_hdr_len + ipv6_hdr_len + na_msg_len; // 86
    build_hdr(buf, &dst_mac, own_mac, &target, &dst_ip, na_msg_len);
    const m = buf[54 .. 54 + na_msg_len];
    m[0] = icmpv6_na;
    m[4] = 0x60; // flags S|O (solicited + override — bits 30/29 of the u32)
    @memcpy(m[8..24], &target);
    m[24] = 2; // TLLA option type
    m[25] = 1; // length 1
    @memcpy(m[26..32], own_mac);
    finish_checksum(buf, na_msg_len);
    return frame_len;
}

// ---------------------------------------------------------------------------
// Inbound handling (D4/D5) — the caller already verified the ethertype,
// the fixed header, the dst gate, the ICMPv6 checksum, and hop_limit 255.
// ---------------------------------------------------------------------------

/// Router Advertisement (D4): a link-local source is required; a foreign
/// source once a router is recorded is `ra_foreign`, counted and ignored
/// wholesale — before any option is trusted. The option walk is bounded
/// (≤ `ra_opt_max`, every length checked — a malformed length or a
/// trailing partial refuses the WHOLE RA, `ra_malformed`, never a
/// partial trust). The first A-flag /64 PIO forms the global under D3
/// (a non-/64 A-flag prefix is `opt_skipped`, never truncated into an
/// address); the same option's L flag marks the prefix on-link (D9).
/// The M/O flags and the PIO lifetimes are recorded, never acted on.
/// The source becomes the ONE router record iff router lifetime > 0; a
/// repeat RA from the accepted source refreshes the record.
pub fn handle_ra(frame: []const u8) void {
    const src = ipv6.src_addr(frame);
    if (!ipv6.is_link_local(src)) {
        ra_malformed += 1;
        return;
    }
    const plen = ipv6.payload_len(frame);
    const msg = frame[54 .. 54 + plen];
    if (msg.len < 16) {
        ra_malformed += 1; // the fixed RA part is 16 bytes
        return;
    }
    // The foreign check precedes any trust in the options — a different
    // source is ignored wholesale once a router is recorded.
    if (ipv6.router_valid and !std.mem.eql(u8, &src, &ipv6.router_addr)) {
        ra_foreign += 1;
        return;
    }
    // Bounded option walk — the decision is collected BEFORE applying:
    // a malformed length anywhere refuses the whole RA.
    var off: usize = 16;
    var opts: usize = 0;
    var form_pio = false;
    var onlink = false;
    var vl: u32 = 0;
    var pl: u32 = 0;
    var prefix: ipv6.Addr = @splat(0);
    var skipped: u64 = 0;
    while (off + 2 <= msg.len) {
        const otype = msg[off];
        const olen = @as(usize, msg[off + 1]) * 8;
        if (olen == 0 or off + olen > msg.len) {
            ra_malformed += 1;
            return;
        }
        opts += 1;
        if (opts > ra_opt_max) {
            ra_malformed += 1;
            return;
        }
        if (otype == 3 and olen >= 32) { // Prefix Information option
            const pfx_len = msg[off + 2];
            const pflags = msg[off + 3];
            const autonomous = (pflags & 0x40) != 0;
            if (autonomous and pfx_len == 64 and !form_pio and ipv6.global_state == .none) {
                form_pio = true;
                onlink = (pflags & 0x80) != 0;
                vl = (@as(u32, msg[off + 4]) << 24) | (@as(u32, msg[off + 5]) << 16) | (@as(u32, msg[off + 6]) << 8) | msg[off + 7];
                pl = (@as(u32, msg[off + 8]) << 24) | (@as(u32, msg[off + 9]) << 16) | (@as(u32, msg[off + 10]) << 8) | msg[off + 11];
                @memcpy(&prefix, msg[off + 16 .. off + 32]);
            } else {
                // A non-/64 A-flag prefix, a non-A PIO, a second usable
                // PIO (one global, ever), or an undersized PIO — skipped,
                // never truncated into an address.
                skipped += 1;
            }
        } else {
            skipped += 1; // RDNSS (type 25) + every unknown option (D4)
        }
        off += olen;
    }
    if (off != msg.len) {
        ra_malformed += 1; // a trailing partial option
        return;
    }
    opt_skipped += skipped;
    ra_flags = msg[5]; // M/O — recorded, never acted on
    ra_accepted += 1;
    if (form_pio) {
        ipv6.form_global(&prefix);
        pio_valid_lifetime = vl;
        pio_preferred_lifetime = pl;
        if (onlink) {
            ipv6.onlink_valid = true;
            ipv6.onlink_prefix = prefix;
            ipv6.onlink_len = 64;
        }
    }
    // The ONE router record (D4): the source iff lifetime > 0 when no
    // router is recorded; a repeat RA from the accepted source refreshes
    // the record — including a 0 lifetime, the honest withdrawal.
    const lifetime = std.mem.readInt(u16, msg[6..8], .big);
    if (!ipv6.router_valid) {
        if (lifetime > 0) {
            ipv6.router_valid = true;
            ipv6.router_addr = src;
            ipv6.router_lifetime = lifetime;
        }
    } else {
        ipv6.router_lifetime = lifetime;
    }
}

/// Neighbor Solicitation (D5): a tentative target is a DAD conflict; an
/// NS for any other target is `ndp_drop`; an NS for an OWNED address is
/// answered with an NA built into `reply_buf` (the caller transmits it —
/// dst = the frame's observed Ethernet source, never a parsed option).
pub fn handle_ns(frame: []const u8, own_mac: *const [6]u8, reply_buf: []u8) ?usize {
    if (ipv6.payload_len(frame) < 24) {
        ndp_drop += 1; // too short to carry the target
        return null;
    }
    var target: ipv6.Addr = undefined;
    @memcpy(&target, frame[62..78]);
    if (ipv6.is_tentative(&target)) {
        dad_conflicts += 1;
        ipv6.mark_conflicted(&target);
        last_conflict = target;
        return null;
    }
    if (!ipv6.is_owned(&target)) {
        ndp_drop += 1;
        return null;
    }
    return build_na_reply(reply_buf, own_mac, frame);
}

/// Neighbor Advertisement (D5): a tentative target is a DAD conflict;
/// S=1 + the target matching the pending solicitation is learned into
/// the bounded table (the M97e-F3 solicited-only rule); everything else
/// is `na_unsolicited` — an on-link host cannot overwrite the router
/// mapping.
pub fn handle_na(frame: []const u8) void {
    if (ipv6.payload_len(frame) < 24) {
        ndp_drop += 1;
        return;
    }
    var target: ipv6.Addr = undefined;
    @memcpy(&target, frame[62..78]);
    if (ipv6.is_tentative(&target)) {
        dad_conflicts += 1;
        ipv6.mark_conflicted(&target);
        last_conflict = target;
        return;
    }
    const flags = std.mem.readInt(u32, frame[58..62], .big);
    const solicited = (flags & 0x4000_0000) != 0;
    if (solicited and pending_na != null and std.mem.eql(u8, &pending_na.?, &target)) {
        var smac: [6]u8 = undefined;
        @memcpy(&smac, frame[6..12]); // the observed source, not a parsed option
        upsert(&target, smac);
        learned += 1;
        pending_na = null;
        return;
    }
    na_unsolicited += 1;
}

// ---------------------------------------------------------------------------
// The tick-seam drive (D4/D5) — pure state; the transport sends
// ---------------------------------------------------------------------------

pub const DadSlot = enum { ll, g6 };

/// Which tentative address needs its one DAD probe sent (null = none).
/// The transport builds + transmits, then calls `dad_mark_sent`.
pub fn dad_pending() ?struct { addr: ipv6.Addr, slot: DadSlot } {
    if (ipv6.link_local_state == .tentative and !dad_ll_sent) return .{ .addr = ipv6.link_local, .slot = .ll };
    if (ipv6.global_state == .tentative and !dad_g6_sent) return .{ .addr = ipv6.global, .slot = .g6 };
    return null;
}

/// Record the probe's send tick — the wait starts at transmission.
pub fn dad_mark_sent(slot: DadSlot) void {
    switch (slot) {
        .ll => {
            dad_ll_sent = true;
            dad_ll_tick = now_ticks;
        },
        .g6 => {
            dad_g6_sent = true;
            dad_g6_tick = now_ticks;
        },
    }
}

/// Which tentative address's bounded wait elapsed unanswered — the
/// transport promotes it via `ipv6.promote` (D5's one probe, one wait).
pub fn dad_due() ?ipv6.Addr {
    if (ipv6.link_local_state == .tentative and dad_ll_sent and now_ticks -| dad_ll_tick >= dad_wait_ticks) return ipv6.link_local;
    if (ipv6.global_state == .tentative and dad_g6_sent and now_ticks -| dad_g6_tick >= dad_wait_ticks) return ipv6.global;
    return null;
}

/// The bounded RS train (D4): one RS per tick while `rs_sent < rs_max`
/// — and only once the link-local is usable (it is the RS's source; a
/// tentative source never goes on the wire).
pub fn rs_due() bool {
    return rs_active and rs_sent < rs_max and ipv6.link_local_state == .valid and now_ticks > rs_last_tick;
}

/// Called when the RX buffer arms (`net: rx-armed`) — the train starts.
/// Idempotent (the drain re-arms after every completion).
pub fn rx_armed() void {
    rs_active = true;
}

/// Record one RS transmit — the next one waits a tick.
pub fn rs_note_sent() void {
    rs_sent += 1;
    rs_last_tick = now_ticks;
}

// ---------------------------------------------------------------------------
// Host tests — pure logic, byte-exact against the RFC fixtures
// ---------------------------------------------------------------------------

const test_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }; // the host-set guest MAC
const host_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 }; // the hermetic host peer
const test_ll = ipv6.Addr{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x01 };
const test_g6 = ipv6.Addr{ 0x20, 0x01, 0x0d, 0xb8, 0, 0x64, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x01 };
const host_ll = ipv6.Addr{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x02 };
const host_g6 = ipv6.Addr{ 0x20, 0x01, 0x0d, 0xb8, 0, 0x64, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0x02 };
const test_pfx = ipv6.Addr{ 0x20, 0x01, 0x0d, 0xb8, 0, 0x64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

fn reset() void {
    table = @splat(@as(NdpEntry, .{}));
    table_cursor = 0;
    pending_na = null;
    now_ticks = 0;
    rs_active = false;
    rs_last_tick = 0;
    dad_ll_sent = false;
    dad_ll_tick = 0;
    dad_g6_sent = false;
    dad_g6_tick = 0;
    ra_flags = 0;
    pio_valid_lifetime = 0;
    pio_preferred_lifetime = 0;
    last_conflict = null;
    rs_sent = 0;
    rs_dropped = 0;
    ra_accepted = 0;
    ra_foreign = 0;
    ra_malformed = 0;
    opt_skipped = 0;
    ns_sent = 0;
    na_sent = 0;
    learned = 0;
    na_unsolicited = 0;
    ndp_drop = 0;
    redirect_dropped = 0;
    dad_sent = 0;
    dad_conflicts = 0;
    reply_tx_fail = 0;
    // The address set lives in ipv6 — reset it too (one fixture).
    ipv6.iid = @splat(0);
    ipv6.have_iid = false;
    ipv6.link_local = @splat(0);
    ipv6.link_local_state = .none;
    ipv6.global = @splat(0);
    ipv6.global_state = .none;
    ipv6.router_valid = false;
    ipv6.router_addr = @splat(0);
    ipv6.router_lifetime = 0;
    ipv6.onlink_valid = false;
    ipv6.onlink_prefix = @splat(0);
    ipv6.onlink_len = 0;
}

fn form_pair() void {
    ipv6.form_link_local(&test_mac);
    _ = ipv6.promote(&ipv6.link_local);
    ipv6.form_global(&test_pfx);
    _ = ipv6.promote(&ipv6.global);
}

/// Build an RA frame the way the hermetic responder does: dst all-nodes,
/// src `src_ll`, hop 255, type 134, the given lifetime + options tail.
fn build_ra(buf: []u8, dst_mac: *const [6]u8, src_mac: *const [6]u8, src_ll: *const ipv6.Addr, dst_addr: *const ipv6.Addr, lifetime: u16, options: []const u8) usize {
    const msg_len = 16 + options.len;
    @memset(buf[0 .. eth_hdr_len + ipv6_hdr_len + msg_len], 0);
    @memcpy(buf[0..6], dst_mac);
    @memcpy(buf[6..12], src_mac);
    buf[12] = 0x86;
    buf[13] = 0xdd;
    buf[14] = 0x60;
    std.mem.writeInt(u16, buf[18..20], @intCast(msg_len), .big);
    buf[20] = ipv6.nexthdr_icmpv6;
    buf[21] = 255;
    @memcpy(buf[22..38], src_ll);
    @memcpy(buf[38..54], dst_addr);
    const m = buf[54 .. 54 + msg_len];
    m[0] = icmpv6_ra;
    m[4] = 64; // cur hop limit field
    std.mem.writeInt(u16, m[6..8], lifetime, .big);
    @memcpy(m[16 .. 16 + options.len], options);
    const chk = ipv6.icmp6_checksum(src_ll, dst_addr, m, ipv6.nexthdr_icmpv6);
    std.mem.writeInt(u16, m[2..4], chk, .big);
    return eth_hdr_len + ipv6_hdr_len + msg_len;
}

/// The A+L /64 PIO for `prefix` (32 bytes — the responder's shape).
fn pio(prefix: *const ipv6.Addr, pfx_len: u8, flags: u8) [32]u8 {
    var o: [32]u8 = @splat(0);
    o[0] = 3;
    o[1] = 4; // length 4 (32 bytes)
    o[2] = pfx_len;
    o[3] = flags;
    std.mem.writeInt(u32, o[4..8], 86400, .big);
    std.mem.writeInt(u32, o[8..12], 14400, .big);
    @memcpy(o[16..32], prefix);
    return o;
}

test "ndp: build_rs is byte-exact + checksum verifies" {
    reset();
    var buf: [frame_len_max]u8 = undefined;
    const n = build_rs(&buf, &test_mac, &test_ll);
    try std.testing.expectEqual(@as(usize, 70), n);
    // Ethernet: all-routers dst, our MAC src, 0x86dd.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x02 }, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &test_mac, buf[6..12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x86, 0xdd }, buf[12..14]);
    // v6: plen 16, nh 58, hop 255, src ll, dst ff02::2.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x10 }, buf[18..20]);
    try std.testing.expectEqual(@as(u8, 58), buf[20]);
    try std.testing.expectEqual(@as(u8, 255), buf[21]);
    try std.testing.expectEqualSlices(u8, &test_ll, buf[22..38]);
    try std.testing.expectEqualSlices(u8, &ipv6.all_routers, buf[38..54]);
    // ICMPv6: type 133, reserved 0, SLLA type 1 len 1 + our MAC.
    try std.testing.expectEqual(@as(u8, 133), buf[54]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, buf[58..62]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1 }, buf[62..64]);
    try std.testing.expectEqualSlices(u8, &test_mac, buf[64..70]);
    var src: ipv6.Addr = undefined;
    var dst: ipv6.Addr = undefined;
    @memcpy(&src, buf[22..38]);
    @memcpy(&dst, buf[38..54]);
    try std.testing.expectEqual(@as(u16, 0), ipv6.icmp6_checksum(&src, &dst, buf[54..70], ipv6.nexthdr_icmpv6));
}

test "ndp: build_ns + pending_na; build_dad_ns leaves pending untouched" {
    reset();
    ipv6.form_link_local(&test_mac);
    _ = ipv6.promote(&ipv6.link_local);
    var buf: [frame_len_max]u8 = undefined;
    const n = build_ns(&buf, &test_mac, &test_ll, &host_g6);
    try std.testing.expectEqual(@as(usize, 86), n);
    // dst = the target's solicited-node group.
    try std.testing.expectEqualSlices(u8, &ipv6.snm_mac(&host_g6), buf[0..6]);
    try std.testing.expectEqualSlices(u8, &ipv6.snm_addr(&host_g6), buf[38..54]);
    try std.testing.expectEqual(@as(u8, 135), buf[54]);
    try std.testing.expectEqualSlices(u8, &host_g6, buf[62..78]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1 }, buf[78..80]); // SLLA
    try std.testing.expectEqualSlices(u8, &test_mac, buf[80..86]);
    try std.testing.expectEqual(@as(u8, 255), buf[21]);
    // The solicitation is now pending — the ONE slot.
    try std.testing.expect(pending_na != null);
    try std.testing.expectEqualSlices(u8, &host_g6, &pending_na.?);
    // A second solicitation supersedes the first.
    const other = ipv6.parse_ip6("2001:db8:64::99").?;
    _ = build_ns(&buf, &test_mac, &test_ll, &other);
    try std.testing.expectEqualSlices(u8, &other, &pending_na.?);
    // The DAD probe: src ::, no SLLA, pending untouched.
    const n2 = build_dad_ns(&buf, &test_mac, &test_g6);
    try std.testing.expectEqual(@as(usize, 78), n2);
    try std.testing.expectEqualSlices(u8, &ipv6.addr_unspecified, buf[22..38]);
    try std.testing.expectEqualSlices(u8, &ipv6.snm_addr(&test_g6), buf[38..54]);
    try std.testing.expectEqualSlices(u8, &test_g6, buf[62..78]);
    try std.testing.expectEqualSlices(u8, &other, &pending_na.?);
}

test "ndp: table — lookup, upsert, the 4-slot round-robin bound" {
    reset();
    const a1 = ipv6.parse_ip6("2001:db8:64::1").?;
    const a2 = ipv6.parse_ip6("2001:db8:64::2").?;
    const a3 = ipv6.parse_ip6("2001:db8:64::3").?;
    const a4 = ipv6.parse_ip6("2001:db8:64::4").?;
    const a5 = ipv6.parse_ip6("2001:db8:64::5").?;
    const m1 = [6]u8{ 0xaa, 0, 0, 0, 0, 1 };
    const m5 = [6]u8{ 0xaa, 0, 0, 0, 0, 5 };
    try std.testing.expect(lookup(&a1) == null);
    upsert(&a1, m1);
    try std.testing.expectEqualSlices(u8, &m1, &lookup(&a1).?);
    upsert(&a2, m1);
    upsert(&a3, m1);
    upsert(&a4, m1);
    // The fifth insert evicts the oldest (a1) — the bounded table.
    upsert(&a5, m5);
    try std.testing.expect(lookup(&a1) == null);
    try std.testing.expectEqualSlices(u8, &m5, &lookup(&a5).?);
    // An upsert on a hit updates in place.
    upsert(&a2, m5);
    try std.testing.expectEqualSlices(u8, &m5, &lookup(&a2).?);
}

test "ndp: NA learning is solicited-only (M97e-F3)" {
    reset();
    form_pair();
    var buf: [frame_len_max]u8 = undefined;
    // An unsolicited NA for a target nobody asked about: counted, never learned.
    _ = build_ns(&buf, &test_mac, &test_ll, &host_g6);
    const fake_target = ipv6.parse_ip6("2001:db8:64::77").?;
    @memcpy(buf[62..78], &fake_target);
    {
        var src: ipv6.Addr = undefined;
        var dst: ipv6.Addr = undefined;
        @memcpy(&src, buf[22..38]);
        @memcpy(&dst, buf[38..54]);
        // Turn it into an NA: type 136, S|O flags, TLLA.
        buf[54] = icmpv6_na;
        buf[58] = 0x60;
        buf[56] = 0;
        buf[57] = 0;
        buf[78] = 2;
        buf[79] = 1;
        @memcpy(buf[80..86], &host_mac);
        const chk = ipv6.icmp6_checksum(&src, &dst, buf[54..86], ipv6.nexthdr_icmpv6);
        std.mem.writeInt(u16, buf[56..58], chk, .big);
    }
    handle_na(&buf);
    try std.testing.expectEqual(@as(u64, 1), na_unsolicited);
    try std.testing.expect(lookup(&fake_target) == null);
    // The solicited NA (S=1, target == pending) is learned — a wire NA
    // for host_g6 from the peer's MAC.
    pending_na = host_g6;
    var na: [frame_len_max]u8 = undefined;
    @memset(&na, 0);
    @memcpy(na[0..6], &test_mac);
    @memcpy(na[6..12], &host_mac);
    na[12] = 0x86;
    na[13] = 0xdd;
    na[14] = 0x60;
    std.mem.writeInt(u16, na[18..20], 32, .big);
    na[20] = 58;
    na[21] = 255;
    @memcpy(na[22..38], &host_g6);
    @memcpy(na[38..54], &test_ll);
    na[54] = icmpv6_na;
    na[58] = 0x60; // S|O
    @memcpy(na[62..78], &host_g6);
    na[78] = 2;
    na[79] = 1;
    @memcpy(na[80..86], &host_mac);
    {
        const chk = ipv6.icmp6_checksum(&host_g6, &test_ll, na[54..86], ipv6.nexthdr_icmpv6);
        std.mem.writeInt(u16, na[56..58], chk, .big);
    }
    handle_na(&na);
    try std.testing.expectEqual(@as(u64, 1), learned);
    try std.testing.expectEqualSlices(u8, &host_mac, &lookup(&host_g6).?);
    try std.testing.expect(pending_na == null);
}

test "ndp: RA acceptance — global formed, router recorded, on-link set" {
    reset();
    ipv6.form_link_local(&test_mac);
    _ = ipv6.promote(&ipv6.link_local);
    const an_mac = ipv6.all_nodes_mac;
    var buf: [512]u8 = undefined;
    const opts = pio(&test_pfx, 64, 0xc0); // L|A
    const n = build_ra(&buf, &an_mac, &host_mac, &host_ll, &ipv6.all_nodes, 1800, &opts);
    handle_ra(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 1), ra_accepted);
    try std.testing.expectEqualSlices(u8, &test_g6, &ipv6.global);
    try std.testing.expect(ipv6.global_state == .tentative); // DAD still owed
    try std.testing.expect(ipv6.router_valid);
    try std.testing.expectEqualSlices(u8, &host_ll, &ipv6.router_addr);
    try std.testing.expectEqual(@as(u16, 1800), ipv6.router_lifetime);
    try std.testing.expect(ipv6.onlink_valid);
    try std.testing.expect(ipv6.on_link(&host_g6));
    try std.testing.expectEqual(@as(u64, 0), opt_skipped);
    try std.testing.expectEqual(@as(u32, 86400), pio_valid_lifetime);
    try std.testing.expectEqual(@as(u32, 14400), pio_preferred_lifetime);
    // A repeat RA from the same source refreshes (lifetime 0 = withdrawal).
    const n2 = build_ra(&buf, &an_mac, &host_mac, &host_ll, &ipv6.all_nodes, 0, &opts);
    handle_ra(buf[0..n2]);
    try std.testing.expectEqual(@as(u64, 2), ra_accepted);
    try std.testing.expectEqual(@as(u16, 0), ipv6.router_lifetime);
    // A foreign source is counted + ignored once the router is recorded.
    const other_ll = ipv6.parse_ip6("fe80::99").?;
    const n3 = build_ra(&buf, &an_mac, &host_mac, &other_ll, &ipv6.all_nodes, 1800, &opts);
    handle_ra(buf[0..n3]);
    try std.testing.expectEqual(@as(u64, 1), ra_foreign);
    try std.testing.expectEqual(@as(u64, 2), ra_accepted); // unchanged
}

test "ndp: RA refusals — non-link-local, bad lengths, bound, non-/64" {
    reset();
    ipv6.form_link_local(&test_mac);
    const an_mac = ipv6.all_nodes_mac;
    var buf: [512]u8 = undefined;
    const opts = pio(&test_pfx, 64, 0xc0);
    // Non-link-local source: malformed, never trusted.
    const n = build_ra(&buf, &an_mac, &host_mac, &host_g6, &ipv6.all_nodes, 1800, &opts);
    handle_ra(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 1), ra_malformed);
    try std.testing.expect(ipv6.global_state == .none);
    // Option length 0: the whole RA refuses — no partial trust.
    var bad_opts: [16]u8 = @splat(0);
    bad_opts[0] = 1;
    bad_opts[1] = 0; // length 0
    const n2 = build_ra(&buf, &an_mac, &host_mac, &host_ll, &ipv6.all_nodes, 1800, &bad_opts);
    handle_ra(buf[0..n2]);
    try std.testing.expectEqual(@as(u64, 2), ra_malformed);
    try std.testing.expect(ipv6.global_state == .none);
    // An option overrunning the message: same refusal.
    bad_opts[1] = 4; // 32 bytes, only 16 present
    const n3 = build_ra(&buf, &an_mac, &host_mac, &host_ll, &ipv6.all_nodes, 1800, &bad_opts);
    handle_ra(buf[0..n3]);
    try std.testing.expectEqual(@as(u64, 3), ra_malformed);
    // Nine options: the walk is bounded at 8.
    var many: [9 * 8]u8 = @splat(0);
    for (0..9) |k| {
        many[k * 8] = 5; // unknown type
        many[k * 8 + 1] = 1;
    }
    const n4 = build_ra(&buf, &an_mac, &host_mac, &host_ll, &ipv6.all_nodes, 1800, &many);
    handle_ra(buf[0..n4]);
    try std.testing.expectEqual(@as(u64, 4), ra_malformed);
    // A non-/64 A-flag PIO: opt_skipped, never truncated into an address.
    const opts48 = pio(&test_pfx, 48, 0xc0);
    const n5 = build_ra(&buf, &an_mac, &host_mac, &host_ll, &ipv6.all_nodes, 1800, &opts48);
    handle_ra(buf[0..n5]);
    try std.testing.expectEqual(@as(u64, 1), ra_accepted);
    try std.testing.expectEqual(@as(u64, 1), opt_skipped);
    try std.testing.expect(ipv6.global_state == .none);
    // An RDNSS option: skipped, not malformed.
    var rd: [24]u8 = @splat(0);
    rd[0] = 25;
    rd[1] = 3;
    const n6 = build_ra(&buf, &an_mac, &host_mac, &host_ll, &ipv6.all_nodes, 0, &rd);
    handle_ra(buf[0..n6]);
    try std.testing.expectEqual(@as(u64, 2), ra_accepted);
    try std.testing.expectEqual(@as(u64, 2), opt_skipped);
    // The same-source RA refreshes the record — lifetime 0 lands as the
    // honest withdrawal (the record stays, it is just not a router).
    try std.testing.expect(ipv6.router_valid);
    try std.testing.expectEqual(@as(u16, 0), ipv6.router_lifetime);
}

test "ndp: NS answering — owned target, tentative conflict, foreign drop" {
    reset();
    form_pair();
    var rbuf: [frame_len_max]u8 = undefined;
    var ns: [frame_len_max]u8 = undefined;
    // A peer NS for our global: answered, dst = the observed src MAC.
    _ = build_ns(&ns, &host_mac, &host_ll, &test_g6);
    const n = handle_ns(&ns, &test_mac, &rbuf).?;
    try std.testing.expectEqual(@as(usize, 86), n);
    try std.testing.expectEqualSlices(u8, &host_mac, rbuf[0..6]); // dst = requester MAC
    try std.testing.expectEqualSlices(u8, &test_mac, rbuf[6..12]);
    try std.testing.expectEqual(@as(u8, 136), rbuf[54]);
    try std.testing.expectEqual(@as(u8, 0x60), rbuf[58]); // S|O
    try std.testing.expectEqualSlices(u8, &test_g6, rbuf[62..78]); // target echoed
    try std.testing.expectEqualSlices(u8, &test_g6, rbuf[22..38]); // src = our addr
    try std.testing.expectEqualSlices(u8, &host_ll, rbuf[38..54]); // dst = their src
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 1 }, rbuf[78..80]); // TLLA
    try std.testing.expectEqualSlices(u8, &test_mac, rbuf[80..86]);
    // An NS for a foreign target: dropped counted.
    const foreign = ipv6.parse_ip6("2001:db8:64::99").?;
    _ = build_ns(&ns, &host_mac, &host_ll, &foreign);
    pending_na = null; // the peer's NS must not consume our pending
    try std.testing.expect(handle_ns(&ns, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 1), ndp_drop);
    // An NS for a TENTATIVE target: the DAD conflict — the address is
    // marked conflicted and never becomes usable.
    ipv6.global_state = .tentative;
    _ = build_ns(&ns, &host_mac, &host_ll, &test_g6);
    pending_na = null; // the peer's NS must not consume our pending
    try std.testing.expect(handle_ns(&ns, &test_mac, &rbuf) == null);
    try std.testing.expectEqual(@as(u64, 1), dad_conflicts);
    try std.testing.expect(ipv6.global_state == .conflicted);
    try std.testing.expectEqualSlices(u8, &test_g6, &last_conflict.?);
    // A conflicting NA hits the same refusal while still tentative.
    try std.testing.expect(!ipv6.is_owned(&test_g6));
}

test "ndp: the tick seam — DAD pending/due, the bounded RS train" {
    reset();
    ipv6.form_link_local(&test_mac);
    // Pending probe for the tentative link-local.
    const p = dad_pending().?;
    try std.testing.expect(p.slot == .ll);
    try std.testing.expectEqualSlices(u8, &test_ll, &p.addr);
    dad_mark_sent(.ll);
    dad_sent += 1;
    try std.testing.expect(dad_pending() == null);
    try std.testing.expect(dad_due() == null); // the wait has not elapsed
    now_ticks = 1;
    try std.testing.expectEqualSlices(u8, &test_ll, &dad_due().?);
    try std.testing.expect(ipv6.promote(&dad_due().?));
    try std.testing.expect(ipv6.link_local_state == .valid);
    // The RS train: armed at rx-armed, one per tick, ≤ 3.
    try std.testing.expect(!rs_due()); // not armed yet
    rx_armed();
    try std.testing.expect(rs_due());
    rs_note_sent();
    try std.testing.expectEqual(@as(u64, 1), rs_sent);
    try std.testing.expect(!rs_due()); // same tick — the spacing bound
    now_ticks = 2;
    try std.testing.expect(rs_due());
    rs_note_sent();
    now_ticks = 3;
    try std.testing.expect(rs_due());
    rs_note_sent();
    now_ticks = 4;
    try std.testing.expect(!rs_due()); // rs_max reached — the bounded train
}
