// view.go — GOASSIST's windowed half (M140b, #2785; v2 #2920): a chat tab
// under the seat. Left rail lists the conversations the store knows by
// their display titles; F2 renames the selected one (the C#### file name
// stays) and Delete removes it behind a confirm. A store-local PRESETS.TXT
// offers up to 8 named system-prompt presets when a conversation starts.
// The transcript wraps, renders code fences in the mono face, and keeps a
// bounded scrollback; the prompt field sends on Enter and Esc cancels the
// stream. save_state records the open conversation's name, its title, and
// the scroll row; the transcript itself re-loads from the conversation
// file.
package main

import (
	"errors"
	"sort"
	"strings"

	"virelai/appkit"
	uidraw "virelai/draw"
	"virelai/gpu3d"
	"virelai/layout"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

const (
	appName  = "GOASSIST.ELF"
	appTitle = "Assistant"
	natW     = 640
	natH     = 420

	sideW     = 148
	rowH      = 17  // transcript line height
	promptMax = 480 // prompt field byte bound
	// pendMax bounds events stashed during one generation — key-down AND
	// key-up each take a slot, so a rename typed mid-answer (F2 + up to a
	// 48-byte title + Return + the snapshot chord) needs ~100, not a few.
	pendMax  = 128
	convCap  = 32 // sidebar row bound; ListDir also caps deeper stores
	stateVer = 2

	// keyF2 is the rename gesture on the focused sidebar row — the HID
	// usage, since appkit's named vocabulary ends at F10.
	keyF2 = 0x3b

	markerOpen      = "goassist: open id="
	markerDeclare   = "goassist: declare accepted"
	markerPresent   = "goassist: present"
	markerSend      = "goassist: send conv="
	markerTokens    = "goassist: tokens="
	markerAnswer    = "goassist: answer toks="
	markerCancel    = "goassist: cancelled toks="
	markerAbsent    = "goassist: weights absent"
	markerUnsup     = "goassist: unsupported"
	markerError     = "goassist: error "
	markerSaved     = "goassist: saved "
	markerCommit    = "goassist: committed conv="
	markerPosted    = "goassist: state posted conv="
	markerRestored  = "goassist: state restored conv="
	markerRefused   = "goassist: state refused"
	markerMismatch  = "goassist: state mismatch"
	markerRenamed   = "goassist: renamed conv="
	markerRenBad    = "goassist: rename refused conv="
	markerDeleted   = "goassist: conv deleted "
	markerPresets   = "goassist: presets n="
	markerPresBad   = "goassist: presets refused"
	markerClose     = "goassist: close"
	markerIMEOn     = "goassist: ime on"
	markerIMEOff    = "goassist: ime off"
	markerIMECommit = "goassist: ime commit "
	markerNotdef    = "fonts: notdef="
	markerOK        = "goassist OK"
	markerDone      = "goassist: done"
)

// viewConsole is the window path's serial sink (the host-test seam var).
var (
	viewConsole    = vi.ConsoleLine
	openViewWindow = tabapp.Init
	pollEvent      = vi.PollEventRaw
	sleepTicks     = vi.Sleep
)

// faces is the optional font pair: ui for prose, mono for code blocks.
// Either may be nil — the bitmap face is the degrade for both.
type faces struct {
	ui   *ttf.Chain
	mono *ttf.Chain
}

// view is the window's state.
type view struct {
	ta  *tabapp.TabApp
	h   host
	eng *engine
	f   faces
	dir string // the conversation store's dir this boot

	convs   []string          // sidebar entries (file stems), sorted
	titles  map[string]string // name → v2 title, for the list's labels
	presets []preset          // the store's PRESETS.TXT, when present
	cur     *conversation     // the open conversation
	lines   []rline           // rendered transcript, scrollMax-bounded
	scroll  int               // first visible transcript row

	prompt appkit.TextField
	side   *appkit.ListController
	newBtn widgets.Button
	renBtn widgets.Button
	delBtn widgets.Button
	sendBn widgets.Button
	ring   *appkit.FocusRing

	// Modal state: the picker owns input while non-nil (a new conversation
	// choosing its preset), the dialog while open (rename prompt, delete
	// confirm). Only one is ever up.
	pick        *presetPick
	dlg         *appkit.Dialog
	dlgName     string // the conversation the open dialog acts on
	pendingSend string // send text parked behind the preset picker

	busy     bool       // a generation is streaming
	genIds   []int      // ids produced by the in-flight answer
	pend     []vi.Event // non-Esc events drained mid-generation
	status   string     // status strip text
	follow   bool       // scroll tracks the tail unless the user scrolls up
	wantQuit bool       // an idle Esc asked for the close

	// restore hand-off: RestoreState runs inside tabapp.Init, before the
	// store is listed — the decoded fields land here and applyRestore
	// consumes them once convs is populated.
	restOK     bool
	restBad    bool
	restName   string
	restTitle  string
	restScroll int
}

// presetPick is the modal "which persona" chooser's state: the highlighted
// row of [default, presets...].
type presetPick struct {
	sel int
}

// convDir resolves the conversation store for this boot: /host/ASSIST, or
// /disk/ASSIST when the data_root opt-in mounted (M100f resolution).
func convDir(h host) string {
	root, fellBack := h.DataRoot()
	if fellBack {
		h.ConsoleLine("goassist: data_root=disk but /disk not_mounted; using /host")
	} else if root == "/disk" {
		h.ConsoleLine("goassist: data_root=/disk")
	}
	return root + "/ASSIST"
}

// convNames lists the store's .CHAT stems, sorted — the sidebar's rows.
func convNames(h host, dir string) []string {
	names, err := h.ListDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, n := range names {
		if strings.HasSuffix(n, convExt) {
			out = append(out, n[:len(n)-len(convExt)])
		}
	}
	sort.Strings(out)
	return out
}

// convPath maps a conversation name to its file.
func convPath(dir, name string) string { return dir + "/" + name + convExt }

// convHeadMax bounds the per-file read the sidebar's title scan makes —
// the v2 title line sits inside the first ~80 bytes.
const convHeadMax = 256

// loadTitles scans the store's titles once at boot so the sidebar can list
// "Trip plan" instead of C0003. A refused or absent read just leaves the
// name's fallback label.
func (v *view) loadTitles() {
	v.titles = map[string]string{}
	for _, n := range v.convs {
		if b, err := v.h.ReadFileAll(convPath(v.dir, n), convHeadMax); err == nil {
			if t := convTitleOf(b); t != "" {
				v.titles[n] = t
			}
		}
	}
}

// setTitleMap records (or clears) a conversation's display title.
func (v *view) setTitleMap(name, title string) {
	if v.titles == nil {
		v.titles = map[string]string{}
	}
	if title == "" {
		delete(v.titles, name)
		return
	}
	v.titles[name] = title
}

// displayName is the conversation's label everywhere it appears to the
// user: the sidebar row, the title bar, the tab title, dialogs.
func (v *view) displayName(name string) string {
	title := v.titles[name]
	if v.cur != nil && v.cur.name == name && v.cur.title != "" {
		title = v.cur.title
	}
	return displayTitle(name, title)
}

// saveConv publishes the conversation crash-safe; the marker is the gate's
// ordering anchor (the file is durable before it prints).
func (v *view) saveConv() {
	if v.cur == nil {
		return
	}
	path := convPath(v.dir, v.cur.name)
	if err := v.h.WriteShareFile(path, encodeConv(v.cur)); err != nil {
		v.h.ConsoleLine("goassist: save error " + v.cur.name)
		return
	}
	v.h.ConsoleLine(markerSaved + v.cur.name + convExt)
}

// openConv swaps the open conversation to a store-loaded one. A missing
// or refused file opens the name with an empty transcript — the name is
// kept so the next save lands on the same file.
func (v *view) openConv(name string) {
	c := &conversation{name: name}
	if b, err := v.h.ReadFileAll(convPath(v.dir, name), convMaxBytes); err == nil {
		if d, ok := decodeConv(b); ok {
			c.title = d.title
			c.turns = d.turns
		}
	}
	v.cur = c
	v.setTitleMap(name, c.title)
	v.rewrap()
	v.follow = true
	v.scroll = v.maxScroll()
	v.setTabTitle()
}

// startNewConv is the "+ New chat" gesture: a store with presets offers
// the picker first; without one the conversation opens directly on the
// default persona.
func (v *view) startNewConv() {
	if len(v.presets) > 0 {
		v.pick = &presetPick{}
		v.status = "choose a persona — Enter picks, Esc cancels"
		return
	}
	v.newConv(-1)
}

// finishPick resolves the preset chooser: row 0 is the default persona,
// row i>0 preset i-1, and -1 cancels — the send that raised the picker is
// dropped back into the field, not eaten.
func (v *view) finishPick(i int) {
	v.pick = nil
	if i < 0 {
		v.status = "ready"
		v.pendingSend = ""
		return
	}
	v.newConv(i - 1)
	if v.pendingSend != "" && v.cur != nil {
		t := v.pendingSend
		v.pendingSend = ""
		v.sendText(t)
		return
	}
	v.pendingSend = ""
	v.repaint()
}

// newConv allocates the next store name, saves the empty conversation so
// its file exists, and opens it. presetIdx ≥0 seeds the transcript's
// @@system turn from the preset list.
func (v *view) newConv(presetIdx int) {
	name := nextConvName(v.convs)
	if name == "" {
		v.status = "conversation space full"
		return
	}
	v.convs = append(v.convs, name)
	sort.Strings(v.convs)
	if err := v.h.MkdirShare(v.dir); err != nil {
		v.h.ConsoleLine(markerError + "mkdir")
	}
	v.cur = &conversation{name: name}
	mark := "goassist: conv new " + name
	if presetIdx >= 0 && presetIdx < len(v.presets) {
		p := v.presets[presetIdx]
		v.cur.turns = append(v.cur.turns, turn{role: roleSystem, text: p.prompt})
		mark += " preset=" + p.name
	}
	v.saveConv()
	v.h.ConsoleLine(mark)
	v.rewrap()
	v.follow = true
	v.scroll = 0
	v.postState()
}

// rewrap rebuilds the transcript at the pane's current width.
func (v *view) rewrap() {
	if v.cur == nil {
		v.lines = nil
		return
	}
	v.lines = renderConv(v.cur, int(v.ta.W)-sideW-24, v.measure)
}

// measure is the renderer's width oracle: the chain's own advance when a
// face resolved, the 8px cell count when the bitmap degrade paints.
func (v *view) measure(k rlineKind, s string) int {
	switch k {
	case rlCode:
		if v.f.mono != nil {
			return v.f.mono.Measure(s, 12)
		}
	default:
		if v.f.ui != nil {
			return v.f.ui.Measure(s, 13)
		}
	}
	return len(s) * 8
}

// maxScroll is the largest legal first-visible row.
func (v *view) maxScroll() int {
	vis := v.transRect().H / rowH
	m := len(v.lines) - vis
	if m < 0 {
		m = 0
	}
	return m
}

// scrollBy moves the first visible row; follow drops when the user
// scrolls away from the tail and re-arms on End.
func (v *view) scrollBy(delta int) {
	v.follow = false
	v.scroll += delta
	if v.scroll < 0 {
		v.scroll = 0
	}
	if m := v.maxScroll(); v.scroll > m {
		v.scroll = m
		v.follow = true
	}
	v.postState()
}

// --- send / generate ---------------------------------------------------------

// send takes the prompt field's text and starts the exchange — a store
// with presets raises the picker first (the text parks in pendingSend);
// otherwise the first send allocates C0001 as before.
func (v *view) send() {
	text := strings.TrimSpace(v.prompt.Value())
	if text == "" || v.busy {
		return
	}
	if v.cur == nil {
		if len(v.presets) > 0 {
			v.pendingSend = text
			v.pick = &presetPick{}
			v.status = "choose a persona — Enter picks, Esc cancels"
			v.repaint()
			return
		}
		v.newConv(-1)
		if v.cur == nil {
			return
		}
	}
	v.sendText(text)
}

// sendText is send's back half once a conversation is open: append the
// user turn and stream the answer — tokens render as they arrive, Esc
// cancels. Named refusals (absent weights, no device) land as transcript
// notes, never answers.
func (v *view) sendText(text string) {
	v.cur.turns = append(v.cur.turns, turn{role: roleUser, text: text})
	v.prompt.Clear()
	v.busy = true
	v.genIds = nil
	v.status = "generating — Esc cancels"
	v.h.ConsoleLine(markerSend + v.cur.name)
	v.rewrap()
	v.scroll = v.maxScroll()
	v.repaint()

	if err := v.eng.ensure(v.h); err != nil {
		v.busy = false
		switch {
		case errors.Is(err, errWeightsAbsent):
			v.h.ConsoleLine(markerAbsent)
			v.note("(weights absent — stage the model at " + modelPath + ")")
		case errors.Is(err, gpu3d.ErrComputeNoDevice):
			v.h.ConsoleLine(markerUnsup)
			v.note("(no compute device on this boot)")
		default:
			v.h.ConsoleLine(markerError + errName(err))
			v.note("(load failed: " + errName(err) + ")")
		}
		v.status = "ready"
		v.saveConv()
		v.postState()
		v.h.ConsoleLine(markerCommit + v.cur.name)
		v.repaint()
		return
	}

	v.cur.turns = append(v.cur.turns, turn{role: roleModel})
	prompt := v.eng.prompt(v.cur)
	_, ids, err := v.eng.generate(prompt, v.onToken)
	v.busy = false
	switch {
	case errors.Is(err, errCancelled):
		v.h.ConsoleLine(markerCancel + is(len(ids)))
		v.note("(cancelled)")
	case err != nil:
		v.h.ConsoleLine(markerError + errName(err))
		v.note("(generate failed: " + errName(err) + ")")
	default:
		v.h.ConsoleLine(markerAnswer + is(len(ids)) + " ids=" + idlist(ids))
	}
	v.status = "ready"
	v.saveConv()
	v.postState()
	v.h.ConsoleLine(markerCommit + v.cur.name)
	v.repaint()
}

// onToken is Generate's callback: each produced id extends the open
// assistant turn (decoded whole so split multi-byte tokens land intact),
// the markers count for the gate, a repaint streams the line live, and a
// drained Esc aborts the decode. Non-Esc events queue for replay — a
// close or resize mid-answer is honoured, never eaten.
func (v *view) onToken(id int) error {
	for {
		ev, _, ok := pollEvent()
		if !ok {
			break
		}
		if ev.Kind == vi.EvKeyDown && (ev.Arg0 == 0x29 || ev.Arg1 == 0x1b) {
			return errCancelled
		}
		if len(v.pend) < pendMax {
			v.pend = append(v.pend, ev)
		}
	}
	v.ta.PollStateAsk()
	v.genIds = append(v.genIds, id)
	v.h.ConsoleLine(markerTokens + is(len(v.genIds)))
	t := &v.cur.turns[len(v.cur.turns)-1]
	t.text = v.eng.model.Tokenizer().Decode(v.genIds)
	v.rewrap()
	if v.follow {
		v.scroll = v.maxScroll()
	}
	v.repaint()
	return nil
}

// note appends a meta turn so refusals and cancels are part of the
// transcript itself.
func (v *view) note(s string) {
	if v.cur == nil {
		return
	}
	v.cur.turns = append(v.cur.turns, turn{role: roleMeta, text: s})
	v.rewrap()
	v.scroll = v.maxScroll()
}

// --- save_state / restore_state (M125) ----------------------------------------

// saveState serializes {u8 ver | u16 nameLen | name | u16 titleLen |
// title | u32 scroll}; the transcript stays in its file — the blob only
// names where to re-open, and carries the title so the restored boot shows
// it even before the store scan.
func (v *view) saveState() []byte {
	out := []byte{stateVer, 0, 0}
	name, title := "", ""
	if v.cur != nil {
		name = v.cur.name
		title = v.cur.title
	}
	out[1] = byte(len(name))
	out[2] = byte(len(name) >> 8)
	out = append(out, name...)
	out = append(out, byte(len(title)), byte(len(title)>>8))
	out = append(out, title...)
	return append(out, byte(v.scroll), byte(v.scroll>>8), byte(v.scroll>>16), byte(v.scroll>>24))
}

// restoreState decodes a saved blob into the rest fields; the file load
// happens in runView after the store dir is known.
func (v *view) restoreState(b []byte) {
	if len(b) < 9 || b[0] != stateVer {
		v.restBad = true
		return
	}
	nl := int(b[1]) | int(b[2])<<8
	if nl > convNameMax || len(b) < 5+nl {
		v.restBad = true
		return
	}
	v.restName = string(b[3 : 3+nl])
	tl := int(b[3+nl]) | int(b[4+nl])<<8
	if tl > convTitleMax || len(b) != 9+nl+tl {
		v.restBad = true
		return
	}
	v.restTitle = string(b[5+nl : 5+nl+tl])
	off := 5 + nl + tl
	v.restScroll = int(uint32(b[off]) | uint32(b[off+1])<<8 | uint32(b[off+2])<<16 | uint32(b[off+3])<<24)
	v.restOK = true
}

// postState publishes the current blob to the tab record — called after
// every meaningful change so the seat's asks/crash arm always find a
// fresh serialization.
func (v *view) postState() {
	if v.ta.SaveStateNow() {
		scroll := 0
		name := ""
		if v.cur != nil {
			name = v.cur.name
		}
		scroll = v.scroll
		v.h.ConsoleLine(markerPosted + name + " scroll=" + is(scroll))
	}
}

// applyRestore runs after the store is listed: re-open the named
// conversation at the saved scroll row, and say what landed.
func (v *view) applyRestore() {
	if v.restBad {
		v.h.ConsoleLine(markerRefused)
		return
	}
	if !v.restOK {
		return
	}
	v.openConv(v.restName)
	v.scroll = v.restScroll
	if m := v.maxScroll(); v.scroll > m {
		v.scroll = m
	}
	v.follow = v.scroll == v.maxScroll()
	turns := 0
	curTitle := ""
	if v.cur != nil {
		turns = len(v.cur.turns)
		curTitle = v.cur.title
	}
	// The blob's title is the snapshot's word; the file's is the truth. A
	// rename between them is the only honest disagreement — named, never
	// silently obeyed either way.
	if v.restTitle != curTitle {
		v.h.ConsoleLine(markerMismatch + " title blob=" + v.restTitle +
			" file=" + curTitle)
	}
	v.h.ConsoleLine(markerRestored + v.restName +
		" turns=" + is(turns) + " scroll=" + is(v.scroll) +
		" title=" + curTitle)
}

// --- rename / delete -----------------------------------------------------------

// selName is the sidebar's target for the file gestures: the selected row
// when one is in range, else the open conversation.
func (v *view) selName() string {
	if i := v.side.List.Sel; i >= 0 && i < len(v.convs) {
		return v.convs[i]
	}
	if v.cur != nil {
		return v.cur.name
	}
	return ""
}

// askRename raises the title prompt for a store conversation.
func (v *view) askRename(name string) {
	d := appkit.NewPrompt("Rename conversation",
		"Title for "+name+" — up to 48 bytes; empty restores the number.")
	d.R = widgets.Rect{
		X: (int(v.ta.W) - d.R.W) / 2, Y: (int(v.ta.H) - d.R.H) / 2,
		W: d.R.W, H: d.R.H,
	}
	v.dlg = &d
	v.dlgName = name
}

// askDelete raises the confirm behind which a conversation's file goes.
func (v *view) askDelete(name string) {
	d := appkit.NewConfirm("Delete conversation",
		"Delete "+v.displayName(name)+"? The transcript file is removed.")
	d.R = widgets.Rect{
		X: (int(v.ta.W) - d.R.W) / 2, Y: (int(v.ta.H) - d.R.H) / 2,
		W: d.R.W, H: d.R.H,
	}
	v.dlg = &d
	v.dlgName = name
}

// applyDialog lands a closed dialog's result. PromptDialog is the rename;
// ConfirmDialog the delete. A cancelled dialog changes nothing.
func (v *view) applyDialog() {
	d := v.dlg
	v.dlg = nil
	name := v.dlgName
	switch d.Kind {
	case appkit.PromptDialog:
		if d.Result == "cancel" || d.Result == "Cancel" {
			return
		}
		v.applyRename(name, d.Result)
	case appkit.ConfirmDialog:
		if d.Result == "Yes" {
			v.deleteConv(name)
		}
	}
}

// applyRename sets a conversation's display title. The open conversation
// is retitled through its normal save; a listed-but-closed one is
// rewritten in place — the C#### file name never moves, and a file that
// refuses to decode is never clobbered by a header-only rewrite.
func (v *view) applyRename(name, input string) {
	title := strings.TrimSpace(input)
	if title != "" && !validTitle(title) {
		v.status = "titles run to 48 bytes"
		v.h.ConsoleLine(markerRenBad + name)
		return
	}
	if v.cur != nil && v.cur.name == name {
		v.cur.title = title
		v.saveConv()
	} else {
		c := &conversation{name: name, title: title}
		if b, err := v.h.ReadFileAll(convPath(v.dir, name), convMaxBytes); err == nil {
			d, ok := decodeConv(b)
			if !ok {
				v.status = "rename failed: file unreadable"
				v.h.ConsoleLine(markerRenBad + name)
				return
			}
			c.turns = d.turns
		}
		if err := v.h.WriteShareFile(convPath(v.dir, name), encodeConv(c)); err != nil {
			v.status = "rename failed"
			v.h.ConsoleLine(markerError + "save " + name)
			return
		}
	}
	v.setTitleMap(name, title)
	v.h.ConsoleLine(markerRenamed + name + " title=" + title)
	v.setTabTitle()
	v.postState()
}

// deleteConv removes the file and refreshes the list; deleting the open
// conversation opens the next one (or none, when the store empties).
func (v *view) deleteConv(name string) {
	if err := v.h.DeleteFile(convPath(v.dir, name)); err != nil {
		v.status = "delete failed"
		v.h.ConsoleLine(markerError + "delete " + name)
		return
	}
	idx := -1
	for i, n := range v.convs {
		if n == name {
			idx = i
			break
		}
	}
	if idx >= 0 {
		v.convs = append(v.convs[:idx], v.convs[idx+1:]...)
	}
	v.setTitleMap(name, "")
	v.h.ConsoleLine(markerDeleted + name)
	if v.cur != nil && v.cur.name == name {
		v.cur = nil
		v.lines = nil
		v.scroll = 0
		v.follow = true
		if len(v.convs) > 0 {
			next := idx
			if next >= len(v.convs) {
				next = len(v.convs) - 1
			}
			if next < 0 {
				next = 0
			}
			v.openConv(v.convs[next])
			v.h.ConsoleLine("goassist: conv open " + v.convs[next])
		}
	}
	v.postState()
}

// --- the preset picker ---------------------------------------------------------

// pickRect is the chooser plate's rect in canvas pixels — one source for
// paint and hit-test, the dialog's own discipline.
func (v *view) pickRect() widgets.Rect {
	rows := 1 + len(v.presets)
	h := 64 + rows*20
	w := 300
	return widgets.Rect{
		X: (int(v.ta.W) - w) / 2, Y: (int(v.ta.H) - h) / 2, W: w, H: h,
	}
}

// pickItemAt maps a plate point to a row index (0 = default persona).
func (v *view) pickItemAt(x, y int) int {
	r := v.pickRect()
	top := r.Y + 40
	if x < r.X || x >= r.Right() || y < top {
		return -1
	}
	i := (y - top) / 20
	if i < 0 || i > len(v.presets) {
		return -1
	}
	return i
}

// pickEvent owns input while the chooser is up: arrows move the highlight,
// Enter chooses, Esc cancels, a row click chooses.
func (v *view) pickEvent(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvKeyDown:
		k, ok := appkit.NormalizeKey(ev)
		if !ok {
			return true
		}
		switch k.Named() {
		case appkit.NamedUp:
			if v.pick.sel > 0 {
				v.pick.sel--
			}
		case appkit.NamedDown:
			if v.pick.sel < len(v.presets) {
				v.pick.sel++
			}
		case appkit.NamedEnter:
			v.finishPick(v.pick.sel)
		case appkit.NamedEscape:
			v.finishPick(-1)
		}
		return true
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft != 0 {
			if i := v.pickItemAt(int(ev.Arg0), int(ev.Arg1)); i >= 0 {
				v.finishPick(i)
			}
		}
		return true
	}
	return true
}

// drawPicker paints the modal plate over the composed frame.
func (v *view) drawPicker(cv widgets.Canvas) {
	tok := theme.Current
	r := v.pickRect()
	cv.FillRoundedRect(r, 8, uidraw.Opaque(tok.Surface))
	cv.StrokeRoundedRect(r, 8, tok.BorderW, uidraw.Opaque(tok.Border))
	(&widgets.Text{
		R:     widgets.Rect{X: r.X + 16, Y: r.Y + 12, W: r.W - 32, H: 18},
		Label: "New conversation — persona", Fg: tok.Text, Bg: tok.Surface,
	}).Draw(cv)
	top := r.Y + 40
	for i := 0; i <= len(v.presets); i++ {
		label := "Default assistant"
		if i > 0 {
			label = v.presets[i-1].name
		}
		row := widgets.Rect{X: r.X + 8, Y: top + i*20, W: r.W - 16, H: 20}
		if i == v.pick.sel {
			cv.FillRect(row, uidraw.Opaque(tok.Selection))
		}
		(&widgets.Text{
			R:     row.Inset(4),
			Label: label, Fg: tok.Text, Bg: tok.Surface,
		}).Draw(cv)
	}
	(&widgets.Text{
		R:     widgets.Rect{X: r.X + 16, Y: r.Bottom() - 20, W: r.W - 32, H: 14},
		Label: "Enter chooses · Esc cancels", Fg: tok.Muted, Bg: tok.Surface,
	}).Draw(cv)
}

// --- input --------------------------------------------------------------------

// handle applies one event; returns whether the frame changed. A modal
// surface — the preset picker or an open dialog — owns every event while
// it is up.
func (v *view) handle(ev vi.Event) bool {
	if v.dlg != nil && v.dlg.Open {
		switch ev.Kind {
		case vi.EvKeyDown:
			if _, done := v.dlg.HandleKey(ev); done {
				v.applyDialog()
			}
		case vi.EvMouseDown:
			if ev.Flags&vi.BtnLeft != 0 {
				if _, done := v.dlg.HandleMouse(int(ev.Arg0), int(ev.Arg1), true); done {
					v.applyDialog()
				}
			}
		}
		return true
	}
	if v.pick != nil {
		return v.pickEvent(ev)
	}
	switch ev.Kind {
	case vi.EvKeyDown:
		return v.key(ev)
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft != 0 {
			return v.click(int(ev.Arg0), int(ev.Arg1))
		}
	}
	return false
}

// armIME wires the prompt's romaji->kana composition (M178b #3145): the
// ui chain so the pre-edit's kana reach the Japanese coverage face, the
// composer behind the field's toggle chord, and the serial markers the
// legs assert — the flip, the committed text, and the registry's notdef
// count proving every prompt rune found a face.
func (v *view) armIME(reg *ttf.Registry) {
	v.prompt.Chain = v.f.ui
	v.prompt.IME = &layout.IME{}
	v.prompt.OnIMEToggle = func(on bool) {
		if on {
			v.h.ConsoleLine(markerIMEOn)
		} else {
			v.h.ConsoleLine(markerIMEOff)
		}
	}
	v.prompt.OnIMECommit = func(s string) {
		v.h.ConsoleLine(markerIMECommit + s)
		n := 0
		if reg != nil {
			n = reg.Notdef()
		}
		v.h.ConsoleLine(markerNotdef + is(n))
	}
}

// key routes keyboard input: scrolling keys always reach the transcript,
// Tab cycles focus, the rest go to the focused control.
func (v *view) key(ev vi.Event) bool {
	k, ok := appkit.NormalizeKey(ev)
	if !ok || v.ring == nil {
		return false
	}
	_, idx := v.ring.Current()
	sideFocused := idx == 1
	// Ctrl+N is the keyboard "+ New chat" (HID usage 0x11 = 'n').
	if k.Ctrl && !k.Shift && !k.Alt && k.Usage == 0x11 {
		v.startNewConv()
		return true
	}
	// The sidebar owns the file gestures: F2 renames the selected row,
	// forward-delete removes it behind a confirm. (The prompt field's own
	// forward-delete stays its text edit — focus decides.)
	if sideFocused && len(v.convs) > 0 {
		switch {
		case k.Usage == keyF2:
			if n := v.selName(); n != "" {
				v.askRename(n)
			}
			return true
		case k.Named() == appkit.NamedDelete:
			if n := v.selName(); n != "" {
				v.askDelete(n)
			}
			return true
		}
	}
	// Enter in the prompt sends; the field itself never consumes it. A
	// live composition owns Enter first — it commits the shown form —
	// so the send only fires once the pre-edit is settled.
	if idx == 0 && k.Named() == appkit.NamedEnter && v.prompt.Preedit() == "" {
		v.send()
		return true
	}
	// Esc with no generation running is the close gesture (a mid-stream
	// Esc never reaches here — onToken consumed it into the cancel). A
	// live pre-edit owns it first: Escape cancels the composition.
	if k.Named() == appkit.NamedEscape && !v.busy && v.prompt.Preedit() == "" {
		v.wantQuit = true
		return true
	}
	switch k.Named() {
	case appkit.NamedPageUp:
		v.scrollBy(-(v.transRect().H/rowH - 1))
		return true
	case appkit.NamedPageDown:
		v.scrollBy(v.transRect().H/rowH - 1)
		return true
	case appkit.NamedHome:
		if sideFocused {
			return v.ring.HandleKey(k)
		}
		v.follow = false
		v.scroll = 0
		v.postState()
		return true
	case appkit.NamedEnd:
		if sideFocused {
			return v.ring.HandleKey(k)
		}
		v.scroll = v.maxScroll()
		v.follow = true
		v.postState()
		return true
	}
	// The sidebar's Enter opens the selected conversation instead of
	// passing through as a list key.
	if sideFocused && k.Named() == appkit.NamedEnter {
		if i := v.side.List.Sel; i >= 0 && i < len(v.convs) {
			v.openConv(v.convs[i])
			v.h.ConsoleLine("goassist: conv open " + v.convs[i])
			v.postState()
		}
		return true
	}
	return v.ring.HandleKey(k)
}

// click focuses and activates whatever the point hits: sidebar row opens
// the conversation, the buttons fire, the transcript pauses follow.
func (v *view) click(x, y int) bool {
	if v.newBtn.HitTest(x, y) {
		v.startNewConv()
		return true
	}
	if v.renBtn.HitTest(x, y) {
		if n := v.selName(); n != "" {
			v.askRename(n)
		}
		return true
	}
	if v.delBtn.HitTest(x, y) {
		if n := v.selName(); n != "" {
			v.askDelete(n)
		}
		return true
	}
	if v.sendBn.HitTest(x, y) {
		v.send()
		return true
	}
	if v.side.HitTest(x, y) {
		if i := v.side.List.ItemAt(x, y); i >= 0 && i < len(v.convs) {
			v.side.List.Sel = i
			v.ring.FocusWidget(v.side)
			v.openConv(v.convs[i])
			v.h.ConsoleLine("goassist: conv open " + v.convs[i])
			v.postState()
		}
		return true
	}
	if v.ring != nil && v.ring.HandleClick(x, y) {
		return true
	}
	if v.transRect().Contains(x, y) {
		v.follow = false
		return true
	}
	return false
}

// --- layout & paint ------------------------------------------------------------

func (v *view) scale(r widgets.Rect) widgets.Rect {
	s := v.ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
	return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
}

func (v *view) transRect() widgets.Rect {
	return v.scale(widgets.Rect{X: sideW + 8, Y: 34, W: natW - sideW - 16, H: natH - 78})
}

// paintText draws one transcript line through its kind's face, or the
// bitmap degrade when the registry gave no chain.
func (v *view) paintText(cv widgets.Canvas, clip widgets.Rect, x, y int, s string, k rlineKind) {
	tok := theme.Current
	rgb := tok.Ink
	switch k {
	case rlUser:
		rgb = tok.Accent
	case rlCode:
		rgb = tok.Text
	case rlMeta:
		rgb = tok.Muted
	}
	if k == rlCode && v.f.mono != nil {
		uidraw.TextChain(cv, v.f.mono, clip, x, y+12, 12, s, uidraw.Opaque(rgb))
		return
	}
	if k != rlCode && v.f.ui != nil {
		uidraw.TextChain(cv, v.f.ui, clip, x, y+13, 13, s, uidraw.Opaque(rgb))
		return
	}
	widgets.DrawText(cv, widgets.Rect{X: clip.X, Y: y, W: clip.W, H: rowH}, s, rgb)
}

func (v *view) draw() {
	cv := v.ta.Canvas()
	tok := theme.Current
	cv.FillRect(widgets.Rect{W: int(v.ta.W), H: int(v.ta.H)}, uidraw.Opaque(tabapp.FillRGB()))

	// Title + model tag.
	tag := modelPath
	if v.eng.stub {
		tag = "stub"
	}
	if v.eng.model != nil {
		tag = v.eng.model.Header().Model.ID
	}
	title := appTitle
	if v.cur != nil {
		title += " — " + v.displayName(v.cur.name)
	}
	(&widgets.Text{
		R:     v.scale(widgets.Rect{X: 8, Y: 8, W: natW - 200, H: 18}),
		Label: title, Fg: tok.Text, Bg: tok.Surface,
	}).Draw(cv)
	(&widgets.Text{
		R:     v.scale(widgets.Rect{X: natW - 188, Y: 8, W: 180, H: 18}),
		Label: tag, Fg: tok.Muted, Bg: tok.Surface,
	}).Draw(cv)

	// Sidebar: list labelled by display titles + New/Rename/Delete row.
	labels := make([]string, len(v.convs))
	for i, n := range v.convs {
		labels[i] = v.displayName(n)
	}
	v.side.List.Items = labels
	v.side.List.R = v.scale(widgets.Rect{X: 8, Y: 34, W: sideW - 4, H: natH - 114})
	if v.cur != nil {
		for i, n := range v.convs {
			if n == v.cur.name {
				v.side.List.Sel = i
			}
		}
	}
	v.side.Draw(cv)
	v.renBtn.R = v.scale(widgets.Rect{X: 8, Y: natH - 72, W: 70, H: 26})
	v.renBtn.Label = "Rename"
	v.renBtn.Disabled = len(v.convs) == 0
	v.renBtn.Draw(cv)
	v.delBtn.R = v.scale(widgets.Rect{X: 82, Y: natH - 72, W: 66, H: 26})
	v.delBtn.Label = "Delete"
	v.delBtn.Disabled = len(v.convs) == 0
	v.delBtn.Draw(cv)
	v.newBtn.R = v.scale(widgets.Rect{X: 8, Y: natH - 40, W: sideW - 4, H: 26})
	v.newBtn.Label = "+ New chat"
	v.newBtn.Draw(cv)

	// Transcript: code runs get a plate per contiguous block.
	tr := v.transRect()
	vis := tr.H / rowH
	for i := 0; i < vis && v.scroll+i < len(v.lines); i++ {
		ln := v.lines[v.scroll+i]
		y := tr.Y + i*rowH
		if ln.kind == rlCode {
			cv.FillRect(widgets.Rect{X: tr.X, Y: y, W: tr.W, H: rowH}, uidraw.Opaque(tok.Surface))
		}
		v.paintText(cv, tr, tr.X+4, y+2, ln.text, ln.kind)
	}
	if len(v.lines) == 0 {
		v.paintText(cv, tr, tr.X+4, tr.Y+2,
			"Ask anything. Esc cancels; conversations save under "+v.dir+"/", rlMeta)
	}

	// Prompt + Send.
	v.prompt.R = v.scale(widgets.Rect{X: sideW + 8, Y: natH - 36, W: natW - sideW - 128, H: 26})
	v.prompt.Disabled = v.busy
	v.prompt.Draw(cv)
	v.sendBn.R = v.scale(widgets.Rect{X: natW - 112, Y: natH - 36, W: 104, H: 26})
	v.sendBn.Label = "Send"
	v.sendBn.Disabled = v.busy
	v.sendBn.Draw(cv)

	// Status strip.
	(&widgets.Text{
		R:     v.scale(widgets.Rect{X: sideW + 8, Y: natH - 12, W: natW - sideW - 16, H: 10}),
		Label: v.status, Fg: tok.Muted, Bg: tok.Surface,
	}).Draw(cv)

	// Modal surfaces paint last, over the composed frame.
	if v.pick != nil {
		v.drawPicker(cv)
	}
	if v.dlg != nil && v.dlg.Open {
		v.dlg.Draw(cv)
	}
}

// setTabTitle keeps the seat's rail row on the open conversation's
// display title — the recorded bin name stays the executable's own.
func (v *view) setTabTitle() {
	if v.ta == nil || !v.ta.TabAware {
		return
	}
	if !v.ta.SetTabTitle(v.tabTitle()) {
		_ = vi.WinSetTitle(v.ta.Win, v.tabTitle())
	}
}

func (v *view) tabTitle() string {
	if v.cur == nil {
		return appTitle
	}
	return appTitle + " — " + v.displayName(v.cur.name)
}

func (v *view) repaint() {
	v.draw()
	v.ta.Present()
}

// --- the window's lifetime ------------------------------------------------------

// runView is the bare-launch presentation: open, restore if the seat held
// a blob, present, then the loop — PollStateAsk every pass so a close or
// snapshot ask is answered inside the app's own slice.
func runView(h host, stub bool) int {
	defer viewConsole(markerDone)
	f := faces{}
	reg, _ := uidraw.LoadRegistry()
	f.ui = reg.Chain(ttf.Query{Role: "ui"})
	f.mono = reg.Chain(ttf.Query{Role: "mono"})

	v := &view{h: h, eng: &engine{stub: stub}, f: f, follow: true}
	// The declare title is the executable's own name: GOTABWM's guessBin
	// default arm records the title verbatim, and a session restore
	// re-execs it bare (the GOIRC declare-title discipline). Declaring
	// appTitle instead made every restore drop the row 'exec' ENOENT.
	ta := openViewWindow(tabapp.Config{
		Name: appName, Title: appName, X: 32, Y: 28, W: natW, H: natH,
		StateVersion: stateVer,
		SaveState:    v.saveState,
		RestoreState: v.restoreState,
	})
	if ta == nil {
		viewConsole("goassist: window refused — journeys: GOASSIST.ELF [stub] | probe")
		return 1
	}
	v.ta = ta
	viewConsole(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		viewConsole(markerDeclare)
		// The rail label is the friendly name; the recorded bin stays the
		// executable the declare carried.
		if !ta.SetTabTitle(appTitle) {
			_ = vi.WinSetTitle(ta.Win, appTitle)
		}
	} else {
		viewConsole("goassist: declare refused")
	}

	v.dir = convDir(h)
	if err := h.MkdirShare(v.dir); err != nil {
		v.h.ConsoleLine(markerError + "mkdir " + v.dir)
	}
	v.convs = convNames(h, v.dir)
	if len(v.convs) > convCap {
		v.convs = v.convs[:convCap]
	}
	v.loadTitles()
	var presBad bool
	v.presets, presBad = loadPresets(h, v.dir)
	if presBad {
		h.ConsoleLine(markerPresBad)
	} else if len(v.presets) > 0 {
		h.ConsoleLine(markerPresets + is(len(v.presets)))
	}

	pf := appkit.NewTextField(widgets.Rect{}, promptMax)
	pf.Placeholder = "Message the assistant"
	v.prompt = pf
	v.armIME(reg)
	v.side = appkit.NewListController(&widgets.List{RowH: 22, Sel: -1})
	v.ring = appkit.NewFocusRing(&v.prompt, v.side)
	v.ring.Focus(0)

	v.applyRestore()
	if v.cur == nil && len(v.convs) > 0 {
		v.openConv(v.convs[len(v.convs)-1])
	}

	v.status = "ready"
	v.draw()
	ta.Present()
	viewConsole(markerPresent)
	v.postState()

	for {
		ta.PollStateAsk()
		var ev vi.Event
		if len(v.pend) > 0 {
			// A generation stashed non-Esc events; replay them through the
			// normal dispatch before polling again.
			ev = v.pend[0]
			v.pend = v.pend[1:]
		} else {
			e, r, ok := pollEvent()
			if !ok {
				if r < 0 {
					return 0
				}
				sleepTicks(1)
				continue
			}
			ev = e
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			viewConsole(markerClose)
			viewConsole(markerOK)
			v.eng.close()
			ta.CloseAndExit(0)
		case tabapp.ActionResized:
			v.rewrap()
			v.repaint()
		case tabapp.ActionUndo:
			ta.Undo()
		case tabapp.ActionNone:
			if v.handle(ev) {
				v.repaint()
			}
			if v.wantQuit {
				viewConsole(markerClose)
				viewConsole(markerOK)
				v.eng.close()
				ta.CloseAndExit(0)
			}
		}
	}
}
