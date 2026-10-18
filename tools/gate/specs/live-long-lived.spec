# live-long-lived.spec -- a never-exiting COUNTER.BIN among live
# peers: its markers span the whole log (first before the first USER
# exit, last after the last), three USER.BINs load/exit/reap exactly
# three times each, and the pages delta is exactly one live USER.BIN
# (97 = 1 text + 48 user-stack + 48 kernel-stack pages at the 192 KiB
# task_stack_size from #1336). No --script-expect (the full window must elapse).
# Mirrors tools/verify-live-long-lived.sh (claim 4613). The stale
# "exactly TWO loads" comment is ignored -- the code requires 3.

vgate_name live-long-lived "permanent occupant among exiting peers on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
ls
exec COUNTER.BIN
exec USER.BIN
procs
pages
echo rx-long-lived-phase1
EOF

vgate_file script2.txt <<'EOF'
exec USER.BIN
procs
exec USER.BIN
pages
echo rx-long-lived-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script1.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'tasks user-exec reaped' --timeout 75

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-exact 'rx-long-lived-phase1' 1
vgate_assert 01 serial-exact 'rx-long-lived-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -qE: the ls row (dots unescaped, as in the script).
if not re.search(r"^  COUNTER.BIN ", ser, re.M):
    sys.exit("FAIL: no COUNTER.BIN ls row")
# Legacy -Fc counts: one counter load, THREE user loads/exits/reaps.
for n, w in (("exec: loaded COUNTER.BIN size=", 1),
             ("exec: loaded USER.BIN size=", 3),
             ("tasks user-exec exited status=43", 3),
             ("procs USER.BIN exited status=43", 3),
             ("tasks user-exec reaped", 3),
             ("tasks user-el0 exited status=7", 1),
             ("counter: alive", None)):
    c = sum(1 for l in lines if n in l)
    if w is None:
        if c < 3:
            sys.exit("FAIL: counter markers=%d, want >= 3" % c)
    elif c != w:
        sys.exit("FAIL: %r x%d, want %d" % (n, c, w))
# The counter never exits: its markers span past every USER exit
# (the ==0 pre-check is dead code when the span resolves -- legacy
# overwrites it; mirror the effective span logic, fall back to ==0).
exits = [i for i, l in enumerate(lines)
         if "tasks user-exec exited status=43" in l or "procs USER.BIN exited status=43" in l]
mks = [i for i, l in enumerate(lines) if "counter: alive" in l]
if mks and exits:
    if not (mks[0] < exits[0] and mks[-1] > exits[-1]):
        sys.exit("FAIL: counter markers do not span the exits")
elif sum(1 for l in lines if "procs COUNTER.BIN exited" in l) != 0:
    sys.exit("FAIL: counter exited")
# Both running at once, distinct executor tasks.
# M50 (#1135) added uid=/caps= columns between name= and state=.
def first_row(name):
    for l in lines:
        if re.search(r"procs: id=[0-9]+ name=%s uid=\d+ caps=\d+ state=running" % name, l):
            return l
    return None
cr, ur = first_row("COUNTER.BIN"), first_row("USER.BIN")
if cr is None or ur is None:
    sys.exit("FAIL: running rows absent")
ct = re.search(r".*task=([0-9]+).*", cr)
ut = re.search(r".*task=([0-9]+).*", ur)
if not ct or not ut or ct.group(1) == ut.group(1):
    sys.exit("FAIL: tasks not distinct")
# The exited USER.BIN row exists (procs table keeps it).
if not re.search(r"name=USER\.BIN uid=\d+ caps=\d+ state=exited", ser):
    sys.exit("FAIL: no exited USER.BIN row")
# Pages: >= 2 reads, phase-2 free = phase-1 free - 97 (one more live
# USER.BIN: 1 text + 48 user-stack + 48 kernel-stack pages at the 192 KiB
# task_stack_size from #1336; a leak would drop further).
# `pages` output interleaves with the counter/exec prints mid-token
# (`total=0x00` / `user: exec ok` / `0000000000febf free=...`), so
# per-line matching misses the continuation. Window after each marker.
frees = []
for m in re.finditer(r"pages: armed=1 total=", ser):
    fm = re.search(r"free=0x([0-9a-f]+)", ser[m.start():m.start() + 700])
    if fm:
        frees.append(int(fm.group(1), 16))
if len(frees) < 2:
    sys.exit("FAIL: fewer than 2 pages reads")
if frees[0] - frees[1] != 97:
    sys.exit("FAIL: pages delta %d, want 97" % (frees[0] - frees[1]))
# The counter runs at the FINAL procs read.
last = [l for l in lines if re.search(r"procs: id=[0-9]+ name=COUNTER.BIN", l)]
if not last or "state=running" not in last[-1]:
    sys.exit("FAIL: counter not running at the end")
print("long-lived span + counts + pages ok")
PY
