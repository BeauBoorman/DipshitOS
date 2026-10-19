// Host pins for the M124a-2 (#2677) drag source: which gesture arms, what
// the offer claims, and which refusals the hook names — the seat transport
// itself is class-B's job (the go-drag spec leg).
package main

import (
	"testing"

	"virelai/vi"
)

// The declared mime follows mime.Sniff — subtype where the in-tree decoders
// read one (PNG/QOI/GIF/JPEG, text/plain), the bare family where they do
// not, octet-stream for honest unknowns.
func TestDragMimeNamesTheSniffedKind(t *testing.T) {
	pngHead := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}
	cases := []struct {
		name string
		head []byte
		want string
	}{
		{"NOTES.TXT", []byte("hello\n"), "text/plain"},
		{"PIC.PNG", pngHead, "image/png"},
		{"PIC.QOI", []byte("qoifrest"), "image/qoi"},
		{"PIC.GIF", []byte("GIF89a\x00\x00"), "image/gif"},
		{"PIC.JPG", []byte{0xff, 0xd8, 0xff, 0xe0}, "image/jpeg"},
		{"PIC.BMP", nil, "image"}, // extension says image; no head to refine
		{"CLIP.WAV", []byte("RIFF\x00\x00\x00\x00WAVE"), "audio"},
		{"PACK.ZIP", []byte("PK\x03\x04rest"), "archive"},
		{"APP.ELF", []byte{0x7f, 'E', 'L', 'F'}, "binary"},
		{"MYSTERY", []byte{0x00, 0x01, 0x02}, "application/octet-stream"},
	}
	for _, c := range cases {
		if got := dragMime(c.name, c.head); got != c.want {
			t.Errorf("dragMime(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

// A press that never landed on a row arms nothing.
func TestDragOfferRefusesNoPress(t *testing.T) {
	m := testModel(entry("KNOWN.TXT", false))
	m.pressRow = -1
	if _, _, ok := m.dragOffer(); ok {
		t.Fatal("no press row must refuse")
	}
	assertPending(t, &m, markerDragNo+"none")
}

// Directories and the volumes root refuse by name — an offer must carry
// what it claims, and a directory is not file bytes.
func TestDragOfferRefusesNonFiles(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleClick(3, 3) // press row 0 = SUB
	if _, _, ok := m.dragOffer(); ok {
		t.Fatal("a directory must refuse")
	}
	assertPending(t, &m, markerDragNo+"SUB dir")

	m.path = volsPath
	m.pressRow = 1
	if _, _, ok := m.dragOffer(); ok {
		t.Fatal("a volumes-root row must refuse")
	}
	assertPending(t, &m, markerDragNo+"KNOWN.TXT volume")
}

// The staged envelope is capped at vi.DragMax — an over-cap file refuses
// before the read, so the seat never stages a truncated lie.
func TestDragOfferRefusesOverCap(t *testing.T) {
	big := entry("HUGE.BIN", false)
	big.Size = vi.DragMax + 1
	m := testModel(big)
	m.pressRow = 0
	if _, _, ok := m.dragOffer(); ok {
		t.Fatal("an over-cap file must refuse")
	}
	assertPending(t, &m, markerDragNo+"HUGE.BIN too-large")
}

// An unreadable file (ENOSYS on the host seam, ENOENT in the guest) reports
// the kernel's refusal code — the arm must not claim bytes it never read.
func TestDragOfferRefusesUnreadable(t *testing.T) {
	m := testModel(entry("KNOWN.TXT", false))
	m.pressRow = 0
	if _, _, ok := m.dragOffer(); ok {
		t.Fatal("a failed read must refuse")
	}
	// The rc marker names the code — on the host that is the stub's
	// refusal, in the guest the kernel's.
	if len(m.pending) == 0 {
		t.Fatal("no refusal marker emitted")
	}
}

// The press gesture itself: a press on the selected row pends its open to
// the release edge, and the gesture state only lives while the row holds.
func TestPressPendsOpenUntilRelease(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleClick(3, 3) // select row 0
	m.handleClick(3, 3) // press the selected row: pends, does not open
	if !m.pendOpen || m.path != "/host/FM" {
		t.Fatalf("press must pend the open: pendOpen=%v path=%q", m.pendOpen, m.path)
	}
	m.releaseClick()
	if m.path != "/host/FM/SUB" || m.pressRow != -1 {
		t.Fatalf("release must settle the open: path=%q pressRow=%d", m.path, m.pressRow)
	}
}

// A press on an unselected row selects it and leaves nothing pending — the
// release is then a no-op.
func TestReleaseWithoutPendingIsInert(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleClick(3, 4) // select row 1
	if m.pendOpen {
		t.Fatal("a first press must not pend an open")
	}
	m.releaseClick()
	if m.path != "/host/FM" || m.pressRow != -1 {
		t.Fatalf("release must be inert: path=%q pressRow=%d", m.path, m.pressRow)
	}
}

// assertPending fails unless the model's marker queue ends with want.
func assertPending(t *testing.T, m *model, want string) {
	t.Helper()
	if len(m.pending) == 0 || m.pending[len(m.pending)-1] != want {
		t.Fatalf("pending = %v, want tail %q", m.pending, want)
	}
}
