package main

import (
	"strings"
	"testing"
	"unsafe"

	"virelai/httpc"
	"virelai/vi"
)

// parseResponseHead keeps the old three-value test seam over the shared
// engine's head parser.
func parseResponseHead(head []byte) (int, int, error) {
	h, err := httpc.ParseHead(head, 1024, 64)
	if err != "" {
		return 0, 0, errStr(err)
	}
	return h.Status, h.Length, nil
}

// segmentPeer serves canned response segments and then reports
// vi.ErrPeerGone (the peer's FIN), the same end condition connStream sees.
type segmentPeer struct {
	segs [][]byte
	off  int
}

func (p *segmentPeer) Read(b []byte) (int, error) {
	if p.off >= len(p.segs) {
		return 0, vi.ErrPeerGone
	}
	n := copy(b, p.segs[p.off])
	p.off++
	return n, nil
}

type exitProbe struct {
	status int
	calls  int
}

func (e *exitProbe) hook(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	if num == vi.SlotWrite {
		return int64(a2)
	}
	return -vi.ErrENOSYS
}

func (e *exitProbe) install(t *testing.T) {
	t.Helper()
	prev := vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == vi.SlotExit {
			e.calls++
			e.status = int(a0)
			panic("exit")
		}
		return e.hook(num, a0, a1, a2, a3)
	})
	t.Cleanup(func() { vi.SetSyscallHookForTest(prev) })
}

// captureExit lets a test observe every other slot while the exit slot
// panics on its first call (vi.Exit's yield loop is stopped by recover).
func captureExit(t *testing.T, probe *exitProbe, other func(num uintptr, a0, a1, a2, a3 uintptr) (int64, bool)) {
	t.Helper()
	prev := vi.SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == vi.SlotExit {
			probe.calls++
			probe.status = int(a0)
			panic("exit")
		}
		if r, ok := other(num, a0, a1, a2, a3); ok {
			return r
		}
		return probe.hook(num, a0, a1, a2, a3)
	})
	t.Cleanup(func() { vi.SetSyscallHookForTest(prev) })
}

// runUntilExit runs fn, which must reach vi.Exit. vi.Exit routes its
// syscall through the vi hook seam, so the exitProbe records the status and
// panics there; recover then stops vi.Exit's post-exit yield loop.
func runUntilExit(t *testing.T, probe *exitProbe, fn func()) {
	t.Helper()
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("runPlain returned instead of exiting")
		}
		if probe.calls != 1 {
			t.Fatalf("vi.Exit called %d times, want 1 (status %d)", probe.calls, probe.status)
		}
	}()
	fn()
}

func hookBytesAt(a0, a1 uintptr) []byte {
	if a0 == 0 || a1 == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
}

// netStatsReady fills the snapshot buffer with own_ip 10.0.0.1 and the
// destination 10.0.0.2 in the first ARP slot, i.e. NetReady. The offsets
// mirror vi's decoded NetStats wire layout (own_ip 6, arp_count 50,
// arp_ips 51).
func netStatsReady(buf []byte) int64 {
	for i := range buf {
		buf[i] = 0
	}
	copy(buf[6:10], []byte{10, 0, 0, 1})
	buf[50] = 1 // arp_count
	copy(buf[51:55], []byte{10, 0, 0, 2})
	return int64(len(buf))
}

func TestParseResponseHead(t *testing.T) {
	status, length, err := parseResponseHead([]byte("HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\n"))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if status != 200 || length != 5 {
		t.Fatalf("status=%d length=%d want 200/5", status, length)
	}
	status, length, err = parseResponseHead([]byte("HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n"))
	if err != nil || status != 404 || length != 0 {
		t.Fatalf("case-insensitive CL: %d/%d err=%v", status, length, err)
	}
	status, length, err = parseResponseHead([]byte("HTTP/1.0 200 OK\r\nServer: x\r\n\r\n"))
	if err != nil || status != 200 || length != -1 {
		t.Fatalf("no CL: %d/%d err=%v want 200/-1", status, length, err)
	}
	for _, bad := range []string{
		"HTTP/1.0 OK\r\n\r\n",
		"HTTP/1.0 20X OK\r\n\r\n",
		"HTTP/1.0 200 OK\r\nContent-Length: abc\r\n\r\n",
		"HTTP/1.0 200 OK\r\nContent-Length:\r\n\r\n",
	} {
		if _, _, err := parseResponseHead([]byte(bad)); err == nil {
			t.Errorf("parseResponseHead(%q) accepted a malformed head", bad)
		}
	}
}

// TestResponseStreamFramesAcrossSegments proves the terminator is found
// when it straddles reads and the body seed from the first segment is not
// lost, and that Content-Length (not the FIN) bounds the body.
func TestResponseStreamFramesAcrossSegments(t *testing.T) {
	segs := [][]byte{
		[]byte("HTTP/1.0 200 OK\r\nContent-Len"),
		[]byte("gth: 5\r\n\r\nhe"),
		[]byte("lloTRAIL"),
	}
	rs, err := newResponseStream(&segmentPeer{segs: segs})
	if err != nil {
		t.Fatalf("newResponseStream: %v", err)
	}
	if rs.parsed.Status != 200 || rs.parsed.Length != 5 {
		t.Fatalf("status=%d length=%d", rs.parsed.Status, rs.parsed.Length)
	}
	if string(rs.head) != "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\n" {
		t.Fatalf("head = %q", rs.head)
	}
	if string(rs.body) != "hello" {
		t.Fatalf("body = %q want %q (Content-Length bounds it)", rs.body, "hello")
	}
}

func TestResponseStreamRejectsOversizedAndMalformedHeads(t *testing.T) {
	long := "HTTP/1.0 200 OK\r\nX: " + strings.Repeat("a", headerLimit) + "\r\n\r\n"
	if _, err := newResponseStream(&segmentPeer{segs: [][]byte{[]byte(long)}}); err == nil {
		t.Error("oversized head accepted")
	}
	if _, err := newResponseStream(&segmentPeer{segs: [][]byte{[]byte("HTTP/1.0 200 OK\r\n")}}); err == nil {
		t.Error("head without terminator accepted")
	}
	short := &segmentPeer{segs: [][]byte{[]byte("HTTP/1.0 200 OK\r\nContent-Length: 9\r\n\r\nhi")}}
	if _, err := newResponseStream(short); err == nil {
		t.Error("short body against Content-Length accepted")
	}
}

func TestRequestString(t *testing.T) {
	got := requestString("10.0.0.2", 80, "/file.bin")
	want := "GET /file.bin HTTP/1.1\r\nHost: 10.0.0.2\r\nUser-Agent: VirelaiOS/1.0\r\nConnection: keep-alive\r\nAccept-Encoding: gzip\r\n\r\n"
	if got != want {
		t.Fatalf("requestString =\n%q\nwant\n%q", got, want)
	}
	if h := requestString("10.0.0.2", 8080, "/"); !strings.Contains(h, "Host: 10.0.0.2:8080\r\n") {
		t.Fatalf("non-default port missing from Host header: %q", h)
	}
}

func TestPlanClearAcceptsOnlyExplicitCleartext(t *testing.T) {
	req, ok := planClear("http://10.0.0.2:8080/a/b.bin?x=1")
	if !ok {
		t.Fatal("explicit http:// URL must plan")
	}
	if req.host != "10.0.0.2" || req.port != 8080 || req.ip != [4]byte{10, 0, 0, 2} {
		t.Fatalf("plan = %+v", req)
	}
	if req.path != "/a/b.bin?x=1" {
		t.Fatalf("path = %q (query must survive like the Zig client)", req.path)
	}
	if req, ok := planClear("10.0.0.2/file.bin"); !ok || req.host != "10.0.0.2" || req.path != "/file.bin" {
		t.Fatalf("scheme-less literal = %+v ok=%v", req, ok)
	}
	for _, bad := range []string{
		"https://10.0.0.2/",
		"ftp://10.0.0.2/",
		"http://example.com/",
		"http://10.0.0.2:99999/",
		"http://",
	} {
		if _, ok := planClear(bad); ok {
			t.Errorf("planClear(%q) accepted", bad)
		}
	}
}

func TestParseLegacyArgsSelectsModes(t *testing.T) {
	// A -h anywhere is a request for the legacy usage text, even next to an
	// https URL; the windowed consumer has its own usage surface.
	if a, legacy := parseLegacyArgs([]string{"GOFETCH.ELF", "-h", "https://10.0.0.2/"}); !legacy || !a.help {
		t.Errorf("-h + https = %+v legacy=%v", a, legacy)
	}
	// No args / bare https / hostname with no cleartext intent: the windowed
	// TLS consumer owns them, so the legacy dispatcher must stay out. The
	// three-positional form is the TLS consumer's `https://URL sni expect`
	// shape (the go-fetch-https negatives) and must not fall into the
	// legacy path either — that mistake once sent an https:// run down the
	// cleartext socket.
	for _, args := range [][]string{
		{"GOFETCH.ELF"},
		{"GOFETCH.ELF", "https://10.0.0.2:24533/"},
		{"GOFETCH.ELF", "leaf.example.com"},
		{"GOFETCH.ELF", "https://10.0.0.2:24550/", "wrong.example.com", "name"},
		{"GOFETCH.ELF", "https://10.0.0.2:24552/", "leaf.example.com", "expired"},
	} {
		if _, legacy := parseLegacyArgs(args); legacy {
			t.Errorf("parseLegacyArgs(%q) claimed the legacy path", args)
		}
	}
	a, legacy := parseLegacyArgs([]string{"GOFETCH.ELF", "http://10.0.0.2/"})
	if !legacy || a.url != "http://10.0.0.2/" || a.download || a.dest != "" {
		t.Fatalf("http fetch = %+v legacy=%v", a, legacy)
	}
	a, legacy = parseLegacyArgs([]string{"GOFETCH.ELF", "--download"})
	if !legacy || !a.download || a.url != "http://10.0.0.2/" || a.dest != legacyDefaultDest {
		t.Fatalf("bare --download = %+v legacy=%v", a, legacy)
	}
	a, legacy = parseLegacyArgs([]string{"GOFETCH.ELF", "--download", "http://10.0.0.2:8080/f.bin", "OUT.BIN"})
	if !legacy || a.dest != "OUT.BIN" || a.url != "http://10.0.0.2:8080/f.bin" {
		t.Fatalf("download with dest = %+v legacy=%v", a, legacy)
	}
	for _, args := range [][]string{
		{"GOFETCH.ELF", "--bogus"},
		{"GOFETCH.ELF", "https://10.0.0.2:24533/", "--bogus"},
		{"GOFETCH.ELF", "--download", "http://10.0.0.2/", "--bogus"},
	} {
		if a, legacy := parseLegacyArgs(args); !legacy || !a.usage {
			t.Errorf("unknown flag %q = %+v legacy=%v want usage", args, a, legacy)
		}
	}
	// More than [URL [DEST]] on the cleartext path is a misuse, not a fetch.
	if a, legacy := parseLegacyArgs([]string{"GOFETCH.ELF", "http://10.0.0.2/", "A", "B"}); !legacy || !a.usage {
		t.Errorf("four positionals = %+v legacy=%v want usage", a, legacy)
	}
	if a, legacy := parseLegacyArgs([]string{"GOFETCH.ELF", "-h"}); !legacy || !a.help {
		t.Errorf("-h = %+v legacy=%v", a, legacy)
	}
}

// TestPreflightOfflineExitsThree drives runPlain through a fake net-stats
// snapshot with no own IP: the preflight must exit 3 before any TCP slot
// is touched (N13).
func TestPreflightOfflineExitsThree(t *testing.T) {
	probe := &exitProbe{}
	tcpTouched := false
	captureExit(t, probe, func(num uintptr, a0, a1, a2, a3 uintptr) (int64, bool) {
		switch num {
		case vi.SlotNetStats:
			buf := hookBytesAt(a0, a1)
			for i := range buf {
				buf[i] = 0
			}
			return int64(len(buf)), true // own_ip 0.0.0.0, arp_count 0
		case vi.SlotTCPConnect, vi.SlotTCPSend, vi.SlotTCPRecv, vi.SlotTCPClose, vi.SlotSockReady, vi.SlotSocket:
			tcpTouched = true
			return -vi.ErrENOSYS, true
		}
		return 0, false
	})

	req, ok := planClear("http://10.0.0.2/")
	if !ok {
		t.Fatal("plan")
	}
	runUntilExit(t, probe, func() { runPlain(req, false, "") })
	if probe.status != exitOffline {
		t.Fatalf("offline: status=%d want %d", probe.status, exitOffline)
	}
	if tcpTouched {
		t.Fatal("offline preflight touched a TCP slot")
	}
}

// TestPreflightNoRouteExitsFour is the N14 row: an own IP is set but the
// ARP table lacks the destination.
func TestPreflightNoRouteExitsFour(t *testing.T) {
	probe := &exitProbe{}
	tcpTouched := false
	captureExit(t, probe, func(num uintptr, a0, a1, a2, a3 uintptr) (int64, bool) {
		switch num {
		case vi.SlotNetStats:
			buf := hookBytesAt(a0, a1)
			for i := range buf {
				buf[i] = 0
			}
			copy(buf[6:10], []byte{10, 0, 0, 1}) // own_ip, arp_count stays 0
			return int64(len(buf)), true
		case vi.SlotTCPConnect, vi.SlotTCPSend, vi.SlotTCPRecv, vi.SlotTCPClose, vi.SlotSockReady, vi.SlotSocket:
			tcpTouched = true
			return -vi.ErrENOSYS, true
		}
		return 0, false
	})

	req, _ := planClear("http://10.0.0.2/")
	runUntilExit(t, probe, func() { runPlain(req, false, "") })
	if probe.status != exitNoRoute {
		t.Fatalf("no-route: status=%d want %d", probe.status, exitNoRoute)
	}
	if tcpTouched {
		t.Fatal("no-route preflight touched a TCP slot")
	}
}

// TestOnlineFetchExitsFortyTwo drives the full cleartext fetch over a fake
// vi seam: preflight ready, connect, request, response framing, exit 42.
func TestOnlineFetchExitsFortyTwo(t *testing.T) {
	probe := &exitProbe{}
	response := []byte("HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhelloTRAIL")
	sent := make([]byte, 0, 256)
	recvCount := 0
	captureExit(t, probe, func(num uintptr, a0, a1, a2, a3 uintptr) (int64, bool) {
		switch num {
		case vi.SlotNetStats:
			buf := hookBytesAt(a0, a1)
			if len(buf) != vi.NetStatsBytes {
				t.Fatalf("net-stats buffer = %d bytes, want %d", len(buf), vi.NetStatsBytes)
			}
			return netStatsReady(buf), true
		case vi.SlotSocket:
			// vi.Dial rides the slot-80 handle ABI: a0 is the op, so a
			// connect arrives as (SockOpConnect, ip, port|ms<<16, _); the
			// per-handle I/O ops then carry (op, handle, ptr, len).
			switch a0 {
			case vi.SockOpConnect:
				if a1 != 0x0a000002 || a2 != 80 {
					t.Errorf("connect = %#x:%#x want 0a000002:80", a1, a2)
				}
				return 0x11, true // a table handle
			case vi.SockOpSend:
				sent = append(sent, hookBytesAt(a2, a3)...)
				return int64(a3), true
			case vi.SockOpReady:
				return 1, true // readyRead
			case vi.SockOpRead:
				if recvCount == 0 {
					recvCount++
					dst := hookBytesAt(a2, a3)
					return int64(copy(dst, response)), true
				}
				return 0, true // readable + 0 bytes == FIN
			case vi.SockOpShutdown, vi.SockOpClose:
				return 0, true
			}
			return -vi.ErrENOSYS, true
		}
		return 0, false
	})

	req, _ := planClear("http://10.0.0.2/")
	runUntilExit(t, probe, func() { runPlain(req, false, "") })
	if probe.status != exitFetchOK {
		t.Fatalf("online fetch: status=%d want %d", probe.status, exitFetchOK)
	}
	want := requestString("10.0.0.2", 80, "/")
	if string(sent) != want {
		t.Fatalf("request on the wire =\n%q\nwant\n%q", sent, want)
	}
}

// TestOnlineDownloadPublishesBodyAndExitsZero drives --download end to end
// over the fake vi seam: no preflight (download never had one), the body is
// published through WriteFileSafe (temp -> write -> fsync -> delete ->
// rename), and the process exits 0.
func TestOnlineDownloadPublishesBodyAndExitsZero(t *testing.T) {
	probe := &exitProbe{}
	payload := "Hello from VirelaiOS Host!\n"
	response := []byte("HTTP/1.0 200 OK\r\nContent-Length: " +
		vi.Itoa64(int64(len(payload))) + "\r\n\r\n" + payload)
	sent := make([]byte, 0, 256)
	recvCount := 0
	// A tiny in-memory file table for the publish sequence.
	files := map[string][]byte{}
	handlePath := map[int64]string{}
	nextHandle := int64(1)
	var ops []string
	captureExit(t, probe, func(num uintptr, a0, a1, a2, a3 uintptr) (int64, bool) {
		switch num {
		case vi.SlotSocket:
			// Slot-80 handle ABI: a0 is the op; connect carries the ip in
			// a1 and port|ms<<16 in a2, I/O ops carry (op, handle, ptr, len).
			switch a0 {
			case vi.SockOpConnect:
				return 0x11, true // a table handle
			case vi.SockOpSend:
				sent = append(sent, hookBytesAt(a2, a3)...)
				return int64(a3), true
			case vi.SockOpReady:
				return 1, true // readyRead
			case vi.SockOpRead:
				if recvCount == 0 {
					recvCount++
					return int64(copy(hookBytesAt(a2, a3), response)), true
				}
				return 0, true
			case vi.SockOpShutdown, vi.SockOpClose:
				return 0, true
			}
			return -vi.ErrENOSYS, true
		case vi.SlotFileOpen:
			path := cstringAt(a0, a1)
			files[path] = nil
			handlePath[nextHandle] = path
			ops = append(ops, "open "+path)
			h := nextHandle
			nextHandle++
			return h, true
		case vi.SlotFileWrite:
			h := int64(a0)
			files[handlePath[h]] = append(files[handlePath[h]], hookBytesAt(a1, a2)...)
			ops = append(ops, "write "+handlePath[h])
			return int64(a2), true
		case vi.SlotFileSync:
			ops = append(ops, "sync "+handlePath[int64(a0)])
			return 0, true
		case vi.SlotFileClose:
			ops = append(ops, "close "+handlePath[int64(a0)])
			return 0, true
		case vi.SlotFileDelete:
			path := cstringAt(a0, a1)
			ops = append(ops, "delete "+path)
			if _, ok := files[path]; !ok {
				return -vi.ErrENOENT, true
			}
			delete(files, path)
			return 0, true
		case vi.SlotFileRename:
			oldPath, newPath := cstringAt(a0, a1), cstringAt(a2, a3)
			ops = append(ops, "rename "+oldPath+" -> "+newPath)
			if _, ok := files[oldPath]; !ok {
				return -vi.ErrENOENT, true
			}
			files[newPath] = files[oldPath]
			delete(files, oldPath)
			return 0, true
		}
		return 0, false
	})

	req, _ := planClear("http://10.0.0.2/file.bin")
	runUntilExit(t, probe, func() { runPlain(req, true, legacyDefaultDest) })
	if probe.status != 0 {
		t.Fatalf("download: status=%d want 0", probe.status)
	}
	if want := requestString("10.0.0.2", 80, "/file.bin"); string(sent) != want {
		t.Fatalf("request on the wire =\n%q\nwant\n%q", sent, want)
	}
	if got := string(files[legacyDefaultDest]); got != payload {
		t.Fatalf("published body = %q want %q (files: %v)", got, payload, files)
	}
	// The publish order is the crash-safe contract, not an implementation
	// detail: open temp, write, fsync, close, delete target, rename.
	wantOps := []string{
		"open " + legacyDefaultDest + "~",
		"write " + legacyDefaultDest + "~",
		"sync " + legacyDefaultDest + "~",
		"close " + legacyDefaultDest + "~",
		"delete " + legacyDefaultDest,
		"rename " + legacyDefaultDest + "~ -> " + legacyDefaultDest,
	}
	if strings.Join(ops, "|") != strings.Join(wantOps, "|") {
		t.Fatalf("publish ops =\n%v\nwant\n%v", ops, wantOps)
	}
}

func cstringAt(ptr, length uintptr) string {
	b := hookBytesAt(ptr, length)
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

// M97f (#2106): cleartext framing must refuse the vectors the browser's
// framing.go already refuses — Transfer-Encoding written verbatim as
// "body", duplicate or conflicting Content-Length (last-wins desync), and a
// non-identity Content-Encoding (gzip) passed through undecoded.
func TestParseResponseHeadRefusesUnsupportedFraming(t *testing.T) {
	for _, bad := range []string{
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\n\r\n",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: deflate\r\n\r\n",
		"HTTP/1.0 200 OK\r\nContent-Length: 5\r\nContent-Length: 9\r\n\r\n",
		"HTTP/1.0 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n",
		"HTTP/1.0 200 OK\r\ncontent-encoding: br\r\n\r\n",
		"HTTP/1.0 200 OK\r\ncontent-encoding: deflate\r\n\r\n",
	} {
		if _, _, err := parseResponseHead([]byte(bad)); err == nil {
			t.Errorf("parseResponseHead(%q) accepted unsupported framing", bad)
		}
	}
	// Identity encoding and a single Content-Length still pass.
	for _, good := range []string{
		"HTTP/1.0 200 OK\r\nContent-Encoding: identity\r\nContent-Length: 5\r\n\r\n",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
		"HTTP/1.0 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 5\r\n\r\n",
	} {
		if _, _, err := parseResponseHead([]byte(good)); err != nil {
			t.Fatalf("supported framing refused: %v", err)
		}
	}
}

// M100f (#2311): the no-DEST download default follows the data_root row —
// /disk on a mounted opt-in, the share path on the set-but-absent fallback,
// and an explicit DEST always wins either way.
func TestDownloadDestFollowsDataRoot(t *testing.T) {
	saved := fetchDataRoot
	defer func() { fetchDataRoot = saved }()

	fetchDataRoot = func() (string, bool) { return "/disk", false }
	a, legacy := parseLegacyArgs([]string{"GOFETCH.ELF", "--download"})
	if !legacy || a.dest != "/disk/DOWNLOAD.OUT" {
		t.Fatalf("mounted opt-in dest = %q legacy=%v", a.dest, legacy)
	}
	a, _ = parseLegacyArgs([]string{"GOFETCH.ELF", "--download", "http://10.0.0.2/f.bin", "OUT.BIN"})
	if a.dest != "OUT.BIN" {
		t.Fatalf("explicit DEST overridden: %q", a.dest)
	}

	fetchDataRoot = func() (string, bool) { return "/host", true }
	a, _ = parseLegacyArgs([]string{"GOFETCH.ELF", "--download"})
	if a.dest != legacyDefaultDest {
		t.Fatalf("fallback dest = %q, want %q", a.dest, legacyDefaultDest)
	}
}
