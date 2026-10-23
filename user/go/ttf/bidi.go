package ttf

// UAX #9 bidirectional resolution for ONE painted line fragment (M178a,
// #3144). The web renderer feeds it the text of one line box (the unit a
// Paint call sees); it answers with the visual order, per-rune resolved
// levels, and the bracket-mirroring substitution. The algorithm lives here,
// not in the renderer, so any painter — canvas text, dialogs — can reuse it.
//
// Scope, per the card:
//   - covered: rules P2/P3 (paragraph level from the first strong rune),
//     W1–W7, N0 (paired brackets), N1/N2, I1/I2, L1 (trailing-whitespace
//     reset only — a fragment is already one line), L2 and L4.
//   - refused: explicit embeddings, overrides and isolates
//     (U+202A–U+202E, U+2066–U+2069). They classify as BN — boundary
//     neutral — drop out of every resolution scan, and never paint.
//   - one fragment is one paragraph and one isolating run sequence: no
//     embeddings exist to split it, so sos = eos = the paragraph direction.
//   - Arabic is classified AL (so adjacent digits and neutrals resolve
//     correctly) even though no shipped face covers its glyphs; the
//     joining/shaping that real Arabic needs is out of scope.
//   - combining marks (niqqud) get the preceding rune's class under W1 and
//     paint at their default advance — no mark positioning.
//
// The class table and the paired-bracket maps at the bottom of this file are
// GENERATED from the Unicode Character Database 17.0.0 (Unicode License v3,
// permissive — the card's D6):
//
//	DerivedBidiClass.txt  sha256 4867b4b7f0731ed1bfcd34cc6251211ff1542541fce0734b6fbda139ee80b3a4
//	BidiBrackets.txt      sha256 dadbaf38a0d0246e5b805bf8725cb81b7c621f93d030595635f5ba2c2f179428
//
// pinned under https://www.unicode.org/Public/17.0.0/ucd/. The table covers
// Latin, Greek, Cyrillic, Hebrew, Arabic, digits, common punctuation and the
// paired brackets; a code point outside it resolves to L, which is the UCD
// default for everything but the RTL blocks anyway and keeps uncovered text
// (CJK, emoji) painting left-to-right exactly as before.

type bidiClass uint8

const (
	bcL   bidiClass = iota // left-to-right
	bcR                    // right-to-left (Hebrew, and AL after W3)
	bcAL                   // Arabic letter — refused glyphs, resolved class
	bcEN                   // European number
	bcAN                   // Arabic number
	bcES                   // European number separator
	bcET                   // European number terminator
	bcCS                   // common separator
	bcB                    // paragraph separator
	bcS                    // segment separator
	bcWS                   // whitespace
	bcON                   // other neutral (punctuation, brackets, symbols)
	bcNSM                  // non-spacing mark
	bcBN                   // boundary neutral — incl. the refused explicit codes
)

// Paragraph directions accepted by Bidi: a forced level for conformance
// vectors, or BidiAuto for P2/P3 first-strong resolution.
const (
	BidiLTR  = 0
	BidiRTL  = 1
	BidiAuto = -1
)

// Visual is the resolved bidi form of one text run. Order lists the logical
// rune indices in visual (left-to-right) paint order; BN-classified runes —
// the refused explicit codes — are dropped from it. Levels is the resolved
// embedding level per logical rune (0xFF for a dropped rune). Mirror[i] is
// the L4 substitution for a paired bracket at an odd level, 0 elsewhere.
// RTL reports an odd paragraph embedding level.
type Visual struct {
	Order  []int
	Levels []uint8
	Mirror []rune
	RTL    bool
}

// Bidi resolves text under the UAX #9 subset this package implements. dir is
// BidiLTR/BidiRTL to force the paragraph embedding level, or BidiAuto to take
// it from the first strong rune (rules P2–P3). A nil-safe call on empty text
// returns an empty Visual.
func Bidi(text string, dir int) *Visual {
	runes := []rune(text)
	n := len(runes)
	v := &Visual{Levels: make([]uint8, n), Mirror: make([]rune, n)}
	if n == 0 {
		return v
	}
	cls := make([]bidiClass, n)  // working types
	orig := make([]bidiClass, n) // pre-W1 types: N0 needs the original NSMs
	kept := make([]int, 0, n)    // logical indices minus the refused BN codes
	for i, r := range runes {
		c := bidiClassOf(r)
		orig[i], cls[i] = c, c
		if c == bcBN {
			v.Levels[i] = 0xFF
			continue
		}
		kept = append(kept, i)
	}

	// P2/P3: paragraph embedding level from the first strong rune.
	para := 0
	switch dir {
	case BidiLTR, BidiRTL:
		para = dir
	default:
		for _, i := range kept {
			if cls[i] == bcR || cls[i] == bcAL {
				para = 1
			}
			if cls[i] == bcL || cls[i] == bcR || cls[i] == bcAL {
				break
			}
		}
	}
	v.RTL = para == 1
	// The boundary types of the one isolating run sequence this fragment is.
	sos := bcL
	if para == 1 {
		sos = bcR
	}
	eos := sos
	emb := bcL
	if para == 1 {
		emb = bcR
	}

	// W1: an NSM takes the (resolved) type of the preceding character, sos at
	// the sequence boundary.
	prev := sos
	for _, i := range kept {
		if cls[i] == bcNSM {
			cls[i] = prev
		} else {
			prev = cls[i]
		}
	}
	// W2: EN -> AN when the first strong back (or sos) is AL.
	for p, i := range kept {
		if cls[i] != bcEN {
			continue
		}
		strong := sos
		for q := p - 1; q >= 0; q-- {
			if c := cls[kept[q]]; c == bcL || c == bcR || c == bcAL {
				strong = c
				break
			}
		}
		if strong == bcAL {
			cls[i] = bcAN
		}
	}
	// W3: every AL becomes R.
	for _, i := range kept {
		if cls[i] == bcAL {
			cls[i] = bcR
		}
	}
	// W4: a single ES flanked by EN, or a single CS flanked by matching
	// number classes, joins the numbers.
	for p, i := range kept {
		if p == 0 || p+1 >= len(kept) {
			continue
		}
		l, r := cls[kept[p-1]], cls[kept[p+1]]
		switch cls[i] {
		case bcES:
			if l == bcEN && r == bcEN {
				cls[i] = bcEN
			}
		case bcCS:
			if l == r && (l == bcEN || l == bcAN) {
				cls[i] = l
			}
		}
	}
	// W5: a run of ET adjacent to an EN becomes all EN.
	for p := 0; p < len(kept); {
		if cls[kept[p]] != bcET {
			p++
			continue
		}
		q := p
		for q < len(kept) && cls[kept[q]] == bcET {
			q++
		}
		if (p > 0 && cls[kept[p-1]] == bcEN) || (q < len(kept) && cls[kept[q]] == bcEN) {
			for k := p; k < q; k++ {
				cls[kept[k]] = bcEN
			}
		}
		p = q
	}
	// W6: separators and terminators not absorbed become ON.
	for _, i := range kept {
		if c := cls[i]; c == bcES || c == bcET || c == bcCS {
			cls[i] = bcON
		}
	}
	// W7: EN becomes L when the first strong back (or sos) is L.
	for p, i := range kept {
		if cls[i] != bcEN {
			continue
		}
		strong := sos
		for q := p - 1; q >= 0; q-- {
			if c := cls[kept[q]]; c == bcL || c == bcR {
				strong = c
				break
			}
		}
		if strong == bcL {
			cls[i] = bcL
		}
	}

	// N0: paired brackets (BD16 pairing, then the enclosed/established-context
	// resolution, processed in opening order).
	for _, pr := range bidiBracketPairs(runes, kept) {
		// EN and AN count as R inside the N0 strong searches.
		hasEmb, hasOpp := false, false
		for _, i := range kept {
			if i <= pr.open || i >= pr.close {
				continue
			}
			switch bidiStrong(cls[i]) {
			case emb:
				hasEmb = true
			case bcL, bcR:
				hasOpp = true
			}
		}
		var set bidiClass
		switch {
		case hasEmb:
			set = emb
		case hasOpp:
			// Established context: the pair takes the direction of the
			// strong type preceding it (sos when there is none) — the two
			// N0 outcomes both equal that type.
			set = sos
			for i := pr.open - 1; i >= 0; i-- {
				if c := bidiStrong(cls[i]); c != bcNone {
					set = c
					break
				}
			}
		default:
			continue // no strong inside: N1/N2 resolve it later
		}
		for _, pos := range []int{pr.open, pr.close} {
			cls[pos] = set
			// Original-NSM runes immediately following a retyped bracket
			// take its new class (the N0 tail rule).
			for j := pos + 1; j < n && orig[j] == bcNSM; j++ {
				cls[j] = set
			}
		}
	}

	// N1/N2: neutral runs take the surrounding strong direction when both
	// sides agree (EN/AN count as R), else the embedding direction.
	for p := 0; p < len(kept); {
		i := kept[p]
		if bidiIsStrongOrNum(cls[i]) {
			p++
			continue
		}
		q := p
		for q < len(kept) && !bidiIsStrongOrNum(cls[kept[q]]) {
			q++
		}
		bef, aft := sos, eos
		for s := p - 1; s >= 0; s-- {
			if c := bidiStrong(cls[kept[s]]); c != bcNone {
				bef = c
				break
			}
		}
		for s := q; s < len(kept); s++ {
			if c := bidiStrong(cls[kept[s]]); c != bcNone {
				aft = c
				break
			}
		}
		set := emb
		if bef == aft {
			set = bef
		}
		for k := p; k < q; k++ {
			cls[kept[k]] = set
		}
		p = q
	}

	// I1/I2: implicit levels off the resolved types.
	for _, i := range kept {
		lev := para
		switch cls[i] {
		case bcR:
			if para == 0 {
				lev++
			}
		case bcEN, bcAN:
			lev++
			if para == 0 {
				lev++
			}
		case bcB, bcS:
			lev = para
		default: // resolved L — including the neutrals N-rules assigned
			if para == 1 {
				lev++
			}
		}
		v.Levels[i] = uint8(lev)
	}
	// L1: trailing whitespace/separators reset to the paragraph level. A
	// fragment never carries B/S mid-line, so the trailing run is all the
	// rule can reach here.
	for k := len(kept) - 1; k >= 0; k-- {
		i := kept[k]
		if c := orig[i]; c == bcWS || c == bcB || c == bcS {
			v.Levels[i] = uint8(para)
			continue
		}
		break
	}

	// L2: from the highest level down to the lowest odd level — counting the
	// paragraph level when odd — reverse each contiguous run at that level
	// or higher.
	v.Order = append(v.Order, kept...)
	maxLev, minOdd := para, -1
	for _, i := range v.Order {
		l := int(v.Levels[i])
		if l > maxLev {
			maxLev = l
		}
		if l&1 == 1 && (minOdd < 0 || l < minOdd) {
			minOdd = l
		}
	}
	if para&1 == 1 && (minOdd < 0 || para < minOdd) {
		minOdd = para
	}
	for lev := maxLev; minOdd >= 0 && lev >= minOdd; lev-- {
		for p := 0; p < len(v.Order); {
			if int(v.Levels[v.Order[p]]) >= lev {
				q := p
				for q < len(v.Order) && int(v.Levels[v.Order[q]]) >= lev {
					q++
				}
				for a, b := p, q-1; a < b; a, b = a+1, b-1 {
					v.Order[a], v.Order[b] = v.Order[b], v.Order[a]
				}
				p = q
			} else {
				p++
			}
		}
	}

	// L4: a paired bracket at an odd level depicts its counterpart.
	for _, i := range kept {
		if v.Levels[i]&1 == 0 {
			continue
		}
		if m, ok := bidiPairOpen[runes[i]]; ok {
			v.Mirror[i] = m
		} else if m, ok := bidiPairClose[runes[i]]; ok {
			v.Mirror[i] = m
		}
	}
	return v
}

// bidiClassOf resolves a rune's class through the generated table; code
// points outside the covered ranges report L.
func bidiClassOf(r rune) bidiClass {
	lo, hi := 0, len(bidiTable)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		t := bidiTable[mid]
		switch {
		case r < t.lo:
			hi = mid - 1
		case r > t.hi:
			lo = mid + 1
		default:
			return t.cls
		}
	}
	return bcL
}

// bidiStrong normalizes a resolved class for the strong-type scans of N0/N1:
// EN and AN act as R there; a non-strong answer is bcNone (bcL is zero and
// must stay distinguishable).
func bidiStrong(c bidiClass) bidiClass {
	switch c {
	case bcEN, bcAN:
		return bcR
	case bcL, bcR:
		return c
	}
	return bcNone
}

// bcNone marks "not a strong type" in the N0/N1 scans — never a table class.
const bcNone bidiClass = 0xFF

// bidiIsStrongOrNum is the N1 sequence boundary test: everything left over
// that is not L, R, EN or AN is neutral.
func bidiIsStrongOrNum(c bidiClass) bool {
	return c == bcL || c == bcR || c == bcEN || c == bcAN
}

type bidiPairElem struct {
	want rune // the closing bracket this opener waits for
	pos  int  // logical rune index of the opener
}

type bidiPairSpan struct{ open, close int }

// bidiBracketPairs identifies the paired brackets of the fragment per BD16:
// opens push {expected closer, position} onto a 63-deep stack; a closer walks
// the stack downward for its match and, on finding it, pops through the
// match. The result is sorted by opening position, as N0 requires.
func bidiBracketPairs(runes []rune, kept []int) []bidiPairSpan {
	var stack []bidiPairElem
	var pairs []bidiPairSpan
	for _, i := range kept {
		r := runes[i]
		if want, ok := bidiPairOpen[r]; ok {
			if len(stack) == 63 {
				return nil // stack full: BD16 abandons pairing for the run
			}
			stack = append(stack, bidiPairElem{want, i})
			continue
		}
		if _, ok := bidiPairClose[r]; !ok {
			continue
		}
		for s := len(stack) - 1; s >= 0; s-- {
			if stack[s].want == r {
				pairs = append(pairs, bidiPairSpan{stack[s].pos, i})
				stack = stack[:s]
				break
			}
		}
	}
	// Insertion sort by opening position; a fragment has a handful of pairs.
	for i := 1; i < len(pairs); i++ {
		for j := i; j > 0 && pairs[j].open < pairs[j-1].open; j-- {
			pairs[j], pairs[j-1] = pairs[j-1], pairs[j]
		}
	}
	return pairs
}

// ---------------------------------------------------------------------
// GENERATED from the Unicode Character Database 17.0.0 (Unicode License
// v3): DerivedBidiClass.txt sha256
// 4867b4b7f0731ed1bfcd34cc6251211ff1542541fce0734b6fbda139ee80b3a4 and
// BidiBrackets.txt sha256
// dadbaf38a0d0246e5b805bf8725cb81b7c621f93d030595635f5ba2c2f179428.
// Coverage is the card's named set — Latin, Greek, Cyrillic, Hebrew,
// Arabic, digits, common punctuation and the paired brackets; everything
// outside bidiTable resolves to L, the UCD default. The explicit
// embeddings/overrides/isolates (U+202A–U+202E, U+2066–U+2069) are
// recorded as BN: they are refused, not implemented.
// ---------------------------------------------------------------------

type bidiRange struct {
	lo, hi rune
	cls    bidiClass
}

var bidiTable = []bidiRange{
	{0x0020, 0x0020, bcWS},
	{0x0021, 0x0022, bcON},
	{0x0023, 0x0025, bcET},
	{0x0026, 0x002A, bcON},
	{0x002B, 0x002B, bcES},
	{0x002C, 0x002C, bcCS},
	{0x002D, 0x002D, bcES},
	{0x002E, 0x002F, bcCS},
	{0x0030, 0x0039, bcEN},
	{0x003A, 0x003A, bcCS},
	{0x003B, 0x0040, bcON},
	{0x0041, 0x005A, bcL},
	{0x005B, 0x0060, bcON},
	{0x0061, 0x007A, bcL},
	{0x007B, 0x007E, bcON},
	{0x00A0, 0x00A0, bcCS},
	{0x00A1, 0x00A1, bcON},
	{0x00A2, 0x00A5, bcET},
	{0x00A6, 0x00A9, bcON},
	{0x00AA, 0x00AA, bcL},
	{0x00AB, 0x00AC, bcON},
	{0x00AD, 0x00AD, bcBN},
	{0x00AE, 0x00AF, bcON},
	{0x00B0, 0x00B1, bcET},
	{0x00B2, 0x00B3, bcEN},
	{0x00B4, 0x00B4, bcON},
	{0x00B5, 0x00B5, bcL},
	{0x00B6, 0x00B8, bcON},
	{0x00B9, 0x00B9, bcEN},
	{0x00BA, 0x00BA, bcL},
	{0x00BB, 0x00BF, bcON},
	{0x00C0, 0x00D6, bcL},
	{0x00D7, 0x00D7, bcON},
	{0x00D8, 0x00F6, bcL},
	{0x00F7, 0x00F7, bcON},
	{0x00F8, 0x00FF, bcL},
	{0x0100, 0x017F, bcL},
	{0x0180, 0x024F, bcL},
	{0x0250, 0x02AF, bcL},
	{0x02B0, 0x02B8, bcL},
	{0x02B9, 0x02BA, bcON},
	{0x02BB, 0x02C1, bcL},
	{0x02C2, 0x02CF, bcON},
	{0x02D0, 0x02D1, bcL},
	{0x02D2, 0x02DF, bcON},
	{0x02E0, 0x02E4, bcL},
	{0x02E5, 0x02ED, bcON},
	{0x02EE, 0x02EE, bcL},
	{0x02EF, 0x02FF, bcON},
	{0x0300, 0x036F, bcNSM},
	{0x0370, 0x0373, bcL},
	{0x0374, 0x0375, bcON},
	{0x0376, 0x037D, bcL},
	{0x037E, 0x037E, bcON},
	{0x037F, 0x0383, bcL},
	{0x0384, 0x0385, bcON},
	{0x0386, 0x0386, bcL},
	{0x0387, 0x0387, bcON},
	{0x0388, 0x03F5, bcL},
	{0x03F6, 0x03F6, bcON},
	{0x03F7, 0x03FF, bcL},
	{0x0400, 0x0482, bcL},
	{0x0483, 0x0489, bcNSM},
	{0x048A, 0x04FF, bcL},
	{0x0500, 0x052F, bcL},
	{0x0590, 0x0590, bcL},
	{0x0591, 0x05BD, bcNSM},
	{0x05BE, 0x05BE, bcR},
	{0x05BF, 0x05BF, bcNSM},
	{0x05C0, 0x05C0, bcR},
	{0x05C1, 0x05C2, bcNSM},
	{0x05C3, 0x05C3, bcR},
	{0x05C4, 0x05C5, bcNSM},
	{0x05C6, 0x05C6, bcR},
	{0x05C7, 0x05C7, bcNSM},
	{0x05C8, 0x05CF, bcL},
	{0x05D0, 0x05EA, bcR},
	{0x05EB, 0x05EE, bcL},
	{0x05EF, 0x05F4, bcR},
	{0x05F5, 0x05FF, bcL},
	{0x0600, 0x0605, bcAN},
	{0x0606, 0x0607, bcON},
	{0x0608, 0x0608, bcAL},
	{0x0609, 0x060A, bcET},
	{0x060B, 0x060B, bcAL},
	{0x060C, 0x060C, bcCS},
	{0x060D, 0x060D, bcAL},
	{0x060E, 0x060F, bcON},
	{0x0610, 0x061A, bcNSM},
	{0x061B, 0x064A, bcAL},
	{0x064B, 0x065F, bcNSM},
	{0x0660, 0x0669, bcAN},
	{0x066A, 0x066A, bcET},
	{0x066B, 0x066C, bcAN},
	{0x066D, 0x066F, bcAL},
	{0x0670, 0x0670, bcNSM},
	{0x0671, 0x06D5, bcAL},
	{0x06D6, 0x06DC, bcNSM},
	{0x06DD, 0x06DD, bcAN},
	{0x06DE, 0x06DE, bcON},
	{0x06DF, 0x06E4, bcNSM},
	{0x06E5, 0x06E6, bcAL},
	{0x06E7, 0x06E8, bcNSM},
	{0x06E9, 0x06E9, bcON},
	{0x06EA, 0x06ED, bcNSM},
	{0x06EE, 0x06EF, bcAL},
	{0x06F0, 0x06F9, bcEN},
	{0x06FA, 0x06FF, bcAL},
	{0x0750, 0x077F, bcAL},
	{0x08A0, 0x08C9, bcAL},
	{0x08CA, 0x08E1, bcNSM},
	{0x08E2, 0x08E2, bcAN},
	{0x08E3, 0x08FF, bcNSM},
	{0x1E00, 0x1EFF, bcL},
	{0x1F00, 0x1FBC, bcL},
	{0x1FBD, 0x1FBD, bcON},
	{0x1FBE, 0x1FBE, bcL},
	{0x1FBF, 0x1FC1, bcON},
	{0x1FC2, 0x1FCC, bcL},
	{0x1FCD, 0x1FCF, bcON},
	{0x1FD0, 0x1FDC, bcL},
	{0x1FDD, 0x1FDF, bcON},
	{0x1FE0, 0x1FEC, bcL},
	{0x1FED, 0x1FEF, bcON},
	{0x1FF0, 0x1FFC, bcL},
	{0x1FFD, 0x1FFE, bcON},
	{0x1FFF, 0x1FFF, bcL},
	{0x2000, 0x200A, bcWS},
	{0x200B, 0x200D, bcBN},
	{0x200E, 0x200E, bcL},
	{0x200F, 0x200F, bcR},
	{0x2010, 0x2027, bcON},
	{0x2028, 0x2028, bcWS},
	{0x2029, 0x2029, bcB},
	{0x202A, 0x202E, bcBN},
	{0x202F, 0x202F, bcCS},
	{0x2030, 0x2034, bcET},
	{0x2035, 0x2043, bcON},
	{0x2044, 0x2044, bcCS},
	{0x2045, 0x205E, bcON},
	{0x205F, 0x205F, bcWS},
	{0x2060, 0x206F, bcBN},
	{0x2070, 0x2070, bcEN},
	{0x2071, 0x2073, bcL},
	{0x2074, 0x2079, bcEN},
	{0x207A, 0x207B, bcES},
	{0x207C, 0x207E, bcON},
	{0x207F, 0x207F, bcL},
	{0x2080, 0x2089, bcEN},
	{0x208A, 0x208B, bcES},
	{0x208C, 0x208E, bcON},
	{0x208F, 0x209F, bcL},
	{0x20A0, 0x20BF, bcET},
	{0x20D0, 0x20F0, bcNSM},
	{0x20F1, 0x20FF, bcL},
	{0x2100, 0x2101, bcON},
	{0x2102, 0x2102, bcL},
	{0x2103, 0x2106, bcON},
	{0x2107, 0x2107, bcL},
	{0x2108, 0x2109, bcON},
	{0x210A, 0x2113, bcL},
	{0x2114, 0x2114, bcON},
	{0x2115, 0x2115, bcL},
	{0x2116, 0x2118, bcON},
	{0x2119, 0x211D, bcL},
	{0x211E, 0x2123, bcON},
	{0x2124, 0x2124, bcL},
	{0x2125, 0x2125, bcON},
	{0x2126, 0x2126, bcL},
	{0x2127, 0x2127, bcON},
	{0x2128, 0x2128, bcL},
	{0x2129, 0x2129, bcON},
	{0x212A, 0x212D, bcL},
	{0x212E, 0x212E, bcET},
	{0x212F, 0x2139, bcL},
	{0x213A, 0x213B, bcON},
	{0x213C, 0x213F, bcL},
	{0x2140, 0x2144, bcON},
	{0x2145, 0x2149, bcL},
	{0x214A, 0x214D, bcON},
	{0x214E, 0x214F, bcL},
	{0x2150, 0x215F, bcON},
	{0x2160, 0x2188, bcL},
	{0x2189, 0x218B, bcON},
	{0x218C, 0x218F, bcL},
	{0x2190, 0x21FF, bcON},
	{0x2200, 0x2211, bcON},
	{0x2212, 0x2212, bcES},
	{0x2213, 0x2213, bcET},
	{0x2214, 0x22FF, bcON},
	{0x2300, 0x2335, bcON},
	{0x2336, 0x237A, bcL},
	{0x237B, 0x2394, bcON},
	{0x2395, 0x2395, bcL},
	{0x2396, 0x23FF, bcON},
	{0x2460, 0x2487, bcON},
	{0x2488, 0x249B, bcEN},
	{0x249C, 0x24E9, bcL},
	{0x24EA, 0x24FF, bcON},
	{0x2500, 0x257F, bcON},
	{0x2580, 0x259F, bcON},
	{0x25A0, 0x25FF, bcON},
	{0x2600, 0x26AB, bcON},
	{0x26AC, 0x26AC, bcL},
	{0x26AD, 0x26FF, bcON},
	{0x2700, 0x27BF, bcON},
	{0x27C0, 0x27EF, bcON},
	{0x2980, 0x29FF, bcON},
	{0x2E00, 0x2E5D, bcON},
	{0x2E5E, 0x2E7F, bcL},
	{0xFB1D, 0xFB1D, bcR},
	{0xFB1E, 0xFB1E, bcNSM},
	{0xFB1F, 0xFB28, bcR},
	{0xFB29, 0xFB29, bcES},
	{0xFB2A, 0xFB36, bcR},
	{0xFB37, 0xFB37, bcL},
	{0xFB38, 0xFB3C, bcR},
	{0xFB3D, 0xFB3D, bcL},
	{0xFB3E, 0xFB3E, bcR},
	{0xFB3F, 0xFB3F, bcL},
	{0xFB40, 0xFB41, bcR},
	{0xFB42, 0xFB42, bcL},
	{0xFB43, 0xFB44, bcR},
	{0xFB45, 0xFB45, bcL},
	{0xFB46, 0xFB4F, bcR},
	{0xFB50, 0xFBC2, bcAL},
	{0xFBC3, 0xFBD2, bcON},
	{0xFBD3, 0xFD3D, bcAL},
	{0xFD3E, 0xFD4F, bcON},
	{0xFD50, 0xFD8F, bcAL},
	{0xFD90, 0xFD91, bcON},
	{0xFD92, 0xFDC7, bcAL},
	{0xFDC8, 0xFDCF, bcON},
	{0xFDD0, 0xFDEF, bcBN},
	{0xFDF0, 0xFDFC, bcAL},
	{0xFDFD, 0xFDFF, bcON},
	{0xFE50, 0xFE50, bcCS},
	{0xFE51, 0xFE51, bcON},
	{0xFE52, 0xFE52, bcCS},
	{0xFE53, 0xFE53, bcL},
	{0xFE54, 0xFE54, bcON},
	{0xFE55, 0xFE55, bcCS},
	{0xFE56, 0xFE5E, bcON},
	{0xFE5F, 0xFE5F, bcET},
	{0xFE60, 0xFE61, bcON},
	{0xFE62, 0xFE63, bcES},
	{0xFE64, 0xFE66, bcON},
	{0xFE67, 0xFE67, bcL},
	{0xFE68, 0xFE68, bcON},
	{0xFE69, 0xFE6A, bcET},
	{0xFE6B, 0xFE6B, bcON},
	{0xFE6C, 0xFE6F, bcL},
	{0xFE70, 0xFE74, bcAL},
	{0xFE75, 0xFE75, bcL},
	{0xFE76, 0xFEFC, bcAL},
	{0xFEFD, 0xFEFE, bcL},
	{0xFEFF, 0xFEFF, bcBN},
	{0xFF00, 0xFF00, bcL},
	{0xFF01, 0xFF02, bcON},
	{0xFF03, 0xFF05, bcET},
	{0xFF06, 0xFF0A, bcON},
	{0xFF0B, 0xFF0B, bcES},
	{0xFF0C, 0xFF0C, bcCS},
	{0xFF0D, 0xFF0D, bcES},
	{0xFF0E, 0xFF0F, bcCS},
	{0xFF10, 0xFF19, bcEN},
	{0xFF1A, 0xFF1A, bcCS},
	{0xFF1B, 0xFF20, bcON},
	{0xFF21, 0xFF3A, bcL},
	{0xFF3B, 0xFF40, bcON},
	{0xFF41, 0xFF5A, bcL},
	{0xFF5B, 0xFF65, bcON},
}

// bidiPairOpen maps each covered opening paired bracket to its
// closer; bidiPairClose is the reverse map. N0 pairs through them;
// L4 mirrors through them. (U+3008/U+3009 <-> U+2329/U+232A canonical
// equivalence is outside the covered ranges and so unimplemented.)
var bidiPairOpen = map[rune]rune{
	0x0028: 0x0029,
	0x005B: 0x005D,
	0x007B: 0x007D,
	0x2045: 0x2046,
	0x207D: 0x207E,
	0x208D: 0x208E,
	0x2308: 0x2309,
	0x230A: 0x230B,
	0x2329: 0x232A,
	0x2768: 0x2769,
	0x276A: 0x276B,
	0x276C: 0x276D,
	0x276E: 0x276F,
	0x2770: 0x2771,
	0x2772: 0x2773,
	0x2774: 0x2775,
	0x27C5: 0x27C6,
	0x27E6: 0x27E7,
	0x27E8: 0x27E9,
	0x27EA: 0x27EB,
	0x27EC: 0x27ED,
	0x27EE: 0x27EF,
	0x2983: 0x2984,
	0x2985: 0x2986,
	0x2987: 0x2988,
	0x2989: 0x298A,
	0x298B: 0x298C,
	0x298D: 0x2990,
	0x298F: 0x298E,
	0x2991: 0x2992,
	0x2993: 0x2994,
	0x2995: 0x2996,
	0x2997: 0x2998,
	0x29D8: 0x29D9,
	0x29DA: 0x29DB,
	0x29FC: 0x29FD,
	0x2E22: 0x2E23,
	0x2E24: 0x2E25,
	0x2E26: 0x2E27,
	0x2E28: 0x2E29,
	0x2E55: 0x2E56,
	0x2E57: 0x2E58,
	0x2E59: 0x2E5A,
	0x2E5B: 0x2E5C,
	0xFE59: 0xFE5A,
	0xFE5B: 0xFE5C,
	0xFE5D: 0xFE5E,
	0xFF08: 0xFF09,
	0xFF3B: 0xFF3D,
	0xFF5B: 0xFF5D,
	0xFF5F: 0xFF60,
	0xFF62: 0xFF63,
}
var bidiPairClose = map[rune]rune{
	0x0029: 0x0028,
	0x005D: 0x005B,
	0x007D: 0x007B,
	0x2046: 0x2045,
	0x207E: 0x207D,
	0x208E: 0x208D,
	0x2309: 0x2308,
	0x230B: 0x230A,
	0x232A: 0x2329,
	0x2769: 0x2768,
	0x276B: 0x276A,
	0x276D: 0x276C,
	0x276F: 0x276E,
	0x2771: 0x2770,
	0x2773: 0x2772,
	0x2775: 0x2774,
	0x27C6: 0x27C5,
	0x27E7: 0x27E6,
	0x27E9: 0x27E8,
	0x27EB: 0x27EA,
	0x27ED: 0x27EC,
	0x27EF: 0x27EE,
	0x2984: 0x2983,
	0x2986: 0x2985,
	0x2988: 0x2987,
	0x298A: 0x2989,
	0x298C: 0x298B,
	0x298E: 0x298F,
	0x2990: 0x298D,
	0x2992: 0x2991,
	0x2994: 0x2993,
	0x2996: 0x2995,
	0x2998: 0x2997,
	0x29D9: 0x29D8,
	0x29DB: 0x29DA,
	0x29FD: 0x29FC,
	0x2E23: 0x2E22,
	0x2E25: 0x2E24,
	0x2E27: 0x2E26,
	0x2E29: 0x2E28,
	0x2E56: 0x2E55,
	0x2E58: 0x2E57,
	0x2E5A: 0x2E59,
	0x2E5C: 0x2E5B,
	0xFE5A: 0xFE59,
	0xFE5C: 0xFE5B,
	0xFE5E: 0xFE5D,
	0xFF09: 0xFF08,
	0xFF3D: 0xFF3B,
	0xFF5D: 0xFF5B,
	0xFF60: 0xFF5F,
	0xFF63: 0xFF62,
}
