// GOHTTPD.ELF — the Go replacement for the Zig HTTPD.BIN (M71l / #1571);
// second pass (#2200): persistent HTTP/1.1 semantics.
//
// This file is deliberately ABI-free: request splitting, parsing, canonical
// paths, routing and formatting live here so they run in host tests. The
// guest wiring (listen, accept, recv, send) is in main.go. Nothing here
// imports virelai/vi.
package main

import (
	"bytes"
	"strconv"
	"strings"
)

// maxRequestBytes bounds one request head (line + headers) buffered before
// the request is refused. The kernel's TCP seam does not reassemble; this
// application limit stays independent of the larger single-segment bound.
const maxRequestBytes = 1024

// shareRoot is the directory every file target resolves under. A request
// target is canonicalized to "/a/b" and served as shareRoot+"/a/b"; the
// canonical form can never escape the root, so no user-supplied string
// reaches the filesystem outside it (the M97 file-channel standard).
const shareRoot = "/host"

type request struct {
	Method    string
	RawTarget string // the path as sent (query stripped) — what the log names
	Path      string // canonical "/a/b"; "" when a ".." segment blocked it
	Version   string // "HTTP/1.1" or "HTTP/1.0"
	KeepAlive bool   // resolved Connection semantics for this version
}

// wantClose reports whether the connection must close after this request's
// response: the resolved keep-alive answer is the HTTP version's default
// flipped by an explicit Connection token (RFC 9112 §9.3/§9.6).
func (r request) wantClose() bool { return !r.KeepAlive }

type response struct {
	Status      int
	ContentType string
	Body        []byte
}

var statusText = map[int]string{
	200: "OK",
	400: "Bad Request",
	404: "Not Found",
	405: "Method Not Allowed",
}

func indexBody() []byte {
	return []byte("<!doctype html>\n<html><head><title>VirelaiOS</title></head>\n" +
		"<body><h1>VirelaiOS</h1>\n" +
		"<p><span class=\"badge\">ONLINE &bull; PORT 8080</span></p>\n" +
		"<p><a href=\"/HTTPD.TXT\">/HTTPD.TXT</a> &middot; <a href=\"/healthz\">/healthz</a></p>\n" +
		"</body></html>\n")
}

func healthBody() []byte { return []byte("{\"status\":\"ok\",\"port\":8080}\n") }

func notFound() response {
	return response{Status: 404, ContentType: "text/plain; charset=utf-8", Body: []byte("not found\n")}
}

func badRequest() response {
	return response{Status: 400, ContentType: "text/plain; charset=utf-8", Body: []byte("bad request\n")}
}

// headerEnd finds the end of the request head: index one past the blank
// line, in CRLF or bare-LF form. -1 means the head is incomplete (not yet
// malformed — more bytes may arrive).
func headerEnd(raw []byte) int {
	if i := bytes.Index(raw, []byte("\r\n\r\n")); i >= 0 {
		return i + 4
	}
	if i := bytes.Index(raw, []byte("\n\n")); i >= 0 {
		return i + 2
	}
	return -1
}

// splitRequest peels one complete request head off buf, returning it and
// a FRESH remainder slice (which may already hold the next pipelined
// request's bytes). ok=false means the head is not yet complete. The
// remainder is copied, never an alias of buf: serveConn's loop hands it
// back as the next iteration's input, so an alias would let the caller
// overwrite head before it is parsed.
func splitRequest(buf []byte) (head []byte, rest []byte, ok bool) {
	end := headerEnd(buf)
	if end < 0 {
		return nil, buf, false
	}
	return buf[:end], append([]byte(nil), buf[end:]...), true
}

// canonicalPath reduces a request target to "/a/b": the query is dropped,
// empty and "." segments collapse, and a ".." segment sets blocked — the
// caller routes a blocked path to 404 so a traversal probe never reaches a
// path outside shareRoot. Percent escapes are NOT decoded: the share's
// names are its literal bytes, so "%2e%2e" is an ordinary (and absent)
// filename, not a traversal.
func canonicalPath(target string) (path string, blocked bool) {
	if i := strings.IndexByte(target, '?'); i >= 0 {
		target = target[:i]
	}
	var segs []string
	for _, seg := range strings.Split(target, "/") {
		switch seg {
		case "", ".":
			continue
		case "..":
			return "", true
		default:
			segs = append(segs, seg)
		}
	}
	if len(segs) == 0 {
		return "/", false
	}
	return "/" + strings.Join(segs, "/"), false
}

// parseRequest reads the request head: METHOD SP TARGET SP HTTP/1.x, then
// scans headers for Connection semantics. It refuses anything that is not
// a well-formed, absolute-path HTTP/1.x request, and any request carrying
// a body (Content-Length or Transfer-Encoding — the server never reads
// request bodies, so a declared body would desync the stream).
func parseRequest(head []byte) (request, bool) {
	if headerEnd(head) != len(head) {
		return request{}, false
	}
	lines := bytes.Split(head, []byte("\n"))
	if len(lines) == 0 {
		return request{}, false
	}
	line := lines[0]
	if n := len(line); n > 0 && line[n-1] == '\r' {
		line = line[:n-1]
	}
	sp1 := bytes.IndexByte(line, ' ')
	if sp1 <= 0 {
		return request{}, false
	}
	rest := line[sp1+1:]
	sp2 := bytes.IndexByte(rest, ' ')
	if sp2 <= 0 {
		return request{}, false
	}
	method := string(line[:sp1])
	target := string(rest[:sp2])
	version := string(rest[sp2+1:])
	var keepAlive bool
	switch version {
	case "HTTP/1.1":
		keepAlive = true
	case "HTTP/1.0":
		keepAlive = false
	default:
		return request{}, false
	}
	for _, hl := range lines[1:] {
		if n := len(hl); n > 0 && hl[n-1] == '\r' {
			hl = hl[:n-1]
		}
		name, value, found := bytes.Cut(hl, []byte(":"))
		if !found {
			continue
		}
		switch strings.ToLower(string(bytes.TrimSpace(name))) {
		case "connection":
			for _, tok := range strings.Split(string(value), ",") {
				switch strings.ToLower(strings.TrimSpace(tok)) {
				case "close":
					keepAlive = false
				case "keep-alive":
					keepAlive = true
				}
			}
		case "content-length":
			v := strings.TrimSpace(string(value))
			if v != "0" {
				return request{}, false
			}
		case "transfer-encoding":
			return request{}, false
		}
	}
	if !strings.HasPrefix(target, "/") {
		return request{}, false
	}
	canon, blocked := canonicalPath(target)
	if blocked {
		canon = ""
	}
	return request{Method: method, RawTarget: target, Path: canon, Version: version, KeepAlive: keepAlive}, true
}

// serveTurn is one iteration of serveConn's request loop, expressed over
// the buffered byte stream so host tests drive it directly: peel the
// complete head, parse it (BEFORE rest replaces buf — the head aliases
// it), and route. ok=false means the head is incomplete; a nil rest with
// ok=true means the stream cannot be resynced (bad head) and the session
// must close after answering resp.
func serveTurn(buf []byte, readFile func(string) []byte) (req request, resp response, rest []byte, ok bool) {
	head, tail, ok := splitRequest(buf)
	if !ok {
		return request{}, response{}, nil, false
	}
	req, ok = parseRequest(head)
	if !ok {
		return request{}, badRequest(), nil, true
	}
	return req, route(req, readFile), tail, true
}

// route maps a parsed request to a response. readFile serves one canonical
// path under shareRoot (nil = absent); on the guest it is the host share
// reader, in tests a stub. Only GET and HEAD are served; every other
// method is 405.
func route(req request, readFile func(rel string) []byte) response {
	if req.Method != "GET" && req.Method != "HEAD" {
		return response{Status: 405, ContentType: "text/plain; charset=utf-8", Body: []byte("method not allowed\n")}
	}
	if req.Path == "" {
		return notFound() // a ".." target: refused, never opened
	}
	switch req.Path {
	case "/":
		return response{Status: 200, ContentType: "text/html; charset=utf-8", Body: indexBody()}
	case "/healthz":
		return response{Status: 200, ContentType: "application/json", Body: healthBody()}
	default:
		body := readFile(shareRoot + req.Path)
		if body == nil {
			return notFound()
		}
		return response{Status: 200, ContentType: mimeForPath(req.Path), Body: body}
	}
}

// formatResponse serialises a response. Content-Length always describes the
// entity, so a HEAD reply carries the length a GET would have produced.
// The Connection header answers the request's resolved keep-alive decision.
func formatResponse(r response, headOnly bool, keepAlive bool) []byte {
	text, ok := statusText[r.Status]
	if !ok {
		text = "Status"
	}
	var b []byte
	b = append(b, "HTTP/1.1 "...)
	b = append(b, strconv.Itoa(r.Status)...)
	b = append(b, ' ')
	b = append(b, text...)
	b = append(b, "\r\nServer: VirelaiOS\r\nContent-Type: "...)
	b = append(b, r.ContentType...)
	b = append(b, "\r\nContent-Length: "...)
	b = append(b, strconv.Itoa(len(r.Body))...)
	if keepAlive {
		b = append(b, "\r\nConnection: keep-alive\r\n\r\n"...)
	} else {
		b = append(b, "\r\nConnection: close\r\n\r\n"...)
	}
	if !headOnly {
		b = append(b, r.Body...)
	}
	return b
}
