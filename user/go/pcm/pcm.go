// Package pcm is the shared PCM audio library — M186a (issue #3178):
// the decode/resample/output path GOSOUND and GOREC carried as package-main
// code, plus the v1-capture record contract both apps duplicated.
//
// Playback: ParseWav negotiates a RIFF/WAVE stream into a WavInfo (PCM,
// IEEE float, and the M162d IMA/MS ADPCM codecs), Pipe streams it
// bounded — one read block, one output period, one codec block, the
// resampler window — through the Resampler into the negotiated OutFmt and
// out to a Sink, the device-write seam the caller owns (GOSOUND hands it
// one mixer-seat Submit; a sync leg hands it whatever paces audio against
// video). Memory is constant in the file's size, and the output frame
// count is the exact rational OutFrames, not a measurement.
//
// Capture: the v1 tuple (S16 / 48 kHz / mono — the only offer slot 92
// accepts) fixes the canonical 44-byte RIFF/WAVE header WriteWavHeader
// emits, the seconds/path contract (ParseRecordSeconds, ValidRecordPath)
// and the meter's ChunkLevel — the pieces GOSOUND's record verb and GOREC
// once kept as two verbatim copies.
//
// The whole package is pure: nothing here names a syscall package, so the
// host corpus pins every byte and every frame the same way the guest
// runs them.
package pcm

// Source is the one read seam: fill buf, return (n, err); n<=0 && err==nil
// means EOF. The guest adapts vi.FileRead; the tests adapt a slice.
type Source func(buf []byte) (int, error)

func le16(b []byte) uint16 { return uint16(b[0]) | uint16(b[1])<<8 }

func le32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

func putLE16(b []byte, v uint16) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
}

func putLE32(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}

// itoa is the parser-local integer formatter, kept free of the vi import so
// this file stays pure (the GOVIEW precedent: the pure half never names a
// syscall package).
func itoa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

// hex4 renders a 16-bit tag for the refusal name (no fmt in the guest build).
func hex4(v uint16) string {
	const digs = "0123456789abcdef"
	return string([]byte{
		digs[v>>12&0xf], digs[v>>8&0xf], digs[v>>4&0xf], digs[v&0xf],
	})
}

func lastByte(s string, c byte) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == c {
			return i
		}
	}
	return -1
}

func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}
