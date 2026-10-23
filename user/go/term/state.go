// M125e (issue #2590): GOTERM's session state — the per-app blob the seat
// carries through the M125a protocol (vi.EncodeAppState, AppStateMax =
// 64 KiB). The app owns the format; v2 (card #2927) is:
//
//	u8  format (=2)          the app's own staleness tag — the seat
//	u8  flags                stores and returns StateVersion verbatim,
//	     bit0: alt-screen    but RestoreState runs inside tabapp.Init
//	u16 cwdLen | cwd         before the returned TabApp can be read, so
//	u16 envN   | envN x      the blob tags itself
//	           { u16 len |
//	             "NAME=VALUE" }
//	u32 scLen  | scrollback
//	u16 profLen | profile    v2 only (card #2927): the active
//	                         term-profile name, "" when none
//
// The scrollback is a BYTE STREAM, not a grid: the kernel owns the tty
// presentation buffer and exposes no readback seam, so GOTERM keeps the
// capped tail of every byte it wrote to /dev/tty. Restore replays it
// read-only — the same emulator re-derives the grid and its scroll ring
// — then starts a fresh shell in the saved cwd/env (child processes are
// out of scope). The alt flag is tracked live across write boundaries by
// altScreenScan; when the ring clip evicted the original DECSET the
// replayed stream ends on the primary grid, so restore re-issues
// `ESC[?1049h` (kernel setAlternate early-outs when already armed — a
// redundant enter never clears replayed alt content).
//
// Every bound is hard and every field is length-checked: a stale, short,
// over-declared, or trailing-garbage blob is refused WHOLE (marker
// `goterm: state refused`), never half-applied and never crashed on. A v1
// blob still decodes — it predates the profile field, so the name lands
// empty and no profile re-applies; v0 and future formats refuse.
package main

import (
	"bytes"
	"strings"

	"virelai/shlib"
	"virelai/vi"
)

const (
	termStateVersion uint8 = 2 // current format; 1 is the M125e legacy
	termStateMinVer  uint8 = 1 // oldest blob decode still accepts
	// stateCwdMax is the resolver's own path bound (shlib maxPathBytes).
	stateCwdMax = 512
	// Env section caps — bounded so the table can never crowd scrollback
	// out of the 64 KiB envelope.
	stateEnvMaxN    = 64
	stateEnvPairMax = 512
	stateEnvBytes   = 8 * 1024
	// stateScrollMax is the captured stream tail: deep enough to cover
	// the kernel ring (history_lines 256 x <=80 cells) several times
	// over while leaving the fixed fields their headroom.
	stateScrollMax = 48 * 1024
	// stateLFAlign bounds the head scan for a trim boundary.
	stateLFAlign = 4096
	// stateTailMax caps the marker's last-line excerpt.
	stateTailMax = 40
)

// termState is the session-state half of the app: the live capture
// (ring + alt + scan) plus the decoded restore fields. `sh` points at
// the CURRENT session's shell — a restart swaps it so a save always
// serializes the live environment.
type termState struct {
	sh   *shlib.Shell
	ring []byte
	// clipped records that the ring has evicted bytes — its head may be
	// mid-line, so save LF-aligns a clipped tail (an untrimmed stream
	// already starts clean; dropping its first line would lose content).
	clipped bool
	alt     bool
	scan    altScreenScan

	restored bool
	cwd      string
	pairs    []string
	savedAlt bool
	scroll   []byte

	// Card #2927: profile is the live pick (set by a successful
	// term-profile apply and by restore); save() falls back to the
	// settings store's term_profile row when no apply ran this process.
	// savedProfile is the blob's decoded name — applyEnv consumes it.
	profile      string
	savedProfile string

	// M149b (#2807): the OSC-8 link tracker on the write path and the
	// SGR mouse-report filter on the read path (links.go).
	lt *linkTracker
	mi *mouseFilter
}

// capture is the tee on the tty write path: every byte the kernel paints
// also lands in the capped ring (drop-oldest) and in the alt-screen
// scanner. The ring is byte-faithful rather than grid-faithful — a
// mid-stream ESC c or ED 3 stays in the stream so replay re-executes the
// same reset.
func (ts *termState) capture(b []byte) {
	ts.ring = append(ts.ring, b...)
	if over := len(ts.ring) - stateScrollMax; over > 0 {
		ts.ring = append(ts.ring[:0], ts.ring[over:]...)
		ts.clipped = true
	}
	for _, c := range b {
		ts.scan.feed(c, ts)
	}
}

// save serializes the live state — Config.SaveState's body. The scroll
// tail is LF-aligned when trimmed so replay never opens mid-line (and,
// in the common case, mid-escape).
func (ts *termState) save() []byte {
	var cwd string
	var pairs []string
	if ts.sh != nil {
		cwd = ts.sh.Pwd()
		pairs = ts.sh.Env().Pairs()
	}
	if len(cwd) > stateCwdMax {
		cwd = cwd[:stateCwdMax]
	}
	scroll := ts.ring
	trimmed := ts.clipped
	if len(scroll) > stateScrollMax {
		scroll = scroll[len(scroll)-stateScrollMax:]
		trimmed = true
	}
	if trimmed {
		if i := bytes.IndexByte(scroll, '\n'); i >= 0 && i < stateLFAlign {
			scroll = scroll[i+1:]
		}
	}
	// The active profile is the settings store's record; the field covers
	// a save that lands between an apply and the file write's visibility,
	// or a guest whose SETTINGS.TXT cannot be re-read.
	profile := shlib.SettingFromSettings(settingsBody(), "term_profile", "")
	if profile == "" {
		profile = ts.profile
	}
	if len(profile) > profileNameMax {
		profile = profile[:profileNameMax]
	}
	out := make([]byte, 0, 10+len(cwd)+len(scroll))
	out = append(out, termStateVersion, 0)
	if ts.alt {
		out[1] = 1
	}
	out = appendU16(out, uint16(len(cwd)))
	out = append(out, cwd...)
	nPos := len(out)
	out = appendU16(out, 0)
	nEnv, envBytes := 0, 0
	for _, p := range pairs {
		if len(p) > stateEnvPairMax || nEnv >= stateEnvMaxN ||
			envBytes+2+len(p) > stateEnvBytes {
			continue
		}
		out = appendU16(out, uint16(len(p)))
		out = append(out, p...)
		envBytes += 2 + len(p)
		nEnv++
	}
	out[nPos] = byte(nEnv)
	out[nPos+1] = byte(nEnv >> 8)
	out = appendU32(out, uint32(len(scroll)))
	out = append(out, scroll...)
	out = appendU16(out, uint16(len(profile)))
	return append(out, profile...)
}

// restore is Config.RestoreState's body: decode or refuse whole. The
// fields land in the decoded slots; runSession replays/applies them
// after the tty is attached.
func (ts *termState) restore(b []byte) {
	d, ok := decodeTermState(b)
	if !ok {
		vi.ConsoleLine(markerStateRefused)
		return
	}
	ts.restored = true
	ts.pairs = d.pairs
	ts.cwd = d.cwd
	ts.savedAlt = d.alt
	ts.scroll = d.scroll
	ts.savedProfile = d.profile
}

// applyReplay writes the saved stream to the tty (through the capture
// tee, so the ring is the true suffix of bytes ever written) and
// re-arms the alternate screen when the saved flag demands it but the
// clip evicted the enter directive.
func (ts *termState) applyReplay(fd uint32) {
	writeTTY(ts, fd, ts.scroll)
	if ts.savedAlt && !ts.alt {
		writeTTY(ts, fd, []byte("\x1b[?1049h"))
	}
}

// applyEnv restores the serialized table into the fresh shell, then
// verifies the saved cwd still exists — a stale PWD is folded back to
// the share root rather than poisoning later path resolution. The
// blob's explicit cwd field wins; the env table's own PWD is the
// fallback when the field is empty. The blob's profile name re-applies
// here too (card #2927): the merge runs before the restored marker, so
// `goterm: profile <name>` is already on serial when `state restored`
// summarizes. Returns the cwd the shell holds.
func (ts *termState) applyEnv(sh *shlib.Shell, hst *termHost) string {
	defer ts.applySavedProfile(hst)
	for _, p := range ts.pairs {
		if eq := strings.IndexByte(p, '='); eq > 0 {
			sh.Env().Set(p[:eq], p[eq+1:])
		}
	}
	cwd := ts.cwd
	if cwd == "" {
		cwd = sh.Pwd()
	}
	if cwd != "/" && hst.Chdir(cwd) != nil {
		cwd = "/"
	}
	sh.Env().Set("PWD", cwd)
	return cwd
}

// restoredMarker reports what was applied — printed only AFTER the
// replay write and env application returned, same contract as every
// other goterm marker.
func (ts *termState) restoredMarker(cwd string) string {
	alt := "0"
	if ts.savedAlt {
		alt = "1"
	}
	return markerStateRestored + " cwd=" + cwd +
		" env=" + vi.Itoa64(int64(len(ts.pairs))) +
		" back=" + vi.Itoa64(int64(len(ts.scroll))) +
		" alt=" + alt + " tail=" + scrollTail(ts.scroll)
}

// termStateDecoded is decodeTermState's checked result.
type termStateDecoded struct {
	cwd     string
	pairs   []string
	alt     bool
	scroll  []byte
	profile string
}

func appendU16(b []byte, v uint16) []byte {
	return append(b, byte(v), byte(v>>8))
}

func appendU32(b []byte, v uint32) []byte {
	return append(b, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

// decodeTermState is save's strict inverse: every declared length is
// checked against what remains and the blob must be consumed EXACTLY —
// no trailing bytes. Refusal is total (ok=false), never partial state.
func decodeTermState(b []byte) (termStateDecoded, bool) {
	var d termStateDecoded
	if len(b) < 6 || b[0] < termStateMinVer || b[0] > termStateVersion {
		return d, false
	}
	ver := b[0]
	d.alt = b[1]&1 != 0
	off := 2
	u16 := func() (int, bool) {
		if len(b)-off < 2 {
			return 0, false
		}
		v := int(b[off]) | int(b[off+1])<<8
		off += 2
		return v, true
	}
	n, ok := u16()
	if !ok || n > stateCwdMax || len(b)-off < n {
		return d, false
	}
	d.cwd = string(b[off : off+n])
	off += n
	envN, ok := u16()
	if !ok || envN > stateEnvMaxN {
		return d, false
	}
	for e := 0; e < envN; e++ {
		pl, ok := u16()
		if !ok || pl > stateEnvPairMax || len(b)-off < pl {
			return d, false
		}
		p := string(b[off : off+pl])
		off += pl
		if strings.IndexByte(p, '=') <= 0 {
			return d, false
		}
		d.pairs = append(d.pairs, p)
	}
	if len(b)-off < 4 {
		return d, false
	}
	sc := int(uint32(b[off]) | uint32(b[off+1])<<8 |
		uint32(b[off+2])<<16 | uint32(b[off+3])<<24)
	off += 4
	if sc > stateScrollMax || len(b)-off < sc {
		return d, false
	}
	d.scroll = append([]byte(nil), b[off:off+sc]...)
	off += sc
	if ver >= 2 {
		// v2's trailing section (card #2927): the active profile name.
		pl, ok := u16()
		if !ok || pl > profileNameMax || len(b)-off != pl {
			return d, false
		}
		d.profile = string(b[off : off+pl])
		off += pl
	}
	if off != len(b) {
		return d, false
	}
	return d, true
}

// scrollTail extracts the last LF-terminated line of the replayed
// stream for the restored marker — printable ASCII only, capped, so the
// marker can never inject a control sequence into serial.
func scrollTail(b []byte) string {
	i := bytes.LastIndexByte(b, '\n')
	if i <= 0 {
		return ""
	}
	line := b[:i]
	if j := bytes.LastIndexByte(line, '\n'); j >= 0 {
		line = line[j+1:]
	}
	line = bytes.TrimRight(line, "\r")
	out := make([]byte, 0, stateTailMax)
	for _, c := range line {
		if c < 0x20 || c > 0x7e {
			continue
		}
		if len(out) >= stateTailMax {
			break
		}
		out = append(out, c)
	}
	return string(out)
}

// altScreenScan tracks DECSET ?47/?1049 across write boundaries — the
// flag the blob serializes. ESC c (RIS) clears it, matching the kernel's
// hardReset. Only the FIRST private parameter is meaningful to the
// kernel (csiParam(0)); later params are skipped to the final byte.
type altScreenScan struct {
	st uint8
	p0 int
}

const (
	scanIdle = iota
	scanEsc
	scanCSI
	scanPriv
	scanRest
)

func (a *altScreenScan) feed(c byte, ts *termState) {
	switch a.st {
	case scanIdle:
		if c == 0x1b {
			a.st = scanEsc
		}
	case scanEsc:
		switch c {
		case '[':
			a.st = scanCSI
		case 'c':
			ts.alt = false
			a.st = scanIdle
		case 0x1b:
		default:
			a.st = scanIdle
		}
	case scanCSI:
		if c == '?' {
			a.st = scanPriv
			a.p0 = -1
		} else {
			a.st = scanIdle
		}
	case scanPriv:
		switch {
		case c >= '0' && c <= '9':
			if a.p0 < 0 {
				a.p0 = 0
			}
			if a.p0 < 100000 {
				a.p0 = a.p0*10 + int(c-'0')
			}
		case c >= 0x40 && c <= 0x7e:
			a.apply(c, ts)
			a.st = scanIdle
		case c >= 0x20 && c <= 0x3f:
			a.st = scanRest
		default:
			a.st = scanIdle
		}
	case scanRest:
		if c >= 0x40 && c <= 0x7e {
			a.apply(c, ts)
			a.st = scanIdle
		} else if c < 0x20 || c > 0x3f {
			a.st = scanIdle
		}
	}
}

func (a *altScreenScan) apply(final byte, ts *termState) {
	if a.p0 != 47 && a.p0 != 1049 {
		return
	}
	if final == 'h' {
		ts.alt = true
	}
	if final == 'l' {
		ts.alt = false
	}
}

// --- M192f (#3251): notify-on-finish -------------------------------------
// A foreground command that ran past the term_notify_seconds threshold
// (default 5 s) while its tab was unfocused earns a seat toast — name,
// status, duration. A focused tab, a fast command, `off`, or an
// unreadable focus query post nothing: silence is what watching earns.
// The toast text must fit the WM_RPC frame's 24-byte title
// (vi.WmRpcTitleMax): the name yields its budget to the status and
// duration — the part worth tapping — so the wire never clips a field.

const (
	// notifyKey is the one settings row: a positive seconds count, or
	// `off` to disable the tap outright.
	notifyKey         = "term_notify_seconds"
	notifyDefaultSecs = 5
	// notifyTextMax is the seat's toast budget — the WM_RPC frame title
	// (vi.WmRpcTitleMax).
	notifyTextMax = 24
)

// notifyThresholdNs reads the key out of a SETTINGS.TXT body. "off" maps
// to a negative sentinel the caller treats as never-notify; a positive
// integer is seconds; anything else — absent, non-numeric, zero — falls
// back to the default.
func notifyThresholdNs(body string) int64 {
	v := notifyValue(body)
	if v == "off" {
		return -1
	}
	if n, ok := parseNotifySeconds(v); ok && n > 0 {
		return int64(n) * 1e9
	}
	return notifyDefaultSecs * 1e9
}

// notifyValue is the key's raw value, scanned with the same `key =`
// tolerance restartPolicyFromSettings uses — the kernel's own parse_line
// trims both sides of '=' (kernel/src/settings.zig), so a spaced row is
// a real row.
func notifyValue(body string) string {
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		eq := strings.IndexByte(line, '=')
		if eq < 0 || strings.TrimSpace(line[:eq]) != notifyKey {
			continue
		}
		return strings.TrimSpace(line[eq+1:])
	}
	return ""
}

// parseNotifySeconds is the decimal parser (the guest strconv port is not
// imported here) — digits only, bounded so a silly threshold can never
// wrap the int64 elapsed compare.
func parseNotifySeconds(s string) (int, bool) {
	if s == "" {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > 1<<30 {
			return 0, false
		}
	}
	return n, true
}

// notifyName is the toast's `name`: the submitted line's first word —
// the command the user would call it by.
func notifyName(line string) string {
	f := strings.Fields(line)
	if len(f) == 0 {
		return "command"
	}
	return f[0]
}

// notifyDuration renders elapsed nanoseconds compactly: `7s` under a
// minute, `2m5s` under an hour, `1h12m` past it — at most 6 bytes so the
// title budget is spent on the name, not the units.
func notifyDuration(ns int64) string {
	s := ns / 1e9
	switch {
	case s < 60:
		return vi.Itoa64(s) + "s"
	case s < 3600:
		return vi.Itoa64(s/60) + "m" + vi.Itoa64(s%60) + "s"
	default:
		return vi.Itoa64(s/3600) + "h" + vi.Itoa64(s%3600/60) + "m"
	}
}

// notifyText builds the toast body — `<name> exited st=<N> in <dur>` —
// with the name clipped to whatever the 24-byte title leaves after the
// suffix, so the marker and the screen always carry the same bytes.
func notifyText(name string, status int, elapsedNs int64) string {
	suffix := " exited st=" + vi.Itoa64(int64(status)) +
		" in " + notifyDuration(elapsedNs)
	budget := notifyTextMax - len(suffix)
	if budget < 1 {
		budget = 1
	}
	if len(name) > budget {
		name = name[:budget]
	}
	return name + suffix
}

// --- M191a (#3242): the scrollback find corpus ----------------------------
//
// The find bar searches the capture ring re-derived into plain rows: the
// same emulator rules the OSC-8 mirror (links.go) tracks — grid + scroll
// ring, cursor, scroll regions, autowrap, the alternate screen — but
// carrying the RUNES each cell holds instead of link ids. The kernel owns
// the tty presentation and exposes no readback seam, so this mirror IS
// the searchable grid; its bounds are the kernel's own (grid_lines 128,
// history_lines 256, grid_cols 80), a blank cell reads as a space, and
// matches never cross row boundaries (the kernel search's pinned v1
// rule). The corpus is rebuilt from the ring on every pattern edit, so
// typing narrows against the live surface — no cached index to stale.
//
// A DCS `q` (sixel) payload paints image cells, not runes — the mirror
// records where each one began and the bar NAMES those rows, never
// silently searching pixels.

// findSpan is one sixel image's origin, as a corpus row index.
type findSpan struct{ row int }

// streamDoc is the find corpus: plain rows oldest-first plus the rows
// sixel images began on. Row 0 of lines is the corpus's oldest line.
type streamDoc struct {
	lines  []string
	sixels []findSpan
}

// scrollFindDoc re-derives the ring into the corpus. A clipped head may
// open mid-line (mid-escape), so the same LF alignment save() applies
// bounds the rebuild — the corpus never opens on half a directive.
func scrollFindDoc(ts *termState) *streamDoc {
	b := ts.ring
	if ts.clipped {
		if i := bytes.IndexByte(b, '\n'); i >= 0 && i < stateLFAlign {
			b = b[i+1:]
		}
	}
	return docFromStream(b)
}

// countHits is the corpus seam's count: non-overlapping substring hits
// across all rows — the same rule virelai/find's All runs for the canvas
// apps' bars, kept per-row because matches never cross row boundaries.
func countHits(doc *streamDoc, pat string) int {
	if doc == nil || pat == "" {
		return 0
	}
	n := 0
	for _, ln := range doc.lines {
		n += strings.Count(ln, pat)
	}
	return n
}

// hitDocRow maps a 0-based hit ordinal to its corpus row; -1 when the
// ordinal is out of range.
func hitDocRow(doc *streamDoc, pat string, ord int) int {
	if doc == nil || pat == "" || ord < 0 {
		return -1
	}
	seen := 0
	for r, ln := range doc.lines {
		c := strings.Count(ln, pat)
		if c == 0 {
			continue
		}
		if seen+c > ord {
			return r
		}
		seen += c
	}
	return -1
}

// hitDocRows lists every row holding at least one hit, oldest first —
// the overlay's hit window.
func hitDocRows(doc *streamDoc, pat string) []int {
	var out []int
	if doc == nil || pat == "" {
		return out
	}
	for r, ln := range doc.lines {
		if strings.Count(ln, pat) > 0 {
			out = append(out, r)
		}
	}
	return out
}

// docBuilder mirrors the kernel emulator (links.go's link-relevant
// subset) carrying runes. A nil row is a blank row; rows materialize on
// first write and a zero rune is a blank cell (rendered ' ' at finish,
// the kernel's own rule for never-written cells).
type docBuilder struct {
	cols int

	hist    [mirrorHist][]rune
	histTop int
	histN   int
	dropped int // corpus rows evicted above the ring (absolute accounting)

	cells    [mirrorRows][]rune
	altCells [mirrorRows][]rune
	used     int
	cur, col int
	pendWrap bool
	autowrap bool
	scrollT  int
	scrollB  int
	origin   bool
	alt      bool

	altUsed, altCur, altCol int
	altPendWrap             bool
	altScrollT, altScrollB  int
	altOrigin               bool

	savCur, savCol       int
	savPendWrap          bool
	savValid             bool
	altSavCur, altSavCol int
	altSavPendWrap       bool
	altSavValid          bool

	tabs, altTabs [2]uint64
	lastRune      rune

	// sixel bookkeeping: each DCS `q` origin as an absolute row.
	sixAbs []int

	// parser state (kernel esc_state numbering, links.go's set)
	state         uint8
	csi           [mirrorCSI]uint16
	csiN          int
	csiPriv       bool
	strKind       uint8 // the ESC-string introducer ('P' = DCS)
	inSixel       bool  // a DCS `q` payload is running
	utfNeed       uint8
	utfAcc, utfLen uint32
}

func docFromStream(b []byte) *streamDoc {
	d := &docBuilder{cols: mirrorCols, used: 1, autowrap: true, scrollB: mirrorRows - 1}
	// kernel default_tab_stops: columns 8,16,24,...; column 0 is no stop.
	for c := 8; c < mirrorCols; c += 8 {
		d.tabs[c/64] |= 1 << uint(c%64)
	}
	for _, c := range b {
		d.feed(c)
	}
	return d.finish()
}

// feed mirrors linkTracker.feedByte's state machine, minus the output
// tee: every byte that moves a cell or writes a rune lands in the doc,
// and every escape the mirror does not model is consumed whole.
func (d *docBuilder) feed(c byte) {
	// A pending UTF-8 sequence continues or fails (one U+FFFD, byte refed).
	if d.utfNeed > 0 {
		if c&0xc0 == 0x80 {
			d.utfContinue(c)
			return
		}
		d.utfNeed, d.utfLen = 0, 0
		d.putRune(0xFFFD)
	}
	switch d.state {
	case 0:
	case 1:
		d.state = 0
		switch c {
		case '[':
			d.state, d.csiN, d.csiPriv = 2, 1, false
			d.csi = [mirrorCSI]uint16{}
		case ']':
			d.state = 4
		case '7':
			d.savCur, d.savCol, d.savPendWrap, d.savValid = d.cur, d.col, d.pendWrap, true
		case '8':
			if d.savValid {
				d.cur, d.col, d.pendWrap = d.savCur, d.savCol, d.savPendWrap
			}
		case 'D':
			d.linefeed()
		case 'M':
			d.reverseIndex()
		case 'E':
			d.col = 0
			d.linefeed()
		case 'c':
			d.hardReset()
		case 'P', '_', 'X', '^':
			d.state, d.strKind, d.inSixel = 6, c, false
		}
		return
	case 2:
		if c >= '0' && c <= '9' {
			d.csi[d.csiN-1] = d.csi[d.csiN-1]*10 + uint16(c-'0')
			return
		}
		if c == ';' {
			if d.csiN < mirrorCSI {
				d.csiN++
			}
			return
		}
		if c == '?' && d.csiN == 1 && d.csi[0] == 0 {
			d.csiPriv = true
			return
		}
		if c >= 0x20 && c <= 0x3f {
			return // intermediate — no position effect we mirror
		}
		d.state = 0
		d.dispatchCSI(c)
		return
	case 3: // charset select — position-neutral, consumed.
		d.state = 0
		return
	case 4: // OSC — consumed whole, never text.
		if c == 0x07 || c == 0x18 || c == 0x1a {
			d.state = 0
			return
		}
		if c == 0x1b {
			d.state = 5
		}
		return
	case 5: // ESC inside an OSC — '\\' completes the ST.
		if c == '\\' {
			d.state = 0
			return
		}
		d.state = 1
		d.feed(c)
		return
	case 6: // ESC string (DCS/APC/SOS/PM) — drained to ST.
		if c == 0x1b {
			d.state = 7
			return
		}
		if c == 0x18 || c == 0x1a {
			d.state, d.inSixel = 0, false
			return
		}
		// A DCS whose final is 'q' is a sixel image: the payload paints
		// pixel cells, never runes — name the origin row and drain.
		if d.strKind == 'P' && !d.inSixel && c == 'q' {
			d.inSixel = true
			d.sixAbs = append(d.sixAbs, d.dropped+d.histN+d.cur)
		}
		return
	case 7:
		d.state, d.inSixel = 0, false
		return
	}
	// state 0: ordinary byte.
	switch c {
	case 0x1b:
		d.state = 1
	case 0x0e, 0x0f:
		// SO/SI charset invoke — rendition, not position.
	case '\n':
		d.linefeed()
		d.col = 0
	case '\r':
		d.cancelWrap()
		d.col = 0
	case 0x08:
		d.cancelWrap()
		if d.col > 0 {
			d.col--
		}
	case '\t':
		d.moveTabStops(1, true)
	case 0x07:
	default:
		if c < 0x20 || c == 0x7f {
			break
		}
		if c < 0x80 {
			d.putRune(rune(c))
		} else if c >= 0xc2 && c <= 0xf4 {
			if c < 0xe0 {
				d.utfNeed, d.utfAcc, d.utfLen = 1, uint32(c&0x1f), 2
			} else if c < 0xf0 {
				d.utfNeed, d.utfAcc, d.utfLen = 2, uint32(c&0x0f), 3
			} else {
				d.utfNeed, d.utfAcc, d.utfLen = 3, uint32(c&0x07), 4
			}
		} else {
			d.putRune(0xFFFD)
		}
	}
}

// finish snapshots the mirror as the corpus: history, primary grid, then
// (if the stream ends on the alternate screen) the alt rows — oldest to
// newest, blanks as spaces, sixel origins rebased to corpus rows.
func (d *docBuilder) finish() *streamDoc {
	doc := &streamDoc{}
	for i := 0; i < d.histN; i++ {
		doc.lines = append(doc.lines, rowString(d.hist[(d.histTop+i)%mirrorHist]))
	}
	for i := 0; i < d.used; i++ {
		doc.lines = append(doc.lines, rowString(d.cells[i]))
	}
	if d.alt {
		for i := 0; i < d.altUsed; i++ {
			doc.lines = append(doc.lines, rowString(d.altCells[i]))
		}
	}
	for _, abs := range d.sixAbs {
		if idx := abs - d.dropped; idx >= 0 && idx < len(doc.lines) {
			doc.sixels = append(doc.sixels, findSpan{row: idx})
		}
	}
	return doc
}

// rowString renders one mirror row: never-written cells read as spaces
// (the kernel's own rule), and a trailing all-blank tail is kept — a
// match may legitimately sit in painted spaces.
func rowString(r []rune) string {
	if r == nil {
		return ""
	}
	out := make([]rune, len(r))
	for i, c := range r {
		if c == 0 {
			c = ' '
		}
		out[i] = c
	}
	return string(out)
}

// hardReset mirrors ESC c: the grid and its history go; prior sixel
// origins age out through `dropped` so they never alias new rows.
func (d *docBuilder) hardReset() {
	d.dropped += d.histN + d.used
	d.histN, d.histTop = 0, 0
	d.cells = [mirrorRows][]rune{}
	d.altCells = [mirrorRows][]rune{}
	d.used, d.cur, d.col = 1, 0, 0
	d.pendWrap, d.origin = false, false
	d.scrollT, d.scrollB = 0, mirrorRows-1
	d.tabs = [2]uint64{}
	for c := 8; c < mirrorCols; c += 8 {
		d.tabs[c/64] |= 1 << uint(c%64)
	}
}

// --- cursor + scroll model (links.go's mirror, rune-carrying) ---

func (d *docBuilder) cancelWrap() {
	d.pendWrap = false
	if d.col >= d.cols {
		d.col = d.cols - 1
	}
}

func (d *docBuilder) clearLine(r int) {
	d.cells[r] = nil
}

func (d *docBuilder) clearScreen() {
	if !d.alt {
		d.dropped += d.histN
		d.histN, d.histTop = 0, 0
	}
	d.cells = [mirrorRows][]rune{}
	d.used, d.cur, d.col = 1, 0, 0
	d.pendWrap = false
}

// grow materializes grid rows through `row` (inclusive): the kernel
// treats a write past `used` as clearing the intervening rows.
func (d *docBuilder) grow(row int) {
	for d.used <= row {
		d.cells[d.used] = nil
		d.used++
	}
}

func (d *docBuilder) linefeed() {
	d.pendWrap = false
	switch {
	case d.cur < d.scrollB:
		d.cur++
		d.grow(d.cur)
	case d.cur == d.scrollB:
		d.scrollRegionUp(1)
		if d.used <= d.cur {
			d.used = d.cur + 1
		}
	case d.cur+1 < mirrorRows:
		d.cur++
		d.grow(d.cur)
	default:
		d.scrollFullUp(1)
	}
}

func (d *docBuilder) reverseIndex() {
	d.pendWrap = false
	switch {
	case d.cur > d.scrollT:
		d.cur--
	case d.cur == d.scrollT:
		d.scrollRegionDown(1)
	case d.cur > 0:
		d.cur--
	}
}

func (d *docBuilder) scrollFullUp(n int) {
	count := n
	if count > d.used+mirrorHist {
		count = d.used + mirrorHist
	}
	for i := 0; i < count; i++ {
		d.pushHistory()
		for r := 0; r+1 < mirrorRows; r++ {
			d.cells[r] = d.cells[r+1]
		}
		d.clearLine(mirrorRows - 1)
	}
	d.used = mirrorRows
}

func (d *docBuilder) pushHistory() {
	if d.alt {
		return
	}
	if d.histN < mirrorHist {
		d.hist[(d.histTop+d.histN)%mirrorHist] = d.cells[0]
		d.histN++
		return
	}
	d.hist[d.histTop] = d.cells[0]
	d.histTop = (d.histTop + 1) % mirrorHist
	d.dropped++
}

func (d *docBuilder) scrollRegionUp(n int) {
	height := d.scrollB - d.scrollT + 1
	limit := height
	if d.scrollT == 0 {
		limit = height + mirrorHist
	}
	count := n
	if count > limit {
		count = limit
	}
	for i := 0; i < count; i++ {
		if d.scrollT == 0 {
			d.pushHistory()
		}
		for r := d.scrollT; r < d.scrollB; r++ {
			d.cells[r] = d.cells[r+1]
		}
		d.clearLine(d.scrollB)
	}
	if d.scrollT == 0 && d.used <= d.scrollB+1 {
		if d.used-count < 1 {
			d.used = 1
		} else {
			d.used -= count
		}
	}
}

func (d *docBuilder) scrollRegionDown(n int) {
	height := d.scrollB - d.scrollT + 1
	count := n
	if count > height {
		count = height
	}
	for r := d.scrollB + 1; r > d.scrollT+count; r-- {
		d.cells[r-1] = d.cells[r-1-count]
	}
	for r := d.scrollT; r < d.scrollT+count; r++ {
		d.clearLine(r)
	}
	if d.used <= d.cur {
		d.used = d.cur + 1
	}
	if d.scrollT == 0 && d.used <= d.scrollB+1 {
		d.used += count
		if d.used > d.scrollB+1 {
			d.used = d.scrollB + 1
		}
		if d.used <= d.cur {
			d.used = d.cur + 1
		}
	}
}

func (d *docBuilder) wrapForPrint() {
	d.pendWrap = false
	switch {
	case d.cur < d.scrollB:
		d.cur++
		if d.cur >= d.used {
			d.used = d.cur + 1
		}
		d.clearLine(d.cur)
	case d.cur == d.scrollB:
		d.scrollRegionUp(1)
		if d.used <= d.cur {
			d.used = d.cur + 1
		}
	case d.cur+1 < mirrorRows:
		d.cur++
		if d.cur >= d.used {
			d.used = d.cur + 1
		}
		d.clearLine(d.cur)
	default:
		d.scrollFullUp(1)
	}
	d.col = 0
}

func (d *docBuilder) moveCursor(row1, col1 uint16) {
	d.pendWrap = false
	row := int(row1) - 1
	if d.origin {
		if row > d.scrollB-d.scrollT {
			row = d.scrollB - d.scrollT
		}
		row += d.scrollT
	} else if row > mirrorRows-1 {
		row = mirrorRows - 1
	}
	d.grow(row)
	d.cur = row
	c := int(col1) - 1
	if c > d.cols-1 {
		c = d.cols - 1
	}
	d.col = c
}

func (d *docBuilder) setScrollRegion(top1, bottom1 uint16) {
	if top1 == 0 || bottom1 == 0 {
		return
	}
	top, bot := int(top1)-1, int(bottom1)-1
	if top >= bot || bot >= mirrorRows {
		return
	}
	d.scrollT, d.scrollB = top, bot
	d.pendWrap = false
	if d.origin {
		d.moveCursor(uint16(top), 1)
	} else {
		d.moveCursor(1, 1)
	}
}

// setAlternate mirrors swapAlternate + the enable-time clear.
func (d *docBuilder) setAlternate(on bool) {
	if d.alt == on {
		return
	}
	d.cells, d.altCells = d.altCells, d.cells
	d.used, d.altUsed = d.altUsed, d.used
	d.cur, d.altCur = d.altCur, d.cur
	d.col, d.altCol = d.altCol, d.col
	d.pendWrap, d.altPendWrap = d.altPendWrap, d.pendWrap
	d.scrollT, d.altScrollT = d.altScrollT, d.scrollT
	d.scrollB, d.altScrollB = d.altScrollB, d.scrollB
	d.origin, d.altOrigin = d.altOrigin, d.origin
	d.savCur, d.altSavCur = d.altSavCur, d.savCur
	d.savCol, d.altSavCol = d.altSavCol, d.savCol
	d.savPendWrap, d.altSavPendWrap = d.altSavPendWrap, d.savPendWrap
	d.savValid, d.altSavValid = d.altSavValid, d.savValid
	d.alt = on
	if on {
		for c := 8; c < mirrorCols; c += 8 {
			d.altTabs[c/64] |= 1 << uint(c%64)
		}
		d.clearScreen()
		d.savValid = false
		d.scrollT, d.scrollB = 0, mirrorRows-1
		d.origin, d.pendWrap = false, false
	}
}

// --- per-cell write ---

func (d *docBuilder) setCell(r, c int, cp rune) {
	if d.cells[r] == nil {
		d.cells[r] = make([]rune, mirrorCols)
	}
	d.cells[r][c] = cp
}

func (d *docBuilder) putRune(cp rune) {
	w := charWidth(cp)
	if w == 0 {
		// Combining/ignorable: overlay or drop — no cell, no cursor move.
		return
	}
	d.grow(d.cur)
	if d.pendWrap {
		d.wrapForPrint()
	} else if w == 2 && d.col+2 > d.cols {
		if d.autowrap {
			d.wrapForPrint()
		} else {
			w = 1 // refused pair paints one replacement cell
		}
	}
	d.setCell(d.cur, d.col, cp)
	if w == 2 && d.col+1 < mirrorCols {
		d.setCell(d.cur, d.col+1, 0)
	}
	d.lastRune = cp
	end := d.col + w
	if end == d.cols {
		if d.autowrap {
			d.col = d.cols
		} else {
			d.col = d.cols - 1
		}
		d.pendWrap = d.autowrap
	} else {
		d.col = end
		d.pendWrap = false
	}
}

func (d *docBuilder) repeatLast(n uint16) {
	if d.lastRune == 0 {
		return
	}
	for i := 0; i < int(n); i++ {
		d.putRune(d.lastRune)
	}
}

// --- CSI dispatch (text-affecting finals; the rest are consumed) ---

func (d *docBuilder) csiP(i int, fallback uint16) uint16 {
	if i >= d.csiN {
		return fallback
	}
	if v := d.csi[i]; v != 0 {
		return v
	}
	return fallback
}

func (d *docBuilder) dispatchCSI(final byte) {
	p0 := d.csiP(0, 0)
	if d.csiPriv {
		switch p0 {
		case 6:
			if final == 'h' || final == 'l' {
				d.origin = final == 'h'
				row := 1
				if d.origin {
					row = d.scrollT + 1
				}
				d.moveCursor(uint16(row), 1)
				d.pendWrap = false
			}
		case 7:
			if final == 'h' || final == 'l' {
				d.autowrap = final == 'h'
				d.cancelWrap()
			}
		case 47, 1049:
			if final == 'h' || final == 'l' {
				d.setAlternate(final == 'h')
			}
		case 1048:
			if final == 'h' {
				d.savCur, d.savCol, d.savPendWrap, d.savValid = d.cur, d.col, d.pendWrap, true
			}
			if final == 'l' && d.savValid {
				d.cur, d.col, d.pendWrap = d.savCur, d.savCol, d.savPendWrap
			}
		}
		return
	}
	switch final {
	case 'H', 'f':
		d.moveCursor(d.csiP(0, 1), d.csiP(1, 1))
	case 'J':
		d.eraseDisplay(p0)
	case 'K':
		d.eraseLine(p0)
	case 'A':
		d.cancelWrap()
		if d.cur-int(d.csiP(0, 1)) < 0 {
			d.cur = 0
		} else {
			d.cur -= int(d.csiP(0, 1))
		}
	case 'B':
		d.cancelWrap()
		d.cur += int(d.csiP(0, 1))
		if d.cur > mirrorRows-1 {
			d.cur = mirrorRows - 1
		}
	case 'C':
		d.cancelWrap()
		d.col += int(d.csiP(0, 1))
		if d.col > d.cols-1 {
			d.col = d.cols - 1
		}
	case 'D':
		d.cancelWrap()
		if d.col-int(d.csiP(0, 1)) < 0 {
			d.col = 0
		} else {
			d.col -= int(d.csiP(0, 1))
		}
	case 'E':
		d.cancelWrap()
		d.cur += int(d.csiP(0, 1))
		if d.cur > mirrorRows-1 {
			d.cur = mirrorRows - 1
		}
		d.col = 0
	case 'F':
		d.cancelWrap()
		if d.cur-int(d.csiP(0, 1)) < 0 {
			d.cur = 0
		} else {
			d.cur -= int(d.csiP(0, 1))
		}
		d.col = 0
	case 'G', '`':
		d.cancelWrap()
		d.col = int(d.csiP(0, 1)) - 1
		if d.col > d.cols-1 {
			d.col = d.cols - 1
		}
		if d.col < 0 {
			d.col = 0
		}
	case 'd':
		d.moveCursor(d.csiP(0, 1), uint16(d.col+1))
	case 'r':
		d.setScrollRegion(d.csiP(0, 1), d.csiP(1, mirrorRows))
	case 'b':
		d.repeatLast(d.csiP(0, 1))
	case '@':
		d.insertChars(d.csiP(0, 1))
	case 'P':
		d.deleteChars(d.csiP(0, 1))
	case 'X':
		d.eraseChars(d.csiP(0, 1))
	case 'L':
		d.insertLines(d.csiP(0, 1))
	case 'M':
		d.deleteLines(d.csiP(0, 1))
	case 'S':
		d.scrollRegionUp(int(d.csiP(0, 1)))
	case 'T':
		if d.csiN == 1 {
			d.scrollRegionDown(int(d.csiP(0, 1)))
		}
	case 'g':
		switch p0 {
		case 0:
			d.tabStop(d.col, 2)
		case 3:
			if d.alt {
				d.altTabs = [2]uint64{}
			} else {
				d.tabs = [2]uint64{}
			}
		}
	case 'I':
		d.moveTabStops(d.csiP(0, 1), true)
	case 'Z':
		d.moveTabStops(d.csiP(0, 1), false)
	}
}

func (d *docBuilder) eraseLine(mode uint16) {
	d.cancelWrap()
	var start, end int
	switch mode {
	case 1:
		start, end = 0, d.col+1
	default:
		start = d.col
		if mode == 2 {
			start = 0
		}
		end = d.cols
	}
	if start > d.cols {
		start = d.cols
	}
	if end > d.cols {
		end = d.cols
	}
	for c := start; c < end; c++ {
		if d.cells[d.cur] != nil {
			d.cells[d.cur][c] = 0
		}
	}
}

func (d *docBuilder) eraseDisplay(mode uint16) {
	switch mode {
	case 1:
		for r := 0; r < d.cur; r++ {
			d.clearLine(r)
		}
		d.eraseLine(1)
	case 2:
		d.clearScreen()
	case 3:
		if !d.alt {
			d.dropped += d.histN
			d.histN, d.histTop = 0, 0
		}
	default:
		d.eraseLine(0)
		for r := d.cur + 1; r < d.used; r++ {
			d.clearLine(r)
		}
	}
}

func (d *docBuilder) insertChars(n uint16) {
	d.cancelWrap()
	if d.cur >= d.used || d.cells[d.cur] == nil {
		return
	}
	count := int(n)
	if count > d.cols {
		count = d.cols
	}
	for c := d.cols - 1; c >= d.col+count; c-- {
		d.cells[d.cur][c] = d.cells[d.cur][c-count]
	}
	for c := d.col; c < d.col+count && c < d.cols; c++ {
		d.cells[d.cur][c] = 0
	}
}

func (d *docBuilder) deleteChars(n uint16) {
	d.cancelWrap()
	if d.cur >= d.used || d.cells[d.cur] == nil {
		return
	}
	end := d.col + int(n)
	if end > d.cols {
		end = d.cols
	}
	m := end - d.col
	for c := d.col; c+m < d.cols; c++ {
		d.cells[d.cur][c] = d.cells[d.cur][c+m]
	}
	for c := d.cols - m; c < d.cols; c++ {
		d.cells[d.cur][c] = 0
	}
}

func (d *docBuilder) eraseChars(n uint16) {
	d.cancelWrap()
	if d.cur >= d.used || d.cells[d.cur] == nil {
		return
	}
	end := d.col + int(n)
	if end > d.cols {
		end = d.cols
	}
	for c := d.col; c < end; c++ {
		d.cells[d.cur][c] = 0
	}
}

func (d *docBuilder) insertLines(n uint16) {
	if d.cur < d.scrollT || d.cur > d.scrollB || d.cur >= d.used {
		return
	}
	d.cancelWrap()
	cnt := int(n)
	if cnt > d.scrollB-d.cur+1 {
		cnt = d.scrollB - d.cur + 1
	}
	for r := d.scrollB + 1; r > d.cur+cnt; r-- {
		d.cells[r-1] = d.cells[r-1-cnt]
	}
	for r := d.cur; r < d.cur+cnt; r++ {
		d.clearLine(r)
	}
	d.col = 0
	if d.used <= d.scrollB+1 {
		d.used += cnt
		if d.used > d.scrollB+1 {
			d.used = d.scrollB + 1
		}
	}
	if d.used <= d.cur {
		d.used = d.cur + 1
	}
}

func (d *docBuilder) deleteLines(n uint16) {
	if d.cur < d.scrollT || d.cur > d.scrollB || d.cur >= d.used {
		return
	}
	d.cancelWrap()
	m := int(n)
	if m > d.scrollB-d.cur+1 {
		m = d.scrollB - d.cur + 1
	}
	for r := d.cur; r+m <= d.scrollB; r++ {
		d.cells[r] = d.cells[r+m]
	}
	for r := d.scrollB + 1 - m; r <= d.scrollB; r++ {
		d.clearLine(r)
	}
	d.col = 0
	if d.used <= d.scrollB+1 {
		d.used -= m
		if d.used < 1 || d.used < d.cur {
			d.used = 1
			if d.cur > 0 {
				d.used = d.cur
			}
		}
	}
}

// --- tab stops (kernel M80d semantics) ---

func (d *docBuilder) tabStop(c int, mode int) bool {
	if c >= d.cols {
		return false
	}
	tb := &d.tabs
	if d.alt {
		tb = &d.altTabs
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

func (d *docBuilder) moveTabStops(count uint16, forward bool) {
	d.cancelWrap()
	for i := 0; i < int(count); i++ {
		if forward {
			c := d.col + 1
			for c < d.cols && !d.tabStop(c, 0) {
				c++
			}
			if c > d.cols-1 {
				c = d.cols - 1
			}
			d.col = c
			if d.col == d.cols-1 && !d.tabStop(d.col, 0) {
				break
			}
		} else {
			c := d.col
			for c > 0 {
				c--
				if d.tabStop(c, 0) {
					break
				}
			}
			d.col = c
			if c == 0 && !d.tabStop(0, 0) {
				break
			}
		}
	}
}

// --- UTF-8 (kernel M73a-1 decode, corpus-relevant) ---

func (d *docBuilder) utfContinue(b byte) {
	d.utfAcc = d.utfAcc<<6 | uint32(b&0x3f)
	d.utfNeed--
	if d.utfNeed > 0 {
		return
	}
	cp := d.utfAcc
	ok := false
	switch d.utfLen {
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
	d.putRune(rune(cp))
}
