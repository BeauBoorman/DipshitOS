// M152d (issue #2918): the win chime. At most 0.5 s of PCM, synthesized
// in-app (no sample asset — this file's own sine/decay arithmetic), then
// played with vi.AudioPlay in the negotiated tuple. The card's honesty
// rule: with audio absent (AudioQuery not ready, a tuple the synth
// cannot encode, or a refused play) or muted (the persisted
// audio_volume row reads 0), the app prints a `gosol: chime` marker and
// stays silent — never an error dialog, never a retried play.
//
// The shape: three stacked partials (E5, B5, E6 — a fifth and its
// octave) under an exponential decay and a short attack ramp, the same
// family gotabwm's notify chime uses but owned here — the card names a
// shared audio package as out of scope for this wave. Deterministic by
// construction (no math, no clock), so the class-A suite pins the byte
// bound and the content, not a coin flip.
package main

import (
	"unsafe"

	"virelai/vi"
)

const (
	// chimeMS is the target length — comfortably under the card's 0.5 s
	// bound at every negotiated rate (the class-A test pins it).
	chimeMS  = 320
	chimeF0  = 660.0  // E5, the fundamental
	chimeF1  = 990.0  // B5, the fifth
	chimeF2  = 1320.0 // E6, the octave above the fifth
	chimeW1  = 0.5    // the fifth's weight against the fundamental
	chimeW2  = 0.25   // the octave's weight
	chimeAmp = 0.5    // peak after normalization
	chimeTau = 4.0    // decay constant: env = e^(-Tau·u) over the chime
)

// chimeRateHz decodes the kernel's RATE_* ladder; 0 is the un-decodable
// code — no synth, no play (the same table fart and the seat carry).
func chimeRateHz(rate uint8) uint32 {
	switch rate {
	case 1:
		return 8000
	case 3:
		return 16000
	case 4:
		return 22050
	case 5:
		return 32000
	case 6:
		return 44100
	case 7:
		return 48000
	}
	return 0
}

// chimeFrameBytes is the on-wire frame size for the negotiated tuple;
// ok=false is a format the chime cannot encode.
func chimeFrameBytes(format, channels uint8) (int, bool) {
	if channels == 0 {
		return 0, false
	}
	switch format {
	case vi.AudioFmtFloat, vi.AudioFmtS32:
		return 4 * int(channels), true
	case vi.AudioFmtS16:
		return 2 * int(channels), true
	}
	return 0, false
}

// chimeFrames is the frame count for the target length at hz — the
// figure the 0.5 s bound is checked against.
func chimeFrames(hz uint32) int {
	return int(uint64(hz) * chimeMS / 1000)
}

// synthChime builds the chime PCM for the negotiated tuple. A rate off
// the ladder or a format it cannot encode returns nil — the caller
// reports the path silent rather than submitting zeros.
func synthChime(info vi.AudioInfo) []byte {
	fb, ok := chimeFrameBytes(info.Format, info.Channels)
	hz := chimeRateHz(info.Rate)
	if !ok || hz == 0 {
		return nil
	}
	frames := chimeFrames(hz)
	if frames == 0 {
		return nil
	}
	pcm := make([]byte, frames*fb)
	sb := fb / int(info.Channels)
	attack := int(hz) / 500 // ~2 ms ramp-in; a leading click is worse
	if attack < 1 {
		attack = 1
	}
	norm := 1.0 + chimeW1 + chimeW2
	for i := 0; i < frames; i++ {
		t := float64(i) / float64(hz)
		env := chimeDecay(chimeTau * float64(i) / float64(frames))
		if i < attack {
			env *= float64(i+1) / float64(attack)
		}
		s := chimeAmp * env *
			(chimeSin(twoPiC*chimeF0*t) +
				chimeW1*chimeSin(twoPiC*chimeF1*t) +
				chimeW2*chimeSin(twoPiC*chimeF2*t)) / norm
		if s > 1 {
			s = 1
		} else if s < -1 {
			s = -1
		}
		for c := 0; c < int(info.Channels); c++ {
			at := i*fb + c*sb
			switch info.Format {
			case vi.AudioFmtFloat:
				putF32C(pcm[at:], float32(s))
			case vi.AudioFmtS16:
				putI16C(pcm[at:], int16(s*32767))
			case vi.AudioFmtS32:
				putI32C(pcm[at:], int32(s*2147483647))
			}
		}
	}
	return pcm
}

// playWinChime is the whole win-path audio decision, in the order the
// card wants honesty: the muted settings row first (a policy fact, not a
// device one), then the one AudioQuery that drives the kernel's
// negotiation, then the synth, then the bounded play. Every branch ends
// in a `gosol: chime` marker; none blocks beyond the play's own drain
// and none raises a dialog.
func playWinChime() {
	if audioMuted() {
		vi.ConsoleLine("gosol: chime silent muted")
		return
	}
	info, err := vi.AudioQuery()
	if err != nil || info.Ready == 0 || info.Format == vi.AudioFmtNone {
		vi.ConsoleLine("gosol: chime silent no-device")
		return
	}
	pcm := synthChime(info)
	if len(pcm) == 0 {
		vi.ConsoleLine("gosol: chime silent no-device")
		return
	}
	played, err := vi.AudioPlay(pcm)
	if err != nil || played != len(pcm) {
		vi.ConsoleLine("gosol: chime silent refused")
		return
	}
	vi.ConsoleLine("gosol: chime played bytes=" + itoa(played))
}

// audioMuted reads the persisted audio_volume row out of SETTINGS.TXT
// and reports true only when it parses as 0 — the seat applies the same
// row to slot 44, so 0 there is the guest's spelling of "muted". A
// missing or junk row is not a mute; an unreadable file is not either.
func audioMuted() bool {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return false
	}
	v, ok := settingsVolume(b)
	return ok && v == 0
}

// settingsVolume finds the `audio_volume=N` row in a settings blob and
// parses N; ok=false when no row parses — the seam the muted check and
// the class-A test share.
func settingsVolume(b []byte) (int, bool) {
	key := "audio_volume="
	for i := 0; i+len(key) <= len(b); i++ {
		if i > 0 && b[i-1] != '\n' && b[i-1] != '\r' && b[i-1] != ' ' {
			continue
		}
		match := true
		for j := range key {
			if b[i+j] != key[j] {
				match = false
				break
			}
		}
		if !match {
			continue
		}
		v, n := 0, 0
		for k := i + len(key); k < len(b) && b[k] >= '0' && b[k] <= '9'; k++ {
			v = v*10 + int(b[k]-'0')
			n++
		}
		if n > 0 {
			return v, true
		}
	}
	return 0, false
}

// --- the arithmetic (no math import; byte-stable across toolchains) ----

const (
	piC    = 3.14159265358979323846264338327950288
	twoPiC = 6.28318530717958647692528676655900577
)

// chimeSin is sin over the reals: range-reduce to [-pi, pi], then the
// degree-15 odd Taylor series in Horner form (same construction fart's
// synth and the seat's chime already carry).
func chimeSin(x float64) float64 {
	n := int64(x / twoPiC)
	x -= float64(n) * twoPiC
	if x > piC {
		x -= twoPiC
	} else if x < -piC {
		x += twoPiC
	}
	z := x * x
	p := -1.0 / 1307674368000.0
	p = 1.0/6227020800.0 + z*p
	p = -1.0/39916800.0 + z*p
	p = 1.0/362880.0 + z*p
	p = -1.0/5040.0 + z*p
	p = 1.0/120.0 + z*p
	p = -1.0/6.0 + z*p
	p = 1.0 + z*p
	return x * p
}

// chimeDecay is e^-x on [0,16]: e^-n · e^-f, the integer part a repeated
// multiply and the fraction a Horner polynomial (~1e-5 error); past 16
// the envelope is silence anyway.
func chimeDecay(x float64) float64 {
	if x <= 0 {
		return 1
	}
	if x >= 16 {
		return 0
	}
	n := int(x)
	f := x - float64(n)
	v := 1.0
	for i := 0; i < n; i++ {
		v *= 0.36787944117144232159552377016146087 // e^-1
	}
	p := -1.0 / 5040.0
	p = 1.0/720.0 + f*p
	p = -1.0/120.0 + f*p
	p = 1.0/24.0 + f*p
	p = -1.0/6.0 + f*p
	p = 1.0/2.0 + f*p
	p = -1.0 + f*p
	p = 1.0 + f*p
	return v * p
}

func putF32C(b []byte, v float32) {
	u := *(*uint32)(unsafe.Pointer(&v))
	b[0], b[1], b[2], b[3] = byte(u), byte(u>>8), byte(u>>16), byte(u>>24)
}

func putI16C(b []byte, v int16) {
	b[0], b[1] = byte(v), byte(uint16(v)>>8)
}

func putI32C(b []byte, v int32) {
	u := uint32(v)
	b[0], b[1], b[2], b[3] = byte(u), byte(u>>8), byte(u>>16), byte(u>>24)
}
