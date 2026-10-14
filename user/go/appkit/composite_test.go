package appkit

// Composite goldens for the M104c (#2270) appkit face pass: ListController's
// widget and TextField painted onto a draw.BufferCanvas through the widened
// widgets.Canvas — rounded plates, inside focus rings, the §2.3 state ramp,
// 13px TrueType labels with a measured caret, and the nil-face degrade
// pinned on the same surface (§3.4).

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
	"virelai/layout"
	"virelai/theme"
	"virelai/ttf"
	"virelai/widgets"
)

// A diff is never auto-accepted. APPKIT_UPDATE_GOLDEN=1 explicitly
// regenerates the pinned images for review — the draw/golden_test.go idiom.
func checkCompositeGolden(t *testing.T, name string, c *draw.BufferCanvas) {
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
	if os.Getenv("APPKIT_UPDATE_GOLDEN") == "1" {
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
		t.Fatalf("missing golden %s (run APPKIT_UPDATE_GOLDEN=1 to create): %v", path, err)
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

func TestControlsCompositeGolden(t *testing.T) {
	th := theme.Current
	ui, err := os.ReadFile("../../../image/fonts/Inter-Regular.ttf")
	if err != nil {
		t.Fatal(err)
	}
	face, err := ttf.Parse(ui)
	if err != nil {
		t.Fatal(err)
	}

	const w, h = 208, 180
	c := &draw.BufferCanvas{Pix: make([]uint32, w*h), W: w, H: h}
	draw.FillRect(c, widgets.Rect{W: w, H: h}, draw.Opaque(th.Bg))

	// A focused list with a selection rides the widget's own face pass.
	items := []string{"alpha", "bravo", "charlie", "delta"}
	list := &widgets.List{R: widgets.Rect{X: 4, Y: 4, W: 96, H: 100}, Items: items,
		RowH: 24, Sel: 1, Focused: true, Fg: th.Text, Bg: th.ChromeBg, Face: face}
	NewListController(list).Draw(c)

	// TextField: unfocused with a prefix, focused with the caret mid-run and
	// a staged dead-key accent underlined, and the disabled state.
	pf := NewTextField(widgets.Rect{X: 108, Y: 4, W: 96, H: 24}, 32)
	pf.Face = face
	pf.Prefix = "> "
	pf.SetValue("notes.txt")
	pf.Draw(c)

	df := deField(32)
	df.R = widgets.Rect{X: 108, Y: 36, W: 96, H: 24}
	df.Face = face
	df.SetFocused(true)
	df.SetValue("ab")
	df.OnKey(Key{Usage: usageLeft})
	df.OnKey(keyUnder(layout.DE, usageAcute, false))
	df.Draw(c)

	off := NewTextField(widgets.Rect{X: 108, Y: 68, W: 96, H: 24}, 32)
	off.Face = face
	off.Disabled = true
	off.SetValue("locked")
	off.Draw(c)

	// The nil-face degrade on the same full canvas: legible bitmap labels.
	bf := NewTextField(widgets.Rect{X: 108, Y: 100, W: 96, H: 24}, 32)
	bf.SetFocused(true)
	bf.SetValue("8x8")
	bf.Draw(c)

	bl := &widgets.List{R: widgets.Rect{X: 4, Y: 112, W: 96, H: 48},
		Items: []string{"bitmap", "rows"}, RowH: 24, Sel: 0, Fg: th.Text, Bg: th.ChromeBg}
	NewListController(bl).Draw(c)

	checkCompositeGolden(t, "appkit-controls", c)
}

// The M104d (#2271) dropdown: the §2.3 button ramp, and the open popover —
// the contract's FillShadow + PushClip surface — with its selected marker,
// hovered row, and the kit's scrollbar inside the plate. The nil-face
// degrade keeps legible bitmap labels (§3.4).
func TestDropdownCompositeGolden(t *testing.T) {
	th := theme.Current
	ui, err := os.ReadFile("../../../image/fonts/Inter-Regular.ttf")
	if err != nil {
		t.Fatal(err)
	}
	face, err := ttf.Parse(ui)
	if err != nil {
		t.Fatal(err)
	}
	chrome, err := os.ReadFile("../../../image/fonts/VirelaiChrome-Regular.ttf")
	if err != nil {
		t.Fatal(err)
	}
	icon, err := ttf.Parse(chrome)
	if err != nil {
		t.Fatal(err)
	}

	const w, h = 240, 232
	c := &draw.BufferCanvas{Pix: make([]uint32, w*h), W: w, H: h}
	draw.FillRect(c, widgets.Rect{W: w, H: h}, draw.Opaque(th.Bg))

	// The closed button's §2.3 ramp: idle, hover, disabled, focused.
	for _, dd := range []*Dropdown{
		{R: widgets.Rect{X: 4, Y: 4, W: 110, H: 24}, Items: []string{"dark", "light"}, Sel: 0},
		{R: widgets.Rect{X: 122, Y: 4, W: 110, H: 24}, Items: []string{"dark", "light"}, Sel: 0, Hovered: true},
		{R: widgets.Rect{X: 4, Y: 36, W: 110, H: 24}, Items: []string{"dark", "light"}, Sel: 1, Disabled: true},
		{R: widgets.Rect{X: 122, Y: 36, W: 110, H: 24}, Items: []string{"dark", "light"}, Sel: 1, Focused: true},
	} {
		dd.UIFace, dd.IconFace = face, icon
		dd.Draw(c)
	}

	// Open, goset-vocab-flavoured rows: selected marker on row 1, the
	// hovered row 3, five items under MaxRows 4 so the popover carries the
	// kit's scrollbar — all under the §2.5 shadow and the clip stack.
	open := &Dropdown{
		R:        widgets.Rect{X: 4, Y: 68, W: 160, H: 24},
		Items:    []string{"tabbed", "floating", "grid", "stack", "monocle"},
		Sel:      1,
		Open:     true,
		MaxRows:  4,
		HoverRow: 3,
		UIFace:   face, IconFace: icon,
	}
	open.Draw(c)

	// The nil-face degrade: a closed control labels itself through the
	// bitmap face and a text "v" affordance.
	bare := &Dropdown{
		R:     widgets.Rect{X: 4, Y: 204, W: 120, H: 24},
		Items: []string{"one", "two"}, Sel: 0,
	}
	bare.Draw(c)

	checkCompositeGolden(t, "appkit-dropdown", c)
}
