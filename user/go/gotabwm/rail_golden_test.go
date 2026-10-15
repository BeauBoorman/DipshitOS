package main

// M104h (#2275) composite goldens for the seat rail: paintRail's whole
// strip on a draw.BytesCanvas — the §2.3.6 focused cell (Selection fill +
// 3px Accent marker), the idle and hovered cells, the Warning frozen
// badge, and the close glyph in both faces: the VirelaiChrome PUA
// window-close on the resolved registry, and the bitmap 'x' degrade on a
// missing manifest (§3.4). The strip alone is the surface — the rail is
// the seat's design-language chrome.

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"virelai/theme"
	"virelai/ttf"
	"virelai/vi"
)

// A diff is never auto-accepted. GOTABWM_UPDATE_GOLDEN=1 explicitly
// regenerates the pinned images for review — the draw/golden_test.go idiom.
func checkSeatGolden(t *testing.T, name string, scan []byte, w, h int) {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	pix := asUint32(scan)
	for i, px := range pix {
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
	if os.Getenv("GOTABWM_UPDATE_GOLDEN") == "1" {
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
		t.Fatalf("missing golden %s (run GOTABWM_UPDATE_GOLDEN=1 to create): %v", path, err)
	}
	pinned, err := png.Decode(bytes.NewReader(want))
	if err != nil {
		t.Fatalf("decode golden %s: %v", path, err)
	}
	if !pinned.Bounds().Eq(img.Bounds()) {
		t.Fatalf("golden bounds %v != %v", pinned.Bounds(), img.Bounds())
	}
	diffs, first := 0, ""
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
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

// seatRegistryFromRepo builds the registry the guest builds — the staged
// FONTS.TXT parsed verbatim, faces loaded lazily from the same TTFs the
// share copies — so the pinned rail is the fonted seat, not a mock.
func seatRegistryFromRepo(t *testing.T) *ttf.Registry {
	t.Helper()
	data, err := os.ReadFile("../../../image/fonts/fonts.txt")
	if err != nil {
		t.Fatal(err)
	}
	specs, err := ttf.ParseManifest(data)
	if err != nil {
		t.Fatal(err)
	}
	// The share's 8.3 names -> the repo files session.sh copies them from.
	repo := map[string]string{
		"INTER.TTF":    "Inter-Regular.ttf",
		"INTERB.TTF":   "Inter-Bold.ttf",
		"INTERI.TTF":   "Inter-Italic.ttf",
		"INTERBI.TTF":  "Inter-BoldItalic.ttf",
		"FIRACODE.TTF": "FiraCode-Regular.ttf",
		"NOTOSERF.TTF": "NotoSerif-Regular.ttf",
		"CHROME.TTF":   "VirelaiChrome-Regular.ttf",
		"NOTOCJK.TTF":  "NotoSansJP-Regular.ttf",
	}
	return ttf.NewRegistry(specs, func(file string) (*ttf.Face, error) {
		name, ok := repo[file]
		if !ok {
			return nil, fmt.Errorf("no repo font for share file %s", file)
		}
		b, err := os.ReadFile(filepath.Join("../../../image/fonts", name))
		if err != nil {
			return nil, err
		}
		return ttf.Parse(b)
	})
}

// stubSeatRegistry points the seat's font resolution at reg (nil = the
// missing-manifest degrade) for one test and restores both the loader and
// the resolved-face cache.
func stubSeatRegistry(t *testing.T, reg *ttf.Registry) {
	t.Helper()
	orig, saved := loadSeatRegistry, seatFonts
	loadSeatRegistry = func() (*ttf.Registry, string) {
		if reg == nil {
			return nil, "manifest=missing"
		}
		return reg, "manifest=ok faces=9 (test)"
	}
	seatFonts.tried, seatFonts.ui, seatFonts.glyph = false, nil, nil
	t.Cleanup(func() {
		loadSeatRegistry = orig
		seatFonts = saved
	})
}

// goldenStrip is one strip carrying every rail state: cell 0 hovered,
// cell 1 focused (Selection + the Accent marker), cell 2 frozen (Warning
// badge), cell 3's close zone under the pointer (Danger tint).
func goldenStrip(t *testing.T) *TabStrip {
	t.Helper()
	var strip TabStrip
	for i, title := range []string{"Calc", "Edit", "Term", "Files"} {
		if !strip.OpenTab(uint32(10+i), title) {
			t.Fatalf("OpenTab %q", title)
		}
	}
	if !strip.FocusTab(11) {
		t.Fatal("FocusTab")
	}
	if !strip.Freeze(12) {
		t.Fatal("Freeze")
	}
	return &strip
}

func paintGoldenRail(t *testing.T, strip *TabStrip, hover, closeHover int) []byte {
	t.Helper()
	scan := make([]byte, vi.ScanoutWidth*RailHeight*4)
	if paintRail(scan, vi.ScanoutWidth, vi.ScanoutHeight, RailHeight, strip, hover, closeHover) == 0 {
		t.Fatal("paintRail wrote nothing")
	}
	return scan
}

func TestRailCompositeGolden(t *testing.T) {
	tok := theme.Current
	theme.Current = theme.Dark
	t.Cleanup(func() { theme.Current = tok })

	stubSeatRegistry(t, seatRegistryFromRepo(t))
	scan := paintGoldenRail(t, goldenStrip(t), 0, 3)
	checkSeatGolden(t, "seat-rail", scan, vi.ScanoutWidth, RailHeight)
}

// The §3.4 degrade on the same strip: no manifest, so the close control
// falls back to the bitmap 'x' — still a full-canvas rail, pinned so the
// fallback path can't silently drift from the fonted one's geometry.
func TestRailCompositeGoldenDegrade(t *testing.T) {
	tok := theme.Current
	theme.Current = theme.Dark
	t.Cleanup(func() { theme.Current = tok })

	stubSeatRegistry(t, nil)
	scan := paintGoldenRail(t, goldenStrip(t), 0, 3)
	checkSeatGolden(t, "seat-rail-degrade", scan, vi.ScanoutWidth, RailHeight)
}
