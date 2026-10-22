# go-emoji.spec -- GOEMOJI.ELF (M146a, issue #2799) class-B gate: the emoji
# picker — a grid of the glyphs kernel/src/font_emoji.zig covers, fuzzy
# search by name, Enter to pick. A pick writes text/plain to the typed
# clipboard (vsys.ClipboardSetTyped) and closes or keeps the app per its
# stay toggle. Three legs:
#
#   run 01  the card's journey under the live gotabwm seat (exec'd from the
#           monitor — wm=none keeps the shared share's autostart off so run
#           02's bare shim stays seatless): ctrl-space opens the launcher,
#           the 'goemoji' filter names the one row, Return execs it; 'fire'
#           narrows the grid to the one glyph, Return picks. A hosted app
#           is uid_user — slots 38/39 refuse it (M97g), so the pick prints
#           'clip refuse rc=-7' and `clip` must read back EMPTY: the policy
#           boundary is the receipt (the go-edit run-07 shape).
#   run 02  bare shim, native 512x384 at (32,32): `exec -u0` is the
#           capable path (M97g-F4) — the picks land on the kernel clipboard
#           for real. A kind-4 snapshot on the settled first frame probes
#           the grid's REAL 16x16 art (the smile disc's carved eyes and the
#           fire cell the run-01 pick names). The kernel's own hit path
#           delivers MOUSE_* under the shim, so a pointer click toggles
#           'stay', then Tab cycles to the Compose tab (the kernel's
#           input.zig pairs) and the Kaomoji tab (the fixed dozen); both
#           picks land on `clip`, which must read back the shrug's exact
#           bytes.
#   run 03  the paste leg, capable end to end: `exec -u0 GOEMOJI`, 'fire'
#           pick lands on the kernel clipboard, `exec -u0 GOEDIT`, ctrl-v
#           -> 'goedit: paste n=4' — the typed clipboard's read direction
#           end-to-end (the emoji is four UTF-8 bytes).
#
# exec-order: assert-proven -- every run ends on a script marker, and the
# asserts read output only the programs produce (app markers, the kernel
# clipboard's own bytes), so a program that never ran cannot pass.
#
# HOST PREREQUISITES (fail the gate honestly when missing):
#   bash tools/go/build-goemoji.sh   ->  .build/go/GOEMOJI.ELF
#   bash tools/go/build-goedit.sh    ->  .build/go/GOEDIT.ELF (run 03)
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF (runs 01/03:
#                                      the kernel autostarts the seat only
#                                      when GOTABWM.ELF is on the share)
#
# The font staging mirrors tools/session.sh: the seed share carries only the
# five frozen 8.3 faces, so this adds FONTS.TXT plus the M99m coverage faces
# (NOTOSERF/NOTOCJK/CHROME). With the manifest present the app's LoadRegistry
# prints 'manifest=ok faces=9' and the Kaomoji tab's chain paint resolves
# through the real ui cascade — the same path kaomoji_test.go pins on the
# host. 'manifest=missing' would degrade the chain to the bitmap face.
#
# M146b (issue #2800) acceptance — run 04 is the card's journey, and
# vgate_repeat 3 replays EVERY leg three times (the go-sheet/go-irc
# convention): GOEDIT focused under a capable seat, ctrl+shift+E summons
# GOEMOJI, 'fire' picks the glyph, the picker quits and focus returns to
# GOEDIT, and a paste shows the glyph's ink on the scanout.
#
# M152c (issue #2917) — runs 05/06 are the shelf pair: run 05 picks two
# emoji in stay mode (recents accumulate inside the instance — the card's
# named limitation is that close-on-pick drops them), pins the first as a
# favorite, and ctrl-shift-s has the seat collect the v2 blob into
# SESSION.TABS; run 06 is the restore boot, where the re-exec'd picker's
# own restored markers read the favorite and the recents row back.
#
# REPEAT SEMANTICS: the armed share persists across iterations, so each
# leg must be iteration-safe. Runs 02/03 are bare-shim legs that write no
# share state. Runs 01/04/05 exec a live seat, and the seat persists
# SESSION.TABS/SESSION.PANES on every tab attach/detach — each boot's
# script re-rm's both so a prior iteration's strip cannot restore extra
# tabs over the journey. Run 05 re-rm's them too (it makes run 06's) and
# run 06 is the consumer — it must not rm.

vgate_name go-emoji "issue #2799+#2800+#2917: GOEMOJI.ELF picks a covered glyph by fuzzy name; the pick lands text/plain on the typed clipboard; K=3 chord-summon/pick/paste acceptance journey; recents/favorites shelf survives the seat snapshot"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

# --- run 01: menu launch -> search -> pick -> refusal pin -----------------
# The seat is exec'd from the monitor (wm=none keeps autostart off — run 02
# needs the bare shim). The chords batch anchors on 'gotabwm: mode live':
# ctrl-space summons the launcher, the 'goemoji' filter names the one row,
# Return execs it. The hosted app is uid_user — slots 38/39 refuse it — so
# the pick prints 'clip refuse rc=-7' and stays open; `clip` then proves
# the kernel buffer was never written.
vgate_file script-01.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
wm
exec GOTABWM.ELF
EOF

vgate_file script2-01.txt <<'EOF'
clip
EOF

vgate_file script3-01.txt <<'EOF'
echo rx-goemoji-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name in ("GOEMOJI.ELF", "GOEDIT.ELF", "GOTABWM.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: "
                 "bash tools/go/build-%s.sh" %
                 (name, src, name[:-4].lower()))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s (%d bytes)" % (name, os.path.getsize(src)))
for name in ("fonts.txt", "NotoSerif-Regular.ttf", "NotoSansJP-Regular.ttf",
             "VirelaiChrome-Regular.ttf"):
    src = os.path.join("image", "fonts", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - the font registry needs it" %
                 (name, src))
    # Share names are the frozen 8.3 convention (M69d #1531).
    dst = {"fonts.txt": "FONTS.TXT",
           "NotoSerif-Regular.ttf": "NOTOSERF.TTF",
           "NotoSansJP-Regular.ttf": "NOTOCJK.TTF",
           "VirelaiChrome-Regular.ttf": "CHROME.TTF"}[name]
    shutil.copy(src, os.path.join(share, dst))
    print("staged %s -> %s" % (name, dst))
# The armed share is ONE share for all three runs, so autostart must not
# fire: run 02 is the bare-shim leg and a live seat would accept the app's
# declare. `wm=none` (the go-paint idiom) keeps every boot seatless; runs
# 01/03 exec GOTABWM.ELF from the monitor instead — same seat, honest
# 'exec: loaded GOTABWM.ELF' marker.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' --via-virtio \
    --script '$RUN_DIR/script-01.txt' \
    --input-chords 'ctrl-space,g,o,e,m,o,j,i,return' \
    --input-chords-after 'gotabwm: mode live' \
    --input-string $'fire\n' \
    --input-string-after 'goemoji: present' \
    --script2 '$RUN_DIR/script2-01.txt' \
    --script2-after 'goemoji: clip refuse rc=-7' \
    --script3 '$RUN_DIR/script3-01.txt' \
    --script3-after 'clip: ' \
    --script-expect 'rx-goemoji-ok' --timeout 300

vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: mode live'
vgate_assert 01 serial-contains 'gotabwm: present'
vgate_assert 01 serial-contains 'gotabwm: launcher open n='
vgate_assert 01 serial-contains 'gotabwm: launcher filter q=goemoji n=1'
vgate_assert 01 serial-contains 'gotabwm: launcher exec GOEMOJI.ELF'
vgate_assert 01 serial-contains 'goemoji: open id='
vgate_assert 01 serial-contains 'goemoji: declare accepted'
vgate_assert 01 serial-contains 'goemoji: fonts manifest=ok faces='
vgate_assert 01 serial-contains 'goemoji: present'
vgate_assert 01 serial-contains 'goemoji: filter q=fire n=1'
# The M97g boundary is the receipt: a hosted uid_user app's slot-38 write
# refuses with EACCES (the pick marker prints only after a real write, so
# 'filter q=fire n=1' is what names the target) and the kernel buffer stays
# EMPTY — no write can be claimed where none happened.
vgate_assert 01 serial-contains 'goemoji: clip refuse rc=-7'
vgate_assert 01 serial-contains 'clip: empty'
vgate_assert 01 serial-absent 'goemoji: clip text/plain'
vgate_assert 01 serial-contains 'rx-goemoji-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- run 02: bare shim — pixel probes + stay + Compose/Kaomoji picks ------
# No seat: `declare` is refused and the app keeps its declared 512x384 at
# (32,32) — canvas coords = window-local coords (the kernel's 16px title
# band covers canvas rows 0..15). The stay checkbox sits at native
# (424,8)-(504,29); a down+up at screen (496,56) -> canvas (464,24) lands
# inside it. The pick keeps the app open under stay=on, so 'tab' cycles
# Emoji -> Compose -> Kaomoji and each 'return' picks the selected row:
# the first compose pair (Alt+e a -> á, U+00E1, two bytes) and the first
# kaomoji (the shrug, thirteen bytes).
#
# Snapshot timing (the go-edit run-10 idiom): the kind-4 stream reads the
# composited scanout, so it must fire on a settled marker — not on
# 'goemoji: present', which precedes the shim's first composite. script2's
# 5 s delay echoes rx-goemoji-grid once the first frame has landed; the
# snapshot rides that echo, and the pointer click waits for it so the probe
# sees the pristine grid.
# `exec -u0` grants the kernel caps (M97g-F4) — the picks below land on the
# kernel clipboard for real, which the `clip` readback asserts.
vgate_file script-02.txt <<'EOF'
exec -u0 GOEMOJI.ELF
EOF

vgate_file script2-02.txt <<'EOF'
echo rx-goemoji-grid
EOF

# The readback AND the run's closing echo share one stage: `clip` prints the
# kernel clipboard (the python assert below reads its exact bytes), the echo
# is the script-expect.
vgate_file script3-02.txt <<'EOF'
clip
echo rx-goemoji-02
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'goemoji: present' --script2-delay 5 \
    --snapshot-after 'rx-goemoji-grid' \
    --pointer-virtio '496,56,d;496,56,u' \
    --pointer-virtio-after 'rx-goemoji-grid' \
    --input-chords 'tab,return,tab,return' \
    --input-chords-after 'goemoji: stay on' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'goemoji: clip text/plain n=13' \
    --script-expect 'rx-goemoji-02' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOEMOJI.ELF'
vgate_assert 02 serial-contains 'goemoji: open id='
vgate_assert 02 serial-contains 'goemoji: declare refused'
vgate_assert 02 serial-contains 'goemoji: present'
vgate_assert 02 serial-contains 'goemoji: stay on'
vgate_assert 02 serial-contains 'goemoji: tab Compose'
vgate_assert 02 serial-contains 'goemoji: pick compose U+00E1'
vgate_assert 02 serial-contains 'goemoji: clip text/plain n=2'
vgate_assert 02 serial-contains 'goemoji: tab Kaomoji'
vgate_assert 02 serial-contains 'goemoji: pick kaomoji shrug'
vgate_assert 02 serial-contains 'goemoji: clip text/plain n=13'
vgate_assert 02 serial-contains 'rx-goemoji-02'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_assert 02 python <<'PY'
import os, sys
raw = open(os.environ["VG_SER"], "rb").read()
want = "clip: ¯\\_(ツ)_/¯\n".encode("utf-8")
if want not in raw:
    sys.exit("kernel clipboard did not read back the shrug kaomoji")
print("kaomoji read-back verified on the host: %r" % want)
PY

# Pixel probes, 1280x720 BGRX. The first frame is the full grid: cell 0 is
# the selected smile — Accent ring, Surface plate, real ink — and the fire
# cell (index 12, row 2 col 0) is the same art font_emoji.zig paints.
# Geometry (canvas = scanout - 32): cell 0 is {10,70,76,54} -> scanout
# (42..117, 102..155); the smile's 16x16 art paints at canvas (32,73) at
# 2x; cell 12 is {10,184,76,54} with its art at canvas (32,187).
vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

def px(x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

BG      = (0x18, 0x20, 0x26)  # theme.Dark.Bg — the window fill
SURFACE = (0x22, 0x2d, 0x35)  # cell plate
ACCENT  = (0x3b, 0x82, 0xf6)  # selection ring
INK     = (0xe6, 0xed, 0xf3)  # glyph art
TITLE   = (0x1a, 0x2b, 0x3c)  # kernel title band (user_title_bg dark)

# Kernel chrome band over canvas rows 0..15 -> scanout rows 32..47.
band = [px(x, y) for y in range(34, 46) for x in range(60, 530, 10)]
if sum(1 for c in band if c == TITLE) * 2 < len(band):
    sys.exit("title band rows are not the kernel chrome colour")

# Cell 0's Accent selection ring: the outer 2px are Accent, inside is
# Surface. (43,115) sits on the ring's left column; (50,140) is plate
# interior left of the glyph art (which starts at canvas x 32).
assert px(43, 115) == ACCENT, \
    "selected cell ring %r is not Accent" % (px(43, 115),)
assert px(50, 140) == SURFACE, \
    "cell plate %r is not Surface" % (px(50, 140),)

# The smile's real art at canvas (32,73) -> scanout (64..95, 105..136):
# row 2 = 0x0FE0 (the disc's top lip, bits 5..10) probes (78,109); row 5 =
# 0x73CC has lit edges at bits 2 and 13 (68,115)/(90,115); the eye boxes
# (cols 4..5 and 10..11, rows 5..6) are CARVED — background, not ink,
# inside the lit face: (73,116)/(85,116).
if px(78, 109) != INK:
    sys.exit("smile lip at (78,109) is %r, want INK — the art did not paint" % (px(78, 109),))
if px(68, 115) != INK or px(90, 115) != INK:
    sys.exit("smile row 5 edges are not ink: %r %r" % (px(68, 115), px(90, 115)))
if px(73, 116) == INK or px(85, 116) == INK:
    sys.exit("smile eyes are lit — the carve did not paint")

# The fire cell (index 12 -> grid row 2 col 0) is {10,186,76,54}: glyph at
# canvas (32,189) -> scanout (64..95, 221..252); row 3 = 0x0180 lights bits
# 7..8 -> scanout (78..81, 227..228).
if px(79, 227) != INK:
    sys.exit("fire tip at (79,227) is %r, want INK" % (px(79, 227),))

# Outside the window is NOT the app: the wallpaper shares no token.
out = px(700, 300)
if out in (BG, SURFACE, ACCENT, INK, TITLE):
    sys.exit("outside-window pixel %r collides with an app token" % (out,))
print("emoji grid: title band ok, selection ring Accent, smile art + carved "
      "eyes ink, fire cell ink")
PY

# --- run 03: pick -> paste into GOEDIT ------------------------------------
# The capable path end to end (the go-edit run-06 shape): `exec -u0` for
# both programs so slots 38/39 admit them — GOEMOJI's pick lands on the
# kernel clipboard and GOEDIT's ctrl-v reads it back. GOEDIT opens only
# after 'goemoji OK', so the focused window receives the chord.
vgate_file script-03.txt <<'EOF'
exec -u0 GOEMOJI.ELF
EOF

vgate_file script2-03.txt <<'EOF'
exec -u0 GOEDIT.ELF
EOF

vgate_file script3-03.txt <<'EOF'
echo rx-goemoji-03
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' --via-virtio \
    --script '$RUN_DIR/script-03.txt' \
    --input-string $'fire\n' \
    --input-string-after 'goemoji: present' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'goemoji OK' \
    --input-chords 'ctrl-v' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'goedit: paste n=4' \
    --script-expect 'rx-goemoji-03' --timeout 300

vgate_assert 03 serial-contains 'exec: loaded GOEMOJI.ELF'
vgate_assert 03 serial-contains 'goemoji: declare refused'
vgate_assert 03 serial-contains 'goemoji: present'
vgate_assert 03 serial-contains 'goemoji: filter q=fire n=1'
vgate_assert 03 serial-contains 'goemoji: pick U+1F525 fire'
vgate_assert 03 serial-contains 'goemoji: clip text/plain n=4'
vgate_assert 03 serial-contains 'goemoji OK'
vgate_assert 03 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 03 serial-contains 'goedit: present'
vgate_assert 03 serial-contains 'goedit: paste n=4'
vgate_assert 03 serial-contains 'rx-goemoji-03'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# --- run 04 (M146b, issue #2800): the acceptance journey ------------------
# GOEDIT holds focus under a live seat, ctrl+shift+E summons GOEMOJI, a
# 'fire' search picks the glyph, the picker quits on the pick and focus
# returns to GOEDIT, and a paste puts the glyph on the scanout.
#
# CAPS: slots 38/39 refuse uid_user callers (M97g — run 01 pins that
# refusal), so the pick+paste endpoints both need CAP_CLIPBOARD. sys_exec
# preserves the caller's principal (kernel/syscall.zig handle_exec), so a
# monitor `exec -u0` GOTABWM.ELF makes the SEAT uid_system — and the
# summon chord's execApp then spawns GOEMOJI with the same caps. GOEDIT is
# exec'd -u0 likewise. That is the only arrangement where pick->paste can
# carry real bytes under the seat.
#
# script2 anchors on 'gotabwm: present' — the seat's first composite frame,
# once per boot — not 'mode live': the window-teardown churn between 'mode
# live' and 'serving' can drop an early declare ('goedit: declare refused'
# observed, run 04-01), which leaves no pane for the sel-paste to target.
#
# Chord-batch budget (one --input-chords per run, the runner's fixed
# surface): 'ctrl-a' selects the staged G.TXT glyph while GOEDIT is
# focused — publishSel hands it to the seat's primary buffer ('selpub n=4'
# + 'sel pub id=', the M124e lane the uid_user posture reserves). Then
# 'ctrl-shift-e' runs applySummonEmoji -> execApp GOEMOJI.ELF (a live tab
# of that name would be focused instead), a down-stroke dwell covers the
# exec+declare+present (~6 s at the 0.25 s/stroke cv-input cadence — arrows
# are harmless no-ops in either app), 'fire' refilters to the one glyph and
# 'return' picks: 'clip text/plain n=4' lands the real write, the picker
# quits (stay off) and the seat refocuses GOEDIT.
#
# The paste itself is the seat-mediated M124e primary delivery — a
# middle-click inside GOEDIT's pane resolves the target by GEOMETRY
# (dragTargetAt), immune to the focus-handoff timing a key chord would
# ride. 'sel paste id=' + 'goedit: sel-paste n=4' splices the same four
# bytes at the caret. script3's `clip` then reads the kernel buffer back —
# 'clip: <fire>' byte-verified by the python assert — so BOTH halves are
# proven: the pick's write really landed, and the paste's glyph really
# painted (the kind-4 probe scans for the 8x8 '?' fallback art in colText
# ink, the pattern nothing else on the scanout draws).
vgate_file script-04.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
wm
exec -u0 GOTABWM.ELF
EOF

vgate_file script2-04.txt <<'EOF'
exec -u0 GOEDIT.ELF /host/G.TXT
EOF

vgate_file script3-04.txt <<'EOF'
clip
echo rx-goemoji-04
EOF

vgate_setup_python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
# G.TXT is the glyph-bearing file GOEDIT opens and select-all publishes —
# the same four UTF-8 bytes the 'fire' pick writes to the kernel buffer,
# so the sel-paste lands "the glyph" the journey picked.
with open(os.path.join(share, "G.TXT"), "wb") as f:
    f.write("\U0001F525".encode("utf-8"))
print("staged G.TXT (fire glyph, 4 bytes)")
PY

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' --via-virtio \
    --cvc-snap --snapshot-out '$RUN_DIR/snap-04' \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'gotabwm: present' \
    --input-chords 'ctrl-a,ctrl-shift-e,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,down,f,i,r,e,return' \
    --input-chords-after 'goedit: present' \
    --pointer-virtio '640,400;640,400;640,400,mc' \
    --pointer-virtio-after 'goemoji OK' \
    --script3 '$RUN_DIR/script3-04.txt' \
    --script3-after 'goedit: sel-paste n=4' \
    --script3-delay 8 \
    --snapshot-after 'rx-goemoji-04' \
    --script-expect 'rx-goemoji-04' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 04 serial-contains 'gotabwm: mode live'
vgate_assert 04 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 04 serial-contains 'goedit: read /host/G.TXT n=4'
vgate_assert 04 serial-contains 'goedit: present'
# GOEDIT focused when the batch fired: ctrl-a select-all published the
# glyph to the seat's primary buffer (the proof the chord went to the app).
vgate_assert 04 serial-contains 'goedit: selpub n=4'
vgate_assert 04 serial-contains 'gotabwm: sel pub id='
# The summon: GOEMOJI only exists because ctrl+shift+E exec'd it — nothing
# else in the run can produce these markers (a seat 'tab focus' alone
# would still lack 'open id=' and 'present').
vgate_assert 04 serial-contains 'goemoji: open id='
vgate_assert 04 serial-contains 'goemoji: declare accepted'
vgate_assert 04 serial-contains 'goemoji: present'
vgate_assert 04 serial-contains 'goemoji: filter q=fire n=1'
vgate_assert 04 serial-contains 'goemoji: pick U+1F525 fire'
vgate_assert 04 serial-contains 'goemoji: clip text/plain n=4'
vgate_assert 04 serial-contains 'goemoji: close'
vgate_assert 04 serial-contains 'goemoji OK'
# Focus back on the editor and the seat-delivered paste.
vgate_assert 04 serial-contains 'gotabwm: sel paste id='
vgate_assert 04 serial-contains 'goedit: sel-paste n=4'
vgate_assert 04 serial-contains 'rx-goemoji-04'
vgate_assert 04 serial-absent 'goemoji: clip refuse'
vgate_assert 04 serial-absent 'gotabwm: sel refuse'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# The kernel buffer really holds the picked glyph — the read direction of
# the same clipboard the pick wrote (the run-02 shrug idiom).
vgate_assert 04 python <<'PY'
import os, sys
raw = open(os.environ["VG_SER"], "rb").read()
want = "clip: \U0001F525\n".encode("utf-8")
if want not in raw:
    sys.exit("kernel clipboard did not read back the picked fire glyph")
print("clipboard read-back verified on the host: %r" % want)
PY

# The pasted glyph's '?' fallback art (webrender/font Glyph8: unknown runes
# fall back to '?') as 8x8 cells in colText ink on colPageBg — the pattern
# the empty-state plate and seat chrome never draw. Lit cells must be ink
# and unlit cells page background, so a partial lookalike cannot pass.
vgate_assert 04 snapshot 'snap-04-*.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))
INK = (0xe6, 0xed, 0xf3)   # goedit colText
BG  = (0x18, 0x20, 0x26)   # goedit colPageBg
ROWS = [0x1e, 0x33, 0x30, 0x18, 0x0c, 0x00, 0x0c, 0x00]  # Glyph8('?')
def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])
found = 0
for y in range(0, H - 8):
    for x in range(0, W - 8):
        ok = True
        for gy in range(8):
            bits = ROWS[gy]
            for gx in range(8):
                want = INK if bits & (1 << gx) else BG
                if px(x + gx, y + gy) != want:
                    ok = False
                    break
            if not ok:
                break
        if ok:
            found += 1
if found == 0:
    sys.exit("no '?' fallback cell found — the pasted glyph is not on "
             "the scanout")
print("pixel probe: %d exact '?' cell(s) in editor ink on the page "
      "background" % found)
PY

# --- run 05 (M152c, issue #2917): the shelf save leg ---------------------
# `exec -u0` for both: the seat's own caps are inert here, but the picker's
# picks must be real kernel clipboard writes. The pointer click toggles
# 'stay' on the full-viewport surface (native {424,8,80,22} scales to
# canvas {1060,15,200,41}; the click at (1120,45) sits inside it and below
# the 22 px rail), so 'fire\n' picks A and 'heart\n' picks B without
# closing — the recents marker then reads B A ('U+2764 U+1F525', newest
# first). 'right' lands the focus on A's recents cell, 'f10' pins it
# ('goemoji: favs U+1F525'), and 'ctrl-shift-s' posts the seat's state
# ask — the app's PollStateAsk answers with the v2 blob, which the seat
# stores on the row and republishes into SESSION.TABS.
vgate_file script-05.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
wm
exec -u0 GOTABWM.ELF
EOF

vgate_file script2-05.txt <<'EOF'
exec -u0 GOEMOJI.ELF
EOF

vgate_file script3-05.txt <<'EOF'
echo rx-goemoji-05
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' --via-virtio \
    --script '$RUN_DIR/script-05.txt' \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'gotabwm: present' \
    --pointer-virtio '1120,45,d;1120,45,u' \
    --pointer-virtio-after 'goemoji: present' \
    --input-string $'fire\nheart\n' \
    --input-string-after 'goemoji: stay on' \
    --input-chords 'right,f10,ctrl-shift-s' \
    --input-chords-after 'goemoji: recents U+2764 U+1F525' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'gotabwm: snapshot saved bytes=' \
    --script-expect 'rx-goemoji-05' --timeout 300

vgate_assert 05 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 05 serial-contains 'gotabwm: mode live'
vgate_assert 05 serial-contains 'gotabwm: present'
vgate_assert 05 serial-contains 'exec: loaded GOEMOJI.ELF'
vgate_assert 05 serial-contains 'goemoji: open id='
vgate_assert 05 serial-contains 'goemoji: declare accepted'
vgate_assert 05 serial-contains 'goemoji: present'
vgate_assert 05 serial-contains 'goemoji: stay on'
vgate_assert 05 serial-contains 'goemoji: filter q=fire n=1'
vgate_assert 05 serial-contains 'goemoji: pick U+1F525 fire'
vgate_assert 05 serial-contains 'goemoji: clip text/plain n=4'
vgate_assert 05 serial-contains 'goemoji: filter q=heart n=1'
vgate_assert 05 serial-contains 'goemoji: pick U+2764 heart'
vgate_assert 05 serial-contains 'goemoji: clip text/plain n=3'
# The card's read: two stay-mode picks land most-recent-first — B A.
vgate_assert 05 serial-contains 'goemoji: recents U+1F525'
vgate_assert 05 serial-contains 'goemoji: recents U+2764 U+1F525'
# The pin: 'right,f10' focused A's recents cell and pinned it.
vgate_assert 05 serial-contains 'goemoji: favs U+1F525'
# The save: the seat asked, the app answered with the v2 blob, the file
# carries it.
vgate_assert 05 serial-contains 'gotabwm: state ask id='
vgate_assert 05 serial-contains 'goemoji: state saved len='
vgate_assert 05 serial-contains 'gotabwm: state save id='
vgate_assert 05 serial-contains 'gotabwm: snapshot saved bytes='
vgate_assert 05 serial-contains 'rx-goemoji-05'
vgate_assert 05 serial-absent 'goemoji: clip refuse'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# --- run 06 (M152c): the restore boot -------------------------------------
# SESSION.TABS on the armed share still names GOEMOJI with the v2 blob, so
# this boot's seat restore IS the leg: loadSession re-execs the row, the
# picker's RestoreState decodes it (ver=2), and the app prints the same
# favs/recents lines the save leg ended on — the favorite and the recents
# row made it across. No rm's: the session file is the payload.
vgate_file script-06.txt <<'EOF'
exec -u0 GOTABWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
echo rx-goemoji-06
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'goemoji: present' \
    --script-expect 'rx-goemoji-06' --timeout 300

vgate_assert 06 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 06 serial-contains 'gotabwm: mode live'
vgate_assert 06 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 06 serial-contains 'gotabwm: session reexec n=1'
# The recorded bin is the real name — the app declares GOEMOJI.ELF as its
# title so the row re-execs a binary the grants table knows.
vgate_assert 06 serial-contains 'gotabwm: session exec GOEMOJI.ELF'
vgate_assert 06 serial-contains 'gotabwm: state restore id='
vgate_assert 06 serial-contains 'goemoji: open id='
vgate_assert 06 serial-contains 'goemoji: declare accepted'
vgate_assert 06 serial-contains 'goemoji: state restored favs=1 recents=2'
vgate_assert 06 serial-contains 'goemoji: favs U+1F525'
vgate_assert 06 serial-contains 'goemoji: recents U+2764 U+1F525'
vgate_assert 06 serial-contains 'goemoji: present'
vgate_assert 06 serial-contains 'rx-goemoji-06'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

# --- run 07 (#2940): the enforce leg — the picker's state write lands under -
# mode=enforce, not only under the audit default. A run-scoped share
# (`--cvc-file`, the go-agentd posture-leg pattern: a later --cvc-file in a
# run's own flags overrides the armed share for that boot only) carries a
# GRANTS.TXT of `#v1 mode=enforce` and NO user rows, so the compiled base
# rows decide — under #2939's table GOEMOJI.ELF's row carries `file`, so
# the save_ask's staged /host/APPSTATE.<win> write lands and the blob
# reaches SESSION.TABS. A row that still lacked `file` would fail BY NAME
# — `refused:file_denied name=GOEMOJI.ELF word=file`, and `goemoji: state
# saved len=` would never print — never quietly; the asserts pin that
# refusal's absence AND the audit receipt's absence (the enforce posture),
# while the python hook proves the share's GRANTS.TXT really carried
# mode=enforce.
#
# Run-05 shape minus the second pick and the pin: `exec -u0` for both (the
# pick's kernel-clipboard write is a uid cap, orthogonal to grant words —
# the `file` word still binds by image name under -u0). The pointer click
# toggles 'stay' on the full-viewport surface, 'fire\n' picks the glyph
# and keeps the app open, and 'ctrl-shift-s' runs the state ask. The armed
# share's wm=none SETTINGS.TXT rides the copy, so no boot autostart, and
# the leading `vf rm`s keep every iteration clean.

vgate_setup_python <<'PY'
# Declared LAST of this spec's setup hooks so the copy sees the armed
# share's final state (fonts manifest + faces + G.TXT included), then
# layers the enforce posture on top.
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
enf = os.path.join(os.environ["RUN_DIR"], "enf-share")
if os.path.exists(enf):
    shutil.rmtree(enf)
shutil.copytree(share, enf)
open(os.path.join(enf, "GRANTS.TXT"), "w").write("#v1 mode=enforce\n")
print("enf-share: %d files, GRANTS.TXT mode=enforce" % len(os.listdir(enf)))
PY

vgate_file script-07.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
wm
exec -u0 GOTABWM.ELF
EOF

vgate_file script2-07.txt <<'EOF'
exec -u0 GOEMOJI.ELF
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' --via-virtio \
    --cvc-file '$RUN_DIR/enf-share' \
    --script '$RUN_DIR/script-07.txt' \
    --script2 '$RUN_DIR/script2-07.txt' \
    --script2-after 'gotabwm: present' \
    --pointer-virtio '1120,45,d;1120,45,u' \
    --pointer-virtio-after 'goemoji: present' \
    --input-string $'fire\n' \
    --input-string-after 'goemoji: stay on' \
    --input-chords 'ctrl-shift-s' \
    --input-chords-after 'goemoji: clip text/plain n=4' \
    --script-expect 'gotabwm: snapshot saved bytes=' --timeout 300

vgate_assert 07 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 07 serial-contains 'gotabwm: mode live'
vgate_assert 07 serial-contains 'gotabwm: present'
vgate_assert 07 serial-contains 'exec: loaded GOEMOJI.ELF'
vgate_assert 07 serial-contains 'goemoji: open id='
vgate_assert 07 serial-contains 'goemoji: declare accepted'
vgate_assert 07 serial-contains 'goemoji: present'
vgate_assert 07 serial-contains 'goemoji: stay on'
vgate_assert 07 serial-contains 'goemoji: filter q=fire n=1'
vgate_assert 07 serial-contains 'goemoji: pick U+1F525 fire'
vgate_assert 07 serial-contains 'goemoji: clip text/plain n=4'
# The ask -> the app's staged blob -> stored -> bundle chain, end to end.
# `goemoji: state saved len=` prints only on the acked handoff — under a
# missing `file` word the APPSTATE.<win> write is refused EACCES and the
# marker never prints.
vgate_assert 07 serial-contains 'gotabwm: state ask id='
vgate_assert 07 serial-contains 'goemoji: state saved len='
vgate_assert 07 serial-contains 'gotabwm: state save id='
vgate_assert 07 serial-contains 'gotabwm: snapshot saved bytes='
# The enforce posture's named failures, absent by name.
vgate_assert 07 serial-absent 'refused:file_denied name=GOEMOJI.ELF'
vgate_assert 07 serial-absent 'refused:file_denied name=GOTABWM.ELF'
vgate_assert 07 serial-absent 'refused:'
vgate_assert 07 serial-absent 'verdict=audit:'
vgate_assert 07 serial-absent 'goemoji: clip refuse'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'

# The share evidence (this run's share is enf-share, not the armed one —
# share-* asserts read the armed share, so the check is python): the
# GRANTS.TXT the boot read really was `#v1 mode=enforce` with no user
# rows; SESSION.TABS holds the picker's row with an AS trailer carrying
# its blob (the envelope bytes ride no other channel than the staged
# APPSTATE.<win> write); SNAPSHOT.BUNDLE exists non-empty.
vgate_assert 07 python <<'PY'
import os, sys
sh = os.path.join(os.environ["RUN_DIR"], "enf-share")
g = open(os.path.join(sh, "GRANTS.TXT")).read()
if g != "#v1 mode=enforce\n":
    sys.exit("enforce share GRANTS.TXT is %r — not the bare enforce header"
             % g)
t = open(os.path.join(sh, "SESSION.TABS"), "rb").read()
if t[0] != 2 or t[2] < 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (t[0], t[2]))
off = 6 + 69 * t[2]
if len(t) < off + 6 + 8 or t[off:off+2] != b"AS" or t[off+2] != 1 \
        or t[off+3] < 1:
    sys.exit("app_state trailer %r — want AS ver=1 count>=1"
             % t[off:off+6])
asc = t[off+3]
# The trailer interleaves 8-byte entries with their blobs: ent{row,
# appver, _, _, len LE} then len bytes, per stored state.
pos = off + 6
lens = []
for i in range(asc):
    ent = t[pos:pos+8]
    ln = int.from_bytes(ent[4:8], "little")
    pos += 8 + ln
    lens.append(ln)
if pos > len(t) or not any(ln > 0 for ln in lens):
    sys.exit("no non-empty blob in the AS trailer: lens=%r tail=%d"
             % (lens, len(t) - pos))
if not os.path.getsize(os.path.join(sh, "SNAPSHOT.BUNDLE")):
    sys.exit("SNAPSHOT.BUNDLE missing or empty")
print("enforce leg: GRANTS.TXT mode=enforce; SESSION.TABS %d row(s), AS "
      "blobs %r; bundle present" % (t[2], lens))
PY
