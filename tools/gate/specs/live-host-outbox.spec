# live-host-outbox.spec -- M127d (#2602, ADR 0051 V2-D5) class-B: the
# OUTBOX export lane end to end. Guest intent (GOSH `export`, planted
# REQ markers) -> the seat's signed OUTBOX record -> the runner's
# verify -> the move into --host-outbox-dir. It is the drop arc
# reversed: the REQ is unsigned intent, the record is provenance, and an
# unmarked payload in OUTBOX/ is the mirror of an unannounced INBOX
# plant -- inert forever.
#
# Run 01 is the arc on one boot: arm -> lane-adoption -> GOSH `export`
# staged REQ -> seat emit -> host move -> suspension mid-flight ->
# a second export held through the suspend and landing after resume ->
# every planted REQ refusal named -> the unsigned plant sitting inert.
# The REQ plants exercise the seat's refusal table live: a REQ naming
# nothing (gone), one carrying a traversal name and one carrying an
# invalid name (name_rejected), one naming a directory
# (unsupported_kind) and one naming an over-cap payload
# (payload_too_large) -- the marker is deleted, the payload is left in
# place, and nothing is emitted. A REQ for COLL.TXT emits and moves all
# the way to the destination, where nine pre-filled collision slots force
# the runner's own name_rejected (the move-side refusal the seat cannot
# see coming).
#
# Run 02 is the per-epoch quota: 65 REQ+payload plants drain at the
# seat's 1-REQ/tick bound into 65 signed records; the runner accepts 64
# and refuses the 65th quota_exceeded -- the hostile-guest wall, counted
# per epoch.
#
# Run 03 is the flags-off posture (D7): the credentialed share, zero
# lane flags -- no OUTBOX/, no REQ watch, no lane markers, and a GOSH
# `export` refusing io_error because the dir it would stage into was
# never created.
#
# Run 04 is no_credential: the flag is up but the share has no host-int
# row -- the arm refuses lane=outbox no_credential and nothing is
# created.
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh      ->  .build/go/GOSH.ELF

vgate_name live-host-outbox "M127d #2602: OUTBOX export lane -- REQ intent -> signed TagOutbox -> host Downloads (ADR 0051 V2-D5)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script-seat.txt <<'EOF'
exec GOTABWM.ELF
EOF

# Once the seat has adopted lanes=outbox, GOSH -c runs the real `export`
# builtin against a share file -- REQ + payload staged under OUTBOX/.
vgate_file script-export.txt <<'EOF'
exec GOSH.ELF -c "export DOCS/HELLO.TXT"
EOF

# During the suspended window the same gesture stages a REQ that sits
# unsigned until resume -- the REQ is inert intent, so the suspension
# holds it, the resume drains it.
vgate_file script-susp.txt <<'EOF'
exec GOSH.ELF -c "export DOCS/SUSP.TXT"
echo rx-outbox-done
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
for name, build in (
    ("GOTABWM.ELF", "bash tools/go/build-gotabwm.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, name))
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
KEY = "m127dkey" * 8  # 64 bytes, ASCII
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# Export sources under the share (GOSH resolves `export DOCS/x` against
# the share root).
os.makedirs(os.path.join(share, "DOCS"), exist_ok=True)
open(os.path.join(share, "DOCS", "HELLO.TXT"), "w").write(
    "through the glass, back again\n")
open(os.path.join(share, "DOCS", "SUSP.TXT"), "w").write(
    "staged under suspension\n")
# OUTBOX/ plants. The dir is the runner's at arm, but plants must exist
# before first boot -- pre-create is part of the fixture.
ob = os.path.join(share, "OUTBOX")
os.makedirs(ob, exist_ok=True)
def req(hexsuffix, payload_name):
    open(os.path.join(ob, "REQ-" + hexsuffix), "w").write(payload_name)
# Refusal table (one REQ outcome per seat tick, each deleted + named):
req("000000a1", "MISSING.TXT")           # no payload -> gone
req("000000a2", "../ESCAPE")             # traversal -> name_rejected
req("000000a3", "bad name!.txt")         # charset -> name_rejected
os.mkdir(os.path.join(ob, "SUBDIR"))
req("000000a4", "SUBDIR")                # dir payload -> unsupported_kind
with open(os.path.join(ob, "BIG.BIN"), "wb") as f:
    f.truncate(65 * 1024 * 1024)         # sparse, over the 64 MiB cap
req("000000a5", "BIG.BIN")               # -> payload_too_large
# The collision leg: COLL.TXT is a real REQ+payload, but every landing
# name (COLL.TXT, COLL-2..COLL-9) is occupied in the destination -> the
# runner's name_rejected after 9 suffix tries.
open(os.path.join(ob, "COLL.TXT"), "w").write("collision payload\n")
req("000000a6", "COLL.TXT")
# The unsigned plant: a payload with NO REQ marker is inert by rule.
open(os.path.join(ob, "PLANT.BIN"), "w").write("unmarked payload\n")
# The landing dir + the collision occupants.
dest = os.path.join(run, "dest")
os.makedirs(dest, exist_ok=True)
for n in ["COLL.TXT"] + ["COLL-%d.TXT" % i for i in range(2, 10)]:
    open(os.path.join(dest, n), "w").write("preexisting\n")
open(os.path.join(run, "key-sentinel.txt"), "w").write(KEY + "\n")
# Run 02's quota fixture: 65 REQ+payload pairs in a SECOND share the run
# boots on -- the same credential, so the epoch is the run's own.
qshare = os.path.join(run, "quota-share")
shutil.copytree(share, qshare)
# Wipe run 01's plants from the quota share, keep ELFs/credential/DOCS.
ob2 = os.path.join(qshare, "OUTBOX")
for n in os.listdir(ob2):
    p = os.path.join(ob2, n)
    if os.path.isdir(p):
        os.rmdir(p)
    else:
        os.unlink(p)
dest2 = os.path.join(run, "dest-quota")
os.makedirs(dest2, exist_ok=True)
for i in range(1, 66):  # 65 pairs -> 64 landings + 1 quota_exceeded
    n = "Q%02d.TXT" % i
    open(os.path.join(ob2, n), "w").write("quota probe %d\n" % i)
    open(os.path.join(ob2, "REQ-%08x" % i), "w").write(n)
# Flags-off + no-credential shares (same shape as the arc spec's).
for off in ("off-share", "nocred-share"):
    d = os.path.join(run, off)
    os.makedirs(d, exist_ok=True)
    for name in ("GOTABWM.ELF", "GOSH.ELF"):
        shutil.copy(os.path.join(".build", "go", name), os.path.join(d, name))
    open(os.path.join(d, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
    open(os.path.join(d, "OWNERS.TXT"), "w").write(
        "#v1\nGOTABWM.ELF\t644\t0\t-\n")
    os.makedirs(os.path.join(d, "DOCS"), exist_ok=True)
    open(os.path.join(d, "DOCS", "HELLO.TXT"), "w").write("off run\n")
open(os.path.join(run, "off-share", "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
print("staged outbox share: 6 REQ plants + unsigned plant + collision dest"
      " + 65-pair quota share + 2 clean shares")
PY

# ---- 01: the arc on one boot -----------------------------------------------
# Marker-ordered: armed -> reveal-export probe (disabled: nothing landed
# yet) -> the first GOSH export -> suspend on its staged marker -> the
# suspended-era export -> resume on ITS staged marker -> everything
# drains and lands.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-export.txt' --script2-after 'lanes=outbox' \
    --script3 '$RUN_DIR/script-susp.txt' --script3-after 'lanes=-' \
    --host-outbox --host-outbox-dir '$RUN_DIR/dest' \
    --host-cmd-after 'gotabwm: hostint armed:reveal-export' \
    --host-cmd-after 'gosh: export staged name=HELLO.TXT:lane-outbox' \
    --host-cmd-after 'gosh: export staged name=SUSP.TXT:lane-outbox' \
    --script-expect 'rx-outbox-done' --script-expect-tail 15 --timeout 240

vgate_assert 01 serial-contains 'gotabwm: registered'
# ONE session, the outbox bit named at both ends; the suspend/resume
# cycle re-adopts lanes=- then lanes=outbox a second time.
vgate_assert 01 output-contains 'host-int: armed lanes=outbox epoch='
vgate_assert 01 serial-count 'lanes=outbox' 2
vgate_assert 01 serial-contains 'lanes=-'
# The bus verbs the lane registered itself: reveal-export disabled with
# nothing landed, both lane toggles performed.
vgate_assert 01 output-contains 'host-ui: cmd=reveal-export vm=1 state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=lane-outbox vm=1 state=performed'
# Both exports staged; the suspended one waited for the resumed mask.
vgate_assert 01 serial-contains 'gosh: export staged name=HELLO.TXT'
vgate_assert 01 serial-contains 'gosh: export staged name=SUSP.TXT'
vgate_assert 01 serial-contains 'gotabwm: hostint outbox seq='
# The planted REQ refusal table, each named and its marker deleted.
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=outbox reason=gone'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=outbox reason=name_rejected'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=outbox reason=unsupported_kind'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=outbox reason=payload_too_large'
# The move-side refusals: COLL.TXT's signed record moved all the way to
# the destination and was refused there -- the landing grammar is the
# host's to enforce.
vgate_assert 01 output-contains 'host-int: refuse lane=outbox reason=name_rejected'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
ser = open(os.environ["VG_SER"], errors="replace").read()
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
# Both toggles performed (suspend + resume), the reveal probe disabled.
if out.count("host-ui: cmd=lane-outbox vm=1 state=performed") != 2:
    sys.exit("FAIL: lane-outbox receipts = %d, want 2"
             % out.count("host-ui: cmd=lane-outbox vm=1 state=performed"))
# Exactly two landings -- the two GOSH exports -- named on the lane line.
landings = re.findall(r"host-outbox: file seq=\d+ name=(\S+) size=", out)
if sorted(landings) != ["HELLO.TXT", "SUSP.TXT"]:
    sys.exit("FAIL: landings = %r want HELLO.TXT + SUSP.TXT" % landings)
# Each seat emit has a marker; refused REQs never emitted. COLL's emit
# + the two export emits = 3 `hostint outbox` lines.
emits = re.findall(r"gotabwm: hostint outbox seq=\d+ name=(\S+) size=", ser)
if sorted(emits) != ["COLL.TXT", "HELLO.TXT", "SUSP.TXT"]:
    sys.exit("FAIL: emits = %r" % emits)
# The unsigned plant: still in OUTBOX/, never named on either side's
# lane line, never landed.
if not os.path.isfile(os.path.join(share, "OUTBOX", "PLANT.BIN")):
    sys.exit("FAIL: the unsigned plant vanished")
if os.path.exists(os.path.join(run, "dest", "PLANT.BIN")):
    sys.exit("FAIL: an unmarked payload was exported")
if "name=PLANT" in out + ser:
    sys.exit("FAIL: the unsigned plant was attributed")
# Every REQ marker is consumed -- none may survive.
left = [n for n in os.listdir(os.path.join(share, "OUTBOX"))
        if n.startswith("REQ-")]
if left:
    sys.exit("FAIL: REQ markers left in OUTBOX: %r" % left)
# Refused payloads stay in place (the refusal deletes the marker, not
# the data): the traversal/name/directory/oversize plants and the
# collision payload remain; nothing else should.
present = sorted(os.listdir(os.path.join(share, "OUTBOX")))
for want in ("BIG.BIN", "COLL.TXT", "PLANT.BIN", "SUBDIR"):
    if want not in present:
        sys.exit("FAIL: refused payload %s missing from OUTBOX: %r"
                 % (want, present))
# The landings are byte-equal to their sources and collision-named only
# where forced.
want_hello = open(os.path.join(share, "DOCS", "HELLO.TXT"), "rb").read()
want_susp = open(os.path.join(share, "DOCS", "SUSP.TXT"), "rb").read()
for n, want in (("HELLO.TXT", want_hello), ("SUSP.TXT", want_susp)):
    got = os.path.join(run, "dest", n)
    if not os.path.isfile(got):
        sys.exit("FAIL: dest/%s missing" % n)
    if open(got, "rb").read() != want:
        sys.exit("FAIL: dest/%s content mismatch" % n)
# The collision refused: COLL.TXT in dest is still the PREEXISTING file,
# not the payload; the nine suffixes were the dead end, not a write.
coll = open(os.path.join(run, "dest", "COLL.TXT")).read()
if coll != "preexisting\n":
    sys.exit("FAIL: the collision path overwrote a live file")
# HOSTINT holds no unconsumed records.
lane = [n for n in os.listdir(os.path.join(share, "HOSTINT"))
        if not n.endswith("~")]
if lane:
    sys.exit("FAIL: unconsumed lane files: %r" % lane)
# Never-logged: key + payload bytes stay off lane lines.
key = open(os.path.join(run, "key-sentinel.txt")).read().strip()
if key in out:
    sys.exit("FAIL: the lane key reached runner stdout")
for line in out.splitlines():
    if line.startswith(("host-int:", "host-outbox:")) and (
            "through the glass" in line or "staged under" in line or
            "collision payload" in line or "unmarked payload" in line):
        sys.exit("FAIL: a lane line carried payload text: " + line[:80])
print("run-01 arc: two exports landed, susp/resume adopted, %d emits,"
      " refusal table + unsigned plant held" % len(emits))
PY

# ---- 02: the per-epoch quota -----------------------------------------------
# 65 REQ+payload plants drain at the seat's one-REQ-per-tick bound: the
# REQ names sort so emit seq == plant index, and the 65th signed record
# hits the runner's 64-export epoch wall -> quota_exceeded, record
# consumed, payload left in OUTBOX/.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --cvc-file '$RUN_DIR/quota-share' \
    --script '$RUN_DIR/script-seat.txt' \
    --host-outbox --host-outbox-dir '$RUN_DIR/dest-quota' \
    --script-expect 'gotabwm: hostint outbox seq=65' --script-expect-tail 12 --timeout 300

vgate_assert 02 output-contains 'host-int: armed lanes=outbox epoch='
vgate_assert 02 output-contains 'host-int: refuse lane=outbox reason=quota_exceeded'
vgate_assert 02 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-02.out"), errors="replace").read()
ser = open(os.environ["VG_SER"], errors="replace").read()
# The seat emitted all 65; the runner moved 64 and refused the 65th.
emits = re.findall(r"gotabwm: hostint outbox seq=(\d+)", ser)
if len(emits) != 65:
    sys.exit("FAIL: %d emits, want 65" % len(emits))
moved = re.findall(r"host-outbox: file seq=(\d+)", out)
refused = re.findall(r"host-int: refuse lane=outbox reason=quota_exceeded", out)
if len(moved) != 64 or len(refused) != 1:
    sys.exit("FAIL: moved=%d refused=%d, want 64/1" % (len(moved), len(refused)))
# The refused record is the LAST one emitted, and its payload was left
# behind in OUTBOX/ -- the cap refuses the move, not the data.
qshare = os.path.join(run, "quota-share")
present = sorted(os.listdir(os.path.join(qshare, "OUTBOX")))
if present != ["Q65.TXT"]:
    sys.exit("FAIL: post-quota OUTBOX = %r want [Q65.TXT]" % present)
if len(os.listdir(os.path.join(run, "dest-quota"))) != 64:
    sys.exit("FAIL: dest holds %d files, want 64"
             % len(os.listdir(os.path.join(run, "dest-quota"))))
if not os.path.isfile(os.path.join(run, "dest-quota", "Q01.TXT")):
    sys.exit("FAIL: Q01.TXT never landed")
print("run-02 quota: 65 emitted, 64 moved, the 65th named quota_exceeded")
PY

# ---- 03: flags-off is byte-silent for the lane ------------------------------
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --cvc-file '$RUN_DIR/off-share' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-export.txt' --script2-after 'gotabwm: mode live' \
    --script-expect 'gosh: export refused target=DOCS/HELLO.TXT reason=io_error' \
    --script-expect-tail 6 --timeout 180

vgate_assert 03 serial-contains 'gotabwm: registered'
vgate_assert 03 serial-contains 'gotabwm: mode live'
vgate_assert 03 serial-contains 'gosh: export refused target=DOCS/HELLO.TXT reason=io_error'
vgate_assert 03 serial-absent 'gotabwm: hostint'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-03.out"), errors="replace").read()
for needle in ("host-int:", "host-outbox:"):
    if needle in out:
        sys.exit("FAIL: flags-off run printed lane traffic: " + needle)
share = os.path.join(run, "off-share")
for d in ("HOSTINT", "OUTBOX"):
    if os.path.isdir(os.path.join(share, d)):
        sys.exit("FAIL: flags-off run created " + d + "/")
print("run-03 flags-off silence ok")
PY

# ---- 04: no_credential refuses the lane at arm ------------------------------
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --cvc-file '$RUN_DIR/nocred-share' \
    --host-outbox --host-outbox-dir '$RUN_DIR/dest-nocred' \
    --script '$RUN_DIR/script-seat.txt' \
    --script-expect 'gotabwm: mode live' --script-expect-tail 6 --timeout 180

vgate_assert 04 output-contains 'host-int: refuse lane=outbox reason=no_credential'
vgate_assert 04 serial-contains 'gotabwm: mode live'
vgate_assert 04 serial-absent 'gotabwm: hostint'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-04.out"), errors="replace").read()
if "host-int: armed" in out:
    sys.exit("FAIL: a credentialless arm still published ARMED")
share = os.path.join(run, "nocred-share")
for d in ("HOSTINT", "OUTBOX"):
    if os.path.isdir(os.path.join(share, d)):
        sys.exit("FAIL: no_credential arm created " + d + "/")
print("run-04 no_credential refusal ok")
PY
