// notify_test.go — M79k (#1720): host tests for the notify strip's pure half.
//
// These run on the host (`go test ./gotabwm`), so they may not call any `vi`
// guest syscall. The queue, the fade ramp, the rect and the hit test are
// plain Go values and a caller's scanout slice; the two marker-printing
// paths (notifyTick, clearNotify) are only reached through pure helpers
// here, so a drift in the bounds or the geometry fails on the host instead
// of as a missing line in a serial log.
package main

import (
	"testing"

	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
)

// resetNotify empties the strip between cases (the seat never runs two
// boots in one process, so there is no production reset to reuse).
func resetNotify(t *testing.T) {
	t.Helper()
	saved := notifyQueue
	savedDropped := notifyDropped
	savedTick := seatTick
	savedPainted := notifyPainted
	savedCenter := notifyCenter
	savedCenterOpen := notifyCenterOpen
	savedCenterPainted := notifyCenterPainted
	savedCenterNextID := notifyCenterNextID
	savedFocusNotifySource := focusNotifySource
	savedDND := notifyDND
	savedHistDirty := notifyHistDirty
	savedHistFailLogged := notifyHistFailLogged
	savedSaveDND, savedRead, savedWrite := saveNotifyDND, readNotifyFile, writeNotifyFile
	savedHistPath, savedDataRoot := notifyHistoryPath, notifyDataRoot
	savedSoundChime := notifySoundChime
	savedSoundParams := notifySoundParams
	savedSoundPending := notifySoundPending
	savedSoundBytes := notifySoundBytes
	savedSoundSkipped := notifySoundSkipped
	savedPlayChime := notifyPlayChime
	savedBusValues := settingsBusValues
	// M82d2 (#1785): the policy's three file seams degrade to ENOSYS on the
	// host, so every case starts with inert ones (a test that cares swaps in
	// a fake through fakeNotifyShare). M99d: the sound state resets beside
	// them — the chime buffer, the in-flight stream, the skip counter, the
	// play seam and the bus value the chime switch reads.
	notifyDND = false
	notifyHistDirty = false
	notifyHistFailLogged = false
	saveNotifyDND = func(bool) bool { return true }
	readNotifyFile = func(string, int) ([]byte, int64) { return nil, -1 }
	writeNotifyFile = func(string, []byte) bool { return true }
	// M100f (#2311): the history path and its resolver reset beside the file
	// seams — a test's /disk answer must never leak into the next case.
	notifyHistoryPath = "/host/NOTIFY.HIST"
	notifyDataRoot = func(f settings.File) (string, bool) { return f.ResolveDataRoot() }
	notifySoundChime = nil
	notifySoundParams = vi.AudioStreamParams{}
	notifySoundPending = nil
	notifySoundBytes = 0
	notifySoundSkipped = 0
	notifyPlayChime = playNotifyChime
	for i := range settingsBusValues {
		settingsBusValues[i] = settingValue{}
	}
	notifyQueue = nil
	notifyDropped = 0
	notifyPainted = false
	seatTick = 0
	notifyCenter = nil
	notifyCenterOpen = false
	notifyCenterPainted = false
	notifyCenterNextID = 0
	focusNotifySource = focusHosted
	t.Cleanup(func() {
		notifyQueue = saved
		notifyDropped = savedDropped
		notifyPainted = savedPainted
		seatTick = savedTick
		notifyCenter = savedCenter
		notifyCenterOpen = savedCenterOpen
		notifyCenterPainted = savedCenterPainted
		notifyCenterNextID = savedCenterNextID
		focusNotifySource = savedFocusNotifySource
		notifyDND = savedDND
		notifyHistDirty = savedHistDirty
		notifyHistFailLogged = savedHistFailLogged
		saveNotifyDND, readNotifyFile, writeNotifyFile = savedSaveDND, savedRead, savedWrite
		notifyHistoryPath, notifyDataRoot = savedHistPath, savedDataRoot
		notifySoundChime = savedSoundChime
		notifySoundParams = savedSoundParams
		notifySoundPending = savedSoundPending
		notifySoundBytes = savedSoundBytes
		notifySoundSkipped = savedSoundSkipped
		notifyPlayChime = savedPlayChime
		settingsBusValues = savedBusValues
	})
}

// TestNotifyQueueBoundDropsOldest is the bound: a fifth toast evicts the
// OLDEST, never the newest, and the eviction is counted rather than silent.
// Dropping the newest instead would mean the seat stops showing the thing
// the user most recently asked it to show.
func TestNotifyQueueBoundDropsOldest(t *testing.T) {
	resetNotify(t)
	for i := 0; i < NotifyMax+2; i++ {
		if _, ok, dropped := notifyPush(uint32(4+i), "msg", uint64(i)); !ok {
			t.Fatalf("push %d refused", i)
		} else if want := i >= NotifyMax; dropped != want {
			t.Fatalf("push %d dropped=%v want %v", i, dropped, want)
		}
	}
	if got := notifyCount(); got != NotifyMax {
		t.Fatalf("queue depth = %d want NotifyMax=%d", got, NotifyMax)
	}
	if notifyDropped != 2 {
		t.Fatalf("notifyDropped = %d want 2", notifyDropped)
	}
	// The survivors are the LAST NotifyMax pushes (ids 4..NotifyMax+3),
	// oldest first — the two earliest ids are the ones that were dropped.
	wantFirst := uint32(4 + 2)
	wantLast := uint32(4 + NotifyMax + 1)
	if notifyQueue[0].tabID != wantFirst || notifyQueue[NotifyMax-1].tabID != wantLast {
		t.Fatalf("survivors = %d..%d want %d..%d",
			notifyQueue[0].tabID, notifyQueue[NotifyMax-1].tabID, wantFirst, wantLast)
	}
	if _, _, ok := notifyPush(9, "", 0); ok {
		t.Fatal("an empty message must refuse before it can paint an empty panel")
	}
	if notifyCount() != NotifyMax {
		t.Fatal("a refused push changed the queue")
	}
}

// TestNotifyExpiryIsExactlyNTicks pins the lifetime: an entry born at tick
// T survives through tick T+NotifyTicks-1 and is dropped ON T+NotifyTicks.
// One tick either way is the difference between "fades after N ticks" and
// something else, and the gate waits on the dismiss marker.
func TestNotifyExpiryIsExactlyNTicks(t *testing.T) {
	resetNotify(t)
	const born = 10
	if _, ok, _ := notifyPush(4, "copied x", born); !ok {
		t.Fatal("push refused")
	}
	for tick := born; tick < born+NotifyTicks; tick++ {
		if gone := notifyExpire(uint64(tick)); len(gone) != 0 {
			t.Fatalf("tick %d dropped the toast early: %v", tick, gone)
		}
		if notifyCount() != 1 {
			t.Fatalf("tick %d lost the toast without dropping it", tick)
		}
	}
	gone := notifyExpire(born + NotifyTicks)
	if len(gone) != 1 || gone[0] != 4 {
		t.Fatalf("expire at %d = %v want [4]", born+NotifyTicks, gone)
	}
	if notifyCount() != 0 {
		t.Fatal("the queue kept an expired entry")
	}
}

// TestNotifyFadeRampHasThreeExactSteps pins the fade. The seat has no alpha
// on its fill path (fillRect writes an opaque pixel), so the fade is three
// named colour steps from Surface toward Bg over the last notifyFadeTicks
// ticks — and the last step IS Bg, which is why a spent toast is already
// invisible one tick before the queue drops it.
func TestNotifyFadeRampHasThreeExactSteps(t *testing.T) {
	tok := theme.Current
	if got := notifyRamp(NotifyTicks); got != 0 {
		t.Fatalf("ramp at full lifetime = %d want 0 (untouched panel)", got)
	}
	if got := notifyRamp(notifyFadeTicks + 1); got != 0 {
		t.Fatalf("ramp just before the fade = %d want 0", got)
	}
	want := []uint32{
		mixRGB(tok.Surface, tok.Bg, 1, notifyFadeTicks),
		mixRGB(tok.Surface, tok.Bg, 2, notifyFadeTicks),
		tok.Bg,
	}
	for i, w := range want {
		remaining := uint64(notifyFadeTicks - i)
		if got := notifyFill(tok, remaining); got != w {
			t.Errorf("fill at remaining=%d = #%06x want #%06x", remaining, got, w)
		}
	}
	// Above the ramp the rule and the text are the untouched tokens: a
	// full-brightness accent line over a Bg-coloured panel would read as
	// "still here", which is exactly what the last ramp step avoids.
	if got := notifyRule(tok, uint64(notifyFadeTicks)+1); got != tok.Accent {
		t.Errorf("rule above the fade = #%06x want the untouched Accent #%06x", got, tok.Accent)
	}
	if got := notifyText(tok, uint64(notifyFadeTicks)+1); got != tok.Ink {
		t.Errorf("text above the fade = #%06x want the untouched Ink #%06x", got, tok.Ink)
	}
	// At the end of the ramp both have reached the desktop colour.
	if got := notifyRule(tok, 1); got != tok.Bg {
		t.Errorf("rule at the last ramp step = #%06x want Bg #%06x", got, tok.Bg)
	}
	if got := notifyText(tok, 1); got != tok.Bg {
		t.Errorf("text at the last ramp step = #%06x want Bg #%06x", got, tok.Bg)
	}
	// The rule fades faster than the panel, so it never out-contrasts the
	// fill it sits on: on a fresh toast Accent-on-Surface, on a spent one
	// they are the same colour.
	if notifyRule(tok, 1) == notifyFill(tok, 1) && notifyRule(tok, 1) != tok.Bg {
		t.Error("a spent toast still contrasts with its own panel")
	}
	// mixRGB is the identity at 0 and exact at den, on every channel.
	if got := mixRGB(0x112233, 0xaabbcc, 0, 3); got != 0x112233 {
		t.Errorf("mixRGB at 0 = #%06x want the identity", got)
	}
	if got := mixRGB(0x112233, 0xaabbcc, 3, 3); got != 0xaabbcc {
		t.Errorf("mixRGB at den = #%06x want b", got)
	}
}

// TestNotifyRectIsBottomLeftStacked pins the geometry in the ORIENTATION the
// docs promise, because orientation is the thing that silently inverted once:
// slot 0 is the top of the band and holds the OLDEST entry, slot n-1 is the
// panel against the bottom edge and holds the NEWEST, and each arrival
// therefore appears at the bottom and pushes the older ones up. The stack is
// bottom-left because that is the one corner the seat's other chrome does not
// occupy.
func TestNotifyRectIsBottomLeftStacked(t *testing.T) {
	const w, h = 1280, 720
	// One toast: the band is one panel, flush with the bottom inset.
	x, y, pw, ph := notifyRect(w, h, 0, 1)
	if x != notifyInset || pw != NotifyW || ph != NotifyH {
		t.Fatalf("slot 0 of 1 rect = (%d,%d %dx%d) want x=%d %dx%d",
			x, y, pw, ph, notifyInset, NotifyW, NotifyH)
	}
	if y+ph+notifyInset != h {
		t.Fatalf("slot 0 bottom edge = %d, want %d (flush with the scanout bottom)",
			y+ph+notifyInset, h)
	}
	// Every stack depth: the NEWEST slot is the bottom panel, and each older
	// slot is exactly one panel + one gap above the next newer one — so the
	// band reads oldest-at-the-top and grows UPWARD with age.
	for n := 1; n <= NotifyMax; n++ {
		_, newestY, _, _ := notifyRect(w, h, n-1, n)
		if newestY+ph+notifyInset != h {
			t.Fatalf("with %d toasts the newest slot (%d) bottom edge = %d, want %d (flush with the scanout)",
				n, n-1, newestY+ph+notifyInset, h)
		}
		for slot := 0; slot < n-1; slot++ {
			xi, olderY, w2, h2 := notifyRect(w, h, slot, n)
			_, newerY, _, _ := notifyRect(w, h, slot+1, n)
			if xi != x || w2 != pw || h2 != ph {
				t.Fatalf("n=%d slot %d rect = (%d,%d %dx%d) want the same column as slot 0", n, slot, xi, olderY, w2, h2)
			}
			if olderY >= newerY {
				t.Fatalf("with %d toasts slot %d (y=%d) is not ABOVE slot %d (y=%d): the stack does not grow upward with age",
					n, slot, olderY, slot+1, newerY)
			}
			if newerY-olderY != NotifyH+notifyGap {
				t.Fatalf("with %d toasts the gap between slot %d and %d is %d, want NotifyH+notifyGap=%d",
					n, slot, slot+1, newerY-olderY, NotifyH+notifyGap)
			}
		}
	}
	// A new entry pushes the band up by exactly one panel + one gap, not by
	// two gaps: the top slot of a two-toast band is the one-toast band minus
	// (NotifyH + notifyGap).
	_, twoTopY, _, _ := notifyRect(w, h, 0, 2)
	if want := y - (NotifyH + notifyGap); twoTopY != want {
		t.Fatalf("the top of a 2-toast band is at y=%d, want %d (the 1-toast band pushed up one panel + one gap)", twoTopY, want)
	}
	// A scanout too narrow for the full panel still gets a live rect (the
	// panel clamps to the width); the seat's only hard give-up is a
	// nonsensical slot, an empty stack, or one that does not fit.
	if _, _, w2, h2 := notifyRect(40, h, 0, 1); w2 <= 0 || h2 <= 0 {
		t.Fatalf("a 40px scanout produced a live rect %dx%d", w2, h2)
	}
	// A slot outside 0..n-1 gives up with the zero rect rather than painting
	// where no entry is: the seat only ever asks for 0..n-1, so this is the
	// guard against a caller that asks for more (or for a slot in an empty
	// stack).
	if _, _, w2, h2 := notifyRect(w, h, 1, 1); w2 != 0 || h2 != 0 {
		t.Fatalf("slot 1 of a 1-toast stack produced %dx%d, want the zero rect", w2, h2)
	}
	if _, _, w2, h2 := notifyRect(w, h, 1000, NotifyMax); w2 != 0 || h2 != 0 {
		t.Fatalf("a slot 1000 panels up produced %dx%d, want the zero rect", w2, h2)
	}
	if _, _, w2, h2 := notifyRect(w, h, -1, NotifyMax); w2 != 0 || h2 != 0 {
		t.Fatalf("a negative slot produced %dx%d, want the zero rect", w2, h2)
	}
	if _, _, w2, h2 := notifyRect(w, h, 0, 0); w2 != 0 || h2 != 0 {
		t.Fatalf("a slot of an empty stack produced %dx%d, want the zero rect", w2, h2)
	}
	if _, _, w2, h2 := notifyRect(0, 0, 0, 1); w2 != 0 || h2 != 0 {
		t.Fatalf("a zero scanout produced %dx%d", w2, h2)
	}
}

// TestNotifyRectClearsTheSeatsOtherChrome is the layering claim in
// geometry: at every scanout size the toast stack must miss the 22px top
// rail, the bottom-right clock panel, and the centred start surface. Paint
// order is the belt; this is the braces — an overlap here would make the
// two chrome elements fight for the same pixels every tick.
func TestNotifyRectClearsTheSeatsOtherChrome(t *testing.T) {
	sizes := [][2]int{{1280, 720}, {1024, 768}, {800, 600}, {640, 480}}
	for _, s := range sizes {
		w, h := s[0], s[1]
		cx, cy, cw, ch := chromeRect(w, h)
		sx, sy, sw, sh := startSurfaceRect(w, h)
		for i := 0; i < NotifyMax; i++ {
			// The TALLEST band, so this is the worst case: a slot only
			// rises as entries are added below it.
			x, y, pw, ph := notifyRect(w, h, i, NotifyMax)
			if pw <= 0 || ph <= 0 {
				continue
			}
			if y < RailHeight {
				t.Errorf("%dx%d slot %d: toast top y=%d is inside the %dpx rail",
					w, h, i, y, RailHeight)
			}
			if y < cy+ch && cy < y+ph && x < cx+cw && cx < x+pw {
				t.Errorf("%dx%d slot %d: toast rect (%d,%d %dx%d) overlaps the clock panel (%d,%d %dx%d)",
					w, h, i, x, y, pw, ph, cx, cy, cw, ch)
			}
			if sh > 0 && y < sy+sh && sy < y+ph && x < sx+sw && sx < x+pw {
				t.Errorf("%dx%d slot %d: toast rect (%d,%d %dx%d) overlaps the start surface (%d,%d %dx%d)",
					w, h, i, x, y, pw, ph, sx, sy, sw, sh)
			}
		}
	}
}

// TestNotifyHitZoneIsExactlyThePaintedRect is the click-to-focus honesty
// check: a hit is reported if and only if the point is inside the rect the
// paint drew, one pixel in or out, and the resolved index is the toast the
// user is pointing at.
func TestNotifyHitZoneIsExactlyThePaintedRect(t *testing.T) {
	resetNotify(t)
	const w, h = 1280, 720
	if _, ok := notifyHit(10, 10, w, h); ok {
		t.Fatal("an empty strip must not be a click target")
	}
	// Two toasts: index 0 is the top panel (the oldest), index 1 the one
	// against the bottom edge (the newest). Queue index == stack slot, so
	// the centre of slot i must resolve to entry i.
	if _, ok, _ := notifyPush(4, "first", 0); !ok {
		t.Fatal("push 1")
	}
	if _, ok, _ := notifyPush(5, "second", 0); !ok {
		t.Fatal("push 2")
	}
	for i := 0; i < notifyCount(); i++ {
		x, y, pw, ph := notifyRect(w, h, i, notifyCount())
		cx, cy := uint32(x+pw/2), uint32(y+ph/2)
		got, ok := notifyHit(cx, cy, w, h)
		if !ok || got != i {
			t.Fatalf("centre of slot %d = (%d,%v) want (%d,true)", i, got, ok, i)
		}
		// Every corner: inside the rect is a hit, one pixel outside is not.
		for _, c := range [][2]int{{x, y}, {x + pw - 1, y + ph - 1}} {
			if _, ok := notifyHit(uint32(c[0]), uint32(c[1]), w, h); !ok {
				t.Errorf("slot %d corner %v inside the rect missed", i, c)
			}
		}
		for _, c := range [][2]int{{x - 1, y}, {x, y - 1}, {x + pw, y + ph - 1}} {
			if c[0] < 0 || c[1] < 0 {
				continue
			}
			if _, ok := notifyHit(uint32(c[0]), uint32(c[1]), w, h); ok {
				t.Errorf("slot %d corner %v one pixel OUTSIDE the rect hit", i, c)
			}
		}
	}
	// The gap between two stacked panels belongs to neither. Slot 0 is the
	// top panel and slot 1 the bottom one, so the gap is measured from the
	// bottom panel's TOP edge up to the top panel's BOTTOM edge.
	_, y0, _, h0 := notifyRect(w, h, 0, 2)
	_, y1, _, h1 := notifyRect(w, h, 1, 2)
	gap := y1 - (y0 + h0)
	if gap != notifyGap {
		t.Fatalf("the gap between the two panels is %d, want notifyGap=%d", gap, notifyGap)
	}
	if _, ok := notifyHit(uint32(notifyInset+1), uint32(y1+h1+gap/2), w, h); ok {
		t.Errorf("the %dpx gap between panels is a click target", gap)
	}
}

// TestDismissByIndexReturnsTheSendersTabID pins what the dismiss marker and
// the focus path both read: the SENDER's window id, not the queue slot.
func TestDismissByIndexReturnsTheSendersTabID(t *testing.T) {
	resetNotify(t)
	notifyPush(4, "a", 0)
	notifyPush(5, "b", 0)
	notifyPush(6, "c", 0)
	id, ok := notifyDismissByIndex(1)
	if !ok || id != 5 {
		t.Fatalf("dismiss index 1 = %d,%v want 5,true", id, ok)
	}
	if notifyCount() != 2 {
		t.Fatalf("queue depth after a dismiss = %d want 2", notifyCount())
	}
	if notifyQueue[0].tabID != 4 || notifyQueue[1].tabID != 6 {
		t.Fatalf("survivors = %d,%d want 4,6 (the middle entry alone went)",
			notifyQueue[0].tabID, notifyQueue[1].tabID)
	}
	if _, ok := notifyDismissByIndex(9); ok {
		t.Fatal("an out-of-range index must not dismiss anything")
	}
	if _, ok := notifyDismissByIndex(-1); ok {
		t.Fatal("a negative index must not dismiss anything")
	}
}

// TestClearNotifyDropsOnlyTheClosedTabsToasts is the dead-sender rule: a
// toast whose tab is gone can never be clicked back to anything, so closing
// the tab takes its toasts with it — and only its own.
func TestClearNotifyDropsOnlyTheClosedTabsToasts(t *testing.T) {
	resetNotify(t)
	notifyPush(4, "a", 0)
	notifyPush(5, "b", 0)
	notifyPush(4, "c", 0)
	if got := clearNotify(4); got != 2 {
		t.Fatalf("clearNotify(4) = %d want 2", got)
	}
	if notifyCount() != 1 || notifyQueue[0].tabID != 5 {
		t.Fatalf("survivors = %d entries, want tab 5 only", notifyCount())
	}
	if got := clearNotify(4); got != 0 {
		t.Fatalf("a second clearNotify(4) = %d want 0", got)
	}
}

// TestPaintNotifyStaysInsideTheRectAndUsesTokens is the paint contract
// paintChrome already holds: the strip writes only inside its own rects,
// and writes them from theme tokens with nothing clipping the text.
func TestPaintNotifyStaysInsideTheRectAndUsesTokens(t *testing.T) {
	resetNotify(t)
	const w, h = 1280, 720
	if paintNotify(make([]byte, w*h*4), w, h, 0) != 0 {
		t.Fatal("an empty strip painted something")
	}
	if _, ok, _ := notifyPush(4, "copied KNOWN.TXT", 0); !ok {
		t.Fatal("push refused")
	}
	scan := make([]byte, w*h*4)
	tok := theme.Current
	for i := 0; i < len(scan)/4; i++ {
		asUint32(scan)[i] = theme.Light.Success // a colour no token uses
	}
	if paintNotify(scan, w, h, 0) == 0 {
		t.Fatal("paintNotify painted nothing")
	}
	pix := asUint32(scan)
	x, y, pw, ph := notifyRect(w, h, 0, 1)
	var fill, rule, ink int
	for row := 0; row < h; row++ {
		for col := 0; col < w; col++ {
			v := pix[row*w+col]
			inRect := col >= x && col < x+pw && row >= y && row < y+ph
			if !inRect {
				// The §2.5 drop shadow darkens a falloff band around the
				// toast plate (blur 16, dy 4) — bound it, then hold the
				// rest of the scanout to the sentinel.
				inShadow := col >= x-16 && col < x+pw+16 && row >= y-16 && row < y+ph+20
				if !inShadow && v != theme.Light.Success {
					t.Fatalf("paintNotify wrote outside its rect and shadow at %d,%d", col, row)
				}
				continue
			}
			switch v & 0xffffff {
			case tok.Surface:
				fill++
			case tok.Accent:
				rule++
			case tok.Ink:
				ink++
			}
		}
	}
	if fill == 0 {
		t.Error("the panel is not Surface")
	}
	if rule == 0 {
		t.Error("the accent rule did not paint")
	}
	if ink == 0 {
		t.Error("the message text did not paint")
	}
	// The full 24-byte text budget must fit the panel: a bounded message
	// that got clipped by the panel would be a silent truncation.
	if NotifyW < notifyTextPad+vi.WmRpcTitleMax*font8Advance+notifyInset {
		t.Errorf("NotifyW=%d cannot hold a %d-byte message", NotifyW, vi.WmRpcTitleMax)
	}
}

// font8Advance is the 8px face's per-character advance (chrome.go's
// chromeScale=1 face), restated here so the width pin does not silently
// drift if the font package changes it.
const font8Advance = 8

// TestNotifyPaintStacksOldestOnTop is the ordering the queue documents: slot
// i draws queue entry i, so the newest is nearest the bottom edge and the
// oldest is the one that has been there longest at the top.
func TestNotifyPaintStacksOldestOnTop(t *testing.T) {
	resetNotify(t)
	const w, h = 1280, 720
	// Two toasts with distinguishable one-glyph texts, painted on frames
	// far apart in the fade so the top panel is mid-ramp and the bottom is
	// fresh: the fills must then differ, which is only possible if each
	// slot painted its OWN entry at its OWN remaining lifetime.
	notifyPush(4, "aaaaaaaa", 0)
	notifyPush(5, "bbbbbbbb", NotifyTicks-1)
	scan := make([]byte, w*h*4)
	paintNotify(scan, w, h, NotifyTicks-1)
	pix := asUint32(scan)
	// Slot 0 is the TOP of the band and holds the older entry; slot n-1 is
	// the panel against the bottom edge and holds the newer one. Named
	// after what they ARE, not after where they were believed to be: this
	// test once sampled the bottom panel into `top` and passed against an
	// inverted stack.
	_, topY, _, _ := notifyRect(w, h, 0, 2)
	_, botY, _, _ := notifyRect(w, h, 1, 2)
	if topY >= botY {
		t.Fatalf("slot 0 (y=%d) is not above slot 1 (y=%d): the band does not read oldest-on-top", topY, botY)
	}
	top := pix[(topY+10)*w+notifyInset+NotifyW-4]
	bot := pix[(botY+10)*w+notifyInset+NotifyW-4]
	if top == bot {
		t.Fatalf("both slots painted the same fill (#%06x): the two entries did not get their own remaining lifetime", top&0xffffff)
	}
	if top&0xffffff != theme.Current.Bg {
		t.Errorf("the older (spent) slot is #%06x, want Bg #%06x", top&0xffffff, theme.Current.Bg)
	}
	if bot&0xffffff != theme.Current.Surface {
		t.Errorf("the freshest slot is #%06x, want Surface #%06x", bot&0xffffff, theme.Current.Surface)
	}
}

// TestToastSurvivesTheRestOfTheTick is the paint-ORDER claim, run through
// the real compositeTick: the launcher is open, a toast is queued, and the
// finished frame still carries the toast's rule and fill. Then the rest of
// the tick's paint is replayed over that frame and the toast is still
// there — the toast is the LAST write of a tick, so nothing the seat
// paints afterwards can erase it.
func TestToastSurvivesTheRestOfTheTick(t *testing.T) {
	resetNotify(t)
	savedTabs, savedLaunch, savedDemo := tabs, launch, demoMode
	savedDone, savedCount := stripDone, hostTicksLeft
	t.Cleanup(func() {
		tabs, launch, demoMode = savedTabs, savedLaunch, savedDemo
		stripDone, hostTicksLeft = savedDone, savedCount
	})
	demoMode = false
	tabs = TabStrip{}
	stripDone, hostTicksLeft = false, 0
	if !tabs.OpenTab(4, "files") {
		t.Fatal("OpenTab")
	}
	launch = launcherState{}
	launch.open = true
	launch.filtered = []int{0}
	compositeClock = 3
	notifyPush(4, "copied KNOWN.TXT", compositeClock)

	scan := make([]byte, vi.ScanoutWidth*vi.ScanoutHeight*4)
	presents := 0
	compositeTick(scan, 4, &presents) // born at composite 3, painted at 4

	x, y, pw, ph := notifyRect(vi.ScanoutWidth, vi.ScanoutHeight, 0, 1)
	pix := asUint32(scan)
	rule := pix[(y+ph/2)*vi.ScanoutWidth+x+1] & 0xffffff
	if rule != theme.Current.Accent {
		t.Fatalf("the toast's accent rule is #%06x after the tick, want #%06x — the strip was not painted last",
			rule, theme.Current.Accent)
	}
	// compositeTick paints the launcher BEFORE the toast and the chrome
	// before both — and with the #2054 left-edge strip the launcher's rect
	// genuinely overlaps the toast column now, so the order is what keeps
	// the toast visible. The honest replay is the real order compressed:
	// strip, then toast again — the strip must lose, and the center
	// dialog (the only paint after it) must not erase it either.
	_ = paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	chromeTick(scan, 4)
	_ = paintNotify(scan, vi.ScanoutWidth, vi.ScanoutHeight, 4)
	_ = paintNotifyCenter(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	pix = asUint32(scan)
	if got := pix[(y+ph/2)*vi.ScanoutWidth+x+1] & 0xffffff; got != theme.Current.Accent {
		t.Fatalf("a later paint in the same tick changed the toast's rule to #%06x: it is not the last write", got)
	}
	_ = pw
}

// TestSeatTickTracksCompositeTick pins the clock the RPC arm reads: seatTick
// is the tick the last paint pass ran at, so a toast born between ticks is
// timed from a tick that actually happened.
func TestSeatTickTracksCompositeTick(t *testing.T) {
	resetNotify(t)
	savedTabs, savedDemo := tabs, demoMode
	savedDone, savedCount := stripDone, hostTicksLeft
	savedLaunch := launch
	t.Cleanup(func() {
		tabs, demoMode = savedTabs, savedDemo
		stripDone, hostTicksLeft = savedDone, savedCount
		// syncSeatChrome names the host's failed WinOpen in launch.err
		// every live tick; hand the launcher state back (#2545).
		launch = savedLaunch
	})
	demoMode = false
	tabs = TabStrip{}
	stripDone, hostTicksLeft = false, 0
	tabs.OpenTab(4, "a")
	scan := make([]byte, vi.ScanoutWidth*vi.ScanoutHeight*4)
	presents := 0
	for i := 1; i <= 3; i++ {
		compositeTick(scan, uint64(i), &presents)
		if seatTick != uint64(i) {
			t.Fatalf("after tick %d seatTick = %d", i, seatTick)
		}
	}
}

// The paint marker is the gate's choreography point, so its rules are
// pinned: it is one-shot PER BURST, it only fires on a tick that actually
// painted a non-empty strip AND presented the frame, and it names the
// NEWEST entry's sender. The re-arm is exercised through the real drain
// path — a test that pokes the latch directly would keep passing if the
// re-arm itself broke.
func TestNotifyPaintMarkerIsOneShotAndOnlyOnAPaintedPresentedTick(t *testing.T) {
	resetNotify(t)

	// Nothing queued, nothing painted: silent.
	if line, ok := notifyPaintMarker(false); ok || line != "" {
		t.Fatalf("an unpainted tick produced %q,%v", line, ok)
	}
	// A paint that was never presented is still not "on the scanout": the
	// caller passes painted && presented, and this is the presented=false
	// case reaching the helper as painted=false.
	notifyPush(7, "copied KNOWN.TXT", 0)
	if line, ok := notifyPaintMarker(false); ok {
		t.Fatalf("an unpresented tick produced %q", line)
	}
	line, ok := notifyPaintMarker(true)
	if !ok || line != MarkerNotifyPaint+"7" {
		t.Fatalf("paint marker = %q,%v want %q7,true", line, ok, MarkerNotifyPaint)
	}
	// One-shot within a burst: the toast is painted on every tick of its
	// life.
	if _, ok := notifyPaintMarker(true); ok {
		t.Fatal("the paint marker fired twice in one burst")
	}
	// A second toast joins the SAME burst and must not re-announce: the user
	// has already been told a toast reached the screen, and the gate greps
	// the transition, not a per-tick (or per-toast) flood.
	notifyPush(9, "second", 0)
	if _, ok := notifyPaintMarker(true); ok {
		t.Fatal("the paint marker fired again while the first burst was still up")
	}
	// Per BURST, not per process: expiry drains the strip and the latch
	// re-arms, so a seat that lives for hours stays observable after toast
	// #1. Drained through the real expiry path — a test that poked the flag
	// would keep passing if the re-arm itself broke.
	notifyTick(NotifyTicks)
	if notifyCount() != 0 {
		t.Fatalf("expiry at tick %d left %d toasts up", NotifyTicks, notifyCount())
	}
	if notifyPainted {
		t.Fatal("the paint-marker latch is still armed on an empty strip")
	}
	// And the next burst names the NEWEST entry, not the oldest.
	notifyPush(9, "second", 0)
	notifyPush(10, "third", 0)
	if line, ok := notifyPaintMarker(true); !ok || line != MarkerNotifyPaint+"10" {
		t.Fatalf("the first toast of a new burst produced %q,%v want %q10,true", line, ok, MarkerNotifyPaint)
	}
	if _, ok := notifyPaintMarker(true); ok {
		t.Fatal("the paint marker fired twice in the new burst")
	}
	// A click that empties the strip re-arms it as well.
	notifyDismissByIndex(0)
	notifyDismissByIndex(0)
	if notifyPainted {
		t.Fatal("clicking the last toast did not re-arm the paint marker")
	}
}
