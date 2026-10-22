package pdf

import (
	"math"
	"virelai/vector"
)

type graphics struct {
	ctm                             vector.Affine
	clip                            vector.Rect
	color                           uint32
	font                            int32
	size, tc, tw, tz, leading, rise float64
}
type operand struct {
	name         [64]byte
	num          float64
	start, count uint16
	k            kind
}
type tjItem struct {
	num          float64
	start, count uint16
	text         bool
}
type contentState struct {
	g                                                   graphics
	saved                                               [16]graphics
	ops                                                 [16]operand
	items                                               [512]tjItem
	chars                                               [4096]byte
	tm, lm                                              vector.Affine
	mapPage                                             vector.Affine
	pathStart, pathN, batchC, batchP                    uint32
	charN, itemN                                        uint16
	depth, opN, outerDepth                              uint8
	bt, hasPoint, onlyRect, clipPending, glyph, metrics bool
	current, start                                      vector.Point
	rect                                                vector.Rect
	fontBox, glyphBox                                   [4]float64
	wx                                                  float64
	page                                                pageDesc
}

// A page program suspends slot zero while an image or glyph uses slot one.
// A1.1 checks decoded stream boundaries without resetting operands or state.
// Empty streams do not separate neighbors; comments end with their stream.
type program struct {
	e                                               *engine
	objects                                         [16]int
	n, at, slot                                     int
	open, have, eof, first, seen, inString, comment bool
	b, last                                         byte
	offset, streamStart                             int
}

// ISO 32000-1 §7.2.2 includes braces among the delimiters.
func regular(b byte) bool { return !delimiter(b) && b != '{' && b != '}' }

func (p *program) peek() (byte, bool) {
	if p.have {
		p.e.charge(Examine, 1)
		return p.b, true
	}
	for !p.eof && p.e.f.Code == OK {
		if !p.open {
			if p.at == p.n {
				p.eof = true
				break
			}
			opened, _ := p.e.openDecoder(p.slot, p.objects[p.at], false)
			if !opened {
				break
			}
			p.open = true
			p.first = true
			p.streamStart = int(p.e.dec[p.slot].pos)
			if !p.e.dec[p.slot].raw {
				// openDecoder has consumed the two-byte zlib header.
				p.streamStart -= 2
			}
		}
		b, ok := p.e.decoded(p.slot)
		if ok {
			if p.first && p.seen && (p.inString || regular(p.last) && regular(b)) {
				p.e.set(MalformedContent)
				p.e.f.Offset = p.streamStart
				p.e.f.Object = p.objects[p.at]
				return 0, false
			}
			p.first = false
			p.seen = true
			p.last = b
			p.b = b
			p.have = true
			p.offset++
			p.e.charge(Examine, 1)
			return b, true
		}
		p.e.closeDecoder(p.slot)
		p.open = false
		p.comment = false
		p.at++
	}
	return 0, false
}
func (p *program) get() (byte, bool) { b, ok := p.peek(); p.have = false; return b, ok }
func (p *program) close() {
	if p.open {
		p.e.closeDecoder(p.slot)
		p.open = false
	}
}
func (p *program) space() {
	for p.e.f.Code == OK {
		b, ok := p.peek()
		if !ok {
			return
		}
		if white(b) {
			p.get()
			continue
		}
		if b != '%' {
			return
		}
		p.comment = true
		for p.e.f.Code == OK {
			b, ok = p.peek()
			if !ok || !p.comment {
				break
			}
			p.have = false
			if b == 10 || b == 13 {
				break
			}
		}
		p.comment = false
	}
}
func (p *program) text() operand {
	e := p.e
	s := e.state
	o := operand{k: kString, start: s.charN}
	b, _ := p.get()
	p.inString = true
	defer func() { p.inString = false }()
	literal := b == '('
	depth := 1
	hi := -1
	put := func(b byte) {
		if s.charN == 4096 {
			e.set(TokenLimit)
			return
		}
		e.charge(Copy, 1)
		s.chars[s.charN] = b
		s.charN++
		o.count++
	}
	for e.f.Code == OK {
		b, ok := p.get()
		if !ok {
			e.set(MalformedContent)
			break
		}
		if !literal {
			if b == '>' {
				if hi >= 0 {
					put(byte(hi * 16))
				}
				return o
			}
			if white(b) {
				continue
			}
			n := hex(b)
			if n < 0 {
				e.set(MalformedContent)
				break
			}
			if hi < 0 {
				hi = n
			} else {
				put(byte(hi*16 + n))
				hi = -1
			}
			continue
		}
		switch b {
		case '(':
			if depth == 32 {
				e.set(DepthLimit)
				return o
			}
			e.charge(Stack, 1)
			depth++
			put(b)
		case ')':
			e.charge(Stack, 1)
			depth--
			if depth == 0 {
				return o
			}
			put(b)
		case '\\':
			b, ok = p.get()
			if !ok {
				e.set(MalformedContent)
				return o
			}
			switch b {
			case 'n':
				b = 10
			case 'r':
				b = 13
			case 't':
				b = 9
			case 'b':
				b = 8
			case 'f':
				b = 12
			case 10:
				continue
			case 13:
				if d, ok := p.peek(); ok && d == 10 {
					p.get()
				}
				continue
			default:
				if b >= '0' && b <= '7' {
					v := int(b - '0')
					for i := 0; i < 2; i++ {
						d, ok := p.peek()
						if !ok || d < '0' || d > '7' {
							break
						}
						p.get()
						v = v*8 + int(d-'0')
					}
					b = byte(v)
				}
			}
			put(b)
		case 13:
			if d, ok := p.peek(); ok && d == 10 {
				p.get()
			}
			put(10)
		default:
			put(b)
		}
	}
	return o
}
func decimal(a []byte) (float64, Code) {
	if len(a) == 0 {
		return 0, MalformedContent
	}
	sign := 1.0
	at := 0
	if a[0] == '-' || a[0] == '+' {
		if a[0] == '-' {
			sign = -1
		}
		at++
	}
	digits, places := 0, 0
	dot := false
	v := 0.0
	scale := 1.0
	for ; at < len(a); at++ {
		b := a[at]
		if b == '.' && !dot {
			dot = true
			continue
		}
		if b < '0' || b > '9' {
			return 0, MalformedContent
		}
		digits++
		if dot {
			places++
			if places > 6 {
				return 0, MalformedContent
			}
			scale *= 10
		}
		v = v*10 + float64(b-'0')
		if math.IsInf(v, 0) {
			return 0, MalformedContent
		}
	}
	if digits == 0 {
		return 0, MalformedContent
	}
	return sign * v / scale, OK
}
func (p *program) token() operand {
	p.space()
	e := p.e
	b, ok := p.peek()
	if !ok {
		return operand{}
	}
	e.charge(Token, 1)
	if b == '(' || b == '<' {
		return p.text()
	}
	o := operand{k: kWord}
	name := false
	if b == '/' {
		name = true
		o.k = kName
		p.get()
	}
	if b == '[' {
		p.get()
		o.k = kArray
		for e.f.Code == OK {
			p.space()
			b, ok = p.peek()
			if !ok {
				e.set(MalformedContent)
				break
			}
			if b == ']' {
				p.get()
				return o
			}
			if e.state.itemN == 512 {
				e.set(ContainerLimit)
				break
			}
			if b == '[' {
				e.set(MalformedContent)
				break
			}
			t := p.token()
			if t.k != kNumber && t.k != kString {
				e.set(MalformedContent)
				break
			}
			e.charge(Record, 1)
			e.state.items[e.state.itemN] = tjItem{t.num, t.start, t.count, t.k == kString}
			e.state.itemN++
			o.count++
		}
		return o
	}
	n := 0
	for e.f.Code == OK {
		b, ok = p.peek()
		if !ok || delimiter(b) {
			break
		}
		p.get()
		if name && b == '#' {
			a, ok1 := p.get()
			d, ok2 := p.get()
			if !ok1 || !ok2 || hex(a) < 0 || hex(d) < 0 {
				e.set(MalformedContent)
				break
			}
			b = byte(hex(a)*16 + hex(d))
		}
		if b == 0 || b > 127 {
			e.set(MalformedContent)
			break
		}
		limit := 32
		if name {
			limit = 64
		}
		if n == limit {
			e.set(TokenLimit)
			break
		}
		e.charge(Copy, 1)
		o.name[n] = b
		n++
	}
	if n == 0 {
		e.set(MalformedContent)
	}
	o.count = uint16(n)
	if !name && (o.name[0] == '+' || o.name[0] == '-' || o.name[0] == '.' || o.name[0] >= '0' && o.name[0] <= '9') {
		o.k = kNumber
		v, c := decimal(o.name[:n])
		e.set(c)
		o.num = v
	}
	return o
}
func (e *engine) arity(n int, kinds string) bool {
	s := e.state
	if int(s.opN) != n {
		e.set(MalformedContent)
		return false
	}
	for i := 0; i < n; i++ {
		e.charge(Operand, 1)
		want := kNumber
		switch kinds[i] {
		case 'n':
			want = kName
		case 's':
			want = kString
		case 'a':
			want = kArray
		}
		if s.ops[i].k != want {
			e.set(MalformedContent)
			return false
		}
	}
	return e.f.Code == OK
}
func (e *engine) program(p *program) {
	s := e.state
	for e.f.Code == OK {
		t := p.token()
		if t.k == kBad {
			break
		}
		if t.k != kWord {
			if s.opN == 16 {
				e.set(ContainerLimit)
				break
			}
			e.charge(Operand, 1)
			s.ops[s.opN] = t
			s.opN++
			continue
		}
		e.operator(string(t.name[:t.count]), p)
		s.opN = 0
		s.charN = 0
		s.itemN = 0
	}
	if s.opN != 0 || s.depth != 0 || s.bt || s.clipPending {
		e.set(MalformedContent)
	}
	if s.glyph && !s.metrics {
		e.set(UnsupportedGlyph)
	}
	if e.f.Code == OK && s.pathN > 0 {
		e.endPath(false, vector.NonZero)
	}
	p.close()
	if e.f.Code != OK && e.f.Offset < 0 {
		e.f.Offset = p.offset
	}
}
func (e *engine) renderPage(p pageDesc, background bool) {
	e.initPage(p)
	if !background {
		// Validate the same mapped geometry and image placement without
		// rasterizing an unpublished copy of every page.
		e.state.g.clip = vector.Rect{}
	}
	if background {
		for i := 0; i < int(p.width)*int(p.height) && e.f.Code == OK; i++ {
			if e.charge(Background, 4) {
				e.pix[i] = 0xffffffff
			}
		}
	}
	var pr program
	pr.e = e
	pr.n = e.contents(p.contents, &pr.objects)
	e.program(&pr)
	e.flush()
}
func (e *engine) initPage(p pageDesc) {
	s := e.state
	if !e.charge(Zero, uint64(contentStateBytes())) {
		return
	}
	*s = contentState{g: graphics{ctm: identity, clip: vector.Rect{X1: int(p.width), Y1: int(p.height)}, color: 0xff000000, tz: 1},
		tm: identity, lm: identity, page: p,
		mapPage: vector.Affine{A: 4.0 / 3, D: -4.0 / 3, E: -4 * float64(p.box[0]) / 3e6, F: 4 * float64(p.box[3]) / 3e6}}
}
func (e *engine) flush() {
	s := e.state
	if s.batchP == 0 || e.f.Code != OK {
		return
	}
	if c := e.l.CheckTime(); c != OK {
		e.set(c)
		return
	}
	// Public API only: first plan with empty integer clips. This prevents
	// painting a batch whose cumulative page edge capacity is already full.
	// Both public calls' work is charged; unique geometry is admitted once.
	for i := uint32(0); i < s.batchP; i++ {
		if !e.charge(Record, 1) {
			return
		}
		e.clips[i] = e.paint[i].Clip
		e.paint[i].Clip = vector.Rect{}
	}
	st := e.vectorCall()
	if st.Edges > MaxEdges-e.stats.Edges {
		e.set(SegmentLimit)
	} else {
		e.stats.Edges += st.Edges
	}
	for i := uint32(0); i < s.batchP; i++ {
		if !e.charge(Record, 1) {
			return
		}
		e.paint[i].Clip = e.clips[i]
	}
	if e.f.Code == OK {
		e.vectorCall()
	}
	e.set(e.l.CheckTime())
	s.batchC = 0
	s.batchP = 0
}
func (e *engine) vectorCall() vector.Stats {
	s := e.state
	b := &e.l.VectorBudget
	b.Max = min(uint64(vector.MaxWork), b.Used+e.l.Max-e.l.Used)
	if b.Max == b.Used {
		e.set(WorkLimit)
		return vector.Stats{}
	}
	if c := e.l.CheckTime(); c != OK {
		e.set(c)
		return vector.Stats{}
	}
	st, f := vector.Rasterize(vector.Scene{Commands: e.cmd[:s.batchC], Paints: e.paint[:s.batchP]},
		vector.Target{Pix: e.pix[:int(s.page.width)*int(s.page.height)], Width: int(s.page.width), Height: int(s.page.height), Stride: int(s.page.width)}, e.ws, b)
	e.set(e.l.Charge(Vector, st.Work))
	e.set(vectorCode(f.Code))
	e.set(e.l.CheckTime())
	return st
}
func (e *engine) emit(c vector.Command) {
	s := e.state
	if e.stats.Commands == MaxCommands || int(s.pathStart+s.pathN) >= len(e.path) {
		e.set(SceneLimit)
		return
	}
	if c.Verb == vector.Move {
		if e.stats.Contours == MaxContours {
			e.set(SceneLimit)
			return
		}
		e.stats.Contours++
		s.current = c.P[0]
		s.start = c.P[0]
		s.hasPoint = true
	} else if !s.hasPoint {
		e.set(MalformedContent)
		return
	}
	switch c.Verb {
	case vector.Line:
		s.current = c.P[0]
	case vector.Cubic:
		s.current = c.P[2]
	case vector.Close:
		s.current = s.start
	}
	e.charge(Record, 1)
	e.path[s.pathStart+s.pathN] = c
	s.pathN++
	e.stats.Commands++
}
func (e *engine) pathPoint(x, y float64) vector.Point {
	s := e.state
	p := vector.Point{X: x, Y: y}
	if s.glyph {
		p = e.mapped(s.g.ctm, p)
		for _, box := range [2][4]float64{s.fontBox, s.glyphBox} {
			if p.X < box[0] || p.X > box[2] || p.Y < box[1] || p.Y > box[3] {
				e.set(UnsupportedGlyph)
			}
		}
		return e.mapped(s.mapPage, p)
	}
	return e.mapped(e.multiply(s.mapPage, s.g.ctm), p)
}
func (e *engine) endPath(paint bool, rule vector.Rule) {
	s := e.state
	if s.pathN > 0 {
		if e.stats.Paints == MaxPaints {
			e.set(SceneLimit)
			return
		}
		if int(s.batchC+s.pathN) > len(e.cmd) || int(s.batchP) >= len(e.paint) {
			e.flush()
		}
		if e.f.Code != OK {
			return
		}
		for i := uint32(0); i < s.pathN; i++ {
			e.charge(Record, 1)
			e.cmd[s.batchC+i] = e.path[s.pathStart+i]
		}
		e.charge(Record, 1)
		e.paint[s.batchP] = vector.Paint{First: s.batchC, Count: s.pathN, Transform: identity, Clip: s.g.clip, Color: s.g.color, Rule: rule}
		if !paint {
			e.paint[s.batchP].Clip = vector.Rect{}
		}
		s.batchC += s.pathN
		s.batchP++
		e.stats.Paints++
	}
	if s.clipPending {
		s.g.clip = vector.Rect{X0: max(s.g.clip.X0, s.rect.X0), Y0: max(s.g.clip.Y0, s.rect.Y0), X1: min(s.g.clip.X1, s.rect.X1), Y1: min(s.g.clip.Y1, s.rect.Y1)}
		if s.g.clip.X1 < s.g.clip.X0 {
			s.g.clip.X1 = s.g.clip.X0
		}
		if s.g.clip.Y1 < s.g.clip.Y0 {
			s.g.clip.Y1 = s.g.clip.Y0
		}
	}
	s.pathN = 0
	s.hasPoint = false
	s.onlyRect = false
	s.clipPending = false
}
func byteColor(v float64) uint32 { return uint32(math.Floor(v*255 + 0.5)) }
func (e *engine) operator(op string, p *program) {
	s := e.state
	if s.glyph {
		if !s.metrics && op != "d1" {
			e.set(UnsupportedGlyph)
			return
		}
		switch op {
		case "d1", "q", "Q", "cm", "m", "l", "c", "v", "y", "h", "re", "f", "F", "f*", "n":
		default:
			e.set(UnsupportedGlyph)
			return
		}
	} else if op == "d1" {
		e.set(MalformedContent)
		return
	}
	pathOp := false
	switch op {
	case "m", "l", "c", "v", "y", "h", "re", "f", "F", "f*", "n", "W", "W*", "Do":
		pathOp = true
	}
	if s.bt && pathOp {
		e.set(MalformedContent)
		return
	}
	if s.clipPending && op != "n" && op != "f" && op != "F" && op != "f*" {
		e.set(UnsupportedClip)
		return
	}
	switch op {
	case "q":
		if !e.arity(0, "") {
			return
		}
		if int(s.depth)+int(s.outerDepth) >= 16 {
			e.set(GraphicsDepthLimit)
			return
		}
		e.charge(Stack, 1)
		s.saved[s.depth] = s.g
		s.depth++
	case "Q":
		if !e.arity(0, "") {
			return
		}
		if s.depth == 0 {
			e.set(MalformedContent)
			return
		}
		e.charge(Stack, 1)
		s.depth--
		s.g = s.saved[s.depth]
	case "cm":
		if !e.arity(6, "######") {
			return
		}
		a := vector.Affine{A: s.ops[0].num, B: s.ops[1].num, C: s.ops[2].num, D: s.ops[3].num, E: s.ops[4].num, F: s.ops[5].num}
		e.affine(a)
		s.g.ctm = e.multiply(s.g.ctm, a)
	case "m", "l":
		if !e.arity(2, "##") {
			return
		}
		verb := vector.Line
		if op == "m" {
			verb = vector.Move
		}
		s.onlyRect = false
		e.emit(vector.Command{Verb: verb, P: [3]vector.Point{e.pathPoint(s.ops[0].num, s.ops[1].num)}})
	case "c", "v", "y":
		n := 6
		if op != "c" {
			n = 4
		}
		if !e.arity(n, "######"[:n]) {
			return
		}
		var pts [3]vector.Point
		if op == "v" {
			pts[0] = s.current
			pts[1] = e.pathPoint(s.ops[0].num, s.ops[1].num)
			pts[2] = e.pathPoint(s.ops[2].num, s.ops[3].num)
		} else {
			pts[0] = e.pathPoint(s.ops[0].num, s.ops[1].num)
			pts[1] = e.pathPoint(s.ops[2].num, s.ops[3].num)
			if op == "y" {
				pts[2] = pts[1]
			} else {
				pts[2] = e.pathPoint(s.ops[4].num, s.ops[5].num)
			}
		}
		s.onlyRect = false
		e.emit(vector.Command{Verb: vector.Cubic, P: pts})
	case "h":
		if !e.arity(0, "") {
			return
		}
		s.onlyRect = false
		e.emit(vector.Command{Verb: vector.Close})
	case "re":
		if !e.arity(4, "####") {
			return
		}
		x, y, w, h := s.ops[0].num, s.ops[1].num, s.ops[2].num, s.ops[3].num
		a, b, c, d := e.pathPoint(x, y), e.pathPoint(x+w, y), e.pathPoint(x+w, y+h), e.pathPoint(x, y+h)
		only := s.pathN == 0
		e.emit(vector.Command{Verb: vector.Move, P: [3]vector.Point{a}})
		e.emit(vector.Command{Verb: vector.Line, P: [3]vector.Point{b}})
		e.emit(vector.Command{Verb: vector.Line, P: [3]vector.Point{c}})
		e.emit(vector.Command{Verb: vector.Line, P: [3]vector.Point{d}})
		e.emit(vector.Command{Verb: vector.Close})
		s.onlyRect = only && ((a.X == b.X && b.Y == c.Y && c.X == d.X && d.Y == a.Y) || (a.Y == b.Y && b.X == c.X && c.Y == d.Y && d.X == a.X)) &&
			a.X == math.Trunc(a.X) && a.Y == math.Trunc(a.Y) && c.X == math.Trunc(c.X) && c.Y == math.Trunc(c.Y)
		s.rect = vector.Rect{X0: int(min(a.X, c.X)), Y0: int(min(a.Y, c.Y)), X1: int(max(a.X, c.X)), Y1: int(max(a.Y, c.Y))}
	case "W", "W*":
		if !e.arity(0, "") {
			return
		}
		if !s.onlyRect {
			e.set(UnsupportedClip)
			return
		}
		s.clipPending = true
	case "f", "F", "f*", "n":
		if !e.arity(0, "") {
			return
		}
		rule := vector.NonZero
		if op == "f*" {
			rule = vector.EvenOdd
		}
		e.endPath(op != "n", rule)
	case "g", "rg":
		n := 1
		if op == "rg" {
			n = 3
		}
		if !e.arity(n, "###"[:n]) {
			return
		}
		for i := 0; i < n; i++ {
			if s.ops[i].num < 0 || s.ops[i].num > 1 {
				e.set(MalformedContent)
				return
			}
		}
		r := byteColor(s.ops[0].num)
		g, b := r, r
		if n == 3 {
			g = byteColor(s.ops[1].num)
			b = byteColor(s.ops[2].num)
		}
		s.g.color = 0xff000000 | r<<16 | g<<8 | b
	case "BT":
		if !e.arity(0, "") {
			return
		}
		if s.bt {
			e.set(MalformedContent)
			return
		}
		s.bt = true
		s.tm = identity
		s.lm = identity
	case "ET":
		if !e.arity(0, "") {
			return
		}
		if !s.bt {
			e.set(MalformedContent)
			return
		}
		s.bt = false
	case "Tc", "Tw", "Tz", "TL", "Ts", "Tr":
		if !e.arity(1, "#") {
			return
		}
		v := s.ops[0].num
		if !finite(v) {
			e.set(CoordinateLimit)
			return
		}
		switch op {
		case "Tc":
			s.g.tc = v
		case "Tw":
			s.g.tw = v
		case "TL":
			s.g.leading = v
		case "Ts":
			s.g.rise = v
		case "Tz":
			if v <= 0 || v > 256 {
				e.set(UnsupportedText)
			} else {
				s.g.tz = v / 100
			}
		case "Tr":
			if v != 0 {
				e.set(UnsupportedText)
			}
		}
	case "Tf", "Tm", "Td", "TD", "T*", "Tj", "TJ", "'", "\"":
		e.textOperator(op)
	case "Do":
		if !e.arity(1, "n") {
			return
		}
		n := e.resource(s.page.resources, "XObject", &s.ops[0].name, int(s.ops[0].count))
		e.flush()
		e.image(n, e.multiply(s.mapPage, s.g.ctm), s.g.clip, true, 1)
	case "d1":
		if !e.arity(6, "######") {
			return
		}
		if s.metrics {
			e.set(UnsupportedGlyph)
			return
		}
		s.wx = s.ops[0].num
		if s.ops[1].num != 0 || s.wx < 0 {
			e.set(UnsupportedGlyph)
		}
		s.glyphBox = [4]float64{s.ops[2].num, s.ops[3].num, s.ops[4].num, s.ops[5].num}
		for _, v := range s.glyphBox {
			if !finite(v) {
				e.set(CoordinateLimit)
			}
		}
		if s.glyphBox[0] > s.glyphBox[2] || s.glyphBox[1] > s.glyphBox[3] {
			e.set(Malformed)
		}
		s.metrics = true
	case "S", "s", "B", "B*", "b", "b*", "w", "J", "j", "M", "d", "G", "RG":
		e.set(UnsupportedStroke)
	case "BI", "ID", "EI":
		e.set(UnsupportedImage)
	default:
		e.set(UnsupportedFeature)
	}
}
