// Package theme is the M69c (#1530) Go token table. Shipping Go widgets
// and chrome import this instead of scattering hex. Values for dark match
// user/src/lib/ui/theme.zig THEME_DARK (bg/surface/border/accent/buttons)
// and CHROME_DARK caret/on-accent; light matches THEME_LIGHT. Tokens are
// data, not a framework: no animation, no layout engine. Zig theme.zig stays.
package theme

// Tokens is one complete palette plus the spacing/border scale. Padding
// and border contrast come from here, never from a one-off hex in an app.
type Tokens struct {
	Bg, Surface, Border           uint32
	Text, Muted, Accent           uint32
	BtnIdle, BtnHover, BtnPressed uint32
	Success, Danger, Warning      uint32
	OnAccent                      uint32
	Caret, Selection, Gutter      uint32
	// Ink / ChromeBg / Rule / Ok are the Go chrome extras NOTE and WEB
	// already painted. They live on the table so those apps import one
	// package rather than keep a parallel hex list.
	Ink, ChromeBg, Rule, Ok    uint32
	InkMuted                   uint32
	PadXS, PadSM, PadMD, PadLG int
	BorderW, FocusW            int
	// M104a (contract v2, #2268): the depth roles. Shadow is the
	// drop-shadow ink — the caller supplies the falloff alpha (the
	// contract pins 0x40 peak at dy=4/blur=16). WallpaperTop/WallpaperBot
	// are the seat desktop gradient endpoints, matching the kernel's
	// wallpaper_top/wallpaper_bot (driving_award.zig) so a Go-seat
	// desktop and the kernel's fixed layer read identically. Go-only:
	// no Zig table carries these, so the byte-parity tests pin nothing
	// here.
	Shadow                     uint32
	WallpaperTop, WallpaperBot uint32
}

// Dark is the boot-default palette. Hexes are byte-identical to Zig
// THEME_DARK / CHROME_DARK for bg, surface, border, text, muted, accent,
// buttons, danger, caret, on-accent.
var Dark = Tokens{
	Bg:           0x182026,
	Surface:      0x222d35,
	Border:       0x334155,
	Text:         0xffffff,
	Muted:        0x94a3b8,
	Accent:       0x3b82f6,
	BtnIdle:      0x2d3748,
	BtnHover:     0x4a5568,
	BtnPressed:   0x1a202c,
	Success:      0x22c55e,
	Danger:       0xef4444,
	Warning:      0xf59e0b,
	OnAccent:     0xffffff,
	Caret:        0x3b82f6,
	Selection:    0x2a4460,
	Gutter:       0x0b0e11,
	Ink:          0xe6edf3,
	InkMuted:     0x8b98a5,
	ChromeBg:     0x11171c,
	Rule:         0x2e3a44,
	Ok:           0x3fb950,
	PadXS:        2,
	PadSM:        4,
	PadMD:        8,
	PadLG:        16,
	BorderW:      1,
	FocusW:       2,
	Shadow:       0x000000,
	WallpaperTop: 0x1a1a2e,
	WallpaperBot: 0x0a0a14,
}

// Light matches Zig THEME_LIGHT / CHROME_LIGHT. Applied when a Go client
// reads schema-v2 `theme=light` from SETTINGS.TXT. No amber: no Go reader
// of `theme=amber` exists yet (#1530 D3-adjacent).
var Light = Tokens{
	Bg:           0xf1f5f9,
	Surface:      0xffffff,
	Border:       0xcbd5e1,
	Text:         0x0f172a,
	Muted:        0x64748b,
	Accent:       0x2563eb,
	BtnIdle:      0xe2e8f0,
	BtnHover:     0xcbd5e1,
	BtnPressed:   0x94a3b8,
	Success:      0x16a34a,
	Danger:       0xdc2626,
	Warning:      0xd97706,
	OnAccent:     0xffffff,
	Caret:        0x2563eb,
	Selection:    0xbfdbfe,
	Gutter:       0xe5e7eb,
	Ink:          0x0f172a,
	InkMuted:     0x64748b,
	ChromeBg:     0xe2e8f0,
	Rule:         0xcbd5e1,
	Ok:           0x16a34a,
	PadXS:        2,
	PadSM:        4,
	PadMD:        8,
	PadLG:        16,
	BorderW:      1,
	FocusW:       2,
	Shadow:       0x0f172a,
	WallpaperTop: 0xf1f5f9,
	WallpaperBot: 0xe2e8f0,
}

// DarkHC is the M165b (#2983) high-contrast variant of Dark, selected when
// a11y.contrast=high: ink/background contrast of at least 7:1 (computed in
// the test — white on black is 21:1), wider focus and border strokes, and
// muted/semantic tones pushed far enough apart to stay legible on black.
var DarkHC = Tokens{
	Bg:           0x000000,
	Surface:      0x0d1117,
	Border:       0x8b949e,
	Text:         0xffffff,
	Muted:        0xb1bac4,
	Accent:       0x58a6ff,
	BtnIdle:      0x1c2128,
	BtnHover:     0x30363d,
	BtnPressed:   0x000000,
	Success:      0x3fb950,
	Danger:       0xff7b72,
	Warning:      0xd29922,
	OnAccent:     0xffffff,
	Caret:        0x58a6ff,
	Selection:    0x1f3a5f,
	Gutter:       0x000000,
	Ink:          0xffffff,
	InkMuted:     0xb1bac4,
	ChromeBg:     0x000000,
	Rule:         0x30363d,
	Ok:           0x3fb950,
	PadXS:        2,
	PadSM:        4,
	PadMD:        8,
	PadLG:        16,
	BorderW:      2,
	FocusW:       4,
	Shadow:       0x000000,
	WallpaperTop: 0x0a0a14,
	WallpaperBot: 0x000000,
}

// LightHC is the high-contrast variant of Light — the same 7:1 floor
// (black on white is 21:1) and the same widened strokes.
var LightHC = Tokens{
	Bg:           0xffffff,
	Surface:      0xf6f8fa,
	Border:       0x24292f,
	Text:         0x000000,
	Muted:        0x3d444d,
	Accent:       0x0550ae,
	BtnIdle:      0xe8ebf0,
	BtnHover:     0xd0d7de,
	BtnPressed:   0x8c959f,
	Success:      0x116329,
	Danger:       0xa40e26,
	Warning:      0x744500,
	OnAccent:     0xffffff,
	Caret:        0x0550ae,
	Selection:    0xadd6ff,
	Gutter:       0xe8ebf0,
	Ink:          0x000000,
	InkMuted:     0x3d444d,
	ChromeBg:     0xffffff,
	Rule:         0x24292f,
	Ok:           0x116329,
	PadXS:        2,
	PadSM:        4,
	PadMD:        8,
	PadLG:        16,
	BorderW:      2,
	FocusW:       4,
	Shadow:       0x0f172a,
	WallpaperTop: 0xffffff,
	WallpaperBot: 0xe8ebf0,
}

// Current is the active table. Boot default is Dark.
var Current = Dark

// The active table is the composition of two independent settings reads:
// the `theme=` base (dark|light) and the `a11y.contrast` switch (off|high,
// M165b #2983). They are separate state precisely so changing one cannot
// clobber the other — `theme=light` while contrast is high must select the
// high-contrast light table, not silently drop the a11y switch.
var (
	baseName     = "dark"
	contrastHigh = false
)

func resolve() {
	base := Dark
	if baseName == "light" {
		base = Light
	}
	if !contrastHigh {
		Current = base
		return
	}
	if baseName == "light" {
		Current = LightHC
	} else {
		Current = DarkHC
	}
}

// Name is "dark" or "light" for the active table's BASE — the `theme=`
// value in force. Contrast is reported separately (Contrast); a
// high-contrast table still names its base.
func Name() string {
	return baseName
}

// Contrast is "off" or "high" for the active table — the a11y.contrast
// value in force.
func Contrast() string {
	if contrastHigh {
		return "high"
	}
	return "off"
}

// Set selects dark or light by the schema-v2 `theme=` value. Unknown names
// are refused so a typo cannot silently invent a third palette.
func Set(name string) bool {
	switch name {
	case "dark", "light":
		baseName = name
		resolve()
		return true
	default:
		return false
	}
}

// SetContrast applies the a11y.contrast switch: high selects the
// high-contrast variant of the current base, off selects the plain table.
func SetContrast(high bool) {
	contrastHigh = high
	resolve()
}

// ParseSettings returns the last `theme=dark|light` value in a SETTINGS.TXT
// body, or "" when none is present. Amber is ignored (no Go reader).
func ParseSettings(buf []byte) string {
	i := 0
	found := ""
	for i < len(buf) {
		eol := i
		for eol < len(buf) && buf[eol] != '\n' {
			eol++
		}
		line := buf[i:eol]
		if len(line) > 6 && string(line[:6]) == "theme=" {
			val := string(line[6:])
			if len(val) > 0 && val[len(val)-1] == '\r' {
				val = val[:len(val)-1]
			}
			if val == "dark" || val == "light" {
				found = val
			}
		}
		if eol < len(buf) {
			i = eol + 1
		} else {
			break
		}
	}
	return found
}

// ParseContrast returns the last `a11y.contrast=off|high` value in a
// SETTINGS.TXT body, or "" when none is present (M165b #2983).
func ParseContrast(buf []byte) string {
	i := 0
	found := ""
	for i < len(buf) {
		eol := i
		for eol < len(buf) && buf[eol] != '\n' {
			eol++
		}
		line := buf[i:eol]
		if len(line) > 14 && string(line[:14]) == "a11y.contrast=" {
			val := string(line[14:])
			if len(val) > 0 && val[len(val)-1] == '\r' {
				val = val[:len(val)-1]
			}
			if val == "off" || val == "high" {
				found = val
			}
		}
		if eol < len(buf) {
			i = eol + 1
		} else {
			break
		}
	}
	return found
}

// ApplySettings sets Current from a SETTINGS.TXT body: the `theme=` base
// AND the `a11y.contrast` switch (M165b #2983), composed so each survives
// the other. Missing/unknown is a no-op (Dark stays the boot default).
func ApplySettings(buf []byte) bool {
	applied := false
	if name := ParseSettings(buf); name != "" {
		applied = Set(name)
	}
	switch ParseContrast(buf) {
	case "high":
		SetContrast(true)
		applied = true
	case "off":
		SetContrast(false)
		applied = true
	}
	return applied
}

// Hex6 formats v as 0xRRGGBB (six digits, no alpha). Guest-safe: no fmt.
func Hex6(v uint32) string {
	const digits = "0123456789abcdef"
	var b [8]byte
	b[0], b[1] = '0', 'x'
	for i := 7; i >= 2; i-- {
		b[i] = digits[v&0xf]
		v >>= 4
	}
	return string(b[:])
}
