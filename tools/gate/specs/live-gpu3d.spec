# live-gpu3d.spec -- M102f2 (issue #2171) class-B acceptance: a guest Go app
# (GPUTRIANGLE.ELF) drives the opt-in VIR1 render device over the real seat
# -> broker -> Metal path; the private profile's raw BGRA readback export and
# the VZ scanout are pixel-proven by f1's independent comparator/geometry.
# Fifteen independent boots, one leg each: 01 triangle, 02 mixed margins,
# 03 resize/second generation, 04 close/reuse, 05 native-only (no render
# device), 06 malformed/auth (invalid battery + forged kind-17), 07
# wrong/stale fence, 08 stall/timeout + next-open drain, 09 M111b GPU
# compute (slot-90 GEMM submit->fence->readback + named refusal), 10 M111c
# GOINFER stub-model inference K=5, 11 GOINFER on a device-less boot, 12
# GOINFER weights-absent honesty, 13 GOINFER owner-approved model
# (SmolLM2-135M-Instruct, Apache-2.0) K=5 decode when a VIW is staged, 14
# GOINFER hostile .VIW named refusal (swapped-shape embed), 15 the virgl
# coverage matrix (#3176 — every attach prints the observed verdict per
# probe; the leg asserts the pinned refusal names).
# `wm=none`
# is seeded so the seat is the spec's own scripted exec; every leg ends on
# a marker only its script can print. Leg 05 RUNS FIRST: the seed share is
# spec-scoped, so its no-receipt assert is only honest before any 3D leg
# has written GPUTRI/ files to it.
# exec-order: assert-proven -- each run's expect marker is printed by the
# script AFTER the guest markers its stage gates wait on; a leg whose
# device/app never ran cannot pass. HOST PREREQUISITE (fails honestly):
#   bash tools/go/build-gotabwm.sh tools/go/build-gputriangle.sh

vgate_name live-gpu3d "M102f2 #2171: guest triangle through real VIR1/Metal into the native 2D seat, 15 legs, raw-BGRA readback + scanout pixels + fence/timeout lifecycle + M111b #2409 slot-90 compute round trip + M111c #2410 GOINFER stub-model + owner-approved SmolLM2 inference + hostile .VIW named refusal + virgl coverage matrix #3176"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-seat.txt <<'EOF'
set GOMAXPROCS=1
exec GOTABWM.ELF
EOF

vgate_file script-tri.txt <<'EOF'
exec GPUTRIANGLE.ELF triangle
EOF

vgate_file script-mixed.txt <<'EOF'
exec GPUTRIANGLE.ELF mixed
EOF

vgate_file script-resize.txt <<'EOF'
exec GPUTRIANGLE.ELF resize
EOF

vgate_file script-closereuse.txt <<'EOF'
exec GPUTRIANGLE.ELF closereuse
EOF

vgate_file script-invalid.txt <<'EOF'
exec GPUTRIANGLE.ELF invalid
EOF

vgate_file script-forged.txt <<'EOF'
exec GPUTRIANGLE.ELF forged
EOF

vgate_file script-gemm.txt <<'EOF'
exec GPUTRIANGLE.ELF gemm
EOF

vgate_file script-gemmrefuse.txt <<'EOF'
exec GPUTRIANGLE.ELF gemmrefuse
EOF

vgate_file script-goinfer-stub.txt <<'EOF'
exec GOINFER.ELF stub
EOF

vgate_file script-goinfer-model.txt <<'EOF'
exec GOINFER.ELF model
EOF

vgate_file script-goinfer-hostile.txt <<'EOF'
exec GOINFER.ELF model /host/HOSTILE.VIW
EOF

vgate_file script-rx.txt <<'EOF'
echo rx-g3-ok
EOF

vgate_file script-rx-invalid.txt <<'EOF'
echo rx-g3-invalid-ok
EOF

# GOTABWM.ELF, GPUTRIANGLE.ELF and GOINFER.ELF are .build products, not
# zig-out: stage all three plus the wm=none seat opt-in (go-wm-seat's own
# pattern) so each leg boots exactly one seat and each app's build stamp is
# honoured.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name in ("GOTABWM.ELF", "GPUTRIANGLE.ELF", "GOINFER.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: "
                 "bash tools/go/build-%s.sh"
                 % (name, src, name[:-4].lower()))
    shutil.copy(src, os.path.join(share, name))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("staged Go seat + GPUTRIANGLE.ELF + GOINFER.ELF, wm=none")

# The model VIW (M111c #2410, owner-approved SmolLM2-135M-Instruct): staged
# ONLY when the operator produced it (tools/goinfer/convert-smollm2.py ->
# artifacts/goinfer/SMOLLM2.VIW) — the clawback keeps the file optional.
# A present file's sha256 must equal the pin recorded at staging time — a
# wrong staged file is a hard failure, never a silently different model.
# The bytes park in RUN_DIR, NOT the share: leg 12's weights-absent boot
# must still find GOINFER/SMOLLM2.VIW missing; the leg-12 post hook moves
# it onto the app's default path only for the model leg that follows.
import hashlib
VIW_PIN = "2f5d4c774ea89016ae2b049e288e21a73987fc1c37eb1a58fc1284fad86878bd"
viw = os.path.join("artifacts", "goinfer", "SMOLLM2.VIW")
if os.path.exists(viw):
    sha = hashlib.sha256(open(viw, "rb").read()).hexdigest()
    if sha != VIW_PIN:
        sys.exit("staged VIW sha256 %s != pinned %s" % (sha, VIW_PIN))
    shutil.copy(viw, os.path.join(rd, "SMOLLM2.VIW"))
    print("model VIW verified against pin, parked until leg 12 runs")
else:
    print("no staged VIW: leg 13 asserts the weights-absent path")
PY

# --- leg 05 (run first): native-only --------------------------------------
# No --gpu3d-metal: the device is absent, the app reports unsupported, the
# ordinary 2D seat and scanout keep working, and NO 3D receipt lands. It
# runs ahead of the 3D legs because their receipt files persist on the
# spec-scoped seed share — asserting "no GPUTRI dir" after them could never
# pass. Tag 05 keeps the report's logical numbering.
vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-tri.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'gputri: unsupported' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 05 serial-absent 'gpu3d: armed'
vgate_assert 05 serial-contains 'gpu: setup ok scanout='
vgate_assert 05 serial-contains 'gotabwm: holding seat'
vgate_assert 05 serial-contains 'gputri: declare accepted'
vgate_assert 05 serial-contains 'gputri: unsupported'
vgate_assert 05 serial-absent 'gputri: published'
vgate_assert 05 serial-count 'gotabwm: present' 1
vgate_assert 05 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
p = os.path.join(share, "GPUTRI")
if os.path.exists(p):
    sys.exit("GPUTRI receipt dir exists on a native-only boot: %r" %
             os.listdir(p))
print("no 3D receipts on native-only boot")
PY

# --- leg 01: triangle ----------------------------------------------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --screenshot-after 'gotabwm: gpu3d presented' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-tri.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'gputri OK' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 01 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 01 serial-contains 'gotabwm: holding seat'
vgate_assert 01 serial-contains 'gputri: declare accepted'
vgate_assert 01 serial-contains 'gotabwm: gpu3d open id=3 64x48'
vgate_assert 01 serial-contains 'gputri: gpu open 64x48 gen=1.1'
vgate_assert 01 serial-contains 'gputri: clear'
vgate_assert 01 serial-contains 'gputri: triangle'
vgate_assert 01 serial-contains 'gputri: present'
vgate_assert 01 serial-contains 'gputri: completed frame=1'
vgate_assert 01 serial-contains 'gotabwm: gpu3d presented id=3 frame=1'
vgate_assert 01 serial-contains 'gputri: published frame=1 EXPO_1_1.BGRA'
vgate_assert 01 serial-contains 'gputri OK'
vgate_assert 01 serial-absent 'gpu3d: timeout'
vgate_assert 01 serial-absent 'gpu3d: badresp'
vgate_assert 01 serial-absent '[EXC] parking:'
# The receipt correlates guest submissions with the host device: fence
# numbers, generations and the export name all pinned by the app itself.
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
body = open(os.path.join(share, "GPUTRI", "RECEIPT.TSV")).read()
for row in ("ctx\t1\t1\t64x48", "submitted\t1\t1\ttriangle",
            "completed\t1\t1\t1", "published\t1\t1\t1\tEXPO_1_1.BGRA"):
    if row not in body:
        sys.exit("receipt missing %r\n%s" % (row, body))
print("receipt rows verified")
PY
# The pixel oracle: the raw BGRA readback export must rasterize the fixture's
# scene exactly (interior colour, outside clear, guards, opaque alpha).
vgate_assert 01 python <<'PY'
import os, subprocess, sys
share = os.environ["VG_SHARE"]
img = os.path.join(share, "GPUTRI", "EXPO_1_1.BGRA")
r = subprocess.run(["python3", "tools/gpu3d-proof/compare.py", img, "triangle"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("compare failed:\n" + r.stdout + r.stderr)
print(r.stdout.strip())
PY
# Host counters: a real Metal draw completed, real guest-mem DMA, zero faults.
vgate_assert 01 output-contains 'draws=1 gpu-completions=1'
vgate_assert 01 output-contains 'submit-rejections=0'
vgate_assert 01 output-contains 'refusals=0'
# The final scanout contains the triangle's red interior AND the non-red
# clear field — one capture, fired on the seat's `gpu3d presented` marker
# (the composite lands there; `gputri: win-present` precedes it and raced
# the capture under concurrent VM load). The
# PNG is a ScreenCaptureKit capture of the composited macOS window, so the
# framebuffer's exact values arrive colour-managed: on this host fb
# 255,0,0 reads as (234,51,35) and fb 16,32,48 as (20,32,47) — stable
# across runs. The check pins those observed anchors with a small
# tolerance; the pixel-EXACT proof stays on the raw EXPO comparator.
vgate_assert 01 snapshot 'screen-01-after' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
if d[:8] != b'\x89PNG\r\n\x1a\n':
    sys.exit("not a PNG")
pos = 8; idat = b''; w = h = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR': w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT': idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp + 1
red = clear = 0
prev = bytearray(stride - 1)
for y in range(h):
    row = raw[y*stride:(y+1)*stride]
    f = row[0]; px = bytearray(row[1:])
    for i in range(len(px)):
        a = px[i-bpp] if i >= bpp else 0
        b = prev[i]
        c = prev[i-bpp] if i >= bpp else 0
        if f == 1: px[i] = (px[i] + a) & 255
        elif f == 2: px[i] = (px[i] + b) & 255
        elif f == 3: px[i] = (px[i] + ((a + b) >> 1)) & 255
        elif f == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            px[i] = (px[i] + pr) & 255
    prev = px
    for x in range(w):
        p = px[x*bpp:x*bpp+3]
        if 218 <= p[0] <= 246 and 38 <= p[1] <= 64 and 22 <= p[2] <= 48: red += 1
        if 16 <= p[0] <= 24 and 28 <= p[1] <= 36 and 42 <= p[2] <= 52: clear += 1
if red < 200:
    sys.exit("scanout has only %d interior red pixels (want >=200)" % red)
if clear < 200:
    sys.exit("scanout has only %d clear pixels (want >=200)" % clear)
print("scanout: %d red + %d clear pixels" % (red, clear))
PY

# Every leg passes --screen: without a VZ graphics device the kernel
# compositor never arms and the seat's wmctl register fails ENXIO — the
# flag is how the seat exists at all, not only how leg 01's PNG lands.

# --- leg 02: mixed margins ------------------------------------------------
# The same 64x48 render exported into the larger 96x72 surface; the margin
# pixels around it are the app's own 2D fill, proven by the mixed scene's
# guard rects (every pixel outside the render rect is the margin colour).
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-mixed.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'gputri OK' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 02 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 02 serial-contains 'gputri: gpu open 64x48 gen=1.1'
vgate_assert 02 serial-contains 'gputri: published frame=1 EXPO_1_1.BGRA'
vgate_assert 02 serial-contains 'gputri OK'
vgate_assert 02 serial-absent 'gpu3d: timeout'
vgate_assert 02 output-contains 'draws=1 gpu-completions=1'
vgate_assert 02 output-contains 'refusals=0'
vgate_assert 02 python <<'PY'
import os, subprocess, sys
share = os.environ["VG_SHARE"]
img = os.path.join(share, "GPUTRI", "EXPO_1_1.BGRA")
r = subprocess.run(["python3", "tools/gpu3d-proof/compare.py", img, "mixed"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("compare failed:\n" + r.stdout + r.stderr)
print(r.stdout.strip())
PY

# --- leg 03: resize / second generation ----------------------------------
# One window, two contexts: EXPO_1_1 at 64x48 (triangle scene) then
# EXPO_1_2 at 96x64 (resized scene) — rgen 2 proves the new generation is
# not the old frame republished.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-resize.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'gputri OK' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 03 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 03 serial-contains 'gputri: gpu open 64x48 gen=1.1'
vgate_assert 03 serial-contains 'gputri: gpu open 96x64 gen=1.2'
vgate_assert 03 serial-contains 'gputri: published frame=1 EXPO_1_2.BGRA'
vgate_assert 03 serial-contains 'gputri OK'
vgate_assert 03 output-contains 'draws=2 gpu-completions=2'
vgate_assert 03 output-contains 'refusals=0'
vgate_assert 03 python <<'PY'
import os, subprocess, sys
share = os.environ["VG_SHARE"]
for img, scene in (("EXPO_1_1.BGRA", "triangle"),
                   ("EXPO_1_2.BGRA", "resized")):
    path = os.path.join(share, "GPUTRI", img)
    r = subprocess.run(["python3", "tools/gpu3d-proof/compare.py", path, scene],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("%s vs %s failed:\n%s%s" % (img, scene, r.stdout, r.stderr))
print("both extent exports verified")
PY

# --- leg 04: close/reuse --------------------------------------------------
# Two full window lifetimes: wgen 1 publishes, closes, then wgen 2 renders
# fresh pixels — the second export cannot contain the old frame.
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-closereuse.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'gputri OK' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 04 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 04 serial-contains 'gputri: gpu open 64x48 gen=1.1'
vgate_assert 04 serial-contains 'gotabwm: gpu3d close id='
vgate_assert 04 serial-contains 'gputri: gpu open 64x48 gen=2.2'
vgate_assert 04 serial-contains 'gputri: published frame=1 EXPO_2_2.BGRA'
vgate_assert 04 serial-contains 'gputri OK'
vgate_assert 04 serial-absent 'gpu3d: timeout'
vgate_assert 04 output-contains 'draws=2 gpu-completions=2'
vgate_assert 04 output-contains 'refusals=0'
vgate_assert 04 output-contains 'retired-pending=0'
vgate_assert 04 python <<'PY'
import os, subprocess, sys
share = os.environ["VG_SHARE"]
img = os.path.join(share, "GPUTRI", "EXPO_2_2.BGRA")
r = subprocess.run(["python3", "tools/gpu3d-proof/compare.py", img, "triangle"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("compare failed:\n" + r.stdout + r.stderr)
print(r.stdout.strip())
PY

# --- leg 06: malformed + forged -------------------------------------------
# One boot, two journeys. `invalid`: every bad call is a NAMED refusal and
# the journey still completes. `forged`: a real publish, then a forged
# kind-17 frame for its own bound surface with an invalid token — the seat
# refuses it at the rpc seam and the device sees ZERO submissions for it.
vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-invalid.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-forged.txt' \
    --script3-after 'gputri OK' \
    --script-expect 'gputri: session intact' --timeout 180

vgate_assert 06 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 06 serial-count 'gputri: refuse open invalid' 3
vgate_assert 06 serial-contains 'gputri: refuse clear-wide invalid'
vgate_assert 06 serial-contains 'gputri: refuse closed-present closed'
vgate_assert 06 serial-contains 'gputri: forged sent'
vgate_assert 06 serial-contains 'gotabwm: rpc refuse id='
vgate_assert 06 serial-contains 'gputri: session intact'
vgate_assert 06 serial-contains 'gputri OK'
# Exactly two real frames reached the device; the forged frame submitted
# nothing (no draw, no rejection, no orphan).
vgate_assert 06 output-contains 'draws=2 gpu-completions=2'
vgate_assert 06 output-contains 'submit-rejections=0'
vgate_assert 06 output-contains 'refusals=0'

# --- leg 07: wrong/stale fence --------------------------------------------
# The host returns the submit's completion under the WRONG fence: the guest
# never completes the exchange, the frame is never published, the stale
# fence is pinned host-side and the seat's 2D keeps presenting.
vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --gpu3d-metal --gpu3d-test-mode wrong-fence \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-tri.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'gputri: error' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 07 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 07 serial-contains 'gputri: gpu open 64x48 gen=1.1'
vgate_assert 07 serial-contains 'gpu3d: timeout req=0x207'
vgate_assert 07 serial-contains 'gputri: refuse present timeout'
vgate_assert 07 serial-absent 'gputri: published'
vgate_assert 07 serial-contains 'gputri: error timeout'
vgate_assert 07 serial-count 'gotabwm: present' 1
vgate_assert 07 serial-count 'gotabwm: tick' 5
vgate_assert 07 output-contains 'stale-fences=1'
vgate_assert 07 output-contains 'retired-pending=1'
vgate_assert 07 output-contains 'submit-rejections=0'

# --- leg 08: stall / retirement -------------------------------------------
# Fence completion is suppressed: the submit's 2 s deadline fires, the frame
# is refused and the session is quarantined (retired-pending). The next
# exec proves the drain/open cycle still works end to end — the invalid
# journey's full open + named refusals — while the parked chain is never
# recycled into the new context.
vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --gpu3d-metal --gpu3d-test-mode stall \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-tri.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-invalid.txt' \
    --script3-after 'gputri: error timeout' \
    --script-expect 'gputri OK' --timeout 180

vgate_assert 08 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 08 serial-contains 'gpu3d: timeout req=0x207'
vgate_assert 08 serial-contains 'gputri: refuse present timeout'
vgate_assert 08 serial-contains 'gputri: error timeout'
vgate_assert 08 serial-count 'gotabwm: gpu3d open id=' 2
vgate_assert 08 serial-contains 'gputri OK'
vgate_assert 08 serial-absent 'gputri: published'
vgate_assert 08 output-contains 'retired-pending=1'
vgate_assert 08 output-contains 'stale-fences=0'

# --- leg 09: GPU compute round trip + refusal (M111b, issue #2409) -------
# The same physical device, the second capset: GPUTRIANGLE's `gemm`
# journey opens a sys_gpucomp session (slot 90), stages A=[[1,2],[3,4]]
# and B=[[5,6],[7,8]] into target-buffer resources, submits the pinned
# 2x2 f16 GEMM — the RUN call IS the bounded fence wait — and reads C
# back through the pool. [[19,22],[43,50]] on the console is the observed
# product of a REAL Metal compute pipeline, not a guest-side answer.
# `gemmrefuse` then runs a descriptor with kernel id 9 — outside the
# curated mask — and must see the named EINVAL refusal while the session
# stays live enough to answer STATS (a refusal is not a poison).
vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-gemm.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-gemmrefuse.txt' \
    --script3-after 'gputri OK' \
    --script-expect 'gputri: stats refusals=1' --timeout 180

vgate_assert 09 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 09 serial-contains 'gputri: gemm c=19,22,43,50 submits='
vgate_assert 09 serial-contains 'gputri: refused invalid'
vgate_assert 09 serial-contains 'gputri: stats refusals=1'
vgate_assert 09 serial-absent 'gpu3d: timeout'
vgate_assert 09 serial-absent 'gpu3d: badresp'
vgate_assert 09 serial-absent '[EXC] parking:'
# The runner advertised the second capset and a REAL compute pipeline —
# compute=1 is the honest-ready bit, not a capability claim.
vgate_assert 09 output-contains 'VIC1 capset 0x56494331'
vgate_assert 09 output-contains 'compute=1'
# One compute submit reached Metal; the kernel-id refusal happened
# guest-side and never touched the device — zero renders, zero refusals.
vgate_assert 09 output-contains 'compute-submits=1 compute-refusals=0'
vgate_assert 09 output-contains 'draws=0'
vgate_assert 09 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
gemm = open(os.path.join(share, "GPUTRI", "RECEIPT-GEMM.TSV")).read()
refuse = open(os.path.join(share, "GPUTRI", "RECEIPT-REFUSE.TSV")).read()
for row in ("compute\talloc", "compute\tuploaded", "compute\tfence-ok",
            "compute\tpublished\tc=19,22,43,50\tsubmits=1\tcompleted=1"):
    if row not in gemm:
        sys.exit("gemm receipt missing %r\n%s" % (row, gemm))
for row in ("compute\trefused\tinvalid", "compute\tstats\trefusals=1"):
    if row not in refuse:
        sys.exit("refuse receipt missing %r\n%s" % (row, refuse))
print("compute receipt rows verified")

# Leg 14's crafted image: a well-formed container — valid prefix, header,
# tokenizer blob, directory — whose embed tensor declares dims
# [dim, vocab] where the arch wants [vocab, dim]. payload_len still agrees
# with the DECLARED dims, so the container parser accepts it and the
# refusal must come from the shape check: a named error, never a panic.
# It parks at the share ROOT — inside GOINFER/ it would break leg 11's
# no-receipt-dir assert on the device-less boot.
import struct
h_hdr = ("\n".join([
    "arch llama", "dim 64", "hidden 128", "layers 1", "heads 4",
    "kv_heads 4", "vocab 32", "seq_cap 16", "rope half",
    "rope_theta 10000", "rms_eps 1e-05", "tie 1", "bos 1", "eos 2",
]) + "\n").encode()
h_tok = struct.pack("<III", 1, 1, 2)  # kind=bytes, bos, eos
h_n = 64 * 32                        # swapped-dims embed's own element count
h_paylen = (h_n + 1) // 2 + ((h_n + 31) // 32) * 8  # u4asym group 32
h_ent = bytearray(96)
h_ent[0:5] = b"embed"
h_ent[32] = 2   # fmt u4asym
h_ent[33] = 2   # nd
h_ent[34] = 32  # group
struct.pack_into("<II", h_ent, 36, 64, 32)  # dims — the lie
struct.pack_into("<Q", h_ent, 56, 64 + len(h_hdr) + len(h_tok) + 96)
struct.pack_into("<Q", h_ent, 64, h_paylen)
h_img = (struct.pack("<IIIII", 0x31574956, len(h_hdr), len(h_tok), 1, 0)
         + bytes(44) + h_hdr + h_tok + bytes(h_ent) + bytes(h_paylen))
open(os.path.join(share, "HOSTILE.VIW"), "wb").write(h_img)
print("staged HOSTILE.VIW (%d bytes, embed dims swapped)" % len(h_img))
PY

# --- leg 11: GOINFER on a device-less boot (M111c, issue #2410) -----------
# Runs ahead of leg 10 in file order: its no-receipt assert is only honest
# before any goinfer leg has written GOINFER/ files to the spec-scoped
# share — the same reason leg 05 sits first among the render legs.
vgate_run 11 -- \
    --screen '$RUN_DIR/screen-11' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-goinfer-stub.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'goinfer: unsupported' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 11 serial-absent 'gpu3d: armed'
vgate_assert 11 serial-contains 'gotabwm: holding seat'
vgate_assert 11 serial-contains 'goinfer: unsupported'
vgate_assert 11 serial-absent 'goinfer: stub answer'
vgate_assert 11 serial-absent 'goinfer: error'
vgate_assert 11 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
p = os.path.join(share, "GOINFER")
if os.path.exists(p):
    sys.exit("GOINFER receipt dir exists on a native-only boot: %r" %
             os.listdir(p))
print("no GOINFER receipts on native-only boot")
PY

# --- leg 10: GOINFER stub-model inference, K=5 (M111c, issue #2410) -------
# One exec, five complete runs of the deterministic PRNG-weights model on
# the journey's single sys_gpucomp session — each a full VIW
# stream-and-seal load, a buffer rebuild, and a greedy decode whose every
# matmul and vocab softmax rides GEMM/DEQUANT/SOFTMAX on the real Metal
# pipelines. The answer is pinned because the model is
# synthetic-by-construction; a real weights image pins its own answer on
# the card's landing PR.
vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-goinfer-stub.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'goinfer OK' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 10 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 10 serial-count 'goinfer: stub run k=' 5
vgate_assert 10 serial-contains 'goinfer: stub consistent K=5'
vgate_assert 10 serial-contains 'goinfer: stub answer'
# The pinned stub answer — observed on the Metal path 2026-10-17 (and
# byte-identical to the kernel-emulating host fake's decode). The sequence
# moved once when the forward path's attention scale landed (the real
# model exposed its absence); any drift now is a real-path regression.
vgate_assert 10 serial-count 'ids=196,99,196,196,196,196,196,196,99,133,99,99,99,99,99,133' 5
vgate_assert 10 serial-contains 'goinfer OK'
vgate_assert 10 serial-absent 'goinfer: error'
vgate_assert 10 serial-absent 'goinfer: diverged'
vgate_assert 10 serial-absent 'gpu3d: timeout'
vgate_assert 10 serial-absent 'gpu3d: badresp'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 output-contains 'compute-refusals=0'
vgate_assert 10 output-contains 'refusals=0'
vgate_assert 10 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
body = open(os.path.join(share, "GOINFER", "RECEIPT.TSV")).read()
if body.count("stub\trun\t") != 5:
    sys.exit("receipt wants 5 run rows:\n%s" % body)
if "stub\tconsistent\tK=5" not in body:
    sys.exit("receipt missing the consistency row\n%s" % body)
print("goinfer receipt rows verified")
PY

# --- leg 12: weights absent is a named failure, not a fabricated answer --
# `goinfer model` on a device-capable boot WITHOUT a staged VIW must name
# its absence and stop — the licence gate's whole point is that the app
# never invents weights it was never given.
vgate_run 12 -- \
    --screen '$RUN_DIR/screen-12' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-goinfer-model.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'goinfer: error absent' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 12 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 12 serial-contains 'goinfer: weights absent'
vgate_assert 12 serial-contains 'goinfer: error absent'
vgate_assert 12 serial-absent 'goinfer: model answer'
vgate_assert 12 serial-absent 'gpu3d: timeout'
vgate_assert 12 output-contains 'compute-submits=0'
vgate_assert 12 output-contains 'refusals=0'
# Leg 12's boot proved the named refusal; NOW the parked VIW (when one
# exists) lands on the app's default path so the model leg that follows
# loads it exactly like an operator's install. Strict optional-file
# semantics: an absent staged file is a skipped move, not a failure.
vgate_assert 12 python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ["VG_SHARE"]
src = os.path.join(rd, "SMOLLM2.VIW")
if not os.path.exists(src):
    print("no parked VIW (clawback state: legs run weights-absent)")
    sys.exit(0)
dst_dir = os.path.join(share, "GOINFER")
os.makedirs(dst_dir, exist_ok=True)
os.replace(src, os.path.join(dst_dir, "SMOLLM2.VIW"))
print("model VIW staged at GOINFER/SMOLLM2.VIW for leg 13")
PY

# --- leg 13: GOINFER owner-approved model, K=5 (M111c, issue #2410) -------
# The licence gate's second half: the real model answers the card's fixed
# ChatML prompt on the same Metal compute path, five consecutive greedy
# decodes on one stream-and-seal load, each run emitting the licence
# receipt (licence / model / staged sha / resident size) the card demands.
# The leg is honest in BOTH states of the staged file — the clawback
# condition made a gate property: when GOINFER/SMOLLM2.VIW is on the share
# the pinned ids and K=5 consistency MUST appear; when it is not (the file
# deleted is the model removed), the same named refusal leg 12 proves must
# appear instead. Either way 'goinfer: done' ends the journey for the rx
# sequencing, and a staged file whose sha differs from the pin fails hard.
vgate_run 13 -- \
    --screen '$RUN_DIR/screen-13' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-goinfer-model.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'goinfer: done' \
    --script-expect 'rx-g3-ok' --timeout 5400

vgate_assert 13 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 13 serial-contains 'gotabwm: holding seat'
vgate_assert 13 serial-contains 'goinfer: done'
vgate_assert 13 serial-absent 'gpu3d: timeout'
vgate_assert 13 serial-absent 'gpu3d: badresp'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 serial-absent 'goinfer: diverged'
vgate_assert 13 output-contains 'compute-refusals=0'
vgate_assert 13 output-contains 'refusals=0'
vgate_assert 13 python <<'PY'
import hashlib, os, sys
share = os.environ["VG_SHARE"]
ser = open(os.environ["VG_SER"], errors="replace").read()
VIW_PIN = "2f5d4c774ea89016ae2b049e288e21a73987fc1c37eb1a58fc1284fad86878bd"
# The pinned greedy answer — the 64 ids observed on the Metal path
# 2026-10-17 ("The capital of France is Paris. ..."), byte-identical to
# the kernel-emulating host fake's decode. Determinism, not fluency, is
# the pin; a drift is a real-path regression.
ANSWER_IDS = "504,3575,282,4649,314,7042,30,7042,314,253,2240,338,553,719,253,2257,282,8238,327,4936,28,6578,28,284,16597,327,5034,30,657,314,3807,281,260,1911,282,260,4206,282,9017,28,10000,411,260,26061,21633,367,7042,28,284,314,253,2240,338,553,719,253,2257,282,8238,327,4936,28,6578,28"
staged = os.path.join(share, "GOINFER", "SMOLLM2.VIW")
if not os.path.exists(staged):
    # Clawback state: the model is gone, the named refusal must still be
    # the only answer the app gives — never a fabricated one.
    for want in ("goinfer: weights absent", "goinfer: error absent",
                 "goinfer: done"):
        if want not in ser:
            sys.exit("absent-path marker missing: %r" % want)
    if "goinfer: model answer" in ser:
        sys.exit("model answer appeared without a staged VIW")
    print("no staged VIW: weights-absent refusal verified (clawback clean)")
    sys.exit(0)
sha = hashlib.sha256(open(staged, "rb").read()).hexdigest()
if sha != VIW_PIN:
    sys.exit("staged VIW sha256 %s != pinned %s" % (sha, VIW_PIN))
for want in ("goinfer: licence=Apache-2.0 " +
             "model=HuggingFaceTB/SmolLM2-135M-Instruct sha=" + VIW_PIN,
             "goinfer: loaded params=",
             "goinfer: model consistent K=5",
             "goinfer: model answer ",
             "goinfer OK"):
    if want not in ser:
        sys.exit("model-path marker missing: %r" % want)
if ser.count("goinfer: model run k=") != 5:
    sys.exit("want 5 model run lines:\n%s" % ser)
if ser.count("ids=" + ANSWER_IDS) != 5:
    sys.exit("pinned ids did not appear on every run")
if "tokps=" not in ser:
    sys.exit("no tok/s evidence emitted")
body = open(os.path.join(share, "GOINFER", "RECEIPT.TSV")).read()
for row in ("model\tlicence\tlicence=Apache-2.0\t" +
            "model=HuggingFaceTB/SmolLM2-135M-Instruct",
            "ssha=" + VIW_PIN, "resident=",
            "model\tconsistent\tK=5"):
    if row not in body:
        sys.exit("receipt missing %r\n%s" % (row, body))
if body.count("model\trun\t") != 5:
    sys.exit("receipt wants 5 model run rows:\n%s" % body)
print("model leg: pinned sha, licence receipt, K=5 consistent answer verified")
PY

# --- leg 14: hostile .VIW is a named refusal, not a crash ----------------
# The setup's crafted image parses as a container but its embed tensor
# lies about its shape; `goinfer model` must refuse the load with a named
# error — console line, receipt, journey-end marker — never a panic, a
# hang, or a fabricated answer. The detail substring pins that the refusal
# is the loader's shape check, not a generic read failure.
vgate_run 14 -- \
    --screen '$RUN_DIR/screen-14' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-goinfer-hostile.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script3 '$RUN_DIR/script-rx.txt' \
    --script3-after 'goinfer: done' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 14 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 14 serial-contains 'goinfer: error'
vgate_assert 14 serial-contains 'viw tensor embed'
vgate_assert 14 serial-contains 'goinfer: done'
vgate_assert 14 serial-absent 'goinfer: model answer'
vgate_assert 14 serial-absent 'goinfer OK'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 serial-absent 'gpu3d: timeout'
vgate_assert 14 serial-absent 'gpu3d: badresp'
vgate_assert 14 output-contains 'compute-submits=0'
vgate_assert 14 output-contains 'refusals=0'

# --- leg 15: the virgl coverage matrix (issue #3176) ----------------------
# Every --gpu3d-metal attach replays VirglCoverage's probe battery through
# the real VirglStreamDecoder — the same decode MetalRenderer's
# gpu3dSubmit runs — and prints one observed verdict per probe plus the
# two field-space sweep rows. This boot asserts the pinned boundary: each
# refused probe's NAMED rejection. A decoder that accepts a refused
# command, or names a refusal differently, drops the line its assert
# wants (or prints DRIFT) — growing the accepted set is a deliberate
# matrix edit, never silent.
vgate_run 15 -- \
    --screen '$RUN_DIR/screen-15' \
    --gpu3d-metal \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-rx.txt' \
    --script2-after 'gotabwm: holding seat' \
    --script-expect 'rx-g3-ok' --timeout 180

vgate_assert 15 serial-contains 'gpu3d: armed did=0x1083'
vgate_assert 15 serial-absent 'gpu3d: timeout'
vgate_assert 15 serial-absent 'gpu3d: badresp'
vgate_assert 15 output-contains 'gpu3d-matrix: canonical: accepted'
vgate_assert 15 output-contains 'gpu3d-matrix: nop-tail-4096: accepted'
vgate_assert 15 output-contains 'gpu3d-matrix: nop-only: accepted'
vgate_assert 15 output-contains 'gpu3d-matrix: empty: refused:empty'
vgate_assert 15 output-contains 'gpu3d-matrix: misaligned: refused:misaligned'
vgate_assert 15 output-contains 'gpu3d-matrix: over-cap: refused:overCap'
vgate_assert 15 output-contains 'gpu3d-matrix: truncated: refused:truncatedCommand'
vgate_assert 15 output-contains 'gpu3d-matrix: nop-nonzero: refused:malformedNOP'
vgate_assert 15 output-contains 'gpu3d-matrix: nop-midstream: refused:malformedNOP'
vgate_assert 15 output-contains 'gpu3d-matrix: unknown-cmd: refused:unknownCommand'
vgate_assert 15 output-contains 'gpu3d-matrix: unknown-obj: refused:unknownObject'
vgate_assert 15 output-contains 'gpu3d-matrix: dead-handle: refused:deadHandle'
vgate_assert 15 output-contains 'gpu3d-matrix: bad-arity: refused:badArity'
vgate_assert 15 output-contains 'gpu3d-matrix: bad-reference: refused:badReference'
vgate_assert 15 output-contains 'gpu3d-matrix: unarmed-clear: refused:unmetPrecondition'
vgate_assert 15 output-contains 'gpu3d-matrix: unarmed-draw: refused:unmetPrecondition'
vgate_assert 15 output-contains 'gpu3d-matrix: bad-handle: refused:badHandle'
vgate_assert 15 output-contains 'gpu3d-matrix: bad-field: refused:badField'
vgate_assert 15 output-contains 'gpu3d-matrix: shader-handle-type: refused:shaderHandleType'
vgate_assert 15 output-contains 'gpu3d-matrix: shader-framing: refused:shaderFraming'
vgate_assert 15 output-contains 'gpu3d-matrix: shader-text: refused:shaderText'
vgate_assert 15 output-contains 'gpu3d-matrix: object-field-set: refused:objectFieldSet'
vgate_assert 15 output-contains 'gpu3d-matrix: second-draw: refused:unmetPrecondition'
vgate_assert 15 output-contains 'gpu3d-matrix: leaked-object: refused:leakedObjects'
vgate_assert 15 output-contains 'gpu3d-matrix: cmd-space handled=0,1,2,3,4,5,6,7,8,30 refused-unknownCommand=246'
vgate_assert 15 output-contains 'gpu3d-matrix: obj-space handled=1,2,3,4,5,8 refused-unknownObject=250'
vgate_assert 15 output-contains 'gpu3d-matrix: pinned 24/24 probes'
