# go-irc.spec -- M147a #2801 + M147b #2802 + M147c #2803: GOIRC.ELF
# protocol core vs a host Python fixture IRCd over the --net-tcp-respond
# relay; runs 04-08 drive the --ui tabapp front-end under a live GOTABWM
# seat.
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
# M147c (#2803) is the K=3 acceptance: vgate_repeat 3 replays every leg.
# Run 07 is the scripted conversation the card names -- TLS first,
# plaintext only after the stored consent, a mention toast with a real
# click-through inside its TTL, then the seat's ctrl-shift-s
# SNAPSHOT.BUNDLE as the terminal marker; run 08 is the restore boot
# (SESSION.TABS re-execs both rows bare -- no consent re-ask -- and the
# fixture's 'restored-tail' proves the scrollback/channels round-trip,
# corroborated by a byte-level decode of the bundle's session trailer).
# The armed share persists across iterations, so run 07's script re-rm's
# GOTABWM.DEMO/SESSION.TABS/NOTIFY.HIST/SNAPSHOT.BUNDLE and the fixture
# conn budget counts per-iteration legs.
#
# exec-order: assert-proven -- run 07's stage gates anchor on markers
# only the seat or the app prints ('goirc: join #other', 'goirc:
# consent ask', 'gotabwm: notify paint id='); run 07 ends on the
# snapshot marker the seat prints after publishing, run 08 on a
# fixture-answered PRIVMSG, so a program that never ran cannot pass.
#
# HOST PREREQUISITES:
#   bash tools/go/build-web.sh goirc GOIRC --gate -> .build/go/GOIRC-GATE.ELF
#   bash tools/go/build-gotabwm.sh                 -> .build/go/GOTABWM.ELF
#   bash tools/go/build-tabapp.sh                  -> .build/go/GOTABAPP.ELF
# GOIRC-GATE is the virelai_gate_roots build (the GOFETCH-GATE pattern):
# run 07's TLS leg anchors on the pinned fixture root, so the gate
# binary is what every run execs under the GOIRC.ELF name.
# Fixture transcripts land in $RUN_DIR/ircd-<port>.log for the python
# asserts. Run 07's TLS leg wraps the same pinned leaf.example.com
# chain go-fetch-https serves (user/src/lib/tls/vectors/fx).

vgate_name go-irc "M147a+b+c #2801/#2802/#2803: GOIRC.ELF core (register/join/recv/drop/reconnect, consent refusal, 433) + UI legs (mention toast click-through, consent dialog) + K=3 journey (TLS first, consent-stored plaintext, toast, snapshot, restore)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

# The monitor's exec verb packs at most 8 argv slots and the program
# name takes one (max_exec_args); the --flag=value spellings keep each
# leg inside the bound. script-01 relies on --script-expect/--timeout to
# end the leg, so no --max-ms.
vgate_file script-01.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
exec GOIRC.ELF --host=10.0.0.2 --nick=gate --join '#goirc' --plain --retries=3 --backoff-ms=300
EOF

vgate_file script-02.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
exec GOIRC.ELF --host=10.0.0.2 --nick=gate --join '#goirc' --max-ms=30000
EOF

vgate_file script-03.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
exec GOIRC.ELF --host=10.0.0.2 --port=6668 --nick=gate --join '#goirc' --plain --max-ms=60000
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

goirc = os.path.join(".build", "go", "GOIRC-GATE.ELF")
if not os.path.exists(goirc):
    sys.exit("GOIRC-GATE.ELF missing (expected " + goirc + ") - build it "
             "first: bash tools/go/build-web.sh goirc GOIRC --gate")
# The gate-roots build rides under the shipping name: run 07's TLS leg
# validates the pinned fixture chain, and the seat's reopen LIFO re-execs
# 'GOIRC.ELF' regardless.
shutil.copy(goirc, os.path.join(share, "GOIRC.ELF"))
print("go-irc: staged GOIRC-GATE.ELF as GOIRC.ELF (%d)"
      % os.path.getsize(os.path.join(share, "GOIRC.ELF")))

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

# journey (M147c run 07) serves BOTH transports on one port — the
# runner arms a single --net-tcp-respond per VM, so the fixture
# discriminates by first byte: a 0x16 record header is a TLS ClientHello
# (wrapped in a TLS 1.3 responder serving the pinned leaf.example.com
# chain — the same material go-fetch-https's tlsresponder.py runs);
# anything else is plaintext IRC. argv[4]/[5] carry the PEM pair only
# for that mode.
tls_ctx = None
if mode == "journey":
    import ssl
    tls_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    tls_ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    tls_ctx.load_cert_chain(sys.argv[4], sys.argv[5])

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

def pump(conn, idx, nick, buf, on_join, hold=20, first_only=False,
         echo=False, on_privmsg=None):
    """Read commands until close/timeout; on_join(chan) fires per JOIN.
    first_only exits after the first JOIN — that close IS the drop the
    leg asserts. echo answers each client PRIVMSG with alice's
    'thanks' — the conversation's return half (M147c run 07); the
    reply deliberately carries NO nick — a nick-bearing echo would
    paint a second toast on the sending session and the pointer's
    'notify paint' gate could land on it instead of the #other ping's.
    on_privmsg fires once per client PRIVMSG after the echo (the
    journey's delayed-mention hook)."""
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
        elif cmd == "PRIVMSG" and len(parts) > 2:
            if echo:
                send(conn, ":alice!u@h PRIVMSG %s :thanks" % parts[1])
            if on_privmsg is not None:
                on_privmsg()
        elif cmd == "QUIT":
            break

# Conn budgets count EVERY iteration's legs — vgate_repeat 3 replays the
# spec, so rejoin alternates first/drop legs on idx parity and journey
# serves 3 registered conns per iteration (TLS session, consent-armed
# plaintext, the reopen's re-dial) plus slack for stray conns the relay
# layer opens but never registers.
conns = {"rejoin": 6, "nickuse": 3, "mention": 3, "once": 3,
         "journey": 24}[mode]

if mode == "journey":
    import threading
    # M147c run 07 holds THREE live conns at once — the TLS session
    # stays open for the snapshot while the consent session and the
    # reopen's re-dial converse — so the per-conn register+pump is a
    # daemon thread, and the accept loop never stalls behind one leg.
    # Roles come from the REGISTERED order, not the accept index: a
    # conn that dies before NICK/USER (a relay-level probe) consumes
    # nothing.
    jlock = threading.Lock()
    jstate = {"plain": 0, "tls": None, "tls_nick": ""}

    def serve_journey(conn, idx):
        try:
            # Peek the first byte: 0x16 = TLS record header
            # (ClientHello) — wrap it; anything else is plaintext IRC.
            conn.settimeout(60)
            try:
                first = conn.recv(1, socket.MSG_PEEK)
            except socket.timeout:
                first = b""
            wrapped = False
            if first == b"\x16":
                try:
                    conn = tls_ctx.wrap_socket(conn, server_side=True)
                    wrapped = True
                    log("c%d tls ok" % idx)
                except Exception as e:
                    log("c%d tls %s" % (idx, e))
                    try:
                        conn.close()
                    except Exception:
                        pass
                    return
            log("c%d open" % idx)
            nick, buf = register(conn, idx)
            if not nick:
                conn.close()
                return
            with jlock:
                if wrapped:
                    role = "tls"
                    jstate["tls"] = conn
                    jstate["tls_nick"] = nick
                else:
                    jstate["plain"] += 1
                    role = "consent" if jstate["plain"] % 2 == 1 else "reopen"
            log("c%d role %s nick %s" % (idx, role, nick))
            if role == "tls":
                def on_jn(ch, conn=conn):
                    if ch == "#other":
                        # The scrollback flood — the blob's #other scroll
                        # offset is real because these lines exist.
                        for i in range(60):
                            send(conn, ":alice!u@h PRIVMSG #other :filler-%02d backlog" % i)
                    else:
                        send(conn, ":alice!u@h PRIVMSG %s :hello on %s" % (ch, ch))
            elif role == "consent":
                def on_jn(ch, conn=conn):
                    send(conn, ":alice!u@h PRIVMSG %s :welcome to the plain side" % ch)
            else:
                def on_jn(ch, conn=conn):
                    send(conn, ":alice!u@h PRIVMSG %s :restored-tail" % ch)
            # The mention ping rides the consent session's first client
            # PRIVMSG (the typed 'ok'): the toast can only paint once the
            # dialog is answered AND the typed line is on the wire, so
            # the click-through ordering is a fact, not a race. The
            # greetings carry no nick on purpose — the ONLY toast the
            # run paints is this ping's, so --pointer-virtio-after
            # 'notify paint' clicks a live one inside its TTL. The
            # once-flag is PER CONN, not global: the fixture outlives a
            # vgate_repeat iteration, and each iteration's consent leg
            # must ping its own iteration's TLS conn (jstate["tls"] is
            # always the newest wrap) or runs 07-02/07-03 never toast.
            pinged = [False]
            def ping_once():
                with jlock:
                    t, tn = jstate["tls"], jstate["tls_nick"]
                    if t is None or pinged[0]:
                        return
                    pinged[0] = True
                try:
                    send(t, ":alice!u@h PRIVMSG #other :ping %s you there?" % tn)
                except Exception as e:
                    log("c%d ping %s" % (idx, e))
            pump(conn, idx, nick, buf, on_jn, hold=90, echo=True,
                 on_privmsg=ping_once if role == "consent" else None)
        except Exception as e:
            log("c%d serve %s" % (idx, e))
        finally:
            try:
                conn.close()
            except Exception:
                pass
            log("c%d close" % idx)

for idx in range(conns):
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        log("accept timeout at conn %d" % idx)
        break
    if mode == "journey":
        threading.Thread(target=serve_journey, args=(conn, idx),
                         daemon=True).start()
        continue
    conn.settimeout(60)
    log("c%d open" % idx)
    if mode == "rejoin":
        nick, buf = register(conn, idx)
        if not nick:
            conn.close()
            continue
        if idx % 2 == 0:
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

# Run 07's TLS fixture serves the pinned leaf.example.com chain —
# identical to go-fetch-https's responder material; nothing regenerates.
cfx = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
chain = os.path.join(cfx, "chain-ec.pem")
irckey = os.path.join(cfx, "leaf-ec.key")
if not os.path.exists(chain) or not os.path.exists(irckey):
    sys.exit("pinned fixture chain missing under %s" % cfx)

procs = []
for mode, port in (("rejoin", 26667), ("nickuse", 26668),
                   ("mention", 26669), ("once", 26670),
                   ("journey", 26671)):
    subprocess.run(["sh", "-c", "lsof -ti tcp:%d | xargs kill -9" % port],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    logpath = os.path.join(run, "ircd-%d.log" % port)
    log = open(logpath, "w")
    log.close()
    argv = [sys.executable, fixture, mode, str(port), logpath]
    if mode == "journey":
        argv += [chain, irckey]
    proc = subprocess.Popen(argv,
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
# The fixture log accumulates across vgate_repeat iterations — the
# cumulative count is what proves THIS iteration's conns ran. (REPEAT=1
# drops the -NN tag suffix; [-1] reads 1 either way.)
it = int(os.environ["VG_TAG"].rsplit("-", 1)[-1])
log = open(os.path.join(os.environ["RUN_DIR"], "ircd-26667.log")).read()
need = ["c0 open", "c0 rx NICK gate", "c0 rx USER", "c0 rx JOIN #goirc",
        "c1 open", "c1 rx NICK gate", "c1 rx USER", "c1 rx JOIN #goirc",
        "c0 close"]
missing = [n for n in need if n not in log]
if missing:
    sys.exit("fixture transcript missing: %r\n%s" % (missing, log))
joins = sum(1 for l in log.splitlines() if "rx JOIN #goirc" in l)
if joins < 2 * it:
    sys.exit("iteration %d: only %d JOINs on the transcript\n%s" % (it, joins, log))
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

# --- M147c (#2803) runs 07+08: the K=3 acceptance conversation ---------
#
# The card's journey splits across TWO boots — the seat's snapshot arm
# is focus-quiet gated (ctrl-shift-s parks until input AND app settle,
# ~4 ticks) so a snapshot and any later input choreography can never be
# sequenced inside one --input-chords batch; a fresh boot's session
# restore is also the stronger reading of the card's "a snapshot and a
# restore". vgate_repeat 3 replays both runs; each iteration is
# self-cleaning (run 07's script re-rms the session files and the
# journey fixture serves BOTH runs' conns on its shared port).
#
# Run 07 — the conversation boot:
#   TLS first           script2 execs GOIRC --ui --tls --sni
#                       leaf.example.com with the positional shorthand
#                       -- 'goirc: dial 10.0.0.2 6667 tls' lands before
#                       any consent ask.
#   plaintext after     script3 (gated on 'goirc: join #other') execs a
#   consent             second GOIRC --ui on the SAME responder port
#                       with no --plain: 'consent ask' -> chords
#                       'tab,return' -> 'consent yes' -> 'state saved'
#                       (the seat's kind-20 ack) -> 'dial 6667 plain'.
#                       (One VM arms ONE --net-tcp-respond, so the
#                       fixture's first-byte peek splits TLS from
#                       plaintext on the shared port.)
#   conversation        'o,k,return' submits 'ok' on the plain
#                       session's #goirc (still focused pre-click);
#                       the fixture echoes 'thanks' (no nick -- a
#                       nick-bearing echo would paint a second toast
#                       and the 'notify paint' gate could land on it) --
#                       both directions on the wire.
#   mention toast       the consent conn's first client PRIVMSG (the
#                       'ok') is what makes the fixture ping the nick
#                       on the TLS session's #other — the toast can
#                       only paint once the dialog is answered AND the
#                       typed line is on the wire, so the click's
#                       ordering is a fact, not a race. Greetings carry
#                       no nick: 'notify paint' is this ping's alone.
#   blur +              the SECOND declare stole focus earlier
#   click-through       ('goirc: blur' — a real window steal, not a
#                       seat chord); the pointer batch, gated on
#                       'notify paint', presses the toast centre
#                       (112,702) inside its TTL: 'notify dismiss' ->
#                       refocus -> the pending mention lands
#                       'goirc: focus #other'.
#   snapshot            the post-click pageups scroll the flooded
#                       #other (real scroll state), then ctrl-shift-s
#                       parks: at quiet 'state ask id=' -> 'state
#                       save id=' -> 'snapshot saved' — SESSION.TABS +
#                       the app_state trailer land inside
#                       SNAPSHOT.BUNDLE (the python decode below).
#                       The TLS row's blob also carries the --sni
#                       verify name (ircState v2): the re-exec has no
#                       argv, so without it the restored dial would
#                       validate the pinned chain against the raw IP
#                       and fail hostname_mismatch.
#
# Run 08 — the restore boot:
#   session restore     SESSION.TABS (written by run 07's snapshot —
#                       the script does NOT rm it) makes the seat
#                       re-exec both rows bare: 'session load n=2
#                       mode=restore' -> 2x 'state restored' -> each
#                       blob supplies host/port/sni/nick/channels/
#                       consent argv never carried. The TLS row re-dials
#                       tls,
#                       the consent row dials plain WITHOUT a second
#                       ask ('consent ask' is ABSENT this run) ->
#                       rejoin #goirc -> the fixture's second
#                       registered plaintext conn answers
#                       'restored-tail' (terminal).
#   scrollback/channels live: 'focus #goirc' post-restore + the
#    intact             fixture transcript roles. Byte-level: run 07's
#                       bundle trailer decodes to two ircState blobs —
#                       TLS carries {#goirc,#other}, focus #other and a
#                       nonzero scroll; plain carries the consent bit.
#
# The restore path is what the GOIRC declare-title change is for: the
# seat re-execs the bin with no argv, so the app declares 'GOIRC.ELF'
# (guessBin's default arm), repaints its rail label via SetTabTitle,
# and a zero-arg launch falls into runUI where the staged blob supplies
# every field argv would have carried.
vgate_file script-07.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
vf rm SNAPSHOT.BUNDLE
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

# The monitor's exec verb packs at most 8 argv slots: the TLS leg rides
# the positional shorthand (<host> <nick> #chan ...) + the default 6667,
# so the only flags it needs are --ui/--tls/--sni.
vgate_file script2-07.txt <<'EOF'
dui focus 0
exec GOIRC.ELF --ui --tls --sni=leaf.example.com 10.0.0.2 gate '#goirc' '#other'
EOF

vgate_file script3-07.txt <<'EOF'
exec GOIRC.ELF --ui --host=10.0.0.2 --nick=gate --join '#goirc'
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio \
    --net '$RUN_DIR/cap07.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:6667:relay --net-tcp-respond-relay 127.0.0.1:26671 \
    --script '$RUN_DIR/script-07.txt' \
    --script2 '$RUN_DIR/script2-07.txt' --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-07.txt' --script3-after 'goirc: join #other' \
    --input-chords 'tab,return,pageup,pageup,pageup,pageup,o,k,return,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,pageup,ctrl-shift-s' \
    --input-chords-after 'goirc: consent ask' \
    --pointer-virtio '112,702,d;112,702,u' \
    --pointer-virtio-after 'gotabwm: notify paint id=' \
    --script-expect 'gotabwm: snapshot saved bytes=' --timeout 300

vgate_assert 07 serial-contains 'gotabwm: mode live'
vgate_assert 07 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 07 serial-count 'goirc: open id=' 2
vgate_assert 07 serial-count 'goirc: declare accepted' 2
vgate_assert 07 serial-contains 'goirc: dial 10.0.0.2 6667 tls'
vgate_assert 07 serial-exact 'goirc: consent ask' 1
vgate_assert 07 serial-contains 'goirc: consent yes'
vgate_assert 07 serial-contains 'goirc: state saved'
vgate_assert 07 serial-contains 'goirc: dial 10.0.0.2 6667 plain'
vgate_assert 07 serial-count 'goirc: registered nick=gate' 2
vgate_assert 07 serial-count 'goirc: join #goirc' 2
vgate_assert 07 serial-contains 'goirc: join #other'
vgate_assert 07 serial-contains 'goirc: msg #other alice filler-00 backlog'
vgate_assert 07 serial-contains 'goirc: msg #other alice ping gate you there?'
vgate_assert 07 serial-contains 'goirc: toast #other'
vgate_assert 07 serial-absent 'goirc: toast-refused'
vgate_assert 07 serial-contains 'gotabwm: notify paint id='
vgate_assert 07 serial-count 'goirc: blur' 2
vgate_assert 07 serial-contains 'gotabwm: notify dismiss id='
vgate_assert 07 serial-contains 'gotabwm: tab focus id='
vgate_assert 07 serial-contains 'goirc: focus #other'
vgate_assert 07 serial-contains 'goirc: line ok'
vgate_assert 07 serial-contains 'alice thanks'
vgate_assert 07 serial-contains 'gotabwm: state ask id='
vgate_assert 07 serial-contains 'gotabwm: state save id='
vgate_assert 07 serial-contains 'gotabwm: snapshot saved bytes='
vgate_assert 07 serial-absent 'goirc: consent no'
vgate_assert 07 serial-absent 'goirc: refuse plaintext'
vgate_assert 07 serial-absent 'goirc: state refused'
vgate_assert 07 serial-absent 'goirc: error'
vgate_assert 07 serial-absent '[EXC] parking:'
# Order: TLS must dial BEFORE the consent ask, the plain dial only after
# consent yes; the typed 'ok' precedes the toast (the fixture sends the
# ping in answer to it); the toast chain runs paint -> dismiss ->
# refocus -> land; the snapshot arm fires only after input goes quiet.
vgate_assert 07 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def after(markers):
    pos = 0
    for m in markers:
        i = ser.find(m, pos)
        if i < 0:
            sys.exit("marker %r missing after pos %d" % (m, pos))
        pos = i + len(m)

after(["goirc: dial 10.0.0.2 6667 tls", "goirc: consent ask",
       "goirc: consent yes", "goirc: state saved",
       "goirc: dial 10.0.0.2 6667 plain"])
after(["goirc: line ok", "goirc: msg #goirc alice thanks"])
after(["gotabwm: notify paint id=", "gotabwm: notify dismiss id=",
       "gotabwm: tab focus id=", "goirc: focus #other"])
after(["gotabwm: state ask id=", "gotabwm: snapshot saved bytes="])

# Fixture transcript: one port, three roles across runs 07+08 — the
# TLS conn (peek-wrapped) saw the register+joins, the consent conn took
# the typed 'ok', and the ping crossed onto the TLS conn.
tag = os.environ["VG_TAG"]
it = int(tag.rsplit("-", 1)[-1]) if "-" in tag else 1
log = open(os.path.join(os.environ["RUN_DIR"], "ircd-26671.log")).read()
need = ["tls ok", "role tls", "role consent", "rx JOIN #other",
        "tx :alice!u@h PRIVMSG #other :ping gate",
        "rx PRIVMSG #goirc :ok",
        "tx :alice!u@h PRIVMSG #goirc :thanks"]
missing = [n for n in need if n not in log]
opens = sum(1 for l in log.splitlines() if l.rstrip().endswith(" open"))
if opens < 2 * it:
    missing.append("opens %d < 2*iteration %d" % (opens, it))
if missing:
    sys.exit("journey fixture missing: %r\n%s" % (missing, log))
PY

# The snapshot's session trailer IS the scrollback/channels evidence:
# decode SNAPSHOT.BUNDLE -> 'session' entry -> .tabs v2 + the app_state
# trailer -> two ircState v1 blobs. The TLS blob carries {#goirc,#other},
# focus #other and a real scroll offset; the plain blob carries the
# consent bit + #goirc. This is the byte-level half of 'intact'.
vgate_assert 07 python <<'PY'
import os, struct, sys
share = os.environ["VG_SHARE"]
raw = open(os.path.join(share, "SNAPSHOT.BUNDLE"), "rb").read()
line, raw = raw.split(b"\n", 1)
if not line.startswith(b"#vb1 "):
    sys.exit("bundle header %r" % line)
want = int(line.split()[1])
entries = {}
for _ in range(want):
    hdr, raw = raw.split(b"\n", 1)
    name, n = hdr.split()
    entries[name.decode()] = raw[: int(n)]
    raw = raw[int(n):]
sess = entries["session"]
if sess[0] != 2:
    sys.exit("session not .tabs v2")
n = sess[2]
if n != 2:
    sys.exit("expected 2 tab records, got %d" % n)
t = sess[6 + 69 * n :]
if t[:2] != b"AS" or t[2] != 1:
    sys.exit("bad app_state trailer magic %r" % t[:4])
blobs = []
off = 6
for _ in range(t[3]):
    idx, appver, ln = t[off], t[off+1], struct.unpack("<I", t[off+4:off+8])[0]
    blobs.append((idx, appver, t[off+8 : off+8+ln]))
    off += 8 + ln
if len(blobs) != 2:
    sys.exit("expected 2 app_state blobs, got %d" % len(blobs))

def ircstate(b):
    if b[0] != 2:
        sys.exit("ircState ver %d" % b[0])
    o = 2
    def u16():
        nonlocal o
        v = struct.unpack("<H", b[o:o+2])[0]
        o += 2
        return v
    def s():
        nonlocal o
        n = u16()
        v = b[o:o+n].decode()
        o += n
        return v
    host = s(); port = u16(); sni = s(); nick = s(); focus = s()
    chans = {}
    for _ in range(u16()):
        chans[s()] = struct.unpack("<I", b[o:o+4])[0]; o += 4
    return dict(flags=b[1], host=host, port=port, sni=sni, nick=nick,
                focus=focus, chans=chans)

states = [ircstate(b) for _, _, b in blobs]
# One port carries both transports — discriminate by the flags word
# (bit0 tls / bit1 consent), not the port.
tls = [s for s in states if s["flags"] & 1]
plain = [s for s in states if not s["flags"] & 1]
if len(tls) != 1 or len(plain) != 1:
    sys.exit("blob flags: %r" % [s["flags"] for s in states])
tls, plain = tls[0], plain[0]
if tls["port"] != 6667 or plain["port"] != 6667:
    sys.exit("blob ports: %r %r" % (tls["port"], plain["port"]))
if not tls["flags"] & 1:
    sys.exit("tls blob missing the tls bit: %r" % tls)
if tls["sni"] != "leaf.example.com":
    sys.exit("tls blob sni %r" % tls["sni"])
if tls["chans"].keys() != {"", "#goirc", "#other"}:
    sys.exit("tls blob chans %r" % tls["chans"])
if tls["focus"] != "#other" or tls["chans"]["#other"] == 0:
    sys.exit("tls blob focus/scroll %r %r" % (tls["focus"], tls["chans"]))
if not plain["flags"] & 2:
    sys.exit("plain blob missing the consent bit: %r" % plain)
if plain["chans"].keys() != {"", "#goirc"} or plain["focus"] != "#goirc":
    sys.exit("plain blob %r" % plain)
print("run07 bundle: tls chans=%r scroll=%d focus=%r; plain consent+chans=%r"
      % (sorted(tls["chans"]), tls["chans"]["#other"], tls["focus"],
         sorted(plain["chans"])))
PY

# --- run 08: the restore boot ------------------------------------------
#
# No session-file rm's here: SESSION.TABS from run 07's snapshot IS the
# leg. The seat restores the strip and re-execs both rows bare; each
# app's staged blob supplies host/port/transport/nick/channels/consent
# that argv never carried, so the consent row dials plain WITHOUT
# re-asking — 'consent ask' must stay absent the whole run.
vgate_file script-08.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --via-virtio \
    --net '$RUN_DIR/cap08.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:6667:relay --net-tcp-respond-relay 127.0.0.1:26671 \
    --script '$RUN_DIR/script-08.txt' \
    --script-expect 'goirc: msg #other alice filler-59 backlog' --timeout 300

vgate_assert 08 serial-contains 'gotabwm: mode live'
vgate_assert 08 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 08 serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert 08 serial-contains 'gotabwm: session reexec n=2'
vgate_assert 08 serial-count 'gotabwm: session exec GOIRC.ELF' 2
vgate_assert 08 serial-count 'goirc: open id=' 2
vgate_assert 08 serial-count 'goirc: declare accepted' 2
vgate_assert 08 serial-count 'goirc: state restored' 2
vgate_assert 08 serial-contains 'goirc: dial 10.0.0.2 6667 tls'
vgate_assert 08 serial-contains 'goirc: dial 10.0.0.2 6667 plain'
vgate_assert 08 serial-absent 'goirc: consent ask'
vgate_assert 08 serial-count 'goirc: registered nick=gate' 2
vgate_assert 08 serial-count 'goirc: join #goirc' 2
vgate_assert 08 serial-contains 'goirc: join #other'
vgate_assert 08 serial-contains 'goirc: focus #goirc'
vgate_assert 08 serial-contains 'goirc: msg #goirc alice restored-tail'
vgate_assert 08 serial-absent 'goirc: refuse plaintext'
vgate_assert 08 serial-absent 'goirc: state refused'
vgate_assert 08 serial-absent 'goirc: error'
vgate_assert 08 serial-absent '[EXC] parking:'
# Order: the restore precedes every dial, and the plain session's join
# earns the fixture's 'restored-tail' (the role-2 conn).
vgate_assert 08 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
pos = 0
for m in ["gotabwm: session load n=2 mode=restore", "goirc: state restored",
          "goirc: dial 10.0.0.2 6667 plain", "goirc: join #goirc",
          "goirc: msg #goirc alice restored-tail"]:
    i = ser.find(m, pos)
    if i < 0:
        sys.exit("marker %r missing after pos %d" % (m, pos))
    pos = i + len(m)

# Fixture transcript (cumulative): the reopened conn took the 'reopen'
# role and answered 'restored-tail'; each iteration's two boots each
# wrap one TLS conn.
tag = os.environ["VG_TAG"]
it = int(tag.rsplit("-", 1)[-1]) if "-" in tag else 1
log = open(os.path.join(os.environ["RUN_DIR"], "ircd-26671.log")).read()
need = ["role reopen", "tx :alice!u@h PRIVMSG #goirc :restored-tail"]
missing = [n for n in need if n not in log]
tls = sum(1 for l in log.splitlines() if "tls ok" in l)
if tls < 2 * it:
    missing.append("tls wraps %d < 2*iteration %d" % (tls, it))
if missing:
    sys.exit("journey fixture missing: %r\n%s" % (missing, log))
PY
