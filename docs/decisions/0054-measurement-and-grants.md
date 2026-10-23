# ADR 0054: Measurement is the trust key — verified+measured boot, measured exec, the grant table

- Date: 2026-10-16
- Status: **Accepted** — shipped by the M113 arc (#2386, closed):
  handoff is live (`kernel/src/handoff.zig:39`) and the grant table
  ships (`image/fleet-grants.txt:1`); this ADR is the card (#2417), and
  the M113 arc implemented it in the filed order: M113b verified+measured
  boot, M113c measured exec + grant table + enforcement (audit), M113d
  `ReleaseCaps` + GOSET consent, M113e trust viewer, M113f acceptance.
- Card: **#2417** (M113 index **#2386**) — card 1 of 6. This is the one doc
  for the arc (AGENTS.md: one doc per arc, not four).
- Related: ADR 0007 (syscall ABI — the slot groups the words map to; D10's
  additive-numbering rule covers the two new slots), ADR 0010 (file ABI),
  ADR 0023 D2 (kernel crypto stays kernel-local, drift-guarded by shared
  vectors — the precedent the measurement hash follows), ADR 0024 D5/D8/D10
  (trust baseline — extended, not revised; amendment notes land there with
  this ADR), ADR 0055 (M110a, in flight — the release manifest that carries
  a publisher's `ReleaseCaps` request), ADR 0051 (the arm-and-indicator /
  seat-mediator consent pattern the grant admin path reuses), ADR 0050
  (receipts live on `/disk`).

> One idea, two parts: **a SHA-256 measurement is the trust key** — for the
> boot stages in Part I and for every binary that gets power in Part II.
> Part I makes boot *verified + measured*: Virtualization.framework on the
> macOS 27 SDK has no TPM (observed: `grep -ril tpm` over its headers is
> empty) but does have UEFI Secure Boot (observed: a live probe, below);
> the firmware db pins `BOOTAA64.EFI`, the loader pins `KERNEL.BIN`, and
> the kernel publishes the chain as a receipt. Part II keeps `caps=` in
> `APPS.TXT` declarative and puts enforcement somewhere the file ABI cannot
> write: a kernel-owned grant table of `(name, sha256, words)` rows, applied
> at exec against a measurement made with the same primitive and receipt,
> and enforced at the existing `capability_gates` choke point plus one
> sub-op check at socket open. The publisher declares, the user decides,
> and ADR 0024 D5 stands: no EL0 path raises privilege. The arc ships in
> `audit`; `enforce` is a separate owner decision.

## Mission

Pin, before any implementation: the boot chain and its receipt format, the
named refusals, the opt-in runner posture (flags-off byte-identical), the
grant-table shape and its two EL0-unwritable sources, the exec-measurement
rule, the word → slot-group enforcement map, the declare/consent flow, the
audit-mode baseline, and the file-level split for M113b–e so those cards
land without renegotiation.

## Grounding (observed in tree `d0a14b6d` and on this host, 2026-10-16)

**[observed]** means checked in the tree, the Xcode 27 SDK headers, or
reproduced live on this host; **[inferred]** means reasoning only.

1. **VZ has no TPM.** `grep -ril tpm` over
   `$(xcrun --show-sdk-path)/System/Library/Frameworks/Virtualization.framework/Headers`
   returns nothing (Xcode 27.1, build 27A9275, SDK 27.0, host macOS 27.2
   build 26B5112a). **[observed]**
2. **VZ has UEFI Secure Boot** (`API_AVAILABLE(macos(27.0))`,
   `VZEFIVariableStore.h`): `enableSecureBoot(platformKey:)` (custom
   `SecCertificate`) or `enableSecureBootUsingDefaultPlatformKey`,
   `enrollSecureBootSignatures(_:)` with a
   `VZEFISignatureDatabaseConfiguration` (KEK/db/dbx arrays of
   `VZEFISignatureList`; db accepts `VZEFISignatureSHA256Hash`, also
   reachable as a 32-byte file through `VZEFISignatureList(contentsOf:)`),
   `getSecureBootEnabled`, `disableSecureBoot`, `resetSecureBoot`.
   **[observed]**
3. **The Secure Boot probe ran.** Throwaway harness under
   `artifacts/sb-probe/` (gitignored): an ObjC CLI that prepares a fresh
   `VZEFIVariableStore` per leg, enrolls a self-signed RSA-2048 PK and a db
   hash, and boots a copied disk image headless with a virtio-console
   serial log. Evidence markers are the ESP files the loader writes
   (`BOOTED.TXT`/`LOADER.TXT`/`MEMMAP.TXT`) plus serial bytes. Legs:

   | Leg | Image | db hash enrolled | Result |
   |-----|-------|------------------|--------|
   | 0 | stock `artifacts/disk.img` | Secure Boot untouched | **booted** — BOOTED.TXT written, serial 8527 B |
   | A | stock | **raw** file SHA-256 `bd7203d8…96fa1` | **refused** — VM stopped, serial 0 B, no markers |
   | A′ | stock | **Authenticode** PE digest `35de135d…5b5924` | **booted** — serial 8795 B |
   | B | tampered `BOOTAA64.EFI` (one byte flipped at 0x4000) | Authenticode digest of the *good* image | **refused** — VM stopped within ~0.4 s, serial 0 B, no markers |
   | C | same tampered image | Authenticode digest of the *tampered* image | **booted** — serial 8521 B |

   Three facts are therefore observed, not guessed: (a) the db SHA-256
   entry is the **PE/COFF Authenticode digest** — the image hashed in PE
   layout order skipping the CheckSum field, the security data-directory
   entry, and the certificate table — *not* the raw file hash; (b) a
   `BOOTAA64.EFI` whose digest is not in db is **refused by the firmware**:
   the VM transitions to `stopped` almost immediately with zero serial
   bytes and no ESP markers — the refusal is a halt, not an error return
   the guest could intercept; (c) enrolling the tampered image's own
   digest boots it, so enforcement is hash-matching, not incidental.
   **[observed]**
4. **The boot volume is exactly two files.** `artifacts/disk.img` carries
   `EFI/BOOT/BOOTAA64.EFI` (173,568 B) and `KERNEL.BIN` (16,547,208 B) and
   nothing else (`image/make-image.sh`, M34 HF6). The loader opens
   `\KERNEL.BIN` at `boot/src/main.zig:75` (`kernel_path`), parses the
   DSK1/KRN2 header, copies content to `EfiLoaderCode` pages, applies the
   KRN2 relocation table, and jumps; every failure path returns quietly to
   the firmware. The kernel never reads the boot volume after handoff.
   **[observed]**
5. **`caps=` is documented declarative.** `image/apps.txt:17-21` defines
   the vocabulary — `file window audio timer memory process debug net
   term` (the first seven are the WASM import contract's `Cap` names,
   `user/src/wasm.zig:134-142`, so one word means one thing) — and states
   "DECLARATIVE: nothing grants or gates power from this field". The file
   lives at `/host/APPS.TXT` on the guest-writable share and STORE rewrites
   it (`user/go/store/install.go`), so it can never be an enforcement
   source. **[observed]**
6. **The trust machinery this extends.** `capability_gates` is an explicit
   bounded table in `kernel/src/syscall.zig:454` queried through
   `gated(number)`; `OWNERS.TXT` is the fail-closed metadata file (a
   malformed line denies its path, `trust.zig`); `SECRETS.TXT` is
   secret-class *by construction* (`trust.ensure_secret_file` mints the
   `secret=true`/`0600`/`uid_system` entry even when `OWNERS.TXT` never
   names it — the file ABI can never read or write it); the M97g seat
   pattern (`clipboard_authorized`, `syscall.zig:2773-2777`: the registered
   WM seat pid or a cap) is the in-tree consent precedent; the M97g
   app-binding precedent (`SECRETS.TXT` fourth field +
   `trust.system_owned_key`) shows a name-only binding is forgeable and a
   `uid_system`-owned, write-bit-free path is what makes a name honest —
   the same reasoning a grant row's `sha256` field makes stronger by
   binding image *content*, not just image *name*. **[observed]**
7. **The exec path already reads the whole image.** `exec.zig` bounds an
   image by `exec_image_max` (32 MiB) and `elf.map_max` (64 MiB), staging
   or streaming it through a bounded buffer before mapping — the bytes a
   measurement needs are already in the loader's hands, so exec measurement
   costs the hash over bytes already read, not a second read. **[observed]**
8. **Slot 80 (`sys_socket`) is a multiplexed handle family** (`syscall_abi.zig`
   row 80; `handle_socket` at `syscall.zig:2521`): ops 0 `listen`, 1
   `accept`, 2/3 `read`/`send`, 4 `close`, 5 `ready`, 6 `shutdown`, 7
   `peer`, 8 `beginDns`, 9 `readDns`, 10 `connect` (M99g active open). The
   **open-class** ops are 0, 8, and 10 — the ones that create a new network
   channel; the rest operate on a handle the process already holds.
   **[observed]**
9. **Kernel crypto stays kernel-local.** ADR 0023 D2 forbids the kernel
   importing the M47 userland library (module-path + direct `zig test`
   gates); `csprng.zig` sets the precedent — a kernel-local primitive
   drift-guarded by shared test vectors. The measurement hash follows it:
   SHA-256 lives in `kernel/src/measure.zig`, pinned by the same
   known-answer vectors the userland library carries. **[observed]**
10. **No `sys_grant*` or `GRANTS.TXT` exists** anywhere in the tree; the
    next free syscall numbers are 88 and 89 (`syscall_abi.zig` ends at
    slot 87). **[observed]**

## Decision — Part I: verified + measured boot

### D1. The anchor is UEFI Secure Boot, not a TPM
VZ exposes no TPM, so "measured boot" in the TPM sense is impossible on
this platform; the available anchor is **verified boot**: the firmware
refuses an image whose Authenticode digest is not enrolled in db. The
probe (Grounding 3) observed the refusal mode — a firmware halt, outside
any code the guest controls, which is exactly the property the chain
needs: no guest path can catch, skip, or downgrade it.

The runner enrolls a **custom Platform Key** (`enableSecureBoot(platformKey:)`)
plus a db containing the Authenticode SHA-256 of the built `BOOTAA64.EFI`.
KEK and dbx stay empty; the default Microsoft signatures are *not*
enrolled (nothing in the boot path is Microsoft-signed, and an empty db is
a smaller trusted set). The PK is a build/test credential: it exists to
pin db contents, not to establish a software publisher identity.

### D2. The chain: firmware db → loader → kernel
1. **Firmware verifies `BOOTAA64.EFI`** against db (Authenticode digest —
   the observed convention, Grounding 3).
2. **The loader verifies `KERNEL.BIN`.** The built `KERNEL.BIN`'s raw
   SHA-256 is carried in the loader image (a build_options constant —
   `build.zig` computes the digest after `elf2bin` and before the loader
   compile; the carrier detail is M113b's). The loader hashes the bytes it
   already reads (`kernel_path` open → header → content), and on a
   mismatch **refuses to jump**: it writes the named refusal
   `kernel_hash_mismatch` to the ESP and returns to the firmware, which
   halts the VM as in the probe. Because the loader's own digest is in db,
   the db transitively pins `KERNEL.BIN` — and transitively the
   `KERNEL.BIN`-compiled base grant rows of Part II.
3. **The kernel publishes the receipt.** One bounded record per stage in
   the D4 format, emitted on the serial channel at boot and made available
   to the host verify path (D5); M113b picks the second publication
   surface (share file or `/disk` receipt) inside that card.

### D3. A mismatch is a named refusal, never a degraded boot
The chain fails closed at every stage:

| Stage | Refusal name | Who refuses | Observable |
|-------|--------------|-------------|------------|
| `BOOTAA64.EFI` | `sb_refused` | firmware | VM halt before loader runs (probe-observed mode: stop, 0 serial bytes, no markers) — the *absence* of the boot receipt is the evidence |
| `KERNEL.BIN` | `kernel_hash_mismatch` | loader | ESP receipt + ConOut line, then return-to-firmware halt |
| exec image | `grant_stale` | kernel | exec refuses; a receipt (Part II) |

### D4. The receipt format: `(stage, sha256, verdict)`
One line per measurement, space-separated `key=value`, printed to serial
and carried on the M113b publication surface:

```
RCPT stage=<word> sha256=<64-hex> verdict=<word> [name=<image>] [word=<cap>]
```

- `stage` ∈ `loader | kernel | exec` — `exec` reuses the format verbatim
  for Part II's per-exec measurements (with `name=` the image name and
  `word=` the denied word on an audit denial).
- `sha256` is the digest *of the convention the stage pins*: the
  Authenticode digest for `loader`, the raw-file digest for `kernel` and
  `exec` (the kernel hashes bytes it holds, not a PE parse).
- `verdict` ∈ `measured | refused:<name> | audit:<name>` — `measured` on a
  pin match or an unlisted binary; `refused:` carries the D3/Part-II
  refusal name (`kernel_hash_mismatch`, `grant_stale`); `audit:` carries a
  would-be denial's name under Part II's audit mode (`audit:word_denied`).

A boot that runs to userspace therefore ends its receipt with the loader
and kernel `measured` lines; a refused boot produces *no* receipt — the
missing line is the signal, which is why the host verify path (D5) checks
for presence, not just content.

### D5. The host verify path and the opt-in flag
The host computes the same Authenticode digest of `BOOTAA64.EFI` (the
algorithm is small and fixed: hash in PE layout order, skipping CheckSum,
the security-directory entry, and the certificate table — the probe's
`pe_hash.py` is the reference) and enrolls it; the gate then compares the
guest's published receipt against the enrolled digests. A `--secure-boot`
runner flag family (PK cert path, db hash or hash list, per-run variable
store) turns the feature on; **flags off is byte-identical**: the variable
store is created without Secure Boot, the disk and every other device are
unchanged, and the boot default does not move (ADR 0024 D11's rule). The
production runner change is M113b's; the probe harness stays under
`artifacts/` and never enters the build.

## Decision — Part II: measured exec and the grant table

### D6. `caps=` stays declarative, forever
The `apps.txt` header stays literally true: `caps=` is a request and a
display, never the enforcement source, and `/host/APPS.TXT` remains
guest-writable. STORE may *propose* rows from a signed `ReleaseCaps`
(D11); `caps=` itself grants nothing.

### D7. Enforcement reads a kernel-owned grant table
The table is a bounded set of rows **`(name, sha256, words)`**:

- `name` — the image name as exec records it (the same name M97g's label
  binding and `sys_procs` rows carry);
- `sha256` — the raw-file digest of the image the row applies to, or the
  literal `*` wildcard;
- `words` — a comma-separated subset of the `caps=` vocabulary (one word
  means one thing, Grounding 5).

Rows are **bounded** (a fixed table; full ⇒ `ENOSPC`, never silent
eviction) and parsed **fail-closed like `OWNERS.TXT`**: a malformed row is
treated as a mismatched row for its name (its binary refuses
`grant_stale`), never silently dropped into the baseline; a non-`#v1`
schema refuses the file entirely. Two sources, **neither writable through
the file ABI**:

- **Base rows** are compiled into `KERNEL.BIN` — chosen over any boot-volume
  file because the kernel never reads the ESP after handoff (Grounding 4)
  and because Part I's chain makes a compiled-in row verified by
  construction: a tampered base table changes the kernel digest and the
  loader refuses at D2.
- **User rows** live in `GRANTS.TXT` on the host share, **secret-class by
  construction exactly like `SECRETS.TXT`** (ADR 0024 D8): the kernel
  mints the `secret=true`/`0600`/`uid_system` metadata entry itself at
  load and at boot even when the file is absent, so the file ABI — the
  only write path an EL0 process has — can never read or modify it. Its
  contents are policy, not a secret; the class is taken for *integrity*
  (the file ABI is the EL0 write surface), and posture is revealed through
  the query slot (D9). In-guest writes go through **one admin slot**,
  `sys_grant_admin` (slot 88 — additive per ADR 0007 D10), gated like the
  M97g clipboard pair: the registered WM seat or `CAP_PROC_ADMIN`, never
  the app the row names.

### D8. Exec measures
When a row names the binary being exec'd, the kernel SHA-256s the image
bytes it is already loading (Grounding 7 — no second read, the Part I
primitive and receipt):

- **match** → the row applies: the process's word set becomes the row's
  `words` (a narrowing), intersected with the baseline;
- **mismatch** → exec refuses `grant_stale` and **never falls open** — a
  named row whose hash is wrong is evidence the image is not the granted
  one, so it gets no grant and no baseline;
- **no row** → the **baseline** word set (all words at ship — today's
  ambient authority, so a flags-off app is byte-identical);
- **a row that grants anything above the baseline must be hash-bound**: a
  `*`-sha256 row may only narrow, because name-only rows are forgeable by
  construction (exec takes a caller-authored path string; a wildcard row
  granting beyond baseline would be claimable by any renamed binary). The
  parse enforces this fail-closed: a non-hash-bound row whose words exceed
  the baseline is refused at load as if malformed.

### D9. One choke point: words → ADR 0007 slot groups
Each word names a group of ADR 0007 slots. Enforcement is a per-process
word mask checked at **the existing `capability_gates` seam** — the table
grows word-gate rows queried through the same `gated()`-style lookup at
dispatch — **plus one sub-op check at socket open** for `net`, because
slot 80 is a multiplexed handle family (Grounding 8): the check fires on
the open-class ops `0 listen`, `8 beginDns`, `10 connect`; handle
operations on an already-open socket are covered by the fact that a
process without `net` can never have opened the handle. Enforcement is
**kernel-only**: the host relay sees Ethernet frames, not guest pids, so
no host process can name a caller (the M113 review's recorded inference,
adopted as the decision).

The word → slot-group map (the declared default M113c lands):

| Word | Slots (ADR 0007 numbers) |
|------|--------------------------|
| `file` | 23–27, 34–37, 69, 77, 79 |
| `window` | 12–22, 46, 47, 49–51, 53, 55, 58, 61, 65 |
| `audio` | 42–45 |
| `timer` | 40, 41 |
| `memory` | 63, 64 |
| `process` | 5–8, 28, 29, 54, 56, 57, 68, 73–75, 81–83, 87 |
| `debug` | 0, 1, 3 |
| `net` | 9–11, 30–33, 59, 60, 62, 76, 84–86, and slot 80 open-class ops 0/8/10 |
| `term` | 67, 71 |

Slots in no group (4 `sleep`, 66/78 `time`, 72 `getrandom`, and any
ungated remainder) stay open in every word set — they are services, not
powers. The query/read surface for the trust viewer is `sys_grant_query`
(slot 89 — additive per ADR 0007 D10): it returns the caller's own word
mask and the row that produced it, nothing more.

### D10. The publisher declares, the user decides
A signed `ReleaseCaps` in the release manifest (ADR 0055, M110a) is a
*request*: STORE reads it at install/update and proposes a `(name,
sha256, words)` row — the manifest's signed release atom supplies both the
name binding and the digest. **GOSET consent writes the row** through the
seat-gated admin slot (D7): the registered WM seat is the user's gesture
mediator, so the write is user-mediated by construction. An update that
does not widen its `words` keeps its grant silently; a widening update
asks again — the proposed row's word set is compared, and only a strict
superset needs a fresh consent gesture. Nothing the publisher signs
becomes power until a seat-held write lands it in `GRANTS.TXT`.

### D11. D5 holds — no EL0 elevation
No EL0 path raises privilege. The grant table is applied by the kernel at
exec from sources EL0 cannot write except through the consent path (the
seat-gated admin slot, which is not the app). Word masks only *remove*
power relative to the baseline; `uid` and the `caps` bitmask are untouched
— a granted process is still `uid_user` with no capability bits, and
`cap_fs_any`/`cap_proc_admin`/`cap_clipboard` remain spawn-time kernel
properties exactly as ADR 0024 D5 writes them. The M97g image-name
squatting residual is *narrowed* here: a name alone could claim a label
today, but a hash-bound row refuses `grant_stale` — the residual shrinks
to wildcard rows, which can only narrow.

### D12. Baseline: the arc ships `audit`
The enforcement mode is a `#v1` header field of `GRANTS.TXT`
(`mode=audit|enforce`, absent = `audit` — defaulting inside the
secret-class file keeps the switch off the writable surface for EL0;
host-side file replacement stays provisioning, the same trust level as
`SECRETS.TXT`). Under `audit` the kernel computes grants, applies the
exec-measurement refusals (`grant_stale` is a real refusal — it protects
row integrity, not word policy), and emits `audit:word_denied` receipts
for every would-be word denial *without refusing the syscall*: grants only
narrow, D5 stands verbatim, and a flags-off boot is byte-identical.
Flipping to `enforce` changes a default, so it is a separate owner
decision and card (M113f collects the audit data that informs it).

## Card split — file-level Touches

The lanes are serial (a → b → c → d → e → f); Touches are paths the card
edits, so later cards do not collide.

| Card | Issue | Delivers | Touches |
|------|-------|----------|---------|
| M113b | #2418 | Runner `--secure-boot` flag family + PK/db enrollment; loader's KERNEL.BIN pin + `kernel_hash_mismatch`; kernel receipt publication | `build.zig`, `boot/src/main.zig`, `kernel/src/main.zig`, `kernel/src/measure.zig`, `host/vm-runner/Sources/VMRunner/main.swift`, `tools/gate/specs/` (one spec) |
| M113c | #2419 | Grant table + `GRANTS.TXT` secret-class registration + exec measurement + word gates at `capability_gates` + slot-80 open-op `net` check, in audit mode | `kernel/src/grants.zig`, `kernel/src/measure.zig`, `kernel/src/exec.zig`, `kernel/src/process.zig`, `kernel/src/syscall.zig`, `kernel/src/syscall_abi.zig`, `kernel/src/socket_core.zig`, `kernel/src/socket_native.zig`, `kernel/src/trust.zig`, `tools/gate/specs/` (one spec) |
| M113d | #2420 | `ReleaseCaps` read in STORE; GOSET grants pane + consent write through `sys_grant_admin` | `user/go/store/release.go`, `user/go/store/install.go`, `user/go/store/manifest.go`, `user/go/goset/grants.go`, `user/go/vi` (admin-slot glue) |
| M113e | #2421 | GOTOP trust viewer: posture rows from `sys_grant_query` | `user/go/top/*` |
| M113f | #2422 | Acceptance: audit data for the enforce decision; status row; index closure | `tools/gate/specs/*`, `docs/status.md` |

## Consequences

- A tampered `BOOTAA64.EFI` is stopped by firmware before any guest code
  runs — the strongest refusal mode this platform offers, observed.
- The kernel's trust in its own base grant table is transitive: compile a
  different table and the loader refuses the kernel image.
- `caps=` keeps telling the truth; enforcement moves to a table the file
  ABI cannot write, resolving the documented red flag without reversing
  the contract.
- The kernel gains a kernel-local SHA-256 under the ADR 0023 D2
  drift-guard pattern (shared vectors pinned in both test roots).
- Audit mode means the arc's enforcement lands observable-first: every
  would-be denial is a receipt before it is a refusal, and M113f's
  enforce decision is made on data, not on faith.

## Rejected alternatives

- **A vTPM anchor.** VZ exposes none — observed, not guessed (Grounding 1).
  The ADR title says "verified + measured" rather than "measured" for
  exactly this reason.
- **Enforcement from `APPS.TXT`/`caps=`.** The file is guest-writable and
  STORE rewrites it; a manifest row is a request, never a source
  (Grounding 5). Reversing the DECLARATIVE clause was rejected — the grant
  table is the honest fix.
- **db pinning by raw file SHA-256.** Observed refused (probe leg A); the
  platform convention is the Authenticode digest, so the chain pins that.
- **Base rows on the boot volume or the share.** The ESP is dead to the
  kernel post-handoff and the share is host-replaceable outside the
  verified chain; compiled-in rows are covered transitively by the db pin.
- **Host-side enforcement at the relay.** The relay sees frames, not pids;
  enforcement is kernel-only (D9).
- **Enforce mode now.** Flipping a default is an owner decision on audit
  data, not an ADR's convenience (D12).
- **`getEnrolledSecureBootSignatures` as the gate.** Readback verifies the
  *store*, not the *boot*; the probe's halt/refusal observation is the
  real evidence.

## Open issues

- Whether the second receipt publication surface is a share file or a
  `/disk` receipt (M113b picks; ADR 0050 owns `/disk` semantics).
- The `ReleaseCaps` field shape inside ADR 0055's manifest (M110a is in
  flight; M113d conforms to whatever lands).
- Whether `enforce` mode and a narrowed baseline (e.g. baseline minus
  `net`) belong to one owner decision or two (M113f's data informs it).
