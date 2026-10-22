#!/usr/bin/env python3
# gen-corrupt.py — regenerate the corrupt-image corpus for the M134c (#2761)
# mount-time check.
#
# Each fixture is a .regions file (the committed golden shape) produced by
# mutating the empty or populated 16 MiB golden. Every fixture carries a
# `# expect: <verdict>` comment — the named refusal the guest mount must
# produce, recorded from `mkfs.vlfs --check` on the same bytes so the two
# implementations stay in verdict parity. `clean` means the image mounts.
#
# The corpus deliberately covers only the bounded mount-check surface:
# superblock pair + geometry, journal scan, inode checksums/kinds, and
# extent/bitmap consistency. Dirent/tree findings (dirent_bad,
# inode_orphan, depth_overflow) are the offline fsck's deep scan — the
# guest read path refuses those lazily — so no fixture expects them.
#
# Usage: python3 kernel/src/vlfs/testdata/gen-corrupt.py [--mkfs PATH]
#   --mkfs defaults to .build/go/mkfs.vlfs, else `go run ./tools/go/vlfs`.
# Verification is mandatory: each generated fixture is checked and its
# `# expect:` line is what the checker actually printed.

import argparse
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
TESTDATA = ROOT / "kernel/src/vlfs/testdata"

BLK = 4096
VOL_BLOCKS = 4096  # 16 MiB golden
JOURNAL_FIRST, JOURNAL_BLOCKS = 2, 512
IBITMAP, BBITMAP = 514, 515
ITABLE, ITABLE_BLOCKS = 516, 8
DATA_FIRST = 524
INODE_COUNT = 256
INODE_BYTES, INODES_PER_BLOCK = 128, 32

IN_KIND, IN_NEXTENTS, IN_SIZE, IN_EXTENTS, IN_NEXT_EXT, IN_CKSUM = 0, 2, 4, 24, 88, 124
XB_MAGIC, XB_NEXT, XB_COUNT, XB_EXTENTS, XB_CKSUM = 0, 4, 8, 12, BLK - 4
JD_MAGIC, JD_SEQ, JD_COUNT, JD_ENTRIES, JD_CKSUM = 0, 4, 12, 16, BLK - 4
JC_MAGIC, JC_SEQ, JC_TXN, JC_CKSUM = 0, 4, 12, BLK - 4
DE_INODE, DE_NAME_LEN, DE_KIND, DE_NAME = 0, 4, 6, 16
SB_VERSION, SB_VOLUME_BYTES, SB_CKSUM = 4, 24, 508

MAGIC_SB, MAGIC_DESC, MAGIC_COMMIT, MAGIC_EXTENT = 0x53464C56, 0x4353444A, 0x544D434A, 0x42455856


def fnv(b):
    h = 2166136261
    for c in b:
        h = ((h ^ c) * 16777619) & 0xFFFFFFFF
    return h


def load_regions(path):
    img = None
    for line in path.read_text().splitlines():
        if not line or line.startswith("#") or line == "vlfs-regions 1":
            continue
        if line.startswith("bytes "):
            img = bytearray(int(line[6:]))
            continue
        off, hexs = line.split(" ", 1)
        img[int(off):int(off) + len(hexs) // 2] = bytes.fromhex(hexs)
    assert img is not None
    return img


def save_regions(path, img, comment, expect):
    lines = ["vlfs-regions 1", "# corrupt: %s" % comment,
             "# expect: %s" % expect, "bytes %d" % len(img)]
    i = 0
    while i < len(img):
        if img[i] == 0:
            i += 1
            continue
        j = i
        while j < len(img) and img[j] != 0:
            j += 1
        lines.append("%d %s" % (i, img[i:j].hex()))
        i = j
    path.write_text("\n".join(lines) + "\n")


def bit(img, byte_base, i, on=True):
    if on:
        img[byte_base + i // 8] |= 1 << (i % 8)
    else:
        img[byte_base + i // 8] &= ~(1 << (i % 8)) & 0xFF


def inode_rec(img, ino):
    off = ITABLE * BLK + ino * INODE_BYTES
    return memoryview(img)[off:off + INODE_BYTES]


def seal_inode(img, ino):
    rec = inode_rec(img, ino)
    struct.pack_into("<I", rec, IN_CKSUM, fnv(rec[:IN_CKSUM]))


def seal_sb(img, slot):
    b = memoryview(img)[slot * BLK:slot * BLK + 512]
    struct.pack_into("<I", b, SB_CKSUM, fnv(b[:SB_CKSUM]))


def live_inodes(img, kind=None):
    out = []
    for i in range(1, INODE_COUNT):
        rec = inode_rec(img, i)
        if struct.unpack_from("<I", rec, IN_CKSUM)[0] != fnv(rec[:IN_CKSUM]):
            continue
        if kind is None or rec[IN_KIND] == kind:
            out.append(i)
    return out


def free_data_blocks(img):
    bb = BBITMAP * BLK
    return [b for b in range(DATA_FIRST, VOL_BLOCKS)
            if not (img[bb + b // 8] >> (b % 8)) & 1]


def journal_txn(img, pos, seq, payloads):
    """DESC + payloads + COMMIT — the bytes the kernel write path emits."""
    dests = sorted(payloads)
    desc = bytearray(BLK)
    struct.pack_into("<I", desc, JD_MAGIC, MAGIC_DESC)
    struct.pack_into("<Q", desc, JD_SEQ, seq)
    struct.pack_into("<H", desc, JD_COUNT, len(dests))
    for i, d in enumerate(dests):
        struct.pack_into("<II", desc, JD_ENTRIES + 8 * i, d, fnv(payloads[d]))
        img[(pos + 1 + i) * BLK:(pos + 2 + i) * BLK] = payloads[d]
    struct.pack_into("<I", desc, JD_CKSUM, fnv(desc[:JD_CKSUM]))
    img[pos * BLK:(pos + 1) * BLK] = desc
    commit = bytearray(BLK)
    struct.pack_into("<I", commit, JC_MAGIC, MAGIC_COMMIT)
    struct.pack_into("<Q", commit, JC_SEQ, seq)
    txn = bytes(desc[:JD_ENTRIES + 8 * len(dests)]) + b"".join(payloads[d] for d in dests)
    struct.pack_into("<I", commit, JC_TXN, fnv(txn))
    struct.pack_into("<I", commit, JC_CKSUM, fnv(commit[:JC_CKSUM]))
    img[(pos + 1 + len(dests)) * BLK:(pos + 2 + len(dests)) * BLK] = commit
    return commit


def cases(empty, populated):
    """Each entry: (filename, comment, expect, image-builder)."""
    out = []

    def add(name, comment, expect, img):
        out.append((name, comment, expect, img))

    # --- mount-phase refusals (superblock pair + geometry) -----------------
    img = bytearray(len(empty))
    add("corrupt-not-vlfs.regions", "fully zeroed image — no VLFS magic", "not_vlfs", img)

    img = bytearray(empty)
    img[100] ^= 0x01  # sb_seq inside copy A's checksummed body
    img[BLK + 100] ^= 0x01
    add("corrupt-bad-superblock.regions", "both superblock copies torn", "bad_superblock", img)

    img = bytearray(empty)
    for slot in (0, BLK):
        struct.pack_into("<I", img, slot + SB_VERSION, 3)
        seal_sb(img, slot // BLK)
    add("corrupt-unsupported-version.regions", "version 3 superblocks, checksums resealed",
        "unsupported_version", img)

    img = bytearray(empty)
    for slot in (0, BLK):
        struct.pack_into("<Q", img, slot + SB_VOLUME_BYTES, 17 << 20)
        seal_sb(img, slot // BLK)
    add("corrupt-geometry-mismatch.regions", "volume_bytes 17 MiB vs stored volume_blocks",
        "geometry_mismatch", img)

    # --- inode table -------------------------------------------------------
    img = bytearray(empty)
    img[ITABLE * BLK + 1 * INODE_BYTES + 8] ^= 0x01  # root inode mtime byte
    add("corrupt-inode-checksum.regions", "root inode record fails its FNV-1a",
        "inode_checksum", img)

    img = bytearray(empty)
    inode_rec(img, 1)[IN_KIND] = 9
    seal_inode(img, 1)
    add("corrupt-bad-inode-kind.regions", "root inode kind 9 (resealed)", "bad_inode", img)

    # --- extents -----------------------------------------------------------
    img = bytearray(empty)
    struct.pack_into("<I", inode_rec(img, 1), IN_EXTENTS, VOL_BLOCKS)
    seal_inode(img, 1)
    add("corrupt-extent-out-of-range.regions", "root extent starts past the volume end",
        "extent_out_of_range", img)

    img = bytearray(empty)
    struct.pack_into("<I", inode_rec(img, 1), IN_SIZE, 3 * BLK + 1)
    seal_inode(img, 1)
    add("corrupt-extent-coverage.regions", "root covers 1 block but size needs 4",
        "extent_out_of_range", img)

    img = bytearray(populated)
    files = [i for i in live_inodes(img, 1)]
    rec_a, rec_b = inode_rec(img, files[0]), inode_rec(img, files[1])
    first_a = struct.unpack_from("<I", rec_a, IN_EXTENTS)[0]
    struct.pack_into("<I", rec_b, IN_EXTENTS, first_a)  # B claims A's first block
    seal_inode(img, files[1])
    add("corrupt-extent-overlap.regions", "two files share one data block",
        "extent_overlap", img)

    img = bytearray(populated)
    chained = [i for i in live_inodes(img, 1)
               if struct.unpack_from("<I", inode_rec(img, i), IN_NEXT_EXT)[0] != 0][0]
    xb = struct.unpack_from("<I", inode_rec(img, chained), IN_NEXT_EXT)[0]
    img[xb * BLK + 100] ^= 0x01
    add("corrupt-extent-chain-corrupt.regions", "extent-chain block fails its checksum",
        "extent_chain_corrupt", img)

    img = bytearray(populated)
    empty_ino = [i for i in live_inodes(img, 1)
                 if struct.unpack_from("<H", inode_rec(img, i), IN_NEXTENTS)[0] == 0
                 and struct.unpack_from("<I", inode_rec(img, i), IN_SIZE)[0] == 0][0]
    xbs = free_data_blocks(img)[:5]
    prev = 0
    for i, b in enumerate(xbs[:4]):  # 5th stays unmarked: never referenced, never visited
        xblk = bytearray(BLK)
        struct.pack_into("<I", xblk, XB_MAGIC, MAGIC_EXTENT)
        if i == 3:
            struct.pack_into("<I", xblk, XB_NEXT, xbs[4])
        if prev:
            pblk = memoryview(img)[prev * BLK:(prev + 1) * BLK]
            struct.pack_into("<I", pblk, XB_NEXT, b)
            struct.pack_into("<I", pblk, XB_CKSUM, fnv(pblk[:XB_CKSUM]))
        else:
            struct.pack_into("<I", inode_rec(img, empty_ino), IN_NEXT_EXT, b)
        struct.pack_into("<I", xblk, XB_CKSUM, fnv(xblk[:XB_CKSUM]))
        img[b * BLK:(b + 1) * BLK] = xblk
        bit(img, BBITMAP * BLK, b)
        prev = b
    seal_inode(img, empty_ino)
    add("corrupt-extent-overflow.regions", "extent chain deeper than the 4-block bound",
        "extent_overflow", img)

    # --- bitmaps -----------------------------------------------------------
    img = bytearray(empty)
    bit(img, BBITMAP * BLK, DATA_FIRST + 10)  # a free data block marked used
    add("corrupt-bitmap-leak.regions", "bbitmap marks an unreferenced data block",
        "bitmap_inconsistent", img)

    img = bytearray(empty)
    bit(img, BBITMAP * BLK, DATA_FIRST, on=False)  # root's dirent block unmarked
    add("corrupt-bitmap-unmarked.regions", "a used data block is unmarked in the bbitmap",
        "bitmap_inconsistent", img)

    img = bytearray(empty)
    bit(img, IBITMAP * BLK, 5)  # inode 5 is a free record but its bit is set
    add("corrupt-ibitmap-free.regions", "ibitmap bit set for a free inode",
        "bitmap_inconsistent", img)

    img = bytearray(empty)
    bit(img, IBITMAP * BLK, 1, on=False)  # root is live but its bit is clear
    add("corrupt-ibitmap-clear.regions", "ibitmap bit clear for a live inode",
        "bitmap_inconsistent", img)

    # --- journal cases (informational; the images must still mount) --------
    img = bytearray(empty)
    payload = bytearray(BLK)
    payload[:9] = b"journaled"
    commit = journal_txn(img, JOURNAL_FIRST, 1, {DATA_FIRST + 5: bytes(payload)})
    # Tear the COMMIT checksum in place — a valid DESC+payload with a torn tail.
    img[(JOURNAL_FIRST + 2) * BLK + JC_CKSUM] ^= 0xFF
    add("corrupt-journal-torn.regions", "committed-shape record with a torn COMMIT — mounts",
        "clean", img)

    # Home ibitmap flags inode 2 used while its record is free — a
    # bitmap_inconsistent that only the committed journal txn repairs: the
    # check must see the as-replayed overlay (fsck's in-memory replay), not
    # the raw home blocks. Verdict clean; mount then replays seq 1.
    img = bytearray(empty)
    ino, data_blk = 2, DATA_FIRST + 1
    content = b"delivered only by replay\n"
    bit(img, IBITMAP * BLK, ino)  # the planted home-state inconsistency
    ib = bytearray(img[IBITMAP * BLK:(IBITMAP + 1) * BLK])
    it = bytearray(img[ITABLE * BLK:(ITABLE + 1) * BLK])
    rec = memoryview(it)[ino * INODE_BYTES:(ino + 1) * INODE_BYTES]
    rec[IN_KIND] = 1  # file
    struct.pack_into("<H", rec, IN_NEXTENTS, 1)
    struct.pack_into("<I", rec, IN_SIZE, len(content))
    struct.pack_into("<II", rec, IN_EXTENTS, data_blk, 1)
    struct.pack_into("<Q", rec, 8, 1760000000)
    struct.pack_into("<Q", rec, 16, 1760000000)
    struct.pack_into("<I", rec, IN_CKSUM, fnv(rec[:IN_CKSUM]))
    root_blk = struct.unpack_from("<I", inode_rec(img, 1), IN_EXTENTS)[0]
    root = bytearray(img[root_blk * BLK:(root_blk + 1) * BLK])
    struct.pack_into("<I", root, DE_INODE, ino)
    struct.pack_into("<H", root, DE_NAME_LEN, len("GHOST.TXT"))
    root[DE_KIND] = 1
    root[DE_NAME:DE_NAME + 9] = b"GHOST.TXT"
    data = bytearray(BLK)
    data[:len(content)] = content
    # The bbitmap payload carries data_blk marked (home copy stays without it).
    bbp = bytearray(img[BBITMAP * BLK:(BBITMAP + 1) * BLK])
    bbp[data_blk // 8] |= 1 << (data_blk % 8)
    journal_txn(img, JOURNAL_FIRST, 1, {
        IBITMAP: bytes(ib), ITABLE: bytes(it), BBITMAP: bytes(bbp),
        root_blk: bytes(root), data_blk: bytes(data)})
    add("corrupt-journal-overlay.regions", "home bitmap_inconsistent repaired only by a "
        "committed txn — the overlay must be evaluated", "clean", img)

    # A committed txn + unrelated corruption: the check refuses
    # inode_checksum before the pending replay writes anything.
    img = bytearray(empty)
    payload = bytearray(BLK)
    payload[:11] = b"still-valid"
    journal_txn(img, JOURNAL_FIRST, 1, {DATA_FIRST + 7: bytes(payload)})
    img[ITABLE * BLK + 3 * INODE_BYTES + 8] ^= 0x01  # inode 3's checksum
    add("corrupt-journal-with-cksum.regions", "committed txn pending plus an inode "
        "checksum fault — refused before replay writes", "inode_checksum", img)

    return out


def check_cmd(mkfs, path):
    if mkfs is not None:
        return [mkfs, "--check", str(path)]
    if (ROOT / ".build/go/mkfs.vlfs").exists():
        return [str(ROOT / ".build/go/mkfs.vlfs"), "--check", str(path)]
    return ["go", "-C", str(ROOT / "tools/go/vlfs"), "run", ".", "--check", str(path)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mkfs", help="path to mkfs.vlfs binary")
    args = ap.parse_args()

    empty = load_regions(TESTDATA / "empty-16m.regions")
    populated = load_regions(TESTDATA / "populated-16m.regions")

    tmp = Path(tempfile.mkdtemp(prefix="vlfs-corpus-"))
    for name, comment, expect, img in cases(empty, populated):
        save_regions(TESTDATA / name, img, comment, expect)
        raw = tmp / (name[:-len(".regions")] + ".img")
        raw.write_bytes(bytes(img))
        out = subprocess.run(check_cmd(args.mkfs, raw), capture_output=True, text=True)
        found = out.stdout
        if expect == "clean":
            if out.returncode != 0:
                sys.exit("%s: expected clean, got rc=%d\n%s" % (name, out.returncode, found))
        elif expect not in found:
            sys.exit("%s: expected %s in --check output, got\n%s" % (name, expect, found))
        print("%-42s expect=%-22s --check rc=%d: %s"
              % (name, expect, out.returncode, " | ".join(found.splitlines()) or "clean"))
    print("corrupt corpus regenerated and verified against --check")


if __name__ == "__main__":
    main()
