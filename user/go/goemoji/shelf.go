// Command goemoji is GOEMOJI.ELF — M152c (issue #2917): the shelf.
// Recents are the last shelfMax picks, most recent first, deduplicated;
// a plain F10 pins or unpins the focused cell into favorites. Both lists
// hold glyph-table indices — the Compose and Kaomoji tabs have no cell
// art, so their picks never join the shelf — and both ride the
// save_state blob v2 so a seat snapshot carries them into the next boot.
// On the Emoji tab an empty query shows the shelf as the grid's first
// rows: favorites on top, recents beneath, each section starting on a
// fresh row.
package main

import "virelai/vi"

const (
	shelfMax = 16 // each list's bound — the card's "last 16" / "up to 16"
	// cellPad is a matches sentinel: a shelf-section pad cell keeping the
	// next section on a fresh grid row. Pads occupy space but are never
	// selectable, clickable, or pickable.
	cellPad = -1
)

// stateVerShelf is the save_state envelope version whose blob carries the
// shelf: `tab | stay | u8 nfav | nfav x u32 cp | u8 nrec | nrec x u32 cp |
// query`. v1 was `tab | stay | query`; the envelope's appver tag tells a
// restore which layout the bytes carry, so a v1 blob still decodes with an
// empty shelf.
const stateVerShelf uint8 = 2

// noteRecent records a picked glyph at the head of recents — deduplicated,
// capped at shelfMax. The marker prints the resulting order, so a gate
// reads "B A" as most-recent-first.
func (a *app) noteRecent(i int) {
	if i < 0 || i >= len(glyphs) {
		return
	}
	next := make([]int, 0, shelfMax)
	next = append(next, i)
	for _, v := range a.recents {
		if v != i && len(next) < shelfMax {
			next = append(next, v)
		}
	}
	a.recents = next
	vi.ConsoleLine(markerRecents + tagsOf(a.recents))
}

// toggleFav is the F10 arm: pin the focused Emoji cell, or unpin it if it
// is already a favorite. A full shelf refuses by name rather than evicting
// — the pin order is the user's, not the app's to rewrite.
func (a *app) toggleFav() bool {
	i, ok := a.selGlyph()
	if !ok {
		return false
	}
	if j := indexOfGlyph(a.favs, i); j >= 0 {
		a.favs = append(a.favs[:j:j], a.favs[j+1:]...)
	} else if len(a.favs) >= shelfMax {
		vi.ConsoleLine(markerFavs + "full")
		return true
	} else {
		a.favs = append(a.favs, i)
	}
	vi.ConsoleLine(markerFavs + tagsOf(a.favs))
	// The pinned cell's section moved: refilter, then land the focus back
	// on the same glyph (its first cell — a favorite is also a recent or
	// grid entry).
	a.refilter()
	for pos, v := range a.matches {
		if v == i {
			a.sel = pos
			break
		}
	}
	return true
}

// selGlyph is the glyph-table index under the selection on the Emoji tab.
// Pad cells and the other tabs' rows are not shelf cells.
func (a *app) selGlyph() (int, bool) {
	if a.tab != tabEmoji || a.sel < 0 || a.sel >= len(a.matches) {
		return 0, false
	}
	i := a.matches[a.sel]
	if i < 0 || i >= len(glyphs) {
		return 0, false
	}
	return i, true
}

func indexOfGlyph(list []int, i int) int {
	for j, v := range list {
		if v == i {
			return j
		}
	}
	return -1
}

// tagsOf renders a shelf list as the gate-parseable marker tail: the cells'
// U+ tags in list order, "-" when the list is empty.
func tagsOf(list []int) string {
	if len(list) == 0 {
		return "-"
	}
	s := uhex(glyphs[list[0]].CP)
	for _, i := range list[1:] {
		s += " " + uhex(glyphs[i].CP)
	}
	return s
}

// shelfView prefixes the Emoji tab's empty-query grid with the favorites
// row and then the recents row. Each nonempty section pads with cellPad
// sentinels to a row boundary, so the recents row always starts below a
// full favorites row — "the favorites row sits above recents" is a literal
// layout property, and arrow keys keep their columns across the shelf.
func shelfView(favs, recents, all []int) []int {
	if len(favs) == 0 && len(recents) == 0 {
		return all
	}
	out := make([]int, 0, len(all)+2*shelfMax+2*gridCols)
	for _, s := range [][]int{favs, recents} {
		out = append(out, s...)
		for len(out)%gridCols != 0 {
			out = append(out, cellPad)
		}
	}
	return append(out, all...)
}

// --- save_state v2 blob ----------------------------------------------------

func appendU32(b []byte, v uint32) []byte {
	return append(b, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

func getU32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

// shelfEncode appends one list as `u8 n | n x u32 cp`. Codepoints — not
// table indices — so a kernel-side append or removal can never silently
// retarget a pin: a dropped glyph's lookup misses and its entry is skipped.
func shelfEncode(b []byte, list []int) []byte {
	n := len(list)
	if n > shelfMax {
		n = shelfMax
	}
	b = append(b, byte(n))
	for _, i := range list[:n] {
		b = appendU32(b, uint32(glyphs[i].CP))
	}
	return b
}

// shelfDecode reads one list at b[off] back through lookup: unknown
// codepoints, duplicates, and entries past the shelf bound are skipped.
// ok=false only when the blob is too short for what the count declares —
// the caller then applies nothing rather than a half-parsed list.
func shelfDecode(b []byte, off int) ([]int, int, bool) {
	if off >= len(b) {
		return nil, off, false
	}
	n := int(b[off])
	off++
	if len(b)-off < n*4 {
		return nil, off, false
	}
	var out []int
	for j := 0; j < n; j++ {
		i := lookup(rune(getU32(b[off+j*4:])))
		if i >= 0 && indexOfGlyph(out, i) < 0 && len(out) < shelfMax {
			out = append(out, i)
		}
	}
	return out, off + n*4, true
}
