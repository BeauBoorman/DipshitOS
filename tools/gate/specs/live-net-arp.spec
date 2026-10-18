# live-net-arp.spec -- vgate pilot (multi-phase net + generated fixtures):
# ARP observed end to end, byte-exact on the host. Mirrors
# tools/verify-live-net-arp.sh (milestone five, card N3): answer a request
# for our address (p1), resolve a peer (p2), drop a foreign request (p3).
# Proves setup-python fixtures, per-phase runs, capture-equals/empty, and
# serial-contains-file asserts.

vgate_name live-net-arp "ARP live on VZ: answer, resolve, scope check"
vgate_note "p1: inject who-has-10.0.0.1 -> reply byte-exact in capture, repl=1"
vgate_note "p2: guest resolves 10.0.0.2 -> request byte-exact, host answer learned"
vgate_note "p3: request for 10.0.0.99 -> no reply (capture empty), drop=1"

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
echo arp-phase1-ready
EOF
vgate_file script-1b.txt <<'EOF'
net recv
net arp
echo net-arp-ok
EOF
vgate_file script-2.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
echo arp-phase2-ready
EOF
vgate_file script-2b.txt <<'EOF'
net arp
net arp
echo net-arp-ok
EOF
vgate_file script-3.txt <<'EOF'
net ip 10.0.0.1
echo arp-phase1-ready
EOF
vgate_file script-3b.txt <<'EOF'
net recv
net arp
echo net-arp-ok
EOF

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
def arp_pkt(dst, src, op, sha, spa, tha, tpa):
    return (bytes(dst) + bytes(src) + bytes([0x08,0x06])
            + bytes([0x00,0x01,0x08,0x00,0x06,0x04])
            + bytes([op>>8, op&0xff])
            + bytes(sha) + bytes(spa) + bytes(tha) + bytes(tpa))
host_mac = [0x02,0,0,0,0,2]
guest_mac = [0x02,0,0,0,0,1]
host_ip = [10,0,0,2]
guest_ip = [10,0,0,1]
other_ip = [10,0,0,99]
bcast = [0xff]*6
zero6 = [0]*6
req1 = arp_pkt(bcast, host_mac, 1, host_mac, host_ip, zero6, guest_ip)
assert len(req1) == 42, len(req1)
open(rd+"/live-net-arp-fixture-1.bin","wb").write(req1)
rep1 = arp_pkt(host_mac, guest_mac, 2, guest_mac, guest_ip, host_mac, host_ip)
assert len(rep1) == 42, len(rep1)
open(rd+"/live-net-arp-reply-1.bin","wb").write(rep1)
req2 = arp_pkt(bcast, guest_mac, 1, guest_mac, guest_ip, zero6, host_ip)
assert len(req2) == 42, len(req2)
open(rd+"/live-net-arp-fixture-2.bin","wb").write(req2)
req3 = arp_pkt(bcast, host_mac, 1, host_mac, host_ip, zero6, other_ip)
assert len(req3) == 42, len(req3)
open(rd+"/live-net-arp-fixture-3.bin","wb").write(req3)
def hexs(b): return " ".join("%02x" % x for x in b)
obs_hdr = bytes([0]*10) + bytes([0x01, 0x00])
def recv_line(b): return "net recv: " + hexs(obs_hdr) + " " + hexs(b)
open(rd+"/live-net-arp-recv-1.txt","w").write(recv_line(req1))
open(rd+"/live-net-arp-recv-3.txt","w").write(recv_line(req3))
PY

vgate_run p1 -- --net '$RUN_DIR/live-net-arp-cap-1.bin' --net-inject '$RUN_DIR/live-net-arp-fixture-1.bin' --net-inject-after 'net ip: ip=10.0.0.1' --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-1b.txt' --script2-after arp-phase1-ready --script-expect net-arp-ok --timeout 40
vgate_run p2 -- --net '$RUN_DIR/live-net-arp-cap-2.bin' --net-arp-respond 10.0.0.2 --script '$RUN_DIR/script-2.txt' --script2 '$RUN_DIR/script-2b.txt' --script2-after arp-phase2-ready --script-expect net-arp-ok --timeout 40
vgate_run p3 -- --net '$RUN_DIR/live-net-arp-cap-3.bin' --net-inject '$RUN_DIR/live-net-arp-fixture-3.bin' --net-inject-after 'net ip: ip=10.0.0.1' --script '$RUN_DIR/script-3.txt' --script2 '$RUN_DIR/script-3b.txt' --script2-after arp-phase1-ready --script-expect net-arp-ok --timeout 40

vgate_assert p1 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p1 serial-contains 'net recv: frames=1'
vgate_assert p1 serial-contains 'net recv: [0] len=54'
vgate_assert p1 serial-contains-file live-net-arp-recv-1.txt
vgate_assert p1 serial-contains 'net arp: req=0,repl=1,learn=0,drop=0,fail=0'
vgate_assert p1 serial-contains 'net-arp-ok'
vgate_assert p1 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
def v4only(cap):
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
cap = v4only(open(rd + "/live-net-arp-cap-1.bin", "rb").read())
want = open(rd + "/live-net-arp-reply-1.bin", "rb").read()
if cap != want:
    sys.exit("FAIL: arp reply capture != fixture (v6-filtered)")
print("arp reply byte-exact (v6-filtered)")
PY

vgate_assert p2 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p2 serial-contains 'net arp: request for 10.0.0.2 sent (42 bytes)'
vgate_assert p2 serial-contains 'net arp: 10.0.0.2 -> 02:00:00:00:00:02'
vgate_assert p2 serial-contains 'net arp: req=1,repl=0,learn=1,drop=0,fail=0'
vgate_assert p2 serial-contains 'net-arp-ok'
vgate_assert p2 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
def v4only(cap):
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
cap = v4only(open(rd + "/live-net-arp-cap-2.bin", "rb").read())
want = open(rd + "/live-net-arp-fixture-2.bin", "rb").read()
if cap != want:
    sys.exit("FAIL: arp request capture != fixture (v6-filtered)")
print("arp request byte-exact (v6-filtered)")
PY

vgate_assert p3 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert p3 serial-contains 'net recv: frames=1'
vgate_assert p3 serial-contains 'net recv: [0] len=54'
vgate_assert p3 serial-contains-file live-net-arp-recv-3.txt
vgate_assert p3 serial-contains 'net arp: req=0,repl=0,learn=0,drop=1,fail=0'
vgate_assert p3 serial-contains 'net-arp-ok'
vgate_assert p3 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
cap = open(rd + "/live-net-arp-cap-3.bin", "rb").read()
i = 0
while i < len(cap):
    et = cap[i+12:i+14]
    if et == b"\x86\xdd":
        i += 14 + 40 + ((cap[i+18] << 8) | cap[i+19]); continue
    sys.exit("FAIL: non-NDP frame in the refused-request capture")
print("no reply for the refused request (NDP filtered)")
PY
