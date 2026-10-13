package ttf

import "math"

// Coverage-antialiased rasterizing: flattened contours -> an 8-bit coverage
// mask -> a blend into a 32-bpp surface.
//
// The scanline sampler takes rasterSubRows sub-scanlines per pixel row and
// computes horizontal coverage exactly, so a glyph edge that lands between two
// pixels produces an intermediate alpha rather than a hard on/off step. Filling
// uses the TrueType non-zero winding rule, which is what makes self-overlapping
// outlines (o, e, 8) come out right.

// Mask is an anti-aliased glyph coverage bitmap in a top-down row order.
//
// Width/Height are the bitmap's extent. Alpha is row-major, Width*Height bytes,
// 0 = fully transparent, 255 = fully covered.
//
// BearingX is the left edge of the bitmap relative to the pen position (may be
// negative for an overhanging glyph). BearingY is the TOP edge of the bitmap
// relative to the baseline, measured upward, so a caller drawing with y growing
// downward places the first row at baselineY-BearingY.
type Mask struct {
	Width    int
	Height   int
	BearingX int
	BearingY int
	Alpha    []byte
}

// Empty reports whether the mask has no pixels to draw (an empty glyph, or one
// whose outline was outside the sane coordinate window).
func (m *Mask) Empty() bool {
	return m == nil || m.Width <= 0 || m.Height <= 0 || len(m.Alpha) < m.Width*m.Height
}

// rasterSubRows is the vertical sampling density. 4 sub-rows per pixel row is
// the point where a 12px stem's edges stop visibly stepping; the horizontal
// direction is computed exactly, so this is the only approximation.
const rasterSubRows = 4

// maskCoordLimit bounds a glyph bitmap's extent in pixels and its origin. A
// corrupt font can declare glyph coordinates in the millions; past this we
// return an empty mask instead of allocating.
const maskCoordLimit = 4096

// maxRasterPx caps the raster size. A 255px glyph is already larger than the
// guest's 512x384 window; the cap also keeps the cache key a single byte.
const maxRasterPx = 255

// flatTolerance is the maximum allowed deviation, in pixels, between a
// quadratic and the chords that replace it.
const flatTolerance = 0.08

type seg struct {
	x0, y0, x1, y1 float64
}

type crossing struct {
	x   float64
	dir int
}

// rasterize scans the flattened polylines into a coverage mask. Polylines are
// implicitly closed; a contour with fewer than three points contributes
// nothing.
func rasterize(polys [][]pointF) *Mask {
	if len(polys) == 0 {
		return &Mask{}
	}
	minX, minY := math.Inf(1), math.Inf(1)
	maxX, maxY := math.Inf(-1), math.Inf(-1)
	nseg := 0
	for _, p := range polys {
		if len(p) < 3 {
			continue
		}
		nseg += len(p)
		for _, q := range p {
			if q.x < minX {
				minX = q.x
			}
			if q.x > maxX {
				maxX = q.x
			}
			if q.y < minY {
				minY = q.y
			}
			if q.y > maxY {
				maxY = q.y
			}
		}
	}
	if nseg == 0 || math.IsInf(minX, 1) {
		return &Mask{}
	}
	x0 := int(math.Floor(minX))
	y0 := int(math.Floor(minY))
	x1 := int(math.Ceil(maxX))
	y1 := int(math.Ceil(maxY))
	if x1 <= x0 {
		x1 = x0 + 1
	}
	if y1 <= y0 {
		y1 = y0 + 1
	}
	if x0 < -maskCoordLimit || y0 < -maskCoordLimit || x1 > maskCoordLimit || y1 > maskCoordLimit {
		return &Mask{}
	}
	w, h := x1-x0, y1-y0
	if w <= 0 || h <= 0 || w > maskCoordLimit || h > maskCoordLimit {
		return &Mask{}
	}

	segs := make([]seg, 0, nseg)
	for _, p := range polys {
		if len(p) < 3 {
			continue
		}
		for i := range p {
			a := p[i]
			b := p[(i+1)%len(p)]
			if a.y == b.y {
				continue // horizontal edges never cross a scanline interior
			}
			segs = append(segs, seg{x0: a.x, y0: a.y, x1: b.x, y1: b.y})
		}
	}
	if len(segs) == 0 {
		return &Mask{}
	}

	acc := make([]int32, w*h)
	var cr []crossing
	for j := 0; j < h; j++ {
		rowOff := j * w
		for s := 0; s < rasterSubRows; s++ {
			ys := float64(y0) + float64(j) + (2*float64(s)+1)/(2*float64(rasterSubRows))
			cr = cr[:0]
			for _, sg := range segs {
				if (sg.y0 <= ys && sg.y1 > ys) || (sg.y1 <= ys && sg.y0 > ys) {
					t := (ys - sg.y0) / (sg.y1 - sg.y0)
					x := sg.x0 + t*(sg.x1-sg.x0)
					dir := 1
					if sg.y1 < sg.y0 {
						dir = -1
					}
					cr = append(cr, crossing{x: x, dir: dir})
				}
			}
			if len(cr) < 2 {
				continue
			}
			// Insertion sort: a glyph scanline has a handful of crossings.
			for i := 1; i < len(cr); i++ {
				c := cr[i]
				k := i - 1
				for k >= 0 && cr[k].x > c.x {
					cr[k+1] = cr[k]
					k--
				}
				cr[k+1] = c
			}
			wind := 0
			for k := 0; k < len(cr); k++ {
				wind += cr[k].dir
				if wind != 0 && k+1 < len(cr) {
					addSpan(acc, rowOff, w, cr[k].x-float64(x0), cr[k+1].x-float64(x0))
				}
			}
		}
	}

	full := int32(256 * rasterSubRows)
	m := &Mask{Width: w, Height: h, BearingX: x0, BearingY: -y0, Alpha: make([]byte, w*h)}
	any := false
	for i, a := range acc {
		if a <= 0 {
			continue
		}
		any = true
		if a >= full {
			m.Alpha[i] = 255
			continue
		}
		m.Alpha[i] = byte((a*255 + full/2) / full)
	}
	if !any {
		return &Mask{}
	}
	return m
}

// addSpan accumulates horizontal coverage for the span [ax,bx) measured from
// the left edge of the mask, in 1/256-pixel units per sub-row.
func addSpan(acc []int32, rowOff, w int, ax, bx float64) {
	if bx <= ax {
		return
	}
	if ax < 0 {
		ax = 0
	}
	if bx > float64(w) {
		bx = float64(w)
	}
	if bx <= ax {
		return
	}
	p := int(math.Floor(ax))
	last := int(math.Ceil(bx))
	for ; p < last; p++ {
		if p < 0 || p >= w {
			continue
		}
		left, right := float64(p), float64(p)+1
		lo, hi := ax, bx
		if left > lo {
			lo = left
		}
		if right < hi {
			hi = right
		}
		if hi > lo {
			acc[rowOff+p] += int32((hi-lo)*256 + 0.5)
		}
	}
}

// Linear-light coverage blending (M99o, #2192). Interpolating encoded sRGB
// channels weights dark destination text far too strongly — a half-covered
// stem edge over a light background comes out visibly darker than the ink the
// outline actually covers — so coverage is applied in linear light instead.
// The conversion is table-driven: a 256-entry sRGB->linear table at 12-bit
// precision, and a 4096-entry linear->sRGB table to encode the blend. The
// two tables cost ~4.6 KiB; the alternative (one gamma curve on coverage) is
// a contrast hack, not a blend, so the tables are the implementation.
var covS2L [256]uint16 // sRGB byte -> linear light, 0..4095
var covL2S [4096]uint8 // linear light 0..4095 -> sRGB byte

func init() {
	for i := range covS2L {
		v := float64(i) / 255
		l := v / 12.92
		if v > 0.04045 {
			l = math.Pow((v+0.055)/1.055, 2.4)
		}
		covS2L[i] = uint16(l*4095 + 0.5)
	}
	for i := range covL2S {
		l := float64(i) / 4095
		v := l * 12.92
		if l > 0.0031308 {
			v = 1.055*math.Pow(l, 1.0/2.4) - 0.055
		}
		covL2S[i] = uint8(v*255 + 0.5)
	}
}

// CoverageBlend composites src over dst weighted by 8-bit coverage a, in
// linear light, and is THE shared helper: every Go glyph-mask blend routes
// here (ttf.Blend, the draw BufferCanvas coverage path, and MaskSink
// implementations). dst is treated as opaque — the surfaces that call this
// are window back-buffers, and the result keeps the 0xff alpha byte the
// window format expects. a == 0 leaves dst untouched and a == 255 paints src
// exactly, so full-coverage pixels and untouched pixels never quantize.
func CoverageBlend(dst, src uint32, a uint8) uint32 {
	if a == 0 {
		return dst
	}
	rgb := src & 0xffffff
	if a == 255 {
		return 0xff000000 | rgb
	}
	ia := int32(255 - int32(a))
	sa := int32(a)
	blend := func(shift uint) uint32 {
		l := (int32(covS2L[(src>>shift)&0xff])*sa + int32(covS2L[(dst>>shift)&0xff])*ia + 127) / 255
		return uint32(covL2S[l]) << shift
	}
	return 0xff000000 | blend(16) | blend(8) | blend(0)
}

// Blend composites an 8-bit coverage mask into a 32-bpp surface.
//
// dst is the surface as 0xAARRGGBB words (in memory on the guest that is the
// window's B8G8R8X8 back-buffer, so the same word layout paints the same
// pixels), stride is the row stride in words, and the surface is w x h words.
// The mask is placed with its top-left corner at (x, y). Everything is clipped
// to the surface; an out-of-range placement is a no-op, never a panic.
//
// Coverage comes from the mask, so a partial pixel becomes a partial blend —
// this is the anti-aliasing, and it is why the glyph edge is smooth rather
// than stair-stepped. The blend itself is linear-light via CoverageBlend.
func Blend(dst []uint32, stride, w, h, x, y int, m *Mask, rgb uint32) {
	if m.Empty() || len(dst) == 0 || stride <= 0 || w <= 0 || h <= 0 || len(dst) < stride*h {
		return
	}
	for row := 0; row < m.Height; row++ {
		dy := y + row
		if dy < 0 || dy >= h {
			continue
		}
		base := dy * stride
		ra := m.Alpha[row*m.Width : (row+1)*m.Width]
		for col := 0; col < m.Width; col++ {
			a := ra[col]
			if a == 0 {
				continue
			}
			dx := x + col
			if dx < 0 || dx >= w {
				continue
			}
			i := base + dx
			if i >= len(dst) {
				continue
			}
			dst[i] = CoverageBlend(dst[i], rgb, a)
		}
	}
}
