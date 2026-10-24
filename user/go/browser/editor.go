package main

import (
	"strings"
	"unicode/utf8"

	"virelai/appkit"
	"virelai/layout"
	"virelai/vi"
	"virelai/webrender"
	"virelai/widgets"
)

type textEditor struct {
	text      string
	cursor    int
	cap       int
	selectAll bool
}

func (e *textEditor) reset(text string, capn int) {
	if len(text) > capn {
		text = text[:capn]
		for !utf8.ValidString(text) {
			text = text[:len(text)-1]
		}
	}
	e.text, e.cursor, e.cap, e.selectAll = text, len(text), capn, true
}

func (e *textEditor) key(usage, symbol uint32, flags uint16) bool {
	ctrl := flags&vi.ModCtrl != 0
	if ctrl && usage == 0x04 {
		e.selectAll = true
		return true
	}
	if ctrl || flags&vi.ModAlt != 0 {
		return false
	}
	switch usage {
	case keyHome:
		e.cursor, e.selectAll = 0, false
	case keyEnd:
		e.cursor, e.selectAll = len(e.text), false
	case keyLeft:
		if e.selectAll {
			e.cursor = 0
		} else if e.cursor > 0 {
			_, size := utf8.DecodeLastRuneInString(e.text[:e.cursor])
			e.cursor -= size
		}
		e.selectAll = false
	case keyRight:
		if e.selectAll {
			e.cursor = len(e.text)
		} else if e.cursor < len(e.text) {
			_, size := utf8.DecodeRuneInString(e.text[e.cursor:])
			e.cursor += size
		}
		e.selectAll = false
	case keyBacksp, 0x4c:
		if e.selectAll {
			e.text, e.cursor, e.selectAll = "", 0, false
		} else if usage == keyBacksp && e.cursor > 0 {
			_, size := utf8.DecodeLastRuneInString(e.text[:e.cursor])
			e.text = e.text[:e.cursor-size] + e.text[e.cursor:]
			e.cursor -= size
		} else if usage == 0x4c && e.cursor < len(e.text) {
			_, size := utf8.DecodeRuneInString(e.text[e.cursor:])
			e.text = e.text[:e.cursor] + e.text[e.cursor+size:]
		}
	default:
		if !layout.Printable(rune(symbol)) {
			return false
		}
		insert := string(rune(symbol))
		size := len(e.text)
		if e.selectAll {
			size = 0
		}
		if size+len(insert) > e.cap {
			return true // cap refused without splitting UTF-8
		}
		if e.selectAll {
			e.text, e.cursor, e.selectAll = "", 0, false
		}
		e.text = e.text[:e.cursor] + insert + e.text[e.cursor:]
		e.cursor += len(insert)
	}
	return true
}

func (a *app) focusURL() {
	a.urlEditing = true
	a.histOpen = false
	a.findDismiss() // the chrome inputs are mutually exclusive
	a.focusControl = nil
	a.urlEdit.reset(a.target, maxURLBytes)
	a.dirty = true
	vi.ConsoleLine("web: url-focus")
}

// submitURL is Enter in the address bar — also the ">" action chip's click
// path while the field edits.
func (a *app) submitURL() {
	target := a.urlEdit.text
	a.urlEditing = false
	from := a.target
	if from == "" {
		from = "url-entry"
	}
	a.navigate(target, from)
}

func (a *app) keyEvent(ev vi.Event) {
	if a.pick.open { // M124b: the modal owns every key — Ctrl+L included
		a.pickKey(ev)
		return
	}
	if a.hints.Open { // M121c: the '?' overlay owns every key while it stands
		if _, done := a.hints.HandleKey(ev); done {
			a.hintsEmit = 2
		}
		a.dirty = true
		return
	}
	// M190d: the menubar engages on F10/Alt and owns the keyboard while it
	// stands — its rows call the same paths the chords below take.
	a.syncMenu()
	if k, ok := appkit.NormalizeKey(ev); ok && a.bar.OnKey(k) {
		if a.bar.Open && !a.menuOpen {
			vi.ConsoleLine("web: menu open")
		}
		a.menuOpen = a.bar.Open
		a.dirty = true
		return
	}
	a.menuOpen = a.bar.Open
	if ev.Flags&vi.ModCtrl != 0 && ev.Arg0 == 0x0f { // focused WEB owns Ctrl+L
		a.focusURL()
		return
	}
	if ev.Flags&vi.ModCtrl != 0 && ev.Arg0 == keyF { // Ctrl+F — the bar's chord, owned from any mode
		a.openFindBar()
		return
	}
	// M126d (#2596): per-tab zoom, owned from any mode like the other
	// chords. '=' and '+' share usage 0x2e ('+' is shift+'='); the OS
	// delivers the usage, so both chords land here.
	if ev.Flags&vi.ModCtrl != 0 {
		switch ev.Arg0 {
		case 0x2e: // Ctrl+= / Ctrl++
			a.zoomStep(1)
			return
		case 0x2d: // Ctrl+-
			a.zoomStep(-1)
			return
		case 0x27: // Ctrl+0
			a.zoomReset()
			return
		}
	}
	if a.findOpen {
		a.findBarKey(ev)
		return
	}
	if a.urlEditing {
		switch ev.Arg0 {
		case keyReturn:
			a.submitURL()
		case keyEscape:
			a.urlEditing = false
			a.dirty = true
		default:
			if a.urlEdit.key(ev.Arg0, ev.Arg1, ev.Flags) {
				a.dirty = true
			}
		}
		return
	}
	if a.histMenuKey(ev.Arg0) {
		return
	}
	if a.sideKey(ev.Arg0) {
		return
	}
	if ev.Arg0 == 0x3a { // F1: bounded diagnostics list, scoped to this app
		a.showDiagnostics = !a.showDiagnostics
		a.dirty = true
		return
	}
	if a.showDiagnostics {
		switch ev.Arg0 {
		case keyEscape:
			a.showDiagnostics = false
		case keyUp:
			a.diagnosticScroll = max(0, a.diagnosticScroll-1)
		case keyDown:
			a.diagnosticScroll = min(max(0, len(a.diagnostics)-1), a.diagnosticScroll+1)
		}
		a.dirty = true
		return
	}
	// M123d (#2578): the open error banner owns the browsing-mode keys —
	// chrome chords (Ctrl+L/F, zoom) and the field modes above still
	// answer; a page interaction under the strip does not.
	if a.banner.Open {
		a.bannerKeyEvent(ev)
		return
	}
	if a.controlKey(ev) {
		return
	}
	if ev.Arg0 == 0x2b {
		a.focusNextControl(ev.Flags&vi.ModShift != 0)
		return
	}
	// M121c (#2566): '?' opens the chord-hint overlay in browsing mode —
	// every field mode above (URL bar, find bar, form controls, the
	// picker's path field) keeps it as text; only the page surface takes
	// it as the help chord.
	if ev.Arg1 == '?' && ev.Flags&(vi.ModCtrl|vi.ModAlt) == 0 {
		a.hints = appkit.NewChordHints(appName)
		a.hints.R = hintsRect(a)
		a.hintsEmit = 1
		a.dirty = true
		return
	}
	a.key(ev.Arg0, ev.Flags)
}

// hintsRect centres the overlay plate on the live canvas, clamped into it.
func hintsRect(a *app) widgets.Rect {
	w, h := a.canvasSize()
	pw, ph := 432, 328
	if pw > w-8 {
		pw = w - 8
	}
	if ph > h-8 {
		ph = h - 8
	}
	return widgets.Rect{X: (w - pw) / 2, Y: (h - ph) / 2, W: pw, H: ph}
}

func (a *app) anchor(target string) bool {
	at := strings.IndexByte(target, '#')
	if at < 0 || a.lay == nil || strings.SplitN(a.target, "#", 2)[0] != target[:at] {
		return false
	}
	a.applyFragment(target)
	a.target = target
	if a.historyMove {
		a.hist.replace(entry{Target: target, Title: a.title})
		a.historyMove = false
	} else {
		a.hist.push(entry{Target: target, Title: a.title})
	}
	a.dirty = true
	a.announceNavigation()
	return true
}

func (a *app) applyFragment(target string) {
	at := strings.IndexByte(target, '#')
	if at < 0 || a.lay == nil {
		return
	}
	name := decodeFragment(target[at+1:])
	if name == "" {
		a.scroll = 0
		return
	}
	if a.lay.BoxTree != nil {
		for _, b := range a.lay.BoxTree.Boxes {
			if b.Node != nil && (b.Node.Attr("id") == name || b.Node.Tag == "a" && b.Node.Attr("name") == name) {
				a.scroll = max(0, min(b.Border.Y, webrenderScrollMax(a)))
				return
			}
		}
	}
}

func decodeFragment(name string) string {
	hex := func(c byte) int {
		switch {
		case c >= '0' && c <= '9':
			return int(c - '0')
		case c >= 'a' && c <= 'f':
			return int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			return int(c-'A') + 10
		}
		return -1
	}
	var out strings.Builder
	for i := 0; i < len(name); i++ {
		if name[i] == '%' && i+2 < len(name) {
			a, b := hex(name[i+1]), hex(name[i+2])
			if a >= 0 && b >= 0 {
				out.WriteByte(byte(a*16 + b))
				i += 2
				continue
			}
		}
		out.WriteByte(name[i])
	}
	return out.String()
}

func webrenderScrollMax(a *app) int {
	if a.lay == nil {
		return 0
	}
	return webrender.ScrollMax(a.lay, contentH)
}
