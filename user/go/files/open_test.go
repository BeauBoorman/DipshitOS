// Host pins for the M81b (#1762) open dispatch. What is under test is the
// DECISION — which type the sniff gives these bytes, which handler the
// registry names, what the frame says, and what main is handed to exec. The
// exec itself is a guest syscall (main.go's execApp seam), so what a launch
// actually does is the class-B gate's proof, not this file's.
//
// vi is ENOSYS on the host, so readHead is swapped for the bytes a seeded
// file would have returned; every other path is the real one.
package main

import (
	"strings"
	"testing"

	"virelai/mime"
	"virelai/rss/keys"
)

// withHead makes readHead answer `head` for every path (rc = len(head), the
// vi.ReadFileAll success shape) and restores it afterwards.
func withHead(t *testing.T, head []byte) {
	t.Helper()
	saved := readHead
	readHead = func(string, int) ([]byte, int64) { return head, int64(len(head)) }
	t.Cleanup(func() { readHead = saved })
}

// withUnreadable makes every read fail, the shape of a file the share cannot
// hand over.
func withUnreadable(t *testing.T) {
	t.Helper()
	saved := readHead
	readHead = func(string, int) ([]byte, int64) { return nil, -int64(viErrENOSYS) }
	t.Cleanup(func() { readHead = saved })
}

var qoiHead = []byte("qoif\x00\x00\x00\x10\x00\x00\x00\x10\x03\xff\xff\xff")

func TestOpenFileDispatchesTheDefaultHandler(t *testing.T) {
	withHead(t, qoiHead)
	m := testModel(entry("PIC.QOI", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	got := pendingJoined(&m)
	want := markerOpenFile + "PIC.QOI type=image handler=GOVIEW.ELF"
	if !strings.Contains(got, want) {
		t.Fatalf("dispatch marker = %q, want it to contain %q", got, want)
	}
	r, ok := m.takeLaunch()
	if !ok {
		t.Fatal("a dispatch must hand main an exec request")
	}
	if r.bin != "GOVIEW.ELF" || r.path != "/host/FM/PIC.QOI" {
		t.Fatalf("launch = %+v; want GOVIEW.ELF on /host/FM/PIC.QOI", r)
	}
	// takeLaunch drains: a second poll must not re-launch the same file.
	if _, again := m.takeLaunch(); again {
		t.Fatal("takeLaunch handed out the same request twice")
	}
}

// The bytes win over the name — a PNG named .TXT opens in the image viewer,
// which is the whole point of sniffing before dispatching.
func TestOpenFileMagicBeatsTheName(t *testing.T) {
	withHead(t, []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"))
	m := testModel(entry("README.TXT", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if got := pendingJoined(&m); !strings.Contains(got, "type=image handler=GOVIEW.ELF") {
		t.Fatalf("PNG bytes named .TXT: %q", got)
	}
}

func TestOpenFileRefusesATypeNothingOpens(t *testing.T) {
	// Audio has a handler since M99c (GOSOUND.ELF); archive does not.
	withHead(t, []byte("PK\x03\x04\x00\x00"))
	m := testModel(entry("BUNDLE.ZIP", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	got := pendingJoined(&m)
	if !strings.Contains(got, markerOpenNo+"BUNDLE.ZIP type=archive") {
		t.Fatalf("archive must refuse by name: %q", got)
	}
	if strings.Contains(got, markerOpenFile) {
		t.Fatalf("a refused open must not also claim a dispatch: %q", got)
	}
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("a refused open must not queue an exec")
	}
	if m.status != "no handler for archive" {
		t.Fatalf("status = %q, want the named refusal", m.status)
	}
}

// "Unreadable" is the answer, not "unknown": the share refused the read, and
// sending the user hunting for a file type would send them the wrong way.
func TestOpenFileRefusesAnUnreadableFile(t *testing.T) {
	withUnreadable(t)
	m := testModel(entry("LOCKED.TXT", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	got := pendingJoined(&m)
	if !strings.Contains(got, markerOpenNo+"LOCKED.TXT (unreadable)") {
		t.Fatalf("an unreadable file must say so: %q", got)
	}
	if strings.Contains(got, "type=") {
		t.Fatalf("an unreadable file has no type to report: %q", got)
	}
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("an unreadable file must not queue an exec")
	}
	if m.status != "LOCKED.TXT: unreadable" {
		t.Fatalf("status = %q", m.status)
	}
	// `o` on the same file says the same thing and arms no list.
	m2 := testModel(entry("LOCKED.TXT", false))
	m2.handleKey(runeKey('o'))
	if m2.mode == modeOpenWith {
		t.Fatal("an unreadable file must not arm the candidate list")
	}
	if got := pendingJoined(&m2); !strings.Contains(got, markerOpenNo+"LOCKED.TXT (unreadable)") {
		t.Fatalf("open-with on an unreadable file: %q", got)
	}
}

func TestOpenWithListsCandidatesAndChooses(t *testing.T) {
	withHead(t, qoiHead)
	m := testModel(entry("PIC.QOI", false))
	m.handleKey(runeKey('o'))
	if m.mode != modeOpenWith {
		t.Fatalf("`o` must arm the list, mode=%d", m.mode)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerOpenWith+"PIC.QOI type=image candidates=3") {
		t.Fatalf("candidate marker = %q", got)
	}
	// The list IS the menu: all three registered image handlers, numbered —
	// GOVIEW, GOEDIT's raw-byte fallback, and M132b's GOPAINT reservation.
	line := m.openWithLine()
	for _, want := range []string{"open with PIC.QOI (image)", "1 Image Viewer", "2 Code Editor", "3 Paint"} {
		if !strings.Contains(line, want) {
			t.Fatalf("status line %q missing %q", line, want)
		}
	}
	// Choosing the SECOND candidate launches the second candidate, not the
	// default — that is the whole point of the list.
	m.handleKey(runeKey('2'))
	if m.mode != modeNormal {
		t.Fatalf("choosing must leave the modal, mode=%d", m.mode)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerOpenChose+"PIC.QOI type=image handler=GOEDIT.ELF") {
		t.Fatalf("chose marker = %q", got)
	}
	r, ok := m.takeLaunch()
	if !ok || r.bin != "GOEDIT.ELF" || r.path != "/host/FM/PIC.QOI" {
		t.Fatalf("launch = %+v ok=%v; want GOEDIT.ELF on the picked file", r, ok)
	}
}

func TestOpenWithEscapeLaunchesNothing(t *testing.T) {
	withHead(t, qoiHead)
	m := testModel(entry("PIC.QOI", false))
	m.handleKey(runeKey('o'))
	m.handleKey(keys.Event{Key: keys.KeyEsc})
	if m.mode != modeNormal || len(m.openCands) != 0 {
		t.Fatalf("escape must clear the list: mode=%d cands=%v", m.mode, m.openCands)
	}
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("a cancelled list must not queue an exec")
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerOpenCancel+"PIC.QOI") {
		t.Fatalf("cancel marker missing: %q", got)
	}
}

func TestOpenWithRefusesATypeWithNoCandidates(t *testing.T) {
	// Binary is a type nothing opens: the modal must not arm empty.
	withHead(t, []byte("\x7fELF\x02\x01\x01\x00"))
	m := testModel(entry("TOOL.ELF", false))
	m.handleKey(runeKey('o'))
	if m.mode == modeOpenWith {
		t.Fatal("no candidates must not arm an empty modal")
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerOpenNo+"TOOL.ELF type=binary") {
		t.Fatalf("the refusal must name the type: %q", got)
	}
}

// A digit outside the list is refused, not clamped: pressing 9 with three
// candidates must not silently open the third one.
func TestOpenWithRejectsAnUnlistedDigit(t *testing.T) {
	withHead(t, qoiHead)
	m := testModel(entry("PIC.QOI", false))
	m.handleKey(runeKey('o'))
	m.handleKey(runeKey('9'))
	if m.mode != modeOpenWith {
		t.Fatalf("an unlisted digit must leave the list open, mode=%d", m.mode)
	}
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("an unlisted digit must not queue an exec")
	}
	if m.status != "open with: no such candidate" {
		t.Fatalf("status = %q", m.status)
	}
}

// `l` and the second click reach the same decision as Enter — one open, three
// gestures.
func TestOpenGesturesShareOneDecision(t *testing.T) {
	for name, press := range map[string]func(*model){
		"enter": func(m *model) { m.handleKey(keys.Event{Key: keys.KeyEnter}) },
		"l":     func(m *model) { m.handleKey(runeKey('l')) },
		"click": func(m *model) {
			// Row 2 of the frame is the first list row; two clicks on it —
			// the second click's open lands on its release edge.
			m.handleClick(2, 3)
			m.handleClick(2, 3)
			m.releaseClick()
		},
	} {
		withHead(t, qoiHead)
		m := testModel(entry("PIC.QOI", false))
		press(&m)
		if _, ok := m.takeLaunch(); !ok {
			t.Errorf("%s: no exec queued for an image", name)
		}
	}
}

// A directory still navigates: the open seam is for files, and openSel must
// not have grown a second meaning for directories.
func TestOpenOnADirectoryStillNavigates(t *testing.T) {
	withHead(t, qoiHead)
	m := testModel(entry("SUB", true), entry("PIC.QOI", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	if m.path != "/host/FM/SUB" {
		t.Fatalf("path = %q, want the directory entered", m.path)
	}
	if _, ok := m.takeLaunch(); ok {
		t.Fatal("entering a directory must not launch anything")
	}
}

// The handler registry the app dispatches through is the mime package's, and
// the two day-one adopters are the ones the card names.
func TestDispatchUsesTheRegisteredHandlers(t *testing.T) {
	if h, ok := mime.Default(mime.Image); !ok || h.Bin != "GOVIEW.ELF" {
		t.Fatalf("Default(Image) = %+v ok=%v; want GOVIEW.ELF", h, ok)
	}
	if h, ok := mime.Default(mime.Text); !ok || h.Bin != "GOEDIT.ELF" {
		t.Fatalf("Default(Text) = %+v ok=%v; want GOEDIT.ELF", h, ok)
	}
	// A text file opens in the editor, and the editor takes a path in argv[1]
	// (edit/main.go reads vi.Args()) — so the launch carries the path.
	withHead(t, []byte("hello from the share\n"))
	m := testModel(entry("NOTES.TXT", false))
	m.handleKey(keys.Event{Key: keys.KeyEnter})
	r, ok := m.takeLaunch()
	if !ok || r.bin != "GOEDIT.ELF" || r.path != "/host/FM/NOTES.TXT" {
		t.Fatalf("text launch = %+v ok=%v", r, ok)
	}
}
