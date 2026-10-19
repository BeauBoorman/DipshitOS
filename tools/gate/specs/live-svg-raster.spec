# ADR 0041 SVG and independent-vector acceptance, without a viewer.
# Prebuilt pinned-fork artifacts and CairoSVG 2.8.2 references are required.
# Four isolated boots: icons, exclusions/reuse, maximum SVG, direct page.
# Missing pixels, receipts, M90d bounds or oracle pins always fail.
# exec-order: assert-proven -- one invocation per boot; script2 waits for
# the primary-task reap diagnostic; receipts prove final process reap.
vgate_name live-svg-raster "ADR 0041: independent SVG pixels, budgets, vector consumer and runtime reclamation"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import json, os, platform, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path("tools/svg-proof").resolve()))
from artifacts import stage, OUT
stage(Path(os.environ["RUN_DIR"]) / "share")
(Path(os.environ["RUN_DIR"]) / "share/SETTINGS.TXT").write_text("#v2\nwm=none\n")
cpu = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
ram = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))
os_version = subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip()
if cpu != "Apple M4" or ram != 17179869184 or not os_version.startswith("27.2"):
    sys.exit("not ADR 0041 reference time hardware")
env = dict(cpu=cpu, ram=ram, macos=os_version, host_load=os.getloadavg(),
           vm=dict(vcpus=2, ram=536870912, framework="Apple Virtualization.framework"),
           build=dict(compiler="Go 1.27.1", mode="optimized", cgo=False, trimpath=True, ldflags="-s -w"))
(OUT / "host-environment.json").write_text(json.dumps(env, indent=2)+"\n")
print("observed reference host; prepared isolated no-UI acceptance share")
PY

vgate_file icons.txt <<'EOF'
pages
timer
exec SVG.ELF icons
EOF
vgate_file reuse.txt <<'EOF'
pages
timer
exec SVG.ELF reuse
EOF
vgate_file maximum.txt <<'EOF'
pages
timer
exec SVG.ELF maximum
EOF
vgate_file consumer.txt <<'EOF'
pages
timer
exec CONSUMER.ELF consumer
EOF
vgate_file svg-exit.txt <<'EOF'
procs receipt SVG.ELF
syscalls
pages
echo svg-raster-held
EOF
vgate_file consumer-exit.txt <<'EOF'
procs receipt CONSUMER.ELF
syscalls
pages
echo svg-raster-held
EOF

vgate_run icons -- --script '$RUN_DIR/icons.txt' --script2 '$RUN_DIR/svg-exit.txt' --script2-after 'tasks user-exec reaped' --script2-delay 1 --script-expect 'svg-raster-held' --timeout 180
vgate_assert icons serial-contains 'svg-proof: outputs closed'
vgate_assert icons serial-contains 'procs SVG.ELF exited status=0'
vgate_assert icons serial-absent 'svg-proof: FAIL'
vgate_assert icons serial-absent '[EXC] parking:'
vgate_assert icons serial-absent 'fatal error:'
vgate_assert icons output-contains 'memory: 512 MiB, cpus: 2'
vgate_assert icons python <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path("tools/svg-proof").resolve()))
from receipts import gate
gate("icons")
PY

vgate_run reuse -- --script '$RUN_DIR/reuse.txt' --script2 '$RUN_DIR/svg-exit.txt' --script2-after 'tasks user-exec reaped' --script2-delay 1 --script-expect 'svg-raster-held' --timeout 180
vgate_assert reuse serial-contains 'svg-proof: outputs closed'
vgate_assert reuse serial-contains 'procs SVG.ELF exited status=0'
vgate_assert reuse serial-absent 'svg-proof: FAIL'
vgate_assert reuse serial-absent '[EXC] parking:'
vgate_assert reuse serial-absent 'fatal error:'
vgate_assert reuse python <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path("tools/svg-proof").resolve()))
from receipts import gate
gate("reuse")
PY

vgate_run maximum -- --script '$RUN_DIR/maximum.txt' --script2 '$RUN_DIR/svg-exit.txt' --script2-after 'tasks user-exec reaped' --script2-delay 1 --script-expect 'svg-raster-held' --timeout 180
vgate_assert maximum serial-contains 'svg-proof: outputs closed'
vgate_assert maximum serial-contains 'procs SVG.ELF exited status=0'
vgate_assert maximum serial-absent 'svg-proof: FAIL'
vgate_assert maximum serial-absent '[EXC] parking:'
vgate_assert maximum serial-absent 'fatal error:'
vgate_assert maximum python <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path("tools/svg-proof").resolve()))
from receipts import gate
gate("maximum")
PY

vgate_run consumer -- --script '$RUN_DIR/consumer.txt' --script2 '$RUN_DIR/consumer-exit.txt' --script2-after 'tasks user-exec reaped' --script2-delay 1 --script-expect 'svg-raster-held' --timeout 180
vgate_assert consumer serial-contains 'svg-proof: outputs closed'
vgate_assert consumer serial-contains 'procs CONSUMER.ELF exited status=0'
vgate_assert consumer serial-absent 'svg-proof: FAIL'
vgate_assert consumer serial-absent '[EXC] parking:'
vgate_assert consumer serial-absent 'fatal error:'
vgate_assert consumer python <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path("tools/svg-proof").resolve()))
from receipts import gate
gate("consumer")
PY
