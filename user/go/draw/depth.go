package draw

import (
	"math/bits"

	"virelai/widgets"
)

// The v2 depth block (contract §3.1): the clip stack, FillShadow,
// FillLinearGradient, BlitScaled, and the FillArc/StrokeArc pair — all
// inside the §3.3 invariants: integer math only, clip to canvas,
// deterministic, and nothing allocated on the hot path.

// ---- clip stack -----------------------------------------------------------

// ClipDepth bounds the clip stack: a push past it and a pop at depth 0 are
// deterministic no-ops (the §3.3.6 clamp rule applied to state).
const ClipDepth = 8

// PushClip intersects r with the active clip and pushes the result.
func (c *BufferCanvas) PushClip(r widgets.Rect) {
	if c == nil || c.depth >= ClipDepth {
		return
	}
	c.clips[c.depth] = intersect(c.Clip(), r)
	c.depth++
}

// PopClip restores the previous clip; at depth 0 it is a no-op.
func (c *BufferCanvas) PopClip() {
	if c == nil || c.depth == 0 {
		return
	}
	c.depth--
}

// Clip reports the active clip — the intersection of every pushed rect —
// or the whole canvas at depth 0, which is why v1 callers are unchanged.
func (c *BufferCanvas) Clip() widgets.Rect {
	if c == nil {
		return widgets.Rect{}
	}
	if c.depth == 0 {
		return widgets.Rect{W: c.W, H: c.H}
	}
	return c.clips[c.depth-1]
}

// intersect returns a ∩ b with the size clamped at empty, never negative.
func intersect(a, b widgets.Rect) widgets.Rect {
	x := max(a.X, b.X)
	y := max(a.Y, b.Y)
	right := min(saturatingAdd(a.X, a.W), saturatingAdd(b.X, b.W))
	bottom := min(saturatingAdd(a.Y, a.H), saturatingAdd(b.Y, b.H))
	if right < x {
		right = x
	}
	if bottom < y {
		bottom = y
	}
	return widgets.Rect{X: x, Y: y, W: right - x, H: bottom - y}
}

// activeClip is intersect(active clip stack, canvas bounds) — the §3.3.4
// region every §3.1 primitive clips to. Stored pushes can never exceed the
// canvas, but intersecting again keeps a caller that pokes W or H safe.
func activeClip(c *BufferCanvas) widgets.Rect {
	return intersect(c.Clip(), widgets.Rect{W: c.W, H: c.H})
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

// isqrt returns floor(√n); n ≤ 0 gives 0. Integer Newton seeded above √n,
// so the sequence descends to the floor — corner distances in FillShadow
// stay deterministic.
func isqrt(n int64) int64 {
	if n <= 0 {
		return 0
	}
	x := int64(1) << uint((bits.Len64(uint64(n))+1)/2)
	for {
		y := (x + n/x) / 2
		if y >= x {
			return x
		}
		x = y
	}
}

// ---- FillShadow -------------------------------------------------------------

// sdRound is the signed eighth-pixel distance from (px,py) to the rounded
// box (center cx,cy; half extents hw,hh; corner radius r — all eighths).
// The exterior distance is exact (flat-edge or arc distance); interior
// answers sign correctly — the shadow ramp clamps it to the peak anyway.
func sdRound(px, py, cx, cy, hw, hh, r int64) int64 {
	qx := abs64(px-cx) - (hw - r)
	qy := abs64(py-cy) - (hh - r)
	if qx <= 0 && qy <= 0 {
		return max(qx, qy) - r
	}
	ox, oy := max(qx, int64(0)), max(qy, int64(0))
	return isqrt(ox*ox+oy*oy) - r
}

// shadowCoverage sums the 16 subpixel ramp samples for the pixel at
// eighth-pixel origin (px,py). Inside the silhouette a sample contributes
// its full 1/16; outside it fades linearly to zero at blur8 eighths.
func shadowCoverage(px, py, cx, cy, hw, hh, r8, blur8 int64) int {
	sum := int64(0)
	for _, sy := range offsets {
		for _, sx := range offsets {
			d := sdRound(px+sx, py+sy, cx, cy, hw, hh, r8)
			switch {
			case blur8 == 0:
				if d <= 0 {
					sum++
				}
			case d <= 0:
				sum += blur8
			default:
				sum += max(0, blur8-d)
			}
		}
	}
	if blur8 == 0 {
		return int(sum) // inside-sample count, already 0..16
	}
	return int((sum + blur8/2) / blur8)
}

// FillShadow paints the §2.5 drop shadow: the rounded-rect silhouette r
// shifted straight down dy pixels, coverage a linear ramp of signed
// distance from the silhouette edge falling to zero blur px outward, with
// rgb's own alpha the peak. blur == 0 paints the translated silhouette — a
// legal hard offset plate. There is no dx and no blur buffer: shadows fall
// straight down in this design language.
func FillShadow(c *BufferCanvas, r widgets.Rect, radius, blur, dy int, rgb uint32) {
	if !valid(c) || r.W <= 0 || r.H <= 0 || rgb>>24 == 0 {
		return
	}
	radius = clamp(radius, 0, min(r.W, r.H)/2)
	blur = max(blur, 0)
	sr := widgets.Rect{X: r.X, Y: saturatingAdd(r.Y, dy), W: r.W, H: r.H}
	// The ramp reaches zero exactly blur px out; the extra pixel covers
	// subpixel samples straddling that boundary.
	pad := blur + 1
	x0, y0, x1, y1 := clipRect(c, widgets.Rect{
		X: saturatingAdd(sr.X, -pad), Y: saturatingAdd(sr.Y, -pad),
		W: saturatingAdd(sr.W, 2*pad), H: saturatingAdd(sr.H, 2*pad),
	})
	cx := int64(sr.X)*8 + int64(sr.W)*4
	cy := int64(sr.Y)*8 + int64(sr.H)*4
	hw, hh, r8, blur8 := int64(sr.W)*4, int64(sr.H)*4, int64(radius)*8, int64(blur)*8
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			px, py := int64(x)*8, int64(y)*8
			// The SDF is Lipschitz-1, so the pixel-center distance with 5
			// eighths of slack decides most pixels without a 16-sample loop.
			coverage := 0
			switch d := sdRound(px+4, py+4, cx, cy, hw, hh, r8); {
			case d <= -5:
				coverage = samples
			case d >= blur8+5:
			default:
				coverage = shadowCoverage(px, py, cx, cy, hw, hh, r8, blur8)
			}
			if coverage != 0 {
				i := y*c.W + x
				c.Pix[i] = blend(c.Pix[i], rgb, coverage)
			}
		}
	}
}

// ---- FillLinearGradient -----------------------------------------------------

// FillLinearGradient fills r top-to-bottom from rgbTop to rgbBot — the §2.5
// seat-desktop ramp. One integer channel-lerp per row in encoded sRGB
// (§3.3.2), at the kernel's own t = row·256/H truncating convention, so a
// Go-seat desktop reads identically to the fixed layer.
func FillLinearGradient(c *BufferCanvas, r widgets.Rect, rgbTop, rgbBot uint32) {
	if !valid(c) || r.W <= 0 || r.H <= 0 {
		return
	}
	x0, y0, x1, y1 := clipRect(c, r)
	for y := y0; y < y1; y++ {
		t := (y - r.Y) * 256 / r.H
		rgb := uint32(0)
		for shift := uint(24); ; shift -= 8 {
			top := int(rgbTop>>shift) & 0xff
			bot := int(rgbBot>>shift) & 0xff
			rgb |= uint32(top*(256-t)/256+bot*t/256) << shift
			if shift == 0 {
				break
			}
		}
		row := c.Pix[y*c.W+x0 : y*c.W+x1]
		if rgb>>24 == 255 {
			for i := range row {
				row[i] = rgb
			}
			continue
		}
		for i := range row {
			row[i] = blend(row[i], rgb, samples)
		}
	}
}

// ---- BlitScaled ---------------------------------------------------------------

// scaleCoord returns the 16.16 source-space position of destination pixel
// rel's center: (rel + 1/2)·srcLen/dstLen − 1/2. The 128/64 divide keeps
// the mapping exact at any integer ratio without floating point.
func scaleCoord(rel, srcLen, dstLen int64) int64 {
	rel = min(max(rel, 0), dstLen-1)
	hi, lo := bits.Mul64(uint64(rel)*2+1, uint64(srcLen))
	hi = hi<<16 | lo>>48
	lo <<= 16
	q, _ := bits.Div64(hi, lo, uint64(dstLen)*2)
	return int64(q) - 32768
}

// edgeIndex clamps the bilinear tap pair at floor index i to [0, last];
// out-of-range taps collapse onto the edge pixel so every weight lands on
// real source data.
func edgeIndex(i, last int64) (int64, int64) {
	a := min(max(i, 0), last)
	b := min(max(i+1, 0), last)
	return a, b
}

// BlitScaled paints src into dst at an arbitrary integer ratio — the
// upscale/downscale path for images and icons. Bilinear with 16.16 weights,
// channels lerped premultiplied so thin alpha edges do not darken, then
// composited by the §3.3.2 shape rule. An empty dst or invalid src is a
// no-op.
func BlitScaled(c *BufferCanvas, src *BufferCanvas, dst widgets.Rect) {
	if !valid(c) || !valid(src) || dst.W <= 0 || dst.H <= 0 {
		return
	}
	x0, y0, x1, y1 := clipRect(c, dst)
	sw, sh := int64(src.W), int64(src.H)
	dw, dh := int64(dst.W), int64(dst.H)
	for y := y0; y < y1; y++ {
		sy := scaleCoord(int64(y)-int64(dst.Y), sh, dh)
		fy := int(sy & 0xffff)
		iy0, iy1 := edgeIndex(sy>>16, sh-1)
		row0, row1 := int(iy0)*src.W, int(iy1)*src.W
		for x := x0; x < x1; x++ {
			sx := scaleCoord(int64(x)-int64(dst.X), sw, dw)
			fx := int(sx & 0xffff)
			ix0, ix1 := edgeIndex(sx>>16, sw-1)
			p00 := src.Pix[row0+int(ix0)]
			p01 := src.Pix[row0+int(ix1)]
			p10 := src.Pix[row1+int(ix0)]
			p11 := src.Pix[row1+int(ix1)]
			w00 := int64(65536-fx) * int64(65536-fy)
			w01 := int64(fx) * int64(65536-fy)
			w10 := int64(65536-fx) * int64(fy)
			w11 := int64(fx) * int64(fy)
			var pa, pr, pg, pb int64
			accum := func(p uint32, w int64) {
				a := int64(p >> 24)
				pa += a * w
				pr += a * int64(p>>16&0xff) * w
				pg += a * int64(p>>8&0xff) * w
				pb += a * int64(p&0xff) * w
			}
			accum(p00, w00)
			accum(p01, w01)
			accum(p10, w10)
			accum(p11, w11)
			pa = (pa + 1<<31) >> 32
			if pa == 0 {
				continue
			}
			// Un-premultiply the weighted channel sums; pa>0 here.
			channel := func(pm int64) uint32 {
				pm = (pm + 1<<31) >> 32
				return uint32(min((pm+pa/2)/pa, 255))
			}
			rgb := uint32(pa)<<24 | channel(pr)<<16 | channel(pg)<<8 | channel(pb)
			i := y*c.W + x
			c.Pix[i] = blend(c.Pix[i], rgb, samples)
		}
	}
}

// ---- arcs ---------------------------------------------------------------------

// sinQ is sin(0°..90°) in 16.16; quadrant symmetry covers the full circle.
// Boundary directions need only degree resolution, so no interpolation.
var sinQ = [91]int64{
	0, 1144, 2287, 3430, 4572, 5712, 6850, 7987, 9121, 10252,
	11380, 12505, 13626, 14742, 15855, 16962, 18064, 19161, 20252, 21336,
	22415, 23486, 24550, 25607, 26656, 27697, 28729, 29753, 30767, 31772,
	32768, 33754, 34729, 35693, 36647, 37590, 38521, 39441, 40348, 41243,
	42126, 42995, 43852, 44695, 45525, 46341, 47143, 47930, 48703, 49461,
	50203, 50931, 51643, 52339, 53020, 53684, 54332, 54963, 55578, 56175,
	56756, 57319, 57865, 58393, 58903, 59396, 59870, 60326, 60764, 61183,
	61584, 61966, 62328, 62672, 62997, 63303, 63589, 63856, 64104, 64332,
	64540, 64729, 64898, 65048, 65177, 65287, 65376, 65446, 65496, 65526,
	65536,
}

// sin16 returns sin(deg)·65536 for integer degrees, exact at every degree.
func sin16(deg int) int64 {
	deg %= 360
	if deg < 0 {
		deg += 360
	}
	switch {
	case deg <= 90:
		return sinQ[deg]
	case deg <= 180:
		return sinQ[180-deg]
	case deg <= 270:
		return -sinQ[deg-180]
	default:
		return -sinQ[360-deg]
	}
}

// arcDir returns the 16.16 unit vector at deg: 0° at 12 o'clock, positive
// clockwise in screen space (y down), so deg maps to (sin deg, −cos deg).
func arcDir(deg int) (int64, int64) {
	return sin16(deg), -sin16(deg + 90)
}

// inWedge reports whether direction v lies inside the clockwise sweep from
// d0 to d1 — the §3.1 two cross-product sign checks per sample: AND inside
// a ≤180° sweep, OR past it (where the excluded wedge is the small one).
func inWedge(vx, vy, d0x, d0y, d1x, d1y int64, wide bool) bool {
	c0 := d0x*vy - d0y*vx
	c1 := d1x*vy - d1y*vx
	if wide {
		return c0 >= 0 || c1 <= 0
	}
	return c0 >= 0 && c1 <= 0
}

func arc(c *BufferCanvas, r widgets.Rect, weight, startDeg, sweepDeg int, rgb uint32, stroke bool) {
	if !valid(c) || r.W <= 0 || r.H <= 0 || rgb>>24 == 0 || stroke && weight <= 0 {
		return
	}
	sweepDeg = clamp(sweepDeg, 0, 360)
	if sweepDeg == 0 {
		return
	}
	weight = clamp(weight, 0, min(r.W, r.H))
	inner := widgets.Rect{X: r.X + weight, Y: r.Y + weight, W: r.W - 2*weight, H: r.H - 2*weight}
	startDeg %= 360
	if startDeg < 0 {
		startDeg += 360
	}
	d0x, d0y := arcDir(startDeg)
	d1x, d1y := arcDir(startDeg + sweepDeg)
	full, wide := sweepDeg >= 360, sweepDeg > 180
	cx := int64(r.X)*8 + int64(r.W)*4
	cy := int64(r.Y)*8 + int64(r.H)*4
	x0, y0, x1, y1 := clipRect(c, r)
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			coverage := 0
			for _, sy := range offsets {
				for _, sx := range offsets {
					px, py := int64(x)*8+sx, int64(y)*8+sy
					if !inEllipse(px, py, r) || (stroke && inEllipse(px, py, inner)) {
						continue
					}
					if full || inWedge(px-cx, py-cy, d0x, d0y, d1x, d1y, wide) {
						coverage++
					}
				}
			}
			if coverage != 0 {
				i := y*c.W + x
				c.Pix[i] = blend(c.Pix[i], rgb, coverage)
			}
		}
	}
}

// FillArc fills the wedge of the ellipse inscribed in r, sweeping clockwise
// from startDeg through sweepDeg — the §2.5 wedge-gauge path.
func FillArc(c *BufferCanvas, r widgets.Rect, startDeg, sweepDeg int, rgb uint32) {
	arc(c, r, 0, startDeg, sweepDeg, rgb, false)
}

// StrokeArc strokes the same sweep as a weight-px annular band inside r —
// the §2.5 progress/volume ring. weight 0 draws nothing.
func StrokeArc(c *BufferCanvas, r widgets.Rect, weight, startDeg, sweepDeg int, rgb uint32) {
	arc(c, r, weight, startDeg, sweepDeg, rgb, true)
}
