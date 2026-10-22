// The agentd seat query (ADR 0044 D5): WM_RPC kind 16, WINDOWS_QUERY, a
// seat-wide read-only ask. It is NOT exempt from the M97g-F2 bind — the
// caller presents a window it owns, walks the same ownership challenge
// every other request walks, and its page requests then carry the session
// token (owner ruling: auth wins). The page index rides request title[0]
// because id is the bound window and x/y/w/h are the auth union; replies
// arrive Pad=Bound quoting the token, so a forged row cannot satisfy the
// wait. Agentd is its only caller; wmclient.go's request path is untouched.
package vi

import "errors"

// wmRpcKindWindowsQuery is the additive kind-16 request. Declared here and
// not in wmclient.go's frozen const block because kind 16 postdates that
// table (ADR 0044 D5).
const wmRpcKindWindowsQuery uint8 = 16

// wmQueryPageSize is the seat's per-request row bound (D5: four frames fit
// the 8-slot mailbox ring).
const wmQueryPageSize = 4

// wmQueryTicks bounds the WHOLE paged exchange: one budget shared across
// every page and any bind round-trips so a pathological seat cannot
// stretch the caller past the daemon's seat_timeout bound.
const wmQueryTicks = wmMailWaitTicks + 1

// The two refusal shapes ui.windows distinguishes (ADR 0044 D3/D4):
// unsupported is the seat answering applied=0 (a Zig seat, or a strip that
// cannot answer the query); silent is no complete answer inside the budget
// — timeout, no resolvable peers, a dropped request, or a bind the seat
// never completes.
var (
	ErrSeatUnsupported = errors.New("vi: seat cannot answer windows_query")
	ErrSeatSilent      = errors.New("vi: seat gave no complete windows answer")
)

// WmWindowRow is one decoded WINDOWS_QUERY row frame: the strip index, the
// kernel window id, the tab title, and the three flag bits (D5).
type WmWindowRow struct {
	Index   int
	ID      uint32
	Title   string
	Focused bool
	Pinned  bool
	Frozen  bool
}

// wqStatus is the per-page outcome: rows collected, the seat refused the
// query itself, or the budget ran out (including a bind that never
// finished).
const (
	wqOK = iota
	wqUnsupported
	wqSilent
)

// WmWindows binds winID — a window the caller owns — to the registered Go
// seat and pages its whole strip, returning rows in strip order. Errors:
//   - ErrSeatUnsupported: the seat answered applied=0 — the Zig seats
//     refuse unknown kinds that way, and so does a Go seat whose strip
//     cannot answer (an off-strip start included).
//   - ErrSeatSilent: no seat peers resolved, winID does not fit the wire,
//     a send failed, the bind never completed, or the shared tick budget
//     ran out mid-page (a page the seat abandoned is simply a silent one —
//     ENOSPC mid-page is defined behavior, D5).
func WmWindows(winID uint32, selfName string) ([]WmWindowRow, error) {
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 || !fitsWire8(peers.Self) ||
		!fitsWire8(winID) {
		return nil, ErrSeatSilent
	}
	id := uint8(winID)
	if !peers.Go {
		// Legacy seat: it cannot bind, so the bare request is all it gets —
		// unknown kinds answer applied=0, which is the unsupported shape.
		budget := wmQueryTicks
		req := wqRequest(id, 0, peers)
		if IpcSend(peers.WM, req.Encode()) < 0 {
			return nil, ErrSeatSilent
		}
		if _, ok := waitWmReply16(req.Seq, req.ReplyTo, &budget); !ok {
			return nil, ErrSeatSilent
		}
		return nil, ErrSeatUnsupported
	}
	budget := wmQueryTicks
	var rows []WmWindowRow
	for start := 0; start <= 15; {
		page, count, st := wqPage(id, start, peers, &budget)
		if st == wqUnsupported {
			return nil, ErrSeatUnsupported
		}
		if st != wqOK {
			return nil, ErrSeatSilent
		}
		rows = append(rows, page...)
		start += len(page)
		if count == 0 || start >= count {
			return rows, nil
		}
		if len(page) == 0 {
			return nil, ErrSeatSilent // an applied page must carry rows
		}
	}
	return rows, nil
}

// wqRequest builds one kind-16 frame: id is the caller's window, start is
// the page index in title[0].
func wqRequest(id uint8, start int, peers WmSeat) WmRpc {
	req := WmRpc{Kind: wmRpcKindWindowsQuery, ID: id, Seq: nextWmSeq(),
		ReplyTo: uint8(peers.Self)}
	req.Title[0] = byte(start)
	return req
}

// wqPage drives one paged request to a bound answer. It performs the
// ownership challenge inline when the window is unbound (or the seat
// re-challenges a stale token), exactly the wmRequestGo flow: the echoed
// request is itself the query, so its first bound frame both mints the
// token and opens the page.
func wqPage(id uint8, start int, peers WmSeat, budget *int) ([]WmWindowRow, int, int) {
	for round := 0; round < wmBindMaxRounds; round++ {
		token := wmToken(id)
		req := wqRequest(id, start, peers)
		if token != 0 {
			req.Pad = WmRpcPadBound
			SetWmAuth(&req, token)
		}
		if IpcSend(peers.WM, req.Encode()) < 0 {
			return nil, 0, wqSilent
		}
		// Bound frames quote the session token in x/y/w/h, so the row
		// payload rides ID + title: title[0:2] is the window id, title[2]
		// the flags, title[3:] the tab title. One applied=0 end-of-page
		// frame (title[0]=count) always terminates the page — a Challenge
		// pad instead means the seat has no binding for id: fresh window,
		// or a restarted seat that forgot the token.
		var rows []WmWindowRow
		echoes := 0 // challenge->echo pairs cap at wmBindMaxRounds, same as wmRequestGoTitle
		for {
			m, ok := waitWmReply16(req.Seq, req.ReplyTo, budget)
			if !ok {
				break
			}
			switch m.Pad {
			case WmRpcPadChallenge:
				challenge := WmAuth(m)
				echoes++
				if challenge == 0 || echoes > wmBindMaxRounds ||
					bindSetTitle(int(id), WmBindChallengeTitle(challenge, req.ReplyTo)) != 0 {
					return nil, 0, wqSilent
				}
				req.Seq = nextWmSeq()
				req.Pad = WmRpcPadBound
				SetWmAuth(&req, challenge)
				if IpcSend(peers.WM, req.Encode()) < 0 {
					return nil, 0, wqSilent
				}
				token = 0 // next bound frame mints the token
				continue
			case WmRpcPadBound:
				if token == 0 {
					// First bound frame after the echo mints the session
					// token (wmRequestGo's accept shape) — and it is
					// itself a row/end frame, so fall through.
					token = WmAuth(m)
					if token == 0 {
						return nil, 0, wqSilent
					}
					setWmToken(id, token)
				}
				if WmAuth(m) != token {
					continue // a bound frame quoting another value is a forgery
				}
				if m.Applied == 0 {
					// End of page: title[0] is the strip count. A zero
					// count on an unanswered page is the seat's
					// refused-query shape (D3).
					if m.Title[0] == 0 && len(rows) == 0 {
						return nil, 0, wqUnsupported
					}
					return rows, int(m.Title[0]), wqOK
				}
				rows = append(rows, WmWindowRow{
					Index:   int(m.ID),
					ID:      uint32(m.Title[0]) | uint32(m.Title[1])<<8,
					Title:   titleTail(m),
					Focused: m.Title[2]&0x1 != 0,
					Pinned:  m.Title[2]&0x2 != 0,
					Frozen:  m.Title[2]&0x4 != 0,
				})
			}
		}
		// Silent round: a stale token can only rebind, an unbound request
		// can only retry — either way, drop any cached token first.
		if wmToken(id) != 0 {
			setWmToken(id, 0)
		}
	}
	return nil, 0, wqSilent
}

// titleTail reads the NUL-trimmed tab title out of a row frame — the row
// payload starts at title[3] because the frame's own x/y/w/h union holds
// the session token (D5).
func titleTail(m WmRpc) string {
	n := 3
	for n < WmRpcTitleMax && m.Title[n] != 0 {
		n++
	}
	return string(m.Title[3:n])
}

// waitWmReply16 waits for one kind-16 reply frame matching seq+reply_to,
// spending from the caller's shared tick budget. Foreign replies are queued
// for their own consumers, exactly as waitWmRpcAck does.
func waitWmReply16(seq, replyTo uint8, ticks *int) (WmRpc, bool) {
	matches := func(m WmRpc) bool {
		return m.Kind == wmRpcKindWindowsQuery|WmRpcReplyFlag &&
			m.Seq == seq && m.ReplyTo == replyTo
	}
	for {
		if m, ok := takePendingWmMessage(matches); ok {
			return m, true
		}
		if m, ok := receiveWmMessage(); ok {
			if matches(m) {
				return m, true
			}
			enqueueWmMessage(m)
			continue
		}
		if *ticks <= 0 {
			return WmRpc{}, false
		}
		*ticks--
		_ = svc1(SlotSleep, 1)
	}
}
