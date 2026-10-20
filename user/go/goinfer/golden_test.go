package main

// The M140a (#2784) golden: the stub journey's whole console transcript,
// pinned byte for byte BEFORE the engine moved to user/go/infer and
// checked after — GOINFER.ELF's observable output must not change when
// the CLI becomes a thin consumer of the library.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A diff is never auto-accepted. GOINFER_UPDATE_GOLDEN=1 explicitly
// regenerates the pinned transcript for review, the draw package's
// convention.
func TestStubRunConsoleMatchesGolden(t *testing.T) {
	h := newFakeHost()
	if err := run(h, []string{"stub"}); err != nil {
		t.Fatalf("run stub: %v", err)
	}
	got := strings.Join(h.console, "\n") + "\n"
	path := filepath.Join("testdata", "golden", "stub-console.txt")
	if os.Getenv("GOINFER_UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("golden updated: %s (%d bytes)", path, len(got))
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("missing golden %s (run GOINFER_UPDATE_GOLDEN=1 to create): %v", path, err)
	}
	if got != string(want) {
		t.Fatalf("stub console drifted from the pinned output\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}
