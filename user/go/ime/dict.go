// Package ime resolves kana readings to kanji candidates for the
// romaji->kana composer (layout.IME). The dictionary is the packed
// KANADICT.BIN produced by tools/kanadict/pack.py from the pinned,
// curated JMdict-derived subset (CC BY-SA 4.0 — see THIRD-PARTY.txt
// in this directory and the licence text beside the artifact).
//
// The guest reads the staged file at /host/KANADICT.BIN. An absent or
// corrupt dictionary is the card's honest bound: lookups yield nothing
// and the composer offers kana-only candidates — never a wrong kanji.
package ime

import (
	"bytes"
	"errors"
	"fmt"
	"sync"

	"virelai/vi"
)

// DefaultPath is where a boot's share staging puts the packed
// dictionary (tools/lib/gate-run.sh, and the go-assist spec's setup).
const DefaultPath = "/host/KANADICT.BIN"

// The packed format (little-endian; pack.py's header comment is the
// reference):
//
//	+0  u32 magic  'KND1'
//	+4  u32 nkeys
//	+8  nkeys x 12B index entries {u32 keyOff, u32 recOff, u16 keyLen,
//	    u16 recLen}; keys are UTF-8 hiragana sorted bytewise
//	then key bytes, then surface records: u8 nsurf, nsurf x (u8 len +
//	UTF-8 surface) in the source's frequency order.
const (
	magic0, magic1, magic2, magic3 = 'K', 'N', 'D', '1'
	indexEntry                     = 12
	headerLen                      = 8
)

// errCorrupt rejects a blob that is not a well-formed dictionary: wrong
// magic, a truncated or out-of-range index/record, or an index that is
// not sorted (binary search would silently mis-answer).
var errCorrupt = errors.New("ime: corrupt dictionary")

// Dict is a parsed KANADICT.BIN. Lookup is a binary search over the
// sorted key index — O(log n) — and the record pays out surfaces in
// their packed (frequency) order.
type Dict struct {
	blob []byte
	n    int
}

// Parse validates a packed dictionary blob and returns it ready for
// Lookup. The blob is retained, not copied.
func Parse(blob []byte) (*Dict, error) {
	if len(blob) < headerLen ||
		blob[0] != magic0 || blob[1] != magic1 ||
		blob[2] != magic2 || blob[3] != magic3 {
		return nil, errCorrupt
	}
	n := int(u32(blob, 4))
	if n == 0 || n*indexEntry > len(blob)-headerLen {
		return nil, errCorrupt
	}
	var prev string
	for i := 0; i < n; i++ {
		e := headerLen + i*indexEntry
		koff, roff := int(u32(blob, e)), int(u32(blob, e+4))
		klen, rlen := int(u16(blob, e+8)), int(u16(blob, e+10))
		if klen == 0 || rlen < 1 ||
			koff+klen > len(blob) || roff+rlen > len(blob) {
			return nil, errCorrupt
		}
		k := string(blob[koff : koff+klen])
		if i > 0 && k <= prev {
			return nil, errCorrupt // binary search needs a sorted index
		}
		prev = k
		if !recordWellFormed(blob[roff : roff+rlen]) {
			return nil, errCorrupt
		}
	}
	return &Dict{blob: blob, n: n}, nil
}

// dictMaxBytes bounds the file read — the packer's own size cap.
const dictMaxBytes = 64 * 1024

// Open reads and parses a packed dictionary file through the guest file
// channel (vi.ReadFileAll). On a host build the call reports -ENOSYS,
// so Open fails cleanly rather than crashing.
func Open(path string) (*Dict, error) {
	b, rc := vi.ReadFileAll(path, dictMaxBytes)
	if rc < 0 {
		return nil, fmt.Errorf("ime: read %s: rc=%d", path, rc)
	}
	return Parse(b)
}

// Len is the number of keyed readings.
func (d *Dict) Len() int { return d.n }

// Lookup returns the surfaces recorded for a kana reading, most common
// first, or nil when the reading is not in the subset.
func (d *Dict) Lookup(reading string) []string {
	key := []byte(reading)
	lo, hi := 0, d.n
	for lo < hi {
		mid := (lo + hi) / 2
		e := headerLen + mid*indexEntry
		koff, klen := int(u32(d.blob, e)), int(u16(d.blob, e+8))
		switch c := bytes.Compare(d.blob[koff:koff+klen], key); {
		case c == 0:
			return d.surfaces(int(u32(d.blob, e+4)))
		case c < 0:
			lo = mid + 1
		default:
			hi = mid
		}
	}
	return nil
}

// surfaces decodes one record: u8 count, then count x (u8 len + bytes).
func (d *Dict) surfaces(off int) []string {
	n := int(d.blob[off])
	p := off + 1
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		l := int(d.blob[p])
		p++
		out = append(out, string(d.blob[p:p+l]))
		p += l
	}
	return out
}

var (
	defaultOnce sync.Once
	defaultDict *Dict
)

// Default is the staged dictionary, loaded once. It is nil when
// /host/KANADICT.BIN is absent or fails Parse — callers must treat nil
// as "no conversions", not as an error.
func Default() *Dict {
	defaultOnce.Do(func() {
		if d, err := Open(DefaultPath); err == nil {
			defaultDict = d
		}
	})
	return defaultDict
}

func u16(b []byte, off int) uint16 { return uint16(b[off]) | uint16(b[off+1])<<8 }

func u32(b []byte, off int) uint32 {
	return uint32(b[off]) | uint32(b[off+1])<<8 |
		uint32(b[off+2])<<16 | uint32(b[off+3])<<24
}

// recordWellFormed walks a surface record: u8 count, then count x (u8
// len + bytes). The walk must consume the record exactly.
func recordWellFormed(rec []byte) bool {
	n, p := int(rec[0]), 1
	for i := 0; i < n; i++ {
		if p >= len(rec) {
			return false
		}
		p += 1 + int(rec[p])
	}
	return p == len(rec)
}
