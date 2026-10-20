package main

import (
	"os"
	"strings"
	"testing"

	"virelai/vi"
)

func TestParseAppsTXTSkipsCommentsAndCaps(t *testing.T) {
	text := "# VirelaiOS app manifest\n" +
		"GOCALC.ELF | 64-bit Calc | c | dock=true\n" +
		"\n" +
		"NOTE.ELF | Text Editor | n | dock=true\n" +
		"TABWM.BIN | Tabbed Desktop | m\n" +
		"BADLINE\n" +
		" | no-bin | x\n"
	got := parseAppsTXT(text)
	if len(got) != 3 {
		t.Fatalf("parse n=%d want 3: %+v", len(got), got)
	}
	if got[0].Bin != "GOCALC.ELF" || got[0].Label != "64-bit Calc" || !got[0].Dock || got[0].Icon != 'c' {
		t.Fatalf("row0 %+v", got[0])
	}
	if got[2].Dock {
		t.Fatal("TABWM.BIN must not be docked in the fixture")
	}
}

func TestParseAppsTXTRefusesDeletedNamesInHonestFixture(t *testing.T) {
	// The honest image/apps.txt must not list these; this pins the parser
	// still seeing them if a test feeds a lie.
	text := "NOTEPAD.ELF | Editor | n\nCALC.BIN | Calc | c\n"
	got := parseAppsTXT(text)
	if len(got) != 2 {
		t.Fatalf("parser must still accept the bytes: n=%d", len(got))
	}
}

func TestHonestImageAppsTxt(t *testing.T) {
	b, err := os.ReadFile("../../../image/apps.txt")
	if err != nil {
		t.Fatalf("read image/apps.txt: %v", err)
	}
	got := parseAppsTXT(string(b))
	want := map[string]bool{
		"GOCALC.ELF": true, "NOTE.ELF": true, "GOEDIT.ELF": true,
		"GOFILES.ELF": true, "WEB.ELF": true,
	}
	seen := map[string]bool{}
	for _, e := range got {
		seen[e.Bin] = true
		switch e.Bin {
		case "NOTEPAD.ELF", "CALC.BIN", "CALC.ELF", "FILE.ELF", "DESKTOP.ELF":
			t.Fatalf("honest catalog still offers %s", e.Bin)
		}
		if e.Bin == "TABWM.BIN" && e.Dock {
			t.Fatal("TABWM.BIN must not be a default dock target")
		}
	}
	for name := range want {
		if !seen[name] {
			t.Fatalf("honest catalog missing %s", name)
		}
	}
	if !seen["GOSH.ELF"] && !seen["GOTERM.ELF"] {
		t.Fatal("honest catalog missing GOSH.ELF and GOTERM.ELF")
	}
}

func TestFilterAppsSubstring(t *testing.T) {
	cat := []AppEntry{
		{Bin: "GOCALC.ELF", Label: "64-bit Calc"},
		{Bin: "NOTE.ELF", Label: "Text Editor"},
		{Bin: "WEB.ELF", Label: "Web"},
	}
	idx := filterApps(cat, "calc")
	if len(idx) != 1 || cat[idx[0]].Bin != "GOCALC.ELF" {
		t.Fatalf("filter calc = %v", idx)
	}
	idx = filterApps(cat, "ELF")
	if len(idx) != 3 {
		t.Fatalf("filter ELF n=%d", len(idx))
	}
	idx = filterApps(cat, "nope")
	if len(idx) != 0 {
		t.Fatalf("filter nope = %v", idx)
	}
	if n := filterApps(cat, ""); len(n) != 3 {
		t.Fatal("empty query is the full catalog")
	}
	idx = filterApps(cat, "CALC")
	if len(idx) != 1 || cat[idx[0]].Bin != "GOCALC.ELF" {
		t.Fatalf("ASCII fold CALC = %v", idx)
	}
}

// --- M82a (#1768): the versioned additive tail ---------------------------

// The compatibility claim, stated as a test: a v1 line — the exact four
// fields every reader parsed before the version existed — decodes to exactly
// the same entry, with no version and no trailing fields. A parser that grew
// a required v2 field would fail this line, which is the point.
func TestParseAppsTXTV1LineIsUnchangedByTheSchema(t *testing.T) {
	got := parseAppsTXT("GOCALC.ELF | 64-bit Calc | c | dock=true\n")
	if len(got) != 1 {
		t.Fatalf("v1 row n=%d want 1", len(got))
	}
	e := got[0]
	if e.Bin != "GOCALC.ELF" || e.Label != "64-bit Calc" || e.Icon != 'c' || !e.Dock {
		t.Fatalf("v1 positional fields changed: %+v", e)
	}
	if e.Version != 0 || len(e.Args) != 0 || len(e.Caps) != 0 || len(e.Opens) != 0 {
		t.Fatalf("a v1 row must carry nothing from the v2 tail: %+v", e)
	}
}

func TestParseAppsTXTDecodesTheV2Tail(t *testing.T) {
	got := parseAppsTXT("WEB.ELF | Web | w | dock=true | v=2 | caps=net | opens=http,https\n")
	if len(got) != 1 {
		t.Fatalf("n=%d want 1", len(got))
	}
	e := got[0]
	if e.Version != 2 {
		t.Fatalf("version = %d want 2", e.Version)
	}
	if len(e.Caps) != 1 || e.Caps[0] != "net" {
		t.Fatalf("caps = %v", e.Caps)
	}
	if len(e.Opens) != 2 || e.Opens[0] != "http" || e.Opens[1] != "https" {
		t.Fatalf("opens = %v (order must follow the line)", e.Opens)
	}
	// The tail is ORDER-INSENSITIVE in its KEYS: a row that spells them in
	// another order says the same thing. Its VALUES keep the order the line
	// wrote them in, because `opens=` is a preference order for a menu and
	// reordering it would be the reader inventing an intent.
	shuffled := parseAppsTXT("WEB.ELF | Web | w | dock=true | opens=https,http | v=2 | caps=net\n")
	if len(shuffled) != 1 {
		t.Fatalf("shuffled n=%d", len(shuffled))
	}
	if strings.Join(shuffled[0].Opens, ",") != "https,http" {
		t.Fatalf("shuffled opens = %v (value order must be the line's own)", shuffled[0].Opens)
	}
	if shuffled[0].Version != 2 || shuffled[0].Caps[0] != "net" {
		t.Fatalf("shuffled row = %+v", shuffled[0])
	}
}

func TestParseAppsTXTAargvIsSpaceSeparatedAndBounded(t *testing.T) {
	got := parseAppsTXT("APP.ELF | App | a | v=2 | argv=--mode fast --tag x\n")
	if len(got) != 1 {
		t.Fatalf("n=%d", len(got))
	}
	want := []string{"--mode", "fast", "--tag", "x"}
	if strings.Join(got[0].Args, " ") != strings.Join(want, " ") {
		t.Fatalf("argv = %v want %v", got[0].Args, want)
	}
	// Nine arguments is more than the kernel's exec can carry
	// (max_exec_args = 8). The row keeps the first eight and the ninth is
	// dropped: an app that launches with one argument short is a smaller
	// lie than an app that vanished from the catalog.
	long := "APP.ELF | App | a | v=2 | argv=1 2 3 4 5 6 7 8 9\n"
	got = parseAppsTXT(long)
	if len(got) != 1 {
		t.Fatalf("over-long argv must not hide the row: n=%d", len(got))
	}
	if len(got[0].Args) != appsMaxArgv {
		t.Fatalf("argv capped at %d want %d: %v", len(got[0].Args), appsMaxArgv, got[0].Args)
	}
}

func TestParseAppsTXTIgnoresUnknownKeysAndJunkTails(t *testing.T) {
	// A row from a NEWER schema still launches: the positional fields are
	// what the seat needs, and the keys this build does not know are not a
	// reason to hide an app the user can see on the dock.
	got := parseAppsTXT("NEW.ELF | New | n | dock=true | v=7 | future=whatever | junk\n")
	if len(got) != 1 {
		t.Fatalf("n=%d want 1", len(got))
	}
	if got[0].Bin != "NEW.ELF" || !got[0].Dock || got[0].Version != 7 {
		t.Fatalf("row = %+v", got[0])
	}
	if len(got[0].Args) != 0 || len(got[0].Caps) != 0 || len(got[0].Opens) != 0 {
		t.Fatalf("unknown keys must decode to nothing: %+v", got[0])
	}
}

func TestParseAppsTXTRefusesAnUnreadableVersion(t *testing.T) {
	// The one field that must be legible. A `v=` that is not a positive
	// number is a row whose version cannot be read, and a guessed version is
	// a silently misread manifest — so the row is refused, like any other
	// malformed row.
	for _, line := range []string{
		"BAD.ELF | Bad | b | dock=true | v=x\n",
		"BAD.ELF | Bad | b | dock=true | v=0\n",
		"BAD.ELF | Bad | b | dock=true | v=\n",
		"BAD.ELF | Bad | b | dock=true | v=9999\n",
		"BAD.ELF | Bad | b | dock=true | v=2x\n",
	} {
		if got := parseAppsTXT(line); len(got) != 0 {
			t.Fatalf("line %q must be refused, got %+v", line, got)
		}
	}
	// The floor for the "too long to be a version" rule is len 3 (`999`),
	// so 2 is a real version and 1000 is not a row we can read.
	got := parseAppsTXT("OK.ELF | Ok | o | dock=true | v=2\n")
	if len(got) != 1 || got[0].Version != 2 {
		t.Fatalf("v=2 must decode: %+v", got)
	}
}

// A row with only three positional fields still has a FOURTH field, and the
// fourth field is the dock flag — never a key. The tail starts at field five,
// so a `v=` in the dock position is a row that is not docked, not a row that
// declares a version. This is the boundary the additive claim rests on, and it
// is why `v=` belongs in the tail and not beside the positional fields.
func TestParseAppsTXTFourthFieldIsStillTheDockFlag(t *testing.T) {
	got := parseAppsTXT("OK.ELF | Ok | o | v=2\n")
	if len(got) != 1 {
		t.Fatalf("n=%d want 1", len(got))
	}
	if got[0].Dock {
		t.Fatal("field 4 is the dock flag: `v=2` there must not dock the row")
	}
	if got[0].Version != 0 {
		t.Fatalf("version = %d: the tail starts at field 5", got[0].Version)
	}
}

func TestSummarizeAppsCountsRowsAndTheHighestVersion(t *testing.T) {
	b, err := os.ReadFile("../../../image/apps.txt")
	if err != nil {
		t.Fatalf("read image/apps.txt: %v", err)
	}
	s := SummarizeApps(parseAppsTXT(string(b)))
	// M122c (#2572) purged the three ghost rows (GODIFF/ZC.BIN/GOSNAP — a
	// click could only die on a usage line or a silent serial write) and
	// M122b (#2571) added GOWELCOME; M120d (#2561) restored GOSNAP now
	// that a bare exec opens its window; M132b (#2753) appended the nine
	// M140–M148 reservation rows — the honest catalog is 29 rows.
	if s.Rows != 29 {
		t.Fatalf("rows = %d want 29 (the honest catalog)", s.Rows)
	}
	// The receipt's headline: the manifest declares v2 rows, so a reader that
	// ignored the tail would report v=0 and fail here.
	if s.Schema != appsSchemaVersion {
		t.Fatalf("schema = %d want %d", s.Schema, appsSchemaVersion)
	}
	// Every trailing key is either used by a row or reported as unused.
	// GOSTALGIA is the one shipping row that declares a fixed command line
	// (`argv=shell --root /host/GS`), so a one here is the truth and is
	// pinned so a row appearing later is a deliberate edit to this test.
	if s.Argv != 1 {
		t.Fatalf("argv rows = %d: a row now declares a fixed command line; "+
			"the marker and this test must both learn about it", s.Argv)
	}
	if s.Caps == 0 || s.Opens == 0 {
		t.Fatalf("caps/opens rows = %d/%d: the v2 tail is not being read", s.Caps, s.Opens)
	}
	// M124e (#2584): GOEDIT, GOTERM and GOVAULT (M148a #2804 — the vault's
	// copy publishes the seat selection) are the three selection=primary
	// rows — pinned like argv so a fourth opt-in is a deliberate edit here.
	if s.Sel != 3 {
		t.Fatalf("selection=primary rows = %d want 3 (GOEDIT + GOTERM + GOVAULT)", s.Sel)
	}
}

// The `opens=` vocabulary is M81b's mime table, not a second list: a name the
// table does not know is a manifest typo that would dispatch nothing. The
// table is read from its source rather than copied here, so this test fails
// if a future card renames an ID — the manifest has to follow it.
func TestManifestOpenTypesAreMimeTableNames(t *testing.T) {
	src, err := os.ReadFile("../mime/mime.go")
	if err != nil {
		t.Fatalf("read mime.go: %v", err)
	}
	// The canonical names are the `return "<name>"` arms of ID.String(),
	// which is what markers, receipts and menus print.
	known := map[string]bool{}
	inString := false
	for _, ln := range strings.Split(string(src), "\n") {
		t := strings.TrimSpace(ln)
		if strings.HasPrefix(t, "func (id ID) String() string {") {
			inString = true
			continue
		}
		if inString && t == "}" {
			inString = false
			continue
		}
		if !inString {
			continue
		}
		if i := strings.Index(t, `return "`); i >= 0 {
			rest := t[i+len(`return "`):]
			if j := strings.Index(rest, `"`); j >= 0 {
				known[rest[:j]] = true
			}
		}
	}
	for _, want := range []string{"text", "image", "audio", "archive", "binary"} {
		if !known[want] {
			t.Fatalf("mime ID %q not found in mime.go's String() — this test "+
				"is reading the wrong thing", want)
		}
	}
	// M81c (#1763) owns URL schemes; they are names mime has no opinion
	// about, and the two must not be confused.
	schemes := map[string]bool{"http": true, "https": true}

	b, err := os.ReadFile("../../../image/apps.txt")
	if err != nil {
		t.Fatalf("read image/apps.txt: %v", err)
	}
	for _, e := range parseAppsTXT(string(b)) {
		if e.Version == 0 {
			continue // a v1 row declares nothing
		}
		for _, o := range e.Opens {
			if !known[o] && !schemes[o] {
				t.Fatalf("%s opens %q, which is neither an M81b mime type "+
					"(%s) nor a URL scheme (%s)", e.Bin, o, keys(known), keys(schemes))
			}
		}
	}
}

func keys(m map[string]bool) string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return strings.Join(out, ",")
}

// The caps vocabulary is declared in two places on purpose: the manifest
// header (for the operator) and here (for the reader). The first seven words
// are the WASM import contract's Cap names, so one word means one thing
// across manifests; `net` and `term` are this manifest's additions.
func TestManifestCapsAreTheDeclaredVocabulary(t *testing.T) {
	declared := strings.Fields("file window audio timer memory process debug net term")
	known := map[string]bool{}
	for _, w := range declared {
		known[w] = true
	}
	b, err := os.ReadFile("../../../image/apps.txt")
	if err != nil {
		t.Fatalf("read image/apps.txt: %v", err)
	}
	for _, e := range parseAppsTXT(string(b)) {
		for _, c := range e.Caps {
			if !known[c] {
				t.Fatalf("%s declares cap %q, outside the vocabulary %v", e.Bin, c, declared)
			}
		}
	}
}

// --- M122c (#2572): manifest honesty ----------------------------------------

// catalogHonesty is the gateable claim about every row a person can see in
// the launcher: a click either opens a window ("window" — the proof file
// named here must carry a window-open call), is a seat-reserved name the
// launcher refuses with a named reason ("seat"), or is an M132b reserved
// row whose binary is not shipped yet ("reserved" — the launcher's own
// availability probe names "Binary not staged", a placeholder refusal
// rather than a launch that dies). A row absent from this table fails the
// test — the catalog may not offer a launch that dies on a usage line, and
// there is no bound terminal wrapper in the exec ABI to launder one
// through (a spawned process's console writes go to serial, never to a
// window's tty).
var catalogHonesty = []struct {
	bin   string
	kind  string // "window" | "seat" | "reserved"
	proof string // "window" rows: repo-relative file that opens the window
}{
	{"GOCALC.ELF", "window", "user/go/calc/main.go"},
	{"NOTE.ELF", "window", "user/go/note/main.go"},
	{"GOEDIT.ELF", "window", "user/go/edit/main.go"},
	{"GOFILES.ELF", "window", "user/go/files/main.go"},
	{"GOTERM.ELF", "window", "user/go/term/main.go"},
	{"WEB.ELF", "window", "user/go/browser/main.go"},
	{"PULSE.ELF", "window", "user/go/pulse/main.go"},
	{"GOSH.ELF", "window", "user/go/sh/main.go"},
	{"GOHELP.ELF", "window", "user/go/help/main.go"},
	{"GOWELCOME.ELF", "window", "user/go/welcome/main.go"},
	{"GOTOP.ELF", "window", "user/go/top/main.go"},
	{"GOSET.ELF", "window", "user/go/goset/main.go"},
	{"GOVIEW.ELF", "window", "user/go/view/main.go"},
	{"GOSOUND.ELF", "window", "user/go/sound/main.go"},
	{"GOSTALGIA.ELF", "window", "user/go/gsport/tty/tty.go"},
	{"GOSTORE.ELF", "window", "user/go/gostore/main.go"},
	{"GOINFER.ELF", "window", "user/go/goinfer/view.go"},
	{"GOREC.ELF", "window", "user/go/gorec/view.go"},
	{"GOSNAP.ELF", "window", "user/go/gosnap/view.go"},
	{"TABWM.BIN", "seat", ""},
	// M132b (#2753): the M140–M148 reservation rows. Each app card lands
	// its binary and moves its entry up to "window" with a proof file.
	{"GOASSIST.ELF", "reserved", ""},
	{"GOSHEET.ELF", "reserved", ""},
	{"GOREADER.ELF", "reserved", ""},
	{"GOCLOCK.ELF", "reserved", ""},
	{"GOMINE.ELF", "reserved", ""},
	{"GOSOL.ELF", "reserved", ""},
	{"GOEMOJI.ELF", "reserved", ""},
	{"GOIRC.ELF", "reserved", ""},
	{"GOVAULT.ELF", "reserved", ""},
}

// windowMarkers are the calls that open (or bind) a window in this tree:
// the tabapp path every Go app takes, or the raw window/tty syscalls an
// app issues directly. A proof file containing none of them cannot be a
// window row's bare launch.
var windowMarkers = []string{
	"tabapp.Init",
	"tabapp.Attach",
	"WinOpen(",
	"TtyAttachWindow(",
}

func TestManifestHonestyRowsOpenAWindowOrAreSeatBound(t *testing.T) {
	// The reserved rows' probe must answer "not staged": stub the file
	// seam to ENOENT so the pin holds on a host that has no /host share
	// rather than depending on the ambient filesystem's accidents.
	savedOpen := openFile
	openFile = func(string, uint32) (int64, int64) { return -1, -vi.ErrENOENT }
	defer func() { openFile = savedOpen }()

	b, err := os.ReadFile("../../../image/apps.txt")
	if err != nil {
		t.Fatalf("read image/apps.txt: %v", err)
	}
	byBin := map[string]struct {
		kind  string
		proof string
	}{}
	for _, r := range catalogHonesty {
		byBin[r.bin] = struct {
			kind  string
			proof string
		}{r.kind, r.proof}
	}
	seen := map[string]bool{}
	for _, e := range parseAppsTXT(string(b)) {
		seen[e.Bin] = true
		r, ok := byBin[e.Bin]
		if !ok {
			t.Fatalf("catalog row %s has no honesty entry — every launcher "+
				"row must open a window (proof) or be a seat name", e.Bin)
		}
		switch r.kind {
		case "seat":
			// The launcher refuses these with the named reason before any
			// staging probe, so the row is never a silent death.
			if reason := appUnavailable(e); reason == "" {
				t.Fatalf("seat row %s is launchable", e.Bin)
			}
		case "reserved":
			// An M132b reserved row: its binary is not shipped, so the
			// probe names the refusal ("Binary not staged") — the visible
			// placeholder the reservation table promises, never a launch
			// that dies silently.
			if reason := appUnavailable(e); reason == "" {
				t.Fatalf("reserved row %s is launchable — move its entry "+
					"to \"window\" with a proof file when the app lands", e.Bin)
			}
		case "window":
			src, err := os.ReadFile("../../../" + r.proof)
			if err != nil {
				t.Fatalf("%s proof %s unreadable: %v", e.Bin, r.proof, err)
			}
			found := false
			for _, m := range windowMarkers {
				if strings.Contains(string(src), m) {
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("%s: %s carries no window-open call — the row "+
					"claims a window it cannot open", e.Bin, r.proof)
			}
		default:
			t.Fatalf("honesty entry for %s has unknown kind %q", e.Bin, r.kind)
		}
	}
	for bin := range byBin {
		if !seen[bin] {
			t.Fatalf("honesty entry %s is stale — no such catalog row", bin)
		}
	}
}
