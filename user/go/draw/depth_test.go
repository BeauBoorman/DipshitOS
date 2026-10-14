package draw

import (
	"testing"

	"virelai/widgets"
)

func TestClipStackSemantics(t *testing.T) {
	c := canvas(20, 20, 0xff102030)
	if got := c.Clip(); got != (widgets.Rect{W: 20, H: 20}) {
		t.Fatalf("depth-0 clip = %v, want the whole canvas", got)
	}
	c.PopClip() // underflow is a deterministic no-op
	c.PushClip(rect(4, 4, 8, 8))
	if got := c.Clip(); got != rect(4, 4, 8, 8) {
		t.Fatalf("clip = %v", got)
	}
	c.PushClip(rect(6, -2, 20, 20))
	if got := c.Clip(); got != (widgets.Rect{X: 6, Y: 4, W: 6, H: 8}) {
		t.Fatalf("nested clip did not intersect: %v", got)
	}
	c.PopClip()
	if got := c.Clip(); got != rect(4, 4, 8, 8) {
		t.Fatalf("pop did not restore: %v", got)
	}
	c.PopClip()
	c.PopClip() // underflow at depth 0 again
	if got := c.Clip(); got != (widgets.Rect{W: 20, H: 20}) {
		t.Fatalf("pop past depth 0 changed clip: %v", got)
	}
	// A push past ClipDepth is a no-op: the ninth, disjoint push must not
	// shrink the clip to empty.
	for i := 0; i < ClipDepth; i++ {
		c.PushClip(rect(2+i, 2+i, 20-2*i, 20-2*i))
	}
	c.PushClip(rect(100, 100, 4, 4))
	if got := c.Clip(); got != rect(9, 9, 6, 6) {
		t.Fatalf("push past ClipDepth was not a no-op: %v", got)
	}
	// An empty intersection is a legal clip: it paints nothing.
	c2 := canvas(10, 10, 0xff102030)
	c2.PushClip(rect(0, 0, 4, 4))
	c2.PushClip(rect(6, 6, 4, 4))
	FillRect(c2, widgets.Rect{W: 10, H: 10}, 0xffffffff)
	for i, p := range c2.Pix {
		if p != 0xff102030 {
			t.Fatalf("empty clip painted pixel %d", i)
		}
	}
}

// TestClipStackBoundsPrimitives pins §3.3.4: every primitive, v1 and v2,
// paints only inside the active clip.
func TestClipStackBoundsPrimitives(t *testing.T) {
	src := canvas(4, 4, 0xffe05050)
	for name, paint := range map[string]func(*BufferCanvas){
		"fillRect":    func(c *BufferCanvas) { FillRect(c, widgets.Rect{W: 20, H: 20}, 0xffffffff) },
		"roundedRect": func(c *BufferCanvas) { FillRoundedRect(c, widgets.Rect{W: 20, H: 20}, 4, 0xffffffff) },
		"stroke":      func(c *BufferCanvas) { StrokeLine(c, 0, 10, 19, 10, 3, 0xffffffff) },
		"ellipse":     func(c *BufferCanvas) { FillEllipse(c, widgets.Rect{W: 20, H: 20}, 0xffffffff) },
		"blendPixel":  func(c *BufferCanvas) { BlendPixel(c, 2, 2, 0xffffffff) },
		"blitTinted":  func(c *BufferCanvas) { BlitTinted(c, src, 0, 0, 0xffffffff) },
		"shadow":      func(c *BufferCanvas) { FillShadow(c, widgets.Rect{W: 20, H: 20}, 4, 6, 4, 0x80000000) },
		"gradient":    func(c *BufferCanvas) { FillLinearGradient(c, widgets.Rect{W: 20, H: 20}, 0xffffffff, 0xff808080) },
		"blitScaled":  func(c *BufferCanvas) { BlitScaled(c, src, widgets.Rect{W: 20, H: 20}) },
		"fillArc":     func(c *BufferCanvas) { FillArc(c, widgets.Rect{W: 20, H: 20}, 0, 360, 0xffffffff) },
		"strokeArc":   func(c *BufferCanvas) { StrokeArc(c, widgets.Rect{W: 20, H: 20}, 2, 0, 360, 0xffffffff) },
		"polygon":     func(c *BufferCanvas) { FillPolygon(c, []Point{{0, 0}, {20, 0}, {20, 20}}, 0xffffffff) },
		"bitmapText":  func(c *BufferCanvas) { c.Text(nil, widgets.Rect{W: 20, H: 20}, 0, 0, 13, "hi", 0xffffffff) },
	} {
		t.Run(name, func(t *testing.T) {
			c := canvas(20, 20, 0xff102030)
			c.PushClip(rect(8, 8, 6, 6))
			paint(c)
			for y := 0; y < 20; y++ {
				for x := 0; x < 20; x++ {
					outside := x < 8 || x >= 14 || y < 8 || y >= 14
					if outside && at(c, x, y) != 0xff102030 {
						t.Fatalf("painted outside the clip at (%d,%d)", x, y)
					}
				}
			}
		})
	}
}

func TestShadowRampAndHardPlate(t *testing.T) {
	bg := uint32(0xff102030)
	// blur == 0: the translated silhouette, full peak inside, nothing outside.
	c := canvas(64, 48, bg)
	FillShadow(c, rect(10, 6, 20, 12), 4, 0, 4, 0x40000000)
	if got, want := at(c, 20, 16), blend(bg, 0x40000000, samples); got != want {
		t.Fatalf("silhouette interior = %08x, want peak %08x", got, want)
	}
	for _, p := range [][2]int{{20, 9}, {9, 14}, {50, 30}} {
		if at(c, p[0], p[1]) != bg {
			t.Fatalf("hard plate painted outside the silhouette at %v", p)
		}
	}
	// blur > 0: the ramp falls off outward and leaves the far side alone.
	c = canvas(64, 48, bg)
	FillShadow(c, rect(20, 10, 20, 12), 4, 8, 4, 0x40000000)
	if got, want := at(c, 30, 16), blend(bg, 0x40000000, samples); got != want {
		t.Fatalf("ramp interior = %08x, want peak %08x", got, want)
	}
	// Distance leftward from the x=20 silhouette edge: darker nearer.
	edge := at(c, 17, 16)
	mid := at(c, 14, 16)
	if edge>>16&0xff >= mid>>16&0xff {
		t.Fatalf("ramp did not fade outward: near %08x far %08x", edge, mid)
	}
	// The falloff is isotropic around the translated silhouette: 6px above
	// the top edge is inside the 8px blur, 10px out is not.
	if at(c, 30, 8) == bg {
		t.Fatal("ramp did not reach the silhouette's upper falloff")
	}
	if at(c, 10, 16) != bg || at(c, 30, 4) != bg {
		t.Fatal("ramp painted past the blur distance")
	}
	// Clamps: negative blur is the hard plate; alpha 0 and empty rect no-op.
	a, b := canvas(24, 24, bg), canvas(24, 24, bg)
	FillShadow(a, rect(4, 4, 12, 8), 4, -3, 4, 0x40000000)
	FillShadow(b, rect(4, 4, 12, 8), 4, 0, 4, 0x40000000)
	for i := range a.Pix {
		if a.Pix[i] != b.Pix[i] {
			t.Fatalf("negative blur did not clamp to 0 at pixel %d", i)
		}
	}
	b = canvas(24, 24, bg)
	FillShadow(b, rect(4, 4, 12, 8), 4, 8, 4, 0x00000000)
	FillShadow(b, rect(4, 4, 0, 8), 4, 8, 4, 0x40000000)
	for i, p := range b.Pix {
		if p != bg {
			t.Fatalf("alpha-0 or empty shadow painted pixel %d", i)
		}
	}
}

func TestGradientKernelConvention(t *testing.T) {
	// The kernel's wallpaper lerp: t = row·256/H, channels truncating —
	// the Go gradient must read identically (ui-primitives.md §2.5).
	lerp := func(top, bot uint32, t int) uint32 {
		out := uint32(0)
		for shift := uint(24); ; shift -= 8 {
			a := int(top>>shift) & 0xff
			b := int(bot>>shift) & 0xff
			out |= uint32(a*(256-t)/256+b*t/256) << shift
			if shift == 0 {
				break
			}
		}
		return out
	}
	const top, bot = 0xff1a1a2e, 0xff0a0a14
	c := canvas(4, 256, 0)
	FillLinearGradient(c, widgets.Rect{W: 4, H: 256}, top, bot)
	for y := 0; y < 256; y++ {
		if got, want := at(c, 1, y), lerp(top, bot, y*256/256); got != want {
			t.Fatalf("row %d = %08x, want kernel lerp %08x", y, got, want)
		}
	}
	if at(c, 1, 0) != top || at(c, 1, 255) == bot {
		t.Fatal("gradient endpoints diverged from the kernel convention")
	}
	// A clipped gradient keeps the rect's own row indexing, not the
	// canvas's: row r.Y stays rgbTop even when r.Y > clip.Y.
	c = canvas(4, 8, 0)
	c.PushClip(rect(0, 4, 4, 4))
	FillLinearGradient(c, rect(0, 2, 4, 6), top, bot)
	for y := 4; y < 8; y++ {
		if got, want := at(c, 1, y), lerp(top, bot, (y-2)*256/6); got != want {
			t.Fatalf("clipped row %d = %08x, want %08x", y, got, want)
		}
	}
	// Empty rect and alpha-0 endpoints are no-ops.
	c = canvas(4, 4, 0xff102030)
	FillLinearGradient(c, rect(0, 0, 4, 0), top, bot)
	FillLinearGradient(c, widgets.Rect{W: 4, H: 4}, 0x00112233, 0x00445566)
	for i, p := range c.Pix {
		if p != 0xff102030 {
			t.Fatalf("empty or transparent gradient painted pixel %d", i)
		}
	}
}

func TestBlitScaledRatios(t *testing.T) {
	src := &BufferCanvas{W: 4, H: 2, Pix: []uint32{
		0xffff0000, 0xff00ff00, 0x80ffffff, 0x00000000,
		0xff0000ff, 0xffffffff, 0xff102030, 0x40000000,
	}}
	// 1:1 is an exact composite, including the translucent texels.
	c := canvas(8, 6, 0xff101010)
	BlitScaled(c, src, rect(2, 2, 4, 2))
	for sy := 0; sy < 2; sy++ {
		for sx := 0; sx < 4; sx++ {
			if got, want := at(c, 2+sx, 2+sy), blend(0xff101010, src.Pix[sy*4+sx], samples); got != want {
				t.Fatalf("1:1 blit (%d,%d) = %08x, want %08x", sx, sy, got, want)
			}
		}
	}
	// An exact 2x upscale keeps texel centers between dst pixels: the
	// edge-clamped corner texel is exact, its neighbor interpolates.
	c = canvas(12, 8, 0xff101010)
	BlitScaled(c, src, rect(2, 2, 8, 4))
	if at(c, 2, 2) != 0xffff0000 {
		t.Fatal("2x upscale lost the corner texel")
	}
	if at(c, 3, 2) == 0xffff0000 {
		t.Fatal("2x upscale skipped bilinear interpolation")
	}
	if at(c, 10, 6) != 0xff101010 {
		t.Fatal("blit painted outside dst")
	}
	// Out-of-range taps clamp to the edge: upscale into a wider dst than
	// the source span paints edge color at the far side, not wraparound.
	c = canvas(10, 10, 0)
	BlitScaled(c, src, rect(0, 0, 10, 10))
	if at(c, 9, 9) == 0 {
		t.Fatal("clamped upscale left the corner unpainted")
	}
	// No-ops: empty dst, nil src, invalid src.
	c = canvas(8, 8, 0xff102030)
	BlitScaled(c, src, rect(0, 0, 0, 4))
	BlitScaled(c, nil, widgets.Rect{W: 4, H: 4})
	BlitScaled(c, &BufferCanvas{Pix: []uint32{0xffffffff}, W: 4, H: 4}, widgets.Rect{W: 4, H: 4})
	for i, p := range c.Pix {
		if p != 0xff102030 {
			t.Fatalf("invalid blit painted pixel %d", i)
		}
	}
}

func TestArcSweepsAndClamps(t *testing.T) {
	r := rect(2, 2, 20, 20)
	// sweep 0 and weight 0 paint nothing.
	c := canvas(24, 24, 0xff102030)
	FillArc(c, r, 0, 0, 0xffffffff)
	FillArc(c, r, 0, -90, 0xffffffff)
	StrokeArc(c, r, 0, 0, 90, 0xffffffff)
	for i, p := range c.Pix {
		if p != 0xff102030 {
			t.Fatalf("zero sweep or weight painted pixel %d", i)
		}
	}
	// A 360 sweep is the full ellipse; a 360 ring is the full stroke.
	a, b := canvas(24, 24, 0xff102030), canvas(24, 24, 0xff102030)
	FillArc(a, r, 0, 360, 0xffe05050)
	FillEllipse(b, r, 0xffe05050)
	for i := range a.Pix {
		if a.Pix[i] != b.Pix[i] {
			t.Fatalf("360 wedge != ellipse at pixel %d", i)
		}
	}
	a, b = canvas(24, 24, 0xff102030), canvas(24, 24, 0xff102030)
	StrokeArc(a, r, 3, 0, 360, 0xffe05050)
	StrokeEllipse(b, r, 3, 0xffe05050)
	for i := range a.Pix {
		if a.Pix[i] != b.Pix[i] {
			t.Fatalf("360 ring != elliptical stroke at pixel %d", i)
		}
	}
	// startDeg normalizes mod 360.
	a, b = canvas(24, 24, 0xff102030), canvas(24, 24, 0xff102030)
	FillArc(a, r, 370, 90, 0xffe05050)
	FillArc(b, r, 10, 90, 0xffe05050)
	for i := range a.Pix {
		if a.Pix[i] != b.Pix[i] {
			t.Fatalf("startDeg did not normalize at pixel %d", i)
		}
	}
	// 0° is 12 o'clock, positive clockwise: a 90° sweep from 0 covers the
	// top-right quadrant and spares the left.
	c = canvas(24, 24, 0)
	FillArc(c, r, 0, 90, 0xffffffff)
	if at(c, 17, 5) == 0 || at(c, 6, 5) != 0 || at(c, 12, 5) == 0 {
		t.Fatal("quarter wedge covered the wrong quadrant")
	}
	if at(c, 12, 18) != 0 {
		t.Fatal("quarter wedge leaked below center")
	}
}

func TestCanvasTextDegradesPerFace(t *testing.T) {
	plate := rect(4, 4, 60, 14)
	// nil face → the 8x8 bitmap run, identical to widgets.DrawText.
	a, b := canvas(72, 24, 0xff102030), canvas(72, 24, 0xff102030)
	a.Text(nil, plate, 0, 0, 13, "hi", 0xffe7f0ff)
	widgets.DrawText(b, plate, "hi", 0xffe7f0ff)
	for i := range a.Pix {
		if a.Pix[i] != b.Pix[i] {
			t.Fatalf("nil-face Text diverged from the bitmap face at pixel %d", i)
		}
	}
	if inkCount(a, 0xff102030) == 0 {
		t.Fatal("nil-face Text blanked the label")
	}
	// A real face takes the draw.Text mask path — different pixels than
	// the bitmap run, and the clip still binds.
	faces := textFaces(t)
	a = canvas(72, 24, 0xff102030)
	a.Text(faces["INTER.TTF"], plate, plate.X+2, plate.Bottom()-4, 13, "hi", 0xffe7f0ff)
	if inkCount(a, 0xff102030) == 0 {
		t.Fatal("faced Text painted nothing")
	}
	diff := 0
	for i := range a.Pix {
		if a.Pix[i] != b.Pix[i] {
			diff++
		}
	}
	if diff == 0 {
		t.Fatal("a TrueType face painted the bitmap run's pixels")
	}
	// A nil FillerCanvas degrades without panicking on host stubs.
	var fc FillerCanvas
	fc.Text(nil, plate, 0, 0, 13, "hi", 0xffe7f0ff)
}

func TestDepthDeterminismAndClamps(t *testing.T) {
	// Identical inputs produce bit-identical output (§3.3.3).
	paint := func(c *BufferCanvas) {
		c.PushClip(rect(4, 4, 40, 32))
		FillShadow(c, rect(8, 6, 24, 18), 6, 10, 4, 0x40000000)
		FillLinearGradient(c, rect(0, 0, 48, 40), 0xff1a1a2e, 0xff0a0a14)
		FillArc(c, rect(8, 8, 24, 24), 30, 200, 0xa0ffe050)
		c.PopClip()
	}
	a, b := canvas(48, 40, 0xff102030), canvas(48, 40, 0xff102030)
	paint(a)
	paint(b)
	for i := range a.Pix {
		if a.Pix[i] != b.Pix[i] {
			t.Fatalf("identical calls diverged at pixel %d", i)
		}
	}
	// Bad arguments clamp, never crash: sweep > 360 == 360; weight beyond
	// the minor axis saturates to the fill inside the wedge.
	c := canvas(24, 24, 0xff102030)
	FillArc(c, rect(2, 2, 20, 20), 0, 500, 0xffe05050)
	d := canvas(24, 24, 0xff102030)
	FillEllipse(d, rect(2, 2, 20, 20), 0xffe05050)
	for i := range c.Pix {
		if c.Pix[i] != d.Pix[i] {
			t.Fatalf("sweep > 360 did not clamp to a full ellipse at pixel %d", i)
		}
	}
	c = canvas(24, 24, 0xff102030)
	StrokeArc(c, rect(2, 2, 20, 20), 99, 0, 90, 0xffe05050)
	d = canvas(24, 24, 0xff102030)
	FillArc(d, rect(2, 2, 20, 20), 0, 90, 0xffe05050)
	for i := range c.Pix {
		if c.Pix[i] != d.Pix[i] {
			t.Fatalf("saturated ring != filled wedge at pixel %d", i)
		}
	}
}

func TestDepthHotPathsNoAllocations(t *testing.T) {
	c := canvas(64, 64, 0xff101010)
	r := rect(4, 4, 24, 20)
	src := canvas(8, 8, 0x80ffffff)
	for name, fn := range map[string]func(){
		"shadow":   func() { FillShadow(c, r, 4, 8, 4, 0x40000000) },
		"gradient": func() { FillLinearGradient(c, r, 0xff102030, 0xff405060) },
		"blitScaled": func() {
			BlitScaled(c, src, rect(8, 8, 14, 10))
		},
		"fillArc":   func() { FillArc(c, r, 30, 200, 0xff102030) },
		"strokeArc": func() { StrokeArc(c, r, 3, 30, 200, 0xff102030) },
		"clipStack": func() { c.PushClip(r); c.PopClip() },
	} {
		t.Run(name, func(t *testing.T) {
			if allocs := testing.AllocsPerRun(20, fn); allocs != 0 {
				t.Fatalf("hot path allocated: %.0f", allocs)
			}
		})
	}
}

// BenchmarkFullWindowDepthComposite is the card's 1280x720 composite: the
// seat-desktop gradient, a floating plate with its drop shadow, and a
// scaled icon — the M86c benchmark idiom, no wall-clock assertion.
func BenchmarkFullWindowDepthComposite(b *testing.B) {
	c := canvas(1280, 720, 0xff102030)
	icon := canvas(16, 16, 0)
	FillLinearGradient(icon, rect(0, 0, 16, 16), 0xffffe050, 0xffe05050)
	FillEllipse(icon, rect(2, 2, 12, 12), 0xccffffff)
	plate := rect(340, 200, 600, 320)
	b.ReportAllocs()
	b.SetBytes(int64(c.W * c.H * 4))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		FillLinearGradient(c, widgets.Rect{W: 1280, H: 720}, 0xff1a1a2e, 0xff0a0a14)
		FillShadow(c, plate, 8, 16, 4, 0x40000000)
		FillRoundedRect(c, plate, 8, 0xff204060)
		BlitScaled(c, icon, rect(356, 216, 48, 48))
	}
}
