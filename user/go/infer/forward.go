package infer

// The forward engine: one decode step per position, every matmul and the
// logits softmax on the GPU compute path — DEQUANT produces f16 weights,
// GEMM multiplies them, SOFTMAX normalizes the vocab head (the shape its
// 49152-column bound was pinned for). RMSNorm, RoPE, residual adds, SiLU
// and the per-head attention softmax run on the guest CPU — the elementwise
// work ADR 0053 deliberately keeps off the wire.
//
// Buffer plan (the kernel broker allocates, never the app):
//
//	wbufs[]  sealed weight-pack buffers — the model, device-resident
//	w16      weight-class f16 scratch — DEQUANT's landing zone per matmul
//	io       one I/O buffer partitioned by offset:
//	           xn | q | att | h13 | h2 | scores | probs | out | logits
//	           | kc | vc | hpack | probs32
//
// One io buffer works because every kernel binding is a {buf, byte_off}
// pair — offsets into a shared region are the ABI's own mechanism.

import (
	"errors"
	"math"

	"virelai/gpu3d"
	"virelai/vi"
)

// ioOff partitions the single I/O buffer.
type ioOff struct {
	xn, q, att, h13, h2, scores, probs, out uint32
	kc, vc, hpack, probs32, logits          uint32
	total                                   uint32
}

// engine owns a live session plus its scratch buffers.
type engine struct {
	s    Dev
	m    *Model
	w16  uint64 // f16 dequant scratch (weight-class)
	io   uint64 // the shared I/O buffer
	off  ioOff
	lmRs int // lm_head slice rows per GEMM (≤4096, sized to w16)
	// guest-side KV cache, f16, [layers][kv_heads][seq_cap][head_dim] —
	// token-major rows so a position append is one contiguous span.
	kc, vc []uint16
	// per-step scratch (no per-token allocs)
	x, xn, qkv, att, h13, h2, out []float32
	scores                        []float32
	logits                        []float32
}

// layout computes the io partition for cfg. Returns total bytes.
func (m *Model) layout(lmRs int) ioOff {
	dh := m.headDim()
	c := m.cfg
	var o ioOff
	at := uint32(0)
	take := func(n uint32) uint32 {
		p := at
		at += n
		return p
	}
	f16 := func(n int) uint32 { return uint32(n) * 2 }
	o.xn = take(f16(c.Dim))
	o.q = take(f16(c.Heads * dh))
	o.att = take(f16(c.Heads * dh))
	o.h13 = take(f16(2 * c.Hidden))
	o.h2 = take(f16(c.Hidden))
	qg := c.Heads / c.KVHeads
	o.scores = take(f16(qg * c.SeqCap))
	o.probs = take(f16(qg * c.SeqCap))
	o.out = take(f16(c.Dim))
	o.kc = take(f16(c.KVHeads * c.SeqCap * dh))
	o.vc = take(f16(c.KVHeads * c.SeqCap * dh))
	pk := uint32(lmRs*c.Dim) / 2
	sz := uint32(lmRs*c.Dim/int(m.embedGrp)) * 8
	o.hpack = take(pk + sz + 16)
	o.probs32 = take(uint32(c.Vocab) * 4)
	o.logits = take(f16(c.Vocab))
	o.total = at
	return o
}

// newEngine allocates scratch on the session. The model's weight buffers
// are already sealed.
func newEngine(s Dev, m *Model) (*engine, error) {
	// w16 must hold the largest single dequanted tensor: w13 [2H, D] or an
	// lm_head slice, whichever is bigger.
	big := uint64(0)
	for li := range m.layers {
		for _, t := range []*devTensor{&m.layers[li].wqkv, &m.layers[li].wo,
			&m.layers[li].w13, &m.layers[li].w2} {
			if b := t.n * 2; b > big {
				big = b
			}
		}
	}
	// w16 holds ONE dequanted tensor at a time, so the lm_head slice bound
	// is capacity alone (not capacity minus the largest layer tensor).
	w16cap := uint64(16 * 1024 * 1024)
	lmRs := int(w16cap / (uint64(m.cfg.Dim) * 2))
	if lmRs > 4096 {
		lmRs = 4096 // GEMM max_dim
	}
	if lmRs > m.cfg.Vocab {
		lmRs = m.cfg.Vocab
	}
	if lmRs < 1 {
		return nil, errors.New("no room for an lm_head row")
	}
	if need := uint64(lmRs*m.cfg.Dim) * 2; need > big {
		big = need
	}
	w16, err := s.AllocBuffer(uint32(big), gpu3d.BufWeight)
	if err != nil {
		return nil, err
	}
	e := &engine{s: s, m: m, w16: w16, lmRs: lmRs}
	e.off = m.layout(lmRs)
	if e.off.total > 8*1024*1024 {
		return nil, errors.New("io partition exceeds the pool")
	}
	e.io, err = s.AllocBuffer(e.off.total, gpu3d.BufIO)
	if err != nil {
		return nil, err
	}
	S, L, KVH, dh := m.cfg.SeqCap, m.cfg.Layers, m.cfg.KVHeads, m.headDim()
	e.kc = make([]uint16, L*KVH*S*dh)
	e.vc = make([]uint16, L*KVH*S*dh)
	e.x = make([]float32, m.cfg.Dim)
	e.xn = make([]float32, m.cfg.Dim)
	e.qkv = make([]float32, m.qkvDim())
	e.att = make([]float32, m.cfg.Heads*dh)
	e.h13 = make([]float32, 2*m.cfg.Hidden)
	e.h2 = make([]float32, m.cfg.Hidden)
	e.out = make([]float32, m.cfg.Dim)
	e.scores = make([]float32, m.cfg.Heads*m.cfg.SeqCap)
	e.logits = make([]float32, m.cfg.Vocab)
	return e, nil
}

// free drops the scratch buffers (weight buffers belong to the model).
func (e *engine) free() {
	if e.io != 0 {
		_ = e.s.FreeBuffer(e.io)
	}
	if e.w16 != 0 {
		_ = e.s.FreeBuffer(e.w16)
	}
	e.io, e.w16 = 0, 0
}

// --- device helpers -----------------------------------------------------------

func f16bytes(vals []float32) []byte {
	b := make([]byte, len(vals)*2)
	for i, v := range vals {
		h := gpu3d.F16bits(v)
		b[2*i] = byte(h)
		b[2*i+1] = byte(h >> 8)
	}
	return b
}

func f16slice(b []byte) []float32 {
	out := make([]float32, len(b)/2)
	for i := range out {
		out[i] = gpu3d.F32bits(uint16(b[2*i]) | uint16(b[2*i+1])<<8)
	}
	return out
}

// put writes f32 values into the io buffer at off as f16.
func (e *engine) put(off uint32, vals []float32) error {
	return e.s.Write(e.io, uint64(off), f16bytes(vals))
}

// put16 writes raw f16 words.
func (e *engine) put16(off uint32, vals []uint16) error {
	b := make([]byte, len(vals)*2)
	for i, v := range vals {
		b[2*i] = byte(v)
		b[2*i+1] = byte(v >> 8)
	}
	return e.s.Write(e.io, uint64(off), b)
}

// get reads n f16 words from the io buffer at off as f32.
func (e *engine) get(off uint32, n int, out []float32) error {
	b := make([]byte, n*2)
	if err := e.s.Read(e.io, uint64(off), b); err != nil {
		return err
	}
	copy(out, f16slice(b))
	return nil
}

// dequant runs DEQUANT t → w16 at offset 0.
func (e *engine) dequant(t *devTensor) error {
	kd := gpu3d.KernelDesc{
		Kernel: vi.GpuKernelDequant,
		D0:     uint32(t.n), D1: t.group,
	}
	bufs := [4]gpu3d.KernelBuf{
		{Buf: uint32(t.buf), ByteOff: t.pOff},
		{Buf: uint32(t.buf), ByteOff: t.sOff},
		{},
		{Buf: uint32(e.w16)},
	}
	switch t.fmt {
	case viwFmtU4Asym:
		kd.Aux = vi.GpuDequantFmtU4Asym
		bufs[2] = gpu3d.KernelBuf{Buf: uint32(t.buf), ByteOff: t.zOff}
	case viwFmtQ8Sym:
		kd.Aux = vi.GpuDequantFmtI8Sym
	default:
		return errors.New("dequant: tensor not a quantized fmt")
	}
	kd.Bufs = bufs
	return e.s.Run(kd)
}

// dequantRaw runs DEQUANT over explicit spans — the lm_head slices stage
// packed/scales/zeros inside the io buffer's hpack region.
func (e *engine) dequantRaw(n uint64, group, fmtb uint32, pOff, sOff, zOff uint32) error {
	kd := gpu3d.KernelDesc{
		Kernel: vi.GpuKernelDequant,
		D0:     uint32(n), D1: group, Aux: fmtb,
		Bufs: [4]gpu3d.KernelBuf{
			{Buf: uint32(e.io), ByteOff: pOff},
			{Buf: uint32(e.io), ByteOff: sOff},
			{},
			{Buf: uint32(e.w16)},
		},
	}
	if fmtb == vi.GpuDequantFmtU4Asym {
		kd.Bufs[2] = gpu3d.KernelBuf{Buf: uint32(e.io), ByteOff: zOff}
	}
	return e.s.Run(kd)
}

// gemm runs C[M,N] = A[M,K] · B[K,N] with B read f16 from w16 (or an io
// region when bIsIO) — bT marks the [N,K]-stored (transposed) weight form
// every linear layer uses.
func (e *engine) gemm(M, N, K uint32, aOff uint32, bBuf uint64, bOff uint32, bT bool, cOff uint32) error {
	kd := gpu3d.KernelDesc{
		Kernel: vi.GpuKernelGEMM,
		D0:     M, D1: N, D2: K,
		Bufs: [4]gpu3d.KernelBuf{
			{Buf: uint32(e.io), ByteOff: aOff},
			{Buf: uint32(bBuf), ByteOff: bOff},
			{Buf: uint32(e.io), ByteOff: cOff},
			{},
		},
	}
	if bT {
		kd.Flags = vi.GpuGemmBTransposed
	}
	return e.s.Run(kd)
}

// matVec is one linear layer: dequant the device tensor then one M=1 GEMM.
func (e *engine) matVec(aOff uint32, t *devTensor, cOff uint32, N, K uint32) error {
	if err := e.dequant(t); err != nil {
		return err
	}
	return e.gemm(1, N, K, aOff, e.w16, 0, true, cOff)
}

// --- CPU math -----------------------------------------------------------------

// rmsnorm: out_i = w_i · x_i · rsqrt(mean(x²)+eps) — the llama-family norm.
func rmsnorm(x, w []float32, eps float64, out []float32) {
	var ss float64
	for _, v := range x {
		ss += float64(v) * float64(v)
	}
	inv := float32(1 / math.Sqrt(ss/float64(len(x))+eps))
	for i := range out {
		out[i] = x[i] * inv * w[i]
	}
}

// rope applies rotary position embedding to v (heads × head_dim) at pos.
// "half" pairs (i, i+dh/2) — the GPT-NeoX convention SmolLM2 uses;
// "interleaved" pairs (2i, 2i+1) — the llama2.c convention.
func rope(v []float32, heads, dh, pos int, theta float64, style string) {
	for h := 0; h < heads; h++ {
		base := h * dh
		if style == "interleaved" {
			for i := 0; i < dh/2; i++ {
				freq := 1 / math.Pow(theta, float64(2*i)/float64(dh))
				ang := float64(pos) * freq
				c, s := float32(math.Cos(ang)), float32(math.Sin(ang))
				a, b := v[base+2*i], v[base+2*i+1]
				v[base+2*i] = a*c - b*s
				v[base+2*i+1] = b*c + a*s
			}
		} else {
			for i := 0; i < dh/2; i++ {
				freq := 1 / math.Pow(theta, float64(2*i)/float64(dh))
				ang := float64(pos) * freq
				c, s := float32(math.Cos(ang)), float32(math.Sin(ang))
				a, b := v[base+i], v[base+i+dh/2]
				v[base+i] = a*c - b*s
				v[base+i+dh/2] = b*c + a*s
			}
		}
	}
}

// softmaxInPlace normalizes v — the CPU twin of the kernel (used for the
// small per-head attention rows; the vocab head goes through the device).
func softmaxInPlace(v []float32) {
	mx := v[0]
	for _, x := range v {
		if x > mx {
			mx = x
		}
	}
	var sum float64
	for i, x := range v {
		e := math.Exp(float64(x - mx))
		v[i] = float32(e)
		sum += e
	}
	for i := range v {
		v[i] /= float32(sum)
	}
}

func silu(x float32) float32 {
	return x / (1 + float32(math.Exp(-float64(x))))
}

// --- one decode step -----------------------------------------------------------

// kcOff/vcOff are the byte offsets of layer l, kv-head g's cache matrix in
// the io buffer (the guest mirror arrays use the same element indexing in
// u16s).
func (e *engine) kcacheEl(l, g int) int {
	dh := e.m.headDim()
	return (l*e.m.cfg.KVHeads + g) * e.m.cfg.SeqCap * dh
}

// cacheUpload stages layer l's k/v rows 0..pos for every kv head. The io
// region is ONE layer's cache at a time — every layer overwrites it — so
// attention must see the layer's whole history, not just the new row:
// earlier rows still hold the previous layer's positions otherwise. The
// guest-side arrays are [layer][kvhead][pos][dh] contiguous, so the full
// upload is the same six-write cost the single-row append had.
func (e *engine) cacheUpload(l, pos int) error {
	c := e.m.cfg
	dh := e.m.headDim()
	for g := 0; g < c.KVHeads; g++ {
		base := e.kcacheEl(l, g)
		koff := e.off.kc + uint32(g*c.SeqCap*dh)*2
		if err := e.put16(koff, e.kc[base:base+(pos+1)*dh]); err != nil {
			return err
		}
		voff := e.off.vc + uint32(g*c.SeqCap*dh)*2
		if err := e.put16(voff, e.vc[base:base+(pos+1)*dh]); err != nil {
			return err
		}
	}
	return nil
}

// step runs one position of the model: embed → L transformer layers →
// final norm. logitsOut is skipped when nil (prompt positions need the
// cache fill, not the head).
func (e *engine) step(tok, pos int) error {
	c := e.m.cfg
	dh := e.m.headDim()
	qg := c.Heads / c.KVHeads

	// Embedding-row gather on the CPU: the packed row and its groups are
	// slices of the guest-resident embed payload.
	dequantU4(e.m.embed, e.m.embedN, e.m.embedGrp,
		uint64(tok)*uint64(c.Dim), uint64(c.Dim), e.x)

	for l := 0; l < c.Layers; l++ {
		lw := &e.m.layers[l]
		rmsnorm(e.x, lw.attnNorm, c.RmsEps, e.xn)
		if err := e.put(e.off.xn, e.xn); err != nil {
			return err
		}
		// Fused q|k|v projection.
		if err := e.matVec(e.off.xn, &lw.wqkv, e.off.q,
			uint32(e.m.qkvDim()), uint32(c.Dim)); err != nil {
			return err
		}
		if err := e.get(e.off.q, e.m.qkvDim(), e.qkv); err != nil {
			return err
		}
		q := e.qkv[:c.Heads*dh]
		k := e.qkv[c.Heads*dh : (c.Heads+c.KVHeads)*dh]
		v := e.qkv[(c.Heads+c.KVHeads)*dh:]
		rope(q, c.Heads, dh, pos, c.RopeTheta, c.Rope)
		rope(k, c.KVHeads, dh, pos, c.RopeTheta, c.Rope)
		// Append this position's k/v rows to the guest cache (f16).
		for g := 0; g < c.KVHeads; g++ {
			base := e.kcacheEl(l, g) + pos*dh
			for i := 0; i < dh; i++ {
				e.kc[base+i] = gpu3d.F16bits(k[g*dh+i])
				e.vc[base+i] = gpu3d.F16bits(v[g*dh+i])
			}
		}
		if err := e.cacheUpload(l, pos); err != nil {
			return err
		}
		// Attention: QG query heads share one kv head — one scores GEMM
		// (M=QG) and one PV GEMM per kv head. Scores ride back through the
		// CPU for the per-head softmax (elementwise; the ADR's elementwise
		// class) before the PV multiply.
		if err := e.put(e.off.q, q); err != nil {
			return err
		}
		for g := 0; g < c.KVHeads; g++ {
			aOff := e.off.q + uint32(g*qg*dh)*2
			bOff := uint32(g*c.SeqCap*dh) * 2
			if err := e.gemm(uint32(qg), uint32(pos+1), uint32(dh),
				aOff, e.io, e.off.kc+bOff, true, e.off.scores); err != nil {
				return err
			}
			if err := e.get(e.off.scores, qg*(pos+1), e.scores); err != nil {
				return err
			}
			// softmax(QK^T / sqrt(dh)) — the 1/sqrt(head_dim) factor every
			// transformer applies; the stub's arbitrary answer masked its
			// absence until a real model exposed it.
			attnScale := float32(1 / math.Sqrt(float64(dh)))
			for r := 0; r < qg; r++ {
				row := e.scores[r*(pos+1) : (r+1)*(pos+1)]
				for i := range row {
					row[i] *= attnScale
				}
				softmaxInPlace(row)
			}
			if err := e.put(e.off.probs, e.scores[:qg*(pos+1)]); err != nil {
				return err
			}
			cOff := e.off.att + uint32(g*qg*dh)*2
			if err := e.gemm(uint32(qg), uint32(dh), uint32(pos+1),
				e.off.probs, e.io, e.off.vc+bOff, false, cOff); err != nil {
				return err
			}
		}
		if err := e.get(e.off.att, c.Heads*dh, e.att); err != nil {
			return err
		}
		if err := e.put(e.off.xn, e.att); err != nil {
			return err
		}
		if err := e.matVec(e.off.xn, &lw.wo, e.off.out,
			uint32(c.Dim), uint32(c.Heads*dh)); err != nil {
			return err
		}
		if err := e.get(e.off.out, c.Dim, e.out); err != nil {
			return err
		}
		for i := range e.x {
			e.x[i] += e.out[i]
		}

		// FFN: rmsnorm → w13 (gate|up) → silu·mul → w2 → residual.
		rmsnorm(e.x, lw.ffnNorm, c.RmsEps, e.xn)
		if err := e.put(e.off.xn, e.xn); err != nil {
			return err
		}
		if err := e.matVec(e.off.xn, &lw.w13, e.off.h13,
			uint32(2*c.Hidden), uint32(c.Dim)); err != nil {
			return err
		}
		if err := e.get(e.off.h13, 2*c.Hidden, e.h13); err != nil {
			return err
		}
		for i := 0; i < c.Hidden; i++ {
			e.h2[i] = silu(e.h13[i]) * e.h13[c.Hidden+i]
		}
		if err := e.put(e.off.h2, e.h2); err != nil {
			return err
		}
		if err := e.matVec(e.off.h2, &lw.w2, e.off.out,
			uint32(c.Dim), uint32(c.Hidden)); err != nil {
			return err
		}
		if err := e.get(e.off.out, c.Dim, e.out); err != nil {
			return err
		}
		for i := range e.x {
			e.x[i] += e.out[i]
		}
	}
	return nil
}

// lmHead runs the tied-embedding output projection in row slices: the
// guest-resident packed rows stage through the io hpack region, DEQUANT
// widens a slice to w16, and one GEMM emits its logit band. The vocab
// softmax then runs ON THE DEVICE — the shape SOFTMAX's column bound was
// pinned for — and the probabilities come back for the sampler.
func (e *engine) lmHead() error {
	c := e.m.cfg
	rmsnorm(e.x, e.m.finalNorm, c.RmsEps, e.xn)
	if err := e.put(e.off.xn, e.xn); err != nil {
		return err
	}
	gpr := uint64(c.Dim) / uint64(e.m.embedGrp) // groups per row
	pkRow := uint64(c.Dim) / 2                  // packed bytes per row
	for s0 := 0; s0 < c.Vocab; s0 += e.lmRs {
		rows := e.lmRs
		if c.Vocab-s0 < rows {
			rows = c.Vocab - s0
		}
		pLen := uint64(rows) * pkRow
		sLen := uint64(rows) * gpr * 4
		// Slice the three spans out of the guest-resident embed payload.
		p0 := uint64(s0) * pkRow
		s0o := (e.m.embedN+1)/2 + uint64(s0)*gpr*4
		z0o := s0o + (e.m.embedN+uint64(e.m.embedGrp)-1)/uint64(e.m.embedGrp)*4
		if err := e.s.Write(e.io, uint64(e.off.hpack),
			e.m.embed[p0:p0+pLen]); err != nil {
			return err
		}
		if err := e.s.Write(e.io, uint64(e.off.hpack)+pLen,
			e.m.embed[s0o:s0o+sLen]); err != nil {
			return err
		}
		if err := e.s.Write(e.io, uint64(e.off.hpack)+pLen+sLen,
			e.m.embed[z0o:z0o+sLen]); err != nil {
			return err
		}
		if err := e.dequantRaw(uint64(rows*c.Dim), e.m.embedGrp,
			vi.GpuDequantFmtU4Asym, e.off.hpack,
			e.off.hpack+uint32(pLen), e.off.hpack+uint32(pLen+sLen)); err != nil {
			return err
		}
		if err := e.gemm(1, uint32(rows), uint32(c.Dim), e.off.xn,
			e.w16, 0, true, e.off.logits+uint32(s0)*2); err != nil {
			return err
		}
	}
	// Read the f16 logits, widen to f32, and let the device softmax the
	// whole vocab head — in-place, one row of V columns.
	if err := e.get(e.off.logits, c.Vocab, e.logits); err != nil {
		return err
	}
	f32b := make([]byte, c.Vocab*4)
	for i, v := range e.logits {
		putF32(f32b[i*4:], v)
	}
	if err := e.s.Write(e.io, uint64(e.off.probs32), f32b); err != nil {
		return err
	}
	kd := gpu3d.KernelDesc{
		Kernel: vi.GpuKernelSoftmax,
		Flags:  vi.GpuSoftmaxInPlace,
		D0:     1, D1: uint32(c.Vocab),
		Bufs: [4]gpu3d.KernelBuf{
			{Buf: uint32(e.io), ByteOff: e.off.probs32},
			{Buf: uint32(e.io), ByteOff: e.off.probs32},
			{}, {},
		},
	}
	if err := e.s.Run(kd); err != nil {
		return err
	}
	if err := e.s.Read(e.io, uint64(e.off.probs32), f32b); err != nil {
		return err
	}
	for i := range e.logits {
		e.logits[i] = f32at(f32b, i*4)
	}
	return nil
}
