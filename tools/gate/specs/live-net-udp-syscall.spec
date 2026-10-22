# live-net-udp-syscall.spec -- the UDP syscall seam from EL0: UDP.BIN
# (exec'd) listens, loopbacks, round-trips via the host responder,
# observes EINVAL from EL0, exits 17; observation phase re-reads the
# syscall rows + counters; the capture is byte-exact behind the ARP.
# Mirrors tools/verify-live-net-udp-syscall.sh (claim 1384, card N6).
# capture-equals retries 5x0.5s (legacy 10x0.5s -- same settle idea).

vgate_name live-net-udp-syscall "UDP.BIN drives slots 9/10/11 from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec UDP.BIN
echo udp-syscall-ready
EOF

vgate_file script-2.txt <<'EOF'
syscalls
tasks
net udp
net
echo net-udp-ok
EOF

vgate_setup_python <<'PY'
import os
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
    return (bytes(dst) + bytes(src) + bytes([0x08, 0x06])
            + bytes([0x00, 0x01, 0x08, 0x00, 0x06, 0x04])
            + bytes([op >> 8, op & 0xff])
            + bytes(sha) + bytes(spa) + bytes(tha) + bytes(tpa))

def udp_frame(dst_mac, src_mac, src_ip, dst_ip, src_port, dst_port, payload, ident=0, ttl=64):
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

host_mac = [0x02, 0, 0, 0, 0, 2]
guest_mac = [0x02, 0, 0, 0, 0, 1]
host_ip = [10, 0, 0, 2]
guest_ip = [10, 0, 0, 1]
bcast = [0xff] * 6
payload = b"ping"

req_arp = arp_pkt(bcast, guest_mac, 1, guest_mac, guest_ip, [0] * 6, host_ip)
assert len(req_arp) == 42, len(req_arp)
req_udp = udp_frame(host_mac, guest_mac, guest_ip, host_ip, 7000, 9999, payload, ident=0)
assert len(req_udp) == 46, len(req_udp)
open(os.environ["RUN_DIR"] + "/fixture.bin", "wb").write(req_arp + req_udp)
print("fixture: %d bytes (42-byte ARP request + 46-byte datagram)" % len(req_arp + req_udp))
PY

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-udp-respond 10.0.0.2:9999 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'udp: send err' --script-expect 'tasks user-exec reaped' --timeout 90

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'udp: listen ok'
vgate_assert 01 serial-contains 'udp: loop ping'
vgate_assert 01 serial-contains 'udp: got ping'
vgate_assert 01 serial-contains 'udp: recv err -1'
vgate_assert 01 serial-contains 'udp: send err -1'
vgate_assert 01 serial-contains 'procs UDP.BIN exited status=17'
vgate_assert 01 serial-contains 'tasks user-exec exited status=17'
vgate_assert 01 serial-contains 'tasks user-exec reaped'
# Keep the live census in step with the append-only slot-80 family.
# Repinned 81 -> 84 on VZ serial after the M97b/M97c/M97d slots landed.
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=96'
vgate_assert 01 serial-contains 'net udp: rx=2,tx=2,loop=1,drop=0'
vgate_assert 01 serial-contains ' udp=rx=2,tx=2,loop=1,drop=0'
vgate_assert 01 serial-contains 'net-udp-ok'
vgate_assert 01 python <<'PY'
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
cap = _v4only(open(os.path.join(rd, "cap.bin"), "rb").read())
want = open(os.path.join(rd, "fixture.bin"), "rb").read()
if cap != want:
    sys.exit("FAIL: udp syscall capture != fixture (v6-filtered)")
print("udp syscall byte-exact (v6-filtered)")
PY
vgate_assert 01 python <<'PY'
import os, sys
import re
ser = open(os.environ["VG_SER"], errors="replace").read()
# smp:/prompt lines split app's marker mid-line (`udp: got `/`ping`);
# the fragments merge when the interposed line leaves with its newline.
ser = re.sub(r"\n[^\n]*smp: [^\n]*\n", "", ser)
lines = ser.splitlines()
# Markers IN ORDER (the claim-1014 line-number pattern).
order = ["udp: listen ok", "udp: loop ping", "udp: got ping",
         "udp: recv err -1", "udp: send err -1",
         "procs UDP.BIN exited status=17"]
pos = []
for m in order:
    idx = next((i for i, l in enumerate(lines) if m in l), None)
    if idx is None:
        sys.exit("FAIL: marker absent: %s" % m)
    pos.append(idx)
if any(b <= a for a, b in zip(pos, pos[1:])):
    sys.exit("FAIL: markers out of order: %s" % list(zip(order, pos)))
# Seam rows show real call counts (present, and never "=0").
for row in ("  9 sys_udp_listen calls=", "  10 sys_udp_send calls=", "  11 sys_udp_recv calls="):
    if row not in ser or (row + "0") in ser:
        sys.exit("FAIL: seam row missing or zero: %r" % row)
print("udp-syscall order + rows ok")
PY
