package vi

import "testing"

// M124a (#2580): the drag protocol's transport half — the envelope the
// staged rendezvous carries, and the client-side request/notice surface.

// The envelope round-trips mime + blob byte-exact, and every malformed or
// over-bounded shape is refused rather than trusted.
func TestDragEnvelopeRoundTrip(t *testing.T) {
	blob := []byte("hello caret")
	enc, ok := EncodeDrag("text/plain", blob)
	if !ok {
		t.Fatal("encode refused a legal payload")
	}
	mime, got, ok := DecodeDrag(enc)
	if !ok || mime != "text/plain" || string(got) != string(blob) {
		t.Fatalf("decode = %q %q %v", mime, got, ok)
	}
}

func TestDragEnvelopeRefusals(t *testing.T) {
	if _, ok := EncodeDrag("", []byte("x")); ok {
		t.Fatal("empty mime encoded")
	}
	if _, ok := EncodeDrag(string(make([]byte, WmRpcTitleMax+1)), nil); ok {
		t.Fatal("over-title mime encoded")
	}
	if _, ok := EncodeDrag("text/plain", make([]byte, DragMax+1)); ok {
		t.Fatal("over-bound blob encoded")
	}
	cases := [][]byte{
		nil,                        // empty
		{0, 0, 0, 0, 0},            // zero mime_len
		{25, 'a', 'b'},             // mime_len over the title bound
		{4, 't', 'e', 'x', 't'},    // header short of the len word
		{4, 't', 'e', 'x', 't', 3}, // declared len mismatches the file size
	}
	for i, c := range cases {
		if _, _, ok := DecodeDrag(c); ok {
			t.Fatalf("case %d decoded", i)
		}
	}
	// Declared length over DragMax.
	over := []byte{1, 'x', 0, 0, 0, 0}
	putU32(over[2:], DragMax+1)
	if _, _, ok := DecodeDrag(over); ok {
		t.Fatal("over-max length decoded")
	}
}

func TestDragPathIsDerivedNotNegotiated(t *testing.T) {
	if DragPath(7) != "/host/DRAG.7" || DragPath(0) != "/host/DRAG.0" {
		t.Fatalf("DragPath = %q %q", DragPath(7), DragPath(0))
	}
}

// DragBegin stages the envelope at the window's rendezvous path and posts
// kind-24 carrying the mime in the title; a refused ack removes the
// staging (the handoff was never claimed).
func TestDragBeginStagesThenPosts(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const token = uint64(0xBEE5)
	setWmToken(7, token)
	var written, deleted []string
	prevW, prevD := dragFileWrite, dragFileDelete
	dragFileWrite = func(path string, b []byte) int64 {
		written = append(written, path)
		return 0
	}
	dragFileDelete = func(path string) int64 {
		deleted = append(deleted, path)
		return 0
	}
	defer func() { dragFileWrite, dragFileDelete = prevW, prevD }()
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Pad: WmRpcPadBound, Applied: 1}
		SetWmAuth(&rep, token)
		return rep.Encode()
	}
	if !DragBegin(7, "text/plain", []byte("hi"), "NOTE.ELF") {
		t.Fatal("drag begin refused")
	}
	if len(written) != 1 || written[0] != "/host/DRAG.7" {
		t.Fatalf("staged = %v", written)
	}
	if len(deleted) != 0 {
		t.Fatalf("an applied arm deleted its own staging: %v", deleted)
	}
	if len(f.sent) != 1 {
		t.Fatalf("sent %d want 1", len(f.sent))
	}
	s := f.sent[0]
	if s.Kind != WmRpcKindDragBegin || s.TitleString() != "text/plain" ||
		s.Pad != WmRpcPadBound || WmAuth(s) != token {
		t.Fatalf("frame = %+v", s)
	}
}

func TestDragBeginRefusedAckCleansStaging(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const token = uint64(0xBEE5)
	setWmToken(7, token)
	var deleted []string
	prevW, prevD := dragFileWrite, dragFileDelete
	dragFileWrite = func(path string, b []byte) int64 { return 0 }
	dragFileDelete = func(path string) int64 {
		deleted = append(deleted, path)
		return 0
	}
	defer func() { dragFileWrite, dragFileDelete = prevW, prevD }()
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Pad: WmRpcPadBound, Applied: 0}
		SetWmAuth(&rep, token)
		return rep.Encode()
	}
	if DragBegin(7, "text/plain", []byte("hi"), "NOTE.ELF") {
		t.Fatal("a refused arm reported applied")
	}
	if len(deleted) != 1 || deleted[0] != "/host/DRAG.7" {
		t.Fatalf("cleanup = %v", deleted)
	}
}

// A staged envelope waits for DragTake to consume it — read, delete,
// decode; absent staging is an honest miss.
func TestDragTakeConsumesTheEnvelope(t *testing.T) {
	enc, _ := EncodeDrag("image/png", []byte{0x89, 'P', 'N', 'G'})
	var reads, deleted []string
	prevR, prevD := dragFileRead, dragFileDelete
	dragFileRead = func(path string, max int) ([]byte, int64) {
		reads = append(reads, path)
		return enc, int64(len(enc))
	}
	dragFileDelete = func(path string) int64 {
		deleted = append(deleted, path)
		return 0
	}
	defer func() { dragFileRead, dragFileDelete = prevR, prevD }()
	mime, blob, ok := DragTake(3)
	if !ok || mime != "image/png" || len(blob) != 4 {
		t.Fatalf("take = %q %v %v", mime, blob, ok)
	}
	if len(reads) != 1 || reads[0] != "/host/DRAG.3" ||
		len(deleted) != 1 || deleted[0] != "/host/DRAG.3" {
		t.Fatalf("reads=%v deleted=%v", reads, deleted)
	}
	// Second take finds nothing — consume-on-use.
	dragFileRead = func(path string, max int) ([]byte, int64) { return nil, -ErrENOENT }
	if _, _, ok := DragTake(3); ok {
		t.Fatal("a consumed handoff decoded again")
	}
}

// PollDragNotice decodes both seat→app roles and refuses forged frames:
// a bound window accepts only notices carrying its session token.
func TestPollDragNoticeRoles(t *testing.T) {
	f := startWmMailFake(t)
	const token = uint64(0xD00D)
	setWmToken(3, token)
	deliver := WmRpc{Kind: WmRpcKindDragDrop, ID: 3, Seq: 0, Applied: 7,
		Pad: WmRpcPadBound}
	SetWmAuth(&deliver, token)
	deliver.SetTitle("image/png")
	receipt := WmRpc{Kind: WmRpcKindDragDrop, ID: 3, Seq: 1, Applied: 9,
		Pad: WmRpcPadBound}
	SetWmAuth(&receipt, token)
	cancel := WmRpc{Kind: WmRpcKindDragCancel, ID: 3, Pad: WmRpcPadBound}
	SetWmAuth(&cancel, token)
	f.replies = [][]byte{deliver.Encode(), receipt.Encode(), cancel.Encode()}
	f.replyAt = 1

	n, ok := PollDragNotice(3)
	if !ok || n.Kind != WmRpcKindDragDrop || n.Receipt || n.Peer != 7 || n.Mime != "image/png" {
		t.Fatalf("delivery = %+v ok=%v", n, ok)
	}
	n, ok = PollDragNotice(3)
	if !ok || !n.Receipt || n.Peer != 9 {
		t.Fatalf("receipt = %+v", n)
	}
	n, ok = PollDragNotice(3)
	if !ok || n.Kind != WmRpcKindDragCancel {
		t.Fatalf("cancel = %+v", n)
	}
	if _, ok := PollDragNotice(3); ok {
		t.Fatal("an exhausted inbox answered again")
	}
}

func TestPollDragNoticeForgedIsNotDelivered(t *testing.T) {
	f := startWmMailFake(t)
	const token = uint64(0xD00D)
	setWmToken(3, token)
	// A kind-25 notice for a bound window quoting no token is not a
	// delivery — it is parked for nobody and PollDragNotice reports miss.
	forged := WmRpc{Kind: WmRpcKindDragDrop, ID: 3, Seq: 0, Applied: 7}
	forged.SetTitle("image/png")
	f.replies = [][]byte{forged.Encode()}
	f.replyAt = 1
	if _, ok := PollDragNotice(3); ok {
		t.Fatal("a tokenless notice satisfied the poll")
	}
}
