// Package main — GOTOP's agent-activity tab (M109c, ADR 0052 D4): the
// human's window onto the AGENTD audit lane. Every receipt in
// /host/AGENT/AUDIT/ is a two-line file — the JSON record, then
// HMAC-SHA256 over line 1 under the agent-hmac row. GOTOP holds the same
// row (its allowlist is AGENTD.ELF,GOTOP.ELF) so the view can mark each
// receipt verified, forged-or-edited, or unverifiable — and a receipt the
// MAC cannot back is shown as untrusted, never dropped silently.
package main

import (
	"virelai/shlib"
	"virelai/vi"
)

const (
	// agentCanon is the AUDIT lane in ListDirAt's canonical form
	// (dirSnapshot prepends /host); agentHostDir is the file-ABI path.
	agentCanon   = "/AGENT/AUDIT"
	agentHostDir = "/host/AGENT/AUDIT/"
	// agentSecret is the SECRETS.TXT row both ends read: the receipt key.
	agentSecret = "agent-hmac"
	// receiptMax bounds one receipt file read (the writer's ceiling is
	// ≈600 bytes; the bound exists so a foreign file cannot stretch the
	// read).
	receiptMax = 1024
	// agentRowMax caps the rendered rows at the lane's own bound.
	agentRowMax = 64
	// agentKeyMax bounds the secret-row read.
	agentKeyMax = 256
)

// Verification marks (the D4 verified/unverified contract):
const (
	markVerified   = 'v' // MAC matched under the agent-hmac row
	markForged     = '!' // key in hand, MAC failed — edited or planted
	markMalformed  = 'x' // not a parseable receipt at all
	markUnknownKey = '?' // no key served: nothing can be proven
)

// agentRow is one decoded receipt for display.
type agentRow struct {
	agent   string
	verb    string
	arg     string // the bounded summary: path, cmd, event or ""
	result  string
	ts      int64
	mark    byte
	seq     string // the seq text as written (display + sort)
	display string
}

// AgentView is the agent-activity tab state.
type AgentView struct {
	key       []byte
	hasKey    bool
	rows      []agentRow
	listed    bool // the lane directory answered
	nVerif    int
	nBad      int
	refreshed bool
}

// Seams: the syscall-adjacent calls as package vars so host tests can
// stage a lane without the kernel (the same discipline agentd uses).
var (
	agentListFn = vi.ListDirAt
	agentReadFn = vi.ReadFileAll
	agentKeyFn  = shlib.StoreGet
)

// NewAgentView builds an empty view.
func NewAgentView() *AgentView { return &AgentView{} }

// Refresh resamples the lane: the key row (its absence downgrades every
// mark to '?'), the RCPT-* names newest-first, then each file's decode +
// MAC verdict. A directory that will not list keeps the previous view and
// reports listed=false — the tab says the lane is missing rather than
// painting an empty one.
func (v *AgentView) Refresh() {
	v.refreshed = true
	var kb [agentKeyMax]byte
	if n := agentKeyFn(agentSecret, kb[:]); n > 0 {
		v.key = append(v.key[:0], kb[:n]...)
		v.hasKey = true
	} else {
		v.key = nil
		v.hasKey = false
	}
	items, err := agentListFn(agentCanon)
	if err != nil {
		v.listed = false
		return
	}
	v.listed = true
	var names []string
	for _, it := range items {
		if it.IsDir || !receiptNameOK(it.Name) {
			continue
		}
		names = append(names, it.Name)
	}
	// Newest first: epoch+seq lexical order is chronological within an
	// epoch; cross-epoch order is the writer's contract, not the viewer's
	// problem. Insertion sort keeps it stable and bounded.
	for i := 1; i < len(names); i++ {
		for j := i; j > 0 && names[j] > names[j-1]; j-- {
			names[j], names[j-1] = names[j-1], names[j]
		}
	}
	if len(names) > agentRowMax {
		names = names[:agentRowMax]
	}
	v.rows = v.rows[:0]
	v.nVerif, v.nBad = 0, 0
	for _, name := range names {
		row := v.readOne(name)
		switch row.mark {
		case markVerified:
			v.nVerif++
		case markForged, markMalformed:
			v.nBad++
		}
		v.rows = append(v.rows, row)
	}
}

// readOne decodes one receipt file and verifies it.
func (v *AgentView) readOne(name string) agentRow {
	row := agentRow{agent: "?", verb: "?", result: "?", mark: markMalformed}
	b, r := agentReadFn(agentHostDir+name, receiptMax+1)
	if r < 0 || b == nil || len(b) > receiptMax {
		row.result = "missing"
		return row
	}
	nl := 0
	for nl < len(b) && b[nl] != '\n' {
		nl++
	}
	if nl >= len(b) || nl+1+64 > len(b) {
		return row // no MAC line
	}
	line := b[:nl]
	macHex := b[nl+1 : nl+1+64]
	fields, ok := scanFlat(line)
	if !ok {
		return row
	}
	row.agent = fieldStr(fields, "agent", "?")
	row.verb = fieldStr(fields, "verb", "?")
	row.result = fieldStr(fields, "result", "?")
	row.seq = fieldStr(fields, "seq", "")
	row.ts = fieldInt(fields, "ts")
	row.arg = argsSummary(fields["args"])
	row.mark = markUnknownKey
	if v.hasKey {
		mac := shlib.HMACSHA256(v.key, line)
		if macHexEq(mac[:], macHex) {
			row.mark = markVerified
		} else {
			row.mark = markForged
		}
	}
	row.display = agentRowLabel(row)
	return row
}

// agentRowLabel renders one receipt row for the list (bounded; guest-safe).
func agentRowLabel(r agentRow) string {
	return padRight(clip(r.agent, 8), 9) + padRight(clip(r.verb, 13), 14) +
		padRight(clip(r.arg, 18), 19) + padRight(clip(r.result, 17), 18) +
		string(r.mark) + " " + clockText(r.ts)
}

// clip bounds a display field.
func clip(s string, max int) string {
	if len(s) > max {
		return s[:max]
	}
	return s
}

// clockText renders unix seconds as hh:mm:ss (the day wraps; receipts only
// need a readable stamp, and the guest has no tzdata anyway).
func clockText(ts int64) string {
	if ts <= 0 {
		return "--:--:--"
	}
	s := ts % 86400
	two := func(v int64) string {
		if v < 10 {
			return "0" + vi.Itoa64(v)
		}
		return vi.Itoa64(v)
	}
	return two(s/3600) + ":" + two((s%3600)/60) + ":" + two(s%60)
}

// Lines is the tab's text, one entry per row.
func (v *AgentView) Lines() []string {
	if !v.refreshed || !v.listed {
		return []string{"agent: no audit lane (/host/AGENT/AUDIT missing)"}
	}
	out := []string{
		"audit lane  receipts=" + vi.Itoa64(int64(len(v.rows))) +
			"  verified=" + vi.Itoa64(int64(v.nVerif)) +
			"  bad=" + vi.Itoa64(int64(v.nBad)) +
			"  key=" + keyText(v.hasKey),
		"",
		padRight("AGENT", 9) + padRight("VERB", 14) + padRight("ARG", 19) +
			padRight("RESULT", 18) + "V TIME",
	}
	for _, r := range v.rows {
		out = append(out, r.display)
	}
	return out
}

func keyText(ok bool) string {
	if ok {
		return "yes"
	}
	return "no"
}

// Marker is the serial line the gate asserts: the row count, the MAC
// verdicts, and whether the key row was served at all.
func (v *AgentView) Marker() string {
	return "top: agent n=" + vi.Itoa64(int64(len(v.rows))) +
		" verified=" + vi.Itoa64(int64(v.nVerif)) +
		" bad=" + vi.Itoa64(int64(v.nBad)) +
		" key=" + keyText(v.hasKey)
}

// RowMarker is one row's serial line (bounded callers cap the count).
func (v *AgentView) RowMarker(i int) (string, bool) {
	if i < 0 || i >= len(v.rows) {
		return "", false
	}
	r := v.rows[i]
	return "top: agent rcpt agent=" + r.agent + " verb=" + r.verb +
		" result=" + r.result + " mark=" + string(r.mark), true
}

// receiptNameOK reports whether name is RCPT-<8hex>-<8hex> (the lane's
// only committed shape; "~" temps and foreign files are skipped).
func receiptNameOK(name string) bool {
	if len(name) != 22 || name[:5] != "RCPT-" || name[13] != '-' {
		return false
	}
	for i := 5; i < 22; i++ {
		if i == 13 {
			continue
		}
		c := name[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F') {
			return false
		}
	}
	return true
}

// macHexEq compares the 32-byte MAC to its 64-char hex line, constant-time
// over the tag. A non-hex byte fails.
func macHexEq(mac []byte, hex []byte) bool {
	if len(hex) != 64 || len(mac) != 32 {
		return false
	}
	var diff byte
	for i := 0; i < 32; i++ {
		hi, ok1 := hexNibble(hex[2*i])
		lo, ok2 := hexNibble(hex[2*i+1])
		if !ok1 || !ok2 {
			return false
		}
		diff |= mac[i] ^ (hi<<4 | lo)
	}
	return diff == 0
}

func hexNibble(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// --- the bounded flat-object scanner -----------------------------------------
//
// The receipt's line 1 is a flat object with one nested args object. Rather
// than pull in a JSON package GOTOP's ELF budget cannot afford (the same
// ADR 0042 §1 rule as agentd), this scanner walks "key":value pairs: string
// and number values arrive unquoted, anything compound arrives as its raw
// balanced text. It accepts only the shape it can prove — a receipt line
// that scans dirty is malformed, never half-read.
func scanFlat(b []byte) (map[string][]byte, bool) {
	out := map[string][]byte{}
	i := 0
	ws := func() {
		for i < len(b) && (b[i] == ' ' || b[i] == '\t' || b[i] == '\r' || b[i] == '\n') {
			i++
		}
	}
	str := func() ([]byte, bool) {
		if i >= len(b) || b[i] != '"' {
			return nil, false
		}
		i++
		start := i
		for i < len(b) {
			if b[i] == '\\' {
				i += 2
				continue
			}
			if b[i] == '"' {
				s := b[start:i]
				i++
				return s, true
			}
			i++
		}
		return nil, false
	}
	ws()
	if i >= len(b) || b[i] != '{' {
		return nil, false
	}
	i++
	ws()
	if i < len(b) && b[i] == '}' {
		return out, true
	}
	for {
		ws()
		key, ok := str()
		if !ok {
			return nil, false
		}
		ws()
		if i >= len(b) || b[i] != ':' {
			return nil, false
		}
		i++
		ws()
		val, ok := scanValue(b, &i)
		if !ok {
			return nil, false
		}
		out[string(key)] = val
		ws()
		if i >= len(b) {
			return nil, false
		}
		if b[i] == '}' {
			i++
			ws()
			return out, i == len(b)
		}
		if b[i] != ',' {
			return nil, false
		}
		i++
	}
}

// scanValue reads one JSON value at *i: a string (returned unquoted), a
// number/literal (raw text), or a balanced {}/[] (raw text, strings
// honored). *i ends just past the value.
func scanValue(b []byte, i *int) ([]byte, bool) {
	p := *i
	if p >= len(b) {
		return nil, false
	}
	switch {
	case b[p] == '"':
		start := p + 1
		j := start
		for j < len(b) {
			if b[j] == '\\' {
				j += 2
				continue
			}
			if b[j] == '"' {
				*i = j + 1
				return b[start:j], true
			}
			j++
		}
		return nil, false
	case b[p] == '{' || b[p] == '[':
		open, close := b[p], byte('}')
		if open == '[' {
			close = ']'
		}
		depth := 0
		j := p
		for j < len(b) {
			c := b[j]
			if c == '"' {
				k := j + 1
				for k < len(b) {
					if b[k] == '\\' {
						k += 2
						continue
					}
					if b[k] == '"' {
						break
					}
					k++
				}
				if k >= len(b) {
					return nil, false
				}
				j = k + 1
				continue
			}
			if c == open {
				depth++
			} else if c == close {
				depth--
				if depth == 0 {
					*i = j + 1
					return b[p : j+1], true
				}
			}
			j++
		}
		return nil, false
	default:
		j := p
		for j < len(b) && b[j] != ',' && b[j] != '}' && b[j] != ']' &&
			b[j] != ' ' && b[j] != '\t' && b[j] != '\r' && b[j] != '\n' {
			j++
		}
		if j == p {
			return nil, false
		}
		*i = j
		return b[p:j], true
	}
}

// fieldStr returns the field's string text (unescape-lite: \" and \\ only —
// anything else stays as written; a display field, not a wire field).
func fieldStr(fields map[string][]byte, key, def string) string {
	v, ok := fields[key]
	if !ok || len(v) == 0 {
		return def
	}
	out := make([]byte, 0, len(v))
	for i := 0; i < len(v); i++ {
		if v[i] == '\\' && i+1 < len(v) && (v[i+1] == '"' || v[i+1] == '\\') {
			out = append(out, v[i+1])
			i++
			continue
		}
		out = append(out, v[i])
	}
	return string(out)
}

// fieldInt parses the field's number text (receipt numbers are plain
// unsigned/literals from the writer).
func fieldInt(fields map[string][]byte, key string) int64 {
	v, ok := fields[key]
	if !ok {
		return 0
	}
	var n int64
	neg := false
	for i, c := range v {
		if i == 0 && c == '-' {
			neg = true
			continue
		}
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int64(c-'0')
	}
	if neg {
		return -n
	}
	return n
}

// argsSummary picks the one bounded arg worth a column: the event name on
// session receipts, else path, else cmd, else "".
func argsSummary(raw []byte) string {
	if len(raw) == 0 {
		return ""
	}
	fields, ok := scanFlat(raw)
	if !ok {
		return ""
	}
	if e := fieldStr(fields, "event", ""); e != "" {
		return e
	}
	if p := fieldStr(fields, "path", ""); p != "" {
		return p
	}
	if c := fieldStr(fields, "cmd", ""); c != "" {
		return c
	}
	if pid := fields["pid"]; len(pid) > 0 {
		return "pid=" + string(pid)
	}
	return ""
}
