// GOTABWM.ELF — M62e (issue #1403): persist the in-process strip as `.tabs`
// v2 on /host/SESSION.TABS. Encode/Decode is a guest-safe copy of the
// host tabcodec layout (tabsv2.go); do not exec the host tool in-guest.
// Corrupt bytes fail closed: empty strip, no trust.
//
// M79g (#1718): the file now records what the USER did, not what the demo
// choreography staged. Every mutation that changes the strip writes it
// through (noteSessionMutation at each call site) instead of waiting for the
// one pin-stay snapshot — reorder a tab, pin it, freeze it, open or close
// one, and the next boot restores that. The choreography's own write keeps
// its marker.
//
// M120b (#2559): a restored strip is LIVE, not corpses. Each backed row is
// re-exec'd and waits as a placeholder only until its pid's declare
// re-inhabits it — order, pin, frozen and focus ride the row across the
// swap. A row nothing can run is dropped by name, and a restore that leaves
// no live row falls back to the first-boot workspace.
package main

import "virelai/vi"

const (
	sessionPath   = "/host/SESSION.TABS"
	sessionIDBase = uint32(0x100) // placeholder ids; records have no window id
)

type sessionLoadState uint8

const (
	sessionMissing sessionLoadState = iota
	sessionRestored
	sessionCorrupt
	// sessionEmpty: the file decoded, but nothing it recorded came back
	// live — every row was unbacked or its re-exec failed. Distinct from a
	// valid EMPTY file (count=0 stays sessionRestored: a boot that closed
	// everything asked for an empty desktop, not a starter).
	sessionEmpty
)

var (
	sessionSeq uint16 = 1
	// sessionDirty is set by noteSessionMutation and cleared by a
	// successful writeSession. It is retry/observability state, not a
	// write gate: the no-op guard lives at the call sites (a same-cell
	// reorder, a pin of an already-pinned tab returns before the hook,
	// so a burst of no-ops costs no file write). A failed publish or an
	// empty-strip refusal leaves it set — there IS an unpersisted change;
	// publishing it would be a lie, dropping it would be amnesia.
	// The guard is on CHANGE, not on time — the seat has no timer to
	// debounce with, and at a human interaction rate a handful of 2 KB
	// crash-safe writes per boot is not a throughput problem.
	sessionDirty bool
)

func sessionTitlesLine(s *TabStrip) string {
	titles := ""
	pins := "pin="
	for i := 0; i < s.count; i++ {
		if i > 0 {
			titles += ","
			pins += ","
		}
		titles += s.tabs[i].Title
		if s.tabs[i].Pinned {
			pins += "1"
		} else {
			pins += "0"
		}
	}
	a := 0
	if s.count > 0 {
		a = s.focus
	}
	return titles + " " + pins + " active=" + dec(uint32(a))
}

// writeHostFile replaces path with data through the M66b crash-safe
// write: temp + fsync + delete/rename publish (vi.WriteFileSafe). It is a
// var so a host test can capture the bytes: vi.WriteFileSafe degrades to
// -ENOSYS off the guest, which would otherwise make the persist path
// unobservable (the execApp / closeWin pattern in hid.go and interop.go).
// M62e
// wrote in place — the write-open truncated the live file to zero before
// the first chunk landed — so a crash mid-write left a partial
// SESSION.TABS or LAYOUT.txt behind for the next boot to trust or trip
// over; now the live path only ever appears atomically, and the crash
// window leaves the previous bytes or none, which fail-closed readers
// treat as defaults.
var writeHostFile = func(path string, data []byte) bool {
	return vi.WriteFileSafe(path, data) == 0
}

// readSessionFile is the ReadFileAll seam for loadSession (the writeHostFile
// pattern): on the host it returns -ENOSYS, so the test drives restore
// through this var.
var readSessionFile = func(path string, max int) ([]byte, int64) {
	return vi.ReadFileAll(path, max)
}

// sessionRows is the strip SESSION.TABS may honestly record: the tabs THIS
// boot hosts. A row still waiting for its re-exec'd app to declare (a
// placeholder id, >= sessionIDBase) is not a live client, so writing it
// back would grow the file with a row no app is running yet; across boots
// (restore, open one, reboot) that grows without bound. Focus follows by
// id; a focus that sat on a dropped row records no active tab.
func (s *TabStrip) sessionRows() TabStrip {
	var out TabStrip
	fid, has := s.Focused()
	for i := 0; i < s.count; i++ {
		t0 := s.tabs[i]
		if t0.ID >= sessionIDBase {
			continue
		}
		if !out.OpenTab(t0.ID, t0.Title) {
			return TabStrip{}
		}
		j := out.count - 1
		out.tabs[j].Bin = t0.Bin
		out.tabs[j].Pinned = t0.Pinned
		out.tabs[j].Frozen = t0.Frozen
		out.tabs[j].State = t0.State
		out.tabs[j].StateVer = t0.StateVer
	}
	out.focus = -1 // set AFTER the loop: OpenTab focuses the first row
	if has {
		if i := out.index(fid); i >= 0 {
			out.focus = i
		}
	}
	return out
}

// noteSessionMutation is the write-through hook: every mutation that changed
// the strip calls it, and the file is correct the moment the mutation lands
// (no debounce, no save-on-exit, so a killed seat still leaves the truth
// behind). It always attempts the write — the write count stays bounded by
// CHANGES because no-op mutations return before reaching this hook, never
// by a timer. (The choreography's pin-stay snapshot in seat.go case 2 calls
// writeSession directly; equivalent — the declares already left dirty set.)
func noteSessionMutation() bool {
	sessionDirty = true
	return writeSession()
}

// writeSession encodes the live strip and writes SESSION.TABS. It refuses an
// EMPTY strip: a boot that closed everything must not publish a file that
// claims a session, and every reader already treats absent as defaults.
// M79g: this is also the choreography's pin-stay snapshot (seat.go case 2)
// and the write-through target of every user mutation.
// M137c (#2773): every space's rows encode, group-named — the active field
// names the live space's focused record.
func writeSession() bool {
	recs, active, ok := sessionRecordsV2()
	if !ok {
		return false
	}
	raw, dropped, ok := encodeRecordsV2(sessionSeq, recs, active)
	if !ok {
		vi.ConsoleLine("gotabwm: session write fail")
		return false
	}
	for _, d := range dropped {
		vi.ConsoleLine(MarkerStateDrop + d + " full")
	}
	if !writeHostFile(sessionPath, raw) {
		vi.ConsoleLine("gotabwm: session write fail")
		return false
	}
	sessionDirty = false
	sessionSeq++
	vi.ConsoleLine(MarkerSessionWrite + vi.Itoa64(int64(len(recs))))
	if spaceN > 1 {
		vi.ConsoleLine(MarkerSessionSpaces + "n=" + vi.Itoa64(int64(spaceN)))
	}
	// M137a: the pane tree rides beside the records — published or
	// cleared at the same point so the pair never disagrees.
	writePanesFile()
	return true
}

// restoreSessionBytes keeps the missing/corrupt/present decisions testable on
// the host. A missing file is distinct from an invalid or valid empty session:
// only missing can request the first-boot workspace. M137c: the decode
// distributes records by group across spaces; *strip lands the live space.
func restoreSessionBytes(strip *TabStrip, b []byte, readResult int64) (uint16, sessionLoadState) {
	if readResult < 0 || b == nil {
		return 0, sessionMissing
	}
	seq, ok := applySpacesV2(b)
	if !ok {
		return 0, sessionCorrupt
	}
	*strip = tabs
	return seq, sessionRestored
}

// loadSession reads SESSION.TABS. Missing is the first-boot branch; corrupt
// or truncated bytes fail closed, while a present valid file is restored
// and (M120b) re-exec'd: each row with a recorded bin gets its executable
// started again, and the rows nothing could run are dropped by name.
func loadSession() sessionLoadState {
	b, r := readSessionFile(sessionPath, tabsV2MaxBytes)
	seq, state := restoreSessionBytes(&tabs, b, r)
	// sessionEcho is the file's own echo, captured before re-exec mutates
	// the strip: the restore-witness line reports what the FILE held, not
	// what survived the exec fan-out (live-vz-restore's fixture legs pin
	// the recorded titles across save and resume).
	sessionEcho = sessionTitlesLine(&tabs)
	if state == sessionMissing {
		return state
	}
	if state == sessionCorrupt {
		vi.ConsoleLine(MarkerSessionBad)
		return state
	}
	sessionSeq = seq + 1
	if tabs.Count() == 0 {
		return state
	}
	// M137a: the sidecar decodes against the restored rows (leaf record
	// index -> tabs[i]) before any re-exec or adoption renames the ids.
	loadPanesFile()
	// Placeholder ids (sessionIDBase+) are not kernel windows. Leave
	// hostedApp=0 so a later Wmctl* cannot aim at 0x100+i until adoption
	// swaps in a real id. stripDone skips the live choreography that
	// would close/split the restored strip.
	hostedApp = 0
	stripDone = true
	// The echoes describe what the FILE held, printed before the re-exec
	// fan-out drops or adopts anything: `mode=restore` names the decode
	// path (a strip that came from disk, not from declares), titles and
	// the freeze count are the round-trip proof, and the order/layout
	// dumps still show the placeholder strip exactly as read back.
	loadN := 0
	for si := 0; si < spaceN; si++ {
		loadN += stripOf(si).Count()
	}
	vi.ConsoleLine(MarkerSessionLoad + vi.Itoa64(int64(loadN)) + " mode=restore")
	vi.ConsoleLine(MarkerSessionTitles + sessionEcho)
	if spaceN > 1 {
		vi.ConsoleLine(MarkerSessionSpaces + "n=" + vi.Itoa64(int64(spaceN)) +
			" cur=" + spaces[spaceCur].Name)
	}
	// M71e (#1564): how many restored tabs came back carrying the frozen
	// badge — the observable that the flag survived the round-trip. A
	// separate line, not a field on the titles line above: that line's exact
	// shape is asserted by go-wm-tabs run 02.
	vi.ConsoleLine(MarkerSessionFreeze + vi.Itoa64(int64(tabs.FrozenCount())))
	dumpOrder()
	_ = writeLayoutFile()
	// M120b (#2559): the restore's live half. Rows sit as placeholders only
	// until their pid declares; the bound is the file's own row cap plus a
	// task pool that refuses what cannot fit. A boot whose rows all dropped
	// reports sessionEmpty so the caller can fall back to the starter.
	vi.ConsoleLine(MarkerSessionReexec + vi.Itoa64(int64(reexecSession())))
	if tabs.Count() == 0 {
		return sessionEmpty
	}
	return state
}

// sessionReexecHold is the composite-tick budget a re-exec'd pid gets to
// reach its declare before the placeholder row is dropped — the row is
// honest about waiting, not a corpse. The budget is hostTicks-shaped:
// every staged client declares well inside its first ticks.
const sessionReexecHold = hostTicks

// reexecWait pairs an exec'd pid with the placeholder row that pid is
// re-inhabiting. The declare path matches on ReplyTo (the client's own
// pid — the same identity the RPC binding checks), never on title: a
// retitled row would never match its own record. M137c: the space index
// rides along so adoption lands on the right strip — placeholder ids are
// unique across the whole file.
type reexecWait struct {
	pid   uint8
	space uint8
	id    uint32 // the placeholder window id the row still carries
}

var (
	reexecPending [MaxSpaces * MaxTabs]reexecWait
	reexecN       int
	reexecHold    int
	// sessionEcho is the file's titles/pin/active echo, captured at load
	// before the re-exec fan-out mutates the strip; restoreWitnessLine
	// reports it.
	sessionEcho string
)

// dropRestoredRow removes a placeholder row that cannot become a live tab,
// named by its recorded title. There is no kernel window behind a
// placeholder id, so this is the local strip removal, not the WM close
// seam — and a dropped row's bin still lands in the reopen LIFO, so
// ctrl-shift-t can retry an app the pool refused.
func dropRestoredRow(si int, t0 Tab, why string) {
	name := t0.Title
	if name == "" {
		name = t0.Bin
	}
	vi.ConsoleLine(MarkerSessionDrop + name + " " + why)
	_ = stripOf(si).CloseTab(t0.ID)
}

// reexecSession turns the just-restored placeholder strips into live tabs:
// every space's backed row's bin is exec'd (the `.tabs` v2 row cap is the
// seat's tab limit, and the kernel's task pool refuses what cannot fit —
// a refused exec drops its row by name, which IS the pool bound). Each
// issued exec leaves the row pending for its pid's declare. Returns the
// execs issued.
func reexecSession() int {
	issued := 0
	for si := 0; si < spaceN; si++ {
		s := stripOf(si)
		var rows [MaxTabs]Tab
		n := s.Count()
		copy(rows[:], s.tabs[:n])
		for i := 0; i < n; i++ {
			t0 := rows[i]
			if t0.Bin == "" {
				dropRestoredRow(si, t0, "unbacked")
				continue
			}
			pid, err := execApp(t0.Bin)
			if err != nil || pid <= 0 || pid > 255 {
				seatRefusalErr(err, "exec "+t0.Bin, t0.Bin)
				dropRestoredRow(si, t0, "exec")
				continue
			}
			vi.ConsoleLine(MarkerSessionExec + t0.Bin)
			reexecPending[reexecN] = reexecWait{
				pid: uint8(pid), space: uint8(si), id: t0.ID}
			reexecN++
			issued++
		}
	}
	if reexecN > 0 {
		reexecHold = sessionReexecHold
		reexecSettleArmed = true
	}
	return issued
}

// adoptReexec re-inhabits a placeholder row with the declaring window: the
// row keeps its recorded position, title, pin, frozen and focus — only the
// dead placeholder id is swapped for the real window id. Returns the strip
// index, or -1 when the pid is not a pending restore (a dropped row's late
// declare joins as an ordinary new tab). M137c: a dormant space's adopted
// window hides at once — it must not composite over the live space.
func adoptReexec(pid uint8, id uint32) int {
	for i := 0; i < reexecN; i++ {
		if reexecPending[i].pid != pid {
			continue
		}
		phid := reexecPending[i].id
		si := int(reexecPending[i].space)
		reexecPending[i] = reexecPending[reexecN-1]
		reexecPending[reexecN-1] = reexecWait{}
		reexecN--
		s := stripOf(si)
		idx := s.index(phid)
		if idx < 0 {
			return -1
		}
		s.tabs[idx].ID = id
		// M137a: a pane leaf named by the dead placeholder id follows
		// the swap to the live window id.
		s.retreeID(phid, id)
		if si != spaceCur {
			wmctlSetVisible(id, false)
		}
		return idx
	}
	return -1
}

// procsAlive is the pid-liveness seam for the reap half: vi.Procs in the
// guest, a stub in tests. Failing open (true) on an unreadable table keeps
// a pending row from being reaped by an unavailable answer — the tick
// deadline below is the backstop either way.
var procsAlive = func(pid uint8) bool {
	var rows [64]vi.ProcRow
	n, r := vi.Procs(rows[:])
	if r < 0 {
		return true
	}
	for i := 0; i < n; i++ {
		if uint8(rows[i].PID) == pid {
			return rows[i].State == vi.ProcCreated || rows[i].State == vi.ProcRunning
		}
	}
	return false
}

// procsCpuTicks reads one pid's cumulative scheduler-work counter from the
// ADR 0047 v2 snapshot (#2703's app-quiet probe: the focused tab's cpu_ticks
// is the only seat-visible measure of work it is still doing on already-
// delivered input). ok=false on an unreadable table, a missing pid, or a
// kernel that answered a v1 stream — a caller that cannot probe has no
// evidence of busyness, not proof of quiet.
var procsCpuTicks = func(pid uint8) (uint64, bool) {
	var rows [64]vi.ProcRow
	n, r := vi.ProcsV2(rows[:])
	if r < 0 {
		return 0, false
	}
	for i := 0; i < n; i++ {
		if uint8(rows[i].PID) == pid {
			return rows[i].CpuTicks, rows[i].RowVer >= vi.ProcRowVersion2
		}
	}
	return 0, false
}

// reapSessionReexec runs on the composite cadence while restores are
// outstanding: a pid that died before declaring drops its row now, and a
// pid still pending when the hold expires drops its row too — a declare
// that arrives afterwards joins as an ordinary new tab. When the set
// drains, finishReexec lands the recorded focus and the live dumps.
func reapSessionReexec() {
	for i := 0; i < reexecN; {
		if procsAlive(reexecPending[i].pid) {
			i++
			continue
		}
		s := stripOf(int(reexecPending[i].space))
		if idx := s.index(reexecPending[i].id); idx >= 0 {
			dropRestoredRow(int(reexecPending[i].space), s.At(idx), "dead")
		}
		reexecPending[i] = reexecPending[reexecN-1]
		reexecPending[reexecN-1] = reexecWait{}
		reexecN--
	}
	if reexecN > 0 && reexecHold > 0 {
		reexecHold--
		if reexecHold == 0 {
			for reexecN > 0 {
				si := int(reexecPending[reexecN-1].space)
				s := stripOf(si)
				if idx := s.index(reexecPending[reexecN-1].id); idx >= 0 {
					dropRestoredRow(si, s.At(idx), "late")
				}
				reexecN--
			}
		}
	}
	maybeFinishReexec()
}

// reexecSettleArmed is the once-latch for the settle: armed by a restore
// that issued execs, consumed when the pending set has fully drained —
// by adoption or by the reap. A boot that never armed it never settles.
var reexecSettleArmed bool

func maybeFinishReexec() {
	if reexecSettleArmed && reexecN == 0 {
		reexecSettleArmed = false
		finishReexec()
	}
}

// finishReexec lands the recorded focus once the pending set has drained:
// the focused row's live window gets the real raise (a later-declaring
// window may have held kernel focus through the fan-out). If the focused
// row never came back, the first live row takes it. The order and layout
// dumps then go out with the real window ids.
func finishReexec() {
	fid, ok := tabs.Focused()
	if !ok || fid >= sessionIDBase {
		fid = 0
		for i := 0; i < tabs.Count(); i++ {
			if id := tabs.At(i).ID; id < sessionIDBase {
				fid = id
				break
			}
		}
	}
	live := 0
	for si := 0; si < spaceN; si++ {
		s := stripOf(si)
		for i := 0; i < s.Count(); i++ {
			if s.At(i).ID < sessionIDBase {
				live++
			}
		}
	}
	if fid != 0 {
		_ = tabs.FocusTab(fid)
		hostedApp = fid
		if focusRaise(fid) == 0 {
			vi.ConsoleLine(MarkerTabFocus + vi.Itoa64(int64(fid)))
			vi.ConsoleLine(MarkerHostFocus + vi.Itoa64(int64(fid)))
		}
	}
	vi.ConsoleLine(MarkerSessionLive + vi.Itoa64(int64(live)))
	// M137c: a dormant space's adopted windows must leave the composite —
	// adoption already hides each one, this sweep is the belt for any row
	// that slipped past it (an id reused, an early declare).
	for si := 0; si < spaceN; si++ {
		if si == spaceCur {
			continue
		}
		spaceSetVisible(&spaces[si].Strip, false)
	}
	// M137a: a restored tree applies its pane rects to the adopted
	// windows once the placeholder swap has settled — the sidecar's
	// layout is real geometry, not just a LAYOUT.txt shape.
	if tabs.treeN != 0 {
		_ = applyTreeRects()
	}
	dumpOrder()
	_ = writeLayoutFile()
}

// firstBootWorkspace is only for the default Go seat. A deliberately selected
// shim-only seat (wm=none) may exec GOTABWM for a gate, and the Zig fallback
// (wm=tabwm) owns its own startup path. M120b: a restore that left no live
// row (sessionEmpty) falls back here too — the starter is suppressed by a
// session that came back, never by one that did not.
func firstBootWorkspace(state sessionLoadState, wm string) bool {
	return (state == sessionMissing || state == sessionEmpty) && wm == "gotabwm"
}

func hasLiveGuestELF(rows []vi.ProcRow) bool {
	for _, row := range rows {
		if row.State != vi.ProcCreated && row.State != vi.ProcRunning {
			continue
		}
		name := row.Name()
		// Init supervises the seat; it is not a competing workspace client.
		if name != "GOTABWM.ELF" && name != "INIT.ELF" && len(name) > 4 && name[len(name)-4:] == ".ELF" {
			return true
		}
	}
	return false
}

// anotherGuestProgram prevents an explicitly started app (for example,
// GOSH in a gate script) from being duplicated by the first-boot default.
func anotherGuestProgram() bool {
	var rows [64]vi.ProcRow
	n, r := vi.Procs(rows[:])
	return r >= 0 && hasLiveGuestELF(rows[:n])
}
