// capture_test.go — the host corpus for the v1-capture record contract:
// the canonical header pin (the same header the live-sound-record gate
// recomputes off the share), the seconds bound, the path rules and the
// meter's level math. These are the M118d (#2482) gorec and M118e (#2483)
// sound pins merged — both apps drove the same writer through verbatim
// copies; M186a made the copies one package.
package pcm

import (
	"bytes"
	"strings"
	"testing"
)

func TestCaptureArithmetic(t *testing.T) {
	if CaptureBytes(2) != 192000 {
		t.Fatalf("CaptureBytes(2) = %d, want 192000", CaptureBytes(2))
	}
	if CaptureFrames(CaptureBytes(2)) != 96000 {
		t.Fatalf("CaptureFrames = %d, want 96000", CaptureFrames(CaptureBytes(2)))
	}
	if CaptureByteRate != 96000 || CaptureFrameBytes != 2 {
		t.Fatal("v1 tuple geometry drifted")
	}
}

// TestWavHeaderBytes is the byte-exact pin: the whole 44-byte header is
// determined by the v1 tuple plus the data length.
func TestWavHeaderBytes(t *testing.T) {
	var h [WavHeaderLen]byte
	WriteWavHeader(h[:], 192000)
	want := append([]byte("RIFF"),
		[]byte{0x24, 0xee, 0x02, 0x00}...) // 36 + 192000 = 192036
	want = append(want, []byte("WAVEfmt ")...)
	want = append(want,
		0x10, 0, 0, 0, // fmt size 16
		1, 0, // PCM
		1, 0, // mono
		0x80, 0xbb, 0, 0, // 48000
		0x00, 0x77, 0x01, 0, // 96000 byte rate
		2, 0, // block align
		16, 0, // bits
	)
	want = append(want, []byte("data")...)
	want = append(want, 0x00, 0xee, 0x02, 0) // 192000
	if len(want) != WavHeaderLen {
		t.Fatalf("golden is %d bytes, want %d", len(want), WavHeaderLen)
	}
	if !bytes.Equal(h[:], want) {
		t.Fatalf("header = %x, want %x", h[:], want)
	}
}

func TestParseRecordSeconds(t *testing.T) {
	for s, want := range map[string]int{"1": 1, "2": 2, "9": 9, "30": 30} {
		got, ok := ParseRecordSeconds(s)
		if !ok || got != want {
			t.Fatalf("ParseRecordSeconds(%q) = %d,%v want %d,true", s, got, ok, want)
		}
	}
	for _, s := range []string{"", "0", "31", "100", "-1", "x", "2s", "2.5",
		"abc", " 2", "9999"} {
		if v, ok := ParseRecordSeconds(s); ok {
			t.Fatalf("ParseRecordSeconds(%q) = %d,true want refuse", s, v)
		}
	}
}

func TestValidRecordPath(t *testing.T) {
	for _, p := range []string{
		"/host/GOREC/clip.wav", "/host/clip.wav", "/host/x.wav",
		"/disk/R.wav", "/disk/REC/A.WAV", "/host/A/B/C/d.wav",
	} {
		if why := ValidRecordPath(p); why != "" {
			t.Fatalf("ValidRecordPath(%q) refused: %s", p, why)
		}
	}
	for p, why := range map[string]string{
		"/tmp/x.wav":                       "outside /host or /disk",
		"/hostx/c.wav":                     "outside /host or /disk",
		"/host/../x.wav":                   "bad segment",
		"/host//x.wav":                     "bad segment",
		"/host/a//b.wav":                   "bad segment",
		"/host/":                           "bad segment",
		"/host/a\tb.wav":                   "control byte",
		"/host/" + strings.Repeat("a", 60): "over path cap",
		"/host/" + strings.Repeat("a", 60) + ".wav": "over path cap",
	} {
		if got := ValidRecordPath(p); got != why {
			t.Fatalf("ValidRecordPath(%q) = %q, want %q", p, got, why)
		}
	}
}

func TestChunkLevel(t *testing.T) {
	cases := []struct {
		name string
		b    []byte
		want int
	}{
		{"silence", make([]byte, 2048), 0},
		{"odd tail is not a frame", []byte{0xff}, 0},
		{"full scale", []byte{0xff, 0x7f}, 99},
		{"negative full scale", []byte{0x00, 0x80}, 100},
		{"half scale", []byte{0x00, 0x40}, 50},
	}
	for _, c := range cases {
		if got := ChunkLevel(c.b); got != c.want {
			t.Fatalf("%s: ChunkLevel = %d, want %d", c.name, got, c.want)
		}
	}
}
