---
name: virelai-gate-authoring
description: Author or extend VirelaiOS declarative class-B regression gates. Use when adding a tools/gate/specs/*.spec leg, choosing guest evidence, or diagnosing exec-order and false-PASS failures. Not a substitute for portable unit tests or human acceptance.
---

# VirelaiOS gate authoring

Turn a specific guest behavior into a reproducible, fail-closed VZ gate.
Follow `AGENTS.md`; keep the spec language and evidence policy in their
canonical files rather than inventing another harness.

## 1. Establish the contract and find existing coverage

- Read `docs/status.md` for scope, `docs/testing.md` for evidence policy,
  and `docs/gate-inventory.md` for the A/B/C/D verification classes.
- Read `tools/gate/SPEC.md` before editing a spec. It defines the allowed
  declarations, assertion operands, execution ordering, and warm-boot rules.
- State the behavior, its observable output, and one defect that must make
  the gate fail. A build, a command echo, or a guest's own PASS line alone
  does not prove that behavior.
- List the fleet with `just gate-list`, then search
  `tools/gate/specs/` for the guest command, binary, or assertion already
  covering the affected path. Extend that spec when it owns the contract.
  Add a new spec only for genuinely separate coverage.
- Inspect the selected spec's guest fixture and build/staging prerequisites.
  `tools/gate/specs/go-selftest.spec` is a concrete example of host-seeded
  inputs, guest read-back receipts, and independent host comparisons.

## 2. Declare the smallest real experiment

- Use an isolated agent worktree and respect existing claims as required
  by `AGENTS.md`. Keep all runtime data in disposable fixture shares,
  never owner documents or an existing session share.
- Run `source tools/env-check.sh` in the shell that will run the checks.
  Resolve reported drift before trusting checks that use that toolchain.
  Go-overlay drift blocks guest Go builds, not shell-only checks; report
  it without modifying another worktree's shared fork. Do not silently
  replace a pinned toolchain.
- Extend or create `tools/gate/specs/<id>.spec` using only the `vgate_*`
  surface. Keep a new spec's header to WHAT and WHY in at most 15 lines.
  Do not add a `tools/verify-*.sh` script or extend the legacy fleet list.
- Declare literal fixture files with `vgate_file`; generate inputs through
  `vgate_setup_python` when needed. Use an armed `vgate_share` for
  `share-*` assertions. A path under `$RUN_DIR` is not a guest share path.
- Preserve boot defaults unless changing them is the explicit task.
  Carry device flags, fixture staging, and runner build flags from the
  relevant existing gate, not from an unrelated successful boot.
- Prefer a cold leg unless checkpoint semantics are understood. Before
  adding `--from-checkpoint`, read the device eligibility and semantic
  exclusions in `tools/gate/SPEC.md`; restore is not evidence of cold boot.

## 3. Make false passes impossible

- Guest `exec` returns before the program finishes. End the run on a marker
  the program produces, and anchor later script/input stages on guest
  output with `--script-after`, `--script2-after`, or the corresponding
  documented flag. Never treat the script's own echo as completion.
- Do not put a file operation immediately after an asynchronous `exec`
  and assume ordering. Split independent invocations into separate boots,
  or use the documented guest `fg N` self-sequencing pattern.
- If the ordering guard cannot prove a valid shape, use only a documented
  `# exec-order:` class and explain the actual ordering argument. A comment
  is not a reason to suppress a real race.
- Assert the result independently: compare bytes the guest read back with
  host-seeded expectations, check externally visible state, or pin actual
  framebuffer output. Use `share-equals`/`share-contains` for armed-share
  receipts so the harness also preserves the compared files as evidence.
- `share-equals` treats an existing `$RUN_DIR` fixture as a file, otherwise
  its operand is literal text. Check fixture spelling and include the
  expected trailing newline; do not mistake a missing fixture for a file
  comparison.
- Add a named refusal or negative case for the relevant boundary. Ask:
  would this still pass if the program never ran, returned constant bytes,
  or failed to write its output? If yes, strengthen the assertion.
- Keep the default runner exit-code check. Use `vgate_allow_rc` only when
  the contract deliberately expects that exit, with assertions proving why.
  Do not increase retries/timeouts or weaken assertions to hide a failure.

## 4. Validate in layers

Run from the worktree root, in a shell prepared by `tools/env-check.sh`:

```bash
# Class A: spec ordering/discovery checks and hermetic harness regressions.
bash tools/inventory-gates.sh --check
bash tools/gate/test-gate-run.sh
just verify-coordination
```

Run the affected guest/host unit tests as appropriate to any code change.
Then, on Apple silicon running macOS 27+ with Virtualization.framework,
set `GATE_ID` to the exact selected spec basename (without `.spec`) and run:

```bash
just gate "$GATE_ID"
```

Use a normal build-enabled run for acceptance. `VGATE_NO_BUILD=1` is only
for iteration with a known matching runner variant, not proof of fresh
sources. A class-A pass does not prove class B; a class-B pass does not
replace class-C human acceptance. If VZ or a prerequisite is unavailable,
finish portable checks and name the exact blocked hardware step.

## 5. Report evidence, not a new narrative document

- Report the exact commands, revision, observed pass/fail counts, and
  relevant `artifacts/<gate>-report.txt`, serial, run, and receipt paths.
  Honor `VIRELAI_GATE_SUFFIX` when set. Do not commit generated logs.
- Explain which assertion catches the targeted defect, and distinguish a
  negative case actually exercised from one justified only by reasoning.
- Adding a spec registers it through `tools/gate/fleet.sh`; do not edit
  curated lists or commit a regenerated `docs/gate-fleet-inventory.md`.
  Change `docs/status.md` only when the work actually changes its state.
- Keep the PR focused. After opening it, return the evidence and link;
  do not poll CI or describe CI as proof of the class-B run.
