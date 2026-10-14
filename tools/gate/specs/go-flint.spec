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
# This spec is grown across M103a-d and is NOT vgate_repeat-safe (runs 01-03,
# 05-07, and 08-10 share /host state across boots).
#
# HOST PREREQ:
#   bash tools/go/build-flint.sh -> .build/go/FLINT.ELF
#   bash tools/go/build-gosh.sh  -> .build/go/GOSH.ELF
#
# exec-order: assert-proven -- run 01 ends on `flint: parse files=`, run 02
# ends on `flint: status `, run 03 ends on `sig_invalid`, run 04 ends on
# `flint: refuse secret_not_found`, runs 05/08 end on `flint: fork ok`, runs
# 06/09 end on `flint: commit ok`, run 07 ends on `flint: status ws=a`, and
# run 10 ends on `flint: merge conflicts=1`.

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

vgate_setup_python <<'PY'
import json, os, shutil, sys

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

print("staged FLINT.ELF, GOSH.ELF, /host/FLINTC, /host/FLINTW, /host/FLINTV, /host/FLINTJ, nosign-share, clean-share, and conflict-share (%d files, %d atoms)" % (manifest["files"], len(atoms)))
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
