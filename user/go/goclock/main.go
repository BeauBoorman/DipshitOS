// Command goclock is GOCLOCK.ELF — M144a (#2794): the Clock app, four tabs
// (World, Stopwatch, Timer, Alarm) full-viewport inside the Go tabbed
// desktop via user/go/tabapp. M152b (#2916): the Alarm tab is a list of
// up to seven alarms (each once or daily, each toggled on/off) and the
// Timer tab carries a preset row — one digit key arms 1/3/5/10/25
// minutes immediately.
//
// Time source split: the faces and every deadline compare in wall-clock
// seconds (vi.Now's epoch, formatted by clockfmt) while the stopwatch
// counts vsys.Nanotime's monotonic EL0 counter — a wall step moves the
// calendar, never a measurement.
//
// ONE scheduler (sched.go) multiplexes every deadline — the world face's
// 1 Hz repaint, the countdown, the alarm rows — onto the process's
// single kernel app timer (sys_timer_set / EvTimer kind 9, re-armed after
// each fire: the kernel timer is one-shot). A fired user deadline raises
// a seat toast through vi.Notify and prints `goclock: fired <id>`; a
// daily alarm re-arms 86400 s out, a once alarm switches its row off.
//
// Input: Left/Right/Tab or a strip click switches tabs; Space/'s' and 'r'
// drive the stopwatch; on the Timer tab digits 1–5 arm presets, 'e'
// opens the custom-seconds entry and 'x' cancels; on the Alarm tab four
// digits + Return add a daily alarm ('o' a once), Up/Down pick a row,
// Space toggles it and 'x' deletes it.
//
// Every marker is printed only AFTER the call it reports returned, so the
// go-clock VZ gate's asserts cannot pass on an app that did not do the
// work. `goclock: painted epoch=<n>` is the post-present marker — the
// world-face snapshot anchor — printed once per painted frame, and only
// while the World tab is showing.
package main

import (
	"strings"

	"virelai/clockfmt"
	"virelai/draw"
	"virelai/ical"
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
	markerADel     = "goclock: alarm deleted "
	markerAToggle  = "goclock: alarm toggled "
	markerAFull    = "goclock: alarm full"
	markerARefuse  = "goclock: alarm refused"
	markerARestore = "goclock: alarm restored "
	markerASaved   = "goclock: alarm saved"
	markerASaveBad = "goclock: alarm save failed rc="
	markerAFileBad = "goclock: alarm file bad"
	markerImport   = "goclock: import "
	markerImpDrop  = "goclock: drop ics len="
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
	keyDown   = 0x51
	keyUp     = 0x52

	// faceDeadline is the 1 Hz repaint entry — a Quiet deadline, so the
	// second hand's cadence never raises a toast or a `fired` marker.
	faceDeadline = "face"

	// alarmPath is the persisted list's share file. The save_state blob
	// carries the same bytes; the file is the always-current half — it is
	// rewritten on every list mutation while the blob is a snapshot
	// capture.
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

// presetR returns the i-th preset button on the Timer tab — five cells
// share the typed-field row's band while the picker (not the editor) is
// showing.
func presetR(i int) widgets.Rect {
	return widgets.Rect{X: 16 + i*122, Y: 104, W: 116, H: 24}
}

// alarmRowR returns the i-th Alarm list row's plate: seven rows fit the
// band under the buttons.
func alarmRowR(i int) widgets.Rect {
	return widgets.Rect{X: 16, Y: 200 + i*18, W: 608, H: 16}
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

	// alarms is the Alarm tab's row list (≤ MaxAlarms); alarmSel is the
	// picked row (-1 while the list is empty). timerEdit selects the
	// Timer tab's input surface: false is the preset row, true the
	// custom-seconds entry.
	alarms    []Alarm
	alarmSel  int
	timerEdit bool

	buttons       [2]widgets.Button
	presetButtons [5]widgets.Button
	paintedEpoch  int64
	ktArmed       bool
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
	// M187d (#3185): the import verb is headless — `exec GOCLOCK.ELF
	// import <path>` or the opens=text/calendar exec line
	// `exec GOCLOCK.ELF <path>.ics` merges the file into the alarm
	// store and exits before any window exists (the GOFILES `vol`
	// precedent: a serial face, not a tab).
	if path, ok := importArg(); ok {
		runImport(path)
	}
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
		// M187d (#3185): the drop half of opens=text/calendar — the
		// seat's opens= admission already filtered the mime; a
		// delivered .ics payload merges into the live alarm list the
		// same way the verb's file read does.
		DropTarget: func(offer tabapp.DragOffer) {
			a.dropICS(offer)
		},
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
		// M187d: a delivered .ics drop runs DropTarget — one poll per
		// loop turn, the same discipline as the save ask.
		ta.PollDrag()
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
// for the user-facing ones), then repaint and re-arm. A fired once-alarm
// switches its row off and the mutation is persisted like any other.
func (a *app) onTimer() {
	now := a.now()
	firedOff := false
	for _, d := range a.sched.Fire(now) {
		if d.Quiet {
			continue
		}
		vi.ConsoleLine(markerFired + d.ID)
		firedOff = a.markFiredAlarm(d.ID) || firedOff
		if !a.ta.Notify(d.ID + " done") {
			vi.ConsoleLine(markerNotifyNo + d.ID)
		}
	}
	if firedOff {
		a.persistAlarms()
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
	case keyUp:
		if a.tab == tabAlarm && a.alarmSel > 0 {
			a.alarmSel--
			return true
		}
		return false
	case keyDown:
		if a.tab == tabAlarm && a.alarmSel < len(a.alarms)-1 {
			a.alarmSel++
			return true
		}
		return false
	case keyEscape:
		if a.tab == tabTimer && a.timerEdit {
			a.timerEdit = false
			return true
		}
		return false
	case keyBacksp:
		if a.tab == tabAlarm || (a.tab == tabTimer && a.timerEdit) {
			return a.entryFor(a.tab).Backspace()
		}
		return false
	case keyEnter:
		switch a.tab {
		case tabTimer:
			return a.armCountdown()
		case tabAlarm:
			return a.addAlarm(true)
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
	case tabTimer:
		if a.timerEdit {
			if ch >= '0' && ch <= '9' {
				return a.entryFor(tabTimer).Digit(int(ch - '0'))
			}
		} else {
			if ch >= '1' && ch <= '5' {
				return a.armPreset(int(ch - '1'))
			}
			// A digit outside the preset row opens the editor with it —
			// typing "90" never needed a mode key first.
			if ch == '0' || (ch >= '6' && ch <= '9') {
				a.timerEdit = true
				a.entryFor(tabTimer).Digit(int(ch - '0'))
				return true
			}
			if ch == 'e' || ch == 'E' {
				a.timerEdit = true
				return true
			}
		}
		switch ch {
		case 'x', 'X':
			return a.cancelTab()
		}
	case tabAlarm:
		if ch >= '0' && ch <= '9' {
			return a.entryFor(tabAlarm).Digit(int(ch - '0'))
		}
		switch ch {
		case 'o', 'O':
			return a.addAlarm(false)
		case 'x', 'X':
			return a.deleteAlarm()
		case ' ', 't', 'T':
			return a.toggleAlarm()
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
		if !a.timerEdit {
			for i := 0; i < len(timerPresets); i++ {
				if a.presetButtons[i].HitTest(x, y) {
					return a.armPreset(i)
				}
			}
		}
		if a.buttons[0].HitTest(x, y) {
			return a.armCountdown()
		}
		if a.buttons[1].HitTest(x, y) {
			return a.cancelTab()
		}
	case tabAlarm:
		for i := range a.alarms {
			if alarmRowR(i).Contains(x, y) {
				a.alarmSel = i
				return true
			}
		}
		if a.buttons[0].HitTest(x, y) {
			return a.addAlarm(true)
		}
		if a.buttons[1].HitTest(x, y) {
			return a.addAlarm(false)
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
	return a.armTimerSecs(int64(e.Value()))
}

// armPreset arms the countdown from the preset row — one key, no entry.
func (a *app) armPreset(i int) bool {
	if i < 0 || i >= len(timerPresets) || a.now() < 0 {
		vi.ConsoleLine(markerTRefuse)
		return false
	}
	return a.armTimerSecs(timerPresets[i])
}

func (a *app) armTimerSecs(secs int64) bool {
	if !a.sched.Add(Deadline{ID: "timer", At: a.now() + secs}) {
		vi.ConsoleLine(markerDFull)
		return false
	}
	vi.ConsoleLine(markerTArm + vi.Itoa64(secs))
	a.armTimer()
	return true
}

// --- alarm list (M152b, #2916) ------------------------------------------------
//
// The Alarm tab is a bounded row list: four digits + Return adds a daily
// alarm, 'o' adds a once, Up/Down (or a row click) picks a row, Space/'t'
// toggles it between armed and off, 'x' deletes it. Deadline ids are the
// row index ("alarm3"); every mutation re-syncs the scheduler from the
// list so index shifts can never strand a deadline under the wrong id.

// alarmMode renders the record's repeat field for the markers.
func alarmMode(daily bool) string {
	if daily {
		return "daily"
	}
	return "once"
}

// alarmID is the deadline id of row i.
func alarmID(i int) string { return "alarm" + itoa(int64(i)) }

// addAlarm appends the typed HHMM as a new armed row.
func (a *app) addAlarm(daily bool) bool {
	e := a.entryFor(tabAlarm)
	h, m, ok := parseHHMM(e.Value())
	now := a.now()
	if e.Empty() || !ok || now < 0 {
		vi.ConsoleLine(markerARefuse)
		return false
	}
	if len(a.alarms) >= MaxAlarms {
		vi.ConsoleLine(markerAFull)
		return false
	}
	a.alarms = append(a.alarms, Alarm{
		At:      alarmAt(now, a.local, h, m),
		HHMM:    e.Value(),
		Daily:   daily,
		Enabled: true,
	})
	a.alarmSel = len(a.alarms) - 1
	e.Clear()
	vi.ConsoleLine(markerAArm + two(int64(h)) + ":" + two(int64(m)) + " " + alarmMode(daily))
	a.syncAlarms()
	a.persistAlarms()
	a.armTimer()
	return true
}

// deleteAlarm removes the picked row, deadline included.
func (a *app) deleteAlarm() bool {
	if a.alarmSel < 0 || a.alarmSel >= len(a.alarms) {
		return false
	}
	h, m, _ := parseHHMM(a.alarms[a.alarmSel].HHMM)
	a.alarms = append(a.alarms[:a.alarmSel], a.alarms[a.alarmSel+1:]...)
	if a.alarmSel >= len(a.alarms) {
		a.alarmSel = len(a.alarms) - 1
	}
	vi.ConsoleLine(markerADel + two(int64(h)) + ":" + two(int64(m)))
	a.syncAlarms()
	a.persistAlarms()
	a.armTimer()
	return true
}

// toggleAlarm switches the picked row between armed and off. A row
// re-enabled after its instant passed is re-anchored to the next
// occurrence — the toggle is a fresh arm, not a catch-up (restore's
// late-fire path is the only one that lets a stored `at` stand).
func (a *app) toggleAlarm() bool {
	if a.alarmSel < 0 || a.alarmSel >= len(a.alarms) {
		return false
	}
	al := &a.alarms[a.alarmSel]
	h, m, _ := parseHHMM(al.HHMM)
	al.Enabled = !al.Enabled
	state := "off"
	if al.Enabled {
		state = "on"
		al.At = alarmAt(a.now(), a.local, h, m)
	}
	vi.ConsoleLine(markerAToggle + two(int64(h)) + ":" + two(int64(m)) + " " + state)
	a.syncAlarms()
	a.persistAlarms()
	a.armTimer()
	return true
}

// syncAlarms rebuilds the alarm deadlines from the list: every alarm id
// is cancelled first, then each enabled row is re-added under its index
// id (daily rows with the 86400 re-arm floor).
func (a *app) syncAlarms() {
	for i := 0; i < MaxAlarms; i++ {
		a.sched.Cancel(alarmID(i))
	}
	for i, al := range a.alarms {
		if !al.Enabled {
			continue
		}
		var rep int64
		if al.Daily {
			rep = dailyRepeat
		}
		if !a.sched.Add(Deadline{ID: alarmID(i), At: al.At, Repeat: rep}) {
			vi.ConsoleLine(markerDFull)
		}
	}
}

// markFiredAlarm flips a fired once-alarm's row off — the deadline is
// already gone (one-shots never re-arm) so only the record and the
// persisted list change. Returns true when a row was switched off.
func (a *app) markFiredAlarm(id string) bool {
	i, ok := alarmIndex(id)
	if !ok || i >= len(a.alarms) || a.alarms[i].Daily || !a.alarms[i].Enabled {
		return false
	}
	a.alarms[i].Enabled = false
	return true
}

func (a *app) cancelTab() bool {
	if a.tab != tabTimer || !a.sched.Cancel("timer") {
		return false
	}
	vi.ConsoleLine(markerTCancel)
	a.armTimer()
	return true
}

// --- alarm persistence (M144b #2795, list format M152b #2916) ------------------
//
// The alarm list survives the app through two carriers that share one
// record (`gocal2`, model.go — `gocal1` still reads):
//
//   - the share file at alarmPath, rewritten crash-safe on every list
//     mutation and deleted when the last row goes — it is the
//     always-current half and survives any reboot the share survives;
//   - the seat's save_state/restore_state blob (SESSION.TABS trailer),
//     pushed on every mutation and answered on the snapshot/close asks —
//     it is a capture of whatever was stored when the seat asked.
//
// At start the file wins when both decode: it tracks mutations the snapshot
// predates. An enabled record whose `at` is already past fires once
// immediately, marked late — that is what "the alarm came due while the
// machine was suspended or rebooted" looks like from the app's side. The
// daily repeater re-arms at the next future occurrence, so the late fire
// never costs the user tomorrow's alarm; a late once-alarm fires once and
// lands back on the list switched off.

// saveBlob is the tabapp.SaveState hook: the current list, or nil when it
// is empty (an empty answer is "no state", never a fabricated one).
func (a *app) saveBlob() []byte {
	if len(a.alarms) == 0 {
		return nil
	}
	return encodeAlarms(a.alarms)
}

// persistAlarms publishes the list through both carriers — the file
// first (the durable half), then the unsolicited state push so the
// seat's stored blob is already current if a crash lands before the
// next ask. An empty list erases both sides.
func (a *app) persistAlarms() {
	if len(a.alarms) == 0 {
		if rc := alarmFileDel(alarmPath); rc != 0 && rc != vi.ErrFileNotFound {
			vi.ConsoleLine(markerASaveBad + vi.Itoa64(rc))
		}
	} else if b := encodeAlarms(a.alarms); b != nil {
		if rc := alarmFileWrite(alarmPath, b); rc != 0 {
			vi.ConsoleLine(markerASaveBad + vi.Itoa64(rc))
		} else {
			vi.ConsoleLine(markerASaved)
		}
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
	var list []Alarm
	found := false
	if ver, blob, ok := vi.RequestStateRestore(uint32(a.ta.Win), appName); ok {
		if bl, bok := decodeAlarms(blob); bok && ver == 1 {
			vi.ConsoleLine(markerStRest)
			list, found = bl, true
		} else {
			vi.ConsoleLine(markerStRefuse)
		}
	}
	// The file is fresher-or-equal to any snapshot capture: it is rewritten
	// on every mutation, so when both decode the file's list stands.
	if raw, r := alarmFileRead(alarmPath, 256); r >= 0 {
		if fl, fok := decodeAlarms(raw); fok {
			list, found = fl, true
		} else {
			vi.ConsoleLine(markerAFileBad)
		}
	}
	if !found {
		return
	}
	a.alarms = list
	a.alarmSel = len(list) - 1
	for _, al := range a.alarms {
		h, m, _ := parseHHMM(al.HHMM)
		state := ""
		if !al.Enabled {
			state = " off"
		}
		vi.ConsoleLine(markerARestore + two(int64(h)) + ":" + two(int64(m)) + " " + alarmMode(al.Daily) + state)
	}
	a.syncAlarms()
	a.armTimer()
	// A deadline that came due while the app was off fires once now, marked
	// late — the daily repeater's re-arm lands on the next future
	// occurrence, exactly the catch-up sched.Fire already performs; a once
	// alarm that fires here lands back on the list switched off.
	firedOff := false
	for _, d := range a.sched.Fire(a.now()) {
		if d.Quiet {
			continue
		}
		vi.ConsoleLine(markerFired + d.ID + " late")
		firedOff = a.markFiredAlarm(d.ID) || firedOff
		if !a.ta.Notify(d.ID + " done") {
			vi.ConsoleLine(markerNotifyNo + d.ID)
		}
	}
	if firedOff {
		a.persistAlarms()
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
	} else if a.timerEdit && !e.Empty() {
		disp = e.String() + "s"
	}
	drawText(cv, displayR, disp, th.Ink, th.Surface)
	hint := "1-5 preset min - e custom seconds - x cancels"
	if a.timerEdit {
		drawText(cv, entryR, "seconds: "+e.String(), th.Ink, th.Surface)
		hint = "digits seconds - return arms - esc presets"
	} else {
		for i := 0; i < len(timerPresets); i++ {
			a.presetButtons[i] = widgets.Button{R: presetR(i), Label: timerPresetLabels[i]}
			a.presetButtons[i].Draw(cv)
		}
	}
	drawText(cv, hintR, hint, th.InkMuted, th.Surface)
	a.buttons[0] = widgets.Button{R: btnR0, Label: "Arm"}
	a.buttons[1] = widgets.Button{R: btnR1, Label: "Cancel"}
	a.buttons[0].Draw(cv)
	a.buttons[1].Draw(cv)
}

// nextAlarmRemaining is the seconds-to-go of the earliest enabled row;
// ok is false when nothing is armed (a past-due row counts as armed —
// it is about to fire).
func (a *app) nextAlarmRemaining() (int64, bool) {
	best := int64(0)
	found := false
	for _, al := range a.alarms {
		if al.Enabled && (!found || al.At < best) {
			best, found = al.At, true
		}
	}
	return best - a.now(), found
}

func (a *app) paintAlarm(cv widgets.Canvas) {
	th := theme.Current
	e := a.entryFor(tabAlarm)
	disp := "alarms"
	if r, ok := a.nextAlarmRemaining(); ok {
		disp = "next in " + FormatElapsed(r*1_000_000_000)
	} else if s := e.String(); len(s) > 2 {
		disp = s[:len(s)-2] + ":" + s[len(s)-2:]
	} else {
		disp = s
	}
	drawText(cv, displayR, disp, th.Ink, th.Surface)
	drawText(cv, entryR, "HHMM: "+e.String(), th.Ink, th.Surface)
	drawText(cv, hintR, "4 digits - return daily - o once - up/dn pick - spc toggles - x del", th.InkMuted, th.Surface)
	a.buttons[0] = widgets.Button{R: btnR0, Label: "Daily"}
	a.buttons[1] = widgets.Button{R: btnR1, Label: "Once"}
	a.buttons[0].Draw(cv)
	a.buttons[1].Draw(cv)
	for i, al := range a.alarms {
		h, m, _ := parseHHMM(al.HHMM)
		state := "on"
		fg := th.Ink
		if !al.Enabled {
			state = "off"
			fg = th.InkMuted
		}
		label := two(int64(h)) + ":" + two(int64(m)) + "  " + alarmMode(al.Daily) + "  " + state
		bg := th.Surface
		if i == a.alarmSel {
			bg = th.Selection
			if al.Enabled {
				fg = th.Text
			}
		}
		drawText(cv, alarmRowR(i), label, fg, bg)
	}
}

func (a *app) shutdown(status int) {
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	a.ta.CloseAndExit(status)
}

// --- .ics import (M187d #3185) ---------------------------------------------
//
// Two doors, one core. The headless verb (`exec GOCLOCK.ELF import
// <path>`, or the opens=text/calendar exec line `exec GOCLOCK.ELF
// <path>.ics`) merges a file into the persisted gocal2 list and exits
// before a window exists; a drop delivered through the seat's opens=
// admission merges the payload into the LIVE list and republishes it
// like any other mutation. importInto is the shared pure half: bytes in,
// the merged list and the marker lines out — the lines are RETURNED so
// host tests pin every verdict without a console.
//
// The verb edits the file behind any running instance's back — the
// share file is last-writer-wins and a running app's next mutation
// republishes its in-memory list, so the honest wording is "merge into
// the store while the store is idle" (the same caveat any foreign
// writer of GOCLOCK.ALARM carries).

// icsFileRead is the verb's file seam (the alarmFileRead pattern).
var icsFileRead = vi.ReadFileAll

// importArg decodes the launch line: `import <path>` is the explicit
// verb; a bare argv path ending .ics is the opens= route's exec line.
// ("", true) is the bare `import` — the verb names that refusal itself.
func importArg() (string, bool) {
	args := vi.Args()
	for i := 1; i < len(args); i++ {
		a := args[i]
		if a == "import" {
			if i+1 < len(args) {
				return args[i+1], true
			}
			return "", true
		}
		if strings.HasSuffix(strings.ToLower(a), ".ics") {
			return a, true
		}
	}
	return "", false
}

// runImport is the verb's whole life: read, merge, republish the file,
// exit. It never opens a window — the markers ARE the face.
func runImport(path string) {
	if path == "" {
		vi.ConsoleLine(markerImport + "refused path")
		vi.Exit(2)
	}
	b, rc := icsFileRead(path, vi.MaxFileBytes)
	if rc < 0 {
		vi.ConsoleLine(markerImport + "refused read rc=" + vi.Itoa64(rc))
		vi.Exit(2)
	}
	list := importLoad()
	out := importInto(list, b, vi.Now(), settings.Load().Timezone())
	if !out.ok {
		vi.ConsoleLine(markerImport + "refused not-vcalendar")
		vi.Exit(2)
	}
	for _, ln := range out.lines {
		vi.ConsoleLine("goclock: " + ln)
	}
	if out.added > 0 {
		if enc := encodeAlarms(out.list); enc == nil {
			vi.ConsoleLine(markerASaveBad + "-1")
			vi.Exit(3)
		} else if wrc := alarmFileWrite(alarmPath, enc); wrc != 0 {
			vi.ConsoleLine(markerASaveBad + vi.Itoa64(wrc))
			vi.Exit(3)
		} else {
			vi.ConsoleLine(markerASaved)
		}
	}
	vi.ConsoleLine(importDoneLine(out.added, out.refused))
	vi.Exit(0)
}

// importLoad reads the persisted half of the store the verb merges
// into. A missing file is an empty list; a foreign one is named bad and
// still an empty list — the decode refused it, not the verb.
func importLoad() []Alarm {
	var list []Alarm
	if raw, r := alarmFileRead(alarmPath, 256); r >= 0 {
		if l, ok := decodeAlarms(raw); ok {
			list = l
		} else {
			vi.ConsoleLine(markerAFileBad)
		}
	}
	return list
}

// importOut is importInto's report: the merged list, the counts the
// done line carries, and the marker bodies (the "goclock: " prefix is
// the caller's).
type importOut struct {
	list    []Alarm
	added   int
	refused int
	lines   []string
	ok      bool
}

// importInto merges b's honoured VEVENTs into list. The verdicts are
// marker bodies, in event order: a landed row prints its civil time,
// mode and summary; a refused event names the parser's why (all-day,
// dtstart-tzid, rrule, dtstart) or the store's (dup, full); an overflow
// tail counts as one truncated line. ok=false is the file-level
// refusal — nothing in the bytes was a VEVENT.
func importInto(list []Alarm, b []byte, now int64, local clockfmt.Zone) importOut {
	res, ok := ical.Parse(b)
	out := importOut{list: list, ok: ok}
	if !ok {
		return out
	}
	seen := make(map[int64]bool, len(list))
	for _, al := range list {
		seen[al.At] = true
	}
	for _, ev := range res.Events {
		at := importAt(ev.Start, now, local)
		switch {
		case seen[at]:
			out.refused++
			out.lines = append(out.lines, "import refused dup")
		case len(out.list) >= MaxAlarms:
			out.refused++
			out.lines = append(out.lines, "import refused full")
		default:
			c := clockfmt.At(at, local)
			out.list = append(out.list, Alarm{
				At:      at,
				HHMM:    c.Hour*100 + c.Minute,
				Daily:   ev.Daily,
				Enabled: true,
			})
			seen[at] = true
			out.added++
			summary := ev.Summary
			if summary == "" {
				summary = "-"
			}
			out.lines = append(out.lines, "import "+
				two(int64(c.Hour))+":"+two(int64(c.Minute))+
				" "+alarmMode(ev.Daily)+" "+summary)
		}
	}
	for _, rf := range res.Refusals {
		out.refused++
		out.lines = append(out.lines, "import refused "+rf.Why)
	}
	if over := res.Total - len(res.Events) - len(res.Refusals); over > 0 {
		out.lines = append(out.lines, "import truncated n="+itoa(int64(over)))
	}
	return out
}

// importAt resolves a parsed stamp to a wall-clock epoch: a Z value's
// Wall IS the epoch; a floating value is the civil reading the user's
// zone resolves (the same solve an alarm arm runs).
func importAt(st ical.Stamp, now int64, local clockfmt.Zone) int64 {
	if st.UTC {
		return st.Wall
	}
	return localEpoch(st.Wall, now, local)
}

// importDoneLine is the verb/drop receipt: what landed and what was
// refused, in one line a gate can end on.
func importDoneLine(added, refused int) string {
	return markerImport + "done added=" + itoa(int64(added)) +
		" refused=" + itoa(int64(refused))
}

// dropICS is the DropTarget hook: the seat already filtered the mime to
// text/calendar, so the payload parses where it lands — each verdict
// prints the same lines the verb's file read would.
func (a *app) dropICS(offer tabapp.DragOffer) {
	if offer.Blob == nil {
		vi.ConsoleLine(markerImport + "refused no-payload")
		return
	}
	vi.ConsoleLine(markerImpDrop + vi.Itoa64(int64(len(offer.Blob))))
	out := importInto(a.alarms, offer.Blob, a.now(), a.local)
	if !out.ok {
		vi.ConsoleLine(markerImport + "refused not-vcalendar")
		return
	}
	for _, ln := range out.lines {
		vi.ConsoleLine("goclock: " + ln)
	}
	a.alarms = out.list
	if out.added > 0 {
		a.alarmSel = len(a.alarms) - 1
		a.syncAlarms()
		a.persistAlarms()
		a.armTimer()
		a.dirty = true
	}
	vi.ConsoleLine(importDoneLine(out.added, out.refused))
}
