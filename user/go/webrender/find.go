package webrender

import (
	"strings"
	"unicode/utf8"
)

// Find-in-page support (M126c #2595): the searchable page text plus the map
// back to paint geometry, so a match offset becomes the rects the browser's
// highlight draws. The matcher itself is package virelai/find — the same
// scan GOEDIT runs.

// findSpan records where one ItemText's bytes sit inside the page text.
type findSpan struct {
	item int // index into Layout.Items (an ItemText)
	off  int // byte offset where the item's text starts inside Text
}

// FindIndex is the find view of a Layout: the searchable text (the ItemText
// runs in paint order — styled runs on one line concatenate with nothing,
// since a styled run mid-sentence is not a word break; a horizontal gap
// between items on one line becomes ' ', because the layout strips
// whitespace and positions each word — the gap IS the rendered space; a
// line change inserts '\n', which a find bar can never carry, so a match
// can span styled runs on one line but never two lines) plus the spans
// that map it back to items.
type FindIndex struct {
	Text  string
	spans []findSpan
}

// FindPiece is one highlight piece of a match: fill Rect, then repaint the
// item's text run on top so the glyphs survive the fill.
type FindPiece struct {
	Item int     // index into Layout.Items carrying this piece
	Rect BoxRect // the highlight, in content coordinates
}

// NewFindIndex indexes l's laid-out text. l may be nil (an error page): the
// index is then empty and every search misses.
func NewFindIndex(l *Layout) *FindIndex {
	f := &FindIndex{}
	if l == nil {
		return f
	}
	var b strings.Builder
	y, right, first := 0, 0, true
	for i, it := range l.Items {
		if it.Kind != ItemText {
			continue
		}
		switch {
		case first:
		case it.Y != y:
			b.WriteByte('\n')
		case it.X > right:
			// A same-line horizontal gap is a rendered word break — the
			// layout strips whitespace runs and positions every word, so
			// one ' ' stands for the whole collapsed run.
			b.WriteByte(' ')
		}
		y, right, first = it.Y, it.X+it.W, false
		f.spans = append(f.spans, findSpan{item: i, off: b.Len()})
		b.WriteString(it.Text)
	}
	f.Text = b.String()
	return f
}

// Pieces resolves page-text byte range [s, e) to the paint pieces the app
// draws — one per text item the range intersects, each sub-rect measured
// with the layout's own engine so the highlight lands exactly under the
// glyphs the match produced.
func (f *FindIndex) Pieces(l *Layout, s, e int) []FindPiece {
	if l == nil || s < 0 || e <= s || e > len(f.Text) {
		return nil
	}
	engine := l.Text
	if engine == nil {
		engine = Bitmap{}
	}
	var out []FindPiece
	for _, sp := range f.spans {
		it := l.Items[sp.item]
		lo, hi := sp.off, sp.off+len(it.Text)
		if hi <= s || lo >= e {
			continue
		}
		a, b := max(s, lo)-lo, min(e, hi)-lo
		// A match can start or end mid-rune; clamp to rune boundaries so a
		// partial never measures or paints as mojibake.
		for a > 0 && a < len(it.Text) && !utf8.RuneStart(it.Text[a]) {
			a--
		}
		for b > a && b < len(it.Text) && !utf8.RuneStart(it.Text[b]) {
			b++
		}
		st := itemStyle(it)
		x := it.X + engine.Measure(it.Text[:a], st)
		w := engine.Measure(it.Text[a:b], st)
		if w <= 0 {
			continue
		}
		out = append(out, FindPiece{Item: sp.item, Rect: BoxRect{X: x, Y: it.Y, W: w, H: it.H}})
	}
	// A match carries the gaps inside it too: the ' ' a word break wrote
	// into Text has no item span, so bridge same-line piece pairs to keep
	// the highlight contiguous — the selection shape browsers paint.
	for i := 1; i < len(out); i++ {
		prev := &out[i-1]
		if prev.Rect.Y == out[i].Rect.Y && out[i].Rect.X > prev.Rect.X+prev.Rect.W {
			prev.Rect.W = out[i].Rect.X - prev.Rect.X
		}
	}
	return out
}

// itemStyle is an ItemText's paint style — the same shape Paint and
// updateControlPaint pass to the engine.
func itemStyle(it Item) Style {
	return Style{Size: it.Size, FontPx: it.FontPx, LineHeightPx: it.LineHeightPx,
		Mono: it.Mono, Serif: it.Serif, Bold: it.Bold, Italic: it.Italic}
}

// PaintFindPieces highlights one match: each piece's rect is filled with
// rgb, then the item's whole run is repainted clipped to that rect, so the
// glyphs re-ink over the highlight in exactly their original positions
// (identical x/y/style as Paint itself uses — no measuring a sub-run, so a
// highlight edge mid-glyph can never shift the remaining ink). scroll and
// clip position the content exactly as Paint's own arguments do for a
// caller that paints at ox=0, oy=0 — the browser's native-surface shape.
func PaintFindPieces(l *Layout, s Surface, scroll int, pieces []FindPiece, rgb uint32, clip Clip) {
	if l == nil {
		return
	}
	engine := l.Text
	if engine == nil {
		engine = Bitmap{}
	}
	for _, p := range pieces {
		if p.Item < 0 || p.Item >= len(l.Items) || p.Rect.W <= 0 || p.Rect.H <= 0 {
			continue
		}
		it := l.Items[p.Item]
		if it.Kind != ItemText || transparentText(it.Box) {
			continue
		}
		x, y := p.Rect.X, p.Rect.Y-scroll
		fillClipped(s, clip, x, y, p.Rect.W, p.Rect.H, rgb)
		inner := clip.Intersect(Clip{X: x, Y: y, W: p.Rect.W, H: p.Rect.H})
		engine.Paint(s, it.X, it.Y-scroll, it.Text, itemStyle(it), it.Color, inner)
	}
}
