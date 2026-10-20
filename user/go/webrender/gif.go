package webrender

import (
	"virelai/webstyle"
)

// In-guest GIF (M136c): GIF87a/GIF89a first frame — the logical screen
// descriptor, the global and local color tables, the first graphic control
// extension's transparency, LZW data (2–8 bit literal widths, deferred
// clear, the KwKwK case) and interlaced frames, bounded by the same pixel
// and byte budgets as the PNG decoder. Later frames are skipped and
// counted, never decoded; Image.Frames reports the total. There is no
// resync — corrupt input refuses as image-invalid: gif instead of being
// recovered, an oversized screen as image-limit: gif. An out-of-range LZW
// literal width refuses by name (gifUnsupported, which matches
// ErrImageUnsupported). The host and guest use this same decoder;
// image/gif is only a host test reference.

const (
	errGIFInvalid = imageError("image-invalid: gif")
	errGIFLimit   = imageError("image-limit: gif")
)

// gifUnsupported is a named refusal for a GIF variant this decoder does not
// handle: "image-gif-unsupported-<kind>". It still IS an
// ErrImageUnsupported, so a viewer reports the format as unsupported rather
// than as corrupt bytes.
type gifUnsupported string

func (e gifUnsupported) Error() string { return "image-gif-unsupported-" + string(e) }

// Is reports the refusal as ErrImageUnsupported for errors.Is.
func (e gifUnsupported) Is(t error) bool { return t == ErrImageUnsupported }

// GIF section indicators, extension labels and descriptor field masks.
const (
	gifExtIntroducer = 0x21
	gifImageDesc     = 0x2c
	gifTrailer       = 0x3b

	gifExtGraphicControl = 0xf9

	gifFieldColorTable = 1 << 7
	gifFieldInterlace  = 1 << 6
	gifFieldTableBits  = 7

	gifGCETransparent = 1 << 0
)

// gifInterlace is the four-pass row order of an interlaced frame.
var gifInterlace = [4][2]int{{8, 0}, {8, 4}, {4, 2}, {2, 1}}

// decodeGIF decodes data as a GIF: the first image descriptor's frame is
// returned, later frames are skipped and counted. The logical screen
// bounds the frame and carries the size cap; the returned Image is the
// frame's own rectangle (mirroring host image/gif's Decode), while
// GOVIEW's header sniff reads the screen size.
func decodeGIF(data []byte) (*Image, error) {
	if len(data) > webstyle.MaxImageBytes {
		return nil, errGIFLimit
	}
	if len(data) < 13 {
		return nil, errGIFInvalid
	}
	if v := string(data[:6]); v != "GIF87a" && v != "GIF89a" {
		return nil, errGIFInvalid
	}
	w := int(data[6]) | int(data[7])<<8
	h := int(data[8]) | int(data[9])<<8
	if w == 0 || h == 0 {
		return nil, errGIFInvalid
	}
	if w > webstyle.MaxImageDimension || h > webstyle.MaxImageDimension ||
		w*h > maxImagePixels {
		return nil, errGIFLimit
	}
	pos := 13
	var gct []uint32
	if data[10]&gifFieldColorTable != 0 {
		var ok bool
		if gct, pos, ok = gifColorTable(data, pos, data[10]); !ok {
			return nil, errGIFInvalid
		}
	}

	var im *Image
	frames := 0
	transparent := -1 // pending transparent index from the latest GCE

	for pos < len(data) {
		switch data[pos] {
		case gifTrailer:
			if im == nil {
				return nil, errGIFInvalid // no image before the trailer
			}
			im.Frames = frames
			return im, nil
		case gifExtIntroducer:
			pos++
			if pos >= len(data) {
				goto done
			}
			label := data[pos]
			pos++
			if label == gifExtGraphicControl {
				if pos+6 > len(data) || data[pos] != 4 || data[pos+5] != 0 {
					if im == nil {
						return nil, errGIFInvalid
					}
					goto done
				}
				if data[pos+1]&gifGCETransparent != 0 {
					transparent = int(data[pos+4])
				}
				pos += 6
			} else {
				var ok bool
				if pos, ok = gifSkipBlocks(data, pos); !ok {
					if im == nil {
						return nil, errGIFInvalid
					}
					goto done
				}
			}
		case gifImageDesc:
			pos++
			if pos+9 > len(data) {
				if im == nil {
					return nil, errGIFInvalid
				}
				goto done
			}
			left := int(data[pos]) | int(data[pos+1])<<8
			top := int(data[pos+2]) | int(data[pos+3])<<8
			fw := int(data[pos+4]) | int(data[pos+5])<<8
			fh := int(data[pos+6]) | int(data[pos+7])<<8
			fields := data[pos+8]
			// The frame must fit inside the logical screen.
			if left+fw > w || top+fh > h {
				if im == nil {
					return nil, errGIFInvalid
				}
				goto done
			}
			pos += 9
			pal := gct
			if fields&gifFieldColorTable != 0 {
				var ok bool
				if pal, pos, ok = gifColorTable(data, pos, fields); !ok {
					if im == nil {
						return nil, errGIFInvalid
					}
					goto done
				}
			}
			if len(pal) == 0 {
				if im == nil {
					return nil, errGIFInvalid // no color table
				}
				goto done
			}
			if pos >= len(data) {
				if im == nil {
					return nil, errGIFInvalid
				}
				goto done
			}
			litWidth := int(data[pos])
			pos++
			if frames == 0 {
				if litWidth < 2 || litWidth > 8 {
					return nil, gifUnsupported("litwidth")
				}
				src, next, ok := gifImageData(data, pos)
				if !ok {
					return nil, errGIFInvalid
				}
				pos = next
				pix, err := gifPixels(src, litWidth, fw, fh, pal, transparent,
					fields&gifFieldInterlace != 0)
				if err != nil {
					return nil, err
				}
				im = &Image{Width: fw, Height: fh, Pix: pix}
			} else {
				var ok bool
				if pos, ok = gifSkipBlocks(data, pos); !ok {
					goto done
				}
			}
			frames++
			// The GCE's scope is the first graphic rendering block that
			// follows it (GIF89a §23): it does not carry to later frames.
			transparent = -1
		default:
			if im == nil {
				return nil, errGIFInvalid
			}
			goto done
		}
	}
done:
	if im == nil {
		return nil, errGIFInvalid
	}
	im.Frames = frames
	return im, nil
}

// gifColorTable reads 2^(1+size) RGB triples at pos into 0xAARRGGBB words.
func gifColorTable(data []byte, pos int, fields byte) ([]uint32, int, bool) {
	n := 1 << (1 + uint(fields&gifFieldTableBits))
	if pos+3*n > len(data) {
		return nil, pos, false
	}
	pal := make([]uint32, n)
	for i := range pal {
		pal[i] = 0xff000000 | uint32(data[pos])<<16 | uint32(data[pos+1])<<8 | uint32(data[pos+2])
		pos += 3
	}
	return pal, pos, true
}

// gifSkipBlocks advances pos past a sub-block sequence (n bytes, repeated,
// ending on a zero-length block) and reports whether the terminator was
// found. GIF extension and image data share this framing.
func gifSkipBlocks(data []byte, pos int) (int, bool) {
	for {
		if pos >= len(data) {
			return pos, false
		}
		n := int(data[pos])
		pos++
		if n == 0 {
			return pos, true
		}
		if pos+n > len(data) {
			return pos, false
		}
		pos += n
	}
}

// gifImageData collects a frame's sub-block payloads into one byte stream
// for the LZW reader. The file cap already bounds the copy.
func gifImageData(data []byte, pos int) ([]byte, int, bool) {
	var src []byte
	for {
		if pos >= len(data) {
			return nil, pos, false
		}
		n := int(data[pos])
		pos++
		if n == 0 {
			return src, pos, true
		}
		if pos+n > len(data) {
			return nil, pos, false
		}
		src = append(src, data[pos:pos+n]...)
		pos += n
	}
}

// gifPixels decodes the frame's index stream and maps it through the
// palette into 0xAARRGGBB words. The stream must produce exactly w*h
// indices — short is "not enough image data", long is "too much" — and
// every index must resolve inside the (possibly extended) palette. The
// transparent index, when the GCE set one, blanks its palette entry like
// the host decoder does, so transparent pixels decode to 0x00000000.
func gifPixels(src []byte, litWidth, w, h int, pal []uint32, transparent int, interlaced bool) ([]uint32, error) {
	if transparent >= 0 {
		p := append([]uint32(nil), pal...)
		if transparent < len(p) {
			p[transparent] = 0
		} else {
			// An out-of-range index is a spec violation the common viewers
			// accept; the palette grows with transparent entries.
			np := make([]uint32, transparent+1)
			copy(np, p)
			p = np
		}
		pal = p
	}
	n := w * h
	idx := make([]byte, n)
	if !gifLZW(src, litWidth, idx) {
		return nil, errGIFInvalid
	}
	for _, px := range idx {
		if int(px) >= len(pal) {
			return nil, errGIFInvalid
		}
	}
	if interlaced {
		un := make([]byte, n)
		off := 0
		for _, pass := range gifInterlace {
			for y := pass[1]; y < h; y += pass[0] {
				copy(un[y*w:(y+1)*w], idx[off:off+w])
				off += w
			}
		}
		idx = un
	}
	pix := make([]uint32, n)
	for i, px := range idx {
		pix[i] = pal[px]
	}
	return pix, nil
}

// gifLZW decodes the GIF LZW stream (LSB-first codes, litWidth+1 growing to
// 12 bits, deferred clear at a full dictionary) into dst, which it must
// fill exactly. The shape mirrors compress/lzw's reader: hi is the next
// dictionary slot, so a code equal to hi while last is valid is the KwKwK
// expansion of last plus its head.
func gifLZW(src []byte, litWidth int, dst []byte) bool {
	var prefix [1 << 12]uint16
	var suffix [1 << 12]byte
	var stack [1<<12 + 1]byte
	clear := 1 << uint(litWidth)
	eoi := clear + 1
	width := uint(litWidth) + 1
	hi := eoi
	overflow := 1 << width
	last := -1
	o := 0
	var br gifBitReader
	br.d = src
	for {
		code, ok := br.get(width)
		if !ok {
			return o == len(dst) // ran out mid-frame: "not enough data"
		}
		switch {
		case code == eoi:
			return o == len(dst)
		case code == clear:
			width = uint(litWidth) + 1
			hi = eoi
			overflow = 1 << width
			last = -1
			continue
		case code > hi:
			return false // "lzw: invalid code"
		}
		c := code
		n := 0
		if code == hi && last >= 0 {
			// KwKwK: the code names the entry hi is about to become —
			// last's expansion plus its own head byte.
			head := last
			for head >= clear {
				head = int(prefix[head])
			}
			stack[n] = byte(head)
			n++
			c = last
		}
		for c >= clear {
			stack[n] = suffix[c]
			n++
			c = int(prefix[c])
		}
		stack[n] = byte(c)
		head := byte(c)
		n++
		if o+n > len(dst) {
			return false // produced more indices than the frame has pixels
		}
		for n > 0 {
			n--
			dst[o] = stack[n]
			o++
		}
		if last >= 0 {
			suffix[hi] = head
			prefix[hi] = uint16(last)
		}
		last, hi = code, hi+1
		if hi >= overflow {
			if width == 12 {
				// Deferred clear: the dictionary freezes until a clear code.
				last = -1
				hi--
			} else {
				width++
				overflow = 1 << width
			}
		}
	}
}

// gifBitReader reads LSB-first codes out of the image data stream.
type gifBitReader struct {
	d     []byte
	pos   int
	bits  uint64
	nbits uint
}

func (b *gifBitReader) get(width uint) (int, bool) {
	for b.nbits < width {
		if b.pos >= len(b.d) {
			return 0, false
		}
		b.bits |= uint64(b.d[b.pos]) << b.nbits
		b.pos++
		b.nbits += 8
	}
	c := int(b.bits & (1<<width - 1))
	b.bits >>= width
	b.nbits -= width
	return c, true
}
