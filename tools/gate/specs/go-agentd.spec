# go-agentd.spec -- M98 (#2145, ADR 0044) class-B: the agent control
# channel. Run 01 is the full AC4/AC5 journey on a live seat: HMAC
# handshake, all six verbs green, the whole in-session D4 refusal matrix,
# the gosh.run kill path, and a second peer's SYN refused while the
# session stays intact. Runs 02-04 are the D2 auth negatives (bad MAC,
# pre-auth verb, mute client); run 05 is --allow-exec off; runs 06-08 are
# the startup posture refusals (privileged, no credential, no sandbox
# root). Every run asserts the never-logged sentinels.
#
# The key is the pinned-vector ASCII 'a5' x 32; it reaches the harness
# through $RUN_DIR/agent.key, never argv. AGENT/SEED.TXT and the
# HELLO.TXT expectation are imported from tools/agentctl/agentctl.py so
# the fixture lives in one place.
#
# Runs 07/08 need a DIFFERENT share (no agent-hmac row / no AGENT/
# directory). A later --cvc-file in a run's own flags overrides the armed
# share for that boot only (VMRunner takes the last assignment), which is
# how one spec covers the two absent-resource postures.
#
# Run 01 stages GOCALC LAST for the task pool: scheduler.max_tasks is 16
# and a Go runtime holds ~4 slots (main + sysmon + startup Ms), so seat +
# Calc + agentd + a gosh.run child cannot coexist. The journey's
# gosh.run calls all land before ui.windows, so Calc execs when the
# first 'verb=ui.windows' marker prints -- the harness then polls
# ui.windows until the Calc row registers.
#
# ui.windows rides the M97g-F2 bind (owner ruling 2026-10-13): agentd
# opens its own undeclared window on the first call, walks the ownership
# challenge, and its bound kind-16 page requests quote the session
# token. The 'gotabwm: rpc bind id=' marker is the serial proof.
#
# HOST PREREQ:
#   bash tools/go/build-agentd.sh  -> .build/go/AGENTD.ELF
#   bash tools/go/build-gosh.sh    -> .build/go/GOSH.ELF
#   bash tools/go/build-gotabwm.sh -> .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh  -> .build/go/GOCALC.ELF

vgate_name go-agentd "M98 #2145: AGENTD.ELF JSONL+HMAC channel - six verbs, D4 matrix, fail-closed posture"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-seat.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTABWM.ELF
EOF

vgate_file script-calc.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
EOF

vgate_file script-agentd.txt <<'EOF'
exec AGENTD.ELF --allow-exec
EOF

vgate_file script-daemon.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec AGENTD.ELF
EOF

vgate_file script-u0.txt <<'EOF'
exec -u0 AGENTD.ELF
EOF

vgate_file script-posture.txt <<'EOF'
exec AGENTD.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
sys.path.insert(0, os.path.join("tools", "agentctl"))
import agentctl
for name, cmd in (
    ("AGENTD.ELF", "bash tools/go/build-agentd.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
    ("GOTABWM.ELF", "bash tools/go/build-gotabwm.sh"),
    ("GOCALC.ELF", "bash tools/go/build-gocalc.sh"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + cmd)
    shutil.copy(src, os.path.join(share, name))
# wm=none: the seat is exec'd explicitly (live-rfb pattern).
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
# The pinned-vector key (ASCII 'a5' x 32) app-bound to AGENTD.ELF; the
# image must be uid_system-owned with no non-owner write for the binding
# to be served (ADR 0024 D5/M97g).
KEY = "a5" * 32
secrets = "#v1\n" + "agent-hmac\t1000\t" + KEY + "\tAGENTD.ELF\n"
open(os.path.join(share, "SECRETS.TXT"), "w").write(secrets)
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nAGENTD.ELF\t644\t0\t-\n"
)
agent_dir = os.path.join(share, "AGENT")
os.makedirs(agent_dir, exist_ok=True)
open(os.path.join(agent_dir, "SEED.TXT"), "wb").write(agentctl.SEED_BYTES)
open(os.path.join(agent_dir, "BIG.BIN"), "wb").write(b"\x00" * 4097)
# The harness's key file (never argv) and the HELLO.TXT expectation.
open(os.path.join(run, "agent.key"), "w").write(KEY + "\n")
open(os.path.join(run, "hello-expect.txt"), "wb").write(agentctl.PAYLOAD)
open(os.path.join(run, "secrets-expect.txt"), "w").write(secrets)
# Run 07: a store with no agent-hmac row. Run 08: no AGENT/ directory.
# Each is a complete alternate share a run's own --cvc-file selects.
elf = os.path.join(".build", "go", "AGENTD.ELF")
for tag in ("nocred", "noroot"):
    alt = os.path.join(run, tag + "-share")
    os.makedirs(alt, exist_ok=True)
    shutil.copy(elf, os.path.join(alt, "AGENTD.ELF"))
    open(os.path.join(alt, "OWNERS.TXT"), "w").write(
        "#v1\nAGENTD.ELF\t644\t0\t-\n")
shutil.copy(os.path.join(share, "SECRETS.TXT"),
            os.path.join(run, "noroot-share", "SECRETS.TXT"))
os.makedirs(os.path.join(run, "nocred-share", "AGENT"), exist_ok=True)
open(os.path.join(run, "nocred-share", "SECRETS.TXT"), "w").write(
    "#v1\n")
print("staged agentd share (key %d bytes, seed %d bytes)"
      % (len(KEY), len(agentctl.SEED_BYTES)))
PY

# ---- 01: the full journey on a live seat -------------------------------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=full' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/agent.key' \
    --net-tcp-connect-intruder \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-agentd.txt' --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script-calc.txt' --script3-after 'verb=ui.windows' \
    --script-expect 'agentd: session end reason=line_too_long' \
    --script-expect-tail 4 --timeout 300

vgate_assert 01 serial-contains 'agentd: start exec=on'
vgate_assert 01 serial-contains 'agentd: listen 4747'
vgate_assert 01 serial-contains 'agentd: accepted'
vgate_assert 01 serial-contains 'agentd: auth ok'
vgate_assert 01 serial-contains 'agentd: req id='
vgate_assert 01 serial-contains 'verb=proc.list ok'
vgate_assert 01 serial-contains 'verb=ui.windows ok'
vgate_assert 01 serial-contains 'agentd: spawn pid='
vgate_assert 01 serial-contains 'agentd: reap pid='
vgate_assert 01 serial-contains 'code=path_rejected'
vgate_assert 01 serial-contains 'code=cmd_rejected'
vgate_assert 01 serial-contains 'code=unknown_verb'
vgate_assert 01 serial-contains 'code=timed_out'
vgate_assert 01 serial-contains 'agentd: session end reason=line_too_long'
vgate_assert 01 serial-contains 'gotabwm: wq start='
vgate_assert 01 serial-contains 'gotabwm: rpc bind id='
vgate_assert 01 output-contains 'NET-TCP-STREAM: ENABLED'
vgate_assert 01 output-contains 'NET-TCP-INTRUDER: sent a second SYN from port'
vgate_assert 01 output-contains 'AGENTCTL: PASS full'
vgate_assert 01 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 01 share-equals AGENT/HELLO.TXT hello-expect.txt
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 01 serial-absent 'agentctl-payload-sentinel-44'
vgate_assert 01 serial-absent 'agentctl-stdout-sentinel-44'
vgate_assert 01 serial-absent 'agentd: auth fail'
vgate_assert 01 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
for secret in (
    "a5" * 32,
    "agentctl-payload-sentinel-44",
    "agentctl-stdout-sentinel-44",
):
    if secret in out:
        sys.exit("FAIL: a never-logged value reached the runner output")
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
names = set(os.listdir(os.path.join(share, "AGENT")))
if names != {"SEED.TXT", "BIG.BIN", "HELLO.TXT"}:
    sys.exit("FAIL: AGENT/ listing drifted: %r" % sorted(names))
if os.path.exists(os.path.join(share, "AGENTD.OUT")):
    sys.exit("FAIL: AGENTD.OUT was left on the share")
have = open(os.path.join(share, "SECRETS.TXT"), "rb").read()
want = open(os.path.join(run, "secrets-expect.txt"), "rb").read()
if have != want:
    sys.exit("FAIL: SECRETS.TXT changed on the share")
print("run-01 share hygiene ok")
PY

# ---- 02: wrong MAC -> auth_failed, damped relisten ----------------------------
# Runs 02-03 assert probe status=1 on purpose: the harness exits hard after
# a refused session (the peer-vanished shape), which the runner answers
# with RST -- the frame that releases the guest's one-socket machine back
# to .listen so the second 'agentd: listen 4747' lands inside the tail.
vgate_run 02 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=badmac' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/agent.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=auth_failed' \
    --script-expect-tail 8 --timeout 150

vgate_assert 02 serial-contains 'agentd: accepted'
vgate_assert 02 serial-contains 'agentd: auth fail reason=mac'
vgate_assert 02 serial-contains 'agentd: session end reason=auth_failed'
vgate_assert 02 serial-count 'agentd: listen 4747' 2
vgate_assert 02 serial-absent 'agentd: auth ok'
vgate_assert 02 serial-absent 'agentd: req id='
vgate_assert 02 output-contains 'AGENTCTL: PASS badmac'
vgate_assert 02 output-contains 'NET-TCP-STREAM: probe exited status=1'
vgate_assert 02 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 02 serial-absent '[EXC] parking:'

# ---- 03: a verb first -> auth_required ---------------------------------------
vgate_run 03 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=preauth' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/agent.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=auth_required' \
    --script-expect-tail 3 --timeout 150

vgate_assert 03 serial-contains 'agentd: auth fail reason=preauth'
vgate_assert 03 serial-contains 'agentd: session end reason=auth_required'
vgate_assert 03 serial-absent 'agentd: auth ok'
vgate_assert 03 serial-absent 'agentd: req id='
vgate_assert 03 output-contains 'AGENTCTL: PASS preauth'
vgate_assert 03 output-contains 'NET-TCP-STREAM: probe exited status=1'
vgate_assert 03 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 03 serial-absent '[EXC] parking:'

# ---- 04: a silent client -> auth_timeout inside 15 s --------------------------
vgate_run 04 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=mute' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/agent.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=auth_timeout' \
    --script-expect-tail 3 --timeout 180

vgate_assert 04 serial-contains 'agentd: auth fail reason=timeout'
vgate_assert 04 serial-contains 'agentd: session end reason=auth_timeout'
vgate_assert 04 serial-absent 'agentd: auth ok'
vgate_assert 04 serial-absent 'agentd: req id='
vgate_assert 04 output-contains 'AGENTCTL: ok auth-timeout'
vgate_assert 04 output-contains 'AGENTCTL: PASS mute'
vgate_assert 04 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 04 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 04 serial-absent '[EXC] parking:'

# ---- 05: no --allow-exec, no seat ---------------------------------------------
vgate_run 05 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=noexec' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/agent.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 3 --timeout 150

vgate_assert 05 serial-contains 'agentd: start exec=off'
vgate_assert 05 serial-contains 'agentd: auth ok'
vgate_assert 05 serial-contains 'verb=gosh.run code=verb_disabled'
vgate_assert 05 serial-absent 'agentd: spawn pid='
vgate_assert 05 output-contains 'AGENTCTL: PASS noexec'
vgate_assert 05 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 05 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 05 serial-absent '[EXC] parking:'

# ---- 06: exec -u0 refuses privileged before any Listen ------------------------
vgate_run 06 -- \
    --script '$RUN_DIR/script-u0.txt' \
    --script-expect 'agentd: refuse privileged' \
    --script-expect-tail 2 --timeout 120

vgate_assert 06 serial-contains 'agentd: refuse privileged'
vgate_assert 06 serial-absent 'agentd: start exec='
vgate_assert 06 serial-absent 'agentd: listen 4747'
vgate_assert 06 serial-absent 'agentd: req id='
vgate_assert 06 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 06 serial-absent '[EXC] parking:'

# ---- 07: no agent-hmac row refuses before any Listen --------------------------
vgate_run 07 -- \
    --cvc-file '$RUN_DIR/nocred-share' \
    --script '$RUN_DIR/script-posture.txt' \
    --script-expect 'agentd: refuse no-credential' \
    --script-expect-tail 2 --timeout 120

vgate_assert 07 serial-contains 'agentd: refuse no-credential'
vgate_assert 07 serial-absent 'agentd: start exec='
vgate_assert 07 serial-absent 'agentd: listen 4747'
vgate_assert 07 serial-absent 'agentd: req id='
vgate_assert 07 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 07 serial-absent '[EXC] parking:'

# ---- 08: no AGENT/ directory refuses before any Listen ------------------------
vgate_run 08 -- \
    --cvc-file '$RUN_DIR/noroot-share' \
    --script '$RUN_DIR/script-posture.txt' \
    --script-expect 'agentd: refuse no-root' \
    --script-expect-tail 2 --timeout 120

vgate_assert 08 serial-contains 'agentd: refuse no-root'
vgate_assert 08 serial-absent 'agentd: start exec='
vgate_assert 08 serial-absent 'agentd: listen 4747'
vgate_assert 08 serial-absent 'agentd: req id='
vgate_assert 08 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 08 serial-absent '[EXC] parking:'
