//! B6 native service — now the ONE TCP socket table (M99f #2184, ADR 0007).
//! Up to four listeners (one per owner) and four connections in the bounded
//! core, plus one separately owned DNS transaction. The legacy slot 30–33/76
//! surface is a thin per-process view over this table (`legacy*` below); the
//! kernel-internal `tcp.zig` singleton stays for the monitor/front-end.
//! Handles are generation-tagged, process-owned, never file descriptors.
//! All operations probe; EL0 sleeps between probes. No scheduler entry here.
pub const core = @import("socket_core.zig");
const std = @import("std");
const timer = @import("timer.zig");
const builtin = @import("builtin");
const udp = @import("udp.zig");
const csprng = @import("csprng.zig");
const ipv6 = @import("ipv6.zig"); // M117c (#2475): the v6 TCP claim + legacyOpen6
const grant = @import("grant.zig"); // M117e (#2477): the net-scope check at the open ops
const klog = @import("klog.zig"); // M135c (#2765): the listen-saturated serial marker
pub var sockets: core.Core = .{};
/// M97e-F5 (#2104): the DNS transaction's client port is a FRESH
/// ephemeral draw per query (the IANA dynamic range 49152..65535) — a
/// fixed port let an off-path attacker spray replies at a known
/// destination; a per-transaction draw means a forged reply must guess
/// the port as well as the query id. `dns_port` is gone; `Dns.port`
/// carries the bound port.
pub const ephemeral_lo: u16 = 49152;
pub const ephemeral_span: u16 = 16384;
pub const dns_max = 64;
pub const Dns = struct {
    owner: u64,
    handle: core.Handle,
    server: [4]u8,
    id: u16,
    port: u16,
    deadline: u64,
    /// The outstanding query's question section (bytes 12.. of the
    /// encoded query) — the reply must echo it byte-exact (M97e-F5).
    question: [dns_max]u8 = undefined,
    question_len: usize = 0,
    reply: [dns_max]u8 = undefined,
    len: usize = 0,
    failed: bool = false,
    timed_out: bool = false,
};
pub var dns: ?Dns = null;
pub var test_now: u64 = 0;

pub fn now() u64 {
    if (builtin.is_test) return test_now;
    if (timer.freq == 0) return timer.ticks *| timer.period_ns;
    return @intCast(@min(std.math.maxInt(u64), @as(u128, timer.cntpct()) * timer.period_ns / timer.freq));
}
/// M99f (#2184): the RX claim `tcp.zig`'s `handle_rx` offers every TCP
/// frame to FIRST. True = the frame named a table-owned port and the
/// table consumed it (its own parse/counts — the singleton never sees it).
/// Registered the first time the table is polled; the kernel-internal
/// singleton is untouched until then.
/// M135c (#2765): one serial marker per saturating SYN — the counter
/// diff names the event, the port names the saturated listener, the
/// bound names itself. klog is a polled-uart write, safe inside the RX
/// drain's domain hold.
fn noteSaturated(before: u64, port: u16) void {
    if (sockets.counters.listen_saturated == before) return;
    var buf: [80]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "net: listen-saturated port={d} bound={d}\n", .{ port, core.child_limit }) catch "net: listen-saturated\n";
    klog.line(line);
}
/// #2875: the ONE table receive — every inbound path that feeds
/// `sockets.receive` wraps it in the saturated diff so `net:
/// listen-saturated` prints wherever the saturating SYN lands: tcp.zig's
/// claim, ipv6's, and ipv4.zig's slot-0 fast path (which calls this
/// directly — a direct `sockets.receive` there silently counted the
/// refusal without the marker). Other traffic leaves the counter alone
/// and the note is a no-op.
pub fn receiveTcp(frame: []const u8, port: u16) void {
    const saturated = sockets.counters.listen_saturated;
    sockets.receive(frame, now(), @truncate(csprng.random_u64())) catch unreachable;
    noteSaturated(saturated, port);
}
fn claimTcpFrame(frame: []const u8) bool {
    if (frame.len < core.wire.frame_min or frame[12] != 8 or frame[13] != 0 or
        frame[14] != 0x45 or frame[23] != core.wire.protocol_tcp) return false;
    const port = std.mem.readInt(u16, frame[36..38], .big);
    if (!sockets.tableOwns(port)) return false;
    receiveTcp(frame, port);
    return true;
}
/// M117c (#2475): the v6 half of `claimTcpFrame` — `ipv6.zig`'s terminal
/// dispatch hands VALIDATED v6/TCP frames (fixed header, next-header 6)
/// here; the claim gates on an owned dst address + a table-owned dst
/// port before the table's own parse sees it. Registered by
/// `registerTableRx` — the same delegate shape, on `ipv6.tcp6_rx`.
fn claimTcp6Frame(frame: []const u8) bool {
    if (frame.len < 14 + ipv6.ipv6_hdr_len + core.wire.tcp_hdr_len or
        frame[14] >> 4 != 6 or frame[20] != core.wire.protocol_tcp) return false;
    const dst = ipv6.dst_addr(frame);
    if (!ipv6.is_owned(&dst)) return false; // not ours — foreign, not a drop
    const port = std.mem.readInt(u16, frame[14 + ipv6.ipv6_hdr_len + 2 ..][0..2], .big);
    if (!sockets.tableOwns(port)) return false;
    receiveTcp(frame, port);
    return true;
}
pub fn registerTableRx() void {
    if (core.wire.table_rx == null) core.wire.table_rx = claimTcpFrame;
    if (ipv6.tcp6_rx == null) ipv6.tcp6_rx = claimTcp6Frame;
    if (ipv6.udp6_rx == null) ipv6.udp6_rx = udp.handle_rx6;
}
pub fn poll() void {
    registerTableRx();
    sockets.poll(now()) catch unreachable;
    if (dns) |*d| {
        if (d.len == 0 and !d.failed and now() >= d.deadline) d.timed_out = true;
    }
}
pub fn closeOwner(owner: u64) void {
    sockets.closeOwner(owner);
    if (dns) |d| if (d.owner == owner) {
        _ = udp.close_port(d.port);
        dns = null;
    };
}
pub fn close(owner: u64, handle: core.Handle) core.Error!void {
    if ((handle.value & core.slot_mask) != core.dns_slot) return sockets.close(owner, handle);
    const d = try dnsFor(owner, handle);
    _ = udp.close_port(d.port);
    dns = null;
}
/// M97e-F5 (#2104): draw a fresh ephemeral client port and bind it in
/// the bounded listen table. `null` after a bounded number of draws
/// (a table full of listeners, or a run of collisions) — an honest
/// Capacity, never a silent shared port.
fn ephemeralPort() ?u16 {
    var tries: usize = 0;
    while (tries < 8) : (tries += 1) {
        const port = ephemeral_lo + @as(u16, @truncate(csprng.random_u64())) % ephemeral_span;
        if (udp.listen_port(port)) return port;
    }
    return null;
}
pub fn beginDns(owner: u64, server: [4]u8, query: []const u8) core.Error!core.Handle {
    if (server[0] == 0 or server[0] == 127 or server[0] >= 224 or query.len < 17 or query.len > dns_max)
        return error.InvalidArgument;
    // M117e (#2477, ADR 0057 D12): the resolver's address is a
    // destination — the row's `if=` scope applies (a LAN resolver is a
    // `bridged` peer, the island's forwarder is `nat` fabric). M116d
    // (#2470): the `to=` tuple is (server, 53) — the resolver's only
    // destination port.
    if (grant.net_open(owner, .{ .v4 = server }, 53) != .allow and grant.enforceMode())
        return error.AccessDenied;
    if (dns != null or sockets.next_generation > std.math.maxInt(i64) >> core.slot_bits) return error.Capacity;
    // Pin one legacy listen-table seat so nobody can bind it concurrently.
    // A pre-existing bind is a capacity refusal, never silently intercepted.
    const port = ephemeralPort() orelse return error.Capacity;
    const handle: core.Handle = .{ .value = sockets.next_generation << core.slot_bits | core.dns_slot };
    sockets.next_generation += 1;
    var d = Dns{ .owner = owner, .handle = handle, .server = server, .id = std.mem.readInt(u16, query[0..2], .big), .port = port, .deadline = now() +| core.deadline_ns };
    @memcpy(d.question[0 .. query.len - 12], query[12..]); // the question echo the reply must carry
    d.question_len = query.len - 12;
    dns = d;
    return handle;
}
fn dnsFor(owner: u64, handle: core.Handle) core.Error!*Dns {
    const d = if (dns) |*d| d else return error.InvalidHandle;
    if (handle.value != d.handle.value) return error.InvalidHandle;
    if (owner != d.owner) return error.AccessDenied;
    return d;
}
pub fn readDns(owner: u64, handle: core.Handle, output: []u8) core.Error!usize {
    const d = try dnsFor(owner, handle);
    if (d.timed_out) return error.TimedOut;
    if (d.failed) return error.InvalidArgument;
    if (d.len == 0) return error.WouldBlock;
    if (output.len < d.len) return error.InvalidArgument;
    @memcpy(output[0..d.len], d.reply[0..d.len]);
    return d.len; // level-triggered until explicit close, never silently consumed
}
/// Called only after IPv4 checksum/destination/fragment validation.
pub fn receiveDns(frame: []const u8) bool {
    if (frame.len < 42 or frame[23] != 17) return false;
    const d = if (dns) |*d| d else return false;
    if (std.mem.readInt(u16, frame[36..38], .big) != d.port) return false;
    if (d.timed_out or d.len != 0 or d.failed) return true;
    const total = std.mem.readInt(u16, frame[16..18], .big);
    const length = std.mem.readInt(u16, frame[38..40], .big);
    if (total < 28 or @as(usize, total) + 14 > frame.len or length < 20 or length != total - 20 or
        !std.mem.eql(u8, frame[26..30], &d.server) or std.mem.readInt(u16, frame[34..36], .big) != 53) return true;
    const segment = frame[34 .. 14 + @as(usize, total)];
    // M97e-F5 (#2104): a ZERO UDP checksum is refused — IPv4 tolerates
    // it, but a resolver must not accept an unchecksummed datagram (the
    // sum is the only integrity check on the wire shape). A nonzero
    // field must verify.
    if (std.mem.readInt(u16, segment[6..8], .big) == 0 or
        udp.checksum_udp(d.server, frame[30..34].*, segment) != 0) return true;
    const reply = segment[8..];
    if (std.mem.readInt(u16, reply[0..2], .big) != d.id or reply[2] & 0x80 == 0) return true;
    // M97e-F5: the question section must echo the outstanding query's
    // byte-exact — a forged answer carrying the right id but a
    // DIFFERENT name is refused (RFC 1035 servers echo the question
    // verbatim; a case-rewritten echo is the honest bound).
    if (reply.len < 12 + d.question_len or
        !std.mem.eql(u8, reply[12 .. 12 + d.question_len], d.question[0..d.question_len])) return true;
    if (reply.len > dns_max) {
        d.failed = true;
    } else {
        @memcpy(d.reply[0..reply.len], reply);
        d.len = reply.len;
    }
    return true;
}
pub fn ready(owner: u64, handle: core.Handle) core.Error!u64 {
    if ((handle.value & core.slot_mask) == core.dns_slot) {
        const d = try dnsFor(owner, handle);
        return if (d.len != 0 or d.failed or d.timed_out) 1 else 0;
    }
    const r = try sockets.ready(owner, handle);
    // A readiness probe is the owner's liveness touch: callers that wait by
    // polling ready must not hit the abandonment deadline while watching.
    if ((handle.value & core.slot_mask) >= core.conn_slot_base)
        sockets.children[(handle.value & core.slot_mask) - core.conn_slot_base].?.read_deadline = now() +| core.deadline_ns;
    return @as(u64, @intFromBool(r.read)) | (@as(u64, @intFromBool(r.write)) << 1) |
        (@as(u64, @intFromBool(r.accept)) << 2) | (@as(u64, @intFromBool(r.terminal)) << 3);
}
pub fn peer(owner: u64, handle: core.Handle) core.Error!u64 {
    _ = try sockets.status(owner, handle);
    const c = sockets.children[(handle.value & core.slot_mask) - core.conn_slot_base].?;
    // M117c: the word marshal is v4-shaped; a v6 peer's address does not
    // fit, so only its port is reported (a v6 conn's caller already knows
    // the literal it dialed).
    if (c.remote.family == .v6) return c.remote.port;
    return ipWord(c.remote.ip) << 16 | c.remote.port;
}
pub fn ownedCount(owner: u64) u64 {
    var n: u64 = sockets.ownedSockets(owner);
    if (dns) |d| if (d.owner == owner) {
        n += 1;
    };
    return n;
}
pub fn ipWord(ip: [4]u8) u64 {
    return @as(u64, ip[0]) << 24 | @as(u64, ip[1]) << 16 | @as(u64, ip[2]) << 8 | ip[3];
}
pub fn ipBytes(value: u64) [4]u8 {
    return .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}

// ---------------------------------------------------------------------------
// M99f (#2184): the legacy slot 30–33/76 shim — a handle-less per-process
// view over the ONE table. The handle ABI (slot 80) is unchanged; the
// kernel-internal tcp.zig singleton still serves the monitor/front-end.
// ---------------------------------------------------------------------------

/// Owner key for a pid-less caller (kernel/test dispatch) — unreachable by
/// any real process, matching "nobody owns it" for legacy purposes.
pub const unowned: u64 = std.math.maxInt(u64);

/// Every TCP local port that is taken system-wide: the table's listeners
/// and connections plus the kernel-internal singleton's listen/client port.
pub fn tcpPortClaimed(port: u16) bool {
    if (sockets.portClaimed(port)) return true;
    const t = core.wire;
    if (t.state != .idle and t.state != .closed) {
        if (t.is_server) return t.listen_port == port;
        return port == t.default_src_port;
    }
    return false;
}

/// The caller's legacy listener slot, if it holds one.
pub fn legacyListenerSlot(owner: u64) ?u64 {
    for (0..core.listener_limit) |slot| if (sockets.listenerAt(slot)) |l| {
        if (l.owner == owner and l.legacy) return slot;
    };
    return null;
}

/// The handle-less "current connection" slots 31–33/76 operate on: the
/// caller's active-open socket wins; else its legacy listener's children —
/// the serving (already-claimed) child first, then a terminal child whose
/// verdict the transport still needs, and only then an unaccepted one.
/// Order matters now that multiplicity admits a second child: the session
/// being served keeps the shim (a later connection WAITS), and a terminal
/// child's .closed verdict outranks a queued accept so waitPeerGone still
/// exits on the mask it watched the singleton produce. Implicit accept
/// marks the child (a shim listener's handle never escapes the kernel, so
/// slot-80 accept cannot double-serve). Explicit close/release frees it.
pub fn legacyConn(owner: u64) ?*core.Connection {
    for (&sockets.children) |*entry| if (entry.*) |*c| {
        if (c.owner == owner and c.parent == core.no_parent) return c;
    };
    const slot = legacyListenerSlot(owner) orelse return null;
    var serving: ?*core.Connection = null;
    var draining: ?*core.Connection = null;
    var pending: ?*core.Connection = null;
    for (&sockets.children) |*entry| if (entry.*) |*c| {
        if (c.parent != slot or c.state == .half_open) continue;
        if (c.state == .terminal) {
            if (draining == null) draining = c;
        } else if (c.accepted) {
            if (serving == null) serving = c;
        } else if (pending == null) {
            pending = c;
        }
    };
    if (serving) |c| return c;
    if (draining) |c| return c;
    if (pending) |c| {
        c.accepted = true;
        return c;
    }
    return null;
}

/// The connection's own table slot — callers pass the pointer `legacyConn`
/// returned, then close/release by handle-free slot id.
pub fn connSlot(c: *core.Connection) u64 {
    for (&sockets.children, 0..) |*entry, i| {
        if (entry.*) |*e| if (e == c) return core.conn_slot_base + i;
    }
    unreachable; // a live conn's slot always exists
}
/// Free a connection slot the shim owns (post-outcome or explicit close).
pub fn releaseConn(c: *core.Connection) void {
    sockets.releaseAt(connSlot(c));
}

/// Passive open for legacy slot 30: re-bind replaces the caller's own
/// legacy listener (today's `tcp.listen` semantics); any other claim on
/// the port — a table listener/connection, another owner's legacy
/// listener, or the kernel-internal singleton — is ENOSPC.
pub fn legacyListen(owner: u64, local_ip: [4]u8, port: u16) core.Error!void {
    registerTableRx(); // an extra-slot listener's SYNs arrive before any poll
    if (legacyListenerSlot(owner)) |slot| sockets.releaseAt(slot);
    if (tcpPortClaimed(port)) return error.Capacity;
    const handle = try sockets.listen(owner, core.ep4(local_ip, port), now());
    try sockets.markLegacy(owner, handle);
}

/// Active open for legacy slot 30: allocate the caller's outbound
/// connection with the SYN already queued in its bounded TX slot — the
/// same engine, deadline and RTO every child carries. Local port is the
/// deterministic 8000 when free, else an honest ephemeral draw that
/// skips every claimed TCP port.
pub fn legacyOpen(owner: u64, local_ip: [4]u8, remote_ip: [4]u8, remote_port: u16, remote_mac: [6]u8, isn: u32) core.Error!core.Handle {
    // M117e (#2477, ADR 0057 D12): the grant row's `net` scope — a
    // `bridged`-class destination (an L2-adjacent peer) outside the row's
    // `if=` set is refused by name; M116d (#2470) adds the `to=`
    // (literal, port) allowlist on the same check. `audit` receipts and
    // proceeds; `enforce` is an honest EACCES before any slot is spent.
    if (grant.net_open(owner, .{ .v4 = remote_ip }, remote_port) != .allow and grant.enforceMode())
        return error.AccessDenied;
    registerTableRx(); // the outbound conn's SYN-ACK can arrive before any poll
    const port = allocLocalPort() orelse return error.Capacity;
    return sockets.open(owner, core.ep4(local_ip, port), core.ep4(remote_ip, remote_port), remote_mac, now(), isn);
}

/// M117c (#2475, ADR 0057 D8/D10): the v6 half of `legacyOpen` — the
/// slot-80 op-10 marshal hands the caller's v6 literal (the pointer-
/// carried 16 bytes); `local6` is the kernel's select_src answer and
/// `remote_mac` the resolved NEXT HOP (the peer on-link, the router
/// off-link). One bounded connection slot and the same port claim as
/// v4 — the family's bounds are shared.
pub fn legacyOpen6(owner: u64, local6: ipv6.Addr, remote6: ipv6.Addr, remote_port: u16, remote_mac: [6]u8, isn: u32) core.Error!core.Handle {
    // M117e (#2477, ADR 0057 D12): the v6 half of the scope check — the
    // literal is matched against the row's `v6=` prefixes AND its path
    // class against `if=`; M116d (#2470) adds the `to=` (literal, port)
    // allowlist — `to=[v6]:port` entries gate v6 connects the same way.
    // Off-policy refuses by name (enforce) or receipts it (audit).
    if (grant.net_open(owner, .{ .v6 = remote6 }, remote_port) != .allow and grant.enforceMode())
        return error.AccessDenied;
    registerTableRx(); // the outbound conn's SYN-ACK can arrive before any poll
    const port = allocLocalPort() orelse return error.Capacity;
    return sockets.open(owner, core.ep6(local6, port), core.ep6(remote6, remote_port), remote_mac, now(), isn);
}
fn allocLocalPort() ?u16 {
    if (!tcpPortClaimed(core.wire.default_src_port)) return core.wire.default_src_port;
    var tries: usize = 0;
    while (tries < 8) : (tries += 1) {
        const port = ephemeral_lo + @as(u16, @truncate(csprng.random_u64())) % ephemeral_span;
        if (!tcpPortClaimed(port)) return port;
    }
    return null;
}

/// slot 76's readiness over the shim view — the singleton's ready_mask
/// shape: bit0 = a read outcome is pending (queued bytes, EOF, close, a
/// peer FIN/RST), bit1 = established with nothing unacked in flight.
/// WouldBlock when the caller holds no socket (the handler maps EAGAIN).
/// #2436 diagnostics: the last bit-0 probe's full shape — whether the
/// caller's "readable-but-empty = peer gone" verdict fired on queued
/// RX data (a race between the 0-recv and the probe) or an honest
/// FIN/terminal/closing. Bounded: one record + a count.
pub const ReadyProbe = struct {
    rx_len: usize,
    peer_fin: bool,
    state: core.State,
    outcome: core.Outcome,
    lport: u16,
    rport: u16,
    in_flight: u32,
};
pub var ready_mask1_count: u64 = 0;
pub var ready_mask1_probe: ReadyProbe = .{
    .rx_len = 0,
    .peer_fin = false,
    .state = .terminal,
    .outcome = .none,
    .lport = 0,
    .rport = 0,
    .in_flight = 0,
};

pub fn legacyReady(owner: u64) core.Error!u64 {
    const c = legacyConn(owner) orelse {
        if (legacyListenerSlot(owner) != null) return 0;
        return error.WouldBlock;
    };
    // The probe is a read-only query on the wire, but it is still the
    // owner's liveness touch — the drain-driven transport and vi.Conn.Recv
    // both keep a conn alive by polling ready alone. Without this slide a
    // silently-waited conn would hit the 30 s abandonment deadline while
    // its owner watches it (the singleton had no such deadline).
    c.read_deadline = now() +| core.deadline_ns;
    var mask: u64 = 0;
    if (c.rx_len != 0 or c.peer_fin or c.state == .terminal or c.state == .closing) mask |= 1;
    if (c.state == .established and c.tx_len == 0) mask |= 2;
    if (mask & 1 != 0) {
        ready_mask1_count +%= 1;
        ready_mask1_probe = .{
            .rx_len = c.rx_len,
            .peer_fin = c.peer_fin,
            .state = c.state,
            .outcome = c.outcome,
            .lport = c.local.port,
            .rport = c.remote.port,
            .in_flight = c.snd_nxt -% c.snd_una,
        };
    }
    return mask;
}
