# Claim: milestone eight, card U3 — error/usage contract

- **Owner:** zcode (`agent/zcode/m8-u3-errors`)
- **Prompt / plan:** user request 2026-08-14 — "lets do card u3". Normative
  contract: ADR 0008 D3
  ([`docs/decisions/0008-human-interface-guidelines.md`](../decisions/0008-human-interface-guidelines.md)).
- **Scope:** the mechanical enforcement of D3 — shared error/usage
  formatting helpers in `kernel/src/monitor.zig` and the migration of every
  handler's failure/misuse reporting onto them; the unknown-verb and
  no-command shapes in `exec`/`handle_line`; the tokenizer's line-level
  notices harmonized; the shell transcript regenerated (the U1 precedent)
  with a misuse section asserting each shape byte-exact; a deterministic
  host fuzz of the tokenizer + every handler (no panic on any bad input);
  the class-A gates registered. Branched from `agent/zcode/m8-u2-lineedit`
  (U2, unmerged upstream at claim time — the cards are serialized per the
  march-m8 agent split: U3 claims after U1's help metadata).
- **Depends on:** U0 (ADR 0008 ✅), U1 (usage strings + categories ✅),
  U2 (the editing surface the shell now carries, ✅ locally).
- **Status:** ✅ done (2026-08-14)

## Notes

ADR 0008 D3 fixes exactly three output shapes, deterministic, and no
handler may panic on bad input: misuse → `usage: <cmd> <args>` plus a
one-line hint; failure → `error: <actionable message>`; unknown verb →
`unknown command '<x>' — try 'help'`. Commands are case-sensitive; a
command that cannot do what was asked reports WHY in the `error:` shape,
never a bare negative number. The enforcement is mechanical: the misuse
transcript asserts each shape byte-exactly, and the fuzz drives garbage at
every handler.

Today's surface is ad hoc per handler ("cat: <f> not found (…)",
"hex: invalid number: …", "unknown command: x" + a second hint line,
"no command given; …", "too many arguments; …") — this card replaces the
shapes wholesale via helpers, migrates the 40 handlers, updates every
affected host test, and regenerates the canonical transcript (U1's
precedent for sanctioned transcript change). Shape decisions for the
line-level cases: an empty verb takes the unknown-verb shape with the
empty quotes; the tokenizer's too-many/unbalanced-quote notices become
`error:` lines (they are line-level failures with no verb to usage).

## Verified

- ✅ class A: `zig fmt --check` pass; `bash tools/verify-unit-tests.sh` —
  all modules pass (monitor 363 incl. the handler fuzz + garbage-verb
  fuzz; tokenizer 371 incl. the 512-case garbage fuzz; shell 399);
  `zig build test-console` — **transcript byte-identical** (regenerated
  with the D3 misuse section: unknown verb, arity usage+hint, handler
  refusal, too-many line — each asserted byte-exactly);
  `zig build`/`image`/`inspect`/`context` + `swift build` pass.
- ✅ the fuzz caught and fixed one real fourth shape during development
  (`beans`'s range message — now `error:`-prefixed).
- ✅ live-gate re-derivation: `tools/verify-live-lineedit.sh` assertions
  moved to the D3 unknown-verb shape (re-run green on VZ);
  `tools/verify-live-net-tcp.sh`'s refusal assertion prefixed; all other
  live gates assert unchanged success/status strings (swept).
- ✅ `bash tools/verify-coordination.sh`
