package widgets_test

// Composite goldens for the contract-v2 widget faces (M104c, #2270): every
// widget drawn onto a draw.BufferCanvas through the widened Canvas — rounded
// plates, inside focus rings, the §2.3 state ramp, and TrueType labels — plus
// the nil-face degrade pinned on the same surface (§3.4: no face → bitmap,
// never a blank label). The fill-only recording tests in widgets_test.go are
// the other half of the bargain: they are unchanged and still pin the
// RectCanvas stream byte-for-byte.

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"virelai/draw"
	"virelai/theme"
	"virelai/ttf"
	"virelai/widgets"
)

func rect(x, y, w, h int) widgets.Rect {
	return widgets.Rect{X: x, Y: y, W: w, H: h}
}

// A diff is never auto-accepted. WIDGETS_UPDATE_GOLDEN=1 explicitly
// regenerates the pinned images for review, the same idiom as
// draw/golden_test.go.
func checkGolden(t *testing.T, name string, c *draw.BufferCanvas) {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, c.W, c.H))
	for i, px := range c.Pix {
		img.Pix[4*i+0] = byte(px >> 16)
		img.Pix[4*i+1] = byte(px >> 8)
		img.Pix[4*i+2] = byte(px)
		img.Pix[4*i+3] = byte(px >> 24)
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join("testdata", "golden", name+".png")
	if os.Getenv("WIDGETS_UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("golden updated: %s (%d bytes)", path, buf.Len())
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("missing golden %s (run WIDGETS_UPDATE_GOLDEN=1 to create): %v", path, err)
	}
	pinned, err := png.Decode(bytes.NewReader(want))
	if err != nil {
		t.Fatalf("decode golden %s: %v", path, err)
	}
	if !pinned.Bounds().Eq(img.Bounds()) {
		t.Fatalf("golden bounds %v != %v", pinned.Bounds(), img.Bounds())
	}
	diffs, first := 0, ""
	for y := 0; y < c.H; y++ {
		for x := 0; x < c.W; x++ {
			a := color.NRGBAModel.Convert(pinned.At(x, y)).(color.NRGBA)
			b := img.NRGBAAt(x, y)
			if a != b {
				diffs++
				if first == "" {
					first = fmt.Sprintf("(%d,%d): %v != %v", x, y, a, b)
				}
			}
		}
	}
	if diffs != 0 {
		t.Fatalf("golden %s differs at %d pixels; first %s", name, diffs, first)
	}
}

// uiFace loads the UI face the desktop labels itself with — the same file the
// guest reads through draw.ReadFont("/host/INTER.TTF").
func uiFace(t *testing.T) *ttf.Face {
	t.Helper()
	return loadFace(t, "../../../image/fonts/Inter-Regular.ttf")
}

// iconFace loads the chrome glyph face — the guest's CHROME.TTF.
func iconFace(t *testing.T) *ttf.Face {
	t.Helper()
	return loadFace(t, "../../../image/fonts/VirelaiChrome-Regular.ttf")
}

func loadFace(t *testing.T, path string) *ttf.Face {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	face, err := ttf.Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	return face
}

func canvas(w, h int) *draw.BufferCanvas {
	c := &draw.BufferCanvas{Pix: make([]uint32, w*h), W: w, H: h}
	draw.FillRect(c, widgets.Rect{W: w, H: h}, draw.Opaque(theme.Current.Bg))
	return c
}

func TestWidgetFaceGoldens(t *testing.T) {
	th := theme.Current
	face := uiFace(t)
	fg, bg := th.Text, th.Surface
	cases := []struct {
		name string
		w, h int
		draw func(*draw.BufferCanvas)
	}{
		{"text", 132, 64, func(c *draw.BufferCanvas) {
			// default + disabled, then the nil-face degrade pinned on the
			// same surface.
			(&widgets.Text{R: rect(4, 4, 124, 24), Label: "Files", Fg: fg, Bg: bg, Face: face}).Draw(c)
			(&widgets.Text{R: rect(4, 36, 56, 24), Label: "Muted", Fg: fg, Bg: bg, Face: face, Disabled: true}).Draw(c)
			(&widgets.Text{R: rect(68, 36, 60, 24), Label: "8x8", Fg: fg, Bg: bg}).Draw(c)
		}},
		{"button", 200, 100, func(c *draw.BufferCanvas) {
			// The §2.3 ramp in one column plus the nil-face degrade.
			bs := []*widgets.Button{
				{R: rect(4, 4, 92, 24), Label: "Idle", LabelFace: face},
				{R: rect(4, 36, 92, 24), Label: "Hover", Hovered: true, LabelFace: face},
				{R: rect(4, 68, 92, 24), Label: "Press", Pressed: true, LabelFace: face},
				{R: rect(104, 4, 92, 24), Label: "Focus", Focused: true, LabelFace: face},
				{R: rect(104, 36, 92, 24), Label: "Off", Disabled: true, LabelFace: face},
				{R: rect(104, 68, 92, 24), Label: "Bitmap"},
			}
			for _, b := range bs {
				b.Draw(c)
			}
		}},
		{"list", 200, 136, func(c *draw.BufferCanvas) {
			items := []string{"alpha", "bravo", "charlie", "delta"}
			(&widgets.List{R: rect(4, 4, 92, 100), Items: items, RowH: 24, Sel: 1,
				Fg: fg, Bg: th.ChromeBg, Face: face}).Draw(c)
			(&widgets.List{R: rect(104, 4, 92, 100), Items: items, RowH: 24, Sel: 2,
				Focused: true, Fg: fg, Bg: th.ChromeBg, Face: face}).Draw(c)
			(&widgets.List{R: rect(4, 108, 92, 24), Items: []string{"disabled row"}, RowH: 24, Sel: 0,
				Disabled: true, Fg: fg, Bg: th.ChromeBg, Face: face}).Draw(c)
			(&widgets.List{R: rect(104, 108, 92, 24), Items: []string{"bitmap row"}, RowH: 24,
				Fg: fg, Bg: th.ChromeBg}).Draw(c)
		}},
		{"controls", 220, 124, func(c *draw.BufferCanvas) {
			// The M104d kit controls on their own §2.3 ramps — no labels, so
			// no face involvement: the pill track/thumb, the toggle states,
			// and the slider's band/fill/knob.
			(&widgets.Scrollbar{R: rect(4, 4, 12, 100), Total: 40, Viewport: 10, Offset: 8}).Draw(c)
			(&widgets.Scrollbar{R: rect(20, 4, 12, 100), Total: 40, Viewport: 10, Offset: 15, Pressed: true}).Draw(c)
			(&widgets.Toggle{R: rect(40, 8, 32, 18)}).Draw(c)
			(&widgets.Toggle{R: rect(40, 34, 32, 18), On: true}).Draw(c)
			(&widgets.Toggle{R: rect(40, 60, 32, 18), On: true, Focused: true}).Draw(c)
			(&widgets.Toggle{R: rect(40, 86, 32, 18), Disabled: true}).Draw(c)
			(&widgets.Slider{R: rect(84, 10, 130, 20), Max: 100, Value: 40}).Draw(c)
			(&widgets.Slider{R: rect(84, 40, 130, 20), Max: 100, Value: 65, Pressed: true}).Draw(c)
			(&widgets.Slider{R: rect(84, 70, 130, 20), Max: 100, Value: 20, Focused: true}).Draw(c)
			(&widgets.Slider{R: rect(84, 100, 130, 20), Max: 100, Value: 60, Disabled: true}).Draw(c)
		}},
		{"tree", 200, 136, func(c *draw.BufferCanvas) {
			icon := iconFace(t)
			rows := []widgets.TreeRow{
				{Label: "system", HasKids: true, Expanded: true},
				{Label: "kernel", Depth: 1},
				{Label: "services", Depth: 1, HasKids: true},
				{Label: "apps", HasKids: true},
			}
			(&widgets.Tree{R: rect(4, 4, 92, 100), Rows: rows, RowH: 24, Sel: 1,
				Fg: fg, Bg: th.ChromeBg, Face: face, IconFace: icon}).Draw(c)
			(&widgets.Tree{R: rect(104, 4, 92, 100), Rows: rows, RowH: 24, Sel: 2,
				Focused: true, Fg: fg, Bg: th.ChromeBg, Face: face, IconFace: icon}).Draw(c)
			// nil-face degrade: ">" / "v" affordances, bitmap labels.
			(&widgets.Tree{R: rect(4, 108, 192, 24), Rows: rows[:2], RowH: 24, Sel: 0,
				Fg: fg, Bg: th.ChromeBg}).Draw(c)
		}},
		{"table", 220, 148, func(c *draw.BufferCanvas) {
			cols := []widgets.TableColumn{
				{Title: "Name", W: 64}, {Title: "Kind", W: 56}, {Title: "State", W: 72},
			}
			cell := func(r, col int) string {
				return []string{"alpha", "beta", "gamma", "delta"}[r%4] +
					[]string{"-a", "-b", "-c"}[col]
			}
			(&widgets.Table{R: rect(4, 4, 212, 100), Cols: cols, Rows: 12,
				Cell: cell, Row: 1, Col: 2, Focused: true,
				Fg: fg, Bg: th.Surface, Face: face}).Draw(c)
			// nil-face degrade.
			(&widgets.Table{R: rect(4, 112, 212, 34), Cols: cols[:2], Rows: 2,
				Cell: cell, Row: 0, Col: 0, Fg: fg, Bg: th.Surface}).Draw(c)
		}},
		{"emptystate", 220, 204, func(c *draw.BufferCanvas) {
			// The M123b plate with the ui face, then the bitmap degrade.
			(&widgets.EmptyState{R: rect(4, 4, 212, 110), Icon: "?", Headline: "No matching apps",
				Hints: []string{"esc clears the filter", "type a new query"}, Face: face}).Draw(c)
			(&widgets.EmptyState{R: rect(4, 122, 212, 76), Icon: "|", Headline: "bitmap",
				Hints: []string{"^s saves"}}).Draw(c)
		}},
		{"textinput", 200, 104, func(c *draw.BufferCanvas) {
			idle := &widgets.TextInput{R: rect(4, 4, 192, 28), Face: face}
			idle.SetValue("notes.txt")
			idle.Draw(c)
			focused := &widgets.TextInput{R: rect(4, 40, 192, 28), Focused: true, Face: face}
			focused.SetValue("open file")
			focused.HandleKey(0x50, 0) // caret back one: the bar sits mid-run
			focused.Draw(c)
			off := &widgets.TextInput{R: rect(4, 76, 92, 24), Disabled: true, Face: face}
			off.SetValue("locked")
			off.Draw(c)
			bitmap := &widgets.TextInput{R: rect(104, 76, 92, 24), Focused: true}
			bitmap.SetValue("8x8")
			bitmap.Draw(c)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := canvas(tc.w, tc.h)
			tc.draw(c)
			checkGolden(t, "widget-"+tc.name, c)
		})
	}
}

// The degrade contract, asserted rather than eyeballed: a fill-only canvas
// sees exactly the v1 FillRect stream, and a full Canvas gets Canvas.Text
// calls for the label — both from the same Draw.
func TestDegradeAndTextContract(t *testing.T) {
	face := uiFace(t)
	b := &widgets.Button{R: rect(0, 0, 92, 24), Label: "OK", LabelFace: face}

	// RectCanvas-only: the stream is identical to pre-v2 paints.
	v1 := &recordingRectCanvas{}
	b.Draw(v1)
	want := []widgets.Rect{b.R, b.R.Inset(theme.Current.BorderW)}
	if len(v1.fills) < 2 || v1.fills[0] != want[0] || v1.fills[1] != want[1] {
		t.Fatalf("degrade stream starts %+v, want border plate %+v then face %+v", v1.fills, want[0], want[1])
	}

	// Full canvas: rounded plate + border + label through Text.
	full := &recordingFullCanvas{}
	b.Draw(full)
	if len(full.rounded) != 1 || full.rounded[0] != b.R {
		t.Fatalf("full canvas rounded fills = %+v", full.rounded)
	}
	if len(full.texts) != 1 || full.texts[0].s != "OK" || full.texts[0].face != face {
		t.Fatalf("full canvas text calls = %+v", full.texts)
	}
	if got := full.texts[0].rgb; got != draw.Opaque(theme.Current.Text) {
		t.Fatalf("label colour %#x, want opaque theme text", got)
	}
}

type recordingRectCanvas struct{ fills []widgets.Rect }

func (c *recordingRectCanvas) FillRect(r widgets.Rect, _ uint32) {
	c.fills = append(c.fills, r)
}

type recordingFullCanvas struct {
	rounded []widgets.Rect
	texts   []struct {
		s    string
		face *ttf.Face
		rgb  uint32
	}
}

func (c *recordingFullCanvas) FillRect(widgets.Rect, uint32) {}
func (c *recordingFullCanvas) FillRoundedRect(r widgets.Rect, _ int, _ uint32) {
	c.rounded = append(c.rounded, r)
}
func (c *recordingFullCanvas) StrokeRoundedRect(widgets.Rect, int, int, uint32) {}
func (c *recordingFullCanvas) BlitTinted([]uint32, int, int, int, int, uint32)  {}
func (c *recordingFullCanvas) Text(face *ttf.Face, _ widgets.Rect, _, _, _ int, s string, rgb uint32) {
	c.texts = append(c.texts, struct {
		s    string
		face *ttf.Face
		rgb  uint32
	}{s, face, rgb})
}
