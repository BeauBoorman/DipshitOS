package main

// export.go — M153b (#2922): a picker save-as whose name ends in .pdf
// exports the buffer as a paginated fixed-pitch document through
// virelai/pdfwrite (M153a) instead of publishing text. The export is a
// snapshot, not a republish: the buffer, its dirty flag and the session's
// path/lease all stay with the text file the export was taken from — the
// PDF is a sibling artifact, so no lease moves and no save marker prints.
//
// The layout is the claim-time pin (the card's "about 66 x 80 at 8 pt"
// was the shaper's inference, not a representable grid): font8x8 only
// scales in integral 8px cells at the writer's fixed 96 dpi, so scale 1
// is the only readable step under 12pt — 6pt glyphs, half-inch (48px)
// margins on Letter, 90 columns, 12px leading for exactly 80 rows. A
// `N / M` page-number footer sits in the bottom margin at row 81.
//
// The wrap rule is a hard wrap at the column bound — no word boundary
// logic, this is fixed-pitch text. Tabs advance to the next multiple-of-8
// column; every non-ASCII rune occupies one '?' cell (pdfwrite's own
// substitution domain is per byte, so the rune walk keeps one glyph per
// rune rather than one per UTF-8 byte).
//
// A document over 64 pages is refused before a byte is emitted — the
// banner plus `edit: export refused pages=<n>`. Anything the writer
// itself refuses (its per-page command budget, the output cap) lands the
// same shape with the refusal's name; a failed publish carries rc=.

import (
	"strings"
	"unicode/utf8"

	"virelai/pdfwrite"
	"virelai/vi"
)

const (
	// The export grid, pinned at claim (see header): 8px font8x8 cells on
	// a 816x1056 Letter page with 48px margins.
	exportCols      = 90 // (816 - 2*48) / 8
	exportPageRows  = 80 // (1056 - 2*48) / 12
	exportLeft      = 48
	exportTop       = 48
	exportLead      = 12 // 9pt leading
	exportTabW      = 8  // tab stop width in columns
	exportMaxPg     = 64 // pdfwrite's own page bound
	exportFooterRow = 81 // footer row index: 80 body rows, one blank, footer
)

// exportWrap folds one buffer line into exportCols-wide rows: a hard wrap
// at the column bound, tab stops every 8 columns, one '?' cell per
// non-ASCII rune. An empty line still emits one (empty) row — a trailing
// newline is a visible blank line in the editor and a blank row here.
func exportWrap(line []byte, rows []string) []string {
	var cur []byte
	col := 0
	for len(line) > 0 {
		r, size := utf8.DecodeRune(line)
		line = line[size:]
		var cells [exportTabW]byte
		var n int
		switch {
		case r == '\t':
			n = exportTabW - col%exportTabW
			for i := 0; i < n; i++ {
				cells[i] = ' '
			}
		case r < 0x20 || r > 0x7e:
			cells[0], n = '?', 1
		default:
			cells[0], n = byte(r), 1
		}
		for i := 0; i < n; i++ {
			if col == exportCols {
				rows = append(rows, string(cur))
				cur = cur[:0]
				col = 0
			}
			cur = append(cur, cells[i])
			col++
		}
	}
	return append(rows, string(cur))
}

// exportWrapAll wraps the whole buffer into fixed-width rows. The result
// never empty: an empty buffer wraps to one blank row, i.e. a one-page
// document carrying only its footer.
func exportWrapAll(buf []byte) []string {
	var rows []string
	for off := 0; ; {
		end := off
		for end < len(buf) && buf[end] != '\n' {
			end++
		}
		rows = exportWrap(buf[off:end], rows)
		if end == len(buf) {
			return rows
		}
		off = end + 1
	}
}

// exportFooter centers the `N / M` page number in the bottom margin row.
func exportFooter(page, pages int) string {
	s := vi.Itoa64(int64(page)) + " / " + vi.Itoa64(int64(pages))
	pad := (exportCols - len(s)) / 2
	if pad < 0 {
		pad = 0
	}
	return strings.Repeat(" ", pad) + s
}

// argvHeadroom wraps this image's writable memsz%4096 back into (0, 1792]
// after importing virelai/pdfwrite (its deflate tables, error vars and the
// `time` dependency push the remainder to ~3640). Same wall as NOTE's
// user/go/note argvHeadroom and the header budget in main.go: a remainder
// above 1792 makes sbrk's first mmap collide and mallocinit die with
// "cannot allocate memory".
var argvHeadroom [1400]byte

func init() { argvHeadroom[0] = 0 }

// exportPath reports whether a save-as name asks for the PDF export —
// the .pdf suffix, spelled in either case (share names are uppercased by
// user habit, not by the share itself).
func exportPath(path string) bool {
	if len(path) < 4 {
		return false
	}
	s := path[len(path)-4:]
	// Hand-folded: strings.EqualFold pulls the unicode case tables into
	// the writable segment — the same wall argvHeadroom exists under.
	return s[0] == '.' &&
		(s[1] == 'p' || s[1] == 'P') &&
		(s[2] == 'd' || s[2] == 'D') &&
		(s[3] == 'f' || s[3] == 'F')
}

// exportRefuse reports a refused export: the named marker first, then the
// banner carries the same shape the save path gives its failures.
func (e *editor) exportRefuse(why string) bool {
	vi.ConsoleLine(markerExportRefused + why)
	e.raiseBanner("export refused " + why)
	return false
}

// exportPDF publishes the buffer as a paginated PDF at path and reports
// whether the bytes are on the share. The document session is untouched:
// the buffer, its dirty flag and e.path belong to the text file the
// export was taken from. The page count is computed up front so the
// over-64 refusal names pages=<n> before any object exists.
func (e *editor) exportPDF(path string) bool {
	rows := exportWrapAll(e.buf)
	pages := (len(rows) + exportPageRows - 1) / exportPageRows
	if pages > exportMaxPg {
		return e.exportRefuse("pages=" + vi.Itoa64(int64(pages)))
	}
	d := pdfwrite.New(pdfwrite.Meta{Title: baseOf(path), Producer: "GOEDIT.ELF"})
	for p := 0; p < pages; p++ {
		body := rows[p*exportPageRows:]
		if len(body) > exportPageRows {
			body = body[:exportPageRows]
		}
		lines := make([]string, 0, exportFooterRow+1)
		lines = append(lines, body...)
		for len(lines) < exportFooterRow {
			lines = append(lines, "")
		}
		lines = append(lines, exportFooter(p+1, pages))
		if _, err := d.AddTextPage(lines, pdfwrite.TextOptions{
			Scale: 1, Left: exportLeft, Top: exportTop, LineAdvance: exportLead,
		}); err != nil {
			return e.exportRefuse(err.Error()[len("pdfwrite: "):])
		}
	}
	out, err := d.Bytes()
	if err != nil {
		return e.exportRefuse(err.Error()[len("pdfwrite: "):])
	}
	if rc := bufWrite(path, out); rc < 0 {
		return e.exportRefuse("rc=" + vi.Itoa64(rc))
	}
	vi.ConsoleLine(markerExport + path + " pages=" + vi.Itoa64(int64(pages)) +
		" bytes=" + vi.Itoa64(int64(len(out))))
	return true
}
