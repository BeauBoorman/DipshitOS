package main

// The GPT + FAT32 image writer (M112c, issue #2415): a Go port of
// image/mkfat32.py's create path, producing the same deterministic layout —
// LBA 0 protective MBR, GPT header at LBA 1 with entries at LBA 2..33 and
// the backup pair at the end, and one ESP FAT32 volume at LBA 2048 holding
// EFI/BOOT/BOOTAA64.EFI and KERNEL.BIN.
//
// Two differences from the Python original, both forced by the channel the
// bytes travel:
//
//   - The image is STREAMED through a seqSink instead of built as one
//     in-memory image: the guest's os.File write path stages everything in
//     a 16 MiB shadow (overlay/syscall/fs_virelai.go virShadowMax) and a
//     ~34 MiB image cannot fit it.
//   - The zero regions (LBA 34..2047 and the volume tail) are emitted as
//     ZeroPad calls, which the guest sink resolves with a truncate-extend
//     plus an append-open — the host file table extends with zeros and an
//     append handle's cursor starts at EOF (VFWire FileHandleTable). The
//     bytes on disk are identical either way.
//
// Sector writes are asserted in order against the running position: a port
// bug lands as a named error, never a silently misaligned image.

import (
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"unicode/utf16"
)

const (
	sectorBytes = 512
	espLBA      = 2048 // volume base (hidden_sectors)
	fatEOC      = 0x0FFFFFFF

	volumeLabel = "VIRELAIOS  "
	partName    = "EFI SYSTEM"
)

// Fixed GUIDs, byte-identical to mkfat32.py so the same inputs produce the
// same image. The disk and partition GUIDs are constants by design — the
// reference builder is deterministic and so is this one.
var (
	espGUID = [16]byte{0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
		0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B}
	diskGUID = [16]byte{0x44, 0x49, 0x50, 0x53, 0x48, 0x49, 0x54, 0x4F,
		0x53, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31}
	partGUID = [16]byte{0x44, 0x49, 0x50, 0x53, 0x48, 0x49, 0x54, 0x4F,
		0x53, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x32}
)

// seqSink is the write side of the image builder: strictly sequential bytes
// plus a zero-fill fast-forward. The guest implementation rides vi's file
// slots; the host one is an *os.File (tests and the dev loop).
type seqSink interface {
	// Write appends b at the current position.
	Write(b []byte) (int, error)
	// ZeroPad extends the stream with zeros so the position becomes `to`;
	// to < pos is an error.
	ZeroPad(to uint64) error
	// Close flushes and releases the underlying handle.
	Close() error
}

// fatGeometry is Fat32Geometry: one volume's layout from its sector count.
type fatGeometry struct {
	baseLBA      uint64
	totalSectors uint64
	reserved     uint64
	nfats        uint64
	fatSectors   uint64
	clusters     uint64
	dataStart    uint64 // volume-relative sector of cluster 2
	rootCluster  uint64
}

func newFatGeometry(volumeSectors, baseLBA uint64) fatGeometry {
	g := fatGeometry{
		baseLBA:      baseLBA,
		totalSectors: volumeSectors,
		reserved:     32,
		nfats:        2,
		rootCluster:  2,
	}
	// Fixed-point iteration for sectors-per-FAT (4 bytes/entry over
	// 512-byte sectors), identical to the Python loop.
	fatSectors := uint64(1)
	for {
		clusters := volumeSectors - g.reserved - g.nfats*fatSectors
		need := (clusters*4 + sectorBytes - 1) / sectorBytes
		if need == fatSectors {
			break
		}
		fatSectors = need
	}
	g.fatSectors = fatSectors
	g.clusters = volumeSectors - g.reserved - g.nfats*fatSectors
	g.dataStart = g.reserved + g.nfats*g.fatSectors
	return g
}

func (g fatGeometry) check() error {
	if g.clusters <= 65525 {
		return fmt.Errorf("FAT32 requires > 65525 clusters (got %d); increase image size", g.clusters)
	}
	if g.totalSectors > 0xFFFFFFFF {
		return fmt.Errorf("volume too large for FAT32 (max 2 TiB)")
	}
	return nil
}

// minimumVolumeSectors is the smallest volume whose geometry passes the
// FAT32 cluster floor — the same 66000 + 512-step search as the reference.
func minimumVolumeSectors() uint64 {
	v := uint64(66000)
	for {
		if newFatGeometry(v, 0).clusters > 65525 {
			return v
		}
		v += sectorBytes
	}
}

func protectiveMBR(totalSectors uint64) []byte {
	mbr := make([]byte, sectorBytes)
	size := totalSectors - 1
	if size > 0xFFFFFFFF {
		size = 0xFFFFFFFF
	}
	// Partition entry 0 at offset 446 ("<B3sB3sII"): boot flag 0, start CHS
	// zeros, type 0xEE (protective), end CHS 0xff, LBA start 1, size.
	mbr[446] = 0x00
	mbr[450] = 0xEE
	copy(mbr[451:454], []byte{0xFF, 0xFF, 0xFF})
	binary.LittleEndian.PutUint32(mbr[454:458], 1)
	binary.LittleEndian.PutUint32(mbr[458:462], uint32(size))
	mbr[510], mbr[511] = 0x55, 0xAA
	return mbr
}

func gptHeader(currentLBA, backupLBA, firstUsable, lastUsable, entriesLBA, entriesCRC uint64) []byte {
	hdr := make([]byte, 92)
	copy(hdr[0:8], "EFI PART")
	binary.LittleEndian.PutUint32(hdr[8:12], 0x00010000)
	binary.LittleEndian.PutUint32(hdr[12:16], 92)
	binary.LittleEndian.PutUint32(hdr[20:24], 0)
	binary.LittleEndian.PutUint64(hdr[24:32], currentLBA)
	binary.LittleEndian.PutUint64(hdr[32:40], backupLBA)
	binary.LittleEndian.PutUint64(hdr[40:48], firstUsable)
	binary.LittleEndian.PutUint64(hdr[48:56], lastUsable)
	copy(hdr[56:72], diskGUID[:])
	binary.LittleEndian.PutUint64(hdr[72:80], entriesLBA)
	binary.LittleEndian.PutUint32(hdr[80:84], 128)
	binary.LittleEndian.PutUint32(hdr[84:88], 128)
	binary.LittleEndian.PutUint32(hdr[88:92], uint32(entriesCRC))
	crc := crc32.ChecksumIEEE(hdr)
	binary.LittleEndian.PutUint32(hdr[16:20], crc)
	return hdr
}

func partitionEntry(typeGUID, uniqueGUID [16]byte, firstLBA, lastLBA uint64, name string) []byte {
	e := make([]byte, 128)
	copy(e[0:16], typeGUID[:])
	copy(e[16:32], uniqueGUID[:])
	binary.LittleEndian.PutUint64(e[32:40], firstLBA)
	binary.LittleEndian.PutUint64(e[40:48], lastLBA)
	enc := utf16.Encode([]rune(name))
	for i, u := range enc {
		binary.LittleEndian.PutUint16(e[56+i*2:], u)
	}
	return e
}

func bootSector(g fatGeometry) []byte {
	b := make([]byte, sectorBytes)
	copy(b[0:3], []byte{0xEB, 0x58, 0x90})
	copy(b[3:11], "MSDOS5.0")
	binary.LittleEndian.PutUint16(b[11:13], sectorBytes)
	b[13] = 1 // sectors per cluster
	binary.LittleEndian.PutUint16(b[14:16], uint16(g.reserved))
	b[16] = byte(g.nfats)
	binary.LittleEndian.PutUint16(b[17:19], 0)
	binary.LittleEndian.PutUint16(b[19:21], 0)
	b[21] = 0xF8
	binary.LittleEndian.PutUint16(b[22:24], 0)
	binary.LittleEndian.PutUint16(b[24:26], 32)
	binary.LittleEndian.PutUint16(b[26:28], 64)
	binary.LittleEndian.PutUint32(b[28:32], uint32(g.baseLBA))
	binary.LittleEndian.PutUint32(b[32:36], uint32(g.totalSectors))
	binary.LittleEndian.PutUint32(b[36:40], uint32(g.fatSectors))
	binary.LittleEndian.PutUint16(b[40:42], 0)
	binary.LittleEndian.PutUint16(b[42:44], 0)
	binary.LittleEndian.PutUint32(b[44:48], uint32(g.rootCluster))
	binary.LittleEndian.PutUint16(b[48:50], 1)
	binary.LittleEndian.PutUint16(b[50:52], 6)
	b[64] = 0x80
	b[66] = 0x29
	binary.LittleEndian.PutUint32(b[67:71], 0x44495031)
	copy(b[71:82], volumeLabel)
	copy(b[82:90], "FAT32   ")
	b[510], b[511] = 0x55, 0xAA
	return b
}

func fsInfoSector() []byte {
	fi := make([]byte, sectorBytes)
	binary.LittleEndian.PutUint32(fi[0:4], 0x41615252)
	binary.LittleEndian.PutUint32(fi[4:8], 0x61417272)
	binary.LittleEndian.PutUint32(fi[8:12], 0xFFFFFFFF)
	binary.LittleEndian.PutUint32(fi[12:16], 0xFFFFFFFF)
	binary.LittleEndian.PutUint32(fi[508:512], 0xAA550000)
	return fi
}

func dirEntry(name11 string, attr byte, cluster uint64, size uint32) []byte {
	if len(name11) != 11 {
		panic("8.3 name must be exactly 11 bytes")
	}
	e := make([]byte, 32)
	copy(e[0:11], name11)
	e[11] = attr
	binary.LittleEndian.PutUint16(e[20:22], uint16(cluster>>16))
	binary.LittleEndian.PutUint16(e[26:28], uint16(cluster))
	binary.LittleEndian.PutUint32(e[28:32], size)
	return e
}

// imageWriter emits the disk image through a seqSink, checking that every
// region lands at the offset the layout says it must.
type imageWriter struct {
	s   seqSink
	pos uint64 // stream position in bytes
}

func (w *imageWriter) write(b []byte) error {
	n, err := w.s.Write(b)
	w.pos += uint64(n)
	if err != nil {
		return err
	}
	if n != len(b) {
		return fmt.Errorf("short write %d of %d", n, len(b))
	}
	return nil
}

func (w *imageWriter) writeSector(b []byte) error {
	if len(b) > sectorBytes {
		return fmt.Errorf("sector payload %d > %d", len(b), sectorBytes)
	}
	pad := make([]byte, sectorBytes)
	copy(pad, b)
	return w.write(pad)
}

// pad zero-fills the stream up to absolute byte offset `to`.
func (w *imageWriter) pad(to uint64) error {
	if to < w.pos {
		return fmt.Errorf("pad target %d behind position %d", to, w.pos)
	}
	if err := w.s.ZeroPad(to); err != nil {
		return err
	}
	w.pos = to
	return nil
}

// writeImage builds the whole disk image: protective MBR, primary GPT,
// the FAT32 ESP with the two boot files, then the backup GPT. sizeMB 0
// means the FAT32 cluster-count floor, matching mkfat32.py's default.
func writeImage(s seqSink, efi, kernel []byte, sizeMB uint64) (uint64, error) {
	var totalSectors uint64
	if sizeMB > 0 {
		totalSectors = sizeMB * 1024 * 1024 / sectorBytes
	} else {
		totalSectors = espLBA + minimumVolumeSectors()
	}
	volumeSectors := totalSectors - espLBA
	geo := newFatGeometry(volumeSectors, espLBA)
	if err := geo.check(); err != nil {
		return 0, err
	}

	efiClusters := uint64((len(efi) + sectorBytes - 1) / sectorBytes)
	kernelClusters := uint64((len(kernel) + sectorBytes - 1) / sectorBytes)

	// Cluster plan identical to build_fat32_image: 2=root, then EFI dir,
	// BOOT dir, BOOTAA64.EFI data, KERNEL.BIN data, in order.
	const rootEntries = 3
	rootClusters := uint64((rootEntries*32 + sectorBytes - 1) / sectorBytes)
	efiDirCluster := 2 + rootClusters
	bootDirCluster := efiDirCluster + 1
	efiStart := bootDirCluster + 1
	kernelStart := efiStart + efiClusters
	allocated := kernelStart + kernelClusters - 2
	if allocated > geo.clusters {
		return 0, fmt.Errorf("boot files need %d clusters but the volume has only %d",
			allocated, geo.clusters)
	}

	fat := make([]uint32, geo.clusters+2)
	fat[0] = 0x0FFFFFF8
	fat[1] = fatEOC
	chain := func(start, count uint64) {
		for i := uint64(0); i < count; i++ {
			if i < count-1 {
				fat[start+i] = uint32(start + i + 1)
			} else {
				fat[start+i] = fatEOC
			}
		}
	}
	chain(2, rootClusters)
	chain(efiDirCluster, 1)
	chain(bootDirCluster, 1)
	chain(efiStart, efiClusters)
	chain(kernelStart, kernelClusters)

	// The GPT layout: header at LBA 1, 128x128 entries at LBA 2..33,
	// backup entries at total-33..total-2, backup header at total-1.
	firstUsable := uint64(34)
	lastUsable := totalSectors - 34
	entriesLBA := uint64(2)
	backupEntriesLBA := lastUsable + 1
	entries := make([]byte, 128*128)
	copy(entries[0:128], partitionEntry(espGUID, partGUID, espLBA, lastUsable, partName))
	entriesCRC := uint64(crc32.ChecksumIEEE(entries))

	w := &imageWriter{s: s}
	write := func(b []byte, what string) error {
		if err := w.write(b); err != nil {
			return fmt.Errorf("%s: %w", what, err)
		}
		return nil
	}
	sector := func(b []byte, what string) error {
		if err := w.writeSector(b); err != nil {
			return fmt.Errorf("%s: %w", what, err)
		}
		return nil
	}
	pad := func(to uint64, what string) error {
		if err := w.pad(to); err != nil {
			return fmt.Errorf("%s: %w", what, err)
		}
		return nil
	}

	if err := sector(protectiveMBR(totalSectors), "mbr"); err != nil {
		return 0, err
	}
	if err := sector(gptHeader(1, totalSectors-1, firstUsable, lastUsable,
		entriesLBA, entriesCRC), "gpt header"); err != nil {
		return 0, err
	}
	if err := write(entries, "gpt entries"); err != nil {
		return 0, err
	}
	if err := pad(espLBA*sectorBytes, "pre-volume gap"); err != nil {
		return 0, err
	}

	// --- the FAT32 volume ---------------------------------------------
	bs := bootSector(geo)
	if err := sector(bs, "boot sector"); err != nil {
		return 0, err
	}
	if err := sector(fsInfoSector(), "fsinfo"); err != nil {
		return 0, err
	}
	if err := pad((espLBA+6)*sectorBytes, "reserved gap"); err != nil {
		return 0, err
	}
	if err := sector(bs, "backup boot sector"); err != nil {
		return 0, err
	}
	if err := sector(fsInfoSector(), "backup fsinfo"); err != nil {
		return 0, err
	}
	if err := pad((espLBA+geo.reserved)*sectorBytes, "reserved tail"); err != nil {
		return 0, err
	}

	fatBytes := make([]byte, geo.fatSectors*sectorBytes)
	for i, e := range fat {
		binary.LittleEndian.PutUint32(fatBytes[i*4:], e)
	}
	for i := uint64(0); i < geo.nfats; i++ {
		if err := write(fatBytes, "fat copy"); err != nil {
			return 0, err
		}
	}

	// Directory tree + file data, in cluster order.
	rootDir := make([]byte, rootClusters*sectorBytes)
	off := 0
	put := func(d []byte) { copy(rootDir[off:], d); off += 32 }
	put(dirEntry(volumeLabel, 0x08, 0, 0))
	put(dirEntry("EFI        ", 0x10, efiDirCluster, 0))
	put(dirEntry("KERNEL  BIN", 0x20, kernelStart, uint32(len(kernel))))
	if err := write(rootDir, "root dir"); err != nil {
		return 0, err
	}

	efiDir := make([]byte, sectorBytes)
	off = 0
	put2 := func(d []byte) { copy(efiDir[off:], d); off += 32 }
	put2(dirEntry(".          ", 0x10, efiDirCluster, 0))
	put2(dirEntry("..         ", 0x10, 2, 0))
	put2(dirEntry("BOOT       ", 0x10, bootDirCluster, 0))
	if err := write(efiDir, "efi dir"); err != nil {
		return 0, err
	}

	bootDir := make([]byte, sectorBytes)
	off = 0
	put3 := func(d []byte) { copy(bootDir[off:], d); off += 32 }
	put3(dirEntry(".          ", 0x10, bootDirCluster, 0))
	put3(dirEntry("..         ", 0x10, efiDirCluster, 0))
	put3(dirEntry("BOOTAA64EFI", 0x20, efiStart, uint32(len(efi))))
	if err := write(bootDir, "boot dir"); err != nil {
		return 0, err
	}

	// cluster_sector(c) = base + dataStart + (c - rootCluster); file data
	// regions are padded to their full cluster span, like the reference's
	// per-sector ljust.
	if err := write(efi, "BOOTAA64.EFI data"); err != nil {
		return 0, err
	}
	efiDataEnd := (espLBA + geo.dataStart + (efiStart - geo.rootCluster) + efiClusters) * sectorBytes
	if err := pad(efiDataEnd, "efi tail"); err != nil {
		return 0, err
	}
	if err := write(kernel, "KERNEL.BIN data"); err != nil {
		return 0, err
	}
	kernelDataEnd := (espLBA + geo.dataStart + (kernelStart - geo.rootCluster) + kernelClusters) * sectorBytes
	if err := pad(kernelDataEnd, "kernel tail"); err != nil {
		return 0, err
	}

	// --- the backup GPT at the image tail --------------------------------
	if err := pad(backupEntriesLBA*sectorBytes, "volume tail"); err != nil {
		return 0, err
	}
	if err := write(entries, "backup gpt entries"); err != nil {
		return 0, err
	}
	if err := sector(gptHeader(totalSectors-1, 1, firstUsable, lastUsable,
		backupEntriesLBA, entriesCRC), "backup gpt header"); err != nil {
		return 0, err
	}

	if w.pos != totalSectors*sectorBytes {
		return 0, fmt.Errorf("image ended at %d bytes, want %d", w.pos, totalSectors*sectorBytes)
	}
	return w.pos, nil
}
