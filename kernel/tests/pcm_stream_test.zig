//! Model verification only: no device, driver, syscall or playback timing proof.
const std = @import("std");
const pcm = @import("pcm_stream");
const t = std.testing;

const formats = [_]pcm.Format{ .s16, .s32, .float32 };
const rates = [_]u32{ 44100, 48000 };
const caps = pcm.Capabilities{ .present = true, .output = true, .queue_descriptors = 32, .formats = &formats, .rates_hz = &rates, .channels_min = 1, .channels_max = 2 };
const params = pcm.Params{ .format = .float32, .rate_hz = 48000, .channels = 2 };
const limits = pcm.Limits{ .control_ns = 100, .period_ns = 200, .drain_ns = 50 };
const audio = @as([pcm.period_bytes]u8, @splat(@as(u8, 0x5a)));

fn reply(model: *pcm.Model, kind: pcm.Control, ok: bool) !void {
    const ticket = model.control().?;
    try t.expectEqual(kind, ticket.kind);
    try model.control_reply(ticket, ok, model.now);
}

fn prepared(model: *pcm.Model) !pcm.StreamToken {
    const token = try model.open(42, caps, params, limits, model.now);
    try reply(model, .prepare, true);
    return token;
}

fn running(model: *pcm.Model, token: pcm.StreamToken) !void {
    try model.start(token, model.now);
    try reply(model, .start, true);
}

fn invariant(model: *const pcm.Model) !void {
    var occupied: usize = 0;
    var outstanding: usize = 0;
    var owned: usize = 0;
    var queued: usize = 0;
    for (model.slots) |slot| {
        if (slot.state != .free) occupied += 1;
        if (slot.state == .owned) owned += 1;
        if (slot.state == .queued) queued += 1;
        if (slot.state == .queued or slot.state == .owned) outstanding += slot.length;
    }
    try t.expect(occupied <= pcm.slot_count);
    try t.expect(occupied * pcm.descriptors_per_period <= pcm.tx_descriptors);
    try t.expectEqual(model.owned, owned);
    try t.expectEqual(model.queue_len, queued);
    try t.expectEqual(model.counts.outstanding, outstanding);
    try t.expectEqual(model.counts.accepted, model.counts.completed + model.counts.canceled + outstanding);
    try t.expect(model.counts.completed <= model.counts.submitted);
    try t.expect(outstanding <= pcm.pcm_bytes);
}

test "PCM model: exact storage and separately charged metadata/prospective DMA" {
    try t.expectEqual(@as(usize, 32768), pcm.pcm_bytes);
    try t.expectEqual(pcm.pcm_bytes, @sizeOf(@FieldType(pcm.Model, "storage")));
    try t.expect(pcm.metadata_bytes > 0);
    try t.expectEqual(@sizeOf(pcm.Model), pcm.pcm_bytes + pcm.metadata_bytes);
    try t.expectEqual(@as(usize, 1984), pcm.prospective_dma_bytes);
    try t.expectEqual(@as(usize, 24), pcm.slot_count * pcm.descriptors_per_period);
}

test "PCM model: missing device and insufficient capacity refuse without state changes" {
    var model = pcm.Model{};
    var unsupported = caps;
    unsupported.present = false;
    try t.expectError(error.NoDevice, model.open(42, unsupported, params, limits, 0));
    unsupported = caps;
    for ([_]usize{ 0, 4, 24, 31 }) |size| {
        unsupported.queue_descriptors = size;
        try t.expectError(error.InsufficientCapacity, model.open(42, unsupported, params, limits, 0));
    }
    try t.expectEqual(pcm.State.closed, model.state);
    try t.expect(model.control() == null);
    try t.expect(model.owner == null);
    try t.expectEqual(@as(u64, 0), model.generation);
    try invariant(&model);
}

test "PCM model: exact advertised output tuple and whole-frame geometry" {
    var model = pcm.Model{};
    var unsupported = caps;
    unsupported.output = false;
    try t.expectError(error.UnsupportedFormat, model.open(42, unsupported, params, limits, 0));
    unsupported = caps;
    unsupported.channels_min = 0;
    try t.expectError(error.UnsupportedFormat, model.open(42, unsupported, params, limits, 0));
    unsupported.channels_min = 3;
    try t.expectError(error.UnsupportedFormat, model.open(42, unsupported, params, limits, 0));
    unsupported = caps;
    unsupported.formats = &.{.s16};
    try t.expectError(error.UnsupportedFormat, model.open(42, unsupported, params, limits, 0));
    unsupported = caps;
    unsupported.rates_hz = &.{44100};
    try t.expectError(error.UnsupportedFormat, model.open(42, unsupported, params, limits, 0));
    for ([_]u8{ 0, 3, 255 }) |channels| {
        var requested = params;
        requested.channels = channels;
        try t.expectError(error.UnsupportedFormat, model.open(42, caps, requested, limits, 0));
    }
    const token = try prepared(&model);
    try t.expectEqual(params, model.params);
    for ([_]usize{ 0, 1, 7, 4095, 4097 }) |length|
        try t.expectError(error.InvalidPeriod, model.reserve(token, length));
    try t.expectEqual(@as(usize, 8), try model.submit(token, audio[0..8]));
    try invariant(&model);
    for (formats) |format| {
        for ([_]u8{ 1, 2 }) |channels| {
            var other = pcm.Model{};
            const requested = pcm.Params{ .format = format, .rate_hz = 44100, .channels = channels };
            const exact = try other.open(42, caps, requested, limits, 0);
            try reply(&other, .prepare, true);
            try t.expectEqual(requested, other.params);
            try t.expectEqual(pcm.period_bytes, try other.submit(exact, &audio));
        }
    }
    var multichannel = pcm.Model{};
    const three_channels = pcm.Params{ .format = .float32, .rate_hz = 48000, .channels = 3 };
    var advertised = caps;
    advertised.channels_max = 3;
    const exact = try multichannel.open(42, advertised, three_channels, limits, 0);
    try reply(&multichannel, .prepare, true);
    try t.expectEqual(@as(usize, 4092), try multichannel.submit(exact, audio[0..4092]));
    try t.expectError(error.InvalidPeriod, multichannel.submit(exact, &audio));
}

test "PCM model: exclusive owner, stale generations and reservations never alias reuse" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    try t.expectError(error.Busy, model.open(43, caps, params, limits, 0));
    var wrong = token;
    wrong.owner = 43;
    try t.expectError(error.InvalidToken, model.submit(wrong, &audio));
    const reserved = try model.reserve(token, 8);
    try model.cancel(reserved);
    const reused = try model.reserve(token, 8);
    try t.expectEqual(reserved.slot, reused.slot);
    try t.expectError(error.StaleReservation, model.commit(reserved, audio[0..8]));
    try model.cancel(reused);
    try model.abort(token, 0);
    try t.expectError(error.InvalidToken, model.submit(token, &audio));
    try reply(&model, .stop, true);
    try reply(&model, .release, true);
    const next = try prepared(&model);
    try t.expect(next.generation != token.generation);
    try t.expectError(error.InvalidToken, model.reserve(token, 8));
    try invariant(&model);
}

test "PCM model: copy rollback and atomic full-queue backpressure preserve all payloads" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    const bad_copy = try model.reserve(token, 8);
    try t.expectError(error.InvalidPeriod, model.commit(bad_copy, audio[0..4]));
    try t.expectEqual(@as(u64, 0), model.counts.accepted);
    const reservation = try model.reserve(token, pcm.period_bytes);
    for (0..pcm.slot_count - 1) |_| _ = try model.submit(token, &audio);
    try t.expectError(error.Backpressure, model.submit(token, &audio));
    _ = try model.commit(reservation, &audio);
    const before = model;
    try t.expectError(error.Backpressure, model.submit(token, &audio));
    try t.expectEqual(before.counts, model.counts);
    try t.expectEqual(before.queue_head, model.queue_head);
    try t.expectEqual(before.queue_len, model.queue_len);
    try t.expectEqual(before.serial, model.serial);
    try t.expectEqualSlices(u8, std.mem.asBytes(&before.storage), std.mem.asBytes(&model.storage));
    try invariant(&model);
}

test "PCM model: all eight device-owned slots remain immutable under backpressure" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    var transfers: [pcm.slot_count]pcm.Transfer = undefined;
    for (&transfers) |*transfer| {
        _ = try model.submit(token, &audio);
        transfer.* = try model.publish(0);
    }
    try running(&model, token);
    const counts = model.counts;
    const serial = model.serial;
    try t.expectError(error.Backpressure, model.submit(token, audio[0..8]));
    try t.expectEqual(counts, model.counts);
    try t.expectEqual(serial, model.serial);
    for (transfers) |transfer| try t.expectEqualSlices(u8, &audio, try model.payload(transfer));
    try t.expectEqual(@as(usize, 8), model.owned);
    try invariant(&model);
    try model.complete(.{ .transfer = transfers[3] }, 0);
    const old = transfers[3];
    _ = try model.submit(token, audio[0..8]);
    const reused = try model.publish(0);
    try t.expectEqual(old.head, reused.head);
    try t.expect(reused.serial != old.serial);
    try t.expectError(error.StaleCompletion, model.complete(.{ .transfer = old }, 0));
    try t.expectEqualSlices(u8, audio[0..8], try model.payload(reused));
    try invariant(&model);
}

test "PCM model: sustained FIFO reuse beyond 64 KiB with a single START and STOP" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    try t.expectError(error.NotPrefilled, model.start(token, 0));
    for (0..pcm.slot_count) |i| {
        var bytes = audio;
        bytes[0] = @intCast(i);
        _ = try model.submit(token, &bytes);
    }
    var transfers: [pcm.slot_count]pcm.Transfer = undefined;
    // The first periods can be published before START.
    for (&transfers) |*transfer| transfer.* = try model.publish(0);
    try running(&model, token);
    const start_serial = model.serial;
    for (0..40) |i| {
        const index = i % pcm.slot_count;
        try t.expectEqual(@as(u8, @intCast(i)), (try model.payload(transfers[index]))[0]);
        try model.complete(.{ .transfer = transfers[index] }, 0);
        var bytes = audio;
        bytes[0] = @intCast(i + pcm.slot_count);
        _ = try model.submit(token, &bytes);
        transfers[index] = try model.publish(0);
        try t.expectEqual(pcm.State.running, model.state);
        try t.expect(model.control() == null);
        try invariant(&model);
    }
    try t.expect(model.counts.completed > 65536);
    try t.expect(model.serial > start_serial);
    try model.end(token, 0);
    try t.expectError(error.InvalidState, model.submit(token, &audio));
    for (transfers) |transfer| try model.complete(.{ .transfer = transfer }, 0);
    try t.expectEqual(pcm.State.stopping, model.state);
    try reply(&model, .stop, true);
    try reply(&model, .release, true);
    try t.expectEqual(pcm.State.closed, model.state);
    try t.expectEqual(@as(u64, 48 * pcm.period_bytes), model.counts.completed);
    try t.expectEqual(model.counts.accepted, model.counts.completed);
    try t.expectEqual(pcm.Reason.none, model.reason);
    try invariant(&model);
}

test "PCM model: descriptor recycling, out-of-order completion and 16-bit ring wrap" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    model.avail_idx = std.math.maxInt(u16);
    model.used_idx = std.math.maxInt(u16);
    _ = try model.submit(token, &audio);
    _ = try model.submit(token, &audio);
    const first = try model.publish(0);
    const second = try model.publish(0);
    try t.expectEqual(@as(u16, 1), model.avail_idx);
    try t.expect(first.head != second.head);
    try running(&model, token);
    try model.complete(.{ .transfer = second }, 0);
    try t.expectEqual(@as(u16, 0), model.used_idx);
    _ = try model.submit(token, &audio);
    const recycled = try model.publish(0);
    try t.expectEqual(second.head, recycled.head);
    try t.expect(recycled.serial != second.serial);
    const counts = model.counts;
    try t.expectError(error.StaleCompletion, model.complete(.{ .transfer = second }, 0));
    var wrong = first;
    wrong.generation += 1;
    try t.expectError(error.StaleCompletion, model.complete(.{ .transfer = wrong }, 0));
    try t.expectEqual(counts, model.counts);
    try t.expectEqualSlices(u8, &audio, try model.payload(first));
    try model.complete(.{ .transfer = first }, 0);
    try t.expectEqual(@as(u16, 1), model.used_idx);
    try invariant(&model);
}

test "PCM model: malformed completion heads/lengths and failed status preserve device ownership" {
    for ([_]u32{ 1, 24, 30, 32, std.math.maxInt(u32) }) |head| {
        var model = pcm.Model{};
        const token = try prepared(&model);
        _ = try model.submit(token, &audio);
        const original = try model.publish(0);
        var bad = original;
        bad.head = head;
        try t.expectError(error.MalformedCompletion, model.complete(.{ .transfer = bad }, 0));
        try t.expectEqual(pcm.State.resetting, model.state);
        try t.expectEqual(@as(usize, 1), model.owned);
        try t.expectEqualSlices(u8, &audio, try model.payload(original));
        try invariant(&model);
    }
    for ([_]usize{ 0, 4, 9, 4096 }) |written| {
        var model = pcm.Model{};
        const token = try prepared(&model);
        _ = try model.submit(token, &audio);
        const transfer = try model.publish(0);
        try t.expectError(error.MalformedCompletion, model.complete(.{ .transfer = transfer, .written = written }, 0));
        try t.expectEqual(@as(u64, 0), model.counts.completed);
        try t.expectEqual(pcm.Reason.malformed_completion, model.reason);
        try invariant(&model);
    }
    var model = pcm.Model{};
    const token = try prepared(&model);
    _ = try model.submit(token, &audio);
    const transfer = try model.publish(0);
    try t.expectError(error.DeviceFailed, model.complete(.{ .transfer = transfer, .ok = false }, 0));
    try t.expectEqual(pcm.Reason.device_failed, model.reason);
    try t.expectEqual(@as(usize, 1), model.owned);
    try invariant(&model);
    var corrupt_length = pcm.Model{};
    const exact = try prepared(&corrupt_length);
    _ = try corrupt_length.submit(exact, &audio);
    var transfer_bad = try corrupt_length.publish(0);
    transfer_bad.length -= 1;
    try t.expectError(error.MalformedCompletion, corrupt_length.complete(.{ .transfer = transfer_bad }, 0));
    try t.expectEqual(pcm.State.resetting, corrupt_length.state);
    try invariant(&corrupt_length);
}

test "PCM model: XRUN is sticky, never inserts silence and requires explicit recovery" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    _ = try model.submit(token, audio[0..8]);
    const transfer = try model.publish(0);
    try running(&model, token);
    const uncommitted = try model.reserve(token, 8);
    try model.complete(.{ .transfer = transfer }, 0);
    try t.expectEqual(pcm.State.xrun, model.state);
    try t.expectEqual(pcm.Reason.underrun, model.reason);
    try t.expect(model.control() == null);
    try t.expectError(error.InvalidState, model.submit(token, &audio));
    try t.expectError(error.InvalidState, model.commit(uncommitted, audio[0..8]));
    try t.expectError(error.InvalidState, model.start(token, 0));
    try model.tick(20);
    try t.expectEqual(@as(u64, 8), model.counts.accepted);
    try model.recover(token, 20);
    try reply(&model, .stop, true);
    try reply(&model, .release, true);
    try t.expectEqual(pcm.Reason.underrun, model.reason);
    const next = try prepared(&model);
    try t.expect(next.generation != token.generation);
    try t.expectEqual(pcm.Reason.none, model.reason);
    try invariant(&model);
}

test "PCM model: EOS drains queued and owned periods without XRUN" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    _ = try model.submit(token, &audio);
    _ = try model.submit(token, audio[0..16]);
    const first = try model.publish(0);
    try running(&model, token);
    const uncommitted = try model.reserve(token, 8);
    try model.end(token, 0);
    try t.expectError(error.InvalidState, model.commit(uncommitted, audio[0..8]));
    try model.complete(.{ .transfer = first }, 1);
    try t.expectEqual(pcm.State.draining, model.state);
    const last = try model.publish(1);
    try model.complete(.{ .transfer = last }, 2);
    try reply(&model, .stop, true);
    try reply(&model, .release, true);
    try t.expectEqual(pcm.Reason.none, model.reason);
    try t.expectEqual(@as(u64, pcm.period_bytes + 16), model.counts.completed);
    try invariant(&model);
}

test "PCM model: monotonic finite deadlines, exact expiry and successful reset fencing" {
    var model = pcm.Model{};
    var bad = limits;
    bad.control_ns = 0;
    try t.expectError(error.InvalidLimits, model.open(42, caps, params, bad, 0));
    bad = limits;
    bad.period_ns = 0;
    try t.expectError(error.InvalidLimits, model.open(42, caps, params, bad, 0));
    bad = limits;
    bad.drain_ns = 0;
    try t.expectError(error.InvalidLimits, model.open(42, caps, params, bad, 0));
    try t.expectError(error.InvalidTime, model.open(42, caps, params, limits, std.math.maxInt(u64)));
    const token = try prepared(&model);
    _ = try model.submit(token, &audio);
    const transfer = try model.publish(0);
    try running(&model, token);
    try model.tick(199);
    try t.expectEqual(pcm.State.running, model.state);
    try t.expectError(error.InvalidTime, model.tick(198));
    try model.tick(200);
    try t.expectEqual(pcm.State.resetting, model.state);
    try t.expectEqual(@as(usize, 1), model.owned);
    try t.expectError(error.InvalidState, model.complete(.{ .transfer = transfer }, 200));
    try t.expectEqualSlices(u8, &audio, try model.payload(transfer));
    try reply(&model, .reset, true);
    try t.expectEqual(@as(usize, 0), model.owned);
    try t.expectEqual(@as(u64, pcm.period_bytes), model.counts.canceled);
    try t.expectEqual(pcm.State.closed, model.state);
    try t.expectError(error.StaleCompletion, model.complete(.{ .transfer = transfer }, 200));
    const next = try prepared(&model);
    _ = try model.submit(next, &audio);
    _ = try model.publish(200);
    try t.expectError(error.StaleCompletion, model.complete(.{ .transfer = transfer }, 200));
    try invariant(&model);
}

test "PCM model: drain timeout and late control replies never grant reuse" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    _ = try model.submit(token, &audio);
    const transfer = try model.publish(0);
    try running(&model, token);
    try model.end(token, 0);
    try model.tick(49);
    try t.expectEqual(pcm.State.draining, model.state);
    try model.tick(50);
    const reset = model.control().?;
    try t.expectEqual(pcm.State.resetting, model.state);
    try t.expectError(error.StaleControl, model.control_reply(reset, true, 150));
    try t.expectEqual(pcm.State.quarantined, model.state);
    try t.expectEqual(@as(usize, 1), model.owned);
    try t.expectEqualSlices(u8, &audio, try model.payload(transfer));
    try t.expectError(error.Quarantined, model.open(43, caps, params, limits, 150));
    try invariant(&model);
}

test "PCM model: completion cannot bypass the drain deadline without tick" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    _ = try model.submit(token, &audio);
    const transfer = try model.publish(0);
    try running(&model, token);
    try model.end(token, 0);
    try t.expectError(error.InvalidState, model.complete(.{ .transfer = transfer }, 50));
    try t.expectEqual(pcm.State.resetting, model.state);
    try t.expectEqual(@as(u64, 0), model.counts.completed);
    try t.expectEqual(@as(usize, 1), model.owned);
    try invariant(&model);
}

test "PCM model: finite control expiry, late replies and serial exhaustion" {
    for ([_]pcm.Control{ .prepare, .start, .stop, .release }) |stage| {
        var model = pcm.Model{};
        const token = try model.open(42, caps, params, limits, 0);
        if (stage != .prepare) {
            try reply(&model, .prepare, true);
            _ = try model.submit(token, &audio);
            try model.start(token, 0);
            if (stage != .start) {
                try reply(&model, .start, true);
                try model.abort(token, 0);
                if (stage == .release) try reply(&model, .stop, true);
            }
        }
        const old = model.control().?;
        try model.tick(99);
        try t.expectEqual(stage, model.control().?.kind);
        try t.expectError(error.StaleControl, model.control_reply(old, true, 100));
        try t.expectEqual(pcm.State.resetting, model.state);
        try t.expectEqual(if (stage == .stop or stage == .release) pcm.Reason.aborted else pcm.Reason.timeout, model.reason);
        try model.tick(200);
        try t.expectEqual(pcm.State.quarantined, model.state);
        try t.expectError(error.Quarantined, model.open(42, caps, params, limits, 200));
        try invariant(&model);
    }
    var exhausted = pcm.Model{};
    exhausted.generation = std.math.maxInt(u64);
    try t.expectError(error.Exhausted, exhausted.open(42, caps, params, limits, 0));
    exhausted.generation = 0;
    exhausted.serial = std.math.maxInt(u64);
    try t.expectError(error.Exhausted, exhausted.open(42, caps, params, limits, 0));
    exhausted.serial = 0;
    const token = try prepared(&exhausted);
    exhausted.counts.accepted = std.math.maxInt(u64);
    const reservation = try exhausted.reserve(token, 8);
    try t.expectError(error.Exhausted, exhausted.commit(reservation, audio[0..8]));
    try t.expectEqual(@as(usize, 0), exhausted.queue_len);
    try t.expectEqual(@as(usize, 0), exhausted.counts.outstanding);
}

test "PCM model: failed RESET quarantines slots and sticky diagnostics" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    for (0..pcm.slot_count) |_| _ = try model.submit(token, &audio);
    const transfer = try model.publish(0);
    try running(&model, token);
    try model.tick(200);
    try reply(&model, .reset, false);
    try t.expectEqual(pcm.State.quarantined, model.state);
    try t.expectEqual(pcm.Reason.timeout, model.reason);
    try t.expectEqual(@as(u64, 7 * pcm.period_bytes), model.counts.canceled);
    try t.expectEqual(@as(usize, pcm.period_bytes), model.counts.outstanding);
    try t.expectError(error.InvalidState, model.complete(.{ .transfer = transfer }, 200));
    try model.tick(1000);
    try t.expectEqual(pcm.State.quarantined, model.state);
    try t.expectError(error.Quarantined, model.open(42, caps, params, limits, 1000));
    try invariant(&model);
}

test "PCM model: owner death invalidates tokens and cannot free DMA on STOP/RELEASE" {
    var model = pcm.Model{};
    const token = try prepared(&model);
    _ = try model.submit(token, &audio);
    _ = try model.submit(token, &audio);
    const transfer = try model.publish(0);
    try running(&model, token);
    try t.expectError(error.InvalidToken, model.owner_death(43, 0));
    try model.owner_death(42, 0);
    try t.expectEqual(@as(u64, pcm.period_bytes), model.counts.canceled);
    try t.expectEqual(@as(usize, 1), model.owned);
    try t.expectError(error.InvalidToken, model.submit(token, &audio));
    try reply(&model, .stop, true);
    try t.expectEqual(@as(usize, 1), model.owned);
    try reply(&model, .release, true);
    try t.expectEqual(pcm.State.resetting, model.state);
    try t.expectEqualSlices(u8, &audio, try model.payload(transfer));
    try reply(&model, .reset, true);
    try t.expectEqual(pcm.State.closed, model.state);
    try t.expectEqual(pcm.Reason.owner_died, model.reason);
    try invariant(&model);
}

test "PCM model: death in PREPARE/START and failed control transitions require reset" {
    for ([_]bool{ false, true }) |during_start| {
        var model = pcm.Model{};
        const token = try model.open(42, caps, params, limits, 0);
        if (during_start) {
            try reply(&model, .prepare, true);
            _ = try model.submit(token, &audio);
            try model.start(token, 0);
        }
        const old_control = model.control().?;
        try model.owner_death(42, 0);
        try t.expectEqual(pcm.State.resetting, model.state);
        try t.expectError(error.StaleControl, model.control_reply(old_control, true, 0));
        try reply(&model, .reset, true);
        try invariant(&model);
    }
    for ([_]pcm.Control{ .prepare, .start, .stop, .release }) |failure| {
        var model = pcm.Model{};
        const token = try model.open(42, caps, params, limits, 0);
        if (failure != .prepare) {
            try reply(&model, .prepare, true);
            _ = try model.submit(token, &audio);
            try model.start(token, 0);
            if (failure != .start) {
                try reply(&model, .start, true);
                try model.abort(token, 0);
                if (failure == .release) try reply(&model, .stop, true);
            }
        }
        try reply(&model, failure, false);
        try t.expectEqual(pcm.State.resetting, model.state);
        try reply(&model, .reset, true);
        try t.expectEqual(pcm.State.closed, model.state);
        try invariant(&model);
    }
}

test "PCM model: owner death in prepared, draining, XRUN, STOP and RELEASE" {
    for ([_]pcm.State{ .prepared, .draining, .xrun, .stopping, .releasing }) |state| {
        var model = pcm.Model{};
        const token = try prepared(&model);
        if (state != .prepared) {
            _ = try model.submit(token, audio[0..8]);
            const transfer = try model.publish(0);
            try running(&model, token);
            if (state != .xrun) try model.end(token, 0);
            if (state != .draining) try model.complete(.{ .transfer = transfer }, 0);
            if (state == .releasing) try reply(&model, .stop, true);
        }
        try t.expectEqual(state, model.state);
        const previous = model.control();
        try model.owner_death(42, 0);
        try t.expectError(error.InvalidToken, model.reserve(token, 8));
        if (previous) |control| try t.expectEqual(control, model.control().?);
        if (model.state != .releasing) try reply(&model, .stop, true);
        try reply(&model, .release, true);
        if (model.state == .resetting) try reply(&model, .reset, true);
        try t.expectEqual(pcm.State.closed, model.state);
        try invariant(&model);
    }
}
