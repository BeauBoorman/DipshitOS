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
#
# Runs 06-07 are M120c's (#2560): the Machine-menu persistence verbs.
# Run 01 additionally fires all five on a posture-less flag run — every
# one receipts `disabled` (no profile, no share, nothing staged), the
# enablement half of the card. Run 06 boots a minted .virelaivm on a
# save-capable device set (devices.share off; the share rides
# --virtio-fs — the standard transport validateSaveRestoreSupport
# accepts, the custom-virtio --cvc-file being what it refuses):
# `snapshot` performs FOR REAL (a menu-<stamp>.vzsave lands under
# <share>/SNAPSHOTS/), `reveal-share` performs, and `apply-update`/
# `rollback-update` still receipt `disabled` — the posture is read at
# dispatch, not at arm. Run 07 fires `suspend` on the same posture: the
# guest's own M115d SuspendCtl freezes, saves saved-state/state.vzsave
# and the run ends through the suspended-teardown path.
#
# Run 08 is M120e's (#2562): the failure-surfaces leg. The guest's own
# `shutdown` monitor verb (EFI ResetSystem — the live-reboot shutdown
# leg's proven mechanism) powers the VM off mid-run; the poll's
# early-stop path notes the postmortem, the drawer model opens on its
# own, and the `host-inspector: postmortem … open=1` line is the receipt.
# The armed --virtio-fs share routes the screenshot verb's PNG into
# <share>/CAPTURES/ — ⌘⇧5's destination — and the dispatch's
# saved=/file= tail is the saved-badge truth a window would mirror.
#
# Run 01 also fires M122d's (#2573) `shortcuts` verb — the ⌘/
# cheat-sheet companion self-registers on the bus, so the scripted run
# receipts the open flip and the chord-row count generated from the
# menu's command table.
#
# M114f (#2459) acceptance: taken together the five runs are the
# full-window journey — bus dispatch (screenshot, clean stop), the
# viewport verbs (fullscreen, capture-keys on/off, the
# --host-capture-keys arming flag), the inspector's send-serial
# injection, and the one-chord capture pair. The same bus's lane
# suspend/resume leg lives in live-hostint run 04 (M114c, #2456).

vgate_name live-host-ui "M114a #2454 + M114b #2455 + M114d #2457 + M114e #2458 + M120e #2562 + M122d #2573: HostCommand bus — --host-cmd-after/--host-capture-keys/--host-serial-send, host-ui: receipts, one-chord capture, postmortem auto-open + CAPTURES routing + shortcuts cheat-sheet"
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
# marker races ahead of record-start). Runs 06-07 mint their
# .virelaivm here too — devices.share stays OFF so the share rides
# --virtio-fs (the save-capable posture live-suspend-resume pinned;
# --cvc-file's custom-virtio device is what save/restore refuses).
vgate_setup_python <<'PY'
import json, os, shutil, subprocess, sys
os.makedirs(os.path.join(os.environ["RUN_DIR"], "capshare", "CAPTURES"), exist_ok=True)
# Run 08's share root only — CAPTURES itself must NOT preexist: the
# screenshot verb creates it on write, which is part of the evidence.
os.makedirs(os.path.join(os.environ["RUN_DIR"], "capshare8"), exist_ok=True)

run = os.environ["RUN_DIR"]
runner = os.path.join("host", "vm-runner", ".build", "release", "VMRunner")
prof = os.path.join(run, "m120c.virelaivm")
r = subprocess.run([runner, "--profile", prof, "--profile-init"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("m120c profile mint refused: " + r.stdout + r.stderr)
base = os.path.join(run, "m120c-base.img")
shutil.copy(os.path.join("artifacts", "disk.img"), base)
cfg_path = os.path.join(prof, "config.json")
cfg = json.load(open(cfg_path))
cfg["baseImage"] = base            # --overlay-base wins anyway; keeps the bundle coherent
cfg.setdefault("devices", {})["share"] = False
json.dump(cfg, open(cfg_path, "w"), indent=2, sort_keys=True)
print("m120c profile minted; private base copy staged; devices.share=false")
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:screenshot' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:fullscreen' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:capture-keys' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:capture-keys' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:send-file' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:suspend' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:snapshot' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:apply-update' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:rollback-update' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:reveal-share' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:shortcuts' \
    --script-expect 'host-ui-idle' --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 output-contains 'host-ui: cmd=screenshot state=performed'
vgate_assert 01 output-contains 'host-ui: cmd=fullscreen state=performed'
vgate_assert 01 output-contains 'host-ui: cmd=capture-keys state=performed capture=on'
vgate_assert 01 output-contains 'host-ui: cmd=capture-keys state=performed capture=off'
vgate_assert 01 output-contains 'host-ui: cmd=send-file state=unavailable'
# M120c (#2560): on a posture-less flag run every lifecycle verb is
# disabled — no saved-state dir (no profile), no share, nothing staged,
# no .prev. Enablement is the receipt, not silence.
vgate_assert 01 output-contains 'host-ui: cmd=suspend state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=snapshot state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=apply-update state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=rollback-update state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=reveal-share state=disabled'
# M122d (#2573): the ⌘/ cheat-sheet verb is a self-registered companion
# — always armed, so its receipt carries the open flip and the row
# count generated from the menu's command table.
vgate_assert 01 output-contains 'host-ui: cmd=shortcuts state=performed open=1 chords=8'
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

# Run 06 is M120c's (#2560) armed-posture leg: the .virelaivm the setup
# minted, the share riding --virtio-fs (the save-capable transport).
# `snapshot` performs FOR REAL — the same SnapshotCtl the ctl wire
# serves freezes the VM and writes SNAPSHOTS/menu-<stamp>.vzsave — and
# `reveal-share` performs (the armed share resolves from argv).
# `apply-update`/`rollback-update` still receipt disabled: nothing is
# staged, no .prev exists — enablement is live posture, not arm-time
# truth. The 'virelai> ' marker fires the verbs on a seated guest, well
# ahead of the script's 'host-ui-idle' echo.
vgate_run 06 -- --profile '$RUN_DIR/m120c.virelaivm' \
    --overlay-base '$RUN_DIR/m120c-base.img' \
    --virtio-fs '$RUN_DIR/m120c.virelaivm/share' \
    --script '$RUN_DIR/script.txt' \
    --host-cmd-after 'virelai> :snapshot' \
    --host-cmd-after 'virelai> :apply-update' \
    --host-cmd-after 'virelai> :rollback-update' \
    --host-cmd-after 'virelai> :reveal-share' \
    --script-expect 'host-ui-idle' --timeout 120

vgate_assert 06 output-contains 'host-ui: cmd=snapshot state=performed'
vgate_assert 06 output-contains 'host-ui: cmd=reveal-share state=performed'
vgate_assert 06 output-contains 'host-ui: cmd=apply-update state=disabled'
vgate_assert 06 output-contains 'host-ui: cmd=rollback-update state=disabled'
# The performed snapshot is a file, not a receipt word — a
# menu-<stamp>.vzsave under the armed share's SNAPSHOTS/, non-empty.
vgate_assert 06 python <<'PY'
import glob, os, sys
snaps = glob.glob(os.path.join(
    os.environ["RUN_DIR"], "m120c.virelaivm", "share",
    "SNAPSHOTS", "menu-*.vzsave"))
if not snaps:
    sys.exit("no menu-*.vzsave under the armed share's SNAPSHOTS/")
sizes = {os.path.basename(p): os.path.getsize(p) for p in snaps}
if any(s == 0 for s in sizes.values()):
    sys.exit("empty snapshot file: %r" % sizes)
print("bus snapshot landed: %s" % sizes)
PY

# Run 07 is the suspend leg: same posture, the `suspend` verb drives the
# M115d SuspendCtl — pause, save into the profile's saved-state/, then
# the suspended-teardown ends the run (the script-expect is the
# deliberately-unreached marker; the receipt + the state file are the
# evidence).
vgate_run 07 -- --profile '$RUN_DIR/m120c.virelaivm' \
    --overlay-base '$RUN_DIR/m120c-base.img' \
    --virtio-fs '$RUN_DIR/m120c.virelaivm/share' \
    --script '$RUN_DIR/script.txt' \
    --host-cmd-after 'virelai> :suspend' \
    --script-expect 'host-ui-idle' --timeout 120

vgate_assert 07 output-contains 'host-ui: cmd=suspend state=performed'
vgate_assert 07 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert 07 python <<'PY'
import os, sys
state = os.path.join(os.environ["RUN_DIR"], "m120c.virelaivm",
                     "saved-state", "state.vzsave")
if not os.path.isfile(state) or os.path.getsize(state) == 0:
    sys.exit("suspend left no non-empty saved-state/state.vzsave")
print("suspended state saved: %d bytes" % os.path.getsize(state))
PY

# Run 08 is M120e's (#2562) forced-failure leg: `shutdown` in the script
# powers the VM off through EFI ResetSystem (live-reboot's mechanism) —
# the early-stop path's noteStop opens the drawer model and emits the
# `host-inspector: postmortem … open=1` receipt, and the armed
# --virtio-fs share routes the screenshot verb's PNG into
# <share>/CAPTURES/ (the verb creates the dir — setup only mints the
# share root). The screenshot trigger anchors on the boot banner so the
# capture provably lands BEFORE the shutdown lands; the expected marker
# never arrives, so the run ends on the VM's own death (rc 1).
# warm-cold: 08 (b) the leg exercises guest power-off semantics, not restore.

vgate_file script-fail.txt <<'EOF'
shutdown
EOF

vgate_run 08 -- --screen '$RUN_DIR/screen8' --virtio-fs '$RUN_DIR/capshare8' \
    --script '$RUN_DIR/script-fail.txt' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:screenshot' \
    --script-expect '__M120E_NEVER__' --timeout 90
vgate_allow_rc 08 1

vgate_assert 08 serial-echo shutdown
vgate_assert 08 output-contains 'host-ui: cmd=screenshot state=performed saved=1 file=screen8-hostui-1.png'
vgate_assert 08 output-contains 'host-cap: saved '
vgate_assert 08 output-contains 'host-inspector: postmortem ending=stopped'
vgate_assert 08 output-contains 'open=1'
vgate_assert 08 output-contains 'VM ended before the expected transcript'
# The screenshot landed in CAPTURES and nowhere else — the routing, not
# just the write.
vgate_assert 08 snapshot 'capshare8/CAPTURES/screen8-hostui-*' <<'PY'
import os, sys
p = sys.argv[1]
with open(p, "rb") as f:
    head = f.read(8)
if head != b"\x89PNG\r\n\x1a\n":
    sys.exit("CAPTURES screenshot is not a PNG: %r" % head)
if os.path.getsize(p) == 0:
    sys.exit("CAPTURES screenshot is empty")
print("⌘⇧5 landed in CAPTURES: %s (%d bytes)" % (p, os.path.getsize(p)))
PY
vgate_assert 08 python <<'PY'
import glob, os, shutil, sys
run = os.environ["RUN_DIR"]
if glob.glob(os.path.join(run, "screen8-hostui-*")):
    sys.exit("screenshot leaked outside CAPTURES into the run dir")
# Lift the capture like run 05 does — the teardown's keep-file copy
# reads $RUN_DIR/<basename>, and the share dies with the temp dir.
caps = glob.glob(os.path.join(run, "capshare8", "CAPTURES", "*"))
for f in caps:
    shutil.copy(f, os.path.join(run, os.path.basename(f)))
print("no run-dir leak; lifted %d CAPTURES file(s)" % len(caps))
PY
