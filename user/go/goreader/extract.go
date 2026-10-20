// extract.go is GOREADER's bounded text extraction, the "find over
// extracted text" half of M143a (#2792). The ADR 0040 engine renders page
// bitmaps and deliberately exports no text API, so the reader walks the
// same closed subset read-only: the classic xref table, the page tree,
// Type3 Encoding/Differences + Widths, and the text-showing operators
// (Tj/TJ/'/") with their pen matrices.
//
// This is a READER for search, never a validator: it only ever sees bytes
// the engine already accepted, and every bound below mirrors an engine
// limit so a worst-case corpus document stays cheap. A parse miss does not
// fail the document — it just yields no findable text on that page (the
// card's "positions when available" degrade path).
package main

import "virelai/flate"

// Extraction bounds, mirroring the engine's own ceilings (pdf.go).
const (
	xMaxObjects   = 8192      // pdf.MaxObjects
	xMaxPages     = 256       // pdf.MaxPages
	xMaxKids      = 256       // Pages /Kids bound
	xMaxContents  = 16        // /Contents array bound
	xMaxDepth     = 32        // pdf.MaxDepth (page tree)
	xValDepth     = 16        // pdf.MaxGraphicsDepth-adjacent
	xMaxDict      = 256       // dictionary pairs
	xMaxArray     = 1024      // array items
	xMaxName      = 64        // name bytes
	xMaxString    = 4096      // shown-string bytes per token
	xMaxDecoded   = 4_194_304 // decoded content bytes per page
	xMaxTextBytes = 1 << 20   // extracted text bytes per page
	xMaxGlyphs    = 1 << 16   // recorded glyph rects per page
	xStack        = 64        // content operand stack
	xGStack       = 16        // q/Q depth
)

// glyphPos is one shown glyph: its byte offset in the page text and its
// band on the rendered page (96 dpi page pixels, y down from the top).
type glyphPos struct {
	off            int
	x0, y0, x1, y1 float64
}

// pageText is one page's extracted text plus the glyph bands find maps a
// hit range back onto. glyphs may be empty while text is not (no usable
// positions), and text may be empty for a picture-only page.
type pageText struct {
	text   []byte
	glyphs []glyphPos
}

// ---------------------------------------------------------------------------
// Values — a small read-only parser for the engine's closed object syntax
// ---------------------------------------------------------------------------

const (
	vBad = iota
	vNull
	vBool
	vNum
	vName
	vStr
	vArr
	vDict
	vRef
)

type xval struct {
	k    byte
	num  float64
	b    []byte  // name bytes / decoded string bytes
	arr  []xval  // vArr
	dict []xpair // vDict
	ref  int     // vRef target
}

type xpair struct {
	key []byte
	val xval
}

type xerr string

func (e xerr) Error() string { return string(e) }

// xparser is the bounded lexer: whitespace + comments skipped, one-byte
// lookahead, every container counted.
type xparser struct {
	b      []byte
	pos    int
	limit  int // bytes this parse may still produce (anti-bomb)
	failed bool
}

func whiteB(b byte) bool {
	return b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32
}

func delimB(b byte) bool {
	return whiteB(b) || b == '(' || b == ')' || b == '<' || b == '>' ||
		b == '[' || b == ']' || b == '/' || b == '%' || b == '{' || b == '}'
}

func hexNib(b byte) int {
	switch {
	case b >= '0' && b <= '9':
		return int(b - '0')
	case b >= 'a' && b <= 'f':
		return int(b-'a') + 10
	case b >= 'A' && b <= 'F':
		return int(b-'A') + 10
	}
	return -1
}

func (p *xparser) ws() {
	for p.pos < len(p.b) {
		c := p.b[p.pos]
		if whiteB(c) {
			p.pos++
			continue
		}
		if c == '%' {
			for p.pos < len(p.b) && p.b[p.pos] != 10 && p.b[p.pos] != 13 {
				p.pos++
			}
			continue
		}
		return
	}
}

// word reads one regular-delimited run (names carry the leading '/' here).
func (p *xparser) word() []byte {
	start := p.pos
	for p.pos < len(p.b) && !delimB(p.b[p.pos]) {
		p.pos++
		if p.pos-start > xMaxName {
			p.failed = true
			return nil
		}
	}
	return p.b[start:p.pos]
}

// literal reads a balanced-paren string with escapes, bounded.
func (p *xparser) literal() []byte {
	p.pos++ // '('
	out := make([]byte, 0, 64)
	depth := 1
	for p.pos < len(p.b) {
		if len(out) >= xMaxString {
			p.failed = true
			return nil
		}
		c := p.b[p.pos]
		p.pos++
		switch c {
		case '(':
			depth++
			if depth > 32 {
				p.failed = true
				return nil
			}
			out = append(out, c)
		case ')':
			depth--
			if depth == 0 {
				return out
			}
			out = append(out, c)
		case '\\':
			if p.pos >= len(p.b) {
				p.failed = true
				return nil
			}
			c = p.b[p.pos]
			p.pos++
			switch c {
			case 'n':
				c = 10
			case 'r':
				c = 13
			case 't':
				c = 9
			case 'b':
				c = 8
			case 'f':
				c = 12
			case 10:
				continue
			case 13:
				if p.pos < len(p.b) && p.b[p.pos] == 10 {
					p.pos++
				}
				continue
			default:
				if c >= '0' && c <= '7' {
					v := int(c - '0')
					for i := 0; i < 2 && p.pos < len(p.b); i++ {
						d := p.b[p.pos]
						if d < '0' || d > '7' {
							break
						}
						p.pos++
						v = v*8 + int(d-'0')
					}
					c = byte(v)
				}
			}
			out = append(out, c)
		default:
			out = append(out, c)
		}
	}
	p.failed = true
	return nil
}

// hexstr reads a `<...>` hex string (a `<<` dict open is handled by the
// caller before it reaches here).
func (p *xparser) hexstr() []byte {
	p.pos++ // '<'
	out := make([]byte, 0, 64)
	hi := -1
	for p.pos < len(p.b) {
		c := p.b[p.pos]
		p.pos++
		if c == '>' {
			if hi >= 0 {
				out = append(out, byte(hi*16))
			}
			return out
		}
		if whiteB(c) {
			continue
		}
		n := hexNib(c)
		if n < 0 {
			p.failed = true
			return nil
		}
		if len(out) >= xMaxString && hi < 0 {
			p.failed = true
			return nil
		}
		if hi < 0 {
			hi = n
		} else {
			out = append(out, byte(hi*16+n))
			hi = -1
		}
	}
	p.failed = true
	return nil
}

// number parses the subset's decimal (sign, digits, at most one dot).
func decNum(b []byte) (float64, bool) {
	if len(b) == 0 || len(b) > 64 {
		return 0, false
	}
	i := 0
	sign := 1.0
	if b[0] == '-' || b[0] == '+' {
		if b[0] == '-' {
			sign = -1
		}
		i++
	}
	digits := 0
	dot := false
	v := 0.0
	scale := 1.0
	for ; i < len(b); i++ {
		c := b[i]
		if c == '.' && !dot {
			dot = true
			continue
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		digits++
		if dot {
			scale *= 10
		}
		v = v*10 + float64(c-'0')
	}
	if digits == 0 || v > 1e12 {
		return 0, false
	}
	return sign * v / scale, true
}

// val parses one PDF object value: null/bool/number/name/string/array/
// dict/ref. Anything else (bare words like `stream`) is vBad to the caller.
func (p *xparser) val(depth int) xval {
	if depth > xValDepth || p.failed {
		p.failed = true
		return xval{}
	}
	p.ws()
	if p.pos >= len(p.b) {
		p.failed = true
		return xval{}
	}
	switch c := p.b[p.pos]; {
	case c == '(':
		return xval{k: vStr, b: p.literal()}
	case c == '<':
		if p.pos+1 < len(p.b) && p.b[p.pos+1] == '<' {
			p.pos += 2
			var d []xpair
			for !p.failed {
				p.ws()
				if p.pos >= len(p.b) {
					p.failed = true
					return xval{}
				}
				if p.b[p.pos] == '>' && p.pos+1 < len(p.b) && p.b[p.pos+1] == '>' {
					p.pos += 2
					return xval{k: vDict, dict: d}
				}
				if len(d) >= xMaxDict {
					p.failed = true
					return xval{}
				}
				kv := p.val(depth + 1)
				if kv.k != vName {
					p.failed = true
					return xval{}
				}
				vv := p.val(depth + 1)
				if p.failed {
					return xval{}
				}
				d = append(d, xpair{kv.b, vv})
			}
			return xval{}
		}
		return xval{k: vStr, b: p.hexstr()}
	case c == '/':
		p.pos++
		w := p.word()
		if p.failed {
			return xval{}
		}
		return xval{k: vName, b: w}
	case c == '[':
		p.pos++
		var a []xval
		for !p.failed {
			p.ws()
			if p.pos >= len(p.b) {
				p.failed = true
				return xval{}
			}
			if p.b[p.pos] == ']' {
				p.pos++
				return xval{k: vArr, arr: a}
			}
			if len(a) >= xMaxArray {
				p.failed = true
				return xval{}
			}
			a = append(a, p.val(depth+1))
		}
		return xval{}
	}
	// Numbers, refs, booleans, null — all bare words.
	w := p.word()
	if len(w) == 0 {
		p.failed = true
		return xval{}
	}
	switch string(w) {
	case "null":
		return xval{k: vNull}
	case "true":
		return xval{k: vBool, num: 1}
	case "false":
		return xval{k: vBool}
	}
	if n, ok := decNum(w); ok {
		// An integer followed by "<gen> R" is an indirect reference. Peek
		// without committing so a plain number still parses on retry.
		save := *p
		p.ws()
		g := p.word()
		if gi, ok2 := decNum(g); ok2 && gi == float64(int(gi)) {
			p.ws()
			r := p.word()
			if len(r) == 1 && r[0] == 'R' {
				return xval{k: vRef, ref: int(n)}
			}
		}
		*p = save
		return xval{k: vNum, num: n}
	}
	return xval{k: vBad, b: w}
}

// ---------------------------------------------------------------------------
// Objects via the classic xref table
// ---------------------------------------------------------------------------

// xobjects is the xref-derived object map: body[n] is the byte range
// after `n 0 obj`'s line ending up to the next object (or the xref).
type xobjects struct {
	body [][]byte
	err  bool
}

func eqs(b []byte, s string) bool { return string(b) == s }

func xindex(data []byte) *xobjects {
	// Final startxref sits in the bounded tail.
	tail := data
	if len(tail) > 4096 {
		tail = tail[len(tail)-4096:]
	}
	base := len(data) - len(tail)
	at := -1
	for i := len(tail) - 9; i >= 0; i-- {
		if eqs(tail[i:i+9], "startxref") {
			at = base + i
			break
		}
	}
	if at < 0 {
		return &xobjects{err: true}
	}
	p := xparser{b: data, pos: at + 9}
	offv := p.val(0)
	if p.failed || offv.k != vNum {
		return &xobjects{err: true}
	}
	xoff := int(offv.num)
	if xoff < 0 || xoff+4 > len(data) || !eqs(data[xoff:xoff+4], "xref") {
		return &xobjects{err: true}
	}
	// At xoff: `xref` EOL `0 N` EOL, then N fixed-width 20-byte rows.
	p = xparser{b: data, pos: xoff + 4}
	p.ws()
	zv := p.val(0)
	nv := p.val(0)
	if p.failed || zv.k != vNum || nv.k != vNum || int(zv.num) != 0 {
		return &xobjects{err: true}
	}
	n := int(nv.num)
	if n < 1 || n > xMaxObjects+1 {
		return &xobjects{err: true}
	}
	offs := make([]int, n)
	for i := 0; i < n; i++ {
		p.ws()
		if p.pos+20 > len(data) {
			return &xobjects{err: true}
		}
		row := data[p.pos : p.pos+20]
		off := 0
		for j := 0; j < 10; j++ {
			if row[j] < '0' || row[j] > '9' {
				return &xobjects{err: true}
			}
			off = off*10 + int(row[j]-'0')
		}
		if row[10] != ' ' || row[16] != ' ' || (row[17] != 'n' && row[17] != 'f') {
			return &xobjects{err: true}
		}
		p.pos += 20
		if i == 0 {
			continue // the free sentinel is not an object
		}
		if off <= 0 || off >= xoff || (i > 1 && off <= offs[i-1]) {
			return &xobjects{err: true}
		}
		offs[i] = off
	}
	// Objects sit at their xref offsets in ascending order (the engine
	// already proved it). A body runs from its "N 0 obj" header's EOL to
	// its own endobj — never past the next object's offset or the xref.
	body := make([][]byte, n)
	for i := 1; i < n; i++ {
		o := offs[i]
		end := xoff
		if i+1 < n {
			end = offs[i+1]
		}
		hd := o
		for hd < end && data[hd] != 10 && data[hd] != 13 {
			hd++
		}
		if hd < end && data[hd] == 13 {
			hd++
		}
		if hd < end && data[hd] == 10 {
			hd++
		}
		lo := hd
		for lo+6 <= end && !eqs(data[lo:lo+6], "endobj") {
			lo++
		}
		if lo+6 > end {
			return &xobjects{err: true}
		}
		body[i] = data[hd:lo]
	}
	return &xobjects{body: body}
}

// obj parses object n's value. A stream object's dict is followed by its
// stream bytes; obj returns just the parsed dict and objStream digs the
// data out separately.
func (x *xobjects) obj(n int) (xval, bool) {
	if n <= 0 || n >= len(x.body) || len(x.body[n]) == 0 {
		return xval{}, false
	}
	p := xparser{b: x.body[n]}
	v := p.val(0)
	if p.failed {
		return xval{}, false
	}
	return v, true
}

// objStream returns object n's decoded stream bytes when it is a stream
// object with a direct /Length and either no filter or FlateDecode.
func (x *xobjects) objStream(n int, budget *int) ([]byte, bool) {
	if n <= 0 || n >= len(x.body) {
		return nil, false
	}
	raw := x.body[n]
	p := xparser{b: raw}
	v := p.val(0)
	if p.failed || v.k != vDict {
		return nil, false
	}
	p.ws()
	if !eqs(p.word(), "stream") {
		return nil, false
	}
	if p.pos < len(raw) && raw[p.pos] == 13 {
		p.pos++
	}
	if p.pos < len(raw) && raw[p.pos] == 10 {
		p.pos++
	}
	lv := xget(v, "Length")
	if lv.k != vNum || lv.num < 0 {
		return nil, false
	}
	ln := int(lv.num)
	if p.pos+ln > len(raw) {
		return nil, false
	}
	data := raw[p.pos : p.pos+ln]
	fv := xget(v, "Filter")
	switch {
	case fv.k == vBad || fv.k == vNull:
		if *budget < ln {
			return nil, false
		}
		*budget -= ln
		return data, true
	case fv.k == vName && eqs(fv.b, "FlateDecode"):
	case fv.k == vArr && len(fv.arr) == 1 && fv.arr[0].k == vName && eqs(fv.arr[0].b, "FlateDecode"):
	default:
		return nil, false
	}
	out := make([]byte, xMaxDecoded)
	m, _, err := flate.InflateZlib(out, data)
	if err != nil || m >= xMaxDecoded || *budget < m {
		return nil, false
	}
	*budget -= m
	return out[:m], true
}

// ---------------------------------------------------------------------------
// Dict helpers + the page tree walk
// ---------------------------------------------------------------------------

func xget(v xval, key string) xval {
	if v.k != vDict {
		return xval{}
	}
	for _, pr := range v.dict {
		if eqs(pr.key, key) {
			return pr.val
		}
	}
	return xval{}
}

func (x *xobjects) resolve(v xval) xval {
	if v.k == vRef {
		if d, ok := x.obj(v.ref); ok {
			return d
		}
		return xval{}
	}
	return v
}

func (x *xobjects) resolveRef(v xval) int {
	if v.k == vRef {
		return v.ref
	}
	return -1
}

// xpage is one leaf's extraction view: its effective box (pts), the
// resolved Resources dict, and its content-stream object numbers.
type xpage struct {
	box      [4]float64
	res      xval
	contents []int
}

func xbox(v xval) ([4]float64, bool) {
	var b [4]float64
	if v.k != vArr || len(v.arr) != 4 {
		return b, false
	}
	for i := 0; i < 4; i++ {
		if v.arr[i].k != vNum {
			return b, false
		}
		b[i] = v.arr[i].num
	}
	if b[0] >= b[2] || b[1] >= b[3] {
		return b, false
	}
	return b, true
}

func (x *xobjects) walkPages(n int, res xval, box [4]float64, crop [4]float64, hasCrop bool, depth int, out *[]xpage) {
	if depth > xMaxDepth || len(*out) >= xMaxPages {
		return
	}
	d, ok := x.obj(n)
	if !ok || d.k != vDict {
		return
	}
	if r := xget(d, "Resources"); r.k != vBad {
		res = x.resolve(r)
	}
	if b, ok := xbox(x.resolve(xget(d, "MediaBox"))); ok {
		box = b
	}
	if b, ok := xbox(x.resolve(xget(d, "CropBox"))); ok {
		crop, hasCrop = b, true
	}
	ty := xget(d, "Type")
	switch {
	case ty.k == vName && eqs(ty.b, "Page"):
		eff := box
		if hasCrop {
			eff = [4]float64{maxF(box[0], crop[0]), maxF(box[1], crop[1]), minF(box[2], crop[2]), minF(box[3], crop[3])}
			if eff[0] >= eff[2] || eff[1] >= eff[3] {
				eff = box
			}
		}
		pg := xpage{box: eff, res: res}
		cv := xget(d, "Contents")
		if cv.k == vRef {
			pg.contents = append(pg.contents, cv.ref)
		} else if cv.k == vArr {
			for _, it := range cv.arr {
				if len(pg.contents) >= xMaxContents {
					break
				}
				if it.k == vRef {
					pg.contents = append(pg.contents, it.ref)
				}
			}
		}
		*out = append(*out, pg)
	case ty.k == vName && eqs(ty.b, "Pages"):
		kids := x.resolve(xget(d, "Kids"))
		if kids.k != vArr {
			return
		}
		for i, k := range kids.arr {
			if i >= xMaxKids || len(*out) >= xMaxPages {
				return
			}
			if k.k == vRef {
				x.walkPages(k.ref, res, box, crop, hasCrop, depth+1, out)
			}
		}
	}
}

// xpages returns the document's leaves in tree (reading) order.
func (x *xobjects) xpages() []xpage {
	// Find the catalog: the one object whose dict names /Type /Catalog.
	for n := 1; n < len(x.body); n++ {
		d, ok := x.obj(n)
		if !ok || d.k != vDict {
			continue
		}
		if ty := xget(d, "Type"); ty.k == vName && eqs(ty.b, "Catalog") {
			root := x.resolveRef(xget(d, "Pages"))
			if root <= 0 {
				return nil
			}
			var out []xpage
			x.walkPages(root, xval{}, [4]float64{0, 0, 0, 0}, [4]float64{}, false, 0, &out)
			return out
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Type3 encodings
// ---------------------------------------------------------------------------

// xfont is one Type3 font's search view: code→glyph-name, code→width, and
// the FontMatrix scale applied to widths.
type xfont struct {
	names  [256][]byte
	widths [256]float64
	matrix float64 // FontMatrix A (the subset's fonts are unscaled uniform)
}

// glyphByte maps a Type3 glyph name to its text byte. Single-character
// names are themselves; the rest come from the usual Adobe names. A name
// we cannot map still extracts — as a byte that never matches a query.
func glyphByte(name []byte) byte {
	if len(name) == 1 {
		return name[0]
	}
	switch string(name) {
	case "space", "Space":
		return ' '
	case "exclam":
		return '!'
	case "quotedbl":
		return '"'
	case "numbersign":
		return '#'
	case "dollar":
		return '$'
	case "percent":
		return '%'
	case "ampersand":
		return '&'
	case "quotesingle", "quoteright":
		return '\''
	case "parenleft":
		return '('
	case "parenright":
		return ')'
	case "asterisk":
		return '*'
	case "plus":
		return '+'
	case "comma":
		return ','
	case "hyphen", "minus":
		return '-'
	case "period":
		return '.'
	case "slash":
		return '/'
	case "colon":
		return ':'
	case "semicolon":
		return ';'
	case "less":
		return '<'
	case "equal":
		return '='
	case "greater":
		return '>'
	case "question":
		return '?'
	case "at":
		return '@'
	case "bracketleft":
		return '['
	case "backslash":
		return '\\'
	case "bracketright":
		return ']'
	case "asciicircum":
		return '^'
	case "underscore":
		return '_'
	case "grave", "quoteleft":
		return '`'
	case "braceleft":
		return '{'
	case "bar":
		return '|'
	case "braceright":
		return '}'
	case "asciitilde":
		return '~'
	case "zero":
		return '0'
	case "one":
		return '1'
	case "two":
		return '2'
	case "three":
		return '3'
	case "four":
		return '4'
	case "five":
		return '5'
	case "six":
		return '6'
	case "seven":
		return '7'
	case "eight":
		return '8'
	case "nine":
		return '9'
	case "endash":
		return '-'
	case "emdash":
		return '-'
	case "bullet":
		return '*'
	}
	return 0
}

// fonts resolves the page's /Resources → /Font table into name→xfont.
func (x *xobjects) fonts(res xval) map[string]*xfont {
	fd := x.resolve(xget(res, "Font"))
	if fd.k != vDict {
		return nil
	}
	out := make(map[string]*xfont, len(fd.dict))
	for _, pr := range fd.dict {
		if len(out) >= 64 {
			break
		}
		fv := x.resolve(pr.val)
		if fv.k != vDict {
			continue
		}
		f := &xfont{matrix: 1}
		if m := x.resolve(xget(fv, "FontMatrix")); m.k == vArr && len(m.arr) == 6 && m.arr[0].k == vNum {
			f.matrix = m.arr[0].num
		}
		first := 0
		if iv := xget(fv, "FirstChar"); iv.k == vNum {
			first = int(iv.num)
		}
		if w := x.resolve(xget(fv, "Widths")); w.k == vArr {
			for i, wv := range w.arr {
				c := first + i
				if c < 0 || c > 255 {
					break
				}
				if wv.k == vNum {
					f.widths[c] = wv.num
				}
			}
		}
		enc := x.resolve(xget(fv, "Encoding"))
		diff := x.resolve(xget(enc, "Differences"))
		if diff.k == vArr {
			code := -1
			for _, d := range diff.arr {
				switch d.k {
				case vNum:
					code = int(d.num)
				case vName:
					if code >= 0 && code <= 255 {
						f.names[code] = d.b
					}
					code++
				}
			}
		}
		out[string(pr.key)] = f
	}
	return out
}

// ---------------------------------------------------------------------------
// The content-stream text walk
// ---------------------------------------------------------------------------

// affine is a PDF 6-number matrix.
type affine struct{ a, b, c, d, e, f float64 }

var identA = affine{a: 1, d: 1}

func mulA(p, q affine) affine {
	return affine{
		a: p.a*q.a + p.c*q.b, b: p.b*q.a + p.d*q.b,
		c: p.a*q.c + p.c*q.d, d: p.b*q.c + p.d*q.d,
		e: p.a*q.e + p.c*q.f + p.e, f: p.b*q.e + p.d*q.f + p.f,
	}
}

func xformA(m affine, x, y float64) (float64, float64) {
	return m.a*x + m.c*y + m.e, m.b*x + m.d*y + m.f
}

func maxF(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}

func minF(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

// textWalker accumulates the page text and glyph bands while interpreting
// just the operators that carry text or move the pen.
type textWalker struct {
	fonts    map[string]*xfont
	mapPage  affine
	out      pageText
	ctm      affine
	gs       [xGStack]affine
	gdepth   int
	inText   bool
	tm, lm   affine
	font     *xfont
	size     float64
	tc, tw   float64
	tz       float64
	leading  float64
	rise     float64
	havePen  bool
	lastY    float64
	lastXEnd float64
}

// penIs returns the page-pixel point of a text-space offset under the
// current pen (mapPage × ctm × tm — the same chain the engine renders).
func (t *textWalker) pen(dx, dy float64) (float64, float64) {
	m := mulA(t.mapPage, mulA(t.ctm, t.tm))
	return xformA(m, dx, dy)
}

// newline records a line break in the text when the pen moved vertically
// since the last shown glyph; a big horizontal jump becomes a space so a
// TJ-tracked word still reads as one.
func (t *textWalker) separate() {
	if !t.havePen || len(t.out.text) == 0 || len(t.out.glyphs) == 0 {
		return
	}
	x, y := t.pen(0, 0)
	h := t.size * 4.0 / 3.0
	if h < 1 {
		h = 8
	}
	last := t.out.text[len(t.out.text)-1]
	if y-t.lastY > h*0.5 || t.lastY-y > h*0.5 {
		if last != '\n' && len(t.out.text) < xMaxTextBytes {
			t.out.text = append(t.out.text, '\n')
		}
		return
	}
	if x-t.lastXEnd > h*0.4 && last != ' ' && last != '\n' && len(t.out.text) < xMaxTextBytes {
		t.out.text = append(t.out.text, ' ')
	}
}

// show emits one text-showing string: per byte, the Type3 name→char and
// the pen band [pen, pen+advance) on the page.
func (t *textWalker) show(s []byte) {
	if t.font == nil || len(s) == 0 {
		return
	}
	if len(t.out.glyphs) >= xMaxGlyphs || len(t.out.text) >= xMaxTextBytes {
		return
	}
	t.separate()
	for _, c := range s {
		ch := glyphByte(t.font.names[c])
		w := t.font.widths[c]
		delta := (w*t.font.matrix*t.size + t.tc) * t.tz
		if c == 32 {
			delta += t.tw * t.tz
		}
		x0, y0 := t.pen(0, t.rise)
		x1, _ := t.pen(delta, t.rise)
		// The band is baseline-to-cap-height: pen.y is the baseline in
		// page space (y grows downward), so the band extends upward by
		// the font's rendered size and a little below the baseline.
		h := t.size * t.font.matrix * 4.0 / 3.0
		if h < 1 {
			h = 1
		}
		gp := glyphPos{off: len(t.out.text),
			x0: minF(x0, x1), x1: maxF(x0, x1),
			y0: y0 - h, y1: y0 + h*0.25}
		if gp.x1 <= gp.x0 {
			gp.x1 = gp.x0 + h*0.5
		}
		if len(t.out.text) < xMaxTextBytes {
			t.out.text = append(t.out.text, ch)
		}
		if len(t.out.glyphs) < xMaxGlyphs {
			t.out.glyphs = append(t.out.glyphs, gp)
		}
		t.havePen = true
		t.lastY = y0
		t.lastXEnd = maxF(x0, x1)
		t.tm = mulA(t.tm, affine{a: 1, d: 1, e: delta})
	}
}

func (t *textWalker) nextLine() {
	t.lm = mulA(t.lm, affine{a: 1, d: 1, f: -t.leading})
	t.tm = t.lm
}

// op applies one content operator against the operand stack. Only the
// text and pen-moving ops do work; everything else just clears operands —
// the engine's own validation already decided what this page may contain.
func (t *textWalker) op(name string, ops []xval) {
	num := func(i int) float64 {
		if i < len(ops) && ops[i].k == vNum {
			return ops[i].num
		}
		return 0
	}
	switch name {
	case "q":
		if t.gdepth < xGStack {
			t.gs[t.gdepth] = t.ctm
			t.gdepth++
		}
	case "Q":
		if t.gdepth > 0 {
			t.gdepth--
			t.ctm = t.gs[t.gdepth]
		}
	case "cm":
		if len(ops) == 6 {
			t.ctm = mulA(t.ctm, affine{num(0), num(1), num(2), num(3), num(4), num(5)})
		}
	case "BT":
		t.inText = true
		t.tm, t.lm = identA, identA
	case "ET":
		t.inText = false
	case "Tf":
		if len(ops) == 2 && ops[0].k == vName {
			t.font = t.fonts[string(ops[0].b)]
			t.size = num(1)
		}
	case "Tm":
		if len(ops) == 6 {
			t.tm = affine{num(0), num(1), num(2), num(3), num(4), num(5)}
			t.lm = t.tm
		}
	case "Td":
		t.lm = mulA(t.lm, affine{a: 1, d: 1, e: num(0), f: num(1)})
		t.tm = t.lm
	case "TD":
		t.leading = -num(1)
		t.lm = mulA(t.lm, affine{a: 1, d: 1, e: num(0), f: num(1)})
		t.tm = t.lm
	case "TL":
		t.leading = num(0)
	case "T*":
		t.nextLine()
	case "Tc":
		t.tc = num(0)
	case "Tw":
		t.tw = num(0)
	case "Tz":
		t.tz = num(0) / 100
		if t.tz <= 0 {
			t.tz = 1
		}
	case "Ts":
		t.rise = num(0)
	case "Tj":
		if len(ops) == 1 && ops[0].k == vStr {
			t.show(ops[0].b)
		}
	case "'":
		if len(ops) == 1 && ops[0].k == vStr {
			t.nextLine()
			t.show(ops[0].b)
		}
	case "\"":
		if len(ops) == 3 && ops[2].k == vStr {
			t.tw, t.tc = num(0), num(1)
			t.nextLine()
			t.show(ops[2].b)
		}
	case "TJ":
		if len(ops) == 1 && ops[0].k == vArr {
			for _, it := range ops[0].arr {
				switch it.k {
				case vStr:
					t.show(it.b)
				case vNum:
					delta := -it.num / 1000 * t.size * t.tz
					t.tm = mulA(t.tm, affine{a: 1, d: 1, e: delta})
				}
			}
		}
	}
}

// walkContent tokenizes one decoded content stream and feeds the walker.
// A malformed tail just ends the walk — extraction is best-effort.
func (t *textWalker) walkContent(data []byte) {
	p := xparser{b: data}
	var ops [xStack]xval
	n := 0
	for p.pos < len(data) && !p.failed {
		p.ws()
		if p.pos >= len(data) {
			break
		}
		// Operators are bare regular words; values parse as operands. A
		// word that is not a number/name falls out of val as vBad with the
		// raw token in b — that IS the operator dispatch.
		v := p.val(0)
		if p.failed {
			break
		}
		if v.k == vBad {
			t.op(string(v.b), ops[:n])
			n = 0
			continue
		}
		if n < xStack {
			ops[n] = v
			n++
		}
	}
}

// pageBox maps a page's effective box (pts) to the engine's 96 dpi page
// pixels: 4/3 scale, y flipped, cropped origin — the same mapPage the
// engine builds in initPage.
func pageMap(box [4]float64) affine {
	return affine{a: 4.0 / 3, d: -4.0 / 3, e: -4 * box[0] / 3, f: 4 * box[3] / 3}
}

// pageDims is the rendered page size the same box gives the engine.
func pageDims(box [4]float64) (int, int) {
	return int((box[2]-box[0])*4.0/3.0 + 0.5), int((box[3]-box[1])*4.0/3.0 + 0.5)
}

// extractPages walks one validated document's bytes and returns per-page
// text+positions in reading order. Engine-accepted docs always reach here;
// any structural surprise degrades that page (or the doc) to no text —
// find then reports a miss, never a crash.
func extractPages(data []byte) []pageText {
	x := xindex(data)
	if x == nil || x.err {
		return nil
	}
	pages := x.xpages()
	out := make([]pageText, len(pages))
	budget := xMaxDecoded * 4 // whole-document decoded-content budget
	for i, pg := range pages {
		w := &textWalker{fonts: x.fonts(pg.res), mapPage: pageMap(pg.box),
			ctm: identA, tm: identA, lm: identA, size: 0, tz: 1}
		for _, ref := range pg.contents {
			if budget <= 0 {
				break
			}
			stream, ok := x.objStream(ref, &budget)
			if !ok {
				continue
			}
			w.walkContent(stream)
		}
		out[i] = w.out
	}
	return out
}
