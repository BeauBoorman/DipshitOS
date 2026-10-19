# live-boris: serial offline compiler, contained publication and exact republish.
# Independent untouched pinned compiler oracle, real entropy and failure refusal.
# exec-order: assert-proven -- launcher waits every child; post-reap pool/page checks.
vgate_name live-boris "Boris serial offline publication, deterministic republish and limits"
vgate_share arm-virtiofs
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt user/zig/boris.zig user/zig/boris/*.zig
vgate_repeat 1
vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
cache = os.environ.get("BORIS_SDK_CACHE", str(pathlib.Path(".build/zig-guest").resolve()))
subprocess.run(["python3", "tools/zig/boris/native.py", "stage", "--share", str(rd / "share"),
                "--expected", str(rd / "expected"), "--cache", cache], check=True)
for batch in range(5):
    (rd / f"start-{batch}.txt").write_text(f"tasks\npages\nexec BORISGATE.BIN {batch}\n")
PY
vgate_file after.txt <<'EOF'
tasks
pages
procs
syscalls
echo done-boris
EOF
vgate_file compare.py <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
batch = int(os.environ["VG_TAG"].split("-")[0][1:])
subprocess.run(["python3", "tools/zig/boris/native.py", "compare",
                "--share", os.environ["VG_SHARE"], "--expected", str(rd / "expected"),
                "--serial", os.environ["VG_SER"], "--batch", str(batch)], check=True)
PY
# warm-cold: b0,b1,b2,b3,b4 (f) compare.py asserts byte-exact share contents —
#   a warm leg's share is the checkpoint bundle's clone and carries base-boot
#   residue (RCPT.TXT/HISTORY.TXT) no cold leg sees; observed: warm fallback
#   legs fail compare on the residue diff (M131d #2641, ADR 0059 D7(f))
vgate_run b0 -- --script '$RUN_DIR/start-0.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'boris-gate: done cases=' --script2-delay 1 --script-expect 'done-boris' --timeout 120
vgate_assert b0 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "compare.py"))
PY
vgate_run b1 -- --script '$RUN_DIR/start-1.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'boris-gate: done cases=' --script2-delay 1 --script-expect 'done-boris' --timeout 120
vgate_assert b1 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "compare.py"))
PY
vgate_run b2 -- --script '$RUN_DIR/start-2.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'boris-gate: done cases=' --script2-delay 1 --script-expect 'done-boris' --timeout 120
vgate_assert b2 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "compare.py"))
PY
vgate_run b3 -- --script '$RUN_DIR/start-3.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'boris-gate: done cases=' --script2-delay 1 --script-expect 'done-boris' --timeout 120
vgate_assert b3 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "compare.py"))
PY
vgate_run b4 -- --script '$RUN_DIR/start-4.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/after.txt' --script2-after 'boris-gate: done cases=' --script2-delay 1 --script-expect 'done-boris' --timeout 120
vgate_assert b4 python <<'PY'
import os, runpy
runpy.run_path(os.path.join(os.environ["RUN_DIR"], "compare.py"))
PY
