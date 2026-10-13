package css

import (
	"strings"
	"testing"
	"virelai/webrender"
	"virelai/webstyle"
)

func px(n int32) webstyle.Length { return webstyle.Length{Kind: webstyle.LengthPx, Value: n} }
func pct(n int32) webstyle.Length {
	return webstyle.Length{Kind: webstyle.LengthPercent, Value: n}
}
func rgba(n uint32) webstyle.Color { return webstyle.Color{Kind: webstyle.ColorRGBA, RGBA: n} }

func parseDecl(t *testing.T, source string) []declaration {
	t.Helper()
	p := newParser(source)
	out := p.declarations(false)
	if len(p.diags.list) != 0 {
		t.Fatalf("%s: %+v", source, p.diags.list)
	}
	return out
}

func TestEveryLonghandValidInvalidAndEdge(t *testing.T) {
	for id, name := range propertyNames {
		t.Run(name, func(t *testing.T) {
			pid := propertyID(id)
			valid, edge, invalid := "12px", "0", "-1px"
			want, wantEdge := value{length: px(12)}, value{length: px(0)}
			switch pid {
			case pDisplay:
				valid, edge, invalid = "flex", "table-caption", "inline-block"
				want.enum, wantEdge.enum = uint8(webstyle.DisplayFlex), uint8(webstyle.DisplayTableCaption)
			case pWidth, pMinWidth, pMaxWidth, pFlexBasis:
				edge, invalid = "100%", "101%"
				wantEdge.length = pct(100)
			case pMarginTop, pMarginRight, pMarginBottom, pMarginLeft:
				edge, invalid = "-32768px", "101%"
				wantEdge.length = px(-32768)
			case pFontFamily:
				valid, edge, invalid = `"Fira Code"`, "serif", `"missing"`
				want.enum, wantEdge.enum = uint8(webstyle.FontMono), uint8(webstyle.FontSerif)
			case pFontSize:
				edge, invalid = "48px", "49px"
				wantEdge.length = px(48)
			case pFontWeight:
				valid, edge, invalid = "700", "100", "bolder"
				want.enum, wantEdge.enum = uint8(webstyle.WeightBold), uint8(webstyle.WeightNormal)
			case pFontStyle:
				valid, edge, invalid = "italic", "normal", "oblique"
				want.enum, wantEdge.enum = uint8(webstyle.StyleItalic), uint8(webstyle.StyleNormal)
			case pLineHeight:
				edge, invalid = "128px", "129px"
				wantEdge.length = px(128)
			case pColor, pBackgroundColor:
				valid, edge, invalid = "#123", "rgb(0,255,0)", "rgba(0,0,0,1)"
				want.color, wantEdge.color = rgba(0xff112233), rgba(0xff00ff00)
			case pTextAlign:
				valid, edge, invalid = "right", "left", "justify"
				want.enum, wantEdge.enum = uint8(webstyle.AlignRight), uint8(webstyle.AlignLeft)
			case pWhiteSpace:
				valid, edge, invalid = "pre-wrap", "normal", "nowrap"
				want.enum, wantEdge.enum = uint8(webstyle.WhiteSpacePreWrap), uint8(webstyle.WhiteSpaceNormal)
			case pFlexDirection:
				valid, edge, invalid = "column", "row", "row-reverse"
				want.enum, wantEdge.enum = uint8(webstyle.FlexColumn), uint8(webstyle.FlexRow)
			case pFlexWrap:
				valid, edge, invalid = "wrap", "nowrap", "wrap-reverse"
				want.enum, wantEdge.enum = uint8(webstyle.FlexWrapLines), uint8(webstyle.FlexNoWrap)
			case pJustify:
				valid, edge, invalid = "space-evenly", "flex-start", "safe center"
				want.enum, wantEdge.enum = uint8(webstyle.JustifySpaceEvenly), uint8(webstyle.JustifyStart)
			case pAlignItems:
				valid, edge, invalid = "center", "stretch", "baseline"
				want.enum, wantEdge.enum = uint8(webstyle.ItemsCenter), uint8(webstyle.ItemsStretch)
			case pFlexGrow, pFlexShrink:
				valid, edge, invalid = "16", "0", "17"
				want, wantEdge = value{enum: 16, set: true}, value{enum: 0, set: true}
			}
			if pid >= pBorderTopWidth && pid <= pBorderLeftColor {
				switch (pid - pBorderTopWidth) % 3 {
				case 0:
					edge, invalid = "32px", "33px"
					wantEdge.length = px(32)
				case 1:
					valid, edge, invalid = "solid", "none", "dotted"
					want.enum, wantEdge.enum = uint8(webstyle.BorderSolid), uint8(webstyle.BorderNone)
				case 2:
					valid, edge, invalid = "#123", "transparent", "hsl(0,0%,0%)"
					want.color, wantEdge.color = rgba(0xff112233), rgba(0)
				}
			}
			// Enum/color expectations do not retain the default length.
			if pid == pDisplay || pid >= pFontFamily && pid != pFontSize && pid != pLineHeight &&
				pid != pFlexBasis && pid != pRowGap && pid != pColumnGap ||
				pid >= pBorderTopWidth && pid <= pBorderLeftColor && (pid-pBorderTopWidth)%3 != 0 {
				want.length, wantEdge.length = webstyle.Length{}, webstyle.Length{}
			}
			for i, input := range []string{valid, edge} {
				ds := parseDecl(t, name+":"+input)
				expected := want
				if i == 1 {
					expected = wantEdge
				}
				if len(ds) != 1 || ds[0].id != pid || ds[0].value != expected {
					t.Fatalf("%s: got %+v, want %+v", input, ds, expected)
				}
			}
			p := newParser(name + ":" + invalid)
			if ds := p.declarations(false); len(ds) != 0 || len(p.diags.list) == 0 {
				t.Fatalf("invalid %s accepted: %+v / %+v", invalid, ds, p.diags.list)
			}
			// Rejecting a later value must preserve the valid cascade winner.
			doc := webrender.ParseHTML([]byte(`<span id="target">text</span>`))
			clean, _ := Parse([]byte("span{" + name + ":" + valid + "}"))
			bad, _ := Parse([]byte("span{" + name + ":" + valid + ";" + name + ":" + invalid + "}"))
			a, _ := Cascade(doc, []*Stylesheet{clean})
			b, _ := Cascade(doc, []*Stylesheet{bad})
			if a.ForNode(find(doc, "target")) != b.ForNode(find(doc, "target")) {
				t.Fatal("invalid value overwrote lower valid value")
			}
		})
	}
}

func TestShorthandsAtomicAndReset(t *testing.T) {
	for _, name := range []string{"margin", "padding", "border-width", "border-style", "border-color", "gap",
		"border", "border-top", "border-right", "border-bottom", "border-left"} {
		t.Run(name, func(t *testing.T) {
			for _, keyword := range []string{"initial", "inherit"} {
				if ds := parseDecl(t, name+":"+keyword); len(ds) != len(propertyGroup(name)) {
					t.Fatal("keyword expansion", ds)
				}
			}
		})
	}
	for _, tc := range []struct {
		text string
		want []value
	}{
		{"margin:1px", []value{{length: px(1)}, {length: px(1)}, {length: px(1)}, {length: px(1)}}},
		{"margin:1px 2px", []value{{length: px(1)}, {length: px(2)}, {length: px(1)}, {length: px(2)}}},
		{"margin:1px 2px 3px", []value{{length: px(1)}, {length: px(2)}, {length: px(3)}, {length: px(2)}}},
		{"margin:1px 2px 3px 4px", []value{{length: px(1)}, {length: px(2)}, {length: px(3)}, {length: px(4)}}},
		{"padding:100% 0", []value{{length: pct(100)}, {length: px(0)}, {length: pct(100)}, {length: px(0)}}},
		{"gap:1px 2px", []value{{length: px(1)}, {length: px(2)}}},
		{"border-width:thin medium thick 0", []value{{length: px(1)}, {length: px(3)}, {length: px(5)}, {length: px(0)}}},
	} {
		ds := parseDecl(t, tc.text)
		for i, v := range tc.want {
			if ds[i].value != v {
				t.Fatalf("%s: %+v", tc.text, ds)
			}
		}
	}
	for _, invalid := range []string{
		"margin:1px 2px 3px 4px 5px", "padding:1px -2px", "padding:auto",
		"border:2px dashed red", "border-style:solid dotted", "gap:1px 2%",
		"border-width:1px 33px", "border-color:red hsl(0,0%,0%)", "border:solid solid",
	} {
		p := newParser(invalid)
		if ds := p.declarations(false); len(ds) != 0 || len(p.diags.list) == 0 {
			t.Fatalf("non-atomic rejection %s: %+v", invalid, ds)
		}
	}
	doc := webrender.ParseHTML([]byte(`<span id="target">text</span>`))
	sheet, _ := Parse([]byte(`span{color:red; border:4px solid blue; border:none}`))
	styles, _ := Cascade(doc, []*Stylesheet{sheet})
	b := styles.ForNode(find(doc, "target")).Border.Top
	if b.Width.Kind != webstyle.LengthInitial || b.Style != webstyle.BorderNone || b.Color != rgba(0xffff0000) {
		t.Fatal("border omission did not reset", b)
	}
}

func TestAdditionalValueEdges(t *testing.T) {
	for _, source := range []string{
		"width:auto", "height:auto", "max-width:none", "max-height:none",
		"margin:auto", "margin:100%", "width:32768px", "font-size:8px",
		"line-height:normal", "line-height:1px", "flex-basis:auto", "color:currentColor",
		"color:#ABCDEF", "font-weight:600", "font-weight:500", "font-weight:550",
		"font-size:large", "font-size:2em", "font-size:0.85rem", "font-size:larger",
		`font-family:Remote, "Fira Code", Inter`,
		`font-family:Fira /*comment*/ Code`,
	} {
		p := newParser(source)
		if len(p.declarations(false)) == 0 {
			t.Fatal("valid edge", source, p.diags.list)
		}
	}
	for _, source := range []string{
		"width:32769px", "width:1.5px", "width:1", "height:1%", "min-height:100%",
		"font-size:7px", "line-height:0", "line-height:1", "margin:-1%",
		"gap:32769px", "border-width:-1px", "color:#12", "color:rgb(256,0,0)",
		"color:rgb(10%,0,0)", "color:rgb (0,0,0)", "font-size:1.234em", "font-weight:50",
		`font-family:"Inter" Remote`, "font-family:monospace,", "width:calc(1px + 2px)",
	} {
		p := newParser(source)
		if ds := p.declarations(false); len(ds) != 0 || len(p.diags.list) == 0 {
			t.Fatal("invalid edge", source, ds, p.diags.list)
		}
	}
	// Every admitted enum spelling, not just one representative.
	for _, tc := range []struct{ property, values string }{
		{"display", "inline block none flex list-item table table-row-group table-header-group table-footer-group table-row table-cell table-caption"},
		{"justify-content", "flex-start flex-end center space-between space-around space-evenly"},
		{"align-items", "stretch flex-start flex-end center"},
		{"color", "black silver gray white maroon red purple fuchsia green lime olive yellow navy blue teal aqua"},
	} {
		for _, v := range strings.Fields(tc.values) {
			parseDecl(t, tc.property+":"+v)
		}
	}
}

func TestFontFallbackPreservesWinnerAndWarnsOnce(t *testing.T) {
	doc, s, ds := compute(t, `<main><span id="target">text</span></main>`,
		`main{font-family:monospace}span{font-family:Missing}`)
	if len(ds) != 1 || !strings.HasPrefix(ds[0].Text, "font-family-fallback Missing") ||
		s.ForNode(find(doc, "target")).FontFamily != webstyle.FontMono {
		t.Fatal("unknown family must omit and inherit, not reset", ds)
	}
	doc, s, ds = compute(t, `<span id="target">text</span>`,
		`span{font-family:monospace;font-family:In/**/ter}`)
	if len(ds) != 1 || s.ForNode(find(doc, "target")).FontFamily != webstyle.FontMono {
		t.Fatal("comment-separated identifiers joined into a known font", ds)
	}
}

// TestFontFamilyListMapping pins M99p (#2193): generic and shipped names map
// to the family's registry role, an unshipped name warns and yields to the
// next list entry, and an unshipped generic degrades to sans with its own
// diagnostic.
func TestFontFamilyListMapping(t *testing.T) {
	for _, tc := range []struct {
		list string
		want webstyle.FontFamily
	}{
		{"serif", webstyle.FontSerif},
		{`"Noto Serif", serif`, webstyle.FontSerif},
		{"VirelaiMissing, serif", webstyle.FontSerif},
		{"VirelaiMissing, Inter", webstyle.FontSans},
		{"ui-monospace", webstyle.FontMono},
		{"system-ui", webstyle.FontSans},
		{"cursive", webstyle.FontSans},
		{"fantasy", webstyle.FontSans},
	} {
		doc, s, _ := compute(t, `<span id="target">text</span>`,
			`span{font-family:`+tc.list+`}`)
		if got := s.ForNode(find(doc, "target")).FontFamily; got != tc.want {
			t.Errorf("font-family:%s = %d, want %d", tc.list, got, tc.want)
		}
	}
	_, _, ds := compute(t, `<span id="target">text</span>`,
		`span{font-family:VirelaiMissing, serif}`)
	if len(ds) != 1 || ds[0].Text != "font-family-fallback VirelaiMissing" {
		t.Fatal("unshipped name must warn once and yield", ds)
	}
	_, _, ds = compute(t, `<span id="target">text</span>`, `span{font-family:cursive}`)
	if len(ds) != 1 || ds[0].Text != "font-family-generic cursive" ||
		ds[0].Kind != webstyle.DiagnosticUnsupported {
		t.Fatal("unshipped generic must warn as unsupported, not as missing", ds)
	}
}

func TestExcludedFunctionsNameUnsupportedOutcome(t *testing.T) {
	for _, source := range []string{"width:calc(100% - 1px)", "font-size:var(--size)", "flex-grow:calc(1 + 1)"} {
		p := newParser(source)
		if len(p.declarations(false)) != 0 || len(p.diags.list) != 1 ||
			p.diags.list[0].Kind != webstyle.DiagnosticUnsupported ||
			!strings.HasPrefix(p.diags.list[0].Text, "unsupported-value") {
			t.Fatal(source, p.diags.list)
		}
	}
}
