//go:build virelai || fileman

// M124b (#2581): the pick-mode runtime loop — the ANSI face and key
// translation live in pick.go (untagged, host-tested); what stays here is
// the tty/event plumbing that references the tagged main.go helpers
// (shutdown) and the tabapp window dispatch.
package main

import (
	"virelai/appkit"
	"virelai/rss/keys"
	"virelai/tabapp"
	"virelai/vi"
)

// pickMain runs the picker until it produces its Result (or the window
// dies). It never returns: every exit path goes through shutdown, the same
// close discipline as the file-manager loop.
func pickMain(fd uint32, ta *tabapp.TabApp, start string, cols, rows int) {
	p := appkit.NewFilePicker(appkit.PickOpen, start)
	if !pickPaint(fd, &p, cols, rows) {
		shutdown(ta, fd, 4)
	}
	vi.Sleep(2)
	vi.ConsoleLine(markerPickMode + p.Dir)

	var in [64]byte
	for {
		n, _ := vi.FileRead(fd, in[:])
		progress := n > 0
		if n > 0 {
			for kbuf := in[:n]; len(kbuf) > 0; {
				// Mouse reporting is on (?1006 SGR) from the manager's
				// init: a report is ESC [ < b ; x ; y M|m — swallow it,
				// the picker is keyboard-driven here.
				if kbuf[0] == 0x1b && len(kbuf) >= 3 && kbuf[1] == '[' && kbuf[2] == '<' {
					end := -1
					for i := 3; i < len(kbuf); i++ {
						if kbuf[i] == 'M' || kbuf[i] == 'm' {
							end = i
							break
						}
					}
					if end < 0 {
						break
					}
					kbuf = kbuf[end+1:]
					continue
				}
				ev, used := keys.Decode(kbuf)
				if used <= 0 {
					break
				}
				kbuf = kbuf[used:]
				if ev.Key == keys.KeyNone {
					continue
				}
				_, done := p.HandleKey(pickKeyEvent(ev))
				if !pickPaint(fd, &p, cols, rows) {
					shutdown(ta, fd, 4)
				}
				vi.Sleep(1)
				if done {
					pickDone(&p)
					shutdown(ta, fd, 0)
				}
				vi.ConsoleLine(markerRepaint)
			}
		}
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
				cols, rows = gridOf(ta.W, ta.H)
				if !pickPaint(fd, &p, cols, rows) {
					shutdown(ta, fd, 4)
				}
				vi.ConsoleLine(markerRepaint)
			}
		}
		if !progress {
			vi.Sleep(1)
		}
	}
}
