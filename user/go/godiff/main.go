// GODIFF.ELF -- unified context diff CLI (M107e #2322 capstone).
// Usage: GODIFF.ELF [-u<n>] <a> <b>. Exits 0 same / 1 differ / 2 usage /
// 3 io / 4 too_large. Prints ---/+++ headers then each @@ hunk, then a
// summary line so a gate can assert the outcome without parsing output.
//
// M138c (#2777): `-i` opens the interactive viewer — a window on the seat
// with a bound /dev/tty rendering the diff with the gitui palette. `s`
// toggles the side-by-side mode (aligned hunks), j/k scroll, q quits.
package main

import (
	"strconv"
	"strings"

	"virelai/vi"
)

const defCtx = 3

// cliArgs drops argv[0] when the loader passes the program name.
func cliArgs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	first := strings.ToUpper(raw[0])
	if strings.HasSuffix(first, ".ELF") || first == "GODIFF" {
		return raw[1:]
	}
	return raw
}

// readPair loads both diff inputs; the shared path keeps the batch and
// interactive legs' refusals identical.
func readPair(paths []string) (a, b []byte, rc int) {
	a, ra := vi.ReadFileAll(paths[0], vi.MaxFileBytes)
	if ra < 0 {
		vi.ConsoleLine("godiff: read " + paths[0] + " refused rc=" + strconv.Itoa(int(ra)))
		return nil, nil, 3
	}
	b, rb := vi.ReadFileAll(paths[1], vi.MaxFileBytes)
	if rb < 0 {
		vi.ConsoleLine("godiff: read " + paths[1] + " refused rc=" + strconv.Itoa(int(rb)))
		return nil, nil, 3
	}
	return a, b, 0
}

func run(args []string) int {
	ctx := defCtx
	interactive := false
	var paths []string
	for _, a := range args {
		if a == "-i" {
			interactive = true
			continue
		}
		if strings.HasPrefix(a, "-u") {
			n, err := strconv.Atoi(a[2:])
			if err != nil || n < 0 || n > 99 {
				vi.ConsoleLine("godiff: usage: GODIFF.ELF [-u<n>] <a> <b>")
				return 2
			}
			ctx = n
			continue
		}
		paths = append(paths, a)
	}
	if len(paths) != 2 {
		vi.ConsoleLine("godiff: usage: GODIFF.ELF [-u<n>] <a> <b>")
		return 2
	}
	if interactive {
		return runInteractive(paths[0], paths[1], ctx)
	}
	a, b, rc := readPair(paths)
	if rc != 0 {
		return rc
	}
	text, differ, tooBig := Diff(string(a), string(b), ctx)
	if tooBig {
		vi.ConsoleLine("godiff: too large")
		return 4
	}
	if !differ {
		vi.ConsoleLine("godiff: " + paths[0] + " and " + paths[1] + " are identical")
		return 0
	}
	vi.ConsoleLine("--- " + paths[0])
	vi.ConsoleLine("+++ " + paths[1])
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	for _, ln := range lines {
		vi.ConsoleLine(ln)
	}
	vi.ConsoleLine("godiff: files differ hunks=" + strconv.Itoa(strings.Count(text, "@@ -")))
	return 1
}

// ---- interactive viewer (M138c #2777) ---------------------------------------
//
// Only virelai/vi is importable here (the in-guest package surface, ADR
// 0035): the window is a raw win_open + TtyAttachWindow pair — the same
// seam tabapp packages for the fleet apps, inlined because the guest build
// links no tabapp archive.

const (
	viewAppName  = "GODIFF.ELF"
	viewAppTitle = "Diff"
	viewNatW     = 640
	viewNatH     = 400
	viewTTY      = "/dev/tty"
)

func viewShutdown(win int, fd uint32, status int) {
	_, _ = vi.FileWrite(fd, []byte("\x1b[?1049l\x1b[?25h"))
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine("godiff: close")
	vi.ConsoleLine("godiff OK")
	vi.WinClose(win)
	vi.Exit(status)
}

func runInteractive(pathA, pathB string, ctx int) int {
	a, b, rc := readPair([]string{pathA, pathB})
	if rc != 0 {
		return rc
	}
	as, bs := splitLines(string(a)), splitLines(string(b))
	big := len(as)
	if len(bs) > big {
		big = len(bs)
	}
	if big > maxLines {
		vi.ConsoleLine("godiff: too large")
		return 4
	}
	hs := hunks(lcsOps(as, bs), ctx)
	if len(hs) == 0 {
		vi.ConsoleLine("godiff: " + pathA + " and " + pathB + " are identical")
		return 0
	}

	win, res := vi.WinOpen(32, 32, viewNatW, viewNatH)
	if res < 0 {
		vi.ConsoleLine("godiff: open failed")
		return 1
	}
	vi.DeclareFullscreen(uint32(win), viewAppTitle, viewAppName)
	vi.ConsoleLine("godiff: open id=" + vi.Itoa64(int64(win)))

	h, orc := vi.FileOpen(viewTTY, vi.ModeRead|vi.ModeWrite)
	if orc < 0 {
		vi.ConsoleLine("godiff: no /dev/tty")
		vi.WinClose(win)
		return 2
	}
	fd := uint32(h)
	if vi.TtyAttachWindow(win) != 0 {
		vi.FileClose(fd)
		vi.WinClose(win)
		vi.ConsoleLine("godiff: attach failed")
		return 3
	}
	vi.ConsoleLine("godiff: attached")

	// Terminal grid: (640-0)/cw cols x (400-16)/ch rows under the seat's
	// title band; fall back to the classic 80x24 when the cell query is
	// unavailable.
	cw, ch := vi.TerminalCell()
	cols, rows := 80, 24
	if cw > 0 && ch > 0 {
		cols = int(viewNatW) / int(cw)
		rows = (int(viewNatH) - 16) / int(ch)
	}

	sideBySide := false
	scroll := 0
	paint := func() bool {
		var f string
		if sideBySide {
			f = renderSideBySide(pathA, pathB, as, bs, hs, scroll, rows-1, cols)
		} else {
			f = renderUnified(pathA, pathB, as, bs, hs, scroll, rows-1)
		}
		n, wrc := vi.FileWrite(fd, []byte(f))
		return wrc >= 0 && n == len(f)
	}
	if !paint() {
		viewShutdown(win, fd, 4)
	}
	// A tty write marks the window dirty; yield so the markers below only
	// ever describe an already-presented frame (the gate's barrier rule).
	vi.Sleep(2)
	vi.ConsoleLine("godiff: painted")
	vi.ConsoleLine("godiff: ready")

	emitKey := func(kb byte) {
		switch kb {
		case 'q':
			viewShutdown(win, fd, 0)
		case 's':
			sideBySide = !sideBySide
		case 'j':
			scroll++
		case 'k':
			if scroll > 0 {
				scroll--
			}
		}
		if !paint() {
			viewShutdown(win, fd, 4)
		}
		vi.Sleep(1)
		vi.ConsoleLine("godiff: key " + string(kb))
		if kb == 's' {
			v := "unified"
			if sideBySide {
				v = "side-by-side"
			}
			vi.ConsoleLine("godiff: view " + v)
		}
		vi.ConsoleLine("godiff: repainted")
	}

	var in [64]byte
	for {
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			for _, kb := range in[:n] {
				if kb != 0x1b {
					emitKey(kb)
				}
			}
		}
		ev, result, ok := vi.PollEventRaw()
		if !ok {
			if result < 0 {
				viewShutdown(win, fd, 5)
			}
			if n <= 0 {
				vi.Sleep(1)
			}
			continue
		}
		switch ev.Kind {
		case vi.EvWinClose:
			viewShutdown(win, fd, 0)
		case vi.EvWinResize:
			if !paint() {
				viewShutdown(win, fd, 4)
			}
		}
	}
}

func main() {
	vi.Yield()
	vi.Exit(run(cliArgs(vi.Args())))
}
