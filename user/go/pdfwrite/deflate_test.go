package pdfwrite

import (
	"bytes"
	"compress/zlib"
	"io"
	"math/rand"
	"testing"

	"virelai/flate"
)

func buffers(rng *rand.Rand) map[string][]byte {
	random := func(n int) []byte {
		b := make([]byte, n)
		rng.Read(b)
		return b
	}
	zeros := func(n int) []byte { return make([]byte, n) }
	pattern := func(n int, p []byte) []byte {
		b := make([]byte, n)
		for i := range b {
			b[i] = p[i%len(p)]
		}
		return b
	}
	counter := func(n int) []byte {
		b := make([]byte, n)
		for i := range b {
			b[i] = byte(i)
		}
		return b
	}
	return map[string][]byte{
		"empty":             {},
		"one":               {'x'},
		"two":               {'a', 'b'},
		"three":             {'a', 'b', 'c'},
		"random-257":        random(257),
		"random-258":        random(258),
		"random-259":        random(259),
		"random-64k":        random(65536),
		"random-1m":         random(1 << 20),
		"zeros-4":           zeros(4),
		"zeros-64k":         zeros(65536),
		"zeros-300k":        zeros(300_000),
		"abab-64k":          pattern(65536, []byte("ab")),
		"text-256k":         pattern(262144, []byte("the quick brown fox jumps over the lazy dog. ")),
		"counter-64k":       counter(65536),
		"window-edge-33k":   append(random(32768), random(4)...),
		"far-match":         append(append([]byte("marker!"), zeros(32760)...), []byte("marker!")...),
		"overlap-match":     pattern(1000, []byte{7}),
		"sawtooth":          counter(300),
		"binary-structured": pattern(70000, []byte{0, 0, 0, 255, 128, 255, 0, 0}),
	}
}

func TestDeflateRoundTrip(t *testing.T) {
	rng := rand.New(rand.NewSource(9))
	for name, src := range buffers(rng) {
		enc := deflateZlib(src)
		if len(enc) < 6 || enc[0] != 0x78 || enc[1] != 0x01 {
			t.Fatalf("%s: bad zlib header %x", name, enc[:min(len(enc), 2)])
		}
		dst := make([]byte, len(src))
		n, consumed, err := flate.InflateZlib(dst, enc)
		if err != nil {
			t.Fatalf("%s: user/go/flate: %v", name, err)
		}
		if n != len(src) || consumed != len(enc) || !bytes.Equal(dst[:n], src) {
			t.Fatalf("%s: n=%d consumed=%d/%d equal=%v", name, n, consumed, len(enc), bytes.Equal(dst[:n], src))
		}
		r, err := zlib.NewReader(bytes.NewReader(enc))
		if err != nil {
			t.Fatalf("%s: std zlib: %v", name, err)
		}
		got, err := io.ReadAll(r)
		if err != nil || !bytes.Equal(got, src) {
			t.Fatalf("%s: std round trip: %v equal=%v", name, err, bytes.Equal(got, src))
		}
		r.Close()
	}
}

func TestQuarter(t *testing.T) {
	for n, want := range map[int64]string{
		0: "0", 4: "1", 100: "25", 3: "0.75", 6: "1.5", 9: "2.25",
		3168: "792", -3: "-0.75", -16: "-4", -6: "-1.5",
	} {
		if got := string(quarter(nil, n)); got != want {
			t.Fatalf("quarter(%d) = %q want %q", n, got, want)
		}
	}
}
