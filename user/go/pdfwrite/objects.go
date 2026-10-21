package pdfwrite

import (
	"errors"
	"strconv"
	"time"

	"virelai/webrender/font"
)

// quarter appends the decimal for numerator/4 points. Every writer
// coordinate is a quarter point, the exact 96-dpi pixel fraction, so no
// emitted number needs more than two decimal places.
func quarter(b []byte, numerator int64) []byte {
	v := numerator
	if v < 0 {
		v = -v
		b = append(b, '-')
	}
	b = strconv.AppendInt(b, v/4, 10)
	switch v % 4 {
	case 1:
		return append(b, ".25"...)
	case 2:
		return append(b, ".5"...)
	case 3:
		return append(b, ".75"...)
	}
	return b
}

// literal appends a PDF literal string for raw bytes. Readers cap decoded
// strings at 4096 bytes; octal escapes keep arbitrary input inside ASCII.
func literal(b, s []byte) []byte {
	b = append(b, '(')
	for _, c := range s {
		switch {
		case c == '(' || c == ')' || c == '\\':
			b = append(b, '\\', c)
		case c < 32 || c > 126:
			const oct = "01234567"
			b = append(b, '\\', oct[c>>6], oct[c>>3&7], oct[c&7])
		default:
			b = append(b, c)
		}
	}
	return append(b, ')')
}

func stream(dict string, raw []byte) []byte {
	compressed := deflateZlib(raw)
	b := make([]byte, 0, len(dict)+len(compressed)+64)
	b = append(b, "<< /Length "...)
	b = strconv.AppendInt(b, int64(len(compressed)), 10)
	b = append(b, " /Filter /FlateDecode"...)
	b = append(b, dict...)
	b = append(b, " >>\nstream\n"...)
	b = append(b, compressed...)
	return append(b, "\nendstream"...)
}

// glyphRects decomposes a font8x8 glyph into the greedy largest set-bit
// rectangles, each returned as x,y,w,h in glyph space with row 0 at the
// top (glyph y runs upward). Fewer rectangles keep the reader's
// normalized-command budget reachable.
func glyphRects(glyph [8]byte) [][4]int {
	var bits [8]byte
	copy(bits[:], glyph[:])
	var rects [][4]int
	for {
		best, area := [4]int{}, 0
		for y := 0; y < 8; y++ {
			for x := 0; x < 8; x++ {
				if bits[y]>>x&1 == 0 {
					continue
				}
				for w := 1; x+w <= 8; w++ {
					for h := 1; y+h <= 8; h++ {
						ok := true
						for r := y; r < y+h && ok; r++ {
							if bits[r]>>uint(x)&((1<<uint(w))-1) != (1<<uint(w))-1 {
								ok = false
							}
						}
						if ok && w*h > area {
							best, area = [4]int{x, y, w, h}, w*h
						}
					}
				}
			}
		}
		if area == 0 {
			return rects
		}
		x, y, w, h := best[0], best[1], best[2], best[3]
		for r := y; r < y+h; r++ {
			bits[r] &^= byte((1<<uint(x+w))-1) &^ byte((1<<uint(x))-1)
		}
		rects = append(rects, [4]int{x, 8 - y - h, w, h})
	}
}

// charProc is the Type 3 glyph program for one font8x8 glyph: each
// rectangle becomes `x y w h re` under one fill. All points stay inside
// the d1 box and FontBBox [0 0 8 8].
func charProc(glyph [8]byte) []byte {
	b := []byte("8 0 0 0 8 8 d1")
	rects := glyphRects(glyph)
	for _, r := range rects {
		b = append(b, ' ', byte('0'+r[0]), ' ', byte('0'+r[1]), ' ', byte('0'+r[2]), ' ', byte('0'+r[3]), ' ', 'r', 'e')
	}
	if len(rects) > 0 {
		b = append(b, " f"...)
	}
	return b
}

// Bytes assembles the whole document. The font is emitted once and only
// when at least one page selects it. Refusals happen before anything is
// returned: an over-budget document is never published as a prefix.
func (d *Document) Bytes() ([]byte, error) {
	if len(d.meta.Title) > maxMetaText || len(d.meta.Producer) > maxMetaText {
		return nil, ErrOutputBudget
	}
	// The Type 3 font is subset to the glyph codes actually shown, and the
	// reader's 8,192 normalized-command bound is accounted up front: every
	// font page's whole-document validation expands all CharProcs plus the
	// shown glyphs, and the rendered page expands them once more.
	var used [128]bool
	var procs [][]byte
	var codes []int
	var procsLen, procsCmds int64
	textPages := 0
	first, last := 0x20, 0x20
	for _, p := range d.pages {
		if !p.font {
			continue
		}
		textPages++
		for c := 0x20; c <= 0x7e; c++ {
			if p.counts[c] > 0 && !used[c] {
				used[c] = true
				proc := charProc(font.Font8x8[c-0x20])
				procsLen += int64(len(proc))
				procsCmds += int64(5 * len(glyphRects(font.Font8x8[c-0x20])))
				procs = append(procs, proc)
				codes = append(codes, c)
				if c < first {
					first = c
				}
				if c > last {
					last = c
				}
			}
		}
	}
	var total, worst int64
	for _, p := range d.pages {
		if !p.font {
			continue
		}
		var shown int64
		for c := 0x20; c <= 0x7e; c++ {
			if p.counts[c] > 0 {
				shown += int64(p.counts[c]) * int64(5*len(glyphRects(font.Font8x8[c-0x20])))
			}
		}
		cost := procsCmds + shown
		if cost > maxCommands {
			return nil, ErrPageTooLarge
		}
		total += cost
		if cost > worst {
			worst = cost
		}
	}
	if total+worst > maxCommands {
		return nil, ErrOutputBudget
	}

	// Object numbering: catalog, pages node, page dictionaries, optional
	// font + its CharProcs, per-page streams, Info last.
	n := 2 + len(d.pages)
	fontObj := 0
	if textPages > 0 {
		fontObj = n + 1
		n += 1 + len(procs)
	}
	contentObj := make([]int, len(d.pages))
	imageObj := make([]int, len(d.pages))
	for i, p := range d.pages {
		if len(p.content) > 0 {
			n++
			contentObj[i] = n
		}
		if p.raster != nil {
			n++
			imageObj[i] = n
		}
	}
	infoObj := n + 1
	n = infoObj

	// CharProcs are decoded once per font page during the reader's
	// whole-document validation and once more on a rendered text page.
	if procsLen*int64(textPages+1) > maxDecoded-d.decoded {
		return nil, ErrOutputBudget
	}

	bodies := make([][]byte, n+1)
	bodies[1] = []byte("<< /Type /Catalog /Pages 2 0 R >>")
	pages := []byte("<< /Type /Pages /Kids [")
	for i := range d.pages {
		pages = append(pages, ' ')
		pages = strconv.AppendInt(pages, int64(3+i), 10)
		pages = append(pages, " 0 R"...)
	}
	pages = append(pages, "] /Count "...)
	pages = strconv.AppendInt(pages, int64(len(d.pages)), 10)
	bodies[2] = append(pages, " /MediaBox [0 0 612 792] >>"...)
	for i, p := range d.pages {
		body := append([]byte("<< /Type /Page /Parent 2 0 R"), ' ')
		if len(p.content) > 0 {
			body = append(body, "/Contents "...)
			body = strconv.AppendInt(body, int64(contentObj[i]), 10)
			body = append(body, " 0 R "...)
		}
		if p.font {
			body = append(body, "/Resources << /Font << /F1 "...)
			body = strconv.AppendInt(body, int64(fontObj), 10)
			body = append(body, " 0 R >> >>"...)
		} else if p.raster != nil {
			body = append(body, "/Resources << /XObject << /Im "...)
			body = strconv.AppendInt(body, int64(imageObj[i]), 10)
			body = append(body, " 0 R >> >>"...)
		}
		bodies[3+i] = append(body, " >>"...)
		if len(p.content) > 0 {
			bodies[contentObj[i]] = stream("", p.content)
		}
		if p.raster != nil {
			dict := []byte("/Type /XObject /Subtype /Image /Width ")
			dict = strconv.AppendInt(dict, int64(p.raster.w), 10)
			dict = append(dict, " /Height "...)
			dict = strconv.AppendInt(dict, int64(p.raster.h), 10)
			if p.raster.gray {
				dict = append(dict, " /BitsPerComponent 8 /ColorSpace /DeviceGray"...)
			} else {
				dict = append(dict, " /BitsPerComponent 8 /ColorSpace /DeviceRGB"...)
			}
			bodies[imageObj[i]] = stream(string(dict), p.raster.samples)
		}
	}
	if textPages > 0 {
		f := []byte("<< /Type /Font /Subtype /Type3 /FontBBox [0 0 8 8] " +
			"/FontMatrix [1 0 0 1 0 0] /CharProcs <<")
		for i, c := range codes {
			f = append(f, " /g"...)
			f = strconv.AppendInt(f, int64(c), 10)
			f = append(f, ' ')
			f = strconv.AppendInt(f, int64(fontObj+1+i), 10)
			f = append(f, " 0 R"...)
		}
		f = append(f, " >> /Encoding << /Type /Encoding /Differences ["...)
		// Differences groups consecutive used codes so unshown codes in
		// [first,last] never acquire a named glyph.
		for i := 0; i < len(codes); {
			j := i
			for j+1 < len(codes) && codes[j+1] == codes[j]+1 {
				j++
			}
			f = strconv.AppendInt(f, int64(codes[i]), 10)
			for ; i <= j; i++ {
				f = append(f, " /g"...)
				f = strconv.AppendInt(f, int64(codes[i]), 10)
			}
			if i < len(codes) {
				f = append(f, ' ')
			}
		}
		f = append(f, "] >> /FirstChar "...)
		f = strconv.AppendInt(f, int64(first), 10)
		f = append(f, " /LastChar "...)
		f = strconv.AppendInt(f, int64(last), 10)
		f = append(f, " /Widths ["...)
		for c := first; c <= last; c++ {
			f = append(f, " 8"...)
		}
		bodies[fontObj] = append(f, "] >>"...)
		for i, p := range procs {
			body := append([]byte("<< /Length "), strconv.Itoa(len(p))...)
			body = append(body, " >>\nstream\n"...)
			body = append(body, p...)
			bodies[fontObj+1+i] = append(body, "\nendstream"...)
		}
	}
	now := time.Now()
	if d.meta.Now != nil {
		now = d.meta.Now()
	}
	info := []byte("<<")
	if d.meta.Title != "" {
		info = append(info, " /Title "...)
		info = literal(info, []byte(d.meta.Title))
	}
	producer := d.meta.Producer
	if producer == "" {
		producer = "virelai pdfwrite"
	}
	info = append(info, " /Producer "...)
	info = literal(info, []byte(producer))
	info = append(info, " /CreationDate (D:"...)
	info = now.UTC().AppendFormat(info, "20060102150405")
	bodies[infoObj] = append(info, "Z) >>"...)

	out := make([]byte, 0, 64<<10)
	out = append(out, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"...)
	offsets := make([]int, n+1)
	for i := 1; i <= n; i++ {
		if bodies[i] == nil {
			return nil, errors.New("pdfwrite: internal numbering gap")
		}
		offsets[i] = len(out)
		out = strconv.AppendInt(out, int64(i), 10)
		out = append(out, " 0 obj\n"...)
		out = append(out, bodies[i]...)
		out = append(out, "\nendobj\n"...)
	}
	xref := len(out)
	out = append(out, "xref\n0 "...)
	out = strconv.AppendInt(out, int64(n+1), 10)
	out = append(out, "\n0000000000 65535 f \n"...)
	for i := 1; i <= n; i++ {
		var digits [10]byte
		v := offsets[i]
		for j := 9; j >= 0; j-- {
			digits[j] = byte('0' + v%10)
			v /= 10
		}
		out = append(out, digits[:]...)
		out = append(out, " 00000 n \n"...)
	}
	out = append(out, "trailer\n<< /Size "...)
	out = strconv.AppendInt(out, int64(n+1), 10)
	out = append(out, " /Root 1 0 R /Info "...)
	out = strconv.AppendInt(out, int64(infoObj), 10)
	out = append(out, " 0 R >>\nstartxref\n"...)
	out = strconv.AppendInt(out, int64(xref), 10)
	out = append(out, "\n%%EOF\n"...)
	if len(out) > maxOutput {
		return nil, ErrOutputBudget
	}
	return out, nil
}
