package main

import (
	"strings"
	"testing"

	"virelai/vi"
	"virelai/webrender"
)

func TestRequestAuthorityAndIdentityFraming(t *testing.T) {
	u, ok := parseBrowserURL("https://Example.COM:8443/a?x=1")
	if !ok {
		t.Fatal("URL rejected")
	}
	got := formatPageRequest(u, "a=b")
	want := "GET /a?x=1 HTTP/1.1\r\nHost: example.com:8443\r\nUser-Agent: VirelaiOS/1.0\r\nCookie: a=b\r\nConnection: keep-alive\r\nAccept-Encoding: gzip\r\n\r\n"
	if got != want {
		t.Fatalf("request=%q want=%q", got, want)
	}
	if strings.Contains(formatPageRequest(u, "x\r\nInjected: yes"), "Injected") {
		t.Fatal("cookie ledger injected a header")
	}
}

func TestBoundedRecordedHTTPFrames(t *testing.T) {
	for _, tc := range []struct {
		name, response, error string
	}{
		{"length", "HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nabc", ""},
		{"EOF", "HTTP/1.1 200 OK\n\nabc", ""},
		{"chunked", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "chunked-malformed"},
		{"gzip", "HTTP/1.0 200 OK\r\nContent-Encoding: gzip\r\n\r\n", "gzip-malformed"},
		{"te nonchunked", "HTTP/1.1 200 OK\r\nTransfer-Encoding: deflate\r\n\r\n", "http-framing-unsupported"},
		{"ce br", "HTTP/1.0 200 OK\r\nContent-Encoding: br\r\n\r\n", "http-framing-unsupported"},
		{"te+cl", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n", "http-framing-invalid"},
		{"length conflict", "HTTP/1.0 200 OK\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n", "http-framing-invalid"},
		{"bogus length", "HTTP/1.0 200 OK\r\nContent-Length: -1\r\n\r\n", "http-framing-invalid"},
		{"short", "HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nabc", "http-premature-eof"},
		{"fold", "HTTP/1.0 200 OK\r\n folded\r\n\r\n", "http-framing-invalid"},
		{"bad field token", "HTTP/1.0 200 OK\r\nX(bad): y\r\n\r\n", "http-framing-invalid"},
		{"bad status token", "HTTP/1.0 200oops\r\n\r\n", "http-framing-invalid"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := parseResponseFrame([]byte(tc.response))
			_, _, err := responseBody(f, []byte(tc.response), 100, true)
			if err != tc.error {
				t.Fatalf("frame error=%q want=%q", err, tc.error)
			}
		})
	}
	for _, raw := range []string{
		"HTTP/1.0 200 OK\r\nX: " + strings.Repeat("x", maxHTTPLine) + "\r\n\r\n",
		"HTTP/1.0 200 OK\r\n" + strings.Repeat("X: y\r\n", maxHTTPFields+1) + "\r\n",
		strings.Repeat("x", maxHTTPHeaders+1),
	} {
		if f := parseResponseFrame([]byte(raw)); f.err == "" {
			t.Fatal("header bound accepted")
		}
	}
}

func TestBrowserURLAndRedirectPolicy(t *testing.T) {
	for _, raw := range []string{"https://u@h/", "https://[::1]/", "http://h:0/", "http://h/\r\nX: y", "http://h/a b"} {
		if _, ok := parseBrowserURL(raw); ok {
			t.Fatalf("unsafe URL accepted: %q", raw)
		}
	}
	from, _ := parseBrowserURL("https://h:8443/a/b?old=1")
	for _, tc := range []struct{ ref, want string }{
		{"/c", "https://h:8443/c"},
		{"../c", "https://h:8443/c"},
		{"?q=x", "https://h:8443/a/b?q=x"},
		{"#x", "https://h:8443/a/b?old=1#x"},
		{"//other/x", "https://other/x"},
	} {
		if got := resolveReference(formatNavURL(from), tc.ref); got != tc.want {
			t.Fatalf("ref=%q got=%q want=%q", tc.ref, got, tc.want)
		}
	}
	if _, kind := redirectTarget(from, "http://h/"); kind != "redirect-downgrade" {
		t.Fatalf("downgrade=%q", kind)
	}
	if _, kind := redirectTarget(from, "javascript:run"); kind != "redirect-location" {
		t.Fatalf("unsupported redirect=%q", kind)
	}
	if isPageRedirect(304) || !isPageRedirect(308) {
		t.Fatal("redirect status subset changed")
	}
}

func TestTotalDeadlineDoesNotResetWithProgress(t *testing.T) {
	f := &fakeTCP{ready: []int64{3}, recv: []int64{1}}
	defer f.install()()
	a := &app{hist: newHistory(), loading: true, pageEnd: vi.Nanos() - 1,
		loadEnd: vi.Nanos() + 30_000_000_000, target: "http://10.0.0.2/"}
	a.loadStep()
	if a.loading || a.errKind != "timeout" || f.ci != 0 {
		t.Fatalf("expired whole page read more bytes: loading=%v error=%q reads=%d", a.loading, a.errKind, f.ci)
	}
}

func TestBrowserConnectUsesExplicitFiveSecondBudget(t *testing.T) {
	f := &fakeTCP{}
	defer f.install()()
	var portWord uintptr
	prev := vi.SyscallHookForTest()
	vi.SetSyscallHookForTest(func(slot, x0, x1, x2, x3 uintptr) int64 {
		// DialTimeout rides the slot-80 handle ABI: x0 is the op, and a
		// connect carries ip in x1 and port|timeoutMs<<16 in x2.
		if slot == vi.SlotSocket && x0 == vi.SockOpConnect {
			portWord = x2
			return 0x11 // a table handle
		}
		return prev(slot, x0, x1, x2, x3)
	})
	defer vi.SetSyscallHookForTest(prev)
	a := &app{}
	u, _ := parseBrowserURL("http://10.0.0.2/")
	c, kind := a.connectPage(u)
	if kind != "" {
		t.Fatal(kind)
	}
	defer c.Close()
	ms := portWord >> 16
	if portWord&0xffff != 80 || ms == 0 || ms > 5000 {
		t.Fatalf("connect word=%#x timeout=%dms", portWord, ms)
	}
}

func TestMainResponseUsesOnlyDeclaredBodyLength(t *testing.T) {
	body := "<p>safe</p>"
	a := &app{hist: newHistory(), text: webrender.Bitmap{}, target: "http://10.0.0.2/",
		tStart: vi.Nanos(), tNav0: vi.Nanos(),
		loadBuf: []byte("HTTP/1.0 200 OK\r\nContent-Length: " + itoa(len(body)) +
			"\r\n\r\n" + body + "<p>undeclared tail</p>")}
	frame := parseResponseFrame(a.loadBuf)
	decoded, _, failure := responseBody(frame, a.loadBuf, 256*1024, true)
	if failure != "" {
		t.Fatalf("responseBody: %q", failure)
	}
	a.finishResponse(false, frame.head, decoded, false)
	if string(a.lastBody) != body {
		t.Fatalf("undeclared bytes reached the page: %q", a.lastBody)
	}
}
