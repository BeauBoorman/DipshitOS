# live-sound-record.spec -- M118d (issue #2482): GOREC.ELF records N seconds
# of the v1 capture tuple (S16/48 kHz/mono, slot 92) to a RIFF/WAVE file
# published crash-safe through vi.WriteFileSafe.
#
# Run 01 pins the device-absent named refusal: the stock VMRunner boot has
# no --sound, slot 91 reports ready=0 and slot 92 answers ENXIO — and a
# refused record leaves NO file. The assert-time SoundInProbe
# --sound-in --share leg puts the input stream at index 0 and records 2 s to
# /host/GOREC/clip.wav; the host then checks the share itself: a byte-exact
# 44-byte PCM header, the recomputed duration, and sha256(file) == the
# sha256 the guest printed. Whether frames arrive is the HOST's mic-consent
# answer (M118b observed: an unentitled launcher is denied without a prompt
# and the device completes nothing), so BOTH outcomes are pinned — the
# consented byte-proof or the bounded ETIMEDOUT refusal with no file.
#
# HOST PREREQUISITE (fails honestly when missing):
#   bash tools/go/build-gorec.sh   ->  .build/go/GOREC.ELF

vgate_name live-sound-record "M118d (#2482): GOREC.ELF records N s to WAV via WriteFileSafe — the host recomputes header, duration and sha256 off the share"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec GOREC.ELF 2 /host/GOREC/absent.wav
EOF

vgate_setup_python <<'PY'
import os, subprocess, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
# The freshness guard refuses a stale or missing ELF by name (issue #1503's
# convention) — the gate never boots a binary this tree did not produce.
rc = subprocess.run(["bash", "tools/go/build-gorec.sh", "check"]).returncode
if rc != 0:
    sys.exit("GOREC.ELF missing or stale — build it first: "
             "bash tools/go/build-gorec.sh")
subprocess.run(["bash", "tools/go/build-gorec.sh", "stage", share], check=True)
PY

# Run 01 -- the stock VM's named refusal. No --sound device on the bus, so
# the capture request answers ENXIO before the tuple is even checked.
# `gorec: done` is the program's own terminal marker (SPEC.md idiom 1),
# printed on the refusal path too.
vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'gorec: done' --timeout 90

vgate_assert 01 serial-contains 'exec: loaded GOREC.ELF'
vgate_assert 01 serial-contains 'gorec: cap ready=0'
vgate_assert 01 serial-contains 'gorec: refused ENXIO at=0 of=192000'
vgate_assert 01 serial-contains 'gorec: done'
vgate_assert 01 serial-absent 'gorec: wrote'
vgate_assert 01 serial-absent '[EXC] parking'

# A refused record leaves nothing behind on the share — the guest's file
# channel is the second reporter, and its silence must agree with serial.
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
p = os.path.join(share, "GOREC", "absent.wav")
if os.path.exists(p):
    sys.exit("the absent-device refusal left a file behind: " + p)
PY

# Run 02 -- M122c (#2572): a BARE `exec GOREC.ELF` is the launcher's click.
# It must open the windowed view — `gorec: view open id=` on serial — never
# fall to the usage line. The run ends on the marker; the window is torn
# down with the boot.
vgate_file script-view.txt <<'EOF'
exec GOREC.ELF
EOF

vgate_run 02 -- --script '$RUN_DIR/script-view.txt' --script-expect 'gorec: view open id=' --timeout 90

vgate_assert 02 serial-contains 'exec: loaded GOREC.ELF'
vgate_assert 02 serial-contains 'gorec: view open id='
vgate_assert 02 serial-absent 'gorec: window refused'
vgate_assert 02 serial-absent 'gorec: usage:'
vgate_assert 02 serial-absent '[EXC] parking'

# The capture leg -- SoundInProbe --sound-in --share: the input stream at
# index 0, the VirtioFS share as exec's app source and the WAV's /host. The
# guest takes 2 s of the v1 tuple (192000 B = 3 bounded slot-92 calls) and
# publishes through WriteFileSafe. A consented host lands a file the host
# re-verifies byte for byte; a denied host prints the bounded ETIMEDOUT and
# the share stays empty — never a hang, never a truncated WAV.
vgate_assert 01 python <<'PY'
import hashlib, os, re, shutil, subprocess, sys

rd = os.environ["RUN_DIR"]
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
probe = os.path.join(os.getcwd(), "host/vm-runner/.build/release/SoundInProbe")
if not os.path.exists(probe):
    sys.exit("SoundInProbe missing at %s (the package swift build precedes the run)" % probe)
codesign = subprocess.run(
    ["codesign", "--force", "--sign", "-", "--entitlements",
     "host/vm-runner/entitlements.plist", probe],
    capture_output=True, text=True)
if codesign.returncode != 0:
    sys.exit("codesign of SoundInProbe failed: %s%s" % (codesign.stdout, codesign.stderr))

share = os.path.join(rd, "record-share")
os.makedirs(share, exist_ok=True)
subprocess.run(["bash", "tools/go/build-gorec.sh", "stage", share], check=True)

script = os.path.join(rd, "record-script.txt")
with open(script, "w") as fh:
    fh.write("exec GOREC.ELF 2 /host/GOREC/clip.wav\n")
serial = os.path.join(rd, "record-serial.log")
run = subprocess.run(
    [probe, "--disk", "artifacts/disk.img",
     "--vars", os.path.join(rd, "record-vars.bin"),
     "--serial", serial,
     "--sound-in", "--share", share,
     "--script", script,
     "--script-expect", "gorec: done",
     "--timeout", "180"],
    capture_output=True, text=True)
with open(os.path.join(rd, "record-run.txt"), "w") as fh:
    fh.write(run.stdout + run.stderr)
if os.path.exists(serial):
    shutil.copyfile(serial, "artifacts/live-sound-record-serial-record%s.log" % suffix)
if run.returncode != 0:
    sys.exit("SoundInProbe --sound-in --share exited %d:\n%s%s"
             % (run.returncode, run.stdout[-1500:], run.stderr[-1500:]))
text = open(serial, errors="replace").read()

# The guest took the scripted exec and ran to its terminal marker.
for want in ("exec: loaded GOREC.ELF", "gorec: done"):
    if want not in text:
        sys.exit("guest serial missing %r — the recorder never finished" % want)
m = re.search(r"gorec: cap ready=(\d+)", text)
if not m or m.group(1) != "1":
    sys.exit("slot 91 did not report the observed INPUT stream "
             "(cap line: %r)" % (m.group(0) if m else "absent"))

clip = os.path.join(share, "GOREC", "clip.wav")
wrote = re.search(r"gorec: wrote (\S+) seconds=(\d+) frames=(\d+)"
                  r" bytes=(\d+) sha256=([0-9a-f]{64})", text)
refused = re.search(r"gorec: refused (\w+)", text)

if wrote:
    path, seconds, frames, nbytes, sha = wrote.groups()
    if path != "/host/GOREC/clip.wav" or seconds != "2":
        sys.exit("receipt path/seconds wrong: %r" % wrote.group(0))
    if int(frames) != 96000 or int(nbytes) != 192000:
        sys.exit("receipt arithmetic broken: frames=%s bytes=%s"
                 % (frames, nbytes))
    if not os.path.isfile(clip):
        sys.exit("guest reported wrote but the share holds no clip.wav")
    # Lift the evidence before the share is torn down.
    kept = os.path.join(rd, "share-GOREC_clip.wav")
    shutil.copyfile(clip, kept)
    shutil.copyfile(kept, "artifacts/live-sound-record-share-GOREC_clip%s.wav" % suffix)
    body = open(clip, "rb").read()
    # The whole 44-byte header is determined by the v1 tuple — byte-compare
    # it, then recompute duration and sha256 off the share, never trusting
    # the receipt for either.
    want_hdr = (
        b"RIFF" + (36 + 192000).to_bytes(4, "little") + b"WAVE"
        + b"fmt " + (16).to_bytes(4, "little")
        + (1).to_bytes(2, "little")      # WAVE_FORMAT_PCM
        + (1).to_bytes(2, "little")      # mono
        + (48000).to_bytes(4, "little")
        + (96000).to_bytes(4, "little")  # byte rate
        + (2).to_bytes(2, "little")      # block align
        + (16).to_bytes(2, "little")     # bits
        + b"data" + (192000).to_bytes(4, "little")
    )
    if len(body) != 44 + 192000 or body[:44] != want_hdr:
        sys.exit("clip.wav is not the expected PCM16/48k/mono RIFF/WAVE: "
                 "len=%d" % len(body))
    data_len = int.from_bytes(body[40:44], "little")
    if data_len % 96000 != 0 or data_len // 96000 != 2:
        sys.exit("recomputed duration is not 2 s: data=%d B" % data_len)
    if hashlib.sha256(body).hexdigest() != sha:
        sys.exit("share file sha256 disagrees with the guest's receipt")
    print("record leg: captured=192000 sha256=%s verified off the share" % sha)
elif refused:
    name = refused.group(1)
    if name != "ETIMEDOUT":
        sys.exit("capture refused %s, want ETIMEDOUT (or the wrote receipt)"
                 % name)
    if "gorec: wrote" in text:
        sys.exit("both refused and wrote markers present")
    if os.path.exists(clip):
        sys.exit("a refused record left a WAV behind")
    print("record leg: host mic denied — bounded ETIMEDOUT, no file (pass shape)")
else:
    sys.exit("no outcome: neither a wrote receipt nor a refused marker")
PY
