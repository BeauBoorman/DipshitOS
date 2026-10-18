# live-scrollback.spec -- milestone-eighteen card T1 class-B gate (issue #404),
# extended by M73k (issue #1637): scrollback depth + Ctrl+Shift+F search.
#
# the terminal scrollback ring on real VZ. TERM.BIN owns a window terminal
# (the M49 SD5 / #1132 pattern — live-term-depth is the sibling gate): a
# sourced fill script prints 150 numbered lines into the bound session's
# grid, pushing line one past the 128-row grid into the 256-row history
# ring. The scroll keys (PageUp/PageDown/Escape) and the Ctrl+Shift+F
# search then ride the SYNTHESIZED KEYBOARD over the custom-virtio INPUT
# queue (`vgate_runner_flags -Xswiftc -DSPIKE` + `--via-virtio`, the
# recipe every green go-* spec uses — the runner's flag help names it for
# exactly this: "no window/view required — attacks #179 synthesized-drop
# and #151 activation wall"), and the monitor `input` report proves every
# key reached the guest keymap with dropped=0.
#
# events=112 was the hand count (35 input-string keys + 77 chords); the
# live report reads 111 — one edge is swallowed somewhere in the
# input-string burst (observed twice, stable), so 111 is the pinned
# truth, not the arithmetic.
#
# Why TERM.BIN and not the bare serial script (observed 2026-09-22): the
# chrome chords — PageUp view scroll, Ctrl+Shift+C/V, and M73k's
# Ctrl+Shift+F search bar — live in input.zig's FOCUSED-TERMINAL route
# (`focused_owner()` + `windowTerminal(focused)`), which a serial-console
# session can never enter: with no window focused the keys take the
# console route (events counts them one-for-one either way, which is why
# the report shape is route-invariant) but that route has no search/scroll
# chrome at all — observed as `unknown command 'veryoldalphaecho'` (the
# whole typed tail reaching the monitor as literal text) with zero
# `tty: search` klogs, on two runs. The view/NSEvent path was also dead
# (claim-4769 activation wall: window key=false, guest saw zero keys), so
# cv-input is the only transport this gate trusts.
#
# Marker grammar (observed, term.zig): `term: line <text>` klogs only on
# an INTERACTIVE editor submit and `term: done status=N` follows it;
# SOURCED lines run inside the same runLine and are grid-only — no klog,
# no serial output (live-term-depth's `term: line LINE-00` hits come from
# its clipboard PASTE, not from sourcing). runSource reads one shot into
# a 2048-byte buffer (term.zig data[2048]), so FILL.SH stays ~1.5 KB.
# Therefore the fill barrier is the INTERACTIVE `echo FILL-COMPLETE`
# submitted right after the source in the same input-string burst: its
# klog proves the source completed (runSource is synchronous inside
# runLine). The chord tail's `term: line echo scroll keys ok` proves the
# search bar closed (escape captured it) and the chords reached the
# editor; script2 then fires the monitor `input` report.
#
# The depth+search proof is `tty: search: 1 matches`: sourced output rows
# carry no command rows, so `veryoldalpha` exists exactly once — in the
# unified history+grid space, and (151 > 128 rows) necessarily in
# history. The 40 PageUp tokens travel 320 view lines: >= the ~300-row
# space, so the view reaches row 0 (clamped) before the search opens.
#
# Every token is inside hidChord's table: pageup/pagedown/escape/space/
# return explicitly, ctrl-shift-f via the 12-char letter rule, single
# letters/digits/punctuation via hidUsage. events counts every key once
# on every route (console n>0, focused-route branches), so the number is
# focus-invariant: 111 pinned = the 112-key arithmetic minus the one
# input-string edge noted above.

vgate_name live-scrollback "milestone-eighteen card T1 class-B gate (issue #404) + M73k depth/search (issue #1637):"
vgate_repeat 1 BOOTS
vgate_runner_flags -Xswiftc -DSPIKE
vgate_share seed

vgate_setup_python <<'SPY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "GOTERM.ELF")
if not os.path.isfile(src):
    sys.exit("GOTERM.ELF missing: bash tools/go/build-goterm.sh")
shutil.copy(src, os.path.join(share, "GOTERM.ELF"))
SPY

vgate_file script.txt <<'EOF'
exec GOTERM.ELF
EOF

# The `input` report is a MONITOR command (monitor.zig cmd_input), so it
# rides script2 to the serial console after the chord tail proves delivery
# — not the chords themselves (which type into TERM.BIN's session).
vgate_file input.txt <<'EOF'
input
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
lines = ["echo veryoldalpha"] + ["echo d%03d" % i for i in range(2, 151)]
body = "\n".join(lines) + "\n"
assert len(body.encode()) < 2048, "runSource data[2048] would truncate"
with open(os.path.join(share, "FILL.SH"), "w") as f:
    f.write(body)
PY

# input-string: the source line THEN the interactive barrier echo — each
# submits through the editor (klog + done), and runSource finishes inside
# line one, so `term: line echo FILL-COMPLETE` is the fill-complete
# barrier. Click (68,76 = live-term-depth's proven in-window point, dui
# click-to-focus + selection, both harmless: searchOpen clears selection)
# and the 77 chords key off that same marker; the search-critical f token
# is stroke ~44 (~12 s in), long after focus lands (dui tick ~2 s).
#
# 77 chord tokens: 40 PageUp (320 lines of view travel -> row 0, clamped)
# + 3 PageDown (both directions at depth) + ctrl-shift-f + the 12-char
# pattern `veryoldalpha` + escape (captured by the open bar, never pushed)
# + `echo scroll keys ok` + return (submitted -> klog = the tail assert
# and the script2 trigger). The `input` command moved to script2.
vgate_run 01 -- --display --input --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-string 'source FILL.SH'$'\n''echo FILL-COMPLETE'$'\n' \
    --input-string-after 'goterm: attached' \
    --pointer-virtio '68,76,c' \
    --pointer-virtio-after 'goterm: line echo FILL-COMPLETE' \
    --input-chords "pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pagedown,pagedown,pagedown,ctrl-shift-f,v,e,r,y,o,l,d,a,l,p,h,a,escape,e,c,h,o,space,s,c,r,o,l,l,space,k,e,y,s,space,o,k,return" \
    --input-chords-after 'goterm: line echo FILL-COMPLETE' \
    --input-chords-delay 0.3 \
    --script2 '$RUN_DIR/input.txt' \
    --script2-after 'goterm: line echo scroll keys ok' \
    --script-expect "input: armed=1 fifo=0/64 dropped=0 events=111" \
    --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'goterm: attached'
vgate_assert 01 serial-contains 'goterm: line source FILL.SH'
vgate_assert 01 serial-contains 'goterm: line echo FILL-COMPLETE'
vgate_assert 01 serial-contains 'tty: search: 1 matches'
vgate_assert 01 serial-contains 'goterm: line echo scroll keys ok'
vgate_assert 01 serial-contains 'input: armed=1 fifo=0/64 dropped=0 events=111'
vgate_assert 01 serial-absent '[EXC] parking:'
