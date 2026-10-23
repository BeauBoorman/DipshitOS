# go-mail.spec -- M187c #3184 + M193a #3253: GOMAIL.ELF — the smallest
# honest mail client: IMAP4rev1 LIST/SELECT/FETCH (boxes, bounded
# headers, one readable body) + SMTP submit, over tls.Dial with the
# pinned fixture chain, plaintext only behind the consent bit, named
# refusals for everything else — and now a bounded local cache under
# /host/MAIL/ (folders + envelopes + last-N bodies, LRU) that `use`
# writes and `search`/offline legs read. Host Python fixture = the
# go-irc pattern: a scripted server on 127.0.0.1 behind
# --net-tcp-respond ...:relay; no live net.
#
# Run 01 is the card leg: the GOMAIL.TXT account file resolves host/
# creds/sni, --tls dials 993, and `fetch INBOX 1 2 3` walks the whole
# journey in one session — LIST, SELECT (3 EXISTS), the bounded
# ENVELOPE list, a text/plain body read verbatim, a text/html body
# rendered stripped, and a multipart whose application/pdf attachment
# lists by name and refuses to open — while the cache write-through
# lands on the share. Run 02 submits one plaintext message over
# SMTP+TLS (AUTH PLAIN, dot-stuffed DATA). Run 03 asks for plaintext
# without consent — 'gomail: refuse plaintext' before any dial. Run 04
# is the consent answer: --plain dials 143 and fetches. Runs 05/06 are
# the folder legs: `use Sent` LISTs, SELECTs and remembers; `use Lists`
# refuses a name the real LIST never carried even though the seeded
# cache remembers it. Runs 07/08 are the search legs: seeded-cache
# header and body hits with no dial at all. Run 09 is the cache-miss
# leg: a dead transport names itself offline, paints remembered rows,
# and refuses seq 9 by name; run 10 serves a remembered body offline.
#
# exec-order: assert-proven — runs end on markers only the app prints
# from fixture traffic ('gomail: refuse attachment report.pdf',
# 'gomail: sent bytes='), and the python halves read the fixture's own
# transcript of the wire bytes.
#
# HOST PREREQUISITES:
#   bash tools/go/build-web.sh gomail GOMAIL --gate -> .build/go/GOMAIL-GATE.ELF
# GOMAIL-GATE is the virelai_gate_roots build (the GOIRC-GATE pattern):
# the TLS legs anchor on the pinned leaf.example.com chain, so the gate
# binary is what every run execs under the GOMAIL.ELF name. Fixture
# transcripts land in $RUN_DIR/maild-<port>.log for the python asserts.

vgate_name go-mail "M187c #3184 + M193a #3253: GOMAIL.ELF — IMAP4 fetch/list/read + SMTP submit over tls.Dial (pinned fixture chain), plaintext consent refusal + grant, attachment/html truth-in-bounds, + use-able folders, bounded /host/MAIL cache, offline search + cache-miss legs"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# The monitor's exec verb packs at most 8 argv slots and the program
# name takes one (max_exec_args); every leg stays inside the bound
# because the account file carries host/user/pass/from/sni.
vgate_file script-01.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOMAIL.ELF --tls fetch INBOX 1 2 3
EOF

vgate_file script-02.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOMAIL.ELF --tls send --to=alice@fixture.local --subject=gate-one --body=see-the-report
EOF

vgate_file script-03.txt <<'EOF'
exec GOMAIL.ELF fetch INBOX
EOF

vgate_file script-04.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOMAIL.ELF --plain fetch INBOX 1
EOF

vgate_file script-05.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOMAIL.ELF --tls use Sent
EOF

vgate_file script-06.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOMAIL.ELF --tls use Lists
EOF

# Runs 07/08 carry no net lines at all: search is a cache read and must
# never dial.
vgate_file script-07.txt <<'EOF'
exec GOMAIL.ELF search weekly
EOF

vgate_file script-08.txt <<'EOF'
exec GOMAIL.ELF search orchid
EOF

# Runs 09/10 ask for TLS with no net configured: the dial fails and the
# verb answers from the cache — hit and miss both named.
vgate_file script-09.txt <<'EOF'
exec GOMAIL.ELF --tls fetch INBOX 9
EOF

vgate_file script-10.txt <<'EOF'
exec GOMAIL.ELF --tls read INBOX 1
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

gomail = os.path.join(".build", "go", "GOMAIL-GATE.ELF")
if not os.path.exists(gomail):
    sys.exit("GOMAIL-GATE.ELF missing (expected " + gomail + ") - build it "
             "first: bash tools/go/build-web.sh gomail GOMAIL --gate")
# The gate-roots build rides under the shipping name: the TLS legs
# validate the pinned leaf.example.com chain.
shutil.copy(gomail, os.path.join(share, "GOMAIL.ELF"))
print("go-mail: staged GOMAIL-GATE.ELF as GOMAIL.ELF (%d)"
      % os.path.getsize(os.path.join(share, "GOMAIL.ELF")))

# The account file the app resolves at boot — deliberately WITHOUT a
# tls/plain row: run 03's bare fetch must hit the plaintext refusal, so
# the file never carries a transport answer and each leg's flag decides.
with open(os.path.join(share, "GOMAIL.TXT"), "w") as f:
    f.write("# go-mail gate fixture account\n"
            "host=10.0.0.2\n"
            "user=gate\n"
            "pass=gate-pass\n"
            "from=gate@fixture.local\n"
            "sni=leaf.example.com\n")
print("go-mail: wrote GOMAIL.TXT account file")

# M193a seed: remembered mail under /host/MAIL/ — the cache files the
# app's own codec reads. 'Lists' exists ONLY here: the wire LIST never
# carries it, so run 06's `use Lists` proves `use` trusts the real LIST
# over the cache, while runs 07/08 prove search reads the seeded corpus
# and run 09 proves a miss names itself instead of fabricating.
maildir = os.path.join(share, "MAIL")
os.makedirs(maildir, exist_ok=True)
with open(os.path.join(maildir, "BOXES"), "w") as f:
    f.write("INBOX\nSent\nLists\n")
with open(os.path.join(maildir, "HDRS"), "w") as f:
    f.write("Lists\t7\tdana@fixture.local\tweekly digest\t"
            "Wed, 21 Oct 2026 11:00:00 +0000\n")
seed_body = b"the orchid thread grows\r\nsecond seeded line"
with open(os.path.join(maildir, "BODIES"), "wb") as f:
    f.write(b"@Lists\t9\t1\ttext/plain\t" + str(len(seed_body)).encode()
            + b"\n" + seed_body + b"\n")
print("go-mail: seeded /host/MAIL cache (BOXES, Lists hdr 7, body 9)")

fixture = os.path.join(run, "maild.py")
with open(fixture, "w") as f:
    f.write('''
import socket, sys, time

mode, port, logpath = sys.argv[1], int(sys.argv[2]), sys.argv[3]
logf = open(logpath, "w", buffering=1)

def log(s):
    logf.write(s + "\\n")

# mode: "imap-tls" | "imap-plain" | "smtp-tls" | "smtp-plain" — one VM
# arms ONE --net-tcp-respond, so each run gets its own fixture leg on
# its own port. TLS wraps with the pinned leaf.example.com chain (the
# same material go-irc's journey leg serves).
proto, _, transport = mode.partition("-")
ctx = None
if transport == "tls":
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(sys.argv[4], sys.argv[5])

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(4)
srv.settimeout(1800)
log("listening mode=" + mode)

def send(conn, line):
    conn.sendall(line.encode() + b"\\r\\n")
    log("tx " + line)

def sendlit(conn, seq, key, payload):
    # '* n FETCH (BODY[s] {n}CRLF<payload>)' — the literal is inline in
    # the record; the closing paren rides the post-literal line.
    head = "* %d FETCH (%s {%d}" % (seq, key, len(payload))
    conn.sendall(head.encode() + b"\\r\\n" + payload + b")\\r\\n")
    log("tx " + head + " <lit %d> )" % len(payload))

def recvline(conn, buf):
    while b"\\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return None, buf
        buf += chunk
    line, buf = buf.split(b"\\n", 1)
    return line.decode("utf-8", "replace").rstrip("\\r"), buf

# The three fixture messages: a text/plain, a text/html (the client
# renders it stripped), and a multipart/mixed whose application/pdf
# attachment lists by name and refuses to open.
B1 = b"line one of the gate body\\r\\nsecond line\\r\\nthird line"
B2 = b"<html><body><p>html <b>hello</b> fixture</p></body></html>"
B3 = b"see the attached report"
MSGS = {
    1: dict(
        env="\\"Wed, 21 Oct 2026 10:00:00 +0000\\" \\"gate hello\\" "
            "((\\"Alice\\" NIL \\"alice\\" \\"fixture.local\\")) NIL NIL NIL NIL NIL NIL "
            "\\"<m1@fixture.local>\\"",
        bs="(\\"TEXT\\" \\"PLAIN\\" (\\"CHARSET\\" \\"US-ASCII\\") NIL NIL \\"7BIT\\" %d 3)" % len(B1),
        parts={"TEXT": B1, "1": B1}),
    2: dict(
        env="\\"Wed, 21 Oct 2026 10:05:00 +0000\\" \\"html issue\\" "
            "((NIL NIL \\"bob\\" \\"fixture.local\\")) NIL NIL NIL NIL NIL NIL "
            "\\"<m2@fixture.local>\\"",
        bs="(\\"TEXT\\" \\"HTML\\" (\\"CHARSET\\" \\"UTF-8\\") NIL NIL \\"7BIT\\" %d 1)" % len(B2),
        parts={"TEXT": B2, "1": B2}),
    3: dict(
        env="\\"Wed, 21 Oct 2026 10:10:00 +0000\\" \\"report attached\\" "
            "((\\"Carol\\" NIL \\"carol\\" \\"fixture.local\\")) NIL NIL NIL NIL NIL NIL "
            "\\"<m3@fixture.local>\\"",
        bs="((\\"TEXT\\" \\"PLAIN\\" (\\"CHARSET\\" \\"US-ASCII\\") NIL NIL \\"7BIT\\" %d 1) "
           "(\\"APPLICATION\\" \\"PDF\\" NIL NIL NIL \\"BASE64\\" 2048 NIL "
           "(\\"attachment\\" (\\"filename\\" \\"report.pdf\\")) NIL NIL) \\"MIXED\\")" % len(B3),
        parts={"1": B3, "TEXT": B3}),
}

def imap_serve(conn, idx):
    send(conn, "* OK fixture IMAP4rev1 ready")
    buf = b""
    deadline = time.time() + 120
    while time.time() < deadline:
        conn.settimeout(max(1.0, deadline - time.time()))
        try:
            line, buf = recvline(conn, buf)
        except socket.timeout:
            break
        if line is None:
            break
        log("c%d rx %s" % (idx, line))
        parts = line.split(" ", 2)
        if len(parts) < 2 or not parts[0].startswith("a"):
            continue
        tag, verb = parts[0], parts[1].upper()
        rest = parts[2] if len(parts) > 2 else ""
        if verb == "LOGIN":
            send(conn, tag + " OK Login completed")
        elif verb == "LIST":
            send(conn, "* LIST (\\\\HasNoChildren) \\"/\\" \\"INBOX\\"")
            send(conn, "* LIST (\\\\HasNoChildren) \\"/\\" \\"Sent\\"")
            send(conn, tag + " OK List completed")
        elif verb == "SELECT":
            send(conn, "* 3 EXISTS")
            send(conn, "* 1 RECENT")
            send(conn, "* FLAGS (\\\\Seen \\\\Answered \\\\Draft)")
            send(conn, "* OK [UIDVALIDITY 7] UIDs valid")
            send(conn, tag + " OK [READ-WRITE] Select completed")
        elif verb == "FETCH":
            # rest: "<set> (<items>)" — set is one seq or a:b.
            spec, _, items = rest.partition(" ")
            items = items.strip()
            seqs = []
            if ":" in spec:
                a, _, b = spec.partition(":")
                seqs = range(int(a), int(b) + 1)
            else:
                seqs = [int(spec)]
            for seq in seqs:
                m = MSGS.get(seq)
                if m is None:
                    continue
                if "ENVELOPE" in items:
                    send(conn, "* %d FETCH (ENVELOPE (%s))" % (seq, m["env"]))
                elif "BODYSTRUCTURE" in items:
                    send(conn, "* %d FETCH (BODYSTRUCTURE %s)" % (seq, m["bs"]))
                elif "BODY[" in items:
                    section = items.split("BODY[", 1)[1].split("]", 1)[0]
                    payload = m["parts"].get(section, b"")
                    sendlit(conn, seq, items.strip("()"), payload)
            send(conn, tag + " OK Fetch completed")
        elif verb == "LOGOUT":
            send(conn, "* BYE fixture logging out")
            send(conn, tag + " OK Logout completed")
            return

def smtp_serve(conn, idx):
    send(conn, "220 fixture ESMTP ready")
    buf = b""
    data = False
    deadline = time.time() + 120
    while time.time() < deadline:
        conn.settimeout(max(1.0, deadline - time.time()))
        try:
            line, buf = recvline(conn, buf)
        except socket.timeout:
            break
        if line is None:
            break
        log("c%d rx %s" % (idx, line))
        if data:
            if line == ".":
                data = False
                send(conn, "250 2.0.0 queued as m001")
            continue
        verb = line.split(" ", 1)[0].upper()
        if verb == "EHLO" or verb == "HELO":
            send(conn, "250-fixture greets virelai")
            send(conn, "250 AUTH PLAIN")
        elif verb == "AUTH":
            send(conn, "235 2.7.0 authenticated")
        elif verb == "MAIL":
            send(conn, "250 2.1.0 sender ok")
        elif verb == "RCPT":
            send(conn, "250 2.1.5 rcpt ok")
        elif verb == "DATA":
            send(conn, "354 end with <CR><LF>.<CR><LF>")
            data = True
        elif verb == "QUIT":
            send(conn, "221 2.0.0 bye")
            return
        else:
            send(conn, "502 5.5.2 verb not implemented")

conns = 4
for idx in range(conns):
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        log("accept timeout at conn %d" % idx)
        break
    conn.settimeout(60)
    if ctx is not None:
        try:
            conn = ctx.wrap_socket(conn, server_side=True)
            log("c%d tls ok" % idx)
        except Exception as e:
            log("c%d tls %s" % (idx, e))
            try:
                conn.close()
            except Exception:
                pass
            continue
    log("c%d open" % idx)
    try:
        if proto == "imap":
            imap_serve(conn, idx)
        else:
            smtp_serve(conn, idx)
    except Exception as e:
        log("c%d serve %s" % (idx, e))
    try:
        conn.close()
    except Exception:
        pass
    log("c%d close" % idx)

srv.close()
log("fixture done")
''')

# The TLS legs serve the pinned leaf.example.com chain — identical to
# go-irc's journey material; nothing regenerates.
cfx = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
chain = os.path.join(cfx, "chain-ec.pem")
mailkey = os.path.join(cfx, "leaf-ec.key")
if not os.path.exists(chain) or not os.path.exists(mailkey):
    sys.exit("pinned fixture chain missing under %s" % cfx)

procs = []
for mode, port in (("imap-tls", 26993), ("smtp-tls", 26465),
                   ("imap-plain", 26143)):
    subprocess.run(["sh", "-c", "lsof -ti tcp:%d | xargs kill -9" % port],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    logpath = os.path.join(run, "maild-%d.log" % port)
    log = open(logpath, "w")
    log.close()
    argv = [sys.executable, fixture, mode, str(port), logpath]
    if mode.endswith("-tls"):
        argv += [chain, mailkey]
    proc = subprocess.Popen(argv,
                            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                            start_new_session=True)
    procs.append(proc)
    print("go-mail: fixture %s pid=%d on 127.0.0.1:%d" % (mode, proc.pid, port))

time.sleep(0.4)
for proc in procs:
    if proc.poll() is not None:
        sys.exit("go-mail: fixture exited early rc=%s" % proc.returncode)
PY

# --- Run 01: the card leg — IMAP4+TLS fetch/list/read journey ---------
#
# 'fetch INBOX 1 2 3' over the gate-roots TLS dial: account file ->
# LIST two boxes -> SELECT 3 EXISTS -> the bounded ENVELOPE list ->
# seq 1 text/plain verbatim, seq 2 text/html rendered stripped, seq 3
# multipart whose report.pdf attachment lists by name and refuses.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --net '$RUN_DIR/cap01.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:993:relay --net-tcp-respond-relay 127.0.0.1:26993 \
    --script '$RUN_DIR/script-01.txt' --script-expect 'gomail: closed' --timeout 240

vgate_assert 01 serial-contains 'gomail: account /host/GOMAIL.TXT'
vgate_assert 01 serial-contains 'gomail: dial 10.0.0.2 993 tls'
vgate_assert 01 serial-contains 'gomail: imap ready'
vgate_assert 01 serial-contains 'gomail: login gate'
vgate_assert 01 serial-contains 'gomail: box INBOX'
vgate_assert 01 serial-contains 'gomail: box Sent'
vgate_assert 01 serial-contains 'gomail: select INBOX exists=3'
vgate_assert 01 serial-contains 'gomail: hdr 1 Alice: gate hello'
vgate_assert 01 serial-contains 'gomail: hdr 2 bob@fixture.local: html issue'
vgate_assert 01 serial-contains 'gomail: hdr 3 Carol: report attached'
vgate_assert 01 serial-contains 'gomail: body 1 text/plain'
vgate_assert 01 serial-contains 'gomail: text line one of the gate body'
vgate_assert 01 serial-contains 'gomail: html-stripped 2'
vgate_assert 01 serial-contains 'gomail: text html hello fixture'
vgate_assert 01 serial-contains 'gomail: body 3 text/plain'
vgate_assert 01 serial-contains 'gomail: attach 3 report.pdf application/pdf'
vgate_assert 01 serial-contains 'gomail: refuse attachment report.pdf'
vgate_assert 01 serial-contains 'gomail: closed'
vgate_assert 01 serial-contains 'gomail: cache /host/MAIL/BOXES'
vgate_assert 01 serial-contains 'gomail: cache /host/MAIL/HDRS'
vgate_assert 01 serial-contains 'gomail: cache /host/MAIL/BODIES'
vgate_assert 01 serial-absent 'gomail: error'
vgate_assert 01 serial-absent 'gomail: refuse plaintext'
vgate_assert 01 serial-absent 'gomail: cache-fail'
vgate_assert 01 serial-absent '[EXC] parking:'
# The cache really landed: the share holds the folders, the envelopes,
# and the bodies the wire just proved.
vgate_assert 01 share-contains MAIL/BOXES 'INBOX'
vgate_assert 01 share-contains MAIL/HDRS 'gate hello'
vgate_assert 01 share-contains MAIL/BODIES 'line one of the gate body'
# The wire half: the fixture transcript carries the exact tagged
# commands — a program that never ran cannot produce them.
vgate_assert 01 python <<'PY'
import os, sys
log = open(os.path.join(os.environ["RUN_DIR"], "maild-26993.log")).read()
need = ["c0 tls ok", "c0 rx a1 LOGIN", "c0 rx a2 LIST", "c0 rx a3 SELECT",
        "c0 rx a4 FETCH 1:3 (ENVELOPE)",
        "c0 rx a5 FETCH 1 (BODYSTRUCTURE)", "c0 rx a6 FETCH 1 (BODY[TEXT])",
        "FETCH 2 (BODYSTRUCTURE)", "FETCH 2 (BODY[TEXT])",
        "FETCH 3 (BODYSTRUCTURE)", "FETCH 3 (BODY[1])",
        "rx a11 LOGOUT"]
missing = [n for n in need if n not in log]
if missing:
    sys.exit("imap fixture transcript missing: %r\n%s" % (missing, log))
PY

# --- Run 02: SMTP+TLS submit -------------------------------------------
#
# One plaintext message: greeting -> EHLO -> AUTH PLAIN -> MAIL/RCPT ->
# dot-stuffed DATA -> 250 queued -> QUIT.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio \
    --net '$RUN_DIR/cap02.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:465:relay --net-tcp-respond-relay 127.0.0.1:26465 \
    --script '$RUN_DIR/script-02.txt' --script-expect 'gomail: sent bytes=' --timeout 240

vgate_assert 02 serial-contains 'gomail: account /host/GOMAIL.TXT'
vgate_assert 02 serial-contains 'gomail: dial 10.0.0.2 465 tls'
vgate_assert 02 serial-contains 'gomail: smtp ready'
vgate_assert 02 serial-contains 'gomail: mail gate@fixture.local'
vgate_assert 02 serial-contains 'gomail: rcpt alice@fixture.local'
vgate_assert 02 serial-contains 'gomail: sent bytes='
vgate_assert 02 serial-contains 'gomail: closed'
vgate_assert 02 serial-absent 'gomail: error'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, sys
log = open(os.path.join(os.environ["RUN_DIR"], "maild-26465.log")).read()
need = ["c0 tls ok", "c0 rx EHLO virelai",
        "c0 rx AUTH PLAIN AGdhdGUAZ2F0ZS1wYXNz",
        "c0 rx MAIL FROM:<gate@fixture.local>",
        "c0 rx RCPT TO:<alice@fixture.local>",
        "c0 rx DATA", "c0 rx Subject: gate-one",
        "c0 rx see-the-report", "c0 rx .", "c0 rx QUIT",
        "tx 250 2.0.0 queued as m001"]
missing = [n for n in need if n not in log]
if missing:
    sys.exit("smtp fixture transcript missing: %r\n%s" % (missing, log))
PY

# --- Run 03: plaintext without consent refuses by name -----------------
#
# GOMAIL.TXT carries no transport answer and the exec has no flag, so
# the request is plaintext and unconsented: the named refusal prints
# BEFORE any dial — no socket, no fixture traffic, no net config.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script-03.txt' --script-expect 'gomail: refuse plaintext' --timeout 180

vgate_assert 03 serial-contains 'gomail: refuse plaintext'
vgate_assert 03 serial-contains 'gomail: closed'
vgate_assert 03 serial-absent 'gomail: dial'
vgate_assert 03 serial-absent 'gomail: imap ready'
vgate_assert 03 serial-absent '[EXC] parking:'

# --- Run 04: the consent answer — --plain dials and fetches -------------
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio \
    --net '$RUN_DIR/cap04.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:143:relay --net-tcp-respond-relay 127.0.0.1:26143 \
    --script '$RUN_DIR/script-04.txt' --script-expect 'gomail: closed' --timeout 240

vgate_assert 04 serial-contains 'gomail: dial 10.0.0.2 143 plain'
vgate_assert 04 serial-contains 'gomail: imap ready'
vgate_assert 04 serial-contains 'gomail: select INBOX exists=3'
vgate_assert 04 serial-contains 'gomail: text line one of the gate body'
vgate_assert 04 serial-contains 'gomail: closed'
vgate_assert 04 serial-absent 'gomail: refuse plaintext'
vgate_assert 04 serial-absent 'gomail: error'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import os, sys
log = open(os.path.join(os.environ["RUN_DIR"], "maild-26143.log")).read()
need = ["c0 open", "c0 rx a1 LOGIN", "c0 rx a2 LIST", "c0 rx a3 SELECT",
        "c0 rx a4 FETCH 1:3 (ENVELOPE)", "c0 rx a5 FETCH 1 (BODYSTRUCTURE)",
        "LOGOUT"]
missing = [n for n in need if n not in log]
if missing:
    sys.exit("imap-plain fixture transcript missing: %r\n%s" % (missing, log))
PY

# --- Run 05: 'use Sent' — folder browsing over the real LIST ------------
#
# M193a: LIST paints the folders, `use` SELECTs the named one and writes
# the remembered selection + folder list into /host/MAIL/.
vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --net '$RUN_DIR/cap05.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:993:relay --net-tcp-respond-relay 127.0.0.1:26993 \
    --script '$RUN_DIR/script-05.txt' --script-expect 'gomail: use Sent exists=3' --timeout 240

vgate_assert 05 serial-contains 'gomail: dial 10.0.0.2 993 tls'
vgate_assert 05 serial-contains 'gomail: imap ready'
vgate_assert 05 serial-contains 'gomail: box INBOX'
vgate_assert 05 serial-contains 'gomail: box Sent'
vgate_assert 05 serial-contains 'gomail: use Sent exists=3'
vgate_assert 05 serial-contains 'gomail: cache /host/MAIL/BOXES'
vgate_assert 05 serial-contains 'gomail: cache /host/MAIL/USE'
vgate_assert 05 serial-contains 'gomail: closed'
vgate_assert 05 serial-absent 'gomail: error'
vgate_assert 05 serial-absent 'gomail: refuse'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 share-contains MAIL/USE 'Sent'
vgate_assert 05 share-contains MAIL/BOXES 'Sent'
vgate_assert 05 python <<'PY'
import os, sys
log = open(os.path.join(os.environ["RUN_DIR"], "maild-26993.log")).read()
need = ["LIST", "SELECT \"Sent\""]
missing = [n for n in need if n not in log]
if missing:
    sys.exit("use fixture transcript missing: %r\n%s" % (missing, log))
PY

# --- Run 06: 'use Lists' — no fake folders ------------------------------
#
# The seeded BOXES remembers 'Lists' but the wire LIST does not: `use`
# validates over the REAL LIST, so the name refuses by name and no
# SELECT is ever sent.
vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --net '$RUN_DIR/cap06.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:993:relay --net-tcp-respond-relay 127.0.0.1:26993 \
    --script '$RUN_DIR/script-06.txt' --script-expect 'gomail: refuse use Lists' --timeout 240

vgate_assert 06 serial-contains 'gomail: box INBOX'
vgate_assert 06 serial-contains 'gomail: box Sent'
vgate_assert 06 serial-contains 'gomail: refuse use Lists'
vgate_assert 06 serial-contains 'gomail: closed'
vgate_assert 06 serial-absent 'gomail: use Lists'
vgate_assert 06 serial-absent 'gomail: error'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 python <<'PY'
import os, sys
log = open(os.path.join(os.environ["RUN_DIR"], "maild-26993.log")).read()
if 'SELECT "Lists"' in log:
    sys.exit("use SELECTed a folder the LIST never carried\n%s" % log)
PY

# --- Run 07: 'search weekly' — seeded-cache header hit, no dial ----------
vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio \
    --script '$RUN_DIR/script-07.txt' --script-expect 'gomail: search hits=1' --timeout 180

vgate_assert 07 serial-contains 'gomail: search weekly'
vgate_assert 07 serial-contains 'gomail: hit Lists 7 dana@fixture.local: weekly digest'
vgate_assert 07 serial-contains 'gomail: search hits=1'
vgate_assert 07 serial-contains 'gomail: closed'
vgate_assert 07 serial-absent 'gomail: dial'
vgate_assert 07 serial-absent 'gomail: error'
vgate_assert 07 serial-absent '[EXC] parking:'

# --- Run 08: 'search orchid' — seeded-cache body hit, no dial ------------
vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --via-virtio \
    --script '$RUN_DIR/script-08.txt' --script-expect 'gomail: search hits=1' --timeout 180

vgate_assert 08 serial-contains 'gomail: hit Lists 9 (body)'
vgate_assert 08 serial-contains 'gomail: search hits=1'
vgate_assert 08 serial-contains 'gomail: closed'
vgate_assert 08 serial-absent 'gomail: dial'
vgate_assert 08 serial-absent 'gomail: error'
vgate_assert 08 serial-absent '[EXC] parking:'

# --- Run 09: cache-miss fetch — offline names itself, never fabricates ---
#
# --tls asks for the wire with no net configured: the dial fails, the
# offline leg paints the remembered folders + INBOX envelopes, then
# 'gomail: cache-miss INBOX 9' names the miss — no 'gomail: body 9' is
# ever invented.
vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --via-virtio \
    --script '$RUN_DIR/script-09.txt' --script-expect 'gomail: cache-miss INBOX 9' --timeout 180

vgate_assert 09 serial-contains 'gomail: offline fetch INBOX'
vgate_assert 09 serial-contains 'gomail: box INBOX'
vgate_assert 09 serial-contains 'gomail: box Sent'
vgate_assert 09 serial-contains 'gomail: hdr 1 Alice: gate hello'
vgate_assert 09 serial-contains 'gomail: cache-miss INBOX 9'
vgate_assert 09 serial-contains 'gomail: closed'
vgate_assert 09 serial-absent 'gomail: dial'
vgate_assert 09 serial-absent 'gomail: body 9'
vgate_assert 09 serial-absent 'gomail: hdr 9'
vgate_assert 09 serial-absent 'gomail: error'
vgate_assert 09 serial-absent '[EXC] parking:'

# --- Run 10: offline read — a remembered body paints offline --------------
vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --via-virtio \
    --script '$RUN_DIR/script-10.txt' --script-expect 'gomail: closed' --timeout 180

vgate_assert 10 serial-contains 'gomail: offline read INBOX 1'
vgate_assert 10 serial-contains 'gomail: body 1 text/plain'
vgate_assert 10 serial-contains 'gomail: text line one of the gate body'
vgate_assert 10 serial-contains 'gomail: closed'
vgate_assert 10 serial-absent 'gomail: dial'
vgate_assert 10 serial-absent 'gomail: cache-miss'
vgate_assert 10 serial-absent 'gomail: error'
vgate_assert 10 serial-absent '[EXC] parking:'
