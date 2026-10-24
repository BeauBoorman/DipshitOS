// layout.go — where everything sits: the pane layout over tabapp's
// scale-to-window, the per-view header and row labels, the M73m palette
// band, and the M104f row affordances (toggle, volume slider, dropdown)
// whose draw and hit-test share one geometry. What the rows mean is
// rows.go's; what the keys do is input.go's.
package main

import (
	"virelai/chords"
	"virelai/draw"
	"virelai/settings"
	"virelai/svcmanifest"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// --- paint ------------------------------------------------------------------

func (a *panel) layout() {
	ta := a.ta
	w := int(natW) - 16
	// M122e (#2574): the tab strip leads the pane — Settings / Services /
	// Grants / Shortcuts cells — with the view's own header line under it.
	a.tabs.R = scaleR(ta, widgets.Rect{X: 8, Y: 8, W: w, H: 20})
	a.tabs.Active = a.activeTab()
	a.headTxt = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 32, W: w, H: 14}),
		Label: a.headLabel(),
		Fg:    theme.Current.Text,
		Bg:    theme.Current.Surface,
	}
	// 18px rows: ten visible at a time; the rest of the table scrolls.
	scrollTop, focused := a.list.ScrollTop, a.list.Focused
	a.list = widgets.List{
		R:         scaleR(ta, widgets.Rect{X: 8, Y: 50, W: w, H: 184}),
		Items:     a.labels(),
		RowH:      scaleH(ta, 18),
		Sel:       a.sel,
		ScrollTop: scrollTop,
		Focused:   focused,
		Fg:        theme.Current.Text,
		Bg:        theme.Current.Bg,
		SelBg:     theme.Current.Surface,
	}
	// M73m: the palette band — three swatches + their stored values, drawn
	// under the list so the colours being chosen are visible, not just typed.
	for i := range a.paletteSwat {
		a.paletteSwat[i] = scaleR(ta, widgets.Rect{X: 8 + i*20, Y: 240, W: 16, H: 16})
	}
	fg, bg, accent := a.paletteColours()
	a.paletteTxt = widgets.Text{
		R: scaleR(ta, widgets.Rect{X: 72, Y: 240, W: int(natW) - 80, H: 16}),
		Label: "custom fg=" + paletteHex(fg) + " bg=" + paletteHex(bg) +
			" accent=" + paletteHex(accent),
		Fg: 0xa8b0b8,
		Bg: 0x101418,
	}
	a.input.R = scaleR(ta, widgets.Rect{X: 8, Y: 258, W: w, H: 22})
	a.input.Fg = 0xe0e8f0
	a.input.Bg = 0x161c24
	a.input.Caret = theme.Current.Caret
	a.input.Focused = false
	if current, _ := a.focus.Current(); current == &a.input {
		a.input.Focused = true
	}
	a.statusT = widgets.Text{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 286, W: w, H: 18}),
		Label: a.status,
		Fg:    0xa8b0b8,
		Bg:    0x101418,
	}
	a.saveBtn = widgets.Button{
		R:     scaleR(ta, widgets.Rect{X: 8, Y: 312, W: 88, H: 28}),
		Label: "Save",
	}
	a.quitBtn = widgets.Button{
		R:     scaleR(ta, widgets.Rect{X: int(natW) - 96, Y: 312, W: 88, H: 28}),
		Label: "Close",
	}
}

// headLabel names the surface the list is showing: the settings file's
// table, or the M82c shortcuts registry.
func (a *panel) headLabel() string {
	if a.showGrants {
		return "Grants  declared vs granted"
	}
	if a.showServices {
		return "Services  " + svcmanifest.Path
	}
	if a.showChords {
		return "Shortcuts  n=" + vi.Itoa64(int64(len(chords.Global))) + "  (one owner per chord)"
	}
	if a.showProfile {
		return "Profile  " + a.prof.Name + "  (read-only)"
	}
	if a.showAccess {
		return "Access  a11y.* — contrast, motion, text scale"
	}
	return "Settings  " + settings.Path
}

// labels renders the display table: the value in force for every row, with the
// seat-choosing key first so the row that matters is never off-screen. The
// palette rows (M73m) are first-class — never marked "(kept)", which is the
// marker for a key the kernel table does NOT carry.
//
// M82c (#1770): in the shortcuts view the same list renders the global
// chord registry instead — chord, owner, description — one owner per chord
// per dispatch point.
func (a *panel) labels() []string {
	if a.showGrants {
		return a.grants.Labels()
	}
	if a.showServices {
		return a.services.Labels()
	}
	if a.showChords {
		return chordLabels()
	}
	if a.showProfile {
		return a.profileLabels()
	}
	if a.showAccess {
		return a.accessLabels()
	}
	out := make([]string, 0, len(a.disp))
	for _, s := range a.disp {
		line := s.Key + " = " + s.Val
		if !settings.Editable(s.Key) {
			line += "  (kept)"
		}
		out = append(out, line)
	}
	return out
}

// accessLabels renders the M165b access tab's three rows. The text-scale
// row names its consumer: WEB scales its base text by it (M177a #3142).
func (a *panel) accessLabels() []string {
	out := make([]string, 0, len(a.accessRows))
	for _, s := range a.accessRows {
		line := s.Key + " = " + s.Val
		if s.Key == settings.A11yTextScaleKey {
			line += "  (honoured by WEB)"
		}
		out = append(out, line)
	}
	return out
}

// profileLabels renders the M128d summary as list rows — the armed
// profile's name, its base image, whether the base's .prev survives (a
// rollback target), and the stored snapshot count. A refused session is
// still a row: the guest reads the refusal's code instead of a blank.
func (a *panel) profileLabels() []string {
	if a.profVerdict != "" {
		return []string{"profile-info refused " + a.profVerdict}
	}
	rb := "no"
	if a.prof.Rollback {
		rb = "yes"
	}
	return []string{
		"name = " + a.prof.Name,
		"base = " + a.prof.Base,
		"rollback = " + rb,
		"snapshots = " + vi.Itoa64(int64(a.prof.Snapshots)),
	}
}

// chordLabels renders the shortcuts registry for the list: one line per
// row, chord first (the sorted-by-nothing, historical table order).
func chordLabels() []string {
	out := make([]string, 0, len(chords.Global))
	for _, r := range chords.Global {
		out = append(out, r.Chord.String()+"  "+r.Owner+"  "+r.Label)
	}
	return out
}

// paletteColours is the custom palette IN FORCE as RGB: the display table's
// stored six-hex values, else the compiled default for that row (the same
// fallback the kernel applies — a malformed stored value never paints).
func (a *panel) paletteColours() (fg, bg, accent uint32) {
	conv := func(key string) uint32 {
		if v, ok := settings.Get(a.disp, key); ok {
			if c, ok := settings.Colour(v); ok {
				return c
			}
		}
		if k, ok := settings.PaletteKey(key); ok {
			if c, ok := settings.Colour(k.Default); ok {
				return c
			}
		}
		return 0
	}
	return conv("palette_fg"), conv("palette_bg"), conv("palette_accent")
}

// paletteHex formats a 24-bit colour as the six stored digits (lowercase).
func paletteHex(v uint32) string {
	const digits = "0123456789abcdef"
	var b [6]byte
	for i := 5; i >= 0; i-- {
		b[i] = digits[v&0xf]
		v >>= 4
	}
	return string(b[:])
}

// --- row controls -----------------------------------------------------------
//
// M104f (#2273): the M104d controls ride the settings list as per-row
// affordances. {on,off} vocab rows get a Toggle, the audio_volume row gets
// the Slider (the §5.2 secondary consumer — its writes still flow through
// a.set → settings.Set → the slot-44 apply hook), and every other
// multi-valued row gets a dropdown affordance whose popover picks the value.
// Non-editable "(kept)" rows get none. All of it is geometry over the same
// canvas; the kernel's vocabulary, not the control, stays authoritative.

// rowRect is row i's slice of the list viewport (i is the absolute index).
func (a *panel) rowRect(i int) (widgets.Rect, bool) {
	lr, top := a.list.R, a.list.ScrollTop
	if i < top || i >= top+a.list.VisibleRows() || i >= len(a.activeRows()) {
		return widgets.Rect{}, false
	}
	ry := lr.Y + (i-top)*a.list.RowH
	if ry+a.list.RowH > lr.Bottom() {
		return widgets.Rect{}, false
	}
	return widgets.Rect{X: lr.X, Y: ry, W: lr.W, H: a.list.RowH}, true
}

// controlFor returns the affordance kind a row carries at its right edge.
// A two-value vocabulary carrying `off` is a toggle — {on,off} and
// {off,on} rows have always been, and M165b's {off,high} contrast row is
// the same gesture; the non-"off" member is the on position.
func rowControl(row settings.Setting) int {
	if !settings.Editable(row.Key) {
		return ctlNone
	}
	vocab, ok := settings.Vocab(row.Key)
	if !ok || len(vocab) < 2 {
		return ctlNone
	}
	if row.Key == settings.AudioVolumeKey {
		return ctlSlider
	}
	if len(vocab) == 2 && (vocab[0] == "off" || vocab[1] == "off") {
		return ctlToggle
	}
	return ctlDropdown
}

// toggleOnValue is the vocabulary member a two-position row reads as ON:
// the non-"off" half of an {off,x} pair — "on" for the on|off rows,
// "high" for a11y.contrast.
func toggleOnValue(vocab []string) string {
	for _, v := range vocab {
		if v != "off" {
			return v
		}
	}
	return "on"
}

const (
	ctlNone = iota
	ctlToggle
	ctlSlider
	ctlDropdown
)

// toggleRect/sliderRect/dropdownRect carve the affordance out of the row's
// right edge. They must agree between draw and click — one geometry source
// per control, same pattern as the widget Bounds() methods.
func toggleRect(rr widgets.Rect) widgets.Rect {
	return widgets.Rect{X: rr.Right() - 38, Y: rr.Y + (rr.H-16)/2, W: 32, H: 16}
}

func sliderRect(rr widgets.Rect) widgets.Rect {
	return widgets.Rect{X: rr.Right() - 100, Y: rr.Y + (rr.H-widgets.SliderKnobD)/2,
		W: 92, H: widgets.SliderKnobD}
}

func dropdownRect(rr widgets.Rect) widgets.Rect {
	return widgets.Rect{X: rr.Right() - 22, Y: rr.Y + (rr.H-14)/2, W: 18, H: 14}
}

// volumeSliderRect is the live audio row's slider geometry for drag updates.
func (a *panel) volumeSliderRect() (widgets.Rect, bool) {
	for i, row := range a.activeRows() {
		if row.Key == settings.AudioVolumeKey {
			if rr, ok := a.rowRect(i); ok {
				return sliderRect(rr), true
			}
		}
	}
	return widgets.Rect{}, false
}

// decade snaps a slider position to the audio_volume vocabulary's step-10
// ladder (the row's stored string, not a raw gain number).
func decade(v int) string {
	v = (v + 5) / 10 * 10
	if v < 0 {
		v = 0
	}
	if v > 100 {
		v = 100
	}
	return vi.Itoa64(int64(v))
}

// drawRowControls paints each visible settings row's affordance after the
// list rows — Toggles, the volume Slider, and the dropdown buttons.
func (a *panel) drawRowControls(cv widgets.RectCanvas) {
	// The affordances name SETTINGS rows: in the services, grants or
	// shortcuts panes the list renders other tables — a settings control
	// over a foreign row would paint (and hit-test) a lie. (M122e fixup:
	// grants was missing here — a grants row could wear row 0's toggle;
	// M128d's profile rows are facts, not settings vocabulary.) M165b's
	// access tab is NOT foreign — its three a11y rows are settings rows
	// and the toggles/dropdown are the view's whole point.
	if a.showServices || a.showGrants || a.showChords || a.showProfile {
		return
	}
	for i, row := range a.activeRows() {
		rr, ok := a.rowRect(i)
		if !ok {
			continue
		}
		switch rowControl(row) {
		case ctlToggle:
			vocab, _ := settings.Vocab(row.Key)
			(&widgets.Toggle{R: toggleRect(rr), On: row.Val == toggleOnValue(vocab), Focused: a.sel == i}).Draw(cv)
		case ctlSlider:
			v, _ := settings.AudioVolume(row.Val)
			(&widgets.Slider{R: sliderRect(rr), Min: 0, Max: 100,
				Value: v, Pressed: a.volDrag}).Draw(cv)
		case ctlDropdown:
			br := dropdownRect(rr)
			cv.FillRect(br, draw.Opaque(theme.Current.BtnIdle))
			cv.FillRect(br.Inset(1), draw.Opaque(theme.Current.Surface))
			// The affordance glyph is a 3-row triangle — font.Glyph8 has no
			// chevron, and a hand-placed wedge reads identically at 8px.
			tx, ty := br.X+5, br.Y+5
			for w := 7; w > 0; w -= 2 {
				cv.FillRect(widgets.Rect{X: tx + (7-w)/2, Y: ty, W: w, H: 1},
					draw.Opaque(theme.Current.Text))
				ty++
			}
		}
	}
}

// rowControlClick gives a left-click inside the list first shot at a row
// affordance; a miss falls through to the existing focus/list handling.
func (a *panel) rowControlClick(x, y int) bool {
	if a.showServices || a.showGrants || a.showChords || a.showProfile {
		return false
	}
	for i, row := range a.activeRows() {
		rr, ok := a.rowRect(i)
		if !ok {
			continue
		}
		switch rowControl(row) {
		case ctlToggle:
			if !toggleRect(rr).Contains(x, y) {
				continue
			}
			a.sel, a.list.Sel = i, i
			vocab, _ := settings.Vocab(row.Key)
			v := vocab[0]
			if row.Val == vocab[0] {
				v = vocab[1]
			}
			return a.set(row.Key, v)
		case ctlSlider:
			sr := sliderRect(rr)
			if !sr.Contains(x, y) {
				continue
			}
			a.sel, a.list.Sel = i, i
			a.volDrag = true
			s := widgets.Slider{R: sr, Min: 0, Max: 100}
			return a.set(row.Key, decade(s.ValueAt(x)))
		case ctlDropdown:
			if !dropdownRect(rr).Contains(x, y) {
				continue
			}
			a.sel, a.list.Sel = i, i
			vocab, _ := settings.Vocab(row.Key)
			a.dropdown.openAt(row.Key, vocab, rr, int(a.ta.H))
			return true
		}
	}
	return false
}

// dropdownClick resolves a click while the popover is open: inside → choose
// (or just close on the padding), outside → close without choosing.
func (a *panel) dropdownClick(x, y int) {
	d := &a.dropdown
	if i := d.optionAt(x, y); i >= 0 {
		key, v := d.key, d.vocab[i]
		d.open = false
		a.set(key, v)
		return
	}
	d.open = false
}

func (a *panel) draw() {
	a.layout()
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(theme.Current.Bg))
	a.tabs.Draw(cv)
	a.headTxt.Draw(cv)
	a.list.Draw(cv)
	a.drawRowControls(cv)
	// M73m: swatch plates — border first, colour inset, so a near-black bg
	// or a near-white fg is still visible against the panel.
	fg, bg, accent := a.paletteColours()
	for i, c := range [3]uint32{fg, bg, accent} {
		r := a.paletteSwat[i]
		cv.FillRect(r, draw.Opaque(theme.Current.Border))
		cv.FillRect(r.Inset(1), draw.Opaque(c))
	}
	a.paletteTxt.Draw(cv)
	a.input.Draw(cv)
	a.statusT.Draw(cv)
	a.saveBtn.Draw(cv)
	a.quitBtn.Draw(cv)
	// The dropdown popover is last: it floats over the rows below it.
	if a.dropdown.open {
		cur, _ := settings.Get(a.activeRows(), a.dropdown.key)
		a.dropdown.Draw(cv, cur)
	}
}

func scaleR(ta *tabapp.TabApp, r widgets.Rect) widgets.Rect {
	s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}

func scaleH(ta *tabapp.TabApp, h int) int {
	s := ta.Layout(tabapp.Rect{X: 0, Y: 0, W: 1, H: h}, natW, natH)
	if s.H < 1 {
		return 1
	}
	return s.H
}
