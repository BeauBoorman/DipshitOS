// GOTABWM.ELF — M125f (#2591): the crash auto-snapshot and its offer.
//
// A released-window mirror that finds its tab STILL on the strip is the
// kernel's teardown (driving_award.close_owner) — the seat never asked for
// the close, so the owning process died on its own. The scheduler's pinned
// exit order runs on_task_exit (which marks the process exited and
// snapshots its status) BEFORE close_owner fans the mirror, so by the time
// the seat drains the event the procs table already carries the verdict:
// exited + status 0 is a quit, exited + nonzero is the crash receipt this
// card hooks. Ordinary closes can never reach the check — closeTabByID
// drops the row itself before the mirror it ordered arrives.
//
// The crash arm runs four bounded steps before the row leaves:
//
//  1. askAllStateSave("crash") + collectStateAsks() — every LIVE client
//     serializes again; the crashed app cannot answer, so its record
//     keeps whatever the last ask stored. The collect's round budget is
//     the same one the snapshot arm lives under.
//  2. writeSession() while the crashed row is still on the strip — the
//     file records its bin and last blob, so the next boot's ordinary
//     loadSession re-execs the app and restore_state hands it back the
//     pre-crash bytes: the file-level recovery.
//  3. crashSnapSave() — park the machine image in one of crashSnapSlots
//     rotated GOSNAP names (CRASH0..CRASH<n-1> under /host/SNAPSHOTS/)
//     via the ctl channel, and leave /host/CRASHSNAP.LAST naming the
//     parked slot: the next boot's offer.
//  4. crashRestart() — re-exec the crashed binary and stage the blob
//     CloseTab just pushed onto the reopen LIFO (the ctrl-shift-t
//     adoption path), so the app is back in THIS boot too. Bounded to
//     once per binary per boot: an app its own blob panics again
//     converges to a dead row instead of a restart loop.
//
// The next boot reads LAST once — crashSnapOffer posts an actionable toast
// (click or its center row = Restore: the ctl `restore` verb stages the
// slot as the next --resume's image; the center row's X = Dismiss). The
// offer is one-shot: resolution consumes LAST, and the file is only ever
// written after a save actually parked — the offer can never point at a
// vzsave that does not exist. A toast that simply expires does NOT resolve
// the offer: the center row and LAST survive, so the next boot re-posts.
package main

import (
	"virelai/snapshot"
	"virelai/vi"
)

const (
	// crashSnapSlots bounds the rotated auto-save names. A crash never
	// grows the SNAPSHOTS directory past this count — each save reuses
	// or replaces a slot.
	crashSnapSlots = 3
	// crashSnapPrefix + a digit is the slot name (CRASH0..CRASH2).
	crashSnapPrefix = "CRASH"
	crashSnapDir    = "/host/SNAPSHOTS"
	// crashSnapLastPath is the pending offer: one line naming the slot a
	// successful save parked. Consume-on-use, the SNAPSHOT.RESTORE idiom.
	crashSnapLastPath = "/host/CRASHSNAP.LAST"
	// crashSnapLastMax bounds the offer read; a bigger file is no offer.
	crashSnapLastMax = 64
	// crashSnapToast is the offer's bounded toast text (the 24-byte wire
	// bound the notify strip already enforces).
	crashSnapToast = "Crash snap: tap=restore"

	// Marker lines the class-B gate greps, printed only after the step
	// they report (the M57a discipline).
	MarkerCrash            = "gotabwm: crash "
	MarkerCrashSnapSave    = "gotabwm: crashsnap save "
	MarkerCrashSnapOffer   = "gotabwm: crashsnap offer "
	MarkerCrashSnapRestore = "gotabwm: crashsnap restore "
	MarkerCrashSnapDismiss = "gotabwm: crashsnap dismiss "
	// MarkerCrashSnapPersist is this file's MarkerSnapshotPersist: a
	// failed LAST publish leaves the offer unwritten — the save marker
	// stays honest, and no boot ever offers an unrecorded slot.
	MarkerCrashSnapPersist = "gotabwm: crashsnap last persist "
	MarkerCrashRestart     = "gotabwm: crash restart "
	// MarkerCrashRestartNone reports a crash receipt with nothing to
	// re-exec: the row's record carried no binary name.
	MarkerCrashRestartNone = "gotabwm: crash restart none"
	// MarkerCrashRestartFail names an exec refusal — the errno rides the
	// marker so a gate run says WHICH bound refused, never a silent skip.
	MarkerCrashRestartFail = "gotabwm: crash restart fail "
	// MarkerCrashRestartStop is the loop bound's report: a binary that
	// already got its one restart this boot crashes to a dead row, not a
	// loop.
	MarkerCrashRestartStop = "gotabwm: crash restart stop "
)

// crashLog is this file's marker sink — vi.ConsoleLine on the guest, a
// recorder in tests (the snapLog / stateLog pattern): every marker here
// is printed only after the step it reports, and the order discipline is
// the thing host tests pin.
var crashLog = vi.ConsoleLine

// procsExitStatus is the crash receipt's read seam: vi.Procs in the guest,
// a stub in tests (the procsAlive pattern). Fail-closed — an unreadable
// table is not a crash.
var procsExitStatus = func(pid uint8) (uint64, bool) {
	var rows [64]vi.ProcRow
	n, r := vi.Procs(rows[:])
	if r < 0 {
		return 0, false
	}
	for i := 0; i < n; i++ {
		if uint8(rows[i].PID) == pid {
			return rows[i].ExitStatus, rows[i].State == vi.ProcExited
		}
	}
	return 0, false
}

// seatCrashStatus decides whether a released tab is a crash receipt: its
// bound owner's process exited nonzero. An unbound window has no
// attributable owner and is never a crash (pid 0); a clean exit is a quit.
func seatCrashStatus(id uint32) (uint8, uint64, bool) {
	if id > 255 {
		return 0, 0, false
	}
	pid := rpcBindings[id].pid
	if pid == 0 {
		return 0, 0, false
	}
	status, exited := procsExitStatus(pid)
	return pid, status, exited && status != 0
}

// crashSave is the auto-snapshot half: fresh asks into the live strip, the
// session republished with the crashed row still recorded, then the
// rotated slot save. It runs while the row is live — the caller's CloseTab
// follows.
func crashSave() {
	askAllStateSave("crash")
	collectStateAsks()
	_ = writeSession()
	crashSnapSave()
}

// crashSnapSeq is the rotation cursor: boot 0's first crash parks CRASH0,
// the second CRASH1, and so on modulo the slot count.
var crashSnapSeq int

// crashSnapSave parks the machine image under the next rotated name. The
// ctl `snapshot` verb refuses an existing name (exists), so a stale slot
// file is deleted first — replace IS rm+save, the path GOSNAP's own rm
// then save would take. A refused save still prints its verdict; LAST is
// only written on ok.
func crashSnapSave() {
	name := crashSnapPrefix + string(rune('0'+rune(crashSnapSeq%crashSnapSlots)))
	crashSnapSeq++
	vz := crashSnapDir + "/" + name + ".vzsave"
	if snapExists(vz) {
		_ = snapDelete(vz)
	}
	var code [40]byte
	r := vsockCtlRequest("snapshot", name, code[:])
	crashLog(MarkerCrashSnapSave + name + " " + ctlVerdict(r, code[:]))
	if r != 0 {
		return
	}
	if w := stateFileWrite(crashSnapLastPath, []byte(name+"\n")); w != 0 {
		crashLog(MarkerCrashSnapPersist + vi.Itoa64(w))
	}
}

// ctlVerdict names one ctl call's outcome — ok, the refusal code the host
// answered, or the syscall errno. suspendVerdict's shape generalized for
// this file's two verbs.
func ctlVerdict(r int64, code []byte) string {
	switch {
	case r == 0:
		return "ok"
	case r > 0:
		if r > int64(len(code)) {
			r = int64(len(code))
		}
		return string(code[:r])
	default:
		return vi.ErrnoName(r)
	}
}

// crashRestarted is the per-boot restart loop bound: a binary appears once
// — its second crash leaves the row dead. MaxTabs entries bound the table
// the same way every other seat table is bounded.
var (
	crashRestarted  [MaxTabs]string
	crashRestartedN int
)

// crashRestartPending defers the re-exec to the next composite tick: the
// ctl `snapshot` save inside crashSave pauses the whole VM to serialize
// it, and the share channel's reads need a live tick behind them before
// exec streams an image — the same-boot restart is a tick later, not in
// the teardown handler's shadow.
var crashRestartPending bool

// crashRestartTick is compositeTick's drain of the deferred restart — one
// shot per crash event, cleared before the exec so a re-crash inside it
// re-arms honestly instead of being eaten by the flag.
func crashRestartTick() {
	if !crashRestartPending {
		return
	}
	crashRestartPending = false
	crashRestart()
}

// crashRestart re-execs the crashed tab: CloseTab already pushed its row
// (bin, title, blob) onto the reopen LIFO, so this is applyReopen's shape
// with a crash marker and the once-per-binary bound. A tab the seat never
// spawned has no recorded bin and honestly does not come back.
func crashRestart() {
	c, ok := tabs.ReopenLastClosed()
	if !ok {
		crashLog(MarkerCrashRestartNone)
		return
	}
	for i := 0; i < crashRestartedN; i++ {
		if crashRestarted[i] == c.Bin {
			crashLog(MarkerCrashRestartStop + c.Bin)
			return
		}
	}
	// The exec seam's share lookup can lose a transient against an
	// existing image; one retry, then the marker names the refusal.
	var pid int64
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		pid, err = execApp(c.Bin)
		if err == nil {
			break
		}
	}
	if err != nil {
		crashLog(MarkerCrashRestartFail + c.Bin + " " + err.Error())
		seatRefusalErr(err, "exec "+c.Bin, c.Bin)
		return
	}
	if crashRestartedN < len(crashRestarted) {
		crashRestarted[crashRestartedN] = c.Bin
		crashRestartedN++
	}
	stagePendingState(pid, c.StateVer, c.State)
	crashLog(MarkerCrashRestart + c.Bin)
}

// crashSnapOfferName reads the pending offer. Missing, empty, oversized,
// or invalid content is no offer — never a guess and never an offer a
// parked slot cannot honour.
func crashSnapOfferName() (string, bool) {
	// One retry on the read: the share channel can lose a transient on an
	// existing file, and an unread LAST is indistinguishable from no offer.
	var b []byte
	var r int64
	for attempt := 0; attempt < 2; attempt++ {
		b, r = stateFileRead(crashSnapLastPath, crashSnapLastMax)
		if r >= 0 {
			break
		}
	}
	if r < 0 || len(b) == 0 {
		return "", false
	}
	name := string(b)
	for i := 0; i < len(name); i++ {
		if name[i] == '\n' || name[i] == '\r' {
			name = name[:i]
			break
		}
	}
	if !snapshot.ValidName(name) {
		return "", false
	}
	return name, true
}

// crashSnapOffer posts the next boot's recovery toast. It runs once at
// startup — the offer survives this toast's own expiry (the center row and
// LAST carry it) so an unread fade never silently loses the choice.
func crashSnapOffer() {
	name, ok := crashSnapOfferName()
	if !ok {
		return
	}
	notifyPushAction(0, crashSnapToast, compositeClock, notifyActionCrashSnap, name)
	crashLog(MarkerCrashSnapOffer + name)
}

// crashSnapRestore is the offer's Restore arm: the ctl `restore` verb
// stages the named slot as the next --resume image (a stage, never a
// rewind — ADR 0056). The verdict prints before the offer is consumed; a
// refusal is reported, not hidden.
func crashSnapRestore(name string) {
	var code [40]byte
	r := vsockCtlRequest("restore", name, code[:])
	crashLog(MarkerCrashSnapRestore + name + " " + ctlVerdict(r, code[:]))
	crashSnapConsume(name)
}

// crashSnapDismiss is the offer's Dismiss arm: declined, consumed, done.
func crashSnapDismiss(name string) {
	crashLog(MarkerCrashSnapDismiss + name)
	crashSnapConsume(name)
}

// crashSnapConsume drops LAST only when it still names the answered slot:
// a LAST a NEWER crash rewrote after this toast posted is that crash's
// offer, not this one's, and stays for the next boot.
func crashSnapConsume(name string) {
	cur, ok := crashSnapOfferName()
	if ok && cur == name {
		for attempt := 0; attempt < 2; attempt++ {
			if stateFileDelete(crashSnapLastPath) == 0 {
				break
			}
		}
	}
}
