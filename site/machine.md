---
title: The machine
status: published
tags: [machine, lifecycle, profiles, persistence]
---

# The machine

A VirelaiOS guest is not just a boot — it is a *machine* with a lifetime.
It owns a bundle on disk, knows how to freeze and resume itself, parks
named snapshots on its own share, and can verify, apply, and roll back a
signed OS update without a single host-side rebuild. This page is the
lifecycle story; [[run]] is the flag reference, [[host-int]] covers the
host-side window and integration lanes, and [[remote]] covers how you
reach a running machine.

The host side of all of this is the Swift runner
(`host/vm-runner`) plus the bundled session app that `just session`
produces. The guest side is the kernel monitor, GOSH's builtins, and a
small set of Go tools (`GOSNAP.ELF`, `GOUPD.ELF`, `GOSET.ELF`,
`GOTOP.ELF`).

## The `.virelaivm` profile bundle

Everything a machine owns lives in one directory, the `.virelaivm`
profile bundle. `--profile <path>` boots from it: an absent path is
*minted* (the bundle is created on the spot), and an existing path must
carry a readable `virelaivm/1` manifest or the run refuses by name.
`--profile-init` performs the mint-and-validate step alone and exits —
`tools/session.sh` runs it before seeding a fresh share.

The bundle is a directory the machine owns for its whole life:

| Member | What it holds |
|--------|---------------|
| `manifest.json` | The format tag (`virelaivm/1`), the identity key, and the member map — the load-time gate; a corrupt manifest or a member that escapes the bundle refuses by name |
| `config.json` | The machine shape: `cpus`, `memoryMiB`, the boot `baseImage`, an `updatePubkey` trust pin, a window-`closeAction` policy, and the `devices` map |
| `efi-vars.bin` | The EFI variable store |
| `overlay.asif` | The *persistent* ASIF overlay over the read-only base image — not the throwaway layer a bare `--overlay-base` run mints |
| `vlfs.img` | The VLFS data disk (the `--data-disk` member) |
| `machine-id.bin` | The `VZGenericMachineIdentifier` data — one machine keeps one identifier across processes |
| `saved-state/` | The VZ saved-state directory (`state.vzsave`) that `suspend` writes and `--resume` reads |
| `share/` | The host file-channel share (`--cvc-file` / `--virtio-fs` member) |

Profile members are *defaults*. An explicit `--vars`, `--overlay-base`,
`--data-disk`, `--cvc-file`, or `--cpus` flag wins over the bundle
regardless of argument order — a profile is a shape, not a straitjacket.

The `devices` map deserves a word. Most devices default **off** so a
profile never silently widens its VM shape; the two that default **on**
are `share` and `dataDisk`, the bundle's own members. A profile whose
`devices.share` is flipped off boots with no share transport armed, and
each leg carries its channel by flag — which is exactly how the
save-capable legs below ride `--virtio-fs`.

### Finder documents and the session front door

A `.virelaivm` bundle is a *Finder document*. The packaged session app
registers the document type, so double-clicking a bundle launches the
app, mints or validates the bundle through the same `--profile`
resolution a flag boot uses, and opens the session front door
(`--display --input --host-session`, no deadline, serial log inside the
bundle's `run/`). A corrupt bundle refuses in the session window itself,
not on a stderr nobody can see.

`just session` is the same front door from a checkout: it builds the
guest, image, and runner, seeds the persistent share, and opens the Go
seat's first-boot workspace. `just session --save-capable` rides
virtio-fs so suspend and snapshot are armed; `just session --resume`
continues a suspended machine.

### Machine settings and the profile manager

Inside a running session, **⌘,** opens the machine settings panel. It
edits the armed bundle's `config.json` — `cpus`, `memoryMiB`, and the
`devices` toggles — as *next-restart* values: the running VM is not
reconfigured underneath you. The verb dispatches on the `HostCommand`
bus like every menu item, and receipts `disabled` when no profile is
armed, so a flag-run's Machine Settings simply greys out.

The Machine menu's profile manager rides the same bus with four verbs:
`profile-new` mints a sibling bundle (`untitled`, `untitled-2`, …) in
the profiles directory; `profile-clone` clones the armed bundle — config
plus a recursive `share/` copy over a fresh overlay; `profile-reset-overlay`
deletes `overlay.asif` so the next boot re-mints it over the read-only
base (the wedged-boot safety net); and `profile-switch` swaps which
sibling bundle lives at the armed path, then asks the running session to
stop. Destructive verbs while the VM runs demand a confirmation the
headless dispatch declines by default — `confirm=declined` is the
fail-closed receipt.

Read-side, `profile-info` is a ctl-channel verb that answers the armed
profile's name, boot base, whether a `.prev` rollback image exists, and
the snapshot count — rendered read-only in GOSET's Profile tab and as a
one-line summary in GOTOP.

<Aside kind="info">

**LIVE-GATED.** The full workstation journey — mint → settings → clone →
reset overlay → `share/` survives → new CPU/RAM live on a session-minted
bundle — is the `live-workstation-profiles` spec, K=3.

</Aside>

## Suspend and resume

A running machine can freeze itself — from inside. GOSH's `suspend`
builtin (or the seat's PWR-menu Suspend row, or the monitor's
`vsock ctl suspend`) asks the host to save the whole VM. The request
travels the `virelai-ctl/1` channel — an HMAC-challenged JSON-Lines
control wire over virtio-vsock that ADR 0056 pins (see [[host-int]] for
the wire itself) — and the verb sequence is:

1. The guest *quiesces*: the VLFS journal fsyncs, settings re-save, and
   a `SUSPEND.MARK` request receipt lands on the share.
2. The host pauses the VM and calls `saveMachineStateTo`, writing the
   profile's `saved-state/state.vzsave`.
3. The `ok:true` reply is written **while the guest is still frozen** —
   the resumed machine's first post-restore read is its own answer —
   then the host stops and exits.

`--resume <profile>` boots the bundle, restores `state.vzsave`, and the
machine continues mid-syscall: the builtin prints `suspend: ok`, and
every byte of session state — environment, clipboard, files on both the
`/host` share and the journaled `/disk` volume — reads back intact. A
restored machine never re-prints the kernel banner; the absence of
`VirelaiOS kernel has seized control.` *is* the proof a restore is not a
boot. The ctl listener re-arms on resume, so a resumed machine can
suspend again.

There is one hard device rule, and it is Virtualization.framework's, not
ours: a configuration carrying any custom-virtio device — which includes
the `--cvc-file` share — refuses `validateSaveRestoreSupport` before any
boot. Save-capable legs therefore ride Apple's standard `--virtio-fs`
share, the one host-file transport that survives the cycle (ADR 0036).
The credential double-reader picks the `vsock-ctl` row off either
transport.

<Aside kind="info">

**LIVE-GATED.** `live-suspend-resume` runs three full save/load pairs on
one profile. Each load leg accepts exactly two honest shapes:
`SUSPEND-RESUME: restored` plus the full state transcript, or
`restore refused code=12` — see the bound below.

</Aside>

<Aside kind="warning">

**LIMITATION.** On some host builds `restoreMachineStateFrom` saturates
at `VZErrorDomain` **Code=12** — hundreds of measured calls, zero
passes, image- and device-independent, aggravated by concurrent VZ load.
Saves are real everywhere; restores are asserted honestly wherever the
OS allows them. The gates pin the refusal rather than claim a restore
that cannot happen on that host.

</Aside>

## Named snapshots: GOSNAP

Suspend writes *the* saved state; `GOSNAP.ELF` parks *named* ones. A
`gosnap save <name>` sends `snapshot <name>` over the same ctl channel:
the host pauses the VM, `saveMachineStateTo`s `SNAPSHOTS/<name>.vzsave`
under the share root (a `.part` write then rename, so a listing never
sees a half-written file), replies while the guest is still frozen, and
resumes the machine. **A snapshot does not stop the run** — it is a
checkpoint of a live machine, not a shutdown.

`gosnap ls` lists the parked set with byte counts; `gosnap rm <name>`
and `gosnap restore <name>` are destructive enough to sit behind a typed
`confirm` consent gesture — without it the verb refuses
`consent_required` and nothing is deleted or staged. `restore` is a
*stage*, not a rewind: the running guest cannot be rewound, so the host
copies the named `.vzsave` over `saved-state/state.vzsave` and the next
`--resume` boots that image. A later suspend supersedes the stage, the
same rule a suspend already applies to a previous suspend.

The seat uses the same machinery itself: force-crash a hosted app and
the seat's crash arm parks a rotated `CRASH0.vzsave`, writes the
`CRASHSNAP.LAST` offer file, and re-execs the app so its own
`restore_state` takes the pre-crash blob back; a fresh boot that finds
`LAST` posts a recovery toast whose press stages the restore.

<Aside kind="info">

**LIVE-GATED.** `go-snap` drives ls/save/restore/rm on one profile —
the `exists` and `name_rejected` refusals, both consent asks, the
byte-identical stage, the crash-snapshot legs, and the
`SUSPEND-RESUME: restored`-or-Code=12 resume.

</Aside>

## Warm checkpoints: boot once, restore per leg

The gate fleet's unit of isolation was always a cold boot: every
`vgate_run` is a fresh `VMRunner` process, ~2–3 minutes of wall clock,
because boot-per-leg is the guarantee that nothing a leg mutates can
reach a sibling. ADR 0059 buys the same guarantee for less time: **boot
once, checkpoint at a quiescent prompt before any workload, restore that
checkpoint per leg**.

A `vgate_checkpoint <tag>` base boot carries the group's full device and
attachment shape, drives the guest to an idle `virelai>` prompt, then —
under one pause — captures a bundle: `state.vzsave` (RAM, vCPU
registers, device state), the run's ASIF overlay, the EFI variable
store, `machine-id.bin`, and the armed share. Every
`vgate_run <leg> --from-checkpoint <tag>` gets its *own clones* of the
overlay and share, because restoring RAM against a disk a sibling leg
already wrote pairs a guest that believes it wrote blocks the image
denies — incoherent, silently. A leg never resumes another leg's
residue; resuming from a sibling's post-workload state is not a flag, a
mode, or a fallback.

Post-restore arming replaces the boot-settle marker: the runner marks a
serial-epoch boundary, pokes a newline into the console, waits for a
fresh prompt *inside the epoch* — the guest proving it is idle — and
only then forwards the leg's script. Nothing is ever typed into a guest
that has not proven idle. Each leg's serial log contains only bytes
emitted after its own restore, so a leg asserting a boot banner is not
silently padded with replayed output — it fails honestly and is
classified cold.

Eligibility is decided statically, off the spec text: a leg whose flags
arm a `VZCustomVirtioDevice` can never checkpoint (`Code=2` needs no
boot to predict), and the semantic classes that cannot cross a freeze —
boot-order markers, the restore/suspend/reboot tests themselves, host
listeners and `vgate_client` hooks, elapsed-time budgets, mutations of
host state outside the cloned share, and legs that read a sibling's
output — stay cold with their reasons named. The fleet census is
mechanical: at the arc's landing, 308 specs held ~960 legs, of which 56
device-clean specs carried 163 warm-eligible legs, with
`live-quickjs` the pilot. A restore refusal degrades a leg to one cold
run, receipted `warm=fallback(<code>)` — never retried, because the
Code=12 bound is measured-persistent — while specs that exist to prove
the warm path pin `warm=restored` and fail on a refusal instead.

<Aside kind="warning">

**LIMITATION.** The USB mass-storage device is the known restore
problem: `--usb-msd` passed save/restore 8/9 times, then saturated to
total refusal under the same Code=12 bound. USB-MSD legs stay cold; the
verdict lives in `docs/hardware-contract.md`.

</Aside>

## Guest-staged OS self-update

A machine can upgrade its own operating system. `GOUPD.ELF` stages a
signed update set — `OS.IMG`, `KERNEL.BIN`, `BOOTAA64.EFI`, plus an
`UPDATE.MF` manifest and `UPDATE.SIG` signature — into the share's
`UPDATE/` directory, written atomically through the temp+rename
convention. The signature reuses the guest's own Ed25519 machinery, and
the `os-update` secret row is app-bound to `GOUPD.ELF`, so only that
image can sign.

On the next boot, `--apply-update` verifies the Ed25519 signature and
every manifest hash, then swaps the boot base: the old base becomes
`<base>.prev`, the staged set becomes the base, and the stale
`overlay.asif` is discarded (old sectors must not shadow the new image)
before the machine boots the new kernel. `--rollback-update` swaps
`.prev` back. The trust pin comes from `--update-key` or the profile's
own `config.updatePubkey` — a bundle-side pin the guest-reachable share
cannot move. A wrong key refuses `sig_invalid`, a tampered payload
refuses `hash_mismatch`, and `--apply-update` with nothing staged is a
harmless "none staged" report — safe to carry permanently.

<Aside kind="info">

**LIVE-GATED.** `live-os-update` runs the six legs — stage, wrong-key
refusal, apply (a real second kernel build whose `sysinfo` version
changes), rollback (the old version returns), tamper, and the
hash-mismatch negative.

</Aside>

## The acceptance chain

The whole arc is pinned by one standing journey: `live-persistence`
mints a single `.virelaivm` profile and runs **snapshot → suspend →
resume → stage → apply → rollback** on it, K=3 consecutive. Every leg is
the same bundle; the save legs ride `--virtio-fs` because a
custom-virtio share cannot be saved, and the update legs ride
`--cvc-file` because the app-bound `os-update` credential is only
servable on the queue-5 share. The transport split is the design made
mechanical.

## Measured envelope

The compiled defaults are deliberately modest and measurable: **2 vCPUs**
(`--cpus` accepts 1–8), **512 MiB** of guest RAM (`--memory-mib` accepts
64–2048), and a **64-slot task pool** (3 kernel-reserved + 61 user
tasks). The workstation-profiles acceptance observed a guest envelope of
≤256 MiB RAM and ≤4 cores on a session-minted bundle before the default
was raised; the capacity table in `docs/status.md` is the measured
record, not a spec sheet.

| Setting | Default | Range / bound |
|---------|---------|---------------|
| `--cpus` | 2 | 1–8 |
| `--memory-mib` | 512 | 64–2048 MiB |
| Task pool | 64 slots | 3 kernel + 61 user |
| Drop gesture | — | ≤64 MiB/file, ≤16 files |
| ctl sessions | — | ≤4 concurrent, 60 s idle |
| `.vzsave` snapshots | — | one per `SNAPSHOTS/<name>` |

## Read next

- [[run|The runner reference]] — every flag these mechanisms ride.
- [[host-int|Host integration]] — the ctl channel, the VHI1 lanes, and
  the Mac app that drives them.
- [[remote|Reaching the machine]] — console, SSH, RFB, and the agent
  channel on a running guest.
- [`docs/decisions/0056-vsock-ctl-channel.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0056-vsock-ctl-channel.md) and
  [`docs/decisions/0059-warm-checkpoint-leg-isolation.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0059-warm-checkpoint-leg-isolation.md)
  — the two ADRs that pin the wire and the checkpoint semantics.
