---
title: Live VZ gates
parent: evidence
status: published
tags: [evidence, class-b, vz]
---

# Live VZ gates (class B)

Class B gates boot a real Virtualization.framework VM on Apple silicon and
assert on what the kernel actually reports. CI cannot run them; a developer
host can (`just verify-vz`). They are the only machinery that observes the
kernel under real firmware — everything else on the
[[class-a|deterministic side]] proves code paths, not the machine.

## What a spec is

Every class-B gate is a **declarative spec** under `tools/gate/specs/`: a
bash file restricted to the `vgate_*` vocabulary defined in
[`tools/gate/SPEC.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/tools/gate/SPEC.md)
(the format is frozen since M40; extending it needs its own issue and a
pilot). A spec *declares*; `tools/gate/vgate.sh` *executes*. A header of at
most fifteen lines says WHAT and WHY; mechanism and history live on the
tracker. One spec may assert several things — the convention is to extend an
existing spec when it already covers a change, never to write a new
`verify-*.sh` script (that shape was rejected in review).

The vocabulary is small:

| Command | Declares |
|---------|----------|
| `vgate_name` / `vgate_share` | the gate id (evidence lands as `NAME-*`) and whether a share device is armed (`none`, `arm`, `seed`, and the `*-virtiofs` variants) |
| `vgate_run TAG -- FLAGS...` | one boot; FLAGS pass verbatim to the runner (device modes, `--script`, `--script-after` stage gates, `--timeout`) |
| `vgate_checkpoint TAG` | a dedicated base boot that pauses at a quiescent prompt and saves a restore bundle (ADR 0059) |
| `vgate_run TAG --from-checkpoint CKPT` | a warm leg: restore the checkpoint in a fresh runner and drive only `--script*` flags |
| `vgate_client TAG` | a host-side TCP client that runs *during* the boot — how the console/SSH/AGENTD listeners get exercised |
| `vgate_repeat N [BOOTS]` | run the whole spec N times (the K in K-consecutive acceptance) |
| `vgate_assert TAG KIND` | what must hold on that run — all asserts of a run must hold plus the runner exit code |

Assert kinds read three evidence surfaces: the guest's **serial log**
(`serial-contains`, `serial-count`, `serial-exact`, `serial-absent`,
`serial-echo`), the **armed share** (`share-equals`, `share-contains` —
files the guest wrote are byte-compared after boot), and **host captures**
(`capture-equals`, `capture-empty`, `snapshot` for scanout PNGs, `python`
hooks, `client-contains` for the `vgate_client` transcript). All of them
fail closed: an absent share file or a mistyped fixture is a FAIL, never a
skip.

## Naming

- **`live-*`** specs gate kernel and OS behavior against hardware —
  `live-net-tcp`, `live-vlfs-crash`, `live-smp`, `live-usb-msc`.
- **`go-*`** specs gate the Go userland and fleet behavior —
  `go-wm-default`, `go-flint`, `go-selftest`, `go-dogfood`.
- **`vgate-warm-smoke`** is the harness's own pilot for warm legs.
- Four legacy scripts predate the format (`bad-handoff`, `marker`,
  `nvram-console`, `host-console`) and ride the fleet as scripts; the list
  is frozen — new gates arrive as specs only.

## Discovery

`tools/gate/fleet.sh` globs the spec dir: the fleet is whatever is on disk —
**317 members** at this writing (313 specs + the four legacy scripts; check
with `bash tools/gate/fleet.sh count`). `just gate <id>` runs one member by
exact id or unique prefix, `just gates <pattern>` runs every member whose id
contains the substring, `just gate-list` prints the same `kind ⇥ id` table
the CI shards consume, and `just verify-vz` runs the whole fleet
sequentially. Dropping a `*.spec` file into the dir registers it in all of
these with zero list edits. The generated
`docs/gate-fleet-inventory.md` is a local snapshot of that discovery —
exempt from the [[claims|coordination gate]], and never to be committed in
a spec PR.

## How a gate proves things

A run is marker-triggered, not sleep-based: the runner forwards scripted
input only when the guest prints the marker it was anchored on
(`--script-after`, `--input-string-after`), and the harness stops the VM
when `--script-expect` matches. That makes the serial transcript itself the
ordering, so a gate asserts on a real causal chain — the kernel seized, the
device answered, the keystroke reached the terminal, the written file
survived a reboot — rather than on timeouts aligning. One consequence the
format enforces mechanically: `exec` returns immediately, so a spec that
launches a program and then does more must declare its ordering intent
(`# exec-order:`), and `inventory-gates.sh --check` flags the provable-bad
shapes in class A.

<Aside kind="info">

**LIVE-GATED.** The strongest single artifacts are the byte-exact ones:
`live-net-udp`/`live-net-tcp` walk captured Ethernet frames and verify every
checksum and the sequence/ack chain; `share-equals` asserts compare guest
output byte-for-byte; `snapshot` asserts decode scanout PNGs and check
pixels.

</Aside>

## K-run acceptance

Acceptance is measured in **consecutive** green runs — K=3 for most
journeys, K=5 where the blast radius warrants it — recorded on the
acceptance issue, not committed as logs. `vgate_repeat N BOOTS` bakes the
repeat into the spec so `just gate <id>` is itself a K-run. When hardware
flakiness is real, the spec says so and names the tolerated signature (see
[[benchmarks|live-bench's]] starvation-tolerant legs); an unexplained flake
is recorded and re-run, never hidden.

## The reference-host reality

GitHub's runners cannot boot a VZ guest, so **0 class-B gates run in CI**.
`.github/workflows/vz-gates.yml` shards the discovered list ×4 but is a
not-enforced placeholder until a `VZ_RUNNER_LABEL` runner registers (see
`docs/vz-runner.md`). The standing evidence is the **reference host**: the
dev machine whose full-fleet and K-run sweeps are recorded in
`docs/status.md`'s gate table and on the acceptance issues. Your local
`just gate <id>` run is a reproduction, not the record.

## Warm checkpoints (ADR 0059)

M131 taught the harness to boot once and restore per leg. A
`vgate_checkpoint` boot settles at a quiescent prompt, then pauses and saves
an immutable bundle — `state.vzsave`, the disk overlay, `machine-id.bin`,
pinned `efi-vars.bin`, and the share when the spec arms VirtioFS. Each
`--from-checkpoint` leg gets `cp -c` clones, restores in a fresh runner,
re-bases its first `--script-after` onto a fresh `virelai> ` handshake, and
sees only post-restore serial. A refused restore (`VZ-RESTORE: refused
code=<N>`, exit 75) falls back to one cold boot — or fails outright under
`--warm-strict`. `fleet.sh census` classifies every leg's warm eligibility
(`# warm-cold:` declarations carry classes `a`–`f`), `live-quickjs` is the
adopted pilot, and `VGATE_WARM=off` re-runs every leg cold for the parity
check.

## Two worked examples

**`live-vlfs-crash`** (the journaled filesystem's standing crash gate,
`vgate_repeat 5`): setup builds VLFS disk images; a leg commits `ANCHOR.TXT`
+ fsync, prints its marker, then keeps streaming a tail file while the
runner's hard `vm.stop` lands mid-write; the next boot remounts, replays the
journal, and asserts the anchor byte-exact and the tail
absent-or-committed-prefix — never half-present. Later legs cover a
metadata storm, a crafted replay-only image, the same pairs on a sealed
volume, and a canary scan that proves the host cannot read the sealed disk.

**`go-wm-default`** (the boot-default flip): a twenty-odd-boot matrix. Boot
01 carries no `wm` setting and asserts the compiled default seats
`GOTABWM.ELF` — `gotabwm: registered`, `holding seat`, the first-boot GOSH
workspace; a Go settings panel then persists `wm=tabwm` *from the default
seat*, and boot 02 asserts the same share boots the Zig fallback. Boots
03/04 stage real `SETTINGS.TXT` corruption and prove the kernel refuses the
file whole, heals to compiled defaults, and reports one honest line —
including the case where the corrupt file arrives mid-session.

<Aside kind="warning">

**LIMITATION.** These gates are hardware-specific and host-specific: they
need Apple silicon on macOS 27+, and timings live in `docs/testing.md`'s
per-leg notes. A flake is recorded and re-run rather than hidden — the claim
issues name flakes when they happen.

</Aside>
