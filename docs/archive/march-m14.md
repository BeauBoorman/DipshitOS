> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone fourteen march — shared user services (living tracker)

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-fourteen's per-card detail and collision-free agent split,
> following the [`march-m13.md`](march-m13.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestone thirteen gave the desktop a file story (manifest, browser,
mutating FS). With text apps and a desktop launcher in place, the wishlist's
**shared-user-services** items are the natural next arc: a clipboard (item
11 — "text apps will make the absence obvious"), application timers (item
12 — apps shouldn't spin sleep loops), and the security/isolation hardening
that grows *alongside* userland power (item 19).

Milestone fourteen is the **shared user services** milestone: S1 clipboard →
S2 app timers → S3 composition capstone → S4 hardening.

The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| S1 | **Clipboard / shared text service.** `sys_clipboard_set`/`sys_clipboard_get` (ADR 0007 slots 38–39), one bounded kernel clipboard buffer (pure BSS, zero heap); NOTEPAD copy/cut/paste + terminal copy. | ✅ | claim 0169 — `verify-live-clipboard.sh` PASS 1/1 on VZ (terminal `clip` set/overwrite/get round-trip + `implemented=40` with slots 38/39 present) | Issue #175; wishlist 11. |
| S2 | **Application timers.** Bounded per-process timer facility (slots 40–41) posting `TIMER` events on the ADR 0009 queue; apps stop spinning (NOTEPAD cursor blink, a live clock, TOP refresh). | ✅ | claim 7323 — `verify-live-timers.sh` PASS 1/1 on VZ (TIMER.BIN arm → block in wait_event → TIMER event → cancel 0/1; `implemented=42`, set calls=3 / cancel calls=2). Wiring NOTEPAD's cursor blink / a live clock / TOP refresh is S3's composition scope. | Issue #176; wishlist 12. |
| S3 | **Composition capstone.** NOTEPAD copy/paste with a timer-driven cursor — S1+S2 proven together. Live gate: `verify-live-m14-composition.sh`. | ✅ | claim 3289 — `verify-live-m14-composition.sh` PASS 1/1 on VZ (clip → exec NOTEPAD selfdemo → pasted → copied → 6 cursor-blink TIMER events → done → exit 43; same-boot syscalls `implemented=42`, clipboard get/set calls=1 each, timer calls=7). Input-seam note (issue #179): keyboard synthesis reports events=0 on this machine, so the gate drives the composition via NOTEPAD's argv selfdemo mode instead of Ctrl+C/V chords; the chord path stays host-tested. | Issue #177; depends on S1+S2. |
| S4 | **Security/isolation hardening.** Process-ownership audit across every EL0-named resource, uaccess validation-depth sweep, resource limits; a hostile EL0 program refused cross-process access. Live gate: `verify-live-hardening.sh`. | ✅ | claim 4482 — `verify-live-hardening.sh` PASS 1/1 on VZ (VICTIM.BIN opens + owns window 2 and yield-loops; HARDEN.BIN, a separate process, attacks fill/present/close/move/query and is refused EINVAL every time → `hardening: refused` + `survived` → exit 44; victim never exits). The audit found and closed ONE ownership gap: the TCP connection's `owner_pid` was set on connect but never enforced — send/recv/close/connect from a non-owner now refuse EACCES (class-A test 341). | Issue #178; wishlist 19. |

## Notes

- The M14 plan lives in issues #175 (S1), #176 (S2), #177 (S3), #178 (S4),
  filed 2026-08-16 alongside the M13 closeout and the pointer-route
  investigation (PR #174) — the roadmap's destination sections are seeded
  ahead of the closeout, per the M12/M13 precedent.
- S1 adds ADR 0007 slots 38–39 (implemented_count 38 → 40, landed
  2026-08-18); S2 adds slots 40–41 (40 → 42) — following slot 37
  `sys_file_free`.
- S4 (claim 4482, 2026-08-18) — the ownership/uaccess/resource-limit
  audit: windows were already per-process (`win_owned_by_caller` behind
  every `sys_win_*`), files/events/timers are per-process by construction,
  and the clipboard/UDP/mailbox/process-control surfaces are documented
  machine-globals; the ONE gap found was TCP — `tcp.owner_pid` was set on
  connect but never enforced, so a second process could send/recv/close
  the connection. send/recv/close/connect from a non-owner now refuse
  EACCES (the connect path refused at the close/teardown step too). The
  hostile-consumer proof (VICTIM.BIN + HARDEN.BIN, two concurrent
  processes) is the card's live gate.
- Zero heap allocation stays a hard constraint for every new kernel
  resource (fixed BSS tables only).
- M8's U4 pointer live proof is a known class-C-only limitation (issue
  #151, claim 4769) — not part of M14 scope.
- Open thread from the M13/pointer work: the synthesized keyboard seam
  currently reports `events=0` (issue #179) — worth confirming no session
  dependency before relying on live input gates.
