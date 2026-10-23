# live-agent-loop.spec -- M109d (issue #2400, ADR 0052) class-B: the agent
# loop end to end — one agent, one chain, six boots of the same truth.
# A host-side driver (tools/gate/fixtures/agent-app/agentloop.py, an
# agentctl Session over --net-tcp-connect-stream) acts ONLY through
# AGENTD verbs. Run 01's session authors the app (fs.write main.go) and
# does `flint init/add/commit` for the sources (gosh.run), then leaves
# its build-dispatch artifact (fs.write BUILD.REQ). The build CANNOT run
# in-session: agentd+gobuild+compile exceeds the 13-slot user task pool
# (observed live: `newosproc: sys_thread create failed` inside the
# compile child — the same wall live-dev-loop's header pins), so run 02
# is a monitor-only build boot that `vf cat`s the agent's request and
# execs GOBUILD on the armed share — the agent's dispatch, consumed
# on serial. Runs 03/04's sessions resume: they check the product exists
# via fs.read (the ELF outgrows the 4 KiB read cap, so `too_large` is the
# yes answer), compute its sha256 host-side over --share — named gap: no
# in-guest hasher exists (crypto/sha256 is outside the staged package
# surface) — write release.go in THREE fs.write halves so every pushed
# Change fits one wire segment (a multi-segment append request risks
# the documented retransmit-dedup corruption), commit thrice more,
# check the stream has all four commits, leave the second dispatch
# artifact (fs.write PUSH.REQ), and read the manifest back byte-for-byte.
# The release work is split across TWO sessions because each gosh.run
# burns task slots the reaper returns only lazily — ~10 sequential
# flint children in one boot starves the pool (live: `agentd: spawn
# pid=0 status=-1` then a timed_out refusal, #2430's own ENOSPC corner)
# and a fresh boot is a fresh pool. Run 05 is the SECOND monitor-dispatch
# boot — vf cat consumes PUSH.REQ, GOSH execs the push detached —
# because the ~2-4 min wire round trip always outlives an in-session
# verb: agentd sends the answer and it is never delivered (the same
# class of transport death as #2436, with the slow op as the trigger;
# observed live on every attempt).
#
# M173d (#3045, ADR 0052 amendment) two-principal posture: AGENTD runs
# under `exec -u2000` and every child it spawns inherits uid_agent
# (index D15), so everything the loop writes must live under an
# agent-owned root. AGENT/ and AGENT/AUDIT/ are kernel-minted
# (`trust.ensure_agent_roots`); the FLINT store subtree is granted to
# the agent by the seeded OWNERS.TXT row `FLINT 755 2000`, and the
# agent-sign/flint-remote SECRETS.TXT rows are scoped to uid 2000 —
# every FLINT consumer on this share is an agent principal. The two
# monitor-dispatch boots exec their consumers as uid_agent too: they
# are the agent's own build/push requests landing inside agent-owned
# workspace (a uid_user GOBUILD cannot write AGENT/APP/.BUILD, and a
# uid_user push cannot write FLINT/REMOTE.json). Runs 06/07 stay
# uid_user by design — the fresh share is the USER's machine pulling
# what the agent pushed. The hermetic flintd rides this spec's
# own lane, 127.0.0.1:4750 (a shared port means a sibling gate's
# lsof-sweep murders the daemon mid-run; go-flint pins 4749 for the same
# reason). Run 05's post-run assert verifies the stream landed
# byte-verbatim + every Change signed by the guest's agent-sign key,
# then materializes only the untrusted drop — the fresh share's
# streams/ stays EMPTY, so the install leg must clone the stream over
# the wire itself (the ELF can never ride a wire read: go-flint's
# documented bound).
# Runs 06/07 boot a FRESH --cvc-file share: `store ls` clones the
# stream over the wire and folds the catalog (one boot — the consumer
# chain is GOSH→STORE→FLINT per command and ~8 nested children starves
# the same pool), then `store install main` verifies keyring + signature
# + manifest + ELF sha end to end and the guest-built app prints its own
# marker on the final boot. Every hop leaves an AGENT/AUDIT receipt (the
# lane persists across the three agentd boots on the one armed share);
# vgate_repeat 5 is the card's K=5, and the last run's assert resets the
# workspaces, drops, receipts, and the flintd store so each pass is a
# fresh loop rather than a replay.
#
# Every run rides --cpus 1: the chain's evidence is the agent's verbs and
# the install, not core count — and the KNOWN OPEN FLAKE #2436 can starve
# the guest's TCP TX under the smp serial flood (observed here: the guest
# ACKed the full fs.write request, then its session died and the daemon
# reported client_close while the runner still held the socket open).
# Single-core removes the flood the flake rides on; when #2436 lands this
# spec can drop the flag.
#
# HOST PREREQS:
#   bash tools/go/build-gosh.sh    -> .build/go/GOSH.ELF
#   bash tools/go/build-agentd.sh  -> .build/go/AGENTD.ELF
#   bash tools/go/build-flint.sh   -> .build/go/FLINT.ELF
#   bash tools/go/build-gobuild.sh -> .build/go/GOBUILD.ELF
#   bash tools/go/build-gotool.sh  -> .build/go/GOCMD{COMPILE,LINK}.ELF
#   bash tools/go/build-store.sh   -> .build/go/STORE.ELF
#   bash tools/go/stage-selfhost.sh -> .build/go/selfhost/{GOIMPORT.CFG,
#                                      GOPKGS.TXT,GPKG_*.a}
#   ../flint-server + ../flint-client checkouts (see live-dev-loop.spec)
# exec-order: intentional -- runs 01/03/04 exec AGENTD (the session
#   daemon, never awaited) and end on 'agentd: session end', which only
#   the session lifecycle prints. Runs 02/05 `vf cat` precede the exec
#   and end on the build's/push's own markers; runs 06/07 are one
#   sourced chain each, ending on ls' and the app's own markers.

vgate_name live-agent-loop "issue #2400 M109d: the agent loop end to end — agent-authored app, GOBUILD, flint push, fresh-share install + run"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 5 BOOTS

# ---- boot scripts -----------------------------------------------------------
# Runs 01/03 ride the session daemon under --allow-exec (the gosh.run
# verb); run 02 is the agentd-free build boot (the four-runtime wall is
# the header's subject); run 04 is the fresh-share consumer.
vgate_file script-01.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec -u2000 AGENTD.ELF --allow-exec
EOF

vgate_file script-02.txt <<'EOF'
vf cat AGENT/BUILD.REQ
exec -u2000 GOBUILD.ELF /host/AGENT/APP -o /host/AGENT/APP.ELF
EOF

vgate_file script-03.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec -u2000 AGENTD.ELF --allow-exec
EOF

vgate_file script-04.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec -u2000 AGENTD.ELF --allow-exec
EOF

vgate_file script-05.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
vf cat AGENT/PUSH.REQ
exec -u2000 GOSH.ELF -c "FLINT.ELF push --remote=10.0.0.2:4750 --stream=main"
EOF

vgate_file script-06.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/LS.SH"
EOF

vgate_file script-07.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/I.SH"
EOF

# ---- setup --------------------------------------------------------------------
vgate_setup_python <<'PY'
import os, shutil, socket, subprocess, sys, time

run = os.environ["RUN_DIR"]
repo = os.getcwd()
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)
sys.path.insert(0, os.path.join("tools", "agentctl"))
import agentctl

# 1. Guest binaries: the daemon, the shell, the SCM, the store, and the
#    build chain (driver + both tool children + the staged package
#    surface GOBUILD resolves against — the live-dev-loop staging).
for name, cmd in (
    ("AGENTD.ELF", "bash tools/go/build-agentd.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
    ("FLINT.ELF", "bash tools/go/build-flint.sh"),
    ("STORE.ELF", "bash tools/go/build-store.sh"),
    ("GOBUILD.ELF", "bash tools/go/build-gobuild.sh"),
    ("GOCMDCOMPILE.ELF", "bash tools/go/build-gotool.sh"),
    ("GOCMDLINK.ELF", "bash tools/go/build-gotool.sh"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first "
                 "(see this spec's header): " + cmd)
    shutil.copy(src, os.path.join(share, name))
selfhost = os.path.join(".build", "go", "selfhost")
if not os.path.isfile(os.path.join(selfhost, "GOIMPORT.CFG")):
    sys.exit("selfhost staging missing - run: bash tools/go/stage-selfhost.sh")
for name in os.listdir(selfhost):
    if (name.startswith("GPKG_") and name.endswith(".a")) or \
       name in ("GOIMPORT.CFG", "GOPKGS.TXT"):
        shutil.copy(os.path.join(selfhost, name), os.path.join(share, name))

# 2. wm=none: no seat ever starts, so the toolchain children hold every
#    EL0 slot they need (live-goedit-diags run 02's wall).
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")

# 3. The agent's Ed25519 identity: devin's pinned seed stays host-side
#    ($RUN_DIR key file, never argv); AGENTS.TXT carries the public half
#    with exactly the caps this journey needs (file for fs.*, term for
#    gosh.run — the declared-caps model, ADR 0052 D2).
SEED_HEX = "0a" * 32
pub = agentctl.ed_public_key(bytes.fromhex(SEED_HEX)).hex()
open(os.path.join(run, "devin.key"), "w").write("devin " + SEED_HEX + "\n")
open(os.path.join(share, "AGENTS.TXT"), "w").write(
    "#v1\nagent=devin key=%s caps=file,term\n" % pub)

# 4. Credentials: the guest's agent-sign seed (RFC 8032 TEST 1 — the same
#    vector go-flint/live-dev-loop pin, so TRUSTED.TXT below names the
#    publisher the keyring already knows), the FLINT-SYNC/1 push auth
#    key, and agent-hmac (the M109c receipt key — the door key is the
#    Ed25519 row above). All three rows scope to uid_agent (M173d): the
#    only FLINT consumers on this share run as uid 2000 — agentd's
#    gosh.run children and the -u2000 monitor-dispatch boots.
sig_dir = os.path.join("user", "go", "flint", "testdata", "sig")
SIGN_SEED_HEX = open(os.path.join(sig_dir, "seed.hex")).read().strip()
AUTH_KEY_HEX = "ab" * 32
RECEIPT_KEY_HEX = "a5" * 32
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n"
    "agent-sign\t2000\t" + SIGN_SEED_HEX + "\tFLINT.ELF\n"
    "flint-remote\t2000\t" + AUTH_KEY_HEX + "\tFLINT.ELF\n"
    "agent-hmac\t2000\t" + RECEIPT_KEY_HEX + "\tAGENTD.ELF\n")
# OWNERS.TXT: the ELFs and the keyring stay uid_system (the app-bound
# secret rows need system_owned_key; the keyring is world-readable).
# The FLINT store root is the operator-granted AGENT-OWNED subtree —
# flint's storeRoot is fixed at /host/FLINT, so the seeded row is how
# uid_agent children mkdir ws/, streams/ and write REMOTE.json under it
# (defaultOwner carries the agent's ownership down the whole subtree).
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nAGENTD.ELF\t644\t0\t-\nFLINT.ELF\t644\t0\t-\nAGENTS.TXT\t444\t0\t-\n"
    "FLINT\t755\t2000\t-\n")

# 5. The agent sandbox: root + the reserved audit lane + the workspace
#    dir (fs.write never makes parents).
for d in ("AGENT", "AGENT/AUDIT", "AGENT/APP"):
    os.makedirs(os.path.join(share, d), exist_ok=True)

# 6. Stale products must not let a broken run go green: a previous
#    boot's workspace state, product, dispatch artifact, capture file,
#    and receipts.
for stale in ("APP.ELF", "AGENT/AUDIT/AGENTD.OUT", "AGENT/BUILD.REQ"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
for stale_dir in ("AGENT/APP", "FLINT"):
    p = os.path.join(share, stale_dir)
    if os.path.isdir(p):
        shutil.rmtree(p)
        os.makedirs(p, exist_ok=True)
adir = os.path.join(share, "AGENT", "AUDIT")
if os.path.isdir(adir):
    for n in os.listdir(adir):
        os.remove(os.path.join(adir, n))

# 7. Host flintd on an EMPTY store (the push must `create` the stream) —
#    the live-dev-loop pattern verbatim: relay 10.0.0.2:4750 <->
#    127.0.0.1:4750. The pid + paths land in RUN_DIR so run 04's reset
#    assert can re-init and relaunch between iterations.
def find_sibling(env_name, dirname, need):
    d = os.environ.get(env_name) or os.path.join(repo, "..", dirname)
    d = os.path.abspath(d)
    if not os.path.isfile(os.path.join(d, "build.zig")):
        sys.exit("%s checkout missing at %s - clone it once (outside the "
                 "repo): git clone https://github.com/drawmeanelephant/%s %s"
                 % (dirname, d, dirname, d))
    if not os.path.isfile(os.path.join(d, need)):
        subprocess.check_call(["zig", "build"], cwd=d)
    return os.path.join(d, need)

flintd = find_sibling("FLINT_SERVER_DIR", "flint-server",
                      os.path.join("zig-out", "bin", "flintd"))
find_sibling("FLINT_CLIENT_DIR", "flint-client",
             os.path.join("zig-out", "bin", "flint"))
open(os.path.join(run, "flintd-path.txt"), "w").write(flintd + "\n")
open(os.path.join(run, "flint-auth.key"), "w").write(AUTH_KEY_HEX + "\n")
open(os.path.join(run, "flintd-store.txt"), "w").write(
    os.path.join(run, "agentloopd-store") + "\n")

def serve_flintd():
    store = os.path.join(run, "agentloopd-store")
    subprocess.check_call([flintd, "init", "--store=" + store])
    subprocess.run(["sh", "-c", "lsof -ti tcp:4750 | xargs kill -9"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.2)
    log = open(os.path.join(run, "flintd.log"), "ab")
    proc = subprocess.Popen(
        [flintd, "serve", "--store=" + store,
         "--listen=127.0.0.1:4750",
         "--auth-key=" + os.path.join(run, "flint-auth.key")],
        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(100):
        try:
            s = socket.create_connection(("127.0.0.1", 4750), 0.2)
            s.close()
            break
        except OSError:
            if proc.poll() is not None:
                sys.exit("flintd did not come up on 127.0.0.1:4750")
            time.sleep(0.1)
    open(os.path.join(run, "flintd.pid"), "w").write(str(proc.pid) + "\n")

serve_flintd()

# 8. The FRESH share run 04 boots: STORE+GOSH+FLINT, the publisher
#    keyring pinning the agent-sign author, the real fleet manifest, and
#    empty replica/drop slots the run-03 assert fills after the push
#    lands. AGENTAPP.ELF is staged nowhere — install must be the thing
#    that lands it at the share root.
ishare = os.path.join(run, "install-share")
os.makedirs(os.path.join(ishare, "FLINT", "streams"), exist_ok=True)
os.makedirs(os.path.join(ishare, "FLINTJ"), exist_ok=True)
os.makedirs(os.path.join(ishare, "DROP", "main"), exist_ok=True)
for name in ("FLINT.ELF", "GOSH.ELF", "STORE.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(ishare, name))
open(os.path.join(ishare, "OWNERS.TXT"), "w").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\n")
open(os.path.join(ishare, "SECRETS.TXT"), "w").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF\n")
author_pub = agentctl.ed_public_key(bytes.fromhex(SIGN_SEED_HEX)).hex()
open(os.path.join(ishare, "FLINT", "TRUSTED.TXT"), "w").write(
    "#v1\nkey=" + author_pub + " name=agentapp\n")
open(os.path.join(run, "author-pub.txt"), "w").write(author_pub + "\n")
shutil.copy(os.path.join("image", "apps.txt"), os.path.join(ishare, "APPS.TXT"))
open(os.path.join(ishare, "FLINTJ", "LS.SH"), "w").write(
    "STORE.ELF ls --remote=10.0.0.2:4750 --channel=/host/DROP\n")
open(os.path.join(ishare, "FLINTJ", "I.SH"), "w").write(
    "STORE.ELF install main --remote=10.0.0.2:4750 --channel=/host/DROP\n"
    "test -e /host/AGENTAPP.ELF || STORE.ELF install main "
    "--remote=10.0.0.2:4750 --channel=/host/DROP\n"
    "test -e /host/AGENTAPP.ELF || STORE.ELF install main "
    "--remote=10.0.0.2:4750 --channel=/host/DROP\n"
    "AGENTAPP.ELF\n")

print("agent-loop staged: agentd+toolchain share, flintd up, fresh install-share")
PY

# ---- 01: the agent authors the app and commits the sources ----------------------
vgate_run 01 -- \
    --cpus 1 \
    --net '$RUN_DIR/cap01.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/gate/fixtures/agent-app/agentloop.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--share=$RUN_DIR/share' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-stream-arg '--phase=author' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-01.txt' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 4 --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'agentd: start exec=on'
vgate_assert 01 serial-contains 'agentd: listen 4747'
vgate_assert 01 serial-contains 'agentd: accepted'
vgate_assert 01 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 01 serial-contains 'verb=fs.write ok'
vgate_assert 01 serial-contains 'verb=gosh.run ok'
vgate_assert 01 serial-contains 'agentd: spawn pid='
vgate_assert 01 serial-contains 'agentd: reap pid='
vgate_assert 01 serial-contains 'name=FLINT.ELF uid=2000'
vgate_assert 01 serial-contains 'flint: init ok ws=agentapp stream=main'
vgate_assert 01 serial-contains 'flint: add files=1 new=2 modified=0 deleted=0 unchanged=0'
vgate_assert 01 serial-contains 'flint: commit ok id='
vgate_assert 01 serial-contains 'agentd: session end reason=client_close'
vgate_assert 01 output-contains 'NET-TCP-STREAM: ENABLED'
vgate_assert 01 output-contains 'ALOOP: t='
vgate_assert 01 output-contains 'ok handshake'
vgate_assert 01 output-contains 'ok author'
vgate_assert 01 output-contains 'ok init'
vgate_assert 01 output-contains 'ok add-src'
vgate_assert 01 output-contains 'ok commit-src'
vgate_assert 01 output-contains 'ok build-request'
vgate_assert 01 output-contains 'PASS agentloop'
vgate_assert 01 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 01 share-contains 'AGENT/APP/main.go' 'agentapp: shipped by an agent'
vgate_assert 01 share-contains 'AGENT/BUILD.REQ' 'ALOOP-BUILD-REQUEST'
vgate_assert 01 serial-absent 'agentd: auth fail'
vgate_assert 01 serial-absent 'flint: refuse'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
vgate_assert 01 serial-absent 'cannot allocate memory'
vgate_assert 01 serial-absent 'newosproc: sys_thread create failed'
vgate_assert 01 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 01 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 01 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 01 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'

# ---- 02: the agentd-free build boot consumes the dispatch -----------------------
vgate_run 02 -- \
    --cpus 1 \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-02.txt' \
    --script-expect 'gobuild: build OK -> /host/AGENT/APP.ELF' \
    --script-expect-tail 3 --timeout 240

# `vf cat` is a stat op — it prints path+size+cksum, not the body — so the
# dispatch's serial marker is the cat of the agent-written request file
# itself (its content is run 01's share-contains + the AUDIT receipt).
vgate_assert 02 serial-contains 'vf: cat AGENT/BUILD.REQ size='
vgate_assert 02 serial-contains 'vf: cat ok'
vgate_assert 02 serial-contains 'gobuild: order main'
vgate_assert 02 serial-contains 'gobuild: compile main GOCMDCOMPILE.ELF status=0'
vgate_assert 02 serial-contains 'gobuild: link GOCMDLINK.ELF status=0'
vgate_assert 02 serial-contains 'gobuild: build OK -> /host/AGENT/APP.ELF'
vgate_assert 02 serial-contains 'name=GOBUILD.ELF uid=2000'
vgate_assert 02 serial-absent 'gobuild: FAIL'
vgate_assert 02 serial-absent 'newosproc: sys_thread create failed'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
elf = os.path.join(share, "AGENT", "APP.ELF")
if not os.path.isfile(elf):
    sys.exit("FAIL: /host/AGENT/APP.ELF missing - the guest build did not write it")
if os.path.getsize(elf) < 64 * 1024:
    sys.exit("FAIL: APP.ELF is suspiciously small (%d bytes)" % os.path.getsize(elf))
errors = os.path.join(share, "AGENT", "APP", ".BUILD", "ERRORS.TXT")
if os.path.isfile(errors) and os.path.getsize(errors) > 0:
    sys.exit("FAIL: ERRORS.TXT is not empty after a successful build")
print("run-02: guest-built ELF present at /host/AGENT/APP.ELF")
PY

# ---- 03: the agent resumes — manifest, release commits, push --------------------
vgate_run 03 -- \
    --cpus 1 \
    --net '$RUN_DIR/cap03.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/gate/fixtures/agent-app/agentloop.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--share=$RUN_DIR/share' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-stream-arg '--phase=release-a' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-03.txt' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 4 --timeout 300

vgate_assert 03 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 03 serial-contains 'verb=fs.write ok'
vgate_assert 03 serial-contains 'verb=gosh.run ok'
vgate_assert 03 serial-contains 'flint: add files=2 new=2 modified=0 deleted=0 unchanged=2'
vgate_assert 03 serial-contains 'flint: add files=2 new=1 modified=0 deleted=0 unchanged=4'
vgate_assert 03 serial-count 'flint: commit ok id=' 2
vgate_assert 03 serial-contains 'agentd: session end reason=client_close'
vgate_assert 03 output-contains 'ok built'
vgate_assert 03 output-contains 'ok manifest-a'
vgate_assert 03 output-contains 'ok commit-rel-a'
vgate_assert 03 output-contains 'ok manifest-b'
vgate_assert 03 output-contains 'ok commit-rel-b'
vgate_assert 03 output-contains 'PASS agentloop'
vgate_assert 03 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 03 share-contains 'AGENT/APP/release.go' 'ReleaseELFSHA256'
vgate_assert 03 serial-absent 'flint: refuse'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 serial-absent 'newosproc: sys_thread create failed'
vgate_assert 03 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 03 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 03 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 03 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'

# ---- 04: the agent's THIRD session — last manifest half, dispatch, roundtrip ----
# Two release sessions instead of one: each gosh.run burns task slots the
# reaper returns only lazily, and ~10 sequential flint children in one
# boot starves the pool — the live evidence is `agentd: spawn pid=0
# status=-1` then a timed_out refusal, #2430's own ENOSPC corner. A
# fresh boot is a fresh pool.
vgate_run 04 -- \
    --cpus 1 \
    --net '$RUN_DIR/cap04.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:4747 \
    --net-tcp-connect-stream 'tools/gate/fixtures/agent-app/agentloop.py' \
    --net-tcp-connect-stream-arg harness \
    --net-tcp-connect-stream-arg '--share=$RUN_DIR/share' \
    --net-tcp-connect-stream-arg '--key-file=$RUN_DIR/devin.key' \
    --net-tcp-connect-stream-arg '--phase=release-b' \
    --net-tcp-connect-after 'agentd: listen 4747' \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-04.txt' \
    --script-expect 'agentd: session end reason=client_close' \
    --script-expect-tail 4 --timeout 300

vgate_assert 04 serial-contains 'agentd: auth ok agent=devin'
vgate_assert 04 serial-contains 'verb=fs.write ok'
vgate_assert 04 serial-contains 'verb=gosh.run ok'
vgate_assert 04 serial-contains 'flint: add files=2 new=1 modified=0 deleted=0 unchanged=5'
vgate_assert 04 serial-contains 'flint: commit ok id='
vgate_assert 04 serial-contains 'agentd: session end reason=client_close'
vgate_assert 04 output-contains 'ok manifest-c'
vgate_assert 04 output-contains 'ok add-rel-c'
vgate_assert 04 output-contains 'ok commit-rel-c'
vgate_assert 04 output-contains 'ok commits-ready'
vgate_assert 04 output-contains 'ok push-request'
vgate_assert 04 output-contains 'ok roundtrip'
vgate_assert 04 output-contains 'PASS agentloop'
vgate_assert 04 output-contains 'NET-TCP-STREAM: probe exited status=0'
vgate_assert 04 share-contains 'AGENT/APP/release.go' 'ReleaseManifestRow'
vgate_assert 04 share-contains 'AGENT/PUSH.REQ' 'ALOOP-PUSH-REQUEST'
vgate_assert 04 serial-absent 'flint: refuse'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 serial-absent 'newosproc: sys_thread create failed'
vgate_assert 04 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 04 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 04 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 04 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'

# ---- 05: the agentd-free publish boot consumes PUSH.REQ ---------------------------
# The ~2-4 min wire round trip always outlives an in-session verb — the
# response is sent by agentd and never delivered (the same class of
# transport death as #2436, just the slow-drip trigger; observed live on
# every attempt). So the push rides the SAME monitor-dispatch seam as the
# build: vf cat consumes the agent's fs.write'd request, GOSH execs the
# push detached, and 'flint: push ok' is the marker. No session exists to
# kill.
vgate_run 05 -- \
    --cpus 1 \
    --net '$RUN_DIR/cap05.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4750:relay --net-tcp-respond-relay 127.0.0.1:4750 \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-05.txt' \
    --script-expect 'flint: push ok stream=main changes=4' \
    --script-expect-tail 4 --timeout 300

vgate_assert 05 serial-contains 'vf: cat AGENT/PUSH.REQ size='
vgate_assert 05 serial-contains 'vf: cat ok'
vgate_assert 05 serial-contains 'flint: push ok stream=main changes=4'
vgate_assert 05 serial-contains 'name=FLINT.ELF uid=2000'
vgate_assert 05 serial-absent 'flint: refuse'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 serial-absent 'newosproc: sys_thread create failed'
vgate_assert 05 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 05 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 05 serial-absent 'a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5'
vgate_assert 05 serial-absent '0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a'

# M109c receipts: every dispatch — fs.write, every gosh.run (each with its
# pre-exec intent pair), and the session frames — lands in AGENT/AUDIT as
# a MAC'd RCPT- file across ALL agentd boots (the lane persists on the
# armed share); verified against the pinned agent-hmac row.
vgate_assert 05 python <<'PY'
import hashlib, hmac, json, os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
adir = os.path.join(share, "AGENT", "AUDIT")
names = sorted(n for n in os.listdir(adir)
               if n.startswith("RCPT-") and not n.endswith("~"))
if not names:
    sys.exit("FAIL: no receipts in AGENT/AUDIT: %r" % os.listdir(adir))
if len(names) > 64:
    sys.exit("FAIL: audit bound exceeded: %d files" % len(names))
KEY = b"a5" * 32
seen = set()
intent = 0
for n in names:
    body = open(os.path.join(adir, n), "rb").read()
    lines = body.split(b"\n")
    if len(lines) != 3 or lines[2] != b"":
        sys.exit("FAIL: receipt %s is not two lines" % n)
    want = hmac.new(KEY, lines[0], hashlib.sha256).hexdigest().encode()
    if lines[1] != want:
        sys.exit("FAIL: receipt %s MAC mismatch" % n)
    r = json.loads(lines[0])
    seen.add((r.get("agent"), r.get("verb"), r.get("result")))
    # The pre-exec intent receipt carries {cmd, timeout_ms} only; the
    # post-dispatch pair adds the outcome fields (exit_status).
    if (r.get("verb") == "gosh.run" and "cmd" in r.get("args", {})
            and "exit_status" not in r.get("args", {})):
        intent += 1
for need in (
    ("devin", "fs.write", "ok"),
    ("devin", "gosh.run", "ok"),
):
    if need not in seen:
        sys.exit("FAIL: no %r receipt; saw %r" % (need, sorted(seen)))
if not any(a == "devin" and v == "session" for a, v, _ in seen):
    sys.exit("FAIL: no session-frame receipt; saw %r" % sorted(seen))
if intent == 0:
    sys.exit("FAIL: no gosh.run intent receipt; saw %r" % sorted(seen))
print("run-05 audit ok: %d receipts across all boots, all MAC'd, "
      "%d gosh.run intents" % (len(names), intent))
PY

# The pushed stream: byte-verbatim against the local log, every Change
# authored by the guest's agent-sign key, and each Change line under the
# relay fill bound the two-half manifest was designed around. Then the
# fresh share's untrusted drop materializes — the only bytes that can
# never ride the wire.
vgate_assert 05 python <<'PY'
import glob, hashlib, json, os, shutil, sys

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
ishare = os.path.join(run, "install-share")
out = open(os.path.join(run, "run-" + os.environ["VG_TAG"] + ".out"),
           errors="replace").read()
for leaked in ("0a" * 32, "ab" * 32, "a5" * 32,
               open(os.path.join("user", "go", "flint", "testdata", "sig",
                                 "seed.hex")).read().strip()):
    if leaked in out:
        sys.exit("FAIL: secret hex reached the runner log")

# The guest stream log and the server's copy must be byte-identical.
local_logs = glob.glob(os.path.join(share, "FLINT", "streams", "*.jsonl"))
if len(local_logs) != 1:
    sys.exit("expected 1 local stream log, got %r" % local_logs)
stream_id = os.path.basename(local_logs[0])[:-len(".jsonl")]
remote_log = os.path.join(run, "agentloopd-store", "streams",
                          stream_id + ".jsonl")
if not os.path.isfile(remote_log):
    sys.exit("pushed stream log missing on server: " + remote_log)
local_raw = open(local_logs[0], "rb").read()
remote_raw = open(remote_log, "rb").read()
if local_raw != remote_raw:
    sys.exit("pushed stream log is not byte-verbatim")
lines = local_raw.decode("utf-8").splitlines()
if len(lines) != 4:
    sys.exit("expected 4 Changes on the stream, got %d" % len(lines))

author_pub = open(os.path.join(run, "author-pub.txt")).read().strip()
names_signed = set()
for i, line in enumerate(lines):
    if len(line) > 1200:
        sys.exit("Change %d is %d bytes — over the one-segment request "
                 "bound the manifest's three-half split was designed around"
                 % (i, len(line)))
    c = json.loads(line)
    if c.get("author") != author_pub:
        sys.exit("Change %d not authored by the agent-sign key" % i)
    if not c.get("sig"):
        sys.exit("Change %d carries no signature" % i)
    for op in c.get("ops", []):
        if (op.get("new_span") or {}).get("file") == "release.go":
            names_signed.add(op.get("new_name"))

# The release head's signed atoms cover the manifest, and the manifest's
# sha256 is the built ELF's.
elf = os.path.join(share, "AGENT", "APP.ELF")
elf_sha = hashlib.sha256(open(elf, "rb").read()).hexdigest()
want = {"release.ReleaseName", "release.ReleaseVersion",
        "release.ReleaseELFSHA256", "release.ReleaseManifestRow"}
if names_signed != want:
    sys.exit("signed release atoms %r != %r" % (sorted(names_signed), sorted(want)))
rel_go = open(os.path.join(share, "AGENT", "APP", "release.go")).read()
if elf_sha not in rel_go:
    sys.exit("release.go's sha256 does not match the built ELF")

# Materialize only the untrusted drop: the fresh share keeps its
# streams/ EMPTY so `store ls`/`install` must CLONE the stream over the
# wire itself (observed: `flint: clone ok stream=main changes=3`) — the
# strongest read of 'fresh machine pulls what the agent pushed'. The
# ELF (~800 KiB) can never ride a wire `read`, so the channel carries
# it + release.go — still verified against the signed head at install.
# REMOTE.json is the guest-side record the push itself landed (flint
# writes it only after pushSingleStream returns).
if not os.path.isfile(os.path.join(share, "FLINT", "REMOTE.json")):
    sys.exit("REMOTE.json missing — the push boot did not land it")
drop = os.path.join(ishare, "DROP", "main")
os.makedirs(drop, exist_ok=True)
shutil.copy(os.path.join(share, "AGENT", "APP", "release.go"),
            os.path.join(drop, "release.go"))
shutil.copy(elf, os.path.join(drop, "AGENTAPP.ELF"))
open(os.path.join(run, "expected-elf-sha.txt"), "w").write(elf_sha + "\n")
print("run-05: stream pushed verbatim, 4 signed Changes under the bound, "
      "drop materialized, elf sha=%s" % elf_sha[:16])
PY

# ---- 06: the fresh VM's catalog leg — ls folds the wire clone --------------------
vgate_run 06 -- \
    --cpus 1 \
    --cvc-file '$RUN_DIR/install-share' \
    --virtio-fs '$RUN_DIR/install-share' \
    --net '$RUN_DIR/cap06.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4750:relay --net-tcp-respond-relay 127.0.0.1:4750 \
    --script '$RUN_DIR/script-06.txt' \
    --script-expect 'store: ls ok entries=1' \
    --script-expect-tail 4 --timeout 300

vgate_assert 06 serial-contains 'store: ls'
vgate_assert 06 serial-contains 'flint: clone ok stream=main changes=4'
vgate_assert 06 serial-contains 'store: stream main release name=AGENTAPP version=1.0.0'
vgate_assert 06 serial-contains 'publisher_name=agentapp publisher_state=trusted'
vgate_assert 06 serial-contains 'store: ls ok entries=1'
vgate_assert 06 serial-absent 'store: refuse'
vgate_assert 06 serial-absent 'flint: refuse'
vgate_assert 06 serial-absent 'sig_invalid'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
vgate_assert 06 serial-absent 'abababababababababababababababababababababababababababababababab'
# ---- 07: the fresh VM installs and runs what the agent shipped ------------------
# Install+run gets its own boot apart from ls: the consumer chain is
# GOSH→STORE→FLINT per command and the task pool starves past ~8 nested
# children (live: `store: refuse sync_failed exec` with the fourth spawn
# refusing outright — the same pool wall, at the leaf of the journey).
vgate_run 07 -- \
    --cpus 1 \
    --cvc-file '$RUN_DIR/install-share' \
    --net '$RUN_DIR/cap07.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4750:relay --net-tcp-respond-relay 127.0.0.1:4750 \
    --virtio-fs '$RUN_DIR/install-share' \
    --script '$RUN_DIR/script-07.txt' \
    --script-expect 'agentapp OK' --script-expect-tail 3 --timeout 300

vgate_assert 07 serial-contains 'store: install main'
vgate_assert 07 serial-contains 'store: verify main'
vgate_assert 07 serial-contains 'sig: verified'
vgate_assert 07 serial-contains 'store: verified main'
vgate_assert 07 serial-contains 'store: install ok AGENTAPP.ELF version=1.0.0'
vgate_assert 07 serial-contains 'agentapp: shipped by an agent through the loop'
vgate_assert 07 serial-contains 'agentapp OK'
vgate_assert 07 serial-contains 'procs AGENTAPP.ELF exited status=0'
vgate_assert 07 serial-absent 'flint: refuse'
vgate_assert 07 serial-absent 'sig_invalid'
vgate_assert 07 serial-absent 'elf_mismatch'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'
vgate_assert 07 serial-absent 'abababababababababababababababababababababababababababababababab'

vgate_assert 07 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
ishare = os.path.join(run, "install-share")
elf = os.path.join(ishare, "AGENTAPP.ELF")
if not os.path.isfile(elf):
    sys.exit("FAIL: AGENTAPP.ELF missing at share root after install")
got = hashlib.sha256(open(elf, "rb").read()).hexdigest()
want = open(os.path.join(run, "expected-elf-sha.txt")).read().strip()
if got != want:
    sys.exit("installed AGENTAPP.ELF sha %s != built %s" % (got, want))
apps = open(os.path.join(ishare, "APPS.TXT")).read()
if apps.count("AGENTAPP.ELF | Agent App | a | dock=false") != 1:
    sys.exit("expected exactly one AGENTAPP row in APPS.TXT: %r" % apps)
state = open(os.path.join(ishare, "STORE.TXT")).read()
if "AGENTAPP.ELF" not in state or "main" not in state:
    sys.exit("STORE.TXT did not record the install: %r" % state)
print("run-07: installed ELF hash matches the guest build; manifest row + state landed")
PY

# Per-iteration reset (K consecutive runs): wipe every artifact of the
# loop so the next pass is a fresh journey — the sandbox workspace, the
# flint store, the receipts, the dispatch artifact, the fresh share's
# replica/drop/install — and restart flintd on an empty store (the push
# must `create` again).
vgate_assert 07 python <<'PY'
import os, shutil, signal, socket, subprocess, sys, time
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")

for stale in ("APP.ELF", "AGENT/AUDIT/AGENTD.OUT", "AGENT/BUILD.REQ",
              "AGENT/PUSH.REQ"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
for stale_dir in ("AGENT/APP", "FLINT"):
    p = os.path.join(share, stale_dir)
    if os.path.isdir(p):
        shutil.rmtree(p)
    os.makedirs(p, exist_ok=True)
adir = os.path.join(share, "AGENT", "AUDIT")
if os.path.isdir(adir):
    for n in os.listdir(adir):
        os.remove(os.path.join(adir, n))

ishare = os.path.join(run, "install-share")
for rel in ("FLINT/streams", "DROP/main"):
    d = os.path.join(ishare, rel)
    if os.path.isdir(d):
        for n in os.listdir(d):
            os.remove(os.path.join(d, n))
for stale in ("AGENTAPP.ELF", "STORE.TXT"):
    p = os.path.join(ishare, stale)
    if os.path.exists(p):
        os.remove(p)
shutil.copy(os.path.join("image", "apps.txt"), os.path.join(ishare, "APPS.TXT"))

# flintd: kill THIS RUN's daemon by its store path (pgrep -f matches
# only the --store arg — immune to pid reuse, and it cannot murder a
# next gate's daemon the way a port-wide lsof sweep did), re-init the
# store, relaunch on the same socket.
store = os.path.join(run, "agentloopd-store")
subprocess.run(["pkill", "-9", "-f", "flintd serve --store=" + store],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.2)
if os.path.isdir(store):
    shutil.rmtree(store)
flintd = open(os.path.join(run, "flintd-path.txt")).read().strip()
subprocess.check_call([flintd, "init", "--store=" + store])
log = open(os.path.join(run, "flintd.log"), "ab")
proc = subprocess.Popen(
    [flintd, "serve", "--store=" + store,
     "--listen=127.0.0.1:4750",
     "--auth-key=" + os.path.join(run, "flint-auth.key")],
    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4750), 0.2)
        s.close()
        up = True
        break
    except OSError:
        if proc.poll() is not None:
            break
        time.sleep(0.1)
if not up:
    sys.exit("flintd did not relaunch for the next iteration")
print("run-07: iteration reset complete, flintd relaunched pid=%d" % proc.pid)
PY
