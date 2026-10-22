# go-agentd.spec -- M98 (#2145, ADR 0044) + M109b (#2398, ADR 0052)
# + M109c (#2399, ADR 0052 D4): the audit trail. Every dispatch — allowed
# and refused — plus each auth outcome and session open/close leaves a
# MAC'd RCPT-<epoch>-<seq> file in AGENT/AUDIT/, and the python legs below
# verify those receipts on the share against the pinned agent-hmac row
# (the M108 lane shape: one record per file, bounded, signed).
# class-B: the agent control channel. Run 01 is the full journey on a
# live seat under virelai-agent/2: the Ed25519 handshake names agent
# devin, all seven verbs green (fs depth, streamed gosh.run, the
# ui.screenshot stream), the whole in-session refusal matrix, the
# gosh.run kill path, and a second peer's SYN refused while the session
# stays intact. Runs 02-04 are the auth negatives (bad signature,
# pre-auth verb, mute client); run 05 is --allow-exec off with no seat
# (verb_disabled + seat_absent); runs 06-08 are the v1 startup postures
# (privileged, no credential, no sandbox root). Run 09 is the cap-absent
# negative: viewer declares process only, every other verb refuses
# cap_required:<cap>. Run 10 is the revoked-credential negative
# (agent_revoked), run 11 the unknown-id negative (agent_unknown).
# Runs 12-14 are the new ADR 0052 D1 postures: no AGENTS.TXT
# (no-keyring), an unparseable keyring (keyring-malformed), and no
# AGENT/AUDIT lane (no-audit). Every run asserts the never-logged
# sentinels. Run 15 is M139b (#2780): the `input` journey — ui.input
# types "hi" and clicks into the focused GOEDIT pane over WM_RPC
# kind 29, the next ui.screenshot sees the repaint, and the named
# refusals (agent_input_no_focus, too_large, bad_request) land. Run 16
# is #2977: ui.screenshot scale=1 streams the full 1280x720 RGB565 frame
# through slot-88 12-row bands under a per-session 2 s rate bound, and
# the spec's python diffs it downsampled against the scale=8 capture.
# Run 17 is #2985: the `geom` journey — ui.geometry query over a two-pane
# split (each answer diffed against the seat's `gotabwm: layout` lines),
# sash percent=30, and move to space 1 over WM_RPC kind 30. Run 18 is
# the `geom-deny` leg: watcher declares `window` only, so query serves
# while move/sash refuse cap_required:input, and WMRPCPROBE.ELF's bound
# kind-30 frame hears win_geometry_denied from the seat itself.
#
# The agent credentials are three pinned Ed25519 seeds; each reaches its
# harness through $RUN_DIR/<agent>.key (agent id + seed hex, never argv)
# and the PUBLIC halves reach the guest in AGENTS.TXT (world-readable by
# design — private keys never enter the VM, ADR 0052 D1). The legacy
# agent-hmac row stays app-bound to AGENTD.ELF: posture check 2 keeps it
# as the no-credential probe (it is the M109c receipt key, not the door
# key). AGENT/SEED.TXT, SUB/DEEP.TXT, WIDE.TXT and the HELLO/NEW
# expectations are imported from tools/agentctl/agentctl.py so the
# fixtures live in one place.
#
# Runs 07/08/12/13/14 need DIFFERENT shares (no agent-hmac row / no
# AGENT/ / no AGENTS.TXT / a malformed keyring / no AUDIT lane). A later
# --cvc-file in a run's own flags overrides the armed share for that
# boot only, which is how one spec covers every absent-resource posture.
#
# Run 01 stages GOCALC LAST for the task pool: scheduler.max_tasks was 16
# (64 after M129b / #2611) and a Go runtime holds ~4 slots (main + sysmon
# + startup Ms), so seat + Calc + agentd + a gosh.run child could not
# coexist. The journey's
# gosh.run calls all land before ui.windows, so Calc execs when the
# first 'verb=ui.windows' marker prints -- the harness then polls
# ui.windows until the Calc row registers, and ui.screenshot runs after
# the focused Calc is up.
#
# ui.windows rides the M97g-F2 bind (owner ruling 2026-10-13): agentd
# opens its own undeclared window on the first call, walks the ownership
# challenge, and its bound kind-16 page requests quote the session
# token. The 'gotabwm: rpc bind id=' marker is the serial proof.
#
# ui.screenshot rides slot 88 sys_scanout_read (ADR 0007 amendment,
# M109b): a bounded read-only scanout copy through uaccess; the verb
# refuses seat_absent when no seat is registered before touching it.
#
# HOST PREREQ:
#   bash tools/go/build-agentd.sh  -> .build/go/AGENTD.ELF
#   bash tools/go/build-gosh.sh    -> .build/go/GOSH.ELF
#   bash tools/go/build-gotabwm.sh -> .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh  -> .build/go/GOCALC.ELF
#   bash tools/go/build-goedit.sh  -> .build/go/GOEDIT.ELF

vgate_name go-agentd "M109b #2398: AGENTD.ELF v2 - Ed25519 identity, declared caps, bounded verbs"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-seat.txt <<'EOF'
vf rm SESSION.TABS
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTABWM.ELF
EOF

vgate_file script-calc.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
EOF

vgate_file script-edit.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF
EOF

# Run 17 needs two apps to split: both exec on the same trigger.
vgate_file script-two.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec GOEDIT.ELF
EOF

# Run 18's deny leg: GOCALC is the query target, WMRPCPROBE is the
# in-guest non-AGENTD sender whose bound kind-30 frame must hear
# win_geometry_denied.
vgate_file script-probe.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec WMRPCPROBE.ELF
EOF

vgate_file script-agentd.txt <<'EOF'
exec -u2000 AGENTD.ELF --allow-exec
EOF

vgate_file script-daemon.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec -u2000 AGENTD.ELF
EOF

vgate_file script-u0.txt <<'EOF'
exec -u0 AGENTD.ELF
EOF

vgate_file script-posture.txt <<'EOF'
exec -u2000 AGENTD.ELF
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
    ("GOEDIT.ELF", "bash tools/go/build-goedit.sh"),
    ("WMRPCPROBE.ELF", "bash tools/go/build-web.sh wmrpcprobe WMRPCPROBE"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + cmd)
    shutil.copy(src, os.path.join(share, name))
# wm=none: the seat is exec'd explicitly (live-rfb pattern).
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
# The four pinned agents: devin holds every cap, viewer process only,
# bobby is listed AND revoked (revocation wins over listing, ADR 0052 D1),
# watcher window only (run 18's cap-split leg).
SEEDS = {"devin": "0a" * 32, "viewer": "0b" * 32, "bobby": "0c" * 32,
         "watcher": "0d" * 32}
PUBS = {a: agentctl.ed_public_key(bytes.fromhex(s)).hex()
        for a, s in SEEDS.items()}
agents_txt = (
    "#v1\n"
    "agent=devin key=%s caps=file,process,window,term,input\n" % PUBS["devin"]
    + "agent=viewer key=%s caps=process\n" % PUBS["viewer"]
    + "agent=bobby key=%s caps=file\n" % PUBS["bobby"]
    + "revoked=%s\n" % PUBS["bobby"]
    + "agent=watcher key=%s caps=window\n" % PUBS["watcher"]
)
open(os.path.join(share, "AGENTS.TXT"), "w").write(agents_txt)
# The pinned-vector secret (ASCII 'a5' x 32) app-bound to AGENTD.ELF and
# GOTOP.ELF (ADR 0052 D4 — the allowlist widened when the viewer landed);
# the image must be uid_system-owned with no non-owner write for the
# binding to be served (ADR 0024 D5/M97g). agent-hmac is the M109c
# receipt key + the no-credential posture probe — the door key is
# Ed25519 now.
KEY = "a5" * 32
secrets = "#v1\n" + "agent-hmac\t2000\t" + KEY + "\tAGENTD.ELF,GOTOP.ELF\n"
open(os.path.join(share, "SECRETS.TXT"), "w").write(secrets)
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nAGENTD.ELF\t644\t0\t-\nAGENTS.TXT\t444\t0\t-\n"
)
agent_dir = os.path.join(share, "AGENT")
os.makedirs(agent_dir, exist_ok=True)
os.makedirs(os.path.join(agent_dir, "AUDIT"), exist_ok=True)
os.makedirs(os.path.join(agent_dir, "SUB"), exist_ok=True)
# M139b run 15: GOEDIT's defaultPath is /host/EDIT/SEED.TXT — the typed
# text splices into the buffer but is never saved, so the share file
# stays at its staged bytes.
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
open(os.path.join(ed, "SEED.TXT"), "wb").write(b"seed-line\n")
open(os.path.join(agent_dir, "SEED.TXT"), "wb").write(agentctl.SEED_BYTES)
open(os.path.join(agent_dir, "BIG.BIN"), "wb").write(b"\x00" * 4097)
open(os.path.join(agent_dir, "SUB", "DEEP.TXT"), "wb").write(agentctl.DEEP_BYTES)
open(os.path.join(agent_dir, "WIDE.TXT"), "wb").write(agentctl.wide_bytes())
# The harness key files (never argv) and the file-content expectations.
for agent, seed in SEEDS.items():
    open(os.path.join(run, agent + ".key"), "w").write(agent + " " + seed + "\n")
open(os.path.join(run, "hello-expect.txt"), "wb").write(agentctl.PAYLOAD)
open(os.path.join(run, "nested-expect.txt"), "wb").write(agentctl.NESTED_PAYLOAD)
open(os.path.join(run, "secrets-expect.txt"), "w").write(secrets)
open(os.path.join(run, "agents-expect.txt"), "w").write(agents_txt)
# The posture legs each get a complete alternate share a run's own
# --cvc-file selects: 07 no agent-hmac row, 08 no AGENT/, 12 no
# AGENTS.TXT, 13 a malformed keyring, 14 no AGENT/AUDIT lane. Every leg
# keeps everything else in place so exactly one check fires.
elf = os.path.join(".build", "go", "AGENTD.ELF")


def stage_alt(tag, secrets_rows, agents, agent_files, audit):
    alt = os.path.join(run, tag + "-share")
    os.makedirs(alt, exist_ok=True)
    shutil.copy(elf, os.path.join(alt, "AGENTD.ELF"))
    own = "#v1\nAGENTD.ELF\t644\t0\t-\n"
    if agents is not None:
        own += "AGENTS.TXT\t444\t0\t-\n"
        open(os.path.join(alt, "AGENTS.TXT"), "w").write(agents)
    open(os.path.join(alt, "OWNERS.TXT"), "w").write(own)
    open(os.path.join(alt, "SECRETS.TXT"), "w").write(secrets_rows)
    if agent_files is not None:
        ad = os.path.join(alt, "AGENT")
        os.makedirs(ad, exist_ok=True)
        for rel, body in agent_files:
            dst = os.path.join(ad, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            open(dst, "wb").write(body)
        if audit:
            os.makedirs(os.path.join(ad, "AUDIT"), exist_ok=True)
    return alt


base_files = [("SEED.TXT", agentctl.SEED_BYTES),
              ("SUB/DEEP.TXT", agentctl.DEEP_BYTES)]
stage_alt("nocred", "#v1\n", agents_txt, base_files, audit=True)
stage_alt("noroot", secrets, agents_txt, None, audit=False)
stage_alt("nokeyring", secrets, None, base_files, audit=True)
stage_alt("badkeyring", secrets, "this is not a keyring\n", base_files, audit=True)
stage_alt("noaudit", secrets, agents_txt, base_files, audit=False)
print("staged agentd share (3 agents, seed %d bytes)" % len(agentctl.SEED_BYTES))
PY

# ---- 01: the full journey on a live seat -------------------------------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=full' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
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
vgate_assert 01 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 01 serial-contains 'agentd: req id='
vgate_assert 01 serial-contains 'verb=proc.list ok'
vgate_assert 01 serial-contains 'verb=ui.windows ok'
vgate_assert 01 serial-contains 'verb=ui.screenshot ok'
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
vgate_assert 01 output-contains 'AGENTCTL: ok fs-depth'
vgate_assert 01 output-contains 'AGENTCTL: ok gosh-stream'
vgate_assert 01 output-contains 'AGENTCTL: ok ui.screenshot'
vgate_assert 01 output-contains 'AGENTCTL: PASS full'
vgate_assert 01 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 01 share-equals AGENT/HELLO.TXT hello-expect.txt
vgate_assert 01 share-equals AGENT/SUB/NEW.TXT nested-expect.txt
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 01 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 01 serial-absent 'agentctl-payload-sentinel-44'
vgate_assert 01 serial-absent 'agentctl-stdout-sentinel-44'
vgate_assert 01 serial-absent 'agentd: auth fail'
vgate_assert 01 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
for secret in (
    "a5" * 32, "0a" * 32, "0b" * 32, "0c" * 32,
    "agentctl-payload-sentinel-44",
    "agentctl-stdout-sentinel-44",
    "agentctl-nested-payload-sentinel-52",
):
    if secret in out:
        sys.exit("FAIL: a never-logged value reached the runner output")
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
names = set(os.listdir(os.path.join(share, "AGENT")))
if names != {"SEED.TXT", "BIG.BIN", "HELLO.TXT", "WIDE.TXT", "SUB", "AUDIT"}:
    sys.exit("FAIL: AGENT/ listing drifted: %r" % sorted(names))
sub = set(os.listdir(os.path.join(share, "AGENT", "SUB")))
if sub != {"DEEP.TXT", "NEW.TXT"}:
    sys.exit("FAIL: AGENT/SUB listing drifted: %r" % sorted(sub))
if os.path.exists(os.path.join(share, "AGENTD.OUT")):
    sys.exit("FAIL: AGENTD.OUT was left on the share")
have = open(os.path.join(share, "SECRETS.TXT"), "rb").read()
want = open(os.path.join(run, "secrets-expect.txt"), "rb").read()
if have != want:
    sys.exit("FAIL: SECRETS.TXT changed on the share")
have = open(os.path.join(share, "AGENTS.TXT"), "rb").read()
want = open(os.path.join(run, "agents-expect.txt"), "rb").read()
if have != want:
    sys.exit("FAIL: AGENTS.TXT changed on the share")
print("run-01 share hygiene ok")
PY

# M109c: the journey's dispatch receipts land in AGENT/AUDIT/ — allowed
# and refused alike, every one MAC-verified under the agent-hmac row, and
# no payload bytes (size+sha256_8 only; the cmd text exception is the
# ADR's own). The lane caps at 64 files, so asserts are set-membership,
# not counts.
vgate_assert 01 python <<'PY'
import hashlib, hmac, json, os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
adir = os.path.join(share, "AGENT", "AUDIT")
names = sorted(n for n in os.listdir(adir)
               if n.startswith("RCPT-") and not n.endswith("~"))
if not names:
    sys.exit("FAIL: no receipts in AGENT/AUDIT: %r" % os.listdir(adir))
if len(names) > 64:
    sys.exit("FAIL: audit bound exceeded: %d files" % len(names))
KEY = b"a5" * 32
seen = set()
for n in names:
    body = open(os.path.join(adir, n), "rb").read()
    if b"agentctl-payload-sentinel-44" in body or b"agentctl-nested-payload-sentinel-52" in body:
        sys.exit("FAIL: payload bytes reached receipt %s" % n)
    lines = body.split(b"\n")
    if len(lines) != 3 or lines[2] != b"":
        sys.exit("FAIL: receipt %s is not two lines" % n)
    want = hmac.new(KEY, lines[0], hashlib.sha256).hexdigest().encode()
    if lines[1] != want:
        sys.exit("FAIL: receipt %s MAC mismatch" % n)
    r = json.loads(lines[0])
    seen.add((r.get("agent"), r.get("verb"), r.get("result")))
for need in (
    ("devin", "fs.write", "ok"),
    ("devin", "fs.read", "path_rejected"),
    ("devin", "gosh.run", "timed_out"),
):
    if need not in seen:
        sys.exit("FAIL: no %r receipt; saw %r" % (need, sorted(seen)))
if not any(a == "devin" and v == "session" for a, v, _ in seen):
    sys.exit("FAIL: no session-frame receipt; saw %r" % sorted(seen))
if not any(r == "unknown_verb" for _, _, r in seen):
    sys.exit("FAIL: no unknown_verb receipt; saw %r" % sorted(seen))
print("run-01 audit ok: %d receipts, all MAC'd, refusals included" % len(names))
PY

# ---- 02: wrong signature -> auth_failed, damped relisten ----------------------
# Runs 02-03 assert probe status=1 on purpose: the harness exits hard after
# a refused session (the peer-vanished shape), which the runner answers
# with RST -- the frame that releases the guest's socket machine back to
# .listen so the second 'agentd: listen 4747' lands inside the tail.
vgate_run 02 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=badsig' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=auth_failed' \
    --script-expect-tail 8 --timeout 150

vgate_assert 02 serial-contains 'agentd: accepted'
vgate_assert 02 serial-contains 'agentd: auth fail reason=sig'
vgate_assert 02 serial-contains 'agentd: session end reason=auth_failed'
vgate_assert 02 serial-count 'agentd: listen 4747' 2
vgate_assert 02 serial-absent 'agentd: auth ok'
vgate_assert 02 serial-absent 'agentd: req id='
vgate_assert 02 output-contains 'AGENTCTL: PASS badsig'
vgate_assert 02 output-contains 'NET-TCP-STREAM: probe exited status=1'
vgate_assert 02 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 02 serial-absent '[EXC] parking:'

# ---- 03: a verb first -> auth_required ---------------------------------------
vgate_run 03 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=preauth' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
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
vgate_assert 03 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 03 serial-absent '[EXC] parking:'

# ---- 04: a silent client -> auth_timeout inside 15 s --------------------------
vgate_run 04 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=mute' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
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
vgate_assert 04 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 04 serial-absent '[EXC] parking:'

# ---- 05: no --allow-exec, no seat ---------------------------------------------
vgate_run 05 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=noexec' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 3 --timeout 150

vgate_assert 05 serial-contains 'agentd: start exec=off'
vgate_assert 05 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 05 serial-contains 'verb=gosh.run code=verb_disabled'
vgate_assert 05 serial-contains 'verb=ui.screenshot code=seat_absent'
vgate_assert 05 serial-absent 'agentd: spawn pid='
vgate_assert 05 output-contains 'AGENTCTL: PASS noexec'
vgate_assert 05 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 05 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
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
vgate_assert 06 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
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
vgate_assert 07 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
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
vgate_assert 08 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 08 serial-absent '[EXC] parking:'

# ---- 09: caps resolved per session — cap-absent negative per verb -------------
# viewer declares `process` only: the ready line advertises just the proc
# verbs, each other verb refuses cap_required:<cap> by name, and the one
# held cap still serves.
vgate_run 09 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=capsneg' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/viewer.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 3 --timeout 150

vgate_assert 09 serial-contains 'agentd: auth ok agent=viewer'
vgate_assert 09 serial-contains 'verb=proc.list ok'
vgate_assert 09 serial-contains 'verb=fs.read code=cap_required'
vgate_assert 09 serial-contains 'verb=fs.write code=cap_required'
vgate_assert 09 serial-contains 'verb=ui.windows code=cap_required'
vgate_assert 09 serial-contains 'verb=ui.screenshot code=cap_required'
vgate_assert 09 serial-contains 'verb=ui.input code=cap_required'
vgate_assert 09 serial-contains 'verb=gosh.run code=cap_required'
vgate_assert 09 output-contains 'AGENTCTL: PASS capsneg'
vgate_assert 09 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 09 serial-absent '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'
vgate_assert 09 serial-absent '[EXC] parking:'

# M109c: the cap-absent refusals are receipted too — viewer's session on a
# small share (no rotation) shows open, the allowed proc.list, the five
# named cap_required results, and the close, all MAC-verified.
vgate_assert 09 python <<'PY2'
import hashlib, hmac, json, os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
adir = os.path.join(share, "AGENT", "AUDIT")
names = sorted(n for n in os.listdir(adir) if n.startswith("RCPT-"))
if not names:
    sys.exit("FAIL: no receipts in AGENT/AUDIT")
KEY = b"a5" * 32
seen = set()
for n in names:
    body = open(os.path.join(adir, n), "rb").read().split(b"\n")
    if len(body) != 3 or body[1] != hmac.new(KEY, body[0], hashlib.sha256).hexdigest().encode():
        sys.exit("FAIL: receipt %s malformed or MAC-bad" % n)
    r = json.loads(body[0])
    seen.add((r.get("agent"), r.get("verb"), r.get("result")))
for need in (
    ("-", "session", "ok"),
    ("viewer", "proc.list", "ok"),
    ("viewer", "fs.read", "cap_required:file"),
    ("viewer", "fs.write", "cap_required:file"),
    ("viewer", "ui.windows", "cap_required:window"),
    ("viewer", "ui.screenshot", "cap_required:window"),
    ("viewer", "ui.input", "cap_required:input"),
    ("viewer", "gosh.run", "cap_required:term"),
    ("viewer", "session", "client_close"),
):
    if need not in seen:
        sys.exit("FAIL: no %r receipt; saw %r" % (need, sorted(seen)))
print("run-09 audit ok: %d receipts incl. the cap_required matrix" % len(names))
PY2

# ---- 10: a revoked credential refuses by name --------------------------------
# bobby's row is listed AND revoked: the signature is valid under the
# listed key and still refused agent_revoked — revocation wins over
# listing (ADR 0052 D1/D2).
vgate_run 10 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=revoked' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/bobby.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=agent_revoked' \
    --script-expect-tail 8 --timeout 150

vgate_assert 10 serial-contains 'agentd: accepted'
vgate_assert 10 serial-contains 'agentd: auth fail reason=agent_revoked'
vgate_assert 10 serial-contains 'agentd: session end reason=agent_revoked'
vgate_assert 10 serial-count 'agentd: listen 4747' 2
vgate_assert 10 serial-absent 'agentd: auth ok'
vgate_assert 10 serial-absent 'agentd: req id='
vgate_assert 10 output-contains 'AGENTCTL: PASS revoked'
vgate_assert 10 output-contains 'NET-TCP-STREAM: probe exited status=1'
vgate_assert 10 serial-absent '0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c'
vgate_assert 10 serial-absent '[EXC] parking:'

# M109c: a refused credential is receipted by name — the claimed agent id
# and its agent_revoked verdict are on the share, MAC-verified.
vgate_assert 10 python <<'PY2'
import hashlib, hmac, json, os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
adir = os.path.join(share, "AGENT", "AUDIT")
names = sorted(n for n in os.listdir(adir) if n.startswith("RCPT-"))
KEY = b"a5" * 32
seen = set()
for n in names:
    body = open(os.path.join(adir, n), "rb").read().split(b"\n")
    if len(body) != 3 or body[1] != hmac.new(KEY, body[0], hashlib.sha256).hexdigest().encode():
        sys.exit("FAIL: receipt %s malformed or MAC-bad" % n)
    r = json.loads(body[0])
    ev = (r.get("args") or {}).get("event", "")
    seen.add((r.get("agent"), r.get("verb"), ev, r.get("result")))
if ("bobby", "session", "auth_fail", "agent_revoked") not in seen:
    sys.exit("FAIL: no bobby agent_revoked receipt; saw %r" % sorted(seen))
print("run-10 audit ok: revoked credential receipted by name")
PY2

# ---- 11: an unlisted id refuses by name ---------------------------------------
vgate_run 11 -- \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=unknown' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-daemon.txt' \
    --script-expect 'agentd: session end reason=agent_unknown' \
    --script-expect-tail 8 --timeout 150

vgate_assert 11 serial-contains 'agentd: accepted'
vgate_assert 11 serial-contains 'agentd: auth fail reason=agent_unknown'
vgate_assert 11 serial-contains 'agentd: session end reason=agent_unknown'
vgate_assert 11 serial-count 'agentd: listen 4747' 2
vgate_assert 11 serial-absent 'agentd: auth ok'
vgate_assert 11 serial-absent 'agentd: req id='
vgate_assert 11 output-contains 'AGENTCTL: PASS unknown'
vgate_assert 11 output-contains 'NET-TCP-STREAM: probe exited status=1'
vgate_assert 11 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 11 serial-absent '[EXC] parking:'

# M109c: an unlisted id is receipted by the name it claimed.
vgate_assert 11 python <<'PY2'
import hashlib, hmac, json, os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
adir = os.path.join(share, "AGENT", "AUDIT")
names = sorted(n for n in os.listdir(adir) if n.startswith("RCPT-"))
KEY = b"a5" * 32
seen = set()
for n in names:
    body = open(os.path.join(adir, n), "rb").read().split(b"\n")
    if len(body) != 3 or body[1] != hmac.new(KEY, body[0], hashlib.sha256).hexdigest().encode():
        sys.exit("FAIL: receipt %s malformed or MAC-bad" % n)
    r = json.loads(body[0])
    ev = (r.get("args") or {}).get("event", "")
    seen.add((r.get("agent"), r.get("verb"), ev, r.get("result")))
if ("mallory", "session", "auth_fail", "agent_unknown") not in seen:
    sys.exit("FAIL: no mallory agent_unknown receipt; saw %r" % sorted(seen))
print("run-11 audit ok: unknown id receipted by claimed name")
PY2

# ---- 12: no AGENTS.TXT refuses no-keyring before any Listen -------------------
vgate_run 12 -- \
    --cvc-file '$RUN_DIR/nokeyring-share' \
    --script '$RUN_DIR/script-posture.txt' \
    --script-expect 'agentd: refuse no-keyring' \
    --script-expect-tail 2 --timeout 120

vgate_assert 12 serial-contains 'agentd: refuse no-keyring'
vgate_assert 12 serial-absent 'agentd: start exec='
vgate_assert 12 serial-absent 'agentd: listen 4747'
vgate_assert 12 serial-absent 'agentd: req id='
vgate_assert 12 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 12 serial-absent '[EXC] parking:'

# ---- 13: an unparseable keyring refuses keyring-malformed ---------------------
vgate_run 13 -- \
    --cvc-file '$RUN_DIR/badkeyring-share' \
    --script '$RUN_DIR/script-posture.txt' \
    --script-expect 'agentd: refuse keyring-malformed' \
    --script-expect-tail 2 --timeout 120

vgate_assert 13 serial-contains 'agentd: refuse keyring-malformed'
vgate_assert 13 serial-absent 'agentd: start exec='
vgate_assert 13 serial-absent 'agentd: listen 4747'
vgate_assert 13 serial-absent 'agentd: req id='
vgate_assert 13 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 13 serial-absent '[EXC] parking:'

# ---- 14: no AGENT/AUDIT lane refuses no-audit before any Listen ---------------
vgate_run 14 -- \
    --cvc-file '$RUN_DIR/noaudit-share' \
    --script '$RUN_DIR/script-posture.txt' \
    --script-expect 'agentd: refuse no-audit' \
    --script-expect-tail 2 --timeout 120

vgate_assert 14 serial-contains 'agentd: refuse no-audit'
vgate_assert 14 serial-absent 'agentd: start exec='
vgate_assert 14 serial-absent 'agentd: listen 4747'
vgate_assert 14 serial-absent 'agentd: req id='
vgate_assert 14 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 14 serial-absent '[EXC] parking:'

# ---- 15: M139b — ui.input drives the focused pane ------------------------------
# devin now declares `input` (AGENTS.TXT above). GOEDIT execs after the
# first ui.windows request — the task-pool staging run 01 uses — and the
# input journey types "hi" plus a click into the focused Edit pane over
# kind-29, then re-shoots the framebuffer: the repaint (the status row's
# dirty `*` and the inserted glyphs) IS the pixels-changed proof. The
# reds assert the seat's refusal name verbatim (agent_input_no_focus for
# a non-focused win), the 64-event bound (too_large), and the malformed
# shapes (bad_request).
vgate_run 15 -- \
    --screen '$RUN_DIR/screen-15' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=input' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-agentd.txt' --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script-edit.txt' --script3-after 'verb=ui.windows' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 4 --timeout 300

vgate_assert 15 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 15 serial-contains 'verb=ui.windows ok'
vgate_assert 15 serial-contains 'verb=ui.input ok'
vgate_assert 15 serial-contains 'verb=ui.screenshot ok'
vgate_assert 15 serial-contains 'code=agent_input_no_focus'
vgate_assert 15 serial-contains 'code=too_large'
vgate_assert 15 serial-contains 'code=bad_request'
vgate_assert 15 serial-contains 'gotabwm: agent-input'
vgate_assert 15 serial-contains 'gotabwm: rpc bind id='
vgate_assert 15 serial-contains 'goedit: present'
vgate_assert 15 serial-contains 'goedit: dirty'
vgate_assert 15 output-contains 'AGENTCTL: PASS input'
vgate_assert 15 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 15 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 15 serial-absent '[EXC] parking:'

# M139b: the ui.input dispatches are receipted — the applied batch AND
# the named refusals — and the receipts carry win/events only, never the
# event bytes.
vgate_assert 15 python <<'PY2'
import hashlib, hmac, json, os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
adir = os.path.join(share, "AGENT", "AUDIT")
names = sorted(n for n in os.listdir(adir) if n.startswith("RCPT-"))
if not names:
    sys.exit("FAIL: no receipts in AGENT/AUDIT")
KEY = b"a5" * 32
seen = set()
for n in names:
    body = open(os.path.join(adir, n), "rb").read().split(b"\n")
    if len(body) != 3 or body[1] != hmac.new(KEY, body[0], hashlib.sha256).hexdigest().encode():
        sys.exit("FAIL: receipt %s malformed or MAC-bad" % n)
    r = json.loads(body[0])
    seen.add((r.get("agent"), r.get("verb"), r.get("result")))
    if r.get("verb") == "ui.input" and b"usage" in body[0]:
        sys.exit("FAIL: receipt %s logged event bytes" % n)
for need in (
    ("devin", "ui.input", "ok"),
    ("devin", "ui.input", "agent_input_no_focus"),
    ("devin", "ui.input", "too_large"),
):
    if need not in seen:
        sys.exit("FAIL: no %r receipt; saw %r" % (need, sorted(seen)))
print("run-15 audit ok: %d receipts incl. ui.input" % len(names))
PY2

# ---- 16: ui.screenshot scale=1 — the full-resolution read (#2977) --------------
# Card #2977 (ADR 0044 D3 amendment): ui.screenshot takes an optional
# `scale` — 8 is the 160x90 thumbnail (default, unbound), 1 is the whole
# 1280x720 frame read in 12-row slot-88 bands and streamed through the
# chunk path (1,843,200 bytes). A second scale=1 inside the per-session
# 2 s bound is rate_limited; every other scale is bad_request. The
# journey saves both frames into $RUN_DIR and the python leg downsamples
# the full frame at the thumbnail's own sampling grid and diffs it
# against the same run's scale=8 capture within a small per-channel
# tolerance. GOCALC stages on the first ui.windows marker, as in run 01.
vgate_run 16 -- \
    --screen '$RUN_DIR/screen-16' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=shot' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-stream-arg '--shot-dir=$RUN_DIR' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-agentd.txt' --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script-calc.txt' --script3-after 'verb=ui.windows' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 4 --timeout 300

vgate_assert 16 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 16 serial-contains 'verb=ui.windows ok'
vgate_assert 16 serial-contains 'verb=ui.screenshot ok'
vgate_assert 16 serial-contains 'verb=ui.screenshot code=rate_limited'
vgate_assert 16 serial-contains 'verb=ui.screenshot code=bad_request'
vgate_assert 16 output-contains 'AGENTCTL: ok shot-full'
vgate_assert 16 output-contains 'AGENTCTL: ok shot-rate'
vgate_assert 16 output-contains 'AGENTCTL: PASS shot'
vgate_assert 16 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 16 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 16 serial-absent '[EXC] parking:'

# The full frame downsampled at the thumbnail's 8:1 grid must match the
# same run's scale=8 capture — same source pixels, same conversion — to
# within a small per-channel tolerance (a repaint may land between the
# two reads). At most 5% of thumbnail pixels may drift.
vgate_assert 16 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
full = open(os.path.join(run, "shot-full.rgb565"), "rb").read()
thumb = open(os.path.join(run, "shot-thumb.rgb565"), "rb").read()
W, H, TW, TH = 1280, 720, 160, 90
if len(full) != W * H * 2:
    sys.exit("FAIL: full frame is %d bytes" % len(full))
if len(thumb) != TW * TH * 2:
    sys.exit("FAIL: thumb frame is %d bytes" % len(thumb))
drift = 0
for ty in range(TH):
    for tx in range(TW):
        fo = (ty * 8 * W + tx * 8) * 2
        to = (ty * TW + tx) * 2
        fv = full[fo] | full[fo + 1] << 8
        tv = thumb[to] | thumb[to + 1] << 8
        if abs(((fv >> 11) & 31) - ((tv >> 11) & 31)) > 1 \
                or abs(((fv >> 5) & 63) - ((tv >> 5) & 63)) > 1 \
                or abs((fv & 31) - (tv & 31)) > 1:
            drift += 1
if drift > TW * TH // 20:
    sys.exit("FAIL: downsample drifted on %d px" % drift)
print("run-16 frame ok: %d B streamed, %d px drift" % (len(full), drift))
PY

# ---- 17: card #2985 — ui.geometry query/sash/move over kind 30 -----------------
# devin holds window+input. GOCALC and GOEDIT exec together on the first
# ui.windows marker; the journey splits the focused pane through
# ui.input's ctrl+shift+v chord, queries both panes (each AGENTCTL geom
# line is diffed against the seat's own `gotabwm: layout` below), sets
# the sash to 30 %, and moves a window to space 1 — where ui.windows no
# longer lists it. The reds land bad_request, win_geometry_bad_op and
# win_geometry_no_window by name.
vgate_run 17 -- \
    --screen '$RUN_DIR/screen-17' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=geom' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-agentd.txt' --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script-two.txt' --script3-after 'verb=ui.windows' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 4 --timeout 300

vgate_assert 17 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 17 serial-contains 'verb=ui.windows ok'
vgate_assert 17 serial-contains 'verb=ui.input ok'
vgate_assert 17 serial-contains 'verb=ui.geometry ok'
vgate_assert 17 serial-contains 'gotabwm: win_geometry op=0 id='
vgate_assert 17 serial-contains 'gotabwm: win_geometry op=2 id='
vgate_assert 17 serial-contains 'gotabwm: win_geometry op=1 id='
vgate_assert 17 serial-contains 'gotabwm: sash v from='
vgate_assert 17 serial-contains 'gotabwm: space new name=2'
vgate_assert 17 serial-contains 'gotabwm: space move '
vgate_assert 17 serial-contains 'code=win_geometry_bad_op'
vgate_assert 17 serial-contains 'code=win_geometry_no_window'
vgate_assert 17 serial-contains 'code=bad_request'
vgate_assert 17 output-contains 'AGENTCTL: PASS geom'
vgate_assert 17 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 17 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 17 serial-absent '[EXC] parking:'

# Every AGENTCTL geom line must name the rect the seat's own layout line
# reports for the same window id — the query is the seat's geometry, not
# a second opinion.
vgate_assert 17 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-17.out"), errors="replace").read()

ser = None
for name in ("vm-serial-17.log", "serial.log"):
    p = os.path.join(run, name)
    if os.path.isfile(p):
        ser = open(p, errors="replace").read()
        break
if ser is None:
    sys.exit("FAIL: no run-17 serial log in RUN_DIR")
geom = re.findall(r"AGENTCTL: geom tab=(\d+) x=(\d+) y=(\d+) w=(\d+) h=(\d+)", out)
if len(geom) < 4:
    sys.exit("FAIL: too few geom lines: %r" % geom)
for tab, x, y, w, h in geom:
    want = ("gotabwm: layout tab=%s .*x=%s y=%s w=%s h=%s" % (tab, x, y, w, h))
    if not re.search(want, ser):
        sys.exit("FAIL: no layout line matching %r" % want)
print("run-17 geometry matches the seat layout lines: %d queries" % len(geom))
PY

# The ui.geometry dispatches are receipted — the applied ops AND the
# named refusals.
vgate_assert 17 python <<'PY2'
import hashlib, hmac, json, os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
adir = os.path.join(share, "AGENT", "AUDIT")
names = sorted(n for n in os.listdir(adir) if n.startswith("RCPT-"))
if not names:
    sys.exit("FAIL: no receipts in AGENT/AUDIT")
KEY = b"a5" * 32
seen = set()
for n in names:
    body = open(os.path.join(adir, n), "rb").read().split(b"\n")
    if len(body) != 3 or body[1] != hmac.new(KEY, body[0], hashlib.sha256).hexdigest().encode():
        sys.exit("FAIL: receipt %s malformed or MAC-bad" % n)
    r = json.loads(body[0])
    seen.add((r.get("agent"), r.get("verb"), r.get("result")))
for need in (
    ("devin", "ui.geometry", "ok"),
    ("devin", "ui.geometry", "win_geometry_bad_op"),
    ("devin", "ui.geometry", "win_geometry_no_window"),
    ("devin", "ui.geometry", "bad_request"),
):
    if need not in seen:
        sys.exit("FAIL: no %r receipt; saw %r" % (need, sorted(seen)))
print("run-17 audit ok: %d receipts incl. ui.geometry" % len(names))
PY2

# ---- 18: card #2985 — the cap split + the non-AGENTD sender --------------------
# watcher declares `window` only: query serves (observation), move and
# sash refuse cap_required:input (the M139b drive grant) before any
# kind-30 frame. WMRPCPROBE.ELF is the in-guest non-AGENTD sender: its
# bound kind-30 frame hears win_geometry_denied from the seat itself.
vgate_run 18 -- \
    --screen '$RUN_DIR/screen-18' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=geom-deny' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/watcher.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-agentd.txt' --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script-probe.txt' --script3-after 'verb=ui.windows' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect 'wmrpcprobe: auth probe ok' \
    --script-expect-tail 4 --timeout 300

vgate_assert 18 serial-contains 'agentd: auth ok agent=watcher'
vgate_assert 18 serial-contains 'verb=ui.windows ok'
vgate_assert 18 serial-contains 'verb=ui.geometry ok'
vgate_assert 18 serial-count 'verb=ui.geometry code=cap_required' 2
vgate_assert 18 serial-contains 'gotabwm: win_geometry op=0 id='
vgate_assert 18 serial-contains 'win_geometry_denied'
vgate_assert 18 serial-contains 'wmrpcprobe: win-geometry refused'
vgate_assert 18 serial-contains 'wmrpcprobe: auth probe ok'
vgate_assert 18 output-contains 'AGENTCTL: PASS geom-deny'
vgate_assert 18 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 18 serial-absent '0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d'
vgate_assert 18 serial-absent '[EXC] parking:'

# The watcher's dispatches are receipted too — query ok and both
# cap_required:input refusals.
vgate_assert 18 python <<'PY2'
import hashlib, hmac, json, os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
adir = os.path.join(share, "AGENT", "AUDIT")
names = sorted(n for n in os.listdir(adir) if n.startswith("RCPT-"))
if not names:
    sys.exit("FAIL: no receipts in AGENT/AUDIT")
KEY = b"a5" * 32
seen = set()
cap_recs = []
for n in names:
    body = open(os.path.join(adir, n), "rb").read().split(b"\n")
    if len(body) != 3 or body[1] != hmac.new(KEY, body[0], hashlib.sha256).hexdigest().encode():
        sys.exit("FAIL: receipt %s malformed or MAC-bad" % n)
    r = json.loads(body[0])
    seen.add((r.get("agent"), r.get("verb"), r.get("result")))
    if (r.get("agent"), r.get("verb"), r.get("result")) == (
            "watcher", "ui.geometry", "cap_required:input"):
        cap_recs.append(r)
for need in (
    ("watcher", "ui.geometry", "ok"),
    ("watcher", "ui.geometry", "cap_required:input"),
):
    if need not in seen:
        sys.exit("FAIL: no %r receipt; saw %r" % (need, sorted(seen)))
if len(cap_recs) != 2:
    sys.exit("FAIL: want exactly 2 cap_required:input receipts; saw %r" % sorted(seen))
print("run-18 audit ok: %d receipts incl. the cap split" % len(names))
PY2
