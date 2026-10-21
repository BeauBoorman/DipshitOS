package qoi

import (
	"bytes"
	"encoding/hex"
	"os"
	"testing"
)

const goldenLadderQOI = "716f696600000006000000040400c2fe112233c0feff80806bfe8040c0fea06f4002ffff000080c06bff1d2d3dff7f7f7f7f7f7f7f7f7f7f0000000000000001"

// ladderPix exercises every op the encoder can emit: a run over the flat
// head, an index hit on the revisited colour, a small diff, a luma jump, a
// full rgb step and an alpha change (rgba). 6x4 so no run needs the cap.
func ladderPix() (pix []uint32, w, h int) {
	w, h = 6, 4
	pix = make([]uint32, w*h)
	base := []uint32{
		0xff000000, 0xff000000, 0xff000000, // run of the initial pixel
		0xff112233, 0xff112233, // rgb + index-hit pair (revisited below)
		0xffff8080, 0xffff8081, // rgb then diff (+1 blue)
		0xff8040c0, 0xffa06f40, // rgb then luma-ish step
		0xff112233, // index: the colour from four pixels back
		0x80ff0000, // rgba: alpha leaves 0xff
		0x80ff0000, // run of the translucent red
		0x80ff0001,
	}
	copy(pix, base)
	for i := len(base); i < len(pix); i++ {
		pix[i] = 0xff102030 + uint32(i)*0x010101 // tail: small diffs
	}
	return pix, w, h
}

func TestEncodeRoundTrip(t *testing.T) {
	pix, w, h := ladderPix()
	enc := Encode(pix, w, h)
	if len(enc) < 14+8 || string(enc[:4]) != Magic {
		t.Fatalf("encoder did not emit a %s stream", Magic)
	}
	dw, dh, dec, err := Decode(enc, 1<<20, 1<<24)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if dw != w || dh != h {
		t.Fatalf("decoded dims %dx%d, want %dx%d", dw, dh, w, h)
	}
	for i := range dec {
		if dec[i] != pix[i] {
			t.Fatalf("round-trip mismatch at %d: %#08x != %#08x", i, dec[i], pix[i])
		}
	}
}

func TestEncodeRejectsGeometry(t *testing.T) {
	pix, w, h := ladderPix()
	for _, tc := range []struct {
		name string
		pix  []uint32
		w, h int
	}{
		{"zero width", pix, 0, h},
		{"negative height", pix, w, -1},
		{"short buffer", pix[:w*h-1], w, h},
	} {
		if enc := Encode(tc.pix, tc.w, tc.h); enc != nil {
			t.Fatalf("%s: Encode returned %d bytes, want nil", tc.name, len(enc))
		}
	}
}

// TestEncodeGolden pins the exact byte stream for the ladder pixmap. This is
// GOPAINT's byte-identity contract moved with the code: the promoted encoder
// must emit what qoienc.go emitted (issue #2986), so a stream diff here means
// saved canvases changed.
func TestEncodeGolden(t *testing.T) {
	pix, w, h := ladderPix()
	want, err := hex.DecodeString(goldenLadderQOI)
	if err != nil {
		t.Fatalf("golden hex: %v", err)
	}
	if got := Encode(pix, w, h); !bytes.Equal(got, want) {
		t.Fatalf("Encode bytes drifted:\n got %x\nwant %x", got, want)
	}
}

// TestEncodeFixtureRoundTrip decodes the viewer's own fixture, re-encodes it
// and decodes again: encode preserves the raster even when the emitted op
// stream differs from the file's (the fixture was not written by this
// encoder, so byte equality with the source is not the contract — pixel
// equality is).
func TestEncodeFixtureRoundTrip(t *testing.T) {
	data, err := os.ReadFile("../../../../tests/fixtures/qoi/viewer_160x120.qoi")
	if err != nil {
		t.Skipf("fixture unavailable: %v", err)
	}
	w, h, pix, err := Decode(data, 1<<20, 1<<24)
	if err != nil {
		t.Fatalf("fixture Decode: %v", err)
	}
	dw, dh, dec, err := Decode(Encode(pix, w, h), 1<<20, 1<<24)
	if err != nil {
		t.Fatalf("re-Decode: %v", err)
	}
	if dw != w || dh != h {
		t.Fatalf("dims %dx%d, want %dx%d", dw, dh, w, h)
	}
	for i := range dec {
		if dec[i] != pix[i] {
			t.Fatalf("fixture round-trip mismatch at %d", i)
		}
	}
}
