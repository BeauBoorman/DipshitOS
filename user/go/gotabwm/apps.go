// GOTABWM.ELF — M69c2 (#1535): parse /host/APPS.TXT. The manifest is the
// catalog (D2): no second hardcoded app list. Wire format matches the M13
// line `NAME | Display Name | icon | dock=true`. Pure so the host tests pin
// it without a guest.
//
// M82a (#1768) makes the manifest a VERSIONED schema without moving a byte
// that already exists: the four positional fields above are still fields
// 1-4, and everything v2 adds is a trailing `key=value` field. The trailing
// keys are the ones every consumer used to re-derive (what argv the entry
// runs with, what it declares it can do, what it can be handed) plus the
// version that says which of them the row is speaking. The wire format is
// documented where it lives — the header of image/apps.txt — and the
// in-tree precedent for `key=value` tails is the WASM import contract's
// WASM.TXT (`abi=2 | caps=file`, user/src/wasm.zig).
package main

// AppEntry is one catalog row. Bin is the executable name on the share.
type AppEntry struct {
	Bin   string
	Label string
	Icon  byte
	// Dock parses `dock=true` but paints nowhere: M190c (#3238) named it
	// out — the rail IS the running set (one cell per live tab), so a
	// dock-of-pinned-apps layer would need its own surface.
	Dock bool
	// Version is the row's schema version. 0 is a v1 row: the four positional
	// fields only, no trailing fields honoured.
	Version int
	// Args is `argv=` — the fixed arguments the entry is launched with,
	// after the binary. Empty on a v1 row, and the launch is the binary
	// alone.
	Args []string
	// Caps is `caps=` — declared capabilities. M188a (#3186) made them
	// load-bearing: the kernel intersects the exec'd process's grant
	// decision with the declared words plus the runtime floor, so an
	// underdeclared verb is refused by name. The seat still treats the
	// field as data it reports, never as something it enforces.
	Caps []string
	// Opens is `opens=` — what the app can be handed: an M81b mime type
	// name (text image audio archive binary), a URL scheme, or since
	// M124a (#2580) a full type/subtype spelling (text/plain, image/png).
	// The seat's drag admission is opensAccepts in drag.go: a bare family
	// word accepts any subtype under it.
	Opens []string
	// Selection is `selection=` — the app's opt-in to the seat's primary
	// selection (M124e #2584). The only admitted value is "primary": with
	// it the app may publish its selection and receive paste deliveries;
	// without it the seat refuses both directions. Unlike caps= this gate
	// is real — the seat enforces it on every request and delivery.
	Selection string
}

const (
	// appsMax is the catalog's row bound — the manifest's reserved rows
	// (M132b #2753) decode alongside the shipped ones, and a cap under
	// the file's real row count silently drops the tail exactly like a
	// buffer truncation.
	appsMax      = 32
	appsMaxBytes = 4096
	appsPath     = "/host/APPS.TXT"

	// appsMaxArgv is the kernel's max_exec_args (vi.ExecMaxArgs, ADR 0007
	// slot 28): a row may not ask for more arguments than exec can carry.
	// Extra ones are dropped rather than refused — the app still launches,
	// and the alternative (hiding the row) is a worse answer to a typo.
	appsMaxArgv = 8
)

// parseAppsTXT decodes the M13 manifest. `#` comments and blank lines are
// skipped. Entries are capped at appsMax. Slices alias `text`.
func parseAppsTXT(text string) []AppEntry {
	var out []AppEntry
	rest := text
	for len(rest) > 0 && len(out) < appsMax {
		var line string
		line, rest = cutLine(rest)
		line = trimSpace(trimCR(line))
		if line == "" || hasPrefix(line, "#") {
			continue
		}
		e, ok := parseAppLine(line)
		if ok {
			out = append(out, e)
		}
	}
	return out
}

func parseAppLine(line string) (AppEntry, bool) {
	fields := splitPipe(line)
	if len(fields) < 2 {
		return AppEntry{}, false
	}
	bin := trimSpace(fields[0])
	label := trimSpace(fields[1])
	if bin == "" || label == "" {
		return AppEntry{}, false
	}
	icon := byte('?')
	if len(fields) >= 3 {
		ic := trimSpace(fields[2])
		if len(ic) > 0 {
			icon = ic[0]
		}
	}
	dock := false
	if len(fields) >= 4 {
		dock = trimSpace(fields[3]) == "dock=true"
	}
	e := AppEntry{Bin: bin, Label: label, Icon: icon, Dock: dock}
	// M82a: the trailing fields. A v1 line has no field 5, so this loop never
	// runs, which is the whole compatibility claim — the four positional
	// fields decode exactly as they did before the version existed.
	for _, f := range splitTail(fields) {
		key, val, ok := cutField(trimSpace(f))
		if !ok {
			continue // not a `key=value` tail: a v1 reader ignored it too
		}
		switch key {
		case "v":
			// The one field that must be legible: a row whose version is
			// garbage is refused rather than guessed at, because a guessed
			// version is a silently misread manifest.
			n, ok := parseUint(val)
			if !ok || n == 0 {
				return AppEntry{}, false
			}
			e.Version = n
		case "argv":
			e.Args = splitSpace(val, appsMaxArgv)
		case "caps":
			e.Caps = splitComma(val)
		case "opens":
			e.Opens = splitComma(val)
		case "selection":
			e.Selection = val
		default:
			// A key this reader does not know is a NEWER row, not a bad
			// one: the positional fields still say what to launch, and the
			// receipt reports the version so an operator can see it.
		}
	}
	return e, true
}

// splitTail is the fields past the four positional ones, or nothing at all
// when the line stops at four (a v1 row). Written as a helper so the `4` is
// written once: the positional count and the tail's first field are the same
// number by definition, and an off-by-one here would panic on every v1 row.
func splitTail(fields []string) []string {
	if len(fields) <= 4 {
		return nil
	}
	return fields[4:]
}

// cutField splits a trailing field at its first `=`. A field with no `=` is
// not a key=value pair and the caller ignores it.
func cutField(s string) (key, val string, ok bool) {
	for i := 0; i < len(s); i++ {
		if s[i] == '=' {
			return s[:i], trimSpace(s[i+1:]), i > 0
		}
	}
	return "", "", false
}

// splitSpace splits a whitespace-separated value list into at most max items.
func splitSpace(s string, max int) []string {
	var out []string
	rest := s
	for len(rest) > 0 && len(out) < max {
		var tok string
		tok, rest = cutToken(rest)
		if tok != "" {
			out = append(out, tok)
		}
	}
	return out
}

// cutToken takes the next run of non-space bytes off s, consuming the
// leading separator even when the run is empty. Skipping the separators FIRST
// is what guarantees progress: a scanner that stops at a leading space
// returns the whole string again and loops forever.
func cutToken(s string) (tok, rest string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	j := i
	for j < len(s) && s[j] != ' ' && s[j] != '\t' {
		j++
	}
	return s[i:j], s[j:]
}

// splitComma splits a comma-separated value list, dropping empties. An empty
// list is nil, not a one-element list holding "".
func splitComma(s string) []string {
	var out []string
	rest := s
	for len(rest) > 0 {
		var tok string
		tok, rest = cutComma(rest)
		if tok != "" {
			out = append(out, tok)
		}
	}
	return out
}

func cutComma(s string) (tok, rest string) {
	i := 0
	for i < len(s) && s[i] != ',' {
		i++
	}
	if i == len(s) {
		return s, ""
	}
	return s[:i], s[i+1:]
}

// parseUint decodes a short unsigned decimal — the `v=` value. No strconv in
// the EL0 slice, and no negative or huge value is a version.
func parseUint(s string) (int, bool) {
	if s == "" || len(s) > 3 {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	return n, true
}

// AppsSchemaVersion is the highest row version this build was written
// against. A row may declare a HIGHER version: its positional fields still
// launch and its unknown keys are ignored, but the decode receipt says so
// rather than pretending the row was fully understood.
const appsSchemaVersion = 2

// DecodeSummary is the honest report of one manifest read: how many rows
// decoded, the highest row version seen, and how many rows actually spoke
// each trailing key. A key with a zero count is a key no row in this
// manifest uses — stated, not hidden.
type DecodeSummary struct {
	Rows   int
	Schema int
	Argv   int
	Caps   int
	Opens  int
	// M124e: how many rows opted into the seat's primary selection.
	Sel int
}

// SummarizeApps is the pure report over a decoded catalog. Pure so the host
// test pins the receipt's numbers without a guest console.
func SummarizeApps(catalog []AppEntry) DecodeSummary {
	s := DecodeSummary{Rows: len(catalog)}
	for _, e := range catalog {
		if e.Version > s.Schema {
			s.Schema = e.Version
		}
		if len(e.Args) > 0 {
			s.Argv++
		}
		if len(e.Caps) > 0 {
			s.Caps++
		}
		if len(e.Opens) > 0 {
			s.Opens++
		}
		if e.Selection != "" {
			s.Sel++
		}
	}
	return s
}

func filterApps(catalog []AppEntry, q string) []int {
	var idx []int
	for i, e := range catalog {
		if q == "" || asciiContainsFold(e.Bin, q) || asciiContainsFold(e.Label, q) {
			idx = append(idx, i)
		}
	}
	return idx
}

func trimCR(s string) string {
	if len(s) > 0 && s[len(s)-1] == '\r' {
		return s[:len(s)-1]
	}
	return s
}

func trimSpace(s string) string {
	i, j := 0, len(s)
	for i < j && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	for j > i && (s[j-1] == ' ' || s[j-1] == '\t') {
		j--
	}
	return s[i:j]
}

func hasPrefix(s, p string) bool {
	return len(s) >= len(p) && s[:len(p)] == p
}

func splitPipe(s string) []string {
	n := 1
	for i := 0; i < len(s); i++ {
		if s[i] == '|' {
			n++
		}
	}
	out := make([]string, 0, n)
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '|' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

func asciiFold(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

// asciiContainsFold is a substring search that folds A–Z only. HID type-in
// is lowercase ASCII. strings.ToLower pulls unicode case tables into the
// writable segment and pushes memsz%4096 past 1792, so mallocinit dies
// with "cannot allocate memory" (the GOEDIT / vsys clipboard wall).
func asciiContainsFold(s, q string) bool {
	if q == "" {
		return true
	}
	if len(q) > len(s) {
		return false
	}
	n := len(s) - len(q)
	for i := 0; i <= n; i++ {
		ok := true
		for j := 0; j < len(q); j++ {
			if asciiFold(s[i+j]) != asciiFold(q[j]) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}
