package main

import "testing"

// REVIEW-LOW L8 (#3057): the overlay's first CSI reader matched the
// parameter byte as the sequence final, so ESC [ 5 ~ / ESC [ 6 ~ never
// produced a scroll — PgUp/PgDn were dead keys.
func TestHintsCSI(t *testing.T) {
	cases := []struct {
		in   string
		act  int
		used int
	}{
		{"\x1b[A", hintsUp, 3},
		{"\x1b[B", hintsDown, 3},
		{"\x1b[H", hintsTop, 3},
		{"\x1b[F", hintsBottom, 3},
		{"\x1b[5~", hintsPageUp, 4},
		{"\x1b[6~", hintsPageDown, 4},
		{"\x1b[5~x", hintsPageUp, 4}, // trailing byte unconsumed
		{"\x1b[5", hintsNone, 0},     // truncated: no final yet
		{"\x1b[9~", hintsNone, 0},    // unknown parameter
		{"\x1b[Z", hintsNone, 0},     // shift-tab is not a scroll key
		{"abc", hintsNone, 0},
		{"\x1bA", hintsNone, 0},
	}
	for _, c := range cases {
		act, used := hintsCSI([]byte(c.in))
		if act != c.act || used != c.used {
			t.Fatalf("hintsCSI(%q) = (%d,%d), want (%d,%d)", c.in, act, used, c.act, c.used)
		}
	}
}
