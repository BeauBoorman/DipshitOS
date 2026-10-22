package main

import (
	"testing"

	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
)

// The gate greps these exact strings; a drift is a host-test failure rather
// than a live run that silently asserts nothing.
func TestInteropMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{MarkerRpcDeclare, "gotabwm: rpc declare id="},
		{MarkerRpcRaise, "gotabwm: rpc raise id="},
		{MarkerRpcAttach, "gotabwm: rpc attach id="},
		{MarkerRpcDetach, "gotabwm: rpc detach id="},
		{MarkerRpcCycle, "gotabwm: rpc cycle"},
		{MarkerTitle, "gotabwm: title id="},
		{MarkerSettingsSubscribe, "gotabwm: settings subscribe pid="},
		{MarkerSettingsBroadcast, "gotabwm: settings broadcast key="},
		{MarkerRpcOther, "gotabwm: rpc other kind="},
		{MarkerRpcShort, "gotabwm: rpc short n="},
		{MarkerHostFocus, "gotabwm: host focus id="},
		{MarkerHostView, "gotabwm: host view id="},
		{MarkerHostClose, "gotabwm: host close id="},
		{MarkerHostDone, "gotabwm: host done"},
		{MarkerTabOpen, "gotabwm: tab open id="},
		{MarkerTabFocus, "gotabwm: tab focus id="},
		{MarkerTabClose, "gotabwm: tab close id="},
		{MarkerRail, "gotabwm: rail "},
		{MarkerTabsEmpty, "gotabwm: tabs empty"},
		{MarkerSplit, "gotabwm: split "},
		{MarkerUnsplit, "gotabwm: unsplit"},
		{MarkerLayout, "gotabwm: layout "},
		{MarkerLayoutFile, "gotabwm: layout file="},
		{MarkerPane, "gotabwm: pane "},
		{MarkerPin, "gotabwm: pin "},
		{MarkerReorder, "gotabwm: reorder "},
		{MarkerOrder, "gotabwm: order "},
		{MarkerAltTab, "gotabwm: alt-tab id="},
		{MarkerRailClick, "gotabwm: rail-click id="},
		{MarkerSessionWrite, "gotabwm: session write n="},
		{MarkerSessionLoad, "gotabwm: session load n="},
		{MarkerSessionTitles, "gotabwm: session titles="},
		{MarkerSessionBad, "gotabwm: session bad"},
		{MarkerSessionReexec, "gotabwm: session reexec n="},
		{MarkerSessionLive, "gotabwm: session live n="},
		{MarkerSessionDrop, "gotabwm: session drop "},
		{MarkerSessionExec, "gotabwm: session exec "},
		{MarkerDogfoodSeat, "dogfood: seat"},
		{MarkerDogfoodOK, "dogfood: ok"},
		{MarkerFirstBootWorkspace, "gotabwm: first-boot workspace"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// M69a (#1528): the dogfood latch. `dogfood: ok` hangs off it because the
// close choreography empties the strip BEFORE host-done, and it is the only
// record left that this boot hosted anything. A request the seat refuses must
// not latch it, or a boot that hosted nothing could still claim the beat.
func TestDogfoodHostedLatch(t *testing.T) {
	savedChrome := configureHostedChrome
	configureHostedChrome = func(uint32) bool { return true }
	defer func() { configureHostedChrome = savedChrome }()
	savedTabs, savedHosted, savedLatch := tabs, hostedApp, dogfoodHosted
	savedHostTicks, savedStep, savedHold := hostTicksLeft, stripStep, stripHoldLeft
	savedSawTwo, savedClosed, savedDone := stripSawTwo, stripClosedOne, stripDone
	defer func() {
		tabs, hostedApp, dogfoodHosted = savedTabs, savedHosted, savedLatch
		hostTicksLeft, stripStep, stripHoldLeft = savedHostTicks, savedStep, savedHold
		stripSawTwo, stripClosedOne, stripDone = savedSawTwo, savedClosed, savedDone
	}()
	tabs, hostedApp, dogfoodHosted = TabStrip{}, 0, false
	stripSawTwo, stripClosedOne, stripDone, stripStep, stripHoldLeft = false, false, false, 0, 0

	// A refused kind (raise with no registered window on the host) must not
	// latch the beat.
	if applyRPC(vi.WmRpc{Kind: vi.WmRpcKindRaise, ID: 9, Seq: 1}) {
		t.Fatal("raise applied on the host; the test proves nothing")
	}
	if dogfoodHosted {
		t.Fatal("a refused request latched dogfoodHosted")
	}

	req := vi.WmRpc{Kind: vi.WmRpcKindDeclareFullscreen, ID: 7, Seq: 1}
	req.SetTitle("Calc")
	if !applyRPC(req) {
		t.Fatal("declare refused")
	}
	if !dogfoodHosted {
		t.Fatal("declare did not latch dogfoodHosted: `dogfood: ok` could never print")
	}
}

func TestHostedChromePrecedesTabPublication(t *testing.T) {
	savedChrome, savedTabs := configureHostedChrome, tabs
	savedHosted, savedLatch, savedTicks := hostedApp, dogfoodHosted, hostTicksLeft
	savedStep, savedHold := stripStep, stripHoldLeft
	savedSawTwo, savedClosed, savedDone := stripSawTwo, stripClosedOne, stripDone
	defer func() {
		configureHostedChrome, tabs = savedChrome, savedTabs
		hostedApp, dogfoodHosted, hostTicksLeft = savedHosted, savedLatch, savedTicks
		stripStep, stripHoldLeft = savedStep, savedHold
		stripSawTwo, stripClosedOne, stripDone = savedSawTwo, savedClosed, savedDone
	}()
	for _, kind := range []uint8{vi.WmRpcKindDeclareFullscreen, vi.WmRpcKindAttachTab} {
		tabs, hostedApp, dogfoodHosted = TabStrip{}, 0, false
		calls := 0
		configureHostedChrome = func(id uint32) bool {
			calls++
			if id != 7 || tabs.index(id) >= 0 || dogfoodHosted {
				t.Fatal("tab published before its no-chrome descriptor")
			}
			return true
		}
		req := vi.WmRpc{Kind: kind, ID: 7}
		req.SetTitle("Gosh")
		if !applyRPC(req) || calls != 1 || tabs.index(7) < 0 {
			t.Fatal("successful chrome setup did not publish the hosted tab")
		}
		tabs, hostedApp, dogfoodHosted = TabStrip{}, 0, false
		configureHostedChrome = func(uint32) bool { return false }
		if applyRPC(req) || tabs.Count() != 0 || dogfoodHosted || hostedApp != 0 {
			t.Fatal("failed chrome setup published a hosted tab")
		}
	}
}

// Set-title is a strip mutation, not a rename of executable identity.
func TestApplySetTitlePreservesTabState(t *testing.T) {
	saved := tabs
	defer func() { tabs = saved }()
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "Notepad") {
		t.Fatal("OpenTab")
	}

	req := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 5}
	req.SetTitle("notes.txt")
	if !applyRPC(req) {
		t.Fatal("set-title request refused")
	}
	if tabs.At(0).Title != "notes.txt" || tabs.At(0).Bin != "NOTE.ELF" {
		t.Fatalf("set-title state = %+v", tabs.At(0))
	}
	if applyRPC(vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 99}) {
		t.Fatal("set-title accepted an unknown tab")
	}
	empty := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4}
	if applyRPC(empty) {
		t.Fatal("set-title accepted an empty title")
	}
}

// The ack MUST set the reply bit and mirror id/seq, or an unmodified Zig app
// ignores it and falls back to its legacy rect (the interop silently no-ops).
func TestBuildReplyWire(t *testing.T) {
	req := vi.WmRpc{Kind: vi.WmRpcKindDeclareFullscreen, ID: 7, Seq: 5, ReplyTo: 3}
	req.SetTitle("Calc")
	rep := buildReply(req, true, "", vi.WmRpcPadBound, 0x1122334455667788)
	if rep.Kind&vi.WmRpcReplyFlag == 0 {
		t.Fatalf("ack kind %#x lacks the reply bit", rep.Kind)
	}
	if rep.Kind&0x7f != vi.WmRpcKindDeclareFullscreen {
		t.Fatalf("ack kind %#x lost the request kind", rep.Kind)
	}
	if rep.ID != req.ID || rep.Seq != req.Seq {
		t.Fatalf("ack id/seq = %d/%d want %d/%d", rep.ID, rep.Seq, req.ID, req.Seq)
	}
	if rep.Applied != 1 {
		t.Fatalf("ack applied = %d want 1", rep.Applied)
	}
	if rep.ReplyTo != req.ReplyTo {
		t.Fatalf("ack reply_to = %d want %d", rep.ReplyTo, req.ReplyTo)
	}
	// The ack frame must survive the wire round-trip the app decodes.
	got, ok := vi.DecodeWmRpc(rep.Encode())
	if !ok || got.Kind != rep.Kind || got.ID != rep.ID || got.Seq != rep.Seq || got.Applied != 1 {
		t.Fatalf("ack round-trip = %+v ok=%v", got, ok)
	}
	if rep.Pad != vi.WmRpcPadBound || vi.WmAuth(rep) != 0x1122334455667788 {
		t.Fatalf("ack auth = pad %d union %#x", rep.Pad, vi.WmAuth(rep))
	}
	if rep2 := buildReply(req, false, "", vi.WmRpcPadPlain, 0); rep2.Applied != 0 {
		t.Fatalf("refused ack applied = %d want 0", rep2.Applied)
	}
	// M79e (#1708): a refused ack must NOT carry a nav payload even if one
	// is offered — a poll the seat refused has no target to hand over.
	if rep3 := buildReply(req, false, "/host/docs", vi.WmRpcPadPlain, 0); rep3.TitleString() != "" {
		t.Fatalf("refused ack carried a nav payload %q", rep3.TitleString())
	}
}

// A hosted app is closed after hostTicks ticks - the budget the composite loop
// counts down.
func TestHostTickBudget(t *testing.T) {
	if hostTicks <= 0 {
		t.Fatalf("hostTicks = %d: an app would never be closed", hostTicks)
	}
	if hostTicks < pointerClickHold {
		t.Fatalf("hostTicks %d < pointerClickHold %d: a click expires while hosted",
			hostTicks, pointerClickHold)
	}
	if hostTicks > maxTicks {
		t.Fatalf("hostTicks %d > maxTicks %d: the close is unreachable", hostTicks, maxTicks)
	}
	// Two-tab path: 1 tick to show n=2, reorder, pin+refocus, SplitV,
	// Unsplit, SplitH, Unsplit, close pinned, close last (9). Plus the
	// single-tab budget must still fit in maxTicks.
	const twoTabTicks = 9
	if hostTicks+hidChordHold+twoTabTicks > maxTicks {
		t.Fatalf("hostTicks %d + hidChordHold %d + two-tab choreography %d > maxTicks %d",
			hostTicks, hidChordHold, twoTabTicks, maxTicks)
	}
}

// The seat must not repaint the blank desktop while a tab is hosted, or the
// compose-N target (above the kernel's window layer) would overpaint the client.
func TestHostedSuppressesBlankPaint(t *testing.T) {
	savedTabs := tabs
	savedHosted := hostedApp
	defer func() {
		tabs = savedTabs
		hostedApp = savedHosted
	}()
	tabs = TabStrip{}
	hostedApp = 0
	if tabs.Count() != 0 {
		t.Fatal("strip should start empty")
	}
	if !tabs.OpenTab(9, "x") {
		t.Fatal("OpenTab")
	}
	hostedApp = 9
	if tabs.Count() == 0 || hostedApp == 0 {
		t.Fatal("hosted tab should be set")
	}
}

func TestLateOpenTabClearsStripDone(t *testing.T) {
	savedTabs := tabs
	savedDone, savedTwo, savedOne, savedStep := stripDone, stripSawTwo, stripClosedOne, stripStep
	defer func() {
		tabs = savedTabs
		stripDone, stripSawTwo, stripClosedOne, stripStep = savedDone, savedTwo, savedOne, savedStep
	}()

	tabs = TabStrip{}
	stripDone, stripSawTwo, stripClosedOne, stripStep = true, true, true, 4
	if !tabs.OpenTab(4, "late") {
		t.Fatal("OpenTab from empty")
	}
	noteStripOpen()
	if stripDone || stripSawTwo || stripClosedOne || stripStep != 0 {
		t.Fatalf("late OpenTab from empty left stripDone=%v sawTwo=%v closedOne=%v step=%d",
			stripDone, stripSawTwo, stripClosedOne, stripStep)
	}

	// A second tab on a live strip must not clear the two-tab latch.
	stripSawTwo = true
	if !tabs.OpenTab(5, "b") {
		t.Fatal("OpenTab second")
	}
	noteStripOpen()
	if !stripSawTwo {
		t.Fatal("OpenTab of a second tab cleared stripSawTwo")
	}

	// A no-op (duplicate) OpenTab must not reset either.
	stripDone = true
	if tabs.OpenTab(5, "b") {
		t.Fatal("duplicate OpenTab counted as added")
	}
	// applyRPC only calls noteStripOpen on added==true; pin that Count!=1
	// is what the helper uses when a second tab is already present.
	if tabs.Count() != 2 {
		t.Fatalf("count = %d want 2", tabs.Count())
	}
}

func TestAttachSyncsHostState(t *testing.T) {
	savedTabs := tabs
	savedHosted := hostedApp
	savedTicks := hostTicksLeft
	defer func() {
		tabs = savedTabs
		hostedApp = savedHosted
		hostTicksLeft = savedTicks
	}()

	tabs = TabStrip{}
	hostedApp = 0
	hostTicksLeft = 0
	if !tabs.OpenTab(7, "attached") {
		t.Fatal("OpenTab")
	}
	noteStripOpen()
	if !tabs.FocusTab(7) {
		t.Fatal("FocusTab")
	}
	hostedApp = 7
	hostTicksLeft = hostTicks
	if id, ok := tabs.Focused(); !ok || id != 7 || hostedApp != 7 || hostTicksLeft != hostTicks {
		t.Fatalf("attach sync: focus=%d ok=%v hosted=%d ticks=%d", id, ok, hostedApp, hostTicksLeft)
	}
}

// M79k (#1720): the kind-12 arm. The marker strings are gate grep targets,
// so a drift is a host-test failure rather than a live run that asserts
// nothing.
func TestNotifyMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{MarkerNotify, "gotabwm: notify id="},
		{MarkerNotifyDismiss, "gotabwm: notify dismiss id="},
		{MarkerNotifyDrop, "gotabwm: notify drop total="},
		{MarkerNotifyPaint, "gotabwm: notify paint id="},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// The arm's whole contract, on the host: a known sender's message is queued
// and accepted, an unknown sender's and an empty one are REFUSED with
// applied=0 (so the client's own ack is the honest answer), and the queue
// bound drops the oldest.
func TestApplyRpcNotify(t *testing.T) {
	resetNotify(t)
	savedTabs, savedStep, savedHold := tabs, stripStep, stripHoldLeft
	savedDone, savedCount := stripDone, hostTicksLeft
	t.Cleanup(func() {
		tabs, stripStep, stripHoldLeft = savedTabs, savedStep, savedHold
		stripDone, hostTicksLeft = savedDone, savedCount
	})
	tabs = TabStrip{}
	stripStep, stripHoldLeft, stripDone, hostTicksLeft = 0, 0, false, 0
	if !tabs.OpenTab(4, "files") {
		t.Fatal("OpenTab")
	}
	seatTick = 7
	compositeClock = 7

	if !applyRPC(navRPC(vi.WmRpcKindNotify, 4, "copied KNOWN.TXT")) {
		t.Fatal("a notify from a known tab must be applied")
	}
	if notifyCount() != 1 {
		t.Fatalf("queue depth = %d want 1", notifyCount())
	}
	e := notifyQueue[0]
	if e.tabID != 4 || e.text != "copied KNOWN.TXT" {
		t.Fatalf("queued entry = id %d %q", e.tabID, e.text)
	}
	// Born at the composite pass the seat last ran, so the lifetime is
	// measured in paints that actually happened (#2730: composites are
	// deferred behind input inside a drain — heartbeat count is not the
	// paint clock).
	if e.born != compositeClock || e.expires != compositeClock+NotifyTicks {
		t.Fatalf("entry lifetime = [%d,%d) want [%d,%d)",
			e.born, e.expires, compositeClock, compositeClock+NotifyTicks)
	}
	if applyRPC(navRPC(vi.WmRpcKindNotify, 99, "ghost")) {
		t.Error("a notify from an UNKNOWN tab must be refused (applied=0)")
	}
	if applyRPC(navRPC(vi.WmRpcKindNotify, 4, "")) {
		t.Error("an empty message must be refused (applied=0)")
	}
	if notifyCount() != 1 {
		t.Fatalf("a refused notify queued something: depth = %d", notifyCount())
	}
	// The bound: one more push than the queue is deep evicts the oldest
	// and COUNTS it. Two drops in total — the one above made the depth 5,
	// and the 5th flood push is the one that overflows NotifyMax=4.
	for i := 0; i < NotifyMax+1; i++ {
		if !applyRPC(navRPC(vi.WmRpcKindNotify, 4, "flood")) {
			t.Fatalf("flood push %d was refused", i)
		}
	}
	if notifyCount() != NotifyMax {
		t.Fatalf("depth after the flood = %d want NotifyMax", notifyCount())
	}
	if wantDrops := 1 + 1; notifyDropped != wantDrops {
		t.Fatalf("notifyDropped = %d want %d (the first toast, plus the one the flood evicted)",
			notifyDropped, wantDrops)
	}
}

func TestSettingsSubscribeAndBroadcastDispatch(t *testing.T) {
	savedTabs := tabs
	savedLoad, savedSend := loadSettingsForBus, sendSettingsNotice
	savedSubs := settingsSubscriptions
	savedValues := settingsBusValues
	savedTheme := theme.Current
	t.Cleanup(func() {
		tabs = savedTabs
		loadSettingsForBus, sendSettingsNotice = savedLoad, savedSend
		settingsSubscriptions = savedSubs
		settingsBusValues = savedValues
		theme.Current = savedTheme
	})
	tabs = TabStrip{}
	resetSettingsSubscriptions()
	if !tabs.OpenTab(4, "calc") || !tabs.OpenTab(5, "settings") {
		t.Fatal("open subscriber and publisher tabs")
	}

	var target uint32
	var sent vi.WmRpc
	sendSettingsNotice = func(pid uint32, body []byte) int64 {
		target = pid
		var ok bool
		sent, ok = vi.DecodeWmRpc(body)
		if !ok {
			t.Fatal("invalid event frame")
		}
		return int64(len(body))
	}
	req := vi.WmRpc{Kind: vi.WmRpcKindSettingsSubscribe, ID: 4, ReplyTo: 77}
	req.SetTitle("theme")
	if !applyRPC(req) {
		t.Fatal("valid subscription refused")
	}
	if !applyRPC(req) {
		t.Fatal("repeated subscription should be idempotent")
	}
	if got := countSettingsSubscriptions(); got != 1 {
		t.Fatalf("subscription count = %d, want 1", got)
	}

	loadSettingsForBus = func() settings.File {
		return settings.File{State: settings.StateOK, Rows: []settings.Setting{{Key: "theme", Val: "light"}}}
	}
	seedSettingsBusValues(settings.File{State: settings.StateOK, Rows: []settings.Setting{{Key: "theme", Val: "dark"}}})
	publish := vi.WmRpc{Kind: vi.WmRpcKindSettingsPublish, ID: 5, ReplyTo: 88}
	publish.SetTitle("theme")
	if !applyRPC(publish) {
		t.Fatal("valid published setting refused")
	}
	if target != 77 || sent.Kind != vi.WmRpcKindSettingsChanged ||
		sent.ID != 4 || sent.ReplyTo != 0 || sent.TitleString() != "theme" {
		t.Fatalf("broadcast target=%d frame=%+v title=%q", target, sent, sent.TitleString())
	}

	bad := vi.WmRpc{Kind: vi.WmRpcKindSettingsPublish, ID: 5, ReplyTo: 88}
	bad.SetTitle("not_a_key")
	if applyRPC(bad) {
		t.Fatal("unknown setting publish applied")
	}
	if applyRPC(publish) {
		t.Fatal("duplicate publish was broadcast as a second change")
	}
	if !tabs.CloseTab(4) {
		t.Fatal("close subscriber tab")
	}
	if got := countSettingsSubscriptions(); got != 0 {
		t.Fatalf("subscriptions after close = %d, want 0", got)
	}
}

func countSettingsSubscriptions() int {
	n := 0
	for _, s := range settingsSubscriptions {
		if s.active {
			n++
		}
	}
	return n
}

// Closing a tab takes its toasts with it, through the same CloseTab choke
// point every close path uses (the M79e clearPendingNav rule).
func TestClosingTheSenderDropsItsToasts(t *testing.T) {
	resetNotify(t)
	savedTabs := tabs
	t.Cleanup(func() { tabs = savedTabs })
	tabs = TabStrip{}
	tabs.OpenTab(4, "a")
	tabs.OpenTab(5, "b")
	notifyPush(4, "from four", 0)
	notifyPush(5, "from five", 0)
	if !tabs.CloseTab(4) {
		t.Fatal("CloseTab")
	}
	if notifyCount() != 1 || notifyQueue[0].tabID != 5 {
		t.Fatalf("after closing tab 4 the strip holds %d entries, want tab 5's only", notifyCount())
	}
}

// #3053: a sub-38-byte post is one malformed frame, not end-of-queue. The
// pre-fix seat returned on the first short frame, so a [short, valid…]
// mailbox served one request per pass — 1 Hz when the tick is 1 s. Now the
// pass drains past it and the per-pass count lands on the console once.
func TestServiceRPCShortFrameDoesNotEndPass(t *testing.T) {
	savedTabs := tabs
	t.Cleanup(func() { tabs = savedTabs })
	tabs = TabStrip{}
	if !tabs.OpenTab(4, "x") {
		t.Fatal("OpenTab")
	}
	stubAuthSeams(t, func(uint8) (string, bool) { return "", false })

	req := vi.WmRpc{Kind: vi.WmRpcKindSetTitle, ID: 4, Seq: 1, ReplyTo: 3}
	req.SetTitle("pwned")
	frames := [][]byte{
		{1, 2, 3, 4, 5}, // short: under the wire size, must not end the pass
		req.Encode(),    // valid request — still answered in the same pass
		{9, 9},          // a second short
	}
	var ackBytes [][]byte
	next := 0
	prev := vi.SetSyscallHookForTest(func(num, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case vi.SlotIPCRecv:
			if next >= len(frames) {
				return 0
			}
			frame := frames[next]
			next++
			copy(hookBuf(a0, a1), frame)
			return int64(len(frame))
		case vi.SlotIPCSend:
			ack := make([]byte, a2)
			copy(ack, hookBuf(a1, a2))
			ackBytes = append(ackBytes, ack)
			return int64(a2)
		}
		return -vi.ErrENOSYS
	})
	t.Cleanup(func() { vi.SetSyscallHookForTest(prev) })

	served := serviceRPC()
	if served != 1 {
		t.Fatalf("served = %d want 1 (short frames must not end the pass)", served)
	}
	if len(ackBytes) != 1 {
		t.Fatalf("acks = %d want 1", len(ackBytes))
	}
	if next != len(frames) {
		t.Fatalf("drained %d of %d queued frames", next, len(frames))
	}
}
