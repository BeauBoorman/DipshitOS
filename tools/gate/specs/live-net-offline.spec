# live-net-offline.spec -- the offline preflight (N13/N14): Run A
# with no net device (both apps exit fast with the diagnosis, never
# connected); Run B with net but no route (no-route exit, no stats);
# Run C the online control (healthy paths unaffected, no
# false-positive preflight).
# Mirrors tools/verify-live-net-offline.sh (claim 8852). One structural
# note: legacy seeds the share for Run A only (B/C run gateless);
# the spec seeds all runs (per-spec share mode) -- behavior-neutral
# for network paths, validated by the equivalence runs.
#
# M71n (#1573) retargeted the ping rows to GOPING.ELF, the Go successor to
# Zig PING.BIN (deleted with user/src/ping.zig). GOPING speaks the same
# slots 59/60 and the same N13/N14 preflight (vi.NetPreflight is the Go twin
# of user/src/lib/netstatus.zig), so the 0/2/3 exit contract is unchanged and
# only the binary name moved.
#
# M78b (#1683) flips the card's former non-goal: the FETCH rows move onto
# GOFETCH.ELF's explicit http:// mode (user/go/fetch legacy.go). The Zig
# FETCH.BIN is deleted; GOFETCH speaks the same N13/N14 preflight through the
# same vi.NetPreflight and keeps the fetch: message shapes and the 3 / 4 / 42
# exit contract, so only the binary name moved on these rows.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goping.sh         ->  .build/go/GOPING.ELF
#   bash tools/go/build-web.sh fetch GOFETCH ->  .build/go/GOFETCH.ELF

vgate_name live-net-offline "offline + no-route preflight, online control on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, build in (("GOPING.ELF", "bash tools/go/build-goping.sh"),
                    ("GOFETCH.ELF", "bash tools/go/build-web.sh fetch GOFETCH")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)" % (name, os.path.getsize(os.path.join(share, name))))
PY

vgate_file a1.txt <<'EOF'
exec GOPING.ELF -c 3 10.0.0.2
exec GOFETCH.ELF http://10.0.0.2/
echo both-launched
EOF

vgate_file a2.txt <<'EOF'
echo offline-ok
EOF

vgate_file b1.txt <<'EOF'
net ip 10.0.0.1
exec GOPING.ELF -c 1 10.0.0.2
echo ping-noroute-launched
EOF

vgate_file b2.txt <<'EOF'
echo noroute-ok
EOF

vgate_file c1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec GOPING.ELF -c 3 10.0.0.2
echo ping-online-launched
EOF

vgate_file c2.txt <<'EOF'
exec GOFETCH.ELF http://10.0.0.2/
EOF

vgate_file c3.txt <<'EOF'
echo online-ok
EOF

vgate_run A -- --script '$RUN_DIR/a1.txt' --script2 '$RUN_DIR/a2.txt' --script2-after 'offline — no IP address' --script-expect 'GOFETCH.ELF exited status=3' --timeout 90
vgate_run B -- --net '$RUN_DIR/b-cap.bin' --script '$RUN_DIR/b1.txt' --script2 '$RUN_DIR/b2.txt' --script2-after 'ping-noroute-launched' --script-expect 'GOPING.ELF exited status=3' --timeout 90
vgate_run C -- --net '$RUN_DIR/c-cap.bin' --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 --script '$RUN_DIR/c1.txt' --script2 '$RUN_DIR/c2.txt' --script2-after 'ping statistics' --script3 '$RUN_DIR/c3.txt' --script3-after 'fetch: starting' --script-expect 'GOFETCH.ELF exited status=42' --timeout 120

vgate_assert A serial-contains 'ping: offline — no IP address'
vgate_assert A serial-contains 'fetch: offline — no IP address'
vgate_assert A serial-contains 'echo offline-ok'
vgate_assert A serial-absent 'fetch: connected'
vgate_assert A python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -cE >= 1 with the ([^0-9]|$) guard (status=2 must not match
# status=20+, hex exit likewise).
if sum(1 for _ in re.finditer(r"GOPING\.ELF exited status=2([^0-9]|$)|exit=0x0000000000000002", ser)) < 1:
    sys.exit("FAIL: no GOPING.ELF exit-2")
if sum(1 for _ in re.finditer(r"GOFETCH\.ELF exited status=3([^0-9]|$)|exit=0x0000000000000003", ser)) < 1:
    sys.exit("FAIL: no GOFETCH.ELF exit-3")
# Fast exit: the bounded poll never ran -- no statistics footer.
if sum(1 for l in ser.splitlines() if "ping statistics" in l) != 0:
    sys.exit("FAIL: ping statistics present (not a fast exit)")
print("offline A exits ok")
PY

vgate_assert B serial-contains 'net ip: ip=10.0.0.1'
vgate_assert B serial-contains 'ping: no route to 10.0.0.2'
vgate_assert B serial-contains 'echo noroute-ok'
vgate_assert B python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -cE >= 1 (guarded) + zero statistics lines (fast exit).
if sum(1 for _ in re.finditer(r"GOPING\.ELF exited status=3([^0-9]|$)|exit=0x0000000000000003", ser)) < 1:
    sys.exit("FAIL: no GOPING.ELF exit-3")
if sum(1 for l in ser.splitlines() if "ping statistics" in l) != 0:
    sys.exit("FAIL: ping statistics present (not a fast exit)")
print("offline B exit ok")
PY

vgate_assert C serial-contains 'PING 10.0.0.2 (10.0.0.2): 56 data bytes'
vgate_assert C serial-contains '64 bytes from 10.0.0.2: icmp_seq=1'
vgate_assert C serial-contains 'ping statistics'
vgate_assert C serial-contains '0% packet loss'
vgate_assert C serial-contains 'fetch: connected'
vgate_assert C serial-contains 'HTTP/1.0 200 OK'
vgate_assert C serial-contains 'fetch: done'
vgate_assert C serial-contains 'echo online-ok'
vgate_assert C serial-absent 'offline'
vgate_assert C serial-absent 'no route'
vgate_assert C python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E pair: the exit-0 / exit-42 rows.
if not re.search(r"GOPING\.ELF exited status=0|GOPING\.ELF.*exit=0x0000000000000000", ser):
    sys.exit("FAIL: no GOPING.ELF exit-0 row")
if not re.search(r"GOFETCH\.ELF exited status=42|GOFETCH\.ELF.*exit=0x000000000000002a", ser):
    sys.exit("FAIL: no GOFETCH.ELF exit-42 row")
print("offline C control ok")
PY

# --- M184a (#3174): a hostname can dial v6 ----------------------------------
# vi.Dial's name path is v4-first: the A question goes first and a
# usable answer dials v4 unchanged; only an A answer with nothing
# dialable (NODATA or the passive-open 0.0.0.0) sends the AAAA
# question, whose answer opens the tagged familyV6Tag socket. The
# hermetic responder answers EVERY A query, so the legs pin the A
# answer to 0.0.0.0 to stand in for NODATA — the same "nothing
# dialable" condition the fallback keys on.
#   run D   A=0.0.0.0 + AAAA=<peer> + the v6 fleet -> the name resolves
#           AAAA and dials TCP6 (the card's bet, end to end)
#   run E   A=10.0.0.2 + the v4 fleet -> the name dials v4 and the wire
#           shows exactly one DNS query (A) — A-only names unchanged
#   run F   A=0.0.0.0 + AAAA=:: -> every record undialable -> the named
#           refusal (ErrServerDial), no socket op spent

vgate_file namedial.go <<'EOF'
package main

import (
    "time"
    "virelai/vi"
    "virelai/vsys"
)

// GODIALNAME.ELF — the M184a (#3174) live fixture: one vi.DialTimeout on
// a NAME, so the resolver's v4-first/AAAA-fallback ordering picks the
// family. Success prints 'namedial: resolved family=v4|v6' then the
// GET/close proof; a refusal prints 'namedial: refused err=<name>' and
// exits 1.
func fail(s string) {
    vsys.Println("namedial: FAIL " + s)
    vsys.Exit(1)
}

func main() {
    args := vi.Args()
    if len(args) != 3 {
        vsys.Println("namedial: usage GODIALNAME.ELF <name> <port>")
        vsys.Exit(2)
    }
    var port uint64
    for i := 0; i < len(args[2]); i++ {
        ch := args[2][i]
        if ch < '0' || ch > '9' {
            vsys.Println("namedial: bad port")
            vsys.Exit(2)
        }
        port = port*10 + uint64(ch-'0')
    }
    c, err := vi.DialTimeout(args[1], uint16(port), 10*time.Second)
    if err != nil {
        vsys.Println("namedial: refused err=" + err.Error())
        vsys.Exit(1)
    }
    fam := "v4"
    if c.IsV6() {
        fam = "v6"
    }
    vsys.Println("namedial: resolved family=" + fam)
    if _, err = c.Send([]byte("GET / HTTP/1.0\r\n\r\n")); err != nil {
        fail("send")
    }
    c.SetRecvDeadline(5_000_000_000)
    buf := make([]byte, vi.TCPPayloadMax)
    n, err := c.Recv(buf)
    if err != nil || n < 15 || string(buf[:15]) != "HTTP/1.0 200 OK" {
        fail("GET response")
    }
    if err = c.Close(); err != nil {
        fail("close")
    }
    vsys.Println("namedial: connected")
    vsys.Println("namedial: done")
    vsys.Exit(0)
}
EOF

vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "namedial-build"
tmp.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="GODIALNAME", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "namedial.go")], env=env, check=True)
PY

vgate_file d1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
echo net4-ready
EOF

vgate_file d2.txt <<'EOF'
net ndp 2001:db8:64::ff:fe00:2
net ip6
net ndp 2001:db8:64::ff:fe00:2
exec GODIALNAME.ELF v6only.local 8080
echo namedial-v6-launched
EOF

vgate_file e1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec GODIALNAME.ELF aonly.local 8080
echo namedial-v4-launched
EOF

vgate_file f1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec GODIALNAME.ELF zero.local 8080
echo namedial-refused-launched
EOF

# Run D -- the AAAA path end to end: the name's A answer is the
# undialable 0.0.0.0, so the second question asks AAAA, the answer is
# the hermetic v6 peer, and the connect lands on the TCP6 responder.
vgate_run D -- --net '$RUN_DIR/d-cap.bin' \
    --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2 \
    --net-dns-answer 0.0.0.0 --net-dns-answer6 20010db800640000000000fffe000002 \
    --net-ra-respond '2001:db8:64::/64' \
    --net-ndp-respond '2001:db8:64::ff:fe00:2' \
    --net-tcp6-respond '[2001:db8:64::ff:fe00:2]:8080' \
    --script '$RUN_DIR/d1.txt' \
    --script2 '$RUN_DIR/d2.txt' --script2-after 'net: v6 g6=2001:db8:64::ff:fe00:1 valid' \
    --script-expect 'namedial: done' --timeout 120

vgate_assert D output-contains 'net-ra-respond: ENABLED'
vgate_assert D output-contains 'net-ndp-respond: ENABLED'
vgate_assert D output-contains 'net-tcp6-respond: ENABLED'
vgate_assert D output-contains "NET-DNS: answered the guest's DNS query for 'v6only.local' qtype=1"
vgate_assert D output-contains "NET-DNS: answered the guest's DNS query for 'v6only.local' qtype=28"
vgate_assert D output-contains 'NET-TCP6: answered'
vgate_assert D serial-contains 'net ndp: 2001:db8:64::ff:fe00:2 is at 02:00:00:00:00:02'
vgate_assert D serial-contains 'namedial: resolved family=v6'
vgate_assert D serial-contains 'namedial: done'
vgate_assert D serial-absent 'namedial: FAIL'
vgate_assert D python <<'PY'
import os, sys
d = open(os.environ["RUN_DIR"] + "/d-cap.bin", "rb").read()
off, qtypes, syn4, syn6 = 0, [], 0, 0
while off < len(d):
    et = d[off+12:off+14]
    if et == b"\x08\x00":
        flen = 14 + ((d[off+16] << 8) | d[off+17])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 42 and f[23] == 17 and f[30:34] == bytes([10,0,0,2]) \
           and f[36:38] == b"\x00\x35" and (f[44] & 0x80) == 0:
            q = 42 + 12
            while q < len(f):
                l = f[q]
                if l == 0:
                    q += 1
                    break
                q += 1 + l
            qtypes.append((f[q] << 8) | f[q+1])
        if len(f) >= 48 and f[23] == 6 and (f[47] & 0x02):
            syn4 += 1
    elif et == b"\x86\xdd":
        flen = 14 + 40 + ((d[off+18] << 8) | d[off+19])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 68 and f[20] == 6 and (f[67] & 0x02):
            syn6 += 1
    else:
        off += 42
if qtypes != [1, 28]:
    sys.exit("FAIL: wire qtypes %r, want [A, AAAA] in that order" % (qtypes,))
if syn6 < 1:
    sys.exit("FAIL: no TCP/IPv6 SYN on the wire")
if syn4 != 0:
    sys.exit("FAIL: a TCPv4 SYN escaped — the name dialed the wrong family")
print("aaaa dial ok: qtypes %r, tcp6 syns %d, no v4 connect" % (qtypes, syn6))
PY

# Run E -- A-only unchanged: a usable A answer dials v4 and the wire
# shows exactly one DNS query (qtype=1) — no AAAA question is paid.
vgate_run E -- --net '$RUN_DIR/e-cap.bin' \
    --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2 \
    --net-dns-answer 10.0.0.2 --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/e1.txt' \
    --script-expect 'namedial: done' --timeout 90

vgate_assert E output-contains "NET-DNS: answered the guest's DNS query for 'aonly.local' qtype=1"
vgate_assert E output-contains 'NET-TCP: answered'
vgate_assert E serial-contains 'namedial: resolved family=v4'
vgate_assert E serial-contains 'namedial: done'
vgate_assert E python <<'PY'
import os, sys
d = open(os.environ["RUN_DIR"] + "/e-cap.bin", "rb").read()
off, qtypes, syn4, syn6 = 0, [], 0, 0
while off < len(d):
    et = d[off+12:off+14]
    if et == b"\x08\x00":
        flen = 14 + ((d[off+16] << 8) | d[off+17])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 42 and f[23] == 17 and f[30:34] == bytes([10,0,0,2]) \
           and f[36:38] == b"\x00\x35" and (f[44] & 0x80) == 0:
            q = 42 + 12
            while q < len(f):
                l = f[q]
                if l == 0:
                    q += 1
                    break
                q += 1 + l
            qtypes.append((f[q] << 8) | f[q+1])
        if len(f) >= 48 and f[23] == 6 and (f[47] & 0x02):
            syn4 += 1
    elif et == b"\x86\xdd":
        flen = 14 + 40 + ((d[off+18] << 8) | d[off+19])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 68 and f[20] == 6 and (f[67] & 0x02):
            syn6 += 1
    else:
        off += 42
if qtypes != [1]:
    sys.exit("FAIL: wire qtypes %r, want exactly one A — a usable A answer never asks AAAA" % (qtypes,))
if syn4 < 1:
    sys.exit("FAIL: no TCPv4 SYN on the wire")
if syn6 != 0:
    sys.exit("FAIL: a TCP6 SYN escaped — the name dialed the wrong family")
print("a-only unchanged ok: qtypes %r, tcp4 syns %d" % (qtypes, syn4))
PY

# Run F -- the named refusal: every record the name carries is
# undialable (A=0.0.0.0, AAAA=::), so the dial refuses by name before
# any socket op — the wire shows both questions and zero connects.
vgate_run F -- --net '$RUN_DIR/f-cap.bin' \
    --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2 \
    --net-dns-answer 0.0.0.0 --net-dns-answer6 00000000000000000000000000000000 \
    --script '$RUN_DIR/f1.txt' \
    --script-expect 'GODIALNAME.ELF exited status=1' --timeout 90

vgate_assert F output-contains "NET-DNS: answered the guest's DNS query for 'zero.local' qtype=1"
vgate_assert F output-contains "NET-DNS: answered the guest's DNS query for 'zero.local' qtype=28"
vgate_assert F serial-contains 'namedial: refused err=vi: 0.0.0.0 is the passive-open address'
vgate_assert F serial-absent 'namedial: connected'
vgate_assert F python <<'PY'
import os, sys
d = open(os.environ["RUN_DIR"] + "/f-cap.bin", "rb").read()
off, qtypes, syns = 0, [], 0
while off < len(d):
    et = d[off+12:off+14]
    if et == b"\x08\x00":
        flen = 14 + ((d[off+16] << 8) | d[off+17])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 42 and f[23] == 17 and f[30:34] == bytes([10,0,0,2]) \
           and f[36:38] == b"\x00\x35" and (f[44] & 0x80) == 0:
            q = 42 + 12
            while q < len(f):
                l = f[q]
                if l == 0:
                    q += 1
                    break
                q += 1 + l
            qtypes.append((f[q] << 8) | f[q+1])
        if len(f) >= 48 and f[23] == 6 and (f[47] & 0x02):
            syns += 1
    elif et == b"\x86\xdd":
        flen = 14 + 40 + ((d[off+18] << 8) | d[off+19])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 68 and f[20] == 6 and (f[67] & 0x02):
            syns += 1
    else:
        off += 42
if qtypes != [1, 28]:
    sys.exit("FAIL: wire qtypes %r, want [A, AAAA] in that order" % (qtypes,))
if syns != 0:
    sys.exit("FAIL: %d SYNs on the wire — an undialable answer connected" % syns)
print("named refusal ok: qtypes %r, zero connects" % (qtypes,))
PY
