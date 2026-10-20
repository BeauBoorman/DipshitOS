# live-dev-loop.spec -- M107f (issue #2323) + M138d (issue #2778) class-B:
# the STANDING dev-loop acceptance gate, K=3 via vgate_repeat. One scripted
# pass per boot over the whole in-guest story, every chain marker observed
# on all three iterations: `flint init` on a staged base program -> add +
# commit -> a heredoc script scaffolds main.go (M138a gosh `<<`) ->
# GOBUILD.ELF fails with a positioned `gobuild: diag` (ERRORS.TXT, checked
# host-side) -> GOEDIT opens the file, ctrl-n jumps the diagnostic to its
# line:col, ctrl-b checks the bracket match (plus the `match none`
# refusal), and ctrl-s save prints the format named refusal and publishes
# -> a scripted fix -> rebuild -> the guest-built product runs -> `flint
# status`/`diff` review -> second commit -> `flint blame` names the new
# change -> `flint push` over the hermetic --net relay to host flintd ->
# python assert: stream byte-verbatim, `flint verify --all`, every Change
# authored by the guest's agent-sign key. The heavyweight capstone (every
# source byte through a GOEDIT paste lane) is live-godiff-loop; this is the
# cheap standing form — scripted edits, no seat, three boots per iteration.
#
# REPEAT SEMANTICS (M138d): the armed share persists across iterations, so
# the spec keeps ONE workspace on ONE stream and replays real history.
# J1 restores the base sources, then init lands 'init ok' on iteration 1
# and 'flint: refuse ws_exists' later (the DEVLOOP-INIT-FRESH/-EXISTS
# branches) — the base restore makes each iteration's first commit a real
# revert-to-base change, so run 03's push APPENDS two changes per
# iteration to the server's stream 'main' (a second `create` of stream
# "main" is the stream_exists refusal a fresh-store model hits). The
# run-03 python pins the stream's even growing Change count, the head,
# and blame's attribution of AnswerPlusOne to that head.
#
# HOST PREREQS:
#   bash tools/go/build-gosh.sh    -> .build/go/GOSH.ELF
#   bash tools/go/build-flint.sh   -> .build/go/FLINT.ELF
#   bash tools/go/build-gobuild.sh -> .build/go/GOBUILD.ELF
#   bash tools/go/build-gotool.sh  -> .build/go/GOCMD{COMPILE,LINK}.ELF
#   bash tools/go/build-goedit.sh  -> .build/go/GOEDIT.ELF
#   bash tools/go/stage-selfhost.sh -> .build/go/selfhost/{GOIMPORT.CFG,
#                                      GOPKGS.TXT,GPKG_*.a}
#   ../flint-server + ../flint-client checkouts (see live-flint-loop.spec)
# exec-order: assert-proven -- run 01 ends on `goedit: saved ` (a marker
# only the editor prints after the last chord), run 02 on the J2-DONE echo
# a sequential gosh `source` reaches only after the staged-set review, run
# 03 on `flint: push up to date` after the second commit + both pushes.
# Transports: run 01 rides the armed cv channel like every console gate;
# run 02 mounts --virtio-fs because the link's ~15 MiB of archive reads
# faulted once on pure cv (live-godiff-loop's note), and run 03 needs it
# outright — FLINT's push-time streams/ listing is virtiofs-only (the
# v1 DirList fallback truncates the 41-char stream names). cv writes are
# synchronous host IO (VFWire FileHandle.write), so run 01's cv-side
# edits are visible to run 02's virtio-fs reads. wm=none keeps the seat's
# EL0 slots for the toolchain children (live-goedit-diags run 02's wall).

vgate_name live-dev-loop "issue #2323 M107f + #2778 M138d: standing dev-loop gate — init, heredoc scaffold, GOEDIT diag-jump/bracket/save, fix, build, run, commit, blame, push, host-verified — K=3"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

# ---- monitor scripts ----------------------------------------------------------
# GOBUILD is always exec'd BY THE MONITOR (script2/script3 legs gated on the
# prior stage's marker) — never as a gosh child. A Go process costs ~4 tasks
# at the gate VM's GOMAXPROCS, so monitor -> gosh -> gobuild -> compile child
# rides the 16-task cap and the compile child dies mid-boot with
# `newosproc: sys_thread create failed` (observed on this spec's first live
# run — the same wall live-goedit-diags run 02 measured). Monitor-exec'd
# gobuild keeps the tree shallow: live-gobuild drives seven children that way.
vgate_file script-01.txt <<'EOF'
exec GOSH.ELF -c "source /host/J1.SH"
EOF

vgate_file script-01b.txt <<'EOF'
exec GOBUILD.ELF /host/LOOP -o /host/LOOPAPP.ELF
EOF

# GOEDIT is the third stage, monitor-exec'd once the build's FAIL is on the
# wire (its ERRORS.TXT is what ctrl-n reads). It runs under the kernel's
# bare shim — wm=none, no seat — the go-edit run-13 shape, so the chords
# reach its window over --via-virtio without spending a seat's EL0 slots.
vgate_file script-01c.txt <<'EOF'
exec GOEDIT.ELF /host/LOOP/main.go
EOF

vgate_file script-02.txt <<'EOF'
exec GOSH.ELF -c "source /host/J2A.SH"
EOF

vgate_file script-02b.txt <<'EOF'
exec GOBUILD.ELF /host/LOOP -o /host/LOOPAPP.ELF
EOF

vgate_file script-02c.txt <<'EOF'
exec GOSH.ELF -c "source /host/J2B.SH"
EOF

vgate_file script-03.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/J3.SH"
EOF

# ---- setup --------------------------------------------------------------------
vgate_setup_python <<'PY'
import os, shutil, socket, subprocess, sys, time

run = os.environ["RUN_DIR"]
repo = os.getcwd()
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

# 1. Guest binaries + the real staged toolchain surface (the same
#    GOIMPORT.CFG + GOPKGS.TXT + GPKG_*.a layout live-gobuild/live-godiff-loop
#    stage — the driver's resolution is the shipped pkg-table policy, not a
#    spec-local mirror).
for name in ("GOSH.ELF", "FLINT.ELF", "GOBUILD.ELF", "GOEDIT.ELF",
             "GOCMDCOMPILE.ELF", "GOCMDLINK.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.isfile(src):
        sys.exit(name + " missing (expected " + src + ") - build it first "
                 "(see this spec's header)")
    shutil.copy(src, os.path.join(share, name))
selfhost = os.path.join(".build", "go", "selfhost")
if not os.path.isfile(os.path.join(selfhost, "GOIMPORT.CFG")):
    sys.exit("selfhost staging missing - run: bash tools/go/stage-selfhost.sh")
n_arch = 0
for name in os.listdir(selfhost):
    if (name.startswith("GPKG_") and name.endswith(".a")) or \
       name in ("GOIMPORT.CFG", "GOPKGS.TXT"):
        shutil.copy(os.path.join(selfhost, name), os.path.join(share, name))
        n_arch += 1

# 2. wm=none: no seat ever starts, so the build runs hold every EL0 slot
#    (live-goedit-diags run 02 measured seat + second compile child =
#    -ENOSPC).
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")

# 3. Credentials: the guest's agent-sign seed (RFC 8032 TEST 1 — the same
#    vector go-flint pins) and the FLINT-SYNC/1 push auth key.
sig_dir = os.path.join("user", "go", "flint", "testdata", "sig")
SEED_HEX = open(os.path.join(sig_dir, "seed.hex")).read().strip()
AUTH_KEY_HEX = "ab" * 32
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n"
    "agent-sign\t1000\t" + SEED_HEX + "\tFLINT.ELF\n"
    "flint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nFLINT.ELF\t644\t0\t-\n")

# 4. The workspace (what `flint init` tracks), the BASE/ copies J1 cats
#    back at the top of every iteration (the M138d repeat reset — a wiped
#    store alone is not enough; the sources must revert too or iteration
#    n's "base" commit would record the v2 edit), and the staged payload
#    J2A cats into place. The base is a working two-package program; the
#    heredoc in J1 scaffolds the v2 main.go itself — unformatted
#    (`func  main( )`) so the ctrl-s leg's format-vs-refusal both mean
#    something — calling a helper.AnswerPlusOne that does not exist yet
#    (a compile child reports the positioned diag — the diagnose leg is
#    the real toolchain, not a graph-stage refusal); helper-v2 adds it.
def w(rel, body):
    p = os.path.join(share, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(body)

# println emits one write per operand; a single string keeps the marker
# atomic on the console (observed: the two-operand form split "devloop:
# answer" from "43" around an `smp: steal` line). strconv also makes the
# program prove a STAGED std import resolves, not only local packages.
BASE_MAIN = ("package main\n"
  "import \"helper\"\n"
  "import \"strconv\"\n"
  "func main() {\n"
  "\tprintln(\"devloop: answer=\" + strconv.Itoa(helper.Answer()-1))\n"
  "}\n")
BASE_HELPER = ("package helper\n"
  "func Answer() int { return 42 }\n")
w("LOOP/main.go", BASE_MAIN)
w("LOOP/helper/helper.go", BASE_HELPER)
w("BASE/main.go", BASE_MAIN)
w("BASE/helper.go", BASE_HELPER)
w("STAGE/helper-v2.go",
  "package helper\n"
  "func Answer() int { return 42 }\n"
  "func AnswerPlusOne() int { return Answer() + 1 }\n")
# One stream named main accumulates the whole K=3 history (see J1.SH).


# 5. The guest-side journey scripts (gosh `source` keeps each line's
#    external run sequential — the go-flint pattern). cat/echo/sleep are
#    gosh builtins: they spend no exec slots.
#
#    Race armour, in two layers. (a) The gobuild legs are gated on
#    `procs GOSH.ELF exited status=0` — the kernel's own proc-exit line —
#    so the sourcing gosh's tasks are fully reaped before the toolchain
#    tree starts (the 16-task wall: monitor->gosh->gobuild->compile child
#    died `newosproc: sys_thread create failed` before this shape).
#    (b) `X || sleep 1 ; X`: gosh `sleep` is mis-scaled 100:1 today
#    (shlib/builtins.go bSleep — `sleep 1` parks ~100 s), so it only pays
#    off as a failure-path backoff: if the FUSE-session/exec-lookup race
#    drops the exec (`gosh: FLINT.ELF: not found` — observed twice under
#    virtiofs, on status->diff and commit->push), `||` buys the settle and
#    `;` retries; on the happy path the verb simply runs twice, which every
#    verb here tolerates (second init refuses ws_exists, second commit
#    refuses nothing_to_commit, second push prints "up to date", reads
#    duplicate) — serial-contains asserts are presence checks.
open(os.path.join(share, "J1.SH"), "w").write(
    # The M138d iteration reset: restore the base sources before init so
    # every boot's first commit is a real (revert-to-base) change. On
    # iteration 1 the cats rewrite the same bytes — a no-op write the
    # share absorbs either way.
    "cat /host/BASE/main.go > /host/LOOP/main.go\n"
    "cat /host/BASE/helper.go > /host/LOOP/helper/helper.go\n"
    # M138d repeat model: ONE workspace, ONE stream, real history. Iter1's
    # init lands 'init ok'; later iterations' 'flint: refuse ws_exists'
    # takes the resume branch — the workspace the arc tracks is already
    # there, and the base restore above turns each iteration's first
    # commit into a real (revert-to-base) change, never nothing_to_commit.
    # This is also what keeps run 03's push green: the single stream named
    # main APPENDS two changes per iteration on the server — a second
    # `create` of stream "main" is the stream_exists refusal the
    # fresh-store-per-iteration design hit.
    "FLINT.ELF init --name=devloop --src=/host/LOOP && echo DEVLOOP-INIT-FRESH || echo DEVLOOP-INIT-EXISTS\n"
    "FLINT.ELF add /host/LOOP\n"
    "FLINT.ELF commit -m \"devloop: base\"\n"
    # The M138a scaffold: a sourced heredoc (runSource collects the body
    # from the file's own next lines — the monitor's heredoc reader never
    # sees it) writes the v2 main.go — valid syntax, unformatted
    # (`func  main( )`), one undefined selector. `&&` so the marker
    # exists only when the write landed.
    "cat <<V2 > /host/LOOP/main.go && echo DEVLOOP-EDIT\n"
    "package main\n"
    "import \"helper\"\n"
    "import \"strconv\"\n"
    "func  main( ) {\n"
    "\tprintln(\"devloop: answer=\" + strconv.Itoa(helper.AnswerPlusOne()))\n"
    "}\n"
    "V2\n")
open(os.path.join(share, "J2A.SH"), "w").write(
    "cat /host/STAGE/helper-v2.go > /host/LOOP/helper/helper.go && echo DEVLOOP-FIXED\n")
open(os.path.join(share, "J2B.SH"), "w").write(
    # gobuild is still reaping when the script3-after marker fires; the
    # settle tick also covers the FUSE lookup of the just-linked product
    # (go-shell-polish documented a fresh image losing that exec).
    "sleep 1\n"
    "LOOPAPP.ELF || sleep 1 ; LOOPAPP.ELF\n"
    # add first, then status/diff review the STAGED set (the live-flint-loop
    # ordering: staged ops do not exist until add writes STAGE.jsonl). The
    # commit lives in run 03: this script plus the commit is already at 5
    # sequential gosh children.
    "FLINT.ELF add /host/LOOP || sleep 1 ; FLINT.ELF add /host/LOOP\n"
    "FLINT.ELF status || sleep 1 ; FLINT.ELF status\n"
    "FLINT.ELF diff || sleep 1 ; FLINT.ELF diff\n"
    "echo J2-DONE\n")
open(os.path.join(share, "J3.SH"), "w").write(
    "FLINT.ELF commit -m \"devloop: AnswerPlusOne lands\" || sleep 1 ; FLINT.ELF commit -m \"devloop: AnswerPlusOne lands\"\n"
    # M138d: `flint blame` attributes each working-tree line through its
    # covering Atom to the newest touching Change — the AnswerPlusOne
    # decl's line must name the commit this boot just made (the run-03
    # python reads the id back off the stream head).
    "FLINT.ELF blame /host/LOOP/helper/helper.go || sleep 1 ; FLINT.ELF blame /host/LOOP/helper/helper.go\n"
    # Commit->push is the observed drop boundary; the push->push spacing is
    # also what flint-loop's relay socket teardown needs.
    "sleep 1\n"
    "FLINT.ELF push --remote=10.0.0.2:4748 --stream=main || sleep 1 ; FLINT.ELF push --remote=10.0.0.2:4748 --stream=main\n"
    "sleep 1\n"
    "FLINT.ELF push || sleep 1 ; FLINT.ELF push\n")

# 6. Stale products must not let a broken run go green: drop a previous
#    boot's build dir, product, and store if a rerun ever reuses the share.
for stale in ("LOOPAPP.ELF",):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
for stale_dir in ("LOOP/.BUILD", "FLINT"):
    p = os.path.join(share, stale_dir)
    if os.path.isdir(p):
        shutil.rmtree(p)

# 7. Host flintd on an EMPTY store (the push must `create` the stream) + the
#    host client for the post-run `flint verify --all` — the live-flint-loop
#    pattern verbatim, relay at 127.0.0.1:4748 <-> guest 10.0.0.2:4748.
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

flintd_store = os.path.join(run, "devloopd-store")
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

print("dev-loop staged: %d toolchain files, ws=LOOP, flintd up pid=%d"
      % (n_arch, flintd_proc.pid))
PY

# ---- 01: init -> base commit -> heredoc scaffold -> build fails -> GOEDIT ----
# The dev's first act after init is the base commit; the heredoc scaffold
# then breaks the build the way real work does — a selector that does not
# exist yet — and GOEDIT's session on the broken file is the M138d leg:
# ctrl-n loads the build's own ERRORS.TXT and jumps the first diagnostic
# to its line:col, ctrl-b round-trips the line-end `)` to its `(` and the
# `{`-less `home` answers `match none`, and ctrl-s answers the shipped
# build's named format refusal before publishing the buffer verbatim.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio \
    --script '$RUN_DIR/script-01.txt' \
    --script2 '$RUN_DIR/script-01b.txt' --script2-after 'procs GOSH.ELF exited status=0' \
    --script3 '$RUN_DIR/script-01c.txt' --script3-after 'gobuild: FAIL' \
    --input-chords 'ctrl-n,end,left,ctrl-b,ctrl-b,home,ctrl-b,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script-expect 'goedit: saved ' --script-expect-tail 4 --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# Iteration 1 prints 'flint: init ok ws=devloop stream=main' and takes the
# FRESH branch; later iterations hit 'flint: refuse ws_exists' and take
# EXISTS — 'DEVLOOP-INIT' is the marker both paths share. The ws is proven
# downstream either way (add sees its 2 files, the commit lands).
vgate_assert 01 serial-contains 'DEVLOOP-INIT'
vgate_assert 01 serial-contains 'flint: add files=2'
vgate_assert 01 serial-contains 'flint: commit ok id='
vgate_assert 01 serial-contains ' ops=2 parent='
vgate_assert 01 serial-contains 'DEVLOOP-EDIT'
# The diagnose leg: helper compiled clean, main's child failed, and the
# driver's positioned diag names the undefined selector.
vgate_assert 01 serial-contains 'gobuild: compile helper GOCMDCOMPILE.ELF status=0'
vgate_assert 01 serial-contains 'gobuild: compile main GOCMDCOMPILE.ELF status=2'
vgate_assert 01 serial-contains 'gobuild: diag /host/LOOP/main.go:5:'
vgate_assert 01 serial-contains 'undefined: helper.AnswerPlusOne'
vgate_assert 01 serial-contains 'gobuild: diag gobuild:0:0: compile main: GOCMDCOMPILE.ELF exited status 2'
vgate_assert 01 serial-contains 'gobuild: FAIL'
vgate_assert 01 serial-absent 'gobuild: build OK'
# The M138d editor leg on the just-failed build's own ERRORS.TXT: the list
# loads, ctrl-n jumps the first row to its line:col (the helper.AnswerPlusOne
# selector on line 5), the status stamp carries the M138b err= count, and
# the bracket chord round-trips `)`->`(`->`)` before `home` parks on a
# non-bracket for the named `match none`. Ctrl-S then takes the shipped
# build's named format refusal and still publishes — the python assert
# checks the landed bytes against whichever path the binary took.
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'goedit: read /host/LOOP/main.go n='
vgate_assert 01 serial-contains 'goedit: present'
vgate_assert 01 serial-contains 'goedit: errors n='
vgate_assert 01 serial-contains 'goedit: errors jump line=5 col='
vgate_assert 01 serial-contains 'goedit: status line=5/'
vgate_assert 01 serial-contains ' err=1/'
vgate_assert 01 serial-count 'goedit: match jump off=' 2
vgate_assert 01 serial-contains 'goedit: match none'
vgate_assert 01 serial-contains 'edit: format unavailable (go/format not guest-safe)'
vgate_assert 01 serial-contains 'goedit: saved /host/LOOP/main.go'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
vgate_assert 01 serial-absent 'cannot allocate memory'
vgate_assert 01 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
# The diagnostics artifact the diagnose step publishes (M107a's fixed path).
vgate_assert 01 share-contains 'LOOP/.BUILD/ERRORS.TXT' 'main.go:5:'
vgate_assert 01 share-contains 'LOOP/.BUILD/ERRORS.TXT' 'undefined: helper.AnswerPlusOne'

# The ctrl-s leg's landed bytes decide which path the save took and require
# the matching one (live-goedit-diags run 05's shape): the named refusal
# leaves the heredoc scaffold verbatim, a real go/format leaves canonical
# output — anything else fails. Either way run 02's fix+build is unmoved.
vgate_assert 01 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
share = os.environ["VG_SHARE"]
got = open(os.path.join(share, "LOOP", "main.go"), "rb").read()
seed = ("package main\nimport \"helper\"\nimport \"strconv\"\n"
        "func  main( ) {\n"
        "\tprintln(\"devloop: answer=\" + strconv.Itoa(helper.AnswerPlusOne()))\n"
        "}\n").encode()
if "edit: format unavailable" in ser:
    assert got == seed, "refusal path must publish verbatim: %r" % got
    print("format unavailable: verbatim scaffold verified (%d bytes)" % len(got))
else:
    assert "goedit: format n=" in ser, "no refusal and no format receipt — which path ran?"
    assert b"func main()" in got and got != seed, \
        "format path must publish gofmt output: %r" % got
    print("format-on-save verified: %d bytes" % len(got))
PY

# ---- 02: fix -> rebuild -> run -> staged-set review ---------------------------
vgate_run 02 -- \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script-02b.txt' --script2-after 'procs GOSH.ELF exited status=0' \
    --script3 '$RUN_DIR/script-02c.txt' --script3-after 'gobuild: build OK' \
    --virtio-fs '$RUN_DIR/share' \
    --script-expect 'J2-DONE' --script-expect-tail 4 --timeout 900

vgate_assert 02 serial-contains 'DEVLOOP-FIXED'
vgate_assert 02 serial-contains 'gobuild: compile helper GOCMDCOMPILE.ELF status=0'
vgate_assert 02 serial-contains 'gobuild: compile main GOCMDCOMPILE.ELF status=0'
vgate_assert 02 serial-contains 'gobuild: link GOCMDLINK.ELF status=0'
vgate_assert 02 serial-contains 'gobuild: build OK -> /host/LOOPAPP.ELF'
vgate_assert 02 serial-contains 'devloop: answer=43'
vgate_assert 02 serial-contains 'procs LOOPAPP.ELF exited status=0'
# The M107d review surface on the staged fix: the staged-set counts, and
# per-decl detail for the modified main.main + the fix's new decl. (The
# stream= field prints the id when the index lookup misses — cosmetic.)
vgate_assert 02 serial-contains 'flint: status ws=devloop stream='
vgate_assert 02 serial-contains ' atoms=3 staged=2'
vgate_assert 02 serial-contains 'flint: diff modify main.go main.main'
vgate_assert 02 serial-contains 'flint: diff add helper/helper.go helper.AnswerPlusOne'
vgate_assert 02 serial-contains 'flint: add files=2 new=1 modified=1 deleted=0 unchanged=1'
vgate_assert 02 serial-absent 'gobuild: FAIL'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'cannot allocate memory'
vgate_assert 02 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
# Host-side: the product exists and is a fresh guest-built ELF, the clean
# build's ERRORS.TXT is empty, and both fixed sources are what the cats wrote.
vgate_assert 02 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
p = os.path.join(share, "LOOPAPP.ELF")
if not os.path.isfile(p):
    sys.exit("FAIL: /host/LOOPAPP.ELF missing - the guest build did not write it")
sz = os.path.getsize(p)
if sz < 500000:
    sys.exit("FAIL: /host/LOOPAPP.ELF is only %d bytes" % sz)
err = os.path.join(share, "LOOP", ".BUILD", "ERRORS.TXT")
if not os.path.exists(err):
    sys.exit("FAIL: no ERRORS.TXT after the clean build")
if os.path.getsize(err) != 0:
    sys.exit("FAIL: ERRORS.TXT nonempty after a clean build: " + open(err).read())
fixed = open(os.path.join(share, "LOOP", "helper", "helper.go")).read()
if "AnswerPlusOne" not in fixed:
    sys.exit("FAIL: the helper fix never landed on LOOP/helper/helper.go")
edited = open(os.path.join(share, "LOOP", "main.go")).read()
if "AnswerPlusOne" not in edited:
    sys.exit("FAIL: the run-01 edit never landed on LOOP/main.go")
print("run-02: guest-built LOOPAPP.ELF is %d bytes, ERRORS.TXT empty, "
      "fix published on the share" % sz)
PY

# ---- 03: second commit + push over the hermetic relay; host verifies --------
# The same relay + setup-hook pattern as live-flint-loop (#2313's shape):
# guest dials 10.0.0.2:4748, the runner relays to flintd on 127.0.0.1:4748.
vgate_run 03 -- \
    --net '$RUN_DIR/cap03.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4748:relay --net-tcp-respond-relay 127.0.0.1:4748 \
    --script '$RUN_DIR/script-03.txt' \
    --virtio-fs '$RUN_DIR/share' \
    --script-expect 'flint: push up to date' --script-expect-tail 3 --timeout 480

vgate_assert 03 serial-contains 'flint: commit ok id='
vgate_assert 03 serial-contains ' ops=2 parent='
vgate_assert 03 serial-absent ' ops=2 parent=none'
# M138d: `flint blame` names the new change — the AnswerPlusOne decl's line
# is attributed to this boot's fix commit (author8 d75a9801 = the guest's
# RFC 8032 TEST 1 key) and the python below reads the change-id back off
# the stream head so the attribution is to the NEW change, not any commit.
vgate_assert 03 serial-contains 'flint: blame '
vgate_assert 03 serial-contains ' d75a9801 func AnswerPlusOne() int { return Answer() + 1 }'
vgate_assert 03 serial-contains 'flint: push ok stream=main changes=2'
vgate_assert 03 serial-contains 'flint: push up to date'
vgate_assert 03 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 03 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 python <<'PY'
import glob, json, os, subprocess, sys

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
out = open(os.path.join(run, "run-" + os.environ["VG_TAG"] + ".out"),
           errors="replace").read()
for leaked in (
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    "ab" * 32,
):
    if leaked in out:
        sys.exit("FAIL: secret hex reached run-03.out")

# The guest stream log and the server's copy must be byte-identical.
local_logs = glob.glob(os.path.join(share, "FLINT", "streams", "*.jsonl"))
if len(local_logs) != 1:
    sys.exit("expected 1 local stream log, got %r" % local_logs)
stream_id = os.path.basename(local_logs[0])[:-len(".jsonl")]
remote_log = os.path.join(run, "devloopd-store", "streams", stream_id + ".jsonl")
if not os.path.isfile(remote_log):
    sys.exit("pushed stream log missing on server: " + remote_log)
local_raw = open(local_logs[0], "rb").read()
remote_raw = open(remote_log, "rb").read()
if local_raw != remote_raw:
    sys.exit("pushed stream log is not byte-verbatim")
lines = local_raw.decode("utf-8").splitlines()
# K=3 (M138d): the stream accumulates — each iteration appends a base-revert
# and a fix Change, so the log holds an even count that grows by 2.
if len(lines) < 2 or len(lines) % 2 != 0:
    sys.exit("expected an even Change count >= 2 on the stream, got %d" % len(lines))

# `flint blame` names the NEW change: the AnswerPlusOne line's change-id
# must be this boot's stream head (the fix commit just pushed), not the
# base commit an older-decl line attributes to.
head_id = json.loads(lines[-1])["id"]
ser = open(os.environ["VG_SER"], errors="replace").read()
blamed = [l for l in ser.splitlines()
          if l.startswith("flint: blame ") and "AnswerPlusOne" in l]
if not blamed or not any(l.split()[2] == head_id for l in blamed):
    sys.exit("blame did not attribute AnswerPlusOne to the head change "
             + head_id + ": " + repr(blamed))

# Every Change must be authored by the guest's agent-sign key — the RFC
# 8032 TEST 1 public key paired to the seed SECRETS.TXT bound to FLINT.ELF.
GUEST_KEY = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
for i, ln in enumerate(lines):
    ch = json.loads(ln)
    if ch.get("author") != GUEST_KEY:
        sys.exit("Change %d author %r is not the guest agent-sign key"
                 % (i, ch.get("author")))

# REMOTE.json bound by the first push is what the bare push consumed.
remote_cfg = open(os.path.join(share, "FLINT", "REMOTE.json")).read()
if '"remote":"tcp://10.0.0.2:4748"' not in remote_cfg or ('"stream":"%s"' % stream_id) not in remote_cfg:
    sys.exit("REMOTE.json does not bind the push: %r" % remote_cfg)

# The host side's own client verifies every pushed Change's signature.
flint = open(os.path.join(run, "flint-client-path.txt")).read().strip()
res = subprocess.run(
    [flint, "--store", os.path.join(run, "devloopd-store"), "verify", "--all"],
    capture_output=True, text=True,
)
if res.returncode != 0:
    sys.exit("host flint verify --all rc=%d: %s%s" % (res.returncode, res.stdout, res.stderr))
verified = [l for l in res.stdout.splitlines() if l.endswith("sig: verified")]
# K=3 (M138d): the server holds the ONE accumulating stream — verify --all
# signs off on every Change the byte-verbatim log carries, not just this
# iteration's pair.
if len(verified) != len(lines):
    sys.exit("expected %d 'sig: verified' lines from host verify, got %r"
             % (len(lines), res.stdout))
rec = json.load(open(os.path.join(run, "devloopd-store", "streams", stream_id + ".json")))
if rec.get("head") != json.loads(lines[-1]).get("id"):
    sys.exit("server stream head %r != last pushed change %r"
             % (rec.get("head"), lines[-1]))
print("run-03: 2 guest-signed Changes byte-verbatim, host verify sig:verified x2, head rolled")
PY
