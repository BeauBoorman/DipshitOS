# VirelaiOS testing

> For the current state of each verification gate (pass/fail/blocked), see
> [`docs/status.md`](status.md). This file is the sequence and policy. The
> A/B/C/D classification is defined in
> [`docs/gate-inventory.md`](gate-inventory.md); the single generated
> inventory of every gate is
> [`docs/gate-fleet-inventory.md`](gate-fleet-inventory.md).

## Verification classes

Every verification command belongs to exactly one class (canonical inventory:
[`docs/gate-inventory.md`](gate-inventory.md)):

- **A — portable / build CI.** Deterministic, no Apple silicon, no VZ VM.
  This is the set GitHub CI proves. A green CI badge means exactly these
  passed — nothing more.
- **B — Apple-silicon Virtualization.framework hardware gate.** Boots a real
  VZ VM on Apple silicon (macOS 27+ — the project's required host).
  GitHub-hosted CI does **not** run these and cannot prove them; run
  `just verify-vz` on a development host.
- **C — interactive / manual hardware gate.** Requires a human at the
  keyboard (`zig build console`).
- **D — diagnostic experiment.** Answers a question (claims
  0017/0018/0020/0021/6460); **not an acceptance gate**.

## Evidence policy

- **Observed** = the claim is backed by command output or a log file saved
  under `artifacts/`. Only observed behavior is reported as "works".
- **Inferred** = we believe it from documentation or reasoning, but have no
  log. Inferred claims are always labeled as inferred.
- We do not fabricate successful command output. If a required dependency or
  platform capability is unavailable, everything else still runs and the
  blocked step is reported precisely.

## Local host front door (M91a)

The supported launch is `source tools/env-check.sh && just session` on
Apple silicon/macOS 27+. The session command generates and directly runs
an ad-hoc-signed `VirelaiOS.app` (`org.virelaios.host`), not an installer or
a standalone Finder app. The raw `VMRunner` CLI remains available for gates.
Build/staging failures belong to the terminal. Runner preflight failures
use the same error window. It shows Starting VM, the running VZ display, or a
startup/runtime failure with the serial-log path. Close/Quit/Ctrl-C stop
the owned VM; rerun the command to relaunch with persistent share files,
fresh RAM, EFI vars and a throwaway writable overlay.

Class A:

```bash
swift test --package-path host/vm-runner
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/tests -p test_session_apps.py
bash -n tools/session.sh
```

Compatibility (class B): `just gate live-input` and
`just gate go-wm-default`. A failed guest-input assertion is not a host
pass, and belongs to M91b (#1923); do not change its specs here.

Host observation uses a fresh isolated fixture share, never personal
documents. Set `VIRELAI_SESSION_SHARE` before launch. Record only the owned
runner PID/window: app/bundle/title identity, an on-screen window, actual
key/first-responder state, native host-view event receipts, close and Quit,
and two launch/relaunch cycles. Verify that each PID is gone and its
temporary app/vars/overlay are removed after exit. Capture only that VM
window, not the desktop or other apps; evidence lives under
`artifacts/m91-host/`. Activation API success or a hidden window is
insufficient. If visibility/activation is unavailable, mark that exact
step blocked. Host observations and injected host-seam events do not
replace M91's later human guest Apps/Terminal/editor acceptance.

## Remote terminal (M87)

Class A uses isolated build/runner/client stand-ins, never a VM:

```bash
python3 -m unittest discover -s tools/tests -p test_remote_terminal.py
bash -n tools/remote-terminal.sh tools/remote-terminal-tape.sh
```

Class B extends the existing HMAC gate with a source-fresh, explicit
`wm=none`, `shell=sh` GOSH boot and M87b's real client. It checks late
attach, guest identity, editing/cancel/history, byte-exact host-share receipt
and history, a pipeline, an external ELF, wrong auth, busy refusal, an
11-second idle partial line and same-boot reconnect. Every client exit is
checked, including both old silent/deadline clients.

```bash
just gate live-remote-console
just gate live-console-tcp
just gate live-sh-monitor
bash tools/inventory-gates.sh --check
just verify-coordination
```

Class C requires **another physical machine**, authorized key-based host
OpenSSH access and a verified host key. Operator prerequisites: configure
Remote Login/key authorization yourself, verify the fingerprint through a
trusted channel, and ensure SSH reachability. Do not disable host-key checks.
Neither script enables Remote Login, uses sudo, or changes network rules.

The authorized key must permit the attach command and PTY allocation.
A forward-only key with `restrict`/`no-pty` correctly fails `ssh -tt` with
`PTY allocation request failed`; use an operator-authorized key with the
needed permissions, not weaker host-key verification.

On the Apple-silicon/macOS 27+ VM host:

```bash
bash tools/remote-terminal.sh serve --share /absolute/remote-share
```

On the other machine:

```bash
ssh -tt operator@vm-host 'cd /absolute/VirelaiOS && bash tools/remote-terminal.sh attach --share /absolute/remote-share'
# Record only the explicit scripted fixture, never an arbitrary operator session:
bash tools/remote-terminal-tape.sh --ssh-target operator@vm-host \
  --host-repo /absolute/VirelaiOS --share /absolute/remote-share --fixture-only
```

The fixture uses `BatchMode=yes`, `StrictHostKeyChecking=yes` and `ssh -tt`
for attach, compares digested machine identities (same-host SSH is refused),
records SSH address families/loopback relationship without raw addresses,
and pins service/runner identity across Ctrl-] and reconnect. It verifies
GOSH/guest principal, receipt read-back plus host-side byte comparison,
editing/Up, Ctrl-C cancellation, UTF-8/ANSI, pipeline and external command.
Evidence lives under `artifacts/remote-terminal/<UTC timestamp>/` on the
connecting machine. Use a clean fixture share: the driver writes
`REMOTE.RECEIPT` and checks absence of `CANCEL.RECEIPT`/`PARTIAL.RECEIPT`.
It does not copy owner documents or history into the transcript.

Different identity digests alone do not prove physical separation, especially
when comparing Linux `/etc/machine-id` with macOS `IOPlatformUUID`. Record the
operator's physical-machine provenance as well as the fixture artifacts.
A container on the VM host remains SSH smoke evidence, even if the driver
prints `PASS class C`; it does not satisfy the physical-machine requirement.

Controls: attach Ctrl-C goes to GOSH; Ctrl-] disconnects without stopping
the VM. Serve Ctrl-C stops its own runner. Ctrl-D on an empty line, `exit`,
or `monitor` ends GOSH and returns the raw kernel monitor, not product
acceptance. `exec GOSH.ELF serial` there resumes GOSH. Documents and
`GOSH-HISTORY.TXT` survive service restart; VM RAM/vars/overlay do not.
The bridge is loopback-only, HMAC-authenticated plaintext inside the SSH
boundary. One client, serial-only, no guest SSH/PTY/resize/Screen/graphics
or new kernel TUI claims.

Missing second machine, SSH service, verified host key, or authorized key is
**BLOCKED class C**, not a local success. Keep M87 product acceptance open
until both the desktop and remote product journeys have evidence; canonical
state is only in `docs/status.md`.

## Guest self-test (M61) — the split of labor

ADR 0031 ([`decisions/0031-guest-selftest.md`](decisions/0031-guest-selftest.md))
moved part of the evidence into the guest. The rule, in one table:

| Lives | Who |
|---|---|
| Boot, VZ death, host-injected HID, framebuffer goldens, hypervisor restore | **Host** class-B spec (keep `just gate`) |
| Syscall ABI, files, windows, clocks, "did this app actually compute" | **Guest** `GOSELF.ELF` writes `/host/SELFTEST/…` |
| Pass/fail of the run | Host reads those files (and one serial summary line). Serial is the heartbeat, not the proof. |

- The share layout is `SELFTEST/IN/` (host-seeded fixtures),
  `SELFTEST/OUT/` (guest receipts) and `SELFTEST/REPORT.txt` (the guest's
  report) inside the per-run `--cvc-file` share — the host `cat`s them on
  macOS. Nothing for this arc is packed into `disk.img`, and the guest
  reads intake fixtures from the share rather than carrying them.
- **Intake (M61c, #1383) is the anti-embedding test.** The spec seeds TWO
  fixtures with different bodies (`IN/fixture.txt` = the canonical bytes,
  `IN/altered.txt` = the same bytes with one character changed) and the
  `intake` / `intake-altered` cases copy the bytes they actually **read**
  to `OUT/fixture.copy` and `OUT/altered.copy`. The host byte-compares
  those copies against the files it wrote, so an app that answered from a
  constant compiled into the binary cannot pass, and mutating the seeded
  file makes the case FAIL (`read returned <n>B of zeros (issue #1391)`
  when the channel itself is the problem). Writes stay out of `IN/`:
  the spec also asserts both fixtures are unchanged after the run.
- **The read path's defect is fixed (#1391, ADR 0032).** A kernel→user copy
  into a page EL0 had never written used to be silently lost — the syscall
  returned the right byte count and the app read zeros (M61b: an all-zeros
  `APPS.TXT` read and a zeros read-back of a file the guest had just
  written). It was never the host file channel (the runner's stdout shows
  the bytes served) nor the guest's write path; the destination page
  resolved for EL1 into the kernel's EL1-only identity overlay, so the
  store reached a physical address no EL0 access could see. The copy path
  now resolves each destination page in the process's own root before
  storing (`exceptions.populate_user_page`; `unbacked` in the monitor's
  `uaccess` line counts refusals and must stay 0). `user/go/selftest`'s
  workaround is **deleted** — the intake case reading a host-seeded fixture
  into a fresh buffer is the regression test, so do not add retries,
  warm-up writes or buffer reuse there, and M61d (create/write/read-back)
  can rely on fresh buffers.
- **The file-ABI pack (M61d, #1384) is the file channel's evidence.** Four
  cases on the share under `OUT/`: `file-roundtrip` (create, write, close,
  reopen, read back the exact bytes), `file-truncate` (write 840 B, shrink
  through the same write handle to 105, read the prefix), `file-delete`
  (delete, then a read-only open must fail) and `file-list` (a listing sees
  `OUT/LIST/listed.txt`, and does not once it is deleted). Each case leaves
  a one-line `OUT/file-<case>.ok` receipt **and** — where bytes came back —
  a `.copy` of the bytes it **read** (`roundtrip.copy` 525 B,
  `truncated.copy` 105 B). The spec byte-compares all of it, and then checks
  the share's own directory state independently of the receipts
  (`OUT/deleted.txt` absent, `OUT/LIST` empty, `OUT/truncate.txt` holding the
  reconstructed prefix). A run with right-length-but-wrong bytes keeps every
  receipt and both serial verdicts green and still fails: the reported
  verdict is never the proof, the bytes are. Watch the coupling — the
  payloads are reconstructed on the host from one expression
  (`b"goself file abi line\n" * n`), so changing that unit in
  `user/go/selftest` means changing the spec.
- `file-list` lists its own subdirectory (`OUT/LIST`), not `OUT/`:
  `sys_dir_list` clamps to 16 rows, and `OUT/` holds far more than that by
  the time the case runs, so listing it would make the verdict depend on the
  alphabet. That subdirectory is also what exercises the guest's own `mkdir`
  for real — the MODE_DIR row needs `MODE_WRITE|MODE_CREATE|MODE_DIR`
  together, and only the host-side `makedirs` had been keeping the app's
  bare-MODE_DIR call from being silently EINVAL.
- **The window receipt (M61e, #1385) is a read-back, not a restatement.** The
  `window` case fills and presents the app's own tabapp window (failing on
  either return) and writes `OUT/window.txt` — `case window win=<id> w=<W>
  h=<H> present=ok` — where `w=`/`h=` come from `sys_win_query`, the kernel's
  record of the window, read back into a fresh buffer (the same kernel->user
  path as the other read-backs). The spec matches the line (its id is a
  runtime value) and then holds it to the two reporters of that window which
  are not this process: the kernel's own open-attribution marker
  `open: id=<N> owner=<pid> rect=<x>,<y> <W>x<H> ws=<k>` (`driving_award.zig`,
  issue #990) and TABWM's `tabwm: tab-switch idx=<i> id=<N>`. All three ids
  must agree.
- The geometry carries a second assertion worth understanding before changing
  anything: GOSELF opens at 32,32 640x400 and the kernel logs exactly that,
  but TABWM then proposes the tab-aware content viewport (180,0 1100x720 —
  tabwm's `compute_tab_viewport`), so the receipt must report **1100x720**. The
  spec fails on a receipt that repeats the open rect, which is what a case
  restating its own request would do — a number the kernel's open line
  contains. Change the WM's viewport policy and the SPEC is what changes; the
  app stays a probe. This is emphatically **not** a framebuffer golden (the
  card's non-goal): no pixels are read, no PNG is compared, and the case knows
  nothing about what the window looks like. Framebuffer goldens stay host-side
  (`vgate_assert snapshot`) for r3d and friends.
- **`share-equals` / `share-contains` (M61f, #1386) read the armed share
  directly**, so a spec that only needs to compare share bytes needs no
  `python` assert at all — and the harness lifts the compared file into
  `artifacts/` itself (a hand-written python block has to do that copy, and
  that copy is what survives `gate_end`). `go-selftest.spec` is the pilot:
  `share-equals` owns `REPORT.txt` and the host-seeded `IN/fixture.txt`,
  `share-contains` owns the guest's summary count, and the `python` assert
  keeps only what the kinds cannot express (the share's directory state and
  the window cross-checks against the serial log). Both kinds **fail closed**:
  an unarmed share, a missing `RELPATH`, and a mismatch are FAILs, never
  skips — a share assert that silently passed is the false PASS the kinds exist
  to remove. See `tools/gate/SPEC.md` for the argument forms; note that
  `share-equals` resolves an existing `$RUN_DIR` file as the fixture and
  anything else as a literal.
- The serial contract is one summary line, `selftest: FAIL n=<N>` (N=0 on
  success), printed after `REPORT.txt` is closed; the report's
  `summary cases=<n> failed=<k>` must agree with it, and a run whose
  summary never appears is a failed run.
- One thin spec (`go-selftest`) boots the app. Do **not** add a
  `live-foo.spec` for a case that belongs in GOSELF, and do not retire a
  `live-*` spec until a later card shows the self-test case is strictly
  stronger. TLS/SSH/net responders stay host-side.
- The per-run share is deleted at `gate_end`; any file the host compares is
  copied into `artifacts/` first (`artifacts/go-selftest-report.txt`, …).

## Locale determinism

A generated file whose bytes depend on the shell's locale is worse than no
check at all: it passes for the author's shell and fails for everyone else's.
That is how the gate-fleet inventory drifted (issue #1177 — the tracked
render was the *byte* truncation under `LC_ALL=C` and the *character*
truncation under a UTF-8 locale, so `main` passed under UTF-8 and failed
under `C` with no workflow noticing). The rules that came out of it:

- **Generated inventory bytes must not depend on the shell locale.**
  `tools/inventory-gates.sh` pins `LC_ALL=C` for the render, truncates
  headers in UTF-8 **characters** rather than bytes, and `--check` renders
  a second copy under `en_US.UTF-8` and fails when the two disagree — so a
  locale-sensitive operation cannot creep back in. The tracked
  `docs/gate-fleet-inventory.md` is a snapshot, not a PR artifact:
  `--check` does not require it to match, because that made every spec PR
  conflict on the same generated table.
  (Reachability, observed 2026-09-29: 101 of the 249
  `tools/gate/specs/*.spec` files contain non-ASCII; **9** of their
  first-line headers do — `go-wm-hid`, `go-wm-tabs`, `live-desktop`,
  `live-desktop-typing`, `live-devcons`, `live-m21-persist-title-orphan`,
  `live-user-fs`, `live-wm1`, `live-wnd5-gate2-policy`. The drift that
  motivated the rule was narrower: of the headers present then, only
  `live-m21-persist-title-orphan` (em dash) crossed its truncation
  boundary, which is why exactly one row differed.)
- **Pin `LC_ALL=C` wherever the output is compared, committed, or used to
  name an artifact.** `cut -c`, `printf '%.Ns'` and bash `${v:0:N}` count
  bytes or characters depending on the locale, and `sort`/`uniq` collation
  plus the `[:lower:]`/`[:upper:]` tables are locale-dependent. Count
  characters explicitly when truncating human-authored text.
- **Audit (issue #1186):** these constructs appear nowhere else under
  `tools/` except `tools/verify-zc-corpus.sh` — its case-list dedupe and
  its case-name to artifact-name mapping are now pinned — and the remaining
  unpinned `sort -u` calls (`tools/verify-pointer-manual.sh`,
  `tools/probe-pointer-routes.sh`) feed a count or a diagnostic string in
  class C/D gates, never a tracked byte or a compared filename.

## Fuzz fleet (M70a, issue #1453)

Two seeded, host-only corpora — both class A, no VM, no device:

- **`kernel/tests/fuzz_test.zig`** (runs inside `bash tools/verify-unit-tests.sh`
  / `zig build test`): drives the ADR 0007 dispatch seam with hostile
  argument tuples over every slot in and just past the namespace — an
  out-of-namespace or reserved row must answer exactly `-ENOSYS`, most
  hostile tuples must produce a documented errno or the ABI's `0`, and no
  call may leave a service-domain lock held or move the caller. A separate
  live-EL0 sweep drives the 24 slot/argument positions the syscall suite
  already pins as buffer-carrying (`uaccess.diagnostic_unmapped`) and
  requires a non-positive answer. It also mutates the checked-in
  `tests/vf-*.bin` fixtures (embedded through a build option, so the corpus
  cannot drift from the files) through the HF decoders.
- **`host/vm-runner/Tests/VMRunnerTests/VFWireTests.swift`** (`swift test`):
  the same fixture mutation over the Swift `VFWire` decode, the share-root
  containment property of `resolveSubpath`, and the refusal properties of
  the pure payload builders.

**Determinism is the rule:** every generator takes a fixed seed; a failure
names the seed and the slot/iteration, so it replays byte-identically on any
machine. Do not introduce wall-clock time, `sys_getrandom`, or host entropy
into a gate-run corpus.

**Keep a green run silent.** An unconditional `std.debug.print` in a test
module makes the Zig build runner mark that run step `w` and echo
`failed command: … --listen=-` for a step whose tests all passed and whose
build exits 0 (observed 2026-09-18 with a five-line probe module). Print only
when there is a violation to report.

**Named gaps** (do not read a green host run as coverage of these): the host
runner's request parse in `main.swift`, which is not VZ-free. Reply-byte
mutations of `tests/vf-*.bin` stay host-side (the guest cannot rewrite a
reply the host generated).

**Live half (M70a-live #1466 / M70a3 #1470, gate `live-fuzz`):** the monitor
command `fuzz roster` (or `fuzz <seed>`) STAT-proves `virtio_file.stat`'s
inline `[size][type]` parse on queue 5, submits 32 mutated STAT requests
per seed, then execs `EL0EXEC.BIN fuzz …` so the `(slot, args)` sweep, the
buffer-contract split, and a successful `sys_exec` of `USER.BIN` all run
from EL0. The program prints `seed=0x… ok` per seed, `fuzz: caller-not-moved
ok`, and `fuzz: done`. Skip list (live-only): yield/exit/sleep/wait/
udp_recv/wait_event/kill/tcp_connect/tcp_recv/setrlimit/thread/futex/
sock_ready. Write is skipped so hostile buffers cannot spray the serial.

## Contract v2 — capabilities and delivery admission (M70e, issue #1457)

`docs/wasm-import-contract.md` **§9** is normative; this is how it is verified.

- **`user/src/wasm.zig` unit tests (class A, `zig build test`).** The module
  now registers as a host test root. Before M70e, nothing in the fleet ran its
  41 test blocks: the file was only ever built as `WASM.BIN`, and it was
  absent from `build.zig`'s test-source list, so `zig test user/src/wasm.zig`
  was a hand-run habit rather than a gate. The §9 cases cover a declared
  revision + capability set gating the imports actually used, an unsupported
  revision failing closed before start, every malformed-section shape, a v1
  module (no section) staying untouched, a module past `max_imports`, and a
  drift guard that every capability is reachable from the frozen list. The
  §9.2 cases parse manifest rows strictly and pin the admission order
  (`no_row` → `size` → `digest` → `revision` → `capability`), including a row
  granting more than the module uses (allowed) and one granting less (refused).
- **`live-wasm-abi.spec` (class B, one boot).** The refusal surface live, each
  a named serial line with its own exit status: unsupported revision `14`,
  undeclared capability `16`, no row `17`, size `18`, digest `19`, capability
  escalation `21` — plus the two paths that must keep working: a v2 module
  whose row was generated from the delivered bytes (`TRIO.WASM`), and a v1
  module that runs with no row at all (`WC.WASM`, the additivity promise).
- **`live-wasm.spec`** gained the positive v2 phase: the stamped corpus
  module, delivered with a manifest row, asserting its file/window/timer
  results and exit status 40 (its byte count).
- **`tools/wasm-manifest.py`** is the delivery tool — `stamp` (add/replace the
  §9.1 section), `gen` (write `WASM.TXT` from the modules present), `check`
  (re-verify every row against every file). It reads the name→capability
  mapping OUT of `user/src/wasm.zig`, so the tool and the loader cannot
  disagree about which capability owns an import.

**Observed while gating this:** nine `exec WASM.BIN …` commands injected in a
single script produce nine runs but **eight** `tasks user-exec exited status=`
reports — the monitor collapses a report when the next run reaps before the
previous is drained, and the dropped one is the first (trio's `status=40`).
The admission spec therefore asserts the refusal statuses, all of which
survive, and the staged `live-wasm.spec` asserts the app's own exit status.
Re-runs reproduced the same drop.

## USB volumes — a read-only FAT32 reader over the M43 block seam (M70f F1, issue #1458)

The frozen decision (on the card, D1) is **read-only FAT32**, not a
Virelai-private on-disk layout: the gate's own MSD corpus is a FAT32 volume
built by the *host*, so the reader has an independent oracle, while a private
format's only verifier would be our own writer. It is a new module, not a
`fat.zig` restoration — no writes, no format, no mount machinery, no DATA
partition, no boot/EFI volume, no allocator, and it never re-arms virtio-blk.

- **`kernel/src/fat32_ro.zig` unit tests (class A, `zig build test`).** The
  module imports only `std` and takes a `SectorSource` (function pointer +
  context), so every structural path is host-testable against an in-memory
  image built in the test: MBR signature/slot parsing, FAT32 BPB validation
  (a FAT16-shaped BPB, a conflicting type string, a non-power-of-two cluster
  size, an out-of-range root cluster, and a 1024-byte-sector volume are each
  refused by name), directory listing with the volume-label/deleted/`.`/`..`
  rows skipped, LFN assembly gated by the 8.3 checksum, a three-cluster chain
  read byte-exact in deliberately ragged chunks, the streaming/one-shot FNV
  identity, and the broken-chain cases (early EOC, out-of-range cluster, the
  reserved bad marker, a self-loop, a zero first cluster) which must stop at
  the last byte the disk held rather than fabricate or hang.
- **`kernel/src/file_table.zig` unit tests (class A).** `usb<N>/<path>` routes
  to the volume partition, `usb5`..`usb9` are refused instead of silently
  becoming host files, `usb1x.txt` still stays one, and with no device attached
  every volume open/listing is an honest `ENOENT`; mutating flags, `set_mode`,
  `delete` and `rename` are refused before any sector is read (the delete
  guard also closes a latent path where a device subpath could reach the host
  channel).
- **`live-usb-block.spec` (class B, one boot).** The staged disk is a
  12 MiB MBR image: partition 1 is a hand-built FAT32 volume (`PROBE.TXT`,
  120 B; `DOCS/NOTE.TXT`, 5000 B across clusters 5→6→7) and partition 2 is a
  deliberately non-FAT32 type (`0x83`). The boot proves the MBR walk
  (`usb vol` geometry, per-slot `absent`/`reason=type` answers), root and
  subdirectory listings, and two **whole-file** byte proofs: `PROBE.TXT`
  prints all 120 bytes with `sum=0x133d22a5`, and `NOTE.TXT` prints a bounded
  256 of 5000 with `sum=0x52e785f5` — the checksum is what makes the
  multi-cluster claim, and the spec's setup python recomputes both values so a
  content edit fails at staging instead of producing a mysterious mismatch.
  The honest refusals are observed live (`partition 2 is not a readable FAT32
  volume (not-fat32)`, `no such MBR partition`, `not found`, a directory read
  by `usb cat`, a file listed by `usb ls`), and `BLKD.BIN` proves the same
  bytes twice from EL0 — raw (`.usb`, phase 1, the M43 regression) and through
  the file-table `usb1/PROBE.TXT` handle (phase 2), asserting 120 bytes then
  EOF and exiting 2 with its own line on anything else.

**Observed limits, recorded rather than hidden:** VZ's `--usb-msd` is the only
attachment path, so "a real stick in a real port" is unprovable here; the
reader speaks 512-byte sectors and FAT32 only (no FAT12/16/exFAT/NTFS) and is
read-only; LFN code units are taken as their low byte, and a name longer than
31 bytes is truncated in the frozen 40-byte `DirEntry` row (`usb ls` prints it
whole); the volume label comes from the BPB only; `usb cat` prints at most 4096
bytes and scans at most 1 MiB, reporting `capped=1` when the bound rather than
the file ended the read. The `usb vol|ls|cat` verbs are in the monitor's `usb`
help catalog, and the three fixtures that pin that string —
`kernel/src/shell.zig`'s exact-transcript test, `tests/transcript-console.txt`,
`kernel/tests/monitor_test.zig` — were updated in the same change (that fixture
near-miss is documented below).

**Chain safety is a rule here, not a hope.** Three shapes are refused rather
than served: a chain that points at itself stops immediately; a cyclic table
(A → B → A) is caught because the chain must END where the file's size says it
does (one extra FAT read at EOF — without it a cycle serves real clusters until
the byte count runs out and looks like a clean read); and a directory walk is
bounded by the volume's own cluster count, so a terminator-less cyclic
directory ends as a broken chain instead of spinning `usb ls` on the
single-threaded shell path. Each case latches `broken` and keeps only the bytes
the disk actually held, asserted by unit cases for the self-loop, a two-cluster
cycle, a healthy control chain, and a cyclic directory (plus early EOC, the
reserved bad marker, and a zero first cluster).

## Go audio — volume/mute and the muted-drain identity (M70f2, issue #1476)

M70f2 is the Go half of the audio arc, and it exists because the card that
commissioned it was written on a stale premise: M58e/M58f had already shipped
`user/go/vi/audio.go` (slots 42/43) and `FART.ELF` three days earlier. What was
genuinely missing was slots **44/45** — `audio_volume`/`audio_mute`, which no Go
program could reach — and a Go consumer that asserts the properties
`user/src/chime.zig` proved from Zig. The card is corrected in place rather than
quietly re-scoped.

**What is verified, and how.**

- `AudioVolume`/`AudioMute` in `user/go/vi/audio.go` (host: `go test ./vi`,
  14/14 audio cases). The audio rows now go through the hookable gateway
  (`svc1`/`svc2`, the seam M66a opened for the file surface), so the host suite
  can inject a fake kernel and pin what the binding **sends**:
  `TestAudioVolumeNoClamp` asserts an out-of-range volume reaches the kernel
  unchanged, `TestAudioMuteMapping` pins the 1/0 wire, and
  `TestAudioVolumeNegativePassedThrough` pins the two's-complement pass-through.
  Before this the whole file called the raw assembly, so the only
  host-testable half was the chunker.
- `go-fart.spec` (2/2 runs, 38 s) grew three phases and cross-checks all four
  against the kernel's single counter: `43 sys_audio_play calls=196` =
  52 (blip) + 24 (unmuted) + 24 (muted) + 96 (sequence). The blip's markers and
  digest are byte-identical to M58f's; only the total moved, and the spec's
  python sums the phases instead of trusting one number.
- The **muted-drain identity** is an A/B: one 250 ms tone (96000 bytes)
  submitted unmuted, then muted, both confirming 96000. Asserting it as an
  equality between two identical submissions is the point — a mute that
  shortened the return would be indistinguishable from `ErrNoAudioDevice`,
  which is this seam's device-refusal signal.
- **The no-clamp rule is observed from EL0**: `fart: vol over=101 err=EINVAL`.
  The app prints `CLAMPED` instead if the kernel ever starts accepting an
  out-of-range gain, and both `go-fart.spec` and `live-sound-control.spec`
  assert that marker ABSENT — so a green run says the refusal happened, not that
  the check was skipped.
- `live-sound-control.spec` (2/2, 41 s) run 02 boots the Go app and then reads
  the kernel state back through the **monitor**: `sound: vol=40 mute=0`, where 40
  could only have come from the app (the kernel's default is 100 —
  `virtio_snd.zig:256 stream_volume`, observed as `sound: vol=100 mute=0` in
  `live-sound-device` on a boot that sets nothing). That is state observed
  through a path the app does not control, which its own markers cannot give.
- `live-sound-playback.spec` (1/1, 28 s) asserts the accounting identity as
  ARITHMETIC rather than as a verbatim line: `submitted == drained == frames * 8`
  with `frames == 300 ms × 48 kHz`, so a consistent-but-wrong pair cannot pass.
- `live-sound-app.spec` (1/1, 45 s) is behaviorally unchanged and carries the
  retirement decision as a comment.

**The M60 one-binary-per-card question, answered.** `JINGLE.BIN` and
`CHIME.BIN` were **not** retired, and the comparison is recorded assertion by
assertion in `live-sound-app.spec`. The Go successor covers the EL0 seam,
bounded chunking over the 64 KiB per-call bound, per-note accounting and the
syscall counters — from Go, in both the `--sound` and soundless arms. It does
not play JINGLE's 14-note melody, and that spec's python asserts the melody's
exact per-note byte counts (96000/192000), so retiring `JINGLE.BIN` would drop a
CONTENT fixture, not merely a binary. That is the policy ADR 0030 (`go-is-el0`)
fixes — "Deletions are one binary at a time, each independently revertible. No
flag day." — and a retirement that silently dropped coverage is not available
under it. CHIME's half *is* covered (slots 44/45 plus the muted-drain identity,
above), but a coverage answer is not a retirement, and nothing is deleted by
this card.

**Named limits, so a green run is not read as more than it is.**

- **The waveform is not observable.** Nothing here captures what the device
  receives (host-side capture is a non-goal of the card), so "muted" is
  evidenced as an accounting identity plus kernel state — never as measured
  silence. A device that drained the samples without zeroing them would pass
  every assertion above.
- The loudness a volume setting produces is not measured either: only the bound
  (0..100), the echo, and the kernel-state read-back are.
- `43 sys_audio_play calls=` counts the run's whole session, so the spec's
  python sums the phases deliberately; a future phase must be added to that sum
  rather than absorbed into a re-pin.
- These four specs are class B (VZ + `--sound`), so they run where the class-B
  fleet runs and not on every push.

**One pre-existing failure found and fixed here.** `live-sound-control.spec`
pinned `syscalls: slots=64 implemented=68` while `kernel/src/syscall.zig`
declares `implemented_count = 78`, so the assert had been RED ON MAIN, in a
class-B spec CI does not run, with no unit test pinning the census. It is now
asserted as the SHAPE the composition specs already use (`implemented=`), with
the exact number left to the kernel source. The exact-count siblings
(`live-wmctl-register`, `live-win-syscall`/`move`/`close`, `live-net-udp-syscall`)
pin `syscalls: slots=64 implemented=78` from the VZ serial.

## Daily-driver beat (M69a, issue #1528)

`go-dogfood` is the one fixed path that boots the **default** Go seat (no `wm`
override anywhere) and drives the apps a human would touch. Two boots, one
beat; every stage is released by the previous stage's own marker, so the serial
order is the beat order:

| boot | stages | markers, asserted in order |
|------|--------|----------------------------|
| 01 | `exec GOSH.ELF`, then `exec NOTE.ELF` | `dogfood: seat` < `dogfood: gosh` < `dogfood: note` < `dogfood: ok` |
| 02 | `exec GOCALC.ELF`, then `exec WEB.ELF /host/DOGFOOD.HTML` | `dogfood: seat` < `dogfood: calc` < `dogfood: page` < `dogfood: ok` |

- **The markers are guest-owned.** Each is printed by the program it is about
  — the seat (`seat` after registration *and* the one-seat probe; `ok` at
  host-done, and only when that boot actually hosted a tab), GOSH / NOTE /
  GOCALC on their **accepted-declare** path, WEB on the first frame of a
  laid-out page reaching the scanout. No staged line and no harness echo can
  produce one, and the spec asserts them at **line start and in order**, with
  the other half of the beat required to be absent from the run.
- **The beat is two boots for one hard reason and one conservative one**, both
  spelled out in the spec header. Hard: the runner forwards at most three
  command phases per boot (`--script` / `--script2` / `--script3`), and four
  phase-gated execs need four. Conservative: the seat's *proven* envelope is
  three Go runtimes — itself plus two clients (M65d / #1442) — so each boot
  stages two client apps, the shape `go-wm-default` (one) and `go-wm-tabs`
  (two) already prove. Four live Go runtimes have not been tried; that is an
  envelope, not a wall, and `#1449` is a different shape (a third *sequential*
  exec from one EL0 parent, which M70c-S2 measured as unreproduced).
- **Hosting is pinned by the seat's counter, not by the app markers.** Each
  app's `dogfood:` line rides the accept-declare ACK, and `gotabwm`'s
  `applyRPC` acks `applied=1` on that path whether or not a tab opened, so the
  app cannot tell — the spec therefore asserts `gotabwm: tab open id=` **twice**
  per boot (the `go-wm-tabs` idiom). `dogfood: ok` is the stronger one: its
  latch is set by a successful `tabs.OpenTab` alone.
- **The browser is attached, not declared.** WEB sends WM_RPC kind 5 (attach)
  rather than kind 8 (declare_fullscreen) so the page keeps the 512x384
  geometry the `live-web*` gates pin. Attach is also what makes the page
  visible on this seat: the seat paints the blank desktop only while its strip
  is empty, and that fill sits above user windows.
- **Host prerequisites** — build the five guest ELFs first; the spec refuses a
  missing one by name: `bash tools/go/build-gotabwm.sh`, `build-gosh.sh`,
  `build-note.sh`, `build-gocalc.sh`, `build-web.sh browser WEB`. The page is
  the pinned fixture `user/go/browser/testdata/gate-page.html`, staged as
  `/host/DOGFOOD.HTML` — no new fixture.

M69a's own header used to promise that M69b would hang `--screenshot-after`
*on* these markers. M69b measured that and it is wrong — see the next section.

## Screenshot corpus (M69b, issue #1529)

The images the site embeds are captures of **this repository's own boot**,
produced by the runner's framebuffer path — no phone camera, no stock art. The
pinned corpus is `site/index.assets/`: `screenshot.png` (the hero), `gosh.png`,
`note.png`, `gocalc.png`, `web.png`, each 2560x1440 (the 1280x720 scanout at
2x) and each one boot of the default Go seat.

**What the capture waits on, and why it is not the app's paint marker.**
`--screenshot-after <marker>` fires once, on the first serial text containing
`<marker>`, into `<--screen base>-after`. Capturing on the app's *own* marker
(`gosh: prompt`, `note: settled`, `gocalc: present`, `dogfood: page`) yields a
**pre-relayout** frame — measured 2026-09-20: the seat opens the tab, resizes
the client's view, and the client repaints a moment later (`note: resize
relayout`), so the early frame is window chrome over a black surface; and
before the seat's desktop fill lands, what is on the scanout is still kernel
console text. So the capture marker is a script echo the runner types N
seconds *after* the guest's marker (`--scriptN-delay`): still a serial marker
(deterministic, not a wall-clock frame pick), just late enough to be the
finished frame.

| capture | release marker (guest-owned) | capture marker | settle |
|---------|------------------------------|----------------|--------|
| `screenshot.png` (hero) | `note: settled`, GOSH already up | `shot-desktop` | 8 s |
| `gosh.png` | `gosh: prompt` | `shot-gosh` | 8 s |
| `note.png` | `note: settled` | `shot-note` | 8 s |
| `gocalc.png` | `gocalc: present` | `shot-gocalc` | 8 s |
| `web.png` | `dogfood: page` | `shot-web` | 8 s |

**Reproducing one of them** (web — the other four differ only in the exec line,
the release marker and the names). Every flag is a pre-existing runner flag;
M69b added no capture machinery, and no spec:

```bash
zig build && zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist \
    host/vm-runner/.build/release/VMRunner
bash tools/go/build-gotabwm.sh && bash tools/go/build-gosh.sh \
  && bash tools/go/build-note.sh && bash tools/go/build-gocalc.sh \
  && bash tools/go/build-web.sh browser WEB

# the share: gate_seed_share's ingredients (tools/lib/gate-run.sh step 1-5)
SHARE=/tmp/m69b-share; rm -rf "$SHARE"; mkdir -p "$SHARE"
cp -R zig-out/bin/. "$SHARE/"
cp .build/go/{GOTABWM,GOSH,NOTE,GOCALC,WEB}.ELF "$SHARE/"
cp user/go/browser/testdata/gate-page.html "$SHARE/DOGFOOD.HTML"
cp image/apps.txt "$SHARE/APPS.TXT"; cp image/WALLPAPER.QOI "$SHARE/"
# the M69d faces: without them the seat's chrome has no UI font to render with
cp image/fonts/Inter-Regular.ttf "$SHARE/INTER.TTF"
cp image/fonts/Inter-Bold.ttf "$SHARE/INTERB.TTF"
cp image/fonts/Inter-Italic.ttf "$SHARE/INTERI.TTF"
cp image/fonts/FiraCode-Regular.ttf "$SHARE/FIRACODE.TTF"

printf 'set GOMAXPROCS=1\nexec WEB.ELF /host/DOGFOOD.HTML\n' > /tmp/m69b-1.txt
printf 'echo shot-web\n' > /tmp/m69b-2.txt
printf 'echo shot-web-done\n' > /tmp/m69b-3.txt

rm -f /tmp/m69b-vars.bin   # REMOVE, never truncate: an empty store is EINVAL
date -u '+captured %Y-%m-%dT%H:%M:%SZ; revision'
git rev-parse HEAD
host/vm-runner/.build/release/VMRunner \
    --overlay-base artifacts/disk.img --vars /tmp/m69b-vars.bin \
    --cvc-file "$SHARE" --serial /tmp/m69b-web.serial.log \
    --screen /tmp/m69b-web --screenshot-after shot-web \
    --script /tmp/m69b-1.txt  --script-after  'dogfood: seat' \
    --script2 /tmp/m69b-2.txt --script2-after 'dogfood: page' --script2-delay 8 \
    --script3 /tmp/m69b-3.txt --script3-after 'shot-web' \
    --script-expect shot-web-done --timeout 90
mv /tmp/m69b-web-after site/index.assets/web.png
```

Details that cost time to learn, all observed here:

- The capture is written to `<--screen base>-after` — the marker label is
always `after`, so the file is renamed per boot. `--screenshot-after` fails
closed without `--screen`.
- `--script-expect` is checked *before* `--screenshot-after` in the same poll
tick, so the capture token and the expect token must differ (`shot-web` vs
`shot-web-done`) — one token doing both ends the run before the capture.
- The runner prints which route produced the PNG:
  `capture path: ScreenCaptureKit (composited window, WxH px)` or
  `capture path: cacheDisplay fallback`. This host has no Screen Recording TCC
grant (`SCShareableContent failed: … code=-3801`), so the committed corpus is
the **cacheDisplay** render — the same guest framebuffer, same 2560x1440.
- The guest's serial log is evidence, not a fixture: it is saved under the
gitignored `artifacts/`, and the capture is greppable to its marker there
  (`shot-web` appears in the log, and each file's release marker preceding it).

## M72c host scanout tape

On an Apple-silicon macOS 27+ host, record the Bubble Tea hello through the
same VMRunner framebuffer path:

```bash
bash tools/charmhello-tape.sh
```

The driver builds and seeds the real default Go seat, injects a HID `space`
into `CHARMHELLO.ELF`, captures `after` on the app's repaint marker before
GOTABWM can reap the single hosted tab, and saves `charmhello-{5s,10s,15s,after}.png` under
`artifacts/charmhello-tape/<timestamp>/`. They are 2560×1440 scanout captures,
not ANSI frame reconstruction. If host ImageMagick is installed, the same
frames are also encoded as `charmhello.gif`; otherwise the PNG sequence is the
portable tape output. `bash tools/charmhello-tape.sh --dry-run` prints the
output location without building or booting.

**One of the two things this corpus exposed is now asserted; the other is
asserted in `live-web` boot 13 and `go-wm-console-ink`.** Both were reported
on #1529 as observed, neither diagnosed there.

`gosh.png` is the *pre-fix* empty tab: GOTABWM opens and presents it
(`gotabwm: tab open id=3`, `host view id=3`, one `present`) while GOSH's own
`gosh: prompt` is green. M69g (#1558) measured the cause — the seat's own 96x64
client-death probe window painted its chrome over the tab's first terminal line,
a band that held **55** terminal-green pixels (all of them anti-aliasing from
the probe's white title text) and holds **578** after the fix. `go-dogfood`
**boot 03** now asserts that region directly (`green >= 200`, so a blank tab
fails the gate instead of passing silently). The committed `gosh.png` is a
capture from before that fix, so it still shows the empty band.

**The console-ink half is now asserted, in both boots it named.** Kernel
console text (`ks worker advances=…`) sits on the scanout wherever no window
covers it in the **shim web boot**. Re-measured in `live-web` boot 13 (#1592,
2026-09-21, macOS 27.2 / arm64, VZ): after `web: settled`, the band below
WEB.ELF's 40,28 512×384 window held **5.734% console-green at +3 s and
5.612% at +20 s** (82792 samples; the M69b ~5.8% 20 s figure, already at
plateau). That boot does not stage `GOTABWM.ELF`, so it is shim compositing
(`wm: autostart gotabwm: GOTABWM.ELF not on the share`) and the full-screen
kernel terminal is the desktop. `live-web` boot 13 PIXEL-asserts that shim
band (2–12%) so a blank capture cannot pass. A seated boot is a different
fact: `paint_scene` already skips the terminal, taskbar, and dock blits
while the seat owns the layer (M71c, #1562) and the tee's present still
flushes, which is what publishes the seat's pixels. Skipping that present
outright leaves the pre-seat console frame in the region the seat does not
repaint (measured 1789 console-green pixels). The default-seat probe is
`go-wm-console-ink` (#1561) and asserts console-green = 0. A serial-marker
beat cannot see this.

## Agent control channel (M98, issue #2145)

`go-agentd` is the ADR 0044 class-B gate: eight boots of `AGENTD.ELF` on
guest TCP 4747 behind an HMAC-SHA256 challenge, driven by the stdlib-only
harness `tools/agentctl/agentctl.py` over the runner's hermetic
`--net-tcp-connect-stream` adapter (stdin is guest->host, stdout is
host->guest, `AGENTCTL:` evidence rides stderr into the run log).

| run | proves |
|-----|--------|
| 01 | seat + `--allow-exec` + Calc (Calc execs on the first `ui.windows` request — the 16-slot task pool cannot hold four Go runtimes at once, so it is staged after the journey's `gosh.run` calls): the handshake, all six verbs green, the whole in-session D4 refusal matrix, the `gosh.run` kill path, a second peer's SYN refused while the session stays up, and `line_too_long` ending it. `ui.windows` rides the M97g-F2 bind: agentd opens its own undeclared window on the first call, walks the ownership challenge, and its bound kind-16 page requests quote the session token (`gotabwm: rpc bind id=` is the serial proof) |
| 02 | wrong MAC -> `auth_failed`, the 1 s damping, and an honest relisten |
| 03 | a `verb` line before auth -> `auth_required`, no request runs |
| 04 | a silent client -> `auth_timeout` inside 15 s |
| 05 | no `--allow-exec` and no seat: `gosh.run` absent from `verbs` -> `verb_disabled`, `ui.windows` -> `seat:"none"` |
| 06–08 | startup posture: `exec -u0` -> `refuse privileged`, a store with no `agent-hmac` row -> `refuse no-credential`, no `AGENT/` directory -> `refuse no-root` — each before any `listen` |

Two runs stage a different share through a run-local `--cvc-file` (the
runner takes the last assignment): `nocred-share` carries a `#v1` secrets
file with no `agent-hmac` row, `noroot-share` has the row but no `AGENT/`
directory. Every run asserts the key text, the `fs.write` payload
sentinel and the `gosh.run` stdout sentinel never reach serial.

Host prerequisites — build the four guest ELFs first; the spec refuses a
missing one by name:

```bash
bash tools/go/build-agentd.sh   # AGENTD.ELF (enforces the 2 MiB ceiling)
bash tools/go/build-gosh.sh     # GOSH.ELF (also hash-checked by fleet.sh)
bash tools/go/build-gotabwm.sh  # GOTABWM.ELF (run 01 seat)
bash tools/go/build-gocalc.sh   # GOCALC.ELF (run 01 window)
just gate go-agentd
```

Class-A coverage is `cd user/go && go test ./agentd ./shlib ./vi ./gotabwm`
for the guest side and `python3 -m unittest
tools/agentctl/test_agentctl.py` for the client: the pinned HMAC vector,
the flat-grammar reader differential against `encoding/json`, the D4 code
table, and the journeys run end-to-end against a wire-level daemon
simulation. The `gosh.run` capture contract is pinned as observed
(`shlib/agentline_observed_test.go`): the redirect captures builtin
stdout; an external app's fd-1 output bypasses it and `AGENTD.OUT` is
written empty; a pipeline naming an external refuses before any write.

## Virtio GPU 3D (M102, issue #2160)

`live-gpu3d` is the M102f2 class-B acceptance gate: eight independent
boots, each driving a guest Go app (`GPUTRIANGLE.ELF`) through the real
path — Go seat -> kernel GPU3D broker -> the opt-in custom-Virtio render
device (`--gpu3d-metal`, PCI DID `0x1083`, private VIR1 capset) -> a
Metal backend on the host — with the rendered surface CPU-composited
into the ordinary 2D scanout by the guest seat itself. This is a custom
VZ/Metal device implementing the project's own bounded VirGL-shaped
subset: native VZ exposes no 3D support at all, and nothing here is
QEMU, Venus or OpenGL.

| run | proves |
|-----|--------|
| 01 | triangle: declare/open/clear/triangle/present markers, the receipt TSV's submitted/completed/published rows, a real host Metal draw (`draws=1 gpu-completions=1`), the raw BGRA readback export against the pinned oracle, and the final scanout's red interior over the non-red clear field |
| 02 | mixed: the 64x48 render inside the larger surface — every margin pixel is the app's own 2D fill (guard rects) |
| 03 | resize: a second context generation at 96x64; both extent exports verified (the new frame cannot be the old one republished) |
| 04 | close/reuse: a second window generation publishes fresh pixels after a full close; counters back to baseline |
| 05 | native-only: no `--gpu3d-metal` -> named `unsupported`, the 2D seat still presents, zero 3D receipts on the share |
| 06 | malformed/auth: the invalid battery's named `invalid`/`closed` refusals, then a forged kind-17 frame refused at the seat's rpc seam — zero broker submissions for it |
| 07 | wrong/stale fence: the injected bad fence is caught (`stale-fences=1 retired-pending=1`), the frame is never published, 2D keeps ticking |
| 08 | stall/retirement: the suppressed fence hits the 2 s deadline -> named timeout + quarantine; a second exec drains and opens a fresh context |

Host prerequisites — build the guest ELFs first; the spec refuses a
missing one by name:

```bash
bash tools/go/build-gotabwm.sh
bash tools/go/build-gputriangle.sh
just gate live-gpu3d
```

Pixel evidence is the independent comparator
(`tools/gpu3d-proof/compare.py`, scene oracles in
`test/fixtures/gpu3d/pixels.json`): the raw BGRA export is rasterized
against pinned geometry — interior colour, clear field, guard bands,
opaque alpha — sharing no code with the renderer. Its self-test suite
(`python3 -m unittest tools.gpu3d-proof.test_compare`, 18 cases)
rejects blank, clear-only, channel-swapped, vertically flipped,
wrong-stride, stale and occlusion-wrong images and accepts the good
fixtures.

Named limits, so a green run is not read as more than it is:

- **CPU composition.** The 3D surface reaches the screen through the
  guest's surface mapping and the ordinary 2D present path — a real
  Metal draw read back and composited in software, not a hardware
  scanout plane and not shared-texture zero-copy.
- **Private profile only.** VIR1 is the project's own bounded subset —
  no Venus/VirGL conformance and no OpenGL claims are made, and none are
  tested.
- **Opt-in only.** Without `--gpu3d-metal` the boot is byte-identical to
  a native-only boot (run 05 pins `unsupported` with the 2D seat green);
  the render device never changes the default VM's device list.
- These are class-B gates (VZ + Metal on Apple silicon): they run where
  the class-B fleet runs, not on every push.

## FLINT source control (M103, ADR 0049)

`go-flint` is the ADR 0049 class-B gate for `FLINT.ELF`, grown across
M103a–d. Because later runs share `/host` state across boots, the spec is
not `vgate_repeat`-safe.

| run | proves |
|-----|--------|
| 01 | M103a (#2253): `FLINT.ELF parse-corpus /host/FLINTC` runs `go/parser` (`parser.SkipObjectResolution`) and FLINT's Go-native Zig declaration scanner in-guest over the 100-file corpus (50 `.go` + 50 `.zig`), prints `flint: parse files=100 atoms=245 parse_errors=0`, and writes `/host/FLINTC.OUT` byte-equal to the host's independent rendering of `MANIFEST.json` (`share-equals`) |
| 02 | M103b (#2251): `GOSH.ELF -c "source /host/FLINTJ/02.SH"` runs `FLINT.ELF init --name=w --src=/host/FLINTW`, adds the 245-Atom corpus, verifies idempotent re-add (`new=0 modified=0 deleted=0 unchanged=245`), applies `sample-body.go` (body edit + `const Answer` removal) and `sample-ws.zig` (whitespace/comments only), re-adds (`modified=1 deleted=1 unchanged=243`), and verifies `status` (`atoms=244 staged=244 add=244 modify=0 delete=0 duplicates=0`), `WORKSPACE.json`, and 244 unique UUIDv7 rows in `ATOMS.jsonl` |

Host prerequisites:

```bash
bash tools/go/build-flint.sh   # FLINT.ELF (8 MiB budget; bans crypto/*)
bash tools/go/build-gosh.sh    # GOSH.ELF (journey runner for runs 02+)
just gate go-flint
```

Class-A coverage is `cd user/go && go test ./flint/... && go vet ./flint/...`:
`TestCorpus` (100 corpus files vs `MANIFEST.json`), `TestPairs` (rename,
body edit, whitespace/comment, parameter edit, field reorder),
`TestRefusals` (`anon_ret.zig` -> `parse_unsupported`, `bad.go` -> `syntax`),
`TestCanon` (`testdata/canon/*.txt`), `TestZigOracle` (`zig run
tools/flint/zigdecls.zig` over all 50 `.zig` files), plus the `memFS` store
suite (`TestInitLayoutAndRefusals`, `TestUUIDv7MonotonicAndClockUnset`,
`TestAddIdempotentAndEdits`, `TestStageFoldRulesAndStatus`,
`TestParseErrorAndDuplicateDeclAllOrNothing`, `TestTornLineAndStoreBounds`).

## Verification sequence

Every `zig` command below must resolve to the pinned compiler: the version +
archive sha256s live in `tools/zig/lock.json` and `tools/zig/sdk.py`
materializes the pinned SDK into `.build/zig-guest` (offline-by-default,
checksum-verified, refuses concurrent substitution). Put
`$(python3 tools/zig/sdk.py prepare)` first on PATH — a shadowing `zig`
(e.g. Homebrew) must not win: it broke `verify-portable` during the M91
recheck and `live-web`'s kernel build during M93g. Upstream caveat: ZLS does
not work with 0.17.0 (maker/configurer split) — known issue, do not file.

1. Print the detected tool versions.
2. Check Zig formatting: `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig`.
3. Run the M1.5 kernel monitor module unit tests:
   `bash tools/verify-unit-tests.sh` — runs `zig test` on each module
   present in `kernel/src/` (console/handoff/memmap/monitor). Modules that
   have not landed yet are skipped with a notice, so the gate stays green
   on `main` and becomes binding branch-protection evidence once each
   module merges.
4. Run the automated transcript gate (M1.5 march step 19):
   `zig build test-console` (also `just test-console`; CI runs
   `tools/verify-transcript.sh`) — the shell module tests plus a byte-exact
   diff of the mock-console transcript against the canonical fixture
   `tests/transcript-console.txt`.
5. Build the Zig UEFI application: `zig build`.
6. Inspect the generated binary: `zig build inspect`.
7. Create the FAT disk image: `zig build image`.
8. Inspect the disk-image contents (part of `zig build inspect`).
9. Build the Swift VM runner: `swift build --package-path host/vm-runner`.
10. Boot with Apple Virtualization.framework (Apple silicon only):
    `zig build run`. Milestone two gates on `vm-serial.log` containing the
    exact banner `VirelaiOS kernel has seized control.`, a
    `memory-map descriptors=0x...` line, and `kernel terminal state`. The
    pre-exit loader marker `\\BOOTED.TXT` remains required. `RC.TXT` is
    expected only for a deliberate pre-exit failure fixture, not success.
    **Passing since 2026-08-08 (claim 1517)** — the post-MMU virtio TX
    blocker (translation start-level mismatch, claims 6460/7896) is fixed
    in production (T0SZ=16 + `tlbi vmalle1` at the switch); see
    `docs/status.md` for gate state.
11. Run the pre-exit failure-path gate:
    `bash tools/verify-bad-handoff.sh` (also `just verify-bad-handoff`) —
    boots a bad-magic fixture and asserts the loader's `RC.TXT` reads
    `kernel_rc=0x2`; **passing since 2026-08-06** (shim LR clobber fixed,
    claim 0001).
12. Run the ADR 0004 D4 marker fallback gate (gate work item 3, claims
    0009/0010): `bash tools/verify-marker.sh` (also `just verify-marker` /
    `zig build marker`) boots the VM and asserts the NVRAM marker ladder —
    the kernel persists each takeover stage as the EFI variable
    `VirelaiM2`, and the runner saves the ordered ladder to
    `artifacts/marker-dump.txt`. The gate passes iff at least one marker
    instance is present; the final stage names the death/crash site. Claim
    0009 observed the ladder ending at `M2_MAPD!` (MMU-takeover window);
    claim 0010 root-caused and fixed it — the ladder now runs
    `M2_MAPD! → M2_MMUP! → M2_SERIA → M2_READY`, i.e. the switch completes
    and the probe/transport are reached (decoded later, claim 0013 — the
    real console is a virtio-pci device outside the declared windows). The
    memory-dump form is impossible on VZ (guest RAM is not host-mapped —
    observed, claim 0009).
13. Run the claim-0015 NVRAM console gate:
    `bash tools/verify-nvram-console.sh` (also `just verify-nvram-console`;
    mechanism `zig build nvram-console`; Apple silicon only) —
    reconstructs the kernel's post-exit console stream from `efi-vars.bin`
    (takeover banner, memory map, probe record, shell banner, and real
    `version`/`mem`/`echo`/`help` output — 69–70 chunks); **passing since
    2026-08-07** (`artifacts/nvram-console-gate.txt`). The gate also found
    and fixed the ADR 0005 flat-loader relocation bug (const
    function-pointer tables are not relocated by the flat loader).
14. Run the M1.5 host-side console plumbing gate (march steps 4–7):
    `bash tools/verify-host-console.sh` (also `just verify-host-console`;
    Apple silicon only) — wires a stdin-backed serial attachment, tees
    guest output to terminal + `vm-serial.log`, and restores the terminal
    on exit/signals.
15. Save command output and logs under `artifacts/m2-*.txt`, including the
    probe output and the complete serial log. State blocked VZ capabilities
    precisely rather than inferring success.

> **Historical regression check (ADR 0002, resolved):** the `\KERNEL.TXT` content gate
> in `zig build run` is the regression check for the loader's
> content-at-`base+0` addressing invariant (ADR 0002). A future loader
> change that reintroduces the old `base+24` layout (the 24-byte DSK1
> header loaded into RAM) makes the kernel's `adrp`+`add` references read
> 24 bytes early, so `KERNEL.TXT` is not byte-perfect and the run gate —
> and therefore CI — fails immediately.
16. Generate the project snapshot: `zig build context` →
    `artifacts/context.md`.
17. Verify the multiagent coordination surface (claims as GitHub issues):
    `bash tools/status/verify-issue-coordination.sh` (also `just
    verify-coordination` and CI). Fetches the open issues labeled `claim`
    via `gh` and fails when two of them from different branches declare
    overlapping `- **Touches:**` files (one editor per file), or when an
    open claim has no Owner line with a backticked branch; claims with no
    comment/edit for 14+ days draw a warning. The old file-based tracker
    (`docs/claims/` + `docs/logs/`, deterministic IDs, generated indexes,
    the indexes-bot workflow) was deleted 2026-09-03.
18. Test the coordination tooling itself: `bash
    tools/status/test-coordination.sh` (also `just test-coordination` and
    CI) — positive/negative offline fixtures for the issue gate's parsing,
    overlap detection (exact + prefix-glob), blocked-claim exclusion,
    staleness warnings, the empty-tracker case, the weekly staleness sweep
    (`tools/status/sweep-stale-claims.sh` — detection plus its `claim:stale`
    label decisions: flag once per stale period, skip already-flagged
    claims, unlabel on fresh updates), and the real-time unlabel guard
    (`tools/status/unlabel-guard.sh` — the bot-vs-human decision the
    event-driven `unlabel-fresh` job runs, exercised against issue_comment /
    issues webhook payloads: human comments/edits unlabel, while the sweep's
    own warning comments and bot-driven events never do). All fixtures run
    in a throwaway sandbox with no network. The GitHub Actions workflow
    files are also linted with actionlint (`bash tools/lint-workflows.sh`,
    class A) so trigger/expression typos fail in CI instead of only
    surfacing when a workflow runs for real. The real-time path can
    additionally be rehearsed LIVE (manual): `just rehearse-unlabel`, or
    the `workflow_dispatch` of `.github/workflows/claim-rehearsal.yml`,
    creates a throwaway claim issue, marks it `claim:stale`, and verifies a
    real event removes the label before cleaning up. The full event cascade
    needs a human-scoped actor (a local collaborator's gh login, or the
    `CLAIM_REHEARSAL_TOKEN` PAT secret in CI — GITHUB_TOKEN events do not
    spawn further runs); without one the guard's live branch is exercised
    in-process against the throwaway issue.
19. Run the live RX / transcript gate (class B, claim 6684):
    `just gate live-transcript` (`tools/gate/specs/live-transcript.spec`) —
    boots the production image, forwards
    scripted keystrokes (`help`/`version`/`mem`/`echo`) into the guest's
    virtio receive queue after the takeover, and asserts the live
    `virelai>` transcript (banner, echoed commands, command output, echo
    reply) in `vm-serial.log`. **Passing 2026-08-08** (3/3 boots,
    byte-identical transcripts; evidence `artifacts/live-transcript-*`).

> The full class-A (portable, no-VM) gate set runs as `just verify-portable`
> (legacy alias `just verify`) and in CI (`.github/workflows/ci.yml`).
> **CI proves only this class** — a green badge says nothing about the
> Apple-silicon VZ hardware gates (class B).
>
> **Host prerequisites (class B):** the Go-runtime gates (`go-hello`,
> `go-args`, `go-goroutines`, `go-stress`, `go-panic`) are NOT hermetic — they exec
> `.build/go/GOHELLO.ELF` + `.build/go/GOARGS.ELF` + `.build/go/GOROUT.ELF`
> + `.build/go/GOSTRESS.ELF` + `.build/go/GOPANIC.ELF` (and `go-hello` also
> `.build/go/GOBIG.ELF` + `.build/go/GOREAD.ELF`, its M70c-K/M70c fixtures),
> and refuse to run (honestly, with the build
> hint) until `just go-toolchain` has provisioned this machine (it builds
> all of them). The recipe is idempotent; the first run takes several
> minutes (one Go make.bash pass — the cross-std pass is phase-2 opt-in
> via `GOVIRELAI_STD=1`). Do not auto-build the fork inside a gate
> (rejected in review — see `tools/go/README.md`).
>
> **The in-guest build gates** follow the same rule with two more host
> prerequisites, because they make the guest build with its own toolchain
> (M70c-S1T #1543, M70c-S2 #1544): `bash tools/go/build-gotool.sh` produces
> `.build/go/{GOCMDCOMPILE,GOCMDLINK}.ELF` (the GOOS=virelai toolchain images,
> built with the opt-in `virelaitoolchain` gate and asserted against every
> loader rule the kernel enforces), and `bash tools/go/stage-selfhost.sh`
> stages what the guest cannot produce for itself — the import config naming
> export data for the pinned fixture's closure, those 29 package archives
> (14.82 MiB), and the pinned source — into `.build/go/selfhost/`. `go-hello`
> runs 06-08 and `live-selfhost-go` are the gates that consume them, and
> `live-selfhost-go` also needs `bash tools/go/build-go.sh tools/go/selfhost.go`
> for `.build/go/GOSELFHOST.ELF`, the in-guest driver. All three refuse by name
> rather than boot a guest that cannot find its inputs.
>
> **The daily loop (M69e, issue #1532)** is the one class-B place where the
> harness itself compiles, and it is deliberate. `go-hello` runs 09-10 have the
> guest author `/host/LOOP.GO` with the monitor's `write` verb; the python hook
> on run 09 — evaluated *between* the two boots — builds that file on the Mac
> with `bash tools/go/build-go.sh`, and run 10 executes the image. No guest
> compiler is staged for these runs, and the host's receipt
> (`loop: host-built GOOS=virelai …`) is printed into the gate log, not the
> guest's serial: both runs assert it absent there. The hook refuses **before
> any boot** when `$GO_FORK_DIR/bin/go` is missing, so the "do not auto-build
> the fork inside a gate" rule above still holds — the fork must be provisioned
> by `just go-toolchain` first, like every other Go gate. The same loop driven
> by hand is `tools/go/README.md` → *Daily loop*.
>
> The class-B fleet is **discovered, not listed** (M40 GF5, issue #940):
> every `tools/gate/specs/*.spec` plus the four legacy class-B scripts
> (`bad-handoff`, `marker`, `nvram-console`, `host-console`), exactly as
> `bash tools/gate/fleet.sh list` prints. Run one with `just gate <id>`, a
> pattern group with `just gates <pattern>`, the whole fleet with
> `just verify-vz` (Apple silicon only — each member boots VZ VMs; the
> interactive serial-takeover gate `zig build run` needs a TTY and is run
> with `just run`). CI does not shard this list: `.github/workflows/vz-gates.yml`
> is a not-enforced placeholder until an Apple silicon runner is registered
> (then the fleet shards onto it per `docs/vz-runner.md`). The class-D diagnostics run individually per claim. See
> [`docs/gate-fleet-inventory.md`](gate-fleet-inventory.md) for the full
> per-member table.
>
> **Permanent rule (M40 GF6, issue #931):** new gates are specs under
> `tools/gate/specs/` — never new `tools/verify-*.sh` scripts (rejected in
> review); the generated inventory fails CI (`--check`) on any unregistered
> gate. Full-fleet reference wall time: 10,052 s serial (185 members, M40
> GF6 reference host, 2026-09-06).
>
> **Dev-shell PATH note (the one canonical paragraph):** fleet members and
> CI need the modern Homebrew toolchain — `/opt/homebrew/bin` FIRST and
> `/opt/homebrew/opt/gnu-sed/libexec/gnubin` for GNU sed, byte-for-byte
> what both workflows set up. Locally, `source tools/env-check.sh` (or
> `just check-env`) verifies the same thing and complains loudly when the
> 2007-era system bash/sed win instead.

## Go SDK class-A loop (the `user/go` module)

`cd user/go && go test ./...` is the SDK's class-A loop, and two things about
it are load-bearing rather than incidental:

- The module's single require, `virelai/tools/go/tabcodec`, is an **in-repo**
  module reached by a relative `replace` to `../../tools/go/tabcodec` (M62d) —
  not a fetched dependency. `virelai/ttf`'s import guard permits exactly that
  shape and still refuses a fetched one; `TestGoModGuardFixtures` keeps the
  refusal firing (#1607).
- `user/go/pulse` keeps its snapshot/row types (`types.go`) and the pure
  `derive.go` layer untagged, so the guest poller, the host stub and the pure
  layer all build with no tag and `./...` runs the pure layer's cases; only the
  Charm-dependent model/update/view files sit behind the `pulse` tag (host
  run: `go test -tags pulse ./pulse/` over the module-cache Charm the transient
  modfile in `tools/go/build-pulse.sh` names) (#1611).

## Gate fleet (M40 GF1–GF5, issues #934–#940)

- **No new `tools/verify-*.sh` files.** New gates arrive as vgate specs
  (`tools/gate/SPEC.md`); one-off per-gate boot scripts are rejected in
  review.
- **The spec dir is the single source of truth.** `tools/gate/fleet.sh`
  discovers the class-B fleet (specs + the four legacy class-B scripts);
  the `just gate`/`just gates`/`just verify-vz` recipes, the
  `vz-gates.yml` CI shards, and the fleet section of
  `docs/gate-fleet-inventory.md` are all derived from that discovery —
  adding a spec registers it everywhere with zero list edits.
- **The fleet inventory is generated, not written:**
  `bash tools/inventory-gates.sh` rewrites `docs/gate-fleet-inventory.md`
  (also `just inventory-gates`) as a local snapshot. Do not commit that
  file in a spec or script PR — GitHub then blocks parallel merges on a
  generated table. `just inventory-gates --check` (class A / CI) enforces
  spec-order and locale invariance; it does not require the snapshot to
  match. Adding a spec under `tools/gate/specs/` registers it via
  `tools/gate/fleet.sh` with zero list edits.
  `tools/lint-workflows.sh` asserts that every command in the
  `just verify-portable` recipe appears in `.github/workflows/ci.yml`, so a
  portable gate cannot go local-only again without failing that lint.
- `docs/gate-inventory.md` defines the class A/B/C/D policy only; the
  archive detail file (`docs/archive/gate-inventory-detail.md`) is frozen
  historical evidence — nothing reads its `GATE_INVENTORY` block anymore.

## Evidence artifacts

| Artifact | Produced by | Contains |
|----------|-------------|----------|
| `artifacts/inspect.txt` | `zig build inspect > artifacts/inspect.txt` | `file`, PE/COFF headers, sections, disassembly, FAT/GPT listing |
| `artifacts/vm-serial.log` | `zig build run` | Kernel serial probe, exact banner, map hex view, and terminal marker |
| `artifacts/efi-vars.bin` | VZ runner | Persisted EFI NVRAM; holds the `VirelaiM2` marker ladder after a marker-gate run |
| `artifacts/marker-dump.txt` | `zig build marker` / `verify-marker.sh` | Ordered M2_* NVRAM marker ladder (ADR 0004 D4 fallback) |
| `artifacts/m2-marker-gate.txt` | `verify-marker.sh` | Full marker-gate run log (2026-08-07: ladder ends `M2_MAPD!`) |
| `artifacts/context.md` | `zig build context` | Full deterministic project snapshot |
| `\LOADER.TXT` on the ESP | loader (`zig build run`) | Loader-observed placement and handoff-v2 jump inputs |
| `\RC.TXT` on the ESP | loader, only after pre-exit failure | Non-zero kernel status for the bad-handoff fixture |
| `\MEMMAP.TXT` on the ESP | boot stub, before handoff | Pre-exit EFI memory map evidence |
| `\KERNEL.TXT` on the ESP | milestone-one regression only | Not written after the kernel exits Boot Services |
| `artifacts/go-selftest-report.txt` | `go-selftest` spec (copied before `gate_end`) | The harness's own run report |
| `artifacts/go-selftest-share-*` | `go-selftest` spec (copied before `gate_end`) | The share evidence the spec byte-compared: the intake copies/receipts, the file-ABI receipts (`file-*.ok`) and read-back copies, and the `window.txt` receipt whose id/geometry the spec cross-checked against the kernel's `open:` line and TABWM's `tab-switch` line |
| `artifacts/go-selftest-share-<RELPATH>` | the `share-equals`/`share-contains` asserts (M61f), copied by the harness | The same evidence for the files the share kinds read — `share-SELFTEST_REPORT.txt` is the guest's own `/host/SELFTEST/REPORT.txt` (ADR 0031) |
| `artifacts/m2-probe.log` | kernel serial output | Candidate reads, signatures, selected transport, and observed/inferred decision |
| `\KERNEL.BIN` on the ESP | `zig build` | Flat kernel image, verified with `elf2bin.py --info` |

## How output is observed

- **Virtualization path (observed findings on macOS 27 / Apple M4; the
  project targets Apple silicon only, no QEMU path):**
  - The virtio serial console stays empty: Apple's EFI firmware does not
    route `ConOut` there.
  - The virtio-gpu framebuffer stays blank: the firmware renders no text
    console to it (captured PNGs are gray/black, OCR finds no text).
  - Therefore the guest also writes its message to `\BOOTED.TXT` on the
    ESP through the UEFI Simple File System protocol, and `zig build run`
    prints that file back from the host. The file's presence and exact
    content is the observed proof of execution on Apple silicon.

## Results log (as verified on the development host)

> Current pass/fail/blocked state lives in [`docs/status.md`](status.md);
> this log is the dated historical record, kept because it is labeled.

- [x] `zig build` compiles `BOOTAA64.EFI` (PE32+ EFI application, AArch64)
- [x] `zig build inspect` reports a valid AArch64 PE/COFF EFI application
- [x] `zig build image` creates a GPT+FAT32 image with `EFI/BOOT/BOOTAA64.EFI`
- [x] Virtualization.framework boot executed the guest (observed via
      `\BOOTED.TXT` on the ESP)
- [x] Milestone one remains covered by the historical evidence in
      `artifacts/m1-fix-run{1,2,3}.txt`.
- [x] Milestone two VZ serial/MMU takeover gate: **PASS 2026-08-08 (claim
      1517)** — `zig build run` puts the banner, memory-map print, and
      `kernel terminal state` in `vm-serial.log` (post-MMU virtio TX
      fixed: T0SZ=16 + TLBI at the switch). Historical path (pre-fix):
      the gate was **not passed** and the blocker was isolated. Every
      directly observed Apple M4 / macOS 27
      run produced no banner, map print, probe log, or terminal
      marker in `vm-serial.log`; no `RC.TXT` is produced (good path,
      expected). The early-post-exit-crash hypothesis is **closed**: claim
      0009's NVRAM ladder showed the death was in the MMU-takeover window
      (`M2_MAPD!`), and claim 0010 (2026-08-07) root-caused and fixed it —
      the MMU takeover now **completes** on VZ (ladder reaches `M2_MMUP!`)
      and the serial probe runs to completion, selecting no device in the
      declared windows (`M2_SERIA`; claim 0013 later decoded those windows
      as Apple's efivars store + an internal debug UART and found the real
      console is a virtio-pci device outside them). The post-MMU access
      blocker (claims 0018/0020) was root-caused by claims 6460/7896
      (translation start-level mismatch + stale-TLB crutch) and fixed in
      production by claim 1517 (T0SZ=16 + TLBI at the switch); the serial
      gate now passes.
      Evidence: `artifacts/m2-mmu-takeover-gate.txt`, `artifacts/m2-firmware-regs.txt`,
      `artifacts/m2-table-walk.txt`, `artifacts/m2-mmu-bisect-tlbi.txt`.
      The console device itself is observed (claim 0013); its register
      layout stays `[inferred]` where RX is concerned until the RX path is
      driven.
- [x] Milestone two marker fallback gate (gate work item 3, claims
      0009/0010): **passing** (2026-08-07). Claim 0009's ladder
      discriminated the serial gate: every run ended at `M2_MAPD!` — the
      identity map was built but the post-install `M2_MMUP!` stage never
      appeared, so the kernel died in the MMU-takeover window and never
      reached the serial probe. Claim 0010 then **root-caused and fixed
      it**: the ladder now runs `M2_MAPD! → M2_MMUP! → M2_SERIA` — the MMU
      switch completes on VZ and the serial probe runs to completion,
      finding no device in the declared windows (later decoded as Apple's
      efivars store + an internal debug UART — claim 0013 — which also
      found the real console is a virtio-pci device outside them;
      evidence: `artifacts/m2-mmu-takeover-gate.txt`,
      `artifacts/m2-firmware-regs.txt`, `artifacts/m2-table-walk.txt`,
      `artifacts/m2-mmu-bisect-tlbi.txt`). The VZ serial gate's historical
      blocker (post-MMU access to the virtio-pci console transport) is
      resolved by claim 1517 (T0SZ=16 + TLBI at the switch); the gate now
      passes.
- [x] Milestone two bad-handoff failure gate: **passing** (fixed 2026-08-06,
      `agent/buffy/m2-badhandoff-fix`). Root cause was the naked `_start`
      shim's `bl kernel_main` overwriting the link register without
      saving/restoring the loader's `x30`, so the shim's final `ret` looped
      forever and the kernel never returned. After the two-instruction fix,
      `verify-bad-handoff.sh` exits 0 and `RC.TXT` shows
      `kernel_rc=0x0000000000000002`. Evidence:
      `artifacts/m2-badhandoff-fix-{before,after,gates,goodpath}.txt`.
- [x] M1.5 live RX / transcript gate (class B, claim 6684): **passing
      (2026-08-08)** — `bash tools/verify-live-transcript.sh` (now `just gate
      live-transcript`) boots the
      production image, forwards scripted keystrokes (`help`/`version`/
      `mem`/`echo rx-live-ok`) into the guest's polled virtio receive
      queue after the takeover terminal state, and asserts the live
      `virelai>` transcript in `vm-serial.log` — banner, echoed keystrokes,
      `available commands:`, `virelai-kernel` version output, `mem:` map
      summary, and the `rx-live-ok` echo reply. 3/3 boots, byte-identical
      4421-byte transcripts. Evidence: `artifacts/live-transcript-*`
      (`live-transcript-gate.txt`, `live-transcript-report.txt`,
      `live-transcript-run-<NN>.txt`, `live-transcript-serial-<NN>.log`).- [x] M1.5 live FAT32 storage gate (class B, claims 3475/6420): **passing
      (2026-08-09, upgraded to the real FAT driver by claim
      6420)** — `bash tools/verify-live-fs.sh` (the script and the writable
      FAT path were both retired with M34 HF6 — `live-fs` gates the host
      share today) boots two VMs against the
      SAME disk image: run A (fresh image) drives `write hello.txt hello
      world` + `ls` + `cat hello.txt` and asserts the write-ok reply
      ("persisted .. bytes to FAT on the ESP"), the live volume listing
      (`EFI/`, `KERNEL.BIN`, `BOOTED.TXT`, `MEMMAP.TXT`, `LOADER.TXT`),
      `hello.txt` listed `[esp]`, and the cat reply; run B (fresh boot,
      same image) still lists `HELLO.TXT [esp]` (the FAT 8.3 short name)
      and prints the content — the file persisted through reboot **on the
      disk itself** via the virtio-blk transport (claim 3475's NVRAM
      persistence medium is replaced). 1/1 pair. Evidence:
      `artifacts/live-fs-*` (`live-fs-gate.txt`, `live-fs-report.txt`,
      `live-fs-run-<A|B>-<NN>.txt`, `live-fs-serial-<A|B>-<NN>.log`).

- [x] Milestone-three live gates (class B, claims 9187/5275/8215/3594/6120/
      5804/6729/6783/3200): **passing 2026-08-09/10** — live timer IRQ
      (claim 9187, 3/3, real periodic CNTP PPI 30 into the claim-9746 EL1
      IRQ vector), live tasks (claim 5275, tick-driven round-robin across
      real context switches), live EL0/SVC boundary (claim 8215, 1/1 —
      two sequenced pings prove return to EL0), live syscall-table gate
      (claim 3594, 1/1, exact snapshot `ping=2 write=3 yield=1 exit=1`),
      live uaccess (claim 6120, 1/1 — `valid=1 fault=1 recovered=1`: a
      real EL1 data abort during copy-in is recovered to EFAULT without
      crashing EL1), live address spaces (claim 5804, per-task TTBR0 with
      EL1-only kernel overlay), live lifecycle (claim 6729, spawn/exit/
      reap + idle reaper), live ESP exec (claim 6783, `USER.BIN` runs at
      EL0 from the ESP), and live blocking syscalls (claim 3200,
      sleep/wakeup in the tick scheduler). Full gate table:
      `docs/status.md`.

**Post-tag reverify (claim 7873, 2026-08-09):** the complete class A set
(just verify-portable: fmt, 95 + 110 unit tests, transcript gate, build,
image, inspect, swift runner build, context, coordination, coordination
tooling, mmu-debt) and the complete class B set (serial takeover
`zig build run`, bad-handoff, marker, nvram-console, host-console,
live-transcript, live-fs, live-timer, live-reboot, live-exceptions) were
re-run at the **`m1.5-interactive-monitor` tag (`74a51f3`, clean tree)**
— **all green**. Summary evidence:
`artifacts/gates-reverify-20260809-m15-tag.txt`.

**Milestone-three close-out reverify (claim 0707, 2026-08-10):** the
complete class A set (just verify-portable: fmt, unit tests,
test-console, build, image, inspect, swift runner build, context,
coordination, coordination tooling, mmu-debt — 11/11) and the complete
class B VZ set (serial takeover `zig build run`, bad-handoff, marker,
nvram-console, host-console, live-transcript, live-fs, live-timer,
live-tasks, live-userspace, live-svc, live-uaccess, live-addrspaces,
live-lifecycle, live-exec, live-sleep, live-reboot — 17/17) were re-run
at the milestone-three candidate HEAD `0c119d8` — **all green**; the
milestone is tagged **`m3-userspace`**. Evidence:
`artifacts/gates-reverify-20260810-m3-closeout.txt` +
`artifacts/classB-chunk{1,2,3,4}-m3-closeout.log`.

**Milestone-four close-out reverify (claim 2839, 2026-08-11):** the
complete class A set (fmt, unit tests, test-console, build, image,
inspect, swift runner build, context, coordination, coordination tooling,
mmu-debt — 11/11) and the complete class B VZ set (the full 28-gate
`verify-vz` aggregate: serial takeover `zig build run`, bad-handoff,
marker, nvram-console, host-console, live-transcript, live-fs, live-gfs,
live-timer, live-tasks, live-userspace, live-svc, live-uaccess,
live-addrspaces, live-lifecycle, live-exec, live-args, live-procs,
live-concurrent, live-long-lived, live-kill, live-sleep, live-entropy,
live-reboot, live-ipc, live-procs-syscall, live-scale, live-wait —
28/28) were re-run at the milestone-four candidate HEAD `9d7e4d5` on a
clean tree — **all green**; the milestone is tagged **`m4-processes`**.
Evidence: `artifacts/gates-reverify-20260811-m4-closeout.txt` +
`artifacts/m4-closeout-classA-1.log` + the per-gate `vz-live-*` logs.
