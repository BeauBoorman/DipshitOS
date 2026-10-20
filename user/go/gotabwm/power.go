// GOTABWM — M115d (issue #2463, ADR 0056 D5): the seat's power affordance.
//
// A PWR button on the bottom chrome (right of the Apps button) opens a
// one-item menu — Suspend — which asks the host to freeze machine state
// into the boot profile's saved-state/. The request rides ONE
// virelai-ctl/1 session through slot 93 (`sys_vsock_ctl`): the kernel
// authenticates with its uid_system credential, runs the guest quiesce
// (VLFS fsync, the settings re-save, the SUSPEND.MARK receipt), and
// relays the host's verdict — the seat never sees the key, which is the
// whole point of the seam. `gotabwm: suspend ok` may print on the far
// side of a host save/restore; the menu's next frame IS the resumed
// desktop.
//
// The menu reuses the launcher's modal discipline: an invisible input
// sink window takes focus while it is open so its keys (Esc, Enter) are
// the seat's alone and a hosted app receives nothing.
package main

import (
	"virelai/draw"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// The markers the class-B gate (and the seat's own tests) grep. Exported
// like every other marker family in this package.
const (
	MarkerPowerOpen      = "gotabwm: power open"
	MarkerPowerDismiss   = "gotabwm: power dismiss"
	MarkerSuspendRequest = "gotabwm: suspend request"
	// The verdict line: `gotabwm: suspend ok` or `gotabwm: suspend <code>`
	// — the ADR 0056 refusal name when the host or kernel refused.
	MarkerSuspendVerdict = "gotabwm: suspend "
	// M120d (#2561): the Snapshot row's report — `exec`, `focus id=`, or
	// the refusal named.
	MarkerPowerSnapshot = "gotabwm: power snapshot "
)

// The menu's rows: Suspend is the M115d verb (first, the Enter default);
// M120d's Snapshot row launches or focuses GOSNAP.ELF's snapshot window.
var powerRows = [2]string{"Suspend", "Snapshot"}

// gosnapBin is the binary the Snapshot row drives.
const gosnapBin = "GOSNAP.ELF"

// Button + menu geometry. The button is a square on the chrome band
// between the Apps button and the clock panel; the menu floats above it.
const (
	powerBtnW    = 28
	powerBtnGap  = 4
	powerMenuW   = 88
	powerRowH    = 20
	powerMenuGap = 4
	powerMenuH   = 2*powerRowH + 6
)

// power state. sink is the focus-stealing invisible window; 0 when none.
// powerSel is the keyboard-highlighted row — Enter's target.
var (
	powerMenuOpen  bool
	powerSink      uint32
	powerBtnHover  bool
	powerBtnLogged bool
	powerSel       int
)

// powerBtnRect is the button's rect on a width x height scanout: the
// chrome band, square, right of the Apps button — the zero rect when the
// band cannot fit it (the same shrink rule godMenuRect obeys). Pure.
func powerBtnRect(width, height int) (x, y, w, h int) {
	gx, gy, gw, gh := godMenuRect(width, height)
	if gw == 0 {
		return 0, 0, 0, 0
	}
	x, y, w, h = gx+gw+powerBtnGap, gy, powerBtnW, gh
	cx, _, _, _ := chromeRect(width, height)
	if x+w+chromeInset > cx {
		return 0, 0, 0, 0
	}
	return
}

func powerBtnHit(px, py uint32, width, height int) bool {
	x, y, w, h := powerBtnRect(width, height)
	return w > 0 && int(px) >= x && int(px) < x+w && int(py) >= y && int(py) < y+h
}

// powerMenuRect is the panel's rect: one row above the button, right
// edge aligned, clamped inside the rail band and the left inset. Pure.
func powerMenuRect(width, height int) (x, y, w, h int) {
	bx, by, bw, _ := powerBtnRect(width, height)
	if bw == 0 {
		return 0, 0, 0, 0
	}
	w, h = powerMenuW, powerMenuH
	x = bx + bw - w
	if x < chromeInset {
		x = chromeInset
	}
	y = by - h - powerMenuGap
	if y < RailHeight {
		y = RailHeight
	}
	return
}

// powerMenuRowAt maps a point onto a row index, or -1 outside any row —
// the one geometry source Draw's row rects and the pointer path share.
func powerMenuRowAt(px, py uint32, width, height int) int {
	x, y, w, _ := powerMenuRect(width, height)
	if w == 0 || int(px) < x || int(px) >= x+w {
		return -1
	}
	rel := int(py) - y - 3
	if rel < 0 {
		return -1
	}
	i := rel / powerRowH
	if i < 0 || i >= len(powerRows) {
		return -1
	}
	return i
}

// --- the modal sink (the launcher's pattern over the menu rect) ---------

func acquirePowerFocus() bool {
	x, y, w, h := powerMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if w <= 0 {
		return false
	}
	id, r := openInputSink(uint32(x), uint32(y), uint32(w), uint32(h))
	if r < 0 {
		return false
	}
	powerSink = uint32(id)
	st, qr := queryWindow(int(powerSink))
	if qr < 0 || (st[5] == 0 && focusRaise(powerSink) != 0) {
		_ = closeWin(powerSink)
		powerSink = 0
		return false
	}
	return true
}

// ensurePowerFocus reports whether the menu's sink still exists — the
// kernel reaps a dead window out from under the seat.
func ensurePowerFocus() bool {
	if powerSink == 0 {
		return false
	}
	_, r := queryWindow(int(powerSink))
	return r >= 0
}

func releasePowerFocus() {
	if powerSink != 0 {
		_ = closeWin(powerSink)
		powerSink = 0
	}
}

func openPowerMenu() {
	dragAbort("chrome") // M124a: the modal menu takes the gesture
	if powerMenuOpen {
		return
	}
	powerMenuOpen = true
	powerSel = 0
	if !acquirePowerFocus() {
		powerSink = 0
	}
	vi.ConsoleLine(MarkerPowerOpen)
}

func dismissPowerMenu() {
	if !powerMenuOpen {
		return
	}
	releasePowerFocus()
	powerMenuOpen = false
	vi.ConsoleLine(MarkerPowerDismiss)
}

// handlePowerKey consumes the menu's keys while it is open. Esc
// dismisses; Up/Down move the highlight; Enter is the highlighted row's
// click. Every other key is swallowed by the sink anyway — the return
// just keeps the seat's own chords quiet.
func handlePowerKey(e vi.Event) bool {
	if !powerMenuOpen {
		return false
	}
	switch e.Arg0 {
	case 0x29: // Escape
		dismissPowerMenu()
	case 0x52: // Up
		if powerSel > 0 {
			powerSel--
		}
	case 0x51: // Down
		if powerSel < len(powerRows)-1 {
			powerSel++
		}
	case 0x28: // Enter
		dismissPowerMenu()
		runPowerRow(powerSel)
	}
	return true
}

// runPowerRow dispatches one row — the pointer click and the Enter path
// share it so a highlighted row and a clicked row mean the same thing.
func runPowerRow(i int) {
	switch i {
	case 1:
		requestSnapshot()
	default:
		requestSuspend()
	}
}

// The vsock-ctl seam is a test seam too — host tests pin the verdict
// markers without a guest.
var vsockCtlRequest = func(verb, name string, code []byte) int64 {
	return vi.VsockCtl(verb, name, code)
}

// suspendVerdict runs the one ctl session and names its outcome: "ok"
// on the host's accept, the refusal's ADR 0056 code otherwise. Pure
// over the vsockCtlRequest seam — host tests pin every branch.
func suspendVerdict() string {
	var code [40]byte
	r := vsockCtlRequest("suspend", "", code[:])
	return ctlVerdict(r, code[:])
}

// requestSuspend sends the seat's Suspend verb down the ctl channel and
// names the verdict — the whole user-visible power operation.
func requestSuspend() {
	vi.ConsoleLine(MarkerSuspendRequest)
	vi.ConsoleLine(MarkerSuspendVerdict + suspendVerdict())
}

// powerFocus is the tab-focus seam (the execApp / vsockCtlRequest
// pattern): focusHosted on the guest, a recorder in tests.
var powerFocus = focusHosted

// requestSnapshot is the Snapshot row: focus the running snapshot
// window when one is already on the strip — the manager's verbs are
// process-wide, so a second instance is never the honest answer — else
// exec the app. The marker names which landed.
func requestSnapshot() {
	for i := 0; i < tabs.Count(); i++ {
		if t := tabs.At(i); t.Bin == gosnapBin {
			if powerFocus(t.ID) {
				vi.ConsoleLine(MarkerPowerSnapshot + "focus id=" + vi.Itoa64(int64(t.ID)))
			} else {
				vi.ConsoleLine(MarkerPowerSnapshot + "focus refused id=" + vi.Itoa64(int64(t.ID)))
			}
			return
		}
	}
	if _, err := execApp(gosnapBin); err != nil {
		vi.ConsoleLine(MarkerPowerSnapshot + "exec refused")
		seatRefusalErr(err, "exec "+gosnapBin, gosnapBin)
		return
	}
	vi.ConsoleLine(MarkerPowerSnapshot + "exec " + gosnapBin)
}

// --- paint --------------------------------------------------------------

// paintPowerButton paints the PWR plate; the menu itself is painted by
// compositeTick so it sits above the rail but under the toasts.
func paintPowerButton(scan []byte, width, height int) int {
	x, y, w, h := powerBtnRect(width, height)
	if w <= 0 || len(scan)/4/width < y+h {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	face := tok.ChromeBg
	if powerBtnHover || powerMenuOpen {
		face = tok.BtnHover
	}
	n := seatPlate(c, plate, radiusControl, tok.Accent, face)
	clip := plate.Inset(1)
	seatText(c, clip, x+3, y+chromePad, seatSmallPx, "PWR", tok.Ink)
	return n
}

// paintPowerMenu paints the open menu's plate and its rows — the
// keyboard highlight on powerSel, each row on the same geometry
// powerMenuRowAt answers.
func paintPowerMenu(scan []byte, width, height int) int {
	if !powerMenuOpen {
		return 0
	}
	x, y, w, h := powerMenuRect(width, height)
	if w <= 0 || len(scan)/4/width < y+h {
		return 0
	}
	c := seatCanvas(scan, width, height)
	if c == nil {
		return 0
	}
	tok := theme.Current
	plate := widgets.Rect{X: x, Y: y, W: w, H: h}
	n := seatPlate(c, plate, radiusControl, tok.Accent, tok.Surface)
	draw.StrokeRoundedRect(c, plate, radiusControl, tok.BorderW, draw.Opaque(tok.Rule))
	clip := plate.Inset(tok.BorderW)
	for i, row := range powerRows {
		rr := widgets.Rect{X: x, Y: y + 3 + i*powerRowH, W: w, H: powerRowH}
		if i == powerSel {
			c.FillRect(rr.Inset(2), draw.Opaque(tok.Selection))
		}
		seatText(c, clip, x+10, rr.Y+6, seatTextPx, row, tok.Ink)
	}
	return n
}
