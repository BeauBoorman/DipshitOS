package httpc

import "bytes"

// Chunked bounds (M135b): the chunk-size line is capped outright (the
// card's declared bound); each trailer line rides the same line cap the
// head parser enforces, since trailers are skipped header fields.
const (
	MaxChunkLine   = 128
	MaxTrailerLine = 4096
)

const (
	chunkSize    = iota // accumulating a chunk-size line
	chunkData           // consuming chunk data
	chunkDataCR         // consumed '\r' after data, expecting '\n'
	chunkTrailer        // accumulating trailer lines until the empty one
	chunkDone
)

// Chunked is the incremental RFC 9112 §7.1 decoder. Feed it wire bytes as
// they arrive; decoded bytes append to out (clipped at capn — surplus
// decoded bytes set Over but are still consumed, so the connection stays
// usable). Trailers are skipped. Done is the terminal zero-chunk seen;
// Err names ChunkedMalformed on any grammar fault.
type Chunked struct {
	state   int
	remain  int64  // data bytes left in the current chunk
	line    []byte // partial size/trailer line
	sawCR   bool   // a bare '\r' carried across a feed boundary
	Fed     int64  // cumulative wire bytes consumed (callers resume at it)
	Decoded int64  // total decoded bytes (including over-cap)
	Done    bool
	Over    bool
	Err     string
}

// Feed consumes wire, decoding as far as the bytes allow. It returns the
// wire bytes consumed (also accumulated in Fed); anything left over after
// Done is not this message's (callers do not pipeline, so it should not
// exist).
func (c *Chunked) Feed(wire []byte, out *[]byte, capn int) int {
	pos := 0
	defer func() { c.Fed += int64(pos) }()
	for pos < len(wire) && !c.Done && c.Err == "" {
		switch c.state {
		case chunkSize, chunkTrailer:
			limit := MaxChunkLine
			if c.state == chunkTrailer {
				limit = MaxTrailerLine
			}
			i := bytes.IndexByte(wire[pos:], '\n')
			if i < 0 {
				// Whole remainder is a partial line.
				if len(c.line)+len(wire)-pos > limit {
					return c.fail(pos)
				}
				c.line = append(c.line, wire[pos:]...)
				return len(wire)
			}
			if len(c.line)+i > limit {
				return c.fail(pos)
			}
			line := c.line
			line = append(line, wire[pos:pos+i]...)
			pos += i + 1
			c.line = c.line[:0]
			if len(line) > 0 && line[len(line)-1] == '\r' {
				line = line[:len(line)-1]
			}
			if c.state == chunkTrailer {
				if len(line) == 0 {
					c.state, c.Done = chunkDone, true
				}
				continue // trailer fields are skipped wholesale
			}
			size, ok := parseChunkSize(line)
			if !ok {
				return c.fail(pos)
			}
			if size == 0 {
				c.state = chunkTrailer
			} else {
				c.remain = int64(size)
				c.state = chunkData
			}
		case chunkData:
			take := int64(len(wire) - pos)
			if take > c.remain {
				take = c.remain
			}
			data := wire[pos : pos+int(take)]
			room := capn - len(*out)
			if room < 0 {
				room = 0
			}
			if int(take) <= room {
				*out = append(*out, data...)
			} else {
				*out = append(*out, data[:room]...)
				c.Over = true
			}
			c.Decoded += take
			pos += int(take)
			c.remain -= take
			if c.remain == 0 {
				c.state = chunkDataCR
			}
		case chunkDataCR:
			if !c.sawCR {
				if wire[pos] != '\r' {
					return c.fail(pos)
				}
				c.sawCR = true
				pos++
				continue
			}
			if wire[pos] != '\n' {
				return c.fail(pos)
			}
			c.sawCR = false
			pos++
			c.state = chunkSize
		}
	}
	return pos
}

func (c *Chunked) fail(consumed int) int {
	c.Err = ChunkedMalformed
	return consumed
}

// parseChunkSize decodes a chunk-size line: 1*HEXDIG then an optional
// ";ext" section whose contents are ignored. Empty, non-hex, and
// overflowing lines are malformed.
func parseChunkSize(line []byte) (int64, bool) {
	i := bytes.IndexByte(line, ';')
	hex := line
	if i >= 0 {
		hex = line[:i]
	}
	hex = bytes.TrimSpace(hex)
	if len(hex) == 0 || len(hex) > 15 {
		return 0, false
	}
	var n int64
	for _, c := range hex {
		var d int64
		switch {
		case c >= '0' && c <= '9':
			d = int64(c - '0')
		case c >= 'a' && c <= 'f':
			d = int64(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = int64(c-'A') + 10
		default:
			return 0, false
		}
		n = n*16 + d
	}
	return n, true
}
