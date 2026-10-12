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
//! Terminal children (including failed half-opens, obtainable through accept)
//! stay charged until close/death. close is immediate local reclamation, not a
//! promise that FIN/RST reached a peer; shutdown initiates bounded graceful FIN.
//! The single independently addressed refusal slot drops/counts overflow.
//! Unsupported option-bearing TCP and fragmented IPv4 are counted and dropped.
const std = @import("std");
pub const wire = @import("tcp.zig");

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
pub const core_limit = 16 * 1024;
pub const deadline_ns: u64 = 30_000_000_000;
pub const rto_ns: u64 = 3_000_000_000;
pub const retry_limit: u8 = 10;
pub const Endpoint = struct { ip: [4]u8, port: u16 };
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
    rx: [wire.payload_max]u8 = undefined,
    rx_len: usize = 0,
    tx: [wire.segment_max]u8 = undefined,
    tx_len: usize = 0,
    tx_due: bool = false,
    tx_started: bool = false,
    last_tx: u64 = 0,
    retries: u8 = 0,
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
        if (!validIp(local.ip) or local.port == 0) return error.InvalidArgument;
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
        if (!validIp(remote.ip) or remote.port == 0 or local.port == 0) return error.InvalidArgument;
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
            queue(&entry.*.?, wire.flag_syn, &.{}, now);
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
        const count = @min(bytes.len, @min(wire.payload_max, c.peer_window));
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
        const p = parse(frame) orelse {
            self.counters.malformed +%= 1;
            return;
        };
        for (&self.children) |*entry| if (entry.*) |*c| {
            if (same(c.local, p.local) and same(c.remote, p.remote)) {
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
        var siblings: usize = 0;
        for (self.children) |entry| if (entry) |c| {
            if (c.parent == parent) siblings += 1;
        };
        if (siblings >= child_limit) {
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
                .snd_una = fresh_isn,
                .snd_nxt = fresh_isn,
                .rcv_nxt = p.seq +% 1,
                .phase_deadline = deadline(now),
                .parent = @intCast(parent),
            };
            queue(&entry.*.?, wire.flag_syn | wire.flag_ack, &.{}, now);
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
        _ = wire.build_segment(&refusal.bytes, p.local.ip, p.remote.ip, p.local.port, p.remote.port, 0, p.seq +% 1, wire.flag_rst | wire.flag_ack, &.{});
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
        if (p.seq != c.rcv_nxt) {
            self.counters.duplicates +%= 1;
            if (c.state != .half_open) ack(c);
            return;
        }
        if ((p.flags & wire.flag_rst) != 0) {
            finish(c, .reset);
            return;
        }
        if ((p.flags & wire.flag_syn) != 0 or
            (c.state == .half_open and (p.flags & wire.flag_fin) != 0))
        {
            self.counters.malformed +%= 1;
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
            clearTx(c);
            c.snd_una = p.ack;
            c.state = .established;
            c.read_deadline = deadline(self.now);
        } else if (c.tx_started and p.ack == c.snd_nxt) {
            clearTx(c);
            c.snd_una = p.ack;
            if (c.state == .closing and c.peer_fin) {
                finish(c, .eof);
                // finish preserves queued clean input; final ACK still goes.
                ack(c);
                return;
            }
        }
        if (p.payload.len != 0) {
            if (c.peer_fin or c.rx_len != 0 or c.state == .closing) {
                self.counters.rx_full +%= 1;
                ack(c);
                return;
            }
            @memcpy(c.rx[0..p.payload.len], p.payload);
            c.rx_len = p.payload.len;
            c.rcv_nxt +%= @intCast(p.payload.len);
            ack(c);
        }
        if ((p.flags & wire.flag_fin) != 0) {
            c.rcv_nxt +%= 1;
            c.peer_fin = true;
            ack(c);
            if (c.tx_len == 0) {
                if (c.state == .closing) {
                    finish(c, .eof);
                    ack(c);
                } else {
                    queue(c, wire.flag_fin | wire.flag_ack, &.{}, self.now);
                    c.state = .closing;
                    c.phase_deadline = deadline(self.now);
                }
            }
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
            if (c.tx_len != 0 and c.tx_started and !c.tx_due and now - c.last_tx >= rto_ns) {
                if (c.retries >= retry_limit) {
                    finish(c, .timeout);
                    self.counters.timed_out +%= 1;
                } else c.tx_due = true;
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
fn same(a: Endpoint, b: Endpoint) bool {
    return a.port == b.port and std.mem.eql(u8, &a.ip, &b.ip);
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
}
fn build(c: *const Connection, buf: []u8, seq: u32, flags: u8, payload: []const u8) usize {
    const len = wire.build_segment(buf, c.local.ip, c.remote.ip, c.local.port, c.remote.port, seq, c.rcv_nxt, flags, payload);
    // One segment, not 4096 bytes of reassembly space. A partial read stays shut.
    std.mem.writeInt(u16, buf[14..16], if (c.rx_len == 0) wire.payload_max else 0, .big);
    @memset(buf[16..18], 0);
    std.mem.writeInt(u16, buf[16..18], wire.checksum_tcp(c.local.ip, c.remote.ip, buf[0..len]), .big);
    return len;
}
fn queue(c: *Connection, flags: u8, payload: []const u8, now: u64) void {
    c.tx_len = build(c, &c.tx, c.snd_nxt, flags, payload);
    c.snd_nxt +%= @intCast(payload.len + @as(usize, if ((flags & (wire.flag_syn | wire.flag_fin)) != 0) 1 else 0));
    c.tx_due = true;
    c.tx_started = false;
    c.retries = 0;
    c.last_tx = now;
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
    payload: []const u8,
};
fn parse(frame: []const u8) ?Parsed {
    if (frame.len < wire.frame_min or frame[12] != 8 or frame[13] != 0 or frame[14] != 0x45 or frame[23] != 6) return null;
    const ip = frame[14..34];
    if (wire.fold(wire.sum_words(ip)) != 0 or std.mem.readInt(u16, ip[6..8], .big) & 0xbfff != 0) return null;
    const length = std.mem.readInt(u16, ip[2..4], .big);
    if (length < 40 or length > 1500 or length + @as(usize, 14) > frame.len) return null;
    const seg = frame[34 .. 14 + @as(usize, length)];
    if (seg[12] != 0x50 or seg[13] & ~@as(u8, 0x1f) != 0 or (seg[13] & (wire.flag_syn | wire.flag_fin)) == (wire.flag_syn | wire.flag_fin)) return null;
    if (seg[13] & wire.flag_rst != 0 and (seg.len != wire.tcp_hdr_len or seg[13] & (wire.flag_syn | wire.flag_fin) != 0)) return null;
    const remote: [4]u8 = ip[12..16].*;
    const local: [4]u8 = ip[16..20].*;
    if (!validIp(remote) or wire.checksum_tcp(remote, local, seg) != 0) return null;
    const src_port = std.mem.readInt(u16, seg[0..2], .big);
    const dst_port = std.mem.readInt(u16, seg[2..4], .big);
    if (src_port == 0 or dst_port == 0) return null;
    return .{
        .local = .{ .ip = local, .port = dst_port },
        .remote = .{ .ip = remote, .port = src_port },
        .mac = frame[6..12].*,
        .seq = std.mem.readInt(u32, seg[4..8], .big),
        .ack = std.mem.readInt(u32, seg[8..12], .big),
        .flags = seg[13],
        .window = std.mem.readInt(u16, seg[14..16], .big),
        .payload = seg[20..],
    };
}
