# ADR 0059: Warm-checkpoint legs — boot once, checkpoint before any workload, restore per leg, nothing crosses

- Date: 2026-10-18
- Status: **Accepted** — shipped by the M131 arc (#2637, closed;
  `tools/gate/fleet-census.py:2`, `tools/gate/SPEC.md:29,39`); this ADR
  is the card (#2638), and the M131 arc implemented it in the filed
  order: M131b the runner primitives (#2639), M131c the `live-quickjs`
  pilot (#2640), M131d the fleet census + sweep + budget row (#2641).
  (Number 0059 taken at write time; 0058 is provisionally held by M130a
  #2618 — unclaimed, but its filed card names that file.)
- Card: **#2638** (M131 index **#2637**) — card 1 of 4. This is the
  one doc for the arc (AGENTS.md: one doc per arc, not four).
- Related: ADR 0036 (VirtioFS — the only armed share a checkpoint may
  carry), ADR 0056 (the suspend/snapshot machinery and its amendment
  history — the same pause/save/stop seam card b extends), ADR 0057
  (the card-split convention this doc follows), `tools/gate/SPEC.md`
  (the frozen spec grammar the census reads and card b extends),
  `docs/hardware-contract.md` (the #2261 refusal contract and the
  M119e Code=12 bound — the two refusal modes this ADR legislates).

> Every `vgate_run` is a cold VM boot (~2–3 min) and the leg count is
> structurally fixed — boot-per-leg is the isolation guarantee. M115's
> suspend/restore machinery buys per-leg warm checkpoints — **boot
> once, checkpoint at a quiescent prompt before any leg's workload,
> restore that checkpoint per leg** — iff every leg resumes the same
> pre-workload state and nothing a leg mutates can reach a sibling.
> The hard constraint is VZ's, not ours: a configuration carrying any
> `VZCustomVirtioDevice` is unsaveable, so eligibility starts from the
> leg's device configuration and only then its semantics. The rest is
> discipline: what the bundle captures, which legs must stay cold, and
> how a restored guest gets armed without reprinting a prompt it never
> re-emits.

## Mission

Pin, before M131b writes the runner code: device-class eligibility
(static, decidable from spec text), config identity (which flags a
warm leg may vary), the bundle contents (what a checkpoint does and
cannot capture), the checkpoint point (a dedicated base boot, never
another leg's residue), the post-restore arming handshake, the serial
epoch, the ineligible semantic classes named with their reasons and
concrete specs, the two-refusal-mode honesty contract, and the
file-level Touches for M131b–d so those cards land without
renegotiation.

## Grounding (observed in tree `093494c2` and on this host, 2026-10-18)

**[observed]** means checked in the tree or the live record;
**[inferred]** means reasoning only.

1. **Boot-per-leg is the whole isolation model today.** `vgate.sh`
   runs each `vgate_run` as one fresh `VMRunner` process and one cold
   boot, deleting `efi-vars.bin` and `vm-serial-<tag>.log` per run; a
   leg's serial file, runner stdout, and armed share are the evidence.
   ~2–3 min per leg; the fleet is 959 legs across 308 specs at this
   tree (Grounding 11). **[observed]**
2. **The save/restore seam already exists and is honest.**
   `--vz-restore` drives pause → `saveMachineStateTo` → stop →
   `restoreMachineStateFrom` → resume; `--vz-restore-save`/`-load`
   prove the cross-process cycle by parking `state.vzsave` +
   `overlay.asif` + `marker.txt` + `machine-id.bin` in one directory
   a second process restores from without booting (`live-vz-restore`,
   `VZRestoreProbe.swift`). **[observed]**
3. **The refusal contract is a device property.** Any
   `VZCustomVirtioDevice` in the configuration refuses at
   `validateSaveRestoreSupport` with `VZErrorDomain` Code=2
   ("Unsupported custom virtio device in configuration"), before any
   boot. VZ offers no device-detach, quiesce, or partial-state API —
   the configuration is immutable. **[observed]** #2261,
   hardware-contract.
4. **The flag set that arms a custom-virtio device is enumerable**
   (main.swift's parse): `--custom-virtio`, `--cvc-echo`,
   `--via-virtio`, `--pointer-virtio` (implies via-virtio),
   `--cvc-snap` (implies via-virtio), `--cvc-file` (implies
   snap+via+echo), `--cvc-console-file`, `--snapshot-after` (implies
   `--cvc-snap`); `--gpu3d-metal` is a second `VZCustomVirtioDevice`
   (the M102 VIR1 render device). Spec-side, `vgate_share arm|seed`
   is harness-armed into `--cvc-file`; `arm-virtiofs|seed-virtiofs`
   arms `--virtio-fs`. The `--host-*` lane modifiers
   (`--host-clipboard`, `--host-drop`, `--host-notify`,
   `--host-outbox`, `--host-capture-keys`) require `--cvc-file`, so
   they can never appear on a clean leg. **[observed]**
5. **Saveable verdicts are measured.** `VZVirtioFileSystemDevice`
   (`--virtio-fs`, M83g — full cross-process cycle, guest FUSE I/O
   after restore), `VZVirtioSocketDevice` (`--vsock`, M115a —
   save passes; the restore leg is bounded by the host, Grounding 6),
   virtio-gpu (`--display`), usb-hid (`--input`) — all full-cycle
   PASS on the recorded host. `--usb-msd` is mixed: save always
   passes; restore went 8/9, then saturated to total refusal under
   M119e. **Unmeasured** for save/restore: the `--net` file-handle
   attachment, `--net-nat`, `--net-bridged`, `--net-vmnet`,
   `--sound`, `--data-disk`. **[observed]**
6. **The runtime refusal bound is persistent, not flappy.** M119e
   (#2489) drove 600+ `restoreMachineStateFrom` calls on this host
   build (26B5112a): every call refused `VZErrorDomain` Code=12, 0
   passes — image-independent, device-independent, aggravated by
   concurrent VZ load (#2261's 5-of-5), not a runner regression (the
   071eef6b-era binary refuses identically). The reason string varies
   ("invalid argument", "permission denied"); Code=12 is the stable
   signature. A retry would only mask it. **[observed]**
7. **The serial-epoch machinery exists.** `VZRestoreProbe` marks
   `serialOffset` at restore and matches only bytes after it — a
   leg's "serial log" as a bounded epoch is already how the probe
   decides PASS. **[observed]**
8. **Post-restore input has a precedent.** After resume the probe
   writes `clip\n` directly into the serial input attachment and the
   guest answers on the serial log — no prompt needed. The shell's
   idle marker is the `virelai> ` prompt (`--input-string` defaults
   its `-after` to the first prompt; `serial-echo` accepts a
   colored-or-plain prompt echo). Script arming is host-side:
   `forwardScriptOnce` polls the serial *log file* for the `-after`
   marker, then writes the script bytes into `consoleInputPipe` —
   arm/expect state lives in the runner process, never in the guest.
   **[observed]**
9. **The bundle must pin two host-side files.** The platform
   `machineIdentifier` must match the saved VM's (SDK-documented);
   `--vz-restore-load` already adopts `machine-id.bin`. The EFI
   variable store must be the same file the save ran against —
   #2261's measurement reused it deliberately; a mismatched store was
   never tried but `restoreMachineStateFrom` refuses `Code=12
   "invalid argument"` on configuration mismatches. **[observed]**
   SDK contract; **[inferred]** the vars match is required.
10. **Host-side state the restore cannot capture is enumerable.**
    `--console-tcp` bridges a live socket into the serial input;
    `--net-*` responders and the `:relay` upstream are capture-thread
    state machines with per-connection dedup/window state;
    `vgate_client` hooks are separate processes; the serial capture
    file is the runner's own artifact; TCC/consent grants
    (`--pointer-request-trust`, Screen Recording) are per-host
    permissions; `--host-outbox-dir` (default `~/Downloads`) and
    `--profile` bundles mutate host state outside any share.
    **[observed]**
11. **The census is mechanical.** Applying D1's rule to this tree
    (joining `\`-continued `vgate_run` lines; spec share `arm|seed`
    ineligible; the Grounding-4 flag set per leg; the one
    parameterized share `${GOSTALGIA_FILES_SHARE:-seed}` resolved to
    its default): **308 specs / 959 legs; 252 specs carry at least
    one custom-virtio leg or a custom-virtio share; 56 device-clean
    specs hold 163 device-clean legs; all 42 `live-web` legs sit
    under `vgate_share seed`.** Re-run at the card's census commit
    `c85d4d6b` the same procedure gives 252 ineligible specs / 56
    clean / 956 legs / 163 clean legs / live-web 40, against the
    card's stated 253 / 55 / 958 / 135. The deltas are recorded, not
    smoothed: the 28-leg gap is exactly the restore-test specs this
    ADR's D7(b) excludes (`live-vz-restore` 14 + `live-suspend-resume`
    7 + `live-persistence` 7), consistent with the card having
    pre-folded them; the one-spec and two-leg deltas are unexplained
    drift the mechanical rule does not reproduce — M131d's computed
    census in `fleet.sh` is the arbiter, and its spec-order/locale
    invariance is what makes the number honest. **[observed]**

## Decision

### D1. Eligibility by device class is static and decidable from spec text

A leg is **device-ineligible** iff either holds, read off the spec
without booting anything:

- its spec declares `vgate_share arm` or `vgate_share seed`
  (harness-armed `--cvc-file`); or
- its `vgate_run` flag vector carries any of the Grounding-4 set:
  `--custom-virtio`, `--cvc-echo`, `--via-virtio`,
  `--pointer-virtio`, `--cvc-snap`, `--cvc-file`,
  `--cvc-console-file`, `--snapshot-after`, `--gpu3d-metal`.

The verdict is monotone in spec text: a configuration either arms a
`VZCustomVirtioDevice` or it doesn't, and Code=2 never needs a boot
to decide it. Device-*clean* flags carry the measured verdicts:
`--virtio-fs` and the `*-virtiofs` share modes (M83g), `--vsock`
(M115a), `--display`, `--input`. `--usb-msd` is device-eligible but
D7(e) removes it on semantic grounds anyway.

**Unmeasured classes** — `--net`, `--net-nat`, `--net-bridged`,
`--net-vmnet`, `--sound`, `--data-disk` — are tentatively eligible.
The base boot's own `validateSaveRestoreSupport` resolves them once
per config group: a Code=2 there classifies the *group* ineligible
for the run (the refusal is persistent; no retry), and the verdict
is recorded into `docs/hardware-contract.md` when observed. That is
the only runtime component of eligibility, and it lives on the base
boot, never on a leg.

### D2. Config identity holds by construction

A checkpoint is owned by a **`vgate_checkpoint <tag>`** base boot
that carries the full device/attachment flag shape. A
**`vgate_run <leg> --from-checkpoint <tag>`** leg *inherits* that
shape: a device flag on a warm leg is a spec-load error, so every
leg resumed from one checkpoint shares its configuration because it
cannot express another. The leg may vary only script payloads,
arming markers, expects/delays, and timeout — asserts are
harness-side declarations, not runner flags.

Non-device flags still belong to the shape where they name state the
restored guest was formed against: `--net*` capture/responder/
listener identity, `--profile`, share mode and directory, `--vars`.
A spec whose legs differ in those partitions into separate
checkpoints — each group gets its own base boot — or the divergent
legs stay cold. In particular a different net responder set means a
different checkpoint: the restored guest's ARP entries, socket
state, and leases were formed against *that* peer.

### D3. What a checkpoint captures — the bundle, taken under one pause

Taken once, with the VM paused, so the pieces are mutually coherent:

| Member | Contents |
|---|---|
| `state.vzsave` | guest RAM, vCPU registers, device state — `saveMachineStateTo` |
| `overlay.asif` | the run's ASIF layer over the read-only `--overlay-base` — **cloned per leg** |
| `efi-vars.bin` | pinned copy of the EFI variable store the save ran against (vgate deletes it per run — the bundle must own its bytes) |
| `machine-id.bin` | platform `machineIdentifier`, adopted verbatim by every restoring process |
| `share/` | the armed VirtioFS share as of checkpoint time — **cloned per leg** |

The overlay/share clone rule is the isolation guarantee: guest RAM
holds filesystem and page-cache state coherent with the disk *as the
guest last saw it*. Restoring RAM against a fresh overlay, or one a
sibling leg already wrote through, pairs a guest that believes it
wrote (or read) blocks the disk image denies — incoherent, and the
incoherence is silent until it isn't. A leg's writes land only in
its own clones; the bundle is immutable once taken.

The bundle **cannot** capture, and no leg may depend on: host
listener/relay state (`--console-tcp` bridge sockets, `--net-*`
responder state machines and `:relay` upstream connections), the
serial capture file itself, script arm/expect machinery, TCC/consent
grants, host outbox dirs, `vgate_client` processes, or the host wall
clock.

### D4. The checkpoint is taken by a dedicated base boot, before any leg's workload

`vgate_checkpoint <tag>` boots cold with the group's device flags,
drives the guest to a quiescent `virelai> ` prompt (the same
boot-settle point `--script-after` markers wait on today), then
pause → save → persist the bundle → stop → exit. It runs no leg
workload and carries no asserts; its serial log is evidence, not a
leg. **A leg never resumes another leg's post-workload state** — the
index's thesis, and the exact behavior card b implements. Resuming a
leg from a sibling's residue is not a supported mode, not a flag,
not a fallback.

### D5. Post-restore arming: the handshake replaces the boot-settle marker

A restored guest reprints nothing — the boot banner, `kern:`
receipts, and the first `virelai> ` all predate the checkpoint and
will never re-emit. After `restoreMachineStateFrom` → resume, the
runner:

1. marks the serial-epoch boundary (Grounding 7's `serialOffset`);
2. writes `\n` into the serial input attachment (Grounding 8's
   precedent);
3. waits for a fresh `virelai> ` echo **inside the epoch** — the
   guest proving its shell is idle;
4. only then forwards `--script`.

The leg's first `--script-after` is **re-based** onto this
handshake: its role in the cold run is "the guest is seated and
idle," which is exactly the state the checkpoint pinned, so the
warm-leg receipt names the re-base rather than pretending the marker
fired. Nothing is ever typed into a guest that has not proven idle —
if the fresh prompt never arrives the leg fails by runner error, not
by keystrokes landing in a busy console.

Later `--scriptN-after` markers are *not* re-based: they gate on the
leg's own workload progress (e.g. `tasks user-exec reaped` follows
the leg's own exec) and must re-occur inside the leg's epoch. A leg
whose later arming marker can only fire during boot is ineligible —
it would deadlock against a log that can never produce it.

### D6. Serial epoch: a leg sees only its own bytes

A warm leg's `vm-serial-<tag>.log` holds only guest output emitted
after its own restore. Base-boot lines — the kernel banner, `kern:`
receipts, boot markers — are invisible to every warm leg's serial-*
asserts. This is deliberate and double-edged:

- **Marker discipline.** Asserts and expects are unchanged between
  cold and warm runs — a leg converted to warm must emit the same
  evidence. A serial assert that names a base-boot line *fails
  honestly* under the epoch, which is why boot-marker legs are
  D7(a)-ineligible rather than silently re-targeted or padded with
  replayed bytes.
- **Guest-side replay is in scope, and honest.** `dmesg`, the
  console tee, and any guest-resident log ring read guest *memory*,
  which the checkpoint legitimately preserves. A warm leg that runs
  `dmesg` sees real pre-checkpoint history — that is not leakage;
  it is the guest truthfully reporting its own past. Asserts that
  reach boot history through guest replay (`live-dmesg`'s shape)
  behave exactly as they do cold.

### D7. Ineligible semantic classes — named, with reasons and specs

Device-clean legs in these classes stay cold. The census reports
each class separately:

| Class | Reason | Named legs/specs |
|---|---|---|
| (a) Cold-boot markers / boot order | the epoch hides them (D6) | `live-boot-order`; any leg asserting `VirelaiOS kernel has seized control.` or `kern:` boot receipts |
| (b) Restore/suspend/reboot tests | the leg *is* the boundary being measured | `live-vz-restore`, `live-vsock-restore`, `live-suspend-resume`, `live-persistence`, `live-reboot`; `live-os-update`'s reboot legs |
| (c) Host listeners, relays, clients | host-side state outside the bundle; cross-boundary semantics unproven | `--console-tcp` legs (`live-console-tcp`, `live-remote-console`, `live-supervise`; `live-quickjs`'s `repl session evals diagnostics receipt eof`); `--net-tcp-respond-relay` legs; every `vgate_client` leg |
| (d) Elapsed/budget timings across the boundary | guest clock and timers jump across the freeze; a budget formed pre-checkpoint is uninterpretable post-restore | `live-timer`, `live-time`, `live-net-dhcp-renew`, `live-net-tcp-rto`; `live-quickjs`'s `cold` (cold-start sampling) |
| (e) Mutating host state outside the cloned share | the mutation is unreachable by the checkpoint | `--usb-msd` host-file writes (also the mixed verdict); `--host-outbox*` exports; `--host-cmd-after` host verbs; `--profile` bundle mutation |
| (f) Sibling-leg dependence | nothing crosses legs; a leg expecting a prior leg's side effects can never see them | setup→work leg pairs; save→load pairings (already (b)); spec-internal sequencing where leg *n* reads leg *n−1*'s output |

The honest overlap: several (c)/(e) legs are device-ineligible
already (`--host-*` requires `--cvc-file`), and the restore specs in
(b) account for most of the card-vs-rule census delta (Grounding 11).
The classes still get named — eligibility is the conjunction of D1
*and* D7, and a spec that future device work makes saveable (the
live-web arc) still has to clear the semantic classes leg by leg.

### D8. Fallback and honesty — two refusal modes, two rules

- **Code=2 is decided statically.** A leg whose flags arm a
  custom-virtio device is classified ineligible at spec load/census
  and *never attempts warm* — no probe, no retry. Receipt:
  `warm=cold`.
- **A runtime restore refusal degrades, once.** On any
  `restoreMachineStateFrom` refusal (the Code=12 bound is today's
  observed shape) the *same leg* cold-boots once with the same
  script and asserts; the receipt records `warm=fallback(<code>)`.
  **No retry loops** — M119e measured the refusal as persistent, and
  a retry can only mask it (Grounding 6).
- **Ordinary specs never refuse.** A warm-adopted leg produces
  byte-for-byte the same assertions either path took; the only
  difference is the receipt field and the wall clock.
- **A spec whose purpose is the warm proof pins `warm=restored`.**
  `vgate-warm-smoke`'s w1/w2 legs and `live-vz-restore`'s legs are
  this shape: a refusal reports FAIL, honestly, rather than passing
  cold (the "reports the refusal honestly rather than masking it"
  precedent).

Every warm-adopted leg's report carries one field —
`warm=restored | fallback(<VZErrorDomain code>) | cold` — and the
fleet census (M131d) reads exactly that vocabulary.

### D9. Ordering and process model

Per spec, per config group: classify legs (D1, D7) → one base boot
(D4) → legs restore **sequentially, in spec order**, each in a fresh
`VMRunner` process (the `--vz-restore-load` precedent) assembled
from cloned overlay + cloned share + pinned vars + adopted
machine-id → handshake (D5) → scripts → asserts over the leg-epoch
serial → teardown. Restores are never parallel — concurrent VZ load
is the observed Code=12 aggravator, and sequential legs keep
host-side port/fd state per-leg anyway. The bundle lives under
`$RUN_DIR` and dies with it; `vgate_repeat` re-restores per
iteration. Card b extends the existing restore seam — it does not
build a third one.

## Non-goals (explicit)

| Non-goal | Where it stands |
|---|---|
| `live-web` warm legs | All 42 legs carry custom-virtio; going warm needs VirtioFS `/host` *and* a saveable scanout-capture/input path — a later saveable-evidence arc, no card filed |
| Chained checkpoints (leg *n* resumes leg *n−1*'s state) | D4 forbids it — residue is the leak this arc exists to remove |
| Cross-spec or cross-run checkpoints | A bundle is one spec's, one `$RUN_DIR`'s, one host-build's |
| Parallel restores | D9 — the Code=12 correlator is concurrent VZ load |
| Relaxing a D7 class | Only with evidence; the class stays closed until a card reopens it |
| Spec-declared eligibility (`vgate_warm on`) | Rejected — eligibility is *computed* (D1+D7); a declaration can lie |
| Changing the boot default or the spec grammar | `vgate_checkpoint`/`--from-checkpoint` are the only additions (card b); every existing spec is byte-identical |
| Cross-host / cross-version saved-state portability | Unmeasured (hardware-contract: "not a promise"); a bundle is single-host, single-build |
| Guest-visible suspend/resume UX | M115d/e's profile path is unchanged and orthogonal |

## Card split — file-level Touches

Lanes are `a → b → c → d` (the index; d consumes b and c's numbers).

| Card | Issue | Delivers | Touches |
|------|-------|----------|---------|
| M131b | #2639 | `vgate_checkpoint` + `vgate_run --from-checkpoint` verbs, bundle capture + per-leg clones, the D5 handshake, the `warm=` receipt, `vgate-warm-smoke` (w1/w2 nonce isolation + epoch absence, f1 forced-truncation fallback), SPEC.md verbs, offline coverage | `tools/gate/vgate.sh`, `tools/lib/gate-run.sh`, `tools/gate/SPEC.md`, `tools/gate/test-gate-run.sh`, `host/vm-runner/Sources/VMRunner/main.swift`, `host/vm-runner/Sources/VMRunner/VZRestoreProbe.swift`, `tools/gate/specs/vgate-warm-smoke.spec` |
| M131c | #2640 | `live-quickjs` pilot: 16 script-only legs warm from one checkpoint, marker-set parity comparator vs cold, measured cold-vs-warm wall-clock | `tools/gate/specs/live-quickjs.spec` (+ the comparator wherever card b's spec grammar puts it) |
| M131d | #2641 | `fleet.sh` census line (total / device-ineligible / semantic-ineligible / adopted), adoption sweep, fleet cold-vs-warm row in hardware-contract capacity bounds | `tools/gate/fleet.sh`, `docs/hardware-contract.md`, then the concrete specs the census names — Touches narrowed at claim time per the card |

## Consequences

- **Isolation is preserved by construction, not by trust.** A leg's
  entire writable world — RAM, disk view, share, NVRAM — is a fresh
  clone of the pre-workload checkpoint; there is no channel by which
  leg *n−1*'s residue reaches leg *n*. Boot-per-leg's guarantee kept,
  its cost amortized.
- **Warm never changes evidence, only cost.** Asserts, markers,
  serial files and receipts are identical-shape either path; card c's
  marker-set parity is the measured proof, not a hope.
- **A refusing host cannot counterfeit a green warm run.** Specs
  pinning `warm=restored` FAIL on refusal; ordinary specs degrade to
  cold and say so. The `warm=` field makes the fleet's true warm
  coverage auditable from the report alone.
- **The ceiling is honest.** ~163 device-clean legs at this tree
  minus the D7 classes; live-web stays cold until the later
  saveable-evidence arc. The census reports the ceiling it measures,
  never the one it wants.
- **The base boot's validate verdict doubles as measurement.** D1's
  unmeasured classes become observed hardware-contract rows the first
  time a group tries them.

## Rejected alternatives

- **Chained / post-workload checkpoints.** Resuming leg *n* from leg
  *n−1*'s residue makes evidence order-dependent and leaks every
  writable surface; D4 forbids it outright.
- **One shared overlay/share across warm legs.** RAM-vs-disk
  incoherence plus direct sibling leakage — the clone rule is the
  isolation (D3).
- **Retrying Code=12.** M119e: persistent, not flappable; a retry
  only masks it.
- **Appending the base boot's serial into each leg's log.** It would
  let boot-marker asserts pass, but it fabricates bytes the leg's VM
  never emitted and breaks `serial-exact`/`serial-count` — the epoch
  is the honest boundary.
- **Re-arming verbatim on the original `--script-after`.** Boot-settle
  markers cannot re-fire post-restore; the leg would deadlock. D5
  re-bases the first marker instead.
- **One runner process restoring repeatedly.** Possible, but per-leg
  processes keep listeners, serial fds and arm/expect state per-leg
  for free, and match the proven `--vz-restore-load` shape (D9).
- **Spec-declared opt-in.** A `vgate_warm` declaration can assert
  eligibility a leg doesn't have; computed eligibility cannot lie
  and needs no grammar change to audit.

## Open issues

- **The unmeasured attachment classes** (D1: `--net*` attachments,
  `--sound`, `--data-disk`) — resolved by each group's base-boot
  `validateSaveRestoreSupport`; the first observed verdict becomes a
  hardware-contract row.
- **Guest time across the freeze.** What the restored RTC/monotonic
  clock does is unmeasured; D7(d) is the conservative posture until
  a leg observes it.
- **`--net` responder state vs restored guest net state.** A guest
  restored mid-lease against a fresh responder set is unproven —
  hence D2's responder-identity rule; whether that set is
  checkpoint-shaped or leg-varying is card b's measurement.
- **live-web eligibility.** The saveable-evidence arc (VirtioFS
  `/host` + saveable scanout/input) is recorded on the index; no
  card is filed.

## Acceptance

- ADR merged with owner sign-off; M131b–d cite its decisions (D1–D9,
  the `warm=` vocabulary, the named classes) without reopening them.
- D1's static rule reproduces the spec census mechanically — the
  procedure in Grounding 11 rerun against the tree, with deltas
  recorded rather than smoothed — and D7's classes each name at
  least one concrete spec or flag set.
- Arc acceptance per the index: fleet wall-clock measured
  before/after on a host where `live-vz-restore` headless-base
  passes; the warm path lands only where leg evidence is unchanged
  (card c's marker-set parity); every adopted leg's receipt states
  `warm=restored | fallback(<code>) | cold`.
