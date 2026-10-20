# go-assist.spec -- M140b (#2785) class-B acceptance: GOASSIST.ELF, the
# chat client over virelai/infer, under GOTABWM on the real VIR1/Metal
# compute path. Four independent boots, one leg each, the same
# wm=none + scripted-seat shape live-gpu3d uses:
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
#
# Legs 02/03 use the `stub` persona (SynthStub) so the stream is
# deterministic without staged weights; leg 04 covers the absent-weight
# path of the default persona. The real-model stream rides the same
# engine path live-gpu3d's leg 13 already stages.
#
# exec-order: assert-proven -- each run's expect marker is printed by the
# script AFTER the guest markers its stage gates wait on; a leg whose
# app never ran cannot pass.
# HOST PREREQUISITE (fails honestly):
#   bash tools/go/build-gotabwm.sh tools/go/build-goassist.sh

vgate_name go-assist "M140b #2785: GOASSIST.ELF under GOTABWM — seat GPU-compute probe, streamed stub answer with increasing token markers + conversation file, mid-conversation kill -> crash-restart restore, weights-absent named refusal"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-seat.txt <<'EOF'
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
vgate_assert 02 serial-contains 'goassist: answer toks=64 ids=71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,79,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209,209'
vgate_assert 02 serial-contains 'goassist: saved C0001.CHAT'
vgate_assert 02 serial-contains 'goassist: committed conv=C0001'
vgate_assert 02 serial-absent 'goassist: cancelled'
vgate_assert 02 serial-absent 'goassist: error'
vgate_assert 02 serial-absent 'gpu3d: timeout'
vgate_assert 02 serial-absent '[EXC] parking:'
# The token markers must count 1..64 in order — "increase over time" is a
# property of the sequence, not of two spot checks.
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
nums = [int(m.group(1)) for m in re.finditer(r"goassist: tokens=(\d+)", ser)]
if nums != list(range(1, len(nums) + 1)) or len(nums) != 64:
    sys.exit("token markers did not count 1..64 in order: %r" % nums)
print("64 token markers, strictly increasing")
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
# The turn count is not pinned: the spec-scoped share persists across
# legs, so the restored conversation carries leg 02's turns plus this
# leg's. ` turns=` presence + the file check below are the evidence.
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
