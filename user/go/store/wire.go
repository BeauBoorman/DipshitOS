package main

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"

	"virelai/shlib"
	"virelai/sshlib"
	"virelai/vi"
)

// Minimal FLINT-SYNC/1 client — hello + auth + list — ported from
// user/go/flint/remote.go (M101a, the wire oracle is the Zig client in
// drawmeanelephant/flint-client). STORE speaks just enough wire to
// enumerate the remote for `store ls`; clone/pull/verify stay with
// FLINT.ELF so the keyring + signature gate has exactly one writer.
// Keeping the client this small is what lets `store ls` run under a
// shell at all: STORE->GOSH->FLINT was four Go runtimes and blew the
// kernel's 13-user-slot task pool (observed `newosproc: sys_thread
// create failed` in go-flint run 15).

const (
	protoVersion     = "FLINT-SYNC/1"
	authDomain       = "FLINT-SYNC-AUTH/1\x00"
	maxWireLineBytes = 4 * 1024 * 1024
	// helloDrainNs bounds the extra-response drain after `hello` — a
	// retransmitted guest segment reaches flintd a second time and a
	// re-processed hello regenerates the session nonce, so only the last
	// hello response is answerable.
	helloDrainNs = 500_000_000

	// secretRemoteKey names the app-bound secret holding the shared
	// flintd --auth-key secret (64 lowercase hex). STORE.ELF needs its own
	// binding row — the slot-70 lane scopes secrets per app.
	secretRemoteKey = "flint-remote"
)

// wireConn is the byte-stream transport seam; *vi.Conn satisfies it and
// tests substitute a scripted fake.
type wireConn interface {
	Send(p []byte) (int, error)
	Recv(p []byte) (int, error)
	Close() error
}

// storeDialNs bounds the outbound handshake: the kernel default is 30 s
// and every stage after it (hello/auth/list) has its own 30 s recv
// budget — under a dead remote those sum past a gate run's script window
// before a `||` retry can fire. 8 s leaves two attempts + stages inside
// the budget while staying far above a healthy handshake.
var remoteDialFn = func(remote string) (wireConn, error) {
	host, port, err := parseRemoteURL(remote)
	if err != nil {
		return nil, err
	}
	return vi.DialTimeout(host, port, 8_000_000_000)
}

var storeGetFn = shlib.StoreGet

// parseRemoteURL splits `tcp://<host>:<port>` or a bare `<host>:<port>`.
func parseRemoteURL(remote string) (string, uint16, error) {
	rest := strings.TrimPrefix(remote, "tcp://")
	if rest == "" || rest == remote && strings.Contains(remote, "://") {
		return "", 0, refuse("remote_malformed", "")
	}
	host, portStr, ok := strings.Cut(rest, ":")
	if !ok || host == "" || portStr == "" || strings.Contains(host, "/") {
		return "", 0, refuse("remote_malformed", "")
	}
	port64, err := strconv.ParseUint(portStr, 10, 16)
	if err != nil || port64 == 0 {
		return "", 0, refuse("remote_malformed", "")
	}
	return host, uint16(port64), nil
}

// normalizeRemote canonicalizes a remote argument to `tcp://<host>:<port>`.
func normalizeRemote(arg string) (string, error) {
	u := arg
	if !strings.HasPrefix(u, "tcp://") {
		u = "tcp://" + u
	}
	if _, _, err := parseRemoteURL(u); err != nil {
		return "", err
	}
	return u, nil
}

func q(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func isLowerHexN(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// loadRemoteKey reads the optional `flint-remote` shared secret from the
// slot-70 lane, bound to STORE.ELF. Absent means "no auth configured":
// the client proceeds and refuses only if the daemon challenges. The raw
// buffer is wiped before returning.
func loadRemoteKey() (*[32]byte, error) {
	var raw [vi.SecretValMax]byte
	defer sshlib.Wipe(raw[:])
	n := storeGetFn(secretRemoteKey, raw[:])
	if n < 0 {
		return nil, nil
	}
	if n != 64 {
		return nil, refuse("secret_malformed", "")
	}
	var key [32]byte
	for i := 0; i < 32; i++ {
		hi, ok1 := lowerNibble(raw[2*i])
		lo, ok2 := lowerNibble(raw[2*i+1])
		if !ok1 || !ok2 {
			return nil, refuse("secret_malformed", "")
		}
		key[i] = (hi << 4) | lo
	}
	return &key, nil
}

func lowerNibble(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	default:
		return 0, false
	}
}

// computeAuthHMAC answers the flintd challenge:
// hex(HMAC-SHA256(key, "FLINT-SYNC-AUTH/1\x00" || nonce[16])).
func computeAuthHMAC(key *[32]byte, nonceHex string) (string, error) {
	if !isLowerHexN(nonceHex, 32) {
		return "", refuse("auth_failed", "")
	}
	var nonce [16]byte
	for i := 0; i < 16; i++ {
		hi, _ := lowerNibble(nonceHex[2*i])
		lo, _ := lowerNibble(nonceHex[2*i+1])
		nonce[i] = (hi << 4) | lo
	}
	defer sshlib.Wipe(nonce[:])
	msg := make([]byte, 0, len(authDomain)+16)
	msg = append(msg, authDomain...)
	msg = append(msg, nonce[:]...)
	mac := shlib.HMACSHA256(key[:], msg)
	defer sshlib.Wipe(mac[:])
	return sshlib.EncodeHex(mac[:]), nil
}

// syncClient speaks FLINT-SYNC/1 over one ordered byte stream: one
// request in flight per connection, `seq` correlates each response, and
// rx buffers bytes past the last consumed line — the runner's TCP relay
// re-delivers retransmitted segments to flintd without dedup, so extra
// responses must not shift the pairing.
type syncClient struct {
	conn wireConn
	seq  uint64
	rx   []byte
}

func (c *syncClient) close() { _ = c.conn.Close() }

func (c *syncClient) nextSeq() uint64 {
	c.seq++
	return c.seq
}

func (c *syncClient) nextLine() ([]byte, error) {
	var buf [vi.TCPPayloadMax]byte
	for {
		if i := bytes.IndexByte(c.rx, '\n'); i >= 0 {
			line := append([]byte(nil), c.rx[:i]...)
			c.rx = c.rx[i+1:]
			if len(line) == 0 {
				return nil, refuse("change_malformed", "")
			}
			if line[len(line)-1] == '\r' {
				line = line[:len(line)-1]
			}
			return line, nil
		}
		if len(c.rx) >= maxWireLineBytes {
			return nil, refuse("change_too_large", "")
		}
		n, err := c.conn.Recv(buf[:])
		if err != nil {
			return nil, err
		}
		c.rx = append(c.rx, buf[:n]...)
	}
}

// nextResponse reads lines until one carries seq — the pairing
// correlator. Smaller seqs are stale relay duplicates; a larger one
// violates the 1:1 contract.
func (c *syncClient) nextResponse(seq uint64) (map[string]json.RawMessage, error) {
	for {
		line, err := c.nextLine()
		if err != nil {
			return nil, err
		}
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(line, &obj); err != nil || obj == nil {
			return nil, refuse("change_malformed", "")
		}
		rseq, ok := jsonFieldUint(obj, "seq")
		if !ok {
			return nil, refuse("change_malformed", "")
		}
		if rseq < seq {
			continue
		}
		if rseq > seq {
			return nil, refuse("change_malformed", "")
		}
		return obj, nil
	}
}

func (c *syncClient) send(req []byte) (map[string]json.RawMessage, error) {
	line := req
	if len(line) == 0 || line[len(line)-1] != '\n' {
		line = append(line, '\n')
	}
	seq := c.seq
	if _, err := c.conn.Send(line); err != nil {
		return nil, err
	}
	return c.nextResponse(seq)
}

// drainSameSeq consumes further responses still queued for the last
// request within a short grace window and returns the last one — see
// remote.go: after `hello`, a re-processed request regenerates the nonce
// and only the latest challenge is answerable.
func (c *syncClient) drainSameSeq(obj map[string]json.RawMessage) map[string]json.RawMessage {
	type deadliner interface{ SetRecvDeadline(int64) }
	d, ok := c.conn.(deadliner)
	if !ok {
		return obj
	}
	d.SetRecvDeadline(helloDrainNs)
	defer d.SetRecvDeadline(0)
	for {
		extra, err := c.nextResponse(c.seq)
		if err != nil {
			return obj
		}
		obj = extra
	}
}

func jsonFieldStr(obj map[string]json.RawMessage, name string) (string, bool) {
	raw, ok := obj[name]
	if !ok {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", false
	}
	return s, true
}

func jsonFieldBool(obj map[string]json.RawMessage, name string) (bool, bool) {
	raw, ok := obj[name]
	if !ok {
		return false, false
	}
	var b bool
	if err := json.Unmarshal(raw, &b); err != nil {
		return false, false
	}
	return b, true
}

func jsonFieldUint(obj map[string]json.RawMessage, name string) (uint64, bool) {
	raw, ok := obj[name]
	if !ok {
		return 0, false
	}
	var u uint64
	if err := json.Unmarshal(raw, &u); err != nil {
		return 0, false
	}
	return u, true
}

func refuseName(obj map[string]json.RawMessage) string {
	if name, ok := jsonFieldStr(obj, "refuse"); ok && name != "" {
		return name
	}
	return "wire_error"
}

// checkOK validates the seq correlator and ok flag; a refusal becomes a
// RefuseError carrying the wire name verbatim.
func (c *syncClient) checkOK(obj map[string]json.RawMessage, seq uint64) (map[string]json.RawMessage, error) {
	gotSeq, ok := jsonFieldUint(obj, "seq")
	if !ok || gotSeq != seq {
		return nil, refuse("change_malformed", "")
	}
	isOK, ok := jsonFieldBool(obj, "ok")
	if !ok {
		return nil, refuse("change_malformed", "")
	}
	if !isOK {
		return nil, refuse(refuseName(obj), "")
	}
	return obj, nil
}

// handshake runs hello + the optional HMAC auth round, mirroring
// remote.go's SyncClient.handshake.
func (c *syncClient) handshake(key *[32]byte) error {
	seq := c.nextSeq()
	obj, err := c.send([]byte(`{"op":"hello","seq":` + vi.Itoa64(int64(seq)) + `,"proto":` + q(protoVersion) + `}`))
	if err != nil {
		return err
	}
	obj = c.drainSameSeq(obj)
	isOK, ok := jsonFieldBool(obj, "ok")
	if !ok {
		return refuse("change_malformed", "")
	}
	if !isOK {
		name := refuseName(obj)
		if name == "auth_required" {
			nonce, nok := jsonFieldStr(obj, "nonce")
			if !nok || !isLowerHexN(nonce, 32) {
				nonce, nok = jsonFieldStr(obj, "detail")
			}
			if nok && isLowerHexN(nonce, 32) && key != nil {
				if err := c.sendAuth(key, nonce); err != nil {
					return err
				}
				seq2 := c.nextSeq()
				obj2, err := c.send([]byte(`{"op":"hello","seq":` + vi.Itoa64(int64(seq2)) + `,"proto":` + q(protoVersion) + `}`))
				if err != nil {
					return err
				}
				if _, err := c.checkOK(obj2, seq2); err != nil {
					return err
				}
				proto, _ := jsonFieldStr(obj2, "proto")
				if proto != protoVersion {
					return refuse("proto_version", "")
				}
				return nil
			}
		}
		return refuse(name, "")
	}
	if _, err := c.checkOK(obj, seq); err != nil {
		return err
	}
	proto, _ := jsonFieldStr(obj, "proto")
	if proto != protoVersion {
		return refuse("proto_version", "")
	}
	if nonce, nok := jsonFieldStr(obj, "nonce"); nok && nonce != "" {
		if key == nil {
			return refuse("auth_required", "")
		}
		if err := c.sendAuth(key, nonce); err != nil {
			return err
		}
	}
	return nil
}

// sendAuth emits the `auth` request answering the daemon's nonce.
func (c *syncClient) sendAuth(key *[32]byte, nonce string) error {
	hmacHex, err := computeAuthHMAC(key, nonce)
	if err != nil {
		return err
	}
	seq := c.nextSeq()
	obj, err := c.send([]byte(`{"op":"auth","seq":` + vi.Itoa64(int64(seq)) +
		`,"nonce":` + q(nonce) + `,"hmac":` + q(hmacHex) + `}`))
	if err != nil {
		return err
	}
	_, err = c.checkOK(obj, seq)
	return err
}

// list returns the remote's stream records (`list` op).
func (c *syncClient) list() ([]Stream, error) {
	seq := c.nextSeq()
	obj, err := c.send([]byte(`{"op":"list","seq":` + vi.Itoa64(int64(seq)) + `}`))
	if err != nil {
		return nil, err
	}
	if _, err := c.checkOK(obj, seq); err != nil {
		return nil, err
	}
	raw, ok := obj["streams"]
	if !ok {
		return nil, refuse("change_malformed", "")
	}
	var streams []Stream
	if err := json.Unmarshal(raw, &streams); err != nil {
		return nil, refuse("change_malformed", "")
	}
	return streams, nil
}

// remoteStreams connects to remote, handshakes, and returns the remote's
// stream list sorted by name — the `store ls` enumeration step. `list`
// is intentionally the only op used: the records carry each stream's
// head id, which is all `ls` needs to decide whether the local replica
// is current — `read` is NOT used because a single Change line plus its
// envelope exceeds the ~1460-byte guest fill boundary the relay can
// carry (see the spec header: the kernel ACKs app-delivered bytes only,
// a partial-segment tail is dropped, and the ACK-gated pump deadlocks).
func remoteStreams(remote string) ([]Stream, error) {
	key, err := loadRemoteKey()
	if err != nil {
		return nil, err
	}
	if key != nil {
		defer sshlib.Wipe(key[:])
	}
	consoleFn("store: wire key ok")
	conn, err := remoteDialFn(remote)
	if err != nil {
		return nil, err
	}
	consoleFn("store: wire dial ok")
	// Bound the whole session, not each Recv: hello+auth+list each carry
	// a 30 s default budget and a wedged remote makes them expire
	// serially — past a gate run's window, with no output to show for it.
	// 20 s covers a healthy session many times over. SetRecvDeadline
	// takes a RELATIVE budget (it adds Nanos() itself — vi/conn.go), so
	// passing an absolute timestamp would bound the session at
	// uptime + 20 s.
	if d, ok := conn.(interface{ SetRecvDeadline(int64) }); ok {
		d.SetRecvDeadline(20_000_000_000)
	}
	client := &syncClient{conn: conn}
	defer client.close()
	if err := client.handshake(key); err != nil {
		return nil, err
	}
	consoleFn("store: wire auth ok")
	streams, err := client.list()
	if err == nil {
		consoleFn("store: wire list ok")
	}
	if err != nil {
		return nil, err
	}
	for i := 0; i < len(streams); i++ {
		for j := i + 1; j < len(streams); j++ {
			if streams[j].Name < streams[i].Name {
				streams[i], streams[j] = streams[j], streams[i]
			}
		}
	}
	return streams, nil
}
