package main

import (
	"strings"
	"testing"

	"virelai/vi"
)

// The gate's pixel assert counts this EXACT RGB in the real scanout — if a
// palette refactor ever moves it, this test is the class-A tripwire.
const testDetailAccent = "\x1b[38;2;255;199;92m"

func TestBrowseFrameShape(t *testing.T) {
	m := testModel()
	lines := m.renderLines()
	if len(lines) != m.rows {
		t.Errorf("browse frame has %d lines, want rows=%d", len(lines), m.rows)
	}
	frame := m.render()
	if !strings.HasPrefix(frame, framePrologue) {
		t.Errorf("frame does not start with the alt-screen prologue")
	}
	if strings.HasSuffix(frame, "\n") {
		t.Errorf("frame ends with a trailing newline (would scroll the grid)")
	}
	// The selected row is the slab, and rows carry their group tag.
	body := strings.Join(lines, "\n")
	if !strings.Contains(body, "> alias") {
		t.Errorf("first row is not the selection slab")
	}
	if !strings.Contains(body, "shell") {
		t.Errorf("rows missing group tags")
	}
	if !strings.Contains(body, testDetailAccent) {
		t.Errorf("browse preview missing the detail accent")
	}
}

func TestDetailFrameIsAccentText(t *testing.T) {
	m := testModel()
	key(&m, kDown)
	key(&m, kDown)
	key(&m, kDown) // M98b's `alias` row sorts one slot ahead of `echo`
	key(&m, kEnter)
	lines := m.renderLines()
	if len(lines) != m.rows {
		t.Errorf("detail frame has %d lines, want rows=%d", len(lines), m.rows)
	}
	if !strings.HasPrefix(lines[0], testDetailAccent+" echo") {
		t.Errorf("detail header not accent-named: %q", lines[0])
	}
	body := strings.Join(lines, "\n")
	if !strings.Contains(body, testDetailAccent+"usage: echo [ARG...]") {
		t.Errorf("detail body missing accent usage line")
	}
	if !strings.Contains(body, "write ARG... separated by single spaces") {
		t.Errorf("detail body missing the blurb")
	}
}

func TestDocsEmptyAndReader(t *testing.T) {
	m := testModel()
	m.mode = modeDocs
	lines := m.renderLines()
	if len(lines) != m.rows {
		t.Errorf("docs frame has %d lines, want rows=%d", len(lines), m.rows)
	}
	if !strings.Contains(strings.Join(lines, "\n"), "(no docs bundle — seed /host/docs)") {
		t.Errorf("empty docs state missing: %v", lines[1])
	}

	m.mode = modeDocView
	m.docOf = "GUIDE.TXT"
	m.docText = "pinned help fixture"
	lines = m.renderLines()
	if len(lines) != m.rows {
		t.Errorf("doc frame has %d lines, want rows=%d", len(lines), m.rows)
	}
	if !strings.Contains(strings.Join(lines, "\n"), "pinned help fixture") {
		t.Errorf("doc text missing from reader frame")
	}
}

func TestDocsListSelection(t *testing.T) {
	m := testModel()
	var a, b vi.DirEntry
	copy(a.Name[:], "GUIDE.TXT")
	a.Size = 26
	copy(b.Name[:], "NOTES.MD")
	b.Size = 24
	m.docs[0], m.docs[1] = a, b
	m.docN = 2
	m.mode = modeDocs
	body := strings.Join(m.renderLines(), "\n")
	if !strings.Contains(body, "> GUIDE.TXT") {
		t.Errorf("docs list missing selected GUIDE.TXT row")
	}
	if !strings.Contains(body, "NOTES.MD") {
		t.Errorf("docs list missing NOTES.MD row")
	}
}

func TestWrapText(t *testing.T) {
	ls := wrapText("alpha beta gamma delta epsilon", 10)
	for _, l := range ls {
		if len(l) > 10 {
			t.Errorf("wrapped line %q exceeds 10 cells", l)
		}
	}
	if strings.Join(ls, " ") != "alpha beta gamma delta epsilon" {
		t.Errorf("wrap dropped or reordered words: %v", ls)
	}
}

func TestClipVisSkipsANSI(t *testing.T) {
	s := colAccent + "abcdef" + colReset
	if visLen(s) != 6 {
		t.Errorf("visLen = %d, want 6", visLen(s))
	}
	if got := clipVis(s, 3); !strings.HasPrefix(got, colAccent) {
		t.Errorf("clipVis lost the ANSI prefix: %q", got)
	}
}
