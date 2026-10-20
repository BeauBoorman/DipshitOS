// Command goclock is GOCLOCK.ELF — M144a (#2794): the Clock app, four tabs
// (World, Stopwatch, Timer, Alarm) full-viewport inside the Go tabbed
// desktop via user/go/tabapp.
//
// Time source split: the faces and every deadline compare in wall-clock
// seconds (vi.Now's epoch, formatted by clockfmt) while the stopwatch
// counts vsys.Nanotime's monotonic EL0 counter — a wall step moves the
// calendar, never a measurement.
//
// ONE scheduler (sched.go) multiplexes every deadline — the world face's
// 1 Hz repaint, the countdown, the daily alarm — onto the process's
// single kernel app timer (sys_timer_set / EvTimer kind 9, re-armed after
// each fire: the kernel timer is one-shot). A fired user deadline raises
// a seat toast through vi.Notify and prints `goclock: fired <id>`; an
// alarm repeats daily at most.
//
// Input: Left/Right/Tab or a strip click switches tabs; Space/'s' and 'r'
// drive the stopwatch; digits + Return arm and 'x' cancels on the Timer
// and Alarm tabs.
//
// Every marker is printed only AFTER the call it reports returned, so the
// go-clock VZ gate's asserts cannot pass on an app that did not do the
// work. `goclock: painted epoch=<n>` is the post-present marker — the
// world-face snapshot anchor — printed once per painted frame, and only
// while the World tab is showing.
package main

import (
	"virelai/clockfmt"
	"virelai/draw"
	"virelai/settings"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/widgets"
)

const (
	appName  = "GOCLOCK.ELF"
	appTitle = "Clock"
	natW     = 640
	natH     = 400

	markerOpen     = "goclock: open id="
	markerDeclare  = "goclock: declare accepted"
	markerDeclined = "goclock: declare refused"
	markerZones    = "goclock: zones "
	markerZoneRow  = "goclock: zone "
	markerSub      = "goclock: settings subscribed key="
	markerPresent  = "goclock: present"
	markerPainted  = "goclock: painted epoch="
	markerTab      = "goclock: tab "
	markerKTimer   = "goclock: ktimer armed"
	markerKTFail   = "goclock: ktimer arm failed rc="
	markerFired    = "goclock: fired "
	markerNotifyNo = "goclock: notify refused "
	markerSwStart  = "goclock: stopwatch start"
	markerSwStop   = "goclock: stopwatch stop elapsed="
	markerSwReset  = "goclock: stopwatch reset"
	markerTArm     = "goclock: timer armed "
	markerTCancel  = "goclock: timer cancel"
	markerTRefuse  = "goclock: timer refused"
	markerAArm     = "goclock: alarm armed "
	markerACancel  = "goclock: alarm cancel"
	markerARefuse  = "goclock: alarm refused"
	markerARestore = "goclock: alarm restored "
	markerASaved   = "goclock: alarm saved"
	markerASaveBad = "goclock: alarm save failed rc="
	markerAFileBad = "goclock: alarm file bad"
	markerStRest   = "goclock: state restored"
	markerStRefuse = "goclock: state refused"
	markerStPosted = "goclock: state posted"
	markerDFull    = "goclock: deadline full"
	markerClose    = "goclock: close"
	markerOK       = "goclock OK"

	keyEnter  = 0x28
	keyEscape = 0x29
	keyBacksp = 0x2a
	keyTab    = 0x2b
	keyRight  = 0x4f
	keyLeft   = 0x50

	// faceDeadline is the 1 Hz repaint entry — a Quiet deadline, so the
	// second hand's cadence never raises a toast or a `fired` marker.
	faceDeadline = "face"

	// alarmPath is the persisted record's share file. The save_state blob
	// carries the same bytes; the file is the always-current half — it is
	// rewritten on every arm/cancel while the blob is a snapshot capture.
	alarmPath = "/host/GOCLOCK.ALARM"
)

// The tab ids are their own block: iota is the const-spec INDEX inside its
// block, so declaring them beside the markers above would start the world
// tab at ~30 and a.tab=0 would match nothing — the exact shape the first
// gate run hit (no face ever painted, no painted marker).
const (
	tabWorld = iota
	tabStopwatch
	tabTimer
	tabAlarm
	tabCount
)

var tabNames = [tabCount]string{"world", "stopwatch", "timer", "alarm"}

// Layout — fixed native geometry (the seat's fullscreen resize keeps the
// same canvas origin, so painted cells land on the scanout 1:1).
var (
	stripR = widgets.Rect{X: 16, Y: 24, W: 608, H: 20}
	// displayR is the big readout plate shared by Stopwatch/Timer/Alarm.
	displayR = widgets.Rect{X: 16, Y: 56, W: 608, H: 40}
	// entryR is the typed-field plate on the Timer and Alarm tabs.
	entryR = widgets.Rect{X: 16, Y: 104, W: 608, H: 24}
	hintR  = widgets.Rect{X: 16, Y: 136, W: 608, H: 16}
	btnR0  = widgets.Rect{X: 16, Y: 164, W: 148, H: 28}
	btnR1  = widgets.Rect{X: 172, Y: 164, W: 148, H: 28}
	// worldRowR returns the i-th World row's plate — the gate's probe
	// rects in the spec comment compute from these exact constants.
)

func worldRowR(i int) widgets.Rect {
	return widgets.Rect{X: 16, Y: 56 + i*20, W: 608, H: 18}
}

func stripCell(i int) widgets.Rect {
	return widgets.Rect{X: stripR.X + i*stripR.W/tabCount, Y: stripR.Y, W: stripR.W / tabCount, H: stripR.H}
}

// drawText paints one labelled plate (widgets.Text.Draw has a pointer
// receiver, so the call sites cannot chain it off a literal).
func drawText(cv widgets.Canvas, r widgets.Rect, label string, fg, bg uint32) {
	t := widgets.Text{R: r, Label: label, Fg: fg, Bg: bg}
	t.Draw(cv)
}

// app is the whole UI state: which tab, its models, and the multiplexer.
type app struct {
	ta    *tabapp.TabApp
	tab   int
	zones []clockfmt.Zone
	local clockfmt.Zone
	sched Sched
	sw    Stopwatch
	entry [2]DigitEntry // [tabTimer], [tabAlarm]
	dirty bool

	// clock seams — the guest binds vi.Now/vsys.Nanotime; host tests inject.
	now  func() int64
	nano func() int64

	// restored latches the one-shot restore pass: the kind-21 request runs
	// once inside the event loop, not from tabapp.Init (see the Config).
	restored bool
	// alarmHHMM is the civil field the armed daily alarm was typed as —
	// the sched deadline knows only the epoch; the record needs both.
	alarmHHMM int

	buttons      [2]widgets.Button
	paintedEpoch int64
	ktArmed      bool
}

func (a *app) entryFor(tab int) *DigitEntry { return &a.entry[tab-tabTimer] }

// The persisted-record seams — vi.WriteFileSafe/ReadFileAll/FileDelete cross
// the raw syscall gateway on the guest and degrade off it, so the vars are
// the host-test surface (the appstate.go / session.go pattern).
var (
	alarmFileWrite = vi.WriteFileSafe
	alarmFileRead  = vi.ReadFileAll
	alarmFileDel   = vi.FileDelete
)

func loadGuestTheme() {
	b, r := vi.ReadFileAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

func main() {
	loadGuestTheme()
	a := &app{now: vi.Now, nano: vsys.Nanotime}
	a.local = settings.Load().Timezone()
	a.zones = worldZones(a.local)
	a.entry[tabTimer-tabTimer] = NewDigitEntry(timerEntryDigits)
	a.entry[tabAlarm-tabTimer] = NewDigitEntry(4)

	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH,
		// M144b (#2795): the armed alarm rides the seat's save/restore
		// channel — SaveState answers the snapshot/close asks and the
		// unsolicited push. RestoreState is deliberately NOT hooked: the
		// kind-21 request is a blocking mailbox round-trip, and a resize
		// queued while it waits can only be Dispatched after it returns —
		// so the request runs once inside the loop after the first event
		// drain instead (applyPersistedAlarm).
		StateVersion: 1,
		SaveState:    a.saveBlob,
	})
	if ta == nil {
		vi.ConsoleLine("goclock: open failed")
		vi.Exit(1)
	}
	a.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine(markerDeclined)
	}
	vi.ConsoleLine(markerZones + "local=" + clockfmt.Label(a.local) + " n=" + vi.Itoa64(int64(len(a.zones))))
	for i, z := range a.zones {
		vi.ConsoleLine(markerZoneRow + vi.Itoa64(int64(i)) + " " + clockfmt.Label(z))
	}
	for _, key := range []string{"timezone", "theme"} {
		if settings.Subscribe(key, uint32(ta.Win), appName) {
			vi.ConsoleLine(markerSub + key)
		}
	}

	// The face deadline is always armed, so the scheduler's arm decision
	// is always "the next second" — and the one kernel timer ticks the
	// repaint and counts user deadlines alike.
	a.sched.Add(Deadline{ID: faceDeadline, At: a.now() + 1, Repeat: 1, Quiet: true})
	a.armTimer()

	a.paint()
	ta.Present()
	vi.ConsoleLine(markerPresent)
	a.flushPainted()

	for {
		progress := false
		for {
			ev, result, ok := vi.PollEventRaw()
			if !ok {
				if result < 0 {
					a.shutdown(0)
				}
				break
			}
			progress = true
			switch ta.Dispatch(ev) {
			case tabapp.ActionClosed:
				a.shutdown(0)
			case tabapp.ActionResized:
				a.dirty = true
			case tabapp.ActionNone:
				if a.handle(ev) {
					a.dirty = true
				}
			}
		}
		if a.pollSettings() {
			a.dirty = true
		}
		// The restore request must precede the save poll on the first
		// pass: a session-restore boot's seat asks the re-exec'd app for
		// state, and an empty answer (nothing armed yet) closes the
		// exchange — the kind-21 request that follows is refused
		// (go-clock run 05: `state save len=0` then `rpc refuse kind=21`).
		if !a.restored {
			a.restored = true
			a.applyPersistedAlarm()
		}
		// The seat's save ask is mailbox traffic, not an input event —
		// answer it once per pass so a snapshot/close ask is serviced
		// inside this app's own slice.
		ta.PollStateAsk()
		if a.dirty {
			a.dirty = false
			a.paint()
			ta.Present()
			a.flushPainted()
		}
		if !progress {
			vi.Sleep(1)
		}
	}
}

// armTimer translates the scheduler's arm decision into the single
// sys_timer_set — the kernel timer is one-shot, so every EvTimer and every
// arm/clear lands back here.
func (a *app) armTimer() {
	d := a.sched.ArmDelay(a.now())
	if d <= 0 {
		vsys.TimerCancel()
		return
	}
	if rc := vsys.TimerSet(uint64(d)); rc < 0 {
		vi.ConsoleLine(markerKTFail + vi.Itoa64(rc))
		return
	}
	// The arm marker is once per process: the kernel timer re-arms every
	// tick by design, and a per-second marker would only add noise.
	if !a.ktArmed {
		a.ktArmed = true
		vi.ConsoleLine(markerKTimer)
	}
}

// onTimer is the EvTimer fan-out: fire the due deadlines (marker + toast
// for the user-facing ones), then repaint and re-arm.
func (a *app) onTimer() {
	now := a.now()
	for _, d := range a.sched.Fire(now) {
		if d.Quiet {
			continue
		}
		vi.ConsoleLine(markerFired + d.ID)
		if !a.ta.Notify(d.ID + " done") {
			vi.ConsoleLine(markerNotifyNo + d.ID)
		}
	}
	a.armTimer()
	a.dirty = true
}

func (a *app) handle(ev vi.Event) bool {
	switch ev.Kind {
	case vi.EvTimer:
		a.onTimer()
		return a.dirty
	case vi.EvKeyDown:
		return a.key(ev)
	case vi.EvMouseDown:
		if ev.Flags&vi.BtnLeft == 0 {
			return false
		}
		return a.click(int(ev.Arg0), int(ev.Arg1))
	}
	return false
}

func (a *app) key(ev vi.Event) bool {
	if ev.Flags&vi.ModCtrl != 0 {
		return false
	}
	// 'q' quits from any tab (Escape is not a gate chord; the seat's rail
	// close remains the WIN_CLOSE path).
	if ch := ev.Arg1; ch == 'q' || ch == 'Q' {
		a.shutdown(0)
	}
	switch ev.Arg0 {
	case keyLeft:
		return a.setTab((a.tab + tabCount - 1) % tabCount)
	case keyRight, keyTab:
		return a.setTab((a.tab + 1) % tabCount)
	case keyBacksp:
		if a.tab >= tabTimer {
			return a.entryFor(a.tab).Backspace()
		}
		return false
	case keyEnter:
		switch a.tab {
		case tabTimer:
			return a.armCountdown()
		case tabAlarm:
			return a.armAlarm()
		}
		return false
	}
	ch := ev.Arg1
	switch a.tab {
	case tabStopwatch:
		switch ch {
		case ' ', 's', 'S':
			a.sw.Toggle(a.nano())
			if a.sw.Running() {
				vi.ConsoleLine(markerSwStart)
			} else {
				vi.ConsoleLine(markerSwStop + vi.Itoa64(a.sw.Elapsed(a.nano())/1_000_000_000))
			}
			return true
		case 'r', 'R':
			a.sw.Reset()
			vi.ConsoleLine(markerSwReset)
			return true
		}
	case tabTimer, tabAlarm:
		if ch >= '0' && ch <= '9' {
			return a.entryFor(a.tab).Digit(int(ch - '0'))
		}
		switch ch {
		case 'x', 'X':
			return a.cancelTab()
		}
	}
	return false
}

func (a *app) click(x, y int) bool {
	if stripR.Contains(x, y) {
		for i := 0; i < tabCount; i++ {
			if stripCell(i).Contains(x, y) {
				return a.setTab(i)
			}
		}
		return false
	}
	switch a.tab {
	case tabStopwatch:
		if a.buttons[0].HitTest(x, y) {
			a.sw.Toggle(a.nano())
			if a.sw.Running() {
				vi.ConsoleLine(markerSwStart)
			} else {
				vi.ConsoleLine(markerSwStop + vi.Itoa64(a.sw.Elapsed(a.nano())/1_000_000_000))
			}
			return true
		}
		if a.buttons[1].HitTest(x, y) {
			a.sw.Reset()
			vi.ConsoleLine(markerSwReset)
			return true
		}
	case tabTimer:
		if a.buttons[0].HitTest(x, y) {
			return a.armCountdown()
		}
		if a.buttons[1].HitTest(x, y) {
			return a.cancelTab()
		}
	case tabAlarm:
		if a.buttons[0].HitTest(x, y) {
			return a.armAlarm()
		}
		if a.buttons[1].HitTest(x, y) {
			return a.cancelTab()
		}
	}
	return false
}

func (a *app) setTab(t int) bool {
	if t == a.tab {
		return false
	}
	a.tab = t
	vi.ConsoleLine(markerTab + tabNames[t])
	return true
}

// --- tab actions -------------------------------------------------------------

func (a *app) armCountdown() bool {
	e := a.entryFor(tabTimer)
	now := a.now()
	if e.Empty() || e.Value() <= 0 || now < 0 {
		vi.ConsoleLine(markerTRefuse)
		return false
	}
	secs := int64(e.Value())
	if !a.sched.Add(Deadline{ID: "timer", At: now + secs}) {
		vi.ConsoleLine(markerDFull)
		return false
	}
	vi.ConsoleLine(markerTArm + vi.Itoa64(secs))
	a.armTimer()
	return true
}

func (a *app) armAlarm() bool {
	e := a.entryFor(tabAlarm)
	h, m, ok := parseHHMM(e.Value())
	now := a.now()
	if e.Empty() || !ok || now < 0 {
		vi.ConsoleLine(markerARefuse)
		return false
	}
	at := alarmAt(now, a.local, h, m)
	// Repeats daily at most: 86400 is the floor for a re-armed alarm, so a
	// fire can never wake the user twice inside one day.
	if !a.sched.Add(Deadline{ID: "alarm", At: at, Repeat: 86400}) {
		vi.ConsoleLine(markerDFull)
		return false
	}
	vi.ConsoleLine(markerAArm + two(int64(h)) + ":" + two(int64(m)))
	a.alarmHHMM = h*100 + m
	a.persistAlarm(at, a.alarmHHMM)
	a.armTimer()
	return true
}

func (a *app) cancelTab() bool {
	var id string
	if a.tab == tabTimer {
		id = "timer"
	} else if a.tab == tabAlarm {
		id = "alarm"
	}
	if id == "" || !a.sched.Cancel(id) {
		return false
	}
	if a.tab == tabTimer {
		vi.ConsoleLine(markerTCancel)
	} else {
		vi.ConsoleLine(markerACancel)
		a.alarmHHMM = 0
		a.unpersistAlarm()
	}
	a.armTimer()
	return true
}

// --- alarm persistence (M144b, #2795) ------------------------------------------
//
// The armed daily alarm survives the app through two carriers that share one
// record (`gocal1 <at> <hhmm>`, model.go):
//
//   - the share file at alarmPath, rewritten crash-safe on every arm and
//     deleted on cancel — it is the always-current half and survives any
//     reboot the share survives;
//   - the seat's save_state/restore_state blob (SESSION.TABS trailer),
//     pushed on arm/cancel and answered on the snapshot/close asks — it is
//     a capture of whatever was stored when the seat asked.
//
// At start the file wins when both decode: it tracks mutations the snapshot
// predates. A record whose `at` is already past fires once immediately,
// marked late — that is what "the alarm came due while the machine was
// suspended or rebooted" looks like from the app's side. The daily repeater
// re-arms at the next future occurrence, so the late fire never costs the
// user tomorrow's alarm.

// saveBlob is the tabapp.SaveState hook: the current record, or nil when no
// alarm is armed (an empty answer is "no state", never a fabricated one).
func (a *app) saveBlob() []byte {
	for _, d := range a.sched.ds {
		if d.ID == "alarm" {
			return encodeAlarm(d.At, a.alarmHHMM)
		}
	}
	return nil
}

// persistAlarm publishes the armed record through both carriers — the file
// first (the durable half), then the unsolicited state push so the seat's
// stored blob is already current if a crash lands before the next ask.
func (a *app) persistAlarm(at int64, hhmm int) {
	b := encodeAlarm(at, hhmm)
	if b == nil {
		return
	}
	if rc := alarmFileWrite(alarmPath, b); rc != 0 {
		vi.ConsoleLine(markerASaveBad + vi.Itoa64(rc))
		return
	}
	vi.ConsoleLine(markerASaved)
	if a.ta != nil && a.ta.SaveStateNow() {
		vi.ConsoleLine(markerStPosted)
	}
}

// unpersistAlarm clears both carriers: the file goes away and the pushed
// empty blob erases the seat's stored record, so a cancelled alarm cannot
// be revived by a later restore.
func (a *app) unpersistAlarm() {
	if rc := alarmFileDel(alarmPath); rc != 0 && rc != vi.ErrFileNotFound {
		vi.ConsoleLine(markerASaveBad + vi.Itoa64(rc))
	}
	if a.ta != nil && a.ta.SaveStateNow() {
		vi.ConsoleLine(markerStPosted)
	}
}

// applyPersistedAlarm runs once inside the event loop, after the first
// event drain: the seat's pane rect can only be Dispatched once the loop
// runs, so the kind-21 request (a blocking mailbox round-trip) waits for
// that first drain rather than sitting in Init ahead of it. The blob is
// consume-on-use, so asking later loses nothing. Marker order is evidence
// order: the channel verdict prints before the arm, the arm before any
// late fire.
func (a *app) applyPersistedAlarm() {
	var at int64
	var hhmmi int
	found := false
	if ver, blob, ok := vi.RequestStateRestore(uint32(a.ta.Win), appName); ok {
		if bat, bhhmm, bok := decodeAlarm(blob); bok && ver == 1 {
			vi.ConsoleLine(markerStRest)
			at, hhmmi, found = bat, bhhmm, true
		} else {
			vi.ConsoleLine(markerStRefuse)
		}
	}
	// The file is fresher-or-equal to any snapshot capture: it is rewritten
	// on every mutation, so when both decode the file's record stands.
	if raw, r := alarmFileRead(alarmPath, 128); r >= 0 {
		if fat, fhhmm, fok := decodeAlarm(raw); fok {
			at, hhmmi, found = fat, fhhmm, true
		} else {
			vi.ConsoleLine(markerAFileBad)
		}
	}
	if !found {
		return
	}
	h, m, _ := parseHHMM(hhmmi)
	vi.ConsoleLine(markerARestore + two(int64(h)) + ":" + two(int64(m)))
	if !a.sched.Add(Deadline{ID: "alarm", At: at, Repeat: 86400}) {
		vi.ConsoleLine(markerDFull)
		return
	}
	a.alarmHHMM = hhmmi
	// A deadline that came due while the app was off fires once now, marked
	// late — the repeat re-arm lands on the next future occurrence, exactly
	// the catch-up sched.Fire already performs.
	for _, d := range a.sched.Fire(a.now()) {
		if d.Quiet {
			continue
		}
		vi.ConsoleLine(markerFired + d.ID + " late")
		if !a.ta.Notify(d.ID + " done") {
			vi.ConsoleLine(markerNotifyNo + d.ID)
		}
	}
	a.dirty = true
}

// remaining is the armed deadline's seconds-to-go, -1 when unarmed.
func (a *app) remaining(id string) int64 {
	for _, d := range a.sched.ds {
		if d.ID == id {
			return d.At - a.now()
		}
	}
	return -1
}

// --- settings bus ------------------------------------------------------------

func (a *app) pollSettings() bool {
	key, value, ok := settings.PollChange(uint32(a.ta.Win))
	if !ok {
		return false
	}
	if key == "timezone" {
		z, ok := clockfmt.Parse(value)
		if !ok {
			return false
		}
		a.local = z
		a.zones = worldZones(z)
		vi.ConsoleLine(markerZones + "local=" + value + " n=" + vi.Itoa64(int64(len(a.zones))))
		return true
	}
	if key == "theme" {
		return theme.Set(value)
	}
	return false
}

// --- paint -------------------------------------------------------------------

// flushPainted prints the post-present marker: the frame carrying epoch
// a.paintedEpoch's face is flushed when the line lands.
func (a *app) flushPainted() {
	if a.tab == tabWorld && a.paintedEpoch > 0 {
		vi.ConsoleLine(markerPainted + vi.Itoa64(a.paintedEpoch))
	}
}

func (a *app) paint() {
	cv := a.ta.Canvas()
	if cv == nil {
		return
	}
	th := theme.Current
	cv.FillRect(widgets.Rect{W: int(a.ta.W), H: int(a.ta.H)}, draw.Opaque(th.Bg))
	a.paintStrip(cv)
	switch a.tab {
	case tabWorld:
		a.paintWorld(cv)
	case tabStopwatch:
		a.paintStopwatch(cv)
	case tabTimer:
		a.paintTimer(cv)
	case tabAlarm:
		a.paintAlarm(cv)
	}
}

func (a *app) paintStrip(cv widgets.Canvas) {
	th := theme.Current
	cv.FillRect(stripR, draw.Opaque(th.Border))
	for i := 0; i < tabCount; i++ {
		cr := stripCell(i)
		face := th.Surface
		if i == a.tab {
			face = th.Selection
		}
		cv.FillRect(cr.Inset(1), draw.Opaque(face))
		widgets.DrawText(cv, cr.Inset(4), tabNames[i], draw.Opaque(th.Text))
	}
}

func (a *app) paintWorld(cv widgets.Canvas) {
	th := theme.Current
	now := a.now()
	if now < 0 {
		drawText(cv, displayR, "no wall clock", th.InkMuted, th.Surface)
		return
	}
	a.paintedEpoch = now
	for i, z := range a.zones {
		fg := th.Ink
		if i == 0 {
			fg = th.Accent
		}
		drawText(cv, worldRowR(i), worldRow(now, z), fg, th.Surface)
	}
}

func (a *app) paintStopwatch(cv widgets.Canvas) {
	th := theme.Current
	drawText(cv, displayR, FormatElapsed(a.sw.Elapsed(a.nano())), th.Ink, th.Surface)
	hint := "space start/pause - r reset"
	if a.sw.Running() {
		hint = "running - space stops - r resets"
	}
	drawText(cv, hintR, hint, th.InkMuted, th.Surface)
	a.buttons[0] = widgets.Button{R: btnR0, Label: "Start"}
	if a.sw.Running() {
		a.buttons[0].Label = "Pause"
	}
	a.buttons[1] = widgets.Button{R: btnR1, Label: "Reset"}
	a.buttons[0].Draw(cv)
	a.buttons[1].Draw(cv)
}

func (a *app) paintTimer(cv widgets.Canvas) {
	th := theme.Current
	e := a.entryFor(tabTimer)
	disp := "timer"
	if r := a.remaining("timer"); r >= 0 {
		disp = itoa(r) + "s left"
	} else if !e.Empty() {
		disp = e.String() + "s"
	}
	drawText(cv, displayR, disp, th.Ink, th.Surface)
	drawText(cv, entryR, "seconds: "+e.String(), th.Ink, th.Surface)
	drawText(cv, hintR, "digits seconds - return arms - x cancels", th.InkMuted, th.Surface)
	a.buttons[0] = widgets.Button{R: btnR0, Label: "Arm"}
	a.buttons[1] = widgets.Button{R: btnR1, Label: "Cancel"}
	a.buttons[0].Draw(cv)
	a.buttons[1].Draw(cv)
}

func (a *app) paintAlarm(cv widgets.Canvas) {
	th := theme.Current
	e := a.entryFor(tabAlarm)
	disp := "alarm"
	if r := a.remaining("alarm"); r >= 0 {
		disp = "in " + FormatElapsed(r*1_000_000_000)
	} else if s := e.String(); len(s) > 2 {
		disp = s[:len(s)-2] + ":" + s[len(s)-2:]
	} else {
		disp = s
	}
	drawText(cv, displayR, disp, th.Ink, th.Surface)
	drawText(cv, entryR, "HHMM: "+e.String(), th.Ink, th.Surface)
	drawText(cv, hintR, "4 digits HHMM - return arms daily - x cancels", th.InkMuted, th.Surface)
	a.buttons[0] = widgets.Button{R: btnR0, Label: "Arm"}
	a.buttons[1] = widgets.Button{R: btnR1, Label: "Cancel"}
	a.buttons[0].Draw(cv)
	a.buttons[1].Draw(cv)
}

func (a *app) shutdown(status int) {
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	a.ta.CloseAndExit(status)
}
