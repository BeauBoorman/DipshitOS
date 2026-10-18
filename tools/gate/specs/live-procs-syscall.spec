# live-procs-syscall.spec -- the process table read FROM EL0 via
# sys_procs (slot 7): PEER.BIN's snapshot names the counter running,
# itself running, and the exited boot payload; the monitor agrees;
# the IPC flow stays live both ways (>= 2 each, echoes >= 90% of
# sends, no echo beyond the last send); both stay running, never
# exit. No --script-expect (the full window must elapse).
# Mirrors tools/verify-live-procs-syscall.sh (claim 5799).

vgate_name live-procs-syscall "EL0 process-table snapshot via sys_procs on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
exec PEER.BIN
exec COUNTER.BIN 1
procs
echo rx-procs-syscall-ok
EOF

vgate_file script2.txt <<'EOF'
procs
echo rx-procs-syscall-ok2
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'peer: got ping 1' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'PEER.BIN' 2
vgate_assert 01 serial-count 'exec: loaded PEER.BIN size=' 1
vgate_assert 01 serial-count 'exec: loaded COUNTER.BIN size=' 1
vgate_assert 01 serial-exact 'rx-procs-syscall-ok' 1
vgate_assert 01 serial-exact 'rx-procs-syscall-ok2' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -E: the EL0 snapshot rows (honest table: the counter
# running, the peer itself running, the exited boot payload, and a
# state word on some row).
# The peer's sees lines are byte-at-a-time writes that interleave with
# the shell prompt and keystroke echo — its own bytes still arrive
# in-order, so a bounded window with noise between fields is the honest
# match (the field ORDER carries the evidence, not line atomicity).
NOISE = r"[\s\S]{0,300}?"
for name, state in (("COUNTER.BIN", "running"), ("PEER.BIN", "running"),
                    ("user-el0", "exited")):
    pat = r"peer: sees" + NOISE + r"[0-9]+" + NOISE + re.escape(name) + NOISE + state
    if not re.search(pat, ser):
        sys.exit("FAIL: ERE absent: %s %s" % (name, state))
if not re.search(r"peer: sees" + NOISE + r"[0-9]+" + NOISE + r"[^ ]+" + NOISE + r"(created|running|exited)", ser):
    sys.exit("FAIL: ERE absent: any sees row")
# Monitor's own read: both running, distinct tasks + stacks.
# Procs rows grew uid/caps (M50) between name and state.
def first_row(name):
    for l in lines:
        if re.search(r"procs: id=[0-9]+ name=%s uid=\d+ caps=\d+ state=running" % name, l):
            return l
    return None
pr, cr = first_row("PEER.BIN"), first_row("COUNTER.BIN")
if pr is None or cr is None:
    sys.exit("FAIL: monitor running rows absent")
pt = re.search(r".*task=([0-9]+).*", pr)
ct = re.search(r".*task=([0-9]+).*", cr)
ps = re.search(r".*stack=0x([0-9a-f]{16}).*", pr)
cs = re.search(r".*stack=0x([0-9a-f]{16}).*", cr)
if not pt or not ct or pt.group(1) == ct.group(1):
    sys.exit("FAIL: task ids not distinct")
if not ps or not cs or ps.group(1) == cs.group(1):
    sys.exit("FAIL: stack VAs not distinct")
# Flow semantic: live both ways (>= 2 distinct each), echoes >= 90%
# of sends; each program writes its complete marker in one sys_write
# so SMP scheduler output cannot split the prefix from the payload.
# No echo beyond the last send.
sends = sorted({int(m.group(1)) for m in
                (re.search(r"ipc: ping ([0-9]+)", l) for l in lines) if m})
echoes = sorted({int(m.group(1)) for m in
                 (re.search(r"peer: got ping ([0-9]+)", l) for l in lines) if m})
if not sends or not echoes or len(echoes) < 2:
    sys.exit("FAIL: flow too thin sends=%d echoes=%d" % (len(sends), len(echoes)))
print("procs-syscall flow: sends=%d echoes=%d ratio=%.2f%% (min 90%%)" %
      (len(sends), len(echoes), 100 * len(echoes) / len(sends)))
if len(echoes) * 10 < len(sends) * 9:
    sys.exit("FAIL: echo ratio off echoes=%d sends=%d" % (len(echoes), len(sends)))
if echoes[-1] > sends[-1]:
    sys.exit("FAIL: echo beyond last send")
# Both STILL running; neither ever exited (exact-zero counts).
if first_row("PEER.BIN") is None or first_row("COUNTER.BIN") is None:
    sys.exit("FAIL: final running rows absent")
if (sum(1 for l in lines if re.search(r"name=PEER\.BIN uid=\d+ caps=\d+ state=exited", l)) != 0 or
        sum(1 for l in lines if re.search(r"name=COUNTER\.BIN uid=\d+ caps=\d+ state=exited", l)) != 0):
    sys.exit("FAIL: a party exited")
print("procs-syscall snapshot + flow ok")
PY
