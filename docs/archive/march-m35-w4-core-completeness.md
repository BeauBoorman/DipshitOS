> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# March: M35 W4 — core completeness (f32/f64, sign-extension proof, bulk-memory gated)

Prompt/plan for issue #765 (Milestone #22, M35 WASM core interpreter W1–W5).
Owner: `buffy2` on `agent/buffy2/m35-w4-core-completeness` (claim 7395).
Tracker: `docs/archive/wasm-core-scoping.md` card table. Baseline: W3 merged
(PR #807); `user/src/wasm.zig` at 3,085 lines, integer subset only.

> **STATUS: ✅ DONE 2026-09-02** — all slices landed and live-gated (see
> `docs/archive/wasm-core-scoping.md` "What W4 landed" and the claim log). The one
> course-correction this plan did not foresee: the 0xA8–0xB1 region — plain
> trapping trunc lives there; 0xAC/0xAD are i64 extends; 0xFC 0–7 are the
> SATURATING forms clang actually emits — corrected in-slice and proven by
> both host tests and the live floatapp gate.

## Goal

Grow the interpreter honestly so floating-point-using programs run in-guest
with pinned output: f32/f64 value types + numeric ops with the W1 trap
discipline, sign-extension *proven* (the ops already exist), and bulk-memory
only as justified by the W5 capstone. Each growth is tied to a named program
(floats → a small C float utility, not `wc` which is integer-only), not
open-ended.

## What is already true of the W3 tree (do not redo)

- **Parse layer is float-ready.** `ValType` accepts 0x7D/0x7C; blocktypes,
  locals, func types, globals all carry float types once validation allows.
- **Sign-extension (0xC0–0xC4) is implemented.** `validateOp` `0xC0...0xC4`
  (~line 961) and execBody handlers (lines 1610–1626) cover
  `i32.extend8_s/16_s`, `i64.extend8/16/32_s` with correct typing. The W4
  sign-ext work is *proof*: exercise them (hand-built fixture + the named
  program where they naturally appear). Check the ops against spec semantics
  while you are there (current impl truncates to i8/i16/i32 then widens —
  correct).
- **Traps, memory ops, tests all exist** and stay green (`TrapKind`,
  `loadMem`/`storeMem`, in-file host tests + `@embedFile` corpus fixtures,
  `zig test user/src/wasm.zig`).

## Delta 1 — lift the float subset (all in `user/src/wasm.zig`)

1. **`Value` union (~line 62):** add `f32: f32, f64: f64` lanes (extern
   union stays 8 bytes — no BSS change).
2. **`ValidationError.FloatOutOfSubset`** (line 249): delete once no longer
   raised. Remove the type-section/global rejections in `validate()`
   (~lines 746–755).
3. **`validateOp` stack rules** for the float opcode ranges (replacing the
   `FloatOutOfSubset` reject arms):
   - `f32.const` 0x43 / `f64.const` 0x44: consume the 4/8-byte LE immediate,
     push `.f32`/`.f64`.
   - f32: `eqz` 0x5B `[f32]->[i32]`; cmp 0x5C–0x61 `[f32 f32]->[i32]`;
     unary abs/neg/ceil/floor/trunc 0x62–0x66 + nearest/sqrt and arith
     add/sub/mul/div/min/max/copysign per the spec table `[f32*]->[f32]`.
   - f64: mirror at 0x8B+ (eqz 0x8B, cmp 0x8C–0x91, abs…copysign 0x92–0x9F).
   - conversions/reinterpret 0xA0–0xBF: stack rules per spec (trunc →
     `[f32/f64]->[i32/i64]`, convert `[i32/i64]->[f32/f64]`,
     demote/promote `[f64/f32]->[f32/f64]`, reinterpret keeps lane width,
     `i32.reinterpret_f32` 0xBC etc.).
   - **Verify every opcode against the official spec table + a local
     `zig cc` probe before coding** (decode a compiled float module's code
     section) — do not trust memory for the assignment map; clang emits the
     real thing and the fixtures will catch drift.
4. **Memory:** `f32.load` 0x2A / `f64.load` 0x2B / `f32.store` 0x38 /
   `f64.store` 0x39 join the loads/stores ranges (natAlign 2/3/2/3;
   `loadType`/`storeType`; `loadMem`/`storeMem` read/write 4/8 LE bytes via
   `readInt`/`writeInt` on u32/u64 then bitcast).
5. **`skipInstr`:** 0x43/0x44 must skip 4/8 immediate bytes (currently
   `else => pc + 1` — latent desync once floats are legal; `findBlockEnd`
   runs only on validated bodies but that guarantee is now weaker).
6. **Const exprs:** `parseConstExpr` (globals/data offsets) stays
   i32/i64-only per spec subset — code-section `f32.const`/`f64.const` live
   in execBody, not const-expr. Float *global* init exprs only if a named
   program needs them (validate then allows float globals; `parseGlobal` +
   `parseConstExpr` need f32/f64.const forms).

## Delta 2 — exec semantics (the byte-exact surface)

- New `execF32`/`execF64` mirrors of `execI32`/`execI64` plus conversion
  helpers; result pushed as the right `Value` lane.
- **Trap discipline:** wasm float div-by-zero → ±inf, NOT a trap. The only
  new trap source is the plain (non-`_sat`) trunc family (0xA0–0xA7 region:
  `i32/i64.trunc_f32/f64_s/u`): NaN or out-of-range → trap named
  module+offset (a new `TrapKind`, e.g. `invalid_conv`, printed in the
  existing trap-naming style). The `_sat` variants (0xFC 0–7) never trap —
  defer with bulk-memory unless a named program needs them now.
- **IEEE semantics to implement exactly:** round-to-nearest-even everywhere
  (hardware default — fine); `min`/`max` = IEEE-754 minNum/maxNum
  (NaN → numeric operand; ±0 sign rules); `nearest` = round-half-even
  (NOT `@round`); `copysign`; `ceil`/`floor`/`trunc`; `sqrt`; NaN
  propagation shape for fixtures. Zig: `std.math` for trig is NOT needed
  (float utility is +-*/ and formatting); use `@abs`, `@ceil`, `@floor`,
  `@trunc`, `@sqrt`, `@copysign`, `@rem`-free ops; verify `nearest` and
  `min/max` against the spec — do not assume Zig builtins match wasm.
- **Conversions:** trunc (trap on NaN/overflow), `_sat` (clamp),
  convert_i32/i64_s/u (`@floatFromInt`), demote `@floatCast`,
  promote, reinterpret `@bitCast` at equal width.
- **Integer display vs float ops:** the guest printing of float results is
  the named program's job (it converts to ints/strings with the imports) —
  the interpreter itself needs no float formatting.

## Delta 3 — sign-extension proof

Hand-built fixture (byte-literal test like `exec: loop + br_if…`) running
all five ops with pinned results; note where the float utility naturally
emits sign-ext and pin it too.

## Delta 4 — bulk-memory, ONLY if justified (probe first)

1. **Probe:** compile the planned wc-style C (file reads + counting) with
   `zig cc -target wasm32-freestanding -nostdlib -fno-sanitize=undefined -g0`
   and dump its code section. If clang emits `memory.copy` (0xFC 10) /
   `memory.fill` (0xFC 11) / `memory.init` (0xFC 8) / `data.drop` (0xFC 9)
   (it does when `memcpy`/`memset` lower to them, e.g. under `-mbulk-memory`),
   the card is justified. If wc avoids them, note it in the claim and stop —
   do not build bulk-memory speculatively.
2. **Parser:** DataCount section id 12 (record count; enforce ordering after
   code); passive data segments (flag 0x01: no offset expr, bytes only) —
   currently rejected. `memory.init` needs per-instruction dataidx + segment
   bytes (already slice-stored in `m.datas`), bounds + active-drop semantics.
3. **Exec:** 0xFC sub-opcodes with uleb immediates; `memory.copy` = memmove
   semantics (overlap-safe), `memory.fill` = memset, `memory.init` =
   memcpy from segment with bounds trap, `data.drop` = mark segment dropped
   (per spec, subsequent `memory.init` of a dropped segment traps).
   `skipInstr` must learn the 0xFC forms (2 reserved memidx bytes for
   copy/fill, dataidx+memidx for init, dataidx for drop).

## Delta 5 — named program, fixtures, gate, docs

- **Float utility:** a small C program (unit converter shape) under
  `tests/` — fixed-point input via `env.write` args or a data section,
  two-decimal output via integer arithmetic around f32/f64 (per the issue:
  "fixed-point-in, two-decimal-out"), compiled with the W3 determinism
  recipe (`zig cc … -g0`, fixed basename), pinned sha256, committed to
  `user/src/wasm-corpus/`.
- **Fixtures/tests:** flip `test "validate: rejects f64 type (W4 float out
  of subset)"` (line 2634) into an f64 parse+validate+exec acceptance test;
  add float arithmetic/conversion/trap unit tests as byte-literal modules;
  extend the corpus list in the final W3-style test if one exists.
- **Gate:** `tools/verify-live-wasm.sh` gains the W4 phase — boot runs
  `exec WASM.BIN <FLOATUTIL.WASM>`, output pinned byte-exact; script1/script2
  runner pattern per the existing phases.
- **Docs:** `wasm.zig` header comment (floats OUT → in), scoping doc card
  row, contract §6 float line ("W4 adds them"), this plan's status, and
  `docs/status.md` on completion.
- **BSS budget:** record before/after (`tools/verify-bss-budget.sh` + the
  gate's size lines) in the claim.

## Acceptance (issue #765)

- The named float utility (built with `zig cc`) produces pinned byte-exact
  output in the live gate.
- Sign-extension exercised by the same program where it naturally appears
  (+ the hand-built fixture).
- Determinism fixtures green; W1b–W3 tests stay green; `zig test
  user/src/wasm.zig` all pass.
- Interpreter BSS budget green (before/after in the claim).
- Out: threads/atomics/SIMD/shared memory, the AOT/JIT off-ramp, WASI.
