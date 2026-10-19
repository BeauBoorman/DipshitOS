// M124d (#2583): the APPS.TXT read the context menu's "Open With…"
// submenu is built from. The seat (gotabwm/apps.go) decodes the whole
// catalog for the launcher and the drag hit-test; this file is the file
// manager's narrower read of the SAME wire format — the image/apps.txt
// header is the contract both parsers answer to, and only the fields a
// launch carries are kept here: bin, label, fixed argv, opens=.
//
// The eligibility rule (opensAccepts) is byte-for-byte the seat's drop
// admission rule: a bare family word accepts any subtype under it, a
// type/subtype spelling accepts only itself. Two implementations of one
// documented rule, pinned by context_test.go against the same cases
// gotabwm/drag_test.go pins the drag side with.
package main

import (
	"strings"

	"virelai/vi"
)

const (
	// appsTxtPath/appsTxtMax are the manifest's contract path and the
	// 4096-byte budget every reader buffers (sexiburger.manifest_buf_max —
	// the same cap the seat's appsMaxBytes carries).
	appsTxtPath = "/host/APPS.TXT"
	appsTxtMax  = 4096
)

// readAppsFile is the manifest read seam — vi.ReadFileAll in the guest,
// swapped by the host tests (the gotabwm readAppsFile precedent: one seam,
// every fixture staged without a second indirection).
var readAppsFile = vi.ReadFileAll

// appsEntry is the manifest row as the menu needs it. Args is the row's
// argv= tail — fixed arguments ahead of the file path on the exec.
type appsEntry struct {
	bin   string
	label string
	args  []string
	opens []string
}

// loadApps decodes the live manifest; an unreadable share is an empty
// catalog — the menu then lists "(no handlers)" rather than guessing at
// what the system can open.
func loadApps() []appsEntry {
	body, rc := readAppsFile(appsTxtPath, appsTxtMax)
	if rc < 0 {
		return nil
	}
	return parseAppsTxt(string(body))
}

// parseAppsTxt decodes the schema-v2 manifest: `#` comments and blank
// lines skipped, `|` fields, the four positional columns then key=value
// tails. Only v= rows get their tail honoured — a row that cannot name
// its version is refused outright (a guessed version is a silently
// misread manifest, the same refusal the seat makes). argv= is capped at
// ExecMaxArgs-1: the launch appends the file path, and a row that spends
// all eight slots on fixed arguments leaves none for it.
func parseAppsTxt(text string) []appsEntry {
	var out []appsEntry
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if e, ok := parseAppsLine(line); ok {
			out = append(out, e)
		}
	}
	return out
}

func parseAppsLine(line string) (appsEntry, bool) {
	fields := strings.Split(line, "|")
	if len(fields) < 2 {
		return appsEntry{}, false
	}
	e := appsEntry{
		bin:   strings.TrimSpace(fields[0]),
		label: strings.TrimSpace(fields[1]),
	}
	if e.bin == "" || e.label == "" {
		return appsEntry{}, false
	}
	version := 1
	if len(fields) > 4 {
		for _, f := range fields[4:] {
			key, val, ok := strings.Cut(strings.TrimSpace(f), "=")
			if !ok {
				continue // not a key=value tail: a v1 reader ignored it too
			}
			switch key {
			case "v":
				n, ok := parseAppsUint(val)
				if !ok || n == 0 {
					return appsEntry{}, false
				}
				version = n
			case "argv":
				e.args = strings.Fields(val)
				if len(e.args) > vi.ExecMaxArgs-1 {
					e.args = e.args[:vi.ExecMaxArgs-1]
				}
			case "opens":
				e.opens = splitOpens(val)
			default:
				// caps= and any newer key: metadata this consumer never
				// reads, ignored by the same additive-tail rule.
			}
		}
	}
	if version < 2 {
		e.args, e.opens = nil, nil
	}
	return e, true
}

// parseAppsUint decodes the v= version: short unsigned decimal, no
// negative and no garbage (the seat's parseUint shape — no strconv).
func parseAppsUint(s string) (int, bool) {
	if s == "" || len(s) > 3 {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n*10 + int(s[i]-'0')
	}
	return n, true
}

// splitOpens splits the comma-separated opens= list, dropping empties.
func splitOpens(s string) []string {
	var out []string
	for _, tok := range strings.Split(s, ",") {
		if tok != "" {
			out = append(out, tok)
		}
	}
	return out
}

// opensAccepts is the menu's eligibility rule — the same rule the seat's
// drop admission runs (gotabwm/drag.go opensAccepts): a bare family word
// accepts any subtype under it (opens=text takes text/plain), a
// type/subtype spelling accepts only itself. Both directions are
// exact-byte compares; a sniffed spelling is never substring-matched.
func opensAccepts(opens []string, mt string) bool {
	if mt == "" {
		return false
	}
	fam := mt
	if i := strings.IndexByte(mt, '/'); i >= 0 {
		fam = mt[:i]
	}
	for _, o := range opens {
		if o == mt {
			return true
		}
		if !strings.Contains(o, "/") && o == fam {
			return true
		}
	}
	return false
}
