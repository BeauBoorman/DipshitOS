package draw

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"virelai/widgets"
)

func rect(x, y, w, h int) widgets.Rect {
	return widgets.Rect{X: x, Y: y, W: w, H: h}
}

// A diff is never auto-accepted. DRAW_UPDATE_GOLDEN=1 explicitly regenerates
// the pinned images for review, as in webrender/golden_test.go.
func checkGolden(t *testing.T, name string, c *BufferCanvas) {
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
	if os.Getenv("DRAW_UPDATE_GOLDEN") == "1" {
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
		t.Fatalf("missing golden %s (run DRAW_UPDATE_GOLDEN=1 to create): %v", path, err)
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

func TestShapeGoldens(t *testing.T) {
	const bg, ink, accent = 0xff101b2b, 0xffe7f0ff, 0xff51adf6
	cases := []struct {
		name string
		w, h int
		draw func(*BufferCanvas)
	}{
		{"round", 106, 84, func(c *BufferCanvas) {
			FillRect(c, rect(3, 3, 24, 17), 0xff204060)
			FillRoundedRect(c, rect(30, 3, 24, 17), 1, accent)
			FillRoundedRect(c, rect(57, 3, 24, 17), 4, accent)
			FillRoundedRect(c, rect(84, 3, 24, 17), 30, accent)
			StrokeRoundedRect(c, rect(3, 25, 24, 17), 0, 1, ink)
			StrokeRoundedRect(c, rect(30, 25, 24, 17), 4, 1, ink)
			StrokeRoundedRect(c, rect(57, 25, 24, 17), 8, 2, ink)
			StrokeRoundedRect(c, rect(84, 25, 24, 17), 8, 5, ink)
			FillRoundedRect(c, rect(-6, 50, 40, 28), 12, 0x8060e080)
			StrokeRoundedRect(c, rect(44, 50, 44, 28), 12, 2, 0x80ffcc40)
		}},
		{"ellipse", 104, 82, func(c *BufferCanvas) {
			FillEllipse(c, rect(3, 3, 18, 18), ink)
			FillEllipse(c, rect(27, 3, 33, 18), accent)
			FillEllipse(c, rect(66, 3, 14, 30), accent)
			StrokeEllipse(c, rect(3, 39, 18, 18), 1, ink)
			StrokeEllipse(c, rect(27, 39, 33, 18), 2, ink)
			StrokeEllipse(c, rect(66, 39, 27, 32), 4, accent)
			StrokeEllipse(c, rect(84, 0, 25, 25), 8, 0x80ffcc40)
		}},
		{"polygon", 104, 78, func(c *BufferCanvas) {
			FillPolygon(c, []Point{{4, 3}, {42, 12}, {12, 37}}, ink)
			FillPolygon(c, []Point{{50, 4}, {97, 4}, {97, 37}, {78, 21}, {50, 37}}, accent)
			FillPolygon(c, []Point{{-7, 47}, {28, 42}, {40, 73}, {-7, 73}}, 0x80ffc044)
			FillPolygon(c, []Point{{51, 43}, {96, 71}, {51, 71}, {96, 43}}, 0x80ff5555)
		}},
		{"line", 105, 83, func(c *BufferCanvas) {
			StrokeLine(c, 4, 6, 97, 6, 1, ink)
			StrokeLine(c, 4, 16, 97, 16, 2, accent)
			StrokeLine(c, 4, 30, 97, 30, 5, 0x80ffcc40)
			StrokeLine(c, 5, 38, 42, 76, 1, ink)
			StrokeLine(c, 43, 76, 81, 38, 3, accent)
			StrokeLine(c, 88, 55, 88, 55, 7, ink)
			StrokePolyline(c, []Point{{-8, 75}, {15, 48}, {44, 75}, {68, 50}, {105, 80}}, 3, 0x80f06eec)
		}},
		{"composite", 52, 42, func(c *BufferCanvas) {
			FillRect(c, rect(2, 2, 28, 25), 0x809944cc)
			src := &BufferCanvas{W: 4, H: 2, Pix: []uint32{
				0x00000000, 0x40000000, 0x80000000, 0xff000000,
				0xffeeeeee, 0x80000000, 0x40000000, 0x00000000,
			}}
			BlitTinted(c, src, 25, 14, 0xc0ffc055)
			BlitTinted(c, src, -1, 32, 0xff51adf6)
			BlendPixel(c, 48, 38, 0x80ffffff)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := canvas(tc.w, tc.h, bg)
			tc.draw(c)
			checkGolden(t, tc.name, c)
		})
	}
}

// The v2 depth block, pinned the same way: shadow at two radii x two blur
// distances plus the hard plate, the vertical gradient in both aspect
// directions plus clipped cases, scaled blits at up/down/non-integer
// ratios, nested and intersecting clips, and arcs at partial sweeps.
func TestDepthGoldens(t *testing.T) {
	const bg, ink, accent, shadow = 0xff101b2b, 0xffe7f0ff, 0xff51adf6, 0x40000000
	sprite := func() *BufferCanvas {
		s := canvas(12, 8, 0)
		FillRect(s, rect(0, 0, 6, 4), 0xffe05050)
		FillRect(s, rect(6, 0, 6, 4), 0xff50e050)
		FillRect(s, rect(0, 4, 6, 4), 0x805050e0)
		FillRect(s, rect(6, 4, 6, 4), 0xffffe050)
		FillEllipse(s, rect(3, 2, 6, 4), 0xccffffff)
		return s
	}
	cases := []struct {
		name string
		w, h int
		draw func(*BufferCanvas)
	}{
		{"shadow", 108, 88, func(c *BufferCanvas) {
			FillShadow(c, rect(8, 6, 22, 16), 2, 6, 4, shadow)
			FillShadow(c, rect(44, 6, 22, 16), 10, 6, 4, shadow)
			FillShadow(c, rect(80, 6, 22, 16), 2, 14, 4, shadow)
			FillShadow(c, rect(8, 42, 22, 16), 10, 14, 4, shadow)
			FillShadow(c, rect(44, 42, 22, 16), 6, 0, 6, 0x80ffc040)
			FillShadow(c, rect(84, 56, 30, 20), 8, 10, 8, shadow)
		}},
		{"gradient", 108, 84, func(c *BufferCanvas) {
			FillLinearGradient(c, rect(4, 4, 20, 60), 0xffff8840, 0xff2050c0)
			FillLinearGradient(c, rect(30, 4, 48, 12), 0xff1a1a2e, 0xffe8e8f0)
			FillLinearGradient(c, rect(30, 22, 48, 40), 0xff51adf6, 0x4051adf6)
			FillLinearGradient(c, rect(84, -10, 20, 60), 0xffe7f0ff, 0xff101b2b)
			c.PushClip(rect(34, 66, 40, 12))
			FillLinearGradient(c, rect(20, 60, 60, 24), 0xff30ff90, 0xff9040e0)
			c.PopClip()
		}},
		{"scaled", 108, 84, func(c *BufferCanvas) {
			s := sprite()
			BlitScaled(c, s, rect(4, 4, 30, 20))
			BlitScaled(c, s, rect(44, 4, 24, 16))
			BlitScaled(c, s, rect(76, 6, 12, 8))
			BlitScaled(c, s, rect(4, 40, 7, 5))
			BlitScaled(c, s, rect(18, 38, 40, 26))
			BlitScaled(c, s, rect(64, 40, 26, 26))
			BlitScaled(c, s, rect(96, 60, 22, 22))
		}},
		{"clip", 108, 84, func(c *BufferCanvas) {
			c.PushClip(rect(6, 6, 40, 30))
			FillRect(c, rect(0, 0, 108, 84), 0x80204060)
			c.PushClip(rect(26, 16, 40, 30))
			FillRoundedRect(c, rect(0, 0, 108, 84), 8, accent)
			c.PopClip()
			StrokeLine(c, 0, 0, 108, 84, 2, 0xc0ffcc40)
			FillEllipse(c, rect(30, 24, 24, 24), ink)
			c.PopClip()
			FillRect(c, rect(60, 50, 40, 30), 0x80f06eec)
			c.PushClip(rect(70, 44, 30, 24))
			FillPolygon(c, []Point{{64, 40}, {104, 40}, {84, 76}}, 0xc051adf6)
			c.PushClip(rect(80, 8, 20, 16))
			FillRect(c, rect(0, 0, 108, 84), 0x60ffffff)
			c.PopClip()
			c.PopClip()
		}},
		{"arc", 110, 84, func(c *BufferCanvas) {
			FillArc(c, rect(4, 4, 24, 24), 0, 90, ink)
			FillArc(c, rect(36, 4, 24, 24), 90, 180, accent)
			FillArc(c, rect(68, 4, 24, 24), 300, 300, 0xc0f06eec)
			FillArc(c, rect(4, 40, 24, 24), 0, 360, 0x8051adf6)
			StrokeArc(c, rect(36, 40, 24, 24), 2, 0, 270, ink)
			StrokeArc(c, rect(68, 40, 24, 24), 6, 45, 160, accent)
			StrokeArc(c, rect(96, -8, 24, 24), 3, 180, 120, 0xc0ffcc40)
			FillArc(c, rect(96, 52, 28, 28), 210, 100, 0x80ffe050)
		}},
		{"depthComposite", 108, 84, func(c *BufferCanvas) {
			FillLinearGradient(c, widgets.Rect{W: 108, H: 84}, 0xff1a1a2e, 0xff0a0a14)
			c.PushClip(rect(4, 4, 100, 76))
			FillShadow(c, rect(18, 14, 72, 52), 8, 12, 4, shadow)
			FillRoundedRect(c, rect(18, 14, 72, 52), 8, 0xff204060)
			BlitScaled(c, sprite(), rect(24, 20, 24, 16))
			StrokeArc(c, rect(58, 20, 26, 26), 4, 270, 220, accent)
			FillArc(c, rect(58, 48, 26, 20), 90, 140, 0xa0ff8840)
			c.PopClip()
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := canvas(tc.w, tc.h, bg)
			tc.draw(c)
			checkGolden(t, tc.name, c)
		})
	}
}
