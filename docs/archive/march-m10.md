> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone ten march — userland filesystem & storage ABI (living tracker)

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-ten's per-card detail and collision-free agent split, following
> the [`march-m6.md`](march-m6.md), [`march-m7.md`](march-m7.md),
> [`march-m8.md`](march-m8.md), and [`march-m9.md`](march-m9.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestones zero through nine delivered an AArch64 OS kernel with preemptive
multitasking, virtual memory, FAT32 kernel storage, virtio-net networking,
virtio-gpu windowing (Driving Award), USB xHCI input, human interface
tooling, and interactive application events.

Milestone ten turns VirelaiOS into a **persistent storage platform for user applications**
by exposing a bounded, safe per-process file handle table and syscall ABI (ADR 0007 slots 23–27).

The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| F0 | **Storage contract & ADR 0010.** Normative specification for userland filesystem access: path syntax (`/data/...`, `/esp/...`), access mode bitmasks (`MODE_READ=1`, `MODE_WRITE=2`, `MODE_CREATE=4`, `MODE_APPEND=8`), 40-byte `DirEntry` wire format, error codes (`ENOENT`, `EBADF`, `EACCES`, `ENOSPC`, `EINVAL`, `ENAMETOOLONG`), and ADR 0007 syscall slots 23–27 (`sys_file_open`, `sys_file_read`, `sys_file_write`, `sys_file_close`, `sys_dir_list`). Docs only — no code. | ✅ done (claim 0662) | `docs/decisions/0010-userland-filesystem-abi.md` | Gate: ADR 0010 accepted. |
| F1 | **Kernel per-process file handle table (`kernel/src/file_table.zig`).** Bounded in-memory file handle table (8 open handles per process slot, pure static BSS, 0 heap allocation). Tracks partition (`ESP` or `DATA`), file cluster chain, byte cursor offset, file size, access mode, and process lifecycle reset (auto-close on `exit_current`). | ✅ done (claim 9948) | `kernel/src/file_table.zig` | Gate: class A unit tests covering handle allocation, offset advancement, bounds checking, and process isolation. |
| F2 | **Path canonicalization & partition routing.** Safe userland path parsing, prefix routing (`/esp/` -> ESP boot volume, `/data/` -> DATA volume, bare paths -> default DATA volume), traversal defense (`..` escaping prevention), and 8.3 / FAT path normalization. | ✅ done (claim 8313) | `kernel/src/file_table.zig` | Gate: class A unit tests for path routing and forbidden traversal vectors. |
| F3 | **File syscall seam (slots 23–27).** Implement `sys_file_open` (slot 23), `sys_file_read` (slot 24), `sys_file_write` (slot 25), `sys_file_close` (slot 26), and `sys_dir_list` (slot 27) in `kernel/src/syscall.zig` using fault-safe `uaccess` copy helpers. | ✅ done (claim 3570) | `kernel/src/syscall.zig` | Gate: class A unit test suite in `kernel/src/syscall.zig` testing all 5 syscall slots and error codes. |
| F4 | **Userland storage utilities (`SAVETEXT.BIN`, `TYPE.BIN`, `DIR.BIN`) & live gate.** **[Capstone Gate]** Standalone EL0 user applications: `SAVETEXT.BIN` creates and writes persistent data to `/data/hello.txt`, `TYPE.BIN` reads and echoes file contents, and `DIR.BIN` lists directory entries. Verified end-to-end on live VZ hardware across reboot. | ✅ done (claim 0510) | `artifacts/live-user-fs-gate.txt`, `tools/verify-live-user-fs.sh` | Gate: `tools/verify-live-user-fs.sh` — PASS on VZ hardware. |

## Agent split / collision rules

- **F0** (claim 0662, buffy): owned `docs/decisions/0010-userland-filesystem-abi.md`
  and ADR 0007 syscall table amendments.
- **F1** (claim 9948, buffy): owned `kernel/src/file_table.zig` and process table
  lifecycle integration in `kernel/src/process.zig` / `kernel/src/scheduler.zig`.
- **F2** (claim 8313, buffy): owned path routing and canonicalization logic.
- **F3** (claim 3570, buffy): owned `kernel/src/syscall.zig` slots 23–27.
- **F4** (claim 0510, buffy): owned `user/src/savetext.zig`, `user/src/type.zig`,
  `user/src/dir.zig`, build image embedding, and capstone gate `tools/verify-live-user-fs.sh`.
