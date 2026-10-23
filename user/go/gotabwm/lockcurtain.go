// lockcurtain.go — M190e (#3240): the screen lock over the vault credential.
//
// The PWR menu's Lock row and the seat's ctrl+shift+l chord drop a
// full-opacity veil. The swallow rides power.go's invisible input-sink
// pattern: a seat-owned window takes kernel focus, so ADR 0009's KEY_DOWN
// fan-out has nowhere to deliver but the seat itself — a hosted app
// receives nothing, and the kind-21 mirrors that still arrive feed the
// curtain's own field instead of the chord dispatch. Serial input to the
// kernel monitor is not the seat's to swallow — "no HID reaches" covers
// hosted apps only.
//
// Unlock re-auths the typed passphrase against the vault frame through
// virelai/vaultlib — the same codec GOVAULT opens with, never a fork.
// With no readable credential the lock refuses by name, never silently
// no-ops: `lock refused no_credential` when VAULT.BIN is absent or
// unreadable, `lock refused bad_credential` when its frame does not parse,
// `lock refused no_sink` when the kernel will not hand the seat a focused
// window to park the keyboard on.
package main

import (
	"virelai/draw"
	"virelai/theme"
	"virelai/vaultlib"
	"virelai/vi"
	"virelai/widgets"
)

// The markers the class-B gate (and the seat's own tests) grep. Exported
// like every other marker family in this package.
const (
	MarkerLocked       = "gotabwm: locked"
	MarkerLockRefused  = "gotabwm: lock refused "
	MarkerUnlockFailed = "gotabwm: unlock failed"
	MarkerUnlocked     = "gotabwm: unlocked"
)

// Lock state. active while the curtain is up; sink is the seat-owned window
// holding kernel focus; prior is the focus to hand back on unlock; file is
// the vault frame read at lock time (kept — re-reading at unlock would let
// a swapped file answer a lock taken on another); pass is the typed
// passphrase buffer, zeroed on every outcome like govault's fields.
var (
	lockActive bool
	lockSink   uint32
	lockPrior  uint32
	lockFile   []byte
	lockPass   []byte
)

const lockPassMax = 64 // govault's passphrase field bound, mirrored

// lockReadFile is the vault read seam — vi.ReadFileAll on the guest, a
// fixture in host tests (the execApp/openFile pattern).
var lockReadFile = vi.ReadFileAll

// lockFocusTarget is the id focus returns to on unlock: the open launcher's
// sink while it is up (its own ensure-refocus owns that window), else the
// seat's focused tab.
func lockFocusTarget() uint32 {
	if launch.open && launch.sink != 0 {
		return launch.sink
	}
	if id, ok := tabs.Focused(); ok {
		return id
	}
	return 0
}

// requestLock drops the curtain: prove a credential exists, then take an
// input-sink focus window. The order is deliberate — a seat that locks
// without a credential it can verify would strand the user, so the file
// is parsed before the sink is taken and every refusal is named.
func requestLock() {
	if lockActive {
		return
	}
	file, r := lockReadFile(vaultlib.DefaultPath, vaultlib.MaxFile+1)
	if r < 0 || file == nil {
		vi.ConsoleLine(MarkerLockRefused + "no_credential")
		return
	}
	if _, _, _, _, _, err := vaultlib.ParseHeader(file, vaultlib.FileMagic); err != nil {
		vi.ConsoleLine(MarkerLockRefused + "bad_credential")
		return
	}
	// The sink is the power.go pattern: a seat-owned window the kernel
	// focuses, so its owner's queue — this seat's — receives the KEY_DOWN
	// fan-out and no hosted app does. 1x1 parked in the corner: the curtain
	// itself is painted straight onto the scanout, not uploaded.
	id, r := openInputSink(uint32(vi.ScanoutWidth-1), uint32(vi.ScanoutHeight-1), 1, 1)
	if r < 0 {
		vi.ConsoleLine(MarkerLockRefused + "no_sink")
		return
	}
	lockSink = uint32(id)
	st, qr := queryWindow(int(lockSink))
	if qr < 0 || (st[5] == 0 && focusRaise(lockSink) != 0) {
		_ = closeWin(lockSink)
		lockSink = 0
		vi.ConsoleLine(MarkerLockRefused + "no_sink")
		return
	}
	lockPrior = lockFocusTarget()
	lockFile = file
	for i := range lockPass {
		lockPass[i] = 0
	}
	lockPass = lockPass[:0]
	lockActive = true
	vi.ConsoleLine(MarkerLocked)
}

// unlockTry verifies the typed passphrase against the frame the lock read.
// A wrong pass names the refusal and stays locked — wrong passphrase and a
// tampered seal are the same answer by codec design. The right pass drops
// the curtain and hands focus back to whatever held it.
func unlockTry() {
	err := vaultlib.Verify(lockPass, lockFile)
	for i := range lockPass {
		lockPass[i] = 0
	}
	lockPass = lockPass[:0]
	if err != nil {
		vi.ConsoleLine(MarkerUnlockFailed)
		return
	}
	if lockSink != 0 {
		_ = closeWin(lockSink)
		lockSink = 0
	}
	lockFile = nil
	lockActive = false
	lastInputTick = seatTick
	if id := lockPrior; id != 0 && id < sessionIDBase && tabs.index(id) >= 0 &&
		focusRaise(id) == 0 {
		_ = tabs.FocusTab(id)
		hostedApp = id
	}
	lockPrior = 0
	vi.ConsoleLine(MarkerUnlocked)
}

// lockKeyDown feeds one kind-1 KEY_DOWN to the curtain's passphrase field.
// With the sink focused the kernel delivers these to the seat decoded —
// arg1 carries the real ASCII, so shifted passphrases work; the kind-21
// mirror never leaves consumeSeatEvent, so no seat chord fires either.
// Enter submits; Backspace erases; Escape clears the field — a slip should
// not spend an attempt.
func lockKeyDown(e vi.Event) {
	switch e.Arg0 {
	case 0x28: // Enter
		unlockTry()
		return
	case 0x2A: // Backspace
		if n := len(lockPass); n > 0 {
			lockPass[n-1] = 0
			lockPass = lockPass[:n-1]
		}
		return
	case 0x29: // Escape
		for i := range lockPass {
			lockPass[i] = 0
		}
		lockPass = lockPass[:0]
		return
	}
	if c := e.Arg1; c >= 0x20 && c < 0x7f && len(lockPass) < lockPassMax {
		lockPass = append(lockPass, byte(c))
	}
}

// --- paint --------------------------------------------------------------

const (
	lockW = 288
	lockH = 96
)

// paintLockCurtain paints the full-opacity veil and the one passphrase
// field — a mask of bullets, never the bytes, like govault's fields.
func paintLockCurtain(scan []byte, width, height int) int {
	if width <= 0 || height <= 0 || len(scan) < 4 {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	written := seatFill(c, widgets.Rect{X: 0, Y: 0, W: width, H: height}, tok.ChromeBg)
	w, h := lockW, lockH
	if w > width-2*chromeInset {
		w = width - 2*chromeInset
	}
	if h > height-2*chromeInset {
		h = height - 2*chromeInset
	}
	if w <= 0 || h <= 0 {
		return written
	}
	x, y := (width-w)/2, (height-h)/2
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	written += seatPlate(c, plate, radiusWindow, tok.Accent, tok.Surface)
	clip := plate.Inset(seatRuleW)
	seatText(c, clip, x+12, y+10, seatTextPx, "LOCKED", tok.Ink)
	fx, fy, fw := x+12, y+32, w-24
	c.FillRect(widgets.Rect{X: fx, Y: fy, W: fw, H: 20}, draw.Opaque(tok.Bg))
	var mask [lockPassMax]byte
	n := len(lockPass)
	for i := 0; i < n && i < lockPassMax; i++ {
		mask[i] = '*'
	}
	seatText(c, clip, fx+4, fy+5, seatTextPx, string(mask[:n]), tok.Ink)
	seatText(c, clip, x+12, y+h-18, seatSmallPx, "vault passphrase unlocks", tok.InkMuted)
	return written
}
