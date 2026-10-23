// Command note is the Go successor to the Zig notepad: M66c (issue #1445), and
// as of #1485 the ONLY text-app client — the Zig binary and user/src/notepad.zig
// are deleted. A small notepad — open, edit, save — full-viewport inside the
// tabbed desktop through user/go/tabapp, over the M66a-hardened file surface.
// The card's shape is M62h (#1406, CALC.BIN -> GOCALC.ELF) applied to the other
// leftover binary.
//
// It is deliberately NOT an editor: no replace, no selection, no undo —
// GOEDIT.ELF owns that arms race. Ctrl-F find is the exception: M191c
// (#3244) docks the shared appkit overlay, the same bar GOREADER migrates
// to, so every text app keeps one find muscle memory. What this app must
// have is the three things
// the seat gates assert of a hosted tab — it declares itself tab-aware, it
// relayouts on WIN_RESIZE, and it closes cleanly on WIN_CLOSE — plus load/save.
// The marker names mirror the Zig app's whole lifecycle vocabulary (`note:
// ready`, `note: tab-aware (full-viewport)`, `note: settled`, `note: exiting`,
// `note: win_close`, `note: resize relayout`), because the seat specs that
// assert them today move to this app by prefix alone. See the marker block
// below for the two places the vocabularies deliberately differ.
//
// Two deliberate behaviour choices, both recorded here because a retarget has
// to reconcile them with the Zig app's coverage:
//
//   - The file is loaded at STARTUP and saved with Ctrl-S (and automatically on
//     WIN_CLOSE when the buffer is dirty, so closing a tab does not silently
//     drop what was typed). The Zig notepad drove load/save from buttons;
//     buttons are not part of this card, and auto-save-on-close is the version
//     that cannot lose an edit by forgetting to save.
//     What that does NOT buy, because the wording matters: vi.WriteFileSafe
//     publishes delete-then-rename, so a crash inside that window leaves
//     notes.txt ABSENT rather than half-written, and the next boot opens an
//     empty notepad. "Never half-written" is the guarantee here; "cannot lose
//     data" would be an overstatement.
//   - Long lines are CLIPPED at the right edge rather than wrapped (see
//     Buffer.View). Wrapping would make one logical line two rows, and the
//     caret's row a function of the canvas width.
//
// The event wire carries a Unicode codepoint in arg1 (ADR 0014). The 8x8 face
// falls back to '?' for unsupported glyphs, but the buffer and saved file keep
// the codepoint's complete UTF-8 encoding.
//
// Every marker below is printed only AFTER its syscall returned, so a gate
// asserting them can only pass if the app actually ran.
package main

import (
	"bytes"
	"unicode/utf8"

	"virelai/appkit"
	"virelai/draw"
	"virelai/find"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/webrender/font"
	"virelai/widgets"
)

const (
	appName = "NOTE.ELF"
	// appTitle is the identity NOTE declares. The seat maps it to
	// NOTE.ELF for reopen; once the startup file is known, M79d sends the
	// document name as a separate set-title RPC without changing that bin.
	appTitle = "Notepad"
	natW     = 512
	natH     = 384
	// natX/natY are the Zig app's declared window ORIGIN too
	// (user/src/notepad.zig `window_x = 56`, `window_y = 56`). The desktop host
	// honours the requested origin, so the fleet's rect assertions
	// (`user user rect=56,56,512,384` in live-desktop-typing, live-wnd5-geometry
	// and live-wnd8-ptr-drag-delete) and the screenshot text-region check keep
	// describing the app instead of being re-derived. Every other Go app opens at
	// 32,32; the notepad keeps its predecessor's origin deliberately, the same
	// way it keeps the predecessor's native size and title.
	natX = 56
	natY = 56

	// defaultPath is where the Zig notepad kept its text
	// (user/src/notepad.zig `notes_path`), kept identical so the seat specs'
	// existing share seeding still points at the same file.
	defaultPath = "/host/notes.txt"

	// readMax is one byte OVER the buffer bound: a file that does not fit is
	// then reported as truncated (Buffer.Load returns MaxBytes) instead of
	// silently losing its tail.
	readMax = MaxBytes + 1
)

// Marker vocabulary. Each one is printed only after the call that earns it, and
// the LIFECYCLE names mirror the Zig notepad's (`notepad: ready`, `notepad:
// tab-aware (full-viewport)`, `notepad: settled`, `notepad: exiting 43`,
// `notepad: win_close`, `notepad: resize relayout`). That shared vocabulary is
// the point of the M66c retarget: the seat specs that assert them today move to
// this app by PREFIX ALONE, so ~30 spec edits stay mechanical instead of
// becoming a rewrite of what they assert.
//
// Two deliberate divergences, both stated where a reviewer would look for them:
//   - the exit status is this app's own (0), not the Zig app's hardcoded 43.
//   - `note: open id=` carries the real window id; the Zig app printed a fixed
//     one.
const (
	markerOpen        = "note: open id="
	markerTabAware    = "note: tab-aware (full-viewport)"
	markerNotTabAware = "note: not-tab-aware (shim or WND desktop)"
	markerTabTitle    = "note: tab title "
	markerDogfood     = "dogfood: note" // M69a (#1528): go-dogfood.spec's marker
	markerReady       = "note: ready"
	markerSettled     = "note: settled"
	markerExiting     = "note: exiting "
	markerLoaded      = "note: loaded ok n="
	markerMiss        = "note: load miss "
	markerLoadErr     = "note: load error "
	markerSaved       = "note: saved ok n="
	markerSaveErr     = "note: save error "
	markerCursor      = "note: cursor line="
	markerFindBar     = "note: find bar"
	markerFind        = "note: find '"
	markerFindMiss    = "note: find miss '"
	markerResize      = "note: resize relayout"
	markerClose       = "note: win_close"
	markerPresents    = "note: presents n="
	markerOK          = "note OK"
	markerOpenErr     = "note: error open "
	// markerState prefixes the M125a envelope report: "restored cur=" /
	// "stale <why>" — same vocabulary GOEDIT and GOPAINT print for theirs.
	markerState = "note: state "
)

// settleNs is how long the app lets the compositor run before it declares
// itself settled, mirroring the Zig app's sleep_ticks(2) at the same point.
// M170c: a named duration on the deadline overlay (vi.SleepNs) instead of a
// ~2-tick guess.
const (
	ms = 1_000_000

	settleNs = 250 * ms
)

// Frame geometry and the palette, both matching GOEDIT's frame so the two text
// apps look like the same desktop.
const (
	chromeH    = 24
	lineH      = 10
	textOrigin = 6
	caretW     = 2
	statusH    = 12
	findH      = 14 // the appkit find overlay's strip height
)

// Key codes. ADR 0009 row 1: arg0 is the HID usage / keycode and arg1 is the
// decoded symbol, so the arrows are read from arg0 (as user/src/notepad.zig
// reads them) and printable input from arg1 (as GOEDIT does).
const (
	modCtrl = uint16(0x0002)

	hidRight = 0x4f
	hidLeft  = 0x50
	hidDown  = 0x51
	hidUp    = 0x52

	codeBackspace = 0x08
	codeDelete    = 0x7f
	codeReturn    = 0x0d
	codeNewline   = 0x0a

	// keyS is the lowercase 's' codepoint and keyCtrlS the Ctrl chord's, the
	// same pair GOEDIT's save path documents.
	keyS     = 0x73
	keyCtrlS = 0x13

	// The Ctrl-F find chord's three spellings — GOEDIT accepts the same set
	// because the kernel can deliver any of them.
	keyF     = 0x66
	keyCtrlF = 0x06
	hidF     = 0x09
)

// app is the whole state: the window, the buffer, the scroll top and the dirty
// bit (which the chrome bar shows and the close path acts on). pend/pendBad
// hold the seat's restored envelope between Init (where noteState runs, before
// the buffer's file is read) and applyRestored (which applies it after load).
type app struct {
	ta    *tabapp.TabApp
	buf   *Buffer
	path  string
	top   int
	dirty bool

	// The find overlay (M191c #3244): Ctrl-F docks the shared appkit bar at
	// the bottom, its Scan walks the buffer through virelai/find and Show
	// lands the caret on the hit the overlay picks. hits is the ordinal
	// list the overlay indexes into. findLog is the one deferred marker —
	// the overlay's Show/Miss fire inside key handling, before the frame
	// they describe is painted, so the marker waits for the draw.
	find    appkit.Find
	hits    []int
	findLog string
	pend    *noteState
	pendBad bool

	// presents counts the frames this app has put on the scanout. Draw and
	// present are separate calls, so the only way a gate can tell a filled frame
	// that was never presented (which looks identical in the serial) from a
	// painted one is a number the app reports itself.
	presents int
}

func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

// argvHeadroom wraps this image's writable memsz%4096 back into (0, 1792]
// after importing appkit for the find overlay (remainder 2992 observed).
// Same wall as GOEDIT's header: a remainder above 1792 makes sbrk's first
// mmap collide and mallocinit die.
var argvHeadroom [3808]byte

func init() { argvHeadroom[0] = 0 }

func main() {
	loadGuestTheme()
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	a.find = appkit.NewFind()
	a.find.Scan = a.findScan
	a.find.Show = a.findShow
	a.find.Miss = a.findMiss
	// The M125a hooks: noteState runs inside Init (a re-exec'd NOTE gets no
	// argv — the blob's path must land before load() reads it), and the
	// loop answers the seat's save asks through PollStateAsk.
	ta := tabapp.Init(tabapp.Config{
		Name:         appName,
		Title:        appTitle,
		X:            natX,
		Y:            natY,
		W:            natW,
		H:            natH,
		StateVersion: stateAppVer,
		SaveState:    a.saveState,
		RestoreState: a.noteState,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpenErr + "-1")
		vi.Exit(1)
	}
	a.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerTabAware)
		// M69a (#1528): printed only on the accepted-declare path -- the
		// editor is HOSTED by a WM seat, not merely running.
		vi.ConsoleLine(markerDogfood)
	} else {
		// The WM refused the declaration (the shim / WND.BIN path): the app
		// keeps its native presentation, which is the documented no-regression
		// case, not a failure.
		vi.ConsoleLine(markerNotTabAware)
	}

	vi.ConsoleLine(a.load())
	// A stored envelope decides over the startup defaults: the blob's path
	// already replaced a.path inside noteState, so the load just performed
	// IS the staleness witness; cursor and dirty apply here.
	if line := a.applyRestored(); line != "" {
		vi.ConsoleLine(line)
	}
	// NOTE owns one startup document. Once the open attempt has returned,
	// name the rail for that document; the initial Notepad declaration still
	// supplied NOTE.ELF to the seat's reopen/session bin field.
	if title := tabTitleForPath(a.path); ta.SetTabTitle(title) {
		vi.ConsoleLine(markerTabTitle + title)
	}
	a.top = a.buf.Follow(a.top, a.rowsIn())
	a.draw()
	// ready means the first frame is BUILT AND PRESENTED, which is why it comes
	// after draw() and not before: the seat specs release injected input here.
	vi.ConsoleLine(markerReady)
	// settled means the compositor has had a chance to pick that frame up, which
	// is what the snapshot gates wait on.
	vi.SleepNs(settleNs)
	vi.ConsoleLine(markerSettled)
	vi.ConsoleLine(a.cursorMarker())

	for {
		// The seat's save ask (snapshot, tab close) is a notice in the
		// mailbox nothing wakes; answering it is once per pass, the same
		// discipline PollDrag/PollSelPaste keep.
		a.ta.PollStateAsk()
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				// Kernel refusal: nothing to wait for, so stop spinning.
				break
			}
			vi.Sleep(1)
			continue
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerClose)
			// Dirty text is saved on the way out: a closed tab must not be a
			// lost edit. The decision is a call so the host can assert it --
			// the close itself exits the process, which is why the live run
			// can only ever observe the clean case.
			if line := a.closeSave(); line != "" {
				vi.ConsoleLine(line)
			}
			// One line, not one per frame: the seat spec pairs this count with
			// its own relayout count, which is the check that catches a draw
			// path that fills a batch and forgets to present it.
			vi.ConsoleLine(markerPresents + vi.Itoa64(int64(a.presents)))
			vi.ConsoleLine(markerOK)
			// The seat specs wait on the exit marker before they read the kernel
			// registry, so it has to be the LAST thing printed.
			vi.ConsoleLine(markerExiting + vi.Itoa64(0))
			a.ta.CloseAndExit(0)
		case tabapp.ActionResized:
			a.top = a.buf.Follow(a.top, a.rowsIn())
			a.draw()
			a.flushFindLog()
			vi.ConsoleLine(markerResize)
		case tabapp.ActionNone:
			// Dirty is set by key() itself, on the mutating arms only: the
			// loop cannot distinguish a save (frame change, not an edit)
			// from typing, and setting it here re-dirtied the buffer on
			// Ctrl-S and dirtied it on a plain arrow press.
			if a.key(ev) {
				a.top = a.buf.Follow(a.top, a.rowsIn())
				a.draw()
				a.flushFindLog()
			}
		}
	}
}

// load reads the path into the buffer and returns the marker to print. The
// callers print it; keeping the decision here is what makes the three outcomes
// (read, absent, refused) host-testable, because the host file channel answers
// -ENOSYS and nothing panics.
func (a *app) load() string {
	data, rc := vi.ReadFileAll(a.path, readMax)
	return a.loadMarker(data, rc)
}

// tabTitleForPath is the final path component. NOTE currently opens one fixed
// file, but keeping the conversion local means a later open/save-as path uses
// the same title rule instead of inventing another format.
func tabTitleForPath(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[i+1:]
		}
	}
	return path
}

// loadMarker is the decision load() makes from what the file channel returned,
// split out because the channel is the one part of this path the host cannot
// drive: the host answers -ENOSYS to every read, so the absent-file outcome and
// the over-bound outcome were unreachable from a test while the decision was
// inlined. Order matters (a negative rc is a refusal even when it carries
// bytes) and so does the bound: truncation needs the buffer filled EXACTLY at
// MaxBytes and MORE handed over, which readMax = MaxBytes+1 is what makes
// observable at all.
func (a *app) loadMarker(data []byte, rc int64) string {
	if rc < 0 {
		// A missing file is the ordinary first-run case, not an error: an
		// empty notepad is a working notepad. Anything else is reported.
		if rc == -int64(vi.ErrENOENT) {
			return markerMiss + a.path
		}
		return markerLoadErr + vi.Itoa64(rc) + " " + a.path
	}
	n := a.buf.Load(data)
	if n == MaxBytes && len(data) > MaxBytes {
		// The file did not fit: say so with the bound, rather than presenting a
		// truncated document as the whole one.
		return markerLoaded + vi.Itoa64(int64(n)) + " truncated at " + vi.Itoa64(int64(MaxBytes))
	}
	return markerLoaded + vi.Itoa64(int64(n))
}

// closeSave is the save-on-close decision, split out so the host can assert it:
// the process exits from inside the close path (CloseAndExit), so a test that
// drives the loop has no way to observe what the close did. It returns the
// marker to print, or "" when the buffer is clean and the file must be left
// untouched.
func (a *app) closeSave() string {
	if !a.dirty {
		return ""
	}
	return a.save()
}

// save writes the buffer and returns the marker to print. It is the one place
// the app writes, so the read-only/no-write story for /host is a single call.
//
// M66b (#1444) landed vi.WriteFileSafe (temp + fsync + rename, no in-place
// truncation of the live path) while this app was being written, which is the
// swap the first version of this function pre-committed to: the notepad now
// publishes crash-safe, so a power loss during a Ctrl-S -- or during the
// automatic save on WIN_CLOSE -- cannot leave a half-written notes.txt. A
// short write is impossible by construction, because WriteFileSafe fails
// closed (removes its temp, reports the failing step's rc) instead of
// partially writing, so the marker's byte count is the length of the body that
// was published and there is no longer a partial-write branch to report.
func (a *app) save() string {
	data := a.buf.Bytes()
	if rc := vi.WriteFileSafe(a.path, data); rc < 0 {
		return markerSaveErr + vi.Itoa64(rc) + " " + a.path
	}
	a.dirty = false
	return markerSaved + vi.Itoa64(int64(len(data)))
}

// cursorMarker reports where the caret is. It is printed once at startup and
// after a save, so a run can assert the editing state without a marker per
// keystroke flooding the serial.
func (a *app) cursorMarker() string {
	return markerCursor + vi.Itoa64(int64(a.buf.Line())) + " col=" + vi.Itoa64(int64(a.buf.Col())) +
		" n=" + vi.Itoa64(int64(a.buf.Len()))
}

// ---------------------------------------------------------------------------
// Find — the appkit overlay's corpus seam (M191c #3244)
// ---------------------------------------------------------------------------

// findScan counts the buffer's hits for the overlay's pattern through the
// shared matcher. The overlay calls it on every pattern edit and before
// every step, so hits always describes the live buffer.
func (a *app) findScan(pat string) int {
	a.hits = find.All(a.buf.Bytes(), []byte(pat))
	return len(a.hits)
}

// findShow lands the caret on hit i — the overlay picked the ordinal, the
// draw scrolls it into view through the usual Follow. The marker waits on
// findLog so it prints after the frame that shows the hit.
func (a *app) findShow(i int) {
	a.buf.SetCursor(a.hits[i])
	a.findLog = markerFind + a.find.Pattern() + "' hit=" +
		vi.Itoa64(int64(i+1)) + "/" + vi.Itoa64(int64(len(a.hits)))
}

// findMiss reports a step against a pattern with no hits.
func (a *app) findMiss() {
	a.findLog = markerFindMiss + a.find.Pattern() + "'"
}

// flushFindLog prints the deferred find marker once the frame it describes
// is on the scanout — the same announce-after-paint rule GOREADER's
// pendingLog keeps.
func (a *app) flushFindLog() {
	if a.findLog != "" {
		vi.ConsoleLine(a.findLog)
		a.findLog = ""
	}
}

// --- the M125a state envelope (M192b #3247) ---------------------------------
//
// NOTE's half of the per-app state protocol, the same shape GOEDIT's
// state.go and GOPAINT's keep: the seat stores the blob verbatim on the
// tab's session row (kind-20 save, kind-21 restore) and hands it back on a
// reopen — a re-exec'd NOTE.ELF gets no argv, so the open file lives only
// here. The format is the app's own; stateFmtVer is the refusal check for
// a stale serialization and stateAppVer the seat-stored twin — a torn or
// foreign blob decodes to nothing and the restore degrades to the plain
// open of defaultPath, never a crash.
//
// Wire v1 (little-endian):
//
//	u8  fmtVer (=1)
//	u8  flags (bit 0: dirty)
//	u32 cur                the caret's byte offset
//	u16 pathLen | path     the open file
//	u32 bufLen | buf       ONLY when dirty — the unsaved text itself
//
// Carrying the unsaved text is what makes the dirty flag honest: the blob
// bound (64 KiB) is twice the buffer bound (32 KiB), so the whole document
// always fits and a session restore does not drop typed work the way
// GOPAINT's envelope drops pixels. On apply, the snapshot text is compared
// against what load() just read: equal means the close-time save already
// published it (the flag goes back clean), different means the snapshot
// caught unsaved work and the buffer takes the blob's bytes back dirty.

const (
	stateFmtVer = 1
	stateAppVer = 1

	flagDirty = 1 << 0
)

// noteState is the decoded blob.
type noteState struct {
	cur   int
	path  string
	dirty bool
	buf   []byte // the unsaved text; present iff dirty
}

func appendU16(out []byte, v int) []byte { return append(out, byte(v), byte(v>>8)) }

func appendU32(out []byte, v int) []byte {
	return append(out, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

func readU16(b []byte) int { return int(b[0]) | int(b[1])<<8 }

func readU32(b []byte) int {
	return int(b[0]) | int(b[1])<<8 | int(b[2])<<16 | int(b[3])<<24
}

// encode renders the blob. Writers are infallible; the seat's own bound
// check (EncodeAppState) runs on the finished length.
func (s *noteState) encode() []byte {
	out := make([]byte, 0, 12+len(s.path)+len(s.buf))
	flags := byte(0)
	if s.dirty {
		flags |= flagDirty
	}
	out = append(out, stateFmtVer, flags)
	out = appendU32(out, max(0, s.cur))
	out = appendU16(out, len(s.path))
	out = append(out, s.path...)
	if s.dirty {
		out = appendU32(out, len(s.buf))
		out = append(out, s.buf...)
	}
	return out
}

// decodeState parses a blob; ok=false means stale/foreign and the caller
// degrades to a plain open. Every declared length is re-verified and the
// blob must be consumed exactly — the seat carries bytes, it does not
// vouch for them.
func decodeState(b []byte) (noteState, bool) {
	var s noteState
	if len(b) < 8 || b[0] != stateFmtVer {
		return s, false
	}
	if b[1]&^flagDirty != 0 {
		return s, false
	}
	s.dirty = b[1]&flagDirty != 0
	s.cur = readU32(b[2:6])
	pl := readU16(b[6:8])
	if len(b) < 8+pl {
		return s, false
	}
	s.path = string(b[8 : 8+pl])
	rest := b[8+pl:]
	if !s.dirty {
		return s, len(rest) == 0
	}
	if len(rest) < 4 {
		return s, false
	}
	n := readU32(rest[:4])
	if len(rest) != 4+n {
		return s, false
	}
	s.buf = rest[4:]
	return s, true
}

// saveState is the tabapp.SaveState hook — the seat's ask (snapshot or tab
// close) lands once per loop pass and gets this blob staged.
func (a *app) saveState() []byte {
	st := noteState{cur: a.buf.Cursor(), path: a.path, dirty: a.dirty}
	if a.dirty {
		st.buf = a.buf.Bytes()
	}
	return st.encode()
}

// noteState is the tabapp.RestoreState hook, run inside Init before the
// first paint. It only decodes and stashes: the path applies immediately so
// the load() below opens the blob's file, the rest waits in pend for the
// buffer's staleness witness.
func (a *app) noteState(b []byte) {
	s, ok := decodeState(b)
	if !ok {
		a.pendBad = true
		return
	}
	a.pend = &s
	if s.path != "" {
		a.path = s.path
	}
}

// applyRestored runs right after load(): the file just read is the blob's
// staleness witness. A dirty snapshot whose text the close-time save already
// published restores clean; one the disk does not have takes the blob's
// bytes back as the dirty buffer. The caret clamps into range either way.
// It returns the marker to print ("" when no blob was waiting) — the same
// convention load/save/closeSave keep, so the decision stays host-testable.
func (a *app) applyRestored() string {
	if a.pendBad {
		a.pendBad = false
		return markerState + "stale bad"
	}
	st := a.pend
	if st == nil {
		return ""
	}
	a.pend = nil
	// The envelope's appver is the seat-visible tag; RestoredVersion is the
	// app's check for a stale serialization — a foreign version is refused
	// even though the blob itself decoded.
	if a.ta != nil && a.ta.RestoredVersion != stateAppVer {
		return markerState + "stale version"
	}
	tag := ""
	if st.dirty && !bytes.Equal(st.buf, a.buf.Bytes()) {
		a.buf.Load(st.buf)
		a.dirty = true
		tag = " dirty"
	}
	a.buf.SetCursor(st.cur)
	a.top = a.buf.Follow(a.top, a.rowsIn())
	return markerState + "restored cur=" + vi.Itoa64(int64(a.buf.Cursor())) +
		" path=" + a.path + tag
}

// rowsIn is how many text rows the canvas holds at the current size. A canvas
// too small for even one row still reports one, so a resize cannot make the
// view model empty and the caret disappear.
func (a *app) rowsIn() int {
	if a.ta == nil {
		return 1
	}
	h := int(a.ta.H)
	if h <= 0 {
		h = natH
	}
	rows := (h - chromeH - statusH - a.bottomChrome()) / lineH
	if rows < 1 {
		return 1
	}
	return rows
}

// bottomChrome is how much the open find bar lifts the status line.
func (a *app) bottomChrome() int {
	if a.find.Open {
		return findH
	}
	return 0
}

// colsIn is how many columns fit on a row at the current width.
func (a *app) colsIn() int {
	w := natW
	if a.ta != nil && int(a.ta.W) > 0 {
		w = int(a.ta.W)
	}
	cols := (w - 2*textOrigin) / font.Advance(1)
	if cols < 1 {
		return 1
	}
	return cols
}

// key feeds one event to the buffer and reports whether the frame changed. A
// frame change is NOT the same as a dirty buffer: Ctrl-S repaints the chrome
// (the `*` goes away) without editing anything, and the arrows move the caret
// without editing anything. So the dirty bit is set here, by the mutating arms
// alone -- see edit().
//
// Ctrl-S saves; printable symbols insert; Return breaks the line; backspace and
// delete remove; the arrows move the caret. Tab inserts nothing (insertionFor
// rejects it, because the WM owns that chord) despite reading like a text key.
// Every other chord belongs to the WM and is left alone.
func (a *app) key(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	if a.find.Open {
		// The bar owns the keyboard while it is up — Escape dismisses,
		// Enter steps, the rest is the pattern field; a key the overlay
		// does not take is swallowed, not typed into the document.
		k, ok := appkit.NormalizeKey(ev)
		if !ok {
			return false
		}
		return a.find.OnKey(k)
	}
	if isSave(ev) {
		vi.ConsoleLine(a.save())
		vi.ConsoleLine(a.cursorMarker())
		return true
	}
	if isFind(ev) {
		a.find.Present()
		a.findLog = markerFindBar
		return true
	}
	if ev.Flags&modCtrl != 0 {
		return false
	}
	switch ev.Arg0 {
	case hidLeft:
		return a.buf.Left()
	case hidRight:
		return a.buf.Right()
	case hidUp:
		return a.buf.Up()
	case hidDown:
		return a.buf.Down()
	}
	if ev.Arg1 == codeBackspace {
		return a.edit(a.buf.Backspace())
	}
	if ev.Arg1 == codeDelete {
		return a.edit(a.buf.Delete())
	}
	if ch, ok := insertionFor(ev); ok {
		return a.edit(a.buf.InsertRune(ch))
	}
	return false
}

// edit records a buffer mutation: the frame changed and the buffer is now
// dirty, which is what the chrome's `*` shows and what the close path acts on.
// Movement deliberately does not come through here, and neither does save.
func (a *app) edit(changed bool) bool {
	if changed {
		a.dirty = true
	}
	return changed
}

// isSave reports whether the event is the Ctrl-S chord. Both spellings of 's'
// are accepted: the kernel puts the decoded symbol in arg1, and a chord can
// arrive as either the control code or the letter depending on the path that
// produced it (GOEDIT accepts both for the same reason).
func isSave(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl == 0 {
		return false
	}
	return ev.Arg1 == keyCtrlS || ev.Arg1 == keyS
}

// isFind reports whether the event is the Ctrl-F chord — the same three
// spellings isSave accepts ('f', the 0x06 control code, the 0x09 usage).
func isFind(ev vi.Event) bool {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl == 0 {
		return false
	}
	return ev.Arg1 == keyF || ev.Arg1 == keyCtrlF || ev.Arg0 == hidF
}

// insertionFor maps a key event to the Unicode scalar it inserts. The kernel
// puts the decoded codepoint in arg1 (ADR 0014); Return/Newline become '\n'.
func insertionFor(ev vi.Event) (rune, bool) {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl != 0 {
		return 0, false
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		return '\n', true
	}
	if (ev.Arg1 >= 0x20 && ev.Arg1 < 0x7f || ev.Arg1 >= 0xa0) &&
		ev.Arg1 <= utf8.MaxRune &&
		(ev.Arg1 < 0xd800 || ev.Arg1 > 0xdfff) {
		return rune(ev.Arg1), true
	}
	return 0, false
}

// fillCanvas adapts the app's own fill to widgets.RectCanvas — the find
// overlay's whole paint contract.
type fillCanvas struct{ a *app }

func (c *fillCanvas) FillRect(r widgets.Rect, rgb uint32) { c.a.fill(r.X, r.Y, r.W, r.H, rgb) }

// fill is one clamped rectangle through the bound window canvas (or the
// FillerCanvas degradation path — tabapp.Canvas picks). draw.Opaque mirrors
// the kernel fill's byte contract on the raster path: the compositor reads
// B8G8R8X8, so the client fill the specs pixel-pin keeps tok.Bg's exact
// bytes (0x182026 since M69c moved NOTE onto the token table).
func (a *app) fill(x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 || x < 0 || y < 0 || a.ta == nil {
		return
	}
	a.ta.Canvas().FillRect(widgets.Rect{X: x, Y: y, W: w, H: h}, draw.Opaque(rgb))
}

// drawText paints text with the VirelaiOS 8x8 face (virelai/webrender/font),
// coalescing each row's lit run into one fill. Local on purpose: the full
// webrender package drags in layout and HTML parsing, and GOEDIT's header
// records what that costs — the Go runtime's init then exceeds the kernel's
// 16-region sbrk budget ("runtime: cannot allocate memory" in mallocinit).
func (a *app) drawText(x, y int, text string, rgb uint32) {
	cx := x
	for _, ch := range text {
		g := font.Glyph8(ch)
		for row := 0; row < 8; row++ {
			bits := g[row]
			col := 0
			for col < 8 {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				a.fill(cx+col, y+row, run, 1, rgb)
				col += run
			}
		}
		cx += font.Advance(1)
	}
}

// draw repaints the frame: chrome bar, the visible text rows, the caret, and a
// status line. One flush at the end — the batcher is the only paint path.
func (a *app) draw() {
	if a.ta == nil {
		return
	}
	w, h := int(a.ta.W), int(a.ta.H)
	if w <= 0 || h <= 0 {
		w, h = natW, natH
	}
	tok := theme.Current
	a.fill(0, 0, w, chromeH, tok.Surface)
	a.fill(0, chromeH, w, h-chromeH, tok.Bg)

	title := appTitle + "  " + a.path
	if a.dirty {
		title += " *"
	}
	a.drawText(textOrigin, 8, title, tok.Ink)

	rows := a.rowsIn()
	a.top = a.buf.Follow(a.top, rows)
	cols := a.colsIn()
	y := chromeH + 4
	for _, row := range a.buf.View(a.top, rows, cols) {
		a.drawText(textOrigin, y, row.Text, tok.Ink)
		if row.Col >= 0 {
			// The caret, drawn after the glyphs so it is never painted over.
			// A caret past the clip sits on the edge: the clip is the view's
			// right boundary, and hiding the caret there would be worse than
			// showing it at the margin.
			col := row.Col
			if col > cols {
				col = cols
			}
			a.fill(textOrigin+col*font.Advance(1), y, caretW, 8, tok.Caret)
		}
		y += lineH
	}

	status := "line " + vi.Itoa64(int64(a.buf.Line())) + ":" + vi.Itoa64(int64(a.buf.Col())) +
		"  words " + vi.Itoa64(int64(a.buf.Words())) +
		"  bytes " + vi.Itoa64(int64(a.buf.Len())) + "/" + vi.Itoa64(int64(MaxBytes))
	a.drawText(textOrigin, h-statusH-a.bottomChrome(), status, tok.Muted)
	if a.find.Open {
		a.find.R = widgets.Rect{Y: h - findH, W: w, H: findH}
		a.find.Draw(&fillCanvas{a: a})
	}
	// Present puts the frame on the scanout — and flushes the degradation
	// path's pending fills first, so the batcher semantics are unchanged. Without it the app fills its own
	// back-buffer and NOTHING reaches the compositor -- and the serial looks
	// identical, which is why the count below exists. GOEDIT presents after
	// every draw for the same reason. Every draw path ends here, so each frame
	// is presented exactly once.
	a.ta.Present()
	a.presents++
}
