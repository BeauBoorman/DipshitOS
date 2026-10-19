# live-net-dhcp-renew.spec -- the RFC 2131 S4.4.5 lease lifecycle:
# Run A renews at T1 (unicast, refused) then rebinds at T2
# (broadcast, ACKed); Run B lets the lease expire (address released)
# and recovers with a fresh DISCOVER. Captures pin the unicast vs
# broadcast frames.
# Mirrors tools/verify-live-net-dhcp-renew.sh (claim 9489, card N9).

vgate_name live-net-dhcp-renew "DHCP lease lifecycle: renew/rebind/expiry/recovery on VZ"
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file a1.txt <<'EOF'
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
echo n9a-phase1-ready
EOF

vgate_file a2.txt <<'EOF'
echo n9a-phase2-ready
net
echo n9a-done
EOF

vgate_file b1.txt <<'EOF'
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
echo n9b-phase1-ready
EOF

vgate_file b2.txt <<'EOF'
net
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net
echo n9b-done
EOF

# warm-cold: A,B (d) --script2-delay arms the lease lifecycle's T1/T2/expiry
#   windows against host wall-clock — a timing budget formed across the
#   freeze is uninterpretable post-restore (ADR 0059 D7(d))
vgate_run A -- --net '$RUN_DIR/a-cap.bin' --net-dhcp-respond 10.0.0.2:100 --net-arp-respond 10.0.0.2 --net-dhcp-respond-norenew --script '$RUN_DIR/a1.txt' --script2 '$RUN_DIR/a2.txt' --script2-after 'n9a-phase1-ready' --script2-delay 92 --script-expect 'n9a-done' --timeout 220
vgate_run B -- --net '$RUN_DIR/b-cap.bin' --net-dhcp-respond 10.0.0.2:100 --net-dhcp-respond-norebind --script '$RUN_DIR/b1.txt' --script2 '$RUN_DIR/b2.txt' --script2-after 'n9b-phase1-ready' --script2-delay 106 --script-expect 'n9b-done' --timeout 220

vgate_assert A serial-contains 'net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=100'
vgate_assert A serial-contains 'renew=1,rebind=1,renewed=1,expired=0'
vgate_assert A serial-contains 'n9a-done'
vgate_assert A output-contains "NET-DHCP: refused the guest's unicast RENEWING REQUEST"
vgate_assert A output-contains "NET-DHCP: answered the guest's DHCP REQUEST"
vgate_assert A output-contains 'net-dhcp-respond: ENABLED (milestone five card N8, claim 0351) + card N9 (claim 9489)'
vgate_assert A python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -qE pair: the T1 unicast RENEW and the T2 broadcast REBIND.
if not re.search(r"net dhcp: renewing \(T1, elapsed=[0-9]+\) request sent to the server \(298 bytes\)", ser):
    sys.exit("FAIL: no T1 renewing line")
if not re.search(r"net dhcp: rebinding \(T2, elapsed=[0-9]+\) request sent \(298 bytes\)", ser):
    sys.exit("FAIL: no T2 rebinding line")
# The capture: 1222 B = DISCOVER 286 + REQUEST 298 + ARP 42 + RENEW
# 298 (unicast dst 02:00:00:00:00:02, dst IP + ciaddr 10.0.0.2) +
# REBIND 298 (broadcast dst).
cap = open(os.environ["RUN_DIR"] + "/a-cap.bin", "rb").read()
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
    sys.exit("FAIL: renew capture offsets off: %s" % bad)
print("dhcp-renew A rungs + capture ok")
PY

vgate_assert B serial-contains 'dhcp=idle,ip=0.0.0.0,mask=0.0.0.0,gw=0.0.0.0,server=0.0.0.0,lease=0,discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0,renew=0,rebind=1,renewed=0,expired=1'
vgate_assert B serial-contains 'net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=100'
vgate_assert B serial-contains 'n9b-done'
vgate_assert B output-contains 'net-dhcp-respond: ENABLED (milestone five card N8, claim 0351) + card N9 (claim 9489)'
vgate_assert B output-contains "NET-DHCP: refused the guest's broadcast REBINDING REQUEST"
vgate_assert B python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -qE pair: the expiry release and the recovery re-DISCOVER.
if not re.search(r"net dhcp: lease expired \(elapsed=[0-9]+ >= lease=100\)", ser):
    sys.exit("FAIL: no lease-expired line")
if not re.search(r"net dhcp: discover sent xid=0x[0-9a-f]+ \(286 bytes\)", ser):
    sys.exit("FAIL: no re-DISCOVER line")
# Recovery capture holds at least DISCOVER + REQUEST + re-DISCOVER
# (v6-filtered — M117b NDP noise must not mask a missing packet).
cap = open(os.environ["RUN_DIR"] + "/b-cap.bin", "rb").read()
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
n = len(_v4)
if n < 870:
    sys.exit("FAIL: recovery capture %d B, want >= 870" % n)
print("dhcp-renew B expiry + recovery ok")
PY
