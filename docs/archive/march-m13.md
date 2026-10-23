> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone thirteen march — files & applications (living tracker)

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-thirteen's per-card detail and collision-free agent split,
> following the [`march-m12.md`](march-m12.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestone twelve connects **userland applications to the network** (the TCP
syscall seam at ADR 0007 slots 30–33, bounded DNS, and the `FETCH.BIN` +
`CHAT.BIN` capstone). When it lands, the desktop has windows, events,
storage, processes, and the network — but no file story: `DESKTOP.BIN`
hardcodes its app list, and nothing can browse, delete, or rename files on
the DATA partition.

Milestone thirteen is the **file browser milestone**: application identity
the launcher reads instead of hardcodes, the filesystem semantics a real
browser needs, and `FILE.BIN` as the capstone — wishlist items 6, 9, and the
filesystem half of 17.

The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| B1 | **Filesystem semantics depth (ADR 0007 slots 34–37).** `sys_file_delete`, `sys_file_rename`, `sys_file_truncate`, `sys_file_free` — the M10 read-only ABI becomes mutating. | ✅ | [`claim 5801`](archive/claims/5801-fs-semantics.md); live gate `tools/verify-live-fs-mutation.sh` **PASS 1/1 on VZ** — `FSTEST.BIN` create+write → truncate → read-back `hello` → rename → free → delete → prove-gone, all four slots `calls=1`. | Tracked by issue #161; slots 30–33 are M12's TCP seam. |
| B2 | **Application identity manifest.** `APPS.TXT` on the ESP (or a trailing `.BIN` record — ADR 0002's header stays frozen); `DESKTOP.BIN` reads it via `sys_file_open` instead of its hardcoded app array. | ✅ | [`claim 8877`](archive/claims/8877-app-manifest.md); live gate `tools/verify-live-desktop.sh` **PASS 1/1 on VZ** — `desktop: manifest apps=8` + `DESKTOP.MANIFEST: OK` + `DESKTOP.LAUNCH: OK` (PR #165, merged 2026-08-16). The gate's tail fixed two PRE-EXISTING kernel bugs the corrupt manifest exposed: the `sys_file_read` kstack overflow (8→16 KiB, see the status.md M13 row) and the FP/SIMD clobber across exceptions (the vector stubs now save q0–q31, claim 8877-bisect). | Wishlist 9; issue #152. |
| B3 | **`FILE.BIN` graphical file browser.** **[Capstone Gate]** Browse `/data/` in a scrollable `ListView`, open `.TXT` in a read-only view, delete/rename through B1. Live gate: `verify-live-file-browser.sh`. | ✅ | [`claim 4742`](archive/claims/4742-file-browser.md); live gate `tools/verify-live-file-browser.sh` **PASS 1/1 on VZ** — `file: ready`, `file: listing 2 entries` (README.TXT + DATA.TXT), `file: open README.TXT`, `file: view README.TXT`, and `27 sys_dir_list`/`23 sys_file_open`/`24 sys_file_read` `calls=1`. | Wishlist 6; tracked by issue #153. Uses the ui.zig toolkit; delete/rename deferred to B1 (slots 34–37). |
| B4 | **Desktop composition.** Launcher menu from B2's manifest; FILE.BIN launchable; the capstone gate drives DESKTOP → launch FILE.BIN → browse → open a file end to end on VZ. | ✅ | [`claim 4046`](archive/claims/4046-desktop-composition.md); live gate `tools/verify-live-file-browser.sh` **PASS 1/1 on VZ** — boots DESKTOP.BIN only, walks the 9-entry manifest menu to FILE.BIN, and launches it through `sys_exec` (slot 28) before opening README.TXT; syscalls report proves the seam (`sys_exec` calls=1, `dir_list` calls=1, `file_open`/`file_read` calls=2). `verify-live-desktop.sh` now pins `manifest apps=9`. | Tracked by issue #162; closes it. |

## Housekeeping folded in

- **`win` → `dui` command rename** (issue #159) — ✅ done 2026-08-16
  (claim 2223): Driving Award's monitor command is now `dui` (same
  subcommands), report prefixes + title-bar label renamed, and the
  re-derived gates assert `dui:` output.
- **M8 U4 pointer-focus class-B evidence** (issue #151) — 🔄 gate finished
  (claim 5776): `verify-live-pointer-cg.sh` now SKIPs cleanly (exit 0)
  without trust and runs to an honest result with it. With trust granted,
  the CG route still produced `ptr-reports=0` (synthesized pointer events
  don't reach VZ's USB device) — U4 stays ⛔ at the live seam; class-C
  (real mouse) is the honest proof.

## Notes

- The M13 plan lives in issues #152 (B2), #153 (B3), #161 (B1), and #162
  (B4), filed 2026-08-16 ahead of M12's closeout — which landed the same
  day (PR #160, issues #148/#149/#150 closed). The roadmap's destination
  sections are seeded ahead of the closeout, per the M12 precedent.
- The DSK1 image format (ADR 0002) is frozen — the manifest must not change
  the `.BIN` header.
- Zero heap allocation stays a hard constraint for every app and every new
  kernel resource.
