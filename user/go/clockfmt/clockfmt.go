// Package clockfmt is M83c (#1776): the one place that answers "what time is
// it HERE" for every Go consumer — GOSH's `date`, GOSET, and the apps. It
// owns the zone vocabulary and the shared local formatter; the `timezone`
// settings row stores one of its labels.
//
// M178c (#3146): a zone is a fixed UTC offset OR one of the curated IANA
// names in zones.go (generated from a pinned tzdata release by
// tools/tz/gen-zones.py). Fixed offsets behave exactly as before — the
// label IS the offset, and a hand-edited `UTC+05:45` is a real fixed offset
// that formats correctly. A named zone carries its current POSIX-TZ rule
// and resolves its offset at the formatted instant, so a `Europe/Berlin`
// row follows DST. History before each zone's current rule is not carried
// (named limitation, D8).
//
// This package is pure: no vi, no syscalls, no stdlib time — the civil
// breakdown is done here so the conversion math is host-testable on its own.
package clockfmt

// Zone is a fixed offset from UTC in seconds east, or a named IANA zone
// (ianaBase + the zone's index in ianaZones). UTC is the zero zone. The
// integer shape is load-bearing: callers assign untyped constants
// (`return 5*3600 + 30*60`) and compare zones with !=, so a named zone
// encodes in-band rather than as a struct.
type Zone int32

// UTC is the zero offset and the fallback for every value that fails to
// parse: an invalid persisted row must never shift every clock silently.
const UTC Zone = 0

// Offsets is the curated cycle list GOSET offers (Left/Right on the
// `timezone` row). Order is west to east; the labels are the stored values.
var Offsets = []Zone{
	-8 * 3600, // UTC-08:00 — US Pacific standard
	-5 * 3600, // UTC-05:00 — US Eastern standard
	-3 * 3600, // UTC-03:00
	0, //         UTC
	1 * 3600, //  UTC+01:00 — Central Europe standard
	2 * 3600, //  UTC+02:00 — Eastern Europe standard
	3 * 3600, //  UTC+03:00
	5*3600 + 30*60, // UTC+05:30 — India
	8 * 3600, //  UTC+08:00
	9 * 3600, //  UTC+09:00
	10 * 3600, // UTC+10:00
	12 * 3600, // UTC+12:00
}

// maxOffset is the widest fixed offset any real zone uses (Kiribati is
// +14:00); anything wider is a typo, not a zone.
const maxOffset = 14 * 3600

// Label renders the canonical stored spelling of z: `UTC` at zero, the
// `UTC+HH:MM` / `UTC-HH:MM` shape for a nonzero fixed offset, and the IANA
// name for a named zone — the exact string the settings row persists, so
// Parse(Label(z)) round-trips.
func Label(z Zone) string {
	if isNamed(z) {
		return named(z).name
	}
	if z == 0 {
		return "UTC"
	}
	off := int(z)
	sign := byte('+')
	if off < 0 {
		sign = '-'
		off = -off
	}
	b := [9]byte{'U', 'T', 'C', sign, '0', '0', ':', '0', '0'}
	b[4] += byte(off / 3600 / 10)
	b[5] += byte(off / 3600 % 10)
	b[7] += byte(off / 60 % 60 / 10)
	b[8] += byte(off / 60 % 60 % 10)
	return string(b[:])
}

// Names returns the curated labels, the vocabulary a `timezone` row cycles.
func Names() []string {
	out := make([]string, 0, len(Offsets))
	for _, z := range Offsets {
		out = append(out, Label(z))
	}
	return out
}

// Parse resolves a stored timezone value to its zone. It accepts `UTC`, the
// canonical `UTC±HH:MM` shape (zero-padded, |offset| <= 14:00), and the
// curated IANA names; every other spelling fails. `UTC+00:00` is the zero
// zone, labelled `UTC`.
func Parse(name string) (Zone, bool) {
	if name == "UTC" {
		return UTC, true
	}
	if i := namedIndex(name); i >= 0 {
		return ianaBase + Zone(i), true
	}
	if len(name) != 9 || name[0] != 'U' || name[1] != 'T' || name[2] != 'C' ||
		(name[3] != '+' && name[3] != '-') || name[6] != ':' {
		return 0, false
	}
	hh, ok := twoDigits(name[4], name[5])
	if !ok {
		return 0, false
	}
	mm, ok := twoDigits(name[7], name[8])
	if !ok || mm > 59 {
		return 0, false
	}
	off := Zone(hh*3600 + mm*60)
	if off > maxOffset {
		return 0, false
	}
	if name[3] == '-' {
		off = -off
	}
	return off, true
}

func twoDigits(a, b byte) (int, bool) {
	if a < '0' || a > '9' || b < '0' || b > '9' {
		return 0, false
	}
	return int(a-'0')*10 + int(b-'0'), true
}

// Civil is a broken-down calendar face in some zone.
type Civil struct {
	Year   int
	Month  int // 1..12
	Day    int // 1..31
	Hour   int // 0..23
	Minute int // 0..59
	Second int // 0..59
}

// ianaBase is the sentinel marking a Zone value as named rather than a
// fixed offset: Zone(ianaBase + i) is ianaZones[i]. Fixed offsets are at
// most |14 h| = 50400, far below the base, so the encodings can never
// collide — and Parse's fixed path rejects anything wider anyway.
const ianaBase Zone = 1 << 20

// tzRule is one POSIX-TZ transition rule: in month `month`, the `week`'th
// occurrence of `wday` (week 5 = the last occurrence), at `secs` seconds
// into the day measured in the wall time in force BEFORE the transition.
type tzRule struct {
	month uint8 // 1..12
	week  uint8 // 1..4 = the nth wday, 5 = the last
	wday  uint8 // 0..6, Sunday = 0 (the POSIX numbering)
	secs  int32 // seconds into the day, local wall before the transition
}

// ianaZone is a named zone's current rule as zones.go emits it: standard
// and daylight offsets in seconds east, their abbreviations, and the two
// yearly transitions. hasDST=false is a named fixed offset.
type ianaZone struct {
	name           string
	stdOff         int32 // seconds east of UTC in the standard state
	dstOff         int32 // seconds east of UTC in the daylight state
	stdAbbr        string
	dstAbbr        string
	start, end     tzRule // std -> dst, dst -> std
	hasDST         bool
}

// isNamed reports whether z encodes a named zone rather than an offset.
func isNamed(z Zone) bool {
	return z >= ianaBase && z-ianaBase < Zone(len(ianaZones))
}

// named returns z's table entry; the caller holds the isNamed guard.
func named(z Zone) *ianaZone { return &ianaZones[z-ianaBase] }

// namedIndex is Parse's named-zone half: the table index of the exact
// IANA spelling, or -1.
func namedIndex(name string) int {
	for i := range ianaZones {
		if ianaZones[i].name == name {
			return i
		}
	}
	return -1
}

// Offset is the zone's effective offset from UTC in seconds east at the
// given instant — the fixed value itself for a fixed zone, the POSIX-rule
// resolution for a named one. Alarm math and any consumer that converts
// between epoch and local wall needs this, never the raw Zone value.
func Offset(epoch int64, z Zone) int64 {
	if isNamed(z) {
		off, _ := named(z).offsetAt(epoch)
		return int64(off)
	}
	return int64(z)
}

// offsetAt resolves the POSIX pair for instant e: the two transition
// instants of e's (standard-time) local year, compared with the start <
// end (northern) and start > end (southern) shapes separately.
func (iz *ianaZone) offsetAt(e int64) (int32, string) {
	if !iz.hasDST {
		return iz.stdOff, iz.stdAbbr
	}
	y, _, _ := civilFromDays(floorDiv(e+int64(iz.stdOff), 86400))
	s := transitionUTC(y, iz.start, iz.stdOff)
	en := transitionUTC(y, iz.end, iz.dstOff)
	dst := e >= s || e < en
	if s < en {
		dst = e >= s && e < en
	}
	if dst {
		return iz.dstOff, iz.dstAbbr
	}
	return iz.stdOff, iz.stdAbbr
}

// transitionUTC is the UTC instant of rule r in year y: the local wall
// instant (month, nth-or-last weekday, secs into the day) read in the
// offset in force just before the transition — the POSIX convention, so
// the caller passes the state the transition leaves.
func transitionUTC(y int, r tzRule, before int32) int64 {
	first := daysFromCivil(y, int(r.month), 1)
	dom := 1 + (int(r.wday)-weekday(first)+7)%7 + 7*(int(r.week)-1)
	if dom > daysInMonth(y, int(r.month)) {
		dom -= 7
	}
	return (first+int64(dom-1))*86400 + int64(r.secs) - int64(before)
}

// weekday is the POSIX day-of-week of a days-since-1970 count, Sunday = 0
// (1970-01-01 was a Thursday).
func weekday(days int64) int {
	return int((days%7 + 11) % 7)
}

// daysInMonth counts the proleptic-Gregorian month, February honouring
// the century rules the civil conversion already uses.
func daysInMonth(y, m int) int {
	switch m {
	case 4, 6, 9, 11:
		return 30
	case 2:
		if y%4 == 0 && (y%100 != 0 || y%400 == 0) {
			return 29
		}
		return 28
	}
	return 31
}

// daysFromCivil is civilFromDays's inverse: proleptic-Gregorian y/m/d as
// days since 1970-01-01 — Howard Hinnant's algorithm, run backwards.
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

// At breaks the Unix epoch down in zone z: epoch + the zone's offset AT
// THAT INSTANT, read as a UTC calendar. For a fixed zone the offset is the
// zone value itself; for a named zone the POSIX rule decides which side of
// the year's transitions e falls on.
func At(epoch int64, z Zone) Civil {
	secs := epoch + Offset(epoch, z)
	days := floorDiv(secs, 86400)
	rem := int(secs - days*86400)
	y, m, d := civilFromDays(days)
	return Civil{
		Year: y, Month: m, Day: d,
		Hour: rem / 3600, Minute: rem / 60 % 60, Second: rem % 60,
	}
}

// String renders the face as `2006-01-02 15:04:05` (the same calendar face
// `date` printed before this package existed).
func (c Civil) String() string {
	b := make([]byte, 0, 19)
	y := c.Year
	if y < 0 {
		b = append(b, '-')
		y = -y
	}
	b = appendDigits(b, y, 4)
	b = append(b, '-')
	b = appendDigits(b, c.Month, 2)
	b = append(b, '-')
	b = appendDigits(b, c.Day, 2)
	b = append(b, ' ')
	b = appendDigits(b, c.Hour, 2)
	b = append(b, ':')
	b = appendDigits(b, c.Minute, 2)
	b = append(b, ':')
	b = appendDigits(b, c.Second, 2)
	return string(b)
}

// Format renders epoch in zone z with the zone label: the one call `date`
// (and any app showing a timestamp) makes. A fixed zone keeps its stored
// label (`UTC+05:30`); a named zone's face is labelled with the
// abbreviation and the offset the rule resolved at that instant, so the
// string reads `... CEST UTC+02:00` in summer and `... CET UTC+01:00` in
// winter — the abbreviation plus offset, never the bare IANA name.
func Format(epoch int64, z Zone) string {
	c := At(epoch, z)
	if isNamed(z) {
		off, abbr := named(z).offsetAt(epoch)
		return c.String() + " " + abbr + " " + Label(Zone(off))
	}
	return c.String() + " " + Label(z)
}

func appendDigits(b []byte, v, width int) []byte {
	for i := width - 1; i >= 0; i-- {
		d := v
		for j := 0; j < i; j++ {
			d /= 10
		}
		b = append(b, byte('0'+d%10))
	}
	return b
}

// floorDiv is integer division rounding toward negative infinity, so days
// before 1970 land on the right civil day.
func floorDiv(a, b int64) int64 {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

// civilFromDays converts days since 1970-01-01 to a year/month/day face —
// Howard Hinnant's era-shifted algorithm, exact for every proleptic-Gregorian
// date the epoch can carry.
func civilFromDays(z int64) (year, month, day int) {
	z += 719468 // shift the era origin to 0000-03-01
	era := floorDiv(z, 146097)
	doe := z - era*146097 // [0, 146096]
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365 // [0, 399]
	y := yoe + era*400
	doy := doe - (365*yoe + yoe/4 - yoe/100) // [0, 365]
	mp := (5*doy + 2) / 153                  // [0, 11]
	day = int(doy - (153*mp+2)/5 + 1)        // [1, 31]
	m := mp + 3                              // [3, 14]
	if mp >= 10 {
		m = mp - 9 // [1, 2] of the year after
	}
	year = int(y)
	if m <= 2 {
		year++
	}
	return year, int(m), day
}
