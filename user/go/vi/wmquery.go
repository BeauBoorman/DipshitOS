// The agentd seat query (ADR 0044 D5): WM_RPC kind 16, WINDOWS_QUERY, a
// seat-wide read-only ask that binds no window and therefore skips the
// M97g-F2 challenge exchange entirely — the seat answers it before
// gateRPC, and the reply frames arrive Pad=Plain. It is agentd's only
// client; the authenticated request path in wmclient.go is untouched.
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
// every page so a pathological seat cannot stretch the caller past the
// daemon's seat_timeout bound.
const wmQueryTicks = wmMailWaitTicks + 1

// The two refusal shapes ui.windows distinguishes (ADR 0044 D3/D4):
// unsupported is the seat answering applied=0 (a Zig seat, or a strip that
// cannot answer the query); silent is no complete answer inside the budget
// — timeout, no resolvable peers, or a dropped request.
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

// WmWindows pages the registered seat for its whole strip, returning rows
// in strip order. Errors:
//   - ErrSeatUnsupported: the seat answered applied=0 — the Zig seats
//     refuse unknown kinds that way, and so does a Go seat whose strip
//     cannot answer (the request itself draws no challenge).
//   - ErrSeatSilent: no seat peers resolved, a send failed, or the shared
//     tick budget ran out mid-page (a page the seat abandoned is simply a
//     silent one — ENOSPC mid-page is defined behavior, D5).
func WmWindows(selfName string) ([]WmWindowRow, error) {
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 || !fitsWire8(peers.Self) {
		return nil, ErrSeatSilent
	}
	var rows []WmWindowRow
	budget := wmQueryTicks
	for start := 0; start <= 15; {
		req := WmRpc{
			Kind:    wmRpcKindWindowsQuery,
			ID:      uint8(start),
			Seq:     nextWmSeq(),
			ReplyTo: uint8(peers.Self),
		}
		if IpcSend(peers.WM, req.Encode()) < 0 {
			return nil, ErrSeatSilent
		}
		expected := -1
		got := 0
		count := 0
		for {
			m, ok := waitWmReply16(req.Seq, req.ReplyTo, &budget)
			if !ok {
				return nil, ErrSeatSilent
			}
			if m.Applied == 0 {
				return nil, ErrSeatUnsupported
			}
			count = int(m.W)
			if expected < 0 {
				expected = count - start
				if expected > wmQueryPageSize {
					expected = wmQueryPageSize
				}
				if expected <= 0 {
					return nil, ErrSeatSilent // an applied row with nothing to send
				}
			}
			rows = append(rows, WmWindowRow{
				Index:   int(m.ID),
				ID:      uint32(m.X),
				Title:   m.TitleString(),
				Focused: m.Y&0x1 != 0,
				Pinned:  m.Y&0x2 != 0,
				Frozen:  m.Y&0x4 != 0,
			})
			got++
			if got >= expected {
				start += got
				break
			}
		}
		if start >= count {
			return rows, nil
		}
	}
	return rows, nil
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
