package main

// smtp.go — the SMTP submission (RFC 5321/6409) subset GOMAIL speaks:
// 220 greeting, EHLO, AUTH PLAIN, MAIL FROM, RCPT TO per recipient,
// DATA with dot-stuffing, QUIT. Plaintext bodies only — the message the
// client builds is Content-Type: text/plain and nothing else. STARTTLS
// is out of scope by the card's own words: TLS rides tls.Dial at the
// transport boundary (dial.go), never an in-protocol upgrade.

import (
	"strings"

	"virelai/vi"
)

// smtpClient is one submission session over an injected WireConn.
type smtpClient struct {
	conn WireConn
	buf  []byte
	now  func() int64
}

func newSMTP(conn WireConn) *smtpClient {
	return &smtpClient{conn: conn, now: vi.Nanos}
}

// reply reads one SMTP reply: "<code> text" or the "<code>-...*<code> "
// multiline form; returns the numeric code and the text lines.
func (s *smtpClient) reply() (int, []string, error) {
	var text []string
	code := -1
	for {
		line, err := s.readLine()
		if err != nil {
			return 0, nil, err
		}
		if len(line) < 4 || line[0] < '0' || line[0] > '9' {
			return 0, nil, protoErr("smtp bad reply: ", string(line))
		}
		c := int(line[0]-'0')*100 + int(line[1]-'0')*10 + int(line[2]-'0')
		if code < 0 {
			code = c
		}
		text = append(text, string(line[4:]))
		if line[3] == ' ' {
			return c, text, nil
		}
		if line[3] != '-' {
			return 0, nil, protoErr("smtp bad reply: ", string(line))
		}
	}
}

// readLine is the SMTP CRLF framer over the shared buffered reader.
func (s *smtpClient) readLine() ([]byte, error) {
	for {
		for i := 0; i+1 < len(s.buf); i++ {
			if s.buf[i] == '\r' && s.buf[i+1] == '\n' {
				line := s.buf[:i]
				s.buf = s.buf[i+2:]
				return line, nil
			}
		}
		if len(s.buf) > 8192 {
			return nil, protoErr("smtp overlong reply", "")
		}
		b := make([]byte, 8192)
		s.conn.SetReadDeadline(s.now() + cmdWaitNs)
		n, err := s.conn.Read(b)
		if n > 0 {
			s.buf = append(s.buf, b[:n]...)
		}
		if err != nil {
			return nil, err
		}
		if n == 0 {
			return nil, protoErr("smtp eof", "")
		}
	}
}

// cmd writes one line and returns its reply code/text.
func (s *smtpClient) cmd(line string) (int, []string, error) {
	if _, err := s.conn.Write([]byte(line + "\r\n")); err != nil {
		return 0, nil, err
	}
	return s.reply()
}

// expect runs a command that must answer `want`; anything else is a
// named refusal carrying the server's code+text.
func (s *smtpClient) expect(verb, line string, want int) error {
	code, text, err := s.cmd(line)
	if err != nil {
		return err
	}
	if code != want {
		return protoErr("smtp "+verb+" refused: ", itoa(int64(code))+" "+strings.Join(text, " "))
	}
	return nil
}

// b64encode is the standard-alphabet base64 AUTH PLAIN needs — the same
// ~20 lines goirc carries against pulling encoding/base64 into the
// guest build surface.
const b64alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

func b64encode(p []byte) string {
	out := make([]byte, 0, (len(p)+2)/3*4)
	for i := 0; i < len(p); i += 3 {
		var w uint32
		n := len(p) - i
		w = uint32(p[i]) << 16
		if n > 1 {
			w |= uint32(p[i+1]) << 8
		}
		if n > 2 {
			w |= uint32(p[i+2])
		}
		out = append(out, b64alpha[(w>>18)&63], b64alpha[(w>>12)&63])
		if n > 1 {
			out = append(out, b64alpha[(w>>6)&63])
		} else {
			out = append(out, '=')
		}
		if n > 2 {
			out = append(out, b64alpha[w&63])
		} else {
			out = append(out, '=')
		}
	}
	return string(out)
}

// buildMessage renders the submit payload: minimal headers + a
// normalised-CRLF plaintext body.
func buildMessage(from string, to []string, subject, body string) []byte {
	var b strings.Builder
	b.WriteString("From: " + from + "\r\n")
	b.WriteString("To: " + strings.Join(to, ", ") + "\r\n")
	b.WriteString("Subject: " + subject + "\r\n")
	b.WriteString("Content-Type: text/plain; charset=utf-8\r\n")
	b.WriteString("\r\n")
	// Normalise bare LF to CRLF.
	body = strings.ReplaceAll(body, "\r\n", "\n")
	body = strings.ReplaceAll(body, "\r", "\n")
	b.WriteString(strings.ReplaceAll(body, "\n", "\r\n"))
	if len(body) > 0 && !strings.HasSuffix(body, "\n") {
		b.WriteString("\r\n")
	}
	return []byte(b.String())
}

// dotStuff inserts the transparency dot on every line starting with '.'.
func dotStuff(msg []byte) []byte {
	s := string(msg)
	var out []string
	for _, l := range strings.Split(s, "\r\n") {
		if strings.HasPrefix(l, ".") {
			l = "." + l
		}
		out = append(out, l)
	}
	return []byte(strings.Join(out, "\r\n"))
}

// hello runs the session front half: greeting, EHLO, optional AUTH
// PLAIN — the single-round-trip credential form (\0user\0pass in b64).
func (s *smtpClient) hello(user, pass string) error {
	code, text, err := s.reply()
	if err != nil {
		return err
	}
	if code != 220 {
		return protoErr("smtp greeting refused: ", itoa(int64(code))+" "+strings.Join(text, " "))
	}
	if err := s.expect("ehlo", "EHLO virelai", 250); err != nil {
		return err
	}
	if user != "" {
		cred := b64encode([]byte("\x00" + user + "\x00" + pass))
		if err := s.expect("auth", "AUTH PLAIN "+cred, 235); err != nil {
			return err
		}
	}
	return nil
}

// submit runs the envelope+data half after hello.
func (s *smtpClient) submit(from string, to []string, msg []byte) error {
	if err := s.expect("mail", "MAIL FROM:<"+from+">", 250); err != nil {
		return err
	}
	for _, rcpt := range to {
		if err := s.expect("rcpt", "RCPT TO:<"+rcpt+">", 250); err != nil {
			return err
		}
	}
	if err := s.expect("data", "DATA", 354); err != nil {
		return err
	}
	if _, err := s.conn.Write(append(dotStuff(msg), []byte("\r\n.\r\n")...)); err != nil {
		return err
	}
	code, text, err := s.reply()
	if err != nil {
		return err
	}
	if code != 250 {
		return protoErr("smtp data refused: ", itoa(int64(code))+" "+strings.Join(text, " "))
	}
	_, _, _ = s.cmd("QUIT") // 221 or a dead peer — the message is already in
	return s.conn.Close()
}
