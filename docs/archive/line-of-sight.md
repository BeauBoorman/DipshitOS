# Line of sight — what's workable on the current board

Status: **RETIRED 2026-10-20 (card #2782)** — `docs/status.md` is the
canonical board view; this file is no longer maintained as a claim-picker.
It is kept as a historical record because its Z-ladder and dialect-boundary
sections are still cited by `tools/verify-zc-corpus.sh`,
`tools/build-zc-host.sh`, and ADR 0035. The board tables below reflect
2026-09-01 and are stale; consult the tracker. Rows 4 and 5 of the FAT32
pain-points table are card #2759's subject (#2759).

> Original header (2026-09-01): maintained manually against GitHub; sources:
> GitHub API (milestones/issues), `origin/main` at `1346855`, claims
> 7710/9459/7599/0098/1263. **observed** = merged/live-gated, not "should
> land soon".

## M34 — FAT-free storage (milestone #21)

The other agent's thread. HF1–HF4 are **merged on main**; HF5–HF7 are the
remaining steps.

| Card | Issue | State | Evidence / what remains |
|------|-------|-------|-------------------------|
| HF1+HF2 — wire + transport + `vf ls`/`vf cat` | #735/#736 | ✅ **merged** (PR #745, claim 7710) | queue 5, VF_PROBE 32 KiB device-write spike, LIST/READ/STAT, `VFWire` module + fixtures, `verify-live-vf.sh` |
| HF3 — mutation (OPEN/CLOSE/WRITE/TRUNCATE/RENAME/MKDIR/DELETE/FSYNC) | #737 | ✅ **merged** (PR #747, claim 9459) | additive ops 0x04–0x0b, 8-slot host handle table, WRITE ≤ 32,763 B chunks, FSYNC durability |
| HF4 — app delivery from the host folder | #738 | ✅ **merged** (PR #769, claim 7599) | drop a `.ELF` in the share, `exec` it; desktop manifest re-pointed; dual path with ESP until HF6 |
| HF5 — user-data migration to the host folder | #739 | 🔶 **open** | re-point every `/data` consumer (settings, notepad, calc history, downloads, screenshots, shell history, clipboard); `/data` deprecation line |
| HF6 — FAT removal | #740 | 🔶 **open** | delete `fat.zig` + post-exit virtio-blk + DATA partition; slim image; gate fleet to one shared read-only boot image |
| HF7 — CLONE → `clonefile` COW dedup | #741 | 🔶 **open** | the worktree capstone; host-side du before/after under `artifacts/` |

**Workable now:** HF5 (user-data migration) is the largest remaining card —
every persistence consumer re-points to the host folder. HF6 (FAT removal)
is the deletion payoff and must be last. HF7 (CLONE dedup) is parallel
(depends only on HF3) and is the worktree capstone.

## FAT32/FAT pain points — inventory and coverage

Every documented FAT pain point, the card that fixes it, and whether that
card has actually landed. Two rows are **GAPS** — the channel as merged does
not fix them, and they are wire-shape decisions already baked into fixtures.

| # | Pain point (documented where) | Fixed by | Status |
|---|-------------------------------|----------|--------|
| 1 | **2048-byte read cap** — `fat.cat`/`read_file` honest 2048-B cap; `esp_content_max` = 2048 B (claim 6344, m4 logs) | HF1/HF2 READ-with-offset, 32 KiB reply | ✅ merged — reads are stateless streams to arbitrarily large files |
| 2 | **2048-byte write/truncate cap** — `write_content_max` = 2048, `sys_file_truncate` ≤ 2048 (ADR 0007 slot 36; `file_table.zig` staging) | HF3 WRITE/TRUNCATE (32,763-B chunks) **at the channel** | ⚠️ **partial** — the channel is cap-free, but the userland syscall ABI (ADR 0010 slots 23–27, `file_table.zig`) still routes through FAT with the 2048 caps until HF5 re-points it. Notepad/settings/downloads still hit the old caps today |
| 3 | **8.3 short names** — leading-dot names unrepresentable (`.recent` → `RECENT.SAV`), padded names (`"CALC    "`), case-insensitive mapping (march-m25 F5, m13 logs) | HF2 LIST serves real host names | ✅ merged — names are host-truth, case-preserving, leading-dot OK |
| 4 | **Long filenames truncate at 31 bytes** — the merged LIST row is `[name 31][type u8][size u64le]` (40 B), inherited from ADR 0010's 31-char display name | **card #2759** | ❌ **GAP → card #2759's subject** — a macOS file with a >30-char name truncates in the guest listing. Card #2759 retires the legacy 31-byte LIST's last consumers (v2 snapshot path or explicit 31-byte refusal by name) |
| 5 | **No modification timestamps** — "Timestamps 'N/A' per FAT32 short-name limitation" (march-m25 F2, claim 0434); STAT as merged is `[size u64le][type u8]` — **no mtime** | **card #2759** | ❌ **GAP → card #2759's subject** — the landed op serves size+type only, so the file manager's properties panel still shows "N/A" for dates. Card #2759 appends `mtime_sec u64le` + `mtime_nsec u32le` to STAT with old/new length acceptance |
| 6 | **Content-pool exhaustion / silent empty reads** — files listed but never content-loaded (`len=0`) when the 8192-B pool overflows → history recall no-op + clobbering (claim 6344) | HF4/HF5 (apps + user data leave the ESP window) | 🔶 open — HF4 landed (apps off the ESP); the class dies for good when HF5 moves user data out |
| 7 | **kstack pressure from FAT staging** — 2×2048 staging + FAT buffers overflowed the 8 KiB kstack (m13 log) | HF6 (fat.zig deleted) | 🔶 open |
| 8 | **Image-rebuild iteration loop** — ~50 apps baked into the ESP; rebuild the image to test an app | HF4 | ✅ merged — drop-`.ELF`-and-exec (PR #769, claim 7599) |
| 9 | **Disk image bloat / ceremonies** — 128 MiB image, 36 MiB DATA partition, expanding/resizing | HF6 | 🔶 open |
| 10 | **Per-gate writable image copies + shared-disk locks** (`gate_shared_disk_lock` contention) | HF6 (one shared read-only boot image) | 🔶 open |
| 11 | **virtio-blk reset at ExitBootServices** — post-MMU queue re-arm footgun (claim 6420) | HF6 (post-exit blk path deleted) | 🔶 open |
| 12 | **8.3 path normalization / prefix routing complexity** (`/esp` vs `/data`, traversal defense, case folding — march-m10 F2) | HF5/HF6 (path canon re-pointed, fat deleted) | 🔶 open |

**Bottom line:** the read-side pain is dead (HF1/HF2). The write-side caps
die at the channel but **live on in the syscall ABI until HF5**. Two pain
points (long names, mtime) are **not covered by any merged card** and should
be decided before HF5 lands — either fold an mtime/name-widening wire
revision into HF5 or file them as follow-up cards, or the "timestamps N/A"
and truncated-name behaviors quietly become permanent.

## Code processing / in-guest Zig compiler (self-hosting lane 2, #708)

The "keep progressing" thread. Core landed (Z0–Z4b closed); VL6's run
consumer landed with the snake (claim #988) — the open end is the Lane 0
hygiene cards + the #706/#707 umbrellas below.

- **Landed (claim 0098, antigravity):** `user/src/lib/asmenc.zig` (encoder
  extraction, VL1), widened assembler set (VL2), `user/src/zc.zig` tokenizer
  + recursive-descent parser + codegen (VL3/VL4), `exec ZC.BIN` in-guest
  compile → ELF32 the loader runs (VL5, `verify-live-zc.sh` PASS 1/1,
  exit 72 observed). Subset: `fn` with typed params, let/const, if/else,
  while, return, calls, block scoping, int/bitwise/compare/logical exprs,
  `svc` builtins for write/exit/file ops. Bounded: ≤32 functions, ≤512
  lines, zero heap.
- **VL6 (issue #708): the GUI surface is built AND has its first live RUN
  consumer (claim #988, 2026-09-04).** The win/draw svc builtins
  (win_open/fill/present) shipped with Z0.5; the open end was run parity —
  the corpus vl6 fixture was compile-only because proving pixels needs a
  window/pixel-observing gate, not a serial log. Claim #978 closed that:
  an in-guest-compiled Snake (`tests/zc-corpus/snake-*.z`, corpus case
  `snk`) is the first live consumer of the VL6 surface AND of the raw
  `zc.svc(<literal>, …)` escape hatch — its per-frame loop polls the ADR
  0009 event queue with `zc.svc(21, &buf)` and renders with
  win_open/fill/present. Proof is display-backed: `verify-live-snake.sh`
  boots VZ with the GPU attached, compiles the group in-guest under
  `strace exec`, runs SNAKE.ELF windowed (ordered markers, exit 72), and
  asserts the game's pixels (dark board + green head + pink food) in host
  framebuffer captures. The corpus `snk` case is dual-run (host zig +
  in-guest zc, byte-equivalent behavior). The rest of the ladder below
  (Z1a–Z4b) is fully landed with its corpus fixtures — dual-run in
  `verify-zc-corpus.sh`.
- **Sibling lanes (milestone #20):** #706 Lane 0 hygiene — **split 2026-09-01
  into four parallel cards**: #773 (re-verify live-desktop + gate-inventory),
  #774 (live-asm/disas fixture drift), #775 (M20 tabs probe-decode red),
  #776 (VZ CI wiring); #706 is now the umbrella — and #707 Lane 1 window
  depth (WM1–WM4: window ceiling 4→8 via page-pool back-buffers, mission
  control, taskbar depth) — all OPEN, unclaimed. (#707 note: M33's userland
  composition may supersede WM1's kernel page-pool framing — check before
  claiming.)

### The leveled Zig support ladder (Z0.5 → Z4, step-at-a-time)

> Aspirational plan (2026-09-01): split the "Zig in the system" dream into
> steps so each is independently claimable and honestly gated. The target
> is concrete — **this repo is pinned to Zig 0.16.0** (`.zigversion`,
> `minimum_zig_version = "0.16.0"`), so "Zig 0.16 support" means the
> in-guest compiler reaches parity with the language the host project is
> written in. Full 0.16 conformance (comptime, std, error sets) is a
> research project; the ladder makes the *dialect* the goal, with a real
> gate at the top: **a `.z` source in the shared subset compiles on host
> `zig 0.16` AND in-guest `zc`, and behaves the same.** That's testable.
>
> Two facts from the current code decide the order (observed, claim 0098):
> (1) the gate source is `fn main() void { svc(3, 72); }` — **`svc` is a
> zc keyword, NOT valid Zig 0.16**; (2) `build_elf32` emits **code only**
> — there is no data segment, so strings/arrays/structs all need one
> added before they can exist. Every step below is one agent / one PR
> sized (the VL1–VL6 pattern), removes exactly one bound, and its gate
> stays honest.

| Step | Issue | Goal | Gate | Removes / adds |
|------|-------|------|------|----------------|
| **Z0 — Spine** | — (landed, claim 0098) | scalar programs, arithmetic, control flow, `svc` builtins, ELF32 | ✅ **landed** (claim 0098, VL1–VL5); `verify-live-zc.sh` PASS | — (bounds: ≤32 fns, ≤512 lines, 8 KiB code buffer, zero heap, one file) |
| **Z0.5 — Dialect contract** | #749 | make the spine *valid Zig 0.16*: `svc(3,72)` becomes a call through a magic `@import("zc")` prelude (zc resolves it in-guest; a real `zc.zig` shim with `asm volatile ("svc #0"…)` exists on the host), so sources parse under `zig 0.16` | the existing `MAIN.Z` rewritten in the honest dialect **parses + type-checks** under host `zig build-exe -target aarch64-freestanding` (compile-only); in-guest `verify-live-zc.sh` unchanged green | removes: "sources are not Zig" — THE step that makes conformance reachable; every later step writes in the honest dialect |
| **Z1a — Data segment + strings** | #750 | a `.rodata` blob appended to the ELF (same PT_LOAD); `"…"` tokenizes, lands in the blob, evaluates to (addr,len); a write builtin prints it | in-guest: a program prints a string literal byte-exact; host `zig 0.16` parses the same source | adds: data segment (first structural change to `build_elf32`); grows the 8 KiB output buffer (string data consumes it) |
| **Z1b — Arrays** | #751 | fixed-size arrays in BSS/stack; scaled-index ldr/str | fill an array in a loop, write it out byte-exact | adds: index addressing |
| **Z1c — Structs** | #752 | field offsets, member load/store | a two-field struct serialized to bytes | adds: aggregate types + offsets |
| **Z1d — Pointers** | #753 | `&x`, `x.*`, pointer params | swap through pointers; pass buf+len to a fn | adds: address-of/deref, indirect calls (`blr`) groundwork |
| **Z1e — Control-flow depth** | #754 | `for (0..n)` + array iteration (reuse while lowering); `switch` as a cond-chain (jump tables later) | a for-loop sum; a switch mapping an int to a string | adds: range/array iteration, multi-way branch |
| **Z1f — Enums** | #755 | tagged constants, cast to/from int | an enum-valued switch, run green | adds: enum type |
| **Z2a — Heap** | #756 | `sys_mmap` (M29 anonymous) + a bounded bump arena exposed through the prelude | read a file, build a string in heap, write it back byte-exact | removes: zero-heap bound |
| **Z2b — defer + fn pointers** | #757 | scope-exit cleanup lowering; `blr` through a function pointer | a program using both, run green | adds: cleanup + indirect calls |
| **Z3a — Multi-file compile** | #758 | `zc a.z b.z out.elf`, cross-file symbol table | two files, cross-file call, run green | removes: one-source-file bound |
| **Z3b — stdz subset** | #759 | fmt (u64→dec/hex), string builder, ring buffer in `lib/`, compiled in | a stdz-using program ships as an app | adds: the first reusable library |
| **Z4a — Corpus parity (compile)** | #760 | a fixture corpus of `.z` sources; every source compiles with host `zig 0.16` (compile-only) AND guest `zc` (compile + run), behavior pinned | corpus green on both sides | the "dual-compile" gate, made real |
| **Z4b — Behavioral parity (run)** | #761 | where host 0.16 output can run — needs a **host link contract** (linker script + target recipe; the loader is already ELF64-class-agnostic, so no kernel seam) — byte-equivalent behavior | dual-run comparison on the contract | the top of the ladder; explicitly a negotiation, not assumed |
| **S3 — Dialect lift** (post-ladder) | #1455 | shrink the boundary the ladder drew: `break`/`continue` in `while`/`for`, with the body's open defers unwound on the jump | `live-zc` run 02 + `tests/zc-corpus/s3-break.z` (`s3` in the corpus dual-run) | removes: the "break/continue are non-goals" bound. Not a rung — a lift; the corpus and this boundary move together |

**Honest notes on the ladder:**

- **Z0.5 is the real unlock.** The `svc` keyword means today's `.z` sources
  are *Zig-ish*, not Zig — every feature added before the dialect is made
  honest bakes in more non-Zig syntax that conformance later has to unwind.
  The magic-import trick (`@import("zc")` resolved by the compiler
  in-guest, shimmed by a real `zc.zig` on the host) is small and proven
  (Zig's own `@import("std")` is the same shape), and it makes every later
  step's gate "host parses it" instead of "host rejects it, trust us".
- **The 8 KiB code buffer is a wall.** Z1a's string data + arrays + structs
  will consume it fast; growing the output bound (8 → 32 KiB, or
  segment-based) should ride along with Z1a, not wait.
- **The loader is already ELF64-class-agnostic — the wall is the layout
  contract.** Verified 2026-09-01: `kernel/src/elf.zig` accepts `ei_class`
  1 *or* 2, and `mkdyn-elf.py` already emits ELF64 `.SO` files. What host
  `zig 0.16` output actually violates is the fixed base `0x00400000` (host
  emits `0x1000000`), the ≤2-PT_LOAD rule (host emits 3), the ≤256 KiB
  image cap (a trivial program measures ~283 KiB with debug info), and
  entry-0 (needs `export fn _start`). **Z4b's host link contract lands
  (2026-09-03):** `tools/zc-host-link.ld` + `tools/build-zc-host.sh` —
  `zig build-exe -target aarch64-freestanding -O ReleaseSmall -fstrip
  -fno-PIE -fno-entry -z max-page-size=4096 -T tools/zc-host-link.ld` on a
  root that concatenates the fixture sources (the flat Z3a namespace) with
  an `export fn _start` epilogue calling `main`; the script merges text +
  rodata into one R+X PT_LOAD at `0x0040_0000` and data + bss into a
  second R+W PT_LOAD starting EXACTLY at `p_memsz[0]`, and
  `tools/check-zc-host-contract.py` validates the image against elf.zig's
  parse rules (entry inside the text file bytes, ≤256 KiB, ≤2 loads).
  Host-built images of every corpus case run in-guest with byte-equivalent
  behavior (dual-run in `verify-zc-corpus.sh`). So the honest answer to
  "how realistic is 0.16" is now: dialect parity AND run parity for the
  corpus, on a host-side link contract — no kernel seam.

  **The z2a zc-leg OUT.TXT flake was ROOT-CAUSED and FIXED 2026-09-03**
  (claim #899): the zc-compiled z2a fixture intermittently (~2/7 boots
  across a sweep) exited 72 with `heap-ok` while its OUT.TXT round trip
  came back missing or wrong, while the Z4b host-built z2a image did the
  identical round trip byte-exact. Root cause: an SMP data race in the
  guest file channel — the virtio_file request ASSEMBLY into the
  module-global `vf_req_buf`/`vf_write_buf` ran OUTSIDE the spinlock
  (only submit/wait/free was locked), so two cores (the app on the
  secondary, the shell's history save / exec reads on the primary)
  spliced encodes into one request — the host's `request length
  mismatch` refusals — and the app's silently-ignored failures left
  OUT.TXT empty/missing while it still exited 72. Fix: the lock now
  covers encode+exchange in `exchange()`/`write()`; timed-out chains are
  PARKED (never recycled until their reply is observed —
  `virtio_custom.park_chain`/`reap_parked`); timeouts re-kick and retry
  once; the wait budget grew 32M→320M (~155 ms → ~1.5-2 s measured).
  Verified on VZ: z2a zc leg 12/12 consecutive PASS with zero length
  mismatches (7 of the 12 ran the app on the secondary core — the
  previously risky condition), full corpus sweep 12/12 cases × both
  legs, `verify-live-zc.sh` PASS. Evidence under `artifacts/claim-899/`;
  the corpus gate is now trustworthy for unattended CI.
- **VL6 (the GUI consumer, #708): shipped with Z0.5; live run parity landed
  with the snake (claim #988).** The win builtins are svc-builtin work
  (win_open/fill/present) — no new language features. The first GUI app in
  the honest dialect is the Snake fixture (`tests/zc-corpus/snake-*.z`),
  proven windowed on a display-backed boot (`verify-live-snake.sh`), not
  just compile-only like the vl6 fixture.
- **Z1e and Z1f can pair** in one claim if reviewers prefer — they're both
  statement-lowering; the split is for single-agent sizing.
- **The corpus accumulates from day one.** Every Z step ships its
  `tests/zc-corpus/<step>.z` fixture with the step (declared in Touches), so
  Z4a only adds the runner + pins behavior instead of rewriting history.
- **zc.zig is a single-editor file.** Every Z step touches it; the gate
  already rejects overlapping ACTIVE claims, but plan Z work strictly
  one-at-a-time (Z1e+Z1f may pair) so claims never trip it.

### The dialect boundary (Z4a, #760 — what the corpus may use)

The corpus contract: every `tests/zc-corpus/*.z` fixture (and the stdz
library modules `user/src/lib/stdz/*.zig` it compiles with) must build
STRICT-valid under host `zig 0.16` AND compile + run in-guest with `zc`
(compile-only for the vl6 GUI fixture — its window surface's run parity
is carried by the snake fixture + `verify-live-snake.sh`, the
window/pixel-observing gate, not a serial log). Strict matters: the Z4a-era
`zig build-obj` check analyzed lazily, so a fixture whose `main` body used
`i += 1` or implicit u64→u8 stores passed; the Z4b host build
(`tools/build-zc-host.sh`) links an entry that calls `main`, forcing full
semantic analysis of every body — it caught exactly that drift class in
z1b/z1d (fixed with the dialect's own `@intCast`, matching the z3b stdz
glue). `tools/verify-zc-corpus.sh` is the mechanical half: one case per
compile unit, per-case pinned exit status, ordered markers, and byte-exact
+ sha256 file pins where the fixture does file IO — and since Z4b, a
DUAL-RUN: each case's host-built ELF gets its own boot asserting the same
pins, so behavior is byte-equivalent across the two compilers. This is the
*shared subset* today, in one place:

**In the subset** (each rung's fixture is the living example):

- Scalar `fn`s with typed params/returns; typed `const`/`var`; `if`/`else`
  with braced bodies; `while`; `for (0..n)` and array iteration; `switch`
  as value/range/multi-prong cond-chains with `else`.
- Strings as `(addr,len)` pairs (string literals and `[]const u8`
  *returns* — e.g. the z1e/z1f name-mapping fns).
- Arrays, structs (including `[*]T` pointer fields), enums with
  `@fromBackingInt`/`@backingInt`, `@intCast` (identity on words — needed so
  dual-dialect sources type-check under host Zig's u8 stores).
- Pointers: `&x`, `x.*`, `[*]u8`/`*T` params, struct-field access through
  pointer params. **Not** slices as *params* (call sites pass one register;
  stdz uses explicit `[*]u8` + `u64` buffer pairs — the z2a/z1d pattern).
- `defer` (scope-exit cleanups: LIFO at block fallthrough, inline on
  `return`; bodies restricted to expression or simple-assignment
  statements), `*const fn(...)` function pointers with `&fn` + `blr`.
- The `zc.*` magic seam (`@import("zc")` — print/write/exit/mmap/file
  ops, the win builtins win_open/fill/present, and the raw
  `zc.svc(<literal>, …)` escape hatch for any ADR 0007 syscall — e.g.
  `zc.svc(21, &buf)` polls the event queue; the host shim's `svc` is
  `anytype`-widened so pointer args type-check under host Zig), multi-file
  flat-namespace compile (Z3a), and the stdz modules (fmt/string
  builder/ring — Z3b) compiled in from source.
- `break`/`continue` in `while` and both `for` forms — the M70c S3 lift
  (2026-09-19, issue #1455). `break` leaves the innermost loop; `continue`
  re-tests a `while`'s condition but runs a `for`'s **step**, because a
  range/array loop's increment sits at the bottom of the body. Both run every
  defer still open inside the body, the same LIFO unwind a fallthrough
  performs. Fixture: `tests/zc-corpus/s3-break.z` (`live-zc` run 02, plus the
  corpus dual-run).

**Non-goals** (host Zig parses them; `zc` does not — compile errors, and
the fixture corpus must not use them): `comptime`, `std`, error sets,
compound assignment (`+=` etc. — write `i = i + 1`),
`%` (emulate as `x - (x / 10) * 10`), `else if` (nest ifs), method-call
syntax, any `@import` other than the magic `"zc"` name (the multi-file
namespace is flat by design). Dialect-internal caps the gate enforces:
every source fits the shared source arena — 32768 B per compile group
(zc's `source_arena_cap`; `run()` drains each source with chunked
`file_read`s until EOF, so the kernel's 2048-B single-read clamp no
longer truncates — a group that overflows the arena fails loudly, never
silently; claim #992), ≤ 6 sources per compile (`MAX_FILES`), ≤ 8 struct
fields, and — surfaced by the snake, claim #988 — a ~512 B stack-frame
budget per function (frame bytes accumulate across the body, so a
`[120]u64` local array refuses to compile; size large locals to the
budget) and braced-only `if` bodies (a single-statement
`if (c) return 1;` without `{ }` is a parse error). When a ladder step wants to lift a non-goal, it ships a
fixture that uses it and this list shrinks — the corpus and this boundary
move together. The corpus gate's first in-guest sweep caught one drift:
`z1b-arrays.z` used `+=` (never in the dialect — its zc.zig unit twin
always used `i = i + 1`), which the Z0.5-era host checks could not see
(host Zig accepts `+=`); fixed to the supported form in Z4a.

**What still blocks full Zig 0.16 (M70c S3's record, 2026-09-19).** The
ladder's own top rung is landed — host `zig 0.16` and in-guest `zc` agree on
the corpus, dual-run (Z4b) — and S3 shrank the boundary by one bound
(`break`/`continue`). The remaining distance is the non-goals above, and it
splits in two. Observed in `user/src/zc.zig`: it contains no comptime
evaluator, no error-set or `try`/`catch` tokens, and no module graph beyond
the magic `"zc"` name, so *dialect parity* is not reachable by writing more
fixtures — those three are a different kind of work and nothing in the fleet
exercises them. The mechanical remainder is unimplemented rather than hard:
`%` is a three-instruction lowering on the `/` path that already emits `udiv`
(`parseMultiplicative` in `zc.zig`), compound assignment and `else if` are
parse-level sugar, and
method-call syntax is a rewrite. One gap is worth naming because it bit this
card's own fixture: Zig's keyword forms `or`/`and` are **not** in the dialect
(`||`/`&&` are) — host Zig accepts both, so only the in-guest leg catches it.
None of these is scheduled: the boundary moves when a fixture needs it, which
is why this lift came from a loop-control bound.

**Sequencing note (historical):** #749 (Z0.5) landed first — the dialect
unlock with the host-shim contract pinned in its body — #708 (VL6) rode
with it, and the snake (claim #988) supplied the missing run consumer.
The Z1a–Z4b ladder then landed its fixtures; the corpus was already
accumulating from
Z0.5 (each step ships its fixture), so it was warm when Z4a/Z4b landed.
Lane 0's
four cards (#773–#776) are independent and claimable in parallel with any
of the above.

## Other open GitHub threads

| Thread | Milestone | Open cards | Notes |
|--------|-----------|-----------|-------|
| Sexiburger god menu | #19 ✅ closed 2026-09-02 | — | #677 umbrella, S1 action registry seam (#701), S2 menu shell (#702), S3 covenant of six (#703), S4 type-to-filter (#704), S5 test app registration & live invocation (#705), S6 tab model (#782), and mascot monitor command `sexiburger`; live gate PASS on VZ (claims 8326/6479) |
| Self-hosting seed | #20 (21 open) | #706 umbrella (0a–0d → #773–#776) · #707 · #708 (VL6, depends #749) + ladder **#749–#761** + **#783** (shell completion) | see above; umbrella #620 closed |
| WASM core interpreter | #22 **proposed** (6 open) | **#778** (W1a contract freeze) · **#762** (W1b interpreter) · **#763–#766** (W2–W5) | one interpreter, the whole ecosystem: host-built wasm apps run in-guest; module = data via the file channel (no ELF contract); `env.*` imports → ADR 0007, no WASI; **Go deferred to post-M35, 2 MiB memory cap, capstone = `wc`** (W1a decisions, #778); tracker `docs/archive/wasm-core-scoping.md` |
| M33 seam B (pixel ownership) | #17 ✅ closed 2026-09-01 | — | SB1–SB6 all landed (claims 7418/8878/3633/2382/7397/6864); SB6's yield-spin scheduler finding filed as #768; M33 weekly lanes #710–#712 closed 2026-09-01 as superseded (tab model → #782, shell completion → #783) |
| Bug cards (unmilestoned) | — | #729–#734 | P1 #729 (desktop launch err=6 ENOENT regression), P2 #730 (WND.BIN abort), P2 #732 (broken win harness), P3 #731/#733/#734 (stale chrome, dhcp fixture, glyph shift) |

## Suggested claim order when M34 finishes

1. **HF5** (user-data migration) — the big one; fold the **mtime + name
   width** wire revision in here (gaps #4/#5) or file them separately.
2. **#749 (Z0.5) → #708 (VL6)** — the compiler thread's open end,
   independent of M34.
3. **HF6** (FAT removal) — after HF5; deletes pain points #2/#6/#7/#9–#12
   at the root.
4. **HF7** (CLONE dedup) — parallel, worktree capstone.
