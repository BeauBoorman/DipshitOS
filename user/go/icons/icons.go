// Package icons names the thirty M86a/M104g chrome glyphs in Virelai Chrome.
// The companion font keeps this PUA range separate from Virelai Sans, whose
// U+E001 is already the sexiburger mark. See docs/ui-primitives.md §4.
package icons

const (
	FontFile  = "VirelaiChrome-Regular.ttf"
	DesignEm  = 16
	SmallPx   = 12
	NominalPx = 16
	LargePx   = 20
)

type Glyph struct {
	Codepoint rune
	Name      string
}

// Inventory is in codepoint order. No unused or extra slots are allocated.
var Inventory = [...]Glyph{
	{0xE000, "window-close"},
	{0xE001, "window-minimize"},
	{0xE002, "window-maximize"},
	{0xE003, "window-restore"},
	{0xE004, "window-pin"},
	{0xE005, "window-unpin"},
	{0xE006, "chevron-left"},
	{0xE007, "chevron-right"},
	{0xE008, "chevron-up"},
	{0xE009, "chevron-down"},
	{0xE00A, "check"},
	{0xE00B, "plus"},
	{0xE00C, "search"},
	{0xE00D, "settings-gear"},
	{0xE00E, "folder"},
	{0xE00F, "file"},
	{0xE010, "warning-triangle"},
	{0xE011, "error-circle"},
	{0xE012, "info-circle"},
	{0xE013, "lock"},
	{0xE014, "menu"},
	{0xE015, "kebab"},
	{0xE016, "media-play"},
	{0xE017, "media-pause"},
	{0xE018, "media-stop"},
	{0xE019, "bell"},
	{0xE01A, "bell-dnd"},
	{0xE01B, "volume"},
	{0xE01C, "volume-mute"},
	{0xE01D, "resize-grip"},
}

func Name(codepoint rune) (string, bool) {
	if codepoint < 0xE000 || codepoint > 0xE01D {
		return "", false
	}
	return Inventory[codepoint-0xE000].Name, true
}

func Codepoint(name string) (rune, bool) {
	for _, glyph := range Inventory {
		if glyph.Name == name {
			return glyph.Codepoint, true
		}
	}
	return 0, false
}
