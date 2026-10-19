package appkit

import (
	"virelai/draw"
	"virelai/icons"
	"virelai/theme"
	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

// --- ErrorBanner ------------------------------------------------------------
//
// ErrorBanner is the M123d (#2578) inline failure surface — the in-app
// counterpart of M123a's seat toast: a strip the app's own frame paints,
// carrying the failure's text, a Copy Error button, and zero or more
// contextual action buttons (Replace/Cancel is the rename-conflict pair).
// It is NOT modal: it steals keys and clicks only while it is open, and it
// never draws outside R — an app keeps painting its own surface around it.
//
// Like Dialog, the state machine is pure: HandleKey/HandleMouse take events
// and set Choice, the app acts on the result (copy the text through its own
// clipboard seam, run the action, or just drop it). VT apps that cannot feed
// vi.Event drive the same machine through Activate/Dismiss/Cycle directly —
// GOFILES maps its keys.Event onto them, and renders Line(cols) where a
// canvas app would Draw.
type ErrorBanner struct {
	Open     bool
	Text     string         // the failure line: what draws and what Copy Error copies
	Actions  []BannerAction // contextual buttons, ahead of Copy Error
	Focus    int            // focused button index (Actions then Copy Error)
	Choice   string         // after close: an action ID, BannerCopy, or BannerDismiss
	R        widgets.Rect   // the strip; Draw, hit-test and layout all read it
	UIFace   *ttf.Face      // optional label face; nil → the 8x8 bitmap face
	IconFace *ttf.Face      // optional icon face for the warning glyph
}

// BannerAction is one contextual button. ID is the vocabulary word the app
// switches on when the banner resolves; Label is what the button says.
type BannerAction struct {
	ID    string
	Label string
}

// Result vocabulary for Choice. BannerCopy means the app should copy Text
// through its own clipboard seam — the banner does not syscall. BannerDismiss
// means closed with nothing chosen (Esc, Backspace, or the × button).
const (
	BannerDismiss = "dismiss"
	BannerCopy    = "copy"
)

// bannerCopyLabel is the always-present last button: every failure's text
// can leave the VM.
const bannerCopyLabel = "Copy Error"

// bannerH is the strip's natural height; callers size R.H to it (or taller
// — the content centres vertically).
const bannerH = 30

// BannerHeight is the suggested strip height for layout.
func BannerHeight() int { return bannerH }

// Show raises the banner with text and contextual actions. Focus defaults to
// the LAST action — the same safe-default convention NewConfirm holds (list
// the cancel-shaped action last so Enter never arms the destructive one);
// with no actions it lands on Copy Error, which is harmless.
func (b *ErrorBanner) Show(text string, actions ...BannerAction) {
	b.Open = true
	b.Text = text
	b.Actions = actions
	b.Choice = ""
	if len(actions) > 0 {
		b.Focus = len(actions) - 1
	} else {
		b.Focus = 0
	}
}

// buttonCount is the actions plus the trailing Copy Error.
func (b *ErrorBanner) buttonCount() int { return len(b.Actions) + 1 }

// buttonLabel names button i: an action's own label, or Copy Error's.
func (b *ErrorBanner) buttonLabel(i int) string {
	if i == len(b.Actions) {
		return bannerCopyLabel
	}
	return b.Actions[i].Label
}

// Activate chooses button i and closes. i == len(Actions) is Copy Error;
// out-of-range indices are a no-op so a stray digit can never arm an action.
func (b *ErrorBanner) Activate(i int) bool {
	if !b.Open || i < 0 || i >= b.buttonCount() {
		return false
	}
	if i == len(b.Actions) {
		b.Choice = BannerCopy
	} else {
		b.Choice = b.Actions[i].ID
	}
	b.Open = false
	return true
}

// ActivateFocused is Enter: the focused button's choice.
func (b *ErrorBanner) ActivateFocused() bool { return b.Activate(b.Focus) }

// CopyChoice is the keyboard Copy Error arm (the c key) — the same result
// as activating its button.
func (b *ErrorBanner) CopyChoice() bool { return b.Activate(len(b.Actions)) }

// Cycle moves the focus n steps over the buttons (Tab is +1).
func (b *ErrorBanner) Cycle(n int) bool {
	if !b.Open || b.buttonCount() == 0 {
		return false
	}
	b.Focus = (b.Focus + n) % b.buttonCount()
	if b.Focus < 0 {
		b.Focus += b.buttonCount()
	}
	return true
}

// Dismiss closes the banner with no choice made (Esc, Backspace, ×).
func (b *ErrorBanner) Dismiss() {
	b.Open = false
	b.Choice = BannerDismiss
}

// digitOf reads the one-digit action index out of a key event, accepting
// both spellings the event wire carries (HID usage 0x1e..0x26 and the
// decoded '1'..'9' rune) — the same dual-accept HandleKey holds for the
// named keys. -1 when the key is not a digit that maps to an action.
func digitOf(usage, ch uint32) int {
	d := -1
	if usage >= 0x1e && usage <= 0x26 {
		d = int(usage - 0x1e)
	}
	if ch >= '1' && ch <= '9' {
		d = int(ch - '1')
	}
	return d
}

// HandleKey consumes one event while the banner is open, with the Dialog
// vocabulary: Esc/Backspace dismiss, Tab cycles, Enter activates the focused
// button, a digit activates its action directly, and c is Copy Error. done
// means the banner resolved — Choice is set and Open cleared.
func (b *ErrorBanner) HandleKey(ev vi.Event) (changed, done bool) {
	if !b.Open || ev.Kind != vi.EvKeyDown {
		return false, false
	}
	usage, ch := ev.Arg0, ev.Arg1
	switch {
	case usage == 0x29 || ch == 0x1b || usage == 0x2a || ch == 0x08 || ch == 0x7f:
		b.Dismiss()
		return true, true
	case usage == 0x2b || ch == '\t':
		return b.Cycle(1), false
	case usage == 0x28 || ch == '\r' || ch == '\n':
		return true, b.ActivateFocused()
	case ch == 'c' || ch == 'C':
		// The rune only: the HID usage (0x06) also fires for Ctrl+C,
		// which stays the app's own chord, never a banner copy.
		return true, b.CopyChoice()
	}
	if d := digitOf(usage, ch); d >= 0 && d < len(b.Actions) {
		return true, b.Activate(d)
	}
	return false, false
}

// Contains reports whether (x, y) lands on the strip — a click inside that
// hits no button is still consumed, never a click on the surface beneath.
func (b *ErrorBanner) Contains(x, y int) bool { return b.Open && b.R.Contains(x, y) }

// HandleMouse handles a left press at a canvas point: a button chooses, the
// × dismisses, anything else inside the strip is swallowed.
func (b *ErrorBanner) HandleMouse(x, y int, down bool) (changed, done bool) {
	if !b.Open || !down || !b.R.Contains(x, y) {
		return false, false
	}
	buttons, dismiss := b.layout()
	if dismiss.Contains(x, y) {
		b.Dismiss()
		return true, true
	}
	for i := range buttons {
		if buttons[i].Contains(x, y) {
			b.Focus = i
			return true, b.Activate(i)
		}
	}
	return true, false
}

// layout derives the button and dismiss rects from R — the one geometry
// source Draw and HandleMouse both read (the widget rule). The visual order
// is the action buttons, then Copy Error, then the × at the far right;
// placement walks right-to-left so the group hugs the strip's right edge.
func (b *ErrorBanner) layout() (buttons []widgets.Rect, dismiss widgets.Rect) {
	if b.R.Empty() {
		return nil, widgets.Rect{}
	}
	tok := theme.Current
	bh := b.R.H - 2*tok.PadSM
	if bh < 14 {
		bh = 14
	}
	by := b.R.Y + (b.R.H-bh)/2
	x := b.R.Right() - tok.PadSM
	dismiss = widgets.Rect{X: x - bh, Y: by, W: bh, H: bh}
	x = dismiss.X - tok.PadSM
	buttons = make([]widgets.Rect, b.buttonCount())
	for i := b.buttonCount() - 1; i >= 0; i-- {
		bw := b.labelW(b.buttonLabel(i)) + 2*tok.PadMD
		if bw < 44 {
			bw = 44
		}
		buttons[i] = widgets.Rect{X: x - bw, Y: by, W: bw, H: bh}
		x = buttons[i].X - tok.PadSM
	}
	return buttons, dismiss
}

// labelW measures a button label: the face's own advance when one resolves,
// the 8x8 bitmap advance otherwise — one width source for paint and hit.
func (b *ErrorBanner) labelW(s string) int {
	if b.UIFace != nil {
		if w := b.UIFace.Measure(s, bannerTextPx); w > 0 {
			return w
		}
	}
	return len(s) * 8
}

// bannerTextPx is the label size a face renders at — 11px, the hint/readout
// scale the kit already uses for small chrome.
const bannerTextPx = 11

// bannerText paints the one-line failure text and button labels. A face
// takes the TrueType path at bannerTextPx; the bitmap face fills 8x8 runs.
func (b *ErrorBanner) bannerText(c widgets.RectCanvas, clip widgets.Rect, x, y int, s string, rgb uint32) {
	if s == "" {
		return
	}
	if fc, ok := c.(widgets.Canvas); ok && b.UIFace != nil {
		asc, desc, _ := b.UIFace.LineMetrics(bannerTextPx)
		draw.Text(fc, b.UIFace, clip, x, y+(clip.H-asc-desc)/2+asc, bannerTextPx, s, rgb)
		return
	}
	// The bitmap face left-anchors inside its plate, so the centred x the
	// caller computed becomes the clip's own left edge — the right bound is
	// still the plate's, which is what the clip is for.
	if clip.Right() <= x {
		return
	}
	widgets.DrawText(c, widgets.Rect{X: x, Y: clip.Y, W: clip.Right() - x, H: clip.H}, s, rgb)
}

// Draw paints the strip: a Surface plate ringed in Border (rounded on a
// full Canvas, flat bands on a fill-only one), a Danger warning mark, the
// failure text left-aligned and clipped before the buttons, and the button
// group — focused carries the Accent ring, Copy Error reads accent-bordered
// like the dialog's primary — plus the × dismiss target.
func (b *ErrorBanner) Draw(c widgets.RectCanvas) {
	if !b.Open || b.R.Empty() {
		return
	}
	tok := theme.Current
	fc, full := c.(widgets.Canvas)
	if full {
		fc.FillRoundedRect(b.R, 6, draw.Opaque(tok.Surface))
		fc.StrokeRoundedRect(b.R, 6, tok.BorderW, draw.Opaque(tok.Border))
	} else {
		c.FillRect(b.R, tok.Surface)
		bw := tok.BorderW
		if bw < 1 {
			bw = 1
		}
		c.FillRect(widgets.Rect{X: b.R.X, Y: b.R.Y, W: b.R.W, H: bw}, tok.Border)
		c.FillRect(widgets.Rect{X: b.R.X, Y: b.R.Y + b.R.H - bw, W: b.R.W, H: bw}, tok.Border)
		c.FillRect(widgets.Rect{X: b.R.X, Y: b.R.Y + bw, W: bw, H: b.R.H - 2*bw}, tok.Border)
		c.FillRect(widgets.Rect{X: b.R.Right() - bw, Y: b.R.Y + bw, W: bw, H: b.R.H - 2*bw}, tok.Border)
	}
	text, muted := tok.Text, tok.Muted
	danger := tok.Danger
	if full {
		text, muted, danger = draw.Opaque(text), draw.Opaque(muted), draw.Opaque(danger)
	}
	inner := b.R.Inset(tok.BorderW + tok.PadSM)
	if inner.Empty() {
		return
	}
	// The warning mark: the icon font's triangle on a full canvas, a plain
	// "!" on the fill-only degrade.
	mark := widgets.Rect{X: inner.X, Y: inner.Y, W: 16, H: inner.H}
	if full && b.IconFace != nil {
		if cp, ok := icons.Codepoint("warning-triangle"); ok {
			draw.Glyph(fc, b.IconFace, mark, mark.X, mark.Y+inner.H-4, icons.NominalPx, cp, danger)
		}
	} else {
		b.bannerText(c, mark, mark.X+4, mark.Y, "!", danger)
	}
	buttons, dismiss := b.layout()
	tx := mark.Right() + tok.PadSM
	tr := widgets.Rect{X: tx, Y: inner.Y, W: b.R.Right() - tx, H: inner.H}
	if len(buttons) > 0 {
		tr.W = buttons[0].X - tok.PadSM - tx
	}
	b.bannerText(c, tr, tx, tr.Y, b.Text, text)
	for i := range buttons {
		bface, border, label := tok.BtnIdle, tok.Border, text
		if i == b.Focus {
			bface, border = tok.BtnHover, tok.Accent
		}
		if i == len(b.Actions) {
			border = tok.Accent
		}
		if full {
			fc.FillRoundedRect(buttons[i], 4, draw.Opaque(bface))
			fc.StrokeRoundedRect(buttons[i], 4, tok.BorderW, draw.Opaque(border))
			if i == b.Focus {
				fc.StrokeRoundedRect(buttons[i], 4, tok.FocusW, draw.Opaque(tok.Accent))
			}
		} else {
			c.FillRect(buttons[i], bface)
			bw := tok.BorderW
			if bw < 1 {
				bw = 1
			}
			r := buttons[i]
			c.FillRect(widgets.Rect{X: r.X, Y: r.Y, W: r.W, H: bw}, border)
			c.FillRect(widgets.Rect{X: r.X, Y: r.Bottom() - bw, W: r.W, H: bw}, border)
			c.FillRect(widgets.Rect{X: r.X, Y: r.Y + bw, W: bw, H: r.H - 2*bw}, border)
			c.FillRect(widgets.Rect{X: r.Right() - bw, Y: r.Y + bw, W: bw, H: r.H - 2*bw}, border)
		}
		bl := buttons[i].Inset(tok.PadSM)
		lbl := b.buttonLabel(i)
		lw := b.labelW(lbl)
		lx := bl.X + (bl.W-lw)/2
		if lx < bl.X {
			lx = bl.X
		}
		b.bannerText(c, bl, lx, bl.Y, lbl, label)
	}
	// The dismiss ×: a bordered square, same hit rect layout() named.
	if full {
		fc.FillRoundedRect(dismiss, 4, draw.Opaque(tok.BtnIdle))
		fc.StrokeRoundedRect(dismiss, 4, tok.BorderW, draw.Opaque(tok.Border))
	} else {
		c.FillRect(dismiss, tok.BtnIdle)
		c.FillRect(widgets.Rect{X: dismiss.X, Y: dismiss.Y, W: dismiss.W, H: 1}, tok.Border)
		c.FillRect(widgets.Rect{X: dismiss.X, Y: dismiss.Bottom() - 1, W: dismiss.W, H: 1}, tok.Border)
		c.FillRect(widgets.Rect{X: dismiss.X, Y: dismiss.Y, W: 1, H: dismiss.H}, tok.Border)
		c.FillRect(widgets.Rect{X: dismiss.Right() - 1, Y: dismiss.Y, W: 1, H: dismiss.H}, tok.Border)
	}
	b.bannerText(c, dismiss.Inset(2), dismiss.X+dismiss.W/2-4, dismiss.Y, "x", muted)
}

// Line is the VT form — the same content EmptyState.Lines owes a text grid:
// the failure, then the action chord menu ([1] Replace [2] Cancel), then
// the standing affordances ([c] copy, [esc]). The caller styles and clips it
// (GOFILES' colWarn + clipVis own the colour and the column bound).
func (b *ErrorBanner) Line(cols int) string {
	if !b.Open {
		return ""
	}
	s := "! " + b.Text
	for i, a := range b.Actions {
		if i < 9 {
			s += " [" + string(rune('1'+i)) + "] " + a.Label
		}
	}
	s += " [c] copy [esc]"
	if cols > 0 && len(s) > cols {
		s = s[:cols]
	}
	return s
}
