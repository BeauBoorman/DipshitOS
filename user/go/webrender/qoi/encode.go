// encode.go is the write direction of the QOI codec (issue #2986): the
// encoder GOPAINT carried privately as qoienc.go since M141a, promoted next
// to Decode so every guest encodes through one owned implementation —
// GOVIEW's save-as is the second caller. The op selection is the format's
// standard ladder — run, index, diff, luma, rgb, rgba — so the bytes are
// deterministic, GOPAINT's saved files are unchanged by the move, and every
// conforming decoder (ours included) round-trips them.
package qoi

// Encode renders w×h 0xAARRGGBB pixels as one QOI stream (channels=4,
// colorspace=0). The capacity hint is the encoder's worst-case bound plus
// header and trailer; the return is the real length's prefix.
func Encode(pix []uint32, w, h int) []byte {
	if w <= 0 || h <= 0 || len(pix) < w*h {
		return nil
	}
	out := make([]byte, 0, 14+w*h*5+8)
	out = append(out, 'q', 'o', 'i', 'f')
	be := func(v uint32) {
		out = append(out, byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
	}
	be(uint32(w))
	be(uint32(h))
	out = append(out, 4, 0) // channels=RGBA, colorspace=sRGB

	var index [64]uint32
	prev := uint32(0xff000000)
	run := 0
	n := w * h
	for i := 0; i < n; i++ {
		px := pix[i]
		if px == prev {
			run++
			if run == 62 || i == n-1 {
				out = append(out, 0xc0|byte(run-1))
				run = 0
			}
			continue
		}
		if run > 0 {
			out = append(out, 0xc0|byte(run-1))
			run = 0
		}
		hh := Hash(px)
		if index[hh] == px {
			out = append(out, byte(hh)) // QOI_OP_INDEX
			prev = px
			continue
		}
		index[hh] = px
		r := int(px>>16) & 0xff
		g := int(px>>8) & 0xff
		b := int(px) & 0xff
		a := int(px>>24) & 0xff
		pa := int(prev>>24) & 0xff
		if a != pa {
			out = append(out, 0xff, byte(r), byte(g), byte(b), byte(a))
			prev = px
			continue
		}
		dr := r - (int(prev>>16) & 0xff)
		dg := g - (int(prev>>8) & 0xff)
		db := b - (int(prev) & 0xff)
		switch {
		case dr >= -2 && dr <= 1 && dg >= -2 && dg <= 1 && db >= -2 && db <= 1:
			out = append(out, 0x40|byte(dr+2)<<4|byte(dg+2)<<2|byte(db+2))
		default:
			drg, dbg := dr-dg, db-dg
			if dg >= -32 && dg <= 31 && drg >= -8 && drg <= 7 && dbg >= -8 && dbg <= 7 {
				out = append(out, 0x80|byte(dg+32), byte(drg+8)<<4|byte(dbg+8))
			} else {
				out = append(out, 0xfe, byte(r), byte(g), byte(b))
			}
		}
		prev = px
	}
	out = append(out, 0, 0, 0, 0, 0, 0, 0, 1)
	return out
}
