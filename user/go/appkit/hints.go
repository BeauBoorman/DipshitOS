package appkit

import (
	"virelai/chords"
	"virelai/draw"
	"virelai/icons"
	"virelai/theme"
	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

// HintRow is one line of the overlay: a section header (Head set), one
// registry chord row, or a muted note (an empty section's "(none
// registered)"). Chord+Label are the registry row's own spelling and
// description — the overlay renders the table, never a hard-coded sheet.
type HintRow struct {
	Head  string
	Chord string
	Label string
	Note  bool
}

// ChordHints is the M121c (#2566) `?` overlay: a modal plate listing the
// chord registry's rows that answer while this app is focused — its own
// app scope first, then the global scopes the caller names — painted over
// the app's own surface. Like FilePicker it is a pure state machine: no
// syscall or drawing dependency sits in its transitions, so host tests pin
// the filtered content, the open/close contract and the scroll without a
// window. Canvas apps Draw it (GOEDIT); a fill-only RectCanvas gets the
// flat degrade (WEB's virender, the same contract EmptyState keeps); a VT
// surface renders the same rows through Lines (GOFILES's truecolour grid,
// GOTERM's tty alternate screen).
type ChordHints struct {
	Open   bool
	Name   string // the binary the app scope resolves from, for the title
	Rows   []HintRow
	Scroll int
	R      widgets.Rect
	UIFace *ttf.Face
	// IconFace is optional: a nil face drops the title glyph only.
	IconFace *ttf.Face
}

const (
	hintRowH   = 16
	hintListY  = 44 // header rows consumed above the list
	hintFooter = 22 // the "esc close" line below the list
)

// NewChordHints builds the overlay for one app, fed by the registry: the
// binary's app-scope section, the seat's global chords, then any extra
// scopes the caller names (a tty-bound front-end passes
// chords.ScopeKernelTerminal — the kernel chrome chords answer on its
// window too). Section order is display order.
func NewChordHints(binary string, extra ...chords.Scope) ChordHints {
	h := ChordHints{
		Open: true,
		Name: binary,
		R:    widgets.Rect{X: 40, Y: 28, W: 432, H: 328},
	}
	h.appendSection("this app — "+binary, chords.AppScope(binary))
	h.appendSection("global chords", chords.ScopeSeat)
	for _, sc := range extra {
		if sc == chords.ScopeSeat || sc == chords.AppScope(binary) {
			continue
		}
		h.appendSection(string(sc)+" chords", sc)
	}
	return h
}

// appendSection lays one scope's registry rows under a header; an empty
// scope gets the honest note rather than vanishing (the overlay then still
// shows the user that this app registers no chords of its own).
func (h *ChordHints) appendSection(title string, scope chords.Scope) {
	h.Rows = append(h.Rows, HintRow{Head: title})
	n := 0
	for _, r := range chords.Global {
		if r.Scope != scope {
			continue
		}
		h.Rows = append(h.Rows, HintRow{Chord: r.Chord.String(), Label: r.Label})
		n++
	}
	if n == 0 {
		h.Rows = append(h.Rows, HintRow{Note: true, Label: "(none registered)"})
	}
}

// ChordRows counts the registry rows the overlay carries — the number an
// app's open marker reports.
func (h *ChordHints) ChordRows() int {
	n := 0
	for _, r := range h.Rows {
		if r.Head == "" && !r.Note {
			n++
		}
	}
	return n
}

// RowLines is the serial-readable copy of the plate: one "chord  label"
// string per registry row, so a gate can pin the content against the
// shipped table instead of trusting pixels.
func (h *ChordHints) RowLines() []string {
	var out []string
	for _, r := range h.Rows {
		if r.Head == "" && !r.Note {
			out = append(out, r.Chord+" "+r.Label)
		}
	}
	return out
}

// VisibleRows is how many list rows fit the plate at its current R.
func (h *ChordHints) VisibleRows() int {
	v := (h.R.H - hintListY - hintFooter) / hintRowH
	if v < 1 {
		return 1
	}
	return v
}

func (h *ChordHints) maxScroll() int {
	m := len(h.Rows) - h.VisibleRows()
	if m < 0 {
		return 0
	}
	return m
}

// Move scrolls the list by delta rows, clamped; reports whether the view
// moved.
func (h *ChordHints) Move(delta int) bool {
	next := h.Scroll + delta
	if next < 0 {
		next = 0
	}
	if next > h.maxScroll() {
		next = h.maxScroll()
	}
	changed := next != h.Scroll
	h.Scroll = next
	return changed
}

// HandleKey consumes one event while the overlay is open: Esc or a second
// '?' closes, the nav keys scroll. changed means repaint; done means the
// overlay closed itself. The event wire exposes the HID usage in Arg0 and
// the decoded symbol in Arg1 — the same duality Dialog accepts.
func (h *ChordHints) HandleKey(ev vi.Event) (changed, done bool) {
	if !h.Open || ev.Kind != vi.EvKeyDown {
		return false, false
	}
	usage, ch := ev.Arg0, ev.Arg1
	switch {
	case usage == 0x29 || ch == 0x1b: // Esc
		h.Open = false
		return true, true
	case ch == '?': // '?' toggles its own overlay closed
		h.Open = false
		return true, true
	case usage == 0x52: // up
		return h.Move(-1), false
	case usage == 0x51: // down
		return h.Move(1), false
	case usage == 0x4b: // pageup
		return h.Move(-h.VisibleRows()), false
	case usage == 0x4e: // pagedown
		return h.Move(h.VisibleRows()), false
	case usage == 0x4a: // home
		h.Scroll = 0
		return true, false
	case usage == 0x4d: // end
		h.Scroll = h.maxScroll()
		return true, false
	}
	return false, false
}

// Lines renders the same content as w-cell text rows for a VT grid — the
// only hints surface a non-Canvas app can paint (GOFILES's ANSI frame,
// GOTERM's tty alternate screen). The caller slices [Scroll:Scroll+vis]
// around the window it owns; the title and footer lines are included.
func (h *ChordHints) Lines(w int) []string {
	clip := func(s string) string {
		rs := []rune(s)
		if len(rs) > w {
			rs = rs[:w]
		}
		return string(rs)
	}
	out := []string{clip("chord hints — " + h.Name), ""}
	for _, r := range h.Rows {
		var line string
		switch {
		case r.Head != "":
			line = r.Head
		case r.Note:
			line = "    " + r.Label
		default:
			line = "  " + padTo(r.Chord, 18) + r.Label
		}
		out = append(out, clip(line))
	}
	out = append(out, "", clip("esc close · arrows scroll"))
	return out
}

// padTo right-pads s with spaces to w runes (no truncation — the longest
// shipped chord spelling is "ctrl+shift+alt+r" at 16).
func padTo(s string, w int) string {
	n := 0
	for range s {
		n++
	}
	for n < w {
		s += " "
		n++
	}
	return s
}

// Draw paints the overlay plate on the caller's own surface: title row
// with the info glyph, the sectioned chord rows, and the footer hint. A
// full Canvas gets the §2.2 rounded plate and face-rendered labels; a
// fill-only RectCanvas keeps the flat form EmptyState degrades to — same
// content, no rounded corners, 8x8 runs.
func (h *ChordHints) Draw(c widgets.RectCanvas) {
	if !h.Open {
		return
	}
	tok := theme.Current
	inset := tok.PadMD + tok.PadSM
	fc, full := c.(widgets.Canvas)
	if full {
		fc.FillRoundedRect(h.R, 8, draw.Opaque(tok.Surface))
		fc.StrokeRoundedRect(h.R, 8, tok.BorderW, draw.Opaque(tok.Border))
	} else {
		c.FillRect(h.R, tok.Surface)
		bw := tok.BorderW
		if bw < 1 {
			bw = 1
		}
		c.FillRect(widgets.Rect{X: h.R.X, Y: h.R.Y, W: h.R.W, H: bw}, tok.Border)
		c.FillRect(widgets.Rect{X: h.R.X, Y: h.R.Bottom() - bw, W: h.R.W, H: bw}, tok.Border)
		c.FillRect(widgets.Rect{X: h.R.X, Y: h.R.Y + bw, W: bw, H: h.R.H - 2*bw}, tok.Border)
		c.FillRect(widgets.Rect{X: h.R.Right() - bw, Y: h.R.Y + bw, W: bw, H: h.R.H - 2*bw}, tok.Border)
	}

	text, muted, accent := tok.Text, tok.Muted, tok.Accent
	if full {
		text, muted, accent = draw.Opaque(text), draw.Opaque(muted), draw.Opaque(accent)
	}
	hintText := func(r widgets.Rect, s string, rgb uint32) {
		if full && h.UIFace != nil {
			dialogText(fc, h.UIFace, r, s, rgb, false)
			return
		}
		widgets.DrawText(c, r, s, rgb)
	}

	// Title row: info glyph + "chord hints — BIN".
	title := widgets.Rect{X: h.R.X + inset + 20, Y: h.R.Y + inset, W: h.R.W - 2*inset - 20, H: 24}
	if full {
		if cp, ok := icons.Codepoint("info-circle"); ok {
			icon := widgets.Rect{X: h.R.X + inset, Y: h.R.Y + inset, W: 16, H: 24}
			draw.Glyph(fc, h.IconFace, icon, icon.X, icon.Y+20, icons.NominalPx, cp, draw.Opaque(tok.Accent))
		}
	}
	hintText(title, "chord hints — "+h.Name, text)

	// Rows: section headers muted, note rows dimmer still, chord column in
	// the accent tone so the keys read before the prose.
	lr := widgets.Rect{X: h.R.X + inset, Y: h.R.Y + hintListY, W: h.R.W - 2*inset, H: h.R.H - hintListY - hintFooter - inset}
	for i := h.Scroll; i < len(h.Rows); i++ {
		rr := widgets.Rect{X: lr.X, Y: lr.Y + (i-h.Scroll)*hintRowH, W: lr.W, H: hintRowH}
		if rr.Y >= lr.Bottom() {
			break
		}
		row := h.Rows[i]
		switch {
		case row.Head != "":
			hintText(rr, row.Head, muted)
		case row.Note:
			hintText(widgets.Rect{X: rr.X + 16, Y: rr.Y, W: rr.W - 16, H: rr.H}, row.Label, muted)
		default:
			hintText(widgets.Rect{X: rr.X + 8, Y: rr.Y, W: 150, H: rr.H}, row.Chord, accent)
			hintText(widgets.Rect{X: rr.X + 160, Y: rr.Y, W: rr.W - 160, H: rr.H}, row.Label, text)
		}
	}

	// Footer hint.
	foot := widgets.Rect{X: lr.X, Y: h.R.Bottom() - inset - 14, W: lr.W, H: 14}
	hintText(foot, "esc close · arrows scroll", muted)
}
