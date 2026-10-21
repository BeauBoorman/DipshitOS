// GOSH's line editor and session history: a dumb-terminal editor over the
// /dev/tty byte stream. The kernel's tty Screen (ADR 0020 A4) understands
// printable bytes, \r, \b, \t and the CSI pair `ESC[2J`/`ESC[H`, and it
// does NOT echo — so every edit repaints the line with `\r`, overwrites the
// old tail with spaces, and repositions the cursor with a second `\r` +
// prefix, the same discipline the Zig editor (lib/tty.zig) used over this
// seam. Pure code; main.go feeds it tty bytes and writes back what it
// returns. Covered keymap: arrows, Home/End, Delete, Ctrl-A/E/K/U/W/L/C/D,
// Backspace, Tab completion, Up/Down history, word motion and word
// kill (alt-f / alt-b / alt-d / alt-backspace), Ctrl-T transpose and
// Ctrl-Y yank.
package shlib

import (
	"os"
	"strings"
	"unicode/utf8"
)

// historyMax is the session history ring bound (SH.BIN kept 16 entries; a
// Go shell can afford more without changing the contract: session-only,
// dup-collapsed, no persistence).
const historyMax = 64

// maxLineBytes bounds one interactive line. The startup contract's per-file
// cap is the same 2048 (main.go maxStartupBytes), so a staged line can never
// trip it. Past it the editor answers with a bell instead of growing the
// buffer -- and the O(n) repaint per keystroke -- without bound.
const maxLineBytes = 2048

// maxSearchQuery bounds one reverse-i-search query. SH.BIN's editor bounded
// its own query buffer; a longer query is simply not extended rather than
// being allowed to grow without limit.
const maxSearchQuery = 64

// defaultCols is the width the completion menu lays out for when no
// front-end has said otherwise: the kernel tty grid's 80 columns, which
// is also GOTERM's 640px window at the default cell size. shlib is a
// dumb-terminal editor and has no window-size query of its own, so a
// front-end that knows better calls SetCols.
const defaultCols = 80

// menuRowsPerPage is how many menu rows one Tab shows before the next
// Tab pages. There is no height query on this seam, so the page is a
// fixed, tested budget rather than a measured screen.
const menuRowsPerPage = 8

// menuGap is the blank columns between menu entries.
const menuGap = 2

// History is the recall ring: dup-collapsed, bounded to historyMax, and
// persisted across boots through the share (M69f1 / #1537, History.Load).
// The monitor's HISTORY.TXT is a different file with a different owner; it
// is never read or written from here.
type History struct {
	entries []string
}

// Push appends a submitted line unless it is empty or a dup of the last.
func (h *History) Push(line string) {
	if line == "" {
		return
	}
	if n := len(h.entries); n > 0 && h.entries[n-1] == line {
		return
	}
	h.entries = append(h.entries, line)
	if len(h.entries) > historyMax {
		h.entries = h.entries[len(h.entries)-historyMax:]
	}
}

// Entries returns a copy of the ring in order (oldest first).
func (h *History) Entries() []string {
	out := make([]string, len(h.entries))
	copy(out, h.entries)
	return out
}

// Load seeds the ring from a persisted history file (M69f1 / #1537): UTF-8,
// LF, one command per line, oldest first -- the shape SaveHistory writes.
// Two deliberate tolerances:
//
//   - a truncated last line (no trailing LF, which is what a half-finished
//     append looks like on the share) is SKIPPED rather than costing the
//     whole file, so a single bad append cannot silently erase recall;
//   - each line goes through Push, so an empty or consecutively-duplicated
//     entry is dropped by exactly the rule the live session uses.
func (h *History) Load(data []byte) {
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	if !strings.HasSuffix(text, "\n") {
		i := strings.LastIndexByte(text, '\n')
		if i < 0 {
			return // only a partial line: nothing recoverable
		}
		text = text[:i+1]
	}
	for _, ln := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		h.Push(strings.TrimRight(ln, "\r"))
	}
}

// evKind is what one Feed produced.
type evKind int

const (
	evNone evKind = iota
	EvSubmit
	EvEOF    // Ctrl-D on an empty line
	EvCancel // Ctrl-C: the line was abandoned
	EvEdit   // Ctrl-X Ctrl-E: hand the line to GOEDIT.ELF, run what it saves
)

// EditEvent carries at most one editor outcome per Feed.
type EditEvent struct {
	Kind evKind
	Line string // for EvSubmit, without the newline
}

// editor CSI decode states.
const (
	edGround = iota
	edEsc
	edCSI
	edPaste
)

// M154a (#2926): DECSET 2004 bracketed paste, ON by default — the modern
// terminal contract, and what the Zig editor's own paste_enable
// (lib/tty.zig) already asked for before this port. The editor writes the
// enable when a line read opens (Repaint, and the post-command prompt the
// front-ends paint through PromptBytes) and the disable when the line is
// submitted or the editor exits, so a running program never receives
// wrapped pastes. BRACKETED_PASTE=0 in the process environment is the
// opt-out — envp is the only channel that reaches a running program —
// and restores the pre-card byte stream exactly: no wraps are emitted
// and the markers keep their old `n ~` meaning.
const (
	pasteEnable  = "\x1b[?2004h"
	pasteDisable = "\x1b[?2004l"
	// pasteEndSeq is the region terminator; matched byte-at-a-time across
	// reads, so a marker split anywhere still closes the paste.
	pasteEndSeq = "\x1b[201~"
	// pasteMaxBytes bounds one bracketed paste (the card's pinned 4 KiB).
	// It sits well above the kernel's 1024 B input queue and the 512 B
	// clipboard, so no kernel-driven paste ever reaches it — it guards
	// the staging buffer against a paste stream that simply never ends.
	pasteMaxBytes = 4096
	// pasteTruncMarker is the named in-line notice appended when a paste
	// was clipped — by the bound above or by the line's own cap — so a
	// shortened paste is visible instead of silently losing its tail.
	pasteTruncMarker = " [paste truncated]"
)

// Editor is the line editor for one tty session.
type Editor struct {
	LineBuffer
	// prompt is the TEMPLATE -- the persisted SETTINGS.TXT value -- and
	// promptOut is its expansion for the line being edited (M80n #1730).
	// facts supplies what the escapes ask about; with no facts the
	// template is written verbatim, so an editor nobody gave escapes to
	// paints exactly what it always did.
	prompt    string
	promptOut []byte
	facts     func() PromptFacts
	hist      *History
	hview     int // -1 = editing the live line
	lastLen   int // painted prompt+line length, for the tail overwrite
	// Completion menu (M80m #1729). `menu` is the candidate snapshot the
	// menu opened with -- kept so a cycle can step the same set without
	// re-running Complete -- `menuStart` is where the completed word began,
	// so a cycle replaces exactly that word, and `menuPage` walks the
	// listing when it is taller than menuRowsPerPage. `cols` is the grid
	// width the layout aims at.
	menu      []string
	menuStart int
	menuPage  int
	menuAt    int
	menuOn    bool
	// cx is the one-shot Ctrl-X prefix (M98h): armed by 0x18, spent by the
	// next byte whatever it is — 0x05 produces EvEdit, anything else is
	// processed normally as if the prefix never happened.
	cx   bool
	cols int
	// kill ring + consecutive-kill merge (M80l #1728). One entry is the
	// minimum readline contract: every kill (Ctrl-K/U/W, alt-d,
	// alt-backspace) parks what it removed, and a kill that continues the
	// previous one -- same direction, cursor untouched since -- grows that
	// entry instead of replacing it. killLo/killHi/killDir record where the
	// last kill happened; breakKill ends the chain without emptying the ring.
	kill     []byte
	killLo   int
	killHi   int
	killDir  int    // killNone / killBackward / killForward
	state    int    // edGround / edEsc / edCSI / edPaste
	csiParam int    // accumulated CSI parameter
	csiGotP  bool   // saw at least one parameter digit
	// M154a (#2926): the bracketed-paste staging buffer. Bytes between
	// ESC[200~ and ESC[201~ accumulate here and commit as ONE edit at the
	// terminator — embedded newlines are literal line bytes that paint as
	// ^J markers — so a 20-line script can be reviewed before Enter runs
	// it once. pasteMatch counts the terminator prefix matched so far (it
	// persists across Feeds, so a split marker still closes), pasteTrunc
	// records that the pasteMaxBytes bound clipped the tail.
	paste      []byte
	pasteMatch int
	pasteTrunc bool
	utf8Need uint8  // continuation bytes left in the current input rune
	utf8Drop uint8  // continuation bytes left in a rune rejected at a byte cap
	pending  []byte // unread input after a submit cut a chunk short
	// reverse-i-search (M45 SH3): while searching, every byte feeds the
	// query matcher instead of the line, and the draft line is held so a
	// cancel can put it back. Mirrors user/src/lib/tty.zig's search_* set.
	searching bool
	query     []byte
	draft     []byte
	draftCur  int
	// Complete proposes candidates for the word being completed, given the
	// M98g context: the line, the cursor, and the stage head it sits under.
	Complete func(req CompleteRequest) []string
}

// NewEditor wires an editor over a history ring.
func NewEditor(prompt string, h *History) *Editor {
	e := &Editor{
		LineBuffer: NewLineBuffer(maxLineBytes),
		prompt:     prompt,
		promptOut:  []byte(prompt),
		hist:       h,
		hview:      -1,
		cols:       defaultCols,
	}
	return e
}

// SetPrompt swaps the prompt TEMPLATE (SETTINGS.TXT drives it at startup
// and after every command, so a mid-session goset change still lands) and
// re-expands it against the facts as they stand right now.
func (e *Editor) SetPrompt(p string) {
	e.prompt = p
	e.RefreshPrompt()
}

// SetPromptFacts gives the prompt escapes something to ask about. The
// provider is called once per line, not once per keystroke: the cwd cannot
// change while a line is being edited, and a provider that walked the
// directory on every repaint would make typing O(directory).
func (e *Editor) SetPromptFacts(f func() PromptFacts) {
	e.facts = f
	e.RefreshPrompt()
}

// RefreshPrompt re-expands the template. Call it when the facts could have
// moved under an unchanged template -- after a `cd`, say -- so the next
// line's prompt is the one the shell is actually in.
func (e *Editor) RefreshPrompt() {
	if e.facts == nil {
		e.promptOut = []byte(e.prompt)
	} else {
		e.promptOut = []byte(ExpandPrompt(e.prompt, e.facts()))
	}
	e.lastLen = 0
}

// bracketed reports whether DECSET 2004 wraps are emitted and decoded:
// on by default, off when BRACKETED_PASTE=0 is in the process envp (the
// only channel that reaches a running program — `set`/`export` it in the
// shell that execs the front-end). Read at each decision so an editor's
// contract never straddles a mid-session toggle.
func (e *Editor) bracketed() bool { return os.Getenv("BRACKETED_PASTE") != "0" }

// PromptBytes is the expanded prompt, for the front-end's own post-submit
// write — plus the DECSET 2004 enable, since this write is what opens the
// next line read after a command that ran with paste unwrapped. Both
// front-ends paint the prompt themselves after a command (M73d #1628: the
// submit echo is a bare \r\n), so they must write the SAME bytes the
// editor would repaint -- otherwise the fresh prompt and the first
// in-line repaint disagree and the line jitters by a prompt's width.
func (e *Editor) PromptBytes() []byte {
	if e.bracketed() {
		out := make([]byte, 0, len(pasteEnable)+len(e.promptOut))
		out = append(out, pasteEnable...)
		return append(out, e.promptOut...)
	}
	return e.promptOut
}

// SetCols tells the editor how wide the terminal grid is, so the
// completion menu can columnate to it. A non-positive value restores the
// default.
func (e *Editor) SetCols(n int) {
	if n <= 0 {
		n = defaultCols
	}
	e.cols = n
}

// Repaint renders the current state: the prompt and line from scratch.
// It re-expands the prompt first -- this is what a front-end calls to open
// a line, so it is the natural place to notice a `cd` from the last one —
// and it opens with the DECSET 2004 enable: this is the write that starts
// a line read.
func (e *Editor) Repaint() []byte {
	e.RefreshPrompt()
	if e.bracketed() {
		return append([]byte(pasteEnable), e.paint()...)
	}
	return e.paint()
}

// paintLine renders the buffer for the tty: a pasted newline is a real
// byte in the line but must not reach the grid as a control code, so it
// paints as the ^J marker (and \r as ^M) — the same caret notation the
// serial console already reads. Lines without a paste carry no marker
// and the render is the identity.
func paintLine(buf []byte) []byte {
	var out []byte
	for i := 0; i < len(buf); i++ {
		var m byte
		switch buf[i] {
		case '\n':
			m = 'J'
		case '\r':
			m = 'M'
		default:
			if out != nil {
				out = append(out, buf[i])
			}
			continue
		}
		if out == nil {
			out = make([]byte, 0, len(buf)+8)
			out = append(out, buf[:i]...)
		}
		out = append(out, '^', m)
	}
	if out == nil {
		return buf
	}
	return out
}

// paint composes the repaint: `\r` + prompt + line, spaces over the old
// tail, then `\r` + prompt + the line up to the cursor.
func (e *Editor) paint() []byte {
	// Cells, not bytes: the grid is rune-based and a prompt can carry colour
	// codes and bracket-marked spans that paint nothing (M80n #1730). A
	// byte count here would write the wrong number of tail spaces and leave
	// the old line's last cells on screen. The line renders through
	// paintLine so a pasted newline's ^J marker counts its two cells.
	line := paintLine(e.Bytes())
	caret := paintLine(e.Bytes()[:e.Caret()])
	content := VisibleWidth(string(e.promptOut)) + VisibleWidth(string(line))
	tail := e.lastLen - content
	if tail < 0 {
		tail = 0
	}
	out := make([]byte, 0, content+tail+2+content)
	out = append(out, '\r')
	out = append(out, e.promptOut...)
	out = append(out, line...)
	out = append(out, []byte(strings.Repeat(" ", tail))...)
	out = append(out, '\r')
	out = append(out, e.promptOut...)
	out = append(out, caret...)
	e.lastLen = content
	return out
}

// Feed processes the next input chunk and returns the bytes to write back
// to the tty plus at most one event. Input that arrives after a submit in
// the same chunk is held for the next Feed.
func (e *Editor) Feed(chunk []byte) ([]byte, EditEvent) {
	if len(e.pending) > 0 {
		chunk = append(e.pending, chunk...)
		e.pending = nil
	}
	if e.searching {
		// Search mode owns the byte stream (SH.BIN's feed does the same). An
		// accept or cancel ends it mid-chunk, and the REST of the chunk is
		// deferred to the ground loop -- which is what lets a staged
		// `Ctrl+R query CR CR` accept the recall and then submit it.
		var out []byte
		for i := 0; i < len(chunk); i++ {
			if dropped, ring := e.discardOverflowingRune(chunk[i], maxSearchQuery-len(e.query)); dropped {
				if ring {
					out = append(out, 0x07)
				}
				continue
			}
			incomplete := e.trackInputRune(chunk[i])
			w, finished := e.searchByte(chunk[i])
			if incomplete {
				w = nil
			}
			out = append(out, w...)
			if finished {
				if i+1 < len(chunk) {
					e.pending = append([]byte{}, chunk[i+1:]...)
				}
				return out, EditEvent{}
			}
		}
		return out, EditEvent{}
	}
	var out []byte
	for i := 0; i < len(chunk); i++ {
		b := chunk[i]
		incomplete := false
		if e.state != edCSI && e.state != edPaste {
			if dropped, ring := e.discardOverflowingRune(b, maxLineBytes-len(e.Bytes())); dropped {
				if ring {
					out = append(out, 0x07)
				}
				continue
			}
			incomplete = e.trackInputRune(b)
		} else {
			e.utf8Need = 0
		}
		// Any byte that is not Tab ends the completion menu: a printable
		// key dismisses it and inserts, a chord or an arrow dismisses it
		// and does its own thing. Tab keeps it up so a repeat can page or
		// cycle. This one line is the whole dismissal rule -- ESC is a
		// non-Tab byte, so the ESC-prefixed chords dismiss on the escape
		// itself and still act on the byte that follows.
		if b != '\t' {
			e.dismissMenu()
		}
		var w []byte
		var ev EditEvent
		switch e.state {
		case edEsc:
			if b == '[' {
				e.state = edCSI
				e.csiParam, e.csiGotP = 0, false
				continue
			}
			e.state = edGround
			// xterm's alt convention: Alt-X arrives as ESC X. Word motion and
			// word kill are dispatched here (M80l #1728), so the ESC is
			// consumed and the prefixed byte never reaches the ground editor:
			// `ESC f` moves a word instead of typing an "f".
			switch b {
			case 'f':
				w, ev = e.keyWordForward()
			case 'b':
				w, ev = e.keyWordBackward()
			case 'd':
				w, ev = e.keyKillWordForward()
			case 0x7f, 0x08: // Alt-Backspace: kill the word before the cursor
				w, ev = e.keyKillWordBack()
			default:
				// A lone ESC (or ESC followed by anything but '[' or an alt
				// key) is not a sequence this keymap consumes. Drop the ESC and
				// treat THIS byte as ground input: eating it would mean Escape
				// followed by typing a character silently loses the character.
				// The kernel's keymap emits ESC [ X for every arrow/Home/End,
				// so no SS3-style sequence (`ESC O A`) reaches here to be
				// misread as text.
				w, ev = e.keyGround(b)
			}
		case edCSI:
			switch {
			case b >= '0' && b <= '9':
				e.csiParam = e.csiParam*10 + int(b-'0')
				e.csiGotP = true
			case b == '~':
				switch {
				case e.bracketed() && e.csiGotP && e.csiParam == 200:
					// A DECSET-2004 paste begins: stage bytes until
					// ESC[201~, then commit them as one edit.
					e.state = edPaste
					e.paste = e.paste[:0]
					e.pasteMatch = 0
					e.pasteTrunc = false
				case e.bracketed() && e.csiGotP && e.csiParam == 201:
					// A stray paste terminator is consumed, not Delete.
					e.state = edGround
				default:
					w, ev = e.keyDelete()
					e.state = edGround
				}
			default:
				// A final byte: A/B/C/D/H/F are the M49 keymap.
				switch b {
				case 'A':
					w, ev = e.histPrev()
				case 'B':
					w, ev = e.histNext()
				case 'C':
					w, ev = e.keyRight()
				case 'D':
					w, ev = e.keyLeft()
				case 'H':
					w, ev = e.keyHome()
				case 'F':
					w, ev = e.keyEnd()
				}
				e.state = edGround
			}
		case edPaste:
			w, ev = e.pasteByte(b)
		default:
			w, ev = e.keyGround(b)
		}
		if incomplete {
			w = nil
		}
		out = append(out, w...)
		if ev.Kind != evNone {
			if i+1 < len(chunk) {
				e.pending = append([]byte{}, chunk[i+1:]...)
			}
			return out, ev
		}
		if e.searching {
			// Ctrl+R took over mid-chunk: the rest of this chunk belongs to
			// the query, not to the line. Defer it (the search branch at the
			// top of Feed consumes it on the next call) — without this, a
			// staged `Ctrl+R status` inserts "status" into the line and
			// searches for nothing.
			if i+1 < len(chunk) {
				e.pending = append([]byte{}, chunk[i+1:]...)
			}
			return out, EditEvent{}
		}
	}
	return out, EditEvent{}
}

// trackInputRune reports whether b leaves a UTF-8 rune incomplete. The tty
// renderer decodes UTF-8 across writes; repainting after each byte of a pasted
// rune would put CR and the prompt between its lead and continuation bytes,
// turning a valid rune into replacement glyphs. The editor still buffers each
// byte, but suppresses those intermediate repaints until the rune is whole.
func (e *Editor) trackInputRune(b byte) bool {
	if e.utf8Need > 0 {
		if b&0xC0 == 0x80 {
			e.utf8Need--
			return e.utf8Need > 0
		}
		e.utf8Need = 0
	}
	switch {
	case b >= 0xC2 && b <= 0xDF:
		e.utf8Need = 1
	case b >= 0xE0 && b <= 0xEF:
		e.utf8Need = 2
	case b >= 0xF0 && b <= 0xF4:
		e.utf8Need = 3
	default:
		return false
	}
	return true
}

// discardOverflowingRune rejects a multibyte rune before its first byte can
// leave a partial UTF-8 sequence in a capped line or search query. Once a
// rune is rejected, its continuation bytes are consumed across Feed calls.
func (e *Editor) discardOverflowingRune(b byte, remaining int) (discarded, ring bool) {
	if e.utf8Drop > 0 {
		if b&0xC0 == 0x80 {
			e.utf8Drop--
			return true, false
		}
		e.utf8Drop = 0
	}

	runeBytes := 1
	switch {
	case b >= 0xC2 && b <= 0xDF:
		runeBytes = 2
	case b >= 0xE0 && b <= 0xEF:
		runeBytes = 3
	case b >= 0xF0 && b <= 0xF4:
		runeBytes = 4
	default:
		return false, false
	}
	if runeBytes <= remaining {
		return false, false
	}
	e.utf8Drop = uint8(runeBytes - 1)
	return true, true
}

// Pending reports whether the editor is still holding input that arrived
// after a submit in the same chunk. Feed returns at most one event per call,
// so a caller that reads a *burst* of bytes (the serial front-end can return
// several whole lines in one read) must keep calling Feed — with a nil chunk
// — until this is false, or the rest of the burst sits unread forever.
func (e *Editor) Pending() bool { return len(e.pending) > 0 }

// -- reverse-i-search (M45 SH3, SH.BIN's search_* semantics) --------------

// searchEnter opens reverse-i-search, saving the draft line for a cancel.
// Returns the paint for the search prompt.
func (e *Editor) searchEnter() []byte {
	e.breakKill()
	e.draft = append(e.draft[:0], e.Bytes()...)
	e.draftCur = e.Caret()
	e.searching = true
	e.query = e.query[:0]
	return e.searchPaint()
}

// searchPaint renders `(reverse-i-search)`query`: match` and loads the match
// as the live line, so an accept needs no further swap. An empty query shows
// `_` and cannot match, exactly as SH.BIN's redraw does.
func (e *Editor) searchPaint() []byte {
	shown := string(e.query)
	if shown == "" {
		shown = "_"
	}
	out := []byte("\r\n(reverse-i-search)`" + shown + "`: ")
	if m, ok := e.searchMatch(string(e.query)); ok {
		out = append(out, m...)
		e.SetValue(string(m))
	} else {
		out = append(out, "(no match)"...)
	}
	// The search line is its own paint; the next ground paint starts from a
	// clean slate rather than overwriting a tail it never measured.
	e.lastLen = 0
	return out
}

// searchMatch finds the NEWEST history entry containing query (a substring
// match, newest-first, the same rule SH.BIN used). An empty query matches
// nothing rather than everything.
func (e *Editor) searchMatch(query string) (string, bool) {
	if query == "" || e.hist == nil {
		return "", false
	}
	ents := e.hist.Entries() // oldest first
	for i := len(ents) - 1; i >= 0; i-- {
		if strings.Contains(ents[i], query) {
			return ents[i], true
		}
	}
	return "", false
}

// searchByte handles one byte in search mode, returning the bytes to write
// and whether search mode ended (accept or cancel).
//
// Three bytes are deliberately NOT handled, and the map is one-way on
// purpose: a repeat Ctrl+R (0x12) is IGNORED, so search is newest-match-only
// rather than walking to older hits — `tty.zig`'s search byte handler ignores
// 0x12 in search mode the same way, so there is no walk state to port. Ctrl+G
// (0x07) is ignored too: only Enter/Esc/Ctrl-C leave search mode, in both
// codebases. Every other control byte is not query text.
//
// One deliberate DIVERGENCE from the reference: a full query rings the bell
// (`0x07`) instead of dropping the byte silently, so the bound is visible to
// the person typing. The bound itself is the same (maxSearchQuery).
func (e *Editor) searchByte(b byte) ([]byte, bool) {
	switch {
	case b == 0x1b, b == 0x03: // Esc / Ctrl-C: cancel and restore the draft
		return e.searchExit(false), true
	case b == '\r', b == '\n': // Enter: accept the current match
		return e.searchExit(true), true
	case b == 0x7f, b == 0x08: // Backspace: trim the query
		if n := len(e.query); n > 0 {
			e.query = e.query[:previousRuneBoundary(e.query, n)]
			return e.searchPaint(), false
		}
		return nil, false
	case b == 0x0c: // Ctrl-L: ignored inside search (SH.BIN's behavior)
		return nil, false
	case b >= 0x20 && b != 0x7f: // a query byte
		if len(e.query) >= maxSearchQuery {
			return []byte{0x07}, false // query full: bell, no append
		}
		e.query = append(e.query, b)
		return e.searchPaint(), false
	}
	return nil, false // other control bytes are not query text
}

// searchExit leaves search mode. On accept the line keeps whatever the last
// match loaded; on cancel the saved draft comes back. It repaints either way,
// so the caller never has to.
func (e *Editor) searchExit(accept bool) []byte {
	e.breakKill()
	e.searching = false
	if !accept {
		e.SetValue(string(e.draft))
		e.SetCaret(e.draftCur)
	}
	e.lastLen = 0
	return append([]byte("\r\n"), e.paint()...)
}

// keyGround handles one non-CSI byte in the ground state.
func (e *Editor) keyGround(b byte) ([]byte, EditEvent) {
	if e.cx {
		e.cx = false
		if b == 0x05 {
			return e.keyEditLine()
		}
		// Any other byte drops the prefix and is processed normally.
	}
	switch b {
	case 0x1b:
		e.state = edEsc
		return nil, EditEvent{}
	case '\r', '\n':
		e.breakKill()
		line := string(e.Bytes())
		// M98c (#2129): history expansion lives here — inside the Editor,
		// before Push — so only typed interactive lines expand and both
		// front-ends inherit it. On a change the expanded line is echoed,
		// pushed and submitted; on an error nothing submits and the typed
		// line stays in the buffer for a fix (bash's histreedit).
		var hist []string
		if e.hist != nil {
			hist = e.hist.Entries()
		}
		if expanded, changed, herr := expandHistory(line, hist); herr != nil {
			out := append([]byte("\r\n"), herr.Error()...)
			out = append(out, '\r', '\n')
			e.RefreshPrompt()
			return append(out, e.paint()...), EditEvent{}
		} else if changed {
			line = expanded
			out := append(e.submitPrefix(), '\r', '\n')
			out = append(out, expanded...)
			out = append(out, '\r', '\n')
			e.Clear()
			e.hview = -1
			e.lastLen = 0
			e.hist.Push(line)
			return out, EditEvent{Kind: EvSubmit, Line: line}
		}
		out := append(e.submitPrefix(), '\r', '\n')
		e.Clear()
		e.hview = -1
		e.lastLen = 0
		e.hist.Push(line)
		// M73d (#1628): submit echoes ONLY the newline. The next prompt
		// belongs AFTER the command's output — the reference shell loop
		// (user/src/lib/shell.zig, SH.BIN/TERM.BIN) prints it after
		// execution, and painting it here put `gosh> ` at the head of the
		// output block: observed the live-term-depth selection then began
		// `gosh> LINE-00 ...` (+6 bytes = 395 vs the gate's 389) while a
		// screen-clearing command erased the prompt with nothing to
		// repaint it. Front-ends write the prompt after RunLine returns.
		return out, EditEvent{Kind: EvSubmit, Line: line}
	case 0x7f, 0x08: // DEL / backspace
		return e.keyBackspace()
	case 0x01: // Ctrl-A
		return e.keyHome()
	case 0x05: // Ctrl-E
		return e.keyEnd()
	case 0x18: // Ctrl-X: arm the one-shot prefix (Ctrl-X Ctrl-E edits)
		e.cx = true
		return nil, EditEvent{}
	case 0x0b: // Ctrl-K: kill to end
		return e.killRegion(e.Caret(), len(e.Bytes()), killForward)
	case 0x15: // Ctrl-U: kill to start
		return e.killRegion(0, e.Caret(), killBackward)
	case 0x17: // Ctrl-W: kill the word before the cursor
		return e.keyKillWordBack()
	case 0x19: // Ctrl-Y: yank the last kill back onto the line
		return e.keyYank()
	case 0x14: // Ctrl-T: transpose the characters around the cursor
		return e.keyTranspose()
	case 0x0c: // Ctrl-L: clear the screen and repaint
		return append([]byte("\x1b[2J\x1b[H"), e.paint()...), EditEvent{}
	case 0x12: // Ctrl+R: reverse-i-search through history (M45 SH3)
		return e.searchEnter(), EditEvent{}
	case 0x03: // Ctrl-C: abandon the line
		e.breakKill()
		e.Clear()
		e.hview = -1
		e.lastLen = 0
		e.RefreshPrompt()
		out := append([]byte("^C\r\n"), e.paint()...)
		return out, EditEvent{Kind: EvCancel}
	case 0x04: // Ctrl-D on an empty line: EOF — the editor exits, so the
		// bracketed-paste contract ends with it.
		if len(e.Bytes()) == 0 {
			return e.submitPrefix(), EditEvent{Kind: EvEOF}
		}
		return nil, EditEvent{}
	case '\t':
		return e.keyTab()
	}
	if b < 0x20 {
		return nil, EditEvent{} // other control bytes are not text
	}
	if len(e.Bytes()) >= maxLineBytes {
		return []byte{0x07}, EditEvent{} // line full: bell, no insert
	}
	// Printable: insert at the cursor.
	e.breakKill()
	e.InsertByte(b)
	return e.paint(), EditEvent{}
}

func (e *Editor) keyBackspace() ([]byte, EditEvent) {
	if e.Caret() == 0 {
		return nil, EditEvent{}
	}
	e.breakKill()
	start := previousRuneBoundary(e.Bytes(), e.Caret())
	e.Replace(start, e.Caret(), nil)
	e.SetCaret(start)
	return e.paint(), EditEvent{}
}

func (e *Editor) keyDelete() ([]byte, EditEvent) {
	if e.Caret() < len(e.Bytes()) {
		e.breakKill()
		end := nextRuneBoundary(e.Bytes(), e.Caret())
		e.Replace(e.Caret(), end, nil)
		return e.paint(), EditEvent{}
	}
	return nil, EditEvent{}
}

func (e *Editor) keyLeft() ([]byte, EditEvent) {
	if e.Caret() > 0 {
		e.breakKill()
		e.SetCaret(previousRuneBoundary(e.Bytes(), e.Caret()))
		return e.paint(), EditEvent{}
	}
	return nil, EditEvent{}
}

func (e *Editor) keyRight() ([]byte, EditEvent) {
	if e.Caret() < len(e.Bytes()) {
		e.breakKill()
		e.SetCaret(nextRuneBoundary(e.Bytes(), e.Caret()))
		return e.paint(), EditEvent{}
	}
	return nil, EditEvent{}
}

func (e *Editor) keyHome() ([]byte, EditEvent) {
	e.breakKill()
	e.SetCaret(0)
	return e.paint(), EditEvent{}
}

func (e *Editor) keyEnd() ([]byte, EditEvent) {
	e.breakKill()
	e.End()
	return e.paint(), EditEvent{}
}

// histPrev/histNext walk the history ring. Leaving the live line for the
// ring starts at the newest entry; walking past the oldest returns to it.
func (e *Editor) histPrev() ([]byte, EditEvent) {
	n := len(e.hist.entries)
	if n == 0 {
		return nil, EditEvent{}
	}
	if e.hview == -1 {
		e.hview = n - 1
	} else if e.hview > 0 {
		e.hview--
	}
	e.breakKill()
	e.SetValue(string(e.hist.entries[e.hview]))
	return e.paint(), EditEvent{}
}

func (e *Editor) histNext() ([]byte, EditEvent) {
	if e.hview == -1 {
		return nil, EditEvent{}
	}
	e.breakKill()
	if e.hview < len(e.hist.entries)-1 {
		e.hview++
		e.SetValue(string(e.hist.entries[e.hview]))
	} else {
		e.hview = -1
		e.Clear()
	}
	return e.paint(), EditEvent{}
}

// keyTab completes the word before the cursor from Complete's candidates: one
// candidate inserts outright and several complete to the common prefix. When
// the prefix adds nothing there is nothing to insert, so Tab opens the
// completion menu instead of ringing a bell; a further Tab pages the menu, and
// once the last page is up it cycles the candidates.
func (e *Editor) keyTab() ([]byte, EditEvent) {
	if e.Complete == nil {
		return nil, EditEvent{}
	}
	if e.menuOn {
		// The word cannot have changed while the menu is up -- any other byte
		// dismissed it -- so page or cycle the snapshot instead of asking
		// Complete about a word we already asked about.
		if e.menuPage+1 < e.menuPages() {
			e.menuPage++
			return e.menuPaint(), EditEvent{}
		}
		return e.menuCycle()
	}
	start := e.Caret()
	for start > 0 && e.Bytes()[start-1] != ' ' {
		start--
	}
	word := string(e.Bytes()[start:e.Caret()])
	cmd, argIndex := stageCtx(string(e.Bytes()), start)
	cands := e.Complete(CompleteRequest{
		Line:      string(e.Bytes()),
		Cursor:    e.Caret(),
		WordStart: start,
		Word:      word,
		ArgIndex:  argIndex,
		Cmd:       cmd,
	})
	if len(cands) == 0 {
		return nil, EditEvent{}
	}
	if len(cands) == 1 {
		// One candidate: insert what is missing, which for a command is its
		// trailing space. A candidate the word already spells adds nothing,
		// and says so with silence rather than a one-row menu.
		if rest := cands[0][len(word):]; rest != "" {
			return e.ins([]byte(rest))
		}
		return nil, EditEvent{}
	}
	prefix := commonPrefix(cands)
	if len(prefix) > len(word) {
		return e.ins([]byte(prefix[len(word):]))
	}
	// Own a copy of the candidates: the menu is a snapshot that outlives
	// this call, and a completer is free to reuse the slice it returned.
	e.menu = append([]string(nil), cands...)
	e.menuStart = start
	e.menuAt = -1
	e.menuPage = 0
	e.menuOn = true
	return e.menuPaint(), EditEvent{}
}

// keyEditLine is Ctrl-X Ctrl-E (M98h): the buffer leaves the editor for
// GOEDIT.ELF, carried on EvEdit the way EvSubmit carries a line. The buffer
// clears the way submit's does — if the round trip fails the front-end puts
// the line back — and the painted row ends with a newline for the editor's
// own output.
func (e *Editor) keyEditLine() ([]byte, EditEvent) {
	e.breakKill()
	line := string(e.Bytes())
	e.Clear()
	e.hview = -1
	e.lastLen = 0
	return append(e.submitPrefix(), '\r', '\n'), EditEvent{Kind: EvEdit, Line: line}
}

// submitPrefix opens the submit/exit echo: the DECRST half of the
// bracketed-paste contract, written before the newline so the mode is off
// while the submitted program owns the tty — a running program never
// receives wrapped pastes. Nil under the opt-out, which keeps the
// pre-card byte stream exactly.
func (e *Editor) submitPrefix() []byte {
	if e.bracketed() {
		return []byte(pasteDisable)
	}
	return nil
}

// ins inserts ins at the cursor unless that would pass the line cap, in
// which case it answers with a bell and leaves the line alone.
func (e *Editor) ins(ins []byte) ([]byte, EditEvent) {
	if len(e.Bytes())+len(ins) > maxLineBytes {
		return []byte{0x07}, EditEvent{}
	}
	e.breakKill()
	c := e.Caret()
	e.Replace(c, c, ins)
	e.SetCaret(c + len(ins))
	return e.paint(), EditEvent{}
}

// pasteByte consumes one byte inside a DECSET-2004 bracketed paste
// (edPaste). Content stages in e.paste until the ESC[201~ terminator
// lands — the match persists across Feeds, so a marker split anywhere
// still closes — then the whole region commits as ONE edit. A byte that
// cannot extend the terminator (a stray ESC included) is literal content;
// a second 200~ inside the region is literal for the same reason.
func (e *Editor) pasteByte(b byte) ([]byte, EditEvent) {
	if b == pasteEndSeq[e.pasteMatch] {
		e.pasteMatch++
		if e.pasteMatch == len(pasteEndSeq) {
			e.pasteMatch = 0
			e.state = edGround
			return e.commitPaste()
		}
		return nil, EditEvent{}
	}
	if e.pasteMatch > 0 {
		// The matched prefix was not the terminator after all: replay it
		// as content, then re-judge this byte from the start.
		e.pasteTake([]byte(pasteEndSeq[:e.pasteMatch]))
		e.pasteMatch = 0
	}
	if b == 0x1b {
		e.pasteMatch = 1
		return nil, EditEvent{}
	}
	e.pasteTake([]byte{b})
	return nil, EditEvent{}
}

// pasteTake appends staged paste bytes, bounded to pasteMaxBytes; the
// overflow sets pasteTrunc so commitPaste can name the clip.
func (e *Editor) pasteTake(b []byte) {
	room := pasteMaxBytes - len(e.paste)
	if len(b) > room {
		e.pasteTrunc = true
		b = b[:max(room, 0)]
	}
	e.paste = append(e.paste, b...)
}

// commitPaste inserts the finished paste at the cursor as one pending
// edit — the point of the wrap: the 20 pasted lines are reviewable text,
// not 20 submits. The insert stays inside the line cap: a paste clipped
// by pasteMaxBytes or by what fits lands shortened and carries
// pasteTruncMarker, so a truncated block is visible instead of silently
// losing its tail.
func (e *Editor) commitPaste() ([]byte, EditEvent) {
	ins := e.paste
	e.paste = nil
	trunc := e.pasteTrunc
	e.pasteTrunc = false
	room := maxLineBytes - len(e.Bytes())
	if room <= 0 {
		return []byte{0x07}, EditEvent{}
	}
	if trunc || len(ins) > room {
		take := room - len(pasteTruncMarker)
		if take < 0 {
			take = 0
		}
		if take < len(ins) {
			ins = ins[:clipRuneBoundary(ins, take)]
		}
		marked := make([]byte, 0, len(ins)+len(pasteTruncMarker))
		marked = append(marked, ins...)
		ins = append(marked, pasteTruncMarker...)
		if len(ins) > room {
			ins = ins[:room]
		}
	}
	if len(ins) == 0 {
		return nil, EditEvent{}
	}
	e.breakKill()
	c := e.Caret()
	e.Replace(c, c, ins)
	e.SetCaret(c + len(ins))
	return e.paint(), EditEvent{}
}

// insertAt inserts ins into buf at index at (0 <= at <= len(buf)).
func insertAt(buf []byte, at int, ins []byte) []byte {
	buf = append(buf, make([]byte, len(ins))...)
	copy(buf[at+len(ins):], buf[at:len(buf)-len(ins)])
	copy(buf[at:], ins)
	return buf
}

// commonPrefix returns the longest common prefix of the candidates.
func commonPrefix(cands []string) string {
	if len(cands) == 0 {
		return ""
	}
	p := cands[0]
	for _, c := range cands[1:] {
		for !strings.HasPrefix(c, p) {
			p = p[:len(p)-1]
			if p == "" {
				return ""
			}
		}
	}
	return p
}

// stripSpaces trims the trailing-space hint each command candidate carries.
func stripSpaces(cands []string) []string {
	out := make([]string, len(cands))
	for i, c := range cands {
		out[i] = strings.TrimSuffix(c, " ")
	}
	return out
}

// -- word motion, the kill ring, transpose (M80l #1728) ---------------------
//
// A space is the only word separator, exactly as Ctrl-W already treated it.
// readline's shell-delimiter set (quotes, \; & | and friends) is a different
// keymap and stays out of this card.

// Kill directions. The merge rule needs to know which way a kill went: a
// backward kill prepends to the ring entry, a forward kill appends.
const (
	killNone     = 0
	killBackward = -1
	killForward  = 1
)

// wordForward is alt-f's landing index: the end of the word under the cursor,
// or -- when the cursor already sits on spaces -- the end of the next word.
// The end of the line is the floor.
func (e *Editor) wordForward(i int) int {
	j := i
	for j < len(e.Bytes()) && e.Bytes()[j] != ' ' {
		j++
	}
	if j > i {
		return j // inside a word: stop at its end
	}
	for j < len(e.Bytes()) && e.Bytes()[j] == ' ' {
		j++
	}
	for j < len(e.Bytes()) && e.Bytes()[j] != ' ' {
		j++
	}
	return j
}

// wordBackward is alt-b's landing index: the start of the word under the
// cursor, or -- on spaces -- the start of the previous word.
func (e *Editor) wordBackward(i int) int {
	j := i
	if j > 0 && e.Bytes()[j-1] == ' ' {
		for j > 0 && e.Bytes()[j-1] == ' ' {
			j--
		}
		for j > 0 && e.Bytes()[j-1] != ' ' {
			j--
		}
		return j
	}
	for j > 0 && e.Bytes()[j-1] != ' ' {
		j--
	}
	return j
}

// keyWordForward/keyWordBackward are alt-f and alt-b. At a line edge they
// write nothing at all, the same silence keyLeft and keyRight keep.
func (e *Editor) keyWordForward() ([]byte, EditEvent) {
	j := e.wordForward(e.Caret())
	if j == e.Caret() {
		return nil, EditEvent{}
	}
	e.breakKill()
	e.SetCaret(j)
	return e.paint(), EditEvent{}
}

func (e *Editor) keyWordBackward() ([]byte, EditEvent) {
	j := e.wordBackward(e.Caret())
	if j == e.Caret() {
		return nil, EditEvent{}
	}
	e.breakKill()
	e.SetCaret(j)
	return e.paint(), EditEvent{}
}

// killRegion removes buf[lo:hi], parks the text in the kill ring and leaves
// the cursor where the hole starts. A kill that continues the previous one --
// same direction, and the cursor still sitting where that kill left it --
// merges into the same ring entry instead of replacing it, which is what
// makes `Ctrl-W Ctrl-W Ctrl-Y` read "foo bar" back instead of "bar". A
// backward merge prepends (that text came earlier in the line) and a forward
// merge appends.
//
// An empty region still repaints: Ctrl-K with the cursor at the end, Ctrl-U
// at the start and Ctrl-W on a blank prefix all did before this card, and
// their bytes are part of the existing wire contract.
func (e *Editor) killRegion(lo, hi, dir int) ([]byte, EditEvent) {
	if lo < 0 {
		lo = 0
	}
	if hi > len(e.Bytes()) {
		hi = len(e.Bytes())
	}
	if lo >= hi {
		return e.paint(), EditEvent{}
	}
	killed := append([]byte(nil), e.Bytes()[lo:hi]...)
	if e.killDir == dir && e.Caret() == e.killLo {
		if dir == killBackward {
			e.kill = append(killed, e.kill...)
		} else {
			e.kill = append(e.kill, killed...)
		}
	} else {
		e.kill = killed
	}
	e.killLo, e.killHi, e.killDir = lo, hi, dir
	e.Replace(lo, hi, nil)
	e.SetCaret(lo)
	return e.paint(), EditEvent{}
}

// keyKillWordBack is Ctrl-W and Alt-Backspace: trailing spaces go first, then
// the word in front of them. Ctrl-W's byte behaviour is unchanged -- it is the
// same code as before this card, plus the ring.
func (e *Editor) keyKillWordBack() ([]byte, EditEvent) {
	j := e.Caret()
	for j > 0 && e.Bytes()[j-1] == ' ' {
		j--
	}
	for j > 0 && e.Bytes()[j-1] != ' ' {
		j--
	}
	return e.killRegion(j, e.Caret(), killBackward)
}

// keyKillWordForward is alt-d: kill to the end of the word under the cursor,
// or -- from whitespace -- through the end of the next word, so two alt-d
// presses on "foo bar" leave nothing behind.
func (e *Editor) keyKillWordForward() ([]byte, EditEvent) {
	return e.killRegion(e.Caret(), e.wordForward(e.Caret()), killForward)
}

// keyYank is Ctrl-Y: insert the last kill at the cursor. An empty ring is a
// no-op, and a yank that would pass the line cap bells like any other
// oversized insert.
func (e *Editor) keyYank() ([]byte, EditEvent) {
	if len(e.kill) == 0 {
		return nil, EditEvent{}
	}
	return e.ins(e.kill)
}

// keyTranspose is Ctrl-T: swap the two characters around the cursor. At the
// end of the line that is the last two characters; in the middle it is the
// pair the cursor sits between, and the cursor follows them right.
func (e *Editor) keyTranspose() ([]byte, EditEvent) {
	if len(e.Bytes()) < 2 {
		return nil, EditEvent{}
	}
	if e.Caret() == 0 {
		return nil, EditEvent{}
	}
	start, middle, end := 0, e.Caret(), e.Caret()
	if e.Caret() >= len(e.Bytes()) {
		end = len(e.Bytes())
		middle = previousRuneBoundary(e.Bytes(), end)
		start = previousRuneBoundary(e.Bytes(), middle)
	} else {
		start = previousRuneBoundary(e.Bytes(), middle)
		end = nextRuneBoundary(e.Bytes(), middle)
	}
	if start == middle || middle == end {
		return nil, EditEvent{}
	}
	leftLen, rightLen := middle-start, end-middle
	var pair [8]byte // two UTF-8 scalars need at most eight bytes
	copy(pair[:rightLen], e.Bytes()[middle:end])
	copy(pair[rightLen:rightLen+leftLen], e.Bytes()[start:middle])
	e.Replace(start, end, pair[:leftLen+rightLen])
	e.SetCaret(end)
	e.breakKill()
	return e.paint(), EditEvent{}
}

// clipRuneBoundary is the largest rune boundary at or before take — the
// clip a bounded insert needs (previousRuneBoundary steps a rune back,
// which is right for backspace and wrong for truncation).
func clipRuneBoundary(buf []byte, take int) int {
	if take > len(buf) {
		take = len(buf)
	}
	for take > 0 && !utf8.RuneStart(buf[take]) {
		take--
	}
	return take
}

func previousRuneBoundary(buf []byte, end int) int {
	if end <= 0 {
		return 0
	}
	if end > len(buf) {
		end = len(buf)
	}
	start := end - 1
	for start > 0 && !utf8.RuneStart(buf[start]) {
		start--
	}
	_, size := utf8.DecodeRune(buf[start:end])
	if start+size != end {
		return end - 1
	}
	return start
}

func nextRuneBoundary(buf []byte, start int) int {
	if start >= len(buf) {
		return len(buf)
	}
	_, size := utf8.DecodeRune(buf[start:])
	return start + size
}

// breakKill ends a consecutive-kill chain. The ring keeps its text, so the
// next Ctrl-Y still yanks, but the next kill starts a fresh entry. Every
// operation that is not a kill calls this.
func (e *Editor) breakKill() {
	e.killLo, e.killHi, e.killDir = 0, 0, killNone
}

// -- the completion menu (M80m #1729) ---------------------------------------

// menuCols is the width the layout aims at, defaulting when a front-end never
// called SetCols.
func (e *Editor) menuCols() int {
	if e.cols > 0 {
		return e.cols
	}
	return defaultCols
}

// menuPages is how many Tabs the current listing needs.
func (e *Editor) menuPages() int {
	rows := menuRowCount(e.menu, e.menuCols())
	pages := (rows + menuRowsPerPage - 1) / menuRowsPerPage
	if pages < 1 {
		pages = 1
	}
	return pages
}

// menuPaint renders the current page above the prompt line and repaints the
// line from a clean slate, the discipline searchPaint already uses: the
// listing is scrollback above the prompt, so the tail the next repaint
// overwrites is only the line itself.
func (e *Editor) menuPaint() []byte {
	rows := menuRows(e.menu, e.menuCols(), e.menuPage)
	e.lastLen = 0
	out := make([]byte, 0, 64)
	for _, r := range rows {
		out = append(out, '\r', '\n')
		out = append(out, r...)
	}
	out = append(out, '\r', '\n')
	return append(out, e.paint()...)
}

// menuCycle replaces the completed word with the next candidate in the
// snapshot -- readline's cycle-on-repeat-Tab. The snapshot is deliberately not
// recomputed: the menu answers one word, and any other keystroke dismisses it
// and starts a fresh completion pass.
func (e *Editor) menuCycle() ([]byte, EditEvent) {
	if len(e.menu) == 0 {
		return nil, EditEvent{}
	}
	e.menuAt = (e.menuAt + 1) % len(e.menu)
	cand := e.menu[e.menuAt]
	tail := append([]byte(nil), e.Bytes()[e.Caret():]...)
	if e.menuStart+len(cand)+len(tail) > maxLineBytes {
		return []byte{0x07}, EditEvent{} // would pass the line cap: bell, no change
	}
	e.breakKill()
	e.Replace(e.menuStart, len(e.Bytes()), append(append([]byte(nil), cand...), tail...))
	e.SetCaret(e.menuStart + len(cand))
	return e.paint(), EditEvent{}
}

// dismissMenu closes the completion menu. The line, the prompt and the kill
// ring are untouched: the listing is scrollback above the prompt line, so
// closing it is only a state change.
func (e *Editor) dismissMenu() {
	e.menu = nil
	e.menuStart = 0
	e.menuPage = 0
	e.menuAt = -1
	e.menuOn = false
}

// menuRowCount is how many rows the candidates need at this width.
func menuRowCount(cands []string, width int) int {
	n := len(cands)
	if n == 0 {
		return 0
	}
	cols := menuColumnCount(cands, width)
	return (n + cols - 1) / cols
}

// menuColumnCount is how many columns fit at this width: every entry padded to
// the widest one plus the gap, never more columns than there are candidates.
func menuColumnCount(cands []string, width int) int {
	colW := menuEntryWidth(cands)
	cols := width / colW
	if cols < 1 {
		cols = 1
	}
	if cols > len(cands) {
		cols = len(cands)
	}
	return cols
}

// menuEntryWidth is the column pitch: the widest displayed entry plus the gap.
func menuEntryWidth(cands []string) int {
	w := menuGap
	for _, c := range stripSpaces(cands) {
		if l := len(c) + menuGap; l > w {
			w = l
		}
	}
	return w
}

// menuRows lays the candidates out in columns that fit width and returns one
// page of rendered rows. The fill is column-major, the way ls does it: the
// first candidate is top-left and the listing runs downward before moving
// right, so a set of similar names stays together instead of stretching into
// one very long line. Each entry is padded to the column pitch except the last
// on its row, so the columns line up and no row ends in painted-over blanks.
func menuRows(cands []string, width, page int) []string {
	disp := stripSpaces(cands)
	n := len(disp)
	if n == 0 {
		return nil
	}
	if width < 1 {
		width = 1
	}
	colW := menuEntryWidth(cands)
	cols := width / colW
	if cols < 1 {
		cols = 1
	}
	if cols > n {
		cols = n
	}
	rows := (n + cols - 1) / cols
	pages := (rows + menuRowsPerPage - 1) / menuRowsPerPage
	if pages < 1 {
		pages = 1
	}
	if page < 0 {
		page = 0
	}
	if page >= pages {
		page = pages - 1
	}
	first := page * menuRowsPerPage
	last := first + menuRowsPerPage
	if last > rows {
		last = rows
	}
	out := make([]string, 0, last-first)
	for r := first; r < last; r++ {
		var idx []int
		for i := r; i < n; i += rows {
			idx = append(idx, i)
		}
		var b strings.Builder
		for k, i := range idx {
			b.WriteString(disp[i])
			if k < len(idx)-1 {
				b.WriteString(strings.Repeat(" ", colW-len(disp[i])))
			}
		}
		out = append(out, b.String())
	}
	return out
}
