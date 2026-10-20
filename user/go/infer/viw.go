package infer

// The VIW container — VirelaiOS Inference Weights (M111c, issue #2410).
//
// A self-contained model image: a key=value text header (architecture +
// licence receipt), a binary tokenizer blob, a fixed-size tensor
// directory, then the tensor payloads IN DIRECTORY ORDER so a guest with a
// sequential-only file seam (no seek anywhere in the syscall table) loads
// it in ONE pass. Every weight payload is stored in a form the GPU compute
// path consumes directly: DEQUANT-native u4asym/q8sym (packed nibbles or
// int8 + f32 scales + f32 zeros) or raw f16/f32. Nothing in this file
// imports a third-party format library OR the reflect-based JSON decoder —
// both stay outside the exec size cap; that is the card's hard requirement.
//
// Layout (all integers LE):
//
//	0    4   magic "VIW1"
//	4    4   header_len  (JSON header bytes)
//	8    4   tok_len     (JSON tokenizer blob bytes)
//	12   4   dir_count   (directory entries)
//	16   4   flags       (0)
//	20   44  reserved    (0)
//	64   ..  header block: `key value\n` lines (see Header)
//	..   ..  tokenizer blob: u32 kind, then kind-specific sections
//	..   ..  dir_count × 96B entries
//	..   ..  payloads, in directory order
//
// Directory entry (96 B):
//
//	0   32   name, zero-padded ASCII
//	32   1   fmt: 1 q8sym, 2 u4asym, 3 f16, 4 f32
//	33   1   nd: live dimension count (1..2)
//	34   1   group: DEQUANT group size (32/64/128; 0 for raw fmts)
//	35   1   reserved
//	36   16  dims u32[4]: row-major shape, unused = 0 (a 1-D tensor uses
//	         dims[0]=n only)
//	52   4   reserved
//	56   8   payload_off: absolute file offset
//	64   8   payload_len
//	72   24  reserved
//
// Payload layout per fmt (contiguous, this order — the same three spans a
// DEQUANT descriptor's buf0/buf1/buf2 slots point at):
//
//	q8sym:   [n int8][groups × f32 scales]
//	u4asym:  [ceil(n/2) nibbles, low first][groups × f32 scales][groups × f32 zeros]
//	f16/f32: raw little-endian elements
//
// groups = ceil(n/group).

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
)

const (
	viwMagic     = 0x31574956 // "VIW1" LE
	viwPrefixLen = 64
	viwDirEntLen = 96
	viwNameLen   = 32
	viwMaxHeader = 64 * 1024
	viwMaxTok    = 8 * 1024 * 1024
	viwMaxDir    = 1024
)

// Quantized payload formats — values 1 and 2 are the DEQUANT kernel's
// aux-fmt numbers (ADR 0053 D3); 3/4 are CPU-side raw spans.
const (
	viwFmtQ8Sym  byte = 1
	viwFmtU4Asym byte = 2
	viwFmtF16    byte = 3
	viwFmtF32    byte = 4
)

// Header is the text header — the architecture description the forward
// pass runs against plus the licence receipt the card demands. The block
// is `key value` lines, one per field; unknown keys refuse (a stale reader
// must not silently skip a field a newer writer needed).
type Header struct {
	Arch      string // "llama" — the only v1 family
	Dim       int
	Hidden    int
	Layers    int
	Heads     int
	KVHeads   int
	Vocab     int
	SeqCap    int    // runtime context bound (≤ model max)
	Rope      string // "half" (GPT-NeoX) or "interleaved" (llama2.c)
	RopeTheta float64
	RmsEps    float64
	Tie       bool // lm_head shares embed
	BOS       int
	EOS       int
	Model     ModelInfo
}

// ModelInfo is the licence receipt the owner-approval gate pins.
type ModelInfo struct {
	ID             string
	License        string
	Source         string
	UpstreamSHA256 string
	UpstreamBytes  int64
	TokSHA256      string
	StagedSHA256   string // filled at staging time
	Seed           uint64 // stub images only
}

// viwTensor is one parsed directory entry.
type viwTensor struct {
	Name   string
	Fmt    byte
	Group  uint32
	Dims   [2]uint32 // rows, cols (1-D: {n, 0})
	PayOff uint64
	PayLen uint64
}

// N returns the element count.
func (t viwTensor) N() uint64 {
	n := uint64(t.Dims[0])
	if t.Dims[1] > 0 {
		n *= uint64(t.Dims[1])
	}
	return n
}

// Groups returns the DEQUANT group count for the tensor.
func (t viwTensor) Groups() uint64 {
	if t.Group == 0 {
		return 0
	}
	return (t.N() + uint64(t.Group) - 1) / uint64(t.Group)
}

// packedLen returns the byte length of the packed (buf0) span.
func (t viwTensor) packedLen() uint64 {
	switch t.Fmt {
	case viwFmtU4Asym:
		return (t.N() + 1) / 2
	case viwFmtQ8Sym:
		return t.N()
	default:
		return 0
	}
}

// scalesOff/zerosOff give the span offsets INSIDE the payload.
func (t viwTensor) scalesOff() uint64 { return t.packedLen() }
func (t viwTensor) zerosOff() uint64  { return t.packedLen() + t.Groups()*4 }

// payloadLen computes the expected payload length for a tensor.
func payloadLen(fmtb byte, n, groups uint64) uint64 {
	switch fmtb {
	case viwFmtQ8Sym:
		return n + groups*4
	case viwFmtU4Asym:
		return (n+1)/2 + groups*8
	case viwFmtF16:
		return n * 2
	case viwFmtF32:
		return n * 4
	}
	return 0
}

// viwImage is a parsed container: header + tokenizer blob + directory.
// Payloads are NOT held — the loader routes each span as it streams past.
type viwImage struct {
	Header Header
	Tok    []byte
	Dir    []viwTensor
}

// readVIWHead parses the sequential prefix: magic → header JSON →
// tokenizer JSON → directory. The reader is left positioned at the first
// payload byte; payloads then arrive in directory order.
func readVIWHead(r io.Reader) (*viwImage, error) {
	pre := make([]byte, viwPrefixLen)
	if _, err := io.ReadFull(r, pre); err != nil {
		return nil, fmt.Errorf("viw prefix: %w", err)
	}
	if binary.LittleEndian.Uint32(pre[0:]) != viwMagic {
		return nil, errors.New("viw: bad magic")
	}
	hLen := binary.LittleEndian.Uint32(pre[4:])
	tLen := binary.LittleEndian.Uint32(pre[8:])
	dCnt := binary.LittleEndian.Uint32(pre[12:])
	flags := binary.LittleEndian.Uint32(pre[16:])
	if flags != 0 {
		return nil, errors.New("viw: nonzero flags")
	}
	if hLen == 0 || hLen > viwMaxHeader {
		return nil, fmt.Errorf("viw: header_len %d out of bound", hLen)
	}
	if tLen > viwMaxTok {
		return nil, fmt.Errorf("viw: tok_len %d out of bound", tLen)
	}
	if dCnt == 0 || dCnt > viwMaxDir {
		return nil, fmt.Errorf("viw: dir_count %d out of bound", dCnt)
	}
	for _, b := range pre[20:] {
		if b != 0 {
			return nil, errors.New("viw: nonzero reserved prefix")
		}
	}
	hb := make([]byte, hLen)
	if _, err := io.ReadFull(r, hb); err != nil {
		return nil, fmt.Errorf("viw header: %w", err)
	}
	var im viwImage
	h, err := parseHeader(hb)
	if err != nil {
		return nil, err
	}
	im.Header = h
	im.Tok = make([]byte, tLen)
	if _, err := io.ReadFull(r, im.Tok); err != nil {
		return nil, fmt.Errorf("viw tokenizer: %w", err)
	}
	dirLen := int(dCnt) * viwDirEntLen
	db := make([]byte, dirLen)
	if _, err := io.ReadFull(r, db); err != nil {
		return nil, fmt.Errorf("viw dir: %w", err)
	}
	im.Dir = make([]viwTensor, 0, dCnt)
	payOff := uint64(viwPrefixLen) + uint64(hLen) + uint64(tLen) + uint64(dirLen)
	for i := 0; i < int(dCnt); i++ {
		e := db[i*viwDirEntLen:]
		var name []byte
		for _, c := range e[:viwNameLen] {
			if c == 0 {
				break
			}
			name = append(name, c)
		}
		t := viwTensor{
			Name:   string(name),
			Fmt:    e[32],
			Group:  uint32(e[34]),
			PayOff: binary.LittleEndian.Uint64(e[56:]),
			PayLen: binary.LittleEndian.Uint64(e[64:]),
		}
		nd := int(e[33])
		if nd < 1 || nd > 2 {
			return nil, fmt.Errorf("viw dir[%d] %q: nd %d", i, t.Name, nd)
		}
		t.Dims[0] = binary.LittleEndian.Uint32(e[36:])
		if nd == 2 {
			t.Dims[1] = binary.LittleEndian.Uint32(e[40:])
		}
		switch t.Fmt {
		case viwFmtQ8Sym, viwFmtU4Asym:
			if t.Group != 32 && t.Group != 64 && t.Group != 128 {
				return nil, fmt.Errorf("viw dir[%d] %q: group %d", i, t.Name, t.Group)
			}
		case viwFmtF16, viwFmtF32:
			if t.Group != 0 {
				return nil, fmt.Errorf("viw dir[%d] %q: raw fmt with group", i, t.Name)
			}
		default:
			return nil, fmt.Errorf("viw dir[%d] %q: fmt %d", i, t.Name, t.Fmt)
		}
		if t.PayLen != payloadLen(t.Fmt, t.N(), t.Groups()) {
			return nil, fmt.Errorf("viw dir[%d] %q: payload_len %d want %d",
				i, t.Name, t.PayLen, payloadLen(t.Fmt, t.N(), t.Groups()))
		}
		if t.PayOff != payOff {
			return nil, fmt.Errorf("viw dir[%d] %q: payload_off %d want %d (dir order)",
				i, t.Name, t.PayOff, payOff)
		}
		payOff += t.PayLen
		im.Dir = append(im.Dir, t)
	}
	return &im, nil
}

// viwWrite is the container writer — the stub synthesizer and the
// staging converter share it, so the bytes a test produces are the bytes
// the loader consumes.
type viwWrite struct {
	header Header
	tok    []byte
	dir    []viwTensor
	pay    [][]byte
}

func newViwWrite(h Header, tok []byte) *viwWrite {
	return &viwWrite{header: h, tok: tok}
}

// add appends a tensor with an already-encoded payload.
func (w *viwWrite) add(name string, fmtb byte, group uint32, dims [2]uint32, payload []byte) {
	w.dir = append(w.dir, viwTensor{
		Name: name, Fmt: fmtb, Group: group, Dims: dims, PayLen: uint64(len(payload)),
	})
	w.pay = append(w.pay, payload)
}

// marshal emits the container — payloads in directory order.
func (w *viwWrite) marshal() []byte {
	hb := w.header.emit()
	out := make([]byte, 0, viwPrefixLen+len(hb)+len(w.tok)+len(w.dir)*viwDirEntLen)
	pre := make([]byte, viwPrefixLen)
	binary.LittleEndian.PutUint32(pre[0:], viwMagic)
	binary.LittleEndian.PutUint32(pre[4:], uint32(len(hb)))
	binary.LittleEndian.PutUint32(pre[8:], uint32(len(w.tok)))
	binary.LittleEndian.PutUint32(pre[12:], uint32(len(w.dir)))
	out = append(out, pre...)
	out = append(out, hb...)
	out = append(out, w.tok...)
	off := uint64(viwPrefixLen + len(hb) + len(w.tok) + len(w.dir)*viwDirEntLen)
	for i, t := range w.dir {
		e := make([]byte, viwDirEntLen)
		copy(e[:viwNameLen], t.Name)
		e[32] = t.Fmt
		nd := byte(1)
		if t.Dims[1] > 0 {
			nd = 2
		}
		e[33] = nd
		e[34] = byte(t.Group)
		binary.LittleEndian.PutUint32(e[36:], t.Dims[0])
		binary.LittleEndian.PutUint32(e[40:], t.Dims[1])
		binary.LittleEndian.PutUint64(e[56:], off)
		binary.LittleEndian.PutUint64(e[64:], uint64(len(w.pay[i])))
		out = append(out, e...)
		off += uint64(len(w.pay[i]))
	}
	for _, p := range w.pay {
		out = append(out, p...)
	}
	return out
}

// --- the text header block ----------------------------------------------------

// parseHeader reads the `key value` block — one field per line, unknown
// keys refused so a stale reader never silently drops a required field.
func parseHeader(b []byte) (Header, error) {
	var h Header
	intf := func(v string) (int, error) { return strconv.Atoi(v) }
	for _, ln := range strings.Split(string(b), "\n") {
		if ln == "" {
			continue
		}
		k, v, ok := strings.Cut(ln, " ")
		if !ok || v == "" {
			return h, fmt.Errorf("viw header: bad line %q", ln)
		}
		var err error
		switch k {
		case "arch":
			h.Arch = v
		case "dim":
			h.Dim, err = intf(v)
		case "hidden":
			h.Hidden, err = intf(v)
		case "layers":
			h.Layers, err = intf(v)
		case "heads":
			h.Heads, err = intf(v)
		case "kv_heads":
			h.KVHeads, err = intf(v)
		case "vocab":
			h.Vocab, err = intf(v)
		case "seq_cap":
			h.SeqCap, err = intf(v)
		case "rope":
			h.Rope = v
		case "rope_theta":
			h.RopeTheta, err = strconv.ParseFloat(v, 64)
		case "rms_eps":
			h.RmsEps, err = strconv.ParseFloat(v, 64)
		case "tie":
			h.Tie = v == "1"
		case "bos":
			h.BOS, err = intf(v)
		case "eos":
			h.EOS, err = intf(v)
		case "m_id":
			h.Model.ID = v
		case "m_license":
			h.Model.License = v
		case "m_source":
			h.Model.Source = v
		case "m_usha":
			h.Model.UpstreamSHA256 = v
		case "m_ubytes":
			var u uint64
			u, err = strconv.ParseUint(v, 10, 64)
			h.Model.UpstreamBytes = int64(u)
		case "m_tsha":
			h.Model.TokSHA256 = v
		case "m_ssha":
			h.Model.StagedSHA256 = v
		case "m_seed":
			h.Model.Seed, err = strconv.ParseUint(v, 10, 64)
		default:
			return h, fmt.Errorf("viw header: unknown key %q", k)
		}
		if err != nil {
			return h, fmt.Errorf("viw header %s: %q: %w", k, v, err)
		}
	}
	return h, nil
}

// emit writes the header block in a fixed key order — the byte-identical
// twin of what parseHeader reads (deterministic images hash cleanly).
func (h Header) emit() []byte {
	var sb strings.Builder
	put := func(k, v string) {
		sb.WriteString(k)
		sb.WriteByte(' ')
		sb.WriteString(v)
		sb.WriteByte('\n')
	}
	put("arch", h.Arch)
	put("dim", strconv.Itoa(h.Dim))
	put("hidden", strconv.Itoa(h.Hidden))
	put("layers", strconv.Itoa(h.Layers))
	put("heads", strconv.Itoa(h.Heads))
	put("kv_heads", strconv.Itoa(h.KVHeads))
	put("vocab", strconv.Itoa(h.Vocab))
	put("seq_cap", strconv.Itoa(h.SeqCap))
	put("rope", h.Rope)
	put("rope_theta", strconv.FormatFloat(h.RopeTheta, 'g', -1, 64))
	put("rms_eps", strconv.FormatFloat(h.RmsEps, 'g', -1, 64))
	if h.Tie {
		put("tie", "1")
	} else {
		put("tie", "0")
	}
	put("bos", strconv.Itoa(h.BOS))
	put("eos", strconv.Itoa(h.EOS))
	// Optional receipt fields emit only when present — an empty value is a
	// parse error, not a field.
	if h.Model.ID != "" {
		put("m_id", h.Model.ID)
	}
	if h.Model.License != "" {
		put("m_license", h.Model.License)
	}
	if h.Model.Source != "" {
		put("m_source", h.Model.Source)
	}
	if h.Model.UpstreamSHA256 != "" {
		put("m_usha", h.Model.UpstreamSHA256)
	}
	if h.Model.UpstreamBytes != 0 {
		put("m_ubytes", strconv.FormatInt(h.Model.UpstreamBytes, 10))
	}
	if h.Model.TokSHA256 != "" {
		put("m_tsha", h.Model.TokSHA256)
	}
	if h.Model.StagedSHA256 != "" {
		put("m_ssha", h.Model.StagedSHA256)
	}
	if h.Model.Seed != 0 {
		put("m_seed", strconv.FormatUint(h.Model.Seed, 10))
	}
	return []byte(sb.String())
}

// --- payload encoders --------------------------------------------------------

// quantU4Asym packs vals into the DEQUANT fmt-2 layout: unsigned nibbles
// (low first) + per-group f32 scale + f32 zero, out = (q − z)·s.
func quantU4Asym(vals []float32, group uint32) []byte {
	n := len(vals)
	groups := (n + int(group) - 1) / int(group)
	packed := make([]byte, (n+1)/2)
	scales := make([]byte, groups*4)
	zeros := make([]byte, groups*4)
	for g := 0; g < groups; g++ {
		lo, hi := g*int(group), (g+1)*int(group)
		if hi > n {
			hi = n
		}
		mn, mx := float32(math.Inf(1)), float32(math.Inf(-1))
		for _, v := range vals[lo:hi] {
			if v < mn {
				mn = v
			}
			if v > mx {
				mx = v
			}
		}
		s := (mx - mn) / 15
		var z float32
		if s == 0 {
			s = 1
			z = 0
		} else {
			z = float32(roundF32(-mn / s))
			if z < 0 {
				z = 0
			}
			if z > 15 {
				z = 15
			}
		}
		putF32(scales[g*4:], s)
		putF32(zeros[g*4:], z)
		for i := lo; i < hi; i++ {
			q := int(roundF32(vals[i]/s + z))
			if q < 0 {
				q = 0
			}
			if q > 15 {
				q = 15
			}
			if i&1 == 0 {
				packed[i/2] |= byte(q)
			} else {
				packed[i/2] |= byte(q) << 4
			}
		}
	}
	return append(append(packed, scales...), zeros...)
}

// dequantU4 decodes count elements starting at element off — the CPU-side
// mirror of the kernel (used for embedding-row gather). The group table is
// consulted per group.
func dequantU4(payload []byte, n uint64, group uint32, off, count uint64, out []float32) {
	groups := int((n + uint64(group) - 1) / uint64(group))
	s := payload[(n+1)/2 : (n+1)/2+uint64(groups)*4]
	z := payload[(n+1)/2+uint64(groups)*4:]
	for i := uint64(0); i < count; i++ {
		e := off + i
		gi := int(e / uint64(group))
		b := payload[e/2]
		var q int
		if e&1 == 0 {
			q = int(b & 0x0f)
		} else {
			q = int(b >> 4)
		}
		out[i] = (float32(q) - f32at(z, gi*4)) * f32at(s, gi*4)
	}
}

func putF32(b []byte, v float32) { binary.LittleEndian.PutUint32(b, math.Float32bits(v)) }
func f32at(b []byte, i int) float32 {
	return math.Float32frombits(binary.LittleEndian.Uint32(b[i:]))
}

func roundF32(f float32) float32 {
	if f < 0 {
		return float32(math.Ceil(float64(f) - 0.5))
	}
	return float32(math.Floor(float64(f) + 0.5))
}
