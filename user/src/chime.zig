//! census (M188e, #3190): CHIME.BIN — gate-referenced: live-m15-composition, live-sound-control.
//! VirelaiOS twenty-seventh ESP user program — CHIME.BIN (Milestone 15,
//! Card A4, claim 3206).
//!
//! The composition capstone's event-triggered sound: a sound that FIRES ON
//! AN EXISTING EVENT — the M14 shared app-timer (ADR 0007 slots 40/41,
//! claim 7323). This app arms a one-tick timer, BLOCKS in `sys_wait_event`
//! (no spin loop — the S2 promise), and on every `TIMER` event (kind 9 on
//! the ADR 0009 queue) plays a short blip through the EL0 audio seam
//! (ADR 0007 slots 42/43, claim 7636). That is the milestone's composition
//! in one program: the kernel's scheduler tick → a shared service event →
//! EL0 audio — the M14 shared services and M15 audio composing in the same
//! session.
//!
//! The blip is synthesized in the negotiated format (observed on VZ:
//! FLOAT 19 / 48000 7 / stereo 2), submitted in bounded chunks (each chunk
//! its own `sys_audio_play`), and every tick prints a marker for
//! `tools/verify-live-m15-composition.sh`. The boot chime (kernel-side,
//! `snd_chime`) is the other half of the capstone; this app is the EL0
//! event side.

const std = @import("std");
const ui = @import("lib/ui.zig");

/// How many timer ticks to play: three blips, one per TIMER event.
const tick_count: u32 = 3;

/// The blip: a short high note (880 Hz, 100 ms) — clearly audible, short
/// enough to not stall the demo. At FLOAT/stereo/48 kHz that's 4800 frames
/// = 38400 bytes, submitted in bounded chunks below the kernel's 64 KiB
/// `audio_max_len`.
const blip_freq: u32 = 880;
const blip_ms: u32 = 100;

/// The per-chunk staging buffer (a STACK local in `_start` — the app's
/// text page is W^X, so writable data lives on the stack, the pattern
/// every other user program uses).
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
fn synth_blip(out: []u8, freq: u32, frames: u32, format: u8, channels: u8, rate_hz_val: u32, start_frame: u32) void {
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

export fn _start() callconv(.c) noreturn {
    var chunk_buf: [chunk_cap_bytes]u8 align(8) = undefined;
    var info: ui.AudioInfo = undefined;
    const info_rc = ui.audio_info(&info);
    if (info_rc < 0 or info.ready == 0) {
        ui.write_console("chime: no audio device (ENXIO)\n");
        ui.exit_process(1);
    }
    var ibuf: [96]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&ibuf, pos, "chime: info fmt=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], info.format));
    pos = append_str(&ibuf, pos, " rate=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], info.rate));
    pos = append_str(&ibuf, pos, " ch=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], info.channels));
    ibuf[pos] = '\n';
    ui.write_console(ibuf[0 .. pos + 1]);

    const hz = rate_hz(info.rate);
    if (hz == 0) {
        ui.write_console("chime: unknown rate\n");
        ui.exit_process(2);
    }
    // M15 follow-up (claim 9297): drive the stream-state control through
    // the EL0 seam — half volume, unmuted — before the first blip. The
    // kernel applies this gain to every period of every blip below (the
    // submit choke point), so the app hears its own attenuated playback.
    const vol_rc = ui.audio_volume(50);
    const mute_rc = ui.audio_mute(0);
    if (vol_rc < 0 or mute_rc < 0) {
        ui.write_console("chime: stream-state control failed\n");
        ui.exit_process(6);
    }
    var sbuf: [64]u8 = undefined;
    var sp: usize = 0;
    sp = append_str(&sbuf, sp, "chime: vol=");
    sp = append_str(&sbuf, sp, fmt_u64(sbuf[sp..], @intCast(vol_rc)));
    sp = append_str(&sbuf, sp, " mute=");
    sp = append_str(&sbuf, sp, fmt_u64(sbuf[sp..], @intCast(mute_rc)));
    sbuf[sp] = '\n';
    ui.write_console(sbuf[0 .. sp + 1]);

    const frame_bytes = fmt_bps(info.format) * info.channels;
    const frames_per_chunk = @max(@as(u32, 1), @as(u32, @intCast(chunk_cap_bytes)) / frame_bytes);
    const blip_frames = @max(@as(u32, 1), (blip_ms * hz) / 1000);

    var tick: u32 = 1;
    while (tick <= tick_count) : (tick += 1) {
        // 1. Arm a one-tick timer (M14 S2 — the shared service).
        if (ui.timer_set(1) < 0) {
            ui.write_console("chime: timer_set failed\n");
            ui.exit_process(3);
        }
        // 2. Block until the TIMER event lands in the ADR 0009 queue.
        var ev: ui.Event = undefined;
        if (ui.wait_event(&ev) <= 0 or ev.kind != ui.EVENT_TIMER) {
            ui.write_console("chime: no TIMER event\n");
            ui.exit_process(4);
        }
        // 3. Play the blip through the EL0 audio seam, in bounded chunks.
        var total_played: u64 = 0;
        var off_frames: u32 = 0;
        var chunks: u32 = 0;
        while (off_frames < blip_frames) {
            const chunk_frames = @min(blip_frames - off_frames, frames_per_chunk);
            const chunk_bytes = chunk_frames * frame_bytes;
            synth_blip(chunk_buf[0..chunk_bytes], blip_freq, chunk_frames, info.format, info.channels, hz, off_frames);
            const played = ui.audio_play(chunk_buf[0..chunk_bytes]);
            if (played != chunk_bytes) {
                ui.write_console("chime: blip play failed\n");
                ui.exit_process(5);
            }
            total_played += @intCast(played);
            off_frames += chunk_frames;
            chunks += 1;
        }
        var tbuf: [96]u8 = undefined;
        var p: usize = 0;
        p = append_str(&tbuf, p, "chime: tick ");
        p = append_str(&tbuf, p, fmt_u64(tbuf[p..], tick));
        p = append_str(&tbuf, p, " seq=");
        p = append_str(&tbuf, p, fmt_u64(tbuf[p..], ev.seq));
        p = append_str(&tbuf, p, " chunks=");
        p = append_str(&tbuf, p, fmt_u64(tbuf[p..], chunks));
        p = append_str(&tbuf, p, " played=");
        p = append_str(&tbuf, p, fmt_u64(tbuf[p..], total_played));
        tbuf[p] = '\n';
        ui.write_console(tbuf[0 .. p + 1]);
    }

    ui.write_console("chime: done\n");
    ui.exit_process(0);
}
