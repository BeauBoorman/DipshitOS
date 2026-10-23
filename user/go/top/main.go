// Command top is GOTOP.ELF — the M71g (issue #1566) Go successor to Zig
// TOP.BIN, with SYSTEM MONITOR's one-job remit folded into it: a live process
// list with click-to-kill, and the network counters view. Zig's TOP.BIN and
// SYSMON.BIN are deleted by the same card; after it the launcher's dock has
// one row for "see what is running".
//
// The marker vocabulary is TOP's own (`top: ...`) ON PURPOSE: twelve class-B
// specs assert it and the vocabulary is the CONTRACT, not the binary — the
// same discipline M66c used when `note:` outlived the Zig notepad, and the same
// reason `gofiles:` kept FILE.BIN's shape. Every marker below is printed only
// AFTER its syscall returned, so no assert can pass on a program that never ran.
//
// The filter is BACK (issue #2197): TOP's C8 text filter rode on Zig's
// ui.TextInput, and the kit now has widgets.TextInput, so the retired
// semantics return unchanged — `/` (or `f`) focuses the field, typed text
// live-narrows the table by case-insensitive name substring, Enter commits
// (the filter stays applied, the field unfocuses), Escape clears and the full
// list comes back. Header sorting is untouched (click / press 1-4).
//
// CPU/MEM are real since issue #2198 (ADR 0047): the snapshot negotiates the
// versioned `sys_procs` row, per-row CPU% is scheduler tick share (windowed
// against the previous refresh, else the share since boot), and MEM is the
// process's owned resident footprint — the summary line reports the machine
// aggregate. On a pre-v2 kernel the columns and summary figures disappear
// entirely; nothing is approximated.
//
// Kill IS the live proof (the card's D2): `k`, or the Kill button, arms the
// selected pid through slot 29, and the kernel converts it into the reserved
// status 137. A refusal (cross-principal EACCES) is printed, never hidden.
//
// The gpu tab (M111d, issue #2411) makes the compute workload observable the
// way the CPU already is: `c` (or the GPU button) shows the sys_gpucomp
// counters — busy, queue depth, last kernel time, and the submit ledger —
// sampled through gpu3d.SampleStats, the kernel's handle-free STATS op, so
// the monitor never takes the single compute session from a real workload.
//
// Why I'm separate (the #3189 diagnostics census, docs/diagnostics.md):
// GOTOP is the point-in-time monitor — every tab renders one kernel
// snapshot class (procs/net/agent/gpu/trust/mounts) sampled on demand.
// None of the append-only surfaces live here: logview owns the live log
// rings, crashview the frozen receipts, observe the armed per-target
// session.
package main

import (
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/widgets"
)

const (
	appName    = "GOTOP.ELF"
	appTitle   = "Top"
	winX       = 40 // TOP.BIN's presentation rect, kept: the WM specs move
	winY       = 40 // and sample GOTOP where they moved and sampled TOP
	natW       = 512
	natH       = 384
	exitStatus = 43 // TOP's exit status, kept (its markers say 43)

	autoRefreshTicks = 12 // ≈1 s on VZ (top.zig auto_refresh_ticks)

	markerOpen       = "top: open id="
	markerTabAware   = "top: tab-aware (full-viewport)"
	markerTabShy     = "top: not-tab-aware (shim or WND desktop)"
	markerReady      = "top: ready"
	markerProcs      = "top: tab=procs"
	markerNetwork    = "top: tab=network"
	markerAgent      = "top: tab=agent"
	markerGPU        = "top: tab=gpu"
	markerTrust      = "top: tab=trust"
	markerMounts     = "top: tab=mounts"
	markerRefreshed  = "top: refreshed ok"
	markerKill       = "top: kill pid="
	markerCount      = "top: procs n="
	markerRow        = "top: row pid="
	markerResize     = "top: resize relayout"
	markerClose      = "top: win_close"
	markerExit       = "top: exiting 43"
	markerRefreshErr = "top: procs err="
	markerUsage      = "top: usage"
	// M173c (#3044): the audit tab's principal filter cycles on `u`.
	markerAgentFilter = "top: agent filter="

	// M192d (#3249): the appver-1 state envelope's markers — the save
	// handoff's ack, the restore summary, and the refuse-by-name verdicts
	// (the gofiles/goterm vocabulary: save/restored/refused).
	markerStateSave     = "top: state save"
	markerStateRestored = "top: state restored"
	markerStateRefused  = "top: state refused"

	// M128d (#2608): the machine-identity line — one ctl `profile-info`
	// session through slot 93 (the kernel holds the credential). Refusals
	// name themselves; a bare run shows "refused <code>", never silence.
	markerProfile = "top: profile "

	// Filter markers (issue #2197): open/commit/cleared are the field's
	// lifecycle; `top: filter=<text> n=<rows>` is printed after every edit
	// rebuild, followed by a row dump of the narrowed view.
	markerFilterOpen    = "top: filter open"
	markerFilter        = "top: filter="
	markerFilterCommit  = "top: filter commit"
	markerFilterCleared = "top: filter cleared"

	// rowMarkerMax bounds the per-row serial lines one refresh prints. The
	// snapshot itself is capped at maxProcs (16), so this is belt-and-braces
	// against a refresh storm flooding the serial log.
	rowMarkerMax = 16
)

// Key codes (ADR 0009): arrows carry their code in Arg0, characters in Arg1.
const (
	keyDownArrow = 0x51
	keyUpArrow   = 0x52
	keyOne       = '1'
	keyTwo       = '2'
	keyThree     = '3'
	keyFour      = '4'
	keyFive      = '5'
	keySix       = '6'
)

// page is the active tab.
type page int

const (
	pageProcs page = iota
	pageNetwork
	pageAgent
	pageGPU
	pageTrust
	pageMounts
)

// tag is the page's lowercase marker name — the `top: tab=<name>` markers
// and the state blob's serial vocabulary share it.
func (p page) tag() string {
	switch p {
	case pageNetwork:
		return "network"
	case pageAgent:
		return "agent"
	case pageGPU:
		return "gpu"
	case pageTrust:
		return "trust"
	case pageMounts:
		return "mounts"
	}
	return "procs"
}

// tabMarker is the `top: tab=<name>` line for a page — setPage announces
// switches with it; the restore path emits it for the page it lands on.
func tabMarker(p page) string {
	switch p {
	case pageNetwork:
		return markerNetwork
	case pageAgent:
		return markerAgent
	case pageGPU:
		return markerGPU
	case pageTrust:
		return markerTrust
	case pageMounts:
		return markerMounts
	}
	return markerProcs
}

// Native layout (top.zig's native_* rects, so GOTOP opens where TOP opened).
var (
	natRefresh = widgets.Rect{X: 6, Y: 6, W: 52, H: 20}
	natKill    = widgets.Rect{X: 62, Y: 6, W: 36, H: 20}
	natAuto    = widgets.Rect{X: 102, Y: 6, W: 40, H: 20}
	natProcs   = widgets.Rect{X: 146, Y: 6, W: 42, H: 20}
	natNetwork = widgets.Rect{X: 192, Y: 6, W: 34, H: 20}
	// M109c's third tab took the slack between Net and the filter plate:
	// the filter row compressed a little to keep one toolbar line.
	// M111d's GPU and M113e's Trust compressed it once more each.
	natAgent = widgets.Rect{X: 226, Y: 6, W: 34, H: 20}
	natGPU   = widgets.Rect{X: 264, Y: 6, W: 28, H: 20}
	natTrust = widgets.Rect{X: 296, Y: 6, W: 34, H: 20}
	// M134b (#2760): the mounts tab squeezes the filter plate once more —
	// one toolbar line holds it.
	natMounts = widgets.Rect{X: 334, Y: 6, W: 30, H: 20}
	// The filter field sits near where Zig TOP.BIN's native_filter_input
	// sat — its "Filter:" label to the left — and the summary line ends
	// the row.
	natFilterLabel = widgets.Rect{X: 368, Y: 6, W: 40, H: 20}
	natFilter      = widgets.Rect{X: 412, Y: 6, W: 42, H: 20}
	natSummary     = widgets.Rect{X: 458, Y: 6, W: 48, H: 20}
	natHeader      = widgets.Rect{X: 6, Y: 52, W: 500, H: 16}
	natList        = widgets.Rect{X: 6, Y: 70, W: 500, H: 256}
	natFoot        = widgets.Rect{X: 6, Y: 330, W: 500, H: 18}
	// M128d (#2608): the machine-identity line sits under the hints —
	// which .virelaivm this run is, the base it boots, rollback, snaps.
	natProf = widgets.Rect{X: 6, Y: 350, W: 500, H: 18}
	natRowH = 16
)

type app struct {
	ta   *tabapp.TabApp
	tab  *Table
	net  *NetView
	ag   *AgentView
	gpu  *GPUView
	tr   *TrustView
	mnt  *MountView
	pg   page
	auto bool

	items  []string
	status string
	// M128d: the profile summary line — sampled on startup and on every
	// explicit refresh (never the 1 Hz tick: a ctl session per second is
	// a heartbeat the channel doesn't need).
	profLine string

	refreshBtn widgets.Button
	killBtn    widgets.Button
	autoBtn    widgets.Button
	procsBtn   widgets.Button
	netBtn     widgets.Button
	agentBtn   widgets.Button
	gpuBtn     widgets.Button
	trustBtn   widgets.Button
	mntBtn     widgets.Button
	summary    widgets.Text
	header     widgets.Text
	foot       widgets.Text
	profTxt    widgets.Text
	list       widgets.List
	scroll     widgets.Scrollbar // proc-list chrome (§5.2); absent while rows fit
	scrollDrag bool              // the thumb is being dragged
	scrollTop  int               // persistent: layout() rebuilds list wholesale

	// filter is persistent state (text, caret, focus): layout() only moves
	// its rect, never rebuilds it — a relayout must not lose the typed text.
	filter      widgets.TextInput
	filterLabel widgets.Text
}

func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

func main() {
	loadGuestTheme()

	// M192d (#3249): the state hooks. SaveState reads the live app (the
	// closure captures the variable, so an ask always serializes the
	// current sort+tab); RestoreState fires inside tabapp.Init, before the
	// app exists: it only decodes — the apply lands once the app is built
	// and the envelope's appver has been checked below.
	var a *app
	var restored topState
	var restoredOK bool
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle, X: winX, Y: winY, W: natW, H: natH,
		StateVersion: stateFmtVer,
		SaveState: func() []byte {
			if a == nil {
				return nil
			}
			return a.encodeState()
		},
		RestoreState: func(b []byte) { restored, restoredOK = decodeTopState(b) },
	})
	if ta == nil {
		vi.ConsoleLine("top: failed to open window")
		vi.Exit(1)
	}
	// The REAL window id, not TOP.BIN's hardcoded "id=3": the id is whatever
	// the host WM assigned, and a literal would make the marker a lie.
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerTabAware)
	} else {
		vi.ConsoleLine(markerTabShy)
	}

	a = &app{
		ta:  ta,
		tab: NewTable(),
		net: NewNetView(),
		ag:  NewAgentView(),
		gpu: NewGPUView(),
		tr:  NewTrustView(),
		mnt: NewMountView(),
		pg:  pageProcs,
	}
	a.bindFilter()
	// A re-exec'd or reopened tab may have delivered a stored blob. The
	// envelope's appver is the app's own stale check — a blob saved under a
	// different format version is refused by name, never silently misread.
	switch {
	case ta.Restored && ta.RestoredVersion == stateFmtVer && restoredOK:
		a.applyState(restored)
		vi.ConsoleLine(markerStateRestored + " tab=" + a.pg.tag() +
			" sort=" + a.tab.SortColumn().Tag() +
			" dir=" + a.sortDir())
	case ta.Restored && ta.RestoredVersion != stateFmtVer:
		vi.ConsoleLine(markerStateRefused + " ver=" + vi.Itoa64(int64(ta.RestoredVersion)))
	case ta.Restored:
		vi.ConsoleLine(markerStateRefused + " bad blob")
	}
	a.refreshAll(true, false)

	a.layout()
	a.draw()
	a.ta.Present()
	vi.ConsoleLine(markerReady)

	for {
		// M192d (#3249): the seat's save_state ask is mailbox traffic, not
		// an input event — answer it once per pass so a snapshot or
		// tab-close ask is serviced before the window dies. The marker
		// prints only on an acked handoff — "the seat stored the blob" —
		// never on silence or a refused post.
		if a.ta.PollStateAsk() {
			vi.ConsoleLine(markerStateSave + " tab=" + a.pg.tag() +
				" sort=" + a.tab.SortColumn().Tag() +
				" dir=" + a.sortDir() +
				" len=" + vi.Itoa64(int64(len(a.encodeState()))))
		}
		ev, r, ok := vi.PollEventRaw()
		if !ok {
			if r < 0 {
				break
			}
			vi.Sleep(1)
			continue
		}
		switch a.ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			vi.ConsoleLine(markerClose)
			if a.auto {
				vsys.TimerCancel()
			}
			vi.ConsoleLine(markerExit)
			a.ta.CloseAndExit(exitStatus)
		case tabapp.ActionResized:
			vi.ConsoleLine(markerResize)
			a.layout()
			a.draw()
			a.ta.Present()
		case tabapp.ActionNone:
			if a.handle(ev) {
				a.layout()
				a.draw()
				a.ta.Present()
			}
		}
	}
}

// --- M192d (#3249): the appver-1 state envelope -----------------------------
//
// Sort column, sort direction and the active tab ride the M125a (#2586)
// seat-mediated save/restore protocol — the monitor a user reopens looks
// like the one they left. The seat owns the lifecycle (it asks on
// snapshot and tab close, stores the blob on the tab's SESSION.TABS
// record, hands it back on re-exec); GOTOP owns the format:
//
//	u8 fmtver — the blob's own version byte; also the Config's
//	            StateVersion, so the envelope's appver and the payload
//	            agree (a stale serialization is refused twice over)
//	u8 page   — the active tab (pageProcs..pageMounts)
//	u8 col    — the sort axis (ColPID..ColMem)
//	u8 dir    — 0 descending, nonzero ascending
//
// Decode is total: a wrong length or a foreign fmtver refuses the WHOLE
// blob — a torn handoff can never land half-applied. Field VALUES never
// refuse: a page or column this build does not know clamps to the
// defaults, so a stale-but-well-formed blob degrades to a sane monitor
// rather than a refused session (the gofiles session.go rule).

// stateFmtVer is the blob's format version — both the Config.StateVersion
// the envelope carries and the payload's first byte.
const stateFmtVer = 1

// topState is one decoded session blob.
type topState struct {
	page page
	col  Column
	asc  bool
}

// encodeState serializes the sort+tab triple. Bounded by construction:
// four bytes, forever under the seat's 64 KiB cap.
func (a *app) encodeState() []byte {
	var d byte
	if a.tab.SortAscending() {
		d = 1
	}
	return []byte{stateFmtVer, byte(a.pg), byte(a.tab.SortColumn()), d}
}

// decodeTopState is encodeState's total inverse. ok=false means the blob
// is refused wholesale — a torn length or a foreign fmtver. Scalar fields
// clamp rather than fail: an out-of-range page or column byte degrades to
// the procs/pid defaults, and any nonzero dir byte reads as ascending.
func decodeTopState(b []byte) (topState, bool) {
	var st topState
	if len(b) != 4 || b[0] != stateFmtVer {
		return st, false
	}
	st.page = page(b[1])
	if st.page > pageMounts {
		st.page = pageProcs
	}
	st.col = Column(b[2])
	if st.col > ColMem {
		st.col = ColPID
	}
	st.asc = b[3] != 0
	return st, true
}

// applyState lands a decoded blob on the freshly built app: the sort is
// replayed through SetSort (absolute — not SortBy's flip) and the page
// switches, announcing the tab marker for whichever view it lands on. The
// first refreshAll right after sorts and samples under the restored
// state, so the reopened monitor's first listing IS the saved ordering.
func (a *app) applyState(st topState) {
	a.tab.SetSort(st.col, st.asc)
	if st.page != a.pg {
		a.pg = st.page
		vi.ConsoleLine(tabMarker(st.page))
	}
}

// sortDir is the sort direction's marker spelling.
func (a *app) sortDir() string {
	if a.tab.SortAscending() {
		return "asc"
	}
	return "desc"
}

// refreshAll takes one process + network sample and rebuilds the view.
//
// rows prints the per-row serial lines (the startup listing and an explicit
// refresh do; the 1 Hz timer does not, so an idle session leaves a bounded
// log). announce prints `top: refreshed ok`, and ONLY an explicit refresh
// does: a boot's startup listing must not satisfy a spec that asserts the
// marker as proof the refresh REQUEST was served (live-n4-top-net gates its
// `r` chord on it — TOP's startup was silent for exactly this reason).
func (a *app) refreshAll(rows, announce bool) {
	n, rc := a.tab.Refresh()
	if rc < 0 {
		a.status = "procs err"
		vi.ConsoleLine(markerRefreshErr + vi.Itoa64(rc))
		return
	}
	a.net.Refresh()
	if rows {
		a.refreshProfile()
	}
	if a.pg == pageAgent {
		a.refreshAgent()
	}
	if a.pg == pageGPU {
		a.refreshGPU()
	}
	if a.pg == pageTrust {
		a.refreshTrust()
	}
	if a.pg == pageMounts {
		a.refreshMounts()
	}
	running, exited, _ := a.tab.Counts()
	vi.ConsoleLine(markerCount + vi.Itoa64(int64(n)) +
		" running=" + vi.Itoa64(int64(running)) +
		" exited=" + vi.Itoa64(int64(exited)))
	if rows {
		a.printRows()
	}
	a.status = "n=" + vi.Itoa64(int64(n)) + " run=" + vi.Itoa64(int64(running))
	if cpuX10, memUsed, memTotal, ok := a.tab.Usage(); ok {
		vi.ConsoleLine(markerUsage + " cpux10=" + vi.Itoa64(int64(cpuX10)) +
			" memused=" + vi.Itoa64(int64(memUsed)) +
			" memtotal=" + vi.Itoa64(int64(memTotal)))
		a.status += " cpu=" + pctX10Text(cpuX10) + "% mem=" + memText(memUsed)
	}
	if announce {
		vi.ConsoleLine(markerRefreshed)
	}
	a.rebuildItems()
}

// ctlProfile is the slot-93 seam — vi.VsockCtl on the guest, a fake in
// host tests (the same discipline every other vi.* caller keeps).
var ctlProfile = vi.VsockCtl

// refreshProfile runs one ctl `profile-info` session and rewrites the
// identity line — the profile name, the base image's name, whether the
// base's .prev survives (a rollback target), and the stored snapshot
// count. A refusal (or no channel at all) names its code in the same
// line: the guest sees "which machine" or "why it cannot ask", never a
// blank.
func (a *app) refreshProfile() {
	p, verdict := vi.FetchProfileInfo(ctlProfile)
	if verdict != "" {
		a.profLine = "profile: refused " + verdict
		vi.ConsoleLine(markerProfile + "refused " + verdict)
		return
	}
	rb := "no"
	if p.Rollback {
		rb = "yes"
	}
	a.profLine = "profile " + p.Name + "  base " + p.Base +
		"  rollback " + rb + "  snaps " + vi.Itoa64(int64(p.Snapshots))
	vi.ConsoleLine(markerProfile + "name=" + p.Name + " base=" + p.Base +
		" rollback=" + rb + " snaps=" + vi.Itoa64(int64(p.Snapshots)))
}

// printRows emits one bounded marker per visible row — the serial evidence
// that the list really holds the kernel's table (and, after a kill, that the
// target was armed).
func (a *app) printRows() {
	n := a.tab.Len()
	if n > rowMarkerMax {
		n = rowMarkerMax
	}
	for i := 0; i < n; i++ {
		p, ok := a.tab.Row(i)
		if !ok {
			break
		}
		line := markerRow + vi.Itoa64(int64(p.PID)) + " name=" + p.Name + " state=" + StateName(p.State)
		if p.State == vi.ProcExited {
			line += " exit=" + vi.Itoa64(int64(p.Exit))
		}
		if p.HasUsage {
			line += " cpu=" + vi.Itoa64(int64(p.CpuTicks)) +
				" cpux10=" + vi.Itoa64(int64(p.CpuX10)) +
				" mem=" + vi.Itoa64(int64(p.MemBytes))
		}
		vi.ConsoleLine(line)
	}
}

// rebuildItems refreshes the list widget's labels from the table.
func (a *app) rebuildItems() {
	a.items = a.tab.Labels()
}

// layout re-derives every widget rect for the current canvas.
func (a *app) layout() {
	ta := a.ta
	t := theme.Current
	scaleR := func(r widgets.Rect) widgets.Rect {
		s := ta.Layout(tabapp.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}, natW, natH)
		return widgets.Rect{X: s.X, Y: s.Y, W: s.W, H: s.H}
	}
	scaleH := func(h int) int {
		s := ta.Layout(tabapp.Rect{X: 0, Y: 0, W: 1, H: h}, natW, natH)
		if s.H < 1 {
			return 1
		}
		return s.H
	}

	a.refreshBtn = widgets.Button{R: scaleR(natRefresh), Label: "Refresh"}
	a.killBtn = widgets.Button{R: scaleR(natKill), Label: "Kill", Face: t.Danger, LabelRGB: t.OnAccent}
	a.autoBtn = widgets.Button{R: scaleR(natAuto), Label: "Auto", Pressed: a.auto}
	a.procsBtn = widgets.Button{R: scaleR(natProcs), Label: "Procs"}
	a.netBtn = widgets.Button{R: scaleR(natNetwork), Label: "Net"}
	a.agentBtn = widgets.Button{R: scaleR(natAgent), Label: "Agent"}
	a.gpuBtn = widgets.Button{R: scaleR(natGPU), Label: "GPU"}
	a.trustBtn = widgets.Button{R: scaleR(natTrust), Label: "Trust"}
	a.mntBtn = widgets.Button{R: scaleR(natMounts), Label: "Mnt"}
	switch a.pg {
	case pageProcs:
		a.procsBtn.Face = t.Accent
		a.procsBtn.LabelRGB = t.OnAccent
	case pageNetwork:
		a.netBtn.Face = t.Accent
		a.netBtn.LabelRGB = t.OnAccent
	case pageAgent:
		a.agentBtn.Face = t.Accent
		a.agentBtn.LabelRGB = t.OnAccent
	case pageGPU:
		a.gpuBtn.Face = t.Accent
		a.gpuBtn.LabelRGB = t.OnAccent
	case pageTrust:
		a.trustBtn.Face = t.Accent
		a.trustBtn.LabelRGB = t.OnAccent
	case pageMounts:
		a.mntBtn.Face = t.Accent
		a.mntBtn.LabelRGB = t.OnAccent
	}

	a.summary = widgets.Text{R: scaleR(natSummary), Label: a.status, Fg: t.Muted, Bg: t.Bg}
	a.header = widgets.Text{R: scaleR(natHeader), Label: a.tab.Header(), Fg: t.Accent, Bg: t.Surface}
	a.foot = widgets.Text{R: scaleR(natFoot), Label: a.footLine(), Fg: t.Muted, Bg: t.Bg}
	a.profTxt = widgets.Text{R: scaleR(natProf), Label: a.profLine, Fg: t.Muted, Bg: t.Bg}
	a.filterLabel = widgets.Text{R: scaleR(natFilterLabel), Label: "Filter:", Fg: t.Muted, Bg: t.Bg}
	a.filter.R = scaleR(natFilter)

	items := a.items
	sel := a.tab.SelIndex()
	switch a.pg {
	case pageNetwork:
		items = a.net.Lines()
		sel = -1
	case pageAgent:
		items = a.ag.Lines()
		sel = -1
	case pageGPU:
		items = a.gpu.Lines()
		sel = -1
	case pageTrust:
		items = a.tr.Lines()
		sel = -1
	case pageMounts:
		items = a.mnt.Lines()
		sel = -1
	}
	a.list = widgets.List{
		R:     scaleR(natList),
		Items: items,
		RowH:  scaleH(natRowH),
		Sel:   sel,
		Fg:    t.Text,
		Bg:    t.Bg,
		SelBg: t.Selection,
	}
	// §5.2: the scrollbar claims its track only while the content overflows;
	// the list keeps the full width when it is absent.
	vr := a.list.VisibleRows()
	maxTop := len(items) - vr
	if a.scrollTop > maxTop {
		a.scrollTop = maxTop
	}
	if a.scrollTop < 0 {
		a.scrollTop = 0
	}
	a.list.ScrollTop = a.scrollTop
	if len(items) > vr && vr > 0 {
		a.scroll = widgets.Scrollbar{
			R: widgets.Rect{
				X: a.list.R.Right() - widgets.ScrollbarW,
				Y: a.list.R.Y, W: widgets.ScrollbarW, H: a.list.R.H,
			},
			Total:    len(items),
			Viewport: vr,
			Offset:   a.scrollTop,
			Pressed:  a.scrollDrag,
		}
		a.list.R.W -= widgets.ScrollbarW + t.PadXS
	} else {
		a.scroll = widgets.Scrollbar{}
	}
}

// ensureVisible scrolls the proc list until the table's selection is inside
// the viewport — the keyboard path of the scrollbar's two-way binding.
func (a *app) ensureVisible() {
	vr := a.list.VisibleRows()
	sel := a.tab.SelIndex()
	if sel < a.scrollTop {
		a.scrollTop = sel
	}
	if sel >= a.scrollTop+vr {
		a.scrollTop = sel - vr + 1
	}
}

// footLine is the keyboard hint / status line.
func (a *app) footLine() string {
	switch a.pg {
	case pageNetwork:
		return "n procs   r refresh   a auto   rx/s " + vi.Itoa64(int64(a.net.RXRate)) +
			" B   tx/s " + vi.Itoa64(int64(a.net.TXRate)) + " B"
	case pageAgent:
		return "p procs   n net   c gpu   t trust   r refresh   a auto   u principal   v verified ! forged ? no-key x bad"
	case pageGPU:
		return "p procs   n net   g agent   t trust   r refresh   a auto"
	case pageTrust:
		return "p procs   n net   g agent   c gpu   m mounts   r refresh   a auto"
	case pageMounts:
		return "p procs   n net   g agent   c gpu   t trust   r refresh   a auto"
	}
	return "k kill   r refresh   a auto   n net   g agent   c gpu   t trust   m mnt   / filter   1-6 sort"
}

func (a *app) draw() {
	cv := a.ta.Canvas()
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(theme.Current.Bg))

	a.summary.Draw(cv)
	a.procsBtn.Draw(cv)
	a.netBtn.Draw(cv)
	a.agentBtn.Draw(cv)
	a.gpuBtn.Draw(cv)
	a.trustBtn.Draw(cv)
	a.mntBtn.Draw(cv)
	a.refreshBtn.Draw(cv)
	a.killBtn.Draw(cv)
	a.autoBtn.Draw(cv)
	if a.pg == pageProcs {
		a.filterLabel.Draw(cv)
		a.filter.Draw(cv)
		a.header.Draw(cv)
	}
	a.list.Draw(cv)
	a.scroll.Draw(cv)
	a.foot.Draw(cv)
	a.profTxt.Draw(cv)
}

// setPage switches tabs and reports it.
func (a *app) setPage(p page) bool {
	if a.pg == p {
		return false
	}
	a.pg = p
	switch p {
	case pageNetwork:
		a.net.Refresh()
		vi.ConsoleLine(markerNetwork)
	case pageAgent:
		vi.ConsoleLine(markerAgent)
		a.refreshAgent()
	case pageGPU:
		vi.ConsoleLine(markerGPU)
		a.refreshGPU()
	case pageTrust:
		vi.ConsoleLine(markerTrust)
		a.refreshTrust()
	case pageMounts:
		vi.ConsoleLine(markerMounts)
		a.refreshMounts()
	default:
		vi.ConsoleLine(markerProcs)
	}
	return true
}

// refreshAgent resamples the audit lane and prints its serial evidence:
// the count/verdict line, then one bounded marker per receipt row — the
// same row-dump discipline printRows uses on the procs tab.
func (a *app) refreshAgent() {
	a.ag.Refresh()
	vi.ConsoleLine(a.ag.Marker())
	for i := 0; i < rowMarkerMax; i++ {
		line, ok := a.ag.RowMarker(i)
		if !ok {
			break
		}
		vi.ConsoleLine(line)
	}
}

// refreshGPU resamples the slot-90 counters and prints the serial evidence —
// one marker carrying the whole block (the tab's rows are few and fixed, so
// there is no per-row dump to bound).
func (a *app) refreshGPU() {
	a.gpu.Refresh()
	vi.ConsoleLine(a.gpu.Marker())
}

// refreshMounts re-enumerates the kernel mount table and prints the
// serial evidence: the count line, then one bounded marker per row —
// name, state, kind, flags — the same row-dump discipline printRows uses.
func (a *app) refreshMounts() {
	a.mnt.Refresh()
	vi.ConsoleLine(a.mnt.Marker())
	for i := 0; i < rowMarkerMax; i++ {
		line, ok := a.mnt.RowMarker(i)
		if !ok {
			break
		}
		vi.ConsoleLine(line)
	}
}

// refreshTrust resamples the trust posture against the SAME process
// snapshot the procs table just took (one sys_procs read per refresh —
// the tab joins the table's rows, never a second snapshot). The serial
// evidence is the summary line, then a bounded per-app dump of the
// posture/hash/publisher markers and the receipt lines.
func (a *app) refreshTrust() {
	a.tr.Refresh(a.tab.Names())
	vi.ConsoleLine(a.tr.Marker())
	for i := 0; i < rowMarkerMax; i++ {
		line, ok := a.tr.AppMarker(i)
		if !ok {
			break
		}
		vi.ConsoleLine(line)
		sha, _ := a.tr.ShaMarker(i)
		vi.ConsoleLine(sha)
		pub, _ := a.tr.PubMarker(i)
		vi.ConsoleLine(pub)
	}
	for i := 0; i < rowMarkerMax; i++ {
		line, ok := a.tr.RcptMarker(i)
		if !ok {
			break
		}
		vi.ConsoleLine(line)
	}
	for i := 0; i < rowMarkerMax; i++ {
		line, ok := a.tr.DenialMarker(i)
		if !ok {
			break
		}
		vi.ConsoleLine(line)
	}
	// The denials summary prints last: it is the block's terminator, so a
	// gate waiting on it knows every entry marker has already landed.
	vi.ConsoleLine(a.tr.DenialsMarker())
}

// toggleAuto arms or disarms the 1 Hz app timer (slot 40/41).
func (a *app) toggleAuto() {
	a.auto = !a.auto
	if a.auto {
		vsys.TimerSet(autoRefreshTicks)
	} else {
		vsys.TimerCancel()
	}
}

// --- The filter (issue #2197) -------------------------------------------------
//
// TOP.BIN's retired C8 filter, restored on widgets.TextInput: `/` (or `f`)
// focuses the field, every edit narrows the table live by name substring,
// Enter commits (the field unfocuses, the filter stays applied, and its text
// survives for the next `/`), Escape clears it — the full list returns.

// bindFilter installs the field's submit/cancel callbacks once. The widget is
// a pure state machine; the app owns what Enter and Escape mean.
func (a *app) bindFilter() {
	a.filter.OnSubmit = func(string) { a.commitFilter() }
	a.filter.OnCancel = func() { a.cancelFilter() }
}

// openFilter focuses the field (`/`, `f`, or a click on the plate). It reports
// whether focus actually moved, so a repeat `/` while focused costs nothing.
func (a *app) openFilter() bool {
	if a.filter.Focused {
		return false
	}
	a.filter.Focused = true
	vi.ConsoleLine(markerFilterOpen)
	return true
}

// filterEdited rebuilds the view after the text changed mid-edit: the table
// narrows live, the marker reports the needle and the row count it left, and
// the row dump names exactly what the list now shows.
func (a *app) filterEdited() {
	a.tab.SetFilter(a.filter.Value())
	a.rebuildItems()
	vi.ConsoleLine(markerFilter + a.filter.Value() + " n=" + vi.Itoa64(int64(a.tab.Len())))
	a.printRows()
}

// commitFilter is Enter: the filter stays applied, the field unfocuses.
func (a *app) commitFilter() {
	a.filter.Focused = false
	vi.ConsoleLine(markerFilterCommit)
}

// cancelFilter is Escape: the text and the filter both clear, so the full
// table comes back — TOP.BIN's "Esc restores the list".
func (a *app) cancelFilter() {
	a.filter.Focused = false
	a.filter.Clear()
	a.tab.SetFilter("")
	a.rebuildItems()
	vi.ConsoleLine(markerFilterCleared)
	a.printRows()
}

// killSelected arms the highlighted process through slot 29. The marker is
// printed after the syscall returned and carries the kernel's own error code,
// so a refusal is evidence rather than silence (live-trust-caps pins -7).
func (a *app) killSelected() bool {
	p, ok := a.tab.Selected()
	if !ok {
		return false
	}
	rc := vi.Kill(p.PID)
	if rc == 0 {
		vi.ConsoleLine(markerKill + vi.Itoa64(int64(p.PID)))
		a.refreshAll(true, true)
	} else {
		vi.ConsoleLine(markerKill + vi.Itoa64(int64(p.PID)) + " err=" + vi.Itoa64(rc))
	}
	return true
}

// handle routes one non-lifecycle event. It reports whether the frame changed.
func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvTimer:
		if !a.auto {
			return false
		}
		a.refreshAll(false, false)
		vsys.TimerSet(autoRefreshTicks) // one timer in flight, never a queue
		return true
	case vi.EvKeyDown:
		return a.handleKey(ev)
	case vi.EvMouseMove:
		if a.scrollDrag {
			a.scrollTop = a.scroll.OffsetAt(int(ev.Arg1))
			return true
		}
		return false
	case vi.EvMouseUp:
		if a.scrollDrag {
			a.scrollDrag = false
			return true
		}
		return false
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft == 0 {
			return false
		}
		return a.handleClick(int(ev.Arg0), int(ev.Arg1))
	}
	return false
}

func (a *app) handleKey(ev vi.Event) bool {
	// A focused filter field eats every key on the procs page (TOP.BIN's
	// rule): the field interprets them, app chords stay inert until Enter or
	// Escape hands the keys back.
	if a.pg == pageProcs && a.filter.Focused {
		before := a.filter.Value()
		handled := a.filter.HandleKey(ev.Arg0, byte(ev.Arg1))
		if a.filter.Focused && a.filter.Value() != before {
			a.filterEdited()
			return true
		}
		return handled || !a.filter.Focused
	}
	switch ev.Arg0 {
	case keyUpArrow:
		if a.tab.MoveBy(-1) {
			a.ensureVisible()
			return true
		}
		return false
	case keyDownArrow:
		if a.tab.MoveBy(1) {
			a.ensureVisible()
			return true
		}
		return false
	}
	switch ev.Arg1 {
	case 'k', 'K':
		return a.killSelected()
	case 'r', 'R':
		a.refreshAll(true, true)
		return true
	case 'a', 'A':
		a.toggleAuto()
		return true
	case 'n', 'N':
		return a.setPage(pageNetwork)
	case 'p', 'P':
		return a.setPage(pageProcs)
	case 'g', 'G':
		return a.setPage(pageAgent)
	case 'u', 'U':
		// The audit tab's principal filter (all → user → agent); inert
		// everywhere else.
		if a.pg == pageAgent {
			vi.ConsoleLine(markerAgentFilter + a.ag.CycleFilter())
			return true
		}
		return false
	case 'c', 'C':
		return a.setPage(pageGPU)
	case 't', 'T':
		return a.setPage(pageTrust)
	case 'm', 'M':
		return a.setPage(pageMounts)
	case '/', 'f', 'F':
		if a.pg == pageProcs {
			return a.openFilter()
		}
		return false
	case keyOne:
		a.tab.SortBy(ColPID)
		return true
	case keyTwo:
		a.tab.SortBy(ColName)
		return true
	case keyThree:
		a.tab.SortBy(ColState)
		return true
	case keyFour:
		a.tab.SortBy(ColExit)
		return true
	case keyFive:
		a.tab.SortBy(ColCPU)
		return true
	case keySix:
		a.tab.SortBy(ColMem)
		return true
	}
	return false
}

func (a *app) handleClick(x, y int) bool {
	// The scrollbar owns its track strip: on the thumb the drag begins, off
	// it the click pages by a viewport (§5.2's track-click rule).
	if a.scroll.HitTest(x, y) {
		switch a.scroll.PageAt(x, y) {
		case 0:
			a.scrollDrag = true
		case -1:
			a.scrollTop -= a.list.VisibleRows()
		case 1:
			a.scrollTop += a.list.VisibleRows()
		}
		return true
	}
	if a.pg == pageProcs {
		// The filter plate takes focus on click; a click anywhere else while
		// it is focused just hands focus back (TOP.BIN's outside-click rule)
		// rather than firing the control under the pointer.
		if a.filter.HitTest(x, y) || a.filterLabel.HitTest(x, y) {
			return a.openFilter()
		}
		if a.filter.Focused {
			a.filter.Focused = false
			return true
		}
	}
	if a.procsBtn.HitTest(x, y) {
		return a.setPage(pageProcs)
	}
	if a.netBtn.HitTest(x, y) {
		return a.setPage(pageNetwork)
	}
	if a.agentBtn.HitTest(x, y) {
		return a.setPage(pageAgent)
	}
	if a.gpuBtn.HitTest(x, y) {
		return a.setPage(pageGPU)
	}
	if a.trustBtn.HitTest(x, y) {
		return a.setPage(pageTrust)
	}
	if a.mntBtn.HitTest(x, y) {
		return a.setPage(pageMounts)
	}
	if a.refreshBtn.HitTest(x, y) {
		a.refreshAll(true, true)
		return true
	}
	if a.killBtn.HitTest(x, y) {
		return a.killSelected()
	}
	if a.autoBtn.HitTest(x, y) {
		a.toggleAuto()
		return true
	}
	if a.pg == pageProcs {
		// Header click sorts on the column under the pointer (TOP's C8
		// behaviour), scaled with the same rect the header is drawn in.
		if a.header.HitTest(x, y) {
			a.tab.SortBy(a.columnAt(x, a.header.R))
			return true
		}
		if i := a.list.ItemAt(x, y); i >= 0 {
			return a.tab.SelectRow(i)
		}
	}
	return false
}

// columnAt maps an x inside the header to a column:
// PID | Name | State | Exit | CPU% | MEM, using the same widths the row
// label pads to, so the header and the rows cannot disagree about where a
// column starts. On a v1 snapshot the CPU/MEM columns are not drawn; a
// click that far right simply sorts an all-zero column.
func (a *app) columnAt(x int, header widgets.Rect) Column {
	rel := x - header.X
	// cell = 6 px per glyph; see rowLabel/Header for the same grid.
	const cell = 6
	pidEnd := 3 * cell
	nameEnd := (3 + 2 + 14) * cell
	stateEnd := (3 + 2 + 14 + 1 + 7) * cell
	exitEnd := (3 + 2 + 14 + 1 + 7 + 1 + 4) * cell
	cpuEnd := (3 + 2 + 14 + 1 + 7 + 1 + 4 + 2 + 5) * cell
	switch {
	case rel < pidEnd:
		return ColPID
	case rel < nameEnd:
		return ColName
	case rel < stateEnd:
		return ColState
	case rel < exitEnd:
		return ColExit
	case rel < cpuEnd:
		return ColCPU
	}
	return ColMem
}
