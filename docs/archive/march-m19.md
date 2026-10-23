> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone nineteen march — shell as programming environment (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M19's per-card detail and agent split, following
> the established march-file pattern.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

M18 gives us a comfortable terminal (scrollback, selection, search, history,
colors). But the shell is still a one-command-at-a-time echo chamber. M19
turns it into a *tool* — pipes so commands can talk to each other,
redirection so output goes to files, environment variables so state persists
within a session, functions so users can build reusable commands, and scripts
so complex workflows can be saved and replayed.

**Two new syscall slots** for pipes (56/57). Everything else is pure userland.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| P1 | **Pipes.** `cmd1 \| cmd2` — stdout of cmd1 feeds stdin of cmd2. Bounded: one pipe at a time, max 4 KiB buffer. `echo hello \| type` prints "hello". `ls \| type` lists directory contents through the pipe. The pipe is set up before cmd1 runs, cmd1 writes to it, cmd2 reads from it after cmd1 exits. | ✅ | claim 7033: `verify-live-pipe.sh` PASS 1/1 on VZ; `echo hello \| type` → `hello`, `ls \| type` lists the ESP, chaining refused | Kernel: slot 56 `sys_pipe_read(buf, max)`, slot 57 `sys_pipe_write(buf, len)` (implemented_count 58). BSS pipe buffer (4 KiB, `kernel/src/pipe.zig`). The shell parses `\|` (outside quotes), runs cmd1 with a sink console (stdout → pipe), then cmd2 with a source console (stdin ← pipe, stdout → real console). Single-pipe only (no chaining `a \| b \| c`). `type` builtin echoes the pipe source. |
| P2 | **Redirection.** `cmd > file` writes stdout to a file (create or overwrite). `cmd < file` reads stdin from a file. `cmd >> file` appends stdout to a file. Reuses existing file syscalls (slots 23–27). No new ABI. | ✅ | claim 7033 P2: host tests pass (628/628 shell, 6 redirect module); live gate pending | New `kernel/src/redirect.zig` (4 KiB capture buffer, `capture_console`/`feed_console` adapters). `shell.zig`: `redirect_split` (finds `>`, `>>`, `<` outside quotes), `run_redirect_out` (capture stdout → write/append file), `run_redirect_in` (pre-load file → feed stdin). No new ABI. |
| P3 | **Environment variables.** `set VAR=val` defines a variable. `$VAR` expansion in any command. Bounded: 16 variables × 64 characters. `unset VAR` removes. `env` shows all. Persisted to FAT (survives reboot). | ✅ | claim 7033 P3: host tests pass (634/634 shell, 6 new env tests); live gate pending | Reuses M18 T12 `EnEntry` table (16 × 64 B). `env_unset`, `save_env`/`load_env` (ESP window). Builtins: `set`, `unset`, `env`. Boot restore via `load_env`. No new ABI. |
| P4 | **Shell functions.** `fn name { cmd1; cmd2 }` — user-defined multi-command sequences. `name` executes them. Bounded: 8 functions × 4 commands each. `fn` lists defined functions. `fn -d name` deletes. | ✅ | claim 7033 P4: host tests pass (640/640 shell); live gate pending | `shell.zig` BSS table. Functions stored as parsed command strings, executed sequentially via `shell_handle_expanded`. Bare `fn` lists; `fn -d` deletes. P8 adds arguments. |
| P8 | **Function arguments.** `fn name(a, b) { cmd1; cmd2 }` — arguments from parens, `$0`–`$N` positionals, `$name` named. `fn` listing shows signature. | ✅ | claim 7033 P8: 646/646 shell tests (6 new P8 tests); live gate pending | `FuncEntry` extended with `arg_names[4][16]`, `arg_count`. Body lines expanded at invocation time. `handle_line` skips expansion for `fn` commands. |
| P9 | **Command substitution.** `$(cmd)` — inline captured stdout. `echo $(echo hello)` prints `hello`. No nesting. Bounded: 256 bytes. | ✅ | claim 7033 P9: 653/653 shell tests (7 new P9 tests); live gate pending | `cmd_subst` scans for `$()`, runs inner cmd via `handle_line` with capture console, substitutes output. `subst_active` guard. `fn` bodies skip. |
| P10 | **Arithmetic expansion.** `$((expr))` — evaluate 64-bit signed integer expression, substitute result. `echo $((2+3*4))` → `14`. Supports `+ - * / % ()` and unary minus. No variable references. | ✅ | claim 7033 P10: 665/653 shell tests (12 new P10 tests); live gate pending | `ArithLexer` + recursive-descent parser (precedence: `()` > unary > `* / %` > `+ -`). `arith_expand` scans `$((...))`, depth-matches `))`, evaluates, formats decimal. Wired before `cmd_subst` in `handle_line`. |
| P11 | **Conditionals.** `if COND; then BODY; [else BODY]; fi` — test exit status. `true` and `false` builtins. `last_exit_ok` tracks status. Single-line syntax, body commands separated by `;`. | ✅ | claim 7033 P11: 672/672 shell tests (7 new P11 tests); live gate pending | `find_if_keyword` whole-word matching. `run_if_body` splits on `;` via `shell_handle_expanded`. `last_exit_ok` bool (4 BSS). `monitor.exec` calls set exit status. |
| P12 | **Loops.** `for VAR in WORD1 ...; do BODY; done` and `while CMD; do BODY; done`. `break`/`continue`. Bounded: 256 iterations. For loop unsets `$VAR` after. | ✅ | claim 7033 P12: 683/683 shell tests (11 new P12 tests); live gate pending | `find_loop_keyword` whole-word matching. `run_loop_body` splits on `;` via `handle_line`. `for` sets/unsets `$VAR` via `env_set`/`env_unset`. `while` evaluates condition. `handle_line` skips expansions for for/while. |
| P13 | **Here-documents.** `cmd <<DELIM` ... `DELIM` — feeds collected lines as stdin. Quoted `"DELIM"` prevents `$VAR` expansion. Bounded: 64 lines, 4 KiB. | ✅ | claim 7033 P13: 689/689 shell tests (6 new P13 tests); live gate pending | `handle_line` detects `<<DELIM` before expansions, enters collection mode. `redirect.feed_console` feeds content. Trailing newline after last line. |
| P14 | **Pipe to/from files.** `cmd1 < in.txt | cmd2 > out.txt` — pipes and redirects compose. No new code needed. | ✅ | claim 7033 P14: verified, 2 new tests; live gate pending | Existing P1+P2 compose: `redirect_split` finds `>`/`<` in lines with `|`, adapters swap console independently. |
| P15 | **set -x tracing.** `set -x` enables trace, `set +x` disables. Each command printed as `+ cmd` before execution. | ✅ | claim 7033 P15: 693/693 shell tests (2 new P15 tests); live gate pending | `trace_enabled` bool. `set -x`/`+x` builtins. Trace in `shell_handle_expanded` after tokenization. |
| P16 | **Temp files.** `mktemp [prefix]` — creates empty file with unique CSPRNG name (`PREFIX_XXXX.BIN`). | ✅ | claim 7033 P16: 693/693 shell tests, 526/526 monitor tests; live gate pending | `cmd_mktemp` in monitor.zig. CSPRNG 4-hex suffix. `esp.write_file` creates empty file. |
| [#292](https://github.com/drawmeanelephant/DipshitOS/issues/292) | **Command chaining** (GitHub milestone numbering; `;`, `&&`, `\|\|`). `;` lowest precedence, `&&`/`\|\|` equal left-to-right, short-circuit on the live status (skipped segments change nothing → POSIX mixed-chain behavior). Bounded: max 4 commands per chain, refused honestly beyond. Structured forms (`if`/`for`/`while`/`fn` lines) bypass un-split so their internal `;` survives. | ✅ | claim 5759: chain_split + run_chain + per-segment `expand_and_dispatch`; 706/706 shell-module host tests (13 new); class-B `tools/verify-live-chain.sh` PASS 1/1 on VZ (`artifacts/live-chain-gate.txt`) | Split on the RAW line outside double quotes BEFORE any expansion; each segment expands at its own execution time — `$?`/`$(cmd)`/`$VAR` in later segments observe what earlier segments did (the VZ gate caught the up-front-expansion ordering bug during bring-up). Empty segments are no-ops that preserve status. |
| [#293](https://github.com/drawmeanelephant/DipshitOS/issues/293) | **Exit status propagation** (GitHub milestone numbering). Numeric `last_exit: u8` kept in lockstep with the P11 bool via `set_exit_ok`/`set_exit_code`; `$?` read-only substitution in `env_expand`; conventional dispatch mapping (`.none`=0, unknown=127, usage=2, failure=1); colored prompt green on 0 / red otherwise. | ✅ | claim 5759: `$?` round-trip, 127/2/1 mapping, and execution-time expansion pinned by host tests; covered by class-B `verify-live-chain.sh` PASS 1/1 (`exit=1`, `ok=0`) | Honest boundary: external programs are fire-and-forget spawns (the interactive shell never blocks), so `$?` reflects spawn/dispatch results exactly as the issue's example asserts; child exit statuses remain observable via `procs`/`ps`. |
| [#294](https://github.com/drawmeanelephant/DipshitOS/issues/294) | **Quoting & escaping** (GitHub milestone numbering). Tokenizer is a full state machine: single quotes fully literal (mid-token quotes JOIN fragments — supersedes the M1.5 mid-token-literal rule), double quotes protect spaces with `\"` `\\` `\$` `\n` `\t` escapes per the issue, outside-quote backslash escapes any byte (defusing operators/expansions). `env_expand` goes single-quote-aware; `\X` pairs pass through so `\$VAR` survives to the tokenizer. Chain/pipe/redirect scanners learn quote+escape states. | ✅ | claim 5424: tokenizer rewritten with caller-provided scratch (`tokenize(line, scratch)`), U3 fuzz test updated for the two-buffer reality; 720/720 shell host tests (14 new); class-B `tools/verify-live-quote.sh` PASS 1/1 on VZ (`artifacts/claim-5424-m19-p5p6/`) | Unbalanced ANY quote keeps the rest-of-line literal warning. Scratch bounded by the line bound, BSS-resident per the script_staging precedent. |
| [#295](https://github.com/drawmeanelephant/DipshitOS/issues/295) | **Globbing** (GitHub milestone numbering). After tokenization, argv slots flagged by the tokenizer (UNQUOTED/UNESCAPED `*` `?` `[`) expand against the ESP window listing (the bare-`ls` universe); fnmatch-style iterative matcher (`*` explicit-backtrack, `?`, `[abc]`, `[a-z]` classes); matches byte-sorted; no match → literal passthrough (nullglob-off); max 64 matches per line TOTAL, honest refusal beyond. | ✅ | claim 5424: matcher unit tests + no-disk passthrough e2e in 720-test suite; class-B `tools/verify-live-glob.sh` PASS 1/1 on VZ — `*.bin` / `g?.bin` / `g[a-b].bin` all expand sorted to `ga.bin gb.bin`, `zz*.nomatch` stays literal | Bounded scope: ESP root listing only, no recursion, no `**`. Expansion happens before builtins AND registry dispatch, so `ls *.BIN` and `echo *.BIN` both expand. |
| [#296](https://github.com/drawmeanelephant/DipshitOS/issues/296) | **Foreground/background jobs** (GitHub milestone numbering). One trailing unquoted/unescaped `&` backgrounds the launch; 4-slot BSS job table tracks pids; the poll idle path reaps and prints `[N] Done: NAME (exit=CODE)` once with the child's REAL registry status; `jobs` lists live state; `fg [N]` reports finished jobs immediately (propagating child status into `$?`) or bounded-waits ~5 ticks (WFE, no console reads) and honestly reports `still running` on timeout. | ✅ | claim 1751: trailing-amp scanner + job table + reaper + fg/jobs builtins; 729/729 shell host tests (9 new, incl. fabricated-process fg propagation); class-B `tools/verify-live-jobs.sh` PASS 1/1 on VZ (`artifacts/claim-1751-m19-p7/`) | Honest scope: only program launches spawn processes here — builtins are synchronous EL1 calls, so a `&` on them records no job. Registry pids start at 0 (the free-slot sentinel had to be `?usize`, caught by host tests). |
| P5 | **Script mode.** `sh script.BIN` — reads a file of shell commands from FAT and executes them line-by-line. Bounded: 64 lines max. Each line is a full shell command (supports pipes, redirection, env vars). `exit` stops early. | ⬜ | — | `shell.zig` script state (line counter, file handle). Reads from FAT via existing file syscalls. Feeds each line through the normal shell parser. No loops, no conditionals — straight-line execution only. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Kernel pipe** | `kernel/src/syscall.zig` (slots 56/57), `kernel/src/shell.zig` (pipe setup), `kernel/src/pipe.zig` (new file, BSS buffer + read/write). | M18 done. |
| **B — Shell features** | `kernel/src/shell.zig` for P2 (redirection), P3 (env vars), P4 (functions), P5 (scripts). Sequential: P2 → P3 → P4 → P5. | P1 (pipe lands first, shell.zig changes merge). |

## Notes

1. **ABI budget:** 2 new syscall slots (56/57) for pipe read/write.
   Cumulative: 58/64 after M19.
2. **BSS budget:** Pipe buffer 4 KiB + env array 1 KiB + function table
   ~2.3 KiB + script state ~256 bytes. Total M19 BSS delta: ~7.6 KiB.
3. **Gate shape:** P1: `verify-live-pipe.sh` — `echo hello | type` round-trip.
   P2: `verify-live-redirect.sh` — write to file, read back.
   P3: `verify-live-env.sh` — set/expand/unset/persist.
   P4: `verify-live-function.sh` — define/call/list/delete.
   P5: `verify-live-script.sh` — script execution with pipe + redirect.
4. **Pipe semantics:** The pipe buffer is filled by cmd1 until it exits or
   the buffer is full, then cmd2 reads from it. This is a simplified model
   — no streaming between concurrent processes. Both commands run
   sequentially (cmd1 completes, then cmd2 runs with the buffered output).
   This matches the bounded, no-heap philosophy.
5. **Scope exclusions:** No command substitution (`cmd $(cmd2)`). No
   conditionals (`if/else`). No loops (`for/while`). No subshells. These
   are programming-language features, not shell features.
