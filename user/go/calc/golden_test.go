package main

// M104h (#2275) composite goldens for the flagship migrated app: GOCALC's
// pad painted onto a draw.BufferCanvas through paintCanvas — the §2.2
// rounded plates with their Border stroke, the §2.3 idle faces, the
// Surface display carrying 8x8 bitmap labels (no LabelFace — the kit's
// degrade), and the history line above it. This is the surface the guest
// composites once tabapp's bind hands the seat the canvas bytes.

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"virelai/draw"
	"virelai/tabapp"
)

// A diff is never auto-accepted. CALC_UPDATE_GOLDEN=1 explicitly
// regenerates the pinned images for review — the draw/golden_test.go idiom.
func checkCompositeGolden(t *testing.T, name string, c *draw.BufferCanvas) {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, c.W, c.H))
	for i, px := range c.Pix {
		img.Pix[4*i+0] = byte(px >> 16)
		img.Pix[4*i+1] = byte(px >> 8)
		img.Pix[4*i+2] = byte(px)
		img.Pix[4*i+3] = byte(px >> 24)
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join("testdata", "golden", name+".png")
	if os.Getenv("CALC_UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("golden updated: %s (%d bytes)", path, buf.Len())
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("missing golden %s (run CALC_UPDATE_GOLDEN=1 to create): %v", path, err)
	}
	pinned, err := png.Decode(bytes.NewReader(want))
	if err != nil {
		t.Fatalf("decode golden %s: %v", path, err)
	}
	if !pinned.Bounds().Eq(img.Bounds()) {
		t.Fatalf("golden bounds %v != %v", pinned.Bounds(), img.Bounds())
	}
	diffs, first := 0, ""
	for y := 0; y < c.H; y++ {
		for x := 0; x < c.W; x++ {
			a := color.NRGBAModel.Convert(pinned.At(x, y)).(color.NRGBA)
			b := img.NRGBAAt(x, y)
			if a != b {
				diffs++
				if first == "" {
					first = fmt.Sprintf("(%d,%d): %v != %v", x, y, a, b)
				}
			}
		}
	}
	if diffs != 0 {
		t.Fatalf("golden %s differs at %d pixels; first %s", name, diffs, first)
	}
}

// The decimal pad after an evaluation: the history line carries the
// evaluated expression, the display its result, and the 5x4 pad sits in
// the idle state. The TabApp is hand-built at native size so Layout is the
// identity and the pin is the unscaled 512x384 design.
func TestCalcDecCompositeGolden(t *testing.T) {
	a := &app{ta: &tabapp.TabApp{W: natW, H: natH}}
	feedKeys(t, a, "12+3=")
	c := &draw.BufferCanvas{Pix: make([]uint32, natW*natH), W: natW, H: natH}
	a.paintCanvas(c)
	checkCompositeGolden(t, "calc-dec", c)
}

// The programmer pad: 'p' toggles the 6x6 layout (HEX/DEC/OCT/BIN base row,
// logic ops, the wider digit grid) and the display reads hex.
func TestCalcProgCompositeGolden(t *testing.T) {
	a := &app{ta: &tabapp.TabApp{W: natW, H: natH}}
	feedKeys(t, a, "pff")
	c := &draw.BufferCanvas{Pix: make([]uint32, natW*natH), W: natW, H: natH}
	a.paintCanvas(c)
	checkCompositeGolden(t, "calc-prog", c)
}
