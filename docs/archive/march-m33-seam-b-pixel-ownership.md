> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone thirty-three march — seam B: full pixel ownership (living tracker)

> [`docs/status.md`](../status.md) is the canonical milestone-level source. This
> file holds M33's per-card detail, order, and ABI notes. A card's row flips to
> ✅ only with real observed evidence.
> Architectural binding: **[ADR 0016](../decisions/0016-shared-anonymous-mmap.md)**
> (DRAFT, claim 9612) — seam B, split from ADR 0015 D5 / issue #630.

## Where we are

M32 (issues #621–#629) is closed: the WM server is real, all nine policy cards
landed, WMS8 slimmed the kernel to a thin render + input + surface server, and
WMS9's span batching is the perf baseline. WMS10 (issue **#630**) was the sole
open card — an explicitly deferred **scoping/tracker** card whose checkboxes are
the *next* milestone's seed. This milestone (M33) is that milestone: seam B,
**full pixel ownership**.

Today apps reach the desktop only through `sys_win_fill` (slot 13) /
`sys_win_present` (slot 14) per-rect fill syscalls; the kernel keeps per-app
back-buffers. Seam B moves pixels to the apps: each migrated app renders into a
**cross-process shared anonymous mmap** surface, the WM composes N shared RO
surfaces + one final present, and the kernel sheds the per-rect fill hot path
for migrated apps. Unmigrated apps keep the frozen slots working. The M29 COW
machinery (`map_user_cow_page`/`sw_cow` bit 55) is the foundation the new
capability generalizes (ADR 0016 D1).

**SB1 (contract) is DONE (claim 7418, 2026-08-30):** ADR 0016 is ACCEPTED, the
`M33_MAP_SHARED` flag bit (16) on `sys_mmap` slot 63 is frozen in ADR 0007, and
the D2 security rule (`kernel/src/shared_region.zig`, 6 host tests) is the frozen
spec SB2 wires into `sys_mmap`. Next card: SB2 (the shared-anon capability —
two EL0 roots mapping one physical region).

## The cards, in order

> **Phase 0 contract → 1 capability → 2 surface → 3 compose → 4 payoff/perf.**
> The capability must exist and be security-reviewed before any surface is
> mapped; surfaces before compose; compose before the perf win is measured.

| SB# | Card | Phase | Depends on | Status | ABI | Notes |
|----:|------|:------|------------|--------|-----|-------|
| SB1 | **ADR 0016 accepted + slot reservation** — shared-anon mmap mechanism, flag-vs-new-slot decision, `SharedRegion` table shape, security/capability rules (D2). | 0 — contract | — | ✅ claim 7418 | slot-63 flag (bit 16) | **DONE 2026-08-30 (claim 7418).** ADR 0016 → **ACCEPTED** with the D2 security review; open items resolved (flag over new slot → `M33_MAP_SHARED` bit 16 on `sys_mmap` slot 63; `SharedRegion` integer handle, `max_shared_regions` = 8 BSS; refcount-to-zero on owner teardown). Encoding frozen in ADR 0007 (no new dispatch row — ADR 0013 posture holds until SB2). New `kernel/src/shared_region.zig` (pure D2 rule, no MMU touch): `create`/`authorize_read`/`grant_read`/`drop_read`/`drop_owner`, 6 host tests pinning owner-write / WM-read-only / non-WM-peer-deny / revoke-every-peer-on-teardown / refcount-to-zero / stale-handle isolation. Pre-merge review (claim-7418) fixed the peer-only writable guard (owner-write is granted, not `.writable_refused`; owner identity checked first) and pinned SB2's mapping duty (do NOT map a redundant `sw_cow` leaf for the owner — only non-owner peers get RO from `.grant`). Build clean, full host suite green, fmt/coordination/BSS clean. **Gate PASSED: ADR ACCEPTED + slot reserved; D2 revocation rule unit-tested.** SB2 implements this rule into `sys_mmap`. |
| SB2 | **Shared-anon mmap capability** — `sys_mmap` gains the shared flag; kernel allocates a `SharedRegion` (refcount + owner + va/pa set), maps RO leaves into peer roots, grants read access to the registered WM server + (future) authorized apps. | 1 — capability | SB1 | ✅ claim 8878 | slot 63 flag (bit 16) | Engineer the refcount/teardown from M29 COW (region-level, not per-page). **Gate: two EL0 spaces map one physical region; owner writes, WM reads RO; munmap-on-close revokes peers (unit + headless VZ proof).** **DONE 2026-08-31 (claim 8878).** `sys_mmap` slot 63 honors `M33_MAP_SHARED` (bit 16): owner `MAP_ANON|SHARED` allocates one contiguous region (`alloc_pages`), maps WRITABLE leaves into the owner's root, registers a `SharedRegion` (kernel-issued handle, refcount, owner pid/va/pa set — extended `shared_region.zig` with the SB2 wiring fields, slot-reuse zeroing, 7 policy tests); the REGISTERED WM attaches by handle (`addr=handle, prot=R, SHARED`) → `authorize_read` (D2: non-owner RO only) → `alloc.ref_page` (+1) → EL0-RO `sw_cow` leaf in the WM's OWN root (new `kernel/src/shared_mmap.zig`); owner `munmap`/exit revokes (`shared_mmap.revoke_owner`: unmap the WM's RO leaf, `unref_page` →0 → free, descriptor zeroed) — wired into the scheduler exit seam; owner re-attach by handle keeps its own va (SB1 review duty: no redundant COW leaf for the owner). 583 aggregated host tests incl. two syscall-level proofs (owner RW / WM RO `sw_cow` in two real roots; revoke-on-owner-exit via the scheduler seam). **Live gate PASS (headless VZ, `--screen`):** `verify-live-sb2-shared-anon.sh` — SB2OWN.BIN creates + writes `0xAB`, SB2WM.BIN (registered WM) reads `0xAB` through its RO leaf, owner exits, stale re-attach → `EFAULT` (no peer access past the owner). ESP root window 64→96 (the image's 68 root files dropped the SB2 binaries). Build clean, full host suite green, fmt/coordination ok, BSS PASS (10850408 B). |
| SB3 | **Surface handoff** — apps render into a shared surface (plain stores); `sys_win_fill`/`sys_win_present` hand off for migrated apps; frozen slots keep working for unmigrated ones. | 2 — surface | SB2 | ⬜ | slots 12–20 frozen | `uaccess` registration stays owner-side only. **Gate: a migrated app draws to its buffer and the WM sees the bytes (parity vs. the old fill path).** **DONE 2026-08-31 (claim 3633).** A user window can be bound to a shared-anonymous surface via `sys_mmap(addr = M33_SURF_WIN_TAG | window_id, MAP_ANON|M33_MAP_SHARED)` (slot 63): the addr-tag reuses SB2's owner-create + peer-attach wholesale, the frozen `sys_win_open`/`fill`/`present` slots (12–14) stay byte-identical for unmigrated apps, and the kernel's 1:1 physical map lets `composite()` blit straight from the surface's `pa_base`. `driving_award` gains `bind_window_surface` + the `Window.surface_*` fields (close/teardown), `handle_mmap_shared` routes the window-tag into a shared owner-create whose tail the plain and window paths both converge on, `sys_win_fill` routes into the surface when bound, and a registered WM auto-mirrors RO at bind time. Host test pins the structures (bind recorded; owner leaf writable aliasing the surface pa; WM mirror leaf RO+`sw_cow` aliasing the SAME pa; unmigrated windows untouched) — byte parity proven by construction (same B8G8R8X8 encoding, different destination memory) and by the live gate. **Live gate PASS (`--screen`, headless VZ):** `verify-live-sb3-surface-handoff.sh` — SB3OWN.BIN opens a window, binds a surface, stores `0xAB` with a plain write (no kernel fill); SB3WM.BIN (registered WM) peers the surface RO and reads `0xAB` exactly. Build clean, full host suite green, fmt/coordination ok. |
| SB4 | **Damage tracking** — the WM consumes per-surface dirty flags each `COMPOSITE_TICK` instead of full-window presents; decide flag-poll vs. kernel notify event. | 3 — compose | SB3 | ✅ claim 2382 | kind 18 (extend) | The kernel already carries per-surface dirty. **Gate: damage is repaint-granular (one rect writes → one rect repaints).** **DONE 2026-08-31 (claim 2382).** Transport = **extend COMPOSITE_TICK (kind 18)**: `wm_server.on_tick` now packs a per-surface dirty **bitmask** into the previously-reserved `arg1` (bit i <=> user surface i + `user_window_id_base`), so the registered WM learns which surfaces changed each tick (rects via a new `user_damage(id)` accessor). Kernel damage is **rect-granular**: each user `Window` tracks a damage rect (`dx/dy/dw/dh` + `damaged`), union-rect clamped to window bounds (`mark_damage`), `user_fill` records the EXACT written rect (fill-first source this card; migrated plain-store apps stay whole-window until SB5), and `composite()`'s user-window blit repaints **only that region** (recording the consumed rect in `last_dx..`). `dui` gained `damage=` (pending) + `last=` (consumed) columns. Host test pins exact-rect/unions/bitmask/consume; a `user_damage_mask()` spill guard is `.user`-only so fixed high-id layers don't overflow the shift. **Live gate PASS (`--screen, headless VZ):** `verify-live-sb4-damage-tracking.sh` — SB4DAM.BIN fills two rects (8,8,48,48)+(100,60,16,16) with no yield so they union; dui shows `last=8,8,108,68` (not whole-window). Build clean, full host suite green, fmt/coordination ok, BSS PASS (10849208 B). |
| SB5 | **WM compose-N + one final present** — the WM copies RO surfaces into the scanout (or a single composited back-buffer) and issues the final present; per-rect fills gone for migrated apps. | 3 — compose | SB4 | ✅ claim 7397 | — | **Gate: a registered-WM desktop composites entirely from shared surfaces; kernel prints zero fill SVCs for migrated apps.** **DONE 2026-08-31 (claim 7397).** The registered WM binds the SCANOUT writable (`sys_mmap(addr = M33_SURF_SCAN_TAG, bit 62, full-frame, WM-only)` — kernel-owned pages, never ref'd/unref'd, torn down on WM exit/full-frame munmap), composites the N migrated RO surfaces into it, and REQUEST_PRESENT (cmd 3) is the FINAL present (flush only). Chrome moved to the TICK: `driving_award.paint_scene()` (the paint half of composite) runs in `wm_server.on_tick` BEFORE the COMPOSITE_TICK, so the scanout z-order is kernel-layer UNDER the WM's compose-N stores at flush time — the kernel can never overdraw the WM's pixels (the old composite-at-present did). Migrated (surface-backed) windows are SKIPPED by paint_scene while the WM owns the user layer. **Host tests:** scanout bind contract (WM-only/full-frame/writable/idempotent/teardown-without-unref), paint-skip (migrated window untouched), WM-seat refusal. **Live gate PASS (headless VZ):** `verify-live-sb5-wm-compose-n.sh` — SB5WM binds the scanout, SB5OWN renders with plain stores only, the WM composes the surface into the scanout, reads the byte back (`sb5: wm readback=0x5B`), presents, and the `syscalls` report shows **`13 sys_win_fill calls=0`** — zero fill SVCs for the migrated app. Build clean, host suite green, fmt/coordination ok, BSS PASS. |
| SB6 | **Perf payoff** — measure seam B vs. the WMS9 baselines (`artifacts/wms9-fill-reduction.md`). | 4 — payoff/perf | SB5 | ✅ claim 6864 | — | The issue's "measured, not asserted" requirement. **Gate: documented before/after on the WMS9 dynamic + static apps.** **DONE 2026-08-31 (claim 6864).** ONE headless VZ boot, SAME 8x8-grid frame, two paths: SB6OLD.BIN (pre-seam-B control) issues 576 `sys_win_fill` (slot 13) SVCs + 9 presents (kernel blits, `dui blits=20`); SB6WM.BIN registers + binds the scanout; SB6NEW.BIN renders the SAME grid with PLAIN STORES into a bound shared surface (0 fills) and the WM compose-N's it into the scanout (`sb6: wm bytes=196608` copy counter, `readback=0x6B`), final present. The `syscalls` snapshot shows **`13 sys_win_fill calls=576`** — exactly the control's fills, ZERO from the seam-B app — and `dui blits=20 skips=22` (the kernel skipped the migrated window, never blitted it). New kernel observables: `user_blits`/`migrated_skips` monotonic counters + `dui blits=`/`skips=` columns; host test pins the counter semantics. Documented before/after (fills, composite cost, copy volume) in `artifacts/m33-sb6-perf-payoff.md`. Honest finding: a SUSTAINED user-task yield-spin stalls after the first timer preemption (~1s, pre-existing, reproduced with a single app and no WM; SB6 apps pace with `sys_sleep(1)` — the proven blocking path — and the gate is green; the yield-stall warrants its own scheduler card). Build clean, full host suite green (221 driving_award incl. the new counter test), fmt/coordination ok, BSS PASS (685128 B headroom). |


### GitHub tracking ([milestone #17](https://github.com/drawmeanelephant/DipshitOS/milestone/17) — "M33 — Seam B: full pixel ownership")

Each card is a milestone issue: SB1 #694 (closed), SB2 #695 (closed), SB3 #696
(closed), SB4 #691 (done, PR #713), SB5 #692 (done, PR #715), SB6 #693 (done, PR #718). The seam-B umbrella is issue #630.

### Dependency phases (why this order)

```text
Phase 0  contract       SB1 ───────────────────────────────┐ capability + security review
Phase 1  capability     SB2 ───────────────────────────────┘ map into two EL0 spaces
Phase 2  surface        SB3  ─────────────────────────────┐ apps render into shared bufs
Phase 3  compose        SB4 → SB5 ────────────────────────┘ damage → one final present
Phase 4  payoff         SB6  (measured vs WMS9 baselines)
```

Hard edges: SB1 before SB2 (can't engineer the capability without the frozen
mechanism + the security model). SB2 before SB3 (surfaces can't be shared until
the capability exists). SB3 before SB4/SB5 (damage and compose consume real
surfaces). SB6 strictly last (measurement needs the whole path). SB5 is where
per-rect fills actually disappear for migrated apps.

## Notes

1. **Out of scope until every prior card lands:** general shared-*write* mmap
   (ADR 0016 D4 explicit non-goal); any ABI break to slots 12–20 / 63/64; a
   second writer per surface.
2. **Zero-regression contract:** the shim path and unmigrated apps keep
   working exactly as before through the frozen syscalls; migration is opt-in
   one app at a time (the WMS7 mailbox seam is the re-point lever).
3. **The security surface is real and new:** SB2 carries the grant/bound/revoke
   rules of ADR 0016 D2 and must land its close-path unit test — the milestone's
   highest-risk change, exactly why it is card SB2, gated.
4. **WMS9 is the baseline, not SB6's invention.** Any perf claim in SB6 is a
   before/after against `artifacts/wms9-fill-reduction.md`, never an assertion.

_Created by claim 9612 (2026-08-30), splitting issue #630's scoping seed into
gated cards._
