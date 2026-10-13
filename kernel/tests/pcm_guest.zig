//! B7/M99b native acceptance fixture, not a shipped app. No libc or capture.
//! Modes: default = orchestrator process; argv "peer" = second concurrent
//! streamer; argv "death" = open/prefill/start then exit for owner-death
//! teardown while a survivor keeps streaming.
const std = @import("std");
pub const panic = std.debug.FullPanic(panicImpl);
const flag: u64 = @as(u64, 1) << 63;
const Params = extern struct { format: u8 = 19, rate: u8 = 7, channels: u8 = 2, reserved: u8 = 0, version: u32 = 1 };
const Status = extern struct {
    generation: u64,
    accepted: u64,
    submitted: u64,
    completed: u64,
    canceled: u64,
    underruns: u64,
    clipped: u64,
    state: u32,
    reason: u32,
    outstanding: u32,
    slots: u32,
    sources: u32,
    peak_sources: u32,
    refused: u32,
    starts: u32,
    stops: u32,
    releases: u32,
    resets: u32,
};
export var pcm_probe_state: u64 = 1;
var samples: [4096]u8 = @splat(0);
var frame_offset: u32 = 0;

fn call(number: u64, args: [6]u64) i64 {
    var result: i64 = undefined;
    asm volatile ("svc #0"
        : [result] "={x0}" (result),
        : [number] "{x8}" (number),
          [a0] "{x0}" (args[0]),
          [a1] "{x1}" (args[1]),
          [a2] "{x2}" (args[2]),
          [a3] "{x3}" (args[3]),
          [a4] "{x4}" (args[4]),
          [a5] "{x5}" (args[5]),
        : .{ .memory = true });
    return result;
}
fn say(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = call(1, .{ 1, @intFromPtr(bytes.ptr) + offset, bytes.len - offset, 0, 0, 0 });
        if (n <= 0) exit(72);
        offset += @intCast(n);
    }
}
fn exit(code: u64) noreturn {
    _ = call(3, .{ code, 0, 0, 0, 0, 0 });
    unreachable;
}
fn panicImpl(_: []const u8, _: ?usize) noreturn {
    say("b7: PANIC\n");
    exit(71);
}
var phase: u8 = '0';
fn require(ok: bool) void {
    if (!ok) {
        var buf: [24]u8 = undefined;
        say(std.fmt.bufPrint(&buf, "b7: FAIL @{c}\n", .{phase}) catch "b7: FAIL\n");
        exit(70);
    }
}
fn audio(op: u64, generation: u64, pointer: u64, length: usize) i64 {
    return call(43, .{ pointer, flag | length, op, generation, 0, 0 });
}
fn counter() u64 {
    return asm volatile ("mrs %[v], cntpct_el0"
        : [v] "=r" (-> u64),
    );
}
fn budget() u64 {
    const freq = asm volatile ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
    return counter() + 10 * freq;
}
fn open() u64 {
    var params = Params{};
    const until = budget();
    while (counter() < until) {
        const n = audio(1, 0, @intFromPtr(&params), @sizeOf(Params));
        if (n == -11) continue; // bounded deferred teardown between streams
        require(n > 0);
        return @intCast(n);
    }
    require(false);
    unreachable;
}
fn status(generation: u64) Status {
    var result: Status = undefined;
    require(audio(6, generation, @intFromPtr(&result), @sizeOf(Status)) == 0);
    // The per-source queue bound is four periods; outstanding is the queue
    // plus this source's share of the device ring still in flight.
    require(result.slots == 4 and result.outstanding <= 16384 + 32768);
    return result;
}
fn closed(generation: u64) Status {
    // A freed seat still has bytes owned by the device (composed but not yet
    // completed): they credit the post-close snapshot asynchronously, so the
    // identity only settles when outstanding reaches zero.
    const until = budget();
    while (counter() < until) {
        const result = status(generation);
        if (result.state == 0 and result.outstanding == 0) return result;
        if (result.state == 10 or result.state == 8) { // quarantined/resetting
            var buf: [80]u8 = undefined;
            say(std.fmt.bufPrint(&buf, "b7: terminal state={d} reason={d} @{c}\n", .{ result.state, result.reason, phase }) catch unreachable);
            exit(70);
        }
    }
    const last = status(generation);
    var buf: [80]u8 = undefined;
    say(std.fmt.bufPrint(&buf, "b7: close-timeout state={d} outstanding={d} @{c}\n", .{ last.state, last.outstanding, phase }) catch unreachable);
    exit(70);
}
fn synth() void {
    for (0..512) |i| {
        const t: f64 = @floatFromInt(frame_offset + i);
        const sample: f32 = @floatCast(@sin(2 * std.math.pi * 440 * t / 48000) * 0.1);
        const bits: u32 = @bitCast(sample);
        std.mem.writeInt(u32, samples[i * 8 ..][0..4], bits, .little);
        std.mem.writeInt(u32, samples[i * 8 + 4 ..][0..4], bits, .little);
    }
    frame_offset += 512;
}
fn submit(generation: u64) void {
    synth();
    const until = budget();
    while (counter() < until) {
        const n = audio(2, generation, @intFromPtr(&samples), samples.len);
        if (n == -11) continue; // source queue full: backpressure, not error
        if (n != 4096) {
            var buf: [128]u8 = undefined;
            const s = status(generation);
            say(std.fmt.bufPrint(&buf, "b7: submit refused={d} state={d} reason={d}\n", .{ n, s.state, s.reason }) catch unreachable);
        }
        require(n == 4096);
        return;
    }
    require(false);
}
fn prefill(generation: u64) void {
    for (0..4) |_| submit(generation);
}
fn start(generation: u64) void {
    require(audio(3, generation, 0, 0) == 0);
}
fn exec_self(mode: []const u8) i64 {
    const name = "PCM.BIN";
    var arg: [256]u8 = @splat(0);
    @memcpy(arg[0..mode.len], mode);
    return call(28, .{ @intFromPtr(name.ptr), name.len, @intFromPtr(&arg), 1, 0, 0 });
}

export fn _start(argc: u64, argv: u64) callconv(.c) noreturn {
    pcm_probe_state += 1;
    if (argc > 0) {
        const block: [*]const u8 = @ptrFromInt(argv);
        if (std.mem.startsWith(u8, block[0..256], "peer")) {
            // Second concurrent streamer: the card's "two processes make
            // sound at the same time" half. It opens its own seat on the
            // already-running device stream, streams, drains and reports
            // its own generation's counters.
            phase = 'p';
            const generation = open();
            prefill(generation);
            phase = 'q';
            start(generation);
            for (0..12) |_| submit(generation);
            phase = 'r';
            {
                const e = audio(4, generation, 0, 0);
                if (e != 0) {
                    var buf: [48]u8 = undefined;
                    say(std.fmt.bufPrint(&buf, "b7: peer-end refused={d}\n", .{e}) catch unreachable);
                    exit(70);
                }
            }
            const drained = closed(generation);
            phase = 's';
            require(drained.accepted == 65536 and drained.submitted == 65536 and drained.completed == 65536);
            require(drained.canceled == 0 and drained.reason == 0);
            say("b7: peer accepted=65536 submitted=65536 completed=65536 sources=2\n");
            exit(0);
        }
        if (std.mem.startsWith(u8, block[0..256], "death")) {
            const generation = open();
            prefill(generation);
            start(generation);
            say("b7: owner exits with queued PCM\n");
            exit(0);
        }
    }
    var params = Params{};
    const initial = audio(1, 0, @intFromPtr(&params), @sizeOf(Params));
    if (initial == -9) {
        require(call(43, .{ @intFromPtr(&samples), 8, 0, 0, 0, 0 }) == -9);
        say("b7: NO AUDIO DEVICE (ENXIO), playback refused\n");
        say("b7: done\n");
        exit(0);
    }
    require(initial > 0);
    const generation: u64 = @intCast(initial);
    require(audio(3, generation, 0, 0) == -1); // no prefill
    require(audio(2, generation, 0xffff_ffff_ffff_f000, 4096) == -3);
    require(status(generation).accepted == 0); // failed copy rolled back
    require(audio(2, generation, @intFromPtr(&samples), 7) == -1);
    require(audio(2, generation, @intFromPtr(&samples), 4097) == -8);
    require(audio(2, generation + 1, @intFromPtr(&samples), 8) == -1);
    // Legacy slot-43 playback stays refused while a source seat is open.
    require(call(43, .{ @intFromPtr(&samples), 8, 0, 0, 0, 0 }) == -11);
    prefill(generation);
    require(audio(2, generation, @intFromPtr(&samples), 4096) == -11);
    require(status(generation).accepted == 16384);
    say("b7: bounds=4x4096 backpressure=EAGAIN accepted=16384 copy-rollback=0 legacy=EAGAIN\n");

    // The source bound is four seats: fill them and watch the (N+1)th open
    // refuse ENOSPC and count it; then free the spares.
    var spares: [3]u64 = undefined;
    for (&spares) |*g| {
        g.* = open();
        require(g.* > 0);
    }
    require(status(generation).sources == 4);
    require(audio(1, 0, @intFromPtr(&params), @sizeOf(Params)) == -5);
    require(status(generation).refused == 1);
    for (spares) |g| require(audio(5, g, 0, 0) == 0);
    require(status(generation).sources == 1);
    say("b7: cap=4 open5=ENOSPC refused=1 sources=1\n");

    phase = 'a';
    start(generation);
    for (0..8) |_| submit(generation);

    // Two processes streaming at once: the peer execs PCM.BIN, opens its
    // own seat on the running device stream, and streams while we do.
    phase = 'b';
    const peer = exec_self("peer");
    require(peer >= 0);
    {
        const until = budget();
        var seen: u32 = 0;
        while (counter() < until and seen != 2) {
            seen = status(generation).sources;
        }
        require(seen == 2);
    }
    for (0..8) |_| submit(generation); // overlapped streaming
    require(call(8, .{ @intCast(peer), 0, 0, 0, 0, 0 }) == 0);
    const after_peer = status(generation);
    require(after_peer.peak_sources == 4 and after_peer.sources == 1);
    say("b7: overlap sources=2 peak=4 both-advanced\n");

    // Owner death mid-stream: the child's seat reaps while ours streams on.
    const dying = exec_self("death");
    require(dying >= 0);
    require(call(8, .{ @intCast(dying), 0, 0, 0, 0, 0 }) == 0);
    for (0..8) |_| submit(generation);
    require(status(generation).sources == 1);
    say("b7: owner-death teardown sources=1 survivor-advances\n");

    // Starvation is per-source data now, not whole-stream death: stop
    // feeding for a slice, watch underruns accrue with state still running,
    // then resume cleanly.
    const before_gap = status(generation).underruns;
    {
        const freq = asm volatile ("mrs %[v], cntfrq_el0"
            : [v] "=r" (-> u64),
        );
        const until = counter() + freq / 4;
        while (counter() < until) {}
    }
    const starved = status(generation);
    require(starved.underruns > before_gap and starved.state == 4);
    for (0..4) |_| submit(generation);
    say("b7: underrun counted no-XRUN resume=ok\n");

    // 4 prefill + 8 + 8 + 8 + 4 = 32 periods accepted end to end.
    require(audio(4, generation, 0, 0) == 0);
    const drained = closed(generation);
    require(drained.accepted == 131072 and drained.submitted == 131072 and drained.completed == 131072);
    require(drained.canceled == 0 and drained.reason == 0 and drained.outstanding == 0);
    require(drained.starts == 1 and drained.stops == 1 and drained.releases == 1 and drained.resets == 0);
    say("b7: continuous accepted=131072 submitted=131072 completed=131072 starts=1 stops=1 releases=1 resets=0\n");
    say("b7: output only, no capture or low-latency claim\n");
    say("b7: done\n");
    exit(0);
}
