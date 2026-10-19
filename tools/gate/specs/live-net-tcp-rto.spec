# live-net-tcp-rto.spec -- the bounded retransmission + timer: Run A
# the black-hole SYN retransmitted autonomously (retx>=2, capture
# holds >=3 byte-identical SYNs); Run B the SYN-ACK clears pending
# (retx=0, exactly one SYN on the wire); Run C the data black hole
# (10 retransmissions, honest abort, eleven byte-identical frames).
# Mirrors tools/verify-live-net-tcp-rto.sh (claim 5357, card N11).

vgate_name live-net-tcp-rto "TCP retransmission timer + bound on VZ"
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file a1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp
net tcp connect 10.0.0.2 9999
net
echo n11a-phase1-ready
EOF

vgate_file a2.txt <<'EOF'
net tcp
net
echo n11a-done
EOF

vgate_file b1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp
net tcp connect 10.0.0.2 9999
net
echo n11b-phase1-ready
EOF

vgate_file b2.txt <<'EOF'
net tcp
net
echo n11b-done
EOF

vgate_file c1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp
net tcp connect 10.0.0.2 9999
net tcp
net tcp send 5
net
echo n11c-phase1-ready
EOF

vgate_file c2.txt <<'EOF'
net tcp
net
echo n11c-done
EOF

# warm-cold: A,B,C (d) --script2-delay arms the retransmission-timer
#   windows against host wall-clock — a timing budget formed across the
#   freeze is uninterpretable post-restore (ADR 0059 D7(d))
vgate_run A -- --net '$RUN_DIR/a-cap.bin' --net-arp-respond 10.0.0.2 --script '$RUN_DIR/a1.txt' --script2 '$RUN_DIR/a2.txt' --script2-after 'n11a-phase1-ready' --script2-delay 7 --script-expect 'n11a-done' --timeout 120
vgate_run B -- --net '$RUN_DIR/b-cap.bin' --net-tcp-respond 10.0.0.2:9999 --net-arp-respond 10.0.0.2 --script '$RUN_DIR/b1.txt' --script2 '$RUN_DIR/b2.txt' --script2-after 'n11b-phase1-ready' --script2-delay 7 --script-expect 'n11b-done' --timeout 120
# 34 wall-s no longer covers the 33 guest-tick abort at HEAD (guest
# ticks run ~10% slow under host load: 2/2 boots land 9 RTOs in 34 s
# on BOTH harnesses, still established retx=9; same slip explains the
# N10 Run-B retx=8). 48 s restores a solid margin (a 40 s attempt still
# raced the abort past script2's reads); every assertion below is
# byte-identical to legacy.
vgate_run C -- --net '$RUN_DIR/c-cap.bin' --net-tcp-respond 10.0.0.2:9999:handshake --net-arp-respond 10.0.0.2 --script '$RUN_DIR/c1.txt' --script2 '$RUN_DIR/c2.txt' --script2-after 'n11c-phase1-ready' --script2-delay 48 --script-expect 'n11c-done' --timeout 150

vgate_assert A serial-contains 'net tcp: syn retransmitted (1/10)'
vgate_assert A serial-contains 'net tcp: syn retransmitted (2/10)'
vgate_assert A serial-contains 'tcp=syn_sent,peer=10.0.0.2:9999,syn=1,synack=0,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=0,abort=0'
vgate_assert A serial-contains 'n11a-done'
vgate_assert A output-contains 'net-arp-respond: ENABLED'
vgate_assert A python <<'PY'
import os, re, struct, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -qE: the SYN went out.
if not re.search(r"net tcp: syn sent \(peer=10\.0\.0\.2:9999, seq=0x[0-9a-f]+, 54 bytes\)", ser):
    sys.exit("FAIL: no SYN line")
# Legacy retx>=2 phase-2 report (the RTO is a 1 Hz-tick timer; a third
# RTO can fire with boot/settle timing -- the count is honestly >= 2).
# Take the LAST syn_sent report: the phase-1 retx=0 line always matches
# first (a re.search takes it and fails the bound -- spec bug caught
# live 2026-09-04; legacy tails the last retx= for the same reason).
ms = re.findall(r"tcp=syn_sent,peer=10\.0\.0\.2:9999,syn=1,synack=0,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=([0-9]+),abort=0", ser)
if not ms or int(ms[-1]) < 2:
    sys.exit("FAIL: no syn_sent retx>=2 report (reports: %s)" % ms)
# The capture: ARP + >= 3 byte-IDENTICAL 54-B SYN frames, nothing else.
d = open(os.environ["RUN_DIR"] + "/a-cap.bin", "rb").read()
off = 0
syns = []
v6b = 0
while off < len(d):
    if d[off+12:off+14] == b'\x08\x00':
        total = (d[off+16] << 8) | d[off+17]
        syns.append(d[off:off+14+total])
        off += 14 + total
    elif d[off+12:off+14] == b"\x86\xdd":
        # M117b (#2474): NDP/ICMPv6 frames are legitimate capture traffic;
        # skip them by the v6 length decode (14 + 40 + payload_len).
        v6n = 14 + 40 + ((d[off+18] << 8) | d[off+19])
        v6b += v6n
        off += v6n
    else:
        off += 42
assert len(syns) >= 3, len(syns)
assert all(len(f) == 54 for f in syns), [len(f) for f in syns]
assert len(d) == 42 + 54 * len(syns) + v6b, (len(d), v6b)
assert all(f == syns[0] for f in syns), "retransmitted SYNs must be byte-identical"
def chk(data):
    if len(data) % 2: data += b'\x00'
    s = sum(struct.unpack('>%dH' % (len(data) // 2), data))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
assert syns[0][47] == 0x02 and syns[0][42:46] == b'\x00' * 4, "syn flags/ack"
assert (syns[0][34] << 8) | syns[0][35] == 8000 and (syns[0][36] << 8) | syns[0][37] == 9999, "syn ports"
assert syns[0][30:34] == bytes([10, 0, 0, 2]), "syn dst ip"
assert syns[0][0:6] == bytes([2, 0, 0, 0, 0, 2]) and syns[0][6:12] == bytes([2, 0, 0, 0, 0, 1]), "syn macs"
assert syns[0][46] == 0x50 and syns[0][48:50] == bytes([0x10, 0x00]), "syn offset/window"
assert chk(syns[0][14:34]) == 0, "syn ipv4 checksum"
for i, f in enumerate(syns):
    seg = f[34:]
    ps = bytes([10, 0, 0, 1, 10, 0, 0, 2, 0, 6]) + struct.pack('>H', len(seg))
    assert chk(ps + seg) == 0, ("tcp checksum", i)
print("tcp-rto A SYN walk ok (%d frames)" % len(syns))
PY

vgate_assert B serial-contains 'net tcp: established (peer=10.0.0.2:9999)'
vgate_assert B serial-contains 'tcp=established,peer=10.0.0.2:9999,syn=1,synack=1,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=0,abort=0'
vgate_assert B serial-contains 'tcp=established,peer=10.0.0.2:9999,syn=1,synack=1,ack=1,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=0,abort=0'
vgate_assert B serial-contains 'n11b-done'
vgate_assert B serial-absent 'retransmitted'
vgate_assert B output-contains 'net-tcp-respond: ENABLED (milestone five card N10, claim 7026) + card N11 (claim 5357)'
vgate_assert B python <<'PY'
import os, re, struct, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -qE: the SYN went out.
if not re.search(r"net tcp: syn sent \(peer=10\.0\.0\.2:9999, seq=0x[0-9a-f]+, 54 bytes\)", ser):
    sys.exit("FAIL: no SYN line")
# The capture: ARP + SYN + handshake ACK = 150 B, exactly ONE SYN.
d = open(os.environ["RUN_DIR"] + "/b-cap.bin", "rb").read()
# M117b NDP frames pad the capture: the 150-byte pin applies to the
# non-v6 bytes (ARP + SYN + handshake ACK), not the whole file.
off = 0
v4_bytes = 0
while off < len(d):
    et = d[off+12:off+14]
    if et == b"\x86\xdd":
        off += 14 + 40 + ((d[off+18] << 8) | d[off+19])
    elif et == b"\x08\x00":
        n = 14 + ((d[off+16] << 8) | d[off+17])
        v4_bytes += n
        off += n
    else:
        v4_bytes += 42
        off += 42
assert v4_bytes == 150, (v4_bytes, len(d))
off = 0
tcpf = []
while off < len(d):
    if d[off+12:off+14] == b'\x08\x00':
        total = (d[off+16] << 8) | d[off+17]
        tcpf.append(d[off:off+14+total])
        off += 14 + total
    elif d[off+12:off+14] == b"\x86\xdd":
        # M117b (#2474): NDP/ICMPv6 frames are legitimate capture traffic;
        # skip them by the v6 length decode (14 + 40 + payload_len).
        off += 14 + 40 + ((d[off+18] << 8) | d[off+19])
    else:
        off += 42
assert len(tcpf) == 2, len(tcpf)
assert [len(f) for f in tcpf] == [54, 54], [len(f) for f in tcpf]
assert tcpf[0][47] == 0x02 and tcpf[1][47] == 0x10, "SYN then the handshake ACK"
synseq = int.from_bytes(tcpf[0][38:42], 'big')
assert tcpf[1][38:42] == ((synseq + 1) & 0xffffffff).to_bytes(4, 'big'), "handshake ack seq"
assert tcpf[1][42:46] == (0x12345678 + 1).to_bytes(4, 'big'), "handshake ack ack = server ISN + 1"
print("tcp-rto B single-SYN capture ok")
PY

vgate_assert C serial-contains 'net tcp: ack sent (ack=0x12345679, 54 bytes)'
vgate_assert C serial-contains 'tcp=established,peer=10.0.0.2:9999,syn=1,synack=1,ack=1,data_s=1,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=0,abort=0'
vgate_assert C serial-contains 'net tcp: data retransmitted (1/10)'
vgate_assert C serial-contains 'net tcp: data retransmitted (10/10)'
vgate_assert C serial-contains 'net tcp: retransmission limit reached (10) — connection aborted'
vgate_assert C serial-contains 'tcp=idle,peer=0.0.0.0:0,syn=1,synack=1,ack=1,data_s=1,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0,retx=10,abort=1'
vgate_assert C serial-contains 'net tcp: no connection (net tcp connect <addr> <port>)'
vgate_assert C serial-contains 'n11c-done'
vgate_assert C output-contains 'net-tcp-respond mode: handshake-only (card N11)'
vgate_assert C python <<'PY'
import os, re, struct, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -qE pair: SYN + data lines (guest seq varies).
if not re.search(r"net tcp: syn sent \(peer=10\.0\.0\.2:9999, seq=0x[0-9a-f]+, 54 bytes\)", ser):
    sys.exit("FAIL: no SYN line")
if not re.search(r"net tcp: data sent \(seq=0x[0-9a-f]+, 5 bytes\)", ser):
    sys.exit("FAIL: no data line")
# Legacy -Fc = 10: exactly ten data-retransmission lines.
n = sum(1 for l in lines if "net tcp: data retransmitted (" in l)
if n != 10:
    sys.exit("FAIL: data retransmission lines=%d, want 10" % n)
# The capture: ARP + SYN + ACK + ELEVEN byte-identical 59-B data
# frames = 799 B.
d = open(os.environ["RUN_DIR"] + "/c-cap.bin", "rb").read()
off = 0
tcpf = []
v6b = 0
while off < len(d):
    if d[off+12:off+14] == b'\x08\x00':
        total = (d[off+16] << 8) | d[off+17]
        tcpf.append(d[off:off+14+total])
        off += 14 + total
    elif d[off+12:off+14] == b"\x86\xdd":
        # M117b (#2474): NDP/ICMPv6 frames are legitimate capture traffic;
        # skip them by the v6 length decode (14 + 40 + payload_len).
        v6n = 14 + 40 + ((d[off+18] << 8) | d[off+19])
        v6b += v6n
        off += v6n
    else:
        off += 42
assert len(d) == 799 + v6b, (len(d), v6b)
assert len(tcpf) == 13, len(tcpf)
assert [len(f) for f in tcpf] == [54, 54] + [59] * 11, [len(f) for f in tcpf]
def chk(data):
    if len(data) % 2: data += b'\x00'
    s = sum(struct.unpack('>%dH' % (len(data) // 2), data))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
assert tcpf[0][47] == 0x02 and tcpf[1][47] == 0x10, "SYN then the handshake ACK"
data = tcpf[2:]
assert all(f == data[0] for f in data), "retransmitted data must be byte-identical"
assert data[0][47] == 0x10 and data[0][54:59] == bytes([1, 2, 3, 4, 5]), "data flags/payload"
for i, f in enumerate(tcpf):
    seg = f[34:]
    ps = bytes([10, 0, 0, 1, 10, 0, 0, 2, 0, 6]) + struct.pack('>H', len(seg))
    assert chk(ps + seg) == 0, ("tcp checksum", i)
print("tcp-rto C bound walk ok")
PY
