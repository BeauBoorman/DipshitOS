package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
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
	for _, f := range checkImage(img) {
		if !f.info {
			t.Fatalf("populated fixture fails check: %v", f)
		}
	}
}

// TestCheckGoldenClean asserts the committed empty image passes --check.
func TestCheckGoldenClean(t *testing.T) {
	img := readGolden(t, "empty-16m.regions")
	for _, f := range checkImage(img) {
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
	for _, f := range checkImage(img) {
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
	for _, f := range checkImage(img) {
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
				binary.LittleEndian.PutUint32(img[off+sbVersion:], 2)
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
			for _, f := range checkImage(w.img) {
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
			for _, f := range checkImage(w.img) {
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
	for _, f := range checkImage(w.img) {
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
	for _, f := range checkImage(w.img) {
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
	for _, f := range checkImage(w.img) {
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
	for _, f := range checkImage(w.img) {
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
