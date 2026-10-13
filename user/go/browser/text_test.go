package main

import (
	"os"
	"strings"
	"testing"

	"virelai/webrender"
)

func browserFonts(t *testing.T) webrender.Fonts {
	t.Helper()
	ui, err := os.ReadFile("../../../image/fonts/Inter-Regular.ttf")
	if err != nil {
		t.Fatalf("Inter fixture: %v", err)
	}
	mono, err := os.ReadFile("../../../image/fonts/FiraCode-Regular.ttf")
	if err != nil {
		t.Fatalf("Fira Code fixture: %v", err)
	}
	bold, err := os.ReadFile("../../../image/fonts/Inter-Bold.ttf")
	if err != nil {
		t.Fatalf("Inter Bold fixture: %v", err)
	}
	italic, err := os.ReadFile("../../../image/fonts/Inter-Italic.ttf")
	if err != nil {
		t.Fatalf("Inter Italic fixture: %v", err)
	}
	boldItalic, err := os.ReadFile("../../../image/fonts/Inter-BoldItalic.ttf")
	if err != nil {
		t.Fatalf("Inter Bold Italic fixture: %v", err)
	}
	serif, err := os.ReadFile("../../../image/fonts/NotoSerif-Regular.ttf")
	if err != nil {
		t.Fatalf("Noto Serif fixture: %v", err)
	}
	f := webrender.LoadFonts(webrender.FontFiles{UI: ui, Mono: mono, Serif: serif, Bold: bold, Italic: italic, BoldItalic: boldItalic})
	if f.UI == nil || f.Mono == nil || f.Serif == nil || f.Bold == nil || f.Italic == nil || f.BoldItalic == nil {
		t.Fatal("LoadFonts dropped a face")
	}
	return f
}

// TestTextProbeOnTrueType pins the probe the class-B gate asserts against. These
// are the exact numbers the guest prints when the faces load, so a change in the
// engine that would trip the gate trips a host test first.
func TestTextProbeOnTrueType(t *testing.T) {
	probe := textProbeString(browserFonts(t))
	t.Logf("truetype probe: %s", probe)
	for _, want := range []string{
		"face=truetype(inter+firacode)",
		"proportional=yes",
		"body-lineh=18",
		"h1-lineh=33",
		"mono-lineh=17",
		"adv-i=3",
		"adv-W=13",
		"adv-space=4",
		"bold-face=yes",
		"bold-heavier=yes",
		"italic-face=yes",
		"bi-face=yes",
		"bi-resolve=bolditalic",
		"serif-face=yes",
		"serif-resolve=serif",
	} {
		if !strings.Contains(probe, want) {
			t.Errorf("probe is missing %q\n  got: %s", want, probe)
		}
	}
	if strings.Contains(probe, "adv-i=8") || strings.Contains(probe, "adv-W=8") {
		t.Errorf("the probe reports the 8x8 lattice: %s", probe)
	}
}

// TestTextProbeOnBitmap is the control: the fallback must be unmistakable.
func TestTextProbeOnBitmap(t *testing.T) {
	probe := textProbeString(webrender.Bitmap{})
	t.Logf("bitmap probe: %s", probe)
	for _, want := range []string{
		"face=bitmap8x8",
		"proportional=no",
		"body-lineh=10",
		"h1-lineh=18",
		"adv-i=8",
		"adv-W=8",
		"adv-space=8",
		"bold-face=no",
		"italic-face=no",
		"bi-face=no",
		"bi-resolve=none",
		"serif-face=no",
		"serif-resolve=none",
	} {
		if !strings.Contains(probe, want) {
			t.Errorf("bitmap probe is missing %q\n  got: %s", want, probe)
		}
	}
}

// TestProbeDistinguishesTheTwoEngines: the gate's whole point is that these two
// lines cannot be confused.
func TestProbeDistinguishesTheTwoEngines(t *testing.T) {
	a := textProbeString(browserFonts(t))
	b := textProbeString(webrender.Bitmap{})
	if a == b {
		t.Fatal("the TrueType and bitmap probes are identical")
	}
	for _, field := range []string{"proportional=", "adv-i=", "adv-W=", "h1-lineh="} {
		if fieldOf(a, field) == fieldOf(b, field) {
			t.Errorf("field %s does not distinguish the engines (%q)", field, fieldOf(a, field))
		}
	}
}

func fieldOf(line, prefix string) string {
	for _, f := range strings.Fields(line) {
		if strings.HasPrefix(f, prefix) {
			return f
		}
	}
	return ""
}

// TestLoadTextEngineOnHostFallsBack: off the guest the file channel answers
// -ENOSYS, so the engine is the bitmap one and says so. This is the same path a
// missing font takes in the guest, and it must not panic or blank the app.
func TestLoadTextEngineOnHostFallsBack(t *testing.T) {
	engine, uiState, monoState, serifState := loadTextEngine()
	if engine.Name() != "bitmap8x8" {
		t.Logf("host file channel returned fonts; engine=%s", engine.Name())
	}
	if uiState == "truetype" && engine.UI == nil {
		t.Error("uiState says truetype but no UI face is loaded")
	}
	if monoState == "truetype" && engine.Mono == nil {
		t.Error("monoState says truetype but no mono face is loaded")
	}
	if serifState == "truetype" && engine.Serif == nil {
		t.Error("serifState says truetype but no serif face is loaded")
	}
	if probe := textProbeString(engine); !strings.Contains(probe, "face=") {
		t.Errorf("probe must always describe the engine: %q", probe)
	}
	t.Logf("host engine=%s ui=%s mono=%s serif=%s", engine.Name(), uiState, monoState, serifState)
}

// TestReadWholeFileIsBoundedAndSafe: a bounded reader that never panics.
func TestReadWholeFileIsBoundedAndSafe(t *testing.T) {
	if b := readWholeFile("/host/NOPE.TTF", maxFontBytes); b != nil {
		t.Errorf("a missing file returned %d bytes", len(b))
	}
	if b := readWholeFile("", 16); b != nil {
		t.Errorf("an empty path returned %d bytes", len(b))
	}
	if b := readWholeFile("/host/NOPE.TTF", 0); b != nil {
		t.Errorf("a zero cap returned %d bytes", len(b))
	}
}

// TestMaxFontBytesHoldsBothShippedFaces: the cap must actually fit the fixtures,
// or the guest would fall back and the gate would (correctly) fail.
func TestMaxFontBytesHoldsBothShippedFaces(t *testing.T) {
	for _, p := range []string{
		"../../../image/fonts/Inter-Regular.ttf",
		"../../../image/fonts/Inter-Bold.ttf",
		"../../../image/fonts/Inter-Italic.ttf",
		"../../../image/fonts/NotoSerif-Regular.ttf",
		"../../../image/fonts/FiraCode-Regular.ttf",
	} {
		st, err := os.Stat(p)
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		t.Logf("%s is %d bytes (cap %d)", p, st.Size(), maxFontBytes)
		if st.Size() > int64(maxFontBytes) {
			t.Errorf("%s (%d bytes) exceeds maxFontBytes (%d)", p, st.Size(), maxFontBytes)
		}
	}
}

// TestResolveImageRefusesNetworkAndMissingSources.
func TestResolveImageRefusesNetworkAndMissingSources(t *testing.T) {
	a := &app{target: "/host/PAGE.HTML"}
	for _, src := range []string{"", "http://10.0.0.2/a.png", "https://example.com/a.png", "/host/NOPE.PNG", "missing.png"} {
		if data, ok := a.resolveImage(src); ok {
			t.Errorf("resolveImage(%q) returned %d bytes, want a refusal", src, len(data))
		}
	}
}

// TestTextProbeIsLanguageStable guards the field names the gate greps.
func TestTextProbeIsLanguageStable(t *testing.T) {
	probe := textProbeString(browserFonts(t))
	for _, f := range []string{"face=", "proportional=", "body-lineh=", "h1-lineh=", "mono-lineh=", "adv-i=", "adv-W=", "adv-space=", "bold-face=", "bold-heavier=", "italic-face=", "bi-face=", "bi-resolve=", "serif-face=", "serif-resolve="} {
		if !strings.Contains(probe, f) {
			t.Errorf("probe lost field %q: %s", f, probe)
		}
	}
}
