# live-glyphs.spec -- the MIRROR-REGRESSION TRIPWIRE (follow-on to the
#
# ScreenCaptureKit switch, 2026-08-12): the captured framebuffer is decoded
# against the kernel's OWN font8x8.zig glyph table (kernel/src/font8x8.zig),
# normalized from its documented LSB-left source rows, and the text must read
# FORWARD.
#
# Why: the milestone-six pixel gates (live-screen/live-text/live-roadpops)
# assert the evidence shows green-family glyphs over the dark background —

vgate_name live-glyphs "the MIRROR-REGRESSION TRIPWIRE (follow-on to the"

vgate_file script.txt <<'EOF'
echo ROADPOPS
uname
roadpops
EOF

vgate_run 01 -- --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --expect "roadpops: armed target=fbtext" --script-expect "roadpops: armed=1" --script-expect-tail 5.0 --timeout 30

# The capture path is host-permission dependent: SCK when Screen Recording
# is granted, the runner's documented cacheDisplay fallback otherwise (the
# view's actual content area — still the gate's pixel evidence). The python
# below notes which path ran; the glyph/tripwire asserts are the contract.
vgate_assert 01 python <<'PY'
import os, sys
# The runner's stdout lives at $RUN_DIR/run-<tag>.out (the python assert env
# carries RUN_DIR/VG_SER/VG_TAG/VG_SHARE; VG_OUT is shell-only).
out = open(os.path.join(os.environ["RUN_DIR"], "run-01.out"), errors="replace").read()
if "capture path: ScreenCaptureKit" in out:
    print("capture path: ScreenCaptureKit")
elif "capture path: cacheDisplay fallback" in out:
    print("capture path: cacheDisplay fallback (no Screen Recording grant)")
else:
    sys.exit("FAIL: no capture-path report in the runner output")
PY
vgate_assert 01 serial-contains 'roadpops: armed target=fbtext'
# The presents counter is a liveness signal (>=1 since arm); both it and the
# transient dirty flag race with the idle loop's drain cadence — banner +
# prompt batches may drain separately (observed presents=2) or coalesce.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"roadpops: armed=(\d) dirty=(\d) presents=(\d+)", ser)
assert m, "roadpops report missing"
assert m.group(1) == "1", "fbtext target not armed"
assert int(m.group(3)) >= 1, "no present since arm: %s" % m.group(0)
print("roadpops:", m.group(0))
PY
vgate_assert 01 serial-contains 'text: boot banner presented'
vgate_assert 01 serial-contains 'VirelaiOS - AArch64 firmware-assisted kernel monitor'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, glob, subprocess, sys, re

run_dir = os.environ["RUN_DIR"]
out_file = os.path.join(run_dir, "run-01.out")
if os.path.exists(out_file):
    with open(out_file) as f:
        out_text = f.read()
    if "capture path: cacheDisplay fallback" in out_text:
        # Screen Recording permission is host-local policy, not guest
        # evidence — on hosts without it the runner's cacheDisplay path
        # still renders the view's real content area, and the pixel
        # decode below is the actual contract.
        print("note: cacheDisplay fallback (Screen Recording permission unavailable)")

snaps = sorted(glob.glob(os.path.join(run_dir, "gpu-screen-*s")), key=os.path.getmtime, reverse=True)
if not snaps:
    print("FAIL: no gpu-screen snapshot found")
    sys.exit(1)
latest = snaps[0]
if os.path.exists(os.path.join(run_dir, "gpu-screen-5s")):
    latest = os.path.join(run_dir, "gpu-screen-5s")

res = subprocess.run(["python3", "tools/decode-screen-glyphs.py", latest], capture_output=True, text=True)
print(res.stdout)
if res.returncode != 0:
    print("FAIL: decode script failed")
    sys.exit(1)

m = re.search(r'STATS fwd_unknowns=(-?\d+) fwd_ink=(-?\d+) mir_unknowns=(-?\d+) mir_ink=(-?\d+)', res.stdout)
if not m:
    print("FAIL: STATS line missing")
    sys.exit(1)

fwd_u, fwd_i, mir_u, mir_i = map(int, m.groups())
if fwd_u == -1:
    print("FAIL: fwd_u is -1")
    sys.exit(1)
if fwd_u > 2:
    print(f"FAIL: fwd_u={fwd_u} > 2")
    sys.exit(1)
if mir_u <= fwd_u * 3 + 8:
    print(f"FAIL: mir_u={mir_u} <= fwd_u*3+8")
    sys.exit(1)

if not re.search(r'(VirelaiOS|elaiOS) - AArch64', res.stdout):
    print("FAIL: boot banner missing in decode")
    sys.exit(1)
if not re.search(r'(virelai|elai)>', res.stdout):
    print("FAIL: prompt missing in decode")
    sys.exit(1)

print("PASS: glyph mirror tripwire check successful")
PY
