// Package tabapp is the M56d (issue #1315) Go mirror of
// user/src/lib/tabapp.zig — the ~40-line shape that makes a Go app work
// full-viewport inside the tabbed desktop (Zig TABWM). It packages four
// things once:
//
//  1. Open   — win_open at the legacy fixed rect (presentation unchanged).
//  2. Declare — a kind-8 declare_fullscreen WM_RPC (best-effort: TABWM accepts
//     and marks the tab full-viewport eligible; WND.BIN/the shim refuse the
//     additive kind and the app keeps its native size — the zero-regression
//     path).
//  3. Dispatch — WIN_CLOSE -> clean exit, WIN_RESIZE -> relayout at the new
//     canvas (the app tracks w/h here).
//  4. Scale — map a fixed layout into the new canvas; the identity mapping at
//     the native canvas is the zero-regression fixed point.
//
// No heap beyond the returned struct's own state, no libc, no cgo. On the host
// every vi call degrades to -ENOSYS, so init returns nil and the dispatch/scale
// logic stays plain unit-test surface.
package tabapp

import (
	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// Config opens/starts a tab app. Name is THIS process's own executable name
// (the WM ack-routing needs it); Title is the tab title.
//
// M125a (#2586): the state hooks. The app owns the serialized format; the
// seat owns the lifecycle. SaveState is called whenever the seat asks the
// tab to serialize (snapshot and tab close); its bytes — at most 64 KiB —
// are stored verbatim. RestoreState is called during Init when the seat
// held a blob for this tab (a re-exec'd session row, a reopened close):
// it gets the stored bytes back byte-intact plus the tag they were saved
// under. StateVersion tags every saved envelope so a stale serialization
// is refused by the app's own check, never silently misread.
type Config struct {
	Name  string
	Title string
	X, Y  uint32
	W, H  uint32

	SaveState    func() []byte
	RestoreState func([]byte)
	StateVersion uint8
}

// Action is what Dispatch decided the app should do with an event.
type Action int

const (
	// ActionNone: not a WM-lifecycle event — handle as usual.
	ActionNone Action = iota
	// ActionResized: relayout at the new canvas (W, H).
	ActionResized
	// ActionClosed: clean up and exit.
	ActionClosed
)

// Rect is a layout rectangle in canvas coordinates.
type Rect struct{ X, Y, W, H int }

// TabApp is the app shell state.
type TabApp struct {
	Win      int
	W, H     uint32
	Name     string
	Title    string
	TabAware bool
	OpenOK   bool

	// M125a (#2586): the state protocol's app side. The hooks are copied
	// from Config; the event loop calls PollStateAsk once per pass so a
	// seat ask gets answered inside the app's own slice.
	SaveState    func() []byte
	RestoreState func([]byte)
	StateVersion uint8
	// Restored reports that Init delivered a stored blob, and
	// RestoredVersion is the tag it was saved under — the app's check
	// for a stale serialization (it owns the format; the seat only
	// carried the bytes).
	Restored        bool
	RestoredVersion uint8

	// surf is the bound M33 window surface — the shared pages the depth
	// engine paints and the compositor reads — nil when the bind refused
	// and this app is on the degrade path. buf is surf viewed at the
	// current W x H stride; fill/fc are the FillerCanvas fallback's batcher
	// and adapter (the contract's keep-forever §1 path).
	surf []byte
	buf  *draw.BufferCanvas
	fill vi.Filler
	fc   draw.FillerCanvas
}

// mmapWindowSurface is the host-test seam over the surface bind — the same
// call draw.WindowCanvas makes. Tests substitute a page-sized slice and
// verify bind + review without a kernel.
var mmapWindowSurface = vi.MmapWindowSurface

// Init opens the window and declares tab-awareness. It returns nil when
// win_open fails (the caller prints and exits).
func Init(cfg Config) *TabApp {
	win, res := vi.WinOpen(cfg.X, cfg.Y, cfg.W, cfg.H)
	if res < 0 {
		return nil
	}
	ta := &TabApp{
		Win:    win,
		W:      cfg.W,
		H:      cfg.H,
		Name:   cfg.Name,
		Title:  cfg.Title,
		OpenOK: true,
	}
	// Best-effort declaration: one blocking RPC at startup. TABWM accepts it;
	// the shim/WND refuse and the app keeps its native presentation.
	// Declare BEFORE the surface bind: tab rails order cells by adoption,
	// so the bind's probe+map latency must not sit in the declare path and
	// reorder a peer's tab ahead of this one.
	ta.TabAware = vi.DeclareFullscreen(uint32(win), cfg.Title, cfg.Name)
	ta.bindSurface()
	// M125a (#2586): a re-exec'd or reopened tab may have a stored blob
	// waiting. Ask for it before the app starts drawing so the restore
	// lands in the same boot slice; no blob is just "start fresh".
	ta.SaveState = cfg.SaveState
	ta.RestoreState = cfg.RestoreState
	ta.StateVersion = cfg.StateVersion
	if ta.RestoreState != nil {
		if v, blob, ok := vi.RequestStateRestore(uint32(win), cfg.Name); ok {
			ta.Restored = true
			ta.RestoredVersion = v
			ta.RestoreState(blob)
		}
	}
	return ta
}

// Attach binds the canvas to a window the app opened with a raw vi.WinOpen —
// the netstat shape: no tab declaration (TabAware stays false because none
// was made), but the same surface binding and rebind-on-resize discipline.
// The bind is best-effort exactly as in Init: a refused mmap leaves the
// FillerCanvas degrade live, never a failed open.
func Attach(win int, name string, w, h uint32) *TabApp {
	t := &TabApp{Win: win, W: w, H: h, Name: name, Title: name, OpenOK: true}
	t.bindSurface()
	return t
}

// bindSurface maps this window's shared M33 surface ONCE, sized to the whole
// scanout — the largest rect a seat can ever propose, since wm_apply_rect
// clamps every proposal on-scanout.
//
// The size is forced by the kernel's surface contract, not convenience:
// bind_window_surface accepts only the first bind for a window (a second
// answers EINVAL — "one surface per window", unbind before rebind), and
// owner-munmapping a bound region revokes the surface, which tears the
// window down (driving_award.zig surface_revoked). Meanwhile reflow refuses
// any resize the bound pages would not cover (surface_covers). The only
// bind that can never refuse a legal resize is therefore one that covers
// the scanout; WIN_RESIZE then re-VIEWS these same pages (review) instead
// of remapping. The bind only requires len >= win.w*win.h*4, so the
// scanout-sized map is legal at the window's native size.
func (t *TabApp) bindSurface() {
	b, err := mmapWindowSurface(t.Win, vi.ScanoutFbBytes)
	if err != nil {
		return
	}
	t.surf = b
	t.review()
	t.shareSurface()
}

// shareSurface hands the bound surface to the Go seat over the kind-18
// SHARE_SURFACE RPC. Under a registered seat the kernel skips blitting
// surface-backed windows (wm_owns_user_layer), so the seat's composeSurfaces
// is the only path the painted bytes take to the scanout — a bound surface
// that was never shared composites black. Best-effort like the bind itself:
// no Go seat, a refused challenge, or the legacy path all return false and
// the kernel's own blit stays in charge.
func (t *TabApp) shareSurface() {
	if len(t.surf) == 0 || t.W == 0 || t.H == 0 {
		return
	}
	vi.WmSurfaceShare(uint32(t.Win), t.surf, int(t.W), int(t.H), t.Title, t.Name)
}

// review re-views the bound surface at the current W x H — the only "rebind"
// a resize can legally perform. The kernel strides the surface by the live
// win.w*4 (user_paint_dest), so the canvas is always the tight w x h view.
//
// The overlap copy is the app's half of reflow's contract ("a resize
// reframes bytes rather than discarding them"): reflow performs that copy
// only for its own pool buffer — for a shared surface the relocation of
// each surviving row to its new stride is this process's job. A grown
// stride copies bottom-up (each destination row sits past every source row
// still unread); a shrunken one top-down.
func (t *TabApp) review() {
	w, h := int(t.W), int(t.H)
	if len(t.surf) == 0 || w <= 0 || h <= 0 {
		return
	}
	if t.buf != nil && (t.buf.W != w || t.buf.H != h) {
		ow := t.buf.W
		copyW := min(ow, w) * 4
		rows := min(t.buf.H, h)
		if w > ow {
			for y := rows - 1; y >= 0; y-- {
				copy(t.surf[y*w*4:][:copyW], t.surf[y*ow*4:][:copyW])
			}
		} else {
			for y := 0; y < rows; y++ {
				copy(t.surf[y*w*4:][:copyW], t.surf[y*ow*4:][:copyW])
			}
		}
	}
	c, err := draw.BytesCanvas(t.surf, w, h)
	if err != nil {
		t.buf = nil
		return
	}
	t.buf = c
}

// Canvas is the frame's paint surface — the M104f contract every migrated
// app paints through instead of opening its own vi.Filler. When the surface
// bound this is a *draw.BufferCanvas over the shared pages (the depth
// engine's AA path; type-assert it for PushClip/PopClip/FillShadow). When
// the bind refused — an old kernel, no surface seat, or a hand-built TabApp
// in a host test — it is the documented degrade: a draw.FillerCanvas
// batching the same rects through the legacy fill syscall, where the kernel
// ignores the alpha byte and paints the identical pixels flat (§1's
// keep-forever policy).
func (t *TabApp) Canvas() widgets.Canvas {
	if t.buf != nil {
		return t.buf
	}
	t.fc.Filler = &t.fill
	t.fc.WindowID = t.Win
	return &t.fc
}

// Dispatch classifies one event and tracks the canvas size. Everything that is
// not a WM-lifecycle event stays the app's own business.
func (t *TabApp) Dispatch(ev vi.Event) Action {
	switch ev.Kind {
	case vi.EvWinClose:
		return ActionClosed
	case vi.EvWinResize:
		t.W = ev.Arg0
		t.H = ev.Arg1
		// The rebind is part of the tracking, not the app's job: the canvas
		// must be the new stride before the ActionResized repaint runs.
		t.review()
		// The seat's handoff record carries the reported stride/rows — a
		// resize leaves it reading the old geometry until re-shared.
		t.shareSurface()
		return ActionResized
	}
	return ActionNone
}

// Present flushes the frame: the degrade path's pending fill batch first
// (a no-op while a surface is bound), then the compositor's dirty mark.
func (t *TabApp) Present() {
	if t.buf == nil {
		_ = t.fill.Flush()
	}
	vi.WinPresent(t.Win)
}

// Close closes the window without exiting.
func (t *TabApp) Close() {
	if len(t.surf) != 0 {
		vi.WmSurfaceShareDrop(uint32(t.Win), t.Name)
	}
	vi.WinClose(t.Win)
}

// CloseAndExit is the common exit path: close the window, then exit.
func (t *TabApp) CloseAndExit(status int) {
	t.Close()
	vi.Exit(status)
}

// DeclareNav tells the WM this tab navigated to path (the browser-history
// analogue for FILE/EDIT tabs). Best-effort.
func (t *TabApp) DeclareNav(path string) { vi.DeclareNav(uint32(t.Win), path, t.Name) }

// PollNav returns a back/forward target the user picked, or "",false.
func (t *TabApp) PollNav() (string, bool) { return vi.PollNav(uint32(t.Win), t.Name) }

// SetTabTitle asks the seat to rename this tab. The initial declaration still
// establishes the executable identity; later titles only change the rail label.
func (t *TabApp) SetTabTitle(title string) bool {
	return vi.SetTabTitle(uint32(t.Win), title, t.Name)
}

// Notify tells the seat to raise a toast for this tab. M79k (#1720): the
// shared-service seam every app reaches for when it has something to say
// the user should see. The message budget is 24 bytes (the WM_RPC frame
// title), so keep it a short human string. The bool is the ack: false means
// no seat, a refused request, or no reply -- the caller should say so
// rather than assume the user was told.
func (t *TabApp) Notify(text string) bool {
	return vi.Notify(uint32(t.Win), text, t.Name)
}

// PollStateAsk answers the seat's save notice when one is waiting (M125a,
// #2586): SaveState() is staged through the rendezvous file and the
// kind-20 request posts the handoff. Call it once per event-loop pass —
// the same discipline as PollNav/PollSettingChanged. An app with no
// SaveState still answers (an empty blob is "no state"), so the seat's
// bounded collect drains deterministically instead of burning its ask
// budget on silence. False means no ask was waiting (or the handoff was
// refused); true means the seat stored the answer.
func (t *TabApp) PollStateAsk() bool {
	if !vi.PollStateAsk(uint32(t.Win)) {
		return false
	}
	var blob []byte
	if t.SaveState != nil {
		blob = t.SaveState()
	}
	return vi.PostStateSave(uint32(t.Win), t.StateVersion, blob, t.Name)
}

// SaveStateNow pushes an unsolicited save: the app's own state moved, so
// it stages the blob and posts the request without waiting for an ask.
func (t *TabApp) SaveStateNow() bool {
	var blob []byte
	if t.SaveState != nil {
		blob = t.SaveState()
	}
	return vi.PostStateSave(uint32(t.Win), t.StateVersion, blob, t.Name)
}

// Scale maps r from a fromW x fromH canvas into toW x toH (integer math,
// rounding toward the top-left, minimum 1px). At the identity mapping
// (to == from) every rect maps to itself exactly — the zero-regression fixed
// point that makes an un-resized tab render byte-identically.
func Scale(r Rect, fromW, fromH, toW, toH uint32) Rect {
	if fromW == 0 || fromH == 0 {
		return r
	}
	if fromW == toW && fromH == toH {
		return r
	}
	x := int(uint64(uint32(r.X)) * uint64(toW) / uint64(fromW))
	y := int(uint64(uint32(r.Y)) * uint64(toH) / uint64(fromH))
	w := int(uint64(uint32(r.W)) * uint64(toW) / uint64(fromW))
	h := int(uint64(uint32(r.H)) * uint64(toH) / uint64(fromH))
	if w < 1 {
		w = 1
	}
	if h < 1 {
		h = 1
	}
	return Rect{x, y, w, h}
}

// Layout scales r from the native canvas into THIS app's current canvas.
func (t *TabApp) Layout(r Rect, fromW, fromH uint32) Rect {
	return Scale(r, fromW, fromH, t.W, t.H)
}

// CellGrid maps a Virelai window rect in FRAME pixels to the terminal
// grid's cell dimensions — M73j's (#1636) agreement pin, mirrored from
// the kernel's two formulas for the SAME rect:
//
//	cols = clamp(w/cellW, 8, 80) — terminal.zig syncWindowCols -> setCols
//	                             (the M49 SD5-effective column count)
//	rows = (h-16)/cellH           — driving_award.zig rows_visible, the 16 px
//	                             title band (wnd_core title_bar_h) is not
//	                             client area; kernel's `else 1` below it
//
// M73l (#1661): cellW/cellH mirror kernel/src/font_metrics.zig —
// FiraCode at pixel size 13: advance 8, ascent+descent 16 (the boot
// look). M80i (#1725): the cell is the ACTIVE zoom rung's (7x13 / 8x16
// / 10x21), so the caller passes vi.TerminalCell() — the same rung the
// kernel's reflow just used — never a literal.
//
// The TUI contract is cells, never pixels: a consumer can only ask for
// geometry the kernel grid will actually render. TestCellGridPinsKernel
// pins both formulas class-A at EVERY rung; the class-B size marker
// proves the live event carries the same numbers.
func CellGrid(w, h, cellW, cellH uint32) (cols, rows int) {
	cols = int(w / cellW)
	if cols < 8 {
		cols = 8
	}
	if cols > 80 {
		cols = 80
	}
	rows = 1
	if h > 16 {
		rows = int((h - 16) / cellH)
	}
	return cols, rows
}

// FillRGB is the full-viewport clear colour from the Go token table (M69c).
func FillRGB() uint32 { return theme.Current.Bg }
