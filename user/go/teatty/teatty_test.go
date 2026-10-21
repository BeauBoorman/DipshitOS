// Package teatty's host surface: the kernel calls degrade to -ENOSYS
// here, so these tests pin the pieces that stay honest off-guest — the
// paced input wrapper's LF->CR normalization (and its bracketed-paste
// carve-out), the File's term.File shape, and the cell-grid math the
// x/term overlay answers through.
package teatty

import (
	"io"
	"os"
	"testing"
	"time"

	"virelai/tabapp"
)

func TestOpenRefusesOnHost(t *testing.T) {
	if IsBoundFd(7) {
		t.Fatal("IsBoundFd must be false before Open")
	}
	in, out, err := Open(tabapp.Config{Name: "TEST.ELF", Title: "t", X: 0, Y: 0, W: 640, H: 400})
	if err == nil || in != nil || out != nil {
		t.Fatalf("Open on host = %v, want refusal (tabapp.Init -> win_open ENOSYS)", err)
	}
	if Bound() {
		t.Fatal("host open must not leave a bound fd")
	}
	if IsBoundFd(7) {
		t.Fatal("IsBoundFd must still be false after the refused Open")
	}
}

func TestTranslateEnterMapsLFOutsidePaste(t *testing.T) {
	out, tail, paste := translateEnter([]byte("a\nb\n"), false)
	if string(out) != "a\rb\r" || tail != nil || paste {
		t.Fatalf("translateEnter = %q tail=%q paste=%v", out, tail, paste)
	}
}

func TestTranslateEnterKeepsPasteContentVerbatim(t *testing.T) {
	src := "x\n" + pasteBegin + "a\nb" + pasteEnd + "y\n"
	out, tail, paste := translateEnter([]byte(src), false)
	want := "x\r" + pasteBegin + "a\nb" + pasteEnd + "y\r"
	if string(out) != want || tail != nil || paste {
		t.Fatalf("translateEnter = %q tail=%q paste=%v, want %q", out, tail, paste, want)
	}
}

func TestTranslateEnterMarkerSplitAcrossReads(t *testing.T) {
	// The begin marker lands split across two kernel reads; the tail
	// holdback must defer the decision, then emit the marker whole.
	out, tail, paste := translateEnter([]byte("k\x1b[20"), false)
	if string(out) != "k" || string(tail) != "\x1b[20" || paste {
		t.Fatalf("first chunk = %q tail=%q paste=%v", out, tail, paste)
	}
	out, tail, paste = translateEnter(append(tail, []byte("0~l\n")...), paste)
	if string(out) != pasteBegin+"l\n" || tail != nil || !paste {
		t.Fatalf("second chunk = %q tail=%q paste=%v", out, tail, paste)
	}
}

func TestTranslateEnterEndMarkerSplit(t *testing.T) {
	out, tail, paste := translateEnter([]byte("a\n\x1b[20"), true)
	if string(out) != "a\n" || string(tail) != "\x1b[20" || !paste {
		t.Fatalf("first chunk = %q tail=%q paste=%v", out, tail, paste)
	}
	out, tail, paste = translateEnter(append(tail, []byte("1~b\n")...), paste)
	if string(out) != pasteEnd+"b\r" || tail != nil || paste {
		t.Fatalf("second chunk = %q tail=%q paste=%v", out, tail, paste)
	}
}

func TestReadReturnsNormalizedBytes(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	in := &File{f: r}
	if _, err := w.Write([]byte("exit\n")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 8)
	n, err := in.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if string(buf[:n]) != "exit\r" {
		t.Fatalf("Read = %q, want the kernel's Enter byte normalized to CR", buf[:n])
	}
}

func TestReadKeepsPasteNewlines(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	in := &File{f: r}
	body := pasteBegin + "a\nb" + pasteEnd + "\n"
	if _, err := w.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 64)
	n, err := in.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	want := pasteBegin + "a\nb" + pasteEnd + "\r"
	if string(buf[:n]) != want {
		t.Fatalf("Read = %q, want pasted LF verbatim and trailing LF -> CR: %q", buf[:n], want)
	}
}

func TestReadPacesEmptyReads(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	// On the host an os.Pipe read BLOCKS already; the virelai pacing loop
	// only shows when the kernel answers 0. What this pins on host is the
	// contract a caller sees: bytes that arrive late still come back.
	in := &File{f: r}
	defer r.Close()
	go func() {
		time.Sleep(30 * time.Millisecond)
		_, _ = w.Write([]byte("late"))
	}()
	buf := make([]byte, 8)
	n, err := in.Read(buf)
	if err != nil && err != io.EOF {
		t.Fatalf("Read err = %v", err)
	}
	if string(buf[:n]) != "late" {
		t.Fatalf("Read = %q, want paced delivery of late bytes", buf[:n])
	}
}

func TestFileIsTermFileShaped(t *testing.T) {
	// term.File is io.ReadWriteCloser + Fd(); the shape is what
	// initInput's type assertion checks.
	var _ interface {
		io.ReadWriteCloser
		Fd() uintptr
	} = (*File)(nil)
}

// TestNoteResizeCellMath pins the cellsForRect contract — cols =
// clamp(w/cellW, 8, 80), rows = (h-16)/cellH — at ALL THREE zoom rungs
// (the M80i ladder: 7x13 / 8x16 / 10x21). 640x400 is charmhello's
// declared rect, 512x384 its 'r' resize target.
func TestNoteResizeCellMath(t *testing.T) {
	rungs := []struct {
		name         string
		cellW, cellH uint32
	}{
		{"small 7x13", 7, 13},
		{"medium 8x16 (the boot look)", 8, 16},
		{"large 10x21", 10, 21},
	}
	rects := []struct {
		w, h uint32
		want [][2]int // cols,rows per rung
	}{
		{640, 400, [][2]int{{80, 29}, {80, 24}, {64, 18}}},
		{512, 384, [][2]int{{73, 28}, {64, 23}, {51, 17}}},
		{48, 40, [][2]int{{8, 1}, {8, 1}, {8, 1}}},
	}
	for i, rung := range rungs {
		for _, rc := range rects {
			c, r := noteResize(rc.w, rc.h, rung.cellW, rung.cellH)
			if c != rc.want[i][0] || r != rc.want[i][1] {
				t.Errorf("noteResize(%d,%d,%d,%d) = %dx%d, want %dx%d (%s)",
					rc.w, rc.h, rung.cellW, rung.cellH, c, r,
					rc.want[i][0], rc.want[i][1], rung.name)
			}
			if w, h := Size(); w != c || h != r {
				t.Errorf("Size = %dx%d after noteResize, want %dx%d", w, h, c, r)
			}
		}
	}
}

func TestNotifyCloseLatches(t *testing.T) {
	if Closed() {
		t.Fatal("Closed must start false")
	}
	NotifyClose()
	if !Closed() {
		t.Fatal("Closed must latch after NotifyClose")
	}
}

func TestCloseIsIdempotent(t *testing.T) {
	Close()
	Close()
	if WindowID() != -1 {
		t.Fatal("WindowID must reset after Close")
	}
}
