package vi

// ADR 0044 D5 / AC2: the WmWindows client assembly — the M97g-F2
// challenge→bind handshake, paged token frames, flag decode, the
// applied=0 → ErrSeatUnsupported verdict, and the silent-seat →
// ErrSeatSilent path. The seat side's own paging tests live in gotabwm's
// windows_query_test.go.

import "testing"

// wqSeat scripts a WINDOWS_QUERY seat under the Go bind protocol: an
// unbound request is challenged, a correct echo binds and answers with
// token rows, and a bound request with the wrong credentials is refused
// plainly. For each bound request it emits the D5 page — applied row
// frames for [start, min(start+4, count)) or one applied=0 frame when
// start >= count.
type wqSeat struct {
	rows      []WmWindowRow
	queue     [][]byte
	challenge uint64 // outstanding challenge (0 = none minted yet)
	token     uint64 // bound session token (0 = unbound)
	boundPid  uint8
	// dropAt is the request count (0-based) whose replies are truncated
	// by one frame — the mid-page loss a dropped send produces.
	dropAt int
	// forgeAt is the request count whose rows quote token^0xff — the
	// forged-bound-frame shape.
	forgeAt int
	// neverBind keeps answering echoes with a fresh challenge — the bind
	// that never completes.
	neverBind bool
	// rechallengeAt is the request count the seat answers with a fresh
	// challenge even though the window was bound — the restarted-seat
	// (forgotten binding) shape.
	rechallengeAt int
	sent          int
	// answeredSeq is the seq of the request already answered: the fake is
	// polled once per recv, and a dropped frame is never re-sent, so an
	// answered request re-answers silence.
	answeredSeq uint8
	answered    bool
}

func (s *wqSeat) reply(req WmRpc) []byte {
	if req.Kind != wmRpcKindWindowsQuery {
		return nil
	}
	if s.answered && req.Seq == s.answeredSeq {
		if len(s.queue) == 0 {
			return nil
		}
	} else {
		s.sent++
		n := s.sent - 1
		auth := WmAuth(req)
		switch {
		case s.token != 0 && n == s.rechallengeAt:
			// The seat "restarted" and forgot the binding: re-challenge.
			s.token = 0
			s.challenge = 0x0b1ade
			rep := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
				ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
				Pad: WmRpcPadChallenge}
			SetWmAuth(&rep, s.challenge)
			s.queue = append(s.queue, rep.Encode())
		case s.neverBind || (s.token == 0 && (s.challenge == 0 || auth != s.challenge)):
			// Unbound (or an unproven echo): challenge — same whether the
			// frame carried no auth or a guess.
			if s.challenge == 0 {
				s.challenge = 0x0a11ce
			}
			rep := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
				ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
				Pad: WmRpcPadChallenge}
			SetWmAuth(&rep, s.challenge)
			s.queue = append(s.queue, rep.Encode())
		case s.token != 0 && (auth != s.token || req.ReplyTo != s.boundPid):
			// Bound window, wrong credentials: bare refusal, no rows.
			rep := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
				ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
				Pad: WmRpcPadPlain}
			s.queue = append(s.queue, rep.Encode())
		case s.token == 0 && auth == s.challenge:
			// Proven echo: bind and answer — the echo IS a page request.
			s.token = 0x7ab1e5
			s.boundPid = req.ReplyTo
			s.challenge = 0
			s.page(req, n)
		default:
			// Bound and credentialed: page rows.
			s.page(req, n)
		}
		s.answered = true
		s.answeredSeq = req.Seq
	}
	if len(s.queue) == 0 {
		return nil
	}
	r := s.queue[0]
	s.queue = s.queue[1:]
	return r
}

// page emits this request's row frames plus the applied=0 end-of-page
// frame, all Pad=Bound quoting the token. Row payloads ride ID + title
// because x/y/w/h are the auth union.
func (s *wqSeat) page(req WmRpc, n int) {
	auth := s.token
	if n == s.forgeAt {
		auth ^= 0xff
	}
	start := int(req.Title[0])
	count := len(s.rows)
	end := start + wmQueryPageSize
	if end > count {
		end = count
	}
	for i := start; i < end; i++ {
		w := s.rows[i]
		rep := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
			ID: uint8(i), Seq: req.Seq, ReplyTo: req.ReplyTo,
			Applied: 1, Pad: WmRpcPadBound}
		rep.Title[0] = byte(w.ID)
		rep.Title[1] = byte(w.ID >> 8)
		var flags byte
		if w.Focused {
			flags |= 0x1
		}
		if w.Pinned {
			flags |= 0x2
		}
		if w.Frozen {
			flags |= 0x4
		}
		rep.Title[2] = flags
		copy(rep.Title[3:], w.Title)
		SetWmAuth(&rep, auth)
		s.queue = append(s.queue, rep.Encode())
	}
	// The end-of-page frame always follows — title[0] is the strip count.
	term := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
		ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
		Applied: 0, Pad: WmRpcPadBound}
	term.Title[0] = byte(count)
	SetWmAuth(&term, auth)
	s.queue = append(s.queue, term.Encode())
	if n == s.dropAt && len(s.queue) > 0 {
		s.queue = s.queue[:len(s.queue)-1] // mid-page loss
	}
}

// startWqFake installs the mailbox fake with a Go seat and stubs the
// ownership-proof title write — the kernel's slot 61 is -ENOSYS off-guest.
func startWqFake(t *testing.T, seat *wqSeat) *wmMailFake {
	t.Helper()
	f := startWmMailFake(t)
	f.wmName = wmGoSeatName
	prev := bindSetTitle
	bindSetTitle = func(int, string) int64 { return 0 }
	t.Cleanup(func() { bindSetTitle = prev })
	if seat != nil {
		f.replyFn = seat.reply
	}
	return f
}

func wqRows(n int) []WmWindowRow {
	rows := make([]WmWindowRow, n)
	for i := 0; i < n; i++ {
		rows[i] = WmWindowRow{ID: uint32(100 + i), Title: "T"}
	}
	rows[0].Focused = true
	return rows
}

func TestWmWindowsPages(t *testing.T) {
	for _, n := range []int{1, 4, 5, 16} {
		seat := &wqSeat{rows: wqRows(n), dropAt: -1, forgeAt: -1, rechallengeAt: -1}
		f := startWqFake(t, seat)
		rows, err := WmWindows(7, "NOTE.ELF")
		if err != nil {
			t.Fatalf("n=%d: %v", n, err)
		}
		if len(rows) != n {
			t.Fatalf("n=%d: got %d rows", n, len(rows))
		}
		for i, w := range rows {
			if w.Index != i || w.ID != uint32(100+i) {
				t.Fatalf("n=%d row %d = %+v", n, i, w)
			}
		}
		if !rows[0].Focused {
			t.Fatalf("n=%d: row 0 lost the focused bit", n)
		}
		if n > 1 && rows[1].Focused {
			t.Fatalf("n=%d: two focused rows", n)
		}
		// Every request carried the caller's window id, and the page
		// index rode title[0] — the bind must not see a page index
		// where the window id belongs. Sent order: bare, echo (start 0),
		// then one bound request per further page.
		for i, req := range f.sent {
			if req.ID != 7 {
				t.Fatalf("n=%d req %d ID = %d want the bound window 7", n, i, req.ID)
			}
			want := 0
			if i > 1 {
				want = (i - 1) * 4
			}
			if int(req.Title[0]) != want {
				t.Fatalf("n=%d req %d title[0] = %d want %d", n, i, req.Title[0], want)
			}
		}
	}
}

// The handshake itself: a bare request is challenged, the echo carries the
// challenge in the auth union, and its bound row frames mint the session
// token — which every later page request then quotes.
func TestWmWindowsBindHandshake(t *testing.T) {
	seat := &wqSeat{rows: wqRows(2), dropAt: -1, forgeAt: -1, rechallengeAt: -1}
	f := startWqFake(t, seat)
	rows, err := WmWindows(7, "NOTE.ELF")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %d", len(rows))
	}
	if len(f.sent) != 2 {
		t.Fatalf("requests = %d want bare+echo", len(f.sent))
	}
	bare, echo := f.sent[0], f.sent[1]
	if WmAuth(bare) != 0 || bare.Pad != 0 {
		t.Fatalf("first request = %+v want unauthenticated", bare)
	}
	if echo.Pad != WmRpcPadBound || WmAuth(echo) != 0x0a11ce {
		t.Fatalf("echo = %+v want bound + challenge echo", echo)
	}
	if wmToken(7) != seat.token {
		t.Fatalf("cached token = %#x want %#x", wmToken(7), seat.token)
	}
}

// A bound window's next WmWindows call skips the handshake entirely — the
// first request already quotes the cached token.
func TestWmWindowsReusesBinding(t *testing.T) {
	seat := &wqSeat{rows: wqRows(1), dropAt: -1, forgeAt: -1, rechallengeAt: -1}
	f := startWqFake(t, seat)
	if _, err := WmWindows(7, "NOTE.ELF"); err != nil {
		t.Fatal(err)
	}
	sent := len(f.sent)
	if _, err := WmWindows(7, "NOTE.ELF"); err != nil {
		t.Fatal(err)
	}
	if len(f.sent) != sent+1 {
		t.Fatalf("second query sent %d more requests want 1", len(f.sent)-sent)
	}
	last := f.sent[len(f.sent)-1]
	if last.Pad != WmRpcPadBound || WmAuth(last) != seat.token {
		t.Fatalf("second query request = %+v want bound+token", last)
	}
}

// A seat that forgot the binding re-challenges; the client drops its stale
// token, walks the handshake again, and still gets its rows.
func TestWmWindowsRebindsAfterSeatRestart(t *testing.T) {
	// Request n=2 is the second call's bound page request — the seat
	// "forgot" the binding and re-challenges it.
	seat := &wqSeat{rows: wqRows(1), dropAt: -1, forgeAt: -1, rechallengeAt: 2}
	startWqFake(t, seat)
	if _, err := WmWindows(7, "NOTE.ELF"); err != nil {
		t.Fatal(err)
	}
	rows, err := WmWindows(7, "NOTE.ELF")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || seat.challenge != 0 {
		t.Fatalf("rebind rows = %+v challenge = %#x", rows, seat.challenge)
	}
}

// Bound frames quoting a different value are forgeries: consumed and
// dropped, they neither satisfy the wait nor mint a token.
func TestWmWindowsDropsForgedBoundFrames(t *testing.T) {
	// Request n=2 is the second page's bound request: its rows quote the
	// wrong token, so the page goes unanswered and the budget expires.
	seat := &wqSeat{rows: wqRows(8), dropAt: -1, forgeAt: 2, rechallengeAt: -1}
	startWqFake(t, seat)
	if _, err := WmWindows(7, "NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("forged-only page err = %v want ErrSeatSilent", err)
	}
}

// A Zig seat answers applied=0 for the unknown kind, and so does a Go seat
// whose strip cannot answer — both are ErrSeatUnsupported (D3).
func TestWmWindowsUnsupported(t *testing.T) {
	f := startWmMailFake(t)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
			ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
			Applied: 0, Pad: WmRpcPadPlain}
		return rep.Encode()
	}
	if _, err := WmWindows(7, "NOTE.ELF"); err != ErrSeatUnsupported {
		t.Fatalf("applied=0 seat err = %v want ErrSeatUnsupported", err)
	}

	// A bound request the Go seat refuses (applied=0 row frame).
	seat := &wqSeat{rows: nil, dropAt: -1, forgeAt: -1, rechallengeAt: -1}
	startWqFake(t, seat)
	if _, err := WmWindows(7, "NOTE.ELF"); err != ErrSeatUnsupported {
		t.Fatalf("empty-strip err = %v want ErrSeatUnsupported", err)
	}
}

// A seat that never answers is silent, and the wait is a bounded park —
// sleep calls, not a yield spin.
func TestWmWindowsSilentSeat(t *testing.T) {
	f := startWqFake(t, nil)
	if _, err := WmWindows(7, "NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("silent seat err = %v want ErrSeatSilent", err)
	}
	if f.sleepCalls == 0 || f.sleepCalls > wmQueryTicks+2 {
		t.Fatalf("sleepCalls = %d want a small tick bound", f.sleepCalls)
	}
}

// A page that drops a frame mid-way is a silent seat: the expected row
// never arrives and the shared budget expires.
func TestWmWindowsMidPageDrop(t *testing.T) {
	seat := &wqSeat{rows: wqRows(8), dropAt: 1, forgeAt: -1, rechallengeAt: -1}
	startWqFake(t, seat)
	if _, err := WmWindows(7, "NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("dropped page err = %v want ErrSeatSilent", err)
	}
}

// A bind that never completes — challenge after challenge — is silent,
// bounded by the same tick budget.
func TestWmWindowsBindNeverCompletes(t *testing.T) {
	seat := &wqSeat{rows: wqRows(2), neverBind: true}
	startWqFake(t, seat)
	if _, err := WmWindows(7, "NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("never-bind err = %v want ErrSeatSilent", err)
	}
}

// No resolvable peers at all is silent, not a crash.
func TestWmWindowsNoPeers(t *testing.T) {
	f := startWqFake(t, nil)
	f.selfPID = 0x100 // self pid cannot fit the wire
	if _, err := WmWindows(7, "NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("unresolvable self err = %v want ErrSeatSilent", err)
	}
	if _, err := WmWindows(0x100, "NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("wide window id err = %v want ErrSeatSilent", err)
	}
}
