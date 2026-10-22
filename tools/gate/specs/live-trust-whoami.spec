# live-trust-whoami.spec -- M50 TS1 class-B gate (issue #1135, ADR 0024 D2),
# retargeted to GOSH by M68b (#1450).
#
# The principal surface live: every EL0 process is `uid_user` (1000) with no
# caps. The EL1h monitor's `procs` row reports the SAME descriptor field the
# new `sys_principal` slot (68) hands to EL0, so the kernel seam and the
# syscall seam must agree. GOSH is asked for `whoami`/`id` over /dev/tty via
# the serial front-end. Boot default unchanged: no new syscall is on the boot
# path.

vgate_name live-trust-whoami "#1135 TS1 identity: whoami/id (sys_principal 68) agree with the monitor procs row"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
procs
exec GOSH.ELF serial
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gosh.sh")
shutil.copy(src, os.path.join(share, "GOSH.ELF"))
print("staged GOSH.ELF (%d bytes) into share" % os.path.getsize(src))
PY

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
# Ask the shell for its principal, then a marker so the gate can stop.
seq = b"whoami\rid\recho whoami-ok\r"
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/edit.bin' \
    --script2-after 'gosh: attached' \
    --script-expect 'whoami-ok' \
    --script-expect-tail 16 \
    --timeout 90

# Kernel seam: the monitor's procs row for the boot payload (uid_user, no caps).
vgate_assert 01 serial-contains 'procs: id=0 name=user-el0 uid=1000 caps=0'
# Syscall seam: sys_principal(68) rendered by the whoami/id builtins.
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'uid=1000 user'
vgate_assert 01 serial-contains 'uid=1000 user caps=0'
vgate_assert 01 serial-contains 'whoami-ok'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

# ---------------------------------------------------------------------------
# M173b (#3041, ADR 0052 amendment): the agent principal, live.
# Boot 02 — name binding. The share carries a COPY of GOSH.ELF named
# AGENTD.ELF: when the uid_user shell execs it, the kernel binds the child
# to uid_agent=2000 by recorded image name alone — and because the child
# is itself a shell, its own `whoami`/`id` prove the assigned principal
# through sys_principal (no dependence on AGENTD internals).
# ---------------------------------------------------------------------------

vgate_file script-agent1.txt <<'EOF'
exec GOSH.ELF serial
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
src = os.path.join(".build", "go", "AGENTD.ELF")
if not os.path.exists(src):
    sys.exit("AGENTD.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-agentd.sh")
shutil.copy(src, os.path.join(share, "AGENTD.ELF"))
print("staged AGENTD.ELF (%d bytes) into share" % os.path.getsize(src))
seq = b"whoami\rAGENTD.ELF\r id\r echo whoami-bind-ok\r"
with open(os.path.join(run, "agent.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 02 -- --screen '$RUN_DIR/screen2' \
    --script '$RUN_DIR/script-agent1.txt' \
    --script2 '$RUN_DIR/agent.bin' \
    --script2-after 'gosh: attached' \
    --script-expect 'whoami-bind-ok' \
    --timeout 90

# The parent's own principal is unchanged (uid_user, no caps).
vgate_assert 02 serial-contains 'uid=1000 user'
vgate_assert 02 serial-contains 'uid=1000 user caps=0'
# The name-bound child: M173d flipped AGENTD's posture to uid_agent-only,
# so the bound child now clears check 1 and reaches the credential probe —
# 'no-credential' IS the binding's proof (a uid_user child would refuse
# 'privileged', and a system principal never gets this far).
vgate_assert 02 serial-contains 'agentd: refuse no-credential'
vgate_assert 02 serial-absent 'agentd: refuse privileged'
vgate_assert 02 serial-absent 'agentd: refuse no-keyring'
vgate_assert 02 serial-contains 'whoami-bind-ok'
vgate_assert 02 serial-absent '\[EXC\]'
vgate_assert 02 serial-absent '[EXC] parking:'

# ---------------------------------------------------------------------------
# Boot 03 — the monitor admin spawn accepts -u2000 (`procs` reports the
# uid_agent row), and the agent shell's whoami/id report uid=2000 through
# sys_principal. Its GOSH.ELF child (NOT name-bound) still reports
# uid=2000: plain uid_agent inheritance through the exec preserve rule.
# ---------------------------------------------------------------------------

vgate_file script-agent3.txt <<'EOF'
exec -u2000 COUNTER.BIN
procs
exec -u2000 GOSH.ELF serial
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
seq = b"whoami\rid\recho whoami-agent-ok\r"
with open(os.path.join(run, "agent3.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 03 -- --screen '$RUN_DIR/screen3' \
    --script '$RUN_DIR/script-agent3.txt' \
    --script2 '$RUN_DIR/agent3.bin' \
    --script2-after 'gosh: attached' \
    --script-expect 'whoami-agent-ok' \
    --timeout 90

# -u2000 accepted: the procs row printed before attach shows uid_agent.
vgate_assert 03 serial-contains 'procs: id=1 name=COUNTER.BIN uid=2000 caps=0'
# whoami/id under the agent principal: uid=2000, caps=0 — twice (the
# parent shell and its inherited GOSH.ELF child).
vgate_assert 03 serial-contains 'uid=2000'

vgate_assert 03 serial-contains 'whoami-agent-ok'
vgate_assert 03 serial-absent '\[EXC\]'
vgate_assert 03 serial-absent '[EXC] parking:'
