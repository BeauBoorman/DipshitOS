# live-search.spec -- milestone-eighteen card T3 class-B gate (issue #406):
#
# reverse-i-search (Ctrl+R) on real VZ.
#
# Mechanism: boots the production image with scripted input: phase 1 submits
# distinctive commands to history. Phase 2 sends ONLY the Ctrl+R entry over
# serial (a modifier chord — VZ's synthesized keyboard cannot deliver it,
# activation wall, hardware contract). Phase 3 types the QUERY and the
# Enter-accept through the synthesized keyboard (--input-chords, claims

vgate_name live-search "milestone-eighteen card T3 class-B gate (issue #406):"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
echo build-up-1
echo build-up-2
echo special-search-target-777
echo build-up-4
echo build-up-5
echo fill-ready
EOF

# The Ctrl+R entry (0x12) cannot be delivered by the synthesized keyboard
# (modifier wall) — the legacy gate wrote the single byte to
# artifacts/live-search-keys.txt at runtime. The spec writes the same
# ONE-byte file (no trailing newline — an Enter here would accept an
# empty query and break the search) via the setup hook: vgate_file
# re-appends a newline by contract.
vgate_setup_python <<'PY'
import os
with open(os.path.join(os.environ["RUN_DIR"], "keys.txt"), "wb") as f:
    f.write(b"\x12")
PY

vgate_run 01 -- --input --display --script '$RUN_DIR/script.txt' --input-chords "s,p,e,c,i,a,l,return,e,c,h,o,space,s,e,a,r,c,h,-,l,i,v,e,-,o,k,return" --input-chords-after "(reverse-i-search)`_`" --input-chords-delay 2.0 --script2 '$RUN_DIR/keys.txt' --script2-after "fill-ready" --script-expect "search-live-ok" --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'fill-ready'
vgate_assert 01 serial-contains '(reverse-i-search)`'
vgate_assert 01 serial-contains '(reverse-i-search)`special`: echo special-search-target-777'
vgate_assert 01 serial-contains 'search-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
