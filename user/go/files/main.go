//go:build virelai || fileman

// Command files is GOFILES.ELF: the M74a (issue #1644) file manager TUI —
// a Bubble Tea model over the bound /dev/tty inside Zig TABWM (evolved from
// the M58a widget app, same identity, same manifest row).
//
// It does not run Bubble Tea's host Program loop: the Virelai port has no
// POSIX tty or signals. Key bytes come from the kernel's bound /dev/tty
// queue (CSI sequences decoded by virelai/rss/keys, ?1006 SGR mouse reports
// split off first) and View's ANSI frame goes back into that bound tty.
//
// Marker discipline: a frame's markers are flushed only AFTER that frame is
// painted and yielded, so every `gofiles: …` line the go-fileman gate waits
// on describes a screen that already exists — the screenshot barrier can
// never race the paint.
package main

import (
	"strings"

	tea "charm.land/bubbletea/v2"

	"virelai/rss/keys"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "GOFILES.ELF"
	appTitle = "Files"
	natW     = 512
	natH     = 384

	ttyPath = "/dev/tty"
)

// paint writes one frame into the bound tty. A tty write marks the window
// dirty; callers yield once before their markers so the markers describe a
// painted frame. A two-pane frame is many KiB and sys_file_write refuses
// count > 2048 with -ENOSPC, so the frame goes through vi.FileWriteAll —
// the chunked-by-confirmed-count primitive term/sh use (M66a). Observed
// failing on the first gate run: one big FileWrite returned -5 and the
// app honestly exited status=4 before its first marker.
func paint(fd uint32, m model) bool {
	data := []byte(m.View().Content)
	n, rc := vi.FileWriteAll(fd, data)
	return rc >= 0 && n == len(data)
}

// execApp is the exec seam (M81b #1762). It is vi.Exec in the guest; the
// indirection exists so the launch path is one named call the model tests can
// reason about, and so a refusal marker can never be printed for a launch
// that did not happen.
var execApp = vi.Exec

// drainLaunch runs the exec the model queued for this frame, if any, and
// prints the OUTCOME marker. It rides the same post-paint barrier as the
// markers: the frame that says "opening …" is already on screen, and the
// launched/refused line follows the syscall that decided it. A launch that
// the kernel refuses (no such binary, bad argv) is named, never swallowed —
// the file manager is the only place that knows which app it meant.
func drainLaunch(m *model) {
	r, ok := m.takeLaunch()
	if !ok {
		return
	}
	// The manifest's argv= tail rides ahead of the file path (M124d): the
	// exec argv is [fixed args…, path], one slot always kept for the file.
	argv := append(append([]string{}, r.args...), r.path)
	pid, err := execApp(r.bin, argv...)
	if err != nil {
		vi.ConsoleLine(markerOpenLaunchNo + baseName(r.path) +
			" handler=" + r.bin + " err=" + err.Error())
		// M123d (#2578): the refusal also stands inside the app — the
		// shared error banner takes the status row with Copy Error and
		// dismiss. The raise is post-paint, so bannerFresh makes the
		// caller paint the strip's own frame next.
		m.raiseExecRefusal(r.bin, err)
		return
	}
	vi.ConsoleLine(markerOpenLaunched + baseName(r.path) +
		" handler=" + r.bin + " pid=" + vi.Itoa64(pid))
}

// flush prints the model's queued serial markers in order, then raises the
// toast the model queued for this frame (M79k #1720). The notify rides the
// SAME post-paint barrier as the markers: a toast that names a completed
// copy must not appear before the listing that shows the copy, and the
// seat's own `gotabwm: notify id=` line must not land before the app's
// `gofiles: pasted …` line it is about. The ack is printed either way, so
// "the seat never heard about it" is a distinguishable outcome.
func flush(m *model, ta *tabapp.TabApp) {
	for _, ln := range m.drain() {
		vi.ConsoleLine(ln)
	}
	if text := m.takeNotify(); text != "" {
		if ta.Notify(text) {
			vi.ConsoleLine(markerNotify + text)
		} else {
			vi.ConsoleLine(markerNotifyNo + text)
		}
	}
}

// settle yields then prints the rename-settle barrier: the screenshot at
// `gofiles: renamed …` has this long to capture before the gate's close
// script (triggered by this marker) tears the window down.
func settle(m *model) {
	if !m.renamedBatch {
		return
	}
	m.renamedBatch = false
	vi.Sleep(50) // hundreds of ms: the screenshot at the rename marker finishes first
	vi.ConsoleLine(markerSettled)
}

// settleBanner paints the frame a post-paint banner raise is owed
// (M123d #2578): drainLaunch's exec outcome lands after the batch's own
// paint, so without this the strip would wait for the user's next event
// to appear. The repaint reuses the batch barrier — paint, yield, flush —
// so the `gofiles: banner …` marker still follows the frame that shows it.
func settleBanner(m *model, fd uint32, ta *tabapp.TabApp) bool {
	if !m.bannerFresh {
		return true
	}
	m.bannerFresh = false
	if !paint(fd, *m) {
		return false
	}
	vi.Sleep(1)
	flush(m, ta)
	return true
}

// leaseFixture stamps a FOREIGN live lease record on the target path before
// the TUI starts — the M81d drill's other side: a file that some other
// writer holds while GOFILES tries to mutate it. The stamp is one no run
// outlives (the year 2286) and pid=0, so the fixture is timing-proof; the
// record text is the on-share VLEASE1 convention, hand-rendered the way a
// foreign writer would (the GOSELF --panic-receipt-fixture precedent: a
// named fixture verb, not a hidden side door).
func leaseFixture(target string) {
	lp := vi.LeasePathFor(target)
	if lp == "" {
		vi.ConsoleLine("gofiles: lease fixture bad path")
		return
	}
	// The record's directory may not exist yet; the MODE_DIR create
	// triple's EEXIST (-9) is fine.
	h, rc := vi.FileOpen(vi.LeaseDir, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc < 0 && rc != -9 {
		vi.ConsoleLine("gofiles: lease fixture rc=" + vi.Itoa64(rc))
		return
	}
	if rc >= 0 {
		vi.FileClose(uint32(h))
	}
	rec := "VLEASE1\npid=0\nts=9999999999\ntoken=fedcba9876543210\npath=" + target + "\n"
	if rc := vi.WriteFileSafe(lp, []byte(rec)); rc < 0 {
		vi.ConsoleLine("gofiles: lease fixture rc=" + vi.Itoa64(rc))
		return
	}
	vi.ConsoleLine("gofiles: lease fixture " + target)
}

func main() {
	// M124b (#2581): `pick [dir]` runs the shared appkit.FilePicker over
	// the bound tty instead of the file-manager model — GOFILES's pick
	// mode IS appkit.FilePicker, rendered ANSI.
	pickOn := false
	pickArg := ""
	for i, a := range vi.Args() {
		if strings.HasPrefix(a, "--lease-fixture=") {
			leaseFixture(strings.TrimPrefix(a, "--lease-fixture="))
		}
		if i == 0 {
			continue
		}
		if a == "pick" || a == "--pick" {
			pickOn = true
			continue
		}
		if pickOn && pickArg == "" && strings.HasPrefix(a, "/host") {
			pickArg = a
		}
	}
	// M125c (#2588): the state hooks. SaveState reads the live model (the
	// closure captures the variable, so an ask always serializes the
	// current session) and prints its own marker — a save is an action,
	// not a frame. RestoreState fires inside tabapp.Init, before the model
	// exists: it only decodes; the apply lands once the first listing is
	// in and the envelope's appver has been checked below.
	var m model
	var restored filesState
	var restoredOK bool
	ta := tabapp.Init(tabapp.Config{
		Name: appName, Title: appTitle, X: 32, Y: 32, W: natW, H: natH,
		StateVersion: stateFmtVer,
		SaveState:    func() []byte { return m.encodeState() },
		RestoreState: func(b []byte) {
			restored, restoredOK = decodeState(b)
		},
		// M124a-2 (#2677): the drag source. A held move off a pressed row
		// calls BeginDrag; the seat calls DragSource for the payload and
		// reports the outcome back through DragEnd. GOFILES is a source
		// only — nothing opens= it, so DropTarget stays nil.
		DragSource: func() (string, []byte, bool) {
			return m.dragOffer()
		},
		DragEnd: func(delivered bool, peer uint32) {
			m.dragOn = false
			if delivered {
				vi.ConsoleLine(markerDragEnd + "delivered win=" + vi.Itoa64(int64(peer)))
			} else {
				vi.ConsoleLine(markerDragEnd + "cancelled")
			}
		},
		// M121e (#2568): the undo hook — the tab-facing undo answer the
		// seat's ctrl+z names in its `undo id=` route. On this tty-bound
		// surface the chord itself arrives as the 0x1a control byte and
		// the model's KeyCtrlZ case calls the same restoreLatest — one
		// undo entry, no second binding.
		HandleUndo: func() bool {
			m.restoreLatest()
			return true
		},
	})
	if ta == nil {
		vi.ConsoleLine("gofiles: error open -1")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine(markerDeclareNo)
	}

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine("gofiles: no /dev/tty")
		ta.CloseAndExit(2)
	}
	fd := uint32(h)
	if vi.TtyAttachWindow(ta.Win) != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine("gofiles: attach failed")
		ta.CloseAndExit(3)
	}
	vi.ConsoleLine(markerAttach)
	// M73i (#1635): enable xterm mouse reporting — ?1000 press/release
	// edges, ?1006 SGR encoding — so rows are clickable; M124a-2 (#2677)
	// adds ?1002 button-motion so a held move off a pressed row can arm
	// the seat-mediated drag. The kernel tracks the modes per screen
	// (never painted).
	if _, rcw := vi.FileWrite(fd, []byte("\x1b[?1000h\x1b[?1002h\x1b[?1006h")); rcw < 0 {
		vi.ConsoleLine("gofiles: mouse enable failed")
	}

	cols, rows := gridOf(ta.W, ta.H)
	if pickOn {
		start := pickArg
		if start == "" {
			start = startPath()
		}
		pickMain(fd, ta, start, cols, rows)
	}
	// M125c (#2588): a re-exec'd or reopened tab may have delivered a
	// stored blob. The envelope's appver is the app's own stale check —
	// a blob saved under a different format version is refused by name,
	// never silently misread. A saved cwd that no longer exists walks up
	// to the nearest existing parent.
	start := startPath()
	fellBack := false
	if ta.Restored && ta.RestoredVersion == stateFmtVer && restoredOK {
		resolved, fell := resolveStatePath(restored.path)
		start = resolved
		fellBack = fell
	}
	m = newModel(start, cols, rows)
	m.winID = uint32(ta.Win) // M155b: the batch's kind-22 progress row reports for this window
	switch {
	case ta.Restored && ta.RestoredVersion == stateFmtVer && restoredOK:
		m.applyState(restored)
		if fellBack {
			m.emit(markerStateCwd + restored.path + " -> " + m.path)
		}
		m.emit(markerStateRestore + m.path +
			" sel=" + vi.Itoa64(int64(m.sel)) +
			" top=" + vi.Itoa64(int64(m.top)) +
			" view=" + vi.Itoa64(int64(m.view)) +
			" sort=" + vi.Itoa64(int64(m.sort)))
	case ta.Restored && ta.RestoredVersion != stateFmtVer:
		m.emit(markerStateRefused + "ver=" + vi.Itoa64(int64(ta.RestoredVersion)))
	case ta.Restored:
		m.emit(markerStateRefused + "bad blob")
	}
	if !paint(fd, m) {
		shutdown(ta, fd, 4)
	}
	vi.Sleep(2)
	vi.ConsoleLine(markerPainted)
	flush(&m, ta)
	vi.ConsoleLine(markerPresent)
	// M79e (#1708): announce where this tab starts. Without a first
	// declare the seat has no history and a back-step has nowhere to go.
	// Declared AFTER the model exists, so the path is the real one; the
	// marker follows the request, not the intent.
	ta.DeclareNav(m.path)
	vi.ConsoleLine(markerNavDeclare + m.path)
	vi.ConsoleLine(markerReady)
	declared := m.path

	// M81f (#1766): the change feed is polled from the IDLE branch only,
	// every watchEvery-th quiet pass — a listing is one queue-5 round trip,
	// and while the user is acting the app already refreshes itself.
	const watchEvery = 5
	idlePasses := 0

	var in [64]byte
	for {
		// M124a-2: seat drag frames for this window — the DragEnd receipt
		// or cancel lands here, one poll per loop turn like StateAsk.
		ta.PollDrag()

		// Keys and mouse reports: the tty read is non-blocking (0 when
		// the queue is empty).
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			if !feed(&m, fd, in[:n], ta) {
				if m.quit {
					shutdown(ta, fd, 0)
				}
				shutdown(ta, fd, 4)
			}
		}

		// Window events: closed ends the session, resize re-derives the
		// grid best-effort (M73j #1636 — a queried tty winsize — is the
		// card that makes this exact after a drag).
		progress := n > 0
		for {
			ev, result, ok := vi.PollEventRaw()
			if !ok {
				if result < 0 {
					shutdown(ta, fd, 7)
				}
				break
			}
			progress = true
			switch ta.Dispatch(ev) {
			case tabapp.ActionClosed:
				shutdown(ta, fd, 0)
			case tabapp.ActionResized:
				cols, rows := gridOf(ta.W, ta.H)
				m.setSize(cols, rows)
				if !paint(fd, m) {
					shutdown(ta, fd, 4)
				}
				vi.Sleep(2)
				flush(&m, ta)
				vi.ConsoleLine(markerResized + vi.Itoa64(int64(cols)) +
					" h=" + vi.Itoa64(int64(rows)))
				vi.ConsoleLine(markerRepaint)
			}
		}

		// M125c (#2588): the seat's save_state ask is mailbox traffic,
		// not an input event — answer it once per pass so a snapshot or
		// tab-close ask is serviced before the window dies. The marker
		// prints only on an acked handoff — "the seat stored the blob" —
		// never on silence or a refused post. The ask polls AFTER the
		// input drains: the seat writes the user's keys to the tty before
		// queuing the ask, so a save answers the state those keys
		// produced, not the stale pre-key frame.
		if ta.PollStateAsk() {
			vi.ConsoleLine(markerStateSave + m.path +
				" sel=" + vi.Itoa64(int64(m.sel)) +
				" top=" + vi.Itoa64(int64(m.top)) +
				" view=" + vi.Itoa64(int64(m.view)) +
				" sort=" + vi.Itoa64(int64(m.sort)) +
				" len=" + vi.Itoa64(int64(len(m.encodeState()))))
		}

		// M79e (#1708): a directory change is a navigation, so tell the
		// seat. Only on a CHANGE: a re-declare of the current path is
		// deduped seat-side anyway, and a marker per repaint would claim
		// navigations that never happened.
		if m.path != declared {
			ta.DeclareNav(m.path)
			vi.ConsoleLine(markerNavDeclare + m.path)
			declared = m.path
		}

		// M155b (#2930): an armed batch steps one item per pass — each
		// item gets its own frame and marker flush, so the seat's
		// progress row and the status counter visibly advance ("watch it
		// happen"). progress=true keeps the pass out of the idle branch:
		// a mid-batch watchStep would diff against the pre-batch baseline
		// and misreport the batch's own writes as feed events. Keys drain
		// it eagerly inside feed(); this is the fallback for batches
		// armed off the key path.
		if m.batchOn {
			if !stepBatch(&m, fd, ta) {
				shutdown(ta, fd, 4)
			}
			progress = true
		}

		if !progress {
			idlePasses++
			// M81f (#1766): poll the change feed on the quiet cadence.
			// Anything it says (armed, or >= 1 event) repaints + flushes on
			// the spot — the watch markers ride the same post-paint barrier
			// as every other marker this app prints.
			if idlePasses%watchEvery == 0 {
				if ev := m.watchStep(); ev >= 0 {
					if !paint(fd, m) {
						shutdown(ta, fd, 4)
					}
					vi.Sleep(1)
					flush(&m, ta)
					if ev > 0 {
						vi.ConsoleLine(markerRepaint)
					}
				}
			}
			// M79e (#1708): poll the seat for a back/forward target the
			// user queued with Ctrl+Shift+[ / ]. This sits in the IDLE
			// branch on purpose: every poll is a mailbox round trip, and
			// while the user is typing there is nothing queued that a
			// keypress did not just cause. With an empty queue the seat
			// answers applied=0 immediately, so this costs one probe and
			// never a parked tick.
			if p, ok := ta.PollNav(); ok && navGoto(&m, p) {
				if !paint(fd, m) {
					shutdown(ta, fd, 4)
				}
				flush(&m, ta)
				vi.ConsoleLine(markerNavBack + p)
			}
			vi.Sleep(1)
		}
	}
}

// navGoto is the nav-poll arrival path (M79e #1708): the user pressed
// back/forward and the seat handed us a path. It takes exactly the three
// steps openSel/goUp take, so a back-step is indistinguishable from a manual
// cd in this app's own log — the same `gofiles: cd` marker, the same
// listing refresh. A target equal to the current path is a no-op, which is
// what keeps a stale queued target from re-listing the same directory.
func navGoto(m *model, path string) bool {
	if path == "" || path == m.path {
		return false
	}
	m.path = path
	m.sel = 0
	m.emit(markerCd + m.path)
	m.refresh()
	return true
}

// mouseTail holds an unterminated SGR report across reads (the kernel
// writes a report in one go, but a split must not leak bytes into the key
// path — a stray 'q' would quit the manager).
var mouseTail []byte

// feed consumes one read chunk of tty bytes: SGR mouse reports are split
// off first (ESC [ < … M|m), the rest decodes to key events. It returns
// false when the caller must shut down (m.quit, or a paint failure). `ta`
// is the tab handle the M79k notify rides out on, threaded to onKey/onMouse.
func feed(m *model, fd uint32, chunk []byte, ta *tabapp.TabApp) bool {
	var kbuf []byte
	if len(mouseTail) > 0 {
		kbuf = append(mouseTail, chunk...)
		mouseTail = nil
	} else {
		kbuf = append(kbuf, chunk...)
	}
	for len(kbuf) > 0 {
		if kbuf[0] == 0x1b && len(kbuf) >= 3 && kbuf[1] == '[' && kbuf[2] == '<' {
			// A mouse report only exists in this shape; if the terminator
			// has not arrived yet, hold the tail for the next read.
			end := -1
			for i := 3; i < len(kbuf); i++ {
				if kbuf[i] == 'M' || kbuf[i] == 'm' {
					end = i
					break
				}
			}
			if end < 0 {
				if len(kbuf) > 80 { // runaway: never a report
					mouseTail = nil
					return true
				}
				mouseTail = append([]byte(nil), kbuf...)
				return true
			}
			released := kbuf[end] == 'm'
			ok, b, x, y := parseSGRMouse(kbuf[:end+1])
			kbuf = kbuf[end+1:]
			if !ok {
				continue
			}
			if !onMouse(m, fd, b, x, y, released, ta) {
				return false
			}
			if !drainBatch(m, fd, ta) {
				return false
			}
			continue
		}
		ev, used := keys.Decode(kbuf)
		if used <= 0 {
			return true
		}
		kbuf = kbuf[used:]
		if ev.Key == keys.KeyNone {
			continue
		}
		if !onKey(m, fd, ev, ta) {
			return false
		}
		// M155b (#2930): a key that armed a batch runs it to completion
		// NOW, one item per painted frame, before the next queued key can
		// interleave with it. A burst chunk (the gate's paced chords can
		// arrive several per read) must not let 'backspace' or 'q'
		// overtake items still queued — observed on the first run-19 leg,
		// where one FileRead swallowed the gesture's tail and the armed
		// batch stepped only once before 'q' quit.
		if !drainBatch(m, fd, ta) {
			return false
		}
	}
	return true
}

// stepBatch runs ONE queued batch item with the post-paint marker barrier
// every other app receipt uses — one item, one frame, one flush.
func stepBatch(m *model, fd uint32, ta *tabapp.TabApp) bool {
	m.batchStep()
	if !paint(fd, *m) {
		return false
	}
	vi.Sleep(1)
	flush(m, ta)
	vi.ConsoleLine(markerRepaint)
	return true
}

// drainBatch runs an armed batch to its end (done or first-failure stop)
// — called after every decoded input event so queued keys can never
// interleave with a half-run batch.
func drainBatch(m *model, fd uint32, ta *tabapp.TabApp) bool {
	for m.batchOn {
		if !stepBatch(m, fd, ta) {
			return false
		}
	}
	return true
}

// onKey runs one key through the model, then paints and flushes: markers
// for this key land only after its frame exists. `ta` is the tab handle the
// M79k notify rides out on — a paste is a key, so this is the path a toast
// actually takes.
func onKey(m *model, fd uint32, ev keys.Event, ta *tabapp.TabApp) bool {
	// Update has a VALUE receiver (the tea.Model contract): the returned
	// model IS the state — discarding it makes every key a no-op (observed
	// on the first gate run: `key return` printed, nothing navigated).
	next, _ := m.Update(toTea(ev))
	if nm, ok := next.(model); ok {
		*m = nm
	}
	if m.quit {
		return false
	}
	if !paint(fd, *m) {
		return false
	}
	vi.Sleep(1)
	flush(m, ta)
	drainLaunch(m)
	if !settleBanner(m, fd, ta) {
		return false
	}
	vi.ConsoleLine(markerKey + keyLabel(ev))
	vi.ConsoleLine(markerRepaint)
	settle(m)
	return true
}

// onMouse handles one SGR report: a left press goes through the model as a
// cell click, a left release settles a pended open (M124a-2's deferred
// "click again opens"), and a left button-motion (?1002, b=32+btn) arms the
// seat-mediated drag of the pressed row — after the arm the seat owns the
// pointer and no further reports arrive. `ta` is the tab handle the M79k
// notify and the drag arm ride out on, same as onKey.
func onMouse(m *model, fd uint32, b, x, y int, released bool, ta *tabapp.TabApp) bool {
	left := b&3 == 0
	right := b&3 == 2
	press := !released && left && b&32 == 0
	rpress := !released && right && b&32 == 0
	dragMove := !released && left && b&32 != 0
	// A release settles the press's deferred open — but only when no drag
	// stole the gesture (arm clears pendOpen).
	if press {
		if m.mode == modeContext {
			// M124d (#2583): a left press while the menu is open picks a
			// row or dismisses — it never reaches the list underneath.
			m.handleMenuClick(x, y)
		} else {
			next, _ := m.Update(tea.MouseClickMsg{X: x, Y: y, Button: tea.MouseLeft})
			if nm, ok := next.(model); ok {
				*m = nm
			}
		}
	} else if released && left {
		m.releaseClick()
	}
	if rpress {
		// M124d (#2583): a right press arms (or dismisses) the context
		// menu — the release edge is a no-op so the menu stays open.
		m.handleRightClick(x, y)
	}
	if press || rpress || (released && left) {
		if m.quit {
			return false
		}
		if !paint(fd, *m) {
			return false
		}
		vi.Sleep(1)
		flush(m, ta)
		drainLaunch(m)
		if !settleBanner(m, fd, ta) {
			return false
		}
		vi.ConsoleLine(markerRepaint)
	}
	if dragMove && m.pressRow >= 0 && !m.dragOn {
		// A held move stole the gesture: the pended open is dead, and the
		// arm either stages the payload (DragSource) or names its refusal.
		m.pendOpen = false
		if ta.BeginDrag() {
			m.dragOn = true
			m.emit(markerDragArm + m.dragName + " " + m.dragMT +
				" len=" + vi.Itoa64(int64(m.dragLen)))
		} else if m.dragName != "" {
			m.emit(markerDragNo + m.dragName + " seat")
		}
		if !paint(fd, *m) {
			return false
		}
		vi.Sleep(1)
		flush(m, ta)
	}
	vi.ConsoleLine(markerMouse + vi.Itoa64(int64(b)) +
		" x=" + vi.Itoa64(int64(x)) + " y=" + vi.Itoa64(int64(y)))
	return true
}

// parseSGRMouse reads ESC [ < b ; x ; y M|m — hand-rolled (no strconv): the
// app only ever prints what the kernel sent. (M73i #1635 shape, as in
// charmhello.)
func parseSGRMouse(seq []byte) (bool, int, int, int) {
	if len(seq) < 6 || seq[0] != 0x1b || seq[1] != '[' || seq[2] != '<' {
		return false, 0, 0, 0
	}
	var vals [3]int
	idx := 0
	cur := 0
	digits := false
	for i := 3; i < len(seq); i++ {
		c := seq[i]
		switch {
		case c >= '0' && c <= '9':
			cur = cur*10 + int(c-'0')
			digits = true
		case c == ';':
			if !digits || idx >= 2 {
				return false, 0, 0, 0
			}
			vals[idx] = cur
			idx++
			cur = 0
			digits = false
		case c == 'M' || c == 'm':
			if !digits || idx != 2 {
				return false, 0, 0, 0
			}
			vals[2] = cur
			return true, vals[0], vals[1], vals[2]
		default:
			return false, 0, 0, 0
		}
	}
	return false, 0, 0, 0
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	// Leave mouse reporting off, the alt screen, and show the cursor again
	// before the window goes away.
	_, _ = vi.FileWrite(fd, []byte("\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?1049l\x1b[?25h"))
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}
