// GODIFF.ELF -- unified context diff for two share files (M107e #2322,
// the in-guest capstone). `flint diff` is status-depth only, so the loop
// has no content-diff tool; this is it. Exit: 0 same, 1 differ, 2 usage,
// 3 io, 4 too_large. Pure engine; main wires the vi calls.
package main

import (
	"strconv"
	"strings"
)

// maxLines bounds the (n+1)*(m+1) LCS table.
const maxLines = 2048

// srcline keeps endings honest: "x" and "x\n" are different files.
type srcline struct {
	text string
	eol  bool
}

func splitLines(s string) []srcline {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, "\n")
	eol := true
	if parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	} else {
		eol = false
	}
	lines := make([]srcline, len(parts))
	for i, p := range parts {
		lines[i] = srcline{text: p, eol: i < len(parts)-1 || eol}
	}
	return lines
}

type op struct {
	kind byte // ' ', '-', '+'
	a, b int  // -1 on the side the op does not consume
}

// lcsOps emits a deterministic minimal edit script via a suffix-DP LCS
// table; ties delete before they add.
func lcsOps(a, b []srcline) []op {
	n, m := len(a), len(b)
	w := m + 1
	t := make([]int, (n+1)*w)
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			switch {
			case a[i] == b[j]:
				t[i*w+j] = t[(i+1)*w+j+1] + 1
			case t[(i+1)*w+j] >= t[i*w+j+1]:
				t[i*w+j] = t[(i+1)*w+j]
			default:
				t[i*w+j] = t[i*w+j+1]
			}
		}
	}
	var ops []op
	i, j := 0, 0
	for i < n || j < m {
		switch {
		case i < n && j < m && a[i] == b[j]:
			ops = append(ops, op{' ', i, j})
			i++
			j++
		case j >= m || (i < n && t[(i+1)*w+j] >= t[i*w+j+1]):
			ops = append(ops, op{'-', i, -1})
			i++
		default:
			ops = append(ops, op{'+', -1, j})
			j++
		}
	}
	return ops
}

type hunk struct {
	ops        []op
	aPos, bPos int // lines consumed before the hunk
	aCnt, bCnt int
}

// hunks groups the script into @@ blocks with ctx context; change groups
// whose gap fits inside 2*ctx merge into one hunk.
func hunks(ops []op, ctx int) []hunk {
	var idx []int
	for i, o := range ops {
		if o.kind != ' ' {
			idx = append(idx, i)
		}
	}
	if len(idx) == 0 {
		return nil
	}
	groups := [][2]int{{idx[0], idx[0]}}
	for _, k := range idx[1:] {
		if k-groups[len(groups)-1][1] <= 2*ctx {
			groups[len(groups)-1][1] = k
		} else {
			groups = append(groups, [2]int{k, k})
		}
	}
	var out []hunk
	for _, g := range groups {
		from, to := g[0]-ctx, g[1]+1+ctx
		if from < 0 {
			from = 0
		}
		if to > len(ops) {
			to = len(ops)
		}
		var h hunk
		for _, o := range ops[:from] {
			if o.kind != '+' {
				h.aPos++
			}
			if o.kind != '-' {
				h.bPos++
			}
		}
		for _, o := range ops[from:to] {
			h.ops = append(h.ops, o)
			if o.kind != '+' {
				h.aCnt++
			}
			if o.kind != '-' {
				h.bCnt++
			}
		}
		out = append(out, h)
	}
	return out
}

// rng prints a hunk range the GNU way: omit ,1; a count of 0 names the
// position BEFORE the insertion.
func rng(pos, cnt int) string {
	if cnt == 0 {
		return strconv.Itoa(pos) + ",0"
	}
	if cnt == 1 {
		return strconv.Itoa(pos + 1)
	}
	return strconv.Itoa(pos+1) + "," + strconv.Itoa(cnt)
}

func (h hunk) String(a, b []srcline) string {
	var sb strings.Builder
	sb.WriteString("@@ -" + rng(h.aPos, h.aCnt) + " +" + rng(h.bPos, h.bCnt) + " @@\n")
	for _, o := range h.ops {
		var l srcline
		if o.kind == '+' {
			l = b[o.b]
		} else {
			l = a[o.a]
		}
		sb.WriteByte(o.kind)
		sb.WriteString(l.text)
		sb.WriteByte('\n')
		if !l.eol {
			sb.WriteString("\\ No newline at end of file\n")
		}
	}
	return sb.String()
}

// Diff computes the hunk text; main adds the ---/+++ headers and the
// exit-status mapping.
func Diff(srcA, srcB string, ctx int) (text string, differ bool, tooBig bool) {
	a, b := splitLines(srcA), splitLines(srcB)
	big := len(a)
	if len(b) > big {
		big = len(b)
	}
	if big > maxLines {
		return "", false, true
	}
	hs := hunks(lcsOps(a, b), ctx)
	if len(hs) == 0 {
		return "", false, false
	}
	var sb strings.Builder
	for _, h := range hs {
		sb.WriteString(h.String(a, b))
	}
	return sb.String(), true, false
}

// ---- interactive viewer renderers (M138c #2777) ---------------------------
//
// The `-i` mode repaints one full frame per key into a bound /dev/tty, so
// each renderer returns a COMPLETE frame: alt-screen prologue, clear+home,
// the header row, then `rows` content rows starting at `scroll`. The SGR
// set is gitui render.go's hand-rolled palette — the same colors the
// history surface already uses (magenta identity, blue hunk headers, red
// removals, green additions, truecolour ink).

const (
	colReset  = "\x1b[0m"
	colHeader = "\x1b[1;95m"             // bold magenta: app identity
	colInk    = "\x1b[38;2;230;230;230m" // truecolour white: context lines
	colDim    = "\x1b[38;2;130;130;130m" // truecolour gray: separator, help
	colPlus   = "\x1b[92m"               // green: added lines
	colMinus  = "\x1b[1;91m"             // red: removed lines
	colHunk   = "\x1b[94m"               // blue: hunk headers
)

const framePrologue = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H"

// fitCell clips s to w display cells (rune-aware; a clipped cell ends in
// '…') and pads short content with spaces so columns stay aligned.
func fitCell(s string, w int) string {
	if w <= 0 {
		return ""
	}
	runes := 0
	for range s {
		runes++
	}
	var b strings.Builder
	if runes > w {
		n := 0
		for _, r := range s {
			if n == w-1 {
				break
			}
			b.WriteRune(r)
			n++
		}
		b.WriteRune('…')
		n++
		for n < w {
			b.WriteByte(' ')
			n++
		}
		return b.String()
	}
	b.WriteString(s)
	for runes < w {
		b.WriteByte(' ')
		runes++
	}
	return b.String()
}

// viewHeader is the row-0 identity strip, identical across views.
func viewHeader(nameA, nameB string) string {
	return colHeader + " GODIFF " + nameA + " | " + nameB +
		"    s toggle · j/k scroll · q quit" + colReset
}

// renderUnified lays out the classic single-column hunk view with the
// palette colors: ' ' ink, '-' red, '+' green, '@@' blue.
func renderUnified(nameA, nameB string, a, b []srcline, hs []hunk, scroll, rows int) string {
	var lines []string
	for _, h := range hs {
		lines = append(lines, colHunk+"@@ -"+rng(h.aPos, h.aCnt)+" +"+rng(h.bPos, h.bCnt)+" @@"+colReset)
		for _, o := range h.ops {
			var l srcline
			col := colInk
			switch o.kind {
			case '+':
				l = b[o.b]
				col = colPlus
			case '-':
				l = a[o.a]
				col = colMinus
			default:
				l = a[o.a]
			}
			lines = append(lines, col+string(o.kind)+l.text+colReset)
		}
	}
	return frame(nameA, nameB, lines, scroll, rows)
}

// renderSideBySide lays out the aligned two-column view: context rows
// repeat on both sides in ink, a change run pairs '-' rows on the left
// (red) with '+' rows on the right (green), and the shorter side pads
// with blanks so every hunk row stays aligned.
func renderSideBySide(nameA, nameB string, a, b []srcline, hs []hunk, scroll, rows, cols int) string {
	cellW := (cols - 3) / 2
	if cellW < 8 {
		cellW = 8
	}
	sep := colDim + " | " + colReset
	var lines []string
	for _, h := range hs {
		lines = append(lines, colHunk+"@@ -"+rng(h.aPos, h.aCnt)+" +"+rng(h.bPos, h.bCnt)+" @@"+colReset)
		for i := 0; i < len(h.ops); {
			o := h.ops[i]
			if o.kind == ' ' {
				t := fitCell(a[o.a].text, cellW)
				lines = append(lines, colInk+t+sep+t+colReset)
				i++
				continue
			}
			// gather the change run: '-' ops then '+' ops
			var dels, adds []op
			for i < len(h.ops) && h.ops[i].kind == '-' {
				dels = append(dels, h.ops[i])
				i++
			}
			for i < len(h.ops) && h.ops[i].kind == '+' {
				adds = append(adds, h.ops[i])
				i++
			}
			n := len(dels)
			if len(adds) > n {
				n = len(adds)
			}
			for k := 0; k < n; k++ {
				lc, rc := strings.Repeat(" ", cellW), strings.Repeat(" ", cellW)
				lcol, rcol := colReset, colReset
				if k < len(dels) {
					lc = fitCell(a[dels[k].a].text, cellW)
					lcol = colMinus
				}
				if k < len(adds) {
					rc = fitCell(b[adds[k].b].text, cellW)
					rcol = colPlus
				}
				lines = append(lines, lcol+lc+colReset+sep+rcol+rc+colReset)
			}
		}
	}
	return frame(nameA, nameB, lines, scroll, rows)
}

// frame joins the header + the scrolled window of content lines into one
// repaintable screen.
func frame(nameA, nameB string, lines []string, scroll, rows int) string {
	var sb strings.Builder
	sb.WriteString(framePrologue)
	sb.WriteString(viewHeader(nameA, nameB))
	sb.WriteByte('\n')
	if scroll > len(lines) {
		scroll = len(lines)
	}
	end := scroll + rows
	if end > len(lines) {
		end = len(lines)
	}
	for _, l := range lines[scroll:end] {
		sb.WriteString(l)
		sb.WriteByte('\n')
	}
	return sb.String()
}
