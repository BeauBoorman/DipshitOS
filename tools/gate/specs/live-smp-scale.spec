# live-smp-scale.spec -- M70b (#1454): multicore M placement + accounted
# work for GOOS=virelai at --cpus 1/2/4 (one boot each).
#
# The fixture (tools/go/smpscale.go) sets GOMAXPROCS(4) — the stock runtime
# knob, no GOOS delta — spins 4 workers that hold 4 Ms simultaneously
# runnable, and holds a >= ~6 s busy window (the kernel scheduler tick is
# ~1 Hz) so script2's single `smp` fires INSIDE the window and the
# per-core `task=` column (kernel/src/monitor.zig cmd_smp: slot-73 tasks
# carry the PROCESS name) proves the placement. Phase B is accounted work:
# 4 workers x 25000 units, one unit = a bounded pure-userspace arithmetic
# burst (NO syscalls — observed: a slot-2 sys_yield is a full ring
# rotation, and with the 1 Hz tick a non-yielding ready task sharing the
# ring takes the quantum for up to a second) plus one atomic add to the
# worker's own counter; the python blocks prove every unit accounted
# exactly once (per-worker lines sum to 100000 and the done line equals
# that sum). The `goscale: ticks=` line is the raw CNTPCT_EL0 delta around
# the SAME 100k units at --cpus 1/2/4 — a real parallelism measurement,
# OBSERVED DATA, asserted present, never a threshold.
#
# PLACEMENT ACCOUNTING (do not "fix" to all cores later): cmd_smp runs in
# shell context — task 0, name "shell" (monitor.zig cmd_smp reads
# scheduler.current_task_for_core; scheduler.zig init() names task 0) — so
# the core EXECUTING the report always prints task=shell. With 5 runnable
# GOSCALE tasks (4 spinning workers + main's Gosched loop) and
# GOMAXPROCS=4, every NON-zero online core shows task=GOSCALE.ELF:
# --cpus 4 -> at least 2 distinct non-zero core lines (the placement
# heuristic is racy BY DESIGN — a stale load read can strand one wake on
# the caller — so the gate asserts the SPREAD, not the best case);
# --cpus 2 -> exactly core 1 (the only online secondary). The
# discriminating targeting evidence is the `smp: wakes=` report line:
# remote=0 forced at --cpus 1, remote>=1 at 2/4.
#
# script1 runs `smp` BEFORE the exec on purpose: that boot report is the
# only source of the exact `smp: cores=N online=N` line (there is no
# boot-banner smp line), and pre-exec it cannot add task=GOSCALE.ELF
# lines — the busy-window report from script2 must stay the sole
# placement evidence. The exact per-core placement shape lives in the
# python blocks: a per-core line is `  core <c>: bsp|ap   mpidr=<hex>
# state=<st> ticks=<n> task=<NAME>` (mpidr/ticks vary, so serial-exact
# cannot match it; the `smp: secondary/steal runs=` drain lines also
# carry task= but name no core, which is why serial-count on the raw
# string is only a floor).
#
# HOST PREREQUISITE (not hermetic — see tools/go/README.md):
# .build/go/GOSCALE.ELF from
#   bash tools/go/build-go.sh tools/go/smpscale.go
#
# exec-order: assert-proven -- the run ends on the program's own final
# line, and every asserted marker (busy/released/w*/done/ticks) is
# program output, so a program that never ran still fails the run; the
# residual risk is a late tail (a flaky FAIL, never a false pass).

vgate_name live-smp-scale "M70b: multicore M placement + accounted work at --cpus 1/2/4"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
smp
exec GOSCALE.ELF
EOF

# Fires on the busy anchor, inside the held window: exactly one `smp`
# during the window, so the per-core task=GOSCALE.ELF lines below come
# from this one report.
vgate_file script2.txt <<'EOF'
smp
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
for name in ("GOSCALE.ELF",):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - "
                 "build the fixture first: bash tools/go/build-go.sh "
                 "tools/go/smpscale.go")
    shutil.copy(src, os.path.join(share, name))
print("staged GOSCALE.ELF into share")
PY

# script1 sends at the default boot marker (smp + exec); script2 fires on
# the program's busy anchor mid-window; the run ends on the program's own
# final ticks line, after phase B is fully printed.
vgate_run 01 -- --cpus 1 --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'goscale: busy m=4' --script-expect 'goscale: ticks=' --timeout 240

vgate_assert 01 serial-contains 'smp: cores=1 online=1'
vgate_assert 01 serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert 01 serial-contains 'goscale: busy m=4'
vgate_assert 01 serial-contains 'goscale: released m=4'
vgate_assert 01 serial-contains 'goscale: w0 units=25000'
vgate_assert 01 serial-contains 'goscale: w1 units=25000'
vgate_assert 01 serial-contains 'goscale: w2 units=25000'
vgate_assert 01 serial-contains 'goscale: w3 units=25000'
vgate_assert 01 serial-contains 'goscale: done units=100000'
vgate_assert 01 serial-contains 'goscale: ticks='
# M70b review: the wakes line is the targeting evidence. With one online
# core every wake must be local — remote=0 is the invariant here.
vgate_assert 01 serial-contains 'smp: wakes='
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
wake_lines = [l for l in lines if l.startswith("smp: wakes=")]
if not wake_lines:
    sys.exit("FAIL: no smp: wakes= report line")
for l in wake_lines:
    m = re.search(r"remote=(\d+)", l)
    if not m or int(m.group(1)) != 0:
        sys.exit("FAIL: --cpus 1 must wake remotely 0 times, got %r" % (wake_lines,))
print("wakes lines ok: remote=0 forced with one online core (%d reports)" % len(wake_lines))
PY
vgate_assert 01 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
units = []
for l in lines:
    m = re.match(r"^goscale: w(\d+) units=(\d+)", l)
    if m:
        units.append((int(m.group(1)), int(m.group(2))))
if sorted(w for w, _ in units) != [0, 1, 2, 3]:
    sys.exit("FAIL: expected exactly one units line per worker w0..w3, got %r" % (units,))
total = sum(u for _, u in units)
if total != 100000:
    sys.exit("FAIL: per-worker units sum to %d, expected 100000" % total)
# Periodic `smp: secondary runs=` reports can fuse onto the end of the
# done line (no newline boundary) — parse the units value, not the line.
done = [int(m.group(1)) for l in lines
        if (m := re.match(r"^goscale: done units=(\d+)", l))]
if done != [total]:
    sys.exit("FAIL: done line %r does not equal the summed units %d" % (done, total))
print("units accounting ok: 4 x 25000 = %d, done line matches" % total)
PY

vgate_run 02 -- --cpus 2 --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'goscale: busy m=4' --script-expect 'goscale: ticks=' --timeout 240

vgate_assert 02 serial-contains 'smp: cores=2 online=2'
vgate_assert 02 serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert 02 serial-contains 'goscale: busy m=4'
vgate_assert 02 serial-contains 'goscale: released m=4'
vgate_assert 02 serial-contains 'goscale: w0 units=25000'
vgate_assert 02 serial-contains 'goscale: w1 units=25000'
vgate_assert 02 serial-contains 'goscale: w2 units=25000'
vgate_assert 02 serial-contains 'goscale: w3 units=25000'
vgate_assert 02 serial-contains 'goscale: done units=100000'
vgate_assert 02 serial-contains 'goscale: ticks='
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
units = []
for l in lines:
    m = re.match(r"^goscale: w(\d+) units=(\d+)", l)
    if m:
        units.append((int(m.group(1)), int(m.group(2))))
if sorted(w for w, _ in units) != [0, 1, 2, 3]:
    sys.exit("FAIL: expected exactly one units line per worker w0..w3, got %r" % (units,))
total = sum(u for _, u in units)
if total != 100000:
    sys.exit("FAIL: per-worker units sum to %d, expected 100000" % total)
# Periodic `smp: secondary runs=` reports can fuse onto the end of the
# done line (no newline boundary) — parse the units value, not the line.
done = [int(m.group(1)) for l in lines
        if (m := re.match(r"^goscale: done units=(\d+)", l))]
if done != [total]:
    sys.exit("FAIL: done line %r does not equal the summed units %d" % (done, total))
# The placement proof: the held-window report must show task=GOSCALE.ELF
# on exactly 1 distinct core line, and it must be core 1 — core 0 carries
# the shell (see the PLACEMENT ACCOUNTING note in the header).
cores = [int(m.group(1)) for l in lines
         if (m := re.match(r"^  core (\d+):", l)) and " task=GOSCALE.ELF" in l]
if len(cores) != 1 or cores[0] != 1:
    sys.exit("FAIL: placement needs task=GOSCALE.ELF on exactly core 1 "
             "(core 0 reports task=shell), got cores=%r" % (cores,))
# Targeting evidence: after the exec, some report must have woken a task
# onto the (only) secondary core remotely.
remotes = [int(m.group(1)) for l in lines
           if l.startswith("smp: wakes=") and (m := re.search(r"remote=(\d+)", l))]
if not remotes or max(remotes) < 1:
    sys.exit("FAIL: no smp: wakes= report with remote>=1 after the exec, got %r" % (remotes,))
print("units accounting ok (%d); placement on core %r; max remote wakes %d" % (total, cores[0], max(remotes)))
PY

vgate_run 03 -- --cpus 4 --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'goscale: busy m=4' --script-expect 'goscale: ticks=' --timeout 240

vgate_assert 03 serial-contains 'smp: cores=4 online=4'
vgate_assert 03 serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert 03 serial-contains 'goscale: busy m=4'
vgate_assert 03 serial-contains 'goscale: released m=4'
vgate_assert 03 serial-contains 'goscale: w0 units=25000'
vgate_assert 03 serial-contains 'goscale: w1 units=25000'
vgate_assert 03 serial-contains 'goscale: w2 units=25000'
vgate_assert 03 serial-contains 'goscale: w3 units=25000'
vgate_assert 03 serial-contains 'goscale: done units=100000'
vgate_assert 03 serial-contains 'goscale: ticks='
# Floor only: the drain lines (smp: secondary/steal runs=... task=GOSCALE.ELF)
# also carry the string, so the raw count exceeds the per-core report; the
# exact placement proof is the python block below.
vgate_assert 03 serial-count 'task=GOSCALE.ELF' 4
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
units = []
for l in lines:
    m = re.match(r"^goscale: w(\d+) units=(\d+)", l)
    if m:
        units.append((int(m.group(1)), int(m.group(2))))
if sorted(w for w, _ in units) != [0, 1, 2, 3]:
    sys.exit("FAIL: expected exactly one units line per worker w0..w3, got %r" % (units,))
total = sum(u for _, u in units)
if total != 100000:
    sys.exit("FAIL: per-worker units sum to %d, expected 100000" % total)
# Periodic `smp: secondary runs=` reports can fuse onto the end of the
# done line (no newline boundary) — parse the units value, not the line.
done = [int(m.group(1)) for l in lines
        if (m := re.match(r"^goscale: done units=(\d+)", l))]
if done != [total]:
    sys.exit("FAIL: done line %r does not equal the summed units %d" % (done, total))
# The placement proof: the held-window `smp` report must show
# task=GOSCALE.ELF on AT LEAST 2 DISTINCT NON-ZERO core lines — core 0
# carries the shell (see the PLACEMENT ACCOUNTING note in the header).
# The placement heuristic is racy by design (a stale load read can
# mis-place one wake onto the caller's core), so the gate asserts the
# SPREAD, not the best case: >=2 distinct APs proves distinct Ms ran on
# distinct cores. The `smp: wakes=` remote count is the companion
# targeting evidence.
cores = [int(m.group(1)) for l in lines
         if (m := re.match(r"^  core (\d+):", l)) and " task=GOSCALE.ELF" in l]
if len(set(cores)) < 2 or 0 in cores:
    sys.exit("FAIL: placement needs task=GOSCALE.ELF on >=2 distinct "
             "non-zero core lines (core 0 reports task=shell), got "
             "cores=%r" % (cores,))
remotes = [int(m.group(1)) for l in lines
           if l.startswith("smp: wakes=") and (m := re.search(r"remote=(\d+)", l))]
if not remotes or max(remotes) < 1:
    sys.exit("FAIL: no smp: wakes= report with remote>=1 after the exec, got %r" % (remotes,))
print("units accounting ok (%d); placement on cores %r; max remote wakes %d" % (total, sorted(cores), max(remotes)))
PY
