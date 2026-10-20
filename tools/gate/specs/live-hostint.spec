# live-hostint.spec -- M108e (#2329, ADR 0051) class-B: the STANDING
# host-integration acceptance gate. Where the per-lane specs prove one
# lane each, this spec proves the arc: every lane exercised on ONE armed
# session AND the negatives the index's consent story rests on.
#
# Run 01 is the whole story on one boot: ARMED names clip,drop,notify on
# one shared epoch; the clipboard crosses both directions (host inject ->
# slot-38 apply -> named-pasteboard mirror of the guest write back); an
# 18-path drop gesture lands four files AND proves all three refusal
# caps in one shot (items 17-18 refused by the >16 gesture bound BEFORE
# per-item evaluation -- two regular files that would otherwise land --
# plus the 64 MiB size cap and the non-regular kind refusal); the four
# DROP toasts cross back out as NOTIFY_OUT records the bare runner
# drains as named no_bundle drops at the lane's 1/tick emit bound.
# The negatives ride the same boot:
#   - stale_epoch + bad_mac plants on BOTH inbound tags (signed under
#     the real key with a foreign epoch; forged under a wrong key) --
#     deleted, never applied, never toasted.
#   - anti-spoof: the guest plants a file in INBOX/ itself (vf, the
#     monitor's own share write) -> no DROP record, no `host drop:`
#     toast, the file just sits there; plus a guest-planted garbage
#     lane file in HOSTINT/ -> bad_record, deleted.
#   - consent: an unprivileged EL0 exec (GOCOMP -- no CAP_CLIPBOARD,
#     not the seat) hits the M97g wall on slot 39 with EACCES (-7), so
#     its bytes never reach the buffer and the runner shows exactly ONE
#     `host-clip: out` line -- the consented monitor write. (The
#     same-epoch re-ARMED mask revocation that produces consent_denied
#     cannot be planted in class B -- the epoch is minted per boot; it
#     is pinned host-side by gotabwm/hostint_test.go and
#     hostnotify_test.go's re-ARMED case.)
#
# Run 02 is the flags-off posture: the same credentialed share shape on
# a clean dir, ZERO lane flags -- no HOSTINT/, no INBOX/, no lane marker
# either end. Byte-silence for the arc, not per lane.
#
# Run 03 is no_credential on ALL THREE lanes at once: the share has the
# seat but no `host-int` row -- one arm, three named refusals, boot
# continues with every lane dead and no directories created.
#
# Run 04 is M114c (#2456): runtime lane suspend/resume over the HostCommand
# bus (`--host-cmd-after` fires the same verbs the Integration menu's
# toggles dispatch). Clip + drop are suspended right at arm (the bus
# republishes ARMED under the same epoch with the bits cleared; the seat
# re-adopts `lanes=notify`); while suspended the --host-clip-in inject and
# the --host-drop-after gesture are both refused lane_disabled and
# send-file receipts `disabled`; clip + drop resume on the stored marker
# (the seat re-adopts `lanes=clip,drop,notify` a second time) and the
# suspended-era write crosses as clip-out seq=1 — the lane held its diff,
# not lost it; send-file then performs and SENDME.QOI lands in INBOX/ ->
# seat DROP notice -> toast -> NOTIFY_OUT -> the bare runner's named
# no_bundle drop. Guest-side emit under a revoked mask prints
# lane_disabled ONLY when a toast is already staged for the lane
# (staging and emit pair inside one seat tick, so it cannot be planted
# in class B — the path is pinned by gotabwm/hostnotify_test.go's
# re-ARMED case); the class-B legs observe the runner-side lane_disabled
# refusals + the seat's mask re-adoption lines + the deferred emit.
#
# Run 05 is the M127f (#2604) acceptance journey — the through-the-glass
# 2.0 round trip on ONE armed session (lanes=drop,notify,outbox): the
# host drop lands TRIP.QOI -> seat toast -> a pointer press on the OLDER
# strip slot dispatches the drop-open action (M127b) while a GOFILES
# paste toast stays newest; GOSH `export` rides the OUTBOX lane to
# --host-outbox-dir (M127d); a `notify-click` bus verb answers the last
# consumed NOTIFY_OUT — the sender-bound GOFILES toast — as a signed
# NFOCUS the seat turns into focusHosted (M127c); and an AGENTD session
# under agentctl's `full` journey feeds AGENT/AUDIT receipts the host
# companion surfaces (`host-agent: watch`/`session open`/`close`) while
# `lane-agent` SIGSTOP/SIGCONTs the stream child mid-session (M127e).
# Ordering that makes it deterministic: the drop gesture waits for
# `gofiles: ready` so the paste input lands on a focused GOFILES; the
# paste input waits for the drop-toast marker so the GOFILES toast is
# seq=2 (the sender the click-through answers); the drop-open rides the
# center ROW (a persistent surface — no toast-expiry race): the pointer
# train opens the clock panel once `agent verb ui.windows` prints, then
# sweeps rows bottom-up so a dismissal can't shift the drop row out from
# under a later press (run 01's D.QOI click gets the same fallback); the
# lane-agent pause fires on
# `agentd: auth ok` (the stream child provably exists, and — because the
# connect itself waits on the paste toast — strictly after the burst) and
# resume fires on the export emit, which script3 only stages post-auth.
#
# The credential rides the share's SECRETS.TXT, bound to GOTABWM.ELF (the
# ADR 0024 D8 app binding). --screen arms the virtio-gpu the seat's
# WmctlRegister requires AND the display path the drop lane needs.
# exec-order: intentional -- run 05's later scripts exec several programs
# (AGENTD/GOCALC/GOFILES at arm, then GOSH post-auth); each consumer is
# gated on that program's own marker and the run ends on `hostint
# notify-focus`, which no script prints.
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-goview.sh    ->  .build/go/GOVIEW.ELF
#   bash tools/go/build-files.sh     ->  .build/go/GOFILES.ELF
#   bash tools/go/build-gosh.sh      ->  .build/go/GOSH.ELF
#   bash tools/go/build-agentd.sh    ->  .build/go/AGENTD.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#   GO_BUILD_NAME=GOCOMP bash tools/go/build-go.sh user/go/compose/main.go

vgate_name live-hostint "M108e #2329: standing host-integration acceptance -- all lanes + negatives (ADR 0051)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script-seat.txt <<'EOF'
exec GOTABWM.ELF
EOF

# The post-apply burst, gated on the real CLIP_IN landing: `clip` reads
# the host text back (h->g proven), `clip m108e-guest-copy-02` stores the
# local write the next seat diff carries out as CLIP_OUT (g->h). Then the
# two guest-side plants -- an INBOX file (anti-spoof: no notice, no
# toast) and a garbage HOSTINT record (bad_record) -- and the unprivileged
# clipboard probe (the consent wall).
vgate_file script-clip.txt <<'EOF'
clip
clip m108e-guest-copy-02
vf open INBOX/PLANTED.BIN
vf write 0 32
vf close 0
vf open HOSTINT/DROP-00000042
vf write 0 64
vf close 0
exec GOCOMP.ELF
EOF

# The post-emit read: the buffer holds the guest text while CLIP_OUT is
# in flight (the runner's echo guard must NOT bounce it back).
vgate_file script-read.txt <<'EOF'
clip
EOF

# M114c run 04: the suspended-era clipboard write — `clip` stores while
# the clip lane is suspended; the emit is deferred until resume (the
# seat's own deferral evidence: stored under the revoked mask, crossing
# after re-adoption).
vgate_file script-susp.txt <<'EOF'
clip m114c-deferred
EOF

# ---- run 05 (M127f): the through-the-glass 2.0 journey ----------------------
vgate_file script-v2-seat.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTABWM.ELF
EOF

# Armed: AGENTD (the M127e companion leg's endpoint) and GOFILES (the
# M127c sender toast) come up together; GOFILES is exec'd last so its
# declare takes focus — the paste input's target.
vgate_file script-v2-apps.txt <<'EOF'
exec AGENTD.ELF --allow-exec
exec GOCALC.ELF
exec GOFILES.ELF /host/NFY
EOF

# Post-paste, post-auth: the runner's TCP connect waits for the paste
# toast, so `agentd: auth ok` can only print once GOFILES's burst is
# done — the GOCALC declare this script makes can never steal the
# paste's focus. The export REQ then stages while the agent stream
# child sits SIGSTOP'd — the seat drains it under a frozen agent and
# the emit marker is what resumes the child.
vgate_file script-v2-late.txt <<'EOF'
exec GOSH.ELF -c "export DOCS/HELLO.TXT"
EOF


vgate_setup_python <<'PY'
import hashlib, hmac, os, shutil, struct, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
for name, build in (
    ("GOTABWM.ELF", "bash tools/go/build-gotabwm.sh"),
    ("GOVIEW.ELF", "bash tools/go/build-goview.sh"),
    ("GOCOMP.ELF", "GO_BUILD_NAME=GOCOMP bash tools/go/build-go.sh user/go/compose/main.go"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, name))
# wm=none: the seat is exec'd on script, like the per-lane specs.
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
# The lane credential: the row the seat reads via sys_secret_get (image
# binding needs the uid_system OWNERS row) and the runner reads as a host
# file. Value bytes ARE the HMAC key verbatim.
KEY = "m108ekey" * 8  # 64 bytes, ASCII
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# Planted lane records exercise the refusals live on BOTH inbound tags:
# (a) correctly signed under a foreign epoch -> stale_epoch; (b) forged
# under a wrong key -> bad_mac. All deleted, never applied/toasted.
def rec(tag, flags, seq, epoch, payload, key):
    hdr = b"VHI1" + bytes([tag, flags, 0, 0]) + struct.pack(
        "<IIH", seq, epoch, len(payload))
    body = hdr + payload
    return body + hmac.new(key.encode(), body, hashlib.sha256).digest()
def drop_payload(name, size):
    n = name.encode()
    return bytes([len(n)]) + n + struct.pack("<Q", size)
os.makedirs(os.path.join(share, "HOSTINT"), exist_ok=True)
open(os.path.join(share, "HOSTINT", "CLIPIN-00000077"), "wb").write(
    rec(2, 0, 0x77, 999, b"stale-epoch-plant", KEY))
open(os.path.join(share, "HOSTINT", "CLIPIN-00000088"), "wb").write(
    rec(2, 0, 0x88, 1, b"forged-plant", "wrongkey" * 8))
open(os.path.join(share, "HOSTINT", "DROP-00000077"), "wb").write(
    rec(4, 0, 0x77, 999, drop_payload("STALE.QOI", 9), KEY))
open(os.path.join(share, "HOSTINT", "DROP-00000088"), "wb").write(
    rec(4, 0, 0x88, 1, drop_payload("FORGED.QOI", 9), "wrongkey" * 8))
# The 18-path drop gesture: items 1-4 land (real QOIs), item 5 is over
# the 64 MiB cap (sparse), items 6-16 are not regular files, items 17-18
# are REGULAR files the >16 gesture bound refuses without ever
# evaluating -- the count cap named apart from the size cap by ordering.
qoi = "tests/fixtures/qoi/viewer_160x120.qoi"
src_dir = os.path.join(run, "drop-src")
os.makedirs(os.path.join(src_dir, "somedir"), exist_ok=True)
for i in range(1, 11):
    os.makedirs(os.path.join(src_dir, "d%02d" % i), exist_ok=True)
for n in ("A.QOI", "B.QOI", "C.QOI", "D.QOI", "TAIL1.QOI", "TAIL2.QOI"):
    shutil.copy(qoi, os.path.join(src_dir, n))
with open(os.path.join(src_dir, "BIG.BIN"), "wb") as f:
    f.truncate(65 * 1024 * 1024)  # sparse: over the 64 MiB cap, instant
# M114c run 04: the send-file source — the --host-drop-file list doubles
# as the bus verb's file source. --host-drop-after 'lanes=notify' fires
# the marker-path drop WHILE drop is suspended (the lane_disabled
# refusal); the bus's send-file then delivers the same list post-resume.
os.makedirs(os.path.join(run, "send-src"), exist_ok=True)
shutil.copy(qoi, os.path.join(run, "send-src", "SENDME.QOI"))
open(os.path.join(run, "key-sentinel.txt"), "w").write(KEY + "\n")
# The flags-off and no_credential postures need shares the lane never
# armed: the runner owns HOSTINT//INBOX/ creation, so a boot on THESE
# directories proves byte-silence / the arm refusal while holding the
# same seat + wm=none posture the armed run uses.
for off in ("off-share", "nocred-share"):
    d = os.path.join(run, off)
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(".build", "go", "GOTABWM.ELF"),
                os.path.join(d, "GOTABWM.ELF"))
    open(os.path.join(d, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
    open(os.path.join(d, "OWNERS.TXT"), "w").write(
        "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# off-share keeps the credential (flags are the consent switch);
# nocred-share deliberately omits the host-int row.
open(os.path.join(run, "off-share", "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
print("staged hostint share (3 ELFs + credential + 4 refusal plants"
      " + 18-path drop gesture) + 2 clean shares")
PY

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
sys.path.insert(0, os.path.join("tools", "agentctl"))
import agentctl
# Run 05 stages on the armed share — the companion resolves argv's
# first --cvc-file (the harness's own), so the audit lane must live on
# the seeded share for host-agent: to see receipts.
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
for name, build in (
    ("GOFILES.ELF", "bash tools/go/build-files.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
    ("AGENTD.ELF", "bash tools/go/build-agentd.sh"),
    ("GOCALC.ELF", "bash tools/go/build-gocalc.sh"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, name))
# The agent's Ed25519 identity: the seed stays host-side ($RUN_DIR key
# file, never argv); AGENTS.TXT carries the public half with full caps
# for the `full` journey.
SEED = "0a" * 32
pub = agentctl.ed_public_key(bytes.fromhex(SEED)).hex()
open(os.path.join(share, "AGENTS.TXT"), "w").write(
    "#v1\nagent=devin key=%s caps=file,process,window,term\n" % pub)
open(os.path.join(run, "devin.key"), "w").write("devin " + SEED + "\n")
# The M109c receipt key, appended beside the host-int row: agentd signs
# with it, the seat's agentwatch and the host companion both verify —
# one provisioned row, three readers (the ADR 0051 v2 double-reader).
# (These are APPENDS — the block above owns the file's host-int row.)
AKEY = "a5" * 32
with open(os.path.join(share, "SECRETS.TXT"), "a") as f:
    f.write("agent-hmac\t1000\t" + AKEY + "\tAGENTD.ELF,GOTABWM.ELF\n")
with open(os.path.join(share, "OWNERS.TXT"), "a") as f:
    f.write("AGENTD.ELF\t644\t0\t-\nAGENTS.TXT\t444\t0\t-\n")
# The agent sandbox + the journey's fs fixture set (imported constants,
# so the fixtures live in tools/agentctl).
ad = os.path.join(share, "AGENT")
os.makedirs(os.path.join(ad, "AUDIT"), exist_ok=True)
os.makedirs(os.path.join(ad, "SUB"), exist_ok=True)
open(os.path.join(ad, "SEED.TXT"), "wb").write(agentctl.SEED_BYTES)
open(os.path.join(ad, "SUB", "DEEP.TXT"), "wb").write(agentctl.DEEP_BYTES)
open(os.path.join(ad, "WIDE.TXT"), "wb").write(agentctl.wide_bytes())
open(os.path.join(ad, "BIG.BIN"), "wb").write(b"\x00" * 4097)
# The export source (GOSH resolves `export DOCS/x` against the share
# root), the GOFILES paste range (one dir, one file — a single
# `copied SRC.TXT` toast), and the journey's drop payload + landing dir.
# OUTBOX/ is pre-created so the seat's first outbox poll cannot race the
# runner's mkdir into an io_error refusal toast (which would push an
# extra center row ahead of the drop's).
os.makedirs(os.path.join(share, "DOCS"), exist_ok=True)
open(os.path.join(share, "DOCS", "HELLO.TXT"), "w").write(
    "through the glass, back again\n")
os.makedirs(os.path.join(share, "NFY", "D1"), exist_ok=True)
open(os.path.join(share, "NFY", "SRC.TXT"), "w").write(
    "notify-range-payload\n")
os.makedirs(os.path.join(share, "OUTBOX"), exist_ok=True)
shutil.copy("tests/fixtures/qoi/viewer_160x120.qoi",
            os.path.join(run, "drop-src", "TRIP.QOI"))
os.makedirs(os.path.join(run, "dest05"), exist_ok=True)
open(os.path.join(run, "agent-hmac-sentinel.txt"), "w").write(AKEY + "\n")
print("staged v2 journey: +4 ELFs, agentd keyring + audit lane, DOCS/NFY"
      " fixtures, TRIP.QOI + dest05")
PY

# ---- 01: every lane + every negative, one boot -------------------------------
# --screen arms the virtio-gpu (WmctlRegister) AND the drop lane's
# display precondition. The chain is strictly marker-ordered: both
# injects fire on the seat's armed marker; the clip burst + plants +
# consent probe ride the clip-in apply; the final read rides clip-out.
# The 12 s tail drains the four DROP toasts' NOTIFY_OUT emits (1/tick)
# and the runner's 250 ms consume of them. M127b (V2-D4): after the last
# DROP consumes, a pointer press on the newest toast (bottom of the
# strip, always 692<=y<712) runs its open-drop action — mime.Open sniffs
# /host/INBOX/D.QOI and the registry execs GOVIEW on it.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-clip.txt' --script2-after 'gotabwm: hostint clip-in seq=1' \
    --script3 '$RUN_DIR/script-read.txt' --script3-after 'gotabwm: hostint clip-out seq=1' \
    --host-clipboard --host-pasteboard 'virelai-m108e-clip' \
    --host-clip-in 'm108e-host-paste-01' --host-clip-in-after 'gotabwm: hostint armed' \
    --host-drop \
    --host-drop-file '$RUN_DIR/drop-src/A.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/B.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/C.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/D.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/BIG.BIN' \
    --host-drop-file '$RUN_DIR/drop-src/somedir' \
    --host-drop-file '$RUN_DIR/drop-src/d01' \
    --host-drop-file '$RUN_DIR/drop-src/d02' \
    --host-drop-file '$RUN_DIR/drop-src/d03' \
    --host-drop-file '$RUN_DIR/drop-src/d04' \
    --host-drop-file '$RUN_DIR/drop-src/d05' \
    --host-drop-file '$RUN_DIR/drop-src/d06' \
    --host-drop-file '$RUN_DIR/drop-src/d07' \
    --host-drop-file '$RUN_DIR/drop-src/d08' \
    --host-drop-file '$RUN_DIR/drop-src/d09' \
    --host-drop-file '$RUN_DIR/drop-src/d10' \
    --host-drop-file '$RUN_DIR/drop-src/TAIL1.QOI' \
    --host-drop-file '$RUN_DIR/drop-src/TAIL2.QOI' \
    --host-drop-after 'gotabwm: hostint armed' \
    --host-notify \
    --pointer-virtio '112,702,c;1250,702,c;640,465,c;640,431,c;640,397,c;640,363,c;640,329,c;640,295,c;640,261,c;640,227,c' \
    --pointer-virtio-after 'gotabwm: hostint drop seq=4 name=D.QOI' \
    --script-expect 'clip: m108e-guest-copy-02' --script-expect-tail 130 --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
# ONE shared session, all three lane bits named at both ends.
vgate_assert 01 output-contains 'host-int: armed lanes=clip,drop,notify epoch='
vgate_assert 01 serial-contains 'gotabwm: hostint armed epoch='
vgate_assert 01 serial-contains 'lanes=clip,drop,notify'
# The planted refusals on BOTH inbound tags: foreign-epoch signed
# records and the forgeries -- named, deleted, never applied.
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=clip reason=stale_epoch'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=clip reason=bad_mac'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=drop reason=stale_epoch'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=drop reason=bad_mac'
vgate_assert 01 serial-absent 'stale-epoch-plant'
vgate_assert 01 serial-absent 'forged-plant'
vgate_assert 01 serial-absent 'host drop: STALE.QOI'
vgate_assert 01 serial-absent 'host drop: FORGED.QOI'
# The guest-planted garbage lane file: bad_record, deleted, no toast.
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=drop reason=bad_record'
# Clipboard h->g: the inject fired on armed, the seat applied CLIP_IN
# through slot 38, the badge flipped host-marked, `clip` reads it back.
vgate_assert 01 output-contains 'host-clip: inject len=19'
vgate_assert 01 output-contains 'host-clip: in seq=1 sha256=132b3de9 len=19 truncated=0'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-in seq=1 len=19 sha=132b3de9 truncated=0'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-ind host'
vgate_assert 01 serial-contains 'clip: m108e-host-paste-01'
# Clipboard g->h: the monitor `clip` write was observed on the seat's
# slot-39 poll, emitted as CLIP_OUT, mirrored to the named pasteboard;
# the post-emit read shows the buffer holding the guest text.
vgate_assert 01 serial-contains 'clip: stored 19 bytes'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-out seq=1 len=19 sha=49c72bc0'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-ind local'
vgate_assert 01 output-contains 'host-clip: out seq=1 sha256=49c72bc0 len=19'
vgate_assert 01 serial-contains 'clip: m108e-guest-copy-02'
# The consent wall: the unprivileged EL0 exec is refused on slot 39
# (EACCES = -7, the M97g gate) and never reaches slot 38 -- its bytes
# cannot cross a lane it was never consented into.
vgate_assert 01 serial-contains 'compose: paste refused rc=-7'
vgate_assert 01 serial-contains 'tasks user-exec exited status=2'
# The drop gesture: 18 paths -> four landings in seq order, the two
# count-cap refusals (items 17-18, regular files never evaluated), the
# size cap, and eleven kind refusals.
vgate_assert 01 output-contains 'host-drop: inject files=18'
vgate_assert 01 output-contains 'host-drop: file seq=1 name=A.QOI'
vgate_assert 01 output-contains 'host-drop: file seq=2 name=B.QOI'
vgate_assert 01 output-contains 'host-drop: file seq=3 name=C.QOI'
vgate_assert 01 output-contains 'host-drop: file seq=4 name=D.QOI'
# The seat side: verified notices became the drop receipt and the
# kind-12 toast (sender id 0 -- the open-drop action, not a focus).
vgate_assert 01 serial-contains 'gotabwm: hostint drop seq=1 name=A.QOI'
vgate_assert 01 serial-contains 'gotabwm: hostint drop seq=4 name=D.QOI'
vgate_assert 01 serial-contains 'gotabwm: notify id=0 host drop: A.QOI'
# M127b (V2-D4): the press on the newest toast dispatched D.QOI through
# the opens= table -- image magic named GOVIEW, the INBOX path rode argv.
vgate_assert 01 serial-contains 'gotabwm: hostint drop-open name=D.QOI app=GOVIEW.ELF'
vgate_assert 01 serial-contains 'gview: open id='
# Notify-out: the drop toasts crossed back as NOTIFY_OUT records the
# bare runner consumed as named no_bundle drops, never a claimed post.
vgate_assert 01 serial-contains 'gotabwm: hostint notify-out seq=1'
vgate_assert 01 output-contains 'host-notify: dropped reason=no_bundle seq=1 n=1'
# The credential and payload text never reach serial or runner stdout.
vgate_assert 01 serial-absent 'm108ekeym108ekey'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
ser = open(os.environ["VG_SER"], errors="replace").read()
# Never-logged: the lane key stays off runner stdout entirely; payload
# text stays off every `host-*` lane line. The forwarded serial
# transcript inside run-01.out legitimately carries the guest's own
# `clip` echo -- that is the seat's console, not a lane marker, so the
# check is scoped to the lane's own line shapes.
key = open(os.path.join(run, "key-sentinel.txt")).read().strip()
if key in out:
    sys.exit("FAIL: the lane key reached runner stdout")
for line in out.splitlines():
    if line.startswith(("host-int:", "host-clip:", "host-drop:", "host-notify:")):
        for text in ("m108e-host-paste-01", "m108e-guest-copy-02"):
            if text in line:
                sys.exit("FAIL: a lane line carried payload text: " + line[:80])
# The consent consequence: exactly ONE guest->host clipboard record
# exists -- the monitor's own write. Had the unprivileged probe's bytes
# reached the buffer, a second CLIP_OUT would name them.
if out.count("host-clip: out ") != 1:
    sys.exit("FAIL: expected exactly 1 host-clip: out line (the consented "
             "write), got %d" % out.count("host-clip: out "))
# The drop refusal shape: exactly three payload_too_large (2 count-cap +
# 1 size) and eleven unsupported_kind, and the count-cap pair precedes
# every per-item line -- items 17-18 were refused by COUNT, never
# evaluated (a regular file would otherwise have landed).
ptl = [m.start() for m in re.finditer(r"reason=payload_too_large", out)]
uk = [m.start() for m in re.finditer(r"reason=unsupported_kind", out)]
first_item = out.find("host-drop: file ")
if len(ptl) != 3 or len(uk) != 11:
    sys.exit("FAIL: refusal counts ptl=%d uk=%d (want 3/11)"
             % (len(ptl), len(uk)))
if not (ptl[0] < first_item and ptl[1] < first_item and ptl[2] > first_item):
    sys.exit("FAIL: count-cap refusals not ordered before the landings")
for tail in ("TAIL1.QOI", "TAIL2.QOI"):
    if "name=" + tail in out:
        sys.exit("FAIL: over-cap item named in a drop marker: " + tail)
# Anti-spoof: the guest-planted INBOX file earned no DROP record and no
# toast -- the file exists (proven below) yet the host never announced it.
if "name=PLANTED" in out or "host drop: PLANTED" in ser:
    sys.exit("FAIL: a guest-planted INBOX file was attributed to the host")
# Notify-out: every seq the seat emitted, the runner consumed in order
# as a named no_bundle drop -- and at least one `gotabwm: tick` sits
# between each pair of emit markers (the 1/tick structural bound).
if "host-notify: post" in out:
    sys.exit("FAIL: bare runner claimed a banner post")
emitted = [int(m) for m in re.findall(r"hostint notify-out seq=(\d+)", ser)]
dropped = [int(m) for m in re.findall(
    r"host-notify: dropped reason=no_bundle seq=(\d+)", out)]
if len(emitted) < 4:
    sys.exit("FAIL: only %d notify-out emits" % len(emitted))
if emitted != sorted(emitted) or emitted[0] != 1:
    sys.exit("FAIL: emit seqs not monotonic from 1: %r" % emitted)
if dropped != emitted:
    sys.exit("FAIL: runner consumed %r but seat emitted %r" % (dropped, emitted))
lines = ser.splitlines()
emit_at = [i for i, l in enumerate(lines) if "hostint notify-out seq=" in l]
for a, b in zip(emit_at, emit_at[1:]):
    if not any("gotabwm: tick" in l for l in lines[a + 1:b]):
        sys.exit("FAIL: two notify-out emits inside one seat tick")
# End state: INBOX holds the four landings + the guest's own plant and
# NOTHING else -- no refusal leaked a file, no temp survived; HOSTINT
# has no unconsumed lane files.
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
want = os.path.getsize("tests/fixtures/qoi/viewer_160x120.qoi")
inbox = sorted(os.listdir(os.path.join(share, "INBOX")))
if inbox != ["A.QOI", "B.QOI", "C.QOI", "D.QOI", "PLANTED.BIN"]:
    sys.exit("FAIL: INBOX = %r" % inbox)
for n in inbox:
    if n == "PLANTED.BIN":
        continue
    if os.path.getsize(os.path.join(share, "INBOX", n)) != want:
        sys.exit("FAIL: INBOX/%s size != %d" % (n, want))
left = [n for n in os.listdir(os.path.join(share, "HOSTINT"))
        if not n.endswith("~")]
if left:
    sys.exit("FAIL: unconsumed lane files left in HOSTINT: %r" % left)
print("run-01 arc: lanes live, %d notify emits paced, caps + anti-spoof"
      " + consent all held" % len(emitted))
PY

# ---- 02: flags-off is byte-silent across the whole arc -----------------------
# Same credential + seat + wm=none posture on a CLEAN share, ZERO lane
# flags: the runner never creates HOSTINT/ or INBOX/, never writes a
# record, never reads a pasteboard or the notification center; the
# seat's once-per-tick listing sees a directory that never exists --
# zero lane markers either end. The credential is present on purpose:
# the flags are the consent switch, not the row.
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
for needle in ("host-int:", "host-clip:", "host-drop:", "host-notify:"):
    if needle in out:
        sys.exit("FAIL: flags-off run printed lane traffic: " + needle)
share = os.path.join(run, "off-share")
for d in ("HOSTINT", "INBOX"):
    if os.path.isdir(os.path.join(share, d)):
        sys.exit("FAIL: flags-off run created " + d + "/")
print("run-02 flags-off silence ok")
PY

# ---- 03: no_credential refuses every lane at arm -----------------------------
# The share has the seat but NO `host-int` row: all three flags request
# lanes, the one credential load fails, and each requested lane logs its
# own no_credential -- the boot continues with every lane dead (fail
# closed per lane, never a boot failure) and nothing is created.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --cvc-file '$RUN_DIR/nocred-share' \
    --host-clipboard --host-drop --host-notify \
    --script '$RUN_DIR/script-seat.txt' \
    --script-expect 'gotabwm: mode live' --script-expect-tail 8 --timeout 180

vgate_assert 03 output-contains 'host-int: refuse lane=clip reason=no_credential'
vgate_assert 03 output-contains 'host-int: refuse lane=drop reason=no_credential'
vgate_assert 03 output-contains 'host-int: refuse lane=notify reason=no_credential'
vgate_assert 03 serial-contains 'gotabwm: registered'
vgate_assert 03 serial-contains 'gotabwm: mode live'
vgate_assert 03 serial-absent 'gotabwm: hostint'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-03.out"), errors="replace").read()
if "host-int: armed" in out:
    sys.exit("FAIL: a credentialless arm still published ARMED")
share = os.path.join(run, "nocred-share")
for d in ("HOSTINT", "INBOX"):
    if os.path.isdir(os.path.join(share, d)):
        sys.exit("FAIL: no_credential arm created " + d + "/")
print("run-03 no_credential refusal ok")
PY

# ---- 04: M114c runtime lane suspend/resume + send-file over the bus -----
# The marker chain is strictly ordered by the seat's own armed lines:
# arm (lanes=clip,drop,notify) -> both suspends fire -> seat adopts
# lanes=notify -> the suspended-lane workload runs -> the stored clip
# write's marker resumes clip (lanes=clip,notify) -> the deferred write's
# clip-out seq=1 resumes drop (lanes=clip,drop,notify a second time) AND
# fires send-file on the same scan, argv-ordered resume-then-send.
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-susp.txt' --script2-after 'lanes=notify' \
    --host-clipboard --host-pasteboard 'virelai-m114c-clip' \
    --host-clip-in 'm114c-suspended-paste' --host-clip-in-after 'lanes=notify' \
    --host-drop \
    --host-drop-file '$RUN_DIR/send-src/SENDME.QOI' \
    --host-drop-after 'lanes=notify' \
    --host-notify \
    --host-cmd-after 'gotabwm: hostint armed:lane-clipboard' \
    --host-cmd-after 'gotabwm: hostint armed:lane-drop' \
    --host-cmd-after 'lanes=notify:send-file' \
    --host-cmd-after 'clip: stored 14 bytes:lane-clipboard' \
    --host-cmd-after 'clip: stored 14 bytes:lane-drop' \
    --host-cmd-after 'gotabwm: hostint clip-out seq=1:send-file' \
    --script-expect 'gotabwm: notify id=0 host drop: SENDME.QOI' --script-expect-tail 10 --timeout 300

# The arm + the seat's re-adoptions narrate the suspension arc: suspended
# lanes leave the published mask, resumed lanes return.
vgate_assert 04 output-contains 'host-int: armed lanes=clip,drop,notify epoch='
vgate_assert 04 output-contains 'host-int: armed lanes=notify epoch='
vgate_assert 04 serial-contains 'lanes=notify'
vgate_assert 04 serial-contains 'lanes=clip,notify'
vgate_assert 04 serial-count 'lanes=clip,drop,notify' 2
# The bus receipts: two toggles each (suspend + resume) performing, the
# send-file refused while the drop lane was suspended and performed after
# resume.
vgate_assert 04 output-contains 'host-ui: cmd=lane-clipboard vm=1 state=performed'
vgate_assert 04 output-contains 'host-ui: cmd=lane-drop vm=1 state=performed'
vgate_assert 04 output-contains 'host-ui: cmd=send-file vm=1 state=disabled'
vgate_assert 04 output-contains 'host-ui: cmd=send-file vm=1 state=performed'
# Suspended lanes refuse lane_disabled (the ADR 0051 vocabulary, both
# directions): the marker-fired clip-in inject refused at the lane's
# entry; the marker-fired drop gesture refused the same way.
vgate_assert 04 output-contains 'host-int: refuse lane=clip reason=lane_disabled'
vgate_assert 04 output-contains 'host-int: refuse lane=drop reason=lane_disabled'
# Resume recovery: the write made WHILE clip was suspended crosses as the
# lane's first emit after resume — the diff survived the suspension.
vgate_assert 04 serial-contains 'clip: stored 14 bytes'
vgate_assert 04 serial-contains 'gotabwm: hostint clip-out seq=1 len=14'
# send-file: the staged list lands SENDME.QOI in INBOX/, the seat's DROP
# apply toasts it, and the toast crosses the notify lane back out.
vgate_assert 04 output-contains 'host-drop: send files=1'
vgate_assert 04 output-contains 'host-drop: file seq=1 name=SENDME.QOI'
vgate_assert 04 serial-contains 'gotabwm: hostint drop seq=1 name=SENDME.QOI'
vgate_assert 04 serial-contains 'gotabwm: notify id=0 host drop: SENDME.QOI'
vgate_assert 04 serial-contains 'gotabwm: hostint notify-out seq=1'
vgate_assert 04 output-contains 'host-notify: dropped reason=no_bundle seq=1 n=1'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-04.out"), errors="replace").read()
ser = open(os.environ["VG_SER"], errors="replace").read()
# The suspension ordering is real, not just presence: suspend receipts
# before the suspended-lane refusals, refusals before the resume + landing.
def idx(s):
    i = out.find(s)
    if i < 0: sys.exit("FAIL: missing " + s)
    return i
susp = idx("host-ui: cmd=lane-drop vm=1 state=performed")
refuse = idx("host-int: refuse lane=drop reason=lane_disabled")
land = idx("host-drop: file seq=1 name=SENDME.QOI")
if not (susp < refuse < land):
    sys.exit("FAIL: suspend/refuse/landing not ordered")
# INBOX holds the send-file landing (run 01's own drops share this share —
# SENDME.QOI lands by its own name, byte-identical to the fixture).
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
want = os.path.getsize("tests/fixtures/qoi/viewer_160x120.qoi")
got = os.path.join(share, "INBOX", "SENDME.QOI")
if not os.path.isfile(got):
    sys.exit("FAIL: INBOX/SENDME.QOI missing")
if os.path.getsize(got) != want:
    sys.exit("FAIL: INBOX/SENDME.QOI size != %d" % want)
# The send-file was the ONLY thing that could publish SENDME.QOI: the
# suspended-era marker gesture refused before publishing, so exactly one
# DROP record ever reached INBOX (the runner's `host-drop: file` line —
# the seat's own `hostint drop` echo also sits in the merged output).
if out.count("host-drop: file seq=") != 1:
    sys.exit("FAIL: %d host-drop landings" % out.count("host-drop: file seq="))
# The suspended-era clip write crossed exactly once — after resume.
if out.count("host-clip: out ") != 1:
    sys.exit("FAIL: expected exactly 1 host-clip: out (the resumed emit)")
# Never-logged: lane key + payload text stay off every host-* lane line.
key = open(os.path.join(run, "key-sentinel.txt")).read().strip()
if key in out:
    sys.exit("FAIL: the lane key reached runner stdout")
print("run-04: suspend -> lane_disabled refusals -> resume recovery +"
      " send-file landing all held")
PY

# ---- 05: M127f (#2604) — the through-the-glass 2.0 journey, one boot --------
# The ordering spine (each edge is causal, none is a sleep): armed ->
# GOFILES declares focused -> the drop gesture lands TRIP.QOI and its
# action toast stages for the notify lane AND the center -> the paste
# input types into the still-focused GOFILES and `copied SRC.TXT` is the
# NEWEST notify-out (seq=2, sender=tab) -> the first press opens the
# center on the clock chrome, the second clicks history row 0 — the
# drop's persistent row carries the same drop-open action the toast did,
# with NO expiry window to race (M127b) -> GOVIEW opens -> the runner's
# TCP connect, held on the paste toast, only now reaches agentd ->
# `agentd: auth ok` pauses the agentctl stream child (lane-agent
# SIGSTOP) and releases script3's GOCALC+export -> the seat drains the
# REQ under a frozen agent and `hostint outbox seq=1` resumes the child
# (SIGCONT) -> the `full` journey completes -> session end fires
# `notify-click`: the last consumed record is the GOFILES toast, so the
# bare runner emits a signed NFOCUS{sender} and the seat focuses the tab
# (M127c). The AGENT/AUDIT receipts feed both mirrors — the seat's
# agentwatch markers and the host companion's `host-agent:` lines.
vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --net '$RUN_DIR/cap05.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=full' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-after 'gofiles: notify sent copied SRC.TXT' \
    --script '$RUN_DIR/script-v2-seat.txt' \
    --script2 '$RUN_DIR/script-v2-apps.txt' --script2-after 'gotabwm: hostint armed' \
    --script3 '$RUN_DIR/script-v2-late.txt' --script3-after 'agentd: auth ok agent=devin' \
    --host-drop \
    --host-drop-file '$RUN_DIR/drop-src/TRIP.QOI' \
    --host-drop-after 'gofiles: ready' \
    --host-notify \
    --host-outbox --host-outbox-dir '$RUN_DIR/dest05' \
    --input-string 'Gcglp' \
    --input-string-after 'gotabwm: notify id=0 host drop: TRIP.QOI' \
    --pointer-virtio '320,10,c;1250,702,c;640,465,c;640,431,c;640,397,c;640,363,c;640,329,c;640,295,c;640,261,c;640,227,c' \
    --pointer-virtio-after 'gotabwm: agent verb ui.windows' \
    --host-cmd-after 'agentd: auth ok agent=devin:lane-agent' \
    --host-cmd-after 'gotabwm: hostint outbox seq=1:lane-agent' \
    --host-cmd-after 'agentd: session end:notify-click' \
    --script-expect 'gotabwm: hostint notify-focus seq=1 id=' --script-expect-tail 95 --timeout 300

vgate_assert 05 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 05 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 05 serial-contains 'gotabwm: registered'
# ONE session, three lane bits named at both ends.
vgate_assert 05 output-contains 'host-int: armed lanes=drop,notify,outbox epoch='
vgate_assert 05 serial-contains 'gotabwm: hostint armed epoch='
vgate_assert 05 serial-contains 'lanes=drop,notify,outbox'
# The drop leg + the M127b click-open: the slot-0 press dispatched the
# action toast, mime sniffed QOI -> GOVIEW, the INBOX path rode argv.
vgate_assert 05 output-contains 'host-drop: inject files=1'
vgate_assert 05 output-contains 'host-drop: file seq=1 name=TRIP.QOI'
vgate_assert 05 serial-contains 'gotabwm: hostint drop seq=1 name=TRIP.QOI'
vgate_assert 05 serial-contains 'gotabwm: notify id=0 host drop: TRIP.QOI'
vgate_assert 05 serial-contains 'gotabwm: hostint drop-open name=TRIP.QOI app=GOVIEW.ELF'
vgate_assert 05 serial-contains 'gview: open id='
# The GOFILES sender toast: the last consumed NOTIFY_OUT record — the
# correlation the notify-click answers.
vgate_assert 05 serial-contains 'gofiles: notify sent copied SRC.TXT'
vgate_assert 05 serial-contains 'gotabwm: hostint notify-out seq=1'
vgate_assert 05 serial-contains 'gotabwm: hostint notify-out seq=2'
vgate_assert 05 output-contains 'host-notify: dropped reason=no_bundle seq=1 n=1'
vgate_assert 05 output-contains 'host-notify: dropped reason=no_bundle seq=2 n=2'
# M127c click-through: the bus verb emitted NFOCUS-00000001 against the
# sender, the seat verified it and ran focusHosted — the same seam the
# bundled banner's didReceive takes.
vgate_assert 05 output-contains 'host-ui: cmd=notify-click vm=1 state=performed'
vgate_assert 05 output-contains 'host-notify: click-focus id='
vgate_assert 05 serial-contains 'gotabwm: hostint notify-focus seq=1 id='
vgate_assert 05 serial-contains 'gotabwm: tab focus id='
vgate_assert 05 serial-contains 'gotabwm: host focus id='
# The M127d export leg: GOSH staged the REQ, the seat signed the record,
# the runner moved the payload to dest05.
vgate_assert 05 serial-contains 'gosh: export staged name=HELLO.TXT'
vgate_assert 05 serial-contains 'gotabwm: hostint outbox seq=1 name=HELLO.TXT'
vgate_assert 05 output-contains 'host-outbox: file seq=1 name=HELLO.TXT'
# The M127e agent leg: the Ed25519 session ran the full journey while
# the companion watched AGENT/AUDIT and lane-agent froze/thawed the
# stream child mid-session.
vgate_assert 05 serial-contains 'agentd: start exec=on'
vgate_assert 05 serial-contains 'agentd: listen 4747'
vgate_assert 05 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 05 serial-contains 'agentd: session end reason=line_too_long'
vgate_assert 05 output-contains 'NET-TCP-STREAM: ENABLED'
vgate_assert 05 output-contains 'AGENTCTL: PASS full'
vgate_assert 05 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 05 output-contains 'host-agent: watch'
vgate_assert 05 output-contains 'host-agent: session open agent=-'
vgate_assert 05 output-contains 'host-agent: session close agent=devin'
vgate_assert 05 output-contains 'host-agent: lane paused pid='
vgate_assert 05 output-contains 'host-agent: lane resumed pid='
vgate_assert 05 output-contains 'host-ui: cmd=lane-agent vm=1 state=performed paused=1'
vgate_assert 05 output-contains 'host-ui: cmd=lane-agent vm=1 state=performed paused=0'
# The seat's own agentwatch mirror read the same lane.
vgate_assert 05 serial-contains 'gotabwm: agent watch'
vgate_assert 05 serial-contains 'gotabwm: agent session open agent=-'
vgate_assert 05 serial-contains 'gotabwm: agent session close agent=devin'
# Never-logged: lane key, receipt key, agent seed stay off serial/stdout.
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'agentd: auth fail'
vgate_assert 05 serial-absent 'm108ekeym108ekey'
vgate_assert 05 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 05 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'
vgate_assert 05 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-05.out"), errors="replace").read()
ser = open(os.environ["VG_SER"], errors="replace").read()
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")

def sidx(s):
    i = ser.find(s)
    if i < 0: sys.exit("FAIL: missing serial marker " + s)
    return i

def oidx(s):
    i = out.find(s)
    if i < 0: sys.exit("FAIL: missing output marker " + s)
    return i

# The journey spine, in order: drop apply -> the drop toast -> the paste
# toast -> the click dispatched drop-open -> the viewer opened.
if not (sidx("hostint drop seq=1 name=TRIP.QOI")
        < sidx("notify id=0 host drop: TRIP.QOI")
        < sidx("gofiles: notify sent copied SRC.TXT")
        < sidx("hostint drop-open name=TRIP.QOI")
        < sidx("gview: open id=")):
    sys.exit("FAIL: drop -> toast -> paste -> click -> open ordering broken")
# The click-through answered a real tab id — never a seat toast — and
# the seat's notify-focus named the same pair.
m = re.search(r"host-notify: click-focus id=(\d+) seq=(\d+)", out)
n = re.search(r"hostint notify-focus seq=(\d+) id=(\d+)", ser)
if not m:
    sys.exit("FAIL: no runner click-focus receipt")
if not n:
    sys.exit("FAIL: no seat notify-focus receipt")
if m.group(1) == "0":
    sys.exit("FAIL: click answered a sender-0 toast")
if m.group(1) != n.group(2) or m.group(2) != n.group(1):
    sys.exit("FAIL: click-focus %r vs seat notify-focus %r"
             % (m.groups(), n.groups()))
# The focused tab IS the toast's sender — the focus markers that follow
# the notify-focus receipt name the same id.
after = ser[n.end():]
if ("gotabwm: tab focus id=" + n.group(2)) not in after or \
   ("gotabwm: host focus id=" + n.group(2)) not in after:
    sys.exit("FAIL: notify-focus did not focus the sender tab")
# The agent choke: the companion saw the session, the child froze, the
# journey still completed — pause strictly before resume before PASS.
if not (oidx("host-agent: session open") > -1 and
        oidx("host-agent: lane paused") < oidx("host-agent: lane resumed")
        < oidx("AGENTCTL: PASS full")):
    sys.exit("FAIL: pause/resume/pass ordering broken")
# The landed files are byte-true: the drop sits in INBOX at fixture
# size, the export moved to dest05 with the source's bytes.
want = os.path.getsize("tests/fixtures/qoi/viewer_160x120.qoi")
got = os.path.join(share, "INBOX", "TRIP.QOI")
if not os.path.isfile(got) or os.path.getsize(got) != want:
    sys.exit("FAIL: INBOX/TRIP.QOI missing or wrong size")
exp = open(os.path.join(share, "DOCS", "HELLO.TXT"), "rb").read()
landed = os.path.join(run, "dest05", "HELLO.TXT")
if not os.path.isfile(landed) or open(landed, "rb").read() != exp:
    sys.exit("FAIL: dest05/HELLO.TXT missing or content mismatch")
# Lane hygiene: HOSTINT holds no unconsumed records (NFOCUS included),
# no REQ marker survives, and the payload moved out of OUTBOX.
left = [x for x in os.listdir(os.path.join(share, "HOSTINT"))
        if not x.endswith("~")]
if left:
    sys.exit("FAIL: unconsumed lane files left in HOSTINT: %r" % left)
ob = sorted(os.listdir(os.path.join(share, "OUTBOX")))
if any(x.startswith("REQ-") for x in ob):
    sys.exit("FAIL: REQ markers left in OUTBOX: %r" % ob)
if "HELLO.TXT" in ob:
    sys.exit("FAIL: the payload stayed in OUTBOX after landing")
# The audit lane fed real receipts and the host companion verified
# every one (a 'rcpt bad' line anywhere is tamper evidence).
adir = os.path.join(share, "AGENT", "AUDIT")
rcpts = [x for x in os.listdir(adir)
         if x.startswith("RCPT-") and not x.endswith("~")]
if not rcpts:
    sys.exit("FAIL: no audit receipts landed in AGENT/AUDIT")
if "host-agent: rcpt bad" in out:
    sys.exit("FAIL: a receipt failed host-side MAC verification")
# Never-logged on the runner side: neither key nor the seed reached
# stdout (the serial transcript inside out may carry guest echoes only).
for secret in (
    open(os.path.join(run, "key-sentinel.txt")).read().strip(),
    open(os.path.join(run, "agent-hmac-sentinel.txt")).read().strip(),
    "0a" * 32,
):
    if secret in out:
        sys.exit("FAIL: a key reached runner stdout")
print("run-05 journey: %d receipts verified, drop-open + sender focus +"
      " export landing + lane pause/resume all held" % len(rcpts))
PY
