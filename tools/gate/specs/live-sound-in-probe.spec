# live-sound-in-probe.spec -- M118a (issue #2479): the `--sound-in` probe.
# `--sound-in` attaches VZVirtioSoundDeviceInputStreamConfiguration +
# VZHostAudioInputStreamSource; the guest enumerates INPUT topology via its
# stream-0 PCM_INFO query (VZ does not populate the devcfg stream count, so
# the driver asks the control queue; input is attached at index 0 because
# snd_pcm_probe is hardcoded start_id=0 — no kernel changes on this card).
#
# The flag lives on the SoundInProbe executable (same package, same swift
# build, same ad-hoc entitlements signature): VMRunner's argument loop is a
# flat `arg ==` chain with no extension point, so a VMRunner flag cannot
# exist without editing main.swift, which is held by #2475/#2476. The probe
# legs below boot that binary from python hooks; run 01 pins the stock
# runner's flag-off named refusal and its byte-identical default VM.

vgate_name live-sound-in-probe "M118a virtio-snd input-stream probe"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
sound
beep 440 100
EOF

# Run 01 -- flag off, stock VMRunner: no sound flags, so `sound` and `beep`
# answer the guest's named refusal (no virtio-snd device on the bus).
# warm sweep (M131d #2641, ADR 0059): single-leg spec on share=none —
# the leg's evidence is leg-epoch serial markers only, so it converts;
# its first --script-after names a boot marker that D5 re-bases onto
# the post-restore handshake.
vgate_checkpoint sp --
vgate_run 01 --from-checkpoint sp -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'beep:' --timeout 90

vgate_assert 01 serial-contains 'sound: no virtio-snd device (DID 0x1059 not found on bus 0)'
vgate_assert 01 serial-contains 'error: beep: no virtio-snd device (DID 0x1059 not found on bus 0)'
vgate_assert 01 serial-absent 'sound: ready'

# Flag on -- SoundInProbe --sound-in: the guest's PCM_INFO(0) reports the
# INPUT direction row (dir=1) with VZ's advertised formats/rates/channels,
# and `beep` then refuses honestly — an input stream is not a playable
# output. Observed live on macOS 27.2 (26B5112a): formats=0xa0020
# (S16|S32|FLOAT), rates=0x480 (48k|96k), ch=1..2, dir=1.
vgate_assert 01 python <<'PY'
import os, shutil, subprocess, sys
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
serial = os.path.join(rd, "probe-soundin-serial.log")
run = subprocess.run(
    [probe, "--disk", "artifacts/disk.img",
     "--vars", os.path.join(rd, "probe-in-vars.bin"),
     "--serial", serial,
     "--sound-in",
     "--script", os.path.join(rd, "script.txt"),
     "--script-expect", "beep: ",
     "--timeout", "90"],
    capture_output=True, text=True)
open(os.path.join(rd, "probe-soundin-run.txt"), "w").write(run.stdout + run.stderr)
if os.path.exists(serial):
    shutil.copyfile(serial, "artifacts/live-sound-in-probe-serial-soundin%s.log" % suffix)
if run.returncode != 0:
    sys.exit("SoundInProbe --sound-in exited %d:\n%s%s" % (run.returncode, run.stdout[-1500:], run.stderr[-1500:]))
if "SOUND-IN: virtio-snd attached (input" not in run.stdout:
    sys.exit("probe did not report the input attach:\n%s" % run.stdout[-1500:])
if "SOUND-IN: mic authorizationStatus=" not in run.stdout:
    sys.exit("probe did not report the mic consent state:\n%s" % run.stdout[-1500:])
text = open(serial, errors="replace").read()
for want in (
    "beep: info st=0x0000000000008000 formats=0x00000000000a0020 rates=0x0000000000000480 ch=1..2 dir=1",
    "beep: FAILED (no supported output channel tuple)",
):
    if want not in text:
        sys.exit("guest serial missing INPUT row %r" % want)
PY

# Flag off on the probe binary itself: no --sound-in, no --sound — the same
# guest answers the same named refusal, proving the flag is what arms the
# input stream rather than the binary always attaching it.
vgate_assert 01 python <<'PY'
import os, subprocess, sys
rd = os.environ["RUN_DIR"]
repo = os.getcwd()
probe = os.path.join(repo, "host/vm-runner/.build/release/SoundInProbe")
serial = os.path.join(rd, "probe-off-serial.log")
run = subprocess.run(
    [probe, "--disk", "artifacts/disk.img",
     "--vars", os.path.join(rd, "probe-off-vars.bin"),
     "--serial", serial,
     "--script", os.path.join(rd, "script.txt"),
     "--script-expect", "beep:",
     "--timeout", "90"],
    capture_output=True, text=True)
open(os.path.join(rd, "probe-off-run.txt"), "w").write(run.stdout + run.stderr)
if run.returncode != 0:
    sys.exit("SoundInProbe (flag off) exited %d:\n%s%s" % (run.returncode, run.stdout[-1500:], run.stderr[-1500:]))
if "SOUND-IN: flag off" not in run.stdout:
    sys.exit("probe did not report the flag-off state:\n%s" % run.stdout[-1500:])
text = open(serial, errors="replace").read()
if "sound: no virtio-snd device (DID 0x1059 not found on bus 0)" not in text:
    sys.exit("flag-off leg missing the named refusal")
PY
