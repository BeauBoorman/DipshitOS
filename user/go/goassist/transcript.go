// transcript.go — the render half of a conversation (M140b, #2785): turns
// become display lines, wrapped to the pane, with ``` fenced runs carried
// as code so the view can paint them in the mono face on a plate. The
// scrollback is BOUNDED: past scrollMax the oldest rendered lines drop
// (the conversation file is the whole record; the view is its tail).
package main

import "strings"

// rlineKind is the paint role of one display line.
type rlineKind uint8

const (
	rlUser  rlineKind = iota // "you>" prefixed prompt lines
	rlModel                  // assistant prose
	rlCode                   // inside a ``` fence
	rlMeta                   // status/note lines ("(cancelled)", refusals)
)

// rline is one wrapped display line.
type rline struct {
	text string
	kind rlineKind
}

// scrollMax bounds the rendered transcript; the head line names the clip
// when it fires.
const scrollMax = 2048

// measurer reports a string's painted width at a kind's face size — the
// view injects the chain's Measure (or cells when faces are absent) so
// wrapping matches the paint exactly.
type measurer func(kind rlineKind, s string) int

// renderConv rebuilds the display lines for c at pane width px. User
// turns carry the "you>" prefix; assistant text wraps on words; a line
// beginning with ``` toggles the code kind (fences themselves are not
// painted).
func renderConv(c *conversation, px int, m measurer) []rline {
	if px < 40 {
		px = 40
	}
	var out []rline
	for _, t := range c.turns {
		kind := rlModel
		prefix := ""
		switch t.role {
		case roleUser:
			kind = rlUser
			prefix = "you> "
		case roleMeta:
			kind = rlMeta
		case roleSystem:
			// The chosen preset heads the transcript — visible, muted.
			kind = rlMeta
			prefix = "persona> "
		}
		code := false
		for _, ln := range strings.Split(t.text, "\n") {
			if strings.HasPrefix(ln, "```") {
				code = !code
				continue
			}
			k := kind
			if code {
				k = rlCode
			}
			out = appendWrapped(out, prefix+ln, k, px, m)
			prefix = ""
		}
	}
	if len(out) > scrollMax {
		out = out[len(out)-scrollMax:]
		out[0] = rline{text: "… older lines clipped", kind: rlMeta}
	}
	return out
}

// appendWrapped word-wraps s at px and appends the lines; an over-long
// word is hard-split at the measure boundary. The merge stays inside
// this call — a body newline is a hard display break, never absorbed
// into the previous line. Empty input still emits one line (a turn's
// visual row is never eaten).
func appendWrapped(out []rline, s string, k rlineKind, px int, m measurer) []rline {
	if s == "" {
		return append(out, rline{text: "", kind: k})
	}
	var cur rline
	have := false
	for _, word := range strings.Split(s, " ") {
		// Hard-split a word that alone exceeds the pane.
		for word != "" && m(k, word) > px {
			cut := fitPrefix(k, word, px, m)
			if cut <= 0 {
				cut = 1
			}
			if have {
				out = append(out, cur)
				cur, have = rline{}, false
			}
			out = append(out, rline{text: word[:cut], kind: k})
			word = word[cut:]
		}
		if word == "" {
			continue
		}
		cand := word
		if have && cur.text != "" {
			cand = cur.text + " " + word
		}
		if have && m(k, cand) <= px {
			cur.text = cand
		} else {
			if have {
				out = append(out, cur)
			}
			cur = rline{text: word, kind: k}
			have = true
		}
	}
	if have {
		out = append(out, cur)
	}
	return out
}

// fitPrefix returns the byte length of the longest prefix of s that
// measures within px — byte-walked, rune-boundary safe by construction
// since only whole-prefix lengths are returned.
func fitPrefix(k rlineKind, s string, px int, m measurer) int {
	lo, hi := 0, len(s)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if m(k, s[:mid]) <= px {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}
