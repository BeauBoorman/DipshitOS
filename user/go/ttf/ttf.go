// Package ttf is a freestanding TrueType (.ttf) parser and metrics engine for
// VirelaiOS EL0 userland.
//
// It is written from scratch in pure Go: no cgo, no golang.org/x/image, and no
// dependency on (or FFI into) the Zig engine it sits beside
// (user/src/lib/font_ttf.zig). The only import is the standard library's
// "errors", and nothing here touches the OS — the package builds identically
// for the host test runner and for GOOS=virelai.
//
// Parsed tables: head, maxp, hhea, hmtx, cmap (formats 0/4/6/12), loca, glyf.
// Glyph outline decoding lives in outline.go; coverage-antialiased rasterizing
// and 32-bpp blending live in raster.go; the ergonomic face + glyph cache
// lives in face.go.
//
// Every table access is bounds-checked and every malformed input returns a
// typed error (or a safe empty result) — never a panic. A font is attacker-
// supplied data; that rule is not negotiable.
package ttf

import "errors"

// Sentinel errors. Parse and the accessors return one of these instead of
// panicking on malformed input.
var (
	// ErrNotTrueType is returned for an sfnt whose version is not TrueType
	// outlines — notably 'OTTO' (CFF/PostScript outlines), which this
	// package deliberately does not support.
	ErrNotTrueType = errors.New("ttf: not a TrueType sfnt (want 0x00010000 or 'true')")
	// ErrMalformed covers a bad table directory or a table whose declared
	// extent runs past the end of the file.
	ErrMalformed = errors.New("ttf: malformed table directory or table data")
	// ErrMissingTable means a table this package requires is absent.
	ErrMissingTable = errors.New("ttf: required table missing")
	// ErrNoCmap means the cmap table carries no Unicode subtable we can use.
	ErrNoCmap = errors.New("ttf: no usable Unicode cmap subtable")
	// ErrNoGlyph means the requested glyph id is outside the font.
	ErrNoGlyph = errors.New("ttf: glyph index out of range")
)

// sfnt versions this package accepts.
const (
	sfntTrueType = 0x00010000
	sfntTrue     = 0x74727565 // 'true' (Apple's original TrueType tag)
)

// Table tags as big-endian words, so a directory entry is matched with one
// integer compare rather than a string allocation.
const (
	tagHead = 0x68656164
	tagHhea = 0x68686561
	tagHmtx = 0x686d7478
	tagMaxp = 0x6d617870
	tagCmap = 0x636d6170
	tagLoca = 0x6c6f6361
	tagGlyf = 0x676c7966
	tagGSUB = 0x47535542 // 'GSUB'
	tagGPOS = 0x47504f53 // 'GPOS'
)

// Big-endian readers. Every caller brackets these with a bounds check.
func be16(b []byte) uint16 { return uint16(b[0])<<8 | uint16(b[1]) }
func be32(b []byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

// cmapGroup is one format-12 group: codepoints start..end map to
// gid..gid+(end-start).
type cmapGroup struct {
	start, end, gid uint32
}

// cmapSeg is one format-4 segment, stored in resolved form: delta is the
// idDelta (signed) and glyphOff is the absolute byte offset of the segment's
// idRangeOffset entry inside the font file (used to walk
// idRangeOffset + 2*(code-start)). glyphOff == 0 means "use idDelta only".
type cmapSeg struct {
	start, end uint16
	delta      int16
	glyphOff   int
}

// Face is a parsed TrueType font. It holds slices of the caller's font bytes:
// the caller must keep that buffer alive and unmodified for the Face's life.
type Face struct {
	data []byte

	unitsPerEm  int
	locFormat   int
	numGlyphs   int
	numHMetrics int
	ascender    int
	descender   int
	lineGap     int

	hmtx []byte
	loca []byte
	glyf []byte
	gsub []byte
	gpos []byte

	// Exactly one of these cmap representations is populated.
	groups  []cmapGroup
	segs    []cmapSeg
	byteMap []byte

	cache *glyphCache

	// Lazily parsed layout features (shape.go). ligaInit/kernInit record
	// whether the parse was attempted so a font without the tables does
	// not re-parse per call.
	ligaInit, kernInit bool
	liga               *layout
	kern               *layout
}

// Parse reads the sfnt directory and the tables this package needs. It returns
// ErrNotTrueType for non-TrueType sfnts (including 'OTTO'), ErrMalformed for a
// directory or table that runs past the file, and ErrMissingTable when a
// required table is absent. It never panics on malformed input.
func Parse(data []byte) (*Face, error) {
	if len(data) < 12 {
		return nil, ErrMalformed
	}
	version := be32(data[0:4])
	if version != sfntTrueType && version != sfntTrue {
		return nil, ErrNotTrueType
	}
	numTables := int(be16(data[4:6]))
	if numTables <= 0 || len(data) < 12+numTables*16 {
		return nil, ErrMalformed
	}

	var head, hhea, hmtx, maxp, cmap, loca, glyf, gsub, gpos []byte
	cmapOff := 0
	for i := 0; i < numTables; i++ {
		off := 12 + i*16
		tag := be32(data[off : off+4])
		tOff := int(be32(data[off+8 : off+12]))
		tLen := int(be32(data[off+12 : off+16]))
		if tOff < 0 || tLen < 0 || tOff > len(data) || tLen > len(data)-tOff {
			return nil, ErrMalformed
		}
		slice := data[tOff : tOff+tLen]
		switch tag {
		case tagHead:
			head = slice
		case tagHhea:
			hhea = slice
		case tagHmtx:
			hmtx = slice
		case tagMaxp:
			maxp = slice
		case tagCmap:
			cmap = slice
			cmapOff = tOff
		case tagLoca:
			loca = slice
		case tagGlyf:
			glyf = slice
		case tagGSUB:
			gsub = slice
		case tagGPOS:
			gpos = slice
		}
	}
	if head == nil || hhea == nil || hmtx == nil || maxp == nil || cmap == nil || loca == nil || glyf == nil {
		return nil, ErrMissingTable
	}
	if len(head) < 54 || len(hhea) < 36 || len(maxp) < 6 {
		return nil, ErrMalformed
	}

	f := &Face{
		data:       data,
		hmtx:       hmtx,
		loca:       loca,
		glyf:       glyf,
		gsub:       gsub,
		gpos:       gpos,
		unitsPerEm: int(be16(head[18:20])),
		locFormat:  int(int16(be16(head[50:52]))),
		numGlyphs:  int(be16(maxp[4:6])),
	}
	f.numHMetrics = int(be16(hhea[34:36]))
	f.ascender = int(int16(be16(hhea[4:6])))
	f.descender = int(int16(be16(hhea[6:8])))
	f.lineGap = int(int16(be16(hhea[8:10])))

	if f.unitsPerEm <= 0 || f.unitsPerEm > 16384 {
		return nil, ErrMalformed
	}
	if f.locFormat != 0 && f.locFormat != 1 {
		return nil, ErrMalformed
	}
	// A font whose hmtx claims more metrics than it has glyphs is broken but
	// exists in the wild. Clamp rather than read past the end.
	if f.numHMetrics > f.numGlyphs {
		f.numHMetrics = f.numGlyphs
	}
	if f.numHMetrics < 1 && f.numGlyphs > 0 {
		f.numHMetrics = 1
	}

	// loca must hold numGlyphs+1 offsets of locFormat's width.
	entry := 2
	if f.locFormat == 1 {
		entry = 4
	}
	if len(f.loca) < (f.numGlyphs+1)*entry {
		return nil, ErrMalformed
	}

	if err := f.parseCmap(cmap, cmapOff); err != nil {
		return nil, err
	}
	f.cache = newGlyphCache(defaultCacheEntries)
	return f, nil
}

// parseCmap selects the best Unicode subtable and resolves it into one of the
// internal representations. Preference order matches every other TrueType
// consumer: a full format-12 Unicode map beats BMP-only format 4.
// cmapOff is the table's byte offset inside the font file: format-4
// idRangeOffset walks produce glyphOff values that must be file-absolute
// because GlyphIndex reads them out of f.data. Every face that shipped
// before NOTOHEB resolved through format 12, so the relative-offset bug
// only surfaced when a fmt4-only face with glyphArray segments arrived.
func (f *Face) parseCmap(cmap []byte, cmapOff int) error {
	if len(cmap) < 4 {
		return ErrMalformed
	}
	n := int(be16(cmap[2:4]))
	if n < 0 || len(cmap) < 4+n*8 {
		return ErrMalformed
	}

	bestScore := -1
	bestOff := 0
	bestFmt := 0
	for i := 0; i < n; i++ {
		p := 4 + i*8
		plat := be16(cmap[p : p+2])
		enc := be16(cmap[p+2 : p+4])
		off := int(be32(cmap[p+4 : p+8]))
		if off < 0 || off+2 > len(cmap) {
			continue
		}
		format := int(be16(cmap[off : off+2]))
		score := -1
		switch {
		case format == 12 && (plat == 0 || plat == 3):
			score = 100 // full Unicode
		case format == 4 && plat == 3 && enc == 1:
			score = 80 // Windows BMP
		case format == 4 && plat == 0:
			score = 70 // Unicode BMP
		case format == 6 && (plat == 0 || plat == 3):
			score = 40
		case format == 0:
			score = 20
		}
		if score > bestScore {
			bestScore, bestOff, bestFmt = score, off, format
		}
	}
	if bestScore < 0 {
		return ErrNoCmap
	}
	switch bestFmt {
	case 12:
		return f.parseCmap12(cmap, bestOff)
	case 4:
		return f.parseCmap4(cmap, bestOff, cmapOff)
	case 6:
		return f.parseCmap6(cmap, bestOff)
	case 0:
		return f.parseCmap0(cmap, bestOff)
	}
	return ErrNoCmap
}

func (f *Face) parseCmap12(cmap []byte, off int) error {
	if off+16 > len(cmap) {
		return ErrMalformed
	}
	length := int(be32(cmap[off+4 : off+8]))
	nGroups := int(be32(cmap[off+12 : off+16]))
	if nGroups < 0 {
		return ErrMalformed
	}
	if length > 0 && off+length <= len(cmap) && off+16+nGroups*12 > off+length {
		return ErrMalformed
	}
	if nGroups > (len(cmap)-off-16)/12 {
		return ErrMalformed
	}
	groups := make([]cmapGroup, 0, nGroups)
	for i := 0; i < nGroups; i++ {
		p := off + 16 + i*12
		g := cmapGroup{
			start: be32(cmap[p : p+4]),
			end:   be32(cmap[p+4 : p+8]),
			gid:   be32(cmap[p+8 : p+12]),
		}
		if g.end < g.start {
			continue
		}
		groups = append(groups, g)
	}
	if len(groups) == 0 {
		return ErrNoCmap
	}
	f.groups = groups
	return nil
}

func (f *Face) parseCmap4(cmap []byte, off int, cmapOff int) error {
	if off+14 > len(cmap) {
		return ErrMalformed
	}
	segX2 := int(be16(cmap[off+6 : off+8]))
	if segX2 < 2 || segX2%2 != 0 {
		return ErrMalformed
	}
	seg := segX2 / 2
	need := segX2*4 + 2
	if off+14+need > len(cmap) {
		return ErrMalformed
	}
	endBase := off + 14
	startBase := endBase + segX2 + 2
	deltaBase := startBase + segX2
	rangeBase := deltaBase + segX2

	segs := make([]cmapSeg, 0, seg)
	for i := 0; i < seg; i++ {
		start := be16(cmap[startBase+2*i : startBase+2*i+2])
		end := be16(cmap[endBase+2*i : endBase+2*i+2])
		delta := int16(be16(cmap[deltaBase+2*i : deltaBase+2*i+2]))
		rOff := int(be16(cmap[rangeBase+2*i : rangeBase+2*i+2]))
		s := cmapSeg{start: start, end: end, delta: delta}
		if rOff != 0 {
			s.glyphOff = cmapOff + rangeBase + 2*i + rOff
		}
		segs = append(segs, s)
	}
	if len(segs) == 0 {
		return ErrNoCmap
	}
	f.segs = segs
	return nil
}

func (f *Face) parseCmap6(cmap []byte, off int) error {
	if off+10 > len(cmap) {
		return ErrMalformed
	}
	first := int(be16(cmap[off+6 : off+8]))
	count := int(be16(cmap[off+8 : off+10]))
	if count < 0 || count*2 > len(cmap)-off-10 {
		return ErrMalformed
	}
	groups := make([]cmapGroup, 0, count)
	for i := 0; i < count; i++ {
		g := be16(cmap[off+10+i*2 : off+12+i*2])
		if g == 0 {
			continue
		}
		groups = append(groups, cmapGroup{
			start: uint32(first + i),
			end:   uint32(first + i),
			gid:   uint32(g),
		})
	}
	if len(groups) == 0 {
		return ErrNoCmap
	}
	f.groups = groups
	return nil
}

func (f *Face) parseCmap0(cmap []byte, off int) error {
	if off+262 > len(cmap) {
		return ErrMalformed
	}
	m := make([]byte, 256)
	copy(m, cmap[off+6:off+262])
	f.byteMap = m
	return nil
}

// UnitsPerEm is the font's design grid (2048 for Inter, 1950 for Fira Code).
func (f *Face) UnitsPerEm() int { return f.unitsPerEm }

// NumGlyphs is the glyph count from maxp.
func (f *Face) NumGlyphs() int { return f.numGlyphs }

// NumHMetrics is the effective numberOfHMetrics (clamped to numGlyphs).
func (f *Face) NumHMetrics() int { return f.numHMetrics }

// IndexToLocFormat is head.indexToLocFormat: 0 = short loca (u16 * 2),
// 1 = long loca (u32). Both shipped faces use the long form.
func (f *Face) IndexToLocFormat() int { return f.locFormat }

// GlyphIndex maps a Unicode code point to a glyph id. An unmapped rune yields
// 0 (.notdef) — a normal outcome, not an error; callers keep advancing so
// unmapped text stays visible rather than vanishing.
func (f *Face) GlyphIndex(r rune) uint16 {
	if r < 0 {
		return 0
	}
	cp := uint32(r)
	if f.byteMap != nil {
		if cp < 256 {
			return uint16(f.byteMap[cp])
		}
		return 0
	}
	if f.groups != nil {
		lo, hi := 0, len(f.groups)-1
		for lo <= hi {
			mid := (lo + hi) / 2
			g := f.groups[mid]
			switch {
			case cp < g.start:
				hi = mid - 1
			case cp > g.end:
				lo = mid + 1
			default:
				gid := g.gid + (cp - g.start)
				if gid > 0xffff {
					return 0
				}
				return uint16(gid)
			}
		}
		return 0
	}
	if cp > 0xffff {
		return 0
	}
	code := uint16(cp)
	segs := f.segs
	lo, hi := 0, len(segs)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		s := segs[mid]
		switch {
		case code < s.start:
			hi = mid - 1
		case code > s.end:
			lo = mid + 1
		default:
			if s.glyphOff == 0 {
				return uint16(int32(code) + int32(s.delta))
			}
			p := s.glyphOff + 2*int(code-s.start)
			if p < 0 || p+2 > len(f.data) {
				return 0
			}
			g := be16(f.data[p : p+2])
			if g == 0 {
				return 0
			}
			return uint16(int32(g) + int32(s.delta))
		}
	}
	return 0
}

// GlyphAdvanceUPEM is the glyph's advance width in font design units, straight
// out of hmtx. Glyphs at or past numberOfHMetrics share the last entry's
// advance, as the spec requires.
func (f *Face) GlyphAdvanceUPEM(gid uint16) int {
	if f.numHMetrics == 0 {
		return 0
	}
	i := int(gid)
	if i >= f.numHMetrics {
		i = f.numHMetrics - 1
	}
	off := i * 4
	if off+2 > len(f.hmtx) {
		return 0
	}
	return int(be16(f.hmtx[off : off+2]))
}

// GlyphLSB is the glyph's left side bearing in font design units: from hmtx
// for the metrics-bearing glyphs, from the trailing lsb-only array otherwise.
func (f *Face) GlyphLSB(gid uint16) int {
	i := int(gid)
	if i >= f.numGlyphs {
		return 0
	}
	if i < f.numHMetrics {
		off := i*4 + 2
		if off+2 > len(f.hmtx) {
			return 0
		}
		return int(int16(be16(f.hmtx[off : off+2])))
	}
	off := f.numHMetrics*4 + 2*(i-f.numHMetrics)
	if off+2 > len(f.hmtx) {
		return 0
	}
	return int(int16(be16(f.hmtx[off : off+2])))
}

// AdvancePx scales the glyph's advance to a pixel size, rounded to nearest with
// ties away from zero. Integer and deterministic.
func (f *Face) AdvancePx(r rune, px int) int {
	if px <= 0 {
		return 0
	}
	return scaleUPEM(f.GlyphAdvanceUPEM(f.GlyphIndex(r)), px, f.unitsPerEm)
}

// scaleUPEM converts a design-unit value to pixels at size px, rounding half
// away from zero. Integer-only, so repeated runs are byte-identical.
func scaleUPEM(v, px, upem int) int {
	if upem <= 0 {
		return 0
	}
	n := int64(v) * int64(px)
	if n >= 0 {
		return int((n + int64(upem)/2) / int64(upem))
	}
	return -int((-n + int64(upem)/2) / int64(upem))
}

// LineMetrics returns the vertical metrics in pixels at size px: ascent above
// the baseline, descent below it, and the extra line gap. All non-negative.
func (f *Face) LineMetrics(px int) (ascent, descent, lineGap int) {
	a := scaleUPEM(f.ascender, px, f.unitsPerEm)
	d := scaleUPEM(f.descender, px, f.unitsPerEm)
	if a < 0 {
		a = -a
	}
	if d < 0 {
		d = -d
	}
	g := scaleUPEM(f.lineGap, px, f.unitsPerEm)
	if g < 0 {
		g = 0
	}
	return a, d, g
}

// Measure is the pixel advance of a whole string at size px. It is the sum of
// the per-rune advances, so it agrees with AdvancePx by construction.
func (f *Face) Measure(text string, px int) int {
	if px <= 0 {
		return 0
	}
	total := 0
	for _, r := range text {
		total += f.AdvancePx(r, px)
	}
	return total
}

// GlyphData returns the glyf bytes for a glyph id. An empty glyph (such as
// space, or a glyph whose loca offsets are equal) returns a zero-length slice
// and no error — a legal, renderable glyph, not a failure.
func (f *Face) GlyphData(gid uint16) ([]byte, error) {
	if int(gid) >= f.numGlyphs {
		return nil, ErrNoGlyph
	}
	start, ok := f.locaOffset(int(gid))
	if !ok {
		return nil, ErrMalformed
	}
	end, ok := f.locaOffset(int(gid) + 1)
	if !ok {
		return nil, ErrMalformed
	}
	if end < start || start > len(f.glyf) || end > len(f.glyf) {
		return nil, ErrMalformed
	}
	return f.glyf[start:end], nil
}

// locaOffset reads the i-th loca entry (0..numGlyphs).
func (f *Face) locaOffset(i int) (int, bool) {
	if i < 0 {
		return 0, false
	}
	if f.locFormat == 0 {
		off := i * 2
		if off+2 > len(f.loca) {
			return 0, false
		}
		return int(be16(f.loca[off:off+2])) * 2, true
	}
	off := i * 4
	if off+4 > len(f.loca) {
		return 0, false
	}
	v := be32(f.loca[off : off+4])
	if v > uint32(len(f.glyf)) {
		return 0, false
	}
	return int(v), true
}
