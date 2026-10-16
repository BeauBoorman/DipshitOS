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
