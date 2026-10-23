package appkit

import (
	"testing"

	"virelai/widgets"
)

// findCorpus is the test corpus seam: a fixed hit count, recording what the
// overlay shows and scans.
type findCorpus struct {
	text   string // what Scan pretends to walk
	scans  int    // how often Scan ran
	shows  []int  // the ordinals the overlay asked the app to make current
	misses int    // Step-against-no-hits count
	linked bool
}

func (c *findCorpus) scan(pat string) int {
	c.scans++
	// A dumb byte-substring count over c.text — the same rule the real
	// seams run through virelai/find.
	n := 0
	for i := 0; i+len(pat) <= len(c.text); i++ {
		if c.text[i:i+len(pat)] == pat {
			n++
			i += len(pat) - 1
		}
	}
	return n
}

func (c *findCorpus) show(i int) { c.shows = append(c.shows, i) }
func (c *findCorpus) miss()      { c.misses++ }

func newFind(c *findCorpus) *Find {
	f := NewFind()
	f.Scan = c.scan
	f.Show = c.show
	f.Miss = c.miss
	return &f
}

func findRune(f *Find, r rune) { f.OnKey(Key{Rune: r}) }

func TestFindOpensScansAndTypes(t *testing.T) {
	c := &findCorpus{text: "one two one"}
	f := newFind(c)
	f.Present()
	if !f.Open || f.Cur != -1 {
		t.Fatalf("open state: open=%v cur=%d", f.Open, f.Cur)
	}
	for _, r := range "one" {
		findRune(f, r)
	}
	if f.Total != 2 || c.scans == 0 {
		t.Fatalf("incremental scan: total=%d scans=%d", f.Total, c.scans)
	}
	if f.countText() != "0/2" {
		t.Fatalf("count before stepping = %q", f.countText())
	}
}

func TestFindStepsAndWraps(t *testing.T) {
	c := &findCorpus{text: "one two one"}
	f := newFind(c)
	f.Present()
	for _, r := range "one" {
		findRune(f, r)
	}
	f.OnKey(Key{Usage: 0x28}) // Enter
	f.OnKey(Key{Usage: 0x28})
	f.OnKey(Key{Usage: 0x28}) // wraps to the first hit
	if len(c.shows) != 3 || c.shows[0] != 0 || c.shows[1] != 1 || c.shows[2] != 0 {
		t.Fatalf("shows=%v, want 0,1,0", c.shows)
	}
	if f.Cur != 0 || f.countText() != "1/2" {
		t.Fatalf("cur=%d count=%q", f.Cur, f.countText())
	}
	// Shift-Enter steps back; from the first hit it wraps to the last.
	f.OnKey(Key{Usage: 0x28, Shift: true})
	if got := c.shows[len(c.shows)-1]; got != 1 || f.countText() != "2/2" {
		t.Fatalf("shift-enter: shows=%v count=%q", c.shows, f.countText())
	}
}

func TestFindFirstStepBackLandsOnLastHit(t *testing.T) {
	c := &findCorpus{text: "one two one"}
	f := newFind(c)
	f.Present()
	for _, r := range "one" {
		findRune(f, r)
	}
	f.OnKey(Key{Usage: 0x28, Shift: true})
	if len(c.shows) != 1 || c.shows[0] != 1 {
		t.Fatalf("shows=%v, want [1] (step-back lands on the last hit)", c.shows)
	}
}

func TestFindEditResetsTheCurrentHit(t *testing.T) {
	c := &findCorpus{text: "one two one"}
	f := newFind(c)
	f.Present()
	for _, r := range "one" {
		findRune(f, r)
	}
	f.OnKey(Key{Usage: 0x28})
	f.OnKey(Key{Usage: 0x2a}) // Backspace: pattern "on" — substring of "one"
	if f.Cur != -1 || f.Total != 2 {
		t.Fatalf("after edit cur=%d total=%d, want -1/2", f.Cur, f.Total)
	}
	f.OnKey(Key{Usage: 0x28})
	if got := c.shows[len(c.shows)-1]; got != 0 {
		t.Fatalf("step after edit landed %d, want the first hit", got)
	}
}

func TestFindMissReportsAndClearsCur(t *testing.T) {
	c := &findCorpus{text: "one two one"}
	f := newFind(c)
	f.Present()
	for _, r := range "one" {
		findRune(f, r)
	}
	f.OnKey(Key{Usage: 0x28})
	for _, r := range "xyz" {
		findRune(f, r)
	}
	f.OnKey(Key{Usage: 0x28})
	if c.misses != 1 || f.Cur != -1 {
		t.Fatalf("miss: misses=%d cur=%d", c.misses, f.Cur)
	}
	if f.countText() != "0" {
		t.Fatalf("miss count = %q", f.countText())
	}
}

func TestFindEscapeDismissesAndPatternSurvives(t *testing.T) {
	c := &findCorpus{text: "one two one"}
	f := newFind(c)
	f.Present()
	for _, r := range "one" {
		findRune(f, r)
	}
	f.OnKey(Key{Usage: 0x28})
	f.OnKey(Key{Usage: 0x29}) // Escape
	if f.Open || f.Pattern() != "one" {
		t.Fatalf("dismiss: open=%v pat=%q", f.Open, f.Pattern())
	}
	// Reopening keeps the pattern AND the cycle position — the repeat-find
	// muscle memory: Enter steps from where the search left off.
	f.Present()
	f.OnKey(Key{Usage: 0x28})
	if got := c.shows[len(c.shows)-1]; got != 1 {
		t.Fatalf("reopen step landed %d, want the second hit", got)
	}
}

func TestFindEmptyPatternNeverScans(t *testing.T) {
	c := &findCorpus{text: "one two one"}
	f := newFind(c)
	f.Present()
	f.OnKey(Key{Usage: 0x28})
	if c.scans != 0 || c.misses != 0 {
		t.Fatalf("empty pattern scanned %d times and missed %d", c.scans, c.misses)
	}
}

func TestFindSwallowsClicksOnlyInsideTheBar(t *testing.T) {
	c := &findCorpus{}
	f := newFind(c)
	f.R = widgets.Rect{Y: 100, W: 200, H: 14}
	f.Present()
	if !f.OnClick(10, 105) {
		t.Fatal("a click inside the bar is consumed")
	}
	if f.OnClick(10, 50) {
		t.Fatal("a click outside the bar must not be swallowed")
	}
}
