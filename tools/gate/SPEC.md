# vgate spec format (FROZEN at M40 GF2 close)

A spec **declares**; `tools/gate/vgate.sh` **executes**. A spec is bash that
may use *only* the `vgate_*` commands below (anything else fails the run).
History, claim numbers, and mechanism prose live in git/issues — a spec
header is WHAT + WHY in ≤15 lines.

```
vgate_name NAME [DESCRIPTION]      # required; evidence files are NAME-*
vgate_share none|arm|seed          # custom-virtio share (default none)
                                   #   arm-virtiofs|seed-virtiofs for standard VZ VirtioFS
vgate_fmt PATH...                  # default: boot/src/*.zig kernel/src/*.zig
                                   #   user/src/*.zig build.zig
vgate_runner_flags FLAGS...        # extra swift build flags (e.g. -Xswiftc -DSPIKE)
vgate_repeat N [ENV]               # run every vgate_run N times (default 1);
                                   # with ENV, use $ENV when set (e.g. BOOTS)
vgate_note TEXT                    # report line (repeatable)
vgate_file NAME <<'EOF'            # write NAME into $RUN_DIR (repeatable,
...                                #   in order; contents are literal)
EOF
vgate_setup_python <<'PY'          # python3 hook, $RUN_DIR env (repeatable,
...                                #   in order; nonzero exit fails the gate)
PY
vgate_run TAG -- FLAGS...          # one boot; FLAGS pass through verbatim
                                   # to VMRunner after the harness-owned
                                   # --serial/--overlay-base/--vars and the
                                   #   selected share device/host directory
vgate_run TAG --from-checkpoint CKPT [--warm-strict] [--warm-corrupt KIND] -- FLAGS...
                                   # (ADR 0059, M131b #2639) a warm leg:
                                   # restores checkpoint CKPT in a fresh
                                   # VMRunner process. FLAGS may carry ONLY
                                   # --script* and --timeout — an allow-list;
                                   # the device/attachment shape is inherited
                                   # from CKPT. --warm-strict pins
                                   #   warm=restored (a refusal FAILs the leg);
                                   # --warm-corrupt truncate-state halves the
                                   #   leg's state.vzsave clone before restore.
vgate_checkpoint TAG [--settle-after MARKER] -- FLAGS...
                                   # (ADR 0059 D4) a dedicated base boot:
                                   # cold boot with the group's device flags,
                                   # settles on MARKER (default
                                   #   'tasks user-el0 reaped') then a fresh
                                   #   'virelai> ' prompt, then pause → save →
                                   #   stop into $RUN_DIR/ckpt-TAG/. No
                                   #   asserts, no leg workload; its serial
                                   #   and stdout stay as
                                   #   artifacts/NAME-ckpt-TAG-*.
vgate_client TAG -- FLAGS...       # (M46 RC2 #1069) a during-run TCP client:
                                   # tools/lib/vgate-client.py runs in the
                                   # background while the TAG run boots; it
                                   # exits non-zero => the run fails. Flags:
                                   # --addr host:port (req), --after MARKER,
                                   # --send-file FILE | --send-text TEXT,
                                   # --expect TEXT, --expect-fail,
                                   # --hmac-secret S (M50 TS4: answer the
                                   #   --console-tcp HMAC challenge),
                                   # --retry-busy (M70g G2 #1459: a
                                   #   `console-tcp: busy` answer is retried
                                   #   until --connect-timeout), --hold S
                                   #   (stay connected S s after the payload),
                                   # --timeout S, --connect-timeout S,
                                   # --after-timeout S, --out FILE.
                                   # Capture: $RUN_DIR/client-TAG.out
vgate_allow_rc TAG RC...           # allowed VMRunner exit codes for TAG (default 0;
                                   # e.g. 1 for death-asserting gates like reboot)
vgate_assert TAG KIND [args]       # all asserts of a TAG must hold, plus
                                   # runner rc in allowed set; failing assert = failed run
```

Assert KINDs (serial = the run's `vm-serial.log` copy; output = runner stdout):

| KIND | args | holds when |
|---|---|---|
| `serial-contains` | STR | STR occurs in serial (fixed-string) |
| `serial-contains-file` | FILE | contents of `$RUN_DIR/FILE` occur in serial (generated fixtures) |
| `serial-count` | STR MIN | STR occurs ≥ MIN times |
| `serial-exact` | STR N | STR matches exactly N whole lines (mirrors `grep -aFxc`; a command echo and its output are different lines) |
| `serial-absent` | STR | STR never occurs (e.g. `[EXC] parking:`) |
| `serial-echo` | CMD | `gate_serial_has_echo` accepts CMD (colored-or-plain prompt echo) |
| `output-contains` | STR | STR occurs in runner stdout (e.g. `input-string: ENABLED`) |
| `client-contains` | STR | STR occurs in the run's `$RUN_DIR/client-TAG.out` (the `vgate_client` capture) |
| `capture-equals` | FILE FIXTURE | `$RUN_DIR/FILE` is byte-equal to `$RUN_DIR/FIXTURE` (5×0.5 s retry; copied to evidence) |
| `capture-empty` | FILE | `$RUN_DIR/FILE` missing or zero-length |
| `share-equals` | RELPATH FILE-OR-LITERAL | the ARMED share's `RELPATH` is byte-equal to the literal, or to `$RUN_DIR/FILE-OR-LITERAL` when that names an existing file (5×0.5 s retry; copied to evidence) |
| `share-contains` | RELPATH STR | the armed share's `RELPATH` exists and STR occurs in it (fixed-string; copied to evidence) |
| `snapshot` | GLOB + python on stdin | newest `$RUN_DIR/GLOB` exists and the python (path as `sys.argv[1]`, `sys.exit(str)` fails) passes; snapshot copied to evidence |
| `python` | python on stdin | hook passes (`$RUN_DIR`/`$VG_SER`/`$VG_TAG`/`$VG_SHARE` env; nonzero exit fails) |

Rules:

- Assert values are **literal** — no expansion. Files a hook needs go
  through `vgate_file`/`vgate_setup_python` (`$RUN_DIR` env) or the
  `FILE`/`FIXTURE` operands (resolved under `$RUN_DIR`).
- The `share-*` kinds read the **armed share** (`vgate_share arm|seed` or
  `arm-virtiofs|seed-virtiofs`),
  which is what makes them differ from the `capture-*` kinds (those read
  `$RUN_DIR` files a client hook wrote). Both fail closed: a share that was
  never armed, a `RELPATH` that is not there, or a mismatch are all FAILs,
  never skips. `share-equals` resolves its expectation the same way the
  capture kinds resolve `FIXTURE` — **an existing `$RUN_DIR` file wins over
  the literal**, so a one-line value is passed as a literal and anything
  with newlines goes in a `vgate_file` fixture (real newlines in a literal
  need `$'…\n…'`). A typo'd fixture name therefore degrades to a literal
  compare, which fails rather than passing.
- Both `share-*` kinds copy the share file they compared into evidence
  (`artifacts/NAME-share-<RELPATH with / and space to _>`), because the
  share is deleted at `gate_end` — a spec that reads the share with `python`
  instead has to do that copy by hand, which is the main reason to prefer
  these kinds.
- The one exception is `vgate_run` FLAGS: a literal `$RUN_DIR` (or
  `${RUN_DIR}`) token there expands to the run dir at execution, so specs
  can name their `vgate_file` outputs (`--script $RUN_DIR/script.txt`).
- `vgate_file` bodies are newline-terminated files by contract (the
  harness re-appends the single trailing newline `$(cat)` strips — a
  missing terminator glues the last script line to the next forwarded
  chunk and the guest executes them as one line).
- Runner flags are **passthrough** — the harness never enumerates the
  VMRunner surface, so new runner knobs need no harness change.
- Evidence per run: `artifacts/NAME-serial-TAG.log`,
  `artifacts/NAME-run-TAG.txt`, `artifacts/NAME-report.txt`, referenced
  captures/snapshots, all `VIRELAI_GATE_SUFFIX`-aware.
- `vgate_client` is launched once per matching run **before** VMRunner with
  `RUN_DIR`/`VG_SER`/`VG_TAG` in its environment; the harness waits for it
  after the run and fails the run on a non-zero exit (evidence
  `artifacts/NAME-client-TAG.{out,log}`). A client that cannot connect within
  its timeout exits non-zero — so "no listener ⇒ run fails" is the negative
  default; `--expect-fail` inverts that for a gate asserting refusal. A spec
  may declare several clients for one run, but **only the last-declared
  client's exit code is enforced** and the default capture/log names are
  shared (observed 2026-09-18, M70g G2): give earlier clients their own
  `--out` and pin them with `python`/`serial-*`/`output-contains` asserts
  (`live-console-tcp` run 03 is the pattern).
- `VGATE_NO_BUILD=1` skips the build preamble (dev iteration only).
  It is only valid when the already-built runner matches the spec's
  `vgate_runner_flags` (plain vs `-DSPIKE`): a stale-variant binary fails
  with the runner's SPIKE error, not a gate failure.
- `VGATE_WARM=off` (ADR 0059 D8): run every `--from-checkpoint` leg cold
  with its checkpoint's device flags + its original script flags — no base
  boot runs, and the receipt records `warm=cold`. M131c's parity check and
  the cold-vs-warm wall-clock numbers need it on the same revision.
- **Warm legs (ADR 0059, M131b #2639).** A `vgate_checkpoint` boot pauses
  at a quiescent prompt and persists a bundle — `state.vzsave`,
  `overlay.asif`, `machine-id.bin`, a pinned `efi-vars.bin`, and `share/`
  when the spec arms `*-virtiofs` — immutable once taken. A
  `--from-checkpoint` leg gets its own `cp -c` clones of every bundle
  member under `$RUN_DIR/warm-<tag>/`; `SHARE`/`VG_SHARE` point at the
  leg's share clone, so `share-*` and `python` asserts see the leg's own
  writes. After restore → resume the runner marks the serial-epoch
  boundary, writes `\n`, and waits for a fresh `virelai> ` inside the
  epoch before forwarding `--script` (D5): the leg's first `--script-after`
  is re-based onto that handshake (the run output names the re-base), and
  `vm-serial-<tag>.log` holds only post-restore bytes (D6). Later
  `--scriptN-after` markers must re-fire inside the leg's own epoch.
- **Refusal and receipt.** `restoreMachineStateFrom` refusing exits the
  runner with status 75 and exactly one stdout line
  `VZ-RESTORE: refused code=<N>`. On that signal — and only that signal —
  a non-strict leg cold-boots once with its original flags (no retry); a
  strict leg FAILs. A leg that restores and then fails asserts is never
  re-run cold. Two classes are refused at spec load and never attempted
  (D8's static Code=2 class): a `--from-checkpoint` leg in a
  `vgate_share arm|seed` spec, and a `vgate_checkpoint` carrying a
  custom-virtio-arming flag. Every leg's report line carries
  `warm=restored|fallback(<code>)|cold` (plain `vgate_run` legs print
  `warm=cold`); a refused strict leg reports `warm=refused(<code>)`.
- Extending this file (new KINDs, new commands) is a spec-format change:
  it needs its own issue and a pilot proving it. GF3/GF4 add specs only.
  Amendments since M40 GF2: issue #1386 (M61f) added the `share-equals`
  and `share-contains` kinds, piloted in `go-selftest.spec`; #2639 (M131b)
  added `vgate_checkpoint` + `vgate_run --from-checkpoint`, piloted in
  `vgate-warm-smoke.spec`. The serial kinds were deliberately left alone,
  and no VZ CI enforcement was restored.
- Since M40 GF5 (issue #940) the spec dir is the class-B fleet's single
  source of truth: dropping a `*.spec` here registers it in `just gate`,
  `just gates`, `just verify-vz`, the `vz-gates.yml` CI shards, and the
  fleet section of `docs/gate-fleet-inventory.md` with zero list edits.
  Do not commit a re-render of that snapshot in the spec PR. Discovery lives
  in `tools/gate/fleet.sh`.

## exec ordering: `exec` returns immediately (claim #1193)

`exec` loads a program, spawns it as an EL0 task, and **returns**. It does not
wait for the program to run, let alone finish. So a boot script that launches a
program and then does anything else has given up its ordering: the next line
runs while that program is still starting. The serial log hides this — it looks
interleaved-but-complete — and it produced a real failure: live-oliver's first
spec drove a second invocation, and a `vf rm` between them, while the first
program was still writing (#1188).

One more consequence: a script cannot sequence two exec'd programs, because the
harness stops the VM when `--script-expect` matches. **One invocation per
boot**, plus the markers to order the run:

1. **Graded run (preferred).** End the run on a marker the PROGRAM prints, and
   hold later scripts with a stage gate — `--script-after` / `--script2-after` /
   `--script3-after` / `--input-string-after` wait for guest output before the
   next script forwards.
2. **Self-sequencing.** Launch with `&` and block on the program with `fg N`
   (the guest shell has `jobs` and `fg`; there is no `wait`/`bg`), so the
   closing marker cannot be echoed before the program's output is logged.
3. **Timeout-ordered.** Bound the run with `--timeout` and assert only
   order-independent facts — nothing that needs program output.

If a spec carries a shape the guard cannot prove safe, it must declare the
intent in a header comment or the guard fails it:

```
# exec-order: <class> -- <one-line reason>
```

| class | means |
|---|---|
| `intentional` | the author vouches for the ordering and says why — the bucket for a provable case the parser cannot see (e.g. an exec whose binary does not exist, so the refusal is synchronous and no program ever runs) |
| `self-sequenced` | idiom 2: the script blocks on the program (`fg N`) |
| `timeout-ordered` | idiom 3: `--timeout`-bounded, asserts need no program output |
| `assert-proven` | the run ends on a script marker, but its asserts read output only the program produces, so a program that never ran still fails the run — the residual risk is a late tail (a flaky FAIL, never a false pass) |

The class must be one of those four: a typo is a hard failure, not a silent
exemption, and declarations are printed in the guard's output so they stay
visible.

Enforcement is `check_spec_order` in `tools/inventory-gates.sh` (`--check`,
hence `just verify-portable`), which flags exactly two mechanical shapes: a run
that launches a program and ends on a marker the script itself supplies with no
stage gate anchoring it on guest output, and a `vf` file-channel operation
following an `exec` in one script. A stage gate only counts as an anchor when
at least one of its markers is NOT supplied by any script the run forwards —
a gate on the script's own echo is a delay, not a gate; the shell prompt does
count, since the guest prints it. Anything else that launches two programs from one script is the
author's to prove. The guard is itself regression-tested against
`tools/gate/fixtures/exec-order/{fail,pass}` — never fleet members, never
executed, excluded from the fleet because `fleet.sh` globs this directory only.
