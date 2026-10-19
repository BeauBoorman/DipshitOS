# live-host-clipboard.spec -- M108b (#2325, ADR 0051) class-B: the
# bidirectional clipboard lane over signed VHI1 share files.
#
# Run 01 is the full journey: the seat adopts the runner's ARMED, a
# marker-timed host pasteboard write lands in the guest clipboard (seat
# applies CLIP_IN through slot 38, the badge flips host-marked, a `clip`
# read proves the bytes), THEN a monitor `clip` write crosses the other
# way (seat emits CLIP_OUT, runner mirrors to the NAMED pasteboard --
# never .general), and two planted records prove the MAC/epoch refusals
# live. The ordering is load-bearing: the guest write rides the seat's
# post-apply diff so `clip-ind host` and `clip-ind local` are BOTH
# observed transitions, not a race — and NO -after/expect marker carries
# payload bytes (the runner echoes its marker flags verbatim, so a marker
# containing the text would self-trip the never-logged check).
#
# Run 02 is the flags-off posture: the same credentialed share shape on a
# clean dir, no --host-clipboard -- byte-silent both directions, no
# HOSTINT/ created.
#
# The credential rides the share's SECRETS.TXT, bound to GOTABWM.ELF (the
# ADR 0024 D8 app binding: uid_system-owned in OWNERS.TXT, 644). The seat
# is exec'd explicitly (wm=none) so the choreography times off its
# markers, and --screen arms the virtio-gpu the seat's WmctlRegister
# requires (headless boots get ENXIO — the go-wm-seat shape).
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh  -> .build/go/GOTABWM.ELF

vgate_name live-host-clipboard "M108b #2325: bidirectional clipboard lane over signed VHI1 share files (ADR 0051)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script-seat.txt <<'EOF'
exec GOTABWM.ELF
EOF

# The read-back AND the guest write ride ONE burst gated on the seat's
# apply marker: `clip` prints the host text (h->g proven), then `clip
# gate-guest-copy-77` stores the local write the next seat diff carries
# out as CLIP_OUT (g->h, with clip-ind flipping host->local).
vgate_file script-clip.txt <<'EOF'
clip
clip gate-guest-copy-77
EOF

# The post-emit read: proves the buffer holds the guest text when the
# CLIP_OUT is in flight (the runner's echo guard must NOT bounce it back).
vgate_file script-read.txt <<'EOF'
clip
EOF

vgate_setup_python <<'PY'
import hashlib, hmac, os, shutil, struct, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.isfile(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
# wm=none: the seat is exec'd on script, like go-agentd.spec.
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
# The lane credential: the row the seat reads via sys_secret_get (image
# binding needs the uid_system OWNERS row) and the runner reads as a host
# file. Value bytes ARE the HMAC key verbatim.
KEY = "clipkey0" * 8  # 64 bytes, ASCII
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# Two planted lane records exercise the refusals live: (a) a correctly
# signed CLIP_IN under a foreign epoch -> stale_epoch; (b) a forged
# CLIP_IN under a wrong key -> bad_mac. Both must be deleted, never
# applied.
def rec(tag, flags, seq, epoch, payload, key):
    hdr = b"VHI1" + bytes([tag, flags, 0, 0]) + struct.pack(
        "<IIH", seq, epoch, len(payload))
    body = hdr + payload
    return body + hmac.new(key.encode(), body, hashlib.sha256).digest()
os.makedirs(os.path.join(share, "HOSTINT"), exist_ok=True)
open(os.path.join(share, "HOSTINT", "CLIPIN-00000077"), "wb").write(
    rec(2, 0, 0x77, 999, b"stale-epoch-plant", KEY))
open(os.path.join(share, "HOSTINT", "CLIPIN-00000088"), "wb").write(
    rec(2, 0, 0x88, 1, b"forged-plant", "wrongkey" * 8))
open(os.path.join(run, "key-sentinel.txt"), "w").write(KEY + "\n")
# Run 02's flags-off posture needs a share the lane flag never touched:
# the runner owns HOSTINT/ creation, so a boot on THIS directory with no
# flag proves byte-silence while still holding the same credential, seat
# binary and wm=none posture the armed run uses. The main share cannot
# prove it — the refusal plants above live in its HOSTINT/ already.
# (go-agentd.spec runs 07/08 are the same alternate-share pattern.)
off = os.path.join(run, "off-share")
os.makedirs(off, exist_ok=True)
shutil.copy(src, os.path.join(off, "GOTABWM.ELF"))
open(os.path.join(off, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
open(os.path.join(off, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(off, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# M124c (#2582): the typed legs' fixtures. Two tiny PNGs — one for the
# h->g inject, a DIFFERENT one for the GOVIEW copy (an identical blob
# would hash-match the applied buffer and the seat's diff would never
# fire). CLIPDIR holds one file so GOFILES' first-entry selection is
# deterministic. GOVIEW/GOEDIT/GOFILES are exec'd -u0: the seat's own
# launches are uid_user and slots 38/39 refuse them (M97g) — the same
# capable path go-edit run 06 takes.
import struct, zlib
def tiny_png(rgb):
    w = h = 4
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(
            ">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))
for elf in ("GOVIEW.ELF", "GOEDIT.ELF", "GOFILES.ELF"):
    src2 = os.path.join(".build", "go", elf)
    if not os.path.isfile(src2):
        sys.exit(elf + " missing - build it first: "
                 "GO_BUILD_NAME=" + elf.split('.')[0] +
                 " bash tools/go/build-go.sh user/go/<dir>/main.go")
    shutil.copy(src2, os.path.join(share, elf))
open(os.path.join(run, "tiny-a.png"), "wb").write(tiny_png((255, 0, 0)))
open(os.path.join(share, "TINY.PNG"), "wb").write(tiny_png((0, 0, 255)))
os.makedirs(os.path.join(share, "CLIPDIR"), exist_ok=True)
open(os.path.join(share, "CLIPDIR", "KNOWN.TXT"), "w").write("known\n")
print("staged hostint share (GOTABWM + host-int credential + 2 refusal plants)"
      " + flags-off share + M124c typed fixtures")
PY

# ---- 01: both directions + refusal proofs, one boot -----------------------------
# --screen arms the virtio-gpu: without it WmctlRegister answers ENXIO and
# the seat dies before the lane exists (every gotabwm spec boots this way).
# The chain is strictly marker-ordered: inject on the armed marker; one
# burst after `clip-in seq=1` reads the applied host text THEN stores the
# guest write; a last read after `clip-out seq=1` ends the run on the
# guest text — the 6 s tail covers the runner's 250 ms drain to the named
# pasteboard.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-clip.txt' --script2-after 'gotabwm: hostint clip-in seq=1' \
    --script3 '$RUN_DIR/script-read.txt' --script3-after 'gotabwm: hostint clip-out seq=1' \
    --host-clipboard --host-pasteboard 'virelai-gate-clip' \
    --host-clip-in 'gate-host-copy-88' --host-clip-in-after 'gotabwm: hostint armed' \
    --script-expect 'clip: gate-guest-copy-77' --script-expect-tail 6 --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
# The lane armed: seat adopted the runner's epoch and lane mask.
vgate_assert 01 output-contains 'host-int: armed lanes=clip epoch='
vgate_assert 01 serial-contains 'gotabwm: hostint armed epoch='
vgate_assert 01 serial-contains 'lanes=clip'
# The planted refusals: foreign-epoch signed record and the forgery.
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=clip reason=stale_epoch'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=clip reason=bad_mac'
vgate_assert 01 serial-absent 'stale-epoch-plant'
vgate_assert 01 serial-absent 'forged-plant'
# h->g: the inject fired on the armed marker, the seat applied CLIP_IN
# through slot 38, and the badge flipped host-marked. `clip` reads it back.
# The sha256[:8] digests are pinned — the payload is a fixed string, so the
# digest IS the content proof (the text itself is asserted on serial only,
# where the guest's own read-back legitimately prints it).
vgate_assert 01 output-contains 'host-clip: inject len=17'
vgate_assert 01 output-contains 'host-clip: in seq=1 sha256=107ea696 len=17 truncated=0'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-in seq=1 len=17 sha=107ea696 truncated=0'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-ind host'
vgate_assert 01 serial-contains 'clip: gate-host-copy-88'
# g->h: the monitor `clip` write was observed on the seat's slot-39 poll,
# emitted as CLIP_OUT, and mirrored to the named pasteboard; the post-emit
# read shows the buffer holding the guest text (no echo bounce).
vgate_assert 01 serial-contains 'clip: stored 18 bytes'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-out seq=1 len=18 sha=09a691a7'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-ind local'
vgate_assert 01 output-contains 'host-clip: out seq=1 sha256=09a691a7 len=18'
vgate_assert 01 serial-contains 'clip: gate-guest-copy-77'
vgate_assert 01 serial-absent '[EXC] parking:'
# The credential never reaches serial or runner stdout.
vgate_assert 01 serial-absent 'clipkey0clipkey0'
vgate_assert 01 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
key = open(os.path.join(run, "key-sentinel.txt")).read().strip()
if key in out:
    sys.exit("FAIL: the lane key reached runner stdout")
if "gate-host-copy-88" in out.split("host-clip: inject")[0] if "host-clip: inject" in out else False:
    sys.exit("FAIL: payload text reached stdout before the inject line")
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
names = sorted(os.listdir(os.path.join(share, "HOSTINT")))
left = [n for n in names if not n.endswith("~")]
if left:
    sys.exit("FAIL: unconsumed lane files left in HOSTINT: %r" % left)
print("run-01 lane hygiene ok")
PY

# ---- 02: flags-off is byte-silent ------------------------------------------------
# Same credential+seat posture on a CLEAN share (setup seeds off-share
# with GOTABWM.ELF + wm=none + the host-int row), no lane flag: the
# runner never creates HOSTINT/, never writes a record, never reads a
# pasteboard; the seat's once-per-tick listing sees a directory that
# never exists -- one cheap ENOENT per tick, zero lane markers either
# end. The seat still registers and reports live (the lane is not a seat
# precondition), so --screen arms the gpu exactly as run 01.
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
for needle in ("host-int:", "host-clip:"):
    if needle in out:
        sys.exit("FAIL: flags-off run printed lane traffic: " + needle)
share = os.path.join(run, "off-share")
if os.path.isdir(os.path.join(share, "HOSTINT")):
    sys.exit("FAIL: flags-off run created HOSTINT/")
print("run-02 flags-off silence ok")
PY

# ---- 03: typed h->g + g->h image/png, GOVIEW copy -> GOEDIT paste (M124c) ----
# The seat leg's image half: a host PNG inject crosses as CLIP_IN_T (seat
# applies the blob, badges CLIP:IMG:H); then GOVIEW (-u0: the seat's own
# launches are uid_user and slot 38 refuses them) copies ITS PNG the other
# way on CLIP_OUT_T, and a -u0 GOEDIT pastes the PNG bytes verbatim —
# "paste as PNG". The two fixture PNGs differ deliberately: an identical
# blob would hash-match the applied buffer and the seat's diff never
# fires.
vgate_file script-goview.txt <<'EOF'
exec -u0 GOVIEW.ELF /host/TINY.PNG
EOF

vgate_file script-goedit.txt <<'EOF'
exec -u0 GOEDIT.ELF
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-goview.txt' --script2-after 'gotabwm: hostint clip-in-t seq=1' \
    --script3 '$RUN_DIR/script-goedit.txt' --script3-after 'gotabwm: hostint clip-out-t seq=1' \
    --host-clipboard --host-pasteboard 'virelai-gate-clip-t' \
    --host-clip-in-file '$RUN_DIR/tiny-a.png' --host-clip-in-mime 'image/png' \
    --host-clip-in-after 'gotabwm: hostint armed' \
    --input-string 'c' --input-string-after 'gview: ready' \
    --input-chords 'ctrl-v' --input-chords-after 'goedit: present' \
    --script-expect 'goedit: paste n=73' --script-expect-tail 6 --timeout 240

vgate_assert 03 serial-contains 'gotabwm: hostint armed epoch='
# h->g typed: the inject lands CLIP_IN_T seq=1 (73-byte blob inside an
# 83-byte envelope); the seat applies it and marks the badge host-sourced.
vgate_assert 03 output-contains 'host-clip: inject mime=image/png'
vgate_assert 03 output-contains 'host-clip: in seq=1 mime=image/png sha256=55f6adb9 len=83 truncated=0'
vgate_assert 03 serial-contains 'gotabwm: hostint clip-in-t seq=1 mime=image/png len=73 sha=3fd6e6be truncated=0'
vgate_assert 03 serial-contains 'gotabwm: hostint clip-ind host'
# g->h typed: 'c' in GOVIEW copies its PNG — the mime is read off the
# file's magic — the seat emits CLIP_OUT_T, the runner mirrors the bytes.
vgate_assert 03 serial-contains 'gview: copy mime=image/png n=73'
vgate_assert 03 serial-contains 'gotabwm: hostint clip-out-t seq=1 mime=image/png len=73 sha=70ca7dc8'
vgate_assert 03 serial-contains 'gotabwm: hostint clip-ind local'
vgate_assert 03 output-contains 'host-clip: out seq=1 mime=image/png'
# GOEDIT pastes the 73 PNG bytes — "copy image -> paste as PNG".
vgate_assert 03 serial-contains 'goedit: paste n=73'
vgate_assert 03 serial-absent '[EXC] parking:'

# ---- 04: GOFILES copy -> uri-list -> GOEDIT pastes the path (M124c) ----
# The seat leg's file half: 'c' in GOFILES publishes the entry's file://
# URI as text/uri-list on the machine clipboard (its own in-app clip is
# unchanged), the seat carries it as CLIP_OUT_T, the runner mirrors file
# URLs, and GOEDIT's paste lands the URI — "copy file -> paste path".
vgate_file script-gofiles.txt <<'EOF'
exec -u0 GOFILES.ELF /host/CLIPDIR
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-gofiles.txt' --script2-after 'gotabwm: hostint armed' \
    --script3 '$RUN_DIR/script-goedit.txt' --script3-after 'gotabwm: hostint clip-out-t seq=1' \
    --host-clipboard --host-pasteboard 'virelai-gate-clip-t4' \
    --input-string 'c' --input-string-after 'gofiles: ready' \
    --input-chords 'ctrl-v' --input-chords-after 'goedit: present' \
    --script-expect 'goedit: paste n=30' --script-expect-tail 6 --timeout 240

vgate_assert 04 serial-contains 'gotabwm: hostint armed epoch='
vgate_assert 04 serial-contains 'gofiles: clip copy KNOWN.TXT'
vgate_assert 04 serial-contains 'gofiles: clip-sys n=30'
vgate_assert 04 serial-contains 'gotabwm: hostint clip-out-t seq=1 mime=text/uri-list len=30 sha=c5313fce'
vgate_assert 04 output-contains 'host-clip: out seq=1 mime=text/uri-list'
vgate_assert 04 serial-contains 'goedit: paste n=30'
vgate_assert 04 serial-absent '[EXC] parking:'
