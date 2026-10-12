// GOTABWM.ELF — the pointer-first Apps affordance and Ctrl+Space share one
// APPS.TXT catalog, exec path and seat-owned input sink.
//
// #2054 (the Quicksilver upgrade): the palette is no longer a centred panel —
// it is a vertical strip docked to the scanout's LEFT edge, the sexiburger
// emblem on top, the "Where do you want to go today?" prompt under it, the
// filter field under that, and a ranked single-column result list below.
// The emblem is the real mascot raster (image/WALLPAPER.QOI-style staging:
// /host/SEXIBURGER.QOI decoded by the virelai/webrender/qoi leaf), not a
// rect-drawn approximation, and the chrome's god-menu button and start
// surface carry the same mark so hotkey and pointer converge on one path.
//
// M82a (#1768): the row the manifest gives is the row that launches. The
// `argv=` field's fixed arguments ride the exec, and the decode receipt says
// what the manifest said — how many rows, the highest row version, and how
// many rows spoke each trailing key (a zero is reported, not hidden).
package main

import (
	"unsafe"

	"virelai/theme"
	"virelai/vi"
	"virelai/webrender/qoi"
)

const (
	MarkerLaunchOpen    = "gotabwm: launcher open n="
	MarkerLaunchFilter  = "gotabwm: launcher filter q="
	MarkerLaunchExec    = "gotabwm: launcher exec "
	MarkerLaunchDismiss = "gotabwm: launcher dismiss"
	MarkerLaunchMissing = "gotabwm: launcher missing "
	MarkerLaunchEmblem  = "gotabwm: launcher emblem "
	MarkerAppsDecode    = "gotabwm: apps decode n="

	hidUsageSpace  uint8 = 0x2C
	hidUsageEnter  uint8 = 0x28
	hidUsageEscape uint8 = 0x29
	hidUsageBksp   uint8 = 0x2A
	hidUsageDown   uint8 = 0x51
	hidUsageUp     uint8 = 0x52

	// The strip: docked at the left edge, full scanout height. The seat's
	// 2px accent rule marks the edge facing the desktop, the same mark the
	// clock panel carries on its left.
	launchX    = 0
	launchY    = 0
	launchW    = 264
	launchRule = 2

	// Header block inside the strip: emblem, prompt, filter field, the
	// error/status line, then the results list at launchHdr.
	launchAvatarY = 16
	launchEmblem  = 64 // the staged mascot_64x64.qoi raster
	launchPromptY = launchAvatarY + launchEmblem + 8
	launchFieldY  = launchPromptY + 16
	launchFieldH  = 20
	launchErrY    = launchFieldY + launchFieldH + 4
	launchHdr     = launchErrY + 12

	// launchPrompt is the AC-B1 prompt text — byte-identical by card.
	launchPrompt = "Where do you want to go today?"

	filterMax = 24

	// The emblem's staging path and decode budget: /host/SEXIBURGER.QOI is
	// the repo's existing mascot_64x64.qoi fixture, copied to the share by
	// gate-run/session.sh exactly like APPS.TXT and WALLPAPER.QOI.
	emblemPath     = "/host/SEXIBURGER.QOI"
	emblemMaxBytes = 65536
	emblemMaxDim   = 256
	emblemMaxPix   = 256 * 256
)

type launcherState struct {
	open      bool
	catalog   []AppEntry
	filter    string
	filtered  []int
	sel       int
	first     int // first visible filtered row
	reasons   []string
	err       string
	sink      uint32
	prior     uint32
	painted   bool
	width     int
	height    int
	launching bool

	// emblem is the decoded mascot raster, decoded once lazily (the
	// god-menu button paints it every tick, long before the first
	// summon). tried gates the one-shot marker and the retry: a share
	// that lacks the file is named once per boot, not once per paint.
	// icon16/icon32 memoize the two scaled variants chrome paints per
	// tick. It lives on launcherState so the seat-state snapshot tests
	// already take carries it.
	emblem emblemState
}

type emblemState struct {
	tried  bool
	w, h   int
	pix    []uint32
	icon16 []uint32
	icon32 []uint32
}

var launch launcherState

// readAppsFile is the share-file read seam: APPS.TXT at summon, and since
// #2054 the SEXIBURGER.QOI emblem — one seam, both fixtures a host test
// stages without a second indirection.
var readAppsFile = vi.ReadFileAll

func launcherEmblem() []uint32 {
	em := &launch.emblem
	if !em.tried {
		em.tried = true
		body, r := readAppsFile(emblemPath, emblemMaxBytes)
		if r >= 0 && body != nil {
			w, h, pix, err := qoi.Decode(body, emblemMaxDim, emblemMaxPix)
			if err == nil {
				em.w, em.h, em.pix = w, h, pix
			}
		}
		if em.pix != nil {
			vi.ConsoleLine(MarkerLaunchEmblem + "qoi " +
				vi.Itoa64(int64(em.w)) + "x" + vi.Itoa64(int64(em.h)))
		} else {
			vi.ConsoleLine(MarkerLaunchEmblem + "unavailable")
		}
	}
	return em.pix
}

// emblemScaled box-filters the mascot by an integer factor, premultiplied,
// so its alpha edges shrink honestly instead of fringing — the 16px chrome
// icon and the 32px start-surface mark both come from the one decode, and
// each factor is computed once per boot.
func emblemScaled(factor int) []uint32 {
	em := &launch.emblem
	switch factor {
	case 2:
		if em.icon32 != nil {
			return em.icon32
		}
	case 4:
		if em.icon16 != nil {
			return em.icon16
		}
	}
	src := launcherEmblem()
	if src == nil || factor < 1 || em.w%factor != 0 || em.h%factor != 0 {
		return nil
	}
	out := emblemBoxScale(src, factor)
	switch factor {
	case 2:
		em.icon32 = out
	case 4:
		em.icon16 = out
	}
	return out
}

func emblemBoxScale(src []uint32, factor int) []uint32 {
	em := &launch.emblem
	dw, dh := em.w/factor, em.h/factor
	out := make([]uint32, dw*dh)
	n := factor * factor
	for ry := 0; ry < dh; ry++ {
		for rx := 0; rx < dw; rx++ {
			var sa, sr, sg, sb int
			for dy := 0; dy < factor; dy++ {
				for dx := 0; dx < factor; dx++ {
					p := src[(ry*factor+dy)*em.w+rx*factor+dx]
					a := int(p >> 24)
					sa += a
					sr += a * int(p>>16&0xff)
					sg += a * int(p>>8&0xff)
					sb += a * int(p&0xff)
				}
			}
			a := sa / n
			if a == 0 {
				continue
			}
			out[ry*dw+rx] = uint32(a)<<24 | uint32(sr/sa)<<16 | uint32(sg/sa)<<8 | uint32(sb/sa)
		}
	}
	return out
}

// blitImage composites an 0xAARRGGBB raster source-over onto the scanout
// words — the same byte order fillRect writes, so opaque source pixels keep
// the X byte opaque like every other seat store.
func blitImage(pix []uint32, stride, maxH int, src []uint32, sw, sh, x, y int) int {
	if src == nil || stride <= 0 {
		return 0
	}
	written := 0
	for row := 0; row < sh; row++ {
		dy := y + row
		if dy < 0 || dy >= maxH {
			continue
		}
		for col := 0; col < sw; col++ {
			dx := x + col
			if dx < 0 || dx >= stride {
				continue
			}
			s := src[row*sw+col]
			a := int(s >> 24)
			if a == 0 {
				continue
			}
			di := dy*stride + dx
			if a == 255 {
				pix[di] = s | 0xff000000
				written++
				continue
			}
			d := pix[di]
			r := (int(s>>16&0xff)*a + int(d>>16&0xff)*(255-a) + 127) / 255
			g := (int(s>>8&0xff)*a + int(d>>8&0xff)*(255-a) + 127) / 255
			b := (int(s&0xff)*a + int(d&0xff)*(255-a) + 127) / 255
			pix[di] = 0xff000000 | uint32(r)<<16 | uint32(g)<<8 | uint32(b)
			written++
		}
	}
	return written
}

func appUnavailable(e AppEntry) string {
	bin := e.Bin
	if bin == "TABWM.BIN" || bin == "GOTABWM.ELF" || bin == "WND.BIN" {
		return "Seat: use settings wm"
	}
	h, r := openFile("/host/"+bin, vi.ModeRead)
	if r < 0 {
		return "Binary not staged"
	}
	vi.FileClose(uint32(h))
	return ""
}

func (l *launcherState) rowH() int {
	h := theme.Current.PadLG + theme.Current.PadMD
	if h < 20 {
		h = 20
	}
	return h
}

// panelH is the strip's height: the full scanout, always — a docked edge
// panel does not size to content.
func (l *launcherState) panelH() int {
	return vi.ScanoutHeight
}

func (l *launcherState) refresh() {
	l.painted = false
	l.filtered = rankApps(l.catalog, l.filter)
	if l.sel >= len(l.filtered) {
		l.sel = len(l.filtered) - 1
	}
	if l.sel < 0 {
		l.sel = 0
	}
	l.first = 0
	l.keepSelectionVisible()
}

func (l *launcherState) visibleRows() int {
	return (l.panelH() - launchHdr - theme.Current.PadMD) / l.rowH()
}

func (l *launcherState) keepSelectionVisible() {
	first := l.first
	n := l.visibleRows()
	if n < 1 {
		return
	}
	if l.sel < l.first {
		l.first = l.sel
	}
	if l.sel >= l.first+n {
		l.first = l.sel - n + 1
	}
	if l.first != first {
		l.painted = false
	}
}

// A row is only a target where its complete painted rectangle exists.
// Header pixels — emblem, prompt, filter field, the error line — are not
// targets, exactly like the old title band was not.
func (l *launcherState) rowRect(i, width, height int) (x, y, w, h int, ok bool) {
	x, y = launchX+theme.Current.PadMD, launchY+launchHdr+(i-l.first)*l.rowH()
	w, h = launchW-2*theme.Current.PadMD-launchRule, l.rowH()-theme.Current.PadXS
	ok = i >= l.first && i < len(l.filtered) && i < l.first+l.visibleRows() &&
		w > 0 && h >= 8 && x+w <= width && y+l.rowH() <= height
	return
}

func (l *launcherState) selected() (AppEntry, bool) {
	if l.sel < 0 || l.sel >= len(l.filtered) {
		return AppEntry{}, false
	}
	i := l.filtered[l.sel]
	if i < 0 || i >= len(l.catalog) {
		return AppEntry{}, false
	}
	return l.catalog[i], true
}

func openLauncher() {
	if launch.open {
		dismissLauncher()
		return
	}
	launch.err = ""
	launch.catalog, launch.reasons, launch.filtered = nil, nil, nil
	launch.filter, launch.sel, launch.first = "", 0, 0
	launch.painted, launch.launching = false, false
	launch.prior, _ = tabs.Focused()
	if !acquireLauncherFocus() {
		vi.ConsoleLine("gotabwm: launcher unavailable " + launch.err)
		// Never claim a modal menu while an app still owns keyboard focus.
		// The always-visible button paints the failed-open error instead.
		launch.open = launch.sink != 0
		return
	}
	body, r := readAppsFile(appsPath, appsMaxBytes)
	if r < 0 || body == nil {
		launch.catalog = nil
		launch.err = "APPS.TXT unavailable"
	} else {
		launch.catalog = parseAppsTXT(string(body))
	}
	launch.filter = ""
	launch.sel = 0
	launch.first = 0
	launch.painted = false
	launch.reasons = make([]string, len(launch.catalog))
	for i, e := range launch.catalog {
		launch.reasons[i] = appUnavailable(e)
	}
	launch.open = true
	launch.refresh()
	// The manifest's own report, before the launcher's: a reader that
	// silently ignored every v2 field would still print `launcher open n=14`,
	// so the decode numbers are what a gate reads to know the v2 fields were
	// decoded rather than skipped.
	s := SummarizeApps(launch.catalog)
	vi.ConsoleLine(MarkerAppsDecode + vi.Itoa64(int64(s.Rows)) +
		" v=" + vi.Itoa64(int64(s.Schema)) +
		" schema=" + vi.Itoa64(int64(appsSchemaVersion)) +
		" argv=" + vi.Itoa64(int64(s.Argv)) +
		" caps=" + vi.Itoa64(int64(s.Caps)) +
		" opens=" + vi.Itoa64(int64(s.Opens)))
	vi.ConsoleLine(MarkerLaunchOpen + vi.Itoa64(int64(len(launch.catalog))))
	vi.ConsoleLine(MarkerLaunchFilter + launch.filter + " n=" + vi.Itoa64(int64(len(launch.filtered))))
	// The emblem is warm by now (the chrome button decoded it on its first
	// paint), but calling it here pins the raster's presence to a summon:
	// the one-shot marker still names what the header will paint.
	_ = launcherEmblem()
}

func dismissLauncher() {
	if !launch.open {
		return
	}
	if !releaseLauncherFocus(true) {
		return
	}
	finishLauncher()
}

func finishLauncher() {
	launch.open = false
	launch.filter = ""
	launch.painted = false
	vi.ConsoleLine(MarkerLaunchDismiss)
}

func emitLaunchFilter() {
	vi.ConsoleLine(MarkerLaunchFilter + launch.filter + " n=" + vi.Itoa64(int64(len(launch.filtered))))
}

func execSelected() {
	if launch.launching {
		if releaseLauncherFocus(false) {
			finishLauncher()
		}
		return
	}
	e, ok := launch.selected()
	if !ok || e.Bin == "" {
		return
	}
	if !ensureLauncherFocus() {
		return
	}
	ci := launch.filtered[launch.sel]
	if ci < len(launch.reasons) && launch.reasons[ci] != "" {
		launch.err = launch.reasons[ci]
		return
	}
	bin := e.Bin
	// Non-app seat entries are refused even if a caller skipped the probe.
	if bin == "TABWM.BIN" || bin == "GOTABWM.ELF" || bin == "WND.BIN" {
		launch.err = "Seat: use settings wm"
		return
	}
	// Preserve the manifest's fixed argv; v1 rows still launch with argc=0.
	_, err := execApp(bin, e.Args...)
	if err != nil {
		vi.ConsoleLine(MarkerLaunchMissing + e.Bin)
		launch.err = "Launch failed: " + bin
		return
	}
	if len(e.Args) > 0 {
		vi.ConsoleLine(MarkerLaunchExec + e.Bin + " argv=" + joinSpace(e.Args))
	} else {
		vi.ConsoleLine(MarkerLaunchExec + e.Bin)
	}
	launch.launching = true
	if releaseLauncherFocus(false) {
		finishLauncher()
	}
}

// joinSpace renders a decoded argv for the marker. It is the inverse of the
// `argv=` split, so the marker and the manifest read the same.
func joinSpace(args []string) string {
	out := ""
	for i, a := range args {
		if i > 0 {
			out += " "
		}
		out += a
	}
	return out
}

// rankApps is the #2054 result model, three tiers over the catalog:
//
//  1. rows whose display name starts with the query,
//  2. rows the query is a substring of (label or binary, the old flat
//     match — apps.go's asciiContainsFold, unchanged),
//  3. fuzzy matches: the query as a subsequence of the label or of the
//     row's `argv=` — Quicksilver's type-a-few-letters reach.
//
// Tiers concatenate in manifest order, so a fixed query over a fixed
// catalog ranks identically on every paint (AC-C2).
func rankApps(catalog []AppEntry, q string) []int {
	if q == "" {
		idx := make([]int, 0, len(catalog))
		for i := range catalog {
			idx = append(idx, i)
		}
		return idx
	}
	var prefix, sub, fuzzy []int
	for i, e := range catalog {
		switch {
		case asciiPrefixFold(e.Label, q):
			prefix = append(prefix, i)
		case asciiContainsFold(e.Label, q) || asciiContainsFold(e.Bin, q):
			sub = append(sub, i)
		case asciiSubseqFold(e.Label, q) || asciiSubseqFold(joinSpace(e.Args), q):
			fuzzy = append(fuzzy, i)
		}
	}
	return append(append(prefix, sub...), fuzzy...)
}

// asciiPrefixFold is tier 1's predicate: s starts with q, A–Z folded.
func asciiPrefixFold(s, q string) bool {
	if len(q) > len(s) {
		return false
	}
	for i := 0; i < len(q); i++ {
		if asciiFold(s[i]) != asciiFold(q[i]) {
			return false
		}
	}
	return true
}

// asciiSubseqFold is tier 3's predicate: every rune of q appears in s, in
// order, not necessarily adjacent ("clc" reaches "Calculator" — well, it
// would reach "64-bit Calc" through the substring tier first, which is the
// point of ranking: fuzzy is a floor, not a ceiling).
func asciiSubseqFold(s, q string) bool {
	j := 0
	for i := 0; i < len(s) && j < len(q); i++ {
		if asciiFold(s[i]) == asciiFold(q[j]) {
			j++
		}
	}
	return j == len(q)
}

// handleLauncherKey owns the launcher's MODAL keys. M82c (#1770): the
// summon chord itself (ctrl+space) is a registry row — hid.go's table
// dispatch opens the launcher with it when the launcher is closed; this
// handler owns only what happens while it is open, including the
// re-summon below.
func handleLauncherKey(e vi.Event) bool {
	usage := uint8(e.Arg0)
	ctrl := e.Flags&vi.ModCtrl != 0
	shift := e.Flags&vi.ModShift != 0
	alt := e.Flags&vi.ModAlt != 0
	if !launch.open {
		return false
	}
	if usage == hidUsageEscape {
		// #2054 AC-C4: Esc is a two-step dismiss. A non-empty filter
		// clears first — the keystroke nobody meant for the app still
		// cannot reach it — and only an already-clear filter dismisses.
		if launch.filter != "" {
			launch.filter = ""
			launch.refresh()
			emitLaunchFilter()
		} else {
			dismissLauncher()
		}
		return true
	}
	if !ensureLauncherFocus() {
		return true
	}
	if alt {
		return true // swallow while modal
	}
	switch usage {
	case hidUsageEnter:
		execSelected()
		return true
	case hidUsageUp, hidUsageDown:
		if usage == hidUsageUp && launch.sel > 0 {
			launch.sel--
		}
		if usage == hidUsageDown && launch.sel+1 < len(launch.filtered) {
			launch.sel++
		}
		launch.keepSelectionVisible()
		return true
	case hidUsageBksp:
		if len(launch.filter) > 0 {
			launch.filter = launch.filter[:len(launch.filter)-1]
			launch.refresh()
			emitLaunchFilter()
		}
		return true
	}
	// Type-to-filter even if Ctrl is still down from the summon chord
	// (virtio HID keeps the modifier on the next report).
	if c, ok := hidUsageChar(usage); ok {
		if usage == hidUsageSpace && ctrl {
			// The summon chord while the launcher is open re-opens it —
			// the same behaviour the old top-of-handler summon had for
			// both open and closed (the closed case now dispatches
			// through the registry row). ctrl+shift+space stays
			// swallowed, exactly as before.
			if shift {
				return true
			}
			openLauncher()
			return true
		}
		if len(launch.filter) < filterMax {
			launch.filter += string(c)
			launch.refresh()
			emitLaunchFilter()
		}
		return true
	}
	return true
}

func hidUsageChar(usage uint8) (byte, bool) {
	if usage >= 0x04 && usage <= 0x1d {
		return 'a' + (usage - 0x04), true
	}
	if usage >= 0x1e && usage <= 0x26 {
		return '1' + (usage - 0x1e), true
	}
	if usage == 0x27 {
		return '0', true
	}
	if usage == hidUsageSpace {
		return ' ', true
	}
	if usage == 0x2d {
		return '-', true
	}
	if usage == 0x37 {
		return '.', true
	}
	return 0, false
}

func launchRowAt(px, py uint32) (int, bool) {
	if !launch.open || !launch.painted {
		return 0, false
	}
	x, y := int(px), int(py)
	if y < launchY+launchHdr {
		return 0, false
	}
	row := launch.first + (y-launchY-launchHdr)/launch.rowH()
	// The scanout is fixed in the guest. Tests can also pin a clipped
	// paint; hit-testing then uses precisely that paint's dimensions.
	width, height := launch.width, launch.height
	rx, ry, rw, rh, ok := launch.rowRect(row, width, height)
	return row, ok && x >= rx && x < rx+rw && y >= ry && y < ry+rh
}

func paintLauncher(scan []byte, width, height int) int {
	launch.painted = false
	if !launch.open || width <= 0 || height <= 0 || len(scan) < 4 {
		return 0
	}
	pixN := len(scan) / 4
	pix := unsafe.Slice((*uint32)(unsafe.Pointer(&scan[0])), pixN)
	maxH := pixN / width
	if maxH > height {
		maxH = height
	}
	if maxH <= 0 {
		return 0
	}
	tok := theme.Current
	launch.painted, launch.width, launch.height = true, width, maxH
	written := fillRect(pix, width, maxH, launchX, launchY, launchW, maxH, tok.Surface)
	written += fillRect(pix, width, maxH, launchX+launchW-launchRule, launchY, launchRule, maxH, tok.Accent)
	// The emblem is the seat's front door: the real sexiburger raster,
	// centred in the strip. A share without it gets a bordered box and
	// the marker's `unavailable`, never a fabricated mascot.
	if src := launcherEmblem(); src != nil {
		written += blitImage(pix, width, maxH, src, launch.emblem.w, launch.emblem.h,
			launchX+(launchW-launchRule-launch.emblem.w)/2, launchY+launchAvatarY)
	} else {
		ex, ey := launchX+(launchW-launchRule-launchEmblem)/2, launchY+launchAvatarY
		written += fillRect(pix, width, maxH, ex, ey, launchEmblem, launchEmblem, tok.Surface)
		written += fillRect(pix, width, maxH, ex, ey, launchEmblem, tok.BorderW, tok.Border)
		written += fillRect(pix, width, maxH, ex, ey+launchEmblem-tok.BorderW, launchEmblem, tok.BorderW, tok.Border)
		written += fillRect(pix, width, maxH, ex, ey, tok.BorderW, launchEmblem, tok.Border)
		written += fillRect(pix, width, maxH, ex+launchEmblem-tok.BorderW, ey, tok.BorderW, launchEmblem, tok.Border)
		written += drawText8(pix, width, maxH, ex+24, ey+28, "SB", tok.InkMuted)
	}
	written += drawText8(pix, width, maxH, launchX+tok.PadMD, launchY+launchPromptY, launchPrompt, tok.Ink)
	// The filter field: an inset box, the query, then the caret — the
	// keystroke sink made visible.
	fx, fy, fw := launchX+tok.PadMD, launchY+launchFieldY, launchW-2*tok.PadMD-launchRule
	written += fillRect(pix, width, maxH, fx, fy, fw, launchFieldH, tok.Bg)
	written += fillRect(pix, width, maxH, fx, fy, fw, tok.BorderW, tok.Border)
	written += fillRect(pix, width, maxH, fx, fy+launchFieldH-tok.BorderW, fw, tok.BorderW, tok.Border)
	written += fillRect(pix, width, maxH, fx, fy, tok.BorderW, launchFieldH, tok.Border)
	written += fillRect(pix, width, maxH, fx+fw-tok.BorderW, fy, tok.BorderW, launchFieldH, tok.Border)
	q := launchText(launch.filter, (fw-14)/8)
	written += drawText8(pix, width, maxH, fx+6, fy+6, q, tok.Ink)
	written += fillRect(pix, width, maxH, fx+8+len(q)*8, fy+6, 1, 8, tok.Caret)
	if launch.err != "" {
		written += drawText8(pix, width, maxH, launchX+tok.PadMD, launchY+launchErrY, launchText(launch.err, 30), tok.Danger)
	}
	if len(launch.filtered) == 0 {
		written += drawText8(pix, width, maxH, launchX+tok.PadMD, launchY+launchHdr+6, "No matching apps", tok.InkMuted)
	}
	for i := launch.first; i < len(launch.filtered); i++ {
		x, y, w, rh, ok := launch.rowRect(i, width, maxH)
		if !ok {
			break
		}
		ci := launch.filtered[i]
		if ci < 0 || ci >= len(launch.catalog) {
			continue
		}
		bg := tok.Surface
		if i == launch.sel {
			bg = tok.Selection
		}
		written += fillRect(pix, width, maxH, x, y, w, rh, bg)
		ink := tok.Ink
		reason := ""
		if ci < len(launch.reasons) {
			reason = launch.reasons[ci]
		}
		if reason != "" {
			// A dimmed row names its own refusal: label and reason on
			// two lines inside the one row, never a launchable facade.
			ink = tok.InkMuted
			written += drawText8(pix, width, maxH, x+6, y+3, launchText(launch.catalog[ci].Label, 28), ink)
			written += drawText8(pix, width, maxH, x+6, y+13, launchText(reason, 28), tok.Muted)
			continue
		}
		written += drawText8(pix, width, maxH, x+6, y+6, launchText(launch.catalog[ci].Label, 29), ink)
	}
	return written
}

func launchText(s string, max int) string {
	if len(s) > max {
		return s[:max-3] + "..."
	}
	return s
}
