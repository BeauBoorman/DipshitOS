// pipe.go — M99c (issue #2181) + M162d (issue #2980): the bounded
// WAV→device pipeline. One input block, one output period, the codec's
// single ADPCM block, and the resampler window are the whole memory
// footprint — a 1 MiB file and a 100 MiB file stream in identical space.
//
// The resampler is a 16-tap Kaiser windowed sinc by default (sinc.go);
// --resampler=linear keeps the M99c lerp. Both engines share the same
// position arithmetic, so the output count is identical under either.
//
// Resampling arithmetic is exact integer math: output frame i samples the
// input at position i*inRate/outRate (a frame index plus a fraction
// outRate-denominator). Because positions are rational, the output count is
// derived, not measured:
//
//	OutFrames(in, inR, outR) = ceil(in * outR / inR)
//
// — the count of i with floor(i*inR/outR) <= in-1, i.e. every output whose
// sampling position lands inside the input. The guest gate recomputes this
// in Python and asserts the stream's completed bytes equal it exactly.
package main

import "math"

// OutFrames is the resampler's output frame count for inFrames of input at
// inRate played at outRate: ceil(inFrames*outRate/inRate), computed without
// floating point. (in==0 → 0.)
func OutFrames(inFrames, inRate, outRate uint64) uint64 {
	if inFrames == 0 {
		return 0
	}
	return (inFrames*outRate + inRate - 1) / inRate
}

// decodeFrame reads one input frame (an interleaved channel pair at `bits`)
// into an f32 stereo pair in [-1, 1]. A mono frame duplicates into both
// channels. b must hold at least FrameBytes bytes.
func decodeFrame(w *WavInfo, b []byte) (l, r float32) {
	var c0, c1 float32
	switch {
	case w.Tag == FormatPCM && w.Bits == 8:
		// u8 PCM is unsigned, centred on 0x80.
		c0 = float32(int32(b[0])-0x80) / 128
		if w.Channels == 2 {
			c1 = float32(int32(b[1])-0x80) / 128
		}
	case w.Tag == FormatPCM && w.Bits == 16:
		c0 = float32(int16(le16(b[0:2]))) / 32768
		if w.Channels == 2 {
			c1 = float32(int16(le16(b[2:4]))) / 32768
		}
	case w.Tag == FormatPCM && w.Bits == 24:
		// Packed s24le: sign-extend the top byte into a 32-bit value.
		c0 = float32(int32(uint32(b[0])|uint32(b[1])<<8|uint32(b[2])<<16)<<8>>8) / 8388608
		if w.Channels == 2 {
			c1 = float32(int32(uint32(b[3])|uint32(b[4])<<8|uint32(b[5])<<16)<<8>>8) / 8388608
		}
	case w.Tag == FormatPCM && w.Bits == 32:
		c0 = float32(int32(le32(b[0:4]))) / 2147483648
		if w.Channels == 2 {
			c1 = float32(int32(le32(b[4:8]))) / 2147483648
		}
	case w.Tag == FormatFloat && w.Bits == 32:
		c0 = math.Float32frombits(le32(b[0:4]))
		if w.Channels == 2 {
			c1 = math.Float32frombits(le32(b[4:8]))
		}
	}
	if w.Channels == 1 {
		c1 = c0
	}
	return c0, c1
}

// The negotiated output tuple: a kernel FMT_* code, RATE_* code expanded to
// Hz, and a channel count. GOSOUND synthesizes in whatever the mixer
// negotiated — the mixer does not resample, so this is authoritative.
type OutFmt struct {
	Fmt      uint8  // kernel FMT_* code (5 s16, 17 s32, 19 f32)
	Code     uint8  // kernel RATE_* code, passed verbatim to the seat params
	Rate     uint32 // samples per second (Code decoded, for the resampler)
	Channels uint16 // 1 or 2
}

// FrameBytes is one encoded output frame.
func (o OutFmt) FrameBytes() int {
	b := 0
	switch o.Fmt {
	case fmtS16:
		b = 2
	case fmtS32, fmtFloat:
		b = 4
	}
	return b * int(o.Channels)
}

// Kernel FMT_* codes (kernel/src/virtio_snd.zig), mirrored from vi so this
// pure file stays syscall-free. vi.AudioFmt* carry the same values.
const (
	fmtS16   uint8 = 5
	fmtS32   uint8 = 17
	fmtFloat uint8 = 19
)

// put encodes one stereo f32 frame at the end of buf and returns the byte
// count. Mono output writes the mid channel. Callers only hand a full frame
// of room, so put never writes partial.
func (o OutFmt) put(buf []byte, l, r float32) int {
	if o.Channels == 1 {
		l = (l + r) / 2
	}
	switch o.Fmt {
	case fmtS16:
		putS16(buf, l)
		if o.Channels == 2 {
			putS16(buf[2:], r)
		}
	case fmtS32:
		putS32(buf, l)
		if o.Channels == 2 {
			putS32(buf[4:], r)
		}
	case fmtFloat:
		putF32(buf, l)
		if o.Channels == 2 {
			putF32(buf[4:], r)
		}
	}
	return o.FrameBytes()
}

func clip(v float32) float32 {
	if v > 1 {
		return 1
	}
	if v < -1 {
		return -1
	}
	return v
}

func putS16(b []byte, v float32) {
	s := int32(clip(v) * 32767)
	b[0] = byte(s)
	b[1] = byte(s >> 8)
}

func putS32(b []byte, v float32) {
	s := int32(clip(v) * 2147483647)
	b[0] = byte(s)
	b[1] = byte(s >> 8)
	b[2] = byte(s >> 16)
	b[3] = byte(s >> 24)
}

func putF32(b []byte, v float32) {
	u := math.Float32bits(v)
	b[0] = byte(u)
	b[1] = byte(u >> 8)
	b[2] = byte(u >> 16)
	b[3] = byte(u >> 24)
}

// Pipe is the bounded streaming pipeline: read a block, decode whole frames,
// resample into the output period, hand full periods to sink. Its buffers are
// allocated once at construction — Play allocates nothing per call.
//
// src supplies the file's bytes starting at the PCM data (the parser leaves
// its source positioned there). sink owns each completed output period; an
// error from it stops the pump and propagates (the guest's stop control uses
// it to unwind mid-stream).
type Pipe struct {
	info WavInfo
	out  OutFmt
	rs   Resampler

	// rbuf is the one read block. Input frames may straddle its edge, so the
	// undecodable tail (at most FrameBytes-1 bytes) is carried forward.
	// For ADPCM the read unit is one whole codec block instead: blk holds
	// it (blockAlign ≤ maxBlockAlign), pcm stages its decoded frames.
	rbuf  []byte
	carry int
	blk   []byte
	pcm   [][2]float32

	// period is the one output period buffer; olen tracks filled bytes and
	// is always a whole number of output frames.
	period []byte
	olen   int

	// Resampler state: num = next output index × inRate, so the sampling
	// position is num/outRate = pos + frac/outRate. prev/cur are the last
	// two decoded frames — the window linear interpolation needs. The sinc
	// engine instead keeps the last sincTaps decoded frames in a ring
	// (hist, Q30) plus its phase-quantized coefficient table (tab).
	num, frac uint64
	pos       uint64
	prev, cur [2]float32
	hist      [sincTaps][2]int32
	tab       [sincPhases * sincTaps]int32

	// in is input frames decoded so far; produced is output frames emitted.
	in       uint64
	produced uint64

	sink func(period []byte) error
}

// NewPipe builds the pipeline for one parsed header and one negotiated
// output tuple. rblk is the read-block size; period is the output staging
// size (vi.AudioPeriodBytes) — all buffers are allocated here and never
// again, sized by the codec's own bounds.
func NewPipe(info WavInfo, out OutFmt, rblk, period int, rs Resampler, sink func([]byte) error) *Pipe {
	p := &Pipe{
		info:   info,
		out:    out,
		rs:     rs,
		period: make([]byte, period),
		sink:   sink,
	}
	if info.Tag == FormatIMA || info.Tag == FormatMS {
		p.blk = make([]byte, info.BlockAlign)
		p.pcm = make([][2]float32, info.SamplesPerBlock)
	} else {
		p.rbuf = make([]byte, rblk)
	}
	if rs == ResampleSinc {
		p.buildSinc()
	}
	return p
}

// emit appends one output frame and flushes a full period.
func (p *Pipe) emit(l, r float32) error {
	p.olen += p.out.put(p.period[p.olen:], l, r)
	p.produced++
	if p.olen == len(p.period) {
		if err := p.sink(p.period); err != nil {
			return err
		}
		p.olen = 0
	}
	return nil
}

// advance steps the rational sampling position one output frame.
func (p *Pipe) advance() {
	p.num += uint64(p.info.Rate)
	p.pos = p.num / uint64(p.out.Rate)
	p.frac = p.num % uint64(p.out.Rate)
}

// feed decodes one input frame (absolute index in) and emits every output
// whose sampling window is now complete. Linear needs the (in-1, in) pair
// — positions with pos < in. Sinc needs the window's right edge covered —
// pos+sincHalf < in, i.e. pos <= in-sincHalf-1 — with its left edge padded
// by zeros at the head. pos cannot lag its window: the previous feed
// emitted every output that needed the earlier samples.
func (p *Pipe) feed(l, r float32) error {
	if p.rs == ResampleSinc {
		p.hist[p.in&(sincTaps-1)] = [2]int32{q30(l), q30(r)}
		p.in++
		for p.pos+sincHalf+1 <= p.in {
			el, er := p.sincOut()
			if err := p.emit(el, er); err != nil {
				return err
			}
			p.advance()
		}
		return nil
	}
	p.prev = p.cur
	p.cur = [2]float32{l, r}
	p.in++
	for p.pos < p.in-1 {
		t := float32(p.frac) / float32(p.out.Rate)
		if err := p.emit(p.prev[0]+(p.cur[0]-p.prev[0])*t,
			p.prev[1]+(p.cur[1]-p.prev[1])*t); err != nil {
			return err
		}
		p.advance()
	}
	return nil
}

// finish emits the tail: every output whose position landed on the LAST
// input frame (pos == in-1) samples it clamped — the lerp's missing second
// point is the frame itself; the sinc tail reads the same frames with
// zeros past the end. The count is the bound, not the position:
// produced == OutFrames exactly when every promised output has been emitted,
// which matters because a short rate step can keep pos parked on the last
// frame for several outputs. Runs after every input frame has been fed.
func (p *Pipe) finish() error {
	if p.in == 0 {
		return nil
	}
	last := p.in - 1
	target := p.ExpectedFrames()
	for p.produced < target {
		if p.pos > last {
			// Unreachable by the ceil construction; bail rather than emit
			// samples past the input if the arithmetic is ever wrong.
			break
		}
		var l, r float32
		if p.rs == ResampleSinc {
			l, r = p.sincOut()
		} else {
			l, r = p.cur[0], p.cur[1]
			if p.pos < last {
				t := float32(p.frac) / float32(p.out.Rate)
				l = p.prev[0] + (p.cur[0]-p.prev[0])*t
				r = p.prev[1] + (p.cur[1]-p.prev[1])*t
			}
		}
		if err := p.emit(l, r); err != nil {
			return err
		}
		p.advance()
	}
	return nil
}

// Play streams at most info.DataSize bytes of PCM from src through the
// pipeline: decode → resample → encode → period → sink. It reads in rbuf
// blocks and never holds more than one block plus the carry tail, so memory
// is constant in the file's size. At EOF it flushes the resampler tail and
// one partial period, then returns — the caller owns End/drain.
//
// A source that ends before DataSize is a `data truncated` refusal: the
// declared length, not the physical file, is what was promised to play.
func (p *Pipe) Play(src byteSource) error {
	if p.info.Tag == FormatIMA || p.info.Tag == FormatMS {
		return p.playADPCM(src)
	}
	want := p.info.DataSize
	fb := p.info.FrameBytes()
	for want > 0 {
		n := int64(len(p.rbuf)) - int64(p.carry)
		if uint64(n) > want {
			n = int64(want)
		}
		got, err := src(p.rbuf[p.carry : p.carry+int(n)])
		if err != nil {
			return err
		}
		if got <= 0 {
			return refuse("data truncated")
		}
		have := p.carry + got
		frames := have / fb
		for i := 0; i < frames; i++ {
			l, r := decodeFrame(&p.info, p.rbuf[i*fb:(i+1)*fb])
			if err := p.feed(l, r); err != nil {
				return err
			}
		}
		tail := have - frames*fb
		copy(p.rbuf[:tail], p.rbuf[frames*fb:have])
		p.carry = tail
		want -= uint64(got)
	}
	return p.flush()
}

// playADPCM is the ADPCM half of Play: the same source and sink contract,
// but the read unit is one whole codec block — the decoder needs the
// block header that carries its own predictor state, so frames cannot be
// picked off a byte stream the way PCM's can. Memory is still one block
// (p.blk) plus its decoded staging (p.pcm), both allocated at NewPipe.
func (p *Pipe) playADPCM(src byteSource) error {
	want := p.info.DataSize
	for want > 0 {
		n := int(p.info.BlockAlign)
		if uint64(n) > want {
			n = int(want)
		}
		got := 0
		for got < n {
			m, err := src(p.blk[got:n])
			if err != nil {
				return err
			}
			if m <= 0 {
				return refuse("data truncated")
			}
			got += m
		}
		want -= uint64(n)

		var frames int
		var err error
		if p.info.Tag == FormatIMA {
			frames = p.decodeIMA(p.blk[:n], p.pcm)
		} else {
			frames, err = p.decodeMS(p.blk[:n], p.pcm)
			if err != nil {
				return err
			}
		}
		for i := 0; i < frames; i++ {
			if err := p.feed(p.pcm[i][0], p.pcm[i][1]); err != nil {
				return err
			}
		}
	}
	return p.flush()
}

// flush is the shared Play tail: resampler drain plus the one partial
// period the output staging holds.
func (p *Pipe) flush() error {
	if err := p.finish(); err != nil {
		return err
	}
	if p.olen > 0 {
		if err := p.sink(p.period[:p.olen]); err != nil {
			return err
		}
		p.olen = 0
	}
	return nil
}

// ProducedFrames is the count of output frames emitted so far; Expected is
// the total a complete Play will emit (the gate's exact equality).
func (p *Pipe) ProducedFrames() uint64 { return p.produced }
func (p *Pipe) ExpectedFrames() uint64 {
	return OutFrames(p.info.Frames, uint64(p.info.Rate), uint64(p.out.Rate))
}
