//! The ONE owner-approved TCP socket table — B6's injected core promoted to
//! the live implementation (M99f #2184, ADR 0007 amendment). Up to
//! `listener_limit` listeners (one per owner), `conn_limit` connections
//! including active-open (`parent == no_parent`) children of no listener;
//! numeric IPv4. A caller serializes access and supplies monotonic
//! nanoseconds and fresh ISNs. No locks, allocation, scheduler calls, DNS,
//! threading or SDK resource grants.
//!
//! receive/poll/flush perform bounded work. Call poll(now) before flushing and
//! periodically even without RX/app traffic. flush calls a bounded, non-reentrant
//! transport callback once; true means accepted by that transport, not delivered.
//! Borrowed bytes are valid only during the callback. Failed TX preserves the slot.
//! Clean FIN drains queued input before EOF; reset/timeout discard input.
//! Terminal children (including timed-out half-opens, obtainable through
//! accept) stay charged until close/death; a peer RST that arrives before
//! accept tears a never-accepted listener child down outright — the slot
//! frees immediately rather than charging a zombie against child_limit
//! (M135c #2765). close is immediate local reclamation, not a
//! promise that FIN/RST reached a peer; shutdown initiates bounded graceful FIN.
//! The single independently addressed refusal slot drops/counts overflow.
//! TCP options are parsed and skipped — MSS is honored, malformed option
//! lists are dropped in their own counter; window scaling, SACK blocks,
//! timestamps, congestion control and keepalive are NOT implemented.
//! Received data reassembles inside each connection's bounded window
//! (1460 bytes, bitmap-marked); the advertised window is the real free
//! space. Retransmission uses RFC 6298 adaptive RTO in nanoseconds
//! (200 ms floor, 60 s ceiling, Karn's rule, backoff). Fragmented IPv4
//! is still counted and dropped.
const std = @import("std");
pub const wire = @import("tcp.zig");
const ipv6 = @import("ipv6.zig"); // M117c (#2475): the family-tagged Endpoint's v6 Addr + is_bad_dst

/// Accepted children one listener may charge at once (the B6 two-client bound,
/// preserved end-to-end by the native socket fixture).
pub const child_limit = 2;
/// System listener slots: slot 0 stays the named `listener` field the ipv4
/// fast path reads; slots 1..3 live in `extra_listeners`.
pub const listener_limit = 4;
/// System connection slots, priced against `core_limit`: a Connection is
/// ~3.1 KiB (RX + TX + control + metadata), so 4 fit the 16 KiB core budget
/// with the listeners, refusal and counters (~14.1 KiB incl. one owned frame)
/// where 5 do not (~17.1 KiB).
pub const conn_limit = 4;
/// Sockets (listeners + connections) one owner may hold at once.
pub const owner_limit = 4;
/// Handle encoding: `generation << slot_bits | slot`. Slots 0..listener_limit-1
/// are listeners, conn_slot_base..conn_slot_base+conn_limit-1 connections;
/// socket_native mints the DNS seat at `dns_slot`.
pub const slot_bits = 4;
pub const slot_mask: u64 = (1 << slot_bits) - 1;
pub const conn_slot_base = listener_limit;
pub const dns_slot: u64 = 15;
/// A connection spawned by `open`, not by a listener's SYN.
pub const no_parent: u8 = 0xff;
/// The whole table's byte budget. M99f priced 16 KiB for 4 connections
/// at ~3.1 KiB each; M99h (#2186) adds each connection's bounded
/// reassembly window (1460 bytes + a 184-byte validity bitmap + spans),
/// the RFC 6298 estimator triple and the peer MSS — ~4.8 KiB per
/// connection — so the honest bound is 24 KiB.
pub const core_limit = 24 * 1024;
pub const deadline_ns: u64 = 30_000_000_000;
/// The INITIAL retransmission timeout before any RTT sample exists
/// (RFC 6298 §2.1 allows an initial RTO >= 1 s). Once a clean sample
/// lands, `Connection.rto_ns_cur` tracks SRTT + 4 x RTTVAR instead.
pub const rto_ns: u64 = 3_000_000_000;
/// M99h (#2186, card h3): the RFC 6298 RTO bounds in nanoseconds —
/// the suggested 1 s floor tightened to 200 ms per the card, the 60 s
/// ceiling.
pub const rto_floor_ns: u64 = 200_000_000;
pub const rto_ceiling_ns: u64 = 60_000_000_000;
pub const retry_limit: u8 = 10;
/// M99h (#2186, card h2): the receive window every connection
/// advertises — one `wire.payload_max` span. Held bytes (the in-order
/// prefix plus the bitmap-marked out-of-order bytes) always fit inside
/// it, so the advertised free space is exactly the honest bound.
pub const recv_window: usize = wire.payload_max;
const ooo_map_words = (recv_window + 63) / 64;
/// M117c (#2475, ADR 0057 D8): the endpoint pair is family-tagged — a
/// v4 endpoint carries its address in `ip` (the pre-M117c field, its
/// readers and literals untouched), a v6 endpoint in `addr6`.
/// `same` compares the family too, so a v6 SYN can never satisfy a v4
/// listener (or vice versa), and the checksum/build dispatch keys off
/// `local.family`.
pub const Family = enum(u8) { v4, v6 };
pub const Endpoint = struct {
    ip: [4]u8 = @splat(0),
    /// The v6 address — only meaningful when `family == .v6`.
    addr6: ipv6.Addr = @splat(0),
    family: Family = .v4,
    port: u16 = 0,
};
/// The v4 endpoint literal — the pre-M117c `{ ip, port }` caller shape.
pub fn ep4(ip: [4]u8, port: u16) Endpoint {
    return .{ .ip = ip, .port = port };
}
/// The v6 endpoint literal — `addr` is the caller's resolved peer or
/// the `select_src` local.
pub fn ep6(addr: ipv6.Addr, port: u16) Endpoint {
    return .{ .family = .v6, .addr6 = addr, .port = port };
}
pub const Handle = struct { value: u64 };
pub const Error = error{
    InvalidArgument,
    InvalidHandle,
    AccessDenied,
    Capacity,
    WouldBlock,
    PeerReset,
    TimedOut,
    Closed,
    Unsupported,
    ClockWentBackwards,
};
pub const State = enum { half_open, established, closing, terminal };
pub const Outcome = enum { none, eof, reset, timeout, closed };
pub const Ready = struct {
    accept: bool = false,
    read: bool = false,
    write: bool = false,
    terminal: bool = false,
};
pub const Outbound = struct {
    local: Endpoint,
    remote: Endpoint,
    remote_mac: [6]u8,
    bytes: []const u8,
};
pub const Transmit = *const fn (?*anyopaque, Outbound) bool;
pub const Flush = enum { empty, sent, refused };
const Listener = struct {
    handle: Handle,
    owner: u64,
    local: Endpoint,
    /// True when created through the legacy slot-30 listen path: the shim
    /// serves its children through slots 31–33/76, never through accept.
    legacy: bool = false,
};
pub const Connection = struct {
    handle: Handle,
    owner: u64,
    local: Endpoint,
    remote: Endpoint,
    remote_mac: [6]u8,
    state: State = .half_open,
    outcome: Outcome = .none,
    /// Listener slot that spawned this connection, or `no_parent` when it
    /// was created by `open` (active open, a child of no listener).
    parent: u8 = no_parent,
    accepted: bool = false,
    peer_fin: bool = false,
    peer_window: u16,
    snd_una: u32,
    snd_nxt: u32,
    rcv_nxt: u32,
    phase_deadline: u64,
    read_deadline: u64 = 0,
    write_deadline: u64 = 0,
    /// M99h (#2186): the peer's advertised MSS (0 = none — outbound
    /// payloads keep the `payload_max` bound; otherwise `send` clamps).
    peer_mss: u16 = 0,
    rx: [wire.payload_max]u8 = undefined,
    rx_len: usize = 0,
    /// M99h (#2186, card h2): the bounded out-of-order window.
    /// `ooo_buf[i]` holds sequence `ooo_base + i`; `ooo_map` marks which
    /// bytes are valid. `ooo_base` always equals `rcv_nxt` while bytes
    /// are held (rebased on every advance), so index 0 is never valid
    /// outside a drain — a held byte is strictly ahead of the stream.
    /// The window bound itself caps held bytes; there is no segment
    /// limit beyond it.
    ooo_buf: [recv_window]u8 = undefined,
    ooo_map: [ooo_map_words]u64 = @splat(0),
    ooo_base: u32 = 0,
    ooo_bytes: u16 = 0,
    /// A FIN received ahead of the stream — the sequence number it
    /// consumes, applied when contiguous.
    fin_ooo: u32 = 0,
    fin_ooo_set: bool = false,
    tx: [wire.segment_max]u8 = undefined,
    tx_len: usize = 0,
    tx_due: bool = false,
    tx_started: bool = false,
    last_tx: u64 = 0,
    retries: u8 = 0,
    /// M99h (#2186, card h3): the RFC 6298 RTT estimators in
    /// nanoseconds. `rtt_valid` is false until the first clean sample —
    /// an ACK covering a segment that was never retransmitted (Karn's
    /// algorithm, §5.2). `rto_ns_cur` is the live timeout: the estimator
    /// value after a sample, doubled per retransmission (§5.5 backoff),
    /// clamped [rto_floor_ns, rto_ceiling_ns].
    srtt_ns: u64 = 0,
    rttvar_ns: u64 = 0,
    rtt_valid: bool = false,
    rto_ns_cur: u64 = rto_ns,
    control: [wire.tcp_hdr_len]u8 = undefined,
    control_pending: bool = false,
};
const Refusal = struct {
    local: Endpoint,
    remote: Endpoint,
    remote_mac: [6]u8,
    bytes: [wire.tcp_hdr_len]u8,
};
pub const Counters = struct {
    malformed: u64 = 0,
    foreign: u64 = 0,
    duplicates: u64 = 0,
    rx_full: u64 = 0,
    capacity_refused: u64 = 0,
    refusal_dropped: u64 = 0,
    tx_refused: u64 = 0,
    retransmitted: u64 = 0,
    timed_out: u64 = 0,
    /// M99h (#2186): a segment dropped for a malformed option list —
    /// distinct from `malformed` (header shape) and `duplicates`.
    dropped_options: u64 = 0,
    /// M99h (#2186): segments the reassembly window has held, ever.
    ooo_held: u64 = 0,
    /// M135c (#2765): the named listen saturation — a SYN refused
    /// because its listener was already charging `child_limit`
    /// children. A subset of `capacity_refused` (the refusal wire shape
    /// is the same RST+ACK); the table-full and terminal-child refusals
    /// stay out of it.
    listen_saturated: u64 = 0,
    /// A SYN refused because the LISTENER's owner already charged
    /// `owner_limit` sockets — the same bound listen()/open() enforce,
    /// applied on the wire-driven path so a peer cannot push an owner
    /// over bound. A subset of `capacity_refused`, disjoint from
    /// `listen_saturated` (the per-listener bound is checked first).
    owner_saturated: u64 = 0,
};

pub const Core = struct {
    /// Slot 0 keeps the named field `ipv4.zig`'s fast path reads.
    listener: ?Listener = null,
    extra_listeners: [listener_limit - 1]?Listener = @splat(null),
    children: [conn_limit]?Connection = @splat(null),
    refusal: ?Refusal = null,
    next_generation: u64 = 1,
    now: u64 = 0,
    tx_cursor: usize = 0,
    counters: Counters = .{},

    fn clock(self: *Core, now: u64) Error!void {
        if (now < self.now) return error.ClockWentBackwards;
        self.now = now;
    }
    fn token(self: *Core, slot: u64) Error!Handle {
        if (self.next_generation > std.math.maxInt(u64) >> slot_bits) return error.Capacity;
        const handle: Handle = .{ .value = (self.next_generation << slot_bits) | slot };
        self.next_generation += 1;
        return handle;
    }
    pub fn listenerAt(self: *Core, slot: u64) ?*Listener {
        if (slot == 0) {
            return if (self.listener) |*l| l else null;
        }
        return if (self.extra_listeners[slot - 1]) |*l| l else null;
    }
    fn listenerSlot(self: *Core, handle: Handle) Error!u8 {
        const slot = handle.value & slot_mask;
        if (slot >= listener_limit) return error.InvalidHandle;
        const listener = self.listenerAt(slot) orelse return error.InvalidHandle;
        if (listener.handle.value != handle.value) return error.InvalidHandle;
        return @intCast(slot);
    }
    fn listenerFor(self: *Core, owner: u64, handle: Handle) Error!*Listener {
        const slot = try self.listenerSlot(handle);
        const listener = self.listenerAt(slot).?;
        if (listener.owner != owner) return error.AccessDenied;
        return listener;
    }
    fn childFor(self: *Core, owner: u64, handle: Handle) Error!*Connection {
        const slot = handle.value & slot_mask;
        if (slot < conn_slot_base or slot >= conn_slot_base + conn_limit) return error.InvalidHandle;
        const child = if (self.children[slot - conn_slot_base]) |*c| c else return error.InvalidHandle;
        if (child.handle.value != handle.value) return error.InvalidHandle;
        if (child.owner != owner) return error.AccessDenied;
        return child;
    }
    /// How many listeners + connections an owner currently charges.
    pub fn ownedSockets(self: *Core, owner: u64) usize {
        var count: usize = 0;
        for (0..listener_limit) |slot| if (self.listenerAt(slot)) |l| {
            if (l.owner == owner) count += 1;
        };
        for (self.children) |entry| if (entry) |c| {
            if (c.owner == owner) count += 1;
        };
        return count;
    }
    /// True when a listener or connection already charges this local port.
    pub fn portClaimed(self: *Core, port: u16) bool {
        for (0..listener_limit) |slot| if (self.listenerAt(slot)) |l| {
            if (l.local.port == port) return true;
        };
        for (self.children) |entry| if (entry) |c| {
            if (c.local.port == port) return true;
        };
        return false;
    }
    /// True when a listener or connection would process TCP for `port`.
    pub fn tableOwns(self: *Core, port: u16) bool {
        return self.portClaimed(port);
    }
    pub fn listen(self: *Core, owner: u64, local: Endpoint, now: u64) Error!Handle {
        if (!validEndpoint(local) or local.port == 0) return error.InvalidArgument;
        // One listener per owner — B6's same-owner second-listen ENOSPC — and
        // no shared local port across listeners or connections.
        for (0..listener_limit) |slot| if (self.listenerAt(slot)) |l| {
            if (l.owner == owner) return error.Capacity;
        };
        if (self.portClaimed(local.port)) return error.Capacity;
        if (self.ownedSockets(owner) >= owner_limit) return error.Capacity;
        try self.clock(now);
        const slot = self.freeListenerSlot() orelse return error.Capacity;
        const handle = try self.token(slot);
        const fresh: Listener = .{ .handle = handle, .owner = owner, .local = local };
        if (slot == 0) {
            self.listener = fresh;
        } else {
            self.extra_listeners[slot - 1] = fresh;
        }
        return handle;
    }
    fn freeListenerSlot(self: *Core) ?u64 {
        for (0..listener_limit) |slot| {
            if (self.listenerAt(slot) == null) return slot;
        }
        return null;
    }
    /// Mark a just-minted listener as belonging to the legacy slot-30 shim so
    /// its children are never served through `accept`.
    pub fn markLegacy(self: *Core, owner: u64, handle: Handle) Error!void {
        (try self.listenerFor(owner, handle)).legacy = true;
    }
    pub fn accept(self: *Core, owner: u64, handle: Handle) Error!Handle {
        const parent = try self.listenerSlot(handle);
        const listener = self.listenerAt(parent).?;
        if (listener.owner != owner) return error.AccessDenied;
        for (&self.children) |*entry| if (entry.*) |*c| {
            if (c.parent == parent and !c.accepted and c.state != .half_open) {
                c.accepted = true;
                return c.handle;
            }
        };
        return error.WouldBlock;
    }
    /// Active open: mint an outbound connection with its SYN queued in the
    /// bounded TX slot. The `connect` operation stays `Unsupported` — the
    /// handle ABI (slot 80) is passive-only; only the legacy slot-30 shim
    /// calls `open`.
    pub fn open(self: *Core, owner: u64, local: Endpoint, remote: Endpoint, remote_mac: [6]u8, now: u64, fresh_isn: u32) Error!Handle {
        if (!validEndpoint(remote) or remote.port == 0 or local.port == 0) return error.InvalidArgument;
        if (self.ownedSockets(owner) >= owner_limit) return error.Capacity;
        if (self.portClaimed(local.port)) return error.Capacity;
        try self.clock(now);
        for (&self.children, 0..) |*entry, index| {
            if (entry.* != null) continue;
            const handle = try self.token(conn_slot_base + index);
            entry.* = .{
                .handle = handle,
                .owner = owner,
                .local = local,
                .remote = remote,
                .remote_mac = remote_mac,
                .peer_window = 0, // unknown until the peer's SYN-ACK arrives
                .snd_una = fresh_isn,
                .snd_nxt = fresh_isn,
                .rcv_nxt = 0,
                .phase_deadline = deadline(now),
                .parent = no_parent,
            };
            // M99h (#2186, card h1): the active-open SYN advertises our
            // MSS 1460 — the table path's originated SYN, where the
            // legacy singleton's bare SYN stays pinned by the fleet.
            queueOpts(&entry.*.?, wire.flag_syn, &wire.mss_option, &.{}, now);
            return handle;
        }
        return error.Capacity;
    }
    pub fn ready(self: *Core, owner: u64, handle: Handle) Error!Ready {
        if ((handle.value & slot_mask) < conn_slot_base) {
            const parent = try self.listenerSlot(handle);
            const listener = self.listenerAt(parent).?;
            if (listener.owner != owner) return error.AccessDenied;
            for (self.children) |entry| if (entry) |c| {
                if (c.parent == parent and !c.accepted and c.state != .half_open) return .{ .accept = true };
            };
            return .{};
        }
        const c = try self.childFor(owner, handle);
        return .{
            .read = c.rx_len != 0 or c.peer_fin or c.state == .terminal,
            .write = c.state == .established and c.tx_len == 0 and !c.peer_fin and c.peer_window != 0,
            .terminal = c.state == .terminal,
        };
    }
    pub fn status(self: *Core, owner: u64, handle: Handle) Error!Outcome {
        return (try self.childFor(owner, handle)).outcome;
    }
    pub fn liveChildren(self: *const Core) usize {
        var count: usize = 0;
        for (self.children) |c| if (c != null) {
            count += 1;
        };
        return count;
    }
    pub fn send(self: *Core, owner: u64, handle: Handle, bytes: []const u8, now: u64) Error!usize {
        const c = try self.childFor(owner, handle);
        try self.poll(now);
        try usable(c);
        // A live sender is servicing the socket — same abandonment-slide as
        // the empty-read path (the singleton never timed a conn out while
        // its owner kept calling).
        c.read_deadline = deadline(now);
        if (bytes.len == 0) return 0;
        if (c.state != .established or c.tx_len != 0 or c.peer_window == 0) return error.WouldBlock;
        // M99h: the peer's advertised MSS bounds the segment too (a peer
        // that sent none keeps the payload_max bound).
        const mss: usize = if (c.peer_mss == 0) wire.payload_max else c.peer_mss;
        const count = @min(bytes.len, @min(@min(wire.payload_max, c.peer_window), mss));
        queue(c, wire.flag_ack, bytes[0..count], now);
        c.write_deadline = deadline(now);
        return count;
    }
    pub fn read(self: *Core, owner: u64, handle: Handle, output: []u8, now: u64) Error!usize {
        const c = try self.childFor(owner, handle);
        try self.poll(now);
        // A zero-length buffer is a validated no-op, not an EOF indication.
        if (output.len == 0) return 0;
        if (c.rx_len != 0) {
            const count = @min(output.len, c.rx_len);
            @memcpy(output[0..count], c.rx[0..count]);
            std.mem.copyForwards(u8, c.rx[0 .. c.rx_len - count], c.rx[count..c.rx_len]);
            c.rx_len -= count;
            c.read_deadline = deadline(now);
            if (c.state != .terminal) ack(c);
            return count;
        }
        if (c.peer_fin or c.outcome == .eof) return 0;
        try usable(c);
        // An empty read is still a read: the caller is alive and servicing
        // the socket, so the abandonment deadline slides. The legacy
        // transport polls recv on every wait tick — without this refresh a
        // live, silent-but-established conn would die at 30 s.
        c.read_deadline = deadline(now);
        return error.WouldBlock;
    }
    /// Graceful close is an operation, not an in-handler wait. close releases.
    pub fn shutdown(self: *Core, owner: u64, handle: Handle, now: u64) Error!void {
        const c = try self.childFor(owner, handle);
        try self.poll(now);
        try usable(c);
        if (c.state != .established or c.tx_len != 0) return error.WouldBlock;
        queue(c, wire.flag_fin | wire.flag_ack, &.{}, now);
        c.state = .closing;
        c.phase_deadline = deadline(now);
    }
    /// Reclaim a slot without the ownership walk — caller already validated.
    /// Closing a listener reclaims only ITS children (other listeners' and
    /// active-open connections survive) plus a refusal bound to its port.
    pub fn releaseAt(self: *Core, slot: u64) void {
        if (slot < listener_limit) {
            const local = self.listenerAt(slot).?.local;
            if (slot == 0) {
                self.listener = null;
            } else {
                self.extra_listeners[slot - 1] = null;
            }
            if (self.refusal) |r| {
                if (same(r.local, local)) self.refusal = null;
            }
            for (&self.children) |*entry| if (entry.*) |c| {
                if (c.parent == slot) entry.* = null;
            };
            return;
        }
        self.children[slot - conn_slot_base] = null;
    }
    pub fn close(self: *Core, owner: u64, handle: Handle) Error!void {
        const slot = handle.value & slot_mask;
        if (slot < conn_slot_base) {
            _ = try self.listenerFor(owner, handle);
        } else {
            _ = try self.childFor(owner, handle);
        }
        self.releaseAt(slot);
    }
    pub fn closeOwner(self: *Core, owner: u64) void {
        for (0..listener_limit) |slot| if (self.listenerAt(slot)) |l| {
            if (l.owner == owner) self.releaseAt(slot);
        };
        for (&self.children) |*entry| if (entry.*) |c| {
            if (c.owner == owner) entry.* = null;
        };
    }
    pub fn connect(_: *Core, _: Endpoint) Error!Handle {
        return error.Unsupported;
    }
    pub fn lookup(_: *Core, _: []const u8) Error![4]u8 {
        return error.Unsupported;
    }

    /// Complete Ethernet/IPv4 frames, not the old singleton's RX globals.
    /// Demux: an established connection's full 4-tuple match wins; then a
    /// listener-local match admits a new SYN under that listener's own
    /// two-child bound; anything else is foreign. A table with no matching
    /// endpoint leaves the frame alone (the caller decides).
    pub fn receive(self: *Core, frame: []const u8, now: u64, fresh_isn: u32) Error!void {
        try self.poll(now);
        var bad_options = false;
        const p = parse(frame, &bad_options) orelse {
            if (bad_options) {
                self.counters.dropped_options +%= 1;
            } else {
                self.counters.malformed +%= 1;
            }
            return;
        };
        for (&self.children) |*entry| if (entry.*) |*c| {
            if (same(c.local, p.local) and same(c.remote, p.remote)) {
                // M135c (#2765): an in-sequence RST tears a never-accepted
                // listener child down on the spot — no handle ever
                // escaped the table, so charging a terminal slot would
                // just leak the child bound. A legacy listener's
                // ALREADY-ESTABLISHED child keeps the terminal verdict
                // (the slot-30 shim's drain arm reads it); a half-open
                // one was never observable through the shim either.
                // Active-open connections and accepted children keep the
                // terminal outcome — an owner holds (or can claim) their
                // handle and reads .reset.
                if (!c.accepted and c.parent != no_parent and c.state != .terminal and
                    (p.flags & wire.flag_rst) != 0 and p.seq == c.rcv_nxt and
                    (c.state == .half_open or !self.listenerAt(c.parent).?.legacy))
                {
                    entry.* = null;
                    return;
                }
                self.received(c, p);
                return;
            }
        };
        const parent = self.listenerForLocal(p.local) orelse {
            self.counters.foreign +%= 1;
            return;
        };
        const l = self.listenerAt(parent).?;
        if (p.flags != wire.flag_syn or p.payload.len != 0) {
            self.counters.foreign +%= 1;
            return;
        }
        // Per-listener child bound — B6's two-client cap, per listener now.
        // M135c (#2765): saturation is the named refusal — counted here
        // and still answered with the refusal slot's RST+ACK (the card's
        // pick: answer, never silently drop — a dropped SYN looks like a
        // dead host to the peer's retransmission timer).
        var siblings: usize = 0;
        for (self.children) |entry| if (entry) |c| {
            if (c.parent == parent) siblings += 1;
        };
        if (siblings >= child_limit) {
            self.counters.listen_saturated +%= 1;
            self.refuse(p);
            return;
        }
        // The owner bound listen()/open() enforce applies on this path
        // too: a wire-driven child charges the LISTENER's owner, so
        // without the same check any peer could push a capped owner over
        // bound — and its children would eat the shared table. Same
        // named refusal shape as the per-listener bound.
        if (self.ownedSockets(l.owner) >= owner_limit) {
            self.counters.owner_saturated +%= 1;
            self.refuse(p);
            return;
        }
        for (&self.children, 0..) |*entry, i| if (entry.* == null) {
            const handle = self.token(conn_slot_base + i) catch {
                self.refuse(p);
                return;
            };
            entry.* = .{
                .handle = handle,
                .owner = l.owner,
                .local = l.local,
                .remote = p.remote,
                .remote_mac = p.mac,
                .peer_window = p.window,
                .peer_mss = p.mss, // M99h: the requester's MSS, if it sent one
                .snd_una = fresh_isn,
                .snd_nxt = fresh_isn,
                .rcv_nxt = p.seq +% 1,
                .phase_deadline = deadline(now),
                .parent = @intCast(parent),
            };
            // M99h: the SYN-ACK advertises our MSS — a SYN is a SYN.
            queueOpts(&entry.*.?, wire.flag_syn | wire.flag_ack, &wire.mss_option, &.{}, now);
            return;
        };
        self.refuse(p);
    }
    /// The listener slot whose local endpoint matches, if any.
    fn listenerForLocal(self: *Core, local: Endpoint) ?u64 {
        for (0..listener_limit) |slot| if (self.listenerAt(slot)) |l| {
            if (same(l.local, local)) return slot;
        };
        return null;
    }
    fn refuse(self: *Core, p: Parsed) void {
        self.counters.capacity_refused +%= 1;
        if (self.refusal != null) {
            self.counters.refusal_dropped +%= 1;
            return;
        }
        var refusal: Refusal = .{ .local = p.local, .remote = p.remote, .remote_mac = p.mac, .bytes = undefined };
        // M117c: the RST rides the same family as the segment that
        // provoked it — the v6 build uses the 16-byte pseudo-header.
        if (p.local.family == .v6) {
            _ = wire.build_segment6(&refusal.bytes, &p.local.addr6, &p.remote.addr6, p.local.port, p.remote.port, 0, p.seq +% 1, wire.flag_rst | wire.flag_ack, &.{});
        } else {
            _ = wire.build_segment(&refusal.bytes, p.local.ip, p.remote.ip, p.local.port, p.remote.port, 0, p.seq +% 1, wire.flag_rst | wire.flag_ack, &.{});
        }
        self.refusal = refusal;
    }
    fn received(self: *Core, c: *Connection, p: Parsed) void {
        if (c.state == .terminal) {
            if (p.flags == wire.flag_syn and p.payload.len == 0) self.refuse(p);
            return;
        }
        if (c.parent == no_parent and c.state == .half_open) {
            // Active-open handshake: a SYN+ACK covering our SYN establishes.
            if ((p.flags & wire.flag_rst) != 0) {
                finish(c, .reset);
                return;
            }
            if (p.flags == (wire.flag_syn | wire.flag_ack) and p.ack == c.snd_nxt and p.payload.len == 0) {
                c.rcv_nxt = p.seq +% 1;
                c.snd_una = p.ack;
                c.peer_window = p.window;
                c.peer_mss = p.mss; // M99h: the peer's advertised MSS
                noteSample(c, self.now); // the SYN-ACK is the first RTT sample
                clearTx(c);
                c.state = .established;
                c.read_deadline = deadline(self.now);
                ack(c);
                return;
            }
            self.counters.malformed +%= 1;
            return;
        }
        if (p.flags == wire.flag_syn and c.state == .half_open and p.seq +% 1 == c.rcv_nxt and p.payload.len == 0) {
            // Reuse the original SYN-ACK; never allocate another child/ISN.
            c.tx_due = true;
            return;
        }
        if ((p.flags & wire.flag_rst) != 0) {
            // An RST still only bites exactly at rcv_nxt — the pinned bound.
            if (p.seq == c.rcv_nxt) {
                finish(c, .reset);
                return;
            }
            self.counters.duplicates +%= 1;
            if (c.state != .half_open) ack(c);
            return;
        }
        if ((p.flags & wire.flag_syn) != 0 or
            (c.state == .half_open and (p.flags & wire.flag_fin) != 0))
        {
            self.counters.malformed +%= 1;
            return;
        }
        // M99h (#2186, card h2): the in-sequence bound became the bounded
        // receive window — a data segment must overlap
        // [rcv_nxt, rcv_nxt + free); fully-old bytes are duplicates
        // (re-ACKed); bytes beyond the window are refused; the rest is
        // head/tail-trimmed honestly. A bare segment still sits exactly
        // at rcv_nxt; a FIN may sit ahead (it queues until contiguous).
        const fwin: u32 = @intCast(rxFree(c));
        const plen: u32 = @intCast(p.payload.len);
        const has_fin = (p.flags & wire.flag_fin) != 0;
        var d_seq = p.seq;
        var d_len: usize = p.payload.len;
        var off: usize = 0;
        if (plen != 0) {
            if (wire.seq_ge(c.rcv_nxt, p.seq)) {
                const skip = c.rcv_nxt -% p.seq;
                if (skip >= plen) {
                    self.counters.duplicates +%= 1;
                    if (c.state != .half_open) ack(c);
                    return;
                }
                off = @intCast(skip);
                d_seq = c.rcv_nxt;
                d_len = p.payload.len - off;
            } else if (p.seq != c.rcv_nxt and (p.seq -% c.rcv_nxt) >= fwin) {
                self.counters.malformed +%= 1;
                return;
            }
        } else if (p.seq != c.rcv_nxt) {
            if (has_fin and !wire.seq_ge(c.rcv_nxt, p.seq) and (p.seq -% c.rcv_nxt) <= fwin) {
                c.fin_ooo = p.seq; // a FIN ahead of the stream — queue it
                c.fin_ooo_set = true;
                if (c.state != .half_open) ack(c);
                return;
            }
            self.counters.duplicates +%= 1;
            if (c.state != .half_open) ack(c);
            return;
        }
        const sent_limit = if (c.tx_started) c.snd_nxt else c.snd_una;
        if ((p.flags & wire.flag_ack) == 0 or !ackInRange(p.ack, c.snd_una, sent_limit)) {
            self.counters.malformed +%= 1;
            return;
        }
        c.peer_window = p.window;
        if (c.state == .half_open) {
            if (!c.tx_started or p.ack != c.snd_nxt) return;
            noteSample(c, self.now); // the handshake ACK covers our SYN-ACK
            clearTx(c);
            c.snd_una = p.ack;
            c.state = .established;
            c.read_deadline = deadline(self.now);
        } else if (c.tx_started and p.ack == c.snd_nxt) {
            noteSample(c, self.now); // Karn's rule keeps retried segments out
            clearTx(c);
            c.snd_una = p.ack;
            if (c.state == .closing and c.peer_fin) {
                finish(c, .eof);
                // finish preserves queued clean input; final ACK still goes.
                ack(c);
                return;
            }
        }
        if (d_len != 0) {
            if (c.peer_fin or c.state == .closing) {
                self.counters.rx_full +%= 1;
                ack(c);
                return;
            }
            // The tail cannot exceed the window past the segment's own
            // offset — `d_seq - rcv_nxt` bytes of the free space are
            // upstream of it (0 for an in-order segment).
            const room: usize = @intCast(fwin -% (d_seq -% c.rcv_nxt));
            if (d_len > room) {
                self.counters.rx_full +%= 1;
                d_len = room;
            }
            if (d_len != 0) {
                if (d_seq == c.rcv_nxt) {
                    @memcpy(c.rx[c.rx_len .. c.rx_len + d_len], p.payload[off .. off + d_len]);
                    c.rx_len += d_len;
                    c.rcv_nxt +%= @intCast(d_len);
                    oooAdvance(c, @intCast(d_len));
                } else {
                    if (oooInsert(c, d_seq, p.payload[off .. off + d_len])) {
                        self.counters.ooo_held +%= 1;
                    } else {
                        self.counters.rx_full +%= 1; // held bound hit — dropped, never misordered
                    }
                }
            }
            ack(c);
        }
        if (has_fin) {
            const fin_seq = p.seq +% plen;
            if (fin_seq == c.rcv_nxt) {
                c.rcv_nxt +%= 1;
                c.peer_fin = true;
            } else {
                c.fin_ooo = fin_seq; // ahead of the stream — applies when contiguous
                c.fin_ooo_set = true;
            }
            ack(c);
            if (c.peer_fin and c.tx_len == 0) {
                if (c.state == .closing) {
                    finish(c, .eof);
                    ack(c);
                } else {
                    queue(c, wire.flag_fin | wire.flag_ack, &.{}, self.now);
                    c.state = .closing;
                    c.phase_deadline = deadline(self.now);
                }
            }
        } else if (c.peer_fin and c.tx_len == 0 and c.state == .established) {
            // A queued FIN just applied inside `oooAdvance` — the same
            // close-out as a FIN that arrived contiguous.
            queue(c, wire.flag_fin | wire.flag_ack, &.{}, self.now);
            c.state = .closing;
            c.phase_deadline = deadline(self.now);
        }
    }
    /// Deadlines win at equality, before a same-time retransmission.
    pub fn poll(self: *Core, now: u64) Error!void {
        try self.clock(now);
        for (&self.children) |*entry| if (entry.*) |*c| {
            if (c.state == .terminal) continue;
            const expired = if (c.state == .half_open or c.state == .closing)
                now >= c.phase_deadline
            else
                now >= c.read_deadline or (c.tx_len != 0 and now >= c.write_deadline);
            if (expired) {
                finish(c, .timeout);
                self.counters.timed_out +%= 1;
                continue;
            }
            // M99h (#2186, card h3): the adaptive RTO — `rto_ns_cur` is
            // the estimator value (or the initial bound), doubled toward
            // the 60 s ceiling per retransmission (RFC 6298 §5.5). The
            // 30 s phase/read deadlines still abort a black hole
            // independently of the retry schedule.
            if (c.tx_len != 0 and c.tx_started and !c.tx_due and now - c.last_tx >= c.rto_ns_cur) {
                if (c.retries >= retry_limit) {
                    finish(c, .timeout);
                    self.counters.timed_out +%= 1;
                } else {
                    c.tx_due = true;
                    c.rto_ns_cur = @min(rto_ceiling_ns, c.rto_ns_cur *| 2);
                }
            }
            // A peer FIN while our data was pending: queue FIN after its ACK.
            if (c.peer_fin and c.state == .established and c.tx_len == 0) {
                queue(c, wire.flag_fin | wire.flag_ack, &.{}, now);
                c.state = .closing;
                c.phase_deadline = deadline(now);
            }
        };
    }
    /// Fair round-robin across all connections and the refusal slot,
    /// one callback per call.
    pub fn flush(self: *Core, context: ?*anyopaque, transmit: Transmit) Flush {
        for (0..conn_limit + 1) |_| {
            const slot = self.tx_cursor;
            self.tx_cursor = (slot + 1) % (conn_limit + 1);
            if (slot == conn_limit) {
                if (self.refusal) |r| {
                    if (!transmit(context, .{ .local = r.local, .remote = r.remote, .remote_mac = r.remote_mac, .bytes = &r.bytes })) {
                        self.counters.tx_refused +%= 1;
                        return .refused;
                    }
                    self.refusal = null;
                    return .sent;
                }
            } else if (self.children[slot]) |*c| {
                const control = c.control_pending;
                if (!control and !c.tx_due) continue;
                if (!control and c.tx_started and c.retries >= retry_limit) {
                    // Repeated SYNs may request early retries, but cannot bypass
                    // the same bound or overflow the u8 counter.
                    finish(c, .timeout);
                    self.counters.timed_out +%= 1;
                    continue;
                }
                const bytes = if (control) &c.control else c.tx[0..c.tx_len];
                if (!transmit(context, .{ .local = c.local, .remote = c.remote, .remote_mac = c.remote_mac, .bytes = bytes })) {
                    self.counters.tx_refused +%= 1;
                    return .refused;
                }
                if (control) {
                    c.control_pending = false;
                } else {
                    if (c.tx_started) {
                        c.retries += 1;
                        self.counters.retransmitted +%= 1;
                    }
                    c.tx_due = false;
                    c.tx_started = true;
                    c.last_tx = self.now;
                }
                return .sent;
            }
        }
        return .empty;
    }
};

comptime {
    if (@sizeOf(Core) + wire.frame_max > core_limit)
        @compileError("SocketCoreBudget: core plus one owned frame exceeds 16 KiB");
}
fn deadline(now: u64) u64 {
    return now +| deadline_ns;
}
fn validIp(ip: [4]u8) bool {
    return ip[0] != 0 and ip[0] != 127 and ip[0] < 224;
}
/// M117c: the family-aware endpoint validation — v4 keeps the
/// `validIp` rules (nonzero, not loopback-net, not multicast); a v6
/// endpoint refuses the `bad_dst6` set (multicast, unspecified,
/// loopback, mapped-v4).
fn validEndpoint(e: Endpoint) bool {
    return switch (e.family) {
        .v4 => validIp(e.ip),
        .v6 => !ipv6.is_bad_dst(e.addr6),
    };
}
fn same(a: Endpoint, b: Endpoint) bool {
    if (a.family != b.family or a.port != b.port) return false;
    return switch (a.family) {
        .v4 => std.mem.eql(u8, &a.ip, &b.ip),
        .v6 => std.mem.eql(u8, &a.addr6, &b.addr6),
    };
}
fn ackInRange(value: u32, first: u32, last: u32) bool {
    return value -% first <= last -% first;
}
fn usable(c: *const Connection) Error!void {
    switch (c.outcome) {
        .reset => return error.PeerReset,
        .timeout => return error.TimedOut,
        .eof, .closed => return error.Closed,
        .none => {},
    }
    if (c.peer_fin) return error.Closed;
}
fn clearTx(c: *Connection) void {
    c.tx_len = 0;
    c.tx_due = false;
    c.tx_started = false;
    c.retries = 0;
    c.write_deadline = 0;
}
fn finish(c: *Connection, outcome: Outcome) void {
    c.state = .terminal;
    c.outcome = outcome;
    clearTx(c);
    c.control_pending = false;
    c.phase_deadline = 0;
    c.read_deadline = 0;
    if (outcome != .eof) {
        c.rx_len = 0;
        c.peer_fin = false;
    }
    // M99h: a dead connection releases its reassembly window and any
    // queued FIN — the .eof path keeps the in-order prefix readable
    // exactly like before.
    c.ooo_map = @splat(0);
    c.ooo_bytes = 0;
    c.fin_ooo_set = false;
}
/// M99h (#2186, card h2): the honest advertised window — the receive
/// window's real free space: `recv_window` minus every buffered byte
/// (the in-order prefix plus the bitmap-held out-of-order bytes).
fn rxFree(c: *const Connection) usize {
    const used = c.rx_len + c.ooo_bytes;
    return if (used >= recv_window) 0 else recv_window - used;
}
fn build(c: *const Connection, buf: []u8, seq: u32, flags: u8, payload: []const u8) usize {
    return buildOpts(c, buf, seq, flags, &.{}, payload);
}
fn buildOpts(c: *const Connection, buf: []u8, seq: u32, flags: u8, opts: []const u8, payload: []const u8) usize {
    // M117c: the segment bytes are family-independent; only the
    // pseudo-header checksum differs (16-byte v6 addresses).
    const len = if (c.local.family == .v6)
        wire.build_segment_opts6(buf, &c.local.addr6, &c.remote.addr6, c.local.port, c.remote.port, seq, c.rcv_nxt, flags, opts, payload)
    else
        wire.build_segment_opts(buf, c.local.ip, c.remote.ip, c.local.port, c.remote.port, seq, c.rcv_nxt, flags, opts, payload);
    // M99h: the advertised window is the queue's real free space — an
    // empty queue advertises the whole span, a partial read a slice.
    std.mem.writeInt(u16, buf[14..16], @intCast(rxFree(c)), .big);
    @memset(buf[16..18], 0);
    const cksum = if (c.local.family == .v6)
        wire.checksum_tcp6(&c.local.addr6, &c.remote.addr6, buf[0..len])
    else
        wire.checksum_tcp(c.local.ip, c.remote.ip, buf[0..len]);
    std.mem.writeInt(u16, buf[16..18], cksum, .big);
    return len;
}
fn queue(c: *Connection, flags: u8, payload: []const u8, now: u64) void {
    queueOpts(c, flags, &.{}, payload, now);
}
fn queueOpts(c: *Connection, flags: u8, opts: []const u8, payload: []const u8, now: u64) void {
    c.tx_len = buildOpts(c, &c.tx, c.snd_nxt, flags, opts, payload);
    c.snd_nxt +%= @intCast(payload.len + @as(usize, if ((flags & (wire.flag_syn | wire.flag_fin)) != 0) 1 else 0));
    c.tx_due = true;
    c.tx_started = false;
    c.retries = 0;
    c.last_tx = now;
    // A new segment loses the backoff: the live RTO returns to the
    // estimator value (or the initial bound before the first sample).
    c.rto_ns_cur = if (c.rtt_valid)
        @min(rto_ceiling_ns, @max(rto_floor_ns, c.srtt_ns +| 4 *| c.rttvar_ns))
    else
        rto_ns;
}
/// M99h (#2186, card h2): the reassembly bitmap — bit i marks
/// `ooo_buf[i]` valid (sequence `ooo_base + i`).
fn oooBit(c: *const Connection, i: usize) bool {
    return (c.ooo_map[i / 64] >> @intCast(i % 64)) & 1 != 0;
}
fn oooSet(c: *Connection, i: usize, v: bool) void {
    if (v) {
        c.ooo_map[i / 64] |= @as(u64, 1) << @intCast(i % 64);
    } else {
        c.ooo_map[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
    }
}
/// Hold `data` (sequence `seq`, strictly ahead of `rcv_nxt`, already
/// trimmed to the free window) in the reassembly window. `ooo_base` is
/// `rcv_nxt` whenever bytes are held, so the offset is always positive;
/// the first held byte also re-bases. Overlapping a held byte is free —
/// the bitmap is idempotent and `ooo_bytes` counts only the new bits.
fn oooInsert(c: *Connection, seq: u32, data: []const u8) bool {
    if (c.ooo_bytes == 0) c.ooo_base = c.rcv_nxt;
    const off: usize = seq -% c.ooo_base;
    if (off + data.len > recv_window) return false;
    var added: u16 = 0;
    for (0..data.len) |i| {
        if (!oooBit(c, off + i)) {
            oooSet(c, off + i, true);
            added += 1;
        }
    }
    @memcpy(c.ooo_buf[off .. off + data.len], data);
    c.ooo_bytes += added;
    return true;
}
/// `rcv_nxt` just advanced by `n` in-order bytes: re-base the held
/// window (bytes the new prefix covered are dropped, the rest slide
/// down), then splice every now-contiguous held run into `rx` — the
/// stream cannot go backwards. A queued FIN applies the moment its
/// sequence number becomes contiguous. The window invariant
/// (`rx_len + ooo_bytes <= recv_window`) guarantees each splice fits.
fn oooAdvance(c: *Connection, n: u32) void {
    if (c.ooo_bytes != 0) {
        oooSlide(c, n);
        while (c.ooo_bytes != 0 and oooBit(c, 0)) {
            var k: usize = 0;
            while (k < recv_window and oooBit(c, k)) k += 1;
            @memcpy(c.rx[c.rx_len .. c.rx_len + k], c.ooo_buf[0..k]);
            c.rx_len += k;
            c.rcv_nxt +%= @intCast(k);
            oooSlide(c, @intCast(k));
        }
    }
    if (c.fin_ooo_set and c.fin_ooo == c.rcv_nxt) {
        c.fin_ooo_set = false;
        c.rcv_nxt +%= 1; // the FIN consumes one sequence number
        c.peer_fin = true;
    }
}
/// Drop the lowest `n` held positions, sliding the rest down and
/// advancing `ooo_base` to match — the shared re-base step for
/// `oooAdvance` (n = the rcv_nxt advance) and its inner splice
/// (n = the run length, so `ooo_base` tracks `rcv_nxt` exactly).
fn oooSlide(c: *Connection, n: usize) void {
    if (n >= recv_window) {
        c.ooo_map = @splat(0);
        c.ooo_bytes = 0;
        c.ooo_base +%= @intCast(n);
        return;
    }
    var kept: u16 = 0;
    var i: usize = 0;
    while (i + n < recv_window) : (i += 1) {
        const b = oooBit(c, i + n);
        oooSet(c, i, b);
        if (b) kept += 1;
    }
    while (i < recv_window) : (i += 1) oooSet(c, i, false);
    std.mem.copyForwards(u8, c.ooo_buf[0 .. recv_window - n], c.ooo_buf[n..recv_window]);
    c.ooo_bytes = kept;
    c.ooo_base +%= @intCast(n);
}
/// M99h (#2186, card h3): the RFC 6298 RTT update — called at every
/// ACK-accept site BEFORE `clearTx`. A sample exists only when the
/// pending segment was never retransmitted (Karn's algorithm, §5.2):
/// `tx_started` and zero retries. First sample: SRTT = R, RTTVAR = R/2;
/// later samples: the §2.3 alpha = 1/8 / beta = 1/4 filters. The live
/// RTO is SRTT + 4 x RTTVAR clamped [rto_floor_ns, rto_ceiling_ns].
fn noteSample(c: *Connection, now: u64) void {
    if (!c.tx_started or c.retries != 0) return;
    const r = now -| c.last_tx;
    if (!c.rtt_valid) {
        c.srtt_ns = r;
        c.rttvar_ns = r / 2;
        c.rtt_valid = true;
    } else {
        const d = if (r > c.srtt_ns) r - c.srtt_ns else c.srtt_ns - r;
        c.rttvar_ns = (3 * c.rttvar_ns + d) / 4;
        c.srtt_ns = (7 * c.srtt_ns + r) / 8;
    }
    c.rto_ns_cur = @min(rto_ceiling_ns, @max(rto_floor_ns, c.srtt_ns +| 4 *| c.rttvar_ns));
}
fn ack(c: *Connection) void {
    _ = build(c, &c.control, if (c.tx_started) c.snd_nxt else c.snd_una, wire.flag_ack, &.{});
    c.control_pending = true;
}
const Parsed = struct {
    local: Endpoint,
    remote: Endpoint,
    mac: [6]u8,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    /// M99h (#2186): the peer's advertised MSS from a SYN-flagged
    /// segment (0 = none).
    mss: u16,
    payload: []const u8,
};
fn parse(frame: []const u8, bad_options: *bool) ?Parsed {
    bad_options.* = false;
    if (frame.len < 14) return null;
    // M117c: the v6 half — ethertype 0x86dd, the 40-byte fixed header,
    // the same TCP-shaped tail.
    if (frame[12] == 0x86 and frame[13] == 0xdd) return parse6(frame, bad_options);
    if (frame.len < wire.frame_min or frame[12] != 8 or frame[13] != 0 or frame[14] != 0x45 or frame[23] != 6) return null;
    const ip = frame[14..34];
    if (wire.fold(wire.sum_words(ip)) != 0 or std.mem.readInt(u16, ip[6..8], .big) & 0xbfff != 0) return null;
    const length = std.mem.readInt(u16, ip[2..4], .big);
    if (length < 40 or length > 1500 or length + @as(usize, 14) > frame.len) return null;
    const seg = frame[34 .. 14 + @as(usize, length)];
    if (seg[13] & ~@as(u8, 0x1f) != 0 or (seg[13] & (wire.flag_syn | wire.flag_fin)) == (wire.flag_syn | wire.flag_fin)) return null;
    // M99h (#2186, card h1): the data offset declares the option area.
    // Offset < 5 or one beyond the segment is malformed; a valid area is
    // scanned (NOPs and unknown kinds skipped, MSS recorded) — a
    // malformed option list drops the segment in its own counter.
    const doff: usize = seg[12] >> 4;
    if (doff < 5 or doff * 4 > seg.len) return null;
    var mss: u16 = 0;
    wire.scanOptions(seg, wire.tcp_hdr_len, doff * 4 - wire.tcp_hdr_len, &mss) catch {
        bad_options.* = true;
        return null;
    };
    if (seg[13] & wire.flag_rst != 0 and (doff != 5 or seg.len != wire.tcp_hdr_len or seg[13] & (wire.flag_syn | wire.flag_fin) != 0)) return null;
    const remote: [4]u8 = ip[12..16].*;
    const local: [4]u8 = ip[16..20].*;
    if (!validIp(remote) or wire.checksum_tcp(remote, local, seg) != 0) return null;
    const src_port = std.mem.readInt(u16, seg[0..2], .big);
    const dst_port = std.mem.readInt(u16, seg[2..4], .big);
    if (src_port == 0 or dst_port == 0) return null;
    return .{
        .local = ep4(local, dst_port),
        .remote = ep4(remote, src_port),
        .mac = frame[6..12].*,
        .seq = std.mem.readInt(u32, seg[4..8], .big),
        .ack = std.mem.readInt(u32, seg[8..12], .big),
        .flags = seg[13],
        .window = std.mem.readInt(u16, seg[14..16], .big),
        .mss = if (seg[13] & wire.flag_syn != 0) mss else 0,
        .payload = seg[doff * 4 ..],
    };
}

/// M117c (#2475, ADR 0057 D8): the v6 half of `parse` — the caller
/// already saw ethertype 0x86dd. The fixed header is validated here the
/// same way `ipv6.handle_rx` does (version, payload_len coverage,
/// hop_limit — the D7 "no extension-header walk" bound: the terminal
/// next-header must be TCP itself), then the segment tail shares the
/// v4 shape checks (flags, data offset, option scan, ports) with a
/// v6 pseudo-header checksum.
fn parse6(frame: []const u8, bad_options: *bool) ?Parsed {
    const frame6_min = 14 + ipv6.ipv6_hdr_len + wire.tcp_hdr_len;
    if (frame.len < frame6_min) return null;
    if (frame[14] >> 4 != 6 or frame[20] != wire.protocol_tcp or frame[21] == 0) return null;
    const plen = std.mem.readInt(u16, frame[18..20], .big);
    if (plen < wire.tcp_hdr_len or frame.len < 14 + ipv6.ipv6_hdr_len + @as(usize, plen)) return null;
    const seg = frame[14 + ipv6.ipv6_hdr_len .. 14 + ipv6.ipv6_hdr_len + @as(usize, plen)];
    if (seg[13] & ~@as(u8, 0x1f) != 0 or (seg[13] & (wire.flag_syn | wire.flag_fin)) == (wire.flag_syn | wire.flag_fin)) return null;
    const doff: usize = seg[12] >> 4;
    if (doff < 5 or doff * 4 > seg.len) return null;
    var mss: u16 = 0;
    wire.scanOptions(seg, wire.tcp_hdr_len, doff * 4 - wire.tcp_hdr_len, &mss) catch {
        bad_options.* = true;
        return null;
    };
    if (seg[13] & wire.flag_rst != 0 and (doff != 5 or seg.len != wire.tcp_hdr_len or seg[13] & (wire.flag_syn | wire.flag_fin) != 0)) return null;
    const remote: ipv6.Addr = frame[22..38].*;
    const local: ipv6.Addr = frame[38..54].*;
    // The remote must be a legal v6 source (never multicast/unspecified/
    // loopback/mapped), and the pseudo-header checksum must verify.
    if (ipv6.is_bad_dst(remote) or wire.checksum_tcp6(&remote, &local, seg) != 0) return null;
    const src_port = std.mem.readInt(u16, seg[0..2], .big);
    const dst_port = std.mem.readInt(u16, seg[2..4], .big);
    if (src_port == 0 or dst_port == 0) return null;
    return .{
        .local = ep6(local, dst_port),
        .remote = ep6(remote, src_port),
        .mac = frame[6..12].*,
        .seq = std.mem.readInt(u32, seg[4..8], .big),
        .ack = std.mem.readInt(u32, seg[8..12], .big),
        .flags = seg[13],
        .window = std.mem.readInt(u16, seg[14..16], .big),
        .mss = if (seg[13] & wire.flag_syn != 0) mss else 0,
        .payload = seg[doff * 4 ..],
    };
}
