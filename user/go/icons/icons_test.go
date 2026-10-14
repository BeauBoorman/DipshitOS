package icons

import "testing"

func TestContractInventory(t *testing.T) {
	want := [...]Glyph{
		{0xE000, "window-close"}, {0xE001, "window-minimize"},
		{0xE002, "window-maximize"}, {0xE003, "window-restore"},
		{0xE004, "window-pin"}, {0xE005, "window-unpin"},
		{0xE006, "chevron-left"}, {0xE007, "chevron-right"},
		{0xE008, "chevron-up"}, {0xE009, "chevron-down"},
		{0xE00A, "check"}, {0xE00B, "plus"},
		{0xE00C, "search"}, {0xE00D, "settings-gear"},
		{0xE00E, "folder"}, {0xE00F, "file"},
		{0xE010, "warning-triangle"}, {0xE011, "error-circle"},
		{0xE012, "info-circle"}, {0xE013, "lock"},
		{0xE014, "menu"}, {0xE015, "kebab"},
		{0xE016, "media-play"}, {0xE017, "media-pause"},
		{0xE018, "media-stop"}, {0xE019, "bell"},
		{0xE01A, "bell-dnd"}, {0xE01B, "volume"},
		{0xE01C, "volume-mute"}, {0xE01D, "resize-grip"},
	}
	if Inventory != want {
		t.Fatalf("chrome inventory drifted from docs/ui-primitives.md §4:\ngot  %v\nwant %v", Inventory, want)
	}
	if DesignEm != 16 || SmallPx != 12 || NominalPx != 16 || LargePx != 20 {
		t.Fatal("chrome size ladder drifted from docs/ui-primitives.md §4")
	}
	for _, glyph := range want {
		if name, ok := Name(glyph.Codepoint); !ok || name != glyph.Name {
			t.Errorf("Name(%U) = %q, %v", glyph.Codepoint, name, ok)
		}
		if cp, ok := Codepoint(glyph.Name); !ok || cp != glyph.Codepoint {
			t.Errorf("Codepoint(%q) = %U, %v", glyph.Name, cp, ok)
		}
	}
	for _, cp := range []rune{0, 0xDFFF, 0xE01E, 0xF000} {
		if _, ok := Name(cp); ok {
			t.Errorf("Name(%U) unexpectedly exists", cp)
		}
	}
	if _, ok := Codepoint("other"); ok {
		t.Error("unknown name unexpectedly exists")
	}
}
