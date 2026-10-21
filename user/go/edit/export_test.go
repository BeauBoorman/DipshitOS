package main

// export_test.go pins the M153b (#2922) .pdf save-as export: the wrap and
// page-break rules as pure functions, the written document parsed and
// rendered back through user/go/pdf (page count and a first-page bitmap
// golden), the over-64 refusal, and the session untouched by the export.

import (
	"strings"
	"testing"

	"virelai/pdf"
	"virelai/vi"
	"virelai/webrender/font"
)

// captureWrite substitutes the publish seam and records what was written.
func captureWrite(t *testing.T) (path *string, body *[]byte, calls *int) {
	var p string
	var b []byte
	n := 0
	old := bufWrite
	bufWrite = func(dst string, data []byte) int64 {
		p, b, n = dst, data, n+1
		return 0
	}
	t.Cleanup(func() { bufWrite = old })
	return &p, &b, &n
}

// memorySource adapts a byte slice to the reader's Source contract (the
// same shim pdfwrite's own tests keep).
type memorySource struct{ data []byte }

func (s *memorySource) Length() int64 { return int64(len(s.data)) }
func (s *memorySource) ReadAt(dst []byte, off int64, l *pdf.Ledger) (int, pdf.Code) {
	if off < 0 || off > int64(len(s.data)) {
		return 0, pdf.ReadFailed
	}
	n := min(len(dst), len(s.data)-int(off))
	if c := l.Read(uint64(n)); c != pdf.OK {
		return 0, c
	}
	copy(dst[:n], s.data[off:int(off)+n])
	return n, pdf.OK
}

func exportRender(t *testing.T, src []byte, page int) (pdf.Page, pdf.Stats) {
	t.Helper()
	l := &pdf.Ledger{Max: pdf.MaxWork}
	p, st, f := pdf.Render(&memorySource{data: src}, page, make([]byte, pdf.ArenaBytes), l)
	if f.Code != pdf.OK {
		t.Fatalf("render page %d: %+v (%s)", page, f, f.Error())
	}
	if p.Width != pdfwrite_PageW || p.Height != pdfwrite_PageH {
		t.Fatalf("page %d geometry %dx%d", page, p.Width, p.Height)
	}
	return p, st
}

// The reader's page geometry, named locally so the test does not import
// the writer's unexported internals.
const (
	pdfwrite_PageW = 816
	pdfwrite_PageH = 1056
)

// exportPixels rasterizes the page's shown cells the way the writer
// emits them: an 8px font8x8 cell per byte at (Left, Top + row*lead),
// black on white — the bitmap golden the first-page render must match.
func exportPixels(lines []string) []uint32 {
	pix := make([]uint32, pdfwrite_PageW*pdfwrite_PageH)
	for i := range pix {
		pix[i] = 0xffffffff
	}
	for row, line := range lines {
		for col := 0; col < len(line); col++ {
			g := font.Font8x8[line[col]-0x20]
			for r := 0; r < 8; r++ {
				for c := 0; c < 8; c++ {
					if g[r]>>c&1 == 0 {
						continue
					}
					y := exportTop + row*exportLead + r
					x := exportLeft + col*8 + c
					pix[y*pdfwrite_PageW+x] = 0xff000000
				}
			}
		}
	}
	return pix
}

func TestExportWrapRules(t *testing.T) {
	// Hard wrap at the column bound: 92 bytes become 90 + 2.
	rows := exportWrap([]byte(strings.Repeat("a", 92)), nil)
	if len(rows) != 2 || len(rows[0]) != exportCols || rows[1] != "aa" {
		t.Fatalf("wrap: %q", rows)
	}
	// An empty line still emits one row; a line of exactly the bound does
	// not grow a trailing blank row.
	if rows = exportWrap(nil, nil); len(rows) != 1 || rows[0] != "" {
		t.Fatalf("empty wrap: %q", rows)
	}
	if rows = exportWrap([]byte(strings.Repeat("b", exportCols)), nil); len(rows) != 1 {
		t.Fatalf("full-row wrap: %d rows", len(rows))
	}
	// Tabs advance to the next multiple-of-8 column: "x\ty" lands y at
	// column 8.
	rows = exportWrap([]byte("x\ty"), nil)
	if len(rows) != 1 || len(rows[0]) != 9 || rows[0][0] != 'x' || rows[0][8] != 'y' {
		t.Fatalf("tab wrap: %q", rows)
	}
	// A tab at a column boundary wraps mid-expansion like any cells: the
	// last column takes one space, the next row gets the rest.
	rows = exportWrap([]byte(strings.Repeat("c", exportCols-1)+"\t"), nil)
	if len(rows) != 2 || len(rows[0]) != exportCols || len(rows[1]) != exportTabW-2 {
		t.Fatalf("edge tab wrap: %d rows widths %d %d", len(rows), len(rows[0]), len(rows[1]))
	}
	// A multi-byte rune is one '?' cell, not one per UTF-8 byte.
	rows = exportWrap([]byte("aéb\t\x01"), nil)
	if len(rows) != 1 || rows[0] != "a?b     ?" {
		t.Fatalf("substitution wrap: %q", rows)
	}
}

func TestExportPageCount(t *testing.T) {
	// 80 rows fill page one; the 81st breaks onto page two.
	buf := []byte(strings.Repeat("\n", 80))
	if pages := (len(exportWrapAll(buf)) + exportPageRows - 1) / exportPageRows; pages != 2 {
		t.Fatalf("81 rows -> %d pages", pages)
	}
}

func TestExportPDFParsesAndRenders(t *testing.T) {
	// An 81-line buffer: "HELLO" on row 0, 79 blank lines, and "TAIL" on
	// row 80 — the first row of page two.
	var b strings.Builder
	b.WriteString("HELLO")
	for i := 0; i < 80; i++ {
		b.WriteByte('\n')
	}
	b.WriteString("TAIL")
	p, w, n := captureWrite(t)
	e := usEditor(b.String())
	if !e.exportPDF("/host/EDIT/EXPORT.PDF") {
		t.Fatalf("export refused: %q", e.banner.Text)
	}
	if *n != 1 || *p != "/host/EDIT/EXPORT.PDF" {
		t.Fatalf("publish calls=%d path=%q", *n, *p)
	}
	out := *w
	if !strings.HasPrefix(string(out), "%PDF-1.") {
		t.Fatal("not a PDF")
	}
	// The page count is the reader's own page-tree walk, not the marker.
	p0, st := exportRender(t, out, 0)
	if st.Pages != 2 {
		t.Fatalf("pages %d want 2", st.Pages)
	}
	// First-page bitmap golden: HELLO on row 0, the centered "1 / 2"
	// footer on row 81, nothing else.
	lines := make([]string, exportFooterRow+1)
	lines[0] = "HELLO"
	for i := 1; i < exportFooterRow; i++ {
		lines[i] = ""
	}
	lines[exportFooterRow] = exportFooter(1, 2)
	want := exportPixels(lines)
	for i := range want {
		if p0.Pix[i] != want[i] {
			t.Fatalf("pixel (%d,%d): got %08x want %08x", i%pdfwrite_PageW, i/pdfwrite_PageW, p0.Pix[i], want[i])
		}
	}
	// Page two carries TAIL at row 0 and "2 / 2".
	p1, _ := exportRender(t, out, 1)
	for i := range lines {
		lines[i] = ""
	}
	lines[0] = "TAIL"
	lines[exportFooterRow] = exportFooter(2, 2)
	want = exportPixels(lines)
	for i := range want {
		if p1.Pix[i] != want[i] {
			t.Fatalf("p2 pixel (%d,%d): got %08x want %08x", i%pdfwrite_PageW, i/pdfwrite_PageW, p1.Pix[i], want[i])
		}
	}
}

func TestExportLeavesTheSession(t *testing.T) {
	_, _, n := captureWrite(t)
	e := usEditor("dirty note\n")
	e.path = "/host/EDIT/SEED.TXT"
	e.dirty = true
	if !e.exportPDF("/host/EDIT/OUT.PDF") {
		t.Fatal("export refused")
	}
	if *n != 1 || !e.dirty || e.path != "/host/EDIT/SEED.TXT" || string(e.buf) != "dirty note\n" {
		t.Fatalf("session moved: calls=%d dirty=%v path=%q buf=%q", *n, e.dirty, e.path, e.buf)
	}
}

func TestExportRefusesOver64Pages(t *testing.T) {
	_, _, n := captureWrite(t)
	// 5202 one-blank rows -> 66 pages, over the writer's bound.
	e := usEditor(strings.Repeat("\n", 5201))
	e.dirty = true
	if e.exportPDF("/host/EDIT/BIG.PDF") {
		t.Fatal("66-page export published")
	}
	if *n != 0 {
		t.Fatal("refused export still wrote")
	}
	if !strings.Contains(e.banner.Text, "pages=66") {
		t.Fatalf("banner %q want pages=66", e.banner.Text)
	}
	if !e.dirty {
		t.Fatal("refusal cleared dirty")
	}
}

func TestExportPickerSaveAsPDF(t *testing.T) {
	// The picker landing: ctrl-shift-s pretypes the basename, a typed
	// .pdf name exports instead of moving the save path.
	_, _, n := captureWrite(t)
	e := usEditor("export me\n")
	e.path = "/host/EDIT/SEED.TXT"
	e.handleKey(usDown(0x16, modCtrl|vi.ModShift, 'S'))
	if e.mode != modePicker {
		t.Fatalf("mode %d", e.mode)
	}
	e.pick.Input = "EXPORT.PDF"
	e.handleKey(usDown(0x28, 0, '\r'))
	if *n != 1 || e.path != "/host/EDIT/SEED.TXT" {
		t.Fatalf("calls=%d path=%q", *n, e.path)
	}
}

func TestExportPathSuffix(t *testing.T) {
	for path, want := range map[string]bool{
		"/host/EDIT/EXPORT.PDF": true,
		"/host/EDIT/note.pdf":   true,
		"/host/EDIT/note.PdF":   true,
		"/host/EDIT/note.txt":   false,
		"/host/EDIT/pdf":        false,
		"/host/EDIT/.pdf":       true,
		"a.pdf":                 true,
	} {
		if exportPath(path) != want {
			t.Fatalf("exportPath(%q) = %v want %v", path, exportPath(path), want)
		}
	}
}

func TestExportMarkerShapes(t *testing.T) {
	// The go-edit gate greps these literal shapes — a drift here fails on
	// the host before it can fail live.
	if markerExport != "edit: export pdf " {
		t.Fatalf("markerExport = %q", markerExport)
	}
	if markerExportRefused != "edit: export refused " {
		t.Fatalf("markerExportRefused = %q", markerExportRefused)
	}
}
