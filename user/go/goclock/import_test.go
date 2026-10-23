package main

// import_test.go — host pins for the M187d (#3185) import core: the
// .ics merge produces the alarm rows, the verdict lines, and the named
// refusals the verb and the drop both print.

import (
	"strings"
	"testing"

	"virelai/clockfmt"
)

const testICS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" +
	"BEGIN:VEVENT\r\nDTSTART:20270615T143000Z\r\nDTEND:20270615T153000Z\r\nSUMMARY:Quarterly sync\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nDTSTART:20270616T090000Z\r\nSUMMARY:Daily standup\r\nRRULE:FREQ=DAILY\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20270617\r\nSUMMARY:All-day thing\r\nEND:VEVENT\r\n" +
	"END:VCALENDAR\r\n"

func TestImportIntoLandsAndRefuses(t *testing.T) {
	out := importInto(nil, []byte(testICS), 1_700_000_000, clockfmt.UTC)
	if !out.ok || out.added != 2 || out.refused != 1 {
		t.Fatalf("out=%+v", out)
	}
	if len(out.list) != 2 {
		t.Fatalf("list=%+v", out.list)
	}
	// 2027-06-15T14:30Z — UTC zone, so the row reads 14:30 once.
	a0 := out.list[0]
	if a0.At != 1813069800 || a0.HHMM != 1430 || a0.Daily || !a0.Enabled {
		t.Fatalf("row0=%+v", a0)
	}
	a1 := out.list[1]
	if a1.At != 1813136400 || a1.HHMM != 900 || !a1.Daily || !a1.Enabled {
		t.Fatalf("row1=%+v", a1)
	}
	joined := strings.Join(out.lines, "\n")
	for _, want := range []string{
		"import 14:30 once Quarterly sync",
		"import 09:00 daily Daily standup",
		"import refused all-day",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("lines missing %q:\n%s", want, joined)
		}
	}
}

func TestImportIntoMergesWithExisting(t *testing.T) {
	list := []Alarm{{At: 1813069800, HHMM: 1430, Daily: false, Enabled: true}}
	out := importInto(list, []byte(testICS), 1_700_000_000, clockfmt.UTC)
	if !out.ok || out.added != 1 || out.refused != 2 { // dup + all-day
		t.Fatalf("out=%+v", out)
	}
	if len(out.list) != 2 || out.list[0] != list[0] {
		t.Fatalf("list=%+v", out.list)
	}
	if !strings.Contains(strings.Join(out.lines, "\n"), "import refused dup") {
		t.Fatalf("lines=%v", out.lines)
	}
}

func TestImportIntoHonoursTheCap(t *testing.T) {
	list := make([]Alarm, MaxAlarms)
	out := importInto(list, []byte(testICS), 1_700_000_000, clockfmt.UTC)
	if !out.ok || out.added != 0 || out.refused != 3 || len(out.list) != MaxAlarms {
		t.Fatalf("out=%+v", out)
	}
	if n := strings.Count(strings.Join(out.lines, "\n"), "import refused full"); n != 2 {
		t.Fatalf("full refusals=%d lines=%v", n, out.lines)
	}
}

func TestImportIntoTruncationCounts(t *testing.T) {
	var b strings.Builder
	b.WriteString("BEGIN:VCALENDAR\r\n")
	for i := 0; i < 10; i++ {
		b.WriteString("BEGIN:VEVENT\r\nDTSTART:20270615T143000Z\r\nSUMMARY:e\r\nEND:VEVENT\r\n")
	}
	b.WriteString("END:VCALENDAR\r\n")
	out := importInto(nil, []byte(b.String()), 1_700_000_000, clockfmt.UTC)
	// 10 identical events: the parse bound honours the first MaxEvents,
	// one of those lands and its twins dup-refuse; the tail counts as
	// one truncated line.
	if !out.ok || out.added+out.refused == 0 {
		t.Fatalf("out=%+v", out)
	}
	if !strings.Contains(strings.Join(out.lines, "\n"), "import truncated n=") {
		t.Fatalf("no truncated line in %v", out.lines)
	}
}

func TestImportArgShapes(t *testing.T) {
	// importArg reads vi.Args, which is nil on the host — the shape is
	// pinned through isICS-style calls instead.
	if _, ok := importArg(); ok {
		t.Fatal("host argv claimed an import")
	}
}
