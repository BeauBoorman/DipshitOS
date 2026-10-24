# WEB.ELF bounded HTML/CSS/GET browser, plus GOFETCH TLS regression. One
# exec per boot, ended by program markers or an anchored kernel receipt.
# 01-11 retain render/link/fetch/error/cancel/store/offline/hostile behaviors.
# 12 proves in-process GOFETCH TLS; 13-14 retain shim console-ink + the
# pinned corpus. 15-17 type real hostnames against hermetic stand-ins;
# 18-20 prove wrong-host/expired/production-unknown-root refusal before GET.
# 21 measures the largest reference with actual kernel ownership counters.
# 22-38 (M93g #1999): each frozen reference renders in-guest; the marker-
# geometry crop SHA-256-matches its approved M93e golden (web-proof/compare.py,
# ADR 0028 D9 exact RGB8, zero tolerance; the comparator self-test runs in setup).
# 39 (M126a #2593): the address-bar/nav leg — a typed URL loads, the chips
# drive back/forward/reload, and the history dropdown lists + revisits entries.
# 40-41 (M126b #2594): the bookmark leg — Ctrl+D stores two pages as FLINT
# ws/bookmarks atoms on the armed share, Ctrl+Shift+B's sidebar lists and
# picks one, and boot 41 (a fresh VM on the SAME share) loads the surviving
# atom off disk and navigates to it.
# 42 (M126c #2595): the find-in-page leg — Ctrl+F's bar searches the laid-out
# text, the match set paints amber and the current match orange on the
# scanout, Enter steps next (wrapping), Esc closes.
# 43 (M126d #2596): per-tab zoom Ctrl+=/-/0 with reflow + font_size setting.
# 44 (M126e #2597): .QOI link click -> staged download -> completion plate ->
# 'o' mime-opens GOVIEW.
# 45-47 (M126f #2598): the K=3 acceptance journey — one boot per iteration of
# browse -> bookmark -> find -> zoom -> download -> open in viewer, three
# independent VMs on the shared armed share.
# 57 (M153e #2925): the picker save with a .pdf name writes the laid-out
# page as a raster PDF (pdfwrite Letter slices); host parses the file and
# compares cgrender's page 1 with the scanout's page crop.
# 54-56 (M135d #2766): the K=3 net acceptance journey — one boot per
# iteration: GOHTTPD --tls serves a page to a host TLS 1.3 client over the
# byte relay, WEB pulls a gzip page plus two linked stylesheets off the host
# packet responder on ONE keep-alive connection, and a third simultaneous
# SYN past the plain listener's child bound draws the named refusal.
# v6 (M117f #2478, ADR 0057): vi.Dial v6 connect+GET to the hermetic
# responder; WEB.ELF's named v6-literal URL refusal beside it — no v6 URL
# grammar or TLS-over-v6 responder exists yet. No public-internet access,
# scripts or POST; owner authorized the fixed three-pixel shim-border
# composition; font markers are live-web-ttf's. Prereqs: build-web.sh
# browser WEB and browser WEB --gate, fetch GOFETCH --gate,
# build-goview.sh, build-files.sh, build-gohttpd.sh.

vgate_name live-web "WEB: bounded CSS browser, exact M93 presentation, DNS/SNI/GET navigation and fail-closed TLS"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-local.txt <<'EOF'
exec WEB.ELF /host/PAGE.HTML
EOF

vgate_file script-nav.txt <<'EOF'
exec WEB.ELF /host/PAGE.HTML
EOF

vgate_file script-fetch.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file script-missing.txt <<'EOF'
exec WEB.ELF /host/NOPE.HTML
EOF

vgate_file script-https.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF https://10.0.0.2:80/
EOF

vgate_file script-dns.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://example.com/
EOF

vgate_file script-badurl.txt <<'EOF'
exec WEB.ELF http://
EOF

vgate_file script-hostile.txt <<'EOF'
exec WEB.ELF /host/HOSTILE.HTML
EOF

vgate_file script-store.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file script-offline.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file script-slow.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file script-gofetch.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOFETCH.ELF https://10.0.0.2:24533/
EOF

vgate_file script-corpus.txt <<'EOF'
exec WEB.ELF /host/CORPUS.HTML
EOF

vgate_file script-m93-start.txt <<'EOF'
net ip 10.0.0.1
net arp 93.184.216.34
exec WEB.ELF --dns=93.184.216.34
EOF
vgate_file script-m93-name.txt <<'EOF'
net ip 10.0.0.1
net arp 93.184.216.34
exec WEB.ELF --dns=93.184.216.34 https://wrong.example.com:24561/
EOF
vgate_file script-m93-expired.txt <<'EOF'
net ip 10.0.0.1
net arp 93.184.216.34
exec WEB.ELF --dns=93.184.216.34 https://en.wikipedia.org:24562/
EOF
vgate_file script-m93-production.txt <<'EOF'
net ip 10.0.0.1
net arp 93.184.216.34
exec WEB-PROD.ELF --dns=93.184.216.34 https://en.wikipedia.org:24560/
EOF
vgate_file script-m93-largest.txt <<'EOF'
exec WEB.ELF /host/M93-LARGEST.HTML
EOF
vgate_file script-m93-receipt.txt <<'EOF'
procs receipt WEB.ELF
EOF

# M93g #1999: one boot per frozen reference page (boots 22-38). The script
# bodies differ only in the share name, kept literal so the exec-order guard
# can read every one of them.
vgate_file script-ref-borders.txt <<'EOF'
exec WEB.ELF /host/BORDERS.HTML
EOF
vgate_file script-ref-box-model.txt <<'EOF'
exec WEB.ELF /host/BOX-MODEL.HTML
EOF
vgate_file script-ref-boxes-block.txt <<'EOF'
exec WEB.ELF /host/BOXES-BLOCK.HTML
EOF
vgate_file script-ref-boxes-collapse.txt <<'EOF'
exec WEB.ELF /host/BOXES-COLLAPSE.HTML
EOF
vgate_file script-ref-boxes-flex.txt <<'EOF'
exec WEB.ELF /host/BOXES-FLEX.HTML
EOF
vgate_file script-ref-colors.txt <<'EOF'
exec WEB.ELF /host/COLORS.HTML
EOF
vgate_file script-ref-degradation.txt <<'EOF'
exec WEB.ELF /host/DEGRADATION.HTML
EOF
vgate_file script-ref-display-tables.txt <<'EOF'
exec WEB.ELF /host/DISPLAY-TABLES.HTML
EOF
vgate_file script-ref-flex.txt <<'EOF'
exec WEB.ELF /host/FLEX.HTML
EOF
vgate_file script-ref-fonts.txt <<'EOF'
exec WEB.ELF /host/FONTS.HTML
EOF

vgate_file script-ref-fonts-family.txt <<'EOF'
exec WEB.ELF /host/FONTS-FAMILY.HTML
EOF

vgate_file script-ref-fonts-size.txt <<'EOF'
exec WEB.ELF /host/FONTS-SIZE.HTML
EOF

vgate_file script-ref-forms.txt <<'EOF'
exec WEB.ELF /host/FORMS.HTML
EOF
vgate_file script-ref-github.txt <<'EOF'
exec WEB.ELF /host/GITHUB.HTML
EOF
vgate_file script-ref-mdn.txt <<'EOF'
exec WEB.ELF /host/MDN.HTML
EOF
vgate_file script-ref-selectors.txt <<'EOF'
exec WEB.ELF /host/SELECTORS.HTML
EOF
vgate_file script-ref-wikipedia.txt <<'EOF'
exec WEB.ELF /host/WIKIPEDIA.HTML
EOF

vgate_setup_python <<'PY'
# Boot 08 needs a peer that ACCEPTS the connection and never answers: the
# browser must sit in its waiting state so the injected cancel key has a load
# to cancel. A plain silent listener on the host, reached through the runner's
# relay responder, is exactly that peer.
import os, socket, sys, time
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("127.0.0.1", 45871))
except OSError as exc:
    sys.exit("boot 08: cannot bind the silent peer on 127.0.0.1:45871: %s" % exc)
srv.listen(4)
srv.settimeout(1.0)
owner = os.getppid()
pid = os.fork()
if pid == 0:
    # The peer must not inherit the gate's stdio pipes: holding them open
    # keeps the runner's session alive after the gate finishes.
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    conns = []
    # The deadline must outlive the whole spec, not the boot it serves:
    # 300 s was sized when this spec had a dozen runs and expired mid-run
    # on a 39-run fleet (observed 2026-10-18: upstream dial ECONNREFUSED,
    # 'web: offline' instead of a load to cancel). The owner-pid watch is
    # the real lifetime bound; this is only the orphan backstop.
    deadline = time.time() + 7200
    while time.time() < deadline:
        try:
            os.kill(owner, 0)
        except ProcessLookupError:
            break
        try:
            conn, _ = srv.accept()
            conns.append(conn)   # held open, never written to
        except OSError:
            pass
    os._exit(0)
print("boot 08: silent peer listening on 127.0.0.1:45871 (pid %d)" % pid)
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "WEB-GATE.ELF")
if not os.path.exists(src):
    sys.exit("WEB.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh browser WEB --gate")
shutil.copy(src, os.path.join(share, "WEB.ELF"))
for src_name, dst_name in (("gate-page.html", "PAGE.HTML"), ("gate-next.html", "NEXT.HTML"),
                           ("hostile.html", "HOSTILE.HTML")):
    shutil.copy(os.path.join("user", "go", "browser", "testdata", src_name),
                os.path.join(share, dst_name))
# M71i (#1568): the M70d (#1456) fidelity-corpus page, inherited from the
# retired live-doc-web boot 05 ("one UA-table corpus page the guest can
# open"). It is a real page off the pinned corpus and the only thing that
# keeps that rung asserted IN the guest now that its Zig consumer is gone;
# the host-side golden tests (user/go/webrender/golden_test.go) pin all nine
# corpus pages' layout, but they never boot the VM.
corpus = os.path.join("user", "go", "webrender", "testdata", "corpus",
                      "cern-home.html")
if not os.path.exists(corpus):
    sys.exit("corpus fixture missing at " + corpus)
shutil.copy(corpus, os.path.join(share, "CORPUS.HTML"))
print("staged WEB.ELF (%d bytes) + PAGE.HTML/NEXT.HTML" %
      os.path.getsize(os.path.join(share, "WEB.ELF")))
gofetch = os.path.join(".build", "go", "GOFETCH-GATE.ELF")
if not os.path.exists(gofetch):
    sys.exit("GOFETCH.ELF missing (expected " + gofetch + ") - build it first: "
             "bash tools/go/build-web.sh fetch GOFETCH --gate")
shutil.copy(gofetch, os.path.join(share, "GOFETCH.ELF"))
print("staged GOFETCH.ELF (%d bytes)" % os.path.getsize(os.path.join(share, "GOFETCH.ELF")))
PY

vgate_setup_python <<'PY'
# Boot 12: TLS 1.3 responder on the same fixture identity the Go shelf
# vendors (leaf.example.com, AutoClaw test CA). Bound to loopback:24533 and
# reached through the runner's :relay -- the probe retired from live-tls13
# in M71k (#1570); this boot is its coverage. Long deadline because this
# spec has many boots before 12.
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
    "--body", "live-web-https-ok\n", "--accept", "2", "--timeout", "3600",
]
log = open(os.path.join(rd, "tlsresponder.log"), "wb")
watch = os.path.join("user", "go", "browser", "peer_watch.py")
proc = subprocess.Popen([sys.executable, watch, str(os.getppid())] + cmd,
                        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
print("live-web 12: tlsresponder pid=%d on 127.0.0.1:24533" % proc.pid)
PY

vgate_setup_python <<'PY'
# Original stand-ins, real DNS names, separate loopback TLS peers. The runner's
# fixed A answer is 93.184.216.34; using it as the DNS peer too needs one ARP
# identity, not a host/SDK change. No public internet is reached.
import os, shutil, subprocess, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
production = os.path.join(".build", "go", "WEB.ELF")
if not os.path.exists(production):
    sys.exit("build production first: bash tools/go/build-web.sh browser WEB")
shutil.copy(production, os.path.join(share, "WEB-PROD.ELF"))
reference = os.path.join("tests", "fixtures", "web", "reference")
references = [os.path.join(reference, name) for name in os.listdir(reference) if name.endswith(".html")]
largest_source = max(references, key=lambda path: os.path.getsize(path))
# reference_work_test.go inventories retained nodes + boxes + paint items.
# Wikipedia is the largest render-work reference, not the slightly larger
# source-only flex fixture whose layout emits a single paint item.
largest = os.path.join(reference, "wikipedia.html")
shutil.copy(largest, os.path.join(share, "M93-LARGEST.HTML"))
print("M93 largest retained-work reference:", largest, os.path.getsize(largest))
print("M93 largest source-only reference:", largest_source, os.path.getsize(largest_source))
fx = os.path.join(run, "m93-fx")
os.makedirs(fx, exist_ok=True)
base = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
key = os.path.join(base, "leaf-ec.key")
csr, leaf, expired = (os.path.join(fx, n) for n in ("stand.csr", "stand.pem", "expired.pem"))
ext = os.path.join(fx, "stand.ext")
open(ext, "w").write(
    "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
    "extendedKeyUsage=serverAuth\n"
    "subjectAltName=DNS:en.wikipedia.org,DNS:github.com,DNS:developer.mozilla.org\n")
subprocess.check_call(["openssl", "req", "-new", "-key", key,
                      "-subj", "/CN=en.wikipedia.org", "-out", csr])
common = ["openssl", "x509", "-req", "-in", csr, "-CA", os.path.join(base, "inter.pem"),
          "-CAkey", os.path.join(base, "inter.key"), "-CAserial", os.path.join(fx, "serial"),
          "-CAcreateserial", "-extfile", ext]
subprocess.check_call(common + ["-days", "30", "-out", leaf])
subprocess.check_call(common + ["-not_before", "20200101000000Z",
                                "-not_after", "20200102000000Z", "-out", expired])
def chain(source, name):
    path = os.path.join(fx, name)
    open(path, "wb").write(open(source, "rb").read() +
                          open(os.path.join(base, "inter.pem"), "rb").read())
    return path
cert = chain(leaf, "stand-chain.pem")
expired_cert = chain(expired, "expired-chain.pem")
peer = os.path.join("user", "go", "browser", "standin_responder.py")
watch = os.path.join("user", "go", "browser", "peer_watch.py")
for port, certificate, negative in (
        (24560, cert, False), (24561, os.path.join(base, "chain-ec.pem"), True),
        (24562, expired_cert, True)):
    log = open(os.path.join(run, "m93-peer-%d.log" % port), "wb")
    command = [sys.executable, peer, "--port", str(port), "--cert", certificate,
               "--key", key, "--timeout", "3600"]
    if negative:
        command.append("--negative")
    proc = subprocess.Popen([sys.executable, watch, str(os.getppid())] + command,
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    print("M93 original peer pid=%d port=%d" % (proc.pid, port))
PY

vgate_setup_python <<'PY'
# M93g #1999: stage every frozen reference page under its uppercased share
# name for boots 22-38, and run the comparator's own self-test before a single
# guest pixel is graded -- a comparator that cannot fail is not evidence.
import json, os, shutil, subprocess, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
ref = os.path.join("tests", "fixtures", "web", "reference")
manifest = json.loads(open(os.path.join("user", "go", "webrender", "testdata",
                                        "golden", "m93-reference.json")).read())
if manifest.get("Version") != 1:
    sys.exit("m93-reference.json version is not 1")
pages = sorted(n for n in os.listdir(ref) if n.endswith(".html"))
names = sorted(os.path.splitext(n)[0] for n in pages)
if sorted(manifest.get("Images", {})) != names:
    sys.exit("reference dir and approved manifest disagree: " + repr(names))
missing = [n for n in names if not manifest.get("Verdicts", {}).get(n)]
if missing:
    sys.exit("reference pages without an owner verdict: " + repr(missing))
for page in pages:
    shutil.copy(os.path.join(ref, page),
                os.path.join(share, os.path.splitext(page)[0].upper() + ".HTML"))
# M99p (#2193): fonts-family.html exercises font-family:serif, which needs the
# serif face on the manifest-less path these boots run. One extra share file;
# nothing else reads it.
serif_src = os.path.join("image", "fonts", "NotoSerif-Regular.ttf")
if not os.path.exists(serif_src):
    sys.exit("serif face missing at " + serif_src)
shutil.copy(serif_src, os.path.join(share, "NOTOSERF.TTF"))
subprocess.check_call([sys.executable, "test_compare.py"], cwd="tools/web-proof")
print("M93g: staged %d reference pages; comparator self-test green" % len(pages))
PY

# --- boot 01: a local page renders (markers + pixels) --------------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script-local.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 01 serial-contains 'web: open id='
vgate_assert 01 serial-contains 'web: parse nodes='
vgate_assert 01 serial-contains 'web: layout blocks='
vgate_assert 01 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 01 serial-contains 'web: paint items='
vgate_assert 01 serial-contains 'web: budget startup-ms='
vgate_assert 01 serial-contains ' wait-ms='
vgate_assert 01 serial-contains ' render-ms='
vgate_assert 01 serial-contains ' settle-ms='
vgate_assert 01 serial-absent 'web: budget over'
vgate_assert 01 serial-contains 'web: settled'
vgate_assert 01 serial-contains 'web: repaint items='
vgate_assert 01 serial-contains 'web: ready'
vgate_assert 01 serial-absent 'web: error'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'page'])
PY

# --- boot 02: a pointer click on the in-page link replaces the page ------
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-nav.txt' \
    --pointer-virtio "42,95,c" --pointer-virtio-after "web: settled" \
    --snapshot-after "web: settled" \
    --snapshot-after "web: navigated" \
    --script-expect "web: nav-ready" --timeout 120

# #1586: EVERY boot that launches WEB asserts the absence, not just the old
# 01/03/11. The guest printed `web: budget over startup ...` in all thirteen
# WEB boots for months while only three looked, which is why the red set
# looked load-driven. Measured then: startup=10048ms (7013ms of it vi.WmPeers
# retrying for a WM seat that does not exist on the shim path, 3022ms the four
# faces). After the fix: startup=3029-3054ms, so the absence is true everywhere
# and a real regression trips it in whichever boot it happens. Boot 12 is
# deliberately NOT asserted: it launches GOFETCH, not WEB, and prints no
# `web:` line at all (an absence there could only ever be vacuous).
vgate_assert 02 serial-absent 'web: budget over'
vgate_assert 02 serial-contains 'web: settled'
vgate_assert 02 serial-contains 'web: ev kind=3'
vgate_assert 02 serial-contains 'web: nav /host/NEXT.HTML'
vgate_assert 02 serial-contains 'web: navigated'
vgate_assert 02 serial-contains 'web: nav-ready'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'next'])
PY

# --- boot 03: HTTP fetch over the host TCP responder --------------------
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-03' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script '$RUN_DIR/script-fetch.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 03 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 03 serial-contains 'web: parse nodes='
vgate_assert 03 serial-contains 'web: paint items='
vgate_assert 03 serial-contains 'web: settled'
vgate_assert 03 serial-contains 'web: repaint items='
vgate_assert 03 serial-contains 'web: ready'
vgate_assert 03 serial-contains 'web: budget startup-ms='
vgate_assert 03 serial-absent 'web: budget over'
vgate_assert 03 serial-absent 'web: error'
vgate_assert 03 serial-absent 'web: poll err='
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 03 snapshot 'snap-03-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'fetch'])
PY

# --- boot 04: a missing target renders an error page, still settles -----
vgate_run 04 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-04' \
    --script '$RUN_DIR/script-missing.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 04 serial-absent 'web: budget over'
vgate_assert 04 serial-contains 'web: open id='
vgate_assert 04 serial-contains 'web: error file'
vgate_assert 04 serial-contains 'web: settled'
vgate_assert 04 serial-contains 'web: repaint items='
vgate_assert 04 serial-contains 'web: ready'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 snapshot 'snap-04-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
n = sum(1 for yy in range(Y + 52, Y + 130)
        for xx in range(X + 10, X + 380)
        if ink(px(xx, yy)))
assert n >= 20, f"error page ink {n}"
print("live-web 04 error pixels ok")
PY

# --- boot 05: https is TLS, never a cleartext GET -------------------------
# The host TCP responder IS armed for 10.0.0.2:80, so a silent downgrade to
# plain http would print web: fetch and a NET-TCP 200. WEB.ELF instead
# tls.Dials :80; the handshake fails closed on the HTTP peer (not a hang),
# and the GET is never armed.
vgate_run 05 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-05' \
    --net '$RUN_DIR/cap5.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script '$RUN_DIR/script-https.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 05 serial-absent 'web: budget over'
vgate_assert 05 serial-contains 'web: url https://10.0.0.2:80/'
vgate_assert 05 serial-contains 'web: error tls'
vgate_assert 05 serial-contains 'web: ready'
vgate_assert 05 serial-absent 'web: fetch '
vgate_assert 05 serial-absent 'FETCHS.BIN'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
assert "web: error tls" in ser, "https did not fail closed on TLS"
assert "web: fetch " not in ser, "a request was armed for an https URL"
assert "web: parse nodes=" not in ser, "an https URL produced a rendered page"
assert "GET / HTTP" not in ser, "a cleartext GET was logged"
assert "FETCHS.BIN" not in ser, "FETCHS.BIN was spawned"
print("live-web 05 https fail-closed ok (TLS handshake, no GET, no FETCHS)")
PY

# --- boot 06: a hostname is refused (no resolver), not attempted ---------
vgate_run 06 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-06' \
    --script '$RUN_DIR/script-dns.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 06 serial-absent 'web: budget over'
vgate_assert 06 serial-contains 'web: error dns'
vgate_assert 06 serial-contains 'web: ready'
vgate_assert 06 serial-absent 'web: fetch '
vgate_assert 06 serial-absent '[EXC] parking:'

# --- boot 07: a malformed URL is a defined error, not a hang -------------
vgate_run 07 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-07' \
    --script '$RUN_DIR/script-badurl.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 07 serial-absent 'web: budget over'
vgate_assert 07 serial-contains 'web: error url'
vgate_assert 07 serial-contains 'web: ready'
vgate_assert 07 serial-absent 'web: fetch '
vgate_assert 07 serial-absent '[EXC] parking:'

# --- boot 08: a load in flight can be stopped (cancel) -------------------
# The guest's request is relayed to the silent host peer (see the first setup
# hook), so the browser is genuinely waiting when the injected `x` arrives:
# the assert requires the cancel, not a fast connection failure.
vgate_run 08 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-08' \
    --net '$RUN_DIR/cap8.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:80:relay --net-tcp-respond-relay 127.0.0.1:45871 \
    --script '$RUN_DIR/script-slow.txt' \
    --input-chords x --input-chords-after "web: fetch " \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 180

vgate_assert 08 serial-absent 'web: budget over'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 08 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
assert "web: fetch 10.0.0.2/" in ser, "the load was never armed"
assert "web: error cancelled" in ser, "the injected cancel key did not stop the load"
assert "web: settled" in ser, "no frame was published after the cancel"
print("live-web 08 cancel ok (a load in flight was stopped by the injected cancel key)")
PY

# --- boot 09: the stores are written, and they land on the host share ----
# Fetch with the responder armed, then save the page. The python assert reads
# the share itself, so this is evidence of a persistent store, not of a
# marker the app printed about itself.
vgate_run 09 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-09' \
    --net '$RUN_DIR/cap9.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script '$RUN_DIR/script-store.txt' \
    --input-chords s --input-chords-after "web: ready" \
    --snapshot-after "web: repaint" \
    --script-expect "web: download " --timeout 180

vgate_assert 09 serial-absent 'web: budget over'
vgate_assert 09 serial-contains 'web: stores '
vgate_assert 09 serial-contains 'web: cache store '
vgate_assert 09 serial-contains 'web: download '
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 python <<'PY'
import glob, os
share = os.environ["VG_SHARE"]
def rows(path):
    with open(path, errors="replace") as fh:
        return [l for l in fh.read().splitlines() if l and not l.startswith("#")]
hist = rows(os.path.join(share, "WEB-HISTORY.TXT"))
assert hist, "WEB-HISTORY.TXT has no data rows"
assert any("http://10.0.0.2/" in r for r in hist), "the visit was not recorded"
idx = rows(os.path.join(share, "WEB-CACHE.TXT"))
assert idx, "WEB-CACHE.TXT has no data rows"
bodies = glob.glob(os.path.join(share, "WEB-C-*.BIN"))
assert bodies, "no cached body file"
size = os.path.getsize(bodies[0])
dl = glob.glob(os.path.join(share, "WEB-DL-*"))
assert dl, "no download file"
dlsize = os.path.getsize(dl[0])
print("live-web 09 stores ok (history rows=%d, cache rows=%d, body=%dB, download=%s %dB)"
      % (len(hist), len(idx), size, os.path.basename(dl[0]), dlsize))
PY

# --- boot 10: the store survives a restart, and serves an offline copy ---
# A second, independent boot with NO responder: the connection cannot be
# answered, so the browser must fall back to what it stored in boot 09 and
# say so. The boot-time inventory is what proves the rows were read back
# from disk.
vgate_run 10 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-10' \
    --net '$RUN_DIR/cap10.bin' --net-arp-respond 10.0.0.2 \
    --script '$RUN_DIR/script-offline.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 180

vgate_assert 10 serial-absent 'web: budget over'
vgate_assert 10 serial-contains 'web: offline http://10.0.0.2/'
vgate_assert 10 serial-contains 'web: settled'
vgate_assert 10 serial-absent 'web: error tcp'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
line = ""
for ln in ser.splitlines():
    if ln.startswith("web: stores "):
        line = ln
        break
assert line, "no store inventory at boot"
fields = dict(f.split("=", 1) for f in line.split()[2:] if "=" in f)
assert int(fields.get("cache", 0)) >= 1, "the cache did not survive the restart: " + line
assert int(fields.get("history", 0)) >= 1, "history did not survive the restart: " + line
assert int(fields.get("downloads", 0)) >= 1, "downloads did not survive the restart: " + line
print("live-web 10 restart-persistence ok (%s)" % line.strip())
PY
vgate_assert 10 snapshot 'snap-10-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'fetch'])
PY

# --- boot 11: a hostile page is inert ------------------------------------
# The fixture carries a script whose body would fetch a URL and read a local
# file, an iframe/object/img pointing at the browser's own store files, and
# javascript:/file: links. This browser has no JavaScript and no way for an
# element to act on an attribute, so the page must render as text with no
# request armed, no file read, and no extra syscall path.
vgate_run 11 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-11' \
    --script '$RUN_DIR/script-hostile.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 11 serial-contains 'web: parse nodes='
vgate_assert 11 serial-contains 'web: settled'
vgate_assert 11 serial-contains 'web: budget startup-ms='
vgate_assert 11 serial-contains ' wait-ms='
vgate_assert 11 serial-contains ' render-ms='
vgate_assert 11 serial-contains ' settle-ms='
vgate_assert 11 serial-absent 'web: fetch'
vgate_assert 11 serial-absent 'web: error'
vgate_assert 11 serial-absent 'web: download'
vgate_assert 11 serial-absent 'web: budget over'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 snapshot 'snap-11-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'hostile'])
PY

# --- boot 12: GOFETCH.ELF https in-process (issue #1447) ------------------
# The host TLS 1.3 fixture peer (setup hook) is relayed at 10.0.0.2:24533.
# GOFETCH dials in-process via tls.Dial; FETCHS.BIN is not exec'd. The
# handshake and GET complete in this process (single goroutine).
# M71k (#1570): FETCHS.BIN no longer exists, so the serial-absent probe
# below can no longer be proven "by a binary that is not built" -- it is
# the identity the retired live-tls13 spec named.
vgate_run 12 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-12' \
    --net '$RUN_DIR/cap12.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24533:relay --net-tcp-respond-relay 127.0.0.1:24533 \
    --script '$RUN_DIR/script-gofetch.txt' \
    --script-expect "gofetch: ready" --timeout 180

vgate_assert 12 serial-contains 'gofetch: open id='
vgate_assert 12 serial-contains 'gofetch: url https://10.0.0.2:24533/'
vgate_assert 12 serial-contains 'gofetch: dial 10.0.0.2 24533 leaf.example.com'
vgate_assert 12 serial-contains 'gofetch: handshake ok'
vgate_assert 12 serial-contains 'gofetch: request sent'
vgate_assert 12 serial-contains 'live-web-https-ok'
vgate_assert 12 serial-contains 'gofetch: body complete'
vgate_assert 12 serial-contains 'gofetch: ready'
vgate_assert 12 serial-absent 'FETCHS.BIN'
vgate_assert 12 serial-absent 'gofetch: helper'
vgate_assert 12 serial-absent 'gofetch: tcp'
vgate_assert 12 serial-absent 'gofetch: error'
vgate_assert 12 serial-absent 'web: fetch '
vgate_assert 12 serial-absent 'GET / HTTP'
vgate_assert 12 serial-absent 'fatal error: runtime: cannot allocate memory'
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
assert "gofetch: handshake ok" in ser, "in-process TLS handshake did not complete"
assert "live-web-https-ok" in ser, "the fixture body was not read"
assert "FETCHS.BIN" not in ser, "FETCHS.BIN spawn marker present"
assert "gofetch: helper" not in ser, "the Zig TLS helper was exec'd"
assert "gofetch: tcp" not in ser, "Go opened a cleartext TCP socket"
assert "GET / HTTP" not in ser, "a cleartext GET was logged"
print("live-web 12 https in-process ok (GOFETCH tls.Dial, body, no FETCHS)")
PY

# --- boot 13: M69b console-ink re-measure in the web boot (#1592) ----------
# live-web 01-12 are shim-compositing (GOTABWM.ELF is not on the share;
# serial: "wm: autostart gotabwm: GOTABWM.ELF not on the share"). The
# M69b numbers came from this shape. Observed 2026-09-21 on this spec's
# first boot-13 run (macOS 27.2 / arm64, VZ): after web: settled, the
# band below WEB.ELF's 40,28 512x384 window held console-green
# 4747/82792 (5.734%) at +3 s and 4646/82792 (5.612%) at +20 s -- the
# M69b ~5.8% 20 s figure, already at plateau. Kernel fg_rgb = 0x00ff00.
# There is no seat, so paint_scene still blits the full-screen terminal
# and this probe pins that ink. A seated boot is go-wm-console-ink
# (#1561): paint_scene skips the terminal blit while the seat owns the
# layer (M71c) but the present must still flush. Skipping the drain
# outright leaves the pre-seat console frame (measured 1789 green pixels).
vgate_file script-ink-3s.txt <<'EOF'
echo web-ink-3s
EOF

vgate_file script-ink-20s.txt <<'EOF'
echo web-ink-20s
echo web-ink-done
EOF

vgate_run 13 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/ink' \
    --script '$RUN_DIR/script-local.txt' \
    --script2 '$RUN_DIR/script-ink-3s.txt' --script2-after "web: settled" --script2-delay 3 \
    --snapshot-after "web-ink-3s" \
    --script3 '$RUN_DIR/script-ink-20s.txt' --script3-after "web-ink-3s" --script3-delay 17 \
    --snapshot-after "web-ink-20s" \
    --script-expect "web-ink-done" --timeout 180

vgate_assert 13 serial-absent 'web: budget over'
vgate_assert 13 serial-contains 'web: settled'
vgate_assert 13 serial-contains 'web-ink-3s'
vgate_assert 13 serial-contains 'web-ink-20s'
vgate_assert 13 serial-contains 'web-ink-done'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 snapshot 'ink-0.raw' <<'PY'
import os, sys
# First frame (3 s after settled). Shared sampler is below in the python
# assert so both frames are reported together; this check only proves the
# kind-4 stream wrote a 1280x720 BGRX scanout.
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280 * 720 * 4, "3s scanout size %d" % len(data)
print("live-web 13 3s snapshot %d bytes" % len(data))
PY
vgate_assert 13 snapshot 'ink-1.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280 * 720 * 4, "20s scanout size %d" % len(data)
print("live-web 13 20s snapshot %d bytes" % len(data))
PY
vgate_assert 13 python <<'PY'
import os, sys

W, H = 1280, 720
# WEB.ELF window is 40,28 512x384; sample the band the window cannot cover.
Y0, STEP = 450, 2
PAGE_BG = (0x18, 0x20, 0x26)

def load(name):
    path = os.path.join(os.environ["RUN_DIR"], name)
    data = open(path, "rb").read()
    if len(data) != W * H * 4:
        sys.exit("%s size %d, want %d" % (name, len(data), W * H * 4))
    return data

def px(data, x, y):
    k = (y * W + x) * 4
    return data[k + 2], data[k + 1], data[k]

def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))

def ink(rgb):
    return max(rgb) >= 100

def console_ink(rgb):
    r, g, b = rgb
    return g > 150 and r < 160 and b < 160

def measure(data, label):
    # Live-capture check: the WEB page fill at the declared window, or any
    # brighter ink there, so a blank/failed stream cannot pass.
    win = 0
    for yy in range(28 + 52, 28 + 200, STEP):
        for xx in range(40 + 10, 40 + 400, STEP):
            rgb = px(data, xx, yy)
            if near(rgb, PAGE_BG) or ink(rgb):
                win += 1
    tot = interior = green = 0
    for yy in range(Y0, H - 8, STEP):
        for xx in range(8, W - 8, STEP):
            rgb = px(data, xx, yy)
            tot += 1
            if ink(rgb):
                interior += 1
                if console_ink(rgb):
                    green += 1
    print("live-web 13 %s: window-page-bg=%d uncovered sampled=%d ink=%d (%.3f%%) console-green=%d (%.3f%%)"
          % (label, win, tot, interior, 100.0 * interior / tot if tot else 0.0,
             green, 100.0 * green / tot if tot else 0.0))
    if win < 200:
        sys.exit("FAIL: %s capture has no WEB window paint -- a blank scanout cannot prove the uncovered region" % label)
    return tot, interior, green

a = measure(load("ink-0.raw"), "3s")
b = measure(load("ink-1.raw"), "20s")
# Shim web boot: the full-screen kernel terminal is the desktop behind WEB.
# Pin the M69b ~5.8% console-green so a blank capture cannot pass and a
# seated paint cannot silently replace this measurement. The seated
# console-green=0 probe is go-wm-console-ink (#1561).
for label, m in (("3s", a), ("20s", b)):
    tot, interior, green = m
    pct = 100.0 * green / tot if tot else 0.0
    if green == 0:
        sys.exit("FAIL: %s uncovered band has 0 console-green -- this shim web boot previously measured ~5.8%% (M69b / #1592)" % label)
    if pct < 2.0 or pct > 12.0:
        sys.exit("FAIL: %s console-green %.3f%% outside the pinned shim band 2-12%% (M69b ~5.8%%)" % (label, pct))
print("live-web 13 console-ink: shim web boot still carries kernel console green in the uncovered band (M69b reproduced; seated probe is go-wm-console-ink)")
PY

# --- boot 14: M70d shard 1 corpus page, on the surviving consumer --------
# M71i (#1568): inherited from the retired live-doc-web boot 05. The fixture
# (CERN's first-website hub) is the corpus's own pinned bytes, and the page is
# readable from the compiled-in UA table alone -- no cascade, no script (ADR
# 0028 D2). The probe asserts a multi-paragraph real page, not a marker: the
# retired boot pinned 16 px of h1 ink, this one pins ink bands and text ink
# inside the client box so a page that failed to lay out cannot pass on its
# own `settled`.
vgate_run 14 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-14' \
    --script '$RUN_DIR/script-corpus.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 180

vgate_assert 14 serial-absent 'web: budget over'
vgate_assert 14 serial-contains 'web: url /host/CORPUS.HTML'
vgate_assert 14 serial-contains 'web: parse nodes='
vgate_assert 14 serial-contains 'web: layout blocks='
vgate_assert 14 serial-contains 'web: paint items='
vgate_assert 14 serial-contains 'web: settled'
vgate_assert 14 serial-contains 'web: ready'
vgate_assert 14 serial-absent 'web: error'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 snapshot 'snap-14-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'corpus'])
PY

# 15: type Wikipedia, click its internal link, back/forward/back, then GET.
# The fixed 2.5 s pointer transport pacing includes inert toolbar moves while
# the translated URL strokes arrive; every transition is independently pinned
# by program nav markers, real peer GET lines and final pixels.
vgate_run 15 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-15' \
    --net '$RUN_DIR/cap15.bin' --net-arp-respond 93.184.216.34 \
    --net-dns-respond 93.184.216.34 \
    --net-tcp-respond 93.184.216.34:24560:relay --net-tcp-respond-relay 127.0.0.1:24560 \
    --script '$RUN_DIR/script-m93-start.txt' \
    --input-string $'https://en.wikipedia.org:24560/wiki/Harbor\n' --input-string-after 'web: url-focus' \
    --pointer-virtio '100,68,c;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;100,68;42,95,c;50,67,c;66,67,c;50,67,c;515,123,c' \
    --pointer-virtio-after 'web: ready' \
    --snapshot-after 'web: nav https://en.wikipedia.org:24560/wiki/Harbor' \
    --snapshot-after 'web: nav https://en.wikipedia.org:24560/w/index.php?search=Zig' \
    --script-expect 'web: nav-ready n=6' --timeout 240

vgate_assert 15 serial-contains 'web: url-focus'
vgate_assert 15 serial-contains 'web: dns en.wikipedia.org 93.184.216.34'
vgate_assert 15 serial-contains 'web: tls en.wikipedia.org virelai-gate-roots-2026-09-14'
vgate_assert 15 serial-contains 'web: nav https://en.wikipedia.org:24560/m93-next'
vgate_assert 15 serial-contains 'web: history back'
vgate_assert 15 serial-contains 'web: history forward'
vgate_assert 15 serial-contains 'web: form-get'
vgate_assert 15 serial-contains 'web: nav https://en.wikipedia.org:24560/w/index.php?search=Zig'
vgate_assert 15 serial-contains 'web: nav-ready n=6'
vgate_assert 15 serial-absent 'web: error'
vgate_assert 15 serial-absent 'web: budget over'
vgate_assert 15 serial-absent '[EXC] parking:'
vgate_assert 15 python <<'PY'
import os, shutil
path = os.path.join(os.environ["RUN_DIR"], "m93-peer-24560.log")
peer = open(path).read()
assert "SNI en.wikipedia.org" in peer
assert "request GET /wiki/Harbor HTTP/1.0" in peer
assert "request GET /m93.css HTTP/1.0" in peer
assert peer.count("request GET /m93-next HTTP/1.0") >= 2, "forward did not refetch the internal link"
assert peer.count("request GET /wiki/Harbor HTTP/1.0") >= 3, "back navigation did not restore the article"
assert "request GET /w/index.php?search=Zig HTTP/1.0" in peer, "successful controls were not sent exactly"
assert "request POST " not in peer
os.makedirs(os.path.join("artifacts", "m93f", "runs"), exist_ok=True)
shutil.copyfile(path, os.path.join("artifacts", "m93f", "runs", "wiki-peer-evidence.log"))
print("M93f Wikipedia: DNS/SNI, typed URL, click, back/forward/back and exact GET proved")
PY
vgate_assert 15 snapshot 'snap-15-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4
pixels = [tuple(data[(y*1280+x)*4+i] for i in (2,1,0))
          for y in range(92,380) for x in range(40,552)]
assert sum(c == (0x18,0x20,0x26) for c in pixels) > 10000
assert sum(min(c) > 150 for c in pixels) > 20, "GET result page has no text"
print("M93f GET result scanout has page fill and text")
PY

# 16/17: independently type GitHub/MDN and follow one original internal link.
vgate_run 16 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-16' \
    --net '$RUN_DIR/cap16.bin' --net-arp-respond 93.184.216.34 --net-dns-respond 93.184.216.34 \
    --net-tcp-respond 93.184.216.34:24560:relay --net-tcp-respond-relay 127.0.0.1:24560 \
    --script '$RUN_DIR/script-m93-start.txt' \
    --input-chords ctrl-l --input-chords-after 'web: ready' \
    --input-string $'https://github.com:24560/mattn/go-runewidth\n' --input-string-after 'web: url-focus' \
    --pointer-virtio '42,95,c' --pointer-virtio-after 'web: nav https://github.com:24560/mattn/go-runewidth' \
    --snapshot-after 'web: nav https://github.com:24560/m93-next' \
    --script-expect 'web: nav-ready n=2' --timeout 240

vgate_assert 16 serial-contains 'web: dns github.com 93.184.216.34'
vgate_assert 16 serial-contains 'web: tls github.com virelai-gate-roots-2026-09-14'
vgate_assert 16 serial-contains 'web: nav https://github.com:24560/m93-next'
vgate_assert 16 serial-contains 'web: nav-ready n=2'
vgate_assert 16 serial-absent 'web: error'
vgate_assert 16 serial-absent 'web: budget over'
vgate_assert 16 serial-absent '[EXC] parking:'
vgate_assert 16 python <<'PY'
import os
peer = open(os.path.join(os.environ["RUN_DIR"], "m93-peer-24560.log")).read()
assert "SNI github.com" in peer
assert "request GET /mattn/go-runewidth HTTP/1.0" in peer
assert "request GET /m93-next HTTP/1.0" in peer
print("M93f GitHub stand-in GET/SNI and internal link proved")
PY
vgate_assert 16 snapshot 'snap-16-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
pixels = [tuple(data[(y*1280+x)*4+i] for i in (2,1,0))
          for y in range(92,160) for x in range(40,552)]
assert sum(min(c) > 150 for c in pixels) > 20, "internal page has no text"
print("M93f GitHub internal page scanout has text")
PY

vgate_run 17 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-17' \
    --net '$RUN_DIR/cap17.bin' --net-arp-respond 93.184.216.34 --net-dns-respond 93.184.216.34 \
    --net-tcp-respond 93.184.216.34:24560:relay --net-tcp-respond-relay 127.0.0.1:24560 \
    --script '$RUN_DIR/script-m93-start.txt' \
    --input-chords ctrl-l --input-chords-after 'web: ready' \
    --input-string $'https://developer.mozilla.org:24560/en-US/docs/Web/CSS/display\n' --input-string-after 'web: url-focus' \
    --pointer-virtio '42,95,c' --pointer-virtio-after 'web: nav https://developer.mozilla.org:24560/en-US/docs/Web/CSS/display' \
    --snapshot-after 'web: nav https://developer.mozilla.org:24560/m93-next' \
    --script-expect 'web: nav-ready n=2' --timeout 240

vgate_assert 17 serial-contains 'web: dns developer.mozilla.org 93.184.216.34'
vgate_assert 17 serial-contains 'web: tls developer.mozilla.org virelai-gate-roots-2026-09-14'
vgate_assert 17 serial-contains 'web: nav https://developer.mozilla.org:24560/m93-next'
vgate_assert 17 serial-contains 'web: nav-ready n=2'
vgate_assert 17 serial-absent 'web: error'
vgate_assert 17 serial-absent 'web: budget over'
vgate_assert 17 serial-absent '[EXC] parking:'
vgate_assert 17 python <<'PY'
import os
peer = open(os.path.join(os.environ["RUN_DIR"], "m93-peer-24560.log")).read()
assert "SNI developer.mozilla.org" in peer
assert "request GET /en-US/docs/Web/CSS/display HTTP/1.0" in peer
assert "request GET /m93-next HTTP/1.0" in peer
print("M93f MDN stand-in GET/SNI and internal link proved")
PY
vgate_assert 17 snapshot 'snap-17-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
pixels = [tuple(data[(y*1280+x)*4+i] for i in (2,1,0))
          for y in range(92,160) for x in range(40,552)]
assert sum(min(c) > 150 for c in pixels) > 20, "internal page has no text"
print("M93f MDN internal page scanout has text")
PY

# 18: name mismatch. Reverting the browser verification/SNI name to the old
# leaf.example.com incorrectly passes this peer and makes this negative red.
vgate_run 18 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --net '$RUN_DIR/cap18.bin' --net-arp-respond 93.184.216.34 --net-dns-respond 93.184.216.34 \
    --net-tcp-respond 93.184.216.34:24561:relay --net-tcp-respond-relay 127.0.0.1:24561 \
    --script '$RUN_DIR/script-m93-name.txt' --script-expect 'web: ready' --timeout 180

vgate_assert 18 serial-contains 'web: error tls-hostname-mismatch'
vgate_assert 18 serial-contains 'web: ready'
vgate_assert 18 serial-absent 'web: fetch '
vgate_assert 18 serial-absent 'web: tls '
vgate_assert 18 serial-absent 'web: budget over'
vgate_assert 18 serial-absent '[EXC] parking:'
vgate_assert 18 python <<'PY'
import os
peer = open(os.path.join(os.environ["RUN_DIR"], "m93-peer-24561.log")).read()
assert "SNI wrong.example.com" in peer
assert "m93f-peer: request " not in peer, "wrong-host request escaped validation"
print("M93f wrong-host browser refuses before GET")
PY

vgate_run 19 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --net '$RUN_DIR/cap19.bin' --net-arp-respond 93.184.216.34 --net-dns-respond 93.184.216.34 \
    --net-tcp-respond 93.184.216.34:24562:relay --net-tcp-respond-relay 127.0.0.1:24562 \
    --script '$RUN_DIR/script-m93-expired.txt' --script-expect 'web: ready' --timeout 180

vgate_assert 19 serial-contains 'web: error tls-expired'
vgate_assert 19 serial-absent 'web: fetch '
vgate_assert 19 serial-absent 'web: tls '
vgate_assert 19 serial-absent 'web: budget over'
vgate_assert 19 serial-absent '[EXC] parking:'

# 20: the real production build must reject the very CA that gate builds trust.
vgate_run 20 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --net '$RUN_DIR/cap20.bin' --net-arp-respond 93.184.216.34 --net-dns-respond 93.184.216.34 \
    --net-tcp-respond 93.184.216.34:24560:relay --net-tcp-respond-relay 127.0.0.1:24560 \
    --script '$RUN_DIR/script-m93-production.txt' --script-expect 'web: ready' --timeout 180

vgate_assert 20 serial-contains 'tls: roots virelai-nss-15-940706e6f856'
vgate_assert 20 serial-contains 'web: error tls-unknown-root'
vgate_assert 20 serial-absent 'web: fetch '
vgate_assert 20 serial-absent 'web: tls '
vgate_assert 20 serial-absent 'web: budget over'
vgate_assert 20 serial-absent '[EXC] parking:'

# 21: cold largest retained-work reference and actual kernel ownership receipt.
# Receipt sampling is anchored after the program's published frame, not an
# estimated heap counter. The script's receipt text is independently asserted.
vgate_run 21 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-m93-largest.txt' \
    --script2 '$RUN_DIR/script-m93-receipt.txt' --script2-after 'web: ready' \
    --script-expect 'record_failures=0 unrecorded_pages=0 reaped=0' --timeout 180

vgate_assert 21 serial-contains 'web: url /host/M93-LARGEST.HTML'
vgate_assert 21 serial-contains 'web: settled'
vgate_assert 21 serial-contains 'web: ready'
vgate_assert 21 serial-contains 'runtime-receipt: pid='
vgate_assert 21 serial-absent 'web: budget over'
vgate_assert 21 serial-absent 'web: error'
vgate_assert 21 serial-absent '[EXC] parking:'
vgate_assert 21 python <<'PY'
import os, re
serial = open(os.environ["VG_SER"], errors="replace").read()
receipts = [line for line in serial.splitlines()
            if line.startswith("runtime-receipt: pid=") and " name=WEB.ELF " in line]
assert receipts, "no intact WEB ownership receipt"
fields = dict(re.findall(r"(\w+)=([^\s]+)", receipts[-1]))
assert int(fields["peak_pages"]) <= 3072, receipts[-1]
assert int(fields["peak_regions"]) <= 12, receipts[-1]
assert int(fields["record_failures"]) == 0, receipts[-1]
budgets = [line for line in serial.splitlines() if line.startswith("web: budget ")]
assert budgets
times = dict(re.findall(r"([\w-]+)=(\d+)", budgets[-1]))
assert int(times["layout-ms"])+int(times["paint-ms"]) <= 500, budgets[-1]
print("M93 largest reference actual demand/region/render ceilings proved:", receipts[-1])
PY

# --- boot 22: M93g reference 'borders' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 22 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-22' \
    --script '$RUN_DIR/script-ref-borders.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 22 serial-contains 'web: url /host/BORDERS.HTML'
vgate_assert 22 serial-contains 'web: parse nodes='
vgate_assert 22 serial-contains 'web: layout blocks='
vgate_assert 22 serial-contains 'web: paint items='
vgate_assert 22 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 22 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 22 serial-contains 'web: settled'
vgate_assert 22 serial-contains 'web: repaint items='
vgate_assert 22 serial-contains 'web: ready'
vgate_assert 22 serial-absent 'web: error'
vgate_assert 22 serial-absent 'web: budget over'
vgate_assert 22 serial-absent '[EXC] parking:'
vgate_assert 22 snapshot 'snap-22-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'borders'])
PY

# --- boot 23: M93g reference 'box-model' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 23 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-23' \
    --script '$RUN_DIR/script-ref-box-model.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 23 serial-contains 'web: url /host/BOX-MODEL.HTML'
vgate_assert 23 serial-contains 'web: parse nodes='
vgate_assert 23 serial-contains 'web: layout blocks='
vgate_assert 23 serial-contains 'web: paint items='
vgate_assert 23 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 23 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 23 serial-contains 'web: settled'
vgate_assert 23 serial-contains 'web: repaint items='
vgate_assert 23 serial-contains 'web: ready'
vgate_assert 23 serial-absent 'web: error'
vgate_assert 23 serial-absent 'web: budget over'
vgate_assert 23 serial-absent '[EXC] parking:'
vgate_assert 23 snapshot 'snap-23-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'box-model'])
PY

# --- boot 24: M93g reference 'boxes-block' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 24 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-24' \
    --script '$RUN_DIR/script-ref-boxes-block.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 24 serial-contains 'web: url /host/BOXES-BLOCK.HTML'
vgate_assert 24 serial-contains 'web: parse nodes='
vgate_assert 24 serial-contains 'web: layout blocks='
vgate_assert 24 serial-contains 'web: paint items='
vgate_assert 24 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 24 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 24 serial-contains 'web: settled'
vgate_assert 24 serial-contains 'web: repaint items='
vgate_assert 24 serial-contains 'web: ready'
vgate_assert 24 serial-absent 'web: error'
vgate_assert 24 serial-absent 'web: budget over'
vgate_assert 24 serial-absent '[EXC] parking:'
vgate_assert 24 snapshot 'snap-24-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'boxes-block'])
PY

# --- boot 25: M93g reference 'boxes-collapse' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 25 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-25' \
    --script '$RUN_DIR/script-ref-boxes-collapse.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 25 serial-contains 'web: url /host/BOXES-COLLAPSE.HTML'
vgate_assert 25 serial-contains 'web: parse nodes='
vgate_assert 25 serial-contains 'web: layout blocks='
vgate_assert 25 serial-contains 'web: paint items='
vgate_assert 25 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 25 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 25 serial-contains 'web: settled'
vgate_assert 25 serial-contains 'web: repaint items='
vgate_assert 25 serial-contains 'web: ready'
vgate_assert 25 serial-absent 'web: error'
vgate_assert 25 serial-absent 'web: budget over'
vgate_assert 25 serial-absent '[EXC] parking:'
vgate_assert 25 snapshot 'snap-25-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'boxes-collapse'])
PY

# --- boot 26: M93g reference 'boxes-flex' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 26 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-26' \
    --script '$RUN_DIR/script-ref-boxes-flex.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 26 serial-contains 'web: url /host/BOXES-FLEX.HTML'
vgate_assert 26 serial-contains 'web: parse nodes='
vgate_assert 26 serial-contains 'web: layout blocks='
vgate_assert 26 serial-contains 'web: paint items='
vgate_assert 26 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 26 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 26 serial-contains 'web: settled'
vgate_assert 26 serial-contains 'web: repaint items='
vgate_assert 26 serial-contains 'web: ready'
vgate_assert 26 serial-absent 'web: error'
vgate_assert 26 serial-absent 'web: budget over'
vgate_assert 26 serial-absent '[EXC] parking:'
vgate_assert 26 snapshot 'snap-26-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'boxes-flex'])
PY

# --- boot 27: M93g reference 'colors' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 27 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-27' \
    --script '$RUN_DIR/script-ref-colors.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 27 serial-contains 'web: url /host/COLORS.HTML'
vgate_assert 27 serial-contains 'web: parse nodes='
vgate_assert 27 serial-contains 'web: layout blocks='
vgate_assert 27 serial-contains 'web: paint items='
vgate_assert 27 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 27 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 27 serial-contains 'web: settled'
vgate_assert 27 serial-contains 'web: repaint items='
vgate_assert 27 serial-contains 'web: ready'
vgate_assert 27 serial-absent 'web: error'
vgate_assert 27 serial-absent 'web: budget over'
vgate_assert 27 serial-absent '[EXC] parking:'
vgate_assert 27 snapshot 'snap-27-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'colors'])
PY

# --- boot 28: M93g reference 'degradation' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 28 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-28' \
    --script '$RUN_DIR/script-ref-degradation.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 28 serial-contains 'web: url /host/DEGRADATION.HTML'
vgate_assert 28 serial-contains 'web: parse nodes='
vgate_assert 28 serial-contains 'web: layout blocks='
vgate_assert 28 serial-contains 'web: paint items='
vgate_assert 28 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 28 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 28 serial-contains 'web: settled'
vgate_assert 28 serial-contains 'web: repaint items='
vgate_assert 28 serial-contains 'web: ready'
vgate_assert 28 serial-absent 'web: error'
vgate_assert 28 serial-absent 'web: budget over'
vgate_assert 28 serial-absent '[EXC] parking:'
vgate_assert 28 snapshot 'snap-28-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'degradation'])
PY

# --- boot 29: M93g reference 'display-tables' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 29 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-29' \
    --script '$RUN_DIR/script-ref-display-tables.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 29 serial-contains 'web: url /host/DISPLAY-TABLES.HTML'
vgate_assert 29 serial-contains 'web: parse nodes='
vgate_assert 29 serial-contains 'web: layout blocks='
vgate_assert 29 serial-contains 'web: paint items='
vgate_assert 29 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 29 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 29 serial-contains 'web: settled'
vgate_assert 29 serial-contains 'web: repaint items='
vgate_assert 29 serial-contains 'web: ready'
vgate_assert 29 serial-absent 'web: error'
vgate_assert 29 serial-absent 'web: budget over'
vgate_assert 29 serial-absent '[EXC] parking:'
vgate_assert 29 snapshot 'snap-29-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'display-tables'])
PY

# --- boot 30: M93g reference 'flex' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 30 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-30' \
    --script '$RUN_DIR/script-ref-flex.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 30 serial-contains 'web: url /host/FLEX.HTML'
vgate_assert 30 serial-contains 'web: parse nodes='
vgate_assert 30 serial-contains 'web: layout blocks='
vgate_assert 30 serial-contains 'web: paint items='
vgate_assert 30 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 30 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 30 serial-contains 'web: settled'
vgate_assert 30 serial-contains 'web: repaint items='
vgate_assert 30 serial-contains 'web: ready'
vgate_assert 30 serial-absent 'web: error'
vgate_assert 30 serial-absent 'web: budget over'
vgate_assert 30 serial-absent '[EXC] parking:'
vgate_assert 30 snapshot 'snap-30-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'flex'])
PY

# --- boot 31: M93g reference 'fonts' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 31 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-31' \
    --script '$RUN_DIR/script-ref-fonts.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 31 serial-contains 'web: url /host/FONTS.HTML'
vgate_assert 31 serial-contains 'web: parse nodes='
vgate_assert 31 serial-contains 'web: layout blocks='
vgate_assert 31 serial-contains 'web: paint items='
vgate_assert 31 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 31 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 31 serial-contains 'web: settled'
vgate_assert 31 serial-contains 'web: repaint items='
vgate_assert 31 serial-contains 'web: ready'
vgate_assert 31 serial-absent 'web: error'
vgate_assert 31 serial-absent 'web: budget over'
vgate_assert 31 serial-absent '[EXC] parking:'
vgate_assert 31 snapshot 'snap-31-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'fonts'])
PY

# --- boot 32: M93g reference 'forms' -- in-guest render vs pinned guest hash --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present. Owner-authorized exception (#1999): the approved M93e
# golden predates M93f's intentional `[x]` checkbox overlay
# (TestInitialCheckedStateIsPaintedBeforeEditing), so no guest render can equal
# it. The comparator still enforces manifest, fonts, geometry and exact crop
# pixels -- but against the deterministic guest hash re-observed on 2026-11-15
# after M99m's coverage faces and M99o's linear-light blending moved glyph edge
# pixels (the guest's delta vs the approved golden is still exactly the 15-px
# checkbox-overlay region; original pin 3ba79ded... was observed 2026-10-08).
# Any drift in EITHER direction goes red.
vgate_run 32 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-32' \
    --script '$RUN_DIR/script-ref-forms.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 32 serial-contains 'web: url /host/FORMS.HTML'
vgate_assert 32 serial-contains 'web: parse nodes='
vgate_assert 32 serial-contains 'web: layout blocks='
vgate_assert 32 serial-contains 'web: paint items='
vgate_assert 32 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 32 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 32 serial-contains 'web: settled'
vgate_assert 32 serial-contains 'web: repaint items='
vgate_assert 32 serial-contains 'web: ready'
vgate_assert 32 serial-absent 'web: error'
vgate_assert 32 serial-absent 'web: budget over'
vgate_assert 32 serial-absent '[EXC] parking:'
vgate_assert 32 snapshot 'snap-32-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'forms',
                       '--expect-actual',
                       '7e6d860f4ffd705f541bb5c99499f6ce44e41e20d25406f226e795490230d18c'])
PY

# --- boot 33: M93g reference 'github' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 33 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-33' \
    --script '$RUN_DIR/script-ref-github.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 33 serial-contains 'web: url /host/GITHUB.HTML'
vgate_assert 33 serial-contains 'web: parse nodes='
vgate_assert 33 serial-contains 'web: layout blocks='
vgate_assert 33 serial-contains 'web: paint items='
vgate_assert 33 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 33 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 33 serial-contains 'web: settled'
vgate_assert 33 serial-contains 'web: repaint items='
vgate_assert 33 serial-contains 'web: ready'
vgate_assert 33 serial-absent 'web: error'
vgate_assert 33 serial-absent 'web: budget over'
vgate_assert 33 serial-absent '[EXC] parking:'
vgate_assert 33 snapshot 'snap-33-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'github'])
PY

# --- boot 34: M93g reference 'mdn' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 34 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-34' \
    --script '$RUN_DIR/script-ref-mdn.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 34 serial-contains 'web: url /host/MDN.HTML'
vgate_assert 34 serial-contains 'web: parse nodes='
vgate_assert 34 serial-contains 'web: layout blocks='
vgate_assert 34 serial-contains 'web: paint items='
vgate_assert 34 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 34 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 34 serial-contains 'web: settled'
vgate_assert 34 serial-contains 'web: repaint items='
vgate_assert 34 serial-contains 'web: ready'
vgate_assert 34 serial-absent 'web: error'
vgate_assert 34 serial-absent 'web: budget over'
vgate_assert 34 serial-absent '[EXC] parking:'
vgate_assert 34 snapshot 'snap-34-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'mdn'])
PY

# --- boot 35: M93g reference 'selectors' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 35 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-35' \
    --script '$RUN_DIR/script-ref-selectors.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 35 serial-contains 'web: url /host/SELECTORS.HTML'
vgate_assert 35 serial-contains 'web: parse nodes='
vgate_assert 35 serial-contains 'web: layout blocks='
vgate_assert 35 serial-contains 'web: paint items='
vgate_assert 35 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 35 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 35 serial-contains 'web: settled'
vgate_assert 35 serial-contains 'web: repaint items='
vgate_assert 35 serial-contains 'web: ready'
vgate_assert 35 serial-absent 'web: error'
vgate_assert 35 serial-absent 'web: budget over'
vgate_assert 35 serial-absent '[EXC] parking:'
vgate_assert 35 snapshot 'snap-35-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'selectors'])
PY

# --- boot 36: M93g reference 'wikipedia' -- in-guest render vs approved golden --
# One page, one boot, one exec. The boot ends on `web: ready`, printed after
# the repaint's present; the snapshot assert runs the ADR 0028 D9 comparator,
# which crops by WEB's own viewport marker and requires the exact manifest hash.
vgate_run 36 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-36' \
    --script '$RUN_DIR/script-ref-wikipedia.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 36 serial-contains 'web: url /host/WIKIPEDIA.HTML'
vgate_assert 36 serial-contains 'web: parse nodes='
vgate_assert 36 serial-contains 'web: layout blocks='
vgate_assert 36 serial-contains 'web: paint items='
vgate_assert 36 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 36 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 36 serial-contains 'web: settled'
vgate_assert 36 serial-contains 'web: repaint items='
vgate_assert 36 serial-contains 'web: ready'
vgate_assert 36 serial-absent 'web: error'
vgate_assert 36 serial-absent 'web: budget over'
vgate_assert 36 serial-absent '[EXC] parking:'
vgate_assert 36 snapshot 'snap-36-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'wikipedia'])
PY

# --- boot 37: M99p reference 'fonts-family' -- serif role end to end ------
# One page, one boot, one exec. font-family:serif must reach the registry's
# serif role (Noto Serif) in the guest, not alias to Inter: the probe's
# serif-face/serif-resolve markers prove the role loaded and the comparator
# grades the pixels against the approved golden.
vgate_run 37 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-37' \
    --script '$RUN_DIR/script-ref-fonts-family.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 37 serial-contains 'web: url /host/FONTS-FAMILY.HTML'
vgate_assert 37 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype serif=truetype'
vgate_assert 37 serial-contains 'serif-face=yes'
vgate_assert 37 serial-contains 'serif-resolve=serif'
vgate_assert 37 serial-contains 'web: paint items='
vgate_assert 37 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 37 serial-contains 'web: settled'
vgate_assert 37 serial-contains 'web: repaint items='
vgate_assert 37 serial-contains 'web: ready'
vgate_assert 37 serial-absent 'web: error'
vgate_assert 37 serial-absent 'web: budget over'
vgate_assert 37 serial-absent '[EXC] parking:'
vgate_assert 37 snapshot 'snap-37-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'fonts-family'])
PY

# --- boot 38: M99p reference 'fonts-size' -- relative sizes + weights ------
# One page, one boot, one exec. em/rem/smaller/larger and the absolute-size
# keywords resolve to px in the cascade; numeric weights 100-900 map to the
# two-weight engine (>=600 -> the real bold face). The comparator grades the
# rendered result against the approved golden, so a wrong resolved size is a
# wrong pixel, not a silent pass.
vgate_run 38 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-38' \
    --script '$RUN_DIR/script-ref-fonts-size.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 38 serial-contains 'web: url /host/FONTS-SIZE.HTML'
vgate_assert 38 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype serif=truetype'
vgate_assert 38 serial-contains 'web: paint items='
vgate_assert 38 serial-contains 'web: viewport css=1280x720 x=0 y=64 w=512 h=288 s=0'
vgate_assert 38 serial-contains 'web: settled'
vgate_assert 38 serial-contains 'web: repaint items='
vgate_assert 38 serial-contains 'web: ready'
vgate_assert 38 serial-absent 'web: error'
vgate_assert 38 serial-absent 'web: budget over'
vgate_assert 38 serial-absent '[EXC] parking:'
vgate_assert 38 snapshot 'snap-38-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'tools/web-proof/compare.py', sys.argv[1], 'fonts-size'])
PY

# --- boot 39 (M126a #2593): the address bar + navigation leg --------------
# One boot, all file-channel loads so every transition is instant. The chord
# channel types ctrl-l + the path (its marker wait is keyed to the run
# deadline, unlike --input-string's fixed 40 s, which expired before
# url-focus on this boot — observed 2026-10-18); the pointer channel then
# clicks the back/forward/reload chips, the history chip, a dropdown row,
# and reopens the dropdown LAST so the kind-4 snapshot cannot drain after
# the pick closed it (observed: the capture outran an open menu while queued
# pointer steps were still draining). Inert hovers pace the fixed 2.5 s
# pointer transport around the typed navigation and each reload. Snapshots
# grade PAGE after the repaint and after back, NEXT after the typed URL, and
# the open dropdown's pixels (plate, selected row, cursor bar) so "history
# list shown" is proven on the scanout, not only on serial.
vgate_run 39 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-39' \
    --script '$RUN_DIR/script-local.txt' \
    --input-chords 'ctrl-l,/,h,o,s,t,/,N,E,X,T,.,H,T,M,L,return' --input-chords-after 'web: ready' \
    --pointer-virtio '100,68;100,68;100,68;100,68;100,68;50,67,c;100,68;100,68;100,68;66,67,c;100,68;100,68;100,68;85,69,c;100,68;100,68;100,68;537,69,c;100,68;100,68;300,100,c;100,68;100,68;537,69,c' \
    --pointer-virtio-after 'web: ready' \
    --snapshot-after 'web: repaint' \
    --snapshot-after 'web: nav /host/NEXT.HTML' \
    --snapshot-after 'web: history n=3' \
    --script-expect 'web: history n=3' --timeout 240

vgate_assert 39 serial-absent 'web: budget over'
vgate_assert 39 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 39 serial-contains 'web: url-focus'
vgate_assert 39 serial-count 'web: url /host/NEXT.HTML' 3
vgate_assert 39 serial-count 'web: nav /host/NEXT.HTML' 2
vgate_assert 39 serial-contains 'web: history back'
vgate_assert 39 serial-contains 'web: history forward'
vgate_assert 39 serial-contains 'web: reload /host/NEXT.HTML'
vgate_assert 39 serial-contains 'web: history n=2'
vgate_assert 39 serial-contains 'web: history 0 /host/NEXT.HTML'
vgate_assert 39 serial-contains 'web: history 1 /host/PAGE.HTML'
vgate_assert 39 serial-contains 'web: history pick /host/PAGE.HTML'
vgate_assert 39 serial-contains 'web: nav-ready n=4'
vgate_assert 39 serial-contains 'web: history n=3'
vgate_assert 39 serial-absent 'web: error'
vgate_assert 39 serial-absent '[EXC] parking:'
vgate_assert 39 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "web: url /host/PAGE.HTML",
    "web: url-focus",
    "web: nav /host/NEXT.HTML",
    "web: history back",
    "web: nav /host/PAGE.HTML",
    "web: history forward",
    "web: reload /host/NEXT.HTML",
    "web: history n=2",
    "web: history pick /host/PAGE.HTML",
    "web: nav-ready n=4",
    "web: history n=3",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
print("live-web 39 nav ordering ok (type->load, back, forward, reload, list, pick, relist)")
PY
vgate_assert 39 snapshot 'snap-39-0.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'page'])
PY
vgate_assert 39 snapshot 'snap-39-1.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'next'])
PY
vgate_assert 39 snapshot 'snap-39-2.raw' <<'PY'
import sys
sys.path.insert(0, 'user/go/browser')
import pixel_probe
# The approved PAGE raster, decoded by the probe's own PNG reader.
want = pixel_probe.decode_png('user/go/browser/testdata/presentation/page.png')
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
WX, WY = 40, 28  # WEB.ELF's raw-shim window origin
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
SURFACE = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the dropdown plate
RULE = (0x2e, 0x3a, 0x44)     # theme.Dark.Rule: border + selected-row fill
ACCENT = (0x3b, 0x82, 0xf6)   # theme.Dark.Accent: the cursor row's left bar
# The plate covers window x in [6,504), rows at window y=48+16i; three
# entries are listed (n=3), so rows 0-2 sit at window y in [48,96) ->
# scanout [76,124).
plate = ink = selrow = 0
for yy in range(76, 124):
    for xx in range(46, 544):
        c = px(xx, yy)
        if near(c, SURFACE):
            plate += 1
        if min(c) > 150:
            ink += 1
# Row 0 is the selected row (rule fill) and carries the accent cursor bar.
for xx in range(100, 540):
    if near(px(xx, 84), RULE):
        selrow += 1
selbar = sum(1 for yy in range(78, 90)
             if near(px(46, yy), ACCENT) or near(px(47, yy), ACCENT))
assert plate > 3000, "dropdown plate pixels %d" % plate
assert ink > 40, "history rows have no text ink: %d" % ink
assert selrow > 300, "selected row fill pixels %d" % selrow
assert selbar >= 8, "cursor accent bar pixels %d" % selbar
# Below the plate and its shadow the pick's target must be on screen:
# exact-match the PAGE raster rows (content crop rows 40..287 -> scanout
# 28+64+row), skipping the shim border columns (window x<4 or x>=508).
diff = 0
for row in range(40, 288):
    sy = WY + 64 + row
    for xx in range(44, 548):
        c = px(xx, sy)
        w = want[(row*512 + (xx-WX))*3:][:3]
        if c != (w[0], w[1], w[2]):
            diff += 1
assert diff == 0, "PAGE rows under the menu differ from the approved raster: %d px" % diff
print("live-web 39 history dropdown pixels ok (plate=%d ink=%d selrow=%d selbar=%d) + PAGE rows under it exact" %
      (plate, ink, selrow, selbar))
PY

# --- run v6: M117f (#2478, ADR 0057) — the v6 leg -------------------------
# The card's thesis is "WEB.ELF fetches https over a v6 literal"; the honest
# landable leg inside spec Touches is one step narrower, and this run pins
# both halves of that bound:
#   * WEB.ELF on https://[v6]:80/ names its refusal — 'web: error url'.
#     user/go/browser/url.go's validHost accepts DNS labels only ("No
#     userinfo, IPv6 ... is accepted"); webrender.URL stores a [4]byte
#     IPv4. A v6 literal never reaches a dial.
#   * The fetch itself is proven one layer down: GOWEB6.ELF (built in
#     setup, the go-net connect6 shape) vi.Dials the BRACKETED v6 literal
#     and does GET / -> 'HTTP/1.0 200 OK' against --net-tcp6-respond's
#     answer table — the same hermetic responder the v4 fetch legs use.
# A full https-over-v6 fetch needs a v6 URL grammar in the browser AND a
# TLS-capable v6 responder (the TCP6 responder speaks the HTTP answer
# table only — no :relay mode exists for v6): both are follow-on code
# outside this card's Touches. SLAAC gates script2 exactly like the
# go-net v6 run: a connect before 'net: v6 g6=... valid' refuses no_src6.

vgate_file web6.go <<'EOF'
package main

import (
    "time"
    "virelai/vi"
    "virelai/vsys"
)

func fail(s string) {
    vsys.Println("web6: FAIL " + s)
    vsys.Exit(1)
}

func main() {
    // M117f (#2478): the bracketed v6 literal — the tagged op-10 marshal.
    vsys.Println("web6: dialing [2001:db8:64::ff:fe00:2]:80")
    c, err := vi.DialTimeout("[2001:db8:64::ff:fe00:2]", 80, 5*time.Second)
    if err != nil { fail("dial " + err.Error()) }
    if !c.IsV6() { fail("conn not family v6") }
    vsys.Println("web6: connected")
    if _, err = c.Send([]byte("GET / HTTP/1.0\r\nHost: v6\r\n\r\n")); err != nil { fail("send") }
    c.SetRecvDeadline(5_000_000_000)
    buf := make([]byte, vi.TCPPayloadMax)
    n, err := c.Recv(buf)
    if err != nil || n < 15 || string(buf[:15]) != "HTTP/1.0 200 OK" { fail("GET response") }
    vsys.Println("web6: HTTP 200 over v6")
    if err = c.Close(); err != nil { fail("close") }
    vsys.Println("web6: done")
    vsys.Exit(0)
}
EOF

vgate_file script-v6-ready.txt <<'EOF'
echo v6-ready
EOF

# exec spawns asynchronously, so the two programs are sequenced by stage
# gates on their own markers: script2's WEB.ELF exec waits for SLAAC, and
# script3's GOWEB6 exec waits for WEB.ELF's own 'web: ready'. The run ends
# on 'web6: done' — a program marker, not a script echo — so the VM cannot
# stop before the fetch completed.
vgate_file script-v6.txt <<'EOF'
net ndp 2001:db8:64::ff:fe00:2
net ndp 2001:db8:64::ff:fe00:2
net ip6
exec WEB.ELF https://[2001:db8:64::ff:fe00:2]:80/
EOF

vgate_file script-v6-fetch.txt <<'EOF'
exec GOWEB6.ELF
EOF

vgate_setup_python <<'PY'
# Run v6: build GOWEB6.ELF onto the armed share — the same in-setup build
# shape go-net.spec uses for GOCONNECT6 (issue #2475).
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "web6-build"
tmp.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="GOWEB6", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "web6.go")], env=env, check=True)
PY

vgate_run v6 -- \
    --screen '$RUN_DIR/screen-v6' --via-virtio --cvc-snap \
    --net '$RUN_DIR/v6.cap' \
    --net-ra-respond '2001:db8:64::/64' \
    --net-ndp-respond '2001:db8:64::ff:fe00:2' \
    --net-tcp6-respond '[2001:db8:64::ff:fe00:2]:80' \
    --script '$RUN_DIR/script-v6-ready.txt' \
    --script2 '$RUN_DIR/script-v6.txt' --script2-after 'net: v6 g6=2001:db8:64::ff:fe00:1 valid' \
    --script3 '$RUN_DIR/script-v6-fetch.txt' --script3-after 'web: ready' \
    --script-expect 'web6: done' --timeout 180

vgate_assert v6 output-contains 'net-ra-respond: ENABLED'
vgate_assert v6 output-contains 'net-ndp-respond: ENABLED'
vgate_assert v6 output-contains 'net-tcp6-respond: ENABLED'
vgate_assert v6 serial-contains 'net: v6 g6=2001:db8:64::ff:fe00:1 valid'
vgate_assert v6 serial-contains 'net ndp: 2001:db8:64::ff:fe00:2 is at 02:00:00:00:00:02'
vgate_assert v6 serial-contains 'web: error url'
vgate_assert v6 serial-contains 'web: ready'
vgate_assert v6 serial-absent 'web: fetch '
vgate_assert v6 serial-contains 'web6: connected'
vgate_assert v6 serial-contains 'web6: HTTP 200 over v6'
vgate_assert v6 serial-contains 'web6: done'
vgate_assert v6 serial-absent 'web6: FAIL'
vgate_assert v6 serial-absent '[EXC] parking:'
vgate_assert v6 output-contains 'NET-TCP6: answered'

# --- boots 40-41 (M126b #2594): the bookmark leg --------------------------
# Boot 40 adds two pages (Ctrl+D), opens the sidebar (Ctrl+Shift+B), picks
# row 0, and deletes it — all over the chord channel, all file-channel
# loads. The store is the FLINT workspace shape on the armed share:
# streams/<uuid>.json + ws/bookmarks/{WORKSPACE.json,ATOMS.jsonl}, which the
# share-* asserts and a python glob read back after the run.
# Boot 41 is the SAME armed share on a fresh VM: the boot-time store
# inventory must report one surviving atom (the deleted row must stay
# deleted), the sidebar lists it, and Enter navigates there.
# Boot 40 opens the panel with bare Ctrl+B — Firefox's sidebar key, the
# same toggle as the card's Ctrl+Shift+B — so the scanout snapshot sees a
# raised window. Under shim compositing the kernel ALSO lowers the focused
# window on Ctrl+Shift+B (input.zig, Arc4 #238, kept with no WM coverage —
# OBSERVED: 'dui: lower-back id=2' precedes the app's own markers and the
# panel hides behind the terminal), so the mandated chord is exercised
# LAST, after the visible pick/remove — its marker evidence is binding.
vgate_run 40 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-40' \
    --script '$RUN_DIR/script-local.txt' \
    --input-chords 'ctrl-d,ctrl-l,/,h,o,s,t,/,N,E,X,T,.,H,T,M,L,return,ctrl-d,ctrl-b,return,delete,escape,ctrl-shift-b' --input-chords-after 'web: ready' \
    --snapshot-after 'web: bookmarks n=2' \
    --script-expect 'web: bookmarks n=1' --timeout 240

vgate_assert 40 serial-absent 'web: budget over'
vgate_assert 40 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 40 serial-contains 'web: bookmark-store ws=bookmarks atoms=0 migrated=0 error=-'
vgate_assert 40 serial-count 'web: bookmark added' 2
vgate_assert 40 serial-contains 'web: nav /host/NEXT.HTML'
vgate_assert 40 serial-contains 'web: bookmarks n=2'
vgate_assert 40 serial-contains 'web: bookmarks 0 /host/PAGE.HTML'
vgate_assert 40 serial-contains 'web: bookmarks 1 /host/NEXT.HTML'
vgate_assert 40 serial-contains 'web: bookmark pick /host/PAGE.HTML'
vgate_assert 40 serial-contains 'web: nav /host/PAGE.HTML'
vgate_assert 40 serial-contains 'web: bookmark removed'
vgate_assert 40 serial-contains 'web: bookmarks n=1'
vgate_assert 40 serial-contains 'web: bookmarks 0 /host/NEXT.HTML'
vgate_assert 40 serial-absent 'web: bookmark error'
vgate_assert 40 serial-absent 'web: error'
vgate_assert 40 serial-absent '[EXC] parking:'
vgate_assert 40 share-contains 'FLINT/ws/bookmarks/ATOMS.jsonl' '/host/NEXT.HTML'
vgate_assert 40 share-contains 'FLINT/ws/bookmarks/WORKSPACE.json' '"name":"bookmarks"'
vgate_assert 40 python <<'PY'
import glob, json, os
share = os.environ["VG_SHARE"]
recs = glob.glob(os.path.join(share, "FLINT", "streams", "*.json"))
assert recs, "no stream record under FLINT/streams"
names = [json.loads(open(r).read()).get("name") for r in recs]
assert "web-bookmarks" in names, "stream names %r" % names
body = open(os.path.join(share, "FLINT", "ws", "bookmarks", "ATOMS.jsonl")).read()
assert body.endswith("\n"), "torn atom append"
rows = [json.loads(l) for l in body.split("\n") if l]
assert len(rows) == 1, "expected the surviving atom only, got %d" % len(rows)
at = rows[0]
assert at["kind"] == "bookmark" and at["metadata"]["url"] == "/host/NEXT.HTML", at
assert at["name"] and at["hash"] and at["sig_hash"] and at["id"], at
print("live-web 40 store shape ok (stream record + one bookmark atom)")
PY
vgate_assert 40 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "web: bookmark added",
    "web: nav /host/NEXT.HTML",
    "web: bookmark added",
    "web: bookmarks n=2",
    "web: bookmark pick /host/PAGE.HTML",
    "web: nav /host/PAGE.HTML",
    "web: bookmark removed",
    "web: bookmarks n=1",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
print("live-web 40 bookmark ordering ok (add, nav, add, open, pick, nav, remove, ctrl-shift-b open)")
PY
vgate_assert 40 snapshot 'snap-40-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
WX, WY = 40, 28  # WEB.ELF's raw-shim window origin
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
SURFACE = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the panel plate
RULE = (0x2e, 0x3a, 0x44)     # theme.Dark.Rule: divider + selected row
ACCENT = (0x3b, 0x82, 0xf6)   # theme.Dark.Accent: the current-page bar
# The docked panel covers window x in [0,172), y in [48,368) -> scanout
# [40,212) x [76,396). Row 0 (the selected row) sits at window y 66..82.
plate = ink = selrow = 0
for yy in range(76, 396):
    for xx in range(41, 211):
        c = px(xx, yy)
        if near(c, SURFACE):
            plate += 1
        if min(c) > 150:
            ink += 1
for xx in range(41, 210):
    if near(px(xx, 76 + 18 + 8), RULE):
        selrow += 1
divider = sum(1 for yy in range(80, 390) if near(px(40 + 171, yy), RULE))
assert plate > 20000, "sidebar plate pixels %d" % plate
assert ink > 40, "sidebar rows have no text ink: %d" % ink
assert selrow > 80, "selected row fill pixels %d" % selrow
assert divider > 200, "panel divider pixels %d" % divider
print("live-web 40 sidebar pixels ok (plate=%d ink=%d selrow=%d divider=%d)" %
      (plate, ink, selrow, divider))
PY

vgate_run 41 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-41' \
    --script '$RUN_DIR/script-local.txt' \
    --input-chords 'ctrl-shift-b,return' --input-chords-after 'web: ready' \
    --script-expect 'web: nav-ready n=1' --timeout 180

vgate_assert 41 serial-absent 'web: budget over'
vgate_assert 41 serial-contains ' bookmarks=1 '
vgate_assert 41 serial-contains 'web: bookmark-store ws=bookmarks atoms=1 migrated=0 error=-'
vgate_assert 41 serial-contains 'web: bookmarks n=1'
vgate_assert 41 serial-contains 'web: bookmarks 0 /host/NEXT.HTML'
vgate_assert 41 serial-contains 'web: bookmark pick /host/NEXT.HTML'
vgate_assert 41 serial-contains 'web: nav /host/NEXT.HTML'
vgate_assert 41 serial-contains 'web: nav-ready n=1'
vgate_assert 41 serial-absent 'web: bookmark error'
vgate_assert 41 serial-absent 'web: error'
vgate_assert 41 serial-absent '[EXC] parking:'
vgate_assert 41 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    " bookmarks=1 ",
    "web: bookmark-store ws=bookmarks atoms=1",
    "web: bookmarks n=1",
    "web: bookmarks 0 /host/NEXT.HTML",
    "web: bookmark pick /host/NEXT.HTML",
    "web: nav /host/NEXT.HTML",
    "web: nav-ready n=1",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
print("live-web 41 restart ordering ok (boot inventory, list, pick, nav)")
PY

# --- boot 42 (M126c #2595): the find-in-page leg -----------------------------
# One boot, a file-channel load, all chords. 'the' has exactly two matches
# on PAGE.HTML ("the greedy", "the browser" — "The end." is a capital-T
# miss, the matcher is case-sensitive). Each keystroke recomputes and
# re-lands on match 1; the two Enters step forward and wrap; Escape closes.
# The f1 pads are no-ops the open bar consumes — ~8 s of dwell so the
# kind-4 snapshot request lands while the highlights are still on the
# scanout. The capture anchors on script3's 'find-shot' echo (3 s after
# hit=2/2, mid-dwell) instead of the hit marker itself: observed 2026-10-19
# under fleet load, a marker-anchored request was serviced after Escape's
# clean repaint (the same race boots 45-47's comment describes).
vgate_run 42 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-42' \
    --script '$RUN_DIR/script-local.txt' \
    --input-chords 'ctrl-f,t,h,e,return,return,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,escape' --input-chords-after 'web: ready' \
    --script3 '$RUN_DIR/script-find-shot.txt' --script3-after 'web: find hit=2/2' --script3-delay 3 \
    --snapshot-after 'find-shot' \
    --script-expect 'web: find close' --timeout 180

vgate_assert 42 serial-absent 'web: budget over'
vgate_assert 42 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 42 serial-contains 'web: find open'
vgate_assert 42 serial-contains "web: find 'the' n=2"
vgate_assert 42 serial-contains 'web: find hit=1/2'
vgate_assert 42 serial-contains 'web: find hit=2/2'
vgate_assert 42 serial-contains 'web: find close'
vgate_assert 42 serial-absent 'web: error'
vgate_assert 42 serial-absent '[EXC] parking:'
vgate_assert 42 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "web: find open",
    "web: find 'the' n=2",
    "web: find hit=1/2",
    "web: find hit=2/2",
    "web: find hit=1/2",   # the second Enter wraps to the first match
    "web: find close",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
print("live-web 42 find ordering ok (open, search, step, wrap, close)")
PY
vgate_assert 42 snapshot 'snap-42-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
MATCH   = (0xb5, 0x89, 0x00)  # every match's fill
CURRENT = (0xcb, 0x4b, 0x16)  # the current match's fill
SURFACE = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the bar's plate
# The scanout is the whole screen; the content letterbox sits under the
# window at (40,92). Count the two highlight inks anywhere in the window
# and the bar's plate on its docked row (window y 352..368 -> scanout
# 380..396).
match = current = 0
for yy in range(92, 380):
    for xx in range(40, 552):
        c = px(xx, yy)
        if near(c, MATCH):
            match += 1
        elif near(c, CURRENT):
            current += 1
# The strip's plate is the row minus the field inset (the 404-px PageBg
# field at window x 44..448): ~3.3k surface pixels minus its ink, so the
# threshold counts the plate edges, not the whole row.
plate = sum(1 for yy in range(380, 396) for xx in range(40, 552) if near(px(xx, yy), SURFACE))
assert match >= 20, "match highlight pixels %d" % match
assert current >= 10, "current-match highlight pixels %d" % current
assert plate > 1500, "find bar plate pixels %d" % plate
print("live-web 42 highlight pixels ok (match=%d current=%d plate=%d)" % (match, current, plate))
PY

# --- boot 43 (M126d #2596): per-tab zoom + the font_size setting ----------
# One boot, all file-channel. `settings set font_size large` publishes the
# row on the armed share BEFORE the exec, so WEB's startup read already
# resolves base=17 (the kernel's rasterized text ladder: 11/13/17 px). The
# chords then step the per-tab zoom ladder — Ctrl+= thrice (110/125/150),
# Ctrl+- once (125), Ctrl+0 (100), and four more Ctrl+= back up to 175 — and
# each step re-runs the cascade + layout: `web: layout` reprints with
# different lines/height — reflow, not bitmap scaling. `web: zoom <pct>`
# prints only AFTER the reflowed frame is on the wire (the
# announceNavigation rule). A kind-4 snapshot request rides queue 3 and is
# serviced at the guest's own pace — under load that is seconds — and the
# runner's pendingSnapPath is a single slot a later trigger overwrites (the
# boot-42 collision). So the two snapshots hang on frames that stay current:
# `web: repaint` is followed by the settle sleeps and the ready wait, and
# `web: zoom 175` is the run's last marker — its frame cannot go stale while
# the drain window holds the VM. This boot runs LAST so the persisted row
# cannot reach the exact-match golden legs.
vgate_file script-zoom.txt <<'EOF'
settings set font_size large
exec WEB.ELF /host/PAGE.HTML
EOF

vgate_run 43 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-43' \
    --script '$RUN_DIR/script-zoom.txt' \
    --input-chords 'ctrl-=,ctrl-=,ctrl-=,ctrl--,ctrl-0,ctrl-=,ctrl-=,ctrl-=,ctrl-=' --input-chords-after 'web: ready' \
    --snapshot-after 'web: repaint' \
    --snapshot-after 'web: zoom 175' \
    --script-expect 'web: zoom 175' --timeout 180

vgate_assert 43 serial-absent 'web: budget over'
vgate_assert 43 serial-contains 'settings: font_size=large'
vgate_assert 43 serial-contains 'web: font-size large base=17'
vgate_assert 43 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 43 serial-contains 'web: zoom 110'
vgate_assert 43 serial-contains 'web: zoom 125'
vgate_assert 43 serial-contains 'web: zoom 150'
vgate_assert 43 serial-contains 'web: zoom 100'
vgate_assert 43 serial-contains 'web: zoom 175'
vgate_assert 43 serial-count 'web: layout blocks=' 10
vgate_assert 43 serial-absent 'web: error'
vgate_assert 43 serial-absent '[EXC] parking:'
vgate_assert 43 share-contains 'SETTINGS.TXT' 'font_size=large'
vgate_assert 43 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "settings: font_size=large",
    "web: font-size large base=17",
    "web: zoom 110",
    "web: zoom 125",
    "web: zoom 150",
    "web: zoom 125",   # Ctrl+- steps back down the ladder
    "web: zoom 100",   # Ctrl+0 resets
    "web: zoom 110",
    "web: zoom 125",
    "web: zoom 150",
    "web: zoom 175",   # and back up past the start to the terminal rung
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
print("live-web 43 zoom ordering ok (setting read, up x3, down, reset, up to 175)")
PY
vgate_assert 43 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# Each `web: layout` reprint is a re-layout: index 0 is the initial load at
# zoom 100, 1-9 follow the nine zoom chords (110/125/150/125/100/110/125/
# 150/175). h and lines climb with the rung — a bitmap stretch would keep
# them flat — and Ctrl+0's reset restores the 100% shape exactly.
layouts = [(int(m.group(1)), int(m.group(2))) for m in
           re.finditer(r"web: layout blocks=\d+ lines=(\d+) h=(\d+)", ser)]
assert len(layouts) >= 10, "expected 10 layout prints (load + 9 zooms), got %d" % len(layouts)
l0, l150, l100, l175 = layouts[0], layouts[3], layouts[5], layouts[9]
assert l150[1] > l0[1], "zoom 150 height %d not above zoom 100 %d — no reflow" % (l150[1], l0[1])
assert l150[0] >= l0[0], "zoom 150 lines shrank: %d -> %d" % (l0[0], l150[0])
assert l100 == l0, "reset did not restore the 100%% shape: %r vs %r" % (l100, l0)
assert l175[1] > l150[1], "zoom 175 height %d not above zoom 150 %d" % (l175[1], l150[1])
print("live-web 43 reflow ok (h %d -> %d -> %d -> %d; lines %d -> %d -> %d -> %d)" %
      (l0[1], l150[1], l100[1], l175[1], l0[0], l150[0], l100[0], l175[0]))
PY
vgate_assert 43 snapshot 'snap-43-0.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
WX, WY = 40, 28  # WEB.ELF's raw-shim window origin
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
# The letterbox (window y 64..352 -> scanout 92..380): count bright text ink.
ink = 0
for yy in range(92, 380):
    for xx in range(40, 552):
        if min(px(xx, yy)) > 150:
            ink += 1
assert ink > 200, "no page ink at base 17: %d" % ink
print("live-web 43 base-17 page ink=%d" % ink)
PY
vgate_assert 43 snapshot 'snap-43-1.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
WX, WY = 40, 28
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
ink = 0
for yy in range(92, 380):
    for xx in range(40, 552):
        if min(px(xx, yy)) > 150:
            ink += 1
# The terminal zoom-175 frame is captured through the drain window. The
# scanout composite is guest-paced: under load this capture can still show
# a stale window, so the reflow proof is the serial layout geometry above —
# this probe only requires a live page frame in the letterbox.
assert ink > 200, "terminal frame ink %d" % ink
print("live-web 43 terminal frame ink=%d" % ink)
PY
vgate_assert 43 python <<'PY'
import glob, os
rd = os.environ["RUN_DIR"]
W = 1280
def load(name):
    hits = sorted(glob.glob(os.path.join(rd, name)))
    assert hits, "missing " + name
    return open(hits[-1], "rb").read()
def ink(d):
    # Bright text pixels inside the letterbox (window y 64..352 -> 92..380).
    n = 0
    for y in range(92, 380):
        for x in range(40, 552):
            k = (y*W+x)*4
            if min(d[k+2], d[k+1], d[k]) > 150:
                n += 1
    return n
base, zoom = load("snap-43-0.raw"), load("snap-43-1.raw")
ib, iz = ink(base), ink(zoom)
# Both captures must carry a rendered page; whether the second window shows
# the zoom-175 reflow or a pre-composite stale frame is transport timing,
# not app state — the in-guest `web: layout` geometry above is the reflow
# evidence. Report what was observed without grading on the race.
assert ib > 200 and iz > 200, "page ink missing: base=%d terminal=%d" % (ib, iz)
print("live-web 43 snapshots ok (letterbox ink %d -> %d)" % (ib, iz))
PY
# --- boot 44 (M126e #2597): the download leg --------------------------------
# The M126e PR carried this run without its staging (observed 2026-10-19:
# the trimmed spec that produced its evidence lived in artifacts/ and the
# vgate_file/setup lines never reached main). M126f restores them here.
# `settings set font_size medium` pins base=13 — the geometry the leg's
# evidence was produced at — so the 42,95 click does not depend on the
# settings row an earlier boot happened to leave (boot 43 sets large).
vgate_file script-dl.txt <<'EOF'
settings set font_size medium
exec WEB.ELF /host/DLPAGE.HTML
EOF

vgate_setup_python <<'PY'
# Boot 44's fixtures: the download-link page, the 4x4 QOI it points at
# (synthesized — every pixel a 0xfe RGB chunk, 14+16*4+8 = 86 bytes), and
# the mime-open targets the completion plate can exec (OPEN -> GOVIEW,
# FOLDER -> GOFILES; the leg exercises OPEN only).
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
shutil.copy(os.path.join("user", "go", "browser", "testdata", "gate-dl.html"),
            os.path.join(share, "DLPAGE.HTML"))
W = H = 4
qoi = bytearray(b"qoif") + (W).to_bytes(4, "big") + (H).to_bytes(4, "big") + bytes([4, 0])
for y in range(H):
    for x in range(W):
        qoi += bytes([0xfe, 0x30 + 20 * x, 0x60 + 20 * y, 0x90])
qoi += bytes([0, 0, 0, 0, 0, 0, 0, 1])
with open(os.path.join(share, "DLPIC.QOI"), "wb") as f:
    f.write(bytes(qoi))
for dst_name, build in (("GOVIEW.ELF", "bash tools/go/build-goview.sh"),
                        ("GOFILES.ELF", "bash tools/go/build-files.sh")):
    src = os.path.join(".build", "go", dst_name)
    if not os.path.exists(src):
        sys.exit(dst_name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, dst_name))
print("live-web 44/45-47: staged DLPAGE.HTML + DLPIC.QOI (86B 4x4) + GOVIEW.ELF + GOFILES.ELF")
PY

# DLPAGE.HTML's first link targets DLPIC.QOI — an image extension the
# mime table already knows, so the click downloads instead of navigating.
# The staged write steps over event-loop passes: `web: download start`,
# `web: download progress` on each tenth, the boot-09-shaped
# `web: download <path> <bytes>` at commit, then `web: download done` and
# the completion plate. 'o' is the plate's Open: mime dispatch execs
# GOVIEW.ELF on the saved file, and GOVIEW's own `gview:` markers prove the
# decode landed. Under the shim there is no Go seat — the kind-22 reports
# and the kind-12 toast refuse fast, and `seat=`/`web: download toast`
# say so instead of pretending.
vgate_run 44 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-44' \
    --script '$RUN_DIR/script-dl.txt' \
    --pointer-virtio '42,95,c' --pointer-virtio-after 'web: ready' \
    --input-chords 'o' --input-chords-after 'web: download done ' \
    --snapshot-after 'web: download done ' \
    --script-expect 'gview: ready' --timeout 180

vgate_assert 44 serial-absent 'web: budget over'
vgate_assert 44 serial-contains 'web: url /host/DLPAGE.HTML'
vgate_assert 44 serial-contains 'web: ev kind=3'
vgate_assert 44 serial-contains 'web: download start DLPIC.QOI bytes='
vgate_assert 44 serial-contains 'web: download progress '
vgate_assert 44 serial-contains 'web: download /host/WEB-DL-DLPIC.QOI '
vgate_assert 44 serial-contains 'web: download done DLPIC.QOI type=image'
vgate_assert 44 serial-contains 'web: download toast '
vgate_assert 44 serial-contains 'web: download open GOVIEW.ELF /host/WEB-DL-DLPIC.QOI'
vgate_assert 44 serial-contains 'web: download open launched pid='
vgate_assert 44 serial-contains 'gview: open id='
vgate_assert 44 serial-contains 'gview: loaded WEB-DL-DLPIC.QOI 4x4'
vgate_assert 44 serial-contains 'gview: ready'
vgate_assert 44 serial-absent 'web: error'
vgate_assert 44 serial-absent 'web: download failed'
vgate_assert 44 serial-absent '[EXC] parking:'
vgate_assert 44 python <<'PY'
import glob, os
share = os.environ["VG_SHARE"]
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "web: download start DLPIC.QOI",
    "web: download progress ",
    "web: download /host/WEB-DL-DLPIC.QOI",
    "web: download done DLPIC.QOI type=image",
    "web: download toast ",
    "web: download open GOVIEW.ELF",
    "gview: loaded WEB-DL-DLPIC.QOI 4x4",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
dl = glob.glob(os.path.join(share, "WEB-DL-DLPIC.QOI"))
assert dl, "no downloaded file on the share"
size = os.path.getsize(dl[0])
assert size == 86, "download size %d" % size
rows = [l for l in open(os.path.join(share, "WEB-DOWNLOADS.TXT"),
        errors="replace").read().splitlines() if l and not l.startswith("#")]
assert any("WEB-DL-DLPIC.QOI" in r for r in rows), "no ledger row for the download"
print("live-web 44 download ok (start->progress->done->toast->open ordering, "
      "share file %dB, ledger row)" % size)
PY

# --- boot 45: M124b (#2581) save-as through appkit.FilePicker -------------
# Ctrl-Shift-S raises the shared picker seeded with the download name
# (PAGE.HTML — nine runes, nine backspaces to clear); a fresh name resolves
# against the picker's cwd (/host) and the picked path runs the same
# write+ledger leg as the fixed download, printing both markers. The host
# assert compares WEBSAVE.HTML to the PAGE.HTML fixture byte-for-byte.
vgate_run 45 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-45' \
    --script '$RUN_DIR/script-local.txt' \
    --input-chords 'ctrl-shift-s,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,W,E,B,S,A,V,E,.,H,T,M,L,return' --input-chords-after 'web: ready' \
    --snapshot-after 'web: save /host/WEBSAVE.HTML' \
    --script-expect 'web: save /host/WEBSAVE.HTML' --timeout 240

vgate_assert 45 serial-absent 'web: budget over'
vgate_assert 45 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 45 serial-contains 'web: download /host/WEBSAVE.HTML '
vgate_assert 45 serial-contains 'web: save /host/WEBSAVE.HTML'
vgate_assert 45 serial-absent 'web: save cancel'
vgate_assert 45 serial-absent 'web: error'
vgate_assert 45 serial-absent '[EXC] parking:'
vgate_assert 45 python <<'PY'
import os
share = os.environ["VG_SHARE"]
got = open(os.path.join(share, "WEBSAVE.HTML"), "rb").read()
want = open(os.path.join(share, "PAGE.HTML"), "rb").read()
if got != want:
    print("SAVE-AS MISMATCH: %d bytes, want the PAGE.HTML body (%d bytes)" % (len(got), len(want)))
    raise SystemExit(1)
print("save-as verified on the host: WEBSAVE.HTML == PAGE.HTML (%d bytes)" % len(got))
PY

# --- boots 46-48 (M126f #2598): the acceptance journey, K=3 -----------------
# One boot per leg of the daily-browser arc, three independent VMs: a file-
# channel load of PAGE.HTML (browse), Ctrl+D (bookmark),
# Ctrl+F on 'the' with step+wrap (find), Ctrl+=/Ctrl+-/Ctrl+0 with a real
# reflow (zoom), a typed-URL nav to DLPAGE.HTML and a click on its .QOI link
# (download), then the completion plate's 'o' -> mime.Open -> GOVIEW (open in
# viewer). The armed share is shared, so the boot-40 NEXT bookmark rides in:
# 46 adds PAGE (atoms 1->2), 47 toggles it off (2->1), 48 adds it again
# (1->2) — each boot's startup inventory proves the previous boot's store
# write persisted, and the ' downloads=' count climbs one per leg.
#
# Channel choreography: everything keyboard-side is one --input-chords burst
# after 'web: ready' (the chord watcher's marker wait is keyed to the run
# deadline, unlike --input-string's fixed 40 s). The two six-second dwells
# are pads the open find bar / the idle page swallow (f1 is consumed by the
# bar — outside it f1 toggles the diagnostics overlay, which would pollute
# the zoom-100 crop; 'g' binds to nothing in the page keymap).
#
# The kind-4 captures are marker-raced (the request copies the CURRENT
# scanout), so the snapshots anchor on markers that postdate their frames:
# snap-N-0 on 'find-shot' — script3's echo 4 s into the f1 dwell, well after
# the hit=2/2 highlight paint; snap-N-1 on 'web: url-focus' — the page crop
# (letterbox region) is untouched by the chrome url bar, and the zoom-100
# reflow+repaint settled during the 'g' dwell; snap-N-2 on 'web: download
# done ' — script2's 8 s delay keeps the plate up until its echo 'web-dl-open'
# releases --input-key's 'o' (macOS keycode 0x1f). The gview end state is
# serial-evidenced (open/loaded/ready markers); a fourth capture on 'gview:
# ready' never lands — the run ends on that marker before queue 3 is serviced.
# 'settings set font_size medium' pins base=13 so the zoom-100 crop is the
# approved golden whatever settings row boot 43 left.

vgate_file script-journey.txt <<'EOF'
settings set font_size medium
exec WEB.ELF /host/PAGE.HTML
EOF

vgate_file script-dl-open.txt <<'EOF'
echo web-dl-open
EOF

vgate_file script-find-shot.txt <<'EOF'
echo find-shot
EOF

vgate_run 46 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-46' \
    --script '$RUN_DIR/script-journey.txt' \
    --input-chords 'ctrl-d,ctrl-f,t,h,e,return,return,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,escape,ctrl-=,ctrl-=,ctrl-0,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,ctrl-l,/,h,o,s,t,/,D,L,P,A,G,E,.,H,T,M,L,return' --input-chords-after 'web: ready' \
    --pointer-virtio '42,95,c' --pointer-virtio-after 'web: nav-ready n=1' \
    --snapshot-after 'find-shot' \
    --snapshot-after 'web: url-focus' \
    --snapshot-after 'web-dl-open' \
    --script2 '$RUN_DIR/script-dl-open.txt' --script2-after 'web: download done ' --script2-delay 8 \
    --script3 '$RUN_DIR/script-find-shot.txt' --script3-after 'web: find hit=2/2' --script3-delay 4 \
    --input-key 31 --input-key-after 'web-dl-open' \
    --script-expect 'gview: ready' --timeout 240

vgate_assert 46 serial-absent 'web: budget over'
vgate_assert 46 serial-contains 'settings: font_size=medium'
vgate_assert 46 serial-contains 'web: font-size medium base=13'
vgate_assert 46 serial-contains ' bookmarks=1 '
vgate_assert 46 serial-contains ' downloads=2'
vgate_assert 46 serial-contains 'web: bookmark-store ws=bookmarks atoms=1 migrated=0'
vgate_assert 46 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 46 serial-contains 'web: settled'
vgate_assert 46 serial-contains 'web: ready'
vgate_assert 46 serial-contains 'web: bookmark added'
vgate_assert 46 serial-contains 'web: find open'
vgate_assert 46 serial-contains "web: find 'the' n=2"
vgate_assert 46 serial-contains 'web: find hit=1/2'
vgate_assert 46 serial-contains 'web: find hit=2/2'
vgate_assert 46 serial-contains 'web: find close'
vgate_assert 46 serial-contains 'web: zoom 110'
vgate_assert 46 serial-contains 'web: zoom 125'
vgate_assert 46 serial-contains 'web: zoom 100'
vgate_assert 46 serial-count 'web: layout blocks=' 5
vgate_assert 46 serial-contains 'web: url-focus'
vgate_assert 46 serial-contains 'web: url /host/DLPAGE.HTML'
vgate_assert 46 serial-contains 'web: nav /host/DLPAGE.HTML'
vgate_assert 46 serial-contains 'web: navigated'
vgate_assert 46 serial-contains 'web: nav-ready n=1'
vgate_assert 46 serial-contains 'web: download start DLPIC.QOI bytes=86'
vgate_assert 46 serial-contains 'web: download progress '
vgate_assert 46 serial-contains 'web: download /host/WEB-DL-DLPIC.QOI '
vgate_assert 46 serial-contains 'web: download done DLPIC.QOI type=image'
vgate_assert 46 serial-contains 'web: download toast '
vgate_assert 46 serial-contains 'web-dl-open'
vgate_assert 46 serial-contains 'web: download open GOVIEW.ELF /host/WEB-DL-DLPIC.QOI'
vgate_assert 46 serial-contains 'web: download open launched pid='
vgate_assert 46 serial-contains 'gview: open id='
vgate_assert 46 serial-contains 'gview: loaded WEB-DL-DLPIC.QOI 4x4'
vgate_assert 46 serial-contains 'gview: ready'
vgate_assert 46 serial-absent 'web: error'
vgate_assert 46 serial-absent 'web: offline '
vgate_assert 46 serial-absent 'web: download failed'
vgate_assert 46 serial-absent 'web: bookmark error'
vgate_assert 46 serial-absent '[EXC] parking:'
vgate_assert 46 share-contains 'WEB-DOWNLOADS.TXT' 'WEB-DL-DLPIC.QOI'
vgate_assert 46 share-contains 'FLINT/ws/bookmarks/ATOMS.jsonl' '/host/NEXT.HTML'
vgate_assert 46 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "settings: font_size=medium",
    "web: font-size medium base=13",
    "web: stores ",
    "web: url /host/PAGE.HTML",
    "web: ready",
    "web: bookmark added",
    "web: find open",
    "web: find 'the' n=2",
    "web: find hit=1/2",
    "web: find hit=2/2",
    "web: find hit=1/2",
    "web: find close",
    "web: zoom 110",
    "web: zoom 125",
    "web: zoom 100",
    "web: url-focus",
    "web: url /host/DLPAGE.HTML",
    "web: nav /host/DLPAGE.HTML",
    "web: nav-ready n=1",
    "web: download start DLPIC.QOI bytes=86",
    "web: download progress ",
    "web: download /host/WEB-DL-DLPIC.QOI",
    "web: download done DLPIC.QOI type=image",
    "web: download toast ",
    "web-dl-open",
    "web: download open GOVIEW.ELF /host/WEB-DL-DLPIC.QOI",
    "web: download open launched pid=",
    "gview: open id=",
    "gview: loaded WEB-DL-DLPIC.QOI 4x4",
    "gview: ready"
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
print("live-web 46 journey ordering ok (browse -> bookmark -> sidebar -> find -> zoom -> nav -> download -> open)")
PY
vgate_assert 46 snapshot 'snap-46-0.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
MATCH   = (0xb5, 0x89, 0x00)  # every match's fill
CURRENT = (0xcb, 0x4b, 0x16)  # the current match's fill
SURFACE = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the bar's plate
match = current = 0
for yy in range(92, 380):
    for xx in range(40, 552):
        c = px(xx, yy)
        if near(c, MATCH):
            match += 1
        elif near(c, CURRENT):
            current += 1
plate = sum(1 for yy in range(380, 396) for xx in range(40, 552) if near(px(xx, yy), SURFACE))
assert match >= 20, "match highlight pixels %d" % match
assert current >= 10, "current-match highlight pixels %d" % current
assert plate > 1500, "find bar plate pixels %d" % plate
print("live-web 46 journey: find highlights ok (match=%d current=%d plate=%d)" % (match, current, plate))
PY
vgate_assert 46 snapshot 'snap-46-1.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'page'])
PY
vgate_assert 46 snapshot 'snap-46-2.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
SURFACE  = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the plate fill
ACCENT   = (0x3b, 0x82, 0xf6)  # theme.Dark.Accent: top rule + chip labels
RULE     = (0x2e, 0x3a, 0x44)  # theme.Dark.Rule: chip borders
CHROMEBG = (0x11, 0x17, 0x1c)  # theme.Dark.ChromeBg: chip fill
# The completion plate: 232x42 at window (272,318) -> scanout x[312,544),
# y[346,388). The 8 s script2 delay keeps 'o' back so the kind-4 stream
# cannot outrun the plate.
surface = accent_top = chips = chipink = 0
for yy in range(346, 388):
    for xx in range(312, 544):
        c = px(xx, yy)
        if near(c, SURFACE):
            surface += 1
        elif near(c, CHROMEBG):
            chips += 1
accent_top = sum(1 for xx in range(312, 544) if near(px(xx, 346), ACCENT))
# Accent ink below the top rule = the OPEN/FOLDER/X labels.
for yy in range(360, 384):
    for xx in range(312, 544):
        if near(px(xx, yy), ACCENT):
            chipink += 1
assert surface > 4000, "plate surface pixels %d" % surface
assert accent_top > 150, "plate accent top-rule pixels %d" % accent_top
assert chips > 800, "plate chip fill pixels %d" % chips
assert chipink > 10, "plate chip label pixels %d" % chipink
print("live-web 46 journey: completion plate ok (surface=%d accent_top=%d chips=%d chipink=%d)" %
      (surface, accent_top, chips, chipink))
PY
vgate_assert 46 python <<'PY'
import glob, os, json
share = os.environ["VG_SHARE"]
rows = [l for l in open(os.path.join(share, "FLINT", "ws", "bookmarks",
        "ATOMS.jsonl")).read().splitlines() if l]
import json
atoms = [json.loads(l)["metadata"]["url"] for l in rows]
assert sorted(atoms) == ["/host/NEXT.HTML", "/host/PAGE.HTML"], atoms
dl = glob.glob(os.path.join(share, "WEB-DL-DLPIC.QOI"))
assert dl, "no downloaded file on the share"
assert os.path.getsize(dl[0]) == 86, "download size %d" % os.path.getsize(dl[0])
led = [l for l in open(os.path.join(share, "WEB-DOWNLOADS.TXT"),
       errors="replace").read().splitlines() if l and not l.startswith("#")]
assert any("WEB-DL-DLPIC.QOI" in r for r in led), "no ledger row for the download"
print("live-web 46 share state ok (atoms, 86B download, ledger row)")
PY
vgate_run 47 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-47' \
    --script '$RUN_DIR/script-journey.txt' \
    --input-chords 'ctrl-d,ctrl-f,t,h,e,return,return,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,escape,ctrl-=,ctrl-=,ctrl-0,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,ctrl-l,/,h,o,s,t,/,D,L,P,A,G,E,.,H,T,M,L,return' --input-chords-after 'web: ready' \
    --pointer-virtio '42,95,c' --pointer-virtio-after 'web: nav-ready n=1' \
    --snapshot-after 'find-shot' \
    --snapshot-after 'web: url-focus' \
    --snapshot-after 'web-dl-open' \
    --script2 '$RUN_DIR/script-dl-open.txt' --script2-after 'web: download done ' --script2-delay 8 \
    --script3 '$RUN_DIR/script-find-shot.txt' --script3-after 'web: find hit=2/2' --script3-delay 4 \
    --input-key 31 --input-key-after 'web-dl-open' \
    --script-expect 'gview: ready' --timeout 240

vgate_assert 47 serial-absent 'web: budget over'
vgate_assert 47 serial-contains 'settings: font_size=medium'
vgate_assert 47 serial-contains 'web: font-size medium base=13'
vgate_assert 47 serial-contains ' bookmarks=2 '
vgate_assert 47 serial-contains ' downloads=3'
vgate_assert 47 serial-contains 'web: bookmark-store ws=bookmarks atoms=2 migrated=0'
vgate_assert 47 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 47 serial-contains 'web: settled'
vgate_assert 47 serial-contains 'web: ready'
vgate_assert 47 serial-contains 'web: bookmark removed'
vgate_assert 47 serial-contains 'web: find open'
vgate_assert 47 serial-contains "web: find 'the' n=2"
vgate_assert 47 serial-contains 'web: find hit=1/2'
vgate_assert 47 serial-contains 'web: find hit=2/2'
vgate_assert 47 serial-contains 'web: find close'
vgate_assert 47 serial-contains 'web: zoom 110'
vgate_assert 47 serial-contains 'web: zoom 125'
vgate_assert 47 serial-contains 'web: zoom 100'
vgate_assert 47 serial-count 'web: layout blocks=' 5
vgate_assert 47 serial-contains 'web: url-focus'
vgate_assert 47 serial-contains 'web: url /host/DLPAGE.HTML'
vgate_assert 47 serial-contains 'web: nav /host/DLPAGE.HTML'
vgate_assert 47 serial-contains 'web: navigated'
vgate_assert 47 serial-contains 'web: nav-ready n=1'
vgate_assert 47 serial-contains 'web: download start DLPIC.QOI bytes=86'
vgate_assert 47 serial-contains 'web: download progress '
vgate_assert 47 serial-contains 'web: download /host/WEB-DL-DLPIC.QOI '
vgate_assert 47 serial-contains 'web: download done DLPIC.QOI type=image'
vgate_assert 47 serial-contains 'web: download toast '
vgate_assert 47 serial-contains 'web-dl-open'
vgate_assert 47 serial-contains 'web: download open GOVIEW.ELF /host/WEB-DL-DLPIC.QOI'
vgate_assert 47 serial-contains 'web: download open launched pid='
vgate_assert 47 serial-contains 'gview: open id='
vgate_assert 47 serial-contains 'gview: loaded WEB-DL-DLPIC.QOI 4x4'
vgate_assert 47 serial-contains 'gview: ready'
vgate_assert 47 serial-absent 'web: error'
vgate_assert 47 serial-absent 'web: offline '
vgate_assert 47 serial-absent 'web: download failed'
vgate_assert 47 serial-absent 'web: bookmark error'
vgate_assert 47 serial-absent '[EXC] parking:'
vgate_assert 47 share-contains 'WEB-DOWNLOADS.TXT' 'WEB-DL-DLPIC.QOI'
vgate_assert 47 share-contains 'FLINT/ws/bookmarks/ATOMS.jsonl' '/host/NEXT.HTML'
vgate_assert 47 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "settings: font_size=medium",
    "web: font-size medium base=13",
    "web: stores ",
    "web: url /host/PAGE.HTML",
    "web: ready",
    "web: bookmark removed",
    "web: find open",
    "web: find 'the' n=2",
    "web: find hit=1/2",
    "web: find hit=2/2",
    "web: find hit=1/2",
    "web: find close",
    "web: zoom 110",
    "web: zoom 125",
    "web: zoom 100",
    "web: url-focus",
    "web: url /host/DLPAGE.HTML",
    "web: nav /host/DLPAGE.HTML",
    "web: nav-ready n=1",
    "web: download start DLPIC.QOI bytes=86",
    "web: download progress ",
    "web: download /host/WEB-DL-DLPIC.QOI",
    "web: download done DLPIC.QOI type=image",
    "web: download toast ",
    "web-dl-open",
    "web: download open GOVIEW.ELF /host/WEB-DL-DLPIC.QOI",
    "web: download open launched pid=",
    "gview: open id=",
    "gview: loaded WEB-DL-DLPIC.QOI 4x4",
    "gview: ready"
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
print("live-web 47 journey ordering ok (browse -> bookmark -> sidebar -> find -> zoom -> nav -> download -> open)")
PY
vgate_assert 47 snapshot 'snap-47-0.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
MATCH   = (0xb5, 0x89, 0x00)  # every match's fill
CURRENT = (0xcb, 0x4b, 0x16)  # the current match's fill
SURFACE = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the bar's plate
match = current = 0
for yy in range(92, 380):
    for xx in range(40, 552):
        c = px(xx, yy)
        if near(c, MATCH):
            match += 1
        elif near(c, CURRENT):
            current += 1
plate = sum(1 for yy in range(380, 396) for xx in range(40, 552) if near(px(xx, yy), SURFACE))
assert match >= 20, "match highlight pixels %d" % match
assert current >= 10, "current-match highlight pixels %d" % current
assert plate > 1500, "find bar plate pixels %d" % plate
print("live-web 47 journey: find highlights ok (match=%d current=%d plate=%d)" % (match, current, plate))
PY
vgate_assert 47 snapshot 'snap-47-1.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'page'])
PY
vgate_assert 47 snapshot 'snap-47-2.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
SURFACE  = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the plate fill
ACCENT   = (0x3b, 0x82, 0xf6)  # theme.Dark.Accent: top rule + chip labels
RULE     = (0x2e, 0x3a, 0x44)  # theme.Dark.Rule: chip borders
CHROMEBG = (0x11, 0x17, 0x1c)  # theme.Dark.ChromeBg: chip fill
# The completion plate: 232x42 at window (272,318) -> scanout x[312,544),
# y[346,388). The 8 s script2 delay keeps 'o' back so the kind-4 stream
# cannot outrun the plate.
surface = accent_top = chips = chipink = 0
for yy in range(346, 388):
    for xx in range(312, 544):
        c = px(xx, yy)
        if near(c, SURFACE):
            surface += 1
        elif near(c, CHROMEBG):
            chips += 1
accent_top = sum(1 for xx in range(312, 544) if near(px(xx, 346), ACCENT))
# Accent ink below the top rule = the OPEN/FOLDER/X labels.
for yy in range(360, 384):
    for xx in range(312, 544):
        if near(px(xx, yy), ACCENT):
            chipink += 1
assert surface > 4000, "plate surface pixels %d" % surface
assert accent_top > 150, "plate accent top-rule pixels %d" % accent_top
assert chips > 800, "plate chip fill pixels %d" % chips
assert chipink > 10, "plate chip label pixels %d" % chipink
print("live-web 47 journey: completion plate ok (surface=%d accent_top=%d chips=%d chipink=%d)" %
      (surface, accent_top, chips, chipink))
PY
vgate_assert 47 python <<'PY'
import glob, os, json
share = os.environ["VG_SHARE"]
rows = [l for l in open(os.path.join(share, "FLINT", "ws", "bookmarks",
        "ATOMS.jsonl")).read().splitlines() if l]
import json
atoms = [json.loads(l)["metadata"]["url"] for l in rows]
assert atoms == ["/host/NEXT.HTML"], "PAGE must stay removed: %r" % atoms
dl = glob.glob(os.path.join(share, "WEB-DL-DLPIC.QOI"))
assert dl, "no downloaded file on the share"
assert os.path.getsize(dl[0]) == 86, "download size %d" % os.path.getsize(dl[0])
led = [l for l in open(os.path.join(share, "WEB-DOWNLOADS.TXT"),
       errors="replace").read().splitlines() if l and not l.startswith("#")]
assert any("WEB-DL-DLPIC.QOI" in r for r in led), "no ledger row for the download"
print("live-web 47 share state ok (atoms, 86B download, ledger row)")
PY
vgate_run 48 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-48' \
    --script '$RUN_DIR/script-journey.txt' \
    --input-chords 'ctrl-d,ctrl-f,t,h,e,return,return,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,f1,escape,ctrl-=,ctrl-=,ctrl-0,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,ctrl-l,/,h,o,s,t,/,D,L,P,A,G,E,.,H,T,M,L,return' --input-chords-after 'web: ready' \
    --pointer-virtio '42,95,c' --pointer-virtio-after 'web: nav-ready n=1' \
    --snapshot-after 'find-shot' \
    --snapshot-after 'web: url-focus' \
    --snapshot-after 'web-dl-open' \
    --script2 '$RUN_DIR/script-dl-open.txt' --script2-after 'web: download done ' --script2-delay 8 \
    --script3 '$RUN_DIR/script-find-shot.txt' --script3-after 'web: find hit=2/2' --script3-delay 4 \
    --input-key 31 --input-key-after 'web-dl-open' \
    --script-expect 'gview: ready' --timeout 240

vgate_assert 48 serial-absent 'web: budget over'
vgate_assert 48 serial-contains 'settings: font_size=medium'
vgate_assert 48 serial-contains 'web: font-size medium base=13'
vgate_assert 48 serial-contains ' bookmarks=1 '
vgate_assert 48 serial-contains ' downloads=4'
vgate_assert 48 serial-contains 'web: bookmark-store ws=bookmarks atoms=1 migrated=0'
vgate_assert 48 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 48 serial-contains 'web: settled'
vgate_assert 48 serial-contains 'web: ready'
vgate_assert 48 serial-contains 'web: bookmark added'
vgate_assert 48 serial-contains 'web: find open'
vgate_assert 48 serial-contains "web: find 'the' n=2"
vgate_assert 48 serial-contains 'web: find hit=1/2'
vgate_assert 48 serial-contains 'web: find hit=2/2'
vgate_assert 48 serial-contains 'web: find close'
vgate_assert 48 serial-contains 'web: zoom 110'
vgate_assert 48 serial-contains 'web: zoom 125'
vgate_assert 48 serial-contains 'web: zoom 100'
vgate_assert 48 serial-count 'web: layout blocks=' 5
vgate_assert 48 serial-contains 'web: url-focus'
vgate_assert 48 serial-contains 'web: url /host/DLPAGE.HTML'
vgate_assert 48 serial-contains 'web: nav /host/DLPAGE.HTML'
vgate_assert 48 serial-contains 'web: navigated'
vgate_assert 48 serial-contains 'web: nav-ready n=1'
vgate_assert 48 serial-contains 'web: download start DLPIC.QOI bytes=86'
vgate_assert 48 serial-contains 'web: download progress '
vgate_assert 48 serial-contains 'web: download /host/WEB-DL-DLPIC.QOI '
vgate_assert 48 serial-contains 'web: download done DLPIC.QOI type=image'
vgate_assert 48 serial-contains 'web: download toast '
vgate_assert 48 serial-contains 'web-dl-open'
vgate_assert 48 serial-contains 'web: download open GOVIEW.ELF /host/WEB-DL-DLPIC.QOI'
vgate_assert 48 serial-contains 'web: download open launched pid='
vgate_assert 48 serial-contains 'gview: open id='
vgate_assert 48 serial-contains 'gview: loaded WEB-DL-DLPIC.QOI 4x4'
vgate_assert 48 serial-contains 'gview: ready'
vgate_assert 48 serial-absent 'web: error'
vgate_assert 48 serial-absent 'web: offline '
vgate_assert 48 serial-absent 'web: download failed'
vgate_assert 48 serial-absent 'web: bookmark error'
vgate_assert 48 serial-absent '[EXC] parking:'
vgate_assert 48 share-contains 'WEB-DOWNLOADS.TXT' 'WEB-DL-DLPIC.QOI'
vgate_assert 48 share-contains 'FLINT/ws/bookmarks/ATOMS.jsonl' '/host/NEXT.HTML'
vgate_assert 48 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "settings: font_size=medium",
    "web: font-size medium base=13",
    "web: stores ",
    "web: url /host/PAGE.HTML",
    "web: ready",
    "web: bookmark added",
    "web: find open",
    "web: find 'the' n=2",
    "web: find hit=1/2",
    "web: find hit=2/2",
    "web: find hit=1/2",
    "web: find close",
    "web: zoom 110",
    "web: zoom 125",
    "web: zoom 100",
    "web: url-focus",
    "web: url /host/DLPAGE.HTML",
    "web: nav /host/DLPAGE.HTML",
    "web: nav-ready n=1",
    "web: download start DLPIC.QOI bytes=86",
    "web: download progress ",
    "web: download /host/WEB-DL-DLPIC.QOI",
    "web: download done DLPIC.QOI type=image",
    "web: download toast ",
    "web-dl-open",
    "web: download open GOVIEW.ELF /host/WEB-DL-DLPIC.QOI",
    "web: download open launched pid=",
    "gview: open id=",
    "gview: loaded WEB-DL-DLPIC.QOI 4x4",
    "gview: ready"
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
print("live-web 48 journey ordering ok (browse -> bookmark -> sidebar -> find -> zoom -> nav -> download -> open)")
PY
vgate_assert 48 snapshot 'snap-48-0.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
MATCH   = (0xb5, 0x89, 0x00)  # every match's fill
CURRENT = (0xcb, 0x4b, 0x16)  # the current match's fill
SURFACE = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the bar's plate
match = current = 0
for yy in range(92, 380):
    for xx in range(40, 552):
        c = px(xx, yy)
        if near(c, MATCH):
            match += 1
        elif near(c, CURRENT):
            current += 1
plate = sum(1 for yy in range(380, 396) for xx in range(40, 552) if near(px(xx, yy), SURFACE))
assert match >= 20, "match highlight pixels %d" % match
assert current >= 10, "current-match highlight pixels %d" % current
assert plate > 1500, "find bar plate pixels %d" % plate
print("live-web 48 journey: find highlights ok (match=%d current=%d plate=%d)" % (match, current, plate))
PY
vgate_assert 48 snapshot 'snap-48-1.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'page'])
PY
vgate_assert 48 snapshot 'snap-48-2.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
def near(c, want, tol=6):
    return all(abs(a-b) <= tol for a, b in zip(c, want))
SURFACE  = (0x22, 0x2d, 0x35)  # theme.Dark.Surface: the plate fill
ACCENT   = (0x3b, 0x82, 0xf6)  # theme.Dark.Accent: top rule + chip labels
RULE     = (0x2e, 0x3a, 0x44)  # theme.Dark.Rule: chip borders
CHROMEBG = (0x11, 0x17, 0x1c)  # theme.Dark.ChromeBg: chip fill
# The completion plate: 232x42 at window (272,318) -> scanout x[312,544),
# y[346,388). The 8 s script2 delay keeps 'o' back so the kind-4 stream
# cannot outrun the plate.
surface = accent_top = chips = chipink = 0
for yy in range(346, 388):
    for xx in range(312, 544):
        c = px(xx, yy)
        if near(c, SURFACE):
            surface += 1
        elif near(c, CHROMEBG):
            chips += 1
accent_top = sum(1 for xx in range(312, 544) if near(px(xx, 346), ACCENT))
# Accent ink below the top rule = the OPEN/FOLDER/X labels.
for yy in range(360, 384):
    for xx in range(312, 544):
        if near(px(xx, yy), ACCENT):
            chipink += 1
assert surface > 4000, "plate surface pixels %d" % surface
assert accent_top > 150, "plate accent top-rule pixels %d" % accent_top
assert chips > 800, "plate chip fill pixels %d" % chips
assert chipink > 10, "plate chip label pixels %d" % chipink
print("live-web 48 journey: completion plate ok (surface=%d accent_top=%d chips=%d chipink=%d)" %
      (surface, accent_top, chips, chipink))
PY
vgate_assert 48 python <<'PY'
import glob, os, json
share = os.environ["VG_SHARE"]
rows = [l for l in open(os.path.join(share, "FLINT", "ws", "bookmarks",
        "ATOMS.jsonl")).read().splitlines() if l]
import json
atoms = [json.loads(l)["metadata"]["url"] for l in rows]
assert sorted(atoms) == ["/host/NEXT.HTML", "/host/PAGE.HTML"], atoms
dl = glob.glob(os.path.join(share, "WEB-DL-DLPIC.QOI"))
assert dl, "no downloaded file on the share"
assert os.path.getsize(dl[0]) == 86, "download size %d" % os.path.getsize(dl[0])
led = [l for l in open(os.path.join(share, "WEB-DOWNLOADS.TXT"),
       errors="replace").read().splitlines() if l and not l.startswith("#")]
assert any("WEB-DL-DLPIC.QOI" in r for r in led), "no ledger row for the download"
print("live-web 48 share state ok (atoms, 86B download, ledger row)")
PY

# --- M121c (#2566) run 49: the '?' chord-hint overlay ----------------------
# '?' in browsing mode raises the appkit overlay fed by the chord registry;
# Esc closes it. n= is the row count: no WEB app rows registered + the
# seat's globals — no kernel-terminal section, WEB's window is not a tty
# front-end. The `hints row` lines are the serial copy of the plate.
vgate_file script-hints.txt <<'EOFX'
exec WEB.ELF /host/PAGE.HTML
EOFX

vgate_run 49 -- \
    --screen '$RUN_DIR/screen-49' \
    --via-virtio \
    --script '$RUN_DIR/script-hints.txt' \
    --input-chords '?,escape,q' \
    --input-chords-after 'web: ready' \
    --script-expect 'web: quit' --timeout 240

vgate_assert 49 serial-contains 'web: ready'
vgate_assert 49 serial-contains 'web: hints n=40'
vgate_assert 49 serial-contains 'web: hints row ctrl+shift+p summon the command palette'
vgate_assert 49 serial-absent 'web: hints row ctrl+shift+c '
vgate_assert 49 serial-contains 'web: hints close'
vgate_assert 49 serial-contains 'web: quit'
vgate_assert 49 serial-absent '[EXC] parking:'

# --- boots 50-53 (M135b #2764): HTTP/1.1 wire honesty ---------------------
# The :packet responder streams canned responses, paced one segment per
# guest ACK: a chunked page, a gzip page, a corrupt gzip body (refused by
# name), and a keep-alive pair (page + linked stylesheet, one connection).
vgate_setup_python <<'PY'
import gzip, os
rd = os.environ["RUN_DIR"]
body = b"Hello from VirelaiOS Host!\n"

def chunked(data, n=7):
    out = b""
    while data:
        out += ("%x\r\n" % min(n, len(data))).encode() + data[:n] + b"\r\n"
        data = data[n:]
    return out + b"0\r\nX-Trailer: skipped\r\n\r\n"

open(os.path.join(rd, "page-chunked.bin"), "wb").write(
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunked(body))
gz = gzip.compress(body, mtime=0)
open(os.path.join(rd, "page-gzip.bin"), "wb").write(
    b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " +
    str(len(gz)).encode() + b"\r\n\r\n" + gz)
bad = bytearray(gz); bad[len(bad) - 5] ^= 0xff  # corrupt the CRC32 field
open(os.path.join(rd, "page-gzip-bad.bin"), "wb").write(
    b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " +
    str(len(bad)).encode() + b"\r\n\r\n" + bytes(bad))
page = (b'<html><head><link rel="stylesheet" href="/ka.css"></head>'
        b'<body><h1>keep-alive</h1><p>two requests, one connection</p></body></html>')
css = b"body { background-color: #7fdbff; }"
open(os.path.join(rd, "page-keepalive.bin"), "wb").write(
    b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(page)).encode() + b"\r\n\r\n" + page +
    b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(css)).encode() + b"\r\n\r\n" + css)
print("M135b: staged chunked/gzip/corrupt-gzip/keep-alive payloads")
PY

# --- boot 50: a chunked page decodes and renders --------------------------
vgate_run 50 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-50' \
    --net '$RUN_DIR/cap50.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond '10.0.0.2:80:packet' --net-tcp-respond-payload '$RUN_DIR/page-chunked.bin' \
    --script '$RUN_DIR/script-fetch.txt' \
    --snapshot-after "web: settled" --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 50 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 50 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 50 serial-contains 'web: parse nodes='
vgate_assert 50 serial-contains 'web: settled'
vgate_assert 50 serial-contains 'web: repaint items='
vgate_assert 50 serial-contains 'web: ready'
vgate_assert 50 serial-absent 'web: error'
vgate_assert 50 serial-absent '[EXC] parking:'
vgate_assert 50 snapshot 'snap-50-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'fetch'])
PY

# --- boot 51: a gzip page inflates and renders ----------------------------
vgate_run 51 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-51' \
    --net '$RUN_DIR/cap51.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond '10.0.0.2:80:packet' --net-tcp-respond-payload '$RUN_DIR/page-gzip.bin' \
    --script '$RUN_DIR/script-fetch.txt' \
    --snapshot-after "web: settled" --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 51 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 51 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 51 serial-contains 'web: parse nodes='
vgate_assert 51 serial-contains 'web: settled'
vgate_assert 51 serial-contains 'web: repaint items='
vgate_assert 51 serial-contains 'web: ready'
vgate_assert 51 serial-absent 'web: error'
vgate_assert 51 serial-absent '[EXC] parking:'
vgate_assert 51 snapshot 'snap-51-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'fetch'])
PY

# --- boot 52: a corrupt gzip body refuses by name --------------------------
vgate_run 52 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-52' \
    --net '$RUN_DIR/cap52.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond '10.0.0.2:80:packet' --net-tcp-respond-payload '$RUN_DIR/page-gzip-bad.bin' \
    --script '$RUN_DIR/script-fetch.txt' \
    --script-expect "web: ready" --timeout 120

vgate_assert 52 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 52 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 52 serial-contains 'web: error gzip-crc'
vgate_assert 52 serial-contains 'web: ready'
vgate_assert 52 serial-absent '[EXC] parking:'

# --- boot 53: keep-alive — page + linked CSS, exactly one connection ------
vgate_run 53 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-53' \
    --net '$RUN_DIR/cap53.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond '10.0.0.2:80:packet' --net-tcp-respond-payload '$RUN_DIR/page-keepalive.bin' \
    --script '$RUN_DIR/script-fetch.txt' \
    --script-expect "web: ready" --timeout 120

vgate_assert 53 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 53 serial-contains 'web: fetch 10.0.0.2/ka.css'
vgate_assert 53 serial-contains 'web: settled'
vgate_assert 53 serial-contains 'web: ready'
vgate_assert 53 serial-absent 'web: error'
vgate_assert 53 serial-absent '[EXC] parking:'
vgate_assert 53 python <<'PY'
import os, sys
run = open(os.path.join(os.environ["RUN_DIR"], "run-53.out"), errors="replace").read()
n = run.count("answered the guest's SYN")
if n != 1:
    sys.exit("FAIL: keep-alive leg accepted %d connections, want 1" % n)
print("live-web 53: 1 accepted connection served page + stylesheet")
PY
vgate_assert 53 snapshot 'snap-53-*.raw' <<'PY'
import sys
# The linked stylesheet paints the page background #7fdbff: the CSS fetch
# really arrived and applied, on the same connection as the page.
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
hits = sum(1 for yy in range(120, 300, 20) for xx in range(60, 540, 20)
           if px(xx, yy) == (0x7f, 0xdb, 0xff))
if hits < 60:
    sys.exit("FAIL: stylesheet background absent (hits=%d)" % hits)
print("live-web 53: linked CSS applied (%d samples)" % hits)
PY

# --- boots 54-56 (M135d #2766): the net acceptance journey, K=3 ---------
# One boot per iteration — three independent VMs running the same journey:
#
#   1. GOHTTPD --tls /host/TLS.CRT /host/TLS.SEED 8443 answers a host TLS
#      1.3 client driven over the runner's byte relay (the live-httpd run
#      05 shape): handshake completes, the peer DER equals the staged
#      fixture, and the index page body comes back.
#   2. WEB fetches a GZIP page plus its two linked stylesheets off a real
#      keep-alive responder behind :relay — three requests down ONE
#      connection (the responder's receipt log counts one accept, three
#      requests; the runner prints 'answered the guest's SYN' once), both
#      stylesheets reaching the scanout.
#   3. Three more host SYNs land on the PLAIN listener (8080) at the same
#      marker; child_limit=2 admits two children and the third draws the
#      named refusal 'net: listen-saturated port=8080 bound=2' + RST —
#      the M135c (#2765) surface, run E's shape.
#
# The leg-2 responder is a real request-driven HTTP/1.1 server, not the
# :packet blob: packet mode streams its payload once per connection and
# never answers a second request on it, which cannot prove keep-alive.
#
# Two listeners keep the journey deterministic: --net-tcp-connect-after is
# one marker for every declared client, so the saturation trio shares its
# dispatch with the TLS client — aimed at 8443 the TLS SYN could lose the
# bound race and flake leg 1; separate ports cannot starve each other.
#
# The TLS listener execs FIRST for a subtler reason: the kernel's slot-0
# listener is the ipv4 fast path's `sockets.listener`, and that path feeds
# `sockets.receive` directly — past `claimTcpFrame`'s `noteSaturated`, so a
# saturated slot-0 port counts lsat but never prints the named marker
# (observed 2026-10-20: 'lbound=2 lsat=1' rows with no 'net:
# listen-saturated' line). The plain 8080 listener sits in
# extra_listeners, where every saturating SYN is named.
# script2 forwards only once 'httpd: listening on port 8443' prints, so
# both legs' targets exist before any client can fire; the runs end on
# script3's echo gated on 'web: ready', which postdates every handshake
# and refusal marker by seconds. GOHTTPD.ELF, TLS.CRT and TLS.SEED are
# staged by the setup hook below (the same env-gated fixture generator
# live-httpd uses).

vgate_file m135d-a.txt <<'EOF'
settings set font_size medium
net ip 10.0.0.1
net arp 10.0.0.2
exec GOHTTPD.ELF --tls /host/TLS.CRT /host/TLS.SEED 8443
EOF

vgate_file m135d-b.txt <<'EOF'
exec GOHTTPD.ELF
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file m135d-c.txt <<'EOF'
echo m135d-accept-done
EOF

# Saturation trio payloads: one GET each, explicit close.
vgate_file m135d-req-a.txt <<'EOF'
GET / HTTP/1.1
Connection: close

EOF

vgate_file m135d-req-b.txt <<'EOF'
GET /B HTTP/1.1
Connection: close

EOF

vgate_file m135d-req-c.txt <<'EOF'
GET /C HTTP/1.1
Connection: close

EOF

# The TLS-over-stdio client, verbatim from live-httpd: ssl.MemoryBIO drives
# TLS 1.3 over the runner's byte relay; stderr is the evidence channel
# (into the run log). argv: CERT_DER_PATH [tls12]
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

# Leg 2's responder: a minimal keep-alive HTTP/1.1 server the runner
# reaches through :relay. It never parses beyond the request line and
# never closes on its own; every accept and request appends a receipt
# line the gate counts afterward (one accept, three requests = the whole
# page load rode one connection).
vgate_file m135d_httpd.py <<'EOF'
#!/usr/bin/env python3
import gzip, os, socket, sys, threading

out_path, port = sys.argv[1], int(sys.argv[2])
out = open(out_path, "a", buffering=1)

page = (b'<html><head><link rel="stylesheet" href="/ka-a.css">'
        b'<link rel="stylesheet" href="/ka-b.css"></head>'
        b'<body><h1>gzip keep-alive journey</h1>'
        b'<p>three fetches, one connection</p></body></html>')
routes = {
    "/": (b"Content-Encoding: gzip\r\n", gzip.compress(page, mtime=0)),
    "/ka-a.css": (b"", b"body { background-color: #7fdbff; }"),
    "/ka-b.css": (b"", b"h1 { background-color: #b58900; }"),
}

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(4)
out.write("m135d-httpd ready\n")

next_id = [0]
def serve(c, cid):
    buf = b""
    while True:
        try:
            data = c.recv(65536)
        except OSError:
            return
        if not data:
            return
        buf += data
        while b"\r\n\r\n" in buf:
            head, buf = buf.split(b"\r\n\r\n", 1)
            reqline = head.split(b"\r\n", 1)[0].decode("latin1")
            path = reqline.split(" ")[1] if " " in reqline else "/"
            extra, body = routes.get(path, (b"", b"not found"))
            status = b"200 OK" if path in routes else b"404 Not Found"
            c.sendall(b"HTTP/1.1 " + status + b"\r\n" + extra +
                      b"Content-Length: " + str(len(body)).encode() +
                      b"\r\n\r\n" + body)
            out.write("conn=%d req=%s\n" % (cid, reqline))
            if b"connection: close" in head.lower():
                return

while True:
    try:
        c, _ = srv.accept()
    except OSError:
        break
    cid = next_id[0]; next_id[0] += 1
    out.write("accept conn=%d\n" % cid)
    threading.Thread(target=serve, args=(c, cid), daemon=True).start()
EOF

vgate_setup_python <<'PY'
# Boots 54-56 (M135d #2766): GOHTTPD.ELF plus the --tls credential pair the
# legs serve, and leg 2's keep-alive responder bound to loopback (the
# runner relays 10.0.0.2:80 to it). The credential comes from the same
# env-gated host generator live-httpd runs; hooks execute with the repo
# root as cwd (every hook's relative paths already assume it).
import os, shutil, subprocess, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOHTTPD.ELF")
if not os.path.exists(src):
    sys.exit("GOHTTPD.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gohttpd.sh")
shutil.copy(src, os.path.join(share, "GOHTTPD.ELF"))
print("live-web 54-56: staged GOHTTPD.ELF (%d bytes)" % os.path.getsize(src))

env = dict(os.environ)
env["HTTPD_TLS_GEN_FIXTURE"] = "1"
env["HTTPD_TLS_FIXTURE_DIR"] = share
r = subprocess.run(["go", "-C", "user/go", "test", "-run", "TestGenTLSFixture",
                    "-v", "./httpd/"], cwd=os.getcwd(), env=env,
                   capture_output=True, text=True)
sys.stderr.write(r.stdout[-800:] + r.stderr[-800:])
if r.returncode != 0:
    sys.exit("live-web 54-56: TLS fixture generator failed")
for name in ("TLS.CRT", "TLS.SEED"):
    if not os.path.exists(os.path.join(share, name)):
        sys.exit("live-web 54-56: fixture missing " + name)
# The stream client verifies the peer DER against the same fixture; the
# share path varies ($VG_SHARE), so it reads a RUN_DIR copy.
shutil.copy(os.path.join(share, "TLS.CRT"), os.path.join(rd, "TLS.CRT"))
os.chmod(os.path.join(rd, "tlscli.py"), 0o755)
os.chmod(os.path.join(rd, "m135d_httpd.py"), 0o755)
print("live-web 54-56: generated TLS.CRT + TLS.SEED; tlscli.py armed")

receipt = os.path.join(rd, "m135d-httpd.log")
watch = os.path.join("user", "go", "browser", "peer_watch.py")
httpd = os.path.join(rd, "m135d_httpd.py")
proc = subprocess.Popen([sys.executable, watch, str(os.getppid()),
                         sys.executable, httpd, receipt, "24601"],
                        stdout=open(os.path.join(rd, "m135d-httpd.err"), "wb"),
                        stderr=subprocess.STDOUT, start_new_session=True)
print("live-web 54-56: keep-alive responder pid=%d on 127.0.0.1:24601" % proc.pid)
PY

vgate_run 54 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-54' \
    --net '$RUN_DIR/cap54.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond '10.0.0.2:80:relay' --net-tcp-respond-relay 127.0.0.1:24601 \
    --net-tcp-connect '10.0.0.1:8443' \
    --net-tcp-connect-stream '$RUN_DIR/tlscli.py' \
    --net-tcp-connect-stream-arg '$RUN_DIR/TLS.CRT' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-a.txt' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-b.txt' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-c.txt' \
    --net-tcp-connect-after 'httpd: listening on port 8080' \
    --script '$RUN_DIR/m135d-a.txt' \
    --script2 '$RUN_DIR/m135d-b.txt' --script2-after 'httpd: listening on port 8443' \
    --script3 '$RUN_DIR/m135d-c.txt' --script3-after 'web: ready' --script3-delay 3 \
    --snapshot-after 'web: repaint' \
    --script-expect 'm135d-accept-done' --timeout 180

vgate_assert 54 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 54 serial-contains 'settings: font_size=medium'
vgate_assert 54 serial-contains 'httpd: listening on port 8443'
vgate_assert 54 serial-contains 'httpd: listening on port 8080'
vgate_assert 54 serial-contains 'net: listen-saturated port=8080 bound=2'
vgate_assert 54 serial-contains 'lbound=2 lsat=1'
vgate_assert 54 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 54 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 54 serial-contains 'web: fetch 10.0.0.2/ka-a.css'
vgate_assert 54 serial-contains 'web: fetch 10.0.0.2/ka-b.css'
vgate_assert 54 serial-contains 'web: settled'
vgate_assert 54 serial-contains 'web: ready'
vgate_assert 54 serial-contains 'm135d-accept-done'
vgate_assert 54 serial-absent 'web: error'
vgate_assert 54 serial-absent 'web: offline '
vgate_assert 54 serial-absent 'web: read-timeout'
vgate_assert 54 serial-absent 'web: diagnostic '
vgate_assert 54 serial-absent 'httpd: tls alert'
vgate_assert 54 serial-absent 'httpd: tls error'
vgate_assert 54 serial-absent 'httpd: error'
vgate_assert 54 serial-absent '[EXC] parking:'
vgate_assert 54 output-contains 'NET-TCP-CONNECT: the guest refused the connection (RST)'
vgate_assert 54 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
out = open(os.path.join(os.environ["RUN_DIR"], "run-54.out"), errors="replace").read()
# Leg 1: the host TLS 1.3 client completed the handshake against the
# guest's own stack, matched the peer DER to the staged fixture, and read
# the index page body back over the record layer.
for m in ("TLSCLI: handshake ok", "fixture match=True"):
    if m not in out:
        sys.exit("FAIL: TLS leg missing %r" % m)
if "VirelaiOS" not in out:
    sys.exit("FAIL: TLS leg body missing the index page")
# Leg 3: exactly one refused SYN against the plain listener — the named
# saturation. Three sessions ran in total: the TLS one plus the two the
# bound admitted; the third trio member never became a session.
n = out.count("the guest refused the connection (RST)")
if n != 1:
    sys.exit("FAIL: refusals %d, want exactly 1" % n)
for marker, want in (("httpd: accepted", 3), ("httpd: served", 3),
                     ("httpd: closed", 3)):
    got = ser.count(marker)
    if got != want:
        sys.exit("FAIL: %r appeared %d times, want %d" % (marker, got, want))
# Leg 2: one TCP connection carried the gzip page and both stylesheets —
# counted twice: once at the runner's SYN-ACK and once in the responder's
# own receipt (one accept, three request lines, in order).
n = out.count("answered the guest's SYN")
if n != 1:
    sys.exit("FAIL: responder accepted %d connections, want 1" % n)
receipt = [l for l in open(os.path.join(os.environ["RUN_DIR"],
           "m135d-httpd.log"), errors="replace").read().splitlines() if l]
# The responder is one process for the whole spec run — this leg's traffic
# is the LAST three request lines, and they must all ride one connection
# (a mid-leg retry would split them across conn ids).
reqs = [l for l in receipt if " req=" in l][-3:]
want = ["GET / HTTP/1.1", "GET /ka-a.css HTTP/1.1", "GET /ka-b.css HTTP/1.1"]
if [r.split("req=", 1)[1] for r in reqs] != want:
    sys.exit("FAIL: leg receipt %r, want %r" % (reqs, want))
conns = {r.split(" ", 1)[0] for r in reqs}
if len(conns) != 1:
    sys.exit("FAIL: leg rode %d connections, want 1" % len(conns))
print("live-web 54: TLS serve ok; 3 requests on 1 connection; 1 named saturation")
PY
vgate_assert 54 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "httpd: listening on port 8443",
    "httpd: listening on port 8080",
    "web: fetch 10.0.0.2/",
    "web: fetch 10.0.0.2/ka-a.css",
    "web: fetch 10.0.0.2/ka-b.css",
    "web: settled",
    "web: ready",
    "m135d-accept-done",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    if at < 0:
        sys.exit("FAIL: missing or out of order: " + marker)
    pos = at + 1
print("live-web 54: journey ordering ok (listeners -> fetch x3 -> ready -> done)")
PY
vgate_assert 54 snapshot 'snap-54-*.raw' <<'PY'
import sys
# Both stylesheets applied: css_a paints the page background #7fdbff,
# css_b paints the h1 band #b58900 — the second subresource really arrived
# and rendered, not just fetched.
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
bg = band = 0
for yy in range(92, 380):
    for xx in range(40, 552, 2):
        c = px(xx, yy)
        if c == (0x7f, 0xdb, 0xff):
            bg += 1
        elif c == (0xb5, 0x89, 0x00):
            band += 1
assert bg > 2000, "page background absent (bg=%d)" % bg
assert band > 30, "h1 band absent (band=%d)" % band
print("live-web 54: both stylesheets on the scanout (bg=%d band=%d)" % (bg, band))
PY

vgate_run 55 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-55' \
    --net '$RUN_DIR/cap55.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond '10.0.0.2:80:relay' --net-tcp-respond-relay 127.0.0.1:24601 \
    --net-tcp-connect '10.0.0.1:8443' \
    --net-tcp-connect-stream '$RUN_DIR/tlscli.py' \
    --net-tcp-connect-stream-arg '$RUN_DIR/TLS.CRT' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-a.txt' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-b.txt' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-c.txt' \
    --net-tcp-connect-after 'httpd: listening on port 8080' \
    --script '$RUN_DIR/m135d-a.txt' \
    --script2 '$RUN_DIR/m135d-b.txt' --script2-after 'httpd: listening on port 8443' \
    --script3 '$RUN_DIR/m135d-c.txt' --script3-after 'web: ready' --script3-delay 3 \
    --snapshot-after 'web: repaint' \
    --script-expect 'm135d-accept-done' --timeout 180

vgate_assert 55 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 55 serial-contains 'settings: font_size=medium'
vgate_assert 55 serial-contains 'httpd: listening on port 8443'
vgate_assert 55 serial-contains 'httpd: listening on port 8080'
vgate_assert 55 serial-contains 'net: listen-saturated port=8080 bound=2'
vgate_assert 55 serial-contains 'lbound=2 lsat=1'
vgate_assert 55 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 55 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 55 serial-contains 'web: fetch 10.0.0.2/ka-a.css'
vgate_assert 55 serial-contains 'web: fetch 10.0.0.2/ka-b.css'
vgate_assert 55 serial-contains 'web: settled'
vgate_assert 55 serial-contains 'web: ready'
vgate_assert 55 serial-contains 'm135d-accept-done'
vgate_assert 55 serial-absent 'web: error'
vgate_assert 55 serial-absent 'web: offline '
vgate_assert 55 serial-absent 'web: read-timeout'
vgate_assert 55 serial-absent 'web: diagnostic '
vgate_assert 55 serial-absent 'httpd: tls alert'
vgate_assert 55 serial-absent 'httpd: tls error'
vgate_assert 55 serial-absent 'httpd: error'
vgate_assert 55 serial-absent '[EXC] parking:'
vgate_assert 55 output-contains 'NET-TCP-CONNECT: the guest refused the connection (RST)'
vgate_assert 55 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
out = open(os.path.join(os.environ["RUN_DIR"], "run-55.out"), errors="replace").read()
# Leg 1: the host TLS 1.3 client completed the handshake against the
# guest's own stack, matched the peer DER to the staged fixture, and read
# the index page body back over the record layer.
for m in ("TLSCLI: handshake ok", "fixture match=True"):
    if m not in out:
        sys.exit("FAIL: TLS leg missing %r" % m)
if "VirelaiOS" not in out:
    sys.exit("FAIL: TLS leg body missing the index page")
# Leg 3: exactly one refused SYN against the plain listener — the named
# saturation. Three sessions ran in total: the TLS one plus the two the
# bound admitted; the third trio member never became a session.
n = out.count("the guest refused the connection (RST)")
if n != 1:
    sys.exit("FAIL: refusals %d, want exactly 1" % n)
for marker, want in (("httpd: accepted", 3), ("httpd: served", 3),
                     ("httpd: closed", 3)):
    got = ser.count(marker)
    if got != want:
        sys.exit("FAIL: %r appeared %d times, want %d" % (marker, got, want))
# Leg 2: one TCP connection carried the gzip page and both stylesheets —
# counted twice: once at the runner's SYN-ACK and once in the responder's
# own receipt (one accept, three request lines, in order).
n = out.count("answered the guest's SYN")
if n != 1:
    sys.exit("FAIL: responder accepted %d connections, want 1" % n)
receipt = [l for l in open(os.path.join(os.environ["RUN_DIR"],
           "m135d-httpd.log"), errors="replace").read().splitlines() if l]
# The responder is one process for the whole spec run — this leg's traffic
# is the LAST three request lines, and they must all ride one connection
# (a mid-leg retry would split them across conn ids).
reqs = [l for l in receipt if " req=" in l][-3:]
want = ["GET / HTTP/1.1", "GET /ka-a.css HTTP/1.1", "GET /ka-b.css HTTP/1.1"]
if [r.split("req=", 1)[1] for r in reqs] != want:
    sys.exit("FAIL: leg receipt %r, want %r" % (reqs, want))
conns = {r.split(" ", 1)[0] for r in reqs}
if len(conns) != 1:
    sys.exit("FAIL: leg rode %d connections, want 1" % len(conns))
print("live-web 55: TLS serve ok; 3 requests on 1 connection; 1 named saturation")
PY
vgate_assert 55 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "httpd: listening on port 8443",
    "httpd: listening on port 8080",
    "web: fetch 10.0.0.2/",
    "web: fetch 10.0.0.2/ka-a.css",
    "web: fetch 10.0.0.2/ka-b.css",
    "web: settled",
    "web: ready",
    "m135d-accept-done",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    if at < 0:
        sys.exit("FAIL: missing or out of order: " + marker)
    pos = at + 1
print("live-web 55: journey ordering ok (listeners -> fetch x3 -> ready -> done)")
PY
vgate_assert 55 snapshot 'snap-55-*.raw' <<'PY'
import sys
# Both stylesheets applied: css_a paints the page background #7fdbff,
# css_b paints the h1 band #b58900 — the second subresource really arrived
# and rendered, not just fetched.
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
bg = band = 0
for yy in range(92, 380):
    for xx in range(40, 552, 2):
        c = px(xx, yy)
        if c == (0x7f, 0xdb, 0xff):
            bg += 1
        elif c == (0xb5, 0x89, 0x00):
            band += 1
assert bg > 2000, "page background absent (bg=%d)" % bg
assert band > 30, "h1 band absent (band=%d)" % band
print("live-web 55: both stylesheets on the scanout (bg=%d band=%d)" % (bg, band))
PY

vgate_run 56 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-56' \
    --net '$RUN_DIR/cap56.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond '10.0.0.2:80:relay' --net-tcp-respond-relay 127.0.0.1:24601 \
    --net-tcp-connect '10.0.0.1:8443' \
    --net-tcp-connect-stream '$RUN_DIR/tlscli.py' \
    --net-tcp-connect-stream-arg '$RUN_DIR/TLS.CRT' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-a.txt' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-b.txt' \
    --net-tcp-connect '10.0.0.1:8080:$RUN_DIR/m135d-req-c.txt' \
    --net-tcp-connect-after 'httpd: listening on port 8080' \
    --script '$RUN_DIR/m135d-a.txt' \
    --script2 '$RUN_DIR/m135d-b.txt' --script2-after 'httpd: listening on port 8443' \
    --script3 '$RUN_DIR/m135d-c.txt' --script3-after 'web: ready' --script3-delay 3 \
    --snapshot-after 'web: repaint' \
    --script-expect 'm135d-accept-done' --timeout 180

vgate_assert 56 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 56 serial-contains 'settings: font_size=medium'
vgate_assert 56 serial-contains 'httpd: listening on port 8443'
vgate_assert 56 serial-contains 'httpd: listening on port 8080'
vgate_assert 56 serial-contains 'net: listen-saturated port=8080 bound=2'
vgate_assert 56 serial-contains 'lbound=2 lsat=1'
vgate_assert 56 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 56 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 56 serial-contains 'web: fetch 10.0.0.2/ka-a.css'
vgate_assert 56 serial-contains 'web: fetch 10.0.0.2/ka-b.css'
vgate_assert 56 serial-contains 'web: settled'
vgate_assert 56 serial-contains 'web: ready'
vgate_assert 56 serial-contains 'm135d-accept-done'
vgate_assert 56 serial-absent 'web: error'
vgate_assert 56 serial-absent 'web: offline '
vgate_assert 56 serial-absent 'web: read-timeout'
vgate_assert 56 serial-absent 'web: diagnostic '
vgate_assert 56 serial-absent 'httpd: tls alert'
vgate_assert 56 serial-absent 'httpd: tls error'
vgate_assert 56 serial-absent 'httpd: error'
vgate_assert 56 serial-absent '[EXC] parking:'
vgate_assert 56 output-contains 'NET-TCP-CONNECT: the guest refused the connection (RST)'
vgate_assert 56 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
out = open(os.path.join(os.environ["RUN_DIR"], "run-56.out"), errors="replace").read()
# Leg 1: the host TLS 1.3 client completed the handshake against the
# guest's own stack, matched the peer DER to the staged fixture, and read
# the index page body back over the record layer.
for m in ("TLSCLI: handshake ok", "fixture match=True"):
    if m not in out:
        sys.exit("FAIL: TLS leg missing %r" % m)
if "VirelaiOS" not in out:
    sys.exit("FAIL: TLS leg body missing the index page")
# Leg 3: exactly one refused SYN against the plain listener — the named
# saturation. Three sessions ran in total: the TLS one plus the two the
# bound admitted; the third trio member never became a session.
n = out.count("the guest refused the connection (RST)")
if n != 1:
    sys.exit("FAIL: refusals %d, want exactly 1" % n)
for marker, want in (("httpd: accepted", 3), ("httpd: served", 3),
                     ("httpd: closed", 3)):
    got = ser.count(marker)
    if got != want:
        sys.exit("FAIL: %r appeared %d times, want %d" % (marker, got, want))
# Leg 2: one TCP connection carried the gzip page and both stylesheets —
# counted twice: once at the runner's SYN-ACK and once in the responder's
# own receipt (one accept, three request lines, in order).
n = out.count("answered the guest's SYN")
if n != 1:
    sys.exit("FAIL: responder accepted %d connections, want 1" % n)
receipt = [l for l in open(os.path.join(os.environ["RUN_DIR"],
           "m135d-httpd.log"), errors="replace").read().splitlines() if l]
# The responder is one process for the whole spec run — this leg's traffic
# is the LAST three request lines, and they must all ride one connection
# (a mid-leg retry would split them across conn ids).
reqs = [l for l in receipt if " req=" in l][-3:]
want = ["GET / HTTP/1.1", "GET /ka-a.css HTTP/1.1", "GET /ka-b.css HTTP/1.1"]
if [r.split("req=", 1)[1] for r in reqs] != want:
    sys.exit("FAIL: leg receipt %r, want %r" % (reqs, want))
conns = {r.split(" ", 1)[0] for r in reqs}
if len(conns) != 1:
    sys.exit("FAIL: leg rode %d connections, want 1" % len(conns))
print("live-web 56: TLS serve ok; 3 requests on 1 connection; 1 named saturation")
PY
vgate_assert 56 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "httpd: listening on port 8443",
    "httpd: listening on port 8080",
    "web: fetch 10.0.0.2/",
    "web: fetch 10.0.0.2/ka-a.css",
    "web: fetch 10.0.0.2/ka-b.css",
    "web: settled",
    "web: ready",
    "m135d-accept-done",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    if at < 0:
        sys.exit("FAIL: missing or out of order: " + marker)
    pos = at + 1
print("live-web 56: journey ordering ok (listeners -> fetch x3 -> ready -> done)")
PY
vgate_assert 56 snapshot 'snap-56-*.raw' <<'PY'
import sys
# Both stylesheets applied: css_a paints the page background #7fdbff,
# css_b paints the h1 band #b58900 — the second subresource really arrived
# and rendered, not just fetched.
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
bg = band = 0
for yy in range(92, 380):
    for xx in range(40, 552, 2):
        c = px(xx, yy)
        if c == (0x7f, 0xdb, 0xff):
            bg += 1
        elif c == (0xb5, 0x89, 0x00):
            band += 1
assert bg > 2000, "page background absent (bg=%d)" % bg
assert band > 30, "h1 band absent (band=%d)" % band
print("live-web 56: both stylesheets on the scanout (bg=%d band=%d)" % (bg, band))
PY
# --- boot 57 (M153e #2925): save-as .pdf — the raster leg -------------------
# The M124b picker again, but the picked name ends .pdf: the laid-out
# document is repainted full-height off-screen, center-sampled 1280->1024,
# sliced to Letter pages and written through pdfwrite. '?' and Esc ride the
# same chord burst after Return so the 'web: hints close' receipt postdates
# the restored frame; a 3 s script2 echo ('web-pdf-shot') then anchors the
# scanout snapshot — the kind-4 capture copies the CURRENT scanout, so it
# needs a marker behind the composite, like run 46's plate capture.
# Host-side, a python leg parses the file and cross-checks the
# marker's page/byte counts against it; a second renders page 1 through
# CoreGraphics (cgrender, the ADR 0040 outside reference) and compares it
# with the scanout's page crop inside the pinned tolerance.
vgate_file script-pdf-shot.txt <<'EOF'
echo web-pdf-shot
EOF

vgate_run 57 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-57' \
    --script '$RUN_DIR/script-local.txt' \
    --input-chords 'ctrl-shift-s,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,W,E,B,S,A,V,E,.,P,D,F,return,?,escape' --input-chords-after 'web: ready' \
    --script2 '$RUN_DIR/script-pdf-shot.txt' --script2-after 'web: hints close' --script2-delay 3 \
    --snapshot-after 'web-pdf-shot' \
    --script-expect 'web-pdf-shot' --timeout 240

vgate_assert 57 serial-absent 'web: budget over'
vgate_assert 57 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 57 serial-contains 'web: saveas pdf /host/WEBSAVE.PDF pages='
vgate_assert 57 serial-contains 'web: save /host/WEBSAVE.PDF'
vgate_assert 57 serial-contains 'web: hints close'
vgate_assert 57 serial-absent 'web: saveas pdf refused'
vgate_assert 57 serial-absent 'web: save cancel'
vgate_assert 57 serial-absent 'web: download failed'
vgate_assert 57 serial-absent 'web: error'
vgate_assert 57 serial-absent '[EXC] parking:'
vgate_assert 57 python <<'PY'
import os, re
share = os.environ["VG_SHARE"]
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"web: saveas pdf /host/WEBSAVE\.PDF pages=(\d+) bytes=(\d+)", ser)
assert m, "missing saveas marker"
pages, nbytes = int(m.group(1)), int(m.group(2))
data = open(os.path.join(share, "WEBSAVE.PDF"), "rb").read()
assert data[:9] == b"%PDF-1.4\n", "bad header %r" % data[:64]
assert len(data) == nbytes, "size %d != marker %d" % (len(data), nbytes)
assert len(data) <= 4*1024*1024, "over the 4 MiB bound"
assert b"/Count " + str(pages).encode() in data, "page count drifted"
assert b"/DeviceRGB" in data and b"/FlateDecode" in data, "no raster page stream"
assert b"/Producer (virelai web)" in data, "Info producer missing"
# Classic xref: every recorded offset must point at its own 'N 0 obj'.
xref = data.find(b"\nxref\n0 ") + 8
count = int(data[xref:data.find(b"\n", xref)])
rows = data.split(b" 00000 n \n")
assert len(rows) >= count, "short xref table"
off = xref + len(str(count)) + 1 + 20  # skip the free entry row
for i in range(1, count):
    o = int(data[off:off+10]); off += 20
    assert data[o:o+len(str(i))+6] == (str(i) + " 0 obj").encode(), "xref %d offset %d" % (i, o)
# The downloads ledger records the save like every other leg.
rows = [l for l in open(os.path.join(share, "WEB-DOWNLOADS.TXT"),
        errors="replace").read().splitlines() if l and not l.startswith("#")]
assert any("WEBSAVE.PDF" in r for r in rows), "no ledger row"
print("live-web 57: WEBSAVE.PDF structure ok (pages=%d bytes=%d, xref offsets, ledger row)"
      % (pages, nbytes))
PY
vgate_assert 57 snapshot 'snap-57-0.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280*720*4, "scanout size %d" % len(data)
def px(x, y):
    k = (y*1280+x)*4
    return (data[k+2], data[k+1], data[k])
# The page crop inside the 3 px compositor frame: dark page background
# dominant with real text ink — the restored frame, not the picker plate.
bg = ink = 0
for yy in range(95, 377):
    for xx in range(43, 549):
        c = px(xx, yy)
        if c == (0x18, 0x20, 0x26):
            bg += 1
        elif min(c) > 180:
            ink += 1
assert bg > 20000, "page background absent (bg=%d)" % bg
assert ink > 100, "no text ink on the page (ink=%d)" % ink
print("live-web 57: restored page on the scanout (bg=%d ink=%d)" % (bg, ink))
PY
vgate_assert 57 python <<'PY'
import os, struct, subprocess
share = os.environ["VG_SHARE"]
rd = os.environ["RUN_DIR"]
# The outside reference: CoreGraphics at 96 dpi, same contract the
# pdf-proof oracle pins (built once into ignored .build/).
binary = ".build/pdf-proof/cgrender"
if not os.path.exists(binary):
    os.makedirs(".build/pdf-proof", exist_ok=True)
    subprocess.check_call(["/usr/bin/swiftc", "-O", "-module-cache-path",
        ".build/pdf-proof/module-cache", "tools/pdf-proof/cgrender.swift",
        "-o", binary])
out = os.path.join(rd, "websave-p1.bgra")
env = {k: v for k, v in os.environ.items() if not k.startswith("DYLD_")}
env["CG_PDF_VERBOSE"] = "1"
r = subprocess.run([os.path.abspath(binary), os.path.join(share, "WEBSAVE.PDF"),
                    out, "1"], env=env, capture_output=True, text=True, timeout=60)
assert r.returncode == 0, "cgrender failed: " + r.stderr[:400]
open(os.path.join(rd, "websave-p1.cglog"), "w").write(r.stderr)
assert "caught exception" not in r.stderr, "oracle diagnostics: " + r.stderr[:400]
cg = open(out, "rb").read()
w, h, stride = struct.unpack_from("<III", cg, 4)
assert (w, h, stride) == (816, 1056, 816), "cgrender geometry %dx%d" % (w, h)
pix = cg[16:]
raw = open(os.path.join(rd, "snap-57-0.raw"), "rb").read()
assert len(raw) == 1280*720*4, "scanout size %d" % len(raw)
def scan(x, y):
    k = (y*1280+x)*4
    return (raw[k+2], raw[k+1], raw[k])
def ref(x, y):
    k = (y*816+x)*4
    return (pix[k+2], pix[k+1], pix[k])
# The page crop (inside the 3 px compositor frame) shows source rows
# [0,720); the PDF's first page shows source rows [0,1655) — the same
# layout scaled by the rungs' center-sample rules. The region maps at
# ~0.8 scanout px per cgrender px both ways; edge AA shifts a pixel, so
# the bound is a per-channel tolerance plus a mismatch fraction, not
# equality.
mism = total = 0
sumdiff = 0
TOL = 48
for cy in range(3, 285):
    gy = int((2*cy+1) * 0.7975837)
    for cx in range(3, 509):
        gx = int((2*cx+1) * 0.796875)
        a = scan(40+cx, 92+cy)
        b = ref(gx, gy)
        d = max(abs(a[0]-b[0]), abs(a[1]-b[1]), abs(a[2]-b[2]))
        sumdiff += abs(a[0]-b[0]) + abs(a[1]-b[1]) + abs(a[2]-b[2])
        total += 1
        if d > TOL:
            mism += 1
frac = mism/total
mean = sumdiff/(3*total)
assert frac <= 0.08 and mean <= 24, "cgrender vs scanout: mism=%.4f mean=%.2f" % (frac, mean)
print("live-web 57: cgrender page 1 vs scanout crop (mismatch %.4f%%, mean %.2f/255, tol %d)"
      % (frac*100, mean, TOL))
PY

# --- boot 58 (#2940): the enforce leg — WEB's writes land under enforce -----
# A run-scoped share (`--cvc-file`, the go-agentd posture-leg pattern: a
# later --cvc-file in a run's own flags overrides the armed share for that
# boot only) carries a GRANTS.TXT of `#v1 mode=enforce` and NO user rows,
# so the compiled base rows decide — under #2939's table WEB.ELF's row
# carries `file`, so the picker's save-as lands WEBSAVE.HTML and the
# bare-'s' download lands WEB-DL-PAGE.HTML (plus the ledger row). A row
# that still lacked `file` would fail BY NAME — `refused:file_denied
# name=WEB.ELF word=file` and `web: download failed file` — never quietly;
# the asserts pin that refusal's absence AND the audit receipt's absence
# (the enforce posture), while the python hook proves the share's
# GRANTS.TXT really carried mode=enforce and both payloads are byte-exact.
#
# Run 45's picker choreography verbatim — ctrl-shift-s, nine backspaces
# clearing the seeded PAGE.HTML name, the fresh name, Return — then one
# `--input-key 1` (macOS kVK_S) fires the bare-s save only AFTER the
# save-as marker, so the 's' can never land inside the picker's name
# field. Run ends on the download's done marker.

vgate_setup_python <<'PY'
# Declared LAST of this spec's setup hooks so the copy sees the armed
# share's final state (PAGE.HTML, DLPAGE.HTML, fonts, the mime-open
# ELFs included), then layers the enforce posture on top.
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
enf = os.path.join(os.environ["RUN_DIR"], "enf-share")
if os.path.exists(enf):
    shutil.rmtree(enf)
shutil.copytree(share, enf)
open(os.path.join(enf, "GRANTS.TXT"), "w").write("#v1 mode=enforce\n")
print("enf-share: %d files, GRANTS.TXT mode=enforce" % len(os.listdir(enf)))
PY

vgate_run 58 -- \
    --screen '$RUN_DIR/screen' --via-virtio \
    --cvc-file '$RUN_DIR/enf-share' \
    --script '$RUN_DIR/script-local.txt' \
    --input-chords 'ctrl-shift-s,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,W,E,B,S,A,V,E,.,H,T,M,L,return' --input-chords-after 'web: ready' \
    --input-key 1 --input-key-after 'web: save /host/WEBSAVE.HTML' \
    --script-expect 'web: download done PAGE.HTML' --timeout 240

vgate_assert 58 serial-absent 'web: budget over'
vgate_assert 58 serial-contains 'web: url /host/PAGE.HTML'
# The save-as leg: the picker returned /host/WEBSAVE.HTML, the staged
# write committed it and the ledger path marked it — under a missing
# `file` word the FileOpen is refused EACCES and `web: save` never
# prints.
vgate_assert 58 serial-contains 'web: download /host/WEBSAVE.HTML '
vgate_assert 58 serial-contains 'web: save /host/WEBSAVE.HTML'
# The bare-s download leg: the same staged-write path under the fixed
# WEB-DL- name.
vgate_assert 58 serial-contains 'web: download start PAGE.HTML bytes='
vgate_assert 58 serial-contains 'web: download /host/WEB-DL-PAGE.HTML '
vgate_assert 58 serial-contains 'web: download done PAGE.HTML'
# The enforce posture's named failures, absent by name.
vgate_assert 58 serial-absent 'refused:file_denied name=WEB.ELF'
vgate_assert 58 serial-absent 'refused:'
vgate_assert 58 serial-absent 'verdict=audit:'
vgate_assert 58 serial-absent 'web: save cancel'
vgate_assert 58 serial-absent 'web: download failed'
vgate_assert 58 serial-absent 'web: error'
vgate_assert 58 serial-absent '[EXC] parking:'
vgate_assert 58 serial-absent 'exited status=139'

# The share evidence (this run's share is enf-share, not the armed one —
# share-* asserts read the armed share, so the check is python): the
# GRANTS.TXT the boot read really was `#v1 mode=enforce` with no user
# rows; WEBSAVE.HTML is byte-exact PAGE.HTML (the run-45 compare);
# WEB-DL-PAGE.HTML holds the same body; the downloads ledger rows both.
vgate_assert 58 python <<'PY'
import os, sys
sh = os.path.join(os.environ["RUN_DIR"], "enf-share")
g = open(os.path.join(sh, "GRANTS.TXT")).read()
if g != "#v1 mode=enforce\n":
    sys.exit("enforce share GRANTS.TXT is %r — not the bare enforce header"
             % g)
want = open(os.path.join(sh, "PAGE.HTML"), "rb").read()
for name in ("WEBSAVE.HTML", "WEB-DL-PAGE.HTML"):
    p = os.path.join(sh, name)
    if not os.path.exists(p):
        sys.exit("%s missing on the enforce share" % name)
    got = open(p, "rb").read()
    if got != want:
        sys.exit("%s is %d bytes, want the PAGE.HTML body (%d)"
                 % (name, len(got), len(want)))
rows = [l for l in open(os.path.join(sh, "WEB-DOWNLOADS.TXT"),
        errors="replace").read().splitlines() if l and not l.startswith("#")]
for name in ("WEBSAVE.HTML", "WEB-DL-PAGE.HTML"):
    if not any(name in r for r in rows):
        sys.exit("no ledger row for %s" % name)
print("enforce leg: GRANTS.TXT mode=enforce; WEBSAVE.HTML + "
      "WEB-DL-PAGE.HTML byte-exact (%d bytes), ledger rows present"
      % len(want))
PY

# --- M190d (#3239): the menubar — F10 engages the bar on the title row,
# right right right lands on Tools, down opens it, and the Chord hints row
# fires the identical '?' overlay path (registry receipts included). The
# start surface needs no page.
vgate_file script-menu.txt <<'EOFS'
tabwm
tabwm start
EOFS

vgate_file script2-menu.txt <<'EOFS'
exec WEB.ELF
EOFS

vgate_file script3-menu.txt <<'EOFS'
dui close 2
echo rx-web-menu-ok
EOFS

vgate_run 61 -- \
    --screen '$RUN_DIR/screen-menu' \
    --via-virtio \
    --script '$RUN_DIR/script-menu.txt' \
    --script2 '$RUN_DIR/script2-menu.txt' --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'f10,right,right,right,down,down,down,down,return,escape' \
    --input-chords-after 'web: ready' \
    --script3 '$RUN_DIR/script3-menu.txt' --script3-after 'web: hints n=40' \
    --script-expect 'rx-web-menu-ok' --timeout 240

vgate_assert 61 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 61 serial-contains 'web: menu open'
vgate_assert 61 serial-contains 'web: menu Chord hints'
vgate_assert 61 serial-contains 'web: hints n=40'
vgate_assert 61 serial-contains 'rx-web-menu-ok'
vgate_assert 61 serial-absent '[EXC] parking:'
vgate_assert 61 serial-absent 'exited status=139'
