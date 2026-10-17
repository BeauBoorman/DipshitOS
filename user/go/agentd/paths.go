// Path validation for the agent sandbox (ADR 0044 D3, M109b bounded
// depth). Pure: the kernel remains the authority on resolution and
// case-insensitive matching; these functions only decide whether the
// typed bytes are a sandbox path at all.
package main

// nameMax is the NAME byte bound per path segment.
const nameMax = 31

// pathMax bounds the whole typed path and pathDepthMax its segment count
// (M109b: bounded depth — SUB/INNER/F.TXT shapes, never deeper). 48 bytes
// leaves "AGENT/<path>" inside the kernel's share-path bound with room for
// the WriteFileSafe "~" temp name.
const (
	pathMax      = 48
	pathDepthMax = 4
)

// auditName is the reserved first segment: AUDIT/ is the receipt lane
// (ADR 0052 D4) — inside the sandbox root but never reachable through
// fs.*, so an agent cannot read or rewrite its own log.
const auditName = "AUDIT"

// validName reports whether s is one sandbox NAME: 1-31 bytes drawn from
// [A-Za-z0-9._-], first byte alphanumeric, and never "." or "..". The
// charset alone excludes every traversal and separator shape ("/", "\",
// "~", NUL, whitespace); the first-byte rule excludes "." and "..".
func validName(s string) bool {
	n := len(s)
	if n == 0 || n > nameMax {
		return false
	}
	if !nameAlnum(s[0]) {
		return false
	}
	for i := 0; i < n; i++ {
		c := s[i]
		if !nameAlnum(c) && c != '.' && c != '_' && c != '-' {
			return false
		}
	}
	return true
}

// validPath reports whether s is a bounded sandbox path: 1..pathDepthMax
// NAME segments joined by "/", total ≤ pathMax bytes, and the first
// segment never the reserved audit lane. Bare names stay valid — the
// grammar strictly extends v1's flat NAME.
func validPath(s string) bool {
	if len(s) == 0 || len(s) > pathMax {
		return false
	}
	depth := 1
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			depth++
		}
	}
	if depth > pathDepthMax {
		return false
	}
	first := s
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			first = s[:i]
			break
		}
	}
	if foldEq(first, auditName) {
		return false
	}
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == '/' {
			if !validName(s[start:i]) {
				return false
			}
			start = i + 1
		}
	}
	return true
}

// parentOf splits a validated path into its parent directory ("" for a
// bare NAME — the sandbox root itself) and its last segment.
func parentOf(s string) (parent, last string) {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '/' {
			return s[:i], s[i+1:]
		}
	}
	return "", s
}

func nameAlnum(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}
