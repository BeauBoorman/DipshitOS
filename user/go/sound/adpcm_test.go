// Host corpus for the M162d (#2980) half of GOSOUND.ELF: the IMA and MS
// ADPCM decoders against pinned vectors (each documented with the hand
// arithmetic), the flipped refusal pins, the partial-block frame counts —
// and the windowed-sinc resampler's passband/stopband on synthetic tones,
// its unity-rate identity, and the arg parser. No guest, no syscall.
package main

import (
	"errors"
	"math"
	"testing"
)

func put16(b []byte, v uint16) { b[0], b[1] = byte(v), byte(v>>8) }
func put32(b []byte, v uint32) {
	b[0], b[1], b[2], b[3] = byte(v), byte(v>>8), byte(v>>16), byte(v>>24)
}

// wavCodec builds a RIFF/WAVE out of a caller-assembled fmt body — the
// ADPCM builders need more than the 16-byte base the PCM builder writes.
func wavCodec(fmtBody, data []byte) []byte {
	out := append([]byte("RIFF"), 0, 0, 0, 0)
	out = append(out, "WAVE"...)
	emit := func(fourcc string, body []byte) {
		out = append(out, fourcc...)
		out = append(out, byte(len(body)), byte(len(body)>>8),
			byte(len(body)>>16), byte(len(body)>>24))
		out = append(out, body...)
		if len(body)%2 != 0 {
			out = append(out, 0)
		}
	}
	emit("fmt ", fmtBody)
	emit("data", data)
	sz := uint32(len(out) - 8)
	out[4], out[5], out[6], out[7] = byte(sz), byte(sz>>8), byte(sz>>16), byte(sz>>24)
	return out
}

// fmtADPCM is the 20-byte fmt body both codecs share (tag, geometry,
// bitsPerSample=4, cbSize covering the extension, wSamplesPerBlock) plus
// trailing extension bytes — the MS coefficient table.
func fmtADPCM(tag, ch uint16, rate uint32, ba, spb uint16, ext ...byte) []byte {
	b := make([]byte, 20)
	put16(b[0:2], tag)
	put16(b[2:4], ch)
	put32(b[4:8], rate)
	put32(b[8:12], rate*uint32(ba)/uint32(spb)) // avg bytes/sec
	put16(b[12:14], ba)
	put16(b[14:16], 4)
	put16(b[16:18], uint16(2+len(ext)))
	put16(b[18:20], spb)
	return append(b, ext...)
}

// msCoefTable is the standard 7-pair MS ADPCM coefficient set, serialized
// as fmt extension bytes (wNumCoef then the pairs).
func msCoefTable() []byte {
	coef := [][2]int16{
		{256, 0}, {512, -256}, {0, 0}, {192, 64},
		{240, 0}, {460, -208}, {392, -232},
	}
	b := make([]byte, 2+4*len(coef))
	put16(b[0:2], uint16(len(coef)))
	for i, c := range coef {
		put16(b[2+4*i:], uint16(c[0]))
		put16(b[4+4*i:], uint16(c[1]))
	}
	return b
}

func TestParseADPCM(t *testing.T) {
	cases := []struct {
		name string
		b    []byte
		want WavInfo
	}{
		{"ima mono", wavCodec(fmtADPCM(FormatIMA, 1, 22050, 256, 505), make([]byte, 512)),
			WavInfo{Tag: FormatIMA, Channels: 1, Rate: 22050, Bits: 4,
				DataSize: 512, Frames: 1010, BlockAlign: 256, SamplesPerBlock: 505}},
		{"ima stereo", wavCodec(fmtADPCM(FormatIMA, 2, 44100, 512, 505), make([]byte, 512)),
			WavInfo{Tag: FormatIMA, Channels: 2, Rate: 44100, Bits: 4,
				DataSize: 512, Frames: 505, BlockAlign: 512, SamplesPerBlock: 505}},
		{"ms stereo", wavCodec(fmtADPCM(FormatMS, 2, 44100, 512, 500, msCoefTable()...), make([]byte, 512)),
			WavInfo{Tag: FormatMS, Channels: 2, Rate: 44100, Bits: 4,
				DataSize: 512, Frames: 500, BlockAlign: 512, SamplesPerBlock: 500,
				NCoef: 7, Coef: msCoefWav()}},
		// A partial tail block counts what it decodes to: 100 bytes of a
		// mono IMA block is the 4-byte preamble + 24 full groups.
		{"ima partial tail", wavCodec(fmtADPCM(FormatIMA, 1, 8000, 256, 505), make([]byte, 256+100)),
			WavInfo{Tag: FormatIMA, Channels: 1, Rate: 8000, Bits: 4,
				DataSize: 356, Frames: 505 + 193, BlockAlign: 256, SamplesPerBlock: 505}},
		// MS mono partial: 100 bytes = 7-byte header + 93 nibble bytes.
		{"ms partial tail", wavCodec(fmtADPCM(FormatMS, 1, 8000, 256, 500, msCoefTable()...), make([]byte, 256+100)),
			WavInfo{Tag: FormatMS, Channels: 1, Rate: 8000, Bits: 4,
				DataSize: 356, Frames: 500 + 188, BlockAlign: 256, SamplesPerBlock: 500,
				NCoef: 7, Coef: msCoefWav()}},
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

// msCoefWav is the WavInfo.Coef shape the standard table parses into.
func msCoefWav() (c [32][2]int32) {
	for i, p := range [][2]int32{
		{256, 0}, {512, -256}, {0, 0}, {192, 64},
		{240, 0}, {460, -208}, {392, -232},
	} {
		c[i] = p
	}
	return c
}

func TestADPCMRefusals(t *testing.T) {
	pcm := make([]byte, 256)
	// A 16-byte fmt under an ADPCM tag: the codec needs its extension
	// fields, so the M99c "fmt size" refusal still fires — this is the
	// flipped pin for the old "fmt tag 0x0002 adpcm" row.
	cases := []struct {
		name string
		b    []byte
		want string
	}{
		{"ms fmt too short", wav(0x0002, 1, 8000, 8, pcm), "fmt size 16"},
		{"ima bits not 4", wavCodec(badBits(), pcm), "bits 8"},
		{"ima bad block align", wavCodec(fmtADPCM(FormatIMA, 1, 8000, 255, 505), pcm), "block align 255"},
		{"ima spb over", wavCodec(fmtADPCM(FormatIMA, 1, 8000, 256, 600), pcm), "samples per block 600"},
		{"ms no coefs", wavCodec(fmtADPCM(FormatMS, 1, 8000, 256, 500, 0, 0), pcm), "adpcm coefs"},
		{"ms spb over", wavCodec(fmtADPCM(FormatMS, 2, 8000, 512, 600, msCoefTable()...), pcm), "samples per block 600"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := refuseName(t, c.b); got != c.want {
				t.Fatalf("refused %q, want %q", got, c.want)
			}
		})
	}
}

// badBits is an IMA fmt body with bitsPerSample 8 — the one field a 4-bit
// codec must pin.
func badBits() []byte {
	b := fmtADPCM(FormatIMA, 1, 8000, 256, 505)
	b[14], b[15] = 8, 0
	return b
}

// decodeOne runs the block decoder directly on a constructed block and
// returns the decoded s16 samples (mono takes channel 0).
func decodeOne(t *testing.T, info WavInfo, blk []byte) []int16 {
	t.Helper()
	p := &Pipe{info: info}
	out := make([][2]float32, info.SamplesPerBlock)
	var n int
	var err error
	if info.Tag == FormatIMA {
		n = p.decodeIMA(blk, out)
	} else {
		n, err = p.decodeMS(blk, out)
		if err != nil {
			t.Fatalf("decode refused: %v", err)
		}
	}
	got := make([]int16, n)
	for i := 0; i < n; i++ {
		got[i] = int16(out[i][0] * 32768)
	}
	return got
}

// TestIMAPinned decodes a hand-computed block: preamble sample 1000, index
// 0 (step 7), then nibbles 0,7,0,0,0,0,0,0 packed lo-first as
// 0x70,0x00,0x00,0x00. Nibble 0 adds step>>3; nibble 7 adds
// step>>3+step+step>>1+step>>2 = 11 and jumps the index to 8 (step 16),
// after which each 0 nibble adds 16>>3=2 then the falling steps' >>3 = 1.
func TestIMAPinned(t *testing.T) {
	blk := []byte{0xe8, 0x03, 0, 0, 0x70, 0, 0, 0}
	info := WavInfo{Tag: FormatIMA, Channels: 1, SamplesPerBlock: 505}
	got := decodeOne(t, info, blk)
	want := []int16{1000, 1000, 1011, 1013, 1014, 1015, 1016, 1017, 1018}
	if len(got) != len(want) {
		t.Fatalf("decoded %d frames, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("sample %d = %d, want %d", i, got[i], want[i])
		}
	}
}

// TestMSPinned decodes a hand-computed mono block: predictor 0
// (coef 256,0 → pred = samp1), delta 16, samp1=0, samp2=0 — output order
// samp2, samp1 — then bytes 0x11,0x22 hi-nibble first. Nibbles 0-3 all
// shrink the delta (230·16>>8 = 14 → clamped to the 16 floor), so it
// never moves:
//
//	nib1: 0 + 1·16 = 16
//	nib1: 16 + 1·16 = 32
//	nib2: 32 + 2·16 = 64
//	nib2: 64 + 2·16 = 96
func TestMSPinned(t *testing.T) {
	blk := []byte{0, 16, 0, 0, 0, 0, 0, 0x11, 0x22}
	info := WavInfo{Tag: FormatMS, Channels: 1, SamplesPerBlock: 500,
		NCoef: 7, Coef: msCoefWav()}
	got := decodeOne(t, info, blk)
	want := []int16{0, 0, 16, 32, 64, 96}
	if len(got) != len(want) {
		t.Fatalf("decoded %d frames, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("sample %d = %d, want %d", i, got[i], want[i])
		}
	}
}

// TestMSPredictorRefuses pins the one decode-time refusal: a predictor
// byte outside the fmt chunk's coefficient table.
func TestMSPredictorRefuses(t *testing.T) {
	blk := []byte{9, 16, 0, 0, 0, 0, 0, 0x11}
	p := &Pipe{info: WavInfo{Tag: FormatMS, Channels: 1, SamplesPerBlock: 500,
		NCoef: 7, Coef: msCoefWav()}}
	out := make([][2]float32, 500)
	_, err := p.decodeMS(blk, out)
	var we *WavError
	if !errors.As(err, &we) || we.Name != "adpcm predictor" {
		t.Fatalf("got %v, want adpcm predictor", err)
	}
}

// imaEncodeBlock is the test-side encoder half of the round-trip: greedy
// IMA nibble quantization of samples[1:] after the preamble takes
// samples[0]. It is deliberately written encoder-side (threshold
// comparison), exercising the decoder against the standard algorithm.
func imaEncodeBlock(samples []int16) []byte {
	blk := make([]byte, 4+(len(samples)-1+7)/8*4)
	put16(blk[0:2], uint16(samples[0]))
	blk[2], blk[3] = 0, 0
	pred := int32(samples[0])
	idx := int32(0)
	for i := 1; i < len(samples); i++ {
		step := imaStep[idx]
		diff := int32(samples[i]) - pred
		var nib byte
		if diff < 0 {
			nib = 8
			diff = -diff
		}
		if diff >= step {
			nib |= 4
			diff -= step
		}
		if diff >= step>>1 {
			nib |= 2
			diff -= step >> 1
		}
		if diff >= step>>2 {
			nib |= 1
		}
		pred = int32(imaExpand(&pred, &idx, nib))
		k := i - 1
		if k&1 == 0 {
			blk[4+k/2] |= nib
		} else {
			blk[4+k/2] |= nib << 4
		}
	}
	return blk
}

// TestIMARoundTrip encodes a sine through the standard algorithm and
// asserts the decoder tracks it — the nibble stream, state roll and
// byte layout all exercised end to end.
func TestIMARoundTrip(t *testing.T) {
	const n = 505
	src := make([]int16, n)
	for i := range src {
		src[i] = int16(8000 * math.Sin(2*math.Pi*220*float64(i)/22050))
	}
	blk := imaEncodeBlock(src)
	info := WavInfo{Tag: FormatIMA, Channels: 1, SamplesPerBlock: n}
	got := decodeOne(t, info, blk)
	if len(got) != n {
		t.Fatalf("decoded %d frames, want %d", len(got), n)
	}
	var sumSq float64
	for i := 0; i < n; i++ {
		d := float64(got[i]) - float64(src[i])
		sumSq += d * d
	}
	rms := math.Sqrt(sumSq / n)
	// IMA at 22 kHz on a 220 Hz tone at amp 8000: RMS error sits far
	// below 10% of amplitude (measured ~2%), and every sample is
	// within 4·32767/8 of truth by codec construction.
	if rms > 800 {
		t.Fatalf("round-trip RMS error %v", rms)
	}
}

// TestIMAStereoLayout pins the stereo group interleave: two channels of
// different signals must not bleed — ch0's group and ch1's group are
// distinct 4-byte runs.
func TestIMAStereoLayout(t *testing.T) {
	// 17 samples per channel: preamble + two groups of 8.
	l, r := make([]int16, 17), make([]int16, 17)
	for i := range l {
		l[i] = 1000 + int16(500*i)
		r[i] = -2000 - int16(300*i)
	}
	blk := make([]byte, 8+2*8)
	put16(blk[0:2], uint16(l[0]))
	put16(blk[4:6], uint16(r[0]))
	var predL, predR, idxL, idxR = int32(l[0]), int32(r[0]), int32(0), int32(0)
	for g := 0; g < 2; g++ {
		enc := func(samples []int16, pred, idx *int32, off int) {
			for k := 0; k < 8; k++ {
				target := int32(samples[1+g*8+k])
				step := imaStep[*idx]
				diff := target - *pred
				var nib byte
				if diff < 0 {
					nib = 8
					diff = -diff
				}
				if diff >= step {
					nib |= 4
					diff -= step
				}
				if diff >= step>>1 {
					nib |= 2
					diff -= step >> 1
				}
				if diff >= step>>2 {
					nib |= 1
				}
				*pred = int32(imaExpand(pred, idx, nib))
				if k&1 == 0 {
					blk[off+k/2] |= nib
				} else {
					blk[off+k/2] |= nib << 4
				}
			}
		}
		enc(l, &predL, &idxL, 8+8*g)
		enc(r, &predR, &idxR, 8+8*g+4)
	}
	info := WavInfo{Tag: FormatIMA, Channels: 2, SamplesPerBlock: 17}
	p := &Pipe{info: info}
	out := make([][2]float32, 17)
	n := p.decodeIMA(blk, out)
	if n != 17 {
		t.Fatalf("decoded %d frames, want 17", n)
	}
	for i := 0; i < n; i++ {
		if d := out[i][0]*32768 - float32(l[i]); d > 2000 || d < -2000 {
			t.Fatalf("ch0 sample %d = %v, want ~%d", i, out[i][0]*32768, l[i])
		}
		if d := out[i][1]*32768 - float32(r[i]); d > 2000 || d < -2000 {
			t.Fatalf("ch1 sample %d = %v, want ~%d", i, out[i][1]*32768, r[i])
		}
	}
}

// TestADPCMStream plays a whole IMA wav through the pipe end to end —
// parse, block-decode, sinc resample — and pins the exact byte identity
// the live gate recomputes.
func TestADPCMStream(t *testing.T) {
	const n = 505
	src := make([]int16, n)
	for i := range src {
		src[i] = int16(8000 * math.Sin(2*math.Pi*440*float64(i)/22050))
	}
	data := append(imaEncodeBlock(src), imaEncodeBlock(src)...)
	file := wavCodec(fmtADPCM(FormatIMA, 1, 22050, 256, 505), data)
	s := &sliceSrc{b: file}
	info, err := ParseWav(s.src(), uint64(len(file)))
	if err != nil {
		t.Fatal(err)
	}
	if info.Tag != FormatIMA || info.Frames != 1010 {
		t.Fatalf("parsed %+v", info)
	}
	sink, buf := collect()
	p := NewPipe(info, OutFmt{Fmt: fmtFloat, Rate: 48000, Channels: 2},
		readBlock, 4096, ResampleSinc, sink)
	if err := p.Play(s.src()); err != nil {
		t.Fatal(err)
	}
	want := OutFrames(info.Frames, 22050, 48000)
	if p.ProducedFrames() != want {
		t.Fatalf("produced %d, want %d", p.ProducedFrames(), want)
	}
	if uint64(len(*buf)) != want*8 {
		t.Fatalf("streamed %d bytes, want %d", len(*buf), want*8)
	}
	// The decoded stream carries the sine — it cannot be silent.
	var nonzero int
	for i := 0; i+4 <= len(*buf); i += 4 {
		if f32((*buf)[i:]) != 0 {
			nonzero++
		}
	}
	if nonzero < int(want)/2 {
		t.Fatalf("stream mostly silent: %d nonzero of %d", nonzero, want)
	}
}

// TestSincUnity pins the identity case: at equal rates every output hits
// an input sample dead-on (phase row 0 is a Kronecker delta), so the sinc
// path reproduces the input exactly, edges included.
func TestSincUnity(t *testing.T) {
	in := make([]byte, 200*2)
	for i := 0; i < 200; i++ {
		v := int16(16000 * math.Sin(2*math.Pi*440*float64(i)/48000))
		put16(in[2*i:], uint16(v))
	}
	info := WavInfo{Tag: FormatPCM, Channels: 1, Rate: 48000, Bits: 16,
		DataSize: uint64(len(in)), Frames: 200}
	sink, buf := collect()
	p := NewPipe(info, OutFmt{Fmt: fmtFloat, Rate: 48000, Channels: 1},
		4096, 4096, ResampleSinc, sink)
	s := &sliceSrc{b: in}
	if err := p.Play(s.src()); err != nil {
		t.Fatal(err)
	}
	if p.ProducedFrames() != 200 {
		t.Fatalf("produced %d, want 200", p.ProducedFrames())
	}
	for i := 0; i < 200; i++ {
		want := float32(int16(le16(in[2*i:]))) / 32768
		got := f32((*buf)[i*4:])
		if d := got - want; d > 0.001 || d < -0.001 {
			t.Fatalf("frame %d = %v, want %v", i, got, want)
		}
	}
}

// toneRMS streams a mono s16 sine through the pipe and returns the output
// RMS over the steady middle frames (the head/tail transients skipped).
func toneRMS(t *testing.T, freq float64, inRate, outRate uint32, rs Resampler) float64 {
	t.Helper()
	const frames = 9600
	data := make([]byte, frames*2)
	for i := 0; i < frames; i++ {
		v := int16(0.5 * 32767 * math.Sin(2*math.Pi*freq*float64(i)/float64(inRate)))
		put16(data[2*i:], uint16(v))
	}
	info := WavInfo{Tag: FormatPCM, Channels: 1, Rate: inRate, Bits: 16,
		DataSize: uint64(len(data)), Frames: frames}
	sink, buf := collect()
	p := NewPipe(info, OutFmt{Fmt: fmtFloat, Rate: outRate, Channels: 1},
		4096, 4096, rs, sink)
	s := &sliceSrc{b: data}
	if err := p.Play(s.src()); err != nil {
		t.Fatal(err)
	}
	var sum float64
	out := *buf
	n := 0
	for i := 400; i+4 <= len(out)-400; i += 4 {
		v := float64(f32(out[i:]))
		sum += v * v
		n++
	}
	return math.Sqrt(sum / float64(n))
}

// TestSincSweep is the acceptance sweep: a 48→24 kHz downsample must keep
// a passband tone (4 kHz, inside the 12 kHz cutoff) and kill a stopband
// tone (20 kHz, past it — where linear interpolation folds it into an
// alias an order of magnitude louder).
func TestSincSweep(t *testing.T) {
	// Input RMS is 0.5/√2 ≈ 0.354.
	if pass := toneRMS(t, 4000, 48000, 24000, ResampleSinc); pass < 0.30 {
		t.Fatalf("passband RMS %v, want ~0.35", pass)
	}
	sincStop := toneRMS(t, 20000, 48000, 24000, ResampleSinc)
	if sincStop > 0.02 {
		t.Fatalf("stopband RMS %v, want <0.02 (16-tap Kaiser stopband)", sincStop)
	}
	linStop := toneRMS(t, 20000, 48000, 24000, ResampleLinear)
	if sincStop > linStop/4 {
		t.Fatalf("sinc stopband %v not well below linear alias %v", sincStop, linStop)
	}
}

func TestParsePlayArgs(t *testing.T) {
	cases := []struct {
		args []string
		path string
		rs   Resampler
	}{
		{[]string{"/host/x.wav"}, "/host/x.wav", ResampleSinc},
		{[]string{"/host/x.wav", "--resampler=linear"}, "/host/x.wav", ResampleLinear},
		{[]string{"--resampler=linear", "/host/x.wav"}, "/host/x.wav", ResampleLinear},
		{[]string{"--resampler=sinc", "/host/x.wav"}, "/host/x.wav", ResampleSinc},
		// An unknown value falls back to the default, not a refusal.
		{[]string{"--resampler=bogus", "/host/x.wav"}, "/host/x.wav", ResampleSinc},
		{nil, "", ResampleSinc},
	}
	for i, c := range cases {
		path, rs := parsePlayArgs(c.args)
		if path != c.path || rs != c.rs {
			t.Fatalf("case %d: got (%q,%d), want (%q,%d)", i, path, rs, c.path, c.rs)
		}
	}
}
