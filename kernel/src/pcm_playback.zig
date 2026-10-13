//! Serialized production PCM pump over the device-free ownership model.
//! The transport owns DMA layout; replies return ownership, not audible proof.
const std = @import("std");
pub const pcm = @import("pcm_stream.zig");

pub const limits = pcm.Limits{
    .control_ns = 5_000_000_000,
    .period_ns = 5_000_000_000,
    .drain_ns = 5_000_000_000,
};
pub const RawCompletion = struct { head: u32, written: usize, ok: bool };
pub const Io = struct {
    context: *anyopaque,
    params: *const fn (*anyopaque, pcm.Params) bool,
    control: *const fn (*anyopaque, pcm.Control) bool,
    publish: *const fn (*anyopaque, pcm.Transfer, []const u8) void,
    poll: *const fn (*anyopaque) ?RawCompletion,
    clock: ?*const fn (*anyopaque) u64 = null,

    fn time(self: Io, fallback: u64) u64 {
        return if (self.clock) |read| read(self.context) else fallback;
    }
};

/// M99b (ADR 0046): optional observer the mixer hangs on the pump. `feed`
/// runs between completion drain and publish so composed periods fill
/// freshly-freed slots in the same drive pass; `completed` resolves the
/// per-source byte credit for a device-acked slot index.
pub const Hook = struct {
    context: *anyopaque,
    feed: ?*const fn (*anyopaque, *pcm.Model) void = null,
    completed: ?*const fn (*anyopaque, usize) void = null,
};

pub const Playback = struct {
    model: pcm.Model = .{},
    transfers: [pcm.slot_count]?pcm.Transfer = @splat(null),
    hook: ?Hook = null,
    starts: u64 = 0,
    stops: u64 = 0,
    releases: u64 = 0,
    resets: u64 = 0,

    pub fn open(self: *Playback, owner: u64, capabilities: pcm.Capabilities, requested: pcm.Params, now: u64, io: Io) pcm.Error!pcm.StreamToken {
        const token = try self.model.open(owner, capabilities, requested, limits, now);
        self.transfers = @splat(null);
        self.starts = 0;
        self.stops = 0;
        self.releases = 0;
        self.resets = 0;
        if (!io.params(io.context, requested)) {
            try self.model.control_reply(self.model.control().?, false, now);
            self.drive(now, io);
            return error.DeviceFailed;
        }
        self.drive(io.time(now), io);
        if (self.model.state != .prepared) return error.DeviceFailed;
        return token;
    }

    /// Bounded nonblocking TX work. Control exchanges have the transport's
    /// bounded wait, and run only in syscall/main context, never the IRQ pump.
    pub fn drive(self: *Playback, now: u64, io: Io) void {
        self.model.tick(now) catch return;
        if (self.model.state != .resetting and self.model.state != .quarantined) {
            for (0..pcm.slot_count) |_| {
                const raw = io.poll(io.context) orelse break;
                const index = raw.head / pcm.descriptors_per_period;
                const transfer = if (raw.head % pcm.descriptors_per_period == 0 and index < pcm.slot_count)
                    self.transfers[index]
                else
                    null;
                const t = transfer orelse pcm.Transfer{
                    .generation = self.model.generation,
                    .serial = 0,
                    .head = std.math.maxInt(u32),
                    .length = 0,
                };
                self.model.complete(.{ .transfer = t, .written = raw.written, .ok = raw.ok }, now) catch break;
                self.transfers[index] = null;
                if (self.hook) |h| {
                    if (h.completed) |credit| credit(h.context, index);
                }
            }
        }
        if (self.hook) |h| {
            if (h.feed) |feed| feed(h.context, &self.model);
        }
        // Prepared periods stay software-queued until explicit START. This
        // makes prefill/backpressure independent of how fast the device is.
        if (self.model.state == .starting or self.model.state == .running or self.model.state == .draining) {
            for (0..pcm.slot_count) |_| {
                const transfer = self.model.publish(now) catch break;
                self.transfers[transfer.head / pcm.descriptors_per_period] = transfer;
                io.publish(io.context, transfer, self.model.payload(transfer) catch unreachable);
            }
        }
        for (0..4) |_| {
            const ticket = self.model.control() orelse break;
            switch (ticket.kind) {
                .start => self.starts += 1,
                .stop => self.stops += 1,
                .release => self.releases += 1,
                .reset => self.resets += 1,
                .prepare => {},
            }
            const ok = io.control(io.context, ticket.kind);
            // A control wait must not acknowledge using its pre-wait time.
            // Expiry can replace this ticket with RESET while it was in flight.
            self.model.control_reply(ticket, ok, io.time(now)) catch break;
            if (ticket.kind == .reset and ok) self.transfers = @splat(null);
        }
    }
};

// ---------------------------------------------------------------------------
// M99b (ADR 0046): bounded multi-source kernel mixer over the same B7 pump.
// `source_count` owner/generation seats each hold a `source_periods`-deep
// queue. `feed` composes one output period per free model slot by summing
// the head period of every live/draining seat in f32, clamping to [-1,1]
// (counted), encoding in the negotiated device format, and running the
// post-mix volume/mute hook exactly once (slots 44/45 choke point — no
// per-submit scaling). An empty live seat contributes silence and counts a
// per-source underrun; the device stream never dies on one source's
// starvation. Sources share the model's negotiated tuple — no resampling.

pub const source_count = 4;
pub const source_periods = 4;
/// Device-stream ownership sentinel: never a real process id.
pub const mixer_owner: u64 = std.math.maxInt(u64);

pub const MixerError = error{TableFull} || pcm.Error;

pub const SourceState = enum { free, idle, live, draining };

/// Post-close snapshot: status reads keep working after end/abort/death.
pub const SourceLast = struct {
    valid: bool = false,
    owner: u64 = 0,
    generation: u64 = 0,
    counts: pcm.Counts = .{},
    underruns: u64 = 0,
    state: pcm.State = .closed,
    reason: pcm.Reason = .none,
};

pub const Source = struct {
    storage: [source_periods][pcm.period_bytes]u8 align(64) = undefined,
    length: [source_periods]u16 = @splat(0),
    head: u8 = 0,
    count: u8 = 0,
    owner: u64 = 0,
    generation: u64 = 0,
    state: SourceState = .free,
    /// ADR 0046 D4: per-source gain is wired into the mix, no setter op yet.
    gain_percent: u8 = 100,
    counts: pcm.Counts = .{},
    underruns: u64 = 0,
    /// Bytes inside composed output periods not yet completed/canceled. A
    /// freed seat stays unreusable while inflight is nonzero so an old
    /// generation's in-flight bytes never credit a new owner of the seat.
    inflight: u64 = 0,
    last: SourceLast = .{},
};

pub const Mixer = struct {
    playback: Playback = .{},
    /// Token the mixer holds on the device stream (owner = mixer_owner).
    token: pcm.StreamToken = .{ .owner = 0, .generation = 0 },
    sources: [source_count]Source = @splat(.{}),
    next_generation: u64 = 0,
    open_count: u8 = 0,
    peak_sources: u8 = 0,
    /// Over-cap opens refused (ENOSPC at the syscall seam) — the card's
    /// refusal counter. Persists across device-stream generations.
    refused: u64 = 0,
    /// Samples clamped at the post-sum saturation.
    clipped: u64 = 0,
    /// Byte credit per device slot: which source's bytes are inside each
    /// composed period, resolved on completion to per-source counters.
    contrib: [pcm.slot_count][source_count]u16 = @splat(@splat(0)),
    /// Slots 44/45 choke point: applied to each composed period post-sum.
    post_mix: ?*const fn (*anyopaque, []u8) void = null,
    post_mix_ctx: *anyopaque = undefined,

    /// Open a source seat. The first open prepares the device stream;
    /// later opens must request the tuple it already negotiated. Over-cap
    /// opens refuse with error.TableFull (ENOSPC) and count; a draining
    /// device stream refuses with error.Busy (EAGAIN).
    pub fn open(self: *Mixer, owner: u64, capabilities: ?pcm.Capabilities, requested: pcm.Params, now: u64, io: Io) MixerError!pcm.StreamToken {
        const model = &self.playback.model;
        self.reconcile();
        if (model.state == .quarantined) return error.Quarantined;
        if (model.state == .closed) {
            self.contrib = @splat(@splat(0));
            self.clipped = 0;
            self.token = try self.playback.open(mixer_owner, capabilities orelse return error.NoDevice, requested, now, io);
            self.arm_hooks();
        } else {
            switch (model.state) {
                .prepared, .starting, .running => {},
                else => return error.Busy,
            }
            if (!std.meta.eql(model.params, requested)) return error.UnsupportedFormat;
        }
        const s = self.free_slot() orelse {
            self.refused += 1;
            return error.TableFull;
        };
        if (self.next_generation == std.math.maxInt(u64)) return error.Exhausted;
        self.next_generation += 1;
        const last = s.last;
        s.* = .{ .owner = owner, .generation = self.next_generation, .state = .idle };
        s.last = last;
        self.open_count += 1;
        self.peak_sources = @max(self.peak_sources, self.open_count);
        return .{ .owner = owner, .generation = s.generation };
    }

    /// Live seat for a token, or null (closed/freed sources live in `last`).
    pub fn source_of(self: *Mixer, token: pcm.StreamToken) ?*Source {
        for (&self.sources) |*s| {
            if (s.state != .free and s.owner == token.owner and s.generation == token.generation) return s;
        }
        return null;
    }

    /// Post-close snapshot for a token (status reads after end/abort/death).
    pub fn last_of(self: *Mixer, token: pcm.StreamToken) ?SourceLast {
        for (&self.sources) |*s| {
            if (s.last.valid and s.last.owner == token.owner and s.last.generation == token.generation) return s.last;
        }
        return null;
    }

    /// Validate token + period geometry, return the tail slot the caller's
    /// copy-in fills. Nothing is accepted until `submit_commit` after a
    /// successful copy — a fault leaves zero bytes accepted.
    pub const Submit = struct { source: *Source, dst: []u8 };
    pub fn submit_begin(self: *Mixer, token: pcm.StreamToken, len: usize) MixerError!Submit {
        const s = self.source_of(token) orelse return error.InvalidToken;
        if (len == 0 or len > pcm.period_bytes or len % self.playback.model.params.frame_bytes() != 0)
            return error.InvalidPeriod;
        if (s.state != .idle and s.state != .live) return error.InvalidState;
        if (s.count == source_periods) return error.Backpressure;
        return .{ .source = s, .dst = &s.storage[(s.head + s.count) % source_periods] };
    }

    pub fn submit_commit(_: *Mixer, sub: Submit, len: usize) void {
        const s = sub.source;
        s.length[(s.head + s.count) % source_periods] = @intCast(len);
        s.count += 1;
        s.counts.accepted += len;
        s.counts.outstanding += len;
    }

    /// Move a source from idle to live. The first live source prefills the
    /// model and issues device START; sources joining a running stream just
    /// start contributing to the next composed period.
    pub fn start(self: *Mixer, token: pcm.StreamToken, now: u64) MixerError!void {
        const s = self.source_of(token) orelse return error.InvalidToken;
        if (s.state != .idle) return error.InvalidState;
        if (s.count == 0) return error.NotPrefilled;
        const model = &self.playback.model;
        switch (model.state) {
            .prepared => {
                s.state = .live;
                self.feed(model);
                model.start(self.token, now) catch |err| {
                    s.state = .idle;
                    return err;
                };
            },
            .starting, .running => s.state = .live,
            else => return error.InvalidState,
        }
    }

    /// Drain this source: its queued periods keep mixing; the seat frees
    /// when they are consumed (or on the next compose once empty).
    pub fn end(self: *Mixer, token: pcm.StreamToken, now: u64) MixerError!void {
        const s = self.source_of(token) orelse return error.InvalidToken;
        if (s.state != .live) return error.InvalidState;
        s.state = .draining;
        if (s.count == 0) self.drop_seat(s, .none, .closed, now);
    }

    /// Cancel this source now: queued bytes count as canceled; in-flight
    /// bytes resolve to canceled/completed as the device answers.
    pub fn abort(self: *Mixer, token: pcm.StreamToken, now: u64) MixerError!void {
        const s = self.source_of(token) orelse return error.InvalidToken;
        self.drop_seat(s, .aborted, .closed, now);
    }

    /// Process-exit teardown: every seat the dead owner held is freed at
    /// once; the device stream survives on the remaining sources.
    pub fn owner_death(self: *Mixer, owner: u64, now: u64) void {
        for (&self.sources) |*s| {
            if (s.state != .free and s.owner == owner) self.free_seat(s, .owner_died, .closed);
        }
        if (self.open_count == 0) self.end_model(now);
    }

    /// Bounded nonblocking pump: completions feed fresh composes in the
    /// same pass, then terminal-state reconcile reaps seats the device
    /// stream took down with it.
    pub fn drive(self: *Mixer, now: u64, io: Io) void {
        if (self.playback.model.state != .closed) self.playback.drive(now, io);
        self.reconcile();
    }

    fn arm_hooks(self: *Mixer) void {
        self.playback.hook = .{ .context = self, .feed = feed_hook, .completed = completed_hook };
    }

    fn feed_hook(ctx: *anyopaque, model: *pcm.Model) void {
        const self: *Mixer = @ptrCast(@alignCast(ctx));
        self.feed(model);
    }

    fn completed_hook(ctx: *anyopaque, slot: usize) void {
        const self: *Mixer = @ptrCast(@alignCast(ctx));
        const row = &self.contrib[slot];
        for (row, 0..) |n, i| {
            if (n == 0) continue;
            const s = &self.sources[i];
            if (s.state == .free) {
                s.last.counts.completed += n;
                s.last.counts.outstanding -= n;
            } else {
                s.counts.completed += n;
                s.counts.outstanding -= n;
            }
            s.inflight -= n;
        }
        row.* = @splat(0);
    }

    /// Compose one output period into each free model slot. Runs while the
    /// model accepts queued periods (.prepared is the pre-START fill;
    /// .running is the steady state). Source bytes move to
    /// submitted/in-flight only after the composed period commits.
    pub fn feed(self: *Mixer, model: *pcm.Model) void {
        if (model.state != .prepared and model.state != .running) return;
        if (!self.any_active()) return;
        while (model.queue_len + model.owned < pcm.slot_count) {
            const res = model.reserve(self.token, pcm.period_bytes) catch break;
            var row: [source_count]u16 = @splat(0);
            self.compose(model.storage[res.slot][0..pcm.period_bytes], &row);
            model.commit_in_place(res) catch break;
            self.contrib[res.slot] = row;
            self.consume(&row);
        }
    }

    fn any_active(self: *const Mixer) bool {
        for (&self.sources) |*s| {
            if (s.state == .live or s.state == .draining) return true;
        }
        return false;
    }

    /// Sum head periods of every active seat into `out` in f32 with
    /// per-source gain, clamp to [-1,1] (counted), encode in the device
    /// format, and run the post-mix hook. `row` records byte contributions;
    /// queues are not consumed until `consume`, after commit.
    fn compose(self: *Mixer, out: []u8, row: *[source_count]u16) void {
        var parts: [source_count]?[]const u8 = @splat(null);
        for (&self.sources, 0..) |*s, i| {
            if (s.state != .live and s.state != .draining) continue;
            if (s.count > 0) {
                parts[i] = s.storage[s.head][0..s.length[s.head]];
                row[i] = @intCast(parts[i].?.len);
            } else if (s.state == .live) {
                // Played silence this period — starvation is per-source data.
                s.underruns += 1;
            }
        }
        const negotiated = self.playback.model.params;
        const frame = negotiated.frame_bytes();
        const ch_bytes = frame / negotiated.channels;
        @memset(out, 0);
        var f: usize = 0;
        while (f * frame < out.len) : (f += 1) {
            var c: usize = 0;
            while (c < negotiated.channels) : (c += 1) {
                var acc: f32 = 0;
                for (0..source_count) |i| {
                    const part = parts[i] orelse continue;
                    const off = f * frame + c * ch_bytes;
                    if (off + ch_bytes > part.len) continue;
                    const gain = @as(f32, @floatFromInt(self.sources[i].gain_percent)) / 100.0;
                    acc += decode(part[off..][0..ch_bytes], negotiated.format) * gain;
                }
                if (acc > 1.0) {
                    acc = 1.0;
                    self.clipped += 1;
                } else if (acc < -1.0) {
                    acc = -1.0;
                    self.clipped += 1;
                }
                encode(out[f * frame + c * ch_bytes ..][0..ch_bytes], acc, negotiated.format);
            }
        }
        if (self.post_mix) |pm| pm(self.post_mix_ctx, out);
    }

    /// Pop the head periods `compose` drew from: byte credit moves to
    /// submitted and in-flight; a drained source releases its seat.
    fn consume(self: *Mixer, row: *const [source_count]u16) void {
        for (&self.sources, 0..) |*s, i| {
            const n = row[i];
            if (n == 0) continue;
            s.head = (s.head + 1) % source_periods;
            s.count -= 1;
            s.counts.submitted += n;
            s.inflight += n;
            if (s.state == .draining and s.count == 0)
                self.drop_seat(s, .none, .closed, self.playback.model.now);
        }
    }

    /// Free a seat and, when it was the last source, end the device stream:
    /// drain while running, abort the control exchange otherwise.
    fn drop_seat(self: *Mixer, s: *Source, reason: pcm.Reason, state: pcm.State, now: u64) void {
        self.free_seat(s, reason, state);
        if (self.open_count == 0) self.end_model(now);
    }

    /// Snapshot the seat's accounting into `last` and release it. Queued-
    /// but-uncomposed bytes count as canceled; in-flight bytes resolve via
    /// completion credit to the snapshot. `inflight` survives on the seat
    /// so it cannot be reallocated while old bytes are still owned.
    fn free_seat(self: *Mixer, s: *Source, reason: pcm.Reason, state: pcm.State) void {
        var queued: u64 = 0;
        for (0..s.count) |i| queued += s.length[(s.head + i) % source_periods];
        s.counts.canceled += queued;
        s.counts.outstanding -= queued;
        s.last = .{ .valid = true, .owner = s.owner, .generation = s.generation, .counts = s.counts, .underruns = s.underruns, .state = state, .reason = reason };
        s.owner = 0;
        s.generation = 0;
        s.state = .free;
        s.head = 0;
        s.count = 0;
        s.gain_percent = 100;
        s.counts = .{};
        s.underruns = 0;
        self.open_count -= 1;
    }

    fn free_slot(self: *Mixer) ?*Source {
        for (&self.sources) |*s| {
            if (s.state == .free and s.inflight == 0) return s;
        }
        return null;
    }

    fn end_model(self: *Mixer, now: u64) void {
        const model = &self.playback.model;
        switch (model.state) {
            .running => model.end(self.token, now) catch {},
            .prepared, .starting, .draining => model.abort(self.token, now) catch {},
            else => {},
        }
    }

    /// When the device stream reaches a terminal state on its own (reset
    /// ack, quarantine) every open seat dies with it: in-flight and queued
    /// contributions count as canceled and `last` carries the model's
    /// reason. Idempotent; also runs at open() entry.
    fn reconcile(self: *Mixer) void {
        const model = &self.playback.model;
        const st = model.state;
        if (st != .closed and st != .quarantined) return;
        for (&self.contrib) |*row| {
            for (row, 0..) |n, i| {
                if (n == 0) continue;
                const s = &self.sources[i];
                if (s.state == .free) {
                    s.last.counts.canceled += n;
                    s.last.counts.outstanding -= n;
                } else {
                    s.counts.canceled += n;
                    s.counts.outstanding -= n;
                }
                s.inflight -= n;
            }
            row.* = @splat(0);
        }
        for (&self.sources) |*s| {
            if (s.state != .free) self.free_seat(s, model.reason, st);
        }
    }

    fn decode(frame: []const u8, format: pcm.Format) f32 {
        return switch (format) {
            .float32 => @bitCast(std.mem.readInt(u32, frame[0..4], .little)),
            .s32 => @as(f32, @floatFromInt(std.mem.readInt(i32, frame[0..4], .little))) / 2147483648.0,
            .s16 => @as(f32, @floatFromInt(std.mem.readInt(i16, frame[0..2], .little))) / 32768.0,
        };
    }

    fn encode(frame: []u8, v: f32, format: pcm.Format) void {
        switch (format) {
            .float32 => std.mem.writeInt(u32, frame[0..4], @bitCast(v), .little),
            .s32 => std.mem.writeInt(i32, frame[0..4], @intFromFloat(v * 2147483647.0), .little),
            .s16 => std.mem.writeInt(i16, frame[0..2], @intFromFloat(v * 32767.0), .little),
        }
    }
};

pub const Fixture = struct {
    params_ok: bool = true,
    fail: ?pcm.Control = null,
    completed: [pcm.slot_count]?RawCompletion = @splat(null),
    published: [pcm.slot_count]?pcm.Transfer = @splat(null),
    pub fn io(self: *Fixture) Io {
        return .{ .context = self, .params = set, .control = control, .publish = publish, .poll = poll };
    }
    fn set(ctx: *anyopaque, _: pcm.Params) bool {
        return (@as(*Fixture, @ptrCast(@alignCast(ctx)))).params_ok;
    }
    fn control(ctx: *anyopaque, kind: pcm.Control) bool {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.fail == kind) return false;
        if (kind == .reset) {
            self.completed = @splat(null);
            self.published = @splat(null);
        }
        return true;
    }
    fn publish(ctx: *anyopaque, transfer: pcm.Transfer, payload: []const u8) void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        std.debug.assert(payload.len == transfer.length);
        self.published[transfer.head / pcm.descriptors_per_period] = transfer;
    }
    fn poll(ctx: *anyopaque) ?RawCompletion {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        for (&self.completed) |*entry| {
            if (entry.*) |raw| {
                entry.* = null;
                return raw;
            }
        }
        return null;
    }
    pub fn complete(self: *Fixture, slot: usize) void {
        const transfer = self.published[slot].?;
        self.published[slot] = null;
        self.completed[slot] = .{ .head = transfer.head, .written = 8, .ok = true };
    }
};
const caps = pcm.Capabilities{ .present = true, .output = true, .queue_descriptors = 32, .formats = &.{.float32}, .rates_hz = &.{48000}, .channels_min = 1, .channels_max = 2 };
const params = pcm.Params{ .format = .float32, .rate_hz = 48000, .channels = 2 };
const samples = @as([pcm.period_bytes]u8, @splat(@as(u8, 0x5a)));

test "PCM pump: continuous 128 KiB, eight slots, one START/STOP/RELEASE" {
    var device = Fixture{};
    var stream = Playback{};
    const token = try stream.open(42, caps, params, 0, device.io());
    for (0..8) |_| _ = try stream.model.submit(token, &samples);
    try std.testing.expectError(error.Backpressure, stream.model.submit(token, &samples));
    try std.testing.expectEqual(@as(u64, 32768), stream.model.counts.accepted);
    try stream.model.start(token, 0);
    stream.drive(0, device.io());
    for (0..24) |i| {
        device.complete(i % 8);
        stream.drive(1, device.io());
        _ = try stream.model.submit(token, &samples);
        stream.drive(1, device.io());
        try std.testing.expectEqual(pcm.State.running, stream.model.state);
        try std.testing.expect(stream.model.counts.outstanding <= pcm.pcm_bytes);
    }
    try stream.model.end(token, 1);
    for (0..8) |i| device.complete(i);
    stream.drive(2, device.io());
    try std.testing.expectEqual(pcm.State.closed, stream.model.state);
    try std.testing.expectEqual(@as(u64, 131072), stream.model.counts.completed);
    try std.testing.expectEqual(@as(u64, 1), stream.starts);
    try std.testing.expectEqual(@as(u64, 1), stream.stops);
    try std.testing.expectEqual(@as(u64, 1), stream.releases);
    try std.testing.expectEqual(@as(u64, 0), stream.resets);
}

test "PCM pump: refusal, starved-queue survival, abort and owner death reclaim only after reset" {
    var device = Fixture{};
    var stream = Playback{};
    var absent = caps;
    absent.present = false;
    try std.testing.expectError(error.NoDevice, stream.open(42, absent, params, 0, device.io()));
    device.params_ok = false;
    try std.testing.expectError(error.DeviceFailed, stream.open(42, caps, params, 0, device.io()));
    try std.testing.expectEqual(pcm.State.closed, stream.model.state);
    device.params_ok = true;
    const token = try stream.open(42, caps, params, 0, device.io());
    _ = try stream.model.submit(token, &samples);
    try stream.model.start(token, 0);
    stream.drive(0, device.io());
    device.complete(0);
    stream.drive(1, device.io());
    // M99b: an empty queue is per-source starvation, not stream death — the
    // model keeps running and accepts more data (underrun counts live on
    // the mixer's source seats now).
    try std.testing.expectEqual(pcm.State.running, stream.model.state);
    try std.testing.expectEqual(pcm.Reason.none, stream.model.reason);
    _ = try stream.model.submit(token, &samples);
    try stream.model.abort(token, 1);
    stream.drive(1, device.io());
    for ([_]bool{ false, true }) |death| {
        const next = try stream.open(42, caps, params, 1, device.io());
        _ = try stream.model.submit(next, &samples);
        try stream.model.start(next, 1);
        stream.drive(1, device.io());
        if (death) try stream.model.owner_death(42, 1) else try stream.model.abort(next, 1);
        stream.drive(1, device.io());
        try std.testing.expectEqual(@as(u64, 1), stream.resets);
        try std.testing.expectEqual(@as(u64, 4096), stream.model.counts.canceled);
        try std.testing.expectEqual(pcm.State.closed, stream.model.state);
    }
}

test "PCM pump: malformed/failed completions, timeout and failed reset quarantine" {
    for (0..4) |failure| {
        var device = Fixture{};
        var stream = Playback{};
        const token = try stream.open(42, caps, params, 0, device.io());
        _ = try stream.model.submit(token, &samples);
        try stream.model.start(token, 0);
        stream.drive(0, device.io());
        if (failure < 3) device.completed[0] = .{
            .head = if (failure == 0) 31 else 0,
            .written = if (failure == 1) 4 else 8,
            .ok = failure != 2,
        };
        device.fail = .reset;
        stream.drive(if (failure == 3) limits.period_ns else 1, device.io());
        try std.testing.expectEqual(pcm.State.quarantined, stream.model.state);
        try std.testing.expectEqual(@as(usize, 4096), stream.model.counts.outstanding);
        try std.testing.expectEqualSlices(u8, &samples, &stream.model.storage[0]);
        try std.testing.expectError(error.Quarantined, stream.open(43, caps, params, limits.period_ns, device.io()));
    }
}

test "PCM pump: each control refusal fails closed" {
    for ([_]pcm.Control{ .prepare, .start, .stop, .release }) |kind| {
        var device = Fixture{ .fail = kind };
        var stream = Playback{};
        const token = stream.open(42, caps, params, 0, device.io()) catch {
            try std.testing.expectEqual(pcm.Control.prepare, kind);
            try std.testing.expectEqual(pcm.State.closed, stream.model.state);
            continue;
        };
        _ = try stream.model.submit(token, &samples);
        try stream.model.start(token, 0);
        stream.drive(0, device.io());
        if (kind != .start) {
            try stream.model.end(token, 0);
            device.complete(0);
            stream.drive(1, device.io());
        }
        try std.testing.expectEqual(pcm.State.closed, stream.model.state);
        try std.testing.expectEqual(pcm.Reason.control_failed, stream.model.reason);
        try std.testing.expectEqual(@as(u64, 1), stream.resets);
    }
}

test "PCM pump: late successful control acknowledgement cannot bypass deadline" {
    const Late = struct {
        now: u64 = 0,
        fn params(_: *anyopaque, _: pcm.Params) bool {
            return true;
        }
        fn control(ctx: *anyopaque, _: pcm.Control) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.now = limits.control_ns;
            return true;
        }
        fn publish(_: *anyopaque, _: pcm.Transfer, _: []const u8) void {}
        fn poll(_: *anyopaque) ?RawCompletion {
            return null;
        }
        fn clock(ctx: *anyopaque) u64 {
            return (@as(*@This(), @ptrCast(@alignCast(ctx)))).now;
        }
    };
    var device = Late{};
    const io = Io{ .context = &device, .params = Late.params, .control = Late.control, .publish = Late.publish, .poll = Late.poll, .clock = Late.clock };
    var stream = Playback{};
    try std.testing.expectError(error.DeviceFailed, stream.open(42, caps, params, 0, io));
    try std.testing.expectEqual(pcm.State.resetting, stream.model.state);
    try std.testing.expectEqual(pcm.Reason.timeout, stream.model.reason);
    try std.testing.expectEqual(pcm.Control.reset, stream.model.control().?.kind);
}

// ---------------------------------------------------------------------------
// M99b mixer host-unit vectors — the card's pinned math: exact composed
// bytes, clip counting, idle/live starvation, post-mix gain order, the
// source bound, and per-source completion credit through the device.

fn mix_open(mix: *Mixer, device: *Fixture, owner: u64) !pcm.StreamToken {
    return mix.open(owner, caps, params, 0, device.io());
}

fn mix_submit(mix: *Mixer, token: pcm.StreamToken, bytes: []const u8) !void {
    const sub = try mix.submit_begin(token, bytes.len);
    @memcpy(sub.dst[0..bytes.len], bytes);
    mix.submit_commit(sub, bytes.len);
}

fn constant_period(v: f32) [pcm.period_bytes]u8 {
    var out: [pcm.period_bytes]u8 = undefined;
    for (0..pcm.period_bytes / 4) |i| {
        std.mem.writeInt(u32, out[i * 4 ..][0..4], @bitCast(v), .little);
    }
    return out;
}

fn expect_f32_period(actual: []const u8, v: f32) !void {
    for (0..actual.len / 4) |i| {
        const got: f32 = @bitCast(std.mem.readInt(u32, actual[i * 4 ..][0..4], .little));
        try std.testing.expectEqual(v, got);
    }
}

test "PCM mixer: two live sources sum exactly; seat bound refuses ENOSPC-style TableFull" {
    var device = Fixture{};
    var mix = Mixer{};
    const a = try mix_open(&mix, &device, 1);
    const b = try mix_open(&mix, &device, 2);
    const c = try mix_open(&mix, &device, 3);
    const d = try mix_open(&mix, &device, 4);
    try std.testing.expectError(error.TableFull, mix.open(5, null, params, 0, device.io()));
    try std.testing.expectEqual(@as(u64, 1), mix.refused);
    try std.testing.expectEqual(@as(u8, 4), mix.open_count);
    try std.testing.expectEqual(@as(u8, 4), mix.peak_sources);
    try mix.abort(c, 0);
    try mix.abort(d, 0);
    try std.testing.expectEqual(@as(u8, 2), mix.open_count);

    try mix_submit(&mix, a, &constant_period(0.25));
    try mix_submit(&mix, b, &constant_period(0.5));
    mix.source_of(a).?.state = .live;
    mix.source_of(b).?.state = .live;
    mix.feed(&mix.playback.model);
    // The first composed period is the exact f32 sum: 0.25 + 0.5 = 0.75.
    try expect_f32_period(&mix.playback.model.storage[mix.playback.model.queue[0]], 0.75);
    // The remaining seven slots composed silence once both queues drained.
    try expect_f32_period(&mix.playback.model.storage[mix.playback.model.queue[1]], 0.0);
    try std.testing.expectEqual(@as(u64, 7), mix.source_of(a).?.underruns);
    try std.testing.expectEqual(@as(u64, 7), mix.source_of(b).?.underruns);
    try std.testing.expectEqual(@as(u64, 0), mix.clipped);
    try std.testing.expectEqual(@as(u64, 4096), mix.source_of(a).?.counts.submitted);
    try std.testing.expectEqual(@as(u64, 4096), mix.source_of(a).?.inflight);
    try std.testing.expectEqual(@as(u64, 8 * pcm.period_bytes), mix.playback.model.counts.accepted);
}

test "PCM mixer: post-sum clamp counts clipped samples; post-mix gain runs after" {
    var device = Fixture{};
    var mix = Mixer{};
    // post_mix halves every f32 sample — proves the clamp ran BEFORE gain:
    // 0.9 + 0.9 saturates to 1.0 (counted), then halves to 0.5.
    mix.post_mix = struct {
        fn half(_: *anyopaque, pcm_out: []u8) void {
            for (0..pcm_out.len / 4) |i| {
                const v: f32 = @bitCast(std.mem.readInt(u32, pcm_out[i * 4 ..][0..4], .little));
                std.mem.writeInt(u32, pcm_out[i * 4 ..][0..4], @bitCast(v * 0.5), .little);
            }
        }
    }.half;
    mix.post_mix_ctx = &device;
    const a = try mix_open(&mix, &device, 1);
    const b = try mix_open(&mix, &device, 2);
    try mix_submit(&mix, a, &constant_period(0.9));
    try mix_submit(&mix, b, &constant_period(0.9));
    mix.source_of(a).?.state = .live;
    mix.source_of(b).?.state = .live;
    mix.feed(&mix.playback.model);
    try expect_f32_period(&mix.playback.model.storage[mix.playback.model.queue[0]], 0.5);
    // 512 frames × 2 channels clamped at the sum, before gain.
    try std.testing.expectEqual(@as(u64, 1024), mix.clipped);
}

test "PCM mixer: idle seat is silence (no underrun); a live-empty seat starves, never kills" {
    var device = Fixture{};
    var mix = Mixer{};
    const a = try mix_open(&mix, &device, 1);
    const b = try mix_open(&mix, &device, 2);
    try mix_submit(&mix, a, &constant_period(0.25));
    mix.source_of(a).?.state = .live;
    // b stays idle: contributes nothing and is NOT a starvation event.
    mix.feed(&mix.playback.model);
    try expect_f32_period(&mix.playback.model.storage[mix.playback.model.queue[0]], 0.25);
    try std.testing.expectEqual(@as(u64, 0), mix.source_of(b).?.underruns);
    // A live-but-empty seat counts an underrun per composed period while
    // the device stream stays running.
    mix.source_of(b).?.state = .live;
    mix.feed(&mix.playback.model);
    try std.testing.expectEqual(@as(u64, 0), mix.source_of(b).?.underruns);
    try std.testing.expectEqual(pcm.State.prepared, mix.playback.model.state);
}

test "PCM mixer: end drains, owner death frees one seat while the survivor streams" {
    var device = Fixture{};
    var mix = Mixer{};
    const a = try mix_open(&mix, &device, 1);
    const b = try mix_open(&mix, &device, 2);
    try mix_submit(&mix, a, &constant_period(0.25));
    try mix.start(a, 0);
    mix.drive(0, device.io()); // START ack -> running, first wave published
    try std.testing.expectEqual(pcm.State.running, mix.playback.model.state);
    try mix_submit(&mix, b, &constant_period(0.5));
    try mix.start(b, 0);
    // Complete the whole first wave; the second wave composes a+b (a's
    // first wave consumed its one period, so both starve except b's data).
    try mix_submit(&mix, a, &constant_period(0.25));
    for (0..pcm.slot_count) |i| device.complete(i);
    mix.drive(1, device.io());
    try std.testing.expectEqual(@as(u64, 4096), mix.source_of(a).?.counts.completed);
    // Kill owner 1 mid-stream: only its seat reaps; the stream survives.
    mix.owner_death(1, 1);
    try std.testing.expectEqual(@as(u8, 1), mix.open_count);
    try std.testing.expectEqual(pcm.State.running, mix.playback.model.state);
    const a_last = mix.last_of(a).?;
    try std.testing.expectEqual(pcm.Reason.owner_died, a_last.reason);
    try std.testing.expectEqual(@as(u64, 8192), a_last.counts.accepted);
    // The survivor keeps accepting and completing: wave-2's shared period
    // credited a's freed snapshot AND b's live seat.
    try mix_submit(&mix, b, &constant_period(0.5));
    for (0..pcm.slot_count) |i| device.complete(i);
    mix.drive(2, device.io());
    try std.testing.expectEqual(pcm.State.running, mix.playback.model.state);
    try std.testing.expectEqual(@as(u64, 4096), mix.source_of(b).?.counts.completed);
    // The survivor's clean end drains and closes the shared stream; its
    // in-flight credit lands on the seat snapshot.
    try mix.end(b, 2);
    for (0..pcm.slot_count) |i| device.complete(i);
    mix.drive(3, device.io());
    try std.testing.expectEqual(pcm.State.closed, mix.playback.model.state);
    try std.testing.expectEqual(@as(u8, 0), mix.open_count);
    const b_last = mix.last_of(b).?;
    try std.testing.expectEqual(@as(u64, 8192), b_last.counts.completed);
    try std.testing.expectEqual(@as(u64, 1), mix.playback.starts);
    try std.testing.expectEqual(@as(u64, 1), mix.playback.stops);
    try std.testing.expectEqual(@as(u64, 1), mix.playback.releases);
    try std.testing.expectEqual(@as(u64, 0), mix.playback.resets);
}
