# live-jobs.spec -- foreground/background jobs: `exec ... &` launch
# lines, `jobs` listing, one Done line with the real registry status,
# and an honest bounded-wait timeout on the eternal child.
# Mirrors tools/verify-live-jobs.sh (M19 P7, issue #296).

# exec-order: self-sequenced -- `fg 2` reaps STATUS43.BIN before the closing
# `echo jobs-done` the run ends on, so the `Done: ... (exit=43)` line the python
# assert counts is already logged. `fg 1` returns early by design (bounded wait
# on the eternal child; nothing asserted after it needs COUNTER.BIN output).

vgate_name live-jobs "background jobs with real exit status on VZ"
vgate_share seed
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec COUNTER.BIN &
jobs
exec STATUS43.BIN &
echo filler-1
echo filler-2
fg 1
echo drain-a
echo drain-b
fg 2
echo drain-c
echo jobs-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'jobs-done' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-contains 'jobs-done'
vgate_assert 01 python <<'PY'
import os, re, sys
# Legacy grep -x BRE counts: \[ = literal [, . = any char, whole line.
# Legacy grep -x BRE counts: \[ = literal [, . = any char, bare ( ) =
# literal parens (BRE groups are \(...\)). The \( \) below preserve that:
# unescaped parens would become groups and never match the literal text.
pats = [
    r"\[1\] running: COUNTER.BIN",
    r"\[2\] running: STATUS43.BIN",
    r"\[1\] Running: COUNTER.BIN",
    r"\[2\] Done: STATUS43.BIN \(exit=43\)",
]
# A running job's `counter: alive` markers interleave between the shell's
# own puts fragments (e.g. "fg: job 1" / " still running", "[2" / " Done:"),
# so whole-line matching never sees the joined line. Strip the marker
# lines and rejoin — the fragments concatenate back to the full lines.
ser = open(os.environ["VG_SER"], errors="replace").read()
joined = "".join(
    l for l in ser.splitlines(keepends=True)
    if "counter: alive" not in l
)
if "fg: job 1 still running" not in joined:
    sys.exit("FAIL: fg still-running line absent")
lines = joined.splitlines()
bad = [(p, sum(1 for l in lines if re.fullmatch(p, l))) for p in pats]
bad = [(p, c) for p, c in bad if c != 1]
if bad:
    sys.exit("FAIL: jobs lines not exactly-once: %s" % bad)
print("jobs lines ok")
PY
