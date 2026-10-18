package fatimg

// The listing half of the writer's contract: read back a file the image
// carries. ReadFile(img, "KERNEL.BIN") and ReadFile(img,
// "EFI/BOOT/BOOTAA64.EFI") cover the two paths WriteImage emits; anything
// else is a named error, never a guess. Exists so the writer's consumers
// (release end-to-end tests, the update stager's self-check) verify the
// produced image without re-deriving the layout.

import (
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"strings"
)

// espEntry is one located 8.3 directory entry.
type espEntry struct {
	cluster uint64
	size    uint32
	dir     bool
}

// espVolume is a mounted view of the image's FAT32 ESP.
type espVolume struct {
	img       []byte
	dataStart uint64 // byte offset of cluster-2 data
	spc       uint64
	fat       []uint32
	rootClus  uint64
}

// mountESP parses the GPT + the ESP's boot sector and FAT.
func mountESP(img []byte) (*espVolume, error) {
	if len(img) < (espLBA+1)*sectorBytes {
		return nil, fmt.Errorf("image too small (%d bytes)", len(img))
	}
	if string(img[sectorBytes:sectorBytes+8]) != "EFI PART" {
		return nil, fmt.Errorf("no GPT signature at LBA 1")
	}
	crc := binary.LittleEndian.Uint32(img[sectorBytes+16:])
	var hdr [92]byte
	copy(hdr[:], img[sectorBytes:sectorBytes+92])
	binary.LittleEndian.PutUint32(hdr[16:], 0)
	if crc32.ChecksumIEEE(hdr[:]) != crc {
		return nil, fmt.Errorf("GPT header crc mismatch")
	}
	entriesLBA := binary.LittleEndian.Uint64(img[sectorBytes+72:])
	var first uint64
	found := false
	for i := 0; i < 128; i++ {
		e := img[entriesLBA*sectorBytes+uint64(i)*128:]
		if len(e) < 128 {
			return nil, fmt.Errorf("GPT entries truncated")
		}
		if string(e[0:16]) == string(espGUID[:]) {
			first = binary.LittleEndian.Uint64(e[32:40])
			found = true
			break
		}
	}
	if !found {
		return nil, fmt.Errorf("no ESP partition entry")
	}
	base := first * sectorBytes
	v := &espVolume{img: img, spc: uint64(img[base+13])}
	if img[base+510] != 0x55 || img[base+511] != 0xAA {
		return nil, fmt.Errorf("no FAT boot signature")
	}
	if string(img[base+82:base+90]) != "FAT32   " {
		return nil, fmt.Errorf("no FAT32 label")
	}
	reserved := uint64(binary.LittleEndian.Uint16(img[base+14:]))
	fatSects := uint64(binary.LittleEndian.Uint32(img[base+36:]))
	v.rootClus = uint64(binary.LittleEndian.Uint32(img[base+44:]))
	v.dataStart = (first + reserved + 2*fatSects) * sectorBytes
	n := int(fatSects * sectorBytes / 4)
	v.fat = make([]uint32, n)
	fatBase := (first + reserved) * sectorBytes
	for i := range v.fat {
		v.fat[i] = binary.LittleEndian.Uint32(img[fatBase+uint64(i)*4:])
	}
	return v, nil
}

func (v *espVolume) chain(start uint64) []uint64 {
	var out []uint64
	for c := start; c != fatEOC && c != 0 && c != 0x0FFFFFF7; {
		if int(c) >= len(v.fat) {
			break
		}
		out = append(out, c)
		c = uint64(v.fat[c] & 0x0FFFFFFF)
	}
	return out
}

// decode83 renders one raw 8.3 entry name as NAME.EXT.
func decode83(e []byte) string {
	name := strings.TrimRight(string(e[0:8]), " ")
	ext := strings.TrimRight(string(e[8:11]), " ")
	if ext != "" {
		return name + "." + ext
	}
	return name
}

// readDir lists one directory cluster chain: name -> entry.
func (v *espVolume) readDir(cluster uint64) map[string]espEntry {
	out := map[string]espEntry{}
	for _, c := range v.chain(cluster) {
		sec := v.dataStart + (c-v.rootClus)*v.spc*sectorBytes
		for i := 0; i < 16; i++ {
			e := v.img[sec+uint64(i)*32:]
			if len(e) < 32 || e[0] == 0 {
				return out
			}
			if e[0] == 0xE5 || e[11]&0x08 != 0 {
				continue
			}
			out[decode83(e)] = espEntry{
				cluster: uint64(binary.LittleEndian.Uint16(e[20:22]))<<16 |
					uint64(binary.LittleEndian.Uint16(e[26:28])),
				size: binary.LittleEndian.Uint32(e[28:32]),
				dir:  e[11]&0x10 != 0,
			}
		}
	}
	return out
}

// ReadFile returns the bytes of `path` inside the image's ESP, where path
// is a "/" or "\"-separated 8.3 name ("KERNEL.BIN", "EFI/BOOT/BOOTAA64.EFI").
func ReadFile(img []byte, path string) ([]byte, error) {
	v, err := mountESP(img)
	if err != nil {
		return nil, err
	}
	parts := strings.FieldsFunc(path, func(r rune) bool { return r == '/' || r == '\\' })
	if len(parts) == 0 {
		return nil, fmt.Errorf("empty path")
	}
	dir := v.readDir(v.rootClus)
	var ent espEntry
	for i, p := range parts {
		p = strings.ToUpper(p)
		e, ok := dir[p]
		if !ok {
			return nil, fmt.Errorf("%s: not found in ESP", path)
		}
		if i == len(parts)-1 {
			if e.dir {
				return nil, fmt.Errorf("%s: is a directory", path)
			}
			ent = e
			continue
		}
		if !e.dir {
			return nil, fmt.Errorf("%s: %s is not a directory", path, p)
		}
		dir = v.readDir(e.cluster)
	}
	var out []byte
	for _, c := range v.chain(ent.cluster) {
		sec := v.dataStart + (c-v.rootClus)*v.spc*sectorBytes
		end := sec + v.spc*sectorBytes
		if end > uint64(len(img)) {
			return nil, fmt.Errorf("%s: cluster chain overruns image", path)
		}
		out = append(out, img[sec:end]...)
	}
	if uint64(len(out)) < uint64(ent.size) {
		return nil, fmt.Errorf("%s: short chain", path)
	}
	return out[:ent.size], nil
}
