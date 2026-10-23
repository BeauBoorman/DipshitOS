package main

// M161b (#2974): the argv split is the fixture's whole surface — pin the
// mode selection so the gate's `wedge 5` / `idle` can never drift into
// the panic path.

import "testing"

func TestCrashfixMode(t *testing.T) {
	cases := []struct {
		args     []string
		mode     string
		secs     int64
	}{
		{[]string{"CRASHFIX.ELF"}, "panic", 0},
		{[]string{"CRASHFIX.ELF", "other"}, "panic", 0},
		{[]string{"CRASHFIX.ELF", "wedge", "5"}, "wedge", 5},
		{[]string{"CRASHFIX.ELF", "wedge"}, "wedge", 0},
		{[]string{"CRASHFIX.ELF", "wedge", "abc"}, "wedge", 0},
		{[]string{"CRASHFIX.ELF", "wedge", "-3"}, "wedge", 0},
		{[]string{"CRASHFIX.ELF", "idle"}, "idle", 0},
		{[]string{"CRASHFIX.ELF", "idle", "9"}, "idle", 0},
	}
	for _, c := range cases {
		mode, secs := crashfixMode(c.args)
		if mode != c.mode || secs != c.secs {
			t.Fatalf("args %v -> %s %d, want %s %d", c.args, mode, secs, c.mode, c.secs)
		}
	}
}
