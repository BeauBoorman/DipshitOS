# live-vlfs-write.spec -- M100d (issue #2309, ADR 0050 D4/D6) class-B
#
# gate: the journaled write path on real VZ hardware. Run A formats nothing —
# the setup hook rebuilds the 16 MiB golden volume from
# kernel/src/vlfs/testdata/empty-16m.regions — boots with it as --data-disk,
# and drives the monitor verbs through real virtio-blk commits: whole-file
# write, chunked pattern write, mkdir, cross-directory rename, fsync
# (VIRTIO_BLK_T_FLUSH), and an oversized truncate that must refuse
# `txn_too_large` by name. Run B boots the SAME image — the remount leg —
# and cats both files back with their stream checksums; the byte-exactness
# assert is a recomputed expectation, not a pattern match. B then fills the
# device: `vf write` past capacity must stop with the named `no_space`
# refusal, and the earlier files still read back byte-exact after it.
# Leg C (M134c #2761): a corrupted image is refused by name at mount —
# `vlfs: mount refused check=inode_checksum` — and the boot continues
# share-only (/disk verbs answer not_mounted, the monitor keeps running).
# What this proves: commit ordering + fsync barrier + persistence across a
# remount at completed-request granularity, plus three named refusals. What
# it does NOT prove: crash-ordered replay (M100e's kill gate owns that).

vgate_name live-vlfs-write "M100d (#2309) class-B: journaled write->flush->readback->remount on VZ"

vgate_setup_python <<'PY'
import os
from pathlib import Path
# Rebuild the golden empty 16 MiB VLFS image from its .regions description
# (header + "bytes N" + <offset> <hex> lines of non-zero runs).
img = None
for line in Path("kernel/src/vlfs/testdata/empty-16m.regions").read_text().splitlines():
    if not line or line.startswith("#") or line == "vlfs-regions 1":
        continue
    if line.startswith("bytes "):
        img = bytearray(int(line[6:]))
        continue
    off, hexs = line.split(" ", 1)
    img[int(off):int(off) + len(hexs) // 2] = bytes.fromhex(hexs)
assert img is not None and len(img) == 16 * 1024 * 1024
Path(os.environ["RUN_DIR"], "vlfs.img").write_bytes(bytes(img))
print("vlfs.img rebuilt from golden regions")

# Leg C image: the committed inode-checksum fixture — the mount check
# refuses it by name (kernel/src/vlfs/testdata/gen-corrupt.py regenerates).
img = None
for line in Path("kernel/src/vlfs/testdata/corrupt-inode-checksum.regions").read_text().splitlines():
    if not line or line.startswith("#") or line == "vlfs-regions 1":
        continue
    if line.startswith("bytes "):
        img = bytearray(int(line[6:]))
        continue
    off, hexs = line.split(" ", 1)
    img[int(off):int(off) + len(hexs) // 2] = bytes.fromhex(hexs)
assert img is not None and len(img) == 16 * 1024 * 1024
Path(os.environ["RUN_DIR"], "corrupt.img").write_bytes(bytes(img))
print("corrupt.img rebuilt from the inode-checksum fixture")
PY

vgate_file script-A.txt <<'EOF'
write /disk/GATE.TXT virelai vlfs write gate
vf write /disk/PAT.BIN 20000
vf mkdir /disk/SUB
vf mv /disk/GATE.TXT /disk/SUB/MOVED.TXT
vf truncate /disk/PAT.BIN 300000
vf fsync /disk
vf cat /disk/PAT.BIN
vf cat /disk/SUB/MOVED.TXT
vf ls /disk
echo vlfs-write-a-done
EOF

vgate_file script-B.txt <<'EOF'
vf ls /disk
vf cat /disk/PAT.BIN
vf cat /disk/SUB/MOVED.TXT
vf write /disk/FILL.BIN 20000000
vf cat /disk/PAT.BIN
vf cat /disk/SUB/MOVED.TXT
vf cat /disk/FILL.BIN
vf ls /disk
echo vlfs-write-b-done
EOF

vgate_run A -- --data-disk '$RUN_DIR/vlfs.img' --script '$RUN_DIR/script-A.txt' --script-expect 'vlfs-write-a-done' --timeout 90
# warm-cold: B (f) reads files leg A wrote into the shared vlfs.img — a prior leg's side effects (ADR 0059 D7(f)); the image is outside the bundle so warm isolation never carries it
vgate_run B -- --data-disk '$RUN_DIR/vlfs.img' --script '$RUN_DIR/script-B.txt' --script-expect 'vlfs-write-b-done' --timeout 180

vgate_assert A output-contains 'data-disk: ENABLED'
vgate_assert A serial-contains 'vlfs: mounted /disk'
vgate_assert A serial-contains 'write: ok (journaled 23 bytes to disk:GATE.TXT)'
vgate_assert A serial-contains 'vf: write disk:PAT.BIN n=20000 wrote=20000 chunks=1'
vgate_assert A serial-contains 'vf: mkdir disk:SUB ok'
vgate_assert A serial-contains 'vf: mv disk:GATE.TXT -> SUB/MOVED.TXT ok'
vgate_assert A serial-contains 'vf truncate: disk:PAT.BIN: txn_too_large'
vgate_assert A serial-contains 'vf: fsync /disk ok (FLUSH completed)'
vgate_assert A serial-contains 'vf: cat ok bytes=20000'
vgate_assert A serial-contains 'vf: cat ok bytes=23'
vgate_assert A serial-absent '[EXC] parking:'
vgate_assert A python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def cksum(data):
    # StreamCksum: big-endian u16 word sum, one's-complement fold + invert.
    s, carry = 0, None
    for b in data:
        if carry is None:
            carry = b
        else:
            s += (carry << 8) | b
            carry = None
    if carry is not None:
        s += carry << 8
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

pat = bytes(i % 251 for i in range(20000))
txt = b"virelai vlfs write gate"
for want in ("cksum=0x%04x" % cksum(pat), "cksum=0x%04x" % cksum(txt)):
    if want not in ser:
        sys.exit("FAIL: %s absent in run A serial" % want)
print("run A cksums: PAT.BIN=0x%04x MOVED.TXT=0x%04x" % (cksum(pat), cksum(txt)))
PY

vgate_assert B output-contains 'data-disk: ENABLED'
vgate_assert B serial-contains 'vlfs: mounted /disk'
vgate_assert B serial-contains 'vf write: disk:FILL.BIN: no_space after '
vgate_assert B serial-contains 'vf: cat ok bytes=20000'
vgate_assert B serial-contains 'vf: cat ok bytes=23'
vgate_assert B serial-absent '[EXC] parking:'
vgate_assert B python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def cksum(data):
    s, carry = 0, None
    for b in data:
        if carry is None:
            carry = b
        else:
            s += (carry << 8) | b
            carry = None
    if carry is not None:
        s += carry << 8
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

pat = bytes(i % 251 for i in range(20000))
txt = b"virelai vlfs write gate"
# The remount must serve run A's committed bytes exactly: each full cat
# line appears once before the FILL.BIN write AND once after the no_space
# refusal (the survivors are byte-identical either side of it).
for want in ("vf: cat ok bytes=20000 rts=5 cksum=0x%04x" % cksum(pat),
             "vf: cat ok bytes=23 rts=1 cksum=0x%04x" % cksum(txt)):
    if ser.count(want) != 2:
        sys.exit("FAIL: %r occurs %d times in run B serial, want 2" % (want, ser.count(want)))
# FILL.BIN exists with an honestly short committed prefix — the refusal
# was named mid-fill, and the file still cats to a real checksum line.
m = re.search(r"vf write: disk:FILL\.BIN: no_space after (\d+) bytes", ser)
if not m or int(m.group(1)) <= 0:
    sys.exit("FAIL: no_space refusal line absent or wrote 0 bytes")
if not re.search(r"vf: cat ok bytes=\d+ rts=\d+ cksum=0x[0-9a-f]{4}", ser):
    sys.exit("FAIL: FILL.BIN readback line absent")
print("run B: remounted bytes match run A; no_space after %s bytes" % m.group(1))
PY

# --- leg C: mount-time check refuses a corrupt image by name (M134c) ------
vgate_file script-C.txt <<'EOF'
vf ls /disk
vf cat /disk/GATE.TXT
echo vlfs-corrupt-refusal-done
EOF

vgate_run C -- --data-disk '$RUN_DIR/corrupt.img' --script '$RUN_DIR/script-C.txt' --script-expect 'vlfs-corrupt-refusal-done' --timeout 90

vgate_assert C output-contains 'data-disk: ENABLED'
vgate_assert C serial-contains 'vlfs: mount refused check=inode_checksum'
vgate_assert C serial-absent 'vlfs: mounted /disk'
vgate_assert C serial-contains 'vf ls: disk:/: not_mounted'
vgate_assert C serial-contains 'vf cat: disk:GATE.TXT: not_mounted'
vgate_assert C serial-absent '[EXC] parking:'
