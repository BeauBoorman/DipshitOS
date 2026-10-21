package pdfwrite

import (
	"bytes"
	"errors"
	"math/rand"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"virelai/pdf"
	"virelai/webrender/font"
)

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

func render(t *testing.T, src []byte, page int) pdf.Page {
	t.Helper()
	l := &pdf.Ledger{Max: pdf.MaxWork}
	p, _, f := pdf.Render(&memorySource{data: src}, page, make([]byte, pdf.ArenaBytes), l)
	if f.Code != pdf.OK {
		t.Fatalf("render page %d: %+v (%s)", page, f, f.Error())
	}
	if p.Width != PageWidth || p.Height != PageHeight || p.Stride != PageWidth {
		t.Fatalf("page %d geometry %dx%d stride %d", page, p.Width, p.Height, p.Stride)
	}
	return p
}

func fixedNow() time.Time { return time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC) }

func document(t *testing.T, build func(*Document)) []byte {
	t.Helper()
	d := New(Meta{Title: "pdfwrite test", Producer: "virelai pdfwrite test", Now: fixedNow})
	build(d)
	out, err := d.Bytes()
	if err != nil {
		t.Fatalf("Bytes: %v", err)
	}
	if !bytes.HasPrefix(out, []byte("%PDF-1.4\n")) {
		t.Fatal("bad header")
	}
	return out
}

// expectedText rasterizes the same grid the writer emits: cell (i,j)
// covers an 8*Scale px block whose bits come from font8x8, with '?' for
// bytes outside 0x20-0x7e.
func expectedText(t *testing.T, lines []string, opts TextOptions) []uint32 {
	t.Helper()
	pix := make([]uint32, PageWidth*PageHeight)
	for i := range pix {
		pix[i] = 0xffffffff
	}
	scale, advance := opts.Scale, opts.LineAdvance
	if scale == 0 {
		scale = 1
	}
	if advance == 0 {
		advance = 8 * scale
	}
	for row, line := range lines {
		for col := 0; col < len(line); col++ {
			b := line[col]
			if b < 0x20 || b > 0x7e {
				b = '?'
			}
			g := font.Font8x8[b-0x20]
			for r := 0; r < 8; r++ {
				for c := 0; c < 8; c++ {
					if g[r]>>c&1 == 0 {
						continue
					}
					for dy := 0; dy < scale; dy++ {
						for dx := 0; dx < scale; dx++ {
							y := opts.Top + row*advance + r*scale + dy
							x := opts.Left + col*8*scale + c*scale + dx
							pix[y*PageWidth+x] = 0xff000000
						}
					}
				}
			}
		}
	}
	return pix
}

func samePixels(t *testing.T, got pdf.Page, want []uint32) {
	t.Helper()
	if len(got.Pix) != len(want) {
		t.Fatalf("pixel count %d want %d", len(got.Pix), len(want))
	}
	for i := range want {
		if got.Pix[i] != want[i] {
			t.Fatalf("pixel %d (%d,%d): got %08x want %08x", i, i%PageWidth, i/PageWidth, got.Pix[i], want[i])
		}
	}
}

func TestTextPageRendersFont8x8(t *testing.T) {
	for _, opts := range []TextOptions{
		{},
		{Scale: 2, Left: 16, Top: 32, LineAdvance: 20},
		{Scale: 3, Left: 4, Top: 8, LineAdvance: 24},
		{Scale: 1, Left: 48, Top: 48, LineAdvance: 12},
	} {
		lines := []string{
			"Hi, OS!",
			"",
			"AB\tCD",
			"\x00\x80\xff",
		}
		var subs int
		src := document(t, func(d *Document) {
			var err error
			subs, err = d.AddTextPage(lines, opts)
			if err != nil {
				t.Fatalf("AddTextPage: %v", err)
			}
		})
		if subs != 4 {
			t.Fatalf("substitutions %d want 4", subs)
		}
		p := render(t, src, 0)
		samePixels(t, p, expectedText(t, lines, opts))
	}
}

func TestRasterPageExact(t *testing.T) {
	rng := rand.New(rand.NewSource(4))
	rgb := make([]byte, PageWidth*PageHeight*3)
	rng.Read(rgb)
	src := document(t, func(d *Document) {
		if err := d.AddRasterPage(rgb, PageWidth, PageHeight); err != nil {
			t.Fatalf("AddRasterPage: %v", err)
		}
	})
	p := render(t, src, 0)
	for i := 0; i < PageWidth*PageHeight; i++ {
		want := uint32(0xff000000) | uint32(rgb[3*i])<<16 | uint32(rgb[3*i+1])<<8 | uint32(rgb[3*i+2])
		if p.Pix[i] != want {
			t.Fatalf("pixel %d: got %08x want %08x", i, p.Pix[i], want)
		}
	}
}

func TestRasterPageScaledAndGray(t *testing.T) {
	// The reader's nearest-neighbor rule: source row 0 is the top, and
	// pixel-center samples tie toward the higher index.
	rgb := []byte{
		255, 0, 0, 0, 255, 0, 0, 0, 255,
		255, 255, 0, 0, 255, 255, 255, 0, 255,
	}
	gray := []byte{0, 85, 170, 255}
	src := document(t, func(d *Document) {
		if err := d.AddRasterPage(rgb, 3, 2); err != nil {
			t.Fatal(err)
		}
		if err := d.AddGrayPage(gray, 2, 2); err != nil {
			t.Fatal(err)
		}
	})
	p := render(t, src, 0)
	for y := 0; y < PageHeight; y++ {
		sy := int((float64(y) + 0.5) / PageHeight * 2)
		for x := 0; x < PageWidth; x++ {
			sx := int((float64(x) + 0.5) / PageWidth * 3)
			i := 3 * (sy*3 + sx)
			want := uint32(0xff000000) | uint32(rgb[i])<<16 | uint32(rgb[i+1])<<8 | uint32(rgb[i+2])
			if p.Pix[y*PageWidth+x] != want {
				t.Fatalf("(%d,%d): got %08x want %08x", x, y, p.Pix[y*PageWidth+x], want)
			}
		}
	}
	p = render(t, src, 1)
	for y := 0; y < PageHeight; y++ {
		sy := int((float64(y) + 0.5) / PageHeight * 2)
		for x := 0; x < PageWidth; x++ {
			sx := int((float64(x) + 0.5) / PageWidth * 2)
			g := uint32(gray[sy*2+sx])
			want := uint32(0xff000000) | g<<16 | g<<8 | g
			if p.Pix[y*PageWidth+x] != want {
				t.Fatalf("gray (%d,%d): got %08x want %08x", x, y, p.Pix[y*PageWidth+x], want)
			}
		}
	}
}

func TestMultiPageDocument(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	rgb := make([]byte, 8*8*3)
	rng.Read(rgb)
	src := document(t, func(d *Document) {
		if _, err := d.AddTextPage([]string{"page one"}, TextOptions{Left: 8, Top: 8}); err != nil {
			t.Fatal(err)
		}
		if err := d.AddRasterPage(rgb, 8, 8); err != nil {
			t.Fatal(err)
		}
		if _, err := d.AddTextPage([]string{"page three"}, TextOptions{Left: 8, Top: 8}); err != nil {
			t.Fatal(err)
		}
		if _, err := d.AddTextPage(nil, TextOptions{}); err != nil {
			t.Fatal(err)
		}
	})
	for page := 0; page < 4; page++ {
		p := render(t, src, page)
		switch page {
		case 0, 2:
			samePixels(t, p, expectedText(t, []string{map[int]string{0: "page one", 2: "page three"}[page]}, TextOptions{Left: 8, Top: 8}))
		case 1:
			want := uint32(0xff000000) | uint32(rgb[0])<<16 | uint32(rgb[1])<<8 | uint32(rgb[2])
			if p.Pix[0] != want {
				t.Fatalf("raster corner: got %08x want %08x", p.Pix[0], want)
			}
		case 3:
			for _, px := range p.Pix {
				if px != 0xffffffff {
					t.Fatal("empty page not white")
				}
			}
		}
	}
}

func TestNamedRefusals(t *testing.T) {
	for _, test := range []struct {
		name string
		add  func(*Document) error
		want error
	}{
		{"line too wide", func(d *Document) error {
			_, err := d.AddTextPage([]string{strings.Repeat("x", 200)}, TextOptions{})
			return err
		}, ErrPageTooLarge},
		{"too many lines", func(d *Document) error {
			lines := make([]string, 200)
			for i := range lines {
				lines[i] = "x"
			}
			_, err := d.AddTextPage(lines, TextOptions{})
			return err
		}, ErrPageTooLarge},
		{"negative origin", func(d *Document) error {
			_, err := d.AddTextPage([]string{"x"}, TextOptions{Left: -1})
			return err
		}, ErrPageTooLarge},
		{"bad scale", func(d *Document) error {
			_, err := d.AddTextPage([]string{"x"}, TextOptions{Scale: -2})
			return err
		}, ErrPageTooLarge},
		{"raster length", func(d *Document) error {
			return d.AddRasterPage([]byte{1, 2, 3}, 2, 2)
		}, ErrBadRaster},
		{"raster dims", func(d *Document) error {
			return d.AddRasterPage(nil, 0, 4)
		}, ErrBadRaster},
		{"raster too big", func(d *Document) error {
			return d.AddRasterPage(make([]byte, 3*1025), 1025, 1)
		}, ErrBadRaster},
		{"gray length", func(d *Document) error {
			return d.AddGrayPage([]byte{1, 2, 3}, 2, 2)
		}, ErrBadRaster},
	} {
		d := New(Meta{})
		if err := test.add(d); !errors.Is(err, test.want) {
			t.Fatalf("%s: got %v want %v", test.name, err, test.want)
		}
	}

	d := New(Meta{})
	for i := 0; i < maxPages; i++ {
		if _, err := d.AddTextPage([]string{"x"}, TextOptions{}); err != nil {
			t.Fatalf("page %d: %v", i, err)
		}
	}
	if _, err := d.AddTextPage([]string{"x"}, TextOptions{}); !errors.Is(err, ErrTooManyPages) {
		t.Fatalf("page 65: %v", err)
	}
	if err := d.AddRasterPage([]byte{0, 0, 0}, 1, 1); !errors.Is(err, ErrTooManyPages) {
		t.Fatalf("raster page 65: %v", err)
	}

	// Two incompressible full-page rasters fit the expansion bound but not
	// the 4 MiB output bound.
	rng := rand.New(rand.NewSource(1))
	rgb := make([]byte, PageWidth*PageHeight*3)
	rng.Read(rgb)
	d = New(Meta{})
	for i := 0; i < 2; i++ {
		if err := d.AddRasterPage(rgb, PageWidth, PageHeight); err != nil {
			t.Fatalf("raster %d: %v", i, err)
		}
	}
	if _, err := d.Bytes(); !errors.Is(err, ErrOutputBudget) {
		t.Fatalf("over-budget Bytes: %v", err)
	}

	// Blank rasters stay under the 4 MiB output bound but cross the
	// doubled expansion bound on the fourth page.
	d = New(Meta{})
	blank := make([]byte, PageWidth*PageHeight*3)
	for i := 0; i < 3; i++ {
		if err := d.AddRasterPage(blank, PageWidth, PageHeight); err != nil {
			t.Fatalf("expansion raster %d: %v", i, err)
		}
	}
	if err := d.AddRasterPage(blank, PageWidth, PageHeight); !errors.Is(err, ErrOutputBudget) {
		t.Fatalf("expansion raster 4: %v", err)
	}

	// A page whose glyph expansion alone exceeds the normalized-command
	// bound refuses page_too_large before any output exists.
	d = New(Meta{})
	wide := strings.Repeat("x", 102)
	lines := make([]string, 12)
	for i := range lines {
		lines[i] = wide
	}
	if _, err := d.AddTextPage(lines, TextOptions{}); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Bytes(); !errors.Is(err, ErrPageTooLarge) && !errors.Is(err, ErrOutputBudget) {
		t.Fatalf("command budget: %v", err)
	}

	d = New(Meta{Title: strings.Repeat("t", maxMetaText+1)})
	if _, err := d.Bytes(); !errors.Is(err, ErrOutputBudget) {
		t.Fatalf("meta over budget: %v", err)
	}
}

func TestSixtyFourPageDocument(t *testing.T) {
	d := New(Meta{Now: fixedNow})
	rgb := make([]byte, 8*8*3)
	for i := range rgb {
		rgb[i] = byte(i)
	}
	for i := 0; i < maxPages; i++ {
		if err := d.AddRasterPage(rgb, 8, 8); err != nil {
			t.Fatal(i, err)
		}
	}
	out, err := d.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	p := render(t, out, maxPages-1)
	if want := uint32(0xff000000) | uint32(rgb[0])<<16 | uint32(rgb[1])<<8 | uint32(rgb[2]); p.Pix[0] != want {
		t.Fatalf("last page corner %08x want %08x", p.Pix[0], want)
	}
}

// authoredFixture is the deterministic document committed under testdata/.
func authoredFixture() []byte {
	d := New(Meta{Title: "VirelaiOS pdfwrite smoke", Producer: "virelai pdfwrite", Now: fixedNow})
	if _, err := d.AddTextPage([]string{
		"pdfwrite",
		"smoke",
		"A1\x00\x9c",
	}, TextOptions{Left: 32, Top: 32, LineAdvance: 16}); err != nil {
		panic(err)
	}
	rgb := make([]byte, 24*18*3)
	for y := 0; y < 18; y++ {
		for x := 0; x < 24; x++ {
			i := 3 * (y*24 + x)
			rgb[i] = byte(32 + 8*x)
			rgb[i+1] = byte(48 + 9*y)
			rgb[i+2] = byte(160 + 2*(x+y))
		}
	}
	if err := d.AddRasterPage(rgb, 24, 18); err != nil {
		panic(err)
	}
	out, err := d.Bytes()
	if err != nil {
		panic(err)
	}
	return out
}

func TestCommittedFixture(t *testing.T) {
	committed, err := os.ReadFile("testdata/smoke.pdf")
	if err != nil {
		t.Skip("testdata/smoke.pdf not yet authored")
	}
	if !bytes.Equal(committed, authoredFixture()) {
		t.Fatal("testdata/smoke.pdf differs from authoredFixture output")
	}
	for page := 0; page < 2; page++ {
		render(t, committed, page)
	}
}

func TestAuthorFixture(t *testing.T) {
	if os.Getenv("PDFWRITE_AUTHOR_FIXTURE") != "1" {
		return
	}
	if err := os.MkdirAll("testdata", 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join("testdata", "smoke.pdf"), authoredFixture(), 0644); err != nil {
		t.Fatal(err)
	}
}

// TestCgrenderReport cross-checks the committed fixture against the
// CoreGraphics outside reference (ADR 0040 A2.1). It runs when
// PDFWRITE_CGRENDER_BGRA names a cgrender output file and writes a
// difference report to PDFWRITE_REPORT.
func TestCgrenderReport(t *testing.T) {
	bgraPath, reportPath := os.Getenv("PDFWRITE_CGRENDER_BGRA"), os.Getenv("PDFWRITE_REPORT")
	if bgraPath == "" {
		return
	}
	pageIndex, _ := strconv.Atoi(os.Getenv("PDFWRITE_CGRENDER_PAGE"))
	fixture, err := os.ReadFile("testdata/smoke.pdf")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(bgraPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) < 16 || string(raw[:4]) != "PDF1" {
		t.Fatal("not a PDF1 product")
	}
	word := func(i int) int { return int(raw[i]) | int(raw[i+1])<<8 | int(raw[i+2])<<16 | int(raw[i+3])<<24 }
	w, h, stride := word(4), word(8), word(12)
	if w != PageWidth || h != PageHeight || stride != PageWidth || len(raw) != 16+4*w*h {
		t.Fatalf("cgrender geometry %dx%d stride %d len %d", w, h, stride, len(raw))
	}
	p := render(t, fixture, pageIndex)
	var mismatch, maxDiff, sum int64
	var first strings.Builder
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			i := y*w + x
			cg := raw[16+4*i:]
			want := [3]uint32{uint32(cg[2]), uint32(cg[1]), uint32(cg[0])}
			ours := p.Pix[i]
			got := [3]uint32{ours >> 16 & 0xff, ours >> 8 & 0xff, ours & 0xff}
			for c := 0; c < 3; c++ {
				d := int64(got[c]) - int64(want[c])
				if d < 0 {
					d = -d
				}
				if d == 0 {
					continue
				}
				if mismatch < 8 {
					if mismatch > 0 {
						first.WriteString(",")
					}
					first.WriteString(strconv.Itoa(x) + "," + strconv.Itoa(y))
				}
				mismatch++
				if d > maxDiff {
					maxDiff = d
				}
				sum += d
			}
		}
	}
	var b strings.Builder
	b.WriteString("pdfwrite cgrender cross-check\n")
	b.WriteString("fixture: user/go/pdfwrite/testdata/smoke.pdf page " + strconv.Itoa(pageIndex+1) + "\n")
	b.WriteString("reference: tools/pdf-proof/cgrender.swift (CoreGraphics, 96 dpi)\n")
	b.WriteString("ours: user/go/pdf Render of the same bytes\n\n")
	b.WriteString("pixels compared: " + strconv.Itoa(w*h) + "\n")
	b.WriteString("channel diffs: " + strconv.FormatInt(mismatch, 10) + "\n")
	b.WriteString("max channel diff: " + strconv.FormatInt(maxDiff, 10) + "/255\n")
	b.WriteString("mean channel diff: " + strconv.FormatFloat(float64(sum)/float64(3*w*h), 'f', 6, 64) + "/255\n")
	b.WriteString("first diffs (x,y): " + first.String() + "\n")
	if reportPath != "" {
		if err := os.WriteFile(reportPath, []byte(b.String()), 0644); err != nil {
			t.Fatal(err)
		}
	}
	t.Logf("mismatch=%d maxDiff=%d", mismatch, maxDiff)
}
