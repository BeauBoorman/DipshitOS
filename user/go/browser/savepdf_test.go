package main

import (
	"bytes"
	"testing"

	"virelai/pdf"
	"virelai/pdfwrite"
	"virelai/webrender"
)

// M153e (#2925): the save-as .pdf leg — name dispatch, the 1280->1024
// slice arithmetic (independent of strip boundaries), the 16-page and
// pdfwrite-budget refusals, and a fixture page round-tripped through
// user/go/pdf against its own written raster.

type pdfMemorySource struct{ data []byte }

func (s *pdfMemorySource) Length() int64 { return int64(len(s.data)) }
func (s *pdfMemorySource) ReadAt(dst []byte, off int64, l *pdf.Ledger) (int, pdf.Code) {
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

func TestIsPDFName(t *testing.T) {
	for _, test := range []struct {
		path string
		want bool
	}{
		{"/host/WEBSAVE.PDF", true},
		{"/host/notes.pdf", true},
		{"/host/Mix.PdF", true},
		{"/host/WEBSAVE.HTML", false},
		{"/host/PDF", false},
		{"/host/x.pdfx", false},
		{"", false},
		{".pdf", true},
	} {
		if got := isPDFName(test.path); got != test.want {
			t.Fatalf("isPDFName(%q)=%v want %v", test.path, got, test.want)
		}
	}
}

// rectLayout builds a synthetic layout: ColorPageBg everywhere except a
// solid full-width rect over [y0, y1) — enough to prove page slicing and
// the 5:4 sample without a font or a DOM.
func rectLayout(height, y0, y1 int, rgb uint32) *webrender.Layout {
	l := &webrender.Layout{Width: contentW, Height: height, Text: webrender.Bitmap{}}
	l.Items = []webrender.Item{{
		Kind: webrender.ItemRect, X: 0, Y: y0, W: contentW, H: y1 - y0, Bg: rgb,
	}}
	return l
}

func pdfSlice(t *testing.T, l *webrender.Layout, p int) []byte {
	t.Helper()
	dst := make([]byte, pdfRasterW*pdfPageRows*3)
	pdfPageSlice(l, p, dst, make([]uint32, contentW*pdfStripRows))
	return dst
}

func dstRGB(dst []byte, x, y int) (byte, byte, byte) {
	i := 3 * (y*pdfRasterW + x)
	return dst[i], dst[i+1], dst[i+2]
}

func TestPDFSliceArithmetic(t *testing.T) {
	bg := webrender.ColorPageBg
	// A red band spanning the strip seam (415) and the page seam (1655):
	// source rows [400, 1700) -> page 0 dst rows [320, 1324) and page 1
	// dst rows [0, ~36). No strip boundary may drop or double a row.
	l := rectLayout(2000, 400, 1700, 0xff2244)
	page0 := pdfSlice(t, l, 0)
	for _, y := range []int{320, 414, 415, 416, 660, 1055, 1323} {
		if r, g, b := dstRGB(page0, 512, y); r != 0xff || g != 0x22 || b != 0x44 {
			t.Fatalf("page0 row %d: got %02x%02x%02x want the rect", y, r, g, b)
		}
	}
	for _, y := range []int{0, 100, 310} {
		r, g, b := dstRGB(page0, 512, y)
		got := uint32(r)<<16 | uint32(g)<<8 | uint32(b)
		if got != bg&0xffffff {
			t.Fatalf("page0 row %d: got %06x want page bg %06x", y, got, bg&0xffffff)
		}
	}
	// The rect's bottom edge (src 1700) lands mid-page-1; below it is bg.
	page1 := pdfSlice(t, l, 1)
	r, g, b := dstRGB(page1, 512, 10)
	if r != 0xff || g != 0x22 || b != 0x44 {
		t.Fatalf("page1 top: got %02x%02x%02x want the rect's continuation", r, g, b)
	}
	r, g, b = dstRGB(page1, 512, 400)
	if got := uint32(r)<<16 | uint32(g)<<8 | uint32(b); got != bg&0xffffff {
		t.Fatalf("page1 row 400: got %06x want page bg past the doc", got)
	}
	// Every dst row is written exactly once: a second slice over fresh
	// bytes reproduces the identical raster.
	if again := pdfSlice(t, l, 0); !bytes.Equal(page0, again) {
		t.Fatal("page slice not deterministic")
	}
}

func TestPDFPageBounds(t *testing.T) {
	// No document at all: a named refusal, never an empty file.
	a := &app{}
	if _, _, why := a.renderPDF(); why != "document" {
		t.Fatalf("no-layout why=%q want document", why)
	}
	// Over the 16-page card bound the leg refuses before pdfwrite runs.
	a.lay = rectLayout(pdfMaxPages*pdfSrcRows+1, 0, 0, 0)
	if _, _, why := a.renderPDF(); why != "pages" {
		t.Fatalf("17-page why=%q want pages", why)
	}
	// Dense color slices exceed the writer's decoded budget on the third
	// page: the named refusal rides out instead of a torn file.
	a.lay = rectLayout(3*pdfSrcRows, 0, 3*pdfSrcRows, 0x102030)
	if _, _, why := a.renderPDF(); why != "bytes" {
		t.Fatalf("over-budget why=%q want bytes", why)
	}
}

func TestPDFSaveRoundTrip(t *testing.T) {
	body := []byte(`<html><head><title>Round Trip Page</title></head><body>` +
		`<h1>Heading one</h1>` +
		`<p>A paragraph long enough to wrap across at least two lines inside ` +
		`the twelve-eighty layout column, for the raster to carry.</p>` +
		`<pre>pre block</pre><hr><p>tail</p></body></html>`)
	a := &app{hist: newHistory(), text: webrender.Bitmap{}, target: "/host/RT.HTML"}
	a.loadBody(body, a.target)
	if a.lay == nil {
		t.Fatal("fixture did not lay out")
	}
	data, pages, why := a.renderPDF()
	if why != "" {
		t.Fatalf("renderPDF refused: %s", why)
	}
	if pages != (a.lay.Height+pdfSrcRows-1)/pdfSrcRows {
		t.Fatalf("pages=%d want ceil(height %d / %d)", pages, a.lay.Height, pdfSrcRows)
	}
	if !bytes.HasPrefix(data, []byte("%PDF-1.4\n")) {
		t.Fatal("no PDF header")
	}
	if !bytes.Contains(data, []byte("(Round Trip Page)")) {
		t.Fatal("PDF Info lost the document <title>")
	}
	// The writer's own reader renders page 1 back to 816x1056 px; the
	// document must survive the trip within the named tolerance (the
	// reader's documented nearest-neighbor rule — center samples tie
	// toward the higher index — makes interior pixels exact; a small
	// bound absorbs only the boundary rows).
	l := &pdf.Ledger{Max: pdf.MaxWork}
	page, _, f := pdf.Render(&pdfMemorySource{data: data}, 0,
		make([]byte, pdf.ArenaBytes), l)
	if f.Code != pdf.OK {
		t.Fatalf("reader refused the written file: %+v", f)
	}
	if page.Width != pdfwrite.PageWidth || page.Height != pdfwrite.PageHeight {
		t.Fatalf("page geometry %dx%d", page.Width, page.Height)
	}
	src := pdfSlice(t, a.lay, 0)
	const tol = 8 // per-channel, against the source slice's own samples
	var diffs, maxDiff int64
	for y := 0; y < pdfwrite.PageHeight; y++ {
		sy := int((float64(y) + 0.5) / pdfwrite.PageHeight * pdfPageRows)
		for x := 0; x < pdfwrite.PageWidth; x++ {
			sx := int((float64(x) + 0.5) / pdfwrite.PageWidth * pdfRasterW)
			sr, sg, sb := dstRGB(src, sx, sy)
			got := page.Pix[y*page.Stride+x]
			for c, want := range [3]int64{int64(sr), int64(sg), int64(sb)} {
				d := int64((got>>(16-8*c))&0xff) - want
				if d < 0 {
					d = -d
				}
				if d > tol {
					diffs++
				}
				if d > maxDiff {
					maxDiff = d
				}
			}
		}
	}
	if diffs != 0 {
		t.Fatalf("%d channel diffs past tolerance (max %d/255)", diffs, maxDiff)
	}
	if page.Pix[0] != 0xff000000|uint32(webrender.ColorPageBg&0xffffff) {
		t.Fatalf("corner pixel %08x want the page background", page.Pix[0])
	}
}
