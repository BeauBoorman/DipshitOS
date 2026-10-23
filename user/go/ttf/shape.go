package ttf

// Opt-in Latin shaping on top of the parsed cmap view of the font: GSUB
// ligature substitution (lookup type 4) and GPOS pair kerning (lookup type 2).
// A font without the tables, scripts, or features shapes as a no-op, so every
// existing cmap-only caller keeps its behavior unless it calls ShapeLatin.

// ShapedGlyph is one slot of the shaped output. GID is the substituted glyph
// id and Cluster is the UTF-8 byte offset in the input string where the
// cluster that produced this glyph begins. XAdvance/XOffset/YOffset are in
// font design units (UPEM), the same space as GlyphAdvanceUPEM.
type ShapedGlyph struct {
	GID      uint16
	Cluster  int
	XAdvance int
	XOffset  int
	YOffset  int
}

// scriptTag builds a big-endian four-byte OpenType tag like 'latn'.
func scriptTag(a, b, c, d byte) uint32 {
	return uint32(a)<<24 | uint32(b)<<16 | uint32(c)<<8 | uint32(d)
}

// Script tags this package resolves, as big-endian words.
const (
	scriptLatn = 0x6c61746e // 'latn'
	scriptDFLT = 0x44464c54 // 'DFLT'
)

// layout is the parsed subset of GSUB/GPOS this package understands: one
// feature per table (liga / kern), resolved through the default LangSys of
// the latn or DFLT script. Everything else in the tables is ignored; anything
// malformed leaves the feature unset and shaping falls back to cmap-only.
type layout struct {
	// ligatures maps first glyph id -> its ligature sets in feature order.
	ligatures map[uint16][]ligatureSet
	// pairs maps first glyph id -> second glyph id -> x advance adjustment.
	pairs map[uint16]map[uint16]int
	// classPairs holds deferred PairPosFormat2 subtables, each with the
	// subtable base offset it was parsed from.
	classPairs []classPairTable
}

// ligatureSet is one first-glyph's list of (components, ligature glyph),
// longest component list first so greedy matching is correct.
type ligatureSet struct {
	comps []uint16
	lig   uint16
}

// parseLayout walks one layout table (GSUB or GPOS). It returns a nil layout
// (no error) when the table is absent, truncated, or carries nothing this
// package implements: shaping must degrade to cmap-only, never fail hard on
// a feature it does not need.
func parseLayout(data []byte, wantFeature string, wantLookupType int) *layout {
	if len(data) < 10 {
		return nil
	}
	scriptList := int(be16(data[4:6]))
	featureList := int(be16(data[6:8]))
	lookupList := int(be16(data[8:10]))

	// ScriptList -> the latn (then DFLT) script's default LangSys -> the
	// feature index whose tag matches -> that feature's lookups.
	scriptBase := -1
	for _, wantScript := range []uint32{scriptLatn, scriptDFLT} {
		scriptBase = findScript(data, scriptList, wantScript)
		if scriptBase >= 0 {
			break
		}
	}
	if scriptBase < 0 {
		return nil
	}
	lookupIdxs := featureLookups(data, scriptBase, featureList, wantFeature)
	if len(lookupIdxs) == 0 {
		return nil
	}

	lay := &layout{}
	for _, li := range lookupIdxs {
		parseLookup(data, lookupList, li, wantLookupType, lay)
	}
	if len(lay.ligatures) == 0 && len(lay.pairs) == 0 && len(lay.classPairs) == 0 {
		return nil
	}
	return lay
}

// findScript returns the byte offset of the named script's Script table, or
// -1 when the script list does not carry it.
func findScript(data []byte, scriptList int, want uint32) int {
	if scriptList <= 0 || scriptList+2 > len(data) {
		return -1
	}
	n := int(be16(data[scriptList : scriptList+2]))
	for i := 0; i < n; i++ {
		p := scriptList + 2 + i*6
		if p+6 > len(data) {
			return -1
		}
		if be32(data[p:p+4]) == want {
			off := int(be16(data[p+4 : p+6]))
			base := scriptList + off
			if base < 0 || base >= len(data) {
				return -1
			}
			return base
		}
	}
	return -1
}

// featureLookups resolves the script's default LangSys to the lookup indexes
// of the first feature whose tag matches want.
func featureLookups(data []byte, scriptBase, featureList int, want string) []int {
	if scriptBase+4 > len(data) {
		return nil
	}
	// Script table: offset16 defaultLangSys, uint16 langSysCount, records.
	// defaultLangSys == 0 means the script has no default LangSys.
	defOff := int(be16(data[scriptBase : scriptBase+2]))
	if defOff == 0 {
		return nil
	}
	langSys := scriptBase + defOff
	if langSys+6 > len(data) {
		return nil
	}
	// LangSys table: offset16 lookupOrder, uint16 reqFeatureIndex,
	// uint16 featureIndexCount, uint16 featureIndices[].
	n := int(be16(data[langSys+4 : langSys+6]))
	for i := 0; i < n; i++ {
		p := langSys + 6 + i*2
		if p+2 > len(data) {
			return nil
		}
		idx := int(be16(data[p : p+2]))
		fp := featureList + 2 + idx*6
		if fp+6 > len(data) {
			continue
		}
		if string(data[fp:fp+4]) != want {
			continue
		}
		// Feature table: offset16 featureParams, uint16 lookupCount,
		// uint16 lookupListIndices[]. The record's offset is relative to
		// the FeatureList, not the record.
		fo := featureList + int(be16(data[fp+4:fp+6]))
		if fo+4 > len(data) {
			return nil
		}
		cnt := int(be16(data[fo+2 : fo+4]))
		if fo+4+cnt*2 > len(data) {
			return nil
		}
		out := make([]int, 0, cnt)
		for j := 0; j < cnt; j++ {
			out = append(out, int(be16(data[fo+4+j*2:fo+6+j*2])))
		}
		return out
	}
	return nil
}

// Lookup extension wrappers re-wrap a lookup's subtables once. GSUB type 7
// and GPOS type 9: uint16 format (=1), uint16 extensionLookupType, uint32
// extensionOffset (relative to the ExtensionFormat1 structure). Inter's kern
// feature is entirely behind a GPOS extension, so without this the real
// font's kerning would be invisible.
const (
	extSubst = 7
	extPos   = 9
)

// parseLookup appends one lookup's contribution to lay, when its type is the
// wanted one and its subtables parse.
//
// LookupList: uint16 lookupCount, offset16 lookups[]. Lookup: uint16 type,
// uint16 flag, uint16 subTableCount, offset16 subtableOffsets[] (all relative
// to the Lookup table itself).
func parseLookup(data []byte, lookupList, idx, wantType int, lay *layout) {
	base := lookupList + 2 + idx*2
	if base < 0 || base+2 > len(data) {
		return
	}
	lookup := lookupList + int(be16(data[base:base+2]))
	if lookup+6 > len(data) {
		return
	}
	lookupType := int(be16(data[lookup : lookup+2]))
	if lookupType == extSubst || lookupType == extPos {
		// Type 7 unwraps GSUB lookups, type 9 unwraps GPOS lookups.
		// A wrapper from the other table is ignored, not reinterpreted.
		if (lookupType == extSubst && wantType != 4) || (lookupType == extPos && wantType != 2) {
			return
		}
		n := int(be16(data[lookup+4 : lookup+6]))
		for i := 0; i < n; i++ {
			p := lookup + 6 + i*2
			if p+2 > len(data) {
				return
			}
			ext := lookup + int(be16(data[p:p+2]))
			if ext+8 > len(data) || int(be16(data[ext:ext+2])) != 1 {
				continue
			}
			if int(be16(data[ext+2:ext+4])) != wantType {
				continue
			}
			// uint32 offset; fonts under 4 GiB only use the low bits, but a
			// negative wrap must be rejected before it is used as an index.
			extOff := int(int64(be32(data[ext+4 : ext+8])))
			sub := ext + extOff
			if sub < 0 || sub >= len(data) {
				continue
			}
			switch wantType {
			case 4:
				parseLigatureSubtable(data, sub, lay)
			case 2:
				parsePairSubtable(data, sub, lay)
			}
		}
		return
	}
	if lookupType != wantType {
		return
	}
	n := int(be16(data[lookup+4 : lookup+6]))
	for i := 0; i < n; i++ {
		p := lookup + 6 + i*2
		if p+2 > len(data) {
			return
		}
		off := int(be16(data[p : p+2]))
		sub := lookup + off
		if sub < 0 || sub >= len(data) {
			continue
		}
		switch wantType {
		case 4:
			parseLigatureSubtable(data, sub, lay)
		case 2:
			parsePairSubtable(data, sub, lay)
		}
	}
}

// parseLigatureSubtable decodes a GSUB lookup type 4 (ligature substitution),
// format 1: coverage of first glyphs, then per-glyph ligature sets.
//
// LigatureSubstFormat1:
//
//	uint16 substFormat (=1)
//	offset16 coverage
//	uint16 ligSetCount
//	offset16 ligSet[ligSetCount]
//
// LigatureSet:
//
//	uint16 ligatureCount
//	offset16 ligatureOffsets[ligatureCount]
//
// Ligature:
//
//	uint16 ligatureGlyph
//	uint16 componentCount
//	uint16 componentGlyphIDs[componentCount-1]
func parseLigatureSubtable(data []byte, sub int, lay *layout) {
	if sub+6 > len(data) || int(be16(data[sub:sub+2])) != 1 {
		return
	}
	cov := parseCoverage(data, offsetTable(sub, be16(data[sub+2:sub+4])))
	if cov == nil {
		return
	}
	setCount := int(be16(data[sub+4 : sub+6]))
	if setCount != len(cov) {
		return
	}
	if lay.ligatures == nil {
		lay.ligatures = make(map[uint16][]ligatureSet)
	}
	for i, first := range cov {
		p := sub + 6 + i*2
		if p+2 > len(data) {
			return
		}
		set := sub + int(be16(data[p:p+2]))
		if set+2 > len(data) {
			continue
		}
		ligCount := int(be16(data[set : set+2]))
		for j := 0; j < ligCount; j++ {
			lp := set + 2 + j*2
			if lp+2 > len(data) {
				break
			}
			lo := set + int(be16(data[lp:lp+2]))
			if lo+4 > len(data) {
				continue
			}
			lig := uint16(be16(data[lo : lo+2]))
			compCount := int(be16(data[lo+2 : lo+4]))
			if compCount < 2 || compCount > 64 {
				continue
			}
			if lo+4+(compCount-1)*2 > len(data) {
				continue
			}
			comps := make([]uint16, compCount)
			comps[0] = first
			for k := 1; k < compCount; k++ {
				comps[k] = be16(data[lo+2+k*2 : lo+4+k*2])
			}
			set2 := ligatureSet{comps: comps, lig: lig}
			lay.ligatures[first] = append(lay.ligatures[first], set2)
		}
	}
	for first, sets := range lay.ligatures {
		sortLigatureSets(sets)
		lay.ligatures[first] = sets
	}
}

// sortLigatureSets orders longest-first so greedy matching takes the most
// specific ligature. Insertion sort: the lists are tiny.
func sortLigatureSets(sets []ligatureSet) {
	for i := 1; i < len(sets); i++ {
		for j := i; j > 0 && len(sets[j].comps) > len(sets[j-1].comps); j-- {
			sets[j], sets[j-1] = sets[j-1], sets[j]
		}
	}
}

// parsePairSubtable decodes a GPOS lookup type 2 (pair positioning). Format 1
// is the per-pair form, format 2 the class-matrix form; both are reduced to
// first-glyph -> second-glyph -> XAdvance. Only the XAdvance field of
// ValueRecord is consumed; everything else in the value records is ignored.
func parsePairSubtable(data []byte, sub int, lay *layout) {
	if sub+2 > len(data) {
		return
	}
	switch int(be16(data[sub : sub+2])) {
	case 1:
		parsePairFormat1(data, sub, lay)
	case 2:
		parsePairFormat2(data, sub, lay)
	}
}

// offsetTable resolves an OpenType offset16 relative to base. Offset 0 is
// NULL (the table is absent), not "the table starts at base".
func offsetTable(base int, offset uint16) int {
	if offset == 0 {
		return -1
	}
	return base + int(offset)
}

// maxRangeGlyphs caps Format-2 Coverage / ClassDef range expansion. A font
// is attacker-supplied data; a handful of 0..65535 ranges must not
// materialize unbounded slices or burn CPU.
const maxRangeGlyphs = 65536

// parseCoverage decodes a coverage table (either format) into its ordered
// glyph list. Returns nil for anything malformed.
func parseCoverage(data []byte, cov int) []uint16 {
	if cov < 0 || cov+4 > len(data) {
		return nil
	}
	switch int(be16(data[cov : cov+2])) {
	case 1:
		n := int(be16(data[cov+2 : cov+4]))
		if cov+4+n*2 > len(data) {
			return nil
		}
		out := make([]uint16, n)
		for i := 0; i < n; i++ {
			out[i] = be16(data[cov+4+i*2 : cov+6+i*2])
		}
		return out
	case 2:
		// CoverageFormat2: uint16 format, uint16 rangeCount, then
		// RangeRecords (start, end, startCoverageIndex) of 6 bytes.
		// A single range is 4+6 = 10 bytes; do not demand a 12-byte
		// header. The glyph list is the glyph ids (start..end), not
		// the startCoverageIndex column.
		n := int(be16(data[cov+2 : cov+4]))
		out := make([]uint16, 0, n)
		for i := 0; i < n; i++ {
			p := cov + 4 + i*6
			if p+6 > len(data) {
				return nil
			}
			start := be16(data[p : p+2])
			end := be16(data[p+2 : p+4])
			if end < start {
				continue
			}
			for g := start; ; g++ {
				if len(out) >= maxRangeGlyphs {
					return nil
				}
				out = append(out, g)
				if g == end {
					break
				}
			}
		}
		return out
	}
	return nil
}

// xAdvanceShift is the bit position of XAdvance in a GPOS ValueFormat mask.
// Order per spec: XPlacement, YPlacement, XAdvance, YAdvance, XPlaDevice,
// YPlaDevice, XAdvDevice, YAdvDevice (bits 0..7).
const xAdvanceShift = 2

// readXAdvance reads the XAdvance field of a value record with the given
// format at off. Bounds-checked; ok is false past the end of data.
func readXAdvance(data []byte, off int, format int) (int, bool) {
	if format&(1<<xAdvanceShift) == 0 {
		return 0, true
	}
	// ValueRecord field order: XPlacement, YPlacement, XAdvance, …
	skip := 0
	if format&0x01 != 0 {
		skip += 2
	}
	if format&0x02 != 0 {
		skip += 2
	}
	p := off + skip
	if p < 0 || p+2 > len(data) {
		return 0, false
	}
	return int(int16(be16(data[p : p+2]))), true
}

// parseValueRecord reads a GPOS value record per the given format at off and
// returns its XAdvance (the only field this package consumes) plus the offset
// past the record. Returns (0, off, false) when the record runs past the end.
func parseValueRecord(data []byte, off int, format int) (int, int, bool) {
	x, ok := readXAdvance(data, off, format)
	if !ok {
		return 0, off, false
	}
	next := off + valueLen(format)
	if next > len(data) {
		return 0, off, false
	}
	return x, next, true
}

// parsePairFormat1 decodes PairPosFormat1: one coverage of first glyphs and a
// PairSet per covered glyph, each PairSet a list of (secondGlyph, value1,
// value2) records.
//
// PairPosFormat1: uint16 posFormat, offset16 coverage, uint16 valueFormat1,
// uint16 valueFormat2, uint16 pairSetCount, offset16 pairSetOffsets[].
func parsePairFormat1(data []byte, sub int, lay *layout) {
	if sub+10 > len(data) || int(be16(data[sub:sub+2])) != 1 {
		return
	}
	cov := parseCoverage(data, offsetTable(sub, be16(data[sub+2:sub+4])))
	if cov == nil {
		return
	}
	valueFormat1 := int(be16(data[sub+4 : sub+6]))
	valueFormat2 := int(be16(data[sub+6 : sub+8]))
	pairSetCount := int(be16(data[sub+8 : sub+10]))
	if pairSetCount != len(cov) {
		return
	}
	if lay.pairs == nil {
		lay.pairs = make(map[uint16]map[uint16]int)
	}
	for i, first := range cov {
		p := sub + 10 + i*2
		if p+2 > len(data) {
			return
		}
		ps := sub + int(be16(data[p:p+2]))
		if ps+2 > len(data) {
			continue
		}
		n := int(be16(data[ps : ps+2]))
		for j := 0; j < n; j++ {
			q := ps + 2 + j*recordLen(valueFormat1, valueFormat2)
			if q+2 > len(data) {
				break
			}
			second := be16(data[q : q+2])
			x1, _, ok := parseValueRecord(data, q+2, valueFormat1)
			if !ok {
				break
			}
			if x1 == 0 {
				continue
			}
			m := lay.pairs[first]
			if m == nil {
				m = make(map[uint16]int)
				lay.pairs[first] = m
			}
			m[second] += x1
		}
	}
}

// recordLen is the byte size of one PairValueRecord for the two formats:
// uint16 secondGlyph plus both value records.
func recordLen(format1, format2 int) int {
	return 2 + valueLen(format1) + valueLen(format2)
}

// parsePairFormat2 decodes PairPosFormat2: class-based pair kerning through
// two class definition tables over one coverage of first glyphs. The class
// matrix is only consulted for (first, second) pairs the shaper actually
// asks about, so nothing is materialized up front; lookups happen in
// PairAdvance at shape time.
func parsePairFormat2(data []byte, sub int, lay *layout) {
	if sub+16 > len(data) {
		return
	}
	// PairPosFormat2 header: fmt, coverage, valueFormat1, valueFormat2,
	// classDef1, classDef2, class1Count, class2Count — value formats
	// come before the class-def offsets.
	cov := parseCoverage(data, offsetTable(sub, be16(data[sub+2:sub+4])))
	cd1 := parseClassDef(data, offsetTable(sub, be16(data[sub+8:sub+10])))
	cd2 := parseClassDef(data, offsetTable(sub, be16(data[sub+10:sub+12])))
	if cov == nil || cd1 == nil || cd2 == nil {
		return
	}
	if lay.classPairs == nil {
		lay.classPairs = make([]classPairTable, 0, 1)
	}
	lay.classPairs = append(lay.classPairs, classPairTable{
		sub:          sub,
		cov:          cov,
		cd1:          cd1,
		cd2:          cd2,
		valueFormat1: int(be16(data[sub+4 : sub+6])),
		valueFormat2: int(be16(data[sub+6 : sub+8])),
		class1Count:  int(be16(data[sub+12 : sub+14])),
		class2Count:  int(be16(data[sub+14 : sub+16])),
	})
}

// classPairTable is one deferred PairPosFormat2 subtable: resolved at shape
// time per (first, second) glyph pair instead of materialized up front — the
// class matrix of a real font can be tens of thousands of entries, and a
// screen of text asks about a few hundred pairs.
type classPairTable struct {
	sub          int
	cov          []uint16
	cd1, cd2     map[uint16]int
	valueFormat1 int
	valueFormat2 int
	class1Count  int
	class2Count  int
}

// inCoverage reports whether gid is in the table's coverage (class 0 is the
// implicit class for everything, so the coverage gate is what matters).
func (t *classPairTable) inCoverage(gid uint16) bool {
	for _, g := range t.cov {
		if g == gid {
			return true
		}
	}
	return false
}

// pairAdjust returns the XAdvance for (first, second) from this table, or
// false when the pair has no entry.
func (t *classPairTable) pairAdjust(data []byte, first, second uint16) (int, bool) {
	if !t.inCoverage(first) {
		return 0, false
	}
	c1, ok := t.cd1[first]
	if !ok {
		c1 = 0
	}
	c2, ok := t.cd2[second]
	if !ok {
		c2 = 0
	}
	if c1 >= t.class1Count || c2 >= t.class2Count {
		return 0, false
	}
	vl1, vl2 := valueLen(t.valueFormat1), valueLen(t.valueFormat2)
	off := t.sub + 16 + (int(c1)*t.class2Count+int(c2))*(vl1+vl2)
	return readXAdvance(data, off, t.valueFormat1)
}

// valueLen is the byte length of a GPOS ValueRecord for the given format.
// Each of the eight ValueFormat bits occupies a uint16 in the record
// (the four Device-table bits store an offset16, still two bytes).
func valueLen(format int) int {
	n := 0
	for bit := 0; bit < 8; bit++ {
		if format&(1<<bit) != 0 {
			n += 2
		}
	}
	return n
}

// parseClassDef decodes a class definition table (either format) into a
// glyph -> class map. Class 0 is the implicit default and is not stored.
func parseClassDef(data []byte, cd int) map[uint16]int {
	if cd < 0 || cd+4 > len(data) {
		return nil
	}
	switch int(be16(data[cd : cd+2])) {
	case 1:
		if cd+6 > len(data) {
			return nil
		}
		start := be16(data[cd+2 : cd+4])
		n := int(be16(data[cd+4 : cd+6]))
		if cd+6+n*2 > len(data) {
			return nil
		}
		m := make(map[uint16]int, n)
		for i := 0; i < n; i++ {
			if cls := int(be16(data[cd+6+i*2 : cd+8+i*2])); cls != 0 {
				m[start+uint16(i)] = cls
			}
		}
		return m
	case 2:
		n := int(be16(data[cd+2 : cd+4]))
		if cd+4+n*6 > len(data) {
			return nil
		}
		m := make(map[uint16]int, n*4)
		for i := 0; i < n; i++ {
			p := cd + 4 + i*6
			start := be16(data[p : p+2])
			end := be16(data[p+2 : p+4])
			cls := int(be16(data[p+4 : p+6]))
			if end < start || cls == 0 {
				continue
			}
			for g := start; ; g++ {
				if len(m) >= maxRangeGlyphs {
					return nil
				}
				m[g] = cls
				if g == end {
					break
				}
			}
		}
		return m
	}
	return nil
}

// ligInit parses (once) the GSUB liga feature for this face.
func (f *Face) ligInit() *layout {
	if !f.ligaInit {
		f.ligaInit = true
		f.liga = parseLayout(f.gsub, "liga", 4)
	}
	return f.liga
}

// kernLayout parses (once) the GPOS kern feature for this face.
func (f *Face) kernLayout() *layout {
	if !f.kernInit {
		f.kernInit = true
		f.kern = parseLayout(f.gpos, "kern", 2)
	}
	return f.kern
}

// PairAdvanceUPEM is the total kerning adjustment between first and second in
// font design units: the sum of every kern lookup's contribution, which is
// how HarfBuzz treats multiple lookups over one pair. Fonts without a GPOS
// kern feature always report 0.
func (f *Face) PairAdvance(first, second uint16) int {
	l := f.kernLayout()
	if l == nil {
		return 0
	}
	total := 0
	if m, ok := l.pairs[first]; ok {
		total += m[second]
	}
	for i := range l.classPairs {
		if x, ok := l.classPairs[i].pairAdjust(f.gpos, first, second); ok {
			total += x
		}
	}
	return total
}

// HasLigatures reports whether the font carries a liga feature this package
// can apply.
func (f *Face) HasLigatures() bool { return f.ligInit() != nil }

// HasKerning reports whether the font carries a kern feature this package
// can apply.
func (f *Face) HasKerning() bool { return f.kernLayout() != nil }

// ShapeLatin maps text to glyph ids through the cmap and then applies the
// opt-in layout pass: greedy longest-first ligature substitution from GSUB
// liga, then GPOS pair kerning between adjacent glyphs. Clusters are UTF-8
// byte offsets of the first rune of each cluster, so a ligature points at
// the byte offset of its first component. Advances and offsets are font
// design units; scale them with scaleUPEM via AdvanceGIDPx-style math at
// render time.
//
// The shaping model is deliberately the fixed-point form HarfBuzz uses for
// these features: ligature substitution may enable a later ligature (f + fi
// + i patterns), so the liga pass repeats until no substitution fires; pair
// positioning is one pass, in lookup order, over the final glyph stream.
// Unsupported tables, scripts, or features shape as a cmap-only no-op.
func (f *Face) ShapeLatin(text string) []ShapedGlyph {
	// cmap pass: one glyph per UTF-8 rune, clusters at rune starts.
	gids := make([]uint16, 0, len(text))
	clusters := make([]int, 0, len(text))
	for i, r := range text {
		gids = append(gids, f.GlyphIndex(r))
		clusters = append(clusters, i)
	}

	// GSUB liga: greedy left-to-right, longest component list first,
	// repeating until a full pass makes no substitution.
	if l := f.ligInit(); l != nil {
		for changed := true; changed; {
			changed = false
			out := make([]ShapedGlyph, 0, len(gids))
			for i := 0; i < len(gids); i++ {
				g := ShapedGlyph{GID: gids[i], Cluster: clusters[i]}
				matched := false
				if sets, ok := l.ligatures[gids[i]]; ok {
					for _, ls := range sets {
						if i+len(ls.comps) <= len(gids) {
							ok := true
							for k := 1; k < len(ls.comps); k++ {
								if gids[i+k] != ls.comps[k] {
									ok = false
									break
								}
							}
							if ok {
								out = append(out, ShapedGlyph{GID: ls.lig, Cluster: clusters[i]})
								i += len(ls.comps) - 1
								matched = true
								changed = true
								break
							}
						}
					}
				}
				if !matched {
					out = append(out, g)
				}
			}
			gids = gids[:0]
			clusters = clusters[:0]
			for _, s := range out {
				gids = append(gids, s.GID)
				clusters = append(clusters, s.Cluster)
			}
		}
	}

	out := make([]ShapedGlyph, len(gids))
	for i := range gids {
		out[i] = ShapedGlyph{
			GID:      gids[i],
			Cluster:  clusters[i],
			XAdvance: f.GlyphAdvanceUPEM(gids[i]),
		}
	}
	if k := f.kernLayout(); k != nil {
		for i := 0; i+1 < len(out); i++ {
			out[i].XAdvance += f.PairAdvance(gids[i], gids[i+1])
		}
	}
	return out
}

// ---------------------------------------------------------------------
// Arabic contextual shaping (M186b, #3179): a presentation-form pass, not
// a GSUB engine. Arabic's connecting letterforms are encoded in Unicode
// as contextual code points — each letter's isolated/final/initial/medial
// form lives in the Arabic Presentation Forms blocks — so shaping is a
// table-driven rewrite: classify each rune by joining type, find whether
// the nearest non-transparent neighbor on each side joins, and substitute
// the matching form's code point. The substituted rune then flows through
// the normal cmap/bidi path — bidi.go classifies the form code points AL,
// so reordered Arabic paints right-to-left with no extra work.
//
// Scope, per the card:
//   - covered: the six joining types (the generated table below lists
//     every code point the UCD types, but only Arabic-script runes have
//     presentation forms), transparent marks skipped by the neighbor
//     scan, the four contextual forms, and the lam + alef-family ligature
//     (adjacent runes only — the face carries all four pairs).
//   - refused: general GSUB/GPOS beyond this file's existing type-4
//     ligature and type-2 kerning paths, mark positioning, justification
//     and kashida, non-Arabic complex scripts, and face-aware fallback —
//     a rune with no encoded presentation form keeps its base code point.
//
// Named limitations: a combining mark BETWEEN lam and alef refuses the
// ligature — the pair still joins as initial+final while the mark paints
// at its default advance (the niqqud rule); letters without encoded
// presentation forms (parts of the extended Arabic blocks) keep their
// isolated glyph even inside a joined run.

// joinType is the ArabicShaping.txt joining class of a code point.
type joinType uint8

const (
	jtU joinType = iota // non-joining — also the default for unlisted runes
	jtR                 // right-joining: joins to the preceding logical rune
	jtD                 // dual-joining: joins both ways
	jtL                 // left-joining: joins to the following logical rune
	jtT                 // transparent: invisible to the neighbor scan
	jtC                 // join-causing: tatweel, ZWJ — joins, has no forms
)

// joinsFwd reports whether a rune of joining type t can connect to the
// FOLLOWING logical rune; joinsBack is the mirror for the preceding one.
// A join needs both sides willing.
func joinsFwd(t joinType) bool  { return t == jtD || t == jtL || t == jtC }
func joinsBack(t joinType) bool { return t == jtD || t == jtR || t == jtC }

// Arabic is the per-rune shaped view of one fragment. Form[i] is the
// presentation-form rune to paint for logical index i — zero means paint
// runes[i] unchanged — and Skip[i] marks a rune absorbed into a lam-alef
// ligature that an earlier index's Form already depicts. Indexed exactly
// like the input, so it composes with Bidi's Order/Levels/Mirror without
// re-indexing.
type Arabic struct {
	Form []rune
	Skip []bool
}

// Runes applies the view: the rune each logical index paints. Face
// resolution runs on this text, so a presentation form falls through the
// cascade exactly like a base letter does; absorbed runes keep their base
// code point so the ligature's span stays inside one face piece.
func (a *Arabic) Runes(runes []rune) []rune {
	out := make([]rune, len(runes))
	for i, r := range runes {
		if a.Form[i] != 0 {
			r = a.Form[i]
		}
		out[i] = r
	}
	return out
}

// ShapeArabic computes the Arabic contextual view of text: each rune's
// presentation form (or none) plus the lam-alef absorptions. Runes of
// every other script pass through untouched — their joining type is U.
// A nil-safe call on empty text returns an empty view.
func ShapeArabic(text string) *Arabic {
	runes := []rune(text)
	n := len(runes)
	a := &Arabic{Form: make([]rune, n), Skip: make([]bool, n)}
	if n == 0 {
		return a
	}
	jt := make([]joinType, n)
	for i, r := range runes {
		jt[i] = joinTypeOf(r)
	}
	for i, r := range runes {
		if a.Skip[i] {
			continue // absorbed into a ligature by an earlier index
		}
		switch jt[i] {
		case jtR, jtD, jtL:
		default:
			continue // U breaks the run; T and C carry no forms of their own
		}
		// Transparent marks are invisible to the neighbor scans; the first
		// non-transparent rune on each side decides the join, and both
		// sides must be willing.
		prev := false
		for j := i - 1; j >= 0; j-- {
			if jt[j] != jtT {
				prev = joinsFwd(jt[j]) && joinsBack(jt[i])
				break
			}
		}
		next := false
		for j := i + 1; j < n; j++ {
			if jt[j] != jtT {
				next = joinsFwd(jt[i]) && joinsBack(jt[j])
				break
			}
		}
		// lam + an alef family letter ligates when the pair is adjacent:
		// lam joins forward (it is jtD) and the alef joins back (jtR), so
		// adjacency is the whole condition. The ligature has only
		// isolated/final forms, chosen by lam's join to its own previous
		// rune; the alef is absorbed into it.
		if r == 0x644 && i+1 < n {
			if lig, ok := lamAlefOf(runes[i+1]); ok {
				a.Form[i] = lig.iso
				if prev {
					a.Form[i] = lig.fin
				}
				a.Skip[i+1] = true
				continue
			}
		}
		// Form order in arabFormTable: isolated, final, initial, medial.
		form := 0
		switch {
		case prev && next:
			form = 3
		case prev:
			form = 1
		case next:
			form = 2
		}
		if e := arabFormOf(r); e != nil && e.forms[form] != 0 {
			a.Form[i] = e.forms[form]
		}
	}
	return a
}

// joinTypeOf resolves a rune's joining type through the generated table.
// Unlisted code points are non-joining: the table's generation folds the
// UCD's mark/format defaults into explicit jtT entries, so a miss is a
// real U, not a table hole.
func joinTypeOf(r rune) joinType {
	lo, hi := 0, len(arabJoinTable)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		t := arabJoinTable[mid]
		switch {
		case r < t.lo:
			hi = mid - 1
		case r > t.hi:
			lo = mid + 1
		default:
			return t.jt
		}
	}
	return jtU
}

// arabFormOf finds the presentation-form set of a base code point, or nil
// when the rune encodes no contextual forms.
func arabFormOf(r rune) *arabForm {
	lo, hi := 0, len(arabFormTable)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		e := &arabFormTable[mid]
		switch {
		case r < e.base:
			hi = mid - 1
		case r > e.base:
			lo = mid + 1
		default:
			return e
		}
	}
	return nil
}

// lamAlefOf resolves an alef-family rune to its lam-alef ligature pair —
// the isolated and final lamalef code points.
func lamAlefOf(r rune) (lamAlef, bool) {
	for _, l := range arabLamAlef {
		if l.alef == r {
			return l, true
		}
	}
	return lamAlef{}, false
}

// ---------------------------------------------------------------------
// GENERATED from the Unicode Character Database 17.0.0 (Unicode License
// v3), same pipeline as bidi.go's tables:
//
//	ArabicShaping.txt  sha256 39afa01e680e27d0fd10b67a9b27be13fbaa3d0efecfb5be45991de9a0d267d0
//	UnicodeData.txt    sha256 2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c
//
// pinned under https://www.unicode.org/Public/17.0.0/ucd/. arabJoinTable
// is every listed joining type plus the unlisted Mn/Me/Cf defaults folded
// to jtT (the UCD's documented default for marks and format characters);
// everything absent resolves to jtU. arabFormTable is the Forms-A/Forms-B
// single-code-point decomposition entries — <isolated>/<final>/<initial>/
// <medial> — keyed by their base letter, in that order. arabLamAlef is
// the four lam + alef-family two-code-point decompositions.
// ---------------------------------------------------------------------

type joinRange struct {
	lo, hi rune
	jt     joinType
}

type arabForm struct {
	base  rune
	forms [4]rune // isolated, final, initial, medial; 0 = no such form
}

type lamAlef struct {
	alef     rune // the alef-family base letter
	iso, fin rune // the lamalef ligature's isolated and final forms
}

var arabJoinTable = []joinRange{
	{0x00AD, 0x00AD, jtT},
	{0x0300, 0x036F, jtT},
	{0x0483, 0x0489, jtT},
	{0x0591, 0x05BD, jtT},
	{0x05BF, 0x05BF, jtT},
	{0x05C1, 0x05C2, jtT},
	{0x05C4, 0x05C5, jtT},
	{0x05C7, 0x05C7, jtT},
	{0x0600, 0x0605, jtU},
	{0x0608, 0x0608, jtU},
	{0x060B, 0x060B, jtU},
	{0x0610, 0x061A, jtT},
	{0x061C, 0x061C, jtT},
	{0x0620, 0x0620, jtD},
	{0x0621, 0x0621, jtU},
	{0x0622, 0x0625, jtR},
	{0x0626, 0x0626, jtD},
	{0x0627, 0x0627, jtR},
	{0x0628, 0x0628, jtD},
	{0x0629, 0x0629, jtR},
	{0x062A, 0x062E, jtD},
	{0x062F, 0x0632, jtR},
	{0x0633, 0x063F, jtD},
	{0x0640, 0x0640, jtC},
	{0x0641, 0x0647, jtD},
	{0x0648, 0x0648, jtR},
	{0x0649, 0x064A, jtD},
	{0x064B, 0x065F, jtT},
	{0x066E, 0x066F, jtD},
	{0x0670, 0x0670, jtT},
	{0x0671, 0x0673, jtR},
	{0x0674, 0x0674, jtU},
	{0x0675, 0x0677, jtR},
	{0x0678, 0x0687, jtD},
	{0x0688, 0x0699, jtR},
	{0x069A, 0x06BF, jtD},
	{0x06C0, 0x06C0, jtR},
	{0x06C1, 0x06C2, jtD},
	{0x06C3, 0x06CB, jtR},
	{0x06CC, 0x06CC, jtD},
	{0x06CD, 0x06CD, jtR},
	{0x06CE, 0x06CE, jtD},
	{0x06CF, 0x06CF, jtR},
	{0x06D0, 0x06D1, jtD},
	{0x06D2, 0x06D3, jtR},
	{0x06D5, 0x06D5, jtR},
	{0x06D6, 0x06DC, jtT},
	{0x06DD, 0x06DD, jtU},
	{0x06DF, 0x06E4, jtT},
	{0x06E7, 0x06E8, jtT},
	{0x06EA, 0x06ED, jtT},
	{0x06EE, 0x06EF, jtR},
	{0x06FA, 0x06FC, jtD},
	{0x06FF, 0x06FF, jtD},
	{0x070F, 0x070F, jtT},
	{0x0710, 0x0710, jtR},
	{0x0711, 0x0711, jtT},
	{0x0712, 0x0714, jtD},
	{0x0715, 0x0719, jtR},
	{0x071A, 0x071D, jtD},
	{0x071E, 0x071E, jtR},
	{0x071F, 0x0727, jtD},
	{0x0728, 0x0728, jtR},
	{0x0729, 0x0729, jtD},
	{0x072A, 0x072A, jtR},
	{0x072B, 0x072B, jtD},
	{0x072C, 0x072C, jtR},
	{0x072D, 0x072E, jtD},
	{0x072F, 0x072F, jtR},
	{0x0730, 0x074A, jtT},
	{0x074D, 0x074D, jtR},
	{0x074E, 0x0758, jtD},
	{0x0759, 0x075B, jtR},
	{0x075C, 0x076A, jtD},
	{0x076B, 0x076C, jtR},
	{0x076D, 0x0770, jtD},
	{0x0771, 0x0771, jtR},
	{0x0772, 0x0772, jtD},
	{0x0773, 0x0774, jtR},
	{0x0775, 0x0777, jtD},
	{0x0778, 0x0779, jtR},
	{0x077A, 0x077F, jtD},
	{0x07A6, 0x07B0, jtT},
	{0x07CA, 0x07EA, jtD},
	{0x07EB, 0x07F3, jtT},
	{0x07FA, 0x07FA, jtC},
	{0x07FD, 0x07FD, jtT},
	{0x0816, 0x0819, jtT},
	{0x081B, 0x0823, jtT},
	{0x0825, 0x0827, jtT},
	{0x0829, 0x082D, jtT},
	{0x0840, 0x0840, jtR},
	{0x0841, 0x0845, jtD},
	{0x0846, 0x0847, jtR},
	{0x0848, 0x0848, jtD},
	{0x0849, 0x0849, jtR},
	{0x084A, 0x0853, jtD},
	{0x0854, 0x0854, jtR},
	{0x0855, 0x0855, jtD},
	{0x0856, 0x0858, jtR},
	{0x0859, 0x085B, jtT},
	{0x0860, 0x0860, jtD},
	{0x0861, 0x0861, jtU},
	{0x0862, 0x0865, jtD},
	{0x0866, 0x0866, jtU},
	{0x0867, 0x0867, jtR},
	{0x0868, 0x0868, jtD},
	{0x0869, 0x086A, jtR},
	{0x0870, 0x0882, jtR},
	{0x0883, 0x0885, jtC},
	{0x0886, 0x0886, jtD},
	{0x0887, 0x0888, jtU},
	{0x0889, 0x088D, jtD},
	{0x088E, 0x088E, jtR},
	{0x088F, 0x088F, jtD},
	{0x0890, 0x0891, jtU},
	{0x0897, 0x089F, jtT},
	{0x08A0, 0x08A9, jtD},
	{0x08AA, 0x08AC, jtR},
	{0x08AD, 0x08AD, jtU},
	{0x08AE, 0x08AE, jtR},
	{0x08AF, 0x08B0, jtD},
	{0x08B1, 0x08B2, jtR},
	{0x08B3, 0x08B8, jtD},
	{0x08B9, 0x08B9, jtR},
	{0x08BA, 0x08C8, jtD},
	{0x08CA, 0x08E1, jtT},
	{0x08E2, 0x08E2, jtU},
	{0x08E3, 0x0902, jtT},
	{0x093A, 0x093A, jtT},
	{0x093C, 0x093C, jtT},
	{0x0941, 0x0948, jtT},
	{0x094D, 0x094D, jtT},
	{0x0951, 0x0957, jtT},
	{0x0962, 0x0963, jtT},
	{0x0981, 0x0981, jtT},
	{0x09BC, 0x09BC, jtT},
	{0x09C1, 0x09C4, jtT},
	{0x09CD, 0x09CD, jtT},
	{0x09E2, 0x09E3, jtT},
	{0x09FE, 0x09FE, jtT},
	{0x0A01, 0x0A02, jtT},
	{0x0A3C, 0x0A3C, jtT},
	{0x0A41, 0x0A42, jtT},
	{0x0A47, 0x0A48, jtT},
	{0x0A4B, 0x0A4D, jtT},
	{0x0A51, 0x0A51, jtT},
	{0x0A70, 0x0A71, jtT},
	{0x0A75, 0x0A75, jtT},
	{0x0A81, 0x0A82, jtT},
	{0x0ABC, 0x0ABC, jtT},
	{0x0AC1, 0x0AC5, jtT},
	{0x0AC7, 0x0AC8, jtT},
	{0x0ACD, 0x0ACD, jtT},
	{0x0AE2, 0x0AE3, jtT},
	{0x0AFA, 0x0AFF, jtT},
	{0x0B01, 0x0B01, jtT},
	{0x0B3C, 0x0B3C, jtT},
	{0x0B3F, 0x0B3F, jtT},
	{0x0B41, 0x0B44, jtT},
	{0x0B4D, 0x0B4D, jtT},
	{0x0B55, 0x0B56, jtT},
	{0x0B62, 0x0B63, jtT},
	{0x0B82, 0x0B82, jtT},
	{0x0BC0, 0x0BC0, jtT},
	{0x0BCD, 0x0BCD, jtT},
	{0x0C00, 0x0C00, jtT},
	{0x0C04, 0x0C04, jtT},
	{0x0C3C, 0x0C3C, jtT},
	{0x0C3E, 0x0C40, jtT},
	{0x0C46, 0x0C48, jtT},
	{0x0C4A, 0x0C4D, jtT},
	{0x0C55, 0x0C56, jtT},
	{0x0C62, 0x0C63, jtT},
	{0x0C81, 0x0C81, jtT},
	{0x0CBC, 0x0CBC, jtT},
	{0x0CBF, 0x0CBF, jtT},
	{0x0CC6, 0x0CC6, jtT},
	{0x0CCC, 0x0CCD, jtT},
	{0x0CE2, 0x0CE3, jtT},
	{0x0D00, 0x0D01, jtT},
	{0x0D3B, 0x0D3C, jtT},
	{0x0D41, 0x0D44, jtT},
	{0x0D4D, 0x0D4D, jtT},
	{0x0D62, 0x0D63, jtT},
	{0x0D81, 0x0D81, jtT},
	{0x0DCA, 0x0DCA, jtT},
	{0x0DD2, 0x0DD4, jtT},
	{0x0DD6, 0x0DD6, jtT},
	{0x0E31, 0x0E31, jtT},
	{0x0E34, 0x0E3A, jtT},
	{0x0E47, 0x0E4E, jtT},
	{0x0EB1, 0x0EB1, jtT},
	{0x0EB4, 0x0EBC, jtT},
	{0x0EC8, 0x0ECE, jtT},
	{0x0F18, 0x0F19, jtT},
	{0x0F35, 0x0F35, jtT},
	{0x0F37, 0x0F37, jtT},
	{0x0F39, 0x0F39, jtT},
	{0x0F71, 0x0F7E, jtT},
	{0x0F80, 0x0F84, jtT},
	{0x0F86, 0x0F87, jtT},
	{0x0F8D, 0x0F97, jtT},
	{0x0F99, 0x0FBC, jtT},
	{0x0FC6, 0x0FC6, jtT},
	{0x102D, 0x1030, jtT},
	{0x1032, 0x1037, jtT},
	{0x1039, 0x103A, jtT},
	{0x103D, 0x103E, jtT},
	{0x1058, 0x1059, jtT},
	{0x105E, 0x1060, jtT},
	{0x1071, 0x1074, jtT},
	{0x1082, 0x1082, jtT},
	{0x1085, 0x1086, jtT},
	{0x108D, 0x108D, jtT},
	{0x109D, 0x109D, jtT},
	{0x135D, 0x135F, jtT},
	{0x1712, 0x1714, jtT},
	{0x1732, 0x1733, jtT},
	{0x1752, 0x1753, jtT},
	{0x1772, 0x1773, jtT},
	{0x17B4, 0x17B5, jtT},
	{0x17B7, 0x17BD, jtT},
	{0x17C6, 0x17C6, jtT},
	{0x17C9, 0x17D3, jtT},
	{0x17DD, 0x17DD, jtT},
	{0x1806, 0x1806, jtU},
	{0x1807, 0x1807, jtD},
	{0x180A, 0x180A, jtC},
	{0x180B, 0x180D, jtT},
	{0x180E, 0x180E, jtU},
	{0x180F, 0x180F, jtT},
	{0x1820, 0x1878, jtD},
	{0x1880, 0x1884, jtU},
	{0x1885, 0x1886, jtT},
	{0x1887, 0x18A8, jtD},
	{0x18A9, 0x18A9, jtT},
	{0x18AA, 0x18AA, jtD},
	{0x1920, 0x1922, jtT},
	{0x1927, 0x1928, jtT},
	{0x1932, 0x1932, jtT},
	{0x1939, 0x193B, jtT},
	{0x1A17, 0x1A18, jtT},
	{0x1A1B, 0x1A1B, jtT},
	{0x1A56, 0x1A56, jtT},
	{0x1A58, 0x1A5E, jtT},
	{0x1A60, 0x1A60, jtT},
	{0x1A62, 0x1A62, jtT},
	{0x1A65, 0x1A6C, jtT},
	{0x1A73, 0x1A7C, jtT},
	{0x1A7F, 0x1A7F, jtT},
	{0x1AB0, 0x1ADD, jtT},
	{0x1AE0, 0x1AEB, jtT},
	{0x1B00, 0x1B03, jtT},
	{0x1B34, 0x1B34, jtT},
	{0x1B36, 0x1B3A, jtT},
	{0x1B3C, 0x1B3C, jtT},
	{0x1B42, 0x1B42, jtT},
	{0x1B6B, 0x1B73, jtT},
	{0x1B80, 0x1B81, jtT},
	{0x1BA2, 0x1BA5, jtT},
	{0x1BA8, 0x1BA9, jtT},
	{0x1BAB, 0x1BAD, jtT},
	{0x1BE6, 0x1BE6, jtT},
	{0x1BE8, 0x1BE9, jtT},
	{0x1BED, 0x1BED, jtT},
	{0x1BEF, 0x1BF1, jtT},
	{0x1C2C, 0x1C33, jtT},
	{0x1C36, 0x1C37, jtT},
	{0x1CD0, 0x1CD2, jtT},
	{0x1CD4, 0x1CE0, jtT},
	{0x1CE2, 0x1CE8, jtT},
	{0x1CED, 0x1CED, jtT},
	{0x1CF4, 0x1CF4, jtT},
	{0x1CF8, 0x1CF9, jtT},
	{0x1DC0, 0x1DFF, jtT},
	{0x200B, 0x200B, jtT},
	{0x200C, 0x200C, jtU},
	{0x200D, 0x200D, jtC},
	{0x200E, 0x200F, jtT},
	{0x202A, 0x202E, jtT},
	{0x202F, 0x202F, jtU},
	{0x2060, 0x2064, jtT},
	{0x2066, 0x2069, jtU},
	{0x206A, 0x206F, jtT},
	{0x20D0, 0x20F0, jtT},
	{0x2CEF, 0x2CF1, jtT},
	{0x2D7F, 0x2D7F, jtT},
	{0x2DE0, 0x2DFF, jtT},
	{0x302A, 0x302D, jtT},
	{0x3099, 0x309A, jtT},
	{0xA66F, 0xA672, jtT},
	{0xA674, 0xA67D, jtT},
	{0xA69E, 0xA69F, jtT},
	{0xA6F0, 0xA6F1, jtT},
	{0xA802, 0xA802, jtT},
	{0xA806, 0xA806, jtT},
	{0xA80B, 0xA80B, jtT},
	{0xA825, 0xA826, jtT},
	{0xA82C, 0xA82C, jtT},
	{0xA840, 0xA871, jtD},
	{0xA872, 0xA872, jtL},
	{0xA873, 0xA873, jtU},
	{0xA8C4, 0xA8C5, jtT},
	{0xA8E0, 0xA8F1, jtT},
	{0xA8FF, 0xA8FF, jtT},
	{0xA926, 0xA92D, jtT},
	{0xA947, 0xA951, jtT},
	{0xA980, 0xA982, jtT},
	{0xA9B3, 0xA9B3, jtT},
	{0xA9B6, 0xA9B9, jtT},
	{0xA9BC, 0xA9BD, jtT},
	{0xA9E5, 0xA9E5, jtT},
	{0xAA29, 0xAA2E, jtT},
	{0xAA31, 0xAA32, jtT},
	{0xAA35, 0xAA36, jtT},
	{0xAA43, 0xAA43, jtT},
	{0xAA4C, 0xAA4C, jtT},
	{0xAA7C, 0xAA7C, jtT},
	{0xAAB0, 0xAAB0, jtT},
	{0xAAB2, 0xAAB4, jtT},
	{0xAAB7, 0xAAB8, jtT},
	{0xAABE, 0xAABF, jtT},
	{0xAAC1, 0xAAC1, jtT},
	{0xAAEC, 0xAAED, jtT},
	{0xAAF6, 0xAAF6, jtT},
	{0xABE5, 0xABE5, jtT},
	{0xABE8, 0xABE8, jtT},
	{0xABED, 0xABED, jtT},
	{0xFB1E, 0xFB1E, jtT},
	{0xFE00, 0xFE0F, jtT},
	{0xFE20, 0xFE2F, jtT},
	{0xFEFF, 0xFEFF, jtT},
	{0xFFF9, 0xFFFB, jtT},
	{0x101FD, 0x101FD, jtT},
	{0x102E0, 0x102E0, jtT},
	{0x10376, 0x1037A, jtT},
	{0x10A01, 0x10A03, jtT},
	{0x10A05, 0x10A06, jtT},
	{0x10A0C, 0x10A0F, jtT},
	{0x10A38, 0x10A3A, jtT},
	{0x10A3F, 0x10A3F, jtT},
	{0x10AC0, 0x10AC4, jtD},
	{0x10AC5, 0x10AC5, jtR},
	{0x10AC6, 0x10AC6, jtU},
	{0x10AC7, 0x10AC7, jtR},
	{0x10AC8, 0x10AC8, jtU},
	{0x10AC9, 0x10ACA, jtR},
	{0x10ACB, 0x10ACC, jtU},
	{0x10ACD, 0x10ACD, jtL},
	{0x10ACE, 0x10AD2, jtR},
	{0x10AD3, 0x10AD6, jtD},
	{0x10AD7, 0x10AD7, jtL},
	{0x10AD8, 0x10ADC, jtD},
	{0x10ADD, 0x10ADD, jtR},
	{0x10ADE, 0x10AE0, jtD},
	{0x10AE1, 0x10AE1, jtR},
	{0x10AE2, 0x10AE3, jtU},
	{0x10AE4, 0x10AE4, jtR},
	{0x10AE5, 0x10AE6, jtT},
	{0x10AEB, 0x10AEE, jtD},
	{0x10AEF, 0x10AEF, jtR},
	{0x10B80, 0x10B80, jtD},
	{0x10B81, 0x10B81, jtR},
	{0x10B82, 0x10B82, jtD},
	{0x10B83, 0x10B85, jtR},
	{0x10B86, 0x10B88, jtD},
	{0x10B89, 0x10B89, jtR},
	{0x10B8A, 0x10B8B, jtD},
	{0x10B8C, 0x10B8C, jtR},
	{0x10B8D, 0x10B8D, jtD},
	{0x10B8E, 0x10B8F, jtR},
	{0x10B90, 0x10B90, jtD},
	{0x10B91, 0x10B91, jtR},
	{0x10BA9, 0x10BAC, jtR},
	{0x10BAD, 0x10BAE, jtD},
	{0x10BAF, 0x10BAF, jtU},
	{0x10D00, 0x10D00, jtL},
	{0x10D01, 0x10D21, jtD},
	{0x10D22, 0x10D22, jtR},
	{0x10D23, 0x10D23, jtD},
	{0x10D24, 0x10D27, jtT},
	{0x10D69, 0x10D6D, jtT},
	{0x10EAB, 0x10EAC, jtT},
	{0x10EC2, 0x10EC2, jtR},
	{0x10EC3, 0x10EC4, jtD},
	{0x10EC6, 0x10EC7, jtD},
	{0x10EFA, 0x10EFF, jtT},
	{0x10F30, 0x10F32, jtD},
	{0x10F33, 0x10F33, jtR},
	{0x10F34, 0x10F44, jtD},
	{0x10F45, 0x10F45, jtU},
	{0x10F46, 0x10F50, jtT},
	{0x10F51, 0x10F53, jtD},
	{0x10F54, 0x10F54, jtR},
	{0x10F70, 0x10F73, jtD},
	{0x10F74, 0x10F75, jtR},
	{0x10F76, 0x10F81, jtD},
	{0x10F82, 0x10F85, jtT},
	{0x10FB0, 0x10FB0, jtD},
	{0x10FB1, 0x10FB1, jtU},
	{0x10FB2, 0x10FB3, jtD},
	{0x10FB4, 0x10FB6, jtR},
	{0x10FB7, 0x10FB7, jtU},
	{0x10FB8, 0x10FB8, jtD},
	{0x10FB9, 0x10FBA, jtR},
	{0x10FBB, 0x10FBC, jtD},
	{0x10FBD, 0x10FBD, jtR},
	{0x10FBE, 0x10FBF, jtD},
	{0x10FC0, 0x10FC0, jtU},
	{0x10FC1, 0x10FC1, jtD},
	{0x10FC2, 0x10FC3, jtR},
	{0x10FC4, 0x10FC4, jtD},
	{0x10FC5, 0x10FC8, jtU},
	{0x10FC9, 0x10FC9, jtR},
	{0x10FCA, 0x10FCA, jtD},
	{0x10FCB, 0x10FCB, jtL},
	{0x11001, 0x11001, jtT},
	{0x11038, 0x11046, jtT},
	{0x11070, 0x11070, jtT},
	{0x11073, 0x11074, jtT},
	{0x1107F, 0x11081, jtT},
	{0x110B3, 0x110B6, jtT},
	{0x110B9, 0x110BA, jtT},
	{0x110BD, 0x110BD, jtU},
	{0x110C2, 0x110C2, jtT},
	{0x110CD, 0x110CD, jtU},
	{0x11100, 0x11102, jtT},
	{0x11127, 0x1112B, jtT},
	{0x1112D, 0x11134, jtT},
	{0x11173, 0x11173, jtT},
	{0x11180, 0x11181, jtT},
	{0x111B6, 0x111BE, jtT},
	{0x111C9, 0x111CC, jtT},
	{0x111CF, 0x111CF, jtT},
	{0x1122F, 0x11231, jtT},
	{0x11234, 0x11234, jtT},
	{0x11236, 0x11237, jtT},
	{0x1123E, 0x1123E, jtT},
	{0x11241, 0x11241, jtT},
	{0x112DF, 0x112DF, jtT},
	{0x112E3, 0x112EA, jtT},
	{0x11300, 0x11301, jtT},
	{0x1133B, 0x1133C, jtT},
	{0x11340, 0x11340, jtT},
	{0x11366, 0x1136C, jtT},
	{0x11370, 0x11374, jtT},
	{0x113BB, 0x113C0, jtT},
	{0x113CE, 0x113CE, jtT},
	{0x113D0, 0x113D0, jtT},
	{0x113D2, 0x113D2, jtT},
	{0x113E1, 0x113E2, jtT},
	{0x11438, 0x1143F, jtT},
	{0x11442, 0x11444, jtT},
	{0x11446, 0x11446, jtT},
	{0x1145E, 0x1145E, jtT},
	{0x114B3, 0x114B8, jtT},
	{0x114BA, 0x114BA, jtT},
	{0x114BF, 0x114C0, jtT},
	{0x114C2, 0x114C3, jtT},
	{0x115B2, 0x115B5, jtT},
	{0x115BC, 0x115BD, jtT},
	{0x115BF, 0x115C0, jtT},
	{0x115DC, 0x115DD, jtT},
	{0x11633, 0x1163A, jtT},
	{0x1163D, 0x1163D, jtT},
	{0x1163F, 0x11640, jtT},
	{0x116AB, 0x116AB, jtT},
	{0x116AD, 0x116AD, jtT},
	{0x116B0, 0x116B5, jtT},
	{0x116B7, 0x116B7, jtT},
	{0x1171D, 0x1171D, jtT},
	{0x1171F, 0x1171F, jtT},
	{0x11722, 0x11725, jtT},
	{0x11727, 0x1172B, jtT},
	{0x1182F, 0x11837, jtT},
	{0x11839, 0x1183A, jtT},
	{0x1193B, 0x1193C, jtT},
	{0x1193E, 0x1193E, jtT},
	{0x11943, 0x11943, jtT},
	{0x119D4, 0x119D7, jtT},
	{0x119DA, 0x119DB, jtT},
	{0x119E0, 0x119E0, jtT},
	{0x11A01, 0x11A0A, jtT},
	{0x11A33, 0x11A38, jtT},
	{0x11A3B, 0x11A3E, jtT},
	{0x11A47, 0x11A47, jtT},
	{0x11A51, 0x11A56, jtT},
	{0x11A59, 0x11A5B, jtT},
	{0x11A8A, 0x11A96, jtT},
	{0x11A98, 0x11A99, jtT},
	{0x11B60, 0x11B60, jtT},
	{0x11B62, 0x11B64, jtT},
	{0x11B66, 0x11B66, jtT},
	{0x11C30, 0x11C36, jtT},
	{0x11C38, 0x11C3D, jtT},
	{0x11C3F, 0x11C3F, jtT},
	{0x11C92, 0x11CA7, jtT},
	{0x11CAA, 0x11CB0, jtT},
	{0x11CB2, 0x11CB3, jtT},
	{0x11CB5, 0x11CB6, jtT},
	{0x11D31, 0x11D36, jtT},
	{0x11D3A, 0x11D3A, jtT},
	{0x11D3C, 0x11D3D, jtT},
	{0x11D3F, 0x11D45, jtT},
	{0x11D47, 0x11D47, jtT},
	{0x11D90, 0x11D91, jtT},
	{0x11D95, 0x11D95, jtT},
	{0x11D97, 0x11D97, jtT},
	{0x11EF3, 0x11EF4, jtT},
	{0x11F00, 0x11F01, jtT},
	{0x11F36, 0x11F3A, jtT},
	{0x11F40, 0x11F40, jtT},
	{0x11F42, 0x11F42, jtT},
	{0x11F5A, 0x11F5A, jtT},
	{0x13430, 0x13440, jtT},
	{0x13447, 0x13455, jtT},
	{0x1611E, 0x16129, jtT},
	{0x1612D, 0x1612F, jtT},
	{0x16AF0, 0x16AF4, jtT},
	{0x16B30, 0x16B36, jtT},
	{0x16F4F, 0x16F4F, jtT},
	{0x16F8F, 0x16F92, jtT},
	{0x16FE4, 0x16FE4, jtT},
	{0x1BC9D, 0x1BC9E, jtT},
	{0x1BCA0, 0x1BCA3, jtT},
	{0x1CF00, 0x1CF2D, jtT},
	{0x1CF30, 0x1CF46, jtT},
	{0x1D167, 0x1D169, jtT},
	{0x1D173, 0x1D182, jtT},
	{0x1D185, 0x1D18B, jtT},
	{0x1D1AA, 0x1D1AD, jtT},
	{0x1D242, 0x1D244, jtT},
	{0x1DA00, 0x1DA36, jtT},
	{0x1DA3B, 0x1DA6C, jtT},
	{0x1DA75, 0x1DA75, jtT},
	{0x1DA84, 0x1DA84, jtT},
	{0x1DA9B, 0x1DA9F, jtT},
	{0x1DAA1, 0x1DAAF, jtT},
	{0x1E000, 0x1E006, jtT},
	{0x1E008, 0x1E018, jtT},
	{0x1E01B, 0x1E021, jtT},
	{0x1E023, 0x1E024, jtT},
	{0x1E026, 0x1E02A, jtT},
	{0x1E08F, 0x1E08F, jtT},
	{0x1E130, 0x1E136, jtT},
	{0x1E2AE, 0x1E2AE, jtT},
	{0x1E2EC, 0x1E2EF, jtT},
	{0x1E4EC, 0x1E4EF, jtT},
	{0x1E5EE, 0x1E5EF, jtT},
	{0x1E6E3, 0x1E6E3, jtT},
	{0x1E6E6, 0x1E6E6, jtT},
	{0x1E6EE, 0x1E6EF, jtT},
	{0x1E6F5, 0x1E6F5, jtT},
	{0x1E8D0, 0x1E8D6, jtT},
	{0x1E900, 0x1E943, jtD},
	{0x1E944, 0x1E94B, jtT},
	{0xE0001, 0xE0001, jtT},
	{0xE0020, 0xE007F, jtT},
	{0xE0100, 0xE01EF, jtT},
}

var arabFormTable = []arabForm{
	{0x0621, [4]rune{0xFE80, 0, 0, 0}},
	{0x0622, [4]rune{0xFE81, 0xFE82, 0, 0}},
	{0x0623, [4]rune{0xFE83, 0xFE84, 0, 0}},
	{0x0624, [4]rune{0xFE85, 0xFE86, 0, 0}},
	{0x0625, [4]rune{0xFE87, 0xFE88, 0, 0}},
	{0x0626, [4]rune{0xFE89, 0xFE8A, 0xFE8B, 0xFE8C}},
	{0x0627, [4]rune{0xFE8D, 0xFE8E, 0, 0}},
	{0x0628, [4]rune{0xFE8F, 0xFE90, 0xFE91, 0xFE92}},
	{0x0629, [4]rune{0xFE93, 0xFE94, 0, 0}},
	{0x062A, [4]rune{0xFE95, 0xFE96, 0xFE97, 0xFE98}},
	{0x062B, [4]rune{0xFE99, 0xFE9A, 0xFE9B, 0xFE9C}},
	{0x062C, [4]rune{0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0}},
	{0x062D, [4]rune{0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4}},
	{0x062E, [4]rune{0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8}},
	{0x062F, [4]rune{0xFEA9, 0xFEAA, 0, 0}},
	{0x0630, [4]rune{0xFEAB, 0xFEAC, 0, 0}},
	{0x0631, [4]rune{0xFEAD, 0xFEAE, 0, 0}},
	{0x0632, [4]rune{0xFEAF, 0xFEB0, 0, 0}},
	{0x0633, [4]rune{0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4}},
	{0x0634, [4]rune{0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8}},
	{0x0635, [4]rune{0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC}},
	{0x0636, [4]rune{0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0}},
	{0x0637, [4]rune{0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4}},
	{0x0638, [4]rune{0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8}},
	{0x0639, [4]rune{0xFEC9, 0xFECA, 0xFECB, 0xFECC}},
	{0x063A, [4]rune{0xFECD, 0xFECE, 0xFECF, 0xFED0}},
	{0x0641, [4]rune{0xFED1, 0xFED2, 0xFED3, 0xFED4}},
	{0x0642, [4]rune{0xFED5, 0xFED6, 0xFED7, 0xFED8}},
	{0x0643, [4]rune{0xFED9, 0xFEDA, 0xFEDB, 0xFEDC}},
	{0x0644, [4]rune{0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0}},
	{0x0645, [4]rune{0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4}},
	{0x0646, [4]rune{0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8}},
	{0x0647, [4]rune{0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC}},
	{0x0648, [4]rune{0xFEED, 0xFEEE, 0, 0}},
	{0x0649, [4]rune{0xFEEF, 0xFEF0, 0xFBE8, 0xFBE9}},
	{0x064A, [4]rune{0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4}},
	{0x0671, [4]rune{0xFB50, 0xFB51, 0, 0}},
	{0x0677, [4]rune{0xFBDD, 0, 0, 0}},
	{0x0679, [4]rune{0xFB66, 0xFB67, 0xFB68, 0xFB69}},
	{0x067A, [4]rune{0xFB5E, 0xFB5F, 0xFB60, 0xFB61}},
	{0x067B, [4]rune{0xFB52, 0xFB53, 0xFB54, 0xFB55}},
	{0x067E, [4]rune{0xFB56, 0xFB57, 0xFB58, 0xFB59}},
	{0x067F, [4]rune{0xFB62, 0xFB63, 0xFB64, 0xFB65}},
	{0x0680, [4]rune{0xFB5A, 0xFB5B, 0xFB5C, 0xFB5D}},
	{0x0683, [4]rune{0xFB76, 0xFB77, 0xFB78, 0xFB79}},
	{0x0684, [4]rune{0xFB72, 0xFB73, 0xFB74, 0xFB75}},
	{0x0686, [4]rune{0xFB7A, 0xFB7B, 0xFB7C, 0xFB7D}},
	{0x0687, [4]rune{0xFB7E, 0xFB7F, 0xFB80, 0xFB81}},
	{0x0688, [4]rune{0xFB88, 0xFB89, 0, 0}},
	{0x068C, [4]rune{0xFB84, 0xFB85, 0, 0}},
	{0x068D, [4]rune{0xFB82, 0xFB83, 0, 0}},
	{0x068E, [4]rune{0xFB86, 0xFB87, 0, 0}},
	{0x0691, [4]rune{0xFB8C, 0xFB8D, 0, 0}},
	{0x0698, [4]rune{0xFB8A, 0xFB8B, 0, 0}},
	{0x06A4, [4]rune{0xFB6A, 0xFB6B, 0xFB6C, 0xFB6D}},
	{0x06A6, [4]rune{0xFB6E, 0xFB6F, 0xFB70, 0xFB71}},
	{0x06A9, [4]rune{0xFB8E, 0xFB8F, 0xFB90, 0xFB91}},
	{0x06AD, [4]rune{0xFBD3, 0xFBD4, 0xFBD5, 0xFBD6}},
	{0x06AF, [4]rune{0xFB92, 0xFB93, 0xFB94, 0xFB95}},
	{0x06B1, [4]rune{0xFB9A, 0xFB9B, 0xFB9C, 0xFB9D}},
	{0x06B3, [4]rune{0xFB96, 0xFB97, 0xFB98, 0xFB99}},
	{0x06BA, [4]rune{0xFB9E, 0xFB9F, 0, 0}},
	{0x06BB, [4]rune{0xFBA0, 0xFBA1, 0xFBA2, 0xFBA3}},
	{0x06BE, [4]rune{0xFBAA, 0xFBAB, 0xFBAC, 0xFBAD}},
	{0x06C0, [4]rune{0xFBA4, 0xFBA5, 0, 0}},
	{0x06C1, [4]rune{0xFBA6, 0xFBA7, 0xFBA8, 0xFBA9}},
	{0x06C5, [4]rune{0xFBE0, 0xFBE1, 0, 0}},
	{0x06C6, [4]rune{0xFBD9, 0xFBDA, 0, 0}},
	{0x06C7, [4]rune{0xFBD7, 0xFBD8, 0, 0}},
	{0x06C8, [4]rune{0xFBDB, 0xFBDC, 0, 0}},
	{0x06C9, [4]rune{0xFBE2, 0xFBE3, 0, 0}},
	{0x06CB, [4]rune{0xFBDE, 0xFBDF, 0, 0}},
	{0x06CC, [4]rune{0xFBFC, 0xFBFD, 0xFBFE, 0xFBFF}},
	{0x06D0, [4]rune{0xFBE4, 0xFBE5, 0xFBE6, 0xFBE7}},
	{0x06D2, [4]rune{0xFBAE, 0xFBAF, 0, 0}},
	{0x06D3, [4]rune{0xFBB0, 0xFBB1, 0, 0}},
}

var arabLamAlef = []lamAlef{
	{0x0622, 0xFEF5, 0xFEF6},
	{0x0623, 0xFEF7, 0xFEF8},
	{0x0625, 0xFEF9, 0xFEFA},
	{0x0627, 0xFEFB, 0xFEFC},
}
