package webrender

import (
	"strings"
	"unicode/utf8"
	"virelai/webstyle"
)

// BoxRect is an integer CSS-pixel rectangle in document coordinates.
type BoxRect struct{ X, Y, W, H int }

// Box owns its style copy and generated fragments. Node is source identity,
// never a CSS pointer. Anonymous boxes and split inline fragments count
// toward the same budget as element/text boxes.
type Box struct {
	Node                             *Node
	Style                            webstyle.ComputedStyle
	Children                         []*Box
	parent                           *Box
	Anonymous                        bool
	Content, Padding, Border, Margin BoxRect
	inline                           bool
	intrinsic                        int
	intrinsicSet                     bool
	measured                         bool
	measureContaining, measureW      int
	measureContentH, measureBorderH  int
	start, end, linkStart, linkEnd   int
}

type BoxTree struct {
	Root          *Box
	Boxes         []*Box
	Truncated     bool
	diagnostics   []webstyle.Diagnostic
	compatibility bool
}

// BuildBoxTree constructs CSS 2.1 anonymous blocks and split inline boxes,
// and blockifies flex items. display:none and inert metadata never produce
// boxes or hit regions. Bounded partial results carry a terminal diagnostic.
func BuildBoxTree(doc *Document, style func(*Node) webstyle.ComputedStyle) (*BoxTree, []webstyle.Diagnostic) {
	tree := &BoxTree{}
	if doc == nil || doc.Root == nil || style == nil {
		tree.notice(webstyle.DiagnosticInvalid, "invalid-input: document/style")
		return tree, tree.diagnostics
	}
	textBytes := 0
	var build func(*Node, int) []*Box
	build = func(n *Node, depth int) []*Box {
		if tree.Truncated {
			return nil
		}
		if n == nil {
			tree.notice(webstyle.DiagnosticInvalid, "invalid-input: nil node")
			return nil
		}
		if depth > webstyle.MaxDepth {
			tree.limit("layout-depth-limit")
			return nil
		}
		s := style(n)
		if s.Display == webstyle.DisplayNone || (n.Kind == KindElement && metadataTag(n.Tag)) {
			return nil
		}
		if n.Kind == KindText {
			textBytes += len(n.Text)
			if textBytes > webstyle.MaxHTMLBytes {
				tree.limit("html-byte-limit")
				return nil
			}
			b := tree.add(n, s, false, true)
			if b == nil {
				return nil
			}
			return []*Box{b}
		}
		isInline := s.Display == webstyle.DisplayInline && n != doc.Root
		var b *Box
		if !isInline {
			b = tree.add(n, s, false, false)
			if b == nil {
				return nil
			}
		}
		var children []*Box
		for _, c := range n.Children {
			children = append(children, build(c, depth+1)...)
			if tree.Truncated {
				break
			}
		}
		if isInline {
			// An inline with a block descendant splits into inline fragments
			// around that block, bubbling it to the nearest block container.
			var out []*Box
			var run []*Box
			flush := func() {
				if len(run) == 0 {
					return
				}
				b := tree.add(n, s, false, true)
				if b != nil {
					b.Children = run
					out = append(out, b)
				}
				run = nil
			}
			for _, c := range children {
				if c.inline {
					run = append(run, c)
				} else {
					flush()
					out = append(out, c)
				}
			}
			flush()
			if len(children) == 0 {
				if b := tree.add(n, s, false, true); b != nil {
					out = append(out, b)
				}
			}
			return out
		}
		if s.Display == webstyle.DisplayFlex {
			var text []*Box
			flush := func() {
				if !meaningful(text) {
					text = nil
					return
				}
				a := tree.add(nil, anonymousStyle(s), true, false)
				if a != nil {
					a.Children = text
					b.Children = append(b.Children, a)
				}
				text = nil
			}
			for _, c := range children {
				if c.Node != nil && c.Node.Kind == KindText {
					text = append(text, c)
					continue
				}
				flush()
				c.inline = false
				b.Children = append(b.Children, c)
			}
			flush()
		} else {
			mixed := false
			for _, c := range children {
				if !c.inline {
					mixed = true
					break
				}
			}
			if !mixed {
				b.Children = children
			} else {
				var run []*Box
				flush := func() {
					if !meaningful(run) {
						run = nil
						return
					}
					a := tree.add(nil, anonymousStyle(s), true, false)
					if a != nil {
						a.Children = run
						b.Children = append(b.Children, a)
					}
					run = nil
				}
				for _, c := range children {
					if c.inline {
						run = append(run, c)
					} else {
						flush()
						b.Children = append(b.Children, c)
					}
				}
				flush()
			}
		}
		return []*Box{b}
	}
	result := build(doc.Root, 0)
	if len(result) != 0 {
		tree.Root = result[0]
	}
	if doc.Truncated {
		tree.limit("html-truncated")
	}
	for _, b := range tree.Boxes {
		for _, c := range b.Children {
			c.parent = b
		}
	}
	return tree, append([]webstyle.Diagnostic(nil), tree.diagnostics...)
}

func metadataTag(tag string) bool {
	switch tag {
	case "head", "script", "style", "title", "meta", "link", "template":
		return true
	}
	return false
}

func anonymousStyle(s webstyle.ComputedStyle) webstyle.ComputedStyle {
	return webstyle.ComputedStyle{Display: webstyle.DisplayBlock, FontFamily: s.FontFamily,
		FontSize: s.FontSize, LineHeight: s.LineHeight, FontWeight: s.FontWeight, FontStyle: s.FontStyle,
		Color: s.Color, TextAlign: s.TextAlign, WhiteSpace: s.WhiteSpace}
}

func meaningful(boxes []*Box) bool {
	for _, b := range boxes {
		if b.Node != nil {
			if b.Node.Kind != KindText || strings.TrimSpace(b.Node.Text) != "" || b.Style.WhiteSpace != webstyle.WhiteSpaceNormal {
				return true
			}
		}
		if meaningful(b.Children) {
			return true
		}
	}
	return false
}

func (t *BoxTree) add(n *Node, s webstyle.ComputedStyle, anon, inline bool) *Box {
	if len(t.Boxes) >= webstyle.MaxBoxes {
		t.limit("box-limit")
		return nil
	}
	b := &Box{Node: n, Style: s, Anonymous: anon, inline: inline}
	t.Boxes = append(t.Boxes, b)
	return b
}

func appendDiagnostic(ds []webstyle.Diagnostic, kind webstyle.DiagnosticKind, text string) []webstyle.Diagnostic {
	if len(ds) >= webstyle.MaxDiagnostics {
		return ds
	}
	if len(ds) == webstyle.MaxDiagnostics-1 {
		kind, text = webstyle.DiagnosticLimit, "diagnostics-truncated"
	}
	if len(text) > webstyle.MaxDiagnosticTextBytes {
		text = text[:webstyle.MaxDiagnosticTextBytes]
	}
	return append(ds, webstyle.Diagnostic{Kind: kind, Text: text})
}
func (t *BoxTree) notice(kind webstyle.DiagnosticKind, text string) {
	t.diagnostics = appendDiagnostic(t.diagnostics, kind, text)
}
func (t *BoxTree) limit(text string) {
	if !t.Truncated {
		t.notice(webstyle.DiagnosticLimit, text)
	}
	t.Truncated = true
}

const maxLayoutCoordinate = 1048576

type usedEdges struct{ top, right, bottom, left int }
type marginStrut struct{ positive, negative int }

func strut(n int) marginStrut { return marginStrut{positive: max(0, n), negative: min(0, n)} }
func (a marginStrut) join(b marginStrut) marginStrut {
	return marginStrut{positive: max(a.positive, b.positive), negative: min(a.negative, b.negative)}
}
func (a marginStrut) value() int { return a.positive + a.negative }

type flowMargins struct {
	top, bottom marginStrut
	through     bool
}

type boxLayout struct {
	tree                *BoxTree
	out                 *Layout
	diagnostics         []webstyle.Diagnostic
	images              ImageResolver
	stopped, horizontal bool
}

// LayoutBoxes resolves the frozen subset at a CSS viewport. Geometry is
// independent of framebuffer/font files; measurement uses the injected seam.
// Existing callers enter via the UA-width compatibility adapter.
func LayoutBoxes(tree *BoxTree, viewport webstyle.Viewport, t TextEngine, images ...ImageResolver) (*Layout, []webstyle.Diagnostic) {
	if t == nil {
		t = Bitmap{}
	}
	l := &Layout{Text: t, BoxTree: tree, Width: viewport.Width}
	if tree == nil || viewport.Width <= 0 || viewport.Height <= 0 || viewport.Width > maxLayoutCoordinate || viewport.Height > maxLayoutCoordinate {
		return l, []webstyle.Diagnostic{{Kind: webstyle.DiagnosticInvalid, Text: "invalid-input: tree/viewport"}}
	}
	ds := append([]webstyle.Diagnostic(nil), tree.diagnostics...)
	if tree.compatibility {
		l = layoutCompatibility(tree, viewport.Width, t, images...)
		if len(l.Items) > webstyle.MaxPaintItems {
			l.Items = l.Items[:webstyle.MaxPaintItems]
			l.Truncated = true
		}
		return l, ds
	}
	b := &boxLayout{tree: tree, out: l, diagnostics: ds}
	if len(images) > 0 {
		b.images = images[0]
	}
	for _, box := range tree.Boxes {
		box.intrinsicSet, box.measured = false, false
		box.Content, box.Padding, box.Border, box.Margin = BoxRect{}, BoxRect{}, BoxRect{}, BoxRect{}
	}
	if tree.Root != nil {
		b.layout(tree.Root, viewport.Width, -1, -1, true, 0)
		l.Height = tree.Root.Border.H
	}
	for _, it := range l.Items {
		l.Height = max(l.Height, it.Y+it.H)
		if it.X < 0 || it.X+it.W > viewport.Width {
			b.horizontal = true
		}
	}
	if b.horizontal {
		b.notice(webstyle.DiagnosticUnsupported, "horizontal-clipped")
	}
	l.Truncated = l.Truncated || tree.Truncated || b.stopped
	if l.Truncated {
		if len(l.Items) >= webstyle.MaxPaintItems {
			l.Items = l.Items[:webstyle.MaxPaintItems-1]
		}
		l.Items = append(l.Items, Item{Kind: ItemText, Y: min(max(0, l.Height), maxLayoutCoordinate-18), W: 200, H: 18,
			Text: "[layout truncated]", Size: 1, Color: ColorError})
		l.Height = min(maxLayoutCoordinate, l.Height+18)
	}
	return l, b.diagnostics
}

func (b *boxLayout) notice(kind webstyle.DiagnosticKind, text string) {
	b.diagnostics = appendDiagnostic(b.diagnostics, kind, text)
}
func (b *boxLayout) stop(text string) {
	if !b.stopped {
		b.notice(webstyle.DiagnosticLimit, text)
	}
	b.stopped = true
	b.out.Truncated = true
}
func (b *boxLayout) coordinate(n int) int {
	if n < -maxLayoutCoordinate || n > maxLayoutCoordinate {
		b.stop("layout-coordinate-limit")
		return max(-maxLayoutCoordinate, min(maxLayoutCoordinate, n))
	}
	return n
}
func (b *boxLayout) emit(it Item) {
	if b.stopped {
		return
	}
	if len(b.out.Items) >= webstyle.MaxPaintItems-1 {
		b.stop("paint-item-limit")
		return
	}
	for _, n := range []int{it.X, it.Y, it.W, it.H, it.X + it.W, it.Y + it.H} {
		b.coordinate(n)
	}
	if !b.stopped {
		b.out.Items = append(b.out.Items, it)
	}
}

func usedLength(l webstyle.Length, reference, initial int) int {
	switch l.Kind {
	case webstyle.LengthPx:
		return int(l.Value)
	case webstyle.LengthPercent:
		return int(int64(reference) * int64(l.Value) / 100)
	}
	return initial
}
func dimension(l webstyle.Length, reference int) int { return usedLength(l, reference, -1) }
func constrain(n int, lo, hi webstyle.Length, reference int) int {
	minimum := max(0, usedLength(lo, reference, 0))
	maximum := usedLength(hi, reference, maxLayoutCoordinate)
	return max(minimum, min(maximum, max(0, n)))
}
func lengths(e webstyle.Edges, reference int) usedEdges {
	return usedEdges{usedLength(e.Top, reference, 0), usedLength(e.Right, reference, 0), usedLength(e.Bottom, reference, 0), usedLength(e.Left, reference, 0)}
}
func borderWidths(e webstyle.Borders) usedEdges {
	width := func(v webstyle.Border) int {
		if v.Style != webstyle.BorderSolid {
			return 0
		}
		return max(0, usedLength(v.Width, 0, 3))
	}
	return usedEdges{width(e.Top), width(e.Right), width(e.Bottom), width(e.Left)}
}

func textStyle(s webstyle.ComputedStyle) Style {
	px := usedLength(s.FontSize, 0, webstyle.InitialFontSize)
	lh := usedLength(s.LineHeight, 0, (px*18+12)/13)
	color := uint32(0)
	if s.Color.Kind == webstyle.ColorRGBA {
		color = s.Color.RGBA & 0xffffff
	}
	return Style{Size: 1, FontPx: px, LineHeightPx: lh, Mono: s.FontFamily == webstyle.FontMono,
		Serif: s.FontFamily == webstyle.FontSerif,
		Bold: s.FontWeight == webstyle.WeightBold, Italic: s.FontStyle == webstyle.StyleItalic, Color: color}
}

// layout positions a subtree relative to its border origin. Parent placement
// translates rectangles/items together, including nested links. forced sizes
// are content sizes assigned by flex/table; -1 means normal used sizing.
func (b *boxLayout) layout(box *Box, containing, forcedW, forcedH int, boundary bool, depth int) flowMargins {
	if b.stopped {
		return flowMargins{}
	}
	if depth > webstyle.MaxDepth {
		b.stop("layout-depth-limit")
		return flowMargins{}
	}
	s := box.Style
	m, p, border := lengths(s.Margin, containing), lengths(s.Padding, containing), borderWidths(s.Border)
	w := dimension(s.Width, containing)
	if w < 0 {
		w = max(0, containing-m.left-m.right-p.left-p.right-border.left-border.right)
	}
	if forcedW >= 0 {
		w = forcedW
	}
	w = constrain(w, s.MinWidth, s.MaxWidth, containing)
	extra := p.left + p.right + border.left + border.right
	if forcedW < 0 {
		free := containing - w - extra - m.left - m.right
		la, ra := s.Margin.Left.Kind == webstyle.LengthAuto, s.Margin.Right.Kind == webstyle.LengthAuto
		if free >= 0 && (la || ra) {
			if la && ra {
				m.left, m.right = free/2, free-free/2
			} else if la {
				m.left += free
			} else {
				m.right += free
			}
		} else {
			m.right += free
		}
	}
	box.start, box.linkStart = len(b.out.Items), len(b.out.Links)
	box.Border = BoxRect{W: b.coordinate(w + extra)}
	box.Content = BoxRect{X: border.left + p.left, Y: border.top + p.top, W: w}
	box.Padding = BoxRect{X: border.left, Y: border.top, W: w + p.left + p.right}
	box.Margin = BoxRect{X: -m.left, Y: -m.top, W: box.Border.W + m.left + m.right}
	bgIndex := -1
	if s.BackgroundColor.Kind == webstyle.ColorRGBA && s.BackgroundColor.RGBA>>24 != 0 || s.BackgroundColor.Kind == webstyle.ColorCurrent {
		color := s.BackgroundColor.RGBA & 0xffffff
		if s.BackgroundColor.Kind == webstyle.ColorCurrent {
			color = textStyle(s).Color
		}
		bgIndex = len(b.out.Items)
		b.emit(Item{Box: box, Kind: ItemRect, W: box.Border.W, Bg: color})
	}
	h := dimension(s.Height, 0)
	if forcedH >= 0 {
		h = forcedH
	}
	if h >= 0 {
		h = constrain(h, s.MinHeight, s.MaxHeight, 0)
	}
	top, bottom := strut(m.top), strut(m.bottom)
	autoHeight := h < 0
	collapseTop := !boundary && s.Display != webstyle.DisplayFlex && p.top+border.top == 0
	collapseBottom := !boundary && s.Display != webstyle.DisplayFlex && autoHeight && p.bottom+border.bottom == 0 && usedLength(s.MinHeight, 0, 0) == 0
	natural := 0
	empty := false
	switch {
	case box.Node != nil && box.Node.Tag == "img":
		natural = b.image(box, w, h)
	case box.Node != nil && FormControl(box.Node.Tag):
		natural = b.control(box, w)
	case box.Node != nil && box.Node.Tag == "hr":
		b.emit(Item{Box: box, Kind: ItemRule, X: box.Content.X, Y: box.Content.Y + 3, W: w, H: 1, Color: textStyle(s).Color})
		natural = 4
	case s.Display == webstyle.DisplayFlex:
		natural = b.flex(box, w, h, depth)
	case s.Display == webstyle.DisplayTable:
		natural = b.table(box, w, depth)
	default:
		allInline := true
		for _, c := range box.Children {
			if !c.inline {
				allInline = false
				break
			}
		}
		if allInline {
			natural = b.inline(box)
			empty = natural == 0
		} else {
			cursor := 0
			pending := marginStrut{}
			first := true
			for _, c := range box.Children {
				cm := b.layout(c, w, -1, -1, false, depth+1)
				adjoining := pending.join(cm.top)
				if cm.through {
					pending = adjoining.join(cm.bottom)
					b.move(c, box.Content.X+usedLength(c.Style.Margin.Left, w, 0), box.Content.Y+cursor+pending.value())
					continue
				}
				if first && collapseTop {
					top = top.join(adjoining)
				} else {
					cursor = b.coordinate(cursor + adjoining.value())
				}
				b.move(c, box.Content.X-c.Margin.X, box.Content.Y+cursor)
				cursor = b.coordinate(cursor + c.Border.H)
				pending, first = cm.bottom, false
			}
			if first && collapseTop && collapseBottom {
				empty = true
				top = top.join(pending)
			} else if first {
				empty = true
				cursor = b.coordinate(cursor + pending.value())
			} else if collapseBottom {
				bottom = bottom.join(pending)
			} else {
				cursor = b.coordinate(cursor + pending.value())
			}
			natural = max(0, cursor)
		}
	}
	if h < 0 {
		h = natural
	}
	h = constrain(h, s.MinHeight, s.MaxHeight, 0)
	box.Content.H = b.coordinate(h)
	box.Padding.H = b.coordinate(h + p.top + p.bottom)
	box.Border.H = b.coordinate(h + p.top + p.bottom + border.top + border.bottom)
	box.Margin.H = b.coordinate(box.Border.H + m.top + m.bottom)
	if bgIndex >= 0 && bgIndex < len(b.out.Items) {
		b.out.Items[bgIndex].H = box.Border.H
	}
	box.end, box.linkEnd = len(b.out.Items), len(b.out.Links)
	b.out.Blocks++
	through := !boundary && s.Display != webstyle.DisplayFlex && empty && h == 0 && p.top+p.bottom+border.top+border.bottom == 0
	if through {
		top = top.join(bottom)
		bottom = top
	}
	if box.Border.W > containing {
		b.horizontal = true
	}
	return flowMargins{top, bottom, through}
}

func (b *boxLayout) move(box *Box, x, y int) {
	var walk func(*Box)
	walk = func(c *Box) {
		for _, r := range []*BoxRect{&c.Content, &c.Padding, &c.Border, &c.Margin} {
			r.X = b.coordinate(r.X + x)
			r.Y = b.coordinate(r.Y + y)
		}
		for _, child := range c.Children {
			walk(child)
		}
	}
	walk(box)
	for i := box.start; i < box.end && i < len(b.out.Items); i++ {
		it := &b.out.Items[i]
		it.X, it.Y = b.coordinate(it.X+x), b.coordinate(it.Y+y)
		b.coordinate(it.X + it.W)
		b.coordinate(it.Y + it.H)
	}
	for i := box.linkStart; i < box.linkEnd && i < len(b.out.Links); i++ {
		k := &b.out.Links[i]
		k.X, k.Y = b.coordinate(k.X+x), b.coordinate(k.Y+y)
	}
}

type inlineToken struct {
	text, target         string
	box                  *Box
	st                   Style
	w                    int
	h                    int
	space, newline, wrap bool
	replaced             bool
	edge                 bool
}

func (b *boxLayout) inline(parent *Box) int {
	var tokens []inlineToken
	var clear func(*Box)
	clear = func(box *Box) {
		box.Content, box.Padding, box.Border, box.Margin = BoxRect{}, BoxRect{}, BoxRect{}, BoxRect{}
		for _, c := range box.Children {
			clear(c)
		}
	}
	for _, c := range parent.Children {
		clear(c)
	}
	if parent.Style.Display == webstyle.DisplayListItem {
		marker := "*"
		if parent.parent != nil && parent.parent.Node != nil && parent.parent.Node.Tag == "ol" {
			index := 1
			for _, c := range parent.parent.Children {
				if c == parent {
					break
				}
				if c.Style.Display == webstyle.DisplayListItem {
					index++
				}
			}
			marker = decimalMarker(index) + "."
		}
		st := textStyle(parent.Style)
		tokens = append(tokens, inlineToken{text: marker, st: st, w: b.out.Text.Measure(marker+" ", st)})
	}
	var collect func(*Box, string)
	collect = func(box *Box, target string) {
		n := box.Node
		if n != nil && n.Tag == "a" && n.Attr("href") != "" {
			target = n.Attr("href")
		}
		if n != nil && n.Tag == "br" {
			tokens = append(tokens, inlineToken{newline: true, st: textStyle(box.Style)})
			return
		}
		if n != nil && (n.Tag == "img" || FormControl(n.Tag)) {
			if n.Tag == "input" && strings.EqualFold(n.Attr("type"), "hidden") {
				return
			}
			w := 160
			if n.Tag == "img" && attrPx(n, "width") > 0 {
				w = attrPx(n, "width")
			}
			if dw := dimension(box.Style.Width, parent.Content.W); dw >= 0 {
				w = dw
			}
			w = min(parent.Content.W, w)
			_, h := b.measureHeight(box, parent.Content.W, w, 0)
			tokens = append(tokens, inlineToken{target: target, box: box, st: textStyle(box.Style), w: w, h: h, wrap: true, replaced: true})
			return
		}
		if n != nil && n.Kind == KindText {
			raw := n.Text
			st := textStyle(box.Style)
			mode := box.Style.WhiteSpace
			if mode == webstyle.WhiteSpaceNormal {
				raw = collapseWS(raw)
			} else {
				raw = strings.ReplaceAll(raw, "\r\n", "\n")
			}
			for i := 0; i < len(raw); {
				if raw[i] == '\n' {
					tokens = append(tokens, inlineToken{newline: true, st: st, box: box})
					i++
					continue
				}
				j := i
				space := raw[i] == ' ' || raw[i] == '\t'
				for j < len(raw) && raw[j] != '\n' && ((raw[j] == ' ' || raw[j] == '\t') == space) {
					j++
				}
				tx := strings.ReplaceAll(raw[i:j], "\t", "    ")
				tokens = append(tokens, inlineToken{text: tx, target: target, box: box, st: st, w: b.out.Text.Measure(tx, st), space: space, wrap: mode != webstyle.WhiteSpacePre})
				i = j
			}
			return
		}
		p, border, margin := lengths(box.Style.Padding, parent.Content.W), borderWidths(box.Style.Border), lengths(box.Style.Margin, parent.Content.W)
		left, right := p.left+border.left+margin.left, p.right+border.right+margin.right
		if left != 0 {
			tokens = append(tokens, inlineToken{box: box, st: textStyle(box.Style), w: left, edge: true})
		}
		for _, c := range box.Children {
			collect(c, target)
		}
		if right != 0 {
			tokens = append(tokens, inlineToken{box: box, st: textStyle(box.Style), w: right, edge: true})
		}
	}
	for _, c := range parent.Children {
		collect(c, "")
	}
	x, y, lh := 0, 0, 0
	lineStart := len(b.out.Items)
	linkStart := len(b.out.Links)
	lineWidth := 0
	started := false
	pendingSpace := 0
	type runGeometry struct {
		box  *Box
		rect BoxRect
	}
	var geometry []runGeometry
	finish := func(force bool) {
		if !started && !force {
			return
		}
		if lh == 0 {
			lh = textStyle(parent.Style).LineHeightPx
		}
		shift := 0
		free := max(0, parent.Content.W-lineWidth)
		if parent.Style.TextAlign == webstyle.AlignCenter {
			shift = free / 2
		}
		if parent.Style.TextAlign == webstyle.AlignRight {
			shift = free
		}
		for i := lineStart; i < len(b.out.Items); i++ {
			b.out.Items[i].X += shift
		}
		for i := linkStart; i < len(b.out.Links); i++ {
			b.out.Links[i].X += shift
		}
		for _, g := range geometry {
			r := g.rect
			r.X += shift
			for box := g.box; box != nil && box != parent; box = box.parent {
				if box.inline && !(box.Node != nil && (box.Node.Tag == "img" || FormControl(box.Node.Tag))) {
					box.Content = unionRect(box.Content, r)
					p, border, m := lengths(box.Style.Padding, parent.Content.W), borderWidths(box.Style.Border), lengths(box.Style.Margin, parent.Content.W)
					box.Padding = expandRect(box.Content, p)
					box.Border = expandRect(box.Padding, border)
					box.Margin = expandRect(box.Border, usedEdges{left: m.left, right: m.right})
				}
			}
		}
		geometry = geometry[:0]
		y = b.coordinate(y + lh)
		b.out.Lines++
		x, lh, lineWidth, pendingSpace, started = 0, 0, 0, 0, false
		lineStart, linkStart = len(b.out.Items), len(b.out.Links)
	}
	for _, token := range tokens {
		if b.stopped {
			break
		}
		if token.newline {
			lh = max(lh, token.st.LineHeightPx)
			finish(true)
			continue
		}
		if token.edge {
			x += token.w
			lineWidth = x
			continue
		}
		if token.space && token.box.Style.WhiteSpace == webstyle.WhiteSpaceNormal {
			if started {
				pendingSpace = b.out.Text.Measure(" ", token.st)
			}
			continue
		}
		if token.wrap && started && x+pendingSpace+token.w > parent.Content.W {
			finish(false)
		}
		x += pendingSpace
		pendingSpace = 0
		lh = max(lh, token.st.LineHeightPx)
		if token.replaced {
			b.layout(token.box, parent.Content.W, token.w, -1, true, 0)
			b.move(token.box, parent.Content.X+x, parent.Content.Y+y)
			lh = max(lh, token.h)
			if token.target != "" && !b.stopped {
				r := token.box.Border
				b.out.Links = append(b.out.Links, Link{X: r.X, Y: r.Y, W: r.W, H: r.H, Target: token.target})
			}
			geometry = append(geometry, runGeometry{token.box, token.box.Border})
			x += token.w
			lineWidth, started = x, true
			continue
		}
		source := token.box
		if source == nil {
			source = parent
		}
		it := Item{Box: source, Kind: ItemText, X: parent.Content.X + x, Y: parent.Content.Y + y, W: token.w, H: token.st.LineHeightPx,
			Text: token.text, Size: 1, FontPx: token.st.FontPx, LineHeightPx: token.st.LineHeightPx, Mono: token.st.Mono,
			Serif: token.st.Serif, Bold: token.st.Bold, Italic: token.st.Italic, Color: token.st.Color, Target: token.target}
		b.emit(it)
		if token.target != "" && !b.stopped {
			b.out.Links = append(b.out.Links, Link{X: it.X, Y: it.Y, W: it.W, H: it.H, Target: token.target})
			b.emit(Item{Box: source, Kind: ItemRule, X: it.X, Y: it.Y + it.H - 1, W: it.W, H: 1, Color: it.Color})
		}
		geometry = append(geometry, runGeometry{token.box, BoxRect{X: it.X, Y: it.Y, W: it.W, H: it.H}})
		x += token.w
		lineWidth = x
		started = true
	}
	finish(false)
	return y
}

func decimalMarker(n int) string {
	var buf [10]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

func unionRect(a, b BoxRect) BoxRect {
	if a.W == 0 && a.H == 0 {
		return b
	}
	x, y := min(a.X, b.X), min(a.Y, b.Y)
	return BoxRect{X: x, Y: y, W: max(a.X+a.W, b.X+b.W) - x, H: max(a.Y+a.H, b.Y+b.H) - y}
}

func expandRect(r BoxRect, e usedEdges) BoxRect {
	return BoxRect{X: r.X - e.left, Y: r.Y - e.top, W: r.W + e.left + e.right, H: r.H + e.top + e.bottom}
}

func (b *boxLayout) intrinsicWidth(box *Box) int {
	if box.intrinsicSet {
		return box.intrinsic
	}
	width := 0
	if box.Node != nil && box.Node.Kind == KindText {
		width = b.out.Text.Measure(collapseWS(box.Node.Text), textStyle(box.Style))
	} else if box.Node != nil && box.Node.Tag == "img" {
		width = attrPx(box.Node, "width")
		if width == 0 {
			width = 160
		}
	} else if box.Node != nil && FormControl(box.Node.Tag) {
		width = 160
	} else {
		inline := true
		for _, c := range box.Children {
			if !c.inline {
				inline = false
			}
		}
		for _, c := range box.Children {
			cw := dimension(c.Style.Width, 0)
			if cw < 0 {
				cw = b.intrinsicWidth(c)
			}
			p, border, m := lengths(c.Style.Padding, 0), borderWidths(c.Style.Border), lengths(c.Style.Margin, 0)
			cw += p.left + p.right + border.left + border.right + m.left + m.right
			if inline || box.Style.Display == webstyle.DisplayFlex && box.Style.FlexDirection == webstyle.FlexRow {
				width += cw
			} else {
				width = max(width, cw)
			}
		}
	}
	box.intrinsic, box.intrinsicSet = max(0, b.coordinate(width)), true
	return box.intrinsic
}

type flexItem struct {
	box                                                                                *Box
	base, size, minimum, maximum, extra, before, after, crossBefore, crossAfter, cross int
	grow, shrink                                                                       int
	autoBefore, autoAfter, crossAutoBefore, crossAutoAfter, crossStretch               bool
}

// resolveFlex uses exact integer ratios and iterative min/max freezes.
// Rounding happens once per iteration; residual pixels go in DOM order.
func resolveFlex(items []flexItem, available int) {
	sum := 0
	for i := range items {
		sum += max(items[i].minimum, min(items[i].maximum, items[i].base)) + items[i].extra
	}
	growing := sum < available
	frozen := make([]bool, len(items))
	for i := range items {
		it := &items[i]
		hyp := max(it.minimum, min(it.maximum, it.base))
		factor := it.shrink
		if growing {
			factor = it.grow
		}
		if factor == 0 || growing && it.base > hyp || !growing && it.base < hyp {
			it.size, frozen[i] = hyp, true
		} else {
			it.size = it.base
		}
	}
	for iteration := 0; iteration <= len(items); iteration++ {
		free, total := available, int64(0)
		for i := range items {
			it := &items[i]
			if frozen[i] {
				free -= it.size + it.extra
				continue
			}
			free -= it.base + it.extra
			weight := int64(it.shrink) * int64(it.base)
			if growing {
				weight = int64(it.grow)
			}
			total += weight
		}
		if total == 0 {
			break
		}
		// Factors are integral in this subset, so the spec's <1 sum branch
		// cannot apply except the already handled all-zero case.
		rawSum := 0
		for i := range items {
			it := &items[i]
			if frozen[i] {
				rawSum += it.size + it.extra
				continue
			}
			weight := int64(it.shrink) * int64(it.base)
			if growing {
				weight = int64(it.grow)
			}
			numerator := int64(it.base)*total + int64(free)*weight
			it.size = int(numerator / total)
			if numerator < 0 && numerator%total != 0 {
				it.size--
			}
			rawSum += it.size + it.extra
		}
		residual := available - rawSum
		for i := range items {
			if residual <= 0 {
				break
			}
			it := &items[i]
			factor := it.shrink * it.base
			if growing {
				factor = it.grow
			}
			if !frozen[i] && factor > 0 {
				it.size++
				residual--
			}
		}
		violation := 0
		for i := range items {
			if frozen[i] {
				continue
			}
			it := &items[i]
			violation += max(it.minimum, min(it.maximum, max(0, it.size))) - it.size
		}
		changed := false
		for i := range items {
			if frozen[i] {
				continue
			}
			it := &items[i]
			clamped := max(it.minimum, min(it.maximum, max(0, it.size)))
			delta := clamped - it.size
			if violation == 0 || violation > 0 && delta > 0 || violation < 0 && delta < 0 {
				frozen[i], changed = true, true
			}
			it.size = clamped
		}
		if violation == 0 || !changed {
			break
		}
	}
}

func (b *boxLayout) flex(parent *Box, w, h, depth int) int {
	s := parent.Style
	column := s.FlexDirection == webstyle.FlexColumn
	main := w
	mainGap, crossGap := usedLength(s.ColumnGap, w, 0), usedLength(s.RowGap, w, 0)
	if column {
		main, mainGap, crossGap = h, crossGap, mainGap
	}
	var items []flexItem
	for _, c := range parent.Children {
		cs := c.Style
		p, border, m := lengths(cs.Padding, w), borderWidths(cs.Border), lengths(cs.Margin, w)
		it := flexItem{box: c, shrink: 1, minimum: usedLength(cs.MinWidth, w, 0), maximum: usedLength(cs.MaxWidth, w, maxLayoutCoordinate),
			before: m.left, after: m.right, crossBefore: m.top, crossAfter: m.bottom, extra: p.left + p.right + border.left + border.right + m.left + m.right,
			autoBefore: cs.Margin.Left.Kind == webstyle.LengthAuto, autoAfter: cs.Margin.Right.Kind == webstyle.LengthAuto,
			crossAutoBefore: cs.Margin.Top.Kind == webstyle.LengthAuto, crossAutoAfter: cs.Margin.Bottom.Kind == webstyle.LengthAuto,
			crossStretch: dimension(cs.Height, 0) < 0}
		if cs.FlexGrow.Set {
			it.grow = int(cs.FlexGrow.Value)
		}
		if cs.FlexShrink.Set {
			it.shrink = int(cs.FlexShrink.Value)
		}
		it.base = dimension(cs.FlexBasis, max(0, main))
		if cs.FlexBasis.Kind == webstyle.LengthPercent && main < 0 {
			it.base = -1
		}
		if it.base < 0 {
			it.base = dimension(cs.Width, w)
		}
		if column {
			it.minimum, it.maximum = usedLength(cs.MinHeight, 0, 0), usedLength(cs.MaxHeight, 0, maxLayoutCoordinate)
			it.before, it.after, it.crossBefore, it.crossAfter = m.top, m.bottom, m.left, m.right
			it.extra = p.top + p.bottom + border.top + border.bottom + m.top + m.bottom
			it.autoBefore, it.autoAfter, it.crossAutoBefore, it.crossAutoAfter = it.crossAutoBefore, it.crossAutoAfter, it.autoBefore, it.autoAfter
			it.crossStretch = dimension(cs.Width, w) < 0
			it.base = dimension(cs.FlexBasis, max(0, main))
			if cs.FlexBasis.Kind == webstyle.LengthPercent && main < 0 {
				it.base = -1
			}
			if it.base < 0 {
				it.base = dimension(cs.Height, 0)
			}
			if it.base < 0 {
				it.base, _ = b.measureHeight(c, w, -1, depth+1)
			}
		} else if it.base < 0 {
			it.base = b.intrinsicWidth(c)
		}
		it.minimum = max(0, it.minimum)
		it.maximum = max(it.minimum, it.maximum)
		items = append(items, it)
	}
	if main < 0 {
		main = max(0, len(items)-1) * mainGap
		for _, it := range items {
			main += max(it.minimum, min(it.maximum, it.base)) + it.extra
		}
		if column {
			main = constrain(main, s.MinHeight, s.MaxHeight, 0)
		}
	}
	crossCursor := 0
	for first := 0; first < len(items); {
		last, total := first, 0
		for last < len(items) {
			hyp := max(items[last].minimum, min(items[last].maximum, items[last].base)) + items[last].extra
			gap := 0
			if last > first {
				gap = mainGap
			}
			if last > first && s.FlexWrap == webstyle.FlexWrapLines && total+gap+hyp > main {
				break
			}
			total += gap + hyp
			last++
		}
		line := items[first:last]
		resolveFlex(line, main-mainGap*max(0, len(line)-1))
		crossSize := 0
		for i := range line {
			it := &line[i]
			if column {
				p, border, m := lengths(it.box.Style.Padding, w), borderWidths(it.box.Style.Border), lengths(it.box.Style.Margin, w)
				cw := dimension(it.box.Style.Width, w)
				if cw < 0 {
					cw = max(0, w-p.left-p.right-border.left-border.right-m.left-m.right)
				}
				it.cross = constrain(cw, it.box.Style.MinWidth, it.box.Style.MaxWidth, w) + p.left + p.right + border.left + border.right
			} else {
				ch := dimension(it.box.Style.Height, 0)
				p, border := lengths(it.box.Style.Padding, w), borderWidths(it.box.Style.Border)
				if ch >= 0 {
					it.cross = constrain(ch, it.box.Style.MinHeight, it.box.Style.MaxHeight, 0) + p.top + p.bottom + border.top + border.bottom
				} else {
					_, it.cross = b.measureHeight(it.box, w, it.size, depth+1)
				}
			}
			crossSize = max(crossSize, it.cross+it.crossBefore+it.crossAfter)
		}
		definiteCross := h
		if column {
			definiteCross = w
		}
		if s.FlexWrap == webstyle.FlexNoWrap && definiteCross >= 0 {
			crossSize = definiteCross
		} else if !column && s.FlexWrap == webstyle.FlexNoWrap {
			crossSize = constrain(crossSize, s.MinHeight, s.MaxHeight, 0)
		}
		used, autos := mainGap*max(0, len(line)-1), 0
		for _, it := range line {
			used += it.size + it.extra
			if it.autoBefore {
				autos++
			}
			if it.autoAfter {
				autos++
			}
		}
		free := max(0, main-used)
		share, remainder := 0, 0
		if autos > 0 {
			share, remainder = free/autos, free%autos
			free = 0
		}
		pen := 0
		for i := range line {
			it := &line[i]
			before, after := it.before, it.after
			if it.autoBefore {
				before = share
				if remainder > 0 {
					before++
					remainder--
				}
			}
			if it.autoAfter {
				after = share
				if remainder > 0 {
					after++
					remainder--
				}
			}
			offset := justifyOffset(s.JustifyContent, free, i, len(line))
			crossFree := max(0, crossSize-it.cross-it.crossBefore-it.crossAfter)
			cross := it.crossBefore
			cw, ch := it.size, -1
			if column {
				cw, ch = -1, it.size
			}
			if it.crossAutoBefore || it.crossAutoAfter {
				if it.crossAutoBefore && it.crossAutoAfter {
					cross += crossFree / 2
				} else if it.crossAutoBefore {
					cross += crossFree
				}
			} else {
				switch s.AlignItems {
				case webstyle.ItemsEnd:
					cross += crossFree
				case webstyle.ItemsCenter:
					cross += crossFree / 2
				case webstyle.ItemsStretch:
					if it.crossStretch {
						box := it.box
						p, border := lengths(box.Style.Padding, w), borderWidths(box.Style.Border)
						if column {
							cw = max(0, crossSize-it.crossBefore-it.crossAfter-p.left-p.right-border.left-border.right)
						} else {
							ch = max(0, crossSize-it.crossBefore-it.crossAfter-p.top-p.bottom-border.top-border.bottom)
						}
					}
				}
			}
			x, y := pen+before+offset, crossCursor+cross
			if column {
				x, y = y, x
			}
			b.layout(it.box, w, cw, ch, true, depth+1)
			b.move(it.box, parent.Content.X+x, parent.Content.Y+y)
			pen += it.size + it.extra - it.before - it.after + before + after + mainGap
		}
		crossCursor += crossSize
		if last < len(items) {
			crossCursor += crossGap
		}
		first = last
	}
	if column {
		return main
	}
	return crossCursor
}

// Memoize natural height for each box's current measuring width. Nested
// auto-basis flex containers reuse it during the final pass instead of
// expanding into an exponential series of trial layouts.
func (b *boxLayout) measureHeight(box *Box, containing, forcedW, depth int) (int, int) {
	if box.measured && box.measureContaining == containing && box.measureW == forcedW {
		return box.measureContentH, box.measureBorderH
	}
	start, links := len(b.out.Items), len(b.out.Links)
	blocks, lines := b.out.Blocks, b.out.Lines
	b.layout(box, containing, forcedW, -1, true, depth)
	content, border := box.Content.H, box.Border.H
	b.out.Items, b.out.Links = b.out.Items[:start], b.out.Links[:links]
	b.out.Blocks, b.out.Lines = blocks, lines
	box.measured, box.measureContaining, box.measureW = true, containing, forcedW
	box.measureContentH, box.measureBorderH = content, border
	return content, border
}

func justifyOffset(j webstyle.JustifyContent, free, index, count int) int {
	switch j {
	case webstyle.JustifyEnd:
		return free
	case webstyle.JustifyCenter:
		return free / 2
	case webstyle.JustifySpaceBetween:
		if count > 1 {
			return free * index / (count - 1)
		}
	case webstyle.JustifySpaceAround:
		return free * (2*index + 1) / (2 * max(1, count))
	case webstyle.JustifySpaceEvenly:
		return free * (index + 1) / (count + 1)
	}
	return 0
}

func (b *boxLayout) image(box *Box, w, h int) int {
	n := box.Node
	label := n.Attr("alt")
	if label == "" {
		label = "[image unavailable]"
	}
	if len(label) > 256 {
		label = label[:256]
		for !utf8.ValidString(label) {
			label = label[:len(label)-1]
		}
	}
	var image *Image
	if b.images != nil && n.Attr("src") != "" {
		if data, ok := b.images(n.Attr("src")); ok {
			if decoded, err := DecodeImage(data); err == nil {
				image = decoded
			}
		}
	}
	iw, ih := 160, 48
	if image != nil {
		iw, ih = image.Width, image.Height
	}
	if aw := attrPx(n, "width"); aw > 0 {
		if image != nil && attrPx(n, "height") == 0 && iw > 0 {
			ih = ih * aw / iw
		}
		iw = aw
	}
	if ah := attrPx(n, "height"); ah > 0 {
		if image != nil && attrPx(n, "width") == 0 && ih > 0 {
			iw = iw * ah / ih
		}
		ih = ah
	}
	if dimension(box.Style.Width, 0) >= 0 {
		if image != nil && h < 0 && iw > 0 {
			ih = ih * w / iw
		}
		iw = w
	}
	if h >= 0 {
		ih = h
	}
	if iw > w && iw > 0 {
		if image != nil && h < 0 {
			ih = ih * w / iw
		}
		iw = w
	}
	b.emit(Item{Box: box, Kind: ItemImage, X: box.Content.X, Y: box.Content.Y, W: max(1, iw), H: max(1, ih), Text: label, Img: image, Color: ColorMuted})
	return max(1, ih)
}

func (b *boxLayout) control(box *Box, w int) int {
	n := box.Node
	if n.Tag == "input" && strings.EqualFold(n.Attr("type"), "hidden") {
		return 0
	}
	st := textStyle(box.Style)
	h := st.LineHeightPx + 6
	if n.Tag == "textarea" {
		h = st.LineHeightPx*3 + 6
	}
	cw := min(w, 160)
	label := controlLabel(n, strings.ToLower(n.Attr("type")))
	if n.Tag == "button" {
		cw = min(w, max(32, b.out.Text.Measure(label, st)+16))
	}
	x, y := box.Content.X, box.Content.Y
	b.emit(Item{Box: box, Kind: ItemRect, X: x, Y: y, W: cw, H: h, Bg: ColorSurface})
	b.emit(Item{Box: box, Kind: ItemText, X: x + 4, Y: y + 3, W: b.out.Text.Measure(label, st), H: st.LineHeightPx, Text: label, Size: 1,
		FontPx: st.FontPx, LineHeightPx: st.LineHeightPx, Color: st.Color})
	return h
}

func (b *boxLayout) table(parent *Box, w, depth int) int {
	var rows, captions []*Box
	var collect func(*Box)
	collect = func(n *Box) {
		switch n.Style.Display {
		case webstyle.DisplayTableRow:
			rows = append(rows, n)
		case webstyle.DisplayTableCaption:
			captions = append(captions, n)
		default:
			for _, c := range n.Children {
				collect(c)
			}
		}
	}
	for _, c := range parent.Children {
		collect(c)
	}
	y := 0
	for _, c := range captions {
		b.layout(c, w, w, -1, true, depth+1)
		b.move(c, parent.Content.X, parent.Content.Y+y)
		y += c.Border.H
	}
	if len(rows) == 0 {
		return y + b.inline(parent)
	}
	var cells func(*Box) []*Box
	cells = func(r *Box) []*Box {
		var out []*Box
		for _, c := range r.Children {
			if c.Style.Display == webstyle.DisplayTableCell {
				out = append(out, c)
			} else if c.Anonymous {
				out = append(out, cells(c)...)
			}
		}
		return out
	}
	cols := len(cells(rows[0]))
	if cols == 0 {
		return y + b.inline(parent)
	}
	for _, row := range rows {
		rh := 0
		x := 0
		cs := cells(row)
		lastBottom := 0
		for i, c := range cs {
			cw := w / cols
			if i < w%cols {
				cw++
			}
			p, border := lengths(c.Style.Padding, w), borderWidths(c.Style.Border)
			b.layout(c, w, max(0, cw-p.left-p.right-border.left-border.right), -1, true, depth+1)
			cx, cy := x, y
			if i >= cols {
				// Malformed extra cells preserve their text in the final
				// column, below its preceding content; no spans or new column.
				cx, cy = w-w/cols, y+lastBottom
			}
			b.move(c, parent.Content.X+cx, parent.Content.Y+cy)
			rh = max(rh, cy-y+c.Border.H)
			lastBottom = cy - y + c.Border.H
			if i < cols {
				x += cw
			}
		}
		row.Content = BoxRect{X: parent.Content.X, Y: parent.Content.Y + y, W: w, H: rh}
		row.Padding, row.Border, row.Margin = row.Content, row.Content, row.Content
		for i, c := range cs {
			if i >= cols {
				continue
			}
			delta := rh - c.Border.H
			c.Content.H, c.Padding.H, c.Border.H, c.Margin.H = c.Content.H+delta, c.Padding.H+delta, rh, c.Margin.H+delta
		}
		y += rh
	}
	var groups func(*Box)
	groups = func(box *Box) {
		for _, c := range box.Children {
			groups(c)
		}
		switch box.Style.Display {
		case webstyle.DisplayTableRowGroup, webstyle.DisplayTableHeaderGroup, webstyle.DisplayTableFooterGroup:
			var r BoxRect
			for _, c := range box.Children {
				r = unionRect(r, c.Border)
			}
			box.Content, box.Padding, box.Border, box.Margin = r, r, r, r
		}
	}
	for _, c := range parent.Children {
		groups(c)
	}
	return y
}
