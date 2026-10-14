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
# This spec is grown across M103a-d and is NOT vgate_repeat-safe (runs 01-03
# share the primary /host store across boots).
#
# HOST PREREQ:
#   bash tools/go/build-flint.sh -> .build/go/FLINT.ELF
#   bash tools/go/build-gosh.sh  -> .build/go/GOSH.ELF
#
# exec-order: assert-proven -- run 01 ends on `flint: parse files=`, run 02
# ends on `flint: status `, run 03 ends on `sig_invalid`, and run 04 ends on
# `flint: refuse secret_not_found`.

vgate_name go-flint "M103 #2253/#2251/#2252 (ADR 0049): FLINT.ELF parser corpus, flat-file store, signed commit, log, verify"
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

print("staged FLINT.ELF, GOSH.ELF, /host/FLINTC, /host/FLINTW, /host/FLINTV, /host/FLINTJ, and nosign-share (%d files, %d atoms)" % (manifest["files"], len(atoms)))
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
