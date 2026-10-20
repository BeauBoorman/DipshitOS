package infer

// The model image: a parsed VIW directory plus where every tensor landed.
// The guest has a sequential-only file seam, so loading is ONE pass over
// the payloads in directory order — norms and the tied embedding stay in
// guest RAM (the CPU gathers rows and applies norms), every transformer
// weight streams through the bounded staging window into a sealed
// weight-class buffer where the Metal copy is authoritative and the guest
// share is released (ADR 0053 D4/D7).

import (
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"virelai/gpu3d"
)

// Dev is the compute-session seam the engine drives — *gpu3d.ComputeSession
// satisfies it on the guest; tests substitute a kernel-emulating fake.
type Dev interface {
	AllocBuffer(size uint32, weight bool) (uint64, error)
	FreeBuffer(buf uint64) error
	SealBuffer(buf uint64) error
	Write(buf uint64, off uint64, data []byte) error
	Read(buf uint64, off uint64, out []byte) error
	Run(kd gpu3d.KernelDesc) error
	Stats() (gpu3d.ComputeStatsBlock, error)
	Close() error
}

// The v1 tensor vocabulary — names the converter and the stub writer must
// produce. wqkv is the fused [QH·dh + 2·KVH·dh, dim] query/key/value
// matrix; w13 the fused [2·hidden, dim] gate|up matrix. Fusions keep the
// exchange count inside the ADR's one-outstanding-request budget.
const (
	tEmbed   = "embed"
	tFinalN  = "final_norm"
	tAttnN   = "attn_norm"
	tFfnN    = "ffn_norm"
	tWqkv    = "wqkv"
	tWo      = "wo"
	tW13     = "w13"
	tW2      = "w2"
	layerPfx = "l"
	maxWBuf  = 16 * 1024 * 1024 // capset max_buffer_bytes
	maxWBufs = 16               // capset max_buffers_per_ctx
	stubSeed = 0x5eed5eed5eed001
)

// devTensor is a device-resident weight: the buffer plus the three span
// offsets a DEQUANT descriptor binds (packed/scales/zeros within the
// buffer) and the f16 extent it dequantizes to.
type devTensor struct {
	name  string
	buf   uint64
	pOff  uint32 // packed span offset inside buf
	sOff  uint32 // scales span offset
	zOff  uint32 // zeros span offset (0 for q8sym — buf2 absent)
	n     uint64 // elements
	group uint32
	fmt   byte
	rows  uint32 // logical [rows, cols] for GEMM B (cols = 0 for 1-D)
	cols  uint32
}

// layerW is one transformer's device tensors plus its CPU norms.
type layerW struct {
	attnNorm []float32
	attnRaw  *[]byte // load-time accumulator
	wqkv     devTensor
	wo       devTensor
	ffnNorm  []float32
	ffnRaw   *[]byte
	w13      devTensor
	w2       devTensor
}

// Model is a loaded image: config, CPU-side tensors, device tensors and
// the weight buffers that own them. The session the weights were sealed
// onto is held for Generate and Close; the caller still owns its Close.
type Model struct {
	cfg       Header
	tok       Tokenizer
	s         Dev     // the load-time compute session
	eng       *engine // scratch, lazily allocated by the first Generate
	embed     []byte  // guest-resident payload [packed|scales|zeros]
	embedN    uint64  // V·D elements
	embedGrp  uint32
	finalNorm []float32
	finalRaw  *[]byte // load-time accumulator
	embedRaw  *[]byte
	layers    []layerW
	wbufs     []uint64 // weight buffers, for FreeBuffer on Close
	params    uint64   // total elements, for receipts
}

// headDim is the per-head attention width.
func (m *Model) headDim() int { return m.cfg.Dim / m.cfg.Heads }

// qkvDim is the fused q|k|v row width.
func (m *Model) qkvDim() int {
	dh := m.headDim()
	return (m.cfg.Heads + 2*m.cfg.KVHeads) * dh
}

// freeBuffers releases the weight buffers (sealed or not); called on load
// failure and on Close before the session ends.
func (m *Model) freeBuffers() {
	for _, h := range m.wbufs {
		_ = m.s.FreeBuffer(h)
	}
	m.wbufs = nil
}

// checkArch refuses anything outside the v1 llama-family envelope.
func (m *Model) checkArch() error {
	c := m.cfg
	if c.Arch != "llama" {
		return fmt.Errorf("viw arch %q", c.Arch)
	}
	for _, bad := range []struct {
		name string
		v    int
	}{{"dim", c.Dim}, {"hidden", c.Hidden}, {"layers", c.Layers},
		{"heads", c.Heads}, {"kv_heads", c.KVHeads}, {"vocab", c.Vocab},
		{"seq_cap", c.SeqCap}} {
		if bad.v <= 0 {
			return fmt.Errorf("viw %s %d", bad.name, bad.v)
		}
	}
	if c.Dim%c.Heads != 0 || c.Heads%c.KVHeads != 0 {
		return fmt.Errorf("viw dims: heads %d into dim %d, kv %d into heads",
			c.Heads, c.Dim, c.KVHeads)
	}
	if c.Rope != "half" && c.Rope != "interleaved" {
		return fmt.Errorf("viw rope %q", c.Rope)
	}
	if c.Vocab > 49152 || c.SeqCap > 4096 || c.Dim > 4096 || c.Hidden > 4096 {
		return errors.New("viw dims exceed the kernel bounds")
	}
	return nil
}

// layerIndex parses "l<N>." prefixes; -1 when the name has none.
func layerIndex(name string) int {
	if !strings.HasPrefix(name, layerPfx) {
		return -1
	}
	dot := strings.IndexByte(name, '.')
	if dot < 0 {
		return -1
	}
	n, err := strconv.Atoi(name[len(layerPfx):dot])
	if err != nil {
		return -1
	}
	return n
}

// loadModel streams the VIW payloads from r (already positioned past the
// directory by readVIWHead), routing each by name: norms and the tied
// embedding to guest RAM, every transformer weight through staging into
// weight-pack buffers that are sealed as the pass completes. stageBytes
// bounds the read chunk (a WRITE's own staging is smaller; chunking is
// the client's problem, the kernel's is the 4 MiB window).
func loadModel(im *viwImage, r io.Reader, s Dev, stageBytes int) (*Model, error) {
	m := &Model{cfg: im.Header, s: s}
	if err := m.checkArch(); err != nil {
		return nil, err
	}
	m.layers = make([]layerW, m.cfg.Layers)

	// Pass 1: the directory is fully known before any payload arrives, so
	// the pack plan (which buffer, which offset) is computable up front.
	plan := make(map[string]*devTensor)
	var pack []uint32
	for _, t := range im.Dir {
		if isGuestTensor(t.Name) {
			continue
		}
		if t.PayLen > maxWBuf {
			return nil, fmt.Errorf("tensor %s: %d bytes exceeds a weight buffer", t.Name, t.PayLen)
		}
		idx := len(pack) - 1
		if idx < 0 || pack[idx]+uint32(t.PayLen) > maxWBuf {
			if len(pack) >= maxWBufs-4 { // leave scratch/io headroom
				return nil, fmt.Errorf("model needs more than %d weight buffers", maxWBufs-4)
			}
			pack = append(pack, 0)
			idx++
		}
		dt := &devTensor{
			name: t.Name, buf: uint64(idx), pOff: pack[idx],
			n: t.N(), group: t.Group, fmt: t.Fmt, rows: t.Dims[0], cols: t.Dims[1],
		}
		dt.sOff = dt.pOff + uint32(t.packedLen())
		if t.Fmt == viwFmtU4Asym {
			dt.zOff = dt.sOff + uint32(t.Groups())*4
		}
		pack[idx] += uint32(t.PayLen)
		plan[t.Name] = dt
	}

	m.wbufs = make([]uint64, len(pack))
	for i := range pack {
		h, err := s.AllocBuffer(pack[i], gpu3d.BufWeight)
		if err != nil {
			m.freeBuffers()
			return nil, fmt.Errorf("weight buffer %d: %w", i, err)
		}
		m.wbufs[i] = h
	}
	for _, dt := range plan {
		dt.buf = m.wbufs[dt.buf]
	}

	// Pass 2: payloads arrive in directory order.
	scratch := make([]byte, stageBytes)
	for _, t := range im.Dir {
		dst := m.tensorDest(t)
		left := t.PayLen
		for left > 0 {
			n := uint64(len(scratch))
			if left < n {
				n = left
			}
			if _, err := io.ReadFull(r, scratch[:n]); err != nil {
				m.freeBuffers()
				return nil, fmt.Errorf("tensor %s: %w", t.Name, err)
			}
			if dst != nil {
				*dst = append(*dst, scratch[:n]...)
			} else {
				dt := plan[t.Name]
				if err := s.Write(dt.buf, uint64(dt.pOff)+(t.PayLen-left), scratch[:n]); err != nil {
					m.freeBuffers()
					return nil, fmt.Errorf("tensor %s upload: %w", t.Name, err)
				}
			}
			left -= n
		}
		m.params += t.N()
	}

	// Resolve device tensors into the layer slots.
	for _, t := range im.Dir {
		dt, ok := plan[t.Name]
		if !ok {
			continue
		}
		li := layerIndex(t.Name)
		if li < 0 || li >= m.cfg.Layers {
			continue
		}
		lw := &m.layers[li]
		switch t.Name[strings.IndexByte(t.Name, '.')+1:] {
		case tWqkv:
			lw.wqkv = *dt
		case tWo:
			lw.wo = *dt
		case tW13:
			lw.w13 = *dt
		case tW2:
			lw.w2 = *dt
		}
	}

	// Seal every weight buffer: the Metal copy is authoritative from here
	// and the guest staging share is released (ADR D4).
	for _, h := range m.wbufs {
		if err := s.SealBuffer(h); err != nil {
			m.freeBuffers()
			return nil, fmt.Errorf("seal: %w", err)
		}
	}

	// Materialize CPU-side tensors.
	if m.embedRaw == nil {
		m.freeBuffers()
		return nil, errors.New("viw: no embed tensor")
	}
	m.embed = *m.embedRaw
	m.embedN = uint64(m.cfg.Vocab) * uint64(m.cfg.Dim)
	for _, t := range im.Dir {
		if t.Name == tEmbed {
			m.embedGrp = t.Group
		}
	}
	if m.embedGrp == 0 || uint64(m.cfg.Dim)%uint64(m.embedGrp) != 0 {
		m.freeBuffers()
		return nil, errors.New("viw: embed group must divide dim (row-sliced by lm_head)")
	}
	if m.finalRaw != nil {
		m.finalNorm = bytesToF32(*m.finalRaw)
		m.finalRaw = nil
	}
	if len(m.finalNorm) != m.cfg.Dim {
		m.freeBuffers()
		return nil, errors.New("viw: final_norm missing or wrong size")
	}
	for li := range m.layers {
		lw := &m.layers[li]
		if lw.attnRaw == nil || lw.ffnRaw == nil || lw.wqkv.buf == 0 ||
			lw.wo.buf == 0 || lw.w13.buf == 0 || lw.w2.buf == 0 {
			m.freeBuffers()
			return nil, fmt.Errorf("viw: layer %d incomplete", li)
		}
		lw.attnNorm = bytesToF32(*lw.attnRaw)
		lw.ffnNorm = bytesToF32(*lw.ffnRaw)
		lw.attnRaw, lw.ffnRaw = nil, nil
		if len(lw.attnNorm) != m.cfg.Dim || len(lw.ffnNorm) != m.cfg.Dim {
			m.freeBuffers()
			return nil, fmt.Errorf("viw: layer %d norm wrong size", li)
		}
	}
	return m, nil
}

// tensorDest decides a payload's destination: a guest-side accumulator
// (norms, embed) or nil — device weight. Accumulators are preallocated to
// the payload length so the streamed append never doubles past its size.
func (m *Model) tensorDest(t viwTensor) *[]byte {
	switch t.Name {
	case tEmbed:
		b := make([]byte, 0, t.PayLen)
		m.embedRaw = &b
		return m.embedRaw
	case tFinalN:
		b := make([]byte, 0, t.PayLen)
		m.finalRaw = &b
		return m.finalRaw
	}
	if li := layerIndex(t.Name); li >= 0 && li < m.cfg.Layers {
		lw := &m.layers[li]
		sub := t.Name[strings.IndexByte(t.Name, '.')+1:]
		switch sub {
		case tAttnN:
			b := make([]byte, 0, t.PayLen)
			lw.attnRaw = &b
			return lw.attnRaw
		case tFfnN:
			b := make([]byte, 0, t.PayLen)
			lw.ffnRaw = &b
			return lw.ffnRaw
		}
	}
	return nil // device weight
}

func isGuestTensor(name string) bool {
	if name == tEmbed || name == tFinalN {
		return true
	}
	li := layerIndex(name)
	if li < 0 {
		return false
	}
	sub := name[strings.IndexByte(name, '.')+1:]
	return sub == tAttnN || sub == tFfnN
}

func bytesToF32(b []byte) []float32 {
	out := make([]float32, len(b)/4)
	for i := range out {
		out[i] = f32at(b, i*4)
	}
	return out
}

// --- the deterministic stub image --------------------------------------------

// xorshift64* — the stub's deterministic weight source. Same bytes on the
// host tests and the guest, always.
type xrand struct{ s uint64 }

func (x *xrand) next() uint64 {
	x.s ^= x.s << 13
	x.s ^= x.s >> 7
	x.s ^= x.s << 17
	return x.s * 0x2545F4914F6CDD1D
}

// f32 in [-amp, amp).
func (x *xrand) f32(amp float32) float32 {
	v := float32(x.next()>>40) / float32(1<<24)
	return (v*2 - 1) * amp
}

// StubDims is the stub model's shape: tiny enough that a K=5 leg finishes
// in seconds, real enough that every kernel and every forward stage runs.
const (
	stubDim     = 64
	stubHidden  = 128
	stubLayers  = 2
	stubHeads   = 4
	stubKVHeads = 4
	stubVocab   = 256
	stubSeq     = 256 // ≥ the fixed model prompt so a stub-staged model run fits
	stubGroup   = 32  // weight quantization group
)

// SynthStub builds a VIW image in memory: small dims, byte-level
// tokenizer, and PRNG weights quantized with the same encoder the
// converter uses. The loader then runs the production path end to end —
// the only thing "stub" about it is where the bytes came from.
// SynthStub is the production stub image: the amplitudes are tuned so the
// hidden state is weight-driven rather than embedding-dominated — a real
// greedy decode then produces a VARIED (still fully deterministic) token
// stream, which is what the leg pins.
func SynthStub() []byte { return synthStubAmps(0.05, 0.2) }

func synthStubAmps(ea, wa float32) []byte {
	const (
		dim, hid, L   = stubDim, stubHidden, stubLayers
		qh, kvh, V, S = stubHeads, stubKVHeads, stubVocab, stubSeq
	)
	x := &xrand{s: stubSeed}
	mat := func(rows, cols int, amp float32) []float32 {
		out := make([]float32, rows*cols)
		for i := range out {
			out[i] = x.f32(amp)
		}
		return out
	}
	norm := func(n int) []float32 {
		out := make([]float32, n)
		for i := range out {
			out[i] = 0.8 + x.f32(0.2)
		}
		return out
	}
	f32pay := func(v []float32) []byte {
		b := make([]byte, len(v)*4)
		for i, e := range v {
			putF32(b[i*4:], e)
		}
		return b
	}

	h := Header{
		Arch: "llama", Dim: dim, Hidden: hid, Layers: L,
		Heads: qh, KVHeads: kvh, Vocab: V, SeqCap: S,
		Rope: "half", RopeTheta: 10000, RmsEps: 1e-5,
		Tie: true, BOS: 1, EOS: 2,
		Model: ModelInfo{
			ID: "goinfer-stub", License: "VirelaiOS (synthetic)",
			Source: "in-image PRNG", Seed: stubSeed,
		},
	}
	w := newViwWrite(h, tokEmitBytes(1, 2))
	// embed needs group | dim for row-slicing (lm_head chunks): 64 | 64.
	w.add(tEmbed, viwFmtU4Asym, 64, [2]uint32{V, dim},
		quantU4Asym(mat(V, dim, ea), 64))
	w.add(tFinalN, viwFmtF32, 0, [2]uint32{dim, 0}, f32pay(norm(dim)))
	for l := 0; l < L; l++ {
		p := fmt.Sprintf("l%d.", l)
		dh := dim / qh
		w.add(p+tAttnN, viwFmtF32, 0, [2]uint32{dim, 0}, f32pay(norm(dim)))
		w.add(p+tWqkv, viwFmtU4Asym, stubGroup,
			[2]uint32{uint32((qh + 2*kvh) * dh), uint32(dim)},
			quantU4Asym(mat((qh+2*kvh)*dh, dim, wa), stubGroup))
		w.add(p+tWo, viwFmtU4Asym, stubGroup, [2]uint32{uint32(dim), uint32(qh * dh)},
			quantU4Asym(mat(dim, qh*dh, wa), stubGroup))
		w.add(p+tFfnN, viwFmtF32, 0, [2]uint32{dim, 0}, f32pay(norm(dim)))
		w.add(p+tW13, viwFmtU4Asym, stubGroup, [2]uint32{2 * hid, uint32(dim)},
			quantU4Asym(mat(2*hid, dim, wa), stubGroup))
		w.add(p+tW2, viwFmtU4Asym, stubGroup, [2]uint32{uint32(dim), uint32(hid)},
			quantU4Asym(mat(dim, hid, wa), stubGroup))
	}
	return w.marshal()
}
