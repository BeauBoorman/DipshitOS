// capture.go — M118d (#2482) / M118e (#2483) / M186a (#3178): the shared
// v1-capture record contract GOREC and GOSOUND's record verb once carried
// as two verbatim copies — the canonical PCM16/48kHz/mono RIFF/WAVE writer
// for the v1 capture tuple (the only tuple sys_audio_rec, slot 92,
// accepts), the shared seconds bound, the output-path rules and the
// meter's level math. Nothing here touches a syscall, so the host corpus
// pins every byte.
package pcm

import "strings"

const (
	// The v1 capture tuple — slot 92's only offer, so the writer never
	// negotiates: the file states what the kernel captures.
	CaptureRate     = 48000
	CaptureChannels = 1
	CaptureBits     = 16

	// Derived geometry: one frame and the byte rate a host recomputes
	// duration from (data chunk bytes / CaptureByteRate = seconds).
	CaptureFrameBytes = CaptureChannels * CaptureBits / 8 // 2
	CaptureByteRate   = CaptureRate * CaptureFrameBytes   // 96000

	// WavHeaderLen is the canonical RIFF/WAVE header size: 12 (RIFF/WAVE) +
	// 8+16 (fmt chunk) + 8 (data chunk header).
	WavHeaderLen = 44

	// MaxRecordSeconds bounds a recording: the WAV body is one in-memory
	// WriteFileSafe publish, so duration IS the memory bound — 30 s of the
	// v1 tuple is 2.88 MB, far inside the process map bound.
	MaxRecordSeconds = 30

	// MaxRecordPathLen leaves WriteFileSafe's one-byte "~" temp inside the
	// kernel's 64-byte file-table path cap (vi.go WriteFileSafe).
	MaxRecordPathLen = 63
)

// CaptureBytes returns the PCM payload size for whole seconds of the v1
// tuple — always frame-aligned, so the data chunk never carries a partial
// frame.
func CaptureBytes(seconds int) int { return seconds * CaptureByteRate }

// CaptureFrames is the whole-frame count of n captured bytes under the v1
// tuple.
func CaptureFrames(n int) int { return n / CaptureFrameBytes }

// WriteWavHeader fills h (exactly WavHeaderLen bytes) with the canonical
// PCM16/48kHz/mono RIFF/WAVE header declaring dataLen PCM bytes.
func WriteWavHeader(h []byte, dataLen int) {
	copy(h[0:4], "RIFF")
	putLE32(h[4:8], uint32(36+dataLen))
	copy(h[8:12], "WAVE")
	copy(h[12:16], "fmt ")
	putLE32(h[16:20], 16)
	putLE16(h[20:22], 1) // WAVE_FORMAT_PCM
	putLE16(h[22:24], uint16(CaptureChannels))
	putLE32(h[24:28], uint32(CaptureRate))
	putLE32(h[28:32], uint32(CaptureByteRate))
	putLE16(h[32:34], uint16(CaptureFrameBytes)) // block align
	putLE16(h[34:36], uint16(CaptureBits))
	copy(h[36:40], "data")
	putLE32(h[40:44], uint32(dataLen))
}

// ChunkLevel is the meter's reading for one captured chunk: the peak |s16|
// sample scaled to 0..100 against full-scale. Only whole frames count — a
// chunk is always frame-aligned by construction (the capture quantum is a
// period multiple), and a short tail is silence, not sound.
func ChunkLevel(b []byte) int {
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

// ParseRecordSeconds is the bounded atoi for the duration argument: decimal
// digits only, in 1..MaxRecordSeconds (the GOREC contract — no strconv, the
// fleet formats through vi.Itoa64).
func ParseRecordSeconds(s string) (int, bool) {
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
	if v < 1 || v > MaxRecordSeconds {
		return 0, false
	}
	return v, true
}

// ValidRecordPath enforces the shared record contract's roots: a file path
// under /host or /disk that WriteFileSafe can publish — short enough for
// the "~" temp, no dot/empty segments, no control bytes. Returns "" on
// accept, else the refusal reason the marker prints.
func ValidRecordPath(path string) string {
	root := strings.HasPrefix(path, "/host/") || strings.HasPrefix(path, "/disk/")
	if !root {
		return "outside /host or /disk"
	}
	if len(path) > MaxRecordPathLen {
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
