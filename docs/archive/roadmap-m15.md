# Roadmap archive — Milestone fifteen — audio

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

### Milestone fifteen — audio (**COMPLETE 2026-08-18**; wishlist 18)

> With events, files, GUI apps, the launcher, and the shared-services arc
> shipped, the next concrete wishlist item is **audio** — "another real
> device/service pipeline", the "DipshitOS becomes a computer" list. The
> host side exists (`VZVirtioSoundDeviceConfiguration`, virtio-snd, macOS
> 13+), so this is greenfield guest work: virtio-snd transport (A1) → a
> bounded PCM playback buffer + `beep` (A2) → an EL0 audio seam (ADR 0007
> slots 42+) + a `JINGLE.BIN` melody app (A3) → a hearable composition
> capstone (A4, boot chime + event-triggered sound). Flag-gated `--sound`
> keeps the default VM byte-identical. Deferred alternatives (items
> 13/14/15/17) remain M16+ candidates.

> **A1 shipped 2026-08-18 (claim 6140):** host `--sound` mode + the guest
> virtio-snd transport, live-gated on VZ (`verify-live-sound-device.sh`
> PASS 1/1). Observed: DID **0x1059** (the 0x1040+25 prediction held),
> class 0x040100, DRIVER_OK, control queue armed, device NOT reset by VZ
> (like net/gpu). Finding: VZ does not populate the le32 config counts
> (0/0/0 — stream topology is enumerated by asking).
>
> **A2 shipped 2026-08-18 (claim 5877):** the PCM playback path —
> `verify-live-sound-playback.sh` PASS 1/1 on VZ. PCM_INFO(0) advertises
> S16\|S32\|FLOAT @ 48000\|96000 ch 1..2 OUTPUT; FLOAT/48000/stereo
> negotiated; SET_PARAMS+PREPARE+START+STOP+RELEASE all S_OK; a 300 ms
> beep = 115200 B submitted in 4096-B periods, **all drained** by the
> device (pcm_status 0x8000). Protocol pinned by observation: VZ speaks
> the virtio-1.3 control codes (OK=0x8000, not 0) and writes control
> replies **[status hdr][entries]** (status first — the Linux driver
> reads it last).
>
> **A3 shipped 2026-08-18 (claim 7636):** the EL0 audio seam — ADR 0007
> slots 42/43 (`sys_audio_info`/`sys_audio_play`, `implemented_count`
> 42→44), live-gated on VZ (`verify-live-sound-app.sh` PASS 1/1).
> JINGLE.BIN (the 26th ESP program) execs from EL0, learns the negotiated
> FLOAT/48000/stereo state via `sys_audio_info` (first-call probe +
> SET_PARAMS — the app knows what to synthesize before any play), then
> plays all 14 notes of Twinkle Twinkle Little Star via `sys_audio_play`:
> per-note accounting exact (96000 B quarters / 192000 B halves at
> FLOAT/stereo/48 kHz), 382 play calls in bounded 4 KiB chunks, exit 0.
> Finding: app writable data must be a STACK local (a global BSS buffer
> faults on write — the W^X text page).
>
> **A4 shipped 2026-08-18 (claim 3206) — milestone fifteen COMPLETE:**
> the composition capstone, live-gated on VZ
> (`verify-live-m15-composition.sh` PASS 1/1). **Boot chime:** the kernel
> plays a two-tone ding-dong (660 Hz 150 ms + 880 Hz 220 ms) through the
> A2 beep path the moment the sound transport is live — flag-gated on the
> device (the default VM stays byte-identical; the unarmed refusal is
> host-tested). **Event-triggered sound:** CHIME.BIN (the 27th ESP
> program) arms a one-tick M14 app timer (slot 40) and BLOCKS in
> `sys_wait_event`; every TIMER event (kind 9) fires an 880 Hz blip
> through `sys_audio_play` (slots 42/43) — 3 ticks, each blip exactly
> 38400 B in 10 chunks, `chime: done`, exit 0, and the same-boot syscalls
> report shows `implemented=44` with `40 sys_timer_set calls=3` / `42
> sys_audio_info calls=1` / `43 sys_audio_play calls=30`. The gate asserts
> device + boot chime + EL0 info + per-tick accounting + lifecycle +
> syscall counts in ONE session — the milestone's "hearable" composition
> test. A1/A2/A3 gates re-ran green with the chime in the boot path.

See [`march-m15.md`](march-m15.md) for the card tracker.
