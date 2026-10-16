# live-flint-loop.spec -- M107d (issue #2321) class-B: the versioned dev
# loop on VZ. Run 01: init -> add -> commit -> in-guest edit -> re-add.
# Run 02: `flint status` + the M107d `flint diff` review, second commit.
# Run 03: push to an EMPTY flintd store (create + one Change per append
# under maxBatchBytes) then a REMOTE.json-bound bare push; host asserts
# byte-compare the pushed log and run `flint verify --all`.
#
# Three boots because the sequential-exec reclamation race drops execs
# past ~6 (`gosh: FLINT.ELF: not found`, observed on exec 7 here);
# echo/cat are builtins and the one `sleep 1` is go-flint's
# socket-session spacing. NOT vgate_repeat-safe (share state carries).
#
# HOST PREREQ: bash tools/go/build-flint.sh + build-gosh.sh; sibling
# ../flint-server + ../flint-client checkouts (FLINT_SERVER_DIR /
# FLINT_CLIENT_DIR overrides) zig-built by the hook — drawmeanelephant
# repos under the VirelaiOS license, not GPL-family.
# exec-order: assert-proven -- run 01 ends on `new=1 modified=1`, run 02
# on the LOOP-COMMITTED echo, run 03 on `flint: push up to date`.

vgate_name live-flint-loop "issue #2321 M107d: init->edit->add->diff->commit->push round-trip; host flint verify + byte-compare"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-01.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/01.SH"
EOF

vgate_file script-02.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/02.SH"
EOF

vgate_file script-03.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/03.SH"
EOF

vgate_setup_python <<'PY'
import os, shutil, socket, subprocess, sys, time

run = os.environ["RUN_DIR"]
repo = os.getcwd()

for name, cmd in (
    ("FLINT.ELF", "bash tools/go/build-flint.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
):
    if not os.path.isfile(os.path.join(".build", "go", name)):
        sys.exit(name + " missing - build it first: " + cmd)

# App-bound Ed25519 signing seed (RFC 8032 §7.1 TEST 1) for commits, and the
# shared --auth-key for FLINT-SYNC/1 — same secret-lane shape as go-flint.
sig_dir = os.path.join("user", "go", "flint", "testdata", "sig")
SEED_HEX = open(os.path.join(sig_dir, "seed.hex"), "r", encoding="utf-8").read().strip()
AUTH_KEY_HEX = "ab" * 32

share = os.path.join(run, "loop-share")
os.makedirs(os.path.join(share, "FLINTJ"), exist_ok=True)
os.makedirs(os.path.join(share, "LOOPSRC"), exist_ok=True)
for name in ("FLINT.ELF", "GOSH.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(share, name))
open(os.path.join(share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\n"
)
open(os.path.join(share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nagent-sign\t1000\t" + SEED_HEX + "\tFLINT.ELF\n"
    "flint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF\n"
)

open(os.path.join(share, "LOOPSRC", "prog.go"), "w", encoding="utf-8").write(
    "package loop\n\n"
    "func Answer() int {\n"
    "\treturn 41\n"
    "}\n\n"
    "func Mul(a, b int) int {\n"
    "\treturn a * b\n"
    "}\n"
)
open(os.path.join(share, "FLINTJ", "loop-v2.go"), "w", encoding="utf-8").write(
    "package loop\n\n"
    "func Answer() int {\n"
    "\treturn 42\n"
    "}\n\n"
    "func Mul(a, b int) int {\n"
    "\treturn a * b\n"
    "}\n\n"
    "func Sub(a, b int) int {\n"
    "\treturn a - b\n"
    "}\n"
)
open(os.path.join(share, "FLINTJ", "01.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF init --name=loop --src=/host/LOOPSRC\n"
    "FLINT.ELF add /host/LOOPSRC\n"
    "FLINT.ELF commit -m \"base\"\n"
    "cat /host/FLINTJ/loop-v2.go > /host/LOOPSRC/prog.go\n"
    "FLINT.ELF add /host/LOOPSRC\n"
)
open(os.path.join(share, "FLINTJ", "02.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF status\n"
    "FLINT.ELF diff\n"
    "FLINT.ELF commit -m \"edit\"\n"
    "echo LOOP-COMMITTED\n"
)
open(os.path.join(share, "FLINTJ", "03.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF push --remote=10.0.0.2:4748 --stream=main\n"
    "sleep 1\n"
    "FLINT.ELF push\n"
)

# Host flintd on an EMPTY store (the push must `create` the stream), plus
# the host client for the post-run `flint verify --all`.
def find_sibling(env_name, dirname, need):
    d = os.environ.get(env_name) or os.path.join(repo, "..", dirname)
    d = os.path.abspath(d)
    if not os.path.isfile(os.path.join(d, "build.zig")):
        sys.exit(
            "%s checkout missing at %s - clone it once (outside the repo): "
            "git clone https://github.com/drawmeanelephant/%s %s"
            % (dirname, d, dirname, d)
        )
    if not os.path.isfile(os.path.join(d, need)):
        subprocess.check_call(["zig", "build"], cwd=d)
    return os.path.join(d, need)

flintd = find_sibling("FLINT_SERVER_DIR", "flint-server",
                      os.path.join("zig-out", "bin", "flintd"))
flint_host = find_sibling("FLINT_CLIENT_DIR", "flint-client",
                          os.path.join("zig-out", "bin", "flint"))
open(os.path.join(run, "flint-client-path.txt"), "w").write(flint_host + "\n")

flintd_store = os.path.join(run, "loopd-store")
subprocess.check_call([flintd, "init", "--store=" + flintd_store])

auth_key_file = os.path.join(run, "flint-auth.key")
open(auth_key_file, "w", encoding="utf-8").write(AUTH_KEY_HEX + "\n")

subprocess.run(
    ["sh", "-c", "lsof -ti tcp:4748 | xargs kill -9"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
time.sleep(0.2)
flintd_log = open(os.path.join(run, "flintd.log"), "wb")
flintd_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store,
     "--listen=127.0.0.1:4748", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True,
)
flintd_up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4748), 0.2)
        s.close()
        flintd_up = True
        break
    except OSError:
        if flintd_proc.poll() is not None:
            break
        time.sleep(0.1)
if not flintd_up:
    sys.exit("flintd did not come up on 127.0.0.1:4748 (see flintd.log)")
print("flintd: serving %s on 127.0.0.1:4748 pid=%d; host client %s"
      % (flintd_store, flintd_proc.pid, flint_host))
PY

# ---- 01: init, base commit, in-guest edit, re-add -------------------------
vgate_run 01 -- \
    --cvc-file '$RUN_DIR/loop-share' \
    --virtio-fs '$RUN_DIR/loop-share' \
    --script '$RUN_DIR/script-01.txt' \
    --script-expect 'flint: add files=1 new=1 modified=1 deleted=0 unchanged=1' \
    --script-expect-tail 3 --timeout 180

vgate_assert 01 serial-contains 'flint: init ok ws=loop stream=main'
vgate_assert 01 serial-contains 'flint: add files=1 new=2 modified=0 deleted=0 unchanged=0'
vgate_assert 01 serial-contains 'flint: commit ok id='
vgate_assert 01 serial-contains ' ops=2 parent=none'
vgate_assert 01 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 01 serial-absent '[EXC] parking:'

# ---- 02: review staged set with status+diff, land the edit commit --------
vgate_run 02 -- \
    --cvc-file '$RUN_DIR/loop-share' \
    --virtio-fs '$RUN_DIR/loop-share' \
    --script '$RUN_DIR/script-02.txt' \
    --script-expect 'LOOP-COMMITTED' \
    --script-expect-tail 3 --timeout 180

vgate_assert 02 serial-contains 'flint: status ws=loop stream=main atoms=3 staged=2 add=1 modify=1 delete=0 duplicates=0'
vgate_assert 02 serial-contains 'flint: diff ws=loop stream=main files=1 staged=2 add=1 modify=1 delete=0'
vgate_assert 02 serial-contains 'flint: diff modify prog.go loop.Answer'
vgate_assert 02 serial-contains 'flint: diff add prog.go loop.Sub'
vgate_assert 02 serial-contains 'flint: commit ok id='
vgate_assert 02 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 02 serial-absent '[EXC] parking:'

# ---- 03: push creates the remote stream, bare push binds REMOTE.json -----
vgate_run 03 -- \
    --cvc-file '$RUN_DIR/loop-share' \
    --virtio-fs '$RUN_DIR/loop-share' \
    --net '$RUN_DIR/cap03.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4748:relay --net-tcp-respond-relay 127.0.0.1:4748 \
    --script '$RUN_DIR/script-03.txt' \
    --script-expect 'flint: push up to date' \
    --script-expect-tail 3 --timeout 180

vgate_assert 03 serial-contains 'flint: push ok stream=main changes=2'
vgate_assert 03 serial-contains 'flint: push up to date'
vgate_assert 03 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 03 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import glob, json, os, subprocess, sys

run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-03.out"), errors="replace").read()
for leaked in (
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    "ab" * 32,
):
    if leaked in out:
        sys.exit("FAIL: secret hex reached run-03.out")

# The guest stream log and the server's copy must be byte-identical.
local_logs = glob.glob(os.path.join(run, "loop-share", "FLINT", "streams", "*.jsonl"))
if len(local_logs) != 1:
    sys.exit("expected 1 local stream log, got %r" % local_logs)
stream_id = os.path.basename(local_logs[0])[:-len(".jsonl")]
remote_log = os.path.join(run, "loopd-store", "streams", stream_id + ".jsonl")
if not os.path.isfile(remote_log):
    sys.exit("pushed stream log missing on server: " + remote_log)
local_raw = open(local_logs[0], "rb").read()
remote_raw = open(remote_log, "rb").read()
if local_raw != remote_raw:
    sys.exit("pushed stream log is not byte-verbatim")
lines = local_raw.decode("utf-8").splitlines()
if len(lines) != 2:
    sys.exit("expected 2 Changes on the stream, got %d" % len(lines))

# REMOTE.json bound by the first push is what the bare push consumed.
remote_cfg = open(os.path.join(run, "loop-share", "FLINT", "REMOTE.json")).read()
if '"remote":"tcp://10.0.0.2:4748"' not in remote_cfg or ('"stream":"%s"' % stream_id) not in remote_cfg:
    sys.exit("REMOTE.json does not bind the push: %r" % remote_cfg)

# The card's acceptance: the real host client verifies every pushed Change.
flint = open(os.path.join(run, "flint-client-path.txt")).read().strip()
res = subprocess.run(
    [flint, "--store", os.path.join(run, "loopd-store"), "verify", "--all"],
    capture_output=True, text=True,
)
if res.returncode != 0:
    sys.exit("host flint verify --all rc=%d: %s%s" % (res.returncode, res.stdout, res.stderr))
verified = [l for l in res.stdout.splitlines() if l.endswith("sig: verified")]
if len(verified) != 2:
    sys.exit("expected 2 'sig: verified' lines from host verify, got %r" % res.stdout)
rec = json.load(open(os.path.join(run, "loopd-store", "streams", stream_id + ".json")))
if rec.get("head") != json.loads(lines[-1]).get("id"):
    sys.exit("server stream head %r != last pushed change %r" % (rec.get("head"), lines[-1]))
print("run-03 loop ok: 2 pushed Changes byte-verbatim, host verify sig:verified x2, head rolled")
PY
