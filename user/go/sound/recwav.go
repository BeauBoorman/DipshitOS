// recwav.go — M118e (issue #2483): the pure file layer of GOSOUND's record
// half — the canonical PCM16/48kHz/mono RIFF/WAVE writer for the v1 capture
// tuple (the only tuple sys_audio_rec, slot 92, accepts), the shared seconds
// bound, the output-path rules and the meter's level math. It is the mirror
// of GOREC's wav.go: nothing here touches a syscall, so the host corpus pins
// every byte.
package main

import "strings"

const (
	// The v1 capture tuple — slot 92's only offer, so the writer never
	// negotiates: the file states what the kernel captures.
	wavRecRate     = 48000
	wavRecChannels = 1
	wavRecBits     = 16

	// Derived geometry: one frame and the byte rate a host recomputes
	// duration from (data chunk bytes / wavRecByteRate = seconds).
	wavRecFrameBytes = wavRecChannels * wavRecBits / 8 // 2
	wavRecByteRate   = wavRecRate * wavRecFrameBytes   // 96000

	// wavHeaderLen is the canonical RIFF/WAVE header size: 12 (RIFF/WAVE) +
	// 8+16 (fmt chunk) + 8 (data chunk header).
	wavHeaderLen = 44

	// maxRecordSeconds bounds a recording: the WAV body is one in-memory
	// WriteFileSafe publish, so duration IS the memory bound — 30 s of the
	// v1 tuple is 2.88 MB, far inside the process map bound.
	maxRecordSeconds = 30

	// meterDefaultSeconds is the meter mode's run with no argument — the
	// mode is bounded by construction whether or not a window exists.
	meterDefaultSeconds = 10

	// maxRecPathLen leaves WriteFileSafe's one-byte "~" temp inside the
	// kernel's 64-byte file-table path cap (vi.go WriteFileSafe).
	maxRecPathLen = 63
)

// recPcmBytes returns the PCM payload size for whole seconds of the v1
// tuple — always frame-aligned, so the data chunk never carries a partial
// frame.
func recPcmBytes(seconds int) int { return seconds * wavRecByteRate }

// recPcmFrames is the whole-frame count of n captured bytes under the v1
// tuple.
func recPcmFrames(n int) int { return n / wavRecFrameBytes }

// writeWavHeader fills h (exactly wavHeaderLen bytes) with the canonical
// PCM16/48kHz/mono RIFF/WAVE header declaring dataLen PCM bytes.
func writeWavHeader(h []byte, dataLen int) {
	copy(h[0:4], "RIFF")
	putLE32(h[4:8], uint32(36+dataLen))
	copy(h[8:12], "WAVE")
	copy(h[12:16], "fmt ")
	putLE32(h[16:20], 16)
	putLE16(h[20:22], 1) // WAVE_FORMAT_PCM
	putLE16(h[22:24], uint16(wavRecChannels))
	putLE32(h[24:28], uint32(wavRecRate))
	putLE32(h[28:32], uint32(wavRecByteRate))
	putLE16(h[32:34], uint16(wavRecFrameBytes)) // block align
	putLE16(h[34:36], uint16(wavRecBits))
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

// chunkLevel is the meter's reading for one captured chunk: the peak |s16|
// sample scaled to 0..100 against full-scale. Only whole frames count — a
// chunk is always frame-aligned by construction (recChunkBytes is a period
// multiple), and a short tail is silence, not sound.
func chunkLevel(b []byte) int {
	peak := 0
	for i := 0; i+1 < len(b); i += 2 {
		v := int(int16(uint16(b[i]) | uint16(b[i+1])<<8))
		if v < 0 {
			v = -v
		}
		if v > peak {
			peak = v
		}
	}
	return peak * 100 / 32768
}

// parseRecSeconds is the bounded atoi for the duration argument: decimal
// digits only, in 1..maxRecordSeconds (the GOREC contract — no strconv, the
// fleet formats through vi.Itoa64).
func parseRecSeconds(s string) (int, bool) {
	if s == "" || len(s) > 3 {
		return 0, false
	}
	v := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
	}
	if v < 1 || v > maxRecordSeconds {
		return 0, false
	}
	return v, true
}

// validRecPath enforces the shared record contract's roots: a file path
// under /host or /disk that WriteFileSafe can publish — short enough for
// the "~" temp, no dot/empty segments, no control bytes. Returns "" on
// accept, else the refusal reason the marker prints.
func validRecPath(path string) string {
	root := strings.HasPrefix(path, "/host/") || strings.HasPrefix(path, "/disk/")
	if !root {
		return "outside /host or /disk"
	}
	if len(path) > maxRecPathLen {
		return "over path cap"
	}
	segs := strings.Split(path, "/")
	for _, seg := range segs[2:] { // ["", "host"|"disk", ...]
		if seg == "" || seg == "." || seg == ".." {
			return "bad segment"
		}
	}
	for i := 0; i < len(path); i++ {
		if path[i] < 0x20 || path[i] == 0x7f {
			return "control byte"
		}
	}
	return ""
}
