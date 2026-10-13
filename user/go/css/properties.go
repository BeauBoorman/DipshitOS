package css

import (
	"strconv"
	"strings"
	"virelai/webstyle"
)

type propertyID uint8

const (
	pDisplay propertyID = iota
	pWidth
	pHeight
	pMinWidth
	pMaxWidth
	pMinHeight
	pMaxHeight
	pMarginTop
	pMarginRight
	pMarginBottom
	pMarginLeft
	pPaddingTop
	pPaddingRight
	pPaddingBottom
	pPaddingLeft
	pBorderTopWidth
	pBorderTopStyle
	pBorderTopColor
	pBorderRightWidth
	pBorderRightStyle
	pBorderRightColor
	pBorderBottomWidth
	pBorderBottomStyle
	pBorderBottomColor
	pBorderLeftWidth
	pBorderLeftStyle
	pBorderLeftColor
	pFontFamily
	pFontSize
	pFontWeight
	pFontStyle
	pLineHeight
	pColor
	pBackgroundColor
	pTextAlign
	pWhiteSpace
	pFlexDirection
	pFlexWrap
	pJustify
	pAlignItems
	pFlexGrow
	pFlexShrink
	pFlexBasis
	pRowGap
	pColumnGap
	propertyCount
)

var propertyNames = [...]string{
	"display", "width", "height", "min-width", "max-width", "min-height", "max-height",
	"margin-top", "margin-right", "margin-bottom", "margin-left",
	"padding-top", "padding-right", "padding-bottom", "padding-left",
	"border-top-width", "border-top-style", "border-top-color",
	"border-right-width", "border-right-style", "border-right-color",
	"border-bottom-width", "border-bottom-style", "border-bottom-color",
	"border-left-width", "border-left-style", "border-left-color",
	"font-family", "font-size", "font-weight", "font-style", "line-height",
	"color", "background-color", "text-align", "white-space",
	"flex-direction", "flex-wrap", "justify-content", "align-items",
	"flex-grow", "flex-shrink", "flex-basis", "row-gap", "column-gap",
}

const (
	valueNormal byte = iota
	valueInherit
	valueInitial
)

type value struct {
	length webstyle.Length
	color  webstyle.Color
	enum   uint8
	mode   byte
	set    bool
}
type declaration struct {
	id        propertyID
	value     value
	important bool
}

func propertyGroup(name string) []propertyID {
	for i, n := range propertyNames {
		if n == name {
			return []propertyID{propertyID(i)}
		}
	}
	var ids []propertyID
	switch name {
	case "margin":
		ids = []propertyID{pMarginTop, pMarginRight, pMarginBottom, pMarginLeft}
	case "padding":
		ids = []propertyID{pPaddingTop, pPaddingRight, pPaddingBottom, pPaddingLeft}
	case "gap":
		ids = []propertyID{pRowGap, pColumnGap}
	case "border-width", "border-style", "border-color":
		offset := propertyID(0)
		if name == "border-style" {
			offset = 1
		} else if name == "border-color" {
			offset = 2
		}
		for i := propertyID(0); i < 4; i++ {
			ids = append(ids, pBorderTopWidth+i*3+offset)
		}
	case "border", "border-top", "border-right", "border-bottom", "border-left":
		first, last := pBorderTopWidth, pBorderLeftColor
		for i, side := range []string{"top", "right", "bottom", "left"} {
			if name == "border-"+side {
				first = pBorderTopWidth + propertyID(i*3)
				last = first + 2
			}
		}
		for id := first; id <= last; id++ {
			ids = append(ids, id)
		}
	}
	return ids
}

func (p *parser) property(name string, ts []token, start token) []declaration {
	ids := propertyGroup(name)
	if len(ids) == 0 {
		p.warn(webstyle.DiagnosticUnsupported, start, "unsupported-property "+name)
		return nil
	}
	ts = trim(ts)
	if len(ts) == 1 && ts[0].kind == tIdent && (lower(ts[0].text) == "inherit" || lower(ts[0].text) == "initial") {
		mode := valueInitial
		if lower(ts[0].text) == "inherit" {
			mode = valueInherit
		}
		var out []declaration
		for _, id := range ids {
			out = append(out, declaration{id: id, value: value{mode: mode}})
		}
		return out
	}
	parts := splitValues(ts)
	var out []declaration
	problem := ""
	if name == "border" || name == "border-top" || name == "border-right" || name == "border-bottom" || name == "border-left" {
		// Omitted shorthand components reset, never inherit lower longhands.
		vals := [3]value{}
		seen := [3]bool{}
		if len(parts) == 0 || len(parts) > 3 {
			problem = "invalid-value"
		}
		for _, part := range parts {
			matched := false
			for component := 0; component < 3; component++ {
				v, why := p.single(pBorderTopWidth+propertyID(component), part, start)
				if why == "" && !seen[component] {
					vals[component], seen[component], matched = v, true, true
					break
				}
			}
			if !matched {
				problem = "unsupported-value"
			}
		}
		if problem == "" {
			for _, id := range ids {
				out = append(out, declaration{id: id, value: vals[(id-pBorderTopWidth)%3]})
			}
		}
	} else if len(ids) > 1 {
		max := 4
		if name == "gap" {
			max = 2
		}
		if len(parts) == 0 || len(parts) > max {
			problem = "invalid-value"
		} else {
			var vals []value
			for _, part := range parts {
				v, why := p.single(ids[0], part, start)
				if why != "" {
					problem = why
					break
				}
				vals = append(vals, v)
			}
			if problem == "" {
				order := [4]int{0, 0, 0, 0}
				if len(vals) >= 2 {
					order[1], order[3] = 1, 1
				}
				if len(vals) >= 3 {
					order[2] = 2
				}
				if len(vals) == 4 {
					order[3] = 3
				}
				for i, id := range ids {
					out = append(out, declaration{id: id, value: vals[order[i]]})
				}
			}
		}
	} else {
		v, why := p.single(ids[0], ts, start)
		problem = why
		if why == "" {
			out = []declaration{{id: ids[0], value: v}}
		}
	}
	if problem != "" {
		if problem == "font-family-fallback" {
			return nil // unknown entries have already emitted their diagnostic
		}
		kind := webstyle.DiagnosticInvalid
		if problem == "unsupported-value" {
			kind = webstyle.DiagnosticUnsupported
		}
		p.warn(kind, start, problem+" "+name)
		return nil
	}
	return out
}

// Split shorthand values only on top-level whitespace, preserving rgb(...) and
// strings as a single component.
func splitValues(ts []token) [][]token {
	var parts [][]token
	depth, start := 0, 0
	for i, t := range ts {
		if t.punct("(") {
			depth++
		} else if t.punct(")") {
			depth--
		} else if t.kind == tSpace && depth == 0 {
			if i > start {
				parts = append(parts, ts[start:i])
			}
			start = i + 1
		}
	}
	if start < len(ts) {
		parts = append(parts, ts[start:])
	}
	return parts
}

func integer(t token) (int32, bool) {
	if t.kind != tNumber || strings.Contains(t.text, ".") {
		return 0, false
	}
	n, err := strconv.ParseInt(t.text, 10, 32)
	return int32(n), err == nil
}

// centis parses a non-negative decimal ("1.5", "0.75", "2") into hundredths —
// the stored unit for em/rem font-size values. Empty, signed, over-precise
// (more than two fraction digits) or overflowing inputs fail.
func centis(s string) (int32, bool) {
	n, frac, fracDigits, seenDot := int64(0), int64(0), 0, false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '.' && !seenDot {
			seenDot = true
			continue
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		if seenDot {
			frac, fracDigits = frac*10+int64(c-'0'), fracDigits+1
		} else {
			n = n*10 + int64(c-'0')
		}
		if n > 10000 || fracDigits > 2 {
			return 0, false
		}
	}
	if len(s) == 0 || seenDot && fracDigits == 0 || !seenDot && len(s) == 0 {
		return 0, false
	}
	if fracDigits == 1 {
		frac *= 10
	}
	return int32(n*100 + frac), true
}

func length(t token, percent, auto, negative bool) (webstyle.Length, string) {
	s := lower(t.text)
	if t.kind == tIdent && s == "auto" && auto {
		return webstyle.Length{Kind: webstyle.LengthAuto}, ""
	}
	kind := webstyle.LengthPx
	switch t.kind {
	case tDimension:
		if !strings.HasSuffix(s, "px") {
			return webstyle.Length{}, "unsupported-value"
		}
		s = s[:len(s)-2]
	case tPercent:
		if !percent {
			return webstyle.Length{}, "unsupported-value"
		}
		kind, s = webstyle.LengthPercent, s[:len(s)-1]
	case tNumber:
	default:
		return webstyle.Length{}, "unsupported-value"
	}
	n, ok := integer(token{kind: tNumber, text: s})
	if !ok || n < -32768 || n > 32768 || n < 0 && (!negative || kind == webstyle.LengthPercent) ||
		kind == webstyle.LengthPercent && n > 100 || t.kind == tNumber && n != 0 {
		return webstyle.Length{}, "invalid-value"
	}
	return webstyle.Length{Kind: kind, Value: n}, ""
}

func enumValue(ts []token, names ...string) (value, string) {
	if len(ts) == 1 && ts[0].kind == tIdent {
		s := lower(ts[0].text)
		for i, name := range names {
			if s == name {
				return value{enum: uint8(i)}, ""
			}
		}
	}
	return value{}, "unsupported-value"
}

func (p *parser) single(id propertyID, ts []token, start token) (value, string) {
	ts = trim(ts)
	if len(ts) == 0 {
		return value{}, "invalid-value"
	}
	if id == pFontFamily {
		return p.family(ts, start)
	}
	if id == pColor || id == pBackgroundColor || id >= pBorderTopWidth && id <= pBorderLeftColor && (id-pBorderTopWidth)%3 == 2 {
		c, ok := colorValue(ts)
		if !ok {
			return value{}, "unsupported-value"
		}
		return value{color: c}, ""
	}
	if len(ts) > 1 && ts[0].kind == tIdent && ts[1].punct("(") {
		return value{}, "unsupported-value"
	}
	switch id {
	case pDisplay:
		return enumValue(ts, "inline", "block", "none", "flex", "list-item", "table",
			"table-row-group", "table-header-group", "table-footer-group", "table-row", "table-cell", "table-caption")
	case pFontStyle:
		return enumValue(ts, "normal", "italic")
	case pFontSize:
		// Absolute keywords use the CSS absolute-size ladder scaled so
		// medium = the frozen 13px initial: factors {0.6,0.75,0.89,1,1.2,
		// 1.5,2} land on {8,10,12,13,16,20,26}. em/rem keep hundredths and
		// resolve in the cascade against parent/root computed size;
		// smaller/larger step the same ladder off the parent's size.
		if len(ts) == 1 {
			t := ts[0]
			if t.kind == tIdent {
				switch lower(t.text) {
				case "xx-small":
					return value{length: webstyle.Length{Kind: webstyle.LengthPx, Value: 8}}, ""
				case "x-small":
					return value{length: webstyle.Length{Kind: webstyle.LengthPx, Value: 10}}, ""
				case "small":
					return value{length: webstyle.Length{Kind: webstyle.LengthPx, Value: 12}}, ""
				case "medium":
					return value{length: webstyle.Length{Kind: webstyle.LengthPx, Value: 13}}, ""
				case "large":
					return value{length: webstyle.Length{Kind: webstyle.LengthPx, Value: 16}}, ""
				case "x-large":
					return value{length: webstyle.Length{Kind: webstyle.LengthPx, Value: 20}}, ""
				case "xx-large":
					return value{length: webstyle.Length{Kind: webstyle.LengthPx, Value: 26}}, ""
				case "smaller":
					return value{length: webstyle.Length{Kind: webstyle.LengthFontSmaller}}, ""
				case "larger":
					return value{length: webstyle.Length{Kind: webstyle.LengthFontLarger}}, ""
				}
			}
			if t.kind == tDimension {
				s := lower(t.text)
				for _, u := range []struct {
					suffix string
					kind   webstyle.LengthKind
				}{{"rem", webstyle.LengthRem}, {"em", webstyle.LengthEm}} {
					if strings.HasSuffix(s, u.suffix) {
						if c, ok := centis(s[:len(s)-len(u.suffix)]); ok && c > 0 {
							return value{length: webstyle.Length{Kind: u.kind, Value: c}}, ""
						}
						return value{}, "invalid-value"
					}
				}
			}
		}
	case pFontWeight:
		if len(ts) == 1 {
			s := lower(ts[0].text)
			if ts[0].kind == tIdent && (s == "normal" || s == "bold") {
				return enumValue(ts, "normal", "bold")
			}
			// Any integer weight 100-900 (M99p #2193): 600 and up resolve to
			// the real bold face, below is normal — the two-weight engine's
			// honest answer, not a clamped lie.
			if n, ok := integer(ts[0]); ok && n >= 100 && n <= 900 {
				if n >= 600 {
					return value{enum: uint8(webstyle.WeightBold)}, ""
				}
				return value{}, ""
			}
		}
		return value{}, "unsupported-value"
	case pTextAlign:
		return enumValue(ts, "left", "center", "right")
	case pWhiteSpace:
		return enumValue(ts, "normal", "pre", "pre-wrap")
	case pFlexDirection:
		return enumValue(ts, "row", "column")
	case pFlexWrap:
		return enumValue(ts, "nowrap", "wrap")
	case pJustify:
		return enumValue(ts, "flex-start", "flex-end", "center", "space-between", "space-around", "space-evenly")
	case pAlignItems:
		return enumValue(ts, "stretch", "flex-start", "flex-end", "center")
	case pFlexGrow, pFlexShrink:
		if len(ts) == 1 {
			if n, ok := integer(ts[0]); ok && n >= 0 && n <= 16 {
				return value{enum: uint8(n), set: true}, ""
			}
		}
		return value{}, "invalid-value"
	}
	if len(ts) != 1 {
		return value{}, "invalid-value"
	}
	t := ts[0]
	if id >= pBorderTopWidth && id <= pBorderLeftColor {
		if (id-pBorderTopWidth)%3 == 1 {
			return enumValue(ts, "none", "solid")
		}
		if t.kind == tIdent {
			for i, name := range []string{"thin", "medium", "thick"} {
				if lower(t.text) == name {
					return value{length: webstyle.Length{Kind: webstyle.LengthPx, Value: [...]int32{1, 3, 5}[i]}}, ""
				}
			}
		}
		l, why := length(t, false, false, false)
		if why == "" && l.Value > 32 {
			why = "invalid-value"
		}
		return value{length: l}, why
	}
	if id == pLineHeight && t.kind == tIdent && lower(t.text) == "normal" {
		return value{}, ""
	}
	if (id == pMaxWidth || id == pMaxHeight) && t.kind == tIdent && lower(t.text) == "none" {
		return value{length: webstyle.Length{Kind: webstyle.LengthAuto}}, ""
	}
	percent := id == pWidth || id == pMinWidth || id == pMaxWidth ||
		id >= pMarginTop && id <= pPaddingLeft || id == pFlexBasis
	auto := id == pWidth || id == pHeight || id >= pMarginTop && id <= pMarginLeft || id == pFlexBasis
	negative := id >= pMarginTop && id <= pMarginLeft
	if id >= pPaddingTop && id <= pPaddingLeft && t.kind == tIdent && lower(t.text) == "auto" {
		return value{}, "invalid-value"
	}
	l, why := length(t, percent, auto, negative)
	if why == "" && (id == pFontSize && (l.Value < 8 || l.Value > 48) ||
		id == pLineHeight && (l.Value < 1 || l.Value > 128)) {
		why = "invalid-value"
	}
	return value{length: l}, why
}

func (p *parser) family(ts []token, start token) (value, string) {
	var chosen value
	known := false
	for len(ts) > 0 {
		i := 0
		for i < len(ts) && !ts[i].punct(",") {
			i++
		}
		part := trim(ts[:i])
		var name string
		valid := len(part) > 0
		if len(part) == 1 && part[0].kind == tString {
			name = part[0].text
		} else {
			var names []string
			for _, t := range part {
				if t.kind == tIdent {
					names = append(names, t.text)
				} else if t.kind == tSpace {
					continue
				} else {
					valid = false
				}
			}
			name = strings.Join(names, " ")
		}
		if !valid {
			return value{}, "invalid-value"
		}
		// Generic families map per M99p (#2193): system-ui/ui-sans-serif are
		// the sans face, ui-monospace the mono face, cursive/fantasy degrade
		// to sans with a diagnostic. Named families select the registry role
		// for that shipped family: Inter->sans, Fira Code->mono,
		// Noto Serif->serif. A name nobody shipped warns and yields to the
		// next list entry; a list with no known name drops the declaration.
		switch lower(name) {
		case "inter", "sans-serif", "system-ui", "ui-sans-serif":
			if !known {
				chosen, known = value{enum: uint8(webstyle.FontSans)}, true
			}
		case "fira code", "firacode", "monospace", "ui-monospace":
			if !known {
				chosen, known = value{enum: uint8(webstyle.FontMono)}, true
			}
		case "serif", "noto serif":
			if !known {
				chosen, known = value{enum: uint8(webstyle.FontSerif)}, true
			}
		case "cursive", "fantasy":
			p.warn(webstyle.DiagnosticUnsupported, start, "font-family-generic "+name)
			if !known {
				chosen, known = value{enum: uint8(webstyle.FontSans)}, true
			}
		default:
			p.warn(webstyle.DiagnosticUnsupported, start, "font-family-fallback "+name)
		}
		if i == len(ts) {
			break
		}
		ts = trim(ts[i+1:])
		if len(ts) == 0 {
			return value{}, "invalid-value"
		}
	}
	if !known {
		return value{}, "font-family-fallback"
	}
	return chosen, ""
}

func colorValue(ts []token) (webstyle.Color, bool) {
	if len(ts) == 1 {
		t := ts[0]
		s := lower(t.text)
		if t.kind == tHash && (len(s) == 3 || len(s) == 6) {
			var n uint32
			for i := 0; i < len(s); i++ {
				h := hex(s[i])
				if h < 0 {
					return webstyle.Color{}, false
				}
				if len(s) == 3 {
					n = n<<8 | uint32(h*17)
				} else {
					n = n<<4 | uint32(h)
				}
			}
			return webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000 | n}, true
		}
		if t.kind == tIdent {
			if s == "currentcolor" {
				return webstyle.Color{Kind: webstyle.ColorCurrent}, true
			}
			if s == "transparent" {
				return webstyle.Color{Kind: webstyle.ColorRGBA}, true
			}
			names := [...]string{"black", "silver", "gray", "white", "maroon", "red", "purple", "fuchsia",
				"green", "lime", "olive", "yellow", "navy", "blue", "teal", "aqua"}
			rgb := [...]uint32{0x000000, 0xc0c0c0, 0x808080, 0xffffff, 0x800000, 0xff0000, 0x800080, 0xff00ff,
				0x008000, 0x00ff00, 0x808000, 0xffff00, 0x000080, 0x0000ff, 0x008080, 0x00ffff}
			for i, name := range names {
				if name == s {
					return webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000 | rgb[i]}, true
				}
			}
		}
	}
	// A function name and '(' must be adjacent tokens, not "rgb (".
	if len(ts) >= 2 && ts[0].kind == tIdent && lower(ts[0].text) == "rgb" && ts[1].punct("(") {
		ts = compact(ts)
		if len(ts) == 8 && ts[3].punct(",") && ts[5].punct(",") && ts[7].punct(")") {
			rgb := uint32(0xff000000)
			for i := 0; i < 3; i++ {
				n, ok := integer(ts[2+i*2])
				if !ok || n < 0 || n > 255 {
					return webstyle.Color{}, false
				}
				rgb |= uint32(n) << (16 - i*8)
			}
			return webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: rgb}, true
		}
	}
	return webstyle.Color{}, false
}
