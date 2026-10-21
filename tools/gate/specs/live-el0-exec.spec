# live-el0-exec.spec -- EL0 sys_exec returns to the caller (issue #1333).
# EL0EXEC.BIN execs a missing name (ENOENT, caller untouched), then
# USER.BIN with argv alpha, uses the stack after spawn, waits, and both
# complete. A kstack overflow on create_as used to kill the caller.
# A2 also checks the pinned native SDK's gap ELF, exact startup bounds,
# one retained reusable arena, failure/panic exits and page recovery.
# A3 exercises the native std backend, explicit-file byte comparison and a
# no-error-return API that must terminate rather than invent a clock.
# B5 adds sixteen explicit TLS contexts (the M129b per-process bound),
# join/reap/capacity, measured mutex contention, lost-wake refusal and a
# counter-bounded coarse timeout.
# exec-order: assert-proven -- SDK stages wait for reap or the launcher exit;
# independent assertions require all guest output and final page recovery.

vgate_name live-el0-exec "EL0 sys_exec: caller survives spawn + ENOENT"
vgate_share seed
vgate_repeat 1 BOOTS
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import json, os, pathlib, shutil, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
output = rd / "share/ZGUEST.BIN"
subprocess.run(["python3", "tools/zig/sdk.py", "build", "--output", str(output),
                "--work", str(rd / "sdk-build")], check=True)
subprocess.run(["python3", "-B", "tools/zig/threads.py",
                "--output", str(rd / "share/ZTHREAD.BIN"),
                "--work", str(rd / "thread-build")], check=True)
shutil.copyfile(output, rd / "share/ZLAUNCH.BIN")
(rd / "share/ZIO.INPUT").write_bytes(bytes(i % 251 for i in range(5000)))
# The monitor has a narrower 64-byte VALUE limit than the ABI's 127-byte
# KEY=VALUE slots. Test this real route losslessly; full slots are host-tested.
env = [f"G{i:02}=" + "e" * 64 for i in range(16)]
(rd / "sdk-env.txt").write_text(
    "".join(f"set {entry}\n" for entry in env) + "pages\nexec ZGUEST.BIN alpha beta\n")
(rd / "sdk-env.json").write_text(json.dumps(env))
PY

vgate_file script.txt <<'EOF'
ls
exec EL0EXEC.BIN
EOF

vgate_file script2.txt <<'EOF'
syscalls
echo rx-el0-exec-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'el0-exec: child done' --script-expect 'rx-el0-exec-ok' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-exact 'rx-el0-exec-ok' 1
vgate_assert 01 serial-contains '28 sys_exec calls=2'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'virfaulthandler'
vgate_assert 01 serial-absent 'unexpected signal'
vgate_assert 01 serial-absent 'el0-exec: exec failed'
vgate_assert 01 serial-absent 'el0-exec: enoent unexpected'
vgate_assert 01 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
need = {
    "el0-exec: enoent ok": 1,
    "el0-exec: parent survived": 1,
    "el0-exec: child done": 1,
    "user: arg=alpha": 1,
    "user: hello from the ESP": 1,
    "user: exec ok": 1,
    "user: awake": 1,
    "tasks user-exec exited status=43": 1,
    "tasks user-exec exited status=0": 1,
}
bad = [(n, sum(1 for l in lines if n in l), w) for n, w in need.items()]
bad = [(n, c, w) for n, c, w in bad if c != w]
if bad:
    sys.exit("FAIL: el0-exec markers off: %s" % bad)
print("el0-exec markers ok")
PY

vgate_file sdk-after.txt <<'EOF'
pages
procs
syscalls
echo rx-zig-guest-ok
EOF

vgate_file sdk-launch.txt <<'EOF'
pages
exec ZLAUNCH.BIN launch
EOF

vgate_file sdk-oom.txt <<'EOF'
pages
exec ZGUEST.BIN oom
EOF

vgate_file sdk-reserve.txt <<'EOF'
pages
exec ZGUEST.BIN reserve-fail
EOF

vgate_file sdk-panic.txt <<'EOF'
pages
exec ZGUEST.BIN panic
EOF

vgate_file sdk-io.txt <<'EOF'
pages
exec ZGUEST.BIN io
EOF

vgate_file sdk-unsupported.txt <<'EOF'
pages
exec ZGUEST.BIN unsupported
EOF

vgate_run sdk-env -- --script '$RUN_DIR/sdk-env.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'rx-zig-guest-ok' --timeout 90
# The two tasks share a reap marker. Anchor on the parent's unique exit,
# allow the idle reaper to run, then REQUIRE both reaps before the snapshot.
vgate_run sdk-launch -- --script '$RUN_DIR/sdk-launch.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'procs ZLAUNCH.BIN exited status=0' --script2-delay 1 --script-expect 'rx-zig-guest-ok' --timeout 90
vgate_run sdk-oom -- --script '$RUN_DIR/sdk-oom.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'rx-zig-guest-ok' --timeout 90
vgate_run sdk-reserve -- --script '$RUN_DIR/sdk-reserve.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'rx-zig-guest-ok' --timeout 90
vgate_run sdk-panic -- --script '$RUN_DIR/sdk-panic.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'rx-zig-guest-ok' --timeout 90
vgate_run sdk-io -- --script '$RUN_DIR/sdk-io.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'rx-zig-guest-ok' --timeout 90
vgate_run sdk-unsupported -- --script '$RUN_DIR/sdk-unsupported.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'rx-zig-guest-ok' --timeout 90

vgate_assert sdk-env serial-exact 'zig-guest: done' 1
vgate_assert sdk-env serial-exact 'tasks user-exec exited status=0' 1
vgate_assert sdk-env serial-contains '63 sys_mmap calls=1'
vgate_assert sdk-env python <<'PY'
import json, os, pathlib, re
rd = pathlib.Path(os.environ["RUN_DIR"])
ser = pathlib.Path(os.environ["VG_SER"]).read_text()
lines = ser.splitlines()
expected = ["zig-guest: arg[0]=ZGUEST.BIN", "zig-guest: arg[1]=alpha",
            "zig-guest: arg[2]=beta"]
expected += ["zig-guest: env=" + entry for entry in json.loads((rd / "sdk-env.json").read_text())]
assert all(lines.count(line) == 1 for line in expected), "startup bytes differ"
assert len([line for line in lines if line.startswith("zig-guest: env=")]) == 16
peak, stack = map(int, re.search(r"reuse=64 arena_peak=(\d+) stack_high_water=(\d+)", ser).groups())
assert 49152 < peak <= 1024 * 1024 and 0 < stack <= 128 * 1024
PY

vgate_assert sdk-launch serial-exact 'zig-guest: ArgumentLimit (256-byte argument)' 1
vgate_assert sdk-launch serial-exact 'zig-guest: ArgumentLimit (eight user arguments)' 1
vgate_assert sdk-launch serial-exact 'zig-guest: launcher done' 1
vgate_assert sdk-launch serial-exact 'tasks user-exec exited status=0' 2
vgate_assert sdk-launch serial-contains '28 sys_exec calls=1'
vgate_assert sdk-launch python <<'PY'
import os, pathlib
lines = pathlib.Path(os.environ["VG_SER"]).read_text().splitlines()
args = ["ZGUEST.BIN", "boundary", "x" * 255, "", "alpha", "beta", "six", "seven"]
assert all(lines.count(f"zig-guest: arg[{i}]={arg}") == 1 for i, arg in enumerate(args))
assert not any(line.startswith("zig-guest: env=") for line in lines), "slot 28 must not claim env inheritance"
PY

vgate_assert sdk-oom serial-exact 'zig-guest: bounded allocation refused' 1
vgate_assert sdk-oom serial-exact 'OutOfMemory' 1
vgate_assert sdk-oom serial-exact 'tasks user-exec exited status=70' 1
vgate_assert sdk-reserve serial-exact 'zig-guest: native reservation refused' 1
vgate_assert sdk-reserve serial-exact 'OutOfMemory' 1
vgate_assert sdk-reserve serial-exact 'tasks user-exec exited status=70' 1
vgate_assert sdk-reserve serial-contains '63 sys_mmap calls=17'
vgate_assert sdk-panic serial-exact 'zig-guest: panic: requested fixture panic' 1
vgate_assert sdk-panic serial-exact 'tasks user-exec exited status=71' 1
vgate_assert sdk-io serial-exact 'zig-io: debug 1867' 1
vgate_assert sdk-io serial-exact 'zig-io: done' 1
vgate_assert sdk-io serial-exact 'Unsupported:FdMetadataUnavailable' 1
vgate_assert sdk-io serial-exact 'Unsupported:UnboundOrClosedOutput' 1
vgate_assert sdk-io serial-absent 'must not reach console'
vgate_assert sdk-io serial-exact 'tasks user-exec exited status=0' 1
vgate_assert sdk-io serial-contains '72 sys_getrandom calls=3'
vgate_assert sdk-io serial-contains '77 sys_file_sync calls=2'
vgate_assert sdk-io serial-contains '36 sys_file_truncate calls=1'
vgate_assert sdk-io python <<'PY'
import os, pathlib, re
rd = pathlib.Path(os.environ["RUN_DIR"])
ser = pathlib.Path(os.environ["VG_SER"]).read_text()
expected = bytes(i % 251 for i in range(5000))
assert (rd / "share/ZIO.INPUT").read_bytes() == expected
assert (rd / "share/ZIO.OUTPUT").read_bytes() == expected
assert (rd / "share/ZIO.DIR/TRUNCATED").read_bytes() == b"tru"
peak, stack = map(int, re.search(r"zig-io: file=5000 arena_peak=(\d+) stack_high_water=(\d+)", ser).groups())
assert 5000 < peak < 1024 * 1024 and 0 < stack <= 128 * 1024
PY
vgate_assert sdk-unsupported serial-contains 'Unsupported:now'
vgate_assert sdk-unsupported serial-exact 'tasks user-exec exited status=70' 1
vgate_assert sdk-unsupported serial-absent 'UnsupportedReturned'

# Check *independent kernel* page observations after the reap, not merely
# the fixture's success marker. The same assertion runs for every exit path.
vgate_file sdk-cleanup.py <<'PY'
import os, pathlib, re
tag = os.environ["VG_TAG"]
ser = pathlib.Path(os.environ["VG_SER"]).read_text()
pages = re.findall(r"^pages: armed=1 total=(0x[0-9a-f]+) free=(0x[0-9a-f]+)", ser, re.M)
assert len(pages) == 2 and pages[0] == pages[1], (tag, pages)
reaps = 2 if tag.startswith("sdk-launch") else 1
assert ser.splitlines().count("tasks user-exec reaped") == reaps and "[EXC]" not in ser, tag
assert ser.rfind("tasks user-exec reaped") < ser.rfind("pages: armed=1"), tag
if any(tag.startswith(kind) for kind in ("sdk-oom", "sdk-reserve", "sdk-panic")):
    assert "zig-guest: done" not in ser, tag
print(tag + ": exact post-reap page recovery")
PY
vgate_assert sdk-env python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "sdk-cleanup.py"))
PY
vgate_assert sdk-launch python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "sdk-cleanup.py"))
PY
vgate_assert sdk-oom python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "sdk-cleanup.py"))
PY
vgate_assert sdk-reserve python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "sdk-cleanup.py"))
PY
vgate_assert sdk-panic python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "sdk-cleanup.py"))
PY
vgate_assert sdk-io python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "sdk-cleanup.py"))
PY
vgate_assert sdk-unsupported python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "sdk-cleanup.py"))
PY

vgate_file threads.txt <<'EOF'
pages
exec ZTHREAD.BIN
EOF
vgate_file threads-after.txt <<'EOF'
pages
syscalls
echo rx-zig-threads-ok
EOF
vgate_run threads -- --script '$RUN_DIR/threads.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/threads-after.txt' --script2-after 'procs ZTHREAD.BIN exited status=0' --script2-delay 1 --script-expect 'rx-zig-threads-ok' --timeout 180
vgate_assert threads serial-exact 'zig-threads: independent=16 joined=16 count=64 capacity=refused' 1
vgate_assert threads serial-exact 'zig-threads: lost-wake=changed fine=refused coarse=not-early' 1
vgate_assert threads serial-exact 'zig-threads: done' 1
vgate_assert threads serial-absent '[EXC]'
vgate_assert threads serial-absent 'zig-threads: FAIL'
vgate_assert threads python <<'PY'
import os, pathlib, re
ser = pathlib.Path(os.environ["VG_SER"]).read_text()
pages = re.findall(r"^pages: armed=1 total=(0x[0-9a-f]+) free=(0x[0-9a-f]+)", ser, re.M)
assert len(pages) == 2 and pages[0] == pages[1], pages
assert ser.count("tasks ZTHREAD.BIN reaped") == 16, "every child kstack reclaimed"
assert ser.count("tasks user-exec reaped") == 1, "primary/address space reclaimed"
assert int(re.search(r"73 sys_thread calls=(\d+)", ser)[1]) >= 20
assert int(re.search(r"74 sys_futex calls=(\d+)", ser)[1]) > 24
assert int(re.search(r"zig-threads: contention=(\d+)", ser)[1]) > 0, "mutex must actually contend"
print("B5: sixteen independent contexts, joins, native capacity, futex contention and exact page recovery")
PY
