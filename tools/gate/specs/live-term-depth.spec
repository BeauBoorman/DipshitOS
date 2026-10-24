# live-term-depth.spec -- M49 card SD5 class-B gate (issue #1132),
# retargeted by M73d (#1628) onto GOTERM.ELF (the Zig TERM.BIN retires
# into M60's leftovers; markers move `term:` -> `goterm:` by prefix alone,
# the M66c/NOTE pattern — no assertion dropped).
#
# GOTERM first-class window terminal: a share script prints 20 numbered
# lines into the kernel presentation grid, the host pointer (custom-virtio
# kind-2, guest pixels) drag-selects a row in the window's client area, and
# the Ctrl+Shift+C chord copies the selection into the shared clipboard —
# all kernel-side for ANY tty-bound window (kernel/src/input.zig chord
# table, driving_award.zig selection), which is what makes this a front-end
# swap. The monitor `clip` command then prints the copied bytes on the
# serial console — observed selection/copy. M73e (#1629) adds the reverse:
# the wide drag selects all 20 rows (259 B > the old 256 B input queue),
# Ctrl+Shift+V pastes it back through the bound tty (bracketed, DECSET
# 2004), and the editor runs every pasted line — tail line included. Reflow/
# scrollback math is class-A (kernel/src/terminal.zig tests) with the
# paint-path width sync. Boot default is unchanged (the serial console
# still belongs to the monitor while GOTERM owns only its window).
# M73d geometry: this gate boots WITHOUT GOTABWM.ELF (shim compositing,
# GOTERM's kind-8 declare refused — the plain .user window still paints)
# at the classic terminal rect 64,48,640,400 — the SAME rect TERM.BIN
# declared. M73l (#1661, cell 8x16) re-anchors this gate: the 384 px
# client fits 24 rows at cell_h=16 (was 48 at 8), so a 30-line script
# would scroll LINE-00 out of the view and the drag could no longer
# reach it. BIG.SH is 20 lines — still every line, total 22 <= 24 so
# the view never scrolls and line1 stays visible. Both drag ends move:
# y76 = row1 at cell_h=8 but row0 (the prompt line) at 16, so the start
# becomes y84 (row1, client top y64) and the end y392 (row20) — line1
# col0 -> line20 col79 = exactly the 20 BIG.SH rows (259 B, still > the
# 256 B input queue the M73e assertion exists to prove) the copy
# asserts count, with the prompt line excluded and `clip: LINE-00`
# (not `clip: gosh> source ...`) back as the clipboard head.
#
# M80k (#1727) gets its OWN boot (run 03, below): the scrollback only
# exists once the 128-row grid has actually scrolled, and a 20-line paste
# never gets there. Runs 01/02 stay byte-identical to their M73d/#1688
# shape.
#
# M80i (#1725) gets its OWN boot (run 04, below): the zoom ladder leaves
# the 8x16 cell. `font` reports BOTH ladders (the boot look is text small
# + grid MEDIUM), `font large` moves both and re-flows the bound grid to
# the 10x21 cell, and the scanout carries the pixel proof — ink below
# y=112 in the client is impossible for three rows at 8x16 and is exactly
# where the 10x21 cell paints row 2.
#
# #1688: run 02 boots the SAME chain WITH the seat registered —
# GOTABWM.ELF is staged by a tag-01 assert (the go-dogfood WINDOWS.SAV
# precedent) so run 01's shim boot stays byte-identical — and the
# drag-select travels the new slot-65 cmd 15 content forward. Under a
# seat, kernel terminal selection is dormant by WMS5 (pointer_tick
# returns before every selection site); the forward is the only path
# that can print `dui: term sel begin/end` there, which is what makes
# the >256 B Ctrl+Shift+V paste reachable in a seated boot. This is the
# class-B proof for claim #1688, which unblocks M73z (#1638).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF (the seat —
#     same reason as live-term: without it the boot falls back to shim
#     compositing and GOTERM's declare is refused)
#   bash tools/go/build-goterm.sh   ->  .build/go/GOTERM.ELF

vgate_name live-term-depth "#1132 SD5 + M73d #1628: GOTERM pointer selection + Ctrl+Shift+C copy through the kernel grid"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
exec GOTERM.ELF
EOF

vgate_file clip.txt <<'EOF'
tty
clip
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
for name, how in (("GOTERM.ELF", "build-goterm.sh"),):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)" % (name, os.path.getsize(src)))
lines = ["echo LINE-%02d pppp" % i for i in range(20)]
with open(os.path.join(share, "BIG.SH"), "w") as f:
    f.write("\n".join(lines) + "\n")
# M80k (#1727): FILL.SH is the scrollback FILLER for run 03. The real
# arithmetic (#1757, measured — the original "~300 grid rows" here was
# arithmetic on a wrong assumption): gosh does NOT echo `source`d script
# lines, so 150 echo outputs plus the typed `source FILL.SH` line is 151
# newlines against the 128-row grid — the grid absorbs 127 of them and
# exactly 24 rows scroll into the ring. The observed `clear 24` matching
# the window's 24 visible rows was numerology, not a viewport cap (the
# class-A pin in kernel/src/terminal.zig holds both halves). A 20-line
# script would not reach the ring at all: `used` never gets to 128, so
# there is no history to clear and the chord would honestly report 0.
fill = ["echo FILL-%03d pppp" % i for i in range(150)]
with open(os.path.join(share, "FILL.SH"), "w") as f:
    f.write("\n".join(fill) + "\n")
# M154a (#2926): SCRIPT2.SH is run 08's RUNNABLE 20-line script — each
# line appends a row to PL.TXT on the share, so a monitor `cat` reads the
# script's execution back from serial. 24 chars x 20 rows + 19 newlines
# = 499 B: under the 512 B clipboard, over the old 256 B input queue.
lines = ["echo L%02d >> /host/PL.TXT" % i for i in range(20)]
with open(os.path.join(share, "SCRIPT2.SH"), "w") as f:
    f.write("\n".join(lines) + "\n")
# M121c (#2566): run 09's $Q readback — `$`/`>` are outside the cv-input
# HID map (the PENV.SH/PCWD.SH constraint), so the write of the read's
# answer into the share lives in a script the leg can `source`.
with open(os.path.join(share, "HINTSE.SH"), "w") as f:
    # `false` ends the script at status=1: `goterm: done status=1` is then
    # the unique "the source child has fully exited" anchor the
    # overlay-open '?' hangs on (read's own `done status=0` is ambiguous —
    # it fires for EVERY zero-exit line).
    f.write("echo $Q > /host/HINTS-Q.OUT\nfalse\n")
PY

vgate_run 01 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'source BIG.SH'$'\n' \
    --input-string-after 'goterm: attached' \
    --pointer-virtio "68,84;68,84,d;696,392;696,392,u" \
    --pointer-virtio-after 'goterm: line source BIG.SH' \
    --input-chords "ctrl-shift-c,ctrl-shift-v,return,e,c,h,o,space,a,f,t,e,r,return" \
    --input-chords-after 'dui: term sel end' \
    --script2 '$RUN_DIR/clip.txt' \
    --script2-after 'goterm: line echo after' \
    --script-expect 'clip: LINE-00' \
    --timeout 150

vgate_assert 01 serial-contains 'goterm: ready'
vgate_assert 01 serial-contains 'goterm: attached'
vgate_assert 01 serial-contains 'goterm: line source BIG.SH'
vgate_assert 01 serial-contains 'goterm: done status=0'
vgate_assert 01 serial-contains 'tty: copy 259 bytes'
vgate_assert 01 serial-contains 'clip: LINE-00'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_done = ser.find("goterm: done status=0")
i_copy = ser.find("tty: copy ")
i_clip = ser.find("clip: LINE-00")
assert i_done >= 0, "BIG.SH did not finish"
assert i_copy > i_done, f"copy marker not after the script (done={i_done} copy={i_copy})"
assert i_clip > i_copy, f"clip read not after the copy (copy={i_copy} clip={i_clip})"
print("selection/copy ordering OK: goterm done < tty copy < clip read")
PY

# M73f-2 (#1632): the monitor `tty` line prints the ADR 0020 D1 drop
# counters. Assert the SHAPE after real activity — not zero: honest values
# until M73f-1/the acceptance card, where M73z pins 0/0 after a repaint.
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"tty\[\d+\]: out_dropped=\d+ in_dropped=\d+", ser)
assert m, "tty drop-counter line missing from serial"
i_copy = ser.find("tty: copy ")
assert i_copy >= 0, "copy marker missing (precondition)"
i_tty = ser.find(m.group(0))
assert i_tty > i_copy, f"tty line not after activity (copy={i_copy} tty={i_tty})"
print(f"drop-counter line OK: {m.group(0)} (after copy activity)")
PY

# M73e (#1629): the reverse direction — Ctrl+Shift+V pastes the >256 B
# selection back through the bound tty. The marker's byte count must
# exceed the old 256 B queue (the raised in_capacity + DECSET 2004 wrap
# are what make that land). M154a (#2926) repins the submit contract:
# bracketed paste is ON by default, so the region stages as ONE pending
# edit and the chord's return submits it once — exactly one `goterm: line`
# after the paste marker, holding every pasted row — and `echo after`
# still submits as its own line right behind it.
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"tty: paste (\d+) bytes", ser)
assert m, "paste marker missing from serial"
n = int(m.group(1))
assert n > 256, f"paste must exceed the old 256 B queue (got {n})"
i_copy = ser.find("tty: copy ")
i_paste = ser.find(m.group(0))
assert i_copy >= 0 and i_paste > i_copy, f"paste not after copy (copy={i_copy} paste={i_paste})"
i_line = ser.find("goterm: line ", i_paste)
i_done = ser.find("goterm: done status=", i_line)
i_after = ser.find("goterm: line echo after", i_done)
for name, i in (("submit", i_line), ("done", i_done), ("echo after", i_after)):
    assert i >= 0, f"{name} missing after the paste"
n_sub = ser.count("goterm: line ", i_paste, i_done)
assert n_sub == 1, f"bracketed paste must be ONE submit on Enter (got {n_sub})"
seg = ser[i_line:i_done]
for i in range(20):
    assert ("LINE-%02d pppp" % i) in seg, f"LINE-{i:02d} pppp missing from the one submit"
print(f"bracketed paste OK: {n} bytes; 20 rows in ONE submit, echo after followed")
PY

# #1688 staged proof: stage the seat binary BETWEEN boots — run 01 (above)
# must never see it, so its shim boot stays byte-identical.
vgate_assert 01 python <<'PY'
import os, shutil, sys
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
dst = os.path.join(os.environ["VG_SHARE"], "GOTABWM.ELF")
shutil.copy(src, dst)
print("staged %s into share (%d bytes)" % (dst, os.path.getsize(src)))

# #1688 (b): one restored placeholder tab = the seat's stable state.
# loadSession sets stripDone (the two-tab choreography is skipped) and
# the single-tab countdown only arms on a LIVE declare — GOTERM's
# declare makes n=2, so neither closer fires and the hosted window
# survives the whole chain. Without this, hostTicks=16 closes GOTERM
# mid-drag (observed run 02 r1: `gotabwm: host close id=3` after 3 ptr
# events). `.tabs` v2 pinned byte vector (tabsv2.go layout): header
# [v2, active+1=0, count=1, seq=1, prefs=0] + one 69-byte record
# "Placeholder" (title 32 NUL-pad, flags 0, group 12, bin 24).
rec = b"Placeholder".ljust(32, b"\x00") + bytes(1) + bytes(12) + bytes(24)
blob = bytes([2, 0, 1, 1, 0, 0]) + rec
assert len(blob) == 6 + 69, len(blob)
sess = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
with open(sess, "wb") as f:
    f.write(blob)
print("staged %s (%d bytes)" % (sess, len(blob)))
PY

# Run 02: the identical chain with the seat registered. The forward
# (gotabwm handleWmPointer -> WmctlContentPtr -> wm_content_pointer ->
# content_pointer_pass) is the only way the sel markers can print here.
# Run 02 geometry: under the seat, the declare is ACCEPTED and the
# seat's host-view proposal (SetWindowRect full viewport) lands the
# window at 0,0 1280x720 — NOT run 01's refused-declare 64,48 640x400.
# Client top_y = 0+16 = 16, col = px/8: row1 col0 (LINE-00) = (4,36),
# row20 col79 (LINE-19) = (632,348). Observed mismatch before the
# retarget: begin landed line4/col8 -> `tty: copy 219 bytes`, head
# `clip: pppp`.
vgate_run 02 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'source BIG.SH'$'\n' \
    --input-string-after 'goterm: attached' \
    --pointer-virtio "4,36;4,36,d;632,348;632,348,u" \
    --pointer-virtio-after 'goterm: line source BIG.SH' \
    --input-chords "ctrl-shift-c,ctrl-shift-v,return,e,c,h,o,space,a,f,t,e,r,return" \
    --input-chords-after 'dui: term sel end' \
    --script2 '$RUN_DIR/clip.txt' \
    --script2-after 'goterm: line echo after' \
    --script-expect 'clip: LINE-00' \
    --timeout 180

vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: session load n=1'
vgate_assert 02 serial-contains 'goterm: ready'
vgate_assert 02 serial-contains 'goterm: attached'
vgate_assert 02 serial-contains 'goterm: line source BIG.SH'
vgate_assert 02 serial-contains 'goterm: done status=0'
vgate_assert 02 serial-contains 'dui: term sel begin'
vgate_assert 02 serial-contains 'dui: term sel end'
vgate_assert 02 serial-contains 'tty: copy 259 bytes'
vgate_assert 02 serial-contains 'clip: LINE-00'
vgate_assert 02 serial-absent '\[EXC\]'
vgate_assert 02 serial-absent '[EXC] parking:'

# The #1688 chain order: seat registered BEFORE the drag, the forward's
# begin/end markers INSIDE it, and the copy/paste/readback after — with
# the script's own done/copy/clip tail in run 01's exact order.
vgate_assert 02 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_reg = ser.find("gotabwm: registered")
i_src = ser.find("goterm: line source BIG.SH")
i_begin = ser.find("dui: term sel begin")
i_end = ser.find("dui: term sel end")
i_done = ser.find("goterm: done status=0")
i_copy = ser.find("tty: copy ")
i_clip = ser.find("clip: LINE-00")
for name, i in (("registered", i_reg), ("source line", i_src),
                ("sel begin", i_begin), ("sel end", i_end),
                ("done", i_done), ("copy", i_copy), ("clip", i_clip)):
    assert i >= 0, f"{name} marker missing from serial"
assert i_reg < i_src < i_begin < i_end, (
    f"forward chain out of order: reg={i_reg} src={i_src} begin={i_begin} end={i_end}")
assert i_done < i_copy < i_clip, (
    f"script/copy/readback out of order: done={i_done} copy={i_copy} clip={i_clip}")
print("seated forward chain OK: registered < source < sel begin < sel end < copy < clip")
PY
# M80k (#1727): run 03 is a SHIM boot again — same shape as run 01 — so
# drop the seat that run 01's #1688 assert staged between boots. Without
# this, run 03 inherits the seat, the window lands at 0,0 1280x720, and
# the seat's own input routing + single-tab countdown govern the chords.
vgate_assert 02 python <<'PY'
import os
share = os.environ["VG_SHARE"]
for name in ("GOTABWM.ELF", "SESSION.TABS"):
    p = os.path.join(share, name)
    if os.path.exists(p):
        os.unlink(p)
        print("unstaged %s from share (run 03 boots shim-only)" % p)
print("share now: %s" % sorted(os.listdir(share)))
PY

# --- M80k (#1727): the terminal hygiene chords -------------------------------
# Run 03 is a third boot of the SAME shim chain (no seat, so GOTERM's window
# is the refused-declare 64,48 640x400 rect run 01 uses). FILL.SH scrolls the
# 128-row grid until the ring genuinely holds history, then the chords are
# typed in order:
#   ctrl-shift-k      clear the scrollback (ED 3) + snap the view to the tail
#   ctrl-shift-r      soft reset — styles and modes, grid intact
#   ctrl-shift-alt-r  full RIS — the grid goes too
# Each is intercepted in kernel/src/input.zig BEFORE the tty queue, so the
# guest never sees a byte and the run ends on a monitor command issued after
# all three (script2 is forwarded on the RIS marker, which no script supplies
# — the exec-order anchor). Three snapshots read the SCANOUT at three points:
# filled, cleared (tail still painted), reset (client blank).
#
# exec-order: assert-proven — the run ends on `fill-chords-done`, which only
# script2 prints, and script2 is held behind the `tty: reset full` chord
# marker, so every chord has fired before the run can end.
vgate_file fill.txt <<'EOF'
tty
echo fill-chords-done
EOF

# shot.txt is snap-03-0's anchor: `goterm: done status=0` prints when
# FILL.SH's RunLine returns, but the fill's last rows can still sit in the
# tty pump (pend>0) and the composite that puts them on the scanout lags
# the marker (OBSERVED: snap-03-0 anchored on `done` shipped a
# mid-repaint frame, ink=98 < 200). The monitor echo behind a 4 s settle
# is the live-term `shot-term-pixels` pattern — by the time it prints,
# the filled grid is provably on the scanout.
vgate_file shot.txt <<'EOF'
echo shot-03-filled
EOF

# The two chord batches are serialized through the stream receipts, which
# is the whole point of `--input-chords2`:
#   batch1 (K+R) waits on `cvspike: snap n=1` — stream0 done — so no
#     stroke can outrun req0's service and the fill frame is always
#     pre-chord;
#   batch2 (RIS) waits on `cvspike: snap n=2` — stream1 done — so the
#     cleared-state frame can never be beaten by the RIS composite. With
#     one batch a guest poll stall drains every stroke in ONE pass, the
#     req1 request lands behind the RIS it was supposed to precede, and
#     snap-03-1 ships the post-RIS grid (OBSERVED: ink=12 on a request
#     fired inside the same burst).
vgate_run 03 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --cvc-snap --snapshot-out '$RUN_DIR/snap-03' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'source FILL.SH'$'\n' \
    --input-string-after 'goterm: ready' \
    --input-chords 'ctrl-shift-k,ctrl-shift-r' \
    --input-chords-after 'cvspike: snap n=1' \
    --input-chords2 'ctrl-shift-alt-r' \
    --input-chords2-after 'cvspike: snap n=2' \
    --snapshot-after 'shot-03-filled' \
    --snapshot-after 'tty: clear' \
    --snapshot-after 'tty: reset full' \
    --script2 '$RUN_DIR/fill.txt' \
    --script2-after 'tty: reset full' \
    --script3 '$RUN_DIR/shot.txt' \
    --script3-after 'goterm: done status=0' --script3-delay 4 \
    --script-expect 'fill-chords-done' \
    --timeout 240

vgate_assert 03 serial-contains 'goterm: ready'
vgate_assert 03 serial-contains 'goterm: done status=0'
vgate_assert 03 serial-contains 'shot-03-filled'
vgate_assert 03 serial-contains 'tty: clear'
vgate_assert 03 serial-contains 'tty: reset soft'
vgate_assert 03 serial-contains 'tty: reset full'
vgate_assert 03 serial-contains 'fill-chords-done'
# The stream-completion receipts, pinned so a marker rename fails the run
# with the assert name rather than a missing snap-03-*.raw — and n=3
# proves the THIRD stream completed (the drain could otherwise ship a
# short tail).
vgate_assert 03 serial-contains 'cvspike: snap n=1'
vgate_assert 03 serial-contains 'cvspike: snap n=2'
vgate_assert 03 serial-contains 'cvspike: snap n=3'
vgate_assert 03 serial-absent '\[EXC\]'
vgate_assert 03 serial-absent '[EXC] parking:'

# The clear marker counts what the ring ACTUALLY dropped (Screen.historyCount
# before minus after) and, since #1757, carries the ring-state figures AT
# READ TIME: hist/used/total (the unified depth), vis (the focused window's
# visible rows) and pend (tty output still queued). The chord order is the
# contract: the RIS is the ctrl+shift+alt-R one, and a mis-dispatch would
# show up as a soft/full pair out of order or missing.
vgate_assert 03 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# #1757: the figures are deterministic and ARE the root-cause evidence.
# 151 newlines (the typed line + 150 echo outputs; gosh does not echo
# source'd script lines) against the 128-row grid: 127 absorbed, 24
# scrolled into the ring. hist=24 used=128 total=152 says the ring held
# exactly the fill's overshoot — NOT a viewport cap (24 == rows_visible
# is numerology; the class-A pin in terminal.zig proves a deeper fill
# saturates at history_lines instead) — and pend=0 total=152 at read
# time is the pump-timing proof: the chord read the COMPLETE fill, so
# the "chord raced the pump" reading from the original observation is
# dead too.
m = re.search(r"tty: clear (\d+) lines \(hist=(\d+) used=(\d+) total=(\d+) vis=(\d+) pend=(\d+)\)", ser)
assert m, "clear-scrollback chord marker (with #1757 figures) missing from serial"
n, hist, used, total, vis, pend = (int(m.group(i)) for i in range(1, 7))
assert (n, hist, used, total, vis, pend) == (24, 24, 128, 152, 24, 0), (
    f"clear figures drifted: clear={n} hist={hist} used={used} total={total} "
    f"vis={vis} pend={pend} — expected 24/24/128/152/24/0; see the #1757 "
    f"arithmetic above before touching this pin")
i_fill = ser.find("goterm: done status=0")
i_clear = ser.find(m.group(0))
i_soft = ser.find("tty: reset soft")
i_ris = ser.find("tty: reset full")
i_done = ser.find("fill-chords-done")
for name, i in (("fill finished", i_fill), ("clear", i_clear),
                ("soft reset", i_soft), ("RIS", i_ris), ("post-chord command", i_done)):
    assert i >= 0, f"{name} marker missing from serial"
assert i_fill < i_clear < i_soft < i_ris < i_done, (
    f"chord chain out of order: fill={i_fill} clear={i_clear} "
    f"soft={i_soft} ris={i_ris} done={i_done}")
print(f"M80k chords OK: cleared {n} scrollback lines (hist={hist} used={used} "
      f"total={total} vis={vis} pend={pend}); clear < soft < RIS; guest alive after")
PY

# SNAPSHOT-CHANNEL SERIALIZATION (the run-03 coalescing fix; the defect
# #1757 documented, OBSERVED 2026-09-26 and again on the #3121 re-run):
# when several `--snapshot-after` requests were in flight together the
# channel coalesced them — the guest's `snap_pending` is a bool, so two
# requests drained by one poll_input merge into ONE stream, and the host's
# `pendingSnapPath` was a single slot the next stream header stole (3
# requests, 2 streams, no snap-03-0.raw). The fix is three seams:
#   * the runner parks every fired trigger while an earlier request is
#     still armed-but-unstreamed, so at most one request ever reaches the
#     guest undrained — the labels can no longer steal each other;
#   * the guest prints `cvspike: snap n=N` after each COMPLETED stream —
#     the reliable marker each state-change burst waits on;
#   * every anchor is now post-state: `shot-03-filled` lands after the
#     fill's composite (not `done`, which raced the repaint), `tty: clear`
#     is post-composite by #1757's present-then-marker, and batch2's RIS
#     cannot run until `snap n=2` — so the cleared grid exists on the
#     scanout for the whole window req1 can fire in. A guest poll stall
#     can still delay a request, but it can never again ship a frame of
#     the wrong state or under the wrong name.
#
# The scanout, in the same run. Window client = x 64..700, y 64..448 (run
# 01's refused-declare rect: 79 cols x 24 rows at the M73l 8x16 cell).
# "Ink" = every sampled pixel that differs from the client's own modal
# background, so the measure is theme-agnostic. The three readings ARE the
# deliverable:
#   snap-0  filled   the scrollback tail is on screen
#   snap-1  cleared  STILL on screen — ED 3 drops the ring, it does not blank
#                    the grid the user is looking at
#   snap-2  ris      gone — the full reset took the grid with it
vgate_assert 03 python <<'PY'
import os, sys
RUN = os.environ["RUN_DIR"]
W = 1280
X, Y, CW, CH = 68, 68, 628, 372


def ink(name):
    d = open(os.path.join(RUN, name), "rb").read()
    if len(d) < W * 720 * 4:
        sys.exit("%s too small: %d bytes" % (name, len(d)))

    def px(x, y):
        k = (y * W + x) * 4
        return (d[k + 2], d[k + 1], d[k])

    hist = {}
    for y in range(Y, Y + CH, 2):
        for x in range(X, X + CW, 2):
            p = px(x, y)
            hist[p] = hist.get(p, 0) + 1
    bg = max(hist, key=hist.get)
    n = 0
    for y in range(Y, Y + CH, 2):
        for x in range(X, X + CW, 2):
            p = px(x, y)
            if max(abs(p[0] - bg[0]), abs(p[1] - bg[1]), abs(p[2] - bg[2])) > 40:
                n += 1
    return n


filled = ink("snap-03-0.raw")
cleared = ink("snap-03-1.raw")
reset = ink("snap-03-2.raw")
print("M80k client ink: filled=%d cleared=%d ris=%d" % (filled, cleared, reset))
assert filled > 200, "the fill tail is not on the scanout (ink=%d)" % filled
assert cleared * 2 >= filled, (
    "ctrl-shift-K blanked the visible grid (filled=%d cleared=%d) — ED 3 "
    "clears the SCROLLBACK, not the screen" % (filled, cleared))
assert reset * 4 <= filled, (
    "ctrl-shift-alt-R left the grid on the scanout (filled=%d ris=%d)"
    % (filled, reset))
print("M80k scanout OK: clear keeps the tail, RIS takes the grid")
PY

# --- M80i (#1725): the zoom ladder leaves 8x16 --------------------------------
# Runs 04 and 05 are two more shim boots of the SAME chain (run 03's asserts
# left the share seat-free, so the window is the refused-declare 64,48 640x400
# rect). `echo pppp` paints THREE content rows (echo line, `pppp`, prompt);
# the pair of scanout frames — one per boot — is the pixel proof that the
# bound grid left 8x16:
#   run 04  the boot cell (8x16: rows at y 64/80/96). Glyph descent stays
#           inside the cell, so the client band y 112..127 is EMPTY: for
#           three rows of content there IS no row 4.
#   run 05  the large rung (10x21: rows at y 64/85/106) after the monitor
#           `font` gesture. Row 2 (the prompt) now paints through the same
#           band — glyph bodies and the `g` descender down to y 126, the
#           block cursor filling the cell — so the band MUST carry ink.
# Ink below y=112 is impossible at 8x16 for this content and unavoidable at
# 10x21: its appearance is the glyph-at-the-large-size pixel proof. Run 05's
# serial report names both ladders — the boot look (text small + grid medium)
# and the rung in force after (text large + grid large).
#
# TWO boots with ONE snapshot each, deliberately (the flake #1757 carries
# as a fixup; OBSERVED 2026-09-26): when more than one kind-4 request is in flight the channel
# coalesces it — the guest's `snap_pending` is a bool and the host's
# `pendingSnapPath` is a single slot the next stream header steals — so a
# multi-snapshot run can lose its first frame and misfile the rest (run 03
# and the first M80i draft both did). A lone request on an idle guest serves
# promptly (observed: the surviving streams in those runs), which is the
# live-web-ttf.spec single-trigger pattern this pair uses. The boots are the
# identical chain and content, so the frame pair states the same relation a
# one-boot before/after would.
vgate_file font.txt <<'EOF'
font
font large
font
tty
echo font-zoom-done
EOF

# Run 04: the pre-zoom control frame at the boot cell. This boot never runs
# the gesture (asserted absent below), so the boot rung is the rung in force.
vgate_run 04 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --cvc-snap --snapshot-out '$RUN_DIR/snap-04' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'echo pppp'$'\n' \
    --input-string-after 'goterm: attached' \
    --snapshot-after 'goterm: line echo pppp' \
    --script-expect 'goterm: line echo pppp' \
    --script-expect-tail 5 \
    --timeout 150

vgate_assert 04 serial-contains 'goterm: ready'
vgate_assert 04 serial-contains 'goterm: line echo pppp'
vgate_assert 04 serial-absent 'font: set (text + grid)'
vgate_assert 04 serial-absent '  grid=large (10x21)'
vgate_assert 04 serial-absent '\[EXC\]'
vgate_assert 04 serial-absent '[EXC] parking:'

# The control frame: nothing in the client band below y=112 at the boot
# cell. Window client = x 64..704, y 64..448 (run 01's refused-declare
# rect); the 4 px inset keeps the sample off the window chrome (the M80k
# probe's rule). "Ink" is theme-agnostic — pixels far from the snapshot's
# own modal client background.
vgate_assert 04 python <<'PY'
import os, sys
RUN = os.environ["RUN_DIR"]
W = 1280
X, Y, CW, CH = 68, 68, 628, 372


def band_ink(name):
    d = open(os.path.join(RUN, name), "rb").read()
    if len(d) < W * 720 * 4:
        sys.exit("%s too small: %d bytes" % (name, len(d)))

    def px(x, y):
        k = (y * W + x) * 4
        return (d[k + 2], d[k + 1], d[k])

    hist = {}
    for y in range(Y, Y + CH, 2):
        for x in range(X, X + CW, 2):
            p = px(x, y)
            hist[p] = hist.get(p, 0) + 1
    bg = max(hist, key=hist.get)
    n = 0
    for y in range(112, 128):
        for x in range(X, X + CW):
            p = px(x, y)
            if max(abs(p[0] - bg[0]), abs(p[1] - bg[1]), abs(p[2] - bg[2])) > 40:
                n += 1
    return n


pre = band_ink("snap-04-0.raw")
print("M80i boot-cell band ink (y 112..127): %d" % pre)
assert pre == 0, (
    "the boot-cell 8x16 grid painted ink below y=112 (ink=%d) — three "
    "16-px rows end at y=111; the control frame is not the boot cell" % pre)
print("M80i control frame OK: empty band at the 8x16 cell")
PY

# Run 05: the gesture and the post-zoom frame — same chain, same content.
# script2 is the monitor `font` workflow: report the boot look (both
# ladders), move to `large`, report again, then a plain command after the
# zoom (the exec-order anchor, same as run 03: the run ends on a marker
# only script2 prints).
vgate_run 05 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --cvc-snap --snapshot-out '$RUN_DIR/snap-05' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'echo pppp'$'\n' \
    --input-string-after 'goterm: attached' \
    --snapshot-after 'font: set (text + grid)' \
    --script2 '$RUN_DIR/font.txt' \
    --script2-after 'goterm: line echo pppp' \
    --script-expect 'font-zoom-done' \
    --script-expect-tail 5 \
    --timeout 150

vgate_assert 05 serial-contains 'goterm: ready'
vgate_assert 05 serial-contains 'goterm: line echo pppp'
vgate_assert 05 serial-contains '  text=small (8x8)'
vgate_assert 05 serial-contains '  grid=medium (8x16)'
vgate_assert 05 serial-contains 'font: set (text + grid)'
vgate_assert 05 serial-contains '  text=large (24x24)'
vgate_assert 05 serial-contains '  grid=large (10x21)'
vgate_assert 05 serial-contains 'font-zoom-done'
vgate_assert 05 serial-absent '\[EXC\]'
vgate_assert 05 serial-absent '[EXC] parking:'

# The gesture chain in order: the boot look is REPORTED before the zoom
# (the one-key/two-ladders wart is visible in the report itself), the
# zoom lands, the large rung is reported, and a monitor command still
# runs after it (the guest is alive — same exec-order anchor as run 03).
vgate_assert 05 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_boot = ser.find("  grid=medium (8x16)")
i_set = ser.find("font: set (text + grid)")
i_large = ser.find("  grid=large (10x21)")
i_done = ser.find("font-zoom-done")
for name, i in (("boot report", i_boot), ("font large", i_set),
                ("large report", i_large), ("post command", i_done)):
    assert i >= 0, f"{name} marker missing from serial"
assert i_boot < i_set < i_large < i_done, (
    f"font chain out of order: boot={i_boot} set={i_set} "
    f"large={i_large} done={i_done}")
print("font zoom chain OK: boot report < font large < large report < guest alive after")
PY

# The pair, in one probe: run 04's control frame and run 05's post-zoom
# frame over the SAME band (y 112..127, the same 4 px inset and modal-bg
# ink rule as run 04). The relation IS the deliverable — the identical
# content's ink moved below y=111, which the 8x16 cell cannot do.
# Thresholds: pre is strict zero by geometry (3 x 16-px rows end at
# y=111); post > 60 is the measured scale of the prompt row's body and
# descender ink (the probe prints the measured values).
vgate_assert 05 python <<'PY'
import os, sys
RUN = os.environ["RUN_DIR"]
W = 1280
X, Y, CW, CH = 68, 68, 628, 372


def band_ink(name):
    d = open(os.path.join(RUN, name), "rb").read()
    if len(d) < W * 720 * 4:
        sys.exit("%s too small: %d bytes" % (name, len(d)))

    def px(x, y):
        k = (y * W + x) * 4
        return (d[k + 2], d[k + 1], d[k])

    hist = {}
    for y in range(Y, Y + CH, 2):
        for x in range(X, X + CW, 2):
            p = px(x, y)
            hist[p] = hist.get(p, 0) + 1
    bg = max(hist, key=hist.get)
    n = 0
    for y in range(112, 128):
        for x in range(X, X + CW):
            p = px(x, y)
            if max(abs(p[0] - bg[0]), abs(p[1] - bg[1]), abs(p[2] - bg[2])) > 40:
                n += 1
    return n


pre = band_ink("snap-04-0.raw")
post = band_ink("snap-05-0.raw")
print("M80i band ink: boot-cell=%d large-cell=%d" % (pre, post))
assert pre == 0, (
    "the boot-cell 8x16 control frame has ink below y=112 (ink=%d) — the "
    "pair's baseline is not the boot cell" % pre)
assert post > 60, (
    "no glyph ink below y=112 after `font large` (ink=%d) — the bound "
    "grid did not re-flow to the 10x21 cell" % post)
print("M80i scanout OK: the bound grid left 8x16 (ink moved below y=112)")
PY

# --- M125e (#2590): GOTERM session state ------------------------------------
# Runs 06/07 are SEATED boots of the save/restore half, mirroring the
# go-wm-tabs runs 12/13 choreography: the tag-02 assert unstaged the
# seat for the shim boots (03-05), so the tag-05 assert below re-stages
# GOTABWM.ELF into the share and run 06 execs it fresh. GOTERM declares,
# the user changes
# directory, sets a variable, and paints a proof line — then the snapshot
# chord asks every bound tab to serialize and the blob lands in
# SESSION.TABS's `AS` trailer. Run 07 is a fresh boot: the seat loads the
# file, re-execs GOTERM.ELF, and the app's restore lands the capped
# scrollback tail, the saved cwd and env, and the alt flag.
#
# The scrollback itself is a captured BYTE STREAM (the kernel owns the
# tty grid and exposes no readback), replayed read-only into the fresh
# tty — the marker carries the byte count and the last complete line
# (`tail=`), which is content proof on serial that the replayed stream
# is what run 06 painted. `test "$V" = alive-7` / `test "$PWD" = /STATE`
# are the engine's own status proof for env/cwd — the markerDone
# contract this file's header documents.
vgate_assert 05 python <<'PY'
import os, shutil, sys
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
dst = os.path.join(os.environ["VG_SHARE"], "GOTABWM.ELF")
shutil.copy(src, dst)
print("staged %s into share (%d bytes)" % (dst, os.path.getsize(src)))
PY

# The share carries the seat (tag-05 stage), so wm_autostart races this
# exec — go-wm-tabs runs 12/13 carry the same shape: whichever instance
# registers first is the live seat, the loser prints `seat-taken` once.
vgate_file script-06.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
vf mkdir STATE
exec GOTABWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
exec GOTERM.ELF
EOF

vgate_file script3-06.txt <<'EOF'
echo term-state-save-ok
EOF

# --input-string is a single runner slot (a repeat overwrites): the three
# session lines go in ONE string, newline-submitted in order, and the
# chord waits on the last line's marker.
vgate_run 06 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'gotabwm: registered' \
    --input-string 'cd STATE'$'\n''set GOTERM_STATE_X=alive-7'$'\n''echo SCROLL-PROOF-LINE'$'\n' \
    --input-string-after 'goterm: ready' \
    --input-chords 'ctrl-shift-s' \
    --input-chords-after 'goterm: line echo SCROLL-PROOF-LINE' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --script-expect 'term-state-save-ok' --timeout 300

vgate_assert 06 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 06 serial-contains 'gotabwm: registered'
vgate_assert 06 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 06 serial-contains 'goterm: declare accepted'
vgate_assert 06 serial-contains 'goterm: ready'
vgate_assert 06 serial-contains 'goterm: attached'
vgate_assert 06 serial-contains 'goterm: line cd STATE'
vgate_assert 06 serial-contains 'goterm: line set GOTERM_STATE_X=alive-7'
vgate_assert 06 serial-contains 'goterm: line echo SCROLL-PROOF-LINE'
# A fresh tab has no stored state — the restore request is the honest
# empty answer, never a fabricated blob.
vgate_assert 06 serial-absent 'goterm: state restored'
vgate_assert 06 serial-absent 'goterm: state refused'
# The snapshot chord asked the bound tab; GOTERM staged its blob at
# appver 2 (M154c #2927 bumped termStateVersion 1 -> 2 for the profile
# field) and the seat stored it into the session.
vgate_assert 06 serial-contains 'gotabwm: state ask id='
vgate_assert 06 serial-contains 'gotabwm: state save id='
vgate_assert 06 serial-contains 'ver=2'
vgate_assert 06 serial-contains 'gotabwm: snapshot saved '
vgate_assert 06 serial-absent 'gotabwm: state drop'
vgate_assert 06 serial-contains 'term-state-save-ok'
vgate_assert 06 serial-absent '\[EXC\]'
vgate_assert 06 serial-absent '[EXC] parking:'

# Byte-level on the share: the .tabs v2 `AS` trailer carries one entry —
# appver 2, and GOTERM's v2 blob framing (u8 fmt | u8 flags | u16 cwd |
# u16 envN | pairs | u32 scroll | u16 profLen | profile). The decoded
# fields must be exactly what the session produced: cwd /STATE, three env
# pairs, a stream tail holding the proof line, and an empty profile (run
# 06 never applies one).
vgate_assert 06 python <<'PY'
import os, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] != 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (b[0], b[2]))
off = 6 + 69
if len(b) < off + 6 + 8 or b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] != 1:
    sys.exit("app_state trailer %r" % b[off:off+6])
ent = b[off+6:off+14]
if ent[0] != 0 or ent[1] != 2:
    sys.exit("app_state entry index=%d appver=%d" % (ent[0], ent[1]))
ln = int.from_bytes(ent[4:8], "little")
blob = b[off+14:off+14+ln]
if len(blob) != ln:
    sys.exit("blob truncated: %d of %d" % (len(blob), ln))
if blob[0] != 2:
    sys.exit("goterm blob format=%d want 2" % blob[0])
cwdLen = int.from_bytes(blob[2:4], "little")
cwd = blob[4:4+cwdLen].decode()
if cwd != "/STATE":
    sys.exit("goterm blob cwd=%r want /STATE" % cwd)
envN = int.from_bytes(blob[4+cwdLen:6+cwdLen], "little")
p = 6 + cwdLen
pairs = []
for _ in range(envN):
    pl = int.from_bytes(blob[p:p+2], "little")
    p += 2
    pairs.append(blob[p:p+pl].decode())
    p += pl
want = ["PWD=/STATE", "OLDPWD=/", "GOTERM_STATE_X=alive-7"]
if pairs != want:
    sys.exit("goterm blob env=%r want %r" % (pairs, want))
scLen = int.from_bytes(blob[p:p+4], "little")
scroll = blob[p+4:p+4+scLen]
if b"SCROLL-PROOF-LINE" not in scroll:
    sys.exit("scrollback lost the proof line (%d bytes)" % len(scroll))
# v2's last field is the term-profile name — it must consume the blob
# tail exactly, and run 06 applies no profile so it decodes empty.
p += 4 + scLen
if len(blob) - p < 2:
    sys.exit("v2 blob truncated before profLen")
profLen = int.from_bytes(blob[p:p+2], "little")
profile = blob[p+2:p+2+profLen].decode()
if p + 2 + profLen != len(blob):
    sys.exit("v2 profile field leaves %d trailing bytes"
             % (len(blob) - p - 2 - profLen))
if profile != "":
    sys.exit("run 06 applied no profile, want empty, got %r" % profile)
print("SESSION.TABS GOTERM blob: cwd=%r env=%d scroll=%dB alt=%d "
      "profile=%r tail intact" % (cwd, envN, scLen, blob[1] & 1, profile))
PY

# Run 07 (M125e / #2590): the restore half — a FRESH boot loads the file
# run 06 left, re-execs GOTERM.ELF, and the app's restore_state request
# hands the blob back. The replayed stream tail, cwd, env, and alt flag
# are all asserted: the marker carries them, and two `test` lines make
# the ENGINE prove the env var and cwd are live ($? is a status only the
# real engine computes — the markerDone contract).
#
# The probes must be typed through the cv-input HID map, which has no
# `$` or `"` usage (observed run 07 r1: KEY-SEQ aborted on the literal
# `test "$X" = v` line and zero keystrokes landed). The engine check
# therefore lives in share scripts: `source /PENV.SH` / `source /PCWD.SH`
# are all-mappable, and each run's markerDone status IS the engine's own
# verdict on the restored env/cwd.
vgate_assert 06 python <<'PY'
import os
share = os.environ["VG_SHARE"]
for name, body in (
    ("PENV.SH", "test $GOTERM_STATE_X = alive-7\n"),
    ("PCWD.SH", "test $PWD = /STATE\n"),
):
    with open(os.path.join(share, name), "w") as f:
        f.write(body)
    print("wrote %s: %r" % (name, body))
PY

vgate_file script-07.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
exec GOTABWM.ELF
EOF

vgate_file script3-07.txt <<'EOF'
echo term-state-restore-ok
EOF

# Input waits on `goterm: prompt` — the strictest precondition: the
# editor loop is live AND finishReexec has long since committed the
# adopted window's focus (serial: `tab focus id=3` -> `session live` ->
# `state restore` -> `ready` -> `prompt`, over ~1.5 s). No `dui focus`:
# it takes kernel window ids, not tab indices — `dui focus 0` aims at the
# seat's own launcher, and the recorded focus arrives on its own anyway.
#
# script3 is held on the LAST probe's line marker, not the restore one:
# the cv-input ladder paces one stroke per 0.25 s of guest rx-pool
# consumption — gating the run's end on `state restored` let the expect
# match mid-typing and the VM stopped with the strokes undelivered
# (observed run 07 r3: two strokes enqueued, then SUCCESS). The line
# marker can only print once the whole string was consumed.
vgate_run 07 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script-07.txt' \
    --input-string 'source /PENV.SH'$'\n''source /PCWD.SH'$'\n' \
    --input-string-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3-07.txt' \
    --script3-after 'goterm: line source /PCWD.SH' \
    --script-expect 'term-state-restore-ok' --timeout 300

vgate_assert 07 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 07 serial-contains 'gotabwm: registered'
vgate_assert 07 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 07 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 07 serial-contains 'gotabwm: session exec GOTERM.ELF'
vgate_assert 07 serial-contains 'gotabwm: session live n=1'
# The seat's session reexec path names the bin but never crosses the
# loader's `exec: loaded` line — `session exec GOTERM.ELF` is the marker.
vgate_assert 07 serial-absent 'exec: loaded GOTERM.ELF'
# The seat staged the stored blob for the re-exec'd tab; GOTERM's own
# restore decoded it — the marker's fields ARE the serialized state.
vgate_assert 07 serial-contains 'gotabwm: state restore id='
vgate_assert 07 serial-contains 'goterm: state restored cwd=/STATE'
vgate_assert 07 serial-contains 'env=3'
vgate_assert 07 serial-contains 'alt=0'
vgate_assert 07 serial-contains 'tail=SCROLL-PROOF-LINE'
vgate_assert 07 serial-contains 'goterm: ready'
vgate_assert 07 serial-contains 'goterm: attached'
vgate_assert 07 serial-contains 'goterm: line source /PENV.SH'
vgate_assert 07 serial-contains 'goterm: line source /PCWD.SH'
vgate_assert 07 serial-count 'goterm: done status=0' 2
vgate_assert 07 serial-absent 'goterm: state refused'
vgate_assert 07 serial-absent 'gotabwm: state drop'
vgate_assert 07 serial-contains 'term-state-restore-ok'
vgate_assert 07 serial-absent '\[EXC\]'
vgate_assert 07 serial-absent '[EXC] parking:'

# Ordering: the restore marker lands BEFORE the first prompt, and both
# engine proofs run after it — a restored blob that never applied could
# not produce `done status=0` on either probe.
vgate_assert 07 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(
    r"goterm: state restored cwd=/STATE env=3 back=(\d+) alt=0 "
    r"tail=SCROLL-PROOF-LINE", ser)
assert m, "restored marker missing or fields drifted"
back = int(m.group(1))
assert back > 0, "replayed scrollback is empty"
i_rest = m.start()
i_ready = ser.find("goterm: ready")
i_env = ser.find("goterm: line source /PENV.SH")
i_done = ser.find("goterm: done status=0", i_env)
for name, i in (("restored", i_rest), ("ready", i_ready),
                ("probe line", i_env), ("probe done", i_done)):
    assert i >= 0, f"{name} marker missing from serial"
assert i_rest < i_ready < i_env < i_done, (
    f"restore chain out of order: restored={i_rest} ready={i_ready} "
    f"probe={i_env} done={i_done}")
print(f"restore chain OK: back={back}B replayed; restored < ready < env/cwd "
      f"proofs")
PY

# The tag-02 unstage precedent, again: the two legs behind run 07 (M121c's
# hints leg and M154a's run 08) are SHIM boots of the run-01 chain — the
# drag coords and the single-prompt choreography were written for the
# refused-declare 64,48 640x400 rect at the BOOT font pair (grid medium,
# 8x16). Runs 06/07 leave the seat AND its saved session on the share; an
# unrestored boot after them seats every later run, reexecs the stored
# tabs (doubled `goterm: ready`/`prompt`), and lands the run-08 drag on
# the wrong window rect. Run 05's `font large` is the other leak: it
# persists `font_size` into SETTINGS.TXT on the share, so every later
# boot's grid is 10x21 — 18 visible rows, the 22-row script output
# scrolls, and the run-08 drag captures a shifted window of it (observed:
# `tty: copy 368 bytes` seated and `399 bytes` shim for the 499 B region).
vgate_assert 07 python <<'PY'
import os, shutil
share = os.environ["VG_SHARE"]
for name in ("GOTABWM.ELF", "SESSION.TABS", "PENV.SH", "PCWD.SH",
             "HINTS-Q.OUT", "PL.TXT"):
    p = os.path.join(share, name)
    if os.path.exists(p):
        os.unlink(p)
        print("unstaged %s from share (runs 09/08 boot shim-only)" % p)
d = os.path.join(share, "STATE")
if os.path.isdir(d):
    shutil.rmtree(d)
    print("unstaged STATE/ from share")
# font_size is a share-persisted setting: drop the row so the legs boot
# at the compiled default pair (text small + grid medium). Keep every
# other key; a file left with only its #v header is removed entirely.
sp = os.path.join(share, "SETTINGS.TXT")
if os.path.exists(sp):
    lines = open(sp).read().splitlines()
    hdr = next((l for l in lines if l.startswith("#")), "#v2")
    kept = [l for l in lines if l and not l.startswith("#")
            and not l.startswith("font_size")]
    if kept:
        with open(sp, "w") as f:
            f.write(hdr + "\n" + "\n".join(kept) + "\n")
        print("stripped font_size from SETTINGS.TXT (kept %d rows)" % len(kept))
    else:
        os.unlink(sp)
        print("removed SETTINGS.TXT (font_size was the only row)")
print("share now: %s" % sorted(os.listdir(share)))
PY

# --- M121c (#2566) run 09: the '?' chord-hint overlay + child pass-through --
# GOTERM is a tty front-end: '?' at the prompt paints the registry's rows
# on the alternate screen (app + seat + kernel-terminal chrome — this
# window answers all three scopes) and a lone Esc pops it. The pass-through
# half the card names: while `read` blocks inside RunLine the main loop is
# not reading the tty, so a '?' keystroke is stdin, not the overlay chord —
# proven by the byte landing in HINTS-Q.OUT on the share and by `hints`
# being absent until after the echo submits.
#
# The runner's input slots are one apiece (a repeat overwrites — the run-06
# comment), so the whole guest-side conversation rides ONE chord batch on
# ONE anchor plus ONE input-string: `read Q` opens the leg, `?` + Return
# answer the blocked `read`, `source /HINTSE.SH` types the write of $Q
# into the share (`$` and `>` are outside the cv-input HID map — the same
# reason run 07 probes via PENV.SH/PCWD.SH).
#
# The overlay-open '?' is NOT in the batch at all: a batch-internal '?' is
# hopeless against the n==1 check because poll_input drains the whole
# used ring per pass — a neighbour report 0.25 s away co-delivers and a
# bundled '?' is literal text (observed: `line ?` 127 from a batch-end '?'
# at an idle prompt, PROVEN by the return probe). Instead --input-string
# fires a guaranteed-lone '?' on `goterm: done status=1` — the unique
# marker HINTSE.SH's trailing `false` produces AFTER the editor has
# resumed its own read. The batch ENDS on '?' too: whichever '?' lands
# first at a live FileRead opens; the second one closes it (the overlay's
# own read loop pops '?' out of ANY-sized read, so the batch-side '?'
# stays useful even bundled).
#
# The backspaces are dead time, not input, three times over: between the
# `read Q` submit and the stdin '?' (a '?' that lands in the editor's
# post-submit window, BEFORE the builtin arms its stdin read, gets queued
# as the NEXT line — observed: `line ?` 127 while `read` went on to eat
# the source line as ITS stdin); before `source` (`read` consumes
# TypeAhead in one drain and DROPS whatever trails the newline —
# observed: 's','o' lost -> `urce` 127); and before the trailing '?' (a
# child-time keystroke rides the M98f stash and is Fed back as literal
# text, never the chord).
vgate_file script-hints.txt <<'EOFX'
exec GOTERM.ELF
EOFX

vgate_file hints-done.txt <<'EOFX'
echo rx-term-hints-ok
EOFX

vgate_run 09 -- --display --input --via-virtio --screen '$RUN_DIR/screen-09' \
    --script '$RUN_DIR/script-hints.txt' \
    --input-chords 'r,e,a,d,space,Q,return,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,?,return,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,s,o,u,r,c,e,space,/,H,I,N,T,S,E,.,S,H,return,ctrl-shift-c,ctrl-shift-c,ctrl-shift-c,ctrl-shift-c,ctrl-shift-c,ctrl-shift-c,ctrl-shift-c,ctrl-shift-c,escape' \
    --input-chords-after 'goterm: prompt' \
    --input-string '?' --input-string-after 'goterm: done status=1' \
    --script2 '$RUN_DIR/hints-done.txt' \
    --script2-after 'goterm: hints close' \
    --script-expect 'rx-term-hints-ok' \
    --timeout 240

vgate_assert 09 serial-contains 'goterm: ready'
vgate_assert 09 serial-contains 'goterm: line read Q'
# n= is the registry's own count for GOTERM's scope (app + seat +
# kernel-terminal): 36 at M121c, 48 after the M121b/M121e/M132/M137
# additions, 52 with the M190a clip-menu, M190b shot pair and M190e
# lock seat rows — re-pinned, not relaxed (the value is what the
# registry reports today; a drift in the overlay's row list fails here).
vgate_assert 09 serial-contains 'goterm: hints n=52'
vgate_assert 09 serial-contains 'goterm: hints row ctrl+shift+c copy the terminal selection'
vgate_assert 09 serial-contains 'goterm: hints row ctrl+shift+p summon the command palette'
vgate_assert 09 serial-contains 'goterm: hints close'
vgate_assert 09 serial-contains 'rx-term-hints-ok'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 share-contains 'HINTS-Q.OUT' '?'

# The pass-through pin: `read` was blocking on stdin when the first '?' was
# injected, so that byte had to go to the shell's stdin — the hints n= line
# may only appear after the HINTSE line, never inside the read window.
# (The anchor is the typed `source` line: the literal `echo $Q >` it runs
# cannot be typed — `$`/`>` are outside the HID map.)
vgate_assert 09 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_read = ser.find("goterm: line read Q")
i_echo = ser.find("goterm: line source /HINTSE.SH")
i_hints = ser.find("goterm: hints n=")
i_close = ser.find("goterm: hints close")
for name, i in (("read line", i_read), ("source line", i_echo),
                ("hints open", i_hints), ("hints close", i_close)):
    assert i >= 0, f"{name} marker missing"
assert i_read < i_echo < i_hints < i_close, (
    f"pass-through broken: read={i_read} source={i_echo} "
    f"hints={i_hints} close={i_close} — '?' reached the overlay while a "
    f"child owned the tty")
print("'?' pass-through OK: stdin byte to `read`, overlay only at the prompt")
PY

# --- M154a (#2926) run 08: bracketed paste ON by default ---------------------
# The card's class-B proof, with NO opt-out anywhere. `cat SCRIPT2.SH`
# paints 20 RUNNABLE lines (each appends a row to PL.TXT on the share),
# the drag copies all 20 rows (~499 B — under the 512 B clipboard, over
# the old 256 B input queue), and Ctrl+Shift+V lands them BRACKETED
# because the editor now writes ?2004h with every line-read prompt. Two
# assertions follow from that: nothing submits between the paste push and
# the Enter chord — no `goterm: line` may appear there — and the Enter
# produces ONE submit whose script ran all 20 lines, read back by the
# monitor's `cat PL.TXT` (the append path makes the print serial-visible,
# where tty output is not).
vgate_file paste-done.txt <<'EOFX'
cat PL.TXT
echo rx-bracketed-paste-ok
EOFX

vgate_run 08 -- --display --input --via-virtio --screen '$RUN_DIR/screen-08' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'cat SCRIPT2.SH'$'\n' \
    --input-string-after 'goterm: attached' \
    --pointer-virtio "68,84;68,84,d;696,392;696,392,u" \
    --pointer-virtio-after 'goterm: done status=0' \
    --input-chords "ctrl-shift-c,ctrl-shift-v,return" \
    --input-chords-after 'dui: term sel end' \
    --script2 '$RUN_DIR/paste-done.txt' \
    --script2-after 'goterm: line echo L00' --script2-delay 2 \
    --script-expect 'rx-bracketed-paste-ok' \
    --timeout 150

vgate_assert 08 serial-contains 'goterm: ready'
vgate_assert 08 serial-contains 'goterm: attached'
vgate_assert 08 serial-contains 'goterm: line cat SCRIPT2.SH'
vgate_assert 08 serial-contains 'tty: copy '
vgate_assert 08 serial-contains 'tty: paste '
vgate_assert 08 serial-contains 'goterm: line echo L00'
vgate_assert 08 serial-contains 'goterm: done status=0'
vgate_assert 08 serial-contains 'rx-bracketed-paste-ok'
vgate_assert 08 serial-absent '\[EXC\]'
vgate_assert 08 serial-absent '[EXC] parking:'

# The pin: copy = exactly the 20 script rows (499 B), the paste push = the
# DECSET-wrapped count (499 + 12), ZERO submits between the push and the
# Enter (one `goterm: line` in the whole window, holding all 20 lines in
# its one marker), and the monitor's cat proves every line ran.
vgate_assert 08 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
mc = re.search(r"tty: copy (\d+) bytes", ser)
assert mc, "copy marker missing"
assert int(mc.group(1)) == 499, f"copy must be the 20 script rows (got {mc.group(1)})"
mp = re.search(r"tty: paste (\d+) bytes", ser)
assert mp, "paste marker missing"
assert int(mp.group(1)) == 499 + 12, (
    f"paste must carry the DECSET wrap: 499+12 (got {mp.group(1)})")
i_paste = ser.find(mp.group(0))
i_line = ser.find("goterm: line ", i_paste)
i_done = ser.find("goterm: done status=0", i_line)
assert i_line > 0 and i_done > i_line, "no submit after the paste"
n_sub = ser.count("goterm: line ", i_paste, i_done)
assert n_sub == 1, f"no submit may appear until Enter; Enter yields ONE (got {n_sub})"
seg = ser[i_line:i_done]
for i in range(20):
    assert ("echo L%02d" % i) in seg, f"echo L{i:02d} missing from the one submit"
rows = re.findall(r"(?m)^L\d\d$", ser[i_done:])
assert len(rows) == 20, f"PL.TXT holds {len(rows)} rows, want 20 — the script must run all lines"
print(f"bracketed run OK: copy=499B paste=511B, one submit, PL.TXT has all 20 rows")
PY
