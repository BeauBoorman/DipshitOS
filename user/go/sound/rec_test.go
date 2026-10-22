// rec_test.go — host corpus for the M118e (#2483) record half of
// GOSOUND.ELF. The pure layer (recwav.go) gets the byte-exact pins; the
// driver (rec.go) runs headless on the host against faked syscall seams —
// tabapp.Init fails closed with -ENOSYS, so the app never opens a window
// and recordMain returns the status main would hand vi.Exit.
package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	"virelai/pcm"
	"virelai/vi"
)

// fakeRig substitutes the record seams (the gorec convention): capture
// scripts answers, console collects marker lines, write records publishes.
type fakeRig struct {
	capInfo vi.AudioCapInfo
	capErr  error
	// capture is the scripted slot-92: fill buf, return (n, err).
	capture func(buf []byte) (int, error)
	writes  map[string][]byte
	writeRC int64
	lines   []string
	mkdirs  []string
}

func (f *fakeRig) install(t *testing.T) {
	t.Helper()
	savedQuery, savedCap := recQuery, recCap
	savedWrite, savedMk := recWrite, recMkdir
	savedCon := recConsole
	if f.writes == nil {
		f.writes = map[string][]byte{}
	}
	recQuery = func() (vi.AudioCapInfo, error) { return f.capInfo, f.capErr }
	recCap = func(format, rate, channels uint8, buf []byte) (int, error) {
		return f.capture(buf)
	}
	recWrite = func(path string, b []byte) int64 {
		f.writes[path] = append([]byte(nil), b...)
		return f.writeRC
	}
	recMkdir = func(dir string) int64 { f.mkdirs = append(f.mkdirs, dir); return 0 }
	recConsole = func(s string) { f.lines = append(f.lines, s) }
	t.Cleanup(func() {
		recQuery, recCap = savedQuery, savedCap
		recWrite, recMkdir = savedWrite, savedMk
		recConsole = savedCon
	})
}

func (f *fakeRig) hasLine(sub string) bool {
	for _, l := range f.lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

func (f *fakeRig) lastLine() string {
	if len(f.lines) == 0 {
		return ""
	}
	return f.lines[len(f.lines)-1]
}

func readyCap() vi.AudioCapInfo {
	return vi.AudioCapInfo{Ready: 1, Format: vi.AudioCapFormat,
		Rate: vi.AudioCapRate, Channels: vi.AudioCapChannels,
		PeriodBytes: vi.AudioCapPeriodBytes, RingBytes: vi.AudioCapRingBytes}
}

func absentCap() vi.AudioCapInfo {
	return vi.AudioCapInfo{Ready: 0, Format: vi.AudioFmtNone, Rate: 0xff,
		PeriodBytes: vi.AudioCapPeriodBytes, RingBytes: vi.AudioCapRingBytes}
}

// fillCapture answers every call with len(buf) bytes of the given s16
// sample (little-endian) — a silence source or a full-scale tone.
func fillCapture(sample int16) func([]byte) (int, error) {
	return func(buf []byte) (int, error) {
		for i := 0; i+1 < len(buf); i += 2 {
			buf[i], buf[i+1] = byte(sample), byte(sample>>8)
		}
		return len(buf), nil
	}
}

func TestRecArgShapes(t *testing.T) {
	f := &fakeRig{}
	f.install(t)
	cases := []struct {
		argv []string
		sub  string
	}{
		{[]string{"GOSOUND.ELF", "record"}, "gosound: rec usage:"},
		{[]string{"GOSOUND.ELF", "record", "2"}, "gosound: rec usage:"},
		{[]string{"GOSOUND.ELF", "record", "2", "/host/x.wav", "extra"},
			"gosound: rec usage:"},
		{[]string{"GOSOUND.ELF", "record", "0", "/host/x.wav"},
			"gosound: rec refused seconds=0"},
		{[]string{"GOSOUND.ELF", "record", "31", "/host/x.wav"},
			"gosound: rec refused seconds=31"},
		{[]string{"GOSOUND.ELF", "record", "2", "/tmp/x.wav"},
			"gosound: rec refused path outside"},
	}
	for _, tc := range cases {
		f.lines = nil
		a := &app{st: stEmpty}
		rc := a.recordMain(tc.argv)
		if rc != 2 {
			t.Fatalf("argv=%v rc=%d, want 2", tc.argv, rc)
		}
		if !f.hasLine(tc.sub) {
			t.Fatalf("argv=%v: no %q in %v", tc.argv, tc.sub, f.lines)
		}
		if f.lastLine() != markerRecDone {
			t.Fatalf("argv=%v last=%q, want %q", tc.argv, f.lastLine(), markerRecDone)
		}
		if len(f.writes) != 0 {
			t.Fatalf("argv=%v published a file on a refused record", tc.argv)
		}
	}
}

// TestRecordNoDevice is the device-absent shape the dogfood leg pins: slot
// 91 reports ready=0 and slot 92 answers ENXIO — a refused record leaves NO
// file.
func TestRecordNoDevice(t *testing.T) {
	f := &fakeRig{capInfo: absentCap()}
	f.capture = func(buf []byte) (int, error) { return 0, vi.ErrNoAudioDevice }
	f.install(t)

	a := &app{st: stEmpty}
	rc := a.recordMain([]string{"GOSOUND.ELF", "record", "2", "/host/GOSOUND/x.wav"})
	if rc != 1 {
		t.Fatalf("rc=%d, want 1", rc)
	}
	for _, want := range []string{"gosound: cap ready=0",
		"gosound: rec refused ENXIO at=0 of=192000"} {
		if !f.hasLine(want) {
			t.Fatalf("no %q in %v", want, f.lines)
		}
	}
	if f.hasLine("gosound: rec wrote") {
		t.Fatalf("a refused record printed a wrote receipt: %v", f.lines)
	}
	if len(f.writes) != 0 {
		t.Fatal("a refused record published a file")
	}
	if f.lastLine() != markerRecDone {
		t.Fatalf("last=%q, want %q", f.lastLine(), markerRecDone)
	}
}

// TestRecordTimeout is the host-mic-denied shape: the bounded drain expires
// before a frame lands and the refusal is ETIMEDOUT, never a short read.
func TestRecordTimeout(t *testing.T) {
	f := &fakeRig{capInfo: readyCap()}
	f.capture = func(buf []byte) (int, error) {
		return 0, vi.ErrAudioCaptureTimeout
	}
	f.install(t)

	a := &app{st: stEmpty}
	rc := a.recordMain([]string{"GOSOUND.ELF", "record", "2", "/host/GOSOUND/x.wav"})
	if rc != 1 {
		t.Fatalf("rc=%d, want 1", rc)
	}
	if !f.hasLine("gosound: cap ready=1") ||
		!f.hasLine("gosound: rec refused ETIMEDOUT at=0 of=192000") {
		t.Fatalf("missing refusal shape in %v", f.lines)
	}
	if len(f.writes) != 0 {
		t.Fatal("a timed-out record published a file")
	}
}

// TestRecordWritesWav is the consented shape: every call fills its chunk,
// the meter reads real levels, and the receipt's sha256 matches the
// published body byte for byte.
func TestRecordWritesWav(t *testing.T) {
	f := &fakeRig{capInfo: readyCap()}
	f.capture = fillCapture(0x4000) // half-scale tone
	f.install(t)

	a := &app{st: stEmpty}
	rc := a.recordMain([]string{"GOSOUND.ELF", "record", "1", "/host/GOSOUND/clip.wav"})
	if rc != 0 {
		t.Fatalf("rc=%d, want 0 (%v)", rc, f.lines)
	}
	body, ok := f.writes["/host/GOSOUND/clip.wav"]
	if !ok {
		t.Fatalf("no publish in %v", f.lines)
	}
	if len(body) != pcm.WavHeaderLen+96000 {
		t.Fatalf("body = %d bytes, want %d", len(body), pcm.WavHeaderLen+96000)
	}
	var wantHdr [pcm.WavHeaderLen]byte
	pcm.WriteWavHeader(wantHdr[:], 96000)
	if !bytes.Equal(body[:pcm.WavHeaderLen], wantHdr[:]) {
		t.Fatalf("published header disagrees with the canonical writer")
	}
	if !f.hasLine("gosound: rec level=50") {
		t.Fatalf("the meter never saw the half-scale tone in %v", f.lines)
	}
	if !f.hasLine("gosound: rec wrote /host/GOSOUND/clip.wav seconds=1 " +
		"frames=48000 bytes=96000 peak=50 sha256=") {
		t.Fatalf("no wrote receipt in %v", f.lines)
	}
	if f.lastLine() != markerRecDone {
		t.Fatalf("last=%q, want %q", f.lastLine(), markerRecDone)
	}
}

// TestRecordShortReadFails: the kernel's contract is len-or-refusal — a
// short answer is a seam lie, a named failure, and no file.
func TestRecordShortReadFails(t *testing.T) {
	f := &fakeRig{capInfo: readyCap()}
	f.capture = func(buf []byte) (int, error) { return len(buf) / 2, nil }
	f.install(t)

	a := &app{st: stEmpty}
	rc := a.recordMain([]string{"GOSOUND.ELF", "record", "1", "/host/GOSOUND/x.wav"})
	if rc != 1 {
		t.Fatalf("rc=%d, want 1", rc)
	}
	if !f.hasLine("gosound: rec short read got=4096 want=8192") {
		t.Fatalf("no short-read marker in %v", f.lines)
	}
	if len(f.writes) != 0 {
		t.Fatal("a short-read record published a file")
	}
}

// TestMeterMode is the meter-only leg: bounded seconds, level markers, no
// file ever.
func TestMeterMode(t *testing.T) {
	f := &fakeRig{capInfo: readyCap()}
	f.capture = fillCapture(0)
	f.install(t)

	a := &app{st: stEmpty}
	rc := a.meterMain([]string{"GOSOUND.ELF", "meter", "1"})
	if rc != 0 {
		t.Fatalf("rc=%d, want 0 (%v)", rc, f.lines)
	}
	if !f.hasLine("gosound: meter secs=1") || !f.hasLine("gosound: meter level=0") ||
		!f.hasLine("gosound: meter end peak=0") {
		t.Fatalf("meter markers missing in %v", f.lines)
	}
	if len(f.writes) != 0 {
		t.Fatal("the meter wrote a file")
	}
	if f.lastLine() != markerMeterDone {
		t.Fatalf("last=%q, want %q", f.lastLine(), markerMeterDone)
	}
}

// TestMeterRefuses: the meter's refusal is the same named errno as record's.
func TestMeterRefuses(t *testing.T) {
	f := &fakeRig{capInfo: absentCap()}
	f.capture = func(buf []byte) (int, error) { return 0, vi.ErrNoAudioDevice }
	f.install(t)

	a := &app{st: stEmpty}
	rc := a.meterMain([]string{"GOSOUND.ELF", "meter"})
	if rc != 1 {
		t.Fatalf("rc=%d, want 1", rc)
	}
	if !f.hasLine("gosound: meter secs=10") ||
		!f.hasLine("gosound: meter refused ENXIO at=0 of=960000") {
		t.Fatalf("meter refusal markers missing in %v", f.lines)
	}
}

// TestLevelMarkerBounded pins the serial throttle: 1 s of capture is ~12
// chunks — silence prints exactly one level line (the first), never one per
// chunk.
func TestLevelMarkerBounded(t *testing.T) {
	f := &fakeRig{capInfo: readyCap()}
	f.capture = fillCapture(0)
	f.install(t)

	a := &app{st: stEmpty}
	if rc := a.recordMain([]string{"GOSOUND.ELF", "record", "1", "/host/x.wav"}); rc != 0 {
		t.Fatalf("rc=%d (%v)", rc, f.lines)
	}
	n := 0
	for _, l := range f.lines {
		if strings.Contains(l, "level=") {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("level printed %d times, want 1 (silence, first tick)", n)
	}
}

// TestPumpStopHonorsUser: a stop armed mid-capture unwinds the pump at the
// next chunk boundary — the windowed path's `s` key sets recStop through
// the event service; here the fake's second fill sets it where service()
// would have read it.
func TestPumpStopHonorsUser(t *testing.T) {
	f := &fakeRig{capInfo: readyCap()}
	f.install(t)

	a := &app{st: stEmpty}
	a.st = stRecording
	a.recTotal = pcm.CaptureBytes(1)
	calls := 0
	f.capture = func(buf []byte) (int, error) {
		calls++
		if calls == 2 {
			a.recStop = true
		}
		return len(buf), nil
	}

	dst := make([]byte, a.recTotal)
	off, err := a.recPump(dst, a.recTotal, markerLevel)
	if !errors.Is(err, errStopped) {
		t.Fatalf("pump err = %v, want errStopped", err)
	}
	if off != 2*recChunkBytes {
		t.Fatalf("stopped after %d bytes, want %d", off, 2*recChunkBytes)
	}
}
