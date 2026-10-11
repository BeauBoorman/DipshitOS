package shlib

import (
	"strings"
	"unicode/utf8"

	"virelai/vsys"
)

// Prompt escapes (M80n #1730). The SETTINGS.TXT `prompt=` value is a
// TEMPLATE: it stays the persisted form, and expansion happens at paint, so
// `prompt=\w` follows the shell across a cd without anyone rewriting the
// file. Both front-ends share this one implementation -- term/main.go had the
// loader extracted and sh/main.go had its own inlined copy of the same loop.

// PromptFacts is everything a prompt escape can ask about. A front-end fills
// it in from what it already knows: the shell's PWD, the host's principal,
// and the hostname from the same SETTINGS.TXT the prompt came from.
type PromptFacts struct {
	// User is the principal's kind, the words `id` prints (PromptUserName).
	User string
	// Host is the machine name (SETTINGS.TXT `hostname=`).
	Host string
	// Cwd is the working directory the shell tracks as PWD.
	Cwd string
	// Home is the prefix `\w` shortens to `~`. Empty on this system, which
	// seeds no HOME -- and an unset Home means the cwd is shown as it is
	// rather than pretending the share root is somebody's home directory.
	Home string
	// Root is the system principal, which `\u` calls "system" and `\$`
	// answers with "#".
	Root bool
	// Status is the last line's exit status, `$?`, for `\?` (M98h).
	Status int
	// DurationNs is the last line's wall time in nanoseconds, for `\D`.
	DurationNs int64
}

// The glyphs the privilege and home escapes produce. `#` for the system
// principal is the readline convention; "system" is this system's word for
// what a Unix calls root.
const (
	promptRootGlyph = "#"
	promptUserGlyph = "$"
	promptHomeGlyph = "~"
)

// ExpandPrompt expands the escapes a prompt template may use:
//
//	\u   the principal's kind: "system" or "user" (PromptUserName)
//	\h   the host name
//	\w   the working directory, shortened to ~ against PromptFacts.Home
//	\W   the last component of \w; the share root stays "/"
//	\$   the privilege glyph: "#" for the system principal, "$" otherwise
//	\?   the last line's exit status, decimal
//	\D   the last line's wall time: 0.4s, 12s, 3m04s, 1h02m
//	\[   a non-printing span opens: copied through, never expanded, and
//	\]   measured as zero cells
//	\\   a literal backslash
//
// A CSI sequence (ESC [ ... final -- the SGR colour codes the grid already
// understands) is copied through untouched: the terminal paints it and
// VisibleWidth does not count it. An unrecognised escape is copied through as
// written, so a prompt spelling something this expander does not know shows
// the user what they typed instead of silently losing a character.
func ExpandPrompt(tmpl string, f PromptFacts) string {
	if !strings.ContainsRune(tmpl, '\\') && !strings.ContainsRune(tmpl, 0x1b) {
		return tmpl // the common plain prompt, byte for byte
	}
	out := make([]byte, 0, len(tmpl)+16)
	marked := false // inside \[ ... \]: literal, and zero cells wide
	for i := 0; i < len(tmpl); {
		b := tmpl[i]
		switch {
		case b == 0x1b:
			j := skipCSI(tmpl, i)
			out = append(out, tmpl[i:j]...)
			i = j
		case b == '\\':
			if i+1 >= len(tmpl) {
				out = append(out, b) // a trailing backslash is just a backslash
				i++
				continue
			}
			c := tmpl[i+1]
			i += 2
			switch {
			case c == ']' && marked:
				marked = false // the one escape a span must honour
			case marked:
				out = append(out, '\\', c) // literal inside the span
			case c == 'u':
				out = append(out, f.User...)
			case c == 'h':
				out = append(out, f.Host...)
			case c == 'w':
				out = append(out, shortenHome(f.Cwd, f.Home)...)
			case c == 'W':
				out = append(out, baseName(f.Cwd)...)
			case c == '$':
				out = append(out, privilegeGlyph(f.Root)...)
			case c == '?':
				out = append(out, vsys.Itoa64(int64(f.Status))...)
			case c == 'D':
				out = append(out, formatDuration(f.DurationNs)...)
			case c == '[':
				marked = true
			case c == ']':
				// A closing bracket with nothing open: drop it, the way
				// the opening one is dropped.
			case c == '\\':
				out = append(out, '\\')
			default:
				out = append(out, '\\', c) // unknown: show it as written
			}
		case marked:
			out = append(out, b)
			i++
		default:
			out = append(out, b)
			i++
		}
	}
	return string(out)
}

// defaultHostName is the hostname the kernel seeds into SETTINGS.TXT
// (settings.KnownKeys carries the same default), so a `\h` prompt has
// something to say when the key is absent.
const defaultHostName = "virelai"

// PromptHost is `\h`: the hostname from the same SETTINGS.TXT body the prompt
// came from.
func PromptHost(body string) string {
	return SettingFromSettings(body, "hostname", defaultHostName)
}

// PromptFactsFor builds the provider both front-ends hand the editor, so `\u`
// and `\$` cannot drift between GOSH and GOTERM. The principal is a method
// value rather than a result because the answer is read once per line, not
// once at startup: the kernel owns the principal, and a shell that lost it
// should say "user" rather than freeze a stale uid in its prompt.
func PromptFactsFor(sh *Shell, principal func() (uid uint32, caps uint32, ok bool), host string) func() PromptFacts {
	return func() PromptFacts {
		f := PromptFacts{Host: host, User: PromptUserName(0, false)}
		if sh != nil {
			f.Cwd = sh.Pwd()
			f.Status = sh.status
			f.DurationNs = sh.lastDurNs
		}
		if uid, _, ok := principal(); ok {
			f.User = PromptUserName(uid, true)
			f.Root = uid == uidSystem
		}
		return f
	}
}

// PromptUserName is `\u`: the same two words `id` prints for the principal
// (principalKind), so the prompt and `id` cannot disagree. This system has no
// user database, so inventing a name would be a fiction; the decimal uid is
// what `id` and `whoami` are for.
func PromptUserName(uid uint32, ok bool) string {
	if ok && uid == uidSystem {
		return "system"
	}
	return "user"
}

// privilegeGlyph is `\$`.
func privilegeGlyph(root bool) string {
	if root {
		return promptRootGlyph
	}
	return promptUserGlyph
}

// shortenHome is `\w`'s `~` shortening. With no Home to shorten against the
// cwd is shown as it is.
func shortenHome(cwd, home string) string {
	if home == "" || home == "/" || cwd == "" {
		return cwd
	}
	if cwd == home {
		return promptHomeGlyph
	}
	if strings.HasPrefix(cwd, home) && len(cwd) > len(home) && cwd[len(home)] == '/' {
		return promptHomeGlyph + cwd[len(home):]
	}
	return cwd
}

// baseName is `\W`. The share root stays "/" rather than collapsing to the
// empty string `pwd` never prints.
func baseName(p string) string {
	if p == "" {
		return ""
	}
	p = strings.TrimRight(p, "/")
	if p == "" {
		return "/"
	}
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		return p[i+1:]
	}
	return p
}

// VisibleWidth is how many grid cells s paints. The grid is rune-based --
// Screen.putByte decodes UTF-8 and putRune stores one cell per rune -- so
// this counts RUNES, not bytes: a prompt carrying one accented character is
// one cell wider than its byte length suggests, and the line editor's tail
// math has to agree with the grid or it overwrites the wrong number of cells.
//
// Bracket-marked spans and CSI sequences paint nothing and count zero, so the
// same function measures an expanded prompt and a raw template.
func VisibleWidth(s string) int {
	w := 0
	marked := false
	for i := 0; i < len(s); {
		b := s[i]
		switch {
		case b == 0x1b:
			i = skipCSI(s, i)
		case b == '\\' && i+1 < len(s) && (s[i+1] == '[' || s[i+1] == ']'):
			marked = s[i+1] == '['
			i += 2
		case marked:
			i++
		default:
			_, size := utf8.DecodeRuneInString(s[i:])
			if size < 1 {
				size = 1 // invalid UTF-8: one cell, and keep going
			}
			w++
			i += size
		}
	}
	return w
}

// skipCSI returns the end of the CSI sequence starting at i, or i+1 when the
// ESC introduces no sequence. A CSI is ESC [ parameters final, with the final
// byte in 0x40..0x7e -- the same shape the editor's own decoder eats, so a
// colour code ends where the line editor would end it.
func skipCSI(s string, i int) int {
	if i+1 >= len(s) || s[i+1] != '[' {
		return i + 1
	}
	j := i + 2
	for j < len(s) && (s[j] < 0x40 || s[j] > 0x7e) {
		j++
	}
	if j < len(s) {
		return j + 1
	}
	return len(s)
}

// SettingFromSettings returns the first `key=` value in a SETTINGS.TXT body,
// trimmed, or def when the key is absent or its value is empty.
func SettingFromSettings(body, key, def string) string {
	prefix := key + "="
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, prefix) {
			if v := strings.TrimSpace(line[len(prefix):]); v != "" {
				return v
			}
		}
	}
	return def
}

// PromptFromSettings is the prompt loader both front-ends share: the first
// `prompt=` value, trimmed, plus the single trailing space the loader has
// always appended. The space belongs to the loader, not the template, so
// `prompt=\w` does not need one written out by hand.
func PromptFromSettings(body, def string) string {
	if v := SettingFromSettings(body, "prompt", ""); v != "" {
		return v + " "
	}
	return def
}
