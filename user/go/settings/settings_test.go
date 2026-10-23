package settings

import (
	"errors"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"virelai/clockfmt"
	"virelai/vi"
)

// ---------------------------------------------------------------------------
// M66b (#1444): the schema-v2 decode, corrupt-fails-closed
// (moved here from user/go/gotabwm by M71f #1565 — one codec, two consumers)
// ---------------------------------------------------------------------------

// The kernel's SETTINGS.TXT gate, mirrored: a valid `#v<digits>` header
// (v0/v1/v2 all parse and migrate up), then key=value rows. Everything the
// kernel refuses, this decoder refuses; everything the kernel accepts, it
// accepts.
func TestSettingsParseMirrorsTheKernelGate(t *testing.T) {
	good := map[string]string{
		"v2":     "#v2\nwm=none\nhostname=box\n",
		"v1":     "#v1\nwm=tabwm\n",
		"v0":     "#v0\nwm=tabwm\n",
		"crlf":   "#v2\r\nwm=none\r\n",
		"mkdirs": "#v2\n# a comment\n\n  wm = tabwm  \n",
	}
	for name, body := range good {
		ss, ok := Parse([]byte(body))
		if !ok {
			t.Fatalf("%s: good file refused", name)
		}
		if v, found := Get(ss, "wm"); !found || v != "tabwm" && v != "none" {
			t.Fatalf("%s: wm = %q found=%v", name, v, found)
		}
	}
	// The seeded gate fixture, decoded end to end.
	ss, ok := Parse([]byte("#v2\nwm=none\n"))
	if !ok || len(ss) != 1 || ss[0].Key != "wm" || ss[0].Val != "none" {
		t.Fatalf("seeded fixture = %+v ok=%v", ss, ok)
	}
}

func TestSettingsParseIsFailClosed(t *testing.T) {
	bad := map[string]string{
		"empty":      "",          // a wiped file
		"headerless": "wm=none\n", // the partial in-place write shape
		"bare hash":  "#\nwm=none\n",
		"no digits":  "#v\nwm=none\n",
		"bad digit":  "#vx\nwm=none\n",
		"trailing":   "#v2x\nwm=none\n",
		"merged":     "#v2 wm=none\n", // header and data on one line
		"newer":      "#v3\nwm=none\n",
		"too long":   "#v1234\nwm=none\n",
		"pattern":    "\x00\x01\x02\x03\n", // vf write's probe-pattern garbage
	}
	for name, body := range bad {
		if ss, ok := Parse([]byte(body)); ok {
			t.Fatalf("%s: corrupt file parsed as %+v", name, ss)
		}
	}
}

// The kernel's parser drops a malformed ROW and the load stands; only the
// header gates the whole file. The decoder mirrors that (and caps the
// table like the kernel's max_entries / 32-byte keys / 64-byte values).
func TestSettingsParseDropsRowsButStands(t *testing.T) {
	ss, ok := Parse([]byte("#v2\nwm=none\nno_equals_here\n=emptykey\n"))
	if !ok {
		t.Fatal("a malformed row refused the whole file")
	}
	if len(ss) != 1 {
		t.Fatalf("rows = %+v, want the wm row only", ss)
	}
	// The later duplicate wins, like the kernel's set-internal.
	ss, ok = Parse([]byte("#v2\nwm=none\nwm=tabwm\n"))
	if !ok {
		t.Fatal("duplicates refused the file")
	}
	if v, _ := Get(ss, "wm"); v != "tabwm" {
		t.Fatalf("wm = %q, want the later row", v)
	}
	// Rows past the table cap are dropped, the load still succeeds.
	var b strings.Builder
	b.WriteString("#v2\n")
	for i := 0; i < MaxKeys+3; i++ {
		b.WriteString("k" + strconv.Itoa(i) + "=v\n")
	}
	ss, ok = Parse([]byte(b.String()))
	if !ok {
		t.Fatal("over-cap table refused the file")
	}
	if len(ss) != MaxKeys {
		t.Fatalf("rows = %d, want the capped %d", len(ss), MaxKeys)
	}
}

// Render is the write half of the codec: its bytes must equal what the
// kernel's own serializer emits for the same table (settings.zig init()
// order), so the two implementations cannot drift. Note the kernel
// round-trips `prompt=virelai> ` byte-exactly on WRITE (only a REload
// trims the value). This unit pin compares Go against a Go-side literal —
// it cannot catch kernel/Go drift by itself; the real cross-implementation
// pin is go-wm-default boot 04's share-equals on the healed file, and M71f's
// panel save is compared byte-for-byte on the share by that spec too.
func TestSettingsRenderMatchesTheKernelSerializer(t *testing.T) {
	rows := []Setting{
		{"hostname", "virelai"},
		{"prompt", "virelai> "},
		{"theme", "dark"},
		{"scrollback", "1000"},
		{"shadow", "off"},
		{"focus_follows_mouse", "off"},
		{"shell", "monitor"},
		{"wm", "tabwm"},
	}
	want := "#v2\nhostname=virelai\nprompt=virelai> \ntheme=dark\n" +
		"scrollback=1000\nshadow=off\nfocus_follows_mouse=off\n" +
		"shell=monitor\nwm=tabwm\n"
	if got := string(Render(rows)); got != want {
		t.Fatalf("render:\n got %q\nwant %q", got, want)
	}
}

// The full round-trip on values the format carries byte-exactly: parse ->
// render -> parse is stable and the wm key survives.
func TestSettingsRoundTripIsStable(t *testing.T) {
	body := "#v2\nwm=none\nhostname=box\nshadow=on\n"
	ss, ok := Parse([]byte(body))
	if !ok {
		t.Fatal("seed refused")
	}
	ss2, ok := Parse(Render(ss))
	if !ok {
		t.Fatal("re-parse refused the rendered bytes")
	}
	if len(ss2) != len(ss) {
		t.Fatalf("rows %d -> %d", len(ss), len(ss2))
	}
	for _, s := range ss {
		if v, found := Get(ss2, s.Key); !found || v != s.Val {
			t.Fatalf("key %s drifted: %q found=%v", s.Key, v, found)
		}
	}
}

// ---------------------------------------------------------------------------
// M71f (#1565): the panel's edit half — known keys, vocabularies, publish
// ---------------------------------------------------------------------------

// KnownKeys is a MIRROR of the kernel's compiled table, not a second schema.
// Read kernel/src/settings.zig and pin the mirror: every set_internal() key
// must be present here with the same default, and no extra key may be offered.
// A key added to the kernel and not to the panel is a failing test, not a
// silent drift.
func TestKnownKeysMirrorTheKernelTable(t *testing.T) {
	src, err := os.ReadFile("../../../kernel/src/settings.zig")
	if err != nil {
		t.Fatalf("read kernel/src/settings.zig: %v (this test only runs in-tree)", err)
	}
	// `_ = set_internal("key", "value");` — plus `wm`, whose default is the
	// `wm_default` const rather than a literal.
	rowRe := regexp.MustCompile(`set_internal\("([^"]+)", ("[^"]*"|[A-Za-z_][A-Za-z0-9_]*)\)`)
	constRe := regexp.MustCompile(`const wm_default: \[\]const u8 = "([^"]*)"`)

	cm := constRe.FindStringSubmatch(string(src))
	if cm == nil {
		t.Fatal("kernel/src/settings.zig: no wm_default const found")
	}
	consts := map[string]string{"wm_default": cm[1]}

	want := map[string]string{}
	for _, m := range rowRe.FindAllStringSubmatch(string(src), -1) {
		key, val := m[1], m[2]
		if strings.HasPrefix(val, `"`) {
			want[key] = strings.Trim(val, `"`)
			continue
		}
		v, ok := consts[val]
		if !ok {
			t.Fatalf("kernel default for %q is %s, which this test cannot resolve", key, val)
		}
		want[key] = v
	}
	if len(want) == 0 {
		t.Fatal("no set_internal rows parsed out of the kernel table")
	}

	got := map[string]string{}
	for _, k := range KnownKeys {
		got[k.Name] = k.Default
	}
	for key, val := range want {
		gv, ok := got[key]
		if !ok {
			t.Errorf("kernel key %q is not offered by the panel", key)
			continue
		}
		if gv != val {
			t.Errorf("key %q default %q, kernel %q", key, gv, val)
		}
	}
	for key := range got {
		if _, ok := want[key]; !ok {
			t.Errorf("panel offers %q, which the kernel table does not carry", key)
		}
	}
}

// A key absent from the file is still a row: the panel shows what is IN FORCE,
// so `wm` is settable on a share that has never carried one (card D2).
func TestDisplaySurfacesAbsentKnownKeysWithTheValueInForce(t *testing.T) {
	f := File{Rows: []Setting{{"hostname", "box"}}, State: StateOK}
	d := f.Display()
	// The file row plus the kernel keys and accepted-unseeded rows are
	// filled out, never duplicated.
	want := len(KnownKeys) + len(KeyboardLayoutKeys) + len(IdleKeys) + len(NotifyKeys) + len(TimezoneKeys)
	if len(d) != want {
		t.Fatalf("display rows = %d, want %d", len(d), want)
	}
	if v, ok := Get(d, "notify_dnd"); !ok || v != "off" {
		t.Fatalf("notify_dnd row = %q ok=%v, want the compiled default off", v, ok)
	}
	if v, ok := Get(d, "wm"); !ok || v != "gotabwm" {
		t.Fatalf("wm row = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := Get(d, "theme"); !ok || v != "dark" {
		t.Fatalf("theme row = %q ok=%v", v, ok)
	}
	if v, ok := Get(d, "keyboard_layout"); !ok || v != "us" {
		t.Fatalf("keyboard_layout row = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := Get(d, "idle_minutes"); !ok || v != "5" {
		t.Fatalf("idle_minutes row = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := Get(d, "timezone"); !ok || v != "UTC" {
		t.Fatalf("timezone row = %q ok=%v, want the compiled default", v, ok)
	}
	if v, ok := Get(d, "hostname"); !ok || v != "box" {
		t.Fatalf("file row lost: %q ok=%v", v, ok)
	}
	// A missing file is the same story: the compiled defaults are in force.
	if v, ok := (File{State: StateMissing}).Effective("wm"); !ok || v != "gotabwm" {
		t.Fatalf("missing file wm = %q ok=%v", v, ok)
	}
}

// Effective prefers the file's value, then the kernel default; an unknown key
// with no row has no value at all.
func TestEffectivePrefersTheFileValue(t *testing.T) {
	f := File{Rows: []Setting{{"wm", "tabwm"}}, State: StateOK}
	if v, ok := f.Effective("wm"); !ok || v != "tabwm" {
		t.Fatalf("wm = %q ok=%v", v, ok)
	}
	if v, ok := f.Effective("shell"); !ok || v != "monitor" {
		t.Fatalf("shell = %q ok=%v", v, ok)
	}
	if v, ok := f.Effective("not_a_key"); ok {
		t.Fatalf("unknown key produced %q", v)
	}
}

func TestDefaultIncludesAcceptedUnseededKeys(t *testing.T) {
	for key, want := range map[string]string{
		"palette_fg":      "00ff00",
		"palette_bg":      "101418",
		"palette_accent":  "3b82f6",
		"font_size":       "medium",
		"keyboard_layout": "us",
		"idle_minutes":    "5",
		"notify_dnd":      "off",
	} {
		if got, ok := Default(key); !ok || got != want {
			t.Errorf("Default(%q) = (%q, %v), want (%q, true)", key, got, ok, want)
		}
	}
	if _, ok := Default("not_a_key"); ok {
		t.Fatal("unknown key acquired a default")
	}
}

func TestSubscriptionAndPublishRejectUnknownKeys(t *testing.T) {
	prev := vi.SetSyscallHookForTest(func(uintptr, uintptr, uintptr, uintptr, uintptr) int64 {
		t.Fatal("unknown setting touched the syscall seam")
		return 0
	})
	defer vi.SetSyscallHookForTest(prev)
	if Subscribe("not_a_key", 4, "NOTE.ELF") {
		t.Fatal("unknown setting subscribed")
	}
	if PublishChange("not_a_key", 4, "GOSET.ELF") {
		t.Fatal("unknown setting published")
	}
}

// Set updates the LAST row for the key (the kernel's later-row-wins) or
// appends; it never duplicates.
func TestSetUpdatesTheLastRowOrAppends(t *testing.T) {
	ss := []Setting{{"wm", "none"}, {"shadow", "on"}, {"wm", "tabwm"}}
	ss = Set(ss, "wm", "gotabwm")
	if len(ss) != 3 {
		t.Fatalf("Set duplicated the key: %+v", ss)
	}
	if v, _ := Get(ss, "wm"); v != "gotabwm" {
		t.Fatalf("wm = %q", v)
	}
	if ss[2].Key != "wm" {
		t.Fatalf("Set rewrote the wrong row: %+v", ss)
	}
	ss = Set(ss, "shell", "sh")
	if len(ss) != 4 || ss[3].Key != "shell" {
		t.Fatalf("new key did not append: %+v", ss)
	}
}

// Next cycles a known vocabulary and restarts at the top for a value outside
// it (a value the seat would ignore, e.g. the Zig panel's `amber`).
func TestNextCyclesTheVocabulary(t *testing.T) {
	vocab, ok := Vocab("wm")
	if !ok {
		t.Fatal("wm has no vocabulary")
	}
	if got := Next(vocab, "gotabwm"); got != "tabwm" {
		t.Fatalf("gotabwm -> %q", got)
	}
	if got := Next(vocab, "none"); got != "gotabwm" {
		t.Fatalf("none -> %q (want the wrap)", got)
	}
	if got := Next(vocab, "amber"); got != "gotabwm" {
		t.Fatalf("outside value -> %q (want the top)", got)
	}
	// M73m (#1662): the theme cycle is the preset chooser — the three
	// built-in presets the kernel resolves plus `custom` (the user's own
	// colours). The Go seat's chrome still only KNOWS dark|light; theme.Set
	// refuses the rest, so an amber/custom row leaves the Go chrome on its
	// current tokens while the kernel terminal takes the choice.
	if tv, _ := Vocab("theme"); !hasOnly(tv, "dark", "light", "amber", "custom") {
		t.Fatalf("theme vocabulary = %v, want exactly dark|light|amber|custom", tv)
	}
	if _, ok := Vocab("not_a_key"); ok {
		t.Fatal("unknown key has a vocabulary")
	}
}

func hasOnly(vocab []string, want ...string) bool {
	if len(vocab) != len(want) {
		return false
	}
	for i := range want {
		if vocab[i] != want[i] {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// M73m (#1662): the custom-palette keys — the accepted set, the value
// grammar, and the defaults mirrored from the kernel source.
// ---------------------------------------------------------------------------

// PaletteKeys are accepted-but-NOT-seeded keys, so they must stay OUT of the
// KnownKeys mirror (a seeded key would change the default table, and the
// default SETTINGS.TXT byte shape, that go-wm-default pins) while their
// defaults stay step-for-step with kernel/src/settings.zig.
func TestPaletteKeysMirrorTheKernelDefaults(t *testing.T) {
	if len(PaletteKeys) != 3 {
		t.Fatalf("PaletteKeys = %d rows, want 3", len(PaletteKeys))
	}
	for _, k := range PaletteKeys {
		if _, known := Known(k.Name); known {
			t.Fatalf("%s must not be a KnownKeys row (the kernel does not seed it)", k.Name)
		}
		if !Editable(k.Name) {
			t.Fatalf("%s is not editable — the panel could not choose colours", k.Name)
		}
		if _, ok := Colour(k.Default); !ok {
			t.Fatalf("default %q for %s is not six hex digits", k.Default, k.Name)
		}
	}
	if Editable("not_a_key") {
		t.Fatal("an unknown key is editable")
	}

	// Read the kernel's `pub const palette_*_default: u32 = ...` and resolve
	// `text.fg_rgb`/`text.bg_rgb` against text.zig — the same drift guard the
	// KnownKeys mirror applies, one level over.
	settingsSrc, err := os.ReadFile("../../../kernel/src/settings.zig")
	if err != nil {
		t.Fatalf("read kernel/src/settings.zig: %v (in-tree only)", err)
	}
	textSrc, err := os.ReadFile("../../../kernel/src/text.zig")
	if err != nil {
		t.Fatalf("read kernel/src/text.zig: %v (in-tree only)", err)
	}
	textConsts := map[string]string{}
	reText := regexp.MustCompile(`pub const (fg|bg)_rgb: u32 = (0x[0-9a-fA-F]+);`)
	for _, m := range reText.FindAllStringSubmatch(string(textSrc), -1) {
		textConsts[m[1]+"_rgb"] = m[2]
	}
	re := regexp.MustCompile(`pub const palette_(fg|bg|accent)_default: u32 = ([^;]+);`)
	got := map[string]string{}
	for _, m := range re.FindAllStringSubmatch(string(settingsSrc), -1) {
		val := strings.TrimSpace(m[2])
		if !strings.HasPrefix(val, "0x") { // `text.fg_rgb` / `text.bg_rgb`
			name := strings.TrimPrefix(val, "text.")
			resolved, ok := textConsts[name]
			if !ok {
				t.Fatalf("kernel default for palette_%s is %s, which this test cannot resolve", m[1], val)
			}
			val = resolved
		}
		got[m[1]] = val
	}
	if len(got) != len(PaletteKeys) {
		t.Fatalf("kernel palette defaults parsed = %d, want %d", len(got), len(PaletteKeys))
	}
	for _, k := range PaletteKeys {
		name := strings.TrimPrefix(k.Name, "palette_")
		want, ok := got[name]
		if !ok {
			t.Errorf("kernel carries no palette_%s_default", name)
			continue
		}
		if v, _ := Colour(k.Default); fmtHex(v) != strings.ToLower(strings.TrimPrefix(want, "0x")) {
			t.Errorf("palette_%s default = 0x%s, kernel %s", name, k.Default, want)
		}
	}
}

// fmtHex is the six-digit lowercase form the comparison wants.
func fmtHex(v uint32) string {
	const d = "0123456789abcdef"
	b := make([]byte, 6)
	for i := 5; i >= 0; i-- {
		b[i] = d[v&0xf]
		v >>= 4
	}
	return string(b)
}

// The palette value grammar, mirrored from the kernel's parse_hex6: exactly
// six hex digits, case-insensitive, no 0x — everything else refused.
func TestValidColourMirrorsTheKernelGrammar(t *testing.T) {
	good := []string{"00ff00", "101418", "3b82f6", "20FF9E", "abcdef"}
	for _, v := range good {
		if !ValidColour(v) {
			t.Errorf("ValidColour(%q) = false, want true", v)
		}
	}
	bad := []string{"", "00ff9", "00ff001", "00ff0z", "0x00ff00", " ff0000", "ff0000\n"}
	for _, v := range bad {
		if ValidColour(v) {
			t.Errorf("ValidColour(%q) = true, want false", v)
		}
	}
	if c, ok := Colour("20ff9e"); !ok || c != 0x20ff9e {
		t.Fatalf("Colour(20ff9e) = %#x ok=%v", c, ok)
	}
	if c, ok := Colour("20FF9E"); !ok || c != 0x20ff9e {
		t.Fatalf("Colour(20FF9E) = %#x ok=%v (case must not matter)", c, ok)
	}
}

// A corrupt decode is refused by Save: the panel must never launder a file the
// kernel refused whole. StateMissing is NOT refused — a first boot is exactly
// how a fresh share gets a settings file.
func TestSaveRefusesOnlyACorruptDecode(t *testing.T) {
	if rc := (File{State: StateCorrupt}).Save(); rc != SaveRefused {
		t.Fatalf("corrupt save rc = %d, want SaveRefused", rc)
	}
	if SaveRefused == 0 {
		t.Fatal("SaveRefused must not look like success")
	}
}

// ---------------------------------------------------------------------------
// M80i (#1725): the font_size row — accepted, NOT seeded (the PaletteKeys
// pattern), with the rung vocabulary the kernel's apply_font_size maps onto
// both ladders.
// ---------------------------------------------------------------------------

// font_size must stay OUT of KnownKeys (the kernel does not seed it — a
// the eight kernel rows plus keyboard_layout, and the fresh-share bytes stay
// identical),
// while its vocabulary is exactly the ladder the kernel applies.
func TestFontKeysMirrorTheKernelVocabulary(t *testing.T) {
	if len(FontKeys) != 1 || FontKeys[0].Name != "font_size" {
		t.Fatalf("FontKeys = %+v, want the one font_size row", FontKeys)
	}
	if _, known := Known("font_size"); known {
		t.Fatal("font_size must not be a KnownKeys row (the kernel does not seed it)")
	}
	if !Editable("font_size") {
		t.Fatal("font_size is not editable — the panel could not choose the zoom rung")
	}
	if v, ok := Vocab("font_size"); !ok || !hasOnly(v, "small", "medium", "large") {
		t.Fatalf("font_size vocabulary = %v ok=%v, want exactly small|medium|large", v, ok)
	}
	// The kernel's apply_font_size must accept every vocabulary name AND
	// the M20 aliases (the panel cycles the names; the kernel also honours
	// the aliases a hand-written file may carry).
	src, err := os.ReadFile("../../../kernel/src/settings.zig")
	if err != nil {
		t.Fatalf("read kernel/src/settings.zig: %v (in-tree only)", err)
	}
	re := regexp.MustCompile(`fn apply_font_size[\s\S]*?\n}`)
	block := re.FindString(string(src))
	if block == "" {
		t.Fatal("kernel/src/settings.zig: apply_font_size not found")
	}
	for _, name := range []string{"small", "medium", "large", "0", "1", "2", "8x8", "16x16", "24x24"} {
		if !strings.Contains(block, "\""+name+"\"") {
			t.Errorf("kernel apply_font_size does not accept %q", name)
		}
	}
}

// M83d2 (#1786): the layout selector is accepted but not seeded, preserving
// the kernel defaults/file bytes while giving GOSET a real two-layout row.
func TestKeyboardLayoutSettingVocabulary(t *testing.T) {
	if len(KeyboardLayoutKeys) != 1 || KeyboardLayoutKeys[0].Name != "keyboard_layout" {
		t.Fatalf("KeyboardLayoutKeys = %+v, want the one selector row", KeyboardLayoutKeys)
	}
	if _, known := Known("keyboard_layout"); known {
		t.Fatal("keyboard_layout must remain outside the seeded kernel table")
	}
	if !Editable("keyboard_layout") {
		t.Fatal("keyboard_layout is not editable")
	}
	if got, ok := Default("keyboard_layout"); !ok || got != "us" {
		t.Fatalf("Default(keyboard_layout) = (%q,%v), want (us,true)", got, ok)
	}
	if got, ok := Vocab("keyboard_layout"); !ok || !hasOnly(got, "us", "de") {
		t.Fatalf("Vocab(keyboard_layout) = (%v,%v), want [us de]", got, ok)
	}
	for _, value := range []string{"us", "de"} {
		if !ValidKeyboardLayout(value) {
			t.Errorf("ValidKeyboardLayout(%q) = false", value)
		}
	}
	if ValidKeyboardLayout("fr") || Editable("not_a_key") {
		t.Fatal("unsupported layout or unknown setting was accepted")
	}
}

func TestOptionalRowsRespectFullTable(t *testing.T) {
	rows := make([]Setting, 0, MaxKeys-2)
	for _, k := range KnownKeys {
		rows = append(rows, Setting{Key: k.Name, Val: k.Default})
	}
	for i := 0; i < MaxKeys-2-len(KnownKeys); i++ {
		rows = append(rows, Setting{Key: "extension" + string(rune('a'+i)), Val: "v"})
	}
	display := (File{Rows: rows, State: StateOK}).Display()
	if len(rows) != MaxKeys-2 || len(display) != MaxKeys {
		t.Fatalf("rows = %d, want %d pre-optional and %d with layout+idle", len(rows), MaxKeys-2, MaxKeys)
	}
	Set(display, "keyboard_layout", "de")
	Set(display, "idle_minutes", "7")
	decoded, ok := Parse(Render(display))
	if !ok || len(decoded) != MaxKeys {
		t.Fatalf("layout was dropped at the new cap: rows=%d ok=%v", len(decoded), ok)
	}
	if got, _ := Get(decoded, "keyboard_layout"); got != "de" {
		t.Fatalf("keyboard_layout = %q after round-trip, want de", got)
	}
	if got, _ := Get(decoded, "idle_minutes"); got != "7" {
		t.Fatalf("idle_minutes = %q after round-trip, want 7", got)
	}
	if rc := (File{Rows: append(display, Setting{Key: "overflow", Val: "v"}), State: StateOK}).Save(); rc != SaveFull {
		t.Fatalf("over-cap panel save = %d, want SaveFull", rc)
	}

	// A table with one free slot can still be saved from GOSET after
	// materializing keyboard_layout. Keep that contract:
	// the idle default is implicit when there is no free kernel slot.
	legacy := append(append([]Setting(nil), rows...), Setting{Key: "extensionz", Val: "v"})
	full := (File{Rows: legacy, State: StateOK}).Display()
	if len(legacy) != MaxKeys-1 || len(full) != MaxKeys {
		t.Fatalf("legacy table rows = %d, display = %d, want %d and %d", len(legacy), len(full), MaxKeys-1, MaxKeys)
	}
	if _, found := Get(full, "idle_minutes"); found {
		t.Fatal("full table materialized idle_minutes beyond the kernel cap")
	}
	if _, found := Get(full, "keyboard_layout"); !found {
		t.Fatal("full table lost the preexisting layout row")
	}
	if _, found := Get(full, "notify_dnd"); found {
		t.Fatal("full table materialized notify_dnd beyond the kernel cap")
	}
	if _, found := Get(full, "timezone"); found {
		t.Fatal("full table materialized timezone beyond the kernel cap")
	}
	if _, found := Get(display, "notify_dnd"); found {
		t.Fatal("a table full after layout+idle materialized notify_dnd beyond the kernel cap")
	}
	if _, found := Get(display, "timezone"); found {
		t.Fatal("a table full after layout+idle materialized timezone beyond the kernel cap")
	}
	// M99d: the chime and gain rows are accepted, never display-materialized —
	// a default panel table carries neither, whatever the cap.
	for _, key := range []string{NotifySoundKey, AudioVolumeKey} {
		if _, found := Get(full, key); found {
			t.Fatalf("full table materialized %s beyond the kernel cap", key)
		}
		if _, found := Get(display, key); found {
			t.Fatalf("%s materialized into a default display table", key)
		}
	}
}

// M82d2 (#1785): do-not-disturb is an accepted-but-unseeded, cyclable row, and
// its parser is strict — a typo must fall back to the default (off) at the
// seat, never silence notifications.
func TestNotifyDNDAcceptedUnseededCyclableAndStrict(t *testing.T) {
	if _, known := Known("notify_dnd"); known {
		t.Fatal("the kernel does not seed notify_dnd")
	}
	if !Editable("notify_dnd") || !IsNotifyDNDKey("notify_dnd") || IsNotifyDNDKey("notify") {
		t.Fatal("GOSET must be able to edit exactly notify_dnd")
	}
	vocab, ok := Vocab("notify_dnd")
	if !ok || len(vocab) != 2 || vocab[0] != "on" || vocab[1] != "off" {
		t.Fatalf("notify_dnd vocab = %v ok=%v, want [on off]", vocab, ok)
	}
	if got := Next(vocab, "off"); got != "on" {
		t.Fatalf("cycle off -> %q, want on", got)
	}
	if got := Next(vocab, "on"); got != "off" {
		t.Fatalf("cycle on -> %q, want off", got)
	}
	for val, want := range map[string]bool{"on": true, "off": false} {
		if on, ok := NotifyDND(val); !ok || on != want {
			t.Errorf("NotifyDND(%q) = (%v, %v), want (%v, true)", val, on, ok, want)
		}
	}
	for _, val := range []string{"", "ON", "true", "1", "yes", "on ", "maybe"} {
		if on, ok := NotifyDND(val); ok || on {
			t.Errorf("NotifyDND(%q) = (%v, %v), want (false, false)", val, on, ok)
		}
	}
	// The value in force survives the safe codec, and an absent row is off.
	f := File{Rows: []Setting{{Key: "notify_dnd", Val: "on"}}, State: StateOK}
	if v, ok := f.Effective("notify_dnd"); !ok || v != "on" {
		t.Fatalf("persisted notify_dnd = %q ok=%v", v, ok)
	}
	if v, ok := (File{State: StateMissing}).Effective("notify_dnd"); !ok || v != "off" {
		t.Fatalf("absent notify_dnd = %q ok=%v, want off", v, ok)
	}
	rows, ok := Parse(Render(f.Display()))
	if !ok {
		t.Fatal("GOSET display cannot round-trip via the safe codec")
	}
	if v, found := Get(rows, "notify_dnd"); !found || v != "on" {
		t.Fatalf("round-trip notify_dnd = %q found=%v", v, found)
	}
}

func TestIdleMinutesAcceptedUnseededAndBounded(t *testing.T) {
	if _, known := Known("idle_minutes"); known {
		t.Fatal("the kernel does not seed idle_minutes")
	}
	if !Editable("idle_minutes") {
		t.Fatal("GOSET must be able to edit idle_minutes")
	}
	for _, val := range []string{"1", "5", "120", "007"} {
		if _, ok := IdleMinutes(val); !ok {
			t.Errorf("valid minutes %q refused", val)
		}
	}
	for _, val := range []string{"", "0", "121", "-1", "1.5", "1x", "1000"} {
		if _, ok := IdleMinutes(val); ok {
			t.Errorf("invalid minutes %q accepted", val)
		}
	}
	f := File{Rows: []Setting{{Key: "idle_minutes", Val: "7"}}, State: StateOK}
	if v, ok := f.Effective("idle_minutes"); !ok || v != "7" {
		t.Fatalf("persisted idle_minutes = %q ok=%v", v, ok)
	}
	if rows, ok := Parse(Render(f.Display())); !ok {
		t.Fatal("GOSET display cannot round-trip via the safe codec")
	} else if v, found := Get(rows, "idle_minutes"); !found || v != "7" {
		t.Fatalf("round-trip idle_minutes = %q found=%v", v, found)
	}
}

// M83c (#1776): the timezone row is accepted-but-unseeded and cyclable, and
// its resolver is strict-fallback — a value that does not parse is UTC, so a
// typo can never shift every clock silently.
func TestTimezoneAcceptedUnseededCyclableAndFallsBackToUTC(t *testing.T) {
	if _, known := Known("timezone"); known {
		t.Fatal("the kernel does not seed timezone")
	}
	if !Editable(TimezoneKey) || !IsTimezoneKey(TimezoneKey) || IsTimezoneKey("time") {
		t.Fatal("GOSET must be able to edit exactly timezone")
	}
	if got, ok := Default(TimezoneKey); !ok || got != "UTC" {
		t.Fatalf("Default(timezone) = (%q,%v), want (UTC,true)", got, ok)
	}
	vocab, ok := Vocab(TimezoneKey)
	if !ok || len(vocab) != len(clockfmt.Offsets) || vocab[0] != clockfmt.Label(clockfmt.Offsets[0]) {
		t.Fatalf("timezone vocab = %v ok=%v, want clockfmt's curated labels", vocab, ok)
	}
	for _, val := range []string{"UTC", "UTC+05:30", "UTC-08:00", "UTC+05:45"} {
		if !ValidTimezone(val) {
			t.Errorf("ValidTimezone(%q) = false", val)
		}
	}
	for _, val := range []string{"", "utc", "UTC+5:30", "UTC+15:00", "Europe/Nowhere", "5:30"} {
		if ValidTimezone(val) {
			t.Errorf("ValidTimezone(%q) = true", val)
		}
	}
	f := File{Rows: []Setting{{Key: TimezoneKey, Val: "UTC+05:30"}}, State: StateOK}
	if z := f.Timezone(); z != 5*3600+30*60 {
		t.Fatalf("persisted timezone = %d, want 19800", z)
	}
	if z := (File{State: StateMissing}).Timezone(); z != clockfmt.UTC {
		t.Fatalf("absent timezone = %d, want UTC", z)
	}
	bad := File{Rows: []Setting{{Key: TimezoneKey, Val: "Europe/Nowhere"}}, State: StateOK}
	if z := bad.Timezone(); z != clockfmt.UTC {
		t.Fatalf("invalid persisted timezone = %d, want the UTC fallback", z)
	}
	rows, ok := Parse(Render(f.Display()))
	if !ok {
		t.Fatal("GOSET display cannot round-trip via the safe codec")
	}
	if v, found := Get(rows, TimezoneKey); !found || v != "UTC+05:30" {
		t.Fatalf("round-trip timezone = %q found=%v", v, found)
	}
}

// M99d (#2182): the notification-chime row is accepted-but-unseeded like
// notify_dnd and strict like it — a typo falls back to the default (on), so
// a bad value can never silence the chime by accident.
func TestNotifySoundAcceptedUnseededCyclableAndStrict(t *testing.T) {
	if _, known := Known(NotifySoundKey); known {
		t.Fatal("the kernel does not seed notify_sound")
	}
	if !Editable(NotifySoundKey) || !IsNotifySoundKey(NotifySoundKey) || IsNotifySoundKey("notify") {
		t.Fatal("GOSET must be able to edit exactly notify_sound")
	}
	if got, ok := Default(NotifySoundKey); !ok || got != "on" {
		t.Fatalf("Default(notify_sound) = (%q,%v), want (on,true)", got, ok)
	}
	vocab, ok := Vocab(NotifySoundKey)
	if !ok || len(vocab) != 2 || vocab[0] != "on" || vocab[1] != "off" {
		t.Fatalf("notify_sound vocab = %v ok=%v, want [on off]", vocab, ok)
	}
	if got := Next(vocab, "off"); got != "on" {
		t.Fatalf("cycle off -> %q, want on", got)
	}
	for val, want := range map[string]bool{"on": true, "off": false} {
		if on, ok := NotifySound(val); !ok || on != want {
			t.Errorf("NotifySound(%q) = (%v, %v), want (%v, true)", val, on, ok, want)
		}
	}
	for _, val := range []string{"", "ON", "true", "1", "yes", "on ", "loud"} {
		if on, ok := NotifySound(val); ok || on {
			t.Errorf("NotifySound(%q) = (%v, %v), want (false, false)", val, on, ok)
		}
	}
	// Absent means on: the value in force for a default table is the chime.
	if v, ok := (File{State: StateMissing}).Effective(NotifySoundKey); !ok || v != "on" {
		t.Fatalf("absent notify_sound = %q ok=%v, want on", v, ok)
	}
	f := File{Rows: []Setting{{Key: NotifySoundKey, Val: "off"}}, State: StateOK}
	if v, ok := f.Effective(NotifySoundKey); !ok || v != "off" {
		t.Fatalf("persisted notify_sound = %q ok=%v", v, ok)
	}
	if rows, ok := Parse(Render(f.Rows)); !ok {
		t.Fatal("a persisted notify_sound row cannot round-trip")
	} else if v, found := Get(rows, NotifySoundKey); !found || v != "off" {
		t.Fatalf("round-trip notify_sound = %q found=%v", v, found)
	}
}

// M99d (#2182): the stream-gain row is accepted-but-unseeded, carries the
// 0..100 bound slot 44 enforces, and is the one row Set applies live — the
// same shape as the kernel set()'s own per-key hooks.
func TestAudioVolumeAcceptedUnseededBoundedAndLiveApplied(t *testing.T) {
	if _, known := Known(AudioVolumeKey); known {
		t.Fatal("the kernel does not seed audio_volume")
	}
	if !Editable(AudioVolumeKey) || !IsVolumeKey(AudioVolumeKey) || IsVolumeKey("volume") {
		t.Fatal("GOSET must be able to edit exactly audio_volume")
	}
	if got, ok := Default(AudioVolumeKey); !ok || got != "100" {
		t.Fatalf("Default(audio_volume) = (%q,%v), want (100,true)", got, ok)
	}
	for _, val := range []string{"0", "1", "40", "100", "007"} {
		if _, ok := AudioVolume(val); !ok {
			t.Errorf("AudioVolume(%q) refused a value slot 44 takes", val)
		}
	}
	for _, val := range []string{"", "101", "255", "-1", "1.5", "loud", "1000", "0x28"} {
		if _, ok := AudioVolume(val); ok {
			t.Errorf("AudioVolume(%q) accepted a value slot 44 refuses", val)
		}
	}
	vocab, ok := Vocab(AudioVolumeKey)
	if !ok || len(vocab) != 11 || vocab[0] != "0" || vocab[10] != "100" {
		t.Fatalf("audio_volume vocab = %v ok=%v, want the 0..100 decade ladder", vocab, ok)
	}
	if got := Next(vocab, "40"); got != "50" {
		t.Fatalf("cycle 40 -> %q, want 50", got)
	}
	// Out-of-vocabulary current value cycles to the top, matching every row.
	if got := Next(vocab, "abc"); got != "0" {
		t.Fatalf("cycle off-ladder -> %q, want 0", got)
	}
	f := File{Rows: []Setting{{Key: AudioVolumeKey, Val: "40"}}, State: StateOK}
	if v, ok := f.Effective(AudioVolumeKey); !ok || v != "40" {
		t.Fatalf("persisted audio_volume = %q ok=%v", v, ok)
	}
	if rows, ok := Parse(Render(f.Rows)); !ok {
		t.Fatal("a persisted audio_volume row cannot round-trip")
	} else if v, found := Get(rows, AudioVolumeKey); !found || v != "40" {
		t.Fatalf("round-trip audio_volume = %q found=%v", v, found)
	}
}

// The live-apply hook: writing audio_volume through Set — GOSET's typed
// input AND its row cycle both funnel here — pushes the value to slot 44 in
// the same call, and only a parseable in-range value applies. Other keys,
// and values the bound refuses, never reach the kernel.
func TestSetAppliesAudioVolumeToSlot44(t *testing.T) {
	saved := AudioVolumeApply
	defer func() { AudioVolumeApply = saved }()
	var got []int
	fail := false
	AudioVolumeApply = func(vol int) (int, error) {
		got = append(got, vol)
		if fail {
			return 0, errors.New("kernel refused")
		}
		return vol, nil
	}
	rows := Set(nil, AudioVolumeKey, "40")
	if len(got) != 1 || got[0] != 40 {
		t.Fatalf("set applied %v, want [40]", got)
	}
	if v, _ := Get(rows, AudioVolumeKey); v != "40" {
		t.Fatalf("row = %q, want 40", v)
	}
	// The row lands even when the kernel refuses — the write is the store,
	// the apply is best-effort like the kernel's own hooks.
	fail = true
	rows = Set(rows, AudioVolumeKey, "60")
	if v, _ := Get(rows, AudioVolumeKey); v != "60" || len(got) != 2 {
		t.Fatalf("refused apply lost the row or retried: %q applied=%v", v, got)
	}
	// Unparsable and out-of-range values write the row but apply nothing —
	// the row's readers refuse them the same way.
	for _, val := range []string{"101", "loud", ""} {
		rows = Set(rows, AudioVolumeKey, val)
	}
	if len(got) != 2 {
		t.Fatalf("out-of-range values applied: %v", got)
	}
	// Other keys never touch the seam.
	Set(rows, "theme", "light")
	Set(rows, NotifySoundKey, "off")
	if len(got) != 2 {
		t.Fatalf("a non-volume key applied: %v", got)
	}
}

// M100f (#2311): data_root is an accepted-but-unseeded row that is NOT
// display-materialized (the M99d chime/gain shape — a default GOSET save
// must stay byte-identical), cycles host|disk once it exists, and is strict
// about its vocabulary.
func TestDataRootAcceptedUnseededCyclableAndStrict(t *testing.T) {
	if _, known := Known(DataRootKey); known {
		t.Fatal("the kernel does not seed data_root")
	}
	if !Editable(DataRootKey) || !IsDataRootKey(DataRootKey) || IsDataRootKey("data") {
		t.Fatal("GOSET must be able to edit exactly data_root")
	}
	if got, ok := Default(DataRootKey); !ok || got != "host" {
		t.Fatalf("Default(data_root) = (%q,%v), want (host,true)", got, ok)
	}
	vocab, ok := Vocab(DataRootKey)
	if !ok || len(vocab) != 2 || vocab[0] != "host" || vocab[1] != "disk" {
		t.Fatalf("data_root vocab = %v ok=%v, want [host disk]", vocab, ok)
	}
	if got := Next(vocab, "host"); got != "disk" {
		t.Fatalf("cycle host -> %q, want disk", got)
	}
	if got := Next(vocab, "disk"); got != "host" {
		t.Fatalf("cycle disk -> %q, want host", got)
	}
	for _, val := range []string{"host", "disk"} {
		if !ValidDataRoot(val) {
			t.Errorf("ValidDataRoot(%q) = false", val)
		}
	}
	for _, val := range []string{"", "DISK", "usb", "/disk", "on", " disk"} {
		if ValidDataRoot(val) {
			t.Errorf("ValidDataRoot(%q) = true", val)
		}
	}
	// Never a default panel row: an absent file's display carries no
	// data_root, and a file that carries one round-trips it.
	if _, found := Get((File{State: StateMissing}).Display(), DataRootKey); found {
		t.Fatal("a default display materialized data_root")
	}
	f := File{Rows: []Setting{{Key: DataRootKey, Val: "disk"}}, State: StateOK}
	if v, ok := f.Effective(DataRootKey); !ok || v != "disk" {
		t.Fatalf("persisted data_root = %q ok=%v", v, ok)
	}
	if rows, ok := Parse(Render(f.Display())); !ok {
		t.Fatal("a set data_root row cannot round-trip")
	} else if v, found := Get(rows, DataRootKey); !found || v != "disk" {
		t.Fatalf("round-trip data_root = %q found=%v", v, found)
	}
}

// M165b (#2983): the a11y trio — accepted-but-unseeded, cyclable, strict
// parsers, never a default panel row. Each materializes once set and
// round-trips like audio_volume.
func TestA11yKeysAcceptedUnseededCyclableAndStrict(t *testing.T) {
	for _, key := range []string{A11yContrastKey, A11yReduceMotionKey, A11yTextScaleKey} {
		if _, known := Known(key); known {
			t.Fatalf("the kernel does not seed %s", key)
		}
		if !Editable(key) || !IsA11yKey(key) {
			t.Fatalf("GOSET must be able to edit %s", key)
		}
		if _, found := Get((File{State: StateMissing}).Display(), key); found {
			t.Fatalf("a default display materialized %s", key)
		}
	}
	if IsA11yKey("a11y") || IsA11yKey("contrast") {
		t.Fatal("IsA11yKey matched a non-a11y row")
	}

	// contrast: off|high, nothing else.
	if got, ok := Default(A11yContrastKey); !ok || got != "off" {
		t.Fatalf("Default(a11y.contrast) = (%q,%v), want (off,true)", got, ok)
	}
	if high, ok := A11yContrast("high"); !ok || !high {
		t.Fatal("A11yContrast(high) refused")
	}
	if high, ok := A11yContrast("off"); !ok || high {
		t.Fatal("A11yContrast(off) refused or read high")
	}
	for _, val := range []string{"", "on", "HIGH", "max", " high"} {
		if _, ok := A11yContrast(val); ok {
			t.Errorf("A11yContrast(%q) accepted", val)
		}
	}
	vocab, ok := Vocab(A11yContrastKey)
	if !ok || len(vocab) != 2 || vocab[0] != "off" || vocab[1] != "high" {
		t.Fatalf("a11y.contrast vocab = %v ok=%v, want [off high]", vocab, ok)
	}
	if got := Next(vocab, "off"); got != "high" {
		t.Fatalf("cycle off -> %q, want high", got)
	}
	if got := Next(vocab, "high"); got != "off" {
		t.Fatalf("cycle high -> %q, want off", got)
	}

	// reduce_motion: off|on, the notify_dnd grammar.
	if got, ok := Default(A11yReduceMotionKey); !ok || got != "off" {
		t.Fatalf("Default(a11y.reduce_motion) = (%q,%v), want (off,true)", got, ok)
	}
	if on, ok := A11yReduceMotion("on"); !ok || !on {
		t.Fatal("A11yReduceMotion(on) refused")
	}
	if on, ok := A11yReduceMotion("off"); !ok || on {
		t.Fatal("A11yReduceMotion(off) refused or read on")
	}
	for _, val := range []string{"", "yes", "1", "on "} {
		if _, ok := A11yReduceMotion(val); ok {
			t.Errorf("A11yReduceMotion(%q) accepted", val)
		}
	}
	vocab, ok = Vocab(A11yReduceMotionKey)
	if !ok || len(vocab) != 2 || vocab[0] != "off" || vocab[1] != "on" {
		t.Fatalf("a11y.reduce_motion vocab = %v ok=%v, want [off on]", vocab, ok)
	}

	// text_scale: the three reserved rungs.
	if got, ok := Default(A11yTextScaleKey); !ok || got != "100" {
		t.Fatalf("Default(a11y.text_scale) = (%q,%v), want (100,true)", got, ok)
	}
	for _, val := range []string{"100", "125", "150"} {
		if _, ok := A11yTextScale(val); !ok {
			t.Errorf("A11yTextScale(%q) refused", val)
		}
	}
	for _, val := range []string{"", "0", "110", "200", "1.25", " 100"} {
		if _, ok := A11yTextScale(val); ok {
			t.Errorf("A11yTextScale(%q) accepted", val)
		}
	}
	vocab, ok = Vocab(A11yTextScaleKey)
	if !ok || len(vocab) != 3 || vocab[0] != "100" || vocab[2] != "150" {
		t.Fatalf("a11y.text_scale vocab = %v ok=%v, want [100 125 150]", vocab, ok)
	}
	if got := Next(vocab, "100"); got != "125" {
		t.Fatalf("cycle 100 -> %q, want 125", got)
	}

	// The panel-side validator is the typed-input gate for all three.
	for _, bad := range []string{"a11y.contrast=on", "a11y.reduce_motion=high", "a11y.text_scale=200"} {
		key, val, _ := strings.Cut(bad, "=")
		if ValidA11y(key, val) {
			t.Errorf("ValidA11y(%q) accepted", bad)
		}
	}

	// Persisted once set: a file carrying the trio round-trips them.
	f := File{Rows: []Setting{
		{Key: A11yContrastKey, Val: "high"},
		{Key: A11yReduceMotionKey, Val: "on"},
		{Key: A11yTextScaleKey, Val: "150"},
	}, State: StateOK}
	for _, want := range []string{"a11y.contrast=high", "a11y.reduce_motion=on", "a11y.text_scale=150"} {
		key, val, _ := strings.Cut(want, "=")
		if v, ok := f.Effective(key); !ok || v != val {
			t.Fatalf("persisted %s = %q ok=%v, want %q", key, v, ok, val)
		}
	}
	if rows, ok := Parse(Render(f.Rows)); !ok {
		t.Fatal("the a11y rows cannot round-trip")
	} else {
		for _, want := range []string{"a11y.contrast=high", "a11y.reduce_motion=on", "a11y.text_scale=150"} {
			key, val, _ := strings.Cut(want, "=")
			if v, found := Get(rows, key); !found || v != val {
				t.Fatalf("round-trip %s = %q found=%v", key, v, found)
			}
		}
	}
}

// M183a (#3171): the union is 24 rows — no longer the cap. A file carrying
// the union PLUS overflow rows up to MaxKeys loads intact (and stays far
// under MaxBody, the card's condition for leaving the byte bound alone);
// the row past the cap is still the one that drops. And a table under the
// row cap whose rendered body exceeds MaxBody is refused by Save — the
// kernel's stat gate would refuse that file WHOLE, so the panel must not
// publish it.
func TestFullUnionPlusOverflowFitsTheCapAndTheBody(t *testing.T) {
	var rows []Setting
	for _, k := range KnownKeys {
		rows = append(rows, Setting{Key: k.Name, Val: k.Default})
	}
	for _, group := range [][]Key{
		PaletteKeys, FontKeys, KeyboardLayoutKeys, IdleKeys, NotifyKeys,
		NotifySoundKeys, VolumeKeys, TimezoneKeys, DataRootKeys, A11yKeys,
	} {
		for _, k := range group {
			rows = append(rows, Setting{Key: k.Name, Val: k.Default})
		}
	}
	// term_restart is kernel-accepted but unknown to this codec — it is a
	// real row a file can carry, so the union includes it.
	rows = append(rows, Setting{Key: "term_restart", Val: "stay"})
	if len(rows) != 24 {
		t.Fatalf("the known union is %d rows, want the pinned wave-5 census of 24", len(rows))
	}
	body := Render(rows)
	if len(body) > MaxBody {
		t.Fatalf("the full union renders %d bytes, over MaxBody %d", len(body), MaxBody)
	}
	decoded, ok := Parse(body)
	if !ok || len(decoded) != 24 {
		t.Fatalf("the union dropped a row: rows=%d ok=%v", len(decoded), ok)
	}
	// Bank two: union + overflow rows up to MaxKeys all survive the parse.
	for len(rows) < MaxKeys {
		rows = append(rows, Setting{Key: "overflow" + strconv.Itoa(len(rows)), Val: "v"})
	}
	body = Render(rows)
	if len(body) > MaxBody {
		t.Fatalf("union + overflow renders %d bytes, over MaxBody %d", len(body), MaxBody)
	}
	decoded, ok = Parse(body)
	if !ok || len(decoded) != MaxKeys {
		t.Fatalf("the full table dropped a row at the new cap: rows=%d ok=%v", len(decoded), ok)
	}
	last := "overflow" + strconv.Itoa(MaxKeys-1)
	if v, found := Get(decoded, last); !found || v != "v" {
		t.Fatalf("the last overflow row = %q found=%v", v, found)
	}
	// And the row past the cap is the one that drops.
	decoded, ok = Parse(append(body, []byte("one_too_many=v\n")...))
	if !ok || len(decoded) != MaxKeys {
		t.Fatalf("over-cap load = %d rows ok=%v, want the capped %d", len(decoded), ok, MaxKeys)
	}
	// A table under the row cap but over the byte bound refuses to publish:
	// SaveFull, not a file the kernel would reject whole at boot.
	var fat []Setting
	for i := 0; i < MaxKeys/2; i++ {
		fat = append(fat, Setting{
			Key: strings.Repeat("k", MaxKey-4) + strconv.Itoa(i),
			Val: strings.Repeat("x", MaxVal),
		})
	}
	if len(Render(fat)) <= MaxBody {
		t.Fatal("the fat fixture does not exceed MaxBody")
	}
	if rc := (File{Rows: fat, State: StateOK}).Save(); rc != SaveFull {
		t.Fatalf("over-byte-cap save rc = %d, want SaveFull %d", rc, SaveFull)
	}
}

// M100f (#2311): the resolver's three legs — the default boot reads /host
// untouched, an opted-in row with a mounted volume reads /disk, and the
// set-but-absent shape is a NAMED fallback (fellBack) that still answers
// /host rather than failing.
func TestResolveDataRootLegs(t *testing.T) {
	saved := DiskMounted
	defer func() { DiskMounted = saved }()

	diskFile := File{Rows: []Setting{{Key: DataRootKey, Val: "disk"}}, State: StateOK}

	DiskMounted = func() bool { return true }
	for _, f := range []File{
		{State: StateMissing},
		{State: StateCorrupt},
		{Rows: []Setting{{Key: DataRootKey, Val: "host"}}, State: StateOK},
		{Rows: []Setting{{Key: DataRootKey, Val: "florp"}}, State: StateOK},
	} {
		if root, fb := f.ResolveDataRoot(); root != DataRootHost || fb {
			t.Fatalf("state=%d root=%q fellBack=%v, want /host without a fallback note", f.State, root, fb)
		}
	}
	if root, fb := diskFile.ResolveDataRoot(); root != DataRootDisk || fb {
		t.Fatalf("mounted opt-in root=%q fellBack=%v, want /disk", root, fb)
	}

	DiskMounted = func() bool { return false }
	if root, fb := diskFile.ResolveDataRoot(); root != DataRootHost || !fb {
		t.Fatalf("unmounted opt-in root=%q fellBack=%v, want /host + the named fallback", root, fb)
	}
}
