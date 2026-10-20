// model.go — the GOVAULT session model, pure of vi/vsys so the host tests can
// drive every deadline and refusal deterministically. main.go wires this to
// the seat, the clipboard and the one app timer.
//
// Two deadlines share the process's single app timer (slot 40, one armed
// timer per process, re-arm replaces):
//
//	idle  — the vault locks itself after idleLockNs of no input. Any
//	        non-timer event is activity and slides the deadline; an expired
//	        idle deadline locks exactly like ctrl-l.
//	clip  — a copied secret is cleared clipLiveNs after the copy, but only
//	        when the clipboard still holds it (the compare rule — a later
//	        copy by someone else is theirs, not ours to wipe).
//
// The clip deadline SURVIVES lock: the kernel clipboard is a shared buffer,
// and locking the vault must not strand a plaintext copy of a secret in it.
// What survives is a sha256 tag plus the length — never the plaintext — so a
// locked vault holds no secret material at all.
package main

import "crypto/sha256"

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

// deadlines tracks the two app-timer consumers in absolute Nanotime; 0 means
// disarmed.
type deadlines struct {
	idleDue int64
	clipDue int64
}

// activity slides the idle deadline — called on every non-timer event while
// the vault is unlocked.
func (d *deadlines) activity(now int64) { d.idleDue = now + idleLockNs }

// armClip starts the 30-second clipboard lease.
func (d *deadlines) armClip(now int64) { d.clipDue = now + clipLiveNs }

// stopIdle disarms the idle deadline (the vault is already locked — nothing
// to time out).
func (d *deadlines) stopIdle() { d.idleDue = 0 }

// stopClip clears the clip deadline (it fired, or a new copy replaced it).
func (d *deadlines) stopClip() { d.clipDue = 0 }

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
func (d *deadlines) expired(now int64) (idle, clip bool) {
	return d.idleDue > 0 && now >= d.idleDue, d.clipDue > 0 && now >= d.clipDue
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
	zero(c.sum[:])
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
	// scrList is the unlocked face: the entry list with per-entry reveal.
	scrList
	// scrAdd is the add-entry face: name, masked secret, note.
	scrAdd
)

// model is the unlockable state — the part of the app a host test needs to
// pin without a seat, a file channel or a timer.
type model struct {
	scr screen

	// Session material — present only while unlocked; lock() zeroes all of
	// it. salt and iters are not secret (they sit in the plaintext header);
	// they are kept so a save re-seals under the SAME header the unlock
	// proved, while key IS the session secret.
	entries []entry
	key     []byte
	salt    []byte
	iters   uint32
	sel     int
	shown   map[int]bool // per-entry reveal

	dl    deadlines
	ctag  clipTag
	armed uint64 // ticks the physical timer was last armed for — test seam
}

// lock wipes every byte of session material and returns to the locked face.
// The clip deadline survives: the clipboard is still holding the plaintext
// we put there, locked or not.
func (m *model) lock() {
	zeroEntries(m.entries)
	m.entries = nil
	zero(m.key)
	m.key = nil
	m.shown = nil
	m.sel = 0
	m.dl.stopIdle()
	if m.scr == scrList || m.scr == scrAdd {
		m.scr = scrLocked
	}
}

// unlocked installs a freshly opened session. key and salt are retained for
// saves; the idle deadline starts from the unlock itself (creating and then
// walking away is still idle).
func (m *model) unlocked(entries []entry, key, salt []byte, iters uint32, now int64) {
	m.entries = entries
	m.key = key
	m.salt = salt
	m.iters = iters
	m.shown = make(map[int]bool)
	m.sel = 0
	m.scr = scrList
	m.dl.activity(now)
}

// toggleReveal flips the selected entry's reveal. Reveal is per entry by
// contract — one row's secret on screen, never the column.
func (m *model) toggleReveal() bool {
	if m.scr != scrList || m.sel < 0 || m.sel >= len(m.entries) {
		return false
	}
	m.shown[m.sel] = !m.shown[m.sel]
	return true
}

// revealed reports whether entry i is face-up.
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

// addEntry appends a bounded entry. The name is required — an entry you
// cannot name is an entry you cannot find. Copies are taken so the caller's
// field buffers can be cleared without aliasing session material.
func (m *model) addEntry(name, secret, note []byte) bool {
	if len(name) == 0 || len(name) > maxName || len(secret) > maxSecret ||
		len(note) > maxNote || len(m.entries) >= maxEntries {
		return false
	}
	e := entry{
		name:   append([]byte(nil), name...),
		secret: append([]byte(nil), secret...),
	}
	if len(note) > 0 {
		e.note = append([]byte(nil), note...)
	}
	m.entries = append(m.entries, e)
	m.sel = len(m.entries) - 1
	return true
}
