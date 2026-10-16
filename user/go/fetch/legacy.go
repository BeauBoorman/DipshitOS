package main

// M78b (#1683): the Go successor to the retired Zig FETCH.BIN and
// DOWNLOAD.BIN. The windowed HTTPS path (https.go / target.go) is the M67b
// consumer and is unchanged here; this file adds the headless cleartext
// HTTP/1.0 mode those gates retarget onto:
//   - fetch:    `exec GOFETCH.ELF http://HOST[:PORT]/PATH` prints the old
//     `fetch:` markers, the header block before the body, and exits 42
//     (3 offline, 4 no route, 1 connect, 2 send) exactly as FETCH.BIN did.
//   - download: `exec GOFETCH.ELF --download [URL [DEST]]` saves the body
//     crash-safely to /host/DOWNLOAD.OUT and exits 0 (1 connect, 2 send,
//     3 file) with the old `download:` markers.
//
// The framing (head scan, status, Content-Length, body stream) is pure and
// host-tested; only Dial/Write/Read/Close touch the guest. vi.NetPreflight
// (the Go twin of user/src/lib/netstatus.zig) supplies the offline/no-route
// verdicts the Zig fetch used.

import (
	"bytes"
	"strings"

	"virelai/settings"
	"virelai/vi"
)

const (
	exitConnect = 1
	exitSend    = 2
	exitFile    = 3
	exitOffline = 3
	exitNoRoute = 4
	exitFetchOK = 42

	legacyDefaultHost = "10.0.0.2"
	legacyDefaultPort = 80
	legacyDefaultPath = "/"
	legacyDefaultDest = "/host/DOWNLOAD.OUT"

	// M100f (#2311): the default download target follows the data_root row —
	// /disk only when it opted in AND the volume mounted. `not_mounted` is
	// the kernel's named refusal for an absent VLFS mount (ADR 0050 D6).
	markerDataRoot         = "gofetch: data_root=/disk"
	markerDataRootFallback = "gofetch: data_root=disk but /disk not_mounted; using /host"

	// headerLimit is the old Zig fetch's header_scratch_max: once the head
	// reaches this without a terminator, refuse instead of growing a buffer.
	headerLimit = 1024
	readChunk   = 192
	// requestTimeoutNs bounds one cleartext request/response exchange; the
	// runner's TCP responder is local, and a dark peer fails closed instead
	// of parking the task for the socket's 30 s connect budget.
	requestTimeoutNs = 5_000_000_000
)

type errStr string

func (e errStr) Error() string { return string(e) }

// connStream adapts vi.Conn's Send/Recv/Close to the io-like shape. A peer
// FIN arrives as vi.ErrPeerGone and ends a close-delimited body; other
// errors (timeout, refused) fail closed.
type connStream struct{ c *vi.Conn }

func (s connStream) Write(p []byte) (int, error) { return s.c.Send(p) }
func (s connStream) Read(p []byte) (int, error)  { return s.c.Recv(p) }
func (s connStream) Close() error                { return s.c.Close() }

// connReader is the half of connStream the framing code needs; keeping it
// an interface lets the head/body split be host-tested without a socket.
type connReader interface {
	Read(p []byte) (int, error)
}

func dialPlain(host string, port uint16) (connStream, error) {
	c, err := vi.Dial(host, port)
	if err != nil {
		return connStream{}, err
	}
	c.SetRecvDeadline(requestTimeoutNs)
	return connStream{c: c}, nil
}

func requestString(host string, port uint16, path string) string {
	if path == "" {
		path = legacyDefaultPath
	}
	hostHeader := host
	if port != legacyDefaultPort {
		hostHeader = host + ":" + portString(port)
	}
	return "GET " + path + " HTTP/1.0\r\n" +
		"Host: " + hostHeader + "\r\n" +
		"User-Agent: VirelaiOS/1.0\r\n" +
		"Accept-Encoding: identity\r\n" +
		"Connection: close\r\n\r\n"
}

// errorName renders a vi/vsys error through its own Error() string (the
// errno type is unexported, so this is the stable name surface).
func errorName(err error) string {
	if err == nil {
		return "error"
	}
	return err.Error()
}

// responseStream frames one HTTP/1.0 response: the head through the bare
// CRLFCRLF, then the body. Content-Length (when present) bounds the body;
// otherwise the peer's FIN delimits it. The head is capped at headerLimit.
type responseStream struct {
	s      connReader
	head   []byte
	status int
	length int
	body   []byte
	buf    [readChunk]byte
}

func newResponseStream(s connReader) (*responseStream, error) {
	r := &responseStream{s: s}
	raw := make([]byte, 0, readChunk)
	for {
		n, err := s.Read(r.buf[:])
		if n > 0 {
			raw = append(raw, r.buf[:n]...)
			if i := bytes.Index(raw, []byte("\r\n\r\n")); i >= 0 {
				end := i + 4
				r.head = append([]byte(nil), raw[:end]...)
				r.body = append([]byte(nil), raw[end:]...)
				status, length, perr := parseResponseHead(r.head)
				if perr != nil {
					return nil, perr
				}
				r.status, r.length = status, length
				if r.length >= 0 && len(r.body) > r.length {
					r.body = r.body[:r.length]
				}
				return r, nil
			}
		}
		if len(raw) >= headerLimit {
			return nil, errStr("response headers exceed 1024 bytes")
		}
		if err != nil || n == 0 {
			return nil, errStr("malformed response: no header terminator")
		}
	}
}

func parseResponseHead(head []byte) (status int, length int, err error) {
	status = -1
	length = -1
	end := bytes.IndexByte(head, '\n')
	if end < 0 {
		return 0, 0, errStr("malformed status line")
	}
	line := strings.TrimSuffix(string(head[:end]), "\r")
	fields := strings.Fields(line)
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "HTTP/") {
		return 0, 0, errStr("malformed status line")
	}
	status = 0
	digits := 0
	for i := 0; i < len(fields[1]); i++ {
		c := fields[1][i]
		if c < '0' || c > '9' || digits == 3 || status > 999 {
			return 0, 0, errStr("malformed status code")
		}
		status = status*10 + int(c-'0')
		digits++
	}
	if digits != 3 || status < 100 {
		return 0, 0, errStr("malformed status code")
	}
	for _, h := range strings.Split(string(head), "\r\n")[1:] {
		i := strings.IndexByte(h, ':')
		if i < 0 {
			continue
		}
		name := strings.TrimSpace(h[:i])
		v := strings.TrimSpace(h[i+1:])
		switch {
		// M97f (#2106): the cleartext path enforces the same framing
		// contract browser/framing.go declares — a peer insisting on
		// chunked or compressed transfer is refused, never misparsed.
		case strings.EqualFold(name, "transfer-encoding"):
			return 0, 0, errStr("http-framing-unsupported")
		case strings.EqualFold(name, "content-encoding"):
			if !strings.EqualFold(v, "identity") {
				return 0, 0, errStr("http-framing-unsupported")
			}
		case strings.EqualFold(name, "content-length"):
			// A second Content-Length — matching or not — is a framing
			// desync; there is no "last wins" rule here.
			if length >= 0 || v == "" {
				return 0, 0, errStr("http-framing-invalid")
			}
			n := 0
			for j := 0; j < len(v); j++ {
				c := v[j]
				if c < '0' || c > '9' || n > (1<<31-1)/10 {
					return 0, 0, errStr("malformed content-length")
				}
				n = n*10 + int(c-'0')
			}
			length = n
		}
	}
	return status, length, nil
}

// readBody drains the response body into r.body, bounded by Content-Length
// when present and by vi.MaxFileBytes (the guest's file-cap, as the browser
// and RSS fetchers use) otherwise. This consumer is a console fetch and a
// one-shot download, not a streaming proxy.
func (r *responseStream) readBody() error {
	for {
		if r.length >= 0 && len(r.body) >= r.length {
			r.body = r.body[:r.length]
			return nil
		}
		if len(r.body) >= vi.MaxFileBytes {
			return errStr("response body exceeds the 256 KiB cap")
		}
		n, err := r.s.Read(r.buf[:])
		if n > 0 {
			chunk := r.buf[:n]
			if r.length >= 0 && len(r.body)+len(chunk) > r.length {
				chunk = chunk[:r.length-len(r.body)]
			}
			if len(r.body)+len(chunk) > vi.MaxFileBytes {
				chunk = chunk[:vi.MaxFileBytes-len(r.body)]
			}
			r.body = append(r.body, chunk...)
		}
		if r.length >= 0 && len(r.body) >= r.length {
			r.body = r.body[:r.length]
			return nil
		}
		if err != nil || n == 0 {
			if r.length >= 0 {
				return errStr("response ended before content-length")
			}
			return nil
		}
	}
}

type legacyArgs struct {
	url      string
	dest     string
	download bool
	help     bool
	usage    bool
}

func usageText() string {
	return "fetch: usage: exec GOFETCH.ELF [--download] [http://HOST[:PORT]/PATH [DEST]]\n" +
		"fetch:   HTTP fetch; prints headers then body; exits " + vi.Itoa64(exitFetchOK) + " (3 offline, 4 no route)\n" +
		"download: --download saves the body to " + legacyDefaultDest + " (or DEST) and exits 0\n" +
		"fetch: default URL: http://" + legacyDefaultHost + "/"
}

func parseLegacyArgs(args []string) (legacyArgs, bool) {
	var a legacyArgs
	positional := make([]string, 0, 2)
	for _, arg := range args[1:] {
		switch {
		case arg == "-h" || arg == "--help":
			a.help = true
		case arg == "--download" || arg == "-d":
			a.download = true
		case strings.HasPrefix(arg, "-"):
			a.usage = true
		default:
			positional = append(positional, arg)
		}
	}
	if a.help {
		return a, true
	}
	// An unknown flag is a usage error on either path (the TLS consumer
	// takes no flags at all), so it never falls through to the window.
	if a.usage {
		return a, true
	}
	if len(positional) > 0 {
		a.url = positional[0]
	}
	if len(positional) > 1 {
		a.dest = positional[1]
	}
	// An explicit http:// URL (or --download) is the legacy shape; https://,
	// a hostname, or no URL at all stays with the TLS consumer. The TLS
	// consumer's own shape is `https://HOST[:PORT]/ [sni [name|expired|chain]]`
	// — up to three positionals — so an https URL claims this path FIRST and
	// the [URL [DEST]] bound only applies to the cleartext branch below.
	if !a.download && !isCleartextURL(a.url) {
		return a, false
	}
	// More than [URL [DEST]] positionals on the cleartext path is a misuse
	// (e.g. an https URL plus its SNI/expect-fail rows), not a legacy fetch.
	if len(positional) > 2 {
		a.usage = true
		return a, true
	}
	if a.url == "" {
		a.url = "http://" + legacyDefaultHost + "/"
	}
	if a.download && a.dest == "" {
		a.dest = legacyDownloadDest()
	}
	return a, true
}

// fetchDataRoot is the M100f (#2311) resolver seam — a var so a host test
// pins the disk and fallback legs without a settings file.
var fetchDataRoot = func() (string, bool) {
	return settings.Load().ResolveDataRoot()
}

// legacyDownloadDest resolves the no-DEST download target for this boot:
// the resolved data root plus the file name. It names the resolution on the
// console exactly when the row opted in — silent on the default boot, which
// is the whole point of opt-in.
func legacyDownloadDest() string {
	root, fellBack := fetchDataRoot()
	if root == "" {
		root = settings.DataRootHost
	}
	switch {
	case fellBack:
		vi.ConsoleLine(markerDataRootFallback)
	case root == settings.DataRootDisk:
		vi.ConsoleLine(markerDataRoot)
	}
	return root + "/DOWNLOAD.OUT"
}

func isCleartextURL(raw string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(raw)), "http://")
}

type clearRequest struct {
	host string
	ip   [4]byte
	port uint16
	path string
}

// planClear classifies an explicit http:// URL (or a scheme-less IPv4
// literal/path, as the retired Zig downloader accepted) into a cleartext
// request. Hostnames and every other scheme are refused — the preflight
// needs an IP literal, and the legacy paths were IP-literal-only.
func planClear(raw string) (clearRequest, bool) {
	rest := strings.TrimSpace(raw)
	if rest == "" {
		rest = "http://" + legacyDefaultHost + "/"
	}
	if !isCleartextURL(rest) {
		if strings.Contains(rest, "://") {
			return clearRequest{}, false
		}
		rest = "http://" + rest
	}
	t := Classify(rest)
	plan, ok := PlanClear(t)
	if !ok {
		return clearRequest{}, false
	}
	return clearRequest{host: plan.Addr, ip: t.IPv4, port: plan.Port, path: plan.Path}, true
}

func preflightClear(req clearRequest) {
	switch verdict, _ := vi.NetPreflight(req.ip); verdict {
	case vi.NetOfflineNoIP:
		vi.Console(vi.NetDiagnosisMessage("fetch", verdict, req.ip))
		vi.Exit(exitOffline)
	case vi.NetNoRoute:
		vi.Console(vi.NetDiagnosisMessage("fetch", verdict, req.ip))
		vi.Exit(exitNoRoute)
	}
}

func runLegacyCLI(args []string) {
	a, _ := parseLegacyArgs(args)
	if a.help || a.usage {
		vi.Console(usageText())
		if a.help {
			vi.Exit(0)
		}
		vi.Exit(exitConnect)
	}
	req, valid := planClear(a.url)
	if !valid {
		vi.Console("fetch: invalid URL " + a.url + "\n")
		vi.Exit(exitConnect)
	}
	if a.dest != "" && !strings.HasPrefix(a.dest, "/") {
		a.dest = "/host/" + a.dest
	}
	runPlain(req, a.download, a.dest)
}

func runPlain(req clearRequest, download bool, dest string) {
	prefix := "fetch"
	if download {
		prefix = "download"
	}
	vi.ConsoleLine(prefix + ": starting")
	if !download {
		preflightClear(req)
	}
	s, err := dialPlain(req.host, req.port)
	if err != nil {
		vi.ConsoleLine(prefix + ": connect failed " + errorName(err))
		vi.Exit(exitConnect)
	}
	vi.ConsoleLine(prefix + ": connected")
	if _, err := s.Write([]byte(requestString(req.host, req.port, req.path))); err != nil {
		vi.ConsoleLine(prefix + ": send failed " + errorName(err))
		_ = s.Close()
		vi.Exit(exitSend)
	}
	vi.ConsoleLine(prefix + ": request sent")
	rs, err := newResponseStream(s)
	if err != nil {
		vi.ConsoleLine(prefix + ": response failed " + err.Error())
		_ = s.Close()
		vi.Exit(exitSend)
	}
	if download {
		vi.ConsoleLine("download: status " + vi.Itoa64(int64(rs.status)))
		vi.ConsoleLine("download: saving to file")
	}
	if err := rs.readBody(); err != nil {
		vi.ConsoleLine(prefix + ": body failed " + err.Error())
		_ = s.Close()
		vi.Exit(exitSend)
	}
	_ = s.Close()
	if download {
		// WriteFileSafe: temp -> write-all -> fsync -> publish. A failed
		// save leaves no partial DOWNLOAD.OUT (absent, not garbage).
		if rc := vi.WriteFileSafe(dest, rs.body); rc < 0 {
			vi.ConsoleLine("download: file write failed " + vi.ErrnoName(rc))
			vi.Exit(exitFile)
		}
		vi.ConsoleLine("download: file opened")
		vi.ConsoleLine("download: received " + vi.Itoa64(int64(len(rs.body))) + " bytes")
		vi.ConsoleLine("download: complete")
		vi.Exit(0)
	}
	vi.ConsoleLine("fetch: headers")
	vi.Console("--- response headers ---\n")
	vi.Console(string(rs.head))
	vi.Console("--- response body ---\n")
	vi.ConsoleLine("fetch: body")
	vi.Console(string(rs.body))
	vi.ConsoleLine("fetch: done")
	vi.Exit(exitFetchOK)
}
