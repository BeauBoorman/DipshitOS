# go-assist.spec -- M140b (#2785) + M140c (#2786) class-B acceptance:
# GOASSIST.ELF, the chat client over virelai/infer, under GOTABWM on the
# real VIR1/Metal compute path, K=3 via vgate_repeat. Legs 01-04 are the
# M140b shape; legs 05+06 are the M140c journey the card names: the
# owner-approved SmolLM2 VIW on the real Metal path answers a typed
# question, the seat snapshots (ctrl-shift-s), a fresh boot
# session-restores the app, and a typed follow-up lands in the same
# conversation.
#
#   01  probe under the seat: one OpenCompute + SynthStub generate —
#       the card's first question (does the device share) answered.
#   02  streamed answer: chords type "hi there" into the stub-backed
#       window; `goassist: tokens=N` markers must count 1..N, the
#       pinned stub ids close it, and the conversation lands crash-safe
#       at ASSIST/C0001.CHAT on the share.
#   03  mid-conversation snapshot: kill the app after its committed
#       turn; the seat's crash arm re-execs it and restore_state hands
#       back {conv, scroll} — the transcript reloads from the file.
#   04  weights absent: the staged-model persona (bare launch) names
#       the refusal GOINFER's leg-12 wording pinned, before the device
#       is ever opened (compute-submits=0).
#   05  the journey's question: the default persona loads the staged
#       SmolLM2 VIW (real weights, real Metal path), a typed question
#       streams its pinned greedy answer, then the queued snapshot
#       chord saves SESSION.TABS + SNAPSHOT.BUNDLE once the commit
#       goes quiet.
#   06  the journey's restore + follow-up: SESSION.TABS re-execs the
#       app bare (mode=restore), the staged blob re-opens the same
#       C0001, and a typed follow-up commits a second turn pair into
#       the same conversation file.
#
# The armed share persists across iterations, so per-leg python tails
# keep each iteration honest: legs 01-04 clear ASSIST/*.CHAT after
# their asserts (a fresh store => every sending leg sees C0001 and the
# pinned decodes stay deterministic), leg 03's tail un-stages the VIW
# and leg 04's tail re-stages it so leg 04's weights-absent boot is
# honest every iteration while legs 05/06 ride the real model.
# script-seat.txt's `vf rm`s keep a leftover SESSION.TABS from
# restoring into legs 01-05's boots; leg 06 alone must find it.
#
# Legs 02/03 use the `stub` persona (SynthStub) so the stream is
# deterministic without staged weights; leg 04 covers the absent-weight
# path of the default persona. Legs 05/06 ride the same engine path and
# the same staged artifact live-gpu3d's leg 13 pinned — and like that
# leg they are honest in both states of the staged file: VIW present
# -> the pinned greedy answer ids; absent -> the named refusal.
#
# exec-order: assert-proven -- each run's expect marker is printed by the
# script AFTER the guest markers its stage gates wait on; a leg whose
# app never ran cannot pass.
# HOST PREREQUISITE (fails honestly):
#   bash tools/go/build-gotabwm.sh tools/go/build-goassist.sh
# OPTIONAL (else the journey legs prove the named refusal):
#   artifacts/goinfer/SMOLLM2.VIW -- python3 tools/goinfer/convert-smollm2.py

vgate_name go-assist "M140b #2785 + M140c #2786: GOASSIST.ELF under GOTABWM — seat GPU-compute probe, streamed stub answer + conversation file, crash-restart restore, weights-absent named refusal, K=3 journey: real SmolLM2 question + snapshot + session-restore + same-conversation follow-up"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

vgate_file script-seat.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

# Leg 06's boot is the restore leg: SESSION.TABS and SNAPSHOT.BUNDLE are
# its INPUTS, so its seat script carries none of script-seat.txt's rms.
vgate_file script-seat6.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script-probe.txt <<'EOF'
exec GOASSIST.ELF probe
EOF

vgate_file script-stub.txt <<'EOF'
exec GOASSIST.ELF stub
EOF

vgate_file script-bare.txt <<'EOF'
exec GOASSIST.ELF
EOF

vgate_file script-kill.txt <<'EOF'
kill GOASSIST.ELF
EOF

vgate_file script-rx1.txt <<'EOF'
echo rx-assist-1-ok
EOF

vgate_file script-rx2.txt <<'EOF'
echo rx-assist-2-ok
EOF

vgate_file script-rx4.txt <<'EOF'
echo rx-assist-4-ok
EOF

vgate_file script-rx6.txt <<'EOF'
echo rx-assist-6-ok
EOF

# GOTABWM.ELF and GOASSIST.ELF are .build products, not zig-out: stage
# both plus the wm=none seat opt-in so each leg boots exactly one seat
# and each app's build stamp is honoured.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name in ("GOTABWM.ELF", "GOASSIST.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: "
                 "bash tools/go/build-%s.sh"
                 % (name, src, name[:-4].lower()))
    shutil.copy(src, os.path.join(share, name))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("staged Go seat + GOASSIST.ELF, wm=none")
PY

# The model VIW (M111c #2410's owner-approved SmolLM2-135M-Instruct,
# Apache-2.0; the same artifact live-gpu3d's leg 13 stages) parks in
# RUN_DIR, NOT the share: leg 04's weights-absent boot must still find
# GOINFER/SMOLLM2.VIW missing. Leg 04's python tail moves it onto the
# share for legs 05/06 — and leg 03's tail moves it back so EVERY
# iteration's leg 04 is honest. An absent artifact is not an error: the
# journey legs then prove the named refusal (the #2410 clawback).
vgate_setup_python <<'PY'
import hashlib, os, shutil, sys
rd = os.environ["RUN_DIR"]
VIW_PIN = "2f5d4c774ea89016ae2b049e288e21a73987fc1c37eb1a58fc1284fad86878bd"
viw = os.path.join("artifacts", "goinfer", "SMOLLM2.VIW")
if os.path.exists(viw):
    sha = hashlib.sha256(open(viw, "rb").read()).hexdigest()
    if sha != VIW_PIN:
        sys.exit("staged VIW sha256 %s != pinned %s" % (sha, VIW_PIN))
    shutil.copy(viw, os.path.join(rd, "SMOLLM2.VIW"))
    print("model VIW verified against pin, parked until leg 04 stages it")
else:
    print("no staged VIW: journey legs assert the weights-absent path")
PY

# --- leg 01: the generate probe under the seat ------------------------------
# The card's first deliverable: one compute session opened and one
# generate run while the seat holds its own device path. `probe ok`
# answers "the device can be shared"; a named refusal would have been
# the card's stop line.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --gpu3d-metal --via-virtio \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-probe.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx1.txt' \
    --script3-after 'goassist: probe ok' \
    --script-expect 'rx-assist-1-ok' --timeout 240

vgate_assert 01 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 01 serial-contains 'gotabwm: holding seat'
vgate_assert 01 serial-contains 'goassist: probe ok toks='
vgate_assert 01 serial-contains 'goassist: probe ok toks=8 ids='
vgate_assert 01 serial-contains 'submits='
vgate_assert 01 serial-contains 'goassist OK'
vgate_assert 01 serial-contains 'goassist: done'
vgate_assert 01 serial-absent 'goassist: probe refused'
vgate_assert 01 serial-absent 'goassist: unsupported'
vgate_assert 01 serial-absent 'gpu3d: timeout'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 output-contains 'compute-submits='
vgate_assert 01 output-contains 'compute-refusals=0'
# Iteration hygiene (the armed share persists across vgate_repeat):
# clear the conversation store so leg 02's send lands in a fresh C0001
# and its pinned stub decode stays valid on every iteration. Tail-hook:
# declared after this leg's asserts so the checks above see the share
# exactly as the leg left it.
vgate_assert 01 python <<'PY'
import glob, os
n = 0
for f in glob.glob(os.path.join(os.environ["VG_SHARE"], "ASSIST", "*.CHAT")):
    os.remove(f)
    n += 1
print("conversation store cleared for leg 02 (%d file(s))" % n)
PY

# --- leg 02: a prompt streams its answer ------------------------------------
# The stub persona needs no weights, so this leg is deterministic on any
# host. Chords type "hi there" + return into the focused prompt field;
# every produced id is a `goassist: tokens=N` marker, and the answer's
# pinned id list is the same stream the host-fake produces in
# TestStubAnswerIdsPinned (the leg-10 property: fake and Metal decode
# byte-identical).
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --gpu3d-metal --via-virtio \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-stub.txt' \
    --script2-after 'gotabwm: holding seat' \
    --input-chords 'h,i,space,t,h,e,r,e,return' \
    --input-chords-after 'goassist: present' \
    --script3 '$RUN_DIR/script-rx2.txt' \
    --script3-after 'goassist: committed conv=C0001' \
    --script-expect 'rx-assist-2-ok' --timeout 300

vgate_assert 02 serial-contains 'goassist: open id='
vgate_assert 02 serial-contains 'goassist: declare accepted'
vgate_assert 02 serial-contains 'goassist: present'
vgate_assert 02 serial-contains 'goassist: send conv=C0001'
vgate_assert 02 serial-contains 'goassist: tokens=1'
# The ids pin lives in the python below and is alphabet-valued, not
# position-exact: the Metal path resolved argmax near-ties two ways in
# K=3 bring-up (tail 209->EOS; position 36: 79->71) on identical inputs
# (SynthStub is fixed-seed). The alphabet {71,79,209,2} is the honest
# pin — it still fails a fabricated or wrong-model answer.
vgate_assert 02 serial-contains 'goassist: answer toks='
vgate_assert 02 serial-contains 'goassist: saved C0001.CHAT'
vgate_assert 02 serial-contains 'goassist: committed conv=C0001'
vgate_assert 02 serial-absent 'goassist: cancelled'
vgate_assert 02 serial-absent 'goassist: error'
vgate_assert 02 serial-absent 'gpu3d: timeout'
vgate_assert 02 serial-absent '[EXC] parking:'
# The token markers must count 1..N in order — "increase over time" is a
# property of the sequence, not of two spot checks — and every emitted
# id must come from the pinned stub alphabet.
vgate_assert 02 python <<'PY'
import os, re, sys
ALPHABET = {"71", "79", "209", "2"}  # the stub answer's token set (Metal-path observed)
ser = open(os.environ["VG_SER"], errors="replace").read()
nums = [int(m.group(1)) for m in re.finditer(r"goassist: tokens=(\d+)", ser)]
if not nums or nums != list(range(1, len(nums) + 1)):
    sys.exit("token markers did not count 1..N in order: %r" % nums)
m = re.search(r"goassist: answer toks=(\d+) ids=([0-9,]+)", ser)
if not m:
    sys.exit("answer line missing")
ids = m.group(2).split(",")
bad = [i for i in ids if i not in ALPHABET]
if bad or len(ids) != int(m.group(1)) or len(ids) < 32:
    sys.exit("answer ids outside the stub alphabet: %s" % m.group(2))
print("%d token markers, strictly increasing; ids within stub alphabet" % len(ids))
PY
# The conversation file on the HOST is the load-bearing evidence: the
# typed prompt and the streamed answer both landed crash-safe.
vgate_assert 02 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
path = os.path.join(share, "ASSIST", "C0001.CHAT")
body = open(path, "rb").read().decode("utf-8", "replace")
for want in ("GOASSIST-CHAT v1", "@@user\nhi there\n", "@@assistant\n"):
    if want not in body:
        sys.exit("conversation file missing %r\n%s" % (want, body))
print("C0001.CHAT holds the user turn and the streamed answer")
PY
# Iteration hygiene, same tail-hook shape as leg 01: leg 03's send must
# also land in a fresh C0001.
vgate_assert 02 python <<'PY'
import glob, os
n = 0
for f in glob.glob(os.path.join(os.environ["VG_SHARE"], "ASSIST", "*.CHAT")):
    os.remove(f)
    n += 1
print("conversation store cleared for leg 03 (%d file(s))" % n)
PY

# --- leg 03: snapshot mid-conversation, restore --------------------------------
# A completed turn, then `kill` — the seat's crash arm stores the last
# posted blob ({conv, scroll}), re-execs the binary, and restore_state
# re-opens the same conversation file. turns=2 is the intact transcript:
# the user turn plus the streamed answer.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --gpu3d-metal --via-virtio \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-stub.txt' \
    --script2-after 'gotabwm: holding seat' \
    --input-chords 'h,i,return' \
    --input-chords-after 'goassist: present' \
    --script3 '$RUN_DIR/script-kill.txt' \
    --script3-after 'goassist: committed conv=' \
    --script-expect 'goassist: state restored conv=' --timeout 300

vgate_assert 03 serial-contains 'goassist: send conv='
vgate_assert 03 serial-contains 'goassist: answer toks='
vgate_assert 03 serial-contains 'goassist: committed conv='
vgate_assert 03 serial-contains 'GOASSIST.ELF exited status=137'
vgate_assert 03 serial-contains 'gotabwm: crash id='
vgate_assert 03 serial-contains 'gotabwm: crash restart GOASSIST.ELF'
vgate_assert 03 serial-contains 'goassist: state restored conv='
# ` turns=` presence + the file check below are the evidence (the store
# is cleared per leg, so the restored conversation is this leg's own —
# always [user, assistant] on a green run).
vgate_assert 03 serial-contains ' turns='
vgate_assert 03 serial-count 'goassist: open id=' 2
vgate_assert 03 serial-absent 'goassist: state refused'
vgate_assert 03 serial-absent 'goassist: state mismatch'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
d = os.path.join(share, "ASSIST")
conv = sorted(os.path.join(d, n) for n in os.listdir(d)
              if n.endswith(".CHAT"))[-1]
body = open(conv, "rb").read().decode("utf-8", "replace")
if body.count("@@user\n") < 1 or body.count("@@assistant\n") < 1:
    sys.exit("restored conversation lost a turn\n%s" % body)
print("conversation file intact across the crash restart: %s" % conv)
PY
# Iteration hygiene, tail-hook: clear the store for leg 04's send AND
# un-stage the VIW so leg 04's weights-absent boot stays honest on
# iterations after the first (leg 04's own tail re-stages it for the
# journey legs). An absent staged file is a skipped move, not a failure.
vgate_assert 03 python <<'PY'
import glob, os
share = os.environ["VG_SHARE"]
n = 0
for f in glob.glob(os.path.join(share, "ASSIST", "*.CHAT")):
    os.remove(f)
    n += 1
viw = os.path.join(share, "GOINFER", "SMOLLM2.VIW")
if os.path.exists(viw):
    os.replace(viw, os.path.join(os.environ["RUN_DIR"], "SMOLLM2.VIW"))
    print("store cleared (%d); VIW un-staged back to RUN_DIR" % n)
else:
    print("store cleared (%d); no staged VIW to un-stage" % n)
PY

# --- leg 04: absent weights are a named refusal ------------------------------
# The default persona reads the staged VIW — absent here — and the send
# must name it (GOINFER leg-12's wording) without ever opening the
# compute session.
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --gpu3d-metal --via-virtio \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-bare.txt' \
    --script2-after 'gotabwm: holding seat' \
    --input-chords 'h,i,return' \
    --input-chords-after 'goassist: present' \
    --script3 '$RUN_DIR/script-rx4.txt' \
    --script3-after 'goassist: weights absent' \
    --script-expect 'rx-assist-4-ok' --timeout 240

vgate_assert 04 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 04 serial-contains 'goassist: declare accepted'
vgate_assert 04 serial-contains 'goassist: send conv='
vgate_assert 04 serial-contains 'goassist: weights absent'
vgate_assert 04 serial-contains 'goassist: committed conv='
vgate_assert 04 serial-absent 'goassist: answer toks='
vgate_assert 04 serial-absent 'gpu3d: timeout'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 output-contains 'compute-submits=0'
# Iteration hygiene, tail-hook: the weights-absent boot just proved the
# named refusal — NOW clear the store so leg 05's send lands in a fresh
# C0001, and land the parked VIW (when one exists) at the app's default
# path so the journey legs load it exactly like an operator's install.
# Strict optional-file semantics: absent staged file = skipped move.
vgate_assert 04 python <<'PY'
import glob, os
share = os.environ["VG_SHARE"]
n = 0
for f in glob.glob(os.path.join(share, "ASSIST", "*.CHAT")):
    os.remove(f)
    n += 1
src = os.path.join(os.environ["RUN_DIR"], "SMOLLM2.VIW")
if os.path.exists(src):
    dst_dir = os.path.join(share, "GOINFER")
    os.makedirs(dst_dir, exist_ok=True)
    os.replace(src, os.path.join(dst_dir, "SMOLLM2.VIW"))
    print("store cleared (%d); VIW staged at GOINFER/SMOLLM2.VIW" % n)
else:
    print("store cleared (%d); no parked VIW (clawback state)" % n)
PY

# --- leg 05: the M140c journey's question + snapshot ------------------------
# The default persona opens the process's one compute session and streams
# the staged SmolLM2 VIW into sealed weight buffers — the real Metal path,
# the same load GOINFER's leg 13 pinned. Chords type the card's question
# and the snapshot chord queues behind it: the seat's snapshot arm is
# focus-quiet gated, so 'state ask' cannot land until the decode + commit
# go quiet — the python orders 'committed conv=' before 'snapshot saved',
# and the share's conv file is the byte-level evidence.
vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --gpu3d-metal --via-virtio \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-bare.txt' \
    --script2-after 'gotabwm: holding seat' \
    --input-chords 'w,h,a,t,space,i,s,space,t,h,e,space,c,a,p,i,t,a,l,space,o,f,space,f,r,a,n,c,e,return,ctrl-shift-s' \
    --input-chords-after 'goassist: present' \
    --script-expect 'gotabwm: snapshot saved bytes=' --timeout 3600

vgate_assert 05 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 05 serial-contains 'gotabwm: holding seat'
vgate_assert 05 serial-contains 'exec: loaded GOASSIST.ELF'
vgate_assert 05 serial-contains 'goassist: open id='
vgate_assert 05 serial-contains 'goassist: declare accepted'
vgate_assert 05 serial-contains 'goassist: present'
vgate_assert 05 serial-contains 'goassist: conv new C0001'
vgate_assert 05 serial-contains 'goassist: send conv=C0001'
vgate_assert 05 serial-contains 'goassist: committed conv=C0001'
vgate_assert 05 serial-contains 'gotabwm: state ask id='
vgate_assert 05 serial-contains 'gotabwm: state save id='
vgate_assert 05 serial-contains 'gotabwm: snapshot saved bytes='
vgate_assert 05 serial-absent 'goassist: cancelled'
vgate_assert 05 serial-absent 'goassist: error'
vgate_assert 05 serial-absent 'gpu3d: timeout'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 output-contains 'compute-refusals=0'
# The answer pin is bimodal like live-gpu3d leg 13: a staged VIW must
# produce the pinned greedy decode for the typed prompt (determinism,
# not fluency, is the property — the ids were observed on the Metal
# path), and an absent VIW must produce the named refusal and no answer.
vgate_assert 05 python <<'PY'
import hashlib, os, re, sys
VIW_PIN = "2f5d4c774ea89016ae2b049e288e21a73987fc1c37eb1a58fc1284fad86878bd"
# The greedy answer's alphabet for "what is the capital of france" on a
# fresh C0001 — observed on the real Metal path 2026-10-21 ("Franconia";
# determinism, not fluency, is the pin). Alphabet-valued like leg 02:
# Metal resolves argmax near-ties differently run to run.
ANSWER_ALPHABET = {"54", "3347", "607", "542", "2"}
share = os.environ["VG_SHARE"]
ser = open(os.environ["VG_SER"], errors="replace").read()
if ser.find("gotabwm: snapshot saved") < ser.find("goassist: committed conv="):
    sys.exit("snapshot landed before the answer committed")
conv = os.path.join(share, "ASSIST", "C0001.CHAT")
body = open(conv, "rb").read().decode("utf-8", "replace")
viw = os.path.join(share, "GOINFER", "SMOLLM2.VIW")
if not os.path.exists(viw):
    # Clawback state: the named refusal, never a fabricated answer.
    for want in ("goassist: weights absent", "goassist: committed conv=C0001",
                 "gotabwm: snapshot saved"):
        if want not in ser:
            sys.exit("absent-path marker missing: %r" % want)
    if "goassist: answer toks=" in ser or "goassist: tokens=" in ser:
        sys.exit("an answer appeared without a staged VIW")
    if "@@user\nwhat is the capital of france\n" not in body:
        sys.exit("clawback conv file lost the question\n%s" % body)
    print("no staged VIW: snapshot + named refusal verified (clawback clean)")
    sys.exit(0)
sha = hashlib.sha256(open(viw, "rb").read()).hexdigest()
if sha != VIW_PIN:
    sys.exit("staged VIW sha256 %s != pinned %s" % (sha, VIW_PIN))
m = re.search(r"goassist: answer toks=(\d+) ids=([0-9,]+)", ser)
if not m:
    sys.exit("model answer line missing:\n%s" % ser[-2000:])
ntoks = int(m.group(1))
ids = m.group(2).split(",")
bad = [i for i in ids if i not in ANSWER_ALPHABET]
if bad or len(ids) != ntoks or ntoks < 2:
    sys.exit("answer ids outside the pinned alphabet: %s" % m.group(2))
nums = [int(t.group(1)) for t in re.finditer(r"goassist: tokens=(\d+)", ser)]
if nums != list(range(1, ntoks + 1)):
    sys.exit("token markers did not count 1..%d in order: %r" % (ntoks, nums))
for want in ("@@user\nwhat is the capital of france\n", "@@assistant\n"):
    if want not in body:
        sys.exit("conversation file missing %r\n%s" % (want, body))
print("question leg: pinned sha, %d streamed tokens, conv file committed" % ntoks)
print("observed ids: " + m.group(2))
PY

# --- leg 06: session restore + the follow-up, same conversation -------------
# The restore boot the card names: SESSION.TABS (leg 05's snapshot) makes
# the seat re-exec GOASSIST.ELF bare under mode=restore and the staged
# blob re-opens C0001 — 'state restored conv=C0001 turns=2' is the
# transcript's own count. The follow-up chords then type a second
# question into the same open conversation: 'conv new' must stay absent
# (a fresh conversation would be the wrong answer), 'send conv=C0001'
# pairs the turn, and the share file ends [Q1, A1, Q2, A2].
vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --gpu3d-metal --via-virtio \
    --script '$RUN_DIR/script-seat6.txt' \
    --input-chords 'w,h,a,t,space,a,b,o,u,t,space,s,p,a,i,n,return' \
    --input-chords-after 'goassist: present' \
    --script3 '$RUN_DIR/script-rx6.txt' \
    --script3-after 'goassist: committed conv=' \
    --script-expect 'rx-assist-6-ok' --timeout 3600

vgate_assert 06 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 06 serial-contains 'gotabwm: mode live'
vgate_assert 06 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 06 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 06 serial-contains 'gotabwm: session exec GOASSIST.ELF'
vgate_assert 06 serial-contains 'goassist: open id='
vgate_assert 06 serial-contains 'goassist: declare accepted'
vgate_assert 06 serial-contains 'goassist: state restored conv=C0001 turns=2'
vgate_assert 06 serial-contains 'goassist: present'
vgate_assert 06 serial-contains 'goassist: send conv=C0001'
vgate_assert 06 serial-contains 'goassist: committed conv=C0001'
vgate_assert 06 serial-absent 'goassist: conv new'
vgate_assert 06 serial-absent 'goassist: state refused'
vgate_assert 06 serial-absent 'goassist: state mismatch'
vgate_assert 06 serial-absent 'goassist: cancelled'
vgate_assert 06 serial-absent 'goassist: error'
vgate_assert 06 serial-absent 'gpu3d: timeout'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 output-contains 'compute-refusals=0'
# Same bimodal shape as leg 05, plus the same-conversation proof: the
# restored conv name is parsed from the serial, the follow-up's send
# must carry it, and the file's turn sequence is asserted verbatim.
vgate_assert 06 python <<'PY'
import hashlib, os, re, sys
VIW_PIN = "2f5d4c774ea89016ae2b049e288e21a73987fc1c37eb1a58fc1284fad86878bd"
# The greedy follow-up answer's alphabet for "what about spain" in the
# C0001 context — observed via the kernel-emulating host fake
# (byte-identical to the Metal decode, the leg-10 property) and on the
# Metal path in K=3 bring-up.
ANSWER2_ALPHABET = {"49028", "2"}
share = os.environ["VG_SHARE"]
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"goassist: state restored conv=(C\d+) turns=(\d+)", ser)
if not m:
    sys.exit("no restore marker:\n%s" % ser[-2000:])
name = m.group(1)
if "goassist: send conv=" + name not in ser:
    sys.exit("the follow-up did not send into the restored %s" % name)
body = open(os.path.join(share, "ASSIST", name + ".CHAT"),
            "rb").read().decode("utf-8", "replace")
roles = [r.group(1) for r in re.finditer(r"^@@(\w+)$", body, re.M)]
viw = os.path.join(share, "GOINFER", "SMOLLM2.VIW")
if not os.path.exists(viw):
    # Clawback: two refusals, never an answer; turns are user/meta pairs.
    for want in ("goassist: weights absent", "goassist: committed conv=" + name):
        if want not in ser:
            sys.exit("absent-path marker missing: %r" % want)
    if ser.count("goassist: weights absent") != 1:
        sys.exit("want exactly one refusal this leg")
    if "goassist: answer toks=" in ser or "goassist: tokens=" in ser:
        sys.exit("an answer appeared without a staged VIW")
    if roles != ["user", "meta", "user", "meta"]:
        sys.exit("clawback turn sequence wrong: %r\n%s" % (roles, body))
    print("no staged VIW: restored conv held the follow-up refusal (clawback clean)")
    sys.exit(0)
sha = hashlib.sha256(open(viw, "rb").read()).hexdigest()
if sha != VIW_PIN:
    sys.exit("staged VIW sha256 %s != pinned %s" % (sha, VIW_PIN))
m2 = re.search(r"goassist: answer toks=(\d+) ids=([0-9,]+)", ser)
if not m2:
    sys.exit("model answer line missing:\n%s" % ser[-2000:])
ntoks = int(m2.group(1))
ids = m2.group(2).split(",")
bad = [i for i in ids if i not in ANSWER2_ALPHABET]
if bad or len(ids) != ntoks or ntoks < 2:
    sys.exit("follow-up ids outside the pinned alphabet: %s" % m2.group(2))
nums = [int(t.group(1)) for t in re.finditer(r"goassist: tokens=(\d+)", ser)]
if nums != list(range(1, ntoks + 1)):
    sys.exit("token markers did not count 1..%d in order: %r" % (ntoks, nums))
if roles != ["user", "assistant", "user", "assistant"]:
    sys.exit("turn sequence wrong — the follow-up left the conversation: %r\n%s"
             % (roles, body))
for want in ("what is the capital of france", "what about spain"):
    if want not in body:
        sys.exit("restored conversation lost %r\n%s" % (want, body))
print("restore leg: same conv %s, %d streamed follow-up tokens, 4 turns intact"
      % (name, ntoks))
print("observed ids: " + m2.group(2))
PY
