# live-trust-caps.spec -- M50 TS3 class-B gate (issue #1137, ADR 0024 D5/D10).
#
# The process-privilege gate live, in two boots on one seeded share:
# (1) the EL1h monitor ADMIN-SPAWNS a uid_system probe (`exec -u0
# COUNTER.BIN`; `procs` reads uid=0 caps=3), a uid_user GOTOP.ELF tries to
# kill it cross-principal and gets EACCES (-7) from slot 29's gate — and
# the probe keeps running after the denial, so nothing was armed;
# (2) the boot default unchanged: a uid_user GOTOP.ELF kills a uid_user
# COUNTER.BIN (same-uid) exactly as before — success, status 137, markers
# stop. The admin spawn is monitor-only: EL0 has no principal argument.

vgate_name live-trust-caps "#1137 TS3: kill gate — uid_user cross-principal EACCES, uid_system probe survives, same-uid kill unchanged"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# Boot 01: the uid_system probe, then the uid_user killer (TOP's 'k').
vgate_file script1.txt <<'EOF'
exec -u0 COUNTER.BIN
procs
exec GOTOP.ELF
EOF

# After the denied kill: a final procs row + the syscall counter, then stop.
vgate_file script2.txt <<'EOF'
procs
syscalls
echo trust-caps-denied
EOF

# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotop.sh   ->  .build/go/GOTOP.ELF
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
PY

vgate_run 01 -- --display --input \
    --script '$RUN_DIR/script1.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'top: kill pid=1 err=-7' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script-expect 'trust-caps-denied' \
    --timeout 75

# Kernel principal: the admin spawn assigned uid_system + both caps.
vgate_assert 01 serial-contains 'procs: id=1 name=COUNTER.BIN uid=0 caps=3'
# EL0 denial: the uid_user caller's cross-principal kill is EACCES (-7) at
# the syscall seam — and the syscall was actually dispatched (counted).
vgate_assert 01 serial-contains 'top: kill pid=1 err=-7'
vgate_assert 01 serial-contains '29 sys_kill calls=1'
vgate_assert 01 serial-contains 'trust-caps-denied'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

# The denial armed nothing: the uid_system probe's markers continue after
# the EACCES line, and its final procs row is still running.
vgate_assert 01 python <<'PY'
import os, sys, re
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
denied = next((i for i, l in enumerate(lines) if "top: kill pid=1 err=-7" in l), None)
if denied is None:
    sys.exit("FAIL: no cross-principal EACCES (-7) denial line")
after = sum(1 for l in lines[denied + 1:] if "counter: alive" in l)
if after < 1:
    sys.exit("FAIL: uid_system probe produced no markers after the denied kill (it was armed)")
if "uid=1000" not in ser:
    sys.exit("FAIL: no uid_user principal observed in the run")
if not re.search(r"procs: id=1 name=COUNTER\.BIN uid=0 caps=3 state=running", ser):
    sys.exit("FAIL: uid_system probe is not still running at the end")
print("trust-caps EACCES ok: probe survived with %d markers after denial" % after)
PY

# Boot 02: the boot-default control — same-uid kill still works.
vgate_file script3.txt <<'EOF'
exec COUNTER.BIN
exec GOTOP.ELF
EOF

vgate_file script4.txt <<'EOF'
procs
syscalls
echo trust-caps-same-uid-ok
EOF

vgate_run 02 -- --display --input \
    --script '$RUN_DIR/script3.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script4.txt' \
    --script2-after 'tasks user-exec exited status=137' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script-expect 'trust-caps-same-uid-ok' \
    --timeout 75

# Same-uid kill: allowed, armed, and converted to the 137 exit path.
vgate_assert 02 serial-contains 'top: ready'
vgate_assert 02 serial-exact 'top: kill pid=1' 1
vgate_assert 02 serial-contains 'tasks user-exec exited status=137'
vgate_assert 02 serial-contains '29 sys_kill calls=1'
vgate_assert 02 serial-contains 'trust-caps-same-uid-ok'
vgate_assert 02 serial-absent '[EXC] parking:'

# The killed uid_user counter stops: no markers after the success line.
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
killed = next((i for i, l in enumerate(lines) if l.strip() == "top: kill pid=1"), None)
if killed is None:
    sys.exit("FAIL: no same-uid kill success line")
after = sum(1 for l in lines[killed + 1:] if "counter: alive" in l)
if after != 0:
    sys.exit("FAIL: killed uid_user counter ran %d times after the kill" % after)
print("trust-caps same-uid kill ok: no markers after the kill")
PY

# ---------------------------------------------------------------------------
# M173b (#3041, index D12): the agent asymmetry in the kill gate.
# Boot 03 — a uid_agent caller cannot signal uid_user (EACCES, probe lives).
# Boot 04 — uid_user may always stop uid_agent (allowed, status 137).
# Boot 05 — uid_agent may signal its own principal (same-uid rule, allowed).
# ---------------------------------------------------------------------------

# Boot 03: agent -> user is EACCES.
vgate_file script-a3.txt <<'EOF'
exec COUNTER.BIN
exec -u2000 GOTOP.ELF
EOF

vgate_file script-a3b.txt <<'EOF'
procs
syscalls
echo caps-agent-denied
EOF

vgate_run 03 -- --display --input \
    --script '$RUN_DIR/script-a3.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script-a3b.txt' \
    --script2-after 'top: kill pid=1 err=-7' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script-expect 'caps-agent-denied' \
    --timeout 75

# The agent principal GOTOP.ELF carried uid=2000 into procs; its cross-
# principal kill of the uid_user counter was refused EACCES (-7).
vgate_assert 03 serial-contains 'procs: id=2 name=GOTOP.ELF uid=2000 caps=0'
vgate_assert 03 serial-contains 'top: kill pid=1 err=-7'
vgate_assert 03 serial-contains '29 sys_kill calls=1'
vgate_assert 03 serial-contains 'caps-agent-denied'
vgate_assert 03 serial-absent '\[EXC\]'
vgate_assert 03 serial-absent '[EXC] parking:'

# Nothing armed: the uid_user counter kept running past the denial.
vgate_assert 03 python <<'PY'
import os, sys, re
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
denied = next((i for i, l in enumerate(lines) if "top: kill pid=1 err=-7" in l), None)
if denied is None:
    sys.exit("FAIL: no agent->user EACCES line")
after = sum(1 for l in lines[denied + 1:] if "counter: alive" in l)
if after < 1:
    sys.exit("FAIL: uid_user target produced no markers after the denied kill")
if not re.search(r"procs: id=1 name=COUNTER\.BIN uid=1000 caps=0 state=running", ser):
    sys.exit("FAIL: uid_user target is not still running at the end")
print("trust-caps agent->user EACCES ok: %d markers after denial" % after)
PY

# Boot 04: user -> agent allowed (D12). The agent principal on COUNTER.BIN
# is minted by the monitor's -u2000 admin spawn; a uid_user GOTOP stops it.
vgate_file script-a4.txt <<'EOF'
exec -u2000 COUNTER.BIN
exec GOTOP.ELF
EOF

vgate_file script-a4b.txt <<'EOF'
procs
syscalls
echo caps-user-stops-agent
EOF

vgate_run 04 -- --display --input \
    --script '$RUN_DIR/script-a4.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script-a4b.txt' \
    --script2-after 'tasks user-exec exited status=137' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script-expect 'caps-user-stops-agent' \
    --timeout 75

# The target carried uid=2000; the human's kill still landed (no EACCES).
vgate_assert 04 serial-contains 'procs: id=1 name=COUNTER.BIN uid=2000 caps=0'
vgate_assert 04 serial-contains 'procs: id=2 name=GOTOP.ELF uid=1000 caps=0'
vgate_assert 04 serial-exact 'top: kill pid=1' 1
vgate_assert 04 serial-absent 'top: kill pid=1 err='
vgate_assert 04 serial-contains 'tasks user-exec exited status=137'
vgate_assert 04 serial-contains '29 sys_kill calls=1'
vgate_assert 04 serial-contains 'caps-user-stops-agent'
vgate_assert 04 serial-absent '[EXC] parking:'

# Boot 05: agent -> own agent child allowed (same-uid rule).
vgate_file script-a5.txt <<'EOF'
exec -u2000 COUNTER.BIN
exec -u2000 GOTOP.ELF
EOF

vgate_file script-a5b.txt <<'EOF'
procs
syscalls
echo caps-agent-self-ok
EOF

vgate_run 05 -- --display --input \
    --script '$RUN_DIR/script-a5.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script-a5b.txt' \
    --script2-after 'tasks user-exec exited status=137' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script-expect 'caps-agent-self-ok' \
    --timeout 75

# Both rows uid=2000; same-uid kill allowed and converted to status 137.
vgate_assert 05 serial-contains 'procs: id=1 name=COUNTER.BIN uid=2000 caps=0'
vgate_assert 05 serial-contains 'procs: id=2 name=GOTOP.ELF uid=2000 caps=0'
vgate_assert 05 serial-exact 'top: kill pid=1' 1
vgate_assert 05 serial-absent 'top: kill pid=1 err='
vgate_assert 05 serial-contains 'tasks user-exec exited status=137'
vgate_assert 05 serial-contains 'caps-agent-self-ok'
vgate_assert 05 serial-absent '[EXC] parking:'
