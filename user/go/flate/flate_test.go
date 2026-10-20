package flate

// Host-side tests. The Go standard library (compress/zlib, compress/flate)
// is the BSD-3-Clause host-only reference; the guest never imports it.

import (
	"bytes"
	stdflate "compress/flate"
	"compress/zlib"
	"io"
	"math/rand"
	"testing"
)

func TestInflateMatchesStdlibZlib(t *testing.T) {
	payloads := [][]byte{
		[]byte("hello, git\n"),
		bytes.Repeat([]byte("The quick brown fox. "), 40),
		{0, 1, 2, 3, 255},
	}
	for _, p := range payloads {
		var buf bytes.Buffer
		w := zlib.NewWriter(&buf)
		if _, err := w.Write(p); err != nil {
			t.Fatal(err)
		}
		if err := w.Close(); err != nil {
			t.Fatal(err)
		}
		out := make([]byte, len(p)+8)
		n, consumed, err := InflateZlib(out, buf.Bytes())
		if err != nil {
			t.Fatalf("inflate %q: %v", p, err)
		}
		if n != len(p) || !bytes.Equal(out[:n], p) {
			t.Fatalf("got %q want %q", out[:n], p)
		}
		if consumed != buf.Len() {
			t.Fatalf("consumed %d want %d", consumed, buf.Len())
		}
	}
}

func TestZlibStoreRoundTrip(t *testing.T) {
	p := []byte("hello, git\n")
	z := ZlibStore(p)
	out := make([]byte, len(p)+4)
	n, _, err := InflateZlib(out, z)
	if err != nil || n != len(p) || !bytes.Equal(out[:n], p) {
		t.Fatalf("store roundtrip n=%d err=%v got=%q", n, err, out[:n])
	}
}

// Concatenated zlib streams (a packfile's object list) are walked by the
// consumed count the reader reports.
func TestInflateZlibConcatenated(t *testing.T) {
	first := []byte("first object body")
	second := bytes.Repeat([]byte("second object body "), 30)
	blob := append(append([]byte(nil), ZlibStore(first)...), ZlibStore(second)...)
	out := make([]byte, len(first)+len(second))
	n, consumed, err := InflateZlib(out, blob)
	if err != nil || n != len(first) || !bytes.Equal(out[:n], first) {
		t.Fatalf("first: n=%d err=%v", n, err)
	}
	n, consumed2, err := InflateZlib(out[n:], blob[consumed:])
	if err != nil || n != len(second) || !bytes.Equal(out[len(first):][:n], second) {
		t.Fatalf("second: n=%d err=%v", n, err)
	}
	if consumed+consumed2 != len(blob) {
		t.Fatalf("consumed %d+%d != %d", consumed, consumed2, len(blob))
	}
}

// Named refusals stay pinned — callers and docs cite the strings.
func TestInflateRefusals(t *testing.T) {
	valid := ZlibStore([]byte("payload"))
	badAdler := append([]byte(nil), valid...)
	badAdler[len(badAdler)-1] ^= 1
	badHeader := append([]byte(nil), valid...)
	badHeader[0] = 0x08 // wrong compression method
	cases := []struct {
		name string
		src  []byte
		dst  int
		want string
	}{
		{"short", valid[:5], 64, "flate: corrupt stream"},
		{"header", badHeader, 64, "flate: invalid zlib header"},
		{"adler", badAdler, 64, "flate: adler32 mismatch"},
		{"bufsmall", valid, 2, "flate: buffer too small"},
	}
	for _, c := range cases {
		_, _, err := InflateZlib(make([]byte, c.dst), c.src)
		if err == nil || err.Error() != c.want {
			t.Fatalf("%s: err=%v want %q", c.name, err, c.want)
		}
	}
}

// Fuzz-style: random payloads at every stdlib level decode identically to
// host compress/zlib (framed) and compress/flate (raw); consumed lands
// exactly on the stream end. Mutated streams must fail or stay in bounds —
// never panic, never write past dst.
func TestInflateMatchesHostOnRandomStreams(t *testing.T) {
	rng := rand.New(rand.NewSource(0x136a))
	levels := []int{
		stdflate.NoCompression, stdflate.BestSpeed,
		stdflate.DefaultCompression, stdflate.BestCompression,
	}
	for i := 0; i < 400; i++ {
		p := randPayload(rng)
		level := levels[rng.Intn(len(levels))]

		var zb bytes.Buffer
		zw, err := zlib.NewWriterLevel(&zb, level)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := zw.Write(p); err != nil {
			t.Fatal(err)
		}
		if err := zw.Close(); err != nil {
			t.Fatal(err)
		}
		dst := make([]byte, len(p))
		n, consumed, err := InflateZlib(dst, zb.Bytes())
		if err != nil {
			t.Fatalf("iter %d zlib len=%d level=%d: %v", i, len(p), level, err)
		}
		if n != len(p) || !bytes.Equal(dst[:n], p) {
			t.Fatalf("iter %d zlib mismatch n=%d len=%d", i, n, len(p))
		}
		if consumed != zb.Len() {
			t.Fatalf("iter %d zlib consumed=%d want %d", i, consumed, zb.Len())
		}

		var rb bytes.Buffer
		fw, err := stdflate.NewWriter(&rb, level)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fw.Write(p); err != nil {
			t.Fatal(err)
		}
		if err := fw.Close(); err != nil {
			t.Fatal(err)
		}
		want, err := io.ReadAll(stdflate.NewReader(bytes.NewReader(rb.Bytes())))
		if err != nil || !bytes.Equal(want, p) {
			t.Fatalf("iter %d host raw decode broken: %v", i, err)
		}
		n, consumed, err = Inflate(dst, rb.Bytes())
		if err != nil {
			t.Fatalf("iter %d raw len=%d level=%d: %v", i, len(p), level, err)
		}
		if n != len(p) || !bytes.Equal(dst[:n], p) {
			t.Fatalf("iter %d raw mismatch n=%d len=%d", i, n, len(p))
		}
		if consumed != rb.Len() {
			t.Fatalf("iter %d raw consumed=%d want %d", i, consumed, rb.Len())
		}

		if i%8 == 0 {
			mut := append([]byte(nil), zb.Bytes()...)
			for j := 0; j < 1+rng.Intn(4); j++ {
				mut[rng.Intn(len(mut))] ^= byte(1 << rng.Intn(8))
			}
			mn, mc, merr := InflateZlib(make([]byte, len(p)*2+64), mut)
			if merr == nil && (mn > len(p)*2+64 || mc > len(mut)) {
				t.Fatalf("iter %d mutant n=%d consumed=%d out of bounds",
					i, mn, mc)
			}
		}
	}
}

// randPayload mixes incompressible noise with repeated runs so both the
// stored-block and huffman/match paths see traffic.
func randPayload(rng *rand.Rand) []byte {
	n := rng.Intn(1 + rng.Intn(8192))
	p := make([]byte, n)
	switch rng.Intn(4) {
	case 0: // pure noise
		rng.Read(p)
	case 1: // a repeated word
		w := make([]byte, 1+rng.Intn(16))
		rng.Read(w)
		for i := range p {
			p[i] = w[i%len(w)]
		}
	case 2: // noise islands inside a zero sea
		for n > 0 && rng.Intn(4) == 0 {
			p[rng.Intn(n)] = byte(rng.Intn(256))
		}
	default: // low-entropy alphabet
		for i := range p {
			p[i] = byte('a' + rng.Intn(4))
		}
	}
	return p
}
