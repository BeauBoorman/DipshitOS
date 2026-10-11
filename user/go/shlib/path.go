// Path resolution for the real PWD (M98j, issue #2136). One resolver —
// (*Shell).resolvePath — sits between every path-taking verb and the host
// seam, so `cd` canonicalizes and cat, the tools, redirects, source,
// `test -e`, chmod and open all resolve against the working directory the
// prompt shows instead of silently landing on the share root.
//
// The kernel still owns the final word: its parse_path (kernel/src/
// file_table.zig) strips leading slashes, collapses `//`, routes the
// host/usbN volumes and refuses `..`, so the resolver's job is only the
// part the kernel cannot do — PWD-relative join — plus a LEXICAL `..` so
// the kernel never sees one. Every bound is a loud refusal by name, never
// a truncation.
package shlib

import (
	"errors"
	"strings"
)

// The kernel's file-ABI bounds (file_table.max_path_len = directory.path_max,
// directory.name_max): a path the host receives must fit the first, and each
// of its components the second. The card's 64-byte figure predates B2's
// (#1869) directory snapshot ABI, which raised the bound to 512.
const (
	maxPathBytes = 512
	maxNameBytes = 255
)

var (
	errPathTooLong = errors.New("path too long")
	errNameTooLong = errors.New("name too long")
	errInvalidPath = errors.New("invalid path")
)

// resolvedPath is one argument after resolution: canon is the /-rooted
// canonical form (what PWD itself stores — `/`, `/data`, `/usb1/DOCS`),
// host is what the host seam receives. They differ only under the
// pass-through rule: when the typed bytes already name the same file the
// kernel would open — an absolute path with no `.`/`..` component, or a
// relative one with none while PWD is `/` — the host gets the typed path
// verbatim, so a session at the share root stays byte-identical to the
// pre-resolver behavior every existing gate pins.
type resolvedPath struct {
	canon string
	host  string
}

// resolvePath canonicalizes p against PWD. A refusal names the problem
// (path too long, name too long, invalid path); the caller reports it
// against the path AS TYPED, because the user typed that path — the
// resolved form is never the surprising one.
func (s *Shell) resolvePath(p string) (resolvedPath, error) {
	canon, err := canonPath(s.Pwd(), p)
	if err != nil {
		return resolvedPath{}, err
	}
	host := canon
	// The pass-through check needs the PWD's canonical form too: a
	// user-set `PWD=/host` is the share root, not a moved directory.
	pwd, perr := canonPath("/", s.Pwd())
	if perr == nil && passThrough(pwd, p) {
		host = p
	}
	if len(host) > maxPathBytes {
		return resolvedPath{}, errPathTooLong
	}
	return resolvedPath{canon: canon, host: host}, nil
}

// resolveDenial renders a resolvePath refusal for a message slot, or ""
// when err is not a resolution failure — the site's ordinary error shape
// applies then.
func resolveDenial(err error) string {
	switch {
	case errors.Is(err, errPathTooLong),
		errors.Is(err, errNameTooLong),
		errors.Is(err, errInvalidPath):
		return err.Error()
	}
	return ""
}

// canonPath joins p onto pwd and returns the canonical /-rooted form:
// components folded (`.` dropped, `..` resolved lexically and clamped at
// the volume root — the kernel refuses `..`, so one must never reach it),
// `/host` and `host:` mapped to the share root, `usb`/`usbN` kept as
// volume roots. It is pure: no seam calls, so the table test owns it.
func canonPath(pwd, p string) (string, error) {
	if p == "" || strings.IndexByte(p, 0) >= 0 {
		return "", errInvalidPath
	}
	var base, comps []string
	if vol, rest, ok := volumePrefix(p); ok {
		// `vol:rest` names the volume root regardless of PWD.
		base, comps = vol, splitPath(rest)
	} else {
		comps = splitPath(p)
		switch {
		case len(comps) > 0 && strings.EqualFold(comps[0], "host"):
			// `host/...` is kernel-native for the share root, so a leading
			// `host` component is a volume form wherever it is typed — never
			// a directory under PWD. (`./host` still reaches one literally.)
			base, comps = nil, comps[1:]
		case len(comps) > 0 && isUsbVolume(comps[0]):
			base, comps = []string{strings.ToLower(comps[0])}, comps[1:]
		case p[0] == '/':
			base = nil
		default:
			b, err := canonBase(pwd)
			if err != nil {
				return "", err
			}
			base = b
		}
	}
	for _, c := range comps {
		switch c {
		case ".":
		case "..":
			if len(base) > 0 {
				base = base[:len(base)-1]
			}
		default:
			base = append(base, c)
		}
	}
	out := "/" + strings.Join(base, "/")
	for _, c := range base {
		if len(c) > maxNameBytes {
			return "", errNameTooLong
		}
	}
	return out, nil
}

// canonBase renders an already-rooted string (PWD or a user-set value that
// claims to be one) as canonical components, applying the same fold and
// volume rules a typed path gets. A missing leading slash is read as the
// root rather than as a relative join onto itself.
func canonBase(s string) ([]string, error) {
	if strings.IndexByte(s, 0) >= 0 {
		return nil, errInvalidPath
	}
	comps := splitPath(s)
	var base []string
	switch {
	case len(comps) > 0 && strings.EqualFold(comps[0], "host"):
		comps = comps[1:]
	case len(comps) > 0 && isUsbVolume(comps[0]):
		base = append(base, strings.ToLower(comps[0]))
		comps = comps[1:]
	}
	for _, c := range comps {
		switch c {
		case ".":
		case "..":
			if len(base) > 0 {
				base = base[:len(base)-1]
			}
		default:
			if len(c) > maxNameBytes {
				return nil, errNameTooLong
			}
			base = append(base, c)
		}
	}
	return base, nil
}

// splitPath splits s on '/' dropping empty components (`//` collapses, a
// trailing slash disappears — the kernel's own normalizer does the same).
func splitPath(s string) []string {
	var out []string
	for _, c := range strings.Split(s, "/") {
		if c != "" {
			out = append(out, c)
		}
	}
	return out
}

// isUsbVolume reports whether comp names a kernel volume root: `usb` (the
// raw block-device partition) or `usbN` for N in 1..9 — the kernel
// recognizes the whole range and refuses 5..9 by name; `usb0` stays an
// ordinary host-share name, matching usbVolumeForm's boundary rule.
func isUsbVolume(comp string) bool {
	if strings.EqualFold(comp, "usb") {
		return true
	}
	return len(comp) == 4 && strings.EqualFold(comp[:3], "usb") &&
		comp[3] >= '1' && comp[3] <= '9'
}

// volumePrefix recognizes the `vol:rest` form at the head of p: `host:`,
// `usb:` and `usbN:` (kernel parse_path volume routing). A colon later
// than the first component boundary is an ordinary character.
func volumePrefix(p string) (vol []string, rest string, ok bool) {
	i := strings.IndexByte(p, ':')
	if i <= 0 || strings.IndexByte(p[:i], '/') >= 0 {
		return nil, "", false
	}
	switch v := p[:i]; {
	case strings.EqualFold(v, "host"):
		return nil, p[i+1:], true
	case isUsbVolume(v):
		return []string{strings.ToLower(v)}, p[i+1:], true
	}
	return nil, "", false
}

// passThrough reports whether the typed path can go to the host
// byte-for-byte: nothing about it needs rewriting. That is an absolute
// path with no `.`/`..` component, a relative one with none while PWD is
// `/` — at the share root the kernel resolves the typed bytes to the
// same file the canonical form would — and a kernel-native volume form
// (`host/...`, `host:...`, `usb...`), which parse_path routes to its
// partition regardless of PWD. Keeping them keeps every gate that pins a
// typed name byte-identical.
func passThrough(pwd, p string) bool {
	if hasDotComponent(p) {
		return false
	}
	if p[0] == '/' || pwd == "/" {
		return true
	}
	if _, _, ok := volumePrefix(p); ok {
		return true
	}
	comps := splitPath(p)
	return len(comps) > 0 &&
		(strings.EqualFold(comps[0], "host") || isUsbVolume(comps[0]))
}

// hasDotComponent reports whether p carries a `.` or `..` component —
// the only shapes canonicalization must rewrite. A `..` inside a name
// (`a..b`) is not a component; the kernel accepts those names.
func hasDotComponent(p string) bool {
	for _, c := range splitPath(p) {
		if c == "." || c == ".." {
			return true
		}
	}
	return false
}

// hasScheme reports whether p carries an RFC 3986-style scheme prefix —
// the same test mime.urlScheme applies — so `open` can tell a file path
// (resolve it) from a URL or volume-colon form (mime's own routing owns
// those).
func hasScheme(p string) bool {
	i := strings.IndexByte(p, ':')
	if i <= 0 || strings.ContainsAny(p[:i], "/?#") {
		return false
	}
	for j := 0; j < i; j++ {
		c := p[j]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		case j > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'):
		default:
			return false
		}
	}
	return true
}
