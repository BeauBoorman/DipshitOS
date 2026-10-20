package httpc

import (
	"bytes"
	"compress/gzip"
	"strings"
	"testing"
)

func TestGetRequestShape(t *testing.T) {
	got := GetRequest("10.0.0.2:8080", "/a?x=1", "a=b")
	want := "GET /a?x=1 HTTP/1.1\r\nHost: 10.0.0.2:8080\r\nUser-Agent: VirelaiOS/1.0\r\nCookie: a=b\r\nConnection: keep-alive\r\nAccept-Encoding: gzip\r\n\r\n"
	if got != want {
		t.Fatalf("request=%q want=%q", got, want)
	}
	if strings.Contains(GetRequest("h", "/", "x\r\nInjected: y"), "Injected") {
		t.Fatal("cookie injected a header")
	}
}

func TestParseHeadGrammar(t *testing.T) {
	for _, tc := range []struct {
		name, head, err string
	}{
		{"cl", "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n", ""},
		{"chunked", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", ""},
		{"gzip", "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n", ""},
		{"identity", "HTTP/1.0 200 OK\r\nContent-Encoding: identity\r\n\r\n", ""},
		{"te+cl", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n", FramingInvalid},
		{"dup cl", "HTTP/1.0 200 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\n", FramingInvalid},
		{"dup te", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n", FramingInvalid},
		{"te other", "HTTP/1.1 200 OK\r\nTransfer-Encoding: deflate\r\n\r\n", FramingUnsupported},
		{"ce other", "HTTP/1.0 200 OK\r\nContent-Encoding: br\r\n\r\n", FramingUnsupported},
		{"fold", "HTTP/1.0 200 OK\r\n folded\r\n\r\n", FramingInvalid},
		{"bad token", "HTTP/1.0 200 OK\r\nX(bad): y\r\n\r\n", FramingInvalid},
		{"bad status", "HTTP/1.0 20x OK\r\n\r\n", FramingInvalid},
		{"http2", "HTTP/2 200 OK\r\n\r\n", FramingInvalid},
	} {
		_, err := ParseHead([]byte(tc.head), 4096, 128)
		if err != tc.err {
			t.Fatalf("%s: err=%q want %q", tc.name, err, tc.err)
		}
	}
}

func TestKeepAliveVerdict(t *testing.T) {
	for _, tc := range []struct {
		head string
		want bool
	}{
		{"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n", true},
		{"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n", false},
		{"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", true},
		{"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\n", false},
		{"HTTP/1.0 200 OK\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n", true},
		{"HTTP/1.0 200 OK\r\nConnection: keep-alive\r\n\r\n", false}, // no declared boundary
		{"HTTP/1.1 200 OK\r\n\r\n", false},                           // close-delimited
		{"HTTP/1.1 204 No Content\r\n\r\n", true},                    // no body is self-delimiting
	} {
		h, err := ParseHead([]byte(tc.head), 4096, 128)
		if err != "" {
			t.Fatalf("%q: %q", tc.head, err)
		}
		if h.KeepAlive() != tc.want {
			t.Fatalf("%q keepAlive=%v want %v", tc.head, h.KeepAlive(), tc.want)
		}
	}
}

func TestChunkedDecoderIncremental(t *testing.T) {
	wire := "5\r\nhello\r\nA;ext=x\r\n0123456789\r\n0\r\nX-Trailer: skipped\r\n\r\n"
	for _, split := range []int{0, 1, 3, 7, len(wire) - 1} {
		var dec Chunked
		var out []byte
		n1 := dec.Feed([]byte(wire[:split]), &out, 100)
		if n1 != split {
			t.Fatalf("split=%d first feed consumed %d", split, n1)
		}
		dec.Feed([]byte(wire[split:]), &out, 100)
		if dec.Err != "" || !dec.Done {
			t.Fatalf("split=%d done=%v err=%q", split, dec.Done, dec.Err)
		}
		if string(out) != "hello0123456789" {
			t.Fatalf("split=%d out=%q", split, out)
		}
	}
}

func TestChunkedDecoderRefusals(t *testing.T) {
	for _, wire := range []string{
		"zz\r\nx\r\n",            // non-hex size
		"\r\nx\r\n",              // empty size
		"5\r\nhelloXX",           // missing CRLF after data
		"5\r\nhello\rX",          // bad data terminator
		strings.Repeat("9", 200), // oversize line never terminated
	} {
		var dec Chunked
		var out []byte
		dec.Feed([]byte(wire), &out, 100)
		if dec.Err != ChunkedMalformed {
			t.Fatalf("%q err=%q want %q", wire, dec.Err, ChunkedMalformed)
		}
	}
}

func TestChunkedDecoderOverCap(t *testing.T) {
	var dec Chunked
	var out []byte
	dec.Feed([]byte("a\r\n0123456789\r\n0\r\n\r\n"), &out, 4)
	if !dec.Done || !dec.Over || string(out) != "0123" {
		t.Fatalf("done=%v over=%v out=%q", dec.Done, dec.Over, out)
	}
	if dec.Decoded != 10 {
		t.Fatalf("decoded=%d want 10", dec.Decoded)
	}
}

func gzipBytes(t *testing.T, body []byte) []byte {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	if _, err := w.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestDecodeGzip(t *testing.T) {
	body := []byte("<h1>compressed</h1>")
	h := Head{Gzip: true}
	out, trunc, err := Decode(h, gzipBytes(t, body), 1024)
	if err != "" || trunc || !bytes.Equal(out, body) {
		t.Fatalf("out=%q trunc=%v err=%q", out, trunc, err)
	}
}

func TestDecodeGzipRefusals(t *testing.T) {
	h := Head{Gzip: true}
	body := []byte("some content")
	good := gzipBytes(t, body)

	badCRC := append([]byte(nil), good...)
	badCRC[len(badCRC)-6] ^= 0xff
	if _, _, err := Decode(h, badCRC, 1024); err != GzipCRC {
		t.Fatalf("crc err=%q want %q", err, GzipCRC)
	}
	if _, _, err := Decode(h, good, len(body)-1); err != GzipTooLarge {
		t.Fatalf("cap err=%q want %q", err, GzipTooLarge)
	}
	for _, wire := range [][]byte{nil, []byte("not gzip"), good[:len(good)-4]} {
		if _, _, err := Decode(h, wire, 1024); err != GzipMalformed {
			t.Fatalf("wire=%q err=%q want %q", wire, err, GzipMalformed)
		}
	}
}

type scriptSource struct{ segs [][]byte }

func (s *scriptSource) Read(p []byte) (int, error) {
	if len(s.segs) == 0 {
		return 0, errEOF
	}
	n := copy(p, s.segs[0])
	s.segs[0] = s.segs[0][n:]
	if len(s.segs[0]) == 0 {
		s.segs = s.segs[1:]
	}
	return n, nil
}

type errStr string

func (e errStr) Error() string { return string(e) }

var errEOF = errStr("eof")

var testPolicy = Policy{MaxHead: 4096, MaxLine: 512, MaxFields: 64, Cap: 4096, WireSlack: 8192}

func TestReadResponseFramings(t *testing.T) {
	gz := gzipBytes(t, []byte("zipped"))
	for _, tc := range []struct {
		name     string
		wire     string
		body     string
		reusable bool
	}{
		{"cl http11", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello", "hello", true},
		{"cl http10", "HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhello", "hello", false},
		{"http10 explicit ka", "HTTP/1.0 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello", "hello", true},
		{"chunked", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n", "hello", true},
		{"close-delimited", "HTTP/1.1 200 OK\r\n\r\nhello", "hello", false},
		{"204", "HTTP/1.1 204 No Content\r\n\r\n", "", true},
		{"1xx then 200", "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi", "hi", true},
		{"chunked gzip", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Encoding: gzip\r\n\r\n" +
			chunkedOf(gz), "zipped", true},
	} {
		src := &scriptSource{segs: [][]byte{[]byte(tc.wire)}}
		head, h, body, _, reusable, err := ReadResponse(src, testPolicy)
		if err != "" {
			t.Fatalf("%s: %q", tc.name, err)
		}
		if string(body) != tc.body {
			t.Fatalf("%s body=%q want %q", tc.name, body, tc.body)
		}
		if reusable != tc.reusable {
			t.Fatalf("%s reusable=%v want %v (head=%q)", tc.name, reusable, tc.reusable, head)
		}
		_ = h
	}
}

func chunkedOf(b []byte) string {
	var sb strings.Builder
	for len(b) > 0 {
		n := len(b)
		if n > 8 {
			n = 8
		}
		sb.WriteString(hexLower(uint64(n)))
		sb.WriteString("\r\n")
		sb.Write(b[:n])
		sb.WriteString("\r\n")
		b = b[n:]
	}
	sb.WriteString("0\r\n\r\n")
	return sb.String()
}

func hexLower(v uint64) string {
	const d = "0123456789abcdef"
	if v == 0 {
		return "0"
	}
	var buf [16]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = d[v&0xf]
		v >>= 4
	}
	return string(buf[i:])
}

func TestReadResponseRefusals(t *testing.T) {
	for _, tc := range []struct {
		name, wire, err string
	}{
		{"bad chunk", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nx\r\n", ChunkedMalformed},
		{"eof mid-chunk", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel", ChunkedMalformed},
		{"short cl", "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nabc", PrematureEOF},
		{"huge head", "HTTP/1.1 200 OK\r\nX: " + strings.Repeat("a", 9999) + "\r\n\r\n", HeaderLimit},
	} {
		src := &scriptSource{segs: [][]byte{[]byte(tc.wire)}}
		if _, _, _, _, _, err := ReadResponse(src, testPolicy); err != tc.err {
			t.Fatalf("%s: err=%q want %q", tc.name, err, tc.err)
		}
	}
}
