# live-vlfs-dataroot.spec -- M100f (issue #2311, ADR 0050) class-B
#
# gate: the opt-in `/disk` data root on real VZ hardware. The default boot
# never moves; `data_root=disk` in SETTINGS.TXT moves exactly the movable
# set — GOSH's history file, the seat's notify history, and the fetch
# download default — onto the mounted VLFS volume, and a set-but-absent
# disk is a NAMED fallback to /host, never a boot failure.
#
# Runs (the share is armed fresh per run; the vlfs.img under RUN_DIR is
# shared across runs, which is what makes run C's remount leg real):
#
#   A — DEFAULT BOOT, no --data-disk and no data_root row. GOFILES's `v`
#       volumes list is the kernel's mount table (M134b #2760): one row per
#       mount — host, disk, usb, usb1..usb4 — each row naming its live
#       state. The disk row marks `not_mounted` (the kernel's refusal
#       name), and the enter refuses by name — no phantom directory, no
#       silent /host.
#
#   B — OPT-IN + MOUNTED. `settings set data_root disk` persists the row,
#       then GOSELF runs under the tabwm seat (its `disk` case writes,
#       fsyncs and reads back /disk/SELFTEST/DISK.TXT with the receipts on
#       /host), then GOSH types one line: `gosh: data_root=/disk` at the
#       latched resolve and GOSH-HISTORY.TXT lands on the volume, NOT the
#       share. Host python cross-checks: the receipt line byte-exact, the
#       420-byte read-back copy byte-exact, the share carrying NO
#       GOSH-HISTORY.TXT, and SETTINGS.TXT — the pointer file — still on
#       the share holding the row.
#
#   C — OPT-IN + MOUNTED, REMOUNT + CROSS-VOLUME COPY. The same vlfs.img
#       attaches again: `vf cat /disk/GOSH-HISTORY.TXT` reads back run B's
#       bytes (persistence across the remount, checksum-recomputed), then
#       GOFILES copies /host/FM/KNOWN.TXT onto /disk through the volumes
#       view (c, v, j, return, p) — the write side is WriteFileSafe on a
#       second partition.
#
#   D — SET-BUT-ABSENT. `settings set data_root disk` with NO --data-disk:
#       GOSH prints the named fallback `gosh: data_root=disk but /disk
#       not_mounted; using /host`, and the typed line's history lands on
#       the SHARE — the fallback is honest, not silent.
#
# HOST PREREQUISITES (fails the gate honestly when missing):
#   bash tools/go/build-goself.sh  ->  .build/go/GOSELF.ELF
#   bash tools/go/build-files.sh   ->  .build/go/GOFILES.ELF
#   bash tools/go/build-gosh.sh    ->  .build/go/GOSH.ELF

vgate_name live-vlfs-dataroot "M100f (#2311) class-B: opt-in /disk data root on VZ — default, mounted opt-in, remount copy, absent fallback"

vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# ---------------------------------------------------------------------------
# fixtures and staging

vgate_file script-A1.txt <<'EOF'
exec GOFILES.ELF /host/FM
EOF

vgate_file script-A2.txt <<'EOF'
echo rx-dataroot-default-ok
EOF

vgate_file script-B1.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script-B2.txt <<'EOF'
settings set data_root disk
exec GOSELF.ELF
EOF

vgate_file script-B3.txt <<'EOF'
exec GOSH.ELF
EOF

# Run C's first script does double duty: re-set the opt-in (fresh armed
# share), then the remount read-back of run B's persisted history — the
# proof that the write survived a detach/attach boundary.
vgate_file script-C1.txt <<'EOF'
settings set data_root disk
vf cat /disk/GOSH-HISTORY.TXT
exec GOFILES.ELF /host/FM
EOF

vgate_file script-C2.txt <<'EOF'
vf cat /disk/KNOWN.TXT
vf ls /disk
echo rx-dataroot-copy-ok
EOF

vgate_file script-D1.txt <<'EOF'
settings set data_root disk
exec GOSH.ELF
EOF

vgate_file script-D2.txt <<'EOF'
echo rx-dataroot-absent-ok
EOF

vgate_file disk-receipt.expected <<'EOF'
case disk mounted=yes path=SELFTEST/DISK.TXT wrote=441 fsync=0 read=441 match=yes
EOF

vgate_file host-history.expected <<'EOF'
echo hosthist
exit
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
from pathlib import Path
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, how in (("GOSELF.ELF", "build-goself.sh"),
                  ("GOFILES.ELF", "build-files.sh"),
                  ("GOSH.ELF", "build-gosh.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
fm = os.path.join(share, "FM")
os.makedirs(fm, exist_ok=True)
with open(os.path.join(fm, "KNOWN.TXT"), "w") as f:
    f.write("hello-from-gofiles\npreview-line-alpha\npreview-line-beta\n")
# GOSELF runs its FULL battery in run B — the same SELFTEST tree
# go-selftest.spec seeds, or every receipt write under OUT/ dies at the
# host's missing-parent refusal (a silent stHostError, -1 guest-side) and
# the intake cases' IN/ fixtures read ENOENT.
st = os.path.join(share, "SELFTEST")
for d in ("IN", "OUT"):
    os.makedirs(os.path.join(st, d), exist_ok=True)
for name, body in (("fixture.txt", b"goself intake fixture v1\n"),
                   ("altered.txt", b"goself intake fixture v2\n")):
    with open(os.path.join(st, "IN", name), "wb") as fh:
        fh.write(body)
snap_docs = os.path.join(st, "IN", "snapshot-docs")
os.makedirs(snap_docs, exist_ok=True)
for name, body in (
        ("snapshot-settings.txt", b"#v2\ntheme=amber\nwm=gotabwm\n"),
        ("snapshot-session.tabs",
         bytes([0x54, 0x41, 0x42, 0x53, 0x00, 0x02, 0x00, 0x0a,
                0xff, 0xfe, 0x10, 0x20])),
        (os.path.join("snapshot-docs", "NOTE.TXT"), b"goself snapshot note\n"),
        (os.path.join("snapshot-docs", "SECOND.TXT"),
         b"goself snapshot second document\n")):
    with open(os.path.join(st, "IN", name), "wb") as fh:
        fh.write(body)
# Rebuild the golden empty 16 MiB VLFS image from its .regions description —
# the same fixture live-vlfs-write.spec formats nothing from.
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
Path(rd, "vlfs.img").write_bytes(bytes(img))
print("staged GOSELF/GOFILES/GOSH + FM/KNOWN.TXT; vlfs.img rebuilt from golden regions")
PY

# ---------------------------------------------------------------------------
# A: the default boot — no data disk, no data_root row. The volumes view
# still exists, still names /disk, and refuses the absent mount BY NAME.

vgate_run A -- --screen '$RUN_DIR/screen-a' --input --via-virtio \
    --script '$RUN_DIR/script-A1.txt' \
    --input-chords 'v,j,return,q' --input-chords-after 'gofiles: ready' \
    --script2 '$RUN_DIR/script-A2.txt' --script2-after 'gofiles: close' \
    --script-expect 'rx-dataroot-default-ok' --timeout 120

# 'data-disk: ENABLED' is runner stdout, not guest serial — the in-guest
# evidence for the absent disk is the missing mount marker.
vgate_assert A serial-absent 'vlfs: mounted /disk'
vgate_assert A serial-absent 'data_root'
# M134b (#2760): the volumes root enumerates the kernel mount table — all
# seven rows, each naming its live state; absent rows say not_mounted.
vgate_assert A serial-contains 'gofiles: list / n=7'
vgate_assert A serial-contains 'gofiles: entry host dir'
vgate_assert A serial-contains 'gofiles: entry disk dir'
vgate_assert A serial-contains 'gofiles: entry usb file'
vgate_assert A serial-contains 'gofiles: entry usb4 dir'
vgate_assert A serial-contains 'gofiles: volume host mounted rw'
vgate_assert A serial-contains 'gofiles: volume usb not_mounted'
vgate_assert A serial-contains 'gofiles: volume usb1 not_mounted'
vgate_assert A serial-contains 'gofiles: volume disk not_mounted'
vgate_assert A serial-contains 'gofiles: volume refused disk not_mounted'
vgate_assert A serial-contains 'gofiles: close'
vgate_assert A serial-contains 'gofiles OK'
vgate_assert A serial-absent '[EXC] parking:'

# ---------------------------------------------------------------------------
# B: opt-in + mounted. The seat goes first because GOSELF's window case
# needs one; then the settings row persists, GOSELF drills the volume
# (write/fsync/readback with the receipts on /host), and GOSH's history
# follows the row onto /disk.

vgate_run B -- --screen '$RUN_DIR/screen-b' --via-virtio --input \
    --data-disk '$RUN_DIR/vlfs.img' \
    --script '$RUN_DIR/script-B1.txt' \
    --script2 '$RUN_DIR/script-B2.txt' --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script-B3.txt' --script3-after 'selftest: FAIL n=0' \
    --input-chords 'e,c,h,o,space,d,i,s,k,h,i,s,t,return,e,x,i,t,return' \
    --input-chords-after 'gosh: prompt' \
    --script-expect 'gosh OK' --timeout 300

vgate_assert B output-contains 'data-disk: ENABLED'
vgate_assert B serial-contains 'vlfs: mounted /disk'
vgate_assert B serial-contains 'settings: data_root=disk (persisted)'
vgate_assert B serial-contains 'selftest: case disk pass'
vgate_assert B serial-contains 'selftest: FAIL n=0'
# The movable set moved: GOSH's latched resolve names the volume, and the
# typed line landed there.
vgate_assert B serial-contains 'gosh: data_root=/disk'
vgate_assert B serial-contains 'gosh: line echo diskhist'
vgate_assert B serial-contains 'gosh: line exit'
vgate_assert B serial-absent 'gosh: data_root=disk but /disk not_mounted'
vgate_assert B serial-absent '[EXC] parking:'
# The receipts are the host-readable evidence: byte-exact, on the share.
vgate_assert B share-equals SELFTEST/OUT/file-disk.ok disk-receipt.expected
vgate_assert B share-contains SETTINGS.TXT 'data_root=disk'
vgate_assert B python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
# The pointer file stayed on /host carrying the row; the payload went to
# /disk. A leaked /host/GOSH-HISTORY.TXT would mean the movable set did not
# move.
hist = os.path.join(share, "GOSH-HISTORY.TXT")
if os.path.exists(hist):
    sys.exit("GOSH-HISTORY.TXT leaked onto /host with data_root=disk: %r" %
             open(hist, "rb").read())
want = ("goself file abi line\n" * 21).encode()
got = open(os.path.join(share, "SELFTEST", "OUT", "disk.copy"), "rb").read()
if got != want:
    sys.exit("disk.copy MISMATCH: %d bytes, want the %d-byte read-back pattern"
             % (len(got), len(want)))
print("share check: no GOSH-HISTORY.TXT on /host; disk.copy is the "
      "byte-exact read-back of the %d-byte volume payload" % len(want))
PY

# ---------------------------------------------------------------------------
# C: same image, second boot — the remount proof — then GOFILES copies a
# /host file onto /disk through the volumes view.

vgate_run C -- --screen '$RUN_DIR/screen-c' --via-virtio --input \
    --data-disk '$RUN_DIR/vlfs.img' \
    --script '$RUN_DIR/script-C1.txt' \
    --input-chords 'c,v,j,return,p,q' --input-chords-after 'gofiles: ready' \
    --script2 '$RUN_DIR/script-C2.txt' --script2-after 'gofiles OK' \
    --script-expect 'rx-dataroot-copy-ok' --timeout 240

vgate_assert C output-contains 'data-disk: ENABLED'
vgate_assert C serial-contains 'vlfs: mounted /disk'
# The remount leg: run B's GOSH-HISTORY.TXT is still the exact body.
vgate_assert C serial-contains 'vf: cat ok bytes=19'
# The volumes view on a mounted boot, and the copy landing. M134b (#2760):
# the row names `mounted rw` — the table's live state and flag bytes.
vgate_assert C serial-contains 'gofiles: list / n=7'
vgate_assert C serial-contains 'gofiles: volume disk mounted rw'
vgate_assert C serial-contains 'gofiles: volume host mounted rw'
vgate_assert C serial-contains 'gofiles: volume usb not_mounted'
vgate_assert C serial-contains 'gofiles: cd /disk'
vgate_assert C serial-contains 'gofiles: list /disk'
vgate_assert C serial-contains 'gofiles: entry SELFTEST dir'
vgate_assert C serial-contains 'gofiles: pasted KNOWN.TXT'
# The copied bytes on the volume, read back by the monitor afterwards.
vgate_assert C serial-contains 'vf: cat ok bytes=56'
vgate_assert C serial-absent '[EXC] parking:'
vgate_assert C python <<'PY'
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

hist = b"echo diskhist\nexit\n"
known = b"hello-from-gofiles\npreview-line-alpha\npreview-line-beta\n"
# rts counts the non-zero 4 KiB reads — one round trip for each of these.
for want in ("vf: cat ok bytes=19 rts=1 cksum=0x%04x" % cksum(hist),
             "vf: cat ok bytes=56 rts=1 cksum=0x%04x" % cksum(known)):
    if want not in ser:
        sys.exit("FAIL: %r absent in run C serial" % want)
print("run C: persisted history and the cross-volume copy both read back "
      "byte-exact (cksum-verified)")
PY

# ---------------------------------------------------------------------------
# D: the row is set but the disk is not there — the named fallback runs and
# the payload lands on the share. Boot never fails.

vgate_run D -- --screen '$RUN_DIR/screen-d' --via-virtio --input \
    --script '$RUN_DIR/script-D1.txt' \
    --input-chords 'e,c,h,o,space,h,o,s,t,h,i,s,t,return,e,x,i,t,return' \
    --input-chords-after 'gosh: prompt' \
    --script2 '$RUN_DIR/script-D2.txt' --script2-after 'gosh: close' \
    --script-expect 'rx-dataroot-absent-ok' --timeout 180

vgate_assert D serial-absent 'vlfs: mounted /disk'
vgate_assert D serial-contains 'settings: data_root=disk (persisted)'
vgate_assert D serial-contains 'gosh: data_root=disk but /disk not_mounted; using /host'
vgate_assert D serial-absent 'gosh: data_root=/disk'
vgate_assert D serial-contains 'gosh: line echo hosthist'
vgate_assert D serial-contains 'gosh: close'
# The fallback is to the share: the history file is HERE, byte-exact.
vgate_assert D share-equals GOSH-HISTORY.TXT host-history.expected
vgate_assert D serial-absent '[EXC] parking:'
