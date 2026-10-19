// GOTABWM.ELF — M123c (issue #2577): progress rows in the notification
// center.
//
// A kind-22 request reports one operation's progress; the center keeps it
// as a row keyed by (sender tab, op) that later reports update IN PLACE —
// there is still no second queue, and no toast: a progress row is a
// standing surface, so do-not-disturb does not gate it (DND holds
// transients; this is the opposite — the user asked for feedback while
// work runs).
//
// While the operation runs the row's trailing affordance is "Cancel",
// wider than the plain dismiss X to fit the word: the seat pushes a
// kind-23 frame (reply_to=0, the asynchronous-notice shape) to the
// reporting pid with title[0]=op, then drops the row — the user asked for
// it to go away either way, and a refused send still answers honestly in
// the marker's sent= flag. A done row (pct 100) or one whose source
// closed falls back to the plain 34px X: there is nothing left to cancel.
//
// Progress rows are transient by contract: encodeNotifyHistory skips
// them, and an update never marks the history dirty — a restarted seat
// cannot resume a reporter it no longer knows, and a per-percent fsync
// would put an IPC-speed stream on the file path the bound exists to
// protect.
package main

import (
	"virelai/vi"
)

const (
	// MarkerNotifyProgress is printed when a progress row is CREATED —
	// not per update: a 0..100 stream is a hundred lines of "the row
	// moved", and the gate wants the row's birth, not its every tick.
	MarkerNotifyProgress = "gotabwm: notify progress id="
	// MarkerNotifyProgressDone is printed on the transition into pct 100:
	// the moment the cancel affordance is withdrawn.
	MarkerNotifyProgressDone = "gotabwm: notify progress done id="
	// MarkerNotifyProgressCancel is printed when a row's Cancel is acted
	// on. `sent=` is whether the kind-23 push reached the reporter's
	// mailbox — a dead source or a pid-0 report still loses its row, but
	// the marker never claims a notice that was not delivered.
	MarkerNotifyProgressCancel = "gotabwm: notify progress cancel id="
	// notifyProgressCancelW is the Cancel affordance's hit zone: the
	// trailing 48px of a live progress row ("Cancel" is 6 cells at the
	// 8px face), vs the plain row's 34px X.
	notifyProgressCancelW = 48
)

// sendProgressNotice is the kind-23 push seam — a var like
// sendSettingsNotice so a host test can watch the frame without a mailbox.
var sendProgressNotice = vi.IpcSend

// notifyProgressUpdate applies one kind-22 report: the row keyed by
// (tabID, op) moves to the new pct/label, or a new bounded entry is
// appended. Returns (created, doneTransition) so the caller prints only
// the two informative markers — the row's birth and its completion.
func notifyProgressUpdate(tabID uint32, pid, op uint8, pct int, label string) (created, done bool) {
	for i := range notifyCenter {
		e := &notifyCenter[i]
		if e.progress && e.tabID == tabID && e.op == op {
			wasDone := e.pct >= 100
			e.pct, e.text, e.pid = pct, label, pid
			return false, pct >= 100 && !wasDone
		}
	}
	source := "App " + vi.Itoa64(int64(tabID))
	if i := tabs.index(tabID); i >= 0 && tabs.At(i).Title != "" {
		source = tabs.At(i).Title
	}
	if len(notifyCenter) == NotifyCenterMax {
		copy(notifyCenter, notifyCenter[1:])
		notifyCenter = notifyCenter[:NotifyCenterMax-1]
	}
	notifyCenterNextID++
	if notifyCenterNextID == 0 {
		notifyCenterNextID++
	}
	notifyCenter = append(notifyCenter, centerNotification{
		tabID: tabID, id: notifyCenterNextID, source: source, text: label,
		progress: true, op: op, pct: pct, pid: pid,
	})
	return true, pct >= 100
}

// progressDone reports whether the operation reached 100 — the moment the
// row's affordance flips from Cancel to a plain dismiss.
func (e centerNotification) progressDone() bool { return e.progress && e.pct >= 100 }

// notifyProgressCancel acts on a live progress row's Cancel: the kind-23
// push to the reporter's pid, carrying the op in title[0] and the bound
// window's session token when one exists (a forged cancel must quote it
// to pass PollProgressCancel's check). The row leaves the center either
// way — the user's intent is executed; the marker's sent= is the honest
// half about whether the app heard it.
func notifyProgressCancel(index int) bool {
	if index < 0 || index >= len(notifyCenter) {
		return false
	}
	e := notifyCenter[index]
	if !e.progress {
		return false
	}
	sent := false
	if e.pid != 0 && !e.sourceGone {
		var ev vi.WmRpc
		ev.Kind = vi.WmRpcKindProgressCancel
		ev.ID = uint8(e.tabID)
		ev.Title[0] = e.op
		if b := rpcBindings[uint8(e.tabID)]; b.token != 0 {
			ev.Pad = vi.WmRpcPadBound
			vi.SetWmAuth(&ev, b.token)
		}
		sent = sendProgressNotice(uint32(e.pid), ev.Encode()) >= 0
	}
	dismissNotifyCenter(index)
	word := "0"
	if sent {
		word = "1"
	}
	vi.ConsoleLine(MarkerNotifyProgressCancel + vi.Itoa64(int64(e.tabID)) +
		" op=" + vi.Itoa64(int64(e.op)) + " sent=" + word)
	return true
}

// notifyProgressSweep returns the indeterminate segment's x-offset inside
// a track of width w at composite tick t: a quarter-track block on a
// triangle wave, one step per tick — the seat's ~1 Hz cadence — sliding
// left→right→left. The appkit widget's sweep shares the arithmetic.
func notifyProgressSweep(t uint64, w int) (off, seg int) {
	seg = w / 4
	if seg < 1 {
		seg = 1
	}
	travel := w - seg
	if travel <= 0 {
		return 0, seg
	}
	ph := int(t % uint64(2*travel))
	if ph > travel {
		ph = 2*travel - ph
	}
	return ph, seg
}
