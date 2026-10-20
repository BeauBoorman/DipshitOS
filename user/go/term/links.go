// M149b (issue #2807): OSC-8 hyperlinks in GOTERM.
//
// The kernel terminal emulator consumes every OSC string whole — "consumed,
// never painted" (kernel/src/terminal.zig dispatchOsc) — so `ESC ] 8 ; params
// ; URI ST` vanishes before the grid sees it and no kernel-side link map
// exists to hit-test. GOTERM therefore owns the whole feature inside its own
// write/read seams:
//
//	linkTracker.filter rides the tty write path (writeTTY): it parses each
//	OSC-8 string, mirrors the kernel's screen model for just enough state to
//	know which CELLS carry a link (grid rows + the history ring, cursor,
//	scroll regions, autowrap, the alternate screen), and injects `ESC[4m` /
//	`ESC[24m` around the link text so the kernel paints it underlined.
//
//	mouseFilter rides the tty read path: GOTERM enables xterm mouse
//	reporting (`CSI ?1000h` + `CSI ?1006h`) at session start, and the kernel
//	then delivers SGR reports `ESC [ < b ; x ; y M|m` as tty input bytes
//	(M73i #1635). Those bytes are NOT editor input — the filter extracts
//	them before the shlib editor can mangle them, and a press+release on the
//	same cell is the open gesture.
//
// Honest limits, stated rather than hidden:
//   - The kernel's report carries no modifier bits (encodeMouse packs only
//     the button), and a tty-bound window sees no app key events for bare
//     modifiers — "ctrl+click" is not distinguishable from click through
//     this ABI. The open gesture is therefore a plain left press+release on
//     a link cell; Shift keeps the kernel's local text selection, exactly
//     like xterm with mouse reporting on.
//   - The mirror cannot observe the kernel's scrollback VIEW offset (chrome
//     chords move it without touching the stream). Click resolution assumes
//     the tail view; a click while scrolled back misses honestly rather than
//     opening the wrong link.
//   - On an effective-column change (WIN_RESIZE reflow) the kernel rewraps
//     the grid; the mirror drops its link cells rather than guess wrong —
//     links stop resolving until repainted, never resolve to a wrong URI.
package main

import "strings"

const (
	mirrorCols = 80  // kernel grid_cols
	mirrorRows = 128 // kernel grid_lines
	mirrorHist = 256 // kernel history_lines
	mirrorOSC  = 768 // kernel osc_max — longer strings drop whole there too
	mirrorCSI  = 16  // kernel csi_params

	// linkTableMax bounds the remembered URIs; the oldest drops first.
	linkTableMax = 512
	linkURIMax   = 640 // comfortably under the 768-byte OSC bound
)

// linkTracker is the output-side half: a byte filter that injects the
// underline rendition around OSC-8 spans AND mirrors the kernel screen's
// link-relevant state so a later click can be resolved to a URI.
type linkTracker struct {
	// --- screen mirror (kernel/src/terminal.zig, link-relevant subset) ---
	cells    [mirrorRows][mirrorCols]uint16
	altCells [mirrorRows][mirrorCols]uint16
	hist     [mirrorHist][mirrorCols]uint16
	histTop  int // ring head (oldest slot)
	histN    int
	used     int
	cur      int
	col      int
	cols     int // effective columns (M49 SD5: 8..80)
	pendWrap bool
	autowrap bool
	scrollT  int
	scrollB  int
	origin   bool
	alt      bool
	// per-screen saved state (the kernel swaps these with the alt screen)
	altUsed, altCur, altCol int
	altPendWrap             bool
	altScrollT, altScrollB  int
	altOrigin               bool
	savCur, savCol          int
	savPendWrap             bool
	savValid                bool
	altSavCur, altSavCol    int
	altSavPendWrap          bool
	altSavValid             bool
	tabs, altTabs           [2]uint64
	lastRune                rune // REP (CSI b) repeats the last printed rune

	// --- link table + stream state ---
	linkOpen uint16   // link id being written (0 = none)
	nextID   uint16   // never reused within a session
	ring     linkRing // id -> URI, FIFO-bounded
	scheme   string   // scheme of linkOpen, for the marker path

	// --- parser state (kernel esc_state numbering) ---
	state          uint8
	csi            [mirrorCSI]uint16
	csiN           int
	csiPriv        bool
	csiInter       uint8
	osc            [mirrorOSC]byte
	oscLen         int
	oscOver        bool
	utfNeed        uint8
	utfAcc, utfLen uint32
	strIntro       uint8 // ESC-string introducer for state 6 bookkeeping

	out []byte // transformed bytes produced by filter
}

func newLinkTracker() *linkTracker {
	t := &linkTracker{
		used:     1,
		cols:     mirrorCols,
		autowrap: true,
		scrollB:  mirrorRows - 1,
	}
	// kernel default_tab_stops: columns 8,16,24,...; column 0 is no stop.
	for c := 8; c < mirrorCols; c += 8 {
		t.tabs[c/64] |= 1 << uint(c%64)
	}
	return t
}

// filter consumes one output chunk and returns what should be written to
// the tty: the input verbatim plus the injected underline rendition around
// OSC-8 spans. The mirror is fed from the ORIGINAL stream (the injected
// bytes are rendition-only and cannot move a cell).
func (t *linkTracker) filter(b []byte) []byte {
	t.out = t.out[:0]
	for _, c := range b {
		t.feedByte(c)
	}
	return append([]byte(nil), t.out...)
}

// emit appends one verbatim byte to the transformed stream — one append
// site instead of one per feedByte path keeps the ELF under exec's cap.
func (t *linkTracker) emit(c byte) { t.out = append(t.out, c) }

// feedByte mirrors putByte's state machine, appending this byte (and, at
// an OSC-8 boundary, the underline rendition) to t.out.
func (t *linkTracker) feedByte(c byte) {
	// A pending UTF-8 sequence continues or fails (one U+FFFD, byte refed).
	if t.utfNeed > 0 {
		if c&0xc0 == 0x80 {
			t.utfContinue(c)
			t.emit(c)
			return
		}
		t.utfNeed, t.utfLen = 0, 0
		t.putRune(0xFFFD)
	}
	switch t.state {
	case 0:
	case 1:
		t.state = 0
		switch c {
		case '[':
			t.state, t.csiN, t.csiPriv, t.csiInter = 2, 1, false, 0
			t.csi = [mirrorCSI]uint16{}
		case ']':
			t.state, t.oscLen, t.oscOver = 4, 0, false
		case '7':
			t.savCur, t.savCol, t.savPendWrap, t.savValid = t.cur, t.col, t.pendWrap, true
		case '8':
			if t.savValid {
				t.cur, t.col, t.pendWrap = t.savCur, t.savCol, t.savPendWrap
			}
		case 'D':
			t.linefeed()
		case 'M':
			t.reverseIndex()
		case 'E':
			t.col = 0
			t.linefeed()
		case 'c':
			t.hardReset()
		case '=', '>':
			// keypad application/numeric — presentation-side, not mirrored.
		case '(', ')':
			t.state = 3
		case 'H':
			t.tabStop(t.col, 1)
		case 'P', '_', 'X', '^':
			t.state, t.strIntro = 6, c
		}
		t.emit(c)
		return
	case 2:
		if c >= '0' && c <= '9' {
			t.csi[t.csiN-1] = t.csi[t.csiN-1]*10 + uint16(c-'0')
			t.emit(c)
			return
		}
		if c == ';' {
			if t.csiN < mirrorCSI {
				t.csiN++
			}
			t.emit(c)
			return
		}
		if c == '?' && t.csiN == 1 && t.csi[0] == 0 {
			t.csiPriv = true
			t.emit(c)
			return
		}
		if c >= 0x20 && c <= 0x3f {
			if t.csiInter == 0 {
				t.csiInter = c
			}
			t.emit(c)
			return
		}
		t.state = 0
		t.dispatchCSI(c)
		t.emit(c)
		return
	case 3: // charset select — ignored (rendition, not position)
		t.state = 0
		t.emit(c)
		return
	case 4: // OSC collection
		if c == 0x07 {
			t.state = 0
			t.emit(c)
			t.dispatchOSC()
			return
		}
		if c == 0x1b {
			t.state = 5
			t.emit(c)
			return
		}
		if c == 0x18 || c == 0x1a {
			t.state, t.oscLen, t.oscOver = 0, 0, false
			t.emit(c)
			return
		}
		if t.oscLen < mirrorOSC {
			t.osc[t.oscLen] = c
			t.oscLen++
		} else {
			t.oscOver = true
		}
		t.emit(c)
		return
	case 5: // ESC inside an OSC — '\\' completes the ST
		if c == '\\' {
			t.state = 0
			t.emit(c)
			t.dispatchOSC()
			return
		}
		t.state, t.oscLen, t.oscOver = 1, 0, false
		t.emit(c)
		t.feedByte(c)
		return
	case 6: // ESC string (DCS/APC/SOS/PM) — drained to ST
		if c == 0x1b {
			t.state = 7
			t.emit(c)
			return
		}
		if c == 0x18 || c == 0x1a {
			t.state = 0
		}
		t.emit(c)
		return
	case 7:
		if c == '\\' {
			t.state = 0
			t.emit(c)
			return
		}
		t.state = 1
		t.emit(c)
		t.feedByte(c)
		return
	}
	// state 0: ordinary byte.
	switch c {
	case 0x1b:
		t.state = 1
	case 0x0e, 0x0f:
		// SO/SI charset invoke — rendition, not position.
	case '\n':
		t.linefeed()
		t.col = 0
	case '\r':
		t.cancelWrap()
		t.col = 0
	case 0x08:
		t.cancelWrap()
		if t.col > 0 {
			t.col--
		}
	case '\t':
		t.moveTabStops(1, true)
	case 0x07:
	default:
		if c < 0x20 || c == 0x7f {
			break
		}
		if c < 0x80 {
			t.putRune(rune(c))
		} else if c >= 0xc2 && c <= 0xf4 {
			if c < 0xe0 {
				t.utfNeed, t.utfAcc, t.utfLen = 1, uint32(c&0x1f), 2
			} else if c < 0xf0 {
				t.utfNeed, t.utfAcc, t.utfLen = 2, uint32(c&0x0f), 3
			} else {
				t.utfNeed, t.utfAcc, t.utfLen = 3, uint32(c&0x07), 4
			}
		} else {
			t.putRune(0xFFFD)
		}
	}
	t.emit(c)
}

// dispatchOSC applies one complete OSC string. Only Ps 8 changes the
// mirror: a `params ; URI` payload opens a link span, an empty URI closes
// it — and appends the underline rendition (SGR 4 on open, SGR 24 on
// close) right after the terminator.
func (t *linkTracker) dispatchOSC() {
	raw := t.osc[:t.oscLen]
	over := t.oscOver
	t.oscLen, t.oscOver = 0, false
	if over || len(raw) == 0 {
		return
	}
	// Leading digits are Ps, ';' separates the payload (kernel's rule).
	i := 0
	for i < len(raw) && raw[i] >= '0' && raw[i] <= '9' {
		i++
	}
	if i == 0 || i == len(raw) || raw[i] != ';' {
		return
	}
	num := 0
	for _, d := range raw[:i] {
		num = num*10 + int(d-'0')
	}
	if num != 8 {
		return
	}
	payload := raw[i+1:]
	// The URI is everything after the params field's own ';'.
	uri := ""
	for j := 0; j < len(payload); j++ {
		if payload[j] == ';' {
			uri = string(payload[j+1:])
			break
		}
	}
	if uri == "" {
		t.linkOpen = 0
		t.scheme = ""
		t.out = append(t.out, "\x1b[24m"...)
		return
	}
	if len(uri) > linkURIMax {
		uri = uri[:linkURIMax]
	}
	id := t.remember(uri)
	if id == 0 {
		return // table exhausted: paint still flows, link never resolves
	}
	t.linkOpen = id
	t.scheme = linkURIScheme(uri)
	t.out = append(t.out, "\x1b[4m"...)
}

// linkRing is the bounded id -> URI table: a fixed array keeps the
// guest binary under the exec cap (a map[string] costs real codegen);
// 512 entries is far past any plausible painted link count, and the
// oldest entry drops first when it fills.
type linkRing struct {
	ids  [linkTableMax]uint16
	uris [linkTableMax]string
	head int
	n    int
}

func (r *linkRing) get(id uint16) (string, bool) {
	for i := 0; i < r.n; i++ {
		if r.ids[i] == id {
			return r.uris[i], true
		}
	}
	return "", false
}

// remember stores a URI under a fresh id, evicting FIFO at linkTableMax.
// Ids run 1..65535 then wrap; a wrapped id whose cells may still exist is
// refused (0) rather than repointed at a different URI.
func (t *linkTracker) remember(uri string) uint16 {
	for i := 0; i < 0xffff; i++ {
		t.nextID++
		if t.nextID == 0 {
			t.nextID = 1
		}
		if _, taken := t.ring.get(t.nextID); !taken {
			id := t.nextID
			r := &t.ring
			if r.n < linkTableMax {
				r.ids[r.n], r.uris[r.n] = id, uri
				r.n++
			} else {
				r.ids[r.head], r.uris[r.head] = id, uri
				r.head = (r.head + 1) % linkTableMax
			}
			return id
		}
	}
	return 0
}

// linkURIScheme is the scheme a URI leads with, lower-cased — the name a
// refusal prints. "" when the URI has no scheme prefix.
func linkURIScheme(uri string) string {
	i := strings.IndexByte(uri, ':')
	if i <= 0 {
		return ""
	}
	s := uri[:i]
	for j := 0; j < len(s); j++ {
		c := s[j]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(j > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'))
		if !ok {
			return ""
		}
	}
	return strings.ToLower(s)
}

// linkAt resolves a 1-based SGR report cell to a URI. rowsVisible is the
// window's painted row count ((h-16)/cellH); the kernel reports the
// VISIBLE row, which maps into the unified history+grid space through
// lineCount - rowsVisible (view==0 — the mirror cannot observe the
// chrome-side scroll offset, and never guesses).
func (t *linkTracker) linkAt(col, row, rowsVisible int) (string, bool) {
	if col < 1 || col > mirrorCols || row < 1 || rowsVisible < 1 {
		return "", false
	}
	c := col - 1
	first := t.lineCount() - rowsVisible // kernel: first = 0 below a full screen
	if first < 0 {
		first = 0
	}
	line := first + row - 1
	var id uint16
	if line < 0 || line >= t.lineCount() {
		return "", false
	}
	if t.alt {
		if line >= t.used {
			return "", false
		}
		id = t.cells[line][c]
	} else if line < t.histN {
		id = t.hist[(t.histTop+line)%mirrorHist][c]
	} else {
		id = t.cells[line-t.histN][c]
	}
	if id == 0 {
		return "", false
	}
	return t.ring.get(id)
}

func (t *linkTracker) lineCount() int { return t.histN + t.used }

// setCols mirrors the kernel's reflow decision for link marks only: a
// column change rewraps the real grid, and the marks cannot follow, so the
// map is dropped whole rather than left answering for rows that moved.
func (t *linkTracker) setCols(n int) {
	if n == t.cols {
		return
	}
	if n < 8 {
		n = 8
	}
	if n > mirrorCols {
		n = mirrorCols
	}
	t.cols = n
	t.cells = [mirrorRows][mirrorCols]uint16{}
	t.altCells = [mirrorRows][mirrorCols]uint16{}
	t.hist = [mirrorHist][mirrorCols]uint16{}
	t.histN, t.histTop = 0, 0
}

func (t *linkTracker) hardReset() {
	cols := t.cols
	ring := t.ring
	*t = *newLinkTracker()
	t.cols, t.ring = cols, ring
}

// --- cursor + scroll model (kernel terminal.zig, link-relevant subset) ---

func (t *linkTracker) cancelWrap() {
	t.pendWrap = false
	if t.col >= t.cols {
		t.col = t.cols - 1
	}
}

func (t *linkTracker) clearLine(r int) {
	t.cells[r] = [mirrorCols]uint16{}
}

func (t *linkTracker) clearScreen() {
	if !t.alt {
		t.histN, t.histTop = 0, 0
	}
	t.cells = [mirrorRows][mirrorCols]uint16{}
	t.used, t.cur, t.col = 1, 0, 0
	t.pendWrap = false
}

// grow materializes grid rows through `row` (inclusive): the kernel
// treats a write past `used` as clearing the intervening rows.
func (t *linkTracker) grow(row int) {
	for t.used <= row {
		t.clearLine(t.used)
		t.used++
	}
}

// linefeed is LF and IND (ESC D): the same downward motion; LF then
// returns the cursor to the margin.
func (t *linkTracker) linefeed() {
	t.pendWrap = false
	switch {
	case t.cur < t.scrollB:
		t.cur++
		t.grow(t.cur)
	case t.cur == t.scrollB:
		t.scrollRegionUp(1)
		if t.used <= t.cur {
			t.used = t.cur + 1
		}
	case t.cur+1 < mirrorRows:
		t.cur++
		t.grow(t.cur)
	default:
		t.scrollFullUp(1)
	}
}

func (t *linkTracker) reverseIndex() {
	t.pendWrap = false
	switch {
	case t.cur > t.scrollT:
		t.cur--
	case t.cur == t.scrollT:
		t.scrollRegionDown(1)
	case t.cur > 0:
		t.cur--
	}
}

func (t *linkTracker) scrollFullUp(n int) {
	count := n
	if count > t.used+mirrorHist {
		count = t.used + mirrorHist
	}
	for i := 0; i < count; i++ {
		t.pushHistory()
		for r := 0; r+1 < mirrorRows; r++ {
			t.cells[r] = t.cells[r+1]
		}
		t.clearLine(mirrorRows - 1)
	}
	t.used = mirrorRows
}

func (t *linkTracker) pushHistory() {
	if t.alt {
		return
	}
	if t.histN < mirrorHist {
		t.hist[(t.histTop+t.histN)%mirrorHist] = t.cells[0]
		t.histN++
		return
	}
	t.hist[t.histTop] = t.cells[0]
	t.histTop = (t.histTop + 1) % mirrorHist
}

func (t *linkTracker) scrollRegionUp(n int) {
	height := t.scrollB - t.scrollT + 1
	limit := height
	if t.scrollT == 0 {
		limit = height + mirrorHist
	}
	count := n
	if count > limit {
		count = limit
	}
	for i := 0; i < count; i++ {
		if t.scrollT == 0 {
			t.pushHistory()
		}
		for r := t.scrollT; r < t.scrollB; r++ {
			t.cells[r] = t.cells[r+1]
		}
		t.clearLine(t.scrollB)
	}
	if t.scrollT == 0 && t.used <= t.scrollB+1 {
		if t.used-count < 1 {
			t.used = 1
		} else {
			t.used -= count
		}
	}
}

func (t *linkTracker) scrollRegionDown(n int) {
	height := t.scrollB - t.scrollT + 1
	count := n
	if count > height {
		count = height
	}
	for r := t.scrollB + 1; r > t.scrollT+count; r-- {
		t.cells[r-1] = t.cells[r-1-count]
	}
	for r := t.scrollT; r < t.scrollT+count; r++ {
		t.clearLine(r)
	}
	if t.used <= t.cur {
		t.used = t.cur + 1
	}
	if t.scrollT == 0 && t.used <= t.scrollB+1 {
		t.used += count
		if t.used > t.scrollB+1 {
			t.used = t.scrollB + 1
		}
		if t.used <= t.cur {
			t.used = t.cur + 1
		}
	}
}

func (t *linkTracker) wrapForPrint() {
	t.pendWrap = false
	switch {
	case t.cur < t.scrollB:
		t.cur++
		grew := t.cur >= t.used
		if grew {
			t.used = t.cur + 1
		}
		t.clearLine(t.cur)
	case t.cur == t.scrollB:
		t.scrollRegionUp(1)
		if t.used <= t.cur {
			t.used = t.cur + 1
		}
	case t.cur+1 < mirrorRows:
		t.cur++
		grew := t.cur >= t.used
		if grew {
			t.used = t.cur + 1
		}
		t.clearLine(t.cur)
	default:
		t.scrollFullUp(1)
	}
	t.col = 0
}

func (t *linkTracker) moveCursor(row1, col1 uint16) {
	t.pendWrap = false
	row := int(row1) - 1
	if t.origin {
		if row > t.scrollB-t.scrollT {
			row = t.scrollB - t.scrollT
		}
		row += t.scrollT
	} else if row > mirrorRows-1 {
		row = mirrorRows - 1
	}
	for t.used <= row {
		t.clearLine(t.used)
		t.used++
	}
	t.cur = row
	c := int(col1) - 1
	if c > t.cols-1 {
		c = t.cols - 1
	}
	t.col = c
}

func (t *linkTracker) setScrollRegion(top1, bottom1 uint16) {
	if top1 == 0 || bottom1 == 0 {
		return
	}
	top, bot := int(top1)-1, int(bottom1)-1
	if top >= bot || bot >= mirrorRows {
		return
	}
	t.scrollT, t.scrollB = top, bot
	t.pendWrap = false
	if t.origin {
		t.moveCursor(uint16(top), 1)
	} else {
		t.moveCursor(1, 1)
	}
}

// setAlternate mirrors swapAlternate + the enable-time clear. The link
// grid is swapped just like the kernel's cell grid; history belongs to the
// primary screen (pushHistory refuses while alt is active).
func (t *linkTracker) setAlternate(on bool) {
	if t.alt == on {
		return
	}
	t.cells, t.altCells = t.altCells, t.cells
	t.used, t.altUsed = t.altUsed, t.used
	t.cur, t.altCur = t.altCur, t.cur
	t.col, t.altCol = t.altCol, t.col
	t.pendWrap, t.altPendWrap = t.altPendWrap, t.pendWrap
	t.scrollT, t.altScrollT = t.altScrollT, t.scrollT
	t.scrollB, t.altScrollB = t.altScrollB, t.scrollB
	t.origin, t.altOrigin = t.altOrigin, t.origin
	t.savCur, t.altSavCur = t.altSavCur, t.savCur
	t.savCol, t.altSavCol = t.altSavCol, t.savCol
	t.savPendWrap, t.altSavPendWrap = t.altSavPendWrap, t.savPendWrap
	t.savValid, t.altSavValid = t.altSavValid, t.savValid
	t.alt = on
	if on {
		for c := 8; c < mirrorCols; c += 8 {
			t.altTabs[c/64] |= 1 << uint(c%64)
		}
		t.clearScreen()
		t.savValid = false
		t.scrollT, t.scrollB = 0, mirrorRows-1
		t.origin, t.pendWrap = false, false
	}
}

// --- per-cell write ---

func (t *linkTracker) putRune(cp rune) {
	w := charWidth(cp)
	if w == 0 {
		// Combining/ignorable: overlay or drop — no cell, no cursor move.
		return
	}
	t.grow(t.cur)
	if t.pendWrap {
		t.wrapForPrint()
	} else if w == 2 && t.col+2 > t.cols {
		if t.autowrap {
			t.wrapForPrint()
		} else {
			w = 1 // refused pair paints one replacement cell
		}
	}
	t.cells[t.cur][t.col] = t.linkOpen
	if w == 2 && t.col+1 < mirrorCols {
		t.cells[t.cur][t.col+1] = t.linkOpen
	}
	t.lastRune = cp
	end := t.col + w
	if end == t.cols {
		if t.autowrap {
			t.col = t.cols
		} else {
			t.col = t.cols - 1
		}
		t.pendWrap = t.autowrap
	} else {
		t.col = end
		t.pendWrap = false
	}
}

func (t *linkTracker) repeatLast(n uint16) {
	if t.lastRune == 0 {
		return
	}
	for i := 0; i < int(n); i++ {
		t.putRune(t.lastRune)
	}
}

// charWidth mirrors kernel/src/text.zig char_width (bounded ranges only).
func charWidth(cp rune) int {
	switch {
	case cp >= 0x0300 && cp <= 0x036F,
		cp >= 0x200B && cp <= 0x200F,
		cp == 0x2060,
		cp >= 0xFE00 && cp <= 0xFE0F:
		return 0
	case cp >= 0x4E00 && cp <= 0x9FFF,
		cp >= 0xFF01 && cp <= 0xFF60,
		cp >= 0x1F300 && cp <= 0x1F9FF:
		return 2
	}
	return 1
}

// --- CSI dispatch (link-relevant finals; the rest are consumed) ---

func (t *linkTracker) csiP(i int, fallback uint16) uint16 {
	if i >= t.csiN {
		return fallback
	}
	if v := t.csi[i]; v != 0 {
		return v
	}
	return fallback
}

func (t *linkTracker) dispatchCSI(final byte) {
	p0 := t.csiP(0, 0)
	if t.csiPriv {
		switch p0 {
		case 6:
			if final == 'h' || final == 'l' {
				t.origin = final == 'h'
				row := 1
				if t.origin {
					row = t.scrollT + 1
				}
				t.moveCursor(uint16(row), 1)
				t.pendWrap = false
			}
		case 7:
			if final == 'h' || final == 'l' {
				t.autowrap = final == 'h'
				t.cancelWrap()
			}
		case 47, 1049:
			if final == 'h' || final == 'l' {
				t.setAlternate(final == 'h')
			}
		case 1048:
			if final == 'h' {
				t.savCur, t.savCol, t.savPendWrap, t.savValid = t.cur, t.col, t.pendWrap, true
			}
			if final == 'l' && t.savValid {
				t.cur, t.col, t.pendWrap = t.savCur, t.savCol, t.savPendWrap
			}
		}
		return
	}
	switch final {
	case 'H', 'f':
		t.moveCursor(t.csiP(0, 1), t.csiP(1, 1))
	case 'J':
		t.eraseDisplay(p0)
	case 'K':
		t.eraseLine(p0)
	case 'A':
		t.cancelWrap()
		if t.cur-int(t.csiP(0, 1)) < 0 {
			t.cur = 0
		} else {
			t.cur -= int(t.csiP(0, 1))
		}
	case 'B':
		t.cancelWrap()
		t.cur += int(t.csiP(0, 1))
		if t.cur > mirrorRows-1 {
			t.cur = mirrorRows - 1
		}
	case 'C':
		t.cancelWrap()
		t.col += int(t.csiP(0, 1))
		if t.col > t.cols-1 {
			t.col = t.cols - 1
		}
	case 'D':
		t.cancelWrap()
		if t.col-int(t.csiP(0, 1)) < 0 {
			t.col = 0
		} else {
			t.col -= int(t.csiP(0, 1))
		}
	case 'E':
		t.cancelWrap()
		t.cur += int(t.csiP(0, 1))
		if t.cur > mirrorRows-1 {
			t.cur = mirrorRows - 1
		}
		t.col = 0
	case 'F':
		t.cancelWrap()
		if t.cur-int(t.csiP(0, 1)) < 0 {
			t.cur = 0
		} else {
			t.cur -= int(t.csiP(0, 1))
		}
		t.col = 0
	case 'G', '`':
		t.cancelWrap()
		t.col = int(t.csiP(0, 1)) - 1
		if t.col > t.cols-1 {
			t.col = t.cols - 1
		}
		if t.col < 0 {
			t.col = 0
		}
	case 'd':
		t.moveCursor(t.csiP(0, 1), uint16(t.col+1))
	case 'r':
		t.setScrollRegion(t.csiP(0, 1), t.csiP(1, mirrorRows))
	case 'b':
		t.repeatLast(t.csiP(0, 1))
	case '@':
		t.insertChars(t.csiP(0, 1))
	case 'P':
		t.deleteChars(t.csiP(0, 1))
	case 'X':
		t.eraseChars(t.csiP(0, 1))
	case 'L':
		t.insertLines(t.csiP(0, 1))
	case 'M':
		t.deleteLines(t.csiP(0, 1))
	case 'S':
		t.scrollRegionUp(int(t.csiP(0, 1)))
	case 'T':
		if t.csiN == 1 {
			t.scrollRegionDown(int(t.csiP(0, 1)))
		}
	case 'g':
		switch p0 {
		case 0:
			t.tabStop(t.col, 2)
		case 3:
			if t.alt {
				t.altTabs = [2]uint64{}
			} else {
				t.tabs = [2]uint64{}
			}
		}
	case 'I':
		t.moveTabStops(t.csiP(0, 1), true)
	case 'Z':
		t.moveTabStops(t.csiP(0, 1), false)
	}
}

func (t *linkTracker) eraseLine(mode uint16) {
	t.cancelWrap()
	var start, end int
	switch mode {
	case 1:
		start, end = 0, t.col+1
	default:
		start = t.col
		if mode == 2 {
			start = 0
		}
		end = t.cols
	}
	if start > t.cols {
		start = t.cols
	}
	if end > t.cols {
		end = t.cols
	}
	for c := start; c < end; c++ {
		t.cells[t.cur][c] = 0
	}
}

func (t *linkTracker) eraseDisplay(mode uint16) {
	switch mode {
	case 1:
		for r := 0; r < t.cur; r++ {
			t.clearLine(r)
		}
		t.eraseLine(1)
	case 2:
		t.clearScreen()
	case 3:
		if !t.alt {
			t.histN, t.histTop = 0, 0
		}
	default:
		t.eraseLine(0)
		for r := t.cur + 1; r < t.used; r++ {
			t.clearLine(r)
		}
	}
}

func (t *linkTracker) insertChars(n uint16) {
	t.cancelWrap()
	if t.cur >= t.used {
		return
	}
	count := int(n)
	if count > t.cols {
		count = t.cols
	}
	for c := t.cols - 1; c >= t.col+count; c-- {
		t.cells[t.cur][c] = t.cells[t.cur][c-count]
	}
	for c := t.col; c < t.col+count && c < t.cols; c++ {
		t.cells[t.cur][c] = 0
	}
}

func (t *linkTracker) deleteChars(n uint16) {
	t.cancelWrap()
	if t.cur >= t.used {
		return
	}
	end := t.col + int(n)
	if end > t.cols {
		end = t.cols
	}
	m := end - t.col
	for c := t.col; c+m < t.cols; c++ {
		t.cells[t.cur][c] = t.cells[t.cur][c+m]
	}
	for c := t.cols - m; c < t.cols; c++ {
		t.cells[t.cur][c] = 0
	}
}

func (t *linkTracker) eraseChars(n uint16) {
	t.cancelWrap()
	if t.cur >= t.used {
		return
	}
	end := t.col + int(n)
	if end > t.cols {
		end = t.cols
	}
	for c := t.col; c < end; c++ {
		t.cells[t.cur][c] = 0
	}
}

func (t *linkTracker) insertLines(n uint16) {
	if t.cur < t.scrollT || t.cur > t.scrollB || t.cur >= t.used {
		return
	}
	t.cancelWrap()
	cnt := int(n)
	if cnt > t.scrollB-t.cur+1 {
		cnt = t.scrollB - t.cur + 1
	}
	for r := t.scrollB + 1; r > t.cur+cnt; r-- {
		t.cells[r-1] = t.cells[r-1-cnt]
	}
	for r := t.cur; r < t.cur+cnt; r++ {
		t.clearLine(r)
	}
	t.col = 0
	if t.used <= t.scrollB+1 {
		t.used += cnt
		if t.used > t.scrollB+1 {
			t.used = t.scrollB + 1
		}
	}
	if t.used <= t.cur {
		t.used = t.cur + 1
	}
}

func (t *linkTracker) deleteLines(n uint16) {
	if t.cur < t.scrollT || t.cur > t.scrollB || t.cur >= t.used {
		return
	}
	t.cancelWrap()
	m := int(n)
	if m > t.scrollB-t.cur+1 {
		m = t.scrollB - t.cur + 1
	}
	for r := t.cur; r+m <= t.scrollB; r++ {
		t.cells[r] = t.cells[r+m]
	}
	for r := t.scrollB + 1 - m; r <= t.scrollB; r++ {
		t.clearLine(r)
	}
	t.col = 0
	if t.used <= t.scrollB+1 {
		t.used -= m
		if t.used < 1 || t.used < t.cur {
			t.used = 1
			if t.cur > 0 {
				t.used = t.cur
			}
		}
	}
}

// --- tab stops (kernel M80d semantics) ---

func (t *linkTracker) tabStop(c int, mode int) bool {
	if c >= t.cols {
		return false
	}
	tb := &t.tabs
	if t.alt {
		tb = &t.altTabs
	}
	b := uint64(1) << uint(c%64)
	switch mode {
	case 1:
		tb[c/64] |= b
	case 2:
		tb[c/64] &^= b
	}
	return tb[c/64]&b != 0
}

func (t *linkTracker) moveTabStops(count uint16, forward bool) {
	t.cancelWrap()
	for i := 0; i < int(count); i++ {
		if forward {
			c := t.col + 1
			for c < t.cols && !t.tabStop(c, 0) {
				c++
			}
			if c > t.cols-1 {
				c = t.cols - 1
			}
			t.col = c
			if t.col == t.cols-1 && !t.tabStop(t.col, 0) {
				break
			}
		} else {
			c := t.col
			for c > 0 {
				c--
				if t.tabStop(c, 0) {
					break
				}
			}
			t.col = c
			if c == 0 && !t.tabStop(0, 0) {
				break
			}
		}
	}
}

// --- UTF-8 (kernel M73a-1 decode, link-relevant) ---

func (t *linkTracker) utfContinue(b byte) {
	t.utfAcc = t.utfAcc<<6 | uint32(b&0x3f)
	t.utfNeed--
	if t.utfNeed > 0 {
		return
	}
	cp := t.utfAcc
	ok := false
	switch t.utfLen {
	case 2:
		ok = cp >= 0x80 && cp <= 0x7ff
	case 3:
		ok = cp >= 0x800 && cp <= 0xd7ff || cp >= 0xe000 && cp <= 0xffff
	case 4:
		ok = cp >= 0x10000 && cp <= 0x10ffff
	}
	if !ok {
		cp = 0xFFFD
	}
	t.putRune(rune(cp))
}

// --- input-side: SGR mouse reports (M73i encodeMouse ?1006 form) ---

// mouseRep is one decoded SGR mouse report.
type mouseRep struct {
	btn     uint8
	col     int
	row     int
	release bool // final 'm' (release) vs 'M' (press/drag/wheel)
}

// mouseFilter strips `ESC [ < b ; x ; y M|m` reports out of the tty input
// stream before the shlib editor sees them. Any other byte sequence —
// including every other escape — passes through byte-identically and in
// order. A partial report survives across reads; a sequence that stops
// matching flushes back to the editor verbatim. The matcher is a small
// explicit state: 0 ground, 1 saw ESC, 2 saw `[`, 3 collecting the
// report's numeric body.
type mouseFilter struct {
	pend   [mouseRepMax]byte
	pendN  int
	reps   []mouseRep
	pressC int // click bookkeeping: press cell, -1 = none
	pressR int
}

func newMouseFilter() *mouseFilter { return &mouseFilter{pressC: -1} }

const mouseRepMax = 32

// extract splits chunk into editor-clean input plus any complete mouse
// reports, preserving order.
func (m *mouseFilter) extract(chunk []byte) ([]byte, []mouseRep) {
	var clean []byte
	m.reps = m.reps[:0]
	flush := func() {
		clean = append(clean, m.pend[:m.pendN]...)
		m.pendN = 0
	}
	for _, c := range chunk {
		if m.pendN == 0 {
			if c == 0x1b {
				m.pend[0] = c
				m.pendN = 1
			} else {
				clean = append(clean, c)
			}
			continue
		}
		if m.pendN >= mouseRepMax {
			flush()
			if c == 0x1b {
				m.pend[0] = c
				m.pendN = 1
			} else {
				clean = append(clean, c)
			}
			continue
		}
		m.pend[m.pendN] = c
		m.pendN++
		switch {
		case m.pendN == 2:
			if c != '[' {
				flush()
			}
		case m.pendN == 3:
			if c != '<' {
				flush()
			}
		case c == 'M' || c == 'm':
			if r, ok := decodeMouseRep(m.pend[:m.pendN]); ok {
				m.reps = append(m.reps, r)
				m.pendN = 0
			} else {
				flush()
			}
		case (c < '0' || c > '9') && c != ';':
			flush()
		}
	}
	return clean, m.reps
}

// decodeMouseRep parses `ESC [ < b ; x ; y M|m` (pend includes the ESC).
func decodeMouseRep(p []byte) (mouseRep, bool) {
	var r mouseRep
	if len(p) < 7 {
		return r, false
	}
	final := p[len(p)-1]
	if final != 'm' && final != 'M' {
		return r, false
	}
	r.release = final == 'm'
	var vals [3]int
	vi := 0
	for i := 3; i < len(p)-1; i++ {
		c := p[i]
		if c == ';' {
			vi++
			if vi > 2 {
				return r, false
			}
			continue
		}
		vals[vi] = vals[vi]*10 + int(c-'0')
	}
	if vi != 2 {
		return r, false
	}
	r.btn = uint8(vals[0])
	r.col, r.row = vals[1], vals[2]
	return r, true
}

// clickCell converts a report into the open gesture: a left press records
// the cell; the matching release on the SAME cell is a click and returns
// its coordinates. Drags (release elsewhere), wheels and non-left buttons
// never click — a press that began elsewhere still may not click here.
func (m *mouseFilter) clickCell(r mouseRep) (int, int, bool) {
	left := r.btn&0x3 == 0 && r.btn&0x40 == 0 // button 0, not wheel
	if !r.release {
		if left {
			m.pressC, m.pressR = r.col, r.row
		} else {
			m.pressC = -1
		}
		return 0, 0, false
	}
	if !left {
		m.pressC = -1
		return 0, 0, false
	}
	if m.pressC == r.col && m.pressR == r.row && m.pressC >= 0 {
		m.pressC = -1
		return r.col, r.row, true
	}
	m.pressC = -1
	return 0, 0, false
}
