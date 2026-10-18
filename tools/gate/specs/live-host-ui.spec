# live-host-ui.spec -- M114a (#2454) + M114b (#2455, index #2447): the
# HostCommand action bus's headless mirror. `--host-cmd-after <marker>:<verb>`
# dispatches a menu verb through the same bus the AppKit menu items dispatch
# on, once the marker appears in the serial stream — the window is never
# driven by synthesized clicks (index thesis 1); the bus is the testable
# seam. Every dispatch writes one `host-ui: cmd=<verb> state=<...>` receipt
# on runner stdout; a toggle verb appends its live post-action state
# (`capture=on|off`) to the receipt.
#
# Run 01 fires `screenshot` — the same --screen framebuffer capture
# --screenshot-after uses — plus the M114b viewport verbs: `fullscreen`
# (now wired; performed on the run's evidence window) and `capture-keys`
# twice, so the toggle's receipts prove the capturesSystemKeys property
# itself changed (on then off), not just that the action ran. `send-file`
# stays unavailable until M114c wires it. The PNG the screenshot wrote is
# held to a PNG signature.
#
# Run 02 fires `stop`: the performed receipt and the run's own early end
# (rc 1 — the VM really stopped before the transcript appeared) prove the
# verb acted, not just reported.
#
# Run 03 arms `--host-capture-keys`: the flag rides the same bus — its
# startup dispatch emits the identical `capture=on` receipt a trigger,
# Cmd+Opt+K or the toolbar pill would, then a --host-cmd-after trigger
# toggles capture back off.
#
# Run 04 is M114d's (#2457): send-serial injects the --host-serial-send
# line into the console pipe and the inspector verb's receipt reports
# the drawer model saw the echo (saw=1).
#
# Run 05 is M114e's (#2458): the one-chord capture pair. `screenshot`
# (the M114a verb, unchanged) plus a bounded record-start/record-stop
# through the bus: `cap-start` arms record-start AND script2's forward,
# so `echo cap-stop` lands ~2 s later and stops the take. The run arms
# its own share via --virtio-fs (the plain-build share — --cvc-file is
# SPIKE-only, and vgate_share is spec-global so arming it here would
# change the device shape of runs 01-04), and the recorder writes
# <share>/CAPTURES/ resolved from that same argv. The stop receipt's
# frames=/bytes= are the writer's actuals; the asserts hold the PNG to
# a signature and the MP4 to a real ftyp+moov.

vgate_name live-host-ui "M114a #2454 + M114b #2455 + M114d #2457 + M114e #2458: HostCommand bus — --host-cmd-after/--host-capture-keys/--host-serial-send, host-ui: receipts, one-chord capture"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
echo host-ui-idle
EOF

vgate_file script-cap.txt <<'EOF'
echo cap-start
EOF

vgate_file script-cap2.txt <<'EOF'
echo cap-stop
EOF

# Run 05's share + CAPTURES dir must exist before the runner validates
# --virtio-fs and before the screenshot verb writes into it (the boot
# marker races ahead of record-start).
vgate_setup_python <<'PY'
import os
os.makedirs(os.path.join(os.environ["RUN_DIR"], "capshare", "CAPTURES"), exist_ok=True)
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:screenshot' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:fullscreen' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:capture-keys' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:capture-keys' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:send-file' \
    --script-expect 'host-ui-idle' --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 output-contains 'host-ui: cmd=screenshot state=performed'
vgate_assert 01 output-contains 'host-ui: cmd=fullscreen state=performed'
vgate_assert 01 output-contains 'host-ui: cmd=capture-keys state=performed capture=on'
vgate_assert 01 output-contains 'host-ui: cmd=capture-keys state=performed capture=off'
vgate_assert 01 output-contains 'host-ui: cmd=send-file state=unavailable'
vgate_assert 01 output-contains 'framebuffer screenshot saved'
vgate_assert 01 snapshot 'screen-hostui-*' <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    magic = f.read(8)
if magic != b"\x89PNG\r\n\x1a\n":
    sys.exit("newest host-ui screenshot is not a PNG: %r" % magic)
print("host-ui screenshot is a PNG: %s" % sys.argv[1])
PY

vgate_run 02 -- --script '$RUN_DIR/script.txt' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:stop' \
    --script-expect 'host-ui-idle' --timeout 90
vgate_allow_rc 02 1

vgate_assert 02 output-contains 'host-ui: cmd=stop state=performed'
vgate_assert 02 output-contains 'VM ended before the expected transcript'

vgate_run 03 -- --screen '$RUN_DIR/screen3' --script '$RUN_DIR/script.txt' \
    --host-capture-keys \
    --host-cmd-after 'VirelaiOS kernel has seized control.:capture-keys' \
    --script-expect 'host-ui-idle' --timeout 90

vgate_assert 03 output-contains 'host-capture-keys: ENABLED'
vgate_assert 03 output-contains 'host-ui: cmd=capture-keys state=performed capture=on'
vgate_assert 03 output-contains 'host-ui: cmd=capture-keys state=performed capture=off'

# Run 04 is M114d's (#2457): the send-serial verb writes the armed
# --host-serial-send line into the console pipe — the same path --script
# forwards through — and the drawer's ring buffer, fed from the same
# serial text, reports it saw the echo. `send-serial` fires on the boot
# marker and receipts `sent=1` from the model's own counter; the guest's
# shell echoes the line back over serial (gosh's `line` record wraps the
# command), and the second trigger fires `inspector` on that echo — its
# receipt's `saw=1` is the drawer model testifying it ingested the
# injected line, not just that a dispatch happened.

vgate_run 04 -- --script '$RUN_DIR/script.txt' \
    --host-serial-send 'echo inspector-ping' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:send-serial' \
    --host-cmd-after 'inspector-ping:inspector' \
    --script-expect 'host-ui-idle' --timeout 90

vgate_assert 04 output-contains 'host-ui: cmd=send-serial state=performed sent=1'
vgate_assert 04 serial-contains 'inspector-ping'
vgate_assert 04 output-contains 'host-ui: cmd=inspector state=performed open=1'
vgate_assert 04 output-contains 'saw=1'

# Run 05: the M114e capture leg. `cap-start` both fires record-start on
# the bus and releases script2 (`echo cap-stop`) after a 2 s settle, so
# record-stop lands ~2 s later — a real take, not a same-tick open/close.
# --screen's base lands the screenshot PNG inside CAPTURES too, so the
# leg's whole evidence set lives under <share>/CAPTURES/ as the card
# names it (the `rec` prefix keeps its basename off run 01's
# `screen-hostui-*` — the teardown's keep-file copy is basename-keyed).
vgate_run 05 -- --screen '$RUN_DIR/capshare/CAPTURES/rec' \
    --virtio-fs '$RUN_DIR/capshare' \
    --script '$RUN_DIR/script-cap.txt' \
    --script2 '$RUN_DIR/script-cap2.txt' --script2-after 'cap-start' --script2-delay 2 \
    --host-cmd-after 'VirelaiOS kernel has seized control.:screenshot' \
    --host-cmd-after 'cap-start:record-start' \
    --host-cmd-after 'cap-stop:record-stop' \
    --script-expect 'cap-stop' --timeout 90

vgate_assert 05 output-contains 'host-ui: cmd=screenshot state=performed'
vgate_assert 05 output-contains 'host-ui: cmd=record-start state=performed recording=on'
vgate_assert 05 output-contains 'host-ui: cmd=record-stop state=performed recording=off frames='
# The receipt's frames=/bytes= are the writer's actuals — a gate that
# only read "performed" would pass on a zero-byte MP4.
vgate_assert 05 python <<'PY'
import os, re
out = open(os.path.join(os.environ["RUN_DIR"], "run-05.out"), "rb").read().decode("utf-8", "replace")
m = re.search(r"host-ui: cmd=record-stop state=performed recording=off frames=(\d+) bytes=(\d+)", out)
if not m:
    raise SystemExit("record-stop receipt with frames=/bytes= not found in runner output")
frames, size = int(m.group(1)), int(m.group(2))
if frames < 1:
    raise SystemExit("record-stop receipt frames=%d — expected >=1 appended frame" % frames)
if size < 1:
    raise SystemExit("record-stop receipt bytes=%d — expected a non-empty MP4" % size)
print("record-stop receipt: frames=%d bytes=%d" % (frames, size))
PY
# The teardown's keep-file copy reads $RUN_DIR/<basename> — the CAPTURES
# files are nested under capshare/, so lift them to the run dir root or
# the evidence disappears with the temp dir (SPEC.md: a spec that reads
# the share with python does its own copy).
vgate_assert 05 python <<'PY'
import glob, os, shutil, sys
run = os.environ["RUN_DIR"]
files = glob.glob(os.path.join(run, "capshare", "CAPTURES", "*"))
if not files:
    sys.exit("CAPTURES is empty — no capture evidence landed")
for f in files:
    shutil.copy(f, os.path.join(run, os.path.basename(f)))
print("lifted %d CAPTURES file(s) to the run dir: %s" %
      (len(files), ", ".join(sorted(os.path.basename(f) for f in files))))
PY
vgate_assert 05 snapshot 'capshare/CAPTURES/rec-hostui-*' <<'PY'
import os, sys
p = sys.argv[1]
with open(p, "rb") as f:
    head = f.read(8)
if head != b"\x89PNG\r\n\x1a\n":
    sys.exit("host-ui screenshot in CAPTURES is not a PNG: %r" % head)
if os.path.getsize(p) == 0:
    sys.exit("host-ui screenshot in CAPTURES is empty")
print("CAPTURES screenshot is a non-empty PNG: %s (%d bytes)" % (p, os.path.getsize(p)))
PY
vgate_assert 05 snapshot 'capshare/CAPTURES/capture-*.mp4' <<'PY'
import os, sys
p = sys.argv[1]
data = open(p, "rb").read()
if len(data) < 12 or data[4:8] != b"ftyp":
    sys.exit("CAPTURES recording has no valid MP4 ftyp header: %r" % data[:12])
if b"moov" not in data:
    sys.exit("CAPTURES recording has no moov box — the writer never finalized (%d bytes)" % len(data))
print("CAPTURES recording is a finalized MP4: %s (%d bytes)" % (p, len(data)))
PY
