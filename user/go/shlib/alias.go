// Command aliases (M98b, issue #2128): a per-session table on Shell plus
// head-word expansion in runSegment — the single choke point every simple
// command reaches (typed lines, chain segments, if/for/while bodies,
// function bodies at call time, source and startup lines; the owner
// decision in the card).
//
// One engine, one rule: an unquoted head word naming an alias is replaced
// by its value before the segment is tokenized, so the value's words
// behave exactly as if typed — globbing included (M98a runs later, in
// parsePlan). Two candidates per segment: the head word, and the head
// word after the single unquoted |.
package shlib

import (
	"errors"
	"sort"
	"strings"

	"virelai/vsys"
)

// The table bounds. A personal shell refuses loudly past them rather than
// silently dropping entries or bytes — the same rule as every other
// bounded structure in the engine.
const (
	aliasMax       = 16
	aliasNameMax   = 32
	aliasValueMax  = 256
	aliasNameChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"
)

var errAliasLineTooLong = errors.New("gosh: alias expansion exceeds the " +
	vsys.Itoa64(maxLineBytes) + "-byte line limit")

// aliasNames is the sorted-name accessor M98g's completion needs (and the
// `alias` listing's order).
func (s *Shell) aliasNames() []string {
	names := make([]string, 0, len(s.aliases))
	for n := range s.aliases {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// validAliasName enforces the name bound: 1..32 bytes of [A-Za-z0-9_.-].
func validAliasName(name string) (string, bool) {
	if len(name) == 0 {
		return "gosh: alias: invalid name", false
	}
	if len(name) > aliasNameMax {
		return "gosh: alias: name exceeds " + vsys.Itoa64(aliasNameMax) + " bytes", false
	}
	if strings.Trim(name, aliasNameChars) != "" {
		return "gosh: alias: " + name + ": invalid name", false
	}
	return "", true
}

// validAliasValue enforces the value bound and the one-command rule: no
// `;`, `&&` or `||`, and no trailing `&`, so an expansion never escapes
// its segment into a chain or a backgrounding the parse would refuse
// differently. A single `|` is fine — the shell allows one pipe.
func validAliasValue(v string) (string, bool) {
	if len(v) > aliasValueMax {
		return "gosh: alias: value exceeds " + vsys.Itoa64(aliasValueMax) + " bytes", false
	}
	if strings.ContainsAny(v, ";") || strings.Contains(v, "&&") ||
		strings.Contains(v, "||") || strings.HasSuffix(v, "&") {
		return "gosh: alias: value must be one command (no ; && || &)", false
	}
	return "", true
}

// setAlias defines or replaces one entry, enforcing every bound. A
// replacement never counts against the table cap.
func (s *Shell) setAlias(name, val string) string {
	if msg, ok := validAliasName(name); !ok {
		return msg
	}
	if msg, ok := validAliasValue(val); !ok {
		return msg
	}
	if s.aliases == nil {
		s.aliases = map[string]string{}
	}
	if _, exists := s.aliases[name]; !exists && len(s.aliases) >= aliasMax {
		return "gosh: alias: table full (at most " + vsys.Itoa64(aliasMax) + " entries)"
	}
	s.aliases[name] = val
	return ""
}

// expandAliases applies alias substitution to a chain segment's text and
// returns the rewritten line — or the line unchanged when nothing names
// an alias. The only failure is the post-expansion line-length refusal.
func (s *Shell) expandAliases(seg string) (string, error) {
	if len(s.aliases) == 0 {
		return seg, nil
	}
	out := s.expandAliasHead(seg, 0, map[string]bool{})
	if i := unquotedPipe(out); i >= 0 {
		// The post-pipe head is an independent position: its own visited
		// set, so `hi | hi` expands both halves like bash does.
		out = s.expandAliasHead(out, i+1, map[string]bool{})
	}
	if len(out) > maxLineBytes {
		return "", errAliasLineTooLong
	}
	return out, nil
}

// expandAliasHead replaces the first word at-or-after `from` when it
// names an unvisited alias, then re-examines the word the value produced
// — the visited set is bash's cycle rule: `a`->`b`->`a` stops at the
// second `a`, and `x`->`x ...` stops after one step. A word containing
// any quote or backslash is verbatim user text and never a candidate.
func (s *Shell) expandAliasHead(seg string, from int, visited map[string]bool) string {
	i := from
	for i < len(seg) && (seg[i] == ' ' || seg[i] == '\t') {
		i++
	}
	start := i
	for i < len(seg) && !strings.ContainsRune(" \t|&<>", rune(seg[i])) {
		i++
	}
	head := seg[start:i]
	if head == "" || strings.ContainsAny(head, `'"`+"\\") {
		return seg
	}
	val, ok := s.aliases[head]
	if !ok || visited[head] {
		return seg
	}
	visited[head] = true
	next := seg[:start] + val + seg[i:]
	// Re-scan from the value's own first word: that is the new head, and
	// it is a fresh candidate (a=b; b=a walks back one hop and stops).
	return s.expandAliasHead(next, start, visited)
}

// unquotedPipe returns the index of the segment's first unquoted `|` —
// the one parsePlan will treat as the pipe — or -1. Quoting follows the
// tokenizer's rules ('…' fully literal, "…" allows $, \x escapes).
func unquotedPipe(s string) int {
	i := 0
	for i < len(s) {
		switch s[i] {
		case '\'':
			j := strings.IndexByte(s[i+1:], '\'')
			if j < 0 {
				return -1
			}
			i += j + 2
		case '"':
			i++
			for i < len(s) && s[i] != '"' {
				if s[i] == '\\' {
					i++
				}
				i++
			}
			if i < len(s) {
				i++
			}
		case '\\':
			i += 2
		case '|':
			return i
		default:
			i++
		}
	}
	return -1
}

// bAlias lists the table (sorted, bash's `alias NAME='VALUE'` format),
// prints one entry (`alias NAME`), or defines/replaces entries
// (`alias NAME=VALUE ...`). Unknown names and refused definitions set
// status 1 without stopping the rest of the call.
func bAlias(c *cmdCtx) int {
	if len(c.args) == 0 {
		for _, n := range c.sh.aliasNames() {
			c.out([]byte("alias " + n + "='" + strings.ReplaceAll(c.sh.aliases[n], "'", `'\''`) + "'\n"))
		}
		return 0
	}
	st := 0
	for _, a := range c.args {
		if eq := strings.IndexByte(a, '='); eq >= 0 {
			if msg := c.sh.setAlias(a[:eq], a[eq+1:]); msg != "" {
				c.out([]byte(msg + "\n"))
				st = 1
			}
			continue
		}
		if v, ok := c.sh.aliases[a]; ok {
			c.out([]byte("alias " + a + "='" + strings.ReplaceAll(v, "'", `'\''`) + "'\n"))
		} else {
			c.out([]byte("gosh: alias: " + a + ": not found\n"))
			st = 1
		}
	}
	return st
}

// bUnalias removes names; `-a` clears the table. An unknown name reports
// and sets status 1, but every other name still comes out.
func bUnalias(c *cmdCtx) int {
	if len(c.args) == 0 {
		c.out([]byte("gosh: unalias: usage: unalias NAME...\n"))
		return 2
	}
	st := 0
	for _, a := range c.args {
		if a == "-a" {
			c.sh.aliases = nil
			continue
		}
		if _, ok := c.sh.aliases[a]; ok {
			delete(c.sh.aliases, a)
		} else {
			c.out([]byte("gosh: unalias: " + a + ": not found\n"))
			st = 1
		}
	}
	return st
}
