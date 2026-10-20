# live-godiff-loop.spec -- M107e (#2322) class-B: THE CAPSTONE PROOF. A real
# fleet program (GODIFF.ELF, unified context diff) is developed ENTIRELY in
# the guest on VZ: FLINT.ELF init, every source byte entered through GOEDIT
# editor sessions, GOBUILD.ELF compiles the guest's own toolchain output,
# the guest-built product runs and diffs, and in-guest FLINT add/diff/
# commit/push lands the history on flintd.
#
# Run 09 (M138c #2777): the guest-built GODIFF.ELF's `-i` viewer opens
# under the seat, an 's' chord toggles the side-by-side mode, and a
# scanout probe pins the aligned-hunk signature: on every painted row
# that carries both change colors, the red removal cell sits strictly
# left of the green addition cell. The host then verifies the
# pushed stream byte-for-byte, `flint verify --all`, and pins every
# Change's author key to the guest's agent-sign key.
#
# ---- how source enters the workspace (the card's definition, verbatim) ----
# "After `flint init`, every source byte entered the workspace through an
#  in-guest editor session (GOEDIT, typed by a human or driven by runner
#  --input-string/--script or AGENTD). There must be no host copy into the
#  workspace dir."
#
# The driver here is --script + GOEDIT's own paste, riding the M108b
# clipboard lane: a setup-spawned feeder (clipfeed.py, written into
# $RUN_DIR) publishes SIGNED VHI1 CLIP_IN records into the share's
# HOSTINT/ lane directory — the same signed-record path live-host-clipboard
# .spec's refusal plants exercise, keyed to the session epoch the seat
# prints (`gotabwm: hostint armed epoch=`). The seat applies at most one
# record per composite tick, so the kernel clipboard cycles chunk-by-chunk
# while the --input-chords' ctrl-v tokens paste each through GOEDIT's real
# paste op (the `-u0` exec carries cap_clipboard — the M97g gate — the same
# way go-edit.spec's clipboard leg drove it) and ctrl-s saves.
#
# Determinism: pastes pace the lane, not vice versa. The feeder emits the
# NEXT chunk only after the previous chunk's `goedit: paste` receipt, and
# the seat polls the lane on every dispatched key event (the M107e
# consumeSeatEvent hook — a host clipboard item now lands within the
# keystroke that asked for it instead of waiting up to a whole composite
# tick), so each filler chord between two ctrl-v's is also a lane poll
# that applies the just-emitted record before the next paste reads it.
# The per-run asserts count `clip-in seq=` == `paste n=` == chunk count
# AND the saved file byte-compares equal to the canonical source, so a
# raced paste fails the run instead of silently splicing the wrong chunk.
#
# Chunks are ~500 B — GOEDIT's clipRead was widened to vsys.ClipboardGetInto
# (this card) so a paste can carry the kernel clipboard's full 512 bytes;
# without it the 256-byte vsys staging bound would silently truncate every
# M108b host paste.
#
# exec-order: multi-exec, marker-sequenced. Each stage's program is exec'd
# only after the previous stage's own serial marker (`gotabwm: hostint
# armed`, `goedit: saved`, `flint: commit ok`) proves the prior step
# finished — the async exec contract is never raced. Gosh `source` scripts
# keep multi-command steps sequential inside the guest (each external run
# waits, the go-flint pattern).
#
# HOST PREREQS:
#   bash tools/go/build-goedit.sh   -> .build/go/GOEDIT.ELF (with the
#       ClipboardGetInto read — the 512 B paste)
#   bash tools/go/build-gotabwm.sh  -> .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh     -> .build/go/GOSH.ELF
#   bash tools/go/build-flint.sh    -> .build/go/FLINT.ELF
#   bash tools/go/build-gobuild.sh  -> .build/go/GOBUILD.ELF
#   bash tools/go/build-gotool.sh   -> .build/go/GOCMD{COMPILE,LINK}.ELF
#   bash tools/go/stage-selfhost.sh -> .build/go/selfhost/{GOIMPORT.CFG,
#                                      GOPKGS.TXT,GPKG_*.a}
#   ../flint-server + ../flint-client checkouts (see live-flint-loop.spec)

vgate_name live-godiff-loop "M107e #2322: capstone — app authored+built+committed entirely in-guest (GOEDIT paste authoring, GOBUILD, FLINT push)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# ---- monitor scripts ----------------------------------------------------------
vgate_file script-init-seat.txt <<'EOF'
vf mkdir GODIFF
exec FLINT.ELF init --name=godiff --src=/host/GODIFF
exec GOTABWM.ELF
EOF

vgate_file script-seat.txt <<'EOF'
exec GOTABWM.ELF
EOF

vgate_file script-open-diff.txt <<'EOF'
exec -u0 GOEDIT.ELF /host/GODIFF/diff.go
EOF

vgate_file script-open-main.txt <<'EOF'
exec -u0 GOEDIT.ELF /host/GODIFF/main.go
EOF

vgate_file script-open-test.txt <<'EOF'
exec -u0 GOEDIT.ELF /host/GODIFF/diff_test.go
EOF

vgate_file script-commit1.txt <<'EOF'
exec GOSH.ELF -c "source /host/COMMIT1.SH"
EOF

vgate_file script-commit2.txt <<'EOF'
exec GOSH.ELF -c "source /host/COMMIT2.SH"
EOF

vgate_file script-buildrun.txt <<'EOF'
exec GOSH.ELF -c "source /host/BUILD.SH"
EOF

vgate_file script-side.txt <<'EOF'
exec GODIFF.ELF -i /host/DA.TXT /host/DB.TXT
EOF

vgate_file script-push.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
vf ls
vf ls FLINT
vf ls FLINT/streams
exec GOSH.ELF -c "source /host/PUSH.SH"
EOF

# ---- setup --------------------------------------------------------------------
vgate_setup_python <<'PY'
import hashlib, hmac, os, shutil, struct, subprocess, socket, sys, time

run = os.environ["RUN_DIR"]
repo = os.getcwd()
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

# 1. Guest binaries + the guest build toolchain + the staged archives.
for name in ("GOTABWM.ELF", "GOEDIT.ELF", "GOSH.ELF", "FLINT.ELF",
             "GOBUILD.ELF", "GOCMDCOMPILE.ELF", "GOCMDLINK.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first")
    shutil.copy(src, os.path.join(share, name))
selfhost = os.path.join(".build", "go", "selfhost")
if not os.path.isfile(os.path.join(selfhost, "GOIMPORT.CFG")):
    sys.exit("selfhost staging missing - run: bash tools/go/stage-selfhost.sh")
for name in os.listdir(selfhost):
    if (name.startswith("GPKG_") and name.endswith(".a")) or \
       name in ("GOIMPORT.CFG", "GOPKGS.TXT"):
        shutil.copy(os.path.join(selfhost, name), os.path.join(share, name))

# 2. wm=none so the seat is exec'd explicitly on script (marker-timed).
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")

# 3. Credentials: the guest's agent-sign seed (RFC 8032 TEST 1 — the same
#    vector go-flint pins), the M108b lane key, and the push auth key.
sig_dir = os.path.join("user", "go", "flint", "testdata", "sig")
SEED_HEX = open(os.path.join(sig_dir, "seed.hex")).read().strip()
LANE_KEY = "clipkey0" * 8
AUTH_KEY_HEX = "ab" * 32
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n"
    "agent-sign\t1000\t" + SEED_HEX + "\tFLINT.ELF\n"
    "host-int\t1000\t" + LANE_KEY + "\tGOTABWM.ELF\n"
    "flint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nGOTABWM.ELF\t644\t0\t-\nGOEDIT.ELF\t644\t0\t-\n")

# 4. Chunk the canonical source for the paste lane. GOEDIT's paste op is
#    bounded by the kernel clipboard (512 B) — chunks stay under 500 B.
def chunk_bytes(data, dst_dir, stem, base, maxb=500):
    out, cur = [], b""
    for line in data.splitlines(keepends=True):
        if len(cur) + len(line) > maxb and cur:
            out.append(cur); cur = b""
        cur += line
    if cur:
        out.append(cur)
    paths = []
    for i, c in enumerate(out):
        p = os.path.join(dst_dir, "%s-%02d" % (stem, base + i))
        open(p, "wb").write(c)
        paths.append(p)
    return paths

chunk_root = os.path.join(run, "chunks")
os.makedirs(chunk_root, exist_ok=True)
godiff = os.path.join(repo, "user", "go", "godiff")
plans = {
    "diff": chunk_bytes(open(godiff + "/diff.go", "rb").read(), chunk_root, "diff", 0),
    "main": chunk_bytes(open(godiff + "/main.go", "rb").read(), chunk_root, "main", 0),
}

# The test file is split at the '\nfunc TestCliArgs' boundary: run 03
# authors everything before it (valid Go — the file's own last test is the
# append), and run 05's fixup edit appends the rest. Both halves chunk
# independently so the saved file is still byte-exact after run 05.
test_src = open(godiff + "/diff_test.go", "rb").read()
off = test_src.find(b"\nfunc TestCliArgs")
if off < 0:
    sys.exit("diff_test.go lost the '\\nfunc TestCliArgs' append boundary")
test_head = chunk_bytes(test_src[:off], chunk_root, "test", 0)
test_tail = chunk_bytes(test_src[off:], chunk_root, "tail", 0)

feeds = {
    "01": plans["diff"],
    "02": plans["main"],
    "03": test_head,
    "05": test_tail,
}
os.makedirs(os.path.join(run, "feeds"), exist_ok=True)
for tag, lst in feeds.items():
    with open(os.path.join(run, "feeds", tag + ".list"), "w") as f:
        f.write("\n".join(lst) + "\n")

# 5. The guest-side journey scripts (gosh `source` keeps each line's
#    external run sequential).
open(os.path.join(share, "COMMIT1.SH"), "w").write(
    "FLINT.ELF add /host/GODIFF\n"
    "FLINT.ELF commit -m \"godiff: unified context diff\"\n"
    "echo COMMIT1-DONE\n")
open(os.path.join(share, "COMMIT2.SH"), "w").write(
    "FLINT.ELF add /host/GODIFF\n"
    "FLINT.ELF commit -m \"godiff: eol-edge regression test\"\n"
    "echo COMMIT2-DONE\n")
open(os.path.join(share, "BUILD.SH"), "w").write(
    "GOBUILD.ELF /host/GODIFF -o /host/GODIFF.ELF\n"
    # go-flint's sequential-exec spacing: a just-built image exec'd on the
    # very next line can lose the reclamation/FUSE-lookup race (observed:
    # `gosh: GODIFF.ELF: not found` right after `build OK`).
    "sleep 1\n"
    "GODIFF.ELF /host/DA.TXT /host/DB.TXT\n"
    "echo BUILD-RUN-DONE\n")
open(os.path.join(share, "PUSH.SH"), "w").write(
    "FLINT.ELF status\n"
    "FLINT.ELF log\n"
    "FLINT.ELF push --remote=10.0.0.2:4748 --stream=main\n"
    "sleep 1\n"
    "FLINT.ELF push\n"
    "echo PUSH-DONE\n")

# 6. Product fixtures: the in-guest-built binary diffs these.
open(os.path.join(share, "DA.TXT"), "w").write(
    "alpha\nbeta\ngamma\ndelta\n")
open(os.path.join(share, "DB.TXT"), "w").write(
    "alpha\nBETA\ngamma\ndelta\n")

# 7. clipfeed.py — the host-side chunk publisher. For each authoring run it
#    reads that run's feed manifest, waits for `goedit: present`, learns
#    the lane epoch from the seat's own armed marker, then emits signed
#    CLIP_IN records — one after each `goedit: paste` lands — so the seat
#    applies them in order and the kernel clipboard carries the next chunk
#    when the next ctrl-v arrives. Publish is atomic (tmp + rename); the
#    records are real VHI1 traffic the seat MAC/epoch/seq-checks.
feeder = r'''import glob, hashlib, hmac, os, re, struct, sys, time

run_dir, share, key = sys.argv[1], sys.argv[2], sys.argv[3].encode()
lane = os.path.join(share, "HOSTINT")

def rec(tag, flags, seq, epoch, payload):
    hdr = b"VHI1" + bytes([tag, flags, 0, 0]) + struct.pack(
        "<IIH", seq, epoch, len(payload))
    body = hdr + payload
    return body + hmac.new(key, body, hashlib.sha256).digest()

def emit(seq, epoch, payload):
    name = "CLIPIN-%08x" % seq
    tmp = os.path.join(lane, "~" + name)
    with open(tmp, "wb") as f:
        f.write(rec(2, 0, seq, epoch, payload))
    os.replace(tmp, os.path.join(lane, name))

def tail(path):
    try:
        return open(path, errors="replace").read()
    except OSError:
        return ""

seen = set()
while True:
    logs = sorted(glob.glob(os.path.join(run_dir, "vm-serial-*.log")),
                  key=os.path.getmtime)
    for lg in logs:
        tag = os.path.basename(lg)[len("vm-serial-"):-len(".log")]
        man = os.path.join(run_dir, "feeds", tag + ".list")
        if lg in seen or not os.path.isfile(man):
            continue
        seen.add(lg)
        chunks = [open(p.strip(), "rb").read()
                  for p in open(man) if p.strip()]
        emitted = 0
        deadline = time.time() + 600
        while time.time() < deadline:
            txt = tail(lg)
            m = re.search(r"gotabwm: hostint armed epoch=(\d+)", txt)
            if m is None:
                time.sleep(0.15)
                continue
            epoch = int(m.group(1))
            if emitted == 0 and "goedit: present" in txt:
                os.makedirs(lane, exist_ok=True)
                emit(1, epoch, chunks[0])
                emitted = 1
            elif 0 < emitted < len(chunks) and \
                    txt.count("goedit: paste") >= emitted:
                emit(emitted + 1, epoch, chunks[emitted])
                emitted += 1
            if emitted == len(chunks) and "goedit: saved" in txt:
                break
            if "goedit: saved" in txt:
                break
            time.sleep(0.15)
    time.sleep(0.3)
'''
feed_path = os.path.join(run, "clipfeed.py")
open(feed_path, "w").write(feeder)
feed_log = open(os.path.join(run, "clipfeed.log"), "wb")
feed_proc = subprocess.Popen(
    [sys.executable, feed_path, run, share, LANE_KEY],
    stdout=feed_log, stderr=subprocess.STDOUT, start_new_session=True)

# 8. Host flintd on an empty store + the host client for verify --all.
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
flint_host = find_sibling("FLINT_CLIENT_DIR", "flint-client",
                          os.path.join("zig-out", "bin", "flint"))
open(os.path.join(run, "flint-client-path.txt"), "w").write(flint_host + "\n")
flintd_store = os.path.join(run, "loopd-store")
subprocess.check_call([flintd, "init", "--store=" + flintd_store])
auth_key_file = os.path.join(run, "flint-auth.key")
open(auth_key_file, "w").write(AUTH_KEY_HEX + "\n")
subprocess.run(["sh", "-c", "lsof -ti tcp:4748 | xargs kill -9"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.2)
flintd_log = open(os.path.join(run, "flintd.log"), "wb")
flintd_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store,
     "--listen=127.0.0.1:4748", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True)
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4748), 0.2)
        s.close()
        break
    except OSError:
        if flintd_proc.poll() is not None:
            sys.exit("flintd did not come up on 127.0.0.1:4748")
        time.sleep(0.1)

n_chunks = sum(len(v) for v in feeds.values())
print("godiff-loop staged: %d chunks across %d authoring runs, feeder "
      "pid=%d, flintd up" % (n_chunks, len(feeds), feed_proc.pid))
PY

# ---- 01: flint init + GOEDIT authors diff.go (18 chunks, ~500 B each) ------
# init runs before the seat so the workspace exists when the editor opens
# it; the init exec and seat exec are independent tasks.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --script '$RUN_DIR/script-init-seat.txt' \
    --script2 '$RUN_DIR/script-open-diff.txt' --script2-after 'gotabwm: hostint armed' \
    --host-clipboard --host-pasteboard 'virelai-gate-godiff' \
    --via-virtio \
    --input-chords 'ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,ctrl-s' \
    --input-chords-after 'gotabwm: hostint clip-in seq=1' \
    --script-expect 'goedit: saved /host/GODIFF/diff.go' --script-expect-tail 4 \
    --timeout 300

vgate_assert 01 serial-contains 'flint: init ok ws=godiff stream=main'
vgate_assert 01 serial-contains 'goedit: present'
vgate_assert 01 serial-count 'gotabwm: hostint clip-in seq=' 18
vgate_assert 01 serial-count 'goedit: paste n=' 18
vgate_assert 01 serial-contains 'goedit: saved /host/GODIFF/diff.go'
vgate_assert 01 serial-absent '[EXC] parking:'
# The workspace file must be byte-identical to the canonical source — the
# proof every byte went lane -> clipboard -> GOEDIT paste -> save.
vgate_assert 01 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
got = open(os.path.join(share, "GODIFF", "diff.go"), "rb").read()
want = open(os.path.join("user", "go", "godiff", "diff.go"), "rb").read()
if got != want:
    sys.exit("FAIL: /host/GODIFF/diff.go (%d B) != canonical diff.go (%d B)"
             % (len(got), len(want)))
print("run-01: diff.go authored byte-identical through GOEDIT pastes")
PY

# ---- 02: GOEDIT authors main.go (13 chunks) ----------------------------------
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-open-main.txt' --script2-after 'gotabwm: hostint armed' \
    --host-clipboard --host-pasteboard 'virelai-gate-godiff' \
    --via-virtio \
    --input-chords 'ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,ctrl-s' \
    --input-chords-after 'gotabwm: hostint clip-in seq=1' \
    --script-expect 'goedit: saved /host/GODIFF/main.go' --script-expect-tail 4 \
    --timeout 240

vgate_assert 02 serial-count 'gotabwm: hostint clip-in seq=' 13
vgate_assert 02 serial-count 'goedit: paste n=' 13
vgate_assert 02 serial-contains 'goedit: saved /host/GODIFF/main.go'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
got = open(os.path.join(share, "GODIFF", "main.go"), "rb").read()
want = open(os.path.join("user", "go", "godiff", "main.go"), "rb").read()
if got != want:
    sys.exit("FAIL: /host/GODIFF/main.go (%d B) != canonical (%d B)"
             % (len(got), len(want)))
print("run-02: main.go authored byte-identical")
PY

# ---- 03: GOEDIT authors diff_test.go minus the last test (5 chunks) --------
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-open-test.txt' --script2-after 'gotabwm: hostint armed' \
    --host-clipboard --host-pasteboard 'virelai-gate-godiff' \
    --via-virtio \
    --input-chords 'ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,ctrl-s' \
    --input-chords-after 'gotabwm: hostint clip-in seq=1' \
    --script-expect 'goedit: saved /host/GODIFF/diff_test.go' --script-expect-tail 4 \
    --timeout 240

vgate_assert 03 serial-count 'gotabwm: hostint clip-in seq=' 5
vgate_assert 03 serial-count 'goedit: paste n=' 5
vgate_assert 03 serial-contains 'goedit: saved /host/GODIFF/diff_test.go'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
# Gate hygiene: every boot in this spec is killed mid-session, so the
# advisory write leases (M81d) GOEDIT takes at open are never released —
# and the next boot's pid space restarts from scratch while the guest
# epoch barely advances between boots, so a previous run's record reads
# live forever (observed: run 05's `goedit: save error ... -11` from a
# lease run 03's killed VM left on /host/GODIFF/diff_test.go). A real
# user's crashed-editor record expires in 30 s; here the lease root is
# cleared between boots, which is exactly that expiry.
leases = os.path.join(share, "LEASES")
if os.path.isdir(leases):
    shutil.rmtree(leases)
print("run-03: cleared leftover LEASES state for the next boot")
PY

# ---- 04: in-guest add + commit (Change 1) ------------------------------------
# Seat-less: GOSH sources the two-step journey so add finishes before
# commit starts.
vgate_run 04 -- \
    --script '$RUN_DIR/script-commit1.txt' \
    --script-expect 'COMMIT1-DONE' --script-expect-tail 4 --timeout 180

vgate_assert 04 serial-contains 'flint: add files=3 new='
vgate_assert 04 serial-contains 'flint: commit ok id='
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'

# ---- 05: GOEDIT appends the test tail (the fixup edit, 6 chunks) -------------
vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-open-test.txt' --script2-after 'gotabwm: hostint armed' \
    --host-clipboard --host-pasteboard 'virelai-gate-godiff' \
    --via-virtio \
    --input-chords 'ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,f5,f5,ctrl-v,f5,f5,ctrl-s' \
    --input-chords-after 'gotabwm: hostint clip-in seq=1' \
    --script-expect 'goedit: saved /host/GODIFF/diff_test.go' --script-expect-tail 4 \
    --timeout 240

vgate_assert 05 serial-count 'goedit: paste n=' 6
vgate_assert 05 serial-contains 'goedit: saved /host/GODIFF/diff_test.go'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
got = open(os.path.join(share, "GODIFF", "diff_test.go"), "rb").read()
want = open(os.path.join("user", "go", "godiff", "diff_test.go"), "rb").read()
if got != want:
    sys.exit("FAIL: /host/GODIFF/diff_test.go (%d B) != canonical (%d B)"
             % (len(got), len(want)))
print("run-05: diff_test.go now byte-identical after the append edit")
PY

# ---- 06: GOBUILD.ELF builds the authored tree; the product diffs ------------
# --virtio-fs for the link: the in-guest GOCMDLINK reads ~12 MiB of GPKG
# archives; a mid-stream read fault (`read /host/GPKG_runtime.a: bad
# address`, ~4.4 MiB in) was observed on the pure cv channel, while the
# same link under virtio-fs links clean. live-gobuild covers cvc builds.
vgate_run 06 -- \
    --script '$RUN_DIR/script-buildrun.txt' \
    --virtio-fs '$RUN_DIR/share' \
    --script-expect 'BUILD-RUN-DONE' --script-expect-tail 5 --timeout 600

vgate_assert 06 serial-contains 'gobuild: build OK'
vgate_assert 06 serial-contains 'godiff: files differ hunks=1'
vgate_assert 06 serial-contains 'procs GODIFF.ELF exited status=1'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
# The product ELF exists and was written by the guest build — a NEW share
# file the build run created, not anything the host staged.
vgate_assert 06 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
p = os.path.join(share, "GODIFF.ELF")
if not os.path.isfile(p):
    sys.exit("FAIL: /host/GODIFF.ELF missing - the guest build did not write it")
sz = os.path.getsize(p)
if sz < 500000:
    sys.exit("FAIL: /host/GODIFF.ELF is only %d bytes" % sz)
print("run-06: guest-built GODIFF.ELF is %d bytes" % sz)
PY

# ---- 07: in-guest add + commit (Change 2) ------------------------------------
vgate_run 07 -- \
    --script '$RUN_DIR/script-commit2.txt' \
    --script-expect 'COMMIT2-DONE' --script-expect-tail 4 --timeout 180

vgate_assert 07 serial-contains 'flint: commit ok id='
vgate_assert 07 serial-absent '[EXC] parking:'

# ---- 08: push to flintd; host verifies the all-guest history -----------------
# This leg mounts --virtio-fs on the armed share because FLINT's store index
# lists streams/ for name->record resolution: the slot-79 paged listing is
# virtiofs-only (virtio_file.metadata_backend refuses the cv channel), and
# the v1 DirList fallback truncates names at 31 bytes, which hides
# `streams/<uuid>.json` (41 chars) -> `flint: refuse stream_missing`. Earlier
# legs stay pure cv like every seat spec (the FUSE-session/exec-lookup race
# documented in go-shell-polish.spec); only push needs name-faithful listing.
vgate_run 08 -- \
    --net '$RUN_DIR/cap08.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4748:relay --net-tcp-respond-relay 127.0.0.1:4748 \
    --script '$RUN_DIR/script-push.txt' \
    --virtio-fs '$RUN_DIR/share' \
    --script-expect 'PUSH-DONE' --script-expect-tail 4 --timeout 300

vgate_assert 08 serial-contains 'flint: push ok stream=main changes=2'
vgate_assert 08 serial-contains 'flint: push up to date'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 python <<'PY'
import glob, json, os, subprocess, sys

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")

# The guest stream log and the server's copy must be byte-identical.
local_logs = glob.glob(os.path.join(share, "FLINT", "streams", "*.jsonl"))
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

# Every Change must be authored by the guest's agent-sign key — the RFC
# 8032 TEST 1 public key paired to the seed SECRETS.TXT bound to FLINT.ELF.
GUEST_KEY = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
for i, ln in enumerate(lines):
    ch = json.loads(ln)
    if ch.get("author") != GUEST_KEY:
        sys.exit("Change %d author %r is not the guest agent-sign key"
                 % (i, ch.get("author")))

flint = open(os.path.join(run, "flint-client-path.txt")).read().strip()
res = subprocess.run(
    [flint, "--store", os.path.join(run, "loopd-store"), "verify", "--all"],
    capture_output=True, text=True,
)
if res.returncode != 0:
    sys.exit("host flint verify --all rc=%d: %s%s" % (res.returncode, res.stdout, res.stderr))
verified = [l for l in res.stdout.splitlines() if l.endswith("sig: verified")]
if len(verified) != 2:
    sys.exit("expected 2 'sig: verified' lines, got %r" % res.stdout)
rec = json.load(open(os.path.join(run, "loopd-store", "streams", stream_id + ".json")))
if rec.get("head") != json.loads(lines[-1]).get("id"):
    sys.exit("server stream head %r != last pushed change %r"
             % (rec.get("head"), lines[-1]))
print("run-08: 2 guest-signed Changes byte-verbatim, all authors = guest "
      "agent-sign key, host verify sig:verified x2, head rolled")
PY

# ---- 09: M138c (#2777) — `-i` viewer + 's' toggles side-by-side -----------
# The product of run 06 is already on the share (state persists across
# boots): the seat comes up first, then the app opens its window, an 's'
# chord flips unified -> side-by-side, and the post-repaint scanout is the
# pixel proof of aligned hunks — red cells strictly left of green cells on
# every row that carries both.
vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --input --via-virtio \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-side.txt' --script2-after 'gotabwm: hostint armed' \
    --input-chords 's' \
    --input-chords-after 'godiff: ready' \
    --screenshot-after 'godiff: repainted' \
    --script-expect 'godiff: repainted' --script-expect-tail 4 --timeout 300

vgate_assert 09 serial-contains 'exec: loaded GODIFF.ELF'
vgate_assert 09 serial-contains 'godiff: open id='
vgate_assert 09 serial-contains 'godiff: attached'
vgate_assert 09 serial-contains 'godiff: painted'
vgate_assert 09 serial-contains 'godiff: ready'
vgate_assert 09 serial-contains 'godiff: key s'
vgate_assert 09 serial-contains 'godiff: view side-by-side'
vgate_assert 09 serial-contains 'godiff: repainted'
vgate_assert 09 serial-absent 'godiff: error'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'
# The pixel probe: side-by-side paints each change row as red-removal on
# the left cell and green-addition on the right cell, so every scanline
# carrying BOTH colors must show all its red strictly left of all its
# green; the unified view this run toggled AWAY from never produces a
# two-color row. At least one qualifying row must exist (the -beta/+BETA
# pair in DA.TXT/DB.TXT).
vgate_assert 09 snapshot 'screen-09-after' <<'PY'
import struct, sys, zlib

d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG scanout"
pos = 8
idat = b""
w = h = ct = 0
while pos < len(d):
    n, typ = struct.unpack(">I4s", d[pos:pos + 8])
    chunk = d[pos + 8:pos + 8 + n]
    if typ == b"IHDR":
        w, h, depth, ct = struct.unpack(">IIBB", chunk[:10])
        assert depth == 8, "unexpected PNG depth"
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + n
assert (w, h) == (2560, 1440), "wanted 2560x1440 scanout, got %dx%d" % (w, h)
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
i = 0
for _ in range(h):
    filt = raw[i]
    i += 1
    row = bytearray(raw[i:i + stride])
    i += stride
    if filt == 1:
        for x in range(bpp, stride):
            row[x] = (row[x] + row[x - bpp]) & 0xff
    elif filt == 2:
        for x in range(stride):
            row[x] = (row[x] + prev[x]) & 0xff
    elif filt == 3:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            row[x] = (row[x] + ((left + up) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            row[x] = (row[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)) & 0xff
    out += row
    prev = row

def is_red(r, g, b):
    return r > 170 and g < 110 and b < 110

def is_green(r, g, b):
    return g > 150 and r < 120 and b < 120

paired = 0
red_total = green_total = 0
for y in range(h):
    rmin = rmax = gmin = gmax = -1
    for x in range(w):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if is_red(r, g, b):
            red_total += 1
            if rmin < 0:
                rmin = x
            rmax = x
        if is_green(r, g, b):
            green_total += 1
            if gmin < 0:
                gmin = x
            gmax = x
    if rmin >= 0 and gmin >= 0:
        if rmax >= gmin:
            sys.exit("row %d: red x<=%d overlaps green x>=%d - not side-by-side"
                     % (y, rmax, gmin))
        paired += 1
print("godiff side-by-side scanout: paired rows=%d red=%d green=%d"
      % (paired, red_total, green_total))
assert paired >= 1, "no row carries red-left-of-green - unified view leaked?"
assert red_total >= 20 and green_total >= 20, "change colors absent"
PY
