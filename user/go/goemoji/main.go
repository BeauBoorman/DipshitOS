// Command goemoji is GOEMOJI.ELF (M146a, issue #2799): the emoji picker.
// See table.go for the scope note. Layout (native 512x384, scaled by
// tabapp on resize): a tab strip (Emoji / Compose / Kaomoji plus the
// stay-open toggle), the search field, the content region — the covered
// grid, the kernel compose pairs, or the kaomoji dozen — and a status
// line naming the selection and the pick contract.
//
// M152c (issue #2917) adds the shelf: on the Emoji tab an empty query
// shows the pinned favorites row above the recents row (the last picks),
// and F10 pins or unpins the focused cell. Both lists ride save_state v2
// through the seat's snapshot; a fresh summon still starts empty — the
// named limitation is that close-on-pick drops the instance, so recents
// accumulate only in stay mode and across a seat restore.
//
// Every marker below is printed only AFTER its syscall returned (or, for
// paint, after Present), so the go-emoji VZ gate's asserts can only pass
// if the app actually ran.

package main

import (
	"virelai/appkit"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/ttf"
	"virelai/vi"
	"virelai/vsys"
	"virelai/widgets"
)

const (
	appName  = "GOEMOJI.ELF"
	appTitle = "Emoji"
	natW     = 512
	natH     = 384

	markerOpen     = "goemoji: open id="
	markerDeclare  = "goemoji: declare accepted"
	markerRefused  = "goemoji: declare refused"
	markerPresent  = "goemoji: present"
	markerFonts    = "goemoji: fonts "
	markerTab      = "goemoji: tab "
	markerFilter   = "goemoji: filter q="
	markerPick     = "goemoji: pick "
	markerClip     = "goemoji: clip text/plain n="
	markerClipErr  = "goemoji: clip refuse rc="
	markerStay     = "goemoji: stay "
	markerClose    = "goemoji: close"
	markerOK       = "goemoji OK"
	markerOpenErr  = "goemoji: error open "
	markerFavs     = "goemoji: favs "
	markerRecents  = "goemoji: recents "
	markerSaved    = "goemoji: state saved len="
	markerRestored = "goemoji: state restored "

	queryMax = 64
)

const (
	tabEmoji = iota
	tabCompose
	tabKaomoji
	tabCount
)

var tabNames = [tabCount]string{"Emoji", "Compose", "Kaomoji"}

// uhex formats a codepoint as the status/pick line's "U+XXXX" tag —
// uppercase, at least four digits (fmt stays out of the image budget).
func uhex(cp rune) string {
	var buf [8]byte
	i := len(buf)
	v := uint32(cp)
	if v == 0 {
		i--
		buf[i] = '0'
	}
	for v > 0 {
		i--
		d := v & 15
		if d < 10 {
			buf[i] = '0' + byte(d)
		} else {
			buf[i] = 'A' - 10 + byte(d)
		}
		v >>= 4
	}
	for len(buf)-i < 4 {
		i--
		buf[i] = '0'
	}
	return "U+" + string(buf[i:])
}

type app struct {
	ta    *tabapp.TabApp
	tab   int
	stay  bool
	chain *ttf.Chain
	field appkit.TextField

	favs    []int // glyph indices, pin order (M152c)
	recents []int // glyph indices, most recent first

	sel       int // index into matches
	matches   []int
	scrollTop int
	quit      bool
	quitCode  int
}

func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

func main() {
	loadGuestTheme()
	// The state hooks: SaveState serializes the live app through the
	// closure; RestoreState fires INSIDE tabapp.Init, before the app
	// exists (the gofiles shape) — it only stashes the blob, the apply
	// lands once the app and its search field are built below.
	var restored []byte
	var restoredOK bool
	// The declared title doubles as the seat's session-row bin: guessBin
	// maps titles to binaries and "Emoji" has no row (that table is
	// #2870's), so declaring the real name keeps a restored row's re-exec
	// able to find — and grant — GOEMOJI.ELF. The retitle below puts the
	// friendly label back on the rail.
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appName, X: 32, Y: 32, W: natW, H: natH,
		StateVersion: stateVerShelf,
		RestoreState: func(b []byte) {
			restored, restoredOK = b, true
		},
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
		_ = ta.SetTabTitle(appTitle)
	} else {
		vi.ConsoleLine(markerRefused)
	}

	a := &app{ta: ta}
	a.field = appkit.NewTextField(widgets.Rect{}, queryMax)
	a.field.Focused = true
	a.field.Placeholder = "search names"
	reg, note := draw.LoadRegistry()
	if reg != nil {
		a.chain = reg.Chain(ttf.Query{Role: "ui"})
	}
	vi.ConsoleLine(markerFonts + note)

	ta.SaveState = a.saveState
	if restoredOK {
		a.restoreState(restored, ta.RestoredVersion)
	}
	a.refilter()

	loop := appkit.NewLoop(ta, a.draw, a.handle)
	loop.OnInitialPresent = func() { vi.ConsoleLine(markerPresent) }
	loop.ShouldQuit = func() (int, bool) { return a.quitCode, a.quit }
	loop.OnExit = func(status int) {
		vi.ConsoleLine(markerClose)
		vi.ConsoleLine(markerOK)
		ta.CloseAndExit(status)
	}
	_ = loop.SubscribeSetting("theme", func(value string) bool { return theme.Set(value) })
	// The save_state ask is mailbox traffic, not an input event: answer it
	// once per pass (the gomine shape) so the seat's snapshot and tab-close
	// collects always get this tab's blob.
	loop.RunWith(func() (vi.Event, int64, bool) {
		if a.ta.PollStateAsk() {
			vi.ConsoleLine(markerSaved + vi.Itoa64(int64(len(a.saveState()))))
		}
		return vi.PollEventRaw()
	}, vi.Sleep)
}

// --- state (M125a + M152c): the flags, the shelf, and the live query ride
// the tab state. The envelope's appver tags the layout: v2 inserts the
// favorites and recents cp lists between the flag byte and the query tail;
// a v1 blob (`tab | stay | query`) still decodes with an empty shelf. ---

func (a *app) saveState() []byte {
	var tab, stay byte = '0', '0'
	if a.tab > 0 && a.tab < tabCount {
		tab = byte('0' + a.tab)
	}
	if a.stay {
		stay = '1'
	}
	out := []byte{tab, stay}
	out = shelfEncode(out, a.favs)
	out = shelfEncode(out, a.recents)
	return append(out, a.field.Value()...)
}

func (a *app) restoreState(b []byte, ver uint8) {
	if len(b) < 2 {
		return
	}
	if b[0] >= '0' && b[0] < byte('0'+tabCount) {
		a.tab = int(b[0] - '0')
	}
	a.stay = b[1] == '1'
	if ver < stateVerShelf {
		// v1: the rest of the blob was the query verbatim.
		a.field.SetValue(string(b[2:]))
		a.refilter()
		vi.ConsoleLine(markerRestored + "ver=1")
		return
	}
	// v2: a list whose declared count overruns the blob applies nothing —
	// the flags already landed, the shelf stays empty, and the query is
	// left unset rather than half-parsed.
	favs, off, ok := shelfDecode(b, 2)
	if !ok {
		return
	}
	recents, off, ok := shelfDecode(b, off)
	if !ok {
		return
	}
	a.favs = favs
	a.recents = recents
	a.field.SetValue(string(b[off:]))
	a.refilter()
	vi.ConsoleLine(markerRestored + "favs=" + vi.Itoa64(int64(len(a.favs))) +
		" recents=" + vi.Itoa64(int64(len(a.recents))))
	if len(a.favs) > 0 {
		vi.ConsoleLine(markerFavs + tagsOf(a.favs))
	}
	if len(a.recents) > 0 {
		vi.ConsoleLine(markerRecents + tagsOf(a.recents))
	}
}

// --- model ----------------------------------------------------------------

func (a *app) count() int {
	switch a.tab {
	case tabCompose:
		return len(compose)
	case tabKaomoji:
		return len(kaomoji)
	}
	return len(glyphs)
}

func (a *app) candidate(i int) (string, []string) {
	switch a.tab {
	case tabCompose:
		return composeName(compose[i]), nil
	case tabKaomoji:
		return kaomoji[i].Name, nil
	}
	g := glyphs[i]
	return g.Name, g.Aliases
}

// composeName is the searchable spelling of a pair: "e a -> á" plus the
// codepoint tag, so "acute", the key names and the hex tag all filter.
func composeName(c Compose) string {
	k1, _ := hidKey(c.First)
	k2, _ := hidKey(c.Second)
	return "alt+" + string(k1) + "+" + string(k2) + " " + string(c.CP) + " " + uhex(c.CP)
}

func (a *app) refilter() {
	q := a.field.Value()
	a.matches = filter(q, a.count(), a.candidate)
	if a.tab == tabEmoji && q == "" {
		a.matches = shelfView(a.favs, a.recents, a.matches)
	}
	if a.sel >= len(a.matches) {
		a.sel = len(a.matches) - 1
	}
	if a.sel < 0 {
		a.sel = 0
	}
	// A shelf pad is never a landing spot — the grid tail always supplies
	// a real cell after one.
	for a.sel+1 < len(a.matches) && a.matches[a.sel] == cellPad {
		a.sel++
	}
	if a.sel < len(a.matches) && a.matches[a.sel] == cellPad {
		a.sel = 0
	}
	a.scrollTop = 0
	if q != "" {
		vi.ConsoleLine(markerFilter + q + " n=" + vi.Itoa64(int64(len(a.matches))))
	}
}

// pickText is the bytes a pick puts on the clipboard.
func (a *app) pickText() (text, desc string, ok bool) {
	if a.sel < 0 || a.sel >= len(a.matches) {
		return "", "", false
	}
	i := a.matches[a.sel]
	if i < 0 {
		return "", "", false // a shelf pad cell carries no pick
	}
	switch a.tab {
	case tabCompose:
		c := compose[i]
		return string(c.CP), "compose " + uhex(c.CP), true
	case tabKaomoji:
		k := kaomoji[i]
		return k.Text, "kaomoji " + k.Name, true
	}
	g := glyphs[i]
	return string(g.CP), uhex(g.CP) + " " + g.Name, true
}

// pick writes the selection to the typed clipboard as text/plain and then
// honours the stay toggle: close, or clear the query for the next pick.
func (a *app) pick() bool {
	text, desc, ok := a.pickText()
	if !ok {
		return false
	}
	n, rc := vsys.ClipboardSetTyped(vsys.ClipText, []byte(text))
	if rc < 0 {
		vi.ConsoleLine(markerClipErr + vi.Itoa64(rc))
		return true
	}
	vi.ConsoleLine(markerPick + desc)
	vi.ConsoleLine(markerClip + vi.Itoa64(int64(n)))
	if a.tab == tabEmoji {
		a.noteRecent(a.matches[a.sel])
	}
	if !a.stay {
		a.quitCode = 0
		a.quit = true
		return true
	}
	a.field.Clear()
	a.sel = 0
	a.refilter()
	return true
}

func (a *app) setTab(t int) bool {
	if t == a.tab || t < 0 || t >= tabCount {
		return false
	}
	a.tab = t
	a.sel = 0
	a.refilter()
	vi.ConsoleLine(markerTab + tabNames[t])
	return true
}

// --- events ---------------------------------------------------------------

func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		return a.key(ev)
	case vi.EvMouseDown:
		return a.click(int(ev.Arg0), int(ev.Arg1), ev.Flags&vi.BtnLeft != 0)
	}
	return false
}

func (a *app) key(ev vi.Event) bool {
	k, ok := appkit.NormalizeKey(ev)
	if !ok || k.Ctrl || k.Alt {
		return false
	}
	switch k.Named() {
	case appkit.NamedTab:
		return a.setTab((a.tab + 1) % tabCount)
	case appkit.NamedEnter:
		return a.pick()
	case appkit.NamedEscape:
		if a.field.Value() == "" {
			return false
		}
		a.field.Clear()
		a.refilter()
		return true
	case appkit.NamedHome:
		return a.moveSel(-len(a.matches))
	case appkit.NamedEnd:
		return a.moveSel(len(a.matches))
	case appkit.NamedUp, appkit.NamedDown, appkit.NamedLeft, appkit.NamedRight:
		d := navDelta(a.tab, k.Named())
		return a.moveSel(d)
	case appkit.NamedF10:
		return a.toggleFav()
	}
	if a.field.OnKey(k) {
		a.sel = 0
		a.refilter()
		return true
	}
	return false
}

// navDelta maps an arrow to a selection delta: ±1 along a row or ±gridCols
// between rows on the grid tab, plain ±1 on the list tabs.
func navDelta(tab int, k appkit.NamedKey) int {
	cols := 1
	if tab == tabEmoji {
		cols = gridCols
	}
	switch k {
	case appkit.NamedLeft:
		return -1
	case appkit.NamedRight:
		return 1
	case appkit.NamedUp:
		return -cols
	case appkit.NamedDown:
		return cols
	}
	return 0
}

func (a *app) moveSel(d int) bool {
	if len(a.matches) == 0 {
		return false
	}
	// Step by d — ±1 along a row, ±gridCols between rows — then keep going
	// in the same direction while the landing cell is a shelf pad: pads
	// sit at section tails, so column steps stay column-aligned and row
	// steps walk past a pad block to the next real row.
	next := a.sel
	for {
		n := next + d
		if n < 0 {
			n = 0
		}
		if n >= len(a.matches) {
			n = len(a.matches) - 1
		}
		if n == next {
			return false
		}
		next = n
		if a.matches[next] != cellPad {
			break
		}
	}
	a.sel = next
	a.ensureVisible()
	return true
}

const (
	gridCols  = 6
	gridCellW = 80
	gridCellH = 58
	listRowH  = 26
	contentY  = 68
	contentH  = 276
)

func (a *app) visibleRows() int {
	if a.tab == tabEmoji {
		return (contentH / gridCellH) * gridCols
	}
	return contentH / listRowH
}

func (a *app) ensureVisible() {
	vis := a.visibleRows()
	if a.sel < a.scrollTop {
		a.scrollTop = a.sel
	}
	if a.sel >= a.scrollTop+vis {
		a.scrollTop = a.sel - vis + 1
	}
}

// scale maps a native layout rect into the live canvas — the same
// tabapp.Layout route every rect takes, so Draw and the click hit-test
// share one geometry under resize (the CALC-drift lesson).
func (a *app) scale(r widgets.Rect) widgets.Rect {
	s := a.ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}

// cellRect is the grid cell for position i (an index into matches), in
// canvas coordinates — the one geometry source for Draw and the click
// hit-test.
func (a *app) cellRect(pos int) widgets.Rect {
	rel := pos - a.scrollTop
	r, c := rel/gridCols, rel%gridCols
	return a.scale(widgets.Rect{X: 8 + c*gridCellW + 2, Y: contentY + r*gridCellH + 2, W: gridCellW - 4, H: gridCellH - 4})
}

func (a *app) rowRect(pos int) widgets.Rect {
	rel := pos - a.scrollTop
	return a.scale(widgets.Rect{X: 8, Y: contentY + rel*listRowH, W: natW - 16, H: listRowH - 2})
}

func (a *app) click(x, y int, left bool) bool {
	if !left {
		return false
	}
	// Tab strip.
	for t := 0; t < tabCount; t++ {
		if a.tabRect(t).Contains(x, y) {
			return a.setTab(t)
		}
	}
	if a.stayRect().Contains(x, y) {
		a.stay = !a.stay
		if a.stay {
			vi.ConsoleLine(markerStay + "on")
		} else {
			vi.ConsoleLine(markerStay + "off")
		}
		return true
	}
	// Content.
	for pos := a.scrollTop; pos < len(a.matches) && pos < a.scrollTop+a.visibleRows(); pos++ {
		if a.matches[pos] == cellPad {
			continue
		}
		var r widgets.Rect
		if a.tab == tabEmoji {
			r = a.cellRect(pos)
		} else {
			r = a.rowRect(pos)
		}
		if r.Contains(x, y) {
			if a.sel == pos {
				return a.pick()
			}
			a.sel = pos
			return true
		}
	}
	return false
}

func (a *app) tabRect(t int) widgets.Rect {
	return a.scale(widgets.Rect{X: 8 + t*76, Y: 8, W: 72, H: 22})
}

func (a *app) stayRect() widgets.Rect {
	return a.scale(widgets.Rect{X: natW - 88, Y: 8, W: 80, H: 22})
}

// --- paint ----------------------------------------------------------------

func (a *app) draw() {
	cv := a.ta.Canvas()
	if cv == nil {
		return
	}
	tok := theme.Current
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(tabapp.FillRGB()))
	a.drawTabs(cv, tok)
	a.field.R = a.scale(widgets.Rect{X: tok.PadMD, Y: 36, W: natW - 2*tok.PadMD, H: 24})
	a.field.Draw(cv)
	switch a.tab {
	case tabEmoji:
		a.drawGrid(cv, tok)
	case tabCompose:
		a.drawList(cv, tok, true)
	case tabKaomoji:
		a.drawList(cv, tok, false)
	}
	a.drawStatus(cv, tok)
}

func (a *app) drawTabs(cv widgets.Canvas, tok theme.Tokens) {
	for t := 0; t < tabCount; t++ {
		r := a.tabRect(t)
		face := tok.Surface
		fg := tok.InkMuted
		if t == a.tab {
			face = tok.Border
			fg = tok.Ink
		}
		cv.FillRect(r, draw.Opaque(face))
		widgets.DrawText(cv, r, tabNames[t], fg)
	}
	sr := a.stayRect()
	cv.FillRect(sr, draw.Opaque(tok.Surface))
	box := widgets.Rect{X: sr.X + 4, Y: sr.Y + 5, W: 12, H: 12}
	cv.FillRect(box, draw.Opaque(tok.Bg))
	if a.stay {
		cv.FillRect(box.Inset(3), draw.Opaque(tok.Accent))
	}
	widgets.DrawText(cv, widgets.Rect{X: sr.X + 20, Y: sr.Y, W: sr.W - 20, H: sr.H}, "stay", tok.InkMuted)
}

func (a *app) drawGrid(cv widgets.Canvas, tok theme.Tokens) {
	end := a.scrollTop + a.visibleRows()
	if end > len(a.matches) {
		end = len(a.matches)
	}
	for pos := a.scrollTop; pos < end; pos++ {
		if a.matches[pos] == cellPad {
			continue // a shelf pad stays window fill — the section break
		}
		g := glyphs[a.matches[pos]]
		cell := a.cellRect(pos)
		if pos == a.sel {
			cv.FillRect(cell, draw.Opaque(tok.Accent))
			cv.FillRect(cell.Inset(2), draw.Opaque(tok.Surface))
		} else {
			cv.FillRect(cell, draw.Opaque(tok.Surface))
		}
		paintGlyph(cv, g.Rows, cell.X+(cell.W-32)/2, cell.Y+3, 2, tok.Ink)
		name := widgets.Rect{X: cell.X, Y: cell.Y + 36, W: cell.W, H: 14}
		fg := tok.InkMuted
		if pos == a.sel {
			fg = tok.Ink
		}
		widgets.DrawText(cv, name, g.Name, fg)
	}
}

func (a *app) drawList(cv widgets.Canvas, tok theme.Tokens, isCompose bool) {
	end := a.scrollTop + a.visibleRows()
	if end > len(a.matches) {
		end = len(a.matches)
	}
	for pos := a.scrollTop; pos < end; pos++ {
		r := a.rowRect(pos)
		fg := tok.Ink
		if pos == a.sel {
			cv.FillRect(r, draw.Opaque(tok.Accent))
			cv.FillRect(r.Inset(1), draw.Opaque(tok.Border))
		} else {
			cv.FillRect(r, draw.Opaque(tok.Surface))
		}
		i := a.matches[pos]
		if isCompose {
			c := compose[i]
			label := "alt+" + string(mustKey(c.First)) + "+" + string(mustKey(c.Second)) +
				"   " + uhex(c.CP)
			widgets.DrawText(cv, widgets.Rect{X: r.X + 6, Y: r.Y, W: 210, H: r.H}, label, fg)
			a.chainText(cv, widgets.Rect{X: r.X + 220, Y: r.Y, W: 36, H: r.H}, string(c.CP), fg)
		} else {
			k := kaomoji[i]
			a.chainText(cv, widgets.Rect{X: r.X + 6, Y: r.Y, W: r.W - 110, H: r.H}, k.Text, fg)
			widgets.DrawText(cv, widgets.Rect{X: r.Right() - 100, Y: r.Y, W: 96, H: r.H}, k.Name, tok.InkMuted)
		}
	}
}

// chainText paints s through the font cascade when the registry loaded; a
// missing chain degrades to the bitmap face, which shows '?' for the
// non-ASCII runes — an honest empty-font answer, never a blank row.
func (a *app) chainText(cv widgets.Canvas, r widgets.Rect, s string, rgb uint32) {
	if a.chain == nil {
		widgets.DrawText(cv, r, s, rgb)
		return
	}
	f := a.chain.Primary()
	if f == nil {
		widgets.DrawText(cv, r, s, rgb)
		return
	}
	asc, desc, _ := f.LineMetrics(13)
	y := r.Y + (r.H-asc-desc)/2 + asc
	draw.TextChain(cv, a.chain, r, r.X+2, y, 13, s, draw.Opaque(rgb))
}

func mustKey(u uint8) byte {
	if b, ok := hidKey(u); ok {
		return b
	}
	return '?'
}

func (a *app) drawStatus(cv widgets.Canvas, tok theme.Tokens) {
	r := a.scale(widgets.Rect{X: 8, Y: natH - 26, W: natW - 16, H: 18})
	cv.FillRect(r, draw.Opaque(tok.Surface))
	_, desc, ok := a.pickText()
	line := ""
	if ok {
		line = desc + "  -  Enter copies"
		if a.tab == tabEmoji {
			line += "  F10 pins"
		}
	} else {
		line = "no match"
	}
	widgets.DrawText(cv, r, line, tok.InkMuted)
	n := vi.Itoa64(int64(len(a.matches))) + "/" + vi.Itoa64(int64(a.count()))
	widgets.DrawText(cv, widgets.Rect{X: r.Right() - 56, Y: r.Y, W: 50, H: r.H}, n, tok.InkMuted)
}

// paintGlyph draws the 16x16 monochrome art scaled by s — the same bitmap
// the kernel console's emoji cells paint (bit x = column x, LSB first).
func paintGlyph(cv widgets.Canvas, rows [16]uint16, x, y, s int, rgb uint32) {
	for gy := 0; gy < 16; gy++ {
		bits := rows[gy]
		for gx := 0; gx < 16; gx++ {
			if bits&(1<<uint(gx)) == 0 {
				continue
			}
			cv.FillRect(widgets.Rect{X: x + gx*s, Y: y + gy*s, W: s, H: s}, draw.Opaque(rgb))
		}
	}
}
