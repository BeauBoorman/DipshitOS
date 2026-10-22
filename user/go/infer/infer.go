// Package infer is the M140a (#2784) extraction of the GOINFER engine:
// the VIW loader, tokenizer, GPU-compute forward pass and greedy decode,
// consumable as a library. GOINFER.ELF is a thin CLI over it; GOASSIST
// (M140b) streams through the token callback.
//
// The generate loop: prompt prefill then greedy decode. Greedy is not a
// limitation — it is the contract: the gate pins one answer, so the
// sampler is argmax (lowest id on ties), the same token on every run,
// every boot, K times in a row.
package infer

import (
	"errors"
	"fmt"
	"io"
)

// Load streams a VIW image from r — head, tokenizer blob and payloads —
// into sealed weight buffers on the compute session s, and parses the
// tokenizer. stageBytes bounds the read chunk (a WRITE's own staging is
// smaller; chunking is the client's problem, the kernel's is the 4 MiB
// window). The caller keeps ownership of s.
func Load(r io.Reader, s Dev, stageBytes int) (*Model, error) {
	im, err := readVIWHead(r)
	if err != nil {
		return nil, err
	}
	m, err := loadModel(im, r, s, stageBytes)
	if err != nil {
		return nil, err
	}
	tok, err := parseTokenizer(im.Tok)
	if err != nil {
		m.freeBuffers()
		return nil, err
	}
	// An id the table can emit that the embedding has no row for is a
	// load-time defect, not a decode-time panic.
	if tok.MaxID() >= m.cfg.Vocab {
		m.freeBuffers()
		return nil, fmt.Errorf("viw: tokenizer id space %d exceeds vocab %d",
			tok.MaxID()+1, m.cfg.Vocab)
	}
	m.tok = tok
	return m, nil
}

// Header returns the model's VIW header: the architecture description the
// forward pass runs against plus the licence receipt.
func (m *Model) Header() Header { return m.cfg }

// Params is the model's total element count, for receipts.
func (m *Model) Params() uint64 { return m.params }

// Tokenizer is the loaded image's encode/decode seam.
func (m *Model) Tokenizer() Tokenizer { return m.tok }

// Generate runs prefill + greedy decode over prompt ids (from the model's
// tokenizer); maxNew bounds the answer inside seq_cap. Each produced id
// goes to cb before the next step — a caller streams token-at-a-time, and
// a non-nil cb return aborts the decode (Generate propagates it with the
// ids collected so far). cb may be nil.
//
// The first call lazily allocates the engine's scratch buffers on the
// session the model was loaded onto; later calls reuse them — the K=5
// leg pattern of one engine, several decodes.
func (m *Model) Generate(prompt []int, maxNew int, cb func(id int) error) ([]int, error) {
	if m.s == nil {
		return nil, errors.New("infer: model closed")
	}
	if m.eng == nil {
		eng, err := newEngine(m.s, m)
		if err != nil {
			return nil, err
		}
		m.eng = eng
	}
	return m.eng.generate(prompt, maxNew, cb)
}

// Close releases the engine scratch and the model's weight buffers. The
// session stays the caller's — Close it after the model. Idempotent; a
// closed model refuses Generate.
func (m *Model) Close() {
	if m.eng != nil {
		m.eng.free()
		m.eng = nil
	}
	if m.s != nil {
		m.freeBuffers()
		m.s = nil
	}
}

// argmax picks the winning id — lowest index on exact ties so the pin is
// stable even when two ids land on the same probability.
func argmax(v []float32) int {
	best, bi := v[0], 0
	for i := 1; i < len(v); i++ {
		if v[i] > best {
			best, bi = v[i], i
		}
	}
	return bi
}

// generate runs prefill + greedy decode. prompt ids come from the model's
// tokenizer; maxNew bounds the answer inside seq_cap. cb sees each id as
// it is produced; its non-nil return aborts the decode.
func (e *engine) generate(prompt []int, maxNew int, cb func(id int) error) ([]int, error) {
	c := e.m.cfg
	if len(prompt) == 0 {
		return nil, errors.New("empty prompt")
	}
	if maxNew < 1 || len(prompt) > c.SeqCap {
		return nil, errors.New("prompt outside seq_cap")
	}
	pos := 0
	cur := prompt[0]
	var ids []int
	for {
		if err := e.step(cur, pos); err != nil {
			return nil, err
		}
		pos++
		if pos < len(prompt) {
			cur = prompt[pos]
			continue
		}
		// Every prompt token consumed: the last step's hidden state heads
		// for the vocab projection.
		if err := e.lmHead(); err != nil {
			return nil, err
		}
		nxt := argmax(e.logits)
		ids = append(ids, nxt)
		if cb != nil {
			if err := cb(nxt); err != nil {
				return ids, err
			}
		}
		if nxt == c.EOS || len(ids) >= maxNew || pos >= c.SeqCap {
			break
		}
		cur = nxt
	}
	return ids, nil
}
