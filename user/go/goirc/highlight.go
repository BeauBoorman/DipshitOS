package main

// highlight.go — M152e (#2919): the /hl highlight rules. Up to hlMax
// words ride the save_state blob; an EntryMsg whose text hits a rule —
// the same ASCII case-folded whole-word test the nick mention uses —
// fires the existing mention toast and takes the accent bar in the
// scrollback, so "pinged for the words you care about" is one code
// path, not two.

import (
	"strings"

	"virelai/vi"
)

const (
	hlMax     = 16 // rule count bound (the card's number)
	hlWordMax = 32 // per-word byte bound, enforced by the blob decode
)

// eqFold is ASCII case-insensitive equality — the same fold mentionMatch
// applies, so rule dedup and the match itself agree on case.
func eqFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		x, y := a[i], b[i]
		if x >= 'a' && x <= 'z' {
			x -= 'a' - 'A'
		}
		if y >= 'a' && y <= 'z' {
			y -= 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

// hlIndex finds word in the rule set (case-insensitive) or -1.
func (u *uiApp) hlIndex(word string) int {
	for i, w := range u.hl {
		if eqFold(w, word) {
			return i
		}
	}
	return -1
}

// hlHit reports whether text matches any armed highlight rule.
func (u *uiApp) hlHit(text string) bool {
	for _, w := range u.hl {
		if mentionMatch(text, w) {
			return true
		}
	}
	return false
}

// hlVerb is the /hl family: bare lists, add/del mutate (and persist —
// the rules ride the blob, so every mutation is a saveNow).
func (u *uiApp) hlVerb(rest string) {
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		if len(u.hl) == 0 {
			u.status("hl: no highlight words")
		} else {
			u.status("hl: " + strings.Join(u.hl, " "))
		}
		return
	}
	if len(fields) != 2 {
		u.status("usage: /hl [add|del] <word>")
		return
	}
	word := fields[1]
	switch strings.ToLower(fields[0]) {
	case "add":
		if len(word) > hlWordMax {
			u.status("hl word too long (max 32)")
			return
		}
		if u.hlIndex(word) >= 0 {
			u.status("hl: already have " + word)
			return
		}
		if len(u.hl) >= hlMax {
			vi.ConsoleLine("goirc: hl full")
			u.status("hl: full (16 words)")
			return
		}
		u.hl = append(u.hl, word)
		vi.ConsoleLine("goirc: hl add " + word)
		u.saveNow()
	case "del":
		i := u.hlIndex(word)
		if i < 0 {
			u.status("hl: no such word " + word)
			return
		}
		u.hl = append(u.hl[:i], u.hl[i+1:]...)
		vi.ConsoleLine("goirc: hl del " + word)
		u.saveNow()
	default:
		u.status("usage: /hl [add|del] <word>")
	}
}
