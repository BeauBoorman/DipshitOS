package pdf

import (
	"math"
	"virelai/vector"
)

func (e *engine) image(n int, m vector.Affine, clip vector.Rect, paint bool, slot int) {
	v, start, length, stream := e.objectValue(n)
	if !stream || !e.named(e.get(v, "Type"), "XObject") || !e.named(e.get(v, "Subtype"), "Image") {
		e.set(UnsupportedFeature)
		return
	}
	e.allowed(v, "Type Subtype Width Height BitsPerComponent ColorSpace Decode Interpolate ImageMask Length Filter DecodeParms", UnsupportedImage)
	w, h := e.integer(e.get(v, "Width")), e.integer(e.get(v, "Height"))
	if w < 1 || h < 1 {
		e.set(Malformed)
		return
	}
	if w > 1024 || h > 1536 {
		e.set(CanvasLimit)
		return
	}
	if e.integer(e.get(v, "BitsPerComponent")) != 8 {
		e.set(UnsupportedImage)
		return
	}
	channels := 1
	cs := e.get(v, "ColorSpace")
	if e.named(cs, "DeviceRGB") {
		channels = 3
	} else if !e.named(cs, "DeviceGray") {
		e.set(UnsupportedImage)
		return
	}
	for _, key := range [2]string{"Interpolate", "ImageMask"} {
		if a := e.get(v, key); a.k != kBad && (a.k != kBool || a.n != 0) {
			e.set(UnsupportedImage)
			return
		}
	}
	if d := e.get(v, "Decode"); d.k != kBad {
		if d.k != kArray || int(d.count) != 2*channels {
			e.set(UnsupportedImage)
			return
		}
		i := e.iter(d)
		for j := 0; j < channels*2; j++ {
			a := i.next().val
			if a.k != kNumber || a.n != int64(j%2)*1e6 {
				e.set(UnsupportedImage)
			}
		}
	}
	if e.f.Code != OK {
		return
	}
	var x0, x1, y0, y1 int
	if paint {
		e.affine(m)
		if m.B != 0 || m.C != 0 || m.A == 0 || m.D == 0 {
			e.set(UnsupportedImage)
			return
		}
		a, b := e.mapped(m, vector.Point{}), e.mapped(m, vector.Point{X: 1, Y: 1})
		if a.X != math.Trunc(a.X) || a.Y != math.Trunc(a.Y) || b.X != math.Trunc(b.X) || b.Y != math.Trunc(b.Y) {
			e.set(UnsupportedImage)
			return
		}
		x0, x1 = int(min(a.X, b.X)), int(max(a.X, b.X))
		y0, y1 = int(min(a.Y, b.Y)), int(max(a.Y, b.Y))
		x0 = max(x0, clip.X0, 0)
		x1 = min(x1, clip.X1, int(e.state.page.width))
		y0 = max(y0, clip.Y0, 0)
		y1 = min(y1, clip.Y1, int(e.state.page.height))
	}
	// A4: a lone DCTDecode routes to the adapter's image-decoder hook; the
	// streaming path below still refuses it when no hook is installed.
	opened, dct := e.openDecoder(slot, n, true)
	if dct {
		e.dctImage(n, v, start, length, w, h, channels, m, x0, x1, y0, y1)
		return
	}
	if !opened {
		return
	}
	// The row lives in the unused portion of the fixed decode partition, not
	// a full-image allocation. A suspended content frame retains its window.
	row := e.arena[decodeEnd-3072 : decodeEnd]
	for sy := 0; sy < h && e.f.Code == OK; sy++ {
		for i := 0; i < w*channels; i++ {
			b, ok := e.decoded(slot)
			if !ok {
				e.set(MalformedStream)
				break
			}
			e.charge(Copy, 1)
			row[i] = b
		}
		if !paint || e.f.Code != OK {
			continue
		}
		// Source row zero is local y=1. Pixel-center nearest-neighbor ties go
		// to the higher index, including reflected axes.
		for y := y0; y < y1 && e.f.Code == OK; y++ {
			e.charge(Sample, 1)
			sourceY := int(math.Floor((1 - (float64(y)+0.5-m.F)/m.D) * float64(h)))
			sourceY = max(0, min(h-1, sourceY))
			if sourceY != sy {
				continue
			}
			for x := x0; x < x1 && e.f.Code == OK; x++ {
				e.charge(Sample, 1)
				sx := int(math.Floor((float64(x) + 0.5 - m.E) / m.A * float64(w)))
				sx = max(0, min(w-1, sx))
				e.charge(Examine, uint64(channels))
				r := uint32(row[sx*channels])
				g, b := r, r
				if channels == 3 {
					g = uint32(row[sx*3+1])
					b = uint32(row[sx*3+2])
				}
				if e.charge(Pixel, 1) {
					e.pix[y*int(e.state.page.width)+x] = 0xff000000 | r<<16 | g<<8 | b
				}
			}
		}
	}
	if e.f.Code == OK {
		if _, ok := e.decoded(slot); ok {
			e.set(MalformedStream)
		}
	}
	e.closeDecoder(slot)
}
