# go-stress.spec -- M70a2 (#1469, parent #1453): seeded randomized
# GOOS=virelai runtime stress on the compiled default GOMAXPROCS (no env
# pin — numCPUStartup = 2, ADR 0027 D6). Supersedes the #1227 fixed
# four-phase shape.
#
# The fixture (tools/go/gostress.go) runs 4 fixed seeds × 8 iterations;
# each iteration draws shape (gc / chan / timer / futex / mem / churn)
# and parameters from an in-tree splitmix64 seeded by the seed — no
# wall-clock, no host entropy (M70a D1); bounded guest time (D2). Run 02
# replays the first roster seed via argv. pins.txt is the pinned corpus:
# the exact deterministic line sequence per seed. A generator, PRNG or
# roster change regenerates it deliberately in the same PR; a crash on
# any seed fails the run.
#
# Matching is ordered-substring with an advancing cursor, NOT whole-line:
# the runtime writes a line's text and newline as separate writes, and
# the shell idle-loop reporters (smp/timer/userspace) interleave between
# them, so kernel fragments can sit inside a serial line — but never
# inside the program's write itself.
#
# Kernel-effect ties (python over the `syscalls` report): sys_mmap grew
# (the mem phase extends the sbrk break through slot 63); its ceiling is
# the kernel's loud-refusal budget (max_mmap_regions=16) — observed 8 on
# the landed roster, with the region count depending on allocator
# chunking the fixture does not control, so the ceiling enforces the
# budget rather than an allocator invariant. sys_futex ≥ floor (slot-74
# contention); sys_thread ≥ 2 (multi-M runtime, M65c).
#
# M129b (#2611) spawn-storm leg (run 07): at the 512 MiB default the
# 64-slot task pool is the sole concurrency bound — twelve GOSTORM.ELF
# instances each seat six slot-73 children (sys_thread op 0, same seam
# the runtime's newosproc rides) after a 2 s settle window that lets
# every exec'd runtime finish seating its own Ms first, so only children
# absorb the overshoot: the pool saturates at tasks=64/64 with all twelve
# programs still alive, children refuse EAGAIN, and one more exec gets
# the named `error: no free scheduler pool slot`.
#
# HOST PREREQUISITE (not hermetic — see tools/go/README.md):
# `just go-toolchain` must have produced .build/go/GOSTRESS.ELF; run 07
# also needs .build/go/GOSTORM.ELF (bash tools/go/build-storm.sh) and
# COUNTER.BIN.
#
# exec-order: assert-proven -- runs 01/02 are a single exec whose script2
# waits on the kernel's final process-exit report to read its retained
# peak page/region receipt; run 03 (bad argv) ends on
# the program's own FAIL marker. All asserts read the program's lines, so
# a green run always proves it ran.

vgate_name go-stress "M70a2 #1469: seeded GOOS=virelai runtime stress (gc/chan/timer/futex/mem/churn) on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
pages
exec GOSTRESS.ELF
EOF

vgate_file script-seed.txt <<'EOF'
pages
exec GOSTRESS.ELF 0x9e3779b97f4a7c15
EOF

vgate_file script-bad.txt <<'EOF'
exec GOSTRESS.ELF bogus
EOF

vgate_file script2.txt <<'EOF'
pages
procs receipt GOSTRESS.ELF
syscalls
echo gostress-held-window
EOF

# Pinned corpus, 4 seeds × 17 lines (8 iteration markers + 8 phase-ok
# detail lines + 1 seed-ok line), in exact program order. The `procs=`
# line and the closing `done` marker are deliberately NOT in the pin —
# they are asserted separately below. Regenerate with the fixture, never
# by loosening an assert.
vgate_file pins.txt <<'EOF'
go-stress seed=0x9e3779b97f4a7c15 iter=1 phase=timer
go-stress seed=0x9e3779b97f4a7c15 iter=1 phase=timer n=6 maxms=14 ok
go-stress seed=0x9e3779b97f4a7c15 iter=2 phase=futex
go-stress seed=0x9e3779b97f4a7c15 iter=2 phase=futex g=17 iters=34 counter=578 ok
go-stress seed=0x9e3779b97f4a7c15 iter=3 phase=chan
go-stress seed=0x9e3779b97f4a7c15 iter=3 phase=chan fan workers=8 jobs=38 ok
go-stress seed=0x9e3779b97f4a7c15 iter=4 phase=churn
go-stress seed=0x9e3779b97f4a7c15 iter=4 phase=churn g=51 depth=37 ok
go-stress seed=0x9e3779b97f4a7c15 iter=5 phase=mem
go-stress seed=0x9e3779b97f4a7c15 iter=5 phase=mem steps=2 top=512KiB ok
go-stress seed=0x9e3779b97f4a7c15 iter=6 phase=gc
go-stress seed=0x9e3779b97f4a7c15 iter=6 phase=gc allocs=49 live=4 cycles=1 ok
go-stress seed=0x9e3779b97f4a7c15 iter=7 phase=gc
go-stress seed=0x9e3779b97f4a7c15 iter=7 phase=gc allocs=56 live=4 cycles=1 ok
go-stress seed=0x9e3779b97f4a7c15 iter=8 phase=chan
go-stress seed=0x9e3779b97f4a7c15 iter=8 phase=chan chain stages=4 vals=5 ok
go-stress seed=0x9e3779b97f4a7c15 ok
go-stress seed=0xa0761d6478bd642f iter=1 phase=mem
go-stress seed=0xa0761d6478bd642f iter=1 phase=mem steps=3 top=1152KiB ok
go-stress seed=0xa0761d6478bd642f iter=2 phase=gc
go-stress seed=0xa0761d6478bd642f iter=2 phase=gc allocs=58 live=4 cycles=2 ok
go-stress seed=0xa0761d6478bd642f iter=3 phase=churn
go-stress seed=0xa0761d6478bd642f iter=3 phase=churn g=33 depth=19 ok
go-stress seed=0xa0761d6478bd642f iter=4 phase=chan
go-stress seed=0xa0761d6478bd642f iter=4 phase=chan fan workers=8 jobs=29 ok
go-stress seed=0xa0761d6478bd642f iter=5 phase=timer
go-stress seed=0xa0761d6478bd642f iter=5 phase=timer n=5 maxms=14 ok
go-stress seed=0xa0761d6478bd642f iter=6 phase=futex
go-stress seed=0xa0761d6478bd642f iter=6 phase=futex g=24 iters=15 counter=360 ok
go-stress seed=0xa0761d6478bd642f iter=7 phase=futex
go-stress seed=0xa0761d6478bd642f iter=7 phase=futex g=24 iters=40 counter=960 parkwake=1 ok
go-stress seed=0xa0761d6478bd642f iter=8 phase=chan
go-stress seed=0xa0761d6478bd642f iter=8 phase=chan fan workers=6 jobs=18 ok
go-stress seed=0xa0761d6478bd642f ok
go-stress seed=0xe7037ed1a0b428db iter=1 phase=mem
go-stress seed=0xe7037ed1a0b428db iter=1 phase=mem steps=3 top=1152KiB ok
go-stress seed=0xe7037ed1a0b428db iter=2 phase=futex
go-stress seed=0xe7037ed1a0b428db iter=2 phase=futex g=6 iters=31 counter=186 parkwake=1 ok
go-stress seed=0xe7037ed1a0b428db iter=3 phase=chan
go-stress seed=0xe7037ed1a0b428db iter=3 phase=chan fan workers=5 jobs=38 ok
go-stress seed=0xe7037ed1a0b428db iter=4 phase=gc
go-stress seed=0xe7037ed1a0b428db iter=4 phase=gc allocs=48 live=4 cycles=2 ok
go-stress seed=0xe7037ed1a0b428db iter=5 phase=churn
go-stress seed=0xe7037ed1a0b428db iter=5 phase=churn g=43 depth=16 ok
go-stress seed=0xe7037ed1a0b428db iter=6 phase=timer
go-stress seed=0xe7037ed1a0b428db iter=6 phase=timer n=3 maxms=8 ok
go-stress seed=0xe7037ed1a0b428db iter=7 phase=gc
go-stress seed=0xe7037ed1a0b428db iter=7 phase=gc allocs=52 live=3 cycles=2 ok
go-stress seed=0xe7037ed1a0b428db iter=8 phase=mem
go-stress seed=0xe7037ed1a0b428db iter=8 phase=mem steps=2 top=512KiB ok
go-stress seed=0xe7037ed1a0b428db ok
go-stress seed=0xc0ffee iter=1 phase=churn
go-stress seed=0xc0ffee iter=1 phase=churn g=48 depth=7 ok
go-stress seed=0xc0ffee iter=2 phase=gc
go-stress seed=0xc0ffee iter=2 phase=gc allocs=41 live=3 cycles=1 ok
go-stress seed=0xc0ffee iter=3 phase=chan
go-stress seed=0xc0ffee iter=3 phase=chan chain stages=3 vals=5 ok
go-stress seed=0xc0ffee iter=4 phase=futex
go-stress seed=0xc0ffee iter=4 phase=futex g=23 iters=37 counter=851 ok
go-stress seed=0xc0ffee iter=5 phase=timer
go-stress seed=0xc0ffee iter=5 phase=timer n=3 maxms=14 ok
go-stress seed=0xc0ffee iter=6 phase=mem
go-stress seed=0xc0ffee iter=6 phase=mem steps=2 top=768KiB ok
go-stress seed=0xc0ffee iter=7 phase=mem
go-stress seed=0xc0ffee iter=7 phase=mem steps=2 top=1024KiB ok
go-stress seed=0xc0ffee iter=8 phase=futex
go-stress seed=0xc0ffee iter=8 phase=futex g=21 iters=23 counter=483 parkwake=1 ok
go-stress seed=0xc0ffee ok
EOF

vgate_setup_python <<'PY'
import os, shutil, struct, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "GOSTRESS.ELF")
if not os.path.exists(src):
    sys.exit("GOSTRESS.ELF missing (expected " + src + ") - "
             "build the fork binaries first: just go-toolchain "
             "(fork prerequisites in tools/go/README.md)")
shutil.copy(src, os.path.join(share, "GOSTRESS.ELF"))
elf = open(src, "rb").read()
phoff = struct.unpack_from("<Q", elf, 32)[0]
phsize, phnum = struct.unpack_from("<HH", elf, 54)
pages = 0
for i in range(phnum):
    kind, flags, off, va, pa, filesz, memsz, align = struct.unpack_from(
        "<IIQQQQQQ", elf, phoff + i * phsize)
    if kind == 1:
        pages += (memsz + 4095) // 4096
with open(os.path.join(os.environ["RUN_DIR"], "static-pages.txt"), "w") as f:
    f.write(str(pages))
print("staged GOSTRESS.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOSTRESS.ELF")))
PY

# Process exit can precede the last task's reap. Give the idle reaper a turn,
# then require reaped=1 AND exact restoration, never treating exit as reap.
vgate_run 01 -- --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'procs GOSTRESS.ELF exited status=0' --script2-delay 1 --script-expect 'gostress-held-window' --timeout 120

vgate_assert 01 serial-contains 'exec: loaded GOSTRESS.ELF'
vgate_assert 01 serial-contains 'go-stress procs=2'
vgate_assert 01 serial-contains 'go-stress done'
vgate_assert 01 serial-absent 'go-stress FAIL'
vgate_assert 01 serial-absent 'fatal error:'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

vgate_assert 01 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
pins = [l for l in open(os.path.join(os.environ["RUN_DIR"], "pins.txt"))
        .read().splitlines() if l]
pos = 0
for i, want in enumerate(pins):
    idx = ser.find(want, pos)
    if idx < 0:
        sys.exit("FAIL: pin %d/%d missing or out of order:\n  %s"
                 % (i + 1, len(pins), want))
    pos = idx + len(want)
print("go-stress run 01: pinned corpus matched in order (%d lines)" % len(pins))
PY

vgate_file check-receipt.py <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def calls(slot):
    for l in lines:
        m = re.search(r"%d (sys_\w+) calls=(\d+)" % slot, l)
        if m:
            return int(m.group(2))
    return None
n_thread = calls(73)
if n_thread is None:
    sys.exit("FAIL: no sys_thread row in the syscalls report")
if n_thread < 2:
    sys.exit("FAIL: sys_thread calls >= 2 required, got %d" % n_thread)
n_futex = calls(74)
if n_futex is None or n_futex < 50:
    sys.exit("FAIL: sys_futex contention expected (>= 50 calls), got %s" % n_futex)
n_mmap = calls(63)
if n_mmap is None:
    sys.exit("FAIL: no sys_mmap row in the syscalls report")
if n_mmap < 2:
    sys.exit("FAIL: sys_mmap growth expected (>= 2 calls), got %s" % n_mmap)
if n_mmap > 16:
    sys.exit("FAIL: sys_mmap calls %d exceeds the per-process "
             "max_mmap_regions budget (16)" % n_mmap)
print("go-stress python asserts OK: sys_thread=%d sys_futex=%d sys_mmap=%d"
      % (n_thread, n_futex, n_mmap))
receipts = re.findall(
    r"runtime-receipt: pid=(\d+) name=GOSTRESS\.ELF peak_pages=(\d+) "
    r"page_cap=(\d+) peak_regions=(\d+) region_cap=(\d+) static_pages=(\d+) "
    r"page_tracking=extensible page_saturated=(\d+) total_pages=(\d+) "
    r"record_failures=(\d+) unrecorded_pages=(\d+) reaped=(\d+)",
    "\n".join(lines))
if len(receipts) != 1:
    sys.exit("FAIL: expected one final GOSTRESS.ELF runtime receipt")
pid, pages, page_cap, regions, region_cap, static_pages, saturated, total, failures, unrecorded, reaped = map(int, receipts[0])
if not (0 < pages <= total and page_cap == 4096):
    sys.exit("FAIL: peak demand pages %d / total %d / inline cap %d" % (pages, total, page_cap))
# #1958: three patched full-roster boots peaked at 1534/1618/1638 pages;
# replay at 1295/1308/1327, versus 15370/14784 before the padding fix.
# Keep scheduling headroom while refusing a restored alignment-gap sweep.
# This fixture regression bound is not a kernel cap or an engine budget.
if pages > 2048:
    sys.exit("FAIL: GOSTRESS peak demand pages %d exceeds fresh-padding "
             "regression bound 2048 (total allocations %d)" % (pages, total))
if saturated != int(pages >= page_cap) or failures or unrecorded or reaped != 1:
    sys.exit("FAIL: saturation=%d failures=%d unrecorded=%d reaped=%d"
             % (saturated, failures, unrecorded, reaped))
if not (0 < regions <= 16 and region_cap == 16 and regions <= n_mmap):
    sys.exit("FAIL: peak regions %d / cap %d inconsistent with sys_mmap=%d"
             % (regions, region_cap, n_mmap))
expected_static = int(open(os.path.join(os.environ["RUN_DIR"], "static-pages.txt")).read())
if static_pages != expected_static:
    sys.exit("FAIL: static segment pages %d != ELF page-rounded PT_LOAD %d"
             % (static_pages, expected_static))
serial = "\n".join(lines)
if serial.index("procs GOSTRESS.ELF exited status=0") >= serial.index("runtime-receipt:"):
    sys.exit("FAIL: receipt did not follow the final process exit")
counts = [int(n, 16) for n in re.findall(
    r"pages: armed=1 total=0x[0-9a-f]+ free=0x([0-9a-f]+)", serial)]
if len(counts) != 2 or counts[0] != counts[1]:
    sys.exit("FAIL: free pages before exec/after reap must match: %s" % counts)
if serial.index("pages: armed=1") >= serial.index("exec: loaded GOSTRESS.ELF"):
    sys.exit("FAIL: initial page sample did not precede exec")
if serial.rindex("pages: armed=1") <= serial.index("procs GOSTRESS.ELF exited status=0"):
    sys.exit("FAIL: final page sample did not follow final process exit")
print("go-stress free pages restored: %d -> %d" % tuple(counts))
print("go-stress runtime receipt OK: pid=%d peak_pages=%d (inline 4096) "
      "peak_regions=%d/16 static_pages=%d total_pages=%d"
      % (pid, pages, regions, static_pages, total))
PY

vgate_assert 01 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check-receipt.py"))
PY

vgate_run 02 -- --script '$RUN_DIR/script-seed.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'procs GOSTRESS.ELF exited status=0' --script2-delay 1 --script-expect 'gostress-held-window' --timeout 120

vgate_assert 02 serial-contains 'exec: loaded GOSTRESS.ELF'
vgate_assert 02 serial-contains 'go-stress procs=2'
vgate_assert 02 serial-contains 'go-stress done'
vgate_assert 02 serial-absent 'go-stress FAIL'
vgate_assert 02 serial-absent 'fatal error:'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# Same-seed-twice determinism, second boot: the argv replay of seed
# 0x9e3779b97f4a7c15 must reproduce run 01's first 17 pinned lines in
# order (the seed's full sequence).
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
pins = [l for l in open(os.path.join(os.environ["RUN_DIR"], "pins.txt"))
        .read().splitlines() if l]
pos = 0
for i, want in enumerate(pins[:17]):
    idx = ser.find(want, pos)
    if idx < 0:
        sys.exit("FAIL: replay pin %d/17 missing or out of order:\n  %s"
                 % (i + 1, want))
    pos = idx + len(want)
print("go-stress run 02: argv replay reproduced the pinned seed sequence")
PY

vgate_assert 02 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check-receipt.py"))
PY

# Bad-argv path (card-explicit contract): an unparseable seed prints the
# FAIL line and withholds the `done` marker, so a failed seeded run can
# never be mistaken for a clean one — the run's red comes from the
# missing anchor, and here the FAIL line itself ends the boot. The
# fixture's exit status stays 0; the gate reads the lines, not the
# status. No syscalls report needed for this run.
vgate_run 03 -- --script '$RUN_DIR/script-bad.txt' --script-expect 'go-stress FAIL argv=bogus' --timeout 120

vgate_assert 03 serial-contains 'exec: loaded GOSTRESS.ELF'
vgate_assert 03 serial-contains 'go-stress FAIL argv=bogus'
vgate_assert 03 serial-absent 'go-stress done'
vgate_assert 03 serial-absent 'fatal error:'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# M94d: independent boots; the GOSTRESS corpus and assertions above are frozen.
vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name in ("HEAP.ELF", "HEAPFIX.ELF", "HEAPBUDG.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing: bash tools/go/build-heap.sh")
    shutil.copy(src, os.path.join(share, name))
PY

vgate_file script-heap-leak.txt <<'EOF'
exec HEAPFIX.ELF leak
EOF
vgate_file script-heap-clean.txt <<'EOF'
exec HEAPFIX.ELF clean
EOF
vgate_file script-heap-view.txt <<'EOF'
exec HEAP.ELF -p HEAPFIX.ELF --polls 120 --samples 5
EOF

vgate_run 04 -- --script '$RUN_DIR/script-heap-leak.txt' \
    --script2 '$RUN_DIR/script-heap-view.txt' --script2-after 'heapfixture: ready mode=leak' \
    --script-expect 'heap: done app=HEAPFIX.ELF' --timeout 180
vgate_assert 04 serial-contains 'heap: memstats ok'
vgate_assert 04 serial-contains 'heap: leak suspected app=HEAPFIX.ELF'
vgate_assert 04 serial-contains 'heap: done app=HEAPFIX.ELF'
vgate_assert 04 serial-absent 'heap: publisher error'
vgate_assert 04 serial-absent 'fatal error:'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 share-contains 'HEAP/HEAPFIX.ELF.TXT' 'H1 '

vgate_file check-heap.py <<'PY'
import math, os, re, shutil, statistics, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
samples = re.findall(
    r"heap: sample app=HEAPFIX\.ELF pid=(\d+) seq=(\d+) live=(\d+) "
    r"objects=(\d+) mallocs=(\d+) frees=(\d+) num_gc=(\d+) pages=(\d+) peak_pages=(\d+)", ser)
assert len(samples) >= 5, "need samples >= N+2 (5), got " + str(len(samples))
samples = [tuple(map(int, row)) for row in samples]
for pid, seq, live, objects, mallocs, frees, gc, pages, peak in samples:
    assert 0 <= pages <= peak <= 4096, (pages, peak)
    assert live > 0 and objects == mallocs-frees and gc > 0
for before, after in zip(samples, samples[1:]):
    assert after[0] == before[0] and after[1] > before[1] and after[6] > before[6]
costs = [int(n) for n in re.findall(r"snapshot_ns=(\d+)", ser)]
assert costs and all(cost > 0 for cost in costs), "invalid snapshot duration: " + repr(costs)
mean = statistics.mean(costs)
p95 = sorted(costs)[math.ceil(len(costs)*0.95)-1]
# Workload samples are reported, not the owner's >=100-poll quiet window.
# Boot 06 enforces the unchanged 100 us mean/p95 acceptance bound.
print("heap joined series (seq, live bytes, kernel pages):", [(row[1], row[2], row[7]) for row in samples])
print("heap kernel snapshot ns:", costs, "mean:", mean, "p95:", p95, "max:", max(costs))
frequency = int(re.search(r"freq=0x([0-9a-f]+)", ser)[1], 16)
counters = [int(n) for n in re.findall(r"cntpct=(\d+) snapshot_ns=", ser)]
assert frequency > 0 and len(counters) == len(costs)
assert all(b-a >= frequency for a, b in zip(counters, counters[1:])), "more than one poll per second"
publishes = [tuple(map(int, row)) for row in re.findall(r"gc_ns=(\d+) publish_ns=(\d+)", ser)]
assert publishes and all(0 < gc <= total for gc, total in publishes)
print("heap forced-GC/publish ns:", publishes, "counter Hz:", frequency)
path = os.path.join(os.environ["VG_SHARE"], "HEAP", "HEAPFIX.ELF.TXT")
rows = open(path).read().splitlines()
assert 5 <= len(rows) <= 32 and all(len(row) <= 256 for row in rows)
shutil.copy(path, os.path.join("artifacts", "m94d-heapfix-series-" + os.environ["VG_TAG"] + ".txt"))
PY

vgate_assert 04 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check-heap.py"))
PY

vgate_run 05 -- --script '$RUN_DIR/script-heap-clean.txt' \
    --script2 '$RUN_DIR/script-heap-view.txt' --script2-after 'heapfixture: ready mode=clean' \
    --script-expect 'heap: done app=HEAPFIX.ELF' --timeout 180
vgate_assert 05 serial-contains 'heap: memstats ok'
vgate_assert 05 serial-contains 'heap: done app=HEAPFIX.ELF'
vgate_assert 05 serial-absent 'heap: leak suspected'
vgate_assert 05 serial-absent 'heap: publisher error'
vgate_assert 05 serial-absent 'fatal error:'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 share-contains 'HEAP/HEAPFIX.ELF.TXT' 'H1 '
vgate_assert 05 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "check-heap.py"))
PY

# Owner D6 ruling: mean and nearest-rank p95 <= 100 us; max is always reported.
# Run this gate on a quiet host when recording the 100-poll acceptance row.
vgate_file script-heap-budget.txt <<'EOF'
exec HEAPBUDG.ELF
EOF
vgate_run 06 -- --script '$RUN_DIR/script-heap-budget.txt' \
    --script-expect 'heap: budget done polls=100' --timeout 240
vgate_assert 06 serial-contains 'heap: budget done polls=100'
vgate_assert 06 serial-absent 'fatal error:'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 python <<'PY'
import json, math, os, re, statistics
ser = open(os.environ["VG_SER"], errors="replace").read()
rows = [tuple(map(int, row)) for row in re.findall(
    r"heap: budget seq=(\d+) ns=(\d+) cntpct=(\d+) pages=(\d+) peak=(\d+)", ser)]
assert len(rows) == 100 and [row[0] for row in rows] == list(range(1,101)), "need all 100 polls"
costs = [row[1] for row in rows]
assert all(cost > 0 for cost in costs), "no zero/negative or sub-counter-tick claim"
frequency = int(re.search(r"freq=0x([0-9a-f]+)", ser)[1], 16)
assert frequency > 0 and all(b[2]-a[2] >= frequency for a,b in zip(rows, rows[1:]))
assert all(0 <= row[3] <= row[4] for row in rows)
summary = dict(polls=len(rows), mean_ns=statistics.mean(costs),
               p95_ns=sorted(costs)[math.ceil(len(costs)*0.95)-1],
               max_ns=max(costs), counter_hz=frequency)
print("heap 100-poll budget:", summary)
with open(os.path.join("artifacts", "m94d-budget-" + os.environ["VG_TAG"] + ".json"), "w") as f:
    json.dump(summary, f)
assert summary["mean_ns"] <= 100000 and summary["p95_ns"] <= 100000, summary
PY

# ---------------------------------------------------------------------------
# M129b (#2611) run 07: spawn-storm — saturate the 64-slot task pool with
# concurrent slot-73 children and prove the named over-cap refusal.
# ---------------------------------------------------------------------------

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name in ("GOSTORM.ELF",):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing: bash tools/go/build-storm.sh")
    shutil.copy(src, os.path.join(share, name))
# COUNTER.BIN ships in the standard seed share (the kernel build's
# zig-out/bin) — live-m16-resources execs it the same way.
PY

vgate_file script-storm.txt <<'EOF'
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
EOF

# script2 fires on the FIRST `gostorm: up` marker (~10 s post-exec: the
# settle window lets every peer's runtime seat before children spawn);
# the 25 s delay covers the staggered settles (~5.5 s spread) plus the
# retry windows (a full-pool proc retries ~10 s: its 20 ms sleeps land
# on ~1 s tick edges), so all twelve reports precede the read —
# `resources` reads a stable saturated pool and the one-more-exec gets
# the named pool-full refusal by name.
vgate_file script2-storm.txt <<'EOF'
resources
exec COUNTER.BIN
echo storm-pool-full
EOF

vgate_run 07 -- --script '$RUN_DIR/script-storm.txt' \
    --script2 '$RUN_DIR/script2-storm.txt' --script2-after 'gostorm: up spawned=' \
    --script2-delay 25 --script-expect 'storm-pool-full' --timeout 240

vgate_assert 07 serial-count 'exec: loaded GOSTORM.ELF' 12
vgate_assert 07 serial-count 'gostorm: up spawned=' 12
vgate_assert 07 serial-contains 'resources: tasks=64/64'
vgate_assert 07 serial-contains 'error: no free scheduler pool slot'
vgate_assert 07 serial-contains 'storm-pool-full'
vgate_assert 07 serial-absent 'fatal error:'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
ups = re.findall(r"gostorm: up spawned= (\d+)  refused= (\d+)", ser)
if len(ups) != 12:
    sys.exit("FAIL: expected 12 gostorm reports, got %d: %s" % (len(ups), ups))
spawned = sum(int(a) for a, _ in ups)
refused = sum(int(b) for _, b in ups)
if refused == 0:
    sys.exit("FAIL: no slot-73 EAGAIN refusal observed (over-cap spawn "
             "must refuse by name)")
# 12 procs x (runtime Ms + up to 6 children, ≤16-seat thread bound) must
# cover the 61 user slots; saturation is separately asserted by
# `resources: tasks=64/64`.
if spawned == 0:
    sys.exit("FAIL: no slot-73 child task seated")
# The over-cap exec refusal follows the saturated-pool read.
if ser.index("resources: tasks=64/64") >= ser.index("error: no free scheduler pool slot"):
    sys.exit("FAIL: pool-full refusal did not follow the saturated read")
print("go-storm leg OK: 12 procs, spawned=%d slot-73 children, refused=%d (EAGAIN), "
      "tasks=64/64, exec pool_full by name" % (spawned, refused))
PY
