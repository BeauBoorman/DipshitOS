// The M74a frame: a two-pane layout (files | preview) drawn as truecolour
// ANSI for the kernel's window VT (M73h #1634: `38;2;r;g;b` paints at exact
// RGB — the go-fileman gate counts the preview accent in the real scanout).
// Pure strings, no Bubble Tea import, so the host tests can pin the frame.
package main

import (
	"strings"

	"virelai/vi"
	"virelai/widgets"
)

// Colours are truecolour on purpose: the class-B snapshot asserts the
// EXACT preview accent below, and no palette indirection may move it.
const (
	colReset = "\x1b[0m"

	colPath = "\x1b[38;2;90;205;230m"                // path bar
	colHead = "\x1b[38;2;160;176;192m"               // pane headers
	colDir  = "\x1b[38;2;90;205;230m"                // directory rows
	colFile = "\x1b[38;2;216;224;232m"               // file rows
	colSel  = "\x1b[48;2;44;58;76;38;2;255;255;255m" // selected row
	colPrev = "\x1b[38;2;122;162;255m"               // PREVIEW PANE TEXT — gate accent
	colStat = "\x1b[38;2;255;200;80m"                // status line
	colWarn = "\x1b[38;2;255;96;96m"                 // modal prompt
	colDim  = "\x1b[38;2;120;130;144m"               // hints, padding notes
	colSep  = "\x1b[38;2;60;72;88m"                  // pane separator

	// The context menu's plate: a raised dark band a step off the list's
	// ink. Selected rows reuse colSel; the "(no handlers)" empty row dims.
	colMenu    = "\x1b[48;2;34;42;56;38;2;216;224;232m"
	colMenuDim = "\x1b[48;2;34;42;56;38;2;120;130;144m"

	// The alt-screen prologue every frame starts with (M72b: the window VT
	// has ?1049/?25l/ED/CUP — each paint is a full, self-contained frame).
	framePrologue = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H"
)

// listWidth is the left pane's width in cells: 45% of the grid, clamped so
// both panes stay usable on a narrow frame.
func listWidth(cols int) int {
	w := cols * 45 / 100
	if w < 12 {
		w = 12
	}
	if w > cols-8 {
		w = cols - 8
	}
	if w < 4 {
		w = cols / 2
	}
	return w
}

// render is the whole frame for the bound tty: prologue + exactly rows
// lines, newline-joined with NO trailing newline on the last (a trailing
// newline on the final row would scroll the path bar out of the visible
// grid).
func (m model) render() string {
	if m.mode == modeHints {
		return m.renderHints()
	}
	if m.mode == modeQuickLook {
		return m.renderQuickLook()
	}
	if m.mode == modeProps {
		return m.renderProps()
	}
	if m.mode == modeSearchHits {
		return m.renderSearch()
	}
	lines := m.renderLines()
	frame := framePrologue + strings.Join(lines, "\n")
	if m.mode == modeContext {
		frame += m.renderCtxMenu()
	}
	// M190d: the open menubar plates over the body like the context menu —
	// row 0 keeps its own cells, so the resting frame's geometry is fixed.
	if m.bar.Open {
		frame += m.renderMenuDrop()
	}
	// M167a: the focused tile's sixel rides after the frame behind a CUP
	// into the preview pane — the kernel's image cells replace the blank
	// rows the frame just painted, and every repaint re-places it (the
	// same append rule the QuickLook image arm uses).
	if m.view == viewGrid && len(m.gridFSixel) > 0 {
		var b strings.Builder
		r, c, _, _ := m.gridSixelSpan()
		cup(&b, r, c)
		frame += b.String() + string(m.gridFSixel)
	}
	return frame
}

// renderHints is the M121c (#2566) '?' overlay's ANSI face — the same
// registry rows ChordHints.Draw paints on a canvas, laid over the whole
// grid in this app's own palette. The window fits m.bodyRows() list rows
// between the title band and the footer; Scroll windows a longer table.
func (m model) renderHints() string {
	src := m.hints.Lines(m.cols - 2)
	// src is title, blank, the row lines (aligned with h.Rows), blank,
	// footer — Scroll windows the row lines.
	head, rest, foot := src[0], src[2:len(src)-2], src[len(src)-1]
	body := m.rows - 2 // title row + footer row; the rest is list window
	if body < 1 {
		body = 1
	}
	lines := make([]string, 0, m.rows)
	lines = append(lines, colPath+"  "+head+strings.Repeat(" ", max(0, m.cols-2-visLen(head)))+colReset)
	for i := 0; i < body; i++ {
		idx := m.hints.Scroll + i
		if idx >= len(rest) {
			lines = append(lines, strings.Repeat(" ", m.cols))
			continue
		}
		row := rest[idx]
		style := colFile
		switch {
		case idx > 0 && !strings.HasPrefix(row, " "):
			style = colHead // a section header
		case strings.HasPrefix(row, "    ("):
			style = colDim // the "(none registered)" note
		}
		lines = append(lines, style+" "+clipVis(row, m.cols-1)+strings.Repeat(" ", max(0, m.cols-1-visLen(row)))+colReset)
	}
	lines = append(lines, colDim+" "+foot+colReset)
	return framePrologue + strings.Join(lines, "\n")
}

// renderQuickLook is the M149a (#2806) pane's frame: a title row, a facts
// row, then the arm's body — blank rows under an image arm (the kernel's
// image cells replace them), the first qlTextLines under a text arm, the
// type/size/mtime rows under the card. The sixel itself is appended AFTER
// the grid text behind a CUP to the pane's origin cell: the image's tiles
// land on the blank band the frame just painted, so every repaint
// re-places the thumbnail the ED prologue erased.
func (m model) renderQuickLook() string {
	lines := make([]string, 0, m.rows)
	lines = append(lines,
		colPath+"  quicklook: "+clipVis(m.ql.name, m.cols-14)+colReset)
	lines = append(lines,
		colHead+"  "+clipVis(m.qlSubtitle(), m.cols-4)+colReset)
	body := m.bodyRows()
	switch m.ql.kind {
	case qlText:
		for i := 0; i < body; i++ {
			idx := m.ql.scroll + i
			if idx >= len(m.ql.lines) {
				lines = append(lines, strings.Repeat(" ", m.cols))
				continue
			}
			row := clipVis(m.ql.lines[idx], m.cols-1)
			lines = append(lines, colPrev+" "+row+colReset+
				strings.Repeat(" ", m.cols-1-visLen(row)))
		}
	case qlCard:
		rows := m.qlCardRows()
		for i := 0; i < body; i++ {
			if i >= len(rows) {
				lines = append(lines, strings.Repeat(" ", m.cols))
				continue
			}
			row := clipVis(rows[i], m.cols-1)
			lines = append(lines, colPrev+" "+row+colReset+
				strings.Repeat(" ", m.cols-1-visLen(row)))
		}
	default:
		// qlImage: the body is a blank band — the sixel's tiles cover it.
		for i := 0; i < body; i++ {
			lines = append(lines, strings.Repeat(" ", m.cols))
		}
	}
	lines = append(lines, m.statusLine())
	lines = append(lines, colDim+" "+
		clipVis("space/esc close · j/k scroll", m.cols-2)+colReset)
	frame := framePrologue + strings.Join(lines, "\n")
	if m.ql.kind == qlImage && len(m.ql.sixel) > 0 {
		var b strings.Builder
		row, col := m.qlOrigin()
		cup(&b, row, col)
		frame += b.String() + string(m.ql.sixel)
	}
	return frame
}

// renderProps is the M155a (#2929) card's frame — the QuickLook frame's
// shape: a title row, a kind subtitle, then the fact rows in the preview
// accent, status and hints. The card is read-only, so the whole body is
// propsRows's ten rows (seven facts, three named not-availables).
func (m model) renderProps() string {
	lines := make([]string, 0, m.rows)
	lines = append(lines,
		colPath+"  props: "+clipVis(m.props.name, m.cols-10)+colReset)
	lines = append(lines,
		colHead+"  "+clipVis(m.props.kind+" properties", m.cols-4)+colReset)
	rows := m.propsRows()
	for i := 0; i < m.bodyRows(); i++ {
		if i >= len(rows) {
			lines = append(lines, strings.Repeat(" ", m.cols))
			continue
		}
		row := clipVis(rows[i], m.cols-1)
		lines = append(lines, colPrev+" "+row+colReset+
			strings.Repeat(" ", m.cols-1-visLen(row)))
	}
	lines = append(lines, m.statusLine())
	lines = append(lines, colDim+" "+
		clipVis("esc close", m.cols-2)+colReset)
	return framePrologue + strings.Join(lines, "\n")
}

// renderSearch is the M155c (#2931) results frame — the props card's
// shape: a title row naming the needle, an accounting subtitle (the
// counts the marker carries, plus the bound that stopped the walk),
// then one `rel:line: snippet` row per hit with the cursor's selection,
// and a `truncated at <bound>` row when the walk stopped early — the
// partial set's honest label. Zero hits on a completed walk gets the
// named empty row, never a bare frame.
func (m model) renderSearch() string {
	s := m.search
	lines := make([]string, 0, m.rows)
	lines = append(lines,
		colPath+"  search: "+clipVis(s.pat, m.cols-12)+colReset)
	sub := vi.Itoa64(int64(len(s.hits))) + " hits · " +
		vi.Itoa64(int64(s.scanned)) + " scanned · " +
		vi.Itoa64(int64(s.skipped)) + " skipped"
	if s.trunc != "" {
		sub += " · truncated at " + s.trunc
	}
	lines = append(lines, colHead+"  "+clipVis(sub, m.cols-4)+colReset)
	// tail is the grid slot the truncation row lands on: right after the
	// last hit, or under the "(no hits)" line on an empty set.
	tail := len(s.hits)
	if tail == 0 {
		tail = 1
	}
	for i := 0; i < m.bodyRows(); i++ {
		idx := s.top + i
		if idx >= len(s.hits) {
			if len(s.hits) == 0 && i == 0 {
				lines = append(lines, colDim+"  (no hits)"+colReset)
				continue
			}
			if idx == tail && s.trunc != "" {
				row := "truncated at " + s.trunc
				lines = append(lines, colWarn+"  "+row+
					strings.Repeat(" ", max(0, m.cols-2-visLen(row)))+colReset)
				continue
			}
			lines = append(lines, strings.Repeat(" ", m.cols))
			continue
		}
		h := s.hits[idx]
		row := h.rel + ":" + vi.Itoa64(int64(h.line)) + ": " + h.snippet
		if idx == s.sel {
			label := clipVis(row, m.cols-2)
			lines = append(lines, colSel+"> "+label+
				strings.Repeat(" ", max(0, m.cols-2-visLen(label)))+colReset)
			continue
		}
		label := clipVis("  "+row, m.cols)
		lines = append(lines, colPrev+label+colReset+
			strings.Repeat(" ", max(0, m.cols-visLen(label))))
	}
	lines = append(lines, m.statusLine())
	lines = append(lines, colDim+" "+
		clipVis("enter open · n/N hit · esc close", m.cols-2)+colReset)
	return framePrologue + strings.Join(lines, "\n")
}

// renderCtxMenu is the M124d (#2583) overlay: after the full grid repaint
// each plate row is painted in place by CUP — the menu floats over the
// frame it was opened on without splicing styled line strings. Rows are
// space-padded to the plate width so the background reads as one plate.
func (m model) renderCtxMenu() string {
	var b strings.Builder
	tx, ty, tw, th := m.ctxTopRect()
	labels := m.ctxTopLabels()
	subRow := m.ctxOpenWithRow()
	for i := 0; i < th; i++ {
		label := ""
		if i < len(labels) {
			label = labels[i]
		}
		// Row text: a leading space, the label padded to the arrow
		// column, then ">" for the submenu parent or a space.
		text := " " + label
		text += strings.Repeat(" ", tw-1-visLen(text))
		if i == subRow {
			text += ">"
		} else {
			text += " "
		}
		style := colMenu
		if i == m.ctx.sel {
			style = colSel
		}
		cup(&b, ty+i, tx)
		b.WriteString(style + text + colReset)
	}
	if m.ctx.sub {
		sx, sy, sw, sh := m.ctxSubRect()
		subs := m.ctxSubLabels()
		for i := 0; i < sh; i++ {
			text := " " + subs[i]
			text += strings.Repeat(" ", sw-visLen(text))
			style := colMenu
			if len(m.ctx.apps) == 0 {
				style = colMenuDim
			} else if i == m.ctx.subSel {
				style = colSel
			}
			cup(&b, sy+i, sx)
			b.WriteString(style + text + colReset)
		}
	}
	return b.String()
}

// cup writes the VT cursor-position escape for a 0-based cell.
func cup(b *strings.Builder, row, col int) {
	b.WriteString("\x1b[")
	b.WriteString(vi.Itoa64(int64(row + 1)))
	b.WriteString(";")
	b.WriteString(vi.Itoa64(int64(col + 1)))
	b.WriteString("H")
}

// menuRow is row 0 — the M190d menubar sharing the path bar's line: menu
// titles at the left (the engaged or open title in the selection style),
// the path behind them. Always painted, so the menus are discoverable at
// rest; nothing about the row's geometry changes when the bar is active.
func (m model) menuRow() string {
	var b strings.Builder
	pos := 0
	for i, t := range m.bar.CellTitles() {
		for pos < t.X {
			b.WriteString(" ")
			pos++
		}
		style := colMenu
		if m.bar.Active && i == m.bar.Bar {
			style = colSel
		}
		b.WriteString(style + " " + t.Text + " ")
		pos = t.X + t.W
	}
	b.WriteString(colReset)
	head := b.String()
	if avail := m.cols - pos - 1; avail > 0 {
		return head + " " + colPath + clipVis(m.path, avail) + colReset
	}
	return head
}

// renderMenuDrop is the open menu's plate, painted in place by CUP after
// the grid — the context menu's overlay idiom: rows pad to the plate
// width so the plate reads as one band, the hover row takes the selection
// style, disabled rows dim.
func (m model) renderMenuDrop() string {
	x, w, rows, ok := m.bar.CellMenu(m.cols)
	if !ok {
		return ""
	}
	var b strings.Builder
	for i, r := range rows {
		text := r.Text + strings.Repeat(" ", max(0, w-visLen(r.Text)))
		style := colMenu
		if r.Disabled {
			style = colMenuDim
		} else if r.Hover {
			style = colSel
		}
		cup(&b, 1+i, x)
		b.WriteString(style + text + colReset)
	}
	return b.String()
}

func (m model) renderLines() []string {
	lw := m.listCols()
	body := m.bodyRows()

	lines := make([]string, 0, m.rows)

	// Row 0: the menubar + path line (M190d).
	lines = append(lines, m.menuRow())

	// Row 1: pane headers, aligned over their panes.
	lhead := clipVis(" files ", lw)
	if m.view == viewList {
		// viewList (M125c #2588): no preview pane, no separator — the
		// list spans the grid.
		lines = append(lines,
			colHead+lhead+strings.Repeat(" ", lw-visLen(lhead))+colReset)
		for i := 0; i < body; i++ {
			lines = append(lines, m.listRow(i, lw))
		}
	} else {
		pw := m.cols - lw - 1
		if pw < 8 {
			pw = 8
		}
		rhead := clipVis(" preview: "+m.previewOf, pw)
		lines = append(lines,
			colHead+lhead+strings.Repeat(" ", lw-visLen(lhead))+colReset+
				colSep+"│"+colReset+
				colHead+rhead+strings.Repeat(" ", pw-visLen(rhead))+colReset)

		// Body: list rows | separator | preview rows. M167a: the grid
		// fills the list pane with its tile field and blanks the preview
		// rows the focus sixel covers.
		plines := strings.Split(m.preview, "\n")
		for i := 0; i < body; i++ {
			left := m.listRow(i, lw)
			right := m.previewRow(i, plines, pw)
			if m.view == viewGrid {
				left = m.gridPaneRow(i, lw)
				right = m.gridPreviewRow(i, plines, pw)
			}
			lines = append(lines, left+colSep+"│"+colReset+right)
		}
	}

	// Status (modal prompts take it over) and the key hints.
	lines = append(lines, m.statusLine())
	lines = append(lines, colDim+" "+
		clipVis("f10 menu · j/k move · enter open · / search · space look · i props · o open with · e export · t grid · v volumes · f pins · b pin · tab view · s sort · backspace up · r rename · m mark · M unmark · d trash · u restore · c/x clip · p paste · q quit",
			m.cols-2)+colReset)
	return lines
}

// emptyListRows is the M123b (#2576) blank-surface presenter on the VT
// grid: the shared widgets.EmptyState's Lines form — icon, headline and
// the chords that still answer on a zero-entry listing, centred in the
// pane's body where the frame used to paint bare spaces.
func (m model) emptyListRows(w, body int) []string {
	return widgets.EmptyState{
		Icon:     "Ø",
		Headline: "This folder is empty",
		Hints:    []string{"p paste · backspace up", "v volumes · q quit"},
	}.Lines(w, body)
}

// listRow is one list line padded to w inside its style, so the selection
// background spans the full pane. i is a SCREEN row: the scroll offset
// m.top maps it onto the listing (the cursor is always inside the window —
// ensureSelVisible owns that invariant).
func (m model) listRow(i, w int) string {
	if m.n == 0 && m.path != volsPath && m.path != favsView {
		rows := m.emptyListRows(w, m.bodyRows())
		if i >= len(rows) {
			return strings.Repeat(" ", w)
		}
		if strings.TrimSpace(rows[i]) == "" {
			return rows[i]
		}
		return colDim + rows[i] + colReset
	}
	idx := m.top + i
	if idx >= m.n {
		if i == 0 && m.path == favsView {
			// M167b: an empty pin list is not an empty folder — the note
			// names the chord that fills it.
			note := clipVis("  (no favorites — b pins the cursor's folder)", w)
			return colDim + note + colReset +
				strings.Repeat(" ", w-visLen(note))
		}
		return strings.Repeat(" ", w)
	}
	e := m.entries[idx]
	// M167b: a pin whose directory is gone keeps its row but wears the
	// missing word — dim ink, no dir slash, and Enter refuses it.
	label := entryLabel(e)
	missing := m.path == favsView && m.favMissing(e)
	if missing {
		label = e.NameString() + " (missing)"
	}
	// M167c: archive rows name their class — a symlink spells its
	// (unfollowed) target, refused and unsupported rows say so.
	tarDim := false
	if m.tar != nil && idx < len(m.tarRows) {
		if ent, ok := m.tarEntAt(idx); ok {
			switch e.Reserved[0] {
			case tarClsLink:
				label = e.NameString() + " -> " + ent.link
			case tarClsRefused:
				label = e.NameString() + " (refused)"
				tarDim = true
			case tarClsOther:
				label = e.NameString() + " (unsupported)"
				tarDim = true
			}
		}
	}
	// M155b (#2930): the two-cell gutter carries the cursor ('>') and the
	// mark ('*') — ">*" is a marked selected row, " *" a marked row.
	pre := "  "
	if m.isMarked(e.NameString()) {
		pre = " *"
	}
	if idx == m.sel {
		if pre == " *" {
			pre = ">*"
		} else {
			pre = "> "
		}
		label := clipVis(label, w-2)
		return colSel + pre + label +
			strings.Repeat(" ", w-2-visLen(label)) + colReset
	}
	vis := clipVis(pre+label, w)
	style := colFile
	switch {
	case missing, tarDim:
		style = colDim
	case e.Dir():
		style = colDir
	}
	return style + vis + strings.Repeat(" ", w-visLen(vis)) + colReset
}

// previewRow is one preview line in the gate's accent colour, padded to w.
func (m model) previewRow(i int, plines []string, w int) string {
	if i >= len(plines) {
		return strings.Repeat(" ", w)
	}
	vis := clipVis(plines[i], w)
	return colPrev + vis + colReset + strings.Repeat(" ", w-visLen(vis))
}

func (m model) statusLine() string {
	// M123d (#2578): an open error banner takes the row — the same
	// takeover the modal prompts hold, in the same warn ink.
	if m.banner.Open {
		return colWarn + " " + clipVis(m.banner.Line(0), m.cols-4) + colReset
	}
	switch m.mode {
	case modeRename:
		return colWarn + " rename to: " + m.input + "_" + colReset
	case modeConfirmDelete:
		return colWarn + " " + m.status + colReset
	case modeOpenWith:
		return colWarn + " " + m.openWithLine() + colReset
	case modeSearchInput:
		return colWarn + " search for: " + m.input + "_" + colReset
	}
	line := " " + m.status
	// M155b (#2930): the status line counts the marked set while it is
	// bound to the directory on screen.
	if k := m.markCount(); k > 0 {
		line += colDim + "  [" + vi.Itoa64(int64(k)) + " marked]" + colReset
	}
	if len(m.clipSet) > 0 {
		verb := "copy"
		if m.clipCut {
			verb = "cut"
		}
		line += colDim + "  [" + verb + ": "
		if len(m.clipSet) == 1 {
			line += baseName(m.clipSet[0])
		} else {
			line += "n=" + vi.Itoa64(int64(len(m.clipSet)))
		}
		line += "]" + colReset
	}
	return colStat + clipVis(line, m.cols-2) + colReset
}

// openWithLine is the M81b (#1762) candidate list: the file, the type the
// sniff gave it, and one numbered entry per registered handler. The digits
// are what the user presses, so the list IS the menu.
func (m model) openWithLine() string {
	var b strings.Builder
	b.WriteString("open with ")
	b.WriteString(m.openName)
	b.WriteString(" (")
	b.WriteString(m.openID.String())
	b.WriteString("):")
	for i, h := range m.openCands {
		b.WriteString(" ")
		b.WriteString(vi.Itoa64(int64(i + 1)))
		b.WriteString(" ")
		b.WriteString(h.Label)
	}
	return b.String()
}

// visLen is the printable width of s, skipping CSI escape sequences.
func visLen(s string) int {
	n := 0
	inEsc := false
	for _, r := range s {
		if inEsc {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				inEsc = false
			}
			continue
		}
		if r == 0x1b {
			inEsc = true
			continue
		}
		n++
	}
	return n
}

// clipVis truncates s to w printable cells (keeping any open ANSI prefix)
// and appends a reset when anything was cut or a style may still be open.
func clipVis(s string, w int) string {
	if w <= 0 {
		return ""
	}
	var out strings.Builder
	vis := 0
	inEsc := false
	cut := false
	for _, r := range s {
		if inEsc {
			out.WriteRune(r)
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
				inEsc = false
			}
			continue
		}
		if r == 0x1b {
			inEsc = true
			out.WriteRune(r)
			continue
		}
		if vis >= w {
			cut = true
			break
		}
		out.WriteRune(r)
		vis++
	}
	if cut {
		out.WriteString(colReset)
	}
	return out.String()
}
