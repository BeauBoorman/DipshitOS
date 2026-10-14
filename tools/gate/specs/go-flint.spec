# go-flint.spec -- M103 (#2253, ADR 0049) class-B: FLINT agent-native source
# control for VirelaiOS.
#
# Run 01 (M103a #2253): proves go/parser + FLINT's Go-native Zig declaration
# scanner run in-guest over the 100-file corpus (50 .go + 50 .zig) staged at
# /host/FLINTC, producing the exact canonical Atom hashes and spans into
# /host/FLINTC.OUT (compared byte-for-byte against an independent host Python
# renderer of MANIFEST.json).
#
# This spec is grown across M103a-d and is NOT vgate_repeat-safe (runs 01-03
# share the primary /host store across boots).
#
# HOST PREREQ:
#   bash tools/go/build-flint.sh -> .build/go/FLINT.ELF
#
# exec-order: assert-proven -- run 01 ends on `flint: parse files=`, which
# only FLINT.ELF prints after publishing /host/FLINTC.OUT via WriteFileSafe.

vgate_name go-flint "M103 #2253 (ADR 0049): FLINT.ELF in-guest Go+Zig parser corpus and canonical Atom hashing"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-01.txt <<'EOF'
exec FLINT.ELF parse-corpus /host/FLINTC
EOF

vgate_setup_python <<'PY'
import json, os, shutil, sys

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

flint_elf = os.path.join(".build", "go", "FLINT.ELF")
if not os.path.isfile(flint_elf):
    sys.exit("FLINT.ELF missing (expected " + flint_elf + ") - build it first: bash tools/go/build-flint.sh")
shutil.copy(flint_elf, os.path.join(share, "FLINT.ELF"))

corpus_src = os.path.join("user", "go", "flint", "testdata", "corpus")
flintc = os.path.join(share, "FLINTC")
os.makedirs(flintc, exist_ok=True)
for sub in ("go", "zig"):
    dst = os.path.join(flintc, sub)
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(os.path.join(corpus_src, sub), dst)

manifest_src = os.path.join(corpus_src, "MANIFEST.json")
shutil.copy(manifest_src, os.path.join(flintc, "MANIFEST.json"))

manifest = json.load(open(manifest_src, "r", encoding="utf-8"))
atoms = sorted(manifest["atoms"], key=lambda a: (a["file"], int(a["start"])))
lines = [
    "%s\t%s\t%s\t%d\t%d\t%s\t%s\n" % (
        a["file"], a["kind"], a["name"], int(a["start"]), int(a["end"]), a["hash"], a["sig_hash"]
    )
    for a in atoms
]
open(os.path.join(run, "expect-corpus.txt"), "w", encoding="utf-8").writelines(lines)
print("staged FLINT.ELF and /host/FLINTC (%d files, %d atoms)" % (manifest["files"], len(atoms)))
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
