package ical

// ical_test.go — host pins for the M187d (#3185) VCALENDAR bound: the
// honoured shapes land as events with their civil fields resolved to
// Wall seconds, and every refused shape names its why.

import (
	"strings"
	"testing"
)

func cal(body string) string {
	return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//t//EN\r\n" +
		body + "END:VCALENDAR\r\n"
}

func evt(body string) string {
	return "BEGIN:VEVENT\r\n" + body + "END:VEVENT\r\n"
}

func TestParseTimedZEvent(t *testing.T) {
	r, ok := Parse([]byte(cal(evt(
		"UID:a@b\r\nDTSTAMP:20261022T120000Z\r\n" +
			"DTSTART:20270615T143000Z\r\n" +
			"DTEND:20270615T153000Z\r\n" +
			"SUMMARY:Quarterly sync\r\n"))))
	if !ok || r.Total != 1 || len(r.Events) != 1 || len(r.Refusals) != 0 {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
	ev := r.Events[0]
	if ev.Summary != "Quarterly sync" || !ev.Start.UTC || !ev.HasEnd {
		t.Fatalf("event=%+v", ev)
	}
	// 2027-06-15 14:30:00 UTC — the epoch the alarm's At carries.
	want := int64(1813069800)
	if ev.Start.Wall != want {
		t.Fatalf("start wall=%d want %d", ev.Start.Wall, want)
	}
	if ev.End.Wall != want+3600 {
		t.Fatalf("end wall=%d want %d", ev.End.Wall, want+3600)
	}
}

func TestParseFloatingAndDaily(t *testing.T) {
	r, ok := Parse([]byte(cal(evt(
		"DTSTART:20270616T090000\r\n" +
			"SUMMARY:Daily standup\r\n" +
			"RRULE:FREQ=DAILY\r\n"))))
	if !ok || len(r.Events) != 1 {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
	ev := r.Events[0]
	if ev.Start.UTC || !ev.Daily || ev.HasEnd {
		t.Fatalf("event=%+v", ev)
	}
	// Floating: Wall is the civil reading; the importer's zone resolves it.
	if ev.Start.Wall != int64(1813136400) {
		t.Fatalf("floating wall=%d", ev.Start.Wall)
	}
}

func TestRefusalsAreNamed(t *testing.T) {
	cases := []struct {
		name, body, why string
	}{
		{"value-date", "DTSTART;VALUE=DATE:20270617\r\nSUMMARY:x\r\n", "all-day"},
		{"bare-date", "DTSTART:20270617\r\nSUMMARY:x\r\n", "all-day"},
		{"tzid", "DTSTART;TZID=America/New_York:20270617T090000\r\n", "dtstart-tzid"},
		{"weekly", "DTSTART:20270618T100000Z\r\nRRULE:FREQ=WEEKLY\r\n", "rrule"},
		{"byday", "DTSTART:20270618T100000Z\r\nRRULE:FREQ=DAILY;BYDAY=MO\r\n", "rrule"},
		{"bad-stamp", "DTSTART:tomorrow\r\n", "dtstart"},
		{"no-dtstart", "SUMMARY:orphan\r\n", "dtstart"},
	}
	for _, c := range cases {
		r, ok := Parse([]byte(cal(evt(c.body))))
		if !ok || r.Total != 1 {
			t.Fatalf("%s: r=%+v ok=%v", c.name, r, ok)
		}
		if len(r.Events) != 0 || len(r.Refusals) != 1 || r.Refusals[0].Why != c.why {
			t.Fatalf("%s: events=%d refusals=%+v want why=%s",
				c.name, len(r.Events), r.Refusals, c.why)
		}
	}
}

func TestMixedFileHonoursPrefix(t *testing.T) {
	r, ok := Parse([]byte(cal(
		evt("DTSTART:20270615T143000Z\r\nSUMMARY:one\r\n") +
			evt("DTSTART;VALUE=DATE:20270617\r\nSUMMARY:allday\r\n") +
			evt("DTSTART:20270616T090000Z\r\nSUMMARY:two\r\nRRULE:FREQ=DAILY\r\n"))))
	if !ok || r.Total != 3 {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
	if len(r.Events) != 2 || len(r.Refusals) != 1 || r.Refusals[0].Why != "all-day" {
		t.Fatalf("events=%d refusals=%+v", len(r.Events), r.Refusals)
	}
	if r.Events[0].Summary != "one" || r.Events[1].Summary != "two" || !r.Events[1].Daily {
		t.Fatalf("events=%+v", r.Events)
	}
}

func TestFoldedSummary(t *testing.T) {
	r, ok := Parse([]byte(cal(evt(
		"DTSTART:20270615T143000Z\r\n" +
			"SUMMARY:A very long summary that an exporter fold\r\n" +
			" ed at the seventy-five column bound\r\n"))))
	if !ok || len(r.Events) != 1 {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
	if got := r.Events[0].Summary; !strings.Contains(got, "folded at") {
		t.Fatalf("summary=%q", got)
	}
}

func TestSummaryEscapes(t *testing.T) {
	r, ok := Parse([]byte(cal(evt(
		"DTSTART:20270615T143000Z\r\n" +
			"SUMMARY:Dentist\\, 3rd floor\\; bring card\\nnotes\r\n"))))
	if !ok || len(r.Events) != 1 {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
	if got, want := r.Events[0].Summary,
		"Dentist, 3rd floor; bring card notes"; got != want {
		t.Fatalf("summary=%q want %q", got, want)
	}
}

func TestNestedValarmDoesNotCloseEvent(t *testing.T) {
	r, ok := Parse([]byte(cal(evt(
		"DTSTART:20270615T143000Z\r\n" +
			"SUMMARY:with alarm\r\n" +
			"BEGIN:VALARM\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n" +
			"DTEND:20270615T150000Z\r\n"))))
	if !ok || len(r.Events) != 1 || !r.Events[0].HasEnd {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
}

func TestTruncationCounted(t *testing.T) {
	var b strings.Builder
	b.WriteString("BEGIN:VCALENDAR\r\n")
	for i := 0; i < MaxEvents+3; i++ {
		b.WriteString(evt("DTSTART:20270615T143000Z\r\nSUMMARY:e\r\n"))
	}
	b.WriteString("END:VCALENDAR\r\n")
	r, ok := Parse([]byte(b.String()))
	if !ok || r.Total != MaxEvents+3 || len(r.Events) != MaxEvents {
		t.Fatalf("r=%+v ok=%v", r, ok)
	}
}

func TestNotVCalendar(t *testing.T) {
	if _, ok := Parse([]byte("hello world\n")); ok {
		t.Fatal("plain text parsed as vcalendar")
	}
	if _, ok := Parse([]byte(cal(""))); ok {
		t.Fatal("empty vcalendar parsed")
	}
}
