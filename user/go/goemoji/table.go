// Command goemoji is GOEMOJI.ELF (M146a, issue #2799): the emoji picker —
// a grid of the glyphs kernel/src/font_emoji.zig covers, fuzzy search by
// name, Enter to pick. A pick writes text/plain to the typed clipboard
// (vsys.ClipboardSetTyped) and closes or keeps the app per the in-app
// stay-open toggle (the settings vocabulary is a closed table — an
// app-level flag is the honest scope for "a setting"). A Compose tab lists
// the kernel's Alt+key+key pairs (drift-tested against
// kernel/src/input.zig) and a Kaomoji tab carries a fixed dozen.
package main

// Glyph is one covered emoji: the codepoint the kernel font resolves, the
// searchable names, and the SAME 16x16 monochrome art font_emoji.zig's
// comptime geometry produces (bit x of rows[y] = pixel column x).
type Glyph struct {
	CP      rune
	Name    string
	Aliases []string
	Rows    [16]uint16
}

// glyphs mirrors font_emoji.emojis — same codepoints, same order ("append
// only, never reorder"), same art. The Rows literals are the kernel's own
// comptime evaluation output (the geometry helpers in font_emoji.zig are
// not source-visible as data), extracted once; table_test.go re-derives
// the codepoint set from the Zig file so a kernel-side append or removal
// fails the class-A run until this table follows.
var glyphs = []Glyph{
	{CP: 0x1F600, Name: "smiling", Aliases: []string{"smile", "happy", "grinning face"},
		Rows: [16]uint16{0x0000, 0x0100, 0x0FE0, 0x1FF0, 0x3FF8, 0x73CC, 0x73CC, 0x7FFC, 0xFFFE, 0x7FFC, 0x7FFC, 0x73CC, 0x3818, 0x1FF0, 0x0FE0, 0x0100}},
	{CP: 0x1F606, Name: "grinning", Aliases: []string{"grin", "laugh", "smiley"},
		Rows: [16]uint16{0x0000, 0x0100, 0x0FE0, 0x1FF0, 0x3FF8, 0x73CC, 0x73CC, 0x7FFC, 0xFFFE, 0x7FFC, 0x781C, 0x781C, 0x3818, 0x1FF0, 0x0FE0, 0x0100}},
	{CP: 0x1F641, Name: "frowning", Aliases: []string{"frown", "sad", "unhappy"},
		Rows: [16]uint16{0x0000, 0x0100, 0x0FE0, 0x1FF0, 0x3FF8, 0x73CC, 0x73CC, 0x7FFC, 0xFFFE, 0x7FFC, 0x781C, 0x7FFC, 0x3FF8, 0x1FF0, 0x0FE0, 0x0100}},
	{CP: 0x1F621, Name: "angry", Aliases: []string{"mad", "pouting", "rage"},
		Rows: [16]uint16{0x0000, 0x0100, 0x0FE0, 0x1FF0, 0x2180, 0x73CC, 0x73CC, 0x7FFC, 0xFFFE, 0x7FFC, 0x7FFC, 0x781C, 0x3FF8, 0x1FF0, 0x0FE0, 0x0100}},
	{CP: 0x1F60E, Name: "sunglasses", Aliases: []string{"cool", "shades"},
		Rows: [16]uint16{0x0000, 0x0100, 0x0FE0, 0x1FF0, 0x3FF8, 0x7FFC, 0x6004, 0x6004, 0xFFFE, 0x7FFC, 0x7FFC, 0x7FFC, 0x3FF8, 0x1FF0, 0x0FE0, 0x0100}},
	{CP: 0x1F609, Name: "wink", Aliases: []string{"winking"},
		Rows: [16]uint16{0x0000, 0x0100, 0x0FE0, 0x1FF0, 0x3FF8, 0x7FCC, 0x61CC, 0x7FFC, 0xFFFE, 0x7FFC, 0x7FFC, 0x73CC, 0x3818, 0x1FF0, 0x0FE0, 0x0100}},
	{CP: 0x1F44D, Name: "thumbs up", Aliases: []string{"thumbsup", "+1", "like", "yes"},
		Rows: [16]uint16{0x0000, 0x0000, 0x01C0, 0x01C0, 0x01C0, 0x01C0, 0x07F0, 0x0FF8, 0x0FF8, 0x0FF8, 0x0FF8, 0x0FF8, 0x0FF8, 0x0FF8, 0x0000, 0x0000}},
	{CP: 0x1F44E, Name: "thumbs down", Aliases: []string{"thumbsdown", "-1", "dislike", "no"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0FF8, 0x0FF8, 0x0FF8, 0x0FF8, 0x0FF8, 0x0FF8, 0x0FF8, 0x07F0, 0x01C0, 0x01C0, 0x01C0, 0x01C0, 0x0000, 0x0000}},
	{CP: 0x1F44F, Name: "clap", Aliases: []string{"clapping", "applause"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0000, 0x0000, 0x0180, 0x3E7C, 0x3E7C, 0x3FFC, 0x3E7C, 0x3E7C, 0x3FFC, 0x3E7C, 0x3E7C, 0x0180, 0x0000, 0x0000}},
	{CP: 0x1F44B, Name: "wave", Aliases: []string{"waving", "hello", "hi", "bye"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0000, 0x01F8, 0x19F8, 0x01F8, 0x01F8, 0x01F8, 0x19F8, 0x01F8, 0x01F8, 0x01F8, 0x05F8, 0x01F8, 0x0000, 0x0000}},
	{CP: 0x2764, Name: "heart", Aliases: []string{"red heart", "love"},
		Rows: [16]uint16{0x0000, 0x0420, 0x1FF8, 0x3FFC, 0x3FFC, 0x7FFE, 0x3FFC, 0x3FFC, 0x1FF8, 0x0FF0, 0x07E0, 0x03C0, 0x0180, 0x0000, 0x0000, 0x0000}},
	{CP: 0x2B50, Name: "star", Aliases: []string{"favorite"},
		Rows: [16]uint16{0x0000, 0x0180, 0x0180, 0x0180, 0x07C0, 0x0FE0, 0x7FFE, 0x7FFE, 0x7FFE, 0x1FF8, 0x1FF8, 0x0FE0, 0x07C0, 0x0180, 0x0180, 0x0000}},
	{CP: 0x1F525, Name: "fire", Aliases: []string{"flame", "hot", "lit"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0000, 0x0180, 0x0180, 0x03C0, 0x03C0, 0x07E0, 0x07E0, 0x0EF0, 0x0C70, 0x1838, 0x1C78, 0x3EFC, 0x3FFC, 0x0000}},
	{CP: 0x1F680, Name: "rocket", Aliases: []string{"ship", "launch", "space"},
		Rows: [16]uint16{0x0000, 0x0180, 0x03C0, 0x07E0, 0x0FF0, 0x03C0, 0x03C0, 0x03C0, 0x03C0, 0x0FF0, 0x0FF0, 0x0C30, 0x0C30, 0x0180, 0x0000, 0x0000}},
	{CP: 0x1F4A1, Name: "light bulb", Aliases: []string{"bulb", "idea", "lightbulb"},
		Rows: [16]uint16{0x0000, 0x0100, 0x0FE0, 0x1FF0, 0x1FF0, 0x1FF0, 0x3FF8, 0x1FF0, 0x1FF0, 0x1FF0, 0x0FE0, 0x03C0, 0x03C0, 0x03C0, 0x0000, 0x0000}},
	{CP: 0x2714, Name: "check", Aliases: []string{"checkmark", "tick", "done"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0000, 0x0000, 0x0180, 0x0380, 0x0780, 0x0F00, 0x1E38, 0x1C78, 0x0070, 0x0060, 0x0040, 0x0000, 0x0000, 0x0000}},
	{CP: 0x2600, Name: "sun", Aliases: []string{"sunny"},
		Rows: [16]uint16{0x0180, 0x0180, 0x4004, 0x2008, 0x0100, 0x07C0, 0x0FE0, 0xCFE3, 0xDFF3, 0x0FE0, 0x0FE0, 0x07C0, 0x0100, 0x2008, 0x4184, 0x0180}},
	{CP: 0x1F319, Name: "moon", Aliases: []string{"crescent", "night"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0000, 0x0060, 0x0070, 0x0078, 0x0038, 0x0078, 0x007C, 0x0078, 0x00F8, 0x37F8, 0x1FF0, 0x0FE0, 0x0100, 0x0000}},
	{CP: 0x2601, Name: "cloud", Aliases: []string{"cloudy"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0000, 0x0100, 0x07C0, 0x0FE0, 0x0FE0, 0x3FF8, 0x3FF8, 0x7FFC, 0x3FF8, 0x3FF8, 0x1FF0, 0x0000, 0x0000, 0x0000}},
	{CP: 0x2744, Name: "snowflake", Aliases: []string{"snow", "cold", "winter"},
		Rows: [16]uint16{0x0180, 0x0180, 0x4184, 0x2188, 0x1190, 0x09A0, 0x05C0, 0xFFFF, 0xFFFF, 0x0380, 0x05C0, 0x09A0, 0x1190, 0x2188, 0x4184, 0x0180}},
	{CP: 0x1F355, Name: "pizza", Aliases: []string{"slice", "food"},
		Rows: [16]uint16{0x0000, 0x0000, 0x1FF8, 0x0000, 0x0000, 0x0100, 0x0180, 0x01C0, 0x03C0, 0x06E0, 0x0460, 0x0EF0, 0x0FF0, 0x1FF8, 0x0000, 0x0000}},
	{CP: 0x2615, Name: "coffee", Aliases: []string{"tea", "cup", "hot beverage"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0120, 0x0000, 0x0120, 0x0000, 0x0FF8, 0x2FF8, 0x27F8, 0x67F8, 0x27F8, 0x2FF8, 0x0FF8, 0x0000, 0x0000, 0x0000}},
	{CP: 0x1F3B5, Name: "music note", Aliases: []string{"musical", "note", "song"},
		Rows: [16]uint16{0x0000, 0x0000, 0x0000, 0x3F00, 0x2F00, 0x3F00, 0x0300, 0x0300, 0x0300, 0x0340, 0x03F0, 0x03F0, 0x03F8, 0x01F0, 0x01F0, 0x0040}},
	{CP: 0x26A0, Name: "warning", Aliases: []string{"caution", "alert"},
		Rows: [16]uint16{0x0000, 0x0000, 0xFFFF, 0x0180, 0x0180, 0x03C0, 0x03C0, 0x05A0, 0x0990, 0x0990, 0x1008, 0x1188, 0x2004, 0x4002, 0x0000, 0x0000}},
}

// lookup resolves a codepoint to its table index, mirroring
// font_emoji.zig's linear lookup over the same order.
func lookup(cp rune) int {
	for i := range glyphs {
		if glyphs[i].CP == cp {
			return i
		}
	}
	return -1
}

// kaomoji is the fixed dozen. Every rune is covered by the image's font
// registry (kaomoji_test.go pins that against image/fonts), so the Kaomoji
// tab's chain paint never shows a .notdef for the app's own strings.
type Kaomoji struct {
	Name string
	Text string
}

var kaomoji = []Kaomoji{
	{Name: "shrug", Text: `¯\_(ツ)_/¯`},
	{Name: "table flip", Text: `(╯°□°)╯ ┻━┻`},
	{Name: "deal with it", Text: `(¬■_■)`},
	{Name: "bear", Text: `ʕ•ᴥ•ʔ`},
	{Name: "hug", Text: `(づ｡⊙‿‿⊙｡)づ`},
	{Name: "wink", Text: `(¬‿¬)`},
	{Name: "point", Text: `(☞ﾟヮﾟ)☞`},
	{Name: "smile", Text: `(⊙‿⊙)`},
	{Name: "joy", Text: `(ᵔᴥᵔ)`},
	{Name: "lenny", Text: `( ͡° ͜ʖ ͡°)`},
	{Name: "shades", Text: `┌(■Ĺ■)┐`},
	{Name: "wave", Text: `(ノ°∀°)ノ`},
}

// Compose is one kernel compose pair: Alt + first key + second key yields
// the codepoint (the input.zig ComposePair shape, HID usages verbatim).
type Compose struct {
	First  uint8
	Second uint8
	CP     rune
}

// compose mirrors input.zig's compose_table, in the kernel's order.
// compose_test.go re-derives the triples from kernel/src/input.zig, so a
// kernel-side edit fails the class-A run until this list follows.
var compose = []Compose{
	{First: 0x08, Second: 0x04, CP: 0x00e1}, // Alt+e a → á
	{First: 0x08, Second: 0x05, CP: 0x00e9}, // Alt+e e → é
	{First: 0x08, Second: 0x0c, CP: 0x00ed}, // Alt+e i → í
	{First: 0x08, Second: 0x12, CP: 0x00f3}, // Alt+e o → ó
	{First: 0x08, Second: 0x18, CP: 0x00fa}, // Alt+e u → ú
	{First: 0x18, Second: 0x04, CP: 0x00e4}, // Alt+u a → ä
	{First: 0x18, Second: 0x05, CP: 0x00eb}, // Alt+u e → ë
	{First: 0x18, Second: 0x0c, CP: 0x00ef}, // Alt+u i → ï
	{First: 0x18, Second: 0x12, CP: 0x00f6}, // Alt+u o → ö
	{First: 0x18, Second: 0x18, CP: 0x00fc}, // Alt+u u → ü
	{First: 0x35, Second: 0x04, CP: 0x00e0}, // Alt+` a → à
	{First: 0x35, Second: 0x05, CP: 0x00e8}, // Alt+` e → è
	{First: 0x35, Second: 0x0c, CP: 0x00ec}, // Alt+` i → ì
	{First: 0x35, Second: 0x12, CP: 0x00f2}, // Alt+` o → ò
	{First: 0x35, Second: 0x18, CP: 0x00f9}, // Alt+` u → ù
	{First: 0x11, Second: 0x11, CP: 0x00f1}, // Alt+n n → ñ
	{First: 0x06, Second: 0x06, CP: 0x00e7}, // Alt+c c → ç
}

// hidKey maps a HID usage to the keycap letter the Compose tab shows. It
// covers exactly the usages compose_table reaches (letters a..z at usages
// 0x04..0x1d, the grave key at 0x35) — the kernel's own display path
// resolves the same usages through hid_to_ascii.
func hidKey(usage uint8) (byte, bool) {
	switch {
	case usage >= 0x04 && usage <= 0x1d:
		return 'a' + usage - 0x04, true
	case usage == 0x35:
		return '`', true
	}
	return 0, false
}
