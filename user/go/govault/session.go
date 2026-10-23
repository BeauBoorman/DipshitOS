// session.go — the vault session state: the app struct (seat client, model,
// field buffers, picker, status), the file load/save under WriteFileSafe,
// the one-timer deadline driver (idle lock, clipboard lease, TOTP repaint),
// the lock wipe, the seat-selection clipboard plumbing, and the M125a
// save_state hooks. The codec is vaultlib's; the model's deadline math is
// model.go's. The seam vars this file calls live in main.go with the rest
// of the marker vocabulary.
package main

import (
	"virelai/appkit"
	"virelai/tabapp"
	"virelai/vaultlib"
	"virelai/vi"
)

// app is the session: the seat client, the model, the loaded file, the field
// buffers per face, the open picker (modal over the list face), and the last
// status line (never secret material).
type app struct {
	ta *tabapp.TabApp
	m  model

	path string
	file []byte

	pass  field // masked passphrase (locked + new + export + import)
	conf  field // masked confirm (new + export)
	focus int   // field index inside the current face
	add   [4]field

	pick     appkit.FilePicker
	picking  bool   // the picker plate owns input while open
	pickPath string // the path the picker resolved — export target or import source

	status string
	quit   bool
}

// The TOTP clock marker is the card's probe leg: the guest wall clock the
// codes are computed against, printed at the moments a code could be on
// screen (unlock, import, reveal) so the host can read skew off the last
// line. Epoch seconds are not secret material.
func (a *app) clockMarker() {
	vi.ConsoleLine(markerClock + vi.Itoa64(timeFn()))
}

// load reads the vault file once and picks the opening face. The bytes stay
// for the unlock attempts — an unlock needs them anyway, so there is no
// re-read between faces (and a file changed under the app is the next
// process's problem, not this boot's).
func (a *app) load() {
	data, rc := readAll(a.path, vaultlib.MaxFile+1)
	if rc < 0 {
		if rc == -int64(vi.ErrENOENT) {
			a.m.scr = scrNew
			vi.ConsoleLine(markerNew)
			return
		}
		a.m.scr = scrBadFile
		vi.ConsoleLine(markerLoadErr + vi.Itoa64(rc))
		return
	}
	if _, _, _, _, _, err := vaultlib.ParseHeader(data, vaultlib.FileMagic); err != nil {
		a.m.scr = scrBadFile
		vi.ConsoleLine(markerBad)
		return
	}
	a.file = data
	a.m.scr = scrLocked
	vi.ConsoleLine(markerLocked)
	// D16: a vault written before the 0600 posture stays 0644 on disk —
	// tighten it on open so the agent's other-triplet read closes. A
	// refusal means the file is not ours; the bytes already parsed, so the
	// errno is noise the face does not need.
	_ = fileMode(a.path, 0o600)
}

// rearm drives the one app timer from the model's deadline triple. Called
// after every event that can change a deadline, so the physical timer always
// counts toward the earliest live one. The TOTP repaint tick arms here too:
// live while the list face shows a seeded row, disarmed the moment lock or
// a face change takes it off screen.
func (a *app) rearm() {
	now := nowFn()
	if a.m.scr == scrList && a.m.hasTotp() {
		a.m.dl.armTick(now)
	} else {
		a.m.dl.stopTick()
	}
	d := a.m.dl.nextDelay(now)
	if d == 0 {
		if a.m.armed != 0 {
			a.m.armed = 0
			timerCancel()
		}
		return
	}
	a.m.armed = d
	timerSetFn(d)
}

// onTimer runs whichever deadlines fired. Order is clip-then-idle so an
// expiry that lands on the same tick as the lock still clears the shared
// buffer before the session material is wiped.
func (a *app) onTimer() bool {
	now := nowFn()
	idle, clip, tick := a.m.dl.expired(now)
	changed := false
	if clip {
		a.expireClip()
		changed = true
	}
	if idle {
		a.lockSession(true)
		changed = true
	}
	if tick {
		// The countdown's periodic repaint: re-arm happens in rearm below
		// — the tick stays live only while a totp row is on the list face.
		changed = true
	}
	a.rearm()
	return changed
}

// expireClip is the 30-second lease end: pull the buffer, apply the
// compare-before-clear rule, and say exactly what happened. A failed pull
// still clears — the alternative is a secret stranded in a buffer we could
// not read, and clobbering a stranger's one stale copy is the smaller harm.
func (a *app) expireClip() {
	a.m.dl.stopClip()
	buf, ok := a.pullSel()
	kept := ok && !a.m.ctag.holds(buf)
	vaultlib.Zero(buf)
	a.m.ctag.wipe()
	if kept {
		vi.ConsoleLine(markerKept)
		a.status = "clipboard changed hands — kept"
		return
	}
	if a.publishSel([]byte(clearBytes)) {
		vi.ConsoleLine(markerExpired)
		a.status = "clipboard cleared"
		notifyFn(a.ta, "clipboard cleared")
		return
	}
	vi.ConsoleLine(markerClipRef)
	a.status = "clipboard clear refused"
}

// publishSel is SelPublish with one restage-and-repost. A bound request
// whose ack never lands (#2260's documented lost-ack/full-ring hazard —
// observed on leg 02: the seat stored len=6, the ack never matched, the
// challenge-resend then met a staging file the first serve had already
// consumed and refused `missing`) is retried through the same call —
// which restages the envelope — so the re-sent request has its payload
// back. A stored-then-retried publish is an idempotent overwrite of the
// same buffer with the same bytes.
func (a *app) publishSel(text []byte) bool {
	if selPublish(uint32(a.ta.Win), text, appName) {
		return true
	}
	return selPublish(uint32(a.ta.Win), text, appName)
}

// pullSel is RequestSelPaste with one retry — the pull's ack rides the same
// lossy ring, and a false here feeds the compare-before-clear rule's
// clear-anyway arm, so one retry buys back the honest read.
func (a *app) pullSel() ([]byte, bool) {
	if buf, ok := selPull(uint32(a.ta.Win), appName); ok {
		return buf, true
	}
	return selPull(uint32(a.ta.Win), appName)
}

// lockSession wipes the session and returns to the locked face. The clip
// deadline is deliberately untouched — the shared buffer still holds the
// plaintext we put there and the lease still runs.
func (a *app) lockSession(idle bool) {
	a.m.lock()
	a.pass.clear()
	a.conf.clear()
	a.focus = 0
	a.add[0].clear()
	a.add[1].clear()
	a.add[2].clear()
	a.add[3].clear()
	a.picking = false // a lock closes the picker with the faces under it
	a.pick.Open = false
	if idle {
		vi.ConsoleLine(markerIdle)
		a.status = "locked after 5 idle minutes"
		notifyFn(a.ta, "vault locked")
	} else {
		vi.ConsoleLine(markerLocked)
		a.status = "locked"
	}
}

// save reseals the session under the SAME salt and iteration count the
// unlock proved, with a fresh nonce per publish, through WriteFileSafe — a
// crash keeps the old file, never a half-written one.
func (a *app) save() bool {
	nonce := make([]byte, vaultlib.NonceLen)
	if !randFill(nonce) {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrENOSYS)))
		return false
	}
	file, err := vaultlib.SealWithKey(vaultlib.FileMagic, vaultlib.FileVersion, a.m.key, a.m.salt, nonce, a.m.iters, a.m.entries)
	if err != nil {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return false
	}
	defer vaultlib.Zero(file)
	if rc := writeSafe(a.path, file); rc < 0 {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(rc))
		return false
	}
	// D16: the vault is private to its owner — a fresh publish lands the
	// guest default 0644, so pull it to 0600 (the agent's other-triplet
	// read must never reach the ciphertext). The chmod is owner-only;
	// this process wrote the file, so the refusal cannot fire honestly —
	// report the kernel's errno if it does.
	if rc := fileMode(a.path, 0o600); rc < 0 {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(rc))
	}
	// The published frame is also the bytes a same-session unlock opens:
	// on the create path nothing ever read the file off disk, so without
	// this a lock->unlock pair meets vaultlib.ParseHeader(nil) -> bad file. It is
	// the sealed text — ciphertext is not secret material to shed.
	a.file = append(a.file[:0], file...)
	vi.ConsoleLine(markerSaved)
	return true
}

// --- save_state (M125a, hooked M156c) -----------------------------------------

// saveBlob is the Config.SaveState hook: the open vault's path and nothing
// else. Never a passphrase, key, vaultlib.Entry or revealed secret — the blob is a
// convenience pointer, and a restored vault starts locked because the path
// is all it learned.
func (a *app) saveBlob() []byte {
	return encodeState(a.path)
}

// applyState is the Config.RestoreState hook: the seat hands back the stored
// path; a sane share path becomes the vault this boot opens. load() runs
// after Init, so the restored path feeds the same face selection a fresh
// boot gets — locked when the file exists.
func (a *app) applyState(blob []byte) {
	if path, ok := decodeState(blob); ok {
		a.path = path
	}
}
