package main

import (
	"strings"

	"virelai/httpc"
	"virelai/webrender"
	"virelai/webstyle"
)

const maxHTTPHeaders = 16384
const maxHTTPLine = 4096
const maxHTTPFields = 128
const maxPageRequests = 25

// responseFrame is the parsed head of one response: where the wire body
// starts, the declared framing (Content-Length / chunked / close-
// delimited / no-body), the content coding, and the connection policy —
// all delegated to the shared httpc grammar (M135b).
type responseFrame struct {
	head, err string
	offset    int
	parsed    httpc.Head
	need      int // Content-Length; -1 means chunked or EOF framing
	complete  bool
}

func parseResponseFrame(raw []byte) responseFrame {
	i := httpc.HeadEnd(raw)
	if i < 0 {
		if len(raw) > maxHTTPHeaders {
			return responseFrame{err: "http-header-limit", complete: true}
		}
		for _, line := range strings.Split(string(raw), "\n") {
			if len(strings.TrimRight(line, "\r")) > maxHTTPLine {
				return responseFrame{err: "http-header-limit", complete: true}
			}
		}
		return responseFrame{}
	}
	f := responseFrame{head: string(raw[:i]), offset: i, need: -1, complete: true}
	if i > maxHTTPHeaders {
		f.err = "http-header-limit"
		return f
	}
	h, perr := httpc.ParseHead(raw[:i], maxHTTPLine, maxHTTPFields)
	if perr != "" {
		f.err = perr
		return f
	}
	f.parsed = h
	f.need = h.Length
	return f
}

func formatPageRequest(u webrender.URL, cookie string) string {
	if len(cookie)+8 > maxHTTPLine {
		cookie = "" // an edited ledger cannot grow past the line bound
	}
	return httpc.GetRequest(urlAuthority(u), u.Path, cookie)
}

// responseBody turns the buffered wire bytes into the decoded body once
// the message is complete: Content-Length bounded, chunked (trailers
// skipped), or close-delimited, then content-decoded (gzip through
// flate). The named refusals are httpc's shared grammar.
func responseBody(f responseFrame, raw []byte, capn int, eof bool) ([]byte, bool, string) {
	if f.err != "" {
		return nil, false, f.err
	}
	if !f.complete {
		if eof {
			return nil, false, "http-premature-eof"
		}
		return nil, false, ""
	}
	wire := raw[f.offset:]
	var src []byte
	switch {
	case f.parsed.NoBody:
		return []byte{}, false, ""
	case f.parsed.Chunked:
		var dec httpc.Chunked
		dec.Feed(wire, &src, capn)
		if dec.Err != "" {
			return nil, false, dec.Err
		}
		if !dec.Done {
			if eof {
				return nil, false, httpc.ChunkedMalformed
			}
			return nil, false, ""
		}
	case f.need >= 0:
		if !f.parsed.Gzip && f.need > capn && len(wire) >= capn {
			return wire[:capn], true, ""
		}
		if len(wire) < f.need {
			if eof {
				return nil, false, "http-premature-eof"
			}
			return nil, false, ""
		}
		src = wire[:f.need]
	default: // close-delimited
		if !eof {
			if len(wire) > capn {
				return wire[:capn], true, ""
			}
			return nil, false, ""
		}
		src = wire
	}
	return httpc.Decode(f.parsed, src, capn)
}

// responseNeed retains the pre-existing host-test framing contract. Production
// fetchers use the structured parser to preserve full named errors.
func responseNeed(raw []byte) (int, bool) {
	f := parseResponseFrame(raw)
	if !f.complete {
		return 0, false
	}
	if f.err != "" || f.need > webstyle.MaxHTMLBytes {
		return -2, true
	}
	return f.need, true
}
