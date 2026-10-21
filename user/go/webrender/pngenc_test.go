package webrender

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"hash/crc32"
	"image/color"
	"image/png"
	"io"
	"testing"

	"virelai/flate"
)

// Host-side tests for the owned PNG writer. image/png and compress/zlib are
// the BSD-3-Clause host-only reference; the guest never imports them.

// encPix builds a deterministic raster with real gradients so the Sub
// filter and the compressor both see varied bytes.
func encPix(w, h int) []uint32 {
	pix := make([]uint32, w*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			pix[y*w+x] = 0xff000000 |
				uint32(byte(x*7+y*3))<<16 |
				uint32(byte(x*2+y*11))<<8 |
				uint32(byte(x*13+y))
		}
	}
	return pix
}

// pngWalk splits a stream into (name, body) pairs, validating every CRC.
func pngWalk(t *testing.T, data []byte) [][2][]byte {
	t.Helper()
	if len(data) < 8 || !bytes.Equal(data[:8], pngMagic) {
		t.Fatal("bad PNG signature")
	}
	var out [][2][]byte
	for pos := 8; pos < len(data); {
		n := int(binary.BigEndian.Uint32(data[pos:]))
		name := data[pos+4 : pos+8]
		body := data[pos+8 : pos+8+n]
		if crc32.ChecksumIEEE(data[pos+4:pos+8+n]) != binary.BigEndian.Uint32(data[pos+8+n:]) {
			t.Fatalf("chunk %s: CRC mismatch", name)
		}
		out = append(out, [2][]byte{name, body})
		pos += 12 + n
	}
	return out
}

func TestEncodePNGStructure(t *testing.T) {
	const w, h = 9, 4
	data := EncodePNG(encPix(w, h), w, h)
	chunks := pngWalk(t, data)
	if len(chunks) != 3 {
		t.Fatalf("chunk count %d, want IHDR+IDAT+IEND", len(chunks))
	}
	if string(chunks[0][0]) != "IHDR" || string(chunks[1][0]) != "IDAT" || string(chunks[2][0]) != "IEND" {
		t.Fatalf("chunk order %s %s %s", chunks[0][0], chunks[1][0], chunks[2][0])
	}
	ihdr := chunks[0][1]
	if len(ihdr) != 13 || binary.BigEndian.Uint32(ihdr) != w || binary.BigEndian.Uint32(ihdr[4:]) != h {
		t.Fatal("IHDR geometry wrong")
	}
	if ihdr[8] != 8 || ihdr[9] != 2 || ihdr[10] != 0 || ihdr[11] != 0 || ihdr[12] != 0 {
		t.Fatalf("IHDR fields %v", ihdr[8:])
	}
	// The IDAT payload inflates to one Sub-filtered row per scanline.
	zr, err := zlib.NewReader(bytes.NewReader(chunks[1][1]))
	if err != nil {
		t.Fatalf("stdlib zlib reader: %v", err)
	}
	raw, err := io.ReadAll(zr)
	if err != nil {
		t.Fatalf("stdlib zlib inflate: %v", err)
	}
	stride := w*3 + 1
	if len(raw) != stride*h {
		t.Fatalf("inflated %d bytes, want %d", len(raw), stride*h)
	}
	for y := 0; y < h; y++ {
		if raw[y*stride] != 1 {
			t.Fatalf("row %d filter %d, want 1 (Sub)", y, raw[y*stride])
		}
	}
}

// The writer's own decoder must read every stream back to the same pixels.
func TestEncodePNGRoundTrip(t *testing.T) {
	for _, dims := range [][2]int{{9, 4}, {64, 48}, {1, 1}, {512, 512}} {
		w, h := dims[0], dims[1]
		pix := encPix(w, h)
		data := EncodePNG(pix, w, h)
		im, err := DecodePNG(data)
		if err != nil {
			t.Fatalf("%dx%d: DecodePNG: %v", w, h, err)
		}
		if im.Width != w || im.Height != h || len(im.Pix) != len(pix) {
			t.Fatalf("%dx%d: decoded dims %dx%d", w, h, im.Width, im.Height)
		}
		for i := range pix {
			if im.Pix[i] != pix[i] {
				t.Fatalf("%dx%d: pixel %d %#08x != %#08x", w, h, i, im.Pix[i], pix[i])
			}
		}
	}
}

// Alpha selection: an all-opaque raster encodes colour type 2; one
// translucent pixel promotes the whole stream to type 6 RGBA.
func TestEncodePNGAlphaSelectsType(t *testing.T) {
	pix := encPix(5, 3)
	typ := func(data []byte) byte { return pngWalk(t, data)[0][1][9] }
	if got := typ(EncodePNG(pix, 5, 3)); got != 2 {
		t.Fatalf("opaque raster colour type %d, want 2", got)
	}
	pix[7] = 0x80abcdef
	if got := typ(EncodePNG(pix, 5, 3)); got != 6 {
		t.Fatalf("translucent raster colour type %d, want 6", got)
	}
	im, err := DecodePNG(EncodePNG(pix, 5, 3))
	if err != nil {
		t.Fatal(err)
	}
	for i := range pix {
		if im.Pix[i] != pix[i] {
			t.Fatalf("RGBA round-trip pixel %d %#08x != %#08x", i, im.Pix[i], pix[i])
		}
	}
}

// The host reference must open the file too — an export only counts when a
// stock decoder agrees on every pixel.
func TestEncodePNGStdlibDecodes(t *testing.T) {
	const w, h = 13, 7
	pix := encPix(w, h)
	pix[w*3+4] = 0x40776655 // one translucent pixel forces the RGBA stream
	want, err := png.Decode(bytes.NewReader(EncodePNG(pix, w, h)))
	if err != nil {
		t.Fatalf("image/png refused the stream: %v", err)
	}
	b := want.Bounds()
	if b.Dx() != w || b.Dy() != h {
		t.Fatalf("stdlib dims %v", b)
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.NRGBAModel.Convert(want.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA)
			p := uint32(c.A)<<24 | uint32(c.R)<<16 | uint32(c.G)<<8 | uint32(c.B)
			if pix[y*w+x] != p {
				t.Fatalf("stdlib pixel (%d,%d) %#08x != %#08x", x, y, p, pix[y*w+x])
			}
		}
	}
}

func TestEncodePNGRefusalsAndDeterminism(t *testing.T) {
	for _, dims := range [][2]int{{0, 4}, {4, 0}, {-2, 3}} {
		if EncodePNG(encPix(8, 8), dims[0], dims[1]) != nil {
			t.Fatalf("dims %v accepted", dims)
		}
	}
	if EncodePNG([]uint32{0xffffffff}, 2, 2) != nil {
		t.Fatal("short pixel slice accepted")
	}
	pix := encPix(16, 16)
	if !bytes.Equal(EncodePNG(pix, 16, 16), EncodePNG(pix, 16, 16)) {
		t.Fatal("encode not deterministic")
	}
	// The stream is the package's own zlib: InflateZlib reads the IDAT.
	data := EncodePNG(pix, 16, 16)
	idat := pngWalk(t, data)[1][1]
	dst := make([]byte, (16*3+1)*16)
	n, consumed, err := flate.InflateZlib(dst, idat)
	if err != nil || n != len(dst) || consumed != len(idat) {
		t.Fatalf("InflateZlib(IDAT): n=%d consumed=%d err=%v", n, consumed, err)
	}
}
