// Package vsockctl is the guest half of the virelai-ctl/1 control channel
// (M115b, issue #2461, ADR 0056): newline-delimited flat JSON over a
// virtio-vsock stream to the runner's --vsock-ctl listener, behind an
// HMAC-SHA256 challenge.
//
// This package is wire + session logic only, transport-injected — the
// same shape hostint takes for the file lanes. The v1 in-guest initiator
// is the kernel's `vsock ctl` monitor path (kernel/src/vsock_ctl.zig);
// the EL0 binding arrives with the sys_vsock_ctl ABI slot (ADR 0056 D5).
// encoding/json is deliberately not imported (ADR 0042 §1 ELF ceiling).
package vsockctl

import (
	"errors"
	"fmt"
	"strconv"

	"virelai/shlib"
)

// Wire constants (ADR 0056 D1/D2). The port is the runner's
// --vsock-ctl-port default; the secret row is the uid_system credential
// both ends read.
const (
	Proto      = "virelai-ctl/1"
	AuthDomain = "VIRELAI-CTL/1 hmac-sha256"
	SecretName = "vsock-ctl"
	SecretUID  = 0
	Port       = 1209

	// Line bounds count the LF. Pre-auth the peer may only send the
	// greeting; post-auth requests and replies stay small.
	PreAuthMax = 256
	LineMax    = 1024
)

// The refusal vocabulary (ADR 0056 D4), one set of names on both ends.
const (
	CodeBadJSON       = "bad_json"
	CodeBadRequest    = "bad_request"
	CodeUnknownVerb   = "unknown_verb"
	CodeNameRejected  = "name_rejected"
	CodeReplay        = "replay"
	CodeUnimplemented = "unimplemented"
	CodeAuthRequired  = "auth_required"
	CodeAuthFailed    = "auth_failed"
	CodeAuthTimeout   = "auth_timeout"
	CodeLineTooLong   = "line_too_long"
	CodeIdleTimeout   = "idle_timeout"
	CodeIO            = "io_error"
)

// ErrProtocol marks a peer line that fails the fixed-shape grammar.
var ErrProtocol = errors.New("vsockctl: malformed line")

// encodable reports whether word can sit inside a JSON string without
// escapes — the request grammar's charset, `[A-Za-z0-9._-]`. Grammar
// refusals are the host's job; this is encoding safety only.
func encodable(word string) bool {
	if len(word) == 0 || len(word) > 31 {
		return false
	}
	for i := 0; i < len(word); i++ {
		c := word[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

const hexDigits = "0123456789abcdef"

// AuthLine answers a greeting's challenge: the `{"auth":"<64 hex>"}` line
// (LF-terminated) whose MAC is HMAC-SHA256(key, AuthDomain || 0x00 ||
// challenge). key is the secret row's value bytes verbatim.
func AuthLine(key []byte, challenge [32]byte) []byte {
	msg := make([]byte, 0, len(AuthDomain)+33)
	msg = append(msg, AuthDomain...)
	msg = append(msg, 0)
	msg = append(msg, challenge[:]...)
	mac := shlib.HMACSHA256(key, msg)
	var out [12 + 64 + 2]byte
	n := copy(out[:], `{"auth":"`)
	for i := 0; i < 32; i++ {
		out[n] = hexDigits[mac[i]>>4]
		out[n+1] = hexDigits[mac[i]&0xf]
		n += 2
	}
	out[n] = '"'
	out[n+1] = '}'
	out[n+2] = '\n'
	return out[:n+3]
}

// EncodeRequest builds `{"id":N,"verb":"<v>"[,"name":"<n>"]}` + LF.
// id is the per-session counter the host checks for strict +1 growth
// (a repeat is `replay`). An unencodable word is a local error — the
// wire never carries it.
func EncodeRequest(id uint32, verb, name string) ([]byte, error) {
	if id == 0 {
		return nil, errors.New("vsockctl: id starts at 1")
	}
	if !encodable(verb) || (name != "" && !encodable(name)) {
		return nil, errors.New("vsockctl: word outside the request charset")
	}
	var line []byte
	if name != "" {
		line = []byte(fmt.Sprintf(`{"id":%d,"verb":"%s","name":"%s"}`, id, verb, name))
	} else {
		line = []byte(fmt.Sprintf(`{"id":%d,"verb":"%s"}`, id, verb))
	}
	return append(line, '\n'), nil
}

// ---------------------------------------------------------------------------
// The flat-object reader: one JSON object per line; string (with escapes),
// unsigned integer, or true/false values; no null, arrays or nesting.
// ---------------------------------------------------------------------------

func hexVal(c byte) (int, bool) {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0'), true
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10, true
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10, true
	}
	return 0, false
}

// parseString consumes a quoted JSON string; out receives the decoded
// value (escapes resolved, invalid UTF-8 left as-is byte-wise).
func parseString(b []byte) (string, []byte, bool) {
	if len(b) == 0 || b[0] != '"' {
		return "", b, false
	}
	out := make([]byte, 0, len(b))
	i := 1
	for i < len(b) {
		c := b[i]
		if c == '"' {
			return string(out), b[i+1:], true
		}
		if c == '\\' {
			if i+1 >= len(b) {
				return "", nil, false
			}
			switch b[i+1] {
			case '"', '\\', '/':
				out = append(out, b[i+1])
			case 'n':
				out = append(out, '\n')
			case 't':
				out = append(out, '\t')
			case 'r':
				out = append(out, '\r')
			case 'b':
				out = append(out, '\b')
			case 'f':
				out = append(out, '\f')
			case 'u':
				if i+5 >= len(b) {
					return "", nil, false
				}
				var v int
				for j := 2; j < 6; j++ {
					h, ok := hexVal(b[i+j])
					if !ok {
						return "", nil, false
					}
					v = v<<4 | h
				}
				if v >= 0x80 {
					// Keep the parser tiny: non-ASCII escapes encode as
					// '?' — the ctl grammar carries only ASCII fields.
					out = append(out, '?')
				} else {
					out = append(out, byte(v))
				}
				i += 4
			default:
				return "", nil, false
			}
			i += 2
			continue
		}
		if c < 0x20 {
			return "", nil, false
		}
		out = append(out, c)
		i++
	}
	return "", nil, false
}

// skipNested consumes one balanced {...} or [...] span (string-aware) —
// used to carry a reply's nested "error" object as raw text the caller
// may parse again. Returns the byte count, 0 when unbalanced.
func skipNested(b []byte) int {
	if len(b) == 0 || (b[0] != '{' && b[0] != '[') {
		return 0
	}
	var open, close byte = b[0], '}'
	if b[0] == '[' {
		close = ']'
	}
	depth := 0
	for i := 0; i < len(b); i++ {
		switch b[i] {
		case '"':
			_, rest, ok := parseString(b[i:])
			if !ok {
				return 0
			}
			i = len(b) - len(rest) - 1
		case open:
			depth++
		case close:
			depth--
			if depth == 0 {
				return i + 1
			}
		}
	}
	return 0
}

// parseObject reads the ctl line grammar: `{"k":v,...}` where v is a
// string, a uint, true/false, or a nested object/array captured verbatim
// (the reply's "error" member and the ready line's "verbs" list are the
// only nested values; "error" is re-parsed on demand). `null` values are
// refused, as are duplicate keys and trailing bytes.
func parseObject(b []byte) (map[string]string, bool) {
	m := make(map[string]string)
	i := 0
	skip := func() {
		for i < len(b) && (b[i] == ' ' || b[i] == '\t') {
			i++
		}
	}
	skip()
	if i >= len(b) || b[i] != '{' {
		return nil, false
	}
	i++
	skip()
	if i < len(b) && b[i] == '}' {
		return m, i+1 == len(b)
	}
	for {
		skip()
		var key string
		var ok bool
		key, rest, ok := parseString(b[i:])
		if !ok {
			return nil, false
		}
		i = len(b) - len(rest)
		if _, dup := m[key]; dup {
			return nil, false
		}
		skip()
		if i >= len(b) || b[i] != ':' {
			return nil, false
		}
		i++
		skip()
		if i >= len(b) {
			return nil, false
		}
		switch c := b[i]; {
		case c == '"':
			var v string
			v, rest, ok = parseString(b[i:])
			if !ok {
				return nil, false
			}
			m[key] = v
			i = len(b) - len(rest)
		case c >= '0' && c <= '9':
			j := i
			for j < len(b) && b[j] >= '0' && b[j] <= '9' {
				j++
			}
			m[key] = string(b[i:j])
			i = j
		case c == 't' || c == 'f':
			for _, lit := range []string{"true", "false"} {
				if len(b)-i >= len(lit) && string(b[i:i+len(lit)]) == lit {
					m[key] = lit
					i += len(lit)
					ok = true
					break
				}
			}
			if !ok {
				return nil, false
			}
		case c == '{', c == '[':
			n := skipNested(b[i:])
			if n == 0 {
				return nil, false
			}
			m[key] = string(b[i : i+n])
			i += n
		default:
			return nil, false
		}
		skip()
		if i >= len(b) {
			return nil, false
		}
		if b[i] == '}' {
			return m, i+1 == len(b)
		}
		if b[i] != ',' {
			return nil, false
		}
		i++
	}
}

// Greeting is the server's first line.
type Greeting struct {
	Proto     string
	Auth      string
	Challenge [32]byte
}

// ParseGreeting reads `{"proto":"virelai-ctl/1","auth":"hmac-sha256",
// "challenge":"<64 hex>"}`. ok=false when the shape or the 32-byte hex
// challenge doesn't parse — the client refuses, never guesses.
func ParseGreeting(line []byte) (g Greeting, ok bool) {
	m, ok := parseObject(line)
	if !ok || len(m) != 3 {
		return g, false
	}
	if m["proto"] != Proto || m["auth"] != "hmac-sha256" {
		return g, false
	}
	hexCh := m["challenge"]
	if len(hexCh) != 64 {
		return g, false
	}
	for i := 0; i < 32; i++ {
		hi, ok1 := hexVal(hexCh[i*2])
		lo, ok2 := hexVal(hexCh[i*2+1])
		if !ok1 || !ok2 {
			return g, false
		}
		g.Challenge[i] = byte(hi<<4 | lo)
	}
	g.Proto = m["proto"]
	g.Auth = m["auth"]
	return g, true
}

// Reply is one post-auth answer line's verdict fields.
type Reply struct {
	ID      uint32
	OK      bool
	Code    string // "" on success
	Message string
}

// ParseReply reads `{"id":N,"ok":...}` (result or error.code). A line
// that is valid JSON but not a reply shape is ErrProtocol.
func ParseReply(line []byte) (Reply, error) {
	m, ok := parseObject(line)
	if !ok {
		return Reply{}, ErrProtocol
	}
	var r Reply
	idstr, present := m["id"]
	if !present {
		return Reply{}, ErrProtocol
	}
	id, err := strconv.ParseUint(idstr, 10, 32)
	if err != nil {
		return Reply{}, ErrProtocol
	}
	r.ID = uint32(id)
	switch m["ok"] {
	case "true":
		r.OK = true
	case "false":
		r.OK = false
	default:
		return Reply{}, ErrProtocol
	}
	// The "error" member is the one nested value the wire carries; it was
	// captured verbatim, so parse it again for code/message.
	if !r.OK {
		if raw, present := m["error"]; present {
			if em, eok := parseObject([]byte(raw)); eok {
				r.Code = em["code"]
				r.Message = em["message"]
			}
		}
		if r.Code == "" {
			return Reply{}, ErrProtocol
		}
	}
	return r, nil
}
