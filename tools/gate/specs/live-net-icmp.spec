# live-net-icmp.spec -- IPv4/ICMP live on VZ. Mirrors
# tools/verify-live-net-icmp.sh (milestone five, card N4): answer an echo
# for our address (p1), ping a peer (p2), drop a foreign echo (p3).
# Same arp-family shape: two-script phases, python fixtures, byte-exact
# captures. The recv-exact needles use the full byte-exact line (the
# strongest of the legacy OR alternatives; all hold together at HEAD).

vgate_name live-net-icmp "IPv4/ICMP: answer echo, ping peer, scope check"
vgate_note "p1: injected echo -> reply byte-exact in capture, repl=1"
vgate_note "p2: resolve + ping -> ARP + echo byte-exact, pong=1 seq=1"
vgate_note "p3: foreign echo -> no reply (capture empty), drop=1"

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
echo icmp-phase1-ready
EOF
vgate_file script-1b.txt <<'EOF'
net recv
net
echo net-icmp-ok
EOF
vgate_file script-2.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
echo icmp-phase2-ready
EOF
vgate_file script-2b.txt <<'EOF'
net ping 10.0.0.2
net arp
net
echo net-icmp-ok
EOF
vgate_file script-3.txt <<'EOF'
net ip 10.0.0.1
echo icmp-phase1-ready
EOF
vgate_file script-3b.txt <<'EOF'
net recv
net
echo net-icmp-ok
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

def arp_pkt(dst, src, op, sha, spa, tha, tpa):
    return (bytes(dst) + bytes(src) + bytes([0x08,0x06])
            + bytes([0x00,0x01,0x08,0x00,0x06,0x04])
            + bytes([op>>8, op&0xff])
            + bytes(sha) + bytes(spa) + bytes(tha) + bytes(tpa))

def echo_req(dst_mac, src_mac, src_ip, dst_ip, ident, icmp_id, seq, ttl=64):
    buf = bytearray(46)
    buf[0:6] = dst_mac
    buf[6:12] = src_mac
    buf[12:14] = b"\x08\x00"
    buf[14] = 0x45
    buf[16:18] = (32).to_bytes(2, "big")
    buf[18:20] = ident.to_bytes(2, "big")
    buf[22] = ttl
    buf[23] = 0x01
    buf[26:30] = src_ip
    buf[30:34] = dst_ip
    c = csum(bytes(buf[14:34]))
    buf[24:26] = c.to_bytes(2, "big")
    icmp = bytearray(12)
    icmp[0] = 0x08
    icmp[4:6] = icmp_id.to_bytes(2, "big")
    icmp[6:8] = seq.to_bytes(2, "big")
    icmp[8:12] = b"\x01\x02\x03\x04"
    c2 = csum(bytes(icmp))
    icmp[2:4] = c2.to_bytes(2, "big")
    buf[34:46] = icmp
    return bytes(buf)

def echo_reply_from_req(req, guest_mac, guest_ip):
    buf = bytearray(len(req))
    buf[0:6] = req[6:12]
    buf[6:12] = guest_mac
    buf[12:14] = b"\x08\x00"
    buf[14] = 0x45
    buf[16:18] = req[16:18]
    buf[18:20] = req[18:20]
    buf[22] = 64
    buf[23] = 0x01
    buf[26:30] = guest_ip
    buf[30:34] = req[26:30]
    c = csum(bytes(buf[14:34]))
    buf[24:26] = c.to_bytes(2, "big")
    buf[34] = 0x00
    icmp_len = len(buf) - 34
    icmp = bytearray(icmp_len)
    icmp[4:] = req[38:]
    c2 = csum(bytes(icmp))
    icmp[2:4] = c2.to_bytes(2, "big")
    buf[34:] = icmp
    return bytes(buf)

host_mac = [0x02,0,0,0,0,2]
guest_mac = [0x02,0,0,0,0,1]
host_ip = [10,0,0,2]
guest_ip = [10,0,0,1]
other_ip = [10,0,0,99]
bcast = [0xff]*6
zero6 = [0]*6

req1 = echo_req(bcast, host_mac, host_ip, guest_ip, ident=0xabcd, icmp_id=0x1234, seq=0x5678)
assert len(req1) == 46, len(req1)
open(rd+"/live-net-icmp-fixture-1.bin","wb").write(req1)
rep1 = echo_reply_from_req(req1, guest_mac, guest_ip)
assert len(rep1) == 46, len(rep1)
open(rd+"/live-net-icmp-reply-1.bin","wb").write(rep1)
req2_arp = arp_pkt(bcast, guest_mac, 1, guest_mac, guest_ip, zero6, host_ip)
assert len(req2_arp) == 42, len(req2_arp)
req2_icmp = echo_req(host_mac, guest_mac, guest_ip, host_ip, ident=1, icmp_id=1, seq=1)
assert len(req2_icmp) == 46, len(req2_icmp)
open(rd+"/live-net-icmp-fixture-2.bin","wb").write(req2_arp + req2_icmp)
req3 = echo_req(bcast, host_mac, host_ip, other_ip, ident=1, icmp_id=1, seq=1)
assert len(req3) == 46, len(req3)
open(rd+"/live-net-icmp-fixture-3.bin","wb").write(req3)
def hexs(b): return " ".join("%02x" % x for x in b)
obs_hdr = bytes([0]*10) + bytes([0x01, 0x00])
def recv_line(b): return "net recv: " + hexs(obs_hdr) + " " + hexs(b)
open(rd+"/live-net-icmp-recv-1.txt","w").write(recv_line(req1))
open(rd+"/live-net-icmp-recv-3.txt","w").write(recv_line(req3))
PY

vgate_run p1 -- --net '$RUN_DIR/live-net-icmp-cap-1.bin' --net-inject '$RUN_DIR/live-net-icmp-fixture-1.bin' --net-inject-after 'net ip: ip=10.0.0.1' --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-1b.txt' --script2-after icmp-phase1-ready --script-expect net-icmp-ok --timeout 40
vgate_run p2 -- --net '$RUN_DIR/live-net-icmp-cap-2.bin' --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 --script '$RUN_DIR/script-2.txt' --script2 '$RUN_DIR/script-2b.txt' --script2-after icmp-phase2-ready --script-expect net-icmp-ok --timeout 40
vgate_run p3 -- --net '$RUN_DIR/live-net-icmp-cap-3.bin' --net-inject '$RUN_DIR/live-net-icmp-fixture-3.bin' --net-inject-after 'net ip: ip=10.0.0.1' --script '$RUN_DIR/script-3.txt' --script2 '$RUN_DIR/script-3b.txt' --script2-after icmp-phase1-ready --script-expect net-icmp-ok --timeout 40

vgate_assert p1 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p1 serial-contains 'net recv: frames=1'
vgate_assert p1 serial-contains-file live-net-icmp-recv-1.txt
vgate_assert p1 serial-contains ' icmp=req=0,repl=1,pong=0,drop=0,fail=0,seq=0'
vgate_assert p1 serial-contains 'net-icmp-ok'
vgate_assert p1 python <<'PY'
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
cap = _v4only(open(os.path.join(rd, "live-net-icmp-cap-1.bin"), "rb").read())
want = open(os.path.join(rd, "live-net-icmp-reply-1.bin"), "rb").read()
if cap != want:
    sys.exit("FAIL: icmp reply capture != fixture (v6-filtered)")
print("icmp reply byte-exact (v6-filtered)")
PY

vgate_assert p2 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p2 serial-contains 'net ping: echo request to 10.0.0.2 sent (46 bytes)'
vgate_assert p2 serial-contains ' icmp=req=1,repl=0,pong=1,drop=0,fail=0,seq=1'
vgate_assert p2 serial-contains 'net arp: 10.0.0.2 -> 02:00:00:00:00:02'
vgate_assert p2 serial-contains 'net arp: req=1,repl=0,learn=1,drop=0,fail=0'
vgate_assert p2 serial-contains 'net-icmp-ok'
vgate_assert p2 python <<'PY'
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
cap = _v4only(open(os.path.join(rd, "live-net-icmp-cap-2.bin"), "rb").read())
want = open(os.path.join(rd, "live-net-icmp-fixture-2.bin"), "rb").read()
if cap != want:
    sys.exit("FAIL: icmp request capture != fixture (v6-filtered)")
print("icmp request byte-exact (v6-filtered)")
PY

vgate_assert p3 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p3 serial-contains 'net recv: frames=1'
vgate_assert p3 serial-contains-file live-net-icmp-recv-3.txt
vgate_assert p3 serial-contains ' icmp=req=0,repl=0,pong=0,drop=1,fail=0,seq=0'
vgate_assert p3 serial-contains 'net-icmp-ok'
vgate_assert p3 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
cap = open(os.path.join(rd, "live-net-icmp-cap-3.bin"), "rb").read()
i = 0
while i < len(cap):
    if cap[i+12:i+14] == b"\x86\xdd":
        i += 14 + 40 + ((cap[i+18] << 8) | cap[i+19]); continue
    sys.exit("FAIL: non-NDP frame in the refused-ping capture")
print("refused-ping clean (NDP filtered)")
PY
