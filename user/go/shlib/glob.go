// Glob expansion (M98a, issue #2127): unquoted `*`, `?` and `[...]` words
// expand against the PWD's directory listing before dispatch. The matcher
// is control.go's globMatch — the same fnmatch dialect `case` arms use —
// driven over a flag vector that says which bytes of the word are
// pattern-active: a `*` that arrived quoted, escaped, or inside a $VAR or
// $(...) value is a literal byte, never a wildcard.
package shlib

import (
	"errors"
	"sort"
	"strings"

	"virelai/vi"
	"virelai/vsys"
)

// dirLister is the OPTIONAL host capability glob expansion needs: a
// path-aware directory listing of a canonical directory (vi.ListDirAt —
// the slot-79 paged snapshot for host paths, the legacy window for USB).
// A host without it leaves glob words literal, the pre-M98a behavior.
type dirLister interface {
	ListPath(dir string) ([]vi.DirItem, error)
}

// globFunc expands one expanded word into zero-or-more argv words; it is
// the Shell hook parsePlan carries so the parser stays seam-free.
type globFunc func(word string, act []bool) ([]string, error)

// active reports whether pattern byte i is glob-significant. A nil vector
// means every byte is active — the unflagged matcher path `case` uses.
func active(act []bool, i int) bool { return act == nil || act[i] }

// expandMarked is expand's twin: the same walk, but every emitted byte is
// flagged glob-active or glob-literal. escMark-quoted bytes and anything
// produced by a $ expansion are literal; bytes the user typed bare are
// active. The flag vector is what stops `set X='*'; cat $X` from globbing
// and what lets an unquoted `*.TXT` expand.
func expandMarked(t token, env *Env, status int) (string, []bool) {
	var b strings.Builder
	var act []bool
	put := func(c byte, a bool) { b.WriteByte(c); act = append(act, a) }
	putStr := func(s string, a bool) {
		for i := 0; i < len(s); i++ {
			put(s[i], a)
		}
	}
	s := t.text
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == escMark:
			if i+1 < len(s) {
				put(s[i+1], false)
				i += 2
			} else {
				i++
			}
		case c == '$' && i+1 < len(s) && s[i+1] == '?':
			putStr(vsys.Itoa64(int64(status)), false)
			i += 2
		case c == '$' && i+1 < len(s) && s[i+1] == '{':
			end := strings.IndexByte(s[i+2:], '}')
			if end < 0 {
				put(c, true)
				i++
				continue
			}
			name := s[i+2 : i+2+end]
			if v, ok := env.Get(name); ok {
				putStr(v, false)
			}
			i = i + 2 + end + 1
		case c == '$':
			j := i + 1
			for j < len(s) && isNameByte(s[j]) {
				j++
			}
			if j == i+1 {
				put(c, true)
				i++
				continue
			}
			if v, ok := env.Get(s[i+1 : j]); ok {
				putStr(v, false)
			}
			i = j
		default:
			put(c, true)
			i++
		}
	}
	return b.String(), act
}

// marksToFlags resolves escMark pairs in raw engine text — a for-list
// word or a case arm pattern, both of which reach the matcher without
// passing through tokenize/expand. A marked byte is literal; the marks
// themselves are consumed (they are artifacts of $(...) splicing, not
// user data, and must not leak into variable values).
func marksToFlags(text string) (string, []bool) {
	if strings.IndexByte(text, escMark) < 0 {
		return text, nil
	}
	b := make([]byte, 0, len(text))
	var act []bool
	for i := 0; i < len(text); i++ {
		if text[i] == escMark && i+1 < len(text) {
			b = append(b, text[i+1])
			act = append(act, false)
			i++
			continue
		}
		b = append(b, text[i])
		act = append(act, true)
	}
	return string(b), act
}

// markGlobLiteral escMark-prefixes every glob-significant byte in
// captured $(...) output. Substitution is a textual splice, so an output
// `*` would otherwise arrive at the tokenizer unquoted and glob a second
// time — the index's hard rule is that captured text never re-globs. The
// marked set covers the class-significant bytes too (`]`, `-`, `!`, `^`)
// for the same reason an output byte must not complete a typed `[...]`.
func markGlobLiteral(s string) string {
	if !strings.ContainsAny(s, "*?[]-!^") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '*', '?', '[', ']', '-', '!', '^':
			b.WriteByte(escMark)
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// hasGlobMeta reports whether pat is a glob pattern: an unquoted `*` or
// `?`, or an unquoted `[` with an unquoted `]` closing it later in the
// same word (the M19 subset has no escaping inside classes).
func hasGlobMeta(pat string, act []bool) bool {
	for i := 0; i < len(pat); i++ {
		if !active(act, i) {
			continue
		}
		switch pat[i] {
		case '*', '?':
			return true
		case '[':
			for j := i + 1; j < len(pat); j++ {
				if pat[j] == ']' && active(act, j) {
					return true
				}
			}
		}
	}
	return false
}

// globSplit splits a word into its directory part (typed, kept verbatim
// for output) and final-component pattern. ok=false means the word is not
// a glob: no active metacharacter, or a metacharacter OUTSIDE the final
// component (`*/X` stays literal — one listing serves one component).
func globSplit(word string, act []bool) (dir, pat string, patAct []bool, ok bool) {
	slash := strings.LastIndexByte(word, '/')
	dir, pat, patAct = "", word, act
	if slash >= 0 {
		dir, pat, patAct = word[:slash+1], word[slash+1:], act[slash+1:]
	}
	if !hasGlobMeta(pat, patAct) {
		return "", "", nil, false
	}
	for i := 0; i <= slash && slash >= 0; i++ {
		if active(act, i) && (word[i] == '*' || word[i] == '?' || word[i] == '[') {
			return "", "", nil, false
		}
	}
	return dir, pat, patAct, true
}

// globLimitError is the line refusal for a directory too large to list
// whole (vi.ErrTreeLimit): the same named refusal whether the slot-79
// snapshot hit 256 or the USB fallback window filled.
func globLimitError(dirPart, canon string) error {
	show := strings.TrimSuffix(dirPart, "/")
	if show == "" {
		show = canon
	}
	return errors.New("gosh: glob: " + show + ": more than 256 entries")
}

// globWord expands one pattern word against the PWD listing. It returns
// {word} unchanged for a non-pattern, a missing lister, an unlistable
// directory (ENOENT, EACCES — all folded into "no match"), or an empty
// match set; the only error is the named too-many-entries refusal.
func (s *Shell) globWord(word string, act []bool) ([]string, error) {
	dirPart, pat, patAct, ok := globSplit(word, act)
	if !ok {
		return []string{word}, nil
	}
	lister, ok := s.host.(dirLister)
	if !ok {
		return []string{word}, nil
	}
	// The directory part resolves against PWD like every path argument;
	// the emitted words keep the user's spelling of it (docs/*.TXT lists
	// /pwd/docs but answers docs/A.TXT).
	dirArg := strings.TrimSuffix(dirPart, "/")
	if dirArg == "" {
		dirArg = "."
		if dirPart != "" {
			dirArg = "/"
		}
	}
	rp, err := s.resolvePath(dirArg)
	if err != nil {
		return []string{word}, nil
	}
	items, err := lister.ListPath(rp.canon)
	if err != nil {
		if errors.Is(err, vi.ErrTreeLimit) {
			return nil, globLimitError(dirPart, rp.canon)
		}
		return []string{word}, nil
	}
	// `*`/`?`/classes do not match a leading dot unless the pattern's own
	// first byte is a literal `.` — the same rule fnmatch pins.
	dotOK := len(pat) > 0 && pat[0] == '.'
	var out []string
	for _, it := range items {
		if it.Name == "" || (it.Name[0] == '.' && !dotOK) {
			continue
		}
		if globMatchFlagged(pat, patAct, it.Name) {
			out = append(out, dirPart+it.Name)
		}
	}
	if len(out) == 0 {
		return []string{word}, nil
	}
	sort.Strings(out)
	return out, nil
}

// forWordExpand runs the for-list's own glob pass: parseFor splits its
// words as raw text and runFor iterates them, so the expansion has to
// happen here rather than in parsePlan. The words carry escMark pairs
// when a $(...) splice landed inside a construct body; marksToFlags turns
// those into literal flags AND cleans the artifact bytes out of the
// values the loop variable sees.
func (s *Shell) forWordExpand(raw []string) ([]string, error) {
	var out []string
	for _, w := range raw {
		word, act := marksToFlags(w)
		words, err := s.globWord(word, act)
		if err != nil {
			return nil, err
		}
		out = append(out, words...)
	}
	return out, nil
}

// globExemptHead reports whether word w in a command headed by head is
// exempt from globbing: the NAME=VALUE arguments of set/export/alias keep
// their metacharacters literal — `set PAT=*` must store `*`, not the
// first file it happens to match.
func globExemptHead(head, w string) bool {
	switch head {
	case "set", "export", "alias":
		return strings.IndexByte(w, '=') >= 0
	}
	return false
}
