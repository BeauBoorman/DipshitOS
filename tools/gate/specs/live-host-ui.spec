# live-host-ui.spec -- M114a (#2454) + M114b (#2455, index #2447): the
# HostCommand action bus's headless mirror. `--host-cmd-after <marker>:<verb>`
# dispatches a menu verb through the same bus the AppKit menu items dispatch
# on, once the marker appears in the serial stream — the window is never
# driven by synthesized clicks (index thesis 1); the bus is the testable
# seam. Every dispatch writes one `host-ui: cmd=<verb> vm=<n> state=<...>`
# receipt on runner stdout — `vm=<n>` names the session the verb landed on
# (M139a #2779); a toggle verb appends its live post-action state
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
#
# Run 10 is M139e's (#2783) acceptance journey: one runner process, two
# profiles — vm 1 (j1) rides --net + a staged agentd share and an
# agentctl 'input' session types into the focused GOEDIT pane then
# re-shoots the framebuffer (the M139b verb pair end to end), while
# vm 2 (ws2, opened by the new-window verb on vm 1's own bus) suspends
# on ITS bus and its serial shows no agent effect. Both sessions end on
# their own receipts — vm=2 suspend+stopped, vm=1 stop. REPEAT
# SEMANTICS: vgate_repeat 3 is the card's K=3 — every leg re-runs, so
# each iteration is one full journey; python asserts read their own
# run's out file via VG_TAG and profile state surviving an iteration
# (saved-state, snapshots, audit receipts) is overwritten, never
# accumulated-into, on the next.
#
# HOST PREREQ (run 10 only — the journey's staged share):
#   bash tools/go/build-agentd.sh  -> .build/go/AGENTD.ELF
#   bash tools/go/build-gotabwm.sh -> .build/go/GOTABWM.ELF
#   bash tools/go/build-goedit.sh  -> .build/go/GOEDIT.ELF
#
# Run 11 is M157a's (#2934): per-VM window identity + the close policy.
# The primary boots m120c's bundle — its `window` line names the
# profile; cv2's bundle carries closeAction=suspend on the virtio-fs
# set, so the `vm2:`-bound `close@vm=2` on vm 2's own prompt runs the
# save path: state.vzsave lands and the sibling stops while the primary
# runs on to its own expect.
#
# Run 12 is M157e's (#2938) acceptance: the arc's surfaces in one
# journey. The m120c primary plus a dedicated tr2 sibling both receipt
# their profile titles; --host-serial-send arms `strace exec
# HELLO.ELF` — the live-strace form, with the mkhello fixture staged on
# the primary's share — and the send-serial verb injects it on vm 1's
# first prompt so the tracer rows the HostTracer ring parses off the
# same serial feed precede the inspector verb's flip, whose
# `host-inspector: trace rows=<n>` receipt must name n > 0. tr2 carries
# closeAction=suspend like cv2, so `close@vm=2` on vm 2's own prompt
# saves (or names the Code=2 refusal) while the primary runs on.

vgate_name live-host-ui "M114a #2454 + M114b #2455 + M114d #2457 + M114e #2458 + M120e #2562 + M122d #2573 + M139a #2779 + M139e #2783: HostCommand bus — host-ui: receipts, one-chord capture, postmortem, multi-VM + agent ui.input journey K=3"
vgate_repeat 3 BOOTS

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

# Run 09's second machine (M139a #2779): ws2 gets its own bundle + base
# copy — the session attaches <bundle>/share over virtio-fs itself.
ws2 = os.path.join(run, "ws2.virelaivm")
r = subprocess.run([runner, "--profile", ws2, "--profile-init"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("ws2 profile mint refused: " + r.stdout + r.stderr)
ws2base = os.path.join(run, "ws2-base.img")
shutil.copy(os.path.join("artifacts", "disk.img"), ws2base)
cfg2 = json.load(open(os.path.join(ws2, "config.json")))
cfg2["baseImage"] = ws2base
json.dump(cfg2, open(os.path.join(ws2, "config.json"), "w"), indent=2, sort_keys=True)
os.makedirs(os.path.join(ws2, "share"), exist_ok=True)
print("ws2 profile minted; private base copy staged")

# Run 10's first machine (M139e #2783): j1's bundle is minted like
# m120c's, then its share is staged with the M109/M139b agentd posture —
# the ELFs, the devin keyring declaring `input`, the agent-hmac receipt
# key, the audit lane, and wm=none so the seat is exec'd on script (the
# go-agentd run-15 choreography, on a save-capable virtio-fs share
# instead of the SPIKE cvc device). One honest difference: the
# agent-hmac row is uid-scoped, NOT app-bound — `OWNERS.TXT` populates
# the trust table only at the queue-5 (custom-virtio) arming point, so
# under virtio-fs `system_owned_key` can never hold and an app-bound
# secret refuses `no-credential` (observed). The key file the agentctl
# stream reads lands at $RUN_DIR/devin.key (never argv).
j1 = os.path.join(run, "j1.virelaivm")
r = subprocess.run([runner, "--profile", j1, "--profile-init"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("j1 profile mint refused: " + r.stdout + r.stderr)
j1base = os.path.join(run, "j1-base.img")
shutil.copy(os.path.join("artifacts", "disk.img"), j1base)
cfg3 = json.load(open(os.path.join(j1, "config.json")))
cfg3["baseImage"] = j1base
cfg3.setdefault("devices", {})["share"] = False
json.dump(cfg3, open(os.path.join(j1, "config.json"), "w"), indent=2, sort_keys=True)

sys.path.insert(0, os.path.join("tools", "agentctl"))
import agentctl
j1share = os.path.join(j1, "share")
os.makedirs(j1share, exist_ok=True)
for name, cmd in (
    ("AGENTD.ELF", "bash tools/go/build-agentd.sh"),
    ("GOTABWM.ELF", "bash tools/go/build-gotabwm.sh"),
    ("GOEDIT.ELF", "bash tools/go/build-goedit.sh"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") — build it first: " + cmd)
    shutil.copy(src, os.path.join(j1share, name))
open(os.path.join(j1share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
devin_pub = agentctl.ed_public_key(bytes.fromhex("0a" * 32)).hex()
open(os.path.join(j1share, "AGENTS.TXT"), "w").write(
    "#v1\nagent=devin key=%s caps=file,process,window,term,input\n" % devin_pub)
open(os.path.join(j1share, "SECRETS.TXT"), "w").write(
    "#v1\nagent-hmac\t2000\t" + "a5" * 32 + "\nagent-hmac\t1000\t" + "a5" * 32 + "\n")
open(os.path.join(j1share, "OWNERS.TXT"), "w").write(
    "#v1\nAGENTD.ELF\t644\t0\t-\nAGENTS.TXT\t444\t0\t-\n")
os.makedirs(os.path.join(j1share, "AGENT", "AUDIT"), exist_ok=True)
ed = os.path.join(j1share, "EDIT")
os.makedirs(ed, exist_ok=True)
open(os.path.join(ed, "SEED.TXT"), "wb").write(b"seed-line\n")
open(os.path.join(run, "devin.key"), "w").write("devin " + "0a" * 32 + "\n")
print("j1 profile minted; agentd share staged (seat exec'd on script)")

# Run 11's second machine (M157a #2934): cv2 carries closeAction=suspend
# on the virtio-fs device set (devices.share stays ON — the session
# attaches <bundle>/share itself, save-capable like ws2's set) so the
# close verb's suspend leg writes saved-state/state.vzsave.
cv2 = os.path.join(run, "cv2.virelaivm")
r = subprocess.run([runner, "--profile", cv2, "--profile-init"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("cv2 profile mint refused: " + r.stdout + r.stderr)
cv2base = os.path.join(run, "cv2-base.img")
shutil.copy(os.path.join("artifacts", "disk.img"), cv2base)
cfgcv = json.load(open(os.path.join(cv2, "config.json")))
cfgcv["baseImage"] = cv2base
cfgcv["closeAction"] = "suspend"
json.dump(cfgcv, open(os.path.join(cv2, "config.json"), "w"), indent=2, sort_keys=True)
os.makedirs(os.path.join(cv2, "share"), exist_ok=True)
print("cv2 profile minted; closeAction=suspend")

# Run 12's sibling (M157e #2938): tr2 carries closeAction=suspend on the
# same device set as cv2 — a dedicated bundle, so the close leg's
# saved-state is this run's own evidence, never a file run 11's close
# may have left.
tr2 = os.path.join(run, "tr2.virelaivm")
r = subprocess.run([runner, "--profile", tr2, "--profile-init"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("tr2 profile mint refused: " + r.stdout + r.stderr)
tr2base = os.path.join(run, "tr2-base.img")
shutil.copy(os.path.join("artifacts", "disk.img"), tr2base)
cfgt = json.load(open(os.path.join(tr2, "config.json")))
cfgt["baseImage"] = tr2base
cfgt["closeAction"] = "suspend"
json.dump(cfgt, open(os.path.join(tr2, "config.json"), "w"), indent=2, sort_keys=True)
os.makedirs(os.path.join(tr2, "share"), exist_ok=True)
print("tr2 profile minted; closeAction=suspend")

# Run 12's tracer leg: `strace exec HELLO.ELF` resolves through the
# host-file channel, so the mkhello fixture lands on the primary's
# share — the same file the seeded shares carry.
m120c_share = os.path.join(run, "m120c.virelaivm", "share")
os.makedirs(m120c_share, exist_ok=True)
r = subprocess.run(["python3", os.path.join("tools", "mkhello-elf.py"),
                    os.path.join(m120c_share, "HELLO.ELF")],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("HELLO.ELF mint refused: " + r.stdout + r.stderr)
print("HELLO.ELF staged on the m120c share")
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
vgate_assert 01 output-contains 'host-ui: cmd=screenshot vm=1 state=performed'
vgate_assert 01 output-contains 'host-ui: cmd=fullscreen vm=1 state=performed'
vgate_assert 01 output-contains 'host-ui: cmd=capture-keys vm=1 state=performed capture=on'
vgate_assert 01 output-contains 'host-ui: cmd=capture-keys vm=1 state=performed capture=off'
vgate_assert 01 output-contains 'host-ui: cmd=send-file vm=1 state=unavailable'
# M120c (#2560): on a posture-less flag run every lifecycle verb is
# disabled — no saved-state dir (no profile), no share, nothing staged,
# no .prev. Enablement is the receipt, not silence.
vgate_assert 01 output-contains 'host-ui: cmd=suspend vm=1 state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=snapshot vm=1 state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=apply-update vm=1 state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=rollback-update vm=1 state=disabled'
vgate_assert 01 output-contains 'host-ui: cmd=reveal-share vm=1 state=disabled'
# M122d (#2573): the ⌘/ cheat-sheet verb is a self-registered companion
# — always armed, so its receipt carries the open flip and the row
# count generated from the menu's command table.
vgate_assert 01 output-contains 'host-ui: cmd=shortcuts vm=1 state=performed open=1 chords=8'
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

vgate_assert 02 output-contains 'host-ui: cmd=stop vm=1 state=performed'
vgate_assert 02 output-contains 'VM ended before the expected transcript'

vgate_run 03 -- --screen '$RUN_DIR/screen3' --script '$RUN_DIR/script.txt' \
    --host-capture-keys \
    --host-cmd-after 'VirelaiOS kernel has seized control.:capture-keys' \
    --script-expect 'host-ui-idle' --timeout 90

vgate_assert 03 output-contains 'host-capture-keys: ENABLED'
vgate_assert 03 output-contains 'host-ui: cmd=capture-keys vm=1 state=performed capture=on'
vgate_assert 03 output-contains 'host-ui: cmd=capture-keys vm=1 state=performed capture=off'

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

vgate_assert 04 output-contains 'host-ui: cmd=send-serial vm=1 state=performed sent=1'
vgate_assert 04 serial-contains 'inspector-ping'
vgate_assert 04 output-contains 'host-ui: cmd=inspector vm=1 state=performed open=1'
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

vgate_assert 05 output-contains 'host-ui: cmd=screenshot vm=1 state=performed'
vgate_assert 05 output-contains 'host-ui: cmd=record-start vm=1 state=performed recording=on'
vgate_assert 05 output-contains 'host-ui: cmd=record-stop vm=1 state=performed recording=off frames='
# The receipt's frames=/bytes= are the writer's actuals — a gate that
# only read "performed" would pass on a zero-byte MP4.
vgate_assert 05 python <<'PY'
import os, re
out = open(os.path.join(os.environ["RUN_DIR"], "run-" + os.environ["VG_TAG"] + ".out"), "rb").read().decode("utf-8", "replace")
m = re.search(r"host-ui: cmd=record-stop vm=1 state=performed recording=off frames=(\d+) bytes=(\d+)", out)
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

vgate_assert 06 output-contains 'host-ui: cmd=snapshot vm=1 state=performed'
vgate_assert 06 output-contains 'host-ui: cmd=reveal-share vm=1 state=performed'
vgate_assert 06 output-contains 'host-ui: cmd=apply-update vm=1 state=disabled'
vgate_assert 06 output-contains 'host-ui: cmd=rollback-update vm=1 state=disabled'
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

vgate_assert 07 output-contains 'host-ui: cmd=suspend vm=1 state=performed'
vgate_assert 07 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert 07 python <<'PY'
import os, sys
state = os.path.join(os.environ["RUN_DIR"], "m120c.virelaivm",
                     "saved-state", "state.vzsave")
if not os.path.isfile(state) or os.path.getsize(state) == 0:
    sys.exit("suspend left no non-empty saved-state/state.vzsave")
print("suspended state saved: %d bytes" % os.path.getsize(state))
PY

# Run 09 is M139a's (#2779) multi-VM leg: one process, two profiles, two
# windows. `virelai> ` on VM 1's serial dispatches `new-window@ws2` on
# vm 1's bus; VM 2 boots in-session and its own prompt fires the
# `vm2:`-bound suspend on ITS bus — the receipt's `vm=2` and the saved
# state.vzsave prove the verb acted on the sibling, not the primary.
# Recording starts on VM 1 only (vm=1 receipt; no vm=2 record line).
# The duplicate `new-window@ws2` fires on the SAME first-prompt marker,
# one trigger after the open: the minted session is registered before
# the second dispatch runs, so the refusal is deterministic — a later
# marker would race vm 2's own suspend (observed pre-fix: at cap-stop
# the sibling had already stopped, the dedup missed, and a third
# session tried to boot the still-held bundle → VZ start error AND a
# truncated serial.log). VM 1 keeps printing until its own
# script-expect ends the run — the process exit drains whatever is
# left.
vgate_file script9.txt <<'EOF'
echo cap-start
EOF

vgate_file script9b.txt <<'EOF'
echo cap-stop
echo vm1-done
EOF

vgate_run 09 -- --profile '$RUN_DIR/m120c.virelaivm' \
    --overlay-base '$RUN_DIR/m120c-base.img' \
    --virtio-fs '$RUN_DIR/m120c.virelaivm/share' \
    --screen '$RUN_DIR/screen9' \
    --script '$RUN_DIR/script9.txt' \
    --script2 '$RUN_DIR/script9b.txt' --script2-after 'cap-start' --script2-delay 20 \
    --host-cmd-after 'virelai> :new-window@$RUN_DIR/ws2.virelaivm' \
    --host-cmd-after 'virelai> :new-window@$RUN_DIR/ws2.virelaivm' \
    --host-cmd-after 'cap-start:record-start' \
    --host-cmd-after 'vm2:virelai> :suspend' \
    --host-cmd-after 'cap-stop:record-stop' \
    --script-expect 'vm1-done' --timeout 150

vgate_assert 09 output-contains 'host-ui: cmd=new-window vm=1 state=performed opened=2'
vgate_assert 09 output-contains 'host-ui: cmd=record-start vm=1 state=performed recording=on'
vgate_assert 09 output-contains 'host-ui: cmd=suspend vm=2 state=performed'
vgate_assert 09 output-contains 'host-ui: cmd=new-window vm=1 state=disabled reason=profile_in_use'
vgate_assert 09 output-contains 'host-ui: cmd=record-stop vm=1 state=performed recording=off'
vgate_assert 09 output-contains 'vm=2: stopped'
# Recording was VM 1's only — no take ever started on vm 2's bus.
vgate_assert 09 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-" + os.environ["VG_TAG"] + ".out"), "rb").read().decode("utf-8", "replace")
if re.search(r"host-ui: cmd=record-start vm=2 ", out):
    sys.exit("a recording started on vm 2 — record must stay per-session")
# VM 2's suspend preceded VM 1's final SUCCESS — VM 1 kept printing
# while the sibling suspended and stopped.
sus = out.find("host-ui: cmd=suspend vm=2 state=performed")
fin = out.find("SUCCESS: expected transcript")
if sus < 0 or fin < 0 or sus > fin:
    sys.exit("suspend/success ordering wrong: suspend@%d success@%d" % (sus, fin))
# VM 2 really booted: its own serial reached the guest shell.
ser = os.path.join(run, "ws2.virelaivm", "run", "serial.log")
text = open(ser, "rb").read().decode("utf-8", "replace")
if "virelai> " not in text:
    sys.exit("vm 2 never reached the guest shell")
# And really suspended: state.vzsave exists, non-empty.
state = os.path.join(run, "ws2.virelaivm", "saved-state", "state.vzsave")
if not os.path.isfile(state) or os.path.getsize(state) == 0:
    sys.exit("vm 2 suspend left no saved-state/state.vzsave")
print("two-VM leg: suspend before vm1 SUCCESS; ws2 serial + state.vzsave green")
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
vgate_assert 08 output-contains 'host-ui: cmd=screenshot vm=1 state=performed saved=1 file=screen8-hostui-1.png'
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
tag = os.environ["VG_TAG"]
if glob.glob(os.path.join(run, "screen8-hostui-*")):
    sys.exit("screenshot leaked outside CAPTURES into the run dir")
# Lift the capture like run 05 does — the teardown's keep-file copy
# reads $RUN_DIR/<basename>, and the share dies with the temp dir. The
# lifted name is tag-prefixed: under vgate_repeat 3 an earlier
# iteration's lift would otherwise match the leak glob above and
# false-red the next pass.
caps = glob.glob(os.path.join(run, "capshare8", "CAPTURES", "*"))
for f in caps:
    shutil.copy(f, os.path.join(run, tag + "-" + os.path.basename(f)))
print("no run-dir leak; lifted %d CAPTURES file(s)" % len(caps))
PY

# Run 10 is M139e's (#2783) acceptance journey — the arc's two halves in
# ONE process: vm 1's first prompt opens ws2 through the new-window verb
# on vm 1's own bus (M139a), and on vm 1 the staged j1 share brings the
# seat up on script so agentctl's `input` journey (M139b) drives an
# AGENTD session over --net — ui.windows polls until script3's GOEDIT
# registers, ui.input types 'hi' + a click into the focused Edit pane,
# and the following ui.screenshot sees the repaint (pixels-changed is
# the card's "shows the typed text"). Vm 2's own prompt suspends it on
# ITS bus (vm=2 receipts; its saved-state/state.vzsave is the real
# stop), its serial never shows an agent effect, and the session's end
# marker stops vm 1 on ITS bus — the verdict's re-read path (#1024) sees
# the transcript already landed, so the run greens rc 0 with both
# machines' own stop receipts in the out file. A tail assert (#2865)
# holds the share's WINDOWS.SAV record count non-increasing across the
# K=3 — restored phantoms never re-persist.
vgate_file script10.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTABWM.ELF
EOF

vgate_file script10b.txt <<'EOF'
exec -u2000 AGENTD.ELF --allow-exec
EOF

vgate_file script10c.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF
EOF

vgate_run 10 -- --profile '$RUN_DIR/j1.virelaivm' \
    --overlay-base '$RUN_DIR/j1-base.img' \
    --virtio-fs '$RUN_DIR/j1.virelaivm/share' \
    --screen '$RUN_DIR/screen10' \
    --net '$RUN_DIR/cap10.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/agentctl/agentctl.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--journey=input' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --script '$RUN_DIR/script10.txt' \
    --script2 '$RUN_DIR/script10b.txt' --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script10c.txt' --script3-after 'verb=ui.windows' \
    --host-cmd-after 'virelai> :new-window@$RUN_DIR/ws2.virelaivm' \
    --host-cmd-after 'vm2:virelai> :suspend' \
    --host-cmd-after 'agentd: session end reason=client_close:stop' \
    --script-expect 'agentd: session end reason=client_close' --timeout 300

vgate_assert 10 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 10 serial-contains 'verb=ui.windows ok'
vgate_assert 10 serial-contains 'verb=ui.input ok'
vgate_assert 10 serial-contains 'verb=ui.screenshot ok'
vgate_assert 10 serial-contains 'gotabwm: agent-input'
vgate_assert 10 serial-contains 'agentd: session end reason=client_close'
vgate_assert 10 output-contains 'AGENTCTL: PASS input'
vgate_assert 10 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 10 output-contains 'host-ui: cmd=new-window vm=1 state=performed opened=2'
vgate_assert 10 output-contains 'host-ui: cmd=suspend vm=2 state=performed'
vgate_assert 10 output-contains 'host-ui: cmd=stop vm=1 state=performed'
vgate_assert 10 output-contains 'vm-stop: state=0'
vgate_assert 10 output-contains 'vm=2: stopped'
# The agent session rode vm 1 only: vm 2's own serial log shows its own
# boot and prompt, and not one agentd/ui.input/agent-input byte — the
# "no effect" half of the card. Its suspend is real: state.vzsave is
# non-empty, like run 09's check.
vgate_assert 10 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
ser = os.path.join(run, "ws2.virelaivm", "run", "serial.log")
text = open(ser, "rb").read().decode("utf-8", "replace")
if "virelai> " not in text:
    sys.exit("vm 2 never reached the guest shell")
for needle in ("agentd", "agent-input", "ui.input", "ui.screenshot"):
    if needle in text:
        sys.exit("vm 2 serial shows agent traffic: %r" % needle)
state = os.path.join(run, "ws2.virelaivm", "saved-state", "state.vzsave")
if not os.path.isfile(state) or os.path.getsize(state) == 0:
    sys.exit("vm 2 suspend left no saved-state/state.vzsave")
print("journey leg: vm2 serial clean (no agent effect), state.vzsave green")
PY

# #2865: WINDOWS.SAV must not accumulate phantom records across the K=3
# boots. j1's share rides --virtio-fs (runner-armed, not harness-armed —
# the per-boot WINDOWS.SAV reset does not apply), which is exactly why
# run 10 found the leak: restored phantoms were re-serialized, so the
# file went 0 -> 4 -> 8 records and the third boot's opens hit ENOSPC.
# Post-fix the file describes LIVE windows only — its record count is
# bounded by the eight user slots, and the ENOSPC signature
# (`win open failed`) never appears. The record ids+titles are dumped
# into the check output and the file itself lifted as evidence.
vgate_assert 10 serial-absent 'win open failed'
vgate_assert 10 python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
sav = os.path.join(run, "j1.virelaivm", "share", "WINDOWS.SAV")
if not os.path.isfile(sav):
    sys.exit("no WINDOWS.SAV on the j1 share — the persist tick never wrote")
size = os.path.getsize(sav)
if size % 32 != 0:
    sys.exit("WINDOWS.SAV size %d is not a whole record count" % size)
count = size // 32
if count < 1:
    sys.exit("WINDOWS.SAV is empty — no live windows persisted this boot")
# Post-fix every record names a LIVE user window: the eight slots bound
# the file, so a larger count is only reachable through re-persisted
# phantoms (the pre-fix leak accumulated past the live set).
if count > 8:
    sys.exit("WINDOWS.SAV holds %d records — more than the 8 user slots (#2865)" % count)
with open(sav, "rb") as f:
    data = f.read()
for i in range(count):
    rec = data[i * 32:(i + 1) * 32]
    title = rec[20:32].split(b"\0", 1)[0].decode("ascii", "replace")
    print("  rec %d: id=%d flags=%02x ws=%d title=%r" % (i, rec[0], rec[1], rec[2], title))
shutil.copy(sav, os.path.join(run, "winsav-" + os.environ["VG_TAG"] + ".sav"))
print("WINDOWS.SAV: %d record(s), within the live-slot bound" % count)
PY

# Run 11 is M157a's (#2934): per-VM window identity + the close policy.
# The primary's `window` line names the m120c profile; the sibling cv2
# carries closeAction=suspend, so `close@vm=2` — fired on vm 2's OWN
# prompt, dispatched on vm 2's OWN bus — runs the SuspendCtl save path:
# a saved-state/state.vzsave lands and the sibling stops. The primary
# keeps running to its own expect — runs 01-10 are unchanged.
vgate_file script11.txt <<'INNER'
echo cv2-boot
INNER

vgate_file script11b.txt <<'INNER'
echo vm1-done
INNER

vgate_run 11 -- --profile '$RUN_DIR/m120c.virelaivm' \
    --overlay-base '$RUN_DIR/m120c-base.img' \
    --virtio-fs '$RUN_DIR/m120c.virelaivm/share' \
    --script '$RUN_DIR/script11.txt' \
    --script2 '$RUN_DIR/script11b.txt' --script2-after 'cv2-boot' --script2-delay 30 \
    --host-cmd-after 'virelai> :new-window@$RUN_DIR/cv2.virelaivm' \
    --host-cmd-after 'vm2:virelai> :close@vm=2' \
    --script-expect 'vm1-done' --timeout 150

vgate_assert 11 output-contains 'host-ui: cmd=new-window vm=1 state=performed opened=2'
vgate_assert 11 output-contains 'host-ui: cmd=close vm=2 state=performed target=2 action=suspend'
vgate_assert 11 output-contains 'vm=2: stopped'
# Both window lines carry the right titles — the em dash is the titles'
# own — and close vm=2 ends in a saved-state file OR the named Code=2
# line (a custom-virtio set is not in this run, so saved is expected).
vgate_assert 11 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-" + os.environ["VG_TAG"] + ".out"), "rb").read().decode("utf-8", "replace")
for needle in ("host-ui: window vm=1 title=VirelaiOS \u2014 m120c",
               "host-ui: window vm=2 title=VirelaiOS \u2014 cv2 (vm 2)"):
    if needle not in out:
        sys.exit("window line missing: %r" % needle)
state = os.path.join(run, "cv2.virelaivm", "saved-state", "state.vzsave")
if "host-ui: close vm=2 action=suspend result=saved" in out:
    if not os.path.isfile(state) or os.path.getsize(state) == 0:
        sys.exit("close=suspend reported saved but saved-state/state.vzsave is absent or empty")
    print("close=suspend saved: state.vzsave %d bytes" % os.path.getsize(state))
elif "host-ui: close vm=2 action=suspend result=refused code=2" in out:
    print("close=suspend refused code=2 (the named Code=2 fallback)")
else:
    sys.exit("no host-ui: close vm=2 verdict line in the out file")
PY

# Run 13 is M183c's (#3173): the idle-pause policy. A gate cannot produce
# a real NSWindow occlusion change (index thesis 1), so `idle-occlude`
# and `idle-focus` are the scripted twins of the occlusion and focus
# edges — the close@vm= precedent — driving the identical policy path the
# window delegates ride. `idle-occlude@600` stages a stretch already past
# the default 300 s interval, so the dispatch itself runs the real
# vm.pause on the live VM; `idle-focus` on the same marker runs the real
# vm.resume (a paused guest can print no marker — the focus trigger must
# ride a pre-pause marker, in dispatch order after the occlude).
vgate_run 13 -- --script '$RUN_DIR/script.txt' \
    --host-cmd-after 'virelai> :idle-occlude@600' \
    --host-cmd-after 'virelai> :idle-focus' \
    --script-expect 'host-ui-idle' --timeout 120

vgate_assert 13 output-contains 'host-machine: idle-pause armed interval=300s'
vgate_assert 13 output-contains 'host-ui: cmd=idle-occlude vm=1 state=performed idle=paused'
vgate_assert 13 output-contains 'host-machine: idle-pause paused occluded=600s'
vgate_assert 13 output-contains 'host-ui: cmd=idle-focus vm=1 state=performed'
vgate_assert 13 output-contains 'host-machine: idle-pause resumed'

# Run 12 is M157e's (#2938): the whole M157 arc in one journey, under
# the spec's inherited K=3. On vm 1's first prompt two triggers fire in
# order — `new-window@tr2` boots the sibling, and `send-serial` writes
# the armed `strace exec HELLO.ELF` into the console pipe (run 04's
# injection seam; HELLO.ELF was staged on the primary's share in setup).
# The guest's own strace arm produces the `[strace <pid>] sys_*` rows
# the HostTracer ring parses off the same serial feed, so the
# `inspector` verb — fired on the traced program's exit record, after
# the rows provably landed — receipts `host-inspector: trace rows=<n>`
# with n > 0. tr2's own prompt then fires `close@vm=2` on ITS bus:
# closeAction=suspend runs the save path and the sibling stops while
# the primary prints to its own expect. The run's K=3 semantics are run
# 10's: each iteration re-mints nothing, but every leg re-runs and the
# python asserts read their own run's out file via VG_TAG.
vgate_file script12.txt <<'INNER'
echo tr-boot
INNER

vgate_file script12b.txt <<'INNER'
echo vm1-done
INNER

vgate_run 12 -- --profile '$RUN_DIR/m120c.virelaivm' \
    --overlay-base '$RUN_DIR/m120c-base.img' \
    --virtio-fs '$RUN_DIR/m120c.virelaivm/share' \
    --host-serial-send 'strace exec HELLO.ELF' \
    --script '$RUN_DIR/script12.txt' \
    --script2 '$RUN_DIR/script12b.txt' --script2-after 'tr-boot' --script2-delay 30 \
    --host-cmd-after 'virelai> :new-window@$RUN_DIR/tr2.virelaivm' \
    --host-cmd-after 'virelai> :send-serial' \
    --host-cmd-after 'tasks user-exec exited status=42:inspector' \
    --host-cmd-after 'vm2:virelai> :close@vm=2' \
    --script-expect 'vm1-done' --timeout 150

vgate_assert 12 output-contains 'host-ui: cmd=new-window vm=1 state=performed opened=2'
vgate_assert 12 output-contains 'host-ui: cmd=send-serial vm=1 state=performed sent=1'
vgate_assert 12 output-contains 'host-ui: cmd=inspector vm=1 state=performed open=1'
vgate_assert 12 output-contains 'saw=1'
vgate_assert 12 output-contains 'host-ui: cmd=close vm=2 state=performed target=2 action=suspend'
vgate_assert 12 output-contains 'vm=2: stopped'
# The injected line really ran: the shell echo wraps it, the arm
# receipts, and the traced program's write + exit land on serial — the
# same records the host-side ring parsed into rows.
vgate_assert 12 serial-contains 'strace exec HELLO.ELF'
vgate_assert 12 serial-contains 'strace: armed'
vgate_assert 12 serial-contains '] sys_write('
vgate_assert 12 serial-contains '] sys_exit('
vgate_assert 12 serial-contains 'elf: hello from HELLO.ELF'
vgate_assert 12 serial-contains 'tasks user-exec exited status=42'
# Titles on both buses, a positive trace-rows receipt, and the close
# verdict — the card's three legs in one check. `saw=1` already proved
# the injection echoed; the rows bound is the M157b ring's count, not a
# replayed serial grep.
vgate_assert 12 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-" + os.environ["VG_TAG"] + ".out"), "rb").read().decode("utf-8", "replace")
for needle in ("host-ui: window vm=1 title=VirelaiOS \u2014 m120c",
               "host-ui: window vm=2 title=VirelaiOS \u2014 tr2 (vm 2)"):
    if needle not in out:
        sys.exit("window line missing: %r" % needle)
m = re.search(r"host-inspector: trace rows=(\d+) filter=", out)
if not m:
    sys.exit("no host-inspector: trace receipt in the out file")
if int(m.group(1)) < 1:
    sys.exit("host-inspector: trace rows=%s — the ring saw no [strace] rows" % m.group(1))
state = os.path.join(run, "tr2.virelaivm", "saved-state", "state.vzsave")
if "host-ui: close vm=2 action=suspend result=saved" in out:
    if not os.path.isfile(state) or os.path.getsize(state) == 0:
        sys.exit("close=suspend reported saved but saved-state/state.vzsave is absent or empty")
    print("close=suspend saved: state.vzsave %d bytes" % os.path.getsize(state))
elif "host-ui: close vm=2 action=suspend result=refused code=2" in out:
    print("close=suspend refused code=2 (the named Code=2 fallback)")
else:
    sys.exit("no host-ui: close vm=2 verdict line in the out file")
print("titles, trace rows=%s>0, close verdict: PASS" % m.group(1))
PY
