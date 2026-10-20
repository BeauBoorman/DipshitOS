package main

import (
	"strings"
	"testing"

	"virelai/hostint"
	"virelai/vi"
)

// resetRefusal clears the dedupe table between cases (there is no
// production reset — the seat runs one boot per process).
func resetRefusal(t *testing.T) {
	t.Helper()
	savedN, savedDeduped := refusalSeenN, refusalDeduped
	savedSeen := refusalSeen
	refusalSeenN, refusalDeduped = 0, 0
	refusalSeen = [refusalTableMax]struct {
		key  string
		tick uint64
	}{}
	t.Cleanup(func() {
		refusalSeenN, refusalDeduped, refusalSeen = savedN, savedDeduped, savedSeen
	})
}

func TestRefusalActionMap(t *testing.T) {
	cases := []struct {
		name string
		want uint8
	}{
		{"EACCES", notifyActionGrant},
		{"ENOENT", notifyActionRetry},
		{"ENOSPC", notifyActionRetry},
		{"ETIMEDOUT", notifyActionRetry},
		{"ENOSYS", notifyActionCopy},
		{"EINVAL", notifyActionCopy},
		{"io_error", notifyActionCopy},
	}
	for _, c := range cases {
		if got := refusalActionFor(c.name); got != c.want {
			t.Fatalf("refusalActionFor(%q) = %d want %d", c.name, got, c.want)
		}
	}
}

func TestSeatRefusalPushesActionToast(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	seatTick = 10
	seatRefusalName("ENOENT", "exec MISSING.ELF", "MISSING.ELF")
	if n := notifyCount(); n != 1 {
		t.Fatalf("notifyCount = %d want 1", n)
	}
	toast := notifyQueue[0]
	if toast.action != notifyActionRetry || toast.snap != "MISSING.ELF" {
		t.Fatalf("toast = %+v want retry on MISSING.ELF", toast)
	}
	if toast.text != "ENOENT exec MISSING.ELF" {
		t.Fatalf("toast text = %q", toast.text)
	}
	// The center row carries the same action — the report survives the
	// toast's expiry, actionable from either surface.
	if len(notifyCenter) != 1 || notifyCenter[0].action != notifyActionRetry ||
		notifyCenter[0].snap != "MISSING.ELF" || notifyCenter[0].source != "Seat" {
		t.Fatalf("center row = %+v", notifyCenter[0])
	}
}

func TestSeatRefusalDedupesInsideWindow(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	seatTick = 10
	seatRefusalName("EACCES", "clipboard", "")
	seatRefusalName("EACCES", "clipboard", "")
	seatRefusalName("EACCES", "clipboard", "")
	if n := notifyCount(); n != 1 {
		t.Fatalf("notifyCount = %d want 1 toast for the storm", n)
	}
	if refusalDeduped != 2 {
		t.Fatalf("refusalDeduped = %d want 2", refusalDeduped)
	}
	// A different signature is a different refusal, not a repeat.
	seatRefusalName("EACCES", "exec X.ELF", "X.ELF")
	if n := notifyCount(); n != 2 {
		t.Fatalf("notifyCount = %d want 2", n)
	}
	// Past the window the same refusal reports again.
	seatTick += refusalDedupeTicks + 1
	seatRefusalName("EACCES", "clipboard", "")
	if n := notifyCount(); n != 3 {
		t.Fatalf("notifyCount = %d want 3 after the window", n)
	}
	if notifyQueue[2].action != notifyActionGrant {
		t.Fatalf("late toast action = %d want grant", notifyQueue[2].action)
	}
}

func TestSeatRefusalRawRc(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	seatRefusal(-vi.ErrEACCES, "clipboard", "")
	if n := notifyCount(); n != 1 || notifyQueue[0].action != notifyActionGrant {
		t.Fatalf("queue = %+v want one grant toast", notifyQueue)
	}
	seatRefusal(0, "ignored", "")
	seatRefusal(7, "ignored", "")
	if n := notifyCount(); n != 1 {
		t.Fatalf("non-negative rc pushed: count = %d", n)
	}
}

func TestRefusalDispatchRetryGrantCopy(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	var execs []string
	oldExec := execApp
	execApp = func(bin string, args ...string) (int64, error) {
		execs = append(execs, bin)
		return 42, nil
	}
	defer func() { execApp = oldExec }()
	var clip []byte
	oldClip := hostClipSet
	hostClipSet = func(p []byte) (int, int64) {
		clip = append([]byte{}, p...)
		return len(p), int64(len(p))
	}
	defer func() { hostClipSet = oldClip }()

	runNotifyAction(notifyActionRetry, "MISSING.ELF")
	runNotifyAction(notifyActionGrant, "")
	runNotifyAction(notifyActionCopy, "ENOENT exec MISSING.ELF")
	if len(execs) != 2 || execs[0] != "MISSING.ELF" || execs[1] != gosetBin {
		t.Fatalf("execs = %v want MISSING.ELF then GOSET.ELF", execs)
	}
	if string(clip) != "ENOENT exec MISSING.ELF" {
		t.Fatalf("clip = %q", clip)
	}
}

func TestNotifyClickedRunsRefusalAction(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	var execs []string
	oldExec := execApp
	execApp = func(bin string, args ...string) (int64, error) {
		execs = append(execs, bin)
		return 42, nil
	}
	defer func() { execApp = oldExec }()
	seatTick = 5
	seatRefusalName("ENOENT", "exec MISSING.ELF", "MISSING.ELF")
	// The toast sits at slot 0 of a one-entry band: bottom-left, the
	// go-snap offer's proven click point.
	notifyClicked(112, 702)
	if len(execs) != 1 || execs[0] != "MISSING.ELF" {
		t.Fatalf("execs = %v want the retry exec", execs)
	}
	if n := notifyCount(); n != 0 {
		t.Fatalf("toast not dismissed: %d", n)
	}
	if len(notifyCenter) != 0 {
		t.Fatalf("center row survived the resolved click: %+v", notifyCenter)
	}
}

func TestCenterRowClickRunsRefusalAction(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	var execs []string
	oldExec := execApp
	execApp = func(bin string, args ...string) (int64, error) {
		execs = append(execs, bin)
		return 0, errnoForTest
	}
	defer func() { execApp = oldExec }()
	seatTick = 5
	// DND holds the toast but keeps the report — the row alone is the
	// whole offer, and its click still resolves.
	notifyDND = true
	seatRefusalName("ENOENT", "exec MISSING.ELF", "MISSING.ELF")
	if n := notifyCount(); n != 0 {
		t.Fatalf("DND leaked a toast: %d", n)
	}
	if len(notifyCenter) != 1 {
		t.Fatalf("no center row under DND: %+v", notifyCenter)
	}
	runNotifyAction(notifyCenter[0].action, notifyCenter[0].snap)
	if len(execs) != 1 || execs[0] != "MISSING.ELF" {
		t.Fatalf("execs = %v want the row's retry", execs)
	}
}

func TestSeatLaneRefusalMapsConsentToGrant(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	seatTick = 3
	seatLaneRefusal("clip", hostint.RefuseConsent)
	if n := notifyCount(); n != 1 {
		t.Fatalf("notifyCount = %d want the clip consent toast", n)
	}
	toast := notifyQueue[0]
	if toast.action != notifyActionGrant || toast.text != "EACCES lane-clip" {
		t.Fatalf("toast = %+v want grant/EACCES lane-clip", toast)
	}
	// Integrity noise stays serial-only: a forged-record storm must not
	// become a toast storm.
	seatLaneRefusal("clip", hostint.RefuseBadMAC)
	seatLaneRefusal("clip", hostint.RefuseStaleEpoch)
	seatLaneRefusal("clip", hostint.RefuseBackpressure)
	if n := notifyCount(); n != 1 {
		t.Fatalf("integrity refusals raised toasts: %d", n)
	}
	// A payload refusal earns Copy Error with the reason as payload.
	seatLaneRefusal("clip", hostint.RefuseNotText)
	if n := notifyCount(); n != 2 {
		t.Fatalf("notifyCount = %d want the payload toast", n)
	}
	if notifyQueue[1].action != notifyActionCopy {
		t.Fatalf("payload toast action = %d want copy", notifyQueue[1].action)
	}
}

// go-wm-seat run 18 (observed 2026-10-20): the engine's io.Log captured
// hostintLog's VALUE at hostintSeatInit, so armRefusalLaneWatch — wired
// after init in the seat's start path — wrapped a var the engine no
// longer called. `refuse lane=clip reason=lane_disabled` printed on
// serial but never dispatched: no toast, no grant, the leg timed out.
// The Log seam now calls the var indirectly, so an engine refusal after
// the watch arms must reach the toast path.
func TestEngineRefusalReachesArmedLaneWatch(t *testing.T) {
	newHostintFixture(t, strings.Repeat("b7", 32))
	resetNotify(t)
	resetRefusal(t)
	hostintSeatInit()
	if hostintEngine == nil {
		t.Fatal("credential present but engine nil")
	}
	armRefusalLaneWatch()
	hostintEngine.RefuseLane(hostint.TagClipOut, hostint.RefuseLaneDisabled)
	if n := notifyCount(); n != 1 {
		t.Fatalf("notifyCount = %d want the lane_disabled toast", n)
	}
	toast := notifyQueue[0]
	if toast.action != notifyActionGrant || toast.text != "EACCES lane-clip" {
		t.Fatalf("toast = %+v want grant/EACCES lane-clip", toast)
	}
}

type testErrno string

func (e testErrno) Error() string { return string(e) }

var errnoForTest error = testErrno("ENOENT")
