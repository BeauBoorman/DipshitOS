// Package vcard is M187d (#3185): the smallest honest VCARD reader —
// the one card GOFILES's contact face needs.
//
// The bound is the card's: BEGIN:VCARD in VERSION 3.0 or 4.0 carrying
// FN, TEL, EMAIL and ORG — the contact-card fields. Everything else an
// exporter writes (N, ADR, PHOTO, REV, folded notes, custom X- rows) is
// skipped by shape but NEVER silently: Card.Other names and counts each
// unhonoured property so the face can account for what it did not paint
// (M193c #3255). What the bound cannot honour is a named refusal:
//
//	not-vcard   no BEGIN:VCARD anywhere in the bytes
//	version     a VERSION that is not 3.0 or 4.0 — the field
//	            semantics differ enough that guessing is lying
//	no-fn       a card with no FN has no name to headline
//
// A multi-card file is first-N by the same honesty rule as ical: Total
// counts every VCARD; Cards holds the honoured prefix.
package vcard

import "strings"

// MaxCards bounds one parse — a contact file longer than the bound is
// first-N with the tail counted, never parsed halfway.
const MaxCards = 8

// Card is one honoured VCARD.
type Card struct {
	FN    string
	ORG   string
	TEL   []string
	EMAIL []string
	// Other names-and-counts the properties the bound does not honour —
	// N, ADR, PHOTO, custom X- rows. A contact face prints them as an
	// accounting row rather than dropping them silently (M193c #3255).
	Other map[string]int
}

// Refusal names the why on a rejected file or card.
type Refusal struct {
	Why string // "not-vcard", "version", "no-fn"
}

// Result is the whole parse: the honoured prefix and the total count.
type Result struct {
	Cards    []Card
	Refusals []Refusal
	Total    int
}

// Parse decodes b as vcard data. Every BEGIN:VCARD counts toward Total;
// cards that pass the bound land in Cards in order; refused cards name
// their why in Refusals. ok=false means the bytes hold no VCARD at all.
func Parse(b []byte) (Result, bool) {
	var r Result
	var cur *Card
	bad := ""
	inCard := false
	for _, ln := range lines(b) {
		name, _, value := prop(ln)
		switch name {
		case "BEGIN":
			if strings.EqualFold(value, "VCARD") {
				r.Total++
				if len(r.Cards)+len(r.Refusals) >= MaxCards {
					cur = nil
					continue
				}
				cur = &Card{}
				bad = ""
				inCard = true
			}
		case "END":
			if strings.EqualFold(value, "VCARD") {
				if cur != nil {
					if bad != "" {
						r.Refusals = append(r.Refusals, Refusal{Why: bad})
					} else if cur.FN == "" {
						r.Refusals = append(r.Refusals, Refusal{Why: "no-fn"})
					} else {
						r.Cards = append(r.Cards, *cur)
					}
				}
				cur = nil
				inCard = false
			}
		default:
			if !inCard || cur == nil || name == "" {
				continue
			}
			switch name {
			case "VERSION":
				v := strings.TrimSpace(value)
				if v != "3.0" && v != "4.0" {
					bad = "version"
				}
			case "FN":
				cur.FN = unescape(strings.TrimSpace(value))
			case "TEL":
				if v := unescape(strings.TrimSpace(value)); v != "" {
					cur.TEL = append(cur.TEL, v)
				}
			case "EMAIL":
				if v := unescape(strings.TrimSpace(value)); v != "" {
					cur.EMAIL = append(cur.EMAIL, v)
				}
			case "ORG":
				cur.ORG = unescape(strings.TrimSpace(value))
			default:
				// A property the bound does not carry: named and
				// counted on the card, never dropped silently.
				if cur.Other == nil {
					cur.Other = map[string]int{}
				}
				cur.Other[name]++
			}
		}
	}
	return r, r.Total > 0
}

// lines unfolds the content line stream — the same RFC 5322/5545 fold
// ical reads: CRLF or LF breaks, a SP/TAB leader continues the previous
// line. Kept local so the two parsers share no file and neither can
// drift the other.
func lines(b []byte) []string {
	raw := strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
	out := make([]string, 0, len(raw))
	for _, ln := range raw {
		ln = strings.TrimSuffix(ln, "\r")
		if len(ln) > 0 && (ln[0] == ' ' || ln[0] == '\t') && len(out) > 0 {
			out[len(out)-1] += ln[1:]
			continue
		}
		out = append(out, ln)
	}
	return out
}

// prop splits `NAME;P=V:value` the way prop in ical does — the face only
// needs the name and the value, so the parameter middle is read for
// position and dropped: a TEL;TYPE=cell: is still a TEL.
func prop(ln string) (name, params, value string) {
	head, value, _ := strings.Cut(ln, ":")
	if i := strings.IndexByte(head, ';'); i >= 0 {
		return strings.ToUpper(head[:i]), head[i+1:], value
	}
	return strings.ToUpper(head), "", value
}

// unescape resolves the vcard text escapes (\, \; \n \N); a \n reads as
// one space — the contact rows are single-line surfaces.
func unescape(s string) string {
	if !strings.ContainsRune(s, '\\') {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			i++
			switch s[i] {
			case 'n', 'N':
				b.WriteByte(' ')
			default:
				b.WriteByte(s[i])
			}
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}
