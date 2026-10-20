// view.go — GOASSIST's windowed half (M140b, #2785): a chat tab under the
// seat. Left rail lists the conversations the store knows; the transcript
// wraps, renders code fences in the mono face, and keeps a bounded
// scrollback; the prompt field sends on Enter and Esc cancels the stream.
// save_state records the open conversation's name and scroll row; the
// transcript itself re-loads from the conversation file.
package main

import (
	"errors"
	"sort"
	"strings"

	"virelai/appkit"
	uidraw "virelai/draw"
	"virelai/gpu3d"
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
	rowH      = 17   // transcript line height
	promptMax = 480  // prompt field byte bound
	pendMax   = 16   // events stashed during one generation
	convCap   = 32   // sidebar row bound; ListDir also caps deeper stores
	stateVer  = 1

	markerOpen     = "goassist: open id="
	markerDeclare  = "goassist: declare accepted"
	markerPresent  = "goassist: present"
	markerSend     = "goassist: send conv="
	markerTokens   = "goassist: tokens="
	markerAnswer   = "goassist: answer toks="
	markerCancel   = "goassist: cancelled toks="
	markerAbsent   = "goassist: weights absent"
	markerUnsup    = "goassist: unsupported"
	markerError    = "goassist: error "
	markerSaved    = "goassist: saved "
	markerCommit   = "goassist: committed conv="
	markerPosted   = "goassist: state posted conv="
	markerRestored = "goassist: state restored conv="
	markerRefused  = "goassist: state refused"
	markerClose    = "goassist: close"
	markerOK       = "goassist OK"
	markerDone     = "goassist: done"
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
	ta   *tabapp.TabApp
	h    host
	eng  *engine
	f    faces
	dir  string // the conversation store's dir this boot

	convs  []string      // sidebar entries, sorted
	cur    *conversation // the open conversation
	lines  []rline       // rendered transcript, scrollMax-bounded
	scroll int           // first visible transcript row

	prompt appkit.TextField
	side   *appkit.ListController
	newBtn widgets.Button
	sendBn widgets.Button
	ring   *appkit.FocusRing

	busy   bool       // a generation is streaming
	genIds []int      // ids produced by the in-flight answer
	pend   []vi.Event // non-Esc events drained mid-generation
	status   string // status strip text
	follow   bool   // scroll tracks the tail unless the user scrolls up
	wantQuit bool   // an idle Esc asked for the close

	// restore hand-off: RestoreState runs inside tabapp.Init, before the
	// store is listed — the decoded fields land here and applyRestore
	// consumes them once convs is populated.
	restOK     bool
	restBad    bool
	restName   string
	restScroll int
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
			c.turns = d.turns
		}
	}
	v.cur = c
	v.rewrap()
	v.follow = true
	v.scroll = v.maxScroll()
}

// newConv allocates the next store name, saves the empty conversation so
// its file exists, and opens it.
func (v *view) newConv() {
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
	v.saveConv()
	v.h.ConsoleLine("goassist: conv new " + name)
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

// send takes the prompt field's text, appends the user turn, and streams
// the answer — tokens render as they arrive, Esc cancels. Named refusals
// (absent weights, no device) land as transcript notes, never answers.
func (v *view) send() {
	text := strings.TrimSpace(v.prompt.Value())
	if text == "" || v.busy {
		return
	}
	if v.cur == nil {
		v.newConv()
		if v.cur == nil {
			return
		}
	}
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

// saveState serializes {u8 ver | u16 nameLen | name | u32 scroll}; the
// transcript stays in its file — the blob only names where to re-open.
func (v *view) saveState() []byte {
	out := []byte{stateVer, 0, 0}
	if v.cur != nil {
		out[1] = byte(len(v.cur.name))
		out[2] = byte(len(v.cur.name) >> 8)
		out = append(out, v.cur.name...)
	}
	return append(out, byte(v.scroll), byte(v.scroll>>8), byte(v.scroll>>16), byte(v.scroll>>24))
}

// restoreState decodes a saved blob into pendingRestore; the file load
// happens in runView after the store dir is known.
func (v *view) restoreState(b []byte) {
	if len(b) < 7 || b[0] != stateVer {
		v.restBad = true
		return
	}
	nl := int(b[1]) | int(b[2])<<8
	if nl < 0 || nl > convNameMax || len(b) != 7+nl {
		v.restBad = true
		return
	}
	v.restName = string(b[3 : 3+nl])
	v.restScroll = int(uint32(b[3+nl]) | uint32(b[4+nl])<<8 | uint32(b[5+nl])<<16 | uint32(b[6+nl])<<24)
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
	if v.cur != nil {
		turns = len(v.cur.turns)
	}
	v.h.ConsoleLine(markerRestored + v.restName +
		" turns=" + is(turns) + " scroll=" + is(v.scroll))
}

// --- input --------------------------------------------------------------------

// handle applies one event; returns whether the frame changed.
func (v *view) handle(ev vi.Event) bool {
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

// key routes keyboard input: scrolling keys always reach the transcript,
// Tab cycles focus, the rest go to the focused control.
func (v *view) key(ev vi.Event) bool {
	k, ok := appkit.NormalizeKey(ev)
	if !ok || v.ring == nil {
		return false
	}
	_, idx := v.ring.Current()
	sideFocused := idx == 1
	// Enter in the prompt sends; the field itself never consumes it.
	if idx == 0 && k.Named() == appkit.NamedEnter {
		v.send()
		return true
	}
	// Esc with no generation running is the close gesture (a mid-stream
	// Esc never reaches here — onToken consumed it into the cancel).
	if k.Named() == appkit.NamedEscape && !v.busy {
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
		v.newConv()
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
		title += " — " + v.cur.name
	}
	(&widgets.Text{
		R:     v.scale(widgets.Rect{X: 8, Y: 8, W: natW - 200, H: 18}),
		Label: title, Fg: tok.Text, Bg: tok.Surface,
	}).Draw(cv)
	(&widgets.Text{
		R:     v.scale(widgets.Rect{X: natW - 188, Y: 8, W: 180, H: 18}),
		Label: tag, Fg: tok.Muted, Bg: tok.Surface,
	}).Draw(cv)

	// Sidebar: list + New button.
	v.side.List.Items = v.convs
	v.side.List.R = v.scale(widgets.Rect{X: 8, Y: 34, W: sideW - 4, H: natH - 82})
	if v.cur != nil {
		for i, n := range v.convs {
			if n == v.cur.name {
				v.side.List.Sel = i
			}
		}
	}
	v.side.Draw(cv)
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
	ta := openViewWindow(tabapp.Config{
		Name: appName, Title: appTitle, X: 32, Y: 28, W: natW, H: natH,
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

	pf := appkit.NewTextField(widgets.Rect{}, promptMax)
	pf.Placeholder = "Message the assistant"
	v.prompt = pf
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
