const std = @import("std");
const port = @import("port.zig");
const pcm = @import("pcm.zig");
const t = std.testing;

test "port reuses phrase and seed WAV bytes unchanged" {
    for ([_][]const u8{ "a", "kujamba karibu", "mtu", "Ng'OMA", "kujamba 123 karibu!" }) |phrase| {
        const expected = try port.synth.renderPhraseWav(t.allocator, phrase);
        defer t.allocator.free(expected);
        const actual = try port.render(t.allocator, .{ .phrase = phrase });
        defer t.allocator.free(actual);
        try t.expectEqualSlices(u8, expected, actual);
    }
    for ([_]u64{ 0, 42, 1234567, std.math.maxInt(u64) }) |seed| {
        const expected = try port.synth.renderShuziWav(t.allocator, seed);
        defer t.allocator.free(expected);
        const actual = try port.render(t.allocator, .{ .seed = seed });
        defer t.allocator.free(actual);
        try t.expectEqualSlices(u8, expected, actual);
    }
}

test "input and exact duration ceiling refuse before rendering" {
    try port.checkSamples(220_500);
    try t.expectError(error.DurationLimit, port.checkSamples(220_501));
    // 16 voiced + four breath syllables, with gaps and penultimate stress.
    const at = try port.render(t.allocator, .{ .phrase = "bbbbb" ++ &@as([16:0]u8, @splat("a"[0])) });
    defer t.allocator.free(at);
    try t.expectEqual(@as(usize, 441_044), at.len);
    try t.expectError(error.DurationLimit, port.render(t.allocator, .{ .phrase = &@as([19:0]u8, @splat("a"[0])) }));
    const text = "a" ++ &@as([254:0]u8, @splat(" "[0]));
    const max_input = try port.render(t.allocator, .{ .phrase = text });
    defer t.allocator.free(max_input);
    try t.expectError(error.InputLimit, port.render(t.allocator, .{ .phrase = text ++ " " }));
    try t.expectError(error.NoSyllables, port.render(t.allocator, .{ .phrase = "123!" }));
}

test "caller allocation failures propagate and release partial plans and samples" {
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn render(a: std.mem.Allocator) !void {
            const wav = try port.render(a, .{ .phrase = "kujamba karibu" });
            defer a.free(wav);
        }
    }.render, .{});
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn render(a: std.mem.Allocator) !void {
            const wav = try port.render(a, .{ .seed = 42 });
            defer a.free(wav);
        }
    }.render, .{});
}

test "one arena enforces allocation bound and reuses all engine buffers" {
    const Arena = @import("arena").Arena;
    const memory = try t.allocator.alignedAlloc(u8, .fromByteUnits(4096), port.arena_bytes);
    defer t.allocator.free(memory);
    const arena = try Arena.init(memory);
    const baseline = arena.used();
    for (0..4) |_| {
        const wav = try port.render(arena.allocator(), .{ .phrase = "bbbbb" ++ &@as([16:0]u8, @splat("a"[0])) });
        arena.allocator().free(wav);
        try t.expectEqual(baseline, arena.used());
    }
    try t.expect(arena.peak() < port.arena_bytes);
    const full = try arena.allocator().alloc(u8, port.arena_bytes - baseline - 16);
    try t.expectEqual(port.arena_bytes, arena.used());
    try t.expectError(error.OutOfMemory, port.render(arena.allocator(), .{ .seed = 0 }));
    arena.allocator().free(full);
    var small: [4096]u8 align(4096) = undefined;
    const limited = try Arena.init(&small);
    try t.expectError(error.OutOfMemory, port.render(limited.allocator(), .{ .phrase = "a" }));
    try t.expectEqual(baseline, limited.used());
}

test "PCM formats and channels encode exact signed extremes with no header" {
    const source = [_]u8{ 0, 128, 0, 0, 255, 127 };
    for ([_]u8{ 5, 17, 19 }) |format| {
        for ([_]u8{ 1, 2 }) |channels| {
            const out = try pcm.convert(t.allocator, &source, .{
                .ready = 1,
                .rate = 6,
                .format = format,
                .channels = channels,
                .max_len = 65536,
            });
            defer t.allocator.free(out);
            const width: usize = if (format == 5) 2 else 4;
            try t.expectEqual(3 * width * channels, out.len);
            for ([_]i16{ -32768, 0, 32767 }, 0..) |sample, frame| {
                for (0..channels) |channel| {
                    const offset = (frame * channels + channel) * width;
                    switch (format) {
                        5 => try t.expectEqual(sample, std.mem.readInt(i16, out[offset..][0..2], .little)),
                        17 => try t.expectEqual(@as(i32, sample) * 65536, std.mem.readInt(i32, out[offset..][0..4], .little)),
                        19 => try t.expectEqual(@as(f32, @floatFromInt(sample)) / 32768.0, @as(f32, @bitCast(std.mem.readInt(u32, out[offset..][0..4], .little)))),
                        else => unreachable,
                    }
                }
            }
        }
    }
}

test "every negotiated rate uses integer nearest-neighbor resampling" {
    const source = try t.allocator.alloc(u8, 882);
    defer t.allocator.free(source);
    for (0..441) |i| std.mem.writeInt(i16, source[2 * i ..][0..2], @intCast(i), .little);
    for ([_]u8{ 0, 2, 3, 5, 6, 7 }, [_]usize{ 8000, 16000, 22050, 32000, 44100, 48000 }) |rate, hz| {
        const out = try pcm.convert(t.allocator, source, .{
            .ready = 1,
            .rate = rate,
            .format = 5,
            .channels = 1,
            .max_len = 65536,
        });
        defer t.allocator.free(out);
        const frames = (441 * hz + 44099) / 44100;
        try t.expectEqual(frames * 2, out.len);
        for (0..frames) |frame|
            try t.expectEqual(@as(i16, @intCast(frame * 44100 / hz)), std.mem.readInt(i16, out[frame * 2 ..][0..2], .little));
    }
}

test "PCM bounds, unsupported negotiation and allocation refusal are explicit" {
    var info = pcm.Info{ .ready = 1, .rate = 6, .format = 5, .channels = 1, .max_len = 65536 };
    try t.expectEqual(@as(usize, 65536), (try pcm.layout(32768, info)).bytes);
    try t.expectError(error.PlaybackLimit, pcm.layout(32769, info));
    info.max_len = 100;
    try t.expectEqual(@as(usize, 100), (try pcm.layout(50, info)).bytes);
    try t.expectError(error.PlaybackLimit, pcm.layout(51, info));
    info.ready = 0;
    try t.expectError(error.NoSoundDevice, pcm.layout(1, info));
    info.ready = 1;
    info.rate = 255;
    try t.expectError(error.UnsupportedAudioRate, pcm.layout(1, info));
    info.rate = 6;
    info.format = 255;
    try t.expectError(error.UnsupportedAudioFormat, pcm.layout(1, info));
    info.format = 5;
    info.channels = 3;
    try t.expectError(error.UnsupportedAudioChannels, pcm.layout(1, info));
    info.channels = 1;
    try t.expectError(error.InvalidPcm, pcm.convert(t.allocator, &.{1}, info));
    try t.expectError(error.InvalidPcm, pcm.convert(t.allocator, &.{}, info));
    try t.expectError(error.OutOfMemory, pcm.convert(std.testing.failing_allocator, &.{ 0, 0 }, info));
}

test "native playback makes one raw submission and never hides device or short-play errors" {
    const Mock = struct {
        var calls: usize = 0;
        var result: isize = 2;
        fn call(n: usize, args: [6]usize) isize {
            calls += 1;
            if (n == 42) {
                const info: *pcm.Info = @ptrFromInt(args[0]);
                info.* = .{};
                return 0;
            }
            if (n != 43 or args[1] != 2) unreachable;
            const bytes: [*]const u8 = @ptrFromInt(args[0]);
            if (bytes[0] != 0x34 or bytes[1] != 0x12) unreachable;
            return result;
        }
    };
    Mock.calls = 0;
    try t.expectError(error.NoSoundDevice, pcm.query(Mock.call));
    try t.expectEqual(@as(usize, 1), Mock.calls);
    Mock.calls = 0;
    try pcm.submit(Mock.call, &.{ 0x34, 0x12 });
    try t.expectEqual(@as(usize, 1), Mock.calls);
    Mock.result = -9;
    try t.expectError(error.AudioDeviceRefused, pcm.submit(Mock.call, &.{ 0x34, 0x12 }));
    Mock.result = -3;
    try t.expectError(error.AudioBufferFault, pcm.submit(Mock.call, &.{ 0x34, 0x12 }));
    Mock.result = -5;
    try t.expectError(error.AudioPlayFailed, pcm.submit(Mock.call, &.{ 0x34, 0x12 }));
    Mock.result = 1;
    try t.expectError(error.ShortPlayback, pcm.submit(Mock.call, &.{ 0x34, 0x12 }));
}

test {
    _ = port.synth;
}
