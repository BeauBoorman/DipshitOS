package webrender

import (
	"virelai/flate"
	"virelai/webstyle"
)

const maxPNGScanlines = 1_049_600
const maxPNGChunks = 256

type imageError string

func (e imageError) Error() string { return string(e) }

const (
	errPNGInvalid = imageError("image-invalid: png")
	errPNGLimit   = imageError("image-limit: png")
)

// DecodePNG implements ADR 0028 Amendment D: non-interlaced, 8-bit PNG
// types 0/2/3/4/6, straight RGBA8, no profile/gamma transformation.
// All allocation sizes are validated before allocating. The host and guest
// use this same decoder; image/png is only a host test reference.
func DecodePNG(data []byte) (*Image, error) {
	if len(data) > webstyle.MaxImageBytes {
		return nil, errPNGLimit
	}
	if len(data) < 8 || string(data[:8]) != string(pngMagic) {
		return nil, errPNGInvalid
	}
	var w, h, channels int
	var typ byte
	var palette []byte
	var transparency []byte
	var compressed []byte
	header, seenPalette, seenTRNS, seenIDAT, endedIDAT := false, false, false, false, false
	pos, chunks := 8, 0
	for pos < len(data) {
		chunks++
		if chunks > maxPNGChunks {
			return nil, errPNGLimit
		}
		if len(data)-pos < 12 {
			return nil, errPNGInvalid
		}
		n := uint64(be32b(data[pos : pos+4]))
		if n > uint64(len(data)-pos-12) {
			return nil, errPNGInvalid
		}
		end := pos + 8 + int(n)
		name := string(data[pos+4 : pos+8])
		for _, c := range data[pos+4 : pos+8] {
			if c < 'A' || c > 'Z' && c < 'a' || c > 'z' {
				return nil, errPNGInvalid
			}
		}
		if data[pos+6]&0x20 != 0 || pngCRC(data[pos+4:end]) != be32b(data[end:end+4]) {
			return nil, errPNGInvalid
		}
		body := data[pos+8 : end]
		pos = end + 4
		if !header && name != "IHDR" {
			return nil, errPNGInvalid
		}
		if seenIDAT && name != "IDAT" {
			endedIDAT = true
		}
		switch name {
		case "IHDR":
			if header || len(body) != 13 {
				return nil, errPNGInvalid
			}
			header = true
			width, height := uint64(be32b(body[:4])), uint64(be32b(body[4:8]))
			if width == 0 || height == 0 {
				return nil, errPNGInvalid
			}
			if width > webstyle.MaxImageDimension || height > webstyle.MaxImageDimension ||
				width*height > webstyle.MaxImagePixels || width*height*4 > webstyle.MaxDecodedImageBytes {
				return nil, errPNGLimit
			}
			w, h, typ = int(width), int(height), body[9]
			switch typ {
			case 0, 3:
				channels = 1
			case 2:
				channels = 3
			case 4:
				channels = 2
			case 6:
				channels = 4
			default:
				return nil, errPNGInvalid
			}
			if body[10] != 0 || body[11] != 0 || body[12] > 1 {
				return nil, errPNGInvalid
			}
			if body[8] != 8 || body[12] != 0 {
				return nil, ErrImageUnsupported
			}
		case "PLTE":
			if seenPalette || seenTRNS || seenIDAT || typ == 0 || typ == 4 ||
				len(body) == 0 || len(body)%3 != 0 || len(body) > 768 {
				return nil, errPNGInvalid
			}
			seenPalette, palette = true, body
		case "tRNS":
			if seenTRNS || seenIDAT {
				return nil, errPNGInvalid
			}
			switch typ {
			case 0:
				if len(body) != 2 || body[0] != 0 {
					return nil, errPNGInvalid
				}
			case 2:
				if len(body) != 6 || body[0] != 0 || body[2] != 0 || body[4] != 0 {
					return nil, errPNGInvalid
				}
			case 3:
				if !seenPalette || len(body) == 0 || len(body) > len(palette)/3 {
					return nil, errPNGInvalid
				}
			default:
				return nil, errPNGInvalid
			}
			seenTRNS, transparency = true, body
		case "IDAT":
			if endedIDAT || typ == 3 && !seenPalette {
				return nil, errPNGInvalid
			}
			seenIDAT = true
			compressed = append(compressed, body...)
		case "IEND":
			if len(body) != 0 || !seenIDAT || pos != len(data) {
				return nil, errPNGInvalid
			}
			return pngPixels(w, h, typ, channels, palette, transparency, compressed)
		case "acTL", "fcTL", "fdAT":
			return nil, ErrImageUnsupported
		default:
			if name[0]&0x20 == 0 {
				return nil, ErrImageUnsupported
			}
		}
	}
	return nil, errPNGInvalid
}

func pngPixels(w, h int, typ byte, channels int, palette, transparency, compressed []byte) (*Image, error) {
	stride := w*channels + 1
	n := stride * h
	if n > maxPNGScanlines {
		return nil, errPNGLimit
	}
	rows := make([]byte, n)
	written, consumed, err := flate.InflateZlib(rows, compressed)
	if err != nil || written != n || consumed != len(compressed) {
		return nil, errPNGInvalid
	}
	out := &Image{Width: w, Height: h, Pix: make([]uint32, w*h), png: true}
	var previous []byte
	for y := 0; y < h; y++ {
		filter := rows[y*stride]
		row := rows[y*stride+1 : (y+1)*stride]
		if filter > 4 {
			return nil, errPNGInvalid
		}
		for i := range row {
			var a, b, c byte
			if i >= channels {
				a = row[i-channels]
			}
			if previous != nil {
				b = previous[i]
				if i >= channels {
					c = previous[i-channels]
				}
			}
			switch filter {
			case 1:
				row[i] += a
			case 2:
				row[i] += b
			case 3:
				row[i] += byte((int(a) + int(b)) / 2)
			case 4:
				row[i] += pngPaeth(a, b, c)
			}
		}
		for x := 0; x < w; x++ {
			p := row[x*channels : (x+1)*channels]
			r, g, b, a := p[0], p[0], p[0], byte(255)
			switch typ {
			case 0:
				if len(transparency) != 0 && r == transparency[1] {
					a = 0
				}
			case 2:
				g, b = p[1], p[2]
				if len(transparency) != 0 && r == transparency[1] && g == transparency[3] && b == transparency[5] {
					a = 0
				}
			case 3:
				index := int(p[0])
				if index >= len(palette)/3 {
					return nil, errPNGInvalid
				}
				r, g, b = palette[index*3], palette[index*3+1], palette[index*3+2]
				if index < len(transparency) {
					a = transparency[index]
				}
			case 4:
				a = p[1]
			case 6:
				g, b, a = p[1], p[2], p[3]
			}
			out.Pix[y*w+x] = uint32(a)<<24 | uint32(r)<<16 | uint32(g)<<8 | uint32(b)
		}
		previous = row
	}
	return out, nil
}

func pngPaeth(a, b, c byte) byte {
	p := int(a) + int(b) - int(c)
	pa, pb, pc := absPNG(p-int(a)), absPNG(p-int(b)), absPNG(p-int(c))
	if pa <= pb && pa <= pc {
		return a
	}
	if pb <= pc {
		return b
	}
	return c
}

func absPNG(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

func pngCRC(data []byte) uint32 {
	crc := uint32(0xffffffff)
	for _, b := range data {
		crc ^= uint32(b)
		for i := 0; i < 8; i++ {
			mask := uint32(0) - (crc & 1)
			crc = crc>>1 ^ 0xedb88320&mask
		}
	}
	return ^crc
}
