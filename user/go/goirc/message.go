package main

import "strings"

// RFC 1459/2812 wire message: [:prefix] COMMAND p1 p2 ... :trailing, one
// line, capped at 512 bytes INCLUDING the CRLF (so 510 payload bytes).
// ParseLine consumes one line WITHOUT the terminator (the splitter owns
// framing); encode refuses an overlong serialisation instead of silently
// truncating a command the peer would then misread.

const (
	// MaxLineBytes is the RFC bound: 512 octets of line including the
	// CRLF pair. Payload space is therefore 510.
	MaxLineBytes     = 512
	maxPayloadBytes  = MaxLineBytes - 2
	maxParams        = 15 // RFC 2812 2.3.1 middle+trailing bound
	errLineOverlong  = "goirc: line over 512 B"
	errLineMalformed = "goirc: malformed line"
)

type ircError string

func (e ircError) Error() string { return string(e) }

// Message is one parsed IRC line. Prefix is the optional leading
// ":server|nick!user@host". Command is the verb (PRIVMSG, JOIN, ...) or a
// three-digit numeric, stored upper-cased. Params are the middle
// arguments; Trailing carries the " :rest of line" field when HasTrailing
// is set (a present-but-empty trailing is legal and distinct from absent).
type Message struct {
	Prefix      string
	Command     string
	Params      []string
	Trailing    string
	HasTrailing bool
}

// Numeric reports the command as a three-digit reply (001, 353, 433 ...)
// or -1 for a verb line.
func (m Message) Numeric() int {
	if len(m.Command) != 3 {
		return -1
	}
	n := 0
	for i := 0; i < 3; i++ {
		c := m.Command[i]
		if c < '0' || c > '9' {
			return -1
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// NickFromPrefix splits "nick!user@host" to the bare nick; a bare server
// name (no ! or @) comes back whole.
func (m Message) NickFromPrefix() string {
	p := m.Prefix
	for i := 0; i < len(p); i++ {
		if p[i] == '!' || p[i] == '@' {
			return p[:i]
		}
	}
	return p
}

// ParseLine decodes one terminator-free line. A line longer than 510
// bytes (the payload share of the 512 B cap) is refused, as is a line
// that cannot be framed at all.
func ParseLine(line string) (Message, error) {
	var m Message
	if len(line) == 0 {
		return m, ircError(errLineMalformed)
	}
	if len(line) > maxPayloadBytes {
		return m, ircError(errLineOverlong)
	}
	rest := line
	if rest[0] == ':' {
		i := strings.IndexByte(rest, ' ')
		if i < 0 {
			return m, ircError(errLineMalformed)
		}
		m.Prefix = rest[1:i]
		rest = rest[i+1:]
		// Skip the run of spaces between prefix and command; a line
		// that BEGINS with a space (no prefix) is malformed.
		for len(rest) > 0 && rest[0] == ' ' {
			rest = rest[1:]
		}
	} else if rest[0] == ' ' {
		return m, ircError(errLineMalformed)
	}
	if len(rest) == 0 {
		return m, ircError(errLineMalformed)
	}
	// Command ends at the first space or runs to EOL.
	if i := strings.IndexByte(rest, ' '); i >= 0 {
		m.Command = rest[:i]
		rest = rest[i+1:]
	} else {
		m.Command = rest
		rest = ""
	}
	m.Command = strings.ToUpper(m.Command)
	// Params: whitespace-separated middles; a param starting ':' (after
	// skipping spaces) swallows the remainder as the trailing field.
	for len(rest) > 0 {
		for len(rest) > 0 && rest[0] == ' ' {
			rest = rest[1:]
		}
		if len(rest) == 0 {
			break
		}
		if rest[0] == ':' {
			m.Trailing = rest[1:]
			m.HasTrailing = true
			break
		}
		if len(m.Params) >= maxParams {
			return m, ircError(errLineMalformed)
		}
		if i := strings.IndexByte(rest, ' '); i >= 0 {
			m.Params = append(m.Params, rest[:i])
			rest = rest[i+1:]
		} else {
			m.Params = append(m.Params, rest)
			rest = ""
		}
	}
	if len(m.Command) == 0 {
		return m, ircError(errLineMalformed)
	}
	return m, nil
}

// Encode serialises m to its wire line WITH the CRLF. It refuses a frame
// that would exceed the 512 B cap or carry an interior CR/LF/NUL — the
// caller (the UI's send path) splits or rejects instead of emitting a
// line the peer parses as two.
func (m Message) Encode() ([]byte, error) {
	n := len(m.Command)
	if m.Prefix != "" {
		n += 1 + len(m.Prefix) + 1
	}
	for _, p := range m.Params {
		n += 1 + len(p)
	}
	if m.HasTrailing {
		n += 2 + len(m.Trailing)
	}
	if n > maxPayloadBytes {
		return nil, ircError(errLineOverlong)
	}
	out := make([]byte, 0, n+2)
	if m.Prefix != "" {
		out = append(out, ':')
		out = append(out, m.Prefix...)
		out = append(out, ' ')
	}
	out = append(out, m.Command...)
	for _, p := range m.Params {
		if badParamByte(p) {
			return nil, ircError("goirc: param carries CR/LF/NUL/space")
		}
		out = append(out, ' ')
		out = append(out, p...)
	}
	if m.HasTrailing {
		out = append(out, ' ', ':')
		if badTrailingByte(m.Trailing) {
			return nil, ircError("goirc: trailing carries CR/LF/NUL")
		}
		out = append(out, m.Trailing...)
	}
	out = append(out, '\r', '\n')
	return out, nil
}

func badParamByte(s string) bool {
	if len(s) == 0 {
		return true // an empty middle cannot be framed — use trailing
	}
	// A middle that begins ':' would be re-read as the trailing field on
	// the far side; interior ':' is legal.
	if s[0] == ':' {
		return true
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == ' ' || c == '\r' || c == '\n' || c == 0 {
			return true
		}
	}
	return false
}

func badTrailingByte(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\r' || c == '\n' || c == 0 {
			return true
		}
	}
	return false
}
