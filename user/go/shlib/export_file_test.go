package shlib

import (
	"strings"
	"testing"
)

// The export builtin's two gestures: `export NAME=VALUE`/`export NAME`
// is the env table (a set variable wins the word), and `export PATH`
// with NAME unset stages the file for the host outbox through the
// exportToHost seam.

func TestExportEnvFormUnchanged(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	status, _ := sh.RunLine("export FOO=bar")
	if status != 0 {
		t.Fatalf("export FOO=bar status = %d", status)
	}
	status, _ = sh.RunLine("export FOO")
	if status != 0 {
		t.Fatalf("export FOO status = %d", status)
	}
	status, _ = sh.RunLine("export")
	if status != 0 || !strings.Contains(h.outString(), "export FOO=bar") {
		t.Fatalf("export list: status=%d out=%q", status, h.outString())
	}
}

func TestExportFileStagesOutbox(t *testing.T) {
	h := newFakeHost()
	var got []string
	prev := exportToHost
	defer func() { exportToHost = prev }()
	exportToHost = func(path string) (string, string) {
		got = append(got, path)
		return "NOTES.TXT", ""
	}
	sh := NewShell(h, &History{})
	status, _ := sh.RunLine("cd /host/docs")
	if status != 0 {
		t.Fatalf("cd status = %d", status)
	}
	status, _ = sh.RunLine("export notes.txt")
	if status != 0 {
		t.Fatalf("export status = %d, out=%q", status, h.outString())
	}
	if len(got) != 1 || got[0] != "/docs/notes.txt" {
		t.Fatalf("stage saw %v, want the canonical /docs/notes.txt", got)
	}
	if !strings.Contains(h.outString(), "exported NOTES.TXT to host") {
		t.Fatalf("output = %q", h.outString())
	}
	found := false
	for _, m := range h.markers {
		if m == "gosh: export staged name=NOTES.TXT" {
			found = true
		}
	}
	if !found {
		t.Fatalf("markers = %v", h.markers)
	}
}

func TestExportFileRefusalsNamed(t *testing.T) {
	h := newFakeHost()
	prev := exportToHost
	defer func() { exportToHost = prev }()
	exportToHost = func(path string) (string, string) {
		return "", "payload_too_large"
	}
	sh := NewShell(h, &History{})
	status, _ := sh.RunLine("export big.bin")
	if status != 1 || !strings.Contains(h.outString(), "payload_too_large") {
		t.Fatalf("refusal: status=%d out=%q", status, h.outString())
	}
	found := false
	for _, m := range h.markers {
		if strings.Contains(m, "gosh: export refused target=big.bin reason=payload_too_large") {
			found = true
		}
	}
	if !found {
		t.Fatalf("markers = %v", h.markers)
	}
}

func TestExportUnsetNameStillNotSet(t *testing.T) {
	h := newFakeHost()
	prev := exportToHost
	defer func() { exportToHost = prev }()
	exportToHost = func(path string) (string, string) {
		return "", "gone"
	}
	sh := NewShell(h, &History{})
	status, _ := sh.RunLine("export MISSING")
	if status != 1 || !strings.Contains(h.outString(), "gosh: export: MISSING: not set") {
		t.Fatalf("missing file+var: status=%d out=%q", status, h.outString())
	}
}
