package flate

// RFC 1952 gzip members: a 10-byte header with optional fields, one raw
// DEFLATE stream, and an 8-byte trailer (CRC32 + ISIZE, little-endian).
// InflateGzip is the HTTP Content-Encoding: gzip consumer (M135b): the
// member structure is parsed here, the payload goes through Inflate, and
// both integrity fields are checked. The package stays dependency-free —
// the CRC32 is the same IEEE table the PNG reader verifies, implemented
// bitwise (the bodies this decodes are already cap-bounded).

var (
	errGzipMember = inflateErr("flate: invalid gzip member")
	errGzipCRC    = inflateErr("flate: gzip crc32 mismatch")
	errGzipSize   = inflateErr("flate: gzip isize mismatch")
)

// IsGzipIntegrity reports whether err is a gzip integrity refusal (CRC32
// or ISIZE mismatch) — what HTTP callers name gzip-crc.
func IsGzipIntegrity(err error) bool { return err == errGzipCRC || err == errGzipSize }

// IsOutputBound reports whether err means dst could not hold the stream
// — what HTTP callers name gzip-too-large.
func IsOutputBound(err error) bool { return err == errBufSmall }

const (
	gzipID1    = 0x1f
	gzipID2    = 0x8b
	gzipCM     = 8 // deflate
	gzipFText  = 0x01
	gzipFHCRC  = 0x02
	gzipFExtra = 0x04
	gzipFName  = 0x08
	gzipFComm  = 0x10
	// Bits 5–7 of FLG are reserved in RFC 1952 and must be zero.
	gzipFReserved = 0xe0
)

var crc32Table [256]uint32

func init() {
	for i := 0; i < 256; i++ {
		c := uint32(i)
		for j := 0; j < 8; j++ {
			if c&1 != 0 {
				c = 0xedb88320 ^ (c >> 1)
			} else {
				c >>= 1
			}
		}
		crc32Table[i] = c
	}
}

func crc32IEEE(data []byte) uint32 {
	c := uint32(0xffffffff)
	for _, b := range data {
		c = crc32Table[(c^uint32(b))&0xff] ^ (c >> 8)
	}
	return ^c
}

// gunzipHeader parses one member's header at the start of src. It returns
// the number of header bytes consumed. FEXTRA/FNAME/FCOMMENT/FHCRC are
// honored (FHCRC is verified against the header bytes); reserved FLG bits
// and a non-deflate compression method refuse.
func gunzipHeader(src []byte) (int, error) {
	if len(src) < 10 {
		return 0, errGzipMember
	}
	if src[0] != gzipID1 || src[1] != gzipID2 || src[2] != gzipCM {
		return 0, errGzipMember
	}
	flg := src[3]
	if flg&gzipFReserved != 0 {
		return 0, errGzipMember
	}
	pos := 10 // MTIME(4) + XFL + OS carry no semantics for a fetch client
	if flg&gzipFExtra != 0 {
		if pos+2 > len(src) {
			return 0, errGzipMember
		}
		xlen := int(src[pos]) | int(src[pos+1])<<8
		pos += 2
		if pos+xlen > len(src) {
			return 0, errGzipMember
		}
		pos += xlen
	}
	if flg&gzipFName != 0 {
		// zero-terminated original file name; the bytes are ignored
		i := pos
		for i < len(src) && src[i] != 0 {
			i++
		}
		if i >= len(src) {
			return 0, errGzipMember
		}
		pos = i + 1
	}
	if flg&gzipFComm != 0 {
		i := pos
		for i < len(src) && src[i] != 0 {
			i++
		}
		if i >= len(src) {
			return 0, errGzipMember
		}
		pos = i + 1
	}
	if flg&gzipFHCRC != 0 {
		if pos+2 > len(src) {
			return 0, errGzipMember
		}
		want := uint32(src[pos]) | uint32(src[pos+1])<<8
		if uint16(crc32IEEE(src[:pos])) != uint16(want) {
			return 0, errGzipMember
		}
		pos += 2
	}
	return pos, nil
}

// InflateGzip decompresses the RFC 1952 member(s) at the start of src
// into dst. A gzip file is a concatenation of members, so after each
// member's trailer is verified the reader steps to the next member and
// continues until src is exhausted. Returns the decoded length and the
// consumed input extent; CRC32 and ISIZE mismatches refuse by name.
func InflateGzip(dst, src []byte) (n, consumed int, err error) {
	for consumed < len(src) {
		hdr, err := gunzipHeader(src[consumed:])
		if err != nil {
			return 0, 0, err
		}
		body, used, err := Inflate(dst[n:], src[consumed+hdr:])
		if err != nil {
			return 0, 0, err
		}
		trailer := consumed + hdr + used
		if trailer+8 > len(src) {
			return 0, 0, errGzipMember
		}
		t := src[trailer:]
		crc := uint32(t[0]) | uint32(t[1])<<8 | uint32(t[2])<<16 | uint32(t[3])<<24
		isize := uint32(t[4]) | uint32(t[5])<<8 | uint32(t[6])<<16 | uint32(t[7])<<24
		if crc32IEEE(dst[n:n+body]) != crc {
			return 0, 0, errGzipCRC
		}
		if uint32(body) != isize {
			return 0, 0, errGzipSize
		}
		n += body
		consumed = trailer + 8
	}
	return n, consumed, nil
}
