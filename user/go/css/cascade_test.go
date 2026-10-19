package css

import (
	"strings"
	"testing"
	"virelai/webrender"
	"virelai/webstyle"
)

func find(doc *webrender.Document, id string) *webrender.Node {
	var walk func(*webrender.Node) *webrender.Node
	walk = func(n *webrender.Node) *webrender.Node {
		if n.Attr("id") == id {
			return n
		}
		for _, c := range n.Children {
			if found := walk(c); found != nil {
				return found
			}
		}
		return nil
	}
	return walk(doc.Root)
}

func compute(t *testing.T, html string, sources ...string) (*webrender.Document, *Styles, []webstyle.Diagnostic) {
	t.Helper()
	doc := webrender.ParseHTML([]byte(html))
	var sheets []*Stylesheet
	for _, source := range sources {
		s, _ := Parse([]byte(source))
		sheets = append(sheets, s)
	}
	styles, diags := Cascade(doc, sheets)
	return doc, styles, diags
}

func TestCascadeSpecificityOrderInlineAndGroups(t *testing.T) {
	for _, tc := range []struct {
		name, source, inline string
		want                 uint32
	}{
		{"universal", "*{color:red}", "", 0xffff0000},
		{"class-over-type", ".x{color:red} span{color:blue}", "", 0xffff0000},
		{"id-over-classes", "#target{color:red} .x.x.x.x{color:blue}", "", 0xffff0000},
		{"repeated-class", ".x.x{color:red} .x{color:blue}", "", 0xffff0000},
		{"descendant", "main .x{color:red} .x{color:blue}", "", 0xffff0000},
		{"compound", "SPAN.x#target{color:red} span.x{color:blue}", "", 0xffff0000},
		{"source-order", ".x{color:red} .x{color:blue}", "", 0xff0000ff},
		{"declaration-order", ".x{color:red; color:blue}", "", 0xff0000ff},
		{"inline", "#target{color:red}", "color:blue", 0xff0000ff},
		{"author-important", "#target{color:red !IMPORTANT}", "color:blue", 0xffff0000},
		{"important-inline", "#target{color:red !important}", "color:blue !important", 0xff0000ff},
		{"group-specificity", "#target,span{color:red} .x{color:blue}", "", 0xffff0000},
		{"class-case", ".X{color:red} .x{color:blue}", "", 0xff0000ff},
		{"id-case", "#TARGET{color:red} .x{color:blue}", "", 0xff0000ff},
		{"escaped", `#t\61 rget.\78 {c\6f lor:r\65 d}`, "", 0xffff0000},
		{"ancestor-gaps", "main section span{color:red} section main span{color:blue}", "", 0xffff0000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			doc, s, ds := compute(t, `<main><section><div><span id="target" class="x xx" style="`+tc.inline+`">text</span></div></section></main>`, tc.source)
			if len(ds) != 0 || s.ForNode(find(doc, "target")).Color != rgba(tc.want) {
				t.Fatal(s.ForNode(find(doc, "target")).Color, ds)
			}
		})
	}
	doc, s, ds := compute(t, `<span id="target" class="xx">text</span>`, ".x{color:red}")
	if len(ds) != 0 || s.ForNode(find(doc, "target")).Color == rgba(0xffff0000) {
		t.Fatal("substring class matching")
	}
	doc, s, ds = compute(t, `<span id="target">text</span>`, "span{color:red}", "span{color:blue}")
	if len(ds) != 0 || s.ForNode(find(doc, "target")).Color != rgba(0xff0000ff) {
		t.Fatal("ordered sources", ds)
	}
}

func TestUAOriginTiersAndDefaults(t *testing.T) {
	if len(uaSheet.rules) > 128 || len(uaSheet.diags) != 0 {
		t.Fatal("UA bounds", len(uaSheet.rules), uaSheet.diags)
	}
	for _, tc := range []struct {
		ua, author, inline string
		want               uint32
	}{
		{"span{color:red}", "*{color:blue}", "", 0xff0000ff},
		{"span{color:red !important}", "#target{color:blue !important}", "color:green !important", 0xffff0000},
		{"span{color:red}", "*{color:blue !important}", "", 0xff0000ff},
	} {
		doc := webrender.ParseHTML([]byte(`<span id="target" style="` + tc.inline + `">text</span>`))
		ua, _ := Parse([]byte(tc.ua))
		author, _ := Parse([]byte(tc.author))
		s, ds := cascade(doc, []*Stylesheet{author}, ua, webstyle.InitialFontSize)
		if len(ds) != 0 || s.ForNode(find(doc, "target")).Color != rgba(tc.want) {
			t.Fatal("origin tiers", ds)
		}
	}
	doc, s, ds := compute(t, `<h1 id="h">Heading</h1><pre id="pre">Code</pre><noscript id="fallback">Visible</noscript><style id="metadata">Never paint</style>`)
	if len(ds) != 0 || s.ForNode(find(doc, "h")).FontSize != px(26) ||
		s.ForNode(find(doc, "h")).FontWeight != webstyle.WeightBold ||
		s.ForNode(find(doc, "pre")).WhiteSpace != webstyle.WhiteSpacePre ||
		s.ForNode(find(doc, "fallback")).Display == webstyle.DisplayNone ||
		s.ForNode(find(doc, "metadata")).Display != webstyle.DisplayNone {
		t.Fatal("UA defaults", ds)
	}
}

func TestInheritanceInitialAndCurrentColor(t *testing.T) {
	doc, s, ds := compute(t, `<main id="parent"><span id="child">text</span><span id="reset">text</span></main>`, `
	main { color:red; font-family:monospace; font-size:20px; font-weight:bold; font-style:italic;
		line-height:normal; text-align:right; white-space:pre-wrap;
		width:200px; margin:8px; padding:4px; border:2px solid blue; background-color:yellow; }
	#child { font-size:26px; background-color:currentColor; border:solid currentColor; }
	#reset { color:initial; font-family:initial; font-size:initial; font-weight:initial; font-style:initial;
		line-height:initial; text-align:initial; white-space:initial; }
	`)
	if len(ds) != 0 {
		t.Fatal(ds)
	}
	c := s.ForNode(find(doc, "child"))
	if c.Color != rgba(0xffff0000) || c.BackgroundColor != c.Color || c.Border.Top.Color != c.Color ||
		c.FontFamily != webstyle.FontMono || c.FontSize != px(26) || c.LineHeight != px(36) ||
		c.FontWeight != webstyle.WeightBold || c.FontStyle != webstyle.StyleItalic ||
		c.TextAlign != webstyle.AlignRight || c.WhiteSpace != webstyle.WhiteSpacePreWrap ||
		c.Width.Kind != webstyle.LengthInitial || c.Margin != (webstyle.Edges{}) || c.Padding != (webstyle.Edges{}) {
		t.Fatal("automatic inheritance", c)
	}
	r := s.ForNode(find(doc, "reset"))
	initial := initialStyle()
	for id := propertyID(0); id < propertyCount; id++ {
		if inherited(id) && valueOf(&r, id) != valueOf(&initial, id) {
			t.Fatal("initial", propertyNames[id], r)
		}
	}
	text := find(doc, "child").Children[0]
	if s.ForNode(text).Color != c.Color || s.ForNode(text).FontFamily != c.FontFamily ||
		s.ForNode(text).BackgroundColor != rgba(0) {
		t.Fatal("text-node inheritance")
	}
	doc, s, _ = compute(t, `<main><span id="target">text</span></main>`,
		`main{color:green;line-height:30px;font-size:20px}span{color:currentColor;font-size:40px}`)
	if s.ForNode(find(doc, "target")).Color != rgba(0xff008000) ||
		s.ForNode(find(doc, "target")).LineHeight != px(30) {
		t.Fatal("current foreground or inherited explicit line-height")
	}
	doc, s, _ = compute(t, `<span id="target">text</span>`, `span{color:red;border-color:initial}`)
	if s.ForNode(find(doc, "target")).Border.Top.Color != rgba(0xffff0000) {
		t.Fatal("border initial is current foreground")
	}
}

func TestInheritAndInitialEveryLonghand(t *testing.T) {
	// The same broad valid stylesheet gives every longhand a noninitial parent
	// value. Longhands are explicitly inherited, including normally private boxes.
	all := `
	display:flex;width:100px;height:20px;min-width:1px;max-width:150px;min-height:1px;max-height:40px;
	margin:1px 2px 3px 4px;padding:2px 3px 4px 5px;border:2px solid red;
	font-family:monospace;font-size:20px;font-weight:bold;font-style:italic;line-height:30px;
	color:blue;background-color:yellow;text-align:right;white-space:pre;
	flex-direction:column;flex-wrap:wrap;justify-content:center;align-items:center;
	flex-grow:2;flex-shrink:0;flex-basis:25%;row-gap:3px;column-gap:4px;
	`
	for _, name := range propertyNames {
		t.Run(name, func(t *testing.T) {
			doc, s, ds := compute(t, `<main id="p"><span id="c">text</span></main>`,
				"main{"+all+"}span{"+name+":inherit}")
			if len(ds) != 0 {
				t.Fatal(ds)
			}
			id := propertyID(0)
			for propertyNames[id] != name {
				id++
			}
			parent, child := s.ForNode(find(doc, "p")), s.ForNode(find(doc, "c"))
			if valueOf(&parent, id) != valueOf(&child, id) {
				t.Fatal("inherit", name, valueOf(&parent, id), valueOf(&child, id))
			}
			doc, s, ds = compute(t, `<span id="target">text</span>`, "span{"+all+name+":initial}")
			child = s.ForNode(find(doc, "target"))
			initial := initialStyle()
			expected := valueOf(&initial, id)
			if id >= pBorderTopWidth && id <= pBorderLeftColor && (id-pBorderTopWidth)%3 == 2 {
				expected.color = child.Color
			}
			if id == pLineHeight {
				expected.length = px((child.FontSize.Value*18 + 12) / 13)
			}
			if len(ds) != 0 || valueOf(&child, id) != expected {
				t.Fatal("initial", name, valueOf(&child, id), expected, ds)
			}
		})
	}
}

func TestUnsupportedSelectorsDiscardWholeGroupedRule(t *testing.T) {
	for _, sel := range []string{
		"main > span", "main + span", "main ~ span", "[id]", "span[id=x]", "ns|span",
		"span:hover", "span::before", ":root", "span:unknown(x)", "span, main > span",
	} {
		t.Run(sel, func(t *testing.T) {
			doc, s, ds := compute(t, `<main><span id="target">text</span></main>`, "span{color:green}"+sel+"{color:red;display:none}")
			if len(ds) != 1 || !strings.HasPrefix(ds[0].Text, "unsupported-selector") ||
				s.ForNode(find(doc, "target")).Color != rgba(0xff008000) ||
				s.ForNode(find(doc, "target")).Display == webstyle.DisplayNone {
				t.Fatal("excluded selector leaked", ds)
			}
		})
	}
}

func TestUnsupportedDiagnosticsOncePerConstruct(t *testing.T) {
	source := `span{float:right;position:absolute;grid-template-columns:1fr}
	span:hover{color:red}span::before{content:"x"}
	@media print{span{display:none}}@import "x";@font-face{font-family:X;src:url(x)}`
	sheet, parsed := Parse([]byte(source))
	if len(parsed) != 8 {
		t.Fatal("one per excluded construct", parsed)
	}
	doc := webrender.ParseHTML([]byte(`<span>text</span>`))
	_, page := Cascade(doc, []*Stylesheet{sheet})
	if len(page) != len(parsed) {
		t.Fatal("page diagnostics must not duplicate parse diagnostics", page)
	}
	for _, d := range page {
		if d.Kind != webstyle.DiagnosticUnsupported || d.Line == 0 || d.Col == 0 {
			t.Fatal(d)
		}
	}
}

// TestRelativeFontSizesResolveInTheCascade pins M99p (#2193): em resolves
// against the parent's computed size, rem against the root's computed size,
// smaller/larger step the absolute-size ladder, and a computed size outside
// 8..48 clamps with a diagnostic rather than refusing at parse — the value is
// unknowable until computed. The renderer only ever sees resolved px.
func TestRelativeFontSizesResolveInTheCascade(t *testing.T) {
	doc, s, ds := compute(t, `<main id="m"><p id="em">e</p><div id="nest"><p id="inner">i</p></div>`+
		`<p id="rem">r</p><p id="larger">l</p><p id="smaller">s</p><p id="clamp">c</p></main>`, `
	main { font-size:20px; }
	#em { font-size:2em; }
	#nest { font-size:1.5em; }
	#inner { font-size:2em; }
	#rem { font-size:1.5rem; }
	#larger { font-size:larger; }
	#smaller { font-size:smaller; }
	#clamp { font-size:10em; }
	`)
	sizes := map[string]int32{}
	for _, id := range []string{"m", "em", "nest", "inner", "rem", "larger", "smaller", "clamp"} {
		st := s.ForNode(find(doc, id))
		if st.FontSize.Kind != webstyle.LengthPx {
			t.Fatalf("%s font-size never resolved: %+v", id, st.FontSize)
		}
		sizes[id] = st.FontSize.Value
	}
	want := map[string]int32{
		"m": 20, "em": 40, "nest": 30, "inner": 48, // 60 clamps to the 48px ceiling
		"rem": 20, "larger": 26, "smaller": 16, "clamp": 48, // rem off the 13px root
	}
	for id, w := range want {
		if sizes[id] != w {
			t.Errorf("%s font-size=%d, want %d", id, sizes[id], w)
		}
	}
	// Exactly the two clamps report; every other resolution is silent.
	clamped := 0
	for _, d := range ds {
		if d.Text == "font-size-clamped" {
			clamped++
		}
	}
	if clamped != 2 || len(ds) != 2 {
		t.Fatalf("want exactly the two clamp diagnostics, got %+v", ds)
	}
	// Normal line height recomputes off the resolved size, not the literal.
	if got := s.ForNode(find(doc, "em")).LineHeight; got != px((40*18+12)/13) {
		t.Fatalf("em line height=%+v", got)
	}
}
