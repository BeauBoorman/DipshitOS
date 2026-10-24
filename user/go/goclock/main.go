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
// Space toggles it, 'e' edits its time in place (M193b) and 'x' deletes
// it. Headless verbs: `import <path>` merges an .ics into the store,
// `export <path>` writes it back as a VCALENDAR through WriteFileSafe.
//
// Every marker is printed only AFTER the call it reports returned, so the
// go-clock VZ gate's asserts cannot pass on an app that did not do the
// work. `goclock: painted epoch=<n>` is the post-present marker — the
// world-face snapshot anchor — printed once per painted frame, and only
// while the World tab is showing.
package main

import (
	"virelai/clockfmt"
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
	markerAEdit    = "goclock: alarm edited "
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
	markerExport   = "goclock: export "
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
	// custom-seconds entry. alarmEdit (M193b) latches edit-in-place on
	// the picked row — the entry is editing THAT row's HHMM, not
	// staging a new one.
	alarms    []Alarm
	alarmSel  int
	timerEdit bool
	alarmEdit bool

	buttons       [2]widgets.Button
	presetButtons [5]widgets.Button
	paintedEpoch  int64
	ktArmed       bool
}

func (a *app) entryFor(tab int) *DigitEntry { return &a.entry[tab-tabTimer] }

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
	// precedent: a serial face, not a tab). M193b (#3254): `export
	// <path>` is the same headless shape the other way — the persisted
	// list as a VCALENDAR through WriteFileSafe.
	if verb, path, ok := verbArg(); ok {
		switch verb {
		case "import":
			runImport(path)
		case "export":
			runExport(path)
		}
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
		if a.tab == tabAlarm && a.alarmEdit {
			a.alarmEdit = false
			a.entryFor(tabAlarm).Clear()
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
			if a.alarmEdit {
				return a.commitAlarmEdit()
			}
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
		// An edit in flight owns the letter keys: Return commits and
		// Escape abandons; the rest wait for one of those.
		if a.alarmEdit {
			return false
		}
		switch ch {
		case 'e', 'E':
			return a.editAlarm()
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
				a.alarmEdit = false
				return true
			}
		}
		if !a.alarmEdit && a.buttons[0].HitTest(x, y) {
			return a.addAlarm(true)
		}
		if !a.alarmEdit && a.buttons[1].HitTest(x, y) {
			return a.addAlarm(false)
		}
	}
	return false
}

func (a *app) setTab(t int) bool {
	if t == a.tab {
		return false
	}
	// Leaving the tab abandons an edit in flight — the row is untouched.
	a.alarmEdit = false
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

func (a *app) cancelTab() bool {
	if a.tab != tabTimer || !a.sched.Cancel("timer") {
		return false
	}
	vi.ConsoleLine(markerTCancel)
	a.armTimer()
	return true
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

func (a *app) shutdown(status int) {
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	a.ta.CloseAndExit(status)
}
