# Declarative cold boot survives an external prerequisite kill before seating.
# Keep its already-started dependent; hold the seat until fresh readiness.
# Two single-task native services keep the ADR 0042 desktop budget's
# task-pool occupancy bounded (the pool is 64 after M129b; the leg
# asserts zombies=0, not a pinned count).
# The negative boots must relinquish init's tasks before direct fallback.
# exec-order: assert-proven -- observation scripts run only after the hosted shell prompt.
# M183b: the balloon leg boots the flag-attached device and drives a host
# target shrink + restore; `pages` free= is the observed drop/recover.
vgate_name live-boot-order "M92: mid-boot restart, dependency order, kill receipt and single-seat fallback"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_setup_python <<'PY'
import os, pathlib, shutil, subprocess
share = pathlib.Path(os.environ.get("VG_SHARE", str(pathlib.Path(os.environ["RUN_DIR"]) / "share")))
for script in ("build-init.sh", "build-gotabwm.sh", "build-gosh.sh"):
    subprocess.run(["bash", "tools/go/" + script], check=True)
for name in ("INIT", "GOTABWM", "GOSH"):
    shutil.copyfile(".build/go/" + name + ".ELF", share / (name + ".ELF"))
subprocess.run(["python3", "tests/fixtures/init/boot/native.py", str(share)], check=True)
(share / "INIT").mkdir(exist_ok=True)
shutil.copyfile("tests/fixtures/init/boot/cold.json", share / "INIT/SERVICES.JSON")
assert not (share / "SETTINGS.TXT").exists()
assert not (share / "SESSION.TABS").exists()
PY
vgate_file prerequisites.py <<'PY'
import json, os, pathlib, re
serial = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
starts = re.findall(r"init: start name=(\S+) order=(\d+)\r?$", serial, re.M)
assert len(starts) == serial.count("init: start name="), "incomplete start marker"
if starts:
    manifest = json.loads(pathlib.Path(os.environ["VG_SHARE"], "INIT/SERVICES.JSON").read_text())
    nodes = {s["name"]: s for s in manifest["services"] if s.get("enabled", True)}
    # These fixtures use required edges only; do not infer optional-edge drops.
    assert all(not s.get("wants") for s in nodes.values()), "ungraded optional edges"
    order, pending = [], set(nodes)
    while pending:
        available = sorted(n for n in pending if all(p in order for p in nodes[n].get("requires", [])))
        assert available, "required cycle in started manifest"
        order.append(available[0])
        pending.remove(available[0])
    ready, running, completed = set(), set(), set()
    events = list(re.finditer(
        r"init: start name=(\S+) order=(\d+)\r?$|"
        r"init: ready name=(\S+)\r?$|"
        r"svc: exit name=(\S+) status=(-?\d+) t_ns=\d+\r?$", serial, re.M))
    assert sum(m[3] is not None for m in events) == serial.count("init: ready name="), \
        "incomplete ready marker"
    assert sum(m[4] is not None for m in events) == serial.count("svc: exit name="), \
        "incomplete exit marker"
    for event in events:
        name, ordinal, observed, exited, status = event.groups()
        if name:
            assert name in nodes and int(ordinal) == order.index(name) + 1, ("ordinal", name, ordinal)
            for prerequisite in nodes[name].get("requires", []):
                assert prerequisite in ready, ("start before current readiness", name, prerequisite)
            ready.discard(name)
            completed.discard(name)
            running.add(name)
        elif observed:
            assert observed in running or observed in completed, ("ready without live start", observed)
            ready.add(observed)
        else:
            assert exited in nodes, ("exit for unknown service", exited)
            was_running = exited in running
            running.discard(exited)
            if was_running and int(status) == 0 and nodes[exited]["restart"]["restart"] == "never":
                completed.add(exited)
            else:
                ready.discard(exited)
    print("every init start follows its prerequisites' current-boot readiness:", starts)
else:
    print("no init starts in", os.environ["VG_TAG"])
PY
vgate_file observe.txt <<'EOF'
procs
tasks
wm
echo m92e-boot-observed
EOF
vgate_run cold -- --screen '$RUN_DIR/screen-cold' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 4 --timeout 90
vgate_assert cold serial-contains 'init: manifest ok n=3'
vgate_assert cold serial-contains 'init: seated'
vgate_assert cold serial-contains 'gotabwm: registered'
vgate_assert cold serial-contains 'gosh: prompt'
vgate_assert cold serial-absent 'wm: autostart gotabwm'
vgate_assert cold serial-absent '[EXC] parking:'
vgate_assert cold python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert cold python <<'PY'
import json, os, pathlib, re
serial = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
manifest = json.loads(pathlib.Path(os.environ["VG_SHARE"], "INIT/SERVICES.JSON").read_text())
nodes = {s["name"]: s for s in manifest["services"] if s.get("enabled", True)}
order, pending = [], set(nodes)
while pending:
    available = sorted(n for n in pending if all(p in order for p in nodes[n].get("requires", [])))
    assert available, "required cycle in test manifest"
    order.append(available[0])
    pending.remove(available[0])
starts = re.findall(r"init: start name=(\S+) order=(\d+)", serial)
assert starts == [(n, str(i+1)) for i, n in enumerate(order)], (starts, order)
own = {"z-pre": "initpre: ready", "a-dep": "initdep: ready", "seat": "gotabwm: registered"}
for name in order:
    start = serial.index("init: start name=" + name + " ")
    ready = serial.index("init: ready name=" + name)
    assert start < ready
    for prerequisite in nodes[name].get("requires", []):
        assert serial.index("init: ready name=" + prerequisite) < start
        assert serial.index(own[prerequisite]) < serial.index(own[name])
assert serial.index("gotabwm: registered") < serial.index("init: seated")
assert serial.count("gotabwm: registered\n") == 1
assert serial.count("gotabwm: first-boot workspace") == 1
assert serial.count("gosh: prompt") == 1
assert re.search(r"tasks: [^\n]*pool=(\d+)/64 zombies=0", serial), "cold-boot task budget not observed"
for binary in ("INIT.ELF", "INITPRE.BIN", "INITDEP.BIN", "GOTABWM.ELF", "GOSH.ELF"):
    assert re.search(r"procs: [^\n]*name=" + re.escape(binary) + r" [^\n]*state=running", serial), binary
print("svcgraph lexical order, subsequent-poll readiness, one seat and one shell observed")
PY
vgate_assert cold python <<'PY'
import json, os, pathlib
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SETTINGS.TXT", "SESSION.TABS", "WINDOWS.SAV"):
    (share / name).unlink(missing_ok=True)
m = json.loads(pathlib.Path("tests/fixtures/init/boot/cold.json").read_text())
nodes = {s["name"]: s for s in m["services"]}
nodes["z-pre"]["restart"] = {
    "restart": "on-failure", "backoff_base_s": 2, "backoff_cap_s": 8,
    "max_restarts": 5, "window": 1000,
}
# a-dep is already running when z-pre dies; seat directly requires both.
nodes["seat"]["requires"] = ["a-dep", "z-pre"]
(share / "INIT/SERVICES.JSON").write_text(json.dumps(m))
assert not (share / "CRASH/INITPRE.BIN.TXT").exists(), "stale kill receipt"
PY
vgate_file kill-service.txt <<'EOF'
kill INITPRE.BIN
EOF
vgate_run killed -- --screen '$RUN_DIR/screen-killed' --script '$RUN_DIR/kill-service.txt' --script-after 'init: start name=a-dep ' --script2 '$RUN_DIR/observe.txt' --script2-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 4 --timeout 90
vgate_assert killed serial-contains 'init: manifest ok n=3'
vgate_assert killed serial-contains 'kill: INITPRE.BIN armed'
vgate_assert killed serial-contains 'svc: exit name=z-pre status=137 '
vgate_assert killed serial-contains 'svc: backoff name=z-pre k=1 '
vgate_assert killed serial-contains 'init: seated'
vgate_assert killed serial-contains 'gotabwm: registered'
vgate_assert killed serial-contains 'gosh: prompt'
vgate_assert killed serial-absent 'init: refuse'
vgate_assert killed serial-absent 'init: fallback direct'
vgate_assert killed serial-absent 'wm: autostart gotabwm'
vgate_assert killed serial-absent '[EXC] parking:'
vgate_assert killed share-contains CRASH/INITPRE.BIN.TXT 'restart=1/5'
vgate_assert killed share-contains CRASH/INITPRE.BIN.TXT 'status=137'
vgate_assert killed python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert killed python <<'PY'
import os, pathlib, re
serial = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
def matches(pattern):
    return list(re.finditer(pattern + r"\r?$", serial, re.M))
starts = matches(r"svc: start name=z-pre pid=(\d+) t_ns=(\d+)")
exits = matches(r"svc: exit name=z-pre status=137 t_ns=(\d+)")
backoffs = matches(r"svc: backoff name=z-pre k=1 delay_s=(\d+) t_ns=(\d+)")
assert (len(starts), len(exits), len(backoffs)) == (2, 1, 1), \
    ("restart counts", len(starts), len(exits), len(backoffs))
assert starts[0][1] != starts[1][1], "restart reused pid"
delay, stamp = map(int, backoffs[0].groups())
assert 2 <= delay < 4, ("M92c first-retry jitter", delay)
interval = (int(starts[1][2]) - stamp) / 1e9
assert delay <= interval <= 5, ("M92c first-retry interval", interval, delay)
init_starts = matches(r"init: start name=z-pre order=1")
ready = matches(r"init: ready name=z-pre")
assert len(init_starts) == len(ready) == 2, "restart readiness missing"
dep = matches(r"init: start name=a-dep order=2")
seat = matches(r"init: start name=seat order=3")
assert len(dep) == len(seat) == 1, "dependent restarted or seat double-started"
kill = serial.index("kill: INITPRE.BIN armed")
assert serial.count("kill: INITPRE.BIN armed") == 1
assert starts[0].start() < init_starts[0].start() < ready[0].start() < dep[0].start() < kill
assert kill < exits[0].start() < backoffs[0].start() < starts[1].start()
assert starts[1].start() < init_starts[1].start() < ready[1].start() < seat[0].start()
assert not matches(r"svc: exit name=a-dep status=-?\d+ t_ns=\d+"), \
    "already-started dependent stopped on prerequisite death"
assert len(matches(r"svc: start name=a-dep pid=\d+ t_ns=\d+")) == 1
assert serial.index("initdep: ready") < seat[0].start()
assert seat[0].start() < serial.index("gotabwm: registered") < serial.index("init: seated")
assert serial.count("initpre: ready") == 2
assert serial.count("gotabwm: registered\n") == 1
assert serial.count("gotabwm: first-boot workspace") == 1
assert serial.count("gosh: prompt") == 1
assert re.search(r"tasks: [^\n]*pool=(\d+)/64 zombies=0", serial), "kill-boot task budget not observed"
for binary in ("INIT.ELF", "INITPRE.BIN", "INITDEP.BIN", "GOTABWM.ELF", "GOSH.ELF"):
    assert re.search(r"procs: [^\n]*name=" + re.escape(binary) + r" [^\n]*state=running", serial), binary
receipt = pathlib.Path(os.environ["VG_SHARE"], "CRASH/INITPRE.BIN.TXT").read_text()
assert receipt == "app=INITPRE.BIN\noutcome=restart=1/5 status=137 backoff_s=%d\nlast-log:\n" % delay
print("mid-boot kill: dependent retained, seat held, restart=1/5 delay_s=%d observed_interval_s=%.9f" %
      (delay, interval))
PY
vgate_assert killed python <<'PY'
import os, pathlib
share = pathlib.Path(os.environ["VG_SHARE"])
(share / "SETTINGS.TXT").write_text("#v2\ninit=off\n")
for name in ("SESSION.TABS", "WINDOWS.SAV"):
    (share / name).unlink(missing_ok=True)
PY
vgate_run off -- --screen '$RUN_DIR/screen-off' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert off serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert off serial-contains 'gosh: prompt'
vgate_assert off serial-absent 'init:'
vgate_assert off python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert off python <<'PY'
import os, pathlib
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SETTINGS.TXT", "SESSION.TABS", "WINDOWS.SAV", "INIT/SERVICES.JSON"):
    (share / name).unlink(missing_ok=True)
PY
vgate_run missing -- --screen '$RUN_DIR/screen-missing' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert missing serial-contains 'init: refuse missing-manifest'
vgate_assert missing serial-contains 'init: fallback direct (init exited)'
vgate_assert missing serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert missing serial-contains 'gosh: prompt'
vgate_assert missing python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert missing python <<'PY'
import json, os, pathlib
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SESSION.TABS", "WINDOWS.SAV"):
    (share / name).unlink(missing_ok=True)
m = json.loads(pathlib.Path("tests/fixtures/init/boot/cold.json").read_text())
m["services"][2]["requires"] = ["seat"]
(share / "INIT/SERVICES.JSON").write_text(json.dumps(m))
PY
vgate_run cycle -- --screen '$RUN_DIR/screen-cycle' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert cycle serial-contains 'init: refuse cycle: a-dep -> z-pre -> seat -> a-dep'
vgate_assert cycle serial-contains 'init: fallback direct (init exited)'
vgate_assert cycle serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert cycle serial-contains 'gosh: prompt'
vgate_assert cycle serial-absent 'init: start'
vgate_assert cycle serial-absent '[EXC] parking:'
vgate_assert cycle python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert cycle python <<'PY'
import os, pathlib
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SESSION.TABS", "WINDOWS.SAV", "INIT.ELF"):
    (share / name).unlink(missing_ok=True)
PY
vgate_run noinit -- --screen '$RUN_DIR/screen-noinit' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert noinit serial-contains 'init: refuse missing-init'
vgate_assert noinit serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert noinit serial-contains 'gosh: prompt'
vgate_assert noinit python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert noinit python <<'PY'
import os, pathlib, shutil
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SESSION.TABS", "WINDOWS.SAV"):
    (share / name).unlink(missing_ok=True)
shutil.copyfile(".build/go/INIT.ELF", share / "INIT.ELF")
(share / "INIT/SERVICES.JSON").write_text('{"version":1,"services":null}')
PY
vgate_run invalid -- --screen '$RUN_DIR/screen-invalid' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert invalid serial-contains 'init: refuse null-field'
vgate_assert invalid serial-contains 'init: fallback direct (init exited)'
vgate_assert invalid serial-contains 'gosh: prompt'
vgate_assert invalid serial-absent 'init: start'
vgate_assert invalid python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert invalid python <<'PY'
import os, pathlib
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SESSION.TABS", "WINDOWS.SAV"):
    (share / name).unlink(missing_ok=True)
(share / "INIT/SERVICES.JSON").write_bytes(b" " * 8193)
PY
vgate_run oversize -- --screen '$RUN_DIR/screen-oversize' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert oversize serial-contains 'init: refuse oversize'
vgate_assert oversize serial-contains 'init: fallback direct (init exited)'
vgate_assert oversize serial-contains 'gosh: prompt'
vgate_assert oversize python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert oversize python <<'PY'
import json, os, pathlib
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SESSION.TABS", "WINDOWS.SAV"):
    (share / name).unlink(missing_ok=True)
m = json.loads(pathlib.Path("tests/fixtures/init/boot/cold.json").read_text())
m["services"][1]["argv"] = ["GOSH.ELF"]
(share / "INIT/SERVICES.JSON").write_text(json.dumps(m))
PY
vgate_run budget -- --screen '$RUN_DIR/screen-budget' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert budget serial-contains 'init: refuse task-budget'
vgate_assert budget serial-contains 'init: fallback direct (init exited)'
vgate_assert budget serial-contains 'gosh: prompt'
vgate_assert budget serial-absent 'init: start'
vgate_assert budget python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert budget python <<'PY'
import os, pathlib, shutil
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SESSION.TABS", "WINDOWS.SAV", "INITDEP.BIN"):
    (share / name).unlink(missing_ok=True)
shutil.copyfile("tests/fixtures/init/boot/cold.json", share / "INIT/SERVICES.JSON")
PY
vgate_run spawn -- --screen '$RUN_DIR/screen-spawn' --script '$RUN_DIR/observe.txt' --script-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert spawn serial-contains 'init: refuse unstartable'
vgate_assert spawn serial-contains 'init: fallback direct (init exited)'
vgate_assert spawn serial-contains 'gosh: prompt'
vgate_assert spawn serial-absent 'init: start name=seat'
vgate_assert spawn python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert spawn python <<'PY'
import os, pathlib, re, subprocess
serial = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
assert re.search(r"procs: [^\n]*name=INIT.ELF [^\n]*state=exited", serial), "init still owns tasks"
assert not re.search(r"procs: [^\n]*name=INITPRE.BIN [^\n]*state=running", serial), "partial-start child survived fallback"
share = pathlib.Path(os.environ["VG_SHARE"])
for name in ("SESSION.TABS", "WINDOWS.SAV"):
    (share / name).unlink(missing_ok=True)
subprocess.run(["python3", "tests/fixtures/init/boot/native.py", str(share)], check=True)
PY
vgate_file kill-init.txt <<'EOF'
kill INIT.ELF
EOF
vgate_run died -- --screen '$RUN_DIR/screen-died' --script '$RUN_DIR/kill-init.txt' --script-after 'init: start name=z-pre ' --script2 '$RUN_DIR/observe.txt' --script2-after 'gosh: prompt' --script-expect 'm92e-boot-observed' --script-expect-tail 2 --timeout 90
vgate_assert died serial-contains 'kill: INIT.ELF armed'
vgate_assert died serial-contains 'init: fallback direct (init exited)'
vgate_assert died serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert died serial-contains 'gosh: prompt'
vgate_assert died serial-absent 'init: seated'
vgate_assert died python <<'PY'
import os, pathlib, runpy
runpy.run_path(str(pathlib.Path(os.environ["RUN_DIR"], "prerequisites.py")))
PY
vgate_assert died python <<'PY'
import os, pathlib, re
serial = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
assert re.search(r"procs: [^\n]*name=INIT.ELF [^\n]*state=exited", serial), "init still owns tasks"
assert not re.search(r"procs: [^\n]*name=INIT(?:PRE|DEP).BIN [^\n]*state=running", serial), "orphaned init child"
assert serial.count("gotabwm: registered\n") == 1, "fallback double-launched seat"
assert serial.count("gotabwm: first-boot workspace") == 1, "fallback double-launched shell"
PY
# M183b (issue #3172): the virtio-balloon reclaim leg. --balloon attaches
# VZ's traditional memory-balloon device; the two --balloon-target-after
# triggers are the host's writes to targetVirtualMachineMemorySize — a
# shrink to 448 MiB (inflate 64 MiB = 16384 pages) on the m183b-pre echo,
# a restore to 512 MiB (full deflate) on m183b-inflated. The guest's
# `pages` free= readout is the observed drop and recover.
vgate_file balloon-observe.txt <<'EOS'
pages
echo m183b-pre
EOS
vgate_file balloon-inflated.txt <<'EOS'
pages
echo m183b-inflated
EOS
vgate_file balloon-deflated.txt <<'EOS'
pages
echo m183b-deflated
EOS
vgate_run balloon -- --balloon --balloon-target-after 'm183b-pre:448' --balloon-target-after 'm183b-inflated:512' --script '$RUN_DIR/balloon-observe.txt' --script2 '$RUN_DIR/balloon-inflated.txt' --script2-after 'balloon: inflate' --script3 '$RUN_DIR/balloon-deflated.txt' --script3-after 'balloon: deflate' --script-expect 'm183b-deflated' --timeout 120
vgate_assert balloon serial-contains 'balloon: armed did='
vgate_assert balloon serial-contains 'balloon: inflate pages='
vgate_assert balloon serial-contains 'balloon: deflate pages='
vgate_assert balloon python <<'PY'
import os, pathlib, re
serial = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
frees = [int(m, 16) for m in re.findall(r"pages: armed=1 total=0x[0-9a-f]+ free=0x([0-9a-f]+)", serial)]
assert len(frees) >= 3, ("expected 3 `pages` readouts (pre/inflated/deflated)", frees)
pre, inflated, deflated = frees[0], frees[1], frees[2]
assert inflated <= pre - 16384, ("inflate did not drop free by 64 MiB", pre, inflated)
assert deflated >= inflated + 16384, ("deflate did not return the pages", inflated, deflated)
assert deflated >= pre - 64, ("free did not recover to ~pre level", pre, deflated)
inflates = re.findall(r"balloon: inflate pages=(\d+)", serial)
deflates = re.findall(r"balloon: deflate pages=(\d+)", serial)
assert sum(int(n) for n in inflates) >= 16384, ("inflated pages short of target", inflates)
assert sum(int(n) for n in deflates) >= 16384, ("deflated pages short of restore", deflates)
print("balloon leg: free %s -> %s -> %s pages (host-driven inflate/deflate observed)" % (pre, inflated, deflated))
PY
