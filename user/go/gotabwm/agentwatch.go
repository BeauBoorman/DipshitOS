// GOTABWM.ELF — M109e (#2401, ADR 0052): the agent-activity indicator and
// the agent-milestone notify lanes, seat half.
//
// The human sees what the agent does. The seat's evidence is the M109c
// audit lane itself — the ADR's stated contract is that the receipt
// stream exists for the seat to read, so no new channel and no agentd
// edit exists: every session open/close and every verb dispatch already
// lands as a MAC'd RCPT-* file under /host/AGENT/AUDIT/. The seat lists
// that directory once per composite tick (the hostclipPoll cadence —
// poll-on-tick is the notification channel, no event kind exists) and
// diffs the names against what it has already consumed.
//
// Trust shape, and why the flag is the credential row:
//
//   - A receipt drives chrome only when its HMAC-SHA256 verifies under
//     the agent-hmac row — the same row GOTOP's viewer verifies with.
//     An unsigned plant or an edited file is `agent rcpt bad`, never a
//     badge and never a toast: the indicator exists so the human can
//     trust "an agent is active", and an unverifiable receipt would make
//     that claim unbacked.
//   - The feature is DEFAULT-OFF at the credential boundary, the ADR
//     0051 D7 posture carried over: the row is served to this image only
//     when the operator names GOTABWM.ELF on its allowlist. Unserved
//     means agentKey is nil, the init probe prints nothing, and the tick
//     never even opens the directory — a flags-off boot is byte-silent.
//   - The first poll that lists the lane is the catch-up: backlog
//     receipts replay in name order to reach the CURRENT session state
//     (an open still standing when the seat (re)booted keeps its
//     indicator honest), summarized in one `caught` line. Backlog
//     receipts print their transition markers but never toast — a toast
//     claims a just-now event, and a receipt from before the watch is
//     not one. Receipts arriving after the catch-up are live: markers
//     and, for the three agent milestones, toasts.
//
// The milestones (commit, push, install) are recognized inside verified
// gosh.run receipts: the audit args carry the command verbatim and the
// child's exit_status, so a milestone is `gosh.run` + result ok +
// exit_status 0 + a command head the card names. The intent receipt the
// same dispatch writes carries no exit_status, so it can never double as
// a milestone. A milestone toast is a seat notice (sender id 0 — the
// hostdrop precedent): strip, center history, notify-out lane, DND hold
// and chime all follow the ordinary kind-12 path.
package main

import (
	"virelai/shlib"
	"virelai/theme"
	"virelai/vi"
)

// The lane markers the class-B gate greps. Agent ids are sanitized
// (agentMark) before they can reach a line; receipt payloads never
// appear — the markers carry ids, verbs and milestone names only.
const (
	MarkerAgentWatch     = "gotabwm: agent watch"
	MarkerAgentCaught    = "gotabwm: agent caught "
	MarkerAgentSessOpen  = "gotabwm: agent session open agent="
	MarkerAgentSessClose = "gotabwm: agent session close agent="
	MarkerAgentAuthFail  = "gotabwm: agent auth fail agent="
	MarkerAgentVerb      = "gotabwm: agent verb "
	MarkerAgentMilestone = "gotabwm: agent milestone "
	MarkerAgentRcptBad   = "gotabwm: agent rcpt bad "
)

const (
	// agentAuditCanon is the AUDIT lane in ListDirAt's canonical form
	// (it prepends /host); agentAuditDir is the file-ABI path. Both are
	// the M109c lane — the seat never writes it.
	agentAuditCanon = "/AGENT/AUDIT"
	agentAuditDir   = "/host/AGENT/AUDIT/"
	// agentSecretName is the receipt key — served to this image only
	// when the operator arms the indicator (the allowlist IS the flag).
	agentSecretName = "agent-hmac"
	// agentRcptMax bounds one receipt read (the writer's ceiling is
	// ≈600 bytes; the bound exists so a foreign file cannot stretch it).
	agentRcptMax = 1024
	// agentSeenMax bounds the consumed-name set. The lane rotates at 64
	// files and names never recur (epoch+seq are unique), so twice the
	// live bound cannot be re-fuzzed.
	agentSeenMax = 128
	// agentFieldMax bounds a receipt field rendered into a marker.
	agentFieldMax = 24
)

// The armed-state: agentKey non-nil is the flag itself (nil = the D7
// posture, byte-silent). agentSeen holds the consumed RCPT names;
// agentActive is the indicator's truth; agentCaughtUp marks
// the catch-up boundary after which receipts are live (toastable).
var (
	agentKey      []byte
	agentSeen     []string
	agentActive   bool
	agentCaughtUp bool
)

// The syscall-adjacent seams, as vars so host tests drive the whole
// watch in memory (the hostint fixture discipline).
var (
	agentSecretGet = shlib.StoreGet
	agentListFn    = vi.ListDirAt
	agentReadFn    = vi.ReadFileAll
	agentLogFn     = vi.ConsoleLine
	agentToastFn   = notifyPush
)

// agentSeatInit probes the agent-hmac row once at seat startup — the
// hostintSeatInit posture for the audit lane. Unserved is silent: the
// watch simply never exists.
func agentSeatInit() {
	var key [vi.SecretValMax]byte
	n := agentSecretGet(agentSecretName, key[:])
	if n <= 0 {
		return
	}
	agentKey = append(agentKey[:0], key[:n]...)
	agentLogFn(MarkerAgentWatch)
}

// agentSeatTick is the per-composite-tick drive, called from
// compositeTick beside hostintSeatTick so a receipt observed this tick
// is already badged on the same presented frame.
func agentSeatTick() {
	if agentKey == nil {
		return
	}
	items, err := agentListFn(agentAuditCanon)
	if err != nil {
		if err.Error() == "ENOENT" {
			items = nil // lane absent: the definitive empty listing
		} else {
			return // transient — try again next tick, silently
		}
	}
	var fresh []string
	for _, it := range items {
		if it.IsDir || !agentRcptName(it.Name) || agentSaw(it.Name) {
			continue
		}
		fresh = append(fresh, it.Name)
	}
	// Name order is the lane's committed order within an epoch; sorting
	// keeps the replay chronological and the markers deterministic.
	for i := 1; i < len(fresh); i++ {
		for j := i; j > 0 && fresh[j] < fresh[j-1]; j-- {
			fresh[j], fresh[j-1] = fresh[j-1], fresh[j]
		}
	}
	caught, bad := 0, 0
	for _, name := range fresh {
		agentRemember(name)
		if agentApply(name) {
			caught++
		} else {
			bad++
			if agentCaughtUp {
				agentLogFn(MarkerAgentRcptBad + name)
			}
		}
	}
	if !agentCaughtUp {
		agentCaughtUp = true
		agentLogFn(MarkerAgentCaught + "n=" + vi.Itoa64(int64(caught)) +
			" bad=" + vi.Itoa64(int64(bad)))
	}
}

// agentApply reads, verifies and applies one receipt. False means the
// file did not yield a verified, parseable receipt (forged, malformed,
// unreadable) — the caller names it once. Toasts fire only on live
// receipts (agentCaughtUp), the stale-news rule above.
func agentApply(name string) bool {
	b, r := agentReadFn(agentAuditDir+name, agentRcptMax+1)
	if r < 0 || b == nil || len(b) > agentRcptMax {
		return false
	}
	nl := 0
	for nl < len(b) && b[nl] != '\n' {
		nl++
	}
	if nl >= len(b) || nl+1+64 > len(b) {
		return false
	}
	line, macHex := b[:nl], b[nl+1:nl+1+64]
	mac := shlib.HMACSHA256(agentKey, line)
	if !agentMacEq(mac[:], macHex) {
		return false
	}
	verb, _ := agentField(line, "verb")
	agent, _ := agentField(line, "agent")
	result, _ := agentField(line, "result")
	agent = agentMark(agent)
	if verb == "session" {
		args, _ := agentObject(line, "args")
		event, _ := agentField([]byte(args), "event")
		switch event {
		case "open":
			agentActive = true
			agentLogFn(MarkerAgentSessOpen + agent)
		case "close":
			agentActive = false
			agentLogFn(MarkerAgentSessClose + agent)
		case "auth_fail":
			agentLogFn(MarkerAgentAuthFail + agent)
		default:
			return false
		}
		return true
	}
	if verb == "" {
		return false
	}
	agentLogFn(MarkerAgentVerb + agentMark(verb))
	args, _ := agentObject(line, "args")
	if ms := agentMilestone(verb, []byte(args), result); ms != "" {
		agentLogFn(MarkerAgentMilestone + ms)
		if agentCaughtUp {
			text, _, dropped := agentToastFn(0, "agent: "+ms+" ok", compositeClock)
			if dropped {
				agentLogFn(MarkerNotifyDrop + vi.Itoa64(int64(notifyDropped)))
			}
			if notifyDND {
				agentLogFn(MarkerNotifyHeld + "0 " + text)
			} else {
				agentLogFn(MarkerNotify + "0 " + text)
			}
		}
	}
	return true
}

// agentMilestone names the card's three agent milestones inside a
// verified gosh.run receipt: an ok result, a zero exit_status, and the
// milestone command head at a word boundary inside the recorded command
// (the audit args carry cmd verbatim). The intent receipt's lack of an
// exit_status is what keeps one dispatch from toasting twice.
func agentMilestone(verb string, args []byte, result string) string {
	if verb != "gosh.run" || result != "ok" {
		return ""
	}
	st, ok := agentNumber(args, "exit_status")
	if !ok || st != 0 {
		return ""
	}
	cmd, ok := agentField(args, "cmd")
	if !ok {
		return ""
	}
	for _, m := range agentMilestones {
		if agentCmdHas(cmd, m.cmd) {
			return m.name
		}
	}
	return ""
}

// agentMilestones is the fixed vocabulary: the journey's three hops as
// the command head the audit args record. Match is a boundary search,
// not a prefix — a milestone piped into place still names itself.
var agentMilestones = []struct{ cmd, name string }{
	{"FLINT.ELF commit", "commit"},
	{"FLINT.ELF push", "push"},
	{"STORE.ELF install", "install"},
}

// agentCmdHas reports whether cmd carries phrase at a command head —
// line start or just past a shell separator the agent grammar admits
// (| ; &). A match preceded only by spaces is an argument position
// (`echo FLINT.ELF commit` runs echo, not commit) and does not count.
func agentCmdHas(cmd, phrase string) bool {
	n := len(phrase)
	for i := 0; i+n <= len(cmd); i++ {
		if cmd[i:i+n] != phrase {
			continue
		}
		if i+n < len(cmd) {
			c := cmd[i+n]
			if c != ' ' && c != '\t' && c != '"' && c != '\'' {
				continue
			}
		}
		j := i - 1
		for j >= 0 && (cmd[j] == ' ' || cmd[j] == '\t') {
			j--
		}
		if j < 0 || cmd[j] == '|' || cmd[j] == ';' || cmd[j] == '&' {
			return true
		}
	}
	return false
}

// agentBadge is the indicator's chrome half: while a verified session
// stands open, an AGENT tag in the panel's badge row, Accent — the
// CLIP-badge tint for a live thing (the M108b shape carried over).
func agentBadge() (text string, rgb uint32, ok bool) {
	if !agentActive {
		return "", 0, false
	}
	return "AGENT", theme.Current.Accent, true
}

// agentRcptName is the lane's committed file shape — RCPT-<8hex>-<8hex>
// (the "~" publish temp and foreign files never qualify).
func agentRcptName(name string) bool {
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

// agentSaw/agentRemember are the consumed-name set. A name is processed
// exactly once: the writer never reuses one, so dropping the oldest half
// at the bound cannot resurrect work.
func agentSaw(name string) bool {
	for _, s := range agentSeen {
		if s == name {
			return true
		}
	}
	return false
}

func agentRemember(name string) {
	agentSeen = append(agentSeen, name)
	if len(agentSeen) > agentSeenMax {
		agentSeen = append(agentSeen[:0], agentSeen[agentSeenMax/2:]...)
	}
}

// agentMacEq compares the 32-byte MAC to its 64-char hex line,
// constant-time over the tag (the GOTOP discipline — a non-hex byte
// fails).
func agentMacEq(mac, hex []byte) bool {
	if len(hex) != 64 || len(mac) != 32 {
		return false
	}
	var diff byte
	for i := 0; i < 32; i++ {
		hi, ok1 := agentNibble(hex[2*i])
		lo, ok2 := agentNibble(hex[2*i+1])
		if !ok1 || !ok2 {
			return false
		}
		diff |= mac[i] ^ (hi<<4 | lo)
	}
	return diff == 0
}

func agentNibble(c byte) (byte, bool) {
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

// --- the bounded receipt scanner ------------------------------------------------
//
// The receipt's line 1 is one flat object with one nested args object,
// written by the lane's own emit. Rather than a JSON package the ELF
// budget refuses (the ADR 0042 §1 rule agentd and GOTOP hold), the
// scanner finds `"key":` at top level and takes the value in its raw
// shape: a quoted string (returned unescape-lite), a bare number, or a
// balanced {} object. A receipt that scans dirty is refused by the
// caller — and every input here already passed the MAC, so dirty means
// the writer's own shape changed.

// agentField returns the top-level string field, unescape-lite (\" and
// \\ only — anything else stays as written).
func agentField(b []byte, key string) (string, bool) {
	v, ok := agentValue(b, key)
	if !ok || len(v) == 0 || v[0] != '"' {
		return "", false
	}
	s := v[1 : len(v)-1]
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) && (s[i+1] == '"' || s[i+1] == '\\') {
			out = append(out, s[i+1])
			i++
			continue
		}
		out = append(out, s[i])
	}
	return string(out), true
}

// agentObject returns the top-level field's raw balanced {...} block,
// braces included — the nested args object the milestone check reads.
func agentObject(b []byte, key string) (string, bool) {
	v, ok := agentValue(b, key)
	if !ok || len(v) == 0 || v[0] != '{' {
		return "", false
	}
	return string(v), true
}

// agentNumber returns the top-level field's bare number.
func agentNumber(b []byte, key string) (int64, bool) {
	v, ok := agentValue(b, key)
	if !ok || len(v) == 0 {
		return 0, false
	}
	var n int64
	neg := false
	for i, c := range v {
		if i == 0 && c == '-' {
			neg = true
			continue
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
	}
	if neg {
		n = -n
	}
	return n, true
}

// agentValue walks one flat object and returns the named field's raw
// value: a quoted string including its quotes, a balanced {} or []
// block including its brackets, or a bare token ended by , or }. The
// walk is sequential — keys are read where the grammar puts them, so a
// "verb" nested inside args can never answer a top-level lookup.
// ok=false when the object is malformed, the key is absent, or the
// value is unterminated.
func agentValue(b []byte, key string) ([]byte, bool) {
	i := 0
	ws := func() {
		for i < len(b) && (b[i] == ' ' || b[i] == '\t' || b[i] == '\r' || b[i] == '\n') {
			i++
		}
	}
	keyAt := func() (string, bool) {
		ws()
		if i >= len(b) || b[i] != '"' {
			return "", false
		}
		i++
		start := i
		for i < len(b) {
			if b[i] == '\\' {
				i += 2
				continue
			}
			if b[i] == '"' {
				s := string(b[start:i])
				i++
				return s, true
			}
			i++
		}
		return "", false
	}
	valAt := func() ([]byte, bool) {
		ws()
		if i >= len(b) {
			return nil, false
		}
		start := i
		switch b[i] {
		case '"':
			i++
			for i < len(b) {
				if b[i] == '\\' {
					i += 2
					continue
				}
				if b[i] == '"' {
					i++
					return b[start:i], true
				}
				i++
			}
			return nil, false
		case '{', '[':
			open, close := b[i], byte('}')
			if open == '[' {
				close = ']'
			}
			depth := 0
			for i < len(b) {
				c := b[i]
				if c == '"' {
					// keyAt leaves i one past the closing quote,
					// which is where the object scan resumes.
					if _, ok := keyAt(); !ok {
						return nil, false
					}
					continue
				}
				if c == open {
					depth++
				} else if c == close {
					depth--
					if depth == 0 {
						i++
						return b[start:i], true
					}
				}
				i++
			}
			return nil, false
		default:
			for i < len(b) && b[i] != ',' && b[i] != '}' && b[i] != ']' &&
				b[i] != ' ' && b[i] != '\t' && b[i] != '\r' && b[i] != '\n' {
				i++
			}
			if i == start {
				return nil, false
			}
			return b[start:i], true
		}
	}
	ws()
	if i >= len(b) || b[i] != '{' {
		return nil, false
	}
	i++
	ws()
	if i < len(b) && b[i] == '}' {
		return nil, false
	}
	for {
		k, ok := keyAt()
		if !ok {
			return nil, false
		}
		ws()
		if i >= len(b) || b[i] != ':' {
			return nil, false
		}
		i++
		v, ok := valAt()
		if !ok {
			return nil, false
		}
		if k == key {
			return v, true
		}
		ws()
		if i >= len(b) {
			return nil, false
		}
		if b[i] == '}' {
			return nil, false
		}
		if b[i] != ',' {
			return nil, false
		}
		i++
	}
}

// agentMark makes a receipt field marker-safe: bounded to agentFieldMax
// and control bytes folded to '?' — a newline inside a quoted field
// would otherwise split the line a gate greps (the dropName rule).
func agentMark(s string) string {
	if len(s) > agentFieldMax {
		s = s[:agentFieldMax]
	}
	out := make([]byte, len(s))
	for i, c := range []byte(s) {
		if c < 0x20 || c == 0x7f {
			c = '?'
		}
		out[i] = c
	}
	return string(out)
}
