//go:build virelai || gohelp

// Command help is GOHELP.ELF: the M74c (issue #1646) help browser TUI —
// a Bubble Tea model over the bound /dev/tty (the M74a GOFILES shape: same
// lifecycle, same marker discipline, one app per ELF).
//
// It does not run Bubble Tea's host Program loop: the Virelai port has no
// POSIX tty or signals. Key bytes come from the kernel's bound /dev/tty
// queue (CSI sequences decoded by virelai/rss/keys, ?1006 SGR mouse reports
// split off first) and View's ANSI frame goes back into that bound tty.
//
// Marker discipline: a frame's markers are flushed only AFTER that frame is
// painted and yielded, so every `gohelp: …` line the go-help gate waits on
// describes a screen that already exists — the screenshot barrier can never
// race the paint.
package main

import (
	tea "charm.land/bubbletea/v2"

	"virelai/rss/keys"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOHELP.ELF"
	appTitle = "Help"
	natW     = 512
	natH     = 384

	ttyPath = "/dev/tty"
)

// Wait durations in nanoseconds (ADR 0060 audit): settles use the deadline
// overlay (vi.SleepNs, slot 94) instead of guessed scheduler ticks.
const (
	ms = 1_000_000

	// detailSettleNs gives the screenshot at `gohelp: detail` time to
	// capture before the gate's close script tears the window down —
	// "hundreds of ms" per the site comment; the 50-tick form was ~50 s.
	detailSettleNs = 300 * ms
	// paintSettleNs is the settle between a paint and the markers the gate
	// snapshots on.
	paintSettleNs = 250 * ms
	// keyRepaintSettleNs is the settle between a key-driven repaint and the
	// `gohelp: key`/`repaint` markers.
	keyRepaintSettleNs = 200 * ms
)

// paint writes one frame into the bound tty. A tty write marks the window
// dirty; callers yield once before their markers so the markers describe a
// painted frame. A two-pane frame is many KiB and sys_file_write refuses
// count > 2048 with -ENOSPC, so the frame goes through vi.FileWriteAll —
// the chunked-by-confirmed-count primitive term/sh use (M66a). Observed
// failing on GOFILES' first gate run: one big FileWrite returned -5 and the
// app honestly exited status=4 before its first marker.
func paint(fd uint32, m model) bool {
	data := []byte(m.View().Content)
	n, rc := vi.FileWriteAll(fd, data)
	return rc >= 0 && n == len(data)
}

// flush prints the model's queued serial markers in order.
func flush(m *model) {
	for _, ln := range m.drain() {
		vi.ConsoleLine(ln)
	}
}

// settle yields then prints the detail-settle barrier: the screenshot at
// `gohelp: detail …` has this long to capture before the gate's close
// script (triggered by this marker) tears the window down.
func settle(m *model) {
	if !m.detailBatch {
		return
	}
	m.detailBatch = false
	vi.SleepNs(detailSettleNs)
	vi.ConsoleLine(markerSettled)
}

func main() {
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH})
	if ta == nil {
		vi.ConsoleLine("gohelp: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine("gohelp: no /dev/tty")
		ta.CloseAndExit(2)
	}
	fd := uint32(h)
	if vi.TtyAttachWindow(ta.Win) != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine("gohelp: attach failed")
		ta.CloseAndExit(3)
	}
	vi.ConsoleLine(markerAttach)
	// M73i (#1635): enable xterm mouse reporting — ?1000 press/release
	// edges, ?1006 SGR encoding — so rows are clickable. The kernel tracks
	// the modes per screen (never painted).
	if _, rcw := vi.FileWrite(fd, []byte("\x1b[?1000h\x1b[?1006h")); rcw < 0 {
		vi.ConsoleLine("gohelp: mouse enable failed")
	}

	cols, rows := gridOf(ta.W, ta.H)
	m := newModel(cols, rows)
	if !paint(fd, m) {
		shutdown(ta, fd, 4)
	}
	vi.SleepNs(paintSettleNs)
	vi.ConsoleLine(markerPainted)
	flush(&m)
	vi.ConsoleLine(markerPresent)
	vi.ConsoleLine(markerReady)

	var in [64]byte
	for {
		// Keys and mouse reports: the tty read is non-blocking (0 when
		// the queue is empty).
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			if !feed(&m, fd, in[:n]) {
				if m.quit {
					shutdown(ta, fd, 0)
				}
				shutdown(ta, fd, 4)
			}
		}

		// Window events: closed ends the session, resize re-derives the
		// grid best-effort (M73j #1636 has landed; the gate runs at the
		// native rect, this path is for a real drag).
		progress := n > 0
		for {
			ev, result, ok := vi.PollEventRaw()
			if !ok {
				if result < 0 {
					shutdown(ta, fd, 7)
				}
				break
			}
			progress = true
			switch ta.Dispatch(ev) {
			case tabapp.ActionClosed:
				shutdown(ta, fd, 0)
			case tabapp.ActionResized:
				cols, rows := gridOf(ta.W, ta.H)
				m.setSize(cols, rows)
				if !paint(fd, m) {
					shutdown(ta, fd, 4)
				}
				vi.SleepNs(paintSettleNs)
				flush(&m)
				vi.ConsoleLine(markerResized + vi.Itoa64(int64(cols)) +
					" h=" + vi.Itoa64(int64(rows)))
				vi.ConsoleLine(markerRepaint)
			}
		}

		if !progress {
			vi.Sleep(1)
		}
	}
}

// mouseTail holds an unterminated SGR report across reads (the kernel
// writes a report in one go, but a split must not leak bytes into the key
// path — a stray 'q' would quit the browser).
var mouseTail []byte

// feed consumes one read chunk of tty bytes: SGR mouse reports are split
// off first (ESC [ < … M|m), the rest decodes to key events. It returns
// false when the caller must shut down (m.quit, or a paint failure).
func feed(m *model, fd uint32, chunk []byte) bool {
	var kbuf []byte
	if len(mouseTail) > 0 {
		kbuf = append(mouseTail, chunk...)
		mouseTail = nil
	} else {
		kbuf = append(kbuf, chunk...)
	}
	for len(kbuf) > 0 {
		if kbuf[0] == 0x1b && len(kbuf) >= 3 && kbuf[1] == '[' && kbuf[2] == '<' {
			// A mouse report only exists in this shape; if the terminator
			// has not arrived yet, hold the tail for the next read.
			end := -1
			for i := 3; i < len(kbuf); i++ {
				if kbuf[i] == 'M' || kbuf[i] == 'm' {
					end = i
					break
				}
			}
			if end < 0 {
				if len(kbuf) > 80 { // runaway: never a report
					mouseTail = nil
					return true
				}
				mouseTail = append([]byte(nil), kbuf...)
				return true
			}
			ok, b, x, y := parseSGRMouse(kbuf[:end+1])
			kbuf = kbuf[end+1:]
			if !ok {
				continue
			}
			if !onMouse(m, fd, b, x, y) {
				return false
			}
			continue
		}
		ev, used := keys.Decode(kbuf)
		if used <= 0 {
			return true
		}
		kbuf = kbuf[used:]
		if ev.Key == keys.KeyNone {
			continue
		}
		if !onKey(m, fd, ev) {
			return false
		}
	}
	return true
}

// onKey runs one key through the model, then paints and flushes: markers
// for this key land only after its frame exists.
func onKey(m *model, fd uint32, ev keys.Event) bool {
	// Update has a VALUE receiver (the tea.Model contract): the returned
	// model IS the state — discarding it makes every key a no-op (observed
	// on GOFILES' first gate run: `key return` printed, nothing navigated).
	next, _ := m.Update(toTea(ev))
	if nm, ok := next.(model); ok {
		*m = nm
	}
	if m.quit {
		return false
	}
	if !paint(fd, *m) {
		return false
	}
	vi.SleepNs(keyRepaintSettleNs)
	flush(m)
	vi.ConsoleLine(markerKey + keyLabel(ev))
	vi.ConsoleLine(markerRepaint)
	settle(m)
	return true
}

// onMouse handles one SGR report: releases only get their marker (charmhello
// precedent), a left press goes through the model as a cell click.
func onMouse(m *model, fd uint32, b, x, y int) bool {
	pressed := b&32 == 0 && b&3 == 0 // left button, press edge
	if pressed {
		next, _ := m.Update(tea.MouseClickMsg{X: x, Y: y, Button: tea.MouseLeft})
		if nm, ok := next.(model); ok {
			*m = nm
		}
		if m.quit {
			return false
		}
		if !paint(fd, *m) {
			return false
		}
		vi.Sleep(1)
		flush(m)
		vi.ConsoleLine(markerRepaint)
	}
	vi.ConsoleLine(markerMouse + vi.Itoa64(int64(b)) +
		" x=" + vi.Itoa64(int64(x)) + " y=" + vi.Itoa64(int64(y)))
	return true
}

// parseSGRMouse reads ESC [ < b ; x ; y M|m — hand-rolled (no strconv): the
// app only ever prints what the kernel sent. (M73i #1635 shape, as in
// charmhello and GOFILES.)
func parseSGRMouse(seq []byte) (bool, int, int, int) {
	if len(seq) < 6 || seq[0] != 0x1b || seq[1] != '[' || seq[2] != '<' {
		return false, 0, 0, 0
	}
	var vals [3]int
	idx := 0
	cur := 0
	digits := false
	for i := 3; i < len(seq); i++ {
		c := seq[i]
		switch {
		case c >= '0' && c <= '9':
			cur = cur*10 + int(c-'0')
			digits = true
		case c == ';':
			if !digits || idx >= 2 {
				return false, 0, 0, 0
			}
			vals[idx] = cur
			idx++
			cur = 0
			digits = false
		case c == 'M' || c == 'm':
			if !digits || idx != 2 {
				return false, 0, 0, 0
			}
			vals[2] = cur
			return true, vals[0], vals[1], vals[2]
		default:
			return false, 0, 0, 0
		}
	}
	return false, 0, 0, 0
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	// Leave mouse reporting off, the alt screen, and show the cursor again
	// before the window goes away.
	_, _ = vi.FileWrite(fd, []byte("\x1b[?1000l\x1b[?1006l\x1b[?1049l\x1b[?25h"))
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}
