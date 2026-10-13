# go-top.spec -- M71g (issue #1566) class-B gate: GOTOP.ELF lists a live
# process, kills it with `k`, and closes -- full-viewport inside Zig TABWM.
#
# user/go/top is a tabapp client: init -> declare (kind-8 WM_RPC) -> sys_procs
# (slot 7) -> paint -> `k` arms the selected pid through sys_kill (slot 29) ->
# the kernel converts it into the reserved status 137 -> window close.
#
# The card's D2 is "kill is the live proof, not a pretty chart", so this spec
# proves the kill against a process it first listed by NAME (the pid is read
# out of GOTOP's own row line, not pinned, so the boot's pid allocation stays
# free to move). GOTOP.ELF is the successor to Zig TOP.BIN and SYSMON.BIN, both
# deleted by this card; it keeps TOP's `top:` marker vocabulary and its
# 40,40 512x384 declaration, so the retargeted live-* specs moved by binary
# name.
#
# exec-order: assert-proven -- the run ends on `rx-gotop-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the
# kernel's own `tasks user-exec exited status=137` (the kill's consequence),
# so a boot in which the kill never landed cannot reach the echo.
#
# Run 02 (issue #2197) is the filter leg: TOP.BIN's retired text filter is
# back on the Go kit's widgets.TextInput. `/` opens the field, typed text
# live-narrows the table (the row dump then shows only matching names), Enter
# commits it, `/` reopens the committed text and Escape clears it -- the full
# list returns. The leg fails before the widget exists: none of its `top:
# filter*` markers are ever printed.
#
# Run 03 (issue #2198) is the real-figures leg: GOSCALE.ELF's four spinning
# workers saturate the cores for a ~6 s window, so a GOTOP snapshot taken
# after `goscale: released` MUST show that pid's cpu_ticks > 0 — under the
# pre-0047 kernel the `top: usage` marker and the cpu=/mem= row fields do not
# exist at all, so every assert below fails before this card. GOSCALE is the
# honest fixture: it holds real runnable Ms instead of parking between
# yields, which is exactly what tick-attributed accounting measures.
#
# Run 04 is the PULSE half: PULSE.ELF's negotiated read prints
# `pulse: usage cpux10= memused= memtotal=` right after `pulse: ready` when
# the v2 rows arrived — absent on a v1 kernel — and a `2` chord repaints the
# Processes tab with real CPU%/MEM columns over the same busy guest.
#
# The old-row decode leg is pinned on the host, not here: a v2 kernel always
# answers a tagged request with v2 rows, so "v1 stream decodes correctly"
# is `go test ./vi ./top` (TestProcsV2OldKernel, TestUsageGoneOnV1) plus the
# kernel-side byte-frozen snapshot test.
#
# HOST PREREQUISITES (fail the gate honestly when missing):
#   bash tools/go/build-gotop.sh                    -> .build/go/GOTOP.ELF
#   bash tools/go/build-go.sh tools/go/smpscale.go  -> .build/go/GOSCALE.ELF
#   bash tools/go/build-pulse.sh                    -> .build/go/PULSE.ELF

vgate_name go-top "issue #1566 M71g: GOTOP.ELF lists a live pid and kills it in Zig TABWM on VZ; #2197: `/` filter leg"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec COUNTER.BIN
exec GOTOP.ELF
EOF

# The close is driven from the harness only AFTER the kernel has reported the
# killed process's exit, so both the kill and its consequence are on the serial
# log before the window goes away. `procs` is the kernel's OWN table read-back:
# the killed pid must show exited/137 there, which is what makes the kill more
# than a marker.
vgate_file script3.txt <<'EOF'
procs
dui close 2
echo rx-gotop-ok
EOF

# Run 02's close rides on the filter's own last marker: the clear is on the
# serial log before the window goes away.
vgate_file script3f.txt <<'EOF'
dui close 2
echo rx-gotop-filter-ok
EOF

# Run 03's busy fixture + GOTOP launch: the exec waits on `goscale: busy m=4`
# so both snapshots land inside the ~6 s spin window — the workers' pids have
# real per-core tick charges by then, while the process row is still live.
vgate_file script2u.txt <<'EOF'
exec GOSCALE.ELF
EOF

vgate_file script3u.txt <<'EOF'
exec GOTOP.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTOP.ELF")
if not os.path.exists(src):
    sys.exit("GOTOP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotop.sh")
shutil.copy(src, os.path.join(share, "GOTOP.ELF"))
print("staged GOTOP.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOTOP.ELF")))
gsrc = os.path.join(".build", "go", "GOSCALE.ELF")
if not os.path.exists(gsrc):
    sys.exit("GOSCALE.ELF missing (expected " + gsrc + ") - build it first: "
             "bash tools/go/build-go.sh tools/go/smpscale.go")
shutil.copy(gsrc, os.path.join(share, "GOSCALE.ELF"))
print("staged GOSCALE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOSCALE.ELF")))
psrc = os.path.join(".build", "go", "PULSE.ELF")
if not os.path.exists(psrc):
    sys.exit("PULSE.ELF missing (expected " + psrc + ") - build it first: "
             "bash tools/go/build-pulse.sh")
shutil.copy(psrc, os.path.join(share, "PULSE.ELF"))
print("staged PULSE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "PULSE.ELF")))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'tasks user-exec exited status=137' \
    --script-expect 'rx-gotop-ok' --timeout 150

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 01 serial-contains 'top: open id='
vgate_assert 01 serial-contains 'top: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'top: procs n='
vgate_assert 01 serial-contains 'name=COUNTER.BIN state=running'
vgate_assert 01 serial-contains 'top: kill pid='
vgate_assert 01 serial-contains 'tasks user-exec exited status=137'
vgate_assert 01 serial-contains 'top: refreshed ok'
vgate_assert 01 serial-contains 'top: win_close'
vgate_assert 01 serial-contains 'top: exiting 43'
vgate_assert 01 serial-contains 'rx-gotop-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

# The kill is real: the pid GOTOP ARMED is the pid its own listing showed for
# COUNTER.BIN, the listing came first, and the counter stops afterwards.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
listed = next((i for i, l in enumerate(lines)
               if l.startswith("top: row pid=") and "name=COUNTER.BIN state=running" in l), None)
if listed is None:
    sys.exit("FAIL: GOTOP never listed COUNTER.BIN as a running row")
m = re.search(r"top: row pid=(\d+) name=COUNTER\.BIN state=running", lines[listed])
pid = m.group(1)
killed = next((i for i, l in enumerate(lines) if l.strip() == "top: kill pid=" + pid), None)
if killed is None:
    cands = [repr(l) for l in lines if "top: kill" in l]
    sys.exit("FAIL: no exact `top: kill pid=%s` for the listed COUNTER.BIN row; saw: %s"
             % (pid, "; ".join(cands) or "nothing"))
if killed < listed:
    sys.exit("FAIL: the kill preceded the listing it names")
# SMP caveat (observed 2026-10-12): sys_kill only ARMS the task — the
# kill_pending flag converts to status 137 at the counter's next resume — so
# a counter mid-quantum on another core can land ONE more `counter: alive`
# between the arm marker and its exit report. The hard invariant is zero
# markers after the kernel's own `exited status=137`: a dead task cannot
# print.
exit_line = next((i for i, l in enumerate(lines)
                  if i > killed and "exited status=137" in l), None)
if exit_line is None:
    sys.exit("FAIL: no exit report follows the kill marker")
after = sum(1 for l in lines[exit_line + 1:] if "counter: alive" in l)
if after != 0:
    sys.exit("FAIL: the killed process produced %d markers after its exit report" % after)
inflight = sum(1 for l in lines[killed + 1:exit_line] if "counter: alive" in l)
if inflight > 1:
    sys.exit("FAIL: %d markers between arm and exit — at most one in-flight "
             "tick is explainable" % inflight)
if not re.search(r"procs: id=%s name=COUNTER\.BIN .*state=exited .*exit=137" % pid, ser):
    sys.exit("FAIL: no exited/137 row for the killed pid %s" % pid)
print("gotop kill ok: listed+armed pid=%s, status 137, no markers after" % pid)
PY

# Run 02 -- the `/` filter leg (issue #2197). One cv-input chord sequence does
# the whole dance: `/` opens the field, `counter` narrows the table to the one
# matching row, `return` commits it, `/` reopens the committed text and
# `escape` clears it -- the unfiltered list comes back. Each edit dumps the
# filtered rows (`top: row pid=`), so the serial holds the row names the list
# showed, not just a count.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords '/,c,o,u,n,t,e,r,return,/,escape' \
    --input-chords-after 'top: ready' \
    --script3 '$RUN_DIR/script3f.txt' \
    --script3-after 'top: filter cleared' \
    --script-expect 'rx-gotop-filter-ok' --timeout 150

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 02 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 02 serial-contains 'top: ready'
vgate_assert 02 serial-contains 'top: filter open'
vgate_assert 02 serial-contains 'top: filter=counter n=1'
vgate_assert 02 serial-contains 'top: filter commit'
vgate_assert 02 serial-contains 'top: filter cleared'
vgate_assert 02 serial-contains 'top: win_close'
vgate_assert 02 serial-contains 'top: exiting 43'
vgate_assert 02 serial-contains 'rx-gotop-filter-ok'
vgate_assert 02 serial-absent '[EXC] parking:'

# The filter really narrowed the LIVE table: between `top: filter open` and
# `top: filter cleared` every row line the app dumped names COUNTER.BIN and
# nothing else (non-match rows hidden), and after the clear the dumped list
# names the seat and GOTOP again -- the full table restored, not a reprint of
# the narrowed one.
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
try:
    op = next(i for i, l in enumerate(lines) if l.strip() == "top: filter open")
    cl = next(i for i, l in enumerate(lines) if l.strip() == "top: filter cleared")
except StopIteration:
    sys.exit("FAIL: filter open/cleared markers missing")
if cl <= op:
    sys.exit("FAIL: filter cleared precedes filter open")
narrowed = [l for l in lines[op:cl] if l.startswith("top: row pid=")]
if not narrowed:
    sys.exit("FAIL: no filtered row dump between open and cleared")
bad = [l for l in narrowed if "name=COUNTER.BIN" not in l]
if bad:
    sys.exit("FAIL: non-match rows visible while filtered: %s" % bad)
restored = [l for l in lines[cl:] if l.startswith("top: row pid=")]
names = {l.split("name=")[1].split(" ")[0] for l in restored if "name=" in l}
missing = {"COUNTER.BIN", "TABWM.BIN", "GOTOP.ELF"} - names
if missing:
    sys.exit("FAIL: full list not restored after clear; missing %s (saw %s)"
             % (sorted(missing), sorted(names)))
print("gotop filter ok: %d narrowed row(s) all COUNTER.BIN; restored names %s"
      % (len(narrowed), sorted(names)))
PY

# --- Run 03 (issue #2198): real CPU/MEM figures against a busy fixture ---------
#
# script2 execs GOSCALE.ELF once the seat is up; script3 execs GOTOP.ELF only
# after `goscale: released m=4` — by then the four spinning workers have held
# the cores for the whole ~6 s window, so the busy pid has real tick charges
# on whichever cores ran them (the per-core attribution is the point: a
# core-0-only charge would read 0 here). The run ends on `top: refreshed ok`
# from the post-'r' dump, which is program output — assert-proven, and the
# pre-0047 kernel cannot emit `top: usage` or cpu=/mem= row fields at all.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2u.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3u.txt' \
    --script3-after 'goscale: busy m=4' \
    --input-string 'r' \
    --input-string-after 'top: ready' \
    --script-expect 'top: refreshed ok' --timeout 240

vgate_assert 03 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 03 serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert 03 serial-contains 'goscale: busy m=4'
vgate_assert 03 serial-contains 'exec: loaded GOTOP.ELF'
vgate_assert 03 serial-contains 'top: ready'
vgate_assert 03 serial-contains 'top: usage cpux10='
vgate_assert 03 serial-contains 'top: refreshed ok'
vgate_assert 03 serial-absent '[EXC] parking:'

vgate_assert 03 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# The busy fixture's row must carry a nonzero tick count — real scheduler
# attribution, not wall-clock math.
busy = [l for l in lines if l.startswith("top: row pid=") and "name=GOSCALE.ELF" in l]
if not busy:
    sys.exit("FAIL: GOTOP never listed GOSCALE.ELF")
cpus = [int(m.group(1)) for l in busy
        for m in [re.search(r" cpu=(\d+)", l)] if m]
if not cpus or max(cpus) == 0:
    sys.exit("FAIL: GOSCALE.ELF rows have no nonzero cpu= tick count: %s" % busy)
# Memory: a live process (GOTOP itself) must report a real footprint.
gotop = [l for l in lines if "name=GOTOP.ELF" in l and "state=running" in l]
mems = [int(m.group(1)) for l in gotop
        for m in [re.search(r" mem=(\d+)", l)] if m]
if not mems or max(mems) == 0:
    sys.exit("FAIL: GOTOP.ELF rows have no nonzero mem= footprint: %s" % gotop)
# The machine summary: nonzero busy share and a real pool denominator.
us = [l for l in lines if l.startswith("top: usage cpux10=")]
if not us:
    sys.exit("FAIL: no `top: usage` marker — v2 rows never arrived")
m = re.search(r"cpux10=(\d+) memused=(\d+) memtotal=(\d+)", us[-1])
if not m or int(m.group(1)) == 0 or int(m.group(3)) == 0:
    sys.exit("FAIL: usage marker carries no real figures: %r" % us[-1])
print("gotop usage ok: busy cpu_ticks=%d, gotop mem=%dB, machine cpux10=%s"
      % (max(cpus), max(mems), m.group(1)))
PY


# --- Run 04 (issue #2198): PULSE renders the same real figures -----------------
#
# PULSE.ELF on the default seat: its usage seam negotiates the v2 row, so
# `pulse: usage` is the proof the bars have real numerators — it is absent
# on a pre-0047 kernel. The `2` chord repaints the Processes tab (CPU%/MEM
# columns) before the close; `pulse: repainted` gates it.
vgate_file script4p.txt <<'EOS'
exec GOSCALE.ELF
EOS

vgate_file script4q.txt <<'EOS'
exec PULSE.ELF
EOS

vgate_file script4r.txt <<'EOS'
dui close 2
EOS

vgate_run 04 -- \
    --screen '$RUN_DIR/screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script4p.txt' \
    --script2 '$RUN_DIR/script4q.txt' \
    --script2-after 'goscale: released m=4' \
    --input-chords '2' \
    --input-chords-after 'pulse: ready' \
    --script3 '$RUN_DIR/script4r.txt' \
    --script3-after 'pulse: repainted' \
    --script-expect 'pulse: close' --timeout 240

vgate_assert 04 serial-contains 'exec: loaded GOSCALE.ELF'
vgate_assert 04 serial-contains 'exec: loaded PULSE.ELF'
vgate_assert 04 serial-contains 'pulse: ready'
vgate_assert 04 serial-contains 'pulse: procs '
vgate_assert 04 serial-contains 'pulse: usage cpux10='
vgate_assert 04 serial-contains 'pulse: key 2'
vgate_assert 04 serial-contains 'pulse: repainted'
vgate_assert 04 serial-contains 'pulse: close'
vgate_assert 04 serial-absent '[EXC] parking:'

vgate_assert 04 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"pulse: usage cpux10=(\d+) memused=(\d+) memtotal=(\d+)", ser)
if not m:
    sys.exit("FAIL: no `pulse: usage` marker - the v2 rows never arrived")
if int(m.group(2)) == 0 or int(m.group(3)) == 0:
    sys.exit("FAIL: pulse usage has no real memory figures: %r" % m.group(0))
print("pulse usage ok: cpux10=%s memused=%sB memtotal=%sB" % m.groups())
PY
