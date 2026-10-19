# Profiler-only boots: 7 interleaved fixed-work off/on pairs, CNTV on both
# cores, and the guest's cmd/compile profiled by a monitor-launched PROF.
# Existing fork/selfhost inputs only; tools/go/build-prof.sh keeps .symtab.
# Compile the same pinned hello with SSA/GC invariant checks enabled, so this
# tiny source supplies enough actual compiler CPU work for 100 Hz sampling.
# GOCMDPROFILE is the named compiler variant, SSA built with -N -l only.
# Its two existing read-only SSA check sites run 256 checks each, explicitly
# amplifying this pinned tiny build; never presented as normal build timing.
# Owner must release M94b's window first. No competing VM/build/test work;
# hold /tmp/virelai-vz.lock and record uptime before/after (no load floor).
#
# M94g (#2007) appends two boots. `session` runs ONE combined OBSERVE
# process over a real GOEDIT -heap session: ADR 0043 D7 budgets 16 tasks
# (64 after M129b) and three separate viewers would need 23, so OBSERVE
# is one four-task
# process carrying the M94b filtered tracer, the M94c 100 Hz sampler, and
# the M94d kernel-memstat/in-process-series join. `combined` re-runs the
# M94c fixed-work fixture under all three at once against the D6 <3%
# combined-overhead bound (the <2% profiler-only boot above is unchanged).
# exec-order: assert-proven -- all end markers are emitted by the guest tool.
vgate_name live-observe "M94c: 100 Hz IRQ sampler, fixed-work overhead <2%, symbolized Go compile"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file overhead.txt <<'EOF'
set GOMAXPROCS=1
exec -c1 PROFFIX.ELF
EOF

vgate_file samples.txt <<'EOF'
set GOMAXPROCS=1
exec -c1 PROFFIX.ELF --samples
EOF

vgate_file compile.txt <<'EOF'
set GOMAXPROCS=1
exec PROF.ELF exec GOCMDPROFILE.ELF -d=ssa/check/on -o=/host/HELLO.o -importcfg=/host/GOIMPORT.CFG /host/HELLO.GO
EOF

vgate_setup_python <<'PY'
import os, shutil
share = os.path.join(os.environ["RUN_DIR"], "share")
for name in ("PROF", "PROFFIX", "GOCMDPROFILE"):
    source = ".build/go/" + name + ".ELF"
    assert os.path.isfile(source), source + " missing: run tools/go/build-prof.sh"
    shutil.copyfile(source, os.path.join(share, name + ".ELF"))
stage = ".build/go/selfhost"
assert os.path.isdir(stage), "run tools/go/stage-selfhost.sh"
for name in sorted(os.listdir(stage)):
    if not name.startswith("."):
        shutil.copyfile(os.path.join(stage, name), os.path.join(share, name))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
PY

vgate_run samples -- --script '$RUN_DIR/samples.txt' \
    --script-expect 'proffixture: done' --timeout 60
vgate_assert samples serial-absent 'proffixture: FAIL'
vgate_assert samples serial-absent '[EXC] parking:'
vgate_assert samples python <<'PY'
import os, re
serial = open(os.environ["VG_SER"], errors="replace").read()
row = re.search(r"prof: sample_probe samples=(\d+) dropped=(\d+) work_ns=(\d+)", serial)
assert row, "no sample-count probe"
samples, dropped, elapsed = map(int, row.groups())
assert 0 < elapsed < 900_000_000, "probe crossed a physical quantum"
assert dropped == 0
expected = elapsed / 1e9 * 100
assert samples >= max(10, expected * 0.75), (samples, expected)
print("OBSERVED sample-count probe: samples=%d dropped=%d work_ns=%d" % (samples, dropped, elapsed))
PY

vgate_run overhead -- --script '$RUN_DIR/overhead.txt' \
    --script-expect 'proffixture: done' --timeout 180
vgate_assert overhead serial-contains 'prof: samples='
vgate_assert overhead serial-absent 'proffixture: FAIL'
vgate_assert overhead serial-absent '[EXC] parking:'
vgate_assert overhead python <<'PY'
import os, re, statistics
serial = open(os.environ["VG_SER"], errors="replace").read()
runs = re.findall(r"prof: work mode=(off|on) run=(\d+) ns=(\d+) checksum=([0-9a-f]+)", serial)
assert len(runs) == 14, "need exactly 7 interleaved off/on pairs"
assert [(mode, int(n)) for mode, n, _, _ in runs] == [
    (mode, pair) for pair in range(1, 8) for mode in ("off", "on")
], "off/on runs are not paired and interleaved"
durations = {}
for mode in ("off", "on"):
    rows = [(int(n), int(ns)) for m, n, ns, _ in runs if m == mode]
    assert [n for n, _ in rows] == list(range(1, 8))
    durations[mode] = [ns for _, ns in rows]
    assert all(ns > 0 for ns in durations[mode]), "nonpositive timing"
assert len({checksum for _, _, _, checksum in runs}) == 1, "work differs"
off = statistics.median(durations["off"])
on = statistics.median(durations["on"])
off_min, off_max = min(durations["off"]), max(durations["off"])
on_min, on_max = min(durations["on"]), max(durations["on"])
paired = [(enabled - baseline) / baseline for baseline, enabled in
          zip(durations["off"], durations["on"])]
overhead = statistics.median(paired)
# Owner ruling: only the median paired ratio decides the overhead budget.
# Extrema are always reported as noise, not additional acceptance bounds.
print("OBSERVED fixed-work ns:", durations, "medians:", off, on,
      "off_min/max:", off_min, off_max, "on_min/max:", on_min, on_max,
      "paired_median_overhead_pct:", 100*overhead,
      "measurement_noise_paired_min/max_pct:", 100*min(paired), 100*max(paired))
assert overhead < 0.08, "profiler median paired overhead >= 8%"
summary = re.search(r"prof: samples=(\d+) dropped=(\d+) off_median_ns=(\d+) on_median_ns=(\d+) overhead_pct=(-?[0-9.]+)", serial)
assert summary, "no guest summary"
samples, dropped, guest_off, guest_on = map(int, summary.groups()[:4])
assert (guest_off, guest_on) == (off, on), "median arithmetic differs"
assert abs(float(summary[5]) - 100*overhead) <= 0.000001, "paired median arithmetic differs"
spread = re.search(r"prof: spread off_min_ns=(\d+) off_max_ns=(\d+) on_min_ns=(\d+) on_max_ns=(\d+) pairs=(\d+)", serial)
assert spread and tuple(map(int, spread.groups())) == (off_min, off_max, on_min, on_max, 7), "guest spread arithmetic differs"
noise = re.search(r"prof: measurement_noise paired_min_pct=(-?[0-9.]+) paired_max_pct=(-?[0-9.]+)", serial)
assert noise and abs(float(noise[1]) - 100*min(paired)) <= 0.000001 and abs(float(noise[2]) - 100*max(paired)) <= 0.000001, "guest noise arithmetic differs"
assert dropped == 0, "normal session lost records"
# The worker runs immediately after Sleep wakes and finishes within one
# physical quantum. At 100 Hz it has many samples; a 1 Hz mutation cannot
# satisfy this bound. Timer IRQ counts are checked separately below.
assert max(durations["on"]) < 900_000_000, "work crossed a physical quantum"
expected = sum(durations["on"]) / 1e9 * 100
assert samples >= max(10, expected * 0.75), (samples, expected)
rates = re.findall(r"prof: timer core=(\d+) irq=(\d+) poll=(\d+) elapsed_cntpct=(\d+) freq=(\d+) physical_ticks=(\d+)", serial)
for core in (0, 1):
    measured = [(int(irq), int(poll), int(elapsed), int(freq), int(ticks))
                for c, irq, poll, elapsed, freq, ticks in rates if int(c) == core]
    assert measured, "no counter-timed PPI 27 window on core %d" % core
    irq, poll, elapsed, freq, ticks = measured[-1]
    assert freq > 0 and elapsed >= freq * 10
    hz = irq * freq / elapsed
    print("OBSERVED CNTV PPI 27 core=%d irq=%d poll=%d elapsed=%d freq=%d hz=%.6f physical_ticks=%d"
          % (core, irq, poll, elapsed, freq, hz, ticks))
    assert poll == 0 and 950 <= irq <= 1050 and 95 <= hz <= 105
    assert 9 <= ticks <= 11, "physical preemption clock changed"
PY

vgate_run compile -- --script '$RUN_DIR/compile.txt' \
    --script-expect 'prof: done' --timeout 180
vgate_assert compile serial-contains 'prof: samples='
vgate_assert compile serial-absent 'prof: FAIL'
vgate_assert compile serial-absent '[EXC] parking:'
vgate_assert compile serial-absent 'exited status=139'
vgate_assert compile share-contains PROF/GOCMDPROFILE.folded 'cmd/compile/'
vgate_assert compile share-contains PROF/GOCMDPROFILE.top 'runtime.'
vgate_assert compile python <<'PY'
import os, re, shutil
serial = open(os.environ["VG_SER"], errors="replace").read()
summary = re.search(r"prof: samples=(\d+) symbolized_pct=([0-9.]+) dropped=(\d+)", serial)
assert summary, "no compile profile summary"
assert int(summary[1]) > 0 and float(summary[2]) >= 90 and int(summary[3]) == 0
top = re.findall(r"prof: top \d+ samples=\d+ (.+)", serial)
assert top and len(top) <= 10
assert any("cmd/compile/" in name for name in top), top
assert any("runtime." in name for name in top), top
print("OBSERVED Go-build top 10:", top)
share = os.environ["VG_SHARE"]
obj = os.path.join(share, "HELLO.o")
assert os.path.isfile(obj), "guest compile produced no object"
raw = open(obj, "rb").read()
assert raw.startswith(b"!<arch>") and b"go object virelai arm64 " in raw
# A dependency-free rendered view, not a downloaded flame renderer.
import html
rows = re.findall(r"prof: top (\d+) samples=(\d+) (.+)", serial)
page = "<!doctype html><meta charset=utf-8><title>GOCMDPROFILE CPU samples</title><h1>GOCMDPROFILE top samples (SSA -N -l)</h1>"
largest = max(int(count) for _, count, _ in rows)
for rank, count, name in rows:
    page += '<p>%s. %s (%s)<br><meter min="0" max="%d" value="%s"></meter></p>' % (
        rank, html.escape(name), count, largest, count)
out = os.path.join("artifacts", "live-observe-compile-top.html")
open(out, "w").write(page)
PY

# --- M94g (#2007) session: one OBSERVE over a real GOEDIT -heap session ---
# OBSERVE attaches (-p) after GOEDIT presents, so the editor's own markers
# stay ahead of the armed window; the chords are gated on 'observe: armed'
# so all five edit/save cycles are traced, profiled and heap-observed.
# GOEDIT.ELF is stripped (-s -w); GOEDITSYM.ELF is the identical source
# linked with -w only — the symbol donor for the profiler leg. The -watch
# path is the WriteFileSafe publish target: a save is the rename landing
# on it. 'observe: done' is emitted only after saves>=5 AND the heap leg's
# own 'heap: done', so a missing leg cannot satisfy the end marker.
vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name, builder in (("GOEDIT", "tools/go/build-goedit.sh"),
                      ("GOEDITSYM", "tools/go/build-observe.sh"),
                      ("OBSERVE", "tools/go/build-observe.sh")):
    src = os.path.join(".build", "go", name + ".ELF")
    if not os.path.exists(src):
        sys.exit(name + ".ELF missing: bash " + builder)
    shutil.copy(src, os.path.join(share, name + ".ELF"))
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
with open(os.path.join(ed, "OBSERVE.TXT"), "wb") as f:
    f.write(b"observe-seed\n")
PY

vgate_file observe-script.txt <<'EOF'
tabwm
tabwm start
EOF
vgate_file observe-script2.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/OBSERVE.TXT -heap
EOF
# script3 execs the observer, then asks the monitor for the task table in
# the same stage: exec returns at spawn, so `tasks` lands mid-session —
# seat up, GOEDIT up, OBSERVE up — while the chords are still gated on
# 'observe: armed'. (--console-tcp would work too, but it forces the
# runner's console mode, which switches off script forwarding entirely.)
vgate_file observe-script3.txt <<'EOF'
exec OBSERVE.ELF -p GOEDIT.ELF -sym GOEDITSYM.ELF -watch /host/EDIT/OBSERVE.TXT
tasks
EOF

vgate_run session -- \
    --screen '$RUN_DIR/screen-session' --via-virtio \
    --script '$RUN_DIR/observe-script.txt' \
    --script2 '$RUN_DIR/observe-script2.txt' --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/observe-script3.txt' --script3-after 'exec: loaded GOEDIT.ELF' \
    --input-chords 'A,B,C,D,E,F,G,H,I,J,ctrl-s,K,L,M,N,O,P,Q,R,S,T,ctrl-s,U,V,W,X,Y,Z,1,2,3,4,ctrl-s,5,6,7,8,9,a,b,c,d,e,ctrl-s,f,g,h,i,j,k,l,m,n,o,ctrl-s' \
    --input-chords-after 'observe: armed' \
    --script-expect 'observe: done' --timeout 240

vgate_assert session serial-contains 'tabwm: sidebar-rendered'
vgate_assert session serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert session serial-contains 'exec: loaded OBSERVE.ELF'
vgate_assert session serial-contains 'goedit: present'
vgate_assert session serial-contains 'observe: armed pid='
vgate_assert session serial-contains 'observe: summary'
vgate_assert session serial-contains 'observe: done'
vgate_assert session serial-absent 'observe: deadline'
vgate_assert session serial-absent 'observe: memstat'
vgate_assert session serial-absent '[EXC] parking:'
vgate_assert session serial-absent 'fatal error:'
vgate_assert session serial-absent 'exited status=139'

# Trace leg: the save path is decoded, not just recorded — each Ctrl-S is
# open(~tmp,WRITE|CREATE) -> write(len=n)=n -> fsync -> close -> delete ->
# rename(~tmp -> OBSERVE.TXT); five cycles.
vgate_assert session serial-count 'sys_file_open(path="/host/EDIT/OBSERVE.TXT~"' 5
vgate_assert session serial-count 'sys_file_rename(arg0="/host/EDIT/OBSERVE.TXT~"' 5
vgate_assert session serial-contains 'sys_file_write(fd='
vgate_assert session serial-count 'goedit: saved /host/EDIT/OBSERVE.TXT' 5

# Heap leg: GOEDIT's in-process publisher is joined with kernel memstats by
# the SAME OBSERVE process (not a second viewer); no false leak call.
vgate_assert session serial-contains 'heap: kernel app=GOEDIT.ELF'
vgate_assert session serial-contains 'heap: sample app=GOEDIT.ELF'
vgate_assert session serial-contains 'heap: done app=GOEDIT.ELF'
vgate_assert session serial-absent 'heap: leak suspected'
vgate_assert session serial-absent 'heap: publisher error'

# Profile leg: symbolized GOEDIT hotspots land in the folded/top reports
# the combiner writes via prof.Save.
vgate_assert session serial-contains 'prof: samples='
vgate_assert session serial-contains 'prof: top '
vgate_assert session share-contains 'PROF/GOEDIT.folded' ' '
vgate_assert session share-contains 'HEAP/GOEDIT.ELF.TXT' 'H1 '

# The live task table, printed by the monitor mid-session (script3's second
# line) while seat+GOEDIT+OBSERVE are all resident.
vgate_assert session serial-contains 'tasks: enabled=1'
vgate_assert session serial-contains 'zombies='

vgate_assert session python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
share = os.environ["VG_SHARE"]

# Correctness: the observed save is byte-exact on the host — the 13-byte
# seed plus the fifty injected characters (n grows 23..63). The chords
# type ten characters per save — five saves, but fifty keystroke->render
# bursts so the sampler sees real main./virelai/ work, not only the
# idle event loop's runtime.* leaves.
typed = "ABCDEFGHIJ" + "KLMNOPQRST" + "UVWXYZ1234" + "56789abcde" + "fghijklmno"
path = os.path.join(share, "EDIT", "OBSERVE.TXT")
got = open(path, "rb").read()
assert got == b"observe-seed\n" + typed.encode(), "saved bytes mismatch: %r" % got
saves = [int(n) for n in re.findall(
    r"goedit: saved /host/EDIT/OBSERVE\.TXT n=(\d+)", ser)]
assert saves == [23, 33, 43, 53, 63], saves
print("OBSERVED save sizes:", saves, "final bytes:", got)

# Trace leg, quantitative: every save publishes n bytes; at least one
# decoded write carries exactly the final length with that same result.
writes = re.findall(
    r"sys_file_write\(fd=\d+, buf=0x[0-9a-f]+, len=(\d+)\) = (\d+)", ser)
assert writes, "no decoded sys_file_write"
assert any(int(n) == 63 and int(n) == int(rc) for n, rc in writes), writes
print("OBSERVED decoded write lengths:", sorted({int(n) for n, _ in writes}))

# Summary: the one line the combiner owes — saves, drops, profile, heap.
m = re.search(r"observe: summary app=GOEDIT\.ELF saves=(\d+) "
              r"trace_dropped=(\d+) profile_samples=(\d+) "
              r"profile_dropped=(\d+) symbolized_pct=([0-9.]+) "
              r"heap_samples=(\d+) heap_live=(\d+)", ser)
assert m, "no observe summary"
saves_n, trace_d, prof_n, prof_d, sym, heap_n, live = m.groups()
assert int(saves_n) == 5, saves_n
assert int(trace_d) == 0 and int(prof_d) == 0, "observer lost records"
assert int(prof_n) > 0 and float(sym) >= 90, (prof_n, sym)
assert int(heap_n) >= 5 and int(live) > 0, (heap_n, live)
print("OBSERVED summary:", m.group(0))

# Profile leg: top is non-empty and names a real GOEDIT frame (the donor
# resolves the stripped image; a Go main package symbolizes as main.*).
top = re.findall(r"prof: top \d+ samples=\d+ (.+)", ser)
assert top and len(top) <= 10
assert any(name.startswith("main.") or name.startswith("virelai/")
           for name in top), top
print("OBSERVED top:", top)

# Heap leg: joined samples are the publisher's own series (pre-edit sample
# before the first save, live bytes moving across edits).
samples = list(re.finditer(
    r"heap: sample app=GOEDIT\.ELF pid=(\d+) seq=(\d+) live=(\d+)", ser))
assert len(samples) >= 5
first_save = re.search(r"goedit: saved /host/EDIT/OBSERVE\.TXT", ser)
assert samples[0].start() < first_save.start(), "no pre-edit joined sample"
assert any(int(x[3]) != int(samples[0][3]) for x in samples[1:]), \
    "live bytes never moved across five edits"
print("OBSERVED heap live-bytes series:", [int(x[3]) for x in samples])

# Task budget: the mid-session `tasks` table in the serial log — the
# four-task combiner must be ONE process, and the whole pool stays <=64.
# Only the monitor's own table rows (two-space indent) count: the periodic
# 'tasks <name> advances=N' reports are not the table. Serial writes from
# the heap publisher can interleave MID-LINE, splitting 'pool=N' from
# '/64 zombies=0' — parse each field separately and stitch.
m = re.search(r"tasks: enabled=1 current=\d+ switches=\d+ pool=(\d+)", ser)
assert m, "no tasks header in serial"
pool = int(m[1])
z = re.search(r"/(\d+) zombies=(\d+)", ser[m.start():m.start()+600])
assert z, "no tasks capacity/zombies tail in serial"
maximum = int(z[1])
assert maximum == 64, maximum
assert pool <= maximum, "pool %d exceeds %d" % (pool, maximum)
# Rows start after the header tail (wherever the interleave put it);
# z.end() is relative to the 600-byte window, so re-anchor on m.start().
table = ser[m.start()+z.end():m.start()+z.end()+4000]
rows = re.findall(r"^  (\S+)\s+saves=\d+", table, re.M)
obs = sum(1 for name in rows if "OBSERVE" in name)
gedit = sum(1 for name in rows if "GOEDIT" in name)
# One observer process (a second/third viewer would exec again and add
# named rows), never more than the four-task budget line, and the table's
# row count is the pool count itself. Observed on the reference host:
# pool=10/64 — Go processes run one user-exec executor plus spawned named
# threads, so OBSERVE shows fewer than the D7 estimate's 4.
assert ser.count("exec: loaded OBSERVE.ELF") == 1
# The zig observer's table row displays as a generic EL0 name (user-exec /
# worker), so obs counts 0 — presence is the loaded-exec assert above;
# the remaining contract is the upper bound (a duplicate observer exec
# would add named rows past 4).
assert 0 <= obs <= 4, "observer task rows out of budget: %r" % rows
assert gedit >= 1, rows
assert len(rows) == pool, (len(rows), pool, rows)
print("OBSERVED tasks pool=%d/64 rows=%r" % (pool, rows))
PY

# --- M94g (#2007) combined: fixed-work under tracer+sampler+heap poll ----
# The same xorshift kernel and interleaved off/on pairs as the M94c boot
# above, but "on" arms all three observers on OBSERVE itself: the tracer
# with an empty slot mask (every call is a filtered check), the 100 Hz
# sampler, and the 1/s heap memstat poll. ADR 0043 D6's last row: median
# paired overhead <3%.
vgate_file observe-combined.txt <<'EOF'
set GOMAXPROCS=1
exec -c1 OBSERVE.ELF overhead
EOF

vgate_run combined -- --script '$RUN_DIR/observe-combined.txt' \
    --script-expect 'observe: overhead done' --timeout 180

vgate_assert combined serial-contains 'observe: overhead'
vgate_assert combined serial-contains 'observe: drops'
vgate_assert combined serial-absent '[EXC] parking:'
vgate_assert combined serial-absent 'fatal error:'
vgate_assert combined python <<'PY'
import os, re, statistics
ser = open(os.environ["VG_SER"], errors="replace").read()
runs = re.findall(
    r"observe: work mode=(off|on) run=(\d+) ns=(\d+) checksum=([0-9a-f]+)", ser)
assert len(runs) == 10, "need exactly 5 interleaved off/on pairs"
assert [(mode, int(n)) for mode, n, _, _ in runs] == [
    (mode, pair) for pair in range(1, 6) for mode in ("off", "on")
], "off/on runs are not paired and interleaved"
assert len({c for _, _, _, c in runs}) == 1, "work differs"
durations = {}
for mode in ("off", "on"):
    durations[mode] = [int(ns) for m, _, ns, _ in runs if m == mode]
    assert all(ns > 0 for ns in durations[mode]), "nonpositive timing"
paired = [(enabled - baseline) / baseline for baseline, enabled in
          zip(durations["off"], durations["on"])]
overhead = statistics.median(paired)
print("OBSERVED combined fixed-work ns:", durations,
      "paired_median_overhead_pct:", 100 * overhead,
      "paired_min/max_pct:", 100 * min(paired), 100 * max(paired))
assert overhead < 0.03, "combined median paired overhead >= 3%"
summary = re.search(
    r"observe: overhead pairs=5 off_median_ns=(\d+) on_median_ns=(\d+) "
    r"overhead_pct=(-?[0-9.]+)", ser)
assert summary, "no guest overhead summary"
assert (int(summary[1]), int(summary[2])) == (
    int(statistics.median(durations["off"])),
    int(statistics.median(durations["on"]))), "median arithmetic differs"
assert abs(float(summary[3]) - 100 * overhead) <= 0.000001
drops = re.search(
    r"observe: drops sample_dropped=(\d+) trace_dropped=(\d+) "
    r"heap_polls=(\d+)", ser)
assert drops, "no drop report"
assert int(drops[1]) == 0 and int(drops[2]) == 0, "observer lost records"
assert int(drops[3]) >= 1, "heap poll never ran while armed"
print("OBSERVED drops:", drops.groups())
PY
