package httpc

import (
	"virelai/flate"
)

// Decode applies the response's content coding to a COMPLETE wire body:
// gzip members through flate (structure, CRC32, ISIZE), else identity.
// capn is the decoded-body cap. A plain body over it clips (truncated);
// a gzip body over it refuses GzipTooLarge — an inflater that has already
// produced capn+1 bytes is a bomb by the stream's own declaration, not a
// page to trim. flate refusals map to the shared names: integrity ->
// GzipCRC, output bound -> GzipTooLarge, structure -> GzipMalformed.
func Decode(h Head, wire []byte, capn int) (body []byte, truncated bool, err string) {
	if !h.Gzip {
		if len(wire) > capn {
			return wire[:capn], true, ""
		}
		return wire, false, ""
	}
	if len(wire) == 0 {
		return nil, false, GzipMalformed // a gzip body carries ≥1 member
	}
	dst := make([]byte, capn+1)
	n, _, derr := flate.InflateGzip(dst, wire)
	switch {
	case flate.IsOutputBound(derr) || n > capn:
		return nil, false, GzipTooLarge
	case flate.IsGzipIntegrity(derr):
		return nil, false, GzipCRC
	case derr != nil:
		return nil, false, GzipMalformed
	}
	return dst[:n], false, ""
}

// Source is the blocking pull shape a live connection provides: n>0
// bytes per read, a nil-error n==0 or an error at the peer's end.
type Source interface {
	Read(p []byte) (int, error)
}

// Policy carries the per-consumer bounds the engine enforces.
type Policy struct {
	MaxHead   int // total head bytes before HeaderLimit
	MaxLine   int // one header/size line before FramingInvalid
	MaxFields int // header field count before HeaderLimit
	Cap       int // decoded-body cap
	// WireSlack bounds the wire form beyond Cap: a chunked stream's size
	// lines and trailer bytes are real wire bytes but not content. A
	// body whose WIRE exceeds Cap+WireSlack is a BodyLimit refusal.
	WireSlack int
}

const readChunk = 1460

// ReadResponse reads one complete response from s: 1xx heads are skipped,
// then the body is framed by its declared shape — Content-Length,
// chunked, or the peer's FIN — and content-decoded. reusable reports the
// keep-alive verdict: the message ended on a declared boundary AND the
// peer did not close AND no error occurred. eof reports whether the peer
// already sent its FIN (a reusable-looking but dead connection must not
// be parked).
func ReadResponse(s Source, p Policy) (head []byte, h Head, body []byte, truncated, reusable bool, err string) {
	raw := make([]byte, 0, 4096)
	var buf [readChunk]byte
	offset := 0
	for {
		if i := HeadEnd(raw); i >= 0 {
			cand := raw[:i]
			parsed, perr := ParseHead(cand, p.MaxLine, p.MaxFields)
			if perr != "" {
				return nil, h, nil, false, false, perr
			}
			if parsed.Status >= 100 && parsed.Status < 200 && parsed.Status != 101 {
				raw = append(raw[:0], raw[i:]...) // interim head: drop and rescan
				continue
			}
			h, head, offset = parsed, cand, i
			break
		}
		if len(raw) >= p.MaxHead {
			return nil, h, nil, false, false, HeaderLimit
		}
		n, rerr := s.Read(buf[:])
		if n > 0 {
			raw = append(raw, buf[:n]...)
		}
		if rerr != nil || n == 0 {
			return nil, h, nil, false, false, PrematureEOF
		}
	}
	wireCap := p.Cap + p.WireSlack
	eof := false
	var decoded []byte
	var dec Chunked
	for {
		wire := raw[offset:]
		done := false
		switch {
		case h.NoBody:
			done = true
		case h.Chunked:
			dec.Feed(wire[dec.Fed:], &decoded, p.Cap)
			if dec.Err != "" {
				return nil, h, nil, false, false, dec.Err
			}
			if dec.Done {
				done = true
			} else if eof {
				return nil, h, nil, false, false, ChunkedMalformed
			}
		case h.Length >= 0:
			if len(wire) >= h.Length {
				done = true
			} else if eof {
				return nil, h, nil, false, false, PrematureEOF
			}
		default:
			done = eof
		}
		if done {
			var wire []byte
			switch {
			case h.NoBody:
				wire = nil
			case h.Chunked:
				wire = decoded // the dechunked form is what content-coding reads
			case h.Length >= 0:
				wire = raw[offset : offset+h.Length]
			default:
				wire = raw[offset:]
			}
			body, truncated, err = Decode(h, wire, p.Cap)
			if err != "" {
				return nil, h, nil, false, false, err
			}
			return head, h, body, truncated, h.KeepAlive() && !eof, ""
		}
		if len(wire) > wireCap {
			return nil, h, nil, false, false, BodyLimit
		}
		n, rerr := s.Read(buf[:])
		if n > 0 {
			raw = append(raw, buf[:n]...)
		}
		if rerr != nil || n == 0 {
			eof = true
		}
	}
}
