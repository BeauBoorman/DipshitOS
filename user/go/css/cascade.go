package css

import (
	"virelai/webrender"
	"virelai/webstyle"
)

// Styles owns computed copies, not references into sheets or mutable DOM data.
type Styles struct {
	values map[*webrender.Node]webstyle.ComputedStyle
}

// ForNode returns the computed style for element and text nodes. Missing/nil
// nodes and a nil Styles receiver safely return the frozen initial style.
func (s *Styles) ForNode(n *webrender.Node) webstyle.ComputedStyle {
	if s != nil {
		if v, ok := s.values[n]; ok {
			return v
		}
	}
	return initialStyle()
}

func initialStyle() webstyle.ComputedStyle {
	return webstyle.ComputedStyle{
		FontSize:        webstyle.Length{Kind: webstyle.LengthPx, Value: webstyle.InitialFontSize},
		LineHeight:      webstyle.Length{Kind: webstyle.LengthPx, Value: 18},
		Color:           webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000},
		BackgroundColor: webstyle.Color{Kind: webstyle.ColorRGBA},
		Border: webstyle.Borders{
			Top:    webstyle.Border{Color: webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000}},
			Right:  webstyle.Border{Color: webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000}},
			Bottom: webstyle.Border{Color: webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000}},
			Left:   webstyle.Border{Color: webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000}},
		},
	}
}

func inherited(id propertyID) bool {
	return id >= pFontFamily && id <= pColor || id == pTextAlign || id == pWhiteSpace
}

type winner struct {
	decl  declaration
	spec  specificity
	tier  int
	order int
	set   bool
}

func take(w *winner, d declaration, spec specificity, tier, order int) {
	if !w.set || tier > w.tier || tier == w.tier && (w.spec.less(spec) || w.spec == spec && order >= w.order) {
		*w = winner{decl: d, spec: spec, tier: tier, order: order, set: true}
	}
}

func applyRules(w *[propertyCount]winner, rules []rule, path []*webrender.Node, ua bool, work *int) bool {
	order := 0
	for _, rule := range rules {
		matched := false
		var spec specificity
		for _, sel := range rule.selectors {
			ok, exhausted := sel.matches(path, work)
			if exhausted {
				return true
			}
			if ok && (!matched || spec.less(sel.spec)) {
				matched, spec = true, sel.spec
			}
		}
		for _, decl := range rule.decls {
			order++
			if !matched {
				continue
			}
			tier := 1 // author normal
			if ua {
				tier = 0
			}
			if decl.important {
				tier = 2 // author important
				if ua {
					tier = 3
				}
			}
			take(&w[decl.id], decl, spec, tier, order)
		}
	}
	return false
}

// Cascade inserts the immutable UA sheet, processes ordered author sources,
// and parses inline declaration lists. Parse diagnostics are aggregated here
// under the page-wide cap; callers should not append them a second time.
func Cascade(doc *webrender.Document, sheets []*Stylesheet) (*Styles, []webstyle.Diagnostic) {
	return cascade(doc, sheets, uaSheet)
}

func cascade(doc *webrender.Document, sheets []*Stylesheet, ua *Stylesheet) (*Styles, []webstyle.Diagnostic) {
	s := &Styles{values: make(map[*webrender.Node]webstyle.ComputedStyle)}
	var diags diagnostics
	if doc == nil || doc.Root == nil {
		diags.add(webstyle.DiagnosticInvalid, 0, 0, "invalid-input document")
		return s, diags.list
	}
	bytes, ruleCount := 0, 0
	var author []rule
	for i, sheet := range sheets {
		if i >= webstyle.MaxStylesheets {
			diags.add(webstyle.DiagnosticLimit, 0, 0, "css-sheet-limit")
			break
		}
		if sheet == nil {
			diags.add(webstyle.DiagnosticInvalid, 0, 0, "invalid-input stylesheet")
			continue
		}
		if sheet.bytes > webstyle.MaxCSSBytes-bytes {
			diags.add(webstyle.DiagnosticLimit, 0, 0, "css-byte-limit")
			break
		}
		bytes += sheet.bytes
		diags.merge(sheet.diags)
		for _, rule := range sheet.rules {
			if rule.sourceRule > webstyle.MaxCSSRules-ruleCount {
				break
			}
			author = append(author, rule)
		}
		if sheet.ruleCount > webstyle.MaxCSSRules-ruleCount {
			diags.add(webstyle.DiagnosticLimit, 0, 0, "css-rule-limit")
			ruleCount = webstyle.MaxCSSRules
		} else {
			ruleCount += sheet.ruleCount
		}
	}
	work := 0
	authorStopped, inlineStopped, nodeStopped := false, false, false
	visited := make(map[*webrender.Node]bool)
	var path []*webrender.Node
	// The root element's computed font-size, once it resolves — the rem base.
	// Initial until then, which is the correct base for a rem on the root
	// itself (its "parent" is the initial style).
	rootFontPx := int32(webstyle.InitialFontSize)
	var walk func(*webrender.Node, webstyle.ComputedStyle, bool)
	walk = func(n *webrender.Node, parent webstyle.ComputedStyle, parentNormal bool) {
		if nodeStopped {
			return
		}
		if n == nil || visited[n] {
			diags.add(webstyle.DiagnosticInvalid, 0, 0, "invalid-input DOM node")
			return
		}
		if len(s.values) >= webstyle.MaxNodes {
			diags.add(webstyle.DiagnosticLimit, 0, 0, "css-node-limit")
			nodeStopped = true
			return
		}
		if len(path) > webstyle.MaxDepth {
			diags.add(webstyle.DiagnosticLimit, 0, 0, "css-depth-limit")
			return
		}
		visited[n] = true
		path = append(path, n)
		var winners [propertyCount]winner
		if n.Kind == webrender.KindElement {
			applyRules(&winners, ua.rules, path, true, nil)
			if !authorStopped && applyRules(&winners, author, path, false, &work) {
				authorStopped = true
				diags.add(webstyle.DiagnosticLimit, 0, 0, "css-work-limit")
			}
			if attr := n.Attr("style"); attr != "" && !inlineStopped && !authorStopped {
				if len(attr) > webstyle.MaxCSSBytes-bytes {
					diags.add(webstyle.DiagnosticLimit, 0, 0, "css-byte-limit inline style")
					inlineStopped = true
				} else {
					bytes += len(attr)
					p := newParser(attr)
					decls := p.declarations(false)
					diags.merge(p.diags.list)
					for i, decl := range decls {
						tier := 1
						if decl.important {
							tier = 2
						}
						take(&winners[decl.id], decl, specificity{inline: 1}, tier, i)
					}
				}
			}
		}
		style := initialStyle()
		for _, b := range []*webstyle.Border{&style.Border.Top, &style.Border.Right, &style.Border.Bottom, &style.Border.Left} {
			b.Color = webstyle.Color{Kind: webstyle.ColorCurrent}
		}
		normal := parentNormal
		for id := propertyID(0); id < propertyCount; id++ {
			w := winners[id]
			if !w.set {
				if inherited(id) {
					assign(&style, id, valueOf(&parent, id))
				}
				continue
			}
			v := w.decl.value
			if id == pLineHeight {
				normal = v.mode == valueInitial || v.mode == valueNormal && v.length.Kind == webstyle.LengthInitial ||
					v.mode == valueInherit && parentNormal
			}
			if v.mode == valueInherit {
				v = valueOf(&parent, id)
			} else if v.mode == valueInitial {
				// Zero style carries length/factor initials. Fonts and foreground
				// are explicitly resolved below; line-height normal is tracked.
				initial := initialStyle()
				v = valueOf(&initial, id)
				if id >= pBorderTopWidth && id <= pBorderLeftColor && (id-pBorderTopWidth)%3 == 2 {
					v.color = webstyle.Color{Kind: webstyle.ColorCurrent}
				}
			}
			assign(&style, id, v)
		}
		// Font-relative sizes resolve to px here (M99p #2193): em against
		// the parent's computed size, rem against the root's, smaller/larger
		// one step off the absolute-size ladder. Parent styles are already
		// resolved before children recurse, so parent's FontSize is always
		// px. A computed result outside 8-48 clamps and reports — the value
		// is only known at this point, unlike a literal px which refuses at
		// parse.
		if style.FontSize.Kind != webstyle.LengthPx &&
			style.FontSize.Kind != webstyle.LengthInitial && style.FontSize.Kind != webstyle.LengthAuto {
			parentPx := parent.FontSize.Value
			if parentPx <= 0 {
				// The root's "parent" is the zero style; CSS resolves a root
				// em/smaller against the initial medium.
				parentPx = webstyle.InitialFontSize
			}
			var px int64
			switch style.FontSize.Kind {
			case webstyle.LengthEm:
				px = (int64(parentPx)*int64(style.FontSize.Value) + 50) / 100
			case webstyle.LengthRem:
				px = (int64(rootFontPx)*int64(style.FontSize.Value) + 50) / 100
			case webstyle.LengthFontSmaller:
				px = int64(fontSizeStep(parentPx, -1))
			case webstyle.LengthFontLarger:
				px = int64(fontSizeStep(parentPx, 1))
			}
			if px < 8 || px > 48 {
				px = min(48, max(8, px))
				diags.add(webstyle.DiagnosticUnsupported, 0, 0, "font-size-clamped")
			}
			style.FontSize = webstyle.Length{Kind: webstyle.LengthPx, Value: int32(px)}
		}
		if len(path) == 1 {
			rootFontPx = style.FontSize.Value
		}
		if style.Color.Kind == webstyle.ColorCurrent {
			style.Color = parent.Color
		}
		if style.Color.Kind == webstyle.ColorInitial {
			style.Color = webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000}
		}
		if normal {
			style.LineHeight = webstyle.Length{Kind: webstyle.LengthPx, Value: (style.FontSize.Value*18 + 12) / 13}
		}
		if style.BackgroundColor.Kind == webstyle.ColorCurrent {
			style.BackgroundColor = style.Color
		}
		if style.BackgroundColor.Kind == webstyle.ColorInitial {
			style.BackgroundColor = webstyle.Color{Kind: webstyle.ColorRGBA}
		}
		for _, b := range []*webstyle.Border{&style.Border.Top, &style.Border.Right, &style.Border.Bottom, &style.Border.Left} {
			if b.Color.Kind == webstyle.ColorCurrent || b.Color.Kind == webstyle.ColorInitial {
				b.Color = style.Color
			}
		}
		s.values[n] = style
		for _, child := range n.Children {
			walk(child, style, normal)
		}
		path = path[:len(path)-1]
	}
	walk(doc.Root, initialStyle(), true)
	return s, diags.list
}

func borderField(s *webstyle.ComputedStyle, id propertyID) *webstyle.Border {
	switch (id - pBorderTopWidth) / 3 {
	case 0:
		return &s.Border.Top
	case 1:
		return &s.Border.Right
	case 2:
		return &s.Border.Bottom
	default:
		return &s.Border.Left
	}
}

func lengthField(s *webstyle.ComputedStyle, id propertyID) *webstyle.Length {
	switch id {
	case pWidth:
		return &s.Width
	case pHeight:
		return &s.Height
	case pMinWidth:
		return &s.MinWidth
	case pMaxWidth:
		return &s.MaxWidth
	case pMinHeight:
		return &s.MinHeight
	case pMaxHeight:
		return &s.MaxHeight
	case pMarginTop:
		return &s.Margin.Top
	case pMarginRight:
		return &s.Margin.Right
	case pMarginBottom:
		return &s.Margin.Bottom
	case pMarginLeft:
		return &s.Margin.Left
	case pPaddingTop:
		return &s.Padding.Top
	case pPaddingRight:
		return &s.Padding.Right
	case pPaddingBottom:
		return &s.Padding.Bottom
	case pPaddingLeft:
		return &s.Padding.Left
	case pFontSize:
		return &s.FontSize
	case pLineHeight:
		return &s.LineHeight
	case pFlexBasis:
		return &s.FlexBasis
	case pRowGap:
		return &s.RowGap
	case pColumnGap:
		return &s.ColumnGap
	}
	if id >= pBorderTopWidth && id <= pBorderLeftColor && (id-pBorderTopWidth)%3 == 0 {
		return &borderField(s, id).Width
	}
	return nil
}

func colorField(s *webstyle.ComputedStyle, id propertyID) *webstyle.Color {
	if id == pColor {
		return &s.Color
	}
	if id == pBackgroundColor {
		return &s.BackgroundColor
	}
	if id >= pBorderTopWidth && id <= pBorderLeftColor && (id-pBorderTopWidth)%3 == 2 {
		return &borderField(s, id).Color
	}
	return nil
}

func valueOf(s *webstyle.ComputedStyle, id propertyID) value {
	if l := lengthField(s, id); l != nil {
		return value{length: *l}
	}
	if c := colorField(s, id); c != nil {
		return value{color: *c}
	}
	if id >= pBorderTopWidth && id <= pBorderLeftColor {
		return value{enum: uint8(borderField(s, id).Style)}
	}
	switch id {
	case pDisplay:
		return value{enum: uint8(s.Display)}
	case pFontFamily:
		return value{enum: uint8(s.FontFamily)}
	case pFontWeight:
		return value{enum: uint8(s.FontWeight)}
	case pFontStyle:
		return value{enum: uint8(s.FontStyle)}
	case pTextAlign:
		return value{enum: uint8(s.TextAlign)}
	case pWhiteSpace:
		return value{enum: uint8(s.WhiteSpace)}
	case pFlexDirection:
		return value{enum: uint8(s.FlexDirection)}
	case pFlexWrap:
		return value{enum: uint8(s.FlexWrap)}
	case pJustify:
		return value{enum: uint8(s.JustifyContent)}
	case pAlignItems:
		return value{enum: uint8(s.AlignItems)}
	case pFlexGrow:
		return value{enum: s.FlexGrow.Value, set: s.FlexGrow.Set}
	case pFlexShrink:
		return value{enum: s.FlexShrink.Value, set: s.FlexShrink.Set}
	}
	return value{}
}

func assign(s *webstyle.ComputedStyle, id propertyID, v value) {
	if l := lengthField(s, id); l != nil {
		*l = v.length
		return
	}
	if c := colorField(s, id); c != nil {
		*c = v.color
		return
	}
	if id >= pBorderTopWidth && id <= pBorderLeftColor {
		borderField(s, id).Style = webstyle.BorderStyle(v.enum)
		return
	}
	switch id {
	case pDisplay:
		s.Display = webstyle.Display(v.enum)
	case pFontFamily:
		s.FontFamily = webstyle.FontFamily(v.enum)
	case pFontWeight:
		s.FontWeight = webstyle.FontWeight(v.enum)
	case pFontStyle:
		s.FontStyle = webstyle.FontStyle(v.enum)
	case pTextAlign:
		s.TextAlign = webstyle.TextAlign(v.enum)
	case pWhiteSpace:
		s.WhiteSpace = webstyle.WhiteSpace(v.enum)
	case pFlexDirection:
		s.FlexDirection = webstyle.FlexDirection(v.enum)
	case pFlexWrap:
		s.FlexWrap = webstyle.FlexWrap(v.enum)
	case pJustify:
		s.JustifyContent = webstyle.JustifyContent(v.enum)
	case pAlignItems:
		s.AlignItems = webstyle.AlignItems(v.enum)
	case pFlexGrow:
		s.FlexGrow = webstyle.FlexFactor{Value: v.enum, Set: v.set}
	case pFlexShrink:
		s.FlexShrink = webstyle.FlexFactor{Value: v.enum, Set: v.set}
	}
}

// fontSizeStep is the CSS smaller/larger keyword: one step off the
// absolute-size ladder from the parent's computed px. Off the ladder ends the
// step is the ladder's own ratio (6/5), matching how the table is built.
func fontSizeStep(parentPx int32, dir int) int32 {
	ladder := [...]int32{8, 10, 12, 13, 16, 20, 26}
	if dir > 0 {
		for _, v := range ladder {
			if v > parentPx {
				return v
			}
		}
		return (parentPx*6 + 2) / 5
	}
	for i := len(ladder) - 1; i >= 0; i-- {
		if ladder[i] < parentPx {
			return ladder[i]
		}
	}
	return (parentPx*5 + 3) / 6
}
