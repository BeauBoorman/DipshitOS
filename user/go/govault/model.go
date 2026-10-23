// model.go — the GOVAULT session model, pure of vi/vsys so the host tests can
// drive every deadline and refusal deterministically. main.go wires this to
// the seat, the clipboard and the one app timer.
//
// Three deadlines share the process's single app timer (slot 40, one armed
// timer per process, re-arm replaces):
//
//	idle  — the vault locks itself after idleLockNs of no input. Any
//	        non-timer event is activity and slides the deadline; an expired
//	        idle deadline locks exactly like ctrl-l.
//	clip  — a copied secret is cleared clipLiveNs after the copy, but only
//	        when the clipboard still holds it (the compare rule — a later
//	        copy by someone else is theirs, not ours to wipe).
//	tick  — M156c (#2933): a once-a-second repaint while the list face has
//	        a live TOTP row, so the seconds countdown stays honest. It is
//	        the only deadline that re-arms itself on fire, and it arms only
//	        while an unlocked vault actually carries a seed.
//
// The clip deadline SURVIVES lock: the kernel clipboard is a shared buffer,
// and locking the vault must not strand a plaintext copy of a secret in it.
// What survives is a sha256 tag plus the length — never the plaintext — so a
// locked vault holds no secret material at all.
package main

import (
	"crypto/sha256"

	"virelai/vaultlib"
)

const (
	// idleLockNs is five idle minutes in Nanotime units.
	idleLockNs = int64(5 * 60 * 1_000_000_000)
	// clipLiveNs is the 30-second clipboard lease the card sets.
	clipLiveNs = int64(30 * 1_000_000_000)
	// tickNs is one scheduler tick — 1 s on VZ (pulse's "1 tick = 1 s").
	tickNs = int64(1_000_000_000)
	// maxDelayTicks is kernel app_timers.max_delay_ticks.
	maxDelayTicks = 3600
)

// deadlines tracks the three app-timer consumers in absolute Nanotime; 0
// means disarmed.
type deadlines struct {
	idleDue int64
	clipDue int64
	tickDue int64
}

// activity slides the idle deadline — called on every non-timer event while
// the vault is unlocked.
func (d *deadlines) activity(now int64) { d.idleDue = now + idleLockNs }

// armClip starts the 30-second clipboard lease.
func (d *deadlines) armClip(now int64) { d.clipDue = now + clipLiveNs }

// armTick schedules the next one-second repaint for the TOTP countdown.
// Unlike the other two it is periodic: the timer handler re-arms it each
// fire while a totp row is on screen.
func (d *deadlines) armTick(now int64) { d.tickDue = now + tickNs }

// stopIdle disarms the idle deadline (the vault is already locked — nothing
// to time out).
func (d *deadlines) stopIdle() { d.idleDue = 0 }

// stopClip clears the clip deadline (it fired, or a new copy replaced it).
func (d *deadlines) stopClip() { d.clipDue = 0 }

// stopTick disarms the repaint tick — no totp row is on screen, or the vault
// locked.
func (d *deadlines) stopTick() { d.tickDue = 0 }

// nextDelay is the ticks to arm the physical timer for: the ceiling of the
// earliest live deadline in whole ticks, 0 when nothing is armed. Ceiling
// (not floor) so a deadline can only ever fire LATE, never early — a
// sub-tick remainder re-arms for one more tick and converges.
func (d *deadlines) nextDelay(now int64) uint64 {
	best := int64(0)
	if d.idleDue > 0 {
		best = d.idleDue
	}
	if d.clipDue > 0 && (best == 0 || d.clipDue < best) {
		best = d.clipDue
	}
	if d.tickDue > 0 && (best == 0 || d.tickDue < best) {
		best = d.tickDue
	}
	if best == 0 {
		return 0
	}
	ns := best - now
	if ns <= 0 {
		return 1
	}
	t := (ns + tickNs - 1) / tickNs
	if t > maxDelayTicks {
		t = maxDelayTicks
	}
	return uint64(t)
}

// expired reports which deadlines fired by now.
func (d *deadlines) expired(now int64) (idle, clip, tick bool) {
	return d.idleDue > 0 && now >= d.idleDue,
		d.clipDue > 0 && now >= d.clipDue,
		d.tickDue > 0 && now >= d.tickDue
}

// clipTag is the compare token for the expiry rule: sha256 of the copied
// secret plus its length. Enough to recognize "our copy is still the
// clipboard", not enough to recover a byte of it — that is the whole point
// of keeping the tag and dropping the plaintext at copy time.
type clipTag struct {
	sum [32]byte
	len int
}

// setClipTag hashes the secret at copy time. It is the ONLY copy of the
// comparison — after this the plaintext leaves process memory.
func setClipTag(secret []byte) clipTag {
	return clipTag{sum: sha256.Sum256(secret), len: len(secret)}
}

// holds is the compare-before-clear rule: the clipboard still holds exactly
// our secret when the length and the digest both match. A shorter, longer or
// different body means somebody else copied since — leave it alone.
func (c clipTag) holds(clipboard []byte) bool {
	return len(clipboard) == c.len && sha256.Sum256(clipboard) == c.sum
}

// empty reports whether a copy lease is in flight.
func (c clipTag) empty() bool { return c.len == 0 }

// wipe clears the tag (it names no secret material, but a clean shutdown is
// a clean shutdown).
func (c *clipTag) wipe() {
	vaultlib.Zero(c.sum[:])
	c.len = 0
}

// screen is the app's state machine: four faces, no other state.
type screen int

const (
	// scrNew is the no-file face: choose a passphrase (masked), confirm it.
	scrNew screen = iota
	// scrLocked is the unlock prompt — a masked field and the refusal.
	scrLocked
	// scrBadFile is the named structural refusal: the file is not a vault.
	// It offers no unlock attempt — spending a passphrase on a file that is
	// not a vault teaches nothing and risks nothing worth the risk.
	scrBadFile
	// scrList is the unlocked face: the vaultlib.Entry list with per-vaultlib.Entry reveal.
	scrList
	// scrAdd is the add-vaultlib.Entry face: name, masked secret, note.
	scrAdd
	// scrReceipts is the receipts face: the vault's own receipts file
	// listed back, read-only (M148b).
	scrReceipts
	// scrExport is the bundle-passphrase face (M156c): the picked save
	// path is already chosen; two masked fields guard the GVLX write.
	scrExport
	// scrImport is the bundle-passphrase face for an open pick: one masked
	// field, then the merge. Both sit past the picker so the unlock face
	// never carries a bundle passphrase.
	scrImport
)

// model is the unlockable state — the part of the app a host test needs to
// pin without a seat, a file channel or a timer.
type model struct {
	scr screen

	// Session material — present only while unlocked; lock() zeroes all of
	// it. salt and iters are not secret (they sit in the plaintext header);
	// they are kept so a save re-seals under the SAME header the unlock
	// proved, while key IS the session secret.
	entries []vaultlib.Entry
	key     []byte
	salt    []byte
	iters   uint32
	sel     int
	shown   map[int]bool // per-vaultlib.Entry reveal

	// rcpts is the loaded receipts view (M148b): metadata rows, never
	// secret material. It is cleared on lock anyway — the view reloads
	// from the file on vaultlib.Entry, so a locked vault holds no stale copy.
	rcpts []receipt

	dl    deadlines
	ctag  clipTag
	armed uint64 // ticks the physical timer was last armed for — test seam
}

// lock wipes every byte of session material and returns to the locked face.
// The clip deadline survives: the clipboard is still holding the plaintext
// we put there, locked or not.
func (m *model) lock() {
	vaultlib.ZeroEntries(m.entries)
	m.entries = nil
	vaultlib.Zero(m.key)
	m.key = nil
	m.shown = nil
	m.sel = 0
	m.rcpts = nil
	m.dl.stopIdle()
	m.dl.stopTick()
	if m.scr == scrList || m.scr == scrAdd || m.scr == scrReceipts ||
		m.scr == scrExport || m.scr == scrImport {
		m.scr = scrLocked
	}
}

// unlocked installs a freshly opened session. key and salt are retained for
// saves; the idle deadline starts from the unlock itself (creating and then
// walking away is still idle).
func (m *model) unlocked(entries []vaultlib.Entry, key, salt []byte, iters uint32, now int64) {
	m.entries = entries
	m.key = key
	m.salt = salt
	m.iters = iters
	m.shown = make(map[int]bool)
	m.sel = 0
	m.scr = scrList
	m.dl.activity(now)
}

// toggleReveal flips the selected vaultlib.Entry's reveal. Reveal is per vaultlib.Entry by
// contract — one row's secret on screen, never the column.
func (m *model) toggleReveal() bool {
	if m.scr != scrList || m.sel < 0 || m.sel >= len(m.entries) {
		return false
	}
	m.shown[m.sel] = !m.shown[m.sel]
	return true
}

// revealed reports whether vaultlib.Entry i is face-up.
func (m *model) revealed(i int) bool { return m.shown[i] }

// move clamps the selection inside the list.
func (m *model) move(delta int) bool {
	if len(m.entries) == 0 {
		return false
	}
	n := m.sel + delta
	if n < 0 {
		n = 0
	}
	if n > len(m.entries)-1 {
		n = len(m.entries) - 1
	}
	if n == m.sel {
		return false
	}
	m.sel = n
	return true
}

// addEntry appends a bounded vaultlib.Entry. The name is required — an vaultlib.Entry you
// cannot name is an vaultlib.Entry you cannot find. Copies are taken so the caller's
// field buffers can be cleared without aliasing session material. totp is
// the canonical base32 seed parseOTPSecret produced — never validated here,
// the intake face owns that refusal.
func (m *model) addEntry(name, secret, note, totp []byte) bool {
	if len(name) == 0 || len(name) > vaultlib.MaxName || len(secret) > vaultlib.MaxSecret ||
		len(note) > vaultlib.MaxNote || len(totp) > vaultlib.MaxTotp || len(m.entries) >= vaultlib.MaxEntries {
		return false
	}
	e := vaultlib.Entry{Name: append([]byte(nil), name...), Secret: append([]byte(nil), secret...)}
	if len(note) > 0 {
		e.Note = append([]byte(nil), note...)
	}
	if len(totp) > 0 {
		e.Totp = append([]byte(nil), totp...)
	}
	m.entries = append(m.entries, e)
	m.sel = len(m.entries) - 1
	return true
}

// mergeEntries folds an imported bundle into the session under the card's
// no-clobber rule: a name the vault already holds keeps the vault's copy and
// the imported row is counted skipped — nothing is silently overwritten.
// Callers zero the source slice afterwards; the fields merge keeps are
// cloned, so wiping the import copy strands nothing live.
func (m *model) mergeEntries(imported []vaultlib.Entry) (added, skipped int) {
	for _, e := range imported {
		dup := false
		for i := range m.entries {
			if vaultlib.EqualBytes(m.entries[i].Name, e.Name) {
				dup = true
				break
			}
		}
		if dup || len(e.Name) == 0 {
			skipped++
			continue
		}
		if !m.addEntry(e.Name, e.Secret, e.Note, e.Totp) {
			skipped++
			continue
		}
		added++
	}
	return added, skipped
}

// hasTotp reports whether any vaultlib.Entry carries a seed — the repaint tick's arm
// condition and the draw path's column decision share this one answer.
func (m *model) hasTotp() bool {
	for i := range m.entries {
		if len(m.entries[i].Totp) > 0 {
			return true
		}
	}
	return false
}
