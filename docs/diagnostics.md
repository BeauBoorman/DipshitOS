# Diagnostics surfaces

The census behind #3189's merge-or-split decision: what each diagnostics
surface reads, who it answers for, and where the data overlaps.

**Verdict: split.** The surfaces read four different kernel planes for
three different audiences, and each surviving app carries its "why I'm
separate" line in its header. The one shared pull — the trace-session
drain — is deduplicated in `virelai/strace` (`Session.Drain`).

## The surfaces

| Surface | Data source | Answers | Shape |
| --- | --- | --- | --- |
| `LOGVIEW.ELF` (`user/go/logview`) | The bounded per-app ring files under `/host/APPLOG` (`vi.AppLogNames` + `vi.ReadLog`; each producer owns its own ring), live and append-only | "What is app X logging right now" — a follow-tail across every producer | appkit window + `-text` serial mode + `/host/LOGEXPORT` snapshot on E |
| `CRASHVIEW.ELF` (`user/go/crashview`) | Frozen receipt files on the crash share (`vi.CrashReceiptDir`, `/host/crash` until the alias probe answers): `APP.ELF.TXT` outcomes + `.STK` panic stacks, `pid-APP.txt` kernel tombstones | "What just died and why" — post-mortem | appkit window + `-text`; `R` reopens the recorded basename under an in-process M94b tracer session |
| `GOTOP.ELF` (`user/go/top`) | Point-in-time kernel snapshots: `sys_procs` v2 rows, the net-stats snapshot, `sys_gpucomp` counters, the mount table, the grant table + denial ring (slot 89 ops 0/2, #2982), `/host/AGENT/AUDIT/` and `/host/RCPT.TXT`, per-image measurement | "What is running now, and what is its posture" — a monitor with kill | appkit window, six tabs |
| `OBSERVE.ELF` (`user/go/observe`) | Nothing pre-existing: it ARMS a bounded session on one live target — filtered tracer + 100 Hz sampler + the 1 Hz kernel/in-process heap join | "Watch this one workload" — a development session | CLI only (`-p <pid|name>`, `overhead`) |
| `STRACE.ELF` / `PROF.ELF` (`user/go/strace/cmd`, `user/go/prof/cmd`) | The same armed sessions, one primitive each | The building blocks observe composes: a syscall stream, or a sampled CPU profile with symbolization | CLI only |
| `HEAP.ELF` (`user/go/heap`) | `sys_memstat` joined with the target's own post-GC sample file | One memory question — is the heap trending up; observe's heap leg is this same loop | CLI only |

## Where the data overlaps, and what was done about it

- **Trace-session drain** — the read→render→console loop over
  `strace.Session` was open-coded in STRACE.ELF (twice), OBSERVE's
  `drainTrace`, and CRASHVIEW's reopen drain. `strace.Session.Drain`
  carries it now; per-consumer policy (save counting, 64-row retention,
  exit detection, batch bounds) stays in the callback.
- **Process-name → pid walks** — three walkers over the same `sys_procs`
  scan exist (`prof.FindTarget`, `heap.Resolve`, `strace`'s `resolve`),
  and they are not interchangeable: `FindTarget` folds case, requires a
  running match, and checks numeric pids against the table; `Resolve`
  matches case-sensitively and re-reads a suspect scan once; `resolve`
  folds case, requires exactly one not-exited name, but passes a numeric
  pid through unchecked. Merging them changes observable behaviour — a
  consolidation is a separate card, not this one.
- **Log tails inside crash receipts** — a receipt's `last-log:` section
  is the kernel's frozen cut of the same ring logview tails live. It is
  producer-side embedding (crashguard writes it into the receipt), not a
  second read of the ring, so there is no guest-side pull to deduplicate.
- **Denial receipts** — the slot-89 op-2 ring (#2966's grounding, #2982's
  surface) has exactly one consumer: GOTOP's trust tab. Nothing to dedup.
- **Liveness probes** — `vi.Probe` serves STRACE's exit watch, observe's
  `running`, and crashview's trace liveness alike; already shared.

## Why not one face

- Three audiences: "why is X broken" (crashview, post-mortem), "what is
  it doing right now" (logview's follow-tail, GOTOP's monitor), "watch
  this workload" (observe/strace/prof sessions). One window answers none
  of them faster, and the two windowed apps disagree about what a row is
  (a log line vs a receipt vs a process).
- The marker vocabularies are load-bearing contracts: `logview:` across
  go-selftest's five legs, `crashview:` across live-crash-viewer's six
  runs, `observe:` in live-observe, `top:` in ~18 specs. Deleting
  binaries means retargeting every leg for zero new capability.
- GOTOP's toolbar is already four compressions deep (its own header
  documents the M109c/M111d/M113e/M134b squeezes); a logs or receipts
  tab has nowhere to live.

## Noted for later cards

- Bug-report bundling — one artifact carrying receipt + log tail +
  posture; deliberately out of scope here.
- Proc-name resolution consolidation — the three walkers above, unified
  only if their differing match contracts are reconciled first.
