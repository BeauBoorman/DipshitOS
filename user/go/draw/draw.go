// Package draw rasterizes small UI shapes into caller-owned 0xAARRGGBB pixels.
// Coordinates are integer pixel edges; coverage uses a fixed 4x4 subpixel grid.
// No drawing operation allocates, and all writes are clipped to the canvas.
package draw

import "virelai/widgets"

type Point struct{ X, Y int }

// BufferCanvas is a row-major, W-stride surface owned by the caller.
// The clip stack is a fixed array (depth.go): the zero value clips to the
// whole canvas.
type BufferCanvas struct {
	Pix  []uint32
	W, H int

	clips [ClipDepth]widgets.Rect
	depth int
}

const samples = 16

var offsets = [4]int64{1, 3, 5, 7} // eighths of a pixel

func valid(c *BufferCanvas) bool {
	return c != nil && c.W > 0 && c.H > 0 && c.W <= len(c.Pix)/c.H
}

// clipRange intersects [origin, origin+size) with [lo, hi) without
// overflowing on an off-screen origin or a very large requested size.
// An empty intersection returns (0, 0).
func clipRange(origin, size, lo, hi int) (int, int) {
	if size <= 0 || lo >= hi || origin >= hi {
		return 0, 0
	}
	start := max(origin, lo)
	end := min(saturatingAdd(origin, size), hi)
	if end <= start {
		return 0, 0
	}
	return start, end
}

// clipRect intersects r with the §3.3.4 paint region — the active clip
// stack intersected with canvas bounds.
func clipRect(c *BufferCanvas, r widgets.Rect) (x0, y0, x1, y1 int) {
	cl := activeClip(c)
	x0, x1 = clipRange(r.X, r.W, cl.X, cl.Right())
	y0, y1 = clipRange(r.Y, r.H, cl.Y, cl.Bottom())
	return
}

// blend implements straight-alpha source-over without gamma correction.
// Coverage scales the source alpha; the destination RGB is weighted by its
// own alpha so translucent surfaces do not accumulate dark fringes.
func blend(dst, rgb uint32, coverage int) uint32 {
	sa := int((rgb>>24)&255) * coverage / samples
	if sa == 0 {
		return dst
	}
	if sa == 255 {
		return rgb
	}
	da := int(dst >> 24)
	den := sa*255 + da*(255-sa)
	if den == 0 {
		return 0
	}
	channel := func(shift uint) uint32 {
		sc := int((rgb >> shift) & 255)
		dc := int((dst >> shift) & 255)
		return uint32((sc*sa*255 + dc*da*(255-sa) + den/2) / den)
	}
	return uint32((den+127)/255)<<24 | channel(16)<<16 | channel(8)<<8 | channel(0)
}

// BlendPixel composites one pixel with the color's alpha. Alpha zero is a
// no-op, including over a transparent destination.
func BlendPixel(c *BufferCanvas, x, y int, rgb uint32) {
	if !valid(c) {
		return
	}
	cl := activeClip(c)
	if x < cl.X || y < cl.Y || x >= cl.Right() || y >= cl.Bottom() {
		return
	}
	i := y*c.W + x
	c.Pix[i] = blend(c.Pix[i], rgb, samples)
}

// BlitTinted uses only src's alpha as a mask; the tint supplies RGB and alpha.
// The source and destination should not overlap in memory.
func BlitTinted(c *BufferCanvas, src *BufferCanvas, x, y int, rgb uint32) {
	if !valid(c) || !valid(src) || rgb>>24 == 0 {
		return
	}
	cl := activeClip(c)
	x0, x1 := clipRange(x, src.W, cl.X, cl.Right())
	y0, y1 := clipRange(y, src.H, cl.Y, cl.Bottom())
	for dy := y0; dy < y1; dy++ {
		for dx := x0; dx < x1; dx++ {
			alpha := int(src.Pix[(dy-y)*src.W+dx-x] >> 24)
			if alpha == 0 {
				continue
			}
			i := dy*c.W + dx
			tint := rgb&0xffffff | uint32((int(rgb>>24)*alpha+127)/255)<<24
			c.Pix[i] = blend(c.Pix[i], tint, samples)
		}
	}
}

// FillRect paints an axis-aligned rectangle, clipping before touching a row.
func FillRect(c *BufferCanvas, r widgets.Rect, rgb uint32) {
	if !valid(c) || rgb>>24 == 0 {
		return
	}
	x0, y0, x1, y1 := clipRect(c, r)
	if rgb>>24 == 255 {
		for y := y0; y < y1; y++ {
			row := c.Pix[y*c.W+x0 : y*c.W+x1]
			for i := range row {
				row[i] = rgb
			}
		}
		return
	}
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			i := y*c.W + x
			c.Pix[i] = blend(c.Pix[i], rgb, samples)
		}
	}
}

func clamp(v, low, high int) int {
	if v < low {
		return low
	}
	if v > high {
		return high
	}
	return v
}

func saturatingAdd(a, b int) int {
	const maxInt = int(^uint(0) >> 1)
	const minInt = -maxInt - 1
	if b > 0 && a > maxInt-b {
		return maxInt
	}
	if b < 0 && a < minInt-b {
		return minInt
	}
	return a + b
}

// inRounded mirrors the Zig quarter-circle layout: a full center column,
// full side waists, then four symmetric corner sectors. Unlike Zig's
// truncated isqrt edge alpha, each sector has 16 coverage samples.
func inRounded(px, py int64, r widgets.Rect, radius int) bool {
	x, y := px-int64(r.X)*8, py-int64(r.Y)*8
	w, h := int64(r.W)*8, int64(r.H)*8
	if x < 0 || y < 0 || x >= w || y >= h {
		return false
	}
	rr := int64(radius) * 8
	if rr == 0 || x >= rr && x < w-rr || y >= rr && y < h-rr {
		return true
	}
	cx, cy := rr, rr
	if x >= w-rr {
		cx = w - rr
	}
	if y >= h-rr {
		cy = h - rr
	}
	dx, dy := x-cx, y-cy
	return dx*dx+dy*dy <= rr*rr
}

// FillRoundedRect clamps radius to half the shorter side. Integer-aligned
// radius zero is exactly FillRect, including its opaque fast path.
func FillRoundedRect(c *BufferCanvas, r widgets.Rect, radius int, rgb uint32) {
	if !valid(c) || r.W <= 0 || r.H <= 0 || rgb>>24 == 0 {
		return
	}
	radius = clamp(radius, 0, min(r.W, r.H)/2)
	if radius == 0 {
		FillRect(c, r, rgb)
		return
	}
	x0, y0, x1, y1 := clipRect(c, r)
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			// Interior spans cost one blend, not 16 circle tests.
			if x >= r.X+radius && x < r.X+r.W-radius ||
				y >= r.Y+radius && y < r.Y+r.H-radius {
				i := y*c.W + x
				c.Pix[i] = blend(c.Pix[i], rgb, samples)
				continue
			}
			coverage := 0
			for _, sy := range offsets {
				for _, sx := range offsets {
					if inRounded(int64(x)*8+sx, int64(y)*8+sy, r, radius) {
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

// StrokeRoundedRect draws the difference of the outer and inset silhouettes.
// The inset uses radius-weight; when it is empty the stroke covers the fill.
func StrokeRoundedRect(c *BufferCanvas, r widgets.Rect, radius, weight int, rgb uint32) {
	if !valid(c) || r.W <= 0 || r.H <= 0 || weight <= 0 || rgb>>24 == 0 {
		return
	}
	radius = clamp(radius, 0, min(r.W, r.H)/2)
	weight = clamp(weight, 0, min(r.W, r.H))
	inner := widgets.Rect{X: r.X + weight, Y: r.Y + weight, W: r.W - 2*weight, H: r.H - 2*weight}
	ir := max(0, radius-weight)
	x0, y0, x1, y1 := clipRect(c, r)
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			coverage := 0
			for _, sy := range offsets {
				for _, sx := range offsets {
					px, py := int64(x)*8+sx, int64(y)*8+sy
					if inRounded(px, py, r, radius) && !inRounded(px, py, inner, ir) {
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

// inEllipse tests the implicit ellipse at eighth-pixel sample coordinates.
// The rect's exclusive edges bound the ellipse, so a circle is a square rect.
func inEllipse(px, py int64, r widgets.Rect) bool {
	if r.W <= 0 || r.H <= 0 {
		return false
	}
	w, h := int64(r.W), int64(r.H)
	dx := px - int64(r.X)*8 - 4*w
	dy := py - int64(r.Y)*8 - 4*h
	return dx*dx*h*h+dy*dy*w*w <= 16*w*w*h*h
}

func ellipse(c *BufferCanvas, r widgets.Rect, weight int, rgb uint32, stroke bool) {
	if !valid(c) || r.W <= 0 || r.H <= 0 || rgb>>24 == 0 || stroke && weight <= 0 {
		return
	}
	weight = clamp(weight, 0, min(r.W, r.H))
	inner := widgets.Rect{X: r.X + weight, Y: r.Y + weight, W: r.W - 2*weight, H: r.H - 2*weight}
	x0, y0, x1, y1 := clipRect(c, r)
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			coverage := 0
			for _, sy := range offsets {
				for _, sx := range offsets {
					px, py := int64(x)*8+sx, int64(y)*8+sy
					if inEllipse(px, py, r) && (!stroke || !inEllipse(px, py, inner)) {
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

// FillEllipse fills the ellipse inscribed in r (a circle when W == H).
func FillEllipse(c *BufferCanvas, r widgets.Rect, rgb uint32) {
	ellipse(c, r, 0, rgb, false)
}

// StrokeEllipse draws a weight-pixel inset elliptical ring.
func StrokeEllipse(c *BufferCanvas, r widgets.Rect, weight int, rgb uint32) {
	ellipse(c, r, weight, rgb, true)
}

// insidePolygon uses the even-odd rule and half-open edges. A fixed-size
// subpixel loop needs no edge list or per-pixel mask, even for concave shapes.
func insidePolygon(px, py int64, pts []Point) bool {
	inside := false
	prev := pts[len(pts)-1]
	for _, next := range pts {
		ax, ay := int64(prev.X)*8, int64(prev.Y)*8
		bx, by := int64(next.X)*8, int64(next.Y)*8
		if (ay <= py && py < by) || (by <= py && py < ay) {
			lhs := (px - ax) * (by - ay)
			rhs := (py - ay) * (bx - ax)
			if by > ay && lhs < rhs || by < ay && lhs > rhs {
				inside = !inside
			}
		}
		prev = next
	}
	return inside
}

// FillPolygon fills a closed, even-odd polygon. Scratch is constant-size
// (zero scanline buffers); complexity is bounded by visible pixels * vertices.
func FillPolygon(c *BufferCanvas, pts []Point, rgb uint32) {
	if !valid(c) || len(pts) < 3 || rgb>>24 == 0 {
		return
	}
	minX, maxX, minY, maxY := pts[0].X, pts[0].X, pts[0].Y, pts[0].Y
	for _, p := range pts[1:] {
		minX, maxX = min(minX, p.X), max(maxX, p.X)
		minY, maxY = min(minY, p.Y), max(maxY, p.Y)
	}
	cl := activeClip(c)
	x0, x1 := max(cl.X, minX), min(cl.Right(), maxX)
	y0, y1 := max(cl.Y, minY), min(cl.Bottom(), maxY)
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			coverage := 0
			for _, sy := range offsets {
				for _, sx := range offsets {
					if insidePolygon(int64(x)*8+sx, int64(y)*8+sy, pts) {
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

// onSegment tests a round-capped stroke about pixel-center endpoints.
// The projection is clamped to the segment; the zero-length case is a disk.
func onSegment(px, py int64, a, b Point, weight int) bool {
	ax, ay := int64(a.X)*8+4, int64(a.Y)*8+4
	bx, by := int64(b.X)*8+4, int64(b.Y)*8+4
	vx, vy := bx-ax, by-ay
	ux, uy := px-ax, py-ay
	r := int64(weight) * 4
	len2 := vx*vx + vy*vy
	dot := ux*vx + uy*vy
	switch {
	case dot <= 0 || len2 == 0:
		return ux*ux+uy*uy <= r*r
	case dot >= len2:
		dx, dy := px-bx, py-by
		return dx*dx+dy*dy <= r*r
	default:
		cross := ux*vy - uy*vx
		return cross*cross <= r*r*len2
	}
}

func strokeSegments(c *BufferCanvas, pts []Point, weight int, rgb uint32) {
	if !valid(c) || len(pts) < 2 || weight <= 0 || rgb>>24 == 0 {
		return
	}
	// A line has no enclosing rect to clamp against; the canvas is its
	// finite painting bound. Samples union all segments before blending, so
	// a joint does not get darker when two translucent strokes meet.
	weight = min(weight, min(c.W, c.H))
	minX, maxX, minY, maxY := pts[0].X, pts[0].X, pts[0].Y, pts[0].Y
	for _, p := range pts[1:] {
		minX, maxX = min(minX, p.X), max(maxX, p.X)
		minY, maxY = min(minY, p.Y), max(maxY, p.Y)
	}
	pad := weight/2 + 1
	cl := activeClip(c)
	x0, x1 := max(cl.X, saturatingAdd(minX, -pad)), min(cl.Right(), saturatingAdd(maxX, pad+1))
	y0, y1 := max(cl.Y, saturatingAdd(minY, -pad)), min(cl.Bottom(), saturatingAdd(maxY, pad+1))
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			coverage := 0
			for _, sy := range offsets {
				for _, sx := range offsets {
					px, py := int64(x)*8+sx, int64(y)*8+sy
					for i := 1; i < len(pts); i++ {
						if onSegment(px, py, pts[i-1], pts[i], weight) {
							coverage++
							break
						}
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

// StrokePolyline draws connected, round-capped segments; joints are a union.
func StrokePolyline(c *BufferCanvas, pts []Point, weight int, rgb uint32) {
	strokeSegments(c, pts, weight, rgb)
}

// StrokeLine draws one round-capped segment, symmetric about its centerline.
func StrokeLine(c *BufferCanvas, x0, y0, x1, y1, weight int, rgb uint32) {
	pts := [2]Point{{x0, y0}, {x1, y1}}
	strokeSegments(c, pts[:], weight, rgb)
}
