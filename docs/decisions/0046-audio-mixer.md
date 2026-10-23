# ADR 0046: Multi-source audio — a kernel mixer over the B7 stream, not a userland AUDIOD

- Date: 2026-10-13
- Status: **Accepted** — shipped by M99b (M99 closed, index #2178): the
  mixer is live (`kernel/src/pcm_playback.zig:25`); this ADR is the card
  (#2179), and the split below is the arc.
- Card: **#2179** (M99a of the M99 depth-pass index #2178). The follow-on
  implementation card is **#2180** (M99b); M99c (#2181) and M99d (#2182)
  consume the result.
- Related: ADR 0007 (syscall ABI — the slot-43 table amendment lands with
  M99b, deliberately not here), ADR 0016 (shared-anonymous mmap — the
  only existing cross-process data path), ADR 0043 (observability).

> M15 proved one virtio-snd output stream (#5877, B7 #1874): a single
> owning process opens slot 43 bit-63, submits 8 × 4096 B periods, and the
> kernel drives them to the device. The M99 depth pass asks who owns that
> stream when *several* processes want sound at once. Two architectures
> were on the table: **(a) a kernel mixer** — N per-source queues feeding
> one kernel-composed output stream — and **(b) an `AUDIOD.ELF`
> userland daemon** that owns B7 and mixes client deliveries in EL0.
> This ADR decides **(a)**, on measurements taken on real VZ
> (macOS 27.2 build 26B5101f, Apple silicon) — not on derived arithmetic.

## Grounding (observed in tree `4e6126d4`, 2026-10-13)

- **One live stream excludes everything else.** `snd_legacy_available()`
  is false while a stream lives; a second `snd_stream_open` and legacy
  slot-43 playback both observe `EAGAIN`
  (`kernel/src/virtio_snd.zig`, `kernel/src/syscall.zig:3001-3008`).
- **The pump never runs in IRQ.** `snd_stream_drive` is entered from
  stream syscalls (open/submit/start/end/abort/status on slot 43) and
  from `scheduler.maybe_report` → `snd_stream_poll`
  (`kernel/src/scheduler.zig:3466-3468`), i.e. every main-context idle /
  report pass. `Playback.drive` is bounded and nonblocking
  (`kernel/src/pcm_playback.zig`).
- **Ring shape.** 8 slots × 4096 B (`pcm_stream.zig`: `slot_count=8`,
  `period_bytes=4096`, `pcm_bytes=32768`). At the negotiated FLOAT32 /
  stereo / 48 kHz tuple a period is 512 frames — **[derived]** 10.67 ms
  per period, ≈ 85.3 ms of ring.
- **Sticky XRUN today.** An empty ring while running transitions the
  *whole stream* to `.xrun`, which only abort+reopen clears
  (`pcm_stream.zig`; asserted by `pcm_guest.zig` and the
  `live-sound-playback` spec).
- **Owner death is wired.** `snd_stream_owner_death` tears down the
  stream when its owning process exits.
- **Legacy playback serializes the device.** `handle_audio_play` holds
  `audio_lock` across copy-in + the full submit/drain loop —
  **[observed]** ≈ 170 ms (FLOAT32) to ≈ 340 ms (S16) for a 64 KiB blast
  — so a legacy blast already freezes the B7 poll path for its whole
  duration.
- **Cross-process data paths are thin.** The mailbox is 8 messages ×
  64 B per process (`mailbox.zig`); `sys_ipc_recv` is nonblocking and
  **`sys_ipc_send` does not wake the target** — no event push, no
  futex wake, nothing. `sys_futex` waits are keyed `(pid, uaddr)` —
  process-local, not a cross-process doorbell. `sys_sleep` /
  `sys_futex` timeouts quantize to the **1 s scheduler tick**
  (`syscall.zig:2272-2279` — "any sub-second timeout rounds UP to one
  tick"). ADR 0016's shared-anonymous mmap authorizes only the
  registered WM peer (one peer seat), not arbitrary client↔daemon
  rings. WM_RPC — the existing cross-process RPC shape — polls the
  mailbox on `sys_sleep` waits.
- **No format conversion in the stream path.** B7 demands the exact
  advertised tuple (S16 | S32 | FLOAT32, 48/96 kHz, 1–2 ch, output
  only); conversion is client-side by contract.
- **Completions prove accounting, not audibility.** There is no capture
  path anywhere in the project (hardware-contract, sound row); every
  number below is buffer/ownership evidence, never measured sound.

## Measurements (observed on VZ, instrumented scratch kernel)

Method, for the record and for reproduction: a scratch kernel build
added pump-gap counters to `snd_stream_drive` (gap between consecutive
drive entries on a live stream, split syscall-driven `sc` vs
poll-driven `mp`, max, mean, and a ms-edge histogram), and a scratch
guest (`kernel/tests/sndm99_guest.zig`, staged as `SNDM99.BIN`) ran
three pump-gap shapes and two IPC shapes under
`tools/gate/specs/m99a-probe.spec`, `--sound`, three full passes of the
spec. None of the instrumentation is part of the proposed change.

### M1. Pump gap with a user owner feeding B7

Gap between consecutive `snd_stream_drive` entries while a greedy
freestanding streamer owns the stream (submits whenever the ring has
room; FLOAT32/stereo/48 kHz):

| Shape (3 boots each) | drives | split sc/mp | mean gap | share <1 ms | gaps ≥85 ms | max gap | XRUNs |
|---|---|---|---|---|---|---|---|
| baseline, no load | 502k / 406k / 368k | ~72/28 | 24–32 µs | ≥ 99.97 % | 0–2 | **19 ms** on the xrun-free boot; 523–562 ms only on boots with 1 XRUN | 0–1 |
| GOTOP + WEB corpus render + GOSTRESS + spin child | 428k / 337k / 316k | ~71/29 | 36–48 µs | ≥ 99.99 % | 7 | 1002 ms | 8 / 8 / 8 |
| saturating: 3 extra spin processes | 218k / 304k / 174k | ~72/28 | 57–72 µs | ≥ 99.98 % | 1–6 | 1508–1524 ms | 5 / 5 / 5 |

Reading: **while the ring has work, the kernel pump is never the
bottleneck** — drive cadence sits at tens of microseconds, ≥ 99.97 % of
gaps are sub-millisecond, and the largest gap observed on a boot with
zero XRUNs was 19 ms (still under one ring of headroom). Every gap
≥ 500 ms coincides with an XRUN-dead window: the stream sat in `.xrun`
waiting for its *user owner* to notice, abort, reopen and prefill. The
user owner, not the kernel pump, is what starves — 8 XRUNs in ~19 s
under the desktop-shaped load, 5 under saturation, even 0–1 at
baseline. Per-submit syscall cost: p50 3.7–6.2 µs, p99 5–22 µs
(n = 2048/run).

### M2. Cross-process publish→submit latency (the AUDIOD data path)

A doorbell publisher sent 16 B `{cntpct, seq}` mailbox messages to a
busy-polling daemon process; on each receipt the daemon computed
publish→submit-decision latency and submitted one period. The daemon's
recv loop is the *best possible* userland shape — it does nothing else
(no sleep primitive exists that could pace a 10.67 ms period anyway):

| Shape | doorbells delivered | p50 | p99 | max | notes |
|---|---|---|---|---|---|
| idle (two boots) | 82 / 82 of 1200 attempted | 8 µs / 8 µs | **67.3 / 68.1 ms** | = p99 | publisher `ENOSPC` at seq 82 — the 8-deep mailbox filled during a ≥ 64 ms daemon scheduling stall |
| +2 spin processes (two boots) | 23 / 19 | 7 µs / 9 µs | **65.6 / 64.2 ms** | = p99 | `ENOSPC` at seq 23/19 |

While the daemon ran, the hop cost ~8 µs. But the daemon *stopped
running*: multi-10 ms and multi-60 ms scheduling stalls are routine for
a user process even on a near-idle boot, and at an 8 ms publish cadence
the depth-8 mailbox overruns inside one such stall. Downstream, the
daemon-owned stream XRUN'd 1–2× per ~10 s and pump gaps reached
2.0–3.0 s while the daemon's mailbox waited for a timeslice that wasn't
coming (syscall-driven pumps collapse to ~75–200 per run vs ~72–112k
poll drives — the sole producer simply wasn't there).

### M3. The budget

The card's gate: p99(pump gap + IPC) ≲ 40 ms — half the 85.3 ms ring
duration at FLOAT32/48 k/stereo.

- **Kernel mixer:** data path is the submitting syscall + the existing
  main-context pump; no cross-process hop. Combined p99 ≈ pump p99
  < 1 ms. **Pass by ~40×.**
- **AUDIOD.ELF:** combined p99 ≈ 64–68 ms, dominated by the
  cross-process scheduling hop. **Fails the budget** — and the failing
  term is not transport cost but timeslice starvation, which no
  mailbox/ring redesign inside EL0 can fix.

## Decisions

### D1. Architecture — DECIDED: a kernel mixer over the B7 stream

N bounded per-source queues live in the kernel; each source submits
periods through the existing slot-43 bit-63 stream ABI; when the device
frees an output period the kernel composes the next one from the source
queues and publishes it down the unchanged `Playback`/TX-descriptor
path. Ownership of the device never leaves the kernel.

`AUDIOD.ELF` is rejected — M2 measured the deciding number: a userland
single-owner pump sees p99 publish→submit ≈ 65–68 ms on this scheduler
under ordinary load, versus the ~40 ms budget, because (i) there is no
blocking cross-process wake anywhere in the syscall table (mailbox send
doesn't wake, recv doesn't block, futex is process-local, sleep/futex
quantize to 1 s), so the daemon must busy-poll a dedicated core just to
be *eligible*, and (ii) even eligible, it loses timeslices longer than
the entire 85 ms ring. A shared-anon ring (ADR 0016) would not fix it:
the transport is not the bottleneck — the consumer not being scheduled
is. Making a daemon viable would require a new kernel wake primitive
plus scheduling-latency guarantees — a strictly larger ABI and
scheduler change than the mixer itself, to land a worse property (one
EL0 process as the single point of starvation for *all* clients).

### D2. Clock and underrun semantics

The output clock is the **device completion clock**, as today: the
mixer composes exactly when a TX slot frees. Per freed slot, each
source with queued data contributes its oldest period; a source with
nothing queued contributes silence and its **per-source underrun
counter** increments. Silence is valid output — while ≥ 1 source is
open the stream runs continuously, so the whole-stream sticky `.xrun`
state is *removed* (M1 shows its only real function today is recording
owner starvation; in mixer mode starvation is per-source data). A
source that never submits contributes permanent silence; an all-idle
mixer streams zeroes — cheap, honest, and keeps the device clock
ticking for sources that resume.

### D3. Bounds and memory charging

Hard bounds: **4 sources**, **4 periods (16 KiB) per source** — 64 KiB
of payload plus bookkeeping. The memory is a **fixed kernel pool
allocated once on first mixer open via `alloc_pages` and retained for
reuse**, exactly the `stream_pages` model already used for the 32 KiB
playback pool ("one fixed pool charge on first open, retained for
reuse/quarantine" — `virtio_snd.zig:1246-1248`). No per-process audio
quota is introduced; the bound is the seat count, not a charging
question.

### D4. Mix math

Sources submit in the one negotiated device tuple (B7's exact-tuple
rule is unchanged — rate/channel conversion stays client-side). The
mixer works in FLOAT32: each source sample is widened to f32, scaled by
its **per-source gain**, and summed; the sum is clamped to [-1.0, 1.0]
and saturated back to the device format (S16/S32/FLOAT32). **Clipped
samples are counted** per mix window and surfaced through status.
Slots 44 (volume) and 45 (mute) keep their exact current meaning —
applied post-sum on the mixed output, the position they occupy on the
device-facing path today.

### D5. Legacy slot-43 playback under a live mixer

Legacy `(ptr, len ≤ 64 KiB)` playback returns **EAGAIN while ≥ 1 source
is open**, and behaves exactly as today when no source is open. It does
not become a mixer source: a legacy blast already holds `audio_lock`
for ≈ 170–340 ms — running one concurrently would freeze the mixer
pump for its whole duration, and registering each blast as a temporary
source buys a protocol for a fallback path that exists precisely for
"play a beep when nothing streams." The exclusion is one predicate in
`snd_legacy_available`'s place.

### D6. Errno vocabulary — no new codes

- source table full (5th open) → `ENOSPC` (-5)
- source queue full on submit → `EAGAIN` (-11)
- no device → `ENXIO`
- legacy play while sources open / stream-op misuse → `EAGAIN`; bad
  params → `EINVAL`

### D7. ABI implications

The slot-43 bit-63 opcode set (`open/submit/start/end/abort/status`) is
unchanged; the contract change is cardinality: "one live stream
excludes other opens" becomes "up to 4 concurrent sources," each owned
by its opener (owner death frees that source only —
`snd_stream_owner_death` becomes per-source). `StreamStatus` (72 B)
gains per-source underrun/clip reporting — either within its reserved
space or via a mixer status extension; the exact field allocation is
M99b's, recorded in its **ADR 0007 amendment**, which lands with the
implementation per the card split (not here).

## M99b card split (#2180)

- **b1 — kernel mixer core.** Source table (4 seats), per-source
  4-period queues in the fixed pool, compose-on-publish inside the B7
  drive path, per-source underrun + clip counters, sticky-`.xrun`
  removal for the multi-open model, D5 legacy exclusion, per-source
  owner death; `pcm_guest.zig` + `live-sound-playback.spec` updated for
  concurrent opens (the single-owner assertions this ADR deliberately
  changes), plus the ADR 0007 slot-43 amendment.
- **b2 — `vi.AudioStream` Go client.** `user/go/vi/audio.go` grows the
  stream ops (today it wraps legacy slots 42–45 only), plus client-side
  format/rate conversion to the negotiated tuple. M99c's WAV player is
  its first consumer.

## Consequences

- Multiple processes can hold live audio sources without an
  intermediary; a stalling or dying source glitches *itself* (counted
  silence), never the mix.
- The pump's real-time properties stay where they were proven (M1):
  kernel context, bounded, nonblocking, driven by syscalls and the
  existing main-context poll.
- The `.xrun` whole-stream state and the "one live stream" exclusion —
  load-bearing assertions in `pcm_guest.zig` and
  `live-sound-playback.spec` — change meaning; that is ABI change
  owned by M99b and its ADR 0007 amendment.
- Nothing here adds a syscall, a wake primitive, a daemon, or a shared
  ring; AUDIOD's prerequisites remain absent and are no longer needed.

## Risks and stop conditions

- **Mix cost in the drive path.** Composing 512 frames × ≤ 4 sources is
  ≤ 2048 f32 FMAs + saturate per period — trivially bounded, but it runs
  under `audio_lock`; b1 must keep the compose path allocation-free and
  bounded (it is, by construction).
- **Measurement scope.** M1/M2 are buffer-level measurements on one
  host (macOS 27.2, one VM shape). They decide *scheduling feasibility*,
  which is what the card asked; they say nothing about audible quality
  — still unobservable (no capture path), unchanged by this decision.
- **p99 interpretation.** M2's p99 is its max on modest n (82/19
  samples) — the honest claim is "stalls ≥ 64 ms occur routinely,"
  which is what ENOSPC-at-8-deep proves independently of the
  distribution shape.

## Rejected alternatives

- **`AUDIOD.ELF` userland mixer** — fails the measured budget (D1/M2):
  p99 publish→submit 64–68 ms > 40 ms; requires a blocking
  cross-process wake that does not exist; single point of starvation
  for all clients; burns a core busy-polling even in its best shape.
- **Shared-anon ring to a daemon** — ADR 0016's mechanism authorizes
  one WM peer seat only, and M2 shows the bottleneck is consumer
  scheduling, not transport: a faster doorbell does not wake an
  unscheduled daemon.
- **Sleep-polling daemon** — `sys_sleep`/futex timeouts quantize to the
  1 s tick; ~94× the period duration. Not a plan.
- **Legacy as a mixer source** — adds a register-blast-as-source
  protocol to keep alive a path that holds `audio_lock` ≈ 170–340 ms
  per call; EAGAIN exclusion is one predicate (D5).
- **IRQ-driven pump** — the project's "no audio control exchange from
  IRQ" invariant holds, and M1 shows it is not needed: main-context
  drive cadence is already ~2000× finer than the period.

## Observed vs inferred (AGENTS.md)

- **Observed** (VZ, macOS 27.2 build 26B5101f, `m99a-probe` ×3 spec
  passes): every number in M1/M2 — pump-gap distributions and maxima,
  XRUN counts, submit p50/p99, doorbell n/p50/p99/max, ENOSPC
  refusals, the 1 Hz sleep/futex quantum and non-waking mailbox (from
  the tree and prior cards), legacy blast durations from #2179.
- **Derived:** 512 frames/period, 10.67 ms/period, 85.3 ms ring at
  FLOAT32/48 k/stereo; the ~40 ms budget arithmetic; mix cost bound.
- **Inferred (design judgment):** 4 sources / 4 periods as the right
  bound; that tail gaps ≥ 500 ms are XRUN-recovery artifacts rather
  than pump failures (consistent with `.xrun` occupancy and the
  counters); per-source underrun as the right failure surface.
- **Not decided here:** `StreamStatus` field allocation, source-open
  generation encoding, the ADR 0007 amendment text — all M99b's.
