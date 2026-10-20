// GOTABWM.ELF — M62f (issue #1404): write /host/SELFTEST/LAYOUT.txt, the
// ADR 0033 D4 structural dump. UTF-8 LF, no timestamps or pointers. One
// line per tab from the applied SET_WINDOW rects (slot 19 WinQuery is
// owner-only, so the seat cannot read a hosted client's rect back). The
// file is closed before the serial line that names it.
package main

import "virelai/vi"

const (
	selftestDir = "/host/SELFTEST"
	layoutPath  = selftestDir + "/LAYOUT.txt"
)

func layoutBin(t Tab) string {
	if t.Bin != "" {
		return t.Bin
	}
	return t.Title
}

// layoutFileBody is the LAYOUT.txt payload for s. Empty strip yields nil
// (do not write an empty file over a good dump). M137a: one rect per
// PANE — a tab with a leaf carries its computed rect and its parent
// split kind; a tab the tree does not hold (opened after the layout, or
// dissolved by an unsplit) reports the headless full-viewport fallback
// with split=none, exactly the shape every pre-tree dump already wrote.
func layoutFileBody(s *TabStrip, scanW, scanH uint32) []byte {
	n := s.Count()
	if n == 0 {
		return nil
	}
	full := FullRect(scanW, scanH)
	fid, has := s.Focused()
	out := make([]byte, 0, n*96)
	for i := 0; i < n; i++ {
		t := s.At(i)
		r, placed := s.rectOf(t.ID, scanW, scanH)
		kind := s.paneParentKind(t.ID)
		if !placed {
			r, kind = full, SplitNone
		}
		line := layoutLine(t.ID, layoutBin(t), r, has && t.ID == fid, kind)
		out = append(out, line...)
		out = append(out, '\n')
	}
	return out
}

func mkdirHost(path string) {
	h, r := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if r >= 0 {
		vi.FileClose(uint32(h))
	}
}

// writeLayoutFile writes LAYOUT.txt then prints the path. Callers must
// not print the path first.
func writeLayoutFile() bool {
	body := layoutFileBody(&tabs, uint32(vi.ScanoutWidth), uint32(vi.ScanoutHeight))
	if len(body) == 0 {
		return false
	}
	mkdirHost(selftestDir)
	if !writeHostFile(layoutPath, body) {
		vi.ConsoleLine("gotabwm: layout write fail")
		return false
	}
	vi.ConsoleLine(MarkerLayoutFile + layoutPath)
	return true
}
