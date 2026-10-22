// Package main — GOTOP's agent-activity tab (M109c, ADR 0052 D4): the
// human's window onto the AGENTD audit lane. Every receipt in
// /host/AGENT/AUDIT/ is a two-line file — the JSON record, then
// HMAC-SHA256 over line 1 under the agent-hmac row. GOTOP holds the same
// row (its allowlist is AGENTD.ELF,GOTOP.ELF) so the view can mark each
// receipt verified, forged-or-edited, or unverifiable — and a receipt the
// MAC cannot back is shown as untrusted, never dropped silently.
//
// M173c (#3044) adds the kernel's half of the trail: the M161a
// denial-receipt ring (slot 89 op 2, the same surface the trust tab
// drains) renders below the lane rows, one row per receipt, with a
// PRINCIPAL column read off the receipt's `uid=` field. Lane receipts
// are the daemon's own trail — every one is the agent principal by
// construction (uid_agent), so their column says "agent". The `u` key
// cycles the principal filter all → user → agent, narrowing both
// sections at once; a refused ring read renders "?", never an empty
// list dressed as silence.
package main

import (
	"strings"

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
	// krcptMax caps the kernel receipts drained per refresh — the ring's
	// own bound, so the view can never hold more than it publishes.
	krcptMax = 32
	// uidAgent is the agent principal (ADR 0052 amendment, M173b #3041);
	// vi carries UidSystem/UidUser but the agent constant is M173d's —
	// duplicated here the way shlib duplicates uidSystem.
	uidAgent = 2000
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
	agent     string
	verb      string
	arg       string // the bounded summary: path, cmd, event or ""
	result    string
	ts        int64
	mark      byte
	seq       string // the seq text as written (display + sort)
	principal string // the column class — lane rows are "agent" by construction
	display   string
}

// krcpt is one drained kernel receipt (the M161a ring's RCPT line,
// M173c's `uid=` tail): the denial's verdict/word/name plus the uid of
// the process the kernel receipted — parsed by key, so a pre-`uid=`
// line decodes with class "?" rather than failing.
type krcpt struct {
	verdict string
	name    string
	word    string
	uid     int64
	hasUID  bool
	class   string // "system" | "user" | "agent" | "uid<n>" | "?"
	display string
}

// auditFilter is the `u`-key principal filter: all rows, only the
// human's (uid_user) receipts, or only the agent's (uid_agent + the
// lane's own trail).
type auditFilter int

const (
	filtAll auditFilter = iota
	filtUser
	filtAgent
)

// AgentView is the agent-activity tab state.
type AgentView struct {
	key           []byte
	hasKey        bool
	rows          []agentRow
	krows         []krcpt
	listed        bool // the lane directory answered
	nVerif        int
	nBad          int
	denialsErr    int64  // the op-2 errno, 0 when the ring was served
	denialDropped uint64 // receipts the ring evicted unread
	filter        auditFilter
	refreshed     bool
}

// Seams: the syscall-adjacent calls as package vars so host tests can
// stage a lane without the kernel (the same discipline agentd uses).
var (
	agentListFn    = vi.ListDirAt
	agentReadFn    = vi.ReadFileAll
	agentKeyFn     = shlib.StoreGet
	agentDenialsFn = func(c uint64) ([]string, uint64, uint64, int64) { return vi.GrantDenials(c) }
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
	// The kernel's half drains independently of the lane — cursor 0
	// re-reads the whole ring ("recent denials" is the ring's bound, not
	// a growing ledger; the trust tab's drain keeps the same contract).
	// A refused read is kept as denialsErr — the section says the
	// surface is unreadable rather than painting an empty ring.
	v.krows = v.krows[:0]
	v.denialsErr = 0
	v.denialDropped = 0
	if dlines, _, dropped, drc := agentDenialsFn(0); drc < 0 {
		v.denialsErr = drc
	} else {
		v.denialDropped = dropped
		for _, l := range dlines {
			if k, ok := parseKReceipt(l); ok {
				v.krows = append(v.krows, k)
			}
			if len(v.krows) >= krcptMax {
				break
			}
		}
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
	row := agentRow{agent: "?", verb: "?", result: "?", mark: markMalformed, principal: "agent"}
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
	return padRight(clip(r.agent, 8), 9) + padRight(clip(r.principal, 9), 10) +
		padRight(clip(r.verb, 13), 14) + padRight(clip(r.arg, 18), 19) +
		padRight(clip(r.result, 17), 18) +
		string(r.mark) + " " + clockText(r.ts)
}

// krcptLabel renders one kernel receipt row: principal, then the denial
// fields the receipt carried.
func krcptLabel(r krcpt) string {
	return padRight(clip(r.class, 9), 10) + padRight(clip(r.verdict, 20), 21) +
		padRight(clip(orDashT(r.name), 16), 17) + clip(orDashT(r.word), 10)
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

// Lines is the tab's text, one entry per row: the lane section, then
// the kernel receipts — both narrowed by the principal filter.
func (v *AgentView) Lines() []string {
	if !v.refreshed {
		return []string{"agent: not sampled"}
	}
	var out []string
	if !v.listed {
		out = append(out, "agent: no audit lane (/host/AGENT/AUDIT missing)")
	} else {
		out = append(out,
			"audit lane  receipts="+vi.Itoa64(int64(len(v.rows)))+
				"  verified="+vi.Itoa64(int64(v.nVerif))+
				"  bad="+vi.Itoa64(int64(v.nBad))+
				"  key="+keyText(v.hasKey)+
				"  filter="+v.filter.name(),
			"",
			padRight("AGENT", 9)+padRight("PRINCIPAL", 10)+padRight("VERB", 14)+
				padRight("ARG", 19)+padRight("RESULT", 18)+"V TIME",
		)
		for _, r := range v.rows {
			if v.filter.admits(r.principal) {
				out = append(out, r.display)
			}
		}
	}
	out = append(out, "", "kernel receipts (denial ring):")
	if v.denialsErr != 0 {
		out = append(out, "  refused: "+vi.ErrnoName(v.denialsErr))
	} else {
		out = append(out,
			"  drained="+vi.Itoa64(int64(len(v.krows)))+
				" dropped="+vi.Itoa64(int64(v.denialDropped)),
			padRight("PRINCIPAL", 10)+padRight("VERDICT", 21)+
				padRight("NAME", 17)+"WORD",
		)
		for _, r := range v.krows {
			if v.filter.admits(r.class) {
				out = append(out, r.display)
			}
		}
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
// verdicts, whether the key row was served at all, the kernel-receipt
// drain ("?" when the ring refused), and the principal filter in force.
func (v *AgentView) Marker() string {
	kr := "?"
	if v.denialsErr == 0 {
		kr = vi.Itoa64(int64(len(v.krows)))
	}
	return "top: agent n=" + vi.Itoa64(int64(len(v.rows))) +
		" verified=" + vi.Itoa64(int64(v.nVerif)) +
		" bad=" + vi.Itoa64(int64(v.nBad)) +
		" key=" + keyText(v.hasKey) +
		" krcpts=" + kr +
		" filter=" + v.filter.name()
}

// RowMarker is one visible row's serial line (bounded callers cap the
// count): filtered lane rows first, then the filtered kernel receipts —
// so a narrowing filter narrows the marker dump too.
func (v *AgentView) RowMarker(i int) (string, bool) {
	n := 0
	for _, r := range v.rows {
		if !v.filter.admits(r.principal) {
			continue
		}
		if n == i {
			return "top: agent rcpt agent=" + r.agent + " verb=" + r.verb +
				" result=" + r.result + " mark=" + string(r.mark), true
		}
		n++
	}
	for _, r := range v.krows {
		if !v.filter.admits(r.class) {
			continue
		}
		if n == i {
			uid := "-"
			if r.hasUID {
				uid = vi.Itoa64(r.uid)
			}
			return "top: agent krcpt uid=" + uid + " class=" + r.class +
				" verdict=" + r.verdict + " name=" + orDashT(r.name) +
				" word=" + orDashT(r.word), true
		}
		n++
	}
	return "", false
}

// CycleFilter advances the `u` principal filter all → user → agent → all.
func (v *AgentView) CycleFilter() string {
	v.filter = (v.filter + 1) % 3
	return v.filter.name()
}

// FilterName is the filter's current word (all | user | agent).
func (v *AgentView) FilterName() string { return v.filter.name() }

func (f auditFilter) name() string {
	switch f {
	case filtUser:
		return "user"
	case filtAgent:
		return "agent"
	}
	return "all"
}

// admits reports whether a row of principal class `class` survives the
// filter. "system" and unresolvable ("?"/"uid<n>") classes render under
// "all" only — neither filter word claims them.
func (f auditFilter) admits(class string) bool {
	switch f {
	case filtUser:
		return class == "user"
	case filtAgent:
		return class == "agent"
	}
	return true
}

// uidClass maps a receipt's uid= to its principal class: the three
// kernel principals get their words, anything else stays numeric, and
// a receipt with no uid= at all reads "?".
func uidClass(uid int64, ok bool) string {
	if !ok {
		return "?"
	}
	switch uid {
	case int64(vi.UidSystem):
		return "system"
	case int64(vi.UidUser):
		return "user"
	case uidAgent:
		return "agent"
	}
	return "uid" + vi.Itoa64(uid)
}

// parseKReceipt decodes one drained RCPT line by key — the same contract
// the format promises (fields split on spaces, read by name); a line
// with no verdict is not a receipt and is skipped, never half-shown.
func parseKReceipt(line string) (krcpt, bool) {
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "RCPT ") {
		return krcpt{}, false
	}
	r := krcpt{}
	for _, f := range strings.Fields(line[5:]) {
		k, val, ok := strings.Cut(f, "=")
		if !ok {
			continue
		}
		switch k {
		case "verdict":
			r.verdict = val
		case "name":
			r.name = val
		case "word":
			r.word = val
		case "uid":
			r.uid = fieldNum(val)
			r.hasUID = true
		}
	}
	if r.verdict == "" {
		return krcpt{}, false
	}
	r.class = uidClass(r.uid, r.hasUID)
	r.display = krcptLabel(r)
	return r, true
}

// fieldNum parses a bare decimal field (the receipt's uid=); a non-digit
// byte ends the number, and an empty field is 0 — the display class then
// answers for the value, not the parse.
func fieldNum(s string) int64 {
	var n int64
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			break
		}
		n = n*10 + int64(s[i]-'0')
	}
	return n
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
