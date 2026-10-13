package draw

import (
	"errors"
	"os"
	"testing"

	"virelai/ttf"
	"virelai/widgets"
)

// textFaces parses the shipped fixtures once; the registry loader below hands
// out these exact *Face values so a miss consults a real cmap.
func textFaces(t *testing.T) map[string]*ttf.Face {
	t.Helper()
	faces := map[string]*ttf.Face{}
	for name, p := range map[string]string{
		"INTER.TTF":  "../../../image/fonts/Inter-Regular.ttf",
		"CHROME.TTF": "../../../image/fonts/VirelaiChrome-Regular.ttf",
	} {
		data, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("font fixture %s: %v", p, err)
		}
		f, err := ttf.Parse(data)
		if err != nil {
			t.Fatalf("parse %s: %v", p, err)
		}
		faces[name] = f
	}
	return faces
}

func testChain(t *testing.T, faces map[string]*ttf.Face, manifest string) (*ttf.Chain, *[]string) {
	t.Helper()
	specs, err := ttf.ParseManifest([]byte(manifest))
	if err != nil {
		t.Fatalf("manifest: %v", err)
	}
	var reads []string
	reg := ttf.NewRegistry(specs, func(file string) (*ttf.Face, error) {
		reads = append(reads, file)
		f := faces[file]
		if f == nil {
			return nil, errors.New("no such staged face")
		}
		return f, nil
	})
	return reg.Chain(ttf.Query{Role: "ui"}), &reads
}

// secondFaceRune is a codepoint chrome covers and Inter lacks — found by
// diffing the two cmaps, never hard-coded.
func secondFaceRune(t *testing.T, faces map[string]*ttf.Face) rune {
	t.Helper()
	inter, chrome := faces["INTER.TTF"], faces["CHROME.TTF"]
	for cp := rune(0x20); cp <= 0x2FFFF; cp++ {
		if chrome.GlyphIndex(cp) != 0 && inter.GlyphIndex(cp) == 0 {
			return cp
		}
	}
	t.Fatal("no chrome-only rune found")
	return 0
}

func inkCount(c *BufferCanvas, bg uint32) int {
	n := 0
	for _, px := range c.Pix {
		if px != bg {
			n++
		}
	}
	return n
}

// TestLoadRegistryOnHostReportsMissing: off the guest the file channel
// answers -ENOSYS, so LoadRegistry must report a missing manifest and hand
// back no registry — the caller's hard-coded faces then apply, which is the
// card's "no manifest keeps today's behavior" arm.
func TestLoadRegistryOnHostReportsMissing(t *testing.T) {
	reg, marker := LoadRegistry()
	if reg != nil {
		t.Fatal("host must not conjure a registry")
	}
	if marker != "manifest=missing" {
		t.Fatalf("marker = %q, want manifest=missing", marker)
	}
}

// TestTextChainPaintsTheFallbackFace: a rune only the second face covers must
// paint its glyph, not the primary's .notdef — and the second face's file is
// read only because the miss happened.
func TestTextChainPaintsTheFallbackFace(t *testing.T) {
	faces := textFaces(t)
	ch, reads := testChain(t, faces,
		"INTER.TTF | role=ui | order=1\nCHROME.TTF | role=symbol | order=1\n")
	r := secondFaceRune(t, faces)
	const bg = 0x00000000
	cov := canvas(64, 40, bg)
	TextChain(cov, ch, widgets.Rect{W: 64, H: 40}, 4, 30, 16, "A", 0xffffffff)
	if len(*reads) != 1 || (*reads)[0] != "INTER.TTF" {
		t.Fatalf("a covered run read %v, want [INTER.TTF]", *reads)
	}
	fb := canvas(64, 40, bg)
	TextChain(fb, ch, widgets.Rect{W: 64, H: 40}, 4, 30, 16, "A"+string(r), 0xffffffff)
	if len(*reads) != 2 || (*reads)[1] != "CHROME.TTF" {
		t.Fatalf("the miss must lazily read only the covering face: %v", *reads)
	}
	if inkCount(fb, bg) <= inkCount(cov, bg) {
		t.Fatalf("the fallback rune painted no ink: covered=%d fallback=%d",
			inkCount(cov, bg), inkCount(fb, bg))
	}
}

// TestTextChainMatchesTextOnCoveredRuns: for text the primary covers, the
// chain painter must be pixel-identical to the single-face Text — the chain
// may only change the pixels of runes the primary lacks.
func TestTextChainMatchesTextOnCoveredRuns(t *testing.T) {
	faces := textFaces(t)
	ch, _ := testChain(t, faces,
		"INTER.TTF | role=ui | order=1\nCHROME.TTF | role=symbol | order=1\n")
	const bg = 0x00102030
	a := canvas(160, 40, bg)
	Text(a, faces["INTER.TTF"], widgets.Rect{W: 160, H: 40}, 4, 30, 16, "Hello, world", 0xffffffff)
	b := canvas(160, 40, bg)
	TextChain(b, ch, widgets.Rect{W: 160, H: 40}, 4, 30, 16, "Hello, world", 0xffffffff)
	for i := range a.Pix {
		if a.Pix[i] != b.Pix[i] {
			t.Fatalf("chain paint diverged from single-face paint at pixel %d", i)
		}
	}
}

func TestTextChainNilSafety(t *testing.T) {
	c := canvas(32, 16, 0)
	TextChain(c, nil, widgets.Rect{W: 32, H: 16}, 0, 8, 13, "hi", 0xffffffff)
	TextChain(nil, nil, widgets.Rect{W: 32, H: 16}, 0, 8, 13, "hi", 0)
	TextChain(c, nil, widgets.Rect{}, 0, 8, 13, "hi", 0xffffffff)
	if inkCount(c, 0) != 0 {
		t.Fatal("a nil chain painted pixels")
	}
}
