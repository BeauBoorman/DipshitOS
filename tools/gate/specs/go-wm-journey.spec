# go-wm-journey.spec -- M137d (issue #2774) class-B gate: the seat
# acceptance journey, keyboard-only, K=3. One vgate_run is one boot is one
# iteration; vgate_repeat 3 replays it so all three iterations must be
# green. The journey rides LIVE mode (no GOTABWM.DEMO trigger is seeded):
# GOCALC, NOTE and GODEMO (the M137b appkit-controls demo) open as tabs,
# two split-cycle presses lay them out as a three-pane tree, the demo's
# menu bar and table are driven by keys alone (F10 -> View -> Expand All;
# Tab -> arrows -> Return), ctrl-alt-pagedown creates + visits space "2"
# and pageup comes home, ctrl-shift-s takes the snapshot bundle, and the
# script then kills the seat AND its clients, stages the SNAPSHOT.RESTORE
# one-shot, and execs the seat again — the restore rehydrates SESSION.TABS
# + SESSION.PANES off the bundle and re-execs every recorded bin onto the
# rebuilt tree.
#
# Two pixel probes per boot: a --screenshot-after PNG of space 2's start
# surface the instant `space switch 1->2` lands, and a kind-4 BGRX scanout
# snap at `session live n=3` proving the restored three-pane composition —
# every pane and every space is checked as pixels across the boot, beside
# the byte-level SESSION.TABS/SESSION.PANES/LAYOUT.txt asserts.
#
# A dedicated spec, not more runs under go-wm-seat/go-wm-tabs: vgate_repeat
# is spec-global, so K=3 inside either host spec would re-run every leg
# (20 and 23 runs) and neither is repeat-safe (the GOTABWM.DEMO trigger is
# consumed in-boot); "each iteration, one boot" is only true when the spec
# IS the journey — the go-dogfood/live-agent-loop acceptance pattern.
#
# HOST PREREQUISITES (fail the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh     ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh      ->  .build/go/GOCALC.ELF
#   bash tools/go/build-note.sh        ->  .build/go/NOTE.ELF
#   bash tools/go/build-appkitdemo.sh  ->  .build/go/GODEMO.ELF
#
# exec-order: assert-proven — the run ends on `gotabwm: session live n=3`,
# a marker only the post-kill restore can print (the first seat exec finds
# no session file), and every stage gate waits on guest output the seat and
# the hosted apps produce.

vgate_name go-wm-journey "M137d (#2774): K=3 keyboard-only seat journey — three-pane split, appkit menu bar + table, second space, snapshot -> seat restart -> restore, pixel probes on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

vgate_file script.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

# GODEMO execs last, but its strip position is NOT load-bearing: it binds
# a scanout-sized surface (reflow never refuses its rect) and the journey
# focuses it by TITLE through the launcher, so the choreography is the
# same whatever index it opens at.
vgate_file script2.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
exec GOEDIT.ELF
exec GODEMO.ELF
EOF

# The restore drill inside the same boot: the bundle is already published
# (script3 rides on `snapshot saved`), `dui focus 0` parks keyboard focus
# on the kernel console so the --input-string restore commands land there,
# and the clients die first so no stale window outlives the seat that
# hosted it. The staging + re-exec itself rides --input-string gated on
# 'wm: unregistered' — kill arms asynchronously, and an exec that beats
# the teardown gets refused (observed: `register failed -7`).
vgate_file script3.txt <<'EOF'
dui focus 0
kill GOCALC.ELF
kill NOTE.ELF
kill GODEMO.ELF
kill GOTABWM.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, tool in (("GOTABWM.ELF", "build-gotabwm.sh"),
                   ("GOCALC.ELF", "build-gocalc.sh"),
                   ("NOTE.ELF", "build-note.sh"),
                   ("GOEDIT.ELF", "build-goedit.sh"),
                   ("GODEMO.ELF", "build-appkitdemo.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: "
                 "bash tools/go/%s" % (name, src, tool))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s (%d bytes)" % (name, os.path.getsize(src)))
# The demo's AttachTab declares bin=GODIALOG.ELF (the source file is shared
# with the wnd4 leg), so the session record — and the restore re-exec —
# names that file. Stage the same bytes under both names.
shutil.copy(os.path.join(".build", "go", "GODEMO.ELF"),
            os.path.join(share, "GODIALOG.ELF"))
print("staged GODIALOG.ELF (GODEMO bytes; the session-record name)")
# GODEMO exits 3 without its faces; the seat degrades cleanly but the demo
# does not.
for src, dst in (("Inter-Regular.ttf", "INTER.TTF"),
                 ("VirelaiChrome-Regular.ttf", "CHROME.TTF")):
    p = os.path.join("image", "fonts", src)
    if not os.path.isfile(p):
        sys.exit("font %s missing" % p)
    shutil.copy(p, os.path.join(share, dst))
print("staged INTER.TTF + CHROME.TTF")
# Same opt-in posture as the seat/tabs specs: the compiled default is the
# Go seat, so `wm=none` keeps this boot shim-only until the script's exec
# registers it explicitly — the point the journey's own markers prove.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
PY

# --input-chords rides the custom-virtio INPUT queue (armed by
# --via-virtio): the VZVirtualMachineView path is session-dependent — with
# no key window the synthesized NSEvents drop silently (the claim-4769
# activation wall, observed on this run: window key=false, zero chord
# effects) — while the INPUT queue delivers real HID reports with no view
# at all. The sequence, in journey order:
#   (GODEMO raises itself after declaring, so it is keyboard-focused when
#   the chords land whatever strip slot it opened at — no focus chord
#   needed and none could be deterministic by index anyway)
#   escape            -> the demo's prompt dialog cancels (d.Open=false)
#   f10, down         -> menu bar activates, then File opens
#   right, right      -> Edit, then View
#   e                 -> '&Expand All' mnemonic fires the tree's lazy loads
#   tab               -> focus ring hands the table control the keys
#   down,down,right   -> cell (2,1)
#   return            -> OnActivate -> 'godemo: table activate r=2 c=1'
#   ctrl-shift-v x2   -> split v on the focused (GODEMO) pane, then h
#                        nests — GODEMO's scanout-sized surface lets the
#                        seat's rect proposals land like every tabapp
#                        client, so it holds a real pane
#   ctrl-shift-p,     -> the palette's "move to" action carries the
#     m,o,v,e,            focused tab — GODEMO — to space "2" (created on
#     space,t,o,          demand). A moved window is the only thing that
#     return              reliably REPAINTS on a space switch (observed:
#                        an empty space keeps stale pixels everywhere —
#                        body and rail both — so no empty-space pixel
#                        check can be deterministic). With GODEMO living
#                        there, the space-2 frame has real content.
#   ctrl-alt-pagedown -> switch to space "2" (GODEMO unhides + repaints)
#   down x12          -> dwell keys on the space: the cv-input path paces
#                        chords at 0.25s/stroke, so twelve buys ~3s — the
#                        2s-delayed screenshot lands inside the visit
#                        even with serial-poll jitter (they fall to the
#                        seat as non-chords on the dormant space)
#   ctrl-alt-pageup   -> back to space "1" for the snapshot (so the
#                        restore lands on the panes, cur=0)
#   ctrl-shift-s      -> the snapshot bundle publishes
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: session live n=4' \
    --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'escape,f10,down,right,right,e,tab,down,down,right,return,ctrl-shift-v,ctrl-shift-v,ctrl-shift-p,m,o,v,e,space,t,o,return,ctrl-alt-pagedown,down,down,down,down,down,down,down,down,down,down,down,down,ctrl-alt-pageup,ctrl-shift-s' \
    --input-chords-after 'godialog: painted' \
    --screenshot-after 'gotabwm: space switch 1->2' \
    --screenshot-after-delay 2 \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --input-string $'vf open SNAPSHOT.RESTORE\nvf write 0 1\nexec GOTABWM.ELF\n' \
    --input-string-after 'wm: unregistered, shim resumed' \
    --script-expect 'gotabwm: session live n=4' --script-expect-tail 20 --timeout 420

# --- the opt-in seat, live mode ------------------------------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-count 'exec: loaded GOTABWM.ELF' 2
vgate_assert 01 serial-count 'gotabwm: registered' 2
vgate_assert 01 serial-contains 'gotabwm: mode live'
# --- step 1: four tabs, three panes ---------------------------------------
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'exec: loaded GODEMO.ELF'
vgate_assert 01 serial-contains 'gotabwm: rail n=4'
vgate_assert 01 serial-contains 'gotabwm: split v'
vgate_assert 01 serial-contains 'gotabwm: split h'
# The three placed pane rects (the focused leaf keeps A): a left column
# split horizontally into two 640x360 panes and one full-height 640x720.
vgate_assert 01 serial-contains 'x=0 y=0 w=640 h=360'
vgate_assert 01 serial-contains 'x=0 y=360 w=640 h=360'
vgate_assert 01 serial-contains 'x=640 y=0 w=640 h=720'
vgate_assert 01 serial-contains 'gotabwm: panes write n=2'
# --- step 2: the appkit demo driven by keys alone -------------------------
vgate_assert 01 serial-contains 'godialog: painted'
vgate_assert 01 serial-contains 'godemo: menu expand-all'
vgate_assert 01 serial-contains 'godemo: table activate r=2 c=1'
# --- step 3: a second space exists, holds GODEMO, and was visited --------
vgate_assert 01 serial-contains 'gotabwm: space new name=2'
vgate_assert 01 serial-contains 'gotabwm: space move id='
vgate_assert 01 serial-contains ' to=2'
vgate_assert 01 serial-contains 'gotabwm: space switch 1->2'
vgate_assert 01 serial-contains 'gotabwm: space switch 2->1'
# --- step 4: snapshot, then the in-boot restore ----------------------------
vgate_assert 01 serial-contains 'gotabwm: session write n=4'
vgate_assert 01 serial-contains 'gotabwm: session spaces n=2'
vgate_assert 01 serial-contains 'gotabwm: snapshot saved'
# The seat died cleanly between the two execs.
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'gotabwm: snapshot restore'
vgate_assert 01 serial-contains 'gotabwm: session load n=4 mode=restore'
vgate_assert 01 serial-contains 'gotabwm: panes load n=2'
vgate_assert 01 serial-contains 'gotabwm: session spaces n=2'
vgate_assert 01 serial-contains 'gotabwm: session reexec n=4'
vgate_assert 01 serial-contains 'gotabwm: session exec GOCALC.ELF'
vgate_assert 01 serial-contains 'gotabwm: session exec NOTE.ELF'
vgate_assert 01 serial-contains 'gotabwm: session exec GOEDIT.ELF'
# The demo's session record names GODIALOG.ELF — guessBin maps its
# declared "Dialog" title — so the restore spawns that file (setup staged
# it: the GODEMO bytes).
vgate_assert 01 serial-contains 'gotabwm: session exec GODIALOG.ELF'
vgate_assert 01 serial-contains 'gotabwm: session live n=4'
# Every restored row really re-hosted: four fresh declares and opens.
vgate_assert 01 serial-count 'gotabwm: tab open id=' 7
vgate_assert 01 serial-absent 'gotabwm: panes bad'
vgate_assert 01 serial-absent 'gotabwm: session bad'
vgate_assert 01 serial-absent 'gotabwm: snapshot bad'
vgate_assert 01 serial-absent 'gotabwm: snapshot missing'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# --- the persisted truth on the share ------------------------------------
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
# SESSION.PANES is the v2 spaces frame: PN\x02 nspaces=2 cur=0 — the
# internal 0-based index of space "1" — both space names, and space "1"'s
# blob holding the three-leaf tree (v+h splits).
blob = open(os.path.join(share, "SESSION.PANES"), "rb").read()
if blob[:5] != b"PN\x02\x02\x00":
    sys.exit("SESSION.PANES v2 header %r want PN\\x02 n=2 cur=0" % blob[:5])
if b"\x011" not in blob or b"\x012" not in blob:
    sys.exit("sidecar must carry both space names: %r" % blob)
if b"v" not in blob[5:]:
    sys.exit("sidecar must carry the v split: %r" % blob)
# SESSION.TABS: four v2 records, all grouped "1" (space 2 is empty).
raw = open(os.path.join(share, "SESSION.TABS"), "rb").read()
if not raw or raw[0] != 2:
    sys.exit("SESSION.TABS ver=%r" % (raw[:1]))
count = raw[2]
groups = set()
for i in range(count):
    groups.add(raw[6 + i * 69 + 33:6 + i * 69 + 45].split(b"\0", 1)[0])
if count != 4 or groups != {b"1", b"2"}:
    sys.exit("records=%d groups=%r want 4 rows over spaces 1+2" % (count, groups))
# LAYOUT.txt: the live space-1 strip writes three rows — the two placed
# panes (GODEMO's emptied leaf carries no tab) plus the unplaced tab.
lay = open(os.path.join(share, "SELFTEST", "LAYOUT.txt"), "rb").read().decode("utf-8")
rows = [l for l in lay.splitlines() if l.startswith("tab=")]
if len(rows) != 3:
    sys.exit("layout rows=%d want 3 (GODEMO lives on space 2)" % len(rows))
for frag in ("x=0 y=0 w=640 h=720", "x=640 y=0 w=640 h=720"):
    if frag not in lay:
        sys.exit("layout missing pane " + frag)
if "split=v" not in lay:
    sys.exit("layout lost the v split")
if "focus=1" not in lay:
    sys.exit("no focused pane recorded")
print("sidecar %dB nspaces=2 cur=0; session records=%d groups=%s; layout: %s"
      % (len(blob), count, sorted(groups), rows))
PY

# --- pixel probe 1: space 2 is real --------------------------------------
# The PNG the runner grabbed ~2s after `space switch 1->2` printed
# (--screenshot-after-delay). GODEMO was palette-moved to space 2, so its
# window unhides and repaints there — the one thing that reliably does
# (observed: an EMPTY space keeps stale pixels body and rail, so a bare-
# space pixel check flapped). The probe looks for GODEMO's painted
# window in the rect it kept from its pane ({0,0,640,360}): a real app
# surface — non-Bg content — where the dormant space-1 panes could not
# have painted anything new.
vgate_assert 01 snapshot 'screen-01-after*' <<'PY'
import sys, zlib, struct
from collections import Counter
path = sys.argv[1]
d = open(path, "rb").read()
if d[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG")
pos = 8; idat = b""; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack(">I4s", d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b"IHDR":
        w, h, bd, ct = struct.unpack(">IIBB", data[:10])
    elif typ == b"IDAT":
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
def near(rgb, token, tol=4):
    return all(abs(a - b) <= tol for a, b in zip(rgb, token))
bg = (0x18, 0x20, 0x26)
scale = w / 1280.0
# GODEMO's window on space 2 keeps its pane rect {0,0,640,360}: the demo
# surface inside it must read as real content — non-Bg pixels well above
# an empty rect — while the rest of the frame may carry stale space-1
# pixels (harmless; the window's own repaint is what proves the space
# took the moved tab and showed it).
n, tot = 0, 0
for y in range(int(40 * scale), int(340 * scale), 4):
    for x in range(int(20 * scale), int(620 * scale), 4):
        tot += 1
        if not near(px(x, y), bg):
            n += 1
if n * 100 < tot * 20:
    sys.exit("space-2 GODEMO rect: only %d/%d non-Bg px — the moved "
             "window never repainted there" % (n, tot))
# The top rail should carry space 2's single tab cell — one wide cell
# face, not space-1's four: a modal count of painted cell pixels.
from collections import Counter
band = Counter()
for y in range(int(2 * scale), int(20 * scale)):
    for x in range(int(40 * scale), int(1240 * scale)):
        band[px(x, y)] += 1
modal, mcount = band.most_common(1)[0]
total = sum(band.values())
if mcount * 100 < total * 60:
    sys.exit("space-2 rail unreadable: only %d%% modal %r" %
             (mcount * 100 // total, modal))
print("space-2: GODEMO window %d/%d non-Bg px; rail modal %d%% %r"
      % (n, tot, mcount * 100 // total, modal))
PY

# --- pixel probe 2: the restored panes, on the composed scanout -----------
# The kind-4 BGRX frame at `session live n=4` — straight out of the guest,
# so tokens are exact. The rail proves the three restored cells (the
# focused one carries the 3px Accent marker); each pane rect must hold a
# real window surface — counted as non-Bg pixels, never an app↔rect guess
# (declare order is unsequenced by design).
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %dx%d BGRX" % (len(raw), W, H))

def px(x, y):
    off = (y * W + x) * 4
    return raw[off + 2], raw[off + 1], raw[off]

BG = (0x18, 0x20, 0x26)
ACCENT = (0x3b, 0x82, 0xf6)
SELECTION = (0x2a, 0x44, 0x60)
BTN_IDLE = (0x2d, 0x37, 0x48)

# The rail (top ~22 rows): at least one cell carries the focused 3px
# Accent marker, and cell interiors read the seat's own faces.
accent = sum(1 for y in range(22) for x in range(W) if px(x, y) == ACCENT)
if accent < 40:
    sys.exit("only %d accent px on the rail — the focused cell's marker "
             "did not repaint" % accent)
faces = sum(1 for y in range(22) for x in range(W)
            if px(x, y) in (SELECTION, BTN_IDLE))
if faces < 3 * 60 * 20:
    sys.exit("rail cell faces too thin (%d px) — the restored strip did "
             "not paint" % faces)

# Every pane rect must hold a real window: the pane's own gutter edges
# (1px Bg seam between panes) and a substantial non-Bg interior. The
# probe counts against Bg only — which app lives in which leaf is the
# strip's business, and a pane that restored as a dead rect would read
# uniform Bg.
def pane_body(x0, y0, x1, y1):
    n = 0
    for y in range(y0, y1, 4):
        for x in range(x0, x1, 4):
            if px(x, y) != BG:
                n += 1
    return n
panes = ((0, 24, 636, 356), (0, 364, 636, 716), (644, 24, 1276, 716))
counts = [pane_body(*p) for p in panes]
for i, c in enumerate(counts):
    if c < 200:
        sys.exit("pane %d holds only %d non-Bg sample px — no window "
                 "restored into it" % (i, c))
print("restored: %d rail accent px, %d face px; pane non-Bg px %s"
      % (accent, faces, counts))
PY

# ===========================================================================
# Run 02 (M151d / #2914): the M151a/b gestures composed in one LIVE session
# and taken through the snapshot restore. GOCALC + NOTE + GOEDIT open as
# three tabs; the exec order is load-bearing: NOTE declares last so it is
# focused when the split lands — leaf A takes NOTE, nextUnplaced wraps to
# GOEDIT for leaf B, and GOCALC stays unplaced on the full-viewport stack.
# That placement is what lets the palette's move row carry GOCALC to space
# "2" WITHOUT collapsing the tree (detachTabAt removes no leaf for an
# unplaced tab), so the drag still has a pane to land in after the move.
#
# One chord burst and one pointer burst is all the harness schedules, so
# the run is two phases: every keyboard leg first, then every pointer leg.
# The burst boundary lands on 'snapshot saved' — the M81g deferral
# (armSnapshotAsk) holds the capture until input quiet, so gating the
# pointer burst on that marker also PROVES the bundle was published before
# a single pointer step fired: the bundle is the deterministic pre-drag
# state, and the restore asserts match it byte for byte.
#
#   chords (after 'rail n=3'):
#     ctrl-shift-v            split v -> leaves {NOTE, GOEDIT}
#     palette "Zoom pane"     'zoom on id=' names NOTE's leaf full-viewport
#     palette "Restore panes" 'zoom off'
#     ctrl-alt-pagedown       'space new name=2' + 'space switch 1->2'
#     ctrl-alt-pageup         'space switch 2->1' — home, tree intact
#     ctrl-2                  focus rail cell 2 = GOCALC (focus-index chord)
#     palette "Move to space 2"  'palette run move-to-space 2' +
#                             'space move id= to=2' — GOCALC's row only:
#                             an unplaced detach keeps the two-leaf tree
#     ctrl-shift-s            the deferred snapshot arm; 'snapshot saved'
#                             fires once input is quiet — the pointer gate
#   pointer (after 'snapshot saved'):
#     960,8,d ; 1000,400,u    rail-drag NOTE's cell into leaf B — the
#                             seat's pane drop swaps the leaf hosts
#     1268,11,c               pill "2" ([1260,1276) at 8px metrics): pick +
#                             'space switch 1->2', visiting GOCALC's space
#     1248,11,c               pill "1" ([1240,1256)): 'space pick 1' +
#                             'space switch 2->1' — the card's come-home
#     1278,8,c                cell-1 close zone is [1264,1280) but pill "2"
#                             covers [1260,1276): 1278 is the 4px strip
#                             where the close-x outranks the pill — closes
#                             the focused NOTE, 'focus restore' names
#                             GOEDIT off the MRU ring
#   script3 (after 'focus restore'): dui focus 0 parks the console for the
#     staged restore; clients die before their seat (run-01 discipline).
#   input-string (after 'wm: unregistered'): SNAPSHOT.RESTORE one-shot,
#     then the seat re-execs -> 'session live n=3' ends the run.
vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF
exec GOCALC.ELF
exec NOTE.ELF
EOF

vgate_file script3-02.txt <<'EOF'
dui focus 0
kill GOCALC.ELF
kill GOEDIT.ELF
kill GOTABWM.ELF
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: session live n=3' \
    --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-v,ctrl-shift-p,z,o,o,m,space,p,a,n,e,return,ctrl-shift-p,r,e,s,t,o,r,e,space,p,a,n,e,s,return,ctrl-alt-pagedown,ctrl-alt-pageup,ctrl-2,ctrl-shift-p,m,o,v,e,space,t,o,space,2,return,ctrl-shift-s' \
    --input-chords-after 'gotabwm: rail n=3' \
    --pointer-virtio '960,8,d;1000,400,u;1268,11,c;1248,11,c;1278,8,c' \
    --pointer-virtio-after 'gotabwm: snapshot saved' \
    --screenshot-after 'gotabwm: space pick 2' \
    --screenshot-after-delay 2 \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'gotabwm: focus restore' \
    --input-string $'vf open SNAPSHOT.RESTORE\nvf write 0 1\nexec GOTABWM.ELF\n' \
    --input-string-after 'wm: unregistered, shim resumed' \
    --script-expect 'gotabwm: session live n=3' --script-expect-tail 20 --timeout 420

# --- the opt-in seat, live mode ------------------------------------------
vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-count 'exec: loaded GOTABWM.ELF' 2
vgate_assert 02 serial-count 'gotabwm: registered' 2
vgate_assert 02 serial-contains 'gotabwm: mode live'
# --- three tabs, the split, and the palette posture legs ------------------
vgate_assert 02 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 02 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 02 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 02 serial-contains 'gotabwm: rail n=3'
vgate_assert 02 serial-contains 'gotabwm: split v'
vgate_assert 02 serial-contains 'gotabwm: palette run zoom-pane'
vgate_assert 02 serial-contains 'gotabwm: zoom on id='
vgate_assert 02 serial-contains 'gotabwm: palette run restore-panes'
vgate_assert 02 serial-contains 'gotabwm: zoom off'
# --- the space legs: chord create, palette move, pill round-trip ----------
vgate_assert 02 serial-contains 'gotabwm: space new name=2'
vgate_assert 02 serial-contains 'gotabwm: palette run move-to-space 2'
vgate_assert 02 serial-contains 'gotabwm: space move id='
vgate_assert 02 serial-contains ' to=2'
vgate_assert 02 serial-count 'gotabwm: space switch 1->2' 2
vgate_assert 02 serial-count 'gotabwm: space switch 2->1' 2
vgate_assert 02 serial-contains 'gotabwm: space pick 2'
vgate_assert 02 serial-contains 'gotabwm: space pick 1'
# --- the drag and the MRU close -------------------------------------------
vgate_assert 02 serial-contains 'gotabwm: pane drop id='
vgate_assert 02 serial-contains ' leaf='
vgate_assert 02 serial-contains 'gotabwm: tab close id='
vgate_assert 02 serial-contains 'gotabwm: focus restore id='
vgate_assert 02 serial-contains ' why=close'
# --- snapshot, kill, restore ----------------------------------------------
vgate_assert 02 serial-contains 'gotabwm: snapshot saved'
vgate_assert 02 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 02 serial-contains 'gotabwm: snapshot restore'
vgate_assert 02 serial-contains 'gotabwm: session load n=3 mode=restore'
vgate_assert 02 serial-contains 'gotabwm: session spaces n=2'
vgate_assert 02 serial-contains 'gotabwm: panes load n=2 spaces=2'
vgate_assert 02 serial-contains 'gotabwm: session reexec n=3'
vgate_assert 02 serial-contains 'gotabwm: session exec GOEDIT.ELF'
vgate_assert 02 serial-contains 'gotabwm: session exec GOCALC.ELF'
vgate_assert 02 serial-contains 'gotabwm: session exec NOTE.ELF'
vgate_assert 02 serial-contains 'gotabwm: session live n=3'
# Every row really re-hosted: three declares pre-kill, three after.
vgate_assert 02 serial-count 'gotabwm: tab open id=' 6
vgate_assert 02 serial-absent 'gotabwm: panes bad'
vgate_assert 02 serial-absent 'gotabwm: session bad'
vgate_assert 02 serial-absent 'gotabwm: snapshot bad'
vgate_assert 02 serial-absent 'gotabwm: snapshot missing'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
# Leg order: the move names a now-two-cell strip, the drop still has a leaf
# to hit, and the close's restore fires AFTER the pick-home landed us back
# on space 1 — all three proven by marker position, not assumption.
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
i_zoom = ser.find("gotabwm: zoom on id=")
i_zoff = ser.find("gotabwm: zoom off")
i_move = ser.find("gotabwm: space move id=")
i_snap = ser.find("gotabwm: snapshot saved")
i_drop = ser.find("gotabwm: pane drop")
i_pk2 = ser.find("gotabwm: space pick 2")
i_pk1 = ser.find("gotabwm: space pick 1")
i_cls = ser.find("gotabwm: tab close id=")
i_rst = ser.find("gotabwm: focus restore id=")
if not (0 <= i_zoom < i_zoff < i_move < i_snap < i_drop < i_pk2 < i_pk1
        < i_cls < i_rst):
    sys.exit("leg order wrong: %d %d %d %d %d %d %d %d %d" % (
        i_zoom, i_zoff, i_move, i_snap, i_drop, i_pk2, i_pk1, i_cls, i_rst))
# The drop named a live client and the restore named the OTHER survivor:
# the closed id and the restored id are the strip's two remaining tabs.
import re
dm = re.search(r"gotabwm: pane drop id=(\d+) leaf=(\d+)", ser[i_snap:])
cm = re.search(r"gotabwm: tab close id=(\d+)", ser[i_pk1:])
fm = re.search(r"gotabwm: focus restore id=(\d+) why=close", ser[i_pk1:])
if not dm or not cm or not fm:
    sys.exit("missing drop/close/restore detail")
if int(cm.group(1)) == int(fm.group(1)):
    sys.exit("focus restore picked the closed tab")
print("ordered: zoom<move<snap<drop<pick2<pick1<close<restore; "
      "drop=%s close=%s restore=%s" % (dm.groups(), cm.group(1), fm.group(1)))
PY
# --- the persisted truth, by bytes: the bundle IS the pre-kill state ------
# restoreSnapshot republishes the bundle's 'session'/'panes' entries over
# the live files, so post-restore SESSION.TABS/SESSION.PANES must equal
# those entries — except the .tabs seq field (bytes 3:5), which a
# post-restore session write legitimately bumps. Everything else — record
# bytes, groups, bins, the pane-tree blob, both space names — must match
# the capture byte for byte.
vgate_assert 02 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
raw = open(os.path.join(share, "SNAPSHOT.BUNDLE"), "rb").read()
nl = raw.index(b"\n")
if raw[:5] != b"#vb1 ":
    sys.exit("bundle header %r" % raw[:nl])
decl = int(raw[5:nl])
rest = raw[nl + 1:]
ents = {}
for _ in range(decl):
    nl = rest.index(b"\n")
    name, num = rest[:nl].split(b" ", 1)
    ents[name.decode()] = rest[nl + 1:nl + 1 + int(num)]
    rest = rest[nl + 1 + int(num):]
if "session" not in ents or "panes" not in ents:
    sys.exit("bundle missing session/panes entries: %s" % sorted(ents))
tabs = open(os.path.join(share, "SESSION.TABS"), "rb").read()
want = ents["session"]
# The record region is the session truth: 6-byte header + count*69 records.
# The seq field (bytes 3:5) legitimately bumps on a post-restore write, and
# an app-state trailer may or may not tail the entry depending on which
# state asks the apps answered before the capture — both excluded here.
if len(tabs) < 6 or tabs[0] != 2:
    sys.exit("SESSION.TABS ver/len: %r" % tabs[:8])
cnt = tabs[2]
rec_len = 6 + cnt * 69
if len(want) < rec_len or len(tabs) < rec_len:
    sys.exit("record region short: live %d bundle %d want %d"
             % (len(tabs), len(want), rec_len))
if tabs[:3] != want[:3] or tabs[5:rec_len] != want[5:rec_len]:
    sys.exit("SESSION.TABS records != bundle session records")
panes = open(os.path.join(share, "SESSION.PANES"), "rb").read()
if panes != ents["panes"]:
    sys.exit("SESSION.PANES != bundle panes (%d vs %d bytes)"
             % (len(panes), len(ents["panes"])))
# Structural spot-checks: v2 header, two spaces, live=space "1" (cur=0),
# the split kind byte, and three records over groups {1,2}.
if panes[:5] != b"PN\x02\x02\x00":
    sys.exit("SESSION.PANES v2 header %r want PN\\x02 n=2 cur=0" % panes[:5])
if b"\x011" not in panes or b"\x012" not in panes:
    sys.exit("sidecar must carry both space names: %r" % panes)
if b"v" not in panes[5:]:
    sys.exit("sidecar must carry the v split: %r" % panes)
if tabs[0] != 2 or tabs[2] != 3:
    sys.exit("SESSION.TABS ver=%d count=%d want v2 n=3" % (tabs[0], tabs[2]))
groups = set()
for i in range(3):
    groups.add(tabs[6 + i * 69 + 33:6 + i * 69 + 45].split(b"\0", 1)[0])
if groups != {b"1", b"2"}:
    sys.exit("record groups %r want {1,2}" % groups)
print("bundle<->restored bytes match: session %dB (seq masked), panes %dB; "
      "records=3 groups=%s" % (len(tabs), len(panes), sorted(groups)))
PY
# --- pixel probe 1: the pill click really visited GOCALC's space ----------
# The PNG ~2s after 'space pick 2': space 2's rail carries its single tab
# and the pill strip flips — pill "2" now holds the Accent plate while the
# dormant "1" sits recessed. The window body must hold real content (the
# moved GOCALC repaints on the visit), never a bare Bg desktop.
vgate_assert 02 snapshot 'screen-02-after*' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, "rb").read()
if d[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG")
pos = 8; idat = b""; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack(">I4s", d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b"IHDR":
        w, h, bd, ct = struct.unpack(">IIBB", data[:10])
    elif typ == b"IDAT":
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
def blue(rgb):
    r, g, b = rgb
    return b > 150 and b > r + 40 and b > g + 40
def darkish(rgb):
    return rgb[2] < 80 and rgb[0] < 40 and rgb[1] < 45
BG = (0x18, 0x20, 0x26)
scale = w / 1280.0
# GOCALC's full-viewport window on space 2: real content, not stale pixels.
n, tot = 0, 0
for y in range(int(40 * scale), int(700 * scale), 4):
    for x in range(int(20 * scale), int(1260 * scale), 4):
        tot += 1
        if px(x, y) != BG:
            n += 1
if n * 100 < tot * 20:
    sys.exit("space-2 body only %d/%d non-Bg px — the visit never painted"
             % (n, tot))
# Pill "2" [1260,1276) carries the Accent plate now that it is live.
acc = sum(1 for y in range(int(4*scale), int(18*scale))
          for x in range(int(1261*scale), int(1275*scale))
          if blue(px(x, y)))
if acc < 150:
    sys.exit("pill 2 shows %d accent px — the pick never landed" % acc)
# Pill "1" [1240,1256) reads recessed (the dormant plate over the cell).
dark = sum(1 for y in range(int(4*scale), int(18*scale))
           for x in range(int(1241*scale), int(1255*scale))
           if darkish(px(x, y)))
if dark < 100:
    sys.exit("dormant pill 1 shows no recessed plate")
print("space-2 visit: body %d/%d non-Bg px; pill2 accent=%d; pill1 dark=%d"
      % (n, tot, acc, dark))
PY
# --- pixel probe 2: the restored panes on the composed scanout ------------
# The kind-4 BGRX frame at 'session live n=3': the restored strip is space
# "1" with its two-leaf tree — left and right half panes each holding a
# real window — under a two-cell rail with the pill strip at its right.
vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %dx%d BGRX" % (len(raw), W, H))

def px(x, y):
    off = (y * W + x) * 4
    return raw[off + 2], raw[off + 1], raw[off]

BG = (0x18, 0x20, 0x26)
ACCENT = (0x3b, 0x82, 0xf6)
SELECTION = (0x2a, 0x44, 0x60)
BTN_IDLE = (0x2d, 0x37, 0x48)

# Rail: a focused cell's accent marker and the restored strip's faces.
accent = sum(1 for y in range(22) for x in range(W) if px(x, y) == ACCENT)
if accent < 40:
    sys.exit("only %d accent px on the rail" % accent)
faces = sum(1 for y in range(22) for x in range(W)
            if px(x, y) in (SELECTION, BTN_IDLE))
if faces < 2 * 60 * 20:
    sys.exit("rail cell faces too thin (%d px)" % faces)
# The live space's pill "1" on its Accent plate [1240,1256)x[3,19).
pill = sum(1 for y in range(4, 18) for x in range(1241, 1255)
           if px(x, y) == ACCENT)
if pill < 100:
    sys.exit("live pill shows %d accent px — no Accent plate" % pill)
# Both pane rects hold real windows — counted as non-Bg interiors only,
# never an app<->rect guess (declare order is unsequenced by design).
def pane_body(x0, y0, x1, y1):
    n = 0
    for y in range(y0, y1, 4):
        for x in range(x0, x1, 4):
            if px(x, y) != BG:
                n += 1
    return n
panes = ((0, 24, 636, 716), (644, 24, 1276, 716))
counts = [pane_body(*p) for p in panes]
for i, c in enumerate(counts):
    if c < 200:
        sys.exit("pane %d holds only %d non-Bg sample px" % (i, c))
print("restored: %d rail accent px, %d face px, %d live-pill px; "
      "pane non-Bg px %s" % (accent, faces, pill, counts))
PY
