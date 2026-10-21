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
//
// DecodeGIFFrames (issue #2975) is the multi-frame half: it composites every
// frame onto the logical screen honoring the graphic control extension's
// disposal, transparency and delay, reads the NETSCAPE2.0 loop count, and
// stops honestly at its own frame and pixel bounds.

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
	gifExtApplication    = 0xff

	gifFieldColorTable = 1 << 7
	gifFieldInterlace  = 1 << 6
	gifFieldTableBits  = 7

	gifGCETransparent = 1 << 0
)

// GIF89a disposal methods (the GCE packed byte's bits 2–4): 0 leaves the
// action unspecified and 1 keeps the frame in place — both composite as
// "keep"; 2 restores the frame's rectangle to the background before the
// next frame draws; 3 restores what was there before the frame drew.
const (
	gifDisposeNone = 0
	gifDisposeKeep = 1
	gifDisposeBack = 2
	gifDisposePrev = 3
)

// gifFramesMax is the default DecodeGIFFrames frame bound; the summed
// composited pixels bound defaults to gifPixelsFactor× the single-image cap.
const (
	gifFramesMax    = 64
	gifPixelsFactor = 4
)

// gifInterlace is the four-pass row order of an interlaced frame.
var gifInterlace = [4][2]int{{8, 0}, {8, 4}, {4, 2}, {2, 1}}

// decodeGIF decodes data as a GIF: the first image descriptor's frame is
// returned, later frames are skipped and counted. The logical screen
// bounds the frame and carries the size cap; the returned Image is the
// frame's own rectangle (mirroring host image/gif's Decode), while
// GOVIEW's header sniff reads the screen size.
func decodeGIF(data []byte) (*Image, error) {
	w, h, gct, pos, err := gifHead(data)
	if err != nil {
		return nil, err
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
				gce, next, ok := gifParseGCE(data, pos)
				if !ok {
					if im == nil {
						return nil, errGIFInvalid
					}
					goto done
				}
				transparent = gce.transparent
				pos = next
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
			blk, ok := gifReadImage(data, pos, w, h, gct)
			if !ok {
				if im == nil {
					return nil, errGIFInvalid
				}
				goto done
			}
			pos = blk.next
			if frames == 0 {
				if blk.lit < 2 || blk.lit > 8 {
					return nil, gifUnsupported("litwidth")
				}
				pix, err := gifPixels(blk.src, blk.lit, blk.w, blk.h, blk.pal, transparent,
					blk.fields&gifFieldInterlace != 0)
				if err != nil {
					return nil, err
				}
				im = &Image{Width: blk.w, Height: blk.h, Pix: pix}
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

// gifHead validates the header and logical screen descriptor and reads the
// global color table: the same contract both decode paths share — corrupt
// input is image-invalid: gif, an oversized screen image-limit: gif.
func gifHead(data []byte) (w, h int, gct []uint32, pos int, err error) {
	if len(data) > webstyle.MaxImageBytes {
		return 0, 0, nil, 0, errGIFLimit
	}
	if len(data) < 13 {
		return 0, 0, nil, 0, errGIFInvalid
	}
	if v := string(data[:6]); v != "GIF87a" && v != "GIF89a" {
		return 0, 0, nil, 0, errGIFInvalid
	}
	w = int(data[6]) | int(data[7])<<8
	h = int(data[8]) | int(data[9])<<8
	if w == 0 || h == 0 {
		return 0, 0, nil, 0, errGIFInvalid
	}
	if w > webstyle.MaxImageDimension || h > webstyle.MaxImageDimension ||
		w*h > maxImagePixels {
		return 0, 0, nil, 0, errGIFLimit
	}
	pos = 13
	if data[10]&gifFieldColorTable != 0 {
		var ok bool
		if gct, pos, ok = gifColorTable(data, pos, data[10]); !ok {
			return 0, 0, nil, 0, errGIFInvalid
		}
	}
	return w, h, gct, pos, nil
}

// gifGCE is one graphic control extension's payload: the disposal method,
// the delay in centiseconds, and the transparent index (-1 when the flag is
// clear).
type gifGCE struct {
	disposal    int
	delay       int
	transparent int
}

// gifParseGCE reads the fixed 4-byte graphic control extension payload at
// pos (just past the 0x21 0xf9 pair). ok requires the spec's size byte and
// terminator.
func gifParseGCE(data []byte, pos int) (gce gifGCE, next int, ok bool) {
	if pos+6 > len(data) || data[pos] != 4 || data[pos+5] != 0 {
		return gifGCE{}, pos, false
	}
	packed := data[pos+1]
	gce.disposal = int(packed>>2) & 7
	gce.delay = int(data[pos+2]) | int(data[pos+3])<<8
	gce.transparent = -1
	if packed&gifGCETransparent != 0 {
		gce.transparent = int(data[pos+4])
	}
	return gce, pos + 6, true
}

// gifBlock is one image descriptor's parse: the frame rectangle, its
// resolved palette (a local table or the GCT), the LZW literal width and
// the collected sub-block stream.
type gifBlock struct {
	left, top, w, h int
	fields          byte
	pal             []uint32
	lit             int
	src             []byte
	next            int
}

// gifReadImage parses the image descriptor at pos (data[pos]==0x2c): the
// frame must fit inside the logical screen sw×sh and carry a color table,
// and its LZW sub-blocks must terminate cleanly.
func gifReadImage(data []byte, pos, sw, sh int, gct []uint32) (*gifBlock, bool) {
	pos++
	if pos+9 > len(data) {
		return nil, false
	}
	b := &gifBlock{
		left: int(data[pos]) | int(data[pos+1])<<8,
		top:  int(data[pos+2]) | int(data[pos+3])<<8,
		w:    int(data[pos+4]) | int(data[pos+5])<<8,
		h:    int(data[pos+6]) | int(data[pos+7])<<8,
	}
	b.fields = data[pos+8]
	// The frame must fit inside the logical screen.
	if b.left+b.w > sw || b.top+b.h > sh {
		return nil, false
	}
	pos += 9
	b.pal = gct
	if b.fields&gifFieldColorTable != 0 {
		var ok bool
		if b.pal, pos, ok = gifColorTable(data, pos, b.fields); !ok {
			return nil, false
		}
	}
	if len(b.pal) == 0 || pos >= len(data) {
		return nil, false
	}
	b.lit = int(data[pos])
	pos++
	src, next, ok := gifImageData(data, pos)
	if !ok {
		return nil, false
	}
	b.src, b.next = src, next
	return b, true
}

// gifAppLoop reads an application extension at pos (just past the
// 0x21 0xff pair): the identifier+auth-code block first, then its
// sub-blocks. A "NETSCAPE2.0" identifier's first sub-block carries the loop
// count as [0x01, lo, hi]; loops stays -1 for any other application block.
func gifAppLoop(data []byte, pos int) (loops, next int, ok bool) {
	if pos >= len(data) {
		return -1, pos, false
	}
	n := int(data[pos])
	pos++
	if pos+n > len(data) {
		return -1, pos, false
	}
	id := string(data[pos : pos+n])
	pos += n
	loops = -1
	if id == "NETSCAPE2.0" && pos+4 <= len(data) && data[pos] == 3 && data[pos+1] == 1 {
		loops = int(data[pos+2]) | int(data[pos+3])<<8
	}
	next, ok = gifSkipBlocks(data, pos)
	return loops, next, ok
}

// GIFLimits bounds a DecodeGIFFrames walk. A zero field selects the
// default: gifFramesMax frames, and gifPixelsFactor× the single-image pixel
// cap summed over the composited frames.
type GIFLimits struct {
	MaxFrames int
	MaxPixels int
}

// GIFFrame is one composited animation frame: the logical screen's pixels
// after this frame drew (Width×Height 0xAARRGGBB words) and the frame's
// delay in centiseconds.
type GIFFrame struct {
	Pix   []uint32
	Delay int
}

// GIFAnimation is DecodeGIFFrames' result: every composited frame on the
// logical screen, the NETSCAPE2.0 loop count (-1 when the extension is
// absent, 0 for loop-forever, n for n iterations) and Truncated naming the
// bound that ended the walk early — "frames", "pixels", "corrupt" or
// "unsupported"; empty when the file ended cleanly.
type GIFAnimation struct {
	Width, Height int
	Frames        []GIFFrame
	Loops         int
	Truncated     string
}

// DecodeGIFFrames decodes a GIF as an animation: each frame composites onto
// the logical screen honoring its GCE — disposal 0/1 keeps the canvas, 2
// restores the frame's rectangle to the logical-screen background
// (transparent when that index is the frame's own transparent index, or
// when no table resolves it), 3 restores the canvas from before the frame;
// transparent indices never overwrite. The walk shares decodeGIF's
// tolerance: a tail that breaks after at least one composited frame returns
// the frames so far with Truncated set rather than an error, while a file
// that yields no frame at all refuses with the same named errors.
func DecodeGIFFrames(data []byte, lim GIFLimits) (*GIFAnimation, error) {
	w, h, gct, pos, err := gifHead(data)
	if err != nil {
		return nil, err
	}
	maxFrames := lim.MaxFrames
	if maxFrames <= 0 {
		maxFrames = gifFramesMax
	}
	maxPixels := lim.MaxPixels
	if maxPixels <= 0 {
		maxPixels = gifPixelsFactor * maxImagePixels
	}

	anim := &GIFAnimation{Width: w, Height: h, Loops: -1}
	bgIndex := int(data[11])
	bg := uint32(0)
	if bgIndex < len(gct) {
		bg = gct[bgIndex]
	}
	canvas := make([]uint32, w*h)
	var saved []uint32     // disposal-3 snapshot of the canvas
	var pend gifGCE        // the previous frame's disposal, owed now
	pendRect := gifBlock{} // ...applied to this rectangle
	gce := gifGCE{transparent: -1}
	pixels := 0

	for pos < len(data) {
		switch data[pos] {
		case gifTrailer:
			if len(anim.Frames) == 0 {
				return nil, errGIFInvalid // no image before the trailer
			}
			return anim, nil
		case gifExtIntroducer:
			pos++
			if pos >= len(data) {
				goto done
			}
			label := data[pos]
			pos++
			if label == gifExtGraphicControl {
				g, next, ok := gifParseGCE(data, pos)
				if !ok {
					if len(anim.Frames) == 0 {
						return nil, errGIFInvalid
					}
					goto done
				}
				gce = g
				pos = next
			} else if label == gifExtApplication {
				loops, next, ok := gifAppLoop(data, pos)
				if !ok {
					if len(anim.Frames) == 0 {
						return nil, errGIFInvalid
					}
					goto done
				}
				if loops >= 0 {
					anim.Loops = loops
				}
				pos = next
			} else {
				var ok bool
				if pos, ok = gifSkipBlocks(data, pos); !ok {
					if len(anim.Frames) == 0 {
						return nil, errGIFInvalid
					}
					goto done
				}
			}
		case gifImageDesc:
			blk, ok := gifReadImage(data, pos, w, h, gct)
			if !ok {
				if len(anim.Frames) == 0 {
					return nil, errGIFInvalid
				}
				goto done
			}
			pos = blk.next
			// The bounds pre-date the draw: a frame that would cross one
			// is not decoded — the frames so far return with the bound's
			// name.
			if len(anim.Frames) >= maxFrames {
				anim.Truncated = "frames"
				goto done
			}
			if pixels+w*h > maxPixels {
				anim.Truncated = "pixels"
				goto done
			}
			if blk.lit < 2 || blk.lit > 8 {
				if len(anim.Frames) == 0 {
					return nil, gifUnsupported("litwidth")
				}
				anim.Truncated = "unsupported"
				goto done
			}
			pix, err := gifPixels(blk.src, blk.lit, blk.w, blk.h, blk.pal, gce.transparent,
				blk.fields&gifFieldInterlace != 0)
			if err != nil {
				if len(anim.Frames) == 0 {
					return nil, err
				}
				goto done
			}
			// The previous frame's disposal is owed before this frame
			// draws; a frame that wants disposal 3 snapshots the canvas
			// it is about to overwrite.
			gifDispose(canvas, saved, w, h, pend, pendRect, bgIndex, bg)
			if gce.disposal == gifDisposePrev {
				saved = append([]uint32(nil), canvas...)
			}
			for y := 0; y < blk.h; y++ {
				dst := (blk.top+y)*w + blk.left
				row := y * blk.w
				for x := 0; x < blk.w; x++ {
					if p := pix[row+x]; p>>24 != 0 {
						canvas[dst+x] = p
					}
				}
			}
			frame := GIFFrame{Pix: make([]uint32, w*h), Delay: gce.delay}
			copy(frame.Pix, canvas)
			anim.Frames = append(anim.Frames, frame)
			pixels += w * h
			pend, pendRect = gce, *blk
			// The GCE's scope is the first graphic rendering block that
			// follows it (GIF89a §23): it does not carry to later frames.
			gce = gifGCE{transparent: -1}
		default:
			if len(anim.Frames) == 0 {
				return nil, errGIFInvalid
			}
			goto done
		}
	}
done:
	if len(anim.Frames) == 0 {
		return nil, errGIFInvalid
	}
	if anim.Truncated == "" {
		anim.Truncated = "corrupt"
	}
	return anim, nil
}

// gifDispose pays the previous frame's disposal to the canvas before the
// next frame draws: mode 2 refills the disposed rectangle with the
// logical-screen background — transparent when that background index is the
// disposed frame's own transparent index — and mode 3 restores the
// pre-frame snapshot. Modes 0/1 and anything past 3 do nothing.
func gifDispose(canvas, saved []uint32, sw, sh int, pend gifGCE, rect gifBlock, bgIndex int, bg uint32) {
	switch pend.disposal {
	case gifDisposeBack:
		fill := bg
		if pend.transparent == bgIndex {
			fill = 0 // the background index was this frame's transparent index
		}
		for y := rect.top; y < rect.top+rect.h && y < sh; y++ {
			for x := rect.left; x < rect.left+rect.w && x < sw; x++ {
				canvas[y*sw+x] = fill
			}
		}
	case gifDisposePrev:
		if saved != nil {
			copy(canvas, saved)
		}
	}
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
