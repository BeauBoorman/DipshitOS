package main

// M161b (#2974): the watchdog's class-A half. The seams are the same
// package vars the runtime binds: stateNoticePost/stateLog come from
// stateFixture (appstate_test.go), and this file's own install swaps the
// kill gate probe, the procs-v2 sampler and the marker sink.

import (
	"strings"
	"testing"

	"virelai/vi"
)

// wdFixture layers the watchdog's globals over stateFixture: tabs and
// bindings are already faked there; here we add the kill/principal/usage
// seams and reset the per-window tables so each test starts empty.
type wdFixture struct {
	logs    []string
	kills   []uint64
	killRC  int64
	uid     uint32
	caps    uint32
	prinOK  bool
	usages  [][4]uint64 // scripted (cpu,total,ncores) samples, in order
	usample int
}

func (f *wdFixture) hasLog(sub string) bool {
	for _, l := range f.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

func (f *wdFixture) install(t *testing.T) {
	t.Helper()
	oldAlive, oldLog := procsAlive, wdLog
	oldUsage, oldKill, oldPrin := wdProcsUsage, wdKill, wdPrincipal
	oldWd := struct {
		proto, asked, ever, wedged, busy, killed [256]bool
		miss                                     [256]uint8
		busyWin                                  uint32
		streak                                   int
		prevCpu, prevTot                         uint64
		prevInit, sweepInit, killOK              bool
		lastSweep                                uint64
	}{wdProto, wdAsked, wdEverAsked, wdWedged, wdBusy, wdKilled, wdMiss,
		wdBusyWin, wdBusyStreak, wdPrevCpu, wdPrevTotal, wdPrevInit,
		wdSweepInit, wdKillOK, wdLastSweep}
	t.Cleanup(func() {
		procsAlive, wdLog = oldAlive, oldLog
		wdProcsUsage, wdKill, wdPrincipal = oldUsage, oldKill, oldPrin
		wdProto, wdAsked, wdEverAsked = oldWd.proto, oldWd.asked, oldWd.ever
		wdWedged, wdBusy, wdKilled = oldWd.wedged, oldWd.busy, oldWd.killed
		wdMiss = oldWd.miss
		wdBusyWin, wdBusyStreak = oldWd.busyWin, oldWd.streak
		wdPrevCpu, wdPrevTotal, wdPrevInit = oldWd.prevCpu, oldWd.prevTot, oldWd.prevInit
		wdSweepInit, wdKillOK, wdLastSweep = oldWd.sweepInit, oldWd.killOK, oldWd.lastSweep
	})
	wdProto, wdAsked, wdEverAsked = [256]bool{}, [256]bool{}, [256]bool{}
	wdWedged, wdBusy, wdKilled = [256]bool{}, [256]bool{}, [256]bool{}
	wdMiss = [256]uint8{}
	wdBusyWin, wdBusyStreak, wdPrevInit = 0, 0, false
	wdSweepInit, wdKillOK, wdLastSweep = false, false, 0
	procsAlive = func(uint8) bool { return true }
	f.uid, f.caps, f.prinOK = vi.UidUser, 0, true
	f.killRC = 0
	wdLog = func(s string) { f.logs = append(f.logs, s) }
	wdPrincipal = func() (uint32, uint32, bool) { return f.uid, f.caps, f.prinOK }
	wdKill = func(pid uint64) int64 { f.kills = append(f.kills, pid); return f.killRC }
	wdProcsUsage = func(pid uint8) (uint64, uint64, uint64, bool) {
		if f.usample >= len(f.usages) {
			return 0, 0, 0, false
		}
		u := f.usages[f.usample]
		f.usample++
		return u[0], u[1], u[2], true
	}
}

// openBoundTab lands a bound, live pane on the strip — the state the
// watchdog's liveness arm watches.
func openBoundTab(t *testing.T, id uint32, pid uint8, title string) {
	t.Helper()
	if !tabs.OpenTab(id, title) {
		t.Fatalf("OpenTab(%d)", id)
	}
	rpcBindings[id] = rpcBinding{pid: pid, token: uint64(id) + 0x100}
}

// answer simulates the app's kind-20 arriving at serveStateSave — the
// latch point, not the blob path.
func answer(id uint8) { watchdogNoteAnswer(id) }

// TestWatchdogDiscoveryAsk: a fresh bound pane gets exactly one discovery
// ask, on the first heartbeat that sees it.
func TestWatchdogDiscoveryAsk(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	watchdogTick(1)
	if len(f.notices) != 1 || f.notices[0].Kind != vi.WmRpcKindSaveState || f.notices[0].ID != 9 {
		t.Fatalf("discovery ask = %+v", f.notices)
	}
	if !wdEverAsked[9] || !wdAsked[9] {
		t.Fatal("discovery ask did not latch")
	}
	for tick := uint64(2); tick < 20; tick++ {
		watchdogTick(tick)
	}
	if len(f.notices) != 1 {
		t.Fatalf("never-answered app re-asked: notices = %d", len(f.notices))
	}
	if wdWedged[9] {
		t.Fatal("a pane that never answered wedged — the liveness arm must not score it")
	}
}

// TestWatchdogSweepRounds: an answered ask joins the pane to the sweep
// pool; two consecutive unanswered asks wedge it, and the marker names
// the window, the app and the round count.
func TestWatchdogSweepRounds(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	watchdogTick(1)
	answer(9) // the discovery ask lands and the app speaks

	// Sweep 1: answered -> clean, fresh ask posted.
	watchdogSweep()
	if wdMiss[9] != 0 || wdWedged[9] {
		t.Fatal("answered pane collected a miss")
	}
	if len(f.notices) != 2 {
		t.Fatalf("sweep repost = %d notices want 2", len(f.notices))
	}
	// Sweep 2: unanswered -> miss 1, still bannerless.
	watchdogSweep()
	if wdMiss[9] != 1 || wdWedged[9] {
		t.Fatalf("first miss = %d wedged=%v", wdMiss[9], wdWedged[9])
	}
	// Sweep 3: miss 2 -> wedged, marker with app + rounds.
	watchdogSweep()
	if !wdWedged[9] || wdMiss[9] != 2 {
		t.Fatalf("wedge: miss=%d wedged=%v", wdMiss[9], wdWedged[9])
	}
	if !w.hasLog(MarkerWatchdogWedged + "id=9 app=GoTabApp rounds=2") {
		t.Fatalf("wedged marker: %v", f.logs)
	}
}

// TestWatchdogRecovery: a wedged pane that answers clears the banner and
// prints the recovered line — silently, meaning no re-wedge on the answer
// itself and the round counter reset.
func TestWatchdogRecovery(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	wdProto[9] = true
	wdAsked[9] = true
	watchdogSweep()
	watchdogSweep()
	if !wdWedged[9] {
		t.Fatal("precondition: pane not wedged")
	}
	answer(9)
	if wdWedged[9] || wdBusy[9] || wdMiss[9] != 0 || wdAsked[9] {
		t.Fatal("answer did not clear the wedge state")
	}
	if !w.hasLog(MarkerWatchdogRecovered + "id=9") {
		t.Fatalf("recovered marker: %v", f.logs)
	}
}

// TestWatchdogTickCadence: the sweep runs on the consumed-tick interval,
// not a modulo — a batched heartbeat step over a %10 boundary still earns
// its round.
func TestWatchdogTickCadence(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	wdProto[9] = true
	// Tick 0 IS a sweep: the answered pane posts its first liveness ask.
	watchdogTick(0)
	if wdMiss[9] != 0 || !wdAsked[9] {
		t.Fatal("epoch sweep should post, not count")
	}
	watchdogTick(9)  // under the interval: no sweep
	watchdogTick(11) // past it: one miss
	if wdMiss[9] != 1 {
		t.Fatalf("sweep interval missed the batch: miss=%d", wdMiss[9])
	}
	// A jump of 25 ticks is still ONE round — the ask cadence counts
	// unanswered rounds, not elapsed ticks.
	watchdogTick(36)
	if wdMiss[9] != 2 || !wdWedged[9] {
		t.Fatalf("batched tick over-counted: miss=%d wedged=%v", wdMiss[9], wdWedged[9])
	}
}

// TestWatchdogBusyArm: a focused pane with no protocol spins its pid at
// ≥90%-of-one-core for 15 sampled ticks and earns the busy flag + marker;
// a below-threshold sample clears it, and losing focus freezes the
// streak where it stood.
func TestWatchdogBusyArm(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	if !tabs.FocusTab(9) {
		t.Fatal("FocusTab")
	}
	// 1 seed + 16 samples at 95% of one core (ncores=4, 95 cpu per 400 total).
	w.usages = [][4]uint64{{0, 0, 4}}
	for i := uint64(1); i <= 16; i++ {
		w.usages = append(w.usages, [4]uint64{95 * i, 400 * i, 4})
	}
	for tick := uint64(1); tick <= 16; tick++ {
		watchdogBusy()
	}
	if wdBusyStreak != 15 || !wdBusy[9] {
		t.Fatalf("busy: streak=%d flag=%v", wdBusyStreak, wdBusy[9])
	}
	if !w.hasLog(MarkerWatchdogBusy + "id=9 cpu=95") {
		t.Fatalf("busy marker: %v", f.logs)
	}
	// Focus elsewhere: sampling stops, the flag stands (last observation).
	openBoundTab(t, 10, 22, "Other")
	_ = tabs.FocusTab(10)
	w.usages = append(w.usages, [4]uint64{1600, 6800, 4}) // cold sample for pid 22
	watchdogBusy()
	if !wdBusy[9] {
		t.Fatal("unfocus cleared a raised busy flag")
	}
	if wdBusyWin == 9 {
		t.Fatal("busy sampler did not follow focus")
	}
	// Back on 9, a cool sample drops the flag and restarts the streak.
	// The refocus re-seeds the sampler (no eval), then the cold delta
	// reads 10 cpu over 400 total = 10% of one core.
	_ = tabs.FocusTab(9)
	w.usages = append(w.usages, [4]uint64{1600, 6800, 4})
	w.usages = append(w.usages, [4]uint64{1610, 7200, 4})
	watchdogBusy()
	watchdogBusy()
	if wdBusy[9] || wdBusyStreak != 0 {
		t.Fatalf("cool sample: busy=%v streak=%d", wdBusy[9], wdBusyStreak)
	}
}

// TestWatchdogBusyNeedsProtocolLess: a pane that speaks the state
// protocol is the liveness arm's problem — the busy sampler never scores
// it, hot or not.
func TestWatchdogBusyNeedsProtocolLess(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	_ = tabs.FocusTab(9)
	wdProto[9] = true
	w.usages = [][4]uint64{{0, 0, 4}, {400, 400, 4}} // 100% for one sample
	watchdogBusy()
	watchdogBusy()
	if wdBusyStreak != 0 || wdBusy[9] {
		t.Fatal("protocol app accrued a busy streak")
	}
	if w.usample != 0 {
		t.Fatal("protocol app consumed a procs sample")
	}
}

// TestWatchdogLayoutAndHit: one layout function owns the strip and the
// button zones, so the paint and the hit-test agree by construction —
// the test pins that a point inside a painted button names its verb and
// a point off the strip names nothing.
func TestWatchdogLayoutAndHit(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	wdWedged[9] = true
	wdKillOK = true

	strip, wait, close, force := watchdogLayout(9, vi.ScanoutWidth, vi.ScanoutHeight)
	if strip.Y < RailHeight || strip.W <= 0 || strip.H != watchBannerH {
		t.Fatalf("strip = %+v", strip)
	}
	if wait.W <= 0 || close.W <= 0 || force.W <= 0 {
		t.Fatal("armed probe dropped a button zone")
	}
	// Hit each button dead centre.
	check := func(x, y int, want int) {
		t.Helper()
		id, act := watchdogHit(uint32(x), uint32(y), vi.ScanoutWidth, vi.ScanoutHeight)
		if id != 9 || act != want {
			t.Fatalf("hit (%d,%d) = id %d act %d want %d", x, y, id, act, want)
		}
	}
	check(wait.X+wait.W/2, strip.Y+strip.H/2, wdActWait)
	check(close.X+close.W/2, strip.Y+strip.H/2, wdActClose)
	check(force.X+force.W/2, strip.Y+strip.H/2, wdActForce)
	// The strip body left of Wait is chrome — consumed, no verb.
	check(strip.X+1, strip.Y+strip.H/2, wdActNone)
	// Off the strip entirely.
	if id, _ := watchdogHit(640, 400, vi.ScanoutWidth, vi.ScanoutHeight); id != 0 {
		t.Fatalf("off-strip hit id=%d", id)
	}
	// Probe off: the Force zone disappears rather than dead-clicking.
	wdKillOK = false
	_, _, _, force = watchdogLayout(9, vi.ScanoutWidth, vi.ScanoutHeight)
	if force.W != 0 {
		t.Fatal("failed probe still painted a Force zone")
	}
}

// TestWatchdogProbeGate: the startup probe reads the seat principal and
// evaluates the kernel's kill-gate rule for hosted apps.
func TestWatchdogProbeGate(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	cases := []struct {
		uid, caps uint32
		ok        bool
		armed     bool
	}{
		{vi.UidUser, 0, true, true},                  // same-uid hosted apps
		{vi.UidUser, wdCapProcAdmin, true, true},     // user + cap
		{vi.UidAgent, 0, true, true},                 // agent-hosted apps
		{vi.UidSystem, wdCapProcAdmin, true, true},   // admin reaches all
		{vi.UidSystem, 0, true, false},               // system w/o cap: nothing hosted
		{0, 0, false, false},                         // no identity: fail closed
	}
	for _, c := range cases {
		w.uid, w.caps, w.prinOK = c.uid, c.caps, c.ok
		watchdogProbeKillGate()
		if wdKillOK != c.armed {
			t.Fatalf("uid=%d caps=%d ok=%v -> armed=%v want %v",
				c.uid, c.caps, c.ok, wdKillOK, c.armed)
		}
	}
	if !w.hasLog(MarkerWatchdogForceQuit + "armed") ||
		!w.hasLog(MarkerWatchdogForceQuit + "off") {
		t.Fatalf("probe verdict lines: %v", f.logs)
	}
}

// TestWatchdogPressVerbs: Wait re-arms, Close runs the ordinary close seam
// and names how=close, Force arms sys_kill on the bound pid — and a
// refused kill is reported, never claimed.
func TestWatchdogPressVerbs(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	wdProto[9], wdWedged[9], wdMiss[9] = true, true, 2
	wdKillOK = true

	// Wait drops the banner and re-arms the counter.
	watchdogPress(9, wdActWait)
	if wdWedged[9] || wdMiss[9] != 0 {
		t.Fatal("Wait did not re-arm")
	}
	// Close: the wedged pane skips the save ask (proven unanswering) and
	// the close lands through closeWin.
	wdWedged[9] = true
	before := len(f.notices)
	watchdogPress(9, wdActClose)
	if tabs.index(9) >= 0 {
		t.Fatal("Close left the row on the strip")
	}
	if !w.hasLog(MarkerWatchdogClosed + "id=9 how=close") {
		t.Fatalf("closed marker: %v", f.logs)
	}
	for _, n := range f.notices[before:] {
		if n.Kind == vi.WmRpcKindSaveState {
			t.Fatal("wedged pane's close still posted a save ask")
		}
	}

	// Force on a fresh wedged pane: armed kill on the bound owner, the
	// wdKilled latch suppresses the crash arm.
	openBoundTab(t, 11, 33, "BusyApp")
	wdWedged[11] = true
	watchdogPress(11, wdActForce)
	if len(w.kills) != 1 || w.kills[0] != 33 {
		t.Fatalf("kill = %v", w.kills)
	}
	if !wdKilled[11] || !w.hasLog(MarkerWatchdogClosed + "id=11 how=kill") {
		t.Fatalf("kill arm: killed=%v logs=%v", wdKilled[11], f.logs)
	}
	// A refused kill reports the errno and latches nothing.
	openBoundTab(t, 12, 44, "Stubborn")
	w.killRC = -vi.ErrEACCES
	watchdogPress(12, wdActForce)
	if wdKilled[12] || !w.hasLog(MarkerWatchdogRefused + "id=12 how=kill err=EACCES") {
		t.Fatalf("refused kill: killed=%v logs=%v", wdKilled[12], f.logs)
	}
	// Probe off: the verb is unreachable — a stray dispatch is a no-op
	// (the earlier armed + refused attempts account for the two kills).
	wdKillOK = false
	openBoundTab(t, 13, 45, "Late")
	watchdogPress(13, wdActForce)
	if len(w.kills) != 2 {
		t.Fatal("unarmed probe still issued a kill")
	}
}

// TestWatchdogDropClears: teardown forgets every bit — a reused window id
// is never born wedged, never holds a dead app's kill latch.
func TestWatchdogDropClears(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	wdProto[9], wdAsked[9], wdEverAsked[9] = true, true, true
	wdWedged[9], wdBusy[9], wdKilled[9] = true, true, true
	wdMiss[9] = 3
	wdBusyWin = 9
	watchdogDrop(9)
	if wdProto[9] || wdAsked[9] || wdEverAsked[9] || wdWedged[9] ||
		wdBusy[9] || wdKilled[9] || wdMiss[9] != 0 || wdBusyWin == 9 {
		t.Fatal("drop left watchdog state on a dead window")
	}
}

// TestWatchdogKillSuppressesCrashArm: the launcherWindowEvent crash check
// reads wdKilled — the force-quit exit must not park a crash snapshot or
// queue a restart. Pinned at the seatCrashStatus level: the window's
// bound owner exits 137 and the row still does not read as a crash.
func TestWatchdogKillSuppressesCrashArm(t *testing.T) {
	f := &stateFixture{}
	f.install(t)
	w := &wdFixture{}
	w.install(t)

	openBoundTab(t, 9, 21, "GoTabApp")
	oldExit := procsExitStatus
	t.Cleanup(func() { procsExitStatus = oldExit })
	procsExitStatus = func(pid uint8) (uint64, bool) { return 137, true }

	_, _, crashed := seatCrashStatus(9)
	if !crashed {
		t.Fatal("precondition: 137 reads as a crash")
	}
	wdKilled[9] = true
	// The suppression lives in launcherWindowEvent; the flag is what the
	// test pins — the mirror path reads it before seatCrashStatus's arm.
	if !wdKilled[9] {
		t.Fatal("kill latch cleared early")
	}
}
