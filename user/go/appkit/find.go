package appkit

// The M191c (#3244) find overlay: one incremental find bar for every text
// app — a bottom-docked strip with a pattern field, a live match count,
// and Enter / Shift-Enter next/prev cycling over a caller-supplied corpus
// seam. Escape dismisses. The overlay is deliberately dumb: it never sees
// a hit's bytes or position. The app's Scan counts the hits for the
// field's pattern and Show jumps to the ordinal the overlay picks, so one
// bar serves a text buffer, a paged document, or anything else an app can
// walk — one muscle memory instead of five ad-hoc bars.
//
// The bar owns the keyboard while Open, like the pickers and menus do. The
// pattern survives a close, so reopening offers the last search again —
// the "find that string once more" rule GOREADER's M143a bar already kept
// and NOTE gets for free.

import (
	"unicode/utf8"

	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// findPatMax bounds the pattern in bytes — the order of GOEDIT's 32 for a
// file buffer, generous enough for a sentence (WEB's findbar took 96 for
// the same reason).
const findPatMax = 96

// Find is the Focusable find overlay. R is the docked bar plate — the app
// sets it once per frame from its own chrome rules; Scan/Show/Miss are the
// corpus seam. The pattern is a plain bounded field (typed at the tail,
// backspace trims a whole rune) — deliberately not a full TextField, so
// adopting the bar does not drag the dead-key layout machinery into every
// app's image: the exec_program_max budget is real, and a find pattern is
// not where rune editing earns its keep.
type Find struct {
	R     widgets.Rect
	Open  bool
	Total int // hits for the current pattern — Scan's last count
	Cur   int // ordinal of the hit last stepped to; -1 when none is current

	// Scan counts the hits for the field's pattern in the app's corpus.
	// It runs on every pattern edit and before every Step, so a hit
	// ordinal never outlives the text it described. The overlay never
	// calls it with an empty pattern.
	Scan func(pat string) int
	// Show makes 0-based hit i the current one — scroll to it, select it,
	// blend it: the app's own affair. Called only for i in [0, Total).
	Show func(i int)
	// Miss reports a Step against a nonempty pattern with no hits — the
	// app's cue for its miss marker, if it has one.
	Miss func()

	pat []byte
}

// NewFind returns a closed overlay; the app wires the corpus seam.
func NewFind() Find {
	return Find{Cur: -1, pat: make([]byte, 0, 32)}
}

// Bounds is the bar plate.
func (f *Find) Bounds() widgets.Rect { return f.R }

// HitTest covers the bar — the field's own plate is inside it.
func (f *Find) HitTest(x, y int) bool { return f.R.Contains(x, y) }

// Present opens the bar. The pattern survives: the corpus rescans so the
// count is fresh, and Cur keeps pointing where it did — reopening steps
// from the hit the user left on, which is what a repeat-find chord wants.
func (f *Find) Present() {
	f.Open = true
	f.scan()
}

// Dismiss closes the bar. The hit set is the app's — whatever it blended
// for the current search stays painted, matching the pre-overlay bars.
func (f *Find) Dismiss() { f.Open = false }

// Pattern is the field's current text — what an out-of-bar repeat chord
// (GOREADER's n/N) searches for.
func (f *Find) Pattern() string { return string(f.pat) }

// SetPattern replaces the pattern — the app's seed, or "". It does not
// rescan; call Recompute (or Present) to refresh the count.
func (f *Find) SetPattern(s string) {
	if len(s) > findPatMax {
		cut := findPatMax
		for cut > 0 && !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut]
	}
	f.pat = append(f.pat[:0], s...)
}

// scan refreshes Total for the field's pattern. An empty pattern is zero
// hits by definition and never disturbs the corpus.
func (f *Find) scan() {
	f.Total = 0
	if len(f.pat) != 0 && f.Scan != nil {
		f.Total = f.Scan(f.Pattern())
	}
}

// Recompute is the pattern-changed rescan: fresh hits and no current one
// — a new search starts its cycling from the first hit again.
func (f *Find) Recompute() {
	f.scan()
	f.Cur = -1
}

// Step cycles to the next (dir > 0) or previous (dir < 0) hit, wrapping at
// both ends — the repeat-Return rule the shared matcher's scan encodes,
// so a lone hit re-reports 1/1 forever. The first step after an edit lands
// on the first hit (or the last, stepping back). Step rescans first so
// the ordinal is honest against the live corpus, and it reports whether a
// hit became current — false on a miss, after Miss fires.
func (f *Find) Step(dir int) bool {
	f.scan()
	if f.Total == 0 {
		f.Cur = -1
		if f.Miss != nil && len(f.pat) != 0 {
			f.Miss()
		}
		return false
	}
	i := 0
	if dir < 0 {
		i = f.Total - 1
	}
	if f.Cur >= 0 {
		i = (f.Cur + dir) % f.Total
		if i < 0 {
			i += f.Total
		}
	}
	f.Cur = i
	if f.Show != nil {
		f.Show(i)
	}
	return true
}

// OnKey is the Focusable key path, called only while Open. Escape
// dismisses, Enter steps (Shift-Enter back), Backspace trims a whole rune,
// and printable runes append at the tail — each edit rescans, the
// incremental rule.
func (f *Find) OnKey(k Key) bool {
	switch k.Named() {
	case NamedEscape:
		f.Dismiss()
		return true
	case NamedEnter:
		if k.Shift {
			f.Step(-1)
		} else {
			f.Step(1)
		}
		return true
	case NamedBackspace:
		if len(f.pat) == 0 {
			return true
		}
		_, n := utf8.DecodeLastRune(f.pat)
		f.pat = f.pat[:len(f.pat)-n]
		f.Recompute()
		return true
	}
	if k.Rune != 0 && !k.Ctrl && !k.Alt && utf8.RuneLen(k.Rune) <= findPatMax-len(f.pat) {
		f.pat = append(f.pat, string(k.Rune)...)
		f.Recompute()
	}
	return true // the bar owns the keyboard; an over-long rune is dropped
}

// OnClick swallows clicks inside the bar — the corpus under it is not
// pointer-reachable while the strip is up.
func (f *Find) OnClick(x, y int) bool { return f.R.Contains(x, y) }

// countText is the bar's right-aligned match count: "" for an empty
// pattern, "0" for a miss, "n/M" once cycling has begun and "0/M" before.
func (f *Find) countText() string {
	if len(f.pat) == 0 {
		return ""
	}
	if f.Total == 0 {
		return "0"
	}
	cur := 0
	if f.Cur >= 0 {
		cur = f.Cur + 1
	}
	return vi.Itoa64(int64(cur)) + "/" + vi.Itoa64(int64(f.Total))
}

// Draw paints the bar: a Surface plate with a rule top edge, the label,
// the pattern text with a caret bar after it, and the match count
// right-aligned. The flat RectCanvas vocabulary is all the bar needs —
// the adopting apps pass the same fill-only adapter their own chrome
// paints through, so the overlay costs them no canvas contract at all.
func (f *Find) Draw(c widgets.RectCanvas) {
	if !f.Open || f.R.Empty() {
		return
	}
	th := theme.Current
	label := widgets.Rect{X: f.R.X, Y: f.R.Y, W: 6 * glyphW, H: f.R.H}
	text := f.Pattern()
	count := f.countText()
	var cplate widgets.Rect
	if count != "" {
		cw := utf8.RuneCountInString(count) * glyphW
		cplate = widgets.Rect{X: f.R.Right() - cw - 4, Y: f.R.Y, W: cw + 4, H: f.R.H}
	}
	// The pattern's plate spans label to count.
	fplate := widgets.Rect{
		X: label.Right() + glyphW/2,
		Y: f.R.Y + 1,
		H: f.R.H - 2,
	}
	right := f.R.Right() - 2
	if count != "" {
		right = cplate.X - glyphW/2
	}
	if fplate.W = right - fplate.X; fplate.W < glyphW {
		fplate.W = glyphW
	}

	c.FillRect(f.R, th.Surface)
	c.FillRect(widgets.Rect{X: f.R.X, Y: f.R.Y, W: f.R.W, H: 1}, th.Border)
	c.FillRect(fplate, th.Bg)
	widgets.DrawText(c, label, "Find:", th.Muted)
	fg := th.Text
	if text == "" {
		text, fg = "type to find", th.Muted
	}
	widgets.DrawText(c, fplate, text, fg)
	if count != "" {
		widgets.DrawText(c, cplate, count, th.Muted)
	}
	// The caret bar sits after the last pattern cell — the same one-pixel
	// accent edge WEB's findbar draws.
	if x := fplate.X + 2 + utf8.RuneCountInString(text)*glyphW; x < fplate.Right() {
		c.FillRect(widgets.Rect{X: x, Y: fplate.Y + 2, W: 1, H: fplate.H - 4}, th.Accent)
	}
}
