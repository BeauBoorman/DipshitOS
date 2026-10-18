# go-gostalgia.spec -- M95b (#2010) + M95c (#2011) + M95f (#2014): the
# pinned Gostalgia tree built as a GOOS=virelai guest through the overlay
# mechanism. Run 01 is the M95b adapter gate (mem:// IPC, file primitives,
# sys_exec'd child, in-band shutdown) and is unchanged. Runs 02-04 are the
# M95c terminal backend gate: GOSTALGIA.ELF's Bubble Tea v1 shell on a
# GOTABWM-hosted window tty, driven by real HID keystrokes — never
# synthetic app input. Runs 06-07 are the M95f packaging gate: the
# APPS.TXT v2 row launched from the seat's own launcher over real HID,
# the hosted window on the strip + kernel registry with its title, and
# clean exit back to the desktop.
#
#   run 02: render + echo + typed `exit` -> status 0. `dui focus` is the
#           marker-gated refocus: the seat's own chrome windows (the Apps
#           button, blur probe) grab kernel focus at open — typing waits
#           for `dui focus: focused=3` so every key lands on the bound tty.
#   run 03: seat relayout resize + WIN_CLOSE. ctrl-shift-v cycles the
#           live seat's split (needs the staged CHARMHELLO tab), both
#           panes re-rect through wm_apply_rect -> WIN_RESIZE -> 80x21.
#   run 04: text-grid readback — kernel selection -> ctrl-shift-c copy ->
#           monitor `clip` — proves typed commands reached the shell and
#           its replies painted the grid; ctrl-c exits via the sig seam.
#   run 05: font-zoom resize — `font large` is the kernel's own WIN_RESIZE
#           delivery (M80i): the bound grid re-flows to the 10x21 rung and
#           the app re-reads TerminalCell — 80x44 -> 80x33.
#   run 06: launcher exec — ctrl-space + typed filter `gostalgia` + Return
#           over real HID runs the APPS.TXT v2 row's argv; `exit` typed on
#           the bound tty exits 0; a post-exit Enter on the emptied strip
#           re-opens the launcher (desktop took the keyboard back).
#   run 07: same launch, then the rail close-x click (rightmost 16 px of
#           the single cell, y<22) drives closeTabByID -> WmctlWinClose ->
#           WIN_CLOSE -> the same in-band shutdown seam -> status 0.
#   run 08: M95g acceptance (#2015) — the full guest journey in one cold
#           boot: seat -> launcher exec -> the marker-paced shell session
#           (launch + echo, dir + type on the seeded manifest, apps
#           LIVE/READY, a clipboard-pasted `call fs/read` byte channel)
#           -> a marker-triggered raw-framebuffer snapshot whose glyph
#           decode proves the seeded document byte-exact -> typed `exit`
#           -> status 0, window gone, focus on the desktop.
#
# HOST PREREQUISITE: `.build/go/GSSMOKE.ELF` and `.build/go/GOSTALGIA.ELF`
# via `bash tools/go/build-gostalgia.sh` (overlay leg; --no-overlay is the
# fail-before leg — the staged pin has no cmd/gssmoke and refuses).
#
# exec-order: assert-proven -- every run ends on markers only the exec'd
# program emits (`gostalgia: done`, `procs GOSTALGIA.ELF exited status=0`,
# `gssmoke: done`); no script-supplied echo gates a run's end.

vgate_name go-gostalgia "M95b/c: pinned Gostalgia on Virelai — gsport adapters + Bubble Tea v1 on a bound GOTABWM window tty"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
strace exec GSSMOKE.ELF
EOF

vgate_file script-02.txt <<'EOF'
exec GOSTALGIA.ELF
EOF

vgate_file script-02b.txt <<'EOF'
dui focus 3
EOF

# script-02c's bare `dui` registry dump doubles as the post-echo repaint
# barrier: it runs 2 s after the echo reply marker, so the guest-side
# snapshot (on `dui[`) reads the repainted grid.
vgate_file script-02c.txt <<'EOF'
dui
EOF

vgate_file script-05.txt <<'EOF'
exec GOSTALGIA.ELF
EOF

# focus before zoom: the font leg needs no input, but the exit chord does.
vgate_file script-05b.txt <<'EOF'
dui focus 3
font large
EOF

# `dui` runs 2 s after the 80x33 marker — the post-zoom repaint barrier,
# same shape as script-02c.
vgate_file script-05c.txt <<'EOF'
dui
EOF

vgate_file script-03.txt <<'EOF'
exec GOSTALGIA.ELF
EOF

vgate_file script-03b.txt <<'EOF'
exec CHARMHELLO.ELF
EOF

# `dui` first (geometry evidence + the screenshot marker), then close the
# GOSTALGIA window by id (the seat itself holds id 2) — the kernel release pushes WIN_CLOSE to its
# owner, which is the run's exit leg.
vgate_file script-03c.txt <<'EOF'
dui
dui close 3
EOF

vgate_file script-04.txt <<'EOF'
exec GOSTALGIA.ELF
EOF

# Same seat-chrome focus steal as run 02: the clock window (seat-owned,
# opened right after the declare) grabs kernel focus, so the typed echo
# must wait for `dui focus: focused=3` before any key is injected.
vgate_file script-04b.txt <<'EOF'
dui focus 3
EOF

# `clip` prints the clipboard lines on the console (the readback half of
# the echo proof); `dui close 3` is only a failsafe so a stalled ctrl-c
# still ends the boot.
vgate_file script-04c.txt <<'EOF'
clip
dui close 3
EOF

# --- M95f run-06/07 inputs ---------------------------------------------------
# Baseline process snapshot before the launcher runs anything: its
# `procs: count=` line doubles as the chords anchor, since script delivery
# is already gated on the seat's first present.
vgate_file script-06.txt <<'EOF'
procs
EOF

# The kernel registry dump while GOSTALGIA is hosted — the dui[ row set is
# what the post-exit dump is diffed against.
vgate_file script-06b.txt <<'EOF'
dui
EOF

# Post-exit snapshot. `procs` proves the registry returned to its
# pre-launch rows; `dui` proves the window is gone and kernel focus fell
# back to the desktop (`focused=0`); `procs receipt` emits the one-shot
# `runtime-receipt` line that anchors the post-exit Enter keystroke.
vgate_file script-06c.txt <<'EOF'
procs
dui
procs receipt GOSTALGIA.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.path.join(rd, "share")
src = os.path.join(".build", "go", "GSSMOKE.ELF")
if not os.path.exists(src):
    sys.exit("GSSMOKE.ELF missing (build it first: bash tools/go/build-gostalgia.sh)")
shutil.copy(src, os.path.join(share, "GSSMOKE.ELF"))
print("staged GSSMOKE.ELF into share (%d bytes)" % os.path.getsize(src))
gsrc = os.path.join(".build", "go", "GOSTALGIA.ELF")
if not os.path.exists(gsrc):
    sys.exit("GOSTALGIA.ELF missing (build it first: bash tools/go/build-gostalgia.sh gostalgia)")
shutil.copy(gsrc, os.path.join(share, "GOSTALGIA.ELF"))
print("staged GOSTALGIA.ELF into share (%d bytes)" % os.path.getsize(gsrc))
csrc = os.path.join(".build", "go", "CHARMHELLO.ELF")
if not os.path.exists(csrc):
    sys.exit("CHARMHELLO.ELF missing (build it first: bash tools/go/build-charmhello.sh)")
shutil.copy(csrc, os.path.join(share, "CHARMHELLO.ELF"))
print("staged CHARMHELLO.ELF into share (%d bytes)" % os.path.getsize(csrc))
# The seat itself is a Go ELF: the seed bundle only carries zig-out bins,
# so without this the boot logs `GOTABWM.ELF not on the share (shim
# compositing)` and no hosted-window grant ever arrives.
wsrc = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(wsrc):
    sys.exit("GOTABWM.ELF missing (build it first: bash tools/go/build-gotabwm.sh)")
shutil.copy(wsrc, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" % os.path.getsize(wsrc))
# Isolate headless fixture boots from the default Go seat (same trick as
# live-strace): no WM seating, so the smoke runs on a quiet desktop. Run
# 01's tag assert restores the default seat for runs 02-04.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
PY

vgate_run 01 -- \
    --script '$RUN_DIR/script.txt' \
    --script-expect 'gssmoke: done' --timeout 180

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'strace: armed'
# `strace exec` bypasses the monitor's "exec: loaded" print (it calls
# esp_exec.exec_file directly); "gssmoke: ready" is the load evidence.
vgate_assert 01 serial-contains 'gssmoke: ready endpoint=mem://gostalgia-'
vgate_assert 01 serial-contains 'gssmoke: file ok'
vgate_assert 01 serial-contains 'gssmoke: spawn pid='
vgate_assert 01 serial-contains 'status=42'
vgate_assert 01 serial-contains 'gssmoke: clock now='
vgate_assert 01 serial-contains 'gssmoke: echo msg="m95b smoke"'
vgate_assert 01 serial-contains 'gssmoke: shutdown'
vgate_assert 01 serial-contains 'gssmoke: done'
vgate_assert 01 serial-absent 'gssmoke: FAIL'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# Slot evidence: decode the strace records, map sys_* names to ADR 0007
# slot numbers, and require the adapter set. This deliberately does NOT
# assert argument layout — only that the program burned the named slots
# and that no adapted path came back ENOSYS.
vgate_assert 01 python <<'PY'
import os, re, sys

serial = open(os.environ["VG_SER"], errors="replace").read()
records = re.findall(r"\[strace (\d+)\] (sys_[a-z_0-9]+)\(([^\n]*)", serial)
if not records:
    raise SystemExit("no decoded strace records")

# ADR 0007 name -> slot. Asserting the name set IS asserting the slot set:
# the decoder renders slots from the kernel's own table.
name_to_slot = {
    "sys_write": 1, "sys_exit": 3, "sys_sleep": 4,
    "sys_procs": 7,
    "sys_file_open": 23, "sys_file_read": 24, "sys_file_write": 25,
    "sys_file_close": 26, "sys_dir_list": 27,
    "sys_exec": 28, "sys_kill": 29,
    "sys_file_delete": 34, "sys_file_rename": 35,
    "sys_mmap": 63, "sys_time": 66, "sys_getrandom": 72,
    "sys_file_sync": 77,
}
observed = {name_to_slot[name] for _, name, _ in records if name in name_to_slot}
required = {4, 7, 23, 24, 25, 26, 27, 28, 34, 35, 77}
missing = sorted(required - observed)
if missing:
    raise SystemExit("adapter slots missing from trace: %s" % missing)
for pid, name, args in records:
    # ENOSYS renders decoded as "= -ENOSYS", raw as the two's-complement
    # of -4: 0xfffffffffffffffc.
    if args.endswith("= -ENOSYS") or args.endswith("= 0xfffffffffffffffc"):
        raise SystemExit("ENOSYS on %s from pid %s — an adapted path refused" % (name, pid))
print("slot evidence %s; no ENOSYS on %d records" % (sorted(observed & required), len(records)))
PY

# Between-run restore for boots 02-05 (evaluated after run 01, before run
# 02 — vgate.sh's tag-filtered assert loop): drop the wm=none override so
# the default GOTABWM seat autostarts and the window-tty legs can bind a
# hosted window. The same write on tag 02 guarantees the medium rung for
# 03-05's cell math.
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert (vgate_share seed?)")
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\n")
print("between-run restore: SETTINGS.TXT back to defaults (seat + medium font)")
PY

# --- boot 02: render + echo + `exit` ---------------------------------------
# The chain, each step gated on a marker only the guest produces:
#   exec GOSTALGIA.ELF  -> the app opens its .user window, the seat hosts
#                        it (full-viewport grant -> WIN_RESIZE -> 80x44),
#                        gsport/tty binds /dev/tty to the window and the
#                        Bubble Tea shell starts. `gostalgia:` markers ride
#                        the kernel console (fd 1), never the tty.
#   ready endpoint=     -> script-02b `dui focus 3`: the seat's own chrome
#                        windows (the 1x1 blur probe, the Apps button)
#                        grabbed kernel focus at open; the restore is the
#                        seat's syncSeatChrome path, but the `dui focus:
#                        focused=3` marker is what proves it held before a
#                        single key is typed.
#   call app/list ok    -> --input-string types `echo m95c tty echo ok`:
#                        real HID key reports -> bound-tty bytes (the
#                        adapter maps the kernel's LF Enter to the CR the
#                        Charm key table names `enter`) -> the shell's IPC
#                        round trip to the echo app. The gate is the
#                        Init discovery call, not the focus marker: the
#                        model's `busy` flag drops every key until
#                        `app/list` returns (observed r2: focus held,
#                        keys fanned out to the seat AND the bound tty,
#                        no `call ...echo ok` — typed inside the busy
#                        window). Focus still held: nothing re-opens a
#                        window between `dui focus` and this marker.
#   call ...echo ok     -> --screenshot-after captures the repainted frame.
#   call ...echo ok +2s -> script-02c `dui`: registry dump (geometry
#                        evidence) and the `dui[` marker that the
#                        guest-side snapshot and the exit chords key on —
#                        2 s guarantees the app's own repaint is what the
#                        snapshot sees.
#   dui[                -> --input-chords types `exit` + Return ->
#                        sys/shutdown -> the in-band seam -> closedMsg ->
#                        tea.Quit -> teardown -> status 0.
vgate_run 02 -- \
    --screen '$RUN_DIR/gos-02' \
    --input --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/gos-02-snap' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script-02b.txt' \
    --script2-after 'gostalgia: ready endpoint=' --script2-delay 1 \
    --input-string $'echo m95c tty echo ok\n' \
    --input-string-after 'gostalgia: call app/list ok' \
    --screenshot-after 'gostalgia: call app/com.gostalgia.echo/echo ok' \
    --script3 '$RUN_DIR/script-02c.txt' \
    --script3-after 'gostalgia: call app/com.gostalgia.echo/echo ok' --script3-delay 2 \
    --snapshot-after 'dui[' \
    --input-chords 'e,x,i,t,return' \
    --input-chords-after 'dui[' \
    --script-expect 'procs GOSTALGIA.ELF exited status=0' --timeout 240

vgate_assert 02 serial-contains 'gostalgia: tty attached window=3'
# The marker-gated refocus — typed keys depend on it (the seat's clock
# window steals kernel focus right after the declare).
vgate_assert 02 serial-contains 'dui focus: focused=3'
# The two size markers pin the declared rect's cells and the seat's
# full-viewport grant (the font-zoom rung change lives on run 05).
vgate_assert 02 serial-contains 'gostalgia: size 80x24'
vgate_assert 02 serial-contains 'gostalgia: size 80x44'
# gsport/tty's one-shot marker on the first non-empty tty read — the
# kernel's key push reached the bound terminal and the app drained it.
vgate_assert 02 serial-contains 'tty: input n='
vgate_assert 02 serial-contains 'gostalgia: call app/list ok'
vgate_assert 02 serial-contains 'gostalgia: call app/com.gostalgia.echo/echo ok'
vgate_assert 02 serial-contains 'gostalgia: shutdown reason='
vgate_assert 02 serial-contains 'gostalgia: done'
vgate_assert 02 serial-contains 'procs GOSTALGIA.ELF exited status=0'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'panic:'

# Between-run restore for boots 03-05: guarantee the medium rung — the
# cell math below (80x21 splits, the readback drag, the 80x33 zoom)
# assumes it, and a persisted font_size survives across these boots.
# Same block deletes SESSION.TABS: the seat restores it on the NEXT boot
# and the restored tab is a placeholder row — a real strip cell whose
# window id is dead. Run 03's applySplit then rects tabs.At(0) (the
# ghost) through WmctlSetWindowRect, fails honestly, and the split never
# happens (observed r3: `session load n=1 mode=restore`, `rail n=2`, two
# chord WM_KEYs, no `split` marker). go-dogfood boots 03->04 hit the same
# class and use this same between-run-assert slot for the delete (the
# setup hooks all run before boot 01, so there is nowhere earlier to put
# it); vgate.sh does the harness-level equivalent for WINDOWS.SAV.
vgate_assert 02 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert")
st = os.path.join(share, "SESSION.TABS")
# The delete runs BEFORE the diagnostics below: a failed run 02 is
# exactly when the stale tab must not leak into boot 03 (observed gate4:
# the done-check exited first, the file survived, and `session load
# n=1 mode=restore` put the dead-id ghost on boot 03's strip).
if os.path.exists(st):
    os.remove(st)
    print("between-run cleanup: SESSION.TABS removed (boot 03's strip "
          "starts empty)")
ser = open(os.environ["VG_SER"], "rb").read()
if b"gostalgia: done" not in ser:
    sys.exit("boot 02 did not reach the shell teardown marker")
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\n")
print("between-run restore: font_size reset to the medium rung")
PY

# The render frame at the medium rung: lipgloss' rounded border in ANSI 62
# (0x5f5fd7 = the kernel's xterm256 palette, terminal.zig xterm256Rgb)
# around the whole grid plus the accent line in 117 (0x87d7ff). The
# scanout is 2x the 1280x720 logical geometry; the 80-col grid occupies
# the left 640 logical px at 8x16 cells.
vgate_assert 02 snapshot 'gos-02-after' <<'PY'
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
            a = row[x-bpp] if x >= bpp else 0
            row[x] = (row[x] + ((a + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            a = row[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp]
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            row[x] = (row[x] + pr) & 0xff
    out += row
    prev = row

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

border = accent = 0
for y in range(30, 1440):
    for x in range(0, 1300):
        r, g, b = px(x, y)
        if abs(r - 95) < 40 and abs(g - 95) < 40 and b > 175:
            border += 1
        if r > 100 and r < 170 and g > 180 and b > 220:
            accent += 1
print("shell frame: border-62 px=%d accent-117 px=%d" % (border, accent))
assert border >= 400, ("no lipgloss border on the scanout (%d px): the shell "
                       "never painted its frame" % border)
assert accent >= 20, ("no accent-colour text (%d px): the welcome/prompt "
                      "line did not paint" % accent)
PY

# The post-zoom frame, from the guest's own composed scanout 2 s after the
# resize marker: same border and accent at the 10x21 rung (grid now
# 80x33 -> 800x709 px inside the window). A resize the app never saw would
# leave it painting the 80x44 layout into the re-flowed 33-row grid —
# wrapped borders and a drowned prompt, not this.
vgate_assert 02 snapshot 'gos-02-snap-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)" % (len(raw), need, W, H))

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])

border = accent = 0
for y in range(16, 710):
    for x in range(0, 820):
        r, g, b = px(x, y)
        if abs(r - 95) < 40 and abs(g - 95) < 40 and b > 175:
            border += 1
        if r > 100 and r < 170 and g > 180 and b > 220:
            accent += 1
print("post-zoom frame: border-62 px=%d accent-117 px=%d" % (border, accent))
assert border >= 200, ("post-zoom frame lost the shell border (%d px): the "
                       "app repainted nothing at the new cell rung" % border)
assert accent >= 15, ("post-zoom frame lost the accent text (%d px)" % accent)
PY

# --- boot 03: seat relayout resize + WIN_CLOSE ----------------------------
#   exec GOSTALGIA.ELF            -> hosted, grants 80x44.
#   gostalgia: ready endpoint=    -> script-03b execs CHARMHELLO: the
#                                  strip's second tab — ctrl-shift-v only
#                                  splits with >= 2 tabs (hid.go).
#   charmhello: ready             -> --input-chords ctrl-shift-v x2: the
#                                  seat's live split cycle none -> V ->
#                                  H. Each press also reaches the
#                                  kernel's focused-terminal paste chord —
#                                  `tty: paste 0 bytes` with the empty
#                                  clipboard, harmless.
#   gotabwm: split h              -> both panes re-rect through
#                                  wm_apply_rect -> WIN_RESIZE to the
#                                  owners -> `gostalgia: size 80x21`
#                                  (1280x360 pane, (360-16)/16).
#   split h + 3 s                 -> script-03c `dui` (dump + the `dui[`
#                                  marker the screenshot keys on, after
#                                  the repaint) then `dui close 3`:
#                                  kernel release -> WIN_CLOSE -> the
#                                  event goroutine's NotifyClose -> the
#                                  same in-band seam -> status 0.
vgate_run 03 -- \
    --screen '$RUN_DIR/gos-03' \
    --input --via-virtio \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script-03b.txt' \
    --script2-after 'gostalgia: ready endpoint=' \
    --input-chords 'ctrl-shift-v,ctrl-shift-v' \
    --input-chords-after 'charmhello: ready' \
    --screenshot-after 'dui[' \
    --script3 '$RUN_DIR/script-03c.txt' \
    --script3-after 'gotabwm: split h' --script3-delay 3 \
    --script-expect 'procs GOSTALGIA.ELF exited status=0' --timeout 240

vgate_assert 03 serial-contains 'gostalgia: tty attached window=3'
vgate_assert 03 serial-contains 'gostalgia: size 80x44'
vgate_assert 03 serial-contains 'gotabwm: split v'
vgate_assert 03 serial-contains 'gotabwm: split h'
vgate_assert 03 serial-contains 'gostalgia: size 80x21'
vgate_assert 03 serial-contains 'gostalgia: shutdown reason='
vgate_assert 03 serial-contains 'gostalgia: done'
vgate_assert 03 serial-contains 'procs GOSTALGIA.ELF exited status=0'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 serial-absent 'panic:'

# Same between-run delete as tag 02: run 03's declares (gostalgia +
# charmhello) wrote two SESSION.TABS rows; boot 04 would otherwise
# restore two dead-id placeholder tabs.
vgate_assert 03 python <<'PY'
import os
share = os.environ.get("VG_SHARE")
st = os.path.join(share, "SESSION.TABS") if share else None
if st and os.path.exists(st):
    os.remove(st)
    print("between-run cleanup: SESSION.TABS removed before boot 04")
else:
    print("between-run cleanup: no SESSION.TABS (nothing to remove)")
PY

# The post-split frame (3 s after the relayout, before the close): the
# shell border survives in whichever half-pane the seat assigned it, and
# the OTHER half carries no border ink — a repaint the resize never
# triggered would leave the old layout clipped or spilled, not a clean
# pane-bounded frame.
vgate_assert 03 snapshot 'gos-03-after' <<'PY'
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
            a = row[x-bpp] if x >= bpp else 0
            row[x] = (row[x] + ((a + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            a = row[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp]
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            row[x] = (row[x] + pr) & 0xff
    out += row
    prev = row

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

def border_in(y0, y1):
    n = 0
    for y in range(y0, y1):
        for x in range(0, 2560):
            r, g, b = px(x, y)
            if abs(r - 95) < 40 and abs(g - 95) < 40 and b > 175:
                n += 1
    return n

top = border_in(0, 700)
bot = border_in(760, 1440)
print("post-split frame: border-62 top=%d bottom=%d" % (top, bot))
ok = (top >= 200 and bot * 3 < top) or (bot >= 200 and top * 3 < bot)
assert ok, ("border ink top=%d bottom=%d: no clean pane-bounded repaint — "
            "either nothing repainted after the split or the old layout "
            "spilled into the other pane" % (top, bot))
PY

# --- boot 04: text-grid readback + ctrl-c ---------------------------------
#   exec GOSTALGIA.ELF -> hosted shell; `call app/list ok` means the model
#   is interactive.
#   ready endpoint=    -> script-04b `dui focus 3` (the same clock-window
#   focus steal as run 02) -> `dui focus: focused=3`.
#   call app/list ok   -> --input-string types `echo m95c readback echo`
#   (the Init-discovery marker — the model drops keys while `busy`, same
#   as run 02).
#   call ...echo ok    -> --pointer-virtio drags over the transcript rows
#   (content top = the kernel's ~24 px title band; the drag spans rows ~6-8
#   at the 8x16 rung — the command + reply rows — sized to fit inside the
#   512 B clipboard with the reply intact) -> `dui: term sel begin/end`.
#   sel end            -> --input-chords ctrl-shift-c copies the focused
#   window's selection (`tty: copy N bytes`), then ctrl-c lands 0x03 in
#   the bound tty -> gsport/tty's seam + the model's ctrl+c key -> clean
#   quit.
#   tty: copy          -> script-04c `clip` prints the clipboard lines on
#   the console — the text-grid readback half of the echo proof (the reply
#   text the app painted is read back cell-for-cell) — then `dui close 3`
#   as the failsafe so a stalled ctrl-c still ends the boot.
vgate_run 04 -- \
    --screen '$RUN_DIR/gos-04' \
    --input --via-virtio \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script-04b.txt' \
    --script2-after 'gostalgia: ready endpoint=' --script2-delay 1 \
    --input-string $'echo m95c readback echo\n' \
    --input-string-after 'gostalgia: call app/list ok' \
    --pointer-virtio '24,120,d;1100,168;1100,168,u' \
    --pointer-virtio-after 'gostalgia: call app/com.gostalgia.echo/echo ok' \
    --input-chords 'ctrl-shift-c,ctrl-c' \
    --input-chords-after 'dui: term sel end' \
    --screenshot-after 'tty: copy ' \
    --script3 '$RUN_DIR/script-04c.txt' \
    --script3-after 'tty: copy ' \
    --script-expect 'procs GOSTALGIA.ELF exited status=0' --timeout 240

vgate_assert 04 serial-contains 'gostalgia: tty attached window=3'
vgate_assert 04 serial-contains 'dui focus: focused=3'
vgate_assert 04 serial-contains 'gostalgia: call app/com.gostalgia.echo/echo ok'
vgate_assert 04 serial-contains 'dui: term sel begin'
vgate_assert 04 serial-contains 'dui: term sel end'
vgate_assert 04 serial-contains 'gostalgia: shutdown reason='
vgate_assert 04 serial-contains 'gostalgia: done'
vgate_assert 04 serial-contains 'procs GOSTALGIA.ELF exited status=0'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 serial-absent 'panic:'

# The readback: `clip` prints the whole clipboard after one `clip: ` prefix,
# so a multi-row copy lands as the `clip:` line plus continuation rows. The
# typed command's reply — `m95c readback echo [echo #1]` — must appear
# inside the copied span, which proves the full round trip in grid cells:
# HID bytes -> shell -> IPC -> paint -> cells -> selection -> clipboard.
# `tty: copy` reports a nonzero byte count.
vgate_assert 04 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"tty: copy (\d+) bytes", ser)
if not m:
    sys.exit("no `tty: copy` marker — the selection never reached the clipboard")
if int(m.group(1)) < 40:
    sys.exit("tty: copy %s bytes — the drag selected almost nothing" % m.group(1))
# The clip dump runs from its `clip: ` prefix to the next console prompt;
# continuation rows carry no prefix of their own.
i = ser.find("clip: ", m.end())
if i < 0:
    sys.exit("the `clip` command printed nothing — clipboard readback failed")
j = ser.find("virelai>", i)
block = ser[i:] if j < 0 else ser[i:j]
if "m95c readback echo" not in block:
    sys.exit("the clip dump lacks the echo reply; block=%r" % block[:400])
print("readback: %d bytes copied, reply text present in the clip dump"
      % int(m.group(1)))
PY

# Same between-run delete as tags 02/03 before boot 05.
vgate_assert 04 python <<'PY'
import os
share = os.environ.get("VG_SHARE")
st = os.path.join(share, "SESSION.TABS") if share else None
if st and os.path.exists(st):
    os.remove(st)
    print("between-run cleanup: SESSION.TABS removed before boot 05")
else:
    print("between-run cleanup: no SESSION.TABS (nothing to remove)")
PY

# --- boot 05: font-zoom resize + `exit` -------------------------------------
# The font-zoom half of the resize contract, on its own boot so every step
# keeps a marker gate:
#   exec GOSTALGIA.ELF -> hosted shell, 80x44 on the seat's grant (medium
#                        rung restored on tag 02).
#   ready endpoint=    -> script-05b: `dui focus 3` (the exit chord needs
#                        the same keyboard focus as run 02's typing), then
#                        `font large`: the kernel's own WIN_RESIZE fan-out
#                        (apply_grid_font_size) -> NoteResize re-reads the
#                        now-10x21 rung -> `gostalgia: size 80x33`.
#   size 80x33 + 2 s   -> script-05c `dui`: registry dump + the `dui[`
#                        barrier for the large-font screenshot and exit.
#   dui[               -> --screenshot-after captures the repainted frame;
#                        --input-chords types `exit` -> status 0.
vgate_run 05 -- \
    --screen '$RUN_DIR/gos-05' \
    --input --via-virtio \
    --script '$RUN_DIR/script-05.txt' \
    --script2 '$RUN_DIR/script-05b.txt' \
    --script2-after 'gostalgia: ready endpoint=' --script2-delay 1 \
    --script3 '$RUN_DIR/script-05c.txt' \
    --script3-after 'gostalgia: size 80x33' --script3-delay 6 \
    --screenshot-after 'dui[' \
    --input-chords 'e,x,i,t,return' \
    --input-chords-after 'dui[' \
    --script-expect 'procs GOSTALGIA.ELF exited status=0' --timeout 240

vgate_assert 05 serial-contains 'gostalgia: tty attached window=3'
vgate_assert 05 serial-contains 'dui focus: focused=3'
vgate_assert 05 serial-contains 'gostalgia: size 80x44'
# The font-zoom leg: NoteResize re-read TerminalCell and reported the
# 10x21 rung's cells — the resize path the seat's pixel payload cannot
# express on its own.
vgate_assert 05 serial-contains 'gostalgia: size 80x33'
vgate_assert 05 serial-contains 'gostalgia: shutdown reason='
vgate_assert 05 serial-contains 'gostalgia: done'
vgate_assert 05 serial-contains 'procs GOSTALGIA.ELF exited status=0'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 serial-absent 'panic:'

# The large-font frame still carries the lipgloss border (ANSI 62) and the
# accent line (117): a repaint that never ran would leave the border at the
# old rung's glyph rows; the counts stay well above the medium-rung floor.
vgate_assert 05 snapshot 'gos-05-after' <<'PY'
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
            a = row[x-bpp] if x >= bpp else 0
            row[x] = (row[x] + ((a + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            a = row[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp]
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            row[x] = (row[x] + pr) & 0xff
    out += row
    prev = row

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

border = accent = 0
for y in range(30, 1440):
    for x in range(0, 1700):
        r, g, b = px(x, y)
        if abs(r - 95) < 40 and abs(g - 95) < 40 and b > 175:
            border += 1
        if r > 100 and r < 170 and g > 180 and b > 220:
            accent += 1
print("zoomed shell frame: border-62 px=%d accent-117 px=%d" % (border, accent))
assert border >= 300, ("no lipgloss border on the post-zoom scanout (%d px): "
                       "the shell never repainted at the new rung" % border)
assert accent >= 10, ("no accent-colour text on the post-zoom scanout "
                      "(%d px)" % accent)
PY

# Repeat-cycle hygiene: on BOOTS>1 the next cycle's boot 02 would restore
# this boot's Gostalgia tab as a dead-id placeholder otherwise.
vgate_assert 05 python <<'PY'
import os
share = os.environ.get("VG_SHARE")
st = os.path.join(share, "SESSION.TABS") if share else None
if st and os.path.exists(st):
    os.remove(st)
    print("between-run cleanup: SESSION.TABS removed (repeat hygiene)")
else:
    print("between-run cleanup: no SESSION.TABS (nothing to remove)")
PY

# --- boot 06: launcher exec + typed `exit` (M95f) ----------------------------
# The chain, each step gated on a marker only the guest produces:
#   gotabwm: present   -> script-06 `procs`: the pre-launch process rows;
#                        `procs: count=` is the chords anchor.
#   procs: count=      -> --input-chords types ctrl-space, the filter
#                        `gostalgia`, Return: the seat's own launcher
#                        decodes APPS.TXT (decode receipt reports the v2
#                        field counts), filters to one row, and execs
#                        `GOSTALGIA.ELF shell --root /host/GS`.
#   launcher exec      -> the app declares a fullscreen hosted window
#                        (`gotabwm: tab open id=`, `gotabwm: session
#                        write n=`), gsport/tty binds it, Bubble Tea runs.
#   call app/list ok   -> script-06b `dui` (kernel window registry while
#                        hosted) AND --input-string types `exit` — the
#                        Init-discovery marker means the model's busy
#                        window is past and the declare's focus handoff
#                        settled.
#   exited status=0 +3s-> script-06c `procs` + `dui` + `procs receipt`:
#                        post-exit registry, focus, and process dumps.
#   runtime-receipt    -> --input-key Return on the emptied strip: the
#                        start surface's keyboard affordance re-opens the
#                        launcher — the desktop took the keyboard back.
vgate_run 06 -- \
    --screen '$RUN_DIR/gos-06' \
    --input --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script-after 'gotabwm: present' \
    --input-chords 'ctrl-space,g,o,s,t,a,l,g,i,a,return' \
    --input-chords-after 'procs: count=' \
    --script2 '$RUN_DIR/script-06b.txt' \
    --script2-after 'gostalgia: call app/list ok' \
    --input-string $'exit\n' \
    --input-string-after 'gostalgia: call app/list ok' \
    --script3 '$RUN_DIR/script-06c.txt' \
    --script3-after 'procs GOSTALGIA.ELF exited status=0' --script3-delay 3 \
    --input-key 36 \
    --input-key-after 'runtime-receipt' \
    --script-expect 'procs GOSTALGIA.ELF exited status=0' \
    --script-expect-tail 8 --timeout 240

# Launcher path: the seat opened its launcher, decoded the manifest's v2
# fields (a v2 row with argv/caps bumps those counts), filtered to exactly
# the Gostalgia row, and exec'd it with the row's fixed argv.
vgate_assert 06 serial-contains 'gotabwm: launcher open n='
vgate_assert 06 serial-contains 'gotabwm: launcher filter q=gostalgia n=1'
vgate_assert 06 serial-contains 'gotabwm: launcher exec GOSTALGIA.ELF argv=shell --root /host/GS'
vgate_assert 06 serial-absent 'gotabwm: launcher missing'
# Window-list evidence: the seat's strip gained a tab and persisted the
# session; SESSION.TABS carries the declared title in its fixed-width
# field.
vgate_assert 06 serial-contains 'gotabwm: tab open id='
vgate_assert 06 serial-contains 'gotabwm: session write n='
vgate_assert 06 serial-contains 'gostalgia: tty attached window='
vgate_assert 06 serial-contains 'gostalgia: ready endpoint='
vgate_assert 06 serial-contains 'gostalgia: call app/list ok'
# Clean exit through the in-band seam.
vgate_assert 06 serial-contains 'gostalgia: shutdown reason='
vgate_assert 06 serial-contains 'gostalgia: done'
vgate_assert 06 serial-contains 'procs GOSTALGIA.ELF exited status=0'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
vgate_assert 06 serial-absent 'panic:'
# The persisted window list names the tab by title.
vgate_assert 06 share-contains SESSION.TABS 'Gostalgia'

# Registry/geometry diff, both sides of the exit: the dui[ dump while
# hosted carries a row owned by the Gostalgia pid (correlated from the
# kernel's per-name records — runtime-receipt / zombie procs row — not a
# guessed pid); the post-exit dump has no row for that owner, reports
# focused=0 (kernel focus fell back to the terminal/desktop), `procs:
# count=` returned to its pre-launch value with no GOSTALGIA row left,
# and the seat opened its launcher a second time on the post-exit Enter.
vgate_assert 06 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()

exit_i = ser.find("procs GOSTALGIA.ELF exited status=0")
if exit_i < 0:
    sys.exit("no clean-exit marker")
pre = ser[:exit_i]
post = ser[exit_i:]

# The app's pid comes from the kernel's own per-name records, not `open:`
# ordering: the kernel's open print and the app's attach marker interleave
# nondeterministically, and window ids are recycled (seat chrome held
# id 4 at boot, the app's declare re-used it, the post-exit launcher
# reopen re-uses it again — a last-open-before-attach heuristic picked
# the seat's pid 1 on 2026-10-09). The runtime-receipt names the pid that
# ran GOSTALGIA.ELF; the retained zombie procs row is the same record;
# the first `open:` for the bound window after the exec marker is the
# fallback.
m = (re.search(r"runtime-receipt: pid=(\d+) name=GOSTALGIA\.ELF", post)
     or re.search(r"^procs: id=(\d+)\b[^\n]*name=GOSTALGIA\.ELF",
                  post, re.M))
if m:
    pid = m.group(1)
else:
    w = re.search(r"gostalgia: tty attached window=(\d+)", ser)
    exec_i = ser.find("gotabwm: launcher exec GOSTALGIA.ELF")
    if not w or exec_i < 0:
        sys.exit("no pid in receipt/procs and no attach/exec markers")
    opens_for_id = re.findall(
        r"open: id=%s owner=(\d+)" % re.escape(w.group(1)),
        ser[exec_i:])
    if not opens_for_id:
        sys.exit("no `open: id=%s owner=` row after the exec marker"
                 % w.group(1))
    pid = opens_for_id[0]
print("gostalgia owner pid=%s" % pid)

pre_rows = [l for l in pre.splitlines() if l.startswith("dui[")]
post_rows = [l for l in post.splitlines() if l.startswith("dui[")]
if not any(("owner=%s" % pid) in l for l in pre_rows):
    sys.exit("no dui[] row owned by pid %s while hosted" % pid)
if any(("owner=%s" % pid) in l for l in post_rows):
    sys.exit("dui[] still lists a pid-%s window after exit" % pid)
heads = [l for l in post.splitlines() if l.startswith("dui: windows=")]
if not heads or " focused=0 " not in heads[-1]:
    sys.exit("post-exit dui header missing or focus did not fall back: %r"
             % (heads[-1] if heads else None))

counts = re.findall(r"^procs: count=(\d+)$", ser, re.M)
if len(counts) < 2:
    sys.exit("expected baseline and post-exit procs dumps, got %s" % counts)
base, last = int(counts[0]), int(counts[-1])
# The registry RETAINS exited rows by design (`state=exited task=reaped`
# — a zombie is history, not a live process; the baseline dump already
# carries one). So `count` may sit at baseline+1 while the zombie lingers.
# What must not exist is a LIVE GOSTALGIA row, and a retained zombie must
# read exit=0.
gs_rows_post = [l for l in post.splitlines()
                if l.startswith("procs: id=") and "name=GOSTALGIA.ELF" in l]
bad = [l for l in gs_rows_post
       if "state=exited" not in l or " exit=0" not in l]
if bad:
    sys.exit("post-exit GOSTALGIA rows are not clean zombies: %s" % bad)
if last - base > 1:
    sys.exit("procs count grew by more than one retained zombie: %s -> %s"
             % (base, last))
if "runtime-receipt" not in post:
    sys.exit("the post-exit `procs receipt` query printed nothing")

opens = ser.count("gotabwm: launcher open n=")
if opens != 2:
    sys.exit("expected launcher open x2 (HID summon + post-exit Enter), got %d" % opens)
print("window gone, focused=0, procs %d->%d (zombie retained), launcher reopened"
      % (base, last))
PY

# No crash receipt: the supervisor writes CRASH/*.TXT only for failed
# children; a clean shell exit must leave both plausible roots empty.
vgate_assert 06 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert")
for rel in ("GS/CRASH", "CRASH"):
    d = os.path.join(share, rel)
    if os.path.isdir(d) and os.listdir(d):
        sys.exit("crash receipt(s) under %s: %s" % (rel, os.listdir(d)))
print("no crash receipts on the share")
PY

# Between-run cleanup so boot 07 does not restore boot 06's dead-id tab.
vgate_assert 06 python <<'PY'
import os
share = os.environ.get("VG_SHARE")
st = os.path.join(share, "SESSION.TABS") if share else None
if st and os.path.exists(st):
    os.remove(st)
    print("between-run cleanup: SESSION.TABS removed before boot 07")
else:
    print("between-run cleanup: no SESSION.TABS (nothing to remove)")
PY

# --- boot 07: launcher exec + rail close-x (M95f) ----------------------------
# Same launcher chain as run 06; the exit leg is the seat's real close
# affordance instead of a typed command:
#   call app/list ok -> --pointer-virtio clicks 1272,10: with one tab the
#                      cell paints [0,1280) and railCloseZoneAt puts the
#                      close-x in the rightmost 16 px -> applyRailClose ->
#                      closeTabByID -> WmctlWinClose -> WIN_CLOSE -> the
#                      same in-band shutdown seam -> status 0.
vgate_run 07 -- \
    --screen '$RUN_DIR/gos-07' \
    --input --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script-after 'gotabwm: present' \
    --input-chords 'ctrl-space,g,o,s,t,a,l,g,i,a,return' \
    --input-chords-after 'procs: count=' \
    --script2 '$RUN_DIR/script-06b.txt' \
    --script2-after 'gostalgia: call app/list ok' \
    --pointer-virtio '1272,10,c' \
    --pointer-virtio-after 'gostalgia: call app/list ok' \
    --script3 '$RUN_DIR/script-06c.txt' \
    --script3-after 'procs GOSTALGIA.ELF exited status=0' --script3-delay 3 \
    --input-key 36 \
    --input-key-after 'runtime-receipt' \
    --script-expect 'procs GOSTALGIA.ELF exited status=0' \
    --script-expect-tail 8 --timeout 240

vgate_assert 07 serial-contains 'gotabwm: launcher open n='
vgate_assert 07 serial-contains 'gotabwm: launcher filter q=gostalgia n=1'
vgate_assert 07 serial-contains 'gotabwm: launcher exec GOSTALGIA.ELF argv=shell --root /host/GS'
vgate_assert 07 serial-absent 'gotabwm: launcher missing'
vgate_assert 07 serial-contains 'gotabwm: tab open id='
vgate_assert 07 serial-contains 'gotabwm: session write n='
vgate_assert 07 serial-contains 'gostalgia: tty attached window='
vgate_assert 07 serial-contains 'gostalgia: ready endpoint='
vgate_assert 07 serial-contains 'gostalgia: call app/list ok'
# The close affordance markers: the seat issued the close through the WM
# seam and the strip went empty.
vgate_assert 07 serial-contains 'gotabwm: host close id='
vgate_assert 07 serial-contains 'gotabwm: tab close id='
vgate_assert 07 serial-contains 'gotabwm: tabs empty'
vgate_assert 07 serial-contains 'gostalgia: shutdown reason='
vgate_assert 07 serial-contains 'gostalgia: done'
vgate_assert 07 serial-contains 'procs GOSTALGIA.ELF exited status=0'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'
vgate_assert 07 serial-absent 'panic:'
vgate_assert 07 share-contains SESSION.TABS 'Gostalgia'

# Same registry/focus/process diff as run 06 — the WIN_CLOSE path must
# leave the desktop in the same state the typed `exit` did.
vgate_assert 07 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()

exit_i = ser.find("procs GOSTALGIA.ELF exited status=0")
if exit_i < 0:
    sys.exit("no clean-exit marker")
pre = ser[:exit_i]
post = ser[exit_i:]

# Same pid derivation as run 06: per-name kernel records first
# (runtime-receipt, retained zombie procs row), never `open:` ordering —
# the open print and the attach marker interleave nondeterministically
# and window ids are recycled across the boot.
m = (re.search(r"runtime-receipt: pid=(\d+) name=GOSTALGIA\.ELF", post)
     or re.search(r"^procs: id=(\d+)\b[^\n]*name=GOSTALGIA\.ELF",
                  post, re.M))
if m:
    pid = m.group(1)
else:
    w = re.search(r"gostalgia: tty attached window=(\d+)", ser)
    exec_i = ser.find("gotabwm: launcher exec GOSTALGIA.ELF")
    if not w or exec_i < 0:
        sys.exit("no pid in receipt/procs and no attach/exec markers")
    opens_for_id = re.findall(
        r"open: id=%s owner=(\d+)" % re.escape(w.group(1)),
        ser[exec_i:])
    if not opens_for_id:
        sys.exit("no `open: id=%s owner=` row after the exec marker"
                 % w.group(1))
    pid = opens_for_id[0]
print("gostalgia owner pid=%s" % pid)

pre_rows = [l for l in pre.splitlines() if l.startswith("dui[")]
post_rows = [l for l in post.splitlines() if l.startswith("dui[")]
if not any(("owner=%s" % pid) in l for l in pre_rows):
    sys.exit("no dui[] row owned by pid %s while hosted" % pid)
if any(("owner=%s" % pid) in l for l in post_rows):
    sys.exit("dui[] still lists a pid-%s window after exit" % pid)
heads = [l for l in post.splitlines() if l.startswith("dui: windows=")]
if not heads or " focused=0 " not in heads[-1]:
    sys.exit("post-exit dui header missing or focus did not fall back: %r"
             % (heads[-1] if heads else None))

counts = re.findall(r"^procs: count=(\d+)$", ser, re.M)
if len(counts) < 2:
    sys.exit("expected baseline and post-exit procs dumps, got %s" % counts)
base, last = int(counts[0]), int(counts[-1])
# Same zombie-retention semantics as run 06: a retained row must read
# state=exited exit=0 and count may sit at baseline+1, never higher.
gs_rows_post = [l for l in post.splitlines()
                if l.startswith("procs: id=") and "name=GOSTALGIA.ELF" in l]
bad = [l for l in gs_rows_post
       if "state=exited" not in l or " exit=0" not in l]
if bad:
    sys.exit("post-exit GOSTALGIA rows are not clean zombies: %s" % bad)
if last - base > 1:
    sys.exit("procs count grew by more than one retained zombie: %s -> %s"
             % (base, last))
if "runtime-receipt" not in post:
    sys.exit("the post-exit `procs receipt` query printed nothing")

opens = ser.count("gotabwm: launcher open n=")
if opens != 2:
    sys.exit("expected launcher open x2 (HID summon + post-exit Enter), got %d" % opens)
print("window gone, focused=0, procs %d->%d (zombie retained), launcher reopened"
      % (base, last))
PY

vgate_assert 07 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert")
for rel in ("GS/CRASH", "CRASH"):
    d = os.path.join(share, rel)
    if os.path.isdir(d) and os.listdir(d):
        sys.exit("crash receipt(s) under %s: %s" % (rel, os.listdir(d)))
print("no crash receipts on the share")
PY

# Repeat-cycle hygiene, same as tag 05. Run 05's `font large` persists in
# SETTINGS.TXT across boots (the same hazard the boot-03 restore guards
# against); boot 08's cell math (8x16 medium rung, `size 80x44`, the
# raw-snap glyph decode) assumes medium, so restore the defaults here.
vgate_assert 07 python <<'PY'
import os
share = os.environ.get("VG_SHARE")
st = os.path.join(share, "SESSION.TABS") if share else None
if st and os.path.exists(st):
    os.remove(st)
    print("between-run cleanup: SESSION.TABS removed (repeat hygiene)")
else:
    print("between-run cleanup: no SESSION.TABS (nothing to remove)")
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\n")
print("between-run restore: font_size reset to the medium rung")
PY


# --- boot 08: M95g acceptance journey --------------------------------------
# The card's end-to-end journey in ONE cold boot on the default seat, every
# step marker-gated (issue #2015):
#   gotabwm: present   -> script-08 `procs` prints the pre-launch process
#                        rows; `procs: count=` anchors the summon chord.
#   procs: count=      -> --input-key Return on the empty strip: the start
#                        surface's keyboard affordance opens the launcher
#                        (same empty-strip path run 06's post-exit Enter
#                        uses) — real HID, never a script line.
#   launcher open      -> --input-string types the `gostalgia` filter +
#                        Return; the seat decodes the v2 row and execs
#                        `GOSTALGIA.ELF shell --root /host/GS`.
#   call app/list ok   -> the Init-discovery refresh: the model's busy
#                        window is past, the declare's focus handoff has
#                        settled. script-08b seeds the kernel clipboard
#                        with the raw-IPC command line — `clip <text>` is
#                        the only channel that carries `"`/`{`/`}` (the
#                        HID chord table has no such glyphs, and the
#                        tokenizer's single-quote arm keeps the JSON
#                        byte-exact) — and dumps the hosted registry;
#                        --screenshot-after `dui[` captures the shell at
#                        its prompt for the pixel assert. --input-chords
#                        begins the session at the fixed 0.25 s/stroke
#                        cv-input pace. The model drops keys while busy
#                        and one command's busy window covers its own IPC
#                        call plus the trailing app/list refresh — ~1.4 s
#                        measured — so every command carries a `space`x12
#                        settle tail (a dropped space is free, an
#                        accepted one pads an empty line the next
#                        submit's TrimSpace eats):
#     stop com.gostalgia.echo      normalize the auto-started app -> READY
#     launch com.gostalgia.echo    the card's `launch` leg (app/launch)
#     echo m95g-token              the card's `echo` leg (the in-process
#                                  echo app reflects the token — the call
#                                  marker is contract; the reply row is
#                                  on-screen)
#     dir /                        root of the seeded env VFS (fs/list)
#     type /apps/manifests/com.gostalgia.echo.json
#                                  the host-seeded document (fs/read —
#                                  the runtime writes the echo manifest
#                                  into /apps/manifests at compose time;
#                                  deterministic bytes asserted exactly
#                                  below)
#     apps                         registry lists echo LIVE · PID (app/list)
#     stop com.gostalgia.echo      the card's `stop` leg (app/stop)
#     apps                         registry lists echo READY again
#     cls                          wipes the transcript synchronously so
#                                  the reply block that follows paints
#                                  top-anchored inside the frame
#     <ctrl-shift-v>               pastes `call fs/read {"path":...}` —
#                                  the raw IPC call returns the seeded
#                                  document as base64 inside the grid:
#                                  the byte-exact readback channel
#     call sys/ping                UNIQUE terminal marker — every other
#                                  method fires earlier in the session,
#                                  so `call sys/ping ok` is the only
#                                  gate that proves ALL content rows are
#                                  painted. --snapshot-after fires the
#                                  kind-4 scanout request on it; the
#                                  guest streams the real 1280x720 BGRX
#                                  framebuffer back over queue 4 and the
#                                  snapshot assert glyph-decodes the
#                                  `data_base64` block straight off the
#                                  pixels — the byte proof never touches
#                                  pointer input, so the seat's
#                                  drop-oldest event queue cannot eat it
#                                  under the keystroke flood the way the
#                                  earlier drag-based proof could
#     exit <return>                `e,x,i,t` waits behind a `space`x12
#                                  busy-cover after ping's own call+refresh
#                                  window (an `e` inside it left `xit` on
#                                  the line — observed: the session hung
#                                  to the timeout) — then Return submits
#                                  the quit. `exit` -> tea.Quit -> the
#                                  seam: shutdown reason=shell exited ->
#                                  done -> status 0.
#   exited status=0 +3s-> script-08c: `procs` + `dui` (post-exit registry,
#                        focus) + `procs receipt` (clean-exit record) +
#                        `clip` (the clipboard still holds the seeded
#                        paste line) + `tty` (the binding list is empty
#                        post-exit: `tty: none`) + `input` (HID counters).
#
# The medium-atlas glyph table the snapshot assert decodes against is
# lifted out of kernel/src/font_atlas_data.zig at setup time (setup
# python runs at the repo root) — the gate tests the font the kernel
# actually renders, not a stale copy.
vgate_setup_python <<'PY'
import os, re, sys
src = open("kernel/src/font_atlas_data.zig").read()
m = re.search(
    r'pub const medium = struct \{.*?pub const blob: \*const \[(\d+):0\]u8'
    r' =\s*"(.*?)";', src, re.S)
if not m:
    sys.exit("no medium atlas blob in font_atlas_data.zig")
want, lit = int(m.group(1)), m.group(2)
out = bytearray()
i = 0
while i < len(lit):
    if lit[i] == "\\" and lit[i + 1] == "x":
        out.append(int(lit[i + 2:i + 4], 16))
        i += 4
    else:
        out.append(ord(lit[i]))
        i += 1
if len(out) != want:
    sys.exit("medium atlas decoded %d bytes, want %d" % (len(out), want))
with open(os.path.join(os.environ["RUN_DIR"], "font-med.bin"), "wb") as f:
    f.write(out)
print("font-med.bin staged: %d bytes (95 glyphs x 64 B)" % len(out))
PY

vgate_file script-08.txt <<'EOF'
procs
EOF

# `clip <text>` seeds the clipboard with the raw-IPC command line for the
# ctrl-shift-v paste leg (single-quoted: the JSON survives the tokenizer
# byte-exact); `dui` is the hosted-registry dump AND the screenshot
# marker (`dui[` fires once the shell is painted and idle).
vgate_file script-08b.txt <<'EOF'
clip call fs/read '{"path":"/apps/manifests/com.gostalgia.echo.json"}'
dui
EOF

vgate_file script-08c.txt <<'EOF'
procs
dui
procs receipt GOSTALGIA.ELF
clip
tty
input
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/gos-08' \
    --input --via-virtio \
    --script '$RUN_DIR/script-08.txt' \
    --script-after 'gotabwm: present' \
    --input-key 36 \
    --input-key-after 'procs: count=' \
    --input-string $'gostalgia\n' \
    --input-string-after 'gotabwm: launcher open n=' \
    --script2 '$RUN_DIR/script-08b.txt' \
    --script2-after 'gostalgia: call app/list ok' --script2-delay 2 \
    --screenshot-after 'dui[' \
    --input-chords 'space,space,space,space,space,space,space,space,s,t,o,p,space,c,o,m,.,g,o,s,t,a,l,g,i,a,.,e,c,h,o,return,space,space,space,space,space,space,space,space,space,space,space,space,l,a,u,n,c,h,space,c,o,m,.,g,o,s,t,a,l,g,i,a,.,e,c,h,o,return,space,space,space,space,space,space,space,space,space,space,space,space,e,c,h,o,space,m,9,5,g,-,t,o,k,e,n,return,space,space,space,space,space,space,space,space,space,space,space,space,d,i,r,space,/,return,space,space,space,space,space,space,space,space,space,space,space,space,t,y,p,e,space,/,a,p,p,s,/,m,a,n,i,f,e,s,t,s,/,c,o,m,.,g,o,s,t,a,l,g,i,a,.,e,c,h,o,.,j,s,o,n,return,space,space,space,space,space,space,space,space,space,space,space,space,a,p,p,s,return,space,space,space,space,space,space,space,space,space,space,space,space,s,t,o,p,space,c,o,m,.,g,o,s,t,a,l,g,i,a,.,e,c,h,o,return,space,space,space,space,space,space,space,space,space,space,space,space,a,p,p,s,return,space,space,space,space,space,space,space,space,space,space,space,space,c,l,s,return,space,space,space,space,ctrl-shift-v,return,space,space,space,space,space,space,space,space,space,space,space,space,c,a,l,l,space,s,y,s,/,p,i,n,g,return,space,space,space,space,space,space,space,space,space,space,space,space,e,x,i,t,space,space,space,space,space,space,space,space,return' \
    --input-chords-after 'gostalgia: call app/list ok' \
    --cvc-snap \
    --snapshot-after 'gostalgia: call sys/ping ok' \
    --snapshot-after 'gostalgia: shutdown reason=shell exited' \
    --snapshot-out '$RUN_DIR/snap-08' \
    --script3 '$RUN_DIR/script-08c.txt' \
    --script3-after 'procs GOSTALGIA.ELF exited status=0' --script3-delay 3 \
    --script-expect 'procs GOSTALGIA.ELF exited status=0' \
    --script-expect-tail 10 --timeout 300

# The seat presented itself and the launcher walked the v2 row over HID.
vgate_assert 08 serial-contains 'gotabwm: present'
vgate_assert 08 serial-contains 'procs: count='
vgate_assert 08 serial-contains 'gotabwm: launcher open n='
vgate_assert 08 serial-contains 'gotabwm: launcher filter q=gostalgia n=1'
vgate_assert 08 serial-contains 'gotabwm: launcher exec GOSTALGIA.ELF argv=shell --root /host/GS'
vgate_assert 08 serial-absent 'gotabwm: launcher missing'
# The hosted window landed on the strip and in the session file.
vgate_assert 08 serial-contains 'gotabwm: tab open id='
vgate_assert 08 serial-contains 'gotabwm: session write n='
vgate_assert 08 serial-contains 'gostalgia: tty attached window='
vgate_assert 08 serial-contains 'gostalgia: size 80x44'
vgate_assert 08 serial-contains 'gostalgia: ready endpoint='
vgate_assert 08 serial-contains 'tty: input n='
# The journey's call legs, each through loggedCaller's receipt.
vgate_assert 08 serial-contains 'gostalgia: call app/list ok'
vgate_assert 08 serial-count 'gostalgia: call app/stop ok' 2
vgate_assert 08 serial-contains 'gostalgia: call app/launch ok'
vgate_assert 08 serial-contains 'gostalgia: call app/com.gostalgia.echo/echo ok'
vgate_assert 08 serial-contains 'gostalgia: call fs/list ok'
vgate_assert 08 serial-count 'gostalgia: call fs/read ok' 2
vgate_assert 08 serial-contains 'gostalgia: call sys/ping ok'
# The paste delivered the raw-IPC line into the bound tty.
vgate_assert 08 serial-contains 'tty: paste '
# Clean shutdown through the in-band seam.
vgate_assert 08 serial-contains 'gostalgia: shutdown reason=shell exited'
vgate_assert 08 serial-contains 'gostalgia: done'
vgate_assert 08 serial-contains 'procs GOSTALGIA.ELF exited status=0'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'
vgate_assert 08 serial-absent 'panic:'
vgate_assert 08 serial-absent ' err='
vgate_assert 08 share-contains SESSION.TABS 'Gostalgia'

# Step order: every leg's receipt must land after the one before it —
# presence alone does not prove the journey ran in sequence.
vgate_assert 08 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    ("seat presented",        "gotabwm: present"),
    ("baseline procs",        "procs: count="),
    ("launcher open",         "gotabwm: launcher open n="),
    ("launcher filter",       "gotabwm: launcher filter q=gostalgia n=1"),
    ("launcher exec",         "gotabwm: launcher exec GOSTALGIA.ELF"),
    ("tty attached",          "gostalgia: tty attached window="),
    ("runtime ready",         "gostalgia: ready endpoint="),
    ("init app/list",         "gostalgia: call app/list ok"),
    ("normalize stop",        "gostalgia: call app/stop ok"),
    ("launch echo",           "gostalgia: call app/launch ok"),
    ("echo token",            "gostalgia: call app/com.gostalgia.echo/echo ok"),
    ("dir /",                 "gostalgia: call fs/list ok"),
    ("type document",         "gostalgia: call fs/read ok"),
    ("stop echo",             "gostalgia: call app/stop ok"),
    ("raw fs/read (b64)",     "gostalgia: call fs/read ok"),
    ("sys/ping (paint gate)", "gostalgia: call sys/ping ok"),
    ("shutdown",              "gostalgia: shutdown reason="),
    ("done",                  "gostalgia: done"),
    ("exit status 0",         "procs GOSTALGIA.ELF exited status=0"),
]
at = 0
prev = ""
for name, marker in order:
    i = ser.find(marker, at)
    if i < 0:
        sys.exit("step %r missing after %r (marker %r)" % (name, prev, marker))
    at = i + 1
    prev = name
# The refresh discipline: every non-quit command triggers a follow-up
# app/list, the two explicit `apps` calls add one each, and the init
# discovery adds one more — thirteen minimum when no leg was garbled.
lists = ser.count("gostalgia: call app/list ok")
if lists < 13:
    sys.exit("expected the per-command app/list refreshes, saw %d" % lists)
print("step order verified: %d legs, %d app/list receipts" % (len(order), lists))
PY

# Window/focus/process diff — same pid-correlated contract as run 06:
# hosted while running, gone after exit, focus fell back, and `procs`
# returned to baseline modulo one clean zombie.
vgate_assert 08 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()

exit_i = ser.find("procs GOSTALGIA.ELF exited status=0")
if exit_i < 0:
    sys.exit("no clean-exit marker")
pre = ser[:exit_i]
post = ser[exit_i:]

m = (re.search(r"runtime-receipt: pid=(\d+) name=GOSTALGIA\.ELF", post)
     or re.search(r"^procs: id=(\d+)\b[^\n]*name=GOSTALGIA\.ELF",
                  post, re.M))
if m:
    pid = m.group(1)
else:
    w = re.search(r"gostalgia: tty attached window=(\d+)", ser)
    exec_i = ser.find("gotabwm: launcher exec GOSTALGIA.ELF")
    if not w or exec_i < 0:
        sys.exit("no pid in receipt/procs and no attach/exec markers")
    opens_for_id = re.findall(
        r"open: id=%s owner=(\d+)" % re.escape(w.group(1)),
        ser[exec_i:])
    if not opens_for_id:
        sys.exit("no `open: id=%s owner=` row after the exec marker"
                 % w.group(1))
    pid = opens_for_id[0]
print("gostalgia owner pid=%s" % pid)

pre_rows = [l for l in pre.splitlines() if l.startswith("dui[")]
post_rows = [l for l in post.splitlines() if l.startswith("dui[")]
if not any(("owner=%s" % pid) in l for l in pre_rows):
    sys.exit("no dui[] row owned by pid %s while hosted" % pid)
if any(("owner=%s" % pid) in l for l in post_rows):
    sys.exit("dui[] still lists a pid-%s window after exit" % pid)
heads = [l for l in post.splitlines() if l.startswith("dui: windows=")]
if not heads or " focused=0 " not in heads[-1]:
    sys.exit("post-exit dui header missing or focus did not fall back: %r"
             % (heads[-1] if heads else None))

counts = re.findall(r"^procs: count=(\d+)$", ser, re.M)
if len(counts) < 2:
    sys.exit("expected baseline and post-exit procs dumps, got %s" % counts)
base, last = int(counts[0]), int(counts[-1])
gs_rows_post = [l for l in post.splitlines()
                if l.startswith("procs: id=") and "name=GOSTALGIA.ELF" in l]
bad = [l for l in gs_rows_post
       if "state=exited" not in l or " exit=0" not in l]
if bad:
    sys.exit("post-exit GOSTALGIA rows are not clean zombies: %s" % bad)
if last - base > 1:
    sys.exit("procs count grew by more than one retained zombie: %s -> %s"
             % (base, last))
if "runtime-receipt" not in post:
    sys.exit("the post-exit `procs receipt` query printed nothing")
print("window gone, focused=0, procs %d->%d (zombie retained)"
      % (base, last))
PY

# Byte-exact document proof off the real framebuffer: the snapshot
# trigger fired on `call sys/ping ok` — after `cls` re-anchored the
# transcript, the pasted `call fs/read` reply, and every earlier leg —
# so the streamed 1280x720 BGRX frame shows the whole reply block.
# Each of the 42x76 content cells is glyph-decoded against the medium
# atlas staged at setup (binary ink mask, argmin Hamming over cp 32..126 —
# calibrated on a captured session: ~0.1 s, lossless on this palette).
# Row content only (cols 1..76): the lipgloss `│`/`─` frame cells are
# skipped structurally so their non-ASCII fallbacks cannot inject noise.
# Squashing every decoded row to the base64 alphabet rejoins the
# hard-wrapped payload seamlessly — the expected 296-char payload must be
# a literal substring, then its decode must equal the exact manifest
# bytes apps.SeedManifests writes at compose time
# (json.MarshalIndent(echo.Manifest()) + '\n', computed on the host).
vgate_assert 08 snapshot 'snap-08-*.raw' <<'PY'
import base64, os, re, sys

rd = os.path.dirname(os.path.abspath(sys.argv[1]))
blob = open(os.path.join(rd, "font-med.bin"), "rb").read()
if len(blob) != 6080:
    sys.exit("font-med.bin is %d bytes, want 6080" % len(blob))
GB = {}
for cp in range(32, 127):
    g = blob[(cp - 32) * 64:(cp - 32) * 64 + 64]
    mask = 0
    for y in range(16):
        for b in range(4):
            byte = g[y * 4 + b]
            hi = ((byte >> 4) & 0xF) >= 8
            lo = (byte & 0xF) >= 8
            mask = (mask << 2) | (hi << 1) | lo
    GB[cp] = mask

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want at least %d (1280x720 BGRX)"
             % (len(raw), W * H * 4))

def px(x, y):
    o = (y * W + x) * 4
    return (raw[o + 2], raw[o + 1], raw[o])

def lum(p):
    return p[0] * 0.30 + p[1] * 0.55 + p[2] * 0.15

# The gostalgia window paints fullscreen under the seat rail: grid row 0
# sits at y=16 (top half hidden behind the 22 px rail), 8x16 medium
# cells, frame borders in cols 0 and 77.
Y0 = 16
lines = []
for r in range(42):
    line = []
    for c in range(1, 77):
        x0, y0 = c * 8, Y0 + r * 16
        lums = [lum(px(x0 + k % 8, y0 + k // 8)) for k in range(128)]
        lo, hi = min(lums), max(lums)
        if hi - lo < 20:
            line.append(" ")
            continue
        mid = (lo + hi) / 2
        mask = 0
        for v in lums:
            mask = (mask << 1) | (v >= mid)
        best, bs = 32, 999
        for cp, gm in GB.items():
            d = bin(mask ^ gm).count("1")
            if d < bs:
                bs, best = d, cp
        line.append(chr(best))
    lines.append("".join(line))
text = "\n".join(lines)
squash = re.sub(r"[^A-Za-z0-9+/=]", "", text)

expected = (
    b'{\n'
    b'  "id": "com.gostalgia.echo",\n'
    b'  "name": "Echo",\n'
    b'  "version": "0.1.0",\n'
    b'  "entrypoint": "echo",\n'
    b'  "permissions": [\n'
    b'    "ipc"\n'
    b'  ],\n'
    b'  "description": "Your words, reflected back. A tiny app with a tiny'
    b' permission grant."\n'
    b'}\n')
want_b64 = base64.b64encode(expected).decode()

if "callfs/read" not in squash:
    sys.exit("the pasted `call fs/read` command line is not on the frame:\n%s"
             % text)
if "database64" not in squash:
    sys.exit("no `data_base64` key on the frame:\n%s" % text)
if "comgostalgiaechojson" not in squash:
    sys.exit("the reply's path row is missing or misrendered:\n%s" % text)
if "size220" not in squash:
    sys.exit("the reply's size row is missing or misrendered:\n%s" % text)
i = squash.find(want_b64)
if i < 0:
    k = squash.find("database64") + 10
    sys.exit("the rendered payload does not match the seeded document "
             "(frame holds %r...):\n%s" % (squash[k:k + 60], text))
data = base64.b64decode(squash[i:i + len(want_b64)])
if data != expected:
    sys.exit("seeded document bytes differ after decode: %r" % data[:120])
print("scanout readback: %d-cell grid decoded, %d-char payload byte-exact "
      "(%d B manifest)" % (76 * 42, len(want_b64), len(data)))
PY

# No crash receipt, and none may name GOSTALGIA* — the supervisor writes
# CRASH/*.TXT only for failed children; a clean shell exit leaves both
# plausible roots empty of Gostalgia-named files.
vgate_assert 08 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert")
found = []
for rel in ("GS/CRASH", "CRASH"):
    d = os.path.join(share, rel)
    if not os.path.isdir(d):
        continue
    for name in os.listdir(d):
        found.append(os.path.join(rel, name))
        if name.upper().startswith("GOSTALGIA"):
            sys.exit("CRASH receipt names the guest: %s" % os.path.join(rel, name))
if found:
    sys.exit("crash receipt(s) on the share: %s" % found)
print("no crash receipts on the share")
PY

# The real-scanout pixel assert at the prompt: script-08b's `dui[` fires
# while the shell sits idle at `C:\users\guest>` — the lipgloss border
# (ANSI 62), the accent header (117), and the gold prompt/badge (221)
# must all be on the framebuffer.
vgate_assert 08 snapshot 'gos-08-after' <<'PY'
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
            a = row[x-bpp] if x >= bpp else 0
            row[x] = (row[x] + ((a + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            a = row[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp]
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            row[x] = (row[x] + pr) & 0xff
    out += row
    prev = row

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

border = accent = gold = 0
for y in range(30, 1440):
    for x in range(0, 1700):
        r, g, b = px(x, y)
        if abs(r - 95) < 40 and abs(g - 95) < 40 and b > 175:
            border += 1
        if r > 100 and r < 170 and g > 180 and b > 220:
            accent += 1
        if r > 220 and g > 175 and b < 140:
            gold += 1
print("prompt frame: border-62 px=%d accent-117 px=%d gold-221 px=%d"
      % (border, accent, gold))
assert border >= 300, ("no lipgloss border on the prompt scanout (%d px): "
                       "the shell never painted its frame" % border)
assert accent >= 10, ("no accent-colour header on the prompt scanout "
                      "(%d px)" % accent)
assert gold >= 20, ("no gold prompt/badge on the scanout (%d px): the "
                    "frame is not at the shell prompt" % gold)
PY

# Repeat-cycle hygiene, same as tags 05-07.
vgate_assert 08 python <<'PY'
import os
share = os.environ.get("VG_SHARE")
st = os.path.join(share, "SESSION.TABS") if share else None
if st and os.path.exists(st):
    os.remove(st)
    print("between-run cleanup: SESSION.TABS removed (repeat hygiene)")
else:
    print("between-run cleanup: no SESSION.TABS (nothing to remove)")
PY
