# go-net.spec -- live File/Conn, DNS, loopback and fail-closed TCP waits.
# Runs 01/02 prove GET/read refusal with a surviving goroutine heartbeat.
# Runs 03/04/05 prove vi DNS+TCP, UDP loopback and legacy connect refusal.
# The two connect rows measure guest physical-counter-derived nanoseconds:
# explicit 5 s ETIMEDOUT and legacy 30 s EINVAL, followed by a successful
# connect/GET/close in the SAME process, proving lock and slot cleanup.
# --net is an isolated datagram attachment, NOT NAT or a host TCP socket.
# Only port 8080 has a responder; SYN to 8081 cannot receive any reply.
# Captured guest TX proves SYN/retransmit bytes reached that fixture.
# GOVINET's heartbeat is counter-paced here, not scheduler-tick sleeping:
# connect masks its core's IRQs, but must not stop a runnable peer goroutine.
# Prerequisite binaries: just go-gonet + just go-govinet.
# exec-order: assert-proven -- observation waits for the fixture's done marker.

vgate_name go-net "Live File/Conn, vi DNS/loopback, fail-closed reads, and bounded outbound connect with legacy 30 s regression"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GONET.ELF
EOF

vgate_file script-vidns.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOVIDNS.ELF
EOF

vgate_file script-viloop.txt <<'EOF'
net ip 10.0.0.1
exec GOVINET.ELF viloop
EOF

vgate_file script-viclosed.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOVINET.ELF viclosed
EOF

vgate_file script-connect.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOCONNECT.ELF
EOF

vgate_file script-connect-legacy.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOCONNECT.ELF legacy
EOF

vgate_file script-connect-after.txt <<'EOF'
syscalls
net
echo netconnect-observed
EOF

vgate_file connect.go <<'EOF'
package main

import (
    "time"
    "virelai/vi"
    "virelai/vsys"
)

func fail(s string) {
    vsys.Println("netconnect: FAIL " + s)
    vsys.Exit(1)
}

func main() {
    legacy := false
    for _, arg := range vi.Args() {
        if arg == "legacy" { legacy = true }
    }
    mode := "bounded"
    if legacy { mode = "legacy" }
    vsys.Println("netconnect: dialing " + mode)
    begin := vi.Nanos()
    var c *vi.Conn
    var err error
    if legacy {
        c, err = vi.Dial("10.0.0.2", 8081)
    } else {
        c, err = vi.DialTimeout("10.0.0.2", 8081, 5*time.Second)
    }
    end := vi.Nanos()
    if c != nil || err == nil { fail("silent peer connected") }
    vsys.Println("netconnect: elapsed mode=" + mode + " begin_ns=" + vsys.Itoa64(begin) + " end_ns=" + vsys.Itoa64(end) + " err=" + err.Error())
    _, rc := vi.TCPReady()
    if rc != -vi.ErrEAGAIN { fail("socket owner remains") }
    vsys.Println("netconnect: no owner")
    if rc = vi.TCPClose(); rc != 0 { fail("close after timeout") }
    if legacy {
        c, err = vi.Dial("10.0.0.2", 8080)
    } else {
        c, err = vi.DialTimeout("10.0.0.2", 8080, 5*time.Second)
    }
    if err != nil { fail("reconnect " + err.Error()) }
    vsys.Println("netconnect: reconnected")
    if _, err = c.Send([]byte("GET / HTTP/1.0\r\n\r\n")); err != nil { fail("send") }
    c.SetRecvDeadline(5_000_000_000)
    buf := make([]byte, vi.TCPPayloadMax)
    n, err := c.Recv(buf)
    if err != nil || n < 15 || string(buf[:15]) != "HTTP/1.0 200 OK" { fail("GET response") }
    if err = c.Close(); err != nil { fail("close reconnect") }
    vsys.Println("netconnect: GET and close ok")
    vsys.Println("netconnect: done")
    vsys.Exit(0)
}
EOF

vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "connect-build"
tmp.mkdir()
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="GOCONNECT", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "connect.go")], env=env, check=True)
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GONET.ELF")
if not os.path.exists(src):
    sys.exit("GONET.ELF missing (expected " + src + ") - build it first: just go-gonet")
shutil.copy(src, os.path.join(share, "GONET.ELF"))
for name in ("GOVINET.ELF", "GOVIDNS.ELF"):
    src2 = os.path.join(".build", "go", name)
    if not os.path.exists(src2):
        sys.exit(name + " missing (expected " + src2 + ") - build it first: just go-govinet")
    shutil.copy(src2, os.path.join(share, name))
share_file = os.path.join(share, "GONET.SHARE")
with open(share_file, "w") as f:
    f.write("gonet-share-hello\n")
print("staged GONET.ELF (%d bytes), GOVINET.ELF (%d bytes), GOVIDNS.ELF (%d bytes), GONET.SHARE (%d bytes)"
      % (os.path.getsize(os.path.join(share, "GONET.ELF")),
         os.path.getsize(os.path.join(share, "GOVINET.ELF")),
         os.path.getsize(os.path.join(share, "GOVIDNS.ELF")),
         os.path.getsize(share_file)))
PY

vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
# Keep the original fixture's phases and assertions. Only its heartbeat
# pacing changes: a sleeping peer depends on timer IRQs on the dialing
# core, which slot 30 masks. A runnable peer on the other Go M instead
# samples the physical counter and cooperatively yields its kernel task.
source = pathlib.Path("tools/go/govinet.go").read_text()
needle = "\t\tvsys.Sleep(2)\n"
assert source.count(needle) == 1, "GOVINET heartbeat pacing anchor changed"
source = source.replace(needle, """\t\tdeadline := vsys.Nanotime() + 2_000_000_000
\t\tfor vsys.Nanotime() < deadline && !*stop {
\t\t\tvi.Yield()
\t\t}
""")
fixture = rd / "govinet-counter.go"
fixture.write_text(source)
env = dict(os.environ, TMPDIR=str(rd / "connect-build"), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="GOVINET", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(fixture)], env=env, check=True)
print("GOVINET heartbeat rebuilt with physical-counter pacing; original phases and assertions unchanged")
PY

# Run 01 -- the peer answers: the full N10 responder on 8080.
vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script.txt' --script-expect 'gonet OK' --timeout 120

# Run 02 -- the peer goes dark: SYN-ACK, then silence on data.
vgate_run 02 -- --net '$RUN_DIR/cap2.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080:handshake \
    --script '$RUN_DIR/script.txt' --script-expect 'gonet OK' --timeout 120

vgate_assert 01 serial-contains 'exec: loaded GONET.ELF'
vgate_assert 01 serial-contains 'gonet: start'
vgate_assert 01 serial-contains 'gonet: readfile n='
vgate_assert 01 serial-contains 'gonet: connected'
vgate_assert 01 serial-contains 'gonet: wrote GET n='
vgate_assert 01 serial-contains 'gonet: hb='
vgate_assert 01 serial-contains 'gonet: body total='
vgate_assert 01 serial-contains 'gonet: heartbeat survived load'
vgate_assert 01 serial-contains 'gonet OK'
vgate_assert 01 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 01 serial-absent '[EXC] parking:'
# Phase 2.1: the EL0 clock is live on target (a 0/dead clock fails here).
vgate_assert 01 serial-contains 'gonet: clock ok'
vgate_assert 01 serial-absent 'gonet: clock DEAD'
vgate_assert 01 serial-contains 'gonet: failclosed ms='

vgate_assert 02 serial-contains 'gonet: connected'
vgate_assert 02 serial-contains 'gonet: hb='
vgate_assert 02 serial-contains 'gonet: read failed closed err='
# Phase 2.1: the same clock proof on the peer-goes-dark run.
vgate_assert 02 serial-contains 'gonet: clock ok'
vgate_assert 02 serial-absent 'gonet: clock DEAD'
vgate_assert 02 serial-contains 'gonet: failclosed ms='
vgate_assert 02 serial-contains 'gonet: heartbeat survived load'
vgate_assert 02 serial-contains 'gonet OK'
vgate_assert 02 output-contains "NET-TCP: answered the guest's SYN"
# The ORDER proof: a heartbeat line must appear AFTER the fail-closed line,
# i.e. the second goroutine kept running while the read was failing.
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
fail = next((i for i, l in enumerate(lines) if "gonet: read failed closed err=" in l), None)
if fail is None:
    sys.exit("FAIL: no fail-closed marker (the peer went dark but the read did not fail closed)")
after = [i for i, l in enumerate(lines) if "gonet: hb=" in l and i > fail]
if not after:
    sys.exit("FAIL: the heartbeat did NOT continue after the read failed closed")
before = [i for i, l in enumerate(lines) if "gonet: hb=" in l and i < fail]
if not before:
    sys.exit("FAIL: the heartbeat never ran before the read blocked")
print("go-net order ok: %d heartbeats before the fail-closed line, %d after"
      % (len(before), len(after)))
PY

# --- M67a (#1446): the vi socket surface, the N5 bar -----------------------

# Run 03 -- the host round trip through vi: DNS-resolve a NAME (the host
# responder answers myhost.local -> 10.0.0.2), then Dial/Send/Recv the GET.
vgate_run 03 -- --net '$RUN_DIR/cap3.bin' --net-arp-respond 10.0.0.2 \
    --net-dns-respond 10.0.0.2:53 --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script-vidns.txt' --script-expect 'gonet OK' --timeout 120

vgate_assert 03 serial-contains 'govinet: vidns start'
vgate_assert 03 serial-contains 'govinet: vidns resolved myhost.local -> 10.0.0.2'
vgate_assert 03 serial-contains 'govinet: vidns connected'
vgate_assert 03 serial-contains 'govinet: vidns sent n='
vgate_assert 03 serial-contains 'govinet: vidns body total='
vgate_assert 03 serial-contains 'gonet OK'
vgate_assert 03 output-contains "NET-DNS: answered the guest's DNS query for 'myhost.local'"
vgate_assert 03 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 03 serial-absent 'govinet: FAIL'
vgate_assert 03 serial-absent '[EXC] parking:'

# Run 04 -- the loopback bar: the vi UDP seam's own-IP datagram comes back
# to the guest's own listen ring. No --net is armed: there is no device to
# leak onto, so a pass IS the loopback proof.
vgate_run 04 -- --script '$RUN_DIR/script-viloop.txt' --script-expect 'gonet OK' --timeout 120

vgate_assert 04 serial-contains 'govinet: viloop start'
vgate_assert 04 serial-contains 'govinet: viloop bound'
vgate_assert 04 serial-contains 'govinet: viloop sent n=4'
vgate_assert 04 serial-contains 'govinet: viloop echoed n=12'
vgate_assert 04 serial-contains 'gonet OK'
vgate_assert 04 serial-absent 'govinet: viloop no echo'
vgate_assert 04 serial-absent 'govinet: FAIL'

# Run 05 -- the closed-port drop: 8081 has no responder, so the connect
# waits in the kernel for its 30 s window and then refuses (rc = -1, the
# kernel's einval on connect timeout) while the heartbeat keeps printing.
vgate_run 05 -- --net '$RUN_DIR/cap5.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script-viclosed.txt' --script-expect 'gonet OK' --timeout 120

vgate_assert 05 serial-contains 'govinet: viclosed start'
vgate_assert 05 serial-contains 'govinet: viclosed dialing 10.0.0.2:8081'
vgate_assert 05 serial-contains 'govinet: viclosed refused rc=-1'
vgate_assert 05 serial-contains 'govinet: heartbeat survived load'
vgate_assert 05 serial-contains 'gonet OK'
vgate_assert 05 serial-absent 'govinet: FAIL'
vgate_assert 05 serial-absent '[EXC] parking:'
# The ORDER proof for a BLOCKING Dial: the heartbeat ran before the dial
# started, and — the point — it kept running across the 30 s refused dial.
vgate_assert 05 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
dial = next((i for i, l in enumerate(lines) if "govinet: viclosed dialing" in l), None)
ref  = next((i for i, l in enumerate(lines) if "govinet: viclosed refused rc=" in l), None)
if dial is None or ref is None:
    sys.exit("FAIL: missing the dialing/refused markers")
before = [i for i, l in enumerate(lines) if "govinet: hb=" in l and i < dial]
during = [i for i, l in enumerate(lines) if "govinet: hb=" in l and dial < i < ref]
after  = [i for i, l in enumerate(lines) if "govinet: hb=" in l and i > ref]
if not before:
    sys.exit("FAIL: the heartbeat never ran before the dial")
if not during:
    sys.exit("FAIL: the heartbeat did NOT run during the 30 s refused dial — a blocking Dial wedged the process")
if not after:
    sys.exit("FAIL: the heartbeat did NOT continue after the refusal")
print("go-net viclosed order ok: %d beats before, %d during, %d after the refused dial"
      % (len(before), len(during), len(after)))
PY

# No injection, NAT, relay, or other TCP responder is armed. Port 8081
# goes unanswered by construction; the responder matches ONLY port 8080.
vgate_run connect -- --net '$RUN_DIR/connect.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080 --script '$RUN_DIR/script-connect.txt' \
    --script2 '$RUN_DIR/script-connect-after.txt' --script2-after 'netconnect: done' \
    --script-expect 'netconnect-observed' --timeout 120

vgate_run connect-legacy -- --net '$RUN_DIR/connect-legacy.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080 --script '$RUN_DIR/script-connect-legacy.txt' \
    --script2 '$RUN_DIR/script-connect-after.txt' --script2-after 'netconnect: done' \
    --script-expect 'netconnect-observed' --timeout 120

vgate_assert connect serial-contains 'netconnect: no owner'
vgate_assert connect serial-contains 'netconnect: reconnected'
vgate_assert connect serial-contains 'netconnect: GET and close ok'
vgate_assert connect serial-absent 'netconnect: FAIL'
vgate_assert connect serial-absent '[EXC] parking:'
vgate_assert connect output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert connect python <<'PY'
import os, pathlib, re, struct
rd = pathlib.Path(os.environ["RUN_DIR"])
ser = pathlib.Path(os.environ["VG_SER"]).read_text()
m = re.search(r"netconnect: elapsed mode=bounded begin_ns=(\d+) end_ns=(\d+) err=ETIMEDOUT", ser)
assert m, "missing guest counter samples or wrong timeout error"
elapsed = int(m[2]) - int(m[1])
assert 5_000_000_000 <= elapsed < 6_000_000_000, elapsed
assert re.search(r"tcp=idle,[^\n]*,timedout=1,", ser), "timeout singleton/counter not observed"
# M99g: vi.Dial rides slot-80 op-10 now, so slot 30 sees no connects and
# slot 33 only the fixture's explicit cleanup call; the handle ops ride 80.
assert "  30 sys_tcp_connect calls=0" in ser and "  33 sys_tcp_close calls=1" in ser
m2 = re.search(r"  80 sys_socket calls=(\d+)", ser)
assert m2 and int(m2.group(1)) >= 5, "slot-80 ops missing (connects+send+read+close)"
data = (rd / "connect.bin").read_bytes()
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
pathlib.Path("artifacts", "go-net-connect-wire" + suffix + ".bin").write_bytes(data)
syns = []
i = 0
while i < len(data):
    et = data[i+12:i+14]
    if et == b"\x86\xdd":  # M117b's autonomous v6 frames (DAD NS, RS) — skip
        size = 14 + 40 + struct.unpack_from("!H", data, i+18)[0]
        i += size
        continue
    assert et in (b"\x08\x06", b"\x08\x00"), "unexpected capture frame"
    size = 42 if et == b"\x08\x06" else 14 + struct.unpack_from("!H", data, i+16)[0]
    f = data[i:i+size]
    if f[12:14] == b"\x08\x00" and f[23] == 6 and f[37:38] == b"\x91" and f[36] == 0x1f:
        assert f[30:34] == bytes([10,0,0,2]) and f[47] == 2, "silent port transmitted something other than SYN"
        syns.append(f)
    i += size
assert len(syns) == 2 and syns[0] == syns[1], "expected initial SYN and one byte-identical 3 s retransmit"
print("bounded connect: guest counters %.6f s; two unanswered SYNs; clean owner/lock/GET/close" % (elapsed / 1e9))
PY

vgate_assert connect-legacy serial-contains 'netconnect: no owner'
vgate_assert connect-legacy serial-contains 'netconnect: GET and close ok'
vgate_assert connect-legacy serial-absent 'netconnect: FAIL'
vgate_assert connect-legacy serial-absent '[EXC] parking:'
vgate_assert connect-legacy output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert connect-legacy python <<'PY'
import os, pathlib, re, struct
rd = pathlib.Path(os.environ["RUN_DIR"])
ser = pathlib.Path(os.environ["VG_SER"]).read_text()
m = re.search(r"netconnect: elapsed mode=legacy begin_ns=(\d+) end_ns=(\d+) err=EINVAL", ser)
assert m, "missing guest counter samples or changed legacy timeout error"
elapsed = int(m[2]) - int(m[1])
assert 30_000_000_000 <= elapsed < 31_000_000_000, elapsed
assert re.search(r"tcp=idle,[^\n]*,timedout=1,", ser), "legacy timeout singleton/counter not observed"
# M99g: same slot-80 reroute — the 'legacy' mode's 30 s EINVAL now comes
# from op-10's default connect window, not the retired slot-30 path.
assert "  30 sys_tcp_connect calls=0" in ser and "  33 sys_tcp_close calls=1" in ser
data = (rd / "connect-legacy.bin").read_bytes()
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
pathlib.Path("artifacts", "go-net-connect-legacy-wire" + suffix + ".bin").write_bytes(data)
syns = []
i = 0
while i < len(data):
    et = data[i+12:i+14]
    if et == b"\x86\xdd":  # M117b's autonomous v6 frames (DAD NS, RS) — skip
        size = 14 + 40 + struct.unpack_from("!H", data, i+18)[0]
        i += size
        continue
    assert et in (b"\x08\x06", b"\x08\x00"), "unexpected capture frame"
    size = 42 if et == b"\x08\x06" else 14 + struct.unpack_from("!H", data, i+16)[0]
    f = data[i:i+size]
    if f[12:14] == b"\x08\x00" and f[23] == 6 and f[36:38] == b"\x1f\x91":
        assert f[30:34] == bytes([10,0,0,2]) and f[47] == 2
        syns.append(f)
    i += size
# M99h (#2186) adaptive RTO backs each retransmit off on a growing schedule,
# so the 30 s legacy dial emits 4 identical SYNs, not the fixed-3 s pin's 10 —
# verified byte-identical against the M104d baseline capture. The contract the
# leg proves is unchanged: the silent port saw only SYN retries (same frame,
# same seq) until the dial returned EINVAL.
assert len(syns) >= 2 and all(s == syns[0] for s in syns), \
    "legacy SYN/retransmit sequence changed: %d frames" % len(syns)
print("legacy connect: guest counters %.6f s; %d identical SYNs; unchanged EINVAL; reconnect/GET/close" % (elapsed / 1e9, len(syns)))
PY

# --- M99f (#2184): socket multiplicity ------------------------------------
# The sshd+agentd+rfb shape: three processes each hold a vi.Listen slot-30
# listener — three coexisting table listeners, distinct owners — while the
# host dials two of them at once: two live connections, distinct 5-tuples,
# in one capture. The listener-only 6003 proves the table holds more than
# the two sockets a connection pair needs. Each accepted process exits
# after the peer's FIN, so owner death also reclaims the sockets.

vgate_file listener.go <<'EOF'
package main

import (
    "strconv"
    "virelai/vi"
    "virelai/vsys"
)

func fail(s string) {
    vsys.Println("listener: FAIL " + s)
    vsys.Exit(1)
}

func main() {
    args := vi.Args()
    if len(args) < 2 {
        fail("no port")
    }
    p, err := strconv.ParseUint(args[1], 10, 16)
    if err != nil {
        fail("bad port " + args[1])
    }
    tag := strconv.Itoa(int(p))
    ln, err := vi.Listen(uint16(p))
    if err != nil {
        fail("listen " + tag + " " + err.Error())
    }
    vsys.Println("listener: listen " + tag)
    if err := ln.Accept(); err != nil {
        fail("accept " + tag + " " + err.Error())
    }
    vsys.Println("listener: accepted " + tag)
    if _, err := ln.Send([]byte("hello from " + tag)); err != nil {
        fail("send " + tag + " " + err.Error())
    }
    buf := make([]byte, vi.TCPPayloadMax)
    _, _ = ln.Recv(buf) // drains the peer's FIN (readable-but-empty = gone)
    vsys.Println("listener: done " + tag)
    vsys.Exit(0)
}
EOF

vgate_file script-multi.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOLISTEN.ELF 6001
exec GOLISTEN.ELF 6002
exec GOLISTEN.ELF 6003
EOF

vgate_file script-multi-end.txt <<'EOF'
echo multi-finished
EOF

vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "connect-build"
tmp.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="GOLISTEN", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "listener.go")], env=env, check=True)
PY

# The two 'done' markers are unordered across the two connections, so the
# run ends on a script2 echo fired by a bounded delay after the SECOND
# connection's listener reports — the same script2-delay mechanism the
# live-net-tcp black-hole run uses.
vgate_run multi -- --net '$RUN_DIR/multi.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:6001 --net-tcp-connect 10.0.0.1:6002 \
    --net-tcp-connect-after 'listener: listen 6003' \
    --script '$RUN_DIR/script-multi.txt' \
    --script2 '$RUN_DIR/script-multi-end.txt' --script2-after 'listener: done 6002' --script2-delay 8 \
    --script-expect 'multi-finished' --timeout 120

vgate_assert multi serial-contains 'listener: listen 6001'
vgate_assert multi serial-contains 'listener: listen 6002'
vgate_assert multi serial-contains 'listener: listen 6003'
vgate_assert multi serial-contains 'listener: accepted 6001'
vgate_assert multi serial-contains 'listener: accepted 6002'
vgate_assert multi serial-contains 'listener: done 6001'
vgate_assert multi serial-contains 'listener: done 6002'
vgate_assert multi serial-absent 'listener: FAIL'
vgate_assert multi serial-absent '[EXC] parking:'
vgate_assert multi output-contains 'NET-TCP-CONNECT: sent SYN to 10.0.0.1:6001'
vgate_assert multi output-contains 'NET-TCP-CONNECT: sent SYN to 10.0.0.1:6002'
vgate_assert multi output-contains 'NET-TCP-CONNECT: handshake complete'
vgate_assert multi python <<'PY'
import os, struct
# The wire walk. The capture carries the GUEST's frames only (the runner
# writes its own replies into the socketpair, not the file — the same
# one-direction shape the live-net-tcp 9-frame walk relies on). Two guest
# listeners (6001/6002) answer two host client source ports
# (12345/12346) — distinct 5-tuples whose lifecycles interleave in ONE
# capture: a singleton guest TCP could not send the second listener's
# SYN-ACK while the first connection was still emitting.
data = open(os.environ["RUN_DIR"] + "/multi.bin", "rb").read()
frames = []
i = 0
while i < len(data):
    if data[i+12:i+14] == b"\x08\x06":
        i += 42
        continue
    if data[i+12:i+14] == b"\x86\xdd":  # M117b's autonomous v6 frames — skip
        i += 14 + 40 + struct.unpack_from("!H", data, i + 18)[0]
        continue
    assert data[i+12:i+14] == b"\x08\x00", "unexpected capture frame"
    size = 14 + struct.unpack_from("!H", data, i + 16)[0]
    frames.append(data[i:i+size])
    i += size
conns = {6001: [], 6002: []}
dst_ports = {}
for idx, f in enumerate(frames):
    if f[23] != 6:
        continue
    sp = (f[34] << 8) | f[35]
    dp = (f[36] << 8) | f[37]
    if sp not in conns or f[26:30] != bytes([10, 0, 0, 1]):
        continue
    conns[sp].append((idx, f[47], len(f) - 54))
    dst_ports.setdefault(sp, set()).add(dp)
for port, segs in conns.items():
    assert segs, "listener %d emitted nothing" % port
    assert any(fl == 0x12 for _, fl, _ in segs), "no SYN-ACK from %d" % port
    assert any(n > 0 for _, _, n in segs), "no data segment from %d" % port
    assert dst_ports[port] == {12345 + (port - 6001)}, (port, dst_ports[port])
# Concurrency: each connection's first frame precedes the other's LAST —
# both were live at once on the wire.
assert conns[6001][0][0] < conns[6002][-1][0] and conns[6002][0][0] < conns[6001][-1][0], (
    "connection windows did not overlap: %r vs %r" % (conns[6001], conns[6002]))
print("multi ok: 3 listeners, 2 concurrent connections, distinct 5-tuples")
PY

# --- M99g (#2185): per-handle outbound conns -----------------------------
# One process now holds several outbound vi.Dial connections: op-10 of
# the slot-80 socket ABI mints a table handle per Dial, priced against
# the kernel's own owner_limit (4 per process). The fifth Dial is the
# bound's own ENOSPC, surfaced as ErrConnBusy BY NAME — there is no
# userland copy of the bound. Two of the held conns carry data so the
# capture shows two distinct guest source ports with interleaved
# lifecycles; GONETSTAT.ELF runs alongside and its `netstat: sock`
# diff-log must list the live conns with the owner's pid.

vgate_file dialpair.go <<'EOF'
package main

import (
	"errors"
	"time"

	"virelai/vi"
	"virelai/vsys"
)

func fail(s string) {
	vsys.Println("dialpair: FAIL " + s)
	vsys.Exit(1)
}

func main() {
	// Four concurrent outbound connections from ONE process. The kernel
	// table's per-owner bound is 4, so these must all succeed — and each
	// answer is a distinct per-connection handle. (Channels, not the sync
	// package: the fixture must stay inside the kernel's text gap.)
	conns := make([]*vi.Conn, 4)
	errs := make([]error, 4)
	done := make(chan int, len(conns))
	for i := range conns {
		go func(i int) {
			conns[i], errs[i] = vi.DialTimeout("10.0.0.2", 8080, 15*time.Second)
			done <- i
		}(i)
	}
	for range conns {
		<-done
	}
	seen := make(map[uint64]bool)
	for i, c := range conns {
		if errs[i] != nil {
			fail("dial refused " + errs[i].Error())
		}
		if c == nil {
			fail("dial returned no conn")
		}
		if seen[c.Handle()] {
			fail("two dials share a handle")
		}
		seen[c.Handle()] = true
		vsys.Println("dialpair: open h=" + vsys.Itoa64(int64(c.Handle())))
	}

	// The fifth Dial meets the kernel's ENOSPC — named ErrConnBusy, not
	// a userland singleton guard (there is none any more).
	c5, err := vi.DialTimeout("10.0.0.2", 8080, 5*time.Second)
	if c5 != nil || err == nil {
		fail("fifth dial succeeded")
	}
	if !errors.Is(err, vi.ErrConnBusy) {
		fail("fifth dial = " + err.Error())
	}
	vsys.Println("dialpair: fifth refused busy")

	// Hold the pair long enough for GONETSTAT's ~1 Hz refresh to log the
	// live rows, then carry data on both — two live connections, two
	// distinct source ports on the wire.
	holdUntil := vi.Nanos() + 3_000_000_000
	for vi.Nanos() < holdUntil {
		vi.Yield()
	}
	_ = conns[2].Close()
	_ = conns[3].Close()
	dataDone := make(chan int, 2)
	for i := 0; i < 2; i++ {
		go func(i int, c *vi.Conn) {
			tag := "one"
			if i == 1 {
				tag = "two"
			}
			if _, err := c.Send([]byte("GET /" + tag + " HTTP/1.0\r\n\r\n")); err != nil {
				fail("send " + tag + " " + err.Error())
			}
			c.SetRecvDeadline(15_000_000_000)
			buf := make([]byte, vi.TCPPayloadMax)
			n, err := c.Recv(buf)
			if err != nil || n < 15 || string(buf[:15]) != "HTTP/1.0 200 OK" {
				fail("recv " + tag)
			}
			vsys.Println("dialpair: data " + tag)
			dataDone <- i
		}(i, conns[i])
	}
	<-dataDone
	<-dataDone
	_ = conns[0].Close()
	_ = conns[1].Close()
	vsys.Println("dialpair: done")
	vsys.Exit(0)
}
EOF

vgate_file script-dialpair.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GONETSTAT.ELF
exec GO2DIAL.ELF
EOF

vgate_file script-dialpair-end.txt <<'EOF'
echo dialpair-finished
EOF

vgate_setup_python <<'PY'
import os, pathlib, subprocess, shutil, sys
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "connect-build"
tmp.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="GO2DIAL", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "dialpair.go")], env=env, check=True)
src = os.path.join(".build", "go", "GONETSTAT.ELF")
if not os.path.exists(src):
    sys.exit("GONETSTAT.ELF missing (expected " + src + ") - build it first: bash tools/go/build-netdiag.sh")
shutil.copy(src, os.path.join(share, "GONETSTAT.ELF"))
PY

# script2 ends the run a beat after the pair finishes: the markers are all
# emitted by then, and netstat's diff-log has already printed the rows.
vgate_run dialpair -- --net '$RUN_DIR/dialpair.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script-dialpair.txt' \
    --script2 '$RUN_DIR/script-dialpair-end.txt' --script2-after 'dialpair: done' --script2-delay 8 \
    --script-expect 'dialpair-finished' --timeout 120

vgate_assert dialpair serial-contains 'netstat: ready'
vgate_assert dialpair serial-contains 'dialpair: fifth refused busy'
vgate_assert dialpair serial-contains 'dialpair: data one'
vgate_assert dialpair serial-contains 'dialpair: data two'
vgate_assert dialpair serial-contains 'dialpair: done'
vgate_assert dialpair serial-absent 'dialpair: FAIL'
vgate_assert dialpair serial-absent '[EXC] parking:'
vgate_assert dialpair python <<'PY'
import os, re, struct, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Four opens, four DISTINCT table handles — the per-handle proof.
handles = re.findall(r"dialpair: open h=(\d+)", ser)
assert len(handles) == 4 and len(set(handles)) == 4, handles
# netstat's diff-log named the owning pid for every live conn: at least
# two sock rows for the SAME pid carrying the 8080 remote endpoint.
sock = re.findall(r"netstat: sock pid=(\d+) tcp .* -> 10\.0\.0\.2:8080", ser)
assert len(sock) >= 2 and len(set(sock)) == 1, sock
# The wire walk: guest-initiated frames to 10.0.0.2:8080 — four SYNs from
# four distinct source ports, at least two carrying data, lifecycles
# overlapping in ONE capture (a singleton dial path cannot emit the
# second SYN while the first connection still sends).
data = open(os.environ["RUN_DIR"] + "/dialpair.bin", "rb").read()
frames = []
i = 0
while i < len(data):
    if data[i+12:i+14] == b"\x08\x06":
        i += 42
        continue
    assert data[i+12:i+14] == b"\x08\x00", "unexpected capture frame"
    size = 14 + struct.unpack_from("!H", data, i + 16)[0]
    frames.append(data[i:i+size])
    i += size
conns = {}
for idx, f in enumerate(frames):
    if f[23] != 6 or f[26:30] != bytes([10, 0, 0, 1]):
        continue
    sp = (f[34] << 8) | f[35]
    dp = (f[36] << 8) | f[37]
    if dp != 8080:
        continue
    conns.setdefault(sp, []).append((idx, f[47], len(f) - 54))
syns = {sp: segs for sp, segs in conns.items() if any(fl == 0x02 for _, fl, _ in segs)}
assert len(syns) == 4, "expected 4 distinct guest source ports, got %r" % list(syns)
data_ports = [sp for sp, segs in conns.items() if any(n > 0 for _, _, n in segs)]
assert len(data_ports) >= 2, "fewer than two conns carried data: %r" % data_ports
a, b = data_ports[0], data_ports[1]
assert conns[a][0][0] < conns[b][-1][0] and conns[b][0][0] < conns[a][-1][0], (
    "connection windows did not overlap")
print("dialpair ok: 4 concurrent dials (%s), 5th ErrConnBusy, netstat pid=%s, data on %s"
      % (sorted(syns), sock[0], sorted(data_ports)))
PY

# --- M95 prerequisite #2029: stdlib `net` on GOOS=virelai ---------------
# The package compiles for in-process IPC only: net.Pipe is a real Conn
# pair (channel plumbing, no netFD), while every path that would need a
# kernel socket — dial, listen, DNS, interface enumeration — refuses with
# a named error. GOPIPE.ELF is pure stdlib: no `virelai/vi` socket seam,
# so a pass proves the std `net` port itself, not the SDK. The run arms
# no network attachment on purpose: in-process IPC needs no peer.

vgate_file gonetpipe.go <<'EOF'
package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"
)

var failed bool

func fail(s string) {
	fmt.Println("gonetpipe: FAIL " + s)
	failed = true
}

// expectRefusal pins the contract this port sells: every path that would
// need a kernel socket refuses with a named error (ENOSYS renders as
// "function not implemented"), never a silent success and never a lie.
func expectRefusal(what string, err error) {
	switch {
	case err == nil:
		fail(what + " succeeded")
	case !strings.Contains(err.Error(), "not implemented"):
		fail(what + " refused with an unnamed error: " + err.Error())
	default:
		fmt.Println("gonetpipe: refused " + what + ": " + err.Error())
	}
}

func main() {
	fmt.Println("gonetpipe: start")

	// The in-process proof: net.Pipe is a synchronous Conn pair over
	// channels — no netFD, no socket — so it is the one std transport
	// this port can run.
	c1, c2 := net.Pipe()
	go func() {
		buf := make([]byte, 64)
		for {
			n, err := c1.Read(buf)
			if err != nil {
				return
			}
			if _, err := c1.Write(buf[:n]); err != nil {
				return
			}
		}
	}()

	msg := []byte("net29-pipe-echo")
	if n, err := c2.Write(msg); err != nil || n != len(msg) {
		fail(fmt.Sprintf("pipe write n=%d err=%v", n, err))
	}
	buf := make([]byte, 64)
	c2.SetReadDeadline(time.Now().Add(5 * time.Second))
	if n, err := c2.Read(buf); err != nil || string(buf[:n]) != string(msg) {
		fail(fmt.Sprintf("pipe echo n=%d err=%v got=%q", n, err, buf[:n]))
	} else {
		fmt.Println("gonetpipe: pipe roundtrip ok")
	}

	// Deadline honesty: a read with nothing to read must expire, and the
	// error must report Timeout() — not a socket refusal.
	c2.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	if _, err := c2.Read(buf); err == nil {
		fail("pipe deadline read succeeded")
	} else if te, ok := err.(net.Error); !ok || !te.Timeout() {
		fail("pipe deadline error is not a timeout: " + err.Error())
	} else {
		fmt.Println("gonetpipe: deadline ok")
	}
	c2.SetReadDeadline(time.Time{})

	// Close honesty: after c1.Close the peer sees ErrClosedPipe on write
	// and io.EOF on read — the stock pipe semantics, unmodified.
	if err := c1.Close(); err != nil {
		fail("pipe close: " + err.Error())
	}
	if _, err := c2.Write([]byte("x")); !errors.Is(err, io.ErrClosedPipe) {
		fail(fmt.Sprintf("pipe write after peer close err=%v", err))
	} else {
		fmt.Println("gonetpipe: close ok")
	}
	c2.Close()

	// The refusal half of the port: external operations refuse with a
	// named error. Nothing below touches a device — there is none armed.
	_, err := net.Dial("tcp", "127.0.0.1:1")
	expectRefusal("dial-tcp", err)
	_, err = net.Listen("tcp", "127.0.0.1:0")
	expectRefusal("listen-tcp", err)
	_, err = net.Listen("unix", "/tmp/gonetpipe.sock")
	expectRefusal("listen-unix", err)
	_, err = net.ListenPacket("udp", "127.0.0.1:0")
	expectRefusal("listen-udp", err)
	_, err = net.Dial("unix", "/tmp/gonetpipe.sock")
	expectRefusal("dial-unix", err)
	_, err = net.LookupHost("gonetpipe.invalid")
	expectRefusal("lookup", err)
	_, err = net.Interfaces()
	expectRefusal("interfaces", err)
	_, err = net.InterfaceAddrs()
	expectRefusal("interface-addrs", err)

	if failed {
		fmt.Println("gonetpipe: FAILED")
		os.Exit(1)
	}
	fmt.Println("gonetpipe: done")
	os.Exit(0)
}
EOF

vgate_file script-pipe.txt <<'EOF'
exec GOPIPE.ELF
EOF

vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
env = dict(os.environ, GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="GOPIPE", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "gonetpipe.go")], env=env, check=True)
PY

vgate_run pipe -- --script '$RUN_DIR/script-pipe.txt' --script-expect 'gonetpipe: done' --timeout 120

vgate_assert pipe serial-contains 'gonetpipe: start'
vgate_assert pipe serial-contains 'gonetpipe: pipe roundtrip ok'
vgate_assert pipe serial-contains 'gonetpipe: deadline ok'
vgate_assert pipe serial-contains 'gonetpipe: close ok'
vgate_assert pipe serial-contains 'gonetpipe: refused dial-tcp'
vgate_assert pipe serial-contains 'gonetpipe: refused listen-tcp'
vgate_assert pipe serial-contains 'gonetpipe: refused listen-unix'
vgate_assert pipe serial-contains 'gonetpipe: refused listen-udp'
vgate_assert pipe serial-contains 'gonetpipe: refused dial-unix'
vgate_assert pipe serial-contains 'gonetpipe: refused lookup'
vgate_assert pipe serial-contains 'gonetpipe: refused interfaces'
vgate_assert pipe serial-contains 'gonetpipe: refused interface-addrs'
vgate_assert pipe serial-absent 'gonetpipe: FAIL'
vgate_assert pipe serial-absent '[EXC] parking:'

# --- M117c (#2475, ADR 0057): the v6 transport legs -----------------------
# UDP/IPv6 echo + TCP/IPv6 connect through the hermetic peer. The guest's
# global forms from the RA's PIO + the EUI-64 IID ('net: v6 g6=... valid'
# gates script2 — a connect before SLAAC settles would refuse no_src6),
# the peer resolves through --net-ndp-respond, and the legs are:
#   * `net udp6 listen/send/recv` — the monitor's own v6 datagram drive;
#   * GOCONNECT6.ELF — `vi.Dial` on the BRACKETED v6 literal, then
#     GET/200/close on the TCP6 responder;
#   * GOPING.ELF on a bare v6 literal — the ping6 marshal (slots 59/60
#     with the family tag).
# HOST PREREQUISITE beyond the listed ones:
#   bash tools/go/build-goping.sh -> .build/go/GOPING.ELF

vgate_file connect6.go <<'EOF'
package main

import (
    "time"
    "virelai/vi"
    "virelai/vsys"
)

func fail(s string) {
    vsys.Println("net6connect: FAIL " + s)
    vsys.Exit(1)
}

func main() {
    // M117c (#2475): the bracketed v6 literal — the tagged op-10 marshal.
    vsys.Println("net6connect: dialing [2001:db8:64::ff:fe00:2]:8080")
    c, err := vi.DialTimeout("[2001:db8:64::ff:fe00:2]", 8080, 5*time.Second)
    if err != nil { fail("dial " + err.Error()) }
    if !c.IsV6() { fail("conn not family v6") }
    vsys.Println("net6connect: connected")
    if _, err = c.Send([]byte("GET / HTTP/1.0\r\n\r\n")); err != nil { fail("send") }
    c.SetRecvDeadline(5_000_000_000)
    buf := make([]byte, vi.TCPPayloadMax)
    n, err := c.Recv(buf)
    if err != nil || n < 15 || string(buf[:15]) != "HTTP/1.0 200 OK" { fail("GET response") }
    if err = c.Close(); err != nil { fail("close") }
    vsys.Println("net6connect: GET and close ok")
    vsys.Println("net6connect: done")
    vsys.Exit(0)
}
EOF

vgate_file script-v6-ready.txt <<'EOF'
echo v6-ready
EOF

vgate_file script-v6.txt <<'EOF'
net ndp 2001:db8:64::ff:fe00:2
net ip6
net ndp 2001:db8:64::ff:fe00:2
net udp6 listen 7000
net udp6 send 2001:db8:64::ff:fe00:2 5555 4
net udp6 recv 7000
exec GOCONNECT6.ELF
exec GOPING.ELF -c 2 2001:db8:64::ff:fe00:2
echo v6-transport-ok
EOF

vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "connect-build"
tmp.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="GOCONNECT6", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "connect6.go")], env=env, check=True)
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOPING.ELF")
if not os.path.exists(src):
    sys.exit("GOPING.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goping.sh")
shutil.copy(src, os.path.join(share, "GOPING.ELF"))
print("staged GOPING.ELF (%d bytes)" % os.path.getsize(src))
PY

# Run v6 -- the hermetic v6 fleet: the RA arms SLAAC, the NDP responder
# resolves the peer, then the UDP echo, the TCP6 connect and the ping6
# legs all land on the same peer.
vgate_run v6 -- --net '$RUN_DIR/v6.bin' \
    --net-ra-respond '2001:db8:64::/64' \
    --net-ndp-respond '2001:db8:64::ff:fe00:2' \
    --net-icmp6-respond '2001:db8:64::ff:fe00:2' \
    --net-udp6-respond '[2001:db8:64::ff:fe00:2]:5555' \
    --net-tcp6-respond '[2001:db8:64::ff:fe00:2]:8080' \
    --script '$RUN_DIR/script-v6-ready.txt' \
    --script2 '$RUN_DIR/script-v6.txt' --script2-after 'net: v6 g6=2001:db8:64::ff:fe00:1 valid' \
    --script-expect 'v6-transport-ok' --timeout 120

vgate_assert v6 output-contains 'net-ra-respond: ENABLED'
vgate_assert v6 output-contains 'net-udp6-respond: ENABLED'
vgate_assert v6 output-contains 'net-tcp6-respond: ENABLED'
vgate_assert v6 serial-contains 'net: v6 g6=2001:db8:64::ff:fe00:1 valid'
vgate_assert v6 serial-contains 'net ndp: 2001:db8:64::ff:fe00:2 is at 02:00:00:00:00:02'
vgate_assert v6 serial-contains 'net udp6: listening on 7000'
vgate_assert v6 serial-contains 'net udp6: sent 4 bytes to 2001:db8:64::ff:fe00:2:5555'
vgate_assert v6 serial-contains 'net udp6 recv: [0] len=4'
vgate_assert v6 serial-contains 'net udp6 recv: 01 02 03 04'
vgate_assert v6 serial-contains 'net6connect: connected'
vgate_assert v6 serial-contains 'net6connect: GET and close ok'
vgate_assert v6 serial-contains 'net6connect: done'
vgate_assert v6 serial-contains 'PING6 2001:db8:64::ff:fe00:2'
vgate_assert v6 serial-contains '2 packets received, 0% packet loss'
vgate_assert v6 serial-contains 'v6-transport-ok'
vgate_assert v6 serial-absent 'net6connect: FAIL'
vgate_assert v6 serial-absent '[EXC] parking:'
vgate_assert v6 output-contains 'NET-UDP6: answered'
vgate_assert v6 output-contains 'NET-TCP6: answered'
vgate_assert v6 output-contains 'NET-ICMP6: answered'
# The wire walk: the capture carries the guest's frames only — every
# 0x86dd frame either the autonomous SLAAC/NDP traffic or the legs'
# UDP/TCP/echo frames. The UDP datagram's pseudo-header checksum and the
# SYN's are recomputed here — a corrupt one could not have been answered.
vgate_assert v6 python <<'PY'
import os, struct
data = open(os.environ["RUN_DIR"] + "/v6.bin", "rb").read()
PEER = bytes([0x20,0x01,0x0d,0xb8,0,0x64,0,0,0,0,0,0xff,0xfe,0,0,2])
G6 = bytes([0x20,0x01,0x0d,0xb8,0,0x64,0,0,0,0,0,0xff,0xfe,0,0,1])

def cksum6(src, dst, msg, nh):
    s = 0
    for i in range(0, 16, 2):
        s += (src[i] << 8) | src[i + 1]
        s += (dst[i] << 8) | dst[i + 1]
    s += (len(msg) >> 16) + (len(msg) & 0xffff) + nh
    i = 0
    while i + 1 < len(msg):
        s += (msg[i] << 8) | msg[i + 1]
        i += 2
    if i < len(msg):
        s += msg[i] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff

v6frames, udps, tcps, echo6 = [], [], [], []
i = 0
while i < len(data):
    et = data[i+12:i+14]
    if et == b"\x08\x06":
        i += 42
        continue
    if et == b"\x08\x00":
        size = 14 + struct.unpack_from("!H", data, i+16)[0]
        i += size
        continue
    assert et == b"\x86\xdd", "unexpected capture frame"
    size = 14 + 40 + struct.unpack_from("!H", data, i+18)[0]
    v6frames.append(data[i:i+size])
    i += size
for f in v6frames:
    nh = f[20]
    src, dst = f[22:38], f[38:54]
    plen = struct.unpack_from("!H", f, 18)[0]
    msg = f[54:14+40+plen]
    # The transport checksum field verifies to 0xffff -> recomputed sum is 0.
    if nh == 17:
        udps.append(f)
        assert src == G6 and dst == PEER, "UDP6 datagram wrong endpoints"
        assert (f[56] << 8) | f[57] == 5555, "UDP6 datagram wrong dst port"
        assert cksum6(src, dst, msg, 17) == 0, "UDP6 pseudo-header checksum invalid"
    elif nh == 6:
        tcps.append(f)
        assert src == G6 and dst == PEER, "TCP6 segment wrong endpoints"
        assert (f[56] << 8) | f[57] == 8080, "TCP6 segment wrong dst port"
        assert cksum6(src, dst, msg, 6) == 0, "TCP6 pseudo-header checksum invalid"
    elif nh == 58 and f[54] == 128:
        echo6.append(f)
        assert cksum6(src, dst, msg, 58) == 0, "ICMPv6 echo checksum invalid"
assert udps, "no UDP/IPv6 datagram on the wire"
assert tcps, "no TCP/IPv6 segment on the wire"
assert any(f[67] == 2 for f in tcps), "no TCP6 SYN on the wire"
assert len(echo6) >= 2, "ping6 sent fewer than 2 echo requests"
print("v6 transport ok: %d v6 frames (%d UDP, %d TCP, %d echo), checksums verify" % (len(v6frames), len(udps), len(tcps), len(echo6)))
PY
