// alarms.go — the Alarm tab's row list (M152b #2916) and the persisted
// alarm store (M144b #2795): add/edit/delete/toggle, the scheduler re-sync,
// and the two carriers (the GOCLOCK.ALARM share file and the seat's
// save_state blob) that make the list survive the app. Input dispatch,
// painting and the .ics verbs live in main.go, paint.go and import.go.
package main

import "virelai/vi"

// --- alarm list (M152b, #2916) ------------------------------------------------
//
// The Alarm tab is a bounded row list: four digits + Return adds a daily
// alarm, 'o' adds a once, Up/Down (or a row click) picks a row, Space/'t'
// toggles it between armed and off, 'x' deletes it. 'e' edits the picked
// row in place (M193b): the entry preloads its HHMM, a re-typed field
// commits on Return and abandons on Escape — mode, enabled flag and
// summary are the row's own; only the civil field (and its re-anchored
// instant) changes. Deadline ids are the row index ("alarm3"); every
// mutation re-syncs the scheduler from the list so index shifts can
// never strand a deadline under the wrong id.

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

// editAlarm arms edit-in-place on the picked row: the entry preloads
// the row's typed HHMM so the edit is a tweak — backspace the minutes,
// retype — rather than a fresh entry. commitAlarmEdit lands it.
func (a *app) editAlarm() bool {
	if a.alarmSel < 0 || a.alarmSel >= len(a.alarms) {
		return false
	}
	a.alarmEdit = true
	e := a.entryFor(tabAlarm)
	e.Clear()
	h, m, _ := parseHHMM(a.alarms[a.alarmSel].HHMM)
	for i := 0; i < 4; i++ {
		e.Digit(int(hhmmString(h, m)[i] - '0'))
	}
	return true
}

// commitAlarmEdit writes the re-typed HHMM back onto the picked row and
// re-anchors its instant — the in-place half of the card's "events you
// can edit". A field that is not a valid HHMM refuses, named like the
// add path's refusal.
func (a *app) commitAlarmEdit() bool {
	e := a.entryFor(tabAlarm)
	h, m, ok := parseHHMM(e.Value())
	if a.alarmSel < 0 || a.alarmSel >= len(a.alarms) ||
		e.Empty() || !ok || a.now() < 0 {
		a.alarmEdit = false
		e.Clear()
		vi.ConsoleLine(markerARefuse)
		return false
	}
	al := &a.alarms[a.alarmSel]
	al.HHMM = e.Value()
	al.At = alarmAt(a.now(), a.local, h, m)
	a.alarmEdit = false
	e.Clear()
	vi.ConsoleLine(markerAEdit + two(int64(h)) + ":" + two(int64(m)) + " " + alarmMode(al.Daily))
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

const (
	// alarmPath is the persisted list's share file. The save_state blob
	// carries the same bytes; the file is the always-current half — it is
	// rewritten on every list mutation while the blob is a snapshot
	// capture.
	alarmPath = "/host/GOCLOCK.ALARM"

	// alarmFileCap bounds the read of the persisted record: seven rows
	// with their gocal3 summary tokens stay well under a KiB.
	alarmFileCap = 1024
)

// The persisted-record seams — vi.WriteFileSafe/ReadFileAll/FileDelete cross
// the raw syscall gateway on the guest and degrade off it, so the vars are
// the host-test surface (the appstate.go / session.go pattern).
var (
	alarmFileWrite = vi.WriteFileSafe
	alarmFileRead  = vi.ReadFileAll
	alarmFileDel   = vi.FileDelete
)

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
	if raw, r := alarmFileRead(alarmPath, alarmFileCap); r >= 0 {
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
