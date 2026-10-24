package main

import (
	"testing"

	"virelai/settings"
)

// The panel's markers are gate grep targets: pin the exact shapes so a drift is
// a host-test failure instead of a silent live miss.
func TestPanelMarkerShapes(t *testing.T) {
	want := map[string]string{
		markerOpen:     "goset: open id=",
		markerDeclare:  "goset: declare accepted",
		markerBad:      "goset: settings bad",
		markerReady:    "goset: ready ",
		markerSet:      "goset: set ",
		markerDiscard:  "goset: discard ",
		markerSaved:    "goset: saved ",
		markerNotified: "goset: settings notified key=",
		markerRefused:  "goset: save refused",
		markerSaveFail: "goset: save failed rc=",
		markerPresent:  "goset: present",
		markerClose:    "goset: close",
		markerOK:       "goset OK",
	}
	for got, expect := range want {
		if got != expect {
			t.Fatalf("marker %q, want %q", got, expect)
		}
	}
}

func TestPanelStartsWithTheTableInForce(t *testing.T) {
	a := newPanel(nil)
	if a.file.State != settings.StateMissing {
		t.Fatalf("host decode state = %d, want StateMissing (no file on the host)", a.file.State)
	}
	if v, ok := settings.Get(a.disp, "wm"); !ok || v != "gotabwm" {
		t.Fatalf("wm = %q ok=%v, want the compiled default", v, ok)
	}
	if a.mode() != "rw" {
		t.Fatalf("mode = %q, want rw", a.mode())
	}
	if got := a.summary(); got != "keys=13 wm=gotabwm theme=dark" {
		t.Fatalf("summary = %q", got)
	}
	if v, ok := settings.Get(a.disp, "keyboard_layout"); !ok || v != "us" {
		t.Fatalf("keyboard_layout = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := settings.Get(a.disp, "idle_minutes"); !ok || v != "5" {
		t.Fatalf("idle_minutes = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := settings.Get(a.disp, "notify_dnd"); !ok || v != "off" {
		t.Fatalf("notify_dnd = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := settings.Get(a.disp, "timezone"); !ok || v != "UTC" {
		t.Fatalf("timezone = %q ok=%v, want the compiled default", v, ok)
	}
	if len(a.labels()) != len(a.disp) {
		t.Fatalf("labels = %d, rows = %d", len(a.labels()), len(a.disp))
	}
}

func rowOf(t *testing.T, a *panel, key string) int {
	t.Helper()
	for i, s := range a.disp {
		if s.Key == key {
			return i
		}
	}
	t.Fatalf("no row for %q in %+v", key, a.disp)
	return -1
}
