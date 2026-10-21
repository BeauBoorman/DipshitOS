//go:build virelai

package tea

import (
	"virelai/teatty"
	"virelai/vi"
)

// listenForResize is the Virelai replacement for the SIGWINCH watcher:
// there is no POSIX signal or ioctl TIOCGWINSZ in the guest, so the
// Program polls the process's own ADR 0009 event queue and delivers
// tea.WindowSizeMsg in cells — the TUI contract is cells, never pixels.
//
// Ownership contract: when this runs, THIS goroutine owns the event
// queue — a Program-loop app must not poll vi.PollEventRaw a second
// time. teatty and the app's main never poll; they only consume what
// this goroutine records. The manual-Update apps (pulse, files, help,
// gitui, rss) never run a Program, so they are unaffected and pump
// tabapp's ActionResized themselves.
//
//   - EvWinResize (kind 10): the kernel pushes the post-clamp frame rect
//     (arg0 w / arg1 h) — the seat's canvas grant, a split relayout and a
//     font zoom all arrive through it. teatty.NoteResize re-reads the
//     active cell rung (the zoom leg) and stores the cells that
//     checkResize/GetSize answer; then the msg reaches the model.
//   - EvWinClose (kind 8): the window's close gesture records on the
//     terminal (teatty.NotifyClose) and ends the Program with a QuitMsg,
//     so `dui close` and a model-requested quit converge on one
//     teardown (the v1 overlay's behaviour, kept — gostalgia-mods'
//     signals_virelai.go).
func (p *Program) listenForResize(done chan struct{}) {
	defer close(done)
	for {
		select {
		case <-p.ctx.Done():
			return
		default:
		}
		ev, _, ok := vi.PollEventRaw()
		if !ok {
			// Non-blocking poll: stay cooperative, one tick per idle.
			vi.Sleep(1)
			continue
		}
		switch ev.Kind {
		case vi.EvWinResize:
			cols, rows := teatty.NoteResize(ev.Arg0, ev.Arg1)
			p.Send(WindowSizeMsg{Width: cols, Height: rows})
		case vi.EvWinClose:
			teatty.NotifyClose()
			p.Send(QuitMsg{})
			return
		default:
			// KEY_DOWN landing here is the misbound-tty signature: the
			// kernel's E2 fallback delivers focused keys to this queue
			// only when the window has no terminal binding. Dropping is
			// correct — the bound tty owns keyboard bytes.
		}
	}
}
