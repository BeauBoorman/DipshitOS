---
title: Services & observability
parent: architecture
status: published
tags: [architecture, services, observability]
---

# Services & observability

VirelaiOS has a real service manager and a real debugging stack, both
unusual for a from-scratch OS this size — and both deliberately ordinary
in shape: a declarative manifest launches programs in dependency order, a
supervisor restarts the ones that die, and a set of bounded kernel
sessions answer "what is it doing" without a debugger stub or a resident
agent. Everything on this page is userspace; the kernel's contribution is
three syscall slots and the receipts format.

## Init and service manifests (ADR 0042)

`INIT.ELF` is the first program the boot path runs — the `init` settings
key defaults on — and it does one job: read a manifest, start services in
dependency order, and supervise them afterward. The manifest is
`/host/INIT/SERVICES.JSON`, a single bounded JSON document. JSON was
chosen because Go's standard scanner validates the syntax for free while
a small owned reader enforces the schema — and the document is bounded
hard: 8192 bytes, `{"version":1,"services":[…]}`, one to three service
records, at most six dependency references total, at most eight nesting
levels. Unknown keys, duplicate keys, null fields, wrong versions, and
trailing garbage each refuse the **whole** document by name; there is no
partial parse and no partial activation, because a half-applied service
graph is worse than none.

Each service record is small:

| Field | Rule |
|-------|------|
| `name` | `[A-Za-z0-9._-]{1,28}`, unique, case-sensitive — it is also the crash-receipt label |
| `argv` | 1–8 elements, each ≤ 255 bytes; argv[0] is the share-root binary name ending `.ELF` or `.BIN` |
| `requires` / `wants` | Hard vs optional edges; a missing `wants` is a diagnostic, not a refusal |
| `restart` | `{restart, backoff_base_s, backoff_cap_s, max_restarts, window}` — see below |
| `class` | `boot` or `on-demand` — on-demand means live-toggleable, not socket activation |
| `enabled` | Defaults true; GOSET persists it inside the same document |
| `caps` | Declarative documentation only — exec preserves the creator's principal and cannot drop it, so this grants nothing |

The dependency graph (`svcgraph`) resolves `requires` first: every
required edge must exist — a required service that is disabled counts as
missing, not silently enabled — and a required **cycle refuses the whole
boot by name** (`init: refuse cycle: a-dep -> z-pre -> seat -> a-dep`).
`wants` edges are admitted in lexical order and an optional edge that
would close a cycle is dropped and reported, so optional relationships
can never deadlock a boot. Ties break on lexical names, which makes the
start order deterministic — and therefore assertable by a gate.

Readiness is deliberately simple: a service is "ready" when its exec'd
pid shows `running` in the process table on the next poll — not an
application handshake, not a serial marker the service would have to
know to emit. Dependents wait on all prerequisites' readiness before
starting; if a prerequisite dies *after* a dependent is up, the dependent
keeps running, and only future dependent starts and restarts wait for
the prerequisite to return. A `never`-restart one-shot that completes
with status 0 stays satisfied.

## Supervision

Restart policy (`supervise`) is `never`, `always`, or `on-failure`. For
the two restarting policies the numbers are bounded —
`1 ≤ base ≤ cap ≤ 3600` seconds, `1 ≤ max_restarts ≤ 32`, a rolling
`window` of at most a day — and the delay is exponential-with-jitter:
attempt k doubles toward the cap, then adds an integer jitter in
`[0, base)`, so a fleet of sick services does not retry in lockstep. A
stable run lasting the full `window` resets the streak; exhausting the
allowance enters `failed` instead of spawning forever. Supervisor-driven
stops are not failures — an external kill (status 137) is.

Every failure writes a **crash receipt**: `/host/CRASH/<name>.TXT`, a
tiny latest-only file per service carrying `restart=<k>/<max>`,
`status=<code>`, the chosen backoff, and the app's last eight log lines.
Because the label is the service name, a restarting service overwrites
its own receipt rather than filling the bounded directory — and the
kernel ties the label to the writer's own image identity, so one app
cannot forge another's crash.

The task budget is policy, not accident: an `.ELF` service is budgeted at
four tasks (a Go runtime's typical M set), a `.BIN` at one, and a
manifest that would overspend the pool refuses `task-budget` before any
spawn — the seat's own shell is reserved, never duplicated by init.

Init is also *replaceable*, which is the other half of the design. A
missing, oversized, cyclic, or unstartable manifest prints
`init: refuse <named-reason>` and hands ownership back to the monitor's
direct `wm=` autostart — after first relinquishing every task it started,
so a partial boot cannot strand a second seat. If init itself is killed
or exits before a seat is live, the same fallback engages. The system
boots without supervision; supervision is an enhancement, not a single
point of failure.

<Aside kind="info">

**LIVE-GATED.** `live-boot-order` is the acceptance journey in eleven
runs: a cold declarative boot in manifest order, a **mid-boot kill** —
the gate kills a prerequisite mid-sequence and watches init take the
exit, apply a jittered backoff, restart it with a fresh pid, keep the
already-started dependent running, hold the seat until the prerequisite
is ready again, and land the `restart=1/5 status=137` receipt — plus the
fallback negatives: `init=off`, missing manifest, missing init, corrupt
JSON, oversized document, required cycle, task-budget, unstartable child,
and init itself dying. `live-supervise` kills a child six times from an
external console, pins five jittered retry intervals and the
`restart-limit` give-up, byte-compares the latest-only receipts, and
exercises GOSET's live/deferred/corrupt reload path in the same boot.

</Aside>

## The observability stack (ADR 0043)

The debugging surface is three numbered slots and a set of Go tools that
read them. The design constraints are strict: one session per feature
system-wide, frozen record formats (version 1, little-endian, no
pointers or native Zig layouts on the wire), session tokens minted by the
CSPRNG rather than guessed, session control scoped to the arming pid or
a `cap_proc_admin` principal, and the two secret-carrying syscalls
recorded as fully redacted stubs — never a captured argument.

- **Tracer — slot 81, `sys_trace`.** Arms a filtered session over up to
  eight pids and a bitmask of syscall slots; each traced call produces a
  frozen 896-byte record — pid, tid, a CNTPCT timestamp, the number, all
  six argument registers, the result, the errno magnitude, and up to
  128 bytes of any string argument, captured through uaccess at entry
  while the caller's own apertures are live. A 256-record ring holds
  unread records with a saturating dropped counter; a full ring
  overwrites oldest rather than blocking the caller, and a peek/copy/drop
  reader never loses a record to a failed copy-out. `ARM_EXEC` arms a
  child before it is published, so a spawned program's first syscall is
  already inside the session. STRACE.ELF is the user-facing tool; the
  monitor's older `strace` command remains as the synchronous
  line-printing path.
- **Sampler — slot 82, `sys_profile`.** A 100 Hz statistical profiler
  driven by the *second* timer — the EL1 virtual timer (CNTV, PPI 27),
  armed only while a session exists, leaving the 1 Hz preemption tick
  untouched. Each sample is a 176-byte record: the interrupted EL0 PC
  plus up to sixteen caller PCs walked down the saved-frame chain through
  fault-safe user reads, stopping at the first malformed frame rather
  than trusting a wild pointer. EL1 samples are skipped entirely — the
  sampler never walks a kernel stack. The 1024-record ring and the same
  loss accounting apply, and the cost contract is measured, not asserted:
  the profiler must cost under 2% median overhead on a fixed-work loop,
  under 3% combined with the tracer and a heap poll.
- **Heap analyzer — slot 83, `sys_memstat`.** One call takes a pid and
  returns a frozen 240-byte snapshot: peak and live page counts, region
  counts, per-aperture image sizes (text/ro/data/stack bytes), and the
  current mmap region table — one coherent read under the process lock,
  with exited processes reporting their retained peaks and an EXITED
  flag. The HEAP tool pairs that kernel snapshot with an opt-in
  in-process series the Go program publishes about itself, so the view
  reconciles "what the kernel charges" against "what the runtime thinks
  it has."
- **Logs and crash receipts.** Every app owns a bounded log ring —
  `/host/APPLOG/<APP>.LOG`, 32 lines of at most 256 bytes — written
  through `vi.Log`/`LogLevel` and read by LOGVIEW.ELF. Crash receipts in
  `/host/CRASH/` carry the frozen `app=/outcome=/last-log:` record plus
  an optional `.STK` sibling — a bounded, hash-linked goroutine stack
  captured by `vi.CrashGuard`, the deferred panic handler every service
  installs. CRASHVIEW.ELF renders those receipts and the kernel's own
  fault tombstones.
- **The standing surfaces.** GOTOP.ELF is the process monitor — live CPU
  and memory columns riding the [[processes|`sys_procs` v2 rows]], plus
  trust and GPU tabs — and OBSERVE.ELF is the combined observer: one
  process carrying tracer, sampler, and heap join, because three separate
  viewers would cost three times the task budget.

<Aside kind="info">

**LIVE-GATED.** `live-strace` pins the tracer — filtered capture, wrap,
redaction, and privilege refusals — against a real shell session;
`live-observe` runs the 100 Hz sampler on both cores, holds the overhead
budget, profiles an actual in-guest Go compile with symbols, and drives
the combined OBSERVE session; `live-crash-viewer` renders a real fault
tombstone with resolved symbols; `go-top` and `go-selftest` cover the
monitor surface and the log/receipt write paths.

</Aside>

<Aside kind="note">

**LIMITATION.** These are read-mostly debugging tools, not a debugger:
there is no breakpoint, no single-step, no register write into a running
process, and the sampler's per-window CPU figures quantize to whole
ticks — the tools report the raw counters and let the reader do the
division, because dressing up the resolution would violate the honesty
rule. Init's readiness is likewise coarse by design: "running in the
process table" is all v1 promises.

</Aside>
