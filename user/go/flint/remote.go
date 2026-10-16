// FLINT-SYNC/1 client — M101a (#2313): remote verbs clone/pull/push/ls-remote
// against host flintd (docs/flint-server-spec.md §2) over vi.Dial. Changes
// cross the wire as raw JSONL line bytes and are written into
// streams/<id>.jsonl verbatim, so canonical bytes and signatures survive
// transport untouched. The Zig `flint` client in drawmeanelephant/flint-client
// (src/sync.zig, M106e) is the wire oracle: verb flow, request field order,
// refusal mapping, and output lines mirror it.
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

const (
	protoVersion     = "FLINT-SYNC/1"
	authDomain       = "FLINT-SYNC-AUTH/1\x00"
	defaultReadLimit = 256
	maxBatchChanges  = 256
	// maxBatchBytes caps the escaped change payload one `append` request
	// carries. A request spanning two guest TCP segments can reach flintd
	// with its first segment duplicated — the runner relay re-delivers
	// retransmitted guest segments without dedup (see helloDrainNs) — and
	// flintd then waits on a line that never terminates, so the push hangs
	// (observed as ETIMEDOUT on a ~1.9 KiB two-Change append, M107d).
	// ~1 KiB of escaped payload keeps the whole request inside one
	// ~1460-byte segment; a single Change larger than the cap ships alone.
	maxBatchBytes    = 1024
	maxWireLineBytes = 4 * 1024 * 1024
	maxChangeBytes   = 1024 * 1024
	// helloDrainNs bounds the extra-response drain after `hello`. The guest
	// TCP stack retransmits a segment when the runner relay is slow to ACK,
	// and the relay forwards each copy to flintd without dedup — a second
	// processed hello REGENERATES the session nonce, so only the last hello
	// response is answerable. Trailing copies arrive within the relay round
	// trip; half a second covers them without stalling a clean server.
	helloDrainNs = 500_000_000

	// secretRemoteKey names the app-bound secret holding the shared
	// flintd --auth-key secret (64 lowercase hex chars), read through the
	// same slot-70 lane as the `agent-sign` signing seed. The key never
	// lives under /host: that share is readable by every app and the host.
	secretRemoteKey = "flint-remote"
)

// wireConn is the byte-stream transport seam; *vi.Conn satisfies it and
// tests substitute a scripted or in-process fake.
type wireConn interface {
	Send(p []byte) (int, error)
	Recv(p []byte) (int, error)
	Close() error
}

// remoteDialFn resolves and dials `tcp://<host>:<port>` remotes.
var remoteDialFn = func(remote string) (wireConn, error) {
	host, port, err := parseRemoteURL(remote)
	if err != nil {
		return nil, err
	}
	return vi.Dial(host, port)
}

// parseRemoteURL splits `tcp://<host>:<port>` or a bare `<host>:<port>`
// (the guest CLI's positional remote form) into host and port.
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

// q renders s as a JSON string with Go encoding/json escaping — the same
// escaping rule wire messages and store files share.
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

// RemoteConfig is the plain remote binding written at <root>/REMOTE.json —
// the M106e `{"remote":"tcp://<host>:<port>","stream":"<id>"}` record the
// Zig client writes per-workspace, hoisted to the store root because the
// guest clone registers history, not a workspace.
type RemoteConfig struct {
	Remote string `json:"remote"`
	Stream string `json:"stream"`
}

func remoteConfigPath(root string) string { return root + "/REMOTE.json" }

// loadRemoteConfig reads <root>/REMOTE.json, or nil when absent.
func loadRemoteConfig(fs FS, root string) (*RemoteConfig, error) {
	p := remoteConfigPath(root)
	if !fs.Exists(p) {
		return nil, nil
	}
	b, err := fs.ReadFile(p, MaxFileReadBytes)
	if err != nil {
		return nil, err
	}
	var rc RemoteConfig
	if err := json.Unmarshal(b, &rc); err != nil || rc.Remote == "" {
		return nil, refuse("remote_malformed", "")
	}
	return &rc, nil
}

func writeRemoteConfig(fs FS, root string, rc RemoteConfig) error {
	return WriteJSONSafe(fs, remoteConfigPath(root), rc)
}

// loadRemoteKey reads the optional `flint-remote` shared secret (64
// lowercase hex chars = 32 raw bytes) from the slot-70 secret lane.
// Absent means "no auth configured": the client still proceeds and only
// refuses `auth_required` if the daemon challenges. The raw secret
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

// syncClient speaks FLINT-SYNC/1 over one ordered byte stream: one request
// in flight per connection, `seq` correlates each response. rx buffers the
// bytes past the last consumed line: relay re-delivery makes responses
// arrive in more copies than requests, and the extras must not shift the
// request/response pairing.
type syncClient struct {
	conn       wireConn
	seq        uint64
	rx         []byte
	inListHint bool
}

func (c *syncClient) close() { _ = c.conn.Close() }

func (c *syncClient) nextSeq() uint64 {
	c.seq++
	return c.seq
}

// nextLine reads one '\n'-terminated line, keeping trailing bytes buffered
// for the next call. A line longer than maxWireLineBytes is
// change_too_large; a peer that goes dark fails closed through vi.Conn's
// bounded Recv.
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

// nextResponse reads lines until one carries seq — the pairing correlator.
// Responses with a SMALLER seq are stale: the runner relay re-delivers a
// retransmitted guest segment to flintd, which answers each copy, so a
// previous request's extra answer can sit queued ahead of the real one.
// Discarding by seq keeps the 1:1 pairing exact; a LARGER seq violates it.
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

// send emits one request and reads the response carrying its seq.
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

// drainSameSeq consumes any further responses still queued for the last
// request within a short grace window and returns the last one. After
// `hello` this matters concretely: a re-processed hello regenerates the
// session nonce, so only the latest response's challenge is answerable.
// For idempotent ops it simply leaves the pairing clean for the next
// request. Transports without a deadline knob get no drain (their Recv
// fails fast anyway).
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

// refuseName extracts the wire refusal name (or "wire_error" when the
// server sent no parseable `refuse` field).
func refuseName(obj map[string]json.RawMessage) string {
	if name, ok := jsonFieldStr(obj, "refuse"); ok && name != "" {
		return name
	}
	return "wire_error"
}

// checkOK validates the seq correlator and the ok flag; a refusal becomes
// a RefuseError carrying the wire name verbatim.
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
		name := refuseName(obj)
		if name == "stream_missing" && !c.inListHint {
			detail, _ := jsonFieldStr(obj, "detail")
			return nil, c.refuseStreamMissing(detail)
		}
		return nil, refuse(name, "")
	}
	return obj, nil
}

func jsonFieldUint(obj map[string]json.RawMessage, name string) (uint64, bool) {
	raw, ok := obj[name]
	if !ok {
		return 0, false
	}
	var v uint64
	if err := json.Unmarshal(raw, &v); err != nil {
		return 0, false
	}
	return v, true
}

// refuseStreamMissing re-refuses stream_missing naming the streams the
// remote actually has (the flint-client #36/#37 behavior): a bare refusal
// still tells the user what to clone or pull.
func (c *syncClient) refuseStreamMissing(detail string) error {
	c.inListHint = true
	defer func() { c.inListHint = false }()
	streams, err := c.list()
	if err != nil {
		return refuse("stream_missing", detail)
	}
	var b strings.Builder
	b.WriteString(detail)
	if detail != "" {
		b.WriteByte(' ')
	}
	b.WriteString("(available streams:")
	for _, s := range streams {
		b.WriteByte(' ')
		b.WriteString(s.Name)
	}
	b.WriteByte(')')
	return refuse("stream_missing", b.String())
}

// handshake runs hello + the optional HMAC auth round, mirroring the Zig
// SyncClient.handshake: ok hello carries `proto` (checked against
// FLINT-SYNC/1) and, when the daemon gates the session, a 16-byte hex
// `nonce` the client answers with `auth`.
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

// heads returns the remote's stream-id -> head map (`heads` op).
func (c *syncClient) heads() (map[string]*string, error) {
	seq := c.nextSeq()
	obj, err := c.send([]byte(`{"op":"heads","seq":` + vi.Itoa64(int64(seq)) + `}`))
	if err != nil {
		return nil, err
	}
	if _, err := c.checkOK(obj, seq); err != nil {
		return nil, err
	}
	raw, ok := obj["heads"]
	if !ok {
		return nil, refuse("change_malformed", "")
	}
	var heads map[string]*string
	if err := json.Unmarshal(raw, &heads); err != nil {
		return nil, refuse("change_malformed", "")
	}
	return heads, nil
}

// open resolves a stream id or name to its record (`open` op).
func (c *syncClient) open(stream string) (*Stream, error) {
	seq := c.nextSeq()
	obj, err := c.send([]byte(`{"op":"open","seq":` + vi.Itoa64(int64(seq)) + `,"stream":` + q(stream) + `}`))
	if err != nil {
		return nil, err
	}
	if _, err := c.checkOK(obj, seq); err != nil {
		return nil, err
	}
	raw, ok := obj["record"]
	if !ok {
		return nil, refuse("stream_malformed", "")
	}
	var st Stream
	if err := json.Unmarshal(raw, &st); err != nil || st.ID == "" || st.Name == "" {
		return nil, refuse("stream_malformed", "")
	}
	return &st, nil
}

type readPage struct {
	head    *string
	changes [][]byte // raw JSONL line bytes, no trailing newline
	more    bool
}

// read fetches one page of raw Change lines (`read` op).
func (c *syncClient) read(stream string, after *string, limit int) (*readPage, error) {
	seq := c.nextSeq()
	req := `{"op":"read","seq":` + vi.Itoa64(int64(seq)) + `,"stream":` + q(stream)
	if after != nil {
		req += `,"after":` + q(*after)
	}
	req += `,"limit":` + vi.Itoa64(int64(limit)) + `}`
	obj, err := c.send([]byte(req))
	if err != nil {
		return nil, err
	}
	if _, err := c.checkOK(obj, seq); err != nil {
		return nil, err
	}
	page := &readPage{}
	if raw, ok := obj["head"]; ok {
		var h *string
		if err := json.Unmarshal(raw, &h); err != nil {
			return nil, refuse("change_malformed", "")
		}
		page.head = h
	}
	raw, ok := obj["changes"]
	if !ok {
		return nil, refuse("change_malformed", "")
	}
	var lines []string
	if err := json.Unmarshal(raw, &lines); err != nil {
		return nil, refuse("change_malformed", "")
	}
	page.changes = make([][]byte, 0, len(lines))
	for _, s := range lines {
		page.changes = append(page.changes, []byte(strings.TrimRight(s, "\r\n")))
	}
	if m, ok := jsonFieldBool(obj, "more"); ok {
		page.more = m
	}
	return page, nil
}

// create registers a stream record on the remote (`create` op).
func (c *syncClient) create(rec *Stream) error {
	recJSON, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	seq := c.nextSeq()
	obj, err := c.send([]byte(`{"op":"create","seq":` + vi.Itoa64(int64(seq)) + `,"record":` + string(recJSON) + `}`))
	if err != nil {
		return err
	}
	_, err = c.checkOK(obj, seq)
	return err
}

// append ships raw Change line bytes to the remote (`append` op) and
// returns the server's acknowledged new head.
func (c *syncClient) append(stream string, expectedHead *string, rawLines [][]byte) (string, error) {
	seq := c.nextSeq()
	var b strings.Builder
	b.WriteString(`{"op":"append","seq":` + vi.Itoa64(int64(seq)) + `,"stream":` + q(stream) + `,"expected_head":`)
	if expectedHead != nil {
		b.WriteString(q(*expectedHead))
	} else {
		b.WriteString("null")
	}
	b.WriteString(`,"changes":[`)
	for i, line := range rawLines {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(q(string(bytes.TrimRight(line, "\r\n"))))
	}
	b.WriteString(`]}`)
	obj, err := c.send([]byte(b.String()))
	if err != nil {
		return "", err
	}
	if _, err := c.checkOK(obj, seq); err != nil {
		return "", err
	}
	head, ok := jsonFieldStr(obj, "head")
	if !ok {
		return "", refuse("change_malformed", "")
	}
	return head, nil
}

// fetchAndVerifyStreamChanges pages `read` from `after` to the remote head
// and verifies every returned Change before the caller writes anything:
// parse, stream id, message bound, parent chain from expectedFirstParent,
// the publisher keyring (M101b: key_unknown/key_revoked), and the Ed25519
// signature — integrity must not depend on the transport. The keyring is
// loaded lazily only when new Changes arrived, so an up-to-date pull never
// demands TRUSTED.TXT.
func fetchAndVerifyStreamChanges(client *syncClient, fs FS, root string, st *Stream, after, expectedFirstParent *string) ([][]byte, error) {
	var all [][]byte
	cursor := after
	for {
		page, err := client.read(st.ID, cursor, defaultReadLimit)
		if err != nil {
			return nil, err
		}
		all = append(all, page.changes...)
		if !page.more || len(page.changes) == 0 {
			break
		}
		last, err := ParseChange(page.changes[len(page.changes)-1])
		if err != nil {
			return nil, err
		}
		cursor = &last.ID
	}

	var kr *Keyring
	if len(all) > 0 {
		var err error
		kr, err = LoadKeyring(fs, root)
		if err != nil {
			return nil, err
		}
	}
	prev := expectedFirstParent
	for _, line := range all {
		if len(line)+1 > maxChangeBytes {
			return nil, refuse("change_too_large", "")
		}
		c, err := ParseChange(line)
		if err != nil {
			return nil, err
		}
		if c.Stream != st.ID {
			return nil, refuse("change_malformed", "stream mismatch")
		}
		if err := validateCommitMessage(c.Message); err != nil {
			return nil, err
		}
		if prev != nil {
			if c.Parent == nil || *c.Parent != *prev {
				return nil, refuse("change_malformed", "parent mismatch")
			}
		} else if c.Parent != nil {
			return nil, refuse("change_malformed", "non-null root parent")
		}
		if err := kr.CheckAuthor(c.Author); err != nil {
			return nil, err
		}
		ok, err := VerifyChange(&c)
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, refuse("sig_invalid", "")
		}
		prev = &c.ID
	}
	return all, nil
}

// readStreamRawLines returns the local stream's raw JSONL line bytes.
func readStreamRawLines(fs FS, root, streamID string) ([][]byte, error) {
	p := streamLogPath(root, streamID)
	if !fs.Exists(p) {
		return nil, nil
	}
	b, err := fs.ReadFile(p, MaxFileReadBytes)
	if err != nil {
		return nil, err
	}
	lines, err := ReadJSONLLines(b)
	if err != nil {
		return nil, err
	}
	if len(lines) > MaxChanges {
		return nil, refuse("store_too_large", "changes")
	}
	return lines, nil
}

// resolveRemoteURL picks the remote: --remote flag → <root>/REMOTE.json →
// remote_missing naming where it looked.
func resolveRemoteURL(fs FS, root, remoteFlag string) (string, error) {
	if remoteFlag != "" {
		return normalizeRemote(remoteFlag)
	}
	rc, err := loadRemoteConfig(fs, root)
	if err != nil {
		return "", err
	}
	if rc != nil && rc.Remote != "" {
		return normalizeRemote(rc.Remote)
	}
	return "", refuse("remote_missing", "")
}

// resolveSyncStream picks the local stream for pull/push: --stream flag
// (name or id) → REMOTE.json's bound stream id → stream_missing.
func resolveSyncStream(idx *StoreIndex, rc *RemoteConfig, streamFlag string) (*Stream, error) {
	if streamFlag != "" {
		if st, ok := idx.StreamsByName[streamFlag]; ok {
			return st, nil
		}
		if st, ok := idx.StreamsByID[streamFlag]; ok {
			return st, nil
		}
		return nil, refuse("stream_missing", streamFlag)
	}
	if rc != nil && rc.Stream != "" {
		if st, ok := idx.StreamsByID[rc.Stream]; ok {
			return st, nil
		}
		return nil, refuse("stream_missing", rc.Stream)
	}
	return nil, refuse("stream_missing", "")
}

// dialSync resolves the remote, loads the auth key, dials, and handshakes.
func dialSync(fs FS, root, remoteFlag string) (*syncClient, string, error) {
	remote, err := resolveRemoteURL(fs, root, remoteFlag)
	if err != nil {
		return nil, "", err
	}
	key, err := loadRemoteKey()
	if err != nil {
		return nil, "", err
	}
	if key != nil {
		defer sshlib.Wipe(key[:])
	}
	conn, err := remoteDialFn(remote)
	if err != nil {
		return nil, "", err
	}
	client := &syncClient{conn: conn}
	if err := client.handshake(key); err != nil {
		client.close()
		return nil, "", err
	}
	return client, remote, nil
}

func forkOriginEql(a, b *ForkOrigin) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return a.Stream == b.Stream && a.Change == b.Change
}

// cmdLsRemote implements `flint ls-remote [<remote>]`: handshake, `list`,
// one line per remote stream sorted by name.
func cmdLsRemote(fs FS, root string, args []string) error {
	var remoteFlag string
	positional := 0
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--remote="):
			remoteFlag = a[len("--remote="):]
		case strings.HasPrefix(a, "-"):
			return refuse("usage", "")
		default:
			if positional > 0 || remoteFlag != "" {
				return refuse("usage", "")
			}
			positional++
			remoteFlag = a
		}
	}
	client, _, err := dialSync(fs, root, remoteFlag)
	if err != nil {
		return err
	}
	defer client.close()

	streams, err := client.list()
	if err != nil {
		return err
	}
	sortStreamsByName(streams)
	for _, st := range streams {
		head := "none"
		if st.Head != nil {
			head = *st.Head
		}
		consoleFn("flint: stream " + st.Name + " id=" + st.ID + " head=" + head)
	}
	return nil
}

func sortStreamsByName(streams []Stream) {
	for i := 1; i < len(streams); i++ {
		for j := i; j > 0 && streams[j-1].Name > streams[j].Name; j-- {
			streams[j-1], streams[j] = streams[j], streams[j-1]
		}
	}
}

// cmdVerifyRemote implements `flint verify --remote [--remote=<url>]
// [--stream=<s>]` (M101b): fetch the remote stream's whole Change chain and
// run the same verify-before-materialize gate clone/pull apply — every
// Change's publisher key against TRUSTED.TXT, then its Ed25519 signature —
// printing the per-change `sig: verified` lines `verify` uses. Read-only:
// nothing is written to the store. The stream selector is --stream (name or
// id) or the REMOTE.json binding; the remote is --remote=<url> or the
// binding's remote.
func cmdVerifyRemote(fs FS, root string, args []string) int {
	var remoteFlag, streamFlag string
	for _, a := range args {
		switch {
		case a == "--remote":
		case strings.HasPrefix(a, "--remote="):
			remoteFlag = a[len("--remote="):]
		case strings.HasPrefix(a, "--stream="):
			streamFlag = a[len("--stream="):]
		default:
			return runErr(refuse("usage", ""))
		}
	}

	client, _, err := dialSync(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	defer client.close()

	sel := streamFlag
	if sel == "" {
		rc, err := loadRemoteConfig(fs, root)
		if err != nil {
			return runErr(err)
		}
		if rc == nil || rc.Stream == "" {
			return runErr(refuse("stream_missing", ""))
		}
		sel = rc.Stream
	}
	st, err := client.open(sel)
	if err != nil {
		return runErr(err)
	}

	var firstParent *string
	if st.ForkedFrom != nil {
		firstParent = &st.ForkedFrom.Change
	}
	lines, err := fetchAndVerifyStreamChanges(client, fs, root, st, nil, firstParent)
	if err != nil {
		return runErr(err)
	}
	if len(lines) == 0 {
		// An empty log is only honest on a fork record whose head is the
		// pinned fork origin.
		if st.Head != nil && (st.ForkedFrom == nil || *st.Head != st.ForkedFrom.Change) {
			return runErr(refuse("stream_malformed", "non-null head on empty stream"))
		}
		return 0
	}
	last, err := ParseChange(lines[len(lines)-1])
	if err != nil {
		return runErr(err)
	}
	if st.Head == nil || last.ID != *st.Head {
		return runErr(refuse("stream_malformed", "head mismatch"))
	}
	for _, line := range lines {
		c, err := ParseChange(line)
		if err != nil {
			return runErr(err)
		}
		consoleFn("flint: verify " + c.ID + " sig: verified")
	}
	return 0
}

// cmdClone implements `flint clone <remote> <stream>`: fetch the target
// stream plus its forked_from ancestors, verify every Change, and write
// the raw JSONL bytes into streams/<id>.jsonl verbatim. No workspace, no
// source files — clone registers signed history (M101a / index #2303).
func cmdClone(fs FS, root string, args []string) error {
	var remoteFlag, streamFlag string
	positional := 0
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--remote="):
			remoteFlag = a[len("--remote="):]
		case strings.HasPrefix(a, "--stream="):
			streamFlag = a[len("--stream="):]
		case strings.HasPrefix(a, "-"):
			return refuse("usage", "")
		default:
			switch positional {
			case 0:
				remoteFlag = a
			case 1:
				streamFlag = a
			default:
				return refuse("usage", "")
			}
			positional++
		}
	}
	if streamFlag == "" {
		return refuse("usage", "")
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}

	client, remote, err := dialSync(fs, root, remoteFlag)
	if err != nil {
		return err
	}
	defer client.close()

	// Follow forked_from from the target back to the root ancestor.
	var chain []*Stream
	seen := map[string]bool{}
	target, err := client.open(streamFlag)
	if err != nil {
		return err
	}
	seen[target.ID] = true
	chain = append(chain, target)
	for chain[len(chain)-1].ForkedFrom != nil {
		ff := chain[len(chain)-1].ForkedFrom
		if seen[ff.Stream] {
			return refuse("stream_malformed", "fork cycle")
		}
		parent, err := client.open(ff.Stream)
		if err != nil {
			return err
		}
		seen[parent.ID] = true
		chain = append(chain, parent)
	}
	for i, j := 0, len(chain)-1; i < j; i, j = i+1, j-1 {
		chain[i], chain[j] = chain[j], chain[i]
	}

	type payload struct {
		record     *Stream
		rawLines   [][]byte
		appendFrom int
		existed    bool
	}
	var payloads []payload
	totalNew := 0
	newStreams := 0

	for _, st := range chain {
		var firstParent *string
		if st.ForkedFrom != nil {
			firstParent = &st.ForkedFrom.Change
		}
		lines, err := fetchAndVerifyStreamChanges(client, fs, root, st, nil, firstParent)
		if err != nil {
			return err
		}

		// The fetched log must end exactly at the record's head.
		if len(lines) > 0 {
			last, err := ParseChange(lines[len(lines)-1])
			if err != nil {
				return err
			}
			if st.Head == nil {
				return refuse("stream_malformed", "null head with changes")
			}
			if last.ID != *st.Head {
				return refuse("stream_malformed", "head mismatch")
			}
		} else if st.ForkedFrom != nil {
			if st.Head == nil || *st.Head != st.ForkedFrom.Change {
				return refuse("stream_malformed", "fork head mismatch")
			}
		} else if st.Head != nil {
			return refuse("stream_malformed", "non-null head on empty stream")
		}

		// A local stream is never silently overwritten: re-clone is only a
		// fast-forward — the existing log must be a verbatim prefix of the
		// remote log and the record must agree.
		if local, ok := idx.StreamsByID[st.ID]; ok {
			if local.Name != st.Name || !forkOriginEql(local.ForkedFrom, st.ForkedFrom) {
				return refuse("stream_exists", local.Name)
			}
			localLines, err := readStreamRawLines(fs, root, st.ID)
			if err != nil {
				return err
			}
			isPrefix := len(localLines) <= len(lines)
			if isPrefix {
				for i, ll := range localLines {
					if !bytes.Equal(ll, lines[i]) {
						isPrefix = false
						break
					}
				}
			}
			if !isPrefix {
				remoteInLocal := false
				if st.Head != nil {
					if local.ForkedFrom != nil && *st.Head == local.ForkedFrom.Change {
						remoteInLocal = true
					}
					if !remoteInLocal {
						localChanges, lerr := ReadStreamChanges(fs, root, st.ID)
						if lerr != nil {
							return lerr
						}
						for _, lc := range localChanges {
							if lc.ID == *st.Head {
								remoteInLocal = true
								break
							}
						}
					}
				}
				if remoteInLocal {
					return refuse("stream_exists", local.Name)
				}
				return refuse("fork_needed", "")
			}
			totalNew += len(lines) - len(localLines)
			payloads = append(payloads, payload{record: st, rawLines: lines, appendFrom: len(localLines), existed: true})
		} else {
			if _, ok := idx.StreamsByName[st.Name]; ok {
				return refuse("stream_exists", st.Name)
			}
			newStreams++
			totalNew += len(lines)
			payloads = append(payloads, payload{record: st, rawLines: lines})
		}
	}

	if idx.ChangeCount+totalNew > MaxChanges {
		return refuse("store_too_large", "changes")
	}

	if err := ensureDirAll(fs, streamsDir(root)); err != nil {
		return err
	}
	for _, p := range payloads {
		logPath := streamLogPath(root, p.record.ID)
		if p.existed {
			if len(p.rawLines) > p.appendFrom {
				var buf bytes.Buffer
				for _, line := range p.rawLines[p.appendFrom:] {
					buf.Write(line)
					buf.WriteByte('\n')
				}
				if err := fs.AppendSync(logPath, buf.Bytes()); err != nil {
					return err
				}
			}
		} else if len(p.rawLines) > 0 {
			var buf bytes.Buffer
			for _, line := range p.rawLines {
				buf.Write(line)
				buf.WriteByte('\n')
			}
			if err := fs.WriteFileSafe(logPath, buf.Bytes()); err != nil {
				return err
			}
		}
		if err := WriteStreamRecord(fs, root, p.record); err != nil {
			return err
		}
	}
	if err := writeRemoteConfig(fs, root, RemoteConfig{Remote: remote, Stream: target.ID}); err != nil {
		return err
	}

	// `changes=` counts the Changes replayed along the target's parent
	// chain to the root — the same number the Zig client prints from its
	// atom replay, minus the workspace it materializes into.
	cloneIdx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	allChanges, err := LoadAllStreamChanges(fs, root, cloneIdx)
	if err != nil {
		return err
	}
	_, replayed, err := ReplayStreamAtoms(target.Head, allChanges)
	if err != nil {
		return err
	}

	consoleFn("flint: clone ok stream=" + target.Name + " changes=" + vi.Itoa64(int64(replayed)))
	return nil
}

// cmdPull implements `flint pull [--remote=<url>] [--stream=<s>]`: read the
// remote head, fetch the suffix after the local head, verify, append the
// raw lines, and roll the local record forward. Divergence refuses
// fork_needed — the client resolves with fork/merge, never overwrite.
func cmdPull(fs FS, root string, args []string) error {
	remoteFlag, streamFlag, err := parseRemoteArgs(args)
	if err != nil {
		return err
	}
	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	rc, err := loadRemoteConfig(fs, root)
	if err != nil {
		return err
	}
	st, err := resolveSyncStream(idx, rc, streamFlag)
	if err != nil {
		return err
	}
	client, remote, err := dialSync(fs, root, remoteFlag)
	if err != nil {
		return err
	}
	defer client.close()

	localSt, localChanges, err := LoadStream(fs, root, st.ID)
	if err != nil {
		return err
	}
	remoteRec, err := client.open(st.ID)
	if err != nil {
		return err
	}
	remoteHead := remoteRec.Head
	if remoteHead == nil {
		consoleFn("flint: pull up to date")
		return nil
	}
	if ptrEqual(localSt.Head, remoteHead) {
		consoleFn("flint: pull up to date")
		return nil
	}
	// Remote head already inside local history means local is ahead.
	if localSt.ForkedFrom != nil && *remoteHead == localSt.ForkedFrom.Change {
		consoleFn("flint: pull up to date")
		return nil
	}
	for _, lc := range localChanges {
		if lc.ID == *remoteHead {
			consoleFn("flint: pull up to date")
			return nil
		}
	}

	var afterArg *string
	if len(localChanges) > 0 {
		afterArg = localSt.Head
	}
	expectedFirst := localSt.Head
	if expectedFirst == nil && localSt.ForkedFrom != nil {
		expectedFirst = &localSt.ForkedFrom.Change
	}
	fetched, err := fetchAndVerifyStreamChanges(client, fs, root, localSt, afterArg, expectedFirst)
	if err != nil {
		if re, ok := err.(*RefuseError); ok && re.Code == "change_missing" {
			return refuse("fork_needed", "")
		}
		return err
	}
	if len(fetched) == 0 {
		if localSt.Head != nil {
			return refuse("fork_needed", "")
		}
		consoleFn("flint: pull up to date")
		return nil
	}
	if idx.ChangeCount+len(fetched) > MaxChanges {
		return refuse("store_too_large", "changes")
	}

	last, err := ParseChange(fetched[len(fetched)-1])
	if err != nil {
		return err
	}
	var buf bytes.Buffer
	for _, line := range fetched {
		buf.Write(line)
		buf.WriteByte('\n')
	}
	if err := fs.AppendSync(streamLogPath(root, localSt.ID), buf.Bytes()); err != nil {
		return err
	}
	updated := Stream{
		ID:         localSt.ID,
		Name:       localSt.Name,
		Head:       &last.ID,
		Created:    localSt.Created,
		ForkedFrom: localSt.ForkedFrom,
	}
	if err := WriteStreamRecord(fs, root, &updated); err != nil {
		return err
	}
	if err := writeRemoteConfig(fs, root, RemoteConfig{Remote: remote, Stream: localSt.ID}); err != nil {
		return err
	}
	consoleFn("flint: pull ok stream=" + localSt.Name + " changes=" + vi.Itoa64(int64(len(fetched))))
	return nil
}

// parseRemoteArgs parses the shared pull/push flag surface.
func parseRemoteArgs(args []string) (remoteFlag, streamFlag string, err error) {
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--remote="):
			remoteFlag = a[len("--remote="):]
		case strings.HasPrefix(a, "--stream="):
			streamFlag = a[len("--stream="):]
		default:
			return "", "", refuse("usage", "")
		}
	}
	return remoteFlag, streamFlag, nil
}

// pushSingleStream ships one stream's unsent suffix, creating the stream
// on the remote first when `heads` showed it missing. Returns changes sent
// and whether the stream was created.
func pushSingleStream(fs FS, root string, client *syncClient, serverHeads map[string]*string, streamID string) (int, bool, error) {
	loaded, changes, err := LoadStream(fs, root, streamID)
	if err != nil {
		return 0, false, err
	}
	rawLines, err := readStreamRawLines(fs, root, streamID)
	if err != nil {
		return 0, false, err
	}

	wasCreated := false
	var remoteHead *string
	if rh, ok := serverHeads[streamID]; ok {
		remoteHead = rh
	} else {
		var initHead *string
		if loaded.ForkedFrom != nil {
			initHead = &loaded.ForkedFrom.Change
		}
		initRec := &Stream{
			ID:         loaded.ID,
			Name:       loaded.Name,
			Head:       initHead,
			Created:    loaded.Created,
			ForkedFrom: loaded.ForkedFrom,
		}
		if err := client.create(initRec); err != nil {
			return 0, false, err
		}
		wasCreated = true
		remoteHead = initHead
		headCopy := copyStrPtr(initHead)
		serverHeads[streamID] = headCopy
	}

	if ptrEqual(loaded.Head, remoteHead) {
		return 0, wasCreated, nil
	}
	if len(rawLines) == 0 {
		// Local log is empty but heads differ: let the server refuse
		// (stale_head on its record comparison) rather than guess.
		if _, err := client.append(streamID, loaded.Head, nil); err != nil {
			return 0, wasCreated, err
		}
		return 0, wasCreated, nil
	}

	var forkHead *string
	if loaded.ForkedFrom != nil {
		forkHead = &loaded.ForkedFrom.Change
	}
	remoteIsInitial := ptrEqual(remoteHead, forkHead)

	startIdx := -1
	var expectedHead *string
	if remoteIsInitial {
		startIdx = 0
		expectedHead = remoteHead
	} else if remoteHead != nil {
		for i, c := range changes {
			if c.ID == *remoteHead {
				startIdx = i + 1
				expectedHead = remoteHead
				break
			}
		}
	}
	if startIdx < 0 {
		// Remote head is not in local history: remote moved ahead or
		// diverged. Send the tail with its parent as expected_head so the
		// server answers stale_head on its own record comparison.
		lastIdx := len(rawLines) - 1
		if _, err := client.append(streamID, changes[lastIdx].Parent, rawLines[lastIdx:lastIdx+1]); err != nil {
			return 0, wasCreated, err
		}
		return 0, wasCreated, refuse("stale_head", "")
	}
	if startIdx >= len(rawLines) {
		return 0, wasCreated, refuse("stale_head", "")
	}

	curExpected := copyStrPtr(expectedHead)
	sent := 0
	for batchStart := startIdx; batchStart < len(rawLines); {
		batchEnd := appendBatchEnd(rawLines, batchStart)
		newHead, err := client.append(streamID, curExpected, rawLines[batchStart:batchEnd])
		if err != nil {
			return sent, wasCreated, err
		}
		curExpected = &newHead
		sent += batchEnd - batchStart
		batchStart = batchEnd
	}
	serverHeads[streamID] = copyStrPtr(curExpected)
	return sent, wasCreated, nil
}

// appendBatchEnd returns the exclusive end of the next append batch: at
// most maxBatchChanges lines whose escaped payload stays under
// maxBatchBytes (a single line always batches, even over the cap). The
// escaped length matches what client.append writes, q(line) per change.
func appendBatchEnd(rawLines [][]byte, start int) int {
	end := start
	payload := 0
	for end < len(rawLines) && end-start < maxBatchChanges {
		n := len(q(string(bytes.TrimRight(rawLines[end], "\r\n"))))
		if end > start && payload+n > maxBatchBytes {
			break
		}
		payload += n
		end++
	}
	return end
}

// cmdPush implements `flint push [--remote=<url>] [--stream=<s>]`:
// `create` any streams the server lacks (forked_from ancestors first),
// then `append` the local unsent suffix.
func cmdPush(fs FS, root string, args []string) error {
	remoteFlag, streamFlag, err := parseRemoteArgs(args)
	if err != nil {
		return err
	}
	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	rc, err := loadRemoteConfig(fs, root)
	if err != nil {
		return err
	}
	st, err := resolveSyncStream(idx, rc, streamFlag)
	if err != nil {
		return err
	}
	client, remote, err := dialSync(fs, root, remoteFlag)
	if err != nil {
		return err
	}
	defer client.close()

	// Local forked_from ancestry, root first, ending at the target.
	var chainIDs []string
	chainIDs = append(chainIDs, st.ID)
	for cur := st; cur.ForkedFrom != nil; {
		parent, ok := idx.StreamsByID[cur.ForkedFrom.Stream]
		if !ok {
			break
		}
		chainIDs = append(chainIDs, parent.ID)
		cur = parent
	}
	for i, j := 0, len(chainIDs)-1; i < j; i, j = i+1, j-1 {
		chainIDs[i], chainIDs[j] = chainIDs[j], chainIDs[i]
	}

	serverHeads, err := client.heads()
	if err != nil {
		return err
	}
	for _, ancID := range chainIDs[:len(chainIDs)-1] {
		if _, _, err := pushSingleStream(fs, root, client, serverHeads, ancID); err != nil {
			return err
		}
	}
	sent, created, err := pushSingleStream(fs, root, client, serverHeads, st.ID)
	if err != nil {
		return err
	}

	if err := writeRemoteConfig(fs, root, RemoteConfig{Remote: remote, Stream: st.ID}); err != nil {
		return err
	}
	if sent == 0 && !created {
		consoleFn("flint: push up to date")
	} else {
		consoleFn("flint: push ok stream=" + st.Name + " changes=" + vi.Itoa64(int64(sent)))
	}
	return nil
}
