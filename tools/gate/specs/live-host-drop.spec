# live-host-drop.spec -- M108c (#2326, ADR 0051 D4) class-B: the host->guest
# file-drop lane over the share.
#
# Run 01 is the full journey: the runner arms the lane (ARMED names the
# drop bit), a marker-timed --host-drop-file gesture feeds SIX host paths
# through the REAL drop handler the NSView calls -- a QOI, a name needing
# sanitizing, a collision pair, an over-cap file and a directory -- so the
# run proves INBOX landing (temp+rename, collision suffix), the four
# refusal names that are not landings, the seat's signed-notice consume
# (toast `host drop: <name>` on the kind-12 strip), and the M81b dispatch
# unchanged (GOSH `open` routes the landed file to GOVIEW). Two planted
# records prove the MAC/epoch refusals live on the DROP tag.
#
# Run 02 is the flags-off posture: same credentialed share shape, no
# --host-drop -- no INBOX/, no HOSTINT/, no lane marker either end.
#
# Run 03 is the headless refusal: --host-drop with no display path refuses
# lane_disabled at arm (the drop target is the display view) -- named, not
# silent, and no directories are created.
#
# The credential rides the share's SECRETS.TXT, bound to GOTABWM.ELF (the
# ADR 0024 D8 app binding: uid_system-owned in OWNERS.TXT, 644). The seat
# is exec'd explicitly (wm=none) so the choreography times off its
# markers, and --screen arms the virtio-gpu the seat's WmctlRegister
# requires -- AND is the display path the drop lane requires at arm.
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh  ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh     ->  .build/go/GOSH.ELF
#   bash tools/go/build-goview.sh   ->  .build/go/GOVIEW.ELF

vgate_name live-host-drop "M108c #2326: host file drop -> /host/INBOX + seat toast + mime dispatch (ADR 0051 D4)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script-seat.txt <<'EOF'
exec GOTABWM.ELF
EOF

# The dispatch proof: after the seat consumes DROP seq=1, GOSH's own
# `open` runs the M81b decision -- sniff head -> registry -> GOVIEW.ELF.
vgate_file script-open.txt <<'EOF'
exec GOSH.ELF -c "open /host/INBOX/PHOTO.QOI"
EOF

vgate_file script-nop.txt <<'EOF'
echo run03-booted
EOF

vgate_setup_python <<'PY'
import hashlib, hmac, os, shutil, struct, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
for name, build in (
    ("GOTABWM.ELF", "bash tools/go/build-gotabwm.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
    ("GOVIEW.ELF", "bash tools/go/build-goview.sh"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, name))
# wm=none: the seat is exec'd on script, like go-agentd.spec.
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
# The lane credential: the row the seat reads via sys_secret_get (image
# binding needs the uid_system OWNERS row) and the runner reads as a host
# file. Value bytes ARE the HMAC key verbatim.
KEY = "dropkey0" * 8  # 64 bytes, ASCII
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# Two planted lane records exercise the refusals live on the DROP tag:
# (a) correctly signed under a foreign epoch -> stale_epoch; (b) forged
# under a wrong key -> bad_mac. Both must be deleted, never toasted.
def rec(tag, flags, seq, epoch, payload, key):
    hdr = b"VHI1" + bytes([tag, flags, 0, 0]) + struct.pack(
        "<IIH", seq, epoch, len(payload))
    body = hdr + payload
    return body + hmac.new(key.encode(), body, hashlib.sha256).digest()
def drop_payload(name, size):
    n = name.encode()
    return bytes([len(n)]) + n + struct.pack("<Q", size)
os.makedirs(os.path.join(share, "HOSTINT"), exist_ok=True)
open(os.path.join(share, "HOSTINT", "DROP-00000077"), "wb").write(
    rec(4, 0, 0x77, 999, drop_payload("STALE.QOI", 9), KEY))
open(os.path.join(share, "HOSTINT", "DROP-00000088"), "wb").write(
    rec(4, 0, 0x88, 1, drop_payload("FORGED.QOI", 9), "wrongkey" * 8))
# The drop gesture's host-side sources. Six items, four landings:
#   PHOTO.QOI        a real QOI -- the dispatch target GOVIEW renders
#   odd name!.qoi    sanitize: ' ' and '!' fold to '_' -> odd_name_.qoi
#   a/DUP.QOI + b/DUP.QOI  the collision pair: second lands as DUP-2.QOI
#   big.bin          65 MiB sparse -> payload_too_large, no file, no record
#   somedir/         not a regular file -> unsupported_kind
qoi = "tests/fixtures/qoi/viewer_160x120.qoi"
src_dir = os.path.join(run, "drop-src")
os.makedirs(os.path.join(src_dir, "a"), exist_ok=True)
os.makedirs(os.path.join(src_dir, "b"), exist_ok=True)
os.makedirs(os.path.join(src_dir, "somedir"), exist_ok=True)
shutil.copy(qoi, os.path.join(src_dir, "PHOTO.QOI"))
shutil.copy(qoi, os.path.join(src_dir, "odd name!.qoi"))
shutil.copy(qoi, os.path.join(src_dir, "a", "DUP.QOI"))
shutil.copy(qoi, os.path.join(src_dir, "b", "DUP.QOI"))
with open(os.path.join(src_dir, "big.bin"), "wb") as f:
    f.truncate(65 * 1024 * 1024)  # sparse: over the 64 MiB cap, instant
open(os.path.join(run, "key-sentinel.txt"), "w").write(KEY + "\n")
# The flags-off and headless-refusal postures need shares the lane never
# armed: the runner owns HOSTINT//INBOX/ creation, so a boot on THESE
# directories proves byte-silence while holding the same credential, seat
# binary and wm=none posture the armed run uses.
for off in ("off-share", "off-share2"):
    d = os.path.join(run, off)
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(".build", "go", "GOTABWM.ELF"),
                os.path.join(d, "GOTABWM.ELF"))
    open(os.path.join(d, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
    open(os.path.join(d, "SECRETS.TXT"), "w").write(
        "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
    open(os.path.join(d, "OWNERS.TXT"), "w").write(
        "#v1\nGOTABWM.ELF\t644\t0\t-\n")
print("staged hostint share (3 ELFs + host-int credential + 2 refusal plants"
      " + 6-path drop gesture) + 2 clean shares")
PY

# ---- 01: the full drop journey, one boot -------------------------------------
# --screen arms the virtio-gpu AND is the display path the drop lane needs
# at arm. The chain is marker-ordered: the gesture injects on the seat's
# armed marker (6 paths -> 4 DROP records + 2 refusals), the seat consumes
# one record per tick, and the open burst rides the seq=1 consume -- the
# file is in INBOX the moment the runner's `host-drop: file` printed, so
# the open is never racing delivery. The 10 s tail covers the remaining
# seat consumes. M127b (V2-D4): after the last DROP consumes, a pointer
# press on the newest toast (bottom of the strip, always 692<=y<712) runs
# its open-drop action -- mime.Open sniffs /host/INBOX/DUP-2.QOI and the
# registry execs GOVIEW on it.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script-seat.txt' \
    --host-drop \
    --host-drop-file '$RUN_DIR/drop-src/PHOTO.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/odd name!.qoi' \
    --host-drop-file '$RUN_DIR/drop-src/a/DUP.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/b/DUP.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/big.bin' \
    --host-drop-file '$RUN_DIR/drop-src/somedir' \
    --host-drop-after 'gotabwm: hostint armed' \
    --script2 '$RUN_DIR/script-open.txt' --script2-after 'gotabwm: hostint drop seq=1 name=PHOTO.QOI' \
    --pointer-virtio '112,702,c' \
    --pointer-virtio-after 'gotabwm: hostint drop seq=4 name=DUP-2.QOI' \
    --script-expect 'gview: open id=' --script-expect-tail 10 --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
# The lane armed: ONE shared session, the mask naming drop.
vgate_assert 01 output-contains 'host-int: armed lanes=drop epoch='
vgate_assert 01 serial-contains 'gotabwm: hostint armed epoch='
vgate_assert 01 serial-contains 'lanes=drop'
# The planted refusals on the DROP tag: foreign-epoch signed record and
# the forgery -- named, deleted, never toasted.
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=drop reason=stale_epoch'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=drop reason=bad_mac'
vgate_assert 01 serial-absent 'host drop: STALE.QOI'
vgate_assert 01 serial-absent 'host drop: FORGED.QOI'
# The gesture: six paths through the real handler -> four landings in
# seq order, two named refusals, no record for either refusal.
vgate_assert 01 output-contains 'host-drop: inject files=6'
vgate_assert 01 output-contains 'host-drop: file seq=1 name=PHOTO.QOI'
vgate_assert 01 output-contains 'host-drop: file seq=2 name=odd_name_.qoi'
vgate_assert 01 output-contains 'host-drop: file seq=3 name=DUP.QOI'
vgate_assert 01 output-contains 'host-drop: file seq=4 name=DUP-2.QOI'
vgate_assert 01 output-contains 'host-int: refuse lane=drop reason=payload_too_large'
vgate_assert 01 output-contains 'host-int: refuse lane=drop reason=unsupported_kind'
# The seat side: verified notices became the drop receipt and the
# kind-12 toast (sender id 0 -- the open-drop action, not a focus).
vgate_assert 01 serial-contains 'gotabwm: hostint drop seq=1 name=PHOTO.QOI'
vgate_assert 01 serial-contains 'gotabwm: hostint drop seq=4 name=DUP-2.QOI'
vgate_assert 01 serial-contains 'gotabwm: notify id=0 host drop: PHOTO.QOI'
# MIME dispatch unchanged: the landed file routes to the image handler.
vgate_assert 01 serial-contains 'gosh: open launched scheme=file target=/host/INBOX/PHOTO.QOI handler=GOVIEW.ELF'
vgate_assert 01 serial-contains 'gview: open id='
# M127b (V2-D4): the press on the newest toast dispatched DUP-2.QOI
# through the opens= table -- image magic named GOVIEW, argv the path.
vgate_assert 01 serial-contains 'gotabwm: hostint drop-open name=DUP-2.QOI app=GOVIEW.ELF'
vgate_assert 01 serial-absent '[EXC] parking:'
# The credential never reaches serial or runner stdout.
vgate_assert 01 serial-absent 'dropkey0dropkey0'
vgate_assert 01 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
key = open(os.path.join(run, "key-sentinel.txt")).read().strip()
if key in out:
    sys.exit("FAIL: the lane key reached runner stdout")
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
want = os.path.getsize("tests/fixtures/qoi/viewer_160x120.qoi")
# INBOX holds the four landings and NOTHING else: no refusal leaked a
# file, no publish temp survived.
inbox = sorted(os.listdir(os.path.join(share, "INBOX")))
if inbox != ["DUP-2.QOI", "DUP.QOI", "PHOTO.QOI", "odd_name_.qoi"]:
    sys.exit("FAIL: INBOX = %r" % inbox)
for n in inbox:
    if os.path.getsize(os.path.join(share, "INBOX", n)) != want:
        sys.exit("FAIL: INBOX/%s size != %d" % (n, want))
left = [n for n in os.listdir(os.path.join(share, "HOSTINT"))
        if not n.endswith("~")]
if left:
    sys.exit("FAIL: unconsumed lane files left in HOSTINT: %r" % left)
print("run-01 INBOX + lane hygiene ok")
PY

# ---- 02: flags-off is byte-silent ---------------------------------------------
# Same credential+seat posture on a CLEAN share (off-share), no --host-drop:
# the runner never creates INBOX//HOSTINT/, writes no record, registers no
# drag type; the seat's once-per-tick listing sees a directory that never
# exists -- zero lane markers either end.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --cvc-file '$RUN_DIR/off-share' \
    --script '$RUN_DIR/script-seat.txt' \
    --script-expect 'gotabwm: mode live' --script-expect-tail 10 --timeout 180

vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: mode live'
vgate_assert 02 serial-absent 'gotabwm: hostint'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-02.out"), errors="replace").read()
for needle in ("host-int:", "host-drop:"):
    if needle in out:
        sys.exit("FAIL: flags-off run printed lane traffic: " + needle)
share = os.path.join(run, "off-share")
for d in ("HOSTINT", "INBOX"):
    if os.path.isdir(os.path.join(share, d)):
        sys.exit("FAIL: flags-off run created " + d + "/")
print("run-02 flags-off silence ok")
PY

# ---- 03: headless --host-drop refuses lane_disabled ---------------------------
# The drop target is the display view; a boot with no --screen/--display
# has none. The refusal is named at arm -- lane dead, boot continues, and
# no HOSTINT//INBOX/ is ever created (off-share2 stays clean).
vgate_run 03 -- \
    --cvc-file '$RUN_DIR/off-share2' \
    --host-drop \
    --script '$RUN_DIR/script-nop.txt' \
    --script-expect 'run03-booted' --script-expect-tail 3 --timeout 120

vgate_assert 03 output-contains 'host-int: refuse lane=drop reason=lane_disabled'
vgate_assert 03 serial-contains 'run03-booted'
vgate_assert 03 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-03.out"), errors="replace").read()
if "host-int: armed" in out:
    sys.exit("FAIL: a lane_disabled drop still published ARMED")
share = os.path.join(run, "off-share2")
for d in ("HOSTINT", "INBOX"):
    if os.path.isdir(os.path.join(share, d)):
        sys.exit("FAIL: lane_disabled arm created " + d + "/")
print("run-03 headless refusal ok")
PY
