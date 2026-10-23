package appkit

import (
	"unicode/utf8"

	"virelai/draw"
	"virelai/layout"
	"virelai/linebuf"
	"virelai/theme"
	"virelai/ttf"
	"virelai/widgets"
)

// ListController adds keyboard selection and scroll-into-view to the pure
// widgets.List. It deliberately keeps the widget's row geometry authoritative.
type ListController struct {
	List *widgets.List
}

func NewListController(list *widgets.List) *ListController {
	return &ListController{List: list}
}

func (c *ListController) valid() bool {
	return c != nil && c.List != nil && len(c.List.Items) > 0
}

func (c *ListController) Move(delta int) bool {
	if !c.valid() {
		return false
	}
	if c.List.Sel < 0 {
		c.List.Sel = 0
	}
	next := c.List.Sel + delta
	if next < 0 {
		next = 0
	}
	if next >= len(c.List.Items) {
		next = len(c.List.Items) - 1
	}
	changed := next != c.List.Sel
	c.List.Sel = next
	c.ensureVisible()
	return changed
}

func (c *ListController) Home() bool {
	if !c.valid() {
		return false
	}
	changed := c.List.Sel != 0
	c.List.Sel = 0
	c.ensureVisible()
	return changed
}

func (c *ListController) End() bool {
	if !c.valid() {
		return false
	}
	last := len(c.List.Items) - 1
	changed := c.List.Sel != last
	c.List.Sel = last
	c.ensureVisible()
	return changed
}

func (c *ListController) Bounds() widgets.Rect       { return c.List.Bounds() }
func (c *ListController) HitTest(x, y int) bool      { return c.List.HitTest(x, y) }
func (c *ListController) Draw(cv widgets.RectCanvas) { c.List.Draw(cv) }
func (c *ListController) OnClick(x, y int) bool {
	if !c.valid() {
		return false
	}
	i := c.List.ItemAt(x, y)
	if i < 0 {
		return false
	}
	c.List.Sel = i
	c.ensureVisible()
	return true
}

func (c *ListController) HandleKey(k Key) bool {
	switch k.Named() {
	case NamedUp:
		return c.Move(-1)
	case NamedDown:
		return c.Move(1)
	case NamedHome:
		return c.Home()
	case NamedEnd:
		return c.End()
	}
	return false
}

func (c *ListController) OnKey(k Key) bool  { return c.HandleKey(k) }
func (c *ListController) SetFocused(v bool) { c.List.Focused = v }

func (c *ListController) ensureVisible() {
	if c.List.RowH <= 0 || c.List.R.H <= 0 {
		return
	}
	visible := c.List.VisibleRows()
	if visible < 1 {
		return
	}
	maxTop := len(c.List.Items) - visible
	if maxTop < 0 {
		maxTop = 0
	}
	if c.List.ScrollTop > maxTop {
		c.List.ScrollTop = maxTop
	}
	if c.List.Sel < c.List.ScrollTop {
		c.List.ScrollTop = c.List.Sel
	}
	if c.List.Sel >= c.List.ScrollTop+visible {
		c.List.ScrollTop = c.List.Sel - visible + 1
	}
	if c.List.ScrollTop < 0 {
		c.List.ScrollTop = 0
	}
}

// TextField is a bounded GUI single-line editor. It uses linebuf.LineBuffer for
// byte/caret operations while appkit owns normalized key handling and paint.
//
// The buffer holds UTF-8 and Max bounds its bytes. Text goes in and out one
// whole scalar at a time, so a rune that does not fit is refused rather than
// truncated, and the caret and the delete keys never stop inside a rune.
//
// A field created without SetLayout has no dead keys and behaves as a plain
// editor. With a layout, a dead key stages an accent that shows in the field
// (see Preedit) until the next key resolves it.
//
// Face is the §3.4 optional TrueType label face — nil keeps the 8x8 bitmap
// face. Chain, when set, paints ALL of the field's text through a face
// cascade instead — a composed pre-edit's kana resolve to the Japanese
// coverage face — and Face is ignored; nil keeps the single-face path.
// Disabled drops text to the Muted role and blends the plate 50%
// toward Surface (§2.3).
//
// IME, when non-nil, arms romaji->kana composition behind Ctrl+J: the
// chord swaps the IME in for the dead-key stage and back, committing
// whatever was staged first. While the IME holds a pre-edit the field
// paints it underlined and offers its candidate forms under the plate.
// OnIMEToggle reports each flip (true = composing) and OnIMECommit each
// text the composition inserts; either may be nil.
type TextField struct {
	R           widgets.Rect
	Buffer      linebuf.LineBuffer
	Fg          uint32
	Bg          uint32
	Caret       uint32
	Focused     bool
	Disabled    bool
	Face        *ttf.Face
	Chain       *ttf.Chain
	Max         int
	Prefix      string
	Placeholder string
	IME         *layout.IME
	OnIMEToggle func(on bool)
	OnIMECommit func(text string)

	stage layout.Stage
	imeOn bool
}

// usageIMEToggle is the composition toggle's HID usage — Ctrl+J. The
// seat's chord table (user/go/chords/table.go) binds no ctrl-j row at
// any scope, and ADR 0009 reaches every focused app regardless.
const usageIMEToggle = 0x0d // 'j'

// composer is the pending-text engine currently driving the field: the
// IME while composition is on, the dead-key stage otherwise. The field
// and its painters never branch on which one is active.
func (f *TextField) composer() layout.Composer {
	if f.IME != nil && f.imeOn {
		return f.IME
	}
	return &f.stage
}

// Composing reports whether the field's romaji->kana composer is the
// active one.
func (f *TextField) Composing() bool {
	return f.IME != nil && f.imeOn
}

func NewTextField(r widgets.Rect, max int) TextField {
	if max < 1 {
		max = 1
	}
	return TextField{R: r, Buffer: linebuf.NewLineBuffer(max), Max: max}
}

func (f *TextField) Bounds() widgets.Rect  { return f.R }
func (f *TextField) HitTest(x, y int) bool { return f.R.Contains(x, y) }

func (f *TextField) Value() string      { return f.Buffer.Value() }
func (f *TextField) CaretPosition() int { return f.Buffer.Caret() }

// SetLayout selects the keyboard layout whose dead keys the field composes.
// Call it when the field is set up; it drops a half-typed sequence.
func (f *TextField) SetLayout(id layout.ID) { f.stage.SetLayout(id) }

// Preedit is the active composer's staged text as the field paints it —
// a pending accent's mark or a composition's shown form — or "" when
// nothing is staged. The text is not in Value yet.
func (f *TextField) Preedit() string { return f.composer().Preedit() }

// SetValue replaces the text. A value longer than Max is clipped to a whole
// rune, and staged input is dropped because it no longer follows the text
// it was typed after.
func (f *TextField) SetValue(s string) {
	f.cancelStaged()
	if f.Max > 0 && len(s) > f.Max {
		cut := f.Max
		for cut > 0 && !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut]
	}
	f.Buffer.SetValue(s)
}

func (f *TextField) Clear() {
	f.cancelStaged()
	f.Buffer.Clear()
}

// cancelStaged drops whatever either composer holds — the active one and,
// defensively, the dormant one too, so a programmatic edit never leaves a
// stale pre-edit waiting behind the mode it was typed in.
func (f *TextField) cancelStaged() {
	f.stage.Cancel()
	if f.IME != nil {
		f.IME.Cancel()
	}
}

// SetFocused commits a staged accent as its literal character when the field
// loses focus, so leaving the field never swallows what was typed.
func (f *TextField) SetFocused(v bool) {
	if !v {
		f.flush()
	}
	f.Focused = v
}

// OnKey reports whether the field consumed the key. The composition toggle
// chord is handled first: it commits whatever is staged and flips modes.
// A key that ends a pending sequence without being text (Enter, Escape, an
// unmapped key) first types the staged text, so Value already includes it,
// and then returns false so the caller still acts on the key. Preedit is
// the state to repaint from.
func (f *TextField) OnKey(k Key) bool {
	if f.IME != nil && k.Ctrl && !k.Shift && !k.Alt && k.Usage == usageIMEToggle {
		f.flush()
		f.imeOn = !f.imeOn
		if f.OnIMEToggle != nil {
			f.OnIMEToggle(f.imeOn)
		}
		return true
	}
	c := f.composer()
	composing := f.imeOn
	before := c.Preedit()
	step := c.Feed(layout.Input{
		Usage: k.Usage,
		Shift: k.Shift,
		Chord: k.Ctrl || k.Alt,
		Sym:   k.Rune,
	})
	changed := false
	var inserted []rune
	for _, r := range step.Commit {
		if f.insertRune(r) {
			inserted = append(inserted, r)
			changed = true
		}
	}
	if c.Preedit() != before {
		changed = true
	}
	if composing && len(inserted) > 0 && f.OnIMECommit != nil {
		f.OnIMECommit(string(inserted))
	}
	if !step.Pass {
		return changed
	}
	return f.editKey(k)
}

func (f *TextField) editKey(k Key) bool {
	switch k.Named() {
	case NamedBackspace:
		return f.backspace()
	case NamedDelete:
		return f.deleteRune()
	case NamedLeft:
		return f.stepCaret(false)
	case NamedRight:
		return f.stepCaret(true)
	case NamedHome:
		return f.Buffer.Home()
	case NamedEnd:
		return f.Buffer.End()
	}
	if k.Rune != 0 && !k.Ctrl && !k.Alt {
		return f.insertRune(k.Rune)
	}
	return false
}

// insertRune types one scalar at the caret. The bytes go in together or not at
// all: if the bound stops the encoding part-way, the bytes already placed are
// taken back out.
func (f *TextField) insertRune(r rune) bool {
	if !layout.Printable(r) {
		return false
	}
	var enc [utf8.UTFMax]byte
	n := utf8.EncodeRune(enc[:], r)
	for i := 0; i < n; i++ {
		if f.Buffer.InsertByte(enc[i]) {
			continue
		}
		for ; i > 0; i-- {
			f.Buffer.Backspace()
		}
		return false
	}
	return true
}

func (f *TextField) flush() bool {
	c := f.composer()
	composing := f.imeOn
	typed := false
	var inserted []rune
	for _, r := range c.Flush() {
		if f.insertRune(r) {
			inserted = append(inserted, r)
			typed = true
		}
	}
	if composing && len(inserted) > 0 && f.OnIMECommit != nil {
		f.OnIMECommit(string(inserted))
	}
	return typed
}

func (f *TextField) backspace() bool {
	v, c := f.Buffer.Value(), f.Buffer.Caret()
	if c == 0 {
		return false
	}
	_, n := utf8.DecodeLastRuneInString(v[:c])
	for i := 0; i < n; i++ {
		f.Buffer.Backspace()
	}
	return true
}

func (f *TextField) deleteRune() bool {
	v, c := f.Buffer.Value(), f.Buffer.Caret()
	if c >= len(v) {
		return false
	}
	_, n := utf8.DecodeRuneInString(v[c:])
	for i := 0; i < n; i++ {
		f.Buffer.Delete()
	}
	return true
}

// stepCaret moves the caret one whole rune, right when forward is set.
func (f *TextField) stepCaret(forward bool) bool {
	v, c := f.Buffer.Value(), f.Buffer.Caret()
	var n int
	switch {
	case forward && c < len(v):
		_, n = utf8.DecodeRuneInString(v[c:])
	case !forward && c > 0:
		_, n = utf8.DecodeLastRuneInString(v[:c])
	default:
		return false
	}
	for i := 0; i < n; i++ {
		if forward {
			f.Buffer.Right()
		} else {
			f.Buffer.Left()
		}
	}
	return true
}

// OnClick commits a staged accent first: a click ends the sequence.
func (f *TextField) OnClick(x, y int) bool {
	typed := f.flush()
	return f.HitTest(x, y) || typed
}

// glyphW is the 8x8 face's advance, and so the width of one text cell.
const glyphW = 8

// labelPx is the §2.2 chrome label size for the TrueType path.
const labelPx = 13

func (f *TextField) Draw(c widgets.RectCanvas) {
	if f.R.Empty() {
		return
	}
	fg, bg := f.Fg, f.Bg
	if fg == 0 {
		fg = 0xffffff
	}
	if bg == 0 {
		bg = 0x101418
	}
	if f.Caret == 0 {
		f.Caret = 0x3b82f6
	}
	if fc, ok := c.(widgets.Canvas); ok {
		f.drawCanvas(fc, fg, bg)
		return
	}
	if f.Disabled {
		fg = theme.Current.Muted
	}
	c.FillRect(f.R, bg)
	// The existing widget text painter is intentionally reused. The caret is a
	// one-cell accent line at the caret's cell, clamped to the plate.
	v, caret := f.Value(), f.Buffer.Caret()
	col := utf8.RuneCountInString(f.Prefix + v[:caret])
	if pre := f.composer().Preedit(); pre != "" {
		// A staged pre-edit is painted where it will land, in the accent
		// colour and underlined, between the text before and after the
		// caret. The text after it moves right by the pre-edit's cells,
		// as it will when the form commits.
		preW := utf8.RuneCountInString(pre)
		widgets.DrawText(c, f.R, f.Prefix+v[:caret], fg)
		widgets.DrawText(c, f.cellPlate(col), pre, f.Caret)
		widgets.DrawText(c, f.cellPlate(col+preW), v[caret:], fg)
		// The underline sits one row under the glyph, where the painter puts
		// it (centred in the inset plate, never above its top edge).
		glyphY := f.R.Y + 2 + (f.R.H-4-8)/2
		if glyphY < f.R.Y+2 {
			glyphY = f.R.Y + 2
		}
		if y := glyphY + 8; y < f.R.Bottom() {
			c.FillRect(widgets.Rect{X: f.R.X + 2 + col*glyphW, Y: y, W: preW * glyphW, H: 1}, f.Caret)
		}
		col += preW
	} else {
		text := f.Prefix + v
		if text == "" && f.Placeholder != "" {
			text = f.Placeholder
		}
		widgets.DrawText(c, f.R, text, fg)
	}
	if f.Focused {
		x := f.R.X + 2 + col*glyphW
		if x >= f.R.Right()-2 {
			x = f.R.Right() - 3
		}
		if x < f.R.X+2 {
			x = f.R.X + 2
		}
		c.FillRect(widgets.Rect{X: x, Y: f.R.Y + 2, W: 2, H: f.R.H - 4}, f.Caret)
	}
	// The candidate strip: every form the staged pre-edit can commit, one
	// row under the plate, the shown form in the accent colour and
	// underlined. Composers without alternates report nothing.
	if forms, sel := f.composer().Candidates(); len(forms) > 0 {
		x := f.R.X + 2
		y := f.R.Bottom() + 1
		for i, s := range forms {
			rgb := fg
			if i == sel {
				rgb = f.Caret
			}
			w := utf8.RuneCountInString(s) * glyphW
			widgets.DrawText(c, widgets.Rect{X: x, Y: y, W: w + 4, H: 10}, s, rgb)
			if i == sel {
				c.FillRect(widgets.Rect{X: x + 2, Y: y + 9, W: w, H: 1}, f.Caret)
			}
			x += w + 4 + glyphW
		}
	}
}

// drawCanvas is the full-Canvas form of Draw: the §2.2 rounded recessed plate
// with a border and an inside focus ring, and text through Canvas.Text — the
// face's own advances when Face is set, the bitmap degrade (which never
// blanks the label) when it is not.
func (f *TextField) drawCanvas(c widgets.Canvas, fg, bg uint32) {
	th := theme.Current
	if f.Disabled {
		fg = th.Muted
		bg = blendHalf(bg, th.Surface)
	}
	c.FillRoundedRect(f.R, 4, draw.Opaque(bg))
	c.StrokeRoundedRect(f.R, 4, th.BorderW, draw.Opaque(th.Border))
	if f.Focused && !f.Disabled {
		c.StrokeRoundedRect(f.R, 4, th.FocusW, draw.Opaque(th.Accent))
	}
	inner := f.R.Inset(th.BorderW)
	if inner.Empty() {
		return
	}
	x0 := inner.X + th.PadXS
	// advance measures a run the way paintRun will draw it: the chain's
	// cascade measure when Chain is set, Face pixels otherwise, or 8px
	// cells under the bitmap fallback — the preedit splits the run either
	// way.
	advance := func(s string) int {
		if f.Chain != nil {
			if w := f.Chain.Measure(s, labelPx); w > 0 {
				return w
			}
		}
		if f.Face == nil {
			return utf8.RuneCountInString(s) * glyphW
		}
		w := 0
		for _, r := range s {
			w += f.Face.AdvancePx(r, labelPx)
		}
		return w
	}
	v, caret := f.Value(), f.Buffer.Caret()
	before, after := f.Prefix+v[:caret], v[caret:]
	caretX := x0 + advance(before)
	if pre := f.composer().Preedit(); pre != "" {
		f.paintRun(c, inner, x0, before, fg)
		f.paintRun(c, inner, x0+advance(before), pre, f.Caret)
		f.paintRun(c, inner, x0+advance(before)+advance(pre), after, fg)
		// The underline sits just under the staged text — the painting
		// face's descender line, or one row under the bitmap glyph like
		// Draw does.
		uy := inner.Y + 2 + (inner.H-4-8)/2 + 8
		if uy < inner.Y+2 {
			uy = inner.Y + 2
		}
		if m := f.faceMetrics(); m != nil {
			asc, desc, _ := m.LineMetrics(labelPx)
			uy = inner.Y + (inner.H-asc-desc)/2 + asc + desc
		}
		if uy >= inner.Bottom() {
			uy = inner.Bottom() - 1
		}
		c.FillRect(widgets.Rect{X: x0 + advance(before), Y: uy, W: advance(pre), H: 1}, draw.Opaque(f.Caret))
		caretX += advance(pre)
	} else {
		text := f.Prefix + v
		if text == "" && f.Placeholder != "" {
			text = f.Placeholder
		}
		f.paintRun(c, inner, x0, text, fg)
	}
	if f.Focused {
		if caretX >= inner.Right()-2 {
			caretX = inner.Right() - 3
		}
		if caretX < x0 {
			caretX = x0
		}
		c.FillRect(widgets.Rect{X: caretX, Y: inner.Y + 2, W: 2, H: inner.H - 4}, draw.Opaque(f.Caret))
	}
	// The candidate strip: every form the staged pre-edit can commit, one
	// row under the plate, the shown form in the caret colour and
	// underlined, the rest muted. Composers without alternates report
	// nothing, so the strip only ever shows while composing.
	if forms, sel := f.composer().Candidates(); len(forms) > 0 {
		strip := widgets.Rect{X: x0, Y: f.R.Bottom() + 2, W: inner.Right() - x0, H: labelPx + 7}
		x := x0
		for i, s := range forms {
			rgb := th.Muted
			if i == sel {
				rgb = f.Caret
			}
			f.paintRun(c, strip, x, s, rgb)
			w := advance(s)
			if i == sel {
				c.FillRect(widgets.Rect{X: x, Y: strip.Bottom() - 1, W: w, H: 1}, draw.Opaque(f.Caret))
			}
			x += w + glyphW
		}
	}
}

// faceMetrics is the face whose metrics govern the field's TrueType
// painting: the chain's primary when a chain is armed and loaded, else
// the single Face. nil means the bitmap degrade is painting.
func (f *TextField) faceMetrics() *ttf.Face {
	if f.Chain != nil {
		if p := f.Chain.Primary(); p != nil {
			return p
		}
	}
	return f.Face
}

// paintRun paints s with the pen at x. A loaded Chain takes the whole run
// through its cascade so kana reach the coverage face; a nil face keeps
// §3.4's bitmap degrade — which anchors at the plate's own inset, so the
// clip is shifted to land the run at x.
func (f *TextField) paintRun(c widgets.Canvas, clip widgets.Rect, x int, s string, rgb uint32) {
	if s == "" {
		return
	}
	if f.Chain != nil && f.Chain.Primary() != nil {
		asc, desc, _ := f.Chain.Primary().LineMetrics(labelPx)
		y := clip.Y + (clip.H-asc-desc)/2 + asc
		draw.TextChain(c, f.Chain, clip, x, y, labelPx, s, draw.Opaque(rgb))
		return
	}
	y := 0
	if f.Face != nil {
		asc, desc, _ := f.Face.LineMetrics(labelPx)
		y = clip.Y + (clip.H-asc-desc)/2 + asc
	} else {
		clip = widgets.Rect{X: x - 2, Y: clip.Y, W: clip.Right() - x + 2, H: clip.H}
	}
	c.Text(f.Face, clip, x, y, labelPx, s, draw.Opaque(rgb))
}

// blendHalf is the §2.3 disabled blend: 50% per-channel toward b. Kept local
// so appkit needs no new export from widgets for one formula.
func blendHalf(a, b uint32) uint32 {
	return (a & b) + (((a ^ b) >> 1) & 0x7f7f7f)
}

// cellPlate is the field's plate shifted right by col text cells, so a run
// painted into it starts at that cell and is still clipped to the field.
func (f *TextField) cellPlate(col int) widgets.Rect {
	p := f.R
	p.X += col * glyphW
	p.W -= col * glyphW
	return p
}
