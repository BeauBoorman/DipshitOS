// Command gomail is the M187c (issue #3184) mail client: the smallest
// honest mail tool — IMAP4rev1 SELECT/FETCH for mailboxes, headers and
// one readable body, SMTP submit for one plaintext message — over the
// GOIRC-proven shape: tls.Dial transport, the plaintext consent rule at
// the dial boundary, a settings-file account, and named refusals for
// everything else.
//
// CLI:
//
//	exec GOMAIL.ELF [--account P] [--host H] [--user U] [--pass P]
//	                [--from A] [--sni NAME] [--imap-port N] [--smtp-port N]
//	                [--tls] [--plain] [--max N] <verb> [args]
//	verbs:
//	  fetch <mbox> [seq ...]   boxes + headers + read each seq (default 1)
//	  fetch [seq ...]          same, on the `use`d box (INBOX until then)
//	  boxes                    LIST "" "*"
//	  use <box>                LIST + SELECT + remember the box
//	  headers [mbox]           SELECT + bounded ENVELOPE list
//	  read [mbox] <seq>        BODYSTRUCTURE + readable part / attachments
//	  search <q>               substring over the local cache (no dial)
//	  send                     --to A [...] --subject S --body T|--body-file P
//	  open <name>              named refusal: attachments do not open
//	  <out-of-scope verb>      named refusal (idle notify copy move
//	                          delete append store subscribe oauth render)
//
// M193a (#3253): the wire work also writes a bounded cache under the
// data root's MAIL/ subtree — folder names, envelope rows, the last-N
// bodies per mailbox (cache.go names the bounds; LRU evicts). `search`
// reads that corpus and never dials; when a verb's own dial fails the
// verb answers from the cache instead, printing 'gomail: offline' ahead
// of the rows memory can prove and 'gomail: cache-miss' for what it
// cannot — never fabricated mail.
//
// The account lives in a key=value file (default /host/GOMAIL.TXT, the
// account.go codec); argv overrides it. Transport: --tls selects
// tls.Dial (ports 993/465 by convention); without it the request is
// plaintext, which refuses by name ('gomail: refuse plaintext') unless
// --plain or the file's plain=on carries the consent bit — the console
// form of the journey GOIRC proved.
//
// Serial markers (one per line, grep-able):
//
//	gomail: account <path>           gomail: dial <host> <port> tls|plain
//	gomail: imap ready               gomail: login <user>
//	gomail: box <name>               gomail: select <mbox> exists=<n>
//	gomail: use <box> exists=<n>     gomail: use <box> cached
//	gomail: hdr <seq> <from>: <subj> gomail: body <seq> <type> bytes=<n>
//	gomail: html-stripped <seq>      gomail: text <line>
//	gomail: attach <seq> <name> <type>  gomail: refuse attachment <name>
//	gomail: cache <path>             gomail: cache-fail <path> <err>
//	gomail: offline <verb> …         gomail: cache-miss <ref>
//	gomail: hit <box> <seq> <from>: <subj> [(body)]
//	gomail: search hits=<n>          gomail: refuse use <box>
//	gomail: smtp ready               gomail: mail <from>
//	gomail: rcpt <to>                gomail: sent bytes=<n>
//	gomail: refuse plaintext|…       gomail: error <err>
//	gomail: closed
//
// Exit: 0 clean, 1 usage, 2 refused/error (the marker line names which).
package main

import (
	"strings"

	"virelai/vi"
	"virelai/vsys"
)

const (
	appName = "GOMAIL.ELF"

	exitOK    = 0
	exitUsage = 1
	exitError = 2

	bodyLineMax = 40 // printed body lines per message
	bodyByteMax = 64 * 1024
)

var argvPad [2048]byte // see fetch/main.go — sbrk/argv tail slack

// options is the argv half: each field plus whether argv set it, so the
// file can load first and argv overrides only what it names.
type options struct {
	cfg      Config
	set      map[string]bool
	account  string
	verb     string
	args     []string
	to       []string
	subject  string
	body     string
	bodyFile string
}

func usage() {
	vi.ConsoleLine("usage: GOMAIL.ELF [--account P] [--host H] [--user U] [--pass P]")
	vi.ConsoleLine("                  [--from A] [--sni NAME] [--tls] [--plain] [--max N]")
	vi.ConsoleLine("                  fetch <mbox> [seq ...] | boxes | use <box> |")
	vi.ConsoleLine("                  headers [mbox] | read [mbox] <seq> | search <q> |")
	vi.ConsoleLine("                  send --to A --subject S --body T")
}

// cliArgs drops argv[0] when it is the image name (the kernel's ELF gap
// path prepends it).
func cliArgs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	switch raw[0] {
	case "GOMAIL", "GOMAIL.ELF", "gomail":
		return raw[1:]
	}
	return raw
}

func parseUint(s string) (int64, bool) {
	var n int64
	if len(s) == 0 {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
		if n > 1<<40 {
			return 0, false
		}
	}
	return n, true
}

// refusedVerbs names the out-of-scope surface — every one is a named
// refusal, never silence.
var refusedVerbs = map[string]bool{
	"idle": true, "notify": true, "copy": true,
	"move": true, "delete": true, "append": true, "store": true,
	"subscribe": true, "oauth": true, "render": true, "html": true,
}

func parseArgs(args []string) (options, bool) {
	var o options
	o.set = map[string]bool{}
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		var eqVal string
		haveEq := false
		if strings.HasPrefix(a, "--") {
			if k := strings.IndexByte(a, '='); k >= 0 {
				a, eqVal, haveEq = a[:k], a[k+1:], true
			}
		}
		next := func() (string, bool) {
			if haveEq {
				haveEq = false
				return eqVal, true
			}
			if i+1 >= len(args) {
				return "", false
			}
			i++
			return args[i], true
		}
		num := func() (int64, bool) {
			s, ok := next()
			if !ok {
				return 0, false
			}
			return parseUint(s)
		}
		switch a {
		case "-h", "--help":
			return o, false
		case "--account":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.account = v
		case "--host":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.Host, o.set["host"] = v, true
		case "--user":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.User, o.set["user"] = v, true
		case "--pass":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.Pass, o.set["pass"] = v, true
		case "--from":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.From, o.set["from"] = v, true
		case "--sni":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.ServerName, o.set["sni"] = v, true
		case "--imap-port":
			n, ok := num()
			if !ok || n <= 0 || n > 65535 {
				return o, false
			}
			o.cfg.IMAPPort, o.set["imap_port"] = uint16(n), true
		case "--smtp-port":
			n, ok := num()
			if !ok || n <= 0 || n > 65535 {
				return o, false
			}
			o.cfg.SMTPPort, o.set["smtp_port"] = uint16(n), true
		case "--tls":
			o.cfg.TLS, o.set["tls"] = true, true
		case "--plain":
			o.cfg.AllowPlain, o.set["plain"] = true, true
		case "--max":
			n, ok := num()
			if !ok || n <= 0 || n > headerMaxBound {
				return o, false
			}
			o.cfg.MaxHeaders, o.set["max_headers"] = int(n), true
		case "--to":
			v, ok := next()
			if !ok || v == "" {
				return o, false
			}
			o.to = append(o.to, v)
		case "--subject":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.subject = v
		case "--body":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.body = v
		case "--body-file":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.bodyFile = v
		default:
			if len(a) > 0 && a[0] == '-' {
				return o, false
			}
			pos = append(pos, a)
		}
	}
	if len(pos) == 0 {
		return o, false
	}
	o.verb, o.args = pos[0], pos[1:]
	return o, true
}

func say(s string) { vi.ConsoleLine(s) }

// fail reports an error line — protoErr/mailError texts already carry
// the 'gomail:' marker — and the closing marker.
func fail(err error) {
	s := err.Error()
	if !strings.HasPrefix(s, "gomail:") {
		s = "gomail: error " + s
	}
	say(s)
	say("gomail: closed")
	vi.Exit(exitError)
}

func main() {
	argvPad[0] = 1
	args := cliArgs(vi.Args())
	o, ok := parseArgs(args)
	if !ok {
		usage()
		vi.Exit(exitUsage)
	}

	// Out-of-scope verbs refuse by name before any file or socket work.
	if refusedVerbs[o.verb] {
		say("gomail: refuse " + o.verb)
		say("gomail: closed")
		vi.Exit(exitError)
	}

	// File first, argv over it.
	cfg := Config{Host: ""}
	path := o.account
	if path == "" {
		path = DefaultAccountPath
	}
	loaded, ok := cfg.loadAccount(path)
	if !ok {
		say("gomail: account bad " + path)
		say("gomail: closed")
		vi.Exit(exitError)
	}
	if loaded {
		say("gomail: account " + path)
	}
	if o.set["host"] {
		cfg.Host = o.cfg.Host
	}
	if o.set["user"] {
		cfg.User = o.cfg.User
	}
	if o.set["pass"] {
		cfg.Pass = o.cfg.Pass
	}
	if o.set["from"] {
		cfg.From = o.cfg.From
	}
	if o.set["sni"] {
		cfg.ServerName = o.cfg.ServerName
	}
	if o.set["imap_port"] {
		cfg.IMAPPort = o.cfg.IMAPPort
	}
	if o.set["smtp_port"] {
		cfg.SMTPPort = o.cfg.SMTPPort
	}
	if o.set["tls"] {
		cfg.TLS = o.cfg.TLS
	}
	if o.set["plain"] {
		cfg.AllowPlain = o.cfg.AllowPlain
	}
	if o.set["max_headers"] {
		cfg.MaxHeaders = o.cfg.MaxHeaders
	}
	if cfg.MaxHeaders <= 0 {
		cfg.MaxHeaders = headerMaxDefault
	}
	// 'search' never dials, so it never needs the account's host.
	if cfg.Host == "" && o.verb != "search" {
		say("gomail: account missing host")
		say("gomail: closed")
		vi.Exit(exitError)
	}

	var err error
	switch o.verb {
	case "fetch":
		// fetch <mbox> [seq ...] — or fetch [seq ...] on the `use`d
		// box: a leading non-numeric arg is the mailbox, a numeric or
		// absent one means seqs on the remembered box.
		mboxArg := ""
		rest := o.args
		if len(rest) > 0 {
			if _, ok := parseUint(rest[0]); !ok {
				mboxArg = rest[0]
				rest = rest[1:]
			}
		}
		seqs := []int{1}
		if len(rest) > 0 {
			seqs = seqs[:0]
			for _, a := range rest {
				n, ok := parseUint(a)
				if !ok || n <= 0 {
					usage()
					vi.Exit(exitUsage)
				}
				seqs = append(seqs, int(n))
			}
		}
		err = runFetch(cfg, resolveBox(mboxArg), seqs, true)
	case "boxes":
		err = runFetch(cfg, "", nil, false)
	case "use":
		if len(o.args) != 1 {
			usage()
			vi.Exit(exitUsage)
		}
		err = runUse(cfg, o.args[0])
	case "headers":
		mboxArg := ""
		if len(o.args) > 0 {
			mboxArg = o.args[0]
		}
		err = runHeaders(cfg, resolveBox(mboxArg))
	case "read":
		// read <mbox> <seq> — or read <seq> on the `use`d box.
		var mboxArg, seqArg string
		switch len(o.args) {
		case 1:
			seqArg = o.args[0]
		case 2:
			mboxArg, seqArg = o.args[0], o.args[1]
		default:
			usage()
			vi.Exit(exitUsage)
		}
		n, ok := parseUint(seqArg)
		if !ok || n <= 0 {
			usage()
			vi.Exit(exitUsage)
		}
		err = runRead(cfg, resolveBox(mboxArg), int(n))
	case "search":
		if len(o.args) < 1 {
			usage()
			vi.Exit(exitUsage)
		}
		err = runSearch(strings.Join(o.args, " "))
	case "open":
		if len(o.args) < 1 {
			usage()
			vi.Exit(exitUsage)
		}
		say("gomail: refuse attachment " + o.args[0])
		say("gomail: closed")
		vi.Exit(exitError)
	case "send":
		err = runSend(cfg, o)
	default:
		say("gomail: refuse " + o.verb)
		say("gomail: closed")
		vi.Exit(exitError)
	}
	if err != nil {
		fail(err)
	}
	say("gomail: closed")
	vi.Exit(exitOK)
}

// dialIMAP connects + greets + logs in, emitting the dial markers.
// The 'gomail: dial' marker reports a REAL socket — it prints only
// after the dial lands, so the consent refusal never claims a dial.
func dialIMAP(cfg Config) (*imapClient, error) {
	scheme := "plain"
	if cfg.TLS {
		scheme = "tls"
	}
	conn, err := dialOne(cfg, cfg.imapPort())
	if err != nil {
		if _, named := err.(mailError); named {
			return nil, err // consent refusal — never a cache leg
		}
		return nil, dialError{err} // transport dead — the cache may answer
	}
	say("gomail: dial " + cfg.Host + " " + vsys.Itoa64(int64(cfg.imapPort())) + " " + scheme)
	c := newIMAP(conn)
	if err := c.greeting(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	say("gomail: imap ready")
	if err := c.login(cfg.User, cfg.Pass); err != nil {
		c.logout()
		return nil, err
	}
	say("gomail: login " + cfg.User)
	return c, nil
}

// listBoxes emits the mailbox rows and returns the names — the caller
// publishes them to the folder cache.
func listBoxes(c *imapClient) ([]string, error) {
	boxes, err := c.list()
	if err != nil {
		return nil, err
	}
	for _, b := range boxes {
		say("gomail: box " + b)
	}
	return boxes, nil
}

// fetchHeaders emits the select marker and returns the bounded envelope
// window plus EXISTS; the caller prints and caches the rows.
func fetchHeaders(c *imapClient, mbox string, max int) ([]Header, int, error) {
	exists, err := c.selectBox(mbox)
	if err != nil {
		return nil, 0, err
	}
	say("gomail: select " + mbox + " exists=" + vsys.Itoa64(int64(exists)))
	hi := exists
	if hi > max {
		hi = max
	}
	if hi <= 0 {
		return nil, exists, nil
	}
	hdrs, err := c.envelopes(1, hi)
	return hdrs, exists, err
}

// printHdrs emits the envelope rows.
func printHdrs(hdrs []Header) {
	for _, h := range hdrs {
		say("gomail: hdr " + vsys.Itoa64(int64(h.Seq)) + " " + h.From + ": " + h.Subject)
	}
}

// readOne renders one message: BODYSTRUCTURE, the readable part (or the
// named refusal), and the attachment list + refuse-to-open rows. On a
// rendered body it returns the mime + bytes so the caller can remember
// them; a refusal or error returns "", nil, err.
func readOne(c *imapClient, seq int) (string, []byte, error) {
	root, err := c.structure(seq)
	if err != nil {
		return "", nil, err
	}
	body := pickBody(root)
	if body == nil {
		for _, a := range attachments(root) {
			say("gomail: attach " + vsys.Itoa64(int64(seq)) + " " + a.attachName() + " " + a.mimeType())
			say("gomail: refuse attachment " + a.attachName())
		}
		return "", nil, protoErr("refuse ", itoa(int64(seq))+" no readable text")
	}
	if body.encoding == "base64" || body.encoding == "quoted-printable" {
		return "", nil, protoErr("refuse ", itoa(int64(seq))+" encoded body "+body.encoding)
	}
	data, err := c.section(seq, body.section())
	if err != nil {
		return "", nil, err
	}
	if len(data) > bodyByteMax {
		data = data[:bodyByteMax]
	}
	printBodyRows(seq, body.mimeType(), body.sub == "html", data)
	for _, a := range attachments(root) {
		say("gomail: attach " + vsys.Itoa64(int64(seq)) + " " + a.attachName() + " " + a.mimeType())
		say("gomail: refuse attachment " + a.attachName())
	}
	return body.mimeType(), data, nil
}

// runFetch is the composite leg: LIST + SELECT + headers + the reads,
// writing the corpus through to the cache as the wire proves it.
// full=false runs only the LIST half (the 'boxes' verb). A dead
// transport answers from the cache instead — the offline leg.
func runFetch(cfg Config, mbox string, seqs []int, full bool) error {
	c, err := dialIMAP(cfg)
	if err != nil {
		return offlineOr(err, func() error {
			if !full {
				return offlineBoxes()
			}
			return offlineFetch(mbox, seqs)
		})
	}
	defer c.logout()
	boxes, err := listBoxes(c)
	if err != nil {
		return err
	}
	cacheSaveBoxes(boxes)
	if !full {
		return nil
	}
	hdrs, exists, err := fetchHeaders(c, mbox, cfg.MaxHeaders)
	if err != nil {
		return err
	}
	printHdrs(hdrs)
	cacheSaveUse(mbox)
	cacheSaveHdrs(mbox, hdrs)
	for _, seq := range seqs {
		if seq > exists {
			return protoErr("refuse ", itoa(int64(seq))+" past exists")
		}
		mime, data, err := readOne(c, seq)
		if err != nil {
			return err
		}
		cachePutBody(mbox, seq, mime, data)
	}
	return nil
}

func runHeaders(cfg Config, mbox string) error {
	c, err := dialIMAP(cfg)
	if err != nil {
		return offlineOr(err, func() error { return offlineHeaders(mbox) })
	}
	defer c.logout()
	hdrs, _, err := fetchHeaders(c, mbox, cfg.MaxHeaders)
	if err != nil {
		return err
	}
	printHdrs(hdrs)
	cacheSaveUse(mbox)
	cacheSaveHdrs(mbox, hdrs)
	return nil
}

func runRead(cfg Config, mbox string, seq int) error {
	c, err := dialIMAP(cfg)
	if err != nil {
		return offlineOr(err, func() error { return offlineRead(mbox, seq) })
	}
	defer c.logout()
	exists, err := c.selectBox(mbox)
	if err != nil {
		return err
	}
	say("gomail: select " + mbox + " exists=" + vsys.Itoa64(int64(exists)))
	if seq > exists {
		return protoErr("refuse ", itoa(int64(seq))+" past exists")
	}
	mime, data, err := readOne(c, seq)
	if err != nil {
		return err
	}
	cacheSaveUse(mbox)
	cachePutBody(mbox, seq, mime, data)
	return nil
}

// runSearch answers 'search <q>' over the cache only — it never dials:
// what memory holds answers, what it does not simply does not hit.
func runSearch(q string) error {
	say("gomail: search " + q)
	hits := cacheSearch(q)
	for i, h := range hits {
		if i >= cacheHitMax {
			say("gomail: search …")
			break
		}
		line := "gomail: hit " + h.box + " " + itoa(int64(h.seq))
		if h.haveHdr {
			line += " " + h.from + ": " + h.subject
		}
		if h.bodyOnly {
			line += " (body)"
		}
		say(line)
	}
	say("gomail: search hits=" + itoa(int64(len(hits))))
	return nil
}

// runSend submits one plaintext message over SMTP.
func runSend(cfg Config, o options) error {
	if len(o.to) == 0 {
		return protoErr("send needs --to", "")
	}
	body := o.body
	if o.bodyFile != "" {
		b, rc := vi.ReadFileAll(o.bodyFile, bodyByteMax)
		if rc < 0 {
			return protoErr("body-file unreadable: ", o.bodyFile)
		}
		body = string(b)
	}
	from := cfg.fromAddr()
	if from == "" {
		return protoErr("send needs from (file or --from)", "")
	}
	scheme := "plain"
	if cfg.TLS {
		scheme = "tls"
	}
	conn, err := dialOne(cfg, cfg.smtpPort())
	if err != nil {
		return err
	}
	say("gomail: dial " + cfg.Host + " " + vsys.Itoa64(int64(cfg.smtpPort())) + " " + scheme)
	s := newSMTP(conn)
	if err := s.hello(cfg.User, cfg.Pass); err != nil {
		_ = conn.Close()
		return err
	}
	say("gomail: smtp ready")
	msg := buildMessage(from, o.to, o.subject, body)
	say("gomail: mail " + from)
	for _, t := range o.to {
		say("gomail: rcpt " + t)
	}
	if err := s.submit(from, o.to, msg); err != nil {
		return err
	}
	say("gomail: sent bytes=" + vsys.Itoa64(int64(len(msg))))
	return nil
}
