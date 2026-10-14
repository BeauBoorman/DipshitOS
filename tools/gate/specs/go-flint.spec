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
# This spec is grown across M103a-d and is NOT vgate_repeat-safe (runs 01-03
# share the primary /host store across boots).
#
# HOST PREREQ:
#   bash tools/go/build-flint.sh -> .build/go/FLINT.ELF
#   bash tools/go/build-gosh.sh  -> .build/go/GOSH.ELF
#
# exec-order: assert-proven -- run 01 ends on `flint: parse files=`, and run 02
# runs a sequential GOSH.ELF script (`source /host/FLINTJ/02.SH`) ending on
# `flint: status `.

vgate_name go-flint "M103 #2253/#2251 (ADR 0049): FLINT.ELF parser corpus, flat-file store, UUIDv7, init/add/status"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-01.txt <<'EOF'
exec FLINT.ELF parse-corpus /host/FLINTC
EOF

vgate_file script-02.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/02.SH"
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

print("staged FLINT.ELF, GOSH.ELF, /host/FLINTC, /host/FLINTW, and /host/FLINTJ (%d files, %d atoms)" % (manifest["files"], len(atoms)))
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
vgate_assert 01 serial-absent '[EXC] parking:'

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
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import json, os, re, sys

share = os.path.join(os.environ["RUN_DIR"], "share")
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
