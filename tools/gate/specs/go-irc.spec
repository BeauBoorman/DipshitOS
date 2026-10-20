# go-irc.spec -- M147a #2801: GOIRC.ELF protocol core vs a host Python
# fixture IRCd over the --net-tcp-respond relay.
#
# Run 01 is the card leg: register (NICK/USER -> 001), JOIN #goirc,
# receive a PRIVMSG, hard-drop, watch the client back off, re-register
# and REJOIN (the 'goirc: rejoin #goirc' marker + the fixture's
# post-rejoin REJOIN-MARKER message). Run 02 refuses plaintext without
# the session consent bit -- 'goirc: refuse plaintext' before any dial.
# Run 03 exercises 433 nick-in-use retry (gate -> gate_ -> gate__).
#
# HOST PREREQUISITE: bash tools/go/build-goirc.sh -> .build/go/GOIRC.ELF.
# Fixture transcripts land in $RUN_DIR/ircd-<port>.log for the python
# asserts. TLS on 6697 is class-A covered (dial path is tls.Dial); the
# fixture speaks plaintext only, per the card's acceptance.

vgate_name go-irc "M147a #2801: GOIRC.ELF register/join/recv/drop/reconnect vs fixture IRCd; plaintext consent refusal; 433 retry"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# The monitor's exec verb packs at most 8 argv slots and the program
# name takes one (max_exec_args); the --flag=value spellings keep each
# leg inside the bound. script-01 relies on --script-expect/--timeout to
# end the leg, so no --max-ms.
vgate_file script-01.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOIRC.ELF --host=10.0.0.2 --nick=gate --join '#goirc' --plain --retries=3 --backoff-ms=300
EOF

vgate_file script-02.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOIRC.ELF --host=10.0.0.2 --nick=gate --join '#goirc' --max-ms=30000
EOF

vgate_file script-03.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOIRC.ELF --host=10.0.0.2 --port=6668 --nick=gate --join '#goirc' --plain --max-ms=60000
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

goirc = os.path.join(".build", "go", "GOIRC.ELF")
if not os.path.exists(goirc):
    sys.exit("GOIRC.ELF missing (expected " + goirc + ") - build it first: "
             "bash tools/go/build-goirc.sh")
shutil.copy(goirc, os.path.join(share, "GOIRC.ELF"))
print("go-irc: staged GOIRC.ELF (%d)" % os.path.getsize(os.path.join(share, "GOIRC.ELF")))

fixture = os.path.join(run, "ircd.py")
with open(fixture, "w") as f:
    f.write('''
import socket, sys, time

mode, port, logpath = sys.argv[1], int(sys.argv[2]), sys.argv[3]
logf = open(logpath, "w", buffering=1)

def log(s):
    logf.write(s + "\\n")

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(4)
srv.settimeout(1800)  # outlives the slowest leg sequence
log("listening mode=" + mode)

def send(conn, line):
    conn.sendall(line.encode() + b"\\r\\n")
    log("tx " + line)

def recvline(conn, buf):
    while b"\\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return None, buf
        buf += chunk
    line, buf = buf.split(b"\\n", 1)
    return line.decode("utf-8", "replace").rstrip("\\r"), buf

def register(conn, idx, taken=()):
    """Read until NICK+USER (optionally refusing nicks in `taken` with
    433), then 001. Returns (nick, buf) or (None, buf) on close."""
    buf, nick, user = b"", None, False
    deadline = time.time() + 60
    while time.time() < deadline:
        line, buf = recvline(conn, buf)
        if line is None:
            return None, buf
        log("c%d rx %s" % (idx, line))
        parts = line.split()
        if not parts:
            continue
        cmd = parts[0].upper()
        if cmd == "NICK" and len(parts) > 1:
            nick = parts[1]
            if nick in taken:
                send(conn, ":srv 433 * %s :Nickname is already in use" % nick)
                nick = None
        elif cmd == "USER":
            user = True
        elif cmd == "PING":
            send(conn, ":srv PONG srv :" + (parts[1] if len(parts) > 1 else ""))
        if nick and user:
            send(conn, ":srv 001 %s :Welcome to the fixture net" % nick)
            return nick, buf
    return None, buf

def pump(conn, idx, nick, buf, on_join, hold=20, first_only=False):
    """Read commands until close/timeout; on_join(chan) fires per JOIN.
    first_only exits after the first JOIN — that close IS the drop the
    leg asserts."""
    deadline = time.time() + hold
    while time.time() < deadline:
        conn.settimeout(max(1.0, deadline - time.time()))
        try:
            line, buf = recvline(conn, buf)
        except socket.timeout:
            break
        if line is None:
            break
        log("c%d rx %s" % (idx, line))
        parts = line.split()
        if not parts:
            continue
        cmd = parts[0].upper()
        if cmd == "JOIN" and len(parts) > 1:
            ch = parts[1].lstrip(":")
            send(conn, ":%s!u@h JOIN %s" % (nick, ch))
            on_join(ch)
            if first_only:
                return
        elif cmd == "PING":
            send(conn, ":srv PONG srv :" + (parts[1] if len(parts) > 1 else ""))
        elif cmd == "QUIT":
            break

conns = {"rejoin": 2, "nickuse": 1}[mode]
for idx in range(conns):
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        log("accept timeout at conn %d" % idx)
        break
    conn.settimeout(60)
    log("c%d open" % idx)
    if mode == "rejoin":
        nick, buf = register(conn, idx)
        if not nick:
            conn.close()
            continue
        if idx == 0:
            # first-hello, then a hard close: the drop the client must
            # back off and reconnect from.
            pump(conn, idx, nick, buf,
                 lambda ch: send(conn, ":alice!u@h PRIVMSG %s :first-hello" % ch),
                 hold=15, first_only=True)
        else:
            pump(conn, idx, nick, buf,
                 lambda ch: send(conn, ":alice!u@h PRIVMSG %s :REJOIN-MARKER" % ch),
                 hold=30)
        conn.close()
        log("c%d close" % idx)
    elif mode == "nickuse":
        nick, buf = register(conn, idx, taken=("gate", "gate_"))
        if nick:
            pump(conn, idx, nick, buf, lambda ch: None, hold=30)
        conn.close()
        log("c%d close" % idx)

srv.close()
log("fixture done")
''')

procs = []
for mode, port in (("rejoin", 26667), ("nickuse", 26668)):
    for p in (port,):
        subprocess.run(["sh", "-c", "lsof -ti tcp:%d | xargs kill -9" % p],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    logpath = os.path.join(run, "ircd-%d.log" % port)
    log = open(logpath, "w")
    log.close()
    proc = subprocess.Popen([sys.executable, fixture, mode, str(port), logpath],
                            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                            start_new_session=True)
    procs.append(proc)
    print("go-irc: fixture %s pid=%d on 127.0.0.1:%d" % (mode, proc.pid, port))

time.sleep(0.4)
for proc in procs:
    if proc.poll() is not None:
        sys.exit("go-irc: fixture exited early rc=%s" % proc.returncode)
PY

# Run 01 -- the card leg: register, join, receive, hard drop, reconnect,
# rejoin. The fixture closes conn 1 after first-hello; the client backs
# off (--backoff-ms 300), re-registers and re-sends JOIN -- 'goirc: rejoin
# #goirc' -- and the fixture's conn-2 answer carries REJOIN-MARKER.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --net '$RUN_DIR/cap01.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:6667:relay --net-tcp-respond-relay 127.0.0.1:26667 \
    --script '$RUN_DIR/script-01.txt' --script-expect 'goirc: msg #goirc alice REJOIN-MARKER' --timeout 300

vgate_assert 01 serial-contains 'goirc: dial 10.0.0.2 6667 plain'
vgate_assert 01 serial-count 'goirc: registered nick=gate' 2
vgate_assert 01 serial-count 'goirc: join #goirc' 2
vgate_assert 01 serial-contains 'goirc: msg #goirc alice first-hello'
vgate_assert 01 serial-contains 'goirc: drop '
vgate_assert 01 serial-contains 'goirc: backoff 300'
vgate_assert 01 serial-contains 'goirc: rejoin #goirc'
vgate_assert 01 serial-contains 'goirc: msg #goirc alice REJOIN-MARKER'
vgate_assert 01 serial-absent 'goirc: error'
vgate_assert 01 serial-absent 'goirc: refuse plaintext'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys
log = open(os.path.join(os.environ["RUN_DIR"], "ircd-26667.log")).read()
need = ["c0 open", "c0 rx NICK gate", "c0 rx USER", "c0 rx JOIN #goirc",
        "c1 open", "c1 rx NICK gate", "c1 rx USER", "c1 rx JOIN #goirc",
        "c0 close"]
missing = [n for n in need if n not in log]
sys.exit("fixture transcript missing: %r\n%s" % (missing, log) if missing else 0)
PY

# Run 02 -- plaintext without the consent bit refuses before any dial:
# the named refusal marker, never a socket. (The TLS dial path itself is
# class-A covered; this leg is the consent rule's gate.)
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --net '$RUN_DIR/cap02.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:6667:relay --net-tcp-respond-relay 127.0.0.1:26667 \
    --script '$RUN_DIR/script-02.txt' --script-expect 'goirc: refuse plaintext' --timeout 180

vgate_assert 02 serial-contains 'goirc: refuse plaintext'
vgate_assert 02 serial-contains 'goirc: closed'
vgate_assert 02 serial-absent 'goirc: registered'
vgate_assert 02 serial-absent 'goirc: join #goirc'
vgate_assert 02 serial-absent '[EXC] parking:'

# Run 03 -- 433 nick-in-use: the fixture refuses 'gate' and 'gate_',
# accepts 'gate__'. The registered marker carries the retry nick.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --net '$RUN_DIR/cap03.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:6668:relay --net-tcp-respond-relay 127.0.0.1:26668 \
    --script '$RUN_DIR/script-03.txt' --script-expect 'goirc: registered nick=gate__' --timeout 240

vgate_assert 03 serial-contains 'goirc: registered nick=gate__'
vgate_assert 03 serial-contains 'nick in use'
vgate_assert 03 serial-absent 'goirc: error'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, sys
log = open(os.path.join(os.environ["RUN_DIR"], "ircd-26668.log")).read()
need = ["c0 rx NICK gate\n", "c0 rx NICK gate_", "c0 rx NICK gate__",
        "c0 rx USER", "c0 open"]
missing = [n for n in need if n not in log]
sys.exit("fixture transcript missing: %r\n%s" % (missing, log) if missing else 0)
PY
