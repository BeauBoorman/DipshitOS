package fatimg

// Host tests for the image writer: structure, determinism, and byte-parity
// against image/mkfat32.py on synthetic inputs. The same parity compare on
// real inputs runs in-guest in the live-release spec.

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func execLookPath() (string, error) { return exec.LookPath("python3") }

func runPy(script string, args ...string) ([]byte, error) {
	argv := append([]string{script}, args...)
	return exec.Command("python3", argv...).CombinedOutput()
}

// memSink is an in-memory seqSink for the writer tests.
type memSink struct {
	buf []byte
}

func (m *memSink) Write(b []byte) (int, error) {
	m.buf = append(m.buf, b...)
	return len(b), nil
}

func (m *memSink) ZeroPad(to uint64) error {
	for uint64(len(m.buf)) < to {
		m.buf = append(m.buf, 0)
	}
	return nil
}

func (m *memSink) Close() error { return nil }

func TestMinimumVolumeSectors(t *testing.T) {
	v := minimumVolumeSectors()
	if newFatGeometry(v, 0).clusters <= 65525 {
		t.Fatalf("floor volume %d has %d clusters, want > 65525", v,
			newFatGeometry(v, 0).clusters)
	}
	// And the previous step must fail the floor — the floor is minimal.
	if newFatGeometry(v-sectorBytes, 0).clusters > 65525 {
		t.Fatalf("volume %d below the floor still passes", v-sectorBytes)
	}
}

func TestProtectiveMBR(t *testing.T) {
	mbr := protectiveMBR(100000)
	if mbr[510] != 0x55 || mbr[511] != 0xAA {
		t.Fatal("MBR signature missing")
	}
	if mbr[446] != 0 || mbr[450] != 0xEE {
		t.Fatalf("protective entry malformed: %x", mbr[446:462])
	}
	if got := binary.LittleEndian.Uint32(mbr[454:458]); got != 1 {
		t.Fatalf("protective LBA start = %d, want 1", got)
	}
	if got := binary.LittleEndian.Uint32(mbr[458:462]); got != 99999 {
		t.Fatalf("protective size = %d, want 99999", got)
	}
}

// imgReader is a tiny GPT+FAT32 reader for the tests — the listing half of
// mkfat32.py's contract, in miniature.
type imgReader struct {
	data      []byte
	firstLBA  uint64
	reserved  uint64
	fatSects  uint64
	rootClus  uint64
	spc       uint64
	dataStart uint64
	fat       []uint32
}

func readImage(t *testing.T, img []byte) *imgReader {
	t.Helper()
	if string(img[512:520]) != "EFI PART" {
		t.Fatal("no GPT signature at LBA 1")
	}
	crc := binary.LittleEndian.Uint32(img[512+16:])
	binary.LittleEndian.PutUint32(img[512+16:], 0)
	if crc32.ChecksumIEEE(img[512:512+92]) != crc {
		t.Fatal("GPT header crc mismatch")
	}
	entriesLBA := binary.LittleEndian.Uint64(img[512+72:])
	var first uint64
	found := false
	for i := 0; i < 128; i++ {
		e := img[entriesLBA*512+uint64(i)*128:]
		if bytes.Equal(e[0:16], espGUID[:]) {
			first = binary.LittleEndian.Uint64(e[32:40])
			found = true
			break
		}
	}
	if !found {
		t.Fatal("no ESP partition entry")
	}
	r := &imgReader{data: img, firstLBA: first}
	base := first * 512
	if img[base+510] != 0x55 || img[base+511] != 0xAA {
		t.Fatal("no FAT boot signature")
	}
	if string(img[base+82:base+90]) != "FAT32   " {
		t.Fatal("no FAT32 label")
	}
	r.reserved = uint64(binary.LittleEndian.Uint16(img[base+14:]))
	r.fatSects = uint64(binary.LittleEndian.Uint32(img[base+36:]))
	r.rootClus = uint64(binary.LittleEndian.Uint32(img[base+44:]))
	r.spc = uint64(img[base+13])
	if got := binary.LittleEndian.Uint32(img[base+28:]); got != uint32(first) {
		t.Fatalf("hidden sectors = %d, want %d", got, first)
	}
	r.dataStart = first + r.reserved + 2*r.fatSects
	n := int(r.fatSects * 512 / 4)
	r.fat = make([]uint32, n)
	fatBase := (first + r.reserved) * 512
	for i := range r.fat {
		r.fat[i] = binary.LittleEndian.Uint32(img[fatBase+uint64(i)*4:])
	}
	return r
}

func (r *imgReader) clusterSector(c uint64) uint64 {
	return r.dataStart + (c-r.rootClus)*r.spc
}

func (r *imgReader) chain(start uint64) []uint64 {
	var out []uint64
	c := start
	for c != fatEOC && c != 0 && c != 0x0FFFFFF7 {
		out = append(out, c)
		c = uint64(r.fat[c] & 0x0FFFFFFF)
	}
	return out
}

func (r *imgReader) readDir(cluster uint64) map[string][2]uint64 {
	out := map[string][2]uint64{}
	for _, c := range r.chain(cluster) {
		sec := r.clusterSector(c)
		for i := 0; i < 16; i++ {
			e := r.data[sec*512+uint64(i)*32:]
			if e[0] == 0 {
				return out
			}
			if e[0] == 0xE5 || e[11]&0x08 != 0 {
				continue
			}
			name := decode83(e)
			cl := uint64(binary.LittleEndian.Uint16(e[20:22]))<<16 |
				uint64(binary.LittleEndian.Uint16(e[26:28]))
			size := uint64(binary.LittleEndian.Uint32(e[28:32]))
			out[name] = [2]uint64{cl, size}
		}
	}
	return out
}

func (r *imgReader) readFile(cluster, size uint64) []byte {
	var out []byte
	for _, c := range r.chain(cluster) {
		sec := r.clusterSector(c)
		out = append(out, r.data[sec*512:(sec+r.spc)*512]...)
	}
	return out[:size]
}

func TestWriteImageStructure(t *testing.T) {
	efi := bytes.Repeat([]byte{0xAB}, 1500)
	kernel := bytes.Repeat([]byte{0xCD}, 3000)
	var s memSink
	total, err := WriteImage(&s, efi, kernel, 0)
	if err != nil {
		t.Fatalf("writeImage: %v", err)
	}
	if uint64(len(s.buf)) != total {
		t.Fatalf("streamed %d bytes, writer reported %d", len(s.buf), total)
	}
	img := s.buf
	totalSectors := uint64(len(img)) / 512
	if totalSectors <= espLBA+66000 {
		t.Fatalf("image too small: %d sectors", totalSectors)
	}

	r := readImage(t, img)
	if r.firstLBA != espLBA {
		t.Fatalf("ESP at LBA %d, want %d", r.firstLBA, espLBA)
	}
	root := r.readDir(r.rootClus)
	efiEnt, ok := root["EFI"]
	if !ok {
		t.Fatal("root has no EFI dir")
	}
	kernEnt, ok := root["KERNEL.BIN"]
	if !ok || kernEnt[1] != uint64(len(kernel)) {
		t.Fatalf("root KERNEL.BIN entry wrong: %v", kernEnt)
	}
	efiDir := r.readDir(efiEnt[0])
	bootEnt, ok := efiDir["BOOT"]
	if !ok {
		t.Fatal("EFI has no BOOT dir")
	}
	bootDir := r.readDir(bootEnt[0])
	appEnt, ok := bootDir["BOOTAA64.EFI"]
	if !ok || appEnt[1] != uint64(len(efi)) {
		t.Fatalf("BOOTAA64.EFI entry wrong: %v", appEnt)
	}
	if !bytes.Equal(r.readFile(appEnt[0], appEnt[1]), efi) {
		t.Fatal("BOOTAA64.EFI content mismatch")
	}
	if !bytes.Equal(r.readFile(kernEnt[0], kernEnt[1]), kernel) {
		t.Fatal("KERNEL.BIN content mismatch")
	}

	// Backup GPT: entries at total-33, header at total-1.
	bh := img[(totalSectors-1)*512:]
	if string(bh[0:8]) != "EFI PART" {
		t.Fatal("no backup GPT signature")
	}
	if binary.LittleEndian.Uint64(bh[24:32]) != totalSectors-1 {
		t.Fatal("backup header current_lba wrong")
	}
	be := img[(totalSectors-33)*512:]
	if !bytes.Equal(be[0:16], espGUID[:]) {
		t.Fatal("backup entries lack the ESP row")
	}
}

func TestWriteImageDeterministic(t *testing.T) {
	efi := []byte("MZ" + strings.Repeat("e", 1000))
	kernel := []byte("DSK1" + strings.Repeat("k", 2000))
	var a, b memSink
	if _, err := WriteImage(&a, efi, kernel, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteImage(&b, efi, kernel, 0); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a.buf, b.buf) {
		t.Fatal("same inputs produced different images")
	}
}

// TestWriteImageVsReference walks the SAME assertions mkfat32.py --list
// performs implicitly, plus the byte compare the spec's python assert runs:
// feed the writer's output back through the reader and compare against a
// second build.
func TestWriteImageSizeOverride(t *testing.T) {
	var s memSink
	if _, err := WriteImage(&s, []byte("MZxx"), []byte("DSK1"), 64); err != nil {
		t.Fatal(err)
	}
	if uint64(len(s.buf)) != 64*1024*1024 {
		t.Fatalf("size-mb 64 produced %d bytes", len(s.buf))
	}
}

func TestWriteImageByteParity(t *testing.T) {
	mkfat := filepath.Join("..", "..", "..", "image", "mkfat32.py")
	if _, err := os.Stat(mkfat); err != nil {
		t.Skip("mkfat32.py not reachable from this tree")
	}
	if _, err := execLookPath(); err != nil {
		t.Skip("python3 not on PATH")
	}
	dir := t.TempDir()
	efi := append([]byte("MZ"), bytes.Repeat([]byte{0x5A}, 4096)...)
	kernel := append([]byte("DSK1"), bytes.Repeat([]byte{0xA5}, 8192)...)
	efiPath := filepath.Join(dir, "BOOTAA64.EFI")
	kernPath := filepath.Join(dir, "KERNEL.BIN")
	if err := os.WriteFile(efiPath, efi, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(kernPath, kernel, 0o644); err != nil {
		t.Fatal(err)
	}
	ref := filepath.Join(dir, "ref.img")
	out, err := runPy(mkfat, ref, efiPath, kernPath)
	if err != nil {
		t.Fatalf("mkfat32.py failed: %v\n%s", err, out)
	}
	var s memSink
	if _, err := WriteImage(&s, efi, kernel, 0); err != nil {
		t.Fatal(err)
	}
	refBytes, err := os.ReadFile(ref)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(refBytes, s.buf) {
		// Name the first divergence — a byte-equal claim that fails needs
		// the offset to mean anything.
		n := len(refBytes)
		if len(s.buf) < n {
			n = len(s.buf)
		}
		for i := 0; i < n; i++ {
			if refBytes[i] != s.buf[i] {
				t.Fatalf("images differ at byte %d: ref=%02x got=%02x (sizes %d/%d)",
					i, refBytes[i], s.buf[i], len(refBytes), len(s.buf))
			}
		}
		t.Fatalf("image sizes differ: ref=%d got=%d", len(refBytes), len(s.buf))
	}
}
