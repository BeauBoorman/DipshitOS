package webrender

import (
	"strings"
	"virelai/webstyle"
)

// ItemKind is the kind of painted primitive.
type ItemKind uint8

const (
	// ItemRect is a solid background/border rectangle.
	ItemRect ItemKind = iota
	// ItemText is a run of text.
	ItemText
	// ItemRule is a 1-pixel horizontal rule.
	ItemRule
	// ItemImage is an image placeholder box.
	ItemImage
)

// Item is one positioned paint primitive in content coordinates (0,0 = top
// left of the document, scrolling is applied at paint time).
type Item struct {
	Box                  *Box // CSS style source; nil for logical-size legacy items
	Kind                 ItemKind
	X, Y                 int
	W, H                 int
	Text                 string
	Size                 int // font scale (logical; the engine maps it to a pixel size)
	FontPx, LineHeightPx int // positive CSS used sizes; zero is the legacy path
	Mono                 bool
	Serif                bool
	Bold                 bool
	Italic               bool
	Color                uint32
	Bg                   uint32
	Target               string // link target, when the run is inside an <a href>
	Img                  *Image // decoded pixels, when this is a real <img>
}

// Link is a hit-testable link rectangle in content coordinates.
type Link struct {
	X, Y, W, H int
	Target     string
}

// Layout is the positioned result of laying a document out at one width.
//
// Text is the engine the layout was measured with. Paint reuses it, so a run is
// wrapped and drawn with identical metrics — measuring with one face and
// painting with another silently mis-wraps every line.
type Layout struct {
	BoxTree   *BoxTree // retained style copies and border geometry for M93e
	Text      TextEngine
	Items     []Item
	Links     []Link
	Width     int
	Height    int
	Lines     int
	Blocks    int
	Truncated bool
}

// MaxItems caps the primitive list (a static bound; overflow is visible via
// Layout.Truncated rather than a panic).
const MaxItems = 24000

type inlineRun struct {
	text   string
	st     Style
	target string
}

type builder struct {
	items     []Item
	links     []Link
	t         TextEngine
	images    ImageResolver
	right     int // absolute right edge of the content box
	lineX     int // absolute left edge of the current inline flow
	y         int
	lines     int
	blocks    int
	truncated bool
	inline    []inlineRun
}

// LayoutDocument lays out a parsed document in a content box of the given
// pixel width. t may be nil, which selects the built-in 8x8 bitmap engine — the
// no-font fallback. An optional ImageResolver lets <img> elements be decoded
// without layout ever touching a file itself (ADR 0028 D1/D3).
func LayoutDocument(doc *Document, width int, t TextEngine, images ...ImageResolver) *Layout {
	if width < 32 {
		width = 32
	}
	tree, _ := BuildBoxTree(doc, compatibilityStyles(doc))
	tree.compatibility = true
	l, _ := LayoutBoxes(tree, webstyle.Viewport{Width: width, Height: 384}, t, images...)
	return l
}

// layoutCompatibility is the legacy formatting policy inside LayoutBoxes.
// It consumes the box tree, not the DOM; its shared inline/replaced helpers
// preserve existing pixels and logical font metrics until M93f's handoff.
func layoutCompatibility(tree *BoxTree, width int, t TextEngine, images ...ImageResolver) *Layout {
	b := &builder{t: t, right: width}
	if len(images) > 0 && images[0] != nil {
		b.images = images[0]
	}
	if tree.Root != nil {
		b.walkChildren(tree.Root, StyleFor("body"), 0)
	}
	b.flushInline()
	return &Layout{
		Text:      t,
		BoxTree:   tree,
		Items:     b.items,
		Links:     b.links,
		Width:     width,
		Height:    b.y,
		Lines:     b.lines,
		Blocks:    b.blocks,
		Truncated: b.truncated || tree.Truncated,
	}
}

// ScrollMax is the largest useful scroll offset for a viewport height.
func ScrollMax(l *Layout, viewH int) int {
	if l.Height <= viewH {
		return 0
	}
	return l.Height - viewH
}

func (b *builder) cap() bool {
	if len(b.items) >= MaxItems {
		b.truncated = true
		return true
	}
	return false
}

// walkChildren walks a node's children, sending text and inline elements to
// the inline buffer and block elements to block().
func (b *builder) walkChildren(n *Box, st Style, indent int) {
	for _, box := range n.Children {
		if b.truncated {
			return
		}
		if box.Anonymous {
			b.walkChildren(box, st, indent)
			continue
		}
		c := box.Node
		if c.Kind == KindText {
			b.pushText(c.Text, st, "")
			continue
		}
		es := StyleFor(c.Tag)
		if es.Skip && c.Tag != "noscript" {
			continue
		}
		if c.Tag == "br" {
			b.hardBreak()
			continue
		}
		if c.Tag == "input" {
			b.emitControl(c)
			continue
		}
		if BlockElement(c.Tag) {
			b.block(box, es, indent)
			continue
		}
		b.inlineElement(box, mergeInline(st, es), indent, "")
	}
}

func (b *builder) inlineElement(box *Box, st Style, indent int, inherited string) {
	e := box.Node
	target := inherited
	if e.Tag == "a" {
		if href := e.Attr("href"); href != "" {
			target = href
		}
	}
	for _, childBox := range box.Children {
		if childBox.Anonymous {
			b.walkChildren(childBox, st, indent)
			continue
		}
		c := childBox.Node
		if c.Kind == KindText {
			b.pushText(c.Text, st, target)
			continue
		}
		es := StyleFor(c.Tag)
		if es.Skip && c.Tag != "noscript" {
			continue
		}
		if c.Tag == "br" {
			b.hardBreak()
			continue
		}
		if c.Tag == "input" {
			b.emitControl(c)
			continue
		}
		if BlockElement(c.Tag) {
			b.block(childBox, es, indent)
			continue
		}
		child := mergeInline(st, es)
		ct := target
		if c.Tag == "a" {
			ct = c.Attr("href")
		}
		b.inlineElement(childBox, child, indent, ct)
	}
}

func (b *builder) block(box *Box, st Style, indent int) {
	e := box.Node
	b.flushInline()
	if b.cap() {
		return
	}
	b.blocks++
	b.y += st.MarginTop
	left := indent + st.Indent
	if b.right-left < 16 {
		left = b.right - 16
		if left < 0 {
			left = 0
		}
	}
	inner := b.right - left
	top := b.y

	switch e.Tag {
	case "hr":
		b.items = append(b.items, Item{Kind: ItemRule, X: left, Y: b.y + 3, W: inner, H: 1, Color: ColorRule})
		b.y += 4
	case "pre":
		b.emitPre(e, left, inner)
	case "blockquote":
		barIdx := len(b.items)
		b.items = append(b.items, Item{Kind: ItemRect, X: left, Y: b.y, W: 3, H: 1, Bg: ColorAccent})
		contentLeft := left + 6
		b.lineX = contentLeft
		b.walkChildren(box, st, contentLeft)
		b.flushInline()
		b.lineX = 0
		if h := b.y - b.items[barIdx].Y; h > 1 {
			b.items[barIdx].H = h
		}
	case "li":
		b.pushText("* ", Style{Size: st.Size, Color: ColorMuted}, "")
		b.lineX = left
		b.walkChildren(box, st, left)
		b.flushInline()
		b.lineX = 0
	case "img":
		b.emitImage(e, left, inner)
	case "table":
		b.emitTable(box, left, inner)
	case "input", "textarea", "select", "button":
		b.lineX = left
		b.emitControl(e)
		b.lineX = 0
	default:
		b.lineX = left
		b.walkChildren(box, st, left)
		b.flushInline()
		b.lineX = 0
	}
	box.Content = BoxRect{X: left, Y: top, W: inner, H: b.y - top}
	box.Padding, box.Border = box.Content, box.Content
	box.Margin = BoxRect{X: left, Y: top - st.MarginTop, W: inner, H: b.y - top + st.MarginTop + st.MarginBottom}
	b.y += st.MarginBottom
}

func mergeInline(parent, child Style) Style {
	out := child
	// Family is exclusive, so it cannot OR-merge like weight: the cascade
	// resolves each node's FontFamily, and a styled child always carries its
	// own. A child carrying neither flag inherits the parent's family.
	if !child.Mono && !child.Serif {
		out.Mono, out.Serif = parent.Mono, parent.Serif
	}
	out.Bold = child.Bold || parent.Bold
	out.Italic = child.Italic || parent.Italic
	if out.Color == 0 {
		out.Color = parent.Color
	}
	if out.Size == 0 {
		out.Size = parent.Size
	}
	return out
}

// pushText collapses HTML whitespace (runs of space/tab/newline become one
// space) unless the run is preformatted, then queues it for line building.
func (b *builder) pushText(text string, st Style, target string) {
	if text == "" {
		return
	}
	if !st.Mono {
		text = collapseWS(text)
	}
	if text == "" {
		return
	}
	b.inline = append(b.inline, inlineRun{text: text, st: st, target: target})
}

// hardBreak forces the pending inline content onto the next line.
func (b *builder) hardBreak() {
	if len(b.inline) == 0 {
		return
	}
	b.inline = append(b.inline, inlineRun{text: "\n", st: Style{Size: 1, Color: ColorText}})
}

func collapseWS(s string) string {
	if s == "" {
		return ""
	}
	lead := isWSByte(s[0])
	trail := isWSByte(s[len(s)-1])
	var b strings.Builder
	b.Grow(len(s))
	pend := false
	for i := 0; i < len(s); i++ {
		if isWSByte(s[i]) {
			pend = true
			continue
		}
		if pend && b.Len() > 0 {
			b.WriteByte(' ')
		}
		pend = false
		b.WriteByte(s[i])
	}
	core := b.String()
	if core == "" {
		if lead || trail {
			return " "
		}
		return ""
	}
	if lead {
		core = " " + core
	}
	if trail {
		core += " "
	}
	return core
}

func isWSByte(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

// flushInline wraps the queued inline runs into lines and emits text items
// (plus link rectangles and link underlines).
func (b *builder) flushInline() {
	if len(b.inline) == 0 {
		return
	}
	runs := b.inline
	b.inline = make([]inlineRun, 0, 8)

	type seg struct {
		text   string
		st     Style
		target string
		w      int
		space  bool
		nl     bool
	}
	var segs []seg
	for _, r := range runs {
		if r.text == "\n" {
			segs = append(segs, seg{nl: true})
			continue
		}
		i := 0
		for i < len(r.text) {
			if r.text[i] == ' ' {
				n := 0
				for i < len(r.text) && r.text[i] == ' ' {
					i++
					n++
				}
				// A space costs what the engine MEASURES for one, not the
				// cell advance: Measure and wrap must price text identically
				// or every paragraph breaks in the wrong place.
				segs = append(segs, seg{space: true, w: n * b.t.Measure(" ", r.st), st: r.st})
				continue
			}
			j := i
			for j < len(r.text) && r.text[j] != ' ' {
				j++
			}
			word := r.text[i:j]
			segs = append(segs, seg{text: word, st: r.st, target: r.target, w: b.t.Measure(word, r.st)})
			i = j
		}
	}

	x := b.lineX
	y := b.y
	avail := b.right - b.lineX
	if avail < 16 {
		avail = 16
	}
	wid := b.lineX + avail
	lineH := b.t.LineHeight(Style{Size: 1})
	started := false
	counted := false

	for _, sg := range segs {
		if b.truncated {
			break
		}
		if sg.nl {
			if started {
				y += lineH
				started = false
				counted = false
			}
			continue
		}
		if sg.space {
			if started {
				x += sg.w
			}
			continue
		}
		if started && x+sg.w > wid {
			y += lineH
			x = b.lineX
			started = false
			counted = false
			lineH = b.t.LineHeight(Style{Size: 1})
		}
		lh := b.t.LineHeight(sg.st)
		if lh > lineH {
			lineH = lh
		}
		if !counted {
			b.lines++
			counted = true
		}
		color := sg.st.Color
		if color == 0 {
			color = ColorText
		}
		if b.cap() {
			break
		}
		b.items = append(b.items, Item{
			Kind: ItemText, X: x, Y: y, W: sg.w, H: lh,
			Text: sg.text, Size: sg.st.Size, Mono: sg.st.Mono, Serif: sg.st.Serif, Bold: sg.st.Bold, Italic: sg.st.Italic,
			Color: color, Target: sg.target,
		})
		if sg.target != "" && len(b.links) < MaxItems {
			b.links = append(b.links, Link{X: x, Y: y, W: sg.w, H: lh, Target: sg.target})
			// Underline: the decoration that makes a link readable without
			// color (the Zig renderer's rule, kept for the same reason).
			b.items = append(b.items, Item{Kind: ItemRule, X: x, Y: y + 7, W: sg.w, H: 1, Color: ColorAccent})
		}
		x += sg.w
		started = true
	}
	if started {
		y += lineH
	}
	b.y = y
	if b.y < 0 {
		b.y = 0
	}
}

func (b *builder) emitPre(e *Node, left, inner int) {
	raw := rawText(e)
	raw = strings.ReplaceAll(raw, "\r\n", "\n")
	lines := strings.Split(raw, "\n")
	// Drop a single trailing empty line produced by a closing tag on its
	// own line; keep everything else verbatim so nothing is lost.
	if n := len(lines); n > 1 && strings.TrimSpace(lines[n-1]) == "" {
		lines = lines[:n-1]
	}
	monoSt := Style{Size: 1, Mono: true}
	stride := b.t.LineHeight(monoSt)
	if stride < 8 {
		stride = 8
	}
	box := Item{Kind: ItemRect, X: left, Y: b.y, W: inner, H: len(lines)*stride + 6, Bg: ColorSurface}
	b.items = append(b.items, box)
	ty := b.y + 3
	// A 72-column RFC line must survive a 512px viewport: paint clips, the
	// line is not destroyed. Ellipsis is only for a hostile run that would
	// otherwise become one unbounded item (ADR 0028 D6).
	const maxPreRunes = 256
	for _, ln := range lines {
		if rs := []rune(ln); len(rs) > maxPreRunes {
			if maxPreRunes > 1 {
				ln = string(rs[:maxPreRunes-1]) + "\u2026"
			} else {
				ln = "\u2026"
			}
		}
		if ln != "" {
			b.items = append(b.items, Item{Kind: ItemText, X: left + 4, Y: ty, W: b.t.Measure(ln, monoSt), H: stride, Text: ln, Size: 1, Mono: true, Color: ColorText})
		}
		ty += stride
		b.lines++
	}
	b.y = box.Y + box.H
}

func (b *builder) emitImage(e *Node, left, inner int) {
	label := e.Attr("alt")
	if label == "" {
		label = e.Attr("src")
	}
	if label == "" {
		label = "img"
	}
	hintW, hintH := attrPx(e, "width"), attrPx(e, "height")
	// ADR 0028 S3: an <img> whose bytes the app can supply is decoded and drawn
	// at its intrinsic size, capped to the content box. HTML width/height are
	// source hints (D2: a page cannot restyle itself; attributes are not a
	// cascade). A missing, undecodable, or unresolvable image keeps the labeled
	// placeholder box — visible, never blank (D5).
	if b.images != nil {
		if src := e.Attr("src"); src != "" {
			if data, ok := b.images(src); ok {
				if img, err := DecodeImage(data); err == nil && img != nil {
					w, h := img.Width, img.Height
					if hintW > 0 && hintH > 0 {
						w, h = hintW, hintH
					} else if hintW > 0 && w > 0 {
						h = h * hintW / w
						w = hintW
					} else if hintH > 0 && h > 0 {
						w = w * hintH / h
						h = hintH
					}
					if w > inner && w > 0 {
						h = h * inner / w
						w = inner
					}
					if w < 1 || h < 1 {
						w, h = 1, 1
					}
					b.items = append(b.items, Item{Kind: ItemImage, X: left, Y: b.y, W: w, H: h, Text: label, Color: ColorMuted, Img: img})
					b.y += h
					return
				}
			}
		}
	}
	w := inner
	if hintW > 0 {
		w = hintW
	}
	if w > inner {
		w = inner
	}
	if w > 96 && hintW == 0 {
		w = 96
	}
	h := 40
	if hintH > 0 {
		h = hintH
	}
	if w < 1 {
		w = 1
	}
	if h < 1 {
		h = 1
	}
	b.items = append(b.items, Item{Kind: ItemImage, X: left, Y: b.y, W: w, H: h, Text: label, Color: ColorMuted})
	b.y += h
}

func attrPx(e *Node, name string) int {
	v := strings.TrimSpace(e.Attr(name))
	v = strings.TrimSuffix(strings.ToLower(v), "px")
	if v == "" {
		return 0
	}
	n := 0
	for i := 0; i < len(v); i++ {
		c := v[i]
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
		if n > 4096 {
			return 4096
		}
	}
	return n
}

func (b *builder) emitTable(box *Box, left, inner int) {
	e := box.Node
	rows := collectRows(e)
	if len(rows) == 0 {
		// A malformed table still renders its text (ADR 0028 D5).
		b.lineX = left
		b.walkChildren(box, Style{Size: 1, Color: ColorText}, left)
		b.flushInline()
		b.lineX = 0
		return
	}
	cols := 1
	for _, r := range rows {
		if len(r.cells) > cols {
			cols = len(r.cells)
		}
	}
	if cols > 8 {
		cols = 8
	}
	gutter := 2
	colw := (inner - gutter*(cols-1)) / cols
	if colw < 8 {
		colw = 8
	}
	lh := b.t.LineHeight(Style{Size: 1})
	startY := b.y
	outerRight := b.right
	for _, r := range rows {
		rowTop := b.y
		rowBottom := rowTop
		ncells := len(r.cells)
		if ncells > cols {
			ncells = cols
		}
		for c := 0; c < ncells; c++ {
			cell := r.cells[c]
			st := StyleFor(cell.tag)
			st.Bold = st.Bold || r.header
			cx := left + c*(colw+gutter)
			cy := rowTop + 2
			cellRight := cx + colw
			if cellRight > outerRight {
				cellRight = outerRight
			}
			b.y = cy
			b.lineX = cx
			b.right = cellRight
			b.pushText(cell.text, st, "")
			b.flushInline()
			if b.y > rowBottom {
				rowBottom = b.y
			}
			b.right = outerRight
			b.lineX = 0
		}
		if rowBottom < rowTop+lh+4 {
			rowBottom = rowTop + lh + 4
		}
		b.y = rowBottom + 3
		if r.header {
			b.items = append(b.items, Item{Kind: ItemRule, X: left, Y: b.y - 1, W: cols*colw + gutter*(cols-1), H: 1, Color: ColorRule})
		}
	}
	if b.y == startY {
		b.y += lh
	}
	b.lineX = 0
}

// emitControl paints a static form control (ADR 0028 D2: display only).
func (b *builder) emitControl(e *Node) {
	if e.Tag == "input" && strings.EqualFold(e.Attr("type"), "hidden") {
		return
	}
	b.flushInline()
	if b.cap() {
		return
	}
	left := b.lineX
	inner := b.right - left
	if inner < 16 {
		inner = 16
	}
	lh := b.t.LineHeight(Style{Size: 1})
	typ := strings.ToLower(e.Attr("type"))
	label := controlLabel(e, typ)
	switch {
	case e.Tag == "input" && (typ == "checkbox" || typ == "radio"):
		// Replaced inline: the 8px box sits on the current line and the
		// surrounding <label> text continues beside it. The value attribute
		// is not painted — it would duplicate the caption.
		box := 8
		x := left
		b.items = append(b.items, Item{Kind: ItemRect, X: x, Y: b.y + 1, W: box, H: box, Bg: ColorSurface})
		b.items = append(b.items, Item{Kind: ItemRule, X: x, Y: b.y + 1, W: box, H: 1, Color: ColorRule})
		b.items = append(b.items, Item{Kind: ItemRule, X: x, Y: b.y + box, W: box, H: 1, Color: ColorRule})
		b.items = append(b.items, Item{Kind: ItemRule, X: x, Y: b.y + 1, W: 1, H: box, Color: ColorRule})
		b.items = append(b.items, Item{Kind: ItemRule, X: x + box - 1, Y: b.y + 1, W: 1, H: box, Color: ColorRule})
		b.lineX = x + box + 4
		return
	default:
		w, h := inner, lh+6
		if e.Tag == "textarea" {
			h = lh*3 + 6
		}
		if e.Tag == "input" && typ != "submit" && typ != "button" && typ != "reset" {
			if w > 160 {
				w = 160
			}
		} else if e.Tag == "button" || typ == "submit" || typ == "reset" || typ == "button" {
			need := b.t.Measure(label, Style{Size: 1}) + 16
			if need < w {
				w = need
			}
			if w < 32 {
				w = 32
			}
		} else if e.Tag == "select" {
			if w > 160 {
				w = 160
			}
		}
		if w > inner {
			w = inner
		}
		b.items = append(b.items, Item{Kind: ItemRect, X: left, Y: b.y, W: w, H: h, Bg: ColorSurface})
		b.items = append(b.items, Item{Kind: ItemRule, X: left, Y: b.y, W: w, H: 1, Color: ColorRule})
		b.items = append(b.items, Item{Kind: ItemRule, X: left, Y: b.y + h - 1, W: w, H: 1, Color: ColorRule})
		b.items = append(b.items, Item{Kind: ItemRule, X: left, Y: b.y, W: 1, H: h, Color: ColorRule})
		b.items = append(b.items, Item{Kind: ItemRule, X: left + w - 1, Y: b.y, W: 1, H: h, Color: ColorRule})
		if label != "" {
			st := Style{Size: 1, Color: ColorText}
			tx := label
			cols := (w - 8) / b.t.Advance(st)
			if cols < 1 {
				cols = 1
			}
			if rs := []rune(tx); len(rs) > cols {
				tx = string(rs[:cols])
			}
			b.items = append(b.items, Item{Kind: ItemText, X: left + 4, Y: b.y + 3, W: b.t.Measure(tx, st), H: lh, Text: tx, Size: 1, Color: ColorText})
		}
		b.y += h + 2
	}
	b.lineX = 0
}

func controlLabel(e *Node, typ string) string {
	switch e.Tag {
	case "button":
		if t := collapseWS(rawText(e)); t != "" {
			return t
		}
		return "button"
	case "textarea":
		if t := rawText(e); strings.TrimSpace(t) != "" {
			return collapseWS(t)
		}
		if p := e.Attr("placeholder"); p != "" {
			return p
		}
		if n := e.Attr("name"); n != "" {
			return n
		}
		return "textarea"
	case "select":
		if t := selectLabel(e); t != "" {
			return t
		}
		if n := e.Attr("name"); n != "" {
			return n
		}
		return "select"
	}
	if v := e.Attr("value"); v != "" {
		return v
	}
	if p := e.Attr("placeholder"); p != "" {
		return p
	}
	if n := e.Attr("name"); n != "" {
		return n
	}
	if typ != "" {
		return typ
	}
	return "input"
}

func selectLabel(e *Node) string {
	var selected, first string
	var walk func(*Node)
	walk = func(n *Node) {
		for _, c := range n.Children {
			if c.Kind != KindElement {
				continue
			}
			if c.Tag == "option" {
				t := collapseWS(rawText(c))
				if first == "" {
					first = t
				}
				if c.HasAttr("selected") {
					selected = t
				}
				continue
			}
			walk(c)
		}
	}
	walk(e)
	if selected != "" {
		return selected
	}
	return first
}

type tableRow struct {
	cells  []tableCell
	header bool
}

type tableCell struct {
	tag  string
	text string
}

func collectRows(e *Node) []tableRow {
	var rows []tableRow
	var walk func(n *Node)
	walk = func(n *Node) {
		for _, c := range n.Children {
			if c.Kind != KindElement {
				continue
			}
			switch c.Tag {
			case "tr":
				var r tableRow
				hdr := true
				for _, cell := range c.Children {
					if cell.Kind != KindElement {
						continue
					}
					if cell.Tag == "td" || cell.Tag == "th" {
						if cell.Tag == "td" {
							hdr = false
						}
						r.cells = append(r.cells, tableCell{tag: cell.Tag, text: collapseWS(rawText(cell))})
					}
				}
				r.header = hdr && len(r.cells) > 0
				if len(rows) < 64 && len(r.cells) > 0 {
					rows = append(rows, r)
				}
			case "thead", "tbody", "tfoot", "table":
				walk(c)
			}
		}
	}
	walk(e)
	return rows
}

// rawText flattens an element's text content (all descendants, in order).
func rawText(n *Node) string {
	var b strings.Builder
	var walk func(*Node)
	walk = func(x *Node) {
		if x.Kind == KindText {
			b.WriteString(x.Text)
			return
		}
		if x.Tag == "br" {
			b.WriteByte('\n')
			return
		}
		if metadataTag(x.Tag) {
			return
		}
		for _, c := range x.Children {
			walk(c)
		}
	}
	walk(n)
	return b.String()
}

// TextContent returns the document's flattened readable text (used by the
// browser's "degrade to readable text" path and by tests).
func TextContent(n *Node) string { return collapseWS(rawText(n)) }
