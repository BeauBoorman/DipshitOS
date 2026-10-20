package webrender

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/gif"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"virelai/webstyle"
)

// The corpus inputs below are original, generated from specified pixel
// vectors by the encoder in this file, not downloaded GIFs or external
// decoder code. The Go standard library image/gif is the BSD-3-Clause
// host-only test reference (and encoded viewer_160x120.gif and
// anim3_160x120.gif); the fixtures' licenses are recorded in
// testdata/gif/SOURCES.txt.
//
// The encoder writes REAL GIFs: header + logical screen descriptor, global
// or per-frame local color tables, an optional graphic control extension
// carrying the transparent index, sub-blocked LZW image data at the right
// literal width, interlaced or multi-frame layouts. That is what lets the
// corpus cover the shapes gif.Encode never emits — it always writes a
// global palette and non-interlaced frames.

// gifVecFrame is one image block in a generated vector.
type gifVecFrame struct {
	left, top   int
	w, h        int
	pix         []byte // w*h palette indices
	pal         []byte // local color table as RGB triples, nil = use the GCT
	interlace   bool
	transparent int // -1 = no graphic control extension
	lit         int // 0 = derive the literal width from the palette size
}

// gifVector is one generated corpus entry.
type gifVector struct {
	name   string
	ver    byte // '7' or '9'
	w, h   int  // logical screen
	gct    []byte
	frames []gifVecFrame
	stdlib bool // encode with the host image/gif reference instead
}

// gifPal is the deterministic test palette: n must be a power of two.
func gifPal(n int) []byte {
	p := make([]byte, 3*n)
	for i := 0; i < n; i++ {
		p[3*i+0] = byte(i*37 + 11)
		p[3*i+1] = byte(i*83 + 7)
		p[3*i+2] = byte(255 - i*29)
	}
	return p
}

// gifPattern is the deterministic index source the generated vectors share.
func gifPattern(w, h, colors int) []byte {
	idx := make([]byte, w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			idx[y*w+x] = byte((x/3 + y/5 + (x*y)%7) % colors)
		}
	}
	return idx
}

func gifVec(l, t, w, h int, pix []byte) gifVecFrame {
	return gifVecFrame{left: l, top: t, w: w, h: h, pix: pix, transparent: -1}
}

var gifVectors = []gifVector{
	{"flat-87a", '7', 32, 24, gifPal(4), []gifVecFrame{
		gifVec(0, 0, 32, 24, gifPattern(32, 24, 4)),
	}, false},
	{"pattern-89a", '9', 48, 32, gifPal(16), []gifVecFrame{
		gifVec(0, 0, 48, 32, gifPattern(48, 32, 16)),
	}, false},
	{"interlaced-89a", '9', 48, 32, gifPal(8), []gifVecFrame{
		func() gifVecFrame { f := gifVec(0, 0, 48, 32, gifPattern(48, 32, 8)); f.interlace = true; return f }(),
	}, false},
	{"transparent-89a", '9', 24, 16, gifPal(8), []gifVecFrame{
		func() gifVecFrame { f := gifVec(0, 0, 24, 16, gifPattern(24, 16, 8)); f.transparent = 3; return f }(),
	}, false},
	{"localpal-89a", '9', 24, 16, nil, []gifVecFrame{
		func() gifVecFrame { f := gifVec(0, 0, 24, 16, gifPattern(24, 16, 8)); f.pal = gifPal(8); return f }(),
	}, false},
	{"subrect-89a", '9', 64, 48, gifPal(8), []gifVecFrame{
		gifVec(10, 6, 24, 16, gifPattern(24, 16, 8)),
	}, false},
	{"anim3-89a", '9', 32, 24, gifPal(4), []gifVecFrame{
		gifVec(0, 0, 32, 24, gifPattern(32, 24, 4)),
		gifVec(0, 0, 32, 24, gifPatternInv(32, 24, 4)),
		gifVec(0, 0, 32, 24, gifPattern(32, 24, 4)),
	}, false},
	{"viewer_160x120", '9', 160, 120, gifPal(16), []gifVecFrame{
		gifVec(0, 0, 160, 120, gifPattern(160, 120, 16)),
	}, true},
	{"anim3_160x120", '9', 160, 120, gifPal(16), nil, true},
}

// gifPatternInv inverts the pattern so a second animation frame differs.
func gifPatternInv(w, h, colors int) []byte {
	idx := gifPattern(w, h, colors)
	for i := range idx {
		idx[i] = byte(colors - 1 - int(idx[i]))
	}
	return idx
}

// gifLitWidth is the smallest legal literal width covering n palette
// entries (the spec's 2–8 range; a 2-entry table still encodes at 2).
func gifLitWidth(n int) int {
	bits := 2
	for 1<<uint(bits) < n {
		bits++
	}
	return bits
}

// gifInterlaceRows reorders the frame's rows into the four-pass wire order.
func gifInterlaceRows(idx []byte, w, h int) []byte {
	out := make([]byte, 0, len(idx))
	for _, pass := range gifInterlace {
		for y := pass[1]; y < h; y += pass[0] {
			out = append(out, idx[y*w:(y+1)*w]...)
		}
	}
	return out
}

// gifCodeWriter packs LZW codes LSB-first into bytes.
type gifCodeWriter struct {
	buf   []byte
	bits  uint64
	nbits uint
}

func (w *gifCodeWriter) put(code uint32, width uint) {
	w.bits |= uint64(code) << w.nbits
	w.nbits += width
	for w.nbits >= 8 {
		w.buf = append(w.buf, byte(w.bits))
		w.bits >>= 8
		w.nbits -= 8
	}
}

func (w *gifCodeWriter) bytes() []byte {
	if w.nbits > 0 {
		w.buf = append(w.buf, byte(w.bits))
	}
	return w.buf
}

// gifLZWEncode is the test-side LZW compressor: the textbook dictionary
// build, emitting a clear code when the 12-bit dictionary fills. Its stream
// exercises the decoder's dictionary-code and code-width-growth paths the
// way a literal-only encoder never would.
func gifLZWEncode(px []byte, litWidth int) []byte {
	var w gifCodeWriter
	clear := uint32(1) << uint(litWidth)
	eof := clear + 1
	const maxCode = 1<<12 - 1
	width := uint(litWidth) + 1
	hi := eof
	overflow := clear << 1
	table := map[uint32]uint32{}
	w.put(clear, width)
	emit := func(code uint32) {
		w.put(code, width)
		hi++
		if hi == overflow {
			width++
			overflow <<= 1
		}
	}
	if len(px) > 0 {
		code := uint32(px[0])
		for _, x := range px[1:] {
			lit := uint32(x)
			key := code<<8 | lit
			if c, ok := table[key]; ok {
				code = c
				continue
			}
			emit(code)
			code = lit
			if hi == maxCode {
				w.put(clear, width)
				width = uint(litWidth) + 1
				hi = eof
				overflow = clear << 1
				table = map[uint32]uint32{}
				continue
			}
			table[key] = hi
		}
		emit(code)
	}
	w.put(eof, width)
	return w.bytes()
}

// gifEncode assembles a complete GIF byte stream for a vector.
func gifEncode(v gifVector) []byte {
	var b []byte
	u16 := func(n int) { b = append(b, byte(n), byte(n>>8)) }
	b = append(b, 'G', 'I', 'F', '8', v.ver, 'a')
	u16(v.w)
	u16(v.h)
	if v.gct != nil {
		b = append(b, 0x80|byte(gifLitWidth(len(v.gct)/3)-1))
	} else {
		b = append(b, 0)
	}
	b = append(b, 0, 0) // background index, aspect
	b = append(b, v.gct...)
	for _, f := range v.frames {
		if f.transparent >= 0 {
			b = append(b, gifExtIntroducer, gifExtGraphicControl, 4,
				gifGCETransparent, 0, 0, byte(f.transparent), 0)
		}
		b = append(b, gifImageDesc)
		u16(f.left)
		u16(f.top)
		u16(f.w)
		u16(f.h)
		fields := byte(0)
		if f.pal != nil {
			fields |= 0x80 | byte(gifLitWidth(len(f.pal)/3)-1)
		}
		if f.interlace {
			fields |= 0x40
		}
		b = append(b, fields)
		b = append(b, f.pal...)
		ncolors := len(v.gct) / 3
		if f.pal != nil {
			ncolors = len(f.pal) / 3
		}
		lit := gifLitWidth(ncolors)
		if f.lit > 0 {
			lit = f.lit
		}
		pix := f.pix
		if f.interlace {
			pix = gifInterlaceRows(pix, f.w, f.h)
		}
		data := gifLZWEncode(pix, lit)
		b = append(b, byte(lit))
		for len(data) > 255 {
			b = append(b, 255)
			b = append(b, data[:255]...)
			data = data[255:]
		}
		b = append(b, byte(len(data)))
		b = append(b, data...)
		b = append(b, 0)
	}
	b = append(b, gifTrailer)
	return b
}

// gifVectorBytes produces a vector's bytes. The viewer fixtures go through
// the host stdlib encoders (gif.Encode/gif.EncodeAll, BSD-3-Clause) so the
// GOVIEW gate fixture is a real-encoder GIF, not only the corpus
// generator's output.
func gifVectorBytes(v gifVector) []byte {
	if !v.stdlib {
		return gifEncode(v)
	}
	pal := make(color.Palette, len(v.gct)/3)
	for i := range pal {
		pal[i] = color.RGBA{v.gct[3*i], v.gct[3*i+1], v.gct[3*i+2], 0xff}
	}
	mk := func(pix []byte) *image.Paletted {
		m := image.NewPaletted(image.Rect(0, 0, v.w, v.h), pal)
		copy(m.Pix, pix)
		return m
	}
	var out bytes.Buffer
	if v.name == "anim3_160x120" {
		g := &gif.GIF{
			Image: []*image.Paletted{
				mk(gifPattern(v.w, v.h, 16)),
				mk(gifPatternInv(v.w, v.h, 16)),
				mk(gifPattern(v.w, v.h, 16)),
			},
			Delay: []int{10, 10, 10},
		}
		if err := gif.EncodeAll(&out, g); err != nil {
			panic(err)
		}
		return out.Bytes()
	}
	if err := gif.Encode(&out, mk(v.frames[0].pix), nil); err != nil {
		panic(err)
	}
	return out.Bytes()
}

// checkGIFParity decodes data with the in-tree decoder and with host
// image/gif and requires every channel of every frame-0 pixel identical.
func checkGIFParity(t testing.TB, data []byte) {
	t.Helper()
	got, err := decodeGIF(data)
	if err != nil {
		t.Fatalf("decodeGIF: %v", err)
	}
	want, err := gif.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("host image/gif refused a corpus file: %v", err)
	}
	b := want.Bounds()
	if got.Width != b.Dx() || got.Height != b.Dy() {
		t.Fatalf("dimensions=%dx%d, stdlib=%v", got.Width, got.Height, b)
	}
	for y := 0; y < got.Height; y++ {
		for x := 0; x < got.Width; x++ {
			c := color.NRGBAModel.Convert(want.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA)
			p := got.At(x, y)
			if p != uint32(c.A)<<24|uint32(c.R)<<16|uint32(c.G)<<8|uint32(c.B) {
				t.Fatalf("pixel (%d,%d): got %#08x want %#v", x, y, p, c)
			}
		}
	}
	all, err := gif.DecodeAll(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("host DecodeAll refused a corpus file: %v", err)
	}
	if got.Frames != len(all.Image) {
		t.Fatalf("frames=%d, stdlib DecodeAll counted %d", got.Frames, len(all.Image))
	}
}

func TestGIFParityVectors(t *testing.T) {
	for _, v := range gifVectors {
		t.Run(v.name, func(t *testing.T) {
			data := gifVectorBytes(v)
			// The corpus encoder must emit files the host reference accepts.
			if _, err := gif.DecodeConfig(bytes.NewReader(data)); err != nil {
				t.Fatalf("generated vector is not a decodable GIF: %v", err)
			}
			checkGIFParity(t, data)
		})
	}
}

func TestGIFCommittedCorpus(t *testing.T) {
	n := 0
	for _, v := range gifVectors {
		path := filepath.Join("testdata", "gif", v.name+".gif")
		data := gifVectorBytes(v)
		if os.Getenv("WEBRENDER_CREATE_GIF_CORPUS") == "1" {
			if _, err := os.Stat(path); os.IsNotExist(err) {
				if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, data, 0o644); err != nil {
					t.Fatal(err)
				}
			}
		}
		pinned, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("committed corpus fixture missing: %s (run with WEBRENDER_CREATE_GIF_CORPUS=1)", path)
		}
		if !bytes.Equal(pinned, data) {
			t.Fatalf("owned corpus vector drift: %s", path)
		}
		checkGIFParity(t, pinned)
		n++
	}
	if n == 0 {
		t.Fatal("GIF corpus is missing")
	}
}

// gifLitWidthOffset finds the literal-width byte of the first image in an
// encoded vector: header (6) + LSD (7) + GCT + descriptor (1+9) + LCT.
func gifLitWidthOffset(t testing.TB, data []byte) int {
	t.Helper()
	pos := 13
	if data[10]&0x80 != 0 {
		pos += 3 * (1 << (1 + uint(data[10]&7)))
	}
	if pos >= len(data) || data[pos] != gifImageDesc {
		t.Fatal("corpus file lost its image descriptor")
	}
	pos++
	fields := data[pos+8]
	pos += 9
	if fields&0x80 != 0 {
		pos += 3 * (1 << (1 + uint(fields&7)))
	}
	if pos >= len(data) {
		t.Fatal("corpus file lost its literal width byte")
	}
	return pos
}

func mutateGIF(data []byte, off int, fn func([]byte, int)) []byte {
	out := append([]byte(nil), data...)
	fn(out, off)
	return out
}

func TestGIFUnsupportedByName(t *testing.T) {
	base := gifVectorBytes(gifVectors[1]) // pattern-89a
	lit := gifLitWidthOffset(t, base)
	mutate := func(fn func([]byte)) []byte {
		data := append([]byte(nil), base...)
		fn(data)
		return data
	}
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{"litwidth-low", mutate(func(d []byte) { d[lit] = 1 }), "image-gif-unsupported-litwidth"},
		{"litwidth-high", mutate(func(d []byte) { d[lit] = 9 }), "image-gif-unsupported-litwidth"},
		{"litwidth-zero", mutate(func(d []byte) { d[lit] = 0 }), "image-gif-unsupported-litwidth"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			im, err := decodeGIF(tc.data)
			if err == nil || err.Error() != tc.want || im != nil {
				t.Fatalf("refusal=%v image=%v, want %s", err, im, tc.want)
			}
			if !errors.Is(err, ErrImageUnsupported) {
				t.Fatalf("%v must match ErrImageUnsupported", err)
			}
		})
	}
}

func TestGIFMalformedByName(t *testing.T) {
	base := gifVectorBytes(gifVectors[1]) // pattern-89a
	lit := gifLitWidthOffset(t, base)
	desc := lit - 10 // descriptor byte position
	// Every prefix that ends inside the first frame's data must refuse;
	// only the trailer (the last byte) may be absent without a refusal.
	for i := 0; i < len(base)-1; i++ {
		if im, err := decodeGIF(base[:i]); err == nil || im != nil {
			t.Fatalf("truncation at %d decoded %v", i, im)
		}
	}
	// A frame whose LZW data produces the wrong pixel count, and a frame
	// whose indices exceed its palette, built from the test encoder.
	wrongCount := gifEncode(gifVector{ver: '9', w: 2, h: 2, gct: gifPal(4), frames: []gifVecFrame{
		gifVec(0, 0, 2, 2, []byte{0, 1, 2, 3, 0, 1}),
	}})
	shortCount := gifEncode(gifVector{ver: '9', w: 2, h: 2, gct: gifPal(4), frames: []gifVecFrame{
		gifVec(0, 0, 2, 2, []byte{0, 1, 2}),
	}})
	badIndex := gifEncode(gifVector{ver: '9', w: 2, h: 2, gct: gifPal(4), frames: []gifVecFrame{
		func() gifVecFrame { f := gifVec(0, 0, 2, 2, []byte{0, 1, 2, 5}); f.lit = 3; return f }(),
	}})
	cases := map[string][]byte{
		"not-gif":     []byte("this is not a gif at all, it just is not"),
		"magic":       []byte("GIF99a" + string(base[6:])),
		"no-tables":   mutateGIF(base, 10, func(d []byte, i int) { d[i] &^= 0x80 }),
		"bounds":      mutateGIF(base, desc+5, func(d []byte, i int) { d[i], d[i+1] = 0xff, 0xff }),
		"bad-block":   mutateGIF(base, desc, func(d []byte, i int) { d[i] = 0x2e }),
		"too-much":    wrongCount,
		"not-enough":  shortCount,
		"bad-index":   badIndex,
		"empty-image": gifEncode(gifVector{ver: '9', w: 8, h: 8, gct: gifPal(4)}),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			im, err := decodeGIF(data)
			if err == nil || im != nil {
				t.Fatal("malformed input accepted")
			}
			if !strings.HasPrefix(err.Error(), "image-") {
				t.Fatalf("unnamed refusal: %v", err)
			}
		})
	}
}

// TestGIFBadGCE refuses a graphic control extension whose block size is not
// the spec's 4 — the mutation targets a transparent frame so the byte is
// known to exist.
func TestGIFBadGCE(t *testing.T) {
	base := gifVectorBytes(gifVectors[3]) // transparent-89a
	// GCE sits right after the global table: 0x21 0xf9 size ....
	gce := 13 + 3*(1<<(1+uint(base[10]&7)))
	if base[gce] != gifExtIntroducer || base[gce+1] != gifExtGraphicControl {
		t.Fatal("corpus file lost its graphic control extension")
	}
	data := mutateGIF(base, gce+2, func(d []byte, i int) { d[i] = 5 })
	if im, err := decodeGIF(data); err != errGIFInvalid || im != nil {
		t.Fatalf("bad GCE size: image=%v err=%v", im, err)
	}
}

func TestGIFCaps(t *testing.T) {
	base := gifVectorBytes(gifVectors[1])
	for _, pair := range [][2]uint32{{1025, 1}, {1, 1025}, {513, 512}, {1024, 1024}, {0xffff, 0xffff}} {
		data := mutateGIF(base, 6, func(d []byte, i int) {
			d[i], d[i+1] = byte(pair[0]), byte(pair[0]>>8)
			d[i+2], d[i+3] = byte(pair[1]), byte(pair[1]>>8)
		})
		im, err := decodeGIF(data)
		if pair[0]*pair[1] > webstyle.MaxImagePixels || pair[0] > webstyle.MaxImageDimension || pair[1] > webstyle.MaxImageDimension {
			if err != errGIFLimit || im != nil {
				t.Fatalf("dimensions %v: image=%v err=%v", pair, im, err)
			}
		}
	}
	if _, err := decodeGIF(make([]byte, webstyle.MaxImageBytes+1)); err != errGIFLimit {
		t.Fatal("source cap not honored")
	}
}

func TestGIFDecodeImageDispatch(t *testing.T) {
	data := gifVectorBytes(gifVectors[0]) // flat-87a
	im, err := DecodeImage(data)
	if err != nil {
		t.Fatalf("DecodeImage: %v", err)
	}
	if im.Width != 32 || im.Height != 24 {
		t.Fatalf("decoded %dx%d", im.Width, im.Height)
	}
	if im.Frames != 1 {
		t.Fatalf("frames=%d, want 1", im.Frames)
	}
	// A bad literal width must surface through the same entry point as a
	// named unsupported, not a generic failure.
	lit := gifLitWidthOffset(t, data)
	data[lit] = 1
	if _, err := DecodeImage(data); !errors.Is(err, ErrImageUnsupported) || err.Error() != "image-gif-unsupported-litwidth" {
		t.Fatalf("litwidth dispatch: %v", err)
	}
}

// TestGIFFramesCounted pins the skip-and-count contract: an animated file
// renders frame 1 exactly like the host's Decode while Frames reports every
// image descriptor, including one after extensions and one truncated tail
// keeps the already-decoded frame.
func TestGIFFramesCounted(t *testing.T) {
	anim := gifVectorBytes(gifVectors[6]) // anim3-89a
	im, err := decodeGIF(anim)
	if err != nil {
		t.Fatal(err)
	}
	if im.Frames != 3 {
		t.Fatalf("frames=%d, want 3", im.Frames)
	}
	checkGIFParity(t, anim)
	// A tail truncated after a complete frame 0 still reports the frames it
	// managed to skip cleanly.
	cut := anim[:len(anim)-30]
	im2, err := decodeGIF(cut)
	if err != nil || im2 == nil || im2.Frames < 1 {
		t.Fatalf("truncated tail: image=%v err=%v", im2, err)
	}
}

func FuzzGIF(f *testing.F) {
	for _, v := range gifVectors[:4] {
		f.Add(gifVectorBytes(v))
	}
	f.Add([]byte{})
	f.Add([]byte("GIF89a"))
	f.Fuzz(func(t *testing.T, data []byte) {
		im, err := decodeGIF(data)
		if err != nil {
			if im != nil {
				t.Fatal("partial successful-looking image on error")
			}
			return
		}
		if im.Width < 0 || im.Height < 0 || im.Width > webstyle.MaxImageDimension ||
			im.Height > webstyle.MaxImageDimension || len(im.Pix) != im.Width*im.Height ||
			len(im.Pix) > webstyle.MaxImagePixels || len(data) > webstyle.MaxImageBytes {
			t.Fatal("decoder cap violated")
		}
	})
}

// TestGIFHeaderSniff keeps GOVIEW's logical-screen read honest: the dims
// sit at bytes 6–9, inside the viewer's bounded head.
func TestGIFHeaderSniff(t *testing.T) {
	data := gifVectorBytes(gifVectors[7])
	w := int(data[6]) | int(data[7])<<8
	h := int(data[8]) | int(data[9])<<8
	if w != 160 || h != 120 {
		t.Fatalf("sniff dims = %dx%d, want 160x120", w, h)
	}
}
