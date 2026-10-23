> ARCHIVED 2026-10-23 — design record for the shipped M34 host file channel;
> the binding ABI is ADR 0007. Not an active plan.

# Host file channel (FAT-free storage) — scoping sketch and gated card split

Status: **FILED — M34 seed issue #727, split into per-card issues
HF1–HF7 (#735–#741); milestone #21, label `m34-host-file-channel`** ·
Date: 2026-08-31 ·
Derived from: the custom-virtio control plane (claims 3141/9588/9367/0680),
the FAT32 storage driver (claims 6420/3678), ADR 0010's userland FS ABI, and
the M32/33 window-manager work (WMS1–WMS9, seam B).

> This document turns a recurring design conversation into a concrete,
> gated, milestone-shaped proposal. The goal is simple: **get the guest off
> FAT32 for everything user-visible.** The only FAT left is the ESP boot
> volume — parsed by Apple's firmware pre-exit, never touched by guest code
> after boot. That means the kernel's own FAT driver, the DATA partition,
> the post-exit virtio-blk path, and the embedded-apps machinery can all be
> deleted. It is NOT a commitment to start — it is the seed for the issue.

## The one-line pitch

Make the guest's user-visible filesystem **a macOS folder**: a small file
protocol over the existing custom-virtio device (DID 0x1082), served by the
host runner with plain Swift `FileManager` calls. No guest filesystem format
to own, no disk image to manage, no FAT to maintain. The Mac is the disk;
the guest just uses it.

## Current-state survey (what this builds on)

- **The custom-virtio device already exists and is proven.** The runner
  attaches `VZCustomVirtioDeviceConfiguration` (VID 0x1af4 / DID 0x1082,
  claims 5844/0828/9737); the guest driver `kernel/src/virtio_custom.zig`
  arms up to five split-ring queues today (`--cvc-snap`). The hard parts are
  all done and live-gated: host→guest pushes into pre-armed buffers
  (claim 3141), byte-exact round trips, checksummed multi-descriptor
  payloads (claims 9492/0680), and the rule that **queue count is the
  capability signal** (each optional queue is probed through the common
  config's `queue_size`; zero = absent, everything upstream byte-identical).
- **The polled guest transport is load-bearing and disciplined.** `submit_ex`
  / `wait` / `free_chain_q` on a ring with a bounded budget; the
  claim-0680 lesson (polled sends MUST free their descriptor chains) is the
  pattern any new queue follows.
- **FAT32 is load-bearing only for convenience.** `kernel/src/fat.zig`
  (~2,100 lines) + the post-exit `virtio_blk.zig` path exist to serve:
  (a) `exec` + `APPS.TXT` loading apps off the ESP at runtime, (b) `ls` /
  `cat` / `write` on the ESP (debug convenience), (c) the DATA partition
  (`/data` — notepad, settings, calc history, downloads, screenshots, shell
  history, clipboard persist). The ESP itself must be FAT (UEFI mandate)
  but is parsed by firmware — the loader reads it through EFI Simple File
  System pre-exit, so **zero lines of guest code need to speak FAT** once
  (a)–(c) move.
- **The disk image is the operational pain.** `make-image.sh` embeds ~50
  apps into the ESP at build time (the iteration bottleneck: rebuild the
  image to test an app); `image/mkfat32.py` builds a 128 MiB image with a
  second 36 MiB DATA volume (claim 3678 — FAT32 purely to reuse the driver);
  every class-B gate juggles **private writable image copies + shared-disk
  locks** (`gate_shared_disk_lock`) because the guest writes to DATA during
  tests. All of it exists to serve storage the guest shouldn't own.

### Sizing facts that shape the design

- Custom-virtio today: 5 queues max (0 exchange · 1 log · 2 push · 3 input ·
  4 snapshot). A file channel is **queue 5** → 6 queues under `--cvc-file`,
  deepest flag implies the full shape below it (unchanged rule).
- `virtio_custom.zig` is 1,836 lines and `VirtqRing` is `[max_queue_probe]`
  — probing queue 5 grows that array by one ring (~900 B BSS). The kernel
  has an 11.0 MiB BSS budget gate (`tools/verify-bss-budget.sh`, ADR
  0013 D3.1); new client
  buffers must stay small and bounded.
- Reply sizing for a first slice: **32 KiB reply cap** (the proven snapshot
  chunk size, claim 0680), **READ carries an explicit offset** so big files
  stream statelessly (no handles — the host holds zero state between
  requests, so an untrusted guest cannot leak host fds), LIST ≤ 128 entries
  (matches `fat.max_root_slots`; 40×128 = 5 KiB, fits trivially), paths ≤
  255 bytes. The honest-truncation discipline from `fat.cat` carries over.
  Validated in HF1: a full-cap 32 KiB **device-write reply** is a modest
  extension of the proven large-payload paths (claim 9492/0680 were
  device-read) — one explicit acceptance case, not an assumption.
- Deleting the DATA partition + embedded apps shrinks the boot image from
  128 MiB to a few MiB (loader + kernel + boot assets) — and because the
  guest never writes its boot volume post-boot, all class-B gates can share
  **one read-only boot image** (no private copies, no shared-disk locks).

## Design sketch

### 1. The wire protocol IS the filesystem

Guest → host requests and host → guest replies over queue 5. Request
(device-read payload): `[op u8][flags u8][len u16le][payload]`. Reply
(device-write buffer): `[status u8][dlen u16le][data]`. Status: 0 ok,
1 not found, 2 is a directory, 3 truncated (reply too small), 4 host error.

Opcode surface (start minimal, grow honestly — the opcode set IS the FS API):

| Op | Meaning | Needed for |
|----|---------|-----------|
| VF_PROBE (0x00) | transport spike — 32 KiB device-write reply, never served from the filesystem | HF1 acceptance case A |
| LIST | list a directory (40-byte DirEntry rows) | `ls` |
| READ | read a file at an offset (stateless streaming) | `cat`, exec loading |
| STAT | size / type / mtime | `stat`, exec validation |
| OPEN / CLOSE | handles for write cursors + read-modify-write | mutation (HF3) |
| WRITE / TRUNCATE | mutation | notepad, settings, downloads |
| RENAME / MKDIR / DELETE | filesystem depth | file manager, apps |
| FSYNC | durability | honest persistence |
| CLONE | APFS `clonefile` (COW) | **worktree dedup** |

The host side is Swift `FileManager` calls rooted at the shared directory,
with traversal defense (resolve the subpath within the share root; reject
`..`, absolute paths, symlink escapes). Wire format gets a section in
`docs/hardware-contract.md` like every other channel.

### 2. Guest surface

A new client module (`kernel/src/virtio_file.zig`, mirroring how `fat.zig`
sits on `virtio_blk.zig`) with pure, host-testable encode/decode plus a
bounded polled transport on queue 5. First user surface: `vf ls [<path>]`
and `vf cat <path>` monitor commands (storage category) that print an honest
"no host file channel" line when queue 5 is absent — default boots stay
byte-identical.

### 3. FAT-free end-state (the deletion story)

| Current feature | Moves to | Fate of FAT |
|-----------------|----------|-------------|
| `exec` / `APPS.TXT` app loading (ESP) | host folder — drop a `.ELF`, exec it | FAT driver no longer needed for apps |
| `/data` user persistence | host folder | DATA partition deleted |
| `ls`/`cat`/`write` on ESP | `vf` commands on the share (ESP stays firmware-only) | post-exit FAT reads gone |
| 128 MiB image + embedded apps | boot volume only (loader + kernel) | image builder slims down |
| per-gate writable image copies + locks | one shared read-only boot image | gate fleet simplifies |

End-state: the guest never speaks FAT after boot; `fat.zig`, the post-exit
virtio-blk path, the DATA partition, and the embedded-apps machinery are
deleted. The only FAT32 left is the boot volume format, parsed by Apple's
firmware — the "tiny amount required" is literally zero lines of our code.

### 4. Dedup (the worktree workload)

The motivating workload is many Git worktrees of the same repo — the classic
redundancy case. Facts: APFS has **no automatic dedup**; its mechanism is
`clonefile` (COW clones — copies share blocks until modified). So the file
channel carries a **CLONE opcode (`0x0c`)** mapped to APFS COW semantics:
creating a worktree clone is COW, and N worktrees of one repo share blocks
until a worktree actually edits a file. Whole-file dedup at clone
granularity is nearly the entire win for worktrees (unchanged files
dominate across worktrees; only branch-differing files diverge).

**Delivered (HF7, issue #741, claim 1312 — 2026-09-02).** The op rides the
same stateless NUL-framed wire as RENAME: `vf clone <from> <to>` in the
monitor; the runner resolves BOTH subpaths with the standard traversal
defense, then clones regular files with `Darwin.clonefile(2)` and
DIRECTORY TREES with `copyfile(3)` + `COPYFILE_ALL | COPYFILE_CLONE |
COPYFILE_RECURSIVE` (the clonefile(2) man page explicitly prefers
copyfile(3) for directories); `to` must not exist (→ status `5`, plus an
EEXIST race fallback). The gate's measurement is honest about what du
cannot see: `du` reports logical `st_blocks`, so a clone and a `cp` copy
of the same fixture report IDENTICAL numbers (observed). The physical
proof is the volume-level used-space delta (`os.statvfs` before/after):
3 `cp -R` copies of a ~7.5 MiB repo measured ≈ 22.5 MiB while 3 page-
channel clones measured ≈ ~0, and appending 512 bytes to ONE worktree
file left the untouched siblings sha256-identical to the repo (byte
compare) with a small observed delta. Raw before/after numbers live under
`artifacts/m34-hf7-measurement.txt` (saved by the gate, never asserted
as a constant).

**Alternative, still the bigger hammer:** point the share at a volume that
does its own dedup/snapshots and the channel inherits it with ZERO guest
code — every VF op is a stateless `FileManager`/path call rooted at
`--cvc-file <dir>`, so the device underneath can be anything. Options,
honestly scoped: (1) **ZFS-backed share** (OpenZFS on macOS via a kext/
MacFUSE system extension — `zpool` + `zfs set dedup=on compression=on` on
the share volume): true BLOCK-LEVEL dedup (identical content anywhere in
the tree collapses, not just whole-file clones) plus snapshots/rollback
(`zfs snapshot` while the guest is quiesced; an untrusted guest can never
snapshot — the HOST owns the pool). Costs: third-party kernel extension,
not the default APFS experience. (2) **APFS local snapshots** on the
share's own volume (`tmutil localsnapshot` or `diskutil apfs addSnapshot`):
snapshots + rollback for free, still whole-file COW rather than block-
dedup — strictly less than ZFS for dedup. (3) **Clonefile is the default
story** and is what HF7 proves: near-zero sysadmin, captures the worktree
win, and an edit in one worktree never duplicates untouched siblings.
Explicitly NOT: writing dedup into a guest filesystem (ZFS-grade chunked
content-addressing is research-grade; the guest has no redundant workload
beyond worktrees, and clones capture it).

## Gated card split

| # | Card | Depends | Gate |
|---|------|---------|------|
| HF1 | **Wire + transport** — queue 5 (`--cvc-file <dir>`, 6 queues), framing, `virtio_file.zig` client (LIST/READ-with-offset/STAT encode + decode), host-side Swift server rooted at the share dir, host wire-format tests on BOTH sides, full-cap 32 KiB device-write reply case — **issue #735** | — | host tests green (encode/decode byte-parity guest↔host); `--cvc-file` attaches 6 queues; BSS budget re-run; all existing custom-virtio gates byte-identical |
| HF2 | **First user surface + live proof** — `vf ls` / `vf cat` monitor commands; class-B gate boots with a share dir holding a fixture file **larger than the 32 KiB reply cap** and asserts the guest lists it and streams it byte-exactly across ≥ 2 round trips (`vf cat` prints the STAT byte count first) — **issue #736** | HF1 | `tools/verify-live-vf.sh` PASS on VZ; default boot unchanged |
| HF3 | **Mutation** — OPEN/CLOSE/WRITE/TRUNCATE/RENAME/MKDIR/DELETE/FSYNC; class-B gate writes to the share, host verifies the file on disk — **issue #737** | HF2 | live gate PASS (write → host-side verification); honest caps |
| HF4 | **App delivery migration** — exec from the host folder, desktop manifest re-pointed, drop-`.ELF`-and-exec workflow; the image-rebuild loop dies — **issue #738** | HF2 (HF3 for write-if-needed) | ✅ **done 2026-09-01 (PR #749, claim 7599)** — live gate `verify-live-vf.sh` PASS 4/4 on VZ: the gate compiles a tiny freestanding ELF on the host AFTER the image is baked, drops it + a 2-entry `APPS.TXT` into the share, and the boot lists it (`vf ls`), execs it from the SHARE (`exec: loaded HF4APP.ELF`, marker, `exited status=43`, 3 chunked READ round trips), and DESKTOP.BIN prints `desktop: manifest apps=2` from the HOST manifest (vs the ESP's 19) — no image rebuild; kernel exec host-first + ESP fallback, read-only `/host` file-table partition, desktop `/host/APPS.TXT` first + `/esp` fallback |
| HF5 | **User-data migration** — settings, notepad, calc history, downloads, screenshots, shell history, clipboard persist → host folder; `/data` deprecated — **issue #739** | HF3 | ✅ **done 2026-09-01 (PR #792, claim 3082)** — `/host` went READ-WRITE (host write handles, replace semantics; DELETE/RENAME/TRUNCATE/MKDIR route to the channel); one-time `/data`→share boot migration (hidden `.virelai-migrated` marker, skip-if-exists); `/data` mount prints an honest deprecation line; every `/data` consumer re-pointed (settings, notepad, calc, downloads, screenshots, shell history, env, file browser, savetext/type/dir); all persistence gates re-pointed through the channel and PASS with host-disk verification (`verify-live-vf` 5/5 + user-fs, n11-download, file-browser, filemanager-bulk/recent/props, settings, history); new runner `--chords-view` flag (--cvc-file implies via-virtio; display gates need the slow view-path chord pacing for launch-then-focus handoffs) |
| HF6 | **FAT removal** — delete `fat.zig` + post-exit virtio-blk path + DATA partition; slim `mkfat32.py`/`make-image.sh` to a boot volume; gate fleet to one shared read-only boot image (kill private copies + shared-disk locks) — **issue #740** | HF4, HF5 | `verify-vz` full fleet green with FAT gone; boot image ≤ a few MiB |
| HF7 | **Clone/dedup** — CLONE opcode → `clonefile`; prove N worktrees of one repo share blocks (host-side space measurement before/after); document the ZFS-backed-share option — **issue #741** | HF3 | ✅ **done 2026-09-02 (claim 1312)** — CLONE `0x0c` (additive), `vf clone <from> <to>`; files via `clonefile(2)`, trees via `copyfile(3)` `COPYFILE_CLONE`, traversal defense on both paths; the live gate measures the physical win at the VOLUME level (du cannot see COW — logical `st_blocks`; observed: a clone and a `cp` copy report identical du) — 3 copies ≈ 22.5 MiB vs 3 clones ≈ ~0, an edit in one worktree leaves untouched siblings byte-identical (sha256 tree compare), raw numbers under `artifacts/m34-hf7-measurement.txt`; the ZFS alternative is documented in §4 |

HF1–HF3 are the "pays off early" core: the transport, the first commands,
and mutation. HF4–HF6 are the deletion payoff. HF7 is the workload-specific
capstone. HF1/HF2 can be scoped as one PR if reviewers prefer a single
vertical slice.

## HF1 acceptance case A — the full-cap 32 KiB device-write reply

The one unproven transport fact HF1 must retire: the largest device-*write*
reply proven on the custom device is the claim-9492 12,340-byte echo;
claim 0680's 32 KiB chunks are device-*read* (guest→host, tiny acks). The
file channel's READ replies are the mirror case — ONE element carrying a
tiny device-read request and a 32,768-byte device-write reply — so HF1
proves it with a spike, not an assumption.

**Wire shape.** Queue 5 gains a transport-only opcode, `VF_PROBE` (0x00),
never served from the filesystem (file ops land in HF2):

```
request  [op=0x00][flags=0][len=0]                 (3 bytes)
reply    [status=0][dlen=0x8000][pattern 32768 B]
```

**Pattern.** A deterministic generator both sides compute without storing
32 KiB: `pattern[i] = (i & 0xff) ^ ((i >> 8) & 0xff)`. The guest
regenerates and compares ALL 32,768 bytes (a full compare, not just the
checksum — catches offset/ordering bugs a checksum can miss), then prints
the RFC-1071 checksum for the gate. The same 32,768 bytes are baked into a
shared class-A fixture so the guest Zig and host Swift generators are
locked byte-for-byte.

**Guest sequence** (`kernel/src/virtio_file.zig`, run once at init when
queue 5 is armed; prints spike lines in the cvspike style):

1. `submit_ex(5, &.{req}, &reply_buf, false)` — one 2-descriptor chain:
   the 3-byte request (device-read) + the 32,768-byte reply
   (device-write).
2. `wait(5, handle, budget, reply_buf)` → `n`. Assert `n == 32768` — the
   used ring must report the FULL writtenByteCount.
3. Parse the reply framing, then byte-compare the regenerated pattern.
4. `free_chain_q(5, handle)`; repeat once (chain reuse + ring free count
   restored — catches the claim-0680 leak class at full scale).
5. Print `vf: probe 32k ok len=0x8000 cksum=0x.... free=32` or a loud
   `vf: probe 32k FAILED (len=…, cmp=…)` line that fails the gate.

**Host sequence** (`main.swift` queue-5 handler; HF1 serves VF_PROBE only):

1. `nextElement()`; reassemble `readBuffers()`; parse the request.
2. `VF_PROBE` → assert `element.writeBuffersByteCount >= 32768` LOUDLY
   (the descriptor must carry the full buffer — a short write buffer is a
   guest bug to surface, never silent truncation); `write` all 32,768
   bytes.
3. Assert `writtenByteCount == 32768`; print
   `VF-PROBE: wrote 32768/32768 bytes (write buffers 32768)`.
4. `returnToQueue()`.
5. Unknown op → reply `[status=4]` (host error) loudly; never hang, never
   fall through to the filesystem.

**Gate assertions** (class B, `tools/verify-live-vf.sh` run 1): the guest's
`vf: probe 32k ok …` line + the runner's `VF-PROBE: wrote 32768/32768`
line + zero `vf:` failure/leak counters + the standard boot evidence.
Class A: generator-fixture byte-parity (Zig vs Swift), `reply_len` clamp
math, and framing encode/decode at `dlen=0x8000`.

**Failure modes it is designed to catch:** host truncated write
(`writtenByteCount < cap`), insufficient write-buffer descriptor
(`writeBuffersByteCount < 32768`), used-ring length not the full write
(`elem.len` ≠ actual), a guest `reply_len` clamp bug, chain leaks between
exchanges, and cache-range bugs at 32 KiB (defensive on VZ's coherent
emulation).

**Scope guard:** VF_PROBE exists only to retire this risk; the opcode is
reserved (never a filesystem path), the spike is flag-gated — without
`--cvc-file` nothing exists.

## HF1 acceptance case B — the class-A test list

Class A must pin the wire format on BOTH sides without a VM: a shared,
fixture-driven byte-parity lock (the WMRPC precedent — the wire mirror was
host-tested byte-identical to `wnd_core.WmRpc`, claim 9994) plus the clamp
and framing edge cases. One structural prerequisite: the host wire code
must be unit-testable — `main.swift` is a 4,500-line monolith, so the frame
encode/decode + pattern generator move to a pure-Swift **`VFWire` module**
(no Virtualization imports — runs under `swift test` on any toolchain);
the runner imports it; a new `VMRunnerTests` target tests it.

**Fixtures** (checked in, python-generated, sha256 pinned in the test):

| Fixture | Contents | Locks |
|---------|----------|-------|
| `tests/vf-pattern-32k.bin` | the 32,768-byte `VF_PROBE` pattern | generator parity, acceptance case A |
| `tests/vf-req-read.bin` | a canonical READ request (known path, offset, little-endian) | request encode/decode parity |
| `tests/vf-reply-ls.bin` | a canonical LIST reply (header + N 40-byte rows) | DirEntry decode parity |
| `tests/vf-reply-32k.bin` | the full-cap reply (header + 0x8000 data) | dlen=0x8000 framing parity |

**Guest tests** (`kernel/src/virtio_file.zig`, run by `verify-unit-tests.sh`):

| ID | Test | Pins |
|----|------|------|
| G1 | generator reproduces `tests/vf-pattern-32k.bin` byte-for-byte (`@embedFile`) + RFC-1071 checksum matches | pattern lock |
| G2 | `reply_len` clamp math: `used_len` 0x8000 / buf 0x8000, used 0x1000 / buf 0x8000, used 0x8000 / buf 0x1000 (never reads past the reported length), used 0 | the `min(used_len, current_reply_len)` clamp in `virtio_custom` and every decode path reads exactly what the transport reported |
| G3 | `build_request` encode: little-endian pins, empty path (LIST root), path = 255 max, `/`-subdir path, flags must be 0 | request framing |
| G4 | reply decode boundaries: dlen 0, 1, 3, 0x8000, 0x8001, 0xffff; dlen > bytes present → truncated; unknown status → error, never success; LIST dlen not a multiple of 40 → malformed counter, never partial decode | framing + status mapping |
| G5 | full-cap decode: hand-built 0x8000 reply — header parse, data slice == remainder, checksum verifies | dlen=0x8000 decode |
| G6 | malformed envelopes: unknown op, nonzero flags, len > payload — each increments a loud-by-counter malformed count, never decodes partially | hostile-input safety |

**Host tests** (new `VMRunnerTests` target against `VFWire`):

| ID | Test | Pins |
|----|------|------|
| S1 | Swift generator reproduces `tests/vf-pattern-32k.bin` + sha256 matches the pinned value | pattern lock (other side) |
| S2 | Swift request parser decodes `tests/vf-req-read.bin` to the canonical field values | request parity with G3 |
| S3 | Swift reply builder emits `tests/vf-reply-ls.bin` / `tests/vf-reply-32k.bin` byte-exactly (dlen, rows, 0x8000 data) | reply parity with G4/G5 |
| S4 | path-defense unit tests: `..`, absolute paths, symlink escapes rejected before any `FileManager` call | sandbox contract |

**Gate wiring:** `tools/verify-vf-class-a.sh` runs `verify-unit-tests.sh`
(includes `virtio_file`), `swift test --package-path host/vm-runner`, and an
sha256 check of the fixtures; new `just verify-vf-class-a` recipe;
wiring into `verify-portable` is the maintainers' call (deterministic — CI
safe). The fixture set is the single source of truth: if a side's generator
or framing drifts, exactly one test fails and names the side.

## HF1 acceptance case C — the VFWire module boundary

The boundary rule: **VFWire owns bytes and policy strings; the runner owns
VZ types and file I/O.** VFWire never imports Virtualization — every
function takes `[UInt8]`/`Data`/`String` and returns bytes/values. The
runner's queue-5 handler is thin glue: `nextElement()` → `VFWire.decode` →
`FileManager` → `VFWire.encode` → `element.write`.

**Module** (new): `host/vm-runner/Sources/VFWire/`, pure Swift 5, no
Virtualization, no FileManager (path defense returns a sanitized relative
path; the runner performs the I/O). Package changes: `VMRunner` gains
`dependencies: ["VFWire"]`; a new `.testTarget(name: "VMRunnerTests",
dependencies: ["VFWire"])` under `Tests/VMRunnerTests/`. Because the test
target depends only on VFWire, **`swift test` builds a graph that never
compiles or links a Virtualization import** — it runs on any toolchain,
including CI's macOS-26 hosted runners.

**Public surface** (sketch — the implementing agent fills details):

```swift
public enum VFWire {
    // Constants the framing, caps, and the guest mirror share.
    public static let replyCap = 32768, maxPathLen = 255
    public static let maxListEntries = 128, dirEntrySize = 40

    // Wire values (must match virtio_file.zig exactly — fixtures pin them).
    public enum Op: UInt8 { case probe = 0, list = 1, read = 2, stat = 3 }
    public enum Status: UInt8 { case ok = 0, notFound = 1,
        isDirectory = 2, truncated = 3, hostError = 4 }
    public struct Request { let op: Op; let flags: UInt8; let payload: [UInt8] }
    public struct Reply   { let status: Status; let data: [UInt8] }
    public enum WireError: Error { case tooShort, badOp, badFlags,
        lenMismatch, truncatedData, unknownStatus, badDirEntryRow }

    // Framing. Runtime sides are marked; the other two exist for the
    // fixture parity lock (mirror: the guest's encoders/decoders are the
    // mirror image — its decoders are runtime, its encoders are locked).
    public static func encodeRequest(_ r: Request) -> [UInt8]     // runtime (fixture lock)
    public static func decodeRequest(_ b: [UInt8]) -> Result<Request, WireError> // runtime
    public static func encodeReply(_ r: Reply) -> [UInt8]         // runtime
    public static func decodeReply(_ b: [UInt8]) -> Result<Reply, WireError>     // fixture lock

    // DirEntry rows (ADR 0010 shape: name[32], size u32 le, is_dir u8, rsvd[3]).
    public struct Entry { let name: [UInt8]; let size: UInt32; let isDir: Bool }
    public static func encodeEntry(_ e: Entry) -> [UInt8]
    public static func decodeEntry(_ row: [UInt8]) -> Result<Entry, WireError>

    // Acceptance case A + the 32k fixture (shared with the guest).
    public static func probePattern() -> [UInt8]
    public static func rfc1071(_ bytes: [UInt8]) -> UInt16

    // Pure string policy — NO FileManager. Returns a sanitized relative
    // path, or nil when the subpath escapes the share root.
    public static func sanitizeSubpath(_ raw: String) -> String?
}
```

**What moves out of `main.swift` vs. what stays:**

| Function (today, in the monolith) | Destination | Why |
|-----------------------------------|-------------|-----|
| `rfc1071(_:)` (private, used by the snapshot parser) | `VFWire.rfc1071` | already pure; snapshot consumer swaps to the VFWire call (one edit) |
| new VF request decode / reply build / rows / pattern / path policy | `VFWire` from day one | the whole point — never born in the monolith |
| `element.write`, `returnToQueue`, `nextElement`, queue notifications | stays in `main.swift` | VZ-only APIs |
| `FileManager` directory/read calls, the `--cvc-file` flag parsing | stays in `main.swift` | I/O + config, the runner's job |
| `consumeSnapshotMessage` + `SnapAssembly` | stays (for now) | pure, but snapshot-churn scope — optional second tranche, not HF1 |

**Consumption contract:** the runner's HF1 queue-5 handler is
`nextElement` → reassemble `readBuffers()` → `VFWire.decodeRequest` → serve
(`VF_PROBE` here; LIST/READ/STAT in HF2) → `VFWire.encodeReply` →
`element.write` → `returnToQueue`. `VMRunnerTests` (
`Tests/VMRunnerTests/VFWireTests.swift`) exercises S1–S4 from acceptance
case B against the same module with zero VZ linkage — the byte-parity
fixtures (G1–G6 on the Zig side, S1–S4 here) are the two sides' single
shared truth.

## Risks and honest limits

- **The opcode set IS the FS API** — a bad surface bakes in; grow it
  deliberately (version byte in the framing from day one).
- **Host security** — the share must be sandboxed to its root (path
  traversal, symlink escapes, absolute paths rejected). The guest is
  untrusted code running with the host runner's privileges.
- **Polled latency** — every op is a bounded polled round trip; fine for
  interactive use, but the chain-free discipline (claim 0680) and tight
  budgets apply to every send.
- **Boot coupling** — the desktop must mount the channel early (HF4) or the
  app story regresses; until then the ESP exec path stays for safety.
- **Existing gates** — exec/manifest/fs gates assume ESP apps; keep them
  green until HF6 deletes the path they test.
- **macOS-only is a feature here, not a risk** — the project is already
  Apple-silicon/VZ-only by declaration; the guest becoming an experience
  layer over a host folder is consistent with that identity. The honest
  tradeoff: the guest is not a standalone computer — but it never claimed
  to be.

## Explicitly out of scope

- **Full virtio-fs / FUSE** — a Linux-shaped protocol (inode caching, DAX,
  hundreds of opcodes) designed for Linux guests; the biggest driver the
  project could write, to import a foreign design. The custom channel is
  ~10% of the size and covers the need.
- **A custom guest filesystem for now** — writing a format, allocator, mkfs,
  and fsck is the "guest stands alone" bet; it solves no current pain and
  HF7 shows dedup needs no guest FS. The DATA partition is a blank slate if
  that dream ever wins — nothing forecloses it.
- **Block-level dedup in the guest** — chunked content-addressing is
  research-grade and unnecessary; clones capture the worktree win.
- **Removing the ESP itself** — UEFI mandates a FAT boot volume; the
  objective is zero *guest code* touching it post-boot, not zero FAT on
  disk.
