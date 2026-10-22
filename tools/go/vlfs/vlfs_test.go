package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The committed golden fixtures live with the kernel-side consumer so the
// Zig tests can @embedFile them inside their package root:
var testdata = filepath.Join("..", "..", "..", "kernel", "src", "vlfs", "testdata")

var update = flag.Bool("update", false, "regenerate the .regions golden fixtures")

// goldenID/goldenTime pin the non-deterministic mkfs fields.
const (
	goldenID   uint64 = 0x5eed5eed5eed5eed
	goldenTime uint64 = 1760000000
	goldenSize        = MinVolumeBytes
)

// --- test-only image writer -------------------------------------------------
// mkfs emits an empty volume; these helpers build populated images by writing
// the same structures a journaled write would leave behind (M100d owns the
// real write path). They exist to author the populated golden and to feed
// --check its fixtures.

type imageWriter struct {
	img []byte
	g   Geometry
}

func newImage(t *testing.T) *imageWriter {
	t.Helper()
	img := make([]byte, goldenSize)
	if err := formatImage(img, goldenID, goldenTime); err != nil {
		t.Fatal(err)
	}
	g, err := geometryFor(goldenSize)
	if err != nil {
		t.Fatal(err)
	}
	return &imageWriter{img, g}
}

func (w *imageWriter) inodeRec(ino uint32) []byte {
	off := uint64(w.g.ItableFirst)*BlockLen + uint64(ino)*InodeBytes
	return w.img[off : off+InodeBytes]
}

func (w *imageWriter) sealInode(ino uint32) {
	rec := w.inodeRec(ino)
	binary.LittleEndian.PutUint32(rec[inCksum:], fnv1a(rec[:inCksum]))
}

func (w *imageWriter) allocInode(kind uint8) uint32 {
	ib := block(w.img, w.g.IbitmapFirst)
	for i := uint32(2); i < w.g.InodeCount; i++ {
		if !bitmapGet(ib, i) {
			bitmapSet(ib, i)
			rec := w.inodeRec(i)
			for j := range rec[:inCksum] {
				rec[j] = 0
			}
			rec[inKind] = kind
			binary.LittleEndian.PutUint64(rec[inMtime:], goldenTime)
			binary.LittleEndian.PutUint64(rec[inCtime:], goldenTime)
			w.sealInode(i)
			return i
		}
	}
	panic("no inodes")
}

func (w *imageWriter) allocBlocks(n uint32) uint32 {
	bb := block(w.img, w.g.BbitmapFirst)
	var first uint32
	var run uint32
	for i := w.g.DataFirst; i < w.g.VolumeBlocks; i++ {
		if !bitmapGet(bb, i) {
			if run == 0 {
				first = i
			}
			run++
			if run == n {
				for j := first; j < first+n; j++ {
					bitmapSet(bb, j)
				}
				return first
			}
			continue
		}
		run = 0
	}
	panic("no space")
}

// setExtents records a dense extent list (contiguous run of n blocks).
func (w *imageWriter) setExtents(ino, first, n uint32) {
	rec := w.inodeRec(ino)
	binary.LittleEndian.PutUint16(rec[inNextents:], 1)
	binary.LittleEndian.PutUint32(rec[inExtents:], first)
	binary.LittleEndian.PutUint32(rec[inExtents+4:], n)
	w.sealInode(ino)
}

// writeFile creates a file inode holding content and links it under parent.
func (w *imageWriter) writeFile(parent uint32, name, content string) uint32 {
	ino := w.allocInode(kindFile)
	need := uint32((uint64(len(content)) + BlockLen - 1) / BlockLen)
	if need > 0 {
		first := w.allocBlocks(need)
		for i := uint32(0); i < need; i++ {
			blk := block(w.img, first+i)
			copy(blk, content[i*BlockLen:])
		}
		w.setExtents(ino, first, need)
	}
	rec := w.inodeRec(ino)
	binary.LittleEndian.PutUint32(rec[inSize:], uint32(len(content)))
	w.sealInode(ino)
	w.addDirent(parent, name, ino, kindFile)
	return ino
}

func (w *imageWriter) mkdir(parent uint32, name string) uint32 {
	ino := w.allocInode(kindDir)
	first := w.allocBlocks(1)
	w.setExtents(ino, first, 1)
	rec := w.inodeRec(ino)
	binary.LittleEndian.PutUint32(rec[inSize:], BlockLen)
	w.sealInode(ino)
	w.addDirent(parent, name, ino, kindDir)
	return ino
}

// addDirent links name->ino in dir parent's payload, using the first
// tombstone/empty slot. Directories are grown in whole blocks; the test
// fixtures stay small enough that the root block is never exceeded.
func (w *imageWriter) addDirent(parent uint32, name string, ino uint32, kind uint8) {
	rec := w.inodeRec(parent)
	size := binary.LittleEndian.Uint32(rec[inSize:])
	first := binary.LittleEndian.Uint32(rec[inExtents:])
	for s := uint64(0); s*DirentBytes < uint64(size); s++ {
		off := uint64(first)*BlockLen + s*DirentBytes
		de := w.img[off : off+DirentBytes]
		if binary.LittleEndian.Uint32(de[deInode:]) != 0 {
			continue
		}
		for i := range de {
			de[i] = 0
		}
		binary.LittleEndian.PutUint32(de[deInode:], ino)
		binary.LittleEndian.PutUint16(de[deNameLen:], uint16(len(name)))
		de[deKind] = kind
		copy(de[deName:], name)
		return
	}
	panic("directory full")
}

// makeSparse places count single-block extents (non-contiguous allocations)
// plus an extent block, to exercise the inode extent-chain path.
func (w *imageWriter) writeChainedFile(parent uint32, name string, blocks []string) uint32 {
	ino := w.allocInode(kindFile)
	var extents [][2]uint32
	for _, content := range blocks {
		b := w.allocBlocks(1)
		copy(block(w.img, b), content)
		extents = append(extents, [2]uint32{b, 1})
	}
	rec := w.inodeRec(ino)
	n := InlineExtents
	if len(extents) < n {
		n = len(extents)
	}
	binary.LittleEndian.PutUint16(rec[inNextents:], uint16(n))
	for i := 0; i < n; i++ {
		binary.LittleEndian.PutUint32(rec[inExtents+i*8:], extents[i][0])
		binary.LittleEndian.PutUint32(rec[inExtents+i*8+4:], extents[i][1])
	}
	if len(extents) > InlineExtents {
		chain := w.allocBlocks(1)
		blk := block(w.img, chain)
		binary.LittleEndian.PutUint32(blk[xbMagic:], MagicExtent)
		binary.LittleEndian.PutUint16(blk[xbCount:], uint16(len(extents)-InlineExtents))
		for i := InlineExtents; i < len(extents); i++ {
			binary.LittleEndian.PutUint32(blk[xbExtents+(i-InlineExtents)*8:], extents[i][0])
			binary.LittleEndian.PutUint32(blk[xbExtents+(i-InlineExtents)*8+4:], extents[i][1])
		}
		binary.LittleEndian.PutUint32(blk[xbCksum:], fnv1a(blk[:xbCksum]))
		binary.LittleEndian.PutUint32(rec[inNextExt:], chain)
	}
	binary.LittleEndian.PutUint32(rec[inSize:], uint32(len(blocks))*BlockLen)
	w.sealInode(ino)
	w.addDirent(parent, name, ino, kindFile)
	return ino
}

// tombstone removes a dirent (inode 0 = reusable slot) and frees the
// target inode and its extent blocks, the way a committed delete leaves
// the volume.
func (w *imageWriter) tombstone(parent uint32, name string) {
	rec := w.inodeRec(parent)
	size := binary.LittleEndian.Uint32(rec[inSize:])
	first := binary.LittleEndian.Uint32(rec[inExtents:])
	for s := uint64(0); s*DirentBytes < uint64(size); s++ {
		off := uint64(first)*BlockLen + s*DirentBytes
		de := w.img[off : off+DirentBytes]
		target := binary.LittleEndian.Uint32(de[deInode:])
		nl := binary.LittleEndian.Uint16(de[deNameLen:])
		if target != 0 && string(de[deName:deName+nl]) == name {
			binary.LittleEndian.PutUint32(de[deInode:], 0)
			w.freeInode(target)
			return
		}
	}
	panic("no such dirent")
}

// freeInode clears an inode's ibitmap bit, its extent blocks' bbitmap bits,
// and resets the record to a checksummed free slot.
func (w *imageWriter) freeInode(ino uint32) {
	rec := w.inodeRec(ino)
	bb := block(w.img, w.g.BbitmapFirst)
	next := binary.LittleEndian.Uint16(rec[inNextents:])
	for e := 0; e < int(next) && e < InlineExtents; e++ {
		first := binary.LittleEndian.Uint32(rec[inExtents+e*8:])
		count := binary.LittleEndian.Uint32(rec[inExtents+e*8+4:])
		for b := first; b < first+count; b++ {
			bb[b/8] &^= 1 << (b % 8)
		}
	}
	ib := block(w.img, w.g.IbitmapFirst)
	ib[ino/8] &^= 1 << (ino % 8)
	for i := range rec[:inCksum] {
		rec[i] = 0
	}
	w.sealInode(ino)
}

// populatedImage builds the golden populated fixture:
//
//	/                  root (inode 1)
//	├── APPLE.TXT      file, "apple\n" repeated across two blocks
//	├── CHAINED.BIN    file, 10 single-block extents (8 inline + 1 extent block)
//	├── DOCS/          dir
//	│   ├── NESTED.TXT file
//	│   └── DEEP/      dir
//	│       └── LEAF.TXT file
//	├── EMPTY.BIN      zero-byte file
//	└── ZEBRA.TXT      file (a tombstone GONE.TXT sits between live entries)
func populatedImage(t *testing.T) []byte {
	w := newImage(t)
	var big bytes.Buffer
	for big.Len() < BlockLen+17 {
		big.WriteString("apple\n")
	}
	w.writeFile(RootInode, "APPLE.TXT", big.String()[:BlockLen+17])
	w.writeFile(RootInode, "GONE.TXT", "deleted\n")
	w.tombstone(RootInode, "GONE.TXT")
	var blocks []string
	for i := 0; i < 10; i++ {
		blocks = append(blocks, "chain-block-"+string(rune('0'+i)))
	}
	w.writeChainedFile(RootInode, "CHAINED.BIN", blocks)
	docs := w.mkdir(RootInode, "DOCS")
	w.writeFile(docs, "NESTED.TXT", "nested file contents\n")
	deep := w.mkdir(docs, "DEEP")
	w.writeFile(deep, "LEAF.TXT", "leaf\n")
	w.writeFile(RootInode, "EMPTY.BIN", "")
	w.writeFile(RootInode, "ZEBRA.TXT", "zebra\n")
	return w.img
}

func writeGolden(t *testing.T, name string, img []byte) {
	t.Helper()
	path := filepath.Join(testdata, name)
	if err := os.MkdirAll(testdata, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(regionsEncode(img)), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %s", path)
}

func readGolden(t *testing.T, name string) []byte {
	t.Helper()
	text, err := os.ReadFile(filepath.Join(testdata, name))
	if err != nil {
		t.Fatal(err)
	}
	img, err := regionsDecode(string(text))
	if err != nil {
		t.Fatal(err)
	}
	return img
}

// --- tests ------------------------------------------------------------------

// TestGoldenEmpty pins mkfs output byte-for-byte against the committed
// golden: every non-zero region must match and everything else must be
// zero. Regenerate with `go test -run Golden -update`.
func TestGoldenEmpty(t *testing.T) {
	img := make([]byte, goldenSize)
	if err := formatImage(img, goldenID, goldenTime); err != nil {
		t.Fatal(err)
	}
	if *update {
		writeGolden(t, "empty-16m.regions", img)
	}
	text, err := os.ReadFile(filepath.Join(testdata, "empty-16m.regions"))
	if err != nil {
		t.Skip("golden fixture not committed; run with -update", err)
	}
	if err := regionsVerify(img, string(text)); err != nil {
		t.Fatal(err)
	}
}

// TestGoldenPopulated pins the populated fixture byte-for-byte and checks
// that --check finds it clean.
func TestGoldenPopulated(t *testing.T) {
	img := populatedImage(t)
	if *update {
		writeGolden(t, "populated-16m.regions", img)
	}
	text, err := os.ReadFile(filepath.Join(testdata, "populated-16m.regions"))
	if err != nil {
		t.Skip("golden fixture not committed; run with -update", err)
	}
	if err := regionsVerify(img, string(text)); err != nil {
		t.Fatal(err)
	}
	for _, f := range checkImage(img, nil) {
		if !f.info {
			t.Fatalf("populated fixture fails check: %v", f)
		}
	}
}

// TestCheckGoldenClean asserts the committed empty image passes --check.
func TestCheckGoldenClean(t *testing.T) {
	img := readGolden(t, "empty-16m.regions")
	for _, f := range checkImage(img, nil) {
		t.Fatalf("empty golden fails check: %v", f)
	}
}

// TestCheckMultiBlockBbitmap: a volume over 128 MiB has a multi-block
// bbitmap. The scan must read every map block — it once read only the
// first and panicked index-out-of-range past bit 32767.
func TestCheckMultiBlockBbitmap(t *testing.T) {
	const size = 256 << 20 // 256 MiB -> 2 bbitmap blocks
	img := make([]byte, size)
	if err := formatImage(img, goldenID, goldenTime); err != nil {
		t.Fatal(err)
	}
	g, err := geometryFor(size)
	if err != nil {
		t.Fatal(err)
	}
	if g.BbitmapBlocks != 2 {
		t.Fatalf("256 MiB bbitmap %d blocks, want 2", g.BbitmapBlocks)
	}
	for _, f := range checkImage(img, nil) {
		if !f.info {
			t.Fatalf("256 MiB image fails check: %v", f)
		}
	}
	// The 1 GiB ceiling spans all 8 map blocks; assert the geometry
	// arithmetically rather than formatting a gigabyte.
	g, err = geometryFor(MaxVolumeBytes)
	if err != nil {
		t.Fatal(err)
	}
	if g.BbitmapBlocks != 8 {
		t.Fatalf("1 GiB bbitmap %d blocks, want 8", g.BbitmapBlocks)
	}
}

// TestGeometry pins the ADR D3 region arithmetic for the floor volume.
func TestGeometry(t *testing.T) {
	g, err := geometryFor(MinVolumeBytes)
	if err != nil {
		t.Fatal(err)
	}
	want := Geometry{
		VolumeBytes:   MinVolumeBytes,
		VolumeBlocks:  4096,
		JournalFirst:  2,
		JournalBlocks: 512,
		IbitmapFirst:  514,
		BbitmapFirst:  515,
		BbitmapBlocks: 1,
		ItableFirst:   516,
		ItableBlocks:  8,
		DataFirst:     524,
		DataBlocks:    3572,
		InodeCount:    256,
	}
	if g != want {
		t.Fatalf("geometry %+v, want %+v", g, want)
	}
	if _, err := geometryFor(MinVolumeBytes - BlockLen); !errIs(err, "volume_too_small") {
		t.Fatalf("floor-1: %v", err)
	}
	if _, err := geometryFor(MaxVolumeBytes + BlockLen); !errIs(err, "volume_too_large") {
		t.Fatalf("ceiling+1: %v", err)
	}
	if _, err := geometryFor(MinVolumeBytes + SectorLen); !errIs(err, "geometry_mismatch") {
		t.Fatalf("unaligned: %v", err)
	}
	// 1 GiB ceiling geometry: J = 2048, inodes = 16384.
	g, err = geometryFor(MaxVolumeBytes)
	if err != nil {
		t.Fatal(err)
	}
	if g.JournalBlocks != 2048 || g.InodeCount != 16384 || g.DataFirst+g.DataBlocks != g.VolumeBlocks {
		t.Fatalf("ceiling geometry %+v", g)
	}
}

// TestGeometryCeilItable: an odd-MiB volume has an inode_count that is not
// a multiple of 32, so the itable must round up (ADR 0050 D3). Truncating
// once wrote the tail inode records into the root directory's data block.
func TestGeometryCeilItable(t *testing.T) {
	const size = 17 << 20
	img := make([]byte, size)
	if err := formatImage(img, goldenID, goldenTime); err != nil {
		t.Fatal(err)
	}
	g, err := geometryFor(size)
	if err != nil {
		t.Fatal(err)
	}
	if g.InodeCount != 272 || g.InodeCount%InodesPerBlock == 0 {
		t.Fatalf("inode_count %d: want a non-multiple of %d", g.InodeCount, InodesPerBlock)
	}
	if g.ItableBlocks != (g.InodeCount+InodesPerBlock-1)/InodesPerBlock {
		t.Fatalf("itable_blocks %d != ceil(inode_count/32)", g.ItableBlocks)
	}
	// Block data_first is the root directory's block: mkfs leaves it zero.
	if !isZero(block(img, g.DataFirst)) {
		t.Fatal("data_first block nonzero — itable aliases the data region")
	}
	// The last inode's slot must land inside the itable.
	if last := g.InodeCount - 1; g.ItableFirst+last/InodesPerBlock >= g.DataFirst {
		t.Fatalf("inode %d maps to block %d >= data_first %d", last,
			g.ItableFirst+last/InodesPerBlock, g.DataFirst)
	}
	for _, f := range checkImage(img, nil) {
		if !f.info {
			t.Fatalf("17 MiB image fails check: %v", f)
		}
	}
}

// TestCheckDetects runs the corruption battery: each mutation must surface
// the named refusal the ADR assigns it.
func TestCheckDetects(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(img []byte)
		code   string
		info   bool
	}{
		{"zeroed image", func(img []byte) {
			for i := range img {
				img[i] = 0
			}
		}, "not_vlfs", false},
		{"bad magic", func(img []byte) {
			img[0] ^= 0xff
			img[BlockLen] ^= 0xff
		}, "not_vlfs", false},
		{"corrupt both superblocks", func(img []byte) {
			img[100] ^= 0x01 // sb_seq inside A
			img[BlockLen+100] ^= 0x01
		}, "bad_superblock", false},
		{"corrupt newest copy reports but B still mounts", func(img []byte) {
			img[100] ^= 0x01 // tear A (seq 2); B (seq 1) survives
		}, "bad_superblock", false},
		{"bad version", func(img []byte) {
			for _, off := range []uint64{0, BlockLen} {
				binary.LittleEndian.PutUint32(img[off+sbVersion:], 3)
				// repair cksum so version is the only complaint
				b := img[off:]
				binary.LittleEndian.PutUint32(b[sbCksum:], fnv1a(b[:sbCksum]))
			}
		}, "unsupported_version", false},
		{"volume_bytes too large", func(img []byte) {
			for _, off := range []uint64{0, BlockLen} {
				binary.LittleEndian.PutUint64(img[off+sbVolumeBytes:], MinVolumeBytes+BlockLen)
				b := img[off:]
				binary.LittleEndian.PutUint32(b[sbCksum:], fnv1a(b[:sbCksum]))
			}
		}, "geometry_mismatch", false},
		{"inode cksum", func(img []byte) {
			g, _ := geometryFor(goldenSize)
			rec := img[uint64(g.ItableFirst)*BlockLen+RootInode*InodeBytes:]
			rec[inMtime] ^= 0x01
		}, "inode_checksum", false},
		{"extent out of range", func(img []byte) {
			g, _ := geometryFor(goldenSize)
			rec := img[uint64(g.ItableFirst)*BlockLen+RootInode*InodeBytes:]
			binary.LittleEndian.PutUint32(rec[inExtents:], g.VolumeBlocks)
			binary.LittleEndian.PutUint32(rec[inCksum:], fnv1a(rec[:inCksum]))
		}, "extent_out_of_range", false},
		{"unmarked data block leak", func(img []byte) {
			g, _ := geometryFor(goldenSize)
			bb := block(img, g.BbitmapFirst)
			bitmapSet(bb, g.DataFirst+10)
		}, "bitmap_inconsistent", false},
		{"used data block unmarked", func(img []byte) {
			g, _ := geometryFor(goldenSize)
			bb := block(img, g.BbitmapFirst)
			bb[g.DataFirst/8] &^= 1 << (g.DataFirst % 8) // root's dirent block
		}, "bitmap_inconsistent", false},
		{"bad inode kind", func(img []byte) {
			g, _ := geometryFor(goldenSize)
			rec := img[uint64(g.ItableFirst)*BlockLen+RootInode*InodeBytes:]
			rec[inKind] = 7
			binary.LittleEndian.PutUint32(rec[inCksum:], fnv1a(rec[:inCksum]))
		}, "bad_inode", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newImage(t)
			tc.mutate(w.img)
			var got []finding
			for _, f := range checkImage(w.img, nil) {
				if !f.info {
					got = append(got, f)
				}
			}
			if tc.code == "" {
				if len(got) != 0 {
					t.Fatalf("expected clean, got %v", got)
				}
				return
			}
			for _, f := range got {
				if f.code == tc.code {
					return
				}
			}
			t.Fatalf("expected %s in %v", tc.code, got)
		})
	}
}

// journalAppend encodes one committed transaction (DESC + payloads +
// COMMIT) into the journal region at block pos — the bytes the kernel's
// write path emits, hand-built so tests can place committed-but-
// uncheckpointed state.
func journalAppend(img []byte, pos, seq uint64, payloads map[uint32][]byte) {
	dests := make([]uint32, 0, len(payloads))
	for d := range payloads {
		dests = append(dests, d)
	}
	sort.Slice(dests, func(a, b int) bool { return dests[a] < dests[b] })
	desc := block(img, uint32(pos))
	for i := range desc {
		desc[i] = 0
	}
	binary.LittleEndian.PutUint32(desc[jdMagic:], MagicDesc)
	binary.LittleEndian.PutUint64(desc[jdSeq:], seq)
	binary.LittleEndian.PutUint16(desc[jdCount:], uint16(len(dests)))
	for i, d := range dests {
		binary.LittleEndian.PutUint32(desc[jdEntries+i*8:], d)
		binary.LittleEndian.PutUint32(desc[jdEntries+i*8+4:], fnv1a(payloads[d]))
		copy(block(img, uint32(pos)+uint32(1+i)), payloads[d])
	}
	binary.LittleEndian.PutUint32(desc[jdCksum:], fnv1a(desc[:jdCksum]))
	commit := block(img, uint32(pos)+uint32(1+len(dests)))
	for i := range commit {
		commit[i] = 0
	}
	var txn []byte
	txn = append(txn, desc[:jdEntries+8*len(dests)]...)
	for _, d := range dests {
		txn = append(txn, payloads[d]...)
	}
	binary.LittleEndian.PutUint32(commit[jcMagic:], MagicCommit)
	binary.LittleEndian.PutUint64(commit[jcSeq:], seq)
	binary.LittleEndian.PutUint32(commit[jcTxn:], fnv1a(txn))
	binary.LittleEndian.PutUint32(commit[jcCksum:], fnv1a(commit[:jcCksum]))
}

// TestCheckDetectsStructural covers the refusal names that need a
// populated writer-built image: overlap, chains, orphans, dirents, depth.
func TestCheckDetectsStructural(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(w *imageWriter)
		code   string
	}{
		{"extent overlap — two files share a block", func(w *imageWriter) {
			a := w.writeFile(RootInode, "A.TXT", "a")
			b := w.writeFile(RootInode, "B.TXT", "b")
			recA := w.inodeRec(a)
			first := binary.LittleEndian.Uint32(recA[inExtents:])
			recB := w.inodeRec(b)
			binary.LittleEndian.PutUint32(recB[inExtents:], first) // B now claims A's block
			w.sealInode(b)
		}, "extent_overlap"},
		{"extent chain corrupt — bad VXEB checksum", func(w *imageWriter) {
			blocks := make([]string, 10)
			for i := range blocks {
				blocks[i] = "x"
			}
			ino := w.writeChainedFile(RootInode, "CH.BIN", blocks)
			chain := binary.LittleEndian.Uint32(w.inodeRec(ino)[inNextExt:])
			block(w.img, chain)[100] ^= 0x01
		}, "extent_chain_corrupt"},
		{"extent overflow — chain deeper than 4", func(w *imageWriter) {
			ino := w.writeFile(RootInode, "DEEP.BIN", "d")
			var prev uint32
			for i := 0; i < 5; i++ {
				xb := w.allocBlocks(1)
				blk := block(w.img, xb)
				binary.LittleEndian.PutUint32(blk[xbMagic:], MagicExtent)
				if prev != 0 {
					pb := block(w.img, prev)
					binary.LittleEndian.PutUint32(pb[xbNext:], xb)
					binary.LittleEndian.PutUint32(pb[xbCksum:], fnv1a(pb[:xbCksum]))
				} else {
					binary.LittleEndian.PutUint32(w.inodeRec(ino)[inNextExt:], xb)
				}
				binary.LittleEndian.PutUint32(blk[xbCksum:], fnv1a(blk[:xbCksum]))
				prev = xb
			}
			w.sealInode(ino)
		}, "extent_overflow"},
		{"inode orphan — allocated, unreachable", func(w *imageWriter) {
			w.writeFile(RootInode, "KEPT.TXT", "k")
			ino := w.allocInode(kindFile) // no dirent names it
			w.setExtents(ino, w.allocBlocks(1), 1)
		}, "inode_orphan"},
		{"dirent bad — kind byte out of range", func(w *imageWriter) {
			w.writeFile(RootInode, "F.TXT", "f")
			rec := w.inodeRec(RootInode)
			first := binary.LittleEndian.Uint32(rec[inExtents:])
			de := block(w.img, first) // slot 0 = F.TXT
			de[deKind] = 9
		}, "dirent_bad"},
		{"dirent bad — points at a free inode", func(w *imageWriter) {
			ino := w.writeFile(RootInode, "F.TXT", "f")
			rec := w.inodeRec(RootInode)
			first := binary.LittleEndian.Uint32(rec[inExtents:])
			de := block(w.img, first)
			binary.LittleEndian.PutUint32(de[deInode:], ino+1) // next slot is free
		}, "dirent_bad"},
		{"depth overflow — nine nested directories", func(w *imageWriter) {
			var dir uint32 = RootInode
			for i := 0; i < 9; i++ {
				dir = w.mkdir(dir, fmt.Sprintf("D%d", i))
			}
		}, "depth_overflow"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newImage(t)
			tc.mutate(w)
			var got []string
			for _, f := range checkImage(w.img, nil) {
				if !f.info {
					got = append(got, f.code)
				}
			}
			for _, code := range got {
				if code == tc.code {
					return
				}
			}
			t.Fatalf("expected %s in %v", tc.code, got)
		})
	}
}

// TestCheckJournal builds a committed-but-uncheckpointed transaction and
// a torn tail, asserting the informational findings land.
func TestCheckJournal(t *testing.T) {
	w := newImage(t)
	g := w.g
	// One valid transaction: payload "hello" at dest data_first+5.
	payload := make([]byte, BlockLen)
	copy(payload, "hello vlfs")
	dest := g.DataFirst + 5
	desc := block(w.img, g.JournalFirst)
	binary.LittleEndian.PutUint32(desc[jdMagic:], MagicDesc)
	binary.LittleEndian.PutUint64(desc[jdSeq:], 1)
	binary.LittleEndian.PutUint16(desc[jdCount:], 1)
	binary.LittleEndian.PutUint32(desc[jdEntries:], dest)
	binary.LittleEndian.PutUint32(desc[jdEntries+4:], fnv1a(payload))
	binary.LittleEndian.PutUint32(desc[jdCksum:], fnv1a(desc[:jdCksum]))
	copy(block(w.img, g.JournalFirst+1), payload)
	commit := block(w.img, g.JournalFirst+2)
	binary.LittleEndian.PutUint32(commit[jcMagic:], MagicCommit)
	binary.LittleEndian.PutUint64(commit[jcSeq:], 1)
	var txn []byte
	txn = append(txn, desc[:jdEntries+8]...)
	txn = append(txn, payload...)
	binary.LittleEndian.PutUint32(commit[jcTxn:], fnv1a(txn))
	binary.LittleEndian.PutUint32(commit[jcCksum:], fnv1a(commit[:jcCksum]))

	found := map[string]bool{}
	for _, f := range checkImage(w.img, nil) {
		found[f.code] = true
		if f.code == "journal_unreplayed" && !f.info {
			t.Fatal("journal_unreplayed must be informational")
		}
	}
	if !found["journal_unreplayed"] {
		t.Fatal("expected journal_unreplayed")
	}

	// Torn tail: corrupt the commit record -> torn, and the overlay's
	// replayed copy must not be trusted (check still inspects cleanly).
	binary.LittleEndian.PutUint32(commit[jcTxn:], 0xdeadbeef)
	found = map[string]bool{}
	for _, f := range checkImage(w.img, nil) {
		found[f.code] = true
	}
	if !found["journal_torn"] {
		t.Fatal("expected journal_torn")
	}
	if found["journal_unreplayed"] {
		t.Fatal("torn txn must not count as unreplayed")
	}
}

// TestCheckReplayOverlay is the D5 as-replayed contract: check evaluates
// the state the journal yields after replay, not the raw home blocks. An
// image whose home state is inconsistent (a dirent naming a free inode)
// but whose committed transaction installs the matching inode, bitmaps,
// dirent, and data must check clean apart from the informational
// journal_unreplayed — and the same image without the covering txn must
// fail dirent_bad, proving the overlay is what was evaluated.
func TestCheckReplayOverlay(t *testing.T) {
	w := newImage(t)
	g := w.g
	const ino = 2
	dataBlk := g.DataFirst + 1 // root's dirent block is DataFirst

	// The committed transaction's payloads: ibitmap with ino's bit, the
	// itable block holding inode 2 as a live file, bbitmap marking dataBlk,
	// the root dirent block naming it, and the file's data block.
	ibitmap := append([]byte(nil), block(w.img, g.IbitmapFirst)...)
	bitmapSet(ibitmap, ino)
	itable := append([]byte(nil), block(w.img, g.ItableFirst)...)
	rec := itable[ino*InodeBytes:]
	rec[inKind] = kindFile
	binary.LittleEndian.PutUint16(rec[inNextents:], 1)
	content := "delivered only by replay\n"
	binary.LittleEndian.PutUint32(rec[inSize:], uint32(len(content)))
	binary.LittleEndian.PutUint32(rec[inExtents:], dataBlk)
	binary.LittleEndian.PutUint32(rec[inExtents+4:], 1)
	binary.LittleEndian.PutUint64(rec[inMtime:], goldenTime)
	binary.LittleEndian.PutUint64(rec[inCtime:], goldenTime)
	binary.LittleEndian.PutUint32(rec[inCksum:], fnv1a(rec[:inCksum]))
	bbitmap := append([]byte(nil), block(w.img, g.BbitmapFirst)...)
	bitmapSet(bbitmap, dataBlk)
	rootBlk := binary.LittleEndian.Uint32(w.inodeRec(RootInode)[inExtents:])
	root := append([]byte(nil), block(w.img, rootBlk)...)
	de := root[:DirentBytes]
	binary.LittleEndian.PutUint32(de[deInode:], ino)
	binary.LittleEndian.PutUint16(de[deNameLen:], uint16(len("GHOST.TXT")))
	de[deKind] = kindFile
	copy(de[deName:], "GHOST.TXT")
	data := make([]byte, BlockLen)
	copy(data, content)

	// First, the same image minus the covering transaction: the home dirent
	// names a free inode and must fail.
	copy(block(w.img, rootBlk), root)
	hard := map[string]bool{}
	for _, f := range checkImage(w.img, nil) {
		if !f.info {
			hard[f.code] = true
		}
	}
	if !hard["dirent_bad"] {
		t.Fatalf("as-written state should fail dirent_bad, got %v", hard)
	}

	// Now the committed txn lands in the journal: check evaluates the
	// as-replayed overlay, which is a consistent populated volume.
	journalAppend(w.img, uint64(g.JournalFirst), 1, map[uint32][]byte{
		g.IbitmapFirst: ibitmap,
		g.ItableFirst:  itable,
		g.BbitmapFirst: bbitmap,
		rootBlk:        root,
		dataBlk:        data,
	})
	hard = map[string]bool{}
	var sawUnreplayed bool
	for _, f := range checkImage(w.img, nil) {
		if !f.info {
			hard[f.code] = true
		}
		if f.code == "journal_unreplayed" {
			sawUnreplayed = true
		}
	}
	if len(hard) != 0 {
		t.Fatalf("as-replayed state must check clean, got %v", hard)
	}
	if !sawUnreplayed {
		t.Fatal("expected informational journal_unreplayed")
	}
}

// --- sealed (v2, ADR 0061) ---------------------------------------------------

func testHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestAEADChaCha20Block pins the RFC 8439 §2.3.2 block-function vector —
// the same vector kernel/src/aead.zig and user/src/lib/crypto carry.
func TestAEADChaCha20Block(t *testing.T) {
	var key [aeadKeyLen]byte
	for i := range key {
		key[i] = byte(i)
	}
	nonce := [aeadNonceLen]byte{0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00}
	var out [chachaBlock]byte
	chacha20Block(&key, 1, &nonce, &out)
	want := testHex(t,
		"10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e"+
			"d2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e")
	if !bytes.Equal(out[:], want) {
		t.Fatal("ChaCha20 block vector mismatch")
	}
}

// TestAEADPoly1305 pins the RFC 8439 §2.5.2 Poly1305 known-answer.
func TestAEADPoly1305(t *testing.T) {
	keyb := testHex(t, "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
	p := poly1305Init((*[32]byte)(keyb))
	p.update([]byte("Cryptographic Forum Research Group"))
	var out [16]byte
	p.final(&out)
	want := testHex(t, "a8061dc1305136c6c22b8baf0c0127a9")
	if !bytes.Equal(out[:], want) {
		t.Fatal("Poly1305 KAT mismatch")
	}
}

// TestAEADRFC8439 pins the §2.8.2 AEAD vector plus tamper refusal.
func TestAEADRFC8439(t *testing.T) {
	key := (*[aeadKeyLen]byte)(testHex(t,
		"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
	nonce := (*[aeadNonceLen]byte)(testHex(t, "070000004041424344454647"))
	aad := testHex(t, "50515253c0c1c2c3c4c5c6c7")
	plaintext := []byte("Ladies and Gentlemen of the class of '99: If I could " +
		"offer you only one tip for the future, sunscreen would be it.")
	wantCT := testHex(t,
		"d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"+
			"3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36"+
			"92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc"+
			"3ff4def08e4b7a9de576d26586cec64b6116")
	wantTag := testHex(t, "1ae10b594f09e26a7e902ecbd0600691")

	ct := make([]byte, len(plaintext))
	var tag [aeadTagLen]byte
	aeadSeal(ct, &tag, plaintext, aad, nonce, key)
	if !bytes.Equal(ct, wantCT) || !bytes.Equal(tag[:], wantTag) {
		t.Fatal("AEAD seal vector mismatch")
	}
	back := make([]byte, len(plaintext))
	if !aeadOpen(back, ct, &tag, aad, nonce, key) || !bytes.Equal(back, plaintext) {
		t.Fatal("AEAD open round trip failed")
	}

	// Tampered tag, ciphertext, or AAD is refused.
	badTag := tag
	badTag[0] ^= 1
	if aeadOpen(back, ct, &badTag, aad, nonce, key) {
		t.Fatal("tampered tag accepted")
	}
	badCT := append([]byte(nil), ct...)
	badCT[3] ^= 0x80
	if aeadOpen(back, badCT, &tag, aad, nonce, key) {
		t.Fatal("tampered ciphertext accepted")
	}
	badAAD := append([]byte(nil), aad...)
	badAAD[0] ^= 0x01
	if aeadOpen(back, ct, &tag, badAAD, nonce, key) {
		t.Fatal("tampered AAD accepted")
	}
}

// TestPBKDF2Stdlib pins the published PBKDF2-HMAC-SHA256 vector against
// the stdlib provider — the drift guard for crypto/pbkdf2.
func TestPBKDF2Stdlib(t *testing.T) {
	dk, err := pbkdf2Key([]byte("password"), []byte("salt"), 1)
	if err != nil {
		t.Fatal(err)
	}
	want := testHex(t, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
	if !bytes.Equal(dk, want) {
		t.Fatal("PBKDF2-HMAC-SHA256 c=1 vector mismatch")
	}
	dk, err = pbkdf2Key([]byte("password"), []byte("salt"), 4096)
	if err != nil {
		t.Fatal(err)
	}
	want = testHex(t, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
	if !bytes.Equal(dk, want) {
		t.Fatal("PBKDF2-HMAC-SHA256 c=4096 vector mismatch")
	}
}

// sealedImage builds a v2 volume with fixed seal material (iters 1 keeps
// the test fast; the format pins the stored count, not a minimum).
func sealedImage(t *testing.T, pass string) ([]byte, Geometry) {
	t.Helper()
	img := make([]byte, goldenSize)
	var p sealParams
	for i := range p.dek {
		p.dek[i] = byte(i)
	}
	for i := range p.salt {
		p.salt[i] = 0xa0 + byte(i)
	}
	for i := range p.wrapNonce {
		p.wrapNonce[i] = 0x50 + byte(i)
	}
	p.iters = 1
	if err := formatSealedImage(img, goldenID, goldenTime, []byte(pass), p); err != nil {
		t.Fatal(err)
	}
	g, err := geometryFor(goldenSize)
	if err != nil {
		t.Fatal(err)
	}
	g, err = sealedGeometry(g)
	if err != nil {
		t.Fatal(err)
	}
	return img, g
}

func hardFindings(findings []finding) []string {
	var out []string
	for _, f := range findings {
		if !f.info {
			out = append(out, f.String())
		}
	}
	return out
}

// sealOpenBlock AEAD-opens a sealed test block against its tag-home
// entry — the checker path's inverse.
func sealOpenBlock(t *testing.T, img []byte, g Geometry, volID uint64,
	dek *[KeyBytes]byte, b uint32) []byte {
	t.Helper()
	out := make([]byte, BlockLen)
	e := tagEntry(img, g, b)
	if !aeadOpen(out, block(img, b), (*[aeadTagLen]byte)(e[aeadNonceLen:]),
		blockAAD(volID, b), (*[aeadNonceLen]byte)(e[:aeadNonceLen]),
		(*[aeadKeyLen]byte)(dek)) {
		t.Fatalf("open block %d", b)
	}
	return out
}

// sealSlotWrite replicates the kernel's journal-slot write on a test
// image: plaintext sealed in place at the slot's AAD under a fresh
// nonce, the {nonce, tag} pair written eagerly to the slot's tag home
// (seal.zig's journal-record path).
func sealSlotWrite(t *testing.T, img []byte, g Geometry, volID uint64,
	dek *[KeyBytes]byte, slot uint32, pt []byte) {
	t.Helper()
	var nonce [aeadNonceLen]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		t.Fatal(err)
	}
	var tag [aeadTagLen]byte
	aeadSeal(block(img, slot), &tag, pt, blockAAD(volID, slot),
		&nonce, (*[aeadKeyLen]byte)(dek))
	e := tagEntry(img, g, slot)
	copy(e[:aeadNonceLen], nonce[:])
	copy(e[aeadNonceLen:], tag[:])
}

// TestSealedFormat checks the v2 on-disk structure ADR 0061 pins.
func TestSealedFormat(t *testing.T) {
	img, g := sealedImage(t, "correct horse battery staple")

	// Tag-region fixpoint: 28 blocks ending at the 16-MiB volume's end.
	if g.TagBlocks != 28 || g.TagFirst != 4068 || g.TagFirst+g.TagBlocks != g.VolumeBlocks {
		t.Fatalf("tag geometry first=%d blocks=%d", g.TagFirst, g.TagBlocks)
	}
	if g.DataFirst+g.DataBlocks != g.TagFirst {
		t.Fatalf("data region %d+%d does not end at tag_first %d",
			g.DataFirst, g.DataBlocks, g.TagFirst)
	}

	for _, slot := range []uint32{0, 1} {
		sb := block(img, slot)[:SectorLen]
		if v := binary.LittleEndian.Uint32(sb[sbVersion:]); v != Version2 {
			t.Fatalf("slot %d version %d, want 2", slot, v)
		}
		if m := binary.LittleEndian.Uint32(sb[sbSealMagic:]); m != MagicSeal {
			t.Fatalf("slot %d seal_magic %08x", slot, m)
		}
		if id := binary.LittleEndian.Uint32(sb[sbKdfID:]); id != KdfPbkdf2Sha256 {
			t.Fatalf("slot %d kdf_id %d", slot, id)
		}
		if n := binary.LittleEndian.Uint32(sb[sbKdfIters:]); n != 1 {
			t.Fatalf("slot %d kdf_iters %d", slot, n)
		}
		if tf := binary.LittleEndian.Uint32(sb[sbTagFirst:]); tf != g.TagFirst {
			t.Fatalf("slot %d tag_first %d != %d", slot, tf, g.TagFirst)
		}
		if !isZero(sb[sbSealZero:sbCksum]) {
			t.Fatalf("slot %d seal reserved bytes nonzero", slot)
		}
	}

	// The sealed span must be ciphertext: the fresh image's journal
	// plaintext is all zeros, but the stored block must not be.
	if isZero(block(img, g.JournalFirst)) {
		t.Fatal("sealed journal block is plaintext-zero")
	}
	// Tag-region tails are the pinned 8 zero bytes.
	for tb := g.TagFirst; tb < g.VolumeBlocks; tb++ {
		if !isZero(block(img, tb)[TagEntriesPerBlock*TagEntryBytes:]) {
			t.Fatalf("tag block %d tail nonzero", tb)
		}
	}
}

// TestSealedRoundTrip is the acceptance round trip: --seal writes, the
// plaintext beneath equals what the shared writer produces, --check with
// the passphrase authenticates every tag and checks clean, and the wrong
// passphrase fails the wrap open.
func TestSealedRoundTrip(t *testing.T) {
	pass := "correct horse battery staple"
	img, g := sealedImage(t, pass)

	// Structure-only mode: no passphrase verifies the v2 shape, reports
	// nothing hard, and notes the unverified span.
	var sawSealedNote bool
	for _, f := range checkImage(img, nil) {
		if !f.info {
			t.Fatalf("sealed structure-only check has hard finding: %v", f)
		}
		if f.code == "sealed" {
			sawSealedNote = true
		}
	}
	if !sawSealedNote {
		t.Fatal("expected informational sealed note without passphrase")
	}

	// Full check: every tag verified, as-replayed structure clean.
	if got := hardFindings(checkImage(img, []byte(pass))); len(got) != 0 {
		t.Fatalf("sealed image fails check: %v", got)
	}

	// Unseal the whole span and compare against the same writer's
	// plaintext — the seal is exactly AEAD per block, nothing more.
	want := make([]byte, goldenSize)
	writeStructures(want, g, goldenID, goldenTime)
	var dek [KeyBytes]byte
	sb, err := parseSuperblock(img, 0)
	if err != nil || sb == nil {
		t.Fatalf("superblock: %v", err)
	}
	d, err := unwrapDEK(sb, []byte(pass))
	if err != nil {
		t.Fatal(err)
	}
	dek = *d
	for b := uint32(2); b < g.TagFirst; b++ {
		e := tagEntry(img, g, b)
		nonce := (*[aeadNonceLen]byte)(e[:aeadNonceLen])
		tag := (*[aeadTagLen]byte)(e[aeadNonceLen:])
		out := make([]byte, BlockLen)
		if !aeadOpen(out, block(img, b), tag, blockAAD(goldenID, b), nonce, (*[aeadKeyLen]byte)(&dek)) {
			t.Fatalf("block %d fails AEAD open", b)
		}
		if !bytes.Equal(out, block(want, b)) {
			t.Fatalf("block %d plaintext differs from formatStructures", b)
		}
	}

	// Wrong passphrase: the wrap open refuses by name.
	var badPass bool
	for _, f := range checkImage(img, []byte("wrong")) {
		if f.code == "sealed_bad_passphrase" {
			badPass = true
		}
	}
	if !badPass {
		t.Fatal("wrong passphrase did not yield sealed_bad_passphrase")
	}
}

// TestSealedBitFlip: one flipped bit in a sealed block, its tag, or its
// nonce must fail --check with bad_block_auth naming the block.
func TestSealedBitFlip(t *testing.T) {
	pass := []byte("correct horse battery staple")
	for _, which := range []string{"ciphertext", "tag", "nonce"} {
		t.Run(which, func(t *testing.T) {
			img, g := sealedImage(t, string(pass))
			victim := g.DataFirst + 10 // an unreferenced data block
			switch which {
			case "ciphertext":
				block(img, victim)[137] ^= 0x01
			case "tag":
				e := tagEntry(img, g, victim)
				e[aeadNonceLen+3] ^= 0x01
			case "nonce":
				e := tagEntry(img, g, victim)
				e[5] ^= 0x01
			}
			want := fmt.Sprintf("block %d", victim)
			var found bool
			for _, f := range checkImage(img, pass) {
				if f.code == "bad_block_auth" && strings.Contains(f.detail, want) {
					found = true
				}
			}
			if !found {
				t.Fatalf("%s flip did not produce bad_block_auth %s", which, want)
			}
		})
	}
}

// TestSealedWrapTamper: a corrupt wrapped DEK is the same refusal as a
// wrong passphrase (ADR 0061 D9).
func TestSealedWrapTamper(t *testing.T) {
	pass := []byte("correct horse battery staple")
	img, _ := sealedImage(t, string(pass))
	for _, slot := range []uint64{0, BlockLen} {
		img[slot+sbWrappedDEK] ^= 0x01
		b := img[slot:]
		binary.LittleEndian.PutUint32(b[sbCksum:], fnv1a(b[:sbCksum]))
	}
	var found bool
	for _, f := range checkImage(img, pass) {
		if f.code == "sealed_bad_passphrase" {
			found = true
		}
	}
	if !found {
		t.Fatal("corrupt wrap did not yield sealed_bad_passphrase")
	}
}

// TestSealedBadSuperblock: a v2 superblock without seal_magic is
// malformed (bad_superblock), and a torn tag_first breaks the fixpoint.
func TestSealedBadSuperblock(t *testing.T) {
	pass := []byte("p")
	img, _ := sealedImage(t, string(pass))
	for _, slot := range []uint64{0, BlockLen} {
		binary.LittleEndian.PutUint32(img[slot+sbSealMagic:], 0)
		b := img[slot:]
		binary.LittleEndian.PutUint32(b[sbCksum:], fnv1a(b[:sbCksum]))
	}
	var found bool
	for _, f := range checkImage(img, pass) {
		if f.code == "bad_superblock" {
			found = true
		}
	}
	if !found {
		t.Fatal("v2 without seal_magic did not yield bad_superblock")
	}

	img, _ = sealedImage(t, string(pass))
	for _, slot := range []uint64{0, BlockLen} {
		binary.LittleEndian.PutUint32(img[slot+sbTagFirst:], 42)
		b := img[slot:]
		binary.LittleEndian.PutUint32(b[sbCksum:], fnv1a(b[:sbCksum]))
	}
	found = false
	for _, f := range checkImage(img, pass) {
		if f.code == "bad_superblock" || f.code == "geometry_mismatch" {
			found = true
		}
	}
	if !found {
		t.Fatal("torn tag_first did not yield a structural refusal")
	}
}

// TestSealedUnreplayedTxn pins the post-kill shape a sealed volume
// legitimately carries (M172e): a committed-uncheckpointed transaction.
// The kernel journals each payload's PLAINTEXT — sealed at the journal
// slot's AAD with an eager tag-home write — and re-seals at the dest on
// checkpoint, so a kill in the commit→checkpoint window leaves dest homes
// with their stale (ciphertext, tag) pairs. The as-replayed view of those
// dests is the authenticated payload, not the dead home pair: --check must
// report journal_unreplayed and nothing hard.
func TestSealedUnreplayedTxn(t *testing.T) {
	pass := []byte("correct horse battery staple")
	img, g := sealedImage(t, string(pass))
	sb, err := parseSuperblock(img, 0)
	if err != nil || sb == nil {
		t.Fatalf("superblock: %v", err)
	}
	dek, err := unwrapDEK(sb, pass)
	if err != nil {
		t.Fatal(err)
	}

	open := func(b uint32) []byte {
		return sealOpenBlock(t, img, g, sb.volumeID, dek, b)
	}
	// The kernel's journal-slot write: plaintext sealed at the slot's AAD,
	// its tag-home entry updated eagerly.
	sealSlot := func(slot uint32, pt []byte) {
		sealSlotWrite(t, img, g, sb.volumeID, dek, slot, pt)
	}

	// One committed txn installing a file at ino 2 (ibitmap + bbitmap +
	// itable + root dirent + data), committed but never checkpointed.
	const ino, dataBlk = 2, 0
	db := g.DataFirst + 1 + dataBlk
	content := []byte("replayed-by-vlfs-journal\n")
	ib := open(g.IbitmapFirst)
	ib[ino/8] |= 1 << (ino % 8)
	bb := open(g.BbitmapFirst)
	bb[db/8] |= 1 << (db % 8)
	it := open(g.ItableFirst)
	rec := it[ino*InodeBytes : (ino+1)*InodeBytes]
	rec[inKind] = kindFile
	binary.LittleEndian.PutUint16(rec[inNextents:], 1)
	binary.LittleEndian.PutUint32(rec[inSize:], uint32(len(content)))
	binary.LittleEndian.PutUint32(rec[inExtents:], db)
	binary.LittleEndian.PutUint32(rec[inExtents+4:], 1)
	binary.LittleEndian.PutUint32(rec[inCksum:], fnv1a(rec[:inCksum]))
	root := open(g.DataFirst)
	binary.LittleEndian.PutUint32(root[deInode:], ino)
	binary.LittleEndian.PutUint16(root[deNameLen:], 10)
	root[deKind] = kindFile
	copy(root[deName:], "REPLAY.TXT")
	data := make([]byte, BlockLen)
	copy(data, content)

	dests := []uint32{g.IbitmapFirst, g.BbitmapFirst, g.ItableFirst, g.DataFirst, db}
	payloads := [][]byte{ib, bb, it, root, data}
	pos := g.JournalFirst
	for i, p := range payloads {
		sealSlot(pos+1+uint32(i), p)
	}
	desc := make([]byte, BlockLen)
	binary.LittleEndian.PutUint32(desc[jdMagic:], MagicDesc)
	binary.LittleEndian.PutUint64(desc[jdSeq:], 1)
	binary.LittleEndian.PutUint16(desc[jdCount:], uint16(len(dests)))
	for i, d := range dests {
		binary.LittleEndian.PutUint32(desc[jdEntries+i*8:], d)
		binary.LittleEndian.PutUint32(desc[jdEntries+i*8+4:], fnv1a(payloads[i]))
	}
	binary.LittleEndian.PutUint32(desc[jdCksum:], fnv1a(desc[:jdCksum]))
	sealSlot(pos, desc)
	txn := append([]byte(nil), desc[:jdEntries+8*len(dests)]...)
	for _, p := range payloads {
		txn = append(txn, p...)
	}
	commit := make([]byte, BlockLen)
	binary.LittleEndian.PutUint32(commit[jcMagic:], MagicCommit)
	binary.LittleEndian.PutUint64(commit[jcSeq:], 1)
	binary.LittleEndian.PutUint32(commit[jcTxn:], fnv1a(txn))
	binary.LittleEndian.PutUint32(commit[jcCksum:], fnv1a(commit[:jcCksum]))
	sealSlot(pos+1+uint32(len(dests)), commit)

	// The killed image must check clean: the journal scan authenticates
	// each slot, the overlay serves the authenticated payload plaintext,
	// and no dest reports bad_block_auth.
	var unreplayed bool
	for _, f := range checkImage(img, pass) {
		if !f.info {
			t.Fatalf("killed sealed image has hard finding: %v", f)
		}
		if f.code == "journal_unreplayed" {
			unreplayed = true
		}
	}
	if !unreplayed {
		t.Fatal("committed-uncheckpointed txn did not report journal_unreplayed")
	}
}

// TestSealedTornJournalSlot pins the post-FLUSH-window residual named on
// #3043 (M172e, ADR 0061): a pre-commit kill that tears a journal slot's
// ciphertext — or its eager tag-entry pair — leaves a journal-region
// block whose AEAD open fails. The guest truncates the journal there
// exactly as a checksum failure does (vlfs journalRead names it torn,
// never BadBlockAuth), so --check reports the informational journal_torn
// and never bad_block_auth: the torn slot is dead journal, not a corrupt
// home. Two placements: the torn record itself, and a dead slot past the
// clean end the scan never reaches — the whole-span tag sweep still
// renders journal_torn, never a hard verdict.
func TestSealedTornJournalSlot(t *testing.T) {
	pass := []byte("correct horse battery staple")

	// build returns a sealed image carrying one committed, uncheckpointed
	// txn: DESC + one payload + COMMIT at the journal head.
	build := func(t *testing.T) ([]byte, Geometry) {
		img, g := sealedImage(t, string(pass))
		sb, err := parseSuperblock(img, 0)
		if err != nil || sb == nil {
			t.Fatalf("superblock: %v", err)
		}
		dek, err := unwrapDEK(sb, pass)
		if err != nil {
			t.Fatal(err)
		}
		dest := g.DataFirst + 7
		payload := make([]byte, BlockLen)
		copy(payload, "torn-window payload\n")
		pos := g.JournalFirst
		sealSlotWrite(t, img, g, sb.volumeID, dek, pos+1, payload)
		desc := make([]byte, BlockLen)
		binary.LittleEndian.PutUint32(desc[jdMagic:], MagicDesc)
		binary.LittleEndian.PutUint64(desc[jdSeq:], 1)
		binary.LittleEndian.PutUint16(desc[jdCount:], 1)
		binary.LittleEndian.PutUint32(desc[jdEntries:], dest)
		binary.LittleEndian.PutUint32(desc[jdEntries+4:], fnv1a(payload))
		binary.LittleEndian.PutUint32(desc[jdCksum:], fnv1a(desc[:jdCksum]))
		sealSlotWrite(t, img, g, sb.volumeID, dek, pos, desc)
		txn := append([]byte(nil), desc[:jdEntries+8]...)
		txn = append(txn, payload...)
		commit := make([]byte, BlockLen)
		binary.LittleEndian.PutUint32(commit[jcMagic:], MagicCommit)
		binary.LittleEndian.PutUint64(commit[jcSeq:], 1)
		binary.LittleEndian.PutUint32(commit[jcTxn:], fnv1a(txn))
		binary.LittleEndian.PutUint32(commit[jcCksum:], fnv1a(commit[:jcCksum]))
		sealSlotWrite(t, img, g, sb.volumeID, dek, pos+2, commit)
		return img, g
	}

	// The commit record's ciphertext torn mid-write: the txn dies with
	// the journal tail — journal_torn, no journal_unreplayed, no hard.
	t.Run("torn_commit_ciphertext", func(t *testing.T) {
		img, g := build(t)
		block(img, g.JournalFirst+2)[200] ^= 0x01
		var torn bool
		for _, f := range checkImage(img, pass) {
			if !f.info {
				t.Fatalf("torn journal slot has hard finding: %v", f)
			}
			switch f.code {
			case "journal_torn":
				torn = true
			case "journal_unreplayed":
				t.Fatal("torn txn must not count as unreplayed")
			}
		}
		if !torn {
			t.Fatal("torn journal slot did not report journal_torn")
		}
	})

	// A dead slot past the clean end (the scan breaks at the sealed-zero
	// slot after COMMIT and never reaches it): the span sweep's
	// journal-region open still reports journal_torn, never
	// bad_block_auth — matching the guest, which never reads it either
	// but would also call it torn.
	t.Run("torn_tag_entry_past_clean_end", func(t *testing.T) {
		img, g := build(t)
		victim := g.JournalFirst + 6
		e := tagEntry(img, g, victim)
		e[5] ^= 0x01 // the eager tag-entry pair torn, ciphertext intact
		var torn, unreplayed bool
		for _, f := range checkImage(img, pass) {
			if !f.info {
				t.Fatalf("dead journal slot has hard finding: %v", f)
			}
			switch f.code {
			case "journal_torn":
				torn = true
			case "journal_unreplayed":
				unreplayed = true
			}
		}
		if !unreplayed {
			t.Fatal("intact committed txn lost journal_unreplayed")
		}
		if !torn {
			t.Fatal("torn journal slot past the clean end not journal_torn")
		}
	})
}
