package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"sort"
)

// bitsPerMapBlock is the number of volume-block bits one bbitmap block
// carries — the kernel's write.zig `bits_per_map_block`.
const bitsPerMapBlock = 8 * BlockLen

// finding is one check result: code is a named ADR 0050 refusal; info marks
// the informational reports (journal_torn, journal_unreplayed) that describe
// expected post-kill state rather than corruption.
type finding struct {
	code   string
	detail string
	info   bool
}

func (f finding) String() string {
	if f.detail == "" {
		return f.code
	}
	return f.code + ": " + f.detail
}

// superblock is the decoded +508 bytes of a superblock sector.
type superblock struct {
	version        uint32
	seq            uint64
	volumeID       uint64
	volumeBytes    uint64
	blockShift     uint32
	volumeBlocks   uint32
	journalFirst   uint32
	journalBlocks  uint32
	ibitmapFirst   uint32
	ibitmapBlocks  uint32
	bbitmapFirst   uint32
	bbitmapBlocks  uint32
	itableFirst    uint32
	itableBlocks   uint32
	dataFirst      uint32
	dataBlocks     uint32
	inodeCount     uint32
	journalApplied uint64
	nextTxnSeq     uint64
	mkfsTime       uint64
	// v2 seal span (ADR 0061); all zero on v1.
	kdfID      uint32
	kdfIters   uint32
	kdfSalt    [SealSaltBytes]byte
	wrapNonce  [WrapNonceBytes]byte
	wrappedDEK [KeyBytes]byte
	wrapTag    [aeadTagLen]byte
	tagFirst   uint32
	tagBlocks  uint32
}

// parseSuperblock validates one superblock sector. It returns (nil, nil)
// when the magic is absent — that copy is simply empty — and (nil, err)
// when a VLFS header is present but the copy fails validation.
func parseSuperblock(img []byte, slot uint32) (*superblock, error) {
	if uint64(slot+1)*BlockLen > uint64(len(img)) {
		return nil, errCode{"geometry_mismatch", "image too small for superblocks"}
	}
	b := block(img, slot)[:SectorLen]
	if binary.LittleEndian.Uint32(b[sbMagic:]) != MagicSuper {
		return nil, nil
	}
	version := binary.LittleEndian.Uint32(b[sbVersion:])
	if version != Version && version != Version2 {
		return nil, errCode{"unsupported_version", fmt.Sprintf("version %d", version)}
	}
	if binary.LittleEndian.Uint32(b[sbCksum:]) != fnv1a(b[:sbCksum]) {
		return nil, errCode{"bad_superblock", fmt.Sprintf("slot %d checksum", slot)}
	}
	s := &superblock{
		version:        version,
		seq:            binary.LittleEndian.Uint64(b[sbSeq:]),
		volumeID:       binary.LittleEndian.Uint64(b[sbVolumeID:]),
		volumeBytes:    binary.LittleEndian.Uint64(b[sbVolumeBytes:]),
		blockShift:     binary.LittleEndian.Uint32(b[sbBlockShift:]),
		volumeBlocks:   binary.LittleEndian.Uint32(b[sbVolumeBlocks:]),
		journalFirst:   binary.LittleEndian.Uint32(b[sbJournalFirst:]),
		journalBlocks:  binary.LittleEndian.Uint32(b[sbJournalBlocks:]),
		ibitmapFirst:   binary.LittleEndian.Uint32(b[sbIbitmapFirst:]),
		ibitmapBlocks:  binary.LittleEndian.Uint32(b[sbIbitmapBlocks:]),
		bbitmapFirst:   binary.LittleEndian.Uint32(b[sbBbitmapFirst:]),
		bbitmapBlocks:  binary.LittleEndian.Uint32(b[sbBbitmapBlocks:]),
		itableFirst:    binary.LittleEndian.Uint32(b[sbItableFirst:]),
		itableBlocks:   binary.LittleEndian.Uint32(b[sbItableBlocks:]),
		dataFirst:      binary.LittleEndian.Uint32(b[sbDataFirst:]),
		dataBlocks:     binary.LittleEndian.Uint32(b[sbDataBlocks:]),
		inodeCount:     binary.LittleEndian.Uint32(b[sbInodeCount:]),
		journalApplied: binary.LittleEndian.Uint64(b[sbJournalApplied:]),
		nextTxnSeq:     binary.LittleEndian.Uint64(b[sbNextTxnSeq:]),
		mkfsTime:       binary.LittleEndian.Uint64(b[sbMkfsTime:]),
	}
	if version == Version2 {
		s.kdfID = binary.LittleEndian.Uint32(b[sbKdfID:])
		s.kdfIters = binary.LittleEndian.Uint32(b[sbKdfIters:])
		copy(s.kdfSalt[:], b[sbKdfSalt:])
		copy(s.wrapNonce[:], b[sbWrapNonce:])
		copy(s.wrappedDEK[:], b[sbWrappedDEK:])
		copy(s.wrapTag[:], b[sbWrapTag:])
		s.tagFirst = binary.LittleEndian.Uint32(b[sbTagFirst:])
		s.tagBlocks = binary.LittleEndian.Uint32(b[sbTagBlocks:])
	}
	if err := s.checkGeometry(); err != nil {
		return nil, err
	}
	if version == Version2 {
		if err := s.checkSeal(b); err != nil {
			return nil, err
		}
	}
	return s, nil
}

// checkSeal enforces the ADR 0061 v2 structure inside the reserved span:
// the seal mark, the only kdf_id, a nonzero iteration count, the
// tag-region fixpoint, and zeroed reserved bytes through +508. A v2
// superblock without seal_magic is malformed (bad_superblock).
func (s *superblock) checkSeal(b []byte) error {
	bad := func(format string, args ...any) error {
		return errCode{"bad_superblock", fmt.Sprintf(format, args...)}
	}
	if binary.LittleEndian.Uint32(b[sbSealMagic:]) != MagicSeal {
		return bad("v2 without seal_magic")
	}
	if s.kdfID != KdfPbkdf2Sha256 {
		return bad("kdf_id %d", s.kdfID)
	}
	if s.kdfIters == 0 {
		return bad("kdf_iters is zero")
	}
	if want := tagBlocksFor(s.volumeBlocks); s.tagBlocks != want {
		return bad("tag_blocks %d != ceil((volume_blocks-2)/%d)=%d",
			s.tagBlocks, TagEntriesPerBlock+1, want)
	}
	if s.tagFirst+s.tagBlocks != s.volumeBlocks {
		return bad("tag_first %d + tag_blocks %d != volume_blocks %d",
			s.tagFirst, s.tagBlocks, s.volumeBlocks)
	}
	if !isZero(b[sbSealZero:sbCksum]) {
		return bad("seal reserved bytes nonzero")
	}
	return nil
}

// checkGeometry enforces the ADR D3 layout: fixed ordering, the mkfs
// formulas, and regions that tile the volume without overlap or gap.
func (s *superblock) checkGeometry() error {
	bad := func(format string, args ...any) error {
		return errCode{"geometry_mismatch", fmt.Sprintf(format, args...)}
	}
	if s.volumeID == 0 {
		return bad("volume_id is zero")
	}
	if s.blockShift != 12 || BlockLen != 1<<s.blockShift {
		return bad("block_shift %d", s.blockShift)
	}
	if s.volumeBytes == 0 || s.volumeBytes%BlockLen != 0 {
		return bad("volume_bytes %d", s.volumeBytes)
	}
	if uint64(s.volumeBlocks) != s.volumeBytes/BlockLen {
		return bad("volume_blocks %d != volume_bytes/4096", s.volumeBlocks)
	}
	if s.volumeBytes < MinVolumeBytes {
		return errCode{"volume_too_small", fmt.Sprintf("%d", s.volumeBytes)}
	}
	if s.volumeBytes > MaxVolumeBytes {
		return errCode{"volume_too_large", fmt.Sprintf("%d", s.volumeBytes)}
	}
	// The mkfs formulas are part of the v1 layout, not suggestions.
	if j := uint32(clamp(uint64(s.volumeBlocks)/16, 512, 2048)); s.journalBlocks != j {
		return bad("journal_blocks %d != clamp(volume_blocks/16)", s.journalBlocks)
	}
	if n := uint32(clamp(s.volumeBytes/65536, MinInodes, MaxInodes)); s.inodeCount != n {
		return bad("inode_count %d != clamp(volume_bytes/65536)", s.inodeCount)
	}
	if s.journalFirst != 2 || s.ibitmapFirst != 2+s.journalBlocks || s.ibitmapBlocks != 1 {
		return bad("journal/ibitmap placement")
	}
	if bb := (s.volumeBlocks + 8*BlockLen - 1) / (8 * BlockLen); s.bbitmapFirst != s.ibitmapFirst+1 || s.bbitmapBlocks != bb {
		return bad("bbitmap placement")
	}
	if s.itableFirst != s.bbitmapFirst+s.bbitmapBlocks ||
		s.itableBlocks != (s.inodeCount+InodesPerBlock-1)/InodesPerBlock {
		return bad("itable placement")
	}
	// v1 tiles data blocks to the end of the volume; v2 ends the data
	// region at tag_first, where the plaintext tag region begins.
	dataEnd := s.volumeBlocks
	if s.version == Version2 {
		dataEnd = s.tagFirst
	}
	if s.dataFirst != s.itableFirst+s.itableBlocks || s.dataFirst+s.dataBlocks != dataEnd {
		return bad("data region %d+%d vs data end %d", s.dataFirst, s.dataBlocks, dataEnd)
	}
	if s.nextTxnSeq == 0 {
		return bad("next_txn_seq is zero")
	}
	return nil
}

// extentWalk collects the file-block -> disk-block map of one inode,
// validating inline extents and up to MaxExtentBlocks chained extent
// blocks. Every validated disk block is recorded in referenced (value is
// the inode, or markChain for chain blocks themselves) so overlap and
// bitmap checks share the one walk.
func (c *checker) extentWalk(ino uint32, rec []byte) (blocks []uint32) {
	mark := func(b uint32, owner uint32) {
		if prev, ok := c.referenced[b]; ok {
			c.fail("extent_overlap", "block %d in inodes %d and %d", b, prev, ino)
			return
		}
		c.referenced[b] = owner
	}
	one := func(first, count uint32) {
		if first < c.g.DataFirst || count == 0 || uint64(first)+uint64(count) > uint64(c.dataEnd()) {
			c.fail("extent_out_of_range", "inode %d extent %d+%d", ino, first, count)
			return
		}
		for b := first; b < first+count; b++ {
			mark(b, ino)
			blocks = append(blocks, b)
		}
	}
	next := binary.LittleEndian.Uint16(rec[inNextents:])
	for e := 0; e < int(next) && e < InlineExtents; e++ {
		one(binary.LittleEndian.Uint32(rec[inExtents+e*8:]),
			binary.LittleEndian.Uint32(rec[inExtents+e*8+4:]))
	}
	chain := binary.LittleEndian.Uint32(rec[inNextExt:])
	for depth := 0; chain != 0; depth++ {
		if depth >= MaxExtentBlocks {
			c.fail("extent_overflow", "inode %d chain deeper than %d", ino, MaxExtentBlocks)
			return
		}
		if chain < c.g.DataFirst || chain >= c.dataEnd() {
			c.fail("extent_out_of_range", "inode %d extent block %d", ino, chain)
			return
		}
		if _, dup := c.referenced[chain]; dup {
			c.fail("extent_overlap", "extent block %d double-owned", chain)
			return
		}
		mark(chain, markChain)
		blk := c.plain(chain)
		if binary.LittleEndian.Uint32(blk[xbMagic:]) != MagicExtent ||
			binary.LittleEndian.Uint32(blk[xbCksum:]) != fnv1a(blk[:xbCksum]) ||
			binary.LittleEndian.Uint16(blk[xbResv:]) != 0 {
			c.fail("extent_chain_corrupt", "inode %d block %d", ino, chain)
			return
		}
		cnt := binary.LittleEndian.Uint16(blk[xbCount:])
		if cnt > ExtentsPerBlock {
			c.fail("extent_chain_corrupt", "inode %d count %d", ino, cnt)
			return
		}
		for e := 0; e < int(cnt); e++ {
			one(binary.LittleEndian.Uint32(blk[xbExtents+e*8:]),
				binary.LittleEndian.Uint32(blk[xbExtents+e*8+4:]))
		}
		chain = binary.LittleEndian.Uint32(blk[xbNext:])
	}
	return blocks
}

const markChain = 1 << 30 // referenced[] sentinel for extent-chain blocks

// checker carries the image, the journal overlay, and accumulated findings.
type checker struct {
	img        []byte
	g          Geometry
	overlay    map[uint32][]byte
	referenced map[uint32]uint32
	inodes     [][]byte
	ibUsed     []bool
	out        []finding
	// Sealed-volume state: dek is nil on v1 and on v2 without a
	// passphrase; volID feeds the AAD; authBad dedupes bad_block_auth
	// findings so a repeatedly-read block reports once.
	dek     *[KeyBytes]byte
	volID   uint64
	authBad map[uint32]bool
}

func (c *checker) fail(code, format string, args ...any) {
	c.out = append(c.out, finding{code, fmt.Sprintf(format, args...), false})
}

func (c *checker) note(code, format string, args ...any) {
	c.out = append(c.out, finding{code, fmt.Sprintf(format, args...), true})
}

// read returns block b's stored bytes as the overlay reports them
// (as-replayed view). On a sealed volume homes are ciphertext for every
// block in [2, tag_first) and plaintext elsewhere; the overlay's
// journaled payloads are plaintext — each was opened (authenticated)
// when the journal scan read its slot.
func (c *checker) read(b uint32) []byte {
	if o, ok := c.overlay[b]; ok {
		return o
	}
	return block(c.img, b)
}

// plain returns block b's plaintext: the stored bytes on v1, on
// plaintext regions (superblocks, tag region), and whenever no DEK was
// unwrapped; otherwise the AEAD-opened contents of the stored sealed
// block. A failed open is reported once per block (bad_block_auth) and
// yields zeros — no path serves unauthenticated bytes downstream.
func (c *checker) plain(b uint32) []byte {
	stored := c.read(b)
	if c.dek == nil || b < 2 || b >= c.g.TagFirst {
		return stored
	}
	// A journaled payload is plaintext that was already authenticated when
	// its journal slot was AEAD-opened; the dest's stored home pair is
	// stale ciphertext the replay owns, never an oracle for it (M172e —
	// re-opening it here false-flagged every committed-uncheckpointed
	// transaction's dests as bad_block_auth).
	if _, ok := c.overlay[b]; ok {
		return stored
	}
	out, ok := c.sealOpen(b, stored)
	if !ok && !c.authBad[b] {
		c.authBad[b] = true
		c.fail("bad_block_auth", "block %d", b)
	}
	return out
}

// plainJournal is plain() for a journal-region read: a failed AEAD open
// truncates the journal exactly as a checksum failure does (ADR 0061;
// the guest's journalRead names it torn, never BadBlockAuth), so it
// reports the informational journal_torn — the expected shape after a
// pre-commit kill tore a journal slot's ciphertext or its eager
// tag-entry pair — never the hard bad_block_auth a sealed home earns.
func (c *checker) plainJournal(b uint32) []byte {
	stored := c.read(b)
	if c.dek == nil {
		return stored
	}
	out, ok := c.sealOpen(b, stored)
	if !ok && !c.authBad[b] {
		c.authBad[b] = true
		c.note("journal_torn", "journal block %d fails AEAD open", b)
	}
	return out
}

// sealOpen AEAD-opens one sealed block's stored bytes against its
// {nonce, tag} home entry. A failed open yields zeros and false.
func (c *checker) sealOpen(b uint32, stored []byte) ([]byte, bool) {
	e := c.tagSlot(b)
	var nonce [aeadNonceLen]byte
	var tag [aeadTagLen]byte
	copy(nonce[:], e[:aeadNonceLen])
	copy(tag[:], e[aeadNonceLen:])
	out := make([]byte, BlockLen)
	return out, aeadOpen(out, stored, &tag, blockAAD(c.volID, b), &nonce, c.dek)
}

// tagSlot reads the {nonce, tag} slot for sealed block b through the
// stored-byte view, so a journaled tag-block update in the overlay is
// seen (ADR 0061: tag blocks ride inside the transaction that carries
// their payloads).
func (c *checker) tagSlot(b uint32) []byte {
	slot := b - 2
	blk := c.read(c.g.TagFirst + slot/TagEntriesPerBlock)
	return blk[uint64(slot%TagEntriesPerBlock)*TagEntryBytes:][:TagEntryBytes]
}

// unwrapDEK derives the KEK from the passphrase and the superblock's KDF
// fields, then AEAD-opens the wrapped DEK — a wrong passphrase and a
// corrupt wrap are the same refusal (ADR 0061 D9/D10).
func unwrapDEK(sb *superblock, pass []byte) (*[KeyBytes]byte, error) {
	kek, err := pbkdf2Key(pass, sb.kdfSalt[:], sb.kdfIters)
	if err != nil {
		return nil, err
	}
	var nonce [aeadNonceLen]byte
	var tag [aeadTagLen]byte
	copy(nonce[:], sb.wrapNonce[:])
	copy(tag[:], sb.wrapTag[:])
	dek := &[KeyBytes]byte{}
	if !aeadOpen(dek[:], sb.wrappedDEK[:], &tag, blockAAD(sb.volumeID, wrapBlockNum),
		&nonce, (*[aeadKeyLen]byte)(kek)) {
		return nil, errCode{"sealed_bad_passphrase", "AEAD unwrap refused"}
	}
	return dek, nil
}

// checkImage is the offline, read-only fsck contract of ADR 0050 D5: it
// validates the superblock pair, scans the journal (reporting live records
// as journal_unreplayed and a torn tail as journal_torn — informational,
// the expected shapes after a kill), then evaluates the as-replayed state
// held in the overlay: inode checksums and kinds, extent bounds and
// overlap, bbitmap consistency, and a single-parent directory tree rooted
// at inode 1 with depth ≤ 8.
//
// On a v2 (sealed) volume the same rules apply through the AEAD layer of
// ADR 0061: pass == nil checks the superblock/seal structure only (the
// ciphertext cannot be read); pass != nil unwraps the DEK — a wrong
// passphrase is sealed_bad_passphrase — and then every read of a
// sealed-span block authenticates first, reporting bad_block_auth with
// the block number. Journal-region reads are the exception: a failed
// open there truncates the journal like a checksum failure, so it
// reports the informational journal_torn.
func checkImage(img []byte, pass []byte) []finding {
	if len(img) < 2*BlockLen || len(img)%SectorLen != 0 {
		return []finding{{"not_vlfs", fmt.Sprintf("image %d bytes", len(img)), false}}
	}

	// Superblock pair: keep the highest-seq valid copy; diagnose the rest.
	var sb *superblock
	var badCopy error
	for slot := uint32(0); slot < 2; slot++ {
		cand, err := parseSuperblock(img, slot)
		if err != nil {
			if badCopy == nil {
				badCopy = err
			}
			continue
		}
		if cand != nil && (sb == nil || cand.seq > sb.seq) {
			sb = cand
		}
	}
	c := &checker{img: img, overlay: map[uint32][]byte{}, referenced: map[uint32]uint32{},
		authBad: map[uint32]bool{}}
	done := func() []finding {
		sort.SliceStable(c.out, func(a, b int) bool { return c.out[a].code < c.out[b].code })
		return c.out
	}
	if sb == nil {
		if badCopy != nil {
			c.fail(badCopy.(errCode).code, "%s", badCopy.(errCode).detail)
		} else {
			c.fail("not_vlfs", "no VLFS magic in either superblock")
		}
		return done()
	}
	if sb.volumeBytes > uint64(len(img)) {
		c.fail("geometry_mismatch", "volume_bytes %d > image %d", sb.volumeBytes, len(img))
		return done()
	}
	if badCopy != nil {
		ec := badCopy.(errCode)
		c.fail(ec.code, "mirror superblock: %s", ec.detail)
	}
	c.g = Geometry{
		VolumeBytes:   sb.volumeBytes,
		VolumeBlocks:  sb.volumeBlocks,
		JournalFirst:  sb.journalFirst,
		JournalBlocks: sb.journalBlocks,
		IbitmapFirst:  sb.ibitmapFirst,
		BbitmapFirst:  sb.bbitmapFirst,
		BbitmapBlocks: sb.bbitmapBlocks,
		ItableFirst:   sb.itableFirst,
		ItableBlocks:  sb.itableBlocks,
		DataFirst:     sb.dataFirst,
		DataBlocks:    sb.dataBlocks,
		InodeCount:    sb.inodeCount,
		TagFirst:      sb.tagFirst,
		TagBlocks:     sb.tagBlocks,
	}

	// Sealed volume: without the passphrase only the plaintext structure
	// can be verified. With it, unwrap the DEK and the whole check runs
	// against authenticated plaintext.
	if sb.version == Version2 {
		c.volID = sb.volumeID
		if pass == nil {
			c.note("sealed", "v2 volume: %d sealed blocks unverified (no passphrase)",
				sb.tagFirst-2)
			return done()
		}
		dek, err := unwrapDEK(sb, pass)
		if err != nil {
			ec := err.(errCode)
			c.fail(ec.code, "%s", ec.detail)
			return done()
		}
		c.dek = dek
	}

	// Journal scan (ADR D5): live transactions overlay in memory, so every
	// later check sees the as-replayed state. The scan stops at the first
	// record that fails; an all-zero DESC is the clean end, anything else
	// is a torn tail.
	pos := c.g.JournalFirst
	end := c.g.JournalFirst + c.g.JournalBlocks
	expected := sb.journalApplied + 1
	var live int
scan:
	for pos < end {
		desc := c.plainJournal(pos)
		if binary.LittleEndian.Uint32(desc[jdMagic:]) != MagicDesc {
			if !isZero(desc) {
				c.note("journal_torn", "non-DESC content at journal block %d", pos)
			}
			break
		}
		n := uint32(binary.LittleEndian.Uint16(desc[jdCount:]))
		if n < 1 || n > MaxPayload || pos+n+2 > end ||
			binary.LittleEndian.Uint64(desc[jdSeq:]) != expected ||
			binary.LittleEndian.Uint16(desc[jdFlags:]) != 0 ||
			binary.LittleEndian.Uint32(desc[jdCksum:]) != fnv1a(desc[:jdCksum]) {
			c.note("journal_torn", "invalid DESC at journal block %d", pos)
			break
		}
		for i := uint32(0); i < n; i++ {
			dest := binary.LittleEndian.Uint32(desc[jdEntries+i*8:])
			if dest < c.g.JournalFirst+c.g.JournalBlocks || dest >= c.g.VolumeBlocks {
				c.note("journal_torn", "DESC dest %d out of range", dest)
				break scan
			}
		}
		var txn []byte
		txn = append(txn, desc[:jdEntries+8*n]...)
		for i := uint32(0); i < n; i++ {
			payload := c.plainJournal(pos + 1 + i)
			if binary.LittleEndian.Uint32(desc[jdEntries+i*8+4:]) != fnv1a(payload) {
				c.note("journal_torn", "payload %d checksum at journal block %d", i, pos)
				break scan
			}
			txn = append(txn, payload...)
		}
		commit := c.plainJournal(pos + 1 + n)
		if binary.LittleEndian.Uint32(commit[jcMagic:]) != MagicCommit ||
			binary.LittleEndian.Uint64(commit[jcSeq:]) != expected ||
			binary.LittleEndian.Uint32(commit[jcTxn:]) != fnv1a(txn) ||
			binary.LittleEndian.Uint32(commit[jcCksum:]) != fnv1a(commit[:jcCksum]) {
			c.note("journal_torn", "invalid COMMIT at journal block %d", pos+1+n)
			break
		}
		for i := uint32(0); i < n; i++ {
			c.overlay[binary.LittleEndian.Uint32(desc[jdEntries+i*8:])] = c.plainJournal(pos + 1 + i)
		}
		expected++
		live++
		pos += n + 2
	}
	if live > 0 {
		c.note("journal_unreplayed", "%d committed transaction(s) pending", live)
	}

	// On a sealed volume authenticate the whole sealed span against the
	// as-replayed view: every block's tag is verified, referenced or not
	// (ADR 0061 — "--check verifies every tag given the passphrase").
	// Overlaid dests hold payload plaintext already authenticated at its
	// journal slot; their stale home pairs are dead bytes the replay owns.
	// A failed open reports bad_block_auth by block number — except in
	// the journal region, where the same failure is the torn tail the
	// guest drops (journal_torn, informational), never a home verdict.
	if c.dek != nil {
		for b := uint32(2); b < c.g.TagFirst; b++ {
			if b < c.g.JournalFirst+c.g.JournalBlocks {
				c.plainJournal(b)
			} else {
				c.plain(b)
			}
		}
	}

	// Inode table: checksums and kind values on every slot, against the
	// as-replayed inode bitmap.
	ibitmap := c.plain(c.g.IbitmapFirst)
	c.inodes = make([][]byte, c.g.InodeCount)
	c.ibUsed = make([]bool, c.g.InodeCount)
	for i := uint32(0); i < c.g.InodeCount; i++ {
		blk := c.plain(c.g.ItableFirst + i/InodesPerBlock)
		rec := blk[uint64(i%InodesPerBlock)*InodeBytes:]
		c.inodes[i] = rec[:InodeBytes]
		c.ibUsed[i] = bitmapGet(ibitmap, i)
		if binary.LittleEndian.Uint32(rec[inCksum:]) != fnv1a(rec[:inCksum]) {
			c.fail("inode_checksum", "inode %d", i)
			continue
		}
		if k := rec[inKind]; k != kindFree && k != kindFile && k != kindDir {
			c.fail("bad_inode", "inode %d kind %d", i, k)
		}
		if i != 0 && c.ibUsed[i] && rec[inKind] == kindFree {
			c.fail("bitmap_inconsistent", "ibitmap bit set for free inode %d", i)
		}
		if !c.ibUsed[i] && rec[inKind] != kindFree {
			c.fail("bitmap_inconsistent", "ibitmap bit clear for live inode %d", i)
		}
	}
	if !c.ibUsed[0] {
		c.fail("bitmap_inconsistent", "inode 0 bit clear")
	}
	if c.inodes[RootInode][inKind] != kindDir {
		c.fail("bad_inode", "root inode 1 kind %d", c.inodes[RootInode][inKind])
	}

	// Extent walk per inode: bounds, cross-file overlap, coverage.
	for i := uint32(0); i < c.g.InodeCount; i++ {
		rec := c.inodes[i]
		if rec[inKind] == kindFree || !c.ibUsed[i] {
			continue
		}
		blocks := c.extentWalk(i, rec)
		size := binary.LittleEndian.Uint32(rec[inSize:])
		if need := (uint64(size) + BlockLen - 1) / BlockLen; uint64(len(blocks)) < need {
			c.fail("extent_out_of_range", "inode %d covers %d blocks, size needs %d", i, len(blocks), need)
		}
	}

	// bbitmap: structural blocks marked; every data-region bit must be
	// explained by exactly one reference (leaks and unmarked use both fail).
	// The map spans BbitmapBlocks blocks, one bit per volume block; index
	// it like the kernel's map_idx and cache the covering block so the
	// scan re-reads it once per bitsPerMapBlock bits, not once per bit.
	var bbitmap []byte
	bbIdx := ^uint32(0)
	dataEnd := c.g.DataFirst + c.g.DataBlocks
	for b := uint32(0); b < c.g.VolumeBlocks; b++ {
		if idx := b / bitsPerMapBlock; idx != bbIdx {
			bbIdx = idx
			bbitmap = c.plain(c.g.BbitmapFirst + idx)
		}
		marked := bitmapGet(bbitmap, b%bitsPerMapBlock)
		owner, used := c.referenced[b]
		switch {
		case b < c.g.DataFirst || b >= dataEnd:
			// Structural: superblocks/journal/bitmaps/itable, and on v2
			// the tag region.
			if !marked {
				c.fail("bitmap_inconsistent", "structural block %d unmarked", b)
			}
		case used != marked:
			if used {
				c.fail("bitmap_inconsistent", "block %d used by inode %d but unmarked", b, owner)
			} else {
				c.fail("bitmap_inconsistent", "block %d marked but unreferenced", b)
			}
		}
	}

	// Directory tree from the root: dirent validity, single parentage,
	// depth bound, then orphan accounting over the reachable set.
	seen := make([]bool, c.g.InodeCount)
	var walkDir func(ino uint32, depth int)
	walkDir = func(ino uint32, depth int) {
		if depth > MaxDepth {
			c.fail("depth_overflow", "below inode %d", ino)
			return
		}
		rec := c.inodes[ino]
		size := binary.LittleEndian.Uint32(rec[inSize:])
		var dirents []byte
		for _, b := range c.inodeBlocks(rec) {
			dirents = append(dirents, c.plain(b)...)
		}
		slots := int(uint64(size) / DirentBytes)
		if slots > len(dirents)/DirentBytes {
			slots = len(dirents) / DirentBytes
		}
		live := 0
		for s := 0; s < slots; s++ {
			de := dirents[s*DirentBytes:]
			target := binary.LittleEndian.Uint32(de[deInode:])
			if target == 0 {
				continue // tombstone
			}
			live++
			nl := binary.LittleEndian.Uint16(de[deNameLen:])
			if nl == 0 || nl > MaxName {
				c.fail("dirent_bad", "inode %d slot %d name_len %d", ino, s, nl)
				continue
			}
			name := de[deName : deName+nl]
			if bytes.IndexByte(name, '/') >= 0 || bytes.IndexByte(name, 0) >= 0 ||
				string(name) == "." || string(name) == ".." {
				c.fail("dirent_bad", "inode %d slot %d name %q", ino, s, name)
				continue
			}
			if binary.LittleEndian.Uint64(de[deReserved:]) != 0 || de[deFlags] != 0 {
				c.fail("dirent_bad", "inode %d slot %d flags/reserved nonzero", ino, s)
				continue
			}
			if target >= c.g.InodeCount || !c.ibUsed[target] {
				c.fail("dirent_bad", "inode %d slot %d -> free/absent inode %d", ino, s, target)
				continue
			}
			if k := de[deKind]; int(k) != int(c.inodes[target][inKind]) || (k != kindFile && k != kindDir) {
				c.fail("dirent_bad", "inode %d slot %d kind %d vs inode %d kind %d", ino, s, k, target, c.inodes[target][inKind])
				continue
			}
			if target == RootInode || seen[target] {
				c.fail("dirent_bad", "inode %d linked more than once", target)
				continue
			}
			seen[target] = true
			if c.inodes[target][inKind] == kindDir {
				walkDir(target, depth+1)
			}
		}
		if live > MaxDirents {
			c.fail("dirent_bad", "inode %d holds %d live dirents (max %d)", ino, live, MaxDirents)
		}
	}
	if c.inodes[RootInode][inKind] == kindDir {
		seen[RootInode] = true
		walkDir(RootInode, 1)
	}
	for i := uint32(2); i < c.g.InodeCount; i++ {
		if c.ibUsed[i] && c.inodes[i][inKind] != kindFree && !seen[i] {
			c.fail("inode_orphan", "inode %d allocated but unreachable", i)
		}
	}

	return done()
}

// dataEnd is the first block past the data region: volume_blocks on v1,
// tag_first on v2 — the bound file extents must stay under.
func (c *checker) dataEnd() uint32 {
	return c.g.DataFirst + c.g.DataBlocks
}

// inodeBlocks collects an inode's file-block sequence without marking or
// reporting — pass one (extentWalk) already diagnosed it, so the directory
// walk only needs the payload addresses.
func (c *checker) inodeBlocks(rec []byte) []uint32 {
	var out []uint32
	one := func(first, count uint32) {
		for b := first; b < first+count && b >= c.g.DataFirst && b < c.dataEnd(); b++ {
			out = append(out, b)
		}
	}
	next := binary.LittleEndian.Uint16(rec[inNextents:])
	for e := 0; e < int(next) && e < InlineExtents; e++ {
		one(binary.LittleEndian.Uint32(rec[inExtents+e*8:]),
			binary.LittleEndian.Uint32(rec[inExtents+e*8+4:]))
	}
	chain := binary.LittleEndian.Uint32(rec[inNextExt:])
	for depth := 0; chain != 0 && depth < MaxExtentBlocks; depth++ {
		if chain < c.g.DataFirst || chain >= c.dataEnd() {
			break
		}
		blk := c.plain(chain)
		if binary.LittleEndian.Uint32(blk[xbMagic:]) != MagicExtent ||
			binary.LittleEndian.Uint32(blk[xbCksum:]) != fnv1a(blk[:xbCksum]) {
			break
		}
		cnt := binary.LittleEndian.Uint16(blk[xbCount:])
		for e := 0; e < int(cnt) && e < ExtentsPerBlock; e++ {
			one(binary.LittleEndian.Uint32(blk[xbExtents+e*8:]),
				binary.LittleEndian.Uint32(blk[xbExtents+e*8+4:]))
		}
		chain = binary.LittleEndian.Uint32(blk[xbNext:])
	}
	return out
}

func isZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}
