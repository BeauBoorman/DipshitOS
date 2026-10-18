# live-net-dhcp-autonomous.spec -- the lease lifecycle advances from
# the shell idle loop with NOBODY typing `net dhcp` after phase 1:
# phase 2 is a marker + report only, yet the T1 renew (refused) and
# T2 rebind (ACKed) still fire. Same wire shape as the N9 renew gate.
# Mirrors tools/verify-live-net-dhcp-autonomous.sh (issue #119).

vgate_name live-net-dhcp-autonomous "idle-loop DHCP renewal with no typed commands on VZ"
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file p1.txt <<'EOF'
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net arp 10.0.0.2
echo dhcp-auto-phase1-ready
EOF

vgate_file p2.txt <<'EOF'
echo dhcp-auto-p2
net
echo dhcp-auto-done
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-dhcp-respond 10.0.0.2:100 --net-arp-respond 10.0.0.2 --net-dhcp-respond-norenew --script '$RUN_DIR/p1.txt' --script2 '$RUN_DIR/p2.txt' --script2-after 'dhcp-auto-phase1-ready' --script2-delay 92 --script-expect 'dhcp-auto-done' --timeout 220

vgate_assert 01 serial-contains 'net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=100'
vgate_assert 01 serial-contains 'renew=1,rebind=1,renewed=1,expired=0'
vgate_assert 01 serial-contains 'dhcp-auto-done'
vgate_assert 01 output-contains 'net-dhcp-respond: ENABLED (milestone five card N8, claim 0351) + card N9 (claim 9489)'
vgate_assert 01 output-contains 'net-arp-respond: ENABLED'
vgate_assert 01 output-contains 'net-dhcp-respond-norenew: ENABLED'
vgate_assert 01 output-contains "NET-DHCP: refused the guest's unicast RENEWING REQUEST"
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# THE autonomous transitions -- typed by NOBODY (phase 2 has no net
# dhcp): the T1 unicast RENEW and the T2 broadcast REBIND.
if not re.search(r"net dhcp: renewing \(T1, elapsed=[0-9]+\) request sent to the server \(298 bytes\)", ser):
    sys.exit("FAIL: no autonomous T1 renewing line")
if not re.search(r"net dhcp: rebinding \(T2, elapsed=[0-9]+\) request sent \(298 bytes\)", ser):
    sys.exit("FAIL: no autonomous T2 rebinding line")
# The capture: 1222 B with the unicast RENEW + broadcast REBIND at
# the N9-pinned offsets.
cap = open(os.environ["RUN_DIR"] + "/cap.bin", "rb").read()
# M117b (#2474): boot-time NDP/ICMPv6 frames ride the same capture —
# noise to this v4 contract; drop them by the v6 length decode so the
# pinned sizes/offsets below stay byte-exact.
_v4 = bytearray()
_i = 0
while _i < len(cap):
    _et = cap[_i+12:_i+14]
    if _et == b"\x86\xdd":
        _i += 14 + 40 + ((cap[_i+18] << 8) | cap[_i+19])
    elif _et == b"\x08\x06":
        _v4 += cap[_i:_i+42]
        _i += 42
    else:
        _fl = 14 + ((cap[_i+16] << 8) | cap[_i+17])
        _v4 += cap[_i:_i+_fl]
        _i += _fl
cap = bytes(_v4)

if len(cap) != 1222:
    sys.exit("FAIL: capture size %d, want 1222" % len(cap))
h = cap.hex()
want = {1252: "020000000002", 1312: "0a000002", 1360: "0a000002", 1848: "ffffffffffff"}
bad = [(o, w) for o, w in want.items() if h[o:o + len(w)] != w]
if bad:
    sys.exit("FAIL: capture offsets off: %s" % bad)
print("dhcp-autonomous rungs + capture ok")
PY
