// Package qoi decodes "Quite OK Image" rasters into 0xAARRGGBB words,
// row-major — the same layout webrender surfaces and the seat's scanout
// words use. It is the leaf factored out of virelai/webrender's DecodeImage
// (M-launcher, #2054) so a guest that paints one emblem — the Go seat's
// launcher — links a hundred-line decoder rather than the layout engine.
// The webrender package delegates to this; the decode itself is unchanged.
package qoi

import "errors"

// Magic is the four-byte tag a QOI stream opens with.
const Magic = "qoif"

// Decode reads one QOI stream. maxDim bounds either axis and maxPixels bounds
// w*h — the caller names its own budget, so a hostile or fat-fingered header
// is refused before the raster allocates. pix is one 0xAARRGGBB word per
// pixel, row-major.
func Decode(data []byte, maxDim, maxPixels int) (w, h int, pix []uint32, err error) {
	if len(data) < 14 {
		return 0, 0, nil, errors.New("qoi: header truncated")
	}
	if string(data[:4]) != Magic {
		return 0, 0, nil, errors.New("qoi: bad magic")
	}
	w = int(be32(data[4:8]))
	h = int(be32(data[8:12]))
	if w <= 0 || h <= 0 || w > maxDim || h > maxDim || w*h > maxPixels {
		return 0, 0, nil, errors.New("qoi: geometry rejected")
	}
	pix = make([]uint32, w*h)

	var index [64]uint32
	var px uint32 = 0xff000000
	p := 14
	n := w * h
	i := 0
	for i < n {
		if p >= len(data) {
			return 0, 0, nil, errors.New("qoi: stream truncated")
		}
		b1 := data[p]
		p++
		switch {
		case b1 == 0xfe: // QOI_OP_RGB
			if p+3 > len(data) {
				return 0, 0, nil, errors.New("qoi: rgb truncated")
			}
			px = 0xff000000 | uint32(data[p])<<16 | uint32(data[p+1])<<8 | uint32(data[p+2])
			p += 3
		case b1 == 0xff: // QOI_OP_RGBA
			if p+4 > len(data) {
				return 0, 0, nil, errors.New("qoi: rgba truncated")
			}
			// Spec order is R,G,B,A — the alpha byte is the LAST of the
			// four. (This read A,R,G,B until #2986's encoder promotion made
			// the asymmetry round-trip-visible; every opaque fixture hid it.)
			px = uint32(data[p+3])<<24 | uint32(data[p])<<16 | uint32(data[p+1])<<8 | uint32(data[p+2])
			p += 4
		case b1>>6 == 0: // QOI_OP_INDEX
			px = index[b1&63]
		case b1>>6 == 1: // QOI_OP_DIFF
			dr := int((b1>>4)&3) - 2
			dg := int((b1>>2)&3) - 2
			db := int(b1&3) - 2
			px = delta(px, dr, dg, db)
		case b1>>6 == 2: // QOI_OP_LUMA
			if p >= len(data) {
				return 0, 0, nil, errors.New("qoi: luma truncated")
			}
			b2 := data[p]
			p++
			vg := int(b1&0x3f) - 32
			px = delta(px, int(b2>>4)-8+vg, vg, int(b2&0x0f)-8+vg)
		default: // QOI_OP_RUN
			run := int(b1&0x3f) + 1
			// A run may span the end of the buffer only if the file is
			// malformed; clamp rather than write past the image.
			if i+run > n {
				run = n - i
			}
			for k := 0; k < run; k++ {
				pix[i] = px
				i++
			}
			index[Hash(px)] = px
			continue
		}
		pix[i] = px
		index[Hash(px)] = px
		i++
	}
	return w, h, pix, nil
}

// Hash is the format's 6-bit index hash. The mask is not optional: the
// index table has 64 slots and the raw sum overruns it immediately (the
// first swatch colour hashes to 1043), which panics the guest.
func Hash(px uint32) uint32 {
	return ((px>>16&0xff)*3 + (px>>8&0xff)*5 + (px&0xff)*7) & 63
}

func delta(px uint32, dr, dg, db int) uint32 {
	r := int(px>>16&0xff) + dr
	g := int(px>>8&0xff) + dg
	b := int(px&0xff) + db
	return px&0xff000000 | uint32(clamp8(r))<<16 | uint32(clamp8(g))<<8 | uint32(clamp8(b))
}

func clamp8(v int) int {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return v
}

func be32(b []byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}
