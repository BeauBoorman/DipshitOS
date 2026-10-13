# live-sound-playback.spec -- claim 5877 (Milestone 15 Card A2): PCM playback on VZ.
# The runner boots with --sound and executes `beep 440 300`. The guest drives virtio-snd
# PCM_INFO -> PCM_SET_PARAMS -> PCM_PREPARE -> PCM_START -> TX submission (4096-B
# periods of FLOAT/stereo/48 kHz) -> drain -> PCM_STOP -> PCM_RELEASE.

vgate_name live-sound-playback "M15 A2 PCM playback on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
beep 440 300
sound
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'beep: ok' --timeout 150

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'snd: pre-rearm st=0f'
vgate_assert 01 serial-contains 'beep: info st=0x0000000000008000'
vgate_assert 01 serial-contains 'formats=0x00000000000a0020'
vgate_assert 01 serial-contains 'rates=0x0000000000000480'
vgate_assert 01 serial-contains 'ch=1..2 dir=0'
vgate_assert 01 serial-contains 'beep: params fmt=19 rate=7 ch=2'
vgate_assert 01 serial-contains 'st=0x0000000000008000 prepare=0x0000000000008000 start=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: tx submitted=115200 drained=115200 frames=14400'
vgate_assert 01 serial-contains 'pcm_status=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: stop=0x0000000000008000 release=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: ok'
vgate_assert 01 serial-absent '[EXC] parking'

# M70f2 (#1476): the accounting IDENTITY, asserted as arithmetic instead of as
# a verbatim line. A pinned `submitted=115200 drained=115200` catches a change
# but cannot catch a *consistent wrong* pair (a period dropped and a frame count
# adjusted to match), whereas the three relations below each fail on their own
# for their own reason: the geometry (300 ms at 48 kHz), the format width
# (FLOAT/stereo = 8 bytes a frame), and the identity itself (every submitted
# byte drained). The card's rule is to assert the identity, not "sound came
# out" -- and this is the PCM path, so it belongs here.
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
m = re.search(r"beep: tx submitted=(\d+) drained=(\d+) frames=(\d+)", ser)
if not m:
    sys.exit("ERROR: no beep tx marker in serial")
submitted, drained, frames = (int(g) for g in m.groups())
if frames != 300 * 48:
    sys.exit(f"ERROR: frames={frames}, want 300 ms at 48 kHz")
if submitted != frames * 8:
    sys.exit(f"ERROR: submitted={submitted} is not frames={frames} * 8 (FLOAT/stereo)")
if drained != submitted:
    sys.exit(f"ERROR: ACCOUNTING IDENTITY BROKEN: drained={drained} of submitted={submitted}")

# The device agreed, from the other side of the same submission: a period that
# never reached the queue would leave a non-zero status here.
if "pcm_status=0x0000000000008000" not in ser:
    sys.exit("ERROR: pcm_status is not the virtio-snd OK value 0x8000")
PY

# B7 (#1874) + M99b (#2180): same real output device, opt-in slot 43 streaming
# through the kernel mixer. PCM.BIN now runs three processes against one device
# stream: the orchestrator, a "peer" streamer that overlaps with it, and a
# "death" streamer whose exit reaps its seat mid-stream. This is
# ownership/accounting evidence, not capture or a low-latency guarantee.
vgate_setup_python <<'PY'
import os, subprocess
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
elf = os.path.join(rd, "pcm.elf")
subprocess.run([
    "zig", "build-exe", "kernel/tests/pcm_guest.zig",
    "-target", "aarch64-freestanding-none", "-O", "ReleaseSafe",
    "-fsingle-threaded", "-fno-PIE", "-fno-stack-check", "-fno-stack-protector",
    "-fno-unwind-tables", "--script", "user/linker-segmented.ld", "-fentry=_start",
    "-femit-bin=" + elf,
], check=True)
subprocess.run(["python3", "tools/elf2bin.py", "--segments", elf,
                os.path.join(share, "PCM.BIN")], check=True)
PY

vgate_file pcm.txt <<'EOF'
exec PCM.BIN
EOF
vgate_file pcm-done.txt <<'EOF'
echo b7-gate-done
EOF

vgate_run stream -- --sound --script '$RUN_DIR/pcm.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/pcm-done.txt' --script2-after 'b7: done' \
    --script2-delay 3 --script-expect 'b7-gate-done' --timeout 150
vgate_assert stream output-contains 'SOUND: virtio-snd attached'
vgate_assert stream serial-contains 'b7: bounds=4x4096 backpressure=EAGAIN accepted=16384 copy-rollback=0 legacy=EAGAIN'
vgate_assert stream serial-contains 'b7: cap=4 open5=ENOSPC refused=1 sources=1'
vgate_assert stream serial-contains 'b7: overlap sources=2 peak=4 both-advanced'
vgate_assert stream serial-contains 'b7: peer accepted=65536 submitted=65536 completed=65536 sources=2'
vgate_assert stream serial-contains 'b7: owner exits with queued PCM'
vgate_assert stream serial-contains 'b7: owner-death teardown sources=1 survivor-advances'
vgate_assert stream serial-contains 'b7: underrun counted no-XRUN resume=ok'
vgate_assert stream serial-contains 'b7: continuous accepted=131072 submitted=131072 completed=131072 starts=1 stops=1 releases=1 resets=0'
vgate_assert stream serial-contains 'b7: output only, no capture or low-latency claim'
vgate_assert stream serial-contains 'b7: done'
vgate_assert stream serial-absent 'b7: FAIL'
vgate_assert stream serial-absent 'b7: PANIC'
vgate_assert stream serial-absent '[EXC] parking'
vgate_assert stream serial-absent 'exited status=139'
vgate_assert stream python <<'PY'
import os, re
serial = open(os.environ["VG_SER"], "rb").read()
assert serial.count(b"b7: continuous accepted=131072") == 1
# orchestrator + peer + death child, each a clean exit
assert len(re.findall(rb"procs PCM\.BIN exited status=0", serial)) == 3
PY

vgate_run absent -- --script '$RUN_DIR/pcm.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/pcm-done.txt' --script2-after 'b7: done' \
    --script2-delay 3 --script-expect 'b7-gate-done' --timeout 150
vgate_assert absent serial-contains 'b7: NO AUDIO DEVICE (ENXIO), playback refused'
vgate_assert absent serial-contains 'b7: done'
vgate_assert absent serial-contains 'procs PCM.BIN exited status=0'
vgate_assert absent serial-absent 'b7: continuous'
vgate_assert absent serial-absent 'b7: FAIL'
vgate_assert absent serial-absent 'b7: PANIC'
vgate_assert absent serial-absent '[EXC] parking'

# ----------------------------------------------------------------------
# M99c (#2181): the WAV player on the same real device. GOFILES opens a
# >256 KiB 44.1 kHz stereo s16 file (TONE.WAV), GOSOUND parses it,
# resamples 44100 -> 48000 linearly, and streams through the M99b mixer
# seat while PCM.BIN's peer mode proves a second source mixes alongside.
# The accounting asserts are the card's: the seat's counters must equal
# the file's expected post-resample byte count exactly.
vgate_setup_python <<'PY'
import math, os, shutil, struct, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for elf, script in (("GOSOUND.ELF", "gosound"), ("GOFILES.ELF", "files")):
    src = os.path.join(".build", "go", elf)
    if not os.path.exists(src):
        sys.exit(elf + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/build-" + script + ".sh")
    shutil.copy(src, os.path.join(share, elf))
d = os.path.join(share, "SND")
os.makedirs(d, exist_ok=True)
# 3 s of 44.1 kHz stereo s16 sine: 132300 frames, 529200 B of PCM — past the
# card's 256 KiB floor, and a rate the negotiated 48 kHz tuple must resample.
rate, frames = 44100, 132300
data = bytearray()
for i in range(frames):
    v = int(0.2 * 32767 * math.sin(2 * math.pi * 440 * i / rate))
    data += struct.pack("<hh", v, v)
hdr = (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE" +
       b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16) +
       b"data" + struct.pack("<I", len(data)))
with open(os.path.join(d, "TONE.WAV"), "wb") as f:
    f.write(hdr + data)
print("staged GOSOUND/GOFILES + TONE.WAV (%d bytes, %d frames)" %
      (len(hdr) + len(data), frames))
PY

vgate_file gosound-open.txt <<'EOF'
exec GOFILES.ELF /host/SND
EOF
vgate_file gosound-peer.txt <<'EOF'
exec PCM.BIN peer
EOF
vgate_file gosound-done.txt <<'EOF'
echo m99c-gate-done
EOF
vgate_file gosound-exec.txt <<'EOF'
exec GOSOUND.ELF /host/SND/TONE.WAV
EOF

# The dispatch chain is the card's acceptance: GOFILES' default open picks
# GOSOUND for type=audio, vi.Exec launches it, the seat streams the whole
# file, and the peer overlaps mid-playback. `gosound:` markers print only
# after the syscall they report.
vgate_run wav -- --sound \
    --screen '$RUN_DIR/gosound-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/gosound-open.txt' \
    --input-chords 'return' \
    --input-chords-after 'gofiles: ready' \
    --script2 '$RUN_DIR/gosound-peer.txt' \
    --script2-after 'gosound: streaming gen=' \
    --script3 '$RUN_DIR/gosound-done.txt' \
    --script3-after 'gosound: done ' \
    --script-expect 'm99c-gate-done' --timeout 240

vgate_assert wav output-contains 'SOUND: virtio-snd attached'
vgate_assert wav serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert wav serial-contains 'gofiles: list /host/SND n=1'
vgate_assert wav serial-contains 'gofiles: open file TONE.WAV type=audio handler=GOSOUND.ELF'
vgate_assert wav serial-contains 'gofiles: open launched TONE.WAV handler=GOSOUND.ELF pid='

# The second reporter: GOSOUND's own markers prove the launched app parsed
# and streamed the file the manager named.
vgate_assert wav serial-contains 'gosound: open id='
vgate_assert wav serial-contains 'gosound: loaded TONE.WAV fmt=pcm16 ch=2 rate=44100 frames=132300'
vgate_assert wav serial-contains 'gosound: out f32 rate=48000 ch=2 frames=144000'
vgate_assert wav serial-contains 'gosound: streaming gen='

# The overlap: the peer's own close-out asserts it saw exactly two live
# sources — its seat plus GOSOUND's.
vgate_assert wav serial-contains 'b7: peer accepted=65536 submitted=65536 completed=65536 sources=2'
vgate_assert wav serial-contains 'procs PCM.BIN exited status=0'

# No refusal of any kind may appear on the happy path.
vgate_assert wav serial-absent 'gosound: refused'
vgate_assert wav serial-absent 'gosound: no decoder'
vgate_assert wav serial-absent 'gosound: drain failed'
vgate_assert wav serial-absent 'gosound: stream err'
vgate_assert wav serial-absent 'gofiles: open refused'
vgate_assert wav serial-absent 'gofiles: open launch refused'
vgate_assert wav serial-absent 'b7: FAIL'
vgate_assert wav serial-absent '[EXC] parking'
vgate_assert wav serial-absent 'exited status=139'
vgate_assert wav serial-contains 'm99c-gate-done'

# The counter identity, recomputed from the fixture rather than pinned: the
# resampler's output frame count is ceil(in*48000/44100), the seat must
# report accepted == submitted == completed == frames * 8 B (FLOAT stereo),
# and the overlap must have raised the mixer's concurrent-source peak to 2.
vgate_assert wav python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
m = re.search(
    r"gosound: done accepted=(\d+) submitted=(\d+) completed=(\d+) "
    r"underruns=(\d+) peak=(\d+) clipped=(\d+)", ser)
if not m:
    sys.exit("ERROR: no gosound done marker in serial")
accepted, submitted, completed, underruns, peak, clipped = (
    int(g) for g in m.groups())

in_frames = 132300                      # 44.1 kHz stereo, 4 B frames
want_frames = -(-in_frames * 48000 // 44100)   # ceil — pipe.go OutFrames
want_bytes = want_frames * 8            # FLOAT/stereo
if want_frames != 144000:
    sys.exit(f"ERROR: fixture math changed: want_frames={want_frames}")
if not (accepted == submitted == completed == want_bytes):
    sys.exit(f"ERROR: counters accepted={accepted} submitted={submitted} "
             f"completed={completed}, want {want_bytes}")
if peak != 2:
    sys.exit(f"ERROR: peak={peak}, want 2 (the peer overlap)")
PY

# Soundless boot: same desktop (screen + input) but no --sound device. The
# file still parses, the window opens and says 'no audio device', and the
# process exits cleanly — documented, not a failure.
vgate_run wav-nodev -- \
    --screen '$RUN_DIR/gosound-screen-nodev' \
    --input --via-virtio \
    --script '$RUN_DIR/gosound-exec.txt' \
    --script-expect 'procs GOSOUND.ELF exited status=0' --timeout 120
vgate_assert wav-nodev serial-contains 'gosound: open id='
vgate_assert wav-nodev serial-contains 'gosound: loaded TONE.WAV fmt=pcm16 ch=2 rate=44100 frames=132300'
vgate_assert wav-nodev serial-contains 'gosound: no audio device'
vgate_assert wav-nodev serial-contains 'procs GOSOUND.ELF exited status=0'
vgate_assert wav-nodev serial-absent 'gosound: streaming'
vgate_assert wav-nodev serial-absent 'gosound: refused'
vgate_assert wav-nodev serial-absent '[EXC] parking'
