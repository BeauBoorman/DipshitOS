// gorec_test.go — the host half of M118d (#2482): the WAV writer, the arg
// contract and the record loop pinned against fake capture/write seams.
// The live-sound-record gate's asserts mirror these shapes on the share.
package main

import (
	"crypto/sha256"
	"strings"
	"testing"

	"virelai/pcm"
	"virelai/tabapp"
	"virelai/vi"
)

// fakeRig installs the seam vars with a capture that fills each request with
// a deterministic byte pattern (frame index mod 251 — nonzero, frame-aligned
// variation) and records every write/mkdir/console line.
type fakeRig struct {
	capInfo vi.AudioCapInfo
	capErr  error // first-error injection: every call fails with it
	failAt  int   // if >0, the capture call index (1-based) that fails
	writeRC int64 // WriteFileSafe's answer
	lines   []string
	writes  []fakeWrite
	mkdirs  []string
	calls   []int // the len of each capture request, in order
	fill    func(buf []byte, off int)
}
type fakeWrite struct {
	path string
	body []byte
}

func (f *fakeRig) install(t *testing.T) {
	t.Helper()
	oldQ, oldC, oldW, oldM, oldCon := capQuery, capture, writeFile, mkdir, console
	t.Cleanup(func() {
		capQuery, capture, writeFile, mkdir, console = oldQ, oldC, oldW, oldM, oldCon
	})
	if f.fill == nil {
		f.fill = func(buf []byte, off int) {
			for i := range buf {
				buf[i] = byte((off + i) % 251)
			}
		}
	}
	capQuery = func() (vi.AudioCapInfo, error) { return f.capInfo, nil }
	off := 0
	capture = func(format, rate, channels uint8, buf []byte) (int, error) {
		f.calls = append(f.calls, len(buf))
		if f.capErr != nil || (f.failAt > 0 && len(f.calls) == f.failAt) {
			err := f.capErr
			if err == nil {
				err = vi.ErrAudioCaptureTimeout
			}
			return 0, err
		}
		f.fill(buf, off)
		off += len(buf)
		return len(buf), nil
	}
	writeFile = func(path string, b []byte) int64 {
		f.writes = append(f.writes, fakeWrite{path: path, body: append([]byte(nil), b...)})
		return f.writeRC
	}
	mkdir = func(dir string) int64 { f.mkdirs = append(f.mkdirs, dir); return 0 }
	console = func(s string) { f.lines = append(f.lines, s) }
}

func (f *fakeRig) lastLine() string {
	if len(f.lines) == 0 {
		return ""
	}
	return f.lines[len(f.lines)-1]
}

func (f *fakeRig) hasLine(sub string) bool {
	for _, l := range f.lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

func readyInfo() vi.AudioCapInfo {
	return vi.AudioCapInfo{
		Ready: 1, Format: vi.AudioCapFormat, Rate: vi.AudioCapRate,
		Channels: vi.AudioCapChannels, PeriodBytes: vi.AudioCapPeriodBytes,
		RingBytes: vi.AudioCapRingBytes,
	}
}

// --- the record loop -------------------------------------------------------

// The happy path pins the whole evidence chain: the call-size ladder (the
// 64 KiB ring bound, then the tail), the file image (header + the exact
// captured bytes — no copy, no rewrite), and the sha256 the guest reports.
func TestRunRecordsTwoSeconds(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo()}
	f.install(t)
	rc := run([]string{"GOREC.ELF", "2", "/host/GOREC/clip.wav"})
	if rc != 0 {
		t.Fatalf("rc=%d lines=%v", rc, f.lines)
	}
	// 192000 = 65536 + 65536 + 60928: the ring bound then the tail.
	wantCalls := []int{65536, 65536, 60928}
	if len(f.calls) != len(wantCalls) {
		t.Fatalf("capture calls %v, want %v", f.calls, wantCalls)
	}
	for i := range wantCalls {
		if f.calls[i] != wantCalls[i] {
			t.Fatalf("capture calls %v, want %v", f.calls, wantCalls)
		}
	}
	if len(f.mkdirs) != 1 || f.mkdirs[0] != "/host/GOREC" {
		t.Fatalf("mkdirs=%v, want [/host/GOREC]", f.mkdirs)
	}
	if len(f.writes) != 1 || f.writes[0].path != "/host/GOREC/clip.wav" {
		t.Fatalf("writes=%v", f.writes)
	}
	body := f.writes[0].body
	if len(body) != pcm.WavHeaderLen+192000 {
		t.Fatalf("body is %d bytes, want %d", len(body), pcm.WavHeaderLen+192000)
	}
	// The file image IS header+PCM: the data chunk must be the bytes the
	// fake produced (index mod 251), proving the capture landed in place.
	for i := 0; i < 192000; i++ {
		if body[pcm.WavHeaderLen+i] != byte(i%251) {
			t.Fatalf("PCM byte %d = %02x, want %02x", i,
				body[pcm.WavHeaderLen+i], byte(i%251))
		}
	}
	var hdr [pcm.WavHeaderLen]byte
	pcm.WriteWavHeader(hdr[:], 192000)
	for i := range hdr {
		if body[i] != hdr[i] {
			t.Fatalf("header byte %d mismatch", i)
		}
	}
	sum := sha256.Sum256(body)
	if !f.hasLine("gorec: wrote /host/GOREC/clip.wav seconds=2 frames=96000 bytes=192000 sha256=" + hexLower(sum[:])) {
		t.Fatalf("no wrote receipt in %v", f.lines)
	}
	if !f.hasLine("gorec: cap ready=1 fmt=5 rate=7 ch=1 period=2048 ring=65536") {
		t.Fatalf("no cap line in %v", f.lines)
	}
	if f.lastLine() != "gorec: done" {
		t.Fatalf("last line = %q, want gorec: done", f.lastLine())
	}
}

// The two refused shapes the gate pins: the device-absent ENXIO and the
// mic-denied bounded drain. Both leave NO file and end on gorec: done.
func TestRunRefusalsWriteNothing(t *testing.T) {
	for name, err := range map[string]error{
		"ENXIO":     vi.ErrNoAudioDevice,
		"ETIMEDOUT": vi.ErrAudioCaptureTimeout,
		"ENOSPC":    vi.ErrAudioStreamFull,
	} {
		t.Run(name, func(t *testing.T) {
			f := &fakeRig{capInfo: readyInfo(), capErr: err}
			f.install(t)
			rc := run([]string{"GOREC.ELF", "2", "/host/GOREC/clip.wav"})
			if rc != 1 {
				t.Fatalf("rc=%d, want 1", rc)
			}
			if len(f.calls) != 1 {
				t.Fatalf("calls=%v — the first refusal must stop the loop", f.calls)
			}
			if len(f.writes) != 0 {
				t.Fatalf("a refused record wrote a file: %v", f.writes)
			}
			if !f.hasLine("gorec: refused " + name + " at=0 of=192000") {
				t.Fatalf("no refusal line in %v", f.lines)
			}
			if f.lastLine() != "gorec: done" {
				t.Fatalf("last line = %q", f.lastLine())
			}
		})
	}
}

// A refusal AFTER bytes landed still writes nothing — a partial record is a
// refused record, never a truncated WAV.
func TestRunMidRecordRefusal(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo(), failAt: 2}
	f.install(t)
	rc := run([]string{"GOREC.ELF", "2", "/host/GOREC/clip.wav"})
	if rc != 1 || len(f.writes) != 0 {
		t.Fatalf("rc=%d writes=%d — mid-record refusal must leave no file", rc, len(f.writes))
	}
	if !f.hasLine("gorec: refused ETIMEDOUT at=65536 of=192000") {
		t.Fatalf("no mid refusal line in %v", f.lines)
	}
}

// WriteFileSafe's negative rc is the named write refusal.
func TestRunWriteRefused(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo(), writeRC: -vi.ErrENOSPC}
	f.install(t)
	rc := run([]string{"GOREC.ELF", "1", "/disk/clip.wav"})
	if rc != 1 {
		t.Fatalf("rc=%d, want 1", rc)
	}
	if !f.hasLine("gorec: write refused rc=-5") {
		t.Fatalf("no write refusal in %v", f.lines)
	}
}

func TestRunUsageAndArgRefusals(t *testing.T) {
	cases := []struct {
		argv []string
		sub  string
	}{
		{[]string{"GOREC.ELF"}, "gorec: usage:"},
		{[]string{"GOREC.ELF", "2"}, "gorec: usage:"},
		{[]string{"GOREC.ELF", "2", "/host/x.wav", "extra"}, "gorec: usage:"},
		{[]string{"GOREC.ELF", "0", "/host/x.wav"}, "gorec: refused seconds=0"},
		{[]string{"GOREC.ELF", "31", "/host/x.wav"}, "gorec: refused seconds=31"},
		{[]string{"GOREC.ELF", "2", "/tmp/x.wav"}, "gorec: refused path outside"},
	}
	for _, tc := range cases {
		f := &fakeRig{capInfo: readyInfo()}
		f.install(t)
		rc := run(tc.argv)
		if rc != 2 {
			t.Fatalf("argv=%v rc=%d, want 2", tc.argv, rc)
		}
		if !f.hasLine(tc.sub) {
			t.Fatalf("argv=%v: no %q in %v", tc.argv, tc.sub, f.lines)
		}
		if len(f.calls) != 0 || len(f.writes) != 0 {
			t.Fatalf("argv=%v touched the seams", tc.argv)
		}
		if f.lastLine() != "gorec: done" {
			t.Fatalf("argv=%v last=%q", tc.argv, f.lastLine())
		}
	}
}

// The kernel's len-or-refusal contract: a short read with no error is a seam
// violation, never a file.
func TestRunShortRead(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo()}
	f.install(t)
	old := capture
	capture = func(format, rate, channels uint8, buf []byte) (int, error) {
		f.calls = append(f.calls, len(buf))
		f.fill(buf[:len(buf)-2], 0)
		return len(buf) - 2, nil
	}
	defer func() { capture = old }()
	rc := run([]string{"GOREC.ELF", "1", "/host/x.wav"})
	if rc != 1 || len(f.writes) != 0 {
		t.Fatalf("rc=%d writes=%d — a short read must fail, not file", rc, len(f.writes))
	}
	if !f.hasLine("gorec: short read got=") {
		t.Fatalf("no short-read line in %v", f.lines)
	}
}

// The /disk root passes the same validation — the mount choice is the
// caller's, not the app's.
func TestRunDiskPath(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo()}
	f.install(t)
	rc := run([]string{"GOREC.ELF", "1", "/disk/REC/clip.wav"})
	if rc != 0 {
		t.Fatalf("rc=%d lines=%v", rc, f.lines)
	}
	if len(f.writes) != 1 || f.writes[0].path != "/disk/REC/clip.wav" {
		t.Fatalf("writes=%v", f.writes)
	}
	if len(f.mkdirs) != 1 || f.mkdirs[0] != "/disk/REC" {
		t.Fatalf("mkdirs=%v, want [/disk/REC]", f.mkdirs)
	}
}

// --- the M122c windowed view ------------------------------------------------

// A bare launch on a window-less host refuses the window honestly: the
// headless usage line, status 2, and the one terminal marker — never a
// silent death. The dispatch pin proves the bare argv reaches the view
// path at all.
func TestViewFallbackWithoutWindow(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo()}
	f.install(t)
	if rc := dispatch([]string{"GOREC.ELF"}); rc != 2 {
		t.Fatalf("dispatch(bare) rc=%d, want 2", rc)
	}
	if !f.hasLine("gorec: window refused") {
		t.Fatalf("no refusal line in %v", f.lines)
	}
	if f.lastLine() != "gorec: done" {
		t.Fatalf("last=%q, want gorec: done", f.lastLine())
	}
}

// The view's record gesture drives the SAME pipeline the CLI form does:
// the fake seams see the identical call ladder and the log carries the
// identical gorec: lines the console got (the tee).
func TestViewRecordRunsTheSharedPipeline(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo()}
	f.install(t)
	v := newView(&tabapp.TabApp{W: viewW, H: viewH})
	v.record()
	if !f.hasLine("gorec: wrote " + viewPath + " seconds=" + vi.Itoa64(viewSeconds)) {
		t.Fatalf("no wrote line in %v", f.lines)
	}
	if len(f.writes) != 1 || f.writes[0].path != viewPath {
		t.Fatalf("writes=%v", f.writes)
	}
	// The in-window log mirrors the console: cap + wrote lines are in it.
	var inLog bool
	for _, l := range v.lines {
		if strings.Contains(l, "gorec: wrote "+viewPath) {
			inLog = true
		}
	}
	if !inLog {
		t.Fatalf("view log lacks the receipt: %v", v.lines)
	}
	if !strings.HasPrefix(v.capLine, "capture ready=1") {
		t.Fatalf("capLine=%q", v.capLine)
	}
	if v.busy {
		t.Fatal("busy flag stuck after the record")
	}
}

// A refused record is shown, not hidden: ENXIO lands in the log and no
// file is written.
func TestViewRecordRefusalIsShown(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo(), capErr: vi.ErrNoAudioDevice}
	f.install(t)
	v := newView(&tabapp.TabApp{W: viewW, H: viewH})
	v.record()
	if len(f.writes) != 0 {
		t.Fatalf("a refused record wrote: %v", f.writes)
	}
	var shown bool
	for _, l := range v.lines {
		if strings.Contains(l, "refused ENXIO") {
			shown = true
		}
	}
	if !shown {
		t.Fatalf("refusal not in view log: %v", v.lines)
	}
}

// The log is bounded — a long session cannot grow it.
func TestViewLogBounded(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo()}
	f.install(t)
	v := newView(&tabapp.TabApp{W: viewW, H: viewH})
	for i := 0; i < viewLogMax*3; i++ {
		v.say("x")
	}
	if len(v.lines) != viewLogMax {
		t.Fatalf("log n=%d, want %d", len(v.lines), viewLogMax)
	}
}

// The whole bare-launch path, pinned: when the window opens, the view
// reaches its event loop (PollEventRaw's ENOSYS exits it on the host) —
// `gorec: view open id=` is the marker a seat leg can assert.
func TestViewRunsWhenWindowOpens(t *testing.T) {
	f := &fakeRig{capInfo: readyInfo()}
	f.install(t)
	old := openViewWindow
	openViewWindow = func(tabapp.Config) *tabapp.TabApp {
		return &tabapp.TabApp{Win: 7, W: viewW, H: viewH, OpenOK: true}
	}
	defer func() { openViewWindow = old }()
	if rc := dispatch([]string{"GOREC.ELF"}); rc != 0 {
		t.Fatalf("dispatch(bare) with a window rc=%d, want 0", rc)
	}
	if !f.hasLine("gorec: view open id=7") {
		t.Fatalf("no open marker in %v", f.lines)
	}
	if f.lastLine() != "gorec: done" {
		t.Fatalf("last=%q, want gorec: done", f.lastLine())
	}
}
