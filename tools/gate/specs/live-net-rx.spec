# live-net-rx.spec -- virtio-net RX: armed queue, injection, drain,
# MAC filter, round trip. Mirrors tools/verify-live-net-rx.sh (milestone
# five, card N2). The recv-exact disjunctions (full line OR len OR
# rx-obs) are verbatim ORs in the original, so they ride the python
# escape hatch (see SPEC.md).

vgate_name live-net-rx "virtio-net RX: inject, drain, filter, round trip"
vgate_note "p1: 60B broadcast -> byte-exact recv + re-send (capture == fixture)"
vgate_note "p2: own-MAC 46B -> received byte-exact"
vgate_note "p3: foreign-MAC 46B -> dropped, rx-obs still records delivery"

vgate_file script-1.txt <<'EOF'
net recv
net
netsend 46
echo net-rx-ok
EOF
vgate_file script-2.txt <<'EOF'
net recv
net
echo net-rx-ok
EOF
vgate_file script-3.txt <<'EOF'
net recv
net
echo net-rx-ok
EOF

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
own = bytes([0x02,0,0,0,0,1])
p1 = bytes([0xff]*6) + own + bytes([0x08,0]) + bytes(range(46))
assert len(p1) == 60, len(p1)
open(rd+"/live-net-rx-fixture-1.bin","wb").write(p1)
p2 = own + bytes([0x02,0,0,0,0,2]) + bytes([0x08,0]) + bytes(range(32))
assert len(p2) == 46, len(p2)
open(rd+"/live-net-rx-fixture-2.bin","wb").write(p2)
p3 = bytes([0x02,0,0,0,0,3]) + bytes([0x02,0,0,0,0,4]) + bytes([0x08,0]) + bytes(range(32))
assert len(p3) == 46, len(p3)
open(rd+"/live-net-rx-fixture-3.bin","wb").write(p3)
def hexs(b): return " ".join("%02x" % x for x in b)
obs_hdr = bytes([0]*10) + bytes([0x01, 0x00])
def recv_line(b): return "net recv: " + hexs(obs_hdr) + " " + hexs(b)
open(rd+"/live-net-rx-fixture-1.hex","w").write(hexs(p1))
open(rd+"/live-net-rx-recv-1.txt","w").write(recv_line(p1))
open(rd+"/live-net-rx-fixture-2.hex","w").write(hexs(p2))
open(rd+"/live-net-rx-recv-2.txt","w").write(recv_line(p2))
open(rd+"/live-net-rx-fixture-3.hex","w").write(hexs(p3))
PY

vgate_run p1 -- --net '$RUN_DIR/live-net-rx-cap-1.bin' --net-inject '$RUN_DIR/live-net-rx-fixture-1.bin' --script '$RUN_DIR/script-1.txt' --script-expect net-rx-ok --timeout 40
vgate_run p2 -- --net '$RUN_DIR/live-net-rx-cap-2.bin' --net-inject '$RUN_DIR/live-net-rx-fixture-2.bin' --script '$RUN_DIR/script-2.txt' --script-expect net-rx-ok --timeout 40
vgate_run p3 -- --net '$RUN_DIR/live-net-rx-cap-3.bin' --net-inject '$RUN_DIR/live-net-rx-fixture-3.bin' --script '$RUN_DIR/script-3.txt' --script-expect net-rx-ok --timeout 40

vgate_assert p1 serial-contains 'net: rx-armed'
vgate_assert p1 serial-contains 'net: rx-obs len='
vgate_assert p1 serial-contains 'net recv: frames=1'
vgate_assert p1 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
ser = open(os.environ["VG_SER"], errors="replace").read()
line = open(rd+"/live-net-rx-recv-1.txt").read()
if line in ser or "net recv: [0] len=72" in ser or "net: rx-obs len=72" in ser:
    print("p1 recv-exact ok")
else:
    sys.exit("FAIL: p1 recv-exact: no full line, len=72, or rx-obs len=72")
PY
vgate_assert p1 serial-contains 'net: rx=frames=1,bytes=72,filtered=0,overflow=0,fifo=0'
vgate_assert p1 serial-contains 'netsend: tx ok'
vgate_assert p1 python <<'PY'
import os, sys
def _v4only(cap):
    # M117b (#2474): drop boot-time NDP/ICMPv6 noise by the v6 decode.
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
cap = _v4only(open(rd+"/live-net-rx-cap-1.bin","rb").read())
want = open(rd+"/live-net-rx-fixture-1.bin","rb").read()
if cap != want:
    sys.exit("FAIL: rx capture != fixture (v6-filtered)")
print("rx byte-exact (v6-filtered)")
PY

vgate_assert p2 serial-contains 'net: rx-armed'
vgate_assert p2 serial-contains 'net: rx-obs len='
vgate_assert p2 serial-contains 'net recv: frames=1'
vgate_assert p2 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
ser = open(os.environ["VG_SER"], errors="replace").read()
line = open(rd+"/live-net-rx-recv-2.txt").read()
if line in ser or "net recv: [0] len=58" in ser or "net: rx-obs len=58" in ser:
    print("p2 recv-exact ok")
else:
    sys.exit("FAIL: p2 recv-exact: no full line, len=58, or rx-obs len=58")
PY
vgate_assert p2 serial-contains 'net: rx=frames=1,bytes=58,filtered=0,overflow=0,fifo=0'
vgate_assert p2 serial-contains 'net-rx-ok'

vgate_assert p3 serial-contains 'net: rx-armed'
vgate_assert p3 serial-contains 'net: rx-obs len='
vgate_assert p3 serial-contains 'net recv: no frames'
vgate_assert p3 serial-contains 'net: rx-obs len=58'
vgate_assert p3 serial-contains 'net: rx=frames=0,bytes=0,filtered=1,overflow=0,fifo=0'
