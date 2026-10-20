# go-wm-default.spec -- M59 (issue #1298) class-B gate: the boot-default flip.
#
# Boot 01 carries NO `wm` setting or SESSION.TABS: the compiled default seats
# GOTABWM.ELF and M76b opens its first-boot GOSH workspace before the settings
# and calculator runs. A marker and prompt-pixel capture pin the hosted
# terminal. Zig CALC.BIN is gone (M62h / #1406).
#
# M71f (#1565): the run then persists `wm=tabwm` FROM THE GO PANEL. GOSET.ELF
# is exec'd under the seat after the first-boot shell tab, typed into, and applies
# `wm=tabwm` with one command line -- the panel publishes it crash-safe. That is
# the card's premise repaired in place: on the DEFAULT seat, a Go UI changes the
# seat. Boot 01's publish includes the visible, accepted-but-unseeded
# idle_minutes default row; boot 04's kernel-side heal does not seed it.
# Boots 11/12 set a nondefault idle_minutes FROM GOSET and read it on reboot.
# M82d2 (#1785) adds the notifications policy's two persisted halves as boots
# 13-16: the do-not-disturb key (GOSET writes `notify_dnd=on`, the seat applies
# it live, the next boot reads it) and the crash-safe notification history (a
# corrupt NOTIFY.HIST is refused whole and heals to an empty one; the boot
# after finds nothing wrong). The notify -> DND -> held -> restart chain with
# a real sender is go-dogfood's boots 05/06.
# M83c (#1776) adds boots 17/18: the `timezone` row is a visible
# accepted-but-unseeded GOSET row like the two above, and a typed fixed
# offset survives the safe publish into the next boot (`settings get`). The
# zone's effect on `date` is go-sh's two-zone boot.
#
# The panel takes focus when its declare is accepted and is typed into before
# the two-tab close choreography completes (the runner's --input-string
# watcher gives up after 40 s). GOCALC.ELF starts after both tabs close, so it
# gets the strip alone and cannot be captured by the M62e SESSION.TABS snapshot.
#
# Boot 02 proves the flip is a SETTING, not a hardcode: the same share boots
# the Zig TABWM seat -- the fallback the card requires to stay reachable.
# M63f (#1463): re-verified green after GOTABWM maxTicks 90 (M73z;
# was 48). No HID here.
#
# M66b (#1444): boots 03/04 add the corrupt-settings story. Boot 03 stages
# real corruption (the monitor's vf verbs overwrite SETTINGS.TXT with
# probe-pattern garbage); boot 04 boots on it -- the kernel refuses the
# file whole (one honest line, compiled defaults, the Go seat again), the
# seat's own decode reports `gotabwm: settings bad`, and the closing
# `settings set` heals the file through the crash-safe save (temp + fsync
# + delete/rename). The healed bytes are byte-compared on the host.
#
# M81g (#1767) adds boots 05-09: the SNAPSHOT bundle and the restore DRILL, in
# five steps staged by the seat and the monitor together — prep the table, take
# the snapshot with the seat's own Ctrl+Shift+S chord, restore it into the next
# boot, then refuse a corrupt bundle and a missing one. The card's deliverable
# is the drill, so the positive half is a boot like any other: the seat
# rehydrates the share and the boot then reads the restored files through its
# ORDINARY loadSettings/loadSession paths, which is why boot 07's byte-exact
# `share-equals` needs no new assert shape. The refusal halves are the M66b
# corrupt-settings story reused verbatim — one honest line, nothing written,
# the boot carries on. See the run-by-run table above the boots.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh      ->  .build/go/GOSH.ELF (M76b first boot)
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#
# exec-order: assert-proven -- every stage gate is anchored on guest output the
# kernel, the seat or the hosted app produced (`gotabwm: win focus`,
# `gotabwm: win gone`, `gotabwm: tabs empty`, `goset: ready`, `tabwm:
# registered`). Runs 02-04 end on a marker only their own script prints. Run 01
# ends on the PANEL's publish line (`goset: saved `) and carries
# --script-expect-tail so the hold covers the seat's own clean exit -- the
# panel's save is the thing under test, and the tail keeps the `gotabwm OK` /
# `wm: unregistered, shim resumed` asserts honest rather than dropping them.
# Tail 90 -> 150 for M73z: the seat's budget went maxTicks 48 -> 90 (seat.go,
# boot 04's acceptance chain), so the exit now lands near the OLD 90 s tail's
# boundary -- observed 2026-09-23: serial cut at `gotabwm OK`, the kernel's
# unregister line just outside the capture.

vgate_name go-wm-default "issue #1298 M59 / M71f #1565: a DEFAULT boot seats the Go desktop (GOTABWM.ELF hosting GOCALC.ELF), and the GO PANEL (GOSET.ELF) writing wm=tabwm keeps the Zig fallback reachable across a reboot"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import runpy
runpy.run_path("tests/fixtures/desktop/m91/fresh.py")["stage"]({
    "GOTABWM": "build-gotabwm.sh", "GOSH": "build-gosh.sh",
    "GOCALC": "build-gocalc.sh", "GOSET": "build-goset.sh",
    "GOTERM": "build-goterm.sh", "GOEDIT": "build-goedit.sh",
    "NOTE": "build-note.sh",
    # M122b (#2571): the first-boot tour — staged so boot 19's live
    # first-boot branch can exec it; the demo boots never reach it.
    "GOWELCOME": "build-gowelcome.sh",
})
PY

# Boot 01, stage 1: forwarded once the seat holds its window and is WAITING for
# the blur, so `dui focus 0` (the fixed terminal window) hands focus away and
# the kernel routes WIN_BLUR to the seat. No `wm` key anywhere: the autostart
# is what put this seat on the scanout.
vgate_file script.txt <<'EOF'
dui focus 0
EOF

# Boot 01, stage 2: after the first-boot GOSH prompt has had four seconds to
# reach scanout, capture it and launch the settings panel. GOSH and GOSET share
# the seat's proven two-client envelope; the seat closes both before stage 3.
vgate_file script2.txt <<'EOF'
echo M76B_FIRSTBOOT_CAPTURE
echo M76B_FIRSTBOOT_CAPTURE
set GOMAXPROCS=1
wm
exec GOSET.ELF
EOF

# Boot 01, stage 3: the two-tab choreography has closed GOSH and GOSET, so
# GOCALC.ELF is exec'd as the M59 hosted-client proof on an empty strip. The
# save under test already happened in stage 2 and was the PANEL's, never the
# monitor's `settings set`.
vgate_file script3.txt <<'EOF'
exec GOCALC.ELF
EOF

# M79a (#1704): the seat's bounded demo choreography (auto-close, the
# two-tab close chain, the run budget) is DEMO mode, opted in by the PRESENCE
# of /host/GOTABWM.DEMO. Boot 01/04 autostart the seat (no monitor exec to
# seed anything at), and boot 01's stage chain is written against the
# choreography's closes -- so the trigger is seeded here like any other share
# fixture. "Untouched" stays true of the SETTINGS/SESSION state, which is
# what this spec's boots actually pin. A daily session never stages this file
# and gets the live seat (go-wm-seat run 05 proves that path end to end).
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
with open(os.path.join(share, "GOTABWM.DEMO"), "w") as f:
    f.write("demo\n")
print("seeded GOTABWM.DEMO (seat demo mode: bounded choreography)")
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABWM.ELF")))
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gosh.sh")
shutil.copy(src, os.path.join(share, "GOSH.ELF"))
print("staged GOSH.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOSH.ELF")))
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
# M71f (#1565): the panel boot 01 launches from the catalogue. It must be
# staged, or the launcher's exec is the honest `launcher missing` path.
src = os.path.join(".build", "go", "GOSET.ELF")
if not os.path.exists(src):
    sys.exit("GOSET.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goset.sh")
shutil.copy(src, os.path.join(share, "GOSET.ELF"))
print("staged GOSET.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOSET.ELF")))
# No SETTINGS.TXT: boot 01 must run on the COMPILED default. That is the
# whole point -- staging a settings file here would test the setting, not
# the flip. It is also what makes the panel's FIRST save a create.
if os.path.exists(os.path.join(share, "SETTINGS.TXT")):
    sys.exit("SETTINGS.TXT already present in the share; boot 01 must boot "
             "with no persisted `wm`")
if os.path.exists(os.path.join(share, "SESSION.TABS")):
    sys.exit("SESSION.TABS already present in the share; boot 01 must prove "
             "the missing-session first-boot branch")
PY

# M81g (#1767): the documents selection the snapshot carries, seeded here on
# the HOST share. The seat's capture lists /host/DOCS and takes the first
# maxDocs regular files in NAME order, so these two are what `docs=2` on the
# snapshot marker counts. They are staged from the host rather than through
# the monitor's `vf` verbs because the seat only READS this directory here —
# the restore writes through the EL0 file ABI, and vf's own trust gate is not
# part of what this card is testing.
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
docs = os.path.join(share, "DOCS")
os.makedirs(docs, exist_ok=True)
bodies = {"NOTE.TXT": b"m81g snapshot document one\n",
          "SECOND.TXT": b"m81g snapshot document two\n"}
for name, body in bodies.items():
    with open(os.path.join(docs, name), "wb") as fh:
        fh.write(body)
print("seeded DOCS/{%s} for the M81g documents selection" % ", ".join(sorted(bodies)))
PY

# The kernel's compiled table with `wm=tabwm` (boot 04's corrupt-file heal).
# The accepted-but-unseeded idle_minutes row is absent by design.
vgate_file settings-healed.expected <<'EOF'
#v2
hostname=virelai
prompt=virelai> 
theme=dark
scrollback=1000
shadow=off
focus_follows_mouse=off
shell=monitor
wm=tabwm
init=on
keyboard_layout=de
EOF

# Boot 01's panel publishes the same rows plus its visible idle_minutes,
# notify_dnd and timezone rows (all accepted-but-unseeded, shown with their
# defaults, in Display() order). Generate from the kernel fixture to keep its
# trailing prompt space exact.
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
with open(os.path.join(rd, "settings-healed.expected"), "rb") as src:
    body = src.read()
with open(os.path.join(rd, "settings-panel.expected"), "wb") as dst:
    dst.write(body + b"idle_minutes=5\nnotify_dnd=off\ntimezone=UTC\n")
PY

# M81g (#1767): the settings table the SNAPSHOT carries, and the one the
# restore must put back byte-exact. It differs from settings-healed.expected in
# exactly two rows — `theme=light` and `wm=gotabwm` — which is what makes the
# restore observable rather than circular: the live file is set to theme=dark
# after the snapshot is taken, so boot 07 reporting `theme=light` AND
# byte-equalling THIS fixture can only have got those bytes from the bundle.
# `wm=gotabwm` is also what seats the Go desktop that performs the restore, so
# it has to be in the table.
#
# `theme` has to be a value the theme module HONORS: user/go/theme's Set
# accepts only dark and light, so `theme=amber` — a legal settings vocab value —
# leaves the seat painting dark and the token probe would report `theme=dark`
# whatever the file said (observed on the first M81g run). light is real, so
# the probe is a true witness of the decoded row.
#
# `prompt` carries NO trailing space here, unlike settings-healed.expected.
# That is not a typo: boot 04 heals a CORRUPT file, so the kernel serializes
# its compiled default table with `prompt=virelai> ` intact, whereas boot 05's
# `settings set` re-serializes a PARSED table — and the schema-v2 parse
# trims each value (virelai/settings Parse). So after any parse+set cycle the
# space is gone, and a fixture carrying it can never match (observed on the
# first M81g run, boot 05).
vgate_file settings-snapshot.expected <<'EOF'
#v2
hostname=virelai
prompt=virelai>
theme=light
scrollback=1000
shadow=off
focus_follows_mouse=off
shell=monitor
wm=gotabwm
init=on
keyboard_layout=de
EOF

# M71f (#1565): the run gains HID. Once the panel says it is ready, the
# idle and seat rows save on Enter through the same safe path. The layout
# row follows by the gate's existing chord path, with leading spaces
# trimmed by GOSET so lost HID startup strokes cannot eat the key name. The
# keys ride the custom-virtio INPUT queue (headless HID reports, no view), the
# same channel go-wm-hid's type-in boot uses, and they land in the FOCUSED
# window -- which is GOSET, because its declare takes focus over the starter.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --screenshot-after 'M76B_FIRSTBOOT_CAPTURE' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gosh: prompt' --script2-delay 4 \
    --input-string $'wm=tabwm\n' \
    --input-string-after 'goset: ready ' \
    --input-chords 'space,space,space,space,space,space,space,space,space,space,space,space,k,e,y,b,o,a,r,d,_,l,a,y,o,u,t,=,d,e,return' \
    --input-chords-after 'goset: saved ' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'goset: close' \
    --script-expect 'goset: saved ' --script-expect-tail 150 --timeout 300

# --- the flip: an untouched boot lands in the Go desktop ------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# The shell idle seated the Go desktop because nothing else was configured.
vgate_assert 01 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
# The seat's own marker chain (each printed after its syscall succeeded).
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
vgate_assert 01 serial-contains 'gotabwm: scanout'
vgate_assert 01 serial-contains 'gotabwm: draw'
vgate_assert 01 serial-contains 'gotabwm: holding seat'
vgate_assert 01 serial-contains 'gotabwm: tick'
vgate_assert 01 serial-contains 'gotabwm: present'
# M76b: the empty SESSION.TABS branch launches one GOSH tab on the default
# seat. The marker is the seat's successful sys_exec; these app/seat markers
# prove that GOSH declared and the seat accepted it.
vgate_assert 01 serial-contains 'gotabwm: first-boot workspace'
# M122b (#2571): the welcome tour is LIVE-mode only — this demo boot's
# choreography owns the strip and must never see it.
vgate_assert 01 serial-absent 'gotabwm: welcome tour'
vgate_assert 01 serial-absent 'gowelcome: open id='
vgate_assert 01 serial-contains 'gosh: declare accepted'
vgate_assert 01 serial-contains 'gotabwm: tab open id='
vgate_assert 01 serial-contains 'gosh: prompt'
# The kernel's own report of the live seat, queried while it is up.
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'wm: present_seq='
# The seat's own window lifecycle, with the kernel-clamped rect (4000,3000
# clamped to the 1280x720 scanout: x=1024, y=528).
vgate_assert 01 serial-contains 'gotabwm: win open id='
vgate_assert 01 serial-contains 'gotabwm: win rect x=1024 y=528 w=256 h=192'
vgate_assert 01 serial-contains 'gotabwm: win focus'
vgate_assert 01 serial-contains 'gotabwm: win blur'
vgate_assert 01 serial-contains 'gotabwm: win close'
vgate_assert 01 serial-contains 'gotabwm: win gone'

# --- M71f (#1565): the DEFAULT seat's Go panel writes the setting ----------
# The panel is focused after its declare on the live default seat. It decodes
# the ABSENT settings file as compiled defaults (so `wm` is a row it can set),
# takes the typed command line, and publishes.
vgate_assert 01 serial-contains 'exec: loaded GOSET.ELF'
vgate_assert 01 serial-contains 'goset: open id='
vgate_assert 01 serial-contains 'goset: ready keys=13 wm=gotabwm theme=dark mode=rw'
vgate_assert 01 serial-contains 'goset: set keyboard_layout=de'
vgate_assert 01 serial-contains 'goset: set wm=tabwm'
vgate_assert 01 serial-contains 'goset: saved keys=13 wm=tabwm theme=dark'
vgate_assert 01 serial-contains 'goset OK'
# The panel's publish is a real file on the share, including idle_minutes and
# the M82d2 do-not-disturb default.
vgate_assert 01 share-equals SETTINGS.TXT settings-panel.expected
# The panel's window closed before the second client was exec'd: the strip
# really emptied, so GOCALC never shared the strip with it.
vgate_assert 01 serial-contains 'gotabwm: tabs empty'

# --- and still hosts GOCALC.ELF (M59) ---------------------------------------
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='
vgate_assert 01 serial-contains 'gocalc: present'
vgate_assert 01 serial-contains 'gotabwm: host close id='
vgate_assert 01 serial-contains 'gocalc: close'
vgate_assert 01 serial-contains 'gotabwm: host done'

vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- M82a (#1768): the manifest on the share is the versioned schema -------
# This spec never summons the launcher, so the decode receipt go-dogfood
# asserts is not observable here. What IS observable is the file the seat
# read: the staged share's APPS.TXT, decoded on the host with the same rules
# the Go parser uses. What this proves is deliberately narrow — the manifest
# the seat boots on is the v2 file, its positional fields are intact, and the
# dock set is the 8 rows the Zig mirrors' comments claim. The v2 tail's
# SEMANTICS (argv/caps/opens) are host-tested in user/go/gotabwm/apps_test.go
# and read live by go-dogfood; this is the share-side half.
vgate_assert 01 python <<'PY'
import os, sys

share = os.environ["VG_SHARE"]
text = open(os.path.join(share, "APPS.TXT"), encoding="utf-8").read()
rows = [ln for ln in text.splitlines() if ln.strip() and not ln.startswith("#")]
if len(rows) != 29:
    sys.exit("manifest has %d rows, want 29 (M132b #2753 appended the nine "
             "M140-M148 reservation rows; dock stays 8)" % len(rows))
dock = 0
v2 = 0
for ln in rows:
    f = [x.strip() for x in ln.split("|")]
    if len(f) < 2 or not f[0] or not f[1]:
        sys.exit("row lost its positional fields: %r" % ln)
    if len(f) > 3 and f[3] == "dock=true":
        dock += 1
    if f[4:]:
        # A v2 tail only exists past field 4, and field 4 is the dock flag in
        # every reader. An undocked row that skipped it put its `v=` where the
        # dock flag goes: the row still parsed, but its version was invisible
        # and its tail was read as fields the schema does not define. This is
        # the one shape error a v1 reader cannot report, so it is reported
        # here.
        if len(f) < 5 or f[3] not in ("dock=true", "dock=false"):
            sys.exit("row has a v2 tail but not all four positional fields "
                     "(field 4 must be dock=true|dock=false): %r" % ln)
        if f[4].split("=", 1)[0] != "v":
            sys.exit("a v2 row must declare its version first: %r" % ln)
    for tail in f[4:]:
        if not tail or "=" not in tail:
            sys.exit("trailing field is not key=value: %r" % ln)
        if tail.split("=", 1)[0] == "v":
            if tail != "v=2":
                sys.exit("unexpected row version: %r" % ln)
            v2 += 1
if dock != 8:
    sys.exit("dock rows = %d, want 8 (the number the Zig mirrors claim)" % dock)
if v2 == 0:
    sys.exit("no row declares v=2: this is the v1 file, not the v2 schema")
print("share APPS.TXT: %d rows, %d docked, %d rows at v=2, %d bytes"
      % (len(rows), dock, v2, len(text.encode())))
PY

# The prompt capture happens before the first-boot GOSH tab's bounded single-
# tab close. Count the green prompt glyphs to prove it reached scanout.
vgate_assert 01 snapshot 'screen-after' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line
def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]
scale = w / 1280.0
green = 0
for y in range(int(17 * scale), int(30 * scale)):
    for x in range(int(1 * scale), int(56 * scale)):
        r, g, b = px(x, y)
        if g > r + 30 and g > b + 30:
            green += 1
print("first-boot terminal-green pixels: %d" % green)
assert green >= 200, ("first-boot GOSH prompt absent from scanout (%d pixels)" % green)
PY

# --- boot 02: the PANEL's `wm=tabwm` from boot 01 -> the Zig fallback seat ---
vgate_file script-02.txt <<'EOF'
settings get keyboard_layout
settings get idle_minutes
tabwm
echo rx-m59-fallback-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script-after 'tabwm: registered' \
    --script-expect 'rx-m59-fallback-ok' --timeout 300

# The persisted setting, not a hardcode: the same share that booted the Go
# seat in run 01 boots the Zig seat here. This is ALSO M71f's D2 -- the value
# the GO PANEL wrote is what makes the named Zig fallback (ADR 0034) reachable
# from the default seat. Panel-driven save, and the panel-driven fallback.
vgate_assert 02 serial-contains 'wm: autostart tabwm (settings wm=tabwm)'
vgate_assert 02 serial-contains 'settings: keyboard_layout=de'
vgate_assert 02 serial-contains 'settings: idle_minutes=5'
vgate_assert 02 serial-contains 'tabwm: registered'
vgate_assert 02 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 02 serial-contains 'tabwm: registered pid='
vgate_assert 02 serial-contains 'rx-m59-fallback-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# --- M66b (#1444): corrupt settings fail closed, then heal ------------------
# Boot 03 stages the corruption the M66b design exists for: the monitor's
# `vf` verbs overwrite SETTINGS.TXT with 64 probe-pattern bytes -- the exact
# shape a partial in-place write used to leave (binary garbage, no valid
# `#v` header). Handle 0 is the first host write handle of a fresh boot.
# The boot itself seated the Zig tabwm (run 01's persisted `wm=tabwm`).
vgate_file script-03.txt <<'EOF'
vf open SETTINGS.TXT
vf truncate 0 0
vf write 0 64
vf close 0
echo rx-m66b-corrupt-staged
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --script '$RUN_DIR/script-03.txt' \
    --script-expect 'rx-m66b-corrupt-staged' --timeout 300

vgate_assert 03 serial-contains 'wm: autostart tabwm (settings wm=tabwm)'
vgate_assert 03 serial-contains 'vf: open SETTINGS.TXT h=0'
vgate_assert 03 serial-contains 'vf: truncate 0 size=0 ok'
vgate_assert 03 serial-contains 'vf: write 0 n=64 wrote=64 chunks=1'
vgate_assert 03 serial-contains 'vf: close 0 ok'
vgate_assert 03 serial-contains 'rx-m66b-corrupt-staged'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# Boot 04 boots ON the corrupt file. The kernel refuses it whole (no valid
# schema header -> one honest line, compiled defaults), so the compiled
# default seats the GO desktop again, and the seat's own decode reports the
# corruption and runs on defaults -- corrupt-fails-closed, never a boot
# failure. The closing `settings set` then heals the file through the
# crash-safe save (temp + fsync + delete/rename, never an in-place
# truncate), and the share assert below byte-compares the healed bytes.
vgate_file script-04.txt <<'EOF'
settings set wm tabwm
settings set keyboard_layout de
echo rx-m66b-corrupt-ok
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --script '$RUN_DIR/script-04.txt' \
    --script-after 'gotabwm: settings bad' \
    --script-expect 'rx-m66b-corrupt-ok' --timeout 300

vgate_assert 04 serial-contains 'settings: SETTINGS.TXT refused (defaults in force)'
vgate_assert 04 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 04 serial-contains 'gotabwm: registered'
vgate_assert 04 serial-contains 'gotabwm: settings bad'
vgate_assert 04 serial-contains 'settings: wm=tabwm (persisted)'
vgate_assert 04 serial-contains 'settings: keyboard_layout=de (persisted)'
vgate_assert 04 serial-contains 'rx-m66b-corrupt-ok'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# The healed file, byte-exact: the same settings-healed.expected boot 01's Go
# panel published (declared above). `share-equals` lifts the compared file
# into evidence automatically.
vgate_assert 04 share-equals SETTINGS.TXT settings-healed.expected
# The publish consumed its temp: a crash-safe save leaves no SETTINGS.TXT~
# on the share (the rename is the publish).
vgate_assert 04 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
stale = os.path.join(share, "SETTINGS.TXT~")
if os.path.exists(stale):
    sys.exit("SETTINGS.TXT~ survived the publish - the rename did not run")
print("crash-safe publish left no SETTINGS.TXT~ on the share")
PY

# ---------------------------------------------------------------------------
# M81g (#1767): the snapshot bundle, and the restore DRILL
# ---------------------------------------------------------------------------
# The card's deliverable is the drill, not the archive step, so the runs below
# are staged by the seat and the monitor together and every step is checked
# against the share from the host:
#
#   05  prep        the settings table the snapshot will carry (wm=gotabwm so
#                   the Go desktop is seated, theme=light as the marker value)
#   06  take        the SEAT presses Ctrl+Shift+S; the follow-up script runs
#                   only after the `snapshot saved` marker, so the capture is
#                   provably taken BEFORE the settings are changed underneath
#                   it. That script then sets theme=dark (so a later restore is
#                   observable) and stages the one-shot SNAPSHOT.RESTORE.
#   07  restore     the seat rehydrates the share from the bundle: the token
#                   probe reports theme=light again and SETTINGS.TXT
#                   byte-equals settings-snapshot.expected.
#   08  corrupt     64 probe-pattern bytes are staged over the bundle and the
#                   request re-armed. The seat refuses the bundle WHOLE:
#                   one `snapshot bad` line, SETTINGS.TXT untouched, the
#                   request consumed, the boot otherwise normal.
#   09  absent      the bundle is removed and the request re-armed. A missing
#                   bundle is a different diagnosis from a corrupt one and is
#                   named as such; nothing is written either way.
#
# The two refusal runs are the M66b corrupt-settings shape reused verbatim:
# refuse whole, one honest line, compiled defaults, never a boot failure.

# Boot 05: the table the snapshot will carry. `wm=gotabwm` cannot be assumed —
# boot 04 healed the file to wm=tabwm — so the Go seat that performs the
# capture has to be asked for first, and the seat is chosen at boot.
vgate_file script-05.txt <<'EOF'
settings set wm gotabwm
settings set theme light
echo rx-m81g-prep-ok
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --script '$RUN_DIR/script-05.txt' \
    --script-expect 'rx-m81g-prep-ok' --timeout 300

vgate_assert 05 serial-contains 'settings: wm=gotabwm (persisted)'
vgate_assert 05 serial-contains 'settings: theme=light (persisted)'
vgate_assert 05 serial-absent '[EXC] parking:'

# The table boot 06 snapshots, and boot 07 must bring back.
vgate_assert 05 share-equals SETTINGS.TXT settings-snapshot.expected

# Boot 06: the seat takes the snapshot. Two orderings have to be right and both
# are marker-caused, never slept on:
#
#   - `dui focus 0` (script 1) hands focus away from the seat's window, which is
#     what the seat's bounded choreography waits for. Without it the seat sits
#     in `win blur timeout` and never reaches the loop that handles keys — the
#     first M81g run stalled there for the full 300 s and no chord was ever
#     read. This is boot 01's own focus step, and the seat needs it here for the
#     same reason.
#   - the chord is anchored AFTER `gotabwm: win gone`, so it is delivered once
#     the seat is actually polling events, and --script2-after keys the
#     follow-up off the seat's OWN `snapshot saved` marker — establishing
#     "capture, then change the settings under it" without a sleep.
vgate_file script-06-focus.txt <<'EOF'
dui focus 0
EOF

vgate_file script-06.txt <<'EOF'
settings set theme dark
vf open SNAPSHOT.RESTORE
vf write 0 1
vf close 0
echo rx-m81g-snapshot-staged
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-06-focus.txt' \
    --script-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-s' \
    --input-chords-after 'gotabwm: win gone' \
    --script2 '$RUN_DIR/script-06.txt' \
    --script2-after 'gotabwm: snapshot saved' \
    --script-expect 'rx-m81g-snapshot-staged' --timeout 300

# The seat is the Go desktop (boot 05 asked for it) and the chord armed.
vgate_assert 06 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 06 serial-contains 'gotabwm: registered'
# The capture marker, printed only after the crash-safe publish returned.
vgate_assert 06 serial-contains 'gotabwm: snapshot saved bytes='
# The follow-up then moved the live settings AWAY from what was captured, and
# armed the one-shot restore request.
vgate_assert 06 serial-contains 'settings: theme=dark (persisted)'
vgate_assert 06 serial-contains 'vf: open SNAPSHOT.RESTORE h=0'
vgate_assert 06 serial-contains 'vf: close 0 ok'
vgate_assert 06 serial-contains 'rx-m81g-snapshot-staged'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
# The publish consumed its temp, like every other safe publish in this spec.
vgate_assert 06 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
stale = os.path.join(share, "SNAPSHOT.BUNDLE~")
if os.path.exists(stale):
    sys.exit("SNAPSHOT.BUNDLE~ survived the publish - the rename did not run")
print("crash-safe bundle publish left no SNAPSHOT.BUNDLE~ on the share")
PY
# The bundle's shape, read on the HOST: the header carries the entry count, and
# the selection is settings + the session strip + both documents. The byte
# count is checked against the file's real size, so the marker's `bytes=` is
# held to what actually landed rather than trusted.
vgate_assert 06 python <<'PY'
import os, re, sys
share = os.environ["VG_SHARE"]
rd = os.environ["RUN_DIR"]
serial = open(os.environ.get("VG_SER") or
              os.path.join(rd, "vm-serial-06.log"), "rb").read()
path = os.path.join(share, "SNAPSHOT.BUNDLE")
if not os.path.exists(path):
    sys.exit("no SNAPSHOT.BUNDLE on the share - the seat published nothing")
raw = open(path, "rb").read()
nl = raw.index(b"\n")
if raw[:nl] != b"#vb1 4":
    print("bundle header is %r, want b'#vb1 4' (settings+session+2 docs)" % raw[:nl])
    sys.exit(1)
m = re.search(rb"gotabwm: snapshot saved bytes=(\d+) entries=(\d+) docs=(\d+)", serial)
if not m:
    sys.exit("the seat printed no `snapshot saved` marker")
if int(m.group(1)) != len(raw):
    print("the marker claims %s bytes, the file is %d" % (m.group(1).decode(), len(raw)))
    sys.exit(1)
if (int(m.group(2)), int(m.group(3))) != (4, 2):
    print("marker says entries=%s docs=%s, want 4 and 2"
          % (m.group(2).decode(), m.group(3).decode()))
    sys.exit(1)
for name in (b"settings ", b"session ", b"docs/NOTE.TXT ", b"docs/SECOND.TXT "):
    if name not in raw:
        print("the bundle does not carry a %r entry" % name)
        sys.exit(1)
# And the two document BODIES are the seeded bytes: the capture really read
# /host/DOCS off the share rather than naming the entries and inventing them.
# (The documents' RESTORE is proven in go-selftest, where the guest rehydrates
# them and the host compares OUT/RESTORED/docs/* against the seeded inputs.)
rest = raw[raw.index(b"\n") + 1:]
for _ in range(4):
    eol = rest.index(b"\n")
    name, _, count = rest[:eol].partition(b" ")
    body = rest[eol + 1:eol + 1 + int(count)]
    rest = rest[eol + 1 + int(count):]
    if name == b"docs/NOTE.TXT" and body != b"m81g snapshot document one\n":
        print("the bundle's NOTE.TXT body is %r, not the seeded bytes" % body)
        sys.exit(1)
    if name == b"docs/SECOND.TXT" and body != b"m81g snapshot document two\n":
        print("the bundle's SECOND.TXT body is %r, not the seeded bytes" % body)
        sys.exit(1)
print("bundle on the share: %d bytes, header `#vb1 4`, entries settings+session"
      "+2 docs whose bodies are the seeded files (the marker agreed with the "
      "file)" % len(raw))
PY

# Boot 07: the drill's positive half. The seat finds the one-shot request,
# rehydrates the share, and the boot then reads the restored files through its
# ORDINARY paths — which is why no boot-07 assert is about a new code path.
#
# The script is anchored on `gotabwm: tokens theme=`, NOT left to run at
# monitor-ready: the seat's restore happens EARLY in its own life, and a script
# with no --script-after runs as soon as the console is up, which the first
# M81g run showed is BEFORE the seat gets there — the corruption landed at
# serial line 93 and the seat then refused its own snapshot at line 126. The
# token probe is printed unconditionally right after the settings decode, so it
# is both always-present and always after the restore.
vgate_file script-07.txt <<'EOF'
vf open SNAPSHOT.BUNDLE
vf truncate 0 0
vf write 0 64
vf close 0
vf open SNAPSHOT.RESTORE
vf write 0 1
vf close 0
echo rx-m81g-corrupt-staged
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --script '$RUN_DIR/script-07.txt' \
    --script-after 'gotabwm: tokens theme=' \
    --script-expect 'rx-m81g-corrupt-staged' --timeout 300

# The restore marker, printed only after the last publish returned.
vgate_assert 07 serial-contains 'gotabwm: snapshot restore bytes='
# The restored settings are what the seat HONORS: the theme probe reports the
# value the bundle carried, not the theme=dark the live file was left on.
vgate_assert 07 serial-contains 'gotabwm: tokens theme=light'
vgate_assert 07 serial-contains 'gotabwm: settings wm=gotabwm'
# Byte-exact: the whole file, not "a settings table that decodes the same".
vgate_assert 07 share-equals SETTINGS.TXT settings-snapshot.expected
# The seat's restore ran BEFORE this boot's script re-armed the request for
# boot 08 — which is the ordering that makes the one-shot property checkable
# at all. Boats 07 and 08 deliberately re-stage the request, so the FILE is
# legitimately present at their end; what has to hold is that the seat had
# already consumed it. Boot 09 is where the file's ABSENCE is the evidence.
vgate_assert 07 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
serial = open(os.environ.get("VG_SER") or
              os.path.join(rd, "vm-serial-07.log"), "rb").read().splitlines()
def line_of(needle):
    for i, l in enumerate(serial):
        if needle in l:
            return i
    sys.exit("the serial has no %r line" % needle)
restore = line_of(b"gotabwm: snapshot restore bytes=")
rearm = line_of(b"vf open SNAPSHOT.RESTORE")
if restore >= rearm:
    print("the restore is at serial line %d but the request was re-armed at %d - "
          "the corruption would have landed BEFORE the restore" % (restore, rearm))
    sys.exit(1)
print("restore (line %d) preceded this boot's re-arm of the request (line %d), "
      "so the seat had already consumed it" % (restore, rearm))
PY
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'
# 07's script then staged the corruption and re-armed the request for boot 08.
vgate_assert 07 serial-contains 'vf: open SNAPSHOT.BUNDLE h=0'
vgate_assert 07 serial-contains 'vf: truncate 0 size=0 ok'
vgate_assert 07 serial-contains 'vf: write 0 n=64 wrote=64 chunks=1'
vgate_assert 07 serial-contains 'rx-m81g-corrupt-staged'

# Boot 08: the refusal half, the M66b shape. A corrupt bundle is refused
# WHOLE — one line naming the reason, nothing written, and the boot continues
# on the live settings it already had.
vgate_file script-08.txt <<'EOF'
vf rm SNAPSHOT.BUNDLE
vf open SNAPSHOT.RESTORE
vf write 0 1
vf close 0
echo rx-m81g-absent-staged
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --script '$RUN_DIR/script-08.txt' \
    --script-after 'gotabwm: tokens theme=' \
    --script-expect 'rx-m81g-absent-staged' --timeout 300

vgate_assert 08 serial-contains 'gotabwm: snapshot bad header'
# A refusal is not a boot failure: the seat ran, and it ran on the settings
# that were already there.
vgate_assert 08 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 08 serial-contains 'gotabwm: registered'
vgate_assert 08 serial-contains 'gotabwm: tokens theme=light'
# Refused WHOLE: the live settings are exactly what boot 07 left there.
vgate_assert 08 share-equals SETTINGS.TXT settings-snapshot.expected
# Same ordering evidence as boot 07: the refusal is the seat's, and it happened
# before this boot's script re-armed the request for boot 09.
vgate_assert 08 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
serial = open(os.environ.get("VG_SER") or
              os.path.join(rd, "vm-serial-08.log"), "rb").read().splitlines()
def line_of(needle):
    for i, l in enumerate(serial):
        if needle in l:
            return i
    sys.exit("the serial has no %r line" % needle)
refusal = line_of(b"gotabwm: snapshot bad")
rearm = line_of(b"vf open SNAPSHOT.RESTORE")
if refusal >= rearm:
    print("the refusal is at serial line %d but the request was re-armed at %d"
          % (refusal, rearm))
    sys.exit(1)
print("refusal (line %d) preceded this boot's re-arm of the request (line %d)"
      % (refusal, rearm))
PY
vgate_assert 08 serial-absent 'gotabwm: snapshot restore'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'
vgate_assert 08 serial-contains 'rx-m81g-absent-staged'

# Boot 09: the absent half. Different diagnosis, same outcome — nothing is
# written and the boot is normal.
vgate_file script-09.txt <<'EOF'
echo rx-m81g-absent-ok
EOF

vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --script '$RUN_DIR/script-09.txt' \
    --script-after 'gotabwm: snapshot missing' \
    --script-expect 'rx-m81g-absent-ok' --timeout 300

vgate_assert 09 serial-contains 'gotabwm: snapshot missing'
# A missing bundle is NOT a corrupt one: the two lines must not be confused.
vgate_assert 09 serial-absent 'gotabwm: snapshot bad'
vgate_assert 09 serial-absent 'gotabwm: snapshot restore'
vgate_assert 09 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 09 share-equals SETTINGS.TXT settings-snapshot.expected
vgate_assert 09 serial-contains 'rx-m81g-absent-ok'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'
# The one-shot property, where the file's ABSENCE is the evidence: boot 08's
# script armed this request, boot 09's seat consumed it while refusing the
# absent bundle, and boot 09's own script arms nothing — so a request left on
# the share would mean the seat does not consume it, and a bad bundle could
# refuse on every later boot.
vgate_assert 09 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
if os.path.exists(os.path.join(share, "SNAPSHOT.RESTORE")):
    sys.exit("SNAPSHOT.RESTORE is still on the share after boot 09 consumed it "
             "- the request is not one-shot")
print("the restore request is a ONE-SHOT: consumed by the boot 09 refusal, "
      "and boot 09 armed nothing, so it is gone from the share")
PY

# Between-run pin for boot 10 (M120b #2559): the session file a boot
# restores is LIVE now — every backed row re-execs — so the file is staged
# deterministically here rather than inherited from whichever write the
# earlier boots happened to leave. One Calc row, the same `.tabs` v2
# encoding live-vz-restore's fixture writes: the boot's `session load`
# marker still fires, the starter stays suppressed, and the re-exec itself
# provides the subscribed calculator the proof needs — a scripted second
# exec would double it (gocalc: open id= is asserted exactly once).
vgate_assert 09 python <<'PY'
import os
share = os.environ["VG_SHARE"]
session = (bytes([2, 1, 1, 0, 0, 0]) +
           b"Calc".ljust(32, b"\0") + bytes([0]) + bytes(12) +
           b"GOCALC.ELF".ljust(24, b"\0"))
with open(os.path.join(share, "SESSION.TABS"), "wb") as f:
    f.write(session)
print("between-run pin: SESSION.TABS = one backed Calc row for boot 10 "
      "(restored session -> live re-exec, not a scripted duplicate)")
PY

# --- M82b (#1769): settings broadcast reaches a live second app -------------
# A persisted session means the rebooted default seat does not auto-open the
# first-boot GOSH workspace — and under M120b the restore's own re-exec is
# what puts GOCALC on the strip, subscribed to theme. GOSET is the second
# app, scripted as before: it writes theme=light while GOCALC remains live.
# SETTINGS.TXT is still the persistent source of truth; the WM_RPC notice
# only names the changed key.
vgate_file script-10.txt <<'EOF'
settings set wm gotabwm
settings set keyboard_layout us
settings set theme dark
reboot
EOF

vgate_file script-10-seat.txt <<'EOF'
dui focus 0
EOF

vgate_file script-10-publish.txt <<'EOF'
exec GOSET.ELF
EOF

vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --via-virtio \
    --script '$RUN_DIR/script-10.txt' \
    --script2 '$RUN_DIR/script-10-seat.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-string $'theme=light\n' \
    --input-string-after 'goset: ready ' \
    --script3 '$RUN_DIR/script-10-publish.txt' \
    --script3-after 'gocalc: settings subscribed key=theme' \
    --script-expect 'gocalc: settings repaint key=theme value=light' \
    --script-expect-tail 30 --timeout 420

vgate_assert 10 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 10 serial-contains 'gotabwm: settings wm=gotabwm'
vgate_assert 10 serial-contains 'gotabwm: session load n='
vgate_assert 10 serial-absent 'gotabwm: first-boot workspace'
# M122b (#2571): a restored strip replays what it recorded — the tour is
# first-boot-only, never re-added on a restored boot.
vgate_assert 10 serial-absent 'gotabwm: welcome tour'
vgate_assert 10 serial-absent 'gowelcome: open id='
# The restore's re-exec, not a monitor exec, is what loads GOCALC now
# (M120b): the kernel's `exec: loaded` marker belongs to scripted execs,
# while the seat names every bin it fans back out.
vgate_assert 10 serial-contains 'gotabwm: session exec GOCALC.ELF'
vgate_assert 10 serial-contains 'gocalc: settings subscribed key=theme'
vgate_assert 10 serial-contains 'exec: loaded GOSET.ELF'
vgate_assert 10 serial-contains 'goset: set theme=light'
vgate_assert 10 serial-contains 'goset: saved '
vgate_assert 10 serial-contains 'gotabwm: settings subscribe pid='
vgate_assert 10 serial-contains 'gotabwm: settings broadcast key=theme listeners=1'
vgate_assert 10 serial-contains 'gocalc: settings repaint key=theme value=light'
vgate_assert 10 serial-absent 'gocalc: close'
vgate_assert 10 serial-absent 'gocalc OK'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 serial-absent 'exited status=139'
vgate_assert 10 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
patterns = [
    "gocalc: settings subscribed key=theme",
    "goset: set theme=light",
    "goset: saved ",
    "gotabwm: settings broadcast key=theme listeners=1",
    "gocalc: settings repaint key=theme value=light",
]
positions = [ser.find(p) for p in patterns]
if any(p < 0 for p in positions) or positions != sorted(positions):
    sys.exit("settings propagation out of order: " + repr(list(zip(patterns, positions))))
if ser.count("gocalc: open id=") != 1:
    sys.exit("calculator restarted: saw %d open markers" % ser.count("gocalc: open id="))
if not re.search(r"gotabwm: settings broadcast key=theme listeners=1", ser):
    sys.exit("seat did not deliver to exactly one subscriber")
print("settings publication reached one live subscriber and repainted without restart")
PY

# M83f (#1779): one typed GOSET edit, one safe publish, then a fresh boot
# reads the value. Boot 01 keeps its proven wm/layout choreography; running a
# second HID line there loses the first stroke on this input transport. This
# separate boot avoids confusing a transport race with settings persistence.
vgate_file script-11-focus.txt <<'EOF'
dui focus 0
EOF

vgate_file script-11-panel.txt <<'EOF'
set GOMAXPROCS=1
exec GOSET.ELF
EOF

vgate_run 11 -- \
    --screen '$RUN_DIR/screen-11' \
    --via-virtio \
    --script '$RUN_DIR/script-11-focus.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script-11-panel.txt' \
    --script2-after 'gotabwm: win gone' \
    --input-string $'idle_minutes=7\n' \
    --input-string-after 'goset: ready ' \
    --script-expect 'goset: saved keys=13 wm=gotabwm theme=light' \
    --script-expect-tail 10 --timeout 300

vgate_assert 11 serial-contains 'goset: ready keys=13 wm=gotabwm theme=light mode=rw'
vgate_assert 11 serial-contains 'goset: set idle_minutes=7'
vgate_assert 11 serial-contains 'goset: saved keys=13 wm=gotabwm theme=light'
vgate_assert 11 share-contains SETTINGS.TXT 'idle_minutes=7'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 serial-absent 'exited status=139'

vgate_file script-12.txt <<'EOF'
settings get idle_minutes
echo rx-m83f-persisted
EOF

vgate_run 12 -- \
    --screen '$RUN_DIR/screen-12' \
    --script '$RUN_DIR/script-12.txt' \
    --script-expect 'rx-m83f-persisted' --timeout 300

vgate_assert 12 serial-contains 'settings: idle_minutes=7'
vgate_assert 12 share-contains SETTINGS.TXT 'idle_minutes=7'
vgate_assert 12 serial-contains 'rx-m83f-persisted'
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 serial-absent 'exited status=139'

# --- M82d2 (#1785): notifications policy, the persisted halves --------------
# Boots 13-16 prove what a restart must not lose or resurrect wrongly.
#
#   13  one typed GOSET edit, `notify_dnd=on`: a safe publish, and the LIVE
#       seat applies it without a restart (`via=settings`).
#   14  a fresh boot reads the persisted key (`via=boot`, printed only when it
#       is ON, so a default boot's log is unchanged) before the loop. The
#       script then stages a corrupt NOTIFY.HIST with the monitor's vf verbs,
#       the M66b boot-03 shape: 64 probe-pattern bytes, no valid header.
#   15  boots on the corrupt history. The seat refuses it WHOLE (`history
#       bad`, nothing restored) and heals it at once with a valid empty one
#       (`history healed`) -- BEFORE the first composite paint, so there is no
#       frame that ever showed a half-trusted history. The healed bytes are
#       byte-compared on the host.
#   16  the boot after the heal restores the empty history cleanly and says
#       nothing is wrong: a bad file costs the user their history once, and is
#       never re-reported.
#
# The seat's history file is /host/NOTIFY.HIST, written through the same
# crash-safe publish as SETTINGS.TXT (temp + fsync + delete/rename); a stale
# NOTIFY.HIST~ on the share after a publish would mean the rename never ran.

# The empty history the heal publishes, computed on the host from the codec's
# documented layout: magic "VNH" + version 1, a zero count, then the FNV-1a 32
# of those five bytes, little-endian (user/go/gotabwm/notify_policy.go).
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
body = b"VNH\x01\x00"
h = 2166136261
for c in body:
    h ^= c
    h = (h * 16777619) & 0xffffffff
with open(os.path.join(rd, "notify-empty.expected"), "wb") as dst:
    dst.write(body + h.to_bytes(4, "little"))
PY

vgate_file script-13-focus.txt <<'EOF'
dui focus 0
EOF

vgate_file script-13-panel.txt <<'EOF'
set GOMAXPROCS=1
exec GOSET.ELF
EOF

vgate_run 13 -- \
    --screen '$RUN_DIR/screen-13' \
    --via-virtio \
    --script '$RUN_DIR/script-13-focus.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script-13-panel.txt' \
    --script2-after 'gotabwm: win gone' \
    --input-string $'notify_dnd=on\n' \
    --input-string-after 'goset: ready ' \
    --script-expect 'gotabwm: notify dnd=on via=settings' \
    --script-expect-tail 10 --timeout 300

vgate_assert 13 serial-contains 'goset: ready keys=13 wm=gotabwm theme=light mode=rw'
vgate_assert 13 serial-contains 'goset: set notify_dnd=on'
vgate_assert 13 serial-contains 'goset: saved keys=13 wm=gotabwm theme=light'
vgate_assert 13 share-contains SETTINGS.TXT 'notify_dnd=on'
# The seat applied the published value live, and told any subscriber.
vgate_assert 13 serial-contains 'gotabwm: notify dnd=on via=settings'
vgate_assert 13 serial-contains 'gotabwm: settings broadcast key=notify_dnd listeners=0'
# The control: the boot itself read no DND (the key was default-off), and a
# boot that received no notice has no history to report -- a default boot's
# log is unchanged by the policy.
vgate_assert 13 serial-absent 'gotabwm: notify dnd=on via=boot'
vgate_assert 13 serial-absent 'gotabwm: notify history'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 serial-absent 'exited status=139'
vgate_assert 13 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
patterns = [
    "goset: set notify_dnd=on",
    "goset: saved ",
    "gotabwm: notify dnd=on via=settings",
]
positions = [ser.find(p) for p in patterns]
if any(p < 0 for p in positions) or positions != sorted(positions):
    sys.exit("DND publication out of order: " + repr(list(zip(patterns, positions))))
print("notify_dnd: typed edit -> safe save -> live seat applied it, in that order")
PY

vgate_file script-14.txt <<'EOF'
settings get notify_dnd
vf open NOTIFY.HIST
vf write 0 64
vf close 0
echo rx-m82d2-history-staged
EOF

# Anchored on the mode marker, which the seat prints AFTER its DND read and its
# history load: the corruption below can only land on a seat that has already
# looked, so this boot reports a MISSING history (silent) and boot 15 is the
# one that meets the bad bytes.
vgate_run 14 -- \
    --screen '$RUN_DIR/screen-14' \
    --script '$RUN_DIR/script-14.txt' \
    --script-after 'gotabwm: mode ' \
    --script-expect 'rx-m82d2-history-staged' --timeout 300

vgate_assert 14 serial-contains 'settings: notify_dnd=on'
vgate_assert 14 serial-contains 'gotabwm: notify dnd=on via=boot'
vgate_assert 14 serial-contains 'vf: open NOTIFY.HIST h=0'
vgate_assert 14 serial-contains 'vf: write 0 n=64 wrote=64 chunks=1'
vgate_assert 14 serial-contains 'vf: close 0 ok'
vgate_assert 14 serial-contains 'rx-m82d2-history-staged'
# No history existed, so the seat said nothing about one and wrote nothing.
vgate_assert 14 serial-absent 'gotabwm: notify history'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 serial-absent 'exited status=139'
vgate_assert 14 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def line_of(prefix):
    for i, l in enumerate(ser):
        if prefix in l:
            return i
    sys.exit("the serial has no %r line" % prefix)
dnd = line_of("gotabwm: notify dnd=on via=boot")
mode = line_of("gotabwm: mode ")
stage = line_of("vf: open NOTIFY.HIST")
if not dnd < mode < stage:
    sys.exit("boot 14 order: dnd read %d, mode %d, corruption staged %d" % (dnd, mode, stage))
share = os.environ["VG_SHARE"]
size = os.path.getsize(os.path.join(share, "NOTIFY.HIST"))
if size != 64:
    sys.exit("NOTIFY.HIST is %d bytes, want the 64 staged probe bytes" % size)
print("DND read from the persisted key (line %d) before the loop (mode line %d); "
      "the 64-byte corrupt history was staged after the seat's look (line %d)"
      % (dnd, mode, stage))
PY

# The run must reach the seat's first PRESENT before it ends, or the "healed
# before the first paint" order below has nothing to compare: the run ends on
# its own marker, and a seat still holding its startup probe never ticks (boot
# 01's `dui focus 0`, phase one, is what lets the composite loop start). So
# phase one hands focus away, phase two waits for the first present.
vgate_file script-15-focus.txt <<'EOF'
dui focus 0
EOF

vgate_file script-15.txt <<'EOF'
echo rx-m82d2-heal-ok
EOF

vgate_run 15 -- \
    --screen '$RUN_DIR/screen-15' \
    --script '$RUN_DIR/script-15-focus.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script-15.txt' \
    --script2-after 'gotabwm: present' \
    --script-expect 'rx-m82d2-heal-ok' --timeout 300

# Refused WHOLE, then healed: one honest line each, nothing restored.
vgate_assert 15 serial-contains 'gotabwm: notify history bad'
vgate_assert 15 serial-contains 'gotabwm: notify history healed'
vgate_assert 15 serial-contains 'gotabwm: notify history write n=0'
vgate_assert 15 serial-absent 'gotabwm: notify history restore'
vgate_assert 15 serial-absent 'gotabwm: notify history write fail'
# A bad history is not a boot failure: the seat ran, on the DND the settings
# file carries.
vgate_assert 15 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 15 serial-contains 'gotabwm: notify dnd=on via=boot'
vgate_assert 15 serial-contains 'rx-m82d2-heal-ok'
vgate_assert 15 serial-absent '[EXC] parking:'
vgate_assert 15 serial-absent 'exited status=139'
# The healed file, byte-exact: a valid EMPTY history, never a partial one.
vgate_assert 15 share-equals NOTIFY.HIST notify-empty.expected
vgate_assert 15 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def line_of(prefix):
    for i, l in enumerate(ser):
        if prefix in l:
            return i
    sys.exit("the serial has no %r line" % prefix)
bad = line_of("gotabwm: notify history bad")
healed = line_of("gotabwm: notify history healed")
mode = line_of("gotabwm: mode ")
tick = line_of("gotabwm: tick")
present = line_of("gotabwm: present")
if not bad < healed < mode:
    sys.exit("refuse/heal order: bad %d, healed %d, mode %d" % (bad, healed, mode))
if not healed < tick or not healed < present:
    sys.exit("the heal (line %d) did not precede the first tick (%d) / present (%d)"
             % (healed, tick, present))
share = os.environ["VG_SHARE"]
if os.path.exists(os.path.join(share, "NOTIFY.HIST~")):
    sys.exit("NOTIFY.HIST~ survived the publish - the rename did not run")
print("history refused (line %d) and healed (line %d) before the first paint "
      "(tick line %d, present line %d); no NOTIFY.HIST~ left on the share"
      % (bad, healed, tick, present))
PY

vgate_file script-16.txt <<'EOF'
echo rx-m82d2-healed-ok
EOF

vgate_run 16 -- \
    --screen '$RUN_DIR/screen-16' \
    --script '$RUN_DIR/script-16.txt' \
    --script-after 'gotabwm: mode ' \
    --script-expect 'rx-m82d2-healed-ok' --timeout 300

# The healed file is a valid history like any other: restored, silent about
# trouble, and left untouched.
vgate_assert 16 serial-contains 'gotabwm: notify history restore n=0'
vgate_assert 16 serial-absent 'gotabwm: notify history bad'
vgate_assert 16 serial-absent 'gotabwm: notify history healed'
vgate_assert 16 serial-absent 'gotabwm: notify history write'
vgate_assert 16 serial-contains 'gotabwm: notify dnd=on via=boot'
vgate_assert 16 serial-contains 'rx-m82d2-healed-ok'
vgate_assert 16 serial-absent '[EXC] parking:'
vgate_assert 16 serial-absent 'exited status=139'
vgate_assert 16 share-equals NOTIFY.HIST notify-empty.expected

# --- M83c (#1776): the timezone row persists -------------------------------
# Boots 17/18 are the idle_minutes pair's shape: one typed GOSET edit, one
# safe publish, then a fresh boot reads the row back through the kernel's
# `settings get`. The value is a fixed offset with the canonical label
# clockfmt parses; a mistyped one is refused by the panel before it can
# reach the file (host-tested in user/go/goset), so nothing here stages a
# bad value.
vgate_file script-17-focus.txt <<'EOF'
dui focus 0
EOF

vgate_file script-17-panel.txt <<'EOF'
set GOMAXPROCS=1
exec GOSET.ELF
EOF

vgate_run 17 -- \
    --screen '$RUN_DIR/screen-17' \
    --via-virtio \
    --script '$RUN_DIR/script-17-focus.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script-17-panel.txt' \
    --script2-after 'gotabwm: win gone' \
    --input-string $'timezone=UTC+05:30\n' \
    --input-string-after 'goset: ready ' \
    --script-expect 'goset: saved keys=13 wm=gotabwm theme=light' \
    --script-expect-tail 10 --timeout 300

vgate_assert 17 serial-contains 'goset: ready keys=13 wm=gotabwm theme=light mode=rw'
vgate_assert 17 serial-contains 'goset: set timezone=UTC+05:30'
vgate_assert 17 serial-contains 'goset: saved keys=13 wm=gotabwm theme=light'
vgate_assert 17 share-contains SETTINGS.TXT 'timezone=UTC+05:30'
vgate_assert 17 serial-absent '[EXC] parking:'
vgate_assert 17 serial-absent 'exited status=139'

vgate_file script-18.txt <<'EOF'
settings get timezone
echo rx-m83c-tz-persisted
EOF

vgate_run 18 -- \
    --screen '$RUN_DIR/screen-18' \
    --script '$RUN_DIR/script-18.txt' \
    --script-expect 'rx-m83c-tz-persisted' --timeout 300

vgate_assert 18 serial-contains 'settings: timezone=UTC+05:30'
vgate_assert 18 share-contains SETTINGS.TXT 'timezone=UTC+05:30'
vgate_assert 18 serial-contains 'rx-m83c-tz-persisted'
vgate_assert 18 serial-absent '[EXC] parking:'
vgate_assert 18 serial-absent 'exited status=139'

# M91: a fresh first workspace on the compiled default, in live mode.
# Only gate-owned settings/session/demo/history state from boots 01-18 is
# removed. No script drives startup focus, no explicit seat exec, no wm key.
vgate_assert 18 python <<'PY'
import os, pathlib, shutil
share = pathlib.Path(os.environ["VG_SHARE"])
fixture = pathlib.Path("tests/fixtures/desktop/m91")
for name in ("SETTINGS.TXT", "SESSION.TABS", "GOTABWM.DEMO", "NOTIFY.HIST",
             "HISTORY", "STARTUP.SH", "PROFILE.SH", "M91-1925.RECEIPT"):
    (share / name).unlink(missing_ok=True)
shutil.copyfile(fixture / "terminal.sh", share / "M91-WORKFLOW.SH")
(share / "EDIT").mkdir(exist_ok=True)
shutil.copyfile(fixture / "editor.txt", share / "EDIT/SEED.TXT")
assert not (share / "SETTINGS.TXT").exists()
assert not (share / "SESSION.TABS").exists()
assert not (share / "GOTABWM.DEMO").exists()
print("M91: absent settings/session/demo; only fixture inputs staged, no receipt")
PY

# VMRunner enables its injected-input watchers in script mode. This
# observation-only echo starts AFTER the first workspace, never unblocks it.
vgate_file script-m91-observe.txt <<'EOF'
echo m91-fixture-ready
EOF
vgate_run 19 -- \
    --screen '$RUN_DIR/screen-19' --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-m91-observe.txt' --script-after 'gosh: prompt' \
    --snapshot-after 'gotabwm: launcher presented' \
    --snapshot-out '$RUN_DIR/menu-19' \
    --pointer-virtio '272,702,c' \
    --pointer-virtio-after 'gosh: prompt' \
    --input-chords 'g,o,t,e,r,m,return' \
    --input-chords-after 'gotabwm: launcher presented' \
    --input-string $'source /host/M91-WORKFLOW.SH\n' \
    --input-string-after 'goterm: prompt' \
    --script-expect 'goterm: done status=0' --script-expect-tail 4 --timeout 180
vgate_assert 19 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 19 serial-contains 'gotabwm: mode live'
vgate_assert 19 serial-contains 'gotabwm: first-boot workspace'
# M122b (#2571): the live first-boot workspace opens the welcome tour
# beside GOSH — the seat's exec marker plus the app's own open/declare/
# present markers prove the surface painted.
vgate_assert 19 serial-contains 'gotabwm: welcome tour'
vgate_assert 19 serial-contains 'gowelcome: open id='
vgate_assert 19 serial-contains 'gowelcome: declare accepted'
vgate_assert 19 serial-contains 'gowelcome: present'
vgate_assert 19 serial-contains 'gosh: declare accepted'
vgate_assert 19 serial-contains 'gosh: prompt'
vgate_assert 19 serial-exact 'gotabwm: launcher exec GOTERM.ELF' 1
vgate_assert 19 serial-contains 'goterm: declare accepted'
vgate_assert 19 serial-contains 'goterm: attached'
vgate_assert 19 serial-contains 'goterm: line source /host/M91-WORKFLOW.SH'
vgate_assert 19 serial-contains 'goterm: done status=0'
vgate_assert 19 serial-absent 'gotabwm: launcher exec GOEDIT.ELF'
vgate_assert 19 serial-absent 'gotabwm: reorder '
vgate_assert 19 serial-absent 'dui: term sel '
vgate_assert 19 serial-absent '[EXC] parking:'
vgate_assert 19 serial-absent 'exited status=139'
vgate_assert 19 python <<'PY'
import os, pathlib, re, shutil
share = pathlib.Path(os.environ["VG_SHARE"])
s = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
assert "exec GOTABWM.ELF" not in s and "dui focus" not in s, "hidden startup workaround"
opened = re.search(r"goterm: open id=(\d+)", s)
assert opened and "gotabwm: host focus id=" + opened[1] in s, "Terminal not focused"
assert s.count("gotabwm: launcher exec ") == 1, "double launch"
expected = pathlib.Path("tests/fixtures/desktop/m91/receipt.expected").read_bytes()
got = (share / "M91-1925.RECEIPT").read_bytes()
assert got == expected, (got, expected)
out = pathlib.Path("artifacts/m91-workflow")
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
(out / ("receipt-after-stop" + suffix)).write_bytes(got)
(out / ("receipt.expected" + suffix)).write_bytes(expected)
shutil.copyfile(os.environ["VG_SER"], out / ("terminal" + suffix + ".log"))
print("independent host byte comparison after VM stop: receipt matches")
PY
vgate_assert 19 snapshot 'menu-19-*.raw' <<'PY'
import os, runpy, sys
runpy.run_path("tests/fixtures/desktop/m91/menu.py")["check"](
    sys.argv[1], "artifacts/m91-workflow/default-menu" +
    os.environ.get("VIRELAI_GATE_SUFFIX", "") + ".png")
PY

# Relaunch on the SAME share, without touching the receipt or changing wm.
# Restored tabs re-exec their recorded bins now (M120b #2559): boot 19's
# [Sh, Term] file drops the unbacked Sh row and spawns a real GOTERM.ELF
# into rail cell 1 — so NO scripted Terminal runs at all (the re-exec'd
# one reads the receipt), and the focus-back chord is ctrl-1, not the old
# placeholder-strip ctrl-3. A scripted second term also costs a task-pool
# slot the boot cannot spare: observed r20 — seat + restored Term +
# scripted Term left GOEDIT's runtime unable to make an M
# (`newosproc: sys_thread create failed`, no `goedit: present`).
# The editor is opened by CLICKING its launcher row, not by filtering:
# script2 feeds the kernel monitor (observed r20: `unknown command
# 'goedit'` — filter text is HID input, and every HID channel this boot
# already owns is spoken for), and the stray 800,400 release was harmless
# only while dead placeholder rows sat under it — on a live strip it is a
# real press that rips keyboard focus off the launcher sink. GOEDIT sits
# at catalog row 2 of this fixture's 18-row APPS.TXT (0=GOCALC, 1=NOTE):
# the 264px panel paints rows at x=8..253, y=140+i*24 — a down at
# (120,199) lands inside row 2's rect (y=188..209).
vgate_file script-m91-relaunch.txt <<'EOF'
set GOMAXPROCS=1
EOF

vgate_run 20 -- \
    --screen '$RUN_DIR/screen-20' --via-virtio \
    --script '$RUN_DIR/script-m91-relaunch.txt' \
    --script-after 'gotabwm: present' \
    --input-string $'cat /host/M91-1925.RECEIPT\n' \
    --input-string-after 'goterm: prompt' \
    --pointer-virtio '272,702,d;272,702,u;120,199,d;120,199,u' \
    --pointer-virtio-after 'goterm: done status=0' \
    --input-chords 'w,o,r,k,e,d,return,ctrl-s,ctrl-1' \
    --input-chords-after 'goedit: present' \
    --script-expect 'gotabwm: alt-tab id=' --script-expect-tail 4 --timeout 180
vgate_assert 20 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 20 serial-contains 'gotabwm: mode live'
vgate_assert 20 serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert 20 serial-contains 'goterm: line cat /host/M91-1925.RECEIPT'
vgate_assert 20 serial-contains 'goterm: done status=0'
vgate_assert 20 serial-exact 'gotabwm: launcher exec GOEDIT.ELF' 1
vgate_assert 20 serial-contains 'goedit: dirty'
vgate_assert 20 serial-contains 'goedit: saved /host/EDIT/SEED.TXT n=23'
vgate_assert 20 serial-absent '[EXC] parking:'
vgate_assert 20 serial-absent 'exited status=139'
vgate_assert 20 python <<'PY'
import os, pathlib, re, shutil
share = pathlib.Path(os.environ["VG_SHARE"])
fixture = pathlib.Path("tests/fixtures/desktop/m91")
got = (share / "M91-1925.RECEIPT").read_bytes()
assert got == (fixture / "receipt.expected").read_bytes(), "receipt changed across relaunch"
edited = (share / "EDIT/SEED.TXT").read_bytes()
assert edited == (fixture / "editor.expected").read_bytes(), edited
s = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
terms = re.findall(r"goterm: open id=(\d+)", s)
# M120b (#2559): the session re-execs boot 19's Term row AND the script
# execs another, so either of the two Terminal windows is a legal focus
# target for the final chord.
assert terms and any(("gotabwm: alt-tab id=" + t) in s for t in terms), \
    "focus did not return to a real Terminal"
assert s.index("goedit: dirty") < s.index("goedit: saved") < s.index("gotabwm: alt-tab id=")
out = pathlib.Path("artifacts/m91-workflow")
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
(out / ("receipt-after-relaunch" + suffix)).write_bytes(got)
(out / ("editor-saved" + suffix)).write_bytes(edited)
shutil.copyfile(os.environ["VG_SER"], out / ("editor" + suffix + ".log"))
print("guest read on relaunch; independent host receipt and editor comparisons match")
PY

# --- M132b (#2753) run 21: a reserved manifest row refuses its launch by name
#
# APPS.TXT now carries the nine M140-M148 reservation rows; their binaries
# ship with the app cards. The launcher decodes all 29 rows (the decode
# receipt and the open count name it), and a click on a row whose binary
# the share lacks is a NAMED refusal, not a silent death — the same shape
# go-wm-seat run 17 pins for a deleted binary. GOCLOCK.ELF is staged
# between boots so the availability probe admits the row at open, then
# `vf rm` removes it behind the 'launcher open' marker — the click execs
# into ENOENT and prints the seat's missing-binary marker.
vgate_assert 20 python <<'PY'
import os, shutil
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(share, "GOCALC.ELF")
dst = os.path.join(share, "GOCLOCK.ELF")
shutil.copyfile(src, dst)
print("M132b: staged GOCLOCK.ELF (%d bytes) for the reserved-row refusal leg"
      % os.path.getsize(dst))
PY

vgate_file script-21.txt <<'EOF'
echo rx-m132b-ready
EOF

vgate_file script2-21.txt <<'EOF'
vf rm GOCLOCK.ELF
EOF

vgate_run 21 -- \
    --screen '$RUN_DIR/screen-21' --via-virtio \
    --script '$RUN_DIR/script-21.txt' \
    --script-after 'gotabwm: mode live' \
    --input-chords 'ctrl-space,g,o,c,l,o,c,k,return' \
    --input-chords-after 'gotabwm: present' \
    --script2 '$RUN_DIR/script2-21.txt' \
    --script2-after 'gotabwm: launcher open n=' \
    --script-expect 'gotabwm: launcher missing GOCLOCK.ELF' --timeout 300

vgate_assert 21 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 21 serial-contains 'gotabwm: mode live'
# The live decode: all 29 manifest rows — shipped and reserved — are in
# the seat's catalog, schema v2, 8 docked (the host-side APPS.TXT check
# on boot 01 pins the file half).
vgate_assert 21 serial-contains 'gotabwm: apps decode n=29 v=2 schema=2'
vgate_assert 21 serial-contains 'gotabwm: launcher open n=29'
vgate_assert 21 serial-contains 'gotabwm: launcher filter q=goclock n=1'
# The named refusal: the reserved row's exec was attempted and refused by
# name — the launcher's existing missing-binary marker plus the refusal
# toast's errno line.
vgate_assert 21 serial-contains 'gotabwm: launcher missing GOCLOCK.ELF'
vgate_assert 21 serial-contains 'gotabwm: refusal ENOENT exec GOCLOCK.ELF act=retry'
vgate_assert 21 serial-absent 'exec: loaded GOCLOCK.ELF'
vgate_assert 21 serial-absent 'gotabwm: launcher exec GOCLOCK.ELF'
vgate_assert 21 serial-absent '[EXC] parking:'
vgate_assert 21 serial-absent 'exited status=139'
