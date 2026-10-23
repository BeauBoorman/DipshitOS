#!/usr/bin/env python3
#
# pack.py -- pack the curated kana->kanji subset into the guest dictionary
# (M186c #3180).
#
# Usage:  python3 tools/kanadict/pack.py [SUBSET_TSV] [OUT_BIN]
#   defaults: tools/kanadict/subset.tsv -> image/kanadict/KANADICT.BIN
#
# Source: subset.tsv (pinned, JMdict-derived, CC BY-SA 4.0 — see its
# header for provenance, the coverage note, and the licence pointer).
#
# Packed format (all integers little-endian):
#
#   +0   u32  magic   'KND1'
#   +4   u32  nkeys
#   +8   index[nkeys], 12 bytes each:
#            u32 keyOff   absolute offset of the reading's UTF-8 bytes
#            u32 recOff   absolute offset of the surface record
#            u16 keyLen   reading byte length (<=255)
#            u16 recLen   record byte length (<=255)
#   then key bytes (UTF-8 hiragana, sorted bytewise — binary search order)
#   then surface records: u8 nsurf, then nsurf x (u8 len + UTF-8 surface)
#
# Lookup is a binary search over the index (O(log n)); record surfaces
# are already frequency-ordered by the source's rank column.
#
# Bounds, named here because the card asks for them in code:
#   MAX_SURFACES_PER_KEY = 4   candidates shown per reading
#   MAX_TOTAL_BYTES      = 64 KiB   the guest dictionary's size cap
#
# Output is deterministic: same input, same bytes.

import os
import struct
import sys

MAGIC = b"KND1"
MAX_SURFACES_PER_KEY = 4
MAX_TOTAL_BYTES = 64 * 1024

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_SRC = os.path.join(HERE, "subset.tsv")
DEFAULT_OUT = os.path.join(ROOT, "image", "kanadict", "KANADICT.BIN")


def fail(msg):
    sys.stderr.write("pack: %s\n" % msg)
    sys.exit(1)


def is_kana(s):
    for ch in s:
        o = ord(ch)
        if not (0x3040 <= o <= 0x309F or ch == "ー"):
            return False
    return True


def load_subset(path):
    """Parse subset.tsv -> {reading: [(rank, surface), ...]} in file order."""
    entries = {}
    order = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                fail("%s:%d: want 'reading<TAB>surface<TAB>rank'" % (path, lineno))
            reading, surface, rank = parts[0], parts[1], parts[2]
            if not is_kana(reading):
                fail("%s:%d: reading %r is not kana" % (path, lineno, reading))
            if not surface:
                fail("%s:%d: empty surface" % (path, lineno))
            try:
                r = int(rank)
            except ValueError:
                fail("%s:%d: rank %r is not an integer" % (path, lineno, rank))
            if r < 1:
                fail("%s:%d: rank must be >= 1" % (path, lineno))
            if reading not in entries:
                entries[reading] = []
                order.append(reading)
            entries[reading].append((r, surface, lineno))
    return entries, order


def pack(entries):
    """Build the packed dictionary bytes. Deterministic."""
    keys = sorted(entries.keys(), key=lambda k: k.encode("utf-8"))
    key_bytes = [k.encode("utf-8") for k in keys]
    for kb in key_bytes:
        if len(kb) > 255:
            fail("reading %r exceeds 255 bytes" % kb.decode("utf-8", "replace"))
    recs = []
    for k in keys:
        surfs = sorted(entries[k])[:MAX_SURFACES_PER_KEY]
        rec = bytearray([len(surfs)])
        for _rank, surface, lineno in surfs:
            sb = surface.encode("utf-8")
            if len(sb) > 255:
                fail("line %d: surface %r exceeds 255 bytes" % (lineno, surface))
            rec.append(len(sb))
            rec += sb
        if len(rec) > 255:
            fail("record for %r exceeds 255 bytes" % k)
        recs.append(rec)
    # Index region size is known up front; all keys precede all records.
    base = 8 + 12 * len(keys)
    key_base = base
    rec_base = base + sum(len(kb) for kb in key_bytes)
    index = []
    key_blob = bytearray()
    rec_blob = bytearray()
    for kb, rec in zip(key_bytes, recs):
        index.append((key_base + len(key_blob),
                      rec_base + len(rec_blob),
                      len(kb), len(rec)))
        key_blob += kb
        rec_blob += rec
    out = bytearray()
    out += MAGIC
    out += struct.pack("<I", len(keys))
    for key_off, rec_off, kl, rl in index:
        out += struct.pack("<IIHH", key_off, rec_off, kl, rl)
    out += key_blob
    out += rec_blob
    if len(out) > MAX_TOTAL_BYTES:
        fail("packed dictionary is %d bytes, over the %d cap"
             % (len(out), MAX_TOTAL_BYTES))
    return bytes(out), len(keys)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    out = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT
    entries, order = load_subset(src)
    if not entries:
        fail("no entries in %s" % src)
    blob, nkeys = pack(entries)
    nsurf = sum(min(len(v), MAX_SURFACES_PER_KEY) for v in entries.values())
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(blob)
    print("pack: %d readings, %d surfaces, %d bytes -> %s"
          % (nkeys, nsurf, len(blob), out))


if __name__ == "__main__":
    main()
