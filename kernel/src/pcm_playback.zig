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

pub const Playback = struct {
    model: pcm.Model = .{},
    transfers: [pcm.slot_count]?pcm.Transfer = @splat(null),
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
            }
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

test "PCM pump: refusal, underrun, abort and owner death reclaim only after reset" {
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
    try std.testing.expectEqual(pcm.State.xrun, stream.model.state);
    try std.testing.expectEqual(pcm.Reason.underrun, stream.model.reason);
    try std.testing.expectError(error.InvalidState, stream.model.submit(token, &samples));
    try stream.model.recover(token, 1);
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
