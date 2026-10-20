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
# Runs 18-19 (M110b #2404): the signed catalog. The `rel` fixture now
# carries ADR 0055's optional consts (summary/description/category); a
# SECOND publisher key (pinned `name=acme` in TRUSTED.TXT) signs stream
# `rel2` whose release carries every catalog field including a pinned
# icon blob; and stream `legacy` ships a bare four-const manifest. Run
# 18 renders the catalog — `store ls` folds each release stream's consts
# + derived publisher fingerprint, --category/--search filter it, and
# `store info rel2` renders the detail card. Run 19 is the refusal leg —
# `store info rel` against a tampered-description drop refuses
# release_mismatch — plus the legacy release installing + execing. They
# split across boots because a socket-heavy catalog pass depletes the
# task pool for the reaper's schedule (the same race that split the
# M101a sync runs — observed: `newosproc`/`wait failed` ate the install
# execs when one boot ran six store verbs).
#
# Runs 20-21 (M110d #2406): the third-party publisher drill on a FRESH
# share (tp-share, the runs 05-07 --cvc-file pattern). The acme key
# signs a THIRD release stream `acme` whose ELF is the fixture app
# (tools/gate/fixtures/third-party-app/acmeapp.go — an in-repo stand-in
# for a foreign publisher's program, built per run by the setup hook so
# its sha256 always matches the signed manifest). `acme` is served on
# the same flintd as every other release stream — one remote, one lane:
# a second listener on its own port is only a second process for a
# sibling gate's lsof-sweep to murder mid-suite (observed: a foreign
# gate's flintd answered for this spec's second listener the first time
# these runs were attempted). Its replica is staged on store-share too
# (run 14's catalog now lists the acme publisher's second app, so the
# 4-entry count is the honest one). tp-share is the fresh consumer —
# its own APPS.TXT/STORE.TXT, every release replica staged verbatim (the
# staged-bytes seam; without them `store ls` would try to clone a
# release-sized Change), the drops, and a TRUSTED.TXT that pins
# sync-seed + acme and revokes revkey's author, plus a staged variant
# with acme moved to a revoked= row. Run 20 is the run-14 shape on the
# fresh share: the catalog lists the acme entry, `store install acme`
# verifies + publishes ACMEAPP.ELF, and the app runs (`acme-app OK` —
# asserted on run 21's fresh boot: the exec right after a socket-heavy
# install is the shape the task-pool race eats, observed `gosh:
# ACMEAPP.ELF: not found` on a green install). Run 21 is the
# install-time negatives by name: `store install badkey`/`revkey`
# clone over the wire and refuse key_unknown/key_revoked inside
# FLINT.ELF; then the in-guest keyring swap revokes the acme publisher
# AFTER its app was published AND installed — `store install acme` now
# refuses key_revoked at the verify --all --trusted gate, the strongest
# form of "revoked after publish" (an already-synced release refused at
# materialization; the installed bytes stay, revocation gates only new
# installs). The legs split across boots for the same task-pool reason
# as runs 18-19.
#
# Runs 22-24 (M113d #2420, ADR 0054 D10): ReleaseCaps declare + consent
# on a fresh `caps-share` under the bare shim (wm=none — the go-calc
# drive shape: GOSET.ELF is typed via --input-string). `caprel` is
# a signed release stream whose manifests carry ReleaseCaps: v1 asks
# file,net, v2 narrows to file, v3 widens to file,debug,net. Run 22
# installs it unprivileged (STORE can only `grant propose` — the admin
# slot refuses it EACCES), execs GOHELLO at the ambient baseline, then
# GOSET -u0 (the monitor's admin spawn — CAP_PROC_ADMIN, the
# cap half of the seat-or-cap gate) opens the grants pane: `refuse`
# declines without a write, `grant` lands (bin, sha, words) through slot
# 89. Run 23's non-widening update re-pins the row to the new image with
# the consented words verbatim (`store: grant keep`, no fresh ask). Run
# 24's widening update leaves the row stale — the unconsented v3 image
# refuses `grant_stale` at exec — until the pane's re-consent binds the
# widened set.
#
# Runs 26-27 (M138c #2777): history surface on a dedicated `hist-share` —
# the clean-share two-workspace shape (base on main, fork feature, X:=10 on
# feature, Y:=20 on main, merge back). Run 26 builds the DAG and exercises
# `flint blame` (per-line change-id + author attribution through the atom
# table), `flint log --graph` (ASCII lanes over parent+merged edges), and
# `flint tag` create/list. Run 27 re-boots the SAME share so `tag -l`
# proves TAGS.jsonl persisted, then `tag -d` empties it.
#
# Run 25 (M113f #2422): the acceptance chain — ONE app taken end to end
# in ONE boot on a pristine copy of the caps-share staging (runs 22-24
# mutate that share). The guest script installs caprel (the signed
# ReleaseCaps — `store: grant propose`), runs GOSET in the -u0 gosh so
# the seat-cap consent lands the hash-bound row, execs GOHELLO under
# the row (verdict=measured + audit:<word>_denied receipts for the
# words its image actually touches outside file,net), and renders
# GOTOP's trust tab — declare -> consent -> measured exec -> audit
# receipt -> viewer, the #2422 chain verbatim. GOSET is inside the
# .SH (not a monitor spawn) so the confined exec and the viewer come
# after it in guest-script order; the typed consent goes over
# --input-chords (the burst ends on `escape` to hand the console back)
# and GOTOP's tab switch is the --input-string slot.
#
# This spec is grown across M103a-d/M101a-e + M110b/d + M113d + M113f
# and is NOT vgate_repeat-safe (runs 01-03, 05-07, 08-10, 14-21, and
# 22-25 share /host state across boots).
#
# HOST PREREQ:
#   bash tools/go/build-flint.sh -> .build/go/FLINT.ELF
#   bash tools/go/build-gosh.sh  -> .build/go/GOSH.ELF
#   bash tools/go/build-store.sh -> .build/go/STORE.ELF
#   bash tools/go/build-go.sh    -> .build/go/GOHELLO.ELF
#   bash tools/go/build-goset.sh -> .build/go/GOSET.ELF       (runs 22/24)
#   bash tools/go/build-gotop.sh -> .build/go/GOTOP.ELF       (run 25)
#   (no seat: wm=none keeps every EL0 slot for the Go legs)
#   ../flint-server checkout (or FLINT_SERVER_DIR=...) for runs 11-17 only;
#   the hook zig-builds flintd. flint-server is drawmeanelephant's repo under
#   the VirelaiOS proprietary source-available license (not GPL-family).
#   The setup hook builds the M110d fixture app itself
#   (tools/gate/fixtures/third-party-app/acmeapp.go ->
#   .build/go/ACMEAPP.ELF via build-go.sh + the fork toolchain).
#
# exec-order: assert-proven -- run 01 ends on `flint: parse files=`, run 02
# ends on `flint: status `, run 03 ends on `sig_invalid`, run 04 ends on
# `flint: refuse secret_not_found`, runs 05/08 end on `flint: fork ok`, runs
# 06/09 end on `flint: commit ok`, run 07 ends on `flint: status ws=a`, run
# 10 ends on `flint: merge conflicts=1`, run 11 ends on `flint: clone ok`,
# run 12 ends on `flint: pull up to date`, run 13 ends on `flint: refuse
# auth_failed`, runs 14/15 end on `virelai-go OK` (the v1 install, then the
# rollback restoring it), run 16 ends on `m101e: torn-state legs done`, run
# 17 ends on `m101e: negatives done`, run 18 ends on `m110b: catalog ls
# done`, run 19 ends on `m110b: catalog legs done`, run 20 ends on `m110d:
# install done`, and run 21 ends on `m110d: negatives done`. Runs 22/24
# end on `goset: grant written name=GOHELLO.ELF`; run 23 ends on `m113d:
# keep done`; run 25 ends on GOTOP's rendered trust-app marker for the
# confined GOHELLO.ELF — the last program output in the chain (every
# asserted line is program output).

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
exec GOSH.ELF -c "STORE.ELF ls --remote=10.0.0.2:4749 --channel=/host/DROP;STORE.ELF install rel --remote=10.0.0.2:4749 --channel=/host/DROP;GOHELLO.ELF"
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

vgate_file script-18.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/18.SH"
EOF

vgate_file script-19.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/19.SH"
EOF

vgate_file script-20.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/20.SH"
EOF

vgate_file script-21.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF -c "source /host/FLINTJ/21.SH"
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

# Runs 26-27 (M138c #2777): hist-share — blame, log --graph, and tags.
# Same two-workspace fork+merge shape as clean-share: base on main, fork
# feature, X:=10 on feature, Y:=20 on main, merge -> the DAG carries one
# fork lane and one merge edge. Run 26 builds history and exercises the
# new verbs; run 27 re-boots the SAME share so `tag -l` proves the tag
# file survived (and blame/graph re-render over the persisted store).
hist_share = os.path.join(run, "hist-share")
for sub in ("SRCA", "SRCB", "FLINTJ"):
    os.makedirs(os.path.join(hist_share, sub), exist_ok=True)
for name in ("FLINT.ELF", "GOSH.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(hist_share, name))
open(os.path.join(hist_share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nagent-sign\t1000\t" + SEED_HEX + "\tFLINT.ELF\n"
)
open(os.path.join(hist_share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\n"
)
open(os.path.join(hist_share, "SRCA", "calc.go"), "w", encoding="utf-8").write(base_calc)
open(os.path.join(hist_share, "SRCB", "calc.go"), "w", encoding="utf-8").write(base_calc)
open(os.path.join(hist_share, "FLINTJ", "edit-b.go"), "w", encoding="utf-8").write(edit_x_feat)
open(os.path.join(hist_share, "FLINTJ", "edit-a.go"), "w", encoding="utf-8").write(edit_y_main)
open(os.path.join(hist_share, "FLINTJ", "26.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF init --name=a --src=/host/SRCA\n"
    "FLINT.ELF add /host/SRCA\n"
    "FLINT.ELF commit -m base\n"
    "FLINT.ELF fork main feature\n"
    "FLINT.ELF init --name=b --src=/host/SRCB --stream=feature\n"
    "cat /host/FLINTJ/edit-b.go > /host/SRCB/calc.go\n"
    "FLINT.ELF add /host/SRCB\n"
    "FLINT.ELF commit --ws=b -m feat\n"
    "cat /host/FLINTJ/edit-a.go > /host/SRCA/calc.go\n"
    "FLINT.ELF add /host/SRCA\n"
    "FLINT.ELF commit -m main\n"
    "FLINT.ELF merge feature\n"
    "FLINT.ELF tag --ws=a v1\n"
    "FLINT.ELF tag -l\n"
    "FLINT.ELF log --graph --stream=main\n"
    "FLINT.ELF blame --ws=a /host/SRCA/calc.go\n"
    "echo M138C-1-DONE\n"
)
open(os.path.join(hist_share, "FLINTJ", "27.SH"), "w", encoding="utf-8").write(
    "FLINT.ELF tag -l\n"
    "FLINT.ELF log --graph --stream=main\n"
    "FLINT.ELF blame --ws=a /host/SRCA/calc.go\n"
    "FLINT.ELF tag -d v1\n"
    "FLINT.ELF tag -l\n"
    "echo M138C-2-DONE\n"
)
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

# M110d (#2406): the third-party fixture app. Built per run with the
# same fork toolchain path as the other guests so the signed release
# manifest's sha256 always matches the delivered ELF — a frozen fixture
# would go stale the way the release fixture does (the guest build is
# not bit-reproducible). GO_BUILD_NAME pins the gate-canonical output
# name; the program is a runtime-only println app like tools/go/hello.go.
subprocess.check_call(
    ["bash", "tools/go/build-go.sh",
     "tools/gate/fixtures/third-party-app/acmeapp.go"],
    env={**os.environ, "GO_BUILD_NAME": "ACMEAPP"})
acme_elf = os.path.join(".build", "go", "ACMEAPP.ELF")
if not os.path.isfile(acme_elf):
    sys.exit("ACMEAPP.ELF missing after build-go.sh (expected " + acme_elf + ")")
acme_bytes = open(acme_elf, "rb").read()

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
# M110b (#2404): the v1/v2 manifests carry ADR 0055's optional signed
# catalog consts — summary + description + category — so `store ls`/`info`
# render them out of the signed atoms. A second publisher (rel2) and a
# bare four-const legacy stream join the catalog below.
REL_SUMMARY = "Go Hello greets VirelaiOS"
REL_DESCRIPTION = ("Go Hello prints a greeting over the serial console.\n"
                   "It is the fleet's smallest signed release.")
REL_CATEGORY = "demo"
gen = subprocess.run(
    ["go", "test", "./store", "-run", "TestGenReleaseFixture", "-count=1"],
    cwd="user/go",
    env={**os.environ, "STORE_GEN_FIXTURE": "1",
         "STORE_FIXTURE_SUMMARY": REL_SUMMARY,
         "STORE_FIXTURE_DESCRIPTION": REL_DESCRIPTION,
         "STORE_FIXTURE_CATEGORY": REL_CATEGORY},
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

def write_drop(drop, rel_text, elf, sname="rel", bin_name="GOHELLO.ELF"):
    d = os.path.join(store_share, drop, sname)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "release.go"), "w", encoding="utf-8").write(rel_text)
    open(os.path.join(d, bin_name), "wb").write(elf)

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


# The v2 manifest keeps v1's catalog consts (the parented-Change diff
# reconstructs the parent release.go with the same optional set — see
# fixture_gen_test.go's env-knob comment).
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.join(fixture_dir, "gohello-v2.elf"),
    "STORE_FIXTURE_VERSION": "2.0.0",
    "STORE_FIXTURE_PARENT": rel_change["id"],
    "STORE_FIXTURE_PREV_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_PREV_VERSION": "1.0.0",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c002",
    "STORE_FIXTURE_TS": "1760000100000",
    "STORE_FIXTURE_SUMMARY": REL_SUMMARY,
    "STORE_FIXTURE_DESCRIPTION": REL_DESCRIPTION,
    "STORE_FIXTURE_CATEGORY": REL_CATEGORY,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "v2",
})

# M110b (#2404): the two-publisher catalog. A second publisher key signs
# stream `rel2` — BOUNCE carries every ADR 0055 catalog field including a
# ReleaseIconSHA256 pin naming the <stream>/icon channel blob (D7) — and
# stream `legacy` ships a bare four-const manifest (D4 backward-compat:
# a v1-format release still installs).
ICON_BLOB = (b"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 8'>"
             b"<rect width='8' height='8' fill='#36c'/>"
             b"<circle cx='4' cy='4' r='3' fill='#fff'/></svg>\n")
icon_sha = hashlib.sha256(ICON_BLOB).hexdigest()
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_NAME": "BOUNCE",
    "STORE_FIXTURE_VERSION": "1.4.0",
    "STORE_FIXTURE_ROW": "BOUNCE.ELF | Bounce | g | dock=false",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000b011",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c010",
    "STORE_FIXTURE_TS": "1760000400000",
    "STORE_FIXTURE_MSG": "bounce release",
    "STORE_FIXTURE_SEED_HEX": "b3" * 32,
    "STORE_FIXTURE_SUMMARY": "A bouncing ball demo",
    "STORE_FIXTURE_DESCRIPTION": ("Bounce renders a ball on the desktop.\n"
                                  "Shipped by a second publisher."),
    "STORE_FIXTURE_CATEGORY": "game",
    "STORE_FIXTURE_ICON_SHA256": icon_sha,
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "rel2",
})
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_NAME": "LEGACY",
    "STORE_FIXTURE_VERSION": "0.9.0",
    "STORE_FIXTURE_ROW": "LEGACY.ELF | Legacy | g | dock=false",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000b012",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c011",
    "STORE_FIXTURE_TS": "1760000500000",
    "STORE_FIXTURE_MSG": "legacy four-const release",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "legacy",
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

# M110d (#2406): the acme publisher's own app on stream `acme` — signed
# by the same second-publisher seed as rel2 (the keyring's name=acme
# row), carrying the ADR 0055 catalog consts, pinning the just-built
# ACMEAPP.ELF.
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.abspath(acme_elf),
    "STORE_FIXTURE_NAME": "ACMEAPP",
    "STORE_FIXTURE_VERSION": "1.0.0",
    "STORE_FIXTURE_ROW": "ACMEAPP.ELF | Acme App | x | dock=false",
    "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000b013",
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c012",
    "STORE_FIXTURE_TS": "1760000600000",
    "STORE_FIXTURE_MSG": "acme app release",
    "STORE_FIXTURE_SEED_HEX": "b3" * 32,
    "STORE_FIXTURE_SUMMARY": "Acme's first VirelaiOS app",
    "STORE_FIXTURE_DESCRIPTION": ("Acme App greets the guest from a\n"
                                  "second publisher key."),
    "STORE_FIXTURE_CATEGORY": "app",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "acme",
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
rel2_ch, rel2_line = load_gen_change("rel2")
legacy_ch, legacy_line = load_gen_change("legacy")
acme_ch, acme_line = load_gen_change("acme")
rel2_go = open(os.path.join(fixture_dir, "release-rel2.go"),
               "r", encoding="utf-8").read()
legacy_go = open(os.path.join(fixture_dir, "release-legacy.go"),
                 "r", encoding="utf-8").read()
acme_go = open(os.path.join(fixture_dir, "release-acme.go"),
               "r", encoding="utf-8").read()

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

# M110b: flintd also serves the second publisher's `rel2` and the legacy
# `legacy` stream; the consumer replica is staged verbatim like `rel`'s
# (the wire `read` cannot carry a release-sized Change — spec header).
# M110d: `acme` joins the same store — the acme publisher's second app —
# served + staged like the others.
for ch, line, sname in ((rel2_ch, rel2_line, "rel2"),
                        (legacy_ch, legacy_line, "legacy"),
                        (acme_ch, acme_line, "acme")):
    for store_root in (flintd_store, os.path.join(store_share, "FLINT")):
        with open(os.path.join(store_root, "streams", ch["stream"] + ".jsonl"), "w") as f:
            f.write(line + "\n")
        with open(os.path.join(store_root, "streams", ch["stream"] + ".json"), "w") as f:
            f.write(json.dumps(
                {"id": ch["stream"], "name": sname, "head": ch["id"],
                 "created": ch["ts"], "forked_from": None},
                separators=(",", ":")) + "\n")

# The consumer keyring keeps the release author pinned, gains the second
# publisher (rel2's author, labeled acme — ADR 0055 D5's trusted display
# name), and a revoked= row for revkey's author; badkey's author stays
# absent (key_unknown).
with open(os.path.join(store_share, "FLINT", "TRUSTED.TXT"),
          "a", encoding="utf-8") as f:
    f.write("key=" + rel2_ch["author"] + " name=acme\n")
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

# M110b drops: the second publisher's stream + icon blob (the D7 member
# `<stream>/icon` — pinned, fetched on demand, never by install/ls), the
# legacy four-const stream, and a drop whose rel release.go carries a
# tampered ReleaseDescription (the atom hash moves off the signed set ->
# release_mismatch).
write_drop("DROP", rel2_go, elf_bytes, sname="rel2", bin_name="BOUNCE.ELF")
open(os.path.join(store_share, "DROP", "rel2", "icon"), "wb").write(ICON_BLOB)
write_drop("DROP", legacy_go, elf_bytes, sname="legacy", bin_name="LEGACY.ELF")
# M110d: the acme app's drop — `store ls` folds its manifest on
# store-share the same way as the other release streams.
write_drop("DROP", acme_go, acme_bytes, sname="acme", bin_name="ACMEAPP.ELF")
desc_tampered = release_v2_go.replace("smallest signed release",
                                      "smallest unsigned release")
assert desc_tampered != release_v2_go
# DROPBADDESC is the full DROP with only rel's release.go tampered, so a
# catalog `ls` over it refuses rel's entry (release_mismatch) at ANY
# replica head — the v1-vs-v2 mismatch the DROP copy would show depends
# on run 15's record advance landing on the share, which the virtio-fs
# window has lost once (observed: run 18's ls silently filtered rel).
shutil.copytree(os.path.join(store_share, "DROP"),
                os.path.join(store_share, "DROPBADDESC"))
write_drop("DROPBADDESC", desc_tampered, elf_v2)

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
    # 18 (M110b): the signed catalog — the --category listing plus the
    # two-publisher detail card. Six back-to-back store verbs in one boot
    # lost execs to the task-pool reclamation race (observed `newosproc`
    # + `wait failed`), so the catalog legs split across boots like the
    # M101a sync runs did. NOTE: do NOT pace with gosh `sleep` — bSleep
    # parks 100·n ticks (~100 s per unit, a pre-existing quirk in
    # user/go/shlib/builtins.go) and two `sleep 2` lines consumed an
    # entire 300 s run budget (observed).
    "18.SH": (
        "STORE.ELF ls --remote=10.0.0.2:4749 --channel=/host/DROP --category=game\n"
        "STORE.ELF info rel2 --remote=10.0.0.2:4749 --channel=/host/DROP\n"
        "echo m110b: catalog ls done\n"
    ),
    # 19 (M110b): the --search listing, the tampered-description refusal,
    # and the legacy four-const install, on a fresh boot so the run-18
    # sockets can't starve the install's execs. The ls runs over
    # DROPBADDESC: the tampered v2 manifest mismatches the signed atom
    # set at whatever head the replica stands at, so rel's
    # catalog-invalid marker does not depend on run 15's record advance
    # surviving the share.
    "19.SH": (
        "STORE.ELF ls --remote=10.0.0.2:4749 --channel=/host/DROPBADDESC --search=bounce\n"
        "STORE.ELF info rel --remote=10.0.0.2:4749 --channel=/host/DROPBADDESC\n"
        "STORE.ELF install legacy --remote=10.0.0.2:4749 --channel=/host/DROP\n"
        "LEGACY.ELF\n"
        "echo m110b: catalog legs done\n"
    ),
}
for sname, sbody in flintj_m101e.items():
    open(os.path.join(store_share, "FLINTJ", sname),
         "w", encoding="utf-8").write(sbody)


# ---- M110d (#2406): the third-party publisher drill -------------------
# The fresh consumer share: its own APPS.TXT/STORE.TXT, the FULL release
# replica set staged verbatim (the wire `read` cannot carry a
# release-sized Change — the spec header's staged-bytes seam), the
# per-stream drops `store ls` folds, and a keyring that pins sync-seed +
# acme and revokes revkey's author while badkey's stays absent. The
# revoked variant run 21 swaps in moves acme itself to a revoked= row —
# revocation AFTER publish, exercised at materialization.
tp_share = os.path.join(run, "tp-share")
os.makedirs(os.path.join(tp_share, "FLINTJ"), exist_ok=True)
os.makedirs(os.path.join(tp_share, "FLINT", "streams"), exist_ok=True)
for name in ("FLINT.ELF", "GOSH.ELF", "STORE.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(tp_share, name))
open(os.path.join(tp_share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\n"
)
open(os.path.join(tp_share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF\n"
)
open(os.path.join(tp_share, "FLINT", "TRUSTED.TXT"),
     "w", encoding="utf-8").write(
    "#v1\nkey=" + good_changes[-1]["author"] + " name=sync-seed\n"
    "key=" + acme_ch["author"] + " name=acme\n"
    "revoked=" + revkey_ch["author"] + "\n"
)
for ch, line, sname, created in (
        (good_changes[-1], good_raw.decode("utf-8").strip(), "main",
         good_changes[0]["ts"]),
        (rel_change, rel_change_line, "rel", 1760000000000),
        (rel2_ch, rel2_line, "rel2", rel2_ch["ts"]),
        (legacy_ch, legacy_line, "legacy", legacy_ch["ts"]),
        (acme_ch, acme_line, "acme", acme_ch["ts"])):
    with open(os.path.join(tp_share, "FLINT", "streams",
                           ch["stream"] + ".jsonl"), "wb") as f:
        if isinstance(line, bytes):
            f.write(line)
        else:
            f.write((line + "\n").encode("utf-8"))
    with open(os.path.join(tp_share, "FLINT", "streams",
                           ch["stream"] + ".json"), "w") as f:
        f.write(json.dumps(
            {"id": ch["stream"], "name": sname, "head": ch["id"],
             "created": created, "forked_from": None},
            separators=(",", ":")) + "\n")
shutil.copy(os.path.join("image", "apps.txt"), os.path.join(tp_share, "APPS.TXT"))

open(os.path.join(tp_share, "FLINTJ", "trusted-revoked.txt"),
     "w", encoding="utf-8").write(
    "#v1\nkey=" + good_changes[-1]["author"] + " name=sync-seed\n"
    "revoked=" + acme_ch["author"] + "\n"
    "revoked=" + revkey_ch["author"] + "\n"
)


def tp_drop(sname, rel_text, elf, bin_name):
    dd = os.path.join(tp_share, "DROP", sname)
    os.makedirs(dd, exist_ok=True)
    open(os.path.join(dd, "release.go"), "w", encoding="utf-8").write(rel_text)
    open(os.path.join(dd, bin_name), "wb").write(elf)


tp_drop("rel", release_go, elf_bytes, "GOHELLO.ELF")
tp_drop("rel2", rel2_go, elf_bytes, "BOUNCE.ELF")
open(os.path.join(tp_share, "DROP", "rel2", "icon"), "wb").write(ICON_BLOB)
tp_drop("legacy", legacy_go, elf_bytes, "LEGACY.ELF")
tp_drop("acme", acme_go, acme_bytes, "ACMEAPP.ELF")

# 20: catalog + install + run — the run-14 shape on the fresh share.
# `store ls` refreshes nothing (the staged replicas' heads match the
# remote's) but does attempt the two remote-only clones, so the named
# keyring refusals print inside the happy-path boot exactly like run 14.
open(os.path.join(tp_share, "FLINTJ", "20.SH"), "w", encoding="utf-8").write(
    "STORE.ELF ls --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "STORE.ELF install acme --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "ACMEAPP.ELF\n"
    "echo m110d: install done\n"
)
# 21: a second boot proves the installed app persists and still runs
# BEFORE any socket session (the fresh-boot exec is the reclaim-safe
# one — the same line right after run 20's socket-heavy install is the
# shape the task-pool race eats). The revoked-after-publish leg runs
# next — this card's new negative — ahead of the clone-negative legs:
# each refused clone is ~3 socket sessions of retries, so the legs
# late in the script are the first execs the task-pool race eats
# (observed in both orders). The keyring swap revokes acme AND revkey
# before all three installs, so the refusals land the same names
# regardless of order.
open(os.path.join(tp_share, "FLINTJ", "21.SH"), "w", encoding="utf-8").write(
    "ACMEAPP.ELF\n"
    "cat /host/FLINTJ/trusted-revoked.txt > /host/FLINT/TRUSTED.TXT\n"
    "STORE.ELF install acme --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "STORE.ELF install badkey --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "STORE.ELF install revkey --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "echo m110d: negatives done\n"
)


# ---- M113d (#2420): ReleaseCaps declare + consent ----------------------
# `caprel` is a third release stream whose signed manifests carry ADR
# 0054 D10's ReleaseCaps — v1 asks file,net, v2 narrows to file (the
# non-widening keep leg), v3 widens to file,debug,net (the re-ask leg).
# Runs 22-24 drive the whole lifecycle on one fresh share under the Go
# seat: STORE.ELF unprivileged can only PROPOSE (the admin slot refuses
# it EACCES — nothing the publisher signs becomes power), GOSET.ELF
# exec'd -u0 (the monitor's admin spawn — the CAP_PROC_ADMIN half of the
# seat-or-cap gate) is the consenting pane, and -u0 update runs the
# keep's sha re-pin through the same slot.
goset_elf = os.path.join(".build", "go", "GOSET.ELF")
if not os.path.isfile(goset_elf):
    sys.exit("GOSET.ELF missing (expected " + goset_elf +
             ") - build it first: bash tools/go/build-goset.sh")

caprel_stream_id = "0199de2d-dc00-7000-8000-00000000f010"
elf_v3 = elf_bytes.replace(mark_v1, b"virelai-go V3")
assert elf_v3 != elf_bytes

gen_release_fixture({
    "STORE_FIXTURE_STREAM": caprel_stream_id,
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000f001",
    "STORE_FIXTURE_CAPS": "file,net",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "caprel-v1",
})
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.join(fixture_dir, "gohello-v2.elf"),
    "STORE_FIXTURE_VERSION": "2.0.0",
    "STORE_FIXTURE_STREAM": caprel_stream_id,
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000f002",
    "STORE_FIXTURE_PARENT": "0199de2d-dc00-7000-8000-00000000f001",
    "STORE_FIXTURE_PREV_ELF": os.path.abspath(gohello),
    "STORE_FIXTURE_PREV_VERSION": "1.0.0",
    "STORE_FIXTURE_TS": "1760000001000",
    "STORE_FIXTURE_CAPS": "file",
    "STORE_FIXTURE_PREV_CAPS": "file,net",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "caprel-v2",
})
open(os.path.join(fixture_dir, "gohello-v3.elf"), "wb").write(elf_v3)
gen_release_fixture({
    "STORE_FIXTURE_ELF": os.path.join(fixture_dir, "gohello-v3.elf"),
    "STORE_FIXTURE_VERSION": "3.0.0",
    "STORE_FIXTURE_STREAM": caprel_stream_id,
    "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000f003",
    "STORE_FIXTURE_PARENT": "0199de2d-dc00-7000-8000-00000000f002",
    "STORE_FIXTURE_PREV_ELF": os.path.join(fixture_dir, "gohello-v2.elf"),
    "STORE_FIXTURE_PREV_VERSION": "2.0.0",
    "STORE_FIXTURE_TS": "1760000002000",
    "STORE_FIXTURE_CAPS": "file,debug,net",
    "STORE_FIXTURE_PREV_CAPS": "file",
    "STORE_FIXTURE_DIR": fixture_dir,
    "STORE_FIXTURE_TAG": "caprel-v3",
})
caprel = {}
for tag in ("caprel-v1", "caprel-v2", "caprel-v3"):
    caprel[tag] = (
        open(os.path.join(fixture_dir, "release-%s-stream.jsonl" % tag),
             "r", encoding="utf-8").read().strip(),
        open(os.path.join(fixture_dir, "release-%s.go" % tag),
             "r", encoding="utf-8").read(),
    )
caprel_v1, caprel_v2, caprel_v3 = (json.loads(caprel[t][0])
                                 for t in ("caprel-v1", "caprel-v2", "caprel-v3"))

caps_share = os.path.join(run, "caps-share")
os.makedirs(os.path.join(caps_share, "FLINTJ"), exist_ok=True)
os.makedirs(os.path.join(caps_share, "FLINT", "streams"), exist_ok=True)
for name in ("FLINT.ELF", "GOSH.ELF", "STORE.ELF", "GOSET.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(caps_share, name))
# NO seat (wm=none — the go-calc shim shape): a seat + GOSH + STORE +
# the FLINT child is four Go runtimes at once, the shape the task-pool
# race eats (observed: `newosproc: sys_thread create failed` inside the
# install leg), and typed input under a shim lands on the only window —
# GOSET's — with no seat-side focus arbitration to race (observed: the
# Zig seat's `tab-switch idx=1` stole focus over `goset: ready`).
shutil.copy(os.path.join("image", "apps.txt"), os.path.join(caps_share, "APPS.TXT"))
if os.path.isfile(os.path.join("image", "WALLPAPER.QOI")):
    shutil.copy(os.path.join("image", "WALLPAPER.QOI"),
                os.path.join(caps_share, "WALLPAPER.QOI"))
if os.path.isfile(os.path.join("user", "src", "lib", "fixtures", "qoi",
                               "mascot_64x64.qoi")):
    shutil.copy(os.path.join("user", "src", "lib", "fixtures", "qoi",
                             "mascot_64x64.qoi"),
                os.path.join(caps_share, "SEXIBURGER.QOI"))
for src, dst in (("Inter-Regular.ttf", "INTER.TTF"),
                 ("Inter-Bold.ttf", "INTERB.TTF"),
                 ("Inter-Italic.ttf", "INTERI.TTF"),
                 ("Inter-BoldItalic.ttf", "INTERBI.TTF"),
                 ("FiraCode-Regular.ttf", "FIRACODE.TTF")):
    p = os.path.join("image", "fonts", src)
    if os.path.isfile(p):
        shutil.copy(p, os.path.join(caps_share, dst))
open(os.path.join(caps_share, "SETTINGS.TXT"), "w", encoding="utf-8").write(
    "#v2\nwm=none\n")
open(os.path.join(caps_share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\n"
)
open(os.path.join(caps_share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF\n" +
    # The keep path runs STORE -u0: uid_system lanes are served to the
    # admin principal only, so the admin STORE gets its own lane for the
    # same remote key.
    "flint-remote\t0\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF\n"
)
open(os.path.join(caps_share, "FLINT", "TRUSTED.TXT"),
     "w", encoding="utf-8").write(
    "#v1\nkey=" + good_changes[-1]["author"] + " name=sync-seed\n"
)
# The v1 replica — the staged-bytes seam again, local AND remote: pull
# only ever runs `heads` (the remote record stays at v1, so the .SH
# file-copy advances read as already-ahead like run 15's).
caprel_line_v1 = caprel["caprel-v1"][0]
for store_root in (flintd_store, os.path.join(caps_share, "FLINT")):
    with open(os.path.join(store_root, "streams",
                           caprel_stream_id + ".jsonl"), "w") as f:
        f.write(caprel_line_v1 + "\n")
    with open(os.path.join(store_root, "streams",
                           caprel_stream_id + ".json"), "w") as f:
        f.write(json.dumps(
            {"id": caprel_stream_id, "name": "caprel",
             "head": caprel_v1["id"], "created": caprel_v1["ts"],
             "forked_from": None},
            separators=(",", ":")) + "\n")


def caps_drop(drop, tag, elf):
    d = os.path.join(caps_share, drop, "caprel")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "release.go"), "w",
         encoding="utf-8").write(caprel[tag][1])
    open(os.path.join(d, "GOHELLO.ELF"), "wb").write(elf)


caps_drop("DROP", "caprel-v1", elf_bytes)
caps_drop("DROPV2G", "caprel-v2", elf_v2)
caps_drop("DROPV3G", "caprel-v3", elf_v3)

# The replica advances (v1+v2 then v1+v2+v3 chains + rolled record
# heads) the .SH legs land by file copy.
with open(os.path.join(caps_share, "FLINTJ", "caprel-v2.jsonl"),
          "w", encoding="utf-8") as f:
    f.write(caprel_line_v1 + "\n" + caprel["caprel-v2"][0] + "\n")
# gosh's readBounded caps one `cat` at 4096 bytes — a 3-line file is
# ~4.9 KiB, so 24.SH appends the v3 line alone instead of overwriting
# with the whole chain (the error text would otherwise land IN the
# stream file and `flint pull` would refuse change_malformed).
with open(os.path.join(caps_share, "FLINTJ", "caprel-v3-last.jsonl"),
          "w", encoding="utf-8") as f:
    f.write(caprel["caprel-v3"][0] + "\n")
for tag, head in (("caprel-v2", caprel_v2["id"]),
                  ("caprel-v3", caprel_v3["id"])):
    with open(os.path.join(caps_share, "FLINTJ", tag + ".json"),
              "w", encoding="utf-8") as f:
        f.write(json.dumps(
            {"id": caprel_stream_id, "name": "caprel", "head": head,
             "created": caprel_v1["ts"], "forked_from": None},
            separators=(",", ":")) + "\n")

flintj_m113d = {
    # 22: install the caps-bearing release (STORE unprivileged — it can
    # only propose), then exec the installed app at the ambient
    # baseline: no grant row means every word stays ambient, and the
    # consent pane's refuse/grant gestures are the legs after this
    # script ends.
    "22.SH": (
        "STORE.ELF install caprel --remote=10.0.0.2:4749 --channel=/host/DROP\n"
        "GOHELLO.ELF\n"
        "echo m113d: install done\n"
    ),
    # 23: advance to the non-widening v2 (file ⊆ consented file,net) and
    # update under -u0 — STORE sees the row, re-pins its sha to the new
    # image with the consented words verbatim, and the v2 exec runs.
    "23.SH": (
        "cat /host/FLINTJ/caprel-v2.jsonl > /host/FLINT/streams/" + caprel_stream_id + ".jsonl\n"
        "cat /host/FLINTJ/caprel-v2.json > /host/FLINT/streams/" + caprel_stream_id + ".json\n"
        "STORE.ELF update GOHELLO --remote=10.0.0.2:4749 --channel=/host/DROPV2G\n"
        "GOHELLO.ELF\n"
        "echo m113d: keep done\n"
    ),
    # 24: advance to the widening v3 (debug ∉ consented file,net) and
    # update under -u0 — the row is left bound to v2's image (stale:
    # the unconsented image refuses grant_stale at exec), the ask is
    # re-proposed, and the pane's consent is the leg after this script.
    "24.SH": (
        "cat /host/FLINTJ/caprel-v2.jsonl > /host/FLINT/streams/" + caprel_stream_id + ".jsonl\n"
        "cat /host/FLINTJ/caprel-v3-last.jsonl >> /host/FLINT/streams/" + caprel_stream_id + ".jsonl\n"
        "cat /host/FLINTJ/caprel-v3.json > /host/FLINT/streams/" + caprel_stream_id + ".json\n"
        "STORE.ELF update GOHELLO --remote=10.0.0.2:4749 --channel=/host/DROPV3G\n"
        "GOHELLO.ELF\n"
        "echo m113d: widening done\n"
    ),
}
for sname, sbody in flintj_m113d.items():
    open(os.path.join(caps_share, "FLINTJ", sname),
         "w", encoding="utf-8").write(sbody)

# ---- M113f (#2422): the acceptance chain leg ------------------------------
# m113f-share is a pristine copy of caps-share's staging — runs 22-24
# mutate that share (the consent row, the v2/v3 image moves) and the
# chain leg must open on a declared-only store like run 22 did. GOTOP.ELF
# joins the bundle for the viewer step.
gotop_elf = os.path.join(".build", "go", "GOTOP.ELF")
if not os.path.isfile(gotop_elf):
    sys.exit("GOTOP.ELF missing (expected " + gotop_elf +
             ") - build it first: bash tools/go/build-gotop.sh")
m113f_share = os.path.join(run, "m113f-share")
shutil.copytree(caps_share, m113f_share)
shutil.copy(gotop_elf, os.path.join(m113f_share, "GOTOP.ELF"))
# The guest script IS the ordering (gosh foregrounds each command):
# install declares the signed ask -> GOSET (inside the -u0 gosh, so the
# consent write carries CAP_PROC_ADMIN) exits on the typed `escape` ->
# GOHELLO execs under the row the consent just wrote -> GOTOP opens ->
# the still-arriving chord tail parks it on the trust tab with auto-
# refresh -> the chain-done echo. GOTOP deliberately comes AFTER GOSET:
# a resident viewer + STORE install overflowed the 16-entry task pool
# (64 after M129b / #2611 — the incident stayed in this shape at 16)
# (`newosproc: sys_thread create failed`, observed twice — once each
# under default and single-core layouts) because STORE and the viewer's
# Go runtimes spawn threads on demand.
open(os.path.join(m113f_share, "FLINTJ", "M113F.SH"),
     "w", encoding="utf-8").write(
    "STORE.ELF install caprel --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "echo m113f: declared\n"
    "GOSET.ELF\n"
    "GOHELLO.ELF\n"
    "GOTOP.ELF &\n"
    "sleep 8\n"
    "kill %1\n"
    "echo m113f: chain done\n"
)


print("staged FLINT.ELF, GOSH.ELF, STORE.ELF, /host/FLINTC, /host/FLINTW, /host/FLINTV, /host/FLINTJ, nosign-share, clean-share, conflict-share, sync-share, badauth-share, store-share, tp-share, caps-share, and m113f-share (%d files, %d atoms)" % (manifest["files"], len(atoms)))
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
vgate_assert 14 serial-contains 'store: stream badkey sync-failed'
vgate_assert 14 serial-contains 'store: stream revkey sync-failed'
# M110b: `store ls` renders the signed catalog — every release stream's
# manifest consts plus the derived publisher fingerprint (the head
# Change's author key, labeled from TRUSTED.TXT). Two pinned publishers
# and one legacy four-const stream. M110d: the acme publisher's second
# app joins the fold — the 4-entry count is the honest one.
vgate_assert 14 serial-contains 'store: stream rel release name=GOHELLO version=1.0.0 category=demo'
vgate_assert 14 serial-contains 'store: stream rel2 release name=BOUNCE version=1.4.0 category=game'
vgate_assert 14 serial-contains 'store: stream legacy release name=LEGACY version=0.9.0 category=-'
vgate_assert 14 serial-contains 'store: stream acme release name=ACMEAPP version=1.0.0 category=app'
vgate_assert 14 serial-contains 'publisher_state=trusted summary=-'
vgate_assert 14 serial-contains 'publisher_name=sync-seed publisher_state=trusted'
vgate_assert 14 serial-contains 'publisher_name=acme publisher_state=trusted'
vgate_assert 14 serial-contains 'summary=Go Hello greets VirelaiOS'
vgate_assert 14 serial-contains 'summary=Acme'"'"'s first VirelaiOS app'
vgate_assert 14 serial-contains 'store: ls ok entries=4'
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
              "caps=- "
              "prev_head=0199de2d-dc00-7000-8000-00000000c002 "
              "prev_sha256=" + v2sha + " "
              "prev_caps=- "
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
              "caps=- "
              "prev_head=0199de2d-dc00-7000-8000-00000000c002 "
              "prev_sha256=" + v2sha + " "
              "prev_caps=- "
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

# ---- 18: M110b (#2404) signed catalog — filtered listings + the ------
# ---- two-publisher detail card --------------------------------------
vgate_run 18 -- \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap18.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-18.txt' \
    --script-expect 'm110b: catalog ls done' \
    --script-expect-tail 3 --timeout 300

# The filtered listing renders exactly the one matching entry; the
# filtered-out release lines pin the behavior.
vgate_assert 18 serial-count 'store: ls ok entries=1' 1
vgate_assert 18 serial-count 'store: stream rel2 release name=BOUNCE version=1.4.0 category=game' 1
# `rel` filters out cleanly — whether its catalog-invalid marker prints
# here depends on which head the replica's record read back (the share
# has dropped that write once); run 19 asserts the marker deterministically
# against the tampered drop.
vgate_assert 18 serial-absent 'store: stream rel release'
vgate_assert 18 serial-absent 'store: stream legacy release'
vgate_assert 18 serial-contains 'store: stream main no-release'
vgate_assert 18 serial-count 'store: stream badkey sync-failed' 1
vgate_assert 18 serial-count 'store: stream revkey sync-failed' 1
vgate_assert 18 serial-contains 'store: name BOUNCE'
vgate_assert 18 serial-contains 'store: category game'
vgate_assert 18 serial-contains 'store: summary A bouncing ball demo'
vgate_assert 18 serial-contains 'publisher_name=acme publisher_state=trusted'
vgate_assert 18 serial-contains 'store: head 0199de2d-dc00-7000-8000-00000000c010'
vgate_assert 18 serial-contains 'store: installed no'
vgate_assert 18 serial-contains 'store: row BOUNCE.ELF | Bounce | g | dock=false'
vgate_assert 18 serial-contains 'store:   Bounce renders a ball on the desktop.'
vgate_assert 18 serial-contains 'store:   Shipped by a second publisher.'
vgate_assert 18 serial-contains 'store: info ok'
vgate_assert 18 serial-absent 'store: refuse'
vgate_assert 18 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 18 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 18 serial-absent '[EXC] parking:'
vgate_assert 18 python <<'PY'
import hashlib, json, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")
ser = open(os.environ["VG_SER"], errors="replace").read()

# The sha256 field on the rel2 card pins the real delivered ELF, and the
# icon_sha256 field pins the staged <stream>/icon blob (ADR 0055 D7).
elf_sha = hashlib.sha256(open(os.path.join(".build", "go", "GOHELLO.ELF"), "rb").read()).hexdigest()
icon_sha = hashlib.sha256(open(os.path.join(share, "DROP", "rel2", "icon"), "rb").read()).hexdigest()
if "store: sha256 " + elf_sha not in ser:
    sys.exit("rel2 card missing sha256=" + elf_sha)
if "store: icon_sha256 " + icon_sha not in ser:
    sys.exit("rel2 card missing icon_sha256=" + icon_sha)
rel2 = json.loads(open(os.path.join(run, "fixtures", "release-rel2-stream.jsonl"),
                      "r", encoding="utf-8").read())
if ("store: publisher " + rel2["author"] +
        " publisher_name=acme publisher_state=trusted") not in ser:
    sys.exit("derived publisher fingerprint missing or mislabeled for rel2")
print("run-18 catalog render verified: filters + two-publisher card")
PY

# ---- 19: M110b (#2404) — tampered-description refusal + legacy -------
# ---- four-const install ---------------------------------------------
vgate_run 19 -- \
    --cvc-file '$RUN_DIR/store-share' \
    --virtio-fs '$RUN_DIR/store-share' \
    --net '$RUN_DIR/cap19.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-19.txt' \
    --script-expect 'm110b: catalog legs done' \
    --script-expect-tail 3 --timeout 300

# The --search leg repeats the filtered-catalog behavior: exactly one
# match, same invalid/absent markers for the rest.
vgate_assert 19 serial-count 'store: ls ok entries=1' 1
vgate_assert 19 serial-count 'store: stream rel2 release name=BOUNCE version=1.4.0 category=game' 1
vgate_assert 19 serial-absent 'store: stream rel release'
vgate_assert 19 serial-absent 'store: stream legacy release'
vgate_assert 19 serial-count 'store: stream rel catalog-invalid release_mismatch' 1
vgate_assert 19 serial-count 'store: stream badkey sync-failed' 1
vgate_assert 19 serial-count 'store: stream revkey sync-failed' 1
vgate_assert 19 serial-count 'store: refuse release_mismatch' 1
vgate_assert 19 serial-contains 'store: install ok LEGACY.ELF version=0.9.0'
vgate_assert 19 serial-contains 'virelai-go OK'
vgate_assert 19 serial-absent 'store: refuse summary_invalid'
vgate_assert 19 serial-absent 'store: refuse description_invalid'
vgate_assert 19 serial-absent 'store: refuse category_unknown'
vgate_assert 19 serial-absent 'store: refuse sync_failed'
vgate_assert 19 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 19 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 19 serial-absent '[EXC] parking:'
vgate_assert 19 python <<'PY'
import os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "store-share")

# The legacy install landed tracked bytes: ELF + manifest row + state.
legacy = open(os.path.join(share, "LEGACY.ELF"), "rb").read()
if legacy != open(os.path.join(".build", "go", "GOHELLO.ELF"), "rb").read():
    sys.exit("LEGACY.ELF bytes differ from the signed ELF")
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if "LEGACY.ELF | Legacy | g | dock=false\n" not in apps:
    sys.exit("LEGACY row missing from APPS.TXT: %r" % apps)
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "name=LEGACY.ELF stream=legacy head=0199de2d-dc00-7000-8000-00000000c011" not in state:
    sys.exit("STORE.TXT missing legacy entry: %r" % state)
if "GOHELLO" in state:
    sys.exit("GOHELLO crept back into STORE.TXT")
print("run-19 verified: tampered description refused, legacy release installed")
PY

# ---- 20: M110d (#2406) fresh share — catalog lists the acme app, ------
# ---- install verifies + publishes it, the app runs -------------------
vgate_run 20 -- \
    --cvc-file '$RUN_DIR/tp-share' \
    --virtio-fs '$RUN_DIR/tp-share' \
    --net '$RUN_DIR/cap20.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-20.txt' \
    --script-expect 'm110d: install done' \
    --script-expect-tail 3 --timeout 300

# The catalog fold over the fresh share: the acme entry renders with its
# signed consts + the derived acme fingerprint beside the other three
# release streams, and the remote-only negative-key streams refuse
# their clones inside the same boot.
vgate_assert 20 serial-contains 'store: stream acme release name=ACMEAPP version=1.0.0 category=app'
vgate_assert 20 serial-contains 'store: stream rel2 release name=BOUNCE version=1.4.0 category=game'
vgate_assert 20 serial-contains 'publisher_name=acme publisher_state=trusted'
vgate_assert 20 serial-contains 'summary=Acme'"'"'s first VirelaiOS app'
vgate_assert 20 serial-contains 'store: stream main no-release'
vgate_assert 20 serial-contains 'store: stream badkey sync-failed'
vgate_assert 20 serial-contains 'store: stream revkey sync-failed'
vgate_assert 20 serial-contains 'store: ls ok entries=4'
vgate_assert 20 serial-count 'flint: refuse key_unknown' 1
vgate_assert 20 serial-count 'flint: refuse key_revoked' 1
vgate_assert 20 serial-contains 'sig: verified'
vgate_assert 20 serial-contains 'store: install ok ACMEAPP.ELF version=1.0.0'
vgate_assert 20 serial-absent 'store: refuse'
vgate_assert 20 serial-absent 'sig_invalid'
vgate_assert 20 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 20 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 20 serial-absent '[EXC] parking:'
vgate_assert 20 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "tp-share")

elf = os.path.join(share, "ACMEAPP.ELF")
if not os.path.isfile(elf):
    sys.exit("ACMEAPP.ELF missing at tp-share root after install")
got = hashlib.sha256(open(elf, "rb").read()).hexdigest()
want = hashlib.sha256(open(os.path.join(".build", "go", "ACMEAPP.ELF"), "rb").read()).hexdigest()
if got != want:
    sys.exit("installed ACMEAPP.ELF hash %s != built %s" % (got, want))
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if apps.count("ACMEAPP.ELF |") != 1:
    sys.exit("expected exactly one ACMEAPP row in APPS.TXT: %r" % apps)
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "name=ACMEAPP.ELF stream=acme head=0199de2d-dc00-7000-8000-00000000c012" not in state:
    sys.exit("STORE.TXT missing acme entry: %r" % state)
trusted = open(os.path.join(share, "FLINT", "TRUSTED.TXT"), "r", encoding="utf-8").read()
if "key=" not in trusted or "name=acme" not in trusted:
    sys.exit("TRUSTED.TXT moved before the revocation leg: %r" % trusted)
for sid in ("0199de2d-dc00-7000-8000-00000000e010",
            "0199de2d-dc00-7000-8000-00000000e011"):
    if os.path.exists(os.path.join(share, "FLINT", "streams", sid + ".jsonl")):
        sys.exit("key-refused clone wrote a local replica for " + sid)
print("run-20 fresh share installed+ran the third-party app; negatives left no local state")
PY

# ---- 21: M110d (#2406) install-time negatives by name + the ----------
# ---- revoked-after-publish leg --------------------------------------
vgate_run 21 -- \
    --cvc-file '$RUN_DIR/tp-share' \
    --virtio-fs '$RUN_DIR/tp-share' \
    --net '$RUN_DIR/cap21.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-21.txt' \
    --script-expect 'm110d: negatives done' \
    --script-expect-tail 3 --timeout 300

vgate_assert 21 serial-contains 'acme-app OK'
vgate_assert 21 serial-count 'flint: refuse key_unknown' 1
vgate_assert 21 serial-count 'flint: refuse key_revoked' 2
vgate_assert 21 serial-count 'store: refuse sync_failed' 3
vgate_assert 21 serial-absent 'store: install ok'
vgate_assert 21 serial-absent 'sig_invalid'
vgate_assert 21 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 21 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 21 serial-absent '[EXC] parking:'
vgate_assert 21 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "tp-share")

# The keyring swap landed verbatim, and revocation gated only NEW
# installs: run 20's published bytes + rows survive untouched.
trusted = open(os.path.join(share, "FLINT", "TRUSTED.TXT"), "r", encoding="utf-8").read()
staged = open(os.path.join(share, "FLINTJ", "trusted-revoked.txt"), "r", encoding="utf-8").read()
if trusted != staged:
    sys.exit("TRUSTED.TXT after the swap != staged revoked variant: %r" % trusted)
got = hashlib.sha256(open(os.path.join(share, "ACMEAPP.ELF"), "rb").read()).hexdigest()
want = hashlib.sha256(open(os.path.join(".build", "go", "ACMEAPP.ELF"), "rb").read()).hexdigest()
if got != want:
    sys.exit("installed ACMEAPP.ELF moved under refused installs")
apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if apps.count("ACMEAPP.ELF |") != 1:
    sys.exit("ACMEAPP row moved under refused installs: %r" % apps)
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "name=ACMEAPP.ELF stream=acme head=0199de2d-dc00-7000-8000-00000000c012" not in state:
    sys.exit("STORE.TXT acme entry moved under refused installs: %r" % state)
for sid in ("0199de2d-dc00-7000-8000-00000000e010",
            "0199de2d-dc00-7000-8000-00000000e011"):
    if os.path.exists(os.path.join(share, "FLINT", "streams", sid + ".jsonl")):
        sys.exit("key-refused clone wrote a local replica for " + sid)
print("run-21 verified: key_unknown + key_revoked refused by name; revoked publisher's already-synced release refused at install")
PY
# ---- 22: M113d (#2420) declare + consent -------------------------------
# The seat boots (go-gostore's shape), STORE.ELF installs caprel
# unprivileged — the admin slot refuses it EACCES, so the install can
# only PROPOSE the row the manifest asked for. GOHELLO.ELF then execs at
# the ambient baseline (no row, every word ambient — the refused-consent
# posture is the default). GOSET.ELF -u0 (the monitor's admin spawn —
# the CAP_PROC_ADMIN half of the seat-or-cap gate) opens the grants
# pane: one row marker per install shows declared-vs-granted, `refuse`
# declines without a write, `grant` lands (bin, sha, words) through slot
# 89.
vgate_file script-22.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script2-22.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/22.SH"
EOF

vgate_file script3-22.txt <<'EOF'
exec -u0 GOSET.ELF
EOF

vgate_run 22 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-22' \
    --cvc-file '$RUN_DIR/caps-share' \
    --virtio-fs '$RUN_DIR/caps-share' \
    --net '$RUN_DIR/cap22.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-22.txt' \
    --script2 '$RUN_DIR/script2-22.txt' \
    --script2-after 'VirelaiOS kernel has seized control.' \
    --script3 '$RUN_DIR/script3-22.txt' \
    --script3-after 'm113d: install done' \
    --input-string $'grants\nrefuse GOHELLO.ELF\ngrant GOHELLO.ELF\n' \
    --input-string-after 'goset: ready ' \
    --script-expect 'goset: grant written name=GOHELLO.ELF' --timeout 300

vgate_assert 22 serial-contains 'store: install ok GOHELLO.ELF version=1.0.0'
vgate_assert 22 serial-contains 'store: grant propose GOHELLO.ELF words=file,net'
vgate_assert 22 serial-contains 'goset: grants n='
vgate_assert 22 serial-contains 'goset: grant row name=GOHELLO.ELF declared=file,net granted=- state=pending'
vgate_assert 22 serial-contains 'goset: grant declined name=GOHELLO.ELF'
vgate_assert 22 serial-contains 'goset: grant written name=GOHELLO.ELF words=file,net'
# The pre-consent exec ran at the ambient baseline — no row, every word
# ambient, and no refused verdict anywhere in the boot.
vgate_assert 22 serial-contains 'virelai-go OK'
vgate_assert 22 serial-absent 'verdict=refused'
vgate_assert 22 serial-absent 'goset: grant refuse name=GOHELLO.ELF'
vgate_assert 22 serial-absent '[EXC] parking:'
vgate_assert 22 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 22 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 22 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "caps-share")

sha = hashlib.sha256(open(os.path.join(share, "GOHELLO.ELF"), "rb").read()).hexdigest()
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
lines = [l for l in grants.splitlines() if l and not l.startswith("#")]
if lines != ["GOHELLO.ELF\t" + sha + "\tfile,net"]:
    sys.exit("GRANTS.TXT after consent: %r (sha %s)" % (lines, sha))
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "caps=file,net" not in state:
    sys.exit("STORE.TXT did not record the declared ask: %r" % state)
print("run-22 verified: propose -> decline -> consent wrote the hash-bound row")
PY

# ---- 23: M113d (#2420) non-widening update keeps the grant -------------
# caprel v2 asks file — a subset of the consented file,net. The update
# under -u0 reads the row, re-pins its sha binding to the new image with
# the consented words verbatim (the keep — no fresh ask), and the v2
# bytes exec.
vgate_file script-23.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script2-23.txt <<'EOF'
exec -u0 GOSH.ELF -c "source /host/FLINTJ/23.SH"
EOF

vgate_run 23 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-23' \
    --cvc-file '$RUN_DIR/caps-share' \
    --virtio-fs '$RUN_DIR/caps-share' \
    --net '$RUN_DIR/cap23.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-23.txt' \
    --script2 '$RUN_DIR/script2-23.txt' \
    --script2-after 'VirelaiOS kernel has seized control.' \
    --script-expect 'm113d: keep done' --timeout 300

vgate_assert 23 serial-contains 'store: update ok GOHELLO.ELF version=2.0.0'
vgate_assert 23 serial-contains 'store: grant keep GOHELLO.ELF words=file,net'
vgate_assert 23 serial-contains 'virelai-go V2'
vgate_assert 23 serial-absent 'store: grant propose'
vgate_assert 23 serial-absent 'verdict=refused'
vgate_assert 23 serial-absent '[EXC] parking:'
vgate_assert 23 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 23 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "caps-share")

elf = open(os.path.join(share, "GOHELLO.ELF"), "rb").read()
sha = hashlib.sha256(elf).hexdigest()
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
lines = [l for l in grants.splitlines() if l and not l.startswith("#")]
if lines != ["GOHELLO.ELF\t" + sha + "\tfile,net"]:
    sys.exit("GRANTS.TXT after the keep: %r (sha %s)" % (lines, sha))
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "caps=file " not in state + " " or "prev_caps=file,net" not in state:
    sys.exit("STORE.TXT lost the caps history: %r" % state)
print("run-23 verified: non-widening update re-pinned the row to the new image")
PY

# ---- 24: M113d (#2420) widening update re-asks; consent re-pins --------
# caprel v3 asks file,debug,net — debug is NOT inside the consented
# file,net, so this is a distinct consent event: the update leaves the
# row bound to v2's image (the unconsented image refuses grant_stale at
# exec — the widening never silently lands), re-proposes, and the
# pane's `grant` writes the widened set bound to v3.
vgate_file script-24.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script2-24.txt <<'EOF'
exec -u0 GOSH.ELF -c "source /host/FLINTJ/24.SH"
EOF

vgate_file script3-24.txt <<'EOF'
exec -u0 GOSET.ELF
EOF

vgate_run 24 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-24' \
    --cvc-file '$RUN_DIR/caps-share' \
    --virtio-fs '$RUN_DIR/caps-share' \
    --net '$RUN_DIR/cap24.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-24.txt' \
    --script2 '$RUN_DIR/script2-24.txt' \
    --script2-after 'VirelaiOS kernel has seized control.' \
    --script3 '$RUN_DIR/script3-24.txt' \
    --script3-after 'm113d: widening done' \
    --input-string $'grants\ngrant GOHELLO.ELF\n' \
    --input-string-after 'goset: ready ' \
    --script-expect 'goset: grant written name=GOHELLO.ELF' --timeout 300

vgate_assert 24 serial-contains 'store: update ok GOHELLO.ELF version=3.0.0'
vgate_assert 24 serial-contains 'store: grant propose GOHELLO.ELF words=file,debug,net'
# The unconsented v3 image is refused at exec — the widening did not
# silently ride the old consent.
vgate_assert 24 serial-contains 'verdict=refused:grant_stale'
vgate_assert 24 serial-contains 'goset: grant row name=GOHELLO.ELF declared=file,debug,net granted=file,net state=stale'
vgate_assert 24 serial-contains 'goset: grant written name=GOHELLO.ELF words=file,debug,net'
vgate_assert 24 serial-absent 'store: grant keep GOHELLO.ELF'
vgate_assert 24 serial-absent '[EXC] parking:'
vgate_assert 24 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 24 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "caps-share")

elf = open(os.path.join(share, "GOHELLO.ELF"), "rb").read()
sha = hashlib.sha256(elf).hexdigest()
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
lines = [l for l in grants.splitlines() if l and not l.startswith("#")]
if lines != ["GOHELLO.ELF\t" + sha + "\tfile,debug,net"]:
    sys.exit("GRANTS.TXT after re-consent: %r" % lines)
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "caps=file,debug,net" not in state or "prev_caps=file" not in state:
    sys.exit("STORE.TXT lost the declared-vs-prior ask: %r" % state)
print("run-24 verified: widening re-asked, consent bound the widened row to v3")
PY

# ---- 25: M113f (#2422) — ONE app through the whole chain, ONE boot --------
# caprel-v1's signed ReleaseCaps declares file,net; the pane's consent
# lands the hash-bound row through slot 89; the confined exec measures in
# (verdict=measured) and receipts audit:<word>_denied for every word the
# image touches outside the row — audit mode records, it never refuses;
# GOTOP's trust tab renders the same posture back. --input-chords types
# the consent conversation (grants pane -> grant -> two padding returns
# so the slot-89 persist has landed before `escape` hands the console
# back); the chord tail then carries ~15 s of harmless down/up padding
# (row navigation in whatever window is up) so the `t` reaches GOTOP's
# window only after the .SH has run the confined GOHELLO and opened the
# viewer — the `t` parks it on the trust tab and ONE post-consent
# render prints the markers this leg asserts. The script-expect is the
# trust-app marker itself: under the deferred `smp: secondary runs=`
# drain, the post-kill `chain done` echo in the .SH can sit in queue
# past the timeout even though every step ran (observed).
vgate_file script-25.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script2-25.txt <<'EOF'
exec -u0 GOSH.ELF -c "source /host/FLINTJ/M113F.SH"
EOF

vgate_run 25 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-25' \
    --cvc-file '$RUN_DIR/m113f-share' \
    --virtio-fs '$RUN_DIR/m113f-share' \
    --net '$RUN_DIR/cap25.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-25.txt' \
    --script2 '$RUN_DIR/script2-25.txt' \
    --script2-after 'VirelaiOS kernel has seized control.' \
    --input-chords 'g,r,a,n,t,s,return,g,r,a,n,t,space,G,O,H,E,L,L,O,.,E,L,F,return,return,return,escape,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,down,up,t' \
    --input-chords-after 'goset: ready ' \
    --script-expect 'top: trust app name=GOHELLO.ELF' --timeout 300

# declared: the signed ReleaseCaps survived verify + publish, and the ask
# is surfaced — nothing consented yet.
vgate_assert 25 serial-contains 'store: install ok GOHELLO.ELF version=1.0.0'
vgate_assert 25 serial-contains 'store: grant propose GOHELLO.ELF words=file,net'
vgate_assert 25 serial-contains 'm113f: declared'
# consent: the grants pane landed the hash-bound row through slot 89.
vgate_assert 25 serial-contains 'goset: grants n='
vgate_assert 25 serial-contains 'goset: grant written name=GOHELLO.ELF words=file,net'
# measured exec + the denied word receipted in audit — and the call still
# landed (audit records, never refuses: 'virelai-go OK' printed).
vgate_assert 25 serial-contains 'verdict=measured name=GOHELLO.ELF'
vgate_assert 25 serial-contains 'audit:debug_denied name=GOHELLO.ELF word=debug'
vgate_assert 25 serial-contains 'virelai-go OK'
# viewer: GOTOP renders the confined posture of the same app.
vgate_assert 25 serial-contains 'top: tab=trust'
vgate_assert 25 serial-contains 'top: trust app name=GOHELLO.ELF'
vgate_assert 25 serial-absent 'verdict=refused'
vgate_assert 25 serial-absent '[EXC] parking:'
vgate_assert 25 serial-absent 'abababababababababababababababababababababababababababababababab'
# The share's own record + the rendered-vs-kernel cross-proof: the row
# the consent wrote is hash-bound to the installed bytes with exactly
# the declared words; GOTOP's rendered denied set names every word the
# kernel receipted a denial for on the same boot; the rendered sha pin
# and publisher come from the share's own stream replica, not constants.
vgate_assert 25 python <<'PY'
import hashlib, json, os, re, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "m113f-share")
ser = open(os.environ["VG_SER"], errors="replace").read()

elf = open(os.path.join(share, "GOHELLO.ELF"), "rb").read()
sha = hashlib.sha256(elf).hexdigest()
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
lines = [l for l in grants.splitlines() if l and not l.startswith("#")]
if lines != ["GOHELLO.ELF\t" + sha + "\tfile,net"]:
    sys.exit("GRANTS.TXT after the chain leg: %r (sha %s)" % (lines, sha))
state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "caps=file,net" not in state:
    sys.exit("STORE.TXT did not record the declared ask: %r" % state)

rows = {}
for l in ser.splitlines():
    m = re.match(r"top: trust app name=(\S+) uid=(\S+) declared=(\S+)"
                 r" granted=(\S+) denied=(\S+) state=(\S+)", l.strip())
    if m:
        rows[m.group(1)] = m.groups()
g = rows.get("GOHELLO.ELF")
if not g:
    sys.exit("GOTOP rendered no trust row for GOHELLO.ELF")
if g[2] != "file,net" or g[3] != "file,net":
    sys.exit("rendered declared/granted = %s/%s want file,net/file,net"
             % (g[2], g[3]))
denied = set(g[4].split(","))

receipted = set(re.findall(
    r"verdict=audit:(\w+)_denied name=GOHELLO\.ELF", ser))
if "debug" not in receipted:
    sys.exit("the confined exec receipted no debug denial: %r" % receipted)
if not receipted <= denied:
    sys.exit("kernel-receipted %r escapes the rendered denied set %r"
             % (sorted(receipted), sorted(denied)))

shas = {}
for l in ser.splitlines():
    m = re.match(r"top: trust sha name=(\S+) measured=(\S+) pin=(\S+)"
                 r" verdict=(\S+)", l.strip())
    if m:
        shas[m.group(1)] = m.groups()
s = shas.get("GOHELLO.ELF")
if not s or s[3] != "match" or s[1] != sha or s[2] != sha:
    sys.exit("GOTOP sha verdict = %r (want match against %s)" % (s, sha))

# The publisher is the staged replica's head-change author (ADR 0055 D5)
# — derived, never a constant in the spec.
sid = "0199de2d-dc00-7000-8000-00000000f010"
rec = json.loads(open(os.path.join(
    share, "FLINT", "streams", sid + ".json")).read())
head = rec["head"]
author = None
for line in open(os.path.join(
        share, "FLINT", "streams", sid + ".jsonl")).read().splitlines():
    if not line:
        continue
    ch = json.loads(line)
    if ch.get("id") == head:
        author = ch.get("author")
pubs = {}
for l in ser.splitlines():
    m = re.match(r"top: trust pub name=(\S+) stream=(\S+) publisher=(\S+)",
                 l.strip())
    if m:
        pubs[m.group(1)] = m.groups()
p = pubs.get("GOHELLO.ELF")
if not p or p[1] != "caprel" or p[2] != author:
    sys.exit("GOTOP publisher = %r (want stream=caprel author=%s)"
             % (p, author))
print("run-25 verified: declare -> consent -> measured exec -> audit "
      "receipt -> viewer, one app, one boot")
PY

# ---- 26-27: M138c (#2777) — blame, log --graph, tags -----------------------
# A self-contained fork+merge history on its own share: base on main,
# feature fork (X:=10), main edit (Y:=20), merge back. Run 26 builds the
# DAG and exercises the new verbs end to end; run 27 re-boots the SAME
# share so `tag -l` proves TAGS.jsonl persisted and the history verbs
# re-render over the store bytes alone.
vgate_file script-26.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/26.SH"
EOF

vgate_file script-27.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/27.SH"
EOF

vgate_run 26 -- \
    --cvc-file '$RUN_DIR/hist-share' \
    --virtio-fs '$RUN_DIR/hist-share' \
    --script '$RUN_DIR/script-26.txt' \
    --script-expect 'M138C-1-DONE' --script-expect-tail 3 --timeout 240

vgate_assert 26 serial-contains 'flint: commit ok id='
vgate_assert 26 serial-contains 'flint: fork ok stream=feature head='
vgate_assert 26 serial-contains 'flint: merge ok conflicts=0'
# tag: create prints ok, list resolves the stream name.
vgate_assert 26 serial-contains 'flint: tag ok v1 '
vgate_assert 26 serial-contains 'flint: tag v1 '
vgate_assert 26 serial-contains ' main'
vgate_assert 26 serial-contains 'flint: tags 1'
# graph: the merge node opens the feature lane (`|\`), the fold lands on
# base (`|/`), and the tagged head annotates.
vgate_assert 26 serial-contains 'flint: graph * '
vgate_assert 26 serial-contains 'flint: graph |\'
vgate_assert 26 serial-contains 'flint: graph |/'
vgate_assert 26 serial-contains '(tag: v1)'
vgate_assert 26 serial-contains 'flint: graph *'
# blame: per-line `flint: blame <id> <author8> <text>` — the merge change
# touched atom X and the main commit touched atom Y.
vgate_assert 26 serial-contains 'flint: blame '
vgate_assert 26 serial-contains ' d75a9801 func X() int {'
vgate_assert 26 serial-contains ' d75a9801 func Y() int {'
vgate_assert 26 serial-contains 'flint: blame - - package calc'
vgate_assert 26 serial-absent 'flint: refuse'
vgate_assert 26 serial-absent '[EXC] parking:'
vgate_assert 26 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'

vgate_run 27 -- \
    --cvc-file '$RUN_DIR/hist-share' \
    --virtio-fs '$RUN_DIR/hist-share' \
    --script '$RUN_DIR/script-27.txt' \
    --script-expect 'M138C-2-DONE' --script-expect-tail 3 --timeout 240

# The reboot leg: v1 survived the restart on the same share, graph and
# blame re-render identically, and -d removes it for real.
vgate_assert 27 serial-contains 'flint: tag v1 '
vgate_assert 27 serial-contains 'flint: tags 1'
vgate_assert 27 serial-contains 'flint: graph |\'
vgate_assert 27 serial-contains 'flint: graph |/'
vgate_assert 27 serial-contains ' d75a9801 func X() int {'
vgate_assert 27 serial-contains 'flint: tag rm v1'
vgate_assert 27 serial-contains 'flint: tags 0'
vgate_assert 27 serial-absent 'flint: refuse'
vgate_assert 27 serial-absent '[EXC] parking:'
vgate_assert 27 serial-absent '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
vgate_assert 27 python <<'PY'
import json, os, sys
share = os.path.join(os.environ["RUN_DIR"], "hist-share")
p = os.path.join(share, "FLINT", "TAGS.jsonl")
rows = [json.loads(l) for l in open(p) if l.strip()]
if rows != []:
    sys.exit("TAGS.jsonl should be empty after tag -d v1: %r" % rows)
print("run-27 verified: tag persisted across the reboot, -d emptied TAGS.jsonl")
PY
