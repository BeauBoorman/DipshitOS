package main

// The verb-level legs: directory-chain creation against the file seams,
// the receipt append through its injected writer, the receipts face's
// load-and-key contract. All pure — every syscall is a seam var.
import (
	"testing"

	"virelai/vaultlib"
	"virelai/vi"
)

// ensureDirs never offers the mount root the mkdir triple — "/host" answers
// it with EINVAL, not EEXIST (observed on the run-01 gate leg: `save refused
// rc=-1 /host`, and the whole vault chain died behind it). Only components
// BELOW the root are created; EEXIST is a pass and a real refusal propagates.
func TestEnsureDirsSkipsMountRoot(t *testing.T) {
	oldOpen, oldClose := fileOpen, fileClose
	defer func() { fileOpen, fileClose = oldOpen, oldClose }()

	var opened []string
	fileOpen = func(path string, flags uint32) (int64, int64) {
		opened = append(opened, path)
		return 0, int64(vi.ErrFileExists)
	}
	fileClose = func(h int64) {}
	if !ensureDirs("/host/GOVAULT/VAULT.BIN") {
		t.Fatal("ensureDirs refused an all-EEXIST chain")
	}
	if len(opened) != 1 || opened[0] != "/host/GOVAULT" {
		t.Fatalf("opened %v, want exactly [/host/GOVAULT] — the mount root is never created", opened)
	}

	fileOpen = func(path string, flags uint32) (int64, int64) {
		return -1, -int64(vi.ErrEACCES)
	}
	if ensureDirs("/host/GOVAULT/VAULT.BIN") {
		t.Fatal("a refused mkdir below the root must propagate")
	}
}

// receipt() appends through the file seam: the row carries the seam-injected
// time, the action and the vaultlib.Entry name — and never the secret.
func TestReceiptAppends(t *testing.T) {
	oldTime, oldAppend := timeFn, rcptAppend
	defer func() {
		timeFn, rcptAppend = oldTime, oldAppend
	}()

	var got []byte
	timeFn = func() int64 { return 1729440000 }
	rcptAppend = func(path string, b []byte) int64 {
		if path != receiptPath {
			t.Fatalf("append path = %q, want %q", path, receiptPath)
		}
		got = append(got, b...)
		return 0
	}

	a := &app{}
	a.receipt(actCopy, []byte("wifi"))
	a.receipt(actUnlockFail, nil)
	want := "1729440000 copy wifi\n1729440000 unlock-failed -\n"
	if string(got) != want {
		t.Fatalf("appended rows = %q, want %q", got, want)
	}

	// A refused append is named in the status — the action stands anyway.
	rcptAppend = func(path string, b []byte) int64 { return -int64(vi.ErrEACCES) }
	a.status = ""
	a.receipt(actReveal, []byte("wifi"))
	if a.status != "receipt refused" {
		t.Fatalf("status = %q, want the named refusal", a.status)
	}
}

// openReceipts loads the file into the view: rows land in the model and the
// face moves over. An absent file is an empty view, not an error.
func TestOpenReceiptsLoadsAndHandlesAbsent(t *testing.T) {
	oldRead := readAll
	defer func() {
		readAll = oldRead
	}()

	var data []byte
	data = append(data, receiptLine(1, actUnlock, "")...)
	data = append(data, receiptLine(2, actCopy, "bank")...)
	readAll = func(path string, max int) ([]byte, int64) { return data, int64(len(data)) }

	a := &app{}
	a.m.scr = scrList
	a.openReceipts()
	if a.m.scr != scrReceipts {
		t.Fatalf("scr=%d, want scrReceipts", a.m.scr)
	}
	if len(a.m.rcpts) != 2 || a.m.rcpts[1].name != "bank" {
		t.Fatalf("rcpts=%+v", a.m.rcpts)
	}

	readAll = func(path string, max int) ([]byte, int64) {
		return nil, -int64(vi.ErrENOENT)
	}
	a.openReceipts()
	if a.m.scr != scrReceipts || len(a.m.rcpts) != 0 {
		t.Fatalf("absent receipts must give an empty view, got %+v n=%d",
			a.m.scr, len(a.m.rcpts))
	}

	// A real refusal (not ENOENT) keeps the list face and names itself.
	a.m.scr = scrList
	readAll = func(path string, max int) ([]byte, int64) {
		return nil, -int64(vi.ErrEACCES)
	}
	a.openReceipts()
	if a.m.scr != scrList || a.status != "receipts refused" {
		t.Fatalf("refused read: scr=%d status=%q", a.m.scr, a.status)
	}
}

// The receipts view's key contract: v and esc both return to the list, and
// ctrl-l still locks — the safe direction is never further than one chord.
func TestReceiptsKeys(t *testing.T) {
	a := &app{}
	a.m.scr = scrReceipts
	a.m.rcpts = []receipt{{epoch: 1, action: actCopy, name: "wifi", ok: true}}

	if !a.keyReceipts(vi.Event{Kind: vi.EvKeyDown, Arg1: 'v'}) || a.m.scr != scrList {
		t.Fatal("'v' must toggle back to the list")
	}
	a.m.scr = scrReceipts
	if !a.keyReceipts(vi.Event{Kind: vi.EvKeyDown, Arg0: hidEsc}) || a.m.scr != scrList {
		t.Fatal("esc must return to the list")
	}
	a.m.scr = scrReceipts
	a.m.unlocked([]vaultlib.Entry{{Name: []byte("w"), Secret: []byte("s")}},
		[]byte("k"), []byte("s"), testIters, 0)
	a.m.scr = scrReceipts
	a.keyReceipts(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyCtrlL})
	if a.m.scr != scrLocked || a.m.rcpts != nil {
		t.Fatalf("ctrl-l on receipts must lock + drop the view, scr=%d", a.m.scr)
	}
}
