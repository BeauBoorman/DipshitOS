# live-crash-viewer.spec -- M22 D11: crash report viewer on VZ.
# Executes CRASH.ELF, then 'crash 1' renders the detailed tombstone
# with the resolved symbol '(in crasher+0x4)' and the serial snapshot.

vgate_name live-crash-viewer "M22 D11: crash report viewer on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec CRASH.ELF
echo cv-mid
EOF

vgate_file script2.txt <<'EOF'
crash 1
echo rx-crashview-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'tasks user-exec exited status=139' --script-expect 'rx-crashview-ok' --timeout 90

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-contains 'exited status=139'
vgate_assert 01 serial-contains 'VirelaiOS Crash Tombstone'
vgate_assert 01 serial-contains '(in crasher+0x4)'
vgate_assert 01 serial-contains '--- Last Serial Output ---'
vgate_assert 01 serial-exact 'rx-crashview-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'

# M94e: guest-owned polling, real Go stacks, honest one-PC kernel faults,
# same-size replacement and an in-process arm-before-exec tracer.
vgate_setup_python <<'PY'
import os, shutil
from pathlib import Path
share = Path(os.environ["RUN_DIR"], "share")
for name in ("CRASHVIEW", "CRASHFIX", "GOTABWM"):
    src = Path(".build/go", name + ".ELF")
    assert src.is_file(), str(src) + " missing; build-crashview/build-gotabwm first"
    shutil.copyfile(src, share / (name + ".ELF"))
(share / "SETTINGS.TXT").write_text("#v2\nwm=none\n")
PY

vgate_file check-crash.py <<'PY'
import json, os, re, shutil
from pathlib import Path
serial = Path(os.environ["VG_SER"]).read_text(errors="replace")
share = Path(os.environ["VG_SHARE"])
tag = os.environ["VG_TAG"]
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
assert "crashview: error" not in serial
assert "crashguard: diagnostic write failed" not in serial
assert re.search(r"crashview: directories=(same|distinct)", serial), "directory observation absent"
shown = re.findall(r"^crashview: shown app=(\S+) kind=(go|kernel|exit) frames=(\d+) t1=(\d+) generation=(\d+)$", serial, re.M)
def go_crashes(count):
    starts = re.findall(r"^crashfix: t0=(\d+) token=(first|other)$", serial, re.M)
    rows = [row for row in shown if row[0] == "CRASHFIX.ELF" and row[1] == "go" and int(row[2]) >= 3]
    # A receipt may appear before its stack sibling; count only genuine stacks.
    unique = {}
    for row in rows:
        unique.setdefault(row[4], row)
    rows = list(unique.values())
    assert len(rows) >= count and len(starts) >= count, (starts, rows)
    delays = []
    for (t0, token), row in zip(starts[:count], rows[:count]):
        t0, t1, generation = int(t0), int(row[3]), int(row[4])
        assert 0 <= t1-t0 <= 10_000_000_000, ("latency", token, t1-t0)
        assert t0 <= generation <= t1, ("shared monotonic clock", t0, generation, t1)
        delays.append(t1-t0)
    assert "crashview: frame main." in serial, "real main frame absent"
    return delays
def capture(app="CRASHFIX.ELF"):
    for ext in ("TXT", "STK"):
        path = share / "CRASH" / (app + "." + ext)
        if path.exists():
            shutil.copyfile(path, "artifacts/live-crash-viewer-" + tag + "-" + app + "." + ext + suffix)
def report(delays):
    result = {"boot": tag, "directory": re.search(r"directories=(same|distinct)", serial)[1],
              "latency_ns": delays}
    print(json.dumps(result))
    with open("artifacts/live-crash-viewer-latencies" + suffix + ".jsonl", "a") as f:
        f.write(json.dumps(result) + "\n")
PY

vgate_file reset-crash.py <<'PY'
# Independent cleanup keeps a deliberately red boot from cascading into others.
# Only this gate's disposable share is affected. Never remove artifacts.
import os, shutil
from pathlib import Path
share = Path(os.environ["VG_SHARE"])
for name in ("CRASH", "crash"):
    if (share / name).exists():
        shutil.rmtree(share / name)
for name in ("FIRST.TXT", "FIRST.STK"):
    (share / name).unlink(missing_ok=True)
PY

vgate_assert 01 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "reset-crash.py")).read())
PY

# M97g (#2085): the APPLOG/CRASH label overlay binds receipt files to the
# producing image or its spawner — a VIEWER needs the monitor's `-u0`
# admin spawn (uid_system + CAP_FS_ANY), the same channel go-selftest's
# LOGVIEW legs use.
vgate_file go.txt <<'EOF'
exec -u0 CRASHVIEW.ELF -text -exercise go
EOF
vgate_file kernel.txt <<'EOF'
exec -u0 CRASHVIEW.ELF -text -exercise kernel
EOF
vgate_file twice.txt <<'EOF'
exec -u0 CRASHVIEW.ELF -text -exercise twice
EOF
vgate_file reopen.txt <<'EOF'
exec -u0 CRASHVIEW.ELF -text -exercise reopen
EOF
vgate_file window.txt <<'EOF'
exec -u0 CRASHVIEW.ELF -exercise go
EOF

vgate_run 02 -- --script '$RUN_DIR/go.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'crashview: done shown=1' --timeout 60
vgate_assert 02 serial-contains 'crashview: shown app=CRASHFIX.ELF kind=go frames='
vgate_assert 02 serial-contains 'crashview: frame main.'
vgate_assert 02 serial-contains 'exited status=2'
vgate_assert 02 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "check-crash.py")).read())
delays = go_crashes(1)
spawn = re.search(r"crashview: spawn app=CRASHFIX.ELF t0=(\d+)", serial)
child = re.search(r"crashfix: t0=(\d+)", serial)
assert spawn and child and 0 <= int(child[1])-int(spawn[1]) <= 10_000_000_000, "cross-process Nanos ordering failed"
capture()
report(delays)
PY
vgate_assert 02 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "reset-crash.py")).read())
PY

vgate_run 03 -- --script '$RUN_DIR/kernel.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'crashview: done shown=1' --timeout 60
vgate_assert 03 serial-contains 'crashview: shown app=CRASH.ELF kind=kernel frames=1'
vgate_assert 03 serial-contains 'crashview: frame (in crasher+0x4)'
vgate_assert 03 serial-contains 'stack: one recorded PC (not an unwound stack)'
vgate_assert 03 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "check-crash.py")).read())
spawn = re.search(r"crashview: spawn app=CRASH.ELF t0=(\d+)", serial)
row = next((row for row in shown if row[:3] == ("CRASH.ELF", "kernel", "1")), None)
assert spawn and row, "kernel receipt missing"
delay = int(row[3])-int(spawn[1])
assert 0 <= delay <= 10_000_000_000, ("kernel latency", delay)
paths = {(p.stat().st_dev, p.stat().st_ino): p for directory in ("CRASH", "crash")
         for p in (share / directory).glob("*-CRASH.ELF.txt")}
assert len(paths) == 1
shutil.copyfile(next(iter(paths.values())), "artifacts/live-crash-viewer-03-kernel.txt" + suffix)
report([delay])
PY
vgate_assert 03 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "reset-crash.py")).read())
PY

vgate_run 04 -- --script '$RUN_DIR/twice.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'crashview: done shown=' --timeout 60
vgate_assert 04 serial-count 'crashview: shown app=CRASHFIX.ELF kind=go frames=' 2
vgate_assert 04 serial-contains 'crashview: done shown=2'
vgate_assert 04 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "check-crash.py")).read())
delays = go_crashes(2)
for ext in ("TXT", "STK"):
    first = (share / ("FIRST." + ext)).read_bytes()
    second = (share / "CRASH" / ("CRASHFIX.ELF." + ext)).read_bytes()
    assert len(first) == len(second) and first != second, ("same-size replacement", ext, len(first), len(second))
    shutil.copyfile(share / ("FIRST." + ext), "artifacts/live-crash-viewer-04-first." + ext + suffix)
capture()
report(delays)
PY
vgate_assert 04 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "reset-crash.py")).read())
PY

vgate_run 05 -- --script '$RUN_DIR/reopen.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'crashview: done shown=' --timeout 60
vgate_assert 05 serial-contains 'crashview: reopened app=CRASHFIX.ELF pid='
vgate_assert 05 serial-contains 'sys_file_open(path="/host/CRASH/CRASHFIX.ELF.TXT~"'
vgate_assert 05 serial-contains 'sys_exit(status=2) = <no-return>'
vgate_assert 05 serial-contains 'crashview: trace done status=2 dropped=0'
vgate_assert 05 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "check-crash.py")).read())
delays = go_crashes(1)
pid = re.search(r"crashview: reopened app=CRASHFIX.ELF pid=(\d+)", serial)
lines = re.findall(r"\[strace (\d+)\] (sys_[^\n]+)", serial)
assert pid and lines and all(p == pid[1] for p, _ in lines), "trace target leaked"
assert lines[0][1].startswith("sys_write("), "child's first console syscall not captured"
assert lines[-1][1] == "sys_exit(status=2) = <no-return>", "trace did not end at crash exit"
capture()
report(delays)
PY
vgate_assert 05 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "reset-crash.py")).read())
(share / "SETTINGS.TXT").write_text("#v2\nwm=gotabwm\n")
PY

# Exercise the same R action through the window's appkit event route, not a
# second tracer process or a gate-only reopening implementation.
vgate_run 06 -- --screen '$RUN_DIR/crash-screen' --via-virtio --script '$RUN_DIR/window.txt' --script-after 'gotabwm: present' --input-chords r --input-chords-after 'crashview: frame main.' --script-expect 'crashview: trace done status=2 dropped=0' --timeout 90
vgate_assert 06 serial-contains 'crashview: ready window'
vgate_assert 06 serial-contains 'crashview: present'
vgate_assert 06 serial-contains 'crashview: reopened app=CRASHFIX.ELF pid='
vgate_assert 06 serial-contains 'sys_exit(status=2) = <no-return>'
vgate_assert 06 python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "check-crash.py")).read())
report(go_crashes(1))
assert "STRACE.ELF" not in serial, "separate tracer process is forbidden"
capture()
PY

# ---------------------------------------------------------------------------
# M161b (#2974): the seat watchdog. CRASHFIX's wedge mode answers the state
# asks for 5 s then stops polling them — two unanswered rounds earn the
# not-responding banner. The Close chord runs the ordinary close seam, the
# kernel tears the window down, and the fixture — asleep but watching its
# own window — exits. `idle` is the control: it answers forever and must
# never draw a wedged line.
vgate_file wedge.txt <<'EOF2'
exec CRASHFIX.ELF wedge 5
EOF2

vgate_file wedge-done.txt <<'EOF2'
echo rx-wedge-ok
EOF2

vgate_run 07 -- --screen '$RUN_DIR/wd-wedge' --via-virtio --script '$RUN_DIR/wedge.txt' --script-after 'gotabwm: present' --input-chords 'ctrl-shift-w' --input-chords-after 'gotabwm: watchdog wedged' --script2 '$RUN_DIR/wedge-done.txt' --script2-after 'gotabwm: watchdog closed' --script-expect 'rx-wedge-ok' --timeout 150
vgate_assert 07 serial-contains 'gotabwm: watchdog force-quit armed'
vgate_assert 07 serial-contains 'crashfix: wedge secs=5'
vgate_assert 07 serial-contains 'crashfix: wedged'
vgate_assert 07 serial-contains 'gotabwm: watchdog wedged id='
vgate_assert 07 serial-contains 'gotabwm: watchdog closed id='
vgate_assert 07 serial-contains ' how=close'
vgate_assert 07 serial-contains 'crashfix: window gone'
vgate_assert 07 serial-contains 'rx-wedge-ok'
# Wedge->close ordering, and the process really exited (status 0).
vgate_assert 07 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
wedged = re.search(r"gotabwm: watchdog wedged id=(\d+) app=(\S+) rounds=(\d+)", ser)
assert wedged, "no wedged marker"
closed = re.search(r"gotabwm: watchdog closed id=%s how=close" % wedged[1], ser)
assert closed and closed.start() > wedged.end(), "no matching closed how=close after wedged"
assert re.search(r"tasks user-exec exited status=0", ser[closed.end():]), "CRASHFIX did not exit after Close"
assert "watchdog recovered" not in ser, "a still-asleep app must not report recovery"
print("watchdog wedge ok: id=%s app=%s rounds=%s" % wedged.groups())
PY

vgate_file idle.txt <<'EOF2'
exec CRASHFIX.ELF idle
EOF2

vgate_file idle-done.txt <<'EOF2'
echo rx-idle-ok
EOF2

vgate_run 08 -- --screen '$RUN_DIR/wd-idle' --via-virtio --script '$RUN_DIR/idle.txt' --script-after 'gotabwm: present' --script2 '$RUN_DIR/idle-done.txt' --script2-after 'crashfix: idle alive=60' --script-expect 'rx-idle-ok' --timeout 150
vgate_assert 08 serial-contains 'crashfix: idle'
vgate_assert 08 serial-contains 'crashfix: idle alive=60'
vgate_assert 08 serial-absent 'gotabwm: watchdog wedged'
vgate_assert 08 serial-contains 'rx-idle-ok'
