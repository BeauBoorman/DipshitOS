package vi

// M117c (#2475, ADR 0057): the IPv6 literal seam — `vi.Dial` accepts a
// bracketed or bare v6 literal, `ping6` accepts a bare one. The parser
// mirrors kernel/src/ipv6.zig `parse_ip6`: full eight-group form or ONE
// `::` compression; hex groups of 1–4 digits. Dotted-quad tails (the
// mapped/compat forms) are NOT parsed — D8 refuses IPv4-mapped literals
// rather than translating them, so "::ffff:10.0.0.2" fails here and a
// hex-form mapped address is refused by the kernel as `bad_dst6`.

import (
	"strings"
)

// ErrBadV6 is the parse refusal every malformed literal shares.
var ErrBadV6 = errString("vi: malformed IPv6 literal")

// isBadV6Dst reports whether a v6 destination is one the guest never
// originates — the kernel's `is_bad_dst` set (kernel/src/ipv6.zig):
// multicast (ff00::/8), the unspecified address (:: — the v6
// passive-open zero), loopback (::1), and the IPv4-mapped form. The
// kernel refuses these EINVAL at connect; the resolver checks earlier
// so an AAAA answer of nothing but undialable records earns the named
// refusal instead of a socket op (M184a, #3174).
func isBadV6Dst(a [16]byte) bool {
	if a[0] == 0xff {
		return true // multicast
	}
	if a == ([16]byte{}) {
		return true // unspecified
	}
	if a == [16]byte{15: 1} {
		return true // ::1 loopback
	}
	// ::ffff:a.b.c.d — the mapped form, refused never translated.
	return a[10] == 0xff && a[11] == 0xff && [10]byte(a[:10]) == [10]byte{}
}

// IsV6Literal reports whether s names a v6 address — a bracketed
// `[x::y]` form or a bare literal containing ':'. A dotted quad never
// qualifies, so this is safe to run before ParseIPv4.
func IsV6Literal(s string) bool {
	if len(s) >= 2 && s[0] == '[' {
		return true
	}
	return strings.ContainsRune(s, ':')
}

// ParseIPv6 parses a v6 literal — bare `x::y` or bracketed `[x::y]` —
// into the wire-order 16 bytes.
func ParseIPv6(s string) ([16]byte, error) {
	var out [16]byte
	if len(s) >= 2 && s[0] == '[' {
		if s[len(s)-1] != ']' {
			return out, ErrBadV6
		}
		s = s[1 : len(s)-1]
	}
	if s == "" || strings.ContainsRune(s, '.') || strings.ContainsRune(s, '%') {
		return out, ErrBadV6
	}
	// Find the single "::" elision, if any.
	dbl := -1
	for i := 0; i+1 < len(s); i++ {
		if s[i] == ':' && s[i+1] == ':' {
			if dbl >= 0 {
				return out, ErrBadV6 // a second ::
			}
			dbl = i
			i++
		}
	}
	head, tail := s, ""
	if dbl >= 0 {
		head, tail = s[:dbl], s[dbl+2:]
	}
	var groups [8]uint16
	hn, ok := v6Groups(head, &groups)
	if !ok {
		return out, ErrBadV6
	}
	var tailGroups [8]uint16
	tn, ok := v6Groups(tail, &tailGroups)
	if !ok {
		return out, ErrBadV6
	}
	if dbl < 0 {
		if hn != 8 {
			return out, ErrBadV6 // no compression: exactly 8 groups
		}
	} else if hn+tn > 7 {
		return out, ErrBadV6 // "::" must elide at least one group
	}
	for i := 0; i < hn; i++ {
		out[2*i] = byte(groups[i] >> 8)
		out[2*i+1] = byte(groups[i])
	}
	for i := 0; i < tn; i++ {
		out[16-2*tn+2*i] = byte(tailGroups[i] >> 8)
		out[16-2*tn+2*i+1] = byte(tailGroups[i])
	}
	return out, nil
}

// v6Groups parses a colon-separated run of hex groups into g[0..n].
// An empty part contributes zero groups (the edges of "::").
func v6Groups(part string, g *[8]uint16) (int, bool) {
	if part == "" {
		return 0, true
	}
	n := 0
	for _, piece := range strings.Split(part, ":") {
		if n >= 8 {
			return 0, false
		}
		v, ok := v6Group(piece)
		if !ok {
			return 0, false
		}
		g[n] = v
		n++
	}
	return n, true
}

// v6Group parses one 1–4 digit hex group.
func v6Group(s string) (uint16, bool) {
	if len(s) == 0 || len(s) > 4 {
		return 0, false
	}
	var v uint16
	for i := 0; i < len(s); i++ {
		c := s[i]
		var d uint16
		switch {
		case c >= '0' && c <= '9':
			d = uint16(c - '0')
		case c >= 'a' && c <= 'f':
			d = uint16(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = uint16(c-'A') + 10
		default:
			return 0, false
		}
		v = v<<4 | d
	}
	return v, true
}
