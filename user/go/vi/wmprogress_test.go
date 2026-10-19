package vi

import "testing"

func TestEncodeProgressTitleWireLayout(t *testing.T) {
	title, ok := EncodeProgressTitle(3, 42, "Copying files")
	if !ok {
		t.Fatal("encode refused op=3")
	}
	if title[0] != 3 || title[1] != 42 {
		t.Fatalf("title head = %v, want op=3 pct=42", title[:2])
	}
	if got := string(title[2:2+len("Copying files")]); got != "Copying files" {
		t.Fatalf("label = %q", got)
	}
	if title[2+len("Copying files")] != 0 {
		t.Fatal("label was not NUL-padded")
	}
	if _, ok := EncodeProgressTitle(0, 50, "x"); ok {
		t.Fatal("op 0 must refuse: no row can ever name it")
	}
}

func TestEncodeProgressTitleClampsAndTruncates(t *testing.T) {
	title, ok := EncodeProgressTitle(1, 250, "")
	if !ok || title[1] != 100 {
		t.Fatalf("pct 250 -> %v ok=%v, want 100", title[1], ok)
	}
	title, ok = EncodeProgressTitle(1, ProgressIndeterminate, "")
	if !ok || title[1] != ProgressPctIndeterminate {
		t.Fatalf("indeterminate -> %#x, want %#x", title[1], ProgressPctIndeterminate)
	}
	long := "0123456789abcdefghijklmno" // 25 bytes > ProgressLabelMax
	title, ok = EncodeProgressTitle(2, 10, long)
	if !ok {
		t.Fatal("encode refused a long label")
	}
	if got := string(title[2:]); got != long[:ProgressLabelMax] {
		t.Fatalf("label = %q, want %q", got, long[:ProgressLabelMax])
	}
}

func TestDecodeProgressTitleRoundTripAndRefusals(t *testing.T) {
	title, _ := EncodeProgressTitle(7, 85, "sync")
	op, pct, label, ok := DecodeProgressTitle(title)
	if !ok || op != 7 || pct != 85 || label != "sync" {
		t.Fatalf("decode = op=%d pct=%d label=%q ok=%v", op, pct, label, ok)
	}
	title, _ = EncodeProgressTitle(9, ProgressIndeterminate, "indexing")
	op, pct, label, ok = DecodeProgressTitle(title)
	if !ok || op != 9 || pct != ProgressIndeterminate || label != "indexing" {
		t.Fatalf("indeterminate decode = op=%d pct=%d label=%q ok=%v", op, pct, label, ok)
	}
	var zero [WmRpcTitleMax]byte
	if _, _, _, ok := DecodeProgressTitle(zero); ok {
		t.Fatal("op 0 decoded")
	}
	zero[0] = 4
	zero[1] = 137 // neither a percent nor the indeterminate mark
	if _, _, _, ok := DecodeProgressTitle(zero); ok {
		t.Fatal("malformed pct byte decoded")
	}
	zero[1] = 100
	if op, pct, label, ok := DecodeProgressTitle(zero); !ok || op != 4 || pct != 100 || label != "" {
		t.Fatalf("empty-label decode = op=%d pct=%d label=%q ok=%v", op, pct, label, ok)
	}
}

func TestPollProgressCancelMatchesKindIdAndAuth(t *testing.T) {
	resetWmAuth()
	defer resetWmAuth()
	defer resetSettingChangeQueue()
	// An unbound window accepts the plain notice for its own id only.
	enqueueWmMessage(WmRpc{Kind: WmRpcKindProgressCancel, ID: 8})
	enqueueWmMessage(WmRpc{Kind: WmRpcKindProgressCancel, ID: 4})
	var e WmRpc
	e.Kind = WmRpcKindProgressCancel
	e.ID = 4
	e.Title[0] = 3
	enqueueWmMessage(e)
	op, ok := PollProgressCancel(4)
	if !ok || op != 3 {
		t.Fatalf("poll = op=%d ok=%v, want op=3", op, ok)
	}
	// The foreign-id notice was consumed by the mailbox walk; op 0 is
	// refused as a payload, so it stays queued and never matches.
	if _, ok := PollProgressCancel(4); ok {
		t.Fatal("a second poll returned a cancel")
	}
	if _, ok := PollProgressCancel(9); ok {
		t.Fatal("a window with no queued cancel got one")
	}
}

func TestPollProgressCancelBoundWindowWantsTheToken(t *testing.T) {
	resetWmAuth()
	defer resetWmAuth()
	defer resetSettingChangeQueue()
	setWmToken(5, 0xfeed)
	forged := WmRpc{Kind: WmRpcKindProgressCancel, ID: 5}
	forged.Title[0] = 2
	enqueueWmMessage(forged) // Pad=Plain, no token
	if _, ok := PollProgressCancel(5); ok {
		t.Fatal("a bound window accepted an unsigned cancel")
	}
	genuine := WmRpc{Kind: WmRpcKindProgressCancel, ID: 5, Pad: WmRpcPadBound}
	genuine.Title[0] = 2
	SetWmAuth(&genuine, 0xfeed)
	enqueueWmMessage(genuine)
	op, ok := PollProgressCancel(5)
	if !ok || op != 2 {
		t.Fatalf("bound poll = op=%d ok=%v, want op=2", op, ok)
	}
}
