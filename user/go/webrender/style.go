package webrender

import (
	"virelai/theme"
	"virelai/webstyle"
)

// Theme colors — imported from virelai/theme (M69c #1530) so WEB chrome and
// the page default share the same table GOTABWM/NOTE/widgets draw from.
// Assigned from Dark so the webrender goldens stay on the dark boot default.
var (
	ColorPageBg    = theme.Dark.Bg
	ColorSurface   = theme.Dark.Surface
	ColorText      = theme.Dark.Ink
	ColorMuted     = theme.Dark.InkMuted
	ColorAccent    = theme.Dark.Accent
	ColorRule      = theme.Dark.Rule
	ColorChromeBg  = theme.Dark.ChromeBg
	ColorChromeInk = theme.Dark.Ink
	ColorError     = theme.Dark.Danger
	ColorOK        = theme.Dark.Ok
)

// Style is the text/paint seam. StyleFor remains the legacy UA-width adapter;
// the CSS pipeline supplies frozen webstyle values to BuildBoxTree instead.
// No CSS parser or cascade is imported by the renderer.
type Style struct {
	Size         int    // font scale: 1 => 8px, 2 => 16px
	FontPx       int    // positive CSS px; zero retains logical-size compatibility
	LineHeightPx int    // positive used CSS line height; zero selects engine metrics
	Mono         bool   // fixed-width face
	Serif        bool   // serif face (registry role "serif"; e.g. Noto Serif)
	Bold         bool   // Inter Bold when loaded; else a 1-px synthetic strike
	Italic       bool   // Inter Italic when loaded; else the UI face
	Align        int    // 0 left, 1 center
	MarginTop    int    // px before the block
	MarginBottom int    // px after the block
	Indent       int    // px of left indent applied to the block
	Color        uint32 // 0 => default text color
	Bg           uint32 // 0 => no background
	Decoration   uint8  // decRule draws an underline, decBar a left accent bar
	Skip         bool   // never rendered (head/script/style/...)
}

// compatibilityStyles derives value copies from the existing UA tag table,
// preserving its inline inheritance and logical font metrics. M93f replaces
// this adapter with styles.ForNode, not a second concurrent cascade.
func compatibilityStyles(doc *Document) func(*Node) webstyle.ComputedStyle {
	values := make(map[*Node]webstyle.ComputedStyle)
	var visit func(*Node, Style, int)
	visit = func(n *Node, parent Style, depth int) {
		if n == nil || depth > webstyle.MaxDepth || len(values) >= webstyle.MaxBoxes {
			return
		}
		ua := parent
		if n.Kind != KindText {
			ua = StyleFor(n.Tag)
			if !BlockElement(n.Tag) {
				ua = mergeInline(parent, ua)
			}
		}
		s := webstyle.ComputedStyle{
			Color:    webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000 | ua.Color},
			FontSize: webstyle.Length{Kind: webstyle.LengthPx, Value: int32(13 * max(1, ua.Size))},
		}
		if n.Kind != KindText && BlockElement(n.Tag) {
			s.Display = webstyle.DisplayBlock
		}
		if ua.Skip && n.Tag != "noscript" {
			s.Display = webstyle.DisplayNone
		}
		if ua.Mono {
			s.FontFamily = webstyle.FontMono
		}
		if ua.Bold {
			s.FontWeight = webstyle.WeightBold
		}
		if ua.Italic {
			s.FontStyle = webstyle.StyleItalic
		}
		s.Margin.Top = webstyle.Length{Kind: webstyle.LengthPx, Value: int32(ua.MarginTop)}
		s.Margin.Bottom = webstyle.Length{Kind: webstyle.LengthPx, Value: int32(ua.MarginBottom)}
		s.Padding.Left = webstyle.Length{Kind: webstyle.LengthPx, Value: int32(ua.Indent)}
		if ua.Bg != 0 {
			s.BackgroundColor = webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: 0xff000000 | ua.Bg}
		}
		values[n] = s
		for _, c := range n.Children {
			visit(c, ua, depth+1)
		}
	}
	if doc != nil {
		visit(doc.Root, StyleFor("body"), 0)
	}
	return func(n *Node) webstyle.ComputedStyle { return values[n] }
}

// Decoration kinds.
const (
	decNone uint8 = iota
	decRule
	decBar
)

// DefaultStyle is the body text style.
var DefaultStyle = Style{Size: 1, Color: ColorText, MarginBottom: 4}

// LinkStyle is the <a> style.
var LinkStyle = Style{Size: 1, Color: ColorAccent, Decoration: decRule, MarginBottom: 4}

// StyleFor returns the UA style for a tag. Unknown tags render as inline
// content in the enclosing block — they never vanish.
func StyleFor(tag string) Style {
	switch tag {
	case "html", "body", "document":
		return Style{Size: 1, Color: ColorText}
	case "h1":
		return Style{Size: 2, Bold: true, Color: ColorText, MarginTop: 10, MarginBottom: 8}
	case "h2":
		return Style{Size: 2, Bold: true, Color: ColorText, MarginTop: 8, MarginBottom: 6}
	case "h3":
		return Style{Size: 1, Bold: true, Color: ColorText, MarginTop: 8, MarginBottom: 5}
	case "h4", "h5", "h6":
		return Style{Size: 1, Bold: true, Color: ColorMuted, MarginTop: 6, MarginBottom: 4}
	case "p":
		return Style{Size: 1, Color: ColorText, MarginBottom: 8}
	case "div", "section", "article", "header", "footer", "main", "nav", "aside", "figure":
		return Style{Size: 1, Color: ColorText, MarginBottom: 4}
	case "figcaption":
		return Style{Size: 1, Color: ColorMuted, MarginBottom: 6}
	case "ul", "ol":
		return Style{Size: 1, Color: ColorText, Indent: 8, MarginTop: 2, MarginBottom: 8}
	case "li":
		return Style{Size: 1, Color: ColorText, Indent: 12, MarginBottom: 3}
	case "dl":
		return Style{Size: 1, Color: ColorText, MarginBottom: 8}
	case "dt":
		return Style{Size: 1, Bold: true, Color: ColorText, MarginBottom: 2}
	case "dd":
		return Style{Size: 1, Color: ColorMuted, Indent: 12, MarginBottom: 4}
	case "pre":
		return Style{Size: 1, Mono: true, Color: ColorText, Bg: ColorSurface, MarginTop: 4, MarginBottom: 8, Indent: 6}
	case "code", "kbd", "samp", "tt":
		return Style{Size: 1, Mono: true, Color: ColorText, Bg: ColorSurface}
	case "blockquote":
		return Style{Size: 1, Color: ColorMuted, Indent: 14, Decoration: decBar, MarginTop: 4, MarginBottom: 8}
	case "hr":
		return Style{Size: 1, Color: ColorRule, MarginTop: 8, MarginBottom: 8}
	case "a":
		return LinkStyle
	case "strong", "b":
		return Style{Size: 1, Bold: true, Color: ColorText}
	case "em", "i":
		return Style{Size: 1, Italic: true, Color: ColorAccent}
	case "small":
		return Style{Size: 1, Color: ColorMuted}
	case "table":
		return Style{Size: 1, Color: ColorText, MarginTop: 4, MarginBottom: 8}
	case "thead", "tbody", "tr":
		return Style{Size: 1, Color: ColorText}
	case "th":
		return Style{Size: 1, Bold: true, Color: ColorText}
	case "td":
		return Style{Size: 1, Color: ColorText}
	case "img":
		return Style{Size: 1, Color: ColorMuted, MarginTop: 4, MarginBottom: 8}
	case "form":
		return Style{Size: 1, Color: ColorText, MarginTop: 4, MarginBottom: 8}
	case "fieldset":
		return Style{Size: 1, Color: ColorText, MarginTop: 6, MarginBottom: 8, Indent: 4}
	case "legend":
		return Style{Size: 1, Bold: true, Color: ColorText, MarginBottom: 4}
	case "label":
		return Style{Size: 1, Color: ColorText}
	case "input", "textarea", "select", "button":
		return Style{Size: 1, Color: ColorText, Bg: ColorSurface, MarginBottom: 4}
	case "address":
		return Style{Size: 1, Color: ColorMuted, MarginTop: 4, MarginBottom: 8}
	case "script", "style", "head", "title", "meta", "link", "template":
		return Style{Skip: true}
	}
	return Style{Size: 1, Color: ColorText}
}
