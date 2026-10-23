// GOTABWM.ELF — M161b (#2974): the seat's not-responding watchdog.
//
// A state-aware app that stops answering the seat's M125a state asks is
// wedged; an app with no state protocol that spins its CPU while holding
// focus is busy. Either earns a seat-painted banner over its pane —
// "<app> is not responding — Wait · Close · Force quit" — and answering
// again clears it silently.
//
// Liveness is the state-ask round trip, not a new wire (the card's D11
// reshape: no kernel change, no new WM_RPC kind). Every composite tick the
// watchdog posts ONE discovery ask to each bound live pane it has never
// asked — the notice sits in the app's mailbox until the app's own poll
// picks it up, so the ask costs one mailbox slot, once. An app that
// answers (any kind-20 serve: a watchdog ask, a lifecycle ask, an
// unsolicited save) latches wdProto and joins the sweep pool; an app that
// never answers is never asked again — liveness only watches speakers of
// the protocol, and the busy arm is the only eye on the rest.
//
// The sweep runs every watchAskEvery heartbeats (~1 Hz each): a pane whose
// previous watchdog ask is still outstanding collects a miss; two
// consecutive misses is wedged. The wedge marker names the window, the
// app's recorded name, and the round count:
//
//	gotabwm: watchdog wedged id=<win> app=<name> rounds=<n>
//	gotabwm: watchdog busy id=<win> cpu=<pct>
//	gotabwm: watchdog recovered id=<win>
//	gotabwm: watchdog closed id=<win> how=close|kill
//
// The busy arm reads the focused pane's bound pid through the ADR 0047
// procs-v2 snapshot: pct = 100·Δcpu·ncores/Δtotal between consecutive
// ticks, exactly the reader contract D6 pins (share of one core,
// top-style). watchBusyTicks consecutive ≥90% samples while focused flags
// it; the flag drops on the first below-threshold sample, on a protocol
// answer, or when the window dies.
//
// Force quit is probe-gated: the kill gate (kernel/src/syscall.zig
// handle_kill, ADR 0024 D5/D10) allows same-uid kills for every principal,
// uid_user → uid_agent unconditionally (M173b D12), and anything for
// CAP_PROC_ADMIN. There is no harmless sys_kill probe — every live
// same-uid target would really be armed — so the startup probe reads the
// seat's own principal (slot 68) and evaluates the rule the kernel will
// apply to the apps this seat hosts: uid_user and uid_agent seats always
// reach their own hosted apps (a uid_user seat reaches uid_agent ones
// too); anything else leaves the button unpainted and the reason on the
// serial line. A still-refused click reports its errno by name — the
// probe is about the seat's authority, not the target's uid, which the
// frozen procs row does not carry.
package main

import (
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const (
	// watchAskEvery is the liveness sweep period in composite heartbeats
	// (the ~1 Hz kind-18 tick): the card's 10 s.
	watchAskEvery = 10
	// watchWedgeRounds is the unanswered-ask count that wedges a
	// state-aware pane: the card's two consecutive rounds.
	watchWedgeRounds = 2
	// watchBusyPct / watchBusyTicks are the spin arm: a protocol-less app
	// holding focus while its pid runs ≥90% of one core for 15 s.
	watchBusyPct   = 90
	watchBusyTicks = 15
	// wdCapProcAdmin is process.cap_proc_admin (1<<1) — duplicated here
	// the same way trust.go duplicates the uid constants; the kernel
	// module is unreachable from the guest module graph.
	wdCapProcAdmin = 1 << 1
)

const (
	MarkerWatchdogWedged    = "gotabwm: watchdog wedged "
	MarkerWatchdogBusy      = "gotabwm: watchdog busy "
	MarkerWatchdogRecovered = "gotabwm: watchdog recovered "
	MarkerWatchdogClosed    = "gotabwm: watchdog closed "
	// MarkerWatchdogRefused reports a Close/Force-quit verb the kernel
	// turned down — the banner was offered, the seam refused.
	MarkerWatchdogRefused = "gotabwm: watchdog refused "
	// MarkerWatchdogForceQuit is the startup probe's one verdict line:
	// `armed` when the kill gate lets this seat force-quit its hosted
	// apps, `off` plus the reason otherwise.
	MarkerWatchdogForceQuit = "gotabwm: watchdog force-quit "
)

// The watchdog's per-window state, indexed by window id like rpcBindings
// and stateAskPend. All of it dies in watchdogDrop from dropRpcBinding —
// a reused id inherits none of its predecessor's liveness record.
var (
	wdProto     [256]bool  // the app has answered at least one kind-20
	wdAsked     [256]bool  // a watchdog-posted ask is outstanding
	wdEverAsked [256]bool  // the discovery ask has been posted
	wdMiss      [256]uint8 // consecutive unanswered watchdog asks
	wdWedged    [256]bool  // liveness verdict: banner up
	wdBusy      [256]bool  // spin verdict: banner up
	wdKilled    [256]bool  // force-quit armed by the watchdog (not a crash)
)

// The busy arm's focused-pane sampler. Only the pane holding focus can
// accrue; a focus move or a missing/unusable sample restarts the streak.
var (
	wdBusyWin    uint32 // the window currently accruing the streak
	wdBusyStreak int
	wdPrevCpu    uint64
	wdPrevTotal  uint64
	wdPrevInit   bool
	wdLastSweep  uint64 // seatTick of the last liveness sweep (batch-safe)
	wdSweepInit  bool
	wdKillOK     bool // the startup probe's verdict
)

// The seams. wdProcsUsage is procsCpuTicks's sibling over the same v2
// snapshot, returning the whole usage triple the percentage math needs.
// wdKill and wdPrincipal are the syscall seams (the execApp/readWindowName
// pattern): real slots on the guest, stubs in the host tests.
var (
	wdLog        = vi.ConsoleLine
	wdProcsUsage = func(pid uint8) (cpu, total, ncores uint64, ok bool) {
		var rows [64]vi.ProcRow
		n, r := vi.ProcsV2(rows[:])
		if r < 0 {
			return 0, 0, 0, false
		}
		for i := 0; i < n; i++ {
			if uint8(rows[i].PID) == pid {
				if rows[i].RowVer < vi.ProcRowVersion2 {
					return 0, 0, 0, false
				}
				return rows[i].CpuTicks, rows[i].TotalTicks,
					uint64(rows[i].NCores), true
			}
		}
		return 0, 0, 0, false
	}
	wdKill      = vi.Kill
	wdPrincipal = vi.Principal
)

// watchdogLivePane reports whether id names a pane the liveness arm
// watches: on the active strip, a real kernel window (not a session
// placeholder), and bound to a live owner pid. A bound pid that already
// exited is no pane at all — its mirror teardown owns the row.
func watchdogLivePane(id uint32) bool {
	if id >= sessionIDBase || id > 255 {
		return false
	}
	if tabs.index(id) < 0 {
		return false
	}
	pid := rpcBindings[id].pid
	return pid != 0 && procsAlive(pid)
}

// watchdogAppName is the banner/marker name for a watched pane: the rail's
// title first, its recorded bin next, the window id last — the same
// fallback chain serveStateSave uses for the state-drop marker.
func watchdogAppName(id uint32) string {
	if i := tabs.index(id); i >= 0 {
		if t := tabs.tabs[i].Title; t != "" {
			return t
		}
		if t := tabs.tabs[i].Bin; t != "" {
			return t
		}
	}
	return vi.Itoa64(int64(id))
}

// watchdogAsk posts one state ask through the M125a seam and records the
// watchdog's own bookkeeping for it — shared by the discovery pass and the
// sweep's repost so both marks stay in step.
func watchdogAsk(id uint32) {
	if askStateSave(id, "watchdog") {
		wdEverAsked[id] = true
		wdAsked[id] = true
	}
}

// watchdogDiscover posts the one-shot discovery ask to every bound live
// pane never asked before. It runs every heartbeat so a fresh declare is
// asked inside a tick or two — the notice waits in the app's mailbox, so
// the post itself is the whole cost. Panes with any ask outstanding are
// skipped: the sweep owns their cadence.
func watchdogDiscover() {
	for i := 0; i < tabs.count; i++ {
		id := tabs.tabs[i].ID
		if !watchdogLivePane(id) || wdEverAsked[id] || wdAsked[id] {
			continue
		}
		watchdogAsk(id)
	}
}

// watchdogSweep is the 10 s liveness round. Only protocol speakers are
// scored or re-asked: a pane that never answered keeps its one outstanding
// discovery ask and stays outside the count (the busy arm watches it
// instead). An outstanding ask at sweep time is one miss; an answered ask
// already cleared wdAsked in watchdogNoteAnswer, so wdAsked==false here
// means answered and the streak resets.
func watchdogSweep() {
	for i := 0; i < tabs.count; i++ {
		id := tabs.tabs[i].ID
		if !watchdogLivePane(id) || !wdProto[id] {
			continue
		}
		if wdAsked[id] {
			wdMiss[id]++
			if wdMiss[id] >= watchWedgeRounds && !wdWedged[id] {
				wdWedged[id] = true
				wdLog(MarkerWatchdogWedged + "id=" + vi.Itoa64(int64(id)) +
					" app=" + watchdogAppName(id) +
					" rounds=" + vi.Itoa64(int64(wdMiss[id])))
			}
		} else {
			wdMiss[id] = 0
		}
		watchdogAsk(id)
	}
}

// watchdogBusy is the spin arm, run every heartbeat: the focused pane
// without the state protocol earns a busy flag after watchBusyTicks
// consecutive ≥90%-of-one-core samples (ADR 0047 D6 reader math). No
// sample is no evidence — a v1 kernel or an unreadable table resets the
// streak, never pads it. The flag drops on the first below-threshold
// sample while focused; an unfocused pane keeps both its streak's pause
// (sampling stops) and a raised flag (the last observation stands).
func watchdogBusy() {
	fid, ok := tabs.Focused()
	if !ok || fid >= sessionIDBase || fid > 255 || wdProto[fid] || wdWedged[fid] {
		// Focused on nothing watchable — or the pane speaks the protocol
		// and the liveness arm owns the verdict. The streak survives a
		// focus hop to another spin candidate only in the sense that
		// wdBusyWin switching re-seeds it below.
		return
	}
	pid := rpcBindings[fid].pid
	if pid == 0 {
		return
	}
	cpu, total, ncores, ok := wdProcsUsage(pid)
	if !ok {
		wdPrevInit = false
		wdBusyStreak = 0
		if wdBusy[fid] {
			wdBusy[fid] = false
		}
		return
	}
	if wdBusyWin != fid {
		wdBusyWin = fid
		wdPrevInit = false
		wdBusyStreak = 0
	}
	if wdPrevInit {
		dcpu := cpu - wdPrevCpu
		dtot := total - wdPrevTotal
		pct := int64(0)
		if dtot > 0 {
			pct = int64(dcpu * ncores * 100 / dtot)
		}
		if pct >= watchBusyPct {
			wdBusyStreak++
			if wdBusyStreak >= watchBusyTicks && !wdBusy[fid] {
				wdBusy[fid] = true
				wdLog(MarkerWatchdogBusy + "id=" + vi.Itoa64(int64(fid)) +
					" cpu=" + vi.Itoa64(pct))
			}
		} else {
			wdBusyStreak = 0
			if wdBusy[fid] {
				wdBusy[fid] = false
			}
		}
	}
	wdPrevCpu, wdPrevTotal, wdPrevInit = cpu, total, true
}

// watchdogTick is the heartbeat-paced entry, called from compositeTick.
// The busy sampler runs every pass; the sweep is cadenced by the
// consumed-tick count, not the clock modulo — a merged heartbeat batch can
// step over a %10 boundary, so the interval is measured — and it runs
// BEFORE the discovery pass so an ask posted this tick is never scored a
// miss in the same pass.
func watchdogTick(ticks uint64) {
	watchdogBusy()
	if !wdSweepInit || ticks-wdLastSweep >= watchAskEvery {
		wdSweepInit = true
		wdLastSweep = ticks
		watchdogSweep()
	}
	watchdogDiscover()
}

// watchdogNoteAnswer is the kind-20 serve's notification that id's app is
// alive and speaking: latch the protocol bit, clear the outstanding ask,
// reset the round counter, and — when the banner was up — print the
// recovery and drop it. Called from serveStateSave before any early
// return: the request itself is the proof of life; whether the blob then
// decodes is a separate verdict.
func watchdogNoteAnswer(id uint8) {
	wdProto[id] = true
	wdAsked[id] = false
	wdMiss[id] = 0
	if wdWedged[id] {
		wdWedged[id] = false
		wdLog(MarkerWatchdogRecovered + "id=" + vi.Itoa64(int64(id)))
	}
	if wdBusy[id] {
		wdBusy[id] = false
	}
}

// watchdogDrop forgets every watchdog bit for a window leaving the
// registry — dropRpcBinding's caller, beside clearAppState.
func watchdogDrop(id uint32) {
	if id > 255 {
		return
	}
	wdProto[id] = false
	wdAsked[id] = false
	wdEverAsked[id] = false
	wdMiss[id] = 0
	wdWedged[id] = false
	wdBusy[id] = false
	wdKilled[id] = false
	if wdBusyWin == id {
		wdBusyWin = 0
		wdBusyStreak = 0
		wdPrevInit = false
	}
}

// watchdogBannerUp reports whether id's pane carries the banner this frame.
func watchdogBannerUp(id uint32) bool {
	return id < 256 && (wdWedged[id] || wdBusy[id])
}

// watchdogProbeKillGate is the startup probe named in the card: read the
// seat's own principal once and evaluate the kill-gate rule for the apps
// this seat will host. uid_user/uid_agent seats always pass same-uid kills
// (their exec'd children share the uid) and uid_user additionally reaches
// uid_agent (D12); CAP_PROC_ADMIN reaches everything; anything else — and
// an identity the kernel will not report — leaves Force quit unpainted
// with the reason on the serial line.
func watchdogProbeKillGate() {
	uid, caps, ok := wdPrincipal()
	switch {
	case !ok:
		wdKillOK = false
		wdLog(MarkerWatchdogForceQuit + "off why=identity")
	case caps&wdCapProcAdmin != 0 || uid == vi.UidUser || uid == vi.UidAgent:
		wdKillOK = true
		wdLog(MarkerWatchdogForceQuit + "armed")
	default:
		wdKillOK = false
		wdLog(MarkerWatchdogForceQuit + "off uid=" + vi.Itoa64(int64(uid)) +
			" caps=" + vi.Itoa64(int64(caps)) + " why=principal")
	}
}

// ---------------------------------------------------------------------------
// The banner. One layout function owns every rect so the paint and the
// pointer hit-test can never disagree (the notifyRect / spacePillRects
// discipline).

const (
	watchBannerH    = 24
	watchBannerPadX = 8
	watchBtnPadX    = 8
	watchBtnSep     = " · "
	watchBtnLead    = " — "
)

// Banner verbs. watchdogHit reports which zone a press landed in; the
// band body itself is chrome that consumes the click without acting.
const (
	wdActNone = iota
	wdActWait
	wdActClose
	wdActForce
)

// watchdogLayout computes the banner strip and its button zones for one
// flagged pane. The strip spans the pane's width at its top edge, pushed
// below the rail when the pane rect covers the rail band (a full-viewport
// leaf). Buttons are right-aligned inside the strip, Force quit last and
// only when the probe armed it — an unarmed probe removes the zone, never
// greys it. Zero rects come back when the pane cannot hold the strip.
func watchdogLayout(id uint32, scanW, scanH int) (strip, wait, close, force widgets.Rect) {
	pane, _ := tabs.rectOf(id, uint32(scanW), uint32(scanH))
	strip = widgets.Rect{X: int(pane.X), Y: int(pane.Y), W: int(pane.W), H: watchBannerH}
	if strip.Y < RailHeight {
		strip.Y = RailHeight
	}
	if strip.W <= 0 || strip.Y+strip.H > scanH {
		return widgets.Rect{}, widgets.Rect{}, widgets.Rect{}, widgets.Rect{}
	}
	// Right-aligned button row: measure each label at chrome size, Force
	// quit outermost. The painted text uses the same extents (paintWatchdog
	// walks these rects), so a painted button is exactly its hit zone.
	x := strip.X + strip.W - watchBannerPadX
	btn := func(label string) widgets.Rect {
		w := seatTextWidth(label, seatTextPx) + 2*watchBtnPadX
		x -= w
		r := widgets.Rect{X: x, Y: strip.Y + 2, W: w, H: strip.H - 4}
		x -= seatTextWidth(watchBtnSep, seatTextPx)
		return r
	}
	if wdKillOK {
		force = btn("Force quit")
	}
	close = btn("Close")
	wait = btn("Wait")
	if wait.X < strip.X {
		// The pane is too narrow for the row — drop the strip rather
		// than paint zones that overhang the pane's left edge.
		return widgets.Rect{}, widgets.Rect{}, widgets.Rect{}, widgets.Rect{}
	}
	return strip, wait, close, force
}

// watchdogHit maps a scanout point to (window id, verb). Banners are
// checked newest-flagged-last ordering is irrelevant — a point belongs to
// at most one pane, so the walk order cannot pick wrong.
func watchdogHit(px, py uint32, scanW, scanH int) (uint32, int) {
	for i := 0; i < tabs.count; i++ {
		id := tabs.tabs[i].ID
		if !watchdogBannerUp(id) {
			continue
		}
		strip, wait, close, force := watchdogLayout(id, scanW, scanH)
		if strip.W <= 0 {
			continue
		}
		if int(px) < strip.X || int(px) >= strip.X+strip.W ||
			int(py) < strip.Y || int(py) >= strip.Y+strip.H {
			continue
		}
		in := func(r widgets.Rect) bool {
			return r.W > 0 && int(px) >= r.X && int(px) < r.X+r.W
		}
		switch {
		case in(wait):
			return id, wdActWait
		case in(close):
			return id, wdActClose
		case in(force):
			return id, wdActForce
		default:
			return id, wdActNone
		}
	}
	return 0, wdActNone
}

// watchdogPress applies one banner verb. Wait re-arms the round counter
// (the banner drops and the next wedge takes a fresh two rounds; the busy
// streak re-seeds too). Close runs the ordinary closeTabByID seam so the
// markers keep their single shape — with the watchdog's own `closed` line
// after it — and the save ask is skipped when the pane is provably
// unanswering (closeTabByID consults the same flags). Force arms sys_kill
// on the bound owner, gated by the startup probe; both outcomes are named.
func watchdogPress(id uint32, act int) {
	if id > 255 {
		return
	}
	switch act {
	case wdActWait:
		wdMiss[id] = 0
		wdWedged[id] = false
		wdBusy[id] = false
		if wdBusyWin == id {
			wdBusyStreak = 0
			wdPrevInit = false
		}
	case wdActClose:
		// closeTabByID prints the closed marker itself for flagged panes
		// (every close path lands there); here only the refusal needs a
		// line.
		if !closeTabByID(id) {
			wdLog(MarkerWatchdogRefused + "id=" + vi.Itoa64(int64(id)) + " how=close")
		}
	case wdActForce:
		if !wdKillOK {
			return
		}
		pid := rpcBindings[id].pid
		if pid == 0 {
			return
		}
		if r := wdKill(uint64(pid)); r == 0 {
			// The armed kill exits the process at its next ring
			// selection; wdKilled keeps the released mirror's crash
			// arm quiet — this exit was ordered, not a crash.
			wdKilled[id] = true
			wdLog(MarkerWatchdogClosed + "id=" + vi.Itoa64(int64(id)) + " how=kill")
		} else {
			wdLog(MarkerWatchdogRefused + "id=" + vi.Itoa64(int64(id)) +
				" how=kill err=" + vi.ErrnoName(r))
		}
	}
}

// paintWatchdog draws every flagged pane's banner and returns the pixels
// written — the paintNotify contract. Banners sit under the launcher,
// power menu, toasts, drag ghost and the idle curtain (the pointer path
// hits them in the same order).
func paintWatchdog(scan []byte, width, height int) int {
	if width <= 0 || height <= 0 || len(scan) < 4 {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	written := 0
	for i := 0; i < tabs.count; i++ {
		id := tabs.tabs[i].ID
		if !watchdogBannerUp(id) {
			continue
		}
		strip, wait, close, force := watchdogLayout(id, width, height)
		if strip.W <= 0 {
			continue
		}
		written += seatPlate(c, strip, radiusControl, tok.Danger, tok.Surface)
		y := strip.Y + watchBannerPadX - 4
		label := watchdogAppName(id) + " is not responding"
		seatText(c, strip, strip.X+watchBannerPadX, y, seatTextPx, label, tok.Text)
		// The lead-in dash belongs to the buttons' band, not the label.
		seatText(c, strip, wait.X-seatTextWidth(watchBtnLead, seatTextPx), y,
			seatTextPx, watchBtnLead, tok.Muted)
		for _, b := range []struct {
			r     widgets.Rect
			label string
		}{{wait, "Wait"}, {close, "Close"}, {force, "Force quit"}} {
			if b.r.W <= 0 {
				continue
			}
			seatText(c, strip, b.r.X+watchBtnPadX, y, seatTextPx, b.label, tok.Accent)
		}
	}
	return written
}
