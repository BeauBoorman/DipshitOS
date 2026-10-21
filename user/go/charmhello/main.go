//go:build virelai || charmhello

// Command charmhello runs a REAL Bubble Tea v2 Program on the bound
// /dev/tty (#2957): teatty hands the Program a term.File over the
// kernel's tty queue, Bubble Tea's own decoder/renderer/mouse/resize/quit
// drive the seat window, and Update only maps messages — the app no
// longer pumps its own loop.
package main

import (
	"errors"

	tea "charm.land/bubbletea/v2"

	"virelai/tabapp"
	"virelai/teatty"
	"virelai/vi"
)

const (
	appName  = "CHARMHELLO.ELF"
	appTitle = "Charm Hello"
	natW     = 640
	natH     = 400

	markerOpen    = "charmhello: open id="
	markerAttach  = "charmhello: attached"
	markerPainted = "charmhello: painted"
	markerReady   = "charmhello: ready"
	markerKey     = "charmhello: key "
	markerRepaint = "charmhello: repainted"
	markerClose   = "charmhello: close"
	markerOK      = "charmhello OK"
	markerMouse   = "charmhello: mouse b="
	markerSize    = "charmhello: size "
	markerProgram = "charmhello: program"
)

func sizeMarker(m model) string {
	return markerSize + vi.Itoa64(int64(m.cols)) + "x" + vi.Itoa64(int64(m.rows))
}

// paintedMsg carries the serial lines that must fire AFTER the frame a
// message triggered is actually painted. Update returns afterPaint cmds;
// the cmd's message lands on the NEXT eventLoop iteration — but the
// cursed renderer is asynchronous (p.render only queues the view; the
// 60 fps ticker flushes it), so the cmd also yields a few ticks first:
// the marker then post-dates at least one renderer flush plus a WM
// publish — the Program equivalent of the hand loop's
// paint -> vi.Sleep -> ConsoleLine order.
type paintedMsg struct{ lines []string }

func afterPaint(lines ...string) tea.Cmd {
	return func() tea.Msg {
		vi.Sleep(4)
		return paintedMsg{lines: lines}
	}
}

type model struct {
	paused bool
	keys   uint32
	quit   bool
	cols   int
	rows   int
	sized  bool // the Program's initial WindowSizeMsg landed
}

// Init is intentionally command-free: the Program sends the initial
// WindowSizeMsg itself.
func (model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case paintedMsg:
		for _, l := range msg.lines {
			vi.ConsoleLine(l)
		}
		return m, nil

	case tea.WindowSizeMsg:
		m.cols, m.rows = msg.Width, msg.Height
		if !m.sized {
			// The Program's first size: term.GetSize's answer at the
			// declared rect (640x400 -> 80x24 cells) — the first frame is
			// measured, not a guess (the M73j contract, now through the
			// framework's own initial-size path).
			m.sized = true
			vi.ConsoleLine(sizeMarker(m))
			return m, afterPaint(markerPainted, markerReady)
		}
		// A live WIN_RESIZE (e.g. the 'r' owner-seam resize): repaint at
		// the new cells, then the marker pair the gate choreographs.
		return m, afterPaint(sizeMarker(m), markerRepaint)

	case tea.KeyPressMsg:
		switch msg.Key().Text {
		case "q":
			m.quit = true
			return m, tea.Quit
		case " ":
			m.paused = !m.paused
			return m, afterPaint(markerKey+"space", markerRepaint)
		default:
			m.keys++
			if msg.Key().Text == "r" {
				// The owner-side resize seam — sys_win_resize (slot 47)
				// clamps + reflows and pushes WIN_RESIZE; the Program's
				// event goroutine turns it into the WindowSizeMsg above
				// (512x384 -> 64x23 cells), the class-B proof.
				_ = vi.WinResize(teatty.WindowID(), 512, 384)
			}
			return m, afterPaint(markerKey+msg.Key().Text, markerRepaint)
		}

	case tea.MouseClickMsg:
		// SGR b is the X11 button code MINUS one (left = 0), x/y the
		// 1-based cells — the same fields the hand parser printed.
		vi.ConsoleLine(mouseLine(int(msg.Button)-1, msg.X+1, msg.Y+1))
		return m, nil

	case tea.MouseMotionMsg:
		// The kernel encodes SGR release/drag as b+32 (the legacy Cb+32
		// convention; terminal.zig encodeMouse), and ultraviolet reads
		// bit 5 as "motion", so a release surfaces HERE, not as
		// MouseReleaseMsg. With ?1002 (never ?1003) every motion is an
		// edge the kernel really sent; reconstruct its SGR b.
		b := 32 + int(msg.Button) - 1
		if msg.Button == tea.MouseNone {
			b = 35 // free-motion encoding (unreached under ?1002)
		}
		vi.ConsoleLine(mouseLine(b, msg.X+1, msg.Y+1))
		return m, nil

	case tea.MouseReleaseMsg:
		// Unreached for the kernel's encoding (see above); handled so a
		// standards-shaped peer still prints the release marker.
		vi.ConsoleLine(mouseLine(32+int(msg.Button)-1, msg.X+1, msg.Y+1))
		return m, nil
	}
	return m, nil
}

func mouseLine(b, x, y int) string {
	return markerMouse + vi.Itoa64(int64(b)) +
		" x=" + vi.Itoa64(int64(x)) +
		" y=" + vi.Itoa64(int64(y))
}

func (m model) View() tea.View {
	state := "\x1b[1;92mRUNNING\x1b[0m"
	if m.paused {
		state = "\x1b[1;93mPAUSED\x1b[0m"
	}
	v := tea.NewView(
		"\x1b[1;95m  VirelaiOS × Bubble Tea \x1b[0m\n\n" +
			"\x1b[96m  bound /dev/tty · real tea.Model\x1b[0m\n\n" +
			"  status: " + state + "\n" +
			"  keys:   \x1b[1;97m" + vi.Itoa64(int64(m.keys)) + "\x1b[0m\n" +
			"  size:   \x1b[1;97m" + vi.Itoa64(int64(m.cols)) + "x" + vi.Itoa64(int64(m.rows)) + "\x1b[0m\n\n" +
			"\x1b[90m  space toggles · q exits\x1b[0m\n",
	)
	// The renderer owns the screen now: alt-screen + hidden cursor +
	// ?1002/?1006 mouse reporting are View fields, not manual escapes
	// (?1002 reports press/release edges like the hand loop's ?1000).
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	return v
}

// mouseEnable is the byte-exact mode pair the hand loop wrote
// (?1000 press/release edges + ?1006 SGR); the View's MouseMode adds
// ?1002 on top through the renderer. Belt and suspenders: the kernel's
// emit path is mode-OR'd, so the union reports exactly what M73i proved.
const mouseEnable = "\x1b[?1000h\x1b[?1006h"

func main() {
	// teatty.Open hosts the window AND binds /dev/tty to it (win_open,
	// slot 23, slot 67 TtyWindow — the kernel's required order).
	in, out, err := teatty.Open(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     32,
		Y:     32,
		W:     natW,
		H:     natH,
	})
	if err != nil {
		switch {
		case errors.Is(err, teatty.ErrWindow):
			vi.ConsoleLine("charmhello: open failed")
			vi.Exit(1)
		case errors.Is(err, teatty.ErrTTY):
			vi.ConsoleLine("charmhello: no /dev/tty")
			vi.Exit(2)
		default:
			vi.ConsoleLine("charmhello: attach failed")
			vi.Exit(3)
		}
	}
	defer teatty.Close()
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(teatty.WindowID())))
	vi.ConsoleLine(markerAttach)
	// The kernel tracks tracking modes per screen; set them before the
	// Program starts so no early pointer event is missed.
	_, _ = out.Write([]byte(mouseEnable))

	// The Program is the whole point of #2957: Bubble Tea's decoder,
	// renderer, mouse, resize and quit handling drive the window, and
	// the app is only a Model. TERM is pinned so colorprofile answers
	// ANSI256 through the real IsTerminal path — the same profile the
	// termenv shim asserts for the hand-loop apps.
	p := tea.NewProgram(
		model{},
		tea.WithInput(in),
		tea.WithOutput(out),
		tea.WithEnvironment([]string{"TERM=xterm-256color"}),
	)
	vi.ConsoleLine(markerProgram)
	if _, err := p.Run(); err != nil {
		vi.ConsoleLine("charmhello: program error")
		vi.Exit(4)
	}
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	vi.Exit(0)
}
