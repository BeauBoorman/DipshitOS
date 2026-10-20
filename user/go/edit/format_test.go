package main

import (
	"go/format"
	"strings"
	"testing"
)

// format_test.go pins M138b (#2776) format-on-save. The shipped build
// carries no go/format (the probe's size refusal — format.go's header has
// the numbers), so formatSource is nil by default: the tests that drive
// the real formatter install format.Source on the seam, exactly what the
// `-tags editfmt` build wires at compile time. The refusal, the
// format-error contract and the save() integration are pinned regardless
// of which side ships.

// useFmt installs the real formatter on the seam — the editfmt build's
// compile-time wiring, run as a test substitute.
func useFmt(t *testing.T) {
	t.Helper()
	old := formatSource
	formatSource = format.Source
	t.Cleanup(func() { formatSource = old })
}

// TestFormatGoApplies: an unformatted .go buffer formats in place as ONE
// undoable op — the caret stays in range and Ctrl-Z restores the
// pre-format bytes.
func TestFormatGoApplies(t *testing.T) {
	useFmt(t)
	e := usEditor("package main\nfunc  main( ) { println(1) }\n")
	e.path = "/host/W/main.go"
	e.formatGo()
	want := "package main\n\nfunc main() { println(1) }\n"
	if string(e.buf) != want {
		t.Fatalf("formatted = %q want %q", e.buf, want)
	}
	if len(e.hist.undo) != 1 || e.hist.undo[0].kind != opEdit {
		t.Fatalf("format must land ONE composite op, got %+v", e.hist.undo)
	}
	e.undo()
	if string(e.buf) != "package main\nfunc  main( ) { println(1) }\n" {
		t.Fatalf("undo must restore the pre-format buffer: %q", e.buf)
	}
	// A caret that was past the new end is clamped, not left indexing.
	e2 := usEditor("package main\nfunc  main( ){}\n")
	e2.path = "/host/W/main.go"
	e2.cur = len(e2.buf)
	e2.formatGo()
	if e2.cur > len(e2.buf) {
		t.Fatalf("caret past formatted end: %d > %d", e2.cur, len(e2.buf))
	}
}

// TestFormatGoAlreadyClean: a gofmt-clean buffer gets the n= receipt and
// no op — the ring does not grow on a no-op save.
func TestFormatGoAlreadyClean(t *testing.T) {
	useFmt(t)
	doc := "package main\n\nfunc main() { println(1) }\n"
	e := usEditor(doc)
	e.path = "/host/W/main.go"
	e.formatGo()
	if string(e.buf) != doc {
		t.Fatalf("clean buffer changed: %q", e.buf)
	}
	if len(e.hist.undo) != 0 {
		t.Fatalf("a no-op format must not push an op: %+v", e.hist.undo)
	}
}

// TestFormatGoErrorLeavesTheBuffer: a parse error is the named-diagnostic
// contract — `format error <diag>` prints, the strip shows it by name, and
// the buffer does not move.
func TestFormatGoErrorLeavesTheBuffer(t *testing.T) {
	useFmt(t)
	doc := "package main\nfunc broken( {\n"
	e := usEditor(doc)
	e.path = "/host/W/main.go"
	e.formatGo()
	if string(e.buf) != doc {
		t.Fatalf("an errored format touched the buffer: %q", e.buf)
	}
	if !e.banner.Open || !strings.Contains(e.banner.Text, "format /host/W/main.go failed:") {
		t.Fatalf("the strip must name the diagnostic: open=%v text=%q",
			e.banner.Open, e.banner.Text)
	}
	if len(e.hist.undo) != 0 {
		t.Fatalf("an errored format must not push an op: %+v", e.hist.undo)
	}
}

// TestFormatGoSkipsNonGo: a .txt save never touches the formatter — the
// .go suffix is the switch.
func TestFormatGoSkipsNonGo(t *testing.T) {
	useFmt(t)
	e := usEditor("not   go\n")
	e.path = "/host/EDIT/SEED.TXT"
	e.formatGo()
	if string(e.buf) != "not   go\n" {
		t.Fatalf("non-.go buffer touched: %q", e.buf)
	}
}

// TestFormatUnavailableRefusal: the shipped build's shape — the seam is
// nil and a .go save prints the card's named refusal, leaving the buffer.
func TestFormatUnavailableRefusal(t *testing.T) {
	old := formatSource
	formatSource = nil
	t.Cleanup(func() { formatSource = old })
	doc := "package main\nfunc  main(){}\n"
	e := usEditor(doc)
	e.path = "/host/W/main.go"
	e.formatGo()
	if string(e.buf) != doc {
		t.Fatalf("the refusal path touched the buffer: %q", e.buf)
	}
	if formatUnavailable != "edit: format unavailable (go/format not guest-safe)" {
		t.Fatalf("refusal text drifted: %q", formatUnavailable)
	}
}

// TestSaveFormatsGoFile: the end-to-end contract on the editfmt side —
// save() on a .go path writes the FORMATTED bytes to the share.
func TestSaveFormatsGoFile(t *testing.T) {
	useFmt(t)
	const target = "/host/W/main.go"
	k := installEditKernel(t, 1000)
	e := &editor{path: target, buf: []byte("package main\nfunc  main( ) { println(1) }\n")}
	if !e.save() {
		t.Fatal("save must publish")
	}
	want := "package main\n\nfunc main() { println(1) }\n"
	if got := string(k.files[target]); got != want {
		t.Fatalf("published = %q want %q", got, want)
	}
}

// TestSaveFormatErrorStillPublishes: a buffer the parser refuses is saved
// as-is — the diagnostic shows on the strip, the publish is not blocked.
func TestSaveFormatErrorStillPublishes(t *testing.T) {
	useFmt(t)
	const target = "/host/W/bad.go"
	k := installEditKernel(t, 1000)
	doc := "package main\nfunc broken( {\n"
	e := &editor{path: target, buf: []byte(doc)}
	if !e.save() {
		t.Fatal("a format error must not block the save")
	}
	if got := string(k.files[target]); got != doc {
		t.Fatalf("published = %q want the unformatted %q", got, doc)
	}
	if !e.banner.Open {
		t.Fatal("the strip must show the format diagnostic")
	}
}

// TestSaveRefusalStillPublishes: the shipped shape — a .go save without a
// formatter prints the refusal and writes the buffer verbatim.
func TestSaveRefusalStillPublishes(t *testing.T) {
	old := formatSource
	formatSource = nil
	t.Cleanup(func() { formatSource = old })
	const target = "/host/W/raw.go"
	k := installEditKernel(t, 1000)
	doc := "package main\nfunc  main(){}\n"
	e := &editor{path: target, buf: []byte(doc)}
	if !e.save() {
		t.Fatal("the refusal must not block the save")
	}
	if got := string(k.files[target]); got != doc {
		t.Fatalf("published = %q want the verbatim %q", got, doc)
	}
}

// TestStatusErrCount: the diagnostics count rides the status line —
// `err=N` before any landing, `err=I/N` once a row was jumped to.
func TestStatusErrCount(t *testing.T) {
	e := usEditor("aa\nbb")
	// cur sits at the end (usEditor's rule) — line 2 col 3.
	e.diags = []diagRow{
		{file: "/host/BAD/main.go", line: 1, col: 1, raw: "a:1:1: one"},
		{file: "/host/BAD/main.go", line: 2, col: 1, raw: "a:2:1: two"},
	}
	e.diagsSel = -1
	if got, want := e.statusText(), "line=2/2 col=3 err=2"; got != want {
		t.Fatalf("status = %q want %q", got, want)
	}
	e.diagsSel = 1
	if got, want := e.statusText(), "line=2/2 col=3 err=2/2"; got != want {
		t.Fatalf("status = %q want %q", got, want)
	}
	// An empty or cleared list drops the count entirely.
	e.diags = nil
	e.diagsSel = -1
	if got, want := e.statusText(), "line=2/2 col=3"; got != want {
		t.Fatalf("status = %q want %q", got, want)
	}
}
