# ADR 0047: sys_procs v2 — a self-describing, size-tagged snapshot row

- Date: 2026-10-13
- Status: **Accepted** — shipped by card #2198 (`kernel/src/syscall.zig:562,1105`;
  bench row `tools/gate/bench/corpus.tsv:33`). Card #2198 was explicitly
  an ABI decision; this ADR landed before the kernel code in the same PR.
- Card: **#2198** (real per-process CPU/mem in `sys_procs` → `vi.ProcRow` →
  GOTOP + PULSE). Index context: the Go-apps second pass.
- Related: ADR 0007 (syscall ABI), ADR 0024 (principals — the frozen row
  omits them), ADR 0027 (threads), ADR 0043 (sys_memstat observability).

> `sys_procs` (slot 7) emits a frozen 40-byte row per non-free process:
> `u64 pid` @0, `u64 state` @8, `u64 exit_status` @16, `name[16]` @24.
> GOTOP and PULSE can only show counts because that row carries no
> utilization figure at all. The card asks for real CPU and memory. This
> ADR decides how the wire grows without breaking the frozen shape, where
> the counters come from, and what "honest" means for each figure.

## Grounding (observed in tree `70a28bf6`, 2026-10-13)

- **The counters already exist.** `Process.cpu_usage` is incremented by
  `inc_cpu_ticks` (process.zig:1327); `Process.mem_usage` counts charged
  dynamic pages (#2115); `AddrSpace` carries owned page counts
  (text/data/stack/ro/interp/lib) plus `dynamic_page_count`; the kernel
  stack is `Process.kernel_stack.pages`. No new accounting counter is
  needed — the card's "land it first" clause is already satisfied.
- **The CPU charge only covers core 0.** `inc_cpu_ticks` is called from
  `scheduler.on_tick` (scheduler.zig:2613-2620), and `on_tick` runs only
  inside `tick()`'s `c == 0` housekeeping gate (scheduler.zig:3108-3119).
  A task scheduled on cores 1–3 is *never* charged — measured evidence:
  the SMP steal log lines in gate serials show multi-core runs while `ps`
  CPU columns stay near zero for non-core-0 workloads. This is a real
  defect the card's honesty rule forces us to fix first: exporting the
  counter as-is would publish silently-wrong figures.
- **The tick is the sample.** `timer.period_ns = 1_000_000_000`: one
  tick-charge ≈ one attributed CPU-second per beat per core. `cpu_usage`
  is therefore a *sampled* tick count — real, not synthesized from wall
  time — but coarse: per-window percentages quantize heavily. The wire
  exports the raw cumulative counter plus the machine tick total; readers
  derive rates/shares and must not dress up the resolution.
- **Existing negotiable-ABI precedent.** `handle_dir_list` dispatches to
  `handle_dir_v2` on a bit inside `args[3]` (syscall.zig:2041) — the
  codebase already overloads a register to select a descriptor version.
- **v1 is pinned hard.** `process.snapshot_row_bytes = 40`, the
  byte-frozen host test (`process: sys_procs snapshot row is byte-frozen
  across principals`), and `vi.ProcRow`/`vsys.ProcRow` decode geometry
  (pid@0/state@8/exit@16/name@24, `unsafe.Offsetof` pinned in
  ipc_test.go) must all keep passing untouched.
- **`a1` is treated as a plain byte length by every test hook.** The
  host-test fake kernels write `unsafe.Slice(ptr, a1)` — a `max` carrying
  tag bits would blow them up. Any negotiation must therefore be a *new*
  caller path, not a change to `Procs`'s wire behavior.

## D1. Negotiation rides in `max`'s top byte — never a positional arg

`sys_procs(buf, max)` gains a version request in the *high* byte of the
existing `max` argument:

```
ver_req  = max >> 56
max_bytes = max & 0x00FF_FFFF_FFFF_FFFF
```

- `ver_req ∈ {0, 1}` → **v1 path, bit-for-bit identical to today**: 40-byte
  rows, whole-row floor on `max_bytes`, return = row count. Every existing
  caller passes a real buffer length (< 2^56 always), so no unmodified
  caller can set the tag — this is why the tag rides `max` and not a
  spare register: `x2`/`x3` of an svc2 caller are *uninitialized caller
  garbage*, and a magic-value probe has a nonzero false-positive rate.
- `ver_req ≥ 2` → the kernel emits its newest row format ≤ `ver_req`
  (v2 today) and returns the row count, same as ever. The tag byte is
  *advisory*: rows self-describe (D2), so a reader never trusts the
  request it made — it reads what actually arrived.
- Old kernel + new reader: the old handler ignores the tag and floors the
  untagged length to whole 40-byte rows inside the reader's
  `len(dst)·80`-byte buffer — a well-formed v1 stream the row-0
  discriminator decodes with the new fields zeroed.
- New kernel + old reader: top byte 0 → frozen shape. Bit-for-bit.

## D2. The v2 row is 80 bytes and self-describing

```
+0   u32  row_version    = 2
+4   u32  row_bytes      = 80
+8   u64  pid
+16  u64  state
+24  u64  exit_status
+32  u8   name[16]        (NUL-padded, same as v1)
+48  u64  cpu_ticks       (cumulative attributed scheduler ticks)
+56  u64  mem_bytes       (owned resident footprint, bytes)
+64  u64  total_ticks     (Σ smp.core_ticks — machine denominator;
                           identical on every row of one snapshot)
+72  u32  ncores          (online cores at snapshot time)
+76  u32  total_pages     (allocator pool pages — machine memory
                           denominator; ×4096 for bytes)
```

- **Self-describing header first.** `row_version`/`row_bytes` lead the
  row so a reader can walk a stream whose stride it does not know. The
  discriminator is unambiguous without a return tag: a v1 stream's row-0
  u32@0 is a pid (< `max_processes`, i.e. < 16) and its u32@4 is
  `pid>>32`, i.e. 0 — `row_bytes == 0` fails sanity, so the stream is v1.
- **v1 field content, shifted.** pid/state/exit_status/name are the v1
  semantics verbatim — the row is additive *information*, not a new
  process model.
- **Denominators ride the row.** `total_ticks` and `total_pages` repeat
  on every row (they are machine-wide, not per-process). That costs 12
  bytes per row × ≤16 rows and buys readers a complete utilization
  picture from a single snapshot — no second syscall, no divergence
  window between a procs read and a machine-stats read.

## D3. The decode rule: stride from the row, fields by fit

A reader that sees `row_version ≥ 2` walks rows at `row_bytes` and decodes
a field **only if the field's end offset fits inside `row_bytes`** —
anything beyond is zero, never garbage. A v2 reader on a future v3
stream therefore still walks every row and gets every field it knows.
`row_version < 2` (or a failed header sanity check) means the frozen
40-byte stride.

`vi.ProcRow` grows the decoded fields (`CpuTicks`, `MemBytes`,
`TotalTicks`, `NCores`, `TotalPages`, `RowVer`) *appended after* the
pinned `NameBuf` — `Offsetof(NameBuf) == 24` stays true. `vi.Procs`
keeps its exact wire behavior (untagged `max`, v1 decode) so every
existing caller — `Probe`, `WmPeers`, the `vsys` mirror — is untouched.
The negotiated read is a **new** seam, `vi.ProcsV2`, because the host
test hooks treat `a1` as a byte length and cannot see a tag.

## D4. CPU attribution moves to the per-core tick

`on_tick`'s charge block moves into `tick()` immediately after
`smp.core_ticks[c] +%= 1`, inside the EV+kernel `svclock` hold that core
already takes — before the `c == 0` housekeeping gate, so **every** core
charges the task it interrupted, not just core 0's. Consequences:

- The charge keeps the existing lock domain (`evk_taken`); `cpu_usage`
  stays a plain counter, no atomics.
- A skipped `try_take` loses the sample for that beat on that core —
  the same cadence-loss semantics the code already documents, now
  honestly per-core.
- The cpu_limit kill arm (`kill_pending` + status 141) follows the charge
  and now works for tasks running on cores 1–3 too — that is a fix, not a
  behavior change worth preserving.
- `total_ticks` = Σ `smp.core_ticks` over online cores; `ncores` lets a
  reader rescale between share-of-machine and share-of-one-core.

## D5. mem_bytes is the owned resident footprint, not the rusage field

`Process.mem_usage` counts only *charged dynamic* pages (demand heap,
mmap fault-ins). The row instead reports the honest resident footprint:

```
mem_pages = text_pages + data_pages + stack_pages + ro_pages
          + interp_pages + lib_pages + dynamic_page_count
          + kernel_stack.pages
          + segment_pages(len) for each segment with pages == 0 && len > 0
            (static boot backing — the payload's .usertext/.userbss)
```

× 4096 → `mem_bytes`. This is what the monitor's `ps` MEM column aspires
to (it currently misses ro/interp/lib/dynamic/static spans); the snapshot
does the full sum once, in one place.

## D6. Reader-side display contracts

- **CPU%** = `100 · Δcpu_ticks · ncores / Δtotal_ticks` between two
  snapshots (share of one core, `top`-style). With no prior snapshot the
  reader shows the lifetime share `100 · cpu_ticks · ncores /
  total_ticks`. A v1 stream or ENOSYS yields `RowVer < 2` and the readers
  render the old figures byte-identically — the gate leg for old-shape
  decode is a host test feeding a 40-byte stream through `ProcsV2`'s
  decoder.
- **MEM** = `mem_bytes`, formatted; share `mem_bytes / (total_pages·4096)`.
- **Honesty bound**: the tick is 1 Hz, so windowed CPU% quantizes to
  whole tick-charges per refresh. Readers show it as-is; nothing
  interpolates.

## Consequences

- v1 callers (`Procs`, `vsys.Procs`, monitor `ps`, every gate spec that
  reads `procs` output) observe zero change — the frozen row is untouched
  and the byte-frozen test still pins it.
- New callers get utilization in one snapshot. GOTOP gains CPU%/MEM
  columns + sort; PULSE's Overview gains real bars and the Procs tab
  gains both columns.
- The extension rule is now in-band and repeatable: any future field is a
  `row_version` bump + tail bytes; readers never guess.
- Kernel cost: one extra BSS scratch (16 × 80 B), one marshal loop, the
  per-core charge move. No new syscall slot, no new locking domain, no
  allocation.
