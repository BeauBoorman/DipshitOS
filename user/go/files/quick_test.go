package main

import (
	"strings"
	"testing"

	"virelai/rss/keys"
	"virelai/vi"
	"virelai/webrender"
)

// qoi builds a solid-colour WxH QOI (header + QOI_OP_RGB per pixel + the
// 8-byte end marker — the same shape the gate seeds).
func qoi(w, h int, r, g, b byte) []byte {
	out := []byte("qoif")
	for _, v := range []int{w >> 24, w >> 16, w >> 8, w, h >> 24, h >> 16, h >> 8, h} {
		out = append(out, byte(v))
	}
	out = append(out, 4, 0)
	for i := 0; i < w*h; i++ {
		out = append(out, 0xfe, r, g, b)
	}
	return append(out, 0, 0, 0, 0, 0, 0, 0, 1)
}

// fileBacker points the readHead seam at a fixture table — the same shape
// the open-with tests use.
func fileBacker(t *testing.T, files map[string][]byte) {
	t.Helper()
	prev := readHead
	readHead = func(path string, cap int) ([]byte, int64) {
		if b, ok := files[path]; ok {
			return b, int64(len(b))
		}
		return nil, -2 // ENOENT
	}
	t.Cleanup(func() { readHead = prev })
}

func TestQuickLookTextArmFirstFortyLines(t *testing.T) {
	var body strings.Builder
	for i := 1; i <= 45; i++ {
		body.WriteString("line-of-text\n")
	}
	fileBacker(t, map[string][]byte{"/host/FM/WORDS.TXT": []byte(body.String())})
	m := testModel(entry("WORDS.TXT", false))
	m.handleKey(runeKey(' '))
	if m.mode != modeQuickLook || m.ql.kind != qlText {
		t.Fatalf("space must open the text arm: mode=%d kind=%d", m.mode, m.ql.kind)
	}
	if len(m.ql.lines) != qlTextLines {
		t.Fatalf("pane holds %d lines, want %d", len(m.ql.lines), qlTextLines)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuick+"WORDS.TXT kind=text lines=40") {
		t.Fatalf("text open marker missing: %q", got)
	}
	frame := m.render()
	if !strings.Contains(frame, testPreviewAccent+" line-of-text") {
		t.Fatal("text arm must paint its lines in the preview accent")
	}
	// j/k scroll inside the 40-line window.
	m.handleKey(runeKey('j'))
	if m.ql.scroll != 1 {
		t.Fatalf("j scrolled to %d, want 1", m.ql.scroll)
	}
	m.handleKey(runeKey('k'))
	if m.ql.scroll != 0 {
		t.Fatalf("k scrolled to %d, want 0", m.ql.scroll)
	}
	// Space closes and the list frame is back.
	m.handleKey(runeKey(' '))
	if m.mode != modeNormal {
		t.Fatalf("second space must close: mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuickClose) {
		t.Fatalf("close marker missing: %q", got)
	}
	if !strings.Contains(m.render(), " preview: ") {
		t.Fatal("closing must restore the list frame")
	}
}

func TestQuickLookImageArmSixel(t *testing.T) {
	fileBacker(t, map[string][]byte{"/host/FM/LOOK.QOI": qoi(16, 16, 255, 0, 0)})
	m := testModel(entry("LOOK.QOI", false))
	m.handleKey(runeKey(' '))
	if m.mode != modeQuickLook || m.ql.kind != qlImage {
		t.Fatalf("space must open the image arm: mode=%d kind=%d", m.mode, m.ql.kind)
	}
	// 16x16 scaled to the 96x64 bank bound: 64x64, a 4x zoom.
	if m.ql.thW != 64 || m.ql.thH != 64 {
		t.Fatalf("thumbnail = %dx%d, want 64x64", m.ql.thW, m.ql.thH)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuick+"LOOK.QOI kind=image 16x16 thumb=64x64") {
		t.Fatalf("image open marker missing: %q", got)
	}
	frame := m.render()
	if !strings.Contains(frame, "\x1bPq\"1;1;64;64") {
		t.Fatal("the sixel raster declaration is missing from the frame")
	}
	if !strings.Contains(frame, "\x1b\\") {
		t.Fatal("the sixel ST is missing")
	}
	// The image lands inside the grid: origin cell + tile coverage.
	row, col := m.qlOrigin()
	tw, th := m.ql.qlTiles()
	if row < 2 || row+th > m.rows-2 || col < 0 || col+tw > m.cols {
		t.Fatalf("origin (%d,%d) tiles %dx%d escapes the %dx%d grid",
			row, col, tw, th, m.cols, m.rows)
	}
	// Esc closes too.
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal {
		t.Fatalf("escape must close: mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuickClose) {
		t.Fatalf("close marker missing: %q", got)
	}
}

func TestQuickLookCardArmTypeSizeMtime(t *testing.T) {
	fileBacker(t, map[string][]byte{"/host/FM/SONG.OGG": append([]byte("OggS\x00\x02"), make([]byte, 58)...)})
	prev := statTimes
	statTimes = func(string) (int64, int64, bool, bool) {
		return 1_700_000_000_000_000_000, 1_700_100_000_000_000_000, true, true
	}
	t.Cleanup(func() { statTimes = prev })
	m := testModel(entry("SONG.OGG", false))
	m.handleKey(runeKey(' '))
	if m.mode != modeQuickLook || m.ql.kind != qlCard {
		t.Fatalf("space must open the card arm: mode=%d kind=%d", m.mode, m.ql.kind)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuick+"SONG.OGG kind=card type=audio") {
		t.Fatalf("card open marker missing: %q", got)
	}
	frame := m.render()
	for _, want := range []string{
		"type      audio", "size      19 B",
		"modified  2023-11-14 22:13:20 UTC",
		"changed   2023-11-16 02:00:00 UTC",
	} {
		if !strings.Contains(frame, want) {
			t.Fatalf("card row %q missing from the frame", want)
		}
	}
	if strings.Contains(frame, "\x1bPq") {
		t.Fatal("the card arm must not emit a sixel")
	}
}

func TestQuickLookDirectoryAndVolumeCards(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(runeKey(' '))
	if m.ql.kind != qlCard || m.ql.typeName != "directory" {
		t.Fatalf("a directory is the card arm: kind=%d type=%q", m.ql.kind, m.ql.typeName)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuick+"SUB kind=card type=directory") {
		t.Fatalf("dir card marker missing: %q", got)
	}
	// A mount-table row reads its state off the kernel's reserved bytes.
	m.mode = modeNormal
	m.path = volsPath
	var host vi.DirEntry
	copy(host.Name[:], "host")
	host.IsDir = 1
	host.Reserved[0] = vi.MountMounted
	host.Reserved[1] = vi.MountKindShare
	m.entries[0] = host
	m.n, m.sel = 1, 0
	m.handleKey(runeKey(' '))
	if m.ql.kind != qlCard || m.ql.vol == "" {
		t.Fatalf("a volume row is the card arm: kind=%d vol=%q", m.ql.kind, m.ql.vol)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuick+"host kind=card type=volume") {
		t.Fatalf("volume card marker missing: %q", got)
	}
	if !strings.Contains(m.render(), "share mounted rw") {
		t.Fatal("the volume card must name the kernel's state words")
	}
}

func TestQuickLookRefusalArmsFallToCard(t *testing.T) {
	// A .qoi that is not a QOI: sniffed image, decode refuses, the card
	// still names the type honestly.
	fileBacker(t, map[string][]byte{"/host/FM/BAD.QOI": []byte("not-an-image-bytes")})
	m := testModel(entry("BAD.QOI", false))
	m.handleKey(runeKey(' '))
	if m.ql.kind != qlCard || m.ql.typeName != "image" {
		t.Fatalf("undecodable image falls to the card: kind=%d type=%q", m.ql.kind, m.ql.typeName)
	}
	// An unreadable file cards too — type off the name, no panic.
	m = testModel(entry("GHOST.TXT", false))
	m.handleKey(runeKey(' '))
	if m.ql.kind != qlCard {
		t.Fatalf("unreadable file falls to the card: kind=%d", m.ql.kind)
	}
	// No selection: status only, no pane, no marker.
	m = testModel()
	m.handleKey(runeKey(' '))
	if m.mode == modeQuickLook {
		t.Fatal("space on an empty listing must not open the pane")
	}
	if got := pendingJoined(&m); strings.Contains(got, markerQuick) {
		t.Fatalf("no-selection emitted a quicklook marker: %q", got)
	}
}

func TestQuickLookPressDismisses(t *testing.T) {
	fileBacker(t, map[string][]byte{"/host/FM/WORDS.TXT": []byte("a line\n")})
	m := testModel(entry("WORDS.TXT", false))
	m.handleKey(runeKey(' '))
	if m.mode != modeQuickLook {
		t.Fatal("pane did not open")
	}
	m.handleClick(10, 10)
	if m.mode != modeNormal {
		t.Fatalf("a press must dismiss the pane: mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuickClose) {
		t.Fatalf("press-dismiss emitted no close marker: %q", got)
	}
}

func TestSixelEncodeRLEAndPaletteBound(t *testing.T) {
	// A 4x4 one-colour image: the run covers every column — the encoder
	// must emit the "!n" repeat form rather than one byte per column.
	im, err := webrender.DecodeImage(qoi(4, 4, 0, 255, 0))
	if err != nil {
		t.Fatalf("fixture QOI refused: %v", err)
	}
	seq, err := sixelEncode(im)
	if err != nil {
		t.Fatalf("encode refused a 4x4: %v", err)
	}
	if !strings.Contains(string(seq), "!4") {
		t.Fatalf("RLE run missing from %q", seq)
	}
	if !strings.HasPrefix(string(seq), "\x1bPq") || !strings.HasSuffix(string(seq), "\x1b\\") {
		t.Fatalf("DCS framing wrong: %q", seq)
	}
	// 257 distinct PERCENT colours refuse BEFORE the DCS opens — the
	// register space is the encoder's percent quantization, so neighbouring
	// 8-bit values share a register and never trip the bound.
	many := make([]uint32, 288)
	for i := range many {
		pr, pg := i%101, i/101
		cr := uint32((pr*255 + 50) / 100)
		cg := uint32((pg*255 + 50) / 100)
		many[i] = 0xff000000 | cr<<16 | cg<<8
	}
	img := &webrender.Image{Width: 96, Height: 3, Pix: many}
	if _, err := sixelEncode(img); err != errSixelPalette {
		t.Fatalf("288 percent colours must refuse with errSixelPalette, got %v", err)
	}
	// And a raster past the kernel's bank bound refuses first.
	wide := &webrender.Image{Width: 97, Height: 1, Pix: make([]uint32, 97)}
	if _, err := sixelEncode(wide); err != errSixelBounds {
		t.Fatalf("a 97px-wide raster must refuse with errSixelBounds, got %v", err)
	}
}
