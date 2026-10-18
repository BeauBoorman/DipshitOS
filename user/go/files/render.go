// The M74a frame: a two-pane layout (files | preview) drawn as truecolour
// ANSI for the kernel's window VT (M73h #1634: `38;2;r;g;b` paints at exact
// RGB — the go-fileman gate counts the preview accent in the real scanout).
// Pure strings, no Bubble Tea import, so the host tests can pin the frame.
package main

import (
	"strings"

	"virelai/vi"
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
	lines := m.renderLines()
	return framePrologue + strings.Join(lines, "\n")
}

func (m model) renderLines() []string {
	lw := listWidth(m.cols)
	pw := m.cols - lw - 1
	if pw < 8 {
		pw = 8
	}
	body := m.bodyRows()

	lines := make([]string, 0, m.rows)

	// Row 0: the path bar.
	lines = append(lines, colPath+"  "+clipVis(m.path, m.cols-2)+colReset)

	// Row 1: pane headers, aligned over their panes.
	lhead := clipVis(" files ", lw)
	rhead := clipVis(" preview: "+m.previewOf, pw)
	lines = append(lines,
		colHead+lhead+strings.Repeat(" ", lw-visLen(lhead))+colReset+
			colSep+"│"+colReset+
			colHead+rhead+strings.Repeat(" ", pw-visLen(rhead))+colReset)

	// Body: list rows | separator | preview rows.
	plines := strings.Split(m.preview, "\n")
	for i := 0; i < body; i++ {
		lines = append(lines, m.listRow(i, lw)+colSep+"│"+colReset+m.previewRow(i, plines, pw))
	}

	// Status (modal prompts take it over) and the key hints.
	lines = append(lines, m.statusLine())
	lines = append(lines, colDim+" "+
		clipVis("j/k move · enter open · o open with · e export · v volumes · backspace up · r rename · d trash · u restore · c/x clip · p paste · q quit",
			m.cols-2)+colReset)
	return lines
}

// listRow is one list line padded to w inside its style, so the selection
// background spans the full pane.
func (m model) listRow(i, w int) string {
	if i >= m.n {
		return strings.Repeat(" ", w)
	}
	e := m.entries[i]
	if i == m.sel {
		label := clipVis(entryLabel(e), w-2)
		return colSel + "> " + label +
			strings.Repeat(" ", w-2-visLen(label)) + colReset
	}
	vis := clipVis("  "+entryLabel(e), w)
	style := colFile
	if e.Dir() {
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
	switch m.mode {
	case modeRename:
		return colWarn + " rename to: " + m.input + "_" + colReset
	case modeConfirmDelete:
		return colWarn + " " + m.status + colReset
	case modeOpenWith:
		return colWarn + " " + m.openWithLine() + colReset
	}
	line := " " + m.status
	if m.clip != "" {
		verb := "copy"
		if m.clipCut {
			verb = "cut"
		}
		line += colDim + "  [" + verb + ": " + baseName(m.clip) + "]" + colReset
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
