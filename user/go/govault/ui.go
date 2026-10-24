// ui.go — the face the seat sees: the masked input field (a byte buffer so
// secret input can be zeroed), the 8x8 run-lit text painter, the chrome and
// per-face draw routines. Nothing in this file touches a seam var or a
// vaultlib secret beyond what the model already holds — it renders state,
// it does not change it.
package main

import (
	"unicode/utf8"

	"virelai/clockfmt"
	"virelai/draw"
	"virelai/theme"
	"virelai/vaultlib"
	"virelai/vi"
	"virelai/webrender/font"
	"virelai/widgets"
)

// field is one input row. buf holds UTF-8; masked fields paint one '*' per
// rune. Kept as bytes so clear() can zero secret input — a string field
// could never be wiped.
type field struct {
	label  string
	buf    []byte
	max    int
	masked bool
}

func newField(label string, max int, masked bool) field {
	return field{label: label, max: max, masked: masked}
}

// insert appends one rune whole; the bound refuses rather than truncating
// mid-encoding.
func (f *field) insert(r rune) bool {
	var enc [utf8.UTFMax]byte
	n := utf8.EncodeRune(enc[:], r)
	if len(f.buf)+n > f.max {
		return false
	}
	f.buf = append(f.buf, enc[:n]...)
	return true
}

// backspace removes the last rune whole and zeroes its bytes.
func (f *field) backspace() bool {
	if len(f.buf) == 0 {
		return false
	}
	_, n := utf8.DecodeLastRune(f.buf)
	vaultlib.Zero(f.buf[len(f.buf)-n:])
	f.buf = f.buf[:len(f.buf)-n]
	return true
}

// clear zeroes and empties the buffer.
func (f *field) clear() {
	vaultlib.Zero(f.buf)
	f.buf = f.buf[:0]
}

// shown is what the field paints: the text, or one bullet per rune.
func (f *field) shown() string {
	if !f.masked {
		return string(f.buf)
	}
	n := utf8.RuneCount(f.buf)
	out := make([]byte, n)
	for i := range out {
		out[i] = '*'
	}
	return string(out)
}

// --- drawing ---------------------------------------------------------------

const (
	chromeH = 24
	fieldH  = 18
	rowH    = 14
	pad     = 12
)

func (a *app) fill(cv widgets.Canvas, x, y, w, h int, rgb uint32) {
	if cv == nil || w <= 0 || h <= 0 {
		return
	}
	cv.FillRect(widgets.Rect{X: x, Y: y, W: w, H: h}, draw.Opaque(rgb))
}

// text paints a string in the 8x8 face, one lit run per glyph row — NOTE's
// raster discipline (the webrender font package without its layout weight).
func (a *app) text(cv widgets.Canvas, x, y int, s string, rgb uint32) {
	cx := x
	for _, ch := range s {
		g := font.Glyph8(ch)
		for row := 0; row < 8; row++ {
			bits := g[row]
			col := 0
			for col < 8 {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				a.fill(cv, cx+col, y+row, run, 1, rgb)
				col += run
			}
		}
		cx += font.Advance(1)
	}
}

func (a *app) draw() {
	cv := a.ta.Canvas()
	if cv == nil {
		return
	}
	tok := theme.Current
	w, h := int(a.ta.W), int(a.ta.H)
	if w <= 0 || h <= 0 {
		w, h = natW, natH
	}
	a.fill(cv, 0, 0, w, chromeH, tok.Surface)
	a.fill(cv, 0, chromeH, w, h-chromeH, tok.Bg)

	state := "LOCKED"
	if a.m.scr == scrList || a.m.scr == scrAdd || a.m.scr == scrReceipts {
		state = "OPEN"
	}
	a.text(cv, pad, 8, appTitle+"   "+state, tok.Ink)
	a.fill(cv, 0, chromeH-1, w, 1, tok.Rule)

	switch a.m.scr {
	case scrNew:
		a.drawNew(cv, w, h)
	case scrLocked:
		a.drawLocked(cv, w, h)
	case scrBadFile:
		a.drawBadFile(cv, w, h)
	case scrList:
		a.drawList(cv, w, h)
	case scrAdd:
		a.drawAdd(cv, w, h)
	case scrReceipts:
		a.drawReceipts(cv, w, h)
	case scrExport:
		a.drawExport(cv, w, h)
	case scrImport:
		a.drawImport(cv, w, h)
	}

	// The picker is a modal plate over the list face — painted last, the
	// same overlay rule GOEDIT keeps.
	if a.picking {
		a.pick.Draw(cv)
	}

	if a.status != "" {
		a.text(cv, pad, h-16, a.status, tok.InkMuted)
	}
}

// fieldRow paints one labeled input row: label, a plated line of the
// shown() text, and a caret tick on the focused field.
func (a *app) fieldRow(cv widgets.Canvas, y int, f *field, focused bool) {
	tok := theme.Current
	a.text(cv, pad, y+5, f.label, tok.Muted)
	fx := pad + 96
	fw := int(a.ta.W) - fx - pad
	if fw < 40 {
		fw = 40
	}
	face := tok.Surface
	if focused {
		face = tok.BtnIdle
	}
	a.fill(cv, fx, y, fw, fieldH, face)
	a.fill(cv, fx, y+fieldH-1, fw, 1, tok.Border)
	a.text(cv, fx+4, y+5, f.shown(), tok.Ink)
	if focused {
		caretX := fx + 4 + font.Advance(1)*utf8.RuneCount(f.buf)
		a.fill(cv, caretX, y+4, 2, fieldH-8, tok.Accent)
	}
}

func (a *app) drawNew(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "No vault yet — choose a passphrase", tok.Text)
	a.fieldRow(cv, chromeH+44, &a.pass, a.focus == 0)
	a.fieldRow(cv, chromeH+44+fieldH+10, &a.conf, a.focus == 1)
	a.text(cv, pad, h-32, "tab next · ⏎ create · esc quit", tok.Muted)
}

func (a *app) drawLocked(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "Vault is locked", tok.Text)
	a.fieldRow(cv, chromeH+44, &a.pass, true)
	a.text(cv, pad, h-32, "⏎ unlock · esc quit", tok.Muted)
}

func (a *app) drawBadFile(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "vault: bad file", tok.Text)
	a.text(cv, pad, chromeH+36, "the file is not a GVLT vault", tok.Muted)
	a.text(cv, pad, h-32, "esc quit", tok.Muted)
}

// drawList paints the vaultlib.Entry rows. A hidden secret is a FIXED bullet width —
// the length of a secret is information too — and only the revealed row's
// own bytes are painted.
func (a *app) drawList(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	if len(a.m.entries) == 0 {
		a.text(cv, pad, chromeH+16, "Vault is empty", tok.Muted)
	}
	y := chromeH + 8
	for i := range a.m.entries {
		if y+rowH > h-40 {
			break
		}
		if i == a.m.sel {
			a.fill(cv, 0, y, w, rowH, tok.Surface)
			a.fill(cv, 0, y, 3, rowH, tok.Accent)
		}
		e := &a.m.entries[i]
		name := string(e.Name)
		if len(name) > 20 {
			name = name[:20]
		}
		a.text(cv, pad, y+3, name, tok.Text)
		secret := "********"
		if a.m.revealed(i) {
			secret = string(e.Secret)
		}
		a.text(cv, pad+176, y+3, secret, tok.Muted)
		// M156c: a seeded vaultlib.Entry shows its live six-digit code and the
		// seconds left in the step — the code is a render of the seed, not
		// the stored text, so a stale frame can never show a dead code.
		if len(e.Totp) > 0 {
			code := "------ --s"
			if key, ok := decodeSeed(e.Totp); ok {
				if v, ok := totpAt(key, timeFn(), 6); ok {
					code = sixDigits(v) + " " + vi.Itoa64(int64(totpLeft(timeFn()))) + "s"
				}
				vaultlib.Zero(key)
			}
			a.text(cv, pad+288, y+3, code, tok.Accent)
		}
		note := string(e.Note)
		if len(note) > 14 {
			note = note[:14]
		}
		a.text(cv, pad+376, y+3, note, tok.InkMuted)
		y += rowH
	}
	a.text(cv, pad, h-32, "a add · r reveal · c copy · e export · i import · v receipts · ctrl-l lock", tok.Muted)
}

// sixDigits renders a TOTP value as its zero-padded six-digit string.
func sixDigits(v uint32) string {
	var b [6]byte
	for i := 5; i >= 0; i-- {
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[:])
}

// drawReceipts lists the loaded receipts — the newest rows at the bottom,
// tail-windowed to fit the face (a log's freshest rows are the ones a
// reviewer is reaching for). A corrupt row is shown verbatim: hiding it
// would pretend the file never carried it.
func (a *app) drawReceipts(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "Receipts", tok.Text)
	rows := a.m.rcpts
	if len(rows) == 0 {
		a.text(cv, pad, chromeH+36, "no receipts yet", tok.Muted)
	}
	fit := (h - 40 - (chromeH + 8)) / rowH
	start := 0
	if fit > 0 && len(rows) > fit {
		start = len(rows) - fit
	}
	y := chromeH + 8
	for i := start; i < len(rows); i++ {
		r := &rows[i]
		if !r.ok {
			a.text(cv, pad, y+3, r.raw, tok.Muted)
			y += rowH
			continue
		}
		a.text(cv, pad, y+3, clockfmt.Format(r.epoch, clockfmt.UTC), tok.Muted)
		a.text(cv, pad+204, y+3, r.action, tok.Text)
		name := r.name
		if len(name) > 24 {
			name = name[:24]
		}
		a.text(cv, pad+292, y+3, name, tok.InkMuted)
		y += rowH
	}
	a.text(cv, pad, h-32, "v back · ctrl-l lock · esc back", tok.Muted)
}

func (a *app) drawAdd(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "New vaultlib.Entry", tok.Text)
	a.fieldRow(cv, chromeH+44, &a.add[0], a.focus == 0)
	a.fieldRow(cv, chromeH+44+fieldH+10, &a.add[1], a.focus == 1)
	a.fieldRow(cv, chromeH+44+2*(fieldH+10), &a.add[2], a.focus == 2)
	a.fieldRow(cv, chromeH+44+3*(fieldH+10), &a.add[3], a.focus == 3)
	a.text(cv, pad, chromeH+44+3*(fieldH+10)+fieldH+8, "totp: base32 seed or otpauth:// URI (optional)", tok.Muted)
	a.text(cv, pad, h-32, "tab next · ⏎ store · esc cancel", tok.Muted)
}

// drawExport is the bundle-passphrase face after a save pick: two masked
// fields guard the GVLX write, same shape as the create pair.
func (a *app) drawExport(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "Export vault to "+a.pickPath, tok.Text)
	a.text(cv, pad, chromeH+36, "bundle passphrase (separate from the vault's)", tok.Muted)
	a.fieldRow(cv, chromeH+64, &a.pass, a.focus == 0)
	a.fieldRow(cv, chromeH+64+fieldH+10, &a.conf, a.focus == 1)
	a.text(cv, pad, h-32, "tab next · ⏎ export · esc cancel", tok.Muted)
}

// drawImport is the bundle-passphrase face after an open pick: one masked
// field, then the merge.
func (a *app) drawImport(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "Import bundle "+a.pickPath, tok.Text)
	a.fieldRow(cv, chromeH+64, &a.pass, true)
	a.text(cv, pad, h-32, "⏎ import · esc cancel", tok.Muted)
}
