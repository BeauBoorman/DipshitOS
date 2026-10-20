package main

// state.go — M147b (issue #2802): GOIRC's session-state blob, the per-app
// envelope the seat carries through the M125a protocol
// (vi.EncodeAppState, AppStateMax = 64 KiB). The card's fields are the
// server (host/port/TLS), the buffer list + per-buffer scroll position,
// the focused buffer, the live nick, and the plaintext-consent answer —
// a restored tab re-asks nothing the user already answered.
//
// v1 layout (all integers little-endian, term/state.go's convention):
//
//	u8  format (=1)      the app's own staleness tag — the seat stores
//	u8  flags            and returns StateVersion verbatim, so the blob
//	     bit0: tls          also tags itself
//	     bit1: consent
//	u16 hostLen | host
//	u16 port
//	u16 nickLen | nick
//	u16 focusLen| focus     "" = the server buffer
//	u16 nChans  | nChans x
//	     { u16 nameLen | name | u32 scrollUp }
//
// Every bound is hard and every declared length is checked: a stale,
// short, over-declared or trailing-garbage blob is refused WHOLE — the
// marker is `goirc: state refused`, never a half-applied session.

const (
	ircStateVersion uint8 = 1

	stateHostMax  = 255
	stateNickMax  = 64
	stateChanMax  = 64 // per-name bytes
	stateChansMax = 64 // buffer count bound
)

func appendU16(b []byte, v uint16) []byte {
	return append(b, byte(v), byte(v>>8))
}

func appendU32(b []byte, v uint32) []byte {
	return append(b, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

// stateChan is one buffer's persisted half.
type stateChan struct {
	name   string
	scroll uint32
}

// ircState is the session-state half of the app: the decoded restore
// fields plus the encode hook that reads the live uiApp.
type ircState struct {
	restored bool
	host     string
	port     uint16
	tls      bool
	consent  bool
	nick     string
	focus    string
	chans    []stateChan
}

// encode serializes the live session — Config.SaveState's body.
func (s *ircState) encode(u *uiApp) []byte {
	host := u.cfg.Host
	if len(host) > stateHostMax {
		host = host[:stateHostMax]
	}
	nick := u.cfg.Nick
	if u.cli != nil {
		nick = u.cli.Nick()
	}
	if len(nick) > stateNickMax {
		nick = nick[:stateNickMax]
	}
	focus := u.focusedBuf()
	if len(focus) > stateChanMax {
		focus = focus[:stateChanMax]
	}
	var flags byte
	if u.cfg.TLS {
		flags |= 1
	}
	if u.cfg.AllowPlain {
		flags |= 2
	}
	out := make([]byte, 0, 64)
	out = append(out, ircStateVersion, flags)
	out = appendU16(out, uint16(len(host)))
	out = append(out, host...)
	out = appendU16(out, u.cfg.Port)
	out = appendU16(out, uint16(len(nick)))
	out = append(out, nick...)
	out = appendU16(out, uint16(len(focus)))
	out = append(out, focus...)
	// Slot 0 (the server buffer) is not a channel — persist buffers in
	// rail order, its scroll included, so the ring layout round-trips.
	chans := u.bufs
	n := len(chans)
	if n > stateChansMax {
		n = stateChansMax
	}
	out = appendU16(out, uint16(n))
	for i := 0; i < n; i++ {
		sc := u.scroll[chans[i]]
		if sc < 0 {
			sc = 0
		}
		name := chans[i]
		if len(name) > stateChanMax {
			name = name[:stateChanMax]
		}
		out = appendU16(out, uint16(len(name)))
		out = append(out, name...)
		out = appendU32(out, uint32(sc))
	}
	return out
}

// decode is encode's strict inverse — refusal is total (ok=false),
// never partial state. The decoded fields land on s only on success.
func (s *ircState) decode(b []byte) bool {
	var d struct {
		host  string
		port  uint16
		flags byte
		nick  string
		focus string
		chans []stateChan
	}
	if len(b) < 12 || b[0] != ircStateVersion {
		return false
	}
	d.flags = b[1]
	off := 2
	u16 := func() (int, bool) {
		if len(b)-off < 2 {
			return 0, false
		}
		v := int(b[off]) | int(b[off+1])<<8
		off += 2
		return v, true
	}
	str := func(max int) (string, bool) {
		n, ok := u16()
		if !ok || n > max || len(b)-off < n {
			return "", false
		}
		v := string(b[off : off+n])
		off += n
		return v, true
	}
	var ok bool
	if d.host, ok = str(stateHostMax); !ok {
		return false
	}
	p, ok := u16()
	if !ok || p == 0 {
		return false
	}
	d.port = uint16(p)
	if d.nick, ok = str(stateNickMax); !ok {
		return false
	}
	if d.focus, ok = str(stateChanMax); !ok {
		return false
	}
	n, ok := u16()
	if !ok || n > stateChansMax {
		return false
	}
	for i := 0; i < n; i++ {
		name, ok := str(stateChanMax)
		if !ok {
			return false
		}
		if len(b)-off < 4 {
			return false
		}
		sc := uint32(b[off]) | uint32(b[off+1])<<8 |
			uint32(b[off+2])<<16 | uint32(b[off+3])<<24
		off += 4
		// A buffer name that is not the server buffer must be a real
		// channel — a forged rail row would smuggle a non-channel into
		// the rejoin set.
		if name != "" && !isChannel(name) {
			return false
		}
		d.chans = append(d.chans, stateChan{name: name, scroll: sc})
	}
	if off != len(b) {
		return false
	}
	if d.focus != "" {
		found := false
		for _, c := range d.chans {
			if c.name == d.focus {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	s.restored = true
	s.host, s.port = d.host, d.port
	s.tls = d.flags&1 != 0
	s.consent = d.flags&2 != 0
	s.nick, s.focus = d.nick, d.focus
	s.chans = d.chans
	return true
}
