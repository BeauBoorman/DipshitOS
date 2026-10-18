# live-n5-dns.spec -- GODNS.ELF (exec'd) resolves through the host
# responder from EL0 and exits 0; M99i (#2187) adds the depth legs.
# M78a (#1682) retargets the existing RFC 1035/UDP behavior to Go.
# Mirrors tools/verify-live-n5-dns.sh (M26 N5, issue #403).
#
#   boot 01   basic A resolve (the pre-M99i leg, new output shape)
#   boot 02   AAAA + multi-answer: -6 answers 2001:db8::53, an A query
#             answers 3 records, TTL and ANCOUNT ride the Answer lines
#   boot 03   hostile wire: a forged-source reply and a corrupted-question
#             reply precede the real answer -> ignored=2, still resolved
#   boot 04   TC=1 reply -> explicit truncated refusal, exit 1, no fallback
#   boot 05   TTL cache: GODNS --twice answers the second resolve from the
#             per-process cache -> exactly ONE query on the wire
#   boot 06   TTL expiry + concurrent transactions: --twice --gap 8 with a
#             1-second server TTL re-queries (2 wire queries), then two
#             backgrounded GODNS processes resolve concurrently -> 2 more
#             queries, every transaction on its OWN ephemeral source port
#
# HOST PREREQUISITE: bash tools/go/build-netdiag.sh -> .build/go/GODNS.ELF

vgate_name live-n5-dns "GODNS.ELF resolution from EL0 on VZ (M99i depth)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec GODNS.ELF example.com 10.0.0.2
echo dns-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo dns-ok
EOF

vgate_file script-aaaa.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec GODNS.ELF -6 example.com 10.0.0.2
exec GODNS.ELF multi.example 10.0.0.2
EOF

vgate_file script-cache.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec GODNS.ELF --twice example.com 10.0.0.2
EOF

vgate_file script-expire.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec GODNS.ELF --twice --gap 8 expire.example 10.0.0.2
exec GODNS.ELF shared.example 10.0.0.2 &
exec GODNS.ELF shared.example 10.0.0.2 &
fg 1
fg 2
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GODNS.ELF")
if not os.path.exists(src):
    sys.exit("GODNS.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-netdiag.sh")
shutil.copy(src, os.path.join(share, "GODNS.ELF"))
print("staged GODNS.ELF (%d bytes)" % os.path.getsize(src))
PY

# --- boot 01: basic A resolve ----------------------------------------------
vgate_run 01 -- --net '$RUN_DIR/cap-01.bin' --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'dns: status=ok' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'DNS query for example.com (A) via 10.0.0.2:53'
vgate_assert 01 serial-contains 'Answer: example.com -> 93.184.216.34 (ttl=300s answers=1 ignored=0)'
vgate_assert 01 serial-contains 'dns: status=ok'
vgate_assert 01 serial-contains 'echo dns-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
if not re.search(r"net arp: (request for|resolved)", ser):
    sys.exit("FAIL: no ARP resolution line")
if not re.search(r"GODNS.ELF.*state=exited.*0|GODNS.ELF\s+exit=0x0000000000000000", ser):
    sys.exit("FAIL: no GODNS.ELF exit-0 row")
# The transaction's source port is ephemeral (M99i): the query on the wire
# must NOT come from the legacy fixed port 7000.
rd = os.environ["RUN_DIR"]
d = open(os.path.join(rd, "cap-01.bin"), "rb").read()
off, ports = 0, []
while off < len(d):
    if d[off+12:off+14] == b"\x08\x00":
        flen = 14 + ((d[off+16] << 8) | d[off+17])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 42 and f[23] == 17 and f[30:34] == bytes([10,0,0,2]) and f[36:38] == b"\x00\x35":
            ports.append((f[34] << 8) | f[35])
    elif d[off+12:off+14] == b"\x86\xdd":
        # M117b (#2474): NDP/ICMPv6 frames are legitimate capture traffic;
        # skip them by the v6 length decode (14 + 40 + payload_len).
        off += 14 + 40 + ((d[off+18] << 8) | d[off+19])
    else:
        off += 42
if len(ports) != 1:
    sys.exit("FAIL: want exactly 1 DNS query on the wire, saw %d" % len(ports))
if not 49152 <= ports[0] <= 65535:
    sys.exit("FAIL: query source port %d outside the ephemeral range" % ports[0])
print("dns arp + reap ok; ephemeral src port %d" % ports[0])
PY

# --- boot 02: AAAA + multi-answer ------------------------------------------
# The responder carries three pinned A records for every A query and the
# default 2001:db8::53 for AAAA; the CLI prints each usable answer and the
# transaction's ANCOUNT/TTL on the first line.
vgate_run 02 -- --net '$RUN_DIR/cap-02.bin' --net-arp-respond 10.0.0.2 \
    --net-dns-respond 10.0.0.2 \
    --net-dns-answer 93.184.216.34 --net-dns-answer 93.184.216.35 --net-dns-answer 93.184.216.36 \
    --net-dns-ttl 120 \
    --script '$RUN_DIR/script-aaaa.txt' --script-expect 'dns: status=ok' --script-expect-tail 8 --timeout 90

vgate_assert 02 serial-contains 'DNS query for example.com (AAAA) via 10.0.0.2:53'
vgate_assert 02 serial-contains 'Answer: example.com -> 2001:0db8:0000:0000:0000:0000:0000:0053 (ttl=120s answers=1 ignored=0)'
vgate_assert 02 serial-contains 'DNS query for multi.example (A) via 10.0.0.2:53'
vgate_assert 02 serial-contains 'Answer: multi.example -> 93.184.216.34 (ttl=120s answers=3 ignored=0)'
vgate_assert 02 serial-contains 'Answer: multi.example -> 93.184.216.35'
vgate_assert 02 serial-contains 'Answer: multi.example -> 93.184.216.36'
vgate_assert 02 serial-contains 'dns: status=ok'
vgate_assert 02 output-contains "NET-DNS: answered the guest's DNS query for 'example.com' qtype=28 ancount=1 ttl=120"
vgate_assert 02 output-contains "NET-DNS: answered the guest's DNS query for 'multi.example' qtype=1 ancount=3 ttl=120"

# --- boot 03: spoofed source + corrupted question are dropped ---------------
# The responder injects a reply forged from 10.0.0.9 and a reply whose
# echoed question is mangled BEFORE the real answer. The guest must consume
# and count both (ignored=2) and still accept the genuine reply.
vgate_run 03 -- --net '$RUN_DIR/cap-03.bin' --net-arp-respond 10.0.0.2 \
    --net-dns-respond 10.0.0.2 --net-dns-spoof --net-dns-wrong-question \
    --script '$RUN_DIR/script-1.txt' --script-expect 'dns: status=ok' --timeout 60

vgate_assert 03 serial-contains 'Answer: example.com -> 93.184.216.34 (ttl=300s answers=1 ignored=2)'
vgate_assert 03 serial-contains 'dns: status=ok'
vgate_assert 03 output-contains "NET-DNS: injected a reply forged from 10.0.0.9 for 'example.com'"
vgate_assert 03 output-contains "NET-DNS: injected a corrupted-question reply for 'example.com'"

# --- boot 04: TC=1 is refused, no fallback ----------------------------------
vgate_run 04 -- --net '$RUN_DIR/cap-04.bin' --net-arp-respond 10.0.0.2 \
    --net-dns-respond 10.0.0.2 --net-dns-truncate \
    --script '$RUN_DIR/script-1.txt' --script-expect 'dns: status=err' --timeout 60

vgate_assert 04 serial-contains 'dns: error: dns: reply truncated (TC=1) — no TCP fallback'
vgate_assert 04 serial-contains 'dns: status=err'
vgate_assert 04 serial-absent 'Answer: example.com'
vgate_assert 04 output-contains "NET-DNS: answered the guest's DNS query for 'example.com' qtype=1 with TC=1 ANCOUNT=0"

# --- boot 05: the TTL cache answers the second resolve ----------------------
# GODNS --twice resolves example.com twice in one process. The second result
# must be the cache entry (`cached`) — proven on the wire: exactly ONE DNS
# query leaves the guest, not two.
vgate_run 05 -- --net '$RUN_DIR/cap-05.bin' --net-arp-respond 10.0.0.2 \
    --net-dns-respond 10.0.0.2 \
    --script '$RUN_DIR/script-cache.txt' --script-expect 'dns: status=ok' --timeout 60

vgate_assert 05 serial-contains 'Answer: example.com -> 93.184.216.34 (ttl=300s answers=1 ignored=0)'
vgate_assert 05 serial-contains 'cached'
vgate_assert 05 serial-contains 'dns: status=ok'
vgate_assert 05 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
answers = re.findall(r"Answer: example\.com -> 93\.184\.216\.34 \(ttl=(\d+)s answers=1 ignored=0( cached)?\)", ser)
if len(answers) != 2:
    sys.exit("FAIL: want 2 Answer lines, saw %r" % (answers,))
if answers[0][1] != "" or answers[1][1] != " cached":
    sys.exit("FAIL: want first Answer wire-fresh, second cached: %r" % (answers,))
rd = os.environ["RUN_DIR"]
d = open(os.path.join(rd, "cap-05.bin"), "rb").read()
off, queries = 0, 0
while off < len(d):
    if d[off+12:off+14] == b"\x08\x00":
        flen = 14 + ((d[off+16] << 8) | d[off+17])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 42 and f[23] == 17 and f[30:34] == bytes([10,0,0,2]) and f[36:38] == b"\x00\x35":
            queries += 1
    elif d[off+12:off+14] == b"\x86\xdd":
        # M117b (#2474): NDP/ICMPv6 frames are legitimate capture traffic;
        # skip them by the v6 length decode (14 + 40 + payload_len).
        off += 14 + 40 + ((d[off+18] << 8) | d[off+19])
    else:
        off += 42
if queries != 1:
    sys.exit("FAIL: cache hit should mean exactly 1 wire query, saw %d" % queries)
print("cache ok: 2 Answers (second cached), 1 wire query")
PY

# --- boot 06: TTL expiry re-queries; concurrent processes get distinct ports
# Server TTL 1 clamps to the guest's 5 s floor; --gap 8 outlives it, so the
# second resolve MUST hit the wire again (2 queries for expire.example).
# Then two GODNS processes run concurrently (& is the shell's own job
# control) — each binds its own ephemeral port, so the wire shows two more
# queries and the four transactions use at least two distinct source ports.
# The SECOND `net arp` is not redundancy: exec spawns asynchronously and
# the script races to its end, so the request's reply must be drained
# into the table synchronously before any child can send (the monitor's
# own `net arp` drains first, then lookups — 'is at' proves the entry).
# The run ends on `fg`'s job-done line — guest-produced output, not a
# script echo — plus a 16 s tail: the expire process needs its ~12 s
# transaction (resolve + 8-tick gap + resolve) to finish inside the tail
# so all four queries and all Answer lines exist.
vgate_run 06 -- --net '$RUN_DIR/cap-06.bin' --net-arp-respond 10.0.0.2 \
    --net-dns-respond 10.0.0.2 --net-dns-ttl 1 \
    --script '$RUN_DIR/script-expire.txt' --script-expect 'Done: GODNS.ELF' --script-expect-tail 16 --timeout 120

vgate_assert 06 serial-contains 'DNS query for expire.example (A) via 10.0.0.2:53'
vgate_assert 06 serial-contains 'dns: status=ok'
vgate_assert 06 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Expiry: two Answer lines for expire.example, NEITHER cached.
exp_answers = re.findall(r"Answer: expire\.example -> 93\.184\.216\.34 \(ttl=5s answers=1 ignored=0( cached)?\)", ser)
if len(exp_answers) != 2 or any(c for c in exp_answers):
    sys.exit("FAIL: want 2 uncached expire.example Answers, saw %r" % (exp_answers,))
# Concurrent: two Answer lines for shared.example, each on its own
# transaction (the per-process cache cannot share between them).
shared = re.findall(r"Answer: shared\.example -> 93\.184\.216\.34 \(ttl=5s answers=1 ignored=0\)", ser)
if len(shared) != 2:
    sys.exit("FAIL: want 2 shared.example Answer lines, saw %d" % len(shared))
rd = os.environ["RUN_DIR"]
d = open(os.path.join(rd, "cap-06.bin"), "rb").read()
off, ports = 0, []
while off < len(d):
    if d[off+12:off+14] == b"\x08\x00":
        flen = 14 + ((d[off+16] << 8) | d[off+17])
        f = d[off:off+flen]
        off += flen
        if len(f) >= 42 and f[23] == 17 and f[30:34] == bytes([10,0,0,2]) and f[36:38] == b"\x00\x35":
            ports.append((f[34] << 8) | f[35])
    elif d[off+12:off+14] == b"\x86\xdd":
        # M117b (#2474): NDP/ICMPv6 frames are legitimate capture traffic;
        # skip them by the v6 length decode (14 + 40 + payload_len).
        off += 14 + 40 + ((d[off+18] << 8) | d[off+19])
    else:
        off += 42
if len(ports) != 4:
    sys.exit("FAIL: want 4 wire queries (expired re-resolve + 2 concurrent), saw %d" % len(ports))
for p in ports:
    if not 49152 <= p <= 65535:
        sys.exit("FAIL: query source port %d outside the ephemeral range" % p)
if len(set(ports)) < 2:
    sys.exit("FAIL: concurrent transactions drew identical source ports %r" % ports)
print("expiry+concurrent ok: 4 queries, ports %r" % (ports,))
PY
