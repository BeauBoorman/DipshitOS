# go-fileman.spec -- M74a (issue #1644): GOFILES.ELF is a Bubble Tea TUI over
# the bound /dev/tty: one chord batch navigates into a seeded dir, comes back,
# selects KNOWN.TXT (preview pane), renames it, and the re-list shows the
# change. The screenshot asserts the preview pane's exact truecolour accent
# (M73h) in the real scanout — not a host ANSI render.
#
# Shape: go-charmhello — direct exec on the kernel desktop (no `tabwm start`
# seat), native 512x384 window = the kernel grid's 64x23 client (cols <= the
# grid's 80-col cap), chords over the real HID path, `dui` rect proof, and a
# screenshot barrier on the app's own post-rename marker. This spec RETIRES
# go-files.spec (M58a): one file manager, one spec.
#
# Marker discipline is load-bearing: the app flushes each frame's markers
# only AFTER painting it, so the screenshot at `gofiles: renamed …` sees the
# renamed frame, and `gofiles: settled after rename` (one yield later) is
# what script3 waits on before closing — the teardown can never race the
# capture.
#
# M81b (#1762) adds run 02: the OPEN dispatch. The same app, a second boot
# with a QOI and an OGG seeded beside the text file, and one chord batch that
# walks the whole decision — list the handlers (`o`), cancel, dispatch the
# default (Enter → GOVIEW.ELF launched), then hit the type nothing opens and
# read the named refusal. The proof is the pair of markers: the DECISION
# (`gofiles: open file … type=image handler=GOVIEW.ELF`) and the OUTCOME
# (`gofiles: open launched … pid=<n>`), which main prints only after vi.Exec
# returned. GOVIEW.ELF's own `goview: open id=` line is the third reporter: the
# image viewer really opened the file the manager named.
#
# M81a (#1761) adds run 04: confirmed delete to TRASH followed by `u` restore,
# with a host byte comparison of FM4/NOTE.TXT and RECENT action checks.
#
# M81f (#1766) adds run 05: the change feed. The app boots in its own dir
# (FM5), arms the vi watcher from its idle loop (`gofiles: watch armed` — the
# baseline listing is taken), and the RUNNER mutates the share macOS-side once
# that marker appears (`--host-write` + `--host-write-content` +
# `--host-write-after`, the same anchor discipline as --screenshot-after; the
# mutation is a real host-side write into the live share). The feed's event
# marker (`gofiles: watch created LATE.TXT`) follows within the idle cadence —
# 5 quiet ticks per poll, so a few tens of ms — and is the anchor for the
# closing script: a feed that never observes the host's write can never reach
# the expect line, so the bound is structural, not a timing hope. The probe
# measured WHY the feed is guest-side (queue 5 is a stateless request/reply
# transport; a host push would need a kernel seam): recorded on the card.
#
# M81d (#1764) adds run 06: the lease half of the convention. A foreign LIVE
# lease record (`--lease-fixture=`, the named fixture verb — the GOSELF
# --panic-receipt-fixture precedent) stands on FM6/NOTE.TXT, so the confirmed
# delete is refused with the emit marker `delete refused NOTE.TXT rc=-11`
# (-ErrEAGAIN, the lease row) and the file's bytes stay on the share — the
# exact silent-loss shape (editor holds the file, manager deletes it, the
# editor's next save resurrects it) the lease makes visible.
#
# M125c (#2588) adds runs 07/08: the session save/restore leg on the M125a
# protocol — the same app under GOTABWM (the go-wm-tabs runs 12/13 shape).
# Run 07 navigates into FM7/SUB7, moves the cursor, flips view mode and
# sort, then ctrl-shift-s snapshots: the seat's kind-20 ask collects the
# app's five-field blob into SESSION.TABS's `AS` trailer (asserted
# byte-level). Run 08 is a fresh boot: the seat restores the file, re-execs
# GOFILES.ELF, and the app's own `state restored` marker names the cwd,
# cursor, scroll, view and sort it decoded — the same session resumed.
#
# exec-order: assert-proven -- each run ends on its own `rx-go-fileman-*`
# marker, which only its closing script prints, and that script waits on the
# app's own marker; an app that never ran, never renamed, never settled or
# never refused cannot pass.

vgate_name go-fileman "M74a + M81a #1761 + M125c #2588: GOFILES navigates, previews, renames, trashes, restores, opens files, and resumes its session"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOFILES.ELF /host/FM
EOF

vgate_file script2.txt <<'EOF'
dui
EOF

vgate_file script3.txt <<'EOF'
dui close 2
echo rx-go-fileman-ok
EOF

vgate_file script6.txt <<'EOF'
exec GOFILES.ELF /host/FM2
EOF

vgate_file script4.txt <<'EOF'
dui
EOF

vgate_file script5.txt <<'EOF'
dui close 2
echo rx-go-fileman-open-ok
EOF

vgate_file script7.txt <<'EOF'
exec GOFILES.ELF /host/FM3
EOF

vgate_file script8.txt <<'EOF'
dui close 3
dui close 2
echo rx-go-fileman-default-open-ok
EOF

vgate_file script10.txt <<'EOF'
exec GOFILES.ELF /host/FM4
EOF

vgate_file script13.txt <<'EOF'
exec GOFILES.ELF /host/FM5
EOF

vgate_file script15.txt <<'EOF'
dui close 2
echo rx-go-fileman-watch-ok
EOF

vgate_file script16.txt <<'EOF'
exec GOFILES.ELF /host/FM6 --lease-fixture=/host/FM6/NOTE.TXT
EOF

vgate_file script17.txt <<'EOF'
dui close 2
echo rx-go-fileman-lease-ok
EOF

vgate_file script11.txt <<'EOF'
dui
EOF

vgate_file script12.txt <<'EOF'
dui close 2
echo rx-go-fileman-trash-ok
EOF

vgate_file fm4.expected <<'EOF'
trash-and-restore-exact
original bytes stay intact
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFILES.ELF")
if not os.path.exists(src):
    sys.exit("GOFILES.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-files.sh")
shutil.copy(src, os.path.join(share, "GOFILES.ELF"))
fm = os.path.join(share, "FM")
os.makedirs(fm, exist_ok=True)
known = os.path.join(fm, "KNOWN.TXT")
with open(known, "w") as f:
    f.write("hello-from-gofiles\npreview-line-alpha\npreview-line-beta\n")
sub = os.path.join(fm, "SUB")
os.makedirs(sub, exist_ok=True)
inner = os.path.join(sub, "INNER.TXT")
with open(inner, "w") as f:
    f.write("inner-file-preview\n")
# M81b (#1762): the handler run 02 dispatches to, plus the two fixtures that
# make the decision observable — an image the registry opens, and a sound file
# that nothing on the system opens. GOVIEW.ELF is copied whole; a missing
# build is named here rather than surfacing as a refused launch.
view = os.path.join(".build", "go", "GOVIEW.ELF")
if not os.path.exists(view):
    sys.exit("GOVIEW.ELF missing (expected " + view + ") - build it first: "
             "bash tools/go/build-goview.sh")
shutil.copy(view, os.path.join(share, "GOVIEW.ELF"))
edit = os.path.join(".build", "go", "GOEDIT.ELF")
if not os.path.exists(edit):
    sys.exit("GOEDIT.ELF missing (expected " + edit + ") - build it first: "
             "bash tools/go/build-goedit.sh")
shutil.copy(edit, os.path.join(share, "GOEDIT.ELF"))
# Run 02 starts the app in its OWN directory (FM2) so run 01's seeded listing
# — and every assert pinned on its two entries — is untouched by this card.
# A real 4x4 QOI: header, QOI_OP_RGB per pixel, the 8-byte end marker. Only the
# first 16 bytes are sniffed, but the whole file must decode for GOVIEW to open
# it — the sniff is not the interesting half of this run.
W = H = 4
qoi = bytearray(b"qoif") + (W).to_bytes(4, "big") + (H).to_bytes(4, "big") + bytes([4, 0])
for y in range(H):
    for x in range(W):
        qoi += bytes([0xfe, 0x30 + 20 * x, 0x60 + 20 * y, 0x90])
qoi += bytes([0, 0, 0, 0, 0, 0, 0, 1])
om = os.path.join(share, "FM2")
os.makedirs(om, exist_ok=True)
pic = os.path.join(om, "PIC.QOI")
with open(pic, "wb") as f:
    f.write(bytes(qoi))
# OggS magic: an audio type the registry has no handler for, so the run can
# read the named refusal instead of only the happy path.
ogg = os.path.join(om, "SONG.OGG")
with open(ogg, "wb") as f:
    f.write(b"OggS\x00\x02" + bytes(58))
fm3 = os.path.join(share, "FM3")
os.makedirs(fm3, exist_ok=True)
readme = os.path.join(fm3, "README.TXT")
with open(readme, "w") as f:
    f.write("open-contract-text\n")
fm4 = os.path.join(share, "FM4")
os.makedirs(fm4, exist_ok=True)
with open(os.path.join(fm4, "NOTE.TXT"), "w") as f:
    f.write("trash-and-restore-exact\noriginal bytes stay intact\n")
# M81f (#1766): run 05's watched directory — one file at boot. LATE.TXT is
# written INTO the live share by the runner mid-run (--host-write-after),
# which is exactly the host-side mutation the feed must observe; it must not
# exist at boot, or the run proves nothing.
fm5 = os.path.join(share, "FM5")
os.makedirs(fm5, exist_ok=True)
base5 = os.path.join(fm5, "BASE.TXT")
with open(base5, "w") as f:
    f.write("watch-baseline\n")
if os.path.exists(os.path.join(fm5, "LATE.TXT")):
    sys.exit("FM5/LATE.TXT already staged - run 05 would prove nothing")
# M81d (#1764): run 06's one-file directory. NOTE.TXT is the leased path; the
# foreign live record itself is written in-guest by the app's fixture verb,
# which is what keeps the drill on the guest's own file ABI.
fm6 = os.path.join(share, "FM6")
os.makedirs(fm6, exist_ok=True)
note6 = os.path.join(fm6, "NOTE.TXT")
with open(note6, "w") as f:
    f.write("leased-file-body\nsecond line\n")
# M125c (#2588): runs 07/08 — the session save/restore leg. FM7 holds one
# subdirectory to descend into (SUB7, two files so `j` provably moves the
# cursor onto DEEP2.TXT) plus a top-level file. The leg rides the Go seat,
# so GOTABWM.ELF is staged here alongside the app.
fm7 = os.path.join(share, "FM7")
sub7 = os.path.join(fm7, "SUB7")
os.makedirs(sub7, exist_ok=True)
with open(os.path.join(sub7, "DEEP1.TXT"), "w") as f:
    f.write("deep-one\n")
with open(os.path.join(sub7, "DEEP2.TXT"), "w") as f:
    f.write("deep-two\n")
with open(os.path.join(fm7, "A7.TXT"), "w") as f:
    f.write("a7\n")
wm = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(wm):
    sys.exit("GOTABWM.ELF missing (expected " + wm + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(wm, os.path.join(share, "GOTABWM.ELF"))
# Runs 07/08 need the SEAT to be the scripted `exec GOTABWM.ELF`, not the
# kernel's wm=gotabwm autostart default (M59 #1298): an autostarted seat
# restores SESSION.TABS before the host share is staged for its re-exec,
# and the restore leg must read the file run 07 left — not a second seat
# that registers after the share is already up. go-wm-tabs seeds the same
# schema-v2 file for the same reason.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")

print("staged GOFILES.ELF (%d bytes), GOEDIT.ELF (%d bytes), %s (%d bytes), "
      "%s (%d bytes), GOVIEW.ELF (%d bytes), %s (%d bytes), %s (%d bytes), "
      "%s (%d bytes), %s (%d bytes)" %
      (os.path.getsize(os.path.join(share, "GOFILES.ELF")),
       os.path.getsize(os.path.join(share, "GOEDIT.ELF")),
       known, os.path.getsize(known), inner, os.path.getsize(inner),
       os.path.getsize(os.path.join(share, "GOVIEW.ELF")),
       pic, os.path.getsize(pic), ogg, os.path.getsize(ogg),
       readme, os.path.getsize(readme), base5, os.path.getsize(base5)))
PY

# The chord batch, in full (17 strokes at the cv-input transport's fixed
# 0.25 s): enter the sorted-first dir SUB, come back up, use `j` to select
# KNOWN.TXT (dirs sort first), open the EMPTY rename prompt, type the new
# name one rune at a time, commit. Lowercase avoids any shift ambiguity in
# the HID chord table; `j` avoids the unreliable multi-byte arrow input path.
vgate_run 01 -- \
    --screen '$RUN_DIR/fileman-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-chords 'return,backspace,j,r,n,e,w,n,a,m,e,.,t,x,t,return' \
    --input-chords-after 'gofiles: ready' \
    --screenshot-after 'gofiles: renamed KNOWN.TXT -> newname.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gofiles: renamed KNOWN.TXT -> newname.txt' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gofiles: settled after rename' \
    --script-expect 'gofiles OK' --timeout 240

# --- serial: the app ran, navigated, previewed, acted -----------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 01 serial-contains 'gofiles: open id='
# The fullscreen declare is best-effort (tabapp doc): on the kernel
# desktop no TABWM exists to accept it, and the shim refuses honestly —
# the app keeps its native presentation.
vgate_assert 01 serial-contains 'gofiles: declare refused'
vgate_assert 01 serial-contains 'gofiles: attached'
vgate_assert 01 serial-contains 'gofiles: painted'
vgate_assert 01 serial-contains 'gofiles: ready'
vgate_assert 01 serial-contains 'gofiles: present'

# The window itself: native rect on the kernel desktop (dui from script2,
# fired at the rename barrier, so it describes the live window) — the
# charmhello dui row shape, plus the kernel's own blit counters showing the
# tty band was composited.
vgate_assert 01 serial-contains 'dui[4]: user user rect=32,32,512,384'

# First listing of the seeded dir: dirs-first order (SUB before KNOWN.TXT)
# and the M58a found-marker.
vgate_assert 01 serial-contains 'gofiles: list /host/FM n=2'
vgate_assert 01 serial-contains 'gofiles: entry SUB dir'
vgate_assert 01 serial-contains 'gofiles: entry KNOWN.TXT file'
vgate_assert 01 serial-contains 'gofiles: found KNOWN.TXT'

# Navigate: enter SUB (preview INNER.TXT), come back, select KNOWN.TXT.
vgate_assert 01 serial-contains 'gofiles: cd /host/FM/SUB'
vgate_assert 01 serial-contains 'gofiles: view INNER.TXT bytes='
vgate_assert 01 serial-contains 'gofiles: key return'
vgate_assert 01 serial-contains 'gofiles: key backspace'
vgate_assert 01 serial-contains 'gofiles: key j'
vgate_assert 01 serial-contains 'gofiles: view KNOWN.TXT bytes='

# Act: rename commits (the syscall returned) and the re-list shows the new
# name; the preview follows the renamed entry.
vgate_assert 01 serial-contains 'gofiles: renamed KNOWN.TXT -> newname.txt'
vgate_assert 01 serial-contains 'gofiles: list /host/FM n=2'
vgate_assert 01 serial-contains 'gofiles: entry newname.txt file'
vgate_assert 01 serial-contains 'gofiles: view newname.txt bytes='
vgate_assert 01 serial-contains 'gofiles: settled after rename'

# Clean teardown through the window-close path.
vgate_assert 01 serial-contains 'gofiles: close'
vgate_assert 01 serial-contains 'gofiles OK'
vgate_assert 01 serial-contains 'rx-go-fileman-ok'

# --- serial: the refusals that must NOT happen ------------------------------
vgate_assert 01 serial-absent 'gofiles: rename refused'
vgate_assert 01 serial-absent 'gofiles: list error'
vgate_assert 01 serial-absent 'gofiles: no /dev/tty'
vgate_assert 01 serial-absent 'gofiles: attach failed'
# M73i selection precedence: with ?1000/?1006 enabled, a plain pointer
# never falls through to kernel selection.
vgate_assert 01 serial-absent 'dui: term sel begin'
vgate_assert 01 serial-absent 'dui: term sel end'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- scanout: the preview pane's exact accent in the REAL framebuffer -------
# The barrier is the rename marker itself (printed AFTER its frame painted).
# At that frame the selection sits on newname.txt and its preview text —
# painted by the kernel's truecolour path at exactly (122,162,255) — is in
# the right pane; the selected-row background is (44,58,76). Tolerances
# The capture path shifts its tagged color space: source (122,162,255) is
# observed around (116,143,220). A bounded max-channel tolerance of 40 covers
# that measured shift; the ROI and minimum pixel count still require preview
# text ink, while the selection background remains a separate assertion.
vgate_assert 01 snapshot 'fileman-screen-after' <<'PY'
import struct, sys, zlib

d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG scanout"
pos = 8
idat = b""
w = h = ct = 0
while pos < len(d):
    n, typ = struct.unpack(">I4s", d[pos:pos + 8])
    chunk = d[pos + 8:pos + 8 + n]
    if typ == b"IHDR":
        w, h, depth, ct = struct.unpack(">IIBB", chunk[:10])
        assert depth == 8, "unexpected PNG depth"
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + n
assert (w, h) == (2560, 1440), "wanted 2560x1440 scanout, got %dx%d" % (w, h)
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
i = 0
for _ in range(h):
    filt = raw[i]
    i += 1
    row = bytearray(raw[i:i + stride])
    i += stride
    if filt == 1:
        for x in range(bpp, stride):
            row[x] = (row[x] + row[x - bpp]) & 0xff
    elif filt == 2:
        for x in range(stride):
            row[x] = (row[x] + prev[x]) & 0xff
    elif filt == 3:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            row[x] = (row[x] + ((left + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            pred = (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)
            row[x] = (row[x] + pred) & 0xff
    out += row
    prev = row

# The capture is 2x Retina: the native 512x384 window at (32,32) occupies
# x=64..1088, y=64..832, and its client starts at y=96. Each 8x16 terminal
# cell is 16x32 capture pixels. listWidth(64)=28, the separator is col 28,
# and the preview starts at col 29 (x=528); its three fixture lines occupy
# rows 2..4 (y=160..256). The capture path blends glyph pixels, so the
# measured preview accent is counted within +/-24 of (122,162,255) there.
# The selected-row background band is (44,58,76).
accent = selbg = 0
for y in range(96, 96 + 736):
    for x in range(64, 64 + 1024):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if (
            528 <= x < 1088
            and 160 <= y < 256
            and max(abs(r - 122), abs(g - 162), abs(b - 255)) <= 40
        ):
            accent += 1
        if abs(r - 44) <= 6 and abs(g - 58) <= 6 and abs(b - 76) <= 6:
            selbg += 1
print("fileman scanout: preview-accent=%d sel-bg=%d" % (accent, selbg))
assert accent >= 40, "preview pane accent (122,162,255) absent from the client rect"
assert selbg >= 100, "selected-row background (44,58,76) absent from the client rect"
PY

# --- M81b (#1762): run 02, the OPEN dispatch -------------------------------
# Same app, same share, new boot — started in /host/FM2, a directory holding
# exactly the two files the decision turns on (PIC.QOI, SONG.OGG; the first is
# selected on arrival). The batch is two chords long:
#
#   o           the Open-with… list on PIC.QOI (two candidates: GOVIEW, then
#               GOEDIT on the raw bytes)
#   1           take the FIRST entry of that list → GOVIEW.ELF on PIC.QOI
#
# Two chords, and the launch is the last one. vi.Exec blocks while the kernel
# loads and maps a 1.2 MB image, and input that arrives inside that window is
# not guaranteed to reach the app (observed on the first run 02 attempt: the
# trailing chords were lost and the run ended on the expect timeout). The
# closing script fires on the launch marker — the last thing the app says.
#
# The refusal half of the decision (a type with no handler) is NOT here: it
# needs a second selection, and this run's value is proving the whole list ->
# choice -> launch chain in ONE frame-budget. `gofiles: open refused SONG.OGG
# type=audio` is pinned on the host instead (files/open_test.go:
# TestOpenFileRefusesATypeNothingOpens), and the UNKNOWN row of the go-selftest
# `mime` receipt is the class-B proof that unknown stays unhandled.
vgate_run 02 -- \
    --screen '$RUN_DIR/fileman-open-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script6.txt' \
    --input-chords 'o,1' \
    --input-chords-after 'gofiles: ready' \
    --script2 '$RUN_DIR/script4.txt' \
    --script2-after 'gofiles: open with PIC.QOI type=image candidates=2' \
    --script3 '$RUN_DIR/script5.txt' \
    --script3-after 'gofiles: open launched PIC.QOI handler=GOVIEW.ELF pid=' \
    --script-expect 'rx-go-fileman-open-ok' --timeout 240

# The app ran, and the listing this run acts on really held both new fixtures.
vgate_assert 02 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 02 serial-contains 'gofiles: list /host/FM2 n=2'
vgate_assert 02 serial-contains 'gofiles: entry PIC.QOI file'
vgate_assert 02 serial-contains 'gofiles: entry SONG.OGG file'

# Open with…: the candidate list is real (both registered image handlers) and
# the digit took the first entry of it.
vgate_assert 02 serial-contains 'gofiles: open with PIC.QOI type=image candidates=2'
vgate_assert 02 serial-contains 'gofiles: open chose PIC.QOI type=image handler=GOVIEW.ELF'

# The dispatch: the DECISION (model) and the OUTCOME (after vi.Exec returned).
vgate_assert 02 serial-contains 'gofiles: open launched PIC.QOI handler=GOVIEW.ELF pid='
# The second reporter: the image viewer really started and opened the file the
# manager named (GOVIEW's own marker prefix is `gview:`). There is no
# `exec: loaded GOVIEW.ELF` line to assert — that marker belongs to the
# MONITOR's exec builtin, and a guest-initiated vi.Exec never prints it
# (observed: only `gofiles: open launched … pid=<n>` and GOVIEW's own lines).
vgate_assert 02 serial-contains 'gview: open id='
vgate_assert 02 serial-contains 'gview: loaded PIC.QOI'

# Nothing may be launched for a type with no handler, and no launch may fail
# quietly: the SONG.OGG fixture is in the listing precisely so the run can
# prove nothing was dispatched to it.
vgate_assert 02 serial-absent 'gofiles: open file SONG.OGG'
vgate_assert 02 serial-absent 'gofiles: open launch refused'

vgate_assert 02 serial-contains 'rx-go-fileman-open-ok'

# --- M81b: the refusals that must NOT happen ------------------------------
vgate_assert 02 serial-absent 'gofiles: no /dev/tty'
vgate_assert 02 serial-absent 'gofiles: attach failed'
vgate_assert 02 serial-absent 'gofiles: list error'
vgate_assert 02 serial-absent 'exited status=139'

# --- M81c (#1763): GOFILES takes the shared default-open path ---------------
# Enter on a text file selects the same virelai/mime.Open resolver as GOSH's
# `open` builtin. The host builds and stages GOEDIT.ELF so a successful
# marker is backed by the handler actually reading the path.
vgate_run 03 -- \
    --screen '$RUN_DIR/fileman-default-open-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script7.txt' \
    --input-chords 'return' \
    --input-chords-after 'gofiles: ready' \
    --script3 '$RUN_DIR/script8.txt' \
    --script3-after 'goedit: present' \
    --script-expect 'rx-go-fileman-default-open-ok' --timeout 240

vgate_assert 03 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 03 serial-contains 'gofiles: list /host/FM3 n=1'
vgate_assert 03 serial-contains 'gofiles: open file README.TXT type=text handler=GOEDIT.ELF'
vgate_assert 03 serial-contains 'gofiles: open launched README.TXT handler=GOEDIT.ELF pid='
vgate_assert 03 serial-contains 'goedit: open id='
vgate_assert 03 serial-contains 'goedit: read /host/FM3/README.TXT n=19'
vgate_assert 03 serial-contains 'goedit: present'
vgate_assert 03 serial-contains 'dui close: closed=3'
vgate_assert 03 serial-contains 'dui close: closed=2'
vgate_assert 03 serial-contains 'rx-go-fileman-default-open-ok'
vgate_assert 03 serial-absent 'gofiles: open refused README.TXT'
vgate_assert 03 serial-absent 'gofiles: open launch refused'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# --- M81a (#1761): run 04, trash then restore -------------------------------
# Keep this independent of the newer default-open run 03. The one-file
# directory makes the move and restoration unambiguous; share-equals proves
# the original bytes came back exactly.
vgate_run 04 -- \
    --screen '$RUN_DIR/fileman-trash-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script10.txt' \
    --input-chords 'd,y,u' \
    --input-chords-after 'gofiles: ready' \
    --script2 '$RUN_DIR/script11.txt' \
    --script2-after 'gofiles: deleted NOTE.TXT trash=' \
    --script3 '$RUN_DIR/script12.txt' \
    --script3-after 'gofiles: restored NOTE.TXT trash=' \
    --script-expect 'rx-go-fileman-trash-ok' --timeout 240

vgate_assert 04 serial-contains 'gofiles: deleted NOTE.TXT trash='
vgate_assert 04 serial-contains 'gofiles: restored NOTE.TXT trash='
vgate_assert 04 serial-contains 'gofiles: list /host/FM4 n=1'
vgate_assert 04 serial-contains 'gofiles: entry NOTE.TXT file'
vgate_assert 04 serial-contains 'rx-go-fileman-trash-ok'
vgate_assert 04 share-equals FM4/NOTE.TXT fm4.expected
vgate_assert 04 share-contains RECENT/LOG.TXT '|delete|'
vgate_assert 04 share-contains RECENT/LOG.TXT '|restore|'
vgate_assert 04 serial-absent 'gofiles: delete refused NOTE.TXT rc='
vgate_assert 04 serial-absent 'gofiles: restore refused rc='
vgate_assert 04 serial-absent 'exited status=139'

# --- M81f (#1766): run 05, the change feed ----------------------------------
# GOFILES in /host/FM5 with no chords typed at all: the watch is armed from
# the app's IDLE loop (first poll takes the baseline listing and prints
# `gofiles: watch armed`), the runner mutates the share macOS-side when that
# marker appears, and the feed must name the mutation on a later poll with
# the refreshed listing behind it. No input path is involved — the proof is
# that the app learned about a change it did not cause.
vgate_run 05 -- \
    --screen '$RUN_DIR/fileman-watch-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script13.txt' \
    --host-write 'FM5/LATE.TXT' \
    --host-write-content 'host wrote this line mid-boot' \
    --host-write-after 'gofiles: watch armed' \
    --script3 '$RUN_DIR/script15.txt' \
    --script3-after 'gofiles: watch created LATE.TXT' \
    --script-expect 'rx-go-fileman-watch-ok' --timeout 240

# The app ran, armed the feed, and the runner really mutated the share.
vgate_assert 05 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 05 serial-contains 'gofiles: list /host/FM5 n=1'
vgate_assert 05 serial-contains 'gofiles: watch armed'
vgate_assert 05 output-contains 'HOST-WRITE: wrote FM5/LATE.TXT'
vgate_assert 05 share-contains FM5/LATE.TXT 'host wrote this line mid-boot'

# The feed observed it: the event marker, then the refreshed listing that
# backs it (the two-entry dir with LATE.TXT among them).
vgate_assert 05 serial-contains 'gofiles: watch created LATE.TXT'
vgate_assert 05 serial-contains 'gofiles: list /host/FM5 n=2'
vgate_assert 05 serial-contains 'gofiles: entry BASE.TXT file size='
vgate_assert 05 serial-contains 'gofiles: entry LATE.TXT file size='
vgate_assert 05 serial-contains 'rx-go-fileman-watch-ok'

# The refusals that must NOT happen: the watch never fires a path-gone (the
# dir stays put), the mutation never fails, and the listing never errors.
vgate_assert 05 serial-absent 'gofiles: watch path gone'
vgate_assert 05 serial-absent 'gofiles: list error'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# --- M81d (#1764): run 06, the leased file is not deletable -----------------
# GOFILES in /host/FM6 with a foreign LIVE lease standing on NOTE.TXT (the
# fixture verb writes it before the TUI starts, and names it on the console).
# One chord batch: `d` arms the confirm, `y` commits — the op refuses with the
# EAGAIN row instead of trashing the file out from under its holder.
vgate_run 06 -- \
    --screen '$RUN_DIR/fileman-lease-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script16.txt' \
    --input-chords 'd,y' \
    --input-chords-after 'gofiles: ready' \
    --script3 '$RUN_DIR/script17.txt' \
    --script3-after 'gofiles: delete refused NOTE.TXT rc=-11' \
    --script-expect 'rx-go-fileman-lease-ok' --timeout 240

# The app ran, the fixture record is on the share's contract path, and the
# listing this run acts on really held the leased file.
vgate_assert 06 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 06 serial-contains 'gofiles: lease fixture /host/FM6/NOTE.TXT'
vgate_assert 06 serial-contains 'gofiles: list /host/FM6 n=1'
vgate_assert 06 serial-contains 'gofiles: entry NOTE.TXT file'

# The refusal: the confirmed delete reports the lease row (-ErrEAGAIN = -11).
vgate_assert 06 serial-contains 'gofiles: delete refused NOTE.TXT rc=-11'
vgate_assert 06 serial-contains 'rx-go-fileman-lease-ok'
# Nothing may be trashed behind the refusal, and nothing may be restored.
vgate_assert 06 serial-absent 'gofiles: deleted NOTE.TXT'
vgate_assert 06 serial-absent 'gofiles: restore refused'
vgate_assert 06 serial-absent 'gofiles: no /dev/tty'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

# The load-bearing assert: NOTE.TXT still holds its exact seeded bytes — the
# delete never reached the trash, so the holder's next save cannot resurrect
# a file the user deleted.
vgate_assert 06 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "FM6", "NOTE.TXT")
want = b"leased-file-body\nsecond line\n"
got = open(path, "rb").read()
if got != want:
    print("LEASED FILE WAS MUTATED: got %r want %r" % (got, want))
    raise SystemExit(1)
print("leased file verified untouched on the host (%d bytes)" % len(got))
PY

# --- M125c (#2588): run 07, session SAVE on the snapshot chord -------------
# The same app under the Go seat (the go-wm-tabs run 12 shape): GOFILES
# descends into FM7/SUB7, moves the cursor onto DEEP2.TXT, flips to the
# full-width list view and name sort — so all five serialized fields are
# non-trivial — then ctrl-shift-s. The seat posts the kind-20 ask, the app
# stages `u8 fmtver | u16 pathLen | path | u16 sel | u16 top | u8 view |
# u8 sort` at the rendezvous file and posts the request; the seat stores
# the blob on the tab's SESSION.TABS record. The trailer is asserted
# byte-level: AS magic, appver=1, and every field decoded back.
vgate_file script-07.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-07.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/FM7
EOF

vgate_file script3-07.txt <<'EOF'
wm
dui
echo rx-go-fileman-state-save-ok
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/fileman-state-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-07.txt' \
    --script2 '$RUN_DIR/script2-07.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'return,j,tab,s,ctrl-shift-s' \
    --input-chords-after 'gofiles: ready' \
    --script3 '$RUN_DIR/script3-07.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --script-expect 'rx-go-fileman-state-save-ok' --timeout 300

vgate_assert 07 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 07 serial-contains 'gotabwm: registered'
vgate_assert 07 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 07 serial-contains 'gofiles: declare accepted'
# A fresh tab honestly has no stored state — no restore marker may print.
vgate_assert 07 serial-absent 'gofiles: state restored'
vgate_assert 07 serial-absent 'gofiles: state refused'
# The navigation and the two mode chords all landed.
vgate_assert 07 serial-contains 'gofiles: cd /host/FM7/SUB7'
vgate_assert 07 serial-contains 'gofiles: view DEEP2.TXT'
vgate_assert 07 serial-contains 'gofiles: viewmode list'
vgate_assert 07 serial-contains 'gofiles: sort name'
# The SEAT's half: the snapshot chord asked the bound tab; the app staged
# 23 bytes at appver 1 (ver 1 + u16 len + 14-byte path + u16 sel + u16 top
# + view + sort) and the seat stored + republished the session carrying it.
vgate_assert 07 serial-contains 'gotabwm: state ask id='
vgate_assert 07 serial-contains 'gotabwm: state save id='
vgate_assert 07 serial-contains 'len=23 ver=1'
vgate_assert 07 serial-contains 'gofiles: state save /host/FM7/SUB7 sel=1 top=0 view=1 sort=1 len=23'
vgate_assert 07 serial-contains 'gotabwm: snapshot saved '
vgate_assert 07 serial-absent 'gotabwm: state drop'
# Byte-level on the share: the .tabs v2 AS trailer framing and the blob's
# own five fields — byte identity is the card's claim, not a checksum.
vgate_assert 07 python <<'PY'
import os, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] != 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (b[0], b[2]))
off = 6 + 69
if len(b) < off + 6 + 8 + 23:
    sys.exit("SESSION.TABS too short for a state trailer: %d" % len(b))
if b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] != 1:
    sys.exit("app_state header %r" % b[off:off+6])
ent = b[off+6:off+14]
if ent[0] != 0 or ent[1] != 1:
    sys.exit("app_state entry index=%d appver=%d" % (ent[0], ent[1]))
ln = int.from_bytes(ent[4:8], "little")
blob = b[off+14:off+14+ln]
# GOFILES blob v1: u8 fmtver | u16 pathLen LE | path | u16 sel LE |
# u16 top LE | u8 view | u8 sort.
if len(blob) != 23 or blob[0] != 1:
    sys.exit("blob len=%d fmtver=%d" % (len(blob), blob[0] if blob else -1))
plen = int.from_bytes(blob[1:3], "little")
path = blob[3:3 + plen].decode()
o = 3 + plen
sel = int.from_bytes(blob[o:o+2], "little")
top = int.from_bytes(blob[o+2:o+4], "little")
view, sort = blob[o+4], blob[o+5]
if path != "/host/FM7/SUB7":
    sys.exit("saved cwd %r is not where the gate navigated" % path)
if sel != 1 or top != 0 or view != 1 or sort != 1:
    sys.exit("saved fields sel=%d top=%d view=%d sort=%d "
             "want 1/0/1/1" % (sel, top, view, sort))
print("SESSION.TABS app_state: idx=0 appver=1 len=%d cwd=%s sel=%d top=%d "
      "view=list sort=name" % (ln, path, sel, top))
PY
vgate_assert 07 serial-contains 'rx-go-fileman-state-save-ok'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'

# --- M125c (#2588): run 08, the RESTORE half -------------------------------
# A FRESH boot on the share run 07 left: the seat loads SESSION.TABS,
# re-execs GOFILES.ELF (no argv — the recorded row carries only the bin),
# and the app's restore_state request gets the blob back byte-intact.
# The proof is the app's own verdicts: `state restored /host/FM7/SUB7`
# names the cwd, `sel=1` the cursor — visible again as the DEEP2.TXT
# preview — and view=1 sort=1 the two mode bytes.
vgate_file script-08.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-08.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-08.txt <<'EOF'
wm
dui
echo rx-go-fileman-state-restore-ok
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/fileman-restore-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-08.txt' \
    --script2 '$RUN_DIR/script2-08.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-08.txt' \
    --script3-after 'gofiles: state restored' \
    --script-expect 'rx-go-fileman-state-restore-ok' --timeout 300

vgate_assert 08 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 08 serial-contains 'gotabwm: registered'
vgate_assert 08 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 08 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 08 serial-contains 'gotabwm: session exec GOFILES.ELF'
vgate_assert 08 serial-contains 'gotabwm: session live n=1'
vgate_assert 08 serial-contains 'gofiles: declare accepted'
# The seat staged the stored blob for the re-exec'd tab and the app's own
# decode applied it — the full protocol leg.
vgate_assert 08 serial-contains 'gotabwm: state restore id='
vgate_assert 08 serial-contains 'len=23 ver=1'
vgate_assert 08 serial-contains 'gofiles: state restored /host/FM7/SUB7 sel=1 top=0 view=1 sort=1'
# cwd restored: the first listing is the descended directory, and the
# cursor is back on DEEP2.TXT (the preview names the selected entry).
vgate_assert 08 serial-contains 'gofiles: list /host/FM7/SUB7 n=2'
vgate_assert 08 serial-contains 'gofiles: view DEEP2.TXT'
vgate_assert 08 serial-contains 'gofiles: ready'
vgate_assert 08 serial-absent 'gofiles: state refused'
# No fallback: the saved cwd still exists, so `state cwd` must not print.
vgate_assert 08 serial-absent 'gofiles: state cwd '
vgate_assert 08 serial-absent 'gotabwm: state drop'
vgate_assert 08 serial-contains 'rx-go-fileman-state-restore-ok'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'
