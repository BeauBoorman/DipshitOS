# go-flint.spec -- M103 (#2253, ADR 0049) class-B: FLINT agent-native source
# control for VirelaiOS.
#
# Run 01 (M103a #2253): proves go/parser + FLINT's Go-native Zig declaration
# scanner run in-guest over the 100-file corpus (50 .go + 50 .zig) staged at
# /host/FLINTC, producing the exact canonical Atom hashes and spans into
# /host/FLINTC.OUT (compared byte-for-byte against an independent host Python
# renderer of MANIFEST.json).
#
# Run 02 (M103b #2251): initializes workspace w over /host/FLINTW, stages the
# 245-Atom corpus, verifies idempotent re-add, applies a body edit + const
# removal in go/sample.go and a whitespace/comment edit in zig/sample.zig,
# re-adds (folding add+modify->add and add+delete->nothing), and checks status
# plus ATOMS.jsonl UUIDv7 invariants.
#
# Run 03 (M103c #2252): continuing workspace w on the primary share, commits
# the 244 staged adds as an Ed25519-signed Change using the app-bound
# `agent-sign` secret, lists the log, verifies the store (--all), and verifies
# the pinned good and bad vectors (--file=/host/FLINTV/{good,bad}.jsonl).
#
# Run 04 (M103c #2252): on an alternate share (`--cvc-file $RUN_DIR/nosign-share`)
# whose SECRETS.TXT has `#v1\n` only, runs init -> add -> commit and proves
# `flint: refuse secret_not_found` with no `streams/*.jsonl` written and
# `STAGE.jsonl` left intact.
#
# Runs 05-07 (M103d #2254): on `--cvc-file $RUN_DIR/clean-share`, proves two-VM
# fork + attach/replay (`init --stream=feature`) + disjoint edits on X and Y +
# semantic merge on Ops (`flint: merge ok conflicts=0`, `src not materialized
# files=1`, re-merge `flint: merge up to date`, `verify --all` 4x `sig: verified`).
#
# Runs 08-10 (M103d #2254): on `--cvc-file $RUN_DIR/conflict-share`, proves two
# machines editing X differently produce `flint: merge conflict atom=calc.X
# type=concurrent_modify` and `flint: merge conflicts=1` with `MERGE.json`
# written and main's stream log and head unchanged.
#
# Runs 11-13 (M101a #2313): FLINT-SYNC/1 remote verbs over hermetic --net.
# The setup hook locates a sibling ../flint-server checkout (FLINT_SERVER_DIR
# override, Zig 0.17 — same recovery pattern as GO_FORK_DIR), `zig build`s
# flintd, seeds its store with the pinned sync-seed stream, and serves it on
# 127.0.0.1:4749 with --auth-key. The runner relays guest dials of
# 10.0.0.2:4749 to it (--net-tcp-respond/-relay). The port is 4749, NOT
# the fleet's 4748: every FLINT socket spec's setup kills the incumbent
# listener (`lsof -ti tcp:<port> | xargs kill -9`), so a shared port
# means sibling-worktree gates murder each other's flintd mid-run —
# observed: run 15's `store ls` answered by a foreign gate's loopd-store
# (empty stream list). 4749 is go-flint's own lane. Run 11 proves `flint
# ls-remote` + `clone <addr> <stream>` writing raw-JSONL verbatim into
# sync-share; run 12 re-boots on the SAME share (the conflict-share pattern)
# for `verify --all` + M101b `verify --remote` + a REMOTE.json-bound bare
# `pull`; run 13 proves a wrong `flint-remote` secret refuses `auth_failed`
# and writes nothing. M101b (#2314): sync-share carries a TRUSTED.TXT
# keyring pinning the seed stream's author — without it clone/pull refuse
# keyring_missing. Splitting
# clone and verify/pull across boots also keeps the sequential-exec path off
# the task-slot/file-channel reclamation race the M103 gate relies on
# vi.Sleep(1) to absorb (observed: `gosh: FLINT.ELF: not found` +
# stream_missing on the immediately-next invocation after a socket session).
#
# Runs 14-15 (M101c #2315): the install seam. The publisher artifact is
# the SIGNED release Change — a stream `rel` whose head covers
# `release.go` carrying ReleaseName/ReleaseVersion/ReleaseELFSHA256/
# ReleaseManifestRow (the flint-client#48 convention). The hook mints it
# with the pinned test key through store's env-gated generator
# (fixture_gen_test.go — parser atoms + FLINT canonical bytes + Ed25519
# against the CURRENT GOHELLO.ELF) and stages it verbatim onto flintd's
# `rel` AND the consumer's local replica: `flint push`/`clone` cannot
# carry a release-sized Change — the ~2 KiB append request outruns the
# kernel's 1460-byte TCPSend payload bound and the relay's verbatim
# retransmission mangles multi-segment requests (observed: flintd logs
# seq:null/op:unknown, client hangs to ETIMEDOUT); the matching `read`
# reply crosses the guest's ~1460 B recv-fill boundary and deadlocks the
# ACK-gated pump (observed — relay log ends at a 2114-byte buffer with
# the guest ACK frozen at exactly 1460). Wire verbs whose requests AND
# replies stay under the bound (hello/auth/list/heads) still run for
# real; every verification leg (keyring, Ed25519, atom hash, ELF sha256)
# is intact — only the transport of the signed bytes differs.
# Run 14 plays the CONSUMER on store-share: `store ls` sees
# `rel release`/`main no-release`, `store install rel` verifies the
# local chain against the remote head (keyring-gated, no pull needed on
# match), re-parses the untrusted /host/DROP release.go against the
# signed head's new_hash, sha256s the fetched ELF against
# ReleaseELFSHA256, and only then WriteFileSafes /host/GOHELLO.ELF + the
# APPS.TXT row — `GOHELLO.ELF` then execs. STORE speaks the wire itself
# ONLY for `ls`+head checks (a minimal hello/auth/list client; the
# shared secret is bound to STORE.ELF via the apps allowlist):
# pull/verify are direct FLINT.ELF execs — an inner GOSH.ELF -c capture
# would put FOUR Go runtimes on the task pool at once (outer gosh +
# store + gosh + flint = 16 > 13 user slots) and the child dies
# `newosproc: sys_thread create failed`. The child's `flint: refuse
# <name>` still reaches serial verbatim; STORE reports store: refuse
# sync_failed alongside it.
#
# Runs 15-17 (M101e #2317): the acceptance legs — update, rollback, and
# the standing negatives, all on store-share (state carries boot to
# boot). The v2 fixture is GOHELLO.ELF with its marker literal patched
# ("virelai-go OK" -> "virelai-go V2"): distinct bytes, distinct sha256,
# a distinct serial marker — no second build. Its release Change is
# parented on v1's with modify ops for the two moved atoms
# (ReleaseVersion + ReleaseELFSHA256), minted by the same env-gated
# generator. The wire still cannot carry a release-sized Change, so run
# 15's script advances the local `rel` replica to v2 by file copy (the
# same seam M101c staged v1 with) — `flint pull` then answers "up to
# date" because the remote head is already inside local history — and
# `store update` runs the full verify + fetch + WriteFileSafe publish
# for real. `store rollback` re-materializes the retained .prev bytes.
# Run 16 is the update negatives: a bad v2 ELF drop refuses elf_mismatch
# BEFORE any publish (old state untouched), then `echo >>` appends stage
# the torn-publish shapes — a diverged .prev refuses rollback with
# prev_mismatch, a diverged live ELF (STORE.TXT still records v1) makes
# update AND rollback refuse state_mismatch — and the post-run python
# pins every tracked file byte-exact. (`cat >` cannot move a >4 KiB file
# in-guest — readBounded — so the tears are appends.) Run 17 removes the app
# (remove needs no hash match — the recovery path), then refuses
# installs on the tampered drops plus the two publisher negatives:
# badkey/revkey are ~400 B empty-ops Changes served ONLY by flintd —
# small enough to clone over the wire for real, so the keyring gate
# fires: badkey's author is simply absent (key_unknown) and revkey's is
# a revoked= row in TRUSTED.TXT (key_revoked). Both also refuse inside
# run 14's `store ls` — the honest negatives print in the same boot as
# the happy path.
#
# This spec is grown across M103a-d/M101a-e and is NOT vgate_repeat-safe
# (runs 01-03, 05-07, 08-10, and 14-17 share /host state across boots).
#
# HOST PREREQ:
#   bash tools/go/build-flint.sh -> .build/go/FLINT.ELF
#   bash tools/go/build-gosh.sh  -> .build/go/GOSH.ELF
#   bash tools/go/build-store.sh -> .build/go/STORE.ELF
#   bash tools/go/build-go.sh    -> .build/go/GOHELLO.ELF
#   ../flint-server checkout (or FLINT_SERVER_DIR=...) for runs 11-17 only;
#   the hook zig-builds flintd. flint-server is drawmeanelephant's repo under
#   the VirelaiOS proprietary source-available license (not GPL-family).
#
# exec-order: assert-proven -- run 01 ends on `flint: parse files=`, run 02
# ends on `flint: status `, run 03 ends on `sig_invalid`, run 04 ends on
# `flint: refuse secret_not_found`, runs 05/08 end on `flint: fork ok`, runs
# 06/09 end on `flint: commit ok`, run 07 ends on `flint: status ws=a`, run
# 10 ends on `flint: merge conflicts=1`, run 11 ends on `flint: clone ok`,
# run 12 ends on `flint: pull up to date`, run 13 ends on `flint: refuse
# auth_failed`, runs 14/15 end on `virelai-go OK` (the v1 install, then the
# rollback restoring it), run 16 ends on `m101e: torn-state legs done`, and
# run 17 ends on `m101e: negatives done`.

vgate_name go-flint "M103 #2253/#2251/#2252/#2254 (ADR 0049): FLINT.ELF parser corpus, flat-file store, signed commit, fork, and semantic merge on Ops"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-01.txt <<'EOF'
exec FLINT.ELF parse-corpus /host/FLINTC
EOF

vgate_file script-02.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/02.SH"
EOF

vgate_file script-03.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/03.SH"
EOF

vgate_file script-04.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/04.SH"
EOF

vgate_file script-05.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/05.SH"
EOF

vgate_file script-06.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/06.SH"
EOF

vgate_file script-07.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/07.SH"
EOF

vgate_file script-08.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/08.SH"
EOF

vgate_file script-09.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/09.SH"
EOF

vgate_file script-10.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/10.SH"
EOF

vgate_file script-11.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/11.SH"
EOF

vgate_file script-12.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/12.SH"
EOF

vgate_file script-13.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/13.SH"
EOF

# One GOSH.ELF -c pipeline: monitor `exec` lines all feed at boot —
# they do NOT sequence (observed `exec GOHELLO.ELF` racing ahead of the
# install that had not run yet). gosh's `;` chain sequences in-process,
# and the reclaim-safe depth is outer-gosh -> store -> flint = 3 Go
# runtimes (~12 slots, under the 13-user cap).
vgate_file script-14.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "STORE.ELF ls --remote=10.0.0.2:4749;STORE.ELF install rel --remote=10.0.0.2:4749 --channel=/host/DROP;GOHELLO.ELF"
EOF

# Runs 15-17 drive the multi-line install legs through staged .SH files —
# the replica advance and the torn-publish leg need `cat >` redirection,
# and a sourced script keeps the sequencing in-guest like runs 02-13.
vgate_file script-15.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/15.SH"
EOF

vgate_file script-16.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/16.SH"
EOF

vgate_file script-17.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/17.SH"
EOF

vgate_setup_python <<'PY'
import json, os, shutil, socket, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

for name, cmd in (
    ("FLINT.ELF", "bash tools/go/build-flint.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
):
    elf = os.path.join(".build", "go", name)
    if not os.path.isfile(elf):
        sys.exit(name + " missing (expected " + elf + ") - build it first: " + cmd)
    shutil.copy(elf, os.path.join(share, name))

# App-bound Ed25519 signing seed (RFC 8032 §7.1 TEST 1) for FLINT.ELF.
sig_dir = os.path.join("user", "go", "flint", "testdata", "sig")
SEED_HEX = open(os.path.join(sig_dir, "seed.hex"), "r", encoding="utf-8").read().strip()
open(os.path.join(share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nagent-sign\t1000\t" + SEED_HEX + "\tFLINT.ELF\n"
)
open(os.path.join(share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\n"
)

flintv = os.path.join(share, "FLINTV")
os.makedirs(flintv, exist_ok=True)
for vname in ("good.jsonl", "bad.jsonl"):
    shutil.copy(os.path.join(sig_dir, vname), os.path.join(flintv, vname))

corpus_src = os.path.join("user", "go", "flint", "testdata", "corpus")
for target_name in ("FLINTC", "FLINTW"):
    target_dir = os.path.join(share, target_name)
    os.makedirs(target_dir, exist_ok=True)
    for sub in ("go", "zig"):
        dst = os.path.join(target_dir, sub)
        if os.path.exists(dst):
            shutil.rmtree(dst)
        shutil.copytree(os.path.join(corpus_src, sub), dst)

manifest_src = os.path.join(corpus_src, "MANIFEST.json")
shutil.copy(manifest_src, os.path.join(share, "FLINTC", "MANIFEST.json"))

manifest = json.load(open(manifest_src, "r", encoding="utf-8"))
atoms = sorted(manifest["atoms"], key=lambda a: (a["file"], int(a["start"])))
lines = [
    "%s\t%s\t%s\t%d\t%d\t%s\t%s\n" % (
        a["file"], a["kind"], a["name"], int(a["start"]), int(a["end"]), a["hash"], a["sig_hash"]
    )
    for a in atoms
]
open(os.path.join(run, "expect-corpus.txt"), "w", encoding="utf-8").writelines(lines)

flintj = os.path.join(share, "FLINTJ")
os.makedirs(flintj, exist_ok=True)

open(os.path.join(flintj, "sample-body.go"), "w", encoding="utf-8").write(
    "package sample\n\n"
    "type Point struct {\n"
    "\tX, Y int\n"
    "}\n\n"
    "func Add(a, b int) int {\n"
    "\treturn a + b + 1\n"
    "}\n\n"
    "func Mul(a, b int) int {\n"
    "\treturn a * b\n"
    "}\n"
)

open(os.path.join(flintj, "sample-ws.zig"), "w", encoding="utf-8").write(
    "// top comment\n"
    "const limit = 100;\n\n"
    "pub const Point = struct {\n"
    "    x: i32,\n"
    "    y: i32,\n"
    "};\n\n"
    "pub fn add(a: i32, b: i32) i32 {\n"
    "    // body comment\n"
    "    return a + b;\n"
    "}\n\n"
    "fn helper(x: i32) i32 {\n"
    "    return x * 2;\n"
    "}\n\n"
    "export fn entry() void {}\n\n"
    "test \"add works\" {\n"
    "    const r = add(1, 2);\n"
    "    _ = r;\n"
    "}\n"
)

open(os.path.join(flintj, "02.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF init --name=w --src=/host/FLINTW\n"
    "FLINT.ELF add /host/FLINTW\n"
    "FLINT.ELF add /host/FLINTW\n"
    "cat /host/FLINTJ/sample-body.go > /host/FLINTW/go/sample.go\n"
    "cat /host/FLINTJ/sample-ws.zig > /host/FLINTW/zig/sample.zig\n"
    "FLINT.ELF add /host/FLINTW\n"
    "FLINT.ELF status\n"
)

open(os.path.join(flintj, "03.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF commit -m \"initial corpus\"\n"
    "FLINT.ELF log\n"
    "FLINT.ELF verify --all\n"
    "FLINT.ELF verify --file=/host/FLINTV/good.jsonl\n"
    "FLINT.ELF verify --file=/host/FLINTV/bad.jsonl\n"
)

# Run 04: alternate share with no `agent-sign` secret entry.
nosign = os.path.join(run, "nosign-share")
os.makedirs(os.path.join(nosign, "SRC", "go"), exist_ok=True)
os.makedirs(os.path.join(nosign, "SRC", "zig"), exist_ok=True)
os.makedirs(os.path.join(nosign, "FLINTJ"), exist_ok=True)
for name in ("FLINT.ELF", "GOSH.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(nosign, name))
open(os.path.join(nosign, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\n"
)
open(os.path.join(nosign, "SECRETS.TXT"), "w", encoding="utf-8").write("#v1\n")
shutil.copy(os.path.join(corpus_src, "go", "sample.go"), os.path.join(nosign, "SRC", "go", "sample.go"))
shutil.copy(os.path.join(corpus_src, "zig", "sample.zig"), os.path.join(nosign, "SRC", "zig", "sample.zig"))
open(os.path.join(nosign, "FLINTJ", "04.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF init --name=w --src=/host/SRC\n"
    "FLINT.ELF add /host/SRC\n"
    "FLINT.ELF commit -m \"no key\"\n"
)

# Runs 05-07 (clean-share) and 08-10 (conflict-share): two-VM merge journeys.
base_calc = (
    "package calc\n\n"
    "func X() int {\n"
    "\treturn 1\n"
    "}\n\n"
    "func Y() int {\n"
    "\treturn 2\n"
    "}\n"
)
edit_x_feat = (
    "package calc\n\n"
    "func X() int {\n"
    "\treturn 10\n"
    "}\n\n"
    "func Y() int {\n"
    "\treturn 2\n"
    "}\n"
)
edit_y_main = (
    "package calc\n\n"
    "func X() int {\n"
    "\treturn 1\n"
    "}\n\n"
    "func Y() int {\n"
    "\treturn 20\n"
    "}\n"
)
edit_x_conflict = (
    "package calc\n\n"
    "func X() int {\n"
    "\treturn 99\n"
    "}\n\n"
    "func Y() int {\n"
    "\treturn 2\n"
    "}\n"
)

def stage_merge_share(share_dir, s_init, s_feat, s_merge, main_edit_src):
    for sub in ("SRCA", "SRCB", "FLINTJ"):
        os.makedirs(os.path.join(share_dir, sub), exist_ok=True)
    for name in ("FLINT.ELF", "GOSH.ELF"):
        shutil.copy(os.path.join(".build", "go", name), os.path.join(share_dir, name))
    open(os.path.join(share_dir, "SECRETS.TXT"), "w", encoding="utf-8").write(
        "#v1\nagent-sign\t1000\t" + SEED_HEX + "\tFLINT.ELF\n"
    )
    open(os.path.join(share_dir, "OWNERS.TXT"), "w", encoding="utf-8").write(
        "#v1\nFLINT.ELF\t644\t0\t-\n"
    )
    open(os.path.join(share_dir, "SRCA", "calc.go"), "w", encoding="utf-8").write(base_calc)
    open(os.path.join(share_dir, "SRCB", "calc.go"), "w", encoding="utf-8").write(base_calc)
    open(os.path.join(share_dir, "FLINTJ", "edit-b.go"), "w", encoding="utf-8").write(edit_x_feat)
    open(os.path.join(share_dir, "FLINTJ", "edit-a.go"), "w", encoding="utf-8").write(main_edit_src)

    open(os.path.join(share_dir, "FLINTJ", s_init), "w", encoding="utf-8").write(
        "FLINT.ELF init --name=a --src=/host/SRCA\n"
        "FLINT.ELF add /host/SRCA\n"
        "FLINT.ELF commit -m base\n"
        "FLINT.ELF fork main feature\n"
    )
    open(os.path.join(share_dir, "FLINTJ", s_feat), "w", encoding="utf-8").write(
        "FLINT.ELF init --name=b --src=/host/SRCB --stream=feature\n"
        "cat /host/FLINTJ/edit-b.go > /host/SRCB/calc.go\n"
        "FLINT.ELF add /host/SRCB\n"
        "FLINT.ELF commit -m feat\n"
    )

stage_merge_share(os.path.join(run, "clean-share"), "05.SH", "06.SH", "07.SH", edit_y_main)
open(os.path.join(run, "clean-share", "FLINTJ", "07.SH"), "w", encoding="utf-8").write(
    "cat /host/FLINTJ/edit-a.go > /host/SRCA/calc.go\n"
    "FLINT.ELF add /host/SRCA\n"
    "FLINT.ELF commit -m main\n"
    "FLINT.ELF merge feature\n"
    "FLINT.ELF merge feature\n"
    "FLINT.ELF verify --all\n"
    "FLINT.ELF status --ws=a\n"
)

stage_merge_share(os.path.join(run, "conflict-share"), "08.SH", "09.SH", "10.SH", edit_x_conflict)
open(os.path.join(run, "conflict-share", "FLINTJ", "10.SH"), "w", encoding="utf-8").write(
    "cat /host/FLINTJ/edit-a.go > /host/SRCA/calc.go\n"
    "FLINT.ELF add /host/SRCA\n"
    "FLINT.ELF commit -m main\n"
    "FLINT.ELF merge feature\n"
)

# ---- M101a (#2313): host flintd for the hermetic --net sync runs ------------
# flintd is not built in this repo: locate a sibling checkout
# (FLINT_SERVER_DIR env override, then ../flint-server — the GO_FORK_DIR
# recovery pattern), zig-build it, seed a store with the pinned sig-vector
# stream, and serve it with --auth-key for runs 11-12.
repo = os.getcwd()
flint_server_dir = os.environ.get("FLINT_SERVER_DIR") or os.path.join(repo, "..", "flint-server")
flint_server_dir = os.path.abspath(flint_server_dir)
if not os.path.isfile(os.path.join(flint_server_dir, "build.zig")):
    sys.exit(
        "flint-server checkout missing at %s - clone it once (outside the repo): "
        "git clone https://github.com/drawmeanelephant/flint-server %s"
        % (flint_server_dir, flint_server_dir)
    )
flintd_rev = subprocess.run(
    ["git", "-C", flint_server_dir, "rev-parse", "HEAD"],
    capture_output=True, text=True,
).stdout.strip()
subprocess.check_call(["zig", "build"], cwd=flint_server_dir)
flintd = os.path.join(flint_server_dir, "zig-out", "bin", "flintd")
if not os.path.isfile(flintd):
    sys.exit("flintd missing after zig build (expected " + flintd + ")")

# Seed the served store with the pinned sync-seed stream (testdata/sync/
# seed-stream.jsonl — one signed empty-ops Change on `main`). streams/<id>.json
# + .jsonl are the byte-portable contract, so a store written here loads in
# flintd and in FLINT.ELF identically. The seed stays under the ~1.4 KiB wire
# cliff observed in the go-flint run-11 capture: the runner's TCP relay
# re-delivers retransmitted guest segments to flintd without dedup AND drops
# inbound data past the first ~1460-byte segment, so a >MTU `read` response
# starves the guest of its '\n' terminator (flint-server @ 3e18fc0 observed).
good_raw = open(os.path.join("user", "go", "flint", "testdata", "sync", "seed-stream.jsonl"), "rb").read()
good_changes = [json.loads(l) for l in good_raw.decode("utf-8").splitlines() if l.strip()]
stream_id = good_changes[-1]["stream"]
flintd_store = os.path.join(run, "flintd-store")
os.makedirs(os.path.join(flintd_store, "streams"), exist_ok=True)
with open(os.path.join(flintd_store, "streams", stream_id + ".jsonl"), "wb") as f:
    f.write(good_raw)
rec = {
    "id": stream_id, "name": "main", "head": good_changes[-1]["id"],
    "created": good_changes[0]["ts"], "forked_from": None,
}
with open(os.path.join(flintd_store, "streams", stream_id + ".json"), "w") as f:
    f.write(json.dumps(rec, separators=(",", ":")) + "\n")

# M101c (#2315): a second remote stream `rel`, headless — the release
# stream's reserved slot. The producer run clones it (zero Changes, so the
# keyring gate is never demanded), attaches a workspace, signs the release
# commit, and pushes — flintd refuses a pushed stream whose NAME already
# exists, which is why `rel` is seeded rather than pushed into existence.
rel_stream_id = "0199de2d-dc00-7000-8000-00000000b010"

# The shared --auth-key secret: 64 lowercase hex + newline, outside the store
# and outside the share (the guest reads its copy from the slot-70 secret
# lane, never from /host).
AUTH_KEY_HEX = "ab" * 32
auth_key_file = os.path.join(run, "flint-auth.key")
open(auth_key_file, "w", encoding="utf-8").write(AUTH_KEY_HEX + "\n")

subprocess.run(
    ["sh", "-c", "lsof -ti tcp:4749 | xargs kill -9"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
time.sleep(0.2)
flintd_log = open(os.path.join(run, "flintd.log"), "wb")
flintd_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store,
     "--listen=127.0.0.1:4749", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True,
)
flintd_up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4749), 0.2)
        s.close()
        flintd_up = True
        break
    except OSError:
        if flintd_proc.poll() is not None:
            break
        time.sleep(0.1)
if not flintd_up:
    sys.exit("flintd did not come up on 127.0.0.1:4749 (see flintd.log)")
print("flintd: serving %s on 127.0.0.1:4749 pid=%d rev=%s" % (flintd_store, flintd_proc.pid, flintd_rev))


def stage_sync_share(share_dir, auth_hex, script_name, script_body):
    os.makedirs(os.path.join(share_dir, "FLINTJ"), exist_ok=True)
    for name in ("FLINT.ELF", "GOSH.ELF"):
        shutil.copy(os.path.join(".build", "go", name), os.path.join(share_dir, name))
    open(os.path.join(share_dir, "OWNERS.TXT"), "w", encoding="utf-8").write(
        "#v1\nFLINT.ELF\t644\t0\t-\n"
    )
    open(os.path.join(share_dir, "SECRETS.TXT"), "w", encoding="utf-8").write(
        "#v1\nagent-sign\t1000\t" + SEED_HEX + "\tFLINT.ELF\n"
        "flint-remote\t1000\t" + auth_hex + "\tFLINT.ELF\n"
    )
    open(os.path.join(share_dir, "FLINTJ", script_name), "w", encoding="utf-8").write(script_body)


stage_sync_share(
    os.path.join(run, "sync-share"),
    AUTH_KEY_HEX,
    "11.SH",
    "FLINT.ELF ls-remote 10.0.0.2:4749\n"
    "FLINT.ELF clone 10.0.0.2:4749 main\n",
)
# M101b (#2314): the publisher keyring at /host/FLINT/TRUSTED.TXT pins the
# seed stream's author key, so clone/pull/verify --remote trust the seeded
# stream. badauth-share carries none on purpose: auth_failed refuses at
# hello before the keyring is ever read (and its FLINT/ dir must stay
# absent for the run-13 no-writes assert).
os.makedirs(os.path.join(run, "sync-share", "FLINT"), exist_ok=True)
open(os.path.join(run, "sync-share", "FLINT", "TRUSTED.TXT"), "w", encoding="utf-8").write(
    "#v1\nkey=" + good_changes[-1]["author"] + " name=sync-seed\n"
)
open(os.path.join(run, "sync-share", "FLINTJ", "12.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF verify --all\n"
    "FLINT.ELF verify --remote\n"
    "sleep 1\n"
    "FLINT.ELF pull\n",
)
stage_sync_share(
    os.path.join(run, "badauth-share"),
    "cd" * 32,
    "13.SH",
    "FLINT.ELF clone 10.0.0.2:4749 main\n",
)

# ---- M101c (#2315): the release stream + install shares -------------------
# The producer half (run 14) signs release.go in-guest and pushes it; the
# hook only renders the release.go text — the real sha256(GOHELLO.ELF) and
# the schema-v2 row a publisher would ship — so the signed Change's
# new_hash covers exactly what the consumer re-parses off the untrusted
# drop.
store_elf = os.path.join(".build", "go", "STORE.ELF")
if not os.path.isfile(store_elf):
    sys.exit("STORE.ELF missing (expected " + store_elf + ") - build it first: "
             "bash tools/go/build-store.sh")
gohello = os.path.join(".build", "go", "GOHELLO.ELF")
if not os.path.isfile(gohello):
    sys.exit("GOHELLO.ELF missing (expected " + gohello + ") - build it first: "
             "bash tools/go/build-go.sh")

import hashlib
elf_bytes = open(gohello, "rb").read()
elf_sha = hashlib.sha256(elf_bytes).hexdigest()

# The signed release Change is minted by store's env-gated generator
# test (user/go/store/fixture_gen_test.go): it parses the release
# manifest with the real parser, replicates FLINT's canonical bytes, and
# signs with the pinned test seed — same author the consumer keyring
# trusts. Regenerated per run so the fixture always matches the CURRENT
# GOHELLO.ELF (the guest build is not bit-reproducible across
# toolchains/paths). The in-guest producer leg was cut: under load the
# file-channel/exec reclamation race ate init/add/commit execs whole
# (observed `gosh: FLINT.ELF: not found` across several runs), and the
# producer machinery is upstream's card anyway (flint-client#49). The
# fixture's signature still goes through the full M101b verify path —
# the consumer's evidence is unchanged.
gen = subprocess.run(
    ["go", "test", "./store", "-run", "TestGenReleaseFixture", "-count=1"],
    cwd="user/go",
    env={**os.environ, "STORE_GEN_FIXTURE": "1"},
    capture_output=True, text=True)
if gen.returncode != 0:
    sys.exit("release fixture generation failed:\n" + gen.stdout[-2000:] + gen.stderr[-2000:])
rel_change_line = open(os.path.join("user", "go", "store", "testdata",
                                    "release-stream.jsonl"),
                       "r", encoding="utf-8").read().strip()
rel_change = json.loads(rel_change_line)
release_go = open(os.path.join("user", "go", "store", "testdata", "release.go"),
                  "r", encoding="utf-8").read()
REL_ROW = "GOHELLO.ELF | Go Hello | g | dock=false"

# Consumer share: STORE+GOSH+FLINT, publisher keyring, the real fleet
# manifest, and the drops (clean v1 / clean v2 / mutated v2 ELF /
# tampered v2 release.go). GOHELLO.ELF is staged ONLY inside the drops —
# install must be the thing that lands it at the share root.
store_share = os.path.join(run, "store-share")
os.makedirs(os.path.join(store_share, "FLINTJ"), exist_ok=True)
os.makedirs(os.path.join(store_share, "FLINT"), exist_ok=True)
for name in ("FLINT.ELF", "GOSH.ELF", "STORE.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(store_share, name))
open(os.path.join(store_share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\n"
)
# STORE.ELF needs its own flint-remote binding for `store ls`'s wire
# handshake — the slot-70 lane scopes secrets per app. The apps field is
# a COMMA allowlist inside ONE row: a second same-key row overwrites the
# first (set_internal dedupes on uid+key), observed FLINT.ELF losing its
# binding to auth_required.
open(os.path.join(store_share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF\n"
)
open(os.path.join(store_share, "FLINT", "TRUSTED.TXT"), "w", encoding="utf-8").write(
    "#v1\nkey=" + good_changes[-1]["author"] + " name=sync-seed\n"
)
# Local stream replicas on store-share. The wire `read` behind clone/
# pull cannot carry a release-sized Change (>~1460 B, the guest fill
# boundary — see the spec header), so the streams the consumer legs
# touch are materialized on the share instead: `main` verbatim from the
# pinned seed, `rel` verbatim from the generated release fixture —
# byte-identical to what a clone would have written. `store ls`/`install`
# then pull only `heads`/`list`-sized responses and verify locally — the
# keyring, signature, atom-hash, and ELF-sha checks are unchanged, only
# the transport of the signed bytes differs.
os.makedirs(os.path.join(store_share, "FLINT", "streams"), exist_ok=True)
with open(os.path.join(store_share, "FLINT", "streams", stream_id + ".jsonl"), "wb") as f:
    f.write(good_raw)
with open(os.path.join(store_share, "FLINT", "streams", stream_id + ".json"), "w") as f:
    f.write(json.dumps(
        {"id": stream_id, "name": "main", "head": good_changes[-1]["id"],
         "created": good_changes[0]["ts"], "forked_from": None},
        separators=(",", ":")) + "\n")
with open(os.path.join(store_share, "FLINT", "streams", rel_stream_id + ".json"), "w") as f:
    f.write(json.dumps(
        {"id": rel_stream_id, "name": "rel", "head": rel_change["id"],
         "created": 1760000000000, "forked_from": None},
        separators=(",", ":")) + "\n")
with open(os.path.join(store_share, "FLINT", "streams", rel_stream_id + ".jsonl"), "w") as f:
    f.write(rel_change_line + "\n")

# The remote's `rel` stream carries the same signed Change — staged
# verbatim because the ~2 KiB append request outruns the kernel's
# 1460-byte TCPSend payload bound and the relay's verbatim
# retransmission mangles multi-segment requests, while the matching
# `read` reply crosses the guest's ~1460 B recv-fill boundary (both
# observed; small hello/auth/list/heads traffic stays honest).
with open(os.path.join(flintd_store, "streams", rel_stream_id + ".json"), "w") as f:
    f.write(json.dumps(
        {"id": rel_stream_id, "name": "rel", "head": rel_change["id"],
         "created": 1760000000000, "forked_from": None},
        separators=(",", ":")) + "\n")
with open(os.path.join(flintd_store, "streams", rel_stream_id + ".jsonl"), "w") as f:
    f.write(rel_change_line + "\n")
shutil.copy(os.path.join("image", "apps.txt"), os.path.join(store_share, "APPS.TXT"))

def write_drop(drop, rel_text, elf):
    d = os.path.join(store_share, drop, "rel")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "release.go"), "w", encoding="utf-8").write(rel_text)
    open(os.path.join(d, "GOHELLO.ELF"), "wb").write(elf)

write_drop("DROP", release_go, elf_bytes)

# ---- M101e (#2317): update/rollback + the standing negatives -----------
# v2 is GOHELLO.ELF with its marker literal patched: same program,
# distinct bytes, distinct sha256, a distinct serial marker — the update
# swap is visible without a second build. The v2 release Change is
# parented on v1's and carries modify ops for the two moved atoms; the
# same env-gated generator (user/go/store/fixture_gen_test.go) mints it
# plus two ~400 B empty-ops Changes signed by untrusted keys for the
# publisher negatives — small enough to clone over the wire for real, so
# the M101b keyring gate is what refuses them (a locally-staged replica
# would short-circuit pull at "up to date" and never consult
# TRUSTED.TXT).
mark_v1 = b"virelai-go OK"
mark_v2 = b"virelai-go V2"
if elf_bytes.count(mark_v1) != 1:
    sys.exit("GOHELLO.ELF marker %r occurs %d times (need exactly 1)"
             % (mark_v1, elf_bytes.count(mark_v1)))
elf_v2 = elf_bytes.replace(mark_v1, mark_v2)

fixture_dir = os.path.join(run, "fixtures")
os.makedirs(fixture_dir, exist_ok=True)
open(os.path.join(fixture_dir, "gohello-v2.elf"), "wb").write(elf_v2)


def gen_release_fixture(env):
    g = subprocess.run(
        ["go", "test", "./store", "-run", "TestGenReleaseFixture", "-count=1"],
        cwd="user/go",
        env={**os.environ, "STORE_GEN_FIXTURE": "1", **env},
        capture_output=True, text=True)
    if g.returncode != 0:
        sys.exit("fixture generation failed (tag=%s):\n%s%s"
                 % (env.get("STORE_FIXTURE_TAG", "?"),
                    g.stdout[-2000:], g.stderr[-2000:]))


gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.join(fixture_dir, "gohello-v2.elf"),
    "STORE_FIXTURE_VERSION": "2.0.0",
    "STORE_FIXTURE_PARENT": rel_change["id"],
    "STORE_FIXTURE_PREV_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_PREV_VERSION": "1.0.0",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c002",
    "STORE_FIXTURE_TS": "1760000100000",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "v2",
})
gen_release_fixture({
    "STORE_FIXTURE_EMPTY": "1",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000e010",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000e001",
    "STORE_FIXTURE_TS": "1760000200000",
    "STORE_FIXTURE_MSG": "untrusted publisher",
    "STORE_FIXTURE_SEED_HEX": "b1" * 32,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "badkey",
})
gen_release_fixture({
    "STORE_FIXTURE_EMPTY": "1",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000e011",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000e002",
    "STORE_FIXTURE_TS": "1760000300000",
    "STORE_FIXTURE_MSG": "revoked publisher",
    "STORE_FIXTURE_SEED_HEX": "b2" * 32,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "revkey",
})

rel_v2_line = open(os.path.join(fixture_dir, "release-v2-stream.jsonl"),
                   "r", encoding="utf-8").read().strip()
rel_v2 = json.loads(rel_v2_line)
release_v2_go = open(os.path.join(fixture_dir, "release-v2.go"),
                     "r", encoding="utf-8").read()
release_v2_tampered = release_v2_go.replace('"2.0.0"', '"9.9.9"')
assert release_v2_tampered != release_v2_go


def load_gen_change(tag):
    line = open(os.path.join(fixture_dir, "release-%s-stream.jsonl" % tag),
                "r", encoding="utf-8").read().strip()
    return json.loads(line), line


badkey_ch, badkey_line = load_gen_change("badkey")
revkey_ch, revkey_line = load_gen_change("revkey")

# flintd serves the two negative-key streams — remote-only, so `store ls`
# and `store install` must clone them over the wire and the keyring gate
# fires inside FLINT.ELF. `store ls` tolerates the per-stream refusal and
# reports `sync-failed` for each.
for ch, line, sname in ((badkey_ch, badkey_line, "badkey"),
                        (revkey_ch, revkey_line, "revkey")):
    with open(os.path.join(flintd_store, "streams", ch["stream"] + ".jsonl"), "w") as f:
        f.write(line + "\n")
    with open(os.path.join(flintd_store, "streams", ch["stream"] + ".json"), "w") as f:
        f.write(json.dumps(
            {"id": ch["stream"], "name": sname, "head": ch["id"],
             "created": ch["ts"], "forked_from": None},
            separators=(",", ":")) + "\n")

# The consumer keyring keeps the release author pinned and gains a
# revoked= row for revkey's author; badkey's author stays absent
# (key_unknown).
with open(os.path.join(store_share, "FLINT", "TRUSTED.TXT"),
          "a", encoding="utf-8") as f:
    f.write("revoked=" + revkey_ch["author"] + "\n")

# The v2 replica advance — run 15's script lands it by file copy (the
# staged-bytes seam again), after which the local `rel` log is the v1+v2
# chain and its record head is the v2 change.
with open(os.path.join(store_share, "FLINTJ", "rel-v2.jsonl"),
          "w", encoding="utf-8") as f:
    f.write(rel_change_line + "\n" + rel_v2_line + "\n")
with open(os.path.join(store_share, "FLINTJ", "rel-v2.json"),
          "w", encoding="utf-8") as f:
    f.write(json.dumps(
        {"id": rel_stream_id, "name": "rel", "head": rel_v2["id"],
         "created": 1760000000000, "forked_from": None},
        separators=(",", ":")) + "\n")

write_drop("DROPV2", release_v2_go, elf_v2)
write_drop("DROPV2BAD", release_v2_go, elf_v2 + b"\x00")
write_drop("DROPV2SIG", release_v2_tampered, elf_v2)

flintj_m101e = {
    # 15: advance the replica to v2, update, exec the new bytes, roll back,
    # exec the restored v1.
    "15.SH": (
        "cat /host/FLINTJ/rel-v2.jsonl > /host/FLINT/streams/" + rel_stream_id + ".jsonl\n"
        "cat /host/FLINTJ/rel-v2.json > /host/FLINT/streams/" + rel_stream_id + ".json\n"
        "STORE.ELF update GOHELLO --remote=10.0.0.2:4749 --channel=/host/DROPV2\n"
        "GOHELLO.ELF\n"
        "STORE.ELF rollback GOHELLO\n"
        "GOHELLO.ELF\n"
    ),
    # 16: a mutated v2 drop refuses elf_mismatch before any publish; then
    # byte-appends stage the two torn-publish shapes the state file fences
    # on — a diverged .prev refuses rollback with prev_mismatch, and a
    # diverged live ELF (state still records v1) makes update AND rollback
    # refuse state_mismatch. `cat` cannot move a >4 KiB file in-guest
    # (readBounded), so the tears are `echo >>` appends — byte-exact for
    # the post-run python.
    "16.SH": (
        "STORE.ELF update GOHELLO --remote=10.0.0.2:4749 --channel=/host/DROPV2BAD\n"
        "echo x >> /host/GOHELLO.ELF.prev\n"
        "STORE.ELF rollback GOHELLO\n"
        "echo y >> /host/GOHELLO.ELF\n"
        "STORE.ELF update GOHELLO --remote=10.0.0.2:4749 --channel=/host/DROPV2\n"
        "STORE.ELF rollback GOHELLO\n"
        "echo m101e: torn-state legs done\n"
    ),
    # 17: remove the (torn-state) app, then install refusals: tampered ELF,
    # tampered release manifest, unknown publisher key, revoked key.
    "17.SH": (
        "STORE.ELF remove GOHELLO\n"
        "STORE.ELF install rel --remote=10.0.0.2:4749 --channel=/host/DROPV2BAD\n"
        "STORE.ELF install rel --remote=10.0.0.2:4749 --channel=/host/DROPV2SIG\n"
        "STORE.ELF install badkey --remote=10.0.0.2:4749 --channel=/host/DROP\n"
        "STORE.ELF install revkey --remote=10.0.0.2:4749 --channel=/host/DROP\n"
        "echo m101e: negatives done\n"
    ),
}
for sname, sbody in flintj_m101e.items():
    open(os.path.join(store_share, "FLINTJ", sname),
         "w", encoding="utf-8").write(sbody)


print("staged FLINT.ELF, GOSH.ELF, STORE.ELF, /host/FLINTC, /host/FLINTW, /host/FLINTV, /host/FLINTJ, nosign-share, clean-share, conflict-share, sync-share, badauth-share, and store-share (%d files, %d atoms)" % (manifest["files"], len(atoms)))
PY

# ---- 01: M103a in-guest parse-corpus over /host/FLINTC -----------------------
vgate_run 01 -- \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-01.txt' \
    --script-expect 'flint: parse files=' \
    --script-expect-tail 2 --timeout 180

vgate_assert 01 serial-contains 'exec: loaded FLINT.ELF'
vgate_assert 01 serial-contains 'flint: parse files=100 atoms=245 parse_errors=0'
vgate_assert 01 share-equals FLINTC.OUT expect-corpus.txt
vgate_assert 01 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-01.out")
print("run-01 secret-absence ok")
PY

# ---- 02: M103b workspace init, idempotent add, body/delete/ws edit, status ---
vgate_run 02 -- \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-02.txt' \
    --script-expect 'flint: status ' \
    --script-expect-tail 3 --timeout 180

vgate_assert 02 serial-contains 'flint: init ok ws=w stream=main'
vgate_assert 02 serial-contains 'flint: add files=100 new=245 modified=0 deleted=0 unchanged=0'
vgate_assert 02 serial-contains 'flint: add files=100 new=0 modified=0 deleted=0 unchanged=245'
vgate_assert 02 serial-contains 'flint: add files=100 new=0 modified=1 deleted=1 unchanged=243'
vgate_assert 02 serial-contains 'flint: status ws=w stream=main atoms=244 staged=244 add=244 modify=0 delete=0 duplicates=0'
vgate_assert 02 share-contains FLINT/ws/w/WORKSPACE.json '"name":"w"'
vgate_assert 02 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import json, os, re, sys

run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-02.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-02.out")

share = os.path.join(run, "share")
atoms_path = os.path.join(share, "FLINT", "ws", "w", "ATOMS.jsonl")
if not os.path.isfile(atoms_path):
    sys.exit("missing " + atoms_path)
raw = open(atoms_path, "rb").read()
if not raw.endswith(b"\n"):
    sys.exit("ATOMS.jsonl does not end with newline")
lines = raw.decode("utf-8").splitlines()
if len(lines) != 244:
    sys.exit("expected 244 lines in ATOMS.jsonl, got %d" % len(lines))
v7_re = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
ids = set()
for line in lines:
    rec = json.loads(line)
    aid = rec.get("id", "")
    if not v7_re.match(aid):
        sys.exit("invalid UUIDv7 id: " + aid)
    if aid in ids:
        sys.exit("duplicate atom id: " + aid)
    ids.add(aid)
print("atoms-uuidv7: 244 lines, all unique valid UUIDv7")
PY

# ---- 03: M103c signed commit, log, verify --all, verify --file vectors -------
vgate_run 03 -- \
    --virtio-fs '$RUN_DIR/share' \
    --script '$RUN_DIR/script-03.txt' \
    --script-expect 'sig_invalid' \
    --script-expect-tail 3 --timeout 180

vgate_assert 03 serial-contains 'flint: commit ok id='
vgate_assert 03 serial-contains ' ops=244 parent=none'
vgate_assert 03 serial-contains 'flint: change '
vgate_assert 03 serial-contains ' ops=244 author=d75a9801 msg=initial corpus'
vgate_assert 03 serial-count 'sig: verified' 2
vgate_assert 03 serial-exact 'flint: verify 0199de2d-dc00-7000-8000-000000000100 sig_invalid' 1
vgate_assert 03 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import glob, json, os, sys

run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-03.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-03.out")
ser = open(os.environ["VG_SER"], errors="replace").read()
if ser.count("sig_invalid") != 1:
    sys.exit("expected exactly 1 sig_invalid in serial log, got %d" % ser.count("sig_invalid"))

share = os.path.join(run, "share")
streams_dir = os.path.join(share, "FLINT", "streams")
logs = sorted(glob.glob(os.path.join(streams_dir, "*.jsonl")))
if len(logs) != 1:
    sys.exit("expected exactly 1 stream .jsonl file, got %r" % logs)
raw = open(logs[0], "rb").read()
if not raw.endswith(b"\n"):
    sys.exit("stream log does not end with newline")
lines = raw.decode("utf-8").splitlines()
if len(lines) != 1:
    sys.exit("expected 1 line in stream log, got %d" % len(lines))
change = json.loads(lines[0])
rec_path = logs[0][:-len(".jsonl")] + ".json"
rec = json.load(open(rec_path, "r", encoding="utf-8"))
if rec.get("head") != change.get("id"):
    sys.exit("stream record head %r != change id %r" % (rec.get("head"), change.get("id")))
stage_path = os.path.join(share, "FLINT", "ws", "w", "STAGE.jsonl")
if os.path.exists(stage_path):
    sys.exit("expected STAGE.jsonl to be removed after commit")
print("run-03 stream log, head, and stage removal ok (change id=%s)" % change.get("id"))
PY

# ---- 04: M103c secret_not_found refusal on nosign-share ----------------------
vgate_run 04 -- \
    --cvc-file '$RUN_DIR/nosign-share' \
    --virtio-fs '$RUN_DIR/nosign-share' \
    --script '$RUN_DIR/script-04.txt' \
    --script-expect 'flint: refuse secret_not_found' \
    --script-expect-tail 3 --timeout 180

vgate_assert 04 serial-contains 'flint: init ok ws=w stream=main'
vgate_assert 04 serial-contains 'flint: add files=2 new=10 modified=0 deleted=0 unchanged=0'
vgate_assert 04 serial-contains 'flint: refuse secret_not_found'
vgate_assert 04 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import glob, os, sys

run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-04.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-04.out")

nosign = os.path.join(run, "nosign-share")
logs = glob.glob(os.path.join(nosign, "FLINT", "streams", "*.jsonl"))
if logs:
    sys.exit("expected no streams/*.jsonl on secret_not_found, found %r" % logs)
stage_path = os.path.join(nosign, "FLINT", "ws", "w", "STAGE.jsonl")
if not os.path.isfile(stage_path) or os.path.getsize(stage_path) == 0:
    sys.exit("expected STAGE.jsonl to remain intact on secret_not_found")
print("run-04 nosign-share hygiene ok (no stream log, STAGE.jsonl intact)")
PY

# ---- 05: M103d clean-share machine A base commit + fork main -> feature ------
vgate_run 05 -- \
    --cvc-file '$RUN_DIR/clean-share' \
    --virtio-fs '$RUN_DIR/clean-share' \
    --script '$RUN_DIR/script-05.txt' \
    --script-expect 'flint: fork ok stream=feature head=' \
    --script-expect-tail 3 --timeout 180

vgate_assert 05 serial-contains 'flint: init ok ws=a stream=main'
vgate_assert 05 serial-contains 'flint: add files=1 new=2 modified=0 deleted=0 unchanged=0'
vgate_assert 05 serial-contains 'flint: commit ok id='
vgate_assert 05 serial-contains 'flint: fork ok stream=feature head='
vgate_assert 05 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-05.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-05.out")
print("run-05 secret-absence ok")
PY

# ---- 06: M103d clean-share machine B init --stream=feature, edit X, commit ---
vgate_run 06 -- \
    --cvc-file '$RUN_DIR/clean-share' \
    --virtio-fs '$RUN_DIR/clean-share' \
    --script '$RUN_DIR/script-06.txt' \
    --script-expect 'flint: commit ok id=' \
    --script-expect-tail 3 --timeout 180

vgate_assert 06 serial-contains 'flint: init ok ws=b stream=feature atoms=2 replayed=1'
vgate_assert 06 serial-contains 'flint: add files=1 new=0 modified=1 deleted=0 unchanged=1'
vgate_assert 06 serial-contains 'flint: commit ok id='
vgate_assert 06 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-06.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-06.out")
print("run-06 secret-absence ok")
PY

# ---- 07: M103d clean-share machine A edit Y, commit, merge, re-merge, verify -
vgate_run 07 -- \
    --cvc-file '$RUN_DIR/clean-share' \
    --virtio-fs '$RUN_DIR/clean-share' \
    --script '$RUN_DIR/script-07.txt' \
    --script-expect 'flint: status ws=a' \
    --script-expect-tail 3 --timeout 180

vgate_assert 07 serial-contains 'flint: merge ok conflicts=0 ops=1 id='
vgate_assert 07 serial-contains 'flint: merge src not materialized files=1'
vgate_assert 07 serial-contains 'flint: merge up to date'
vgate_assert 07 serial-count 'sig: verified' 4
vgate_assert 07 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 python <<'PY'
import glob, json, os, sys

run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-07.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-07.out")

clean = os.path.join(run, "clean-share")
streams_dir = os.path.join(clean, "FLINT", "streams")
by_name = {}
for p in glob.glob(os.path.join(streams_dir, "*.json")):
    rec = json.load(open(p, "r", encoding="utf-8"))
    by_name[rec["name"]] = rec

if "main" not in by_name or "feature" not in by_name:
    sys.exit("missing main or feature stream record: %r" % list(by_name.keys()))

main_rec = by_name["main"]
feat_rec = by_name["feature"]
main_log = os.path.join(streams_dir, main_rec["id"] + ".jsonl")
lines = [json.loads(l) for l in open(main_log, "r", encoding="utf-8").read().splitlines() if l.strip()]
if len(lines) != 3:
    sys.exit("expected 3 changes in main log, got %d" % len(lines))

prev_change = lines[-2]
last_change = lines[-1]
if last_change.get("merged") != feat_rec.get("head"):
    sys.exit("last main change merged=%r != feature head=%r" % (last_change.get("merged"), feat_rec.get("head")))
if last_change.get("parent") != prev_change.get("id"):
    sys.exit("last main change parent=%r != previous main head=%r" % (last_change.get("parent"), prev_change.get("id")))
if main_rec.get("head") != last_change.get("id"):
    sys.exit("main record head=%r != last main change id=%r" % (main_rec.get("head"), last_change.get("id")))
print("run-07 clean merge log + head verified (merged=%s parent=%s)" % (last_change.get("merged"), last_change.get("parent")))
PY

# ---- 08: M103d conflict-share machine A base commit + fork main -> feature ---
vgate_run 08 -- \
    --cvc-file '$RUN_DIR/conflict-share' \
    --virtio-fs '$RUN_DIR/conflict-share' \
    --script '$RUN_DIR/script-08.txt' \
    --script-expect 'flint: fork ok stream=feature head=' \
    --script-expect-tail 3 --timeout 180

vgate_assert 08 serial-contains 'flint: init ok ws=a stream=main'
vgate_assert 08 serial-contains 'flint: add files=1 new=2 modified=0 deleted=0 unchanged=0'
vgate_assert 08 serial-contains 'flint: commit ok id='
vgate_assert 08 serial-contains 'flint: fork ok stream=feature head='
vgate_assert 08 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-08.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-08.out")
print("run-08 secret-absence ok")
PY

# ---- 09: M103d conflict-share machine B init --stream=feature, edit X --------
vgate_run 09 -- \
    --cvc-file '$RUN_DIR/conflict-share' \
    --virtio-fs '$RUN_DIR/conflict-share' \
    --script '$RUN_DIR/script-09.txt' \
    --script-expect 'flint: commit ok id=' \
    --script-expect-tail 3 --timeout 180

vgate_assert 09 serial-contains 'flint: init ok ws=b stream=feature atoms=2 replayed=1'
vgate_assert 09 serial-contains 'flint: add files=1 new=0 modified=1 deleted=0 unchanged=1'
vgate_assert 09 serial-contains 'flint: commit ok id='
vgate_assert 09 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-09.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-09.out")
print("run-09 secret-absence ok")
PY

# ---- 10: M103d conflict-share machine A edit X differently, merge -> conflict
vgate_run 10 -- \
    --cvc-file '$RUN_DIR/conflict-share' \
    --virtio-fs '$RUN_DIR/conflict-share' \
    --script '$RUN_DIR/script-10.txt' \
    --script-expect 'flint: merge conflicts=1' \
    --script-expect-tail 3 --timeout 180

vgate_assert 10 serial-contains 'flint: merge conflict atom=calc.X type=concurrent_modify'
vgate_assert 10 serial-contains 'flint: merge conflicts=1'
vgate_assert 10 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 python <<'PY'
import glob, json, os, sys

run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-10.out"), errors="replace").read()
if "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" in out:
    sys.exit("FAIL: signing seed hex reached run-10.out")

conflict_share = os.path.join(run, "conflict-share")
streams_dir = os.path.join(conflict_share, "FLINT", "streams")
by_name = {}
for p in glob.glob(os.path.join(streams_dir, "*.json")):
    rec = json.load(open(p, "r", encoding="utf-8"))
    by_name[rec["name"]] = rec

main_rec = by_name["main"]
main_log = os.path.join(streams_dir, main_rec["id"] + ".jsonl")
lines = [json.loads(l) for l in open(main_log, "r", encoding="utf-8").read().splitlines() if l.strip()]
if len(lines) != 2:
    sys.exit("expected 2 changes in main log (nothing appended on conflict), got %d" % len(lines))
if main_rec.get("head") != lines[-1].get("id"):
    sys.exit("main record head=%r != last log line id=%r" % (main_rec.get("head"), lines[-1].get("id")))

merge_path = os.path.join(conflict_share, "FLINT", "ws", "a", "MERGE.json")
if not os.path.isfile(merge_path):
    sys.exit("missing " + merge_path)
report = json.load(open(merge_path, "r", encoding="utf-8"))
conflicts = report.get("conflicts", [])
if len(conflicts) != 1 or conflicts[0].get("name") != "calc.X" or conflicts[0].get("type") != "concurrent_modify":
    sys.exit("unexpected MERGE.json conflicts: %r" % (conflicts,))
print("run-10 conflict MERGE.json and unchanged main log/head verified")
PY

# ---- 11: M101a hermetic sync — ls-remote + clone land the stream ------------
vgate_run 11 -- \
    --cvc-file '$RUN_DIR/sync-share' \
    --virtio-fs '$RUN_DIR/sync-share' \
    --net '$RUN_DIR/cap11.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-11.txt' \
    --script-expect 'flint: clone ok stream=main changes=1' \
    --script-expect-tail 3 --timeout 180

vgate_assert 11 serial-contains 'flint: stream main id=0199de2d-dc00-7000-8000-00000000a010 head=0199de2d-dc00-7000-8000-00000000a001'
vgate_assert 11 serial-contains 'flint: clone ok stream=main changes=1'
vgate_assert 11 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 11 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 python <<'PY'
import json, os, sys

run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-11.out"), errors="replace").read()
for leaked in (
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    "ab" * 32,
):
    if leaked in out:
        sys.exit("FAIL: secret hex reached run-11.out")

share = os.path.join(run, "sync-share")
log_path = os.path.join(
    share, "FLINT", "streams", "0199de2d-dc00-7000-8000-00000000a010.jsonl"
)
if not os.path.isfile(log_path):
    sys.exit("missing " + log_path)
got = open(log_path, "rb").read()
want = open(
    os.path.join("user", "go", "flint", "testdata", "sync", "seed-stream.jsonl"), "rb"
).read()
if got != want:
    sys.exit("cloned streams/<id>.jsonl is not byte-verbatim")
rec = json.load(
    open(
        os.path.join(
            share, "FLINT", "streams",
            "0199de2d-dc00-7000-8000-00000000a010.json",
        ),
        "r",
        encoding="utf-8",
    )
)
if rec.get("head") != "0199de2d-dc00-7000-8000-00000000a001":
    sys.exit("stream record head %r != pinned change id" % rec.get("head"))
remote = open(os.path.join(share, "FLINT", "REMOTE.json"), "r", encoding="utf-8").read()
if '"remote":"tcp://10.0.0.2:4749"' not in remote or '"stream":"0199de2d-dc00-7000-8000-00000000a010"' not in remote:
    sys.exit("REMOTE.json does not bind the clone: %r" % remote)
print("run-11 clone landed verbatim raw JSONL, rolled the record head, and wrote REMOTE.json")
PY

# ---- 12: M101a — same share, fresh boot: verify --all + REMOTE.json pull -----
vgate_run 12 -- \
    --cvc-file '$RUN_DIR/sync-share' \
    --virtio-fs '$RUN_DIR/sync-share' \
    --net '$RUN_DIR/cap12.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-12.txt' \
    --script-expect 'flint: pull up to date' \
    --script-expect-tail 3 --timeout 180

vgate_assert 12 serial-count 'sig: verified' 2
vgate_assert 12 serial-contains 'flint: pull up to date'
vgate_assert 12 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 12 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 12 serial-absent '[EXC] parking:'

# ---- 13: M101a refusal leg — wrong flint-remote secret → auth_failed ---------
vgate_run 13 -- \
    --cvc-file '$RUN_DIR/badauth-share' \
    --virtio-fs '$RUN_DIR/badauth-share' \
    --net '$RUN_DIR/cap13.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-13.txt' \
    --script-expect 'flint: refuse auth_failed' \
    --script-expect-tail 3 --timeout 180

vgate_assert 13 serial-contains 'flint: refuse auth_failed'
vgate_assert 13 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 13 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 13 serial-absent 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 python <<'PY'
import os, sys

run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-13.out"), errors="replace").read()
for leaked in (
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    "ab" * 32,
    "cd" * 32,
):
    if leaked in out:
        sys.exit("FAIL: secret hex reached run-13.out")

share = os.path.join(run, "badauth-share")
if os.path.exists(os.path.join(share, "FLINT")):
    sys.exit("auth_failed clone wrote a store under badauth-share/FLINT")
print("run-13 auth_failed leg wrote nothing")
PY

# ---- 14: M101c consumer — ls, verify-then-install, launch ------------------
vgate_run 14 -- \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap14.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-14.txt' \
    --script-expect 'virelai-go OK' \
    --script-expect-tail 3 --timeout 300

vgate_assert 14 serial-contains 'store: stream main no-release'
vgate_assert 14 serial-contains 'store: stream rel release'
vgate_assert 14 serial-contains 'store: stream badkey sync-failed'
vgate_assert 14 serial-contains 'store: stream revkey sync-failed'
vgate_assert 14 serial-contains 'store: ls ok'
vgate_assert 14 serial-contains 'sig: verified'
vgate_assert 14 serial-contains 'store: install ok GOHELLO.ELF version=1.0.0'
vgate_assert 14 serial-contains 'virelai-go OK'
# M101e: the untrusted-publisher streams are refused by the keyring inside
# the same boot as the happy path — `store ls` tolerates them per-stream.
vgate_assert 14 serial-count 'flint: refuse key_unknown' 1
vgate_assert 14 serial-count 'flint: refuse key_revoked' 1
vgate_assert 14 serial-absent 'store: refuse'
vgate_assert 14 serial-absent 'sig_invalid'
vgate_assert 14 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 14 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 python <<'PY'
import hashlib, os, re, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
elf = os.path.join(share, "GOHELLO.ELF")
if not os.path.isfile(elf):
    sys.exit("GOHELLO.ELF missing at share root after install")
got = hashlib.sha256(open(elf, "rb").read()).hexdigest()
want = hashlib.sha256(open(os.path.join(".build", "go", "GOHELLO.ELF"), "rb").read()).hexdigest()
if got != want:
    sys.exit("installed GOHELLO.ELF hash %s != built %s" % (got, want))
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if apps.count("GOHELLO.ELF |") != 1:
    sys.exit("expected exactly one GOHELLO row in APPS.TXT: %r" % apps)

ser = open(os.environ["VG_SER"], errors="replace").read()
for m in re.finditer(r"flint: refuse (\S+)", ser):
    if m.group(1) not in ("key_unknown", "key_revoked"):
        sys.exit("unexpected flint refusal on the happy-path run: %s" % m.group(1))
for sid in ("0199de2d-dc00-7000-8000-00000000e010",
            "0199de2d-dc00-7000-8000-00000000e011"):
    if os.path.exists(os.path.join(share, "FLINT", "streams", sid + ".jsonl")):
        sys.exit("key-refused clone wrote a local replica for " + sid)
print("run-14 installed ELF bytes verified; key_unknown/key_revoked refused with zero local state")
PY

# ---- 15: M101e update — advance the replica, publish v2, roll back to v1 -
vgate_run 15 -- \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap15.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-15.txt' \
    --script-expect 'virelai-go OK' \
    --script-expect-tail 3 --timeout 300

vgate_assert 15 serial-contains 'flint: pull up to date'
vgate_assert 15 serial-count 'sig: verified' 3
vgate_assert 15 serial-contains 'store: update ok GOHELLO.ELF version=2.0.0'
vgate_assert 15 serial-contains 'virelai-go V2'
vgate_assert 15 serial-contains 'store: rollback ok GOHELLO.ELF head=0199de2d-dc00-7000-8000-00000000c001'
vgate_assert 15 serial-absent 'store: refuse'
vgate_assert 15 serial-absent 'flint: refuse'
vgate_assert 15 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 15 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 15 serial-absent '[EXC] parking:'
vgate_assert 15 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
ser = open(os.environ["VG_SER"], errors="replace").read()

marks = ["store: update ok GOHELLO.ELF version=2.0.0",
         "virelai-go V2",
         "store: rollback ok GOHELLO.ELF",
         "virelai-go OK"]
pos = -1
for m in marks:
    i = ser.find(m, pos + 1)
    if i < 0:
        sys.exit("missing or out-of-order marker: " + m)
    pos = i

v1 = open(os.path.join(".build", "go", "GOHELLO.ELF"), "rb").read()
v1sha = hashlib.sha256(v1).hexdigest()
v2 = open(os.path.join(run, "fixtures", "gohello-v2.elf"), "rb").read()
v2sha = hashlib.sha256(v2).hexdigest()

live = open(os.path.join(share, "GOHELLO.ELF"), "rb").read()
if live != v1:
    sys.exit("post-rollback GOHELLO.ELF is not the v1 bytes")
prev = open(os.path.join(share, "GOHELLO.ELF.prev"), "rb").read()
if prev != v2:
    sys.exit("post-rollback .prev is not the replaced v2 bytes")

want_state = ("#v1\n"
              "name=GOHELLO.ELF stream=rel "
              "head=0199de2d-dc00-7000-8000-00000000c001 "
              "sha256=" + v1sha + " "
              "prev_head=0199de2d-dc00-7000-8000-00000000c002 "
              "prev_sha256=" + v2sha + " "
              "prev_row=GOHELLO.ELF | Go Hello | g | dock=false\n")
got_state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if got_state != want_state:
    sys.exit("STORE.TXT after update+rollback:\n" + got_state + "\nwant:\n" + want_state)
print("run-15 update published v2, ran it, rollback restored v1 bytes")
PY

# ---- 16: M101e update negatives — refused update touches nothing, torn ---
# ---- publish makes update AND rollback refuse state_mismatch ------------
vgate_run 16 -- \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap16.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-16.txt' \
    --script-expect 'm101e: torn-state legs done' \
    --script-expect-tail 3 --timeout 300

vgate_assert 16 serial-contains 'store: refuse elf_mismatch GOHELLO.ELF'
vgate_assert 16 serial-contains 'store: refuse prev_mismatch GOHELLO.ELF'
vgate_assert 16 serial-exact 'store: refuse state_mismatch GOHELLO.ELF' 2
vgate_assert 16 serial-absent 'store: update ok'
vgate_assert 16 serial-absent 'store: rollback ok'
vgate_assert 16 serial-absent 'flint: refuse'
vgate_assert 16 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 16 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 16 serial-absent '[EXC] parking:'
vgate_assert 16 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")

v1 = open(os.path.join(".build", "go", "GOHELLO.ELF"), "rb").read()
v1sha = hashlib.sha256(v1).hexdigest()
v2 = open(os.path.join(run, "fixtures", "gohello-v2.elf"), "rb").read()
v2sha = hashlib.sha256(v2).hexdigest()

# The tears staged by the script's `echo >>` appends: the retained .prev
# diverged from prev_sha256 (the prev_mismatch leg) and the live ELF
# diverged from the recorded v1 sha256 — exactly the divergent-but-
# detected shape a kill between the ELF write and the state write leaves.
live = open(os.path.join(share, "GOHELLO.ELF"), "rb").read()
if live != v1 + b"y\n":
    sys.exit("torn leg: GOHELLO.ELF is not the v1 bytes plus the appended line")
prev = open(os.path.join(share, "GOHELLO.ELF.prev"), "rb").read()
if prev != v2 + b"x\n":
    sys.exit("torn leg: .prev is not the v2 bytes plus the appended line")
want_state = ("#v1\n"
              "name=GOHELLO.ELF stream=rel "
              "head=0199de2d-dc00-7000-8000-00000000c001 "
              "sha256=" + v1sha + " "
              "prev_head=0199de2d-dc00-7000-8000-00000000c002 "
              "prev_sha256=" + v2sha + " "
              "prev_row=GOHELLO.ELF | Go Hello | g | dock=false\n")
got_state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if got_state != want_state:
    sys.exit("tracked state moved under refused updates/rollback:\n" + got_state)
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if apps.count("GOHELLO.ELF |") != 1:
    sys.exit("manifest moved under refused updates/rollback: %r" % apps)
print("run-16 elf_mismatch + torn-state legs left tracked bytes untouched")
PY

# ---- 17: M101e remove + install negatives — tampered ELF/release, --------
# ---- unknown + revoked publisher keys, zero partial state ---------------
vgate_run 17 -- \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap17.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-17.txt' \
    --script-expect 'm101e: negatives done' \
    --script-expect-tail 3 --timeout 300

vgate_assert 17 serial-contains 'store: remove ok GOHELLO.ELF'
vgate_assert 17 serial-contains 'store: refuse elf_mismatch GOHELLO.ELF'
vgate_assert 17 serial-contains 'store: refuse release_mismatch'
vgate_assert 17 serial-count 'flint: refuse key_unknown' 1
vgate_assert 17 serial-count 'flint: refuse key_revoked' 1
vgate_assert 17 serial-count 'store: refuse sync_failed' 2
vgate_assert 17 serial-absent 'store: install ok'
vgate_assert 17 serial-absent 'store: update ok'
vgate_assert 17 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 17 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 17 serial-absent '[EXC] parking:'
vgate_assert 17 python <<'PY'
import os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
if os.path.exists(os.path.join(share, "GOHELLO.ELF")):
    sys.exit("GOHELLO.ELF present at share root after remove + refused installs")
if os.path.exists(os.path.join(share, "GOHELLO.ELF.prev")):
    sys.exit("GOHELLO.ELF.prev left behind after remove")
apps_path = os.path.join(share, "APPS.TXT")
if os.path.exists(apps_path) and "GOHELLO.ELF" in open(apps_path, "r", encoding="utf-8").read():
    sys.exit("GOHELLO row present in APPS.TXT after remove + refused installs")
state_path = os.path.join(share, "STORE.TXT")
if os.path.exists(state_path) and "GOHELLO" in open(state_path, "r", encoding="utf-8").read():
    sys.exit("GOHELLO entry present in STORE.TXT after remove")
for sid in ("0199de2d-dc00-7000-8000-00000000e010",
            "0199de2d-dc00-7000-8000-00000000e011"):
    if os.path.exists(os.path.join(share, "FLINT", "streams", sid + ".jsonl")):
        sys.exit("key-refused clone wrote a local replica for " + sid)
if os.path.exists(os.path.join(share, "STORECAP.OUT")):
    sys.exit("store left its FLINT capture scratch file behind")
print("run-17 remove + all four refused installs left zero partial state")
PY
