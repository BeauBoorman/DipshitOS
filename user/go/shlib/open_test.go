package shlib

import (
	"strings"
	"testing"
)

type openLaunch struct {
	name string
	args []string
}

type openHost struct {
	*fakeHost
	launches   []openLaunch
	waitStatus int64
}

func (h *openHost) RunExternal(name string, args []string) (int64, error) {
	h.launches = append(h.launches, openLaunch{name: name, args: append([]string(nil), args...)})
	if h.missing[name] {
		return 0, ErrNotFound
	}
	return 41, nil
}

func (h *openHost) WaitExternal(pid int64) (int64, error) {
	if pid != 41 {
		return 0, ErrNotFound
	}
	return h.waitStatus, nil
}

func newOpenHost() *openHost {
	return &openHost{fakeHost: newFakeHost()}
}

func runOpenLine(t *testing.T, h *openHost, line string) (int, *Shell) {
	t.Helper()
	sh := NewShell(h, &History{})
	status, action := sh.RunLine(line)
	if action != ActionContinue {
		t.Fatalf("%q returned action %v, want continue", line, action)
	}
	return status, sh
}

func TestOpenBuiltinUsesSharedFileDispatch(t *testing.T) {
	h := newOpenHost()
	h.files["/host/docs/README.TXT"] = []byte("hello from the share\n")
	sh := NewShell(h, &History{})
	status, action := sh.RunLine("cd /host/docs")
	if status != 0 {
		t.Fatalf("cd status = %d", status)
	}
	if action != ActionContinue {
		t.Fatalf("cd returned action %v, want continue", action)
	}
	status, action = sh.RunLine("open README.TXT")
	if action != ActionContinue {
		t.Fatalf("open returned action %v, want continue", action)
	}
	if status != 0 {
		t.Fatalf("open status = %d, output=%q", status, h.outString())
	}
	if len(h.launches) != 1 || h.launches[0].name != "GOEDIT.ELF" ||
		len(h.launches[0].args) != 1 || h.launches[0].args[0] != "/host/docs/README.TXT" {
		t.Fatalf("launches = %+v; want GOEDIT.ELF /host/docs/README.TXT", h.launches)
	}
	if len(h.markers) != 1 || h.markers[0] !=
		"gosh: open launched scheme=file target=/host/docs/README.TXT handler=GOEDIT.ELF pid=41" {
		t.Fatalf("markers = %v", h.markers)
	}
}

func TestOpenBuiltinRoutesFileURLThroughMIME(t *testing.T) {
	h := newOpenHost()
	h.files["/host/README.TXT"] = []byte("hello from the share\n")
	status, _ := runOpenLine(t, h, "open file://localhost/host/README.TXT")
	if status != 0 {
		t.Fatalf("open status = %d, output=%q", status, h.outString())
	}
	if len(h.launches) != 1 || h.launches[0].name != "GOEDIT.ELF" ||
		h.launches[0].args[0] != "/host/README.TXT" {
		t.Fatalf("launches = %+v; want GOEDIT.ELF /host/README.TXT", h.launches)
	}
}

func TestOpenBuiltinRoutesHTTPSDirectlyToWeb(t *testing.T) {
	h := newOpenHost()
	const target = "https://10.0.0.2/guide"
	status, _ := runOpenLine(t, h, "open "+target)
	if status != 0 {
		t.Fatalf("open status = %d, output=%q", status, h.outString())
	}
	if len(h.launches) != 1 || h.launches[0].name != "WEB.ELF" ||
		len(h.launches[0].args) != 1 || h.launches[0].args[0] != target {
		t.Fatalf("launches = %+v; want WEB.ELF %s", h.launches, target)
	}
	if len(h.markers) != 1 || !strings.Contains(h.markers[0], "scheme=https target="+target) {
		t.Fatalf("markers = %v", h.markers)
	}
}

func TestOpenBuiltinSplitsLongHTTPSAcrossExecArgs(t *testing.T) {
	h := newOpenHost()
	target := "https://example.com/" + strings.Repeat("a", 540)
	status, _ := runOpenLine(t, h, "open "+target)
	if status != 0 {
		t.Fatalf("open status = %d, output=%q", status, h.outString())
	}
	if len(h.launches) != 1 || h.launches[0].name != "WEB.ELF" {
		t.Fatalf("launches = %+v; want one WEB.ELF launch", h.launches)
	}
	args := h.launches[0].args
	if len(args) < 2 || len(args) > openExecArgSlots {
		t.Fatalf("URL args = %d, want 2..%d slots: %v", len(args), openExecArgSlots, args)
	}
	for _, arg := range args {
		if len(arg) > openExecArgBytes {
			t.Fatalf("URL arg has %d bytes, exceeds exec cap %d", len(arg), openExecArgBytes)
		}
	}
	if got := strings.Join(args, ""); got != target {
		t.Fatalf("joined URL = %q, want %q", got, target)
	}
}

func TestOpenBuiltinNamesHTTPSBeyondExecArgLimit(t *testing.T) {
	h := newOpenHost()
	target := "https://example.com/" +
		strings.Repeat("b", openExecArgBytes*openExecArgSlots)
	status, _ := runOpenLine(t, h, "open "+target)
	if status != 1 || len(h.launches) != 0 ||
		!strings.Contains(h.outString(), errOpenTargetTooLong.Error()) {
		t.Fatalf("oversized URL: status=%d launches=%v output=%q",
			status, h.launches, h.outString())
	}
}

func TestOpenBuiltinNamesUnsupportedSchemeAndMissingHandler(t *testing.T) {
	h := newOpenHost()
	status, _ := runOpenLine(t, h, "open ftp://example.com/file")
	if status != 1 || len(h.launches) != 0 ||
		!strings.Contains(h.outString(), "unsupported URL scheme ftp") {
		t.Fatalf("unsupported scheme: status=%d launches=%v output=%q",
			status, h.launches, h.outString())
	}

	h.out = nil
	h.files["/host/SAVE.ZIP"] = []byte("PK\x03\x04\x00\x02")
	status, _ = runOpenLine(t, h, "open SAVE.ZIP")
	if status != 1 || len(h.launches) != 0 ||
		!strings.Contains(h.outString(), "no handler for archive") {
		t.Fatalf("missing MIME handler: status=%d launches=%v output=%q",
			status, h.launches, h.outString())
	}
}

func TestOpenBuiltinNamesUnavailableApplication(t *testing.T) {
	h := newOpenHost()
	h.files["/host/README.TXT"] = []byte("hello from the share\n")
	h.missing["GOEDIT.ELF"] = true
	status, _ := runOpenLine(t, h, "open README.TXT")
	if status != 127 || len(h.launches) != 1 ||
		!strings.Contains(h.outString(), "handler GOEDIT.ELF unavailable") {
		t.Fatalf("missing app: status=%d launches=%v output=%q",
			status, h.launches, h.outString())
	}
}
