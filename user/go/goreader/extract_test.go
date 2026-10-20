package main

import (
	"strings"
	"testing"

	"virelai/find"
)

// testPDF builds the same classic-xref document shape tools/pdf-proof's
// corpus.py authors: objects ascending, one xref, one trailer.
func testPDF(objects ...string) []byte {
	var b strings.Builder
	b.WriteString("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
	offs := make([]int, len(objects)+1)
	for i, obj := range objects {
		offs[i+1] = b.Len()
		b.WriteString(itoa(i + 1))
		b.WriteString(" 0 obj\n")
		b.WriteString(obj)
		b.WriteString("\nendobj\n")
	}
	xref := b.Len()
	b.WriteString("xref\n0 ")
	b.WriteString(itoa(len(offs)))
	b.WriteString("\n0000000000 65535 f \n")
	for _, o := range offs[1:] {
		var row [10]byte
		for j := 9; j >= 0; j-- {
			row[j] = byte('0' + o%10)
			o /= 10
		}
		b.Write(row[:])
		b.WriteString(" 00000 n \n")
	}
	b.WriteString("trailer\n<< /Size ")
	b.WriteString(itoa(len(offs)))
	b.WriteString(" /Root 1 0 R >>\nstartxref\n")
	b.WriteString(itoa(xref))
	b.WriteString("\n%%EOF\n")
	return []byte(b.String())
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [12]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

func testStream(data string) string {
	return "<< /Length " + itoa(len(data)) + " >>\nstream\n" + data + "\nendstream"
}

// testFont returns a Type3 font whose Differences cover space plus A–Z,
// every charproc a 1-unit-wide unit square — the shape corpus.py's text()
// helper authors for the proof suite.
func testFont(firstObj int) []string {
	var names []string
	names = append(names, "/Space")
	for c := 'A'; c <= 'Z'; c++ {
		names = append(names, "/"+string(c))
	}
	var diffs strings.Builder
	diffs.WriteString("[32 /Space 65")
	for c := 'A'; c <= 'Z'; c++ {
		diffs.WriteString(" /")
		diffs.WriteString(string(c))
	}
	diffs.WriteString("]")
	var procs strings.Builder
	for i, nm := range names {
		procs.WriteString(nm)
		procs.WriteString(" ")
		procs.WriteString(itoa(firstObj + 1 + i))
		procs.WriteString(" 0 R ")
	}
	widths := strings.Repeat("1 ", 59) // FirstChar 32 .. LastChar 90
	font := "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] " +
		"/FontMatrix [1 0 0 1 0 0] /CharProcs << " + procs.String() + " >> " +
		"/Encoding << /Type /Encoding /Differences " + diffs.String() +
		" >> /FirstChar 32 /LastChar 90 /Widths [" + widths + "] " +
		"/Resources << >> /Name /Authored >>"
	out := []string{font}
	for range names {
		out = append(out, testStream("1 0 0 0 1 1 d1 0 0 m 1 0 l .5 1 l h f"))
	}
	return out
}

// twoPageTextDoc authors a 2-page 96x72pt (128x96px) document: page 1 says
// ALPHA PAGE, page 2 says THE ZOOKEEPER SANG — the find target.
func twoPageTextDoc() []byte {
	font := testFont(7) // font object 7, charprocs 8..34
	objs := []string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 96 72] " +
			"/Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>",
		testStream("BT /F1 6 Tf 1 0 0 1 4 60 Tm (ALPHA PAGE) Tj ET"),
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 96 72] " +
			"/Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>",
		testStream("BT /F1 6 Tf 1 0 0 1 4 60 Tm (THE ZOOKEEPER SANG) Tj ET"),
	}
	objs = append(objs, font...)
	return testPDF(objs...)
}

func TestXindexAndObjects(t *testing.T) {
	doc := twoPageTextDoc()
	x := xindex(doc)
	if x.err {
		t.Fatal("xref index failed")
	}
	if len(x.body) != 35 {
		t.Fatalf("objects = %d want 35", len(x.body))
	}
	cat, ok := x.obj(1)
	if !ok || cat.k != vDict {
		t.Fatal("catalog parse")
	}
	if ty := xget(cat, "Type"); ty.k != vName || !eqs(ty.b, "Catalog") {
		t.Fatal("catalog type")
	}
	stream, ok := x.objStream(4, intPtr(xMaxDecoded))
	if !ok || !strings.Contains(string(stream), "ALPHA") {
		t.Fatalf("content stream = %q", stream)
	}
}

func intPtr(v int) *int { return &v }

func TestExtractPagesText(t *testing.T) {
	pages := extractPages(twoPageTextDoc())
	if len(pages) != 2 {
		t.Fatalf("pages = %d want 2", len(pages))
	}
	if got := string(pages[0].text); got != "ALPHA PAGE" {
		t.Fatalf("page 1 text = %q", got)
	}
	if got := string(pages[1].text); got != "THE ZOOKEEPER SANG" {
		t.Fatalf("page 2 text = %q", got)
	}
	// Positions: "ZOOKEEPER" starts at char 4 of page 2 — the band sits at
	// Tm x = 4pt + 4 glyphs * 6pt = 28pt -> 37px at 96 dpi, baseline 60pt
	// -> the band's top near y=8px.
	hits := find.All(pages[1].text, []byte("ZOOKEEPER"))
	if len(hits) != 1 || hits[0] != 4 {
		t.Fatalf("hits = %v", hits)
	}
	rs := mergeHitRects(pages[1].glyphs, hits[0], hits[0]+9)
	if len(rs) == 0 {
		t.Fatal("no hit rect")
	}
	r := rs[0]
	if r.X0 < 30 || r.X0 > 44 || r.X1 < 95 || r.X1 > 120 {
		t.Fatalf("hit band x = [%d,%d) want inside [30,44)..[95,120)", r.X0, r.X1)
	}
	if r.Y0 < 0 || r.Y0 > 20 || r.Y1 < r.Y0 || r.Y1 > 30 {
		t.Fatalf("hit band y = [%d,%d) want near 8..16", r.Y0, r.Y1)
	}
}

func TestExtractDegrades(t *testing.T) {
	// A non-PDF or structurally-off source yields no text, never a crash.
	if pages := extractPages([]byte("not a pdf")); pages != nil {
		t.Fatal("garbage must extract to nothing")
	}
	// A page without fonts still parses to empty text.
	doc := testPDF(
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 48 48] /Contents 4 0 R >>",
		testStream("0 g 3 3 12 12 re f"),
	)
	pages := extractPages(doc)
	if len(pages) != 1 || len(pages[0].text) != 0 {
		t.Fatalf("picture page = %+v", pages)
	}
}
