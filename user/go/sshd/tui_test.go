//go:build sshdtui

// M168e (#2961) host tests — run over a transient modfile because
// bubbletea v2 lives outside the SDK go.mod. bash tools/go/build-sshd.sh
// stages the module at .build/sshd-module first, then:
//
//	cp user/go/go.mod user/go/.sshd-tui.mod
//	printf '\nrequire charm.land/bubbletea/v2 v2.0.9\nreplace charm.land/bubbletea/v2 => %s\n' \
//	    "$PWD/.build/sshd-module" >> user/go/.sshd-tui.mod
//	( cd user/go && go test -mod=mod -modfile .sshd-tui.mod -tags sshdtui ./sshd/ )
//	rm -f user/go/.sshd-tui.mod user/go/.sshd-tui.sum
package main

import (
	"strings"
	"sync"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"

	"virelai/sshlib"
)

func TestTermProfileTable(t *testing.T) {
	cases := []struct {
		term string
		want colorprofile.Profile
	}{
		{"xterm-256color", colorprofile.ANSI256},
		{"screen-256color", colorprofile.ANSI256},
		{"tmux-256color", colorprofile.ANSI256},
		{"xterm-truecolor", colorprofile.TrueColor},
		{"alacritty-direct", colorprofile.TrueColor},
		{"foot-direct", colorprofile.TrueColor},
		{"xterm", colorprofile.ANSI},
		{"vt100", colorprofile.ANSI},
		{"dumb", colorprofile.ANSI},
		{"", colorprofile.ANSI},
	}
	for _, c := range cases {
		if got := termProfile(c.term); got != c.want {
			t.Fatalf("termProfile(%q) = %v want %v", c.term, got, c.want)
		}
	}
}

func TestTUIModelWindowSizeAndView(t *testing.T) {
	m := newTUIModel(tuiConfig{
		user: "alice", keyAlgo: "ssh-ed25519",
		term: "xterm-256color", cols: 80, rows: 24, tick: time.Second,
	})
	if got := m.View().Content; !strings.Contains(got, "size 80x24") {
		t.Fatalf("initial view lacks the size line: %q", got)
	}
	up, _ := m.Update(tuiResizeMsg{w: 132, h: 43})
	got := up.(tuiModel)
	if got.cols != 132 || got.rows != 43 {
		t.Fatalf("WindowSizeMsg -> %dx%d", got.cols, got.rows)
	}
	if v := got.View().Content; !strings.Contains(v, "size 132x43") ||
		!strings.Contains(v, "user=alice") || !strings.Contains(v, "key=ssh-ed25519") ||
		!strings.Contains(v, "term=xterm-256color") {
		t.Fatalf("resized view missing lines: %q", v)
	}
}

func TestTUIModelQuitAndUptime(t *testing.T) {
	m := newTUIModel(tuiConfig{cols: 80, rows: 24, tick: time.Second})
	m.started = time.Now()
	m.now = func() time.Time { return m.started.Add(90 * time.Second) }
	up, cmd := m.Update(tuiTickMsg{})
	got := up.(tuiModel)
	if got.up != 90 {
		t.Fatalf("uptime = %d want 90", got.up)
	}
	if cmd == nil {
		t.Fatal("tick did not re-arm")
	}
	if _, cmd = m.Update(tea.KeyPressMsg(tea.Key{Code: 'q', Text: "q"})); cmd == nil {
		t.Fatal("q produced no command")
	} else if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatalf("q produced %T want tea.QuitMsg", cmd())
	}
}

// TestTUIRunSession drives the real Program over the event/output channels:
// a window-change lands as WindowSizeMsg, q exits with status 0, the
// `sshd: tui size` marker is logged, and a rendered frame carried the size
// line.
func TestTUIRunSession(t *testing.T) {
	events := make(chan sshlib.InEvent, 8)
	out := make(chan []byte, 256)
	var logs []string
	var mu sync.Mutex
	logf := func(s string) { mu.Lock(); logs = append(logs, s); mu.Unlock() }
	cfg := tuiConfig{
		user: "alice", keyAlgo: "ssh-ed25519",
		term: "xterm-256color", cols: 80, rows: 24,
		tick: 10 * time.Millisecond, log: logf,
	}
	type result struct {
		m  tuiModel
		rc int
	}
	done := make(chan result, 1)
	go func() {
		m, rc := runSessionProgram(events, out, cfg)
		done <- result{m, rc}
	}()

	var frames strings.Builder
	drainDone := make(chan struct{})
	go func() {
		defer close(drainDone)
		for b := range out {
			frames.Write(b)
		}
	}()

	events <- sshlib.InEvent{Kind: sshlib.InResize, Cols: 100, Rows: 40}
	events <- sshlib.InEvent{Kind: sshlib.InData, Data: []byte("q")}

	var res result
	select {
	case res = <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("program did not exit on q")
	}
	close(out)
	<-drainDone

	if res.rc != 0 {
		t.Fatalf("session rc = %d want 0", res.rc)
	}
	if res.m.cols != 100 || res.m.rows != 40 {
		t.Fatalf("window-change mapped to %dx%d want 100x40", res.m.cols, res.m.rows)
	}
	// The renderer may coalesce the two queued updates into one frame, so
	// the wire carries either the declared or the resized geometry — what
	// is asserted is that a real frame carries the size line at all.
	if f := frames.String(); !strings.Contains(f, "size ") ||
		!strings.Contains(f, "user=alice") {
		t.Fatalf("no rendered frame carries the session lines: %q", f)
	}
	mu.Lock()
	defer mu.Unlock()
	joined := strings.Join(logs, "\n")
	if !strings.Contains(joined, markerTUISize+"100x40") {
		t.Fatalf("missing resize marker in %q", joined)
	}
}
