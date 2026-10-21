// M152d (issue #2918): the win chime — GOMINE's own copy of the shape
// GOSOL carries, deliberately not shared (the card names a common audio
// package as out of scope this wave). At most 0.5 s of synthesized PCM
// played with vi.AudioPlay; absent or muted audio prints a
// `gomine: chime` marker and stays silent — no dialog, no retry.
//
// The sound: a short two-note rise (C5 then G5, a fifth apart — a mine
// cleared, not a fanfare) under an exponential decay, deterministic so
// the class-A suite pins byte bounds and content rather than a coin
// flip.
package main

import (
	"unsafe"

	"virelai/vi"
)

const (
	chimeMS  = 280   // under the 0.5 s card bound at every rate
	chimeF0  = 523.0 // C5
	chimeF1  = 784.0 // G5 — the rise
	chimeW1  = 0.6   // the upper note's weight against the root
	chimeAmp = 0.5   // peak after normalization
	chimeTau = 4.5   // decay constant: env = e^(-Tau·u)
)

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

// synthChime builds the win chime for the negotiated tuple; nil when
// the tuple cannot be encoded — the caller reports the path silent
// rather than submitting zeros.
func synthChime(info vi.AudioInfo) []byte {
	fb, ok := chimeFrameBytes(info.Format, info.Channels)
	hz := chimeRateHz(info.Rate)
	if !ok || hz == 0 {
		return nil
	}
	frames := int(uint64(hz) * chimeMS / 1000)
	if frames == 0 {
		return nil
	}
	pcm := make([]byte, frames*fb)
	sb := fb / int(info.Channels)
	attack := int(hz) / 500 // ~2 ms ramp-in
	if attack < 1 {
		attack = 1
	}
	norm := 1.0 + chimeW1
	for i := 0; i < frames; i++ {
		t := float64(i) / float64(hz)
		env := chimeDecay(chimeTau * float64(i) / float64(frames))
		if i < attack {
			env *= float64(i+1) / float64(attack)
		}
		s := chimeAmp * env *
			(chimeSin(twoPiC*chimeF0*t) + chimeW1*chimeSin(twoPiC*chimeF1*t)) / norm
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

// playWinChime runs the card's decision order at the win: the muted
// settings row (a policy fact, not a device one), the one AudioQuery
// probe, the synth, the bounded play — every branch ending in a
// `gomine: chime` marker, never a dialog.
func playWinChime() {
	if audioMuted() {
		vi.ConsoleLine("gomine: chime silent muted")
		return
	}
	info, err := vi.AudioQuery()
	if err != nil || info.Ready == 0 || info.Format == vi.AudioFmtNone {
		vi.ConsoleLine("gomine: chime silent no-device")
		return
	}
	pcm := synthChime(info)
	if len(pcm) == 0 {
		vi.ConsoleLine("gomine: chime silent no-device")
		return
	}
	played, err := vi.AudioPlay(pcm)
	if err != nil || played != len(pcm) {
		vi.ConsoleLine("gomine: chime silent refused")
		return
	}
	vi.ConsoleLine("gomine: chime played bytes=" + vi.Itoa64(int64(played)))
}

// audioMuted reports the guest's spelling of "muted": the persisted
// audio_volume row reads 0 (the seat applies that row to slot 44). A
// missing or unreadable row is not a mute.
func audioMuted() bool {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return false
	}
	v, ok := settingsVolume(b)
	return ok && v == 0
}

// settingsVolume finds the `audio_volume=N` row in a settings blob;
// ok=false when none parses — the seam the muted check and the class-A
// test share.
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
// degree-15 odd Taylor series in Horner form.
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
// multiply and the fraction a Horner polynomial; past 16 it is silence.
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
