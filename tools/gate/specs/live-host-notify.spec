# live-host-notify.spec -- M108d (#2328, ADR 0051 D5) class-B: the
# notify-out lane — seat toasts crossing the glass as signed NOTIFY_OUT
# records the runner drains on its 250 ms poll.
#
# Run 01 is the full journey on the BARE runner: ARMED names notify+drop,
# three drop gestures land `host drop:` toasts through the real DROP
# consume, and a GOFILES burst (one yank + five pastes into five dirs —
# a paste never overwrites) raises five real `tabapp.Notify` kind-12
# toasts. Every strip-queued toast stages for the lane; the seat emits
# <=1 NOTIFY_OUT per tick and <=4 outstanding, so the burst overflows the
# staging bound and the strip's own `notify drop total=` accounting carries
# the overflow. The bare runner has no bundle identity, so each verified
# record logs `host-notify: dropped reason=no_bundle` — the ADR-named
# honest answer; the banner pixel is the class-C owner leg.
#
# M127c (#2601, ADR 0051 V2-D3) extends run 01 with the click-through leg:
# NOTIFY_OUT now carries the toast's sender tab id, and the
# --host-cmd-after '…notify-out seq=5:notify-click' trigger fires the
# IDENTICAL click path a banner's didReceive takes — the runner emits a
# signed NOTIFY_FOCUS{sender} (NFOCUS-00000001) the seat verifies and runs
# through focusHosted. By the fifth emit the runner's most-recent consumed
# record is a GOFILES toast (the three drop toasts, sender 0, drained
# first), so the click answers a real tab id, not a seat notice.
#
# Run 02 is the flags-off posture: same credentialed share, no lane flags —
# no HOSTINT/, no markers either end, byte-silent.
#
# Run 03 is the credential refusal: --host-notify on a share with no
# `host-int` SECRETS.TXT row refuses no_credential at arm; the boot
# continues with the lane dead (fail closed per lane, never a boot
# failure) and the seat never arms.
#
# The credential rides the share's SECRETS.TXT, bound to GOTABWM.ELF (the
# ADR 0024 D8 app binding). The seat is exec'd explicitly (wm=none) so the
# choreography times off its markers; --screen arms the virtio-gpu the
# seat's WmctlRegister requires AND gives the drop lane its display path;
# --via-virtio carries the --input-string keystrokes to GOFILES.
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh  ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-files.sh    ->  .build/go/GOFILES.ELF

vgate_name live-host-notify "M108d #2328: seat toasts -> NOTIFY_OUT records -> macOS banners, bundle-gated, rate-limited (ADR 0051 D5)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script-seat.txt <<'EOF'
exec GOTABWM.ELF
EOF

vgate_file script-files.txt <<'EOF'
exec GOFILES.ELF /host/NFY
EOF

vgate_file script-nop.txt <<'EOF'
echo run03-booted
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
for name, build in (
    ("GOTABWM.ELF", "bash tools/go/build-gotabwm.sh"),
    ("GOFILES.ELF", "bash tools/go/build-files.sh"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, name))
# wm=none: the seat is exec'd on script, like the other hostint specs.
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
# The lane credential: the row the seat reads via sys_secret_get (image
# binding needs the uid_system OWNERS row) and the runner reads as a host
# file. Value bytes ARE the HMAC key verbatim.
KEY = "notfykey" * 8  # 64 bytes, ASCII
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# The drop gesture's host-side sources (three small landings -> three
# `host drop:` toasts crossing back out as NOTIFY_OUT).
qoi = "tests/fixtures/qoi/viewer_160x120.qoi"
src_dir = os.path.join(run, "drop-src")
os.makedirs(src_dir, exist_ok=True)
for n in ("A.QOI", "B.QOI", "C.QOI"):
    shutil.copy(qoi, os.path.join(src_dir, n))
# GOFILES's copy+paste range: five destination dirs (a paste never
# overwrites, so each toast needs its own dir) plus the file to copy.
nfy = os.path.join(share, "NFY")
for d in ("D1", "D2", "D3", "D4", "D5"):
    os.makedirs(os.path.join(nfy, d), exist_ok=True)
open(os.path.join(nfy, "SRC.TXT"), "w").write("notify-range-payload\n")
open(os.path.join(run, "key-sentinel.txt"), "w").write(KEY + "\n")
# Run 02's flags-off share: same seat + credential posture, nothing armed.
d = os.path.join(run, "off-share")
os.makedirs(d, exist_ok=True)
shutil.copy(os.path.join(".build", "go", "GOTABWM.ELF"),
            os.path.join(d, "GOTABWM.ELF"))
open(os.path.join(d, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
open(os.path.join(d, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(d, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# Run 03's share: the seat binary and settings, but NO host-int row — the
# runner refuses no_credential at arm and the seat never builds an engine.
d = os.path.join(run, "nocred-share")
os.makedirs(d, exist_ok=True)
shutil.copy(os.path.join(".build", "go", "GOTABWM.ELF"),
            os.path.join(d, "GOTABWM.ELF"))
open(os.path.join(d, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
open(os.path.join(d, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
print("staged hostint share (2 ELFs + credential + 3-path drop gesture"
      " + NFY/D1..D5 paste range) + 2 clean shares")
PY

# ---- 01: toasts cross the glass as signed NOTIFY_OUT records -----------------
# The drop gesture fires on the seat's armed marker; GOFILES execs after
# adoption so its paste burst lands mid-lane. The input is `G c` (yank the
# last entry, SRC.TXT) then `g`+j's to each dir, `l` in, `p` paste, `h` back
# — five pastes, five `copied SRC.TXT` toasts, one burst over the lane's
# staging bound. The tail gives the 1/tick emit drain time to finish.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script-seat.txt' \
    --host-notify \
    --host-drop \
    --host-drop-file '$RUN_DIR/drop-src/A.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/B.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/C.QOI' \
    --host-drop-after 'gotabwm: hostint armed' \
    --host-cmd-after 'gotabwm: hostint notify-out seq=5:notify-click' \
    --script2 '$RUN_DIR/script-files.txt' --script2-after 'gotabwm: hostint armed' \
    --input-string $'Gcglphgjlphgjjlphgjjjlphgjjjjlp' \
    --input-string-after 'gofiles: ready' \
    --script-expect 'gofiles: notify sent' --script-expect-tail 15 --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
# The shared session armed with BOTH lane bits named.
vgate_assert 01 output-contains 'host-int: armed lanes=drop,notify epoch='
vgate_assert 01 serial-contains 'gotabwm: hostint armed epoch='
vgate_assert 01 serial-contains 'lanes=drop,notify'
# The drop notices became seat toasts (sender id 0) AND app toasts landed.
vgate_assert 01 serial-contains 'gotabwm: notify id=0 host drop: A.QOI'
vgate_assert 01 serial-contains 'gofiles: notify sent copied SRC.TXT'
# The egress: seat-side emit receipts and the bare runner's honest drops —
# every seq the seat emitted, the runner consumed and named no_bundle with
# the running count (the ADR's `dropped reason=<code> n=<count>`).
vgate_assert 01 serial-contains 'gotabwm: hostint notify-out seq=1'
vgate_assert 01 output-contains 'host-notify: dropped reason=no_bundle seq=1 n=1'
# The staging-overflow drop itself is pinned host-side (GOFILES keypacing
# under three Go runtimes lands one toast per several ticks, so the lane's
# 4-deep staging never fills against a runner draining at 250 ms) —
# gotabwm TestHostNotifyOverflowDropsOldest proves the `notify drop
# total=` accounting reuse and TestHostNotifyBackpressuredHolds the
# 4-outstanding hold; class-B proves the 1/tick pacing below.
# The bare runner never claims a post it cannot make.
vgate_assert 01 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
ser = open(os.environ["VG_SER"], errors="replace").read()
if "host-notify: post" in out:
    sys.exit("FAIL: bare runner claimed a banner post")
key = open(os.path.join(run, "key-sentinel.txt")).read().strip()
if key in out or key in ser:
    sys.exit("FAIL: the lane key reached runner stdout or serial")
# Every seq the seat emitted, the runner consumed in order as a named drop.
emitted = [int(m) for m in re.findall(r"hostint notify-out seq=(\d+)", ser)]
dropped = [int(m) for m in re.findall(
    r"host-notify: dropped reason=no_bundle seq=(\d+)", out)]
if len(emitted) < 4:
    sys.exit("FAIL: only %d notify-out emits" % len(emitted))
if emitted != sorted(emitted) or emitted[0] != 1:
    sys.exit("FAIL: emit seqs not monotonic from 1: %r" % emitted)
if dropped != emitted:
    sys.exit("FAIL: runner consumed %r but seat emitted %r" % (dropped, emitted))
# The rate bound, observed: at least one `gotabwm: tick` between each pair
# of emit markers — no two NOTIFY_OUT emits in the same seat tick.
lines = ser.splitlines()
emit_at = [i for i, l in enumerate(lines) if "hostint notify-out seq=" in l]
for a, b in zip(emit_at, emit_at[1:]):
    if not any("gotabwm: tick" in l for l in lines[a + 1:b]):
        sys.exit("FAIL: two notify-out emits inside one seat tick")
# The runner drained every record: no unconsumed NOTIFY-* left behind.
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
left = [n for n in os.listdir(os.path.join(share, "HOSTINT"))
        if n.startswith("NOTIFY-")]
if left:
    sys.exit("FAIL: unconsumed NOTIFY records left: %r" % left)
print("run-01 notify-out: %d emits, pace + drain + never-logged ok"
      % len(emitted))
PY
vgate_assert 01 serial-absent '[EXC] parking:'

# M127c (#2601, ADR 0051 V2-D3): the click-through leg. The notify-click
# bus verb fires once the seat's fifth emit marker is on serial — by then
# the runner has consumed earlier NOTIFY_OUTs, so the verb has a
# "most recent" to answer. The bare runner's click path is the same one
# didReceive takes: emit a signed NOTIFY_FOCUS{sender} (NFOCUS-00000001)
# which the seat verifies and turns into a real focus.
vgate_assert 01 output-contains 'host-ui: cmd=notify-click vm=1 state=performed'
vgate_assert 01 output-contains 'host-notify: click-focus id='
vgate_assert 01 serial-contains 'gotabwm: hostint notify-focus seq=1 id='
vgate_assert 01 serial-contains 'gotabwm: tab focus id='
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"host-notify: click-focus id=(\d+) seq=(\d+)", out)
n = re.search(r"hostint notify-focus seq=(\d+) id=(\d+)", ser)
if not m:
    sys.exit("FAIL: no runner click-focus receipt")
if not n:
    sys.exit("FAIL: no seat notify-focus receipt")
if m.group(1) == "0":
    sys.exit("FAIL: click answered a sender-0 toast")
if m.group(1) != n.group(2) or m.group(2) != n.group(1):
    sys.exit("FAIL: click-focus %r vs seat notify-focus %r" % (m.groups(), n.groups()))
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
left = [x for x in os.listdir(os.path.join(share, "HOSTINT"))
        if x.startswith("NFOCUS-")]
if left:
    sys.exit("FAIL: unconsumed NFOCUS records left: %r" % left)
print("run-01 click-through: NFOCUS seq=%s focused tab %s" % (n.group(1), n.group(2)))
PY

# ---- 02: flags-off is byte-silent ---------------------------------------------
# Same credential+seat posture on a CLEAN share, no --host-notify: the
# runner never creates HOSTINT/, writes no record, never touches the
# center; the seat's once-per-tick listing sees a directory that never
# exists — zero lane markers either end.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --cvc-file '$RUN_DIR/off-share' \
    --script '$RUN_DIR/script-seat.txt' \
    --script-expect 'gotabwm: mode live' --script-expect-tail 8 --timeout 180

vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: mode live'
vgate_assert 02 serial-absent 'gotabwm: hostint'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-02.out"), errors="replace").read()
for needle in ("host-int:", "host-notify:"):
    if needle in out:
        sys.exit("FAIL: flags-off run printed lane traffic: " + needle)
share = os.path.join(run, "off-share")
for d in ("HOSTINT", "INBOX"):
    if os.path.isdir(os.path.join(share, d)):
        sys.exit("FAIL: flags-off run created " + d + "/")
print("run-02 flags-off silence ok")
PY

# ---- 03: --host-notify without the credential refuses no_credential ----------
# The share has the seat but no `host-int` row: the runner refuses at arm,
# the boot continues with the lane dead, and the seat never arms (no row,
# no engine — D7). Nothing is created or polled.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --cvc-file '$RUN_DIR/nocred-share' \
    --host-notify \
    --script '$RUN_DIR/script-nop.txt' \
    --script-expect 'run03-booted' --script-expect-tail 5 --timeout 120

vgate_assert 03 output-contains 'host-int: refuse lane=notify reason=no_credential'
vgate_assert 03 serial-contains 'run03-booted'
vgate_assert 03 serial-absent 'gotabwm: hostint'
vgate_assert 03 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-03.out"), errors="replace").read()
if "host-int: armed" in out:
    sys.exit("FAIL: a credentialless arm still published ARMED")
share = os.path.join(run, "nocred-share")
if os.path.isdir(os.path.join(share, "HOSTINT")):
    sys.exit("FAIL: no_credential arm created HOSTINT/")
print("run-03 no_credential refusal ok")
PY
