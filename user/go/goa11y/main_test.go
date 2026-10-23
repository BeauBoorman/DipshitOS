package main

import (
	"errors"
	"testing"

	"virelai/appkit"
	"virelai/vi"
)

// stub seams — the guest syscalls are replaced wholesale, the same way
// wmquery's own host tests drive the mailbox.
type stubs struct {
	rows    []vi.WmWindowRow
	err     error
	files   map[string][]byte
	console []string
}

func (s *stubs) install(t *testing.T) {
	t.Helper()
	savedW, savedR, savedC := wmWindows, readFile, console
	wmWindows = func(uint32, string) ([]vi.WmWindowRow, error) {
		return s.rows, s.err
	}
	readFile = func(path string, _ int) ([]byte, int64) {
		if b, ok := s.files[path]; ok {
			return b, int64(len(b))
		}
		return nil, -vi.ErrENOENT
	}
	console = func(line string) { s.console = append(s.console, line) }
	t.Cleanup(func() {
		wmWindows, readFile, console = savedW, savedR, savedC
	})
}

func TestNodeLineGrammar(t *testing.T) {
	line := nodeLine(3, appkit.Node{
		Role:  appkit.RoleMenuItem,
		State: appkit.StateFocused | appkit.StateSelected,
		Name:  "Open…",
	})
	if line != "goa11y: node 3 menuitem fs Open…" {
		t.Fatalf("node line = %q", line)
	}
}

func TestPollStatesAndDedup(t *testing.T) {
	var s stubs
	s.install(t)
	a := &app{self: 9}

	// Query failure is a named state.
	s.err = errors.New("seat silent")
	if !a.poll() || a.state != viewQueryFail {
		t.Fatalf("query-fail poll state=%d", a.state)
	}
	if s.console[len(s.console)-1] != "goa11y: query refused" {
		t.Fatalf("console = %v", s.console)
	}

	// Answered query with no focused row.
	s.err = nil
	s.rows = []vi.WmWindowRow{{ID: 4}, {ID: 5}}
	if !a.poll() || a.state != viewNoFocus {
		t.Fatalf("no-focus poll state=%d", a.state)
	}

	// Focused window, no published outline.
	s.rows[1].Focused = true
	if !a.poll() || a.state != viewNoOutline || a.win != 5 {
		t.Fatalf("no-outline poll state=%d win=%d", a.state, a.win)
	}
	if s.console[len(s.console)-1] != "goa11y: no outline win=5" {
		t.Fatalf("console = %v", s.console)
	}
	// Same state again: the poll must stay silent.
	if a.poll() {
		t.Fatal("identical no-outline reported twice")
	}

	// A malformed file is a named state, not a decode.
	s.files = map[string][]byte{"/host/A11Y.5": []byte("junk\n")}
	if !a.poll() || a.state != viewBadOutline {
		t.Fatalf("bad-outline poll state=%d", a.state)
	}
	if s.console[len(s.console)-1] != "goa11y: bad outline win=5" {
		t.Fatalf("console = %v", s.console)
	}

	// The real outline: markers carry the node set.
	body := appkit.EncodeOutline([]appkit.Node{
		{Depth: 0, Role: appkit.RoleWindow, Name: "Dialog"},
		{Depth: 1, Role: appkit.RoleTree, Name: "Tree"},
		{Depth: 2, Role: appkit.RoleTreeItem,
			State: appkit.StateFocused | appkit.StateSelected, Name: "kernel"},
	})
	s.files["/host/A11Y.5"] = body
	if !a.poll() || a.state != viewOutline || len(a.nodes) != 3 {
		t.Fatalf("outline poll state=%d nodes=%d", a.state, len(a.nodes))
	}
	want := "goa11y: focus win=5 nodes=3"
	if s.console[len(s.console)-4] != want {
		t.Fatalf("console tail = %v", s.console[len(s.console)-4:])
	}
	if s.console[len(s.console)-1] != "goa11y: node 2 treeitem fs kernel" {
		t.Fatalf("last node line = %q", s.console[len(s.console)-1])
	}
	// Identical body again: silent.
	n := len(s.console)
	if a.poll() || len(s.console) != n {
		t.Fatal("identical outline re-reported")
	}
	// Same window, changed bytes: reported again.
	body2 := appkit.EncodeOutline([]appkit.Node{
		{Depth: 0, Role: appkit.RoleWindow, Name: "Dialog"},
		{Depth: 1, Role: appkit.RoleTable, Name: "Table"},
		{Depth: 2, Role: appkit.RoleRow,
			State: appkit.StateFocused | appkit.StateSelected, Name: "row 3 of 64"},
	})
	s.files["/host/A11Y.5"] = body2
	if !a.poll() || len(s.console) != n+4 {
		t.Fatalf("changed outline re-report failed: %v", s.console[n:])
	}
}

func TestFocusedWin(t *testing.T) {
	var s stubs
	s.install(t)
	s.err = errors.New("silent")
	if _, st, ok := focusedWin(1, appName); ok || st != viewQueryFail {
		t.Fatalf("silent query = %v %v", st, ok)
	}
	s.err = nil
	s.rows = []vi.WmWindowRow{{ID: 2}, {ID: 7, Focused: true}}
	if win, _, ok := focusedWin(1, appName); !ok || win != 7 {
		t.Fatalf("focused row = %d %v", win, ok)
	}
}
