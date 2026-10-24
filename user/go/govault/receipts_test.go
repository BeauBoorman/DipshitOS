package main

// The class-A receipts legs the card names: the row codec (format/parse
// round-trip, corrupt rows kept), the append path through the injected file
// seam, and the receipts view's load/clear contract. Pure — time and the
// append are seams, the rows are plain bytes.

import "testing"

// The row is "<epoch> <action> <name>" with the name as the rest of the
// line — a multi-word vaultlib.Entry name round-trips without escaping, and a
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
