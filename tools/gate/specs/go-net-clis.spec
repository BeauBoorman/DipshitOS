# go-net-clis.spec -- M71n (issue #1573) class-B gate: the Go net CLIs are
# reached BY TYPING THEM AT A GOSH PROMPT on a live network.
#
# The card's daily bar is "type a net verb in GOSH and get a Go program". Two
# things could be true while that bar is still unmet: the binaries exist but
# nothing names them (deliverable 1's `help` half, pinned by the host tests in
# user/go/sh -- TestHelpNamesTheNetCLIs), or GOSH cannot actually launch them
# over a real device. This spec is the second half, and it is the only place
# that runs: the exec goes through GOSH's OWN parser and RunExternal seam, so
# the marker below is GOSH's child's output, not the monitor's.
#
#   boot 01   GOSH (serial console) types `exec GOPING.ELF -c 3 10.0.0.2`
#             against the runner's ICMP responder  -> 3 round trips, exit 0
#   boot 02   GOSH types `exec GOFETCH.ELF https://10.0.0.2:24533/`
#             against the pinned TLS 1.3 fixture relayed to the guest
#             ->  `gofetch: handshake ok` / `gofetch: body complete`
#   boot 03   M83b (#1775): GOSH types `time sync 10.0.0.2`, `echo rc=$?` and
#             `date` against the runner's SNTP responder serving host time
#             +3600 s -> the guest clock is STEPPED an hour forward, exit 0,
#             and the next `date` reads the new clock
#   boot 04   M83b: the same three lines with NO responder -> one query on the
#             wire, `no reply ... clock untouched`, exit 1, and `date` still
#             reads the boot clock
#   boot 05   M83b: bare `time sync` (the default NAME) with no network at all
#             -> the live-net-offline sentence, `clock untouched`, exit 1, and
#             no DNS query attempted
#   boot 06   M99i (#2187): GOSH types `exec GODNS.ELF example.com 10.0.0.2`
#             against the runner's DNS responder -> the deep resolver's
#             Answer, `dns: status=ok`, one ephemeral-port wire query
#
# WHY THE CONSOLE SHELL AND NOT THE WINDOW: a windowed GOSH would need
# GOTABWM.ELF staged and a third live Go runtime (seat + shell + CLI), and
# go-sh.spec records that a THIRD SEQUENTIAL exec from one EL0 parent dies in
# the Go runtime's own schedinit. `GOSH.ELF serial` (ADR 0020 selector 1) is
# the same engine, the same parser and the same RunExternal, with only the
# monitor (Zig) as its parent -- so the two-Go-runtime envelope every
# go-* spec already proves holds here.
#
# WHY A NEW SPEC rather than a run in live-sh.spec: live-sh.spec owns the
# shell CORE (builtins, history, help) on a share with no network at all, and
# the two boots below need `--net` plus a device responder. The split keeps
# that spec's share pristine.
#
# WHAT PROVES THE EXEC CAME FROM GOSH, precisely, because the obvious reading
# is stronger than the wire supports: `exec: loaded <NAME>` is the MONITOR's
# line (kernel/src/monitor.zig cmd_exec) and an EL0 `sys_exec` does not print
# it. So the proof is a negative plus a positive:
#   * `exec: loaded GOPING.ELF` is ABSENT -- the monitor never ran it; and
#   * GOSH's own `gosh: line exec GOPING.ELF ...` submit record is present,
#     which only its line editor and parser produce; and
#   * the child's OWN output follows, ordered after that record.
# The monitor-side script contains neither the typed line nor the child's
# markers, so a boot in which GOSH never spawned the CLI cannot pass.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gosh.sh      ->  .build/go/GOSH.ELF
#   bash tools/go/build-goping.sh    ->  .build/go/GOPING.ELF
#   bash tools/go/build-netdiag.sh   ->  .build/go/GODNS.ELF
#   bash tools/go/build-web.sh fetch GOFETCH --gate -> .build/go/GOFETCH-GATE.ELF
#   (staged under the GOFETCH.ELF guest name; the gate build carries the
#   AutoClaw test root the boot-02 fixture chains to)

vgate_name go-net-clis "issue #1573 M71n: GOSH execs GOPING.ELF (ICMP) and GOFETCH.ELF (TLS) on a live VZ net"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Boot 01, phase 1: the monitor brings the interface up BEFORE the shell takes
# the console (GOSH's serial front-end owns the input once it attaches, so
# these two lines cannot be typed after it).
vgate_file net.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

# Boot 01, phase 2: hand the console to the shell.
vgate_file sh.txt <<'EOF'
exec GOSH.ELF serial
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, how in (("GOSH.ELF", "build-gosh.sh"),
                  ("GOPING.ELF", "build-goping.sh"),
                  ("GODNS.ELF", "build-netdiag.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
    print("staged %s (%d bytes)" % (name, os.path.getsize(src)))
# Boot 02's TLS fixture chains to the AutoClaw test root, which only the
# --gate build trusts (same staging live-web.spec uses).
gofetch = os.path.join(".build", "go", "GOFETCH-GATE.ELF")
if not os.path.exists(gofetch):
    sys.exit("GOFETCH.ELF missing (expected " + gofetch + ") - build it first: "
             "bash tools/go/build-web.sh fetch GOFETCH --gate")
shutil.copy(gofetch, os.path.join(share, "GOFETCH.ELF"))
print("staged GOFETCH.ELF (%d bytes)" % os.path.getsize(gofetch))
# The typed lines are raw console bytes (CR submits a line in GOSH's editor),
# so they are written here rather than as a heredoc.
with open(os.path.join(rd, "typed-ping.bin"), "wb") as f:
    f.write(b"exec GOPING.ELF -c 3 10.0.0.2\r")
with open(os.path.join(rd, "typed-fetch.bin"), "wb") as f:
    f.write(b"exec GOFETCH.ELF https://10.0.0.2:24533/\r")
with open(os.path.join(rd, "typed-dns.bin"), "wb") as f:
    f.write(b"exec GODNS.ELF example.com 10.0.0.2\recho rc=$?\r")
PY

# M83b (#1775): boots 03 and 04 type three lines in one burst. `time sync` is a
# GOSH builtin (no ELF to stage); the host wall clock at setup is the
# reference the served and set epochs are bounded against.
vgate_setup_python <<'PY'
import os, time
rd = os.environ["RUN_DIR"]
with open(os.path.join(rd, "host-epoch-start.txt"), "w") as f:
    f.write(str(time.time()))
with open(os.path.join(rd, "typed-sync.bin"), "wb") as f:
    f.write(b"time sync 10.0.0.2\recho rc=$?\rdate\r")
with open(os.path.join(rd, "typed-sync-default.bin"), "wb") as f:
    f.write(b"time sync\recho rc=$?\rdate\r")
PY

# The TLS 1.3 responder the Go shelf's own fixtures use (leaf.example.com,
# AutoClaw test CA), reached through the runner's :relay -- the recipe
# live-web.spec boot 12 pins.
vgate_setup_python <<'PY'
import os, subprocess, sys
rd = os.environ["RUN_DIR"]
cfx = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
chain = os.path.join(cfx, "chain-ec.pem")
if not os.path.exists(chain):
    sys.exit("pinned fixture chain missing at %s" % chain)
cmd = [
    sys.executable,
    os.path.join("user", "src", "lib", "tls", "vectors", "tlsresponder.py"),
    "--host", "127.0.0.1", "--port", "24533",
    "--cert", chain, "--key", os.path.join(cfx, "leaf-ec.key"),
    "--body", "go-net-clis-ok\n", "--accept", "2", "--timeout", "3600",
]
log = open(os.path.join(rd, "tlsresponder.log"), "wb")
proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
print("go-net-clis: tlsresponder pid=%d on 127.0.0.1:24533" % proc.pid)
PY

# --- boot 01: GOSH execs GOPING.ELF over the ICMP responder ----------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --net '$RUN_DIR/cap-01.bin' --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 \
    --script '$RUN_DIR/net.txt' \
    --script2 '$RUN_DIR/sh.txt' --script2-after 'net arp: ' \
    --script3 '$RUN_DIR/typed-ping.bin' --script3-after 'gosh: attached' \
    --script-expect 'ping statistics' --timeout 180

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
# The monitor did NOT run it (`exec: loaded` is the monitor's own line, see
# the header): this run cannot be satisfied by a monitor-script exec.
vgate_assert 01 serial-absent 'exec: loaded GOPING.ELF'
# ...and the child's own output. GOPING prints the header before the first
# send, so a header alone would prove only that it started; the statistics
# footer is printed after the last poll and cannot exist unless the ICMP
# round trip completed.
vgate_assert 01 serial-contains 'PING 10.0.0.2 (10.0.0.2): 56 data bytes'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=1'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=2'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=3'
vgate_assert 01 serial-contains '--- 10.0.0.2 ping statistics ---'
vgate_assert 01 serial-contains '3 packets transmitted, 3 packets received, 0% packet loss'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'fatal error: runtime:'
# The typed line is what the shell received: `exec ` is GOSH's own verb, and
# the printed markers are GOSH's `gosh: line ` submit record of it.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Anchored at line start, tolerant of a kernel log line spliced onto the
# tail (go-sh.spec observed that interleave); the reject case is a monitor
# line that merely CONTAINS the text, which starts with `gosh: line exec`
# only if the shell actually submitted it.
m = re.search(r"(?m)^gosh: line exec GOPING\.ELF -c 3 10\.0\.0\.2", ser)
if not m:
    sys.exit("FAIL: GOSH never recorded the typed `exec GOPING.ELF ...` line")
header = ser.find("PING 10.0.0.2 (10.0.0.2): 56 data bytes")
stats = ser.find("ping statistics")
if header < 0 or stats < 0 or not m.start() < header < stats:
    sys.exit("FAIL: order want typed(%d) < header(%d) < statistics(%d)"
             % (m.start(), header, stats))
print("go-net-clis 01 ok: GOSH exec'd GOPING.ELF, 3 replies, statistics, ordered")
PY

# --- boot 02: GOSH execs GOFETCH.ELF against the TLS fixture ---------------
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --net '$RUN_DIR/cap-02.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24533:relay --net-tcp-respond-relay 127.0.0.1:24533 \
    --script '$RUN_DIR/net.txt' \
    --script2 '$RUN_DIR/sh.txt' --script2-after 'net arp: ' \
    --script3 '$RUN_DIR/typed-fetch.bin' --script3-after 'gosh: attached' \
    --script-expect 'gofetch: ready' --timeout 240

vgate_assert 02 serial-contains 'gosh: ready'
vgate_assert 02 serial-contains 'gosh: attached'
# See run 01: the monitor's own load line is ABSENT, so the spawn was GOSH's.
vgate_assert 02 serial-absent 'exec: loaded GOFETCH.ELF'
vgate_assert 02 serial-contains 'gofetch: url https://10.0.0.2:24533/'
vgate_assert 02 serial-contains 'gofetch: handshake ok'
vgate_assert 02 serial-contains 'go-net-clis-ok'
vgate_assert 02 serial-contains 'gofetch: body complete'
vgate_assert 02 serial-absent 'gofetch: error'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'fatal error: runtime:'
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
if not re.search(r"(?m)^gosh: line exec GOFETCH\.ELF https://10\.0\.0\.2:24533/", ser):
    sys.exit("FAIL: GOSH never recorded the typed `exec GOFETCH.ELF ...` line")
if "gofetch: dial 10.0.0.2 24533" not in ser:
    sys.exit("FAIL: GOFETCH did not dial the relayed fixture")
if "gofetch: fail-closed" in ser:
    sys.exit("FAIL: the fetch failed closed; the fixture body was not read")
print("go-net-clis 02 ok: GOSH exec'd GOFETCH.ELF, TLS handshake + body")
PY

# --- boot 03: `time sync` steps the clock from the SNTP responder ----------
# M83b (#1775). The runner answers the guest's UDP :123 query with the HOST
# wall clock + 3600 s, so a correct client must land an hour ahead of the
# boot clock. Three lines are typed at once: the sync, its exit status, and
# `date` -- the read-back through the ordinary slot-66 path, a different code
# path from the client's own after-set read.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --net '$RUN_DIR/cap-03.bin' --net-arp-respond 10.0.0.2 \
    --net-sntp-respond 10.0.0.2 --net-sntp-skew 3600 \
    --script '$RUN_DIR/net.txt' \
    --script2 '$RUN_DIR/sh.txt' --script2-after 'net arp: ' \
    --script3 '$RUN_DIR/typed-sync.bin' --script3-after 'gosh: attached' \
    --script-expect '(epoch=' --timeout 180

vgate_assert 03 serial-contains 'gosh: attached'
vgate_assert 03 serial-contains 'time sync: synced server=10.0.0.2 stratum=2 delay='
vgate_assert 03 serial-absent 'clock untouched'
vgate_assert 03 output-contains 'NET-SNTP: answered 10.0.0.1:7000 served_unix='
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'fatal error: runtime:'
vgate_assert 03 python <<'PY'
import os, re, sys, time
rd = os.environ["RUN_DIR"]
ser = open(os.environ["VG_SER"], errors="replace").read()
out = open(os.path.join(rd, "run-" + os.environ["VG_TAG"] + ".out"), errors="replace").read()
start = float(open(os.path.join(rd, "host-epoch-start.txt")).read())
end = time.time()

# The host side: the responder served the host clock + 3600, and the epoch it
# served is bounded by the host's own samples around the run.
m = re.search(r"NET-SNTP: answered 10\.0\.0\.1:7000 served_unix=(\d+) skew=3600 originate=([0-9a-f]{16})", out)
if not m:
    sys.exit("FAIL: no NET-SNTP answer line with skew=3600 in the runner output")
served, originate = int(m.group(1)), m.group(2)
if not start + 3600 - 2 <= served <= end + 3600 + 2:
    sys.exit("FAIL: served epoch %d outside host interval [%d, %d] + 3600" % (served, start, end))

# The wire: exactly ONE guest query to 10.0.0.2:123 from the seam's fixed
# source port, a 48-byte v4 client packet, and its transmit stamp is the
# originate the responder echoed (so the reply answered THIS query).
d = open(os.path.join(rd, "cap-03.bin"), "rb").read()
off, queries = 0, []
while off < len(d):
    if d[off+12:off+14] == b"\x08\x00":
        flen = 14 + ((d[off+16] << 8) | d[off+17])
        f = d[off:off+flen]
        off += flen
        if f[23] == 17 and f[30:34] == bytes([10, 0, 0, 2]) and f[36:38] == b"\x00\x7b":
            queries.append(f)
    elif d[off+12:off+14] == b"\x86\xdd":
        # M117b (#2474): NDP/ICMPv6 frames are legitimate capture traffic;
        # skip them by the v6 length decode (14 + 40 + payload_len).
        off += 14 + 40 + ((d[off+18] << 8) | d[off+19])
    else:
        off += 42
if len(queries) != 1:
    sys.exit("FAIL: want exactly 1 SNTP query on the wire, saw %d" % len(queries))
q = queries[0]
if q[34:36] != (7000).to_bytes(2, "big") or len(q) != 42 + 48 or q[42] != 0x23:
    sys.exit("FAIL: query shape src=%r len=%d b0=%#x" % (q[34:36], len(q), q[42]))
if q[42+40:42+48].hex() != originate:
    sys.exit("FAIL: originate %s does not echo the query's transmit stamp %s"
             % (originate, q[42+40:42+48].hex()))

# The guest side: the console line, the correction it names, the exit status,
# and the read-back through `date`, in that order.
typed = re.search(r"(?m)^gosh: line time sync 10\.0\.0\.2", ser)
line = re.search(r"(?m)^time sync: synced server=10\.0\.0\.2 stratum=2 delay=(\d+)ms "
                 r"correction=([+-]\d+)s epoch=(\d+)$", ser)
rc = re.search(r"(?m)^rc=(\d+)\s*$", ser)
dline = re.search(r"(?m)^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?: UTC)? \(epoch=(\d+)\)$", ser)
for name, mm in (("typed line", typed), ("sync line", line), ("rc line", rc), ("date line", dline)):
    if not mm:
        sys.exit("FAIL: no %s in the serial log" % name)
if not typed.start() < line.start() < rc.start() < dline.start():
    sys.exit("FAIL: order want typed < sync < rc < date")
if rc.group(1) != "0":
    sys.exit("FAIL: `time sync` exit status %s, want 0" % rc.group(1))
correction, set_epoch, date_epoch = int(line.group(2)), int(line.group(3)), int(dline.group(2))
# The boot clock came from the host's own clock, so an hour of skew reads as
# about +3600 (a few seconds of boot-clock drift and tick phase allowed).
if not 3590 <= correction <= 3610:
    sys.exit("FAIL: correction %+d, want about +3600" % correction)
# The set epoch is the served second plus what elapsed since, and `date`
# reads the same clock a moment later.
if not served <= set_epoch <= served + 10:
    sys.exit("FAIL: set epoch %d not within 10 s of served %d" % (set_epoch, served))
if not set_epoch <= date_epoch <= set_epoch + 30:
    sys.exit("FAIL: date epoch %d not within 30 s after set epoch %d" % (date_epoch, set_epoch))
print("go-net-clis 03 ok: served %d (host+3600), 1 query, correction %+d, set %d, date %d"
      % (served, correction, set_epoch, date_epoch))
PY

# --- boot 04: no reply leaves the clock alone -------------------------------
# M83b. The route is real (ARP resolves 10.0.0.2) but nothing answers UDP
# :123, so the client sends ONE query, waits its 5 s budget and gives up.
# Honest failure is the acceptance: the line names it, the status is 1, and
# the clock `date` then reads is still the boot clock, not a stepped one.
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --net '$RUN_DIR/cap-04.bin' --net-arp-respond 10.0.0.2 \
    --script '$RUN_DIR/net.txt' \
    --script2 '$RUN_DIR/sh.txt' --script2-after 'net arp: ' \
    --script3 '$RUN_DIR/typed-sync.bin' --script3-after 'gosh: attached' \
    --script-expect '(epoch=' --timeout 180

vgate_assert 04 serial-contains 'gosh: attached'
vgate_assert 04 serial-contains 'time sync: no reply from 10.0.0.2 within 5s; clock untouched'
vgate_assert 04 serial-absent 'time sync: synced'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'fatal error: runtime:'
vgate_assert 04 python <<'PY'
import os, re, sys, time
rd = os.environ["RUN_DIR"]
ser = open(os.environ["VG_SER"], errors="replace").read()
out = open(os.path.join(rd, "run-" + os.environ["VG_TAG"] + ".out"), errors="replace").read()
start = float(open(os.path.join(rd, "host-epoch-start.txt")).read())
end = time.time()
if "NET-SNTP" in out:
    sys.exit("FAIL: a responder answered in the no-responder run")

d = open(os.path.join(rd, "cap-04.bin"), "rb").read()
off, queries = 0, 0
while off < len(d):
    if d[off+12:off+14] == b"\x08\x00":
        flen = 14 + ((d[off+16] << 8) | d[off+17])
        f = d[off:off+flen]
        off += flen
        if f[23] == 17 and f[30:34] == bytes([10, 0, 0, 2]) and f[36:38] == b"\x00\x7b":
            queries += 1
    elif d[off+12:off+14] == b"\x86\xdd":
        # M117b (#2474): NDP/ICMPv6 frames are legitimate capture traffic;
        # skip them by the v6 length decode (14 + 40 + payload_len).
        off += 14 + 40 + ((d[off+18] << 8) | d[off+19])
    else:
        off += 42
if queries != 1:
    sys.exit("FAIL: want exactly 1 SNTP query (no retry), saw %d" % queries)

typed = re.search(r"(?m)^gosh: line time sync 10\.0\.0\.2", ser)
fail = re.search(r"(?m)^time sync: no reply from 10\.0\.0\.2 within 5s; clock untouched$", ser)
rc = re.search(r"(?m)^rc=(\d+)\s*$", ser)
dline = re.search(r"(?m)^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?: UTC)? \(epoch=(\d+)\)$", ser)
for name, mm in (("typed line", typed), ("failure line", fail), ("rc line", rc), ("date line", dline)):
    if not mm:
        sys.exit("FAIL: no %s in the serial log" % name)
if not typed.start() < fail.start() < rc.start() < dline.start():
    sys.exit("FAIL: order want typed < failure < rc < date")
if rc.group(1) != "1":
    sys.exit("FAIL: `time sync` exit status %s, want 1" % rc.group(1))
epoch = int(dline.group(2))
# Still the boot clock: the host's own clock within the 60 s slack go-selftest
# uses for the same reading.
if not start - 60 <= epoch <= end + 60:
    sys.exit("FAIL: date epoch %d outside host interval [%d, %d] with 60 s slack" % (epoch, start, end))
print("go-net-clis 04 ok: 1 query, no reply, exit 1, clock untouched (date epoch %d)" % epoch)
PY

# --- boot 05: offline says offline ------------------------------------------
# M83b. No --net at all, so the guest has no IP. Bare `time sync` names the
# default server, which needs DNS -- and the client must say "offline" (the
# live-net-offline sentence) before it tries a resolver it cannot reach, not
# surface the resolver's ARP-flavoured send refusal.
vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --script '$RUN_DIR/sh.txt' \
    --script3 '$RUN_DIR/typed-sync-default.bin' --script3-after 'gosh: attached' \
    --script-expect '(epoch=' --timeout 120

vgate_assert 05 serial-contains 'gosh: attached'
vgate_assert 05 serial-contains 'time sync: offline — no IP address (set one: net ip <a.b.c.d> or net dhcp)'
vgate_assert 05 serial-contains 'time sync: clock untouched'
vgate_assert 05 serial-absent 'time sync: synced'
vgate_assert 05 serial-absent 'cannot resolve'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'fatal error: runtime:'
vgate_assert 05 python <<'PY'
import os, re, sys, time
rd = os.environ["RUN_DIR"]
ser = open(os.environ["VG_SER"], errors="replace").read()
start = float(open(os.path.join(rd, "host-epoch-start.txt")).read())
end = time.time()
typed = re.search(r"(?m)^gosh: line time sync$", ser)
fail = re.search(r"(?m)^time sync: clock untouched$", ser)
rc = re.search(r"(?m)^rc=(\d+)\s*$", ser)
dline = re.search(r"(?m)^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?: UTC)? \(epoch=(\d+)\)$", ser)
for name, mm in (("typed line", typed), ("failure line", fail), ("rc line", rc), ("date line", dline)):
    if not mm:
        sys.exit("FAIL: no %s in the serial log" % name)
if not typed.start() < fail.start() < rc.start() < dline.start():
    sys.exit("FAIL: order want typed < failure < rc < date")
if rc.group(1) != "1":
    sys.exit("FAIL: `time sync` exit status %s, want 1" % rc.group(1))
epoch = int(dline.group(2))
if not start - 60 <= epoch <= end + 60:
    sys.exit("FAIL: date epoch %d outside host interval [%d, %d] with 60 s slack" % (epoch, start, end))
print("go-net-clis 05 ok: offline, exit 1, clock untouched (date epoch %d)" % epoch)
PY

# --- boot 06: GOSH execs GODNS.ELF through the DNS responder -----------------
# M99i (#2187): the deep resolver holds up when the exec comes from GOSH's
# own parser — a third-process proof that the owned-port seam is per-process,
# not per-runtime. Same proof shape as boots 01/02: the monitor's load line
# is absent, GOSH's submit record is present, the child's Answer follows.
vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --net '$RUN_DIR/cap-06.bin' --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2 \
    --script '$RUN_DIR/net.txt' \
    --script2 '$RUN_DIR/sh.txt' --script2-after 'net arp: ' \
    --script3 '$RUN_DIR/typed-dns.bin' --script3-after 'gosh: attached' \
    --script-expect 'rc=0' --timeout 180

vgate_assert 06 serial-contains 'gosh: attached'
vgate_assert 06 serial-absent 'exec: loaded GODNS.ELF'
vgate_assert 06 serial-contains 'DNS query for example.com (A) via 10.0.0.2:53'
vgate_assert 06 serial-contains 'Answer: example.com -> 93.184.216.34 (ttl=300s answers=1 ignored=0)'
vgate_assert 06 serial-contains 'dns: status=ok'
vgate_assert 06 serial-contains 'rc=0'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'fatal error: runtime:'
vgate_assert 06 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
if not re.search(r"(?m)^gosh: line exec GODNS\.ELF example\.com 10\.0\.0\.2", ser):
    sys.exit("FAIL: GOSH never recorded the typed `exec GODNS.ELF ...` line")
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
if len(ports) != 1:
    sys.exit("FAIL: want exactly 1 DNS query on the wire, saw %d" % len(ports))
if not 49152 <= ports[0] <= 65535:
    sys.exit("FAIL: query source port %d outside the ephemeral range" % ports[0])
print("go-net-clis 06 ok: GOSH exec'd GODNS.ELF, ephemeral src port %d" % ports[0])
PY
