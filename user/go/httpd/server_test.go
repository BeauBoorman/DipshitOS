package main

import (
	"bytes"
	"strconv"
	"strings"
	"testing"
)

func TestParseRequestAcceptsGetAndHead(t *testing.T) {
	for _, raw := range []string{
		"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
		"HEAD /healthz HTTP/1.1\r\n\r\n",
		"GET /HTTPD.TXT HTTP/1.0\n\n",
	} {
		req, ok := parseRequest([]byte(raw))
		if !ok {
			t.Fatalf("parseRequest(%q) refused a well-formed request", raw)
		}
		if !strings.HasPrefix(req.Path, "/") {
			t.Fatalf("parseRequest(%q) path = %q", raw, req.Path)
		}
	}
}

func TestParseRequestRefusals(t *testing.T) {
	cases := map[string]string{
		"unterminated headers":  "GET / HTTP/1.1\r\nHost: x\r\n",
		"no method":             " / HTTP/1.1\r\n\r\n",
		"no version":            "GET /\r\n\r\n",
		"http/2":                "GET / HTTP/2.0\r\n\r\n",
		"absolute-form target":  "GET http://example.com/ HTTP/1.1\r\n\r\n",
		"empty":                 "",
		"garbage":               "not a request at all\r\n\r\n",
		"missing space + ver":   "GET /\r\n\r\n",
		"version without slash": "GET / HTTP1.1\r\n\r\n",
		"declared body":         "POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc",
		"chunked body":          "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
	}
	for name, raw := range cases {
		if _, ok := parseRequest([]byte(raw)); ok {
			t.Errorf("%s: parseRequest(%q) accepted a bad request", name, raw)
		}
	}
}

func TestParseRequestConnectionSemantics(t *testing.T) {
	cases := []struct {
		raw       string
		keepAlive bool
	}{
		{"GET / HTTP/1.1\r\n\r\n", true},                       // 1.1 default
		{"GET / HTTP/1.1\r\nConnection: close\r\n\r\n", false}, // explicit close
		{"GET / HTTP/1.0\r\n\r\n", false},                      // 1.0 default
		{"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", true},
		{"GET / HTTP/1.1\r\nconnection: CLOSE\r\n\r\n", false}, // case-insensitive
		{"GET / HTTP/1.1\r\nConnection: upgrade, keep-alive\r\n\r\n", true},
	}
	for _, c := range cases {
		req, ok := parseRequest([]byte(c.raw))
		if !ok {
			t.Fatalf("parseRequest(%q) refused", c.raw)
		}
		if req.KeepAlive != c.keepAlive {
			t.Errorf("parseRequest(%q) keepAlive = %v, want %v", c.raw, req.KeepAlive, c.keepAlive)
		}
	}
}

func TestCanonicalPath(t *testing.T) {
	cases := []struct {
		target  string
		path    string
		blocked bool
	}{
		{"/", "/", false},
		{"/HTTPD.TXT", "/HTTPD.TXT", false},
		{"/a/b/c.txt", "/a/b/c.txt", false},
		{"//a//b", "/a/b", false},
		{"/a/./b", "/a/b", false},
		{"/x?y=1", "/x", false},
		{"/healthz?verbose", "/healthz", false},
		{"/../secret", "", true},
		{"/a/../../b", "", true},
		{"/..", "", true},
		{"/a/..", "", true},
	}
	for _, c := range cases {
		p, b := canonicalPath(c.target)
		if p != c.path || b != c.blocked {
			t.Errorf("canonicalPath(%q) = %q,%v want %q,%v", c.target, p, b, c.path, c.blocked)
		}
	}
}

func TestSplitRequestPipelined(t *testing.T) {
	blob := []byte("GET / HTTP/1.1\r\n\r\nGET /healthz HTTP/1.1\r\n\r\nGET /x")
	head, rest, ok := splitRequest(blob)
	if !ok {
		t.Fatal("first split refused a complete head")
	}
	if !bytes.HasPrefix(head, []byte("GET / ")) {
		t.Fatalf("first head = %q", head)
	}
	head, rest, ok = splitRequest(rest)
	if !ok {
		t.Fatal("second split refused a complete head")
	}
	if !bytes.Contains(head, []byte("GET /healthz")) {
		t.Fatalf("second head = %q", head)
	}
	if _, _, ok := splitRequest(rest); ok {
		t.Fatalf("incomplete tail %q split anyway", rest)
	}
}

// TestServeTurnPipelined drives the same split-then-parse-then-compact
// turn serveConn runs, over one segment carrying several requests: the
// head and the remainder must stay independent or the next request's
// bytes would overwrite the head before it is parsed (the aliasing bug
// the live gate caught — a pipelined GET answered 400).
func TestServeTurnPipelined(t *testing.T) {
	buf := []byte("GET / HTTP/1.1\n\nGET /NOPE.TXT HTTP/1.1\n\nHEAD /healthz HTTP/1.1\nConnection: close\n\n")
	want := []struct {
		method, target string
		status         int
		keepAlive      bool
	}{
		{"GET", "/", 200, true},
		{"GET", "/NOPE.TXT", 404, true},
		{"HEAD", "/healthz", 200, false},
	}
	for i, w := range want {
		req, resp, rest, ok := serveTurn(buf, func(string) []byte { return nil })
		if !ok {
			t.Fatalf("turn %d: no request peeled from %q", i, buf)
		}
		if req.Method != w.method || req.RawTarget != w.target || resp.Status != w.status {
			t.Fatalf("turn %d: %s %q -> %d, want %s %q -> %d",
				i, req.Method, req.RawTarget, resp.Status, w.method, w.target, w.status)
		}
		if req.KeepAlive != w.keepAlive {
			t.Fatalf("turn %d: keepAlive=%v want %v", i, req.KeepAlive, w.keepAlive)
		}
		buf = rest
	}
	if len(buf) != 0 {
		t.Fatalf("tail left: %q", buf)
	}
}

func TestServeTurnBadHead(t *testing.T) {
	_, resp, rest, ok := serveTurn([]byte("HELLO WORLD\n\n"), nil)
	if !ok || resp.Status != 400 || rest != nil {
		t.Fatalf("bad head: ok=%v status=%d rest=%q", ok, resp.Status, rest)
	}
}

func TestRouteSurfaces(t *testing.T) {
	files := map[string][]byte{"/host/HTTPD.TXT": []byte("share bytes\n")}
	read := func(rel string) []byte { return files[rel] }

	got := route(request{Method: "GET", Path: "/"}, read)
	if got.Status != 200 || !strings.Contains(string(got.Body), "VirelaiOS") {
		t.Fatalf("index: status=%d body=%q", got.Status, got.Body)
	}

	got = route(request{Method: "GET", Path: "/healthz"}, read)
	if got.Status != 200 || got.ContentType != "application/json" {
		t.Fatalf("healthz: status=%d type=%q", got.Status, got.ContentType)
	}
	if !bytes.Contains(got.Body, []byte("\"status\":\"ok\"")) {
		t.Fatalf("healthz body = %q", got.Body)
	}

	got = route(request{Method: "GET", Path: "/HTTPD.TXT"}, read)
	if got.Status != 200 || !bytes.Equal(got.Body, files["/host/HTTPD.TXT"]) {
		t.Fatalf("file present: status=%d body=%q", got.Status, got.Body)
	}
	if got.ContentType != "text/plain; charset=utf-8" {
		t.Fatalf("file mime = %q", got.ContentType)
	}

	got = route(request{Method: "GET", Path: "/ABSENT.TXT"}, read)
	if got.Status != 404 {
		t.Fatalf("absent file: status=%d", got.Status)
	}

	got = route(request{Method: "GET", Path: "/nope"}, read)
	if got.Status != 404 {
		t.Fatalf("unknown target: status=%d", got.Status)
	}

	got = route(request{Method: "POST", Path: "/"}, read)
	if got.Status != 405 {
		t.Fatalf("non-GET/HEAD: status=%d", got.Status)
	}
}

func TestRouteNeverReadsARequestedPath(t *testing.T) {
	// A traversal-shaped target never reaches the filesystem: blocked
	// paths carry Path == "" and 404 without a read, and every reachable
	// path is under shareRoot.
	read := func(rel string) []byte {
		if !strings.HasPrefix(rel, shareRoot+"/") {
			t.Errorf("route read outside shareRoot: %q", rel)
		}
		return nil
	}
	for _, raw := range []string{
		"GET /../HTTPD.TXT HTTP/1.1\r\n\r\n",
		"GET /a/../../b HTTP/1.1\r\n\r\n",
		"GET /%2e%2e/HTTPD.TXT HTTP/1.1\r\n\r\n",
		"GET /host/HTTPD.TXT HTTP/1.1\r\n\r\n",
	} {
		req, ok := parseRequest([]byte(raw))
		if !ok {
			t.Fatalf("parseRequest(%q) refused", raw)
		}
		if got := route(req, read); got.Status != 404 {
			t.Errorf("%q: status=%d, want 404", raw, got.Status)
		}
	}
}

func TestFormatResponse(t *testing.T) {
	resp := response{Status: 200, ContentType: "text/plain; charset=utf-8", Body: []byte("hello\n")}

	full := string(formatResponse(resp, false, false))
	for _, want := range []string{
		"HTTP/1.1 200 OK\r\n",
		"Server: VirelaiOS\r\n",
		"Content-Type: text/plain; charset=utf-8\r\n",
		"Content-Length: 6\r\n",
		"Connection: close\r\n\r\n",
	} {
		if !strings.Contains(full, want) {
			t.Errorf("full response missing %q:\n%s", want, full)
		}
	}
	if !strings.HasSuffix(full, "hello\n") {
		t.Errorf("full response lost the body: %q", full)
	}

	ka := string(formatResponse(resp, false, true))
	if !strings.Contains(ka, "Connection: keep-alive\r\n\r\n") {
		t.Errorf("keep-alive response carried the wrong Connection:\n%s", ka)
	}

	head := string(formatResponse(resp, true, false))
	if strings.Contains(head, "hello") {
		t.Errorf("HEAD response carried a body: %q", head)
	}
	if !strings.Contains(head, "Content-Length: 6\r\n") {
		t.Errorf("HEAD response lost the entity length: %q", head)
	}
}

func TestFormatResponseStatusText(t *testing.T) {
	for status, text := range statusText {
		line := string(formatResponse(response{Status: status}, true, false))
		want := "HTTP/1.1 " + strconv.Itoa(status) + " " + text + "\r\n"
		if !strings.HasPrefix(line, want) {
			t.Errorf("status %d: first line %.20q, want prefix %q", status, line, want)
		}
	}
}

func TestMimeForPath(t *testing.T) {
	cases := map[string]string{
		"/host/HTTPD.TXT": "text/plain; charset=utf-8",
		"/host/PAGE.HTML": "text/html; charset=utf-8",
		"/host/STYLE.CSS": "text/css; charset=utf-8",
		"/host/data.json": "application/json",
		"/host/img.png":   "image/png",
		"/host/img.qoi":   "image/qoi",
		"/host/logo.svg":  "image/svg+xml",
		"/host/noext":     "application/octet-stream",
		"/host/weird.bin": "application/octet-stream",
	}
	for path, want := range cases {
		if got := mimeForPath(path); got != want {
			t.Errorf("mimeForPath(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestAtoiPort(t *testing.T) {
	if p, ok := atoiPort("8080"); !ok || p != 8080 {
		t.Errorf("atoiPort(8080) = %d,%v", p, ok)
	}
	for _, bad := range []string{"", "0", "abc", "8080x", "99999", "-1"} {
		if _, ok := atoiPort(bad); ok {
			t.Errorf("atoiPort(%q) accepted a bad port", bad)
		}
	}
}

func TestParseArgsDefaults(t *testing.T) {
	cfg := parseArgs(nil)
	if cfg.port != defaultPort || cfg.tls {
		t.Errorf("parseArgs(nil) = %+v", cfg)
	}
	if got := parseArgs([]string{"--x", "9090"}); got.port != 9090 || got.tls {
		t.Errorf("parseArgs(--x 9090) = %+v", got)
	}
}

func TestParseArgsTLS(t *testing.T) {
	cfg := parseArgs([]string{"GOHTTPD.ELF", "--tls", "/host/T.CRT", "/host/T.KEY"})
	if !cfg.tls || cfg.certPath != "/host/T.CRT" || cfg.seedPath != "/host/T.KEY" || cfg.port != defaultTLSPort {
		t.Errorf("tls parse = %+v", cfg)
	}
	cfg = parseArgs([]string{"--tls", "c", "k", "9443"})
	if !cfg.tls || cfg.port != 9443 {
		t.Errorf("tls explicit port = %+v", cfg)
	}
	// A --tls without its two operands is refused, not half-read.
	cfg = parseArgs([]string{"--tls", "only-cert"})
	if cfg.tls {
		t.Errorf("incomplete --tls parsed as tls: %+v", cfg)
	}
}
