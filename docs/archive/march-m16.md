> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone sixteen march — the kernel grows up (living tracker)

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds milestone-
> sixteen's per-card detail and collision-free agent split, following the
> [`march-m15-audio.md`](march-m15-audio.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

## Why the kernel grows up (wishlist items 15, 14, 13)

The maintainer's wishlist filed items 13 (resource-model cleanup), 14
(richer virtual memory), and 15 (executable-format evolution) as
**conditional** — "only when applications force it". Milestones eleven
through fifteen shipped exactly the applications that now do the forcing,
and the M15-era claims recorded the pressure in black and white:

- **The 16 KiB exec load bound (item 15).** JINGLE.BIN's first draft was
  33 KB and would not load — the melody app had to be rewritten down under
  `exec`'s 16 KiB load buffer (claim 7636). Programs cannot grow.
- **The W^X single-segment layout (items 15/14).** JINGLE.BIN's global
  `chunk_buf` faulted on write from EL0 — the text page is read-only, so
  every user program's mutable data must be a stack local (claim 7636).
  There is no writable data segment and no BSS.
- **The fixed pools under real load (item 13).** The scheduler pool is 7
  slots and the exec path refuses a fifth concurrent user program
  (`pool_full`, every M4-era gate); the launcher, the file browser, the
  chat app, and the sound apps all compete for the same few slots. The
  wishlist rule — keep pools bounded until real apps expose actual pain —
  now has real apps; C3 measures whether the pain is real enough to grow.

Item 17 (deeper filesystem semantics) stays deferred: M13's B1 already
shipped delete/rename/truncate/free and no application has produced new
pressure.

**Meta-requirement (roadmap):** every infrastructure card names the small
experience that consumes it, and the milestone ends in a composition test
a human can perceive. C4 is that test: a desktop session where bigger
programs with real globals run alongside a guard-page-refused hostile
app, and more concurrent processes than today's pool allows — the
"kernel grew up" moment, human-verified on VZ.

## The cards, in order

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| C1 | **The image format grows up (wishlist 15; issue #190).** A multi-segment user image — text (read-only, W^X), writable data, and zeroed BSS — replacing the flat single-segment DSK1 shape in `exec`, lifting the 16 KiB load bound so programs can grow, and giving EL0 real writable globals (the JINGLE finding reversed: no more stack-local-only rule). The DSK1 loader stays for the boot payload; the new shape is a second loader path, not a rewrite. Live gate: `verify-live-m16-image.sh` — a program with global BSS AND an image larger than 16 KiB runs from EL0, with the kernel's own page accounting exact. Consuming experience: a bigger app (e.g. NOTEPAD's scrollback or a paint app) that today cannot fit or cannot use globals. | ✅ | **claim 3805 (2026-08-19):** `elf2bin.py --segments` (DSK3: 48-byte header + `text_size`/`data_file_size`/`data_mem_size`, [text+rodata][data], BSS zero-fill implicit), `kernel/src/exec.zig` second loader path (`parse_dsk3` + data pages), `mmu.build_user_root_full` third data aperture (EL0 RW+UXN), process owns/frees data pages, load bound 16 KiB → 256 KiB. `GLOBALS.BIN` (28th ESP program, 28 KiB text + 8 B data + 4 KiB BSS): `tools/verify-live-m16-image.sh` **PASS 1/1 on VZ** — `size=0x7000` (past the old bound), `data=0x1010 datapages=2` (page accounting exact), `globals: data bss ok`, exit 42. The flat DSK1 path + `user/linker.ld` are byte-unchanged (segmented program uses the new `user/linker-segmented.ld`). | Wishlist 15; depends on nothing. |
| C2 | **Address-space depth (wishlist 14; issue #191).** Guard pages below the user stack and around the new data segment; per-segment permission enforcement beyond W^X text (data writable-but-not-executable); hostile-EL0-refused live proof in the S4 pattern. Live gate: `verify-live-m16-guards.sh` — a hostile program stepping off its stack or into a guard faults, is reaped by the kernel, and never corrupts a neighbor's page. Consuming experience: the desktop surviving a malicious app. | ✅ | **claim 8403 (2026-08-19):** an EL0 synchronous fault (SPSR.M==0, not an SVC, not a recoverable uaccess fault) now goes through a registered fault dispatcher → `scheduler.fault_current` → `exit_current(139)` (`reserved_fault_status`), so a hostile program touching a guard page is REAPED (status 139) instead of parking the machine; a `fault: <name> far=0x… ec=0x24` FIFO line is drained before the exit report. Guard pages are the user root mapping ONLY text/data/stack: the page below the stack bottom and the page above the data region are unmapped (documented in `build_user_root_full`). `GUARD.BIN` (29th ESP program) steps 20 KiB below its 16 KiB stack top — 4 KiB below the bottom, into the guard — and `tools/verify-live-m16-guards.sh` **PASS 1/1 on VZ**: `guard: stepping off` → `fault: GUARD.BIN far=0x… ec=0x24` → `tasks user-exec exited status=139` / `procs GUARD.BIN exited status=139`, with COUNTER.BIN still `state=running` beside it (never corrupted). | Wishlist 14; depends on C1 (the data segment needs a real address-space shape to guard). |
| C3 | **The resource model, measured (wishlist 13; issue #192).** Audit the fixed pools — process slots (7), windows, mailbox rings, TCP connections, file handles — under the real concurrent-app load (M11 launcher + M13 apps + M15 apps), and grow ONLY the pool the demo apps actually exhaust, with the measurement recorded as the evidence (the wishlist's "keep them bounded until real apps expose actual pain" rule, applied honestly). Live gate: `verify-live-m16-resources.sh` — a launcher session running more concurrent applications than today's 7-slot pool allows, with the before/after pool accounting pinned. Consuming experience: 8+ apps on the desktop. | ✅ | **claim 0339 (2026-08-19):** the measured bottleneck is the scheduler executor pool — `max_tasks = 7` (4 user slots) refused a FIFTH concurrent program (`pool_full`). Grown `max_tasks` 7 → 11 (8 user slots) and `process.max_processes` 8 → 16 (the registry saturates at the new 8-program concurrency). Added a `resources` monitor command (audits tasks/procs/windows/tables + the per-process ring bounds) and re-derived the M4-era gates that pinned the 7/7 budget (scale/args/ipc/long-lived + exec/scheduler/monitor/shell tests + transcript). `tools/verify-live-m16-resources.sh` **PASS 1/1 on VZ**: before `resources: tasks=3/11 procs=1/16 tables=62/512` → 8 concurrent programs (counter + 7 USER.BINs) → after `tasks=11/11 procs=9/16 tables=238/512` (the carve-out fits 8 small user roots with headroom — no table growth needed for C3's scope alone; C4's composition, which adds the big app + hostile app, grows it, see C4), ninth exec `pool_full`, windows/events/mbox/fds/timers/tcp stay bounded. The re-derived scale/args/ipc/long-lived gates all PASS 1/1. | Wishlist 13; depends on nothing (rides on C1/C2's address-space shape). |
| C4 | **Composition capstone (issue #193).** One session proves C1+C2+C3 together: a bigger app with real globals runs next to a guard-page-refused hostile app, and the desktop holds more concurrent programs than the old pool allowed — the milestone's human-perceivable "kernel grew up" test. Live gate: `verify-live-m16-composition.sh` — device-agnostic (the default VM stays byte-identical; the sound/gfx/input flags only add their layers). | ✅ | **claim 2714 (2026-08-19):** one boot runs `GLOBALS.BIN` (C1) then `GUARD.BIN` (C2) beside a persistent `COUNTER.BIN`, then seven `USER.BIN`s fill the grown pool; `tools/verify-live-m16-composition.sh` **PASS 1/1 on VZ** (`globals: data bss ok` exit 42 → `fault: GUARD.BIN far=0x… ec=0x24` reaped 139 → eight concurrent programs, `resources: tasks=11/11 procs=11/16 tables=282/512`). **C4 finding:** the composition exposed that the page-table carve-out is a TOTAL-roots budget (table pages are never reclaimed — the `table_count` cursor is monotonic), so the big app + hostile app + eight concurrent programs = 282 pages exceeded the OLD 256-page carve-out (the last two `USER.BIN`s were refused with `table_full`, not `pool_full`); C4 grows `mmu.table_page_count` 256 → 512 and re-derives the scale gate + monitor `resources` test to the new capacity. Three scripted phases keep the transient C1/C2 programs reaped before the C3 fill, so a zombie never oversubscribes the 8-slot budget. | Depends on C1+C2+C3. |

## Issues

Filed 2026-08-18 when the milestone was picked up, the M14 way (one per
card, mirroring #175–#178): **#190** (C1), **#191** (C2), **#192** (C3),
**#193** (C4). Claim each card (claim file + branch log) before writing
code, and close its issue with the claim + gate evidence.

## Notes

- Zero heap stays a hard constraint for every new kernel resource (fixed
  BSS tables only) — the M14 rule carried forward — UNLESS C3's
  measurement explicitly justifies a dynamic pool, in which case the
  claim must record the measured pressure that earned it.
- The default VM (no flags) must stay byte-identical: C1/C2 change the
  exec loader and address-space builder, so every existing live gate that
  execs a program (exec/procs/lifecycle/scale/wait/args/ipc + every app
  gate) is a regression surface — the full `verify-vz` sweep re-runs at
  each card.
- Wishlist item 17 (deeper FS semantics) stays deferred — no application
  pressure yet; item 20 mountains (SMP, 3D, dynamic linking, POSIX) stay
  visible, not climbed.
- The card letter is C (consolidation) — M13 used B, M14 S, M15 A; no
  collision.
