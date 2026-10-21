package webrender

import (
	"hash/crc32"

	"virelai/flate"
)

// pngenc.go is the owned PNG writer (issue #2976): 8-bit truecolor —
// colour type 2 (RGB), or type 6 (RGBA) when any pixel is not opaque —
// with filter Sub on every row, one IDAT, no interlace/palette/profile.
// The IDAT payload is flate.CompressZlib's zlib stream and chunk CRCs come
// from hash/crc32 (already guest-safe — user/go/fatimg builds on it).
// Every output decodes through DecodePNG; image/png stays a host-only test
// reference, never imported here.

// EncodePNG renders w×h 0xAARRGGBB pixels (the Image/doc word layout) as
// one PNG stream. It returns nil for impossible geometry.
func EncodePNG(pix []uint32, w, h int) []byte {
	if w <= 0 || h <= 0 || len(pix) < w*h {
		return nil
	}
	n := w * h
	channels := 3
	for i := 0; i < n; i++ {
		if pix[i]>>24 != 0xff {
			channels = 4
			break
		}
	}
	stride := w*channels + 1
	raw := make([]byte, stride*h)
	for y := 0; y < h; y++ {
		row := raw[y*stride : (y+1)*stride]
		row[0] = 1 // filter Sub: each byte minus its unfiltered left neighbour
		base := y * w
		for x := 0; x < w; x++ {
			p := pix[base+x]
			var q uint32 // the pixel to the left; the row head subtracts zero
			if x > 0 {
				q = pix[base+x-1]
			}
			o := 1 + x*channels
			row[o] = byte(p>>16) - byte(q>>16)
			row[o+1] = byte(p>>8) - byte(q>>8)
			row[o+2] = byte(p) - byte(q)
			if channels == 4 {
				row[o+3] = byte(p>>24) - byte(q>>24)
			}
		}
	}
	var ihdr [13]byte
	pngBe32(ihdr[0:4], uint32(w))
	pngBe32(ihdr[4:8], uint32(h))
	ihdr[8] = 8 // bit depth
	if channels == 4 {
		ihdr[9] = 6
	} else {
		ihdr[9] = 2
	}
	// ihdr[10] compression, [11] filter method, [12] interlace: all zero.
	idat := flate.CompressZlib(raw)
	out := make([]byte, 0, 8+12+len(ihdr)+12+len(idat)+12)
	out = append(out, pngMagic...)
	out = pngWriteChunk(out, "IHDR", ihdr[:])
	out = pngWriteChunk(out, "IDAT", idat)
	return pngWriteChunk(out, "IEND", nil)
}

// pngWriteChunk appends one framed chunk: BE length, the four-letter name, the
// body, and the IEEE CRC-32 over name+body.
func pngWriteChunk(out []byte, name string, body []byte) []byte {
	var lb [4]byte
	pngBe32(lb[:], uint32(len(body)))
	out = append(out, lb[:]...)
	crc := crc32.NewIEEE()
	crc.Write([]byte(name))
	crc.Write(body)
	out = append(out, name...)
	out = append(out, body...)
	pngBe32(lb[:], crc.Sum32())
	return append(out, lb[:]...)
}

func pngBe32(dst []byte, v uint32) {
	dst[0] = byte(v >> 24)
	dst[1] = byte(v >> 16)
	dst[2] = byte(v >> 8)
	dst[3] = byte(v)
}
