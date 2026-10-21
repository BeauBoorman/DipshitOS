# live-vm-depth.spec -- Milestone 29 (Issue #598, Claim 8247) Class-B gate:
#
# VM Depth: Demand Paging, Copy-on-Write (COW), and Anonymous mmap on real VZ hardware.
#
# Asserts:
#   1. System boots cleanly under VZ on Apple Silicon.
#   2. `exec VMTEST.BIN` loads and executes the M29 test payload at EL0.
#   3. Anonymous `mmap` registers valid user address space regions.
#   4. Translation faults at unmapped addresses trigger on-demand zero-fill page allocation.
#
# Run 02 is the M133d (#2758) acceptance journey: exhaustion + contention
# in ONE boot, K=3 via vgate_repeat — alloc pressure (M133a's EL0EXEC oom
# child), a CPU hog (M133b's SCHEDHOG/SCHEDINT pair on core 1) and a spawn
# storm at the M133c task-pool ceiling (12 x GOSTORM.ELF), all at once.
# Every refusal must be named and the seat still answers a probe.

vgate_name live-vm-depth "Milestone 29 (Issue #598, Claim 8247) Class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

vgate_file script.txt <<'EOF'
exec VMTEST.BIN
EOF

vgate_file script2.txt <<'EOF'
echo rx-vmtest-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "vmtest: all tests passed" --script-expect "rx-vmtest-ok" --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'vmtest: mmap ok'
vgate_assert 01 serial-contains 'vmtest: demand read ok'
vgate_assert 01 serial-contains 'vmtest: demand write ok'
vgate_assert 01 serial-contains 'vmtest: munmap ok'
vgate_assert 01 serial-contains 'vmtest: eager mmap ok'
vgate_assert 01 serial-contains 'vmtest: all tests passed'
vgate_assert 01 serial-contains 'rx-vmtest-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

# ---------------------------------------------------------------------------
# Run 02 — M133d (#2758): exhaustion + contention journey, one boot, K=3.
# All three arc stressors at once:
#   * alloc pressure — the M133a (#2755) child: EL0EXEC.BIN's two oom
#     modes under a 6-page rlimit (ENOMEM named, status-140 mem-limit
#     reap named);
#   * CPU contention — the M133b (#2756) tasks: SCHEDHOG.BIN plus two
#     SCHEDINT.BIN interactives pinned to core 1 (`exec -c1`), burning
#     for the whole window;
#   * spawn storm — the M133c (#2757) ceiling: twelve GOSTORM.ELF
#     instances seating slot-73 children until the 64-slot task pool
#     saturates, over-cap spawns refused EAGAIN by name and one more
#     exec refused `error: no free scheduler pool slot`.
# The OOM pair is typed last in script 1 so it exhausts while the hog
# burns and the twelve storm runtimes are seating — maximum overlap, and
# at ~54 of 64 slots there is still named headroom for both 1-task procs.
# (The first pass exposed a kernel bug this card fixes in syscall.zig:
# `sys_setrlimit` armed the LAST-CREATED process, not the caller's, so an
# `oom` child's limit landed on a GOSTORM that then reaped status=140.)
# script 2 fires on the FIRST `gostorm: up` report then delays past the
# staggered settles and retry windows (the go-stress run-07 margin, +10 s
# for the hog's core-1 share), so `resources` reads the saturated pool
# and every refusal has already printed before the seat probe.
#
# The seat probe: `wm` answered with `wm: none (shim compositing)` — the
# shim seat's own report — plus the closing echo marker, both typed and
# answered while the pool sits at 64/64 and the hog is still burning.
#
# exec-order: assert-proven -- every assert reads program/kernel lines;
# `--script-expect` is the seat's own echo, which only prints when the
# console still answers after saturation.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-storm.sh   -> .build/go/GOSTORM.ELF
# (the pinned go-virelai fork — tools/go/README.md).
# ---------------------------------------------------------------------------

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "GOSTORM.ELF")
if not os.path.exists(src):
    sys.exit("GOSTORM.ELF missing (expected " + src + ") — "
             "build it first: bash tools/go/build-storm.sh")
shutil.copy(src, os.path.join(share, "GOSTORM.ELF"))
print("staged GOSTORM.ELF (%d bytes)" % os.path.getsize(src))
PY

vgate_file m133d.txt <<'EOF'
exec -c1 SCHEDHOG.BIN
exec -c1 SCHEDINT.BIN
exec -c1 SCHEDINT.BIN
exec GOSTORM.ELF 6 0
exec GOSTORM.ELF 6 1
exec GOSTORM.ELF 6 2
exec GOSTORM.ELF 6 3
exec GOSTORM.ELF 6 4
exec GOSTORM.ELF 6 5
exec GOSTORM.ELF 6 6
exec GOSTORM.ELF 6 7
exec GOSTORM.ELF 6 8
exec GOSTORM.ELF 6 9
exec GOSTORM.ELF 6 10
exec GOSTORM.ELF 6 11
exec EL0EXEC.BIN oom
exec EL0EXEC.BIN oom reap
EOF

vgate_file m133d-probe.txt <<'EOF'
resources
smp
exec COUNTER.BIN
wm
echo rx-depth-accept-ok
EOF

vgate_run 02 -- --cpus 2 --script '$RUN_DIR/m133d.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/m133d-probe.txt' --script2-after 'gostorm: up spawned=' \
    --script2-delay 35 --script-expect 'rx-depth-accept-ok' --timeout 300

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
# The M133b contenders: armed, and still beating under storm+hog load.
vgate_assert 02 serial-exact 'schedhog: armed' 1
vgate_assert 02 serial-exact 'schedint: armed' 2
vgate_assert 02 serial-count 'schedint: hb=' 4
# The M133a named OOM under contention: ENOMEM named by the populate
# refusal, the demand-fault refusal named by the mem-limit reap receipt.
vgate_assert 02 serial-contains 'oom: enomem ok'
vgate_assert 02 serial-contains 'EL0EXEC.BIN exited status=140'
vgate_assert 02 serial-absent 'oom: setrlimit failed'
vgate_assert 02 serial-absent 'oom: mmap unexpected'
vgate_assert 02 serial-absent 'oom: reap-miss'
# The M133c storm at the ceiling: twelve drivers, named EAGAIN refusals,
# the saturated read, the named pool-full exec refusal.
vgate_assert 02 serial-count 'exec: loaded GOSTORM.ELF' 12
vgate_assert 02 serial-count 'gostorm: up spawned=' 12
vgate_assert 02 serial-contains 'resources: tasks=64/64'
vgate_assert 02 serial-contains 'error: no free scheduler pool slot'
# The seat still answers a probe at saturation.
vgate_assert 02 serial-contains 'wm: none (shim compositing)'
vgate_assert 02 serial-contains 'rx-depth-accept-ok'
# Nothing dies badly anywhere in the boot.
vgate_assert 02 serial-absent 'fatal error:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# The storm's named refusals: all twelve drivers report, children were
# seated, and the over-cap spawns came back as EAGAIN refusals — never
# deaths, never a wedge.
ups = re.findall(r"gostorm: up spawned= (\d+)  refused= (\d+)", ser)
if len(ups) != 12:
    sys.exit("FAIL: expected 12 gostorm reports, got %d: %s" % (len(ups), ups))
spawned = sum(int(a) for a, _ in ups)
refused = sum(int(b) for _, b in ups)
if spawned == 0:
    sys.exit("FAIL: no slot-73 child task seated")
if refused == 0:
    sys.exit("FAIL: no slot-73 EAGAIN refusal observed (over-cap spawn "
             "must refuse by name)")
# The saturated read precedes the named pool-full exec refusal.
if ser.index("resources: tasks=64/64") >= ser.index("error: no free scheduler pool slot"):
    sys.exit("FAIL: pool-full refusal did not follow the saturated read")
# Contention is real, not staged: the post-saturation `smp` snapshot
# shows the hog and both interactives accumulating ticks on the contested
# core while the storm holds the pool.
rows = re.findall(r"smp: run task=(\d+) name=(\S+) ticks=(\d+)", ser)
hog = [int(t) for _, n, t in rows if n == "SCHEDHOG.BIN"]
ints = [int(t) for _, n, t in rows if n == "SCHEDINT.BIN"]
if not hog or hog[-1] <= 0:
    sys.exit("FAIL: hog never ran on the contested core: %s" % hog)
if len(ints) < 2 or ints[-1] <= 0:
    sys.exit("FAIL: interactives not both running under load: %s" % ints)
# The seat probe lands after the last named refusal: the shim seat's own
# answer arrives while the pool is saturated.
if ser.index("wm: none (shim compositing)") <= ser.index("error: no free scheduler pool slot"):
    sys.exit("FAIL: seat probe answered before the pool-full refusal")
print("m133d journey OK: spawned=%d refused=%d (EAGAIN), tasks=64/64, "
      "hog ticks=%d int ticks=%d, seat answered" % (spawned, refused, hog[-1], ints[-1]))
PY
