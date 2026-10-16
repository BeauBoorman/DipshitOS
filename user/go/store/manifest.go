package main

import (
	"strings"
)

// The launcher manifest at /host/APPS.TXT is a schema-v2 additive file
// (image/apps.txt header): four positional `|`-delimited fields plus
// optional trailing key=value fields. GOTABWM.ELF re-reads it on every
// summon (gotabwm/launcher.go), so a crash-safe rewrite is picked up at
// the next launcher call — nothing notifies or restarts.
const (
	appsPath     = "/host/APPS.TXT"
	appsMaxBytes = 4096 // sexiburger.manifest_buf_max — every reader's bound
)

// loadManifest returns APPS.TXT's raw lines. An absent file is an empty
// manifest (the launcher's own posture); a corrupt one is refused whole —
// STORE never writes on top of bytes it could not read.
func loadManifest(fs FS) ([]string, error) {
	if !fs.Exists(appsPath) {
		return nil, nil
	}
	b, err := fs.ReadFile(appsPath, appsMaxBytes)
	if err != nil {
		return nil, refuse("manifest_malformed", "")
	}
	text := strings.ReplaceAll(string(b), "\r\n", "\n")
	return strings.Split(text, "\n"), nil
}

// rowBin returns the first field of a manifest line (the binary name), or
// "" for comments, blanks, and single-field lines.
func rowBin(line string) string {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return ""
	}
	i := strings.IndexByte(line, '|')
	if i < 0 {
		return ""
	}
	return strings.TrimSpace(line[:i])
}

// manifestHasBin reports whether any row's bin field equals bin.
func manifestHasBin(lines []string, bin string) bool {
	for _, l := range lines {
		if rowBin(l) == bin {
			return true
		}
	}
	return false
}

// renderManifest joins lines back to file bytes with a trailing newline.
func renderManifest(lines []string) []byte {
	var b strings.Builder
	for _, l := range lines {
		if l == "" {
			continue
		}
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return []byte(b.String())
}

// manifestWithRow appends row to the manifest, enforcing the shared
// 4096-byte reader budget (a manifest over it is silently truncated at
// the last whole line by every seat — appending past the bound would
// hide rows, so it refuses manifest_full instead).
func manifestWithRow(lines []string, row string) ([]byte, error) {
	out := renderManifest(append(append([]string{}, lines...), row))
	if len(out) > appsMaxBytes {
		return nil, refuse("manifest_full", "")
	}
	return out, nil
}

// manifestWithoutBin returns the manifest lines minus every row naming
// bin; found reports whether anything was removed.
func manifestWithoutBin(lines []string, bin string) ([]string, bool) {
	out := make([]string, 0, len(lines))
	found := false
	for _, l := range lines {
		if rowBin(l) == bin {
			found = true
			continue
		}
		out = append(out, l)
	}
	return out, found
}

// normalizeBin turns a `store remove <name>` argument into the canonical
// binary name: case-folded up, one trailing .ELF tolerated and re-added.
func normalizeBin(arg string) (string, bool) {
	s := strings.ToUpper(strings.TrimSpace(arg))
	s = strings.TrimSuffix(s, ".ELF")
	if !validStem(s) {
		return "", false
	}
	return s + ".ELF", true
}
