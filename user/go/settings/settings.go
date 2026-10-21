// Package settings is the schema-v2 SETTINGS.TXT codec, shared by the Go seat
// (GOTABWM.ELF) and the Go settings panel (GOSET.ELF).
//
// M66b (#1444) wrote this decode inside the seat, as the corrupt-fails-closed
// twin of the kernel's own loader (kernel/src/settings.zig): the same key=value
// grammar, the same `#v<digits>` header gate, the same verdict on a bad file.
// M71f (#1565) moves it here — one codec, two consumers — because the panel has
// to read and WRITE the same file the seat decoded. The seat keeps its
// seat-level markers (gotabwm: settings wm= / settings bad); the panel owns the
// user-facing edit and publishes crash-safe through vi.WriteFileSafe (temp +
// fsync + delete/rename), the same publish the kernel's `settings set` uses, so
// a panel save can never leave a partial file behind.
//
// KnownKeys mirrors the kernel's seeded table (kernel/src/settings.zig). It is
// a MIRROR, not a second schema: the panel offers every key the kernel seeds,
// plus its explicitly accepted-unseeded palette/font/layout/idle rows. The mirror
// is pinned against the kernel source by a host test, so a key added there and
// not here is a failing test rather than a silent drift.
//
// M73m (#1662) grows the surface WITHOUT touching this table: the three
// custom-palette keys below are accepted keys the kernel does not seed (the
// `color`/`font_size`/`keyboard_layout` pattern), so a default settings table
// — and the SETTINGS.TXT a fresh share carries — stays byte-identical to the
// pre-M73m image. GOSET's display row count can grow without materializing
// these optional values in the file.
package settings

import (
	"strings"

	"virelai/clockfmt"
	"virelai/layout"
	"virelai/vi"
)

const (
	// Path is the file both consumers read. The kernel owns writing it; the
	// panel writes it too, through the same crash-safe publish.
	Path = "/host/SETTINGS.TXT"
	// Caps mirror the kernel's table (max_entries / max_key_len / max_val_len)
	// and its bounded load buffer. M99d (#2182) raised the cap 18 -> 20: the
	// Go-side union (nine seeded + palette 3 + font_size + keyboard_layout +
	// idle_minutes + notify_dnd + timezone + notify_sound + audio_volume) is
	// 19 rows, and the table must hold a file that carries all of them with
	// one slot to spare rather than silently dropping the last row at load.
	// M100f (#2311) added data_root, and M165b (#2983) adds the three a11y.*
	// rows, so the cap moved 20 -> 24: the Go union is 23 rows, the kernel's
	// own accepted term_restart makes the full known union 24, and the row
	// past the cap is the one that drops. MaxBody stays 2048 — a file
	// carrying every known row is a few hundred bytes, pinned by test.
	MaxKeys = 24
	MaxKey  = 32
	MaxVal  = 64
	MaxBody = 2048

	// SaveRefused is Save's return when the decode was corrupt: no file was
	// written. The two negative sentinels are not kernel error codes.
	SaveRefused int64 = -4097
	// SaveFull refuses a panel table that the kernel cannot load intact.
	SaveFull int64 = -4098
)

// State is the decode verdict for the file.
const (
	// StateMissing is a first boot, or the pre-seed default flow. The compiled
	// defaults are in force; saving is allowed (that is how a fresh share gets
	// a settings file at all).
	StateMissing = iota
	// StateOK is a schema-v2 file this package understands.
	StateOK
	// StateCorrupt is a file the kernel refused whole (no valid header, a newer
	// schema, or an oversized body). Every write is refused: a corrupt file is
	// never laundered into a half-parsed one.
	StateCorrupt
)

// Setting is one key=value row of the schema-v2 file.
type Setting struct {
	Key string
	Val string
}

// File is a decoded settings file plus its verdict.
type File struct {
	Rows  []Setting
	State int
}

// Key is one row of the kernel's compiled table: the value in force when the
// file carries no such key, and the vocabulary the panel may cycle through
// (nil = free text, the kernel's own value space is open for that key).
type Key struct {
	Name    string
	Default string
	Vocab   []string
}

// KnownKeys mirrors kernel/src/settings.zig init(): the keys the kernel
// seeds before it loads the file. Order is the kernel's, so a diff against the
// kernel source reads straight down.
var KnownKeys = []Key{
	{Name: "hostname", Default: "virelai"},
	{Name: "prompt", Default: "virelai> "},
	{Name: "theme", Default: "dark", Vocab: []string{"dark", "light", "amber", "custom"}},
	{Name: "scrollback", Default: "1000"},
	{Name: "shadow", Default: "off", Vocab: []string{"on", "off"}},
	{Name: "focus_follows_mouse", Default: "off", Vocab: []string{"on", "off"}},
	{Name: "shell", Default: "monitor", Vocab: []string{"monitor", "sh"}},
	{Name: "wm", Default: "gotabwm", Vocab: []string{"gotabwm", "tabwm", "none"}},
	{Name: "init", Default: "on", Vocab: []string{"on", "off"}},
}

// PaletteKeys are the M73m (#1662) custom-palette rows: the colours
// `theme=custom` resolves to at paint time (the kernel's palette_fg /
// palette_bg / palette_accent). They are NOT KnownKeys — the kernel does not
// seed them either — so the mirror table above stays exactly the kernel's,
// and a default panel stays at the kernel rows plus the layout/idle rows. The
// panel reveals them as rows the moment `custom` is chosen and accepts them
// as typed input at any time.
// Defaults mirror kernel/src/settings.zig *_default (pinned by host test).
var PaletteKeys = []Key{
	{Name: "palette_fg", Default: "00ff00"},
	{Name: "palette_bg", Default: "101418"},
	{Name: "palette_accent", Default: "3b82f6"},
}

// FontKeys is the M80i (#1725) accepted-not-seeded font_size row: one
// key, two ladders (the framebuffer text layer 8x8/16x16/24x24 and the
// terminal GRID's 7x13/8x16/10x21 — the kernel's apply_font_size drives
// both). Not KnownKeys, for the same reason as the palette rows: the
// kernel does not seed it either, so a default panel stays at eight kernel
// rows plus keyboard_layout/idle_minutes and a fresh share's SETTINGS.TXT stays
// byte-identical. The panel
// accepts it as typed input at any time and cycles it (small -> medium
// -> large) once the row exists; it never fabricates the row, because an
// ABSENT key is the boot look (text small + grid medium) — which no
// single stored value can represent. Default is the grid's boot cell
// only for readers asking what an absent row sizes to (the mirror is
// vi.TerminalCellForSize, pinned against kernel/src/font_atlas_data.zig).
var FontKeys = []Key{
	{Name: "font_size", Default: "medium", Vocab: []string{"small", "medium", "large"}},
}

// KeyboardLayoutKeys are the M83d2 layout selector. The kernel uses US when
// the key is absent, so this remains accepted-but-unseeded there; GOSET still
// surfaces the row with that effective default so the choice is discoverable.
var KeyboardLayoutKeys = []Key{
	{Name: "keyboard_layout", Default: string(layout.US), Vocab: layout.Values()},
}

// IdleKeys is the seat's accepted-but-unseeded idle policy. An absent row
// leaves the kernel's eight-row table unchanged; GOSET still shows the
// effective five-minute default. The seat alone interprets the value.
var IdleKeys = []Key{
	{Name: "idle_minutes", Default: "5"},
}

// IdleMinutes accepts whole minutes from 1 to 120. Invalid persisted values
// cannot make the seat dim immediately or turn the curtain into a security
// boundary; the seat uses the compiled default instead.
func IdleMinutes(value string) (uint64, bool) {
	if value == "" || len(value) > 3 {
		return 0, false
	}
	var minutes uint64
	for i := 0; i < len(value); i++ {
		if value[i] < '0' || value[i] > '9' {
			return 0, false
		}
		minutes = minutes*10 + uint64(value[i]-'0')
	}
	return minutes, minutes >= 1 && minutes <= 120
}

func IsIdleMinutesKey(key string) bool { return key == "idle_minutes" }

// NotifyKeys is the M82d2 (#1785) do-not-disturb policy row. Like the idle
// row it is accepted-but-unseeded: the kernel's eight-row table stays exactly
// as it was, an absent row means "off", and GOSET still surfaces the
// effective default so the toggle is discoverable. The seat alone interprets
// it: `on` keeps a new notice out of the toast strip and lets it go straight
// to the history the notifications center holds.
var NotifyKeys = []Key{
	{Name: "notify_dnd", Default: "off", Vocab: []string{"on", "off"}},
}

// NotifyDNDKey is the do-not-disturb key's name, for the seat's own writes.
const NotifyDNDKey = "notify_dnd"

// NotifyDND parses a stored do-not-disturb value. ok is false for anything
// but exactly `on` or `off`: a mistyped value must never silence the user's
// notifications by accident, so the caller treats it as the default (off).
func NotifyDND(value string) (on, ok bool) {
	switch value {
	case "on":
		return true, true
	case "off":
		return false, true
	}
	return false, false
}

// IsNotifyDNDKey reports whether key is the do-not-disturb row.
func IsNotifyDNDKey(key string) bool { return key == NotifyDNDKey }

// NotifySoundKeys is the M99d (#2182) notification-chime row: like font_size
// it is accepted-but-unseeded AND not a default panel row — the kernel's
// table stays unchanged, an absent row means the chime is on (the default),
// and the row materializes in GOSET once it is set, after which it cycles
// on|off like every vocabulary row. The seat alone interprets it: `off`
// keeps an accepted toast silent.
var NotifySoundKeys = []Key{
	{Name: "notify_sound", Default: "on", Vocab: []string{"on", "off"}},
}

// NotifySoundKey is the notification-chime key's name.
const NotifySoundKey = "notify_sound"

// NotifySound parses a stored notify_sound value, the same on|off grammar
// as notify_dnd. ok is false for anything else, and the caller treats that
// as the default (on) so a mistyped value can never silence the user's
// notification sound by accident.
func NotifySound(value string) (on, ok bool) {
	switch value {
	case "on":
		return true, true
	case "off":
		return false, true
	}
	return false, false
}

// IsNotifySoundKey reports whether key is the notification-chime row.
func IsNotifySoundKey(key string) bool { return key == NotifySoundKey }

// VolumeKeys is the M99d (#2182) audio-volume row: the stream gain behind
// slot 44 (0..100, kernel state that resets to 100 at boot). Accepted-
// but-unseeded and not a default panel row, like font_size: the row is
// typed input (`audio_volume=40`), persists once set, and cycles its
// vocabulary afterwards. The kernel never interprets the row — slot 44 is
// applied by the row's consumers (GOSET's edit, the seat's boot read).
var VolumeKeys = []Key{
	{Name: "audio_volume", Default: "100", Vocab: []string{"0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"}},
}

// AudioVolumeKey is the stream-gain key's name.
const AudioVolumeKey = "audio_volume"

// AudioVolume parses a stored volume value: whole numbers 0..100, the same
// bound slot 44 enforces. ok is false for anything else — out-of-range is
// the kernel's refusal, never a silent clamp.
func AudioVolume(value string) (int, bool) {
	if value == "" || len(value) > 3 {
		return 0, false
	}
	v := 0
	for i := 0; i < len(value); i++ {
		if value[i] < '0' || value[i] > '9' {
			return 0, false
		}
		v = v*10 + int(value[i]-'0')
	}
	return v, v <= 100
}

// IsVolumeKey reports whether key is the audio-volume row.
func IsVolumeKey(key string) bool { return key == AudioVolumeKey }

// TimezoneKeys is the M83c (#1776) timezone row: accepted-but-unseeded like
// the idle row — the kernel's eight-row table stays exactly as it was, an
// absent row means UTC, and GOSET still surfaces the effective default so
// the choice is discoverable. The vocabulary is clockfmt's curated
// fixed-offset list; DST rules are named risk, not scope.
var TimezoneKeys = []Key{
	{Name: "timezone", Default: "UTC", Vocab: clockfmt.Names()},
}

// TimezoneKey is the timezone key's name, for the shared formatter's callers.
const TimezoneKey = "timezone"

// IsTimezoneKey reports whether key is the M83c timezone row.
func IsTimezoneKey(key string) bool { return key == TimezoneKey }

// DataRootKeys is the M100f (#2311) data-root row: accepted-but-unseeded AND
// not a default panel row, like notify_sound — the kernel's table stays
// unchanged, an absent row means the host share, and the row materializes
// in GOSET once it is set, after which it cycles host|disk like every
// vocabulary row. (Display-materializing it would write data_root=host into
// every GOSET save — a byte change to default SETTINGS.TXT the opt-in does
// not need.) The kernel never interprets the row: the movable data set
// (GOSH history, the notify history, the fetch download default) resolves
// through File.ResolveDataRoot, and SETTINGS.TXT itself always stays on
// /host — it is the pointer, not the payload.
var DataRootKeys = []Key{
	{Name: "data_root", Default: "host", Vocab: []string{"host", "disk"}},
}

// DataRootKey is the data-root key's name, for the movable set's readers.
const DataRootKey = "data_root"

// IsDataRootKey reports whether key is the M100f data-root row.
func IsDataRootKey(key string) bool {
	return key == DataRootKey
}

// ValidDataRoot reports whether the value names a real data root. The
// resolver treats anything but an exact `disk` as the host default anyway,
// so a refused value here is one a save would write and a boot would read
// as `host` — the panel names it instead of persisting a silent lie.
func ValidDataRoot(value string) bool {
	return value == "host" || value == "disk"
}

// A11yKeys is the M165b (#2983) accessibility trio: accepted-but-unseeded
// AND not default panel rows, like notify_sound — the kernel's table
// stays unchanged, an absent row means the compiled default, and each row
// materializes in the file once set. They are GOSET's access tab, not the
// settings list: a11y.contrast is honoured by every theme.ApplySettings
// caller, a11y.reduce_motion by the seat's toast ramp, and a11y.text_scale
// is reserved — reserved and named, honoured by no app yet.
var A11yKeys = []Key{
	{Name: "a11y.contrast", Default: "off", Vocab: []string{"off", "high"}},
	{Name: "a11y.reduce_motion", Default: "off", Vocab: []string{"off", "on"}},
	{Name: "a11y.text_scale", Default: "100", Vocab: []string{"100", "125", "150"}},
}

// The three key names, for the seat's reads and the panel's dispatch.
const (
	A11yContrastKey     = "a11y.contrast"
	A11yReduceMotionKey = "a11y.reduce_motion"
	A11yTextScaleKey    = "a11y.text_scale"
)

// IsA11yContrastKey reports whether key is the high-contrast row.
func IsA11yContrastKey(key string) bool { return key == A11yContrastKey }

// IsA11yReduceMotionKey reports whether key is the reduced-motion row.
func IsA11yReduceMotionKey(key string) bool { return key == A11yReduceMotionKey }

// IsA11yTextScaleKey reports whether key is the reserved text-scale row.
func IsA11yTextScaleKey(key string) bool { return key == A11yTextScaleKey }

// IsA11yKey reports whether key is one of the three a11y.* rows.
func IsA11yKey(key string) bool {
	return IsA11yContrastKey(key) || IsA11yReduceMotionKey(key) || IsA11yTextScaleKey(key)
}

// A11yContrast parses a stored contrast value: ok is false for anything
// but exactly `off` or `high` — a mistyped value must never paint a user
// into a palette they did not ask for, so the caller treats it as off.
func A11yContrast(value string) (high, ok bool) {
	switch value {
	case "high":
		return true, true
	case "off":
		return false, true
	}
	return false, false
}

// A11yReduceMotion parses a stored reduce-motion value, the same on|off
// grammar as notify_dnd. ok is false for anything else — a mistyped value
// reads as the default (off), never a silent mode change.
func A11yReduceMotion(value string) (on, ok bool) {
	switch value {
	case "on":
		return true, true
	case "off":
		return false, true
	}
	return false, false
}

// A11yTextScale parses a stored text-scale value: exactly one of the three
// reserved rungs. ok is false for anything else.
func A11yTextScale(value string) (int, bool) {
	switch value {
	case "100":
		return 100, true
	case "125":
		return 125, true
	case "150":
		return 150, true
	}
	return 0, false
}

// ValidA11y reports whether value is in the row's declared vocabulary — the
// panel's typed-input gate, refused before it reaches the file for the same
// reason every vocabulary row is refused there.
func ValidA11y(key, value string) bool {
	switch {
	case IsA11yContrastKey(key):
		_, ok := A11yContrast(value)
		return ok
	case IsA11yReduceMotionKey(key):
		_, ok := A11yReduceMotion(value)
		return ok
	case IsA11yTextScaleKey(key):
		_, ok := A11yTextScale(value)
		return ok
	}
	return false
}

// ValidTimezone reports whether the value names a fixed offset clockfmt
// parses.
func ValidTimezone(value string) bool {
	_, ok := clockfmt.Parse(value)
	return ok
}

// Timezone resolves the zone in force: the file's row when it parses, UTC
// otherwise. An invalid persisted value must never shift every clock
// silently, so the fallback is the same default an absent row carries.
func (f File) Timezone() clockfmt.Zone {
	v, ok := f.Effective(TimezoneKey)
	if !ok {
		return clockfmt.UTC
	}
	z, ok := clockfmt.Parse(v)
	if !ok {
		return clockfmt.UTC
	}
	return z
}

// IsKeyboardLayoutKey reports whether key is the M83d2 layout selector.
func IsKeyboardLayoutKey(key string) bool {
	return key == "keyboard_layout"
}

// ValidKeyboardLayout reports whether the value names a shipped layout.
func ValidKeyboardLayout(value string) bool {
	_, ok := layout.Parse(value)
	return ok
}

// FontKey returns the font_size row (found=false otherwise).
func FontKey(key string) (Key, bool) {
	for _, k := range FontKeys {
		if k.Name == key {
			return k, true
		}
	}
	return Key{}, false
}

// IsFontKey reports whether key is the font_size row.
func IsFontKey(key string) bool {
	_, ok := FontKey(key)
	return ok
}

// PaletteKey returns the palette row for key (found=false otherwise).
func PaletteKey(key string) (Key, bool) {
	for _, k := range PaletteKeys {
		if k.Name == key {
			return k, true
		}
	}
	return Key{}, false
}

// IsPaletteKey reports whether key is one of the custom-palette rows.
func IsPaletteKey(key string) bool {
	_, ok := PaletteKey(key)
	return ok
}

// Editable is the panel's write gate: a kernel-table key, one of the
// custom-palette keys, font_size (M80i), keyboard_layout (M83d2),
// idle_minutes (M83f), notify_dnd (M82d2), notify_sound or audio_volume
// (M99d), timezone (M83c), data_root (M100f), or an a11y.* row (M165b).
// Anything else is named and dropped, never written.
func Editable(key string) bool {
	_, known := Known(key)
	return known || IsPaletteKey(key) || IsFontKey(key) || IsKeyboardLayoutKey(key) ||
		IsIdleMinutesKey(key) || IsNotifyDNDKey(key) || IsNotifySoundKey(key) ||
		IsVolumeKey(key) || IsTimezoneKey(key) || IsDataRootKey(key) || IsA11yKey(key)
}

// ValidColour is the palette value grammar, mirrored from the kernel's
// `parse_hex6`: EXACTLY six hex digits, case-insensitive, no `0x` prefix.
// Anything else is refused by the panel BEFORE it reaches the file — the
// kernel refuses it again at apply (defence in depth: the applied colour is
// never a half-read number).
func ValidColour(val string) bool {
	_, ok := Colour(val)
	return ok
}

// Colour parses a stored palette colour (the ValidColour grammar) to 24-bit
// RGB. found=false for anything the kernel would refuse.
func Colour(val string) (uint32, bool) {
	if len(val) != 6 {
		return 0, false
	}
	var v uint32
	for i := 0; i < 6; i++ {
		c := val[i]
		var d uint32
		switch {
		case c >= '0' && c <= '9':
			d = uint32(c - '0')
		case c >= 'a' && c <= 'f':
			d = uint32(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = uint32(c-'A') + 10
		default:
			return 0, false
		}
		v = v<<4 | d
	}
	return v, true
}

// Known reports the kernel-table row for key.
func Known(key string) (Key, bool) {
	for _, k := range KnownKeys {
		if k.Name == key {
			return k, true
		}
	}
	return Key{}, false
}

// Default returns the value in force for key when the file carries no such
// key: the kernel's compiled default, or "".found=false for an unknown key.
func Default(key string) (string, bool) {
	if k, ok := Known(key); ok {
		return k.Default, true
	}
	if k, ok := PaletteKey(key); ok {
		return k.Default, true
	}
	if k, ok := FontKey(key); ok {
		return k.Default, true
	}
	for _, k := range KeyboardLayoutKeys {
		if k.Name == key {
			return k.Default, true
		}
	}
	for _, k := range IdleKeys {
		if k.Name == key {
			return k.Default, true
		}
	}
	for _, group := range [][]Key{NotifyKeys, NotifySoundKeys, VolumeKeys, TimezoneKeys, DataRootKeys, A11yKeys} {
		for _, k := range group {
			if k.Name == key {
				return k.Default, true
			}
		}
	}
	return "", false
}

// Vocab returns the values the panel may cycle key through, and whether
// key is cyclable at all. A kernel-table key with no vocabulary is free
// text; font_size (M80i), keyboard_layout (M83d2) and notify_dnd (M82d2)
// carry declared lists.
func Vocab(key string) ([]string, bool) {
	k, ok := Known(key)
	if !ok {
		k, ok = FontKey(key)
	}
	if !ok {
		k, ok = findKey(KeyboardLayoutKeys, key)
	}
	if !ok {
		k, ok = findKey(NotifyKeys, key)
	}
	if !ok {
		k, ok = findKey(NotifySoundKeys, key)
	}
	if !ok {
		k, ok = findKey(VolumeKeys, key)
	}
	if !ok {
		k, ok = findKey(TimezoneKeys, key)
	}
	if !ok {
		k, ok = findKey(DataRootKeys, key)
	}
	if !ok {
		k, ok = findKey(A11yKeys, key)
	}
	if !ok {
		return nil, false
	}
	return k.Vocab, true
}

func findKey(keys []Key, name string) (Key, bool) {
	for _, k := range keys {
		if k.Name == name {
			return k, true
		}
	}
	return Key{}, false
}

// Next returns the vocabulary value after cur, wrapping; a cur outside the
// vocabulary (a value the kernel would ignore) starts the cycle at the top.
func Next(vocab []string, cur string) string {
	if len(vocab) == 0 {
		return cur
	}
	for i, v := range vocab {
		if v == cur {
			return vocab[(i+1)%len(vocab)]
		}
	}
	return vocab[0]
}

// Parse decodes a schema-v2 SETTINGS.TXT body. The first line must be exactly
// `#v<digits>` with a version this consumer understands (the kernel's gate: a
// malformed header or a NEWER schema is refused, not half-read; `#v0`/`#v1`/
// `#v2` all parse and migrate up); every other line is `key=value`, `#`
// comments and blank lines skipped. Bounded like the kernel's table: rows past
// the caps are dropped, the load still succeeds. A file that fails the header
// gate is corrupt: ok=false, and the caller fails closed.
func Parse(b []byte) ([]Setting, bool) {
	first, rest := cutLine(string(b))
	first = strings.TrimSuffix(first, "\r")
	if !strings.HasPrefix(first, "#v") || len(first) <= 2 {
		return nil, false
	}
	digits := first[2:]
	if len(digits) > 3 {
		return nil, false // no real schema version needs more
	}
	ver := 0
	for i := 0; i < len(digits); i++ {
		c := digits[i]
		if c < '0' || c > '9' {
			return nil, false
		}
		ver = ver*10 + int(c-'0')
	}
	if ver > 2 {
		return nil, false
	}
	var out []Setting
	for len(rest) > 0 {
		var line string
		line, rest = cutLine(rest)
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, hasEq := strings.Cut(line, "=")
		if !hasEq {
			continue // the kernel's parse_line refuses a row without '='
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		if key == "" || len(key) > MaxKey || len(val) > MaxVal {
			continue // the kernel's parse_line drops the row, the load stands
		}
		if len(out) >= MaxKeys {
			break
		}
		out = append(out, Setting{Key: key, Val: val})
	}
	return out, true
}

// Render serializes rows in the kernel's exact byte shape: the `#v2` header,
// then one `key=value` line per row. Pinned host-side against the kernel
// serializer's output (see settings_test.go).
func Render(ss []Setting) []byte {
	var b strings.Builder
	b.WriteString("#v2\n")
	for _, s := range ss {
		b.WriteString(s.Key)
		b.WriteString("=")
		b.WriteString(s.Val)
		b.WriteString("\n")
	}
	return []byte(b.String())
}

// Get returns the last value decoded for key (the kernel's set-internal
// semantics: a later row updates the earlier one).
func Get(ss []Setting, key string) (string, bool) {
	var val string
	found := false
	for _, s := range ss {
		if s.Key == key {
			val, found = s.Val, true
		}
	}
	return val, found
}

// Set updates the last row for key in place, or appends one when the file
// carries no such row. The kernel's own set is the same shape: a later row
// wins, and a new key lands at the end of the table.
//
// M99d (#2182): the kernel's set also runs per-key apply hooks (theme,
// font_size, focus_follows_mouse — kernel/src/settings.zig). The Go mirror
// carries exactly one: writing audio_volume applies it to slot 44 at the
// moment the row is written, so a GOSET `audio_volume=40` moves the stream
// gain before the save even publishes. The kernel validates the same
// 0..100 bound; an unparsable value writes the row but applies nothing
// (the row's consumers refuse it the same way at read time).
func Set(ss []Setting, key, val string) []Setting {
	found := false
	for i := len(ss) - 1; i >= 0; i-- {
		if ss[i].Key == key {
			ss[i].Val = val
			found = true
			break
		}
	}
	if !found {
		ss = append(ss, Setting{Key: key, Val: val})
	}
	if key == AudioVolumeKey {
		if v, ok := AudioVolume(val); ok {
			_, _ = AudioVolumeApply(v)
		}
	}
	return ss
}

// AudioVolumeApply is the slot-44 seam behind Set's audio_volume hook —
// exported and a var so a host test outside this package can pin the call
// the way the seat pins its own seams; the real syscall degrades to ENOSYS
// off the guest, and a refusal is honest (the caller's row still lands).
var AudioVolumeApply = vi.AudioVolume

// Effective returns the value the seat will honor for key: the file's value
// when the file carries one, else the kernel's compiled default. found=false
// for an unknown key with no row.
func (f File) Effective(key string) (string, bool) {
	if v, ok := Get(f.Rows, key); ok {
		return v, true
	}
	return Default(key)
}

// Display returns the decoded rows, then the missing compiled-table and
// visible accepted-but-unseeded rows with their effective defaults. An
// already-full table keeps the idle, do-not-disturb and timezone defaults
// implicit to respect MaxKeys.
// Unknown file rows are preserved untouched, not offered for editing.
func (f File) Display() []Setting {
	out := make([]Setting, 0, len(f.Rows)+len(KnownKeys)+len(KeyboardLayoutKeys)+len(IdleKeys)+len(NotifyKeys)+len(TimezoneKeys))
	out = append(out, f.Rows...)
	for _, k := range KnownKeys {
		if _, ok := Get(f.Rows, k.Name); !ok {
			out = append(out, Setting{Key: k.Name, Val: k.Default})
		}
	}
	for _, k := range KeyboardLayoutKeys {
		if _, ok := Get(f.Rows, k.Name); !ok {
			out = append(out, Setting{Key: k.Name, Val: k.Default})
		}
	}
	for _, group := range [][]Key{IdleKeys, NotifyKeys, TimezoneKeys} {
		for _, k := range group {
			if _, ok := Get(f.Rows, k.Name); !ok {
				// A legacy table may already have 16 rows; its visible layout
				// row fills the kernel's 17-slot cap. Do not make an unchanged
				// GOSET save fail merely by displaying one more default.
				if len(out) >= MaxKeys {
					break
				}
				out = append(out, Setting{Key: k.Name, Val: k.Default})
			}
		}
	}
	return out
}

// Load reads and decodes Path. A missing file is StateMissing (the compiled
// defaults are in force); a file that fails the decode is StateCorrupt and
// nothing in it is trusted — the same verdict the kernel and the seat reach.
func Load() File {
	// Read one byte past the kernel's bounded buffer: a file LARGER than
	// MaxBody is refused whole (the kernel's stat gate), so neither consumer
	// accepts what the kernel would refuse (M66b review).
	b, r := vi.ReadFileAll(Path, MaxBody+1)
	if r < 0 || b == nil {
		return File{State: StateMissing}
	}
	if len(b) > MaxBody {
		return File{State: StateCorrupt}
	}
	rows, ok := Parse(b)
	if !ok {
		return File{State: StateCorrupt}
	}
	return File{Rows: rows, State: StateOK}
}

// Save publishes the file's rows crash-safe (vi.WriteFileSafe: temp + fsync +
// delete/rename). It REFUSES a corrupt decode — a panel must never launder a
// file the kernel refused — returning SaveRefused. SaveFull likewise refuses a
// table the kernel would truncate. Any other negative return is the kernel
// code of the step that failed; every failure removes the temp, so the target
// is either the old bytes, the new bytes, or absent (defaults).
func (f File) Save() int64 {
	if f.State == StateCorrupt {
		return SaveRefused
	}
	if len(f.Rows) > MaxKeys {
		return SaveFull
	}
	return vi.WriteFileSafe(Path, Render(f.Rows))
}

// Subscribe asks the active WM seat to deliver changes to key to this tab.
// The subscriber still reads the persisted value after a notification, so the
// mailbox carries only the key and never becomes a second settings store.
func Subscribe(key string, winID uint32, selfName string) bool {
	if !Editable(key) {
		return false
	}
	return vi.SubscribeSetting(winID, key, selfName)
}

// PublishChange tells the active WM seat that a successful Save changed key.
// Call this only after the crash-safe publish has completed.
func PublishChange(key string, winID uint32, selfName string) bool {
	if !Editable(key) {
		return false
	}
	return vi.PublishSettingChange(winID, key, selfName)
}

// PollChange consumes one delivered key and returns its current persisted
// value. A malformed or missing settings file fails closed.
func PollChange(winID uint32) (key, value string, ok bool) {
	key, ok = vi.PollSettingChanged(winID)
	if !ok || !Editable(key) {
		return "", "", false
	}
	f := Load()
	if f.State != StateOK {
		return "", "", false
	}
	value, ok = f.Effective(key)
	if !ok {
		return "", "", false
	}
	return key, value, true
}

// cutLine splits s after the first newline (if any); the remainder keeps its
// newline handling for the next round.
func cutLine(s string) (line, rest string) {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i], s[i+1:]
	}
	return s, ""
}
