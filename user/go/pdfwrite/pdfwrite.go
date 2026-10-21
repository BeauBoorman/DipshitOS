// Package pdfwrite writes bounded PDF documents inside the ADR 0040
// reader subset: Letter pages, classic xref, one uncolored Type 3 font
// whose CharProcs are font8x8 glyph rectangles, DeviceRGB/DeviceGray
// 8-bit image XObjects and FlateDecode streams from the owned encoder in
// deflate.go. Every input that cannot become a conforming document is a
// named refusal, never a silently different file.
package pdfwrite

import (
	"errors"
	"time"
)

const (
	// Letter at the reader's fixed 96 dpi: 612x792 pt maps to exact pixels.
	PageWidth  = 816
	PageHeight = 1056

	letterPtW = 612
	letterPtH = 792

	maxPages    = 64         // under the reader's 256
	maxOutput   = 4_194_304  // the reader's MaxSource
	maxDecoded  = 16_777_216 // all streams expanded, the reader's per-call cap
	maxCommands = 8_192      // the reader's normalized commands per page call
	maxMetaText = 4_000      // decoded bytes per Info string
	maxImageW   = 1_024
	maxImageH   = 1_536
)

var (
	ErrPageTooLarge = errors.New("pdfwrite: page_too_large")
	ErrTooManyPages = errors.New("pdfwrite: too_many_pages")
	ErrOutputBudget = errors.New("pdfwrite: output_over_budget")
	ErrBadRaster    = errors.New("pdfwrite: bad_raster")
)

type Meta struct {
	Title    string
	Producer string
	// Now supplies CreationDate; nil uses time.Now. Tests inject a fixed
	// clock for deterministic output.
	Now func() time.Time
}

// TextOptions places monospace font8x8 cells on a page. All units are
// 96-dpi device pixels. Scale is device pixels per font pixel (glyphs are
// 8*Scale px cells); Left and Top are the first cell's top-left origin;
// LineAdvance is the distance between successive rows and defaults to the
// cell height.
type TextOptions struct {
	Scale       int
	Left        int
	Top         int
	LineAdvance int
}

type raster struct {
	samples []byte
	w, h    int
	gray    bool
}

type page struct {
	content []byte
	raster  *raster
	font    bool
	counts  [128]uint32 // shown-glyph frequencies after '?' substitution
}

type Document struct {
	meta    Meta
	pages   []page
	decoded int64
}

func New(meta Meta) *Document {
	return &Document{meta: meta}
}

// AddTextPage appends a page of text lines drawn with the Type 3 font8x8
// font. Bytes outside 0x20-0x7E are drawn as '?' and counted in the
// returned substitution count.
func (d *Document) AddTextPage(lines []string, opts TextOptions) (int, error) {
	if len(d.pages) >= maxPages {
		return 0, ErrTooManyPages
	}
	scale, advance := opts.Scale, opts.LineAdvance
	if scale == 0 {
		scale = 1
	}
	if advance == 0 {
		advance = 8 * scale
	}
	if scale < 1 || scale > PageHeight || advance < 1 || advance > PageHeight ||
		opts.Left < 0 || opts.Left > PageWidth || opts.Top < 0 || opts.Top > PageHeight {
		return 0, ErrPageTooLarge
	}
	cell := 8 * scale
	if cell > PageHeight || opts.Top > PageHeight-cell {
		return 0, ErrPageTooLarge
	}
	if len(lines) > 0 && len(lines)-1 > (PageHeight-cell-opts.Top)/advance {
		return 0, ErrPageTooLarge
	}
	subs := 0
	var p page
	var content []byte
	content = append(content, "BT /F1 "...)
	content = quarter(content, 3*int64(scale))
	content = append(content, " Tf "...)
	content = quarter(content, 3*int64(advance))
	content = append(content, " TL 1 0 0 1 "...)
	content = quarter(content, 3*int64(opts.Left))
	content = append(content, ' ')
	content = quarter(content, 4*letterPtH-3*int64(opts.Top)-24*int64(scale))
	content = append(content, " Tm"...)
	for i, line := range lines {
		if int64(len(line))*int64(cell) > int64(PageWidth-opts.Left) {
			return 0, ErrPageTooLarge
		}
		if i > 0 {
			content = append(content, " T*"...)
		}
		if line == "" {
			continue
		}
		content = append(content, " <"...)
		for j := 0; j < len(line); j++ {
			b := line[j]
			if b < 0x20 || b > 0x7e {
				b = '?'
				subs++
			}
			p.counts[b]++
			const digits = "0123456789abcdef"
			content = append(content, digits[b>>4], digits[b&15])
		}
		content = append(content, "> Tj"...)
	}
	content = append(content, " ET"...)
	if len(lines) == 0 {
		content = nil
	}
	// Every stream is decoded once during the reader's whole-document
	// validation and again while rendering its page; charge twice.
	if 2*int64(len(content)) > maxDecoded-d.decoded {
		return 0, ErrOutputBudget
	}
	d.decoded += 2 * int64(len(content))
	p.content = content
	p.font = len(lines) > 0
	d.pages = append(d.pages, p)
	return subs, nil
}

// AddRasterPage appends a page showing an 8-bit DeviceRGB image stretched
// over the full Letter page. rgb must hold w*h*3 samples. A 816x1056
// raster lands on the reader's pixels exactly one-to-one.
func (d *Document) AddRasterPage(rgb []byte, w, h int) error {
	return d.addRaster(raster{samples: rgb, w: w, h: h})
}

// AddGrayPage is AddRasterPage for 8-bit DeviceGray samples (w*h bytes).
func (d *Document) AddGrayPage(gray []byte, w, h int) error {
	return d.addRaster(raster{samples: gray, w: w, h: h, gray: true})
}

func (d *Document) addRaster(r raster) error {
	if len(d.pages) >= maxPages {
		return ErrTooManyPages
	}
	if r.w < 1 || r.h < 1 || r.w > maxImageW || r.h > maxImageH {
		return ErrBadRaster
	}
	channels := int64(3)
	if r.gray {
		channels = 1
	}
	if int64(len(r.samples)) != int64(r.w)*int64(r.h)*channels {
		return ErrBadRaster
	}
	if 2*int64(len(r.samples))+64 > maxDecoded-d.decoded {
		return ErrOutputBudget
	}
	d.decoded += 2*int64(len(r.samples)) + 64
	d.pages = append(d.pages, page{
		content: []byte("q 612 0 0 792 0 0 cm /Im Do Q"),
		raster:  &r,
	})
	return nil
}
