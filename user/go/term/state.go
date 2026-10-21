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
