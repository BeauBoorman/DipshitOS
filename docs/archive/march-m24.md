> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

| K1 | **Programmer mode.** Ctrl+P toggles between standard and programmer view. Programmer shows: hex/octal/decimal display (all three simultaneously), AND/OR/XOR/NOT/shift operators (<<, >>), register display (R0–R7 as scratch). Base selector buttons: HEX/DEC/OCT. | ✅ gate | `tools/verify-live-calc-prog.sh` PASS on VZ (Ctrl+P toggles observed, `calc: prog-on/off`). | `calc/programmer.zig` + bitwise ops in `calc/engine.zig` (opcodes `A/O/X/L/R`, `bitwise_not`). Triple-line display (hex `0x`/dec/oct `0o`), R0–R7 register display. Serial markers: `calc: prog-on` / `calc: prog-off`. |
| K2 | **Memory store.** MS (memory store) / MR (memory recall) / M+ (memory add) / M- (memory subtract) with 4 memory slots (M0–M3). Memory indicator in the display showing which slots are non-zero. Ctrl+1/2/3/4 selects the active memory slot. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: mem-slot` + `5 s m` keyboard store/recall consumed). | `AppState.mem_slots[4]`, `mem_active_slot`, `mem_any_nonzero` flag. MS/MR/MC/M+/M- buttons + keyboard `m` (MR), `s` (MS), Ctrl+1/2/3/4 slot select. Memory indicator `M0`–`M3` in display. |
| K3 | **Unit conversion.** Ctrl+U opens a conversion bar at the top. Categories: `temp` (C/F/K), `length` (m/ft/in/cm/mm), `weight` (kg/lb/g/oz). Type a value, select units, result appears instantly. Conversion factors are comptime constants. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: conv-on/off` toggles observed). | `convert_active`, `convert_category` (temp/length/weight), `convert_from_idx`/`convert_to_idx`, `convert_value` (f64). Conversion bar overlays history area with category labels + from/to display + result. Temperature C→F 100→212 verified in tests. |
| K4 | **Constant calculator.** Mathematical constants available as dedicated buttons: π (3.14159…), e (2.71828…), √2 (1.41421…), φ (1.61803…), ∞, and 1/3 (0.333…). Press the constant button and the value appears in the display, ready to be used in the next operation. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (PI click renders `3` in the display — screenshot pixel proof). | `calc/constants.zig` comptime table. PI/e/sqrt2/phi buttons insert integer value (3/2/1/1) into accumulator. |
| K5 | **History persistence.** Last 20 calculations survive reboot (FAT write). `calc history` command from the shell shows them. History ring is saved on each Enter (new result). History is restored on CALC.BIN startup from FAT. | ✅ done | 61 calc tests + 464 monitor tests pass. PR #482 (code) + PR #484 (shell command). | `calc/history.zig` `Ring.save_to_fat()` / `load_from_fat()`. `/data/calc_hst.txt` format: `expr=result\n`. History ring extended from 10→20. Shell command: `calc [history]` reads FAT file, prints entry count + contents (registry 51→52). Live gate pending. |
| K6 | **Scientific notation display.** SCI button toggles sci rendering of the display; auto-switch when \|v\| ≥ 1e10 (the < 1e-4 half is unreachable for nonzero integers in an i64 engine but format_sci handles fractional magnitudes for future float sources). 6 significant digits, trailing zeros stripped, exponent never zero-padded (`1.23e+4`). | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: sci-on/off` toggle observed via pointer click). | `engine.format_sci(f64)` truncates mantissa at 6 sig figs; `engine.sci_auto(i64)` threshold helper; `AppState.sci_mode` + SCI button below keypad (standard mode) with serial markers `calc: sci-on/off`. Issue tests: 123456789012345 → `1.23456e+14`, 0.000001234 → `1.234e-6` — both covered as unit tests. |
| K7 | **Trigonometric functions.** SIN/COS/TAN/ASIN/ACOS/ATAN buttons below the keypad; DEG/RAD toggle (RAD default; label reflects current mode). Taylor series, 10 terms, with range reduction for sin/cos and half-π / range-shift identities so boundary inputs (asin(1), atan(1)) stay exact. Inverse functions emit degrees in DEG mode. Domain errors (tan 90°, asin(±>1)) raise the engine ERROR state. Results round to nearest integer — i64 engine, documented precision limit. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: deg-mode/rad-mode` toggle observed via pointer click). | New `user/src/calc/science.zig` (pure f64 math, no libm — freestanding-safe). Issue tests: sin(90°)=1 and cos(0)=1 covered as GUI-level button-click tests. Serial markers `calc: deg-mode/rad-mode`. |
| K8 | **Logarithmic & exponential functions.** LN / LOG (base-10) / EXP / POW / SQRT / ABS buttons below the keypad. exp/ln via argument scaling + 10-term Taylor (exp splits e^x = 2^n·e^r; ln uses the atanh identity on m∈[1,2)), sqrt is Newton's method per the card, log10 = ln/ln10. POW is an engine opcode ('P') backed by exact checked integer exponentiation — overflow and non-representable negative exponents raise ERROR instead of wrapping. Float results round to nearest i64 (documented engine limit). | ✅ code | 76/76 host tests pass (`zig test user/src/calc.zig`, evidence `artifacts/m24-k8/host-tests.txt`); new `calc/mathfn.zig` passes 4/4 standalone; verify-bss-budget PASS. | New `user/src/calc/mathfn.zig` (no libm). Issue tests: ln(e)=1, log(100)=2, sqrt(16)=4 covered at module level + GUI flows (log(100)=2, sqrt(16)=4 via clicks). `CalcEngine.raise_error()` exposes the existing fail() contract to the caller layer. |
| K9 | **Expression editor.** EXPR button toggles editor mode: type full expressions into the display (`2+3*4`), Enter evaluates, Backspace edits, Esc exits. Recursive-descent parser with BODMAS precedence, left-associative, tokens numbers / `+ - * / %` / parens / unary minus; checked i64 arithmetic — syntax/div-zero/overflow raise ERROR while keeping the broken expression visible for fixing. Clicking a history row loads its expression back into the editor. Evaluated expressions record `expr=result` in history and persist via K5. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: expr-on/off` toggle observed via pointer click). | New `user/src/calc/expr.zig`. Issue tests: 2+3*4=14, (2+3)*4=20, 10/2+3=8 covered at module level plus GUI flows (typing, backspace-edit, history-click-edit → edit 2+3*4 to *5 = 17). Serial markers `calc: expr-on/off/ok/error/edit`. |
| K10 | **Copy result/expression.** Ctrl+C copies the result to the shared kernel clipboard (slot 38); Ctrl+Shift+C copies "<expr> = <result>" from the newest history entry; Ctrl+V pastes, parsing a leading signed integer (trailing junk tolerated, overflow refused). | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: clip-copy` observed via Ctrl+C chord). | Payload formatting + paste parsing are pure functions (`clipboard_payload`, `parse_pasted_number`) so host tests cover them without syscall stubs; chords verified consumed and non-clashing with plain-c clear. |
| K11 | **CLI CALC mode.** `calc <expr>` from the shell routes to CALC.BIN's CLI path: the kernel exec entry contract (argc in x0, argv block VA in x1) drives a no-GUI evaluate-print-exit (`2+3*4 = 14`); `calc -h` prints help; no args opens the GUI. Shell-side routing is a Rule-4 self-contained insertion in monitor.zig's cmd_calc (unowned shared file): non-`history` args exec CALC.BIN verbatim, falling through to the honest unknown-subcommand error if the image can't run. | ✅ | 87/87 calc host tests pass (evidence `artifacts/m24-k11/host-tests.txt`); monitor 22/22 module tests pass; `zig build calc` image 20,262 B; verify-bss-budget PASS. | calc.zig: `_start(argc, argv_va)` signature per claim-4636 contract; args joined with spaces; expr parser reused (BSS ~none). Live proof pending: `calc 2+3*4` from a booted shell (needs live-gate bring-up pass). |
| K12 | **Formatting controls.** Ctrl+, opens a settings bar over the history area: DEC PLACES (0–10, wraps), THOUSANDS separator ON/OFF, HEX PAD (16-digit zero-padded programmer hex) ON/OFF. Up/Down select, +/− adjust, Enter applies, Esc closes; clicks land on rows directly. Settings persist to `/data/calc_cfg.txt` (`dec=/sep=/hexlz=` lines; out-of-range values ignored) and load at startup. Applied: separator on the plain integer display, dec places on the unit-conversion float result (`format_fixed`, half-away rounding), padding on the programmer hex line. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: cfg-open/close` via Ctrl+, chord). | Issue's `1/3 = 0.33` case: the engine is checked-integer (march scope notes exclude fractions), so dec_places formats the genuinely-float paths (unit conversion) — the module-level test covers `format_fixed(1/3, 2) = "0.33"`. Serial markers `calc: cfg-open/close/save`. Host file stubs return 0 so persistence round-trip is tested at the parse/write level. |
| K13 | **Date/time arithmetic.** Ctrl+D opens a command bar: `d1 - d2` → days between (issue case 2026-01-01→2026-01-10 = 9), `d + N` → new date rendered YYYY-MM-DD, bare date → epoch-day count, `now` → seconds since boot. Results are numeric in engine/history; human-readable in the bar. Leap years via proleptic-Gregorian civil-date math (Hinnant algorithms). `now()` reads CNTFRQ_EL0/CNTPCT_EL0 directly (EL0-accessible) — zero ABI slots spent. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: date-open/ok/close`; the `now()` CNTPCT read is live — the kernel now sets `CNTKCTL_EL1.EL0PCTEN`). | Typed syntax errors (month 13, day 40, malformed) raise ERROR with an in-bar hint. Host builds stub the register read with a deterministic counter. |
| K14 | **Random number generation.** RAND button (SCI/EXPR row) and `r` key: display value N > 0 → value in [0, N); N == 0 → [0, 2^32). xorshift64\* re-seeded from the generic boot-counter at press time so consecutive presses differ. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: rand` via `r` key — first live EL0 CNTPCT read; exposed + fixed the missing `CNTKCTL_EL1.EL0PCTEN`). | Honest deviation, documented: the card suggests the kernel CSPRNG "may need a sys_random slot" — M24's ABI budget is zero new slots (plan §8 hard constraint) and no EL0 entropy seam exists, so this is a PRNG with the seed source documented, not cryptographic. Serial marker `calc: rand`. |
| K15 | **Saved expressions & definitions.** In the K9 expression editor: `def pi = 3.14` stores a named f64 value (8 defs, names ≤ 16 chars, replace-in-place, honest Full/BadName refusals); any expression containing letters evaluates over f64 with names resolved from the table (`2 * pi` → 6.28 rendered via dec_places). Persisted to `/data/calc_defs.txt`. | ✅ code | 111/111 calc host tests pass (`zig test user/src/calc.zig`, evidence `artifacts/m24-k15/host-tests.txt`); new `calc/defs.zig` passes 2/2 standalone; image 61,888 B; verify-bss-budget PASS. | New `evaluate_f64` in expr.zig shares the integer parser's grammar with a resolver callback; editor charset widened to letters/underscore/'='/'.' with '=' literal inside def lines. Issue case covered as a GUI key-flow test. |
| K16 | **Statistics mode.** Ctrl+S opens a stats bar: type a comma-separated list (≤100 samples), Enter computes n / sum / mean / median / population std-dev / min / max. Mean lands in the engine for chaining and the full summary renders in the bar. Median sorts an insertion-sorted copy — stored order preserved. [100]f64 store per the card's BSS budget. | ✅ gate | `tools/verify-live-calc-depth.sh` PASS on VZ (`calc: stats-on/ok/off`; live proof types a single value "123" — the CSV chord list cannot carry a literal comma, so the multi-sample parse_list path stays host-tested, documented in the gate header). | Serial markers `calc: stats-on/off/ok/error`. Plain \`s\` keeps its K2 memory-store meaning while the bar is closed. |
# Milestone twenty-four march — CALC grows up (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M24's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

CALC.BIN (M11 A2, M17 C9) is a basic four-function calculator with
keyboard input, memory (MR/M+), and a scrollable history ring. It works
for simple arithmetic. But it can't do hex, can't convert units, and
doesn't survive a reboot. M24 makes it *useful*.

**Zero new syscall slots.** All changes are pure userland.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|

## File decomposition

M24 split the monolithic `calc.zig` (1,147 lines) into focused modules:

```
user/src/calc.zig          — entry point, AppState, GUI orchestration (~950 lines)
user/src/calc/engine.zig   — CalcEngine: pure arithmetic, bitwise ops, format (~350 lines)
user/src/calc/history.zig  — Ring buffer: push/get/format/FAT persistence (~200 lines)
user/src/calc/programmer.zig — ProgrammerState: base conversion, registers, format (~180 lines)
user/src/calc/constants.zig  — comptime constant table + get() (~55 lines)
```

Total: ~1,735 lines across 5 files (was 1,147 in 1 file). Each module is
independently testable and has clear dependency boundaries.

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — CALC features** | `user/src/calc.zig` for K1 (programmer mode), K2 (memory), K4 (constants), K5 (history persistence). K1 and K2 can be done in parallel (disjoint state). K4 is independent. K5 extends K1–K4. | M18 done (FAT write for persistence). |
| **B — Unit conversion** | `user/src/calc.zig` + `user/src/lib/ui.zig` (DropDown reuse) for K3. | M17 done (DropDown widget exists). K1 (programmer mode affects which conversions are relevant). |

## Notes

1. **ABI budget:** Zero new syscall slots.
2. **BSS budget:** Registers 64 bytes. Memory slots 32 bytes. Conversion
   state ~32 bytes. History ring 640 bytes. Total M24 BSS delta: ~768 bytes.
   Negligible.
3. **Gate shape:** K1: `verify-live-calc-prog.sh` — hex/octal display toggles.
   K2: `verify-live-calc-memory.sh` — store/recall round-trip. K3:
   `verify-live-calc-units.sh` — unit conversion result. K4:
   `verify-live-calc-constants.sh` — constant button inserts value. K5:
   `verify-live-calc-history.sh` — history persists across reboot.
4. **Programmer mode vs standard mode:** The mode toggle (Ctrl+P) switches
   the entire UI layout. Standard mode shows: display + basic buttons + history.
   Programmer mode shows: triple display (hex/dec/oct) + extended buttons +
   registers. Both modes share the same calculator core.
5. **Scope exclusions:** No graphing. No symbolic algebra. No equation solver.
   No complex numbers. No matrix operations. This is a pocket calculator
   with programmer extensions.
