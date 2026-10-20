// The M109c audit lane (ADR 0052 D4): every dispatch leaves a receipt —
// allowed and refused — plus the auth outcomes and session open/close.
// One receipt per file in /host/AGENT/AUDIT/, named
// RCPT-<epoch:8hex>-<seq:8hex> (epoch is a fresh 32-bit vi.Random draw per
// daemon start, seq per-epoch monotonic from 1 — the VHI1 epoch+seq shape,
// so cross-boot names never collide). Each file is two lines: the JSON
// receipt, then 64 lowercase hex of HMAC-SHA256(receipt key, line-1 bytes)
// — the agent-hmac row re-scoped from door key to receipt key. A forged or
// edited receipt fails the MAC; GOTOP and the host verify against the same
// SECRETS.TXT line.
//
// Files under AUDIT/ are unreachable through fs.* (the flat NAME grammar
// reserves the AUDIT segment, paths.go) and gosh.run reaching them is the
// ADR's stated residual: receipts are tamper-evident, not tamper-proof,
// which is why the gosh.run attempt is receipted BEFORE the child starts.
package main

import (
	"strings"

	"virelai/shlib"
	"virelai/vi"
)

const (
	// auditStem is the receipt filename prefix; the epoch+seq suffix makes
	// lexical order chronological within one epoch.
	auditStem = "RCPT-"
	// auditFileMax is the lane's receipt bound (D4): at the cap the daemon
	// drops the lexically smallest name before publishing the next.
	auditFileMax = 64
	// auditKeyMax bounds the agent-hmac row read. The value bytes are the
	// HMAC key verbatim (the a5x32 precedent); the row is never decoded.
	auditKeyMax = 256
	// auditCanon is auditDir in the canonical form the paged listing
	// takes (dirSnapshot prepends /host).
	auditCanon = "/AGENT/AUDIT"
)

// receiptKeyMax bounds the key buffer auditInit fills.
const receiptKeyMax = auditKeyMax

// auditLane is the daemon's receipt state: the loaded key, this boot's
// epoch, the next seq, and the sorted RCPT-* names the bound rotates over.
// names is loaded once at start and kept by the writer itself — receipts
// are only ever appended by this process, so the sorted view never goes
// stale inside a boot.
type auditLane struct {
	key   []byte
	epoch uint32
	seq   uint32
	names []string
}

var lane auditLane

// Seams for the audit lane's kernel calls beyond the shared verb seams:
// the paged directory listing and the wall clock.
var (
	auditListFn = auditList
	timeFn      = vi.Time
)

// auditList returns the AUDIT directory's RCPT-* names sorted ascending —
// the drop candidate is always names[0]. "~" publish temps and foreign
// files are skipped (WriteFileSafe's temp is one byte past the receipt
// name). A listing failure returns nil: the writer still publishes, the
// bound simply has nothing to rotate against.
func auditList() []string {
	items, err := vi.ListDirAt(auditCanon)
	if err != nil {
		return nil
	}
	var names []string
	for _, it := range items {
		if validReceiptName(it.Name) {
			names = insertName(names, it.Name)
		}
	}
	return names
}

// validReceiptName reports whether name is RCPT-<8hex>-<8hex> — the only
// shape the lane rotates or the viewer reads.
func validReceiptName(name string) bool {
	if len(name) != len(auditStem)+17 || !strings.HasPrefix(name, auditStem) {
		return false
	}
	if name[len(auditStem)+8] != '-' {
		return false
	}
	for i := len(auditStem); i < len(name); i++ {
		if i == len(auditStem)+8 {
			continue
		}
		c := name[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F') {
			return false
		}
	}
	return true
}

// insertName inserts name into the sorted list (binary search, stays
// sorted — the same discipline the keyring's row order keeps).
func insertName(names []string, name string) []string {
	lo, hi := 0, len(names)
	for lo < hi {
		mid := (lo + hi) / 2
		if names[mid] < name {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	names = append(names, "")
	copy(names[lo+1:], names[lo:])
	names[lo] = name
	return names
}

// hex8u renders v as 8 lowercase hex digits (the epoch and seq fields).
func hex8u(v uint32) string {
	var b [8]byte
	for i := 0; i < 8; i++ {
		b[i] = hexDigits[(v>>uint((7-i)*4))&0xf]
	}
	return string(b[:])
}

// auditInit loads the receipt key and this boot's epoch, and snapshots the
// lane's existing names for the rotation bound. It runs once at start,
// after the AUDIT posture check; "" means armed, else the refusal reason
// the caller exits with (credential and entropy are posture, not flags —
// a daemon that cannot receipt does not serve, D1 check 5).
func auditInit() string {
	var key [receiptKeyMax]byte
	n := secretGetFn(secretName, key[:])
	if n <= 0 {
		return "no-credential"
	}
	lane.key = append(lane.key[:0], key[:n]...)
	var e [4]byte
	if m, err := randomFn(e[:]); err != nil || m != len(e) {
		return "no-entropy"
	}
	lane.epoch = uint32(e[0])<<24 | uint32(e[1])<<16 | uint32(e[2])<<8 | uint32(e[3])
	lane.seq = 0
	lane.names = auditListFn()
	return ""
}

// emit writes one receipt: the JSON line, its MAC line, then the publish.
// A write failure is one marker — audit must never take the session down
// (posture already guaranteed the lane exists), and the bound is
// best-effort around the same rule.
func (l *auditLane) emit(agent, verb, args, result string) {
	l.seq++
	var sb strings.Builder
	sb.WriteString(`{"seq":`)
	sb.WriteString(vi.Itoa64(int64(l.seq)))
	sb.WriteString(`,"epoch":`)
	jwriteStr(&sb, hex8u(l.epoch))
	sb.WriteString(`,"agent":`)
	jwriteStr(&sb, agent)
	sb.WriteString(`,"verb":`)
	jwriteStr(&sb, verb)
	sb.WriteString(`,"args":`)
	sb.WriteString(args)
	sb.WriteString(`,"ts":`)
	sb.WriteString(vi.Itoa64(timeFn()))
	sb.WriteString(`,"mono":`)
	sb.WriteString(vi.Itoa64(nanosFn()))
	sb.WriteString(`,"result":`)
	jwriteStr(&sb, result)
	sb.WriteByte('}')
	line := sb.String()
	mac := shlib.HMACSHA256(l.key, []byte(line))
	name := auditStem + hex8u(l.epoch) + "-" + hex8u(l.seq)
	body := line + "\n" + hexString(mac[:]) + "\n"
	if r := writeFileFn(auditDir+"/"+name, []byte(body)); r < 0 {
		consoleFn("agentd: audit io_error errno=" + vi.ErrnoName(r))
		return
	}
	l.names = insertName(l.names, name)
	// D4's lexical rotation reads "oldest goes first" only inside one
	// epoch: a share that outlives a boot holds earlier epochs whose
	// names may sort anywhere relative to the fresh one. A boot's own
	// receipts are always its chronologically newest, so the victim is
	// the smallest name from an EARLIER epoch — the fresh epoch never
	// eats its own evidence. When every name is the current epoch's the
	// smallest is also the chronologically oldest; either way the
	// just-written name can never be the victim.
	prefix := auditStem + hex8u(l.epoch)
	for len(l.names) > auditFileMax {
		victim := 0
		for i, n := range l.names {
			if !strings.HasPrefix(n, prefix) {
				victim = i
				break
			}
		}
		if r := deleteFileFn(auditDir + "/" + l.names[victim]); r < 0 {
			consoleFn("agentd: audit io_error errno=" + vi.ErrnoName(r))
			break
		}
		consoleFn("agentd: audit drop " + l.names[victim])
		l.names = append(l.names[:victim], l.names[victim+1:]...)
	}
}

// --- the session trail --------------------------------------------------------

// sessionTrail accumulates what one connection's audit events resolve to:
// the id the client claimed ("" until the auth line parses), whether the
// verdict succeeded, the named auth refusal, and the end reason. session()
// wraps runSession so the open/auth_fail/close events bracket the per-verb
// receipts in seq order without touching every early return.
type sessionTrail struct {
	claimed string
	authed  bool
	verdict string // the wire refusal code when auth failed
	end     string // the markerSessEnd reason
}

// auditSessionEvent emits a session-frame receipt (verb "session", args
// {"event":...}) for agent — "-" while no id has authenticated.
func auditSessionEvent(agent, event, result string) {
	var sb strings.Builder
	sb.WriteString(`{"event":`)
	jwriteStr(&sb, event)
	sb.WriteByte('}')
	lane.emit(agent, "session", sb.String(), result)
}

// --- the per-verb receipt -----------------------------------------------------

// clipStr bounds a verbatim audit field (path ≤ pathMax, cmd ≤ cmdMax) —
// the receipt ceiling holds regardless of what was typed.
func clipStr(s string, max int) string {
	if len(s) > max {
		return s[:max]
	}
	return s
}

// auditVerb emits the dispatch receipt. verb is the request's verb string
// ("-" when the line never parsed far enough to name one); args is built
// from the request's bounded metadata — path and cmd verbatim, payload
// bytes reduced to size + sha256_8, outcome fields (size, exit_status)
// lifted from the result object on ok. result is "ok" or the dispatch
// code:detail string.
func auditVerb(sess *sessionCtx, verb string, req *request, result, code string) {
	res := "ok"
	if code != "" {
		res = code
	}
	lane.emit(sess.agentID, verb, auditArgs(req, result, code), res)
}

// auditArgs renders the receipt's args object. Only bounded metadata ever
// appears: path and cmd verbatim inside their typed bounds, the payload
// digest, and the ok-side outcome fields the result object already
// carries. Never a payload byte, never a secret (D6 — cmd text is the
// stated exception).
func auditArgs(req *request, result, code string) string {
	if req == nil {
		return "{}"
	}
	var sb strings.Builder
	sb.WriteByte('{')
	n := 0
	str := func(k, v string) {
		if n > 0 {
			sb.WriteByte(',')
		}
		n++
		jwriteStr(&sb, k)
		sb.WriteByte(':')
		jwriteStr(&sb, v)
	}
	num := func(k string, v int64) {
		if n > 0 {
			sb.WriteByte(',')
		}
		n++
		jwriteStr(&sb, k)
		sb.WriteByte(':')
		sb.WriteString(vi.Itoa64(v))
	}
	if p, present, ok := req.argStr("path"); present && ok {
		str("path", clipStr(p, pathMax))
	}
	if cmd, present, ok := req.argStr("cmd"); present && ok {
		str("cmd", clipStr(cmd, cmdMax))
	}
	if pid, present, ok := req.argInt("pid", 1, intMax); present && ok {
		num("pid", pid)
	}
	if ms, present, ok := req.argInt("timeout_ms", 1, timeoutMaxMs); present && ok {
		num("timeout_ms", ms)
	}
	// ui.input (M139b): the target pane and the batch size, never the
	// event bytes themselves — a receipt names what was asked, not the
	// keys pressed.
	if win, present, ok := req.argInt("win", 0, intMax); present && ok {
		num("win", win)
	}
	if evs, present, ok := req.argArray("events"); present && ok {
		num("events", int64(len(evs)))
	}
	wroteSize := false
	if body, present, ok := req.argStr("data_b64"); present && ok {
		if data, dok := b64Decode(body); dok {
			num("size", int64(len(data)))
			wroteSize = true
			d := shlib.SHA256Sum(data)
			str("sha256_8", hexString(d[:4]))
		}
	}
	// Ok-side outcome fields ride the result object the verb already built
	// — the parse is the in-package reader, never a second opinion.
	if code == "" && result != "" {
		if v, rest, ok := parseValue([]byte(result)); ok && len(skipWS(rest)) == 0 && v.kind == jObj {
			for _, m := range v.membs {
				switch m.key {
				case "size", "exit_status", "stdout_bytes", "w", "h", "bytes":
					if m.val.kind != jNum || (m.key == "size" && wroteSize) {
						continue
					}
					if iv, ok2 := flatInt(m.val.str); ok2 {
						num(m.key, iv)
					}
				case "data_b64":
					if m.val.kind == jStr && req.verb == "fs.read" && !wroteSize {
						if data, dok := b64Decode(m.val.str); dok {
							num("size", int64(len(data)))
							d := shlib.SHA256Sum(data)
							str("sha256_8", hexString(d[:4]))
						}
					}
				case "truncated":
					if m.val.kind == jTrue {
						if n > 0 {
							sb.WriteByte(',')
						}
						n++
						jwriteStr(&sb, "truncated")
						sb.WriteString(":true")
					}
				}
			}
		}
	}
	sb.WriteByte('}')
	return sb.String()
}
