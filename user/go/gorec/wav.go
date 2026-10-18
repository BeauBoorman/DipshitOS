// wav.go — the M118d (#2482) RIFF/WAVE writer, the pure half of GOREC.ELF's
// output side and the mirror of user/go/sound's reader: nothing here touches
// a syscall, so the host suite drives it with slices and pins every byte.
//
// The shape is fixed by the v1 capture tuple (slot 92's only offer): PCM16 /
// 48 kHz / mono. A 44-byte canonical header — "RIFF" + size + "WAVE", one
// 16-byte "fmt " chunk, one "data" chunk — is the whole container; there are
// no optional chunks to get wrong and every field is a function of the v1
// constants plus the PCM length.
package main

const (
	// The v1 tuple — the ONLY geometry sys_audio_rec (slot 92) accepts, so
	// the writer never negotiates: the file states what the kernel captures.
	wavRate     = 48000
	wavChannels = 1
	wavBits     = 16

	// Derived geometry: one interleaved frame and the byte rate a host
	// recomputes duration from (data chunk bytes / byteRate = seconds).
	wavFrameBytes = wavChannels * wavBits / 8 // 2
	wavByteRate   = wavRate * wavFrameBytes   // 96000

	// wavHeaderLen is the canonical RIFF/WAVE header size: 12 (RIFF/WAVE) +
	// 8+16 (fmt chunk) + 8 (data chunk header).
	wavHeaderLen = 44
)

// pcmBytes returns the PCM payload size for whole seconds of the v1 tuple —
// always frame-aligned, so the data chunk never carries a partial frame.
func pcmBytes(seconds int) int { return seconds * wavByteRate }

// pcmFrames is the whole-frame count of n captured bytes under the v1 tuple.
func pcmFrames(n int) int { return n / wavFrameBytes }

// writeWavHeader fills h (exactly wavHeaderLen bytes) with the canonical
// PCM16/48kHz/mono RIFF/WAVE header declaring dataLen PCM bytes.
func writeWavHeader(h []byte, dataLen int) {
	copy(h[0:4], "RIFF")
	putLE32(h[4:8], uint32(36+dataLen))
	copy(h[8:12], "WAVE")
	copy(h[12:16], "fmt ")
	putLE32(h[16:20], 16)
	putLE16(h[20:22], 1) // WAVE_FORMAT_PCM
	putLE16(h[22:24], uint16(wavChannels))
	putLE32(h[24:28], uint32(wavRate))
	putLE32(h[28:32], uint32(wavByteRate))
	putLE16(h[32:34], uint16(wavFrameBytes)) // block align
	putLE16(h[34:36], uint16(wavBits))
	copy(h[36:40], "data")
	putLE32(h[40:44], uint32(dataLen))
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
