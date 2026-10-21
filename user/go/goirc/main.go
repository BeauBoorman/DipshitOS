// Command goirc is the M147a (issue #2801) IRC client: the RFC 1459/2812
// protocol core in this package plus a console driver the shell's exec
// verb and the go-irc gate can drive without a UI. M147b layers the
// channel list / scrollback / input line over the same Client.
//
// CLI (flags or the two-position shorthand):
//
//	exec GOIRC.ELF --host 10.0.0.2 [--port 6667] --nick N [--user U]
//	               [--realname R] [--join '#a,#b'] [--tls [--sni NAME]]
//	               [--sasl acct:pass] [--plain] [--retries N]
//	               [--backoff-ms N] [--idle-ms N] [--pong-ms N]
//	               [--max-ms N]
//	exec GOIRC.ELF <host> <nick> [#chan ...]
//
// TLS dials 6697-style through tls.Dial; plaintext refuses unless
// --plain sets the session's consent bit (the refusal is the named
// 'goirc: refuse plaintext' marker).
//
// Serial markers (one per line, grep-able):
//
//	goirc: dial <host> <port> tls|plain
//	goirc: registered nick=<n>          goirc: join|rejoin <chan>
//	goirc: names <chan> <count>        goirc: msg <chan|*> <from> <text>
//	goirc: notice <chan|*> <from> <t>  goirc: status <text>
//	goirc: drop <err>                  goirc: backoff <ms>
//	goirc: nick-in-use <nick>          goirc: join-fail <chan> <reason>
//	goirc: sasl ok|fail                goirc: error <err>
//	goirc: quit                        goirc: closed
//
// The --ui front-end adds (same prefix, same grep discipline):
//
//	goirc: open id=<n>                 goirc: declare accepted|refused
//	goirc: consent ask|yes|no          goirc: toast|toast-refused <chan>
//	goirc: focus <buf>                 goirc: blur
//	goirc: state restored|refused|saved
//
// M152e (#2919) adds:
//
//	goirc: hl add|del|full             goirc: log on|off <chan>
//	goirc: log write <path>            goirc: log write-fail <chan> <err>
//
// Exit: 0 clean quit/--max-ms, 1 usage, 2 session error (fatal refusals
// and exhausted retries alike — the marker line names which).
package main

import (
	"strings"

	"virelai/vi"
	"virelai/vsys"
)

const (
	appName = "GOIRC.ELF"

	exitOK    = 0
	exitUsage = 1
	exitError = 2
)

var argvPad [2048]byte // see fetch/main.go — sbrk/argv tail slack

type options struct {
	cfg      Config
	maxMs    int64
	haveHost bool
	haveNick bool
	ui       bool // M147b: --ui runs the tabapp front-end
}

func usage() {
	vi.ConsoleLine("usage: GOIRC.ELF --host H --nick N [--port P] [--join '#a,#b']")
	vi.ConsoleLine("                  [--tls [--sni NAME]] [--sasl acct:pass] [--plain] [--ui]")
	vi.ConsoleLine("                  [--retries N] [--backoff-ms N] [--idle-ms N] [--pong-ms N] [--max-ms N]")
	vi.ConsoleLine("       GOIRC.ELF <host> <nick> [#chan ...]")
}

// cliArgs drops argv[0] when it is the image name (the kernel's ELF gap
// path prepends it); every real argument here is a flag or a positional
// that never spells like the binary.
func cliArgs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	switch raw[0] {
	case "GOIRC", "GOIRC.ELF", "goirc":
		return raw[1:]
	}
	if len(raw[0]) > 0 && raw[0][0] != '-' {
		return raw // a positional host — argv[0] was already consumed
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

func parseArgs(args []string) (options, bool) {
	var o options
	o.cfg.Port = 6667
	o.cfg.Reconnect = true
	pos := []string{}
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
		case "--host":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.Host, o.haveHost = v, true
		case "--port":
			n, ok := num()
			if !ok || n <= 0 || n > 65535 {
				return o, false
			}
			o.cfg.Port = uint16(n)
		case "--nick":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.Nick, o.haveNick = v, true
		case "--user":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.User = v
		case "--realname":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.Realname = v
		case "--join":
			v, ok := next()
			if !ok {
				return o, false
			}
			for _, ch := range strings.Split(v, ",") {
				if isChannel(ch) {
					o.cfg.Channels = append(o.cfg.Channels, ch)
				}
			}
		case "--tls":
			o.cfg.TLS = true
		case "--sni":
			v, ok := next()
			if !ok {
				return o, false
			}
			o.cfg.ServerName = v
		case "--sasl":
			v, ok := next()
			if !ok {
				return o, false
			}
			acct, pass, _ := strings.Cut(v, ":")
			o.cfg.SASL = &SASLConfig{Account: acct, Password: pass}
		case "--plain":
			o.cfg.AllowPlain = true
		case "--ui":
			o.ui = true
		case "--retries":
			n, ok := num()
			if !ok {
				return o, false
			}
			o.cfg.MaxRetries = int(n)
		case "--no-reconnect":
			o.cfg.Reconnect = false
		case "--backoff-ms":
			n, ok := num()
			if !ok || n <= 0 {
				return o, false
			}
			o.cfg.BackoffBase = n * 1e6
		case "--backoff-max-ms":
			n, ok := num()
			if !ok || n <= 0 {
				return o, false
			}
			o.cfg.BackoffMax = n * 1e6
		case "--idle-ms":
			n, ok := num()
			if !ok || n <= 0 {
				return o, false
			}
			o.cfg.IdlePing = n * 1e6
		case "--pong-ms":
			n, ok := num()
			if !ok || n <= 0 {
				return o, false
			}
			o.cfg.PongWait = n * 1e6
		case "--max-ms":
			n, ok := num()
			if !ok || n <= 0 {
				return o, false
			}
			o.maxMs = n
		default:
			if len(a) > 0 && a[0] == '-' {
				return o, false
			}
			pos = append(pos, a)
		}
	}
	// Positional shorthand: <host> <nick> [#chan ...]
	if !o.haveHost && len(pos) >= 1 {
		o.cfg.Host, o.haveHost = pos[0], true
		pos = pos[1:]
	}
	if !o.haveNick && len(pos) >= 1 {
		o.cfg.Nick, o.haveNick = pos[0], true
		pos = pos[1:]
	}
	for _, ch := range pos {
		if isChannel(ch) {
			o.cfg.Channels = append(o.cfg.Channels, ch)
		}
	}
	return o, o.haveHost && o.haveNick && o.cfg.Nick != "" && o.cfg.Host != ""
}

// consoleSink renders each Event as its one-line marker — the console
// driver's sink. The UI drains its event queue through the same logEvent
// so both modes emit an identical marker stream.
func consoleSink(cfg Config) func(Event) {
	return func(e Event) { logEvent(cfg, e) }
}

// logEvent prints e's marker line. Channel "" (the server/status buffer)
// prints as '*'.
func logEvent(cfg Config, e Event) {
	switch e.Kind {
	case EvState:
		switch e.State {
		case StateDialing:
			scheme := "plain"
			if cfg.TLS {
				scheme = "tls"
			}
			vi.ConsoleLine("goirc: dial " + cfg.Host + " " + vsys.Itoa64(int64(cfg.Port)) + " " + scheme)
		case StateClosed:
			vi.ConsoleLine("goirc: closed")
		}
	case EvEntry:
		printEntry(e.Entry)
	case EvRegistered:
		vi.ConsoleLine("goirc: registered nick=" + e.Nick)
	case EvJoined:
		vi.ConsoleLine("goirc: join " + e.Channel)
	case EvRejoined:
		vi.ConsoleLine("goirc: rejoin " + e.Channel)
	case EvJoinFail:
		vi.ConsoleLine("goirc: join-fail " + e.Channel + " " + e.Reason)
	case EvNames:
		vi.ConsoleLine("goirc: names " + e.Channel + " " + vsys.Itoa64(int64(len(e.Names))))
	case EvNickInUse:
		vi.ConsoleLine("goirc: nick-in-use " + e.Nick)
	case EvSASLResult:
		vi.ConsoleLine("goirc: sasl " + e.Text)
	case EvDrop:
		vi.ConsoleLine("goirc: drop " + errText(e.Err))
	case EvBackoff:
		vi.ConsoleLine("goirc: backoff " + vsys.Itoa64(e.BackoffNs/1e6))
	case EvQuit:
		vi.ConsoleLine("goirc: quit")
	case EvError:
		vi.ConsoleLine("goirc: error " + firstNonEmpty(errText(e.Err), e.Text))
	}
}

func printEntry(en Entry) {
	ch := en.Channel
	if ch == "" {
		ch = "*"
	}
	switch en.Kind {
	case EntryMsg:
		vi.ConsoleLine("goirc: msg " + ch + " " + en.From + " " + en.Text)
	case EntryNotice:
		vi.ConsoleLine("goirc: notice " + ch + " " + en.From + " " + en.Text)
	case EntryJoin, EntryPart, EntryKick, EntryNick:
		vi.ConsoleLine("goirc: chan " + ch + " " + en.Text)
	case EntryError:
		vi.ConsoleLine("goirc: error " + en.Text)
	default:
		vi.ConsoleLine("goirc: status " + en.Text)
	}
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func main() {
	argvPad[0] = 1
	args := cliArgs(vi.Args())
	o, ok := parseArgs(args)
	if !ok {
		// A bare exec is the seat's reopen/crash re-exec shape (the LIFO
		// carries only the recorded bin — no argv can ride it). The
		// session's host/nick/channels live in the save_state blob, so a
		// zero-arg launch falls into the UI: a staged blob resumes it,
		// and runUI itself prints usage + exits when none arrives.
		if len(args) == 0 {
			runUI(o)
			vi.Exit(exitError) // runUI exits via CloseAndExit; unreachable
		}
		usage()
		vi.Exit(exitUsage)
	}

	// M147b: --ui runs the tabapp front-end (channel rail, scrollback,
	// input line, mention toasts, the plaintext consent dialog and
	// save_state); the console driver stays the default so the existing
	// gate legs and the shell's exec verb are unchanged.
	if o.ui {
		runUI(o)
		vi.Exit(exitError) // runUI exits via CloseAndExit; unreachable
	}

	c := NewClient(o.cfg, dialGuest(o.cfg), consoleSink(o.cfg))

	// --max-ms bounds the whole run from a second goroutine; the gate's
	// --script-expect normally ends the boot long before it bites.
	done := make(chan struct{})
	var runErr error
	go func() { runErr = c.Run(); close(done) }()

	if o.maxMs > 0 {
		deadline := vi.Nanos() + o.maxMs*1e6
		for vi.Nanos() < deadline {
			select {
			case <-done:
				finish(runErr)
			default:
			}
			vi.Sleep(1)
		}
		_ = c.Close()
	}
	<-done
	finish(runErr)
}

func finish(err error) {
	if err != nil {
		vi.Exit(exitError)
	}
	vi.Exit(exitOK)
}
