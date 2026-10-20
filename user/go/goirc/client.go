package main

// Client is the M147a protocol core: one IRC session (RFC 1459/2812
// subset — NICK, USER, JOIN, PART, PRIVMSG, NOTICE, PING/PONG, QUIT,
// numerics 001/353/366/433/474, optional SASL PLAIN) over an injected
// WireConn, with a bounded reconnect/backoff state machine and the
// 256-line per-channel backlog ring the M147b UI reads.
//
// The core never dials by itself: a Dialer builds the transport
// (dial.go wires tls.Dial on 6697 / vi.Dial on 6667 for the guest, the
// tests inject fakes), and every state change goes out as an Event so a
// UI layer renders without touching the socket. Plaintext is refused
// unless Config.AllowPlain — the session config's consent bit — is set;
// dial.go's guest dialer is the one place that enforces it.

import (
	"errors"
	"sort"
	"strings"
	"sync"

	"virelai/tls"
	"virelai/vi"
)

// ConnState is the coarse phase the UI renders.
type ConnState int

const (
	StateIdle ConnState = iota
	StateDialing
	StateRegistering // NICK/USER sent, waiting for 001 (or a fatal numeric)
	StateOnline      // 001 seen; channel traffic flows
	StateBackoff     // between drops, sleeping before the next dial
	StateClosed      // Run returned
)

// EventKind names what an Event carries.
type EventKind int

const (
	EvState      EventKind = iota // .State changed
	EvEntry                       // .Entry was appended to a backlog
	EvRegistered                  // 001; .Nick is the live nick
	EvJoined                      // own JOIN confirmed; .Channel
	EvRejoined                    // own JOIN re-sent after a reconnect; .Channel
	EvJoinFail                    // e.g. 474; .Channel + .Reason
	EvNames                       // 366; .Channel + .Names
	EvNickInUse                   // 433 retries exhausted during registration
	EvSASLResult                  // .Text "ok"|"fail", .Err on fail
	EvDrop                        // the transport died; .Err
	EvBackoff                     // sleeping .BackoffNs before redial
	EvQuit                        // local Quit acknowledged by the close
	EvError                       // non-fatal problem; .Err/.Text
)

// Event is one core→UI notification. Only the fields the Kind names are
// meaningful.
type Event struct {
	Kind      EventKind
	State     ConnState
	Entry     Entry
	Channel   string
	Nick      string
	Names     []string
	Reason    string
	Text      string
	BackoffNs int64
	Err       error
}

// SASLConfig opts into CAP SASL PLAIN during registration.
type SASLConfig struct {
	Account  string
	Password string
}

// Config is the session configuration — what M147b's save_state
// persists and what the console driver's argv builds.
type Config struct {
	Host string
	Port uint16

	Nick     string
	User     string
	Realname string

	// TLS selects tls.Dial (port 6697 by convention). Plaintext runs
	// ONLY when AllowPlain is set — the session config's stored consent
	// answer; dialGuest refuses otherwise.
	TLS        bool
	ServerName string // SNI/verify name; empty takes Host
	AllowPlain bool

	SASL *SASLConfig // optional

	Channels []string // joined after every 001

	// Reconnect behaviour. MaxRetries > 0 bounds the number of failed
	// sessions before Run returns; 0 retries forever.
	Reconnect   bool
	MaxRetries  int
	BackoffBase int64 // ns; default BackoffBaseDefault
	BackoffMax  int64 // ns; default BackoffMaxDefault

	// Liveness: after IdlePing silence the core sends PING and gives the
	// peer PongWait to answer before declaring the connection dead.
	IdlePing int64 // ns; default 90 s
	PongWait int64 // ns; default 30 s
}

const (
	// BackoffBaseDefault is short enough for the gate's drop/reconnect
	// leg and sane for a daily session's first retry.
	BackoffBaseDefault = int64(500 * 1000 * 1000)       // 0.5 s
	BackoffMaxDefault  = int64(30 * 1000 * 1000 * 1000) // 30 s
	IdlePingDefault    = int64(90 * 1000 * 1000 * 1000) // 90 s
	PongWaitDefault    = int64(30 * 1000 * 1000 * 1000) // 30 s
	nickRetryMax       = 3
	registerWaitN      = int64(120 * 1000 * 1000 * 1000) // per-read registration bound
)

// Dialer builds one transport session.
type Dialer func() (WireConn, error)

// WireConn is the byte pipe the core drives: guest builds adapt vi.Conn
// (Send/Recv, relative recv deadline) and tls.TLSConn (Read/Write,
// absolute deadline) onto this shape.
type WireConn interface {
	Read(p []byte) (int, error)
	Write(p []byte) (int, error)
	SetReadDeadline(at int64) // absolute vi.Nanos instant; 0 clears
	Close() error
}

// Client is one configured session. Construct with NewClient, drive with
// Run; the send verbs (Join/Part/Privmsg/Quit) are safe to call from the
// UI's goroutine while Run owns the read side.
type Client struct {
	cfg   Config
	dial  Dialer
	emit  func(Event)
	now   func() int64
	sleep func(ns int64)

	mu        sync.Mutex // guards the fields below
	wmu       sync.Mutex // serialises conn.Write (PONG vs UI sends)
	conn      WireConn
	state     ConnState
	done      bool // Quit/Close asked — drops do not reconnect
	nick      string
	reg       bool // 001 seen on the CURRENT connection
	everReg   bool // 001 seen on ANY connection (reconnect detection)
	nickTries int
	want      map[string]bool     // channels to be in (join intent)
	joined    map[string]bool     // confirmed membership this connection
	pend      map[string][]string // 353 names until 366
	sasl      saslState
	await     bool // a PING is outstanding

	backlogs map[string]*Backlog // per-channel rings; "" = server/status
}

type saslState int

const (
	saslOff   saslState = iota
	saslReq             // CAP REQ :sasl sent
	saslPlain           // AUTHENTICATE PLAIN sent, want +
	saslAuth            // credentials sent, want 903/904
	saslDone
)

// NewClient builds a session. emit may be nil (events dropped); dial is
// required. Missing clock/sleep default to the guest implementations;
// the tests inject fakes.
func NewClient(cfg Config, dial Dialer, emit func(Event)) *Client {
	if cfg.BackoffBase <= 0 {
		cfg.BackoffBase = BackoffBaseDefault
	}
	if cfg.BackoffMax <= 0 {
		cfg.BackoffMax = BackoffMaxDefault
	}
	if cfg.IdlePing <= 0 {
		cfg.IdlePing = IdlePingDefault
	}
	if cfg.PongWait <= 0 {
		cfg.PongWait = PongWaitDefault
	}
	c := &Client{
		cfg:      cfg,
		dial:     dial,
		emit:     emit,
		now:      vi.Nanos,
		sleep:    sleepNs,
		want:     map[string]bool{},
		joined:   map[string]bool{},
		pend:     map[string][]string{},
		backlogs: map[string]*Backlog{"": NewBacklog(BacklogCap)},
	}
	c.nick = cfg.Nick
	for _, ch := range cfg.Channels {
		c.want[ch] = true
	}
	return c
}

// Backlog returns the named channel's ring ("" is the server/status
// buffer). A never-seen channel reports an empty ring, never nil.
func (c *Client) Backlog(channel string) *Backlog {
	c.mu.Lock()
	defer c.mu.Unlock()
	b, ok := c.backlogs[channel]
	if !ok {
		b = NewBacklog(BacklogCap)
		c.backlogs[channel] = b
	}
	return b
}

func (c *Client) backlogLocked(channel string) *Backlog {
	b, ok := c.backlogs[channel]
	if !ok {
		b = NewBacklog(BacklogCap)
		c.backlogs[channel] = b
	}
	return b
}

// Nick returns the current effective nick (433 retries may have moved it
// from Config.Nick).
func (c *Client) Nick() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.nick
}

// State returns the coarse phase.
func (c *Client) State() ConnState {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.state
}

// Joined reports the confirmed membership set (this connection).
func (c *Client) Joined() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return sortedKeys(c.joined)
}

func (c *Client) isDone() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.done
}

func (c *Client) isReg() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reg
}

func (c *Client) setState(s ConnState) {
	c.mu.Lock()
	c.state = s
	c.mu.Unlock()
	c.emitf(Event{Kind: EvState, State: s})
}

func (c *Client) emitf(e Event) {
	if c.emit != nil {
		c.emit(e)
	}
}

// appendEntry stores e in its channel's ring and emits EvEntry — the
// single funnel every rendered line takes so the UI never polls.
func (c *Client) appendEntry(e Entry) {
	c.mu.Lock()
	b := c.backlogLocked(e.Channel)
	c.mu.Unlock()
	b.Add(e)
	c.emitf(Event{Kind: EvEntry, Entry: e, Channel: e.Channel})
}

// fatalError wraps an unrecoverable condition (nick refused after all
// retries, plaintext refused, registration rejected): Run returns it
// WITHOUT reconnecting.
type fatalError struct{ err error }

func (f fatalError) Error() string { return f.err.Error() }
func (f fatalError) Unwrap() error { return f.err }

func isFatal(err error) bool {
	var f fatalError
	return errors.As(err, &f)
}

// Run drives dial → register → read → (drop) backoff → redial until
// Quit, a fatal error, or MaxRetries. It returns nil on a clean Quit.
func (c *Client) Run() error {
	fails := 0
	for {
		if c.isDone() {
			c.setState(StateClosed)
			return nil
		}
		c.setState(StateDialing)
		conn, err := c.dial()
		if err == nil {
			err = c.session(conn)
		}
		if isFatal(err) {
			c.emitf(Event{Kind: EvError, Err: err})
			c.setState(StateClosed)
			return err
		}
		if c.isDone() {
			_ = connOrNilClose(conn)
			c.setState(StateClosed)
			return nil
		}
		fails++
		c.emitf(Event{Kind: EvDrop, Err: err})
		c.appendEntry(Entry{Kind: EntryStatus, Text: "connection lost: " + errText(err), At: c.now()})
		if !c.cfg.Reconnect {
			c.setState(StateClosed)
			return err
		}
		if c.cfg.MaxRetries > 0 && fails > c.cfg.MaxRetries {
			c.appendEntry(Entry{Kind: EntryError, Text: "reconnects exhausted", At: c.now()})
			c.emitf(Event{Kind: EvError, Err: err})
			c.setState(StateClosed)
			return err
		}
		d := backoffDelay(c.cfg.BackoffBase, c.cfg.BackoffMax, fails)
		c.setState(StateBackoff)
		c.emitf(Event{Kind: EvBackoff, BackoffNs: d})
		c.sleep(d)
	}
}

func connOrNilClose(conn WireConn) error {
	if conn == nil {
		return nil
	}
	return conn.Close()
}

// backoffDelay doubles from base per failed attempt, capped at max.
func backoffDelay(base, max int64, attempt int) int64 {
	d := base
	for i := 1; i < attempt && d < max; i++ {
		d *= 2
	}
	if d > max {
		d = max
	}
	return d
}

// session runs one connection: registration then the read loop. It
// returns the error that ended the session (ErrPeerGone on a drop,
// a timeout after unanswered PING, a fatal registration refusal).
func (c *Client) session(conn WireConn) error {
	c.mu.Lock()
	c.conn = conn
	c.reg = false
	c.nickTries = 0
	c.pend = map[string][]string{}
	c.sasl = saslOff
	c.await = false
	if c.cfg.SASL != nil {
		c.sasl = saslReq
	}
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		c.conn = nil
		c.joined = map[string]bool{}
		c.mu.Unlock()
		_ = conn.Close()
	}()

	c.setState(StateRegistering)
	if c.cfg.SASL != nil {
		if err := c.send(Message{Command: "CAP", Params: []string{"REQ"}, Trailing: "sasl", HasTrailing: true}); err != nil {
			return err
		}
	}
	if err := c.send(Message{Command: "NICK", Params: []string{c.Nick()}}); err != nil {
		return err
	}
	user := c.cfg.User
	if user == "" {
		user = c.cfg.Nick
	}
	real := c.cfg.Realname
	if real == "" {
		real = user
	}
	if err := c.send(Message{Command: "USER", Params: []string{user, "0", "*"}, Trailing: real, HasTrailing: true}); err != nil {
		return err
	}

	var sp splitter
	buf := make([]byte, 4096)
	c.armRead(conn, registerWaitN)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			lines, overlong := sp.feed(buf[:n])
			if overlong {
				c.appendEntry(Entry{Kind: EntryError, Text: "overlong line dropped", At: c.now()})
				c.emitf(Event{Kind: EvError, Text: "overlong line dropped"})
			}
			for _, line := range lines {
				if err := c.handleLine(line); err != nil {
					return err
				}
			}
			c.armRead(conn, c.readWait())
		}
		if err == nil {
			continue
		}
		if isTimeoutErr(err) {
			if terr := c.onReadTimeout(conn); terr != nil {
				return terr
			}
			continue
		}
		return err
	}
}

// readWait is the current idle bound: registration window until 001,
// PongWait while a PING is out, else the idle-PING interval.
func (c *Client) readWait() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.await {
		return c.cfg.PongWait
	}
	if !c.reg {
		return registerWaitN
	}
	return c.cfg.IdlePing
}

func (c *Client) armRead(conn WireConn, wait int64) {
	conn.SetReadDeadline(c.now() + wait)
}

// onReadTimeout fires on an ETIMEDOUT-class read: idle → PING and arm
// the pong bound; a second timeout while a PING is out declares the
// peer dead and ends the session for the reconnect pass.
func (c *Client) onReadTimeout(conn WireConn) error {
	c.mu.Lock()
	awaiting := c.await
	c.mu.Unlock()
	if awaiting {
		return ircError("goirc: PONG timeout — peer declared dead")
	}
	if err := c.send(Message{Command: "PING", Trailing: "goirc", HasTrailing: true}); err != nil {
		return err
	}
	c.mu.Lock()
	c.await = true
	c.mu.Unlock()
	c.armRead(conn, c.cfg.PongWait)
	return nil
}

// handleLine parses and dispatches one wire line. Returning an error
// ends the session.
func (c *Client) handleLine(line string) error {
	m, err := ParseLine(line)
	if err != nil {
		c.appendEntry(Entry{Kind: EntryError, Text: errText(err) + ": " + line, At: c.now()})
		return nil // a bad line is dropped, not fatal
	}
	c.mu.Lock()
	c.await = false
	c.mu.Unlock()

	switch m.Command {
	case "PING":
		tok := m.Trailing
		if !m.HasTrailing && len(m.Params) > 0 {
			tok = m.Params[len(m.Params)-1]
		}
		return c.send(Message{Command: "PONG", Trailing: tok, HasTrailing: true})
	case "PONG":
		return nil
	case "CAP":
		return c.handleCAP(m)
	case "AUTHENTICATE":
		return c.handleAuthPrompt(m)
	case "JOIN":
		c.handleJoin(m)
	case "PART":
		c.handlePart(m)
	case "KICK":
		c.handleKick(m)
	case "NICK":
		c.handleNick(m)
	case "PRIVMSG", "NOTICE":
		c.handleMsg(m)
	case "MODE", "TOPIC", "QUIT":
		// Presence verbs the core does not act on in M147a; they are
		// still honest scrollback lines.
		c.handlePresence(m)
	case "ERROR":
		c.appendEntry(Entry{Kind: EntryError, Text: "server: " + m.Trailing, At: c.now()})
	default:
		if num := m.Numeric(); num >= 0 {
			if err := c.handleNumeric(num, m); err != nil {
				return err
			}
		} else {
			c.status(m, rawTrailing(m))
		}
	}
	return nil
}

func (c *Client) handleNumeric(num int, m Message) error {
	switch num {
	case 1: // RPL_WELCOME — registered
		return c.onWelcome(m)
	case 353: // RPL_NAMREPLY: <me> <sym> <chan> :<names>
		if len(m.Params) >= 3 {
			ch := m.Params[2]
			c.mu.Lock()
			c.pend[ch] = append(c.pend[ch], strings.Fields(m.Trailing)...)
			c.mu.Unlock()
		}
	case 366: // RPL_ENDOFNAMES
		if len(m.Params) >= 2 {
			ch := m.Params[1]
			c.mu.Lock()
			names := c.pend[ch]
			delete(c.pend, ch)
			c.mu.Unlock()
			c.emitf(Event{Kind: EvNames, Channel: ch, Names: names})
		}
	case 433: // ERR_NICKNAMEINUSE
		return c.onNickInUse(m)
	case 474: // ERR_BANNEDFROMCHAN: <me> <chan> :reason
		ch := ""
		if len(m.Params) >= 2 {
			ch = m.Params[1]
		}
		c.appendEntry(Entry{Kind: EntryError, Channel: ch, Text: "cannot join " + ch + ": " + m.Trailing, At: c.now()})
		c.emitf(Event{Kind: EvJoinFail, Channel: ch, Reason: m.Trailing})
	case 903: // RPL_SASLSUCCESS
		c.saslFinish(true, nil)
	case 904, 905, 906, 907: // SASL failure family
		c.saslFinish(false, ircError("goirc: SASL failed "+m.Command+" "+m.Trailing))
	case 421, 432, 461, 462, 464, 465:
		// UNKNOWNCOMMAND / ERRONEUSNICKNAME / NEEDMOREPARAMS /
		// ALREADYREGISTRED / PASSWDMISMATCH / YOUREBANNEDCREEP — during
		// registration these are fatal (the session cannot stand up);
		// online they are status lines.
		c.status(m, m.Trailing)
		if !c.isReg() {
			return fatalError{err: ircError("goirc: registration refused " + m.Command + " " + m.Trailing)}
		}
	default:
		c.status(m, rawTrailing(m))
	}
	return nil
}

// onWelcome marks the connection registered and (re)joins the intent
// set. On a reconnect the re-send itself emits EvRejoined per channel —
// the gate's rejoin marker is the re-send, the confirm stays EvJoined.
func (c *Client) onWelcome(m Message) error {
	c.mu.Lock()
	reconnect := c.everReg
	c.everReg = true
	c.reg = true
	c.nickTries = 0
	if len(m.Params) >= 1 && m.Params[0] != "" {
		c.nick = m.Params[0]
	}
	c.mu.Unlock()
	c.setState(StateOnline)
	c.emitf(Event{Kind: EvRegistered, Nick: c.Nick()})
	c.status(m, m.Trailing)

	for _, ch := range c.wantChannels() {
		if err := c.send(Message{Command: "JOIN", Params: []string{ch}}); err != nil {
			return err
		}
		if reconnect {
			c.emitf(Event{Kind: EvRejoined, Channel: ch})
		}
	}
	return nil
}

func (c *Client) wantChannels() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return sortedKeys(c.want)
}

func (c *Client) onNickInUse(m Message) error {
	c.mu.Lock()
	if c.reg {
		nick := c.nick
		c.mu.Unlock()
		c.emitf(Event{Kind: EvNickInUse, Nick: nick})
		c.appendEntry(Entry{Kind: EntryError, Text: "nick already in use", At: c.now()})
		return nil
	}
	c.nickTries++
	tries := c.nickTries
	c.mu.Unlock()
	if tries > nickRetryMax {
		c.emitf(Event{Kind: EvNickInUse, Nick: c.Nick()})
		return fatalError{err: ircError("goirc: nick in use after retries")}
	}
	next := c.Nick() + "_"
	c.mu.Lock()
	c.nick = next
	c.mu.Unlock()
	c.appendEntry(Entry{Kind: EntryStatus, Text: "nick in use — trying " + next, At: c.now()})
	return c.send(Message{Command: "NICK", Params: []string{next}})
}

func (c *Client) handleCAP(m Message) error {
	// :srv CAP <nick> <sub> :<caps>
	if len(m.Params) < 2 {
		return nil
	}
	sub := strings.ToUpper(m.Params[1])
	c.mu.Lock()
	st := c.sasl
	c.mu.Unlock()
	if st == saslOff {
		return nil
	}
	switch sub {
	case "ACK":
		c.mu.Lock()
		c.sasl = saslPlain
		c.mu.Unlock()
		return c.send(Message{Command: "AUTHENTICATE", Params: []string{"PLAIN"}})
	case "NAK":
		c.saslFinish(false, ircError("goirc: SASL not available"))
	}
	return nil
}

func (c *Client) handleAuthPrompt(m Message) error {
	// AUTHENTICATE + asks for the PLAIN payload.
	c.mu.Lock()
	st := c.sasl
	c.mu.Unlock()
	if st != saslPlain || len(m.Params) == 0 || m.Params[0] != "+" {
		return nil
	}
	c.mu.Lock()
	c.sasl = saslAuth
	c.mu.Unlock()
	payload := c.cfg.SASL.Account + "\x00" + c.cfg.SASL.Account + "\x00" + c.cfg.SASL.Password
	return c.send(Message{Command: "AUTHENTICATE", Params: []string{b64encode([]byte(payload))}})
}

func (c *Client) saslFinish(ok bool, err error) {
	c.mu.Lock()
	c.sasl = saslDone
	c.mu.Unlock()
	text := "ok"
	if !ok {
		text = "fail"
	}
	c.emitf(Event{Kind: EvSASLResult, Text: text, Err: err})
	_ = c.send(Message{Command: "CAP", Params: []string{"END"}})
}

func (c *Client) handleJoin(m Message) {
	ch := m.Trailing
	if !m.HasTrailing && len(m.Params) > 0 {
		ch = m.Params[0]
	}
	from := m.NickFromPrefix()
	c.mu.Lock()
	own := from == c.nick
	if own {
		c.joined[ch] = true
	}
	c.mu.Unlock()
	c.appendEntry(Entry{Kind: EntryJoin, Channel: ch, From: from, Text: from + " joined", At: c.now()})
	if own {
		c.emitf(Event{Kind: EvJoined, Channel: ch})
	}
}

func (c *Client) handlePart(m Message) {
	if len(m.Params) == 0 {
		return
	}
	ch := m.Params[0]
	from := m.NickFromPrefix()
	c.mu.Lock()
	own := from == c.nick
	if own {
		delete(c.joined, ch)
	}
	c.mu.Unlock()
	c.appendEntry(Entry{Kind: EntryPart, Channel: ch, From: from, Text: from + " left " + trailingOr(m, ""), At: c.now()})
}

func (c *Client) handleKick(m Message) {
	// :op KICK <chan> <nick> :reason
	if len(m.Params) < 2 {
		return
	}
	ch, target := m.Params[0], m.Params[1]
	c.mu.Lock()
	own := target == c.nick
	if own {
		delete(c.joined, ch)
		delete(c.want, ch) // a kick ends the intent too — no rejoin war
	}
	c.mu.Unlock()
	c.appendEntry(Entry{Kind: EntryKick, Channel: ch, From: m.NickFromPrefix(), Text: target + " kicked " + trailingOr(m, ""), At: c.now()})
}

func (c *Client) handleNick(m Message) {
	from := m.NickFromPrefix()
	next := m.Trailing
	if !m.HasTrailing && len(m.Params) > 0 {
		next = m.Params[0]
	}
	c.mu.Lock()
	if from == c.nick {
		c.nick = next
	}
	channels := sortedKeys(c.joined)
	c.mu.Unlock()
	// Presence without a roster: the rename is recorded on every channel
	// we share (the joined set); the roster lands with the UI card.
	for _, ch := range channels {
		c.appendEntry(Entry{Kind: EntryNick, Channel: ch, From: from, Text: from + " is now " + next, At: c.now()})
	}
}

func (c *Client) handleMsg(m Message) {
	if len(m.Params) == 0 {
		return
	}
	target := m.Params[0]
	kind := EntryMsg
	if m.Command == "NOTICE" {
		kind = EntryNotice
	}
	ch := ""
	if isChannel(target) {
		ch = target
	}
	c.appendEntry(Entry{Kind: kind, Channel: ch, From: m.NickFromPrefix(), Text: m.Trailing, At: c.now()})
}

func (c *Client) handlePresence(m Message) {
	ch := ""
	if len(m.Params) > 0 && isChannel(m.Params[0]) {
		ch = m.Params[0]
	}
	text := m.Command + " " + strings.Join(m.Params, " ")
	if m.HasTrailing {
		text += " :" + m.Trailing
	}
	c.appendEntry(Entry{Kind: EntryStatus, Channel: ch, From: m.NickFromPrefix(), Text: text, At: c.now()})
}

// status appends a server numeric/status line to the status buffer.
func (c *Client) status(m Message, text string) {
	c.appendEntry(Entry{Kind: EntryStatus, From: m.Prefix, Text: m.Command + " " + text, At: c.now()})
}

// --- outbound verbs (UI/console entry points) ---------------------------

// send serialises and writes one message. Safe from any goroutine —
// wmu keeps a PONG from interleaving with a UI-driven PRIVMSG.
func (c *Client) send(m Message) error {
	b, err := m.Encode()
	if err != nil {
		return err
	}
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return ircError("goirc: not connected")
	}
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err = conn.Write(b)
	return err
}

// Join asks to enter ch and records the intent (rejoins after a drop).
func (c *Client) Join(ch string) error {
	c.mu.Lock()
	c.want[ch] = true
	online := c.reg && c.conn != nil
	c.mu.Unlock()
	if !online {
		return nil // rides the next onWelcome
	}
	return c.send(Message{Command: "JOIN", Params: []string{ch}})
}

// Part leaves ch and drops the rejoin intent.
func (c *Client) Part(ch, reason string) error {
	c.mu.Lock()
	delete(c.want, ch)
	online := c.reg && c.conn != nil
	c.mu.Unlock()
	if !online {
		return nil
	}
	return c.send(Message{Command: "PART", Params: []string{ch}, Trailing: reason, HasTrailing: reason != ""})
}

// Privmsg sends text to a channel or nick. The local echo lands in the
// target channel's backlog — the server does not echo our own PRIVMSG.
func (c *Client) Privmsg(target, text string) error {
	if err := c.send(Message{Command: "PRIVMSG", Params: []string{target}, Trailing: text, HasTrailing: true}); err != nil {
		return err
	}
	ch := ""
	if isChannel(target) {
		ch = target
	}
	c.appendEntry(Entry{Kind: EntryMsg, Channel: ch, From: c.Nick(), Text: text, At: c.now()})
	return nil
}

// Notice sends a NOTICE.
func (c *Client) Notice(target, text string) error {
	return c.send(Message{Command: "NOTICE", Params: []string{target}, Trailing: text, HasTrailing: true})
}

// SetNick asks for a new nick.
func (c *Client) SetNick(nick string) error {
	return c.send(Message{Command: "NICK", Params: []string{nick}})
}

// Quit sends QUIT and ends the session cleanly — the drop that follows
// is not reconnected.
func (c *Client) Quit(reason string) error {
	c.mu.Lock()
	c.done = true
	conn := c.conn
	c.mu.Unlock()
	if conn != nil {
		_ = c.send(Message{Command: "QUIT", Trailing: reason, HasTrailing: reason != ""})
		_ = conn.Close()
	}
	c.emitf(Event{Kind: EvQuit})
	return nil
}

// Close ends the session without sending QUIT (the UI's own close path).
func (c *Client) Close() error {
	c.mu.Lock()
	c.done = true
	conn := c.conn
	c.mu.Unlock()
	return connOrNilClose(conn)
}

// --- small helpers ------------------------------------------------------

func isChannel(s string) bool {
	if len(s) == 0 {
		return false
	}
	switch s[0] {
	case '#', '&', '+', '!':
		return true
	}
	return false
}

func isTimeoutErr(err error) bool {
	if err == nil {
		return false
	}
	if tls.IsTimeout(err) {
		return true
	}
	return err.Error() == "ETIMEDOUT" // vi keeps its errno type private
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func rawTrailing(m Message) string {
	if m.HasTrailing {
		return m.Trailing
	}
	return strings.Join(m.Params, " ")
}

func trailingOr(m Message, def string) string {
	if m.HasTrailing {
		return m.Trailing
	}
	return def
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k, v := range m {
		if v {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// b64encode is the standard-alphabet base64 SASL PLAIN needs — ~20 lines
// against pulling encoding/base64 into the guest build surface.
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
