package parser

import (
	"encoding/hex"
	"sort"
	"strconv"
	"strings"
)

// Render writes one line per Atom, sorted by (file, start):
//
//	file\tkind\tname\tstart\tend\thash_hex\tsig_hash_hex\n
//
// This format is shared by the gate receipt (FLINTC.OUT) and the
// MANIFEST comparison (ADR 0049, M103a #2253).
func Render(atoms []Atom) []byte {
	sorted := make([]Atom, len(atoms))
	copy(sorted, atoms)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].File != sorted[j].File {
			return sorted[i].File < sorted[j].File
		}
		return sorted[i].Start < sorted[j].Start
	})
	var b strings.Builder
	for _, a := range sorted {
		b.WriteString(a.File)
		b.WriteByte('\t')
		b.WriteString(a.Kind)
		b.WriteByte('\t')
		b.WriteString(a.Name)
		b.WriteByte('\t')
		b.WriteString(strconv.Itoa(int(a.Start)))
		b.WriteByte('\t')
		b.WriteString(strconv.Itoa(int(a.End)))
		b.WriteByte('\t')
		b.WriteString(hex.EncodeToString(a.Hash[:]))
		b.WriteByte('\t')
		b.WriteString(hex.EncodeToString(a.SigHash[:]))
		b.WriteByte('\n')
	}
	return []byte(b.String())
}
