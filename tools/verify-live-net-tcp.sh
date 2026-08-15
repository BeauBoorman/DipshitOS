#!/usr/bin/env bash
#
# verify-live-net-tcp.sh -- claim 7026 (milestone five, card N10)
# class-B gate: the bounded RFC 793 TCP client live on real VZ hardware —
# the three-way handshake, the data echo round trip, the client-driven
# close, the reset, the bounded connect timeout, and the real-NAT
# observation.
#
# Mechanism: the guest's `net tcp` drives the bounded client ONE step
# per invocation (build + transmit on the N1 TX seam, the RX drain
# processes the peer's segments — the polled-drain contract). The
# runner's `--net-tcp-respond <host-ip>:<host-port>` is a tiny
# deterministic host-side TCP server in the capture thread: SYN ->
# SYN-ACK (the FIXED server ISN 0x12345678, ack = the guest's ISN+1),
# data -> ACK + the payload echoed byte-exact, FIN -> FIN-ACK. The
# file-handle attachment is deterministic end to end: all NINE guest-TX
# frames are byte-assertable in the capture.
#
# THREE runs, each ONE boot:
#   Run A — the full lifecycle (file-handle + responder): connect
#   (SYN) -> the handshake ACK -> established -> send 5 -> the echo ACK
#   -> `net tcp recv` prints 01 02 03 04 05 -> close (FIN) -> the
#   FIN-ACK -> the final ACK -> closed, then a SECOND connect -> `net
#   tcp` (established) -> `net tcp reset` (a real RST). Assertions: the
#   command lines, the report counters
#   (`tcp=closed,…,syn=2,synack=2,ack=4,data_s=1,data_r=1,fin=1,finack=1,rst_s=1,rst_r=0,timedout=0,mal=0`),
#   the fixed ack values (0x12345679 / 0x1234567e / 0x1234567f — the
#   fixed server ISN makes the ACK numbers deterministic), the host's
#   NET-TCP lines, and the capture's NINE-frame walk (a python check:
#   the seq/ack chain, the flags, the ports, the MACs, the payload, and
#   EVERY TCP checksum byte-exact).
#   Run B — the bounded connect timeout (file-handle, ARP responder
#   ONLY — the host answers ARP but never TCP, a deterministic black
#   hole): connect -> `tcp=syn_sent,syn=1,synack=0,timedout=0`, wait 31 s
#   (the card-N9 --script2-delay pattern) -> `net tcp` ->
#   `connect refused (no SYN-ACK after 30s)` -> `tcp=idle,peer=0.0.0.0:0,
#   timedout=1`.
#   Run C — the real-NAT observation (rides card N7's --net-nat): the
#   guest connects to the NAT gateway 192.168.64.1:9999. CLAIM-TIME
#   OBSERVATION, honestly recorded: the VZ NAT gateway on this host
#   answers the SYN with a RST (no TCP listener on the test port —
#   connection refused), so the client's RST-RX path fires
#   (`rst_r=1`, `tcp=closed`, then the drive returns it to idle). Never
#   faked; if a future host's NAT gateway instead drops the SYN
#   silently, the honest timeout path fires (`timedout=1` — the
#   assertion set below documents where to flip).
#
# The FULL 38-gate verify-vz aggregate must stay green (re-run
# separately); the N8/N9 gates re-run green — the tcp= line APPENDS at
# the end of the report, so their substring assertions hold. Evidence
# under artifacts/: live-net-tcp-*.txt (runner output),
# live-net-tcp-*.log (serial copies), live-net-tcp-*.bin (host captures).
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-net-tcp.sh
#
# Evidence: artifacts/live-net-tcp-gate.txt (full output),
# artifacts/live-net-tcp-report.txt (per-run detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-net-tcp-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-net-tcp-report.txt"

echo "=== verify-live-net-tcp: claim 7026 — the bounded RFC 793 TCP client live on VZ (Run A full lifecycle + reset, Run B the bounded connect timeout, Run C the real-NAT observation) ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted keystrokes ----------------------------------------------------
# Run A: the full lifecycle. `net arp 10.0.0.2` (twice) resolves the
# peer; `net tcp connect` drains first (the ARP reply learned), transmits
# the SYN; `net tcp` drains the SYN-ACK + transmits the handshake ACK;
# `net tcp send 5` transmits the data; `net tcp` drains the echo +
# transmits the ACK for it; `net tcp recv` prints the echoed payload;
# `net tcp close` transmits the FIN; `net tcp` drains the FIN-ACK +
# transmits the final ACK (back to idle); the SECOND connect + `net tcp`
# establish again; `net tcp reset` transmits the RST (the client's
# abort). The final `net` reads the counters. No delays — every step is
# request-driven (the runner's forward settle is plenty).
cat > artifacts/live-net-tcp-a1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp
net tcp connect 10.0.0.2 9999
net tcp
net tcp send 5
net tcp
net tcp recv
net tcp close
net tcp
net tcp connect 10.0.0.2 9999
net tcp
net tcp reset
net
echo n10a-done
EOF
# Run B: the bounded connect timeout. The host answers ARP but NEVER TCP
# (no --net-tcp-respond — a deterministic black hole): connect -> syn_sent,
# the 31 s script2 delay passes the 30 s timeout, `net tcp` refuses
# honestly, `net` reads `timedout=1`.
cat > artifacts/live-net-tcp-b1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp
net tcp connect 10.0.0.2 9999
net
echo n10b-phase1-ready
EOF
cat > artifacts/live-net-tcp-b2.txt <<'EOF'
net tcp
net
echo n10b-done
EOF
# Run C: the real-NAT observation. The guest connects to the NAT gateway
# 192.168.64.1:9999; the gateway's answer (RST or silence) is the
# claim-time observation. The `net` report after the connect + the drive
# + the final report capture the client's honest response.
cat > artifacts/live-net-tcp-c1.txt <<'EOF'
net ip 192.168.64.5
net arp 192.168.64.1
net arp
net tcp connect 192.168.64.1 9999
net
net tcp
net
echo n10c-done
EOF

# --- per-run gate ------------------------------------------------------------
# Run A (the full lifecycle + reset): $1 = runner output, $2 = serial
# copy, $3 = capture file.
run_a() {
    local out="$1" serial="$2" capture="$3"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log "$capture"
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --net "$capture" --net-tcp-respond 10.0.0.2:9999 --net-arp-respond 10.0.0.2 \
        --script artifacts/live-net-tcp-a1.txt \
        --script-expect $'n10a-done\ndipshit> ' --timeout 120 \
        > "$out" 2>&1
    local RC=$?
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial" || true
    echo "$RC" > /tmp/live-net-tcp-rc-a.txt
}

# Run B (the bounded connect timeout): same shape, ARP responder only.
run_b() {
    local out="$1" serial="$2" capture="$3"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log "$capture"
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --net "$capture" --net-arp-respond 10.0.0.2 \
        --script artifacts/live-net-tcp-b1.txt \
        --script2 artifacts/live-net-tcp-b2.txt --script2-after "n10b-phase1-ready" --script2-delay 31 \
        --script-expect $'n10b-done\ndipshit> ' --timeout 140 \
        > "$out" 2>&1
    local RC=$?
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial" || true
    echo "$RC" > /tmp/live-net-tcp-rc-b.txt
}

# Run C (the real-NAT observation): rides --net-nat; no capture file.
run_c() {
    local out="$1" serial="$2"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --net-nat \
        --script artifacts/live-net-tcp-c1.txt \
        --script-expect $'n10c-done\ndipshit> ' --timeout 120 \
        > "$out" 2>&1
    local RC=$?
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial" || true
    echo "$RC" > /tmp/live-net-tcp-rc-c.txt
}

set +e
run_a "artifacts/live-net-tcp-a-run.txt" "artifacts/live-net-tcp-a-serial.log" "artifacts/live-net-tcp-a-cap.bin"
RCA="$(cat /tmp/live-net-tcp-rc-a.txt)"
run_b "artifacts/live-net-tcp-b-run.txt" "artifacts/live-net-tcp-b-serial.log" "artifacts/live-net-tcp-b-cap.bin"
RCB="$(cat /tmp/live-net-tcp-rc-b.txt)"
run_c "artifacts/live-net-tcp-c-run.txt" "artifacts/live-net-tcp-c-serial.log"
RCC="$(cat /tmp/live-net-tcp-rc-c.txt)"
set -e

# --- Run A assertions ---------------------------------------------------------
SA="artifacts/live-net-tcp-a-serial.log"
SA_BYTES=0 ASYN=0 AACK=0 AESTSENT=0 ADATASENT=0 AECHOACK=0 ARECV=0 AFIN=0 AFINALACK=0 ACLOSED=0 ASYN2=0 ARESET=0 ACOUNTERS=0 ADONE=0
if [ -f "$SA" ]; then
    SA_BYTES=$(wc -c < "$SA" | tr -d ' ')
    # The handshake + data + close + reset command lines. The ACK
    # numbers are DETERMINISTIC (the fixed server ISN 0x12345678).
    grep -a -qE -- "net tcp: syn sent \(peer=10\.0\.0\.2:9999, seq=0x[0-9a-f]+, 54 bytes\)" "$SA" && ASYN=1
    # TWO connects — the second syn line must be present (the capture's
    # 9-frame walk pins both SYNs byte-exact; this count cross-checks).
    [ "$(grep -ac -- 'net tcp: syn sent' "$SA")" -ge 2 ] && ASYN2=1
    grep -a -qF -- "net tcp: ack sent (ack=0x12345679, 54 bytes)" "$SA" && AACK=1
    grep -a -qF -- "net tcp: established (peer=10.0.0.2:9999)" "$SA" && AESTSENT=1
    grep -a -qE -- "net tcp: data sent \(seq=0x[0-9a-f]+, 5 bytes\)" "$SA" && ADATASENT=1
    grep -a -qF -- "net tcp: ack sent (ack=0x1234567e, 54 bytes)" "$SA" && AECHOACK=1
    grep -a -qF -- "net tcp recv: 01 02 03 04 05" "$SA" && ARECV=1
    grep -a -qE -- "net tcp: fin sent \(seq=0x[0-9a-f]+, 54 bytes\)" "$SA" && AFIN=1
    grep -a -qF -- "net tcp: final ack sent (ack=0x1234567f, 54 bytes)" "$SA" && AFINALACK=1
    grep -a -qF -- "net tcp: connection closed" "$SA" && ACLOSED=1

    grep -a -qE -- "net tcp: reset sent \(seq=0x[0-9a-f]+, 54 bytes\)" "$SA" && ARESET=1
    # The counters: two connects, one data round trip, one close, one reset.
    grep -a -qF -- "tcp=closed,peer=10.0.0.2:9999,syn=2,synack=2,ack=4,data_s=1,data_r=1,fin=1,finack=1,rst_s=1,rst_r=0,timedout=0,mal=0" "$SA" && ACOUNTERS=1
    grep -a -qF -- "n10a-done" "$SA" && ADONE=1
fi
ARUNNER=0 ANETSYN=0 ANETDATA=0 ANETFIN=0
# The host answered from the capture thread (its own stdout lines).
grep -a -qF -- "NET-TCP: answered the guest's SYN (seq 0x" artifacts/live-net-tcp-a-run.txt && ANETSYN=1
grep -a -qF -- "NET-TCP: echoed the guest's 5-byte data" artifacts/live-net-tcp-a-run.txt && ANETDATA=1
grep -a -qF -- "NET-TCP: answered the guest's FIN" artifacts/live-net-tcp-a-run.txt && ANETFIN=1
grep -a -qF -- "net-tcp-respond: ENABLED (milestone five card N10, claim 7026)" artifacts/live-net-tcp-a-run.txt && ARUNNER=1
# The capture: ARP (42) + NINE TCP frames (54+54+59+54+54+54+54+54+54 =
# 491) = 533 bytes, verified by the python walk (the seq/ack chain, the
# flags, the ports, the MACs, the payload, and every TCP checksum).
ACAP=0
if [ -f artifacts/live-net-tcp-a-cap.bin ] && [ "$(wc -c < artifacts/live-net-tcp-a-cap.bin | tr -d ' ')" = 533 ]; then
    if python3 - artifacts/live-net-tcp-a-cap.bin <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
off = 0
tcpf = []
while off < len(d):
    if d[off+12:off+14] == b'\x08\x00':
        total = (d[off+16] << 8) | d[off+17]
        flen = 14 + total
        tcpf.append(d[off:off+flen])
        off += flen
    else:
        off += 42  # the N3 unpadded ARP frame
assert len(tcpf) == 9, len(tcpf)
assert [len(f) for f in tcpf] == [54, 54, 59, 54, 54, 54, 54, 54, 54], [len(f) for f in tcpf]
def be32(b): return struct.unpack('>I', b)[0]
def chk(data):
    if len(data) % 2: data += b'\x00'
    s = sum(struct.unpack('>%dH' % (len(data) // 2), data))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
SRV_ISN = 0x12345678
syn = tcpf[0]
synseq = be32(syn[38:42])
assert syn[47] == 0x02 and syn[42:46] == b'\x00' * 4, "syn flags/ack"
assert (syn[34] << 8) | syn[35] == 8000 and (syn[36] << 8) | syn[37] == 9999, "syn ports"
assert syn[30:34] == bytes([10, 0, 0, 2]), "syn dst ip"
assert syn[0:6] == bytes([2, 0, 0, 0, 0, 2]) and syn[6:12] == bytes([2, 0, 0, 0, 0, 1]), "syn macs"
assert syn[46] == 0x50 and syn[48:50] == bytes([0x10, 0x00]), "syn offset/window"
assert chk(syn[14:34]) == 0, "syn ipv4 checksum"
for i, f in enumerate(tcpf):
    seg = f[34:]
    ps = bytes([10, 0, 0, 1, 10, 0, 0, 2, 0, 6]) + struct.pack('>H', len(seg))
    assert chk(ps + seg) == 0, ("tcp checksum", i)
ack1 = tcpf[1]
assert ack1[47] == 0x10 and be32(ack1[38:42]) == (synseq + 1) & 0xffffffff and be32(ack1[42:46]) == (SRV_ISN + 1) & 0xffffffff, "handshake ack"
data = tcpf[2]
assert data[47] == 0x10 and data[54:59] == bytes([1, 2, 3, 4, 5]) and be32(data[38:42]) == (synseq + 1) & 0xffffffff and be32(data[42:46]) == (SRV_ISN + 1) & 0xffffffff, "data"
ack2 = tcpf[3]
assert ack2[47] == 0x10 and be32(ack2[42:46]) == (SRV_ISN + 6) & 0xffffffff, "echo ack"
fin = tcpf[4]
assert fin[47] == 0x11 and be32(fin[38:42]) == (synseq + 6) & 0xffffffff and be32(fin[42:46]) == (SRV_ISN + 6) & 0xffffffff, "fin"
fack = tcpf[5]
assert fack[47] == 0x10 and be32(fack[38:42]) == (synseq + 7) & 0xffffffff and be32(fack[42:46]) == (SRV_ISN + 7) & 0xffffffff, "final ack"
syn2 = tcpf[6]
syn2seq = be32(syn2[38:42])
assert syn2[47] == 0x02 and syn2[42:46] == b'\x00' * 4 and syn2seq != synseq, "second syn"
ack3 = tcpf[7]
assert ack3[47] == 0x10 and be32(ack3[38:42]) == (syn2seq + 1) & 0xffffffff and be32(ack3[42:46]) == (SRV_ISN + 1) & 0xffffffff, "second handshake ack"
rst = tcpf[8]
assert rst[47] == 0x14 and be32(rst[38:42]) == (syn2seq + 1) & 0xffffffff, "reset"
print("Run A capture: the 9-frame seq/ack chain, flags, payload, MACs, ports, and checksums byte-exact")
PY
    then
        ACAP=1
    fi
fi

# --- Run B assertions (the bounded connect timeout) ---------------------------
SB="artifacts/live-net-tcp-b-serial.log"
SB_BYTES=0 BSYN=0 BSYNREPORT=0 BREFUSED=0 BTIMEDOUT=0 BDONE=0
if [ -f "$SB" ]; then
    SB_BYTES=$(wc -c < "$SB" | tr -d ' ')
    grep -a -qE -- "net tcp: syn sent \(peer=10\.0\.0\.2:9999, seq=0x[0-9a-f]+, 54 bytes\)" "$SB" && BSYN=1
    # The SYN went out and NO SYN-ACK answered (the host never answers
    # TCP in this run) — the report before the timeout shows it.
    grep -a -qF -- "tcp=syn_sent,peer=10.0.0.2:9999,syn=1,synack=0,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=0,mal=0" "$SB" && BSYNREPORT=1
    # The 30 s connect timeout refused honestly.
    grep -a -qF -- "error: net tcp: connect refused (no SYN-ACK after 30s) — run 'net tcp connect <addr> <port>' to retry" "$SB" && BREFUSED=1
    grep -a -qF -- "tcp=idle,peer=0.0.0.0:0,syn=1,synack=0,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=0,timedout=1,mal=0" "$SB" && BTIMEDOUT=1
    grep -a -qF -- "n10b-done" "$SB" && BDONE=1
fi
BRUNNER=0
[ "$RCB" = 0 ] && grep -a -qF -- "net-arp-respond: ENABLED" artifacts/live-net-tcp-b-run.txt && BRUNNER=1

# --- Run C assertions (the real-NAT observation) ------------------------------
SC="artifacts/live-net-tcp-c-serial.log"
SC_BYTES=0 CGWMAC=0 CSYN=0 CRST=0 CIDLE=0 CDONE=0
if [ -f "$SC" ]; then
    SC_BYTES=$(wc -c < "$SC" | tr -d ' ')
    # The real NAT gateway's MAC was learned through the attachment.
    grep -a -qE -- "net arp: 192\.168\.64\.1 -> " "$SC" && CGWMAC=1
    grep -a -qE -- "net tcp: syn sent \(peer=192\.168\.64\.1:9999, seq=0x[0-9a-f]+, 54 bytes\)" "$SC" && CSYN=1
    # THE CLAIM-TIME OBSERVATION: the VZ NAT gateway on this host
    # answers the SYN with a RST (no TCP listener on 192.168.64.1:9999 —
    # connection refused), so the client's RST-RX path fired. If a
    # future host's NAT silently drops instead, this assertion flips to
    # the timedout=1 report (the honest path is proven by Run B).
    grep -a -qF -- "tcp=closed,peer=192.168.64.1:9999,syn=1,synack=0,ack=0,data_s=0,data_r=0,fin=0,finack=0,rst_s=0,rst_r=1,timedout=0,mal=0" "$SC" && CRST=1
    grep -a -qF -- "net tcp: connection closed — idle again" "$SC" && CIDLE=1
    grep -a -qF -- "n10c-done" "$SC" && CDONE=1
fi
CRUNNER=0
[ "$RCC" = 0 ] && grep -a -qF -- "net-nat: ENABLED (milestone five card N7, claim 4678)" artifacts/live-net-tcp-c-run.txt && CRUNNER=1

# --- tally --------------------------------------------------------------------
PASS=0 FAIL=0
tally() {
    local name="$1" ok="$2"
    if [ "$ok" = 1 ]; then
        PASS=$((PASS + 1))
        echo "PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name"
    fi
}

echo
echo "=== Run A (the full lifecycle + reset) ==="
tally "runner rc" "$([ "$RCA" = 0 ] && echo 1 || echo 0)"
tally "serial log present ($SA_BYTES bytes)" "$([ "$SA_BYTES" -gt 1000 ] && echo 1 || echo 0)"
tally "syn sent" "$ASYN"
tally "handshake ack (ack=0x12345679)" "$AACK"
tally "established" "$AESTSENT"
tally "data sent (5 bytes)" "$ADATASENT"
tally "echo ack (ack=0x1234567e)" "$AECHOACK"
tally "recv prints 01 02 03 04 05" "$ARECV"
tally "fin sent" "$AFIN"
tally "final ack (ack=0x1234567f)" "$AFINALACK"
tally "connection closed" "$ACLOSED"
tally "second syn" "$ASYN2"
tally "reset sent" "$ARESET"
tally "counters syn=2,synack=2,ack=4,data_s=1,data_r=1,fin=1,finack=1,rst_s=1,rst_r=0,timedout=0,mal=0" "$ACOUNTERS"
tally "runner flag line" "$ARUNNER"
tally "host SYN-ACK line" "$ANETSYN"
tally "host data-echo line" "$ANETDATA"
tally "host FIN-ACK line" "$ANETFIN"
tally "capture 533 bytes + 9-frame byte-exact walk" "$ACAP"
tally "n10a-done marker" "$ADONE"

echo
echo "=== Run B (the bounded connect timeout) ==="
tally "runner rc" "$([ "$RCB" = 0 ] && echo 1 || echo 0)"
tally "serial log present ($SB_BYTES bytes)" "$([ "$SB_BYTES" -gt 1000 ] && echo 1 || echo 0)"
tally "syn sent" "$BSYN"
tally "report tcp=syn_sent,syn=1,synack=0,timedout=0" "$BSYNREPORT"
tally "connect refused (no SYN-ACK after 30s)" "$BREFUSED"
tally "report tcp=idle,peer=0.0.0.0:0,timedout=1" "$BTIMEDOUT"
tally "runner arp-respond flag" "$BRUNNER"
tally "n10b-done marker" "$BDONE"

echo
echo "=== Run C (the real-NAT observation) ==="
tally "runner rc" "$([ "$RCC" = 0 ] && echo 1 || echo 0)"
tally "serial log present ($SC_BYTES bytes)" "$([ "$SC_BYTES" -gt 1000 ] && echo 1 || echo 0)"
tally "real gateway MAC learned" "$CGWMAC"
tally "syn sent to 192.168.64.1:9999" "$CSYN"
tally "OBSERVED: NAT gateway RST'd the SYN (rst_r=1, tcp=closed)" "$CRST"
tally "drive returns the client to idle" "$CIDLE"
tally "runner nat flag" "$CRUNNER"
tally "n10c-done marker" "$CDONE"

echo
echo "=== verify-live-net-tcp: $PASS passed, $FAIL failed ==="
{
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "Run A rc=$RCA Run B rc=$RCB Run C rc=$RCC"
    echo "PASS=$PASS FAIL=$FAIL"
} > "$REPORT"
[ "$FAIL" = 0 ] || exit 1
echo "verify-live-net-tcp: PASS ($PASS/$PASS)"
