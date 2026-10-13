# live-ssh-server.spec -- M70g G1 (#1491, ADR 0025) class-B positive.
#
# The in-guest GOSSHD.ELF listens on 2222 (slot 30 ip-0). The runner's
# `--net-tcp-connect …:ssh` client speaks the ADR 0025 D2 profile against
# it: curve25519-sha256 KEX, ssh-ed25519 host key from TS5
# `ssh-host-ed25519` (RFC 8032 TEST 1), publickey vs SSH/AUTHORIZED_KEYS
# (TEST 2), one session exec piped to GOSH.ELF -c. TX is paced one
# encrypted <=192-byte segment per guest ACK. Hermetic via --net.
# Class B (Apple silicon VZ).
#
# HOST PREREQ:
#   bash tools/go/build-sshd.sh -> .build/go/GOSSHD.ELF
#   bash tools/go/build-gosh.sh -> .build/go/GOSH.ELF

vgate_name live-ssh-server "M70g G1: GOSSHD.ELF KEX+publickey+GOSH exec against the runner's SSH-2 client"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSSHD.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
for name, cmd in (("GOSSHD.ELF", "bash tools/go/build-sshd.sh"),
                  ("GOSH.ELF", "bash tools/go/build-gosh.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + cmd)
    shutil.copy(src, os.path.join(share, name))
os.makedirs(os.path.join(share, "SSH"), exist_ok=True)
# RFC 8032 §7.1 TEST 1 seed: the guest host key (uid_user), app-bound to
# GOSSHD.ELF (M97g #2083); OWNERS.TXT pins the image uid_system.
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n"
    "ssh-host-ed25519\t1000\t9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60\tGOSSHD.ELF\n"
)
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\n"
    "GOSSHD.ELF\t644\t0\t-\n"
    "GOSH.ELF\t644\t0\t-\n"
)
# RFC 8032 §7.1 TEST 2 public key: the runner client's identity.
open(os.path.join(share, "SSH", "AUTHORIZED_KEYS"), "w").write(
    "#v1\n"
    "alice\tssh-ed25519\t3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c\n"
)
print("staged GOSSHD.ELF (%d bytes) GOSH.ELF (%d bytes)"
      % (os.path.getsize(os.path.join(share, "GOSSHD.ELF")),
         os.path.getsize(os.path.join(share, "GOSH.ELF"))))
PY

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:2222:ssh \
    --net-tcp-connect-after 'sshd: listen' \
    --script '$RUN_DIR/script-1.txt' \
    --script-expect 'sshd: bye' \
    --timeout 120

vgate_assert 01 output-contains 'NET-TCP-CONNECT-SSH: cipher self-check ok'
vgate_assert 01 output-contains 'NET-TCP-CONNECT-SSH: ENABLED'
vgate_assert 01 output-contains 'SSH-CLI: version received: SSH-2.0-VirelaiOS_1.0'
vgate_assert 01 output-contains 'SSH-CLI: kexinit received (suite negotiated)'
vgate_assert 01 output-contains 'SSH-CLI: ecdh reply accepted; host key pinned'
vgate_assert 01 output-contains 'SSH-CLI: publickey accepted user=alice key=ssh-ed25519'
vgate_assert 01 output-contains 'SSH-CLI: exec echo VIRELAI-SSH-SERVER-OK-ARGV2'
vgate_assert 01 output-contains 'SSH-CLI: stdout VIRELAI-SSH-SERVER-OK-ARGV2'
vgate_assert 01 output-contains 'SSH-CLI: exit-status=0'
vgate_assert 01 output-contains 'NET-TCP-CONNECT-SSH: sent'
vgate_assert 01 serial-contains 'sshd: listen 2222'
vgate_assert 01 serial-contains 'sshd: accepted'
vgate_assert 01 serial-contains 'sshd: kex-ok'
vgate_assert 01 serial-contains 'sshd: auth-ok user=alice key=ssh-ed25519'
vgate_assert 01 serial-contains 'sshd: exec echo VIRELAI-SSH-SERVER-OK-ARGV2'
vgate_assert 01 serial-contains 'sshd: gosh rc=0'
vgate_assert 01 serial-contains 'sshd: bye'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 01 serial-absent '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb'
vgate_assert 01 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
for seed in (
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
):
    if seed in out:
        sys.exit("FAIL: a private seed appears in the runner stdout")
if out.count("NET-TCP-CONNECT-SSH: sent ") < 3:
    sys.exit("FAIL: pacing produced fewer than 3 segments")
print("ssh server runner log ok")
PY

# --- M99g (#2185): two concurrent sessions -------------------------------
# The pre-M99g daemon served exactly one session on the singleton socket.
# On the slot-80 handle listener every accepted child is its own Conn on
# its own goroutine, so the kernel's child_limit=2 becomes two
# concurrent SSH sessions — each running GOSH -c independently — while a
# DIFFERENT process (AGENTD.ELF, legacy slot-30 listener) holds its own
# socket: listener + two children + a second process's listener coexist
# inside the one socket table.

# GOMAXPROCS=1 pins every runtime to 3 tasks (primary+sysmon+helper, the
# WM-spec convention): agentd + sshd + two session GOSH children = 12 of
# the 13 EL0t slots. At the compiled default of 2 the second session's
# GOSH hits EAGAIN on sys_thread create and dies status=2 — observed
# 2026-10-12 with the run unchanged since M99g, i.e. the two-session leg
# had been silently capacity-racing on faster hosts.
vgate_file script-2.txt <<'EOF'
set GOMAXPROCS=1
net ip 10.0.0.1
net arp 10.0.0.2
exec AGENTD.ELF
exec GOSSHD.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
for name, cmd in (("GOSSHD.ELF", "bash tools/go/build-sshd.sh"),
                  ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
                  ("AGENTD.ELF", "bash tools/go/build-agentd.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + cmd)
    shutil.copy(src, os.path.join(share, name))
os.makedirs(os.path.join(share, "SSH"), exist_ok=True)
os.makedirs(os.path.join(share, "AGENT"), exist_ok=True)
# sshd's host key + agentd's hmac credential, each app-bound (M97g).
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n"
    "ssh-host-ed25519\t1000\t9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60\tGOSSHD.ELF\n"
    "agent-hmac\t1000\t" + "a5" * 32 + "\tAGENTD.ELF\n"
)
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\n"
    "GOSSHD.ELF\t644\t0\t-\n"
    "GOSH.ELF\t644\t0\t-\n"
    "AGENTD.ELF\t644\t0\t-\n"
)
open(os.path.join(share, "SSH", "AUTHORIZED_KEYS"), "w").write(
    "#v1\n"
    "alice\tssh-ed25519\t3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c\n"
)
print("staged two-session share")
PY

# Two :ssh clients on ports 12345/12346 dial once 'sshd: listen' lands;
# both must complete KEX+auth+exec. The daemon keeps its listener for the
# next SYN; the bounded idle accept then closes the loop and 'sshd: bye'
# is the run's own end marker.
vgate_run 02 -- --net '$RUN_DIR/cap2.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:2222:ssh --net-tcp-connect 10.0.0.1:2222:ssh \
    --net-tcp-connect-after 'sshd: listen' \
    --script '$RUN_DIR/script-2.txt' \
    --script-expect 'sshd: bye' --timeout 150

vgate_assert 02 serial-contains 'agentd: listen 4747'
vgate_assert 02 serial-contains 'sshd: listen 2222'
vgate_assert 02 serial-contains 'sshd: bye'
vgate_assert 02 serial-absent 'sshd: error'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, re, struct, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Every marker twice: two sessions each ran the full KEX+auth+GOSH exec.
for marker in ("sshd: accepted", "sshd: kex-ok",
               "sshd: auth-ok user=alice key=ssh-ed25519",
               "sshd: exec echo VIRELAI-SSH-SERVER-OK-ARGV2",
               "sshd: gosh rc=0"):
    n = ser.count(marker)
    if n != 2:
        sys.exit("FAIL: %r appeared %d times, want 2" % (marker, n))
out = open(os.path.join(os.environ["RUN_DIR"], "run-02.out"), errors="replace").read()
assert out.count("SSH-CLI: exit-status=0") == 2, "both clients must finish exec"
assert out.count("SSH-CLI: stdout VIRELAI-SSH-SERVER-OK-ARGV2") == 2
# The wire walk: guest frames from listener 2222 to the two client
# source ports — distinct 5-tuples whose windows overlap (a one-session
# daemon could not emit on the second while the first still streams).
data = open(os.environ["RUN_DIR"] + "/cap2.bin", "rb").read()
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
    if sp != 2222:
        continue
    conns.setdefault(dp, []).append((idx, len(f) - 54))
assert set(conns) == {12345, 12346}, list(conns)
for dp, segs in conns.items():
    assert any(n > 0 for _, n in segs), "client port %d got no guest data" % dp
assert conns[12345][0][0] < conns[12346][-1][0] and conns[12346][0][0] < conns[12345][-1][0], (
    "session windows did not overlap")
print("ssh2 ok: agentd listener + 2 concurrent SSH sessions, 2 GOSH execs, overlapping 5-tuples")
PY

# --- M99z (#2194) run 03: the networking end-to-end ----------------------
#
# The card's concurrency bar, all on the one hermetic --net attachment at
# once: AGENTD.ELF listening on 4747, GOSSHD.ELF serving TWO concurrent
# sessions, and WEB.ELF fetching http://10.0.0.2/ through the runner's
# relay responder — three connection-bearing apps plus a listener, live
# together in the one socket table. The web fetch is armed on 'sshd:
# listen' with zero delay so its SYN lands while the paced KEX traffic of
# session 1 is still in flight; the pcap walk below asserts the three
# distinct 5-tuples and that the web flow's window interleaves the SSH
# sessions'.
#
# NAT real-peer result, recorded per the card: M99h's live-net-tcp run C
# drove a SYN to the real NAT gateway (192.168.64.1:9999) on this host and
# the gateway answered RST — 'named-blocked', documented in that spec's
# header (rst_r=1, the gateway refuses rather than drops). The hermetic
# --net path below is unaffected: it never leaves the runner.

# Same GOMAXPROCS=1 pin, and it is load-bearing here: agentd + sshd + WEB +
# the session GOSH children are FIVE runtimes in one boot. At 3 tasks each
# the steady state is 9 slots and each GOSH adds 3 while its exec lives —
# inside 13 only because the paced KEX keeps the two sessions' execs out of
# phase (observed ~2 s apart, each echo under a second). A run where the
# two GOSHs genuinely overlap would hit EAGAIN and print rc=2 — an honest
# capacity edge, not a silent result.
vgate_file script-3.txt <<'EOF'
set GOMAXPROCS=1
net ip 10.0.0.1
net arp 10.0.0.2
exec AGENTD.ELF
exec GOSSHD.ELF
EOF

vgate_file script-3b.txt <<'EOF'
exec WEB.ELF http://10.0.0.2/
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
src = os.path.join(".build", "go", "WEB.ELF")
if not os.path.exists(src):
    sys.exit("WEB.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh")
shutil.copy(src, os.path.join(share, "WEB.ELF"))
print("staged WEB.ELF (%d bytes)" % os.path.getsize(src))
PY

vgate_run 03 -- --net '$RUN_DIR/cap3.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:2222:ssh --net-tcp-connect 10.0.0.1:2222:ssh \
    --net-tcp-connect-after 'sshd: listen' \
    --net-tcp-respond 10.0.0.2:80 \
    --screen '$RUN_DIR/screen-03' \
    --script '$RUN_DIR/script-3.txt' \
    --script2 '$RUN_DIR/script-3b.txt' \
    --script2-after 'sshd: listen' --script2-delay 0 \
    --script-expect 'sshd: bye' --script-expect-tail 8 --timeout 240

vgate_assert 03 serial-contains 'agentd: listen 4747'
vgate_assert 03 serial-contains 'sshd: listen 2222'
vgate_assert 03 serial-contains 'sshd: bye'
vgate_assert 03 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 03 serial-contains 'web: settled'
vgate_assert 03 serial-contains 'web: ready'
vgate_assert 03 serial-absent 'sshd: error'
vgate_assert 03 serial-absent 'web: error'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 03 python <<'PY'
import os, struct, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Both SSH sessions ran the full KEX+auth+GOSH exec while the fetch ran.
for marker in ("sshd: accepted", "sshd: kex-ok",
               "sshd: auth-ok user=alice key=ssh-ed25519",
               "sshd: exec echo VIRELAI-SSH-SERVER-OK-ARGV2",
               "sshd: gosh rc=0"):
    n = ser.count(marker)
    if n != 2:
        sys.exit("FAIL: %r appeared %d times, want 2" % (marker, n))
out = open(os.path.join(os.environ["RUN_DIR"], "run-03.out"), errors="replace").read()
assert out.count("SSH-CLI: exit-status=0") == 2, "both clients must finish exec"
# The wire walk: the two SSH flows are guest:2222 <-> 10.0.0.2:{12345,
# 12346}; the web flow is guest:ephemeral <-> 10.0.0.2:80. Three distinct
# 5-tuples, and the web window must sit inside the SSH window — the
# sessions were provably still live when the fetch crossed them.
data = open(os.environ["RUN_DIR"] + "/cap3.bin", "rb").read()
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
guest = bytes([10, 0, 0, 1])
peer = bytes([10, 0, 0, 2])
ssh, web = {}, {"first": None, "last": None, "sport": None}
for idx, f in enumerate(frames):
    if f[23] != 6:
        continue
    src, dst, sp, dp = f[26:30], f[30:34], (f[34] << 8) | f[35], (f[36] << 8) | f[37]
    if src == guest and sp == 2222:
        ssh.setdefault(dp, []).append(idx)
    elif src == peer and sp == 80 or src == guest and dp == 80:
        web["first"] = idx if web["first"] is None else web["first"]
        web["last"] = idx
        web["sport"] = dp if sp == 80 else sp
assert set(ssh) == {12345, 12346}, list(ssh)
assert web["first"] is not None, "no web flow to 10.0.0.2:80 in the capture"
ssh_lo = min(s[0] for s in ssh.values())
ssh_hi = max(s[-1] for s in ssh.values())
assert ssh_lo < web["first"] < ssh_hi and web["last"] > ssh_lo, (
    f"web window [{web['first']},{web['last']}] did not interleave "
    f"the ssh window [{ssh_lo},{ssh_hi}]")
print("m99z-net ok: agentd listener + 2 concurrent SSH + web fetch, "
      "3 distinct 5-tuples, web window inside ssh window")
PY
