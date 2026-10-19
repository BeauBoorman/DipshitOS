// crashsnap_test.go — M125f (#2591): host tests for the crash receipt
// check, the rotated slot save, the one-shot offer, and the restart bound.
//
// Every seam is a package var (the procsAlive / snapExists / stateFile*
// pattern), so the whole card is provable off the guest: the receipt's
// discrimination (exited-nonzero vs clean-quit vs unreadable table), the
// rotation and refusal verdicts, the consume-on-use LAST contract, the
// toast's action arm and its center-row dismiss, and the once-per-binary
// restart bound.
package main

import (
	"strings"
	"testing"

	"virelai/vi"
)

// crashShare is a fake /host backed by a map: the stateFile*/snapExists/
// snapDelete seams all land on it, so a test can stage LAST and watch the
// crash paths' reads, writes and deletes land where the guest would put
// them.
type crashShare struct {
	files   map[string][]byte
	deleted []string
}

func fakeCrashShare(t *testing.T) *crashShare {
	t.Helper()
	fs := &crashShare{files: map[string][]byte{}}
	oldR, oldW, oldD := stateFileRead, stateFileWrite, stateFileDelete
	oldX, oldDel := snapExists, snapDelete
	stateFileRead = func(path string, max int) ([]byte, int64) {
		b, ok := fs.files[path]
		if !ok {
			return nil, -1
		}
		return b, 0
	}
	stateFileWrite = func(path string, b []byte) int64 {
		cp := append([]byte(nil), b...)
		fs.files[path] = cp
		return 0
	}
	stateFileDelete = func(path string) int64 {
		fs.deleted = append(fs.deleted, path)
		delete(fs.files, path)
		return 0
	}
	snapExists = func(path string) bool { _, ok := fs.files[path]; return ok }
	snapDelete = func(path string) int64 {
		fs.deleted = append(fs.deleted, path)
		delete(fs.files, path)
		return 0
	}
	t.Cleanup(func() {
		stateFileRead, stateFileWrite, stateFileDelete = oldR, oldW, oldD
		snapExists, snapDelete = oldX, oldDel
	})
	return fs
}

// crashMarkerLog records crashLog lines in order.
func crashMarkerLog(t *testing.T) *[]string {
	t.Helper()
	lines := new([]string)
	old := crashLog
	crashLog = func(s string) { *lines = append(*lines, s) }
	t.Cleanup(func() { crashLog = old })
	return lines
}

func fakeCtl(t *testing.T, calls *[]string, reply int64, code string) {
	t.Helper()
	old := vsockCtlRequest
	vsockCtlRequest = func(verb, name string, dst []byte) int64 {
		*calls = append(*calls, verb+" "+name)
		if reply > 0 {
			copy(dst, code)
			return int64(len(code))
		}
		return reply
	}
	t.Cleanup(func() { vsockCtlRequest = old })
}

func fakeExitStatus(t *testing.T, status uint64, exited bool) {
	t.Helper()
	old := procsExitStatus
	procsExitStatus = func(uint8) (uint64, bool) { return status, exited }
	t.Cleanup(func() { procsExitStatus = old })
}

func resetCrashState(t *testing.T) {
	t.Helper()
	oldSeq, oldN := crashSnapSeq, crashRestartedN
	oldRestarted := crashRestarted
	oldBindings := rpcBindings
	oldPend := pendingAppStates
	oldPendN := pendingAppStateN
	oldAlive := procsAlive
	procsAlive = func(uint8) bool { return true }
	crashSnapSeq = 0
	crashRestartedN = 0
	crashRestarted = [MaxTabs]string{}
	rpcBindings = [256]rpcBinding{}
	pendingAppStates = [MaxTabs]pendingAppState{}
	pendingAppStateN = 0
	t.Cleanup(func() {
		crashSnapSeq, crashRestartedN = oldSeq, oldN
		crashRestarted = oldRestarted
		rpcBindings = oldBindings
		pendingAppStates = oldPend
		pendingAppStateN = oldPendN
		procsAlive = oldAlive
	})
}

func hasLine(lines []string, prefix string) bool {
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) {
			return true
		}
	}
	return false
}

// TestSeatCrashStatus pins the receipt's discrimination: only a bound
// owner whose process exited nonzero is a crash. A clean exit is a quit,
// a still-running or unreadable row is nothing, and an unbound window has
// no attributable owner at all.
func TestSeatCrashStatus(t *testing.T) {
	resetCrashState(t)
	rpcBindings[7] = rpcBinding{pid: 42, token: 0xAA}

	fakeExitStatus(t, 139, true)
	pid, status, crashed := seatCrashStatus(7)
	if !crashed || pid != 42 || status != 139 {
		t.Fatalf("exited+139: crashed=%v pid=%d status=%d", crashed, pid, status)
	}

	fakeExitStatus(t, 0, true)
	if _, _, crashed := seatCrashStatus(7); crashed {
		t.Fatal("a clean exit (status 0) is a quit, not a crash")
	}

	fakeExitStatus(t, 0, false)
	if _, _, crashed := seatCrashStatus(7); crashed {
		t.Fatal("a live process is not a crash")
	}

	// An unreadable table fails closed.
	old := procsExitStatus
	procsExitStatus = func(uint8) (uint64, bool) { return 0, false }
	if _, _, crashed := seatCrashStatus(7); crashed {
		t.Fatal("an unreadable procs table is not a crash receipt")
	}
	procsExitStatus = old

	// Unbound (pid 0) and out-of-range ids are never crashes.
	if _, _, crashed := seatCrashStatus(8); crashed {
		t.Fatal("an unbound window is not a crash")
	}
	if _, _, crashed := seatCrashStatus(300); crashed {
		t.Fatal("an out-of-range id is not a crash")
	}
}

// TestCrashSnapSaveRotation pins the bounded-rotated slot contract: three
// names in order, wrapping, a stale slot deleted before the save, and
// LAST written only after an ok verdict.
func TestCrashSnapSaveRotationAndLast(t *testing.T) {
	resetCrashState(t)
	fs := fakeCrashShare(t)
	lines := crashMarkerLog(t)
	var calls []string
	fakeCtl(t, &calls, 0, "")

	for i := 0; i < crashSnapSlots; i++ {
		crashSnapSave()
	}
	// The host wrote each parked image; rotation's fourth save must delete
	// the stale CRASH0 file before the ctl call (snapshot refuses exists).
	fs.files[crashSnapDir+"/CRASH0.vzsave"] = []byte("parked")
	crashSnapSave()
	want := []string{"snapshot CRASH0", "snapshot CRASH1", "snapshot CRASH2", "snapshot CRASH0"}
	if len(calls) != len(want) {
		t.Fatalf("ctl calls = %v want %v", calls, want)
	}
	for i := range want {
		if calls[i] != want[i] {
			t.Fatalf("call %d = %q want %q", i, calls[i], want[i])
		}
	}
	// Rotation reuses a slot: the second CRASH0 save deleted the stale
	// vzsave first (the ctl refuses `exists`).
	wantVZ := crashSnapDir + "/CRASH0.vzsave"
	found := false
	for _, d := range fs.deleted {
		if d == wantVZ {
			found = true
		}
	}
	if !found {
		t.Fatalf("stale %s was never deleted on rotation: %v", wantVZ, fs.deleted)
	}
	if got := string(fs.files[crashSnapLastPath]); got != "CRASH0\n" {
		t.Fatalf("LAST = %q want %q", got, "CRASH0\n")
	}
	if !hasLine(*lines, MarkerCrashSnapSave+"CRASH0 ok") {
		t.Fatalf("no save-ok marker: %v", *lines)
	}
}

// TestCrashSnapSaveRefused pins the honest refusal: the verdict code names
// itself in the marker, the stale slot delete still ran (the attempt was
// real), and LAST is never written for a save that did not park.
func TestCrashSnapSaveRefused(t *testing.T) {
	resetCrashState(t)
	fs := fakeCrashShare(t)
	lines := crashMarkerLog(t)
	var calls []string
	fakeCtl(t, &calls, 12, "no_credential")
	fs.files[crashSnapDir+"/CRASH0.vzsave"] = []byte("stale")

	crashSnapSave()
	if !hasLine(*lines, MarkerCrashSnapSave+"CRASH0 no_credential") {
		t.Fatalf("refusal not named: %v", *lines)
	}
	if _, ok := fs.files[crashSnapLastPath]; ok {
		t.Fatal("LAST written for a refused save — the offer would point at nothing")
	}
	found := false
	for _, d := range fs.deleted {
		if d == crashSnapDir+"/CRASH0.vzsave" {
			found = true
		}
	}
	if !found {
		t.Fatal("stale slot not deleted before the refused attempt")
	}
}

// TestCrashSnapOfferName pins the LAST read's fail-closed grammar: absent,
// empty, oversized and invalid content are all "no offer"; a good line is
// trimmed at its newline and validated as a NAME.
func TestCrashSnapOfferName(t *testing.T) {
	resetCrashState(t)
	fs := fakeCrashShare(t)

	if _, ok := crashSnapOfferName(); ok {
		t.Fatal("absent LAST offered")
	}
	fs.files[crashSnapLastPath] = []byte("")
	if _, ok := crashSnapOfferName(); ok {
		t.Fatal("empty LAST offered")
	}
	fs.files[crashSnapLastPath] = []byte("..bad name!!\n")
	if _, ok := crashSnapOfferName(); ok {
		t.Fatal("invalid name offered")
	}
	fs.files[crashSnapLastPath] = []byte("CRASH2\nextra bytes that must not ride")
	name, ok := crashSnapOfferName()
	if !ok || name != "CRASH2" {
		t.Fatalf("offer = %q ok=%v want CRASH2", name, ok)
	}
}

// TestCrashSnapOffer pins the boot half: a parked LAST becomes an
// action-carrying toast naming the slot, and absent LAST posts nothing.
func TestCrashSnapOffer(t *testing.T) {
	resetCrashState(t)
	resetNotify(t)
	fs := fakeCrashShare(t)
	lines := crashMarkerLog(t)

	crashSnapOffer()
	if notifyCount() != 0 {
		t.Fatal("no LAST posted a toast anyway")
	}

	fs.files[crashSnapLastPath] = []byte("CRASH1\n")
	crashSnapOffer()
	if notifyCount() != 1 {
		t.Fatalf("offer posted %d toasts want 1", notifyCount())
	}
	toast := notifyQueue[0]
	if toast.action != notifyActionCrashSnap || toast.snap != "CRASH1" {
		t.Fatalf("toast action=%d snap=%q", toast.action, toast.snap)
	}
	if !hasLine(*lines, MarkerCrashSnapOffer+"CRASH1") {
		t.Fatalf("no offer marker: %v", *lines)
	}
	// The history row carries the slot too: it IS the offer after the
	// toast fades.
	if len(notifyCenter) != 1 || notifyCenter[0].snap != "CRASH1" {
		t.Fatalf("center snap=%v", notifyCenter)
	}
}

// TestCrashSnapRestoreAndDismiss pin the two resolve arms: Restore runs
// the ctl `restore` stage and consumes the matching LAST; Dismiss only
// consumes. A LAST a newer crash rewrote survives a stale toast's click.
func TestCrashSnapRestoreAndDismiss(t *testing.T) {
	resetCrashState(t)
	fs := fakeCrashShare(t)
	lines := crashMarkerLog(t)
	var calls []string
	fakeCtl(t, &calls, 0, "")

	fs.files[crashSnapLastPath] = []byte("CRASH0\n")
	crashSnapRestore("CRASH0")
	if len(calls) != 1 || calls[0] != "restore CRASH0" {
		t.Fatalf("ctl calls = %v want [restore CRASH0]", calls)
	}
	if !hasLine(*lines, MarkerCrashSnapRestore+"CRASH0 ok") {
		t.Fatalf("no restore marker: %v", *lines)
	}
	if _, ok := fs.files[crashSnapLastPath]; ok {
		t.Fatal("the answered offer's LAST was not consumed")
	}

	// A stale toast answering a LAST a newer crash rewrote does not
	// consume it.
	fs.files[crashSnapLastPath] = []byte("CRASH2\n")
	crashSnapDismiss("CRASH0")
	if got := string(fs.files[crashSnapLastPath]); got != "CRASH2\n" {
		t.Fatalf("a stale dismiss consumed the newer offer: LAST=%q", got)
	}
	if !hasLine(*lines, MarkerCrashSnapDismiss+"CRASH0") {
		t.Fatalf("no dismiss marker: %v", *lines)
	}

	crashSnapDismiss("CRASH2")
	if _, ok := fs.files[crashSnapLastPath]; ok {
		t.Fatal("the matching dismiss did not consume LAST")
	}
	if !hasLine(*lines, MarkerCrashSnapDismiss+"CRASH2") {
		t.Fatalf("no dismiss marker: %v", *lines)
	}
}

// TestCrashSnapRestoreRefused still consumes: the offer was answered —
// the host named its verdict, and the one-shot file is gone so no later
// boot re-offers a refused restore.
func TestCrashSnapRestoreRefused(t *testing.T) {
	resetCrashState(t)
	fs := fakeCrashShare(t)
	lines := crashMarkerLog(t)
	fakeCtl(t, &[]string{}, 9, "not_found")

	fs.files[crashSnapLastPath] = []byte("CRASH0\n")
	crashSnapRestore("CRASH0")
	if !hasLine(*lines, MarkerCrashSnapRestore+"CRASH0 not_found") {
		t.Fatalf("refusal not named: %v", *lines)
	}
	if _, ok := fs.files[crashSnapLastPath]; ok {
		t.Fatal("a refused restore left the offer pending")
	}
}

// TestCrashRestartStagesBlob pins the re-exec half: the popped LIFO entry's
// bin is exec'd and its blob rides the pid-matched pending-state table,
// and the marker names the binary. The once-per-binary bound refuses the
// second restart with its own marker.
func TestCrashRestartStagesBlob(t *testing.T) {
	resetCrashState(t)
	defer saveSeatState()()
	lines := crashMarkerLog(t)

	var execs []string
	oldExec := execApp
	execApp = func(bin string, args ...string) (int64, error) {
		execs = append(execs, bin)
		return 77, nil
	}
	t.Cleanup(func() { execApp = oldExec })

	tabs = TabStrip{}
	if !tabs.OpenTab(9, "App") {
		t.Fatal("OpenTab")
	}
	tabs.tabs[0].Bin = "GOTABAPP.ELF"
	_ = tabs.SetState(9, 2, []byte("state-bytes"))
	_ = tabs.CloseTab(9)

	crashRestart()
	if len(execs) != 1 || execs[0] != "GOTABAPP.ELF" {
		t.Fatalf("execs = %v", execs)
	}
	if pendingAppStateN != 1 || pendingAppStates[0].pid != 77 ||
		pendingAppStates[0].ver != 2 || string(pendingAppStates[0].blob) != "state-bytes" {
		t.Fatalf("pending = %+v n=%d", pendingAppStates[0], pendingAppStateN)
	}
	if !hasLine(*lines, MarkerCrashRestart+"GOTABAPP.ELF") {
		t.Fatalf("no restart marker: %v", *lines)
	}

	// Same binary's second crash this boot: the bound refuses.
	if !tabs.OpenTab(10, "App") {
		t.Fatal("OpenTab 2")
	}
	tabs.tabs[0].Bin = "GOTABAPP.ELF"
	_ = tabs.CloseTab(10)
	crashRestart()
	if len(execs) != 1 {
		t.Fatalf("the loop bound allowed a second exec: %v", execs)
	}
	if !hasLine(*lines, MarkerCrashRestartStop+"GOTABAPP.ELF") {
		t.Fatalf("no stop marker: %v", *lines)
	}
}

// TestCrashRestartEmpty covers the honest no-ops: nothing recorded (a tab
// with no bin) execs nothing and prints nothing.
func TestCrashRestartEmpty(t *testing.T) {
	resetCrashState(t)
	defer saveSeatState()()
	var execs []string
	oldExec := execApp
	execApp = func(bin string, args ...string) (int64, error) {
		execs = append(execs, bin)
		return 1, nil
	}
	t.Cleanup(func() { execApp = oldExec })

	crashRestart()
	tabs = TabStrip{}
	if !tabs.OpenTab(9, "orphan") {
		t.Fatal("OpenTab")
	}
	tabs.tabs[0].Bin = "" // a tab the seat never spawned records no bin
	_ = tabs.CloseTab(9)  // skipped by the LIFO pop
	crashRestart()
	if len(execs) != 0 {
		t.Fatalf("a bin-less close was restarted: %v", execs)
	}
}

// TestCrashSaveOrder pins the arm's step order — asks first, session
// republish second (the crashed row still recorded), slot save last —
// by landing every seam's arrival in one recorder.
func TestCrashSaveOrder(t *testing.T) {
	resetCrashState(t)
	defer saveSeatState()()
	fs := fakeCrashShare(t)
	var calls []string
	fakeCtl(t, &calls, 0, "")

	var order []string
	oldPost := stateNoticePost
	oldDrain := stateServiceDrain
	oldWrite := writeHostFile
	stateNoticePost = func(uint32, []byte) int64 {
		order = append(order, "ask")
		return 1
	}
	stateServiceDrain = func() int {
		for i := range stateAskPend {
			stateAskPend[i] = false
		}
		return 0
	}
	writeHostFile = func(string, []byte) bool {
		order = append(order, "session")
		return true
	}
	oldCtl := vsockCtlRequest
	vsockCtlRequest = func(verb, name string, dst []byte) int64 {
		order = append(order, "ctl:"+verb)
		calls = append(calls, verb+" "+name)
		return 0
	}
	t.Cleanup(func() {
		stateNoticePost = oldPost
		stateServiceDrain = oldDrain
		writeHostFile = oldWrite
		vsockCtlRequest = oldCtl
	})

	tabs = TabStrip{}
	if !tabs.OpenTab(9, "App") {
		t.Fatal("OpenTab")
	}
	tabs.tabs[0].Bin = "GOTABAPP.ELF"
	rpcBindings[9] = rpcBinding{pid: 42, token: 0xBEEF}

	crashSave()
	want := []string{"ask", "session", "ctl:snapshot"}
	if len(order) != len(want) {
		t.Fatalf("order = %v want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order[%d] = %q want %q", i, order[i], want[i])
		}
	}
	// The republished session still names the crashed row's bin: the file
	// written BEFORE CloseTab carries it for the next boot's re-exec.
	if _, ok := fs.files[crashSnapLastPath]; !ok {
		t.Fatal("LAST was not written after an ok save")
	}
}

// TestNotifyClickedCrashSnapRestores pins the toast's action arm: a click
// on the offer runs the staged restore and never tries to focus sender 0.
func TestNotifyClickedCrashSnapRestores(t *testing.T) {
	resetCrashState(t)
	resetNotify(t)
	fs := fakeCrashShare(t)
	var calls []string
	fakeCtl(t, &calls, 0, "")
	var focused []uint32
	oldFocus := focusNotifySource
	focusNotifySource = func(id uint32) bool {
		focused = append(focused, id)
		return true
	}
	t.Cleanup(func() { focusNotifySource = oldFocus })

	fs.files[crashSnapLastPath] = []byte("CRASH0\n")
	crashSnapOffer()

	x, y, pw, ph := notifyRect(vi.ScanoutWidth, vi.ScanoutHeight, 0, 1)
	if got := notifyClicked(uint32(x+pw/2), uint32(y+ph/2)); got != 1 {
		t.Fatalf("click dismissed %d want 1", got)
	}
	if len(calls) != 1 || calls[0] != "restore CRASH0" {
		t.Fatalf("ctl calls = %v want [restore CRASH0]", calls)
	}
	if len(focused) != 0 {
		t.Fatalf("the action toast's click focused %v", focused)
	}
	if _, ok := fs.files[crashSnapLastPath]; ok {
		t.Fatal("the clicked offer's LAST was not consumed")
	}
	// The resolved offer leaves BOTH surfaces — the paired center row
	// cannot answer the same offer a second time.
	if len(notifyCenter) != 0 {
		t.Fatalf("the resolved offer's center row survived: %+v", notifyCenter)
	}
}

// TestNotifyCenterSnapRowRestores pins the mirror direction: the center
// row's body click is the same Restore arm, and the resolved offer's
// toast retires with the row.
func TestNotifyCenterSnapRowRestores(t *testing.T) {
	resetCrashState(t)
	resetNotify(t)
	fs := fakeCrashShare(t)
	var calls []string
	fakeCtl(t, &calls, 0, "")

	fs.files[crashSnapLastPath] = []byte("CRASH0\n")
	crashSnapOffer()
	if notifyCount() != 1 || len(notifyCenter) != 1 {
		t.Fatalf("offer surfaces: queue=%d center=%d", notifyCount(), len(notifyCenter))
	}
	notifyCenterOpen = true
	x, y, _, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	// The row's body — left of the trailing X zone — is the Restore arm.
	if !notifyCenterClick(uint32(x+notifyCenterPad+8),
		uint32(y+notifyHeaderH+notifyRowH/2)) {
		t.Fatal("the offer row's click was not consumed")
	}
	if len(calls) != 1 || calls[0] != "restore CRASH0" {
		t.Fatalf("ctl calls = %v want [restore CRASH0]", calls)
	}
	if len(notifyCenter) != 0 || notifyCount() != 0 {
		t.Fatalf("resolved offer left row=%d toast=%d", len(notifyCenter), notifyCount())
	}
	if _, ok := fs.files[crashSnapLastPath]; ok {
		t.Fatal("the row-answered offer's LAST was not consumed")
	}
}

// TestNotifyClickedOrdinaryStillFocuses is the regression guard: a
// non-action toast's click keeps its sender-focus contract.
func TestNotifyClickedOrdinaryStillFocuses(t *testing.T) {
	resetCrashState(t)
	resetNotify(t)
	var calls []string
	fakeCtl(t, &calls, 0, "")
	lines := crashMarkerLog(t)

	tabs = TabStrip{}
	if !tabs.OpenTab(4, "files") {
		t.Fatal("OpenTab")
	}
	if _, ok, _ := notifyPush(4, "copied KNOWN.TXT", 0); !ok {
		t.Fatal("push refused")
	}
	x, y, pw, ph := notifyRect(vi.ScanoutWidth, vi.ScanoutHeight, 0, 1)
	if notifyClicked(uint32(x+pw/2), uint32(y+ph/2)) != 1 {
		t.Fatal("click did not land")
	}
	if len(calls) != 0 {
		t.Fatalf("an ordinary toast's click touched ctl: %v", calls)
	}
	if hasLine(*lines, MarkerCrashSnapRestore) {
		t.Fatalf("an ordinary toast's click staged a restore: %v", *lines)
	}
	if notifyCount() != 0 {
		t.Fatal("the ordinary toast was not dismissed")
	}
}

// TestCrashSnapToastExpiryLeavesOffer pins expiry-is-not-dismissal: a
// faded offer keeps LAST and its center row, so the next boot re-posts.
func TestCrashSnapToastExpiryLeavesOffer(t *testing.T) {
	resetCrashState(t)
	resetNotify(t)
	fs := fakeCrashShare(t)

	fs.files[crashSnapLastPath] = []byte("CRASH0\n")
	crashSnapOffer()
	notifyTick(toastExpiresAt() + 1)
	if notifyCount() != 0 {
		t.Fatal("the toast did not expire")
	}
	if _, ok := fs.files[crashSnapLastPath]; !ok {
		t.Fatal("toast expiry consumed the offer")
	}
	if len(notifyCenter) != 1 || notifyCenter[0].snap != "CRASH0" {
		t.Fatal("toast expiry dropped the offer's center row")
	}
}

// toastExpiresAt is notifyQueue[0].expires — the offer posted this test.
func toastExpiresAt() uint64 { return notifyQueue[0].expires }

// TestDismissNotifyCenterEntryResolvesSnap pins the row-X dismiss arm:
// the offer is resolved as dismissed and LAST consumed.
func TestDismissNotifyCenterEntryResolvesSnap(t *testing.T) {
	resetCrashState(t)
	resetNotify(t)
	fs := fakeCrashShare(t)
	lines := crashMarkerLog(t)

	fs.files[crashSnapLastPath] = []byte("CRASH0\n")
	crashSnapOffer()
	if len(notifyCenter) != 1 {
		t.Fatal("offer did not reach the center")
	}
	if !dismissNotifyCenterEntry(0) {
		t.Fatal("dismiss refused")
	}
	if !hasLine(*lines, MarkerCrashSnapDismiss+"CRASH0") {
		t.Fatalf("no dismiss marker: %v", *lines)
	}
	if _, ok := fs.files[crashSnapLastPath]; ok {
		t.Fatal("the dismissed offer's LAST was not consumed")
	}
	// The resolved row's toast goes with it — no surface answers twice.
	if notifyCount() != 0 {
		t.Fatal("the dismissed offer's toast survived")
	}
}

// TestClearNotifyCenterResolvesSnap pins clear-all: every pending offer
// inside it resolves as dismissed, not dropped silently.
func TestClearNotifyCenterResolvesSnap(t *testing.T) {
	resetCrashState(t)
	resetNotify(t)
	fs := fakeCrashShare(t)
	lines := crashMarkerLog(t)

	fs.files[crashSnapLastPath] = []byte("CRASH0\n")
	crashSnapOffer()
	if clearNotifyCenter() != 1 {
		t.Fatal("clear-all missed the offer")
	}
	if !hasLine(*lines, MarkerCrashSnapDismiss+"CRASH0") {
		t.Fatalf("clear-all did not resolve the offer: %v", *lines)
	}
	if _, ok := fs.files[crashSnapLastPath]; ok {
		t.Fatal("clear-all left the offer's LAST")
	}
}
