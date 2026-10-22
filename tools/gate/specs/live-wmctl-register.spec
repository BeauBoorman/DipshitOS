# live-wmctl-register.spec -- M32 WMS2: kernel render-server register on VZ

vgate_name live-wmctl-register "M32 WMS2: kernel render-server register on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
wm
exec WNDSTUB.BIN
EOF

vgate_file script2.txt <<'EOF'
wm
syscalls
echo rx-wmctl-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'tasks user-exec reaped' --script-expect 'rx-wmctl-ok' --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-count 'wm: none (shim compositing)' 2
vgate_assert 01 serial-contains 'wndstub: registered'
vgate_assert 01 serial-contains 'wndstub: tick'
vgate_assert 01 serial-contains 'wndstub: present ok'
vgate_assert 01 serial-contains 'tasks user-exec reaped'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains '65 sys_wmctl calls=2'
# Census observed on VZ: `syscalls: slots=64 implemented=96` (kernel
# implemented_count; host tests pin the same line). The M32-era pin was 68.
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=96'
vgate_assert 01 serial-contains 'rx-wmctl-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
