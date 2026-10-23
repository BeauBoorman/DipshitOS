package appkit

import (
	"errors"
	"os"
	"testing"

	"virelai/layout"
	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

// keyUnder is the Key a hosted app receives for a physical key under a layout:
// the kernel's usage and translated symbol, normalized the way the app's event
// loop does. A dead key has no symbol, so its Rune is 0.
func keyUnder(id layout.ID, usage uint8, shift bool) Key {
	var sym uint32
	if r, ok := layout.Translate(id, usage, shift); ok {
		sym = uint32(r)
	}
	var flags uint16
	if shift {
		flags = vi.ModShift
	}
	k, _ := NormalizeKey(keyEvent(uint32(usage), sym, flags))
	return k
}

const (
	usageE     = 0x08
	usageX     = 0x1b
	usageAcute = 0x2e // DE dead acute; Shift is dead grave
	usageCirc  = 0x35 // DE dead circumflex
	usageEnter = 0x28
	usageEsc   = 0x29
	usageBksp  = 0x2a
	usageSpace = 0x2c
	usageLeft  = 0x50
)

func deField(max int) *TextField {
	f := NewTextField(widgets.Rect{X: 0, Y: 0, W: 200, H: 20}, max)
	f.SetLayout(layout.DE)
	return &f
}

func TestTextFieldComposesADeadKeyAndShowsItPending(t *testing.T) {
	f := deField(16)
	f.OnKey(keyUnder(layout.DE, usageX, false))
	if !f.OnKey(keyUnder(layout.DE, usageAcute, false)) {
		t.Fatal("staging a dead key changes what the field shows, so it must report a change")
	}
	if f.Value() != "x" || f.Preedit() != "'" {
		t.Fatalf("after the dead key value=%q preedit=%q, want the accent pending and not yet typed", f.Value(), f.Preedit())
	}
	if !f.OnKey(keyUnder(layout.DE, usageE, false)) {
		t.Fatal("composing must report a change")
	}
	if f.Value() != "xé" || f.Preedit() != "" || f.CaretPosition() != len("xé") {
		t.Fatalf("value=%q preedit=%q caret=%d, want the composed é typed at the caret", f.Value(), f.Preedit(), f.CaretPosition())
	}
	// Shift on the dead key is the grave; the circumflex key is dead even
	// though the kernel translated it to a literal '^'.
	f.OnKey(keyUnder(layout.DE, usageAcute, true))
	f.OnKey(keyUnder(layout.DE, usageE, false))
	f.OnKey(keyUnder(layout.DE, usageCirc, false))
	f.OnKey(keyUnder(layout.DE, 0x12, false))
	if f.Value() != "xéèô" {
		t.Fatalf("value = %q, want xéèô", f.Value())
	}
}

func TestTextFieldStrayCombinationTypesBothCharacters(t *testing.T) {
	f := deField(16)
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	if !f.OnKey(keyUnder(layout.DE, usageX, false)) || f.Value() != "´x" {
		t.Fatalf("value = %q, want the literal accent then the x", f.Value())
	}
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	f.OnKey(keyUnder(layout.DE, usageSpace, false))
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	if f.Value() != "´x´´" {
		t.Fatalf("value = %q, want the bare accent from dead+space and dead+dead", f.Value())
	}
}

func TestTextFieldKeysThatEndASequenceStillDoTheirJob(t *testing.T) {
	f := deField(16)
	f.SetValue("ac")
	f.OnKey(Key{Usage: usageLeft})
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	if !f.OnKey(keyUnder(layout.DE, usageLeft, false)) {
		t.Fatal("the arrow is the field's own key, so it is consumed")
	}
	if f.Value() != "a´c" || f.CaretPosition() != 1 {
		t.Fatalf("value=%q caret=%d, want the accent typed at the old caret and the caret one rune left of it", f.Value(), f.CaretPosition())
	}

	// Enter and Escape are the caller's keys: the accent is typed, and the
	// field reports the key unconsumed so the caller can act on it.
	for _, u := range []uint8{usageEnter, usageEsc} {
		g := deField(16)
		g.OnKey(keyUnder(layout.DE, usageAcute, false))
		if g.OnKey(keyUnder(layout.DE, u, false)) {
			t.Errorf("usage %#x must not be consumed", u)
		}
		if g.Value() != "´" || g.Preedit() != "" {
			t.Errorf("usage %#x: value=%q preedit=%q, want the literal typed", u, g.Value(), g.Preedit())
		}
	}
}

func TestTextFieldBackspaceCancelsTheStagedAccent(t *testing.T) {
	f := deField(16)
	f.SetValue("ab")
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	if !f.OnKey(keyUnder(layout.DE, usageBksp, false)) {
		t.Fatal("dropping the staged accent is a visible change")
	}
	if f.Value() != "ab" || f.Preedit() != "" {
		t.Fatalf("value=%q preedit=%q, want the text untouched and nothing pending", f.Value(), f.Preedit())
	}
	// The next Backspace is an ordinary one.
	f.OnKey(keyUnder(layout.DE, usageBksp, false))
	if f.Value() != "a" {
		t.Fatalf("value = %q", f.Value())
	}
}

func TestTextFieldLosingFocusOrClickTypesTheStagedAccent(t *testing.T) {
	f := deField(16)
	f.SetFocused(true)
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	f.SetFocused(false)
	if f.Value() != "´" || f.Preedit() != "" {
		t.Fatalf("blur: value=%q preedit=%q", f.Value(), f.Preedit())
	}

	f.OnKey(keyUnder(layout.DE, usageAcute, true))
	if !f.OnClick(1, 1) || f.Value() != "´`" {
		t.Fatalf("click: value=%q, want the grave typed", f.Value())
	}

	// Tab moves focus through the ring, which blurs the field: the same rule.
	a, b := deField(16), deField(16)
	ring := NewFocusRing(a, b)
	ring.Next()
	a.OnKey(keyUnder(layout.DE, usageCirc, false))
	if !ring.HandleKey(Key{Usage: 0x2b}) || a.Value() != "^" {
		t.Fatalf("tab away: value=%q, want the circumflex typed", a.Value())
	}

	// Programmatic edits drop a stage that no longer follows the text.
	c := deField(16)
	c.OnKey(keyUnder(layout.DE, usageAcute, false))
	c.SetValue("new")
	if c.Preedit() != "" || c.Value() != "new" {
		t.Fatalf("SetValue: value=%q preedit=%q", c.Value(), c.Preedit())
	}
	c.OnKey(keyUnder(layout.DE, usageAcute, false))
	c.Clear()
	if c.Preedit() != "" || c.Value() != "" {
		t.Fatalf("Clear: value=%q preedit=%q", c.Value(), c.Preedit())
	}
}

func TestTextFieldWithoutDeadKeysIsUnchanged(t *testing.T) {
	// Under US the same physical key is '=', and it must simply type.
	for _, id := range []layout.ID{"", layout.US} {
		f := NewTextField(widgets.Rect{W: 100, H: 20}, 8)
		f.SetLayout(id)
		f.OnKey(keyUnder(layout.US, usageAcute, false))
		f.OnKey(keyUnder(layout.US, usageE, false))
		if f.Value() != "=e" || f.Preedit() != "" {
			t.Errorf("layout %q: value=%q preedit=%q, want =e", id, f.Value(), f.Preedit())
		}
	}
	// A layout key the kernel already translated (DE's ö) is plain text.
	f := deField(8)
	f.OnKey(keyUnder(layout.DE, 0x33, false))
	if f.Value() != "ö" {
		t.Fatalf("value = %q", f.Value())
	}
}

func TestTextFieldHoldsUTF8WithoutSplittingARune(t *testing.T) {
	f := deField(5)
	for _, r := range "aéb" {
		if !f.OnKey(Key{Rune: r}) {
			t.Fatalf("insert %q", r)
		}
	}
	if f.Value() != "aéb" || f.CaretPosition() != 4 {
		t.Fatalf("value=%q caret=%d", f.Value(), f.CaretPosition())
	}
	// Left, Right, Delete and Backspace all move by whole runes.
	f.OnKey(Key{Usage: 0x50})
	f.OnKey(Key{Usage: 0x50})
	if f.CaretPosition() != 1 {
		t.Fatalf("two lefts from the end: caret=%d, want 1 (before é)", f.CaretPosition())
	}
	f.OnKey(Key{Usage: 0x4f})
	if f.CaretPosition() != 3 {
		t.Fatalf("right over é: caret=%d, want 3", f.CaretPosition())
	}
	f.OnKey(Key{Usage: 0x2a})
	if f.Value() != "ab" || f.CaretPosition() != 1 {
		t.Fatalf("backspace over é: value=%q caret=%d", f.Value(), f.CaretPosition())
	}
	f.SetValue("aéb")
	f.OnKey(Key{Usage: 0x4a})
	f.OnKey(Key{Usage: 0x4f})
	f.OnKey(Key{Usage: 0x4c})
	if f.Value() != "ab" {
		t.Fatalf("delete over é: value=%q", f.Value())
	}

	// The byte bound refuses a rune that does not fit, whole.
	g := deField(4)
	g.SetValue("abc")
	if g.OnKey(Key{Rune: 'é'}) || g.Value() != "abc" || g.CaretPosition() != 3 {
		t.Fatalf("value=%q caret=%d, want é refused with the field untouched", g.Value(), g.CaretPosition())
	}
	// SetValue clips to a rune boundary, never through a rune.
	g.SetValue("abé")
	if g.Value() != "abé" {
		t.Fatalf("value = %q", g.Value())
	}
	g.SetValue("aébé")
	if g.Value() != "aéb" {
		t.Fatalf("clipped value = %q, want aéb (é would have been cut in half)", g.Value())
	}
	// Control codes and C1 controls are not text.
	if g.OnKey(Key{Rune: 0x85}) || g.OnKey(Key{Rune: 0x1b}) {
		t.Fatal("control runes must not be typed")
	}
}

func TestTextFieldComposedCharacterThatDoesNotFitIsRefusedNotTruncated(t *testing.T) {
	f := deField(2)
	f.SetValue("ab")
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	f.OnKey(keyUnder(layout.DE, usageE, false))
	if f.Value() != "ab" || f.Preedit() != "" {
		t.Fatalf("value=%q preedit=%q, want a full field left as it was", f.Value(), f.Preedit())
	}
}

type fill struct {
	r   widgets.Rect
	rgb uint32
}

type recCanvas struct{ fills []fill }

func (c *recCanvas) FillRect(r widgets.Rect, rgb uint32) { c.fills = append(c.fills, fill{r, rgb}) }

func (c *recCanvas) within(rgb uint32, x0, x1, y0, y1 int) int {
	n := 0
	for _, f := range c.fills {
		if f.rgb == rgb && f.r.X >= x0 && f.r.X < x1 && f.r.Y >= y0 && f.r.Y < y1 {
			n++
		}
	}
	return n
}

func (c *recCanvas) has(r widgets.Rect, rgb uint32) bool {
	for _, f := range c.fills {
		if f.r == r && f.rgb == rgb {
			return true
		}
	}
	return false
}

func TestTextFieldPaintsThePendingAccentAtTheCaret(t *testing.T) {
	const fg, accent = 0xe6edf3, 0xffd75f
	f := deField(16)
	f.Fg, f.Caret = fg, accent
	f.SetFocused(true)
	f.SetValue("ab")
	f.OnKey(Key{Usage: usageLeft})

	// Without a pending accent the caret sits after the "a" (cell 1), where the
	// buffer's caret is, and nothing is drawn in the accent colour but it.
	var c recCanvas
	f.Draw(&c)
	if !c.has(widgets.Rect{X: 2 + 8, Y: 2, W: 2, H: 16}, accent) {
		t.Fatalf("caret not at cell 1: %+v", c.fills)
	}
	if n := c.within(accent, 0, 200, 0, 20); n != 1 {
		t.Fatalf("%d accent-coloured fills with nothing pending, want only the caret", n)
	}

	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	c = recCanvas{}
	f.Draw(&c)
	// Cell 1 holds the mark: accent glyph pixels and an underline one row under
	// the glyph (centred in the inset plate: glyph rows 6..13, underline row 14).
	if c.within(accent, 10, 18, 6, 14) == 0 {
		t.Fatal("no accent-coloured glyph pixels in the pending cell")
	}
	if !c.has(widgets.Rect{X: 10, Y: 14, W: 8, H: 1}, accent) {
		t.Fatalf("no underline under the pending cell: %+v", c.fills)
	}
	// The text before stays in cell 0, and the "b" has moved right to cell 2.
	if c.within(fg, 2, 10, 0, 20) == 0 || c.within(fg, 18, 26, 0, 20) == 0 {
		t.Fatal("text before or after the accent is missing")
	}
	if c.within(fg, 10, 18, 0, 20) != 0 {
		t.Fatal("text was painted over the pending cell")
	}
	// The caret follows the pending cell.
	if !c.has(widgets.Rect{X: 2 + 16, Y: 2, W: 2, H: 16}, accent) {
		t.Fatalf("caret did not move past the pending accent: %+v", c.fills)
	}

	// Composing removes the mark and types the character in its place.
	f.OnKey(keyUnder(layout.DE, usageE, false))
	c = recCanvas{}
	f.Draw(&c)
	if c.has(widgets.Rect{X: 10, Y: 14, W: 8, H: 1}, accent) {
		t.Fatal("underline outlived the pending accent")
	}
}

// --- romaji->kana composition (M178b #3145) --------------------------------

// imeField is a field with the composition composer armed, the way an
// adopting app sets it up.
func imeField(max int) *TextField {
	f := NewTextField(widgets.Rect{X: 0, Y: 0, W: 200, H: 20}, max)
	f.IME = &layout.IME{}
	return &f
}

// typeText feeds printable keys the way the event loop normalizes them.
func typeText(f *TextField, s string) {
	for _, r := range s {
		f.OnKey(Key{Usage: 0x04, Rune: r})
	}
}

func TestTextFieldIMEToggleComposesAndCommits(t *testing.T) {
	f := imeField(64)
	var toggles []bool
	var commits []string
	f.OnIMEToggle = func(on bool) { toggles = append(toggles, on) }
	f.OnIMECommit = func(s string) { commits = append(commits, s) }

	if !f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true}) || !f.Composing() {
		t.Fatal("the toggle chord must arm composition")
	}
	if len(toggles) != 1 || !toggles[0] {
		t.Fatalf("toggles = %v, want [true]", toggles)
	}
	typeText(f, "nihongo")
	if f.Preedit() != "にほんご" || f.Value() != "" {
		t.Fatalf("preedit=%q value=%q, want the staged kana and an empty value", f.Preedit(), f.Value())
	}
	// Return commits the shown form and is consumed — the field's caller
	// must not also see the Enter.
	if !f.OnKey(Key{Usage: usageEnter}) {
		t.Fatal("Return while composing must be consumed")
	}
	if f.Value() != "にほんご" || f.Preedit() != "" {
		t.Fatalf("value=%q preedit=%q, want the committed kana", f.Value(), f.Preedit())
	}
	if len(commits) != 1 || commits[0] != "にほんご" {
		t.Fatalf("commits = %v, want [にほんご]", commits)
	}
	// The next Return is the surface's own: unconsumed.
	if f.OnKey(Key{Usage: usageEnter}) {
		t.Fatal("Return on a settled field must pass through")
	}
	// Toggling back returns the field to the dead-key stage.
	if !f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true}) || f.Composing() {
		t.Fatal("the chord must toggle composition off")
	}
	if len(toggles) != 2 || toggles[1] {
		t.Fatalf("toggles = %v, want [true false]", toggles)
	}
	typeText(f, "x")
	if f.Value() != "にほんごx" || f.Preedit() != "" {
		t.Fatalf("after toggle off value=%q preedit=%q", f.Value(), f.Preedit())
	}
}

func TestTextFieldIMECycleEditCancel(t *testing.T) {
	f := imeField(64)
	f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true})
	typeText(f, "sushi")
	f.OnKey(Key{Usage: usageSpace, Rune: ' '})
	if f.Preedit() != "スシ" {
		t.Fatalf("cycle 1: %q, want スシ", f.Preedit())
	}
	f.OnKey(Key{Usage: usageSpace, Rune: ' '})
	if f.Preedit() != "sushi" {
		t.Fatalf("cycle 2: %q, want the raw romaji", f.Preedit())
	}
	// Backspace edits the romaji; Escape cancels the composition.
	f.OnKey(Key{Usage: usageBksp})
	if f.Preedit() != "sush" {
		t.Fatalf("backspace: %q", f.Preedit())
	}
	f.OnKey(Key{Usage: usageEsc})
	if f.Preedit() != "" || f.Value() != "" {
		t.Fatalf("escape must cancel: value=%q preedit=%q", f.Value(), f.Preedit())
	}
}

func TestTextFieldIMEToggleOffCommits(t *testing.T) {
	f := imeField(64)
	var commits []string
	f.OnIMECommit = func(s string) { commits = append(commits, s) }
	f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true})
	typeText(f, "ka")
	// The toggle-off commits the staged form — typed text is never
	// swallowed by a mode flip.
	f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true})
	if f.Value() != "か" || f.Preedit() != "" {
		t.Fatalf("value=%q preedit=%q, want the shown form committed", f.Value(), f.Preedit())
	}
	if len(commits) != 1 || commits[0] != "か" {
		t.Fatalf("commits = %v, want [か]", commits)
	}
	// Losing focus and clicks flush the composition the same way.
	f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true})
	typeText(f, "ki")
	f.SetFocused(false)
	if f.Value() != "かき" || f.Preedit() != "" {
		t.Fatalf("blur: value=%q", f.Value())
	}
	typeText(f, "ku")
	f.OnClick(1, 1)
	if f.Value() != "かきく" {
		t.Fatalf("click: value=%q", f.Value())
	}
}

func TestTextFieldWithoutIMEIgnoresTheChord(t *testing.T) {
	f := NewTextField(widgets.Rect{W: 100, H: 20}, 8)
	if f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true}) {
		t.Fatal("an unarmed field must not consume the chord")
	}
	if f.Composing() || f.Preedit() != "" {
		t.Fatal("an unarmed field must not compose")
	}
}

func TestTextFieldIMECommitReportsOnlyInsertedText(t *testing.T) {
	f := imeField(6) // room for two kana, not three
	var commits []string
	f.OnIMECommit = func(s string) { commits = append(commits, s) }
	f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true})
	typeText(f, "nihongo")
	f.OnKey(Key{Usage: usageEnter})
	// にほんご is 9 bytes over a 6-byte bound: the marker reports what the
	// field actually took, not what the composer produced.
	if len(commits) != 1 || commits[0] != "にほ" {
		t.Fatalf("commits = %v, want the inserted prefix [にほ]", commits)
	}
	if f.Value() != "にほ" {
		t.Fatalf("value = %q", f.Value())
	}
}

func TestTextFieldCandidatesPaintUnderTheField(t *testing.T) {
	const fg, accent = 0xe6edf3, 0xffd75f
	f := imeField(64)
	f.Fg, f.Caret = fg, accent
	f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true})
	typeText(f, "sushi")
	var c recCanvas
	f.Draw(&c)
	// The three forms paint below the plate, the shown (hiragana) one in
	// the accent colour with an underline.
	if n := c.within(fg, 0, 200, 20, 40); n == 0 {
		t.Fatal("the unselected forms did not paint under the field")
	}
	if n := c.within(accent, 0, 200, 20, 40); n < 2 {
		t.Fatalf("the shown form and its underline must paint under the field: %d fills", n)
	}
	// Settled text paints nothing below the plate.
	f.OnKey(Key{Usage: usageEnter})
	c = recCanvas{}
	f.Draw(&c)
	if n := c.within(fg, 0, 200, 20, 40); n != 0 {
		t.Fatalf("a settled field still shows %d fills below the plate", n)
	}
}

// chainField builds a field whose text paints through a real cascade:
// Inter as the ui primary, the JP face via the symbol consult — the same
// resolution FONTS.TXT gives the guest.
func chainField(t *testing.T, max int) *TextField {
	t.Helper()
	files := map[string]string{
		"INTER.TTF":   "Inter-Regular.ttf",
		"NOTOCJK.TTF": "NotoSansJP-Regular.ttf",
	}
	load := func(name string) (*ttf.Face, error) {
		src, ok := files[name]
		if !ok {
			return nil, errors.New("no such staged face")
		}
		data, err := os.ReadFile("../../../image/fonts/" + src)
		if err != nil {
			return nil, err
		}
		return ttf.Parse(data)
	}
	specs := []ttf.FaceSpec{
		{File: "INTER.TTF", Role: "ui", Order: 1, Weight: 400},
		{File: "NOTOCJK.TTF", Role: "symbol", Order: 2, Weight: 400},
	}
	reg := ttf.NewRegistry(specs, load)
	f := NewTextField(widgets.Rect{X: 0, Y: 0, W: 200, H: 26}, max)
	f.Chain = reg.Chain(ttf.Query{Role: "ui"})
	f.IME = &layout.IME{}
	if f.Chain == nil {
		t.Fatal("the fixture chain must resolve")
	}
	return &f
}

// fullCanvas is the recording Canvas the chain paint path needs: Text
// runs arrive as glyph blits (BlitTinted), never as Text calls.
type fullCanvas struct {
	fills []fill
	blits []fill
	texts []string
}

func (c *fullCanvas) FillRect(r widgets.Rect, rgb uint32) {
	c.fills = append(c.fills, fill{r, rgb})
}
func (c *fullCanvas) FillRoundedRect(r widgets.Rect, _ int, rgb uint32) {
	c.fills = append(c.fills, fill{r, rgb})
}
func (c *fullCanvas) StrokeRoundedRect(widgets.Rect, int, int, uint32) {}
func (c *fullCanvas) BlitTinted(src []uint32, w, h, x, y int, rgb uint32) {
	c.blits = append(c.blits, fill{widgets.Rect{X: x, Y: y, W: w, H: h}, rgb})
}
func (c *fullCanvas) Text(_ *ttf.Face, _ widgets.Rect, _, _, _ int, s string, _ uint32) {
	c.texts = append(c.texts, s)
}

func TestTextFieldPreeditPaintsThroughTheChain(t *testing.T) {
	f := chainField(t, 64)
	f.Caret = 0xffd75f
	f.SetFocused(true)
	f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true})
	typeText(f, "nihongo")
	var c fullCanvas
	f.Draw(&c)
	// The kana pre-edit resolves through the cascade to the JP face and
	// lands as real glyph masks — never as bitmap Text calls — and the
	// same cascade paints the candidate strip under the plate.
	if len(c.blits) == 0 {
		t.Fatal("no glyph blits: the chain did not paint the pre-edit")
	}
	if len(c.texts) != 0 {
		t.Fatalf("chain painting must not fall back to single-face Text: %v", c.texts)
	}
	var under bool
	for _, b := range c.blits {
		if b.r.Y >= f.R.Bottom() {
			under = true
		}
	}
	if !under {
		t.Fatal("the candidate forms did not paint under the field")
	}
	// Committing keeps painting through the chain — the kana in Value
	// resolve to the coverage face too.
	f.OnKey(Key{Usage: usageEnter})
	c = fullCanvas{}
	f.Draw(&c)
	if len(c.blits) == 0 || len(c.texts) != 0 {
		t.Fatalf("committed kana left the chain: blits=%d texts=%v", len(c.blits), c.texts)
	}
}

// A field armed but never chained keeps the single-face painter — the
// bitmap degrade path is the unchanged one from before the chain existed.
func TestTextFieldNoChainPaintsAsBefore(t *testing.T) {
	f := imeField(64)
	f.Fg, f.Caret = 0xe6edf3, 0xffd75f
	f.OnKey(Key{Usage: usageIMEToggle, Ctrl: true})
	typeText(f, "kana")
	var c recCanvas
	f.Draw(&c)
	// The bitmap path paints the pre-edit in cells with its underline
	// one row under the glyph, and the candidates below the plate.
	if c.within(f.Caret, 2, 50, 6, 14) == 0 {
		t.Fatal("no accent-coloured pre-edit in the plate")
	}
	if !c.has(widgets.Rect{X: 2, Y: 14, W: 16, H: 1}, f.Caret) {
		t.Fatalf("no underline under the pre-edit: %+v", c.fills)
	}
}

func TestTextFieldPlaceholderYieldsToAPendingAccent(t *testing.T) {
	const fg, accent = 0xe6edf3, 0xffd75f
	f := deField(16)
	f.Fg, f.Caret, f.Placeholder = fg, accent, "type here"
	var c recCanvas
	f.Draw(&c)
	if c.within(fg, 2, 200, 0, 20) == 0 {
		t.Fatal("empty field must paint its placeholder")
	}
	f.OnKey(keyUnder(layout.DE, usageAcute, false))
	c = recCanvas{}
	f.Draw(&c)
	if c.within(fg, 0, 200, 0, 20) != 0 {
		t.Fatal("the placeholder must not paint next to a pending accent")
	}
	if !c.has(widgets.Rect{X: 2, Y: 14, W: 8, H: 1}, accent) {
		t.Fatalf("no underline for the pending accent in an empty field: %+v", c.fills)
	}
}
