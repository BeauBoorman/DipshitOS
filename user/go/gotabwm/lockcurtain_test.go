package main

// lockcurtain_test.go — M190e (#3240): the lock curtain's class-A legs.
// The vault blob is a real sealed frame built through vaultlib (iterations
// pinned to 1 so the host run stays fast); the sink seams are the same
// openInputSink/queryWindow/focusRaise/closeWin stubs cliphist_test uses.

import (
	"testing"

	"virelai/vaultlib"
	"virelai/vi"
)

var (
	lockTestSalt  = []byte("0123456789abcdef")
	lockTestNonce = []byte("fedcba987654")
	lockTestPass  = []byte("hunter2")
)

// lockTestVault seals an empty vault under lockTestPass at iterations=1 —
// the frame is real GVLT v2, only cheap.
func lockTestVault(t *testing.T) []byte {
	t.Helper()
	key, err := vaultlib.DeriveKey(lockTestPass, lockTestSalt, 1)
	if err != nil {
		t.Fatalf("DeriveKey: %v", err)
	}
	file, err := vaultlib.SealWithKey(vaultlib.FileMagic, vaultlib.FileVersion,
		key, lockTestSalt, lockTestNonce, 1, nil)
	vaultlib.Zero(key)
	if err != nil {
		t.Fatalf("SealWithKey: %v", err)
	}
	return file
}

// lockTestSeams stubs the four window syscalls the sink path rides and
// returns a restore func (the cliphist_test pattern).
func lockTestSeams(t *testing.T) (raised *uint32, closed *uint32) {
	oldOpen, oldQuery, oldRaise, oldClose := openInputSink, queryWindow, focusRaise, closeWin
	r, c := new(uint32), new(uint32)
	openInputSink = func(x, y, w, h uint32) (int, int64) { return 91, 0 }
	queryWindow = func(int) ([8]uint32, int64) {
		return [8]uint32{0, 0, 1, 1, 0, 1}, 0 // st[5]!=0: already focused
	}
	focusRaise = func(id uint32) int64 { *r = id; return 0 }
	closeWin = func(id uint32) int64 { *c = id; return 0 }
	t.Cleanup(func() {
		openInputSink, queryWindow, focusRaise, closeWin = oldOpen, oldQuery, oldRaise, oldClose
	})
	return r, c
}

func lockReset(t *testing.T) {
	old := lockActive
	sink, prior, file := lockSink, lockPrior, lockFile
	pass := lockPass
	lockActive, lockSink, lockPrior, lockFile, lockPass = false, 0, 0, nil, nil
	t.Cleanup(func() {
		lockActive, lockSink, lockPrior, lockFile, lockPass = old, sink, prior, file, pass
	})
}

func TestLockRefusedNoCredential(t *testing.T) {
	lockReset(t)
	lockTestSeams(t)
	old := lockReadFile
	lockReadFile = func(string, int) ([]byte, int64) { return nil, -int64(vi.ErrENOENT) }
	t.Cleanup(func() { lockReadFile = old })

	requestLock()
	if lockActive || lockSink != 0 {
		t.Fatalf("lock engaged without a credential: active=%v sink=%d", lockActive, lockSink)
	}
}

func TestLockRefusedBadCredential(t *testing.T) {
	lockReset(t)
	lockTestSeams(t)
	old := lockReadFile
	lockReadFile = func(string, int) ([]byte, int64) { return []byte("not a vault"), 11 }
	t.Cleanup(func() { lockReadFile = old })

	requestLock()
	if lockActive || lockSink != 0 {
		t.Fatalf("lock engaged on a bad frame: active=%v sink=%d", lockActive, lockSink)
	}
}

// The whole leg: a staged vault engages the curtain, a wrong passphrase is
// refused, the right one unlocks and restores the pre-lock focus.
func TestLockUnlockRoundTrip(t *testing.T) {
	lockReset(t)
	raised, closed := lockTestSeams(t)
	old := lockReadFile
	lockReadFile = func(string, int) ([]byte, int64) { return lockTestVault(t), 0 }
	t.Cleanup(func() { lockReadFile = old })

	// A hosted tab to hand focus back to — on a clean strip, so the id the
	// test asserts is the one the seat tracks.
	tabs = TabStrip{}
	tabs.OpenTab(7, "GOSH.ELF")
	defer tabs.CloseTab(7)
	hostedApp = 7
	defer func() { hostedApp = 0 }()

	requestLock()
	if !lockActive || lockSink != 91 || lockPrior != 7 {
		t.Fatalf("lock: active=%v sink=%d prior=%d", lockActive, lockSink, lockPrior)
	}

	// Wrong pass stays locked.
	typeLock(t, "nope")
	lockKeyDown(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x28})
	if !lockActive {
		t.Fatal("wrong pass unlocked")
	}
	if len(lockPass) != 0 {
		t.Fatalf("pass buffer held %d bytes after a refusal", len(lockPass))
	}

	// Right pass drops the curtain and restores the prior focus.
	typeLock(t, string(lockTestPass))
	lockKeyDown(vi.Event{Kind: vi.EvKeyDown, Arg0: 0x28})
	if lockActive {
		t.Fatal("right pass left the curtain up")
	}
	if *closed != 91 {
		t.Fatalf("sink close = %d, want 91", *closed)
	}
	if *raised != 7 {
		t.Fatalf("focusRaise = %d, want the pre-lock tab 7", *raised)
	}
	if hostedApp != 7 {
		t.Fatalf("hostedApp = %d, want 7", hostedApp)
	}
}

// typeLock feeds printable kind-1 KEY_DOWNs — the sink holds kernel focus,
// so arg1 carries real ASCII.
func typeLock(t *testing.T, s string) {
	t.Helper()
	for _, c := range []byte(s) {
		lockKeyDown(vi.Event{Kind: vi.EvKeyDown, Arg0: 0, Arg1: uint32(c)})
	}
}

// While locked the seat's dispatch is dead: a registered chord must not
// fire, and the focused tab must not see the key either.
func TestLockSwallowsSeatChords(t *testing.T) {
	lockReset(t)
	lockTestSeams(t)
	old := lockReadFile
	lockReadFile = func(string, int) ([]byte, int64) { return lockTestVault(t), 0 }
	t.Cleanup(func() { lockReadFile = old })

	requestLock()
	if !lockActive {
		t.Fatal("lock did not engage")
	}
	// ctrl+space is the launcher chord — a registered seat action. Under
	// the curtain it must decode to nothing.
	consumeSeatEvent(vi.Event{Kind: vi.EvWmKey, Flags: vi.ModCtrl, Arg0: 0x2C})
	if launch.open {
		t.Fatal("a seat chord fired under the lock curtain")
	}
	// Pointer input dies on the same boundary.
	consumeSeatEvent(vi.Event{Kind: vi.EvWmPointer, Arg0: 100 | 200<<16, Flags: 1})
	if !lockActive {
		t.Fatal("a pointer sample dropped the lock")
	}
}

// The PWR menu's Lock row dispatches the same request the chord does.
func TestPowerMenuLockRow(t *testing.T) {
	lockReset(t)
	lockTestSeams(t)
	old := lockReadFile
	lockReadFile = func(string, int) ([]byte, int64) { return lockTestVault(t), 0 }
	t.Cleanup(func() { lockReadFile = old })

	if len(powerRows) != 3 || powerRows[2] != "Lock" {
		t.Fatalf("powerRows = %v, want [Suspend Snapshot Lock]", powerRows)
	}
	runPowerRow(2)
	if !lockActive {
		t.Fatal("the Lock row did not engage the curtain")
	}
}
