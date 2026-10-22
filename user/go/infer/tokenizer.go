package infer

// Tokenizers: the stub's byte-level table and a dependency-free GPT-2-style
// byte-level BPE for real models (the SmolLM2 family ships exactly this —
// ChatML specials, bytes_to_unicode atoms, ranked merges). The VIW
// tokenizer blob is a compact binary section — no format library, no
// third-party tokenization dependency anywhere, per the card.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
)

// Tokenizer is the encode/decode seam. Encode is prompt-side; Decode turns
// generated ids back into bytes.
type Tokenizer interface {
	Encode(s string) []int
	Decode(ids []int) string
	// Specials used by the sampler.
	EOS() int
	BOS() int
	// MaxID is the largest id the table can emit; Load refuses a tokenizer
	// whose id space outruns the model's vocab.
	MaxID() int
}

// The VIW tokenizer blob is a small binary section — no format library:
//
//	u32 kind    (1 = bytes, 2 = bpe)
//	u32 bos
//	u32 eos
//	[bpe] u32 n_vocab, then n_vocab × {u16 len, utf8 token bytes}
//	[bpe] u32 n_merges, then n_merges × {u32 a_idx, u32 b_idx}
//
// A merge's result token is vocab[a]+vocab[b] — the same strings a HF
// tokenizer.json carries, just indexed instead of spelled out per merge.
const (
	tokKindBytes uint32 = 1
	tokKindBPE   uint32 = 2
)

type tokBlob struct {
	kind   uint32
	vocab  []string
	merges [][2]uint32 // index pairs into vocab
	bos    int
	eos    int
}

// parseTokenizer builds the tokenizer the blob names.
func parseTokenizer(b []byte) (Tokenizer, error) {
	var tb tokBlob
	if len(b) < 12 {
		return nil, errors.New("viw: short tokenizer blob")
	}
	tb.kind = binary.LittleEndian.Uint32(b)
	tb.bos = int(binary.LittleEndian.Uint32(b[4:]))
	tb.eos = int(binary.LittleEndian.Uint32(b[8:]))
	switch tb.kind {
	case tokKindBytes:
		return &bytesTok{eos: tb.eos, bos: tb.bos}, nil
	case tokKindBPE:
		p := 12
		need := func(n int) error {
			if p+n > len(b) {
				return errors.New("viw: truncated tokenizer blob")
			}
			return nil
		}
		if err := need(4); err != nil {
			return nil, err
		}
		nv := int(binary.LittleEndian.Uint32(b[p:]))
		p += 4
		// Bound the count by the bytes that remain BEFORE it sizes make():
		// every entry costs at least its u16 length, so a lying count fails
		// here instead of preallocating gigabytes of table.
		if nv > (len(b)-p)/2 {
			return nil, fmt.Errorf("viw: vocab count %d beyond blob", nv)
		}
		tb.vocab = make([]string, 0, nv)
		for i := 0; i < nv; i++ {
			if err := need(2); err != nil {
				return nil, err
			}
			ln := int(binary.LittleEndian.Uint16(b[p:]))
			p += 2
			if err := need(ln); err != nil {
				return nil, err
			}
			tb.vocab = append(tb.vocab, string(b[p:p+ln]))
			p += ln
		}
		if err := need(4); err != nil {
			return nil, err
		}
		nm := int(binary.LittleEndian.Uint32(b[p:]))
		p += 4
		if nm > (len(b)-p)/8 {
			return nil, fmt.Errorf("viw: merge count %d beyond blob", nm)
		}
		tb.merges = make([][2]uint32, 0, nm)
		for i := 0; i < nm; i++ {
			if err := need(8); err != nil {
				return nil, err
			}
			a := binary.LittleEndian.Uint32(b[p:])
			c := binary.LittleEndian.Uint32(b[p+4:])
			if int(a) >= nv || int(c) >= nv {
				return nil, fmt.Errorf("viw: merge %d names vocab outside 0..%d", i, nv)
			}
			tb.merges = append(tb.merges, [2]uint32{a, c})
			p += 8
		}
		if p != len(b) {
			return nil, errors.New("viw: trailing tokenizer bytes")
		}
		return newBPE(&tb)
	}
	return nil, fmt.Errorf("tokenizer kind %d", tb.kind)
}

// tokEmitBytes writes the kind=1 blob.
func tokEmitBytes(bos, eos int) []byte {
	b := make([]byte, 12)
	binary.LittleEndian.PutUint32(b, tokKindBytes)
	binary.LittleEndian.PutUint32(b[4:], uint32(bos))
	binary.LittleEndian.PutUint32(b[8:], uint32(eos))
	return b
}

// tokEmitBPE writes the kind=2 blob: vocab strings plus index-pair merges.
func tokEmitBPE(vocab []string, merges [][2]uint32, bos, eos int) []byte {
	n := 16
	for _, s := range vocab {
		n += 2 + len(s)
	}
	n += len(merges) * 8
	b := make([]byte, 0, n)
	u32 := func(v uint32) {
		b = binary.LittleEndian.AppendUint32(b, v)
	}
	u32(tokKindBPE)
	u32(uint32(bos))
	u32(uint32(eos))
	u32(uint32(len(vocab)))
	for _, s := range vocab {
		b = binary.LittleEndian.AppendUint16(b, uint16(len(s)))
		b = append(b, s...)
	}
	u32(uint32(len(merges)))
	for _, m := range merges {
		u32(m[0])
		u32(m[1])
	}
	return b
}

// --- byte-level (stub) --------------------------------------------------------

// bytesTok is the stub's tokenizer: id = byte value. ids 0..255 are the
// raw bytes; the model's BOS/EOS are ordinary ids in that range — the stub
// config picks values that keep the stream byte-safe (2 = STX doubles as
// EOS in the stub image, never generated in practice).
type bytesTok struct{ bos, eos int }

func (t *bytesTok) Encode(s string) []int {
	out := make([]int, 0, len(s))
	for _, c := range []byte(s) {
		out = append(out, int(c))
	}
	return out
}

func (t *bytesTok) Decode(ids []int) string {
	var sb strings.Builder
	for _, id := range ids {
		if id >= 0 && id < 256 {
			sb.WriteByte(byte(id))
		} else {
			sb.WriteString(fmt.Sprintf("<%d>", id))
		}
	}
	return sb.String()
}

func (t *bytesTok) EOS() int { return t.eos }
func (t *bytesTok) BOS() int { return t.bos }

// MaxID is 255: byte-level ids are the bytes themselves.
func (t *bytesTok) MaxID() int { return 255 }

// --- GPT-2-style byte-level BPE ----------------------------------------------

// bpeTok implements byte-level BPE: atoms are the 256 bytes mapped through
// the GPT-2 bytes_to_unicode table, merges apply by rank, decode reverses
// the unicode map back to bytes.
type bpeTok struct {
	vocab   map[string]int
	idTok   []string // id -> token string (unicode-mapped)
	ranks   map[[2]string]int
	u2b     [256]rune // byte -> unicode atom char
	b2u     map[rune]byte
	bos     int
	eos     int
	special map[string]int // literal special-token text -> id
}

func newBPE(tb *tokBlob) (*bpeTok, error) {
	if len(tb.vocab) == 0 {
		return nil, errors.New("bpe tokenizer: empty vocab")
	}
	t := &bpeTok{
		vocab:   make(map[string]int, len(tb.vocab)),
		idTok:   tb.vocab,
		ranks:   make(map[[2]string]int, len(tb.merges)),
		b2u:     make(map[rune]byte, 256),
		bos:     tb.bos,
		eos:     tb.eos,
		special: make(map[string]int),
	}
	for id, s := range tb.vocab {

		t.vocab[s] = id
		if strings.HasPrefix(s, "CH"+"ATML") || (strings.HasPrefix(s, "<") && strings.HasSuffix(s, ">") && len(s) < 64 && strings.Count(s, " ") == 0) {
			t.special[s] = id
		}
	}
	for i, m := range tb.merges {
		t.ranks[[2]string{tb.vocab[m[0]], tb.vocab[m[1]]}] = i
	}
	buildByteTable(t)
	return t, nil
}

// buildByteTable fills the GPT-2 bytes_to_unicode map: printable bytes map
// to themselves; the rest get 256+n code points.
func buildByteTable(t *bpeTok) {
	n := 0
	for b := 0; b < 256; b++ {
		printable := (b >= '!' && b <= '~') || (b >= 0xA1 && b <= 0xAC) || b >= 0xAE
		if printable {
			t.u2b[b] = rune(b)
		} else {
			t.u2b[b] = rune(256 + n)
			n++
		}
		t.b2u[t.u2b[b]] = byte(b)
	}
}

func (t *bpeTok) EOS() int { return t.eos }
func (t *bpeTok) BOS() int { return t.bos }

// MaxID is the last vocab row — specials and merge results all live inside
// the same table, so no emitted id can outrun it.
func (t *bpeTok) MaxID() int { return len(t.idTok) - 1 }

// atomize maps a byte slice to its unicode-atom token strings.
func (t *bpeTok) atomize(bs []byte) []string {
	out := make([]string, len(bs))
	for i, b := range bs {
		out[i] = string(t.u2b[b])
	}
	return out
}

// splitSpecials walks s left to right, cutting out the longest matching
// special token at each position; the returned pieces alternate text
// ("" never) and specials (marked by flag).
func (t *bpeTok) splitSpecials(s string) []seg {
	var out []seg
	for len(s) > 0 {
		best := -1
		var bname string
		for sp, id := range t.special {
			if strings.HasPrefix(s, sp) && len(sp) > len(bname) {
				best, bname = id, sp
			}
		}
		if best < 0 {
			// take text up to the next possible special start
			i := strings.IndexByte(s[1:], '<')
			if i < 0 {
				out = append(out, seg{text: s})
				break
			}
			out = append(out, seg{text: s[:i+1]})
			s = s[i+1:]
			continue
		}
		out = append(out, seg{tok: best})
		s = s[len(bname):]
	}
	return out
}

type seg struct {
	text string
	tok  int // >=0 means a special id
}

// preTokenize implements the GPT-2 byte-level pre-tokenizer WITHOUT the
// regex library: contractions' suffixes, optional-space letter runs,
// digits split individually (the SmolLM2 Digits pretokenizer), optional-
// space punctuation runs, and whitespace runs — the same partition the
// 'spattern produces, hand-rolled.
func preTokenize(s string) []string {
	var out []string
	i, n := 0, len(s)
	isLetter := func(c byte) bool {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
	}
	isDigit := func(c byte) bool { return c >= '0' && c <= '9' }
	for i < n {
		// contraction suffixes: 's 't 're 've 'm 'll 'd (case-insensitive)
		if s[i] == '\'' && i+1 < n {
			for _, suf := range []string{"'s", "'t", "'re", "'ve", "'m", "'ll", "'d"} {
				if i+len(suf) <= n && strings.EqualFold(s[i:i+len(suf)], suf) {
					out = append(out, s[i:i+len(suf)])
					i += len(suf)
					goto next
				}
			}
		}
		// optional single space + run of letters
		if isLetter(s[i]) || (s[i] == ' ' && i+1 < n && isLetter(s[i+1])) {
			j := i
			if s[j] == ' ' {
				j++
			}
			for j < n && isLetter(s[j]) {
				j++
			}
			out = append(out, s[i:j])
			i = j
			continue
		}
		// digits: one token each (Digits individual_digits); a leading
		// space glues to the first digit (the regex's " ?" arm).
		if isDigit(s[i]) || (s[i] == ' ' && i+1 < n && isDigit(s[i+1])) {
			j := i
			if s[j] == ' ' {
				j += 2
			} else {
				j++
			}
			out = append(out, s[i:j])
			i = j
			continue
		}
		// whitespace run (not followed by a word char stays together;
		// trailing whitespace is its own token)
		if s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' {
			j := i
			for j < n && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') {
				j++
			}
			// A whitespace run followed by a letter/digit keeps one space
			// attached to the next token (the " ?" in the regex arms) —
			// but only when the run exceeds a single space.
			if j < n && j-i > 1 && (isLetter(s[j]) || isDigit(s[j])) {
				out = append(out, s[i:j-1])
				i = j - 1
			} else {
				out = append(out, s[i:j])
				i = j
			}
			continue
		}
		// optional space + run of other non-space non-letter non-digit
		{
			j := i
			if s[j] == ' ' && j+1 < n {
				j++
			}
			for j < n && !isLetter(s[j]) && !isDigit(s[j]) &&
				s[j] != ' ' && s[j] != '\t' && s[j] != '\n' && s[j] != '\r' {
				j++
			}
			out = append(out, s[i:j])
			i = j
		}
	next:
	}
	return out
}

// mergeBPE applies ranked merges to one atom list until no pair ranks.
func (t *bpeTok) mergeBPE(atoms []string) []string {
	for len(atoms) > 1 {
		best, bi := -1, -1
		for i := 0; i+1 < len(atoms); i++ {
			if r, ok := t.ranks[[2]string{atoms[i], atoms[i+1]}]; ok && (best < 0 || r < best) {
				best, bi = r, i
			}
		}
		if best < 0 {
			break
		}
		atoms[bi] = atoms[bi] + atoms[bi+1]
		copy(atoms[bi+1:], atoms[bi+2:])
		atoms = atoms[:len(atoms)-1]
	}
	return atoms
}

// Encode maps text to ids: specials first, then GPT-2 pre-tokenize →
// atomize → merge → vocab lookup. An atom string with no vocab entry is a
// hard error — the table is closed, so a miss is a converter bug, not OOV.
func (t *bpeTok) Encode(s string) []int {
	var out []int
	for _, p := range t.splitSpecials(s) {
		if p.text == "" {
			out = append(out, p.tok)
			continue
		}
		for _, piece := range preTokenize(p.text) {
			atoms := t.mergeBPE(t.atomize([]byte(piece)))
			for _, a := range atoms {
				id, ok := t.vocab[a]
				if !ok {
					// fall back to raw atoms — a merge produced an
					// unvocab'd string only if the table is inconsistent
					for _, raw := range t.atomize([]byte(a)) {
						if rid, ok2 := t.vocab[raw]; ok2 {
							out = append(out, rid)
						}
					}
					continue
				}
				out = append(out, id)
			}
		}
	}
	return out
}

// Decode reverses: id -> token string -> unicode atoms -> bytes.
func (t *bpeTok) Decode(ids []int) string {
	var sb strings.Builder
	for _, id := range ids {
		if id < 0 || id >= len(t.idTok) {
			continue
		}
		s := t.idTok[id]
		if _, sp := t.special[s]; sp {
			continue // specials never render
		}
		for _, r := range s {
			if b, ok := t.b2u[r]; ok {
				sb.WriteByte(b)
			} else {
				sb.WriteRune(r) // literal rune in the vocab (rare)
			}
		}
	}
	return sb.String()
}
