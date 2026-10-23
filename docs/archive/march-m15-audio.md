> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone fifteen march — audio (living tracker)

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds milestone-
> fifteen's per-card detail and collision-free agent split, following the
> [`march-m14.md`](march-m14.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

## Why audio (wishlist item 18)

Every "bridge the maintainer would be most disappointed to see omitted" is
now shipped — EL0 application events (M9), userland filesystem access
(M10), consumer GUI apps + a launcher (M11), and the shared-services arc
(M14). The next **concrete, non-conditional** wishlist item is **audio**
(item 18, "VirelaiOS becomes a computer"): another real device/service
pipeline exactly like the virtio-net work, but for sound. The host side
exists — Apple's Virtualization.framework has shipped virtio-snd
(`VZVirtioSoundDeviceConfiguration` with PCM stream configs) since macOS
13 — so this is greenfield *guest* work, not a host capability gap.

Deferred (wishlist order, still on the map as M16+ candidates): item 13
resource-model cleanup ("keep them bounded until real apps expose actual
pain" — the pools are still comfortably bounded), items 14/15 richer VM +
executable-format ("only when applications force it" — the DSK1 apps are
still small), item 17 better filesystem semantics (pressure-driven; B1
already added delete/rename/truncate/free). Distant mountains (item 20:
SMP, 3D, dynamic linking, POSIX) stay visible, not climbed.

**Meta-requirement (roadmap):** every infrastructure card names the small
experience that consumes it, and the milestone ends in a composition test
a human can perceive. Audio's composition test is audible — the strongest
"VirelaiOS is a computer" signal yet.

## The cards, in order

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| A1 | **virtio-snd transport.** Host: `VMRunner` attaches `VZVirtioSoundDeviceConfiguration` (one output PCM stream) behind a new flag-gated `--sound` mode — the default VM stays byte-identical, the `--net`/`--input` precedent. Guest: discover the virtio-snd PCI device (virtio device type 25; expected non-transitional DID `0x1059` = `0x1040+25`, the same convention as net `0x1041` / entropy `0x1044` / gpu `0x1050` — **pinned at claim time**), negotiate features, drive the control queue, and arm the stream. Live gate: `verify-live-sound-device.sh` — the guest's own `sound` report. Consuming experience: the `sound` monitor command (the `usb`/`net` pattern). | ✅ | claim 6140, `verify-live-sound-device.sh` PASS 1/1 on VZ (2026-08-18): DID **0x1059** (prediction held), cls 0x040100, st=0x0f DRIVER_OK, ctrl queue armed (qsz=4), rearm ok; NOT reset by VZ (st=0x0f pre-rearm, like net/gpu). **Finding:** VZ reports cfg counts 0/0/0 (le32 jacks/streams/chmaps all zero from pre- and post-exit reads, raw 32 B dump uniform zero, even with 2 streams attached) — A2 enumerates topology via CONTROL-queue JACK_INFO/PCM_INFO instead. | Wishlist 18. |
| A2 | **PCM playback + the shared sound buffer.** A bounded PCM ring (fixed BSS, zero heap — the M14 constraint) fed by a `beep <freq> <ms>` monitor command that synthesizes a sine wave; the driver submits buffers to the device and VZ routes them to the Mac's output. Live gate: `verify-live-sound-playback.sh` — N frames submitted/drained (the guest's own accounting). Consuming experience: a beep the human hears. | ✅ | claim 5877, `verify-live-sound-playback.sh` PASS 1/1 on VZ (2026-08-18): PCM_INFO S_OK (formats 0xa0020 = S16\|S32\|FLOAT, rates 0x480 = 48000\|96000, ch 1..2 OUTPUT), negotiated FLOAT/48000/stereo, SET_PARAMS+PREPARE+START+STOP+RELEASE all S_OK (0x8000), **115200 B submitted in 4096-B periods, all drained** (14400 frames, pcm_status 0x8000). **Protocol pinned live:** VZ speaks the virtio-1.3 control renumbering (status OK=0x8000 — a 1.2-style code-3 request got BAD_MSG 0x8001) and writes control replies **[status hdr][entries]** (status first, unlike the Linux driver's [entries][status]); the used ring needs a dcache invalidate on every poll; the 16-bit kick is the queue-index write. | Wishlist 18. |
| A3 | **EL0 audio seam + a melody app.** ADR 0007 slots 42+ (`sys_audio_play` / `sys_audio_info`, `implemented_count` 42→44): `copy_in` samples into the shared PCM ring — the shared-service model M14's clipboard/timers established (machine-global buffer, per-process safety via the S4 ownership discipline). A new userland image `JINGLE.BIN` plays a recognizable melody. Live gate: `verify-live-sound-app.sh`. Consuming experience: the melody from EL0. | ✅ | claim 7636, `verify-live-sound-app.sh` PASS 1/1 on VZ (2026-08-18): JINGLE.BIN execs from EL0, `sys_audio_info` reports the negotiated FLOAT(19)/48000(7)/stereo(2) state (first-call probe+SET_PARAMS — the app learns what to synthesize BEFORE any play), then plays all 14 notes of Twinkle Twinkle Little Star through `sys_audio_play` — each note's played accounting exact (96000 B per quarter, 192000 B per half at FLOAT/stereo/48 kHz), 382 total play calls (24 chunks/quarter, 47/half), `jingle: done`, exit 0; syscalls report `implemented=44` with `42 sys_audio_info calls=1` / `43 sys_audio_play calls=382`. **Finding:** app BSS lives in the W^X text page — a global `chunk_buf` faults on write from EL0; the chunk buffer is a STACK local instead (the pattern every other user program already uses). | Wishlist 18. |
| A4 | **Composition capstone.** Sound joins the desktop: a boot chime, and a sound fires on an existing event (window focus, a clipboard copy, or a timer tick) — audio composes with the M14 shared services. Live gate: `verify-live-m15-composition.sh` — one session proves device + playback + EL0 + the hearable composition, human-verified on VZ. | ✅ | claim 3206, `verify-live-m15-composition.sh` PASS 1/1 on VZ (2026-08-18): **boot chime** — the kernel plays a two-tone ding-dong (660 Hz 150 ms + 880 Hz 220 ms) through the A2 beep path the moment the transport is live (`chime: boot chime played (660+880)`), flag-gated on the device (default VM byte-identical, unarmed refusal host-tested); **event-triggered sound** — CHIME.BIN (27th ESP program) arms a one-tick M14 app timer (slot 40) and BLOCKS in `sys_wait_event`; every TIMER event (kind 9, ADR 0009) fires an 880 Hz blip through `sys_audio_play` (slots 42/43) — 3 ticks, each blip exactly 38400 B in 10 chunks, `chime: done`, exit 0; same-boot syscalls report `implemented=44`, `40 sys_timer_set calls=3`, `42 sys_audio_info calls=1`, `43 sys_audio_play calls=30`. The gate asserts device (DID 0x1059) + boot chime + EL0 info + per-tick accounting + lifecycle + syscall counts in ONE session; A1/A2/A3 gates re-ran green with the chime in the boot path. | Depends on A1+A2+A3. |

## Notes

- Zero heap allocation stays a hard constraint for every new kernel
  resource (fixed BSS tables only) — the M14 rule carried forward.
- A1 claim-time finding: VZ does not populate the virtio-snd device
  config (le32 jacks/streams/chmaps read 0/0/0 from pre- and post-exit
  paths, raw dump uniform zero) — stream topology in A2 is enumerated
  via the CONTROL-queue JACK_INFO/PCM_INFO queries, not the config
  counts.
- The host device is flag-gated (`--sound`); without it
  `config.audioDevices` stays empty (the SDK's actual member — the
  property is `audioDevices`, not `soundDevices`) and every existing
  gate stays byte-identical (the `--net`/`--input` precedent).
- ADR 0007 slots 42+ are the next free range (M14 ended at 41,
  `implemented_count` 42). Each ABI addition is a one-line ADR amendment
  with the exact error-code contract, per the existing pattern.
- Wishlist mapping: item 18 (audio). Items 13/14/15/17 remain M16+
  candidates; item 20 stays a distant mountain.
- Known unrelated threads: U4's pointer proof is class-C-only (issue
  #151, closed as a documented limitation); the synthesized-keyboard seam
  is session-dependent (claim 8844 diagnostic).
- When the milestone is picked up, file issues #A1–#A4 the way M14 filed
  #175–#178, and claim each card before writing code.

## Next action

**M15 is complete** — all four cards shipped (claims 6140/5877/7636/3206,
gates PASSED). The milestone ends where the roadmap said it would: a
**hearable** composition — the kernel's boot chime, and CHIME.BIN firing a
blip on every app-timer TIMER event from EL0, proven in ONE VZ session by
`verify-live-m15-composition.sh`. status.md carries the milestone-level
wrap-up; M16 candidates (wishlist 13/14/15/17) remain on the map.
