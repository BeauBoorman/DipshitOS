package clockfmt

import "testing"

// TestAtBreaksDownTheEpoch pins the civil conversion against faces computed
// independently on the host (python datetime, 2026-09-29). The rows cross
// year, month, and day boundaries in both directions, include the 2024 leap
// day and the 1900/2100 century non-leap years, and reach the pre-1970
// negative epochs — the same math `date` runs in the guest.
func TestAtBreaksDownTheEpoch(t *testing.T) {
	cases := []struct {
		epoch int64
		zone  Zone
		want  string
	}{
		{0, UTC, "1970-01-01 00:00:00"},
		{0, 5 * 3600, "1970-01-01 05:00:00"},
		{0, -8 * 3600, "1969-12-31 16:00:00"},
		{-1, UTC, "1969-12-31 23:59:59"},
		{-1, 5*3600 + 30*60, "1970-01-01 05:29:59"},
		{1789043696, UTC, "2026-09-10 12:34:56"},
		{1789043696, 5*3600 + 30*60, "2026-09-10 18:04:56"},
		{1789043696, -8 * 3600, "2026-09-10 04:34:56"},
		{1789043696, 14 * 3600, "2026-09-11 02:34:56"}, // the day rolls over east
		{1709164800, UTC, "2024-02-29 00:00:00"},        // the leap day itself
		{1709164800, -8 * 3600, "2024-02-28 16:00:00"},  // ...and one day back west
		{4102444800, UTC, "2100-01-01 00:00:00"},        // 2100 is NOT a leap year
		{4102444800, -8 * 3600, "2099-12-31 16:00:00"},
		{-2208988800, UTC, "1900-01-01 00:00:00"}, // 1900 is NOT either
	}
	for _, c := range cases {
		if got := At(c.epoch, c.zone).String(); got != c.want {
			t.Errorf("At(%d, %d).String() = %q, want %q", c.epoch, c.zone, got, c.want)
		}
	}
}

// TestFormatCarriesTheZoneLabel pins the shared formatter's face: the civil
// face plus the canonical label, which is what `date` prints.
func TestFormatCarriesTheZoneLabel(t *testing.T) {
	cases := []struct {
		epoch int64
		zone  Zone
		want  string
	}{
		{1789043696, UTC, "2026-09-10 12:34:56 UTC"},
		{1789043696, 5*3600 + 30*60, "2026-09-10 18:04:56 UTC+05:30"},
		{1789043696, -8 * 3600, "2026-09-10 04:34:56 UTC-08:00"},
	}
	for _, c := range cases {
		if got := Format(c.epoch, c.zone); got != c.want {
			t.Errorf("Format(%d, %d) = %q, want %q", c.epoch, c.zone, got, c.want)
		}
	}
}

// TestParseAndLabelRoundTrip pins the stored vocabulary: every curated
// offset parses from its own label, the zero zone labels `UTC` under every
// spelling, and the shapes a typo produces are refused.
func TestParseAndLabelRoundTrip(t *testing.T) {
	for _, z := range Offsets {
		name := Label(z)
		got, ok := Parse(name)
		if !ok || got != z {
			t.Errorf("Parse(Label(%d)) = %d, %v; want %d, true", z, got, ok, z)
		}
	}
	if z, ok := Parse("UTC"); !ok || z != UTC {
		t.Errorf("Parse(UTC) = %d, %v; want 0, true", z, ok)
	}
	if z, ok := Parse("UTC+00:00"); !ok || z != UTC {
		t.Errorf("Parse(UTC+00:00) = %d, %v; want 0, true", z, ok)
	}
	if z, ok := Parse("UTC+05:45"); !ok || z != 5*3600+45*60 {
		t.Errorf("Parse(UTC+05:45) = %d, %v; want a real fixed offset", z, ok)
	}
	for _, bad := range []string{
		"", "utc", "UTC+", "UTC+5:30", "UTC+05:3", "UTC+0530",
		"UTC+05:60", "UTC+15:00", "UTC-15:00", "GMT", "Europe/Nowhere", "UTC+05:30 ",
	} {
		if z, ok := Parse(bad); ok {
			t.Errorf("Parse(%q) = %d, true; want refusal", bad, z)
		}
	}
}

// TestLabelIsCanonical: the label is derived from the offset alone, so two
// spellings of one offset can never both be stored.
func TestLabelIsCanonical(t *testing.T) {
	if got := Label(0); got != "UTC" {
		t.Errorf("Label(0) = %q, want UTC", got)
	}
	if got := Label(5*3600 + 30*60); got != "UTC+05:30" {
		t.Errorf("Label(19800) = %q, want UTC+05:30", got)
	}
	if got := Label(-8 * 3600); got != "UTC-08:00" {
		t.Errorf("Label(-28800) = %q, want UTC-08:00", got)
	}
}

// TestNamesAreTheCuratedVocabulary pins the GOSET cycle list: the curated
// labels, west to east, `UTC` among them.
func TestNamesAreTheCuratedVocabulary(t *testing.T) {
	names := Names()
	if len(names) != len(Offsets) {
		t.Fatalf("Names() = %d names, want %d", len(names), len(Offsets))
	}
	seen := map[string]bool{}
	for i, n := range names {
		if seen[n] {
			t.Errorf("Names() repeats %q", n)
		}
		seen[n] = true
		if n != Label(Offsets[i]) {
			t.Errorf("Names()[%d] = %q, want %q", i, n, Label(Offsets[i]))
		}
	}
	if !seen["UTC"] {
		t.Errorf("Names() has no UTC: %v", names)
	}
}

// --- M178c (#3146): named IANA zones ----------------------------------------

// mustParse is the shared harness for the named-zone pins: a spelling that
// refuses is a table bug, not a test fixture.
func mustParse(t *testing.T, name string) Zone {
	t.Helper()
	z, ok := Parse(name)
	if !ok {
		t.Fatalf("Parse(%q) refused a curated name", name)
	}
	return z
}

// TestParseAcceptsTheCuratedNames pins the named half of the vocabulary:
// every ianaZones row parses and round-trips through Label — the stored
// spelling IS the name — while the curated cycle list (Names) stays
// fixed-offset-only, which is what keeps GOSET's cycle and its tests
// untouched.
func TestParseAcceptsTheCuratedNames(t *testing.T) {
	if len(ianaZones) < 40 {
		t.Fatalf("ianaZones carries %d zones, want the curated ~60+", len(ianaZones))
	}
	for _, iz := range ianaZones {
		z := mustParse(t, iz.name)
		if got := Label(z); got != iz.name {
			t.Errorf("Label(Parse(%q)) = %q — the name must round-trip", iz.name, got)
		}
	}
	// The cycle vocabulary is unchanged: no IANA name leaks into Names().
	for _, n := range Names() {
		if _, ok := Parse(n); !ok || namedIndex(n) >= 0 {
			t.Errorf("Names() carries %q — the GOSET cycle stays fixed-offset", n)
		}
	}
	// Lookalikes refuse: names are exact, not prefix- or case-lenient.
	for _, bad := range []string{
		"europe/Berlin", "Europe/Berlin ", "Europe", "Europe/Berlinn",
		"Berlin", "Asia/Kolkatta", "UTC+05:30x",
	} {
		if z, ok := Parse(bad); ok {
			t.Errorf("Parse(%q) = %d, true; want refusal", bad, z)
		}
	}
}

// TestNamedZoneResolvesAtTheInstant pins the POSIX evaluator at the four
// edges the card names: DST start and end for a northern zone (Berlin),
// both directions for a southern one (Sydney), a half-hour offset
// (Adelaide), and Dublin's negative-save winter. Expected faces were
// computed on the host with python zoneinfo, tzdata-equivalent rules.
func TestNamedZoneResolvesAtTheInstant(t *testing.T) {
	berlin := mustParse(t, "Europe/Berlin")
	sydney := mustParse(t, "Australia/Sydney")
	adelaide := mustParse(t, "Australia/Adelaide")
	dublin := mustParse(t, "Europe/Dublin")
	cases := []struct {
		epoch int64
		zone  Zone
		want  string
	}{
		// Europe/Berlin: CEST starts 2026-03-29 at 01:00 UTC —
		// 01:59:59 CET jumps to 03:00:00 CEST.
		{1774745999, berlin, "2026-03-29 01:59:59"},
		{1774746000, berlin, "2026-03-29 03:00:00"},
		// and ends 2026-10-25 at 01:00 UTC — 02:59:59 CEST to 02:00:00 CET.
		{1792889999, berlin, "2026-10-25 02:59:59"},
		{1792890000, berlin, "2026-10-25 02:00:00"},
		// Australia/Sydney, the southern shape: AEDT starts 2026-10-04
		// (16:00 UTC on the 3rd) and ends 2026-04-05.
		{1791043199, sydney, "2026-10-04 01:59:59"},
		{1791043200, sydney, "2026-10-04 03:00:00"},
		{1775318399, sydney, "2026-04-05 02:59:59"},
		{1775318400, sydney, "2026-04-05 02:00:00"},
		// Australia/Adelaide: the half-hour pair +09:30/+10:30.
		{1784116800, adelaide, "2026-07-15 21:30:00"}, // ACST, winter
		{1768478400, adelaide, "2026-01-15 22:30:00"}, // ACDT, summer
		// Europe/Dublin: negative-save winter — GMT in January, IST (+1)
		// in July.
		{1768478400, dublin, "2026-01-15 12:00:00"},
		{1784116800, dublin, "2026-07-15 13:00:00"},
	}
	for _, c := range cases {
		if got := At(c.epoch, c.zone).String(); got != c.want {
			t.Errorf("At(%d, %s) = %q, want %q", c.epoch, Label(c.zone), got, c.want)
		}
	}
}

// TestFormatLabelsTheNamedFace pins Format's named-zone string: the
// abbreviation AND the resolved offset (`CEST UTC+02:00`), so `date` under
// a named row reads like a real zone, while a named fixed offset labels
// the same way (`IST UTC+05:30`).
func TestFormatLabelsTheNamedFace(t *testing.T) {
	cases := []struct {
		epoch int64
		name  string
		want  string
	}{
		{1784116800, "Europe/Berlin", "2026-07-15 14:00:00 CEST UTC+02:00"},
		{1768478400, "Europe/Berlin", "2026-01-15 13:00:00 CET UTC+01:00"},
		{1768478400, "Europe/London", "2026-01-15 12:00:00 GMT UTC"},
		{1784116800, "Europe/London", "2026-07-15 13:00:00 BST UTC+01:00"},
		{1784116800, "Asia/Kolkata", "2026-07-15 17:30:00 IST UTC+05:30"},
		{1768478400, "America/New_York", "2026-01-15 07:00:00 EST UTC-05:00"},
		{1784116800, "America/New_York", "2026-07-15 08:00:00 EDT UTC-04:00"},
		{1784116800, "Australia/Adelaide", "2026-07-15 21:30:00 ACST UTC+09:30"},
		{1768478400, "Australia/Adelaide", "2026-01-15 22:30:00 ACDT UTC+10:30"},
	}
	for _, c := range cases {
		z := mustParse(t, c.name)
		if got := Format(c.epoch, z); got != c.want {
			t.Errorf("Format(%d, %s) = %q, want %q", c.epoch, c.name, got, c.want)
		}
	}
}

// TestOffsetAtInstant pins the exported resolver the alarm math uses:
// fixed zones answer their own value at every instant, named zones the
// state the POSIX rule resolves there.
func TestOffsetAtInstant(t *testing.T) {
	if got := Offset(1784116800, 5*3600+30*60); got != 19800 {
		t.Errorf("Offset(fixed +05:30) = %d, want 19800", got)
	}
	berlin := mustParse(t, "Europe/Berlin")
	if got := Offset(1774745999, berlin); got != 3600 {
		t.Errorf("Offset(Berlin, pre-start) = %d, want 3600", got)
	}
	if got := Offset(1774746000, berlin); got != 7200 {
		t.Errorf("Offset(Berlin, post-start) = %d, want 7200", got)
	}
	// A named zone the rules already ended for resolves as its fixed
	// offset — Moscow is Europe/Moscow with no ongoing DST.
	moscow := mustParse(t, "Europe/Moscow")
	if got := Offset(1784116800, moscow); got != 10800 {
		t.Errorf("Offset(Moscow) = %d, want 10800", got)
	}
}

// TestFixedOffsetsAreUnchanged is the regression guard the card asks for
// explicitly: the sentinel range can never collide with a real offset, and
// a hand-edited UTC±HH:MM still resolves, labels and formats exactly as it
// did before named zones existed.
func TestFixedOffsetsAreUnchanged(t *testing.T) {
	for _, z := range Offsets {
		if isNamed(z) {
			t.Fatalf("Offsets entry %d encodes in the named range", z)
		}
	}
	if isNamed(14 * 3600) || isNamed(-14 * 3600) {
		t.Fatal("the widest real offset must stay fixed, not named")
	}
	z := mustParse(t, "UTC+05:45")
	if isNamed(z) || Format(1784116800, z) != "2026-07-15 17:45:00 UTC+05:45" {
		t.Errorf("hand-edited UTC+05:45 formats %q", Format(1784116800, z))
	}
}
