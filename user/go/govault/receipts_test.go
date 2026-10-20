package main

// The class-A receipts legs the card names: the row codec (format/parse
// round-trip, corrupt rows kept), the append path through the injected file
// seam, and the receipts view's load/clear contract. Pure — time and the
// append are seams, the rows are plain bytes.

import (
	"testing"

	"virelai/vi"
)

// The row is "<epoch> <action> <name>" with the name as the rest of the
// line — a multi-word entry name round-trips without escaping, and a
// vault-level action records "-".
func TestReceiptLineShape(t *testing.T) {
	line := receiptLine(1729440000, actReveal, "wifi router")
	want := "1729440000 reveal wifi router\n"
	if string(line) != want {
		t.Fatalf("receiptLine = %q, want %q", line, want)
	}
	if got := string(receiptLine(0, actUnlock, "")); got != "0 unlock -\n" {
		t.Fatalf("vault-level row = %q, want \"0 unlock -\\n\"", got)
	}
}

// Parse is the format's inverse, and a line that is not a receipt row is
// kept verbatim with ok=false — a hand-mangled audit row is still a row.
func TestParseReceipts(t *testing.T) {
	var data []byte
	data = append(data, receiptLine(100, actUnlock, "")...)
	data = append(data, receiptLine(101, actReveal, "wifi")...)
	data = append(data, receiptLine(102, actCopy, "wifi")...)
	data = append(data, receiptLine(103, actUnlockFail, "")...)
	data = append(data, "this is not a receipt row\n"...)
	data = append(data, "\n"...) // a blank line drops, it is not a row

	rows := parseReceipts(data)
	if len(rows) != 5 {
		t.Fatalf("rows=%d, want 5 (4 receipts + 1 corrupt)", len(rows))
	}
	if !rows[0].ok || rows[0].epoch != 100 || rows[0].action != actUnlock || rows[0].name != "-" {
		t.Fatalf("row0 = %+v", rows[0])
	}
	if rows[1].name != "wifi" || rows[2].action != actCopy {
		t.Fatalf("rows 1/2 = %+v / %+v", rows[1], rows[2])
	}
	if rows[3].action != actUnlockFail {
		t.Fatalf("row3 action = %q", rows[3].action)
	}
	if rows[4].ok || rows[4].action != rcptCorruptRow || rows[4].raw != "this is not a receipt row" {
		t.Fatalf("corrupt row = %+v — must keep the line verbatim", rows[4])
	}
	if len(parseReceipts(nil)) != 0 {
		t.Fatal("an absent/empty file parses to zero rows, not one empty row")
	}
}

// receipt() appends through the file seam: the row carries the seam-injected
// time, the action and the entry name — and never the secret.
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
	a.m.unlocked([]entry{{name: []byte("w"), secret: []byte("s")}},
		[]byte("k"), []byte("s"), testIters, 0)
	a.m.scr = scrReceipts
	a.keyReceipts(vi.Event{Kind: vi.EvKeyDown, Flags: modCtrl, Arg1: keyCtrlL})
	if a.m.scr != scrLocked || a.m.rcpts != nil {
		t.Fatalf("ctrl-l on receipts must lock + drop the view, scr=%d", a.m.scr)
	}
}

// lock() drops the loaded receipts too — the view reloads from the file on
// entry, so a locked vault holds no stale copy.
func TestLockClearsReceipts(t *testing.T) {
	m := &model{}
	m.unlocked(nil, make([]byte, 32), make([]byte, 16), testIters, 0)
	m.rcpts = []receipt{{epoch: 1, action: actUnlock, name: "-", ok: true}}
	m.lock()
	if m.rcpts != nil {
		t.Fatal("lock left the receipts view loaded")
	}
}
