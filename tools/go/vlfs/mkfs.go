package main

import (
	"encoding/binary"
)

// formatImage formats img in place as an empty VLFS volume. len(img) is the
// volume size and must satisfy geometryFor's bounds. volumeID must be
// nonzero; mkfsTime is a unix-seconds stamp. The two superblock copies get
// sb_seq 2 (A) and 1 (B) so A is the newest valid copy at format time —
// the first mount-time superblock rewrite lands on B (ping-pong starts
// with B holding the lower sequence).
func formatImage(img []byte, volumeID, mkfsTime uint64) error {
	g, err := geometryFor(uint64(len(img)))
	if err != nil {
		return err
	}
	for i := range img {
		img[i] = 0
	}

	writeSuperblock(img, 0, g, 2, volumeID, mkfsTime)
	writeSuperblock(img, 1, g, 1, volumeID, mkfsTime)

	// Inode bitmap: inode 0 is reserved (ADR 0050 D3 — "inode 0 never
	// allocated" yet carries an allocated bit) and inode 1 is the root.
	ibitmap := block(img, g.IbitmapFirst)
	bitmapSet(ibitmap, 0)
	bitmapSet(ibitmap, 1)

	// Block bitmap: every structural block plus the root directory's one
	// data block are allocated at format time.
	bbitmap := block(img, g.BbitmapFirst)
	for i := uint32(0); i <= g.DataFirst; i++ {
		bitmapSet(bbitmap, i)
	}

	// Inode table: every slot carries a valid checksum (the format pins a
	// trailing FNV-1a on every structure, free or not). Inode 1 is the
	// empty root directory — kind 2, one extent covering a single zeroed
	// data block.
	itable := img[uint64(g.ItableFirst)*BlockLen : uint64(g.ItableFirst+g.ItableBlocks)*BlockLen]
	for i := uint32(0); i < g.InodeCount; i++ {
		slot := itable[uint64(i)*InodeBytes : uint64(i+1)*InodeBytes]
		binary.LittleEndian.PutUint32(slot[inCksum:], fnv1a(slot[:inCksum]))
	}
	root := itable[RootInode*InodeBytes : (RootInode+1)*InodeBytes]
	for i := range root {
		root[i] = 0
	}
	root[inKind] = kindDir
	binary.LittleEndian.PutUint16(root[inNextents:], 1)
	binary.LittleEndian.PutUint32(root[inSize:], BlockLen)
	binary.LittleEndian.PutUint64(root[inMtime:], mkfsTime)
	binary.LittleEndian.PutUint64(root[inCtime:], mkfsTime)
	binary.LittleEndian.PutUint32(root[inExtents:], g.DataFirst) // extents[0].first_block
	binary.LittleEndian.PutUint32(root[inExtents+4:], 1)         // extents[0].block_count
	binary.LittleEndian.PutUint32(root[inCksum:], fnv1a(root[:inCksum]))

	return nil
}
