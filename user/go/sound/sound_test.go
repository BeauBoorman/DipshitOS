// Host corpus for the M99c (#2181) WAV half of GOSOUND.ELF. These pin the
// card's acceptance list verbatim: every supported `fmt ` shape, every named
// refusal, the odd-padding walk, the chunk bound, the container sniff — and
// the resampler's golden vector plus its exact output-count contract (the
// same ceil the live gate recomputes in Python). No guest, no syscall.
package main

import (
	"errors"
	"math"
	"testing"
)

// sliceSrc adapts a byte slice to byteSource, one fill per call.
type sliceSrc struct {
	b   []byte
	off int
}

func (s *sliceSrc) src() byteSource {
	return func(buf []byte) (int, error) {
		if s.off >= len(s.b) {
			return 0, nil
		}
		n := copy(buf, s.b[s.off:])
		s.off += n
		return n, nil
	}
}

// File layout constants for the builders below: RIFF hdr is 12 bytes, the
// fmt chunk header is 8 more, so the fmt body is bytes 20..36 and the first
// trailing chunk (data) starts at 36.
const (
	fmtBodyOff  = 20
	afterFmtOff = 36
)

// wav builds a RIFF/WAVE file: fmt chunk then data. chunks are any extra
// (fourCC, body) pairs spliced between them.
func wav(tag, ch uint16, rate uint32, bits uint16, data []byte, chunks ...[2][]byte) []byte {
	return wavSized(tag, ch, rate, bits, data, 0, chunks...)
}

// wavSized is wav with a data chunk DECLARED as dataLen bytes while only
// len(data) bytes are actually appended — the "data beyond eof" fixture.
// dataLen 0 means the real length.
func wavSized(tag, ch uint16, rate uint32, bits uint16, data []byte, dataLen int, chunks ...[2][]byte) []byte {
	if dataLen == 0 {
		dataLen = len(data)
	}
	fb := int(ch) * int(bits) / 8
	fmtBody := make([]byte, 16)
	fmtBody[0], fmtBody[1] = byte(tag), byte(tag>>8)
	fmtBody[2], fmtBody[3] = byte(ch), byte(ch>>8)
	fmtBody[4], fmtBody[5], fmtBody[6], fmtBody[7] = byte(rate), byte(rate>>8), byte(rate>>16), byte(rate>>24)
	avg := uint32(rate) * uint32(fb)
	fmtBody[8], fmtBody[9], fmtBody[10], fmtBody[11] = byte(avg), byte(avg>>8), byte(avg>>16), byte(avg>>24)
	fmtBody[12], fmtBody[13] = byte(fb), byte(fb>>8)
	fmtBody[14], fmtBody[15] = byte(bits), byte(bits>>8)

	out := append([]byte("RIFF"), 0, 0, 0, 0)
	out = append(out, "WAVE"...)
	emit := func(fourcc string, body []byte, declared int) {
		out = append(out, fourcc...)
		out = append(out, byte(declared), byte(declared>>8), byte(declared>>16), byte(declared>>24))
		out = append(out, body...)
		if declared%2 != 0 {
			out = append(out, 0) // the RIFF pad byte
		}
	}
	emit("fmt ", fmtBody, len(fmtBody))
	for _, c := range chunks {
		emit(string(c[0][:4]), c[1], len(c[1]))
	}
	emit("data", data[:min(len(data), dataLen)], dataLen)
	sz := uint32(len(out) - 8)
	out[4], out[5], out[6], out[7] = byte(sz), byte(sz>>8), byte(sz>>16), byte(sz>>24)
	return out
}

// wavExt builds a 40-byte WAVE_FORMAT_EXTENSIBLE fmt chunk whose sub-format
// GUID is `sub` (1 = PCM, 3 = float) with the standard tail.
func wavExt(sub, ch uint16, rate uint32, bits uint16, data []byte) []byte {
	base := wav(0xfffe, ch, rate, bits, data)
	body := make([]byte, 40)
	copy(body, base[fmtBodyOff:afterFmtOff]) // tag/ch/rate/avg/align/bits
	body[16], body[17] = 22, 0               // cbSize
	body[18], body[19] = byte(bits), byte(bits>>8)
	// channel mask 0 at 20..23
	body[24], body[25] = byte(sub), byte(sub>>8)
	copy(body[26:40], []byte{0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
		0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71})
	var out []byte
	out = append(out, "RIFF"...)
	out = append(out, 0, 0, 0, 0)
	out = append(out, "WAVE"...)
	out = append(out, "fmt "...)
	out = append(out, 40, 0, 0, 0)
	out = append(out, body...)
	out = append(out, base[afterFmtOff:]...) // the data chunk
	sz := uint32(len(out) - 8)
	out[4], out[5], out[6], out[7] = byte(sz), byte(sz>>8), byte(sz>>16), byte(sz>>24)
	return out
}

func parse(t *testing.T, b []byte) WavInfo {
	t.Helper()
	s := &sliceSrc{b: b}
	info, err := ParseWav(s.src(), uint64(len(b)))
	if err != nil {
		t.Fatalf("ParseWav refused a valid file: %v", err)
	}
	return info
}

func refuseName(t *testing.T, b []byte) string {
	t.Helper()
	s := &sliceSrc{b: b}
	_, err := ParseWav(s.src(), uint64(len(b)))
	if err == nil {
		t.Fatal("ParseWav accepted a file the card refuses")
	}
	var we *WavError
	if errors.As(err, &we) {
		if we.Detail != 0 {
			return we.Name + " " + itoa(we.Detail)
		}
		return we.Name
	}
	if errors.Is(err, ErrNeedMore) {
		return "truncated header"
	}
	t.Fatalf("untyped error: %v", err)
	return ""
}

func TestParseAccepts(t *testing.T) {
	pcm := make([]byte, 44100*4) // one second of stereo s16 silence
	cases := []struct {
		name string
		b    []byte
		want WavInfo
	}{
		{"pcm16 stereo 44.1k", wav(1, 2, 44100, 16, pcm[:4096]),
			WavInfo{Tag: 1, Channels: 2, Rate: 44100, Bits: 16, DataSize: 4096, Frames: 1024}},
		{"pcm8 mono 8k", wav(1, 1, 8000, 8, make([]byte, 8000)),
			WavInfo{Tag: 1, Channels: 1, Rate: 8000, Bits: 8, DataSize: 8000, Frames: 8000}},
		{"pcm24 stereo 22.05k", wav(1, 2, 22050, 24, make([]byte, 600*6)),
			WavInfo{Tag: 1, Channels: 2, Rate: 22050, Bits: 24, DataSize: 3600, Frames: 600}},
		{"pcm32 mono 48k", wav(1, 1, 48000, 32, make([]byte, 4800*4)),
			WavInfo{Tag: 1, Channels: 1, Rate: 48000, Bits: 32, DataSize: 19200, Frames: 4800}},
		{"float32 stereo 48k", wav(3, 2, 48000, 32, make([]byte, 3200)),
			WavInfo{Tag: 3, Channels: 2, Rate: 48000, Bits: 32, DataSize: 3200, Frames: 400}},
		{"extensible pcm", wavExt(1, 2, 44100, 16, pcm[:1024]),
			WavInfo{Tag: 1, Channels: 2, Rate: 44100, Bits: 16, DataSize: 1024, Frames: 256}},
		{"extensible float", wavExt(3, 1, 96000, 32, pcm[:4096]),
			WavInfo{Tag: 3, Channels: 1, Rate: 96000, Bits: 32, DataSize: 4096, Frames: 1024}},
		// Odd-size chunk: a 3-byte LIST body carries the pad byte, and the
		// walk must step over both before finding data.
		{"odd chunk padding",
			wav(1, 1, 8000, 8, make([]byte, 64), [2][]byte{[]byte("LIST"), []byte("abc")}),
			WavInfo{Tag: 1, Channels: 1, Rate: 8000, Bits: 8, DataSize: 64, Frames: 64}},
		// fmt can legally be 18 bytes (PCM with cbSize=0).
		{"fmt size 18", wav18(make([]byte, 64)),
			WavInfo{Tag: 1, Channels: 1, Rate: 8000, Bits: 8, DataSize: 64, Frames: 64}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := parse(t, c.b)
			if got != c.want {
				t.Fatalf("got %+v, want %+v", got, c.want)
			}
		})
	}
}

// wav18 builds a file with an 18-byte fmt chunk (PCM + cbSize).
func wav18(data []byte) []byte {
	base := wav(1, 1, 8000, 8, data)
	var out []byte
	out = append(out, base[:16]...)                    // RIFF/WAVE/"fmt "
	out = append(out, 18, 0, 0, 0)                     // size = 18
	out = append(out, base[fmtBodyOff:afterFmtOff]...) // the 16-byte fmt body
	out = append(out, 0, 0)                            // cbSize = 0
	out = append(out, base[afterFmtOff:]...)           // data chunk
	sz := uint32(len(out) - 8)
	out[4], out[5], out[6], out[7] = byte(sz), byte(sz>>8), byte(sz>>16), byte(sz>>24)
	return out
}

func TestParseRefuses(t *testing.T) {
	pcm := make([]byte, 256)
	cases := []struct {
		name string
		b    []byte
		want string
	}{
		{"truncated header", []byte("RIFF"), "truncated header"},
		{"not riff", append([]byte("NOPE"), wav(1, 1, 8000, 8, pcm)...), "not a RIFF/WAVE file"},
		{"data beyond eof", wavSized(1, 1, 8000, 8, pcm[:64], 4096), "data beyond eof"},
		{"three channels", wav(1, 3, 8000, 8, pcm), "channels 3"},
		{"rate too low", wav(1, 1, 4000, 8, pcm), "rate 4000"},
		{"rate too high", wav(1, 1, 192000, 8, pcm), "rate 192000"},
		// The card's named example: 0x0055 is mp3-in-wav.
		{"mp3-in-wav", wav(0x0055, 1, 8000, 8, pcm), "fmt tag 0x0055 mp3-in-wav"},
		{"alaw", wav(0x0006, 1, 8000, 8, pcm), "fmt tag 0x0006 alaw"},
		{"unknown tag", wav(0x1234, 1, 8000, 8, pcm), "fmt tag 4660"},
		{"odd bits", wav(1, 1, 8000, 12, pcm), "bits 12"},
		{"float16", wav(3, 1, 8000, 16, pcm), "bits 16"},
		{"data before fmt", dataFirst(pcm), "data before fmt"},
		{"chunk walk bound", manyChunks(pcm), "chunks 32"},
		{"bad block align", badAlign(pcm), "block align 2"},
		{"fmt size 12", fmtSize(pcm, 12), "fmt size 12"},
		{"fmt size 24", fmtSize(pcm, 24), "fmt size 24"},
		{"bad ext guid", wavExtBadTail(pcm), "extensible subformat"},
		{"ext adpcm", wavExt(2, 1, 8000, 8, pcm), "extensible tag 2"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := refuseName(t, c.b); got != c.want {
				t.Fatalf("refused %q, want %q", got, c.want)
			}
		})
	}
}

// dataFirst puts a data chunk before fmt — legal RIFF, refused by the card
// (the streamer needs the geometry before it can size the data).
func dataFirst(data []byte) []byte {
	full := wav(1, 1, 8000, 8, data)
	var out []byte
	out = append(out, full[:12]...)   // RIFF/WAVE
	out = append(out, full[36:44]...) // data header (declared size intact)
	out = append(out, data...)        // the data body follows its header
	out = append(out, full[12:36]...) // fmt chunk, reordered after data
	sz := uint32(len(out) - 8)
	out[4], out[5], out[6], out[7] = byte(sz), byte(sz>>8), byte(sz>>16), byte(sz>>24)
	return out
}

// manyChunks fronts 33 junk chunks — one over the walk bound.
func manyChunks(data []byte) []byte {
	full := wav(1, 1, 8000, 8, data)
	var out []byte
	out = append(out, full[:12]...)
	for i := 0; i < 33; i++ {
		out = append(out, 'J', 'U', 'N', 'K', 2, 0, 0, 0, 0, 0)
	}
	out = append(out, full[12:]...)
	sz := uint32(len(out) - 8)
	out[4], out[5], out[6], out[7] = byte(sz), byte(sz>>8), byte(sz>>16), byte(sz>>24)
	return out
}

// badAlign declares block align != channels*bits/8.
func badAlign(data []byte) []byte {
	full := wav(1, 1, 8000, 8, data)
	full[32], full[33] = 2, 0 // block align field (fmt body +12)
	return full
}

// fmtSize writes a fmt chunk of arbitrary (refused) size.
func fmtSize(data []byte, n int) []byte {
	full := wav(1, 1, 8000, 8, data)
	var out []byte
	out = append(out, full[:16]...)                    // RIFF/WAVE/"fmt "
	out = append(out, byte(n), 0, 0, 0)                // size n
	out = append(out, full[fmtBodyOff:afterFmtOff]...) // the real 16-byte body
	out = append(out, make([]byte, max(0, n-16))...)   // pad to declared size
	out = append(out, full[afterFmtOff:]...)           // data chunk
	sz := uint32(len(out) - 8)
	out[4], out[5], out[6], out[7] = byte(sz), byte(sz>>8), byte(sz>>16), byte(sz>>24)
	return out
}

// wavExtBadTail corrupts the GUID tail of an extensible header — the tail
// byte sits at fmt-body offset 39, file offset fmtBodyOff+39.
func wavExtBadTail(data []byte) []byte {
	b := wavExt(1, 1, 8000, 8, data)
	b[fmtBodyOff+39] ^= 0xff
	return b
}

func TestContainer(t *testing.T) {
	cases := []struct {
		name, file string
		head       string
		want       string
	}{
		{"wav magic", "x.wav", "RIFF\x00\x00\x00\x00WAVEfmt ", "wav"},
		{"wav by ext", "x.wav", "\x00\x01", "wav"},
		{"ogg magic", "x.bin", "OggS", "ogg"},
		{"flac magic", "x.bin", "fLaC", "flac"},
		{"mp3 id3", "x.bin", "ID3\x04\x00", "mp3"},
		{"mp3 sync", "x.bin", "\xff\xfb\x90\x00", "mp3"},
		{"riff non-wave", "x.bin", "RIFF\x00\x00\x00\x00WEBP", "riff"},
		{"unknown", "x.bin", "\x00\x01\x02\x03\x04\x05\x06\x07", "unknown"},
		{"ogg by ext", "SOUND.OGG", "\x00", "ogg"},
	}
	for _, c := range cases {
		if got := Container(c.file, []byte(c.head)); got != c.want {
			t.Fatalf("%s: Container = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestOutFrames(t *testing.T) {
	cases := []struct{ in, inR, outR, want uint64 }{
		{0, 44100, 48000, 0},
		{1, 44100, 48000, 2},         // ceil(48000/44100)
		{44100, 44100, 48000, 48000}, // one second
		{44101, 44100, 48000, 48002}, // one frame past a second
		{1024, 22050, 48000, 2230},   // ceil(1024*48000/22050)
		{48000, 48000, 48000, 48000}, // identity
		{48000, 48000, 24000, 24000}, // 2:1 downsample
		{3, 24000, 48000, 6},         // golden-vector case below
		{8000, 8000, 48000, 48000},   // 1:6 upsample
	}
	for _, c := range cases {
		if got := OutFrames(c.in, c.inR, c.outR); got != c.want {
			t.Fatalf("OutFrames(%d,%d,%d) = %d, want %d", c.in, c.inR, c.outR, got, c.want)
		}
	}
}

// collect gathers every period the sink sees into one buffer (test-only —
// the point of Play is the guest never does this for a file).
func collect() (func([]byte) error, *[]byte) {
	var out []byte
	return func(p []byte) error {
		out = append(out, p...)
		return nil
	}, &out
}

// TestResampleGolden is the exact-output pin the card asks for: a three-frame
// s16 ramp at 24 kHz upsampled 2:1 to f32 48 kHz. Linear interpolation makes
// the halves exact — {0, .25, .5, .75, 1, 1} — and the count is OutFrames'.
func TestResampleGolden(t *testing.T) {
	// Three mono s16 frames: 0, 16384 (0.5), 32767 (~1.0).
	in := []byte{0, 0, 0, 0x40, 0xff, 0x7f}
	info := WavInfo{Tag: FormatPCM, Channels: 1, Rate: 24000, Bits: 16,
		DataSize: uint64(len(in)), Frames: 3}
	out := OutFmt{Fmt: fmtFloat, Rate: 48000, Channels: 2}
	sink, buf := collect()
	p := NewPipe(info, out, 64, 64, ResampleLinear, sink)
	s := &sliceSrc{b: in}
	if err := p.Play(s.src()); err != nil {
		t.Fatal(err)
	}
	got := *buf
	wantFrames := uint64(6)
	if p.ProducedFrames() != wantFrames {
		t.Fatalf("produced %d frames, want %d", p.ProducedFrames(), wantFrames)
	}
	if uint64(len(got)) != wantFrames*8 {
		t.Fatalf("got %d bytes, want %d", len(got), wantFrames*8)
	}
	// Frame i = stereo f32 pair; L==R for a mono source.
	want := [][2]float32{
		{0, 0}, {0.25, 0.25}, {0.5, 0.5},
		{0.75, 0.75}, {1, 1}, {1, 1},
	}
	for i, w := range want {
		l := f32(got[i*8:])
		r := f32(got[i*8+4:])
		// s16 32767 decodes to 32767/32768 = 0.99996948…, scaled back into
		// the lerp the tail frames read 32767/32768 not 1.0. Compare with a
		// small epsilon rather than pretend the table is exact.
		const eps = 0.0001
		if d := l - w[0]; d > eps || d < -eps {
			t.Fatalf("frame %d L = %v, want %v", i, l, w[0])
		}
		if d := r - w[1]; d > eps || d < -eps {
			t.Fatalf("frame %d R = %v, want %v", i, r, w[1])
		}
	}
}

// f32 decodes a little-endian float32.
func f32(b []byte) float32 {
	return math.Float32frombits(le32(b))
}

// TestDownsampleGolden pins the 2:1 case: positions 0,2,4 of five frames —
// the resampler picks every other frame, no averaging.
func TestDownsampleGolden(t *testing.T) {
	in := []byte{
		0, 0, // 0
		0, 0x20, // 0.25
		0, 0x40, // 0.5
		0, 0x60, // 0.75
		0xff, 0x7f, // ~1.0
	}
	info := WavInfo{Tag: FormatPCM, Channels: 1, Rate: 48000, Bits: 16,
		DataSize: uint64(len(in)), Frames: 5}
	out := OutFmt{Fmt: fmtFloat, Rate: 24000, Channels: 1}
	sink, buf := collect()
	p := NewPipe(info, out, 64, 64, ResampleLinear, sink)
	s := &sliceSrc{b: in}
	if err := p.Play(s.src()); err != nil {
		t.Fatal(err)
	}
	if p.ProducedFrames() != 3 {
		t.Fatalf("produced %d, want 3", p.ProducedFrames())
	}
	want := []float32{0, 0.5, 1}
	for i, w := range want {
		if d := f32((*buf)[i*4:]) - w; d > 0.0001 || d < -0.0001 {
			t.Fatalf("frame %d = %v, want %v", i, f32((*buf)[i*4:]), w)
		}
	}
}

// TestStreamExactness plays a full 44.1 kHz mono file and asserts the byte
// count the seat sees equals ExpectedFrames * frameBytes — the identity the
// live gate asserts against `completed`.
func TestStreamExactness(t *testing.T) {
	// 1.5 s of mono s16 silence at 44100 — a non-round resample count.
	inFrames := uint64(66150)
	data := make([]byte, inFrames*2)
	info := WavInfo{Tag: FormatPCM, Channels: 1, Rate: 44100, Bits: 16,
		DataSize: uint64(len(data)), Frames: inFrames}
	out := OutFmt{Fmt: fmtFloat, Rate: 48000, Channels: 2}
	period := 4096
	var periods int
	var last int
	var total uint64
	sink := func(b []byte) error {
		periods++
		last = len(b)
		total += uint64(len(b))
		if len(b) > period || len(b)%8 != 0 {
			t.Fatalf("bad period size %d", len(b))
		}
		return nil
	}
	p := NewPipe(info, out, readBlock, period, ResampleLinear, sink)
	s := &sliceSrc{b: data}
	if err := p.Play(s.src()); err != nil {
		t.Fatal(err)
	}
	want := OutFrames(inFrames, 44100, 48000) * 8
	if total != want {
		t.Fatalf("streamed %d bytes, want %d", total, want)
	}
	if last == period {
		t.Fatalf("last period full; expected a partial flush for %d bytes", want)
	}
}

// TestConstantMemory plays a >1 MiB file and a 4 MiB file and asserts the
// allocation count does not grow — the card's streaming bound.
func TestConstantMemory(t *testing.T) {
	mk := func(frames uint64) (*Pipe, *sliceSrc) {
		data := make([]byte, frames*4)
		info := WavInfo{Tag: FormatPCM, Channels: 2, Rate: 44100, Bits: 16,
			DataSize: uint64(len(data)), Frames: frames}
		var n uint64
		p := NewPipe(info, OutFmt{Fmt: fmtFloat, Rate: 48000, Channels: 2},
			readBlock, 4096, ResampleSinc, func(b []byte) error { n += uint64(len(b)); return nil })
		return p, &sliceSrc{b: data}
	}
	// >1 MiB stereo s16.
	p1, s1 := mk(300000) // 1.2 MiB
	if err := p1.Play(s1.src()); err != nil {
		t.Fatal(err)
	}
	if p1.ProducedFrames() != OutFrames(300000, 44100, 48000) {
		t.Fatalf("1.2MiB: produced %d", p1.ProducedFrames())
	}
	small := testing.AllocsPerRun(20, func() {
		p, s := mk(300000)
		_ = p.Play(s.src())
	})
	big := testing.AllocsPerRun(20, func() {
		p, s := mk(1200000) // ~4.8 MiB
		_ = p.Play(s.src())
	})
	// NewPipe allocates its two buffers per run; the stream itself must add
	// nothing proportional to the input. A bound of 8 covers the pipe's
	// fixed allocations on any host Go version.
	if small > 8 || big > 8 {
		t.Fatalf("allocs grew or are unbounded: 1.2MiB=%v 4.8MiB=%v", small, big)
	}
}

// TestTruncatedMidStream refuses a file whose bytes end before the declared
// data size — the guest path when the size cross-check could not run.
func TestTruncatedMidStream(t *testing.T) {
	data := make([]byte, 512)
	info := WavInfo{Tag: FormatPCM, Channels: 1, Rate: 8000, Bits: 8,
		DataSize: 4096, Frames: 4096}
	p := NewPipe(info, OutFmt{Fmt: fmtS16, Rate: 48000, Channels: 2},
		readBlock, 4096, ResampleLinear, func(b []byte) error { return nil })
	s := &sliceSrc{b: data}
	err := p.Play(s.src())
	var we *WavError
	if !errors.As(err, &we) || we.Name != "data truncated" {
		t.Fatalf("got %v, want data truncated", err)
	}
}

// TestSinkErrorStops verifies a sink error unwinds Play — the guest's stop
// path relies on it.
func TestSinkErrorStops(t *testing.T) {
	boom := errors.New("boom")
	data := make([]byte, 8192)
	info := WavInfo{Tag: FormatPCM, Channels: 1, Rate: 48000, Bits: 16,
		DataSize: uint64(len(data)), Frames: 4096}
	p := NewPipe(info, OutFmt{Fmt: fmtS16, Rate: 48000, Channels: 2},
		readBlock, 4096, ResampleLinear, func(b []byte) error { return boom })
	s := &sliceSrc{b: data}
	if err := p.Play(s.src()); err != boom {
		t.Fatalf("got %v, want boom", err)
	}
}
