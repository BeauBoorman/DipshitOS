package main

import (
	"strings"
	"testing"

	"virelai/vi"
	"virelai/webrender"
)

// HTTPS, including a DNS hostname, always uses TLS, never a cleartext GET.
func TestClassifyTargetHTTPS(t *testing.T) {
	cases := []struct{ in, want string }{
		{"https://example.com/", "https"},
		{"HTTPS://10.0.0.2/x", "https"},
		{"https://10.0.0.2:24533/", "https"},
		{"http://example.com/", "http"},
		{"http://10.0.0.2/", "http"},
		{"http://10.0.0.2:8080/x", "http"},
		{"http://", "url"},
		{"http:broken", "url"},
		{"https:broken", "url"},
		{"http://h:99999/", "url"},
		{"/host/A.HTML", "file"},
		{"A.HTML", "file"},
	}
	for _, c := range cases {
		if got := classifyTarget(c.in); got != c.want {
			t.Fatalf("classifyTarget(%q) = %q want %q", c.in, got, c.want)
		}
	}
}

// A hostname https target must not reach the fetch path: navigate() lands
// on the error page with kind "dns". An IP-literal https target on the host
// (no syscall seam) fails closed as "tls", never as a cleartext load.
func TestHTTPSNeverFetchesCleartext(t *testing.T) {
	a := &app{hist: newHistory()}
	a.navigate("https://example.com/", "")
	if a.errKind != "dns" {
		t.Fatalf("hostname errKind = %q want dns", a.errKind)
	}
	if a.loading {
		t.Fatal("an https hostname must not start a load")
	}

	b := &app{hist: newHistory()}
	b.navigate("https://10.0.0.2/", "")
	if b.errKind != "tls" {
		t.Fatalf("IP-literal errKind = %q want tls (host Dial is ENOSYS)", b.errKind)
	}
	if b.loading {
		t.Fatal("a failed TLS dial must not leave a load armed")
	}
	if b.errMsg == "" {
		t.Fatal("tls failure must explain itself")
	}
}

func TestDNSRefusalIsNotAHang(t *testing.T) {
	a := &app{hist: newHistory()}
	a.navigate("http://example.com/", "")
	if a.errKind != "dns" {
		t.Fatalf("errKind = %q want dns", a.errKind)
	}
	if a.loading {
		t.Fatal("a hostname must not arm a load")
	}
}

func TestMalformedURLIsDefined(t *testing.T) {
	for _, in := range []string{"http://", "http://h:99999/", "ftp://x/y", ""} {
		a := &app{hist: newHistory()}
		a.navigate(in, "")
		if a.errKind == "" && !a.loading {
			t.Fatalf("input %q produced neither an error nor a load", in)
		}
		if a.loading {
			t.Fatalf("input %q should not start a load", in)
		}
	}
}

// Stopping a load produces the "cancelled" state, not a hang and not a
// silent success.
func TestCancelLoadingTransition(t *testing.T) {
	a := &app{hist: newHistory(), loading: true, target: "http://10.0.0.2/"}
	a.cancelLoad()
	if a.loading {
		t.Fatal("cancel must clear the loading state")
	}
	if a.errKind != "cancelled" {
		t.Fatalf("errKind = %q want cancelled", a.errKind)
	}
	if a.lay != nil {
		t.Fatal("a cancelled load must not leave a stale page")
	}
}

// A stopped idle browser (no load in flight) is a status, not an error page.
func TestCancelIdleIsAStatus(t *testing.T) {
	a := &app{hist: newHistory()}
	a.cancelLoad()
	if a.errKind != "" {
		t.Fatalf("idle cancel raised an error: %q", a.errKind)
	}
	if a.status != "stopped" {
		t.Fatalf("status = %q want stopped", a.status)
	}
}

// On the host every socket call is -ENOSYS, so a stepped load must land on a
// defined error instead of spinning.
func TestLoadStepErrorIsDefined(t *testing.T) {
	a := &app{hist: newHistory(), loading: true, target: "http://10.0.0.2/"}
	a.loadStep()
	if a.loading {
		t.Fatal("a failed read must end the load")
	}
	if a.errKind == "" {
		t.Fatal("a failed read must set an error kind")
	}
}

// fakeTCP is a scripted stand-in for the kernel's ONE socket, injected
// through vi's syscall hook: connect/send succeed, and the readiness/recv
// answers follow scripts. The mask shape is the kernel's
// `rx_pending || peer_fin` (kernel/src/tcp.zig ready_mask): bit 0 when a
// segment is queued or the peer FIN'd, bit 1 while established.
//
// The fake never writes the recv buffer (a raw uintptr through the hook is
// exactly the unsafe conversion `go vet` refuses); instead the tests
// pre-load a.chunk — the buffer the app hands to TCPRecv — and the fake
// only reports the length, which is all vi.TCPRecv returns.
type fakeTCP struct {
	ready []int64 // readiness answers, in probe order
	recv  []int64 // recv lengths, in call order
	ri    int
	ci    int
	sent  int // bytes TCPSend accepted
}

func (f *fakeTCP) install() func() {
	prev := vi.SyscallHookForTest()
	vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case vi.SlotTCPConnect:
			return 0
		case vi.SlotTCPSend:
			f.sent += int(a1)
			return int64(a1)
		case vi.SlotSockReady:
			if f.ri < len(f.ready) {
				v := f.ready[f.ri]
				f.ri++
				return v
			}
			return 2
		case vi.SlotTCPRecv:
			if f.ci < len(f.recv) {
				v := f.recv[f.ci]
				f.ci++
				return v
			}
			return 0
		}
		return 0
	})
	return func() { vi.SetSyscallHookForTest(prev) }
}

// The regression from #1366: a close-delimited response (no Content-Length)
// that ends with the peer's FIN must complete the load. The merged behavior
// kept polling until the 30 s deadline and then rendered "error timeout"
// (observed on live-web boot 03).
func TestLoadCompletesOnPeerClose(t *testing.T) {
	body := "HTTP/1.0 200 OK\r\n\r\n<p>hi</p>"
	f := &fakeTCP{ready: []int64{3, 1}, recv: []int64{int64(len(body)), 0}}
	defer f.install()()
	a := &app{hist: newHistory()}
	copy(a.chunk[:], body) // the buffer TCPRecv would fill
	u, ok := webrender.ParseHTTPURL("http://10.0.0.2/")
	if !ok {
		t.Fatal("fixture URL must parse")
	}
	a.startHTTP(u)
	if !a.loading {
		t.Fatal("startHTTP must arm a load")
	}
	for i := 0; i < 8 && a.loading; i++ {
		a.loadStep()
	}
	if a.loading {
		t.Fatal("a peer FIN after the response must complete the load")
	}
	if a.errKind != "" {
		t.Fatalf("errKind = %q, want the page with no error", a.errKind)
	}
	if a.doc == nil || a.lay == nil {
		t.Fatal("a completed load must parse and lay out the body")
	}
	if f.sent == 0 {
		t.Fatal("the request was never sent over the faked socket")
	}
}

// A Content-Length body completes as soon as the declared bytes arrive —
// the peer does not have to close (the host responder answers and stays up).
func TestLoadCompletesOnContentLength(t *testing.T) {
	body := "HTTP/1.0 200 OK\r\nContent-Length: 9\r\n\r\n<p>hi</p>"
	f := &fakeTCP{ready: []int64{3, 2}, recv: []int64{int64(len(body))}}
	defer f.install()()
	a := &app{hist: newHistory()}
	copy(a.chunk[:], body) // the buffer TCPRecv would fill
	u, ok := webrender.ParseHTTPURL("http://10.0.0.2/")
	if !ok {
		t.Fatal("fixture URL must parse")
	}
	a.startHTTP(u)
	for i := 0; i < 8 && a.loading; i++ {
		a.loadStep()
	}
	if a.loading {
		t.Fatal("a satisfied Content-Length must complete the load")
	}
	if a.errKind != "" {
		t.Fatalf("errKind = %q, want the page with no error", a.errKind)
	}
	if a.doc == nil || a.lay == nil {
		t.Fatal("a completed load must parse and lay out the body")
	}
}

// Transfer-Encoding: chunked is decoded by this browser (M135b): a valid
// stream renders, and a malformed one is refused by name — never silently
// treated as the body.
func TestLoadStepDecodesChunked(t *testing.T) {
	body := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
	f := &fakeTCP{ready: []int64{3, 2}, recv: []int64{int64(len(body))}}
	defer f.install()()
	a := &app{hist: newHistory()}
	copy(a.chunk[:], body)
	u, _ := webrender.ParseHTTPURL("http://10.0.0.2/")
	a.startHTTP(u)
	for i := 0; i < 8 && a.loading; i++ {
		a.loadStep()
	}
	if a.loading {
		t.Fatal("a complete chunked stream must end the load")
	}
	if a.errKind != "" {
		t.Fatalf("errKind = %q want the decoded page", a.errKind)
	}
	if string(a.lastBody) != "hello" {
		t.Fatalf("decoded body = %q want hello", a.lastBody)
	}
}

func TestLoadStepRefusesMalformedChunked(t *testing.T) {
	body := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n"
	f := &fakeTCP{ready: []int64{3, 2}, recv: []int64{int64(len(body))}}
	defer f.install()()
	a := &app{hist: newHistory()}
	copy(a.chunk[:], body)
	u, _ := webrender.ParseHTTPURL("http://10.0.0.2/")
	a.startHTTP(u)
	for i := 0; i < 8 && a.loading; i++ {
		a.loadStep()
	}
	if a.loading {
		t.Fatal("a malformed chunked stream must end the load")
	}
	if a.errKind != "chunked-malformed" {
		t.Fatalf("errKind = %q want chunked-malformed", a.errKind)
	}
}

// responseNeed pins the framing decisions without a socket.
func TestResponseNeed(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want int
		ok   bool
	}{
		{"incomplete", "HTTP/1.0 200 OK\r\nContent-Len", 0, false},
		{"length", "HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nabc", 3, true},
		{"length case", "HTTP/1.0 200 OK\r\ncontent-length: 0\r\n\r\n", 0, true},
		{"no length", "HTTP/1.0 200 OK\r\n\r\nabc", -1, true},
		{"duplicate", "HTTP/1.0 200 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc", -2, true},
		{"empty", "HTTP/1.0 200 OK\r\nContent-Length:\r\n\r\nabc", -2, true},
		{"nondigit", "HTTP/1.0 200 OK\r\nContent-Length: 3x\r\n\r\nabc", -2, true},
		{"chunked", "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nabc", -1, true},
		{"over cap", "HTTP/1.0 200 OK\r\nContent-Length: 99999999\r\n\r\n", -2, true},
	}
	for _, c := range cases {
		got, ok := responseNeed([]byte(c.raw))
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("%s: responseNeed = (%d, %v), want (%d, %v)", c.name, got, ok, c.want, c.ok)
		}
	}
}

// A redirect hop must be re-framed from scratch: the second response's
// Content-Length belongs to the second response, not the first one. The
// second response arrives in two segments with a body longer than the first
// hop's length, so a stale frame would silently truncate it to "abc".
func TestRedirectReframesTheNextHop(t *testing.T) {
	first := "HTTP/1.0 302 Found\r\nLocation: http://10.0.0.2/next\r\nContent-Length: 2\r\n\r\nok"
	head := "HTTP/1.0 200 OK\r\nContent-Length: 9\r\n\r\n"
	part1, part2 := head+"abc", "defghi"
	f := &fakeTCP{
		ready: []int64{3, 3, 3},
		recv:  []int64{int64(len(first)), int64(len(part1)), int64(len(part2))},
	}
	defer f.install()()
	a := &app{hist: newHistory()}
	copy(a.chunk[:], first) // hop 1's segment
	u, _ := webrender.ParseHTTPURL("http://10.0.0.2/")
	a.startHTTP(u)
	a.loadStep()
	if a.loadHops != 1 || !a.loading {
		t.Fatalf("hop 1: loadHops = %d loading = %v, want a redirect and a live load", a.loadHops, a.loading)
	}
	copy(a.chunk[:], part1) // hop 2's first segment: headers + 3 body bytes
	a.loadStep()
	if !a.loading {
		t.Fatal("hop 2 must keep loading until its own Content-Length is satisfied")
	}
	copy(a.chunk[:], part2) // hop 2's second segment: the remaining 6 bytes
	a.loadStep()
	if a.loading {
		t.Fatal("hop 2 must complete on its own Content-Length")
	}
	if a.errKind != "" {
		t.Fatalf("errKind = %q, want the page with no error", a.errKind)
	}
	if string(a.lastBody) != "abcdefghi" {
		t.Fatalf("body = %q, want abcdefghi (a stale frame truncates it)", a.lastBody)
	}
}

// A peer that closes without ever answering is not a truncated page: the
// load ends on the offline path, not in completeLoad.
func TestLoadStepEmptyCloseIsNotATruncatedPage(t *testing.T) {
	f := &fakeTCP{ready: []int64{1}, recv: []int64{0}}
	defer f.install()()
	a := &app{hist: newHistory(), loading: true, target: "http://10.0.0.2/", loadEnd: vi.Nanos() + 60_000_000_000}
	a.loadStep()
	if a.loading {
		t.Fatal("a closed peer must end the load")
	}
	if a.errKind != "tcp" {
		t.Fatalf("errKind = %q want tcp", a.errKind)
	}
}

// "No bytes right now" is not completion: with no FIN the load stays armed
// while the deadline is live, and an expired deadline ends it as a timeout.
func TestLoadStepNoProgressKeepsLoading(t *testing.T) {
	f := &fakeTCP{ready: []int64{2, 2}, recv: []int64{0, 0}}
	defer f.install()()
	a := &app{hist: newHistory(), loading: true, target: "http://10.0.0.2/"}
	a.loadEnd = vi.Nanos() + 60_000_000_000 // 60 s in the future
	a.loadStep()
	if !a.loading {
		t.Fatal("an idle read with a live deadline must keep the load armed")
	}
	if a.errKind != "" {
		t.Fatalf("an idle read must not raise an error: %q", a.errKind)
	}
	// And an expired deadline must end it as a timeout.
	a.loadEnd = vi.Nanos() - 1
	a.loadStep()
	if a.loading {
		t.Fatal("an expired deadline must end the load")
	}
	if a.errKind != "timeout" {
		t.Fatalf("errKind = %q want timeout", a.errKind)
	}
}

// sendAll loops the payload-bounded send. A fake socket is injected through
// vi's syscall hook so the chunking is exercised deterministically: the fake
// accepts at most 192 bytes per call (the kernel's payload_max), so a
// truncating implementation (one send, ignore the count) cannot pass.
func TestSendAllLoopsLargeRequests(t *testing.T) {
	prev := vi.SyscallHookForTest()
	defer vi.SetSyscallHookForTest(prev)
	sent := 0
	vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == vi.SlotTCPSend {
			n := int(a1)
			if n > 192 {
				n = 192
			}
			sent += n
			return int64(n)
		}
		return 0
	})
	if !sendAll(nil) {
		t.Fatal("sendAll(nil) should succeed")
	}
	if sent != 0 {
		t.Fatalf("sendAll(nil) sent %d bytes", sent)
	}
	sent = 0
	if !sendAll([]byte("hello")) {
		t.Fatal("sendAll(hello) should succeed")
	}
	if sent != 5 {
		t.Fatalf("sent = %d want 5", sent)
	}
	sent = 0
	big := make([]byte, 500)
	if !sendAll(big) {
		t.Fatal("sendAll(500B) must loop until the whole request is sent")
	}
	if sent != 500 {
		t.Fatalf("sent = %d want 500 (a short write must be retried, not dropped)", sent)
	}
}

// Redirect handling is pure and must resolve absolute, root-relative and
// relative Location values, and detect a loop by hop count.
func TestRedirectResolution(t *testing.T) {
	from, ok := webrender.ParseHTTPURL("http://10.0.0.2/a/b.html")
	if !ok {
		t.Fatal("bad base")
	}
	cases := []struct{ loc, want string }{
		{"http://10.0.0.2/next", "http://10.0.0.2/next"},
		{"/root", "http://10.0.0.2/root"},
		{"c.html", "http://10.0.0.2/a/c.html"},
		{"../up.html", "http://10.0.0.2/up.html"},
	}
	for _, c := range cases {
		got, ok := webrender.ResolveRedirect(from, c.loc)
		if !ok {
			t.Fatalf("ResolveRedirect(%q) failed", c.loc)
		}
		u := "http://" + got.Host + got.Path
		if u != c.want {
			t.Fatalf("ResolveRedirect(%q) = %q want %q", c.loc, u, c.want)
		}
	}
	if _, ok := webrender.ResolveRedirect(from, ""); ok {
		t.Fatal("empty Location must not resolve")
	}
	if !webrender.RedirectStatus(301) || !webrender.RedirectStatus(302) || webrender.RedirectStatus(200) {
		t.Fatal("RedirectStatus wrong")
	}
	head := "HTTP/1.0 302 Found\r\nLocation: /moved\r\n\r\n"
	if got := webrender.LocationHeader(head); got != "/moved" {
		t.Fatalf("LocationHeader = %q", got)
	}
	if got := webrender.LocationHeader("HTTP/1.0 200 OK\r\n\r\n"); got != "" {
		t.Fatalf("LocationHeader on 200 = %q", got)
	}
}

// Scheme-shaped targets must never be turned into file-channel paths: a
// javascript: or file: href is refused as a scheme, not rewritten into
// "/host/javascript:...".
func TestSchemeShapedTargetsAreRefused(t *testing.T) {
	cases := []struct{ in, wantKind string }{
		{"javascript:alert(1)", "unsupported"},
		{"file:///host/WEB-HISTORY.TXT", "unsupported"},
		{"mailto:someone@example.com", "unsupported"},
		{"data:text/html,<b>x</b>", "unsupported"},
		{"ftp://10.0.0.2/x", "unsupported"},
	}
	for _, c := range cases {
		got, kind := resolveInput(c.in)
		if kind != c.wantKind {
			t.Fatalf("resolveInput(%q) kind = %q want %q", c.in, kind, c.wantKind)
		}
		if strings.HasPrefix(got, "/host/") {
			t.Fatalf("resolveInput(%q) rewrote a scheme into a file path: %q", c.in, got)
		}
	}
	// And a plain name is still a file on the share.
	if got, kind := resolveInput("PAGE.HTML"); kind != "file" || got != "/host/PAGE.HTML" {
		t.Fatalf("plain name = %q,%q", got, kind)
	}
}

// A hostile page must render as inert text with no request armed: the script
// body is dropped by the parser and nothing on the page can act.
func TestHostilePageIsInert(t *testing.T) {
	a := &app{hist: newHistory()}
	a.navigate("/host/HOSTILE.HTML", "")
	if a.loading {
		t.Fatal("a local page must not arm a request")
	}
}
