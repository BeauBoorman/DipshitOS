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

vgate_name go-emoji "issue #2799: GOEMOJI.ELF picks a covered glyph by fuzzy name; the pick lands text/plain on the typed clipboard"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# --- run 01: menu launch -> search -> pick -> refusal pin -----------------
# The seat is exec'd from the monitor (wm=none keeps autostart off — run 02
# needs the bare shim). The chords batch anchors on 'gotabwm: mode live':
# ctrl-space summons the launcher, the 'goemoji' filter names the one row,
# Return execs it. The hosted app is uid_user — slots 38/39 refuse it — so
# the pick prints 'clip refuse rc=-7' and stays open; `clip` then proves
# the kernel buffer was never written.
vgate_file script-01.txt <<'EOF'
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
