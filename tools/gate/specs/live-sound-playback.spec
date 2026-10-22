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

# ----------------------------------------------------------------------
# M162d (#2980) run wav-adpcm: a COMPRESSED wav on the same dispatch path.
# GOFILES opens ADPCM.WAV — a stereo IMA ADPCM file, the tag old games and
# recorders write — GOSOUND block-decodes it and windowed-sinc resamples
# 22050 -> 48000. The card's bar is the wav leg's own: the seat counters
# equal the exact post-resample byte count (the stream's evidence that
# real decoded samples, not silence or a stub, reached the device).
#
# Fixture: blockAlign 2048 -> samplesPerBlock 2041, 33 whole blocks =
# 67353 frames ~= 3.05 s; ch0 a 440 Hz sine, ch1 a 220 Hz one, amp 0.3.
vgate_setup_python <<'PY'
import math, os, struct

rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")

IMA_STEP = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
]
IMA_IDX = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

def ima_nibble(st, target):
    step = IMA_STEP[st["idx"]]
    diff = target - st["pred"]
    nib = 0
    if diff < 0:
        nib = 8
        diff = -diff
    if diff >= step:
        nib |= 4
        diff -= step
    if diff >= step >> 1:
        nib |= 2
        diff -= step >> 1
    if diff >= step >> 2:
        nib |= 1
    delta = step >> 3
    if nib & 4:
        delta += step
    if nib & 2:
        delta += step >> 1
    if nib & 1:
        delta += step >> 2
    st["pred"] += -delta if nib & 8 else delta
    st["pred"] = max(-32768, min(32767, st["pred"]))
    st["idx"] = max(0, min(88, st["idx"] + IMA_IDX[nib]))
    return nib

rate, ba, nblk = 22050, 2048, 33
spb = 1 + (ba - 8) // 8 * 8          # 2041
nfr = nblk * spb                      # 67353
# Per-channel source signals; blocks encode whole groups, no tail.
l = [int(0.3 * 32767 * math.sin(2 * math.pi * 440 * i / rate)) for i in range(nfr)]
r = [int(0.3 * 32767 * math.sin(2 * math.pi * 220 * i / rate)) for i in range(nfr)]

data = bytearray()
for b in range(nblk):
    base = b * spb
    data += struct.pack("<hBB", l[base], 0, 0)
    data += struct.pack("<hBB", r[base], 0, 0)
    st0, st1 = {"pred": l[base], "idx": 0}, {"pred": r[base], "idx": 0}
    for g in range(255):              # 255 groups x 8 samples per channel
        for c, st, smp in ((0, st0, l), (1, st1, r)):
            nib = [ima_nibble(st, smp[base + 1 + g * 8 + k]) for k in range(8)]
            for k in range(4):
                data.append(nib[2 * k] | (nib[2 * k + 1] << 4))

fmt_body = struct.pack("<HHIIHHH", 0x0011, 2, rate,
                       rate * ba // spb, ba, 4, 2) + struct.pack("<H", spb)
hdr = (b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt_body) + 8 + len(data)) +
       b"WAVE" + b"fmt " + struct.pack("<I", len(fmt_body)) + fmt_body +
       b"data" + struct.pack("<I", len(data)))
d = os.path.join(share, "SND3")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "ADPCM.WAV"), "wb") as f:
    f.write(hdr + data)
print("staged SND3/ADPCM.WAV (%d bytes, %d frames, %d blocks, spb=%d)" %
      (len(hdr) + len(data), nfr, nblk, spb))
PY

vgate_file adpcm-open.txt <<'EOF'
exec GOFILES.ELF /host/SND3
EOF

# The dispatch chain is the wav leg's: GOFILES' open picks GOSOUND for
# type=audio, the pipe decodes blocks through to `gosound: done`, and the
# run ends on that marker — no script supplies it, the program does.
vgate_run wav-adpcm -- --sound \
    --screen '$RUN_DIR/adpcm-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/adpcm-open.txt' \
    --input-chords 'return' \
    --input-chords-after 'gofiles: ready' \
    --script-expect 'gosound: done ' --timeout 240

vgate_assert wav-adpcm output-contains 'SOUND: virtio-snd attached'
vgate_assert wav-adpcm serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert wav-adpcm serial-contains 'gofiles: list /host/SND3 n=1'
vgate_assert wav-adpcm serial-contains 'gofiles: open file ADPCM.WAV type=audio handler=GOSOUND.ELF'
vgate_assert wav-adpcm serial-contains 'gofiles: open launched ADPCM.WAV handler=GOSOUND.ELF pid='

# GOSOUND's own markers: the file parsed as IMA ADPCM, the default
# resampler reported itself, and the stream went live.
vgate_assert wav-adpcm serial-contains 'gosound: open id='
vgate_assert wav-adpcm serial-contains 'gosound: loaded ADPCM.WAV fmt=ima-adpcm ch=2 rate=22050 frames=67353'
vgate_assert wav-adpcm serial-contains 'gosound: resampler=sinc'
vgate_assert wav-adpcm serial-contains 'gosound: streaming gen='

vgate_assert wav-adpcm serial-absent 'gosound: refused'
vgate_assert wav-adpcm serial-absent 'gosound: no decoder'
vgate_assert wav-adpcm serial-absent 'gosound: drain failed'
vgate_assert wav-adpcm serial-absent 'gosound: stream err'
vgate_assert wav-adpcm serial-absent 'b7: FAIL'
vgate_assert wav-adpcm serial-absent '[EXC] parking'
vgate_assert wav-adpcm serial-absent 'exited status=139'

# The counter identity, recomputed from the fixture like the wav leg:
# out frames = ceil(67353*48000/22050) = 146619, bytes = frames*8
# (FLOAT stereo), and no peer runs so the mixer's peak stays 1.
vgate_assert wav-adpcm python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
m = re.search(
    r"gosound: done accepted=(\d+) submitted=(\d+) completed=(\d+) "
    r"underruns=(\d+) peak=(\d+) clipped=(\d+)", ser)
if not m:
    sys.exit("ERROR: no gosound done marker in serial")
accepted, submitted, completed, underruns, peak, clipped = (
    int(g) for g in m.groups())

in_frames = 67353                       # 33 IMA blocks x 2041 samples
want_frames = -(-in_frames * 48000 // 22050)   # ceil — pipe.go OutFrames
want_bytes = want_frames * 8            # FLOAT/stereo
if want_frames != 146619:
    sys.exit(f"ERROR: fixture math changed: want_frames={want_frames}")
if not (accepted == submitted == completed == want_bytes):
    sys.exit(f"ERROR: counters accepted={accepted} submitted={submitted} "
             f"completed={completed}, want {want_bytes} — the decoded "
             f"stream did not reach the device whole")
if peak != 1:
    sys.exit(f"ERROR: peak={peak}, want 1 (no peer in this leg)")
PY

# ----------------------------------------------------------------------
# M99z (#2194) run wav-toast: the audio end-to-end. A real WAV streams from
# GOFILES's open-by-extension dispatch through GOSOUND while a kind-12
# notify toast — the M99d path, GOFILES's own copy completion — fires MID-
# STREAM and its chime mixes on a second source seat. The card's bar is
# that both streams' `completed` counters advance while they overlap: the
# chime's `played` line carries the kernel's own completed count, and
# GOSOUND's `done` line reports the mixer's PeakSources, which only reaches
# 2 if the chime was in the mix alongside it.
#
# The choreography is the go-wm-seat run 06 pattern: the seat is staged on
# the share but SETTINGS.TXT pins wm=none so nothing autostarts — the
# earlier runs in this spec then keep their seatless shim environment —
# and this run execs GOTABWM.ELF itself. `vf rm GOTABWM.DEMO` keeps the
# seat live (demo mode's single-tab countdown would close apps).
#
# SND2/LONG.WAV is a 60 s 44.1 kHz stereo sine — same resample path as
# TONE.WAV — so the toast has a wide drain window inside the stream.
#
# #2260 root cause (this leg used to flap), three coupled defects:
#  1. The seat's poll loop parked a full 1 Hz scheduler tick on every empty
#     poll AND after every consumed WM_KEY, so injected strokes (0.25 s/
#     stroke host-side) piled up — first in the cv input ring, then as
#     drop-oldest losses in the 16-deep process event queue when one
#     idle-turn pump burst overflowed it (the batch head — the alt-tab
#     focus move — is exactly what drop-oldest eats). The seat now blocks
#     on sys_wait_event (the kernel wakes event waiters on every push, so
#     keys drain at arrival rate) and yields after each key instead of
#     parking a tick; the event queue grew 16 -> 64, twice the pump's
#     per-pass bound.
#  2. RPC latency slips under the same load push the client's 8-tick ack
#     budget over: its token drops and retries go out unauthenticated —
#     but the seat bare-refused unauthed frames on a BOUND id forever
#     (observed: 'rpc refuse ... authed=0' repeating until teardown), so
#     the client's documented re-challenge recovery could never trigger.
#     gateRPC now re-challenges credential-less frames on a bound id and
#     lets a title-proven echo rebind (same proof bar as a first bind).
#  3. A client send that hit the momentarily-full 8-deep seat mailbox
#     returned ENOSPC -> instant `notify refused`; vi.wmSend now retries
#     ENOSPC a bounded 4 ticks.
# The toast chain below is the regression surface: every chord edge must
# reach the seat (the key-marker count assert), and the kind-12 post must
# paint + play inside the stream.
vgate_setup_python <<'PY'
import math, os, shutil, struct, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
# The seat: staged for run wav-toast only; SETTINGS.TXT below pins wm=none
# so the kernel never autostarts it and the earlier runs keep the shim.
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
# The toast source: a GOFILES copy completion posts the kind-12 notice.
# TWO paste cycles below give the post two independent chances — under a
# starved seat the WM_RPC ack races the 8-tick budget and a single post
# was observed refused with no delivery (2026-10-13). NOTIFY lists
# dirs-first as [SUB, SOURCE.XYZ] and SUB holds only the empty D1; the
# .XYZ extension has no mime handler, so a stray `return` on the source
# degrades to an "open refused" status, never an exec'd app mid-stream.
# The dance is DOWNWARD-ONLY on purpose: no goUp means no /host wander
# (observed 2026-10-13 when doubled 'h' left the batch in the share root
# and the second paste refused "exists" on a root file).
d = os.path.join(share, "NOTIFY")
os.makedirs(os.path.join(d, "SUB", "D1"), exist_ok=True)
with open(os.path.join(d, "SOURCE.XYZ"), "w") as f:
    f.write("copy me\n")
# The long stream: 60 s of 44.1 kHz stereo s16 sine, 2646000 frames.
d2 = os.path.join(share, "SND2")
os.makedirs(d2, exist_ok=True)
rate, frames = 44100, 2646000
data = bytearray()
for i in range(frames):
    v = int(0.2 * 32767 * math.sin(2 * math.pi * 440 * i / rate))
    data += struct.pack("<hh", v, v)
hdr = (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE" +
       b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16) +
       b"data" + struct.pack("<I", len(data)))
with open(os.path.join(d2, "LONG.WAV"), "wb") as f:
    f.write(hdr + data)
print("staged GOTABWM + NOTIFY + SND2/LONG.WAV (%d bytes, %d frames)" %
      (len(hdr) + len(data), frames))
PY

vgate_file script-seat.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

# GOFILES on NOTIFY execs FIRST so its seat handshake (declare/nav-declare)
# completes while the seat is idle — a second GOFILES exec'd mid-stream was
# observed to sit unbound until the stream ended, dropping the key batch on
# the floor (first attempt, 2026-10-12). Its tab is then index 0.
vgate_file script-notify.txt <<'EOF'
dui focus 0
set GOMAXPROCS=1
exec GOFILES.ELF /host/NOTIFY
EOF

# GOMAXPROCS=1 is pinned in every script: four runtimes (seat, two
# GOFILES, GOSOUND) at 3 tasks each stay inside the 13 EL0 slots — at the
# default of 2 the GOSOUND exec was observed to hit newosproc EAGAIN and
# die status=2 (2026-10-13).
vgate_file script-snd2.txt <<'EOF'
set GOMAXPROCS=1
exec GOFILES.ELF /host/SND2
EOF

# script2 opens the NOTIFY GOFILES once the seat's chime is armed; script3
# opens the SND2 one once the first is fully declared (a unique per-path
# marker — 'gofiles: ready' prints once per instance). The SND2 instance is
# focused on open, so a lone '\n' opens LONG.WAV -> GOSOUND (tab index 2).
# Mid-stream one alt-tab wraps focus index 2 -> 0 (positional cycle) back to
# the NOTIFY GOFILES, whose input path is long since live, then TWO
# copy+paste cycles post the kind-12 twice — one post was observed refused
# with no delivery under seat starvation (2026-10-13), so the evidence
# rides on either toast landing. Motion strokes are absolute + idempotent
# (end/home clamp); single-return drops are absorbed by cycle B's extra
# depth, and every wrong landing degrades to a refused paste or a refused
# .XYZ open, never an exec'd app:
#   cycle A: end,end -> SOURCE.XYZ; c,c copy; home,home -> SUB;
#            return cd in; p,p paste SOURCE.XYZ into SUB -> post 1
#   cycle B: home,home -> D1 (cwd is now SUB=[D1, SOURCE.XYZ]);
#            return,return cd D1 (empty, second no-ops); p,p paste
#            SOURCE.XYZ into D1 -> post 2
# If cycle A's lone return drops, the first p refuses "exists" in NOTIFY
# and cycle B cds SUB then D1 before pasting — still one clean post. A
# dropped alt-tab fails honestly: the keys land on the GOSOUND tab.
vgate_run wav-toast -- \
    --sound --screen '$RUN_DIR/toast-screen' --input --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-notify.txt' \
    --script2-after 'gotabwm: notify-sound ready' \
    --script3 '$RUN_DIR/script-snd2.txt' \
    --script3-after 'gofiles: nav declare /host/NOTIFY' \
    --input-string $'\n' --input-string-after 'gofiles: list /host/SND2' \
    --input-chords 'alt-tab,end,end,c,c,home,home,return,p,p,home,home,return,return,p,p' \
    --input-chords-after 'gosound: streaming gen=' \
    --script-expect 'gosound: done ' --timeout 240

# The seat came up with its chime path armed (a device exists under
# --sound), and the dispatch chain ran: list -> open -> GOSOUND streaming.
vgate_assert wav-toast serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert wav-toast serial-contains 'gotabwm: holding seat'
vgate_assert wav-toast serial-contains 'gotabwm: notify-sound ready bytes='
vgate_assert wav-toast serial-contains 'gofiles: list /host/SND2'
vgate_assert wav-toast serial-contains 'gofiles: open launched LONG.WAV handler=GOSOUND.ELF'
vgate_assert wav-toast serial-contains 'gosound: open id='
vgate_assert wav-toast serial-contains 'gosound: loaded LONG.WAV fmt=pcm16 ch=2 rate=44100 frames=2646000'
vgate_assert wav-toast serial-contains 'gosound: streaming gen='

# The toast's half: the mid-stream GOFILES copied, the seat accepted the
# kind-12, painted it, and drained the chime — the kernel's completed count
# is on the played line. NOTE the app-side `gofiles: notify sent|refused`
# marker is NOT asserted either way: vi.Notify's bool is a post-time
# verdict, not a delivered verdict — observed 2026-10-13 it printed
# `refused` while the seat still painted id=3 and played the chime. The
# seat-side lines below are the authoritative toast evidence.
vgate_assert wav-toast serial-contains 'gofiles: list /host/NOTIFY'
vgate_assert wav-toast serial-contains 'gofiles: pasted SOURCE'
vgate_assert wav-toast serial-contains 'gotabwm: notify id='
vgate_assert wav-toast serial-contains 'gotabwm: notify paint id='
vgate_assert wav-toast serial-contains 'gotabwm: notify-sound played bytes='
vgate_assert wav-toast serial-contains 'gosound: done '
# #2260 drop detector: the 16 injected chords each produce exactly one
# WM_KEY edge, and the seat prints 'gotabwm: key' for every edge it
# consumes. A seat-queue overflow drops the head of the batch — the count
# falls below 16 and this fails even when a toast still lands via cycle B.
vgate_assert wav-toast python <<'PY'
import os, sys
n = open(os.environ["VG_SER"]).read().count("gotabwm: key")
if n < 16:
    sys.exit(f"ERROR: seat consumed {n} key edges, want >= 16 — "
             f"event-queue drop under PCM load")
PY
# 'gofiles: open refused' and 'gofiles: open launch refused' are
# deliberately NOT absent-asserted: the doubled-stroke design tolerates
# drops AND doubles — a stray return on a .XYZ source prints `open
# refused`, and a doubly-landed 'h' can wander the batch to a share-root
# file whose handler is not staged (`open launch refused ... ENOENT`),
# both observed safe (2026-10-13: toast+chime still landed via the other
# cycle).
vgate_assert wav-toast serial-absent 'gotabwm: notify-sound skipped'
vgate_assert wav-toast serial-absent 'gosound: refused'
vgate_assert wav-toast serial-absent 'gosound: drain failed'
vgate_assert wav-toast serial-absent '[EXC] parking'
vgate_assert wav-toast serial-absent 'exited status=139'

# The card's counter evidence, all recomputed: the chime's played bytes
# equal its kernel-completed count, it landed while the stream was live
# (the played marker precedes gosound's done), the wav stream drained
# every resampled byte (accepted == submitted == completed == 1764000
# frames resampled to 1920000 * 8 B FLOAT stereo), and the mixer's
# PeakSources reached 2 — the two streams really were concurrent.
vgate_assert wav-toast python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
pm = re.search(r"gotabwm: notify-sound played bytes=(\d+) completed=(\d+)", ser)
if not pm:
    sys.exit("ERROR: no notify-sound played marker")
played_bytes, played_done = int(pm.group(1)), int(pm.group(2))
if played_bytes <= 0 or played_done < played_bytes:
    sys.exit(f"ERROR: chime counters bytes={played_bytes} "
             f"completed={played_done}")
dm = re.search(
    r"gosound: done accepted=(\d+) submitted=(\d+) completed=(\d+) "
    r"underruns=(\d+) peak=(\d+) clipped=(\d+)", ser)
if not dm:
    sys.exit("ERROR: no gosound done marker")
accepted, submitted, completed, underruns, peak, clipped = (
    int(g) for g in dm.groups())
in_frames = 2646000
want_frames = -(-in_frames * 48000 // 44100)
want_bytes = want_frames * 8
if want_frames != 2880000:
    sys.exit(f"ERROR: fixture math changed: want_frames={want_frames}")
if not (accepted == submitted == completed == want_bytes):
    sys.exit(f"ERROR: counters accepted={accepted} submitted={submitted} "
             f"completed={completed}, want {want_bytes}")
if peak != 2:
    sys.exit(f"ERROR: peak={peak}, want 2 (the chime overlap)")
if not (0 <= pm.start() < dm.start()):
    sys.exit("ERROR: chime played marker did not precede gosound done")
print(f"toast-overlap ok: chime {played_done} B completed, "
      f"stream {completed} B completed, peak={peak}")
PY
