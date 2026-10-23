package main

import (
	"strings"
	"testing"

	"virelai/appkit"
)

// seedDoc builds the corpus the M191a tests share: a capture ring fed a
// plain CRLF stream, seedLine repeated until it has scrolled past the
// visible fold, plus a unique token line near the tail.
func seedDoc(t *testing.T, seedLine, token string, seedRows int) *streamDoc {
	t.Helper()
	ts := &termState{}
	for i := 0; i < seedRows; i++ {
		ts.capture([]byte(seedLine + "\r\n"))
	}
	ts.capture([]byte(token + "\r\n"))
	ts.capture([]byte("tail line\r\n"))
	return scrollFindDoc(ts)
}

// TestScrollFindDocSeedsBelowTheFold is the card's own leg shape: seed
// known strings into the scrollback, find one that sits BELOW the fold
// (older than the visible grid), and prove the corpus carries it — the
// largest unindexed text surface, searchable.
func TestScrollFindDocSeedsBelowTheFold(t *testing.T) {
	doc := seedDoc(t, "filler alpha row", "needle191a token", 200)
	if len(doc.lines) < 100 {
		t.Fatalf("corpus rows = %d, want a scrolled history", len(doc.lines))
	}
	if got := countHits(doc, "needle191a"); got != 1 {
		t.Fatalf("token hits = %d want 1", got)
	}
	if got := countHits(doc, "filler alpha"); got < 100 {
		t.Fatalf("seed hits = %d want >=100", got)
	}
}

// TestScrollFindDocRespectsEscapeSemantics pins the corpus against the
// stream's control bytes: the ring holds SGR, CSI moves and OSC whole,
// and none of it may read as text.
func TestScrollFindDocRespectsEscapeSemantics(t *testing.T) {
	ts := &termState{}
	ts.capture([]byte("\x1b[31mred\x1b[0m plain\r\n"))
	ts.capture([]byte("\x1b]8;;https://x\x07linktext\x1b]8;;\x07\r\n"))
	doc := scrollFindDoc(ts)
	for _, ln := range doc.lines {
		if strings.Contains(ln, "\x1b") {
			t.Fatalf("corpus row carries escape bytes: %q", ln)
		}
	}
	if got := countHits(doc, "red plain"); got != 1 {
		t.Fatalf("'red plain' hits = %d want 1 (SGR is not text): %q",
			got, doc.lines)
	}
	if got := countHits(doc, "linktext"); got != 1 {
		t.Fatalf("'linktext' hits = %d want 1 (OSC URI is not text)", got)
	}
	if got := countHits(doc, "https"); got != 0 {
		t.Fatalf("the OSC URI leaked into the corpus as text: %q", doc.lines)
	}
}

// TestScrollFindDocAltScreenAndClear pins the two corpus-resetters: a
// ?1049 round trip must not lose the primary history, and an ED 3 (the
// hygiene chord's clear) empties the history half.
func TestScrollFindDocAltScreenAndClear(t *testing.T) {
	ts := &termState{}
	ts.capture([]byte("primary row\r\n"))
	ts.capture([]byte("\x1b[?1049h"))
	ts.capture([]byte("alt row\r\n"))
	ts.capture([]byte("\x1b[?1049l"))
	doc := scrollFindDoc(ts)
	if got := countHits(doc, "primary row"); got != 1 {
		t.Fatalf("alt round trip lost primary history: %q", doc.lines)
	}
	if got := countHits(doc, "alt row"); got != 0 {
		t.Fatalf("alt-screen content leaked into the primary corpus: %q", doc.lines)
	}
	ts.capture([]byte("\x1b[3J"))
	doc = scrollFindDoc(ts)
	if got := countHits(doc, "primary row"); got != 1 {
		t.Fatalf("ED 3 must keep the visible grid's rows: %q", doc.lines)
	}
}

// TestScrollFindDocClippedHeadLFAligns pins the clipped-ring rule: a
// clipped head may open mid-line, so the corpus LF-aligns exactly like
// save() — it must never search half a directive.
func TestScrollFindDocClippedHeadLFAligns(t *testing.T) {
	ts := &termState{}
	big := strings.Repeat("x", stateScrollMax+64)
	ts.capture([]byte(big))
	ts.capture([]byte("start of a real line\r\n"))
	ts.clipped = true
	doc := scrollFindDoc(ts)
	for _, ln := range doc.lines {
		if strings.Contains(ln, "\r") {
			t.Fatalf("corpus row still carries a CR (mid-line head): %q", ln)
		}
	}
	if got := countHits(doc, "real line"); got != 1 {
		t.Fatalf("post-clip rows = %q", doc.lines)
	}
}

// TestScrollFindDocSixelSkippedByName is the card's sixel rule: a DCS q
// payload paints image cells, never runes — its origin row is NAMED in
// doc.sixels and the payload's bytes never read as text.
func TestScrollFindDocSixelSkippedByName(t *testing.T) {
	ts := &termState{}
	ts.capture([]byte("before image\r\n"))
	ts.capture([]byte("\x1bPq#0;2;0;0;0#1~~-\x1b\\"))
	ts.capture([]byte("\r\nafter image\r\n"))
	doc := scrollFindDoc(ts)
	if len(doc.sixels) != 1 {
		t.Fatalf("sixel spans = %d want 1: %+v", len(doc.sixels), doc.sixels)
	}
	for _, ln := range doc.lines {
		if strings.ContainsAny(ln, "~~-q#") {
			t.Fatalf("sixel payload leaked as text: %q", ln)
		}
	}
	if got := countHits(doc, "after image"); got != 1 {
		t.Fatalf("rows after the image = %q", doc.lines)
	}
}

// TestCountHitsPerRow pins the matcher's rule: non-overlapping
// substrings, per row — matches never cross row boundaries.
func TestCountHitsPerRow(t *testing.T) {
	doc := &streamDoc{lines: []string{"aba ba", "xaba", "no"}}
	if got := countHits(doc, "aba"); got != 2 {
		t.Fatalf("hits = %d want 2 (non-overlapping, per row)", got)
	}
	if got := countHits(doc, ""); got != 0 {
		t.Fatalf("empty pattern = %d want 0", got)
	}
	cross := &streamDoc{lines: []string{"ab", "ba"}}
	if got := countHits(cross, "abba"); got != 0 {
		t.Fatalf("a cross-row match was counted: %d", got)
	}
}

// TestHitDocRowOrdinals pins the ordinal mapping the Step path rides:
// hits number oldest-first across rows, multiple hits per row count in
// place, and an out-of-range ordinal refuses.
func TestHitDocRowOrdinals(t *testing.T) {
	doc := &streamDoc{lines: []string{"one", "zero", "one one", ""}}
	cases := []struct{ ord, want int }{
		{0, 0}, {1, 2}, {2, 2}, {3, -1}, {-1, -1},
	}
	for _, c := range cases {
		if got := hitDocRow(doc, "one", c.ord); got != c.want {
			t.Fatalf("hitDocRow(%d) = %d want %d", c.ord, got, c.want)
		}
	}
}

// TestHitRowWindow pins the scroll-to-hit window: a Step recenters the
// content window on the hit's row, clamped to the corpus bounds.
func TestHitRowWindow(t *testing.T) {
	var lines []string
	for i := 0; i < 40; i++ {
		lines = append(lines, "hit")
	}
	doc := &streamDoc{lines: lines}
	all := hitDocRows(doc, "hit")
	if len(all) != 40 {
		t.Fatalf("hit rows = %d want 40", len(all))
	}
	// A window around hit 30 with room for 8 content rows must start at
	// 30 - 8/2 = 26 and end exclusive at 34.
	w := hitRowWindow(doc, "hit", 30, 10)
	if len(w) != 8 || w[0] != 26 || w[len(w)-1] != 33 {
		t.Fatalf("window = %v want rows 26..33", w)
	}
	// The head and tail clamp instead of under/overrunning.
	if w := hitRowWindow(doc, "hit", 0, 10); w[0] != 0 {
		t.Fatalf("head window starts at %d want 0", w[0])
	}
	if w := hitRowWindow(doc, "hit", 39, 10); w[len(w)-1] != 39 {
		t.Fatalf("tail window ends at %d want 39", w[len(w)-1])
	}
}

// TestFindPaintFace pins the ANSI face: the reverse-video bar with the
// count, the hit rows with SGR 7 marks on the current hit, and the
// sixel origin named rather than searched.
func TestFindPaintFace(t *testing.T) {
	f := appkit.NewFind()
	doc := &streamDoc{
		lines:  []string{"keep needle191a here", "plain row", "needle again"},
		sixels: []findSpan{{row: 1}},
	}
	f.Scan = func(pat string) int { return countHits(doc, pat) }
	f.SetPattern("needle191a")
	f.Recompute()
	if !f.Step(1) {
		t.Fatalf("step against a live pattern found no hit")
	}
	lay := findLayout{rows: []int{0, 1, 2}}
	b := string(findPaint(f, doc, lay, 8))
	if !strings.Contains(b, "\x1b[7m>needle191a") {
		t.Fatalf("bar face missing: %q", b)
	}
	if !strings.Contains(b, "\x1b[7mneedle191a\x1b[27m") {
		t.Fatalf("current-hit mark missing: %q", b)
	}
	if !strings.Contains(b, "[image] row") {
		t.Fatalf("sixel origin not named: %q", b)
	}
	if !strings.Contains(b, "esc=close") {
		t.Fatalf("hint line missing: %q", b)
	}
}
