package main

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
)

// pbkdf2Key derives a 32-byte key: PBKDF2-HMAC-SHA256 (ADR 0061 D9) via
// the standard library — no new module dependency.
func pbkdf2Key(pass, salt []byte, iters uint32) ([]byte, error) {
	return pbkdf2.Key(sha256.New, string(pass), salt, int(iters), KeyBytes)
}

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
	writeStructures(img, g, volumeID, mkfsTime)
	return nil
}

// writeStructures lays down the structures v1 and v2 share: the
// superblock pair, the inode bitmap, the block bitmap, the zeroed
// checksummed inode table, and the empty root directory. The caller
// stamps v2's seal span and version afterwards — this function emits the
// v1 base every format starts from.
func writeStructures(img []byte, g Geometry, volumeID, mkfsTime uint64) {
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
	// data block are allocated at format time. On v2 the tag region is
	// structural too — plaintext homes for public nonces and tags.
	bbitmap := block(img, g.BbitmapFirst)
	for i := uint32(0); i <= g.DataFirst; i++ {
		bitmapSet(bbitmap, i)
	}
	for i := g.TagFirst; g.TagBlocks != 0 && i < g.VolumeBlocks; i++ {
		bitmapSet(bbitmap, i)
	}

	// Inode table: every slot carries a valid checksum (the format pins a
	// trailing FNV-1a on every structure, free or not). Inode 1 is the
	// empty root directory — kind 2, one extent covering a single zeroed
	// data block. Each slot is sliced out of its own itable block so a
	// partial tail block can never spill writes into the data region.
	for i := uint32(0); i < g.InodeCount; i++ {
		slot := block(img, g.ItableFirst+i/InodesPerBlock)[uint64(i%InodesPerBlock)*InodeBytes:][:InodeBytes]
		binary.LittleEndian.PutUint32(slot[inCksum:], fnv1a(slot[:inCksum]))
	}
	root := block(img, g.ItableFirst)[RootInode*InodeBytes:][:InodeBytes]
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
}

// sealParams carries the wrap material the v2 superblock records (ADR
// 0061 D9): the minted DEK, the KDF salt and iteration count, and the
// wrap nonce. iters is the calibrated PBKDF2 count (~1 s on the
// reference host at seal time).
type sealParams struct {
	dek       [KeyBytes]byte
	salt      [SealSaltBytes]byte
	wrapNonce [WrapNonceBytes]byte
	iters     uint32
}

// newSealParams mints fresh random seal material from the host CSPRNG.
// iters must already be calibrated by the caller.
func newSealParams(iters uint32) (sealParams, error) {
	var p sealParams
	if _, err := rand.Read(p.dek[:]); err != nil {
		return p, err
	}
	if _, err := rand.Read(p.salt[:]); err != nil {
		return p, err
	}
	if _, err := rand.Read(p.wrapNonce[:]); err != nil {
		return p, err
	}
	p.iters = iters
	return p, nil
}

// wrapBlockNum is the sentinel block number in the wrap's AAD: the same
// volume_id‖block shape as sealed-block AAD, but a number no real block
// (the volume caps at 262,144) or superblock can claim, binding the DEK
// wrap to this volume without colliding with the sealed span.
const wrapBlockNum = 0xFFFFFFFF

// blockAAD is ADR 0061's bound context: volume UUID ‖ block number,
// little-endian — a tag verifies only at this position in this volume.
func blockAAD(volumeID uint64, blockNum uint32) []byte {
	var aad [12]byte
	binary.LittleEndian.PutUint64(aad[0:8], volumeID)
	binary.LittleEndian.PutUint32(aad[8:12], blockNum)
	return aad[:]
}

// writeSealFields stamps the v2 superblock's seal span (+108..+204) and
// flips version to 2, then rewrites the checksum over the whole record.
// The wrap is an AEAD seal of the DEK under the KEK derived from the
// passphrase — an unwrap is an AEAD open, so a wrong passphrase and a
// corrupt wrap are the same failure (ADR 0061 D9).
func writeSealFields(sb []byte, g Geometry, volumeID uint64, p *sealParams, pass []byte) error {
	kek, err := pbkdf2Key(pass, p.salt[:], p.iters)
	if err != nil {
		return err
	}
	var wrapped [KeyBytes]byte
	var wtag [aeadTagLen]byte
	nonce := (*[aeadNonceLen]byte)(p.wrapNonce[:])
	key := (*[aeadKeyLen]byte)(kek)
	aeadSeal(wrapped[:], &wtag, p.dek[:], blockAAD(volumeID, wrapBlockNum), nonce, key)

	binary.LittleEndian.PutUint32(sb[sbVersion:], Version2)
	binary.LittleEndian.PutUint32(sb[sbSealMagic:], MagicSeal)
	binary.LittleEndian.PutUint32(sb[sbKdfID:], KdfPbkdf2Sha256)
	binary.LittleEndian.PutUint32(sb[sbKdfIters:], p.iters)
	copy(sb[sbKdfSalt:], p.salt[:])
	copy(sb[sbWrapNonce:], p.wrapNonce[:])
	copy(sb[sbWrappedDEK:], wrapped[:])
	copy(sb[sbWrapTag:], wtag[:])
	binary.LittleEndian.PutUint32(sb[sbTagFirst:], g.TagFirst)
	binary.LittleEndian.PutUint32(sb[sbTagBlocks:], g.TagBlocks)
	binary.LittleEndian.PutUint32(sb[sbCksum:], fnv1a(sb[:sbCksum]))
	return nil
}

// formatSealedImage formats img as an empty sealed (v2) volume per ADR
// 0061: the layout is writeStructures' with a shrunken data region, then
// every block in the sealed span [2, tag_first) is encrypted in place
// under the DEK with a fresh random nonce per block, nonces and tags
// recorded in the plaintext tag region. pass is the passphrase used to
// wrap the DEK into the superblock pair.
func formatSealedImage(img []byte, volumeID, mkfsTime uint64, pass []byte, p sealParams) error {
	g, err := geometryFor(uint64(len(img)))
	if err != nil {
		return err
	}
	g, err = sealedGeometry(g)
	if err != nil {
		return err
	}
	writeStructures(img, g, volumeID, mkfsTime)
	for _, slot := range []uint32{0, 1} {
		if err := writeSealFields(block(img, slot), g, volumeID, &p, pass); err != nil {
			return err
		}
	}
	return sealBlocks(img, g, volumeID, &p.dek)
}

// sealBlocks encrypts every block in the sealed span [2, tag_first) in
// place under dek with a fresh random 96-bit nonce per block (ADR 0061:
// the nonce need not be secret, it must never repeat under one DEK) and
// stores each {nonce, tag} pair in tag slot b-2. A failed host CSPRNG
// refuses sealing, mirroring the kernel's unseeded-CSPRNG refusal.
func sealBlocks(img []byte, g Geometry, volumeID uint64, dek *[KeyBytes]byte) error {
	key := (*[aeadKeyLen]byte)(dek[:])
	for b := uint32(2); b < g.TagFirst; b++ {
		var nonce [aeadNonceLen]byte
		if _, err := rand.Read(nonce[:]); err != nil {
			return errCode{"seal_failed", "csprng: " + err.Error()}
		}
		blk := block(img, b)
		var tag [aeadTagLen]byte
		aeadSeal(blk, &tag, blk, blockAAD(volumeID, b), &nonce, key)
		e := tagEntry(img, g, b)
		copy(e[:aeadNonceLen], nonce[:])
		copy(e[aeadNonceLen:], tag[:])
	}
	return nil
}

// tagEntry returns the 28-byte {nonce, tag} slot for sealed block b
// (2 ≤ b < tag_first): tag block tag_first + (b−2)/146, byte offset
// ((b−2) mod 146) × 28 (ADR 0061).
func tagEntry(img []byte, g Geometry, b uint32) []byte {
	slot := b - 2
	blk := block(img, g.TagFirst+slot/TagEntriesPerBlock)
	return blk[uint64(slot%TagEntriesPerBlock)*TagEntryBytes:][:TagEntryBytes]
}
