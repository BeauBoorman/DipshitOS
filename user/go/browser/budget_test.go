package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"virelai/webrender"
)

func TestRequiredReferencesFitPreflightLedger(t *testing.T) {
	files, err := filepath.Glob("../../../tests/fixtures/web/reference/*.html")
	if err != nil || len(files) != 17 {
		t.Fatal("reference inventory", err)
	}
	for _, path := range files {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		a := &app{}
		if !a.preflightPage(body) || a.memoryRemaining <= 0 {
			t.Fatalf("required reference cannot fit: %s", path)
		}
	}
}

func TestHostileMemoryShapeIsRefusedBeforeParsing(t *testing.T) {
	a := &app{}
	if a.preflightPage([]byte(strings.Repeat("<p>x</p>", 20000))) {
		t.Fatal("large DOM/cascade/box/item demand was promised without headroom")
	}
	a.memoryRemaining = 1
	if a.reserveCSS("p { margin:1px; }") {
		t.Fatal("stylesheet ledger overflow accepted")
	}
}

func TestImageHeadroomIsCheckedBeforeDecode(t *testing.T) {
	a := &app{hist: newHistory(), text: webrender.Bitmap{}, target: "/host/IMAGE.HTML"}
	if a.canDecodeImage(1) {
		t.Fatal("decoder was permitted without transient headroom")
	}
	a.memoryRemaining = imageDecodeReserve + 2
	if !a.canDecodeImage(1) {
		t.Fatal("exact admitted headroom refused")
	}
	a.resourceForTest = func(string, int) ([]byte, string) {
		a.memoryRemaining = 1
		return []byte("qoif"), ""
	}
	a.loadBody([]byte(`<img src="shape.qoi" alt="bounded placeholder">`), a.target)
	if len(a.imageSources) != 0 || len(a.diagnostics) == 0 ||
		a.diagnostics[0].Text != "page-memory-limit: image" {
		t.Fatalf("image decoded before refusing insufficient headroom: %+v", a.diagnostics)
	}
}
