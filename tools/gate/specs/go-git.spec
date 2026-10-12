# go-git.spec -- issue #1337 / M67b #1447 (clone) + #2203 (fetch/pull):
# GOTGIT.ELF clones a tiny fixture repo over HTTPS in-process (tls.Dial over
# vi.Dial, ADR 0029), then fetches and pulls against the same remote after
# it advances.
#
# Smart HTTP against a real `git http-backend` on the host, TLS 1.3 only.
# Never a cleartext GET. FETCHS.BIN is not exec'd. Kernel untouched.
# The fixture remote starts at commit one (HELLO + SECOND, a delta pair so
# `git repack` emits a depth-1 delta and class-B runs the delta path); a
# post-run python hook pushes commit two (HELLO punched, NEWS added), so
# the runs exercise: clone -> fetch (refs move, worktree does NOT) ->
# dirty pull (refuses, clobbers nothing) -> clean pull (files + branch ref
# advance) -> no-op fetch (one GET, no POST). Guest-facing TCP 24541 is the
# runner --net-tcp-respond pin (the TLS fixture family live-web boot 12 now
# owns, M71k #1570); a leftover listener is killed in setup AND in the last
# run's hook (collides with a concurrent go-git; per-run bind(:0) needs
# vgate_run to expand a generated host port).
#
# HOST PREREQUISITE: bash tools/go/build-git.sh --gate -> .build/go/
# GOTGIT-GATE.ELF plus `git` on PATH.
#
# exec-order: assert-proven -- every run ends on a marker only GOTGIT
# prints (`gotgit OK` or the dirty refusal); a program that never ran
# fails its run.

vgate_name go-git "issue #1337/#1447 clone + #2203 fetch/pull over in-process TLS from git http-backend"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-clone.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTGIT.ELF clone https://10.0.0.2:24541/g.git /host/G
EOF

vgate_file script-fetch.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTGIT.ELF fetch https://10.0.0.2:24541/g.git /host/G
EOF

vgate_file script-pull.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTGIT.ELF pull https://10.0.0.2:24541/g.git /host/G
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)
# Leftover-listener hygiene on the 24541 pin (see header); the last run's
# python hook kills this run's listener on the way out.
subprocess.run(["sh", "-c", "lsof -ti tcp:24541 | xargs kill -9"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.2)

gogit = os.path.join(".build", "go", "GOTGIT-GATE.ELF")
if not os.path.exists(gogit):
    sys.exit("GOTGIT.ELF missing (expected " + gogit + ") - build it first: "
             "bash tools/go/build-git.sh --gate")
shutil.copy(gogit, os.path.join(share, "GOTGIT.ELF"))

git = shutil.which("git")
if not git:
    sys.exit("git not on PATH; go-git needs a real git http-backend")

root = os.path.join(run, "gitroot")
work = os.path.join(run, "work")
os.makedirs(root, exist_ok=True)
os.makedirs(work, exist_ok=True)
env = os.environ.copy()
env.update({
    "GIT_AUTHOR_NAME": "g",
    "GIT_AUTHOR_EMAIL": "g@g",
    "GIT_AUTHOR_DATE": "1000000000 +0000",
    "GIT_COMMITTER_NAME": "g",
    "GIT_COMMITTER_EMAIL": "g@g",
    "GIT_COMMITTER_DATE": "1000000000 +0000",
})
def g(*args, cwd=None):
    subprocess.check_call([git, "-c", "init.defaultBranch=main"] + list(args), cwd=cwd, env=env)

def hello_blob(punch):
    lines = ["line %03d of the git fixture blob" % i for i in range(200)]
    if punch is not None:
        lines[punch] = "LINE %03d PUNCHED" % punch
    return "\n".join(lines) + "\n"

# Commit one: HELLO plus SECOND, a one-line punch of the same blob, so the
# repacked store carries a depth-1 delta the clone run must resolve.
g("init", "-q", cwd=work)
open(os.path.join(work, "HELLO"), "w").write(hello_blob(None))
open(os.path.join(work, "SECOND"), "w").write(hello_blob(150))
g("add", "HELLO", "SECOND", cwd=work)
g("commit", "-q", "-m", "first", cwd=work)
sha1 = subprocess.check_output(
    [git, "rev-parse", "refs/heads/main"], cwd=work, env=env, text=True).strip()
bare = os.path.join(root, "g.git")
g("clone", "-q", "--bare", work, bare)
g("--git-dir", bare, "config", "http.uploadpack", "true")
g("--git-dir", bare, "-c", "pack.window=50", "-c", "pack.depth=50",
  "repack", "-a", "-d", "-q")
pack_dir = os.path.join(bare, "objects", "pack")
packs = [os.path.join(pack_dir, f) for f in os.listdir(pack_dir)
         if f.endswith(".pack")]
if not packs:
    sys.exit("go-git: no pack after repack")
vp = subprocess.check_output([git, "verify-pack", "-v", packs[0]], text=True)
if "chain length" not in vp:
    sys.exit("go-git: fixture pack has no delta (need a larger HELLO edit)")

# Fixtures later runs compare the share against (share-equals resolves an
# existing RUN_DIR file as the expectation).
open(os.path.join(run, "sha1"), "w").write(sha1 + "\n")
open(os.path.join(run, "hello-c1"), "w").write(hello_blob(None))
open(os.path.join(run, "hello-dirty"), "w").write("LOCAL EDIT - pull must not clobber\n")

cfx = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
chain = os.path.join(cfx, "chain-ec.pem")
key = os.path.join(cfx, "leaf-ec.key")
if not os.path.exists(chain):
    sys.exit("pinned fixture chain missing at %s" % chain)

wrapper = os.path.join(run, "git-https.py")
open(wrapper, "w").write(r'''
import os, socket, ssl, subprocess, sys, time

host, port = "127.0.0.1", 24541
cert, keyp = sys.argv[1], sys.argv[2]
gitroot = sys.argv[3]
gitbin = sys.argv[4]
# clone GET+POST, fetch GET+POST, dirty pull GET+POST, clean pull GET+POST,
# no-op fetch GET = 9; headroom for a retry, the last hook kills it anyway.
accept_n, timeout = 12, 600.0

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.maximum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(cert, keyp)
ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind((host, port))
ls.listen(8)
sys.stdout.write("git-https: listening on %s:%d\n" % (host, port))
sys.stdout.flush()
deadline = time.monotonic() + timeout
n = 0
while n < accept_n:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        sys.stdout.write("git-https: deadline\n")
        sys.stdout.flush()
        break
    ls.settimeout(remaining)
    n += 1
    try:
        raw, _ = ls.accept()
    except socket.timeout:
        sys.stdout.write("git-https: accept timed out\n")
        sys.stdout.flush()
        break
    try:
        with ctx.wrap_socket(raw, server_side=True) as s:
            req = b""
            while b"\r\n\r\n" not in req and len(req) < 16384:
                chunk = s.recv(4096)
                if not chunk:
                    break
                req += chunk
            head, _, rest = req.partition(b"\r\n\r\n")
            lines = head.split(b"\r\n")
            reqline = lines[0].decode("latin1") if lines else ""
            parts = reqline.split(" ")
            method = parts[0] if parts else "GET"
            target = parts[1] if len(parts) > 1 else "/"
            headers = {}
            for ln in lines[1:]:
                if b":" in ln:
                    k, v = ln.split(b":", 1)
                    headers[k.decode("latin1").lower()] = v.strip().decode("latin1")
            body = rest
            need = int(headers.get("content-length", "0") or "0")
            while len(body) < need:
                chunk = s.recv(need - len(body))
                if not chunk:
                    break
                body += chunk
            path, _, qs = target.partition("?")
            env = os.environ.copy()
            env["GATEWAY_INTERFACE"] = "CGI/1.1"
            env["GIT_PROJECT_ROOT"] = gitroot
            env["GIT_HTTP_EXPORT_ALL"] = "1"
            env["REQUEST_METHOD"] = method
            env["PATH_INFO"] = path
            env["QUERY_STRING"] = qs
            env["CONTENT_TYPE"] = headers.get("content-type", "")
            env["CONTENT_LENGTH"] = str(len(body))
            env["REMOTE_ADDR"] = "127.0.0.1"
            p = subprocess.run([gitbin, "http-backend"], input=body, capture_output=True, env=env)
            cgi = p.stdout
            if p.returncode != 0:
                sys.stdout.write("git-https: backend rc=%d stderr=%s\n" % (p.returncode, p.stderr[:200]))
                sys.stdout.flush()
            sep = b"\r\n\r\n" if b"\r\n\r\n" in cgi else b"\n\n"
            cgi_h, _, cgi_b = cgi.partition(sep)
            status = "200 OK"
            out_h = []
            for ln in cgi_h.splitlines():
                if ln.lower().startswith(b"status:"):
                    status = ln.split(b":", 1)[1].strip().decode("latin1")
                elif ln:
                    out_h.append(ln)
            resp = b"HTTP/1.0 " + status.encode("latin1") + b"\r\n"
            for ln in out_h:
                resp += ln + b"\r\n"
            resp += b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(cgi_b)
            resp += cgi_b
            s.sendall(resp)
            sys.stdout.write("git-https: served %s\n" % reqline)
            sys.stdout.flush()
    except (ssl.SSLError, OSError) as e:
        sys.stdout.write("git-https: refused: %s\n" % e)
        sys.stdout.flush()
    finally:
        try:
            raw.close()
        except OSError:
            pass
ls.close()
''')
log = open(os.path.join(run, "git-https.log"), "wb")
proc = subprocess.Popen(
    [sys.executable, wrapper, chain, key, root, git],
    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
time.sleep(0.2)
print("go-git: staged GOTGIT.ELF (%d); git-https pid=%d" % (
    os.path.getsize(os.path.join(share, "GOTGIT.ELF")), proc.pid))
PY

# --- run 01: clone at commit one -------------------------------------------
vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24541:relay --net-tcp-respond-relay 127.0.0.1:24541 \
    --script '$RUN_DIR/script-clone.txt' --script-expect 'gotgit OK' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTGIT.ELF'
vgate_assert 01 serial-contains 'gotgit: start'
vgate_assert 01 serial-contains 'gotgit: url https://10.0.0.2:24541/g.git'
vgate_assert 01 serial-contains 'gotgit: dial 10.0.0.2 24541 leaf.example.com GET'
vgate_assert 01 serial-contains 'gotgit: handshake ok'
vgate_assert 01 serial-count 'gotgit: handshake ok' 2
vgate_assert 01 serial-contains 'gotgit: dial 10.0.0.2 24541 leaf.example.com POST'
vgate_assert 01 serial-contains 'gotgit: refs '
vgate_assert 01 serial-contains 'gotgit: want '
vgate_assert 01 serial-contains 'gotgit: pack objects='
vgate_assert 01 serial-contains 'gotgit: blob '
vgate_assert 01 serial-contains 'gotgit: tree '
vgate_assert 01 serial-contains 'gotgit: commit '
vgate_assert 01 serial-contains 'gotgit: checkout HELLO'
vgate_assert 01 serial-contains 'gotgit: checkout SECOND'
vgate_assert 01 serial-contains 'gotgit: delta'
vgate_assert 01 serial-contains 'gotgit OK'
vgate_assert 01 serial-absent 'gotgit: error'
vgate_assert 01 serial-absent 'FETCHS.BIN'
vgate_assert 01 serial-absent 'GET / HTTP'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 share-equals 'G/HELLO' 'hello-c1'
vgate_assert 01 python <<'PY'
import os, zlib
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
objroot = os.path.join(share, "G", ".git", "objects")
found = {"blob": 0, "tree": 0, "commit": 0}
saw_punch = False
for d in sorted(os.listdir(objroot)):
    dp = os.path.join(objroot, d)
    if not os.path.isdir(dp) or len(d) != 2:
        continue
    for fn in os.listdir(dp):
        raw = open(os.path.join(dp, fn), "rb").read()
        data = zlib.decompress(raw)
        for kind in found:
            if data.startswith(kind.encode() + b" "):
                found[kind] += 1
        if data.startswith(b"blob ") and b"LINE 150 PUNCHED" in data:
            saw_punch = True
assert found["blob"] >= 1 and found["tree"] >= 1 and found["commit"] >= 1, found
assert saw_punch, "SECOND blob (the delta pair member) missing from object store"
print("go-git clone objects on disk: %s" % found)
PY

# Advance the remote AFTER the clone: commit two punches HELLO and adds
# NEWS. Runs as a run-01 assert hook so it lands before the 02 boot; the
# fixture files it writes are what the later share-equals checks compare.
vgate_assert 01 python <<'PY'
import os, shutil, subprocess, sys

run = os.environ["RUN_DIR"]
git = shutil.which("git")
work = os.path.join(run, "work")
bare = os.path.join(run, "gitroot", "g.git")
env = os.environ.copy()
env.update({
    "GIT_AUTHOR_NAME": "g", "GIT_AUTHOR_EMAIL": "g@g",
    "GIT_AUTHOR_DATE": "1000000060 +0000",
    "GIT_COMMITTER_NAME": "g", "GIT_COMMITTER_EMAIL": "g@g",
    "GIT_COMMITTER_DATE": "1000000060 +0000",
})
def g(*args, cwd=None):
    subprocess.check_call([git, "-c", "init.defaultBranch=main"] + list(args), cwd=cwd, env=env)

def hello_blob(punch):
    lines = ["line %03d of the git fixture blob" % i for i in range(200)]
    if punch is not None:
        lines[punch] = "LINE %03d PUNCHED" % punch
    return "\n".join(lines) + "\n"

open(os.path.join(work, "HELLO"), "w").write(hello_blob(100))
open(os.path.join(work, "NEWS"), "w").write("news from commit two\n")
g("add", "HELLO", "NEWS", cwd=work)
g("commit", "-q", "-m", "second", cwd=work)
g("push", "-q", bare, "main", cwd=work)
g("--git-dir", bare, "-c", "pack.window=50", "-c", "pack.depth=50",
  "repack", "-a", "-d", "-q")
sha2 = subprocess.check_output(
    [git, "--git-dir", bare, "rev-parse", "refs/heads/main"], env=env, text=True).strip()
open(os.path.join(run, "sha2"), "w").write(sha2 + "\n")
open(os.path.join(run, "hello-c2"), "w").write(hello_blob(100))
open(os.path.join(run, "news-c2"), "w").write("news from commit two\n")
open(os.path.join(run, "fetch-head-2"), "w").write(sha2 + "\t\trefs/heads/main\n")
print("go-git: remote advanced to %s" % sha2)
PY

# --- run 02: fetch — refs move, worktree does NOT ---------------------------
vgate_run 02 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24541:relay --net-tcp-respond-relay 127.0.0.1:24541 \
    --script '$RUN_DIR/script-fetch.txt' --script-expect 'gotgit OK' --timeout 240

vgate_assert 02 serial-contains 'gotgit: start'
vgate_assert 02 serial-contains 'gotgit: dial 10.0.0.2 24541 leaf.example.com GET'
vgate_assert 02 serial-contains 'gotgit: dial 10.0.0.2 24541 leaf.example.com POST'
vgate_assert 02 serial-contains 'gotgit: refs '
vgate_assert 02 serial-contains 'gotgit: want refs/heads/main '
vgate_assert 02 serial-contains 'gotgit: have '
vgate_assert 02 serial-contains 'gotgit: pack objects='
vgate_assert 02 serial-contains 'gotgit: fetch '
vgate_assert 02 serial-contains 'gotgit OK'
vgate_assert 02 serial-absent 'gotgit: error'
vgate_assert 02 serial-absent 'gotgit: checkout '
vgate_assert 02 serial-absent 'gotgit: pull '
# fetch moved the tracking ref, not the branch, not the worktree.
vgate_assert 02 share-equals 'G/.git/refs/remotes/origin/main' 'sha2'
vgate_assert 02 share-equals 'G/.git/FETCH_HEAD' 'fetch-head-2'
vgate_assert 02 share-equals 'G/.git/refs/heads/main' 'sha1'
vgate_assert 02 share-equals 'G/HELLO' 'hello-c1'

# Dirty the checked-out file the next pull would overwrite.
vgate_assert 02 python <<'PY'
import os
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
open(os.path.join(share, "G", "HELLO"), "w").write(
    "LOCAL EDIT - pull must not clobber\n")
print("go-git: dirtied G/HELLO for the refusal run")
PY

# --- run 03: pull on a dirty tree refuses without touching it ---------------
vgate_run 03 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24541:relay --net-tcp-respond-relay 127.0.0.1:24541 \
    --script '$RUN_DIR/script-pull.txt' --script-expect 'gotgit: error dirty HELLO' --timeout 240

vgate_assert 03 serial-contains 'gotgit: refs '
vgate_assert 03 serial-contains 'gotgit: want refs/heads/main '
vgate_assert 03 serial-contains 'gotgit: error dirty HELLO'
vgate_assert 03 serial-absent 'gotgit: pull '
vgate_assert 03 serial-absent 'gotgit OK'
# The refusal leaves the local edit byte-exact and the branch ref at c1;
# the fetch half already landed (tracking ref at c2) — exactly where a
# real `git pull` leaves a dirty tree.
vgate_assert 03 share-equals 'G/HELLO' 'hello-dirty'
vgate_assert 03 share-equals 'G/.git/refs/heads/main' 'sha1'
vgate_assert 03 share-equals 'G/.git/refs/remotes/origin/main' 'sha2'

# Restore the clean c1 worktree for the green pull.
vgate_assert 03 python <<'PY'
import os, shutil
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
shutil.copyfile(os.path.join(run, "hello-c1"), os.path.join(share, "G", "HELLO"))
print("go-git: restored clean HELLO for the pull run")
PY

# --- run 04: pull — second commit's files appear, refs match ----------------
vgate_run 04 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24541:relay --net-tcp-respond-relay 127.0.0.1:24541 \
    --script '$RUN_DIR/script-pull.txt' --script-expect 'gotgit OK' --timeout 240

vgate_assert 04 serial-contains 'gotgit: want refs/heads/main '
vgate_assert 04 serial-contains 'gotgit: have '
vgate_assert 04 serial-contains 'gotgit: checkout HELLO'
vgate_assert 04 serial-contains 'gotgit: checkout NEWS'
vgate_assert 04 serial-contains 'gotgit: pull '
vgate_assert 04 serial-contains 'gotgit OK'
vgate_assert 04 serial-absent 'gotgit: error'
vgate_assert 04 share-equals 'G/HELLO' 'hello-c2'
vgate_assert 04 share-equals 'G/NEWS' 'news-c2'
vgate_assert 04 share-equals 'G/.git/refs/heads/main' 'sha2'
vgate_assert 04 share-equals 'G/.git/refs/remotes/origin/main' 'sha2'

# --- run 05: incremental fetch with nothing new is a clean no-op ------------
vgate_run 05 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24541:relay --net-tcp-respond-relay 127.0.0.1:24541 \
    --script '$RUN_DIR/script-fetch.txt' --script-expect 'gotgit OK' --timeout 240

vgate_assert 05 serial-contains 'gotgit: refs '
vgate_assert 05 serial-contains 'gotgit: up-to-date'
vgate_assert 05 serial-contains 'gotgit OK'
vgate_assert 05 serial-absent 'gotgit: error'
vgate_assert 05 serial-absent 'gotgit: dial 10.0.0.2 24541 leaf.example.com POST'
vgate_assert 05 serial-absent 'gotgit: pack objects='
vgate_assert 05 serial-absent 'gotgit: fetch '
# Last hook: retire the leftover listener on the 24541 pin.
vgate_assert 05 python <<'PY'
import subprocess
subprocess.run(["sh", "-c", "lsof -ti tcp:24541 | xargs kill -9"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("go-git: listener on 24541 retired")
PY
