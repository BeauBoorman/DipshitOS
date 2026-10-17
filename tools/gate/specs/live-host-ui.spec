# live-host-ui.spec -- M114a (#2454, index #2447): the HostCommand action
# bus's headless mirror. `--host-cmd-after <marker>:<verb>` dispatches a
# menu verb through the same bus the AppKit menu items dispatch on, once
# the marker appears in the serial stream — the window is never driven
# by synthesized clicks (index thesis 1); the bus is the testable seam.
# Every dispatch writes one `host-ui: cmd=<verb> state=<...>` receipt on
# runner stdout.
#
# Run 01 fires `screenshot` — a verb wired TODAY (the same --screen
# framebuffer capture --screenshot-after uses) — plus `fullscreen` and
# `send-file`, verbs declared on the bus whose handlers land in M114b/c:
# performed, unavailable and unavailable receipts on one boot, and the
# PNG the action itself wrote is held to a PNG signature.
#
# Run 02 fires `stop`: the performed receipt and the run's own early end
# (rc 1 — the VM really stopped before the transcript appeared) prove
# the verb acted, not just reported.

vgate_name live-host-ui "M114a #2454: HostCommand bus --host-cmd-after mirror, host-ui: receipts"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
echo host-ui-idle
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:screenshot' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:fullscreen' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:send-file' \
    --script-expect 'host-ui-idle' --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 output-contains 'host-ui: cmd=screenshot state=performed'
vgate_assert 01 output-contains 'host-ui: cmd=fullscreen state=unavailable'
vgate_assert 01 output-contains 'host-ui: cmd=send-file state=unavailable'
vgate_assert 01 output-contains 'framebuffer screenshot saved'
vgate_assert 01 snapshot 'screen-hostui-*' <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    magic = f.read(8)
if magic != b"\x89PNG\r\n\x1a\n":
    sys.exit("newest host-ui screenshot is not a PNG: %r" % magic)
print("host-ui screenshot is a PNG: %s" % sys.argv[1])
PY

vgate_run 02 -- --script '$RUN_DIR/script.txt' \
    --host-cmd-after 'VirelaiOS kernel has seized control.:stop' \
    --script-expect 'host-ui-idle' --timeout 90
vgate_allow_rc 02 1

vgate_assert 02 output-contains 'host-ui: cmd=stop state=performed'
vgate_assert 02 output-contains 'VM ended before the expected transcript'
