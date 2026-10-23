package webrender

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"os"
	"strings"
	"testing"
	"virelai/ttf"
	"virelai/webrender/qoi"
	"virelai/webstyle"
)

// maskFB represents the optional Surface capability without changing the
// legacy Fill-only framebuffer used by the existing approved goldens.
type maskFB struct{ *fb }

func TestCSSShortLineHeightDoesNotCullGlyphInk(t *testing.T) {
	fonts := loadFonts(t)
	for _, sink := range []bool{false, true} {
		f := newFB(200, 80, ColorPageBg)
		var surface Surface = f
		if sink {
			surface = &maskFB{f}
		}
		item := Item{Kind: ItemText, X: 4, Y: -8, W: 160, H: 1,
			Text: "MMMM", FontPx: 48, LineHeightPx: 1, Color: ColorText}
		Paint(&Layout{Text: fonts, Items: []Item{item}}, surface, 0, 0, 200, 80, 0)
		want := newFB(200, 80, ColorPageBg)
		var expected Surface = want
		if sink {
			expected = &maskFB{want}
		}
		fonts.Paint(expected, 4, -8, "MMMM", Style{FontPx: 48, LineHeightPx: 1}, ColorText, Clip{W: 200, H: 80})
		for i := range f.px {
			if f.px[i] != want.px[i] {
				t.Fatalf("mask capability=%v: ink outside the short line box was culled at pixel %d", sink, i)
			}
		}
	}
}

// Kept in the internal test package while image/reference integration tests
// use the external package, avoiding a renderer -> CSS import cycle.
func TestQOIHashStaysInTheIndexTable(t *testing.T) {
	for _, px := range []uint32{0xff117f33, 0xffd03399, 0xff2266dd, 0xffeecc00,
		0xffffffff, 0xff000000, 0xff7f7f7f, 0xff010203} {
		if h := qoi.Hash(px); h >= 64 {
			t.Errorf("qoi.Hash(%#08x) = %d, outside the 64-entry index table", px, h)
		}
	}
}

func (f *maskFB) BlitMask(x, y int, m *ttf.Mask, rgb uint32) {
	// The shared linear-light helper (M99o): every Go coverage blend routes
	// through ttf.Blend, test surfaces included.
	ttf.Blend(f.px, f.w, f.w, f.h, x, y, m, rgb)
}

func TestCSSFontSizes(t *testing.T) {
	f := loadFonts(t)
	for _, px := range []int{8, 13, 21, 48} {
		for _, flags := range []Style{{}, {Bold: true}, {Italic: true}, {Bold: true, Italic: true}, {Mono: true}} {
			st := flags
			st.FontPx = px
			face := f.face(st)
			if got, want := f.Measure("Mi W", st), face.Measure("Mi W", px); got != want {
				t.Errorf("%+v measure=%d, face=%d", st, got, want)
			}
			if got, want := f.Advance(st), face.AdvancePx('M', px); got != want {
				t.Errorf("%+v advance=%d, face=%d", st, got, want)
			}
			if got, want := f.LineHeight(st), (px*18+12)/13; got != want {
				t.Errorf("%+v line height=%d, want %d", st, got, want)
			}
			st.LineHeightPx = 7
			if f.LineHeight(st) != 7 || (Bitmap{}).LineHeight(st) != 7 {
				t.Fatal("declared line height ignored")
			}
		}
		t.Logf("CSS metrics verified at %d px for Inter, Bold, Italic, Bold+Italic and Fira Code", px)
	}
	if f.face(Style{Bold: true, Italic: true}) != f.BoldItalic {
		t.Fatal("the dedicated Bold-Italic face must win when it is loaded")
	}
	// And the card's degrade: a Fonts built without BI resolves {B,I} to
	// Bold, not to Regular.
	noBI := Fonts{UI: f.UI, Mono: f.Mono, Bold: f.Bold, Italic: f.Italic}
	if noBI.face(Style{Bold: true, Italic: true}) != noBI.Bold {
		t.Fatal("without a Bold-Italic face a {bold,italic} style must degrade to Bold")
	}
	// These are the existing guest metric markers, not CSS normal line height.
	if f.LineHeight(Style{Size: 1}) != 18 || f.LineHeight(Style{Size: 2}) != 33 ||
		f.LineHeight(Style{Size: 1, Mono: true}) != 17 ||
		f.Measure("i", Style{Size: 1}) != 3 || f.Measure("W", Style{Size: 1}) != 13 {
		t.Fatal("legacy typography marker changed")
	}
}

func TestOptionalMaskSinkClipsToPage(t *testing.T) {
	const bg = 0x123456
	for _, sink := range []Surface{newFB(16, 16, bg), &maskFB{newFB(16, 16, bg)}} {
		c := Clip{X: 4, Y: 4, W: 3, H: 3}
		m := &ttf.Mask{Width: 5, Height: 5, Alpha: bytes.Repeat([]byte{127}, 25)}
		blitMask(sink, c, 2, 2, m, 0xffffff)
		var pixels *fb
		if f, ok := sink.(*fb); ok {
			pixels = f
		} else {
			pixels = sink.(*maskFB).fb
		}
		for y := 0; y < 16; y++ {
			for x := 0; x < 16; x++ {
				changed := pixels.at(x, y) != bg
				if changed != c.Contains(x, y) {
					t.Fatalf("%T: changed=%v at (%d,%d), clip=%+v", sink, changed, x, y, c)
				}
			}
		}
	}
}

func TestCSSLayoutAndPaintUseSameSize(t *testing.T) {
	fonts := loadFonts(t)
	for _, px := range []int{8, 19, 48} {
		doc := ParseHTML([]byte("<p>MMMM</p>"))
		tree, _ := BuildBoxTree(doc, func(*Node) webstyle.ComputedStyle {
			return webstyle.ComputedStyle{Display: webstyle.DisplayBlock,
				FontSize: webstyle.Length{Kind: webstyle.LengthPx, Value: int32(px)}}
		})
		l, ds := LayoutBoxes(tree, webstyle.Viewport{Width: 300, Height: 100}, fonts)
		if len(ds) != 0 {
			t.Fatal(ds)
		}
		got := newFB(300, 100, ColorPageBg)
		Paint(l, got, 0, 0, 300, 100, 0)
		want := newFB(300, 100, ColorPageBg)
		for _, it := range l.Items {
			if it.Kind == ItemText {
				st := Style{FontPx: px, LineHeightPx: (px*18 + 12) / 13}
				if it.W != fonts.Measure(it.Text, st) {
					t.Fatal("CSS layout measurement disagrees with font")
				}
				fonts.Paint(want, it.X, it.Y, it.Text, st, it.Color, Clip{W: 300, H: 100})
			}
		}
		for i := range got.px {
			if got.px[i] != want.px[i] {
				t.Fatalf("CSS %d px paint mismatch at pixel %d", px, i)
			}
		}
	}
}

// The faces the desktop loads. All are committed fixtures; a missing one
// fails the test rather than skipping it.
const (
	interFixture       = "../../../image/fonts/Inter-Regular.ttf"
	interBoldFixture   = "../../../image/fonts/Inter-Bold.ttf"
	interItalicFixture = "../../../image/fonts/Inter-Italic.ttf"
	interBIFixture     = "../../../image/fonts/Inter-BoldItalic.ttf"
	firaFixture        = "../../../image/fonts/FiraCode-Regular.ttf"
	serifFixture       = "../../../image/fonts/NotoSerif-Regular.ttf"
)

func loadFonts(t *testing.T) Fonts {
	t.Helper()
	ui, err := os.ReadFile(interFixture)
	if err != nil {
		t.Fatalf("Inter fixture is required by these tests: %v", err)
	}
	bold, err := os.ReadFile(interBoldFixture)
	if err != nil {
		t.Fatalf("Inter Bold fixture is required by these tests: %v", err)
	}
	italic, err := os.ReadFile(interItalicFixture)
	if err != nil {
		t.Fatalf("Inter Italic fixture is required by these tests: %v", err)
	}
	boldItalic, err := os.ReadFile(interBIFixture)
	if err != nil {
		t.Fatalf("Inter Bold Italic fixture is required by these tests: %v", err)
	}
	mono, err := os.ReadFile(firaFixture)
	if err != nil {
		t.Fatalf("Fira Code fixture is required by these tests: %v", err)
	}
	serif, err := os.ReadFile(serifFixture)
	if err != nil {
		t.Fatalf("Noto Serif fixture is required by these tests: %v", err)
	}
	f := LoadFonts(FontFiles{UI: ui, Mono: mono, Serif: serif, Bold: bold, Italic: italic, BoldItalic: boldItalic})
	if f.UI == nil {
		t.Fatal("LoadFonts dropped the Inter face")
	}
	if f.Mono == nil {
		t.Fatal("LoadFonts dropped the Fira Code face")
	}
	if f.Bold == nil {
		t.Fatal("LoadFonts dropped the Inter Bold face")
	}
	if f.Italic == nil {
		t.Fatal("LoadFonts dropped the Inter Italic face")
	}
	if f.BoldItalic == nil {
		t.Fatal("LoadFonts dropped the Inter Bold Italic face")
	}
	if f.Serif == nil {
		t.Fatal("LoadFonts dropped the Noto Serif face")
	}
	return f
}

// inkExtent is the horizontal span of painted (non-background) pixels.
func inkExtent(f *fb, w, h int, bg uint32) (int, int, int) {
	minX, maxX, n := -1, -1, 0
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if f.at(x, y) != bg {
				n++
				if minX < 0 {
					minX = x
				}
				maxX = x
			}
		}
	}
	return minX, maxX, n
}

func renderText(t *testing.T, engine TextEngine, markup string, w, h int) (*fb, *Layout) {
	t.Helper()
	doc := ParseHTML([]byte(markup))
	lay := LayoutDocument(doc, w, engine)
	f := newFB(w, h, ColorPageBg)
	Paint(lay, f, 0, 0, w, h, 0)
	return f, lay
}

// TestEngineNameAndProportionality pins the two engines' identities.
func TestEngineNameAndProportionality(t *testing.T) {
	f := loadFonts(t)
	if !f.Proportional() {
		t.Error("Fonts with Inter loaded must report Proportional")
	}
	if f.Name() != "truetype(inter+firacode)" {
		t.Errorf("Fonts.Name() = %q", f.Name())
	}
	if b := (Bitmap{}); b.Proportional() || b.Name() != "bitmap8x8" {
		t.Errorf("Bitmap must report itself as the non-proportional 8x8 fallback (got %q)", b.Name())
	}
	st := Style{Size: 1, Color: ColorText}
	iii, www := f.Measure("iii", st), f.Measure("WWW", st)
	t.Logf("Inter @size 1: Measure(iii)=%d Measure(WWW)=%d", iii, www)
	if www <= iii*2 {
		t.Errorf("Inter measure is not proportional: iii=%d WWW=%d", iii, www)
	}
	if bi, bw := (Bitmap{}).Measure("iii", st), (Bitmap{}).Measure("WWW", st); bi != bw {
		t.Errorf("the bitmap fallback must be monospace: iii=%d WWW=%d", bi, bw)
	}
}

// TestProportionalAdvancesAreVisibleInPixels is the rendering-level version of
// the same fact, and the host-side stand-in for the class-B gate's pixel probe:
// with a proportional face, "WWW" paints a visibly wider band than "iii"; on the
// 8x8 lattice the two are exactly the same width.
func TestProportionalAdvancesAreVisibleInPixels(t *testing.T) {
	fonts := loadFonts(t)
	bitmap := Bitmap{}
	for _, tc := range []struct {
		name   string
		engine TextEngine
	}{{"truetype", fonts}, {"bitmap", bitmap}} {
		fi, li := renderText(t, tc.engine, "<p>iii</p>", 240, 40)
		fw, lw := renderText(t, tc.engine, "<p>WWW</p>", 240, 40)
		mini, maxi, ni := inkExtent(fi, 240, 40, ColorPageBg)
		minw, maxw, nw := inkExtent(fw, 240, 40, ColorPageBg)
		advI, advW := textRunWidth(li), textRunWidth(lw)
		inkI, inkW := maxi-mini+1, maxw-minw+1
		t.Logf("%s: iii advance=%d ink-span=%d (%d px), WWW advance=%d ink-span=%d (%d px)",
			tc.name, advI, inkI, ni, advW, inkW, nw)
		if ni == 0 || nw == 0 {
			t.Fatalf("%s painted nothing", tc.name)
		}
		switch tc.name {
		case "truetype":
			if advW <= advI*3/2 {
				t.Errorf("TrueType 'WWW' advance %d is not clearly wider than 'iii' advance %d", advW, advI)
			}
			if inkW <= inkI {
				t.Errorf("TrueType 'WWW' ink span %d must exceed 'iii' ink span %d", inkW, inkI)
			}
		case "bitmap":
			if advW != advI {
				t.Errorf("the 8x8 fallback must advance 'WWW' and 'iii' identically: %d vs %d", advW, advI)
			}
		}
	}
}

// textRunWidth is the advance the layout assigned to a page's text items.
func textRunWidth(l *Layout) int {
	n := 0
	for _, it := range l.Items {
		if it.Kind == ItemText {
			n += it.W
		}
	}
	return n
}

// TestWrapAtKnownWidths derives the expected line count from the engine's own
// metrics and requires the layout to match. A wrapping bug is otherwise only
// visible as slightly-wrong line breaks in a golden nobody looks at twice.
func TestWrapAtKnownWidths(t *testing.T) {
	fonts := loadFonts(t)
	st := Style{Size: 1, Color: ColorText}
	word := fonts.Measure("M", st)
	space := fonts.Measure("M M", st) - word*2
	if word <= 0 || space <= 0 {
		t.Fatalf("implausible metrics: word=%d space=%d", word, space)
	}
	for _, width := range []int{160, 240, 320, 420} {
		perLine := (width - word) / (word + space)
		if perLine < 1 {
			perLine = 1
		}
		for _, n := range []int{3, 7, 12} {
			text := strings.TrimSuffix(strings.Repeat("M ", n), " ")
			doc := ParseHTML([]byte("<p>" + text + "</p>"))
			lay := LayoutDocument(doc, width, fonts)
			lines := map[int]bool{}
			for _, it := range lay.Items {
				if it.Kind == ItemText {
					lines[it.Y] = true
				}
			}
			want := (n + perLine - 1) / perLine
			t.Logf("width=%d words=%d word=%d space=%d perLine=%d -> lines=%d (want %d)",
				width, n, word, space, perLine, len(lines), want)
			if len(lines) != want {
				t.Errorf("width=%d words=%d: %d lines, want %d (perLine=%d)",
					width, n, len(lines), want, perLine)
			}
		}
	}
}

// TestTTFLineHeightExceedsBitmap: a 13px Inter line box is taller than the 8px
// bitmap's — the h1 band of a page renders at a different rhythm once the face
// is real, which is what the gate's band probe keys on.
func TestTTFLineHeightExceedsBitmap(t *testing.T) {
	fonts := loadFonts(t)
	for _, st := range []Style{{Size: 1}, {Size: 2}, {Size: 1, Mono: true}} {
		tl, bl := fonts.LineHeight(st), (Bitmap{}).LineHeight(st)
		t.Logf("style %+v: truetype=%d bitmap=%d", st, tl, bl)
		if tl <= bl {
			t.Errorf("style %+v: TrueType line height %d must exceed the bitmap's %d", st, tl, bl)
		}
	}
}

// TestFallbackNeverPaintsNothing is the hard rule: whatever is missing, the
// page still renders something. A blank viewport is the one outcome the
// renderer is not allowed to produce.
func TestFallbackNeverPaintsNothing(t *testing.T) {
	const markup = "<h1>Fallback</h1><p>No font was loaded, and the page still renders.</p>"
	engines := []TextEngine{
		Bitmap{},           // explicit fallback
		Fonts{},            // no faces loaded at all
		Fonts{UI: nil},     // UI face missing
		NewFonts(nil, nil), // constructor with no bytes
		NewFonts([]byte("not a font at all"), nil), // a rejected font
	}
	for _, e := range engines {
		f, _ := renderText(t, e, markup, 260, 120)
		_, _, ink := inkExtent(f, 260, 120, ColorPageBg)
		t.Logf("%s: %d ink px", e.Name(), ink)
		if ink < 100 {
			t.Errorf("%s painted only %d px; a missing face must degrade typography, not blank the page",
				e.Name(), ink)
		}
	}
}

// TestRejectedFontFallsBackButReports: a corrupt face is dropped, and the
// engine says so through Name() so the app can put it on the wire.
func TestRejectedFontFallsBackButReports(t *testing.T) {
	junk := make([]byte, 4096)
	copy(junk, "not-a-font")
	f := NewFonts(junk, junk)
	if f.UI != nil || f.Mono != nil {
		t.Fatal("a corrupt font must not produce a face")
	}
	if f.Loaded() {
		t.Error("Loaded() must be false when no face parsed")
	}
	if f.Name() != "bitmap8x8" {
		t.Errorf("a fontless engine must report bitmap8x8, got %q", f.Name())
	}
}

// TestMonoStylePrefersTheMonoFace: a monospace style takes Fira Code when it is
// loaded, and the UI face otherwise; either way it is never blank.
func TestMonoStylePrefersTheMonoFace(t *testing.T) {
	fonts := loadFonts(t)
	mono := Style{Size: 1, Mono: true}
	if a, b := fonts.Measure("iiii", mono), fonts.Measure("WWWW", mono); a != b {
		t.Errorf("mono style must be monospace: iiii=%d WWWW=%d", a, b)
	}
	onlyMono := Fonts{Mono: fonts.Mono}
	if onlyMono.Measure("x", Style{Size: 1}) != (Bitmap{}).Measure("x", Style{Size: 1}) {
		t.Error("with no UI face a proportional style must fall back to the bitmap metric")
	}
	prose := fonts.Measure("iiii", Style{Size: 1})
	if prose == fonts.Measure("WWWW", Style{Size: 1}) {
		t.Error("a proportional style must not report a fixed advance")
	}
}

// TestSerifStyleResolvesTheSerifFace pins M99p (#2193): a serif style selects
// the serif family — through both the file list and the manifest registry —
// and a styled serif run keeps that face (refusal by name): a bold serif run
// resolves to "serif" with NO synthetic strike — the manifest's documented
// policy is real glyphs at real coverage, never a fake embolden.
func TestSerifStyleResolvesTheSerifFace(t *testing.T) {
	serifSt := Style{Size: 1, Serif: true}
	boldSerif := Style{Size: 1, Serif: true, Bold: true}
	for name, f := range map[string]Fonts{"files": loadFonts(t)} {
		if got := f.ResolvedName(serifSt); got != "serif" {
			t.Fatalf("%s: serif style resolved to %q", name, got)
		}
		if got := f.ResolvedName(boldSerif); got != "serif" {
			t.Fatalf("%s: bold serif must keep the serif face, got %q", name, got)
		}
		if f.noRealBold(boldSerif) {
			t.Fatalf("%s: refusal-by-name means no strike on serif", name)
		}
	}
	f, _ := manifestFonts(t)
	if got := f.ResolvedName(serifSt); got != "serif" {
		t.Fatalf("registry: serif style resolved to %q", got)
	}
	if got := f.ResolvedName(boldSerif); got != "serif" {
		t.Fatalf("registry: bold serif must degrade to the serif primary, got %q", got)
	}
	if f.face(serifSt) != f.Serif {
		t.Fatal("registry: face() and Serif disagree")
	}
}

// TestHostileHTMLStillRenders: malformed and adversarial markup must still
// paint real ink with the real face, and must not panic. Unknown tags flatten
// to their text (ADR 0028 D5) and truncation stays visible (D6).
func TestHostileHTMLStillRenders(t *testing.T) {
	fonts := loadFonts(t)
	cases := []struct {
		name   string
		markup string
	}{
		{"unclosed everything", "<div><p>text<h1>heading<span>inline"},
		{"unknown tags", "<foo><bar>alpha</bar><baz>beta</baz></foo>"},
		{"script and style are skipped", "<script>alert(1)</script><style>p{}</style><p>visible</p>"},
		{"deep nesting", strings.Repeat("<div>", 300) + "deep" + strings.Repeat("</div>", 300)},
		{"a megabyte of text", "<p>" + strings.Repeat("word ", 20000) + "</p>"},
		{"nul and control bytes", "<p>a\x00b\x01c\x7f</p>"},
		{"broken entity soup", "<p>&amp;&#xZZ;&notanentity;&#999999999;</p>"},
		{"table with no rows", "<table></table>"},
		{"table with ragged rows", "<table><tr><th>A</th><th>B</th></tr><tr><td>only one</td></tr></table>"},
		{"img with no src", `<img alt="a box">`},
		{"img with an unresolvable src", `<img src="/host/NOPE.PNG" alt="missing">`},
		{"links with no href", "<p><a>bare anchor</a> and <a href=\"\">empty</a></p>"},
		{"only whitespace", "   \n\t  "},
		{"empty document", ""},
	}
	always := ImageResolver(func(string) ([]byte, bool) { return nil, false })
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("PANIC rendering hostile markup: %v", r)
				}
			}()
			doc := ParseHTML([]byte(tc.markup))
			lay := LayoutDocument(doc, 320, fonts, always)
			f := newFB(320, 200, ColorPageBg)
			Paint(lay, f, 0, 0, 320, 200, 0)
			_, _, ink := inkExtent(f, 320, 200, ColorPageBg)
			t.Logf("%s: nodes=%d items=%d lines=%d truncated=%v ink=%d",
				tc.name, doc.Nodes, len(lay.Items), lay.Lines, lay.Truncated, ink)
			// Whitespace-only markup legitimately paints nothing; anything
			// with real text must leave ink.
			if txt := strings.TrimSpace(TextContent(doc.Root)); txt != "" && ink == 0 {
				t.Errorf("markup with %d runes of text (%q) painted nothing", len([]rune(txt)), txt)
			}
		})
	}
}

// TestResolvedImagePaintsPixels: an <img> whose bytes the resolver can supply
// paints decoded pixels, and its box takes the image's own geometry.
func TestResolvedImagePaintsPixels(t *testing.T) {
	fonts := loadFonts(t)
	png := pngFixture(t)
	res := ImageResolver(func(src string) ([]byte, bool) {
		if src == "shot.png" {
			return png, true
		}
		return nil, false
	})
	doc := ParseHTML([]byte(`<img src="shot.png" alt="shot">`))
	lay := LayoutDocument(doc, 200, fonts, res)
	if len(lay.Items) != 1 || lay.Items[0].Img == nil {
		t.Fatalf("expected one decoded image item, got %d items", len(lay.Items))
	}
	it := lay.Items[0]
	t.Logf("decoded image: %dx%d painted into a %dx%d box", it.Img.Width, it.Img.Height, it.W, it.H)
	if it.W != it.Img.Width || it.H != it.Img.Height {
		t.Errorf("image box %dx%d must match the decoded %dx%d", it.W, it.H, it.Img.Width, it.Img.Height)
	}
	f := newFB(200, 120, ColorPageBg)
	Paint(lay, f, 0, 0, 200, 120, 0)
	_, _, ink := inkExtent(f, 200, 120, ColorPageBg)
	t.Logf("image ink: %d px (expected %d)", ink, it.W*it.H)
	if ink != it.W*it.H {
		t.Errorf("the decoded image painted %d px, want every one of its %d pixels", ink, it.W*it.H)
	}
	// Without a resolver the same img is still a visible labeled box.
	lay2 := LayoutDocument(doc, 200, fonts)
	if len(lay2.Items) != 1 || lay2.Items[0].Img != nil {
		t.Fatal("without a resolver the img must be an undecoded placeholder")
	}
	f2 := newFB(200, 120, ColorPageBg)
	Paint(lay2, f2, 0, 0, 200, 120, 0)
	if _, _, ink := inkExtent(f2, 200, 120, ColorPageBg); ink < 100 {
		t.Errorf("the placeholder box painted only %d px", ink)
	}
}

// TestDecodeImageRejectsJunk: a bad image is an error, never a panic or an
// unallocatable raster.
func TestDecodeImageRejectsJunk(t *testing.T) {
	cases := [][]byte{
		nil,
		[]byte("qoif"),
		[]byte("qoif\x00\x00\x00\x02\x00\x00\x00\x02\x04\x00"),
		[]byte("\x89PNG\r\n\x1a\ntruncated"),
		[]byte("GIF89a not a png"),
	}
	for i, c := range cases {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("case %d panicked: %v", i, r)
				}
			}()
			if img, err := DecodeImage(c); err == nil && img != nil {
				t.Errorf("case %d decoded to %dx%d, want an error", i, img.Width, img.Height)
			}
		}()
	}
	// A QOI header announcing an enormous image must be refused, not allocated.
	huge := append([]byte("qoif"), 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x40, 0x00, 4, 0)
	if img, err := DecodeImage(huge); err == nil {
		t.Errorf("a 16384x16384 qoi decoded to %dx%d", img.Width, img.Height)
	}
}

// TestEngineSurvivesASurfaceWithNoMaskSink: the plain rect-only Surface must
// still show the text (the thresholded-span path), which is what the guest uses
// until its window has a direct back-buffer.
func TestEngineSurvivesASurfaceWithNoMaskSink(t *testing.T) {
	fonts := loadFonts(t)
	doc := ParseHTML([]byte("<h1>Plain fill</h1><p>rect-only surface</p>"))
	lay := LayoutDocument(doc, 260, fonts)
	f := newFB(260, 120, ColorPageBg)
	// Wrap it in a Surface that hides BlitMask, forcing the span fallback.
	var plain Surface = plainSurface{f}
	Paint(lay, plain, 0, 0, 260, 120, 0)
	_, _, ink := inkExtent(f, 260, 120, ColorPageBg)
	t.Logf("rect-only surface: %d ink px", ink)
	if ink < 100 {
		t.Errorf("the span fallback painted only %d px", ink)
	}
}

// plainSurface implements Surface but deliberately not MaskSink.
type plainSurface struct{ f *fb }

func (p plainSurface) Fill(x, y, w, h int, rgb uint32) {
	for yy := y; yy < y+h; yy++ {
		for xx := x; xx < x+w; xx++ {
			if xx >= 0 && yy >= 0 && xx < p.f.w && yy < p.f.h {
				p.f.px[yy*p.f.w+xx] = rgb & 0x00ffffff
			}
		}
	}
}

// pngFixture builds a small PNG in memory so the image path is exercised
// without adding a binary fixture. 8x4, four quadrants of distinct colour.
func pngFixture(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 8, 4))
	cols := []color.RGBA{
		{0xff, 0x00, 0x00, 0xff}, {0x00, 0xff, 0x00, 0xff},
		{0x00, 0x00, 0xff, 0xff}, {0xff, 0xff, 0x00, 0xff},
	}
	for y := 0; y < 4; y++ {
		for x := 0; x < 8; x++ {
			img.Set(x, y, cols[(y/2)*2+(x/4)])
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode fixture: %v", err)
	}
	return buf.Bytes()
}

// TestGoldenOlivierFixtureWithTrueType pins the whole pipeline — parse, style,
// layout, coverage-AA paint — against the fixture this project already uses to
// prove its in-guest HTML path (tests/oliver-spike/expect.html, the pinned
// oliver output). It is the host-side twin of the class-B screenshot: the page
// the goal asks for must render, in Inter, with real ink.
func TestGoldenOlivierFixtureWithTrueType(t *testing.T) {
	fonts := loadFonts(t)
	html, err := os.ReadFile("../../../tests/oliver-spike/expect.html")
	if err != nil {
		t.Fatalf("oliver fixture is required: %v", err)
	}
	doc := ParseHTML(html)
	const w, h = 470, 320
	lay := LayoutDocument(doc, w, fonts)
	f := newFB(w, h, ColorPageBg)
	Paint(lay, f, 0, 0, w, h, 0)
	ink := f.count(func(v uint32) bool { return v != ColorPageBg })
	t.Logf("oliver fixture with Inter: nodes=%d items=%d lines=%d blocks=%d ink=%d",
		doc.Nodes, len(lay.Items), lay.Lines, lay.Blocks, ink)
	if ink < 800 {
		t.Fatalf("the oliver fixture rendered only %d px of ink", ink)
	}
	// The same page through the bitmap engine, for the comparison the goal is
	// actually about: the two must differ, or the face is not being used.
	layerB := LayoutDocument(doc, w, Bitmap{})
	fbB := newFB(w, h, ColorPageBg)
	Paint(layerB, fbB, 0, 0, w, h, 0)
	diff := 0
	for i := range f.px {
		if f.px[i] != fbB.px[i] {
			diff++
		}
	}
	t.Logf("TrueType vs bitmap on the same fixture: %d of %d px differ", diff, len(f.px))
	if diff == 0 {
		t.Fatal("the TrueType render is pixel-identical to the bitmap fallback: no face was used")
	}
	checkGolden(t, "oliver-truetype", f)
}

func loadRegularOnly(t *testing.T) Fonts {
	t.Helper()
	ui, err := os.ReadFile(interFixture)
	if err != nil {
		t.Fatalf("Inter fixture: %v", err)
	}
	f := NewFonts(ui, nil)
	if f.UI == nil || f.Bold != nil {
		t.Fatal("Regular-only fixture must parse UI and leave Bold absent")
	}
	return f
}

// TestBoldFaceIsNotSyntheticStrike is the host twin of the class-B strong
// probe. Inter matches advances across weights, so Measure cannot tell Bold
// from Regular; the stems can, and a Regular+1px strike cannot reproduce them.
func TestBoldFaceIsNotSyntheticStrike(t *testing.T) {
	fonts := loadFonts(t)
	only := loadRegularOnly(t)
	reg := Style{Size: 1, Color: ColorText}
	bold := Style{Size: 1, Bold: true, Color: ColorText}
	regW := fonts.Measure("MMMMMMMM", reg)
	boldW := fonts.Measure("MMMMMMMM", bold)
	synthW := only.Measure("MMMMMMMM", bold)
	t.Logf("Measure M×8: regular=%d bold-face=%d synthetic-style=%d (Inter keeps advances matched)", regW, boldW, synthW)
	if synthW != only.Measure("MMMMMMMM", reg) {
		t.Fatal("synthetic bold must not change Measure (it is a paint-only +1px strike)")
	}
	if !fonts.BoldHeavier() {
		t.Fatal("Inter Bold 'n' coverage must exceed Regular; otherwise the face is not Bold")
	}

	const w, h = 240, 40
	realBold, _ := renderText(t, fonts, "<p><strong>MMMMMMMM</strong></p>", w, h)
	regular, _ := renderText(t, fonts, "<p>MMMMMMMM</p>", w, h)
	synth, _ := renderText(t, only, "<p><strong>MMMMMMMM</strong></p>", w, h)
	rmin, rmax, rink := inkExtent(regular, w, h, ColorPageBg)
	bmin, bmax, bink := inkExtent(realBold, w, h, ColorPageBg)
	_, _, synthInk := inkExtent(synth, w, h, ColorPageBg)
	rspan, bspan := rmax-rmin+1, bmax-bmin+1
	diffSynth, diffReg := 0, 0
	for i := range realBold.px {
		if realBold.px[i] != synth.px[i] {
			diffSynth++
		}
		if realBold.px[i] != regular.px[i] {
			diffReg++
		}
	}
	t.Logf("M×8: regular span=%d ink=%d; bold span=%d ink=%d; synthetic ink=%d; diff vs synth=%d vs regular=%d",
		rspan, rink, bspan, bink, synthInk, diffSynth, diffReg)
	if diffSynth == 0 {
		t.Fatal("real Inter Bold painted identically to Regular+1px synthetic strike")
	}
	if diffReg == 0 {
		t.Fatal("real Inter Bold painted identically to Regular: the Bold face was not used")
	}
	if bspan-rspan == 1 {
		t.Fatal("Bold span is exactly Regular+1px: that is the synthetic strike, not a real face")
	}
	if bink <= rink {
		t.Errorf("Bold ink %d is not heavier than Regular %d", bink, rink)
	}
}

// TestItalicFaceIsSelectedForEmphasis: <em> with a loaded Italic face must
// not be Regular-in-accent-color. Same accent colour, Italic true vs false,
// the glyphs themselves differ.
func TestItalicFaceIsSelectedForEmphasis(t *testing.T) {
	fonts := loadFonts(t)
	stReg := Style{Size: 1, Color: ColorAccent}
	stEm := Style{Size: 1, Italic: true, Color: ColorAccent}
	if fonts.face(stEm) != fonts.Italic {
		t.Fatal("an italic style must select the Italic face when it is loaded")
	}
	const w, h, text = 200, 32, "emphasis"
	reg := newFB(w, h, ColorPageBg)
	em := newFB(w, h, ColorPageBg)
	clip := Clip{X: 0, Y: 0, W: w, H: h}
	fonts.Paint(reg, 4, 4, text, stReg, ColorAccent, clip)
	fonts.Paint(em, 4, 4, text, stEm, ColorAccent, clip)
	diff := 0
	for i := range reg.px {
		if reg.px[i] != em.px[i] {
			diff++
		}
	}
	t.Logf("italic vs regular (same accent colour): %d px differ", diff)
	if diff == 0 {
		t.Fatal("<em> painted Regular glyphs; the Italic face was not used")
	}
}

// TestH1BandWithBoldFace logs the host-side h1 band so the class-B probe can
// be re-pinned if Inter Bold changes the oliver heading's width.
func TestH1BandWithBoldFace(t *testing.T) {
	fonts := loadFonts(t)
	f, _ := renderText(t, fonts, "<h1>VirelaiOS wasm channel</h1>", 496, 80)
	minx, maxx, ink := inkExtent(f, 496, 80, ColorPageBg)
	span := 0
	if minx >= 0 {
		span = maxx - minx + 1
	}
	rows := 0
	in := false
	for y := 0; y < 80; y++ {
		on := false
		for x := 0; x < 496; x++ {
			if f.at(x, y) != ColorPageBg {
				on = true
				break
			}
		}
		if on {
			if !in {
				rows++
				in = true
			}
		} else {
			in = false
		}
	}
	// Count contiguous first band height.
	first, last := -1, -1
	for y := 0; y < 80; y++ {
		on := false
		for x := 0; x < 496; x++ {
			if f.at(x, y) != ColorPageBg {
				on = true
				break
			}
		}
		if on {
			if first < 0 {
				first = y
			}
			last = y
		} else if first >= 0 {
			break
		}
	}
	bandH := 0
	if first >= 0 {
		bandH = last - first + 1
	}
	t.Logf("h1 'VirelaiOS wasm channel': span=%d bandH=%d ink=%d (gate 01 previously Regular+1px span=294 height=20)", span, bandH, ink)
	if span < 200 || span > 400 {
		t.Errorf("implausible h1 span %d", span)
	}
	if bandH < 14 {
		t.Errorf("h1 band height %d is too short", bandH)
	}
}

// ——— M99l registry/fallback-chain tests (#2189) ———

const chromeFixture = "../../../image/fonts/VirelaiChrome-Regular.ttf"

// manifestFonts builds the engine over the shipped manifest shape: the four
// UI/mono primaries plus the chrome face as the symbol tail. reads records
// every file the registry asked for — the lazy-load witness.
func manifestFonts(t *testing.T) (Fonts, *[]string) {
	t.Helper()
	paths := map[string]string{
		"INTER.TTF":    interFixture,
		"INTERB.TTF":   interBoldFixture,
		"INTERI.TTF":   interItalicFixture,
		"INTERBI.TTF":  interBIFixture,
		"FIRACODE.TTF": firaFixture,
		"NOTOSERF.TTF": serifFixture,
		"CHROME.TTF":   chromeFixture,
	}
	specs, err := ttf.ParseManifest([]byte(
		"INTER.TTF | role=ui | order=1\n" +
			"INTERB.TTF | role=ui | order=2 | weight=700\n" +
			"INTERI.TTF | role=ui | order=3 | style=italic\n" +
			"INTERBI.TTF | role=ui | order=4 | weight=700 | style=italic\n" +
			"FIRACODE.TTF | role=mono | order=1\n" +
			"NOTOSERF.TTF | role=serif | order=1\n" +
			"CHROME.TTF | role=symbol | order=1\n"))
	if err != nil {
		t.Fatalf("manifest refused: %v", err)
	}
	var reads []string
	reg := ttf.NewRegistry(specs, func(file string) (*ttf.Face, error) {
		reads = append(reads, file)
		data, err := os.ReadFile(paths[file])
		if err != nil {
			return nil, err
		}
		return ttf.Parse(data)
	})
	f := RegistryFonts(reg)
	if f.UI == nil || f.Mono == nil || f.Serif == nil || f.Bold == nil || f.Italic == nil || f.BoldItalic == nil {
		t.Fatalf("the manifest engine must resolve all six primaries: %+v", f)
	}
	return f, &reads
}

// symbolOnlyRune finds a rune the symbol face covers that the UI-role faces
// lack — diffed from the cmaps, never hard-coded. Mono faces are NOT
// excluded: the ui cascade never consults them, so a rune Fira Code covers
// is still a ui miss.
func symbolOnlyRune(t *testing.T, f Fonts) rune {
	t.Helper()
	excl := []*ttf.Face{f.UI, f.Bold, f.Italic, f.BoldItalic}
	for cp := rune(0x20); cp <= 0x2FFFF; cp++ {
		if glyphOf(f.Reg, cp) == 0 {
			continue
		}
		only := true
		for _, face := range excl {
			if face != nil && face.GlyphIndex(cp) != 0 {
				only = false
				break
			}
		}
		if only {
			return cp
		}
	}
	t.Fatal("no rune covered only by the symbol face within the ui cascade")
	return 0
}

// glyphOf reports the symbol face's gid for a rune (0 = uncovered).
func glyphOf(reg *ttf.Registry, cp rune) uint16 {
	for _, s := range reg.Specs() {
		if s.Role != "symbol" {
			continue
		}
		if face := reg.Primary(ttf.Query{Role: "symbol"}); face != nil {
			return face.GlyphIndex(cp)
		}
	}
	return 0
}

// TestRegistryCascadePaintsTheSecondFace is the card's core assertion at the
// engine level: a rune only the symbol face covers must paint THAT face's
// glyph — pixel-identical to blitting the symbol face's own mask — not the
// primary's .notdef.
func TestRegistryCascadePaintsTheSecondFace(t *testing.T) {
	f, reads := manifestFonts(t)
	st := Style{Size: 1}
	// Primaries load eagerly (ui, bold, italic, mono — the same four files
	// the hard-coded path always read); the symbol face must NOT have been
	// touched yet.
	for _, r := range *reads {
		if r == "CHROME.TTF" {
			t.Fatalf("the symbol face loaded before any miss: %v", *reads)
		}
	}
	r := symbolOnlyRune(t, f)
	symbol := f.Reg.Primary(ttf.Query{Role: "symbol"})
	if symbol == nil {
		t.Fatal("no symbol face resolved")
	}
	text := "A" + string(r) + "A"
	// Measure must be the per-face sum — agreement the comparator pins.
	want := f.UI.Measure("A", ttfBodyPx)*2 + symbol.AdvancePx(r, ttfBodyPx)
	if got := f.Measure(text, st); got != want {
		t.Fatalf("chain measure=%d, per-face sum=%d", got, want)
	}
	// Paint it, then reproduce the expected pixels by hand: same baseline,
	// the symbol face's own mask in the middle.
	const bg = 0x000000
	surf := newFB(120, 60, bg)
	Paint(&Layout{Text: f}, surf, 0, 0, 120, 60, 0) // no items; sanity
	got := newFB(120, 60, bg)
	f.Paint(got, 4, 20, text, st, ColorText, Clip{W: 120, H: 60})
	wantFB := newFB(120, 60, bg)
	asc, _, _ := f.UI.LineMetrics(ttfBodyPx)
	baseline := 20 + asc
	pen := 4
	for _, rr := range text {
		face := f.UI
		if rr == r {
			face = symbol
		}
		m, adv, err := face.Glyph(face.GlyphIndex(rr), ttfBodyPx)
		if err != nil {
			t.Fatalf("glyph %U: %v", rr, err)
		}
		blitMask(wantFB, Clip{W: 120, H: 60}, pen+m.BearingX, baseline-m.BearingY, m, ColorText)
		pen += adv
	}
	for i := range got.px {
		if got.px[i] != wantFB.px[i] {
			t.Fatalf("fallback paint diverged at pixel %d", i)
		}
	}
	// And the lazy load fired exactly once, for the covering face.
	seenChrome := 0
	for _, rd := range *reads {
		if rd == "CHROME.TTF" {
			seenChrome++
		}
	}
	if seenChrome != 1 {
		t.Fatalf("the miss must lazily read the symbol face once: %v", *reads)
	}
	if f.Reg.Notdef() != 0 {
		t.Error("a covered rune was counted as notdef")
	}
}

// TestRegistryCoveredRunsMatchTheHardCodedEngine pins the comparator rule:
// when the manifest lists only today's faces, text they cover must measure
// and paint byte-identically through either engine — the M93 corpus cannot
// move.
func TestRegistryCoveredRunsMatchTheHardCodedEngine(t *testing.T) {
	hard := loadFonts(t)
	reg, _ := manifestFonts(t)
	texts := []string{
		"The quick brown fox jumps over the lazy dog 0123456789",
		"inter, national: punctuation & marks!?!",
		"Mi W .il",
	}
	styles := []Style{
		{Size: 1}, {Size: 2},
		{Size: 1, Bold: true}, {Size: 1, Italic: true},
		{Size: 1, Mono: true}, {Size: 1, Bold: true, Italic: true},
	}
	for _, st := range styles {
		for _, text := range texts {
			if a, b := hard.Measure(text, st), reg.Measure(text, st); a != b {
				t.Errorf("%+v %q: hard=%d registry=%d", st, text, a, b)
			}
			if a, b := hard.LineHeight(st), reg.LineHeight(st); a != b {
				t.Errorf("%+v lineheight: hard=%d registry=%d", st, a, b)
			}
			fa, fb2 := newFB(400, 60, 0), newFB(400, 60, 0)
			hard.Paint(fa, 4, 20, text, st, ColorText, Clip{W: 400, H: 60})
			reg.Paint(fb2, 4, 20, text, st, ColorText, Clip{W: 400, H: 60})
			for i := range fa.px {
				if fa.px[i] != fb2.px[i] {
					t.Fatalf("%+v %q: paint diverged at pixel %d", st, text, i)
				}
			}
		}
	}
	if reg.Reg.Notdef() != 0 {
		t.Error("covered text counted notdefs")
	}
}

// TestRegistryNotdefCountsAndKeepsThePrimary: a rune NO face covers lands on
// the primary's .notdef — it measures as the primary's own advance for that
// rune and increments the counter the browser publishes.
func TestRegistryNotdefCountsAndKeepsThePrimary(t *testing.T) {
	f, _ := manifestFonts(t)
	st := Style{Size: 1}
	// Find a rune absent from every listed face — primaries and the symbol
	// tail are the whole cascade for a ui run.
	symbol := f.Reg.Primary(ttf.Query{Role: "symbol"})
	var miss rune = -1
	for cp := rune(0x20); cp <= 0x2FFFF; cp++ {
		if f.UI.GlyphIndex(cp) == 0 && f.Mono.GlyphIndex(cp) == 0 &&
			f.Bold.GlyphIndex(cp) == 0 && f.Italic.GlyphIndex(cp) == 0 &&
			(symbol == nil || symbol.GlyphIndex(cp) == 0) {
			miss = cp
			break
		}
	}
	if miss < 0 {
		t.Fatal("no uncovered rune found in the scan range")
	}
	text := "A" + string(miss)
	if got, want := f.Measure(text, st), f.UI.Measure(text, ttfBodyPx); got != want {
		t.Fatalf("a missed rune must measure on the primary: got=%d primary=%d", got, want)
	}
	if f.Reg.Notdef() != 1 {
		t.Fatalf("Notdef=%d, want exactly one counted miss", f.Reg.Notdef())
	}
	// The painted pixels are the primary's .notdef glyph — identical to
	// painting the rune on the primary directly.
	a := newFB(120, 60, 0)
	f.Paint(a, 4, 20, text, st, ColorText, Clip{W: 120, H: 60})
	b := newFB(120, 60, 0)
	asc, _, _ := f.UI.LineMetrics(ttfBodyPx)
	pen := 4
	for _, rr := range text {
		m, adv, _ := f.UI.Glyph(f.UI.GlyphIndex(rr), ttfBodyPx)
		blitMask(b, Clip{W: 120, H: 60}, pen+m.BearingX, 20+asc-m.BearingY, m, ColorText)
		pen += adv
	}
	for i := range a.px {
		if a.px[i] != b.px[i] {
			t.Fatalf("the missed rune did not paint the primary's .notdef (pixel %d)", i)
		}
	}
}

// ——— M186b Arabic presentation forms (#3179) ———

const naskhFixture = "../../../image/fonts/NotoNaskhArabic-Regular.ttf"

// arabicFonts builds the engine over INTER + NOTOARAB, the manifest shape
// that routes an Arabic run to the Naskh face while Latin stays on Inter.
func arabicFonts(t *testing.T) Fonts {
	t.Helper()
	paths := map[string]string{
		"INTER.TTF":    interFixture,
		"NOTOARAB.TTF": naskhFixture,
	}
	specs, err := ttf.ParseManifest([]byte(
		"INTER.TTF | role=ui | order=1\n" +
			"NOTOARAB.TTF | role=ui | order=7\n"))
	if err != nil {
		t.Fatalf("manifest refused: %v", err)
	}
	reg := ttf.NewRegistry(specs, func(file string) (*ttf.Face, error) {
		data, err := os.ReadFile(paths[file])
		if err != nil {
			return nil, err
		}
		return ttf.Parse(data)
	})
	f := RegistryFonts(reg)
	if f.UI == nil {
		t.Fatal("no ui primary")
	}
	return f
}

// paintString paints text into a framebuffer through the engine's own
// path — the same surface walk Measure's advance claims.
func paintString(f Fonts, text string, st Style) *fb {
	out := newFB(160, 60, 0)
	f.Paint(out, 4, 20, text, st, ColorText, Clip{W: 160, H: 60})
	return out
}

func fbEqual(a, b *fb) bool {
	if len(a.px) != len(b.px) {
		return false
	}
	for i := range a.px {
		if a.px[i] != b.px[i] {
			return false
		}
	}
	return true
}

// TestArabicPaintsTheShapedForms is the card's end-to-end engine check:
// "بح" must paint EXACTLY the pixels the literal shaped sequence
// U+FE91 U+FEA2 (beh-initial, hah-final) paints — the same forms resolved
// to the Naskh face through the cascade, reordered by the same bidi pass —
// and must NOT paint the unshaped isolated forms. lam-alef likewise
// collapses to its ligature code point. Measure rides the same runes.
func TestArabicPaintsTheShapedForms(t *testing.T) {
	f := arabicFonts(t)
	st := Style{Size: 1}

	text := "abبحde"
	shaped := paintString(f, text, st)
	literal := paintString(f, "abﺑﺢde", st)
	if !fbEqual(shaped, literal) {
		t.Fatal("shaped بح did not paint the literal beh-initial/hah-final forms")
	}
	if got, want := f.Measure(text, st), f.Measure("abﺑﺢde", st); got != want {
		t.Fatalf("measure %d != literal %d", got, want)
	}
	unshaped := paintString(f, "abﺏﺡde", st)
	if fbEqual(shaped, unshaped) {
		t.Fatal("shaped بح equals the isolated forms — shaping did nothing")
	}

	// lam-alef: the pair paints its ligature, with the absorbed alef
	// consuming no advance.
	lig := paintString(f, "لا", st)
	litLig := paintString(f, "ﻻ", st)
	if !fbEqual(lig, litLig) {
		t.Fatal("لا did not paint the lamalef ligature")
	}
	if got, want := f.Measure("لا", st), f.Measure("ﻻ", st); got != want {
		t.Fatalf("measure لا=%d, want ligature %d", got, want)
	}
	// And the ligature is narrower than the two letters would be: the alef
	// slot paints nothing of its own.
	if got, sum := f.Measure("لا", st), f.Measure("ل", st)+f.Measure("ا", st); got >= sum {
		t.Fatalf("ligature measure %d not under the two-letter sum %d", got, sum)
	}
}

// TestRegistryZeroValueIsBitmapHonest: a nil registry degrades exactly like a
// failed hard-coded load — bitmap metrics, honest name.
func TestRegistryZeroValueIsBitmapHonest(t *testing.T) {
	f := RegistryFonts(nil)
	if f.Loaded() || f.Name() != "bitmap8x8" {
		t.Fatalf("a nil registry must be the fontless engine, got %q", f.Name())
	}
	if f.Measure("W", Style{Size: 1}) != (Bitmap{}).Measure("W", Style{Size: 1}) {
		t.Error("nil-registry measure must be the bitmap metric")
	}
}
