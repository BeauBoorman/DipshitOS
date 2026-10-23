// Package ical is M187d (#3185): the smallest honest VCALENDAR reader —
// the half of an .ics file that can become a GOCLOCK row.
//
// The bound is the card's: BEGIN:VCALENDAR wrapping BEGIN:VEVENT blocks,
// and inside each VEVENT only DTSTART, DTEND, SUMMARY and a TRIVIAL RRULE
// (exactly FREQ=DAILY — the alarm list's repeater). Everything else an
// exporter writes — VTIMEZONE, VALARM, ATTENDEE, folded descriptions —
// is skipped by shape, never half-parsed. What the bound cannot honour
// is a named refusal, not a guess:
//
//	dtstart-tzid   DTSTART;TZID=… — zone rules live in VTIMEZONE blocks
//	               this package does not read; guessing at one is lying.
//	all-day        DTSTART;VALUE=DATE (or a bare YYYYMMDD) — an alarm
//	               has an instant, a date has none.
//	rrule          RRULE beyond FREQ=DAILY (weekly, monthly, BYDAY,
//	               COUNT, INTERVAL>1) — the store re-arms at 86400 s or
//	               not at all.
//	dtstart        a malformed or missing start stamp.
//
// Stamps carry Wall: the naive civil reading expressed as if UTC — for a
// `…Z` value it IS the epoch; for a floating value the importer resolves
// it against the user's zone (GOCLOCK's localEpoch). The package never
// picks a zone itself, so host tests pin the parse with no clock.
package ical

import "strings"

// MaxEvents bounds one import: a longer file is first-N — the tail is
// counted and named, never parsed halfway.
const MaxEvents = 8

// Stamp is one parsed date-time. Wall is the civil fields read as UTC
// seconds (daysFromCivil · 86400 + h·3600 + m·60 + s). UTC reports the
// trailing Z: when set, Wall is the epoch; when clear the stamp is
// floating and the caller's zone resolves it.
type Stamp struct {
	Wall int64
	UTC  bool
}

// Event is one honoured VEVENT.
type Event struct {
	Summary string
	Start   Stamp
	End     Stamp
	HasEnd  bool
	Daily   bool // RRULE:FREQ=DAILY — the only recurrence the store speaks
}

// Refusal names one VEVENT the bound could not honour.
type Refusal struct {
	Why string // "all-day", "dtstart-tzid", "rrule", "dtstart"
}

// Result is the whole parse: the honoured prefix, the named skips, and
// the tail count. Total is every VEVENT seen; Events is the honoured
// prefix of at most MaxEvents; Refusals is the skipped middle.
type Result struct {
	Events   []Event
	Refusals []Refusal
	Total    int
}

// Parse decodes b as a VCALENDAR. ok=false means the bytes are not a
// vcalendar at all (no BEGIN:VCALENDAR, or no VEVENT inside) — the
// caller's refusal is on the file, not an event.
func Parse(b []byte) (Result, bool) {
	var r Result
	inCal, inEvt, depth := false, false, 0
	var cur *Event
	var refused bool
	for _, ln := range lines(b) {
		name, params, value := prop(ln)
		switch name {
		case "BEGIN":
			switch strings.ToUpper(value) {
			case "VCALENDAR":
				inCal = true
			case "VEVENT":
				if !inCal {
					continue
				}
				r.Total++
				if len(r.Events)+len(r.Refusals) >= MaxEvents {
					cur = nil
					continue
				}
				cur = &Event{}
				refused = false
				inEvt = true
				depth = 1
			default:
				// A nested component (VALARM, VTIMEZONE): tracked only so
				// its END does not close the VEVENT.
				if inEvt {
					depth++
				}
			}
		case "END":
			switch strings.ToUpper(value) {
			case "VEVENT":
				if inEvt && cur != nil {
					if refused {
						cur = nil
					} else if !cur.Start.UTC && cur.Start.Wall == 0 {
						// no DTSTART survived the stamps
						r.Refusals = append(r.Refusals, Refusal{Why: "dtstart"})
					} else {
						r.Events = append(r.Events, *cur)
					}
				}
				cur = nil
				inEvt = false
				depth = 0
			case "VCALENDAR":
				inCal = false
			default:
				if inEvt && depth > 1 {
					depth--
				}
			}
		default:
			if !inEvt || cur == nil || depth != 1 {
				continue
			}
			if !parseProp(cur, name, params, value) {
				refused = true
				r.Refusals = append(r.Refusals, refusalOf(name, params, value))
				cur = nil
				inEvt = false
				depth = 0
			}
		}
	}
	return r, r.Total > 0
}

// parseProp folds one VEVENT property into ev; false when the property
// names a refusal (the event is un-importable by shape).
func parseProp(ev *Event, name, params, value string) bool {
	switch name {
	case "DTSTART":
		st, why := stamp(params, value)
		if why != "" {
			return false
		}
		ev.Start = st
	case "DTEND":
		st, why := stamp(params, value)
		if why != "" {
			return false
		}
		ev.End, ev.HasEnd = st, true
	case "SUMMARY":
		ev.Summary = unescape(value)
	case "RRULE":
		if !strings.EqualFold(strings.TrimSpace(value), "FREQ=DAILY") {
			return false
		}
		ev.Daily = true
	}
	return true
}

// refusalOf names the why for a rejected property — the reason is the
// property's own shape, so the marker can say WHAT was refused.
func refusalOf(name, params, value string) Refusal {
	why := "dtstart"
	switch name {
	case "DTSTART", "DTEND":
		_, why = stamp(params, value)
	case "RRULE":
		why = "rrule"
	}
	return Refusal{Why: why}
}

// stamp parses a DTSTART/DTEND parameter+value pair. The refused shapes
// name themselves: a TZID parameter is "dtstart-tzid", a VALUE=DATE or
// bare date is "all-day", anything unparsable is "dtstart".
func stamp(params, value string) (Stamp, string) {
	for _, p := range strings.Split(params, ";") {
		k, v, _ := strings.Cut(p, "=")
		switch strings.ToUpper(k) {
		case "":
		case "TZID":
			return Stamp{}, "dtstart-tzid"
		case "VALUE":
			if strings.ToUpper(v) == "DATE" {
				return Stamp{}, "all-day"
			}
		}
	}
	v := strings.TrimSpace(value)
	var st Stamp
	if strings.HasSuffix(v, "Z") || strings.HasSuffix(v, "z") {
		st.UTC = true
		v = v[:len(v)-1]
	}
	// YYYYMMDDTHHMMSS — the T separator is required; a bare YYYYMMDD is
	// the all-day shape even without the VALUE=DATE spelling.
	if len(v) != 15 || v[8] != 'T' {
		if len(v) == 8 && digits(v) {
			return Stamp{}, "all-day"
		}
		return Stamp{}, "dtstart"
	}
	y, ok1 := ndigits(v[0:4], 4)
	mo, ok2 := ndigits(v[4:6], 2)
	d, ok3 := ndigits(v[6:8], 2)
	h, ok4 := ndigits(v[9:11], 2)
	mi, ok5 := ndigits(v[11:13], 2)
	s, ok6 := ndigits(v[13:15], 2)
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 ||
		mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo) ||
		h > 23 || mi > 59 || s > 60 {
		return Stamp{}, "dtstart"
	}
	st.Wall = daysFromCivil(y, mo, d)*86400 + int64(h)*3600 + int64(mi)*60 + int64(s)
	return st, ""
}

// lines unfolds the content line stream: CRLF or LF breaks, and a line
// opening with SP or TAB is a fold of the previous one (RFC 5545 §3.1 —
// the marker's event can never be severed by an exporter's 75-col wrap).
func lines(b []byte) []string {
	raw := strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
	out := make([]string, 0, len(raw))
	for _, ln := range raw {
		ln = strings.TrimSuffix(ln, "\r")
		if len(ln) > 0 && (ln[0] == ' ' || ln[0] == '\t') && len(out) > 0 {
			out[len(out)-1] += ln[1:]
			continue
		}
		out = append(out, ln)
	}
	return out
}

// prop splits `NAME;P=V;P2=V2:value` — params arrive as the raw
// `P=V;P2=V2` middle ("" when absent); a property with no colon is not a
// property and parses as name-only noise the switch ignores.
func prop(ln string) (name, params, value string) {
	head, value, _ := strings.Cut(ln, ":")
	if i := strings.IndexByte(head, ';'); i >= 0 {
		return strings.ToUpper(head[:i]), head[i+1:], value
	}
	return strings.ToUpper(head), "", value
}

// unescape resolves the RFC 5545 text escapes the card fields carry:
// \, \; \n \N (a literal newline reads as one space — the marker line
// and the face row are single-line surfaces). An unknown escape keeps
// the escaped byte, the honest read.
func unescape(s string) string {
	if !strings.ContainsRune(s, '\\') {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			i++
			switch s[i] {
			case 'n', 'N':
				b.WriteByte(' ')
			default:
				b.WriteByte(s[i])
			}
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func digits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return len(s) > 0
}

func ndigits(s string, n int) (int, bool) {
	if len(s) != n || !digits(s) {
		return 0, false
	}
	v := 0
	for i := 0; i < n; i++ {
		v = v*10 + int(s[i]-'0')
	}
	return v, true
}

func daysInMonth(y, m int) int {
	switch m {
	case 4, 6, 9, 11:
		return 30
	case 2:
		if (y%4 == 0 && y%100 != 0) || y%400 == 0 {
			return 29
		}
		return 28
	}
	return 31
}

// daysFromCivil is Hinnant's era-shifted algorithm, run forward: the
// proleptic-Gregorian y/m/d as days since 1970-01-01 — clockfmt's own
// math, kept local so the package stays clockfmt-free.
func daysFromCivil(y, m, d int) int64 {
	if m <= 2 {
		y--
	}
	era := floorDiv(int64(y), 400)
	yoe := int64(y) - era*400
	mp := m - 3
	if mp < 0 {
		mp += 12
	}
	doy := (153*int64(mp)+2)/5 + int64(d-1)
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

func floorDiv(a, b int64) int64 {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}
