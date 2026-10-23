# Roadmap archive — Milestone thirteen — files & applications

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

### Milestone thirteen — files & applications: the file browser milestone

> Give the desktop a file story: application identity that the launcher
> reads instead of hardcodes, a graphical file browser over the DATA
> partition, and the filesystem semantics (delete, rename, truncate, free
> space) a real browser needs. This is wishlist items 6, 9, and the
> filesystem half of 17 — the next "weird little computer" step after the
> network milestone. **🔄 B2 done 2026-08-16** (claim 8877, PR #165 — the
> `APPS.TXT` application identity manifest; `verify-live-desktop.sh` PASS on
> VZ; the gate's tail also fixed two pre-existing kernel bugs: the
> `sys_file_read` kernel-stack overflow and the FP/SIMD clobber across
> exceptions); **🔄 B3 done 2026-08-16** (claim 4742 — `FILE.BIN`, the
> graphical DATA file browser; `verify-live-file-browser.sh` PASS on VZ);
> **🔄 B1 done 2026-08-16** (claim 5801 — the mutating FS seam, slots 34–37;
> `verify-live-fs-mutation.sh` PASS on VZ); **✅ B4 done 2026-08-16**
> (claim 4046 — desktop composition; the file-browser gate now drives
> DESKTOP → launch FILE.BIN via `sys_exec` → open README.TXT, PASS on VZ).
> M12's TCP seam runs at ADR 0007 slots 30–33, so this milestone's FS
> additions start at slot 34.

- **B1 — Filesystem semantics depth (ADR 0007 slots 34–37).** ✅
  done 2026-08-16 (claim 5801): `sys_file_delete(path_ptr, path_len)`,
  `sys_file_rename(old_ptr, old_len, new_ptr, new_len)`,
  `sys_file_truncate(handle, size)`, and a `sys_file_free(volume) -> bytes`
  free-space query — the read-only M10 ABI becomes a mutating one, bounded
  like every other kernel resource. `FSTEST.BIN` + the
  `verify-live-fs-mutation.sh` live gate prove it (all four slots `calls=1`).
- **B2 — Application identity manifest.** A tiny fixed-format manifest
  (`APPS.TXT` on the ESP, or a trailing record in each `.BIN` — the DSK1
  header is frozen by ADR 0002): `NAME.BIN | Display Name | icon-char`.
  `DESKTOP.BIN` reads it via `sys_file_open` instead of its hardcoded app
  array, so adding an app means a manifest entry, not a launcher recompile.
  (Wishlist 9; issue #152.)
- **B3 — `FILE.BIN` graphical file browser.** **[Capstone Gate]** ✅
  done 2026-08-16 (claim 4742): browse `/data/` in a scrollable `ListView`
  (the ui.zig toolkit), open `.TXT` files in a read-only text view;
  delete/rename still arrive through B1's slots. Live gate
  `verify-live-file-browser.sh` PASS on VZ. (Wishlist 6; issue #153.)
- **B4 — Desktop composition.** ✅ done 2026-08-16 (claim 4046): the
  launcher menu comes from B2's manifest (not the hardcoded array) and
  FILE.BIN is one of the launchable apps; the reworked
  `verify-live-file-browser.sh` drives DESKTOP → launch FILE.BIN through
  `sys_exec` → browse → open a file end to end on VZ.

Housekeeping folded into this milestone: the `win` → `dui` command rename
(issue #159, done 2026-08-16 claim 2223), and closing out M8's U4
pointer-focus evidence with the class-B CG gate (issue #151, self-gating
on Accessibility trust).

See [`march-m13.md`](march-m13.md) for the per-card tracker.
