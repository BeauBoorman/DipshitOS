package main

import (
	"testing"

	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
)

// The gate greps these exact strings; a drift is a host-test failure rather
// than a live run that silently asserts nothing.
func TestMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{MarkerRegistered, "gotabwm: registered"},
		{MarkerSeatTaken, "gotabwm: seat-taken"},
		{MarkerScanout, "gotabwm: scanout"},
		{MarkerDraw, "gotabwm: draw"},
		{MarkerHolding, "gotabwm: holding seat"},
		{MarkerTick, "gotabwm: tick"},
		{MarkerPtr, "gotabwm: ptr"},
		{MarkerKey, "gotabwm: key"},
		{MarkerPresent, "gotabwm: present"},
		{MarkerClose, "gotabwm: close"},
		{MarkerOK, "gotabwm OK"},
		{MarkerModeDemo, "gotabwm: mode demo"},
		{MarkerModeLive, "gotabwm: mode live"},
		{MarkerLiveSteady, "gotabwm: live steady "},
		{MarkerAltTab, "gotabwm: alt-tab id="},
		{MarkerRailClick, "gotabwm: rail-click id="},
		{MarkerTokens, "gotabwm: tokens "},
		{MarkerLaunchOpen, "gotabwm: launcher open n="},
		{MarkerLaunchFilter, "gotabwm: launcher filter q="},
		{MarkerLaunchExec, "gotabwm: launcher exec "},
		{MarkerLaunchDismiss, "gotabwm: launcher dismiss"},
		{MarkerLaunchMissing, "gotabwm: launcher missing "},
		{MarkerRestoreWitness, "gotabwm: restore witness "},
		{MarkerIdleDim, "gotabwm: idle dim"},
		{MarkerIdleLock, "gotabwm: idle lock"},
		{MarkerIdleWake, "gotabwm: idle wake"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

func TestIdleThresholdsAndInputWake(t *testing.T) {
	savedAfter, savedLast := idleAfter, lastInputTick
	savedState, savedPresented, savedWake := idleState, idlePresented, idleWakePending
	savedTick := seatTick
	defer func() {
		idleAfter, lastInputTick = savedAfter, savedLast
		idleState, idlePresented, idleWakePending = savedState, savedPresented, savedWake
		seatTick = savedTick
	}()
	configureIdle(settings.File{Rows: []settings.Setting{{Key: "idle_minutes", Val: "1"}}, State: settings.StateOK}, 2)
	if idleAfter != 2 {
		t.Fatalf("seeded threshold = %d ticks, want 2", idleAfter)
	}
	idleAdvance(1)
	if idleState != idleActive {
		t.Fatal("dimmed before the first threshold")
	}
	idleAdvance(2)
	if idleState != idleDim {
		t.Fatal("failed to dim at the first threshold")
	}
	idlePresentedFrame(true)
	idleAdvance(3)
	if idleState != idleDim {
		t.Fatal("left dim before the lock threshold")
	}
	idleAdvance(4)
	if idleState != idleCurtain {
		t.Fatal("failed to curtain at twice the threshold")
	}
	idlePresentedFrame(true)
	seatTick = 4
	if consumeSeatEvent(vi.Event{Kind: vi.EvWmKey, Arg0: 0}) || idleState != idleActive {
		// consumeSeatEvent returns false for input, including the waking edge.
		t.Fatal("keyboard wake failed")
	}
	idlePresentedFrame(true)
	if idleWakePending || lastInputTick != 4 {
		t.Fatalf("wake pending=%v last=%d", idleWakePending, lastInputTick)
	}
	idleAdvance(5)
	if idleState != idleActive {
		t.Fatal("re-dimmed before another complete threshold")
	}
	idleAdvance(6)
	if idleState != idleDim {
		t.Fatal("did not resume the idle clock from the waking input")
	}
	seatTick = 6
	if consumeSeatEvent(vi.Event{Kind: vi.EvWmPointer}) || idleState != idleActive || lastInputTick != 6 {
		t.Fatal("pointer wake failed")
	}
}

func TestIdleInvalidSettingFallsBackToFiveMinutes(t *testing.T) {
	savedAfter := idleAfter
	defer func() { idleAfter = savedAfter }()
	configureIdle(settings.File{Rows: []settings.Setting{{Key: "idle_minutes", Val: "0"}}, State: settings.StateOK}, 60)
	if idleAfter != 300 {
		t.Fatalf("invalid idle threshold = %d, want default 300 ticks", idleAfter)
	}
}

func TestRestoreWitnessCapturesResumedSeatState(t *testing.T) {
	oldTabs, oldTheme, oldWM := tabs, theme.Current, restoreSettingsWM
	oldEcho := sessionEcho
	defer func() {
		tabs, theme.Current, restoreSettingsWM = oldTabs, oldTheme, oldWM
		sessionEcho = oldEcho
	}()
	tabs = TabStrip{}
	if !tabs.OpenTab(sessionIDBase, "Notes") || !tabs.OpenTab(sessionIDBase+1, "Calc") {
		t.Fatal("restore witness fixture tabs")
	}
	if !tabs.FocusTab(sessionIDBase + 1) {
		t.Fatal("focus restored active tab")
	}
	tabs.tabs[0].Pinned = true
	// M120b (#2559): the witness reports the session FILE's echo, captured
	// at load — not the live strip, which the re-exec fan-out now mutates.
	sessionEcho = sessionTitlesLine(&tabs)
	restoreSettingsWM = "gotabwm"
	if !theme.Set("light") {
		t.Fatal("select light theme")
	}
	const want = "gotabwm: restore witness wm=gotabwm theme=light file=wake-fuse-ok Notes,Calc pin=1,0 active=1"
	if got := restoreWitnessLine(); got != want {
		t.Fatalf("restore witness = %q want %q", got, want)
	}
}

func TestBlankColourIs24Bit(t *testing.T) {
	if blankRGB()&0xFF000000 != 0 {
		t.Fatalf("blankRGB %#x sets the X byte; the scanout is B8G8R8X8", blankRGB())
	}
	if blankRGB() != theme.Current.Bg {
		t.Fatalf("blankRGB %#x want theme.Bg %#x", blankRGB(), theme.Current.Bg)
	}
}

func TestLoopBounds(t *testing.T) {
	if maxTicks <= 0 {
		t.Fatalf("maxTicks = %d: an unbounded loop can hang a boot", maxTicks)
	}
	if maxEvents < maxTicks {
		t.Fatalf("maxEvents %d < maxTicks %d: the tick bound is unreachable", maxEvents, maxTicks)
	}
	if pointerClickHold < 8 {
		t.Fatalf("pointerClickHold = %d: a 3×2.5s click does not fit", pointerClickHold)
	}
	if pointerDragHold < 12 {
		t.Fatalf("pointerDragHold = %d: a 4×2.5s drag does not fit", pointerDragHold)
	}
	if hidChordHold < pointerDragHold {
		t.Fatalf("hidChordHold = %d: a rail drag plus chords do not fit before auto-pin", hidChordHold)
	}
	if maxTicks < pointerClickHold {
		t.Fatalf("maxTicks %d < pointerClickHold %d: a click expires mid-sequence", maxTicks, pointerClickHold)
	}
	if maxTicks < hidChordHold {
		t.Fatalf("maxTicks %d < hidChordHold %d: chords expire mid-sequence", maxTicks, hidChordHold)
	}
}

// paintBlank must fill EVERY pixel (a partial fill is the "frame is right on
// one half" bug), and must ignore a trailing sub-pixel remainder. The scanout
// is B,G,R,X and paintBlank forces X opaque (M71c #1562: a 6-hex token leaves
// X=0, which the host display honours as alpha and hides every seat pixel), so
// a 6-hex token comes back with 0xff in the top byte.
func TestPaintBlankFillsEveryPixel(t *testing.T) {
	const pix = 1024
	const token = 0x112233
	const want = token | 0xff000000
	buf := make([]byte, pix*4)
	if got := paintBlank(buf, token); got != pix {
		t.Fatalf("paintBlank returned %d want %d", got, pix)
	}
	for i := 0; i < pix; i++ {
		v := uint32(buf[i*4]) | uint32(buf[i*4+1])<<8 | uint32(buf[i*4+2])<<16 | uint32(buf[i*4+3])<<24
		if v != want {
			t.Fatalf("pixel %d = %#x want %#x (opaque X)", i, v, want)
		}
	}
}

func TestPaintBlankEdgeCases(t *testing.T) {
	if got := paintBlank(nil, 1); got != 0 {
		t.Fatalf("paintBlank(nil) = %d want 0", got)
	}
	if got := paintBlank(make([]byte, 3), 1); got != 0 {
		t.Fatalf("paintBlank(3 bytes) = %d want 0 (no whole pixel)", got)
	}
	if got := paintBlank(make([]byte, 6), 1); got != 1 {
		t.Fatalf("paintBlank(6 bytes) = %d want 1", got)
	}
}

// hidMarker logs ptr/key only for real WM input-seam kinds — never for an
// empty poll (kind 0), a composite tick, a window mirror, or app-side
// MOUSE_*/KEY_* events (the ignore-non-tick regression).
func TestHidMarkerOnlyAfterRealEvent(t *testing.T) {
	if hidMarker(vi.EvWmPointer) != MarkerPtr {
		t.Fatalf("kind 19 marker = %q want %q", hidMarker(vi.EvWmPointer), MarkerPtr)
	}
	if hidMarker(vi.EvWmKey) != MarkerKey {
		t.Fatalf("kind 21 marker = %q want %q", hidMarker(vi.EvWmKey), MarkerKey)
	}
	zeros := []uint16{0, vi.EvCompositeTick, vi.EvWmWindow, vi.EvKeyDown, vi.EvMouseMove, vi.EvWinFocus}
	for _, k := range zeros {
		if m := hidMarker(k); m != "" {
			t.Fatalf("hidMarker(%d) = %q: empty polls / non-HID kinds must not log ptr/key", k, m)
		}
	}
}

func TestDrainSeatEventsConsumesWholeBurstInArrivalOrder(t *testing.T) {
	queue := []vi.Event{
		{Kind: vi.EvWmKey, Arg0: 2},
		{Kind: vi.EvCompositeTick},
	}
	var got []uint32
	ticks := 0
	consume := func(e vi.Event) bool {
		if e.Kind == vi.EvWmKey {
			got = append(got, e.Arg0)
			return false
		}
		return e.Kind == vi.EvCompositeTick
	}
	onTick := func() bool {
		ticks++
		return true
	}
	poll := func() (vi.Event, bool) {
		if len(queue) == 0 {
			return vi.Event{}, false
		}
		e := queue[0]
		queue = queue[1:]
		return e, true
	}
	if n := drainSeatEvents(vi.Event{Kind: vi.EvWmKey, Arg0: 1}, poll, consume, 10, nil, onTick, nil); n != 3 {
		t.Fatalf("drained %d events, want 3", n)
	}
	if len(got) != 2 || got[0] != 1 || got[1] != 2 {
		t.Fatalf("key order = %v, want [1 2]", got)
	}
	if ticks != 1 {
		t.Fatalf("composite ticks = %d, want 1", ticks)
	}
}

func TestDrainSeatEventsStopsAtTickLimit(t *testing.T) {
	queue := []vi.Event{{Kind: vi.EvWmKey, Arg0: 1}}
	poll := func() (vi.Event, bool) {
		if len(queue) == 0 {
			return vi.Event{}, false
		}
		e := queue[0]
		queue = queue[1:]
		return e, true
	}
	consume := func(e vi.Event) bool { return e.Kind == vi.EvCompositeTick }
	onTick := func() bool { return false }
	flushes := 0
	flush := func() { flushes++ }
	if n := drainSeatEvents(vi.Event{Kind: vi.EvCompositeTick}, poll, consume, 10, nil, onTick, flush); n != 1 {
		t.Fatalf("drained %d events after tick-limit refusal, want 1", n)
	}
	if len(queue) != 1 {
		t.Fatalf("queue changed after tick-limit refusal: %d events remain", len(queue))
	}
	// The stop edge still offers the owed paint once — the live closure
	// decides whether the refused heartbeat actually owed a frame.
	if flushes != 1 {
		t.Fatalf("flushes on the stop edge = %d, want 1", flushes)
	}
}

// #2730: the composite a heartbeat owes is deferred behind the input that
// queued behind it — one flush pays however many ticks the batch held, and
// it lands after every queued event, not at the tick's own position.
func TestDrainSeatEventsDefersPaintBehindQueuedInput(t *testing.T) {
	queue := []vi.Event{
		{Kind: vi.EvWmKey, Arg0: 2},
		{Kind: vi.EvCompositeTick},
		{Kind: vi.EvWmKey, Arg0: 3},
		{Kind: vi.EvCompositeTick},
	}
	var order []string
	poll := func() (vi.Event, bool) {
		if len(queue) == 0 {
			return vi.Event{}, false
		}
		e := queue[0]
		queue = queue[1:]
		return e, true
	}
	consume := func(e vi.Event) bool {
		if e.Kind == vi.EvCompositeTick {
			return true
		}
		order = append(order, "key"+vi.Itoa64(int64(e.Arg0)))
		return false
	}
	onTick := func() bool {
		order = append(order, "tick")
		return true
	}
	flush := func() { order = append(order, "flush") }
	first := vi.Event{Kind: vi.EvWmKey, Arg0: 1}
	if n := drainSeatEvents(first, poll, consume, 10, nil, onTick, flush); n != 5 {
		t.Fatalf("drained %d events, want 5", n)
	}
	want := []string{"key1", "key2", "tick", "key3", "tick", "flush"}
	if len(order) != len(want) {
		t.Fatalf("drain order = %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("drain order = %v, want %v", order, want)
		}
	}
}

// #2730: a paint owed behind a stream that never quiets is paid once per
// drainPaintStride events — the input keeps its lead, the scanout keeps a
// bounded cadence, and no gratuitous flush runs at the drain's tail.
func TestDrainSeatEventsPaysOwedPaintAtStride(t *testing.T) {
	queue := make([]vi.Event, 0, drainPaintStride+4)
	for i := 0; i < drainPaintStride+4; i++ {
		queue = append(queue, vi.Event{Kind: vi.EvWmKey, Arg0: uint32(i)})
	}
	poll := func() (vi.Event, bool) {
		if len(queue) == 0 {
			return vi.Event{}, false
		}
		e := queue[0]
		queue = queue[1:]
		return e, true
	}
	consume := func(e vi.Event) bool { return e.Kind == vi.EvCompositeTick }
	onTick := func() bool { return true }
	flushes := 0
	flush := func() { flushes++ }
	n := drainSeatEvents(vi.Event{Kind: vi.EvCompositeTick}, poll, consume, maxEvents, nil, onTick, flush)
	if n != drainPaintStride+5 {
		t.Fatalf("drained %d events, want %d", n, drainPaintStride+5)
	}
	if flushes != 1 {
		t.Fatalf("owed-paint flushes = %d, want 1 (one mid-drain pay, nothing owed at the tail)", flushes)
	}
}

// #2730: the mailbox is serviced every drainServiceStride events inside the
// drain — a deep queue cannot park a WM_RPC past its bounded-poll window.
func TestDrainSeatEventsServicesMailboxAtStride(t *testing.T) {
	const nkeys = 21
	queue := make([]vi.Event, 0, nkeys)
	for i := 0; i < nkeys; i++ {
		queue = append(queue, vi.Event{Kind: vi.EvWmKey, Arg0: uint32(i)})
	}
	poll := func() (vi.Event, bool) {
		if len(queue) == 0 {
			return vi.Event{}, false
		}
		e := queue[0]
		queue = queue[1:]
		return e, true
	}
	consume := func(e vi.Event) bool { return e.Kind == vi.EvCompositeTick }
	services := 0
	service := func() { services++ }
	if n := drainSeatEvents(vi.Event{Kind: vi.EvWmKey, Arg0: 0}, poll, consume, maxEvents, service, nil, nil); n != nkeys+1 {
		t.Fatalf("drained %d events, want %d", n, nkeys+1)
	}
	// 22 events at stride 8: probes at event 8 and 16.
	if want := (nkeys + 1) / drainServiceStride; services != want {
		t.Fatalf("mid-drain services = %d, want %d", services, want)
	}
}

func TestSweepHostedStopsWhenCloseFails(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()

	tabs = TabStrip{}
	if !tabs.OpenTab(4, "web") || !tabs.OpenTab(5, "calc") {
		t.Fatal("OpenTab")
	}
	calls := 0
	sweepHosted(func() bool {
		calls++
		return false
	})
	if calls != 1 {
		t.Fatalf("close calls = %d, want 1 after failed close", calls)
	}
	if tabs.Count() != 2 {
		t.Fatalf("tabs after failed close = %d, want 2", tabs.Count())
	}
}

func TestSweepHostedDiscardsRestoredPlaceholders(t *testing.T) {
	savedTabs := tabs
	defer func() { tabs = savedTabs }()

	tabs = TabStrip{}
	if !tabs.OpenTab(sessionIDBase, "restored") || !tabs.OpenTab(4, "live") {
		t.Fatal("OpenTab")
	}
	calls := 0
	sweepHosted(func() bool {
		calls++
		id, ok := tabs.Focused()
		if !ok {
			return false
		}
		return tabs.CloseTab(id)
	})
	if calls != 1 {
		t.Fatalf("close calls = %d, want 1 live close", calls)
	}
	if tabs.Count() != 0 {
		t.Fatalf("tabs after sweep = %d, want 0", tabs.Count())
	}
}

func TestConsumeSeatEventIgnoreNonTick(t *testing.T) {
	savedBtn := prevPtrButtons
	savedDrag := railDragFrom
	defer func() {
		prevPtrButtons = savedBtn
		railDragFrom = savedDrag
	}()
	prevPtrButtons = 0
	railDragFrom = -1
	if !consumeSeatEvent(vi.Event{Kind: vi.EvCompositeTick}) {
		t.Fatal("kind 18 must count as a tick")
	}
	// Pointer and key are drained (not ticks). consumeSeatEvent logs via
	// ConsoleLine; on the host that degrades to ENOSYS and does not panic.
	if consumeSeatEvent(vi.Event{Kind: vi.EvWmPointer}) {
		t.Fatal("kind 19 must not count as a tick")
	}
	if consumeSeatEvent(vi.Event{Kind: vi.EvWmKey}) {
		t.Fatal("kind 21 must not count as a tick")
	}
	if consumeSeatEvent(vi.Event{Kind: vi.EvWmWindow}) {
		t.Fatal("kind 20 must not count as a tick")
	}
	if consumeSeatEvent(vi.Event{}) {
		t.Fatal("empty event must not count as a tick")
	}
	if consumeSeatEvent(vi.Event{Kind: vi.EvWinFocus}) {
		t.Fatal("WIN_FOCUS must stay on the ignore-non-tick path")
	}
	if consumeSeatEvent(vi.Event{Kind: vi.EvMouseMove}) {
		t.Fatal("app MOUSE_MOVE must stay on the ignore-non-tick path")
	}
}

// M79a (#1704): the demo trigger is a bare PRESENCE probe of
// /host/GOTABWM.DEMO through the openFile seam -- found -> demo, any open
// error (including the host's -ENOSYS) -> live. Content is irrelevant.
func TestDetectDemoIsPresenceProbe(t *testing.T) {
	saved := openFile
	defer func() { openFile = saved }()

	openFile = func(path string, flags uint32) (int64, int64) {
		if path != demoTriggerPath {
			t.Fatalf("probe path = %q want %q", path, demoTriggerPath)
		}
		return 7, 0
	}
	if !detectDemo() {
		t.Fatal("a found trigger must select demo mode")
	}
	openFile = func(path string, flags uint32) (int64, int64) { return -1, -2 }
	if detectDemo() {
		t.Fatal("an absent trigger (open refused) must leave live mode")
	}
}

// M79a (#1704): in live mode the seat never choreographs and never
// auto-closes -- two composite ticks of proof per behavior, with the demo
// path as the control that still arms.
func TestLiveModeNeverChoreographs(t *testing.T) {
	savedTabs := tabs
	savedDemo := demoMode
	savedSaw := stripSawTwo
	savedStep := stripStep
	savedOne := stripClosedOne
	savedDone := stripDone
	savedHold := stripHoldLeft
	savedCount := hostTicksLeft
	savedLaunch := launch
	defer func() {
		tabs = savedTabs
		demoMode = savedDemo
		stripSawTwo = savedSaw
		stripStep = savedStep
		stripClosedOne = savedOne
		stripDone = savedDone
		stripHoldLeft = savedHold
		hostTicksLeft = savedCount
		// syncSeatChrome names the host's failed WinOpen in launch.err
		// every live tick; hand the launcher state back (#2545).
		launch = savedLaunch
	}()

	scan := make([]byte, vi.ScanoutWidth*vi.ScanoutHeight*4)
	presents := 0

	// Live, two tabs: no reorder/pin/split choreography arms, nothing closes.
	demoMode = false
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "a") || !tabs.OpenTab(5, "b") {
		t.Fatal("OpenTab")
	}
	stripSawTwo, stripStep, stripDone = false, 0, false
	hostTicksLeft = 3
	for i := 1; i <= 3; i++ {
		compositeTick(scan, uint64(i), &presents)
	}
	if stripSawTwo || stripStep != 0 || stripDone {
		t.Fatalf("live mode armed the choreography: sawTwo=%v step=%d done=%v", stripSawTwo, stripStep, stripDone)
	}
	if tabs.Count() != 2 {
		t.Fatalf("live mode closed tabs: count = %d want 2", tabs.Count())
	}
	if hostTicksLeft != 3 {
		t.Fatalf("live mode ran the hostTicks countdown: %d want 3", hostTicksLeft)
	}

	// Demo (control): the same strip arms the choreography exactly as before.
	demoMode = true
	stripSawTwo, stripStep, stripDone, stripHoldLeft = false, 0, false, 0
	compositeTick(scan, 1, &presents)
	if !stripSawTwo {
		t.Fatal("demo mode must still arm the two-tab choreography")
	}
	if stripStep != 0 {
		t.Fatalf("choreography advanced before its hold expired: step=%d", stripStep)
	}

	// Demo, one tab: the single-tab countdown still runs (the control).
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "a") {
		t.Fatal("OpenTab")
	}
	stripSawTwo, stripDone = false, false
	hostTicksLeft = 1
	compositeTick(scan, 2, &presents)
	if hostTicksLeft != 0 {
		t.Fatalf("demo mode skipped the hostTicks countdown: %d want 0", hostTicksLeft)
	}
	if !stripDone {
		t.Fatal("demo mode must still close the countdown tab at zero")
	}
}

// #2703: the demo run budget follows observed activity — an idle boot
// still exits at maxTicks, activity past it re-arms the exit to
// lastActivity + demoTeardownHold, and the cap binds a stream that never
// quiets.
func TestDemoTickLimit(t *testing.T) {
	saved := lastActivityTick
	defer func() { lastActivityTick = saved }()

	lastActivityTick = 0
	if got := demoTickLimit(maxTicks, maxTicks*2); got != maxTicks {
		t.Fatalf("no activity must keep the base budget: %d", got)
	}
	// Activity while the base window is still open does nothing — the
	// boot was never at risk.
	lastActivityTick = 40
	if got := demoTickLimit(maxTicks, maxTicks*2); got != maxTicks {
		t.Fatalf("early activity must not shrink the base budget: %d", got)
	}
	// Activity past the window re-arms to lastActivity + the hold.
	lastActivityTick = 118
	if got := demoTickLimit(maxTicks, maxTicks*2); got != 118+demoTeardownHold {
		t.Fatalf("late activity must extend the budget: %d want %d",
			got, 118+demoTeardownHold)
	}
	// The cap binds a stream that never quiets.
	lastActivityTick = 500
	if got := demoTickLimit(maxTicks, maxTicks*2); got != maxTicks*2 {
		t.Fatalf("a never-quiet stream must hit the cap: %d", got)
	}
}
