# sandbox-negatives fixtures (M116e, issue #2471)

The fixture battery for `tools/gate/specs/live-sandbox-negatives.spec`
— a `GRANTS.TXT` `#v1 mode=enforce` table plus the two guest binaries
the corpus copies under each fixture name (the row, not the bytes, is
the controlled variable — the live-trust-grants pattern).

- `probe.go` — the boundary-word probe: a `file` open, a `net` dial,
  one named print per outcome, clean exit. Staged as every probe-side
  name (`NOROW`/`NONET`/`NOFILE`/`GRANTED`, the exec-refused
  `STALE`/`BADSHA`/`BADWORDS`/`BADTO`/`BADFS`/`BADCNT`, and `FORGED`).
- `rowwriter.go` — the row-write attempts: slot-89 `write`/`self`/`read`
  and the file-ABI `GRANTS.TXT` write, each answered with a named errno
  print.
- `GRANTS.TXT` — the seeded user table: `enforce` posture, three valid
  narrowing rows, the `WRITER` file-word row, and one row per malformed
  shape (bad sha field, unknown word, bad `to=` endpoint, off-vocabulary
  `fs=` path, a fifth field) — each poisoned row must refuse its binary
  `grant_stale` at exec.

Per-run build (the spec's setup hook does this):

```bash
GO_BUILD_OUT=$SHARE GO_BUILD_NAME=NEGPROBE \
    bash tools/go/build-go.sh tools/gate/fixtures/sandbox-negatives/probe.go
GO_BUILD_OUT=$SHARE GO_BUILD_NAME=ROWWRITE \
    bash tools/go/build-go.sh tools/gate/fixtures/sandbox-negatives/rowwriter.go
```
