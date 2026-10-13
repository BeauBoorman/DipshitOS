//! Device-free PCM ownership/lifecycle model, bound by pcm_playback/virtio_snd.
//! The caller serializes access and injects capabilities, replies and time.
//! Completion returns buffer ownership, not evidence of audible consumption.
const std = @import("std");

pub const slot_count = 8;
pub const period_bytes = 4096;
pub const pcm_bytes = slot_count * period_bytes;
pub const tx_descriptors = 32;
pub const descriptors_per_period = 3;
pub const status_bytes = 8;
// Prospective cache-line-isolated headers/statuses, descriptors and split rings.
// Budget only: no DMA objects are allocated here; a driver must verify its layout.
pub const prospective_dma_bytes = 512 + 128 + 320 + slot_count * (64 + 64);

pub const Format = enum { s16, s32, float32 };
pub const Params = struct {
    format: Format,
    rate_hz: u32,
    channels: u8,

    pub fn frame_bytes(self: Params) usize {
        return @as(usize, self.channels) * @as(usize, if (self.format == .s16) 2 else 4);
    }
};
pub const Capabilities = struct {
    present: bool,
    output: bool,
    queue_descriptors: usize,
    formats: []const Format,
    rates_hz: []const u32,
    channels_min: u8,
    channels_max: u8,
};
pub const Limits = struct {
    control_ns: u64,
    period_ns: u64,
    drain_ns: u64,
};
// Values are exported by slot 43's B7 status ABI. `xrun` (9) is RETIRED:
// M99b's mixer (ADR 0046 D2) makes starvation per-source data — the device
// stream composes silence for an empty source instead of dying whole — so
// the model never enters it. The value stays in the ABI numbering.
pub const State = enum(u32) { closed = 0, preparing = 1, prepared = 2, starting = 3, running = 4, draining = 5, stopping = 6, releasing = 7, resetting = 8, xrun = 9, quarantined = 10 };
pub const Reason = enum(u32) { none = 0, underrun = 1, owner_died = 2, aborted = 3, control_failed = 4, device_failed = 5, malformed_completion = 6, timeout = 7 };
pub const Control = enum { prepare, start, stop, release, reset };
pub const StreamToken = struct { owner: u64, generation: u64 };
pub const Reservation = struct { stream: StreamToken, slot: usize, serial: u64 };
pub const ControlTicket = struct { kind: Control, serial: u64 };
pub const Transfer = struct {
    generation: u64,
    serial: u64,
    head: u32,
    length: usize,
};
pub const Completion = struct {
    transfer: Transfer,
    written: usize = status_bytes,
    ok: bool = true,
};
pub const Counts = struct {
    accepted: u64 = 0,
    submitted: u64 = 0,
    completed: u64 = 0,
    canceled: u64 = 0,
    outstanding: usize = 0,
};
pub const Error = error{
    NoDevice,
    InsufficientCapacity,
    UnsupportedFormat,
    InvalidLimits,
    InvalidTime,
    Exhausted,
    Busy,
    Quarantined,
    InvalidToken,
    InvalidState,
    InvalidPeriod,
    Backpressure,
    StaleReservation,
    StaleControl,
    StaleCompletion,
    MalformedCompletion,
    DeviceFailed,
    NotPrefilled,
    NothingQueued,
};
const SlotState = enum { free, reserved, queued, owned };
const Slot = struct {
    state: SlotState = .free,
    serial: u64 = 0,
    length: usize = 0,
    deadline: u64 = 0,
};
const Pending = struct { ticket: ControlTicket, deadline: u64 };

pub const Model = struct {
    storage: [slot_count][period_bytes]u8 align(64) = undefined,
    slots: [slot_count]Slot = @splat(.{}),
    queue: [slot_count]usize = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,
    owned: usize = 0,
    state: State = .closed,
    reason: Reason = .none,
    counts: Counts = .{},
    params: Params = .{ .format = .s16, .rate_hz = 0, .channels = 0 },
    limits: Limits = .{ .control_ns = 0, .period_ns = 0, .drain_ns = 0 },
    owner: ?u64 = null,
    generation: u64 = 0,
    serial: u64 = 0,
    now: u64 = 0,
    pending: ?Pending = null,
    drain_deadline: ?u64 = null,
    // Injected split-ring counters, deliberately wrapping at 16 bits.
    avail_idx: u16 = 0,
    used_idx: u16 = 0,

    pub fn open(self: *Model, owner: u64, caps: Capabilities, params: Params, limits: Limits, now: u64) Error!StreamToken {
        if (self.state == .quarantined) return error.Quarantined;
        if (self.state != .closed) return error.Busy;
        if (!caps.present) return error.NoDevice;
        if (caps.queue_descriptors < tx_descriptors) return error.InsufficientCapacity;
        if (!caps.output or caps.channels_min == 0 or caps.channels_min > caps.channels_max or
            params.channels < caps.channels_min or params.channels > caps.channels_max or
            params.channels == 0 or params.rate_hz == 0 or
            std.mem.indexOfScalar(Format, caps.formats, params.format) == null or
            std.mem.indexOfScalar(u32, caps.rates_hz, params.rate_hz) == null)
            return error.UnsupportedFormat;
        if (limits.control_ns == 0 or limits.period_ns == 0 or limits.drain_ns == 0)
            return error.InvalidLimits;
        _ = try deadline(now, limits.control_ns);
        _ = try deadline(now, limits.period_ns);
        _ = try deadline(now, limits.drain_ns);
        if (now < self.now) return error.InvalidTime;
        if (self.generation == std.math.maxInt(u64) or self.serial == std.math.maxInt(u64))
            return error.Exhausted;
        self.generation += 1;
        self.owner = owner;
        self.params = params;
        self.limits = limits;
        self.now = now;
        self.reason = .none;
        self.counts = .{};
        self.avail_idx = 0;
        self.used_idx = 0;
        self.state = .preparing;
        self.pending = try self.command(.prepare, now);
        return .{ .owner = owner, .generation = self.generation };
    }

    pub fn control(self: *const Model) ?ControlTicket {
        return if (self.pending) |p| p.ticket else null;
    }

    pub fn control_reply(self: *Model, ticket: ControlTicket, ok: bool, now: u64) Error!void {
        try self.time(now);
        const p = self.pending orelse return error.StaleControl;
        if (ticket.serial != p.ticket.serial or ticket.kind != p.ticket.kind) return error.StaleControl;
        self.pending = null;
        if (!ok) {
            self.note(.control_failed);
            if (ticket.kind == .reset) {
                self.state = .quarantined;
            } else self.reset(now);
            return;
        }
        switch (ticket.kind) {
            .prepare => self.state = .prepared,
            .start => self.state = .running,
            .stop => {
                // STOP alone does not return any DMA-owned buffers.
                self.state = .releasing;
                self.pending = self.command(.release, now) catch {
                    self.reset(now);
                    return;
                };
            },
            .release => {
                if (self.owned != 0) self.reset(now) else self.finish();
            },
            .reset => {
                for (&self.slots) |*slot| {
                    if (slot.state == .owned) {
                        self.counts.canceled += slot.length;
                        self.counts.outstanding -= slot.length;
                    }
                    slot.* = .{};
                }
                self.owned = 0;
                self.finish();
            },
        }
    }

    pub fn reserve(self: *Model, token: StreamToken, length: usize) Error!Reservation {
        try self.authenticate(token);
        if (self.state != .prepared and self.state != .running) return error.InvalidState;
        if (length == 0 or length > period_bytes or length % self.params.frame_bytes() != 0)
            return error.InvalidPeriod;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state != .free) continue;
            const serial = try self.next_serial();
            slot.* = .{ .state = .reserved, .serial = serial, .length = length };
            return .{ .stream = token, .slot = index, .serial = serial };
        }
        return error.Backpressure;
    }

    pub fn cancel(self: *Model, reservation: Reservation) Error!void {
        const slot = try self.reserved(reservation);
        slot.* = .{};
    }

    /// Source validation/copy finishes before the period is made visible.
    /// A bad source length rolls the reservation back; no partial publication.
    pub fn commit(self: *Model, reservation: Reservation, bytes: []const u8) Error!usize {
        const slot = try self.reserved(reservation);
        if (bytes.len != slot.length) {
            slot.* = .{};
            return error.InvalidPeriod;
        }
        if (bytes.len > std.math.maxInt(u64) - self.counts.accepted) {
            slot.* = .{};
            return error.Exhausted;
        }
        @memcpy(self.storage[reservation.slot][0..bytes.len], bytes);
        slot.state = .queued;
        self.queue[(self.queue_head + self.queue_len) % slot_count] = reservation.slot;
        self.queue_len += 1;
        self.counts.accepted += bytes.len;
        self.counts.outstanding += bytes.len;
        return bytes.len;
    }

    pub fn submit(self: *Model, token: StreamToken, bytes: []const u8) Error!usize {
        return self.commit(try self.reserve(token, bytes.len), bytes);
    }

    /// The reservation's storage was filled in place — the M99b mixer
    /// composes each output period directly into the slot so mixed sources
    /// never take a bounce copy.
    pub fn commit_in_place(self: *Model, reservation: Reservation) Error!void {
        const slot = try self.reserved(reservation);
        slot.state = .queued;
        self.queue[(self.queue_head + self.queue_len) % slot_count] = reservation.slot;
        self.queue_len += 1;
        self.counts.accepted += slot.length;
        self.counts.outstanding += slot.length;
    }

    pub fn start(self: *Model, token: StreamToken, now: u64) Error!void {
        try self.authenticate(token);
        try self.time(now);
        if (self.state != .prepared) return error.InvalidState;
        if (self.queue_len == 0 and self.owned == 0) return error.NotPrefilled;
        const p = try self.command(.start, now);
        self.state = .starting;
        self.pending = p;
    }

    /// Publish at most one queued period. Payload stays immutable until reclaim.
    pub fn publish(self: *Model, now: u64) Error!Transfer {
        try self.time(now);
        if (self.state != .prepared and self.state != .starting and self.state != .running and self.state != .draining)
            return error.InvalidState;
        if (self.queue_len == 0) return error.NothingQueued;
        const until = try deadline(now, self.limits.period_ns);
        const index = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % slot_count;
        self.queue_len -= 1;
        const slot = &self.slots[index];
        slot.state = .owned;
        slot.deadline = until;
        self.owned += 1;
        self.counts.submitted += slot.length;
        self.avail_idx +%= 1;
        return .{ .generation = self.generation, .serial = slot.serial, .head = @intCast(index * descriptors_per_period), .length = slot.length };
    }

    pub fn payload(self: *const Model, transfer: Transfer) Error![]const u8 {
        const index = try self.owned_slot(transfer);
        return self.storage[index][0..self.slots[index].length];
    }

    pub fn complete(self: *Model, completion: Completion, now: u64) Error!void {
        try self.time(now);
        const transfer = completion.transfer;
        if (transfer.generation != self.generation) return error.StaleCompletion;
        if (self.state == .closed) return error.StaleCompletion;
        if (transfer.head >= tx_descriptors or transfer.head % descriptors_per_period != 0 or
            transfer.head / descriptors_per_period >= slot_count)
        {
            self.note(.malformed_completion);
            self.reset(now);
            return error.MalformedCompletion;
        }
        const candidate = self.slots[transfer.head / descriptors_per_period];
        if (candidate.state == .owned and candidate.serial == transfer.serial and candidate.length != transfer.length) {
            self.note(.malformed_completion);
            self.reset(now);
            return error.MalformedCompletion;
        }
        const index = try self.owned_slot(transfer);
        const slot = &self.slots[index];
        if (completion.written != status_bytes) {
            self.note(.malformed_completion);
            self.reset(now);
            return error.MalformedCompletion;
        }
        // After a timeout/failure only RESET acknowledgement can reclaim storage.
        if (self.state == .resetting or self.state == .quarantined) return error.InvalidState;
        if (!completion.ok) {
            self.note(.device_failed);
            self.reset(now);
            return error.DeviceFailed;
        }
        self.counts.completed += slot.length;
        self.counts.outstanding -= slot.length;
        self.owned -= 1;
        slot.* = .{};
        self.used_idx +%= 1;
        if (self.state == .draining and self.queue_len == 0 and self.owned == 0) {
            self.stop(now);
        }
    }

    pub fn end(self: *Model, token: StreamToken, now: u64) Error!void {
        try self.authenticate(token);
        try self.time(now);
        if (self.state != .running) return error.InvalidState;
        const until = try deadline(now, self.limits.drain_ns);
        self.cancel_reservations();
        self.state = .draining;
        self.drain_deadline = until;
        if (self.queue_len == 0 and self.owned == 0) self.stop(now);
    }

    pub fn abort(self: *Model, token: StreamToken, now: u64) Error!void {
        try self.authenticate(token);
        try self.time(now);
        self.note(.aborted);
        self.owner = null;
        self.cancel_queued();
        self.stop(now);
    }

    pub fn owner_death(self: *Model, owner: u64, now: u64) Error!void {
        if (self.owner == null or self.owner.? != owner) return error.InvalidToken;
        try self.time(now);
        self.note(.owner_died);
        self.owner = null;
        self.cancel_queued();
        self.stop(now);
    }

    pub fn tick(self: *Model, now: u64) Error!void {
        try self.time(now);
    }

    fn authenticate(self: *const Model, token: StreamToken) Error!void {
        if (self.owner == null or self.owner.? != token.owner or self.generation != token.generation)
            return error.InvalidToken;
    }

    fn reserved(self: *Model, reservation: Reservation) Error!*Slot {
        try self.authenticate(reservation.stream);
        if (self.state != .prepared and self.state != .running) return error.InvalidState;
        if (reservation.slot >= slot_count) return error.StaleReservation;
        const slot = &self.slots[reservation.slot];
        if (slot.state != .reserved or slot.serial != reservation.serial) return error.StaleReservation;
        return slot;
    }

    fn owned_slot(self: *const Model, transfer: Transfer) Error!usize {
        if (transfer.generation != self.generation or transfer.head % descriptors_per_period != 0)
            return error.StaleCompletion;
        const index = transfer.head / descriptors_per_period;
        if (index >= slot_count) return error.StaleCompletion;
        const slot = self.slots[index];
        if (slot.state != .owned or slot.serial != transfer.serial or slot.length != transfer.length)
            return error.StaleCompletion;
        return index;
    }

    fn time(self: *Model, now: u64) Error!void {
        if (now < self.now) return error.InvalidTime;
        self.now = now;
        self.expire(now);
    }

    fn next_serial(self: *Model) Error!u64 {
        if (self.serial == std.math.maxInt(u64)) return error.Exhausted;
        self.serial += 1;
        return self.serial;
    }

    fn command(self: *Model, kind: Control, now: u64) Error!Pending {
        const until = try deadline(now, self.limits.control_ns);
        return .{ .ticket = .{ .kind = kind, .serial = try self.next_serial() }, .deadline = until };
    }

    fn note(self: *Model, reason: Reason) void {
        if (self.reason == .none) self.reason = reason;
    }

    fn cancel_reservations(self: *Model) void {
        for (&self.slots) |*slot| {
            if (slot.state == .reserved) slot.* = .{};
        }
    }

    fn cancel_queued(self: *Model) void {
        self.cancel_reservations();
        for (&self.slots) |*slot| {
            if (slot.state == .queued) {
                self.counts.canceled += slot.length;
                self.counts.outstanding -= slot.length;
                slot.* = .{};
            }
        }
        self.queue_head = 0;
        self.queue_len = 0;
    }

    fn finish(self: *Model) void {
        self.cancel_queued();
        self.owner = null;
        self.pending = null;
        self.drain_deadline = null;
        self.state = .closed;
    }

    fn stop(self: *Model, now: u64) void {
        if (self.state == .resetting or self.state == .quarantined or self.state == .stopping or self.state == .releasing) return;
        // An interrupted control exchange cannot safely be replaced with STOP.
        if (self.pending != null) {
            self.reset(now);
            return;
        }
        self.drain_deadline = null;
        self.state = .stopping;
        self.pending = self.command(.stop, now) catch {
            self.reset(now);
            return;
        };
    }

    fn reset(self: *Model, now: u64) void {
        if (self.state == .resetting or self.state == .quarantined) return;
        self.owner = null;
        self.cancel_queued();
        self.drain_deadline = null;
        self.state = .resetting;
        self.pending = self.command(.reset, now) catch {
            self.pending = null;
            self.state = .quarantined;
            return;
        };
    }

    fn expire(self: *Model, now: u64) void {
        if (self.state == .closed or self.state == .quarantined) return;
        if (self.pending) |p| {
            if (now >= p.deadline) {
                self.note(.timeout);
                if (p.ticket.kind == .reset) {
                    self.pending = null;
                    self.state = .quarantined;
                } else self.reset(now);
                return;
            }
        }
        if (self.drain_deadline) |until| {
            if (now >= until) {
                self.note(.timeout);
                self.reset(now);
                return;
            }
        }
        if (self.state == .resetting) return;
        for (self.slots) |slot| {
            if (slot.state == .owned and now >= slot.deadline) {
                self.note(.timeout);
                self.reset(now);
                return;
            }
        }
    }
};

pub const metadata_bytes = @sizeOf(Model) - pcm_bytes;

fn deadline(now: u64, duration: u64) Error!u64 {
    return std.math.add(u64, now, duration) catch error.InvalidTime;
}
