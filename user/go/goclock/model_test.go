package main

// model_test.go — host tests for the pure model halves: the world row
// list, the monotonic stopwatch, the bounded digit field, and the alarm's
// next-occurrence math in the settings zone's own civil day.
import (
	"testing"

	"virelai/clockfmt"
)

func TestWorldZonesLocalFirst(t *testing.T) {
	zones := worldZones(clockfmt.UTC)
	if len(zones) == 0 || zones[0] != clockfmt.UTC {
		t.Fatalf("zones[0] = %v, want the settings zone (UTC) first", zones)
	}
	// UTC is in the curated list — it must appear exactly once.
	n := 0
	for _, z := range zones {
		if z == clockfmt.UTC {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("UTC appears %d times, want 1 (settings row + no duplicate)", n)
	}
	if len(zones) != len(clockfmt.Offsets) {
		t.Fatalf("n = %d, want %d (settings + curated minus the dup)",
			len(zones), len(clockfmt.Offsets))
	}
}

func TestWorldZonesOffListLocal(t *testing.T) {
	// A hand-edited UTC+05:45 is a real zone but not in Offsets — it leads
	// and nothing is deduplicated.
	local, ok := clockfmt.Parse("UTC+05:45")
	if !ok {
		t.Fatal("UTC+05:45 must parse")
	}
	zones := worldZones(local)
	if zones[0] != local {
		t.Fatalf("zones[0] = %v, want %v", zones[0], local)
	}
	if len(zones) != len(clockfmt.Offsets)+1 {
		t.Fatalf("n = %d, want %d", len(zones), len(clockfmt.Offsets)+1)
	}
}

func TestWorldRowFormat(t *testing.T) {
	// 2026-10-20 12:00:00 UTC = epoch 1792497600.
	got := worldRow(1792497600, clockfmt.UTC)
	if got != "2026-10-20 12:00:00 UTC" {
		t.Fatalf("worldRow UTC = %q", got)
	}
	z, _ := clockfmt.Parse("UTC+01:00")
	if got := worldRow(1792497600, z); got != "2026-10-20 13:00:00 UTC+01:00" {
		t.Fatalf("worldRow +01:00 = %q", got)
	}
}

func TestStopwatch(t *testing.T) {
	var sw Stopwatch
	if sw.Running() || sw.Elapsed(5_000_000_000) != 0 {
		t.Fatal("fresh watch must read stopped zero")
	}
	sw.Toggle(1_000_000_000) // start at t=1s
	if !sw.Running() {
		t.Fatal("Toggle did not start")
	}
	if got := sw.Elapsed(4_500_000_000); got != 3_500_000_000 {
		t.Fatalf("Elapsed = %d, want 3.5s", got)
	}
	sw.Toggle(5_000_000_000) // pause at t=5s -> banked 4s
	if sw.Running() || sw.Elapsed(9_000_000_000) != 4_000_000_000 {
		t.Fatalf("paused watch reads %d, want 4s", sw.Elapsed(9_000_000_000))
	}
	sw.Toggle(10_000_000_000) // resume
	if got := sw.Elapsed(11_000_000_000); got != 5_000_000_000 {
		t.Fatalf("resumed Elapsed = %d, want 5s", got)
	}
	sw.Reset()
	if sw.Running() || sw.Elapsed(99) != 0 {
		t.Fatal("Reset must stop and zero")
	}
}

func TestFormatElapsed(t *testing.T) {
	for in, want := range map[int64]string{
		0:                                   "0:00:00",
		999_000_000:                         "0:00:00", // sub-second drops: the face is 1 Hz
		1_000_000_000:                       "0:00:01",
		61_000_000_000:                      "0:01:01",
		3_599_000_000_000:                   "0:59:59",
		3_600_000_000_000:                   "1:00:00",
		36_000_000_000_000 + 61_000_000_000: "10:01:01",
	} {
		if got := FormatElapsed(in); got != want {
			t.Fatalf("FormatElapsed(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestDigitEntry(t *testing.T) {
	e := NewDigitEntry(4)
	for _, d := range []int{0, 7, 3, 0} {
		if !e.Digit(d) {
			t.Fatalf("Digit(%d) refused", d)
		}
	}
	if e.Digit(5) {
		t.Fatal("the 5th digit must be refused — the field is bounded")
	}
	if e.Value() != 730 {
		t.Fatalf("Value = %d, want 730", e.Value())
	}
	if !e.Backspace() || e.Value() != 73 {
		t.Fatalf("Backspace leaves %d, want 73", e.Value())
	}
	e.Clear()
	if !e.Empty() || e.Backspace() {
		t.Fatal("cleared field must be empty and refuse backspace")
	}
}

func TestParseHHMM(t *testing.T) {
	for _, c := range [][4]int{
		{0, 0, 0, 1}, {730, 7, 30, 1}, {2359, 23, 59, 1},
		{2460, 0, 0, 0}, {1261, 0, 0, 0}, {9999, 0, 0, 0},
	} {
		h, m, ok := parseHHMM(c[0])
		if h != c[1] || m != c[2] || ok != (c[3] == 1) {
			t.Fatalf("parseHHMM(%d) = %d,%d,%v", c[0], h, m, ok)
		}
	}
}

// The alarm lands on the next civil h:m IN THE SETTINGS ZONE — a UTC+05:30
// alarm computes against the user's own day, not UTC's.
func TestAlarmAt(t *testing.T) {
	// 2026-10-20 12:00:00 UTC.
	now := int64(1792497600)
	if got := alarmAt(now, clockfmt.UTC, 12, 30); got != now+1800 {
		t.Fatalf("alarmAt 12:30 today = %d, want %d", got, now+1800)
	}
	if got := alarmAt(now, clockfmt.UTC, 11, 0); got != now+82800 {
		t.Fatalf("alarmAt 11:00 (past) = %d, want %d (tomorrow)", got, now+82800)
	}
	// UTC+05:30: local reads 17:30, so 18:00 is still ahead by 1800 s.
	z, _ := clockfmt.Parse("UTC+05:30")
	if got := alarmAt(now, z, 18, 0); got != now+1800 {
		t.Fatalf("alarmAt 18:00 in UTC+05:30 = %d, want %d", got, now+1800)
	}
	// And 17:00 already passed locally: the alarm lands tomorrow.
	if got := alarmAt(now, z, 17, 0); got != now+84600 {
		t.Fatalf("alarmAt 17:00 in UTC+05:30 = %d, want %d", got, now+84600)
	}
}
