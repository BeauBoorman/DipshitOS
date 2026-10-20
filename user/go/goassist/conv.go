// conv.go — GOASSIST's conversation model and its on-disk codec (M140b,
// #2785). A conversation is an ordered list of turns; the file is its
// durable half, published crash-safe through vi.WriteFileSafe so a torn
// write is never a torn chat.
//
// The wire format is line-oriented so it stays readable with `vf cat`:
//
//	GOASSIST-CHAT v1
//	@@user
//	<text lines>
//	@@assistant
//	<text lines>
//
// A `@@`-prefixed line inside a body would split a turn, so bodies never
// carry one: encode prefixes such a line with a single space, decode
// strips it. Decode is strict — wrong magic, an unknown role, a body out
// of order, bounds, or trailing garbage refuse the WHOLE file (ok=false),
// never a half-loaded conversation.
package main

import (
	"strconv"
	"strings"
)

const (
	convMagic    = "GOASSIST-CHAT v1"
	convExt      = ".CHAT"
	convMark     = "@@"
	convMaxTurns = 256
	convMaxBytes = 256 * 1024
	convNameMax  = 24

	roleUser  = "user"
	roleModel = "assistant"
	roleMeta  = "meta"
)

// turn is one side of the exchange. role is roleUser or roleModel.
type turn struct {
	role string
	text string
}

// conversation is the in-memory chat: a stable name (its file's stem)
// plus the turns, oldest first.
type conversation struct {
	name  string
	turns []turn
}

// encodeConv serializes c. A body line that begins with the turn marker
// is space-protected so decode never splits a turn mid-body.
func encodeConv(c *conversation) []byte {
	var sb strings.Builder
	sb.WriteString(convMagic + "\n")
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
	if !strings.HasPrefix(s, convMagic+"\n") {
		return nil, false
	}
	s = s[len(convMagic)+1:]
	var c conversation
	var cur *turn
	for _, ln := range strings.Split(s, "\n") {
		if strings.HasPrefix(ln, convMark) {
			role := ln[len(convMark):]
			if role != roleUser && role != roleModel && role != roleMeta {
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
	if len(c.turns) == 0 {
		return nil, false
	}
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
