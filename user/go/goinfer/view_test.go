package main

// view_test.go — the M122c (#2572) host half of GOINFER's windowed view:
// the mirrored console, the one-session-per-process bound, and the
// window-refused fallback are all pinned against the fake host.

import (
	"strings"
	"testing"

	"virelai/gpu3d"
	"virelai/tabapp"
)

func (v *inferView) hasLine(sub string) bool {
	for _, l := range v.lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// A bare launch on a window-less host names the journeys and exits
// nonzero — the honest headless answer, not a silent death. The dispatch
// pin proves the bare argv reaches the view path at all.
func TestViewFallbackWithoutWindow(t *testing.T) {
	var lines []string
	old := viewConsole
	viewConsole = func(s string) { lines = append(lines, s) }
	defer func() { viewConsole = old }()
	if rc := dispatch(nil); rc == 0 {
		t.Fatal("dispatch(nil) on a window-less host must not report success")
	}
	var refused, done bool
	for _, l := range lines {
		if strings.Contains(l, "window refused") {
			refused = true
		}
		if l == "goinfer: done" {
			done = true
		}
	}
	if !refused || !done {
		t.Fatalf("lines=%v, want window-refused then done", lines)
	}
}

// The Stub button drives the real journey and the window's log carries
// every console line the fake host received.
func TestViewStubMirrorsConsole(t *testing.T) {
	h := newFakeHost()
	v := newInferView(&tabapp.TabApp{W: viewW, H: viewH}, h)
	v.journey("stub")
	if !h.hasConsole("goinfer: stub consistent K=5") {
		t.Fatalf("console: %v", h.console)
	}
	if !v.hasLine("goinfer: stub consistent K=5") || !v.hasLine("goinfer OK") {
		t.Fatalf("view log lacks the journey's own lines: %v", v.lines)
	}
	if !v.h.opened {
		t.Fatal("the stub run took the session; opened must be set")
	}
}

// The one-session bound is shown on the window, not left to the kernel's
// refusal: a second journey press after a session-opening run says spent
// and runs nothing.
func TestViewSessionSpentIsNamed(t *testing.T) {
	h := newFakeHost()
	v := newInferView(&tabapp.TabApp{W: viewW, H: viewH}, h)
	v.journey("stub")
	if !v.hasLine("session spent") {
		t.Fatalf("spent note missing: %v", v.lines)
	}
	before := len(h.devs)
	v.journey("stub")
	if len(h.devs) != before {
		t.Fatal("a second journey opened another session")
	}
	if got := v.lines[len(v.lines)-1]; !strings.Contains(got, "session spent") {
		t.Fatalf("last log line %q, want the spent refusal", got)
	}
}

// A weights-absent model press never reaches OpenComp, so the session is
// NOT spent — a later stub press still runs.
func TestViewAbsentModelKeepsSession(t *testing.T) {
	h := newFakeHost()
	v := newInferView(&tabapp.TabApp{W: viewW, H: viewH}, h)
	v.journey("model")
	if v.h.opened {
		t.Fatal("absent weights must not consume the session")
	}
	if !v.hasLine("goinfer: weights absent") {
		t.Fatalf("view log lacks the absent line: %v", v.lines)
	}
	v.journey("stub")
	if !v.hasLine("goinfer: stub consistent K=5") {
		t.Fatalf("stub after absent-model did not run: %v", v.lines)
	}
}

// A device-less journey names itself unsupported in the window and the
// session stays unspent (the open was refused before a device existed).
func TestViewUnsupportedIsShown(t *testing.T) {
	h := newFakeHost()
	h.openErr = gpu3d.ErrComputeNoDevice
	v := newInferView(&tabapp.TabApp{W: viewW, H: viewH}, h)
	v.journey("stub")
	if !v.hasLine("goinfer: unsupported") {
		t.Fatalf("view log lacks unsupported: %v", v.lines)
	}
	if v.h.opened {
		t.Fatal("a refused open must not mark the session spent")
	}
}

// The log is bounded.
func TestViewLogBounded(t *testing.T) {
	v := newInferView(&tabapp.TabApp{W: viewW, H: viewH}, newFakeHost())
	for i := 0; i < viewLogMax*3; i++ {
		v.say("x")
	}
	if len(v.lines) != viewLogMax {
		t.Fatalf("log n=%d, want %d", len(v.lines), viewLogMax)
	}
}

// The whole bare-launch path, pinned: when the window opens the view
// reaches its event loop (PollEventRaw's ENOSYS exits it on the host) —
// `goinfer: view open id=` is the marker a seat leg can assert.
func TestViewRunsWhenWindowOpens(t *testing.T) {
	var lines []string
	oldCon, oldOpen := viewConsole, openViewWindow
	viewConsole = func(s string) { lines = append(lines, s) }
	openViewWindow = func(tabapp.Config) *tabapp.TabApp {
		return &tabapp.TabApp{Win: 9, W: viewW, H: viewH, OpenOK: true}
	}
	defer func() { viewConsole, openViewWindow = oldCon, oldOpen }()
	if rc := dispatch(nil); rc != 0 {
		t.Fatalf("dispatch(nil) with a window rc=%d, want 0", rc)
	}
	var opened, done bool
	for _, l := range lines {
		if l == "goinfer: view open id=9" {
			opened = true
		}
		if l == "goinfer: done" {
			done = true
		}
	}
	if !opened || !done {
		t.Fatalf("lines=%v, want view-open then done", lines)
	}
}
