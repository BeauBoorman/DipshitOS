# live-sound-device.spec -- claim 6140 (Milestone 15 Card A1): virtio-snd transport on VZ.
# The runner boots with --sound. The guest discovers the virtio-snd device on PCI
# bus 0 (DID 0x1059, class 0x040100), negotiates features, arms the control queue,
# reaches DRIVER_OK (st=0x0f), re-arms post-MMU, and reports device config via `sound`.

vgate_name live-sound-device "M15 A1 virtio-snd transport on VZ"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
sound
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'sound: cfg=' --timeout 90

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'snd: pre-rearm st=0f'
vgate_assert 01 serial-contains 'snd: rearm ok st=0f'
vgate_assert 01 serial-contains 'did=0x0000000000001059'
vgate_assert 01 serial-contains 'cls=0x0000000000040100'
vgate_assert 01 serial-contains 'st=0x000000000000000f'
vgate_assert 01 serial-contains 'qsz=0x0000000000000004'
vgate_assert 01 serial-contains 'sound: cfg=jacks=0 streams=0 chmaps=0'
vgate_assert 01 serial-absent '[EXC] parking'

# M118b (#2480): the capture leg. SoundInProbe --sound-in puts the input
# stream at index 0; the guest's rearm-time self-test negotiates the v1
# tuple (S16/48 kHz/mono) on queue 3, posts the RX buffers after START
# (post-before-START wedges VZ's control queue — observed), drains into
# the bounded ring, and prints the receipt plus the named-refusal
# exercise. Whether frames actually arrive is the HOST's mic-consent
# answer (observed 2026-10-17: the VZ XPC helper asks TCC for
# kTCCServiceMicrophone at stream start; a launcher without the
# audio-input entitlement gets denied without a prompt and the device
# completes nothing). Both outcomes are pinned: a consented host prints
# the 8192-frame receipt; a denied host prints the bounded
# 'RX drain timeout' refusal. The refusal names print either way.
vgate_assert 01 python <<'PY'
import os, re, shutil, subprocess, sys

rd = os.environ["RUN_DIR"]
repo = os.getcwd()
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
probe = os.path.join(repo, "host/vm-runner/.build/release/SoundInProbe")
if not os.path.exists(probe):
    sys.exit("SoundInProbe missing at %s (the package swift build precedes the run)" % probe)
codesign = subprocess.run(
    ["codesign", "--force", "--sign", "-", "--entitlements",
     "host/vm-runner/entitlements.plist", probe],
    capture_output=True, text=True)
if codesign.returncode != 0:
    sys.exit("codesign of SoundInProbe failed: %s%s" % (codesign.stdout, codesign.stderr))
serial = os.path.join(rd, "capture-serial.log")
run = subprocess.run(
    [probe, "--disk", "artifacts/disk.img",
     "--vars", os.path.join(rd, "capture-vars.bin"),
     "--serial", serial,
     "--sound-in",
     "--script-expect", "cap: refuse",
     "--timeout", "120"],
    capture_output=True, text=True)
open(os.path.join(rd, "capture-run.txt"), "w").write(run.stdout + run.stderr)
if os.path.exists(serial):
    shutil.copyfile(serial, "artifacts/live-sound-device-serial-capture%s.log" % suffix)
if run.returncode != 0:
    sys.exit("SoundInProbe --sound-in exited %d:\n%s%s" % (run.returncode, run.stdout[-1500:], run.stderr[-1500:]))
text = open(serial, errors="replace").read()

# The self-test ran the v1 tuple: INFO/SET_PARAMS/PREPARE/START on stream 0.
for want in (
    "cap: rx capture fmt=5 rate=7 ch=1 want=8192",
    "cap: info=0x0000000000008000 params=0x0000000000008000 prepare=0x0000000000008000 start=0x0000000000008000",
):
    if want not in text:
        sys.exit("guest serial missing capture control row %r" % want)

# The named refusals print whatever the device did.
ref = ("cap: refuse fmt 'capture format over cap (S16)' "
       "rate 'capture rate over cap (48kHz)' "
       "ch 'capture channels over cap (mono)' "
       "ring 'capture request exceeds ring'")
if ref not in text:
    sys.exit("guest serial missing the named-refusal exercise")

# The outcome leg: EITHER a real receipt (host mic consented) OR the
# bounded drain-timeout refusal (host mic denied) — never a hang, never
# silence. The receipt, when present, is checked as arithmetic like the
# playback identity: 8192 frames x 2 B = 16384 bytes, ring <= bound.
if "cap: ok" in text:
    m = re.search(r"cap: captured=(\d+) frames bytes=(\d+) ring=(\d+)/(\d+)", text)
    if not m:
        sys.exit("cap: ok without a receipt line")
    frames, cap_bytes, ring_used, ring_cap = (int(g) for g in m.groups())
    if frames != 8192 or cap_bytes != frames * 2:
        sys.exit("receipt identity broken: frames=%d bytes=%d" % (frames, cap_bytes))
    if ring_used != cap_bytes or ring_used > ring_cap:
        sys.exit("ring bound broken: used=%d bytes=%d cap=%d" % (ring_used, cap_bytes, ring_cap))
elif "cap: FAILED (RX drain timeout)" in text:
    # The denied host completes zero buffers — the timeout is the honest,
    # bounded record (not a hang: STOP/RELEASE still ran).
    if "cap: captured=0 frames bytes=0" not in text:
        sys.exit("drain timeout without a zero receipt")
else:
    sys.exit("no capture outcome: neither 'cap: ok' nor 'cap: FAILED (RX drain timeout)'")

if "[EXC] parking" in text:
    sys.exit("guest parked an exception during the capture leg")
PY
