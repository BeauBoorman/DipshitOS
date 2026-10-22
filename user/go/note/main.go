// Command note is the Go successor to the Zig notepad: M66c (issue #1445), and
// as of #1485 the ONLY text-app client — the Zig binary and user/src/notepad.zig
// are deleted. A small notepad — open, edit, save — full-viewport inside the
// tabbed desktop through user/go/tabapp, over the M66a-hardened file surface.
// The card's shape is M62h (#1406, CALC.BIN -> GOCALC.ELF) applied to the other
// leftover binary.
//
// It is deliberately NOT an editor: no find/replace, no selection, no undo.
// GOEDIT.ELF owns that arms race. What this app must have is the three things
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
	"unicode/utf8"

	"virelai/draw"
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
	markerResize      = "note: resize relayout"
	markerClose       = "note: win_close"
	markerPresents    = "note: presents n="
	markerOK          = "note OK"
	markerOpenErr     = "note: error open "
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
)

// app is the whole state: the window, the buffer, the scroll top and the dirty
// bit (which the chrome bar shows and the close path acts on).
type app struct {
	ta    *tabapp.TabApp
	buf   *Buffer
	path  string
	top   int
	dirty bool

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
// after importing virelai/theme (remainder 2160 observed). Same wall as
// GOEDIT's header: a remainder above 1792 makes sbrk's first mmap collide
// and mallocinit die.
var argvHeadroom [2192]byte

func init() { argvHeadroom[0] = 0 }

func main() {
	loadGuestTheme()
	a := &app{buf: NewBuffer(), path: defaultPath, top: 1}
	ta := tabapp.Init(tabapp.Config{Name: appName, Title: appTitle, X: natX, Y: natY, W: natW, H: natH})
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
			vi.ConsoleLine(markerResize)
		case tabapp.ActionNone:
			// Dirty is set by key() itself, on the mutating arms only: the
			// loop cannot distinguish a save (frame change, not an edit)
			// from typing, and setting it here re-dirtied the buffer on
			// Ctrl-S and dirtied it on a plain arrow press.
			if a.key(ev) {
				a.top = a.buf.Follow(a.top, a.rowsIn())
				a.draw()
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
	rows := (h - chromeH - statusH) / lineH
	if rows < 1 {
		return 1
	}
	return rows
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
	if isSave(ev) {
		vi.ConsoleLine(a.save())
		vi.ConsoleLine(a.cursorMarker())
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
		"  bytes " + vi.Itoa64(int64(a.buf.Len())) + "/" + vi.Itoa64(int64(MaxBytes))
	a.drawText(textOrigin, h-statusH, status, tok.Muted)
	// Present puts the frame on the scanout — and flushes the degradation
	// path's pending fills first, so the batcher semantics are unchanged. Without it the app fills its own
	// back-buffer and NOTHING reaches the compositor -- and the serial looks
	// identical, which is why the count below exists. GOEDIT presents after
	// every draw for the same reason. Every draw path ends here, so each frame
	// is presented exactly once.
	a.ta.Present()
	a.presents++
}
