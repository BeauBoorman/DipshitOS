package main

// imap.go — the IMAP4rev1 (RFC 3501) subset GOMAIL speaks: greeting,
// LOGIN, LIST "" "*", SELECT, bounded FETCH ENVELOPE (the header list),
// FETCH BODYSTRUCTURE, FETCH BODY[section] for the one readable part,
// LOGOUT. Tagged-command/untagged-data only — no IDLE, no unsolicited
// EXPUNGE handling (a fetch-and-quit client sees none), no SASL.
//
// The wire shape is the card's "protocol-state" half: every command is
// one tagged write followed by records until the tagged status lands;
// literals ride INSIDE a record as '{n}\r\n<payload>' (RFC 3501's
// synchronising literal — the fixture's bodies are small enough that
// non-synchronising '+' handling is out of scope and named-refused at
// the parser bound).

import (
	"strings"

	"virelai/vi"
	"virelai/vsys"
)

// mailError is the named-refusal / protocol-error carrier — its text IS
// the marker vocabulary the gate matches.
type mailError struct{ s string }

func (e mailError) Error() string { return e.s }

func protoErr(format string, a string) error {
	return mailError{"gomail: " + format + a}
}

const (
	cmdWaitNs   = int64(30 * 1000 * 1000 * 1000) // per-command read bound
	maxUntagged = 512                            // records per command
)

// itoa is the decimal formatter the tag counter and FETCH sets use.
func itoa(v int64) string { return vsys.Itoa64(v) }

// Header is one FETCH ENVELOPE row the headers verb prints.
type Header struct {
	Seq     int
	From    string
	Subject string
	Date    string
}

// imapClient is one IMAP session over an injected WireConn — the tests
// drive it with recorded transcripts, the guest with dialOne.
type imapClient struct {
	conn WireConn
	tag  int
	buf  []byte
	now  func() int64
}

func newIMAP(conn WireConn) *imapClient {
	return &imapClient{conn: conn, now: vi.Nanos}
}

// --- record layer -----------------------------------------------------

// fill appends at least one read to buf (or the read error).
func (c *imapClient) fill() error {
	b := make([]byte, 8192)
	c.conn.SetReadDeadline(c.now() + cmdWaitNs)
	n, err := c.conn.Read(b)
	if n > 0 {
		c.buf = append(c.buf, b[:n]...)
	}
	if err != nil {
		return err
	}
	if n == 0 {
		return protoErr("imap eof", "")
	}
	return nil
}

// readLine returns the bytes before the next CRLF (consumed).
func (c *imapClient) readLine() ([]byte, error) {
	for {
		for i := 0; i+1 < len(c.buf); i++ {
			if c.buf[i] == '\r' && c.buf[i+1] == '\n' {
				line := c.buf[:i]
				c.buf = c.buf[i+2:]
				return line, nil
			}
		}
		if len(c.buf) > recordMax {
			return nil, protoErr("imap overlong record", "")
		}
		if err := c.fill(); err != nil {
			return nil, err
		}
	}
}

// readN consumes exactly n bytes (a literal payload).
func (c *imapClient) readN(n int) ([]byte, error) {
	for len(c.buf) < n {
		if err := c.fill(); err != nil {
			return nil, err
		}
	}
	out := make([]byte, n)
	copy(out, c.buf[:n])
	c.buf = c.buf[n:]
	return out, nil
}

// literalTail reports whether line ends with '{digits}' — the marker
// saying a literal payload continues this record — and returns n.
func literalTail(line []byte) (int, bool) {
	i := len(line) - 1
	if i < 0 || line[i] != '}' {
		return 0, false
	}
	j := i - 1
	for j >= 0 && line[j] >= '0' && line[j] <= '9' {
		j--
	}
	if j < 0 || line[j] != '{' || j == i-1 {
		return 0, false
	}
	n := 0
	for k := j + 1; k < i; k++ {
		n = n*10 + int(line[k]-'0')
		if n > literalMax {
			return 0, false
		}
	}
	return n, true
}

// readRecord reads one logical response line: text to CRLF, with every
// '{n}\r\n<payload>' literal sequence embedded inline so parseRecord can
// tokenise it as a string form.
func (c *imapClient) readRecord() ([]byte, error) {
	var rec []byte
	for {
		line, err := c.readLine()
		if err != nil {
			return nil, err
		}
		rec = append(rec, line...)
		n, ok := literalTail(line)
		if !ok {
			return rec, nil
		}
		if len(rec)+n+2 > recordMax {
			return nil, protoErr("imap oversized record", "")
		}
		rec = append(rec, '\r', '\n')
		lit, err := c.readN(n)
		if err != nil {
			return nil, err
		}
		rec = append(rec, lit...)
	}
}

// command writes one tagged command and collects untagged records until
// the tagged status. Returns the untagged token streams and the status
// ("OK"/"NO"/"BAD" + trailing text for the refusal name).
func (c *imapClient) command(cmd string) (unt [][]form, status string, err error) {
	c.tag++
	tag := "a" + itoa(int64(c.tag))
	if _, err := c.conn.Write([]byte(tag + " " + cmd + "\r\n")); err != nil {
		return nil, "", err
	}
	for i := 0; i < maxUntagged; i++ {
		rec, err := c.readRecord()
		if err != nil {
			return nil, "", err
		}
		toks, err := parseRecord(rec)
		if err != nil {
			return nil, "", err
		}
		if len(toks) == 0 {
			continue
		}
		head, _ := formStr(toks[0])
		if head == tag {
			if len(toks) < 2 {
				return unt, "", protoErr("imap bare tagged reply", "")
			}
			s, _ := formStr(toks[1])
			var rest []string
			for _, t := range toks[2:] {
				if s2, ok := formStr(t); ok {
					rest = append(rest, s2)
				}
			}
			return unt, s + " " + strings.Join(rest, " "), nil
		}
		unt = append(unt, toks)
	}
	return nil, "", protoErr("imap untagged flood", "")
}

// commandOK runs a command that must end tagged-OK; the failure string
// carries the server's own refusal text.
func (c *imapClient) commandOK(verb, cmd string) ([]form, error) {
	unt, status, err := c.command(cmd)
	if err != nil {
		return nil, err
	}
	if !strings.HasPrefix(status, "OK") {
		return nil, protoErr("imap "+verb+" refused: ", status)
	}
	// Flatten: callers want the row records, one []form each.
	out := make([]form, len(unt))
	for i := range unt {
		out[i] = unt[i]
	}
	return out, nil
}

// --- session verbs ----------------------------------------------------

// greeting consumes the server banner: '* OK'/'* PREAUTH' connect, a
// '* BYE' refuses by name.
func (c *imapClient) greeting() error {
	rec, err := c.readRecord()
	if err != nil {
		return err
	}
	toks, err := parseRecord(rec)
	if err != nil {
		return err
	}
	if len(toks) < 2 {
		return protoErr("imap short greeting", "")
	}
	star, _ := formStr(toks[0])
	kind, _ := formStr(toks[1])
	if star != "*" {
		return protoErr("imap bad greeting", "")
	}
	switch kind {
	case "OK", "PREAUTH":
		return nil
	default:
		return protoErr("imap greeting refused", "")
	}
}

// quote renders an IMAP quoted string (escape \ and ").
func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		if s[i] == '"' || s[i] == '\\' {
			b.WriteByte('\\')
		}
		b.WriteByte(s[i])
	}
	b.WriteByte('"')
	return b.String()
}

func (c *imapClient) login(user, pass string) error {
	if user == "" {
		return protoErr("imap login refused: no user", "")
	}
	_, err := c.commandOK("login", "LOGIN "+quote(user)+" "+quote(pass))
	return err
}

// list returns mailbox names from LIST "" "*".
func (c *imapClient) list() ([]string, error) {
	unt, err := c.commandOK("list", "LIST "+quote("")+" "+quote("*"))
	if err != nil {
		return nil, err
	}
	var out []string
	for _, u := range unt {
		toks, _ := u.([]form)
		if len(toks) < 4 {
			continue
		}
		star, _ := formStr(toks[0])
		verb, _ := formStr(toks[1])
		if star != "*" || verb != "LIST" {
			continue
		}
		// The name is the last token — quoted, literal, or atom.
		name, ok := formStr(toks[len(toks)-1])
		if !ok {
			continue
		}
		out = append(out, name)
	}
	return out, nil
}

// selectBox SELECTs mbox and returns the EXISTS count.
func (c *imapClient) selectBox(mbox string) (int, error) {
	unt, err := c.commandOK("select", "SELECT "+quote(mbox))
	if err != nil {
		return 0, err
	}
	exists := -1
	for _, u := range unt {
		toks, _ := u.([]form)
		if len(toks) < 3 {
			continue
		}
		star, _ := formStr(toks[0])
		num, _ := formStr(toks[1])
		kind, _ := formStr(toks[2])
		if star == "*" && kind == "EXISTS" {
			if n, ok := parseUint(num); ok {
				exists = int(n)
			}
		}
	}
	if exists < 0 {
		return 0, protoErr("imap select: no EXISTS for ", mbox)
	}
	return exists, nil
}

// fetchItems issues FETCH <set> (<items>) and returns each untagged
// '* <seq> FETCH (<pairs>)' items list keyed by its data-item names.
func (c *imapClient) fetchItems(set, items string) ([]form, error) {
	unt, err := c.commandOK("fetch", "FETCH "+set+" ("+items+")")
	if err != nil {
		return nil, err
	}
	var out []form
	for _, u := range unt {
		toks, _ := u.([]form)
		if len(toks) < 4 {
			continue
		}
		star, _ := formStr(toks[0])
		verb, _ := formStr(toks[2])
		if star != "*" || verb != "FETCH" {
			continue
		}
		out = append(out, toks)
	}
	return out, nil
}

// fetchPairs extracts the (KEY value KEY value) items of a FETCH row.
func fetchPairs(toks []form) (seq int, pairs map[string]form, ok bool) {
	seqs, _ := formStr(toks[1])
	n, _ := parseUint(seqs)
	l, isL := formList(toks[3])
	if n <= 0 || !isL {
		return 0, nil, false
	}
	pairs = map[string]form{}
	for i := 0; i+1 < len(l); i += 2 {
		k, ok := formStr(l[i])
		if !ok {
			continue
		}
		pairs[k] = l[i+1]
	}
	return int(n), pairs, true
}

// addrText renders one (name adl mbox host) address list entry.
func addrText(f form) string {
	l, ok := formList(f)
	if !ok || len(l) < 4 {
		return "?"
	}
	if name := formStrOr(l[0], ""); name != "" {
		return name
	}
	mbox := formStrOr(l[2], "")
	host := formStrOr(l[3], "")
	if mbox == "" {
		return "?"
	}
	return mbox + "@" + host
}

// envelopes fetches ENVELOPE rows for seq lo..hi (bounded by the caller).
func (c *imapClient) envelopes(lo, hi int) ([]Header, error) {
	rows, err := c.fetchItems(itoa(int64(lo))+":"+itoa(int64(hi)), "ENVELOPE")
	if err != nil {
		return nil, err
	}
	var out []Header
	for _, r := range rows {
		toks, _ := r.([]form)
		seq, pairs, ok := fetchPairs(toks)
		if !ok {
			continue
		}
		env, ok := formList(pairs["ENVELOPE"])
		if !ok || len(env) < 3 {
			continue
		}
		h := Header{Seq: seq, Date: formStrOr(env[0], ""), Subject: formStrOr(env[1], "")}
		if froms, ok := formList(env[2]); ok && len(froms) > 0 {
			h.From = addrText(froms[0])
		}
		out = append(out, h)
	}
	return out, nil
}

// structure FETCHes one message's BODYSTRUCTURE into a partInfo tree.
func (c *imapClient) structure(seq int) (*partInfo, error) {
	rows, err := c.fetchItems(itoa(int64(seq)), "BODYSTRUCTURE")
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		toks, _ := r.([]form)
		got, pairs, ok := fetchPairs(toks)
		if !ok || got != seq {
			continue
		}
		bs, ok := formList(pairs["BODYSTRUCTURE"])
		if !ok {
			return nil, protoErr("imap bodystructure not a list", "")
		}
		return walkPart(bs, ""), nil
	}
	return nil, protoErr("imap no bodystructure for ", itoa(int64(seq)))
}

// section FETCHes BODY[part] of seq and returns the literal bytes.
// part "TEXT" is the single-part spelling.
func (c *imapClient) section(seq int, part string) ([]byte, error) {
	key := "BODY[" + part + "]"
	rows, err := c.fetchItems(itoa(int64(seq)), key)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		toks, _ := r.([]form)
		got, pairs, ok := fetchPairs(toks)
		if !ok || got != seq {
			continue
		}
		if s, ok := formStr(pairs[key]); ok {
			return []byte(s), nil
		}
		// Some servers answer BODY[TEXT] for BODY[1] on single parts.
		for k, v := range pairs {
			if strings.HasPrefix(k, "BODY[") {
				if s, ok := formStr(v); ok {
					return []byte(s), nil
				}
			}
		}
		return nil, protoErr("imap empty body for ", itoa(int64(seq)))
	}
	return nil, protoErr("imap no body for ", itoa(int64(seq)))
}

// logout sends LOGOUT and drains the BYE; a dead peer is fine.
func (c *imapClient) logout() {
	_, _, _ = c.command("LOGOUT")
	_ = c.conn.Close()
}
