package gitread

// Git packfile v2: header, zlib-framed objects (including ofs/ref deltas),
// SHA-1 trailer. Delta resolution is required — a pack with no delta would
// not exercise the path the #1337 fixture exists to prove.

import "virelai/flate"

type packErr string

func (e packErr) Error() string { return string(e) }

var (
	errPackMagic = packErr("pack: bad magic")
	errPackVer   = packErr("pack: unsupported version")
	errPackTrunc = packErr("pack: truncated")
	errPackSum   = packErr("pack: checksum mismatch")
	errPackType  = packErr("pack: bad object type")
	errPackDelta = packErr("pack: delta resolve failed")
	errPackHuge  = packErr("pack: object past size cap")
	errPackCount = packErr("pack: object count mismatch")
)

const (
	ObjCommit   = 1
	ObjTree     = 2
	ObjBlob     = 3
	ObjTag      = 4
	ObjOfsDelta = 6
	ObjRefDelta = 7
	// One object and the HTTP response that carries the pack share the
	// 256 KiB guest file-read cap (vi.MaxFileBytes).
	maxObjSize = 256 * 1024
)

type GitObj struct {
	Type int
	Data []byte
	ID   [20]byte
}

func typeName(t int) string {
	switch t {
	case ObjCommit:
		return "commit"
	case ObjTree:
		return "tree"
	case ObjBlob:
		return "blob"
	case ObjTag:
		return "tag"
	default:
		return "obj"
	}
}

func HashObject(typ int, data []byte) [20]byte {
	hdr := typeName(typ) + " " + Uitoa(uint64(len(data))) + "\x00"
	buf := make([]byte, len(hdr)+len(data))
	copy(buf, hdr)
	copy(buf[len(hdr):], data)
	return sha1Sum(buf)
}

func Uitoa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

func be32(b []byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

type rawObj struct {
	typ     int
	off     int
	size    int
	data    []byte
	baseSHA [20]byte
	baseOff int
	delta   bool
	id      [20]byte
	done    bool
}

func ParsePack(buf []byte) ([]GitObj, int, error) {
	return parsePack(buf, nil)
}

// ParsePackThin is ParsePack for a FETCH pack (#2203): negotiated with the
// thin-pack capability, it may carry ref-deltas whose base the sender
// omitted because the client already holds it. lookup resolves those bases
// against the local object store; a miss fails the parse honestly (a delta
// never floats on a guessed base). A self-contained pack parses identically
// under either entry point.
func ParsePackThin(buf []byte, lookup func(id [20]byte) (GitObj, bool)) ([]GitObj, int, error) {
	return parsePack(buf, lookup)
}

func parsePack(buf []byte, lookup func(id [20]byte) (GitObj, bool)) ([]GitObj, int, error) {
	if len(buf) < 32 {
		return nil, 0, errPackTrunc
	}
	if string(buf[:4]) != "PACK" {
		return nil, 0, errPackMagic
	}
	if be32(buf[4:8]) != 2 {
		return nil, 0, errPackVer
	}
	nobj := int(be32(buf[8:12]))
	sum := sha1Sum(buf[:len(buf)-20])
	var trail [20]byte
	copy(trail[:], buf[len(buf)-20:])
	if sum != trail {
		return nil, 0, errPackSum
	}
	body := buf[12 : len(buf)-20]
	raw := make([]rawObj, 0, nobj)
	pos := 0
	nDelta := 0
	for i := 0; i < nobj; i++ {
		if pos >= len(body) {
			return nil, 0, errPackTrunc
		}
		o, n, err := readOne(body[pos:], 12+pos)
		if err != nil {
			return nil, 0, err
		}
		if o.delta {
			nDelta++
		}
		raw = append(raw, o)
		pos += n
	}
	if pos != len(body) {
		return nil, 0, errPackCount
	}
	if err := resolveDeltas(raw, lookup); err != nil {
		return nil, 0, err
	}
	out := make([]GitObj, len(raw))
	for i := range raw {
		out[i] = GitObj{Type: raw[i].typ, Data: raw[i].data, ID: raw[i].id}
	}
	return out, nDelta, nil
}

func readOne(b []byte, absOff int) (rawObj, int, error) {
	typ, size, hdrN, err := readPackHdr(b)
	if err != nil {
		return rawObj{}, 0, err
	}
	if size < 0 || size > maxObjSize {
		return rawObj{}, 0, errPackHuge
	}
	o := rawObj{typ: typ, off: absOff, size: size}
	rest := b[hdrN:]
	used := hdrN
	switch typ {
	case ObjOfsDelta:
		back, n, err := readOfsDelta(rest)
		if err != nil {
			return rawObj{}, 0, err
		}
		o.baseOff = absOff - back
		o.delta = true
		rest = rest[n:]
		used += n
	case ObjRefDelta:
		if len(rest) < 20 {
			return rawObj{}, 0, errPackTrunc
		}
		copy(o.baseSHA[:], rest[:20])
		o.delta = true
		rest = rest[20:]
		used += 20
	case ObjCommit, ObjTree, ObjBlob, ObjTag:
	default:
		return rawObj{}, 0, errPackType
	}
	out := make([]byte, size)
	n, consumed, err := flate.InflateZlib(out, rest)
	if err != nil {
		return rawObj{}, 0, err
	}
	if n != size {
		return rawObj{}, 0, errPackTrunc
	}
	o.data = out[:n]
	used += consumed
	return o, used, nil
}

func readPackHdr(b []byte) (typ, size, n int, err error) {
	if len(b) == 0 {
		return 0, 0, 0, errPackTrunc
	}
	c := b[0]
	typ = int((c >> 4) & 7)
	size = int(c & 15)
	n = 1
	shift := 4
	for c&0x80 != 0 {
		if n >= len(b) {
			return 0, 0, 0, errPackTrunc
		}
		c = b[n]
		n++
		size |= int(c&0x7f) << shift
		shift += 7
		if shift > 28 {
			return 0, 0, 0, errPackHuge
		}
	}
	return typ, size, n, nil
}

func readOfsDelta(b []byte) (off, n int, err error) {
	if len(b) == 0 {
		return 0, 0, errPackTrunc
	}
	c := b[0]
	n = 1
	off = int(c & 0x7f)
	for c&0x80 != 0 {
		if n >= len(b) {
			return 0, 0, errPackTrunc
		}
		c = b[n]
		n++
		off++
		off = (off << 7) + int(c&0x7f)
	}
	if off <= 0 {
		return 0, 0, errPackDelta
	}
	return off, n, nil
}

func resolveDeltas(raw []rawObj, lookup func(id [20]byte) (GitObj, bool)) error {
	byOff := make(map[int]int, len(raw))
	for i := range raw {
		byOff[raw[i].off] = i
	}
	progress := true
	for progress {
		progress = false
		for i := range raw {
			if raw[i].done {
				continue
			}
			if !raw[i].delta {
				raw[i].id = HashObject(raw[i].typ, raw[i].data)
				raw[i].done = true
				progress = true
				continue
			}
			base, ok := findBase(raw, byOff, &raw[i])
			if ok && base.done {
				out, err := applyDelta(base.data, raw[i].data)
				if err != nil {
					return err
				}
				raw[i].typ = base.typ
				raw[i].data = out
				raw[i].id = HashObject(raw[i].typ, out)
				raw[i].delta = false
				raw[i].done = true
				progress = true
				continue
			}
			// Thin pack: a ref-delta base the sender left out lives in
			// the object store the client already holds.
			if !ok && lookup != nil && raw[i].typ == ObjRefDelta {
				if ext, eok := lookup(raw[i].baseSHA); eok {
					out, err := applyDelta(ext.Data, raw[i].data)
					if err != nil {
						return err
					}
					raw[i].typ = ext.Type
					raw[i].data = out
					raw[i].id = HashObject(raw[i].typ, out)
					raw[i].delta = false
					raw[i].done = true
					progress = true
				}
			}
		}
	}
	for i := range raw {
		if !raw[i].done {
			return errPackDelta
		}
	}
	return nil
}

func findBase(raw []rawObj, byOff map[int]int, o *rawObj) (*rawObj, bool) {
	if o.typ == ObjOfsDelta || o.baseOff != 0 && o.baseSHA == [20]byte{} {
		idx, ok := byOff[o.baseOff]
		if !ok {
			return nil, false
		}
		return &raw[idx], true
	}
	for i := range raw {
		if raw[i].done && raw[i].id == o.baseSHA {
			return &raw[i], true
		}
	}
	return nil, false
}

func applyDelta(base, delta []byte) ([]byte, error) {
	srcSize, n, ok := readDeltaVar(delta)
	if !ok {
		return nil, errPackDelta
	}
	dstSize, m, ok := readDeltaVar(delta[n:])
	if !ok {
		return nil, errPackDelta
	}
	if srcSize != len(base) || dstSize > maxObjSize {
		return nil, errPackDelta
	}
	p := n + m
	out := make([]byte, 0, dstSize)
	for p < len(delta) {
		cmd := delta[p]
		p++
		if cmd == 0 {
			return nil, errPackDelta
		}
		if cmd&0x80 != 0 {
			off, sz := 0, 0
			if cmd&0x01 != 0 {
				if p >= len(delta) {
					return nil, errPackDelta
				}
				off = int(delta[p])
				p++
			}
			if cmd&0x02 != 0 {
				if p >= len(delta) {
					return nil, errPackDelta
				}
				off |= int(delta[p]) << 8
				p++
			}
			if cmd&0x04 != 0 {
				if p >= len(delta) {
					return nil, errPackDelta
				}
				off |= int(delta[p]) << 16
				p++
			}
			if cmd&0x08 != 0 {
				if p >= len(delta) {
					return nil, errPackDelta
				}
				off |= int(delta[p]) << 24
				p++
			}
			if cmd&0x10 != 0 {
				if p >= len(delta) {
					return nil, errPackDelta
				}
				sz = int(delta[p])
				p++
			}
			if cmd&0x20 != 0 {
				if p >= len(delta) {
					return nil, errPackDelta
				}
				sz |= int(delta[p]) << 8
				p++
			}
			if cmd&0x40 != 0 {
				if p >= len(delta) {
					return nil, errPackDelta
				}
				sz |= int(delta[p]) << 16
				p++
			}
			if sz == 0 {
				sz = 0x10000
			}
			if off < 0 || sz < 0 || off+sz > len(base) {
				return nil, errPackDelta
			}
			out = append(out, base[off:off+sz]...)
			continue
		}
		nins := int(cmd)
		if p+nins > len(delta) {
			return nil, errPackDelta
		}
		out = append(out, delta[p:p+nins]...)
		p += nins
	}
	if len(out) != dstSize {
		return nil, errPackDelta
	}
	return out, nil
}

func readDeltaVar(b []byte) (int, int, bool) {
	x, shift, n := 0, 0, 0
	for {
		if n >= len(b) || shift > 28 {
			return 0, 0, false
		}
		c := b[n]
		n++
		x |= int(c&0x7f) << shift
		if c&0x80 == 0 {
			return x, n, true
		}
		shift += 7
	}
}

func encodePackHdr(typ, size int) []byte {
	var out [16]byte
	n := 0
	b := byte((typ&7)<<4) | byte(size&15)
	size >>= 4
	for size != 0 {
		out[n] = b | 0x80
		n++
		b = byte(size & 0x7f)
		size >>= 7
	}
	out[n] = b
	n++
	return append([]byte{}, out[:n]...)
}

func encodeDeltaVar(v int) []byte {
	var out [8]byte
	n := 0
	for {
		b := byte(v & 0x7f)
		v >>= 7
		if v != 0 {
			b |= 0x80
			out[n] = b
			n++
			continue
		}
		out[n] = b
		n++
		return append([]byte{}, out[:n]...)
	}
}

// encodeDelta builds a copy+insert delta of target against base. Used by
// host tests to pin that applyDelta actually copies.
func encodeDelta(base, target []byte) []byte {
	prefix := 0
	for prefix < len(base) && prefix < len(target) && base[prefix] == target[prefix] {
		prefix++
	}
	out := append(encodeDeltaVar(len(base)), encodeDeltaVar(len(target))...)
	if prefix > 0 {
		cmd := byte(0x80)
		var extra [4]byte
		en := 0
		off := prefix // we copy from 0
		_ = off
		// copy offset 0, size prefix
		sz := prefix
		if sz != 0 {
			extra[en] = byte(sz)
			en++
			cmd |= 0x10
			if sz > 0xff {
				extra[en] = byte(sz >> 8)
				en++
				cmd |= 0x20
			}
			if sz > 0xffff {
				extra[en] = byte(sz >> 16)
				en++
				cmd |= 0x40
			}
		}
		out = append(out, cmd)
		out = append(out, extra[:en]...)
	}
	rest := target[prefix:]
	for len(rest) > 0 {
		n := len(rest)
		if n > 127 {
			n = 127
		}
		out = append(out, byte(n))
		out = append(out, rest[:n]...)
		rest = rest[n:]
	}
	return out
}

func PackObjects(objs []GitObj, deltaFrom []int, ofsDelta []bool) []byte {
	var body []byte
	offs := make([]int, len(objs))
	for i, o := range objs {
		offs[i] = 12 + len(body)
		if deltaFrom != nil && i < len(deltaFrom) && deltaFrom[i] >= 0 {
			base := objs[deltaFrom[i]]
			d := encodeDelta(base.Data, o.Data)
			z := flate.ZlibStore(d)
			useOfs := ofsDelta != nil && i < len(ofsDelta) && ofsDelta[i]
			if useOfs {
				back := offs[i] - offs[deltaFrom[i]]
				body = append(body, encodePackHdr(ObjOfsDelta, len(d))...)
				body = append(body, encodeOfs(back)...)
			} else {
				body = append(body, encodePackHdr(ObjRefDelta, len(d))...)
				id := base.ID
				if id == [20]byte{} {
					id = HashObject(base.Type, base.Data)
				}
				body = append(body, id[:]...)
			}
			body = append(body, z...)
			continue
		}
		z := flate.ZlibStore(o.Data)
		body = append(body, encodePackHdr(o.Type, len(o.Data))...)
		body = append(body, z...)
	}
	hdr := make([]byte, 12)
	copy(hdr, "PACK")
	putBE32(hdr[4:], 2)
	putBE32(hdr[8:], uint32(len(objs)))
	all := append(hdr, body...)
	sum := sha1Sum(all)
	return append(all, sum[:]...)
}

func encodeOfs(back int) []byte {
	// Inverse of readOfsDelta.
	var tmp [16]byte
	n := 0
	tmp[n] = byte(back & 0x7f)
	n++
	back >>= 7
	for back != 0 {
		back--
		tmp[n] = byte(back&0x7f) | 0x80
		n++
		back >>= 7
	}
	out := make([]byte, n)
	for i := 0; i < n; i++ {
		out[i] = tmp[n-1-i]
	}
	return out
}
