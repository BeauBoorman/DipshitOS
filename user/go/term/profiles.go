// M149b (issue #2807): named GOTERM profiles.
//
// A profile is a named bundle of the settings keys the terminal answers to —
// the M80i `font_size` ladder plus the M73m colour vocabulary (`theme`, and
// `palette_fg`/`palette_bg`/`palette_accent` when the theme is `custom`).
// Profiles live in their own settings file, /host/GOTERM-PROFILES.TXT, in
// the same `key=value` grammar as SETTINGS.TXT:
//
//	# name.key = value
//	dusk.font_size = large
//	dusk.theme = custom
//	dusk.palette_fg = e0e6ed
//	dusk.palette_bg = 0b1020
//	dusk.palette_accent = 7aa2f7
//
// Choosing a profile merges its keys into SETTINGS.TXT (plus
// `term_profile=<name>` as the record of the choice) through the same
// crash-safe publish every settings writer uses; the kernel applies the
// font ladder and theme live exactly as it does for a GOSET save, and each
// changed key is published to the seat the same way. The selection itself
// rides the settings store, so it is discoverable wherever the palette of
// settings keys is browsed — GOSET and the command palette's `Settings:`
// rows both carry `font_size`/`theme`/`palette_*`.
//
// In-terminal selection is the `term-profile` line command (the same
// front-end intercept as `exit --close` — it never reaches the engine):
// `term-profile` lists the file's profile names (the active one starred),
// `term-profile <name>` applies one, and `term-profile next`/`prev` cycle
// the file's order with wraparound. `next` and `prev` are therefore
// reserved names — a profile carrying either is unreachable by name.
package main

import (
	"strings"
)

const (
	profilesPath    = "/host/GOTERM-PROFILES.TXT"
	profilesMax     = 4096
	profileNameMax  = 24
	profileFieldMax = 64
)

// termProfile is one named bundle: the profile's name plus the settings
// keys it declares (font_size/theme/palette_*), in file order — keys and
// values are parallel slices so no key/value record type enters go.type.
type termProfile struct {
	name string
	keys []string
	vals []string
}

// parseProfiles decodes the GOTERM-PROFILES.TXT body. Rows are
// `name.key = value`; `#` and `;` lead comments, blank lines are skipped.
// A name is [a-z0-9_-]{1,24}; an unknown key, an over-long value, or a
// malformed name makes the row drop — never the whole file. Declared
// values are validated against the kernel's own vocabulary for the key.
func parseProfiles(body string) []termProfile {
	var out []termProfile
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		lhs := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		dot := strings.IndexByte(lhs, '.')
		if dot <= 0 || dot > profileNameMax {
			continue
		}
		okName := true
		for i := 0; i < dot; i++ {
			ch := lhs[i]
			okName = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') ||
				ch == '-' || ch == '_'
			if !okName {
				break
			}
		}
		if !okName {
			continue
		}
		name, key := lhs[:dot], lhs[dot+1:]
		if len(val) == 0 || len(val) > profileFieldMax || !profileFieldOK(key, val) {
			continue
		}
		i := len(out)
		for j := range out {
			if out[j].name == name {
				i = j
			}
		}
		if i == len(out) {
			out = append(out, termProfile{name: name})
		}
		// Last assignment wins inside a profile, kernel set semantics.
		set := true
		for j := range out[i].keys {
			if out[i].keys[j] == key {
				out[i].vals[j] = val
				set = false
			}
		}
		if set {
			out[i].keys = append(out[i].keys, key)
			out[i].vals = append(out[i].vals, val)
		}
	}
	return out
}

// profileFieldOK validates a `key = value` row against the kernel's
// vocabulary for the key — the same refusal list GOSET applies, so a
// stored profile cannot write a value the kernel would ignore anyway.
func profileFieldOK(key, val string) bool {
	switch key {
	case "font_size":
		return val == "small" || val == "medium" || val == "large"
	case "theme":
		return val == "dark" || val == "light" || val == "amber" || val == "custom"
	case "palette_fg", "palette_bg", "palette_accent":
		if len(val) != 6 {
			return false
		}
		for i := 0; i < 6; i++ {
			c := val[i]
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return false
			}
		}
		return true
	}
	return false
}

// applyProfileBody merges a profile into a SETTINGS.TXT body: each
// declared key replaces its existing row (first occurrence wins; later
// duplicate rows are dropped, matching the kernel's last-row rule but
// producing one canonical line), undeclared keys are appended, and
// `term_profile=<name>` records the choice. Pure — the write and the
// publish live in the caller.
func applyProfileBody(body string, p *termProfile) string {
	var keep []string
	for _, line := range strings.Split(body, "\n") {
		raw := strings.TrimSuffix(line, "\r")
		eq := strings.IndexByte(raw, '=')
		if eq > 0 {
			key := strings.TrimSpace(raw[:eq])
			replaced := key == "term_profile"
			for j := range p.keys {
				if p.keys[j] == key {
					replaced = true
				}
			}
			if replaced {
				continue
			}
		}
		if strings.TrimSpace(raw) != "" {
			keep = append(keep, raw)
		}
	}
	for j := range p.keys {
		keep = append(keep, p.keys[j]+"="+p.vals[j])
	}
	return strings.Join(keep, "\n") + "\nterm_profile=" + p.name + "\n"
}

// profileCmd decodes a `term-profile` line: (list=true) a bare command,
// (name) the profile to apply — "next"/"prev" ride the name slot and
// linkact resolves them against the file's order — ok=false for anything
// else.
func profileCmd(line string) (name string, list, ok bool) {
	fields := strings.Fields(line)
	if len(fields) == 0 || fields[0] != "term-profile" {
		return "", false, false
	}
	switch len(fields) {
	case 1:
		return "", true, true
	case 2:
		return fields[1], false, true
	}
	return "", false, false
}

// cycleProfile resolves `next` (delta=1) / `prev` (delta=-1) in the file's
// order, wrapping at the ends. An unset or file-absent current enters at
// the head (next) or the tail (prev) — the cycle's entry points.
func cycleProfile(ps []termProfile, cur string, delta int) *termProfile {
	if len(ps) == 0 {
		return nil
	}
	idx := -1
	for i := range ps {
		if ps[i].name == cur {
			idx = i
		}
	}
	switch {
	case idx < 0 && delta >= 0:
		idx = 0
	case idx < 0:
		idx = len(ps) - 1
	case delta >= 0:
		idx = (idx + 1) % len(ps)
	default:
		idx = (idx - 1 + len(ps)) % len(ps)
	}
	return &ps[idx]
}

// resolveRestore picks the profile a blob-saved name asks for: the named
// one, else the file's head — the first profile in file order is the
// default — with fellBack reporting which half fired. An empty file
// resolves to nil.
func resolveRestore(ps []termProfile, saved string) (*termProfile, bool) {
	for i := range ps {
		if ps[i].name == saved {
			return &ps[i], false
		}
	}
	if len(ps) == 0 {
		return nil, false
	}
	return &ps[0], true
}

// profileNamesMarked renders the bare-command list: space-joined names
// with `*` on cur — the active profile as the settings store records it.
func profileNamesMarked(ps []termProfile, cur string) string {
	var names []byte
	for i := range ps {
		if i > 0 {
			names = append(names, ' ')
		}
		if ps[i].name == cur {
			names = append(names, '*')
		}
		names = append(names, ps[i].name...)
	}
	return string(names)
}
