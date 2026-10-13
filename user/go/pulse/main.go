//go:build virelai || pulse

// Command pulse is PULSE.ELF: the Go seat's Charm TUI system monitor.
//
// It does not run Bubble Tea's host Program loop: the Virelai port has no
// POSIX tty or signals, and this app must take bytes from the kernel's bound
// /dev/tty queue. It still owns a real tea.Model — Update receives
// tty-decoded key messages and View emits Bubble Tea's ANSI text into that
// bound tty, repainted on every key and on every 1 Hz timer tick.
package main

import (
	"virelai/tabapp"
	"virelai/vi"
	"virelai/vsys"
)

const (
	appName  = "PULSE.ELF"
	appTitle = "PULSE.ELF" // binary name as title: guessBin falls back to the
	// title as the bin name, so session restore maps back here.
	natW = 640
	natH = 400

	ttyPath = "/dev/tty"

	markerOpen     = "pulse: open id="
	markerAttach   = "pulse: attached"
	markerPainted  = "pulse: painted"
	markerReady    = "pulse: ready"
	markerKey      = "pulse: key "
	markerTick     = "pulse: tick"
	markerRepaint  = "pulse: repainted"
	markerKill     = "pulse: kill "
	markerClose    = "pulse: close"
	markerOK       = "pulse OK"
	markerTimerArm = "pulse: timer armed"
)

func paint(fd uint32, m model) bool {
	v := m.View()
	n, rc := vi.FileWrite(fd, []byte(v.Content))
	return rc >= 0 && n == len(v.Content)
}

func armTimer() bool {
	return vsys.TimerSet(1) >= 0 // 1 tick = 1 s on VZ: the 1 Hz refresh
}

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,
	})
	if ta == nil {
		vi.ConsoleLine("pulse: open failed")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine("pulse: no /dev/tty")
		ta.CloseAndExit(2)
	}
	fd := uint32(h)
	if vi.TtyAttachWindow(ta.Win) != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine("pulse: attach failed")
		ta.CloseAndExit(3)
	}
	vi.ConsoleLine(markerAttach)

	m := newModel(guestKill, takeSnapshot)
	if !paint(fd, m) {
		shutdown(ta, fd, 4)
	}
	// A tty write marks the window dirty; yield once before the marker the
	// VZ gate uses as its screenshot barrier, so it describes a painted frame.
	vi.Sleep(2)
	vi.ConsoleLine(markerPainted)

	if !armTimer() {
		vi.ConsoleLine("pulse: timer arm failed")
		ta.CloseAndExit(5)
	}
	vi.ConsoleLine(markerTimerArm)
	vi.ConsoleLine(markerReady)
	vi.ConsoleLine("pulse: procs " + vi.Itoa64(int64(len(m.snap.procs))))
	if m.usage.ok {
		// ADR 0047 evidence: the negotiated v2 rows actually arrived.
		vi.ConsoleLine("pulse: usage cpux10=" + vi.Itoa64(int64(m.usage.cpuX10)) +
			" memused=" + vi.Itoa64(int64(m.usage.memUsed)) +
			" memtotal=" + vi.Itoa64(int64(m.usage.memTotal)))
	}

	var in [64]byte
	for {
		// Keys: the tty read is non-blocking (0 when the queue is empty).
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			for _, b := range in[:n] {
				next, _ := m.Update(keyPress(b))
				m = next.(model)
				if m.quit {
					shutdown(ta, fd, 0)
				}
				if !paint(fd, m) {
					shutdown(ta, fd, 4)
				}
				vi.Sleep(1)
				if b == ' ' {
					vi.ConsoleLine(markerKey + "space")
				} else {
					vi.ConsoleLine(markerKey + string([]byte{b}))
				}
				vi.ConsoleLine(markerRepaint)
			}
		}

		// Events: the 1 Hz timer tick and window events. Drained fully so a
		// tick never waits behind a key burst.
		progress := n > 0
		for {
			ev, result, ok := vi.PollEventRaw()
			if !ok {
				if result < 0 {
					shutdown(ta, fd, 6)
				}
				break
			}
			progress = true
			switch ev.Kind {
			case vi.EvTimer:
				m.refresh()
				if !paint(fd, m) {
					shutdown(ta, fd, 4)
				}
				vi.Sleep(1)
				vi.ConsoleLine(markerTick)
				vi.ConsoleLine(markerRepaint)
				armTimer() // one-shot: re-arm every tick
			default:
				if ta.Dispatch(ev) == tabapp.ActionClosed {
					shutdown(ta, fd, 0)
				}
			}
		}

		if !progress {
			vi.Sleep(1)
		}
	}
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	_, _ = vi.FileWrite(fd, []byte("\x1b[?1049l\x1b[?25h"))
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}
