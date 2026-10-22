package pdf

import (
	"bytes"
	"errors"
	"os"
	"testing"

	"virelai/webrender"
)

// ADR 0040 A4: the DCT fixture is the pinned 32x32 grayscale baseline JPEG
// in testdata/ (license: testdata/SOURCES.txt), embedded in a one-page
// document that paints it 1:1 at page pixels (16,16)-(48,48) of a 64x64 page.
func dctJPEG(t *testing.T) []byte {
	data, err := os.ReadFile("testdata/dct-gray-32.jpg")
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func dctKeys(extra string) string {
	return "/Width 32 /Height 32 /BitsPerComponent 8 /ColorSpace /DeviceGray " + extra
}

func webDecoder(data []byte) (w, h int, pix []uint32, err error) {
	im, err := webrender.DecodeImage(data)
	if err != nil {
		return 0, 0, nil, err
	}
	return im.Width, im.Height, im.Pix, nil
}

// The hook is process-global state: every test that installs one must put
// the refusal back, or the policy table's unchanged rows would see it.
func withDecoder(t *testing.T, d func([]byte) (int, int, []uint32, error)) {
	t.Helper()
	SetImageDecoder(d)
	t.Cleanup(func() { SetImageDecoder(nil) })
}

func TestDCTHookAbsent(t *testing.T) {
	jpeg := dctJPEG(t)
	SetImageDecoder(nil)
	refusal(t, imageDocument("24 0 0 24 12 12 cm /I1 Do", jpeg, dctKeys("/Filter /DCTDecode")), UnsupportedFilter)
}

func TestDCTHookRenders(t *testing.T) {
	jpeg := dctJPEG(t)
	var staged []byte
	withDecoder(t, func(data []byte) (int, int, []uint32, error) {
		staged = append([]byte(nil), data...)
		return webDecoder(data)
	})
	p, _, _ := rendered(t, imageDocument("24 0 0 24 12 12 cm /I1 Do", jpeg, dctKeys("/Filter /DCTDecode")))
	if !bytes.Equal(staged, jpeg) {
		t.Fatal("hook did not receive the raw DCT stream")
	}
	im, err := webrender.DecodeImage(jpeg)
	if err != nil {
		t.Fatal(err)
	}
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			got := p.Pix[(16+y)*64+16+x]
			if got != im.Pix[y*32+x] {
				t.Fatalf("pixel (%d,%d) = %08x, want %08x", x, y, got, im.Pix[y*32+x])
			}
		}
	}
	if p.Pix[0] != 0xffffffff || p.Pix[63*64+63] != 0xffffffff {
		t.Fatal("page outside the image placement changed")
	}
}

func TestDCTArrayFilter(t *testing.T) {
	jpeg := dctJPEG(t)
	withDecoder(t, webDecoder)
	p, _, _ := rendered(t, imageDocument("24 0 0 24 12 12 cm /I1 Do", jpeg, dctKeys("/Filter [/DCTDecode]")))
	if p.Pix[16*64+16] == 0xffffffff {
		t.Fatal("single-element filter array was not admitted")
	}
}

func TestDCTRefusalsStand(t *testing.T) {
	jpeg := dctJPEG(t)
	withDecoder(t, webDecoder)
	// Progressive JPEG: SOF2 refuses by name inside the hook, and a decoder
	// error reaches the caller as UnsupportedFilter.
	sof0 := bytes.Index(jpeg, []byte{0xff, 0xc0})
	if sof0 < 0 {
		t.Fatal("fixture lost its SOF0 marker")
	}
	prog := append([]byte(nil), jpeg...)
	prog[sof0+1] = 0xc2
	refusal(t, imageDocument("24 0 0 24 12 12 cm /I1 Do", prog, dctKeys("/Filter /DCTDecode")), UnsupportedFilter)
	// No DecodeParms other than the default.
	for _, keys := range []string{
		"/Filter /DCTDecode /DecodeParms << /Predictor 1 >>",
		"/Filter [/DCTDecode] /DecodeParms [<< >>]",
		"/Filter /DCTDecode /DecodeParms [null null]",
	} {
		refusal(t, imageDocument("24 0 0 24 12 12 cm /I1 Do", jpeg, dctKeys(keys)), UnsupportedFilter)
	}
	// Filter chains and the other codec rows stay refused.
	refusal(t, imageDocument("24 0 0 24 12 12 cm /I1 Do", jpeg, dctKeys("/Filter [/FlateDecode /DCTDecode]")), UnsupportedFilter)
	refusal(t, imageDocument("24 0 0 24 12 12 cm /I1 Do", jpeg, dctKeys("/Filter /JPXDecode")), UnsupportedFilter)
	// DCTDecode is admitted on image XObjects only: a content stream still
	// refuses it.
	refusal(t, document("<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 48 48] /Contents 4 0 R >>", stream(jpeg, "/Filter /DCTDecode")), UnsupportedFilter)
}

func TestDCTHookFailures(t *testing.T) {
	jpeg := dctJPEG(t)
	src := imageDocument("24 0 0 24 12 12 cm /I1 Do", jpeg, dctKeys("/Filter /DCTDecode"))
	// A decoder error is UnsupportedFilter.
	withDecoder(t, func([]byte) (int, int, []uint32, error) {
		return 0, 0, nil, errors.New("decode failed")
	})
	refusal(t, src, UnsupportedFilter)
	SetImageDecoder(nil)
	// Decoded dimensions must equal the XObject's /Width and /Height.
	withDecoder(t, func([]byte) (int, int, []uint32, error) {
		return 16, 16, make([]uint32, 256), nil
	})
	refusal(t, src, MalformedStream)
	SetImageDecoder(nil)
	// A short raster is malformed too.
	withDecoder(t, func([]byte) (int, int, []uint32, error) {
		return 32, 32, make([]uint32, 512), nil
	})
	refusal(t, src, MalformedStream)
	SetImageDecoder(nil)
	// The decoded raster over the charged margin is MemoryLimit.
	big := imageDocument("24 0 0 24 12 12 cm /I1 Do", jpeg,
		"/Width 1024 /Height 1536 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /DCTDecode")
	withDecoder(t, func([]byte) (int, int, []uint32, error) {
		return 1024, 1536, make([]uint32, 1024*1536), nil
	})
	refusal(t, big, MemoryLimit)
	SetImageDecoder(nil)
	// The compressed stream over the staging span is MemoryLimit as well.
	oversize := imageDocument("24 0 0 24 12 12 cm /I1 Do", make([]byte, dctStageCap+1), dctKeys("/Filter /DCTDecode"))
	withDecoder(t, webDecoder)
	refusal(t, oversize, MemoryLimit)
}
