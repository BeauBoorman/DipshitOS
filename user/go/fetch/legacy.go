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
	"strings"

	"virelai/httpc"
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
	hostHeader := host
	if port != legacyDefaultPort {
		hostHeader = host + ":" + portString(port)
	}
	return httpc.GetRequest(hostHeader, path, "")
}

// errorName renders a vi/vsys error through its own Error() string (the
// errno type is unexported, so this is the stable name surface).
func errorName(err error) string {
	if err == nil {
		return "error"
	}
	return err.Error()
}

// responseStream is the M135b reader over httpc: one response per call —
// head through the terminator, then the body framed by Content-Length,
// chunked, or the peer's FIN, content-decoded (gzip) into body. reusable
// is the exchange's keep-alive verdict for the caller's conn pool.
type responseStream struct {
	head     []byte
	parsed   httpc.Head
	body     []byte
	reusable bool
}

var fetchPolicy = httpc.Policy{
	MaxHead:   headerLimit,
	MaxLine:   1024,
	MaxFields: 64,
	Cap:       vi.MaxFileBytes,
	WireSlack: 64 * 1024,
}

func newResponseStream(s connReader) (*responseStream, error) {
	r := &responseStream{}
	head, h, body, _, reusable, err := httpc.ReadResponse(s, fetchPolicy)
	if err != "" {
		return nil, errStr(err)
	}
	r.head, r.parsed, r.body, r.reusable = head, h, body, reusable
	return r, nil
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

// maxFetchRedirects bounds the redirect chain one invocation follows —
// the same honesty the browser's maxRedirects applies, so a redirect loop
// terminates as the last response, never a hang.
const maxFetchRedirects = 5

// isRedirectStatus mirrors the browser's followed-redirect subset.
func isRedirectStatus(code int) bool {
	return code == 301 || code == 302 || code == 303 || code == 307 || code == 308
}

// resolveFetchRedirect turns a Location value into the next cleartext
// request: absolute http:// IP-literal URLs, root-relative paths, and
// plain relative paths resolve; every other shape (https, a hostname,
// garbage) is not a fetchable target and yields ok=false.
func resolveFetchRedirect(cur clearRequest, location string) (clearRequest, bool) {
	loc := strings.TrimSpace(location)
	if loc == "" {
		return clearRequest{}, false
	}
	if strings.HasPrefix(strings.ToLower(loc), "http://") {
		return planClear(loc)
	}
	if strings.Contains(loc, "://") {
		return clearRequest{}, false
	}
	next := clearRequest{host: cur.host, ip: cur.ip, port: cur.port}
	if strings.HasPrefix(loc, "/") {
		next.path = loc
		return next, true
	}
	// Relative: resolve against the current path's directory.
	dir := cur.path
	if i := strings.LastIndexByte(dir, '/'); i >= 0 {
		dir = dir[:i+1]
	} else {
		dir = "/"
	}
	if strings.HasPrefix(dir, "/") && !strings.Contains(loc, "\r") && !strings.Contains(loc, "\n") {
		next.path = dir + loc
		return next, true
	}
	return clearRequest{}, false
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
	var s connStream
	open := false
	cur := req
	var rs *responseStream
	// The redirect loop: each hop reuses the live connection when the
	// origin is unchanged (keep-alive), else it closes and re-dials.
	for hops := 0; ; {
		if !open {
			var err error
			s, err = dialPlain(cur.host, cur.port)
			if err != nil {
				vi.ConsoleLine(prefix + ": connect failed " + errorName(err))
				vi.Exit(exitConnect)
			}
			vi.ConsoleLine(prefix + ": connected")
			open = true
		}
		if _, err := s.Write([]byte(requestString(cur.host, cur.port, cur.path))); err != nil {
			vi.ConsoleLine(prefix + ": send failed " + errorName(err))
			_ = s.Close()
			vi.Exit(exitSend)
		}
		vi.ConsoleLine(prefix + ": request sent")
		var err error
		rs, err = newResponseStream(s)
		if err != nil {
			vi.ConsoleLine(prefix + ": response failed " + err.Error())
			_ = s.Close()
			vi.Exit(exitSend)
		}
		loc := ""
		if isRedirectStatus(rs.parsed.Status) {
			loc = httpc.LocationHeader(rs.head)
		}
		next, follow := clearRequest{}, false
		if loc != "" {
			next, follow = resolveFetchRedirect(cur, loc)
		}
		if !follow || hops >= maxFetchRedirects {
			break
		}
		hops++
		vi.ConsoleLine(prefix + ": redirect " + vi.Itoa64(int64(hops)) + " " + loc)
		if !rs.reusable || next.host != cur.host || next.port != cur.port {
			_ = s.Close()
			open = false
			if !download && (next.host != cur.host || next.port != cur.port) {
				preflightClear(next)
			}
		}
		cur = next
	}
	_ = s.Close()
	if download {
		vi.ConsoleLine("download: status " + vi.Itoa64(int64(rs.parsed.Status)))
		vi.ConsoleLine("download: saving to file")
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
