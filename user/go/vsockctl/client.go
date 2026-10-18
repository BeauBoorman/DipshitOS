package vsockctl

import (
	"errors"
	"io"
)

// Transport is the byte seam a session rides: the eventual EL0 binding's
// sys_vsock_ctl handle on the guest, a scripted pipe in tests. Lines are
// written whole; reads may arrive split arbitrarily.
type Transport interface {
	io.Reader
	io.Writer
}

var (
	// ErrRefused is any well-formed refusal the host named — Code names it.
	ErrRefused = errors.New("vsockctl: refused")
	// ErrAuth marks a session that never authenticated (the reply's Code
	// says which of auth_required/auth_failed/auth_timeout it was).
	ErrAuth = errors.New("vsockctl: auth refused")
)

// Session is one authenticated connection's request/answer state. The id
// counter is the replay check the host enforces — Call issues 1, 2, 3...
// and a transport-level rewind can only ever produce the refusal.
type Session struct {
	key     []byte
	n       uint32 // last issued id
	pending []byte // bytes read past the last complete line
}

// NewSession binds the `vsock-ctl` credential bytes (value verbatim from
// the SECRETS.TXT row) to a not-yet-authenticated session.
func NewSession(key []byte) *Session { return &Session{key: key} }

// Handshake reads the greeting, answers the challenge, and requires the
// ready line. On refusal the session is dead — the host closes the
// connection after the error line.
func (s *Session) Handshake(t Transport) error {
	line, err := s.readLine(t, PreAuthMax)
	if err != nil {
		return err
	}
	g, ok := ParseGreeting(line)
	if !ok {
		return ErrProtocol
	}
	if _, err := t.Write(AuthLine(s.key, g.Challenge)); err != nil {
		return err
	}
	line, err = s.readLine(t, LineMax)
	if err != nil {
		return err
	}
	// The ready line is `{"ok":true,...}`; a refusal is the same shape
	// with ok:false and an error.code.
	m, ok := parseObject(line)
	if !ok {
		return ErrProtocol
	}
	if m["ok"] == "true" {
		return nil
	}
	// A pre-ready refusal carries no id — read the nested error directly.
	if raw, present := m["error"]; present {
		if em, eok := parseObject([]byte(raw)); eok && em["code"] != "" {
			return &ReplyError{Code: em["code"]}
		}
	}
	return ErrAuth
}

// ReplyError is a named host refusal (the ADR 0056 D4 vocabulary).
type ReplyError struct{ Code string }

func (e *ReplyError) Error() string { return "vsockctl: refused " + e.Code }

// Call sends one request and returns its reply. A refusal reply is a
// *ReplyError — non-fatal codes leave the session usable.
func (s *Session) Call(t Transport, verb, name string) (Reply, error) {
	req, err := EncodeRequest(s.n+1, verb, name)
	if err != nil {
		return Reply{}, err
	}
	if _, err := t.Write(req); err != nil {
		return Reply{}, err
	}
	line, err := s.readLine(t, LineMax)
	if err != nil {
		return Reply{}, err
	}
	r, err := ParseReply(line)
	if err != nil {
		return Reply{}, err
	}
	if r.ID != s.n+1 {
		return Reply{}, ErrProtocol
	}
	s.n++
	if !r.OK {
		return r, &ReplyError{Code: r.Code}
	}
	return r, nil
}

// readLine accumulates until LF (stripped), capping at limit bytes
// including the terminator. Bytes past the first LF stay in s.pending —
// a read may carry several lines (or half of one).
func (s *Session) readLine(t Transport, limit int) ([]byte, error) {
	var chunk [512]byte
	for {
		for i, c := range s.pending {
			if c == '\n' {
				line := s.pending[:i]
				if i > 0 && s.pending[i-1] == '\r' {
					line = s.pending[:i-1]
				}
				out := make([]byte, len(line))
				copy(out, line)
				s.pending = append(s.pending[:0], s.pending[i+1:]...)
				return out, nil
			}
		}
		if len(s.pending) >= limit {
			s.pending = s.pending[:0]
			return nil, ErrProtocol
		}
		n, err := t.Read(chunk[:])
		if err != nil {
			return nil, err
		}
		s.pending = append(s.pending, chunk[:n]...)
	}
}
