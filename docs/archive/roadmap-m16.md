# Roadmap archive — Milestone sixteen — the kernel grows up

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

### Milestone sixteen — the kernel grows up (**done 2026-08-19**; wishlist 15/14/13)

> The M15-era claims recorded the pressure that finally activates the
> wishlist's conditional items: the **16 KiB exec load bound** (a 33 KB
> JINGLE.BIN would not load — claim 7636), the **W^X single-segment
> layout** (a global BSS buffer faults on write from EL0 — every app's
> mutable data must be a stack local), and the **fixed pools under real
> load** (7 process slots, `pool_full` on a fifth concurrent user
> program). So milestone sixteen is the internals-consolidation
> milestone — the kernel grows up under the weight of its own apps:
> a multi-segment user image with real writable globals + a lifted load
> bound (C1, wishlist 15) → guard pages + per-segment permissions (C2,
> wishlist 14) → the resource pools measured and grown only where the
> demo apps actually hurt (C3, wishlist 13) → a composition capstone
> proving all three in one session (C4). Wishlist 17 (deeper FS
> semantics) stays deferred — M13's B1 already shipped
> delete/rename/truncate/free and no app has produced new pressure.
> The default VM (no flags) stays byte-identical at every card. Issues
> **#190–#193** filed 2026-08-18 (one per card, the M14 way).

See [`march-m16.md`](march-m16.md) for the card tracker.

**Closed 2026-08-19 — C1 + C2 + C3 + C4 all live (claims 3805 + 8403 +
0339 + 2714).** C4's composition capstone (`verify-live-m16-composition.sh`)
ran GLOBALS.BIN, GUARD.BIN, and eight concurrent programs in ONE boot and
exposed one more measured growth: the page-table carve-out is a total-roots
budget (tables are never reclaimed), so the big app + hostile app + eight
concurrent = 282 pages exceeded the old 256 — grown to 512 (2 MiB).
