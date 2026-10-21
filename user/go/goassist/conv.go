// conv.go — GOASSIST's conversation model and its on-disk codec (M140b,
// #2785; v2 adds the title header and the system turn, #2920). A
// conversation is an ordered list of turns; the file is its durable half,
// published crash-safe through vi.WriteFileSafe so a torn write is never a
// torn chat.
//
// The wire format is line-oriented so it stays readable with `vf cat`:
//
//	GOASSIST-CHAT v2
//	@@title <display title, ≤48 bytes>   (v2 only, first line, optional)
//	@@system                             (v2 only, optional, turn 0 only)
//	<prompt lines>
//	@@user
//	<text lines>
//	@@assistant
//	<text lines>
//
// A file stays v1 while it has no title and no preset — an untouched store
// is byte-identical to the M140b format, and a v1 file reads as a v2 one
// with an empty title. Encode picks the version from the content; decode
// picks it from the magic line.
//
// A `@@`-prefixed line inside a body would split a turn, so bodies never
// carry one: encode prefixes such a line with a single space, decode
// strips it. Decode is strict — wrong magic, an unknown role, a body out
// of order, a stray or over-long title, a system turn that is not first,
// bounds, or trailing garbage refuse the WHOLE file (ok=false), never a
// half-loaded conversation.
package main

import (
	"strconv"
	"strings"
)

const (
	convMagicV1   = "GOASSIST-CHAT v1"
	convMagicV2   = "GOASSIST-CHAT v2"
	convTitleMark = "@@title "
	convExt       = ".CHAT"
	convMark      = "@@"
	convMaxTurns  = 256
	convMaxBytes  = 256 * 1024
	convNameMax   = 24
	convTitleMax  = 48

	roleUser   = "user"
	roleModel  = "assistant"
	roleMeta   = "meta"
	roleSystem = "system"
)

// turn is one side of the exchange. role is roleUser, roleModel, roleMeta,
// or — only as turn 0 — roleSystem carrying the preset's prompt.
type turn struct {
	role string
	text string
}

// conversation is the in-memory chat: a stable name (its file's stem), an
// optional display title, plus the turns, oldest first.
type conversation struct {
	name  string
	title string
	turns []turn
}

// encodeConv serializes c. A body line that begins with the turn marker
// is space-protected so decode never splits a turn mid-body.
func encodeConv(c *conversation) []byte {
	var sb strings.Builder
	v2 := c.title != ""
	for _, t := range c.turns {
		if t.role == roleSystem {
			v2 = true
		}
	}
	if v2 {
		sb.WriteString(convMagicV2 + "\n")
		if c.title != "" {
			sb.WriteString(convTitleMark + c.title + "\n")
		}
	} else {
		sb.WriteString(convMagicV1 + "\n")
	}
	for _, t := range c.turns {
		sb.WriteString(convMark + t.role + "\n")
		for _, ln := range strings.Split(t.text, "\n") {
			if strings.HasPrefix(ln, convMark) || strings.HasPrefix(ln, " "+convMark) {
				sb.WriteByte(' ')
			}
			sb.WriteString(ln + "\n")
		}
	}
	return []byte(sb.String())
}

// decodeConv is encodeConv's strict inverse. Every bound is checked; a
// refusal is total.
func decodeConv(b []byte) (*conversation, bool) {
	if len(b) == 0 || len(b) > convMaxBytes {
		return nil, false
	}
	s := string(b)
	v2 := false
	switch {
	case strings.HasPrefix(s, convMagicV1+"\n"):
		s = s[len(convMagicV1)+1:]
	case strings.HasPrefix(s, convMagicV2+"\n"):
		v2 = true
		s = s[len(convMagicV2)+1:]
	default:
		return nil, false
	}
	var c conversation
	if v2 && strings.HasPrefix(s, convTitleMark) {
		rest := s[len(convTitleMark):]
		end := strings.IndexByte(rest, '\n')
		if end < 0 {
			end = len(rest)
		}
		title := rest[:end]
		if !validTitle(title) {
			return nil, false
		}
		c.title = title
		s = rest[end:]
		if len(s) > 0 {
			s = s[1:]
		}
	}
	var cur *turn
	for _, ln := range strings.Split(s, "\n") {
		if strings.HasPrefix(ln, convMark) {
			role := ln[len(convMark):]
			ok := role == roleUser || role == roleModel || role == roleMeta ||
				(v2 && role == roleSystem && len(c.turns) == 0)
			if !ok {
				return nil, false
			}
			if len(c.turns) >= convMaxTurns {
				return nil, false
			}
			c.turns = append(c.turns, turn{role: role})
			cur = &c.turns[len(c.turns)-1]
			continue
		}
		if cur == nil {
			// Body text before the first marker, or the file's trailing
			// newline after the last turn — only the empty string is legal.
			if ln != "" {
				return nil, false
			}
			continue
		}
		if strings.HasPrefix(ln, " "+convMark) {
			ln = ln[1:]
		}
		if cur.text != "" {
			cur.text += "\n"
		}
		cur.text += ln
	}
	// Split's trailing "" after a final newline lands inside the last turn
	// as a phantom empty line; drop exactly that one.
	if cur != nil && strings.HasSuffix(cur.text, "\n") {
		cur.text = strings.TrimSuffix(cur.text, "\n")
	}
	// A turn-less file is a legitimate empty conversation — newConv saves
	// one the moment it allocates the name.
	return &c, true
}

// validConvName is the C#### grammar the store generates: a file a user
// dropped beside them can be listed, but only generated names count when
// allocating the next one.
func validConvName(s string) bool {
	if len(s) < 2 || len(s) > convNameMax {
		return false
	}
	if s[0] != 'C' {
		return false
	}
	for i := 1; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// nextConvName allocates the lowest free C0001..C9999 over the names the
// store listed; "" means the space is exhausted (a named refusal upstream,
// not a wraparound).
func nextConvName(have []string) string {
	used := map[int]bool{}
	for _, n := range have {
		if !validConvName(n) || len(n) > 5 {
			continue
		}
		if v, err := strconv.Atoi(n[1:]); err == nil {
			used[v] = true
		}
	}
	for i := 1; i <= 9999; i++ {
		if !used[i] {
			return "C" + pad4(i)
		}
	}
	return ""
}

func pad4(n int) string {
	s := strconv.Itoa(n)
	for len(s) < 4 {
		s = "0" + s
	}
	return s
}

// validTitle is the title bound: 1..48 bytes, single-line. Rename treats
// the empty string as "clear the title" before this is ever consulted.
func validTitle(t string) bool {
	return len(t) >= 1 && len(t) <= convTitleMax &&
		!strings.ContainsAny(t, "\r\n")
}

// convTitleOf is the listing's cheap header read: the title a v2 file's
// head carries, "" for v1, malformed, or untitled. It parses only the
// first two lines, so callers bound the read small.
func convTitleOf(b []byte) string {
	s := string(b)
	if !strings.HasPrefix(s, convMagicV2+"\n") {
		return ""
	}
	s = s[len(convMagicV2)+1:]
	if !strings.HasPrefix(s, convTitleMark) {
		return ""
	}
	rest := s[len(convTitleMark):]
	end := strings.IndexByte(rest, '\n')
	if end < 0 {
		end = len(rest)
	}
	t := rest[:end]
	if !validTitle(t) {
		return ""
	}
	return t
}

// displayTitle is the list/title-bar label: the stored title when one
// exists, "Conversation N" for a generated C#### name with none (the v1
// file's reading), else the raw stem for a file dropped beside them.
func displayTitle(name, title string) string {
	if title != "" {
		return title
	}
	if validConvName(name) {
		if v, err := strconv.Atoi(name[1:]); err == nil {
			return "Conversation " + strconv.Itoa(v)
		}
	}
	return name
}
