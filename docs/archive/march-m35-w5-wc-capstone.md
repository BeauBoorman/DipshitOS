> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# March: M35 W5 — the ecosystem capstone: wc (issue #766)

Prompt/plan for issue #766 (Milestone #22, M35 WASM core interpreter W1–W5).
Owner: `buffy2` on `agent/buffy2/m35-w5-wc-capstone` (claim 5883).
Tracker: `docs/archive/wasm-core-scoping.md` card table. Baseline: W4 done
(claim 7395) — f32/f64, sign-ext proof, bulk-memory 0xFC 8–11, floatapp
live-gated; `user/src/wasm.zig` 38/38 host tests.

> **STATUS: ✅ DONE 2026-09-02 — Milestone #22 6/6.** All slices landed
> and live-gated: native cross-run caught two authoring slips (a
> `put_pad` uninitialized-index bug and a 15-vs-14 length on the path
> write) before anything was pinned; one gate boot hit the known M34
> VZ-error flake (issue #803 class) and the rerun PASSed with all
> needles green. See the claim log for the full evidence trail.

## Goal

The milestone's payoff, per the issue: **a real tool — not a hello-world —
ported to wasm via `zig cc`, shipped as an HF4 app, and used**; plus the
import contract complete enough that a fresh host author writes a working
`virelai.h` program from the doc alone. Both halves land in one slice.

## What wc is (frozen in W1a's D3)

- Byte/line/word counts of a file read **through the file channel**
  (env.file_open/file_read/file_close — the M34 HF4 share is the disk),
  printed byte-exact. Integer-only — W4's float work stands on floatapp.
- Wasm `_start` takes no argv → the path is a **static constant**
  `/host/WC.TXT` (same hardcode as fileapp's `/host/FILE.TXT`).
- Streaming: 64-byte chunks (the kernel clamps reads to 2048 anyway;
  small chunks prove the multi-chunk path). Counts:
  - bytes = sum of read lengths (also the exit status — fileapp's
    "exit = bytes read" length proof);
  - lines = count of `\n` bytes;
  - words = count of transitions into a maximal run of non-whitespace
    (space/tab/\n/\r/\v/\f), the state flag carried across chunk
    boundaries (an in-word run must not double-count at the seam).
- Output: the classic wc line, right-aligned to the widest of the three
  counts: `%*d %*d %*d /host/WC.TXT\n` (real-wc shape; byte-exact and
  deterministic — no locale, no padding surprises).
- Error exits: open failed 41, read failed 42 (distinct statuses, mirroring
  fileapp's 31/32/33 discipline).

## The standalone-author proof (issue's second half)

`tests/wc.c` is written from **`docs/wasm-import-contract.md` + the shim it
blesses (`tests/virelai.h`) alone** — §5.1 rows for the file imports (§4
error model, §3 pointer conventions), §7 author recipe for the compile line.
No `user/src/wasm.zig` reads while authoring. The doc's §7 gains a short
"worked example: wc" block (path-constant + read-loop + EOF semantics) so
the promise is concrete for the next author; a W5 provenance note records
which doc sections produced which wc.c lines.

## Verification plan

1. Author wc.c against virelai.h alone (provenance block in the log).
2. Native cross-validation: counts for the fixture computed independently
   in Python; print format (widths/padding) replicated in Python; also
   diff the count triple against host `wc -lwc` on the same bytes.
3. `zig cc -target wasm32-freestanding -nostdlib -fno-sanitize=undefined
   -g0 tests/wc.c -o user/src/wasm-corpus/wc.wasm`; pin sha256; decode the
   module (imports must be exactly `env.*`; assert byte-identity of the
   rebuild).
4. Host test in wasm.zig: extend `HostCapture` with `file_data`/`file_pos`
   so captured `file_read` serves the pinned fixture bytes via `stageOut`
   (0 at EOF, cap-clamped — kernel-faithful). Then execute wc end-to-end:
   parse → validate → instantiate → run; env.write captured byte-exact;
   assert the exact count line, exit status = fixture byte count,
   `exited` flag.
5. Live gate (`tools/verify-live-wasm.sh` W5 phase): WC.WASM copied +
   sha-pinned; deterministic WC.TXT written host-side (like FILE.TXT);
   `exec WASM.BIN WC.WASM` + `echo rx-w5-wc` in script1 (before winapp,
   keeping the concurrent-overlap invariants); assert the exact count
   line, `tasks user-exec exited status=<bytes>`, `rx-w5-wc`, and the
   FAIL_NEEDLES stay silent.
6. Docs flips: scoping card W5 row ✅, contract §7 example + provenance,
   status.md M35 row → done 6/6 (milestone closure note rides the PR).
7. Full gate run on VZ (BOOTS=1) for the PASS evidence; log + commit.

## Risks

- **Host capture realism**: the simulated file_read must match kernel
  semantics (0 at EOF, cap clamp) or the host test could pass where the
  live path fails — mitigated by running the live gate, the real proof.
- **wc output width**: if counts share a width, the line is
  ` 19  23 154 /host/WC.TXT` (widths right-aligned with a single leading
  space per column in classic wc? — NO: classic wc separates with ONE
  space after the padded number; the fixture's exact string is computed by
  the Python cross-check and asserted byte-for-byte, so any drift shows).
- **Fixture choice**: WC.TXT must exercise >1 chunk (>64 B), multiple
  lines, words spanning chunk seams, a trailing newline, and
  whitespace-variety — deterministic content, counts precomputed.