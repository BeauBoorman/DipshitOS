// M124d (#2583): the right-click context menu. A right-press on a list
// row selects it and opens the menu at the click cell; "Open" dispatches
// the entry exactly as Enter would, and "Open With…" hangs a submenu of
// every APPS.TXT handler whose opens= takes the file's mime (manifest.go
// is the wire read, opensAccepts the eligibility rule, fileMime the
// spelling both sides match against). The registry default is marked
// "(default)". The model stays pure — it decides and marks; the overlay
// paint lives in render.go and the exec in main's drainLaunch.
package main

import (
	"virelai/mime"
	"virelai/vi"
)

// ctxApp is one submenu row: the manifest entry that accepted the file's
// mime, plus whether it is the registry's default handler for the type.
type ctxApp struct {
	bin   string
	label string
	args  []string // argv= fixed arguments, ahead of the file path
	def   bool
}

// ctxMenu is the live context menu. name/path identify the entry the menu
// acts on; mimeT is the opens= match spelling ("" on an unreadable head —
// no row can claim it); mimeID feeds the registry default lookup and the
// chose marker's type= word. ax/ay anchor the top-level plate (0-based
// cell coords); sel/subSel are the highlighted rows.
type ctxMenu struct {
	name   string
	path   string
	mimeT  string
	mimeID mime.ID
	dir    bool
	vol    bool
	apps   []ctxApp
	ax     int
	ay     int
	sel    int
	subSel int
	sub    bool
}

// ctxTopLabels is the top-level plate's rows: "Open" always, "Open With…"
// on a real file. A directory or a volumes-root row has nothing to be
// handed to, so the submenu never exists for them.
func (m *model) ctxTopLabels() []string {
	if m.ctx.dir || m.ctx.vol {
		return []string{"Open"}
	}
	return []string{"Open", "Open With…"}
}

// ctxOpenWithRow is the top-level index of the submenu parent, or -1.
func (m *model) ctxOpenWithRow() int {
	for i, l := range m.ctxTopLabels() {
		if l == "Open With…" {
			return i
		}
	}
	return -1
}

// openCtx arms the menu for the row handleRightClick already selected,
// anchored at the clicked cell. The file half reads the head for the mime
// spelling and the manifest for the eligible handlers — both through the
// host-stubbed seams, so the DECISION is pinned without a guest.
func (m *model) openCtx(col, row int) {
	e, ok := m.selEntry()
	if !ok {
		return
	}
	m.mode = modeContext
	m.ctx = ctxMenu{name: e.NameString(), ax: col, ay: row}
	switch {
	case m.path == volsPath:
		m.ctx.vol = true
		m.emit(markerMenu + m.ctx.name + " volume")
	case e.Dir():
		m.ctx.dir = true
		m.emit(markerMenu + m.ctx.name + " dir")
	default:
		p, ok := joinPath(m.path, m.ctx.name)
		mt := "unreadable"
		if ok {
			m.ctx.path = p
			if head, rc := readHead(p, mime.HeadBytes); rc >= 0 {
				m.ctx.mimeID = mime.Sniff(m.ctx.name, head)
				m.ctx.mimeT = fileMime(m.ctx.name, head)
				mt = m.ctx.mimeT
				m.ctx.apps = ctxAppsFor(m.ctx.mimeT, m.ctx.mimeID)
			}
		}
		m.emit(markerMenu + m.ctx.name + " mime=" + mt +
			" apps=" + vi.Itoa64(int64(len(m.ctx.apps))))
	}
	m.status = "menu " + m.ctx.name
}

// ctxAppsFor lists the manifest handlers whose opens= takes mt, in
// manifest order, marking the registry's default for the type.
func ctxAppsFor(mt string, id mime.ID) []ctxApp {
	def := ""
	if h, ok := mime.Default(id); ok {
		def = h.Bin
	}
	var out []ctxApp
	for _, e := range loadApps() {
		if !opensAccepts(e.opens, mt) {
			continue
		}
		out = append(out, ctxApp{
			bin: e.bin, label: e.label, args: e.args, def: e.bin == def,
		})
	}
	return out
}

// ctxSubLabels is the submenu's row text: the app label, the default
// mark, and the honest empty row when nothing accepts the mime.
func (m *model) ctxSubLabels() []string {
	if len(m.ctx.apps) == 0 {
		return []string{"(no handlers)"}
	}
	out := make([]string, len(m.ctx.apps))
	for i, a := range m.ctx.apps {
		out[i] = a.label
		if a.def {
			out[i] += " (default)"
		}
	}
	return out
}

// handleRightClick maps a right SGR press (1-based cell coords) onto the
// list: a press on a row selects it and arms the menu there; a press off
// the list dismisses an open menu and is otherwise a no-op.
func (m *model) handleRightClick(x, y int) {
	// M123d (#2578): no menu may open while the error banner stands — the
	// strip is answered first.
	if m.banner.Open {
		return
	}
	if m.mode == modeQuickLook {
		// M149a (#2806): any press dismisses the pane, left or right.
		m.closeQuickLook()
		return
	}
	col, row := x-1, y-1
	if col < 0 || col >= m.cols || row < 2 || row >= 2+m.bodyRows() ||
		col >= m.listCols() {
		m.cancelCtx()
		return
	}
	idx := m.top + row - 2
	if idx < 0 || idx >= m.n {
		m.cancelCtx()
		return
	}
	m.sel = idx
	m.ensureSelVisible()
	m.loadPreview()
	m.openCtx(col, row)
}

// handleMenuClick routes a LEFT press while the menu is open: a submenu
// row chooses, the Open With… row descends, "Open" dispatches, and a
// press anywhere else dismisses without acting (a click meant to close
// the menu must not also open what it landed on).
func (m *model) handleMenuClick(x, y int) {
	col, row := x-1, y-1
	if m.ctx.sub {
		if sx, sy, sw, sh := m.ctxSubRect(); col >= sx && col < sx+sw &&
			row >= sy && row < sy+sh {
			m.ctxChooseSub(row - sy)
			return
		}
	}
	tx, ty, tw, th := m.ctxTopRect()
	if col >= tx && col < tx+tw && row >= ty && row < ty+th {
		i := row - ty
		if i == m.ctxOpenWithRow() {
			m.ctxOpenSub()
		} else {
			m.ctxActivate(i)
		}
		return
	}
	m.cancelCtx()
}

// ctxActivate commits top-level row i. "Open" is exactly the Enter
// gesture on the selected row — directory or volume navigation included —
// so the menu never grows a second dispatch of its own.
func (m *model) ctxActivate(i int) {
	labels := m.ctxTopLabels()
	if i < 0 || i >= len(labels) {
		return
	}
	if labels[i] == "Open With…" {
		m.ctxOpenSub()
		return
	}
	m.clearCtx()
	m.openSel()
}

// ctxOpenSub descends into the Open With… submenu. The candidate count is
// named even when it is zero — the submenu then shows the "(no handlers)"
// row, and the marker is what tells an empty list from a failed descent.
func (m *model) ctxOpenSub() {
	if m.ctxOpenWithRow() < 0 {
		return
	}
	m.ctx.sub = true
	m.ctx.subSel = 0
	m.emit(markerMenuSub + m.ctx.name + " mime=" + orDash(m.ctx.mimeT) +
		" candidates=" + vi.Itoa64(int64(len(m.ctx.apps))))
	m.status = "open with " + m.ctx.name
}

// ctxChooseSub commits submenu row j: the manifest entry launches with
// the file, its argv= tail ahead of the path on the exec line.
func (m *model) ctxChooseSub(j int) {
	if j < 0 || j >= len(m.ctx.apps) {
		return
	}
	a := m.ctx.apps[j]
	m.emit(markerOpenChose + m.ctx.name + " type=" + m.ctx.mimeID.String() +
		" handler=" + a.bin)
	m.launch = launchReq{bin: a.bin, path: m.ctx.path, args: a.args}
	m.clearCtx()
	m.status = "opening " + baseName(a.bin)
}

// ctxMove steps the highlight: inside the open submenu when it is open,
// the top-level plate otherwise.
func (m *model) ctxMove(delta int) {
	if m.ctx.sub {
		if len(m.ctx.apps) == 0 {
			return
		}
		m.ctx.subSel += delta
		if m.ctx.subSel < 0 {
			m.ctx.subSel = 0
		}
		if m.ctx.subSel >= len(m.ctx.apps) {
			m.ctx.subSel = len(m.ctx.apps) - 1
		}
		return
	}
	n := len(m.ctxTopLabels())
	m.ctx.sel += delta
	if m.ctx.sel < 0 {
		m.ctx.sel = 0
	}
	if m.ctx.sel >= n {
		m.ctx.sel = n - 1
	}
}

// ctxCommit is Enter: the submenu choice when it is open, the top-level
// row otherwise — which on "Open With…" descends rather than acts.
func (m *model) ctxCommit() {
	if m.ctx.sub {
		m.ctxChooseSub(m.ctx.subSel)
		return
	}
	m.ctxActivate(m.ctx.sel)
}

// cancelCtx dismisses the menu by name — Esc, a press off the plate, or a
// right-press that hit no row.
func (m *model) cancelCtx() {
	if m.mode != modeContext {
		return
	}
	m.emit(markerMenuClose + m.ctx.name)
	m.clearCtx()
	m.status = "menu closed"
}

func (m *model) clearCtx() {
	m.mode = modeNormal
	m.ctx = ctxMenu{}
}

// --- geometry: 0-based cell rects the hit-test and the overlay share ---

// ctxTopRect is the top-level plate's (x, y, w, h) in cells, clamped
// inside the grid.
func (m *model) ctxTopRect() (x, y, w, h int) {
	w = 0
	for _, l := range m.ctxTopLabels() {
		if n := visLen(l) + 3; n > w {
			w = n
		}
	}
	h = len(m.ctxTopLabels())
	x, y = m.ctx.ax, m.ctx.ay
	if x+w > m.cols {
		x = m.cols - w
	}
	if y+h > m.rows {
		y = m.rows - h
	}
	if x < 0 {
		x = 0
	}
	if y < 0 {
		y = 0
	}
	return x, y, w, h
}

// ctxSubRect is the submenu plate's rect: it hangs off the Open With…
// row's right edge, flipping left when the grid has no room — and is
// meaningless while the submenu is closed.
func (m *model) ctxSubRect() (x, y, w, h int) {
	tx, ty, tw, _ := m.ctxTopRect()
	w = 0
	for _, l := range m.ctxSubLabels() {
		if n := visLen(l) + 2; n > w {
			w = n
		}
	}
	h = len(m.ctxSubLabels())
	y = ty + m.ctxOpenWithRow()
	x = tx + tw
	if x+w > m.cols && tx-w >= 0 {
		x = tx - w
	}
	if x+w > m.cols {
		x = m.cols - w
	}
	if y+h > m.rows {
		y = m.rows - h
	}
	if y < 0 {
		y = 0
	}
	return x, y, w, h
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
