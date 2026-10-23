// Package find is the shared find-in-text matcher (M126c #2595): the
// non-overlapping, left-to-right, byte-exact scan GOEDIT's find bar has
// always run, extracted so WEB's find-in-page searches the same way — one
// matcher, one scan rule, no drift between the two bars.
//
// The search is case-SENSITIVE (at is a byte compare): that is GOEDIT's
// M66c review decision (#1495) for the Zig app it replaced, kept verbatim
// rather than re-litigated as two divergent local rules.
package find

// All returns the byte offset of every non-overlapping match of pat in
// buf, in document order. The scan resumes AFTER each hit, never inside
// it: "ababa" searched for "aba" has one match, not two.
func All(buf, pat []byte) []int {
	if len(pat) == 0 || len(pat) > len(buf) {
		return nil
	}
	var out []int
	for i := 0; i+len(pat) <= len(buf); {
		if at(buf, i, pat) {
			out = append(out, i)
			i += len(pat)
			continue
		}
		i++
	}
	return out
}

// From searches buf for pat from byte offset `from`, and returns the
// number of non-overlapping matches, the 1-based ordinal of the match the
// caret lands on, and that match's offset. The first match at or after
// `from` wins; when there is none the search wraps to the FIRST match
// (the find bar's "search again from the top" rule, and what makes Return
// on a single-match document report hit=1/1). No match returns -1.
func From(buf, pat []byte, from int) (total, ordinal, off int) {
	off, ordinal = -1, 0
	if len(pat) == 0 || len(pat) > len(buf) {
		return 0, 0, -1
	}
	for i := 0; i+len(pat) <= len(buf); {
		if at(buf, i, pat) {
			total++
			if off < 0 && i >= from {
				off, ordinal = i, total
			}
			i += len(pat)
			continue
		}
		i++
	}
	if off < 0 {
		for i := 0; i+len(pat) <= len(buf); i++ {
			if at(buf, i, pat) {
				return total, 1, i
			}
		}
	}
	return total, ordinal, off
}

// at reports whether pat matches at offset off.
func at(buf []byte, off int, pat []byte) bool {
	if off < 0 || len(pat) == 0 || off+len(pat) > len(buf) {
		return false
	}
	for i := 0; i < len(pat); i++ {
		if buf[off+i] != pat[i] {
			return false
		}
	}
	return true
}

// FoldByte is the ASCII case fold the name matchers share: a-z fold onto
// A-Z, every other byte is itself (no Unicode case folding — the same
// plain-bytes rule GOFILES' content walk documents).
func FoldByte(c byte) byte {
	if c >= 'a' && c <= 'z' {
		return c - ('a' - 'A')
	}
	return c
}

// ContainsFold reports whether pat occurs anywhere in s under the ASCII
// fold — the same left-to-right scan shape at() runs, with both sides
// compared folded. It is the predicate a NAME search wants (the
// launcher's filename hits, M191b): callers pass the needle pre-folded
// (FoldByte over each byte) so a per-candidate check stays a scan, never
// a re-fold. The byte-exact All/From stay the editors' rules — a find
// bar honours what the document says, a name lookup honours what the
// user meant.
func ContainsFold(s, patFolded []byte) bool {
	if len(patFolded) == 0 || len(patFolded) > len(s) {
		return false
	}
	for i := 0; i+len(patFolded) <= len(s); i++ {
		ok := true
		for j := 0; j < len(patFolded); j++ {
			if FoldByte(s[i+j]) != patFolded[j] {
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
