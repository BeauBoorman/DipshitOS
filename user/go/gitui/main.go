//go:build virelai || gitui

// Command gitui is GOGITUI.ELF — the M74b Git TUI (#1645). It reads a
// repository (default /host/R, argv[1] to override) through
// virelai/git/gitread BEFORE opening its window, then runs charmhello's
// loop shape: keys from the bound /dev/tty through the M73i SGR mouse FSM
// into the tea.Model, frames back into that tty.
package main

import (
	"virelai/git/gitread"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOGITUI.ELF"
	appTitle = "Git TUI"
	natW     = 640
	natH     = 400

	ttyPath = "/dev/tty"
)

// Wait durations in nanoseconds (ADR 0060 audit): settles use the deadline
// overlay (vi.SleepNs, slot 94) instead of guessed scheduler ticks.
const (
	ms = 1_000_000

	// presentSettleNs yields after a tty write so the barrier markers only
	// describe an already-presented frame (the M72c gate contract).
	presentSettleNs = 200 * ms
	// keyRepaintSettleNs is the settle between a key-driven repaint and the
	// `gitui: key`/`view`/`repainted` markers.
	keyRepaintSettleNs = 100 * ms
)

// argvPad keeps the Go sbrk heap from overlapping the kernel's argv+envp
// block (same GOFETCH/GOTGIT fix): this app reads vi.Args().
var argvPad [4096]byte

func paint(fd uint32, m model) bool {
	v := m.View()
	n, rc := vi.FileWrite(fd, []byte(v.Content))
	return rc >= 0 && n == len(v.Content)
}

// loadData opens the repository and emits the data markers the gate
// asserts (status counts, per-file entries, log subjects, diff paths).
// Returns "" as the error detail on success.
func loadData(root string) (*Data, string) {
	r, err := gitread.Open(gitread.VirelaiFS{}, root)
	if err != nil {
		return nil, "open " + err.Error()
	}
	d := &Data{Root: root}
	d.Status, err = r.Status()
	if err != nil {
		return nil, "status " + err.Error()
	}
	vi.ConsoleLine(markerStatus +
		"staged=" + vi.Itoa64(int64(len(d.Status.Staged))) +
		" modified=" + vi.Itoa64(int64(len(d.Status.Modified))) +
		" untracked=" + vi.Itoa64(int64(len(d.Status.Untracked))))
	for _, e := range d.Status.Staged {
		vi.ConsoleLine(markerEntry + string([]byte{e.Code}) + " " + e.Path)
	}
	for _, e := range d.Status.Modified {
		vi.ConsoleLine(markerEntry + string([]byte{e.Code}) + " " + e.Path)
	}
	for _, e := range d.Status.Untracked {
		vi.ConsoleLine(markerEntry + string([]byte{e.Code}) + " " + e.Path)
	}
	d.Log, err = r.Log(50)
	if err != nil {
		return nil, "log " + err.Error()
	}
	vi.ConsoleLine(markerLog + vi.Itoa64(int64(len(d.Log))))
	for _, rev := range d.Log {
		vi.ConsoleLine(markerSubject + rev.Subject)
	}
	d.Diffs, err = r.Diff()
	if err != nil {
		return nil, "diff " + err.Error()
	}
	for _, f := range d.Diffs {
		vi.ConsoleLine(markerDiff + f.Path)
	}
	return d, ""
}

func main() {
	argvPad[0] = 1

	root := "/host/R"
	if args := vi.Args(); len(args) > 1 && args[1] != "" {
		root = args[1]
	}
	vi.ConsoleLine(markerRepo + root)

	// Load before opening a window: a broken repo exits without a window.
	d, errMsg := loadData(root)
	if errMsg != "" {
		vi.ConsoleLine(markerErr + errMsg)
		vi.Exit(1)
	}

	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,
	})
	if ta == nil {
		vi.ConsoleLine("gitui: open failed")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine("gitui: no /dev/tty")
		ta.CloseAndExit(2)
	}
	fd := uint32(h)
	if vi.TtyAttachWindow(ta.Win) != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine("gitui: attach failed")
		ta.CloseAndExit(3)
	}
	vi.ConsoleLine(markerAttach)
	// M73i (#1635): ?1000 press/release edges + ?1006 SGR — clicks over the
	// tab strip switch views; the kernel reports pointer events only while
	// these modes are on for this screen.
	if _, rcw := vi.FileWrite(fd, []byte("\x1b[?1000h\x1b[?1006h")); rcw < 0 {
		vi.ConsoleLine("gitui: mouse enable failed")
	}

	m := model{data: d, view: viewStatus}
	if !paint(fd, m) {
		shutdown(ta, fd, 4)
	}
	// Yield once before the barrier markers so they describe a painted
	// frame (M72c gate contract).
	vi.SleepNs(presentSettleNs)
	vi.ConsoleLine(markerPainted)
	vi.ConsoleLine(markerReady)

	// emitKey: process, repaint, then markers — key, view (on a view key),
	// repainted. Screenshots wait on the view marker: the frame is already
	// written when the gate reads it.
	emitKey := func(b byte) {
		next, _ := m.Update(keyPress(b))
		m = next.(model)
		if m.quit {
			shutdown(ta, fd, 0)
		}
		if !paint(fd, m) {
			shutdown(ta, fd, 4)
		}
		vi.SleepNs(keyRepaintSettleNs)
		vi.ConsoleLine(markerKey + string([]byte{b}))
		if b == '1' || b == '2' || b == '3' {
			vi.ConsoleLine(markerView + viewName(m.view))
		}
		vi.ConsoleLine(markerRepaint)
	}

	// M73i SGR mouse FSM, byte-for-byte charmhello's: ESC [ < b ; x ; y M|m
	// shares the tty with keys; non-mouse escapes flush as keys.
	var mouseTail []byte
	var mouseB, mouseX, mouseY int
	msWait, msMouse, msDrop := 0, 1, 2
	msStep := func(b byte) int {
		switch len(mouseTail) {
		case 0:
			if b == 0x1b {
				mouseTail = append(mouseTail, b)
				return msWait
			}
			return msDrop
		case 1:
			if b == '[' {
				mouseTail = append(mouseTail, b)
				return msWait
			}
			mouseTail = mouseTail[:0]
			return msDrop
		case 2:
			if b == '<' {
				mouseTail = append(mouseTail, b)
				return msWait
			}
			mouseTail = mouseTail[:0]
			return msDrop
		default:
			if (b >= '0' && b <= '9') || b == ';' {
				if len(mouseTail) >= 32 {
					mouseTail = mouseTail[:0]
					return msDrop
				}
				mouseTail = append(mouseTail, b)
				return msWait
			}
			if b == 'M' || b == 'm' {
				mouseTail = append(mouseTail, b)
				ok, btn, x, y := parseSGRMouse(mouseTail)
				mouseTail = mouseTail[:0]
				if ok {
					mouseB, mouseX, mouseY = btn, x, y
					return msMouse
				}
				return msDrop
			}
			mouseTail = mouseTail[:0]
			return msDrop
		}
	}

	handleMouse := func() {
		vi.ConsoleLine(markerMouse + vi.Itoa64(int64(mouseB)) +
			" x=" + vi.Itoa64(int64(mouseX)) +
			" y=" + vi.Itoa64(int64(mouseY)))
		// Act on release only; a tab-strip hit switches the view and
		// repaints before the view marker the gate can wait on.
		if mouseB != 32 {
			return
		}
		v := tabAtCell(mouseX, mouseY)
		if v < 0 || v == m.view {
			return
		}
		m.view, m.scroll = v, 0
		if !paint(fd, m) {
			shutdown(ta, fd, 4)
		}
		vi.SleepNs(presentSettleNs)
		vi.ConsoleLine(markerView + viewName(m.view))
		vi.ConsoleLine(markerRepaint)
	}

	var in [64]byte
	for {
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			for _, b := range in[:n] {
				if len(mouseTail) > 0 || b == 0x1b {
					switch msStep(b) {
					case msWait:
						continue
					case msMouse:
						handleMouse()
						continue
					}
					pending := mouseTail
					mouseTail = nil
					for _, pb := range pending {
						emitKey(pb)
					}
				}
				emitKey(b)
			}
		}

		ev, result, ok := vi.PollEventRaw()
		if !ok {
			if result < 0 {
				shutdown(ta, fd, 5)
			}
			if n <= 0 {
				vi.Sleep(1)
			}
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			shutdown(ta, fd, 0)
		case tabapp.ActionResized:
			// Frame is fixed-ANSI; repaint into the new canvas (M73j seam).
			if !paint(fd, m) {
				shutdown(ta, fd, 4)
			}
		}
	}
}

// parseSGRMouse reads ESC [ < b ; x ; y M|m — hand-rolled (no strconv):
// the app only ever prints what the kernel sent. charmhello's parser.
func parseSGRMouse(seq []byte) (bool, int, int, int) {
	if len(seq) < 6 || seq[0] != 0x1b || seq[1] != '[' || seq[2] != '<' {
		return false, 0, 0, 0
	}
	var vals [3]int
	idx := 0
	cur := 0
	digits := false
	for i := 3; i < len(seq); i++ {
		b := seq[i]
		if b >= '0' && b <= '9' {
			cur = cur*10 + int(b-'0')
			digits = true
		} else if b == ';' {
			if !digits || idx >= 2 {
				return false, 0, 0, 0
			}
			vals[idx] = cur
			idx++
			cur = 0
			digits = false
		} else if b == 'M' || b == 'm' {
			if !digits || idx != 2 {
				return false, 0, 0, 0
			}
			vals[2] = cur
			return true, vals[0], vals[1], vals[2]
		} else {
			return false, 0, 0, 0
		}
	}
	return false, 0, 0, 0
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	_, _ = vi.FileWrite(fd, []byte("\x1b[?1049l\x1b[?25h"))
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}
