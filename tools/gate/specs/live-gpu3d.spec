# live-gpu3d.spec -- M102f2 (issue #2171) class-B acceptance: a guest Go app
# (GPUTRIANGLE.ELF) drives the opt-in VIR1 render device over the real seat
# -> broker -> Metal path; the private profile's raw BGRA readback export and
# the VZ scanout are pixel-proven by f1's independent comparator/geometry.
# Nine independent boots, one leg each: 01 triangle, 02 mixed margins,
# 03 resize/second generation, 04 close/reuse, 05 native-only (no render
# device), 06 malformed/auth (invalid battery + forged kind-17), 07
# wrong/stale fence, 08 stall/timeout + next-open drain, 09 M111b GPU
# compute (slot-90 GEMM submit->fence->readback + named refusal). `wm=none`
# is seeded so the seat is the spec's own scripted exec; every leg ends on
# a marker only its script can print. Leg 05 RUNS FIRST: the seed share is
# spec-scoped, so its no-receipt assert is only honest before any 3D leg
# has written GPUTRI/ files to it.
# exec-order: assert-proven -- each run's expect marker is printed by the
# script AFTER the guest markers its stage gates wait on; a leg whose
# device/app never ran cannot pass. HOST PREREQUISITE (fails honestly):
#   bash tools/go/build-gotabwm.sh tools/go/build-gputriangle.sh

vgate_name live-gpu3d "M102f2 #2171: guest triangle through real VIR1/Metal into the native 2D seat, 9 legs, raw-BGRA readback + scanout pixels + fence/timeout lifecycle + M111b #2409 slot-90 compute round trip"
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

vgate_file script-rx.txt <<'EOF'
echo rx-g3-ok
EOF

vgate_file script-rx-invalid.txt <<'EOF'
echo rx-g3-invalid-ok
EOF

# GOTABWM.ELF and GPUTRIANGLE.ELF are .build products, not zig-out: stage
# both plus the wm=none seat opt-in (go-wm-seat's own pattern) so each leg
# boots exactly one seat and the app's build stamp is honoured.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name in ("GOTABWM.ELF", "GPUTRIANGLE.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: "
                 "bash tools/go/build-%s.sh"
                 % (name, src, name[:-4].lower()))
    shutil.copy(src, os.path.join(share, name))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("staged Go seat + GPUTRIANGLE.ELF, wm=none")
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
    --screenshot-after 'gputri: win-present' \
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
# clear field — one capture, fired on the successful present marker. The
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
PY
