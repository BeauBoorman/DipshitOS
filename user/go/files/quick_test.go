package main

import (
	"bytes"
	"fmt"
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

// pdfDoc builds a minimal single-page document inside the M89 engine's
// closed classic-xref subset — the same byte discipline pdf's own
// document() helper emits: exact ascending object offsets, a Size/Root
// trailer, the %%EOF tail. The 72x48 pt MediaBox is the 96x64 raster
// that already IS the pane's bank bound — the thumbnail passes through.
func pdfDoc(content string) []byte {
	objects := []string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 48] /Contents 4 0 R >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(content), content),
	}
	var b bytes.Buffer
	b.WriteString("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
	offsets := make([]int, len(objects)+1)
	for i, o := range objects {
		offsets[i+1] = b.Len()
		fmt.Fprintf(&b, "%d 0 obj\n%s\nendobj\n", i+1, o)
	}
	start := b.Len()
	fmt.Fprintf(&b, "xref\n0 %d\n0000000000 65535 f \n", len(offsets))
	for _, off := range offsets[1:] {
		fmt.Fprintf(&b, "%010d 00000 n \n", off)
	}
	fmt.Fprintf(&b, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n",
		len(offsets), start)
	return b.Bytes()
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

func TestQuickLookDocumentArmPageOne(t *testing.T) {
	// Page one is two field fills — red left half, blue right — on the
	// 72x48 pt page that rasterizes exactly at the 96x64 bank bound.
	fileBacker(t, map[string][]byte{
		"/host/FM/PAGE.PDF": pdfDoc("1 0 0 rg 0 0 36 48 re f 0 0 1 rg 36 0 36 48 re f"),
	})
	m := testModel(entry("PAGE.PDF", false))
	m.handleKey(runeKey(' '))
	if m.mode != modeQuickLook || m.ql.kind != qlImage || !m.ql.doc {
		t.Fatalf("space must open the pdf arm: mode=%d kind=%d doc=%v",
			m.mode, m.ql.kind, m.ql.doc)
	}
	if m.ql.imgW != 96 || m.ql.imgH != 64 || m.ql.thW != 96 || m.ql.thH != 64 {
		t.Fatalf("dims = %dx%d thumb %dx%d, want 96x64/96x64",
			m.ql.imgW, m.ql.imgH, m.ql.thW, m.ql.thH)
	}
	if m.ql.pages != 1 {
		t.Fatalf("pages = %d, want 1", m.ql.pages)
	}
	if got := pendingJoined(&m); !strings.Contains(got,
		markerQuick+"PAGE.PDF kind=pdf 96x64 thumb=96x64") {
		t.Fatalf("pdf open marker missing: %q", got)
	}
	frame := m.render()
	if !strings.Contains(frame, "pdf page 1/1 · 96x64") {
		t.Fatal("the facts row must name the page, not an image")
	}
	if !strings.Contains(frame, "\x1bPq\"1;1;96;64") {
		t.Fatal("the sixel raster declaration is missing from the frame")
	}
	if !strings.Contains(frame, "\x1b\\") {
		t.Fatal("the sixel ST is missing")
	}
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal {
		t.Fatalf("escape must close: mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerQuickClose) {
		t.Fatalf("close marker missing: %q", got)
	}
}

func TestQuickLookDocumentRefusalsAreNamed(t *testing.T) {
	// Not a PDF at all — the .pdf name earns the sniff but the engine
	// names the refusal; the card carries it, never a bare card.
	fileBacker(t, map[string][]byte{
		"/host/FM/BAD.PDF": []byte("a text file that borrowed a .pdf name"),
		"/host/FM/BIG.PDF": []byte("%PDF-1.4\n"),
	})
	m := testModel(entry("BAD.PDF", false))
	m.handleKey(runeKey(' '))
	if m.ql.kind != qlCard || m.ql.typeName != "document" ||
		m.ql.refuse != "UnsupportedStructure" {
		t.Fatalf("malformed pdf = kind=%d type=%q refuse=%q",
			m.ql.kind, m.ql.typeName, m.ql.refuse)
	}
	if got := pendingJoined(&m); !strings.Contains(got,
		markerQuick+"BAD.PDF kind=card type=document refused=UnsupportedStructure") {
		t.Fatalf("refused card marker missing: %q", got)
	}
	frame := m.render()
	if !strings.Contains(frame, "refused   UnsupportedStructure") {
		t.Fatal("the card must name the refusal in the pane")
	}
	if strings.Contains(frame, "\x1bPq") {
		t.Fatal("a refused document must not emit a sixel")
	}
	// Oversized: the listing's own size says the source can never fit
	// the preview read — SourceLimit before the engine ever runs.
	big := entry("BIG.PDF", false)
	big.Size = 1 << 20
	m = testModel(big)
	m.handleKey(runeKey(' '))
	if m.ql.kind != qlCard || m.ql.refuse != "SourceLimit" {
		t.Fatalf("oversized pdf = kind=%d refuse=%q", m.ql.kind, m.ql.refuse)
	}
	if got := pendingJoined(&m); !strings.Contains(got,
		markerQuick+"BIG.PDF kind=card type=document refused=SourceLimit") {
		t.Fatalf("oversized refusal marker missing: %q", got)
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

// --- M193c (#3255): the .vcf contact-card face ---------------------------

// vcfFixture is one honoured card with an unhonoured tail — the shape
// the contact face lays out, N counted on the `also` row.
const vcfFixture = "BEGIN:VCARD\r\n" +
	"VERSION:4.0\r\n" +
	"FN:Grace Hopper\r\n" +
	"ORG:Cognition\r\n" +
	"TEL;TYPE=cell:+1-555-0100\r\n" +
	"EMAIL:grace@example.com\r\n" +
	"EMAIL:hopper@navy.mil\r\n" +
	"N:Hopper;Grace;;;\r\n" +
	"END:VCARD\r\n"

func TestQuickLookContactFaceRows(t *testing.T) {
	fileBacker(t, map[string][]byte{"/host/FM/CONTACT.VCF": []byte(vcfFixture)})
	m := testModel(entry("CONTACT.VCF", false))
	m.handleKey(runeKey(' '))
	if m.mode != modeQuickLook || m.ql.ct == nil || m.ql.kind != qlCard {
		t.Fatalf("space on a .vcf must open the contact face: mode=%d ct=%v",
			m.mode, m.ql.ct)
	}
	got := pendingJoined(&m)
	for _, want := range []string{
		markerQuick + "CONTACT.VCF kind=contact",
		"gofiles: contact fn=Grace Hopper",
		"gofiles: contact org=Cognition",
		"gofiles: contact tel=+1-555-0100",
		"gofiles: contact email=grace@example.com",
		"gofiles: contact email=hopper@navy.mil",
		"gofiles: contact also=N=1",
		"gofiles: contact done cards=1",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("contact marker %q missing: %q", want, got)
		}
	}
	frame := m.render()
	for _, want := range []string{
		"contact · card 1/1",
		"  Grace Hopper",
		"org      Cognition",
		"tel      +1-555-0100",
		"> email    grace@example.com  · enter mails via GOMAIL",
		"also     N=1",
	} {
		if !strings.Contains(frame, want) {
			t.Fatalf("card row %q missing from the frame", want)
		}
	}
	if strings.Contains(frame, "\x1bPq") {
		t.Fatal("the contact face must not emit a sixel")
	}
}

func TestContactMailHandoffQueuesGOMAIL(t *testing.T) {
	fileBacker(t, map[string][]byte{"/host/FM/CONTACT.VCF": []byte(vcfFixture)})
	m := testModel(entry("CONTACT.VCF", false))
	m.handleKey(runeKey(' '))
	// j moves the mail cursor to the second address; Enter fires it.
	m.handleKey(runeKey('j'))
	if m.ql.ct.mail != 1 {
		t.Fatalf("j must move the mail cursor: mail=%d", m.ql.ct.mail)
	}
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	lr, ok := m.takeLaunch()
	if !ok || lr.bin != "GOMAIL.ELF" {
		t.Fatalf("the hand-off must queue GOMAIL.ELF: %+v ok=%v", lr, ok)
	}
	if len(lr.args) != 3 || lr.args[0] != "send" || lr.args[1] != "--to" ||
		lr.args[2] != "hopper@navy.mil" {
		t.Fatalf("hand-off argv = %v, want send --to hopper@navy.mil", lr.args)
	}
	if lr.path != "" {
		t.Fatalf("the mail hand-off carries no file path: %q", lr.path)
	}
	if got := pendingJoined(&m); !strings.Contains(got,
		"gofiles: contact mail hopper@navy.mil handler=GOMAIL.ELF") {
		t.Fatalf("hand-off decision marker missing: %q", got)
	}
}

func TestContactFaceRefusalsAreNamed(t *testing.T) {
	// Not a vcard at all — the extension claims it, the parse names it.
	fileBacker(t, map[string][]byte{
		"/host/FM/BAD.VCF": []byte("a text file that borrowed a .vcf name"),
	})
	m := testModel(entry("BAD.VCF", false))
	m.handleKey(runeKey(' '))
	if m.ql.ct == nil || m.ql.ct.refuse != "not-vcard" {
		t.Fatalf("bad vcf = ct=%+v", m.ql.ct)
	}
	got := pendingJoined(&m)
	for _, want := range []string{
		markerQuick + "BAD.VCF kind=contact refused=not-vcard",
		"gofiles: contact refused not-vcard",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("refusal marker %q missing: %q", want, got)
		}
	}
	frame := m.render()
	if !strings.Contains(frame, "refused  not-vcard") {
		t.Fatal("the face must name the refusal")
	}
	// Oversized: the read bound refuses by name before the parse runs.
	big := entry("BIG.VCF", false)
	big.Size = maxContactBytes + 1
	m = testModel(big)
	m.handleKey(runeKey(' '))
	if m.ql.ct == nil || m.ql.ct.refuse != "SourceLimit" {
		t.Fatalf("oversized vcf = ct=%+v", m.ql.ct)
	}
	m.handleKey(runeKey('m'))
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("a refused card must not queue a mail hand-off")
	}
}

func TestContactFaceBoundsAndCardStep(t *testing.T) {
	// Two honoured cards, the first carrying more fields than the face's
	// bound: overflow rows name "+n more", n steps to the second card.
	var b strings.Builder
	b.WriteString("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Many Fields\r\n")
	for i := 0; i < contactFieldMax+3; i++ {
		b.WriteString("TEL:+1-555-000" + string(rune('0'+i)) + "\r\n")
	}
	b.WriteString("END:VCARD\r\n")
	b.WriteString("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Second Person\r\n" +
		"EMAIL:two@example.com\r\nEND:VCARD\r\n")
	fileBacker(t, map[string][]byte{"/host/FM/MULTI.VCF": []byte(b.String())})
	m := testModel(entry("MULTI.VCF", false))
	m.handleKey(runeKey(' '))
	frame := m.render()
	if !strings.Contains(frame, "tel      +3 more") {
		t.Fatal("the tel overflow must be named on the card")
	}
	if !strings.Contains(frame, "cards    1/2") {
		t.Fatal("the multi-card accounting row is missing")
	}
	m.handleKey(runeKey('n'))
	if m.ql.ct.idx != 1 || m.ql.ct.mail != 0 {
		t.Fatalf("n must step to card 2 with the cursor reset: %+v", m.ql.ct)
	}
	if !strings.Contains(m.render(), "  Second Person") {
		t.Fatal("card 2 must paint after the step")
	}
	if got := pendingJoined(&m); !strings.Contains(got, "gofiles: contact fn=Second Person") {
		t.Fatalf("the card step must re-mirror the shown card: %q", got)
	}
	// 'm' mails the stepped card's single address.
	m.handleKey(runeKey('m'))
	lr, ok := m.takeLaunch()
	if !ok || lr.args[2] != "two@example.com" {
		t.Fatalf("hand-off after the step = %+v", lr)
	}
	// N past the first card clamps — no wrap, no panic.
	m.handleKey(runeKey('N'))
	if m.ql.ct.idx != 0 {
		t.Fatalf("N must step back: idx=%d", m.ql.ct.idx)
	}
	m.handleKey(runeKey('N'))
	if m.ql.ct.idx != 0 {
		t.Fatalf("N at the first card clamps: idx=%d", m.ql.ct.idx)
	}
}

func TestContactMailNoAddressNamesItself(t *testing.T) {
	fileBacker(t, map[string][]byte{"/host/FM/NOMAIL.VCF": []byte(
		"BEGIN:VCARD\r\nVERSION:4.0\r\nFN:No Address\r\nEND:VCARD\r\n")})
	m := testModel(entry("NOMAIL.VCF", false))
	m.handleKey(runeKey(' '))
	if !strings.Contains(m.render(), "mail     — (no address)") {
		t.Fatal("the face must name the absent hand-off")
	}
	m.handleKey(runeKey('m'))
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("a card with no address must not queue a hand-off")
	}
	if m.status != "contact: no address to mail" {
		t.Fatalf("status = %q", m.status)
	}
}

func TestOpenContactArgvFace(t *testing.T) {
	// The opens=text/vcard exec line's face: openContact arms the pane
	// on the path directly — the same card space on the row earns.
	fileBacker(t, map[string][]byte{"/host/FMV/CONTACT.VCF": []byte(vcfFixture)})
	m := testModel(entry("CONTACT.VCF", false))
	m.path = "/host/FMV"
	m.openContact("/host/FMV/CONTACT.VCF")
	if m.mode != modeQuickLook || m.ql.ct == nil {
		t.Fatalf("the argv face must stand on the pane: mode=%d ct=%v",
			m.mode, m.ql.ct)
	}
	if got := pendingJoined(&m); !strings.Contains(got,
		"gofiles: contact fn=Grace Hopper") {
		t.Fatalf("the argv face must mirror the card: %q", got)
	}
	if !strings.Contains(m.render(), "  Grace Hopper") {
		t.Fatal("the argv face must paint the card")
	}
	// Esc hands the frame back to the parent's listing.
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal {
		t.Fatalf("esc must close the face to the listing: mode=%d", m.mode)
	}
}
