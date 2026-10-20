package main

// ui.go — M147b (issue #2802): the tabapp front-end. One window split into
// a channel rail, the focused buffer's scrollback, and a single-line input;
// the console driver's markers still print (the emit queue funnels through
// the same logEvent), so the go-irc gate reads UI runs exactly like console
// ones.
//
// The M147b additions the card names:
//
//   - mention → toast: an EntryMsg carrying the user's nick posts
//     vi.Notify; the seat's click-through refocuses THIS window, and the
//     next EvWinFocus applies the pending-mention channel (so the click
//     lands the user on the buffer that called).
//   - plaintext consent: the FIRST plaintext connection opens an
//     appkit.Confirm dialog before any dial; the answer lands in the
//     save_state blob (flags bit) so a restored tab never re-asks.
//   - save_state: server/port/TLS/nick, the buffer list + per-buffer
//     scroll offset, the focused buffer, and the consent bit ride the
//     M125a envelope (state.go). The seat owns the lifecycle; PollStateAsk
//     answers snapshot/close asks and SaveStateNow posts on mutation.

import (
	"strings"

	"virelai/appkit"
	uidraw "virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	uiNatW = 640
	uiNatH = 400

	// railW is the channel rail's fixed width; the scrollback takes the
	// remainder. inputH is the input field's strip at the canvas foot.
	railW  = 132
	inputH = 26
	headH  = 20 // the nick@host state strip

	// rowH is one scrollback line (8px face + breathing room); the rail
	// reuses it for buffer rows so pointer hit-testing is one arithmetic.
	rowH = 12

	// evChanCap bounds the core→UI queue; a flood drops with a counted
	// status line rather than parking the client's read goroutine.
	evChanCap = 1024

	keyPgUp = 0x4b
	keyPgDn = 0x4e
	keyUp   = 0x52
	keyDown = 0x51
)

// uiApp is the whole front-end. cli events arrive on evs (emit never
// touches the canvas); the event loop drains, applies and repaints.
type uiApp struct {
	ta        *tabapp.TabApp
	cfg       Config
	cli       *Client
	evs       chan Event
	evDropped uint64

	bufs        []string       // "" = the server/status buffer
	focus       int            // index into bufs
	scroll      map[string]int // lines scrolled up from the newest entry
	input       widgets.TextInput
	dlg         *appkit.Dialog // the plaintext-consent ask, while open
	pendMention string         // buffer the last toast named
	winFocus    bool
	started     bool
	quit        bool
	dirty       bool // a repaint is owed
	st          *ircState
	// localLog holds status lines written before the client exists (the
	// consent window): spliced into the server ring when Run starts.
	localLog *Backlog
}

// bufLabel is the rail's spelling of a buffer name; the server buffer is
// always slot 0 and prints '*'.
func bufLabel(name string) string {
	if name == "" {
		return "*"
	}
	return name
}

// focusedBuf names the focused buffer ("" = server).
func (u *uiApp) focusedBuf() string {
	if u.focus < 0 || u.focus >= len(u.bufs) {
		return ""
	}
	return u.bufs[u.focus]
}

// addBuf registers name in the rail (first-seen order) — a no-op repeat.
func (u *uiApp) addBuf(name string) {
	for _, b := range u.bufs {
		if b == name {
			return
		}
	}
	u.bufs = append(u.bufs, name)
}

// focusName selects the named buffer (registering it first when unseen)
// and reports the change — one marker shape for every selection, so the
// gate's click-through read is the same line a /join produces.
func (u *uiApp) focusName(name string) {
	u.addBuf(name)
	for i, b := range u.bufs {
		if b == name {
			u.focus = i
			break
		}
	}
	vi.ConsoleLine("goirc: focus " + bufLabel(name))
	u.dirty = true
}

// status appends a local status line to the server buffer — the client's
// ring once it exists, the pre-client log (spliced at startClient) before.
func (u *uiApp) status(text string) {
	e := Entry{Kind: EntryStatus, Text: text, At: vi.Nanos()}
	if u.cli != nil {
		u.cli.Backlog("").Add(e)
		return
	}
	u.localLog.Add(e)
}

// emit is the core's callback: queue the event, never draw here.
func (u *uiApp) emit(e Event) {
	select {
	case u.evs <- e:
	default:
		u.evDropped++
	}
}

// startClient launches the session once consent (or TLS) allows it.
func (u *uiApp) startClient() {
	if u.started {
		return
	}
	u.started = true
	u.cli = NewClient(u.cfg, dialGuest(u.cfg), u.emit)
	for _, e := range u.localLog.Entries() {
		u.cli.Backlog("").Add(e)
	}
	u.localLog = nil
	go func() { _ = u.cli.Run() }()
}

// --- mention → toast ------------------------------------------------------

// mentionMatch reports whether text names nick as a word — ASCII
// case-folded, bounded by non-nick characters (letters, digits and the
// RFC 1459 special set [-_\[\]{}\\|`^] count as nick bytes).
func mentionMatch(text, nick string) bool {
	if nick == "" {
		return false
	}
	n := len(nick)
	isNickByte := func(c byte) bool {
		return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
			c >= '0' && c <= '9' || c == '-' || c == '_' ||
			c == '[' || c == ']' || c == '{' || c == '}' ||
			c == '\\' || c == '|' || c == '`' || c == '^'
	}
	for i := 0; i+n <= len(text); i++ {
		if i > 0 && isNickByte(text[i-1]) {
			continue
		}
		if i+n < len(text) && isNickByte(text[i+n]) {
			continue
		}
		match := true
		for j := 0; j < n; j++ {
			a, b := text[i+j], nick[j]
			if a >= 'a' && a <= 'z' {
				a -= 'a' - 'A'
			}
			if b >= 'a' && b <= 'z' {
				b -= 'a' - 'A'
			}
			if a != b {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

// toastText packs the mention into the seat's 24-byte title budget:
// "<from> on <chan>" trimmed at the wire's limit.
func toastText(from, ch string) string {
	s := from + " on " + ch
	if len(s) > 24 {
		s = s[:24]
	}
	return s
}

// onEvent applies one drained core event: the marker line first (same
// text the console driver prints), then the model update.
func (u *uiApp) onEvent(e Event) {
	logEvent(u.cfg, e)
	switch e.Kind {
	case EvEntry:
		u.addBuf(e.Entry.Channel)
		en := e.Entry
		if en.Kind == EntryMsg && en.Channel != "" && u.cli != nil {
			nick := u.cli.Nick()
			if en.From != nick && mentionMatch(en.Text, nick) {
				u.pendMention = en.Channel
				if u.ta != nil && u.ta.Notify(toastText(en.From, en.Channel)) {
					vi.ConsoleLine("goirc: toast " + en.Channel)
				} else {
					vi.ConsoleLine("goirc: toast-refused " + en.Channel)
				}
			}
		}
	case EvJoined, EvRejoined, EvJoinFail, EvNames:
		u.addBuf(e.Channel)
		if e.Kind == EvJoined || e.Kind == EvRejoined {
			// Push the channel set on every join so a close-time LIFO
			// capture carries it even when the seat's save ask lands
			// late (the M147c reopen leg depends on the stored chans).
			u.saveNow()
		}
	}
	u.dirty = true
}

// --- input verbs ----------------------------------------------------------

// submit parses one input line: the slash verbs the card names, else a
// PRIVMSG to the focused channel.
func (u *uiApp) submit(line string) {
	line = strings.TrimSpace(line)
	if line == "" {
		return
	}
	vi.ConsoleLine("goirc: line " + line)
	if line[0] != '/' {
		ch := u.focusedBuf()
		if ch == "" {
			u.status("no channel focused — /join one first")
			u.dirty = true
			return
		}
		if u.cli == nil {
			u.status("not connected")
		} else if err := u.cli.Privmsg(ch, line); err != nil {
			u.status(errText(err))
		}
		u.dirty = true
		return
	}
	verb := line
	rest := ""
	if i := strings.IndexByte(line, ' '); i >= 0 {
		verb, rest = line[:i], strings.TrimSpace(line[i+1:])
	}
	switch strings.ToLower(verb) {
	case "/join":
		if !isChannel(rest) {
			u.status("usage: /join #channel")
			break
		}
		if u.cli != nil {
			_ = u.cli.Join(rest)
		}
		u.focusName(rest)
	case "/part":
		ch := rest
		if ch == "" {
			ch = u.focusedBuf()
		}
		if !isChannel(ch) {
			u.status("usage: /part [#channel]")
			break
		}
		if u.cli != nil {
			_ = u.cli.Part(ch, "")
		}
	case "/msg":
		target, text, _ := strings.Cut(rest, " ")
		if target == "" || strings.TrimSpace(text) == "" {
			u.status("usage: /msg target text")
			break
		}
		if u.cli != nil {
			_ = u.cli.Privmsg(target, strings.TrimSpace(text))
		}
		if isChannel(target) {
			u.addBuf(target)
		}
	case "/nick":
		if rest == "" {
			u.status("usage: /nick newnick")
			break
		}
		if u.cli != nil {
			_ = u.cli.SetNick(rest)
		}
	case "/quit":
		if u.cli != nil {
			_ = u.cli.Quit(rest) // EvQuit prints 'goirc: quit'
		}
		u.quit = true
	default:
		u.status("unknown command " + verb)
	}
	u.dirty = true
}

// --- keys / pointer -------------------------------------------------------

// scrollClamp bounds a buffer's scroll offset to what fits.
func (u *uiApp) scrollClamp(name string) {
	if u.cli == nil {
		return
	}
	n := u.cli.Backlog(name).Len()
	rows := u.scrollRows()
	max := n - rows
	if max < 0 {
		max = 0
	}
	if u.scroll[name] > max {
		u.scroll[name] = max
	}
}

// scrollRows is how many lines the scrollback pane can show.
func (u *uiApp) scrollRows() int {
	h := int(u.ta.H) - headH - inputH
	if h < 0 {
		return 0
	}
	return h / rowH
}

func (u *uiApp) scrollBy(d int) {
	name := u.focusedBuf()
	old := u.scroll[name]
	v := old + d
	if v < 0 {
		v = 0
	}
	u.scroll[name] = v
	u.scrollClamp(name)
	u.dirty = true
	if u.scroll[name] != old {
		u.saveNow()
	}
}

// moveFocus steps the rail selection by d (wrapping), like the up/down
// arrows.
func (u *uiApp) moveFocus(d int) {
	if len(u.bufs) == 0 {
		return
	}
	i := u.focus + d
	for i < 0 {
		i += len(u.bufs)
	}
	u.focusName(u.bufs[i%len(u.bufs)])
}

// railHit maps a canvas point to a buffer index, or -1.
func (u *uiApp) railHit(x, y int) int {
	if x < 0 || x >= railW || y < headH {
		return -1
	}
	i := (y - headH) / rowH
	if i < 0 || i >= len(u.bufs) {
		return -1
	}
	return i
}

// handleEvent routes one non-lifecycle window event.
func (u *uiApp) handleEvent(ev vi.Event) {
	// The consent dialog owns every event while it is open.
	if u.dlg != nil && u.dlg.Open {
		switch ev.Kind {
		case vi.EvKeyDown:
			if _, done := u.dlg.HandleKey(ev); done {
				u.consentAnswer()
			}
		case vi.EvMouseDown:
			x, y := int(ev.Arg0), int(ev.Arg1)
			if _, done := u.dlg.HandleMouse(x, y, true); done {
				u.consentAnswer()
			}
		}
		u.dirty = true
		return
	}
	switch ev.Kind {
	case vi.EvKeyDown:
		switch ev.Arg0 {
		case keyPgUp:
			u.scrollBy(u.scrollRows() - 1)
			return
		case keyPgDn:
			u.scrollBy(-(u.scrollRows() - 1))
			return
		case keyUp:
			u.moveFocus(-1)
			return
		case keyDown:
			u.moveFocus(1)
			return
		}
		if u.input.HandleKey(ev.Arg0, byte(ev.Arg1)) {
			u.dirty = true
		}
	case vi.EvMouseDown:
		x, y := int(ev.Arg0), int(ev.Arg1)
		if i := u.railHit(x, y); i >= 0 {
			u.focusName(u.bufs[i])
		}
	case vi.EvWinFocus:
		u.winFocus = true
		// Click-through: the seat refocused this window because a toast
		// named a buffer — land on it exactly once.
		if u.pendMention != "" {
			ch := u.pendMention
			u.pendMention = ""
			u.focusName(ch)
			u.saveNow()
		}
	case vi.EvWinBlur:
		u.winFocus = false
		vi.ConsoleLine("goirc: blur")
	}
}

// --- consent --------------------------------------------------------------

// needConsent reports whether the FIRST plaintext dial needs the dialog:
// plaintext selected, no --plain bit, and no stored consent answer.
func (u *uiApp) needConsent() bool {
	return !u.cfg.TLS && !u.cfg.AllowPlain
}

// openConsent raises the dialog before any dial.
func (u *uiApp) openConsent() {
	d := appkit.NewConfirm("Plaintext IRC",
		u.cfg.Host+":"+vi.Itoa64(int64(u.cfg.Port))+" has no TLS — connect anyway?")
	// Centre on the live canvas, not the native one.
	d.R = widgets.Rect{
		X: (int(u.ta.W) - d.R.W) / 2,
		Y: (int(u.ta.H) - d.R.H) / 2,
		W: d.R.W, H: d.R.H,
	}
	u.dlg = &d
}

// consentAnswer applies the dialog's result: Yes arms the session's
// AllowPlain bit (stored in save_state); anything else is the named
// refusal — the same marker the console driver would print.
func (u *uiApp) consentAnswer() {
	res := u.dlg.Result
	u.dlg = nil
	if res == "Yes" {
		u.cfg.AllowPlain = true
		vi.ConsoleLine("goirc: consent yes")
		u.saveNow()
		u.startClient()
		return
	}
	vi.ConsoleLine("goirc: consent no")
	vi.ConsoleLine(errPlainRefused)
	u.status("plaintext refused — the consent answer is stored; close or /quit")
}

// --- save_state -----------------------------------------------------------

// saveNow posts an unsolicited save after a material mutation (the M125f
// discipline: a crash between asks must still find the blob).
func (u *uiApp) saveNow() {
	if u.ta != nil && u.ta.SaveStateNow() {
		vi.ConsoleLine("goirc: state saved")
	}
}

// saveBlob is Config.SaveState's body — the live serialization.
func (u *uiApp) saveBlob() []byte { return u.st.encode(u) }

// restoreBlob is Config.RestoreState's body — decode or refuse whole.
// The blob is authoritative for every field it carries (the seat re-execs
// the same argv, so a stored answer is the NEWER fact).
func (u *uiApp) restoreBlob(b []byte) {
	if !u.st.decode(b) {
		vi.ConsoleLine("goirc: state refused")
		return
	}
	vi.ConsoleLine("goirc: state restored")
}

// applyRestored lands the decoded blob onto cfg + the rail before the
// client starts: server/port/TLS/nick, buffers + scroll, focus, consent.
func (u *uiApp) applyRestored() {
	if !u.st.restored {
		return
	}
	u.cfg.Host = u.st.host
	u.cfg.Port = u.st.port
	u.cfg.TLS = u.st.tls
	u.cfg.ServerName = u.st.sni
	if u.st.nick != "" {
		u.cfg.Nick = u.st.nick
	}
	if u.st.consent {
		u.cfg.AllowPlain = true
	}
	u.cfg.Channels = nil
	for _, ch := range u.st.chans {
		if ch.name != "" {
			u.cfg.Channels = append(u.cfg.Channels, ch.name)
		}
		u.addBuf(ch.name)
		u.scroll[ch.name] = int(ch.scroll)
	}
	if u.st.focus != "" {
		u.focusName(u.st.focus)
	}
}

// --- paint -----------------------------------------------------------------

// draw paints rail + scrollback + input (+ dialog) onto the live canvas.
func (u *uiApp) draw() {
	cv := u.ta.Canvas()
	tok := theme.Current
	w, h := int(u.ta.W), int(u.ta.H)
	cv.FillRect(widgets.Rect{W: w, H: h}, uidraw.Opaque(tok.Bg))

	// Header strip: nick @ host:port + connection state.
	state := "offline"
	if u.cli != nil {
		switch u.cli.State() {
		case StateDialing:
			state = "dialing"
		case StateRegistering:
			state = "registering"
		case StateOnline:
			state = "online"
		case StateBackoff:
			state = "backoff"
		case StateClosed:
			state = "closed"
		}
	}
	nick := u.cfg.Nick
	if u.cli != nil {
		nick = u.cli.Nick()
	}
	head := nick + " @ " + u.cfg.Host + ":" + vi.Itoa64(int64(u.cfg.Port)) + " (" + state + ")"
	cv.FillRect(widgets.Rect{W: w, H: headH}, uidraw.Opaque(tok.ChromeBg))
	widgets.DrawText(cv, widgets.Rect{X: tok.PadXS, W: w - 2*tok.PadXS, H: headH}, head, uidraw.Opaque(tok.Text))

	// The rail: one row per buffer, focused row highlighted.
	list := widgets.List{
		R:     widgets.Rect{Y: headH, W: railW, H: h - headH - inputH},
		RowH:  rowH,
		Sel:   u.focus,
		Fg:    tok.Ink,
		Bg:    tok.ChromeBg,
		SelBg: tok.Selection,
	}
	for _, b := range u.bufs {
		label := bufLabel(b)
		if u.cli != nil && b != "" && !u.cliJoined(b) {
			label += " -" // open buffer, not joined
		}
		list.Items = append(list.Items, label)
	}
	list.Draw(cv)

	// The scrollback: newest entries at the pane bottom, scrolled up by
	// scroll[focus]; mention lines carry the accent bar.
	name := u.focusedBuf()
	var ents []Entry
	switch {
	case u.cli != nil:
		ents = u.cli.Backlog(name).Entries()
	case name == "" && u.localLog != nil:
		ents = u.localLog.Entries()
	}
	pane := widgets.Rect{X: railW, Y: headH, W: w - railW, H: h - headH - inputH}
	cv.FillRect(pane, uidraw.Opaque(tok.Surface))
	rows := u.scrollRows()
	off := u.scroll[name]
	end := len(ents) - off
	if end > len(ents) {
		end = len(ents)
	}
	start := end - rows
	if start < 0 {
		start = 0
	}
	mynick := ""
	if u.cli != nil {
		mynick = u.cli.Nick()
	}
	for i := start; i < end; i++ {
		en := ents[i]
		y := headH + (i-start)*rowH
		row := widgets.Rect{X: railW, Y: y, W: w - railW, H: rowH}
		fg := tok.Text
		text := en.Text
		switch en.Kind {
		case EntryMsg:
			text = "<" + en.From + "> " + en.Text
		case EntryNotice:
			text = "-" + en.From + "- " + en.Text
		case EntryJoin, EntryPart, EntryKick, EntryNick:
			fg = tok.Muted
			text = "* " + en.Text
		case EntryError:
			fg = tok.Accent
			text = "! " + en.Text
		default:
			fg = tok.Muted
			text = "= " + en.Text
		}
		if en.Kind == EntryMsg && mynick != "" && mentionMatch(en.Text, mynick) {
			cv.FillRect(widgets.Rect{X: railW, Y: y, W: 3, H: rowH}, uidraw.Opaque(tok.Accent))
		}
		widgets.DrawText(cv, row.Inset(2), text, uidraw.Opaque(fg))
	}

	// The input line.
	u.input.R = widgets.Rect{Y: h - inputH, W: w, H: inputH}
	u.input.Focused = true
	u.input.Draw(cv)

	if u.dlg != nil && u.dlg.Open {
		u.dlg.Draw(cv)
	}
}

// cliJoined reports the live membership set's answer (cli nil → joined).
func (u *uiApp) cliJoined(ch string) bool {
	if u.cli == nil {
		return true
	}
	for _, j := range u.cli.Joined() {
		if j == ch {
			return true
		}
	}
	return false
}

// run is the whole front-end: init → (consent) → client → event loop.
func (u *uiApp) run() {
	// Seed the rail from the launch config so the list is populated
	// before the first JOIN confirm lands.
	for _, ch := range u.cfg.Channels {
		u.addBuf(ch)
	}
	// Fresh sessions land on the first channel; a restored blob keeps
	// its own focus (applyRestored already moved it — a saved "" is the
	// server buffer and must not be overridden here).
	if len(u.bufs) > 1 && !u.st.restored {
		u.focus = 1
	}
	u.draw()
	u.ta.Present()

	if u.needConsent() {
		u.openConsent()
		u.draw()
		u.ta.Present()
		// Printed AFTER the dialog reached the scanout — the gate's
		// pointer/chord anchor proves the ask was visible, not queued.
		vi.ConsoleLine("goirc: consent ask")
	} else {
		u.startClient()
	}

	for !u.quit {
		u.ta.PollStateAsk()
		idle := true
		for drained := false; !drained; {
			select {
			case e := <-u.evs:
				u.onEvent(e)
				idle = false
			default:
				drained = true
			}
		}
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				break
			}
			if idle {
				vi.Sleep(1)
			}
			continue
		}
		idle = false
		switch u.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			u.quit = true
		case tabapp.ActionResized:
			u.scrollClamp(u.focusedBuf())
			u.dirty = true
		case tabapp.ActionNone:
			u.handleEvent(ev)
		}
		if u.dirty {
			u.draw()
			u.ta.Present()
			u.dirty = false
		}
	}
	if u.cli != nil {
		_ = u.cli.Close()
	}
	vi.ConsoleLine("goirc: close")
	vi.ConsoleLine("goirc OK")
	u.ta.CloseAndExit(0)
}

// runUI is the --ui entry: window + (restored state) + run.
func runUI(o options) {
	u := &uiApp{
		cfg:      o.cfg,
		evs:      make(chan Event, evChanCap),
		bufs:     []string{""},
		scroll:   map[string]int{},
		st:       &ircState{},
		localLog: NewBacklog(BacklogCap),
	}
	u.input.OnSubmit = func(s string) { u.input.Clear(); u.submit(s) }
	u.input.OnCancel = func() { u.input.Clear() }
	ta := tabapp.Init(tabapp.Config{
		Name: appName,
		// The declare title is the executable's own name: GOTABWM's
		// guessBin default arm records the title verbatim, and the
		// seat's reopen LIFO re-execs it bare — argv lives only in the
		// save_state blob (the GOPAINT declare-title discipline).
		Title:        appName,
		X:            64,
		Y:            48,
		W:            uiNatW,
		H:            uiNatH,
		StateVersion: ircStateVersion,
		SaveState:    u.saveBlob,
		RestoreState: u.restoreBlob,
	})
	if ta == nil {
		vi.ConsoleLine("goirc: error open -1")
		vi.Exit(exitError)
	}
	u.ta = ta
	vi.ConsoleLine("goirc: open id=" + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine("goirc: declare accepted")
		// The rail label is the friendly name; the recorded bin stays the
		// executable the declare carried.
		if !ta.SetTabTitle("IRC") {
			_ = vi.WinSetTitle(ta.Win, "IRC")
		}
	} else {
		vi.ConsoleLine("goirc: declare refused")
	}
	u.applyRestored()
	// A bare exec with no staged blob has no host/nick to dial: the same
	// usage + exit the malformed-argv path gives, minus the argv walk.
	if u.cfg.Host == "" || u.cfg.Nick == "" {
		usage()
		u.ta.CloseAndExit(exitUsage)
	}
	u.run()
}
