package webrender

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"virelai/flate"
	"virelai/webstyle"
)

// The Go standard library is the BSD-3-Clause host-only test reference.
// Corpus inputs below are original, generated from specified pixel vectors,
// not downloaded PNGs or external decoder code.
func pngChunk(name string, body []byte) []byte {
	out := make([]byte, 12+len(body))
	binary.BigEndian.PutUint32(out, uint32(len(body)))
	copy(out[4:], name)
	copy(out[8:], body)
	binary.BigEndian.PutUint32(out[8+len(body):], crc32.ChecksumIEEE(out[4:8+len(body)]))
	return out
}

func pngTestFile(t testing.TB, typ, filter byte, level int, trns bool) []byte {
	t.Helper()
	const w, h = 7, 5
	channels := map[byte]int{0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[typ]
	header := make([]byte, 13)
	binary.BigEndian.PutUint32(header[:4], w)
	binary.BigEndian.PutUint32(header[4:8], h)
	header[8], header[9] = 8, typ
	out := append([]byte(nil), pngMagic...)
	out = append(out, pngChunk("IHDR", header)...)
	if typ == 3 {
		out = append(out, pngChunk("PLTE", []byte{9, 200, 17, 244, 26, 9, 17, 31, 211})...)
	}
	if trns {
		values := map[byte][]byte{0: {0, 0}, 2: {0, 0, 0, 19, 0, 38}, 3: {0, 127}}
		out = append(out, pngChunk("tRNS", values[typ])...)
	}
	raw := make([]byte, w*h*channels)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			for c := 0; c < channels; c++ {
				value := byte(x*37 + y*53 + c*19)
				if typ == 3 {
					value = byte((x + y) % 3)
				}
				if typ == 4 && c == 1 || typ == 6 && c == 3 {
					value = []byte{0, 127, 255}[(x+y)%3]
				}
				raw[(y*w+x)*channels+c] = value
			}
		}
	}
	rows := make([]byte, 0, (w*channels+1)*h)
	for y := 0; y < h; y++ {
		rows = append(rows, filter)
		for i := 0; i < w*channels; i++ {
			p := y*w*channels + i
			a, b, c := 0, 0, 0
			if i >= channels {
				a = int(raw[p-channels])
			}
			if y > 0 {
				b = int(raw[p-w*channels])
				if i >= channels {
					c = int(raw[p-w*channels-channels])
				}
			}
			predict := 0
			switch filter {
			case 1:
				predict = a
			case 2:
				predict = b
			case 3:
				predict = (a + b) / 2
			case 4:
				dist := func(n int) int {
					if n < 0 {
						return -n
					}
					return n
				}
				q := a + b - c
				da, db, dc := dist(q-a), dist(q-b), dist(q-c)
				predict = c
				if da <= db && da <= dc {
					predict = a
				} else if db <= dc {
					predict = b
				}
			}
			rows = append(rows, byte(int(raw[p])-predict))
		}
	}
	var compressed bytes.Buffer
	z, err := zlib.NewWriterLevel(&compressed, level)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = z.Write(rows); err != nil {
		t.Fatal(err)
	}
	if err = z.Close(); err != nil {
		t.Fatal(err)
	}
	// Split IDAT across non-stream-aligned boundaries.
	stream := compressed.Bytes()
	split := len(stream) / 3
	out = append(out, pngChunk("IDAT", stream[:split])...)
	out = append(out, pngChunk("IDAT", stream[split:])...)
	return append(out, pngChunk("IEND", nil)...)
}

func checkPNGEquality(t testing.TB, data []byte) {
	t.Helper()
	got, err := DecodePNG(data)
	if err != nil {
		t.Fatal(err)
	}
	want, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	bounds := want.Bounds()
	if got.Width != bounds.Dx() || got.Height != bounds.Dy() {
		t.Fatalf("dimensions=%dx%d, stdlib=%v", got.Width, got.Height, bounds)
	}
	for y := 0; y < got.Height; y++ {
		for x := 0; x < got.Width; x++ {
			c := color.NRGBAModel.Convert(want.At(bounds.Min.X+x, bounds.Min.Y+y)).(color.NRGBA)
			p := uint32(c.A)<<24 | uint32(c.R)<<16 | uint32(c.G)<<8 | uint32(c.B)
			if got.At(x, y) != p {
				t.Fatalf("pixel (%d,%d)=%08x, stdlib straight RGBA8=%08x", x, y, got.At(x, y), p)
			}
		}
	}
}

func TestPNGStdlibEquality(t *testing.T) {
	for _, typ := range []byte{0, 2, 3, 4, 6} {
		for filter := byte(0); filter <= 4; filter++ {
			for _, level := range []int{zlib.NoCompression, zlib.HuffmanOnly, zlib.BestCompression} {
				name := string(rune('0'+typ)) + "-filter-" + string(rune('0'+filter))
				t.Run(name, func(t *testing.T) {
					data := pngTestFile(t, typ, filter, level, typ == 0 || typ == 2 || typ == 3)
					checkPNGEquality(t, data)
				})
			}
		}
	}
}

func TestPNGCorpusEquality(t *testing.T) {
	n, refused := 0, 0
	for _, pattern := range []string{"testdata/png/*.png", "testdata/corpus/*.png", "testdata/golden/*.png"} {
		paths, err := filepath.Glob(pattern)
		if err != nil {
			t.Fatal(err)
		}
		for _, path := range paths {
			if filepath.Ext(path) != ".png" || bytes.Contains([]byte(path), []byte(".actual.")) {
				continue
			}
			t.Run(path, func(t *testing.T) {
				data, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				config, err := png.DecodeConfig(bytes.NewReader(data))
				if err != nil {
					t.Fatal(err)
				}
				// Native 1280x720 frame goldens are comparator outputs,
				// not permitted <img> inputs. Never widen image caps to
				// admit those frames into the guest decoder.
				if config.Width > webstyle.MaxImageDimension || config.Height > webstyle.MaxImageDimension ||
					config.Width*config.Height > webstyle.MaxImagePixels {
					if im, err := DecodePNG(data); err != errPNGLimit || im != nil {
						t.Fatalf("out-of-cap reference frame: image=%v err=%v", im, err)
					}
					refused++
					return
				}
				checkPNGEquality(t, data)
				n++
			})
		}
	}
	if n == 0 {
		t.Fatal("PNG corpus is missing")
	}
	t.Logf("byte-equal to stdlib straight RGBA8 on %d pinned PNGs; %d out-of-cap native frames refused", n, refused)
}

func TestOwnedPNGCorpus(t *testing.T) {
	for _, typ := range []byte{0, 2, 3, 4, 6} {
		for filter := byte(0); filter <= 4; filter++ {
			data := pngTestFile(t, typ, filter, zlib.BestCompression, typ == 0 || typ == 2 || typ == 3)
			path := filepath.Join("testdata", "png", fmt.Sprintf("type-%d-filter-%d.png", typ, filter))
			if os.Getenv("WEBRENDER_CREATE_PNG_CORPUS") == "1" {
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
				t.Fatal(err)
			}
			if !bytes.Equal(pinned, data) {
				t.Fatalf("owned corpus vector drift: %s", path)
			}
			checkPNGEquality(t, pinned)
		}
	}
}

func TestPNGInflateIntegrity(t *testing.T) {
	valid := pngTestFile(t, 6, 0, zlib.BestCompression, false)
	var stream []byte
	for pos := 8; pos < len(valid); {
		n := int(binary.BigEndian.Uint32(valid[pos:]))
		if string(valid[pos+4:pos+8]) == "IDAT" {
			stream = append(stream, valid[pos+8:pos+8+n]...)
		}
		pos += 12 + n
	}
	badAdler := append([]byte(nil), stream...)
	badAdler[len(badAdler)-1] ^= 1
	for name, compressed := range map[string][]byte{
		"adler":         badAdler,
		"second-stream": append(append([]byte(nil), stream...), stream...),
		"excess-output": flate.ZlibStore(make([]byte, (7*4+1)*5+1)),
		"short-output":  flate.ZlibStore(make([]byte, (7*4+1)*5-1)),
	} {
		t.Run(name, func(t *testing.T) {
			data := append(append(append([]byte(nil), valid[:33]...), pngChunk("IDAT", compressed)...), pngChunk("IEND", nil)...)
			if im, err := DecodePNG(data); err == nil || im != nil {
				t.Fatal("invalid inflate framing accepted")
			}
		})
	}
}

func replacePNGChunk(data []byte, name string, f func([]byte) []byte) []byte {
	out := append([]byte(nil), data[:8]...)
	for pos := 8; pos < len(data); {
		n := int(binary.BigEndian.Uint32(data[pos:]))
		kind := string(data[pos+4 : pos+8])
		body := append([]byte(nil), data[pos+8:pos+8+n]...)
		if kind == name {
			body = f(body)
		}
		out = append(out, pngChunk(kind, body)...)
		pos += 12 + n
	}
	return out
}

func TestPNGMalformed(t *testing.T) {
	valid := pngTestFile(t, 6, 4, zlib.BestCompression, false)
	badCRC := append([]byte(nil), valid...)
	badCRC[29] ^= 1
	cases := map[string][]byte{
		"crc":        badCRC,
		"bad-filter": pngTestFile(t, 6, 5, zlib.NoCompression, false),
		"zero-width": replacePNGChunk(valid, "IHDR", func(b []byte) []byte {
			binary.BigEndian.PutUint32(b, 0)
			return b
		}),
		"missing-palette": replacePNGChunk(pngTestFile(t, 3, 0, zlib.NoCompression, false), "PLTE", func([]byte) []byte { return nil }),
		"alpha-trns":      append(append(append([]byte(nil), valid[:33]...), pngChunk("tRNS", []byte{0, 0})...), valid[33:]...),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if im, err := DecodePNG(data); err == nil || im != nil {
				t.Fatal("malformed input accepted")
			}
			if _, err := png.Decode(bytes.NewReader(data)); err == nil {
				t.Fatal("stdlib accepted the malformed reference vector")
			}
		})
	}
	for i := 0; i < len(valid); i++ {
		if im, err := DecodePNG(valid[:i]); err == nil || im != nil {
			t.Fatalf("truncation at %d accepted", i)
		}
	}
}

func TestPNGCapsAndUnsupported(t *testing.T) {
	valid := pngTestFile(t, 6, 0, zlib.NoCompression, false)
	for _, pair := range [][2]uint32{{1025, 1}, {1, 1025}, {513, 512}, {0xffffffff, 0xffffffff}} {
		data := replacePNGChunk(valid, "IHDR", func(b []byte) []byte {
			binary.BigEndian.PutUint32(b, pair[0])
			binary.BigEndian.PutUint32(b[4:], pair[1])
			return b
		})
		if im, err := DecodePNG(data); err != errPNGLimit || im != nil {
			t.Fatalf("dimensions %v: image=%v err=%v", pair, im, err)
		}
	}
	for _, field := range []int{8, 12} {
		data := replacePNGChunk(valid, "IHDR", func(b []byte) []byte {
			if field == 8 {
				b[field] = 16
			} else {
				b[field] = 1
			}
			return b
		})
		if _, err := DecodePNG(data); err != ErrImageUnsupported {
			t.Fatalf("unsupported header field %d: %v", field, err)
		}
	}
	if _, err := DecodePNG(make([]byte, webstyle.MaxImageBytes+1)); err != errPNGLimit {
		t.Fatal("source cap not honored")
	}
	ancillary := append([]byte(nil), valid[:33]...)
	for i := 0; i < maxPNGChunks; i++ {
		ancillary = append(ancillary, pngChunk("teSt", nil)...)
	}
	ancillary = append(ancillary, valid[33:]...)
	if _, err := DecodePNG(ancillary); err != errPNGLimit {
		t.Fatalf("chunk cap: %v", err)
	}
	if _, err := DecodePNG(append(valid, 0)); err == nil {
		t.Fatal("trailing bytes accepted")
	}
	critical := append(append(append([]byte(nil), valid[:33]...), pngChunk("ABCD", nil)...), valid[33:]...)
	if _, err := DecodePNG(critical); err != ErrImageUnsupported {
		t.Fatalf("unknown critical chunk: %v", err)
	}
}

func FuzzPNG(f *testing.F) {
	for _, typ := range []byte{0, 2, 3, 4, 6} {
		for filter := byte(0); filter <= 4; filter++ {
			f.Add(pngTestFile(f, typ, filter, zlib.BestCompression, typ == 3))
		}
	}
	f.Add([]byte{})
	f.Add([]byte("not png"))
	f.Fuzz(func(t *testing.T, data []byte) {
		im, err := DecodePNG(data)
		if err != nil {
			if im != nil {
				t.Fatal("partial successful-looking image on error")
			}
			return
		}
		if im.Width <= 0 || im.Height <= 0 || im.Width > webstyle.MaxImageDimension ||
			im.Height > webstyle.MaxImageDimension || len(im.Pix) != im.Width*im.Height ||
			len(im.Pix) > webstyle.MaxImagePixels || len(data) > webstyle.MaxImageBytes {
			t.Fatal("decoder cap violated")
		}
		checkPNGEquality(t, data)
	})
}
