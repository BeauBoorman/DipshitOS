// NAME validation for the agent sandbox (ADR 0044 D3). Pure: the kernel
// remains the authority on resolution and case-insensitive matching; this
// function only decides whether the typed bytes are a NAME at all.
package main

// nameMax is the NAME byte bound. Resolved paths are "AGENT/<NAME>" (at
// most 43 bytes), which leaves room for the WriteFileSafe "~" temp name.
const nameMax = 31

// validName reports whether s is a sandbox NAME: 1-31 bytes drawn from
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

func nameAlnum(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}
