# live-net-dhcp.spec -- the bounded RFC 2131 client: P1 runs the full
# DISCOVER/OFFER/REQUEST/ACK handshake against the host responder
# (byte-exact client messages in the capture); P2 rides --net-nat with
# the honest dual-branch (bound dynamic lease OR unbound, never faked)
# plus the static-fallback gateway ping.
# Mirrors tools/verify-live-net-dhcp.sh (claim 0351, card N8). The two
# host-side DISCOVER/ACK EREs ride split fixed-substring
# output-contains (only the variable xid hex falls out -- still pinned
# on the guest side + capture); no format extension needed.

vgate_name live-net-dhcp "RFC 2131 handshake + honest NAT observation on VZ"
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file script-1.txt <<'EOF'
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
net
echo net-dhcp-phase1-ready
EOF

vgate_file script-2.txt <<'EOF'
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net
echo net-dhcp-ok
EOF

vgate_file script-nat-1.txt <<'EOF'
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net dhcp
net
net ip 192.168.64.5
net arp 192.168.64.1
net arp 192.168.64.1
net ping 192.168.64.1
echo net-dhcp-nat-phase1-ready
EOF

vgate_file script-nat-2.txt <<'EOF'
net arp 192.168.64.1
net ping 192.168.64.1
net
net
echo net-dhcp-nat-ok
EOF

vgate_run P1 -- --net '$RUN_DIR/p1-cap.bin' --net-dhcp-respond 10.0.0.2 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'net-dhcp-phase1-ready' --script-expect 'net-dhcp-ok' --timeout 40
vgate_run P2 -- --net-nat --script '$RUN_DIR/script-nat-1.txt' --script2 '$RUN_DIR/script-nat-2.txt' --script2-after 'net-dhcp-nat-phase1-ready' --script-expect 'net-dhcp-nat-ok' --timeout 40

vgate_assert P1 serial-contains 'net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=3600'
vgate_assert P1 serial-contains 'dhcp=bound,ip=10.0.0.2,mask=255.255.255.0,gw=10.0.0.1,server=10.0.0.2,lease=3600,discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0'
vgate_assert P1 serial-contains 'net-dhcp-ok'
vgate_assert P1 output-contains "NET-DHCP: answered the guest's DHCP DISCOVER"
vgate_assert P1 output-contains 'with a OFFER for 10.0.0.2 (lease 3600s)'
vgate_assert P1 output-contains "NET-DHCP: answered the guest's DHCP REQUEST"
vgate_assert P1 output-contains 'with a ACK for 10.0.0.2 (lease 3600s)'
vgate_assert P1 output-contains 'net-dhcp-respond: ENABLED (milestone five card N8, claim 0351)'
vgate_assert P1 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -qE: DISCOVER went out (286 B, hex xid).
if not re.search(r"net dhcp: discover sent xid=0x[0-9a-f]+ \(286 bytes\)", ser):
    sys.exit("FAIL: no DISCOVER-sent line")
# The capture: 584 bytes = 286-B DISCOVER + 298-B REQUEST, load-bearing
# offsets byte-exact (dst ff*6, src guest MAC, ethertype, 68->67, op 1,
# cookie, option 53 = 1 then 3).
cap = open(os.environ["RUN_DIR"] + "/p1-cap.bin", "rb").read()
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

if len(cap) != 584:
    sys.exit("FAIL: capture size %d, want 584" % len(cap))
h = cap.hex()
want = {0: "ffffffffffff020000000001", 24: "0800", 68: "0044", 72: "0043",
        84: "01", 556: "63825363", 564: "350101",
        572: "ffffffffffff020000000001", 1128: "63825363", 1136: "350103"}
bad = [(o, w) for o, w in want.items() if h[o:o + len(w)] != w]
if bad:
    sys.exit("FAIL: capture offsets off: %s" % bad)
print("dhcp P1 DISCOVER + capture ok")
PY

vgate_assert P2 serial-contains 'net-dhcp-nat-ok'
vgate_assert P2 output-contains 'net-nat: ENABLED (milestone five card N7, claim 4678)'
vgate_assert P2 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# The client TRIED the real network (legacy -qE).
if not re.search(r"net dhcp: discover sent xid=0x[0-9a-f]+ \(286 bytes\)", ser):
    sys.exit("FAIL: no NAT DISCOVER-sent line")
# Honest dual-branch on the LAST dhcp report (#879: never fake either).
last_dhcp = [l for l in lines if " dhcp=" in l]
if not last_dhcp:
    sys.exit("FAIL: no dhcp report line")
last = last_dhcp[-1]
bound = re.search(r"dhcp=bound,ip=192\.168\.64\.[0-9]+,mask=[0-9.]+,gw=[0-9.]*,server=192\.168\.64\.1,lease=3600,discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0", last)
unbound = re.search(r"dhcp=(selecting|requesting),ip=0\.0\.0\.0,mask=0\.0\.0\.0,gw=0\.0\.0\.0,server=0\.0\.0\.0,lease=0,discover=[1-9][0-9]*,offer=[0-9]+,request=[0-9]+,ack=0,nack=[0-9]+,timeout=[0-9]+,mal=0", last)
if not bound and not unbound:
    sys.exit("FAIL: last dhcp report is neither bound nor honest-unbound: %r" % last)
# Not stranded: last icmp report shows a completed round trip (req is
# cumulative across the two scripted pings -- pong>=1 anchors it).
last_icmp = [l for l in lines if " icmp=req=" in l]
if not last_icmp:
    sys.exit("FAIL: no icmp report line")
if not re.search(r" icmp=req=[0-9]+,repl=0,pong=[1-9][0-9]*,drop=0,fail=0,seq=[1-9][0-9]*", last_icmp[-1]):
    sys.exit("FAIL: no completed gateway round trip: %r" % last_icmp[-1])
print("dhcp P2 honest-branch + fallback ok (%s)" % ("bound" if bound else "unbound"))
PY
