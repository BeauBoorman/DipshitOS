package store

import (
	"bytes"
	"strconv"
	"strings"

	"virelai/vi"
)

// channel is the untrusted fetch path release.go and the ELF arrive by.
// Every byte it returns is verified against the signed stream head before
// use — the channel may be the host, a relay, or anything in between.
type channel interface {
	// fetch returns the bytes at the channel-relative path
	// (<stream>/release.go, <stream>/<NAME>.ELF), or a named refusal.
	fetch(rel string, max int) ([]byte, error)
}

// openChannel resolves a --channel argument: an http:// URL is the
// cleartext relay; anything else is a share-drop directory.
func openChannel(fs FS, arg string) (channel, error) {
	c := strings.TrimSpace(arg)
	if c == "" {
		c = DefaultChannel
	}
	if strings.HasPrefix(c, "http://") {
		return newHTTPChannel(c)
	}
	if strings.Contains(c, "://") {
		return nil, refuse("channel_malformed", c)
	}
	return &dirChannel{fs: fs, root: strings.TrimSuffix(c, "/")}, nil
}

// dirChannel is the share drop: <dir>/<stream>/release.go and
// <dir>/<stream>/<NAME>.ELF dropped onto /host by the publisher. A
// missing member refuses channel_missing; a path escape is refused
// channel_malformed.
type dirChannel struct {
	fs   FS
	root string
}

func (d *dirChannel) fetch(rel string, max int) ([]byte, error) {
	if err := checkRelPath(rel); err != nil {
		return nil, err
	}
	p := d.root + "/" + rel
	if !d.fs.Exists(p) {
		return nil, refuse("channel_missing", rel)
	}
	b, err := d.fs.ReadFile(p, max)
	if err != nil {
		if re, ok := err.(*RefuseError); ok {
			return nil, re
		}
		return nil, refuse("channel_missing", rel)
	}
	return b, nil
}

// checkRelPath bounds channel-relative names to one directory level of
// share-name grammar — no "..", no leading slash, no empty components.
func checkRelPath(rel string) error {
	parts := strings.Split(rel, "/")
	if len(parts) == 0 || len(parts) > 3 {
		return refuse("channel_malformed", rel)
	}
	for _, p := range parts {
		if p == "" || p == "." || p == ".." || len(p) > 32 {
			return refuse("channel_malformed", rel)
		}
		for i := 0; i < len(p); i++ {
			c := p[i]
			if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
				(c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
				return refuse("channel_malformed", rel)
			}
		}
	}
	return nil
}

// ---- cleartext HTTP channel ---------------------------------------------
//
// The hermetic HTTP relay: --channel=http://<ip>:<port>[/<base>] issues a
// plain HTTP/1.0 GET <base>/<stream>/<member> per artifact. The stream is
// untrusted by construction; the framing contract is the one
// user/go/fetch/legacy.go enforces (no chunked, no compression, one
// Content-Length). The dial seam is var-bound so host tests drive it with
// a scripted connection.

const (
	httpHeaderLimit = 1024
	httpReadChunk   = 1460
	// httpTimeoutNs bounds one request/response exchange; a dark peer
	// fails closed instead of parking on the socket's 30 s budget.
	httpTimeoutNs = 5_000_000_000
)

type httpConn interface {
	Send(p []byte) (int, error)
	Recv(p []byte) (int, error)
	Close() error
}

var httpDialFn = func(host string, port uint16) (httpConn, error) {
	c, err := vi.Dial(host, port)
	if err != nil {
		return nil, err
	}
	c.SetRecvDeadline(httpTimeoutNs)
	return c, nil
}

type httpChannel struct {
	host string
	port uint16
	base string // "" or "/x/y" (no trailing slash)
}

func newHTTPChannel(raw string) (*httpChannel, error) {
	rest := strings.TrimPrefix(raw, "http://")
	authority := rest
	base := ""
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		authority = rest[:i]
		base = strings.TrimSuffix(rest[i:], "/")
		if strings.Contains(base, "..") {
			return nil, refuse("channel_malformed", raw)
		}
	}
	host, portStr, ok := strings.Cut(authority, ":")
	if !ok || host == "" || portStr == "" {
		return nil, refuse("channel_malformed", raw)
	}
	port64, err := strconv.ParseUint(portStr, 10, 16)
	if err != nil || port64 == 0 {
		return nil, refuse("channel_malformed", raw)
	}
	return &httpChannel{host: host, port: uint16(port64), base: base}, nil
}

func (h *httpChannel) fetch(rel string, max int) ([]byte, error) {
	if err := checkRelPath(rel); err != nil {
		return nil, err
	}
	path := h.base + "/" + rel
	c, err := httpDialFn(h.host, h.port)
	if err != nil {
		return nil, refuse("channel_missing", rel)
	}
	defer c.Close()
	req := "GET " + path + " HTTP/1.0\r\n" +
		"Host: " + h.host + "\r\n" +
		"Accept-Encoding: identity\r\n" +
		"Connection: close\r\n\r\n"
	if _, err := c.Send([]byte(req)); err != nil {
		return nil, refuse("channel_missing", rel)
	}
	status, body, err := readHTTPResponse(c, max)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, refuse("channel_missing", rel)
	}
	return body, nil
}

// readHTTPResponse frames one HTTP/1.0 response: head to CRLFCRLF capped
// at httpHeaderLimit, then a Content-Length- or FIN-delimited body capped
// at max. Returns (status, body, refusal).
func readHTTPResponse(c httpConn, max int) (int, []byte, error) {
	var raw []byte
	var buf [httpReadChunk]byte
	for {
		n, err := c.Recv(buf[:])
		if n > 0 {
			raw = append(raw, buf[:n]...)
			if i := bytes.Index(raw, []byte("\r\n\r\n")); i >= 0 {
				head := raw[:i+4]
				body := append([]byte(nil), raw[i+4:]...)
				status, length, perr := parseHTTPHead(head)
				if perr != nil {
					return 0, nil, perr
				}
				if length >= 0 && length > max {
					return 0, nil, refuse("file_too_large", "")
				}
				for length < 0 || len(body) < length {
					if len(body) > max {
						return 0, nil, refuse("file_too_large", "")
					}
					m, rerr := c.Recv(buf[:])
					if m > 0 {
						take := m
						if length >= 0 && len(body)+take > length {
							take = length - len(body)
						}
						body = append(body, buf[:take]...)
					}
					if length < 0 && (rerr != nil || m == 0) {
						return status, body, nil
					}
					if rerr != nil && (length < 0 || len(body) < length) {
						return 0, nil, refuse("channel_malformed", "body")
					}
					if m == 0 && length >= 0 && len(body) < length {
						return 0, nil, refuse("channel_malformed", "body")
					}
				}
				return status, body[:length], nil
			}
		}
		if len(raw) >= httpHeaderLimit {
			return 0, nil, refuse("channel_malformed", "head")
		}
		if err != nil || n == 0 {
			return 0, nil, refuse("channel_missing", "")
		}
	}
}

// parseHTTPHead decodes the status line and the one honored header. The
// framing refusals mirror fetch/legacy.go: chunked or compressed bodies
// and a second Content-Length are channel_malformed, never misparsed.
func parseHTTPHead(head []byte) (status int, length int, err error) {
	status = -1
	length = -1
	end := bytes.IndexByte(head, '\n')
	if end < 0 {
		return 0, 0, refuse("channel_malformed", "status")
	}
	line := strings.TrimSuffix(string(head[:end]), "\r")
	fields := strings.Fields(line)
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "HTTP/") {
		return 0, 0, refuse("channel_malformed", "status")
	}
	code, cerr := strconv.Atoi(fields[1])
	if cerr != nil || code < 100 || code > 999 {
		return 0, 0, refuse("channel_malformed", "status")
	}
	status = code
	for _, h := range strings.Split(string(head), "\r\n")[1:] {
		i := strings.IndexByte(h, ':')
		if i < 0 {
			continue
		}
		name := strings.TrimSpace(h[:i])
		v := strings.TrimSpace(h[i+1:])
		switch {
		case strings.EqualFold(name, "transfer-encoding"):
			return 0, 0, refuse("channel_malformed", "transfer-encoding")
		case strings.EqualFold(name, "content-encoding"):
			if !strings.EqualFold(v, "identity") {
				return 0, 0, refuse("channel_malformed", "content-encoding")
			}
		case strings.EqualFold(name, "content-length"):
			if length >= 0 || v == "" {
				return 0, 0, refuse("channel_malformed", "content-length")
			}
			n, cerr := strconv.Atoi(v)
			if cerr != nil || n < 0 {
				return 0, 0, refuse("channel_malformed", "content-length")
			}
			length = n
		}
	}
	return status, length, nil
}
