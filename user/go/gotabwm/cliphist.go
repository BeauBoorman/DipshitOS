// GOTABWM.ELF — M190a (#3236): the seat's bounded clipboard history.
//
// The M124c typed clipboard is single-slot: a second copy destroys the
// first. The seat is the one component that sees every copy — it already
// reads slot 39 on the lane's cadence — so the history lives here: a
// ≤16-entry ring of typed clips, FIFO evict, newest at index 0. Every
// entry carries the vsys classification of its own bytes (the same rule
// ClipboardClassify applies to every writer), so a paste delivers the
// M124c negotiation the app asked for instead of a lie about the label.
//
// Observation points, all of them the seat's own seams:
//
//   - cliphistPoll diffs the kernel buffer against the ring's own
//     baseline ((len, FNV-1a), the lane's rule) wherever the seat
//     already wakes: every composite pass (chromeTick), every
//     WM_KEY/WM_POINTER dispatch, and once more inside the summon
//     action so the list the menu shows is never a tick stale. A
//     buffer that changes twice between observations records the last
//     — the lane's own once-per-tick semantics, not a byte journal.
//   - the CLIP_IN applies (hostclip.go) push directly: they set the
//     lane's seen-state themselves, so the poll's diff would never
//     report what they wrote.
//   - primary-selection publishes are excluded BY CONSTRUCTION: M124e's
//     buffer is seat memory plus SelPath staging — it never touches
//     slots 38/39, so the ring cannot observe it (sel.go's comment).
//
// The ring is memory-only: never serialized to /host, never written into
// the session envelope, gone when the seat exits.
//
// The menu is the seat's own modal chrome, the power menu's discipline:
// ctrl+shift+i (the M190a registry row) summons a list over the seat
// chrome, an input-sink window holds focus so its keys are the seat's
// alone, arrows move, Enter pastes through the existing deliver path —
// slot 38 writes the pick back (the seam every copy already takes),
// then the app's own paste chord rides the slot-65 cmd-23 content-key
// forward the routed chords already use — Esc dismisses.
package main

import (
	"bytes"
	"unicode/utf8"

	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/widgets"
)

// clipHistMax is the card's bound: the last 16 typed clips.
const clipHistMax = 16

// The markers the class-B gate greps. Payload bytes never appear — a
// marker names the mime, the length and the outcome, the hostclip.go
// never-logged discipline carried to history.
const (
	MarkerClipHist = "gotabwm: cliphist "
	MarkerClipMenu = "gotabwm: clipmenu "
)

// clipEntry is one remembered clip: the classification of its own bytes
// (never a writer's claim) and a private copy of them — the kernel buffer
// is shared, the ring's are not.
type clipEntry struct {
	mime string
	h    uint64 // fnv1a(blob) — the cheap dedupe key before the byte walk
	blob []byte
}

var (
	clipHist  [clipHistMax]clipEntry // index 0 = newest
	clipHistN int

	// The poll's own diff baseline — separate from the lane's
	// hostClipSeen/hostClipHash/hostClipLen, because arming a lane is a
	// baseline event for the lane and not for history: the ring wants
	// continuous observation from boot, not from consent.
	clipHistSeen bool
	clipHistHash uint64
	clipHistLen  int
	clipHistBuf  []byte // lazy slot-39 read buffer (clipKernelMax)
)

// cliphistPoll is the ring's observer: one slot-39 read through the
// lane's own seam, diffed against the ring baseline. It runs wherever
// the seat already wakes — the composite pass (chromeTick), the input
// path (handleWmKey/handleWmPointer) and the summon action — so a copy
// lands in the ring inside the gesture that made it. An empty buffer is
// a state, not a clip.
func cliphistPoll() {
	if clipHistBuf == nil {
		clipHistBuf = make([]byte, clipKernelMax)
	}
	n, rc := hostClipGet(clipHistBuf)
	if rc < 0 {
		return
	}
	cur := clipHistBuf[:n]
	h := fnv1a(cur)
	if clipHistSeen && h == clipHistHash && n == clipHistLen {
		return
	}
	clipHistSeen, clipHistHash, clipHistLen = true, h, n
	if n == 0 {
		return
	}
	cliphistPush(cur)
}

// cliphistNote records bytes the seat already holds — the CLIP_IN
// applies, whose own echo guard would hide them from the poll's diff.
// It syncs the poll baseline so the next cliphistPoll does not
// re-observe what it just recorded.
func cliphistNote(b []byte) {
	if len(b) == 0 {
		return
	}
	clipHistSeen = true
	clipHistHash = fnv1a(b)
	clipHistLen = len(b)
	cliphistPush(b)
}

// cliphistPush lands one observation at the head. An identical entry
// anywhere in the ring moves to the head instead of duplicating — a
// re-copy refreshes, it does not fork the history — and a genuinely new
// clip drops the oldest when the ring is full: FIFO evict, the card's
// bound.
func cliphistPush(b []byte) {
	mime := vsys.ClipboardClassify(b)
	h := fnv1a(b)
	for i := 0; i < clipHistN; i++ {
		e := clipHist[i]
		if e.h == h && len(e.blob) == len(b) && bytes.Equal(e.blob, b) {
			copy(clipHist[1:i+1], clipHist[:i])
			clipHist[0] = e
			vi.ConsoleLine(MarkerClipHist + "bump mime=" + mime +
				" len=" + vi.Itoa64(int64(len(b))) +
				" n=" + vi.Itoa64(int64(clipHistN)))
			return
		}
	}
	ent := clipEntry{mime: mime, h: h, blob: append([]byte(nil), b...)}
	copy(clipHist[1:], clipHist[:clipHistMax-1])
	clipHist[0] = ent
	if clipHistN < clipHistMax {
		clipHistN++
	}
	vi.ConsoleLine(MarkerClipHist + "push mime=" + mime +
		" len=" + vi.Itoa64(int64(len(b))) +
		" n=" + vi.Itoa64(int64(clipHistN)))
}

// --- the paste menu -----------------------------------------------------
// The summon row is chords/table.go's "clip-menu" (ctrl+shift+i); the
// geometry, sink discipline and row hit-test are the power menu's
// pattern carried to a taller panel.

const (
	clipMenuW    = 480
	clipMenuRowH = 22
	clipMenuPad  = 6
	clipMenuGap  = 8
)

// clipMenuList snapshots the ring at open: rows must not reorder under
// the selection while the menu is up — a copy that lands mid-menu joins
// the RING, not the list the user is reading. The pick still delivers
// the bytes the row showed.
var (
	clipMenuList  [clipHistMax]clipEntry
	clipMenuRows  int
	clipMenuOpen  bool
	clipMenuSel   int
	clipMenuSink  uint32
	clipMenuPrior uint32
)

// clipMenuSetTyped is the pick's buffer-write seam (vsys.ClipboardSetTyped
// in the guest): the declared mime is the ring's recorded classification
// of the same bytes — the shape check the M124c writers already pass
// keeps the delivered label honest.
var clipMenuSetTyped = vsys.ClipboardSetTyped

// clipMenuRect is the panel's rect: centered horizontally, dropped just
// under the rail — a paste list over the seat chrome. The zero rect on
// degenerate geometry.
func clipMenuRect(width, height int) (x, y, w, h int) {
	rows := clipMenuRows
	if rows < 1 {
		rows = 1
	}
	w = clipMenuW
	if w > width-2*chromeInset {
		w = width - 2*chromeInset
	}
	if w <= 0 {
		return 0, 0, 0, 0
	}
	h = 2*clipMenuPad + rows*clipMenuRowH
	x = (width - w) / 2
	y = RailHeight + clipMenuGap
	if y+h > height-chromeInset {
		y = height - chromeInset - h
	}
	if y < RailHeight {
		y = RailHeight
	}
	return
}

// clipMenuRowAt maps a point onto a list row, or -1 outside — the one
// geometry source paintClipMenu and the pointer path share.
func clipMenuRowAt(px, py uint32, width, height int) int {
	x, y, w, _ := clipMenuRect(width, height)
	if w == 0 || int(px) < x || int(px) >= x+w {
		return -1
	}
	rel := int(py) - y - clipMenuPad
	if rel < 0 {
		return -1
	}
	i := rel / clipMenuRowH
	if i < 0 || i >= clipMenuRows {
		return -1
	}
	return i
}

// --- the modal sink (the launcher/power pattern over the menu rect) ---

func acquireClipMenuFocus() bool {
	x, y, w, h := clipMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if w <= 0 {
		return false
	}
	id, r := openInputSink(uint32(x), uint32(y), uint32(w), uint32(h))
	if r < 0 {
		return false
	}
	clipMenuSink = uint32(id)
	st, qr := queryWindow(int(clipMenuSink))
	if qr < 0 || (st[5] == 0 && focusRaise(clipMenuSink) != 0) {
		_ = closeWin(clipMenuSink)
		clipMenuSink = 0
		return false
	}
	return true
}

// ensureClipMenuFocus reports whether the menu's sink still exists — the
// kernel reaps a dead window out from under the seat.
func ensureClipMenuFocus() bool {
	if clipMenuSink == 0 {
		return false
	}
	_, r := queryWindow(int(clipMenuSink))
	return r >= 0
}

// restoreClipMenuFocus hands kernel focus back to the tab that held it
// at summon — the launcher's restore rule: re-resolve against the strip
// as it is, because a tab that closed mid-menu is not a target.
func restoreClipMenuFocus() {
	id := clipMenuPrior
	clipMenuPrior = 0
	if tabs.index(id) < 0 || id >= sessionIDBase {
		var ok bool
		if id, ok = tabs.Focused(); !ok {
			return
		}
	}
	if id < sessionIDBase && focusRaise(id) == 0 {
		kernelFocusID = id
	}
}

// applyClipMenu is the registry row's action: a fresh observation first
// (the summon chord is itself an input event, so the last copy lands in
// the list this press shows), then the modal open — or the honest
// `empty` when the ring holds nothing.
func applyClipMenu() {
	cliphistPoll()
	if clipHistN == 0 {
		vi.ConsoleLine(MarkerClipMenu + "empty")
		return
	}
	if clipMenuOpen {
		return
	}
	dragAbort("chrome") // M124a: the modal menu takes the gesture
	clipMenuOpen = true
	clipMenuSel = 0
	clipMenuPrior = 0
	if id, ok := tabs.Focused(); ok && id < sessionIDBase {
		clipMenuPrior = id
	}
	copy(clipMenuList[:], clipHist[:clipHistN])
	clipMenuRows = clipHistN
	if !acquireClipMenuFocus() {
		clipMenuSink = 0
	}
	vi.ConsoleLine(MarkerClipMenu + "open n=" + vi.Itoa64(int64(clipMenuRows)))
}

func dismissClipMenu() {
	if !clipMenuOpen {
		return
	}
	if clipMenuSink != 0 {
		_ = closeWin(clipMenuSink)
		clipMenuSink = 0
	}
	clipMenuOpen = false
	restoreClipMenuFocus()
	vi.ConsoleLine(MarkerClipMenu + "dismiss")
}

// handleClipMenuKey consumes the menu's keys while it is open — Esc
// dismisses, Up/Down move the highlight, Enter is the highlighted row's
// pick. Every other key is swallowed by the sink anyway; the return
// just keeps the seat's own chords quiet.
func handleClipMenuKey(e vi.Event) bool {
	if !clipMenuOpen {
		return false
	}
	switch e.Arg0 {
	case 0x29: // Escape
		dismissClipMenu()
	case 0x52: // Up
		if clipMenuSel > 0 {
			clipMenuSel--
		}
	case 0x51: // Down
		if clipMenuSel < clipMenuRows-1 {
			clipMenuSel++
		}
	case 0x28: // Enter
		applyClipMenuPick(clipMenuSel)
	}
	return true
}

// applyClipMenuPick is the menu's Enter (and a row click): the pick
// becomes the live clipboard — written back through slot 38 with its
// recorded mime, the same seam every copy and the lane's CLIP_IN
// applies use — and the focused tab is offered its own paste chord
// through the content-key forward. An app that binds ctrl+v reads the
// pick off the kernel buffer through its own M124c negotiation; an app
// that does not simply sees the clipboard it would read on its next
// paste hold the pick — the pick is current either way.
func applyClipMenuPick(i int) {
	if i < 0 || i >= clipMenuRows {
		dismissClipMenu()
		return
	}
	e := clipMenuList[i]
	id := clipMenuPrior // resolved before dismiss clears it
	dismissClipMenu()
	vi.ConsoleLine(MarkerClipMenu + "pick i=" + vi.Itoa64(int64(i)) +
		" mime=" + e.mime + " len=" + vi.Itoa64(int64(len(e.blob))))
	n, rc := clipMenuSetTyped(e.mime, e.blob)
	if rc < 0 {
		vi.ConsoleLine(MarkerClipMenu + "paste refuse rc=" + vi.Itoa64(rc))
		return
	}
	// The pick rides the buffer forward as the head of history — a
	// cliphistNote, not a wait for the poll: the write is the seat's
	// own, so the baseline syncs here like a CLIP_IN apply.
	cliphistNote(e.blob[:n])
	if tabs.index(id) < 0 || id >= sessionIDBase {
		var ok bool
		if id, ok = tabs.Focused(); !ok {
			vi.ConsoleLine(MarkerClipMenu + "paste refuse notab")
			return
		}
	}
	if focusRaise(id) != 0 {
		vi.ConsoleLine(MarkerClipMenu + "paste refuse id=" + vi.Itoa64(int64(id)))
		return
	}
	kernelFocusID = id
	forwardContentKey(hidUsageV, vi.ModCtrl)
	vi.ConsoleLine(MarkerClipMenu + "paste id=" + vi.Itoa64(int64(id)) +
		" mime=" + e.mime + " len=" + vi.Itoa64(int64(n)))
}

// clipMenuRowText is one row's label: the recorded mime, then a preview
// — a text clip's first line, control bytes folded to spaces, fitted to
// the panel width; a non-text clip's byte count, because its bytes are
// not text the row may show.
func clipMenuRowText(i int, fitW, px int) string {
	e := clipMenuList[i]
	if i < 0 || i >= clipMenuRows {
		return ""
	}
	preview := ""
	switch e.mime {
	case vsys.ClipText, vsys.ClipCSV, vsys.ClipHTML, vsys.ClipURIList:
		preview = clipPreviewText(e.blob)
	default:
		preview = vi.Itoa64(int64(len(e.blob))) + "B"
	}
	return seatFitText(e.mime+"  "+preview, fitW, px)
}

// clipPreviewText flattens a text clip to one line: the first line's
// run with control bytes and stray non-runes folded to spaces, capped
// at the card's readable span.
func clipPreviewText(b []byte) string {
	const maxPrev = 64
	out := make([]byte, 0, maxPrev)
	for i := 0; i < len(b) && len(out) < maxPrev; {
		r, w := utf8.DecodeRune(b[i:])
		i += w
		if r == '\n' || r == '\r' {
			break
		}
		if r < 0x20 || r == utf8.RuneError && w == 1 {
			r = ' '
		}
		var tmp [4]byte
		n := utf8.EncodeRune(tmp[:], r)
		out = append(out, tmp[:n]...)
	}
	return string(out)
}

// paintClipMenu paints the open list over the seat chrome — the power
// menu's plate discipline at list height, called from chromeTick so the
// menu lands over the rail and under the toasts.
func paintClipMenu(scan []byte, width, height int) int {
	if !clipMenuOpen {
		return 0
	}
	x, y, w, h := clipMenuRect(width, height)
	if w <= 0 || len(scan)/4/width < y+h {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	seatShadow(c, plate, radiusWindow)
	n := seatPlate(c, plate, radiusWindow, tok.Accent, tok.Surface)
	draw.StrokeRoundedRect(c, plate, radiusWindow, tok.BorderW, draw.Opaque(tok.Rule))
	clip := plate.Inset(tok.BorderW)
	fitW := w - 2*clipMenuPad - 12
	for i := 0; i < clipMenuRows; i++ {
		rr := widgets.Rect{X: x, Y: y + clipMenuPad + i*clipMenuRowH, W: w, H: clipMenuRowH}
		if i == clipMenuSel {
			c.FillRect(rr.Inset(2), draw.Opaque(tok.Selection))
		}
		seatText(c, clip, x+clipMenuPad+6, rr.Y+7, seatTextPx,
			clipMenuRowText(i, fitW, seatTextPx), tok.Ink)
	}
	return n
}
