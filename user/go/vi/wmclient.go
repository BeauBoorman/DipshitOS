package vi

import (
	"sync"
	"sync/atomic"
)

// M56b (issue #1316): the tab-client WM_RPC wire + event dispatch. The frame
// is byte-identical to kernel/src/wnd_core.zig's `WmRpc` (mirrored in
// user/src/lib/ui/abi.zig): 38 bytes, little-endian, fitting the frozen
// 64-byte mailbox slot. A tab client never calls slot 65 (`wmctl`) — that
// seam is WM-only; an app asks the registered WM over the mailbox instead and
// polls its own inbox for the ack.
//
// The wire mirror is the integration drift guard: if it ever drifts from
// wnd_core, the WM's `wnd: mail` serve and the `wmrpc: *-ack` markers stop
// matching and the live gate fails. TestWmRpcWire pins it on the host.

const (
	// WmRpcTitleMax is the frame title width (wnd_core `wm_rpc_title_max`).
	WmRpcTitleMax = 24
	// WmRpcMax is the mailbox slot bound the frame must fit (wnd_core
	// `wm_rpc_max`).
	WmRpcMax = 64
	// WmRpcReplyFlag marks a WM ack frame (wnd_core `wm_rpc_reply_flag`).
	WmRpcReplyFlag uint8 = 0x80
)

// M97g-F2 (#2080): the authenticated WM_RPC exchange between a client and
// the Go seat. The mailbox is any-to-any and carries no sender identity
// (ADR 0007 slots 5/6), so the frame alone can never prove who sent it. The
// seat instead binds each hosted window to a session token only the window's
// kernel-registered owner can obtain:
//
//  1. a request for an UNBOUND window draws a challenge ack — Pad=Challenge
//     with an 8-byte value in the x/y/w/h union;
//  2. the owner proves itself by setting the window's kernel title to the
//     challenge string — slot 61 (sys_win_set_title) refuses non-owners —
//     and resends the request with the challenge echoed in the union;
//  3. the seat reads the title back (wmctl cmd 14), mints the session token,
//     and binds the window to the request's reply_to pid + token — the
//     proof title names that pid too (#3048), so an echo claiming a pid
//     the owner never committed to cannot bind even while the owner's
//     title proof stands mid-handshake;
//  4. every later frame for the window must carry the token in the union,
//     and every ack for a bound window carries Pad=Bound + the token — a
//     forged ack cannot satisfy the client's wait because it cannot quote
//     the token.
//
// The 38-byte wire is unchanged: x/y/w/h are zero in every request kind the
// client sends today, so the auth value rides existing fields.
const (
	// WmRpcPadPlain marks a request with no auth union, or a bare refusal /
	// legacy (Zig-seat) ack.
	WmRpcPadPlain uint8 = 0
	// WmRpcPadChallenge marks a seat challenge ack: the x/y/w/h union holds
	// the bind challenge.
	WmRpcPadChallenge uint8 = 1
	// WmRpcPadBound marks a bound-session frame: the x/y/w/h union holds
	// the window's session token.
	WmRpcPadBound uint8 = 2
)

// WmAuth reads the auth union (challenge echo or session token) out of the
// frame's x/y/w/h fields — the one 8-byte span every request leaves zero.
func WmAuth(m WmRpc) uint64 {
	return uint64(m.X) | uint64(m.Y)<<16 | uint64(m.W)<<32 | uint64(m.H)<<48
}

// SetWmAuth writes the auth union into the frame's x/y/w/h fields.
func SetWmAuth(m *WmRpc, v uint64) {
	m.X = uint16(v)
	m.Y = uint16(v >> 16)
	m.W = uint16(v >> 32)
	m.H = uint16(v >> 48)
}

// WmBindChallengeTitle is the window title a window's owner sets to prove
// ownership for challenge c, committed to the pid the echo will claim as
// reply_to: fixed 24 bytes, inside the kernel's 64-byte title bound and
// the seat's name read-back. The pid is part of the proof (#3048): the
// challenge is disclosed to any requester, so an attacker can echo it —
// but its reply_to binds only if the owner-written title names that same
// pid, and only the owner can write the title.
func WmBindChallengeTitle(c uint64, pid uint8) string {
	const hexd = "0123456789abcdef"
	var b [24]byte
	copy(b[:], "wrpc:")
	for i := 0; i < 16; i++ {
		b[5+i] = hexd[(c>>(60-4*i))&0xf]
	}
	b[21] = ':'
	b[22] = hexd[pid>>4]
	b[23] = hexd[pid&0xf]
	return string(b[:])
}

// The frozen request kinds (wnd_core / abi.zig). Do not renumber.
const (
	WmRpcKindRaise             uint8 = 1
	WmRpcKindConfig            uint8 = 2
	WmRpcKindRegisterAction    uint8 = 3
	WmRpcKindInvokeAction      uint8 = 4
	WmRpcKindAttachTab         uint8 = 5
	WmRpcKindDetachTab         uint8 = 6
	WmRpcKindCycleTab          uint8 = 7
	WmRpcKindDeclareFullscreen uint8 = 8
	// Additive app-side nav kinds (user/src/lib/tabapp.zig): the WM routes
	// WM_RPC by mailbox without interpreting `kind`, so these need no
	// frozen-ABI change.
	WmRpcKindNavDeclare uint8 = 9
	WmRpcKindNavPoll    uint8 = 10
	// Additive client -> seat title update. The request title carries the
	// replacement; the ack keeps the same generic reply shape.
	WmRpcKindSetTitle uint8 = 11
	// M79k (#1720): the notify seam. The request title carries the message
	// text (24 NUL-padded bytes, the whole budget), and the request id is
	// the sender's own tab so the seat can click the toast back to it.
	WmRpcKindNotify uint8 = 12
	// M82b (#1769): key-only settings subscription and publish requests.
	// The seat sends kind 15 asynchronously to matching subscribers.
	WmRpcKindSettingsSubscribe uint8 = 13
	WmRpcKindSettingsPublish   uint8 = 14
	WmRpcKindSettingsChanged   uint8 = 15
	// M125a (#2586): the per-app state protocol. Kind 20 is bidirectional:
	// the seat pushes an asynchronous save notice (reply_to=0) and the app
	// answers with a request; kind 21 is the app's restore request. The
	// 38-byte frame cannot carry a blob, so both kinds rendezvous on the
	// staged share file AppStatePath(id) — the frame is only the handoff
	// signal. See wmstate.go.
	WmRpcKindSaveState    uint8 = 20
	WmRpcKindRestoreState uint8 = 21
)

// WmRpc is the 38-byte app-to-WM mailbox frame. Field order and widths are the
// kernel's: kind@0, id@1, seq@2, reply_to@3, applied@4, pad@5, x@6, y@8,
// w@10, h@12, title[24]@14.
//
// Frozen wire fields:
//   - kind: u8; bit 0x80 marks a reply, and additive kinds do not renumber
//   - id: u8 window id; the low byte only, so WmMailRequest refuses values > 0xff
//   - seq: u8 per-process monotonic request counter; zero is skipped
//   - reply_to: u8 requester pid; the low byte only, so values > 0xff are refused
//   - applied: u8, reply frames only
//   - x, y, w, h: u16 little-endian
//   - title: 24 NUL-padded bytes; set-title requests carry the tab title and
//     nav-poll replies carry their path
//
// The id and reply_to bounds are part of the client contract, not an
// invitation to truncate a wider value silently.
type WmRpc struct {
	Kind    uint8
	ID      uint8
	Seq     uint8
	ReplyTo uint8
	Applied uint8
	Pad     uint8
	X       uint16
	Y       uint16
	W       uint16
	H       uint16
	Title   [WmRpcTitleMax]byte
}

// Encode marshals the frame little-endian into a fresh 38-byte slice. Hand
// encoded (not an unsafe cast) so the byte layout is explicit and does not
// depend on the compiler's struct padding.
func (m WmRpc) Encode() []byte {
	b := make([]byte, 38)
	b[0] = m.Kind
	b[1] = m.ID
	b[2] = m.Seq
	b[3] = m.ReplyTo
	b[4] = m.Applied
	b[5] = m.Pad
	putU16(b[6:], m.X)
	putU16(b[8:], m.Y)
	putU16(b[10:], m.W)
	putU16(b[12:], m.H)
	copy(b[14:38], m.Title[:])
	return b
}

// DecodeWmRpc parses a frame from b, which must be at least 38 bytes.
func DecodeWmRpc(b []byte) (WmRpc, bool) {
	if len(b) < 38 {
		return WmRpc{}, false
	}
	var m WmRpc
	m.Kind = b[0]
	m.ID = b[1]
	m.Seq = b[2]
	m.ReplyTo = b[3]
	m.Applied = b[4]
	m.Pad = b[5]
	m.X = getU16(b[6:])
	m.Y = getU16(b[8:])
	m.W = getU16(b[10:])
	m.H = getU16(b[12:])
	copy(m.Title[:], b[14:38])
	return m, true
}

// SetTitle copies up to WmRpcTitleMax bytes of s into the frame's title,
// leaving the remainder NUL-padded.
func (m *WmRpc) SetTitle(s string) {
	for i := range m.Title {
		m.Title[i] = 0
	}
	n := len(s)
	if n > WmRpcTitleMax {
		n = WmRpcTitleMax
	}
	copy(m.Title[:n], s[:n])
}

// TitleString returns the frame's title with the NUL padding trimmed.
func (m WmRpc) TitleString() string {
	n := 0
	for n < len(m.Title) && m.Title[n] != 0 {
		n++
	}
	return string(m.Title[:n])
}

// wmMailWaitTicks bounds one WM_RPC ack wait. Each miss parks one scheduler
// tick (slot 4 sys_sleep; 1 s on VZ) so a silent seat cannot burn millions
// of yield-spins inside tabapp.Init (#1489). The first probe is immediate —
// a WM that has already replied never sleeps. Expiry is false (honest
// refusal; DeclareFullscreen callers already handle it).
const wmMailWaitTicks = 8

// wmSeq is process-local because the package-level helpers are the client
// surface: there is no Client object to own the counter. Atomic allocation
// keeps two goroutines making requests from receiving the same sequence.
var wmSeq atomic.Uint32

// wmTokens is the session-token table the Go-seat handshake fills, indexed
// directly by window id (u8). A zero entry means "not bound under this
// seat" — tokens are minted nonzero.
var (
	wmTokensMu sync.Mutex
	wmTokens   [256]uint64
)

func wmToken(id uint8) uint64 {
	wmTokensMu.Lock()
	defer wmTokensMu.Unlock()
	return wmTokens[id]
}

func setWmToken(id uint8, token uint64) {
	wmTokensMu.Lock()
	wmTokens[id] = token
	wmTokensMu.Unlock()
}

// resetWmAuth clears the bind state. Tests use it for isolation; a lost
// binding is otherwise re-established by the challenge round.
func resetWmAuth() {
	wmTokensMu.Lock()
	wmTokens = [256]uint64{}
	wmTokensMu.Unlock()
}

// bindSetTitle is the ownership-proof seam: slot 61 (sys_win_set_title) is
// owner-restricted, so only the kernel-registered owner can make a window's
// title read as the challenge string. The raw gateway is -ENOSYS off-guest,
// so host tests stub this var.
var bindSetTitle = WinSetTitle

// A blocking WM_RPC request can receive another request's ack or a
// settings-change frame while it waits. Preserve both for the rightful
// consumer; the shared mailbox remains safe when an app has concurrent RPC
// callers and an appkit loop polling asynchronous settings.
var (
	wmInboxMu      sync.Mutex
	pendingWmInbox [MailboxMaxMessages]WmRpc
	pendingWmCount int
	// wmRecvBuf is package-level on purpose: the kernel writes through a
	// uintptr, and a stack-allocated recv buffer can move if the goroutine
	// stack grows mid-svc — the stale uintptr then lands the frame on the
	// dead stack copy and the decode reads zeros. A global address is
	// stable; wmInboxMu already serializes every recv.
	wmRecvBuf [WmRpcMax]byte
)

func enqueueWmMessage(m WmRpc) {
	wmInboxMu.Lock()
	defer wmInboxMu.Unlock()
	if m.Kind == WmRpcKindSettingsChanged {
		for i := 0; i < pendingWmCount; i++ {
			old := pendingWmInbox[i]
			if old.Kind == m.Kind && old.ID == m.ID && old.TitleString() == m.TitleString() {
				pendingWmInbox[i] = m
				return
			}
		}
	}
	if pendingWmCount == len(pendingWmInbox) {
		copy(pendingWmInbox[:], pendingWmInbox[1:])
		pendingWmCount--
	}
	pendingWmInbox[pendingWmCount] = m
	pendingWmCount++
}

func takePendingWmMessage(matches func(WmRpc) bool) (WmRpc, bool) {
	wmInboxMu.Lock()
	defer wmInboxMu.Unlock()
	for i := 0; i < pendingWmCount; i++ {
		m := pendingWmInbox[i]
		if !matches(m) {
			continue
		}
		copy(pendingWmInbox[i:], pendingWmInbox[i+1:pendingWmCount])
		pendingWmCount--
		pendingWmInbox[pendingWmCount] = WmRpc{}
		return m, true
	}
	return WmRpc{}, false
}

func receiveWmMessage() (WmRpc, bool) {
	wmInboxMu.Lock()
	n, r := IpcRecv(wmRecvBuf[:])
	wmInboxMu.Unlock()
	if r < 0 || n < 38 {
		return WmRpc{}, false
	}
	return DecodeWmRpc(wmRecvBuf[:n])
}

func nextWmSeq() uint8 {
	for {
		seq := wmSeq.Add(1)
		if seq&0xff != 0 {
			return uint8(seq)
		}
	}
}

func fitsWire8(v uint32) bool {
	return v <= 0xff
}

// waitWmRpcAck polls the caller's inbox for the request's ack. A silent
// mailbox parks between probes and returns (_, false) when the tick budget
// runs out; it never yield-spins. Replies with another sequence or requester
// are foreign and are queued for their own consumer; a reply that matches
// seq+reply_to but fails accept is consumed and dropped — under the Go seat
// that is what a forged ack looks like, and it must neither satisfy the wait
// nor linger for a later caller.
func waitWmRpcAck(seq, replyTo uint8, accept func(WmRpc) bool) (WmRpc, bool) {
	matches := func(m WmRpc) bool {
		return m.Kind&WmRpcReplyFlag != 0 && m.Seq == seq && m.ReplyTo == replyTo
	}
	for tick := uint64(0); tick < wmMailWaitTicks; tick++ {
		for {
			m, ok := takePendingWmMessage(matches)
			if !ok {
				break
			}
			if accept(m) {
				return m, true
			}
		}
		if m, ok := receiveWmMessage(); ok {
			if matches(m) {
				if accept(m) {
					return m, true
				}
				continue
			}
			enqueueWmMessage(m)
		}
		if tick+1 >= wmMailWaitTicks {
			return WmRpc{}, false
		}
		_ = svc1(SlotSleep, 1)
	}
	return WmRpc{}, false
}

// wmBindMaxRounds bounds the challenge-handshake retries: one fresh
// challenge arrives per refused echo, and a forged challenge only costs a
// round-trip.
const wmBindMaxRounds = 3

// wmSendRetries bounds the full-mailbox resend: the seat's ring is 8 deep
// and drains once per composite pass, so a frame that hits ENOSPC under a
// burst fits one tick later (#2260 — a one-shot send turned a momentarily
// full seat mailbox into an instant `refused` while the request was
// otherwise servable).
const wmSendRetries = 4

// wmSend posts one request frame to the seat, retrying only the transient
// ENOSPC (ring full) for a few scheduler ticks. Every other error —
// EINVAL for a dead seat, EFAULT — fails at once.
func wmSend(target uint32, b []byte) int64 {
	for i := 0; i < wmSendRetries; i++ {
		if r := IpcSend(target, b); r != -ErrENOSPC {
			return r
		}
		_ = svc1(SlotSleep, 1)
	}
	return IpcSend(target, b)
}

// wmRequest sends one WM_RPC request to the resolved seat and returns its
// genuine ack (or ok=false on refusal/timeout/no seat). The Zig seats keep
// the bare legacy exchange; the Go seat adds the ownership handshake: an
// unbound window's first request draws a challenge, the caller proves
// ownership by setting the window's kernel title to the challenge string,
// the echo completes the bind, and every later request rides the session
// token in the x/y/w/h union.
func wmRequest(kind uint8, id uint32, x, y, w, h uint16, title, selfName string) (WmRpc, bool) {
	if !fitsWire8(id) {
		return WmRpc{}, false
	}
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 || !fitsWire8(peers.Self) {
		return WmRpc{}, false
	}
	if !peers.Go {
		// Legacy seat: the single bare exchange, exactly as before the bind
		// protocol. The Zig seats never emit an auth Pad, and x/y/w/h are
		// real geometry on their wire.
		req := WmRpc{Kind: kind, ID: uint8(id), Seq: nextWmSeq(), ReplyTo: uint8(peers.Self), X: x, Y: y, W: w, H: h}
		req.SetTitle(title)
		if IpcSend(peers.WM, req.Encode()) < 0 {
			return WmRpc{}, false
		}
		return waitWmRpcAck(req.Seq, req.ReplyTo, func(WmRpc) bool { return true })
	}
	// #2157: under the Go seat the frame's only x/y/w/h fields ARE the auth
	// union — a bound request carries the session token and an unbound one
	// draws a challenge whose echo overwrites them, so nonzero geometry can
	// never reach the wire. Refuse honestly rather than land the request
	// with its geometry silently zeroed; carrying both needs a wire
	// (ABI) decision the client cannot make alone.
	if x != 0 || y != 0 || w != 0 || h != 0 {
		return WmRpc{}, false
	}
	return wmRequestGo(kind, uint8(id), title, peers)
}

// wmRequestGo is the authenticated exchange with the Go seat. A bound
// request carries the session token; an unbound one walks the ownership
// challenge first. The Go seat never sends a plain (Pad=0) ack, so anything
// in that shape matching seq+reply_to is a forgery and is dropped inside
// waitWmRpcAck rather than satisfying it.
func wmRequestGo(kind uint8, id uint8, title string, peers WmSeat) (WmRpc, bool) {
	var tb [WmRpcTitleMax]byte
	copy(tb[:], title)
	return wmRequestGoTitle(kind, id, tb, title, peers)
}

// wmRequestGoTitle is the raw-title form of wmRequestGo for kinds whose
// payload is binary (kind 17 gpu3d, kind 18 surface handoff): title is the
// verbatim frame field, restoreTitle is the window's intended kernel title
// the challenge tail puts back after the bind proof.
func wmRequestGoTitle(kind uint8, id uint8, title [WmRpcTitleMax]byte, restoreTitle string, peers WmSeat) (WmRpc, bool) {
	for round := 0; round < wmBindMaxRounds; round++ {
		token := wmToken(id)
		req := WmRpc{Kind: kind, ID: id, Seq: nextWmSeq(), ReplyTo: uint8(peers.Self), Title: title}
		// The accept predicate is strict per send shape: a bound request
		// accepts an ack quoting the same token, an unbound request
		// accepts only a challenge — a plain ack is the forgery shape, and
		// a Bound ack for a request that carried no credentials could only
		// install an attacker-chosen token. A bound request ALSO accepts
		// a re-challenge: that is how the seat answers a token it no
		// longer holds (a reused window's binding died with the old
		// window), and the challenge tail below re-proves and rebinds in
		// the SAME round, exactly as wqPage does.
		var accept func(WmRpc) bool
		if token != 0 {
			req.Pad = WmRpcPadBound
			SetWmAuth(&req, token)
			accept = func(m WmRpc) bool {
				return m.Pad == WmRpcPadChallenge ||
					(m.Pad == WmRpcPadBound && WmAuth(m) == token)
			}
		} else {
			accept = func(m WmRpc) bool { return m.Pad == WmRpcPadChallenge }
		}
		if wmSend(peers.WM, req.Encode()) < 0 {
			return WmRpc{}, false
		}
		rep, ok := waitWmRpcAck(req.Seq, req.ReplyTo, accept)
		if !ok {
			if token != 0 {
				// The seat lost the binding (it restarted and forgot the
				// token): drop the stale entry and rebind next round.
				setWmToken(id, 0)
				continue
			}
			return WmRpc{}, false
		}
		if rep.Pad == WmRpcPadBound {
			return rep, true // bound-window answer
		}
		// Challenge: prove ownership through the window title, then resend
		// the request with the challenge echoed as the auth union.
		challenge := WmAuth(rep)
		if challenge == 0 || bindSetTitle(int(id), WmBindChallengeTitle(challenge, req.ReplyTo)) != 0 {
			return WmRpc{}, false
		}
		req.Seq = nextWmSeq()
		req.Pad = WmRpcPadBound
		SetWmAuth(&req, challenge)
		if wmSend(peers.WM, req.Encode()) < 0 {
			return WmRpc{}, false
		}
		rep, ok = waitWmRpcAck(req.Seq, req.ReplyTo,
			func(m WmRpc) bool { return m.Pad != WmRpcPadPlain })
		if !ok || rep.Pad != WmRpcPadBound {
			continue // silent or re-challenged: another round
		}
		newToken := WmAuth(rep)
		if newToken == 0 {
			return WmRpc{}, false
		}
		setWmToken(id, newToken)
		// The challenge string is the window's kernel title right now;
		// restore the title the request meant it to wear.
		_ = bindSetTitle(int(id), restoreTitle)
		return rep, true
	}
	return WmRpc{}, false
}

// WmMailRequest sends one WM_RPC request to the registered WM and polls the
// CALLER's own inbox for the matching ack. It returns whether the WM applied
// it. A missing WM seat, an id or requester pid that does not fit the frozen
// 8-bit wire fields, nonzero geometry under the Go seat (the auth union owns
// the wire's only x/y/w/h fields — #2157), or a bounded-poll timeout returns
// false (honest — the caller then falls back to the frozen syscall); recv
// reads the caller's own ring, while the seat uses reply_to to route the ack.
func WmMailRequest(kind uint8, id uint32, x, y, w, h uint16, title, selfName string) bool {
	rep, ok := wmRequest(kind, id, x, y, w, h, title, selfName)
	return ok && rep.Applied != 0
}

// DeclareFullscreen asks the WM to make this tab full-viewport eligible (kind
// 8). TABWM accepts; WND.BIN and the shim refuse and the app keeps its legacy
// size — the zero-regression path.
func DeclareFullscreen(winID uint32, title, selfName string) bool {
	return WmMailRequest(WmRpcKindDeclareFullscreen, winID, 0, 0, 0, 0, title, selfName)
}

// DeclareNav tells the WM this tab navigated to path (kind 9) — the
// browser-history analogue for FILE/EDIT tabs.
func DeclareNav(winID uint32, path, selfName string) bool {
	if path == "" {
		return false
	}
	return WmMailRequest(WmRpcKindNavDeclare, winID, 0, 0, 0, 0, path, selfName)
}

// PollNav asks the WM for a back/forward target the user picked on the rail
// (kind 10), returning the path when one is queued. Best-effort: a missing WM
// seat or no pending target returns ("", false).
func PollNav(winID uint32, selfName string) (string, bool) {
	rep, ok := wmRequest(WmRpcKindNavPoll, winID, 0, 0, 0, 0, "", selfName)
	if !ok || rep.Applied == 0 {
		return "", false
	}
	return rep.TitleString(), true
}

// SetTabTitle asks the seat to replace the title on winID (kind 11). An empty
// title is refused before the mailbox: every open tab should remain named.
func SetTabTitle(winID uint32, title, selfName string) bool {
	if title == "" {
		return false
	}
	return WmMailRequest(WmRpcKindSetTitle, winID, 0, 0, 0, 0, title, selfName)
}

// Notify tells the seat to show a toast for winID (kind 12). The whole
// message budget is the frame's 24-byte title, so text is a short human
// string ("copied notes.txt"), not a path or a payload -- the same bound
// SetTabTitle and DeclareNav already live inside. Best-effort: a missing
// seat, an id that does not fit the 8-bit wire, or a refused/timeout ack
// returns false, and the caller should say so rather than assume the user
// was told.
func Notify(winID uint32, text, selfName string) bool {
	if text == "" {
		return false
	}
	return WmMailRequest(WmRpcKindNotify, winID, 0, 0, 0, 0, text, selfName)
}

// SubscribeSetting asks the seat to send kind-15 notices when key changes.
// Keys longer than the frame title are refused rather than subscribed under a
// truncated name.
func SubscribeSetting(winID uint32, key, selfName string) bool {
	if key == "" || len(key) > WmRpcTitleMax {
		return false
	}
	return WmMailRequest(WmRpcKindSettingsSubscribe, winID, 0, 0, 0, 0, key, selfName)
}

// PublishSettingChange tells the seat a persisted key changed. The seat
// validates the key against SETTINGS.TXT, then fans out kind-15 notices.
func PublishSettingChange(winID uint32, key, selfName string) bool {
	if key == "" || len(key) > WmRpcTitleMax {
		return false
	}
	return WmMailRequest(WmRpcKindSettingsPublish, winID, 0, 0, 0, 0, key, selfName)
}

// PollSettingChanged returns the next asynchronous key notice for winID.
// It never waits; ordinary appkit polling remains paced by the event loop.
// A bound window accepts only notices carrying its session token — a forged
// kind-15 frame cannot quote it. Unbound windows keep the legacy match so
// the Zig seats still deliver.
func PollSettingChanged(winID uint32) (string, bool) {
	if !fitsWire8(winID) {
		return "", false
	}
	matches := func(m WmRpc) bool {
		if m.Kind != WmRpcKindSettingsChanged || m.ReplyTo != 0 ||
			m.ID != uint8(winID) || m.TitleString() == "" {
			return false
		}
		if tok := wmToken(uint8(winID)); tok != 0 {
			return m.Pad == WmRpcPadBound && WmAuth(m) == tok
		}
		return true
	}
	if m, ok := takePendingWmMessage(matches); ok {
		return m.TitleString(), true
	}
	for i := 0; i < MailboxMaxMessages; i++ {
		m, ok := receiveWmMessage()
		if !ok {
			return "", false
		}
		if matches(m) {
			return m.TitleString(), true
		}
		enqueueWmMessage(m)
	}
	return "", false
}

func resetSettingChangeQueue() {
	wmInboxMu.Lock()
	pendingWmInbox = [MailboxMaxMessages]WmRpc{}
	pendingWmCount = 0
	wmInboxMu.Unlock()
}

// WmAction is what a tab client's event dispatch decided to do.
type WmAction int

const (
	// WmActionNone: not a WM-lifecycle event (mouse/key/timer...).
	WmActionNone WmAction = iota
	// WmActionResized: the WM resized the canvas; relayout at (W, H).
	WmActionResized
	// WmActionClosed: the window closed; clean up and exit.
	WmActionClosed
)

// TabClient is the state the dispatch loop tracks: the window id and the
// CURRENT canvas size, which follows every WIN_RESIZE (the WM's SET_WINDOW
// seam). Apps lay out against these, never against compile-time constants,
// once tab-aware.
type TabClient struct {
	Win     uint32
	W       uint32
	H       uint32
	Focused bool
}

// NewTabClient returns a client for winID with the given initial canvas size.
func NewTabClient(winID, w, h uint32) *TabClient {
	return &TabClient{Win: winID, W: w, H: h}
}

// Dispatch classifies one WM-lifecycle event and tracks the canvas.
// WIN_RESIZE updates the tracked size and returns WmActionResized; WIN_CLOSE
// returns WmActionClosed; WIN_FOCUS/WIN_BLUR update the focus flag. Everything
// else is WmActionNone and stays the app's own business.
func (t *TabClient) Dispatch(ev Event) WmAction {
	switch ev.Kind {
	case EvWinClose:
		return WmActionClosed
	case EvWinResize:
		t.W = ev.Arg0
		t.H = ev.Arg1
		return WmActionResized
	case EvWinFocus:
		t.Focused = true
	case EvWinBlur:
		t.Focused = false
	}
	return WmActionNone
}
