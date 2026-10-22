// Package main holds mkfs.vlfs, the VirelaiOS VLFS formatter/checker.
//
// The on-disk format is frozen in docs/decisions/0050-vlfs.md (ADR 0050
// section D3). This tool is one of two implementations of those bytes —
// the other is the kernel's kernel/src/vlfs reader — and the committed
// `testdata/*.regions` fixtures are the proof that both emit/read the same
// image: the Zig tests @embedFile the same files this package's -update
// run regenerates.
//
// Layout summary (all integers little-endian; one VLFS block = 4096 B =
// 8 sectors of 512 B; every structure ends in an FNV-1a-32 checksum over
// its preceding bytes):
//
//	block 0            superblock A     (ping-pong; highest sb_seq wins)
//	block 1            superblock B
//	block 2 .. 2+J-1   journal region   (DESC + n*payload + COMMIT records)
//	ibitmap            1 block, 1 bit per inode (inode 0 is pre-allocated)
//	bbitmap            ceil(volume_blocks/8/4096) blocks, 1 bit per block
//	itable             ceil(inode_count/32) blocks, 128 B per inode
//	data region        the rest; block 0 of it is the root directory's
//
// This file is pure data: no syscalls, no dependencies outside stdlib.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	// SectorLen is the device sector (the VZ raw-image unit).
	SectorLen = 512
	// BlockLen is the VLFS allocation/journaling unit.
	BlockLen = 4096
	// SectorsPerBlock is BlockLen/SectorLen.
	SectorsPerBlock = BlockLen / SectorLen

	// MagicSuper is the superblock magic, "VLFS".
	MagicSuper uint32 = 0x53464C56
	// MagicDesc is the journal descriptor magic, "JDSC".
	MagicDesc uint32 = 0x4353444A
	// MagicCommit is the journal commit magic, "JCMT".
	MagicCommit uint32 = 0x544D434A
	// MagicExtent is the extent-block magic, "VXEB".
	MagicExtent uint32 = 0x42455856
	// Version is the v1 format version — an unsealed volume.
	Version uint32 = 1
	// Version2 is the sealed format version (ADR 0061).
	Version2 uint32 = 2

	// MagicSeal is the sealed-volume mark in the v2 superblock, "SLFS".
	// A version-2 superblock without it is malformed (bad_superblock).
	MagicSeal uint32 = 0x53464C53
	// KdfPbkdf2Sha256 is the only kdf_id: PBKDF2-HMAC-SHA256.
	KdfPbkdf2Sha256 uint32 = 1

	// Tag region (ADR 0061): the last region of the volume, tag_blocks
	// plaintext blocks ending at volume_blocks. Each carries
	// TagEntriesPerBlock {nonce, tag} pairs for the sealed span
	// [2, tag_first): entry for sealed block b is slot b-2.
	TagEntryBytes      = 28                             // nonce 12 B ‖ tag 16 B
	TagEntriesPerBlock = (BlockLen - 8) / TagEntryBytes // 146
	// KeyBytes is the DEK/KEK width; SealSaltBytes and WrapNonceBytes are
	// the superblock wrap material widths (ADR 0061 D9).
	KeyBytes       = aeadKeyLen
	SealSaltBytes  = 16
	WrapNonceBytes = aeadNonceLen

	// MinVolumeBytes is ADR 0050 D7's volume floor (volume_too_small).
	MinVolumeBytes uint64 = 16 << 20
	// MaxVolumeBytes is the volume ceiling (volume_too_large).
	MaxVolumeBytes uint64 = 1 << 30

	// InodeBytes is one inode record's width (itable slot i = inode i).
	InodeBytes = 128
	// InodesPerBlock is InodeBytes-per-block.
	InodesPerBlock = BlockLen / InodeBytes
	// MaxInodes is the mkfs-scaled inode ceiling (no_inodes).
	MaxInodes = 16384
	// MinInodes is the mkfs inode floor.
	MinInodes = 256

	// DirentBytes is one directory entry's width inside a directory's
	// file payload.
	DirentBytes = 272
	// MaxDirents is the live-dirent bound per directory (dir_full).
	MaxDirents = 1024
	// MaxName is the filename byte bound (directory.name_max).
	MaxName = 255
	// MaxDepth is the path depth bound (directory.depth_max).
	MaxDepth = 8

	// MaxPayload is the per-transaction payload block bound.
	MaxPayload = 64
	// MaxTxnSpan is a transaction's total span (DESC + n + COMMIT).
	MaxTxnSpan = MaxPayload + 2

	// InlineExtents is the inode's inline extent count.
	InlineExtents = 8
	// MaxExtentBlocks is the extent-chain bound (extent_overflow).
	MaxExtentBlocks = 4
	// ExtentsPerBlock is one extent block's capacity.
	ExtentsPerBlock = (BlockLen - 12) / 8 // 510

	// RootInode is the root directory's inode number (minted by mkfs).
	RootInode = 1

	// kind codes inside inodes and dirents.
	kindFree = 0
	kindFile = 1
	kindDir  = 2
)

// Superblock field offsets (ADR 0050 D3). The record occupies the first
// 512-byte sector of each of blocks 0 and 1; the rest of the block is zero.
const (
	sbMagic          = 0
	sbVersion        = 4
	sbSeq            = 8
	sbVolumeID       = 16
	sbVolumeBytes    = 24
	sbBlockShift     = 32
	sbVolumeBlocks   = 36
	sbJournalFirst   = 40
	sbJournalBlocks  = 44
	sbIbitmapFirst   = 48
	sbIbitmapBlocks  = 52
	sbBbitmapFirst   = 56
	sbBbitmapBlocks  = 60
	sbItableFirst    = 64
	sbItableBlocks   = 68
	sbDataFirst      = 72
	sbDataBlocks     = 76
	sbInodeCount     = 80
	sbJournalApplied = 84
	sbNextTxnSeq     = 92
	sbMkfsTime       = 100
	sbReserved       = 108 // 400 bytes: v1 all zero; v2 consumes +108..+204
	sbCksum          = 508
)

// v2 seal fields inside the superblock's reserved span (ADR 0061).
const (
	sbSealMagic  = 108 // u32 = MagicSeal
	sbKdfID      = 112 // u32 = KdfPbkdf2Sha256
	sbKdfIters   = 116 // u32, calibrated ~1 s at seal time
	sbKdfSalt    = 120 // 16 B, random at seal/rewrap
	sbWrapNonce  = 136 // 12 B, random at seal/rewrap
	sbWrappedDEK = 148 // 32 B, DEK ciphertext under the KEK
	sbWrapTag    = 180 // 16 B, AEAD tag of the wrap
	sbTagFirst   = 196 // u32, first tag-region block
	sbTagBlocks  = 200 // u32
	sbSealZero   = 204 // zero through +508 (cksum)
)

// Inode field offsets (ADR 0050 D3; 128-byte record).
const (
	inKind     = 0
	inFlags    = 1
	inNextents = 2
	inSize     = 4
	inMtime    = 8
	inCtime    = 16
	inExtents  = 24 // 8 × {first_block u32, block_count u32}
	inNextExt  = 88
	inReserved = 92 // 32 bytes, zero
	inCksum    = 124
)

// Dirent field offsets (272-byte record).
const (
	deInode    = 0
	deNameLen  = 4
	deKind     = 6
	deFlags    = 7
	deReserved = 8  // u64 zero
	deName     = 16 // 256 bytes
)

// Journal record field offsets (ADR 0050 D3).
const (
	jdMagic   = 0
	jdSeq     = 4
	jdCount   = 12 // u16, 1..64
	jdFlags   = 14 // u16, 0
	jdEntries = 16 // {dest_block u32, payload_cksum u32} × n
	jdCksum   = BlockLen - 4
	jcMagic   = 0
	jcSeq     = 4
	jcTxn     = 12 // txn_cksum
	jcCksum   = BlockLen - 4
)

// Extent-block field offsets.
const (
	xbMagic   = 0
	xbNext    = 4
	xbCount   = 8  // u16, ≤ 510
	xbResv    = 10 // u16, 0
	xbExtents = 12
	xbCksum   = BlockLen - 4
)

// fnv1a is the house checksum: FNV-1a-32 (offset basis 2166136261,
// prime 16777619) over b.
func fnv1a(b []byte) uint32 {
	h := uint32(2166136261)
	for _, c := range b {
		h ^= uint32(c)
		h *= 16777619
	}
	return h
}

func clamp(v, lo, hi uint64) uint64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Geometry is the derived region map of a volume.
type Geometry struct {
	VolumeBytes   uint64
	VolumeBlocks  uint32
	JournalFirst  uint32 // always 2
	JournalBlocks uint32
	IbitmapFirst  uint32
	BbitmapFirst  uint32
	BbitmapBlocks uint32
	ItableFirst   uint32
	ItableBlocks  uint32
	DataFirst     uint32
	DataBlocks    uint32
	InodeCount    uint32
	// Tag region (v2 only; both zero on v1). TagFirst is the first
	// tag-region block; DataFirst+DataBlocks == TagFirst on a sealed
	// volume — the tag region is carved off the end of the data region.
	TagFirst  uint32
	TagBlocks uint32
}

// geometryFor computes the mkfs layout for a volume of volumeBytes, which
// must be a multiple of the block length (the VZ floor is 512 B, but a VLFS
// volume is an integral number of 4 KiB blocks).
func geometryFor(volumeBytes uint64) (Geometry, error) {
	if volumeBytes < MinVolumeBytes {
		return Geometry{}, errCode{"volume_too_small", fmt.Sprintf("%d < %d", volumeBytes, MinVolumeBytes)}
	}
	if volumeBytes > MaxVolumeBytes {
		return Geometry{}, errCode{"volume_too_large", fmt.Sprintf("%d > %d", volumeBytes, MaxVolumeBytes)}
	}
	if volumeBytes%BlockLen != 0 {
		return Geometry{}, errCode{"geometry_mismatch", fmt.Sprintf("size %d not a multiple of %d", volumeBytes, BlockLen)}
	}
	vb := uint32(volumeBytes / BlockLen)
	journal := uint32(clamp(uint64(vb)/16, 512, 2048))
	inodes := uint32(clamp(volumeBytes/65536, MinInodes, MaxInodes))
	itable := (inodes + InodesPerBlock - 1) / InodesPerBlock
	bbitmap := (vb + 8*BlockLen - 1) / (8 * BlockLen)
	g := Geometry{
		VolumeBytes:   volumeBytes,
		VolumeBlocks:  vb,
		JournalFirst:  2,
		JournalBlocks: journal,
		IbitmapFirst:  2 + journal,
		BbitmapFirst:  3 + journal,
		BbitmapBlocks: bbitmap,
		ItableFirst:   3 + journal + bbitmap,
		ItableBlocks:  itable,
		InodeCount:    inodes,
	}
	g.DataFirst = g.ItableFirst + itable
	g.DataBlocks = vb - g.DataFirst
	if g.DataBlocks == 0 {
		return Geometry{}, errCode{"geometry_mismatch", "no data region"}
	}
	return g, nil
}

// tagBlocksFor solves the ADR 0061 fixpoint: the tag region holds one
// 28-byte entry per sealed block in [2, tag_first) where
// tag_first = volume_blocks − tag_blocks, so the count must satisfy
// 146·tag_blocks ≥ volume_blocks − 2 − tag_blocks — i.e.
// tag_blocks = ⌈(volume_blocks − 2)/147⌉ (28 blocks at the 16-MiB floor,
// 1,784 at the 1-GiB cap).
func tagBlocksFor(volumeBlocks uint32) uint32 {
	return (volumeBlocks - 2 + TagEntriesPerBlock) / (TagEntriesPerBlock + 1)
}

// sealedGeometry carves the tag region off the end of a v1 layout: the
// sealed span becomes [2, tag_first) and the data region shrinks by
// tag_blocks. Fails if sealing would leave no data region.
func sealedGeometry(g Geometry) (Geometry, error) {
	tb := tagBlocksFor(g.VolumeBlocks)
	if tb >= g.DataBlocks {
		return Geometry{}, errCode{"volume_too_small",
			fmt.Sprintf("tag region %d blocks covers data region %d", tb, g.DataBlocks)}
	}
	g.TagBlocks = tb
	g.TagFirst = g.VolumeBlocks - tb
	g.DataBlocks = g.TagFirst - g.DataFirst
	return g, nil
}

// errCode is a named ADR 0050 refusal with a detail line. The name is the
// diagnostic surface; check reports it verbatim and the kernel maps its
// own errors to the same spellings.
type errCode struct {
	code   string
	detail string
}

func (e errCode) Error() string {
	if e.detail == "" {
		return e.code
	}
	return e.code + ": " + e.detail
}

// errIs reports whether err (or anything it wraps) carries code.
func errIs(err error, code string) bool {
	var ec errCode
	if errors.As(err, &ec) {
		return ec.code == code
	}
	return false
}

// block returns the byte range of VLFS block b inside img.
func block(img []byte, b uint32) []byte {
	off := uint64(b) * BlockLen
	return img[off : off+BlockLen]
}

// bitmapSet marks bit i (LSB-first per byte) in a bitmap block slice.
func bitmapSet(bitmap []byte, i uint32) {
	bitmap[i/8] |= 1 << (i % 8)
}

// bitmapGet reports whether bit i is set.
func bitmapGet(bitmap []byte, i uint32) bool {
	return bitmap[i/8]&(1<<(i%8)) != 0
}

// writeSuperblock stamps a valid superblock into the first sector of
// block slot (0 or 1) and zeroes the rest of that block.
func writeSuperblock(img []byte, slot uint32, g Geometry, seq, volumeID, mkfsTime uint64) {
	b := block(img, slot)
	for i := range b {
		b[i] = 0
	}
	binary.LittleEndian.PutUint32(b[sbMagic:], MagicSuper)
	binary.LittleEndian.PutUint32(b[sbVersion:], Version)
	binary.LittleEndian.PutUint64(b[sbSeq:], seq)
	binary.LittleEndian.PutUint64(b[sbVolumeID:], volumeID)
	binary.LittleEndian.PutUint64(b[sbVolumeBytes:], g.VolumeBytes)
	binary.LittleEndian.PutUint32(b[sbBlockShift:], 12)
	binary.LittleEndian.PutUint32(b[sbVolumeBlocks:], g.VolumeBlocks)
	binary.LittleEndian.PutUint32(b[sbJournalFirst:], g.JournalFirst)
	binary.LittleEndian.PutUint32(b[sbJournalBlocks:], g.JournalBlocks)
	binary.LittleEndian.PutUint32(b[sbIbitmapFirst:], g.IbitmapFirst)
	binary.LittleEndian.PutUint32(b[sbIbitmapBlocks:], 1)
	binary.LittleEndian.PutUint32(b[sbBbitmapFirst:], g.BbitmapFirst)
	binary.LittleEndian.PutUint32(b[sbBbitmapBlocks:], g.BbitmapBlocks)
	binary.LittleEndian.PutUint32(b[sbItableFirst:], g.ItableFirst)
	binary.LittleEndian.PutUint32(b[sbItableBlocks:], g.ItableBlocks)
	binary.LittleEndian.PutUint32(b[sbDataFirst:], g.DataFirst)
	binary.LittleEndian.PutUint32(b[sbDataBlocks:], g.DataBlocks)
	binary.LittleEndian.PutUint32(b[sbInodeCount:], g.InodeCount)
	binary.LittleEndian.PutUint64(b[sbJournalApplied:], 0)
	binary.LittleEndian.PutUint64(b[sbNextTxnSeq:], 1)
	binary.LittleEndian.PutUint64(b[sbMkfsTime:], mkfsTime)
	binary.LittleEndian.PutUint32(b[sbCksum:], fnv1a(b[:sbCksum]))
}
