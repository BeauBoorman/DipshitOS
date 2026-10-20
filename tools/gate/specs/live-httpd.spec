# live-httpd.spec -- GOHTTPD.ELF (exec'd) serves HTTP/1.1 on port 8080.
#
# M71l (#1571) proved the passive open only -- the monitor showed
# tcp=listen while the one-shot responder lived. Second pass (#2200):
# GOHTTPD is a persistent server on the slot-80 handle listener
# (vi.SocketListen), so the gate now drives real exchanges with the
# runner's --net-tcp-connect host clients:
#
#   01 passive listen (kept leg)
#   02 two clients on one listener without a restart
#   03 keep-alive: three requests on ONE connection (GET, GET 404, HEAD)
#   04 refusal surface: traversal 404, POST 405, garbage 400
#   05 HTTPS: --tls on 8443, host TLS 1.3 client over the
#      --net-tcp-connect-stream relay, cert DER + body checked (M135a)
#   06 negative: a TLS 1.2-only client gets the protocol_version alert
#      in the serial log
#
# The kernel's child_limit=2 bounds simultaneous children and every
# --net-tcp-connect client fires on its own dispatch queue at the same
# marker, so a literal third SEQUENTIAL connect in one boot is not
# expressible: run 02 instead proves the accept loop iterates -- one
# client's session completes and the pending child is served after it.
# Runs 02/03/04 re-accept five sessions total on one listener, and the
# payload clients FIN on the response so client-initiated close is
# covered too. GOHTTPD.ELF is staged into the share by the setup hook
# along with the HTTPD.TXT fixture the file route serves.
#
# HOST PREREQUISITE (fails honestly when missing):
#   bash tools/go/build-gohttpd.sh  ->  .build/go/GOHTTPD.ELF

vgate_name live-httpd "GOHTTPD.ELF persistent HTTP/1.1 on 8080 (sequential, keep-alive, refusals)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt kernel/src/tcp.zig kernel/src/syscall.zig kernel/src/monitor.zig user/src/lib/ui.zig build.zig

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
exec GOHTTPD.ELF
echo httpd-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
net
echo httpd-ok
EOF

vgate_file script-3.txt <<'EOF'
procs
kill GOHTTPD.ELF
echo httpd-killed
EOF

# run 02 payloads: one request each, explicit Connection: close.
vgate_file req-index.txt <<'EOF'
GET / HTTP/1.1
Connection: close

EOF

vgate_file req-file.txt <<'EOF'
GET /HTTPD.TXT HTTP/1.1
Connection: close

EOF

# run 03 payload: three pipelined requests on one keep-alive connection.
vgate_file req-keepalive.txt <<'EOF'
GET / HTTP/1.1

GET /NOPE.TXT HTTP/1.1

HEAD /healthz HTTP/1.1
Connection: close

EOF

# run 04 payloads: a traversal probe (404, keep-alive survives it) then
# POST (405, closes), and a second client whose bytes are not HTTP (400).
vgate_file req-errors.txt <<'EOF'
GET /../SECRETS.TXT HTTP/1.1

POST / HTTP/1.1

EOF

vgate_file req-garbage.txt <<'EOF'
HELLO WORLD

EOF

# run 05/06: the TLS-over-stdio client. ssl.MemoryBIO drives TLS 1.3 over the
# runner's byte relay; stderr is the evidence channel (into the run log).
# argv: CERT_DER_PATH [tls12]
vgate_file tlscli.py <<'EOF'
#!/usr/bin/env python3
import os, ssl, sys

cert_path = sys.argv[1]
tls12 = len(sys.argv) > 2 and sys.argv[2] == "tls12"

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
if tls12:
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
else:
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.maximum_version = ssl.TLSVersion.TLSv1_3

inbio = ssl.MemoryBIO()
outbio = ssl.MemoryBIO()
so = ctx.wrap_bio(inbio, outbio, server_side=False)

def flush():
    while True:
        b = outbio.read()
        if not b:
            return
        os.write(1, b)

# Handshake loop: flush outgoing BIO, feed incoming stdin. An SSLError means
# the peer's alert arrived — print it for the log and stop.
ok = False
while True:
    try:
        so.do_handshake()
        ok = True
        break
    except ssl.SSLWantReadError:
        flush()
        block = os.read(0, 65536)
        if not block:
            break
        inbio.write(block)
    except ssl.SSLWantWriteError:
        flush()
    except ssl.SSLError as e:
        sys.stderr.write("TLSCLI: handshake ssl error %r\n" % (e,))
        break
    flush()

if not ok:
    sys.exit(0 if tls12 else 2)

peer = so.getpeercert(binary_form=True)
want = open(cert_path, "rb").read()
sys.stderr.write("TLSCLI: handshake ok, peer cert %d bytes, fixture match=%s\n"
                 % (len(peer or b""), peer == want))
so.write(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
flush()
body = b""
while True:
    try:
        d = so.read(4096)
        if not d:
            break
        body += d
    except ssl.SSLWantReadError:
        pass
    except ssl.SSLError as e:
        sys.stderr.write("TLSCLI: read err %r\n" % (e,))
        break
    block = os.read(0, 65536)
    if not block:
        break
    inbio.write(block)
sys.stderr.write("TLSCLI: body=%r\n" % body)
if b"VirelaiOS" not in body:
    sys.exit(3)
sys.exit(0)
EOF

vgate_file script-tls.txt <<'EOF'
exec GOHTTPD.ELF --tls /host/TLS.CRT /host/TLS.SEED 8443
echo tls-launched
EOF

vgate_file script-tls-kill.txt <<'EOF'
procs
kill GOHTTPD.ELF
echo tls-killed
EOF

vgate_setup_python <<'PY'
import os, shutil, sys

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

src = os.path.join(".build", "go", "GOHTTPD.ELF")
if not os.path.exists(src):
    sys.exit("GOHTTPD.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gohttpd.sh")
dst = os.path.join(share, "GOHTTPD.ELF")
shutil.copy(src, dst)
print("live-httpd: staged GOHTTPD.ELF (%d bytes)" % os.path.getsize(dst))
with open(os.path.join(share, "HTTPD.TXT"), "w") as f:
    f.write("VIRELAI-HTTPD-FIXTURE-01\n")
print("live-httpd: staged HTTPD.TXT fixture")

# The TLS legs' credential: the env-gated host generator writes TLS.CRT
# (DER, self-signed Ed25519, CA:TRUE + serverAuth + SANs for 10.0.0.1 /
# virelai-https.local) and TLS.SEED (raw 32-byte Ed25519 seed) into the
# share.
env = dict(os.environ)
env["HTTPD_TLS_GEN_FIXTURE"] = "1"
env["HTTPD_TLS_FIXTURE_DIR"] = share
import subprocess
repo = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
r = subprocess.run(["go", "-C", "user/go", "test", "-run", "TestGenTLSFixture",
                    "-v", "./httpd/"], cwd=repo, env=env,
                   capture_output=True, text=True)
sys.stderr.write(r.stdout[-800:] + r.stderr[-800:])
if r.returncode != 0:
    sys.exit("fixture generator failed")
for name in ("TLS.CRT", "TLS.SEED"):
    p = os.path.join(share, name)
    if not os.path.exists(p):
        sys.exit("fixture missing " + p)
print("live-httpd: generated TLS.CRT + TLS.SEED in share")

# The stream client verifies the peer's DER against the same fixture; the
# share path varies ($VG_SHARE), so it reads a RUN_DIR copy.
shutil.copy(os.path.join(share, "TLS.CRT"), os.path.join(run, "TLS.CRT"))

import stat
os.chmod(os.path.join(run, "tlscli.py"), 0o755)
PY

# ---- 01: passive open (the kept M71l leg) --------------------------------
vgate_run 01 -- --net '$RUN_DIR/cap.bin' --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'httpd: listening on port 8080' --script-expect 'httpd-ok' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'httpd: starting'
vgate_assert 01 serial-contains 'httpd: listening on port 8080'
vgate_assert 01 serial-contains 'echo httpd-launched'
vgate_assert 01 serial-contains 'GOHTTPD.ELF'
vgate_assert 01 serial-contains 'echo httpd-ok'

# ---- 02: two sequential clients, then kill mid-listen --------------------
vgate_run 02 -- --net '$RUN_DIR/cap2.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/req-index.txt' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/req-file.txt' \
    --net-tcp-connect-after 'httpd: listening on port 8080' \
    --script '$RUN_DIR/script-1.txt' \
    --script2 '$RUN_DIR/script-3.txt' --script2-after 'httpd: closed' --script2-delay 4 \
    --script-expect 'httpd-killed' --timeout 90

vgate_assert 02 serial-contains 'httpd: listening on port 8080'
vgate_assert 02 serial-contains 'kill: GOHTTPD.ELF armed'
vgate_assert 02 serial-contains 'httpd: request /'
vgate_assert 02 serial-contains 'httpd: request /HTTPD.TXT'
vgate_assert 02 output-contains 'HTTP/1.1 200 OK'
vgate_assert 02 output-contains 'VIRELAI-HTTPD-FIXTURE-01'
vgate_assert 02 output-contains 'Content-Type: text/plain; charset=utf-8'
vgate_assert 02 output-contains 'Connection: close'
vgate_assert 02 serial-absent 'httpd: error'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
for marker, want in (("httpd: accepted", 2), ("httpd: served", 2), ("httpd: closed", 2)):
    n = ser.count(marker)
    if n != want:
        sys.exit("FAIL: %r appeared %d times, want %d" % (marker, n, want))
# Exact lines: 'httpd: request /' is a substring of the HTTPD.TXT line,
# so count only full-line matches.
lines = [l.strip() for l in ser.splitlines()]
for marker, want in (("httpd: request /", 1), ("httpd: request /HTTPD.TXT", 1)):
    n = lines.count(marker)
    if n != want:
        sys.exit("FAIL: %r appeared %d times, want %d" % (marker, n, want))
print("two sequential clients served on one listener without restart")
PY

# ---- 03: keep-alive -- three requests on ONE connection -------------------
vgate_run 03 -- --net '$RUN_DIR/cap3.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/req-keepalive.txt' \
    --net-tcp-connect-after 'httpd: listening on port 8080' \
    --net-tcp-connect-close-after 'Connection: close' \
    --script '$RUN_DIR/script-1.txt' \
    --script2 '$RUN_DIR/script-3.txt' --script2-after 'httpd: closed' --script2-delay 2 \
    --script-expect 'httpd-killed' --timeout 90

vgate_assert 03 serial-contains 'kill: GOHTTPD.ELF armed'
vgate_assert 03 serial-contains 'httpd: request /'
vgate_assert 03 serial-contains 'httpd: request /NOPE.TXT'
vgate_assert 03 serial-contains 'httpd: request /healthz'
vgate_assert 03 output-contains 'HTTP/1.1 200 OK'
vgate_assert 03 output-contains 'HTTP/1.1 404 Not Found'
vgate_assert 03 output-contains 'Connection: keep-alive'
vgate_assert 03 output-contains 'Connection: close'
vgate_assert 03 serial-absent 'httpd: error'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
if ser.count("httpd: accepted") != 1:
    sys.exit("keep-alive leg took %d connections, want exactly 1" % ser.count("httpd: accepted"))
if ser.count("httpd: served") != 3:
    sys.exit("keep-alive leg served %d responses, want 3" % ser.count("httpd: served"))
out = open(os.path.join(os.environ["RUN_DIR"], "run-03.out"), errors="replace").read()
# The HEAD answer carries the entity length but no JSON body.
if 'Content-Length' not in out:
    sys.exit("HEAD answer missing Content-Length")
if '"status":"ok"' in out:
    sys.exit("HEAD answer carried the healthz body")
print("keep-alive: 3 requests on one connection; HEAD had headers only")
PY

# ---- 04: refusal surface -- traversal 404, POST 405, garbage 400 ----------
vgate_run 04 -- --net '$RUN_DIR/cap4.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/req-errors.txt' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/req-garbage.txt' \
    --net-tcp-connect-after 'httpd: listening on port 8080' \
    --net-tcp-connect-close-after 'Connection: close' \
    --script '$RUN_DIR/script-1.txt' \
    --script2 '$RUN_DIR/script-3.txt' --script2-after 'httpd: closed' --script2-delay 4 \
    --script-expect 'httpd-killed' --timeout 90

vgate_assert 04 serial-contains 'kill: GOHTTPD.ELF armed'
vgate_assert 04 serial-contains 'httpd: request /../SECRETS.TXT'
vgate_assert 04 output-contains 'HTTP/1.1 404 Not Found'
vgate_assert 04 output-contains 'HTTP/1.1 405 Method Not Allowed'
vgate_assert 04 output-contains 'HTTP/1.1 400 Bad Request'
vgate_assert 04 serial-absent 'httpd: error'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# No path outside the served root is ever logged or opened: the traversal
# target is logged as the client's own string, and SECRETS.TXT's staged
# name never appears as a served path.
if "/host/" in ser:
    sys.exit("a share-root path leaked into the serial log")
print("traversal refused 404, POST 405, garbage 400")
PY

# ---- 05: HTTPS -- GOHTTPD --tls on 8443, host TLS 1.3 client (M135a) ------
vgate_run 05 -- --net '$RUN_DIR/cap5.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect '10.0.0.1:8443' \
    --net-tcp-connect-stream '$RUN_DIR/tlscli.py' \
    --net-tcp-connect-stream-arg '$RUN_DIR/TLS.CRT' \
    --net-tcp-connect-after 'httpd: listening on port 8443' \
    --script '$RUN_DIR/script-tls.txt' \
    --script2 '$RUN_DIR/script-tls-kill.txt' --script2-after 'httpd: closed' --script2-delay 3 \
    --script-expect 'tls-killed' --timeout 90

vgate_assert 05 serial-contains 'httpd: listening on port 8443'
vgate_assert 05 serial-contains 'httpd: accepted'
vgate_assert 05 serial-contains 'httpd: request /'
vgate_assert 05 serial-contains 'httpd: served'
vgate_assert 05 serial-absent 'httpd: tls alert'
vgate_assert 05 serial-absent 'httpd: tls error'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 python <<'PY'
import os, sys
out = open(os.path.join(os.environ["RUN_DIR"], "run-05.out"), errors="replace").read()
if "fixture match=True" not in out:
    sys.exit("peer cert did not equal the staged TLS.CRT")
if "TLSCLI: handshake ok" not in out:
    sys.exit("host TLS 1.3 client did not complete the handshake")
if "VirelaiOS" not in out:
    sys.exit("HTTPS body missing the index page")
ser = open(os.environ["VG_SER"], errors="replace").read()
if "httpd: tls alert" in ser or "httpd: tls error" in ser:
    sys.exit("a TLS alert/error reached serial")
print("HTTPS leg: host TLS 1.3 client over the relay, cert + body verified")
PY

# ---- 06: TLS 1.2-only client -> protocol_version alert --------------------
vgate_run 06 -- --net '$RUN_DIR/cap6.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect '10.0.0.1:8443' \
    --net-tcp-connect-stream '$RUN_DIR/tlscli.py' \
    --net-tcp-connect-stream-arg '$RUN_DIR/TLS.CRT' \
    --net-tcp-connect-stream-arg 'tls12' \
    --net-tcp-connect-after 'httpd: listening on port 8443' \
    --script '$RUN_DIR/script-tls.txt' \
    --script2 '$RUN_DIR/script-tls-kill.txt' --script2-after 'httpd: closed' --script2-delay 3 \
    --script-expect 'tls-killed' --timeout 90

vgate_assert 06 serial-contains 'httpd: listening on port 8443'
vgate_assert 06 serial-contains 'httpd: accepted'
vgate_assert 06 serial-contains 'httpd: tls alert protocol_version'
vgate_assert 06 serial-contains 'httpd: closed'
vgate_assert 06 serial-absent 'httpd: served'
vgate_assert 06 serial-absent '[EXC] parking:'
