package main

import "testing"

// The M152c shelf: recents order/dedupe/bound, the favorites bound and
// toggle, the empty-query shelf rows (padding keeps each section on its
// own row), and the save_state v2 round trip plus the v1 decode.

func TestRecentsOrderDedupeBound(t *testing.T) {
	a := newApp()
	// Pick order 0,1,2,…,17 then re-pick 3: recents is most recent first,
	// the re-pick moves to the head, and the list stays inside the bound.
	for i := 0; i < shelfMax+2; i++ {
		a.noteRecent(i)
	}
	if len(a.recents) != shelfMax {
		t.Fatalf("recents bound: len=%d want %d", len(a.recents), shelfMax)
	}
	if a.recents[0] != shelfMax+1 || a.recents[1] != shelfMax {
		t.Fatalf("recents order: %v — want newest first", a.recents[:4])
	}
	// The two evicted oldest picks must be gone.
	for _, v := range a.recents {
		if v == 0 || v == 1 {
			t.Fatalf("recents %v still holds an evicted pick", a.recents)
		}
	}
	a.noteRecent(3)
	if a.recents[0] != 3 {
		t.Fatalf("re-pick did not move to the head: %v", a.recents[:4])
	}
	n := 0
	for _, v := range a.recents {
		if v == 3 {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("dedupe: recents %v holds %d copies of 3", a.recents, n)
	}
	if len(a.recents) != shelfMax {
		t.Fatalf("dedupe re-pick grew the list: %d", len(a.recents))
	}
}

// focusGlyph lands the selection on a real cell for glyph g (the grid's
// copy, not a shelf duplicate or a pad).
func focusGlyph(t *testing.T, a *app, g int) {
	t.Helper()
	for pos := len(a.matches) - 1; pos >= 0; pos-- {
		if a.matches[pos] == g {
			a.sel = pos
			return
		}
	}
	t.Fatalf("glyph %d has no cell in %v", g, a.matches)
}

func TestFavToggleBound(t *testing.T) {
	a := newApp()
	for i := 0; i < shelfMax; i++ {
		focusGlyph(t, a, i)
		if !a.toggleFav() {
			t.Fatalf("pin %d refused inside the bound", i)
		}
	}
	if len(a.favs) != shelfMax {
		t.Fatalf("favs len=%d want %d", len(a.favs), shelfMax)
	}
	// The next pin is refused: the bound holds, nothing is evicted.
	focusGlyph(t, a, shelfMax)
	if !a.toggleFav() {
		t.Fatal("pin over the bound must still consume the key")
	}
	if indexOfGlyph(a.favs, shelfMax) >= 0 {
		t.Fatalf("favs %v took a 17th pin", a.favs)
	}
	// Unpin frees the slot; re-pin lands at the tail (pin order).
	focusGlyph(t, a, 0)
	if !a.toggleFav() {
		t.Fatal("unpin refused")
	}
	if indexOfGlyph(a.favs, 0) >= 0 {
		t.Fatalf("favs %v still holds the unpinned cell", a.favs)
	}
	focusGlyph(t, a, 0)
	if !a.toggleFav() || a.favs[len(a.favs)-1] != 0 {
		t.Fatalf("re-pin did not land at the tail: %v", a.favs)
	}
}

func TestShelfRowsOnlyOnEmptyQuery(t *testing.T) {
	a := newApp()
	a.favs = []int{2}
	a.recents = []int{5, 1}
	a.refilter()
	// favs row: [2] + 5 pads; recents row: [5,1] + 4 pads; then the grid.
	want := []int{2, cellPad, cellPad, cellPad, cellPad, cellPad,
		5, 1, cellPad, cellPad, cellPad, cellPad}
	for i, v := range want {
		if a.matches[i] != v {
			t.Fatalf("shelf prefix at %d = %d, want %d (matches %v)", i, a.matches[i], v, a.matches[:len(want)])
		}
	}
	// The grid tail follows unmodified and row-aligned.
	for j, i := 0, len(want); j < len(glyphs); j++ {
		if a.matches[i+j] != j {
			t.Fatalf("grid tail at %d = %d, want %d", i+j, a.matches[i+j], j)
		}
	}
	if len(a.matches) != len(want)+len(glyphs) {
		t.Fatalf("matches len=%d want %d", len(a.matches), len(want)+len(glyphs))
	}
	// A live query hides the shelf entirely — the filter output is bare.
	a.field.SetValue("fire")
	a.refilter()
	if len(a.matches) != 1 || a.matches[0] != lookup(0x1F525) {
		t.Fatalf("query did not hide the shelf: %v", a.matches)
	}
}

func TestShelfPadsAreInert(t *testing.T) {
	a := newApp()
	a.recents = []int{1}
	a.refilter()
	// [1] + 5 pads + grid: Enter on a pad cell refuses, the arrows skip it.
	a.sel = 0
	if !a.moveSel(1) || a.sel != gridCols {
		t.Fatalf("right from the recents cell landed on %d, want the grid head %d", a.sel, gridCols)
	}
	a.sel = 1 // a pad position, forced
	if _, _, ok := a.pickText(); ok {
		t.Fatal("a pad cell must refuse the pick")
	}
}

func TestStateV2RoundTripShelf(t *testing.T) {
	a := newApp()
	a.tab = tabCompose
	a.stay = true
	a.favs = []int{lookup(0x2764), lookup(0x1F600)}
	a.recents = []int{lookup(0x1F525), lookup(0x2764)}
	a.field.SetValue("heart")
	b := a.saveState()

	c := newApp()
	c.restoreState(b, stateVerShelf)
	if c.tab != tabCompose || !c.stay || c.field.Value() != "heart" {
		t.Fatalf("v2 restore = tab %d stay %v q %q", c.tab, c.stay, c.field.Value())
	}
	if len(c.favs) != 2 || c.favs[0] != lookup(0x2764) || c.favs[1] != lookup(0x1F600) {
		t.Fatalf("favs round trip: %v", c.favs)
	}
	if len(c.recents) != 2 || c.recents[0] != lookup(0x1F525) || c.recents[1] != lookup(0x2764) {
		t.Fatalf("recents round trip: %v", c.recents)
	}
	// The restored empty-query Emoji tab shows the lists — back on the
	// grid tab with the query cleared, the shelf head is the favorite.
	c.tab = tabEmoji
	c.field.SetValue("")
	c.refilter()
	if c.matches[0] != lookup(0x2764) {
		t.Fatalf("restored shelf head = %d, want the favorite", c.matches[0])
	}
}

func TestStateV1Decodes(t *testing.T) {
	// A v1 blob — `tab | stay | query` — carries no shelf and must decode
	// under the v2 app with empty lists.
	c := newApp()
	c.restoreState([]byte{'2', '1', 'w', 'i', 'n', 'k'}, 1)
	if c.tab != tabKaomoji || !c.stay || c.field.Value() != "wink" {
		t.Fatalf("v1 restore = tab %d stay %v q %q", c.tab, c.stay, c.field.Value())
	}
	if len(c.favs) != 0 || len(c.recents) != 0 {
		t.Fatalf("v1 restore invented a shelf: %v %v", c.favs, c.recents)
	}
}

func TestStateV2Malformed(t *testing.T) {
	// A declared count that overruns the blob applies the flags but no
	// shelf and no query — never a half-parsed list.
	c := newApp()
	c.restoreState([]byte{'1', '1', 40, 0, 0}, stateVerShelf)
	if !c.stay || c.tab != tabCompose {
		t.Fatalf("flags did not survive the refused shelf: tab %d stay %v", c.tab, c.stay)
	}
	if len(c.favs) != 0 || len(c.recents) != 0 || c.field.Value() != "" {
		t.Fatalf("truncated v2 blob applied a shelf/query: %v %v %q",
			c.favs, c.recents, c.field.Value())
	}
	// Unknown codepoints and duplicates decode away, never crash.
	var b []byte
	b = append(b, '0', '0', 3)
	b = appendU32(b, 0x10FFFF) // no glyph covers it
	b = appendU32(b, uint32(glyphs[0].CP))
	b = appendU32(b, uint32(glyphs[0].CP)) // a dupe
	b = append(b, 0)                       // empty recents
	c.restoreState(b, stateVerShelf)
	if len(c.favs) != 1 || c.favs[0] != 0 {
		t.Fatalf("decode kept garbage: favs %v", c.favs)
	}
}
