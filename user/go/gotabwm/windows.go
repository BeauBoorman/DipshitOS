// GOTABWM.ELF — M57b (issue #1317): the seat manages its OWN Go windows.
//
// M57a put the seat on slot 65 and composited a blank desktop. This card adds
// the window lifecycle the seat owns as a CLIENT of its own render server:
//
//	vi.WinOpen                (12)    -> gotabwm: win open id=<n>
//	vi.WmctlSetWindowChrome   (65/2)  -> gotabwm: win chrome
//	vi.WmctlSetWindowRect     (65/2)  -> gotabwm: win rect x=<x> y=<y> w=<w> h=<h>
//	WIN_FOCUS (kind 6, routed by the kernel on open) -> gotabwm: win focus
//	WIN_BLUR  (kind 7, routed when another window takes focus) -> win blur
//	vi.WmctlWinClose          (65/13) -> gotabwm: win close
//	vi.WinQuery fails after the close  -> gotabwm: win gone
//	a window left open at exit         -> gotabwm: win leak id=<n>
//
// Every marker is printed only after its syscall/step SUCCEEDED, so the marker
// chain is the syscall chain (the M57a discipline). The kernel proves the rest:
// it CLAMPS the WM's proposed rect (WM proposes, kernel clamps to the scanout),
// it routes focus as real WIN_FOCUS/WIN_BLUR events, and its exit seam tears
// down a window the process never closed (M52 client-death discipline — no
// zombie window, no residue). No libc, no POSIX, no cgo: only the ADR 0007
// `svc #0` seam through virelai/vi.
package main

import (
	"unsafe"

	"virelai/theme"
	"virelai/vi"
)

// The window-lifecycle marker lines the class-B gate greps. Exported so
// windows_test.go pins the exact shapes (a drift is a host-test failure, not a
// live run that silently asserts nothing).
const (
	MarkerWinOpen   = "gotabwm: win open id="
	MarkerWinChrome = "gotabwm: win chrome"
	MarkerWinRect   = "gotabwm: win rect "
	MarkerWinFocus  = "gotabwm: win focus"
	MarkerWinBlur   = "gotabwm: win blur"
	MarkerWinClose  = "gotabwm: win close"
	MarkerWinGone   = "gotabwm: win gone"
	MarkerWinLeak   = "gotabwm: win leak id="
)

// The Go window the seat opens, and the position it PROPOSES. The proposal is
// deliberately OFF-SCANOUT (the framebuffer is 1280x720) so the kernel's clamp
// is observable: the reported rect is the CLAMPED one, never the proposed one.
// The size is carried through unchanged, so the kernel's move-only path applies
// (driving_award.reflow) and the clamp is proved without asking the pool to
// grow the back-buffer.
const (
	winX = 24
	winY = 16
	winW = 256
	winH = 192

	propX = 4000
	propY = 3000
	propW = winW
	propH = winH
)

// The client-death probe: a second window the process deliberately NEVER
// closes. The kernel's exit seam (driving_award.close_owner, reached from
// scheduler exit) must tear it down, so the post-exit registry is back to its
// pre-program count — no zombie window.
const (
	leakX = 8
	leakY = 8
	leakW = 96
	leakH = 64
)

// scratchVA is the page the chrome descriptor lives on. uaccess.copy_in reads
// through the caller's own user page map, and a Go heap/stack buffer is not
// guaranteed mapped for EL1 (ADR 0026 D8), so the descriptor goes on an
// explicitly mapped page — the same reason gowin.go hints its back-buffer.
// 10 GiB is clear of the sbrk heap and of the randomized EL0 stack band.
const scratchVA = 0x0000_0002_8000_0000

// maxWinEvents bounds every window-phase wait so a boot can never hang.
const maxWinEvents = 200

// The menu has its own ordinary window, never the lifecycle/death probe.
// WinOpen and taskbar focus change the kernel's focused key/tty destination;
// kind-21 WM_KEY still reaches the seat. No event-consumption ABI is implied.
var (
	openInputSink = vi.WinOpen
	queryWindow   = vi.WinQuery
	openBlurProbe = vi.WinOpen
)

// The demo deliberately waits for the harness to move focus. A normal boot
// has no harness: opening a temporary owned window supplies the real blur
// event, without a monitor command or a boot-default override.
func beginProbeBlur() (int, bool) {
	if demoMode {
		return -1, true
	}
	id, r := openBlurProbe(0, 0, 1, 1)
	return id, r >= 0
}

func acquireLauncherFocus() bool {
	id, r := openInputSink(launchX, launchY, launchW, uint32(launch.panelH()))
	if r < 0 {
		launch.err = "Input sink unavailable"
		return false
	}
	launch.sink = uint32(id)
	if !ensureLauncherFocus() {
		_ = releaseLauncherFocus(false)
		return false
	}
	vi.ConsoleLine("gotabwm: launcher focus sink=" + vi.Itoa64(int64(id)))
	return true
}

func ensureLauncherFocus() bool {
	if launch.sink == 0 {
		return false
	}
	st, r := queryWindow(int(launch.sink))
	if r < 0 {
		launch.err = "Input sink closed"
		return false
	}
	if st[5] == 0 && focusRaise(launch.sink) != 0 {
		launch.err = "Input focus unavailable"
		return false
	}
	return true
}

func releaseLauncherFocus(restore bool) bool {
	if launch.sink != 0 {
		if closeWin(launch.sink) != 0 {
			if _, r := queryWindow(int(launch.sink)); r >= 0 {
				launch.err = "Input sink close failed"
				return false
			}
		}
		launch.sink = 0
	}
	menuPixels = windowPixels{}
	if restore {
		// WinQuery is owner-only: use the existing WM focus seam for clients,
		// not a query that would reject every app owned by another process.
		// Release mirrors remove dead/reused ids; an EINVAL focus catches a
		// death before its mirror was drained.
		id := launch.prior
		if tabs.index(id) < 0 || id >= sessionIDBase {
			id = 0
		}
		restored := false
		if id != 0 {
			r := focusRaise(id)
			restored = r == 0
			if r == -vi.ErrEINVAL {
				_ = tabs.CloseTab(id)
				id = 0
			}
		}
		if id == 0 {
			for i := 0; i < tabs.Count(); i++ {
				candidate := tabs.At(i).ID
				if candidate >= sessionIDBase {
					continue
				}
				if focusRaise(candidate) == 0 {
					id = candidate
					restored = true
					break
				}
			}
		}
		if restored {
			_ = tabs.FocusTab(id)
			hostedApp = id
			vi.ConsoleLine("gotabwm: launcher restore id=" + vi.Itoa64(int64(id)))
		}
	}
	launch.prior = 0
	return true
}

// Unmigrated app windows are kernel-blitted on the following tick. Keep the
// button and menu in ordinary seat-owned back buffers too, rather than losing
// their direct scanout paint under the next app blit. Raising is not focusing.
type windowPixels struct {
	id     int
	x, y   int
	w, h   int
	pixels []uint32
}

var buttonPixels, menuPixels, powerPixels windowPixels
var chromeScratch []byte
var writeWindowChrome = vi.WmctlSetWindowChrome

func setSeatWindowChrome(id int) bool {
	return setWindowChrome(id, false)
}

func setHostedWindowChrome(id uint32) bool {
	return setWindowChrome(int(id), true)
}

func setWindowChrome(id int, hosted bool) bool {
	if chromeScratch == nil {
		var err error
		chromeScratch, err = vi.MmapHint(scratchVA+vi.PageSize, vi.PageSize,
			vi.ProtRead|vi.ProtWrite, vi.MapAnonymous)
		if err != nil {
			vi.ConsoleLine("gotabwm: chrome mmap failed " + err.Error())
			return false
		}
	}
	desc := chromeScratch[:vi.ChromeDescBytes]
	if hosted {
		for i := range desc {
			desc[i] = 0
		}
	} else {
		fillBorderChrome(desc)
	}
	if c := writeWindowChrome(uint32(id), desc); c != 0 {
		vi.ConsoleLine("gotabwm: chrome refuse id=" + vi.Itoa64(int64(id)) +
			" r=" + vi.Itoa64(c))
		return false
	}
	return true
}

// upload emits only changed, same-color horizontal runs, in batched fills.
// The source is the very same painted scanout used by layout/hit tests.
func (p *windowPixels) upload(scan []byte, width, x, y, w, h int, rect func(int, uint32, uint32, uint32, uint32, uint32)) {
	if width <= 0 || x < 0 || y < 0 || w <= 0 || h <= 0 ||
		x+w > width || len(scan)/4/width < y+h {
		return
	}
	fresh := p.w != w || p.h != h || len(p.pixels) != w*h
	if fresh {
		p.pixels = make([]uint32, w*h)
	}
	p.x, p.y, p.w, p.h = x, y, w, h
	src := unsafe.Slice((*uint32)(unsafe.Pointer(&scan[0])), len(scan)/4)
	for row := 0; row < h; row++ {
		for col := 0; col < w; {
			at := row*w + col
			color := src[(y+row)*width+x+col] & 0xffffff
			if !fresh && p.pixels[at] == color {
				col++
				continue
			}
			start := col
			for col < w && src[(y+row)*width+x+col]&0xffffff == color {
				p.pixels[row*w+col] = color
				col++
			}
			rect(p.id, uint32(start), uint32(row), uint32(col-start), 1, color)
		}
	}
}

func syncSeatChrome(scan []byte) {
	x, y, w, h := godMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
	// M115d (#2463): the PWR button lives on the same chrome band — the
	// chrome window's upload region widens to cover it so a hosted tab
	// cannot hide the power affordance either.
	if px, _, pw, _ := powerBtnRect(vi.ScanoutWidth, vi.ScanoutHeight); pw > 0 && px+pw > x+w {
		w = px + pw - x
	}
	if buttonPixels.id == 0 {
		// Opening an ordinary window focuses it. Restore the live hosted
		// destination immediately, including the menu sink if it is open.
		focus := hostedApp
		if launch.open {
			focus = launch.sink
		}
		id, r := vi.WinOpen(uint32(x), uint32(y), uint32(w), uint32(h))
		if r < 0 {
			launch.err = "Apps button unavailable"
			return
		}
		ok := setSeatWindowChrome(id)
		if focus != 0 && focus < sessionIDBase && focusRaise(focus) != 0 {
			ok = false
		}
		if !ok {
			_ = vi.WinClose(id)
			launch.err = "Apps button focus unavailable"
			return
		}
		buttonPixels.id = id
	}
	var fills vi.Filler
	buttonPixels.upload(scan, vi.ScanoutWidth, x, y, w, h, fills.Rect)
	_ = vi.WinRaise(buttonPixels.id)
	if launch.open && launch.sink != 0 {
		h = launch.panelH()
		if menuPixels.id != int(launch.sink) {
			menuPixels = windowPixels{id: int(launch.sink)}
			if !setSeatWindowChrome(menuPixels.id) {
				launch.err = "Menu chrome unavailable"
				return
			}
		}
		if menuPixels.w != launchW || menuPixels.h != h {
			if vi.WmctlSetWindowRect(launch.sink, launchX, launchY, launchW, uint32(h)) != 0 {
				launch.err = "Menu layout unavailable"
				return
			}
		}
		menuPixels.upload(scan, vi.ScanoutWidth, launchX, launchY, launchW, h, fills.Rect)
		_ = vi.WinRaise(menuPixels.id)
	}
	// M115d (#2463): the open power menu uploads its panel to its own
	// sink window, the same seat-chrome discipline as menuPixels.
	if powerMenuOpen && powerSink != 0 {
		px, py, pw, ph := powerMenuRect(vi.ScanoutWidth, vi.ScanoutHeight)
		if powerPixels.id != int(powerSink) {
			powerPixels = windowPixels{id: int(powerSink)}
			if !setSeatWindowChrome(powerPixels.id) {
				return
			}
		}
		powerPixels.upload(scan, vi.ScanoutWidth, px, py, pw, ph, fills.Rect)
		_ = vi.WinRaise(powerPixels.id)
	}
	fills.Flush()
}

func launcherWindowEvent(e vi.Event) {
	if e.Kind != vi.EvWmWindow || e.Flags&(1<<13) == 0 {
		return
	}
	id := uint32(e.Flags & 0xff)
	if int(id) == buttonPixels.id {
		if _, r := queryWindow(int(id)); r < 0 {
			buttonPixels = windowPixels{}
		}
	}
	if id == launch.prior {
		launch.prior = 0
	}
	// #2870: the mirror carries an 8-bit id and no generation, so a death
	// mirror can drain after the kernel already reissued the id to a live
	// window. Nothing the mirror would trigger — the row close or the
	// binding drop — may run while the successor is provably alive.
	stale := deathMirrorStale(id)
	if !stale && tabs.index(id) >= 0 {
		// M125f (#2591): a released tab the seat never closed is the
		// kernel's teardown of a dead process. Its bound owner's exit
		// status discriminates the crash receipt (nonzero) from a clean
		// quit (0) — the crash arm runs while the row is still live so
		// writeSession records it for the next boot's re-exec.
		pid, status, crashed := seatCrashStatus(id)
		if crashed {
			crashLog(MarkerCrash + "id=" + vi.Itoa64(int64(id)) +
				" pid=" + vi.Itoa64(int64(pid)) +
				" status=" + vi.Itoa64(int64(status)))
			crashSave()
		}
		// M137c: the dying window may belong to a dormant space.
		_ = closeTabAcrossSpaces(id)
		if crashed {
			// The restart runs on the next composite tick, off this
			// event's teardown path — the just-saved machine image and
			// the in-flight reap are both settled by then.
			crashRestartPending = true
		}
		syncHostedFromStrip()
	}
	if !stale {
		// M97g-F2 (#2080): the released window's binding and pending
		// challenge die with it, tab or not — a reused id must not
		// inherit a dead token. A stale mirror's "release" names a
		// predecessor: the live binding belongs to the successor, not
		// the dead window, so it survives untouched.
		dropRpcBinding(id)
	}
	// A delayed mirror can name a reused id. Only a failed query proves
	// the current sink is gone; ordinary sink KEY_DOWN/BLUR events drain
	// on the same seat queue and are intentionally ignored.
	if id == launch.sink {
		if _, r := queryWindow(int(id)); r < 0 {
			launch.sink = 0
			dismissLauncher()
		}
	}
}

// deathMirrorStale reports whether a released registry mirror naming id is
// STALE: it was minted for a window that left the registry, but the kernel
// has since reissued the id to a live successor — the mirror's side effects
// must not run against the successor's row, binding, or geometry. The
// mirror carries no generation to disambiguate, so the seat proves life
// with the two cross-owner facts it can read: a user window still answers
// at id (wmctl cmd 14 — sys_win_query is owner-restricted and cannot ask),
// and the row's bound owner pid is still running (the M97g-F2 bind proved
// that pid owns the current window at id). Both live means the mirror names
// a predecessor. Observed 2026-10-21 (#2870): the launcher focus sink's
// death mirror drained ~33k serial lines after GOSET re-bound its reissued
// id — the silent close removed GOSET's live row and the recorded entry
// poisoned the reopen LIFO (`reopen missing Settings`).
//
// A live window whose bound owner is dead still counts as a real death:
// the row's own window died with its owner and the live window is an
// unbound successor, which binds and declares fresh. The residual race is
// a bound owner that closes its window but keeps running while the id
// passes to a window that never binds — that reads as live, and the row
// survives until the successor declares or a later mirror proves it dead.
// An unbound row cannot be told apart this way and keeps the old close.
func deathMirrorStale(id uint32) bool {
	if id > 255 {
		return false
	}
	if _, ok := readWindowName(uint8(id)); !ok {
		return false
	}
	pid := rpcBindings[id].pid
	return pid != 0 && procsAlive(pid)
}

// runWindowPhase drives the seat's own window lifecycle end to end. It returns
// whether every step succeeded; main turns a false into a distinct exit code,
// so a failed gate points at one step rather than a mystery.
func runWindowPhase() bool {
	// The chrome descriptor's backing page (see scratchVA).
	scratch, err := vi.MmapHint(scratchVA, vi.PageSize, vi.ProtRead|vi.ProtWrite, vi.MapAnonymous)
	if err != nil {
		vi.ConsoleLine("gotabwm: win scratch failed " + err.Error())
		return false
	}
	desc := scratch[:vi.ChromeDescBytes]
	fillBorderChrome(desc)

	// 1. Open the seat's own Go window.
	id, r := vi.WinOpen(winX, winY, winW, winH)
	if r < 0 {
		vi.ConsoleLine("gotabwm: win open failed " + vi.Itoa64(r))
		return false
	}
	vi.ConsoleLine(MarkerWinOpen + vi.Itoa64(int64(id)))

	// 2. Submit a chrome descriptor through the WM seam.
	if c := vi.WmctlSetWindowChrome(uint32(id), desc); c != 0 {
		vi.ConsoleLine("gotabwm: win chrome failed " + vi.Itoa64(c))
		return false
	}
	vi.ConsoleLine(MarkerWinChrome)

	// 3. Propose an oversized rect; read back what the KERNEL decided.
	if c := vi.WmctlSetWindowRect(uint32(id), propX, propY, propW, propH); c != 0 {
		vi.ConsoleLine("gotabwm: win rect failed " + vi.Itoa64(c))
		return false
	}
	st, q := vi.WinQuery(id)
	if q < 0 {
		vi.ConsoleLine("gotabwm: win query failed " + vi.Itoa64(q))
		return false
	}
	vi.ConsoleLine(MarkerWinRect +
		"x=" + vi.Itoa64(int64(st[0])) +
		" y=" + vi.Itoa64(int64(st[1])) +
		" w=" + vi.Itoa64(int64(st[2])) +
		" h=" + vi.Itoa64(int64(st[3])))

	// 4. Focus gain: the kernel routed WIN_FOCUS when the window opened.
	if !waitKind(vi.EvWinFocus) {
		vi.ConsoleLine("gotabwm: win focus timeout")
		return false
	}
	vi.ConsoleLine(MarkerWinFocus)

	// 5. Focus loss: the demo harness or a live boot's temporary owned
	//    window moves focus; the kernel routes the real WIN_BLUR.
	blurID, blurOK := beginProbeBlur()
	if !blurOK {
		vi.ConsoleLine("gotabwm: win blur open failed")
		return false
	}
	if blurID >= 0 {
		defer vi.WinClose(blurID)
	}
	if !waitKind(vi.EvWinBlur) {
		vi.ConsoleLine("gotabwm: win blur timeout")
		return false
	}
	vi.ConsoleLine(MarkerWinBlur)

	// 6. Close THROUGH the WM seam: the kernel runs its own release, so the
	//    owner (this process) receives the real WIN_CLOSE.
	if c := vi.WmctlWinClose(uint32(id)); c != 0 {
		vi.ConsoleLine("gotabwm: win close failed " + vi.Itoa64(c))
		return false
	}
	if !waitKind(vi.EvWinClose) {
		vi.ConsoleLine("gotabwm: win close timeout")
		return false
	}
	vi.ConsoleLine(MarkerWinClose)

	// 7. No residue: the released window is gone from the registry.
	if _, q := vi.WinQuery(id); q >= 0 {
		vi.ConsoleLine("gotabwm: win gone FAILED")
		return false
	}
	vi.ConsoleLine(MarkerWinGone)

	// 8. Client-death probe (M52): open a window and NEVER close it. The
	//    kernel's exit seam must tear it down when this process exits.
	lid, lr := vi.WinOpen(leakX, leakY, leakW, leakH)
	if lr < 0 {
		vi.ConsoleLine("gotabwm: win leak open failed " + vi.Itoa64(lr))
		return false
	}
	vi.ConsoleLine(MarkerWinLeak + vi.Itoa64(int64(lid)))
	return true
}

// waitKind drains the caller's event queue until an event of `kind` arrives,
// bounded so a boot can never hang. Non-matching events (the kind-18
// COMPOSITE_TICK stream, WIN_RESIZE from the clamp) are consumed and dropped.
func waitKind(kind uint16) bool {
	for i := 0; i < maxWinEvents; i++ {
		ev, ok := vi.PollEvent()
		if ok {
			if ev.Kind == kind {
				return true
			}
			continue
		}
		vi.Sleep(1)
	}
	return false
}

// fillBorderChrome writes the frozen 40-byte v1 chrome descriptor: kind =
// chrome_border (0x01), flags = 0, then the eight colour words. It is built
// with explicit little-endian stores so the wire layout does not depend on the
// compiler's struct padding.
func fillBorderChrome(desc []byte) {
	for i := range desc {
		desc[i] = 0
	}
	tok := theme.Current
	putU32LE(desc[0:], 0x01)        // kind: chrome_border for seat-owned windows
	putU32LE(desc[4:], 0x00)        // flags: no reserved bits set
	putU32LE(desc[8:], tok.Accent)  // border_rgb
	putU32LE(desc[12:], tok.Border) // border_unfocus_rgb
	putU32LE(desc[16:], tok.Bg)     // title_bg_rgb
	putU32LE(desc[20:], tok.Text)   // title_fg_rgb
	putU32LE(desc[24:], tok.Accent) // ring_rgb
	putU32LE(desc[28:], tok.Danger) // close_rgb
	putU32LE(desc[32:], tok.Muted)  // min_rgb
	putU32LE(desc[36:], tok.Muted)  // pin_rgb
}

// putU32LE stores v little-endian at b (b must have at least 4 bytes).
func putU32LE(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}
