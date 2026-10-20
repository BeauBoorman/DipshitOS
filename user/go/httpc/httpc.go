// Package httpc is the shared HTTP/1.1 client wire engine for the guest
// consumers (GOFETCH, WEB) — M135b (card #2764). It owns the request
// shape, the response head grammar, the incremental chunked decoder, and
// the gzip content-coding pass through virelai/flate. Every consumer of
// an HTTP connection shares one parser so the refusal grammar cannot
// diverge between the console fetcher and the browser.
//
// The package is pure: inputs are byte slices or a blocking pull source,
// so the whole grammar is host-tested without a socket. Socket specifics
// (deadlines, FIN detection, cancellation) stay with the callers.
package httpc

import (
	"bytes"
	"strconv"
	"strings"
)

// The named refusal grammar. These strings are the stable error surface
// on both consumers' serial markers (fetch: ... / web: error ...).
const (
	FramingInvalid     = "http-framing-invalid"
	FramingUnsupported = "http-framing-unsupported"
	HeaderLimit        = "http-header-limit"
	BodyLimit          = "http-body-limit"
	PrematureEOF       = "http-premature-eof"
	ChunkedMalformed   = "chunked-malformed"
	GzipMalformed      = "gzip-malformed"
	GzipCRC            = "gzip-crc"
	GzipTooLarge       = "gzip-too-large"
)

// GetRequest formats the one request shape every consumer sends:
// HTTP/1.1, keep-alive armed, gzip accepted. hostHeader is the authority
// already rendered by the caller (host or host:port); a cookie carrying
// bytes that could forge a header line is dropped, never emitted.
func GetRequest(hostHeader, path, cookie string) string {
	if path == "" {
		path = "/"
	}
	req := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + hostHeader + "\r\n" +
		"User-Agent: VirelaiOS/1.0\r\n"
	if strings.ContainsAny(cookie, "\x00\r\n") {
		cookie = ""
	}
	if cookie != "" {
		req += "Cookie: " + cookie + "\r\n"
	}
	return req + "Connection: keep-alive\r\nAccept-Encoding: gzip\r\n\r\n"
}

// Head is a parsed response head: the status, the declared framing, and
// the connection policy the response permits.
type Head struct {
	Status  int
	Length  int  // Content-Length; -1 when absent
	Chunked bool // Transfer-Encoding: chunked
	Gzip    bool // Content-Encoding: gzip
	Minor   int  // HTTP/1.<minor> — 0 or 1
	close_  bool // Connection: close token seen
	keepOn  bool // explicit Connection: keep-alive token (HTTP/1.0)
	NoBody  bool // status forbids a message body (1xx, 204, 304)
}

// SelfDelimiting reports whether the message body ends on a declared
// boundary rather than the peer's FIN — the precondition for reusing the
// connection at all.
func (h Head) SelfDelimiting() bool {
	return h.NoBody || h.Length >= 0 || h.Chunked
}

// KeepAlive is the response's reuse verdict: a self-delimiting message on
// a connection the peer did not close. HTTP/1.1 keeps alive unless it
// says close; HTTP/1.0 keeps alive only when it says so.
func (h Head) KeepAlive() bool {
	if !h.SelfDelimiting() || h.close_ {
		return false
	}
	if h.Minor == 0 {
		return h.keepOn
	}
	return true
}

// HeadEnd finds the offset just past the head terminator — the first
// CRLFCRLF (or bare LFLF, which the guest render path has always
// tolerated). -1 while the head is incomplete.
func HeadEnd(raw []byte) int {
	for i := 0; i+1 < len(raw); i++ {
		if raw[i] == '\n' && raw[i+1] == '\n' {
			return i + 2
		}
		if i+3 < len(raw) && raw[i] == '\r' && raw[i+1] == '\n' && raw[i+2] == '\r' && raw[i+3] == '\n' {
			return i + 4
		}
	}
	return -1
}

// ParseHead decodes a complete head block (terminator included or not):
// the status line, then the honored fields. maxLine caps one line,
// maxFields the field count; a header section needing more is a
// HeaderLimit refusal. The grammar is strict on purpose — a peer whose
// framing does not parse is refused by name, never misparsed into a body.
func ParseHead(head []byte, maxLine, maxFields int) (Head, string) {
	var h Head
	h.Status, h.Length = -1, -1
	text := strings.TrimRight(string(head), "\r\n")
	lines := strings.Split(text, "\n")
	if len(lines) == 0 {
		return h, FramingInvalid
	}
	statusLine := strings.TrimSuffix(lines[0], "\r")
	if len(statusLine) > maxLine || !validStatusLine(statusLine) {
		return h, FramingInvalid
	}
	h.Minor = int(statusLine[7] - '0')
	status := 0
	for i := 9; i < 12; i++ {
		status = status*10 + int(statusLine[i]-'0')
	}
	if status < 100 {
		return h, FramingInvalid
	}
	h.Status = status
	h.NoBody = status >= 100 && status < 200 || status == 204 || status == 304
	fields := lines[1:]
	if len(fields) > maxFields {
		return h, HeaderLimit
	}
	teSeen, ceSeen, clSeen := false, false, false
	for _, rawLine := range fields {
		line := strings.TrimSuffix(rawLine, "\r")
		i := strings.IndexByte(line, ':')
		if i <= 0 || len(line) > maxLine || strings.ContainsAny(line, "\x00\r") ||
			!validFieldName(line[:i]) {
			return h, FramingInvalid
		}
		name, value := strings.ToLower(line[:i]), strings.TrimSpace(line[i+1:])
		switch name {
		case "transfer-encoding":
			// chunked is the only coding this engine decodes, it must be
			// the single token, and it forbids a Content-Length beside it
			// (the pair is the classic desync vector).
			if !strings.EqualFold(value, "chunked") {
				return h, FramingUnsupported
			}
			if teSeen || clSeen {
				return h, FramingInvalid
			}
			teSeen, h.Chunked = true, true
		case "content-encoding":
			if ceSeen {
				return h, FramingInvalid
			}
			ceSeen = true
			switch {
			case strings.EqualFold(value, "identity"):
			case strings.EqualFold(value, "gzip"):
				h.Gzip = true
			default:
				return h, FramingUnsupported
			}
		case "content-length":
			if clSeen || teSeen || value == "" {
				return h, FramingInvalid
			}
			clSeen = true
			n, err := strconv.Atoi(value)
			if err != nil || n < 0 {
				return h, FramingInvalid
			}
			h.Length = n
		case "connection":
			for _, tok := range strings.Split(value, ",") {
				switch strings.ToLower(strings.TrimSpace(tok)) {
				case "close":
					h.close_ = true
				case "keep-alive":
					h.keepOn = true
				}
			}
		}
	}
	return h, ""
}

func validStatusLine(line string) bool {
	if len(line) < 12 || (!strings.HasPrefix(line, "HTTP/1.0 ") && !strings.HasPrefix(line, "HTTP/1.1 ")) {
		return false
	}
	for _, c := range line {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	return line[9] >= '0' && line[9] <= '9' && line[10] >= '0' && line[10] <= '9' &&
		line[11] >= '0' && line[11] <= '9' && (len(line) == 12 || line[12] == ' ')
}

func validFieldName(name string) bool {
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
			strings.ContainsRune("!#$%&'*+-.^_`|~", c)) {
			return false
		}
	}
	return name != ""
}

// LocationHeader extracts the Location value from a parsed head block
// ("" when absent); the field-name match is case-insensitive.
func LocationHeader(head []byte) string {
	lines := bytes.Split(head, []byte("\n"))
	for _, ln := range lines[1:] {
		ln = bytes.TrimRight(ln, "\r")
		i := bytes.IndexByte(ln, ':')
		if i <= 0 {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(string(ln[:i])), "location") {
			return strings.TrimSpace(string(ln[i+1:]))
		}
	}
	return ""
}
