# live-vlfs-crash.spec -- M100e/M100g (issues #2310/#2312, ADR 0050 D5)
# class-B: the STANDING crash-resilience acceptance gate. The M100e
# kill-mid-write proof at vgate_repeat 5 is the permanent record; M100g
# raised the default from 3 so every invocation is itself K=5 consecutive
# kill/remount cycles.
#
# gate: crash recovery on real VZ hardware. Three legs over data-disk
# images built in setup; the kill is the runner's own vm.stop (a hard
# power-off) reached when --script-expect matches and the claim-4912 tail
# window expires mid-workload.
#   01/02 write-stream pair (vlfs.img): commit ANCHOR.TXT + fsync, print
#     the marker, keep streaming TAIL.BIN. 02 remounts and proves A
#     byte-exact and TAIL absent-or-committed-prefix, never half-present.
#   03/04 metadata-storm pair (vlfs2.img): the same kill shape over
#     mkdir/write/mv/rm (dirent + inode txns, not a payload stream).
#   05 deterministic replay (replay.img): a crafted image whose journal
#     holds one committed-but-uncheckpointed txn installing REPLAY.TXT;
#     run 04's assert re-crafts it per repeat so 05 always replays.
# M172e (#3043, ADR 0061): the sealed pass + the canary.
#   06/07 the 01/02 pair re-run on a sealed v2 image (vlfs-s.img, built by
#     mkfs.vlfs --seal in setup): the runner types the passphrase at the
#     unseal prompt, the same kill lands mid-stream, 07 unseals/remounts
#     and proves the same replay contract. mkfs.vlfs --check with the
#     passphrase must report no hard findings on the killed image.
#   08 the 05 leg re-run sealed (replay-s.img, crafted by mkreplay.py
#     --seal — the tool's own code built via `go build -overlay`, never
#     hand-rolled crypto); re-crafted by run 07's assert per repeat.
#   09/10 the canary pair: both boots write CANARY-<random> to
#     /disk/CANARY.TXT, fsync, power off. 10's python assert scans the
#     sealed image for the canary bytes and requires ZERO hits, then the
#     plaintext twin vlfs-c.img for >= 1 (the scan works). "The host
#     cannot read the disk" is the bet this leg turns into a gate.
# A python assert runs mkfs.vlfs --check (built in setup) on the killed
# image BEFORE its remount: only journal_torn/journal_unreplayed infos are
# legal, and run 02/04/07 must then print `vlfs: replayed` when unreplayed
# txns were seen. Honesty bound: stop() preserves completed requests, so
# this proves replay + ordering at completed-request granularity, not
# FLUSH correctness under a host power cut (that is the class-A crash-state
# enumerator in kernel/src/vlfs/write.zig tests).

vgate_name live-vlfs-crash "M100e/g (#2310/#2312) class-B: STANDING crash-resilience gate — kill-mid-write -> remount replay consistency"
vgate_fmt kernel/src/main.zig kernel/src/vlfs/*.zig build.zig
vgate_repeat 5 BOOTS
vgate_note "K=5 consecutive full-spec runs green is the M100g acceptance record (BOOTS overrides the default 5)"

# mkreplay.py: rebuild replay.img fresh — an empty 16 MiB golden volume
# plus one committed, uncheckpointed journal txn that installs REPLAY.TXT
# (ibitmap + itable + bbitmap + root dirent + data payloads). Mount must
# replay seq 1 to see the file at all; the home blocks for those regions
# carry no trace of it.
vgate_file mkreplay.py <<'PY'
import struct, subprocess, sys
from pathlib import Path

BLK = 4096
# 16 MiB golden geometry (pinned by the kernel tests): journal 2..513,
# ibitmap 514, bbitmap 515, itable 516..523, data region 524.. and the
# root directory's dirent block is data_first = 524.
JOURNAL_FIRST, IBITMAP, BBITMAP, ITABLE, DATA_FIRST = 2, 514, 515, 516, 524


def fnv(b):
    h = 2166136261
    for c in b:
        h = ((h ^ c) * 16777619) & 0xFFFFFFFF
    return h


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

ino, data_blk = 2, DATA_FIRST + 1
content = b"replayed-by-vlfs-journal\n"

ib = bytearray(img[IBITMAP * BLK:(IBITMAP + 1) * BLK])
ib[ino // 8] |= 1 << (ino % 8)
bb = bytearray(img[BBITMAP * BLK:(BBITMAP + 1) * BLK])
bb[data_blk // 8] |= 1 << (data_blk % 8)
it = bytearray(img[ITABLE * BLK:(ITABLE + 1) * BLK])
rec = bytearray(it[ino * 128:(ino + 1) * 128])
rec[0] = 1                                            # kind = file
struct.pack_into("<H", rec, 2, 1)                     # nextents
struct.pack_into("<I", rec, 4, len(content))          # size
struct.pack_into("<Q", rec, 8, 1760000000)            # mtime
struct.pack_into("<Q", rec, 16, 1760000000)           # ctime
struct.pack_into("<II", rec, 24, data_blk, 1)         # extent 0
struct.pack_into("<I", rec, 124, fnv(rec[:124]))      # cksum
it[ino * 128:(ino + 1) * 128] = rec
root = bytearray(img[DATA_FIRST * BLK:(DATA_FIRST + 1) * BLK])
de = bytearray(272)
struct.pack_into("<IH", de, 0, ino, 10)
de[6] = 1                                             # kind = file
de[16:26] = b"REPLAY.TXT"
root[0:272] = de
data = bytearray(BLK)
data[:len(content)] = content

# --seal: a v2 volume's bbitmap also marks the tag homes allocated (the
# last ceil((vb-2)/147) blocks). The journaled payload must carry them
# too — it is what the mount's replay lands.
if sys.argv[1] == "--seal":
    vb = len(img) // BLK
    for b in range(vb - (vb - 2 + 146) // 147, vb):
        bb[b // 8] |= 1 << (b % 8)

payloads = {IBITMAP: bytes(ib), BBITMAP: bytes(bb), ITABLE: bytes(it),
            DATA_FIRST: bytes(root), data_blk: bytes(data)}
dests = sorted(payloads)
for i, d in enumerate(dests):
    img[(JOURNAL_FIRST + 1 + i) * BLK:(JOURNAL_FIRST + 2 + i) * BLK] = payloads[d]
desc = bytearray(BLK)
struct.pack_into("<I", desc, 0, 0x4353444A)             # "JDSC"
struct.pack_into("<Q", desc, 4, 1)                      # seq = applied+1
struct.pack_into("<H", desc, 12, len(dests))
for i, d in enumerate(dests):
    struct.pack_into("<II", desc, 16 + 8 * i, d, fnv(payloads[d]))
struct.pack_into("<I", desc, BLK - 4, fnv(desc[:BLK - 4]))
img[JOURNAL_FIRST * BLK:(JOURNAL_FIRST + 1) * BLK] = desc
commit = bytearray(BLK)
struct.pack_into("<I", commit, 0, 0x544D434A)           # "JCMT"
struct.pack_into("<Q", commit, 4, 1)
txn = bytes(desc[:16 + 8 * len(dests)]) + b"".join(payloads[d] for d in dests)
struct.pack_into("<I", commit, 12, fnv(txn))
struct.pack_into("<I", commit, BLK - 4, fnv(commit[:BLK - 4]))
img[(JOURNAL_FIRST + 1 + len(dests)) * BLK:(JOURNAL_FIRST + 2 + len(dests)) * BLK] = commit

if sys.argv[1] == "--seal":
    # M172e: the same crafted image as a sealed v2 volume. The plaintext
    # goes to a scratch file and `sealimg` — built in setup from
    # tools/go/vlfs' own sources via `go build -overlay` — runs the tool's
    # own seal code path over it (the ADR 0061 format, not hand-rolled
    # crypto in this script).
    passfile, out = sys.argv[2], sys.argv[3]
    tmp = Path(out).with_suffix(".plain.img")
    tmp.write_bytes(bytes(img))
    sealimg = Path(sys.argv[0]).resolve().parent / "sealimg"
    subprocess.check_call([str(sealimg), passfile, str(tmp), out])
    print("replay-s.img crafted+sealed: committed-uncheckpointed txn seq=1")
else:
    Path(sys.argv[1]).write_bytes(bytes(img))
    print("replay.img crafted: committed-uncheckpointed txn seq=1, 5 payloads")
PY

vgate_file sealimg.go <<'EOF'
// sealimg — seals an EXISTING crafted plaintext image as a v2 volume.
// The spec builds it over tools/go/vlfs with `go build -overlay`
// replacing main.go, so every format/AEAD byte below is the tool's own
// code path; this driver only reorders the calls (ADR 0061, M172e — the
// sealed replay image is crafted through the tool, not hand-written).
//
// Usage: sealimg <pass-file> <plain.img> <sealed-out.img>
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
)

func fail(v any) {
	fmt.Fprintln(os.Stderr, "sealimg:", v)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: sealimg <pass-file> <plain.img> <sealed.img>")
		os.Exit(2)
	}
	pass, err := os.ReadFile(os.Args[1])
	if err != nil {
		fail(err)
	}
	pass = bytes.TrimRight(pass, "\r\n")
	img, err := os.ReadFile(os.Args[2])
	if err != nil {
		fail(err)
	}
	g, err := geometryFor(uint64(len(img)))
	if err != nil {
		fail(err)
	}
	g, err = sealedGeometry(g)
	if err != nil {
		fail(err)
	}
	// Carve the tag region off the end of the data region exactly as
	// formatSealedImage does: shrink data_blocks in both superblocks
	// (writeSealFields restamps the checksum over all of it) and mark the
	// tag homes allocated in the bbitmap.
	for slot := uint32(0); slot < 2; slot++ {
		binary.LittleEndian.PutUint32(block(img, slot)[sbDataBlocks:], g.DataBlocks)
	}
	bb := block(img, g.BbitmapFirst)
	for i := g.TagFirst; i < g.VolumeBlocks; i++ {
		bitmapSet(bb, i)
	}
	volID := binary.LittleEndian.Uint64(block(img, 0)[sbVolumeID:])
	p, err := newSealParams(4000) // gate iters — the passphrase is RUN_DIR-local
	if err != nil {
		fail(err)
	}
	for slot := uint32(0); slot < 2; slot++ {
		if err := writeSealFields(block(img, slot), g, volID, &p, pass); err != nil {
			fail(err)
		}
	}
	if err := sealBlocks(img, g, volID, &p.dek); err != nil {
		fail(err)
	}
	if err := os.WriteFile(os.Args[3], img, 0o644); err != nil {
		fail(err)
	}
}
EOF

vgate_setup_python <<'PY'
import os, subprocess, sys
from pathlib import Path

run = Path(os.environ["RUN_DIR"])
for name in ("vlfs.img", "vlfs2.img"):
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
    (run / name).write_bytes(bytes(img))

subprocess.check_call(["python3", str(run / "mkreplay.py"), str(run / "replay.img")])

# The checker under test, built once; the assert hooks invoke the binary.
subprocess.check_call(["go", "-C", "tools/go/vlfs", "build",
                       "-o", str(run / "mkfs.vlfs"), "."])

# --- M172e: sealed images, the sealer driver, and the canary --------------
# sealimg is built over the tool's own sources via `go build -overlay`:
# main.go is replaced by the RUN_DIR driver, so every format/AEAD byte is
# tools/go/vlfs code.
import json
overlay = {"Replace": {str(Path("tools/go/vlfs/main.go").resolve()):
                       str(run / "sealimg.go")}}
(run / "sealimg-overlay.json").write_text(json.dumps(overlay))
subprocess.check_call(["go", "-C", "tools/go/vlfs", "build",
                       "-overlay", str(run / "sealimg-overlay.json"),
                       "-o", str(run / "sealimg"), "."])

(run / "pass.txt").write_text("swordfish\n")
for name in ("vlfs-s.img", "vlfs-cs.img"):
    subprocess.check_call([str(run / "mkfs.vlfs"), "--seal",
                           "--passphrase-file", str(run / "pass.txt"),
                           "-mib", "16", "-kdf-iters", "4000",
                           str(run / name)])

# The sealed replay image: same crafted txn, sealed through the tool.
subprocess.check_call(["python3", str(run / "mkreplay.py"), "--seal",
                       str(run / "pass.txt"), str(run / "replay-s.img")])
out = subprocess.run([str(run / "mkfs.vlfs"), "--check",
                      "--passphrase-file", str(run / "pass.txt"),
                      str(run / "replay-s.img")],
                     capture_output=True, text=True)
if out.returncode != 0 or "journal_unreplayed" not in out.stdout:
    sys.exit("replay-s.img fsck: rc=%d\n%s" % (out.returncode, out.stdout))
print("replay-s.img sealed fsck:", out.stdout.strip().replace("\n", " | "))

# The plaintext canary twin and the per-run canary bytes.
img = None
for line in Path("kernel/src/vlfs/testdata/empty-16m.regions").read_text().splitlines():
    if not line or line.startswith("#") or line == "vlfs-regions 1":
        continue
    if line.startswith("bytes "):
        img = bytearray(int(line[6:]))
        continue
    off, hexs = line.split(" ", 1)
    img[int(off):int(off) + len(hexs) // 2] = bytes.fromhex(hexs)
(run / "vlfs-c.img").write_bytes(bytes(img))

import secrets
canary = "CANARY-" + secrets.token_hex(12)
(run / "canary.txt").write_text(canary)
(run / "script-pass.txt").write_text("swordfish\n")
(run / "script-ws1.txt").write_text(
    "vf rm /disk/TAIL.BIN\n"
    "write /disk/ANCHOR.TXT virelai vlfs crash anchor\n"
    "vf fsync /disk\n"
    "echo vlfs-committed-anchor-s1\n"
    "vf write /disk/TAIL.BIN 12000000\n")
(run / "script-canary.txt").write_text(
    "write /disk/CANARY.TXT %s\n"
    "vf fsync /disk\n"
    "echo canary-plain-done\n" % canary)
(run / "script-canary-s.txt").write_text(
    "write /disk/CANARY.TXT %s\n"
    "vf fsync /disk\n"
    "echo canary-sealed-done\n" % canary)
print("canary: %s" % canary)

# fsck on the crafted image must report journal_unreplayed and NOTHING
# hard — the as-replayed overlay is a consistent populated volume.
out = subprocess.run([str(run / "mkfs.vlfs"), "--check", str(run / "replay.img")],
                     capture_output=True, text=True)
if out.returncode != 0 or "journal_unreplayed" not in out.stdout:
    sys.exit("replay.img fsck: rc=%d\n%s" % (out.returncode, out.stdout))
print("images built; replay.img fsck:", out.stdout.strip().replace("\n", " | "))
PY

# --- leg 1: kill mid file-write stream -------------------------------------
vgate_file script-w1.txt <<'EOF'
vf rm /disk/TAIL.BIN
write /disk/ANCHOR.TXT virelai vlfs crash anchor
vf fsync /disk
echo vlfs-committed-anchor-1
vf write /disk/TAIL.BIN 12000000
EOF

vgate_file script-v1.txt <<'EOF'
vf cat /disk/ANCHOR.TXT
vf cat /disk/TAIL.BIN
vf ls /disk
echo vlfs-verify-1-done
EOF

# warm-cold: 01,02,03,04,05,06,07,08,09,10 (f) every leg sequences on a shared --data-disk
#   image a sibling leg or assert built/crashed (02 verifies 01's killed
#   vlfs.img, 04 verifies 03's, 05 replays the image 04's assert re-crafts)
#   — the image is outside the bundle so warm isolation never carries it
#   (ADR 0059 D7(f))
vgate_run 01 -- --data-disk '$RUN_DIR/vlfs.img' --script '$RUN_DIR/script-w1.txt' --script-expect 'vlfs-committed-anchor-1' --script-expect-tail 1.5 --timeout 90

vgate_assert 01 output-contains 'data-disk: ENABLED'
vgate_assert 01 output-contains 'vm-stop: state='
vgate_assert 01 serial-contains 'vlfs: mounted /disk'
vgate_assert 01 serial-contains 'write: ok (journaled 25 bytes to disk:ANCHOR.TXT)'
vgate_assert 01 serial-contains 'vf: fsync /disk ok (FLUSH completed)'
vgate_assert 01 serial-echo 'vf write /disk/TAIL.BIN 12000000'
vgate_assert 01 serial-absent 'vf: write disk:TAIL.BIN'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, subprocess, sys
run = os.environ["RUN_DIR"]
out = subprocess.run([run + "/mkfs.vlfs", "--check", run + "/vlfs.img"],
                     capture_output=True, text=True)
open(run + "/killed1.findings", "w").write(out.stdout)
if out.returncode != 0:
    sys.exit("killed vlfs.img has hard fsck findings:\n" + out.stdout)
for line in out.stdout.splitlines():
    if not (line.startswith("info: journal_") or line == "check: clean"):
        sys.exit("unexpected fsck line on killed image: " + line)
print("killed vlfs.img:", out.stdout.strip().replace("\n", " | "))
PY

vgate_run 02 -- --data-disk '$RUN_DIR/vlfs.img' --script '$RUN_DIR/script-v1.txt' --script-expect 'vlfs-verify-1-done' --timeout 90

vgate_assert 02 output-contains 'data-disk: ENABLED'
vgate_assert 02 serial-contains 'vlfs: mounted /disk'
vgate_assert 02 serial-absent 'vlfs: mount refused'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, re, subprocess, sys
run, ser = os.environ["RUN_DIR"], open(os.environ["VG_SER"], errors="replace").read()

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

anchor = b"virelai vlfs crash anchor"
want = "vf: cat ok bytes=25 rts=1 cksum=0x%04x" % cksum(anchor)
if want not in ser:
    sys.exit("FAIL: anchor not byte-exact after remount (want %r)" % want)

# TAIL.BIN: absent, empty, or a committed-prefix of the stream pattern —
# every vf-write chunk is one transaction, so any other shape means a
# torn commit surfaced as live bytes.
tail_total = 12000000
m = re.search(r"vf: cat disk:TAIL\.BIN size=(\d+)", ser)
if m is None:
    if "vf cat: disk:TAIL.BIN: not_found" not in ser:
        sys.exit("FAIL: TAIL.BIN neither readable nor named-refused")
    print("TAIL.BIN absent at remount")
else:
    size = int(m.group(1))
    mm = re.search(r"vf: cat ok bytes=%d rts=\d+ cksum=0x([0-9a-f]{4})" % size, ser)
    if not mm:
        sys.exit("FAIL: TAIL.BIN size=%d but no matching cat-ok line" % size)
    if not (size % 32768 == 0 or size == tail_total):
        sys.exit("FAIL: TAIL.BIN size %d is not a committed-chunk prefix" % size)
    pat = bytes(i % 251 for i in range(size))
    if int(mm.group(1), 16) != cksum(pat):
        sys.exit("FAIL: TAIL.BIN cksum mismatch at size %d" % size)
    print("TAIL.BIN committed prefix: %d bytes" % size)

# If the killed image carried committed-unreplayed txns, this boot's mount
# must have replayed them — the serial marker is the evidence.
killed = open(run + "/killed1.findings").read()
if "journal_unreplayed" in killed and "vlfs: replayed 0x" not in ser:
    sys.exit("FAIL: killed image had live txns but mount printed no replay")

# Post-remount image must be fully consistent: no hard findings and the
# journal is drained (journal_unreplayed cannot persist past a replay).
out = subprocess.run([run + "/mkfs.vlfs", "--check", run + "/vlfs.img"],
                     capture_output=True, text=True)
if out.returncode != 0 or "journal_unreplayed" in out.stdout:
    sys.exit("post-remount fsck not clean: rc=%d\n%s" % (out.returncode, out.stdout))
print("post-remount fsck:", out.stdout.strip().replace("\n", " | "))
PY

# --- leg 2: kill mid metadata storm (dirent/inode txns) --------------------
vgate_file script-w2.txt <<'EOF'
write /disk/ANCHOR2.TXT storm anchor committed bytes
vf fsync /disk
echo vlfs-committed-anchor-2
vf mkdir /disk/S0
write /disk/S0/F0.TXT storm file zero
vf mv /disk/S0/F0.TXT /disk/F0.TXT
write /disk/M0.TXT marker file zero
vf rm /disk/M0.TXT
vf mkdir /disk/S1
write /disk/S1/F1.TXT storm file one
vf mv /disk/S1/F1.TXT /disk/F1.TXT
write /disk/M1.TXT marker file one
vf rm /disk/M1.TXT
vf mkdir /disk/S2
write /disk/S2/F2.TXT storm file two
vf mv /disk/S2/F2.TXT /disk/F2.TXT
write /disk/M2.TXT marker file two
vf rm /disk/M2.TXT
vf mkdir /disk/S3
write /disk/S3/F3.TXT storm file three
vf mv /disk/S3/F3.TXT /disk/F3.TXT
write /disk/M3.TXT marker file three
vf rm /disk/M3.TXT
vf mkdir /disk/S4
write /disk/S4/F4.TXT storm file four
vf mv /disk/S4/F4.TXT /disk/F4.TXT
write /disk/M4.TXT marker file four
vf rm /disk/M4.TXT
vf mkdir /disk/S5
write /disk/S5/F5.TXT storm file five
vf mv /disk/S5/F5.TXT /disk/F5.TXT
write /disk/M5.TXT marker file five
vf rm /disk/M5.TXT
vf mkdir /disk/S6
write /disk/S6/F6.TXT storm file six
vf mv /disk/S6/F6.TXT /disk/F6.TXT
write /disk/M6.TXT marker file six
vf rm /disk/M6.TXT
vf mkdir /disk/S7
write /disk/S7/F7.TXT storm file seven
vf mv /disk/S7/F7.TXT /disk/F7.TXT
write /disk/M7.TXT marker file seven
vf rm /disk/M7.TXT
vf mkdir /disk/S8
write /disk/S8/F8.TXT storm file eight
vf mv /disk/S8/F8.TXT /disk/F8.TXT
write /disk/M8.TXT marker file eight
vf rm /disk/M8.TXT
vf mkdir /disk/S9
write /disk/S9/F9.TXT storm file nine
vf mv /disk/S9/F9.TXT /disk/F9.TXT
write /disk/M9.TXT marker file nine
vf rm /disk/M9.TXT
echo vlfs-storm-done
EOF

vgate_file script-v2.txt <<'EOF'
vf cat /disk/ANCHOR2.TXT
vf ls /disk
vf cat /disk/F0.TXT
vf cat /disk/F1.TXT
vf cat /disk/F2.TXT
vf cat /disk/F3.TXT
vf cat /disk/F4.TXT
vf cat /disk/F5.TXT
vf cat /disk/F6.TXT
vf cat /disk/F7.TXT
vf cat /disk/F8.TXT
vf cat /disk/F9.TXT
vf cat /disk/M0.TXT
vf cat /disk/M1.TXT
vf cat /disk/M2.TXT
vf cat /disk/M3.TXT
vf cat /disk/M4.TXT
vf cat /disk/M5.TXT
vf cat /disk/M6.TXT
vf cat /disk/M7.TXT
vf cat /disk/M8.TXT
vf cat /disk/M9.TXT
echo vlfs-verify-2-done
EOF

vgate_run 03 -- --data-disk '$RUN_DIR/vlfs2.img' --script '$RUN_DIR/script-w2.txt' --script-expect 'vlfs-committed-anchor-2' --script-expect-tail 1 --timeout 90

vgate_assert 03 output-contains 'data-disk: ENABLED'
vgate_assert 03 output-contains 'vm-stop: state='
vgate_assert 03 serial-contains 'vlfs: mounted /disk'
vgate_assert 03 serial-contains 'write: ok (journaled 28 bytes to disk:ANCHOR2.TXT)'
vgate_assert 03 serial-contains 'vf: fsync /disk ok (FLUSH completed)'
vgate_assert 03 serial-absent 'vlfs-storm-done'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, subprocess, sys
run = os.environ["RUN_DIR"]
out = subprocess.run([run + "/mkfs.vlfs", "--check", run + "/vlfs2.img"],
                     capture_output=True, text=True)
open(run + "/killed2.findings", "w").write(out.stdout)
if out.returncode != 0:
    sys.exit("killed vlfs2.img has hard fsck findings:\n" + out.stdout)
for line in out.stdout.splitlines():
    if not (line.startswith("info: journal_") or line == "check: clean"):
        sys.exit("unexpected fsck line on killed image: " + line)
print("killed vlfs2.img:", out.stdout.strip().replace("\n", " | "))
PY

vgate_run 04 -- --data-disk '$RUN_DIR/vlfs2.img' --script '$RUN_DIR/script-v2.txt' --script-expect 'vlfs-verify-2-done' --timeout 90

vgate_assert 04 output-contains 'data-disk: ENABLED'
vgate_assert 04 serial-contains 'vlfs: mounted /disk'
vgate_assert 04 serial-absent 'vlfs: mount refused'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import os, re, subprocess, sys
run, ser = os.environ["RUN_DIR"], open(os.environ["VG_SER"], errors="replace").read()

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

anchor = b"storm anchor committed bytes"
want = "vf: cat ok bytes=28 rts=1 cksum=0x%04x" % cksum(anchor)
if want not in ser:
    sys.exit("FAIL: anchor2 not byte-exact after remount (want %r)" % want)

# Every storm file is absent, created-empty, or byte-exact complete —
# writeWhole is create + write in separate transactions, so a killed
# publish yields exactly those states and never a half-present file.
words = {i: ("zero", "one", "two", "three", "four", "five", "six", "seven",
             "eight", "nine")[i] for i in range(10)}
for pref, what in (("F", "storm file "), ("M", "marker file ")):
    for i in range(10):
        name = "%s%d.TXT" % (pref, i)
        content = (what + words[i]).encode()
        if "vf cat: disk:%s: not_found" % name in ser:
            continue
        m = re.search(r"vf: cat disk:%s size=(\d+)\nvf: cat ok bytes=\d+ rts=\d+ cksum=0x([0-9a-f]{4})"
                      % name, ser)
        if not m:
            sys.exit("FAIL: %s produced no consistent cat result" % name)
        size, got = int(m.group(1)), int(m.group(2), 16)
        if size == 0:
            continue
        if size != len(content) or got != cksum(content):
            sys.exit("FAIL: %s size=%d cksum=%04x vs full %d/%04x"
                     % (name, size, got, len(content), cksum(content)))

killed = open(run + "/killed2.findings").read()
if "journal_unreplayed" in killed and "vlfs: replayed 0x" not in ser:
    sys.exit("FAIL: killed image had live txns but mount printed no replay")

out = subprocess.run([run + "/mkfs.vlfs", "--check", run + "/vlfs2.img"],
                     capture_output=True, text=True)
if out.returncode != 0 or "journal_unreplayed" in out.stdout:
    sys.exit("post-remount fsck not clean: rc=%d\n%s" % (out.returncode, out.stdout))
# Re-craft the deterministic replay image for the next repeat cycle.
subprocess.check_call(["python3", run + "/mkreplay.py", run + "/replay.img"])
print("post-remount fsck:", out.stdout.strip().replace("\n", " | "))
PY

# --- leg 3: deterministic mount replay on a crafted killed image -----------
vgate_file script-r.txt <<'EOF'
vf cat /disk/REPLAY.TXT
vf ls /disk
echo vlfs-replay-done
EOF

vgate_run 05 -- --data-disk '$RUN_DIR/replay.img' --script '$RUN_DIR/script-r.txt' --script-expect 'vlfs-replay-done' --timeout 90

# --- M172e legs: the sealed pass -------------------------------------------
# Every sealed leg forwards two scripts: the passphrase after the unseal
# prompt marker, then the leg script after the shell prompt (the
# live-vlfs-blk sealed-leg shape). 'swordfish' must never reach serial.

vgate_run 06 -- --data-disk '$RUN_DIR/vlfs-s.img' \
    --script '$RUN_DIR/script-pass.txt' --script-after 'vlfs: sealed — passphrase: ' \
    --script2 '$RUN_DIR/script-ws1.txt' --script2-after 'virelai> ' \
    --script-expect 'vlfs-committed-anchor-s1' --script-expect-tail 1.5 --timeout 120

vgate_assert 06 output-contains 'data-disk: ENABLED'
vgate_assert 06 output-contains 'vm-stop: state='
vgate_assert 06 serial-contains 'vlfs: sealed — unsealed'
vgate_assert 06 serial-contains 'vlfs: mounted /disk'
vgate_assert 06 serial-contains 'write: ok (journaled 25 bytes to disk:ANCHOR.TXT)'
vgate_assert 06 serial-contains 'vf: fsync /disk ok (FLUSH completed)'
vgate_assert 06 serial-echo 'vf write /disk/TAIL.BIN 12000000'
vgate_assert 06 serial-absent 'vf: write disk:TAIL.BIN'
vgate_assert 06 serial-absent 'swordfish'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 python <<'PY'
import os, subprocess, sys
run = os.environ["RUN_DIR"]
out = subprocess.run([run + "/mkfs.vlfs", "--check",
                      "--passphrase-file", run + "/pass.txt",
                      run + "/vlfs-s.img"], capture_output=True, text=True)
open(run + "/killed-s1.findings", "w").write(out.stdout)
if out.returncode != 0:
    sys.exit("killed vlfs-s.img has hard fsck findings:\n" + out.stdout)
for line in out.stdout.splitlines():
    if not (line.startswith("info: journal_") or line == "check: clean"):
        sys.exit("unexpected fsck line on killed sealed image: " + line)
print("killed vlfs-s.img:", out.stdout.strip().replace("\n", " | "))
PY

vgate_run 07 -- --data-disk '$RUN_DIR/vlfs-s.img' \
    --script '$RUN_DIR/script-pass.txt' --script-after 'vlfs: sealed — passphrase: ' \
    --script2 '$RUN_DIR/script-v1.txt' --script2-after 'virelai> ' \
    --script-expect 'vlfs-verify-1-done' --timeout 120

vgate_assert 07 output-contains 'data-disk: ENABLED'
vgate_assert 07 serial-contains 'vlfs: sealed — unsealed'
vgate_assert 07 serial-contains 'vlfs: mounted /disk'
vgate_assert 07 serial-absent 'vlfs: mount refused'
vgate_assert 07 serial-absent 'swordfish'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 python <<'PY'
import os, re, subprocess, sys
run, ser = os.environ["RUN_DIR"], open(os.environ["VG_SER"], errors="replace").read()

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

anchor = b"virelai vlfs crash anchor"
want = "vf: cat ok bytes=25 rts=1 cksum=0x%04x" % cksum(anchor)
if want not in ser:
    sys.exit("FAIL: anchor not byte-exact after sealed remount (want %r)" % want)

tail_total = 12000000
m = re.search(r"vf: cat disk:TAIL\.BIN size=(\d+)", ser)
if m is None:
    if "vf cat: disk:TAIL.BIN: not_found" not in ser:
        sys.exit("FAIL: TAIL.BIN neither readable nor named-refused")
    print("TAIL.BIN absent at remount")
else:
    size = int(m.group(1))
    mm = re.search(r"vf: cat ok bytes=%d rts=\d+ cksum=0x([0-9a-f]{4})" % size, ser)
    if not mm:
        sys.exit("FAIL: TAIL.BIN size=%d but no matching cat-ok line" % size)
    if not (size % 32768 == 0 or size == tail_total):
        sys.exit("FAIL: TAIL.BIN size %d is not a committed-chunk prefix" % size)
    pat = bytes(i % 251 for i in range(size))
    if int(mm.group(1), 16) != cksum(pat):
        sys.exit("FAIL: TAIL.BIN cksum mismatch at size %d" % size)
    print("TAIL.BIN committed prefix: %d bytes" % size)

killed = open(run + "/killed-s1.findings").read()
if "journal_unreplayed" in killed and "vlfs: replayed 0x" not in ser:
    sys.exit("FAIL: killed sealed image had live txns but mount printed no replay")

# Post-remount image must be fully consistent through the AEAD layer:
# every sealed block's tag verifies and the journal is drained.
out = subprocess.run([run + "/mkfs.vlfs", "--check",
                      "--passphrase-file", run + "/pass.txt",
                      run + "/vlfs-s.img"], capture_output=True, text=True)
if out.returncode != 0 or "journal_unreplayed" in out.stdout:
    sys.exit("post-remount sealed fsck not clean: rc=%d\n%s" % (out.returncode, out.stdout))
print("post-remount sealed fsck:", out.stdout.strip().replace("\n", " | "))

# Re-craft the sealed replay image for the next repeat cycle.
subprocess.check_call(["python3", run + "/mkreplay.py", "--seal",
                       run + "/pass.txt", run + "/replay-s.img"])
PY

vgate_run 08 -- --data-disk '$RUN_DIR/replay-s.img' \
    --script '$RUN_DIR/script-pass.txt' --script-after 'vlfs: sealed — passphrase: ' \
    --script2 '$RUN_DIR/script-r.txt' --script2-after 'virelai> ' \
    --script-expect 'vlfs-replay-done' --timeout 120

vgate_assert 08 output-contains 'data-disk: ENABLED'
vgate_assert 08 serial-contains 'vlfs: sealed — unsealed'
vgate_assert 08 serial-contains 'vlfs: mounted /disk'
vgate_assert 08 serial-contains 'vlfs: replayed 0x0000000000000001 txn(s) from the journal'
vgate_assert 08 serial-absent 'swordfish'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 python <<'PY'
import os, re, subprocess, sys
run, ser = os.environ["RUN_DIR"], open(os.environ["VG_SER"], errors="replace").read()

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

content = b"replayed-by-vlfs-journal\n"
want = "vf: cat ok bytes=%d rts=1 cksum=0x%04x" % (len(content), cksum(content))
if want not in ser:
    sys.exit("FAIL: REPLAY.TXT not byte-exact after sealed replay (want %r)" % want)

out = subprocess.run([run + "/mkfs.vlfs", "--check",
                      "--passphrase-file", run + "/pass.txt",
                      run + "/replay-s.img"], capture_output=True, text=True)
if out.returncode != 0 or "journal_unreplayed" in out.stdout:
    sys.exit("post-replay sealed fsck not clean: rc=%d\n%s" % (out.returncode, out.stdout))
print("post-replay sealed fsck:", out.stdout.strip().replace("\n", " | "))
PY

# --- M172e legs: the canary -------------------------------------------------
# 09 writes CANARY-<random> to a plaintext image, 10 the same bytes to a
# sealed one; 10's assert scans both raw images — zero hits sealed, at
# least one plaintext (the scan is proven to work).

vgate_run 09 -- --data-disk '$RUN_DIR/vlfs-c.img' --script '$RUN_DIR/script-canary.txt' --script-expect 'canary-plain-done' --timeout 90

vgate_assert 09 output-contains 'data-disk: ENABLED'
vgate_assert 09 serial-contains 'vlfs: mounted /disk'
vgate_assert 09 serial-contains 'write: ok (journaled 31 bytes to disk:CANARY.TXT)'
vgate_assert 09 serial-contains 'vf: fsync /disk ok (FLUSH completed)'
vgate_assert 09 serial-absent '[EXC] parking:'

vgate_run 10 -- --data-disk '$RUN_DIR/vlfs-cs.img' \
    --script '$RUN_DIR/script-pass.txt' --script-after 'vlfs: sealed — passphrase: ' \
    --script2 '$RUN_DIR/script-canary-s.txt' --script2-after 'virelai> ' \
    --script-expect 'canary-sealed-done' --timeout 120

vgate_assert 10 output-contains 'data-disk: ENABLED'
vgate_assert 10 serial-contains 'vlfs: sealed — unsealed'
vgate_assert 10 serial-contains 'vlfs: mounted /disk'
vgate_assert 10 serial-contains 'write: ok (journaled 31 bytes to disk:CANARY.TXT)'
vgate_assert 10 serial-contains 'vf: fsync /disk ok (FLUSH completed)'
vgate_assert 10 serial-absent 'swordfish'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
needle = open(run + "/canary.txt", "rb").read()

def hits(path):
    img = open(path, "rb").read()
    n, pos = 0, 0
    while True:
        i = img.find(needle, pos)
        if i < 0:
            return n
        n += 1
        pos = i + 1

sealed = hits(run + "/vlfs-cs.img")
if sealed != 0:
    sys.exit("FAIL: canary found %d time(s) in sealed vlfs-cs.img — "
             "the image is not ciphertext at rest" % sealed)
plain = hits(run + "/vlfs-c.img")
if plain < 1:
    sys.exit("FAIL: canary absent from plaintext vlfs-c.img — the scan "
             "proved nothing")
print("canary: 0 hits in sealed image, %d in plaintext twin" % plain)
PY

vgate_assert 05 output-contains 'data-disk: ENABLED'
vgate_assert 05 serial-contains 'vlfs: mounted /disk'
vgate_assert 05 serial-contains 'vlfs: replayed 0x0000000000000001 txn(s) from the journal'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 python <<'PY'
import os, re, subprocess, sys
run, ser = os.environ["RUN_DIR"], open(os.environ["VG_SER"], errors="replace").read()

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

content = b"replayed-by-vlfs-journal\n"
want = "vf: cat ok bytes=%d rts=1 cksum=0x%04x" % (len(content), cksum(content))
if want not in ser:
    sys.exit("FAIL: REPLAY.TXT not byte-exact after replay (want %r)" % want)

# The replayed mount checkpointed the txn: fsck must be fully clean now.
out = subprocess.run([run + "/mkfs.vlfs", "--check", run + "/replay.img"],
                     capture_output=True, text=True)
if out.returncode != 0 or "journal_unreplayed" in out.stdout:
    sys.exit("post-replay fsck not clean: rc=%d\n%s" % (out.returncode, out.stdout))
print("post-replay fsck:", out.stdout.strip().replace("\n", " | "))
PY
