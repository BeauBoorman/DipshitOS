package vi

// ADR 0044 D5 / AC2: the WmWindows client assembly — paging, flag decode,
// the applied=0 → ErrSeatUnsupported verdict, and the silent-seat →
// ErrSeatSilent path. The seat side's own paging tests live in gotabwm's
// windows_query_test.go.

import "testing"

// wqSeat scripts a WINDOWS_QUERY seat: for each fresh request it emits the
// D5 page — applied row frames for [start, min(start+4, count)) or one
// applied=0 frame when start >= count.
type wqSeat struct {
	rows  []WmWindowRow
	queue [][]byte
	// dropAt is the page index (0-based request count) whose replies are
	// truncated by one frame — the mid-page loss a dropped send produces.
	dropAt int
	// servedSeq marks the request seq already answered: a dropped frame
	// is never re-sent, so re-asking the same seq is silence.
	servedSeq uint8
	served    bool
	sent      int
}

func (s *wqSeat) reply(req WmRpc) []byte {
	if req.Kind != wmRpcKindWindowsQuery {
		return nil
	}
	if !s.served || req.Seq != s.servedSeq {
		start := int(req.ID)
		count := len(s.rows)
		end := start + wmQueryPageSize
		if end > count {
			end = count
		}
		for i := start; i < end; i++ {
			w := s.rows[i]
			rep := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
				ID: uint8(i), Seq: req.Seq, ReplyTo: req.ReplyTo,
				Applied: 1, Pad: WmRpcPadPlain,
				X: uint16(w.ID), W: uint16(count)}
			var flags uint16
			if w.Focused {
				flags |= 0x1
			}
			if w.Pinned {
				flags |= 0x2
			}
			if w.Frozen {
				flags |= 0x4
			}
			rep.Y = flags
			rep.SetTitle(w.Title)
			s.queue = append(s.queue, rep.Encode())
		}
		if start >= count {
			rep := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
				ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
				Applied: 0, Pad: WmRpcPadPlain, W: uint16(count)}
			s.queue = append(s.queue, rep.Encode())
		}
		if s.dropAt == s.sent && len(s.queue) > 0 {
			s.queue = s.queue[:len(s.queue)-1] // mid-page loss
		}
		s.sent++
		s.served = true
		s.servedSeq = req.Seq
	}
	if len(s.queue) == 0 {
		return nil
	}
	r := s.queue[0]
	s.queue = s.queue[1:]
	return r
}

func startWqFake(t *testing.T, seat *wqSeat) *wmMailFake {
	t.Helper()
	f := startWmMailFake(t)
	f.wmName = wmGoSeatName
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
		seat := &wqSeat{rows: wqRows(n), dropAt: -1}
		startWqFake(t, seat)
		rows, err := WmWindows("NOTE.ELF")
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
	}
}

// A Zig seat answers applied=0 for the unknown kind, and so does a Go seat
// whose strip cannot answer — both are ErrSeatUnsupported (D3).
func TestWmWindowsUnsupported(t *testing.T) {
	f := startWqFake(t, nil)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: wmRpcKindWindowsQuery | WmRpcReplyFlag,
			ID: req.ID, Seq: req.Seq, ReplyTo: req.ReplyTo,
			Applied: 0, Pad: WmRpcPadPlain}
		return rep.Encode()
	}
	if _, err := WmWindows("NOTE.ELF"); err != ErrSeatUnsupported {
		t.Fatalf("applied=0 seat err = %v want ErrSeatUnsupported", err)
	}
}

// A seat that never answers is silent, and the wait is a bounded park —
// sleep calls, not a yield spin.
func TestWmWindowsSilentSeat(t *testing.T) {
	f := startWqFake(t, nil)
	if _, err := WmWindows("NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("silent seat err = %v want ErrSeatSilent", err)
	}
	if f.sleepCalls == 0 || f.sleepCalls > wmQueryTicks+2 {
		t.Fatalf("sleepCalls = %d want a small tick bound", f.sleepCalls)
	}
}

// A page that drops a frame mid-way is a silent seat: the expected row
// never arrives and the shared budget expires.
func TestWmWindowsMidPageDrop(t *testing.T) {
	seat := &wqSeat{rows: wqRows(8), dropAt: 0}
	startWqFake(t, seat)
	if _, err := WmWindows("NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("dropped page err = %v want ErrSeatSilent", err)
	}
}

// An empty strip answers applied=0 for the first page — unsupported, the
// same verdict the gate reads for a Zig seat.
func TestWmWindowsEmptyStrip(t *testing.T) {
	seat := &wqSeat{rows: nil, dropAt: -1}
	startWqFake(t, seat)
	if _, err := WmWindows("NOTE.ELF"); err != ErrSeatUnsupported {
		t.Fatalf("empty strip err = %v want ErrSeatUnsupported", err)
	}
}

// No resolvable peers at all is silent, not a crash.
func TestWmWindowsNoPeers(t *testing.T) {
	f := startWqFake(t, nil)
	f.selfPID = 0x100 // self pid cannot fit the wire
	if _, err := WmWindows("NOTE.ELF"); err != ErrSeatSilent {
		t.Fatalf("unresolvable self err = %v want ErrSeatSilent", err)
	}
}
