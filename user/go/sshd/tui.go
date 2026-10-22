//go:build virelai || sshdtui

// The M168e (#2961) interactive session: a pty-req + shell channel serves a
// real Bubble Tea v2 Program — the Wish model on sshlib instead of
// gliderlabs/ssh. tea.WithInput is an io.Reader fed from the drained session
// queue, tea.WithOutput is an io.Writer whose bytes reach the one goroutine
// that owns sshlib.Server and the vi.Conn over a channel, and window-change
// arrives as tea.WindowSizeMsg because a non-term.File output has no resize
// listener (bubbletea v2.0.9 tea.go:690). No state is shared between the
// owner goroutine and the Program's goroutines — only the two channels.
package main

import (
	"io"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"

	"virelai/sshlib"
	"virelai/vi"
)

const (
	markerTUIStart = "sshd: tui start "
	markerTUISize  = "sshd: tui size "
	markerTUIExit  = "sshd: tui exit "
)

// termProfile maps the client's pty TERM to a colour profile: a
// `*-256color` name gets ANSI256, a `*truecolor*`/`*direct*` name gets
// TrueColor, anything else gets plain ANSI. The ssh channel carries no
// terminfo lookup, so the name is the whole contract.
func termProfile(term string) colorprofile.Profile {
	switch {
	case strings.Contains(term, "truecolor"), strings.Contains(term, "direct"):
		return colorprofile.TrueColor
	case strings.HasSuffix(term, "-256color"):
		return colorprofile.ANSI256
	default:
		return colorprofile.ANSI
	}
}

// tuiConfig carries the session facts the model renders plus the seam the
// owner supplies: log is the serial-marker sink (vi.ConsoleLine on the
// guest), kill asks the Program to stop when the transport dies first, and
// tick sizes the uptime refresh (tests shorten it).
type tuiConfig struct {
	user, keyAlgo string
	term          string
	cols, rows    int
	tick          time.Duration
	log           func(string)
	kill          <-chan struct{}
}

type tuiTickMsg time.Time

// tuiResizeMsg is the session-authoritative size update. The dispatcher
// sends it paired with a tea.WindowSizeMsg: the window message resizes the
// renderer, this one resizes the model. The model must not take its size
// from WindowSizeMsg itself — the Program announces the declared
// (pty-req) size on its own goroutine at startup, and that announcement
// may land AFTER a real window-change already queued on the session
// channel; last-writer-wins would then stick the view on the stale size.
type tuiResizeMsg struct{ w, h int }

// tuiModel is the small honest session view: who is on the channel, the
// client's TERM and live size, an uptime that ticks once a second, and `q`
// to leave.
type tuiModel struct {
	user, keyAlgo string
	term          string
	cols, rows    int
	started       time.Time
	up            int
	tick          time.Duration
	now           func() time.Time
}

func newTUIModel(cfg tuiConfig) tuiModel {
	return tuiModel{
		user: cfg.user, keyAlgo: cfg.keyAlgo,
		term: cfg.term, cols: cfg.cols, rows: cfg.rows,
		started: time.Now(), tick: cfg.tick, now: time.Now,
	}
}

func (m tuiModel) Init() tea.Cmd {
	return tea.Tick(m.tick, func(t time.Time) tea.Msg { return tuiTickMsg(t) })
}

func (m tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tuiResizeMsg:
		m.cols, m.rows = msg.w, msg.h
	case tuiTickMsg:
		m.up = int(m.now().Sub(m.started) / time.Second)
		return m, tea.Tick(m.tick, func(t time.Time) tea.Msg { return tuiTickMsg(t) })
	case tea.KeyPressMsg:
		if msg.String() == "q" || msg.String() == "ctrl+c" {
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m tuiModel) View() tea.View {
	var b strings.Builder
	b.WriteString("GOSSHD session — Bubble Tea over sshlib\r\n")
	b.WriteString("user=" + m.user + " key=" + m.keyAlgo + "\r\n")
	b.WriteString("term=" + m.term + " size " +
		strconv.Itoa(m.cols) + "x" + strconv.Itoa(m.rows) + "\r\n")
	b.WriteString("up " + strconv.Itoa(m.up) + "s\r\n\r\n")
	b.WriteString("press q to disconnect\r\n")
	return tea.NewView(b.String())
}

// tuiReader is tea.WithInput over the drained CHANNEL_DATA: each queued
// byte slice is one Read chunk, a closed channel is the client's EOF.
type tuiReader struct {
	ch  <-chan []byte
	buf []byte
}

func (r *tuiReader) Read(p []byte) (int, error) {
	for len(r.buf) == 0 {
		b, ok := <-r.ch
		if !ok {
			return 0, io.EOF
		}
		r.buf = b
	}
	n := copy(p, r.buf)
	r.buf = r.buf[n:]
	return n, nil
}

// tuiWriter is tea.WithOutput: every frame the renderer posts is handed to
// the owner goroutine as one item — never to the Server directly. A dead
// transport (kill) or a finished Program (stop) fails the write instead of
// parking the renderer forever.
type tuiWriter struct {
	ch   chan<- []byte
	kill <-chan struct{}
	stop <-chan struct{}
}

func (w tuiWriter) Write(p []byte) (int, error) {
	cp := append([]byte(nil), p...)
	select {
	case w.ch <- cp:
		return len(p), nil
	case <-w.kill:
		return 0, io.ErrClosedPipe
	case <-w.stop:
		return 0, io.ErrClosedPipe
	}
}

// dispatchTUIEvents routes the owner's drained session events into the
// Program: data bytes to the input reader, resizes to a WindowSizeMsg
// (renderer) + tuiResizeMsg (model) pair, client EOF to a closed input,
// and kill to Program.Kill. The `sshd: tui size` marker is logged here so
// the resize is on the serial record even when the client repaints
// nothing.
func dispatchTUIEvents(events <-chan sshlib.InEvent, inCh chan []byte, stop <-chan struct{}, p *tea.Program, cfg tuiConfig) {
	closed := false
	closeIn := func() {
		if !closed {
			closed = true
			close(inCh)
		}
	}
	defer closeIn()
	for {
		select {
		case <-stop:
			return
		case <-cfg.kill:
			p.Kill()
			return
		case ev, ok := <-events:
			if !ok {
				return
			}
			switch ev.Kind {
			case sshlib.InData:
				if closed {
					continue
				}
				select {
				case inCh <- ev.Data:
				case <-stop:
					return
				case <-cfg.kill:
					p.Kill()
					return
				}
			case sshlib.InResize:
				cfg.log(markerTUISize + strconv.Itoa(int(ev.Cols)) + "x" + strconv.Itoa(int(ev.Rows)))
				p.Send(tea.WindowSizeMsg{Width: int(ev.Cols), Height: int(ev.Rows)})
				p.Send(tuiResizeMsg{w: int(ev.Cols), h: int(ev.Rows)})
			case sshlib.InEOF:
				closeIn()
			}
		}
	}
}

// runSessionProgram runs the Program over the two channels and returns the
// final model with the session's exit status: 0 on a clean quit, 1 when Run
// reports an error (a transport kill included).
func runSessionProgram(events <-chan sshlib.InEvent, out chan<- []byte, cfg tuiConfig) (tuiModel, int) {
	if cfg.log == nil {
		cfg.log = func(string) {}
	}
	if cfg.kill == nil {
		cfg.kill = make(chan struct{})
	}
	if cfg.tick <= 0 {
		cfg.tick = time.Second
	}
	inCh := make(chan []byte, 8)
	stop := make(chan struct{})
	p := tea.NewProgram(
		newTUIModel(cfg),
		tea.WithInput(&tuiReader{ch: inCh}),
		tea.WithOutput(tuiWriter{ch: out, kill: cfg.kill, stop: stop}),
		tea.WithColorProfile(termProfile(cfg.term)),
		tea.WithWindowSize(cfg.cols, cfg.rows),
	)
	go dispatchTUIEvents(events, inCh, stop, p, cfg)
	final, err := p.Run()
	close(stop)
	m, _ := final.(tuiModel)
	if err != nil {
		cfg.log("sshd: tui error " + err.Error())
		return m, 1
	}
	return m, 0
}

// serveTUI owns the session after shell is granted: this goroutine (the one
// that owns srv and c all along) polls the socket, feeds inbound wire bytes,
// forwards drained events to the Program's channel, and ships Program
// output and sshlib's WINDOW_ADJUST credit back out through pacedSend. It
// returns when the transport is closed — by the Program's exit-status or by
// the client.
func serveTUI(c *vi.Conn, srv *Server, leftover *[]byte, user, keyAlgo string) int {
	pty, _ := srv.PtyGranted()
	cfg := tuiConfig{
		user: user, keyAlgo: keyAlgo,
		term: pty.Term, cols: int(pty.Cols), rows: int(pty.Rows),
		log: vi.ConsoleLine,
	}
	cfg.log(markerTUIStart + "term=" + pty.Term + " size=" +
		strconv.Itoa(cfg.cols) + "x" + strconv.Itoa(cfg.rows))

	events := make(chan sshlib.InEvent, 64)
	out := make(chan []byte, 64)
	kill := make(chan struct{})
	done := make(chan int, 1)
	cfg.kill = kill
	go func() {
		_, rc := runSessionProgram(events, out, cfg)
		done <- rc
	}()

	rc := 0
	progExit := -1
	var buf [vi.TCPPayloadMax]byte
	doneCh := (<-chan int)(done)
	// Drained events the Program has not consumed yet. Nothing is dropped:
	// the ssh window bounds what the client can have in flight, and the
	// pending queue just holds what the dispatcher has not taken.
	var pending []sshlib.InEvent

	send := func(p []byte) bool {
		if err := pacedSend(c, p, leftover); err != nil {
			cfg.log(markerErr + "send")
			rc = 1
			return false
		}
		return true
	}

	for !srv.Closed() {
		progress := false
		// Wire bytes pacedSend captured while sending still belong to the
		// transport — feed them before polling for more.
		if len(*leftover) > 0 {
			in := *leftover
			*leftover = nil
			if !send(srv.Feed(in)) {
				break
			}
			progress = true
		}
		select {
		case b := <-out:
			if !send(srv.Write(b)) {
				goto abort
			}
			progress = true
		case progExit = <-doneCh:
			doneCh = nil
			for {
				select {
				case b := <-out:
					if !send(srv.Write(b)) {
						goto abort
					}
				default:
					goto flushed
				}
			}
		flushed:
			cfg.log(markerTUIExit + strconv.Itoa(progExit))
			if !send(srv.CloseSession(uint32(progExit))) {
				goto abort
			}
			progress = true
		default:
		}
		if mask, err := c.ReadyMask(); err != nil {
			cfg.log(markerErr + "ready")
			rc = 1
			break
		} else if mask&1 != 0 {
			n, err := c.Recv(buf[:])
			if err != nil {
				cfg.log(markerErr + "recv")
				rc = 1
				break
			}
			if n > 0 {
				if !send(srv.Feed(buf[:n])) {
					break
				}
				progress = true
			}
		}
		// The drain returns window credit (WINDOW_ADJUST leaves through
		// Take) and queues the client events the dispatcher consumes. Once
		// the Program is gone the events are drained for the credit only.
		if progExit < 0 {
			pending = append(pending, srv.Drain()...)
			kept := pending[:0]
			for _, ev := range pending {
				select {
				case events <- ev:
				default:
					kept = append(kept, ev)
				}
			}
			pending = kept
		} else {
			srv.Drain()
		}
		if b := srv.Take(); len(b) > 0 {
			if !send(b) {
				break
			}
			progress = true
		}
		if !progress {
			vi.Sleep(1)
		}
	}
abort:
	if progExit < 0 {
		close(kill)
		progExit = <-done
		cfg.log(markerTUIExit + strconv.Itoa(progExit))
	}
	if srv.Failed() {
		rc = 1
	}
	return rc
}
