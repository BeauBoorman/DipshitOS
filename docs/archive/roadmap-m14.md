# Roadmap archive — Milestone fourteen — shared user services

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

### Milestone fourteen — shared user services (**✅ COMPLETE 2026-08-18 — S1 + S2 + S3 + S4 landed, issues #175–#178**)

> After the file browser, the wishlist's shared-user-services items become the
> natural next arc, in maintainer-preference order: **clipboard** (item 11,
> "text apps will make the absence obvious"), **app timers** (item 12, so
> apps stop spinning sleep loops), and **security/isolation hardening** (item
> 19, grown alongside userland power, not as one giant milestone). M8's
> remaining usability cards (U6–U8) are DONE; U4's live pointer proof is a
> known class-C-only limitation (see issue #151). **S1 done 2026-08-18**
> (claim 0169 — the bounded shared kernel clipboard, slots 38–39;
> `verify-live-clipboard.sh` PASS 1/1 on VZ); **S2 done 2026-08-18**
> (claim 7323 — the bounded per-process app timer facility, slots 40–41;
> `verify-live-timers.sh` PASS 1/1 on VZ); **S3 done 2026-08-18**
> (claim 3289 — the composition capstone: NOTEPAD paste + copy + a
> timer-driven cursor blink in one session;
> `verify-live-m14-composition.sh` PASS 1/1 on VZ); **S4 done 2026-08-18**
> (claim 4482 — the ownership/uaccess/resource-limit hardening audit with
> a hostile-EL0-refused live proof; `verify-live-hardening.sh` PASS 1/1 on
> VZ).

- **S1 — Clipboard / shared text service** (issue #175, wishlist 11): ✅
  done 2026-08-18 (claim 0169): `sys_clipboard_set`/`sys_clipboard_get`
  (ADR 0007 slots 38–39, `implemented_count` 38→40), a single bounded
  kernel clipboard buffer in `kernel/src/clipboard.zig` (pure BSS, zero
  heap) — NOTEPAD gains copy/cut/paste (Ctrl+C/X/V) and the terminal gains
  the `clip` command (`clip <text...>` sets it, `clip` pastes it). Live
  gate: `verify-live-clipboard.sh` PASS 1/1 on VZ.
- **S2 — Application timers** (issue #176, wishlist 12): ✅ done
  2026-08-18 (claim 7323): a bounded per-process timer facility (ADR 0007
  slots 40–41, `implemented_count` 40→42) — ONE countdown timer per
  process in `kernel/src/app_timers.zig` (fixed BSS, zero heap), driven
  from the scheduler tick, posting `TIMER` events (kind 9) on the existing
  ADR 0009 queue, so an app BLOCKS in `sys_wait_event` instead of spinning
  a sleep loop. `TIMER.BIN` proves arm → block → fire → cancel live; live
  gate `verify-live-timers.sh` PASS 1/1 on VZ. (Wiring the timer into
  NOTEPAD's cursor blink / a live clock / TOP refresh is card S3's
  composition scope.)
- **S3 — Composition capstone** (issue #177): ✅ done 2026-08-18 (claim
  3289): NOTEPAD copy/paste with a timer-driven cursor — S1+S2 proven
  together in a real app. The gate pre-loads the shared clipboard with
  `clip`, execs `NOTEPAD.BIN selfdemo` (argv mode, claim 4636's entry
  contract), and observes paste (`sys_clipboard_get`), copy
  (`sys_clipboard_set`), and a timer-driven cursor blink (6 TIMER events,
  arm + re-arm per fire) in ONE session, then NOTEPAD exits 43 through the
  real lifecycle. Live gate `verify-live-m14-composition.sh` PASS 1/1 on
  VZ (`implemented=42`, slots 38/39/40 all counted in the same boot).
  Input-seam note (issue #179): synthesized keyboard reports `events=0` on
  this machine, so the gate drives the composition via NOTEPAD's argv
  selfdemo instead of scripted Ctrl+C/V chords — the chord path stays
  host-tested and regains live coverage when the seam recovers.
- **S4 — Security/isolation hardening** (issue #178, wishlist 19): ✅
  done 2026-08-18 (claim 4482): the audit covered every EL0-named
  resource — windows (already per-process via `win_owned_by_caller`),
  file handles, event queues, app timers (per-process by construction),
  and the documented machine-globals (clipboard, UDP, mailbox,
  process-control) — plus the uaccess pointer/length sweep and the
  bounded-pool refusal audit. The ONE gap found and closed: the TCP
  connection's `owner_pid` was recorded on connect but never enforced, so
  a second process could send/recv/close it; a non-owner is now refused
  EACCES on send/recv/close/connect (class-A test 341). The hostile-EL0
  proof runs TWO concurrent processes (VICTIM.BIN owns window 2 and
  yield-loops forever; HARDEN.BIN attacks fill/present/close/move/query
  and is refused EINVAL every time, then exits 44 — the victim never
  exits). Live gate `verify-live-hardening.sh` PASS 1/1 on VZ.

See [`march-m14.md`](march-m14.md) for the per-card tracker.
