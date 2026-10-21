package theme

import (
	"math"
	"testing"
)

// snapshotTheme captures the composed state so a test can put it back —
// Current alone no longer describes it (M165b): the base name and the
// contrast switch are separate inputs to resolve().
func snapshotTheme() (Tokens, string, bool) { return Current, baseName, contrastHigh }

func restoreTheme(t Tokens, name string, high bool) {
	baseName, contrastHigh = name, high
	resolve()
	if Current.Bg != t.Bg || Current.Accent != t.Accent {
		// The saved tokens came from a caller-set Current, not the
		// (name, contrast) composition — put it back verbatim.
		Current = t
	}
}

// contrastRatio is the WCAG relative-luminance ratio the card pins: the
// high-contrast variants must sit at or above 7:1 ink-on-background.
func contrastRatio(a, b uint32) float64 {
	lum := func(c uint32) float64 {
		ch := func(shift uint) float64 {
			v := float64((c>>shift)&0xff) / 255
			if v <= 0.03928 {
				return v / 12.92
			}
			return math.Pow((v+0.055)/1.055, 2.4)
		}
		return 0.2126*ch(16) + 0.7152*ch(8) + 0.0722*ch(0)
	}
	l1, l2 := lum(a), lum(b)
	if l1 < l2 {
		l1, l2 = l2, l1
	}
	return (l1 + 0.05) / (l2 + 0.05)
}

func TestDarkMatchesZigThemeZig(t *testing.T) {
	// Byte-identical to user/src/lib/ui/theme.zig THEME_DARK / CHROME_DARK
	// for the colours #1530 asked to agree on.
	if Dark.Bg != 0x182026 || Dark.Surface != 0x222d35 || Dark.Border != 0x334155 {
		t.Fatalf("dark chrome %#x/%#x/%#x", Dark.Bg, Dark.Surface, Dark.Border)
	}
	if Dark.Accent != 0x3b82f6 || Dark.Text != 0xffffff || Dark.Muted != 0x94a3b8 {
		t.Fatalf("dark ink %#x/%#x/%#x", Dark.Accent, Dark.Text, Dark.Muted)
	}
	if Dark.BtnIdle != 0x2d3748 || Dark.BtnHover != 0x4a5568 || Dark.BtnPressed != 0x1a202c {
		t.Fatalf("dark buttons %#x/%#x/%#x", Dark.BtnIdle, Dark.BtnHover, Dark.BtnPressed)
	}
	if Dark.PadSM != 4 || Dark.PadMD != 8 || Dark.BorderW != 1 || Dark.FocusW != 2 {
		t.Fatalf("spacing pad_sm=%d pad_md=%d border=%d focus=%d", Dark.PadSM, Dark.PadMD, Dark.BorderW, Dark.FocusW)
	}
	if Dark.Danger != 0xef4444 || Dark.Caret != 0x3b82f6 {
		t.Fatalf("dark danger/caret %#x/%#x", Dark.Danger, Dark.Caret)
	}
}

func TestLightMatchesZigThemeLight(t *testing.T) {
	if Light.Bg != 0xf1f5f9 || Light.Surface != 0xffffff || Light.Accent != 0x2563eb {
		t.Fatalf("light %#x/%#x/%#x", Light.Bg, Light.Surface, Light.Accent)
	}
}

func TestSetAndName(t *testing.T) {
	saved, name, high := snapshotTheme()
	defer restoreTheme(saved, name, high)
	restoreTheme(Dark, "dark", false)
	if !Set("light") || Name() != "light" || Current.Bg != Light.Bg {
		t.Fatal("Set(light) did not switch")
	}
	if !Set("dark") || Name() != "dark" {
		t.Fatal("Set(dark) did not switch back")
	}
	if Set("amber") || Set("") || Set("DARK") {
		t.Fatal("unknown names must be refused")
	}
}

func TestParseAndApplySettings(t *testing.T) {
	saved, name, high := snapshotTheme()
	defer restoreTheme(saved, name, high)
	restoreTheme(Dark, "dark", false)
	if ParseSettings([]byte("#v2\nhostname=virelai\n")) != "" {
		t.Fatal("missing theme key must be empty")
	}
	if ParseSettings([]byte("#v2\ntheme=light\nwm=gotabwm\n")) != "light" {
		t.Fatal("theme=light")
	}
	if ParseSettings([]byte("theme=amber\n")) != "" {
		t.Fatal("amber has no Go reader")
	}
	if !ApplySettings([]byte("#v2\ntheme=light\n")) || Name() != "light" {
		t.Fatal("ApplySettings light")
	}
}

// M165b (#2983): the high-contrast variants hold the card's floor —
// ink/background contrast of at least 7:1 — and carry wider focus and
// border strokes than the table they vary.
func TestHighContrastVariantsMeetTheFloor(t *testing.T) {
	for _, hc := range []struct {
		name string
		tok  Tokens
		base Tokens
	}{
		{"dark", DarkHC, Dark},
		{"light", LightHC, Light},
	} {
		if r := contrastRatio(hc.tok.Ink, hc.tok.Bg); r < 7 {
			t.Errorf("%s: Ink/Bg contrast %.2f:1, want >= 7:1", hc.name, r)
		}
		if r := contrastRatio(hc.tok.Text, hc.tok.Bg); r < 7 {
			t.Errorf("%s: Text/Bg contrast %.2f:1, want >= 7:1", hc.name, r)
		}
		if hc.tok.FocusW <= hc.base.FocusW || hc.tok.BorderW <= hc.base.BorderW {
			t.Errorf("%s: strokes %d/%d not wider than base %d/%d",
				hc.name, hc.tok.FocusW, hc.tok.BorderW, hc.base.FocusW, hc.base.BorderW)
		}
	}
}

// M165b: a11y.contrast composes with the base — it selects the variant of
// the CURRENT table, and flipping the base afterwards keeps the switch.
func TestContrastComposesWithTheBase(t *testing.T) {
	saved, name, high := snapshotTheme()
	defer restoreTheme(saved, name, high)
	restoreTheme(Dark, "dark", false)

	if ParseContrast([]byte("#v2\nhostname=virelai\n")) != "" {
		t.Fatal("missing a11y.contrast must be empty")
	}
	if ParseContrast([]byte("#v2\na11y.contrast=high\n")) != "high" {
		t.Fatal("a11y.contrast=high")
	}
	if ParseContrast([]byte("a11y.contrast=HIGH\n")) != "" {
		t.Fatal("unknown contrast values must be ignored")
	}
	// Last row wins, like theme=.
	if ParseContrast([]byte("a11y.contrast=high\na11y.contrast=off\n")) != "off" {
		t.Fatal("the later contrast row must win")
	}

	// high selects the variant of the current table — dark first.
	if !ApplySettings([]byte("#v2\na11y.contrast=high\n")) ||
		Current.Bg != DarkHC.Bg || Contrast() != "high" || Name() != "dark" {
		t.Fatal("contrast=high on dark did not select DarkHC")
	}
	// ...and the switch survives a later base change (each key honoured
	// without clobbering the other).
	if !ApplySettings([]byte("#v2\ntheme=light\na11y.contrast=high\n")) ||
		Current.Bg != LightHC.Bg || Name() != "light" {
		t.Fatal("theme=light + contrast=high did not select LightHC")
	}
	if !Set("dark") || Current.Bg != DarkHC.Bg {
		t.Fatal("Set(dark) under high contrast must stay on the variant")
	}
	// off returns to the plain table, and an ApplySettings carrying no
	// a11y row leaves the switch alone.
	SetContrast(false)
	if Current.Bg != Dark.Bg || Contrast() != "off" {
		t.Fatal("SetContrast(false) did not return to Dark")
	}
	if ApplySettings([]byte("#v2\na11y.contrast=bogus\n")) {
		t.Fatal("an unknown contrast value must be a no-op")
	}
}

func TestHex6(t *testing.T) {
	if got := Hex6(0x182026); got != "0x182026" {
		t.Fatalf("Hex6 = %q", got)
	}
	if got := Hex6(0x3b82f6); got != "0x3b82f6" {
		t.Fatalf("Hex6 accent = %q", got)
	}
	if got := Hex6(0); got != "0x000000" {
		t.Fatalf("Hex6 zero = %q", got)
	}
}

func TestBootDefaultIsDark(t *testing.T) {
	if Current.Bg != Dark.Bg || Name() != "dark" {
		t.Fatal("package default must be dark")
	}
}

func TestDepthTokensV2(t *testing.T) {
	// M104a (#2268): Go-only roles — no Zig table carries them, so these
	// pin the contract's chosen values, not a Zig byte-parity.
	if Dark.Shadow != 0x000000 || Light.Shadow != 0x0f172a {
		t.Fatalf("shadow ink %#x/%#x", Dark.Shadow, Light.Shadow)
	}
	// The seat desktop gradient endpoints match the kernel's
	// wallpaper_top/bot for dark and light (driving_award.zig), so the
	// Go-seat desktop reads identically to the kernel's fixed layer.
	if Dark.WallpaperTop != 0x1a1a2e || Dark.WallpaperBot != 0x0a0a14 {
		t.Fatalf("dark wallpaper %#x -> %#x", Dark.WallpaperTop, Dark.WallpaperBot)
	}
	if Light.WallpaperTop != 0xf1f5f9 || Light.WallpaperBot != 0xe2e8f0 {
		t.Fatalf("light wallpaper %#x -> %#x", Light.WallpaperTop, Light.WallpaperBot)
	}
}
