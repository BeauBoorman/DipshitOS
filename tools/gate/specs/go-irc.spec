# go-irc.spec -- M147a #2801 + M147b #2802: GOIRC.ELF protocol core vs a
# host Python fixture IRCd over the --net-tcp-respond relay; runs 04-06
# drive the --ui tabapp front-end under a live GOTABWM seat.
#
# Run 01 is the M147a card leg: register (NICK/USER -> 001), JOIN #goirc,
# receive a PRIVMSG, hard-drop, watch the client back off, re-register
# and REJOIN (the 'goirc: rejoin #goirc' marker + the fixture's
# post-rejoin REJOIN-MARKER message). Run 02 refuses plaintext without
# the session consent bit -- 'goirc: refuse plaintext' before any dial.
# Run 03 exercises 433 nick-in-use retry (gate -> gate_ -> gate__).
#
# M147b (#2802):
#   run 04 -- the mention chain end to end: GOIRC --ui joins #goirc +
#     #other under the seat, the fixture sends alice's "ping gate"
#     on #other, the app posts vi.Notify ('goirc: toast #other' +
#     'gotabwm: notify paint id='), a seat alt-tab blurs GOIRC to
#     GOTABAPP, and the toast click refocuses it -- the pending mention
#     lands the user on #other ('goirc: focus #other').
#   run 05 -- plaintext without a stored consent asks the dialog and
#     No is the safe default: 'return' on the focused No refuses by
#     name before any dial.
#   run 06 -- the same dialog with 'tab,return' (focus Yes): the answer
#     is stored ('goirc: state saved' from the seat's kind-20 ack) and
#     the session dials + joins.
#
# HOST PREREQUISITES:
#   bash tools/go/build-goirc.sh   -> .build/go/GOIRC.ELF
#   bash tools/go/build-gotabwm.sh -> .build/go/GOTABWM.ELF
#   bash tools/go/build-tabapp.sh  -> .build/go/GOTABAPP.ELF
# Fixture transcripts land in $RUN_DIR/ircd-<port>.log for the python
# asserts. TLS on 6697 is class-A covered (dial path is tls.Dial); the
# fixture speaks plaintext only, per the card's acceptance.

vgate_name go-irc "M147a+b #2801/#2802: GOIRC.ELF core (register/join/recv/drop/reconnect, consent refusal, 433) + UI legs (mention toast click-through, consent dialog)"
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

# M147b runs 04-06 drive --ui under a live seat: stage the seat and the
# second tab the rail-click blur needs.
for name, script in (("GOTABWM.ELF", "build-gotabwm.sh"),
                     ("GOTABAPP.ELF", "build-tabapp.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + script)
    shutil.copy(src, os.path.join(share, name))
    print("go-irc: staged %s (%d)" % (name, os.path.getsize(src)))

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

conns = {"rejoin": 2, "nickuse": 1, "mention": 1, "once": 1}[mode]
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
    elif mode == "mention":
        # M147b run 04: on the #other JOIN confirm, alice pings the
        # client's nick — the toast the gate then clicks through.
        nick, buf = register(conn, idx)
        if not nick:
            conn.close()
            continue
        def on_join(ch, conn=conn, nick=nick):
            if ch == "#other":
                send(conn, ":alice!u@h PRIVMSG #other :ping %s you there?" % nick)
            else:
                send(conn, ":alice!u@h PRIVMSG %s :plain hello on %s" % (ch, ch))
        pump(conn, idx, nick, buf, on_join, hold=45)
        conn.close()
        log("c%d close" % idx)
    elif mode == "once":
        # M147b run 06: a plain session that just holds — the leg's
        # interest is the consent dialog, not the traffic.
        nick, buf = register(conn, idx)
        if nick:
            pump(conn, idx, nick, buf, lambda ch: None, hold=45)
        conn.close()
        log("c%d close" % idx)

srv.close()
log("fixture done")
''')

procs = []
for mode, port in (("rejoin", 26667), ("nickuse", 26668),
                   ("mention", 26669), ("once", 26670)):
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

# --- M147b (#2802) run 04: mention -> toast -> click-through ---------------
#
# GOIRC --ui runs under a LIVE seat (GOTABWM.DEMO removed): the tabapp
# declare makes it a rail tab, and vi.Notify is a real kind-12 frame the
# seat queues + paints. The chain, each link its own marker:
#
#   goirc: join #other               own JOIN confirmed (rail seeded it
#                                    earlier; the confirm re-adds noop)
#   goirc: msg #other alice ping ... the mention entry
#   goirc: toast #other              the app's ack -- the seat answered,
#                                    so the toast is not a void request
#   gotabwm: notify paint id=<n>     toast ON THE SCANOUT (pointer anchor)
#   goirc: blur                      the seat's alt-tab moved focus to
#                                    GOTABAPP (the rail cell script2 put
#                                    first)
#   gotabwm: notify dismiss id=<n>   the toast click dismissed it AND
#                                    refocused the sender (focusHosted)
#   goirc: focus #other              the pending mention lands the user
#                                    on the buffer that called
#
# The pointer batch is ONE batch anchored on 'notify paint' (toast provably
# on screen): press+release at the toast's centre (112,702) = middle of
# notifyRect(1280,720,0) = (8,692,208,20). The BLUR rides a different
# transport deliberately: pointer messages pace at 2.5 s each, so a
# blur-click + toast-click in one batch lands the toast press ~9 s after
# the push -- past NotifyTicks=8 (observed on the first attempt: the
# dismiss marker was expiry, and the press found an empty strip). A seat
# 'alt-tab' chord strokes at 0.25 s, so it blurs GOIRC to GOTABAPP the
# moment the toast paints, and the solo pointer press refocuses it while
# the toast is still alive.
#
# The blur is load-bearing either way: kernel focus() pushes WIN_FOCUS
# only when focused_id changes, so a toast click on an already-focused
# sender would never reach GOIRC's event loop for the pending-mention
# landing.
vgate_file script-04.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-04.txt <<'EOF'
dui focus 0
exec GOTABAPP.ELF &
fg
exec GOIRC.ELF --ui --host=10.0.0.2 --port=6669 --nick=gate --join '#goirc,#other' --plain
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio \
    --net '$RUN_DIR/cap04.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:6669:relay --net-tcp-respond-relay 127.0.0.1:26669 \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' --script2-after 'gotabwm: win focus' \
    --input-chords 'alt-tab' --input-chords-after 'gotabwm: notify paint id=' \
    --pointer-virtio '112,702,d;112,702,u' \
    --pointer-virtio-after 'gotabwm: notify paint id=' \
    --script-expect 'goirc: focus #other' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 04 serial-contains 'gotabwm: mode live'
vgate_assert 04 serial-absent 'gotabwm: mode demo'
vgate_assert 04 serial-contains 'exec: loaded GOTABAPP.ELF'
vgate_assert 04 serial-contains 'exec: loaded GOIRC.ELF'
vgate_assert 04 serial-contains 'goirc: open id='
vgate_assert 04 serial-contains 'goirc: declare accepted'
vgate_assert 04 serial-contains 'goirc: dial 10.0.0.2 6669 plain'
vgate_assert 04 serial-contains 'goirc: registered nick=gate'
vgate_assert 04 serial-contains 'goirc: join #goirc'
vgate_assert 04 serial-contains 'goirc: join #other'
vgate_assert 04 serial-contains 'goirc: msg #other alice ping gate you there?'
vgate_assert 04 serial-contains 'goirc: toast #other'
vgate_assert 04 serial-absent 'goirc: toast-refused'
vgate_assert 04 serial-contains 'gotabwm: notify id='
vgate_assert 04 serial-contains 'gotabwm: notify paint id='
vgate_assert 04 serial-contains 'goirc: blur'
vgate_assert 04 serial-contains 'gotabwm: notify dismiss id='
vgate_assert 04 serial-contains 'gotabwm: tab focus id='
vgate_assert 04 serial-contains 'goirc: focus #other'
vgate_assert 04 serial-absent 'goirc: error'
vgate_assert 04 serial-absent '[EXC] parking:'
# Ordering: the toast must be painted before the click dismisses it, and
# the blur before the refocus -- each marker can appear without the
# others, so the causal chain is asserted as an order. 'tab focus id='
# also prints at tab-setup, so each link is searched AFTER the previous
# one, not globally.
vgate_assert 04 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

chain = ["gotabwm: notify paint id=", "goirc: blur",
         "gotabwm: notify dismiss id=", "gotabwm: tab focus id=",
         "goirc: focus #other"]
pos = 0
for m in chain:
    i = ser.find(m, pos)
    if i < 0:
        sys.exit("chain marker missing after %d: %r" % (pos, m))
    pos = i + len(m)
log = open(os.path.join(os.environ["RUN_DIR"], "ircd-26669.log")).read()
need = ["c0 open", "c0 rx NICK gate", "c0 rx USER", "c0 rx JOIN #goirc",
        "c0 rx JOIN #other", "tx :alice!u@h PRIVMSG #other :ping gate"]
missing = [n for n in need if n not in log]
sys.exit("fixture transcript missing: %r\n%s" % (missing, log) if missing else 0)
PY

# --- M147b (#2802) run 05: plaintext consent refuses by name ----------------
#
# --ui without --plain and with no stored consent raises appkit's Confirm
# BEFORE any dial; No is the default focus, so a bare 'return' chooses it:
# 'goirc: consent no' + the same named refusal the console driver prints.
# Nothing reaches the wire -- no dial marker, no registered, no fixture
# transcript at all.
vgate_file script-05.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-05.txt <<'EOF'
dui focus 0
exec GOIRC.ELF --ui --host=10.0.0.2 --port=6670 --nick=gate
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --script '$RUN_DIR/script-05.txt' \
    --script2 '$RUN_DIR/script2-05.txt' --script2-after 'gotabwm: win focus' \
    --input-chords 'return' --input-chords-after 'goirc: consent ask' \
    --script-expect 'goirc: refuse plaintext' --timeout 240

vgate_assert 05 serial-contains 'goirc: consent ask'
vgate_assert 05 serial-contains 'goirc: consent no'
vgate_assert 05 serial-contains 'goirc: refuse plaintext'
vgate_assert 05 serial-absent 'goirc: consent yes'
vgate_assert 05 serial-absent 'goirc: dial'
vgate_assert 05 serial-absent 'goirc: registered'
vgate_assert 05 serial-absent '[EXC] parking:'

# --- M147b (#2802) run 06: consent yes is stored + dials ---------------------
#
# 'tab' moves the dialog focus from No (default) to Yes; 'return' chooses
# it: 'goirc: consent yes' -> SaveStateNow posts the blob ('goirc: state
# saved' prints on the seat's kind-20 ack, so the answer is PROVABLY
# stored) -> the session dials, registers and joins.
vgate_file script-06.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
dui focus 0
exec GOIRC.ELF --ui --host=10.0.0.2 --port=6670 --nick=gate --join '#goirc'
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --net '$RUN_DIR/cap06.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:6670:relay --net-tcp-respond-relay 127.0.0.1:26670 \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' --script2-after 'gotabwm: win focus' \
    --input-chords 'tab,return' --input-chords-after 'goirc: consent ask' \
    --script-expect 'goirc: join #goirc' --timeout 300

vgate_assert 06 serial-contains 'goirc: consent ask'
vgate_assert 06 serial-contains 'goirc: consent yes'
vgate_assert 06 serial-contains 'goirc: state saved'
vgate_assert 06 serial-contains 'goirc: dial 10.0.0.2 6670 plain'
vgate_assert 06 serial-contains 'goirc: registered nick=gate'
vgate_assert 06 serial-contains 'goirc: join #goirc'
vgate_assert 06 serial-absent 'goirc: refuse plaintext'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 python <<'PY'
import os, sys
log = open(os.path.join(os.environ["RUN_DIR"], "ircd-26670.log")).read()
need = ["c0 open", "c0 rx NICK gate", "c0 rx USER", "c0 rx JOIN #goirc"]
missing = [n for n in need if n not in log]
sys.exit("fixture transcript missing: %r\n%s" % (missing, log) if missing else 0)
PY
