# live-sb6-perf-payoff.spec -- M33 SB6 (claim 6864) class-B gate:
#
# measure seam B against the WMS9 baselines, live on real VZ hardware.
# M52 card 3 (#1240) adds run 02: SB6NEW.BIN is the ONE live client that
# holds a surface-backed window across a deterministic window (8 committed
# frames, each `sys_sleep(1)` = a full 1 s tick), so a `kill` armed on its
# `sb6: new bound` marker lands mid-commit — the surface bound, the WM's RO
# mirror auto-granted, frames in flight — and must leave no zombie window.
# (SB2OWN/SB3OWN hand off and exit within milliseconds of their acks, so
# they cannot be interrupted deterministically; this app can.)
#
# ONE headless boot, THREE scripted programs, TWO snapshots:
#   Phase 1 (the "before" control):  SB6OLD.BIN opens a 256x192 user window
#     and renders an 8x8 grid (static + 8 dynamic redraws) through the
#     FROZEN per-rect path — 576 `sys_win_fill` (slot 13) SVCs + 9
#     `sys_win_present` (slot 14) SVCs, each present kernel-blitted.

vgate_name live-sb6-perf-payoff "M33 SB6: seam-B perf-payoff on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec SB6WM.BIN
exec SB6OLD.BIN
exec SB6NEW.BIN
EOF

vgate_file script2.txt <<'EOF'
dui
syscalls
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'timer heartbeat ticks=45' --script-expect '13 sys_win_fill calls=576' --timeout 180

vgate_assert 01 serial-contains 'sb6: wm registered'
vgate_assert 01 serial-contains 'sb6: wm scanout=1'
vgate_assert 01 serial-contains 'sb6: old fills=576'
vgate_assert 01 serial-contains 'sb6: old done'
vgate_assert 01 serial-contains 'sb6: new ready'
vgate_assert 01 serial-contains 'sb6: new bound'
vgate_assert 01 serial-contains 'sb6: new fills=0 stores=ok'
vgate_assert 01 serial-contains 'sb6: new done'
vgate_assert 01 serial-contains 'sb6: wm bytes=196608'
vgate_assert 01 serial-contains 'sb6: wm readback=0x6B'
vgate_assert 01 serial-contains 'sb6: wm present'
vgate_assert 01 serial-contains 'sb6: wm done'
vgate_assert 01 serial-contains '13 sys_win_fill calls=576'
vgate_assert 01 serial-contains 'dui: windows='
vgate_assert 01 serial-absent 'sb6: wm register-fail'
vgate_assert 01 serial-absent 'sb6: wm scanout-fail'
vgate_assert 01 serial-absent 'sb6: wm attach-fail'
vgate_assert 01 serial-absent 'sb6: wm compose-fail'
vgate_assert 01 serial-absent 'sb6: old open-fail'
vgate_assert 01 serial-absent 'sb6: new open-fail'
vgate_assert 01 serial-absent 'sb6: new bind-fail'
vgate_assert 01 serial-absent 'sb6: new no-wm'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys, re
ser = open(os.environ["VG_SER"]).read()
for line in ser.splitlines():
    if "dui: windows=" in line:
        m_b = re.search(r'blits=([0-9]+)', line)
        m_s = re.search(r'skips=([0-9]+)', line)
        if m_b and m_s and int(m_b.group(1)) >= 9 and int(m_s.group(1)) >= 9:
            sys.exit(0)
sys.exit(1)
PY

# --- M52 card 3 (#1240): the mid-commit kill leaves no zombie window ---
# The client is killed while its committed frames are in flight and its
# shared surface is bound + mirrored. The kill conversion runs the SAME
# teardown as sys_exit (close_owner first, then the surface revoke), so the
# window leaves the registry and the WM's mirror dies with the region.

vgate_file script-c.txt <<'EOF'
exec SB6WM.BIN
exec SB6NEW.BIN
EOF

vgate_file s2-c.txt <<'EOF'
kill SB6NEW.BIN
echo sb6-kill-armed
EOF

vgate_file s3-c.txt <<'EOF'
dui
echo sb6-zombie-probe-done
EOF

vgate_run 02 -- --screen '$RUN_DIR/screen-c' \
    --script '$RUN_DIR/script-c.txt' \
    --script2 '$RUN_DIR/s2-c.txt' --script2-after 'sb6: new bound' --script2-delay 0 \
    --script3 '$RUN_DIR/s3-c.txt' --script3-after 'tasks user-exec reaped' --script3-delay 3 \
    --script-expect 'sb6-zombie-probe-done' --timeout 300

vgate_assert 02 serial-contains 'sb6: new bound'
vgate_assert 02 serial-contains 'kill: SB6NEW.BIN armed'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'sb6: new open-fail'
vgate_assert 02 serial-absent 'sb6: new bind-fail'
# The client never reached its own end: it was killed WITH the surface
# bound and died before `sb6: new done` — that marker's absence is the
# no-clean-exit evidence. `fills=0 stores=ok` is one redraw-pass marker,
# not exit: the armed kill is asynchronous and may land after the first
# pass under load (observed on the reference host).
vgate_assert 02 serial-absent 'sb6: new done'
vgate_assert 02 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
# Ordering + non-vacuity: the surface was BOUND and the mirror live before
# the kill was armed (cmd_kill refuses an already-exited process, so an armed
# kill proves the client was alive), and the probe ran after the reap.
i_bound = ser.index("sb6: new bound")
i_kill = ser.index("kill: SB6NEW.BIN armed")
i_reap = ser.index("tasks user-exec reaped")
i_probe = ser.index("dui: windows=", i_reap)
i_done = ser.index("sb6-zombie-probe-done")
assert i_bound < i_kill < i_reap < i_probe < i_done, "probe ordering"
# The probe's registry block: `dui: windows=N` then one `dui[i]: <title>
# <kind> rect=...` row per window. The killed client's window must be GONE —
# a zombie row would still composite from the region the revoke freed.
block = ser[i_probe:i_done].splitlines()
rows = [l for l in block if re.match(r'dui\[[0-9]+\]: ', l)]
m = re.search(r'dui: windows=([0-9]+)', block[0])
assert m, "no windows= count"
assert int(m.group(1)) == len(rows) and rows, "windows= disagrees with the rows"
zombies = [l for l in rows if " user user " in l]
assert not zombies, f"zombie window after the mid-commit kill: {zombies}"
PY
