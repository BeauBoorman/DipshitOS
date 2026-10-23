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

// The gocal2 list record: `gocal2 <n>` plus n `<at> <hhmm> <flags>`
// triples (d|o for daily/once, +|- for enabled/off). Round-trips
// byte-exact.
func TestAlarmListRoundTrip(t *testing.T) {
	list := []Alarm{
		{At: 1792497600, HHMM: 2359, Daily: true, Enabled: true},
		{At: 1792500000, HHMM: 645, Daily: false, Enabled: true},
		{At: 1792510000, HHMM: 1920, Daily: true, Enabled: false},
	}
	b := encodeAlarms(list)
	want := "gocal2 3 1792497600 2359 d+ 1792500000 0645 o+ 1792510000 1920 d-"
	if string(b) != want {
		t.Fatalf("encodeAlarms = %q, want %q", b, want)
	}
	got, ok := decodeAlarms(b)
	if !ok || len(got) != len(list) {
		t.Fatalf("decodeAlarms = %v,%v", got, ok)
	}
	for i := range list {
		if got[i] != list[i] {
			t.Fatalf("row %d = %+v, want %+v", i, got[i], list[i])
		}
	}
	// A trailing newline (a hand-staged or edited file) still decodes.
	if got, ok = decodeAlarms([]byte(want + "\n")); !ok || len(got) != 3 {
		t.Fatalf("decodeAlarms trailing-newline = %v,%v", got, ok)
	}
}

// gocal1 still reads: the single-record format decodes as the one daily
// enabled alarm it always was — the M144b file a v1 app last wrote.
func TestGocal1StillReads(t *testing.T) {
	got, ok := decodeAlarms([]byte("gocal1 1792497600 2359"))
	if !ok || len(got) != 1 {
		t.Fatalf("decodeAlarms gocal1 = %v,%v", got, ok)
	}
	al := got[0]
	if al.At != 1792497600 || al.HHMM != 2359 || !al.Daily || !al.Enabled {
		t.Fatalf("gocal1 decodes %+v, want armed daily 23:59", al)
	}
}

// Anything that is not exactly the gocal1 record or the gocal2 list
// refuses whole — a torn write, a foreign blob, a bad civil field or a
// count that lies are all "no state".
func TestAlarmRecordRefusals(t *testing.T) {
	for _, s := range []string{
		"", "gocal1", "gocal1 1", "gocal1 1 235",
		"gocal1 1 23590", "gocal1 x 2359", "gocal1 1 2460", "gocal1 -1 2359",
		" gocal1 1 2359", "gocal1 1 2359 extra", "gocal2",
		"gocal2 x", "gocal2 1", "gocal2 1 1 2359",
		"gocal2 1 1 2359 d+ extra", "gocal2 2 1 2359 d+",
		"gocal2 8 1 0000 d+ 1 0000 d+ 1 0000 d+ 1 0000 d+ 1 0000 d+ 1 0000 d+ 1 0000 d+ 1 0000 d+",
		"gocal2 1 x 2359 d+", "gocal2 1 1 2460 d+", "gocal2 1 -1 2359 d+",
		"gocal2 1 1 2359 dd", "gocal2 1 1 2359 dx", "gocal2 1 1 2359 x+",
		"gocal2  1 1 2359 d+", "gocal2 1  1 2359 d+",
	} {
		if _, ok := decodeAlarms([]byte(s)); ok {
			t.Fatalf("decodeAlarms(%q) = ok, want refused", s)
		}
	}
	if encodeAlarms(make([]Alarm, MaxAlarms+1)) != nil {
		t.Fatal("encodeAlarms must refuse a list past MaxAlarms")
	}
	if encodeAlarms([]Alarm{{At: -1, HHMM: 2359}}) != nil ||
		encodeAlarms([]Alarm{{At: 1, HHMM: 2460}}) != nil {
		t.Fatal("encodeAlarms must refuse a negative at or a bad HHMM")
	}
}

// --- M178c (#3146): the named-zone row ----------------------------------------

// TestWorldZonesNamedLocal: a named zone leads the row list like a fixed
// one and never collides with the curated offsets — the sentinel encoding
// keeps `z != local` honest.
func TestWorldZonesNamedLocal(t *testing.T) {
	local, ok := clockfmt.Parse("Europe/Berlin")
	if !ok {
		t.Fatal("Europe/Berlin must parse")
	}
	zones := worldZones(local)
	if zones[0] != local {
		t.Fatalf("zones[0] = %v, want the settings zone first", zones[0])
	}
	if len(zones) != len(clockfmt.Offsets)+1 {
		t.Fatalf("n = %d, want %d", len(zones), len(clockfmt.Offsets)+1)
	}
}

// TestWorldRowNamedZone: the World row is the whole clockfmt string, so a
// named row shows the instant's abbreviation and offset.
func TestWorldRowNamedZone(t *testing.T) {
	berlin, _ := clockfmt.Parse("Europe/Berlin")
	// 2026-10-20 12:00:00 UTC = epoch 1792497600; Berlin is still CEST.
	if got := worldRow(1792497600, berlin); got != "2026-10-20 14:00:00 CEST UTC+02:00" {
		t.Fatalf("worldRow Berlin = %q", got)
	}
}

// TestAlarmAtFollowsTheNamedOffset pins the alarm solve against the
// instant-dependent offset: on the 2026-10-25 fall-back day a Berlin 07:30
// rings at 06:30 UTC (CET, not CEST), and on an ordinary July day a 13:45
// rings at 11:45 UTC (CEST). Expected epochs computed with host zoneinfo.
func TestAlarmAtFollowsTheNamedOffset(t *testing.T) {
	berlin, _ := clockfmt.Parse("Europe/Berlin")
	// now = 2026-10-24 20:00:00 UTC — Berlin reads 22:00 CEST on the
	// Saturday; tomorrow's 07:30 lands past the 01:00 UTC transition in
	// CET, so the naive +86400 would ring an hour early.
	if got := alarmAt(1792872000, berlin, 7, 30); got != 1792909800 {
		t.Fatalf("alarmAt over the fall-back = %d, want 1792909800 (07:30 CET)", got)
	}
	// now = 2026-07-15 10:00:00 UTC — 12:00 CEST; today's 13:45 is ahead.
	if got := alarmAt(1784109600, berlin, 13, 45); got != 1784115900 {
		t.Fatalf("alarmAt same-day = %d, want 1784115900 (13:45 CEST)", got)
	}
	// The UTC check stays: alarmAt's old behaviour is intact on UTC —
	// now = 2026-10-20 11:30 UTC, 12:00 today is 1800 s out.
	if got := alarmAt(1792495800, clockfmt.UTC, 12, 0); got != 1792497600 {
		t.Fatalf("alarmAt UTC = %d, want 1792497600", got)
	}
}
