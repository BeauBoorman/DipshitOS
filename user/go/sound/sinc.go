// sinc.go — M162d (issue #2980): the windowed-sinc resampler, the pipe's
// default engine. 16 taps under a Kaiser window, quantized to Q30
// fixed-point so the per-sample multiply-accumulate is pure integer math
// on the guest (no FPU assumptions beyond what the runtime already uses).
//
// The positions are the pipe's exact rationals: output i samples the input
// at x = pos + frac/outRate. The fractional part quantizes to one of
// sincPhases coefficient rows, built per pipe because the anti-alias
// cutoff depends on the rate ratio (ν = min(1, outRate/inRate) — a
// downsample has to filter to the new Nyquist, an upsample runs full
// band). Each row is normalized so DC gain is flat across phases.
package main

import "math"

const (
	// sincTaps is the FIR length; sincHalf the one-sided reach in input
	// frames. Emission waits until pos+sincHalf+1 frames exist.
	sincTaps, sincHalf = 16, 8
	// sincPhases is the fractional-position quantization.
	sincPhases = 64
	// sincBeta shapes the Kaiser window (~60 dB stopband at 16 taps).
	sincBeta = 6.0
)

// Resampler names the pipe's interpolation engine. Windowed-sinc is the
// default; --resampler=linear keeps the M99c lerp.
type Resampler uint8

const (
	ResampleSinc Resampler = iota
	ResampleLinear
)

// besselI0 is the series form of the zeroth-order modified Bessel
// function the Kaiser window needs — a dozen terms to convergence.
func besselI0(x float64) float64 {
	y := x * x / 4
	sum, term := 1.0, 1.0
	for k := 1; k < 30; k++ {
		term *= y / float64(k*k)
		sum += term
		if term < 1e-15*sum {
			break
		}
	}
	return sum
}

// buildSinc fills p.tab with sincPhases rows of sincTaps Q30 coefficients.
// Tap j of phase row φ covers input index pos-7+j, a distance of
// t = φ+7-j input samples from the sampling position; each tap's weight
// is the cutoff-scaled sinc under the Kaiser window, then the row is
// normalized to unit DC gain.
func (p *Pipe) buildSinc() {
	nu := float64(p.out.Rate) / float64(p.info.Rate)
	if nu > 1 {
		nu = 1
	}
	den := besselI0(sincBeta)
	var c [sincTaps]float64
	for ph := 0; ph < sincPhases; ph++ {
		phi := float64(ph) / sincPhases
		sum := 0.0
		for j := 0; j < sincTaps; j++ {
			t := phi + 7 - float64(j)
			var s float64 = 1
			if x := nu * t * math.Pi; x != 0 {
				s = math.Sin(x) / x
			}
			w := 0.0
			if d := t / sincHalf; d > -1 && d < 1 {
				w = besselI0(sincBeta*math.Sqrt(1-d*d)) / den
			}
			c[j] = nu * s * w
			sum += c[j]
		}
		for j := 0; j < sincTaps; j++ {
			p.tab[ph*sincTaps+j] = int32(c[j] / sum * (1 << 30))
		}
	}
}

// q30 converts a [-1,1] float to the Q30 domain the MAC runs in.
func q30(v float32) int32 {
	return int32(clip(v) * (1 << 30))
}

// sincOut evaluates the 16-tap dot product at the pipe's current
// (pos, frac) position. Input frames outside [0, in) read as zero — the
// head and tail padding that lets the output count stay exactly
// OutFrames at the stream edges.
func (p *Pipe) sincOut() (l, r float32) {
	ph := int(p.frac * sincPhases / uint64(p.out.Rate))
	row := p.tab[ph*sincTaps:]
	var accL, accR int64
	for j := 0; j < sincTaps; j++ {
		idx := int64(p.pos) - 7 + int64(j)
		if idx < 0 || idx >= int64(p.in) {
			continue
		}
		s := p.hist[idx&(sincTaps-1)]
		c := int64(row[j])
		accL += int64(s[0]) * c
		accR += int64(s[1]) * c
	}
	return float32(accL>>30) / (1 << 30),
		float32(accR>>30) / (1 << 30)
}
