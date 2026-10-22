# live-win-close.spec -- EL0 window release on real VZ hardware (milestone six card G6)

vgate_name live-win-close "EL0 window release + slot reuse on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec WINCLOSE.BIN
EOF

vgate_file script2.txt <<'EOF'
dui
syscalls
exec WINCLOSE.BIN
EOF

vgate_run 01 -- --display --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'procs WINCLOSE.BIN exited status=88' --script-expect 'timer heartbeat ticks=20 irq=20 poll=0' --timeout 60

vgate_assert 01 serial-count 'win: open id=2' 2
vgate_assert 01 serial-absent 'win: open id=3'
vgate_assert 01 serial-count 'win: close ok' 2
vgate_assert 01 serial-count 'procs WINCLOSE.BIN exited status=88' 2
vgate_assert 01 serial-count 'dui: windows=4' 1
vgate_assert 01 serial-absent 'user user'
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=96'
vgate_assert 01 serial-contains '  12 sys_win_open calls=1'
vgate_assert 01 serial-contains '  15 sys_win_close calls=1'
