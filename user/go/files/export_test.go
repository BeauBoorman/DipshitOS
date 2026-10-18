package main

import (
	"strings"
	"testing"
)

// "Export to Host" (M127d): `e` stages the selection through the
// exportFn seam — the model decides and marks; refusals are the lane
// vocabulary carried into the marker and the status line.

func TestExportStagesSelection(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	m.handleKey(runeKey('j')) // select KNOWN.TXT (dirs sort first)
	var got []string
	prev := exportFn
	defer func() { exportFn = prev }()
	exportFn = func(path string) (string, string) {
		got = append(got, path)
		return "KNOWN.TXT", ""
	}
	m.handleKey(runeKey('e'))
	if len(got) != 1 || got[0] != "/host/FM/KNOWN.TXT" {
		t.Fatalf("stage saw %v, want /host/FM/KNOWN.TXT", got)
	}
	if out := pendingJoined(&m); !strings.Contains(out, markerExport+"KNOWN.TXT -> OUTBOX/KNOWN.TXT") {
		t.Fatalf("export marker missing: %q", out)
	}
	if m.status != "exported KNOWN.TXT" {
		t.Fatalf("status = %q", m.status)
	}
}

func TestExportDirRefusedByName(t *testing.T) {
	m := testModel(entry("SUB", true), entry("KNOWN.TXT", false))
	called := false
	prev := exportFn
	defer func() { exportFn = prev }()
	exportFn = func(path string) (string, string) {
		called = true
		return "", ""
	}
	m.handleKey(runeKey('e'))
	if called {
		t.Fatal("a directory reached the stage seam")
	}
	if out := pendingJoined(&m); !strings.Contains(out, markerExportNo+"SUB unsupported_kind") {
		t.Fatalf("dir refusal marker missing: %q", out)
	}
}

func TestExportRefusalCarriesLaneWord(t *testing.T) {
	m := testModel(entry("KNOWN.TXT", false))
	prev := exportFn
	defer func() { exportFn = prev }()
	exportFn = func(path string) (string, string) {
		return "", "payload_too_large"
	}
	m.handleKey(runeKey('e'))
	if out := pendingJoined(&m); !strings.Contains(out, markerExportNo+"KNOWN.TXT payload_too_large") {
		t.Fatalf("refusal marker missing: %q", out)
	}
	if m.status != "export refused: payload_too_large" {
		t.Fatalf("status = %q", m.status)
	}
}
