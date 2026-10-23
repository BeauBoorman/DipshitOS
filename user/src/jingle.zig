//! census (M188e, #3190): JINGLE.BIN — gate-referenced: live-sound-app.
//! VirelaiOS twenty-sixth ESP user program — JINGLE.BIN (Milestone 15,
//! Card A3, claim 7636).
//!
//! Headless class-B proof for the EL0 audio seam (ADR 0007 slots 42–43):
//! ask `sys_audio_info` what format/rate/channels the device is
//! negotiated to, synthesize a recognizable melody ("Twinkle Twinkle
//! Little Star" — C C G G A A G, F F E E D D C) as per-note PCM in
//! exactly that format, and play each note with `sys_audio_play`. Every
//! note prints a marker (freq, duration, bytes played) for
//! `tools/verify-live-sound-app.sh`.
//!
//! The device (observed on VZ, claims 5877/7636) advertises FLOAT(19) /
//! 48000(7) / stereo(2); the synth handles FLOAT, S16 and S32 so the app
//! works against whatever the device offers. A note longer than the
//! kernel's 64 KiB `audio_max_len` bound is submitted in bounded chunks
//! (each chunk is its own `sys_audio_play` — the kernel plays + drains
//! it in real-time, so the melody tempo is the device's own clock, and
//! the chunked accounting is the gate's evidence).

const std = @import("std");
const ui = @import("lib/ui.zig");

const Note = struct { freq: u32, ms: u32 };

// Twinkle Twinkle Little Star — the opening phrase. Each quarter is 250 ms;
// the phrase ends on a half note (500 ms).
const melody = [_]Note{
    .{ .freq = 262, .ms = 250 }, // C4
    .{ .freq = 262, .ms = 250 }, // C4
    .{ .freq = 392, .ms = 250 }, // G4
    .{ .freq = 392, .ms = 250 }, // G4
    .{ .freq = 440, .ms = 250 }, // A4
    .{ .freq = 440, .ms = 250 }, // A4
    .{ .freq = 392, .ms = 500 }, // G4 (half)
    .{ .freq = 349, .ms = 250 }, // F4
    .{ .freq = 349, .ms = 250 }, // F4
    .{ .freq = 330, .ms = 250 }, // E4
    .{ .freq = 330, .ms = 250 }, // E4
    .{ .freq = 294, .ms = 250 }, // D4
    .{ .freq = 294, .ms = 250 }, // D4
    .{ .freq = 262, .ms = 500 }, // C4 (half)
};

/// The per-chunk staging buffer. Chunks stay well under the kernel's
/// 64 KiB `audio_max_len` bound (zero-heap by construction). The buffer
/// is a STACK local in `_start` — the app's text page is W^X (EL0
/// read-only), so writable data lives on the stack, the same pattern as
/// every other user program (a 4 KiB local is well inside the 8 KiB
/// user stack).
const chunk_cap_bytes: usize = 4 * 1024;

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    @memcpy(buf[pos .. pos + src.len], src);
    return pos + src.len;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

/// Samples per second for a RATE_* enum value (the kernel's numbering;
/// 0 for unknown).
fn rate_hz(rate: u8) u32 {
    return switch (rate) {
        1 => 8000,
        3 => 16000,
        4 => 22050,
        5 => 32000,
        6 => 44100,
        7 => 48000,
        else => 0,
    };
}

/// Synthesize `frames` frames of a sine at `freq` Hz starting at absolute
/// frame `start_frame` (phase continuity across chunks), `channels`
/// interleaved, at 50% amplitude, in the negotiated format.
fn synth_note(out: []u8, freq: u32, frames: u32, format: u8, channels: u8, rate_hz_val: u32, start_frame: u32) void {
    const step = 2.0 * std.math.pi * @as(f64, @floatFromInt(freq)) / @as(f64, @floatFromInt(rate_hz_val));
    var i: u32 = 0;
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        const sample = @sin(step * @as(f64, @floatFromInt(start_frame + f))) * 0.5;
        var ch: u8 = 0;
        while (ch < channels) : (ch += 1) {
            switch (format) {
                19 => { // FMT_FLOAT
                    const v: f32 = @floatCast(sample);
                    @memcpy(out[i..][0..4], std.mem.asBytes(&v));
                },
                5 => { // FMT_S16
                    const v: i16 = @intFromFloat(sample * 32767.0);
                    @memcpy(out[i..][0..2], std.mem.asBytes(&v));
                },
                17 => { // FMT_S32
                    const v: i32 = @intFromFloat(sample * 2147483647.0);
                    @memcpy(out[i..][0..4], std.mem.asBytes(&v));
                },
                else => {
                    out[i] = 0;
                    out[i + 1] = 0;
                    out[i + 2] = 0;
                    out[i + 3] = 0;
                },
            }
            i += 4;
        }
    }
}

fn fmt_bps(format: u8) u32 {
    return switch (format) {
        19, 17 => 4,
        else => 2,
    };
}

pub export fn _start() callconv(.c) noreturn {
    var chunk_buf: [chunk_cap_bytes]u8 align(8) = undefined;
    var info: ui.AudioInfo = undefined;
    const info_rc = ui.audio_info(&info);
    if (info_rc < 0 or info.ready == 0) {
        ui.write_console("jingle: no audio device (ENXIO)\n");
        ui.exit_process(1);
    }
    // Report the negotiated state (the gate asserts this line).
    var ibuf: [96]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&ibuf, pos, "jingle: info fmt=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], info.format));
    pos = append_str(&ibuf, pos, " rate=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], info.rate));
    pos = append_str(&ibuf, pos, " ch=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], info.channels));
    pos = append_str(&ibuf, pos, " period=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], info.period_bytes));
    pos = append_str(&ibuf, pos, " max=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], info.max_len));
    ibuf[pos] = '\n';
    ui.write_console(ibuf[0 .. pos + 1]);

    const hz = rate_hz(info.rate);
    if (hz == 0) {
        ui.write_console("jingle: unknown rate\n");
        ui.exit_process(2);
    }
    const frame_bytes = fmt_bps(info.format) * info.channels;
    const frames_per_chunk = @max(@as(u32, 1), @as(u32, @intCast(chunk_cap_bytes)) / frame_bytes);

    var note: u32 = 1;
    for (melody) |n| {
        const frames = @max(@as(u32, 1), (n.ms * hz) / 1000);
        var total_played: u64 = 0;
        var off_frames: u32 = 0;
        var chunks: u32 = 0;
        while (off_frames < frames) {
            const chunk_frames = @min(frames - off_frames, frames_per_chunk);
            const chunk_bytes = chunk_frames * frame_bytes;
            synth_note(chunk_buf[0..chunk_bytes], n.freq, chunk_frames, info.format, info.channels, hz, off_frames);
            const played = ui.audio_play(chunk_buf[0..chunk_bytes]);
            if (played != chunk_bytes) {
                ui.write_console("jingle: note play failed\n");
                ui.exit_process(4);
            }
            total_played += @intCast(played);
            off_frames += chunk_frames;
            chunks += 1;
        }
        // The per-note marker (the gate asserts the played accounting).
        var nbuf: [96]u8 = undefined;
        var p: usize = 0;
        p = append_str(&nbuf, p, "jingle: note ");
        p = append_str(&nbuf, p, fmt_u64(nbuf[p..], note));
        p = append_str(&nbuf, p, " f=");
        p = append_str(&nbuf, p, fmt_u64(nbuf[p..], n.freq));
        p = append_str(&nbuf, p, " dur=");
        p = append_str(&nbuf, p, fmt_u64(nbuf[p..], n.ms));
        p = append_str(&nbuf, p, " chunks=");
        p = append_str(&nbuf, p, fmt_u64(nbuf[p..], chunks));
        p = append_str(&nbuf, p, " played=");
        p = append_str(&nbuf, p, fmt_u64(nbuf[p..], total_played));
        nbuf[p] = '\n';
        ui.write_console(nbuf[0 .. p + 1]);
        note += 1;
    }

    ui.write_console("jingle: done\n");
    ui.exit_process(0);
}
