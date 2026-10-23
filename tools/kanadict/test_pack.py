#!/usr/bin/env python3
#
# test_pack.py -- host test pinning the KANADICT.BIN packed format
# (M186c #3180). Run:
#   python3 -m unittest tools.kanadict.test_pack         (from repo root)
#   python3 tools/kanadict/test_pack.py                (direct)
#
# The committed image/kanadict/KANADICT.BIN is the golden artifact: this
# test regenerates it from the pinned subset.tsv and demands identical
# bytes, then decodes the format the same way user/go/ime/dict.go does
# (binary search over the sorted key index) and pins a few lookups.

import os
import struct
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

import pack  # noqa: E402

BIN_PATH = os.path.join(ROOT, "image", "kanadict", "KANADICT.BIN")


def decode_lookup(blob, reading):
    """Mirror of ime.Dict.Lookup: binary search the index, read the record."""
    assert blob[:4] == pack.MAGIC
    n = struct.unpack_from("<I", blob, 4)[0]
    key = reading.encode("utf-8")
    lo, hi = 0, n
    while lo < hi:
        mid = (lo + hi) // 2
        koff, roff, klen, rlen = struct.unpack_from("<IIHH", blob, 8 + mid * 12)
        k = blob[koff:koff + klen]
        if k == key:
            nsurf = blob[roff]
            out, p = [], roff + 1
            for _ in range(nsurf):
                sl = blob[p]
                out.append(blob[p + 1:p + 1 + sl].decode("utf-8"))
                p += 1 + sl
            return out
        if k < key:
            lo = mid + 1
        else:
            hi = mid
    return None


class TestPackFormat(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entries, _ = pack.load_subset(pack.DEFAULT_SRC)
        cls.blob, cls.nkeys = pack.pack(cls.entries)

    def test_committed_bin_matches_regen(self):
        with open(BIN_PATH, "rb") as f:
            committed = f.read()
        self.assertEqual(committed, self.blob,
                         "image/kanadict/KANADICT.BIN is stale — rerun "
                         "python3 tools/kanadict/pack.py")

    def test_header_and_bounds(self):
        self.assertEqual(self.blob[:4], pack.MAGIC)
        n = struct.unpack_from("<I", self.blob, 4)[0]
        self.assertEqual(n, self.nkeys)
        self.assertLessEqual(len(self.blob), pack.MAX_TOTAL_BYTES)
        # Every index offset lands inside the blob.
        for i in range(n):
            koff, roff, klen, rlen = struct.unpack_from("<IIHH", self.blob,
                                                       8 + i * 12)
            self.assertLessEqual(koff + klen, len(self.blob))
            self.assertLessEqual(roff + rlen, len(self.blob))

    def test_index_is_sorted(self):
        keys = []
        n = self.nkeys
        for i in range(n):
            koff, _, klen, _ = struct.unpack_from("<IIHH", self.blob, 8 + i * 12)
            keys.append(self.blob[koff:koff + klen])
        self.assertEqual(keys, sorted(keys),
                         "index must be bytewise-sorted for binary search")

    def test_known_lookup(self):
        self.assertEqual(decode_lookup(self.blob, "にほんご"), ["日本語"])
        self.assertEqual(decode_lookup(self.blob, "かんじ"), ["漢字"])

    def test_surfaces_are_rank_ordered(self):
        self.assertEqual(decode_lookup(self.blob, "やさしい"),
                         ["易しい", "優しい"])
        self.assertEqual(decode_lookup(self.blob, "はやい"),
                         ["早い", "速い"])

    def test_absent_reading_misses(self):
        self.assertIsNone(decode_lookup(self.blob, "ふがふが"))
        self.assertIsNone(decode_lookup(self.blob, "にほn"))

    def test_readings_are_kana(self):
        for reading in self.entries:
            self.assertTrue(pack.is_kana(reading),
                            "reading %r is not kana" % reading)


if __name__ == "__main__":
    unittest.main()
