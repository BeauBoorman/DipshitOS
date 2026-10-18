# live-net-udp.spec -- UDP live on VZ. Mirrors
# tools/verify-live-net-udp.sh (milestone five, card N5): loopback (p1),
# host->guest delivery (p2), guest->host round trip (p3), closed-port
# drop (p4). Same arp-family shape: two-script phases, python fixtures,
# byte-exact captures.

vgate_name live-net-udp "UDP: loopback, delivery, round trip, closed-port drop"
vgate_note "p1: loopback send -> byte-exact recv, rx=1 tx=1 loop=1, capture empty"
vgate_note "p2: injected datagram -> byte-exact recv, len 58 observed"
vgate_note "p3: send to peer -> datagram byte-exact, host answer lands"
vgate_note "p4: closed port -> no delivery, drop=1, frame still observable"

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net udp listen 7000
echo udp-phase1-ready
EOF
vgate_file script-1b.txt <<'EOF'
net udp send 10.0.0.1 7000 4
net udp recv 7000
net udp
echo net-udp-ok
EOF
vgate_file script-2.txt <<'EOF'
net ip 10.0.0.1
net udp listen 7000
echo udp-phase1-ready
EOF
vgate_file script-2b.txt <<'EOF'
net udp recv 7000
net recv
net
echo net-udp-ok
EOF
vgate_file script-3.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net udp listen 7000
echo udp-phase3-ready
EOF
vgate_file script-3b.txt <<'EOF'
net udp send 10.0.0.2 9999 4
net udp recv 7000
net udp recv 7000
net
echo net-udp-ok
EOF
vgate_file script-4.txt <<'EOF'
net ip 10.0.0.1
echo udp-phase1-ready
EOF
vgate_file script-4b.txt <<'EOF'
net udp recv 9998
net recv
net
echo net-udp-ok
EOF

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
def csum(b):
    s = 0
    for i in range(0, len(b) - 1, 2):
        s += (b[i] << 8) | b[i + 1]
    if len(b) % 2:
        s += b[-1] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff

def udp_frame(dst_mac, src_mac, src_ip, dst_ip, src_port, dst_port, payload, ident=1, ttl=64):
    buf = bytearray(46)
    buf[0:6] = dst_mac
    buf[6:12] = src_mac
    buf[12:14] = b"\x08\x00"
    buf[14] = 0x45
    buf[16:18] = (32).to_bytes(2, "big")
    buf[18:20] = ident.to_bytes(2, "big")
    buf[22] = ttl
    buf[23] = 17
    buf[26:30] = src_ip
    buf[30:34] = dst_ip
    c = csum(bytes(buf[14:34]))
    buf[24:26] = c.to_bytes(2, "big")
    udp = bytearray(8 + len(payload))
    udp[0:2] = src_port.to_bytes(2, "big")
    udp[2:4] = dst_port.to_bytes(2, "big")
    udp[4:6] = (8 + len(payload)).to_bytes(2, "big")
    udp[8:] = payload
    ph = bytes(src_ip) + bytes(dst_ip) + b"\x00\x11" + (8 + len(payload)).to_bytes(2, "big")
    c2 = csum(ph + bytes(udp))
    udp[6:8] = c2.to_bytes(2, "big")
    buf[34:46] = udp
    return bytes(buf)

def arp_pkt(dst, src, op, sha, spa, tha, tpa):
    return (bytes(dst) + bytes(src) + bytes([0x08,0x06])
            + bytes([0x00,0x01,0x08,0x00,0x06,0x04])
            + bytes([op>>8, op&0xff])
            + bytes(sha) + bytes(spa) + bytes(tha) + bytes(tpa))

host_mac = [0x02,0,0,0,0,2]
guest_mac = [0x02,0,0,0,0,1]
host_ip = [10,0,0,2]
guest_ip = [10,0,0,1]
bcast = [0xff]*6
payload = b"\x01\x02\x03\x04"

req2 = udp_frame(bcast, host_mac, host_ip, guest_ip, 9999, 7000, payload, ident=0xabcd)
assert len(req2) == 46, len(req2)
open(rd+"/live-net-udp-fixture-2.bin","wb").write(req2)
req3_arp = arp_pkt(bcast, guest_mac, 1, guest_mac, guest_ip, [0]*6, host_ip)
assert len(req3_arp) == 42, len(req3_arp)
req3_udp = udp_frame(host_mac, guest_mac, guest_ip, host_ip, 7000, 9999, payload, ident=0)
assert len(req3_udp) == 46, len(req3_udp)
open(rd+"/live-net-udp-fixture-3.bin","wb").write(req3_arp + req3_udp)
req4 = udp_frame(bcast, host_mac, host_ip, guest_ip, 9999, 9998, payload, ident=1)
assert len(req4) == 46, len(req4)
open(rd+"/live-net-udp-fixture-4.bin","wb").write(req4)

def datagram_hex(src_port, dst_port, plen):
    dg = bytearray(8 + plen)
    dg[0:2] = src_port.to_bytes(2, "big")
    dg[2:4] = dst_port.to_bytes(2, "big")
    dg[4:6] = (8 + plen).to_bytes(2, "big")
    dg[8:] = payload
    src = guest_ip if src_port == 7000 and dst_port == 7000 else host_ip
    dst = guest_ip
    ph = bytes(src) + bytes(dst) + b"\x00\x11" + (8 + plen).to_bytes(2, "big")
    c2 = csum(ph + bytes(dg))
    dg[6:8] = c2.to_bytes(2, "big")
    return " ".join("%02x" % x for x in dg)

def recv_line(dg_hex):
    return "net udp recv: " + dg_hex

open(rd+"/live-net-udp-recv-1.txt","w").write(recv_line(datagram_hex(7000, 7000, 4)))
open(rd+"/live-net-udp-recv-2.txt","w").write(recv_line(datagram_hex(9999, 7000, 4)))
PY

vgate_run p1 -- --net '$RUN_DIR/live-net-udp-cap-1.bin' --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-1b.txt' --script2-after udp-phase1-ready --script-expect net-udp-ok --timeout 40
vgate_run p2 -- --net '$RUN_DIR/live-net-udp-cap-2.bin' --net-inject '$RUN_DIR/live-net-udp-fixture-2.bin' --net-inject-after 'net ip: ip=10.0.0.1' --script '$RUN_DIR/script-2.txt' --script2 '$RUN_DIR/script-2b.txt' --script2-after udp-phase1-ready --script-expect net-udp-ok --timeout 40
vgate_run p3 -- --net '$RUN_DIR/live-net-udp-cap-3.bin' --net-arp-respond 10.0.0.2 --net-udp-respond 10.0.0.2:9999 --script '$RUN_DIR/script-3.txt' --script2 '$RUN_DIR/script-3b.txt' --script2-after udp-phase3-ready --script-expect net-udp-ok --timeout 40
vgate_run p4 -- --net '$RUN_DIR/live-net-udp-cap-4.bin' --net-inject '$RUN_DIR/live-net-udp-fixture-4.bin' --net-inject-after 'net ip: ip=10.0.0.1' --script '$RUN_DIR/script-4.txt' --script2 '$RUN_DIR/script-4b.txt' --script2-after udp-phase1-ready --script-expect net-udp-ok --timeout 40

vgate_assert p1 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p1 serial-contains 'net udp recv: port=7000'
vgate_assert p1 serial-contains 'net udp recv: [0] len=12'
vgate_assert p1 serial-contains-file live-net-udp-recv-1.txt
vgate_assert p1 serial-contains 'net udp: rx=1,tx=1,loop=1,drop=0'
vgate_assert p1 serial-contains 'net-udp-ok'
vgate_assert p1 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
cap = open(os.path.join(rd, "live-net-udp-cap-1.bin"), "rb").read()
i = 0
while i < len(cap):
    if cap[i+12:i+14] == b"\x86\xdd":
        i += 14 + 40 + ((cap[i+18] << 8) | cap[i+19]); continue
    sys.exit("FAIL: non-NDP frame in the no-listener capture")
print("no-listener clean (NDP filtered)")
PY

vgate_assert p2 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p2 serial-contains 'net udp recv: port=7000'
vgate_assert p2 serial-contains 'net udp recv: [0] len=12'
vgate_assert p2 serial-contains-file live-net-udp-recv-2.txt
vgate_assert p2 serial-contains 'net recv: [0] len=58'
vgate_assert p2 serial-contains ' udp=rx=1,tx=0,loop=0,drop=0'
vgate_assert p2 serial-contains 'net-udp-ok'

vgate_assert p3 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p3 serial-contains 'net udp: sent 4 bytes to 10.0.0.2:9999 (46 bytes)'
vgate_assert p3 serial-contains 'net udp recv: port=7000'
vgate_assert p3 serial-contains 'net udp recv: [0] len=12'
vgate_assert p3 serial-contains-file live-net-udp-recv-2.txt
vgate_assert p3 serial-contains ' udp=rx=1,tx=1,loop=0,drop=0'
vgate_assert p3 serial-contains 'net-udp-ok'
vgate_assert p3 python <<'PY'
import os, sys
def _v4only(cap):
    # M117b (#2474): boot-time NDP/ICMPv6 frames ride the same capture —
    # noise to this v4 contract; drop them by the v6 length decode.
    out = bytearray(); i = 0
    while i < len(cap):
        et = cap[i+12:i+14]
        if et == b"\x86\xdd":
            i += 14 + 40 + ((cap[i+18] << 8) | cap[i+19])
        elif et == b"\x08\x06":
            out += cap[i:i+42]; i += 42
        else:
            fl = 14 + ((cap[i+16] << 8) | cap[i+17])
            out += cap[i:i+fl]; i += fl
    return bytes(out)
rd = os.environ["RUN_DIR"]
cap = _v4only(open(os.path.join(rd, "live-net-udp-cap-3.bin"), "rb").read())
want = open(os.path.join(rd, "live-net-udp-fixture-3.bin"), "rb").read()
if cap != want:
    sys.exit("FAIL: udp reply capture != fixture (v6-filtered)")
print("udp reply byte-exact (v6-filtered)")
PY

vgate_assert p4 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p4 serial-contains 'net udp recv: no datagrams for port 9998'
vgate_assert p4 serial-contains 'net recv: [0] len=58'
vgate_assert p4 serial-contains ' udp=rx=0,tx=0,loop=0,drop=1'
vgate_assert p4 serial-contains 'net-udp-ok'
vgate_assert p4 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
cap = open(os.path.join(rd, "live-net-udp-cap-4.bin"), "rb").read()
i = 0
while i < len(cap):
    if cap[i+12:i+14] == b"\x86\xdd":
        i += 14 + 40 + ((cap[i+18] << 8) | cap[i+19]); continue
    sys.exit("FAIL: non-NDP frame in the closed-port capture")
print("closed-port clean (NDP filtered)")
PY
