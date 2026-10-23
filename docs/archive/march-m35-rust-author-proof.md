> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# M35 post-card — cross-language author proof: virelai.zig + a rustc app

**Prompt:** Prove the contract's cross-language claim: write the
`virelai.zig` shim author recipe and a fresh Rust `wasm32-unknown-unknown`
app from `docs/wasm-import-contract.md` alone, gated in the live boot.

**Why now:** Milestone #22 is 6/6 (PR #813 pending). The contract doc —
frozen at W1a and amended through W5 — already *promises* two authoring
surfaces that do not exist yet:

- §1 "Host shims": "`virelai.h` (C) **and `virelai.zig` (Zig)** emit
  `__attribute__((import_module("env"), import_name("<name>")))` /
  `extern "env"` declarations matching the WAT signatures in §5".
- §7 "Verification & author recipe": "Compile C: `zig cc … app.c
  virelai.c -o app.wasm` (or Rust `rustc --target wasm32-unknown-unknown`
  with the `virelai.zig` shim)".

W5's provenance proof was C-only (one language, `virelai.h`). This card
proves the *contract* is the ABI — any language that can emit a wasm
module with `env.*` imports from §5 can author against it: Zig through the
new `virelai.zig` shim, Rust through `#[link(wasm_import_module =
"env")]` externs written straight from the §5 tables.

**Deliverables**

1. `tests/virelai.zig` — Zig sibling of `tests/virelai.h`: `extern "env"`
   declarations (write/exit + the full §5 frozen surface), the MODE_*/PROT_*/
   MAP_* constants, and `DirEntry`/`AudioInfo` extern structs (40/16 bytes).
   Proven by compiling a scratch Zig module (`zig build-exe -target
   wasm32-freestanding -fno-entry`) whose import table is exactly the
   frozen `env.*` set — class-A, no live boot needed. The Zig author
   recipe (compile line + `export fn _start`) lands in contract §7.
2. `tests/nl.rs` — a fresh **Rust** no_std `wasm32-unknown-unknown` app,
   written from the contract doc alone (no interpreter source read during
   authoring; the only out-of-band fact is the fixture path convention
   `/host/WC.TXT` used by every app since W3). Tool = `nl`, a numbered-
   lines reader: reads `/host/WC.TXT` in 64-byte `env.file_read` chunks,
   splits on `\n`, tolerates CRLF (a trailing `\r` before the newline is
   line-terminator, not content — keeps the console stream clean), prints
   each line `%6d  <content>` byte-exact, exits with the total output byte
   count (fileapp's length proof). Distinct needles over the SAME
   deterministic WC.TXT fixture — no new fixture file.
3. `user/src/wasm-corpus/nl.wasm` — the pinned binary (rustc + wasm-ld,
   rebuild-verified byte-identical, sha pinned).
4. Host test in `user/src/wasm.zig` — "rustc-built app fixture executes
   byte-exact": embed + parse + validate + instantiate + exec against the
   `file_data` capture seam, byte-exact output + exit status (mirror the
   w5 test).
5. `tools/verify-live-wasm.sh` — cross-language phase: `NL.WASM` from the
   corpus into the share (sha-pinned), `exec WASM.BIN NL.WASM` in script1
   after wc (it reads WC.TXT — order-independent, but grouped with the
   short compute apps so the winapp's overlap set stays ≤1), assert
   distinctive numbered-line needles + exit status + `rx-rust-nl` echo.
6. Docs: contract §7 recipes made true (virelai.zig + rustc lines +
   corrected C line — `virelai.c` does not exist; the fixtures compile
   `app.c` alone against the header); scoping doc + status.md post-M35
   notes; claim 9746 + branch log.

**Expected output math (host test + gate needles, computed from
`tests/wc-fixture.txt`):** the 8 numbered lines `     1  w5 wc capstone
fixture` … `     8  last line ends with a word`; exit = 8·(6+2) + Σ line
lengths + 8·1 = exact byte count (python-precomputed, asserted in the
host test).

**Determinism:** rustc's crate name (not the output basename) feeds the
name section — rebuild twice in separate dirs from the same source, `cmp`
must be byte-identical before pinning (mirror the W3 fixture-recipe
discipline).

**Honest scope:** the Zig app recipe is *documented + compile-proven*
(import table exactly the frozen surface); the live-gated cross-language
proof app is the Rust `nl` (per the prompt). A live-gated Zig-authored app
would be a follow-up, not this card.
