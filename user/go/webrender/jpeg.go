package webrender

import (
	"math"

	"virelai/webstyle"
)

// In-guest baseline JPEG (M136b): SOF0 sequential DCT, 8-bit precision,
// Huffman entropy coding, a full-precision separable IDCT, YCbCr
// 4:4:4/4:2:2/4:2:0 plus grayscale, bounded by the same pixel and byte
// budgets as the PNG decoder.
// Progressive, arithmetic-coded, 12-bit and CMYK files refuse by name
// (jpegUnsupported, which matches ErrImageUnsupported); there is no resync —
// corrupt input refuses as image-invalid: jpeg instead of being recovered.
// The host and guest use this same decoder; image/jpeg is only a host test
// reference.

const (
	errJPEGInvalid = imageError("image-invalid: jpeg")
	errJPEGLimit   = imageError("image-limit: jpeg")
)

// jpegUnsupported is a named refusal for a JPEG variant this decoder does not
// handle: "image-jpeg-unsupported-<kind>". It still IS an ErrImageUnsupported,
// so a viewer reports the format as unsupported rather than as corrupt bytes.
type jpegUnsupported string

func (e jpegUnsupported) Error() string { return "image-jpeg-unsupported-" + string(e) }

// Is reports the refusal as ErrImageUnsupported for errors.Is.
func (e jpegUnsupported) Is(t error) bool { return t == ErrImageUnsupported }

// JPEG markers (T.81 table B.1).
const (
	jmTEM   = 0x01
	jmSOF0  = 0xc0
	jmSOF2  = 0xc2
	jmDHT   = 0xc4
	jmDAC   = 0xcc
	jmRST0  = 0xd0
	jmRST7  = 0xd7
	jmSOI   = 0xd8
	jmEOI   = 0xd9
	jmSOS   = 0xda
	jmDQT   = 0xdb
	jmDNL   = 0xdc
	jmDRI   = 0xdd
	jmAPP0  = 0xe0
	jmAPP14 = 0xee
	jmAPP15 = 0xef
	jmCOM   = 0xfe
)

// jpegZigZag maps a coefficient's zig-zag index to its natural row-major
// index inside the 8x8 block.
var jpegZigZag = [64]int{
	0, 1, 8, 16, 9, 2, 3, 10,
	17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34,
	27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36,
	29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63,
}

// jpegFix rounds a trigonometric constant to b fractional bits, in the same
// 60-bit fixed-point shape the reference IDCT's constants are documented at:
// round(c * 2^b) for c in {cos,sin}(k*pi/16), sqrt(2) and 1/sqrt(2).
// An integer IDCT that rounds where the reference rounds keeps decoded
// samples bit-identical — the ±2 budget then never rides on rounding edges.
func jpegFix(x float64, b int) int32 {
	return int32(math.Floor(x*math.Exp2(float64(b)) + 0.5))
}

var (
	jpegCos1         = float64(1130768441178740757) / (1 << 60) // cos 1*pi/16
	jpegSin1         = float64(224923827593068887) / (1 << 60)  // sin 1*pi/16
	jpegCos3         = float64(958619196450722178) / (1 << 60)  // cos 3*pi/16
	jpegSin3         = float64(640528868967736374) / (1 << 60)  // sin 3*pi/16
	jpegSqrt2        = float64(1630477228166597777) / (1 << 60) // sqrt(2)
	jpegSqrt2Cos6    = float64(623956622067911264) / (1 << 60)  // sqrt(2)*cos(6*pi/16)
	jpegSqrt2Sin6    = float64(1506364539328854985) / (1 << 60) // sqrt(2)*sin(6*pi/16)
	jpegSqrt2Inv     = float64(815238614083298888) / (1 << 60)  // 1/sqrt(2)
	jpegSqrt2InvCos6 = float64(311978311033955632) / (1 << 60)  // (1/sqrt(2))*cos(6*pi/16)
	jpegSqrt2InvSin6 = float64(753182269664427492) / (1 << 60)  // (1/sqrt(2))*sin(6*pi/16)
)

// jpegBox is the 3-multiply 3-add rotation+scale of the LLM butterfly:
// (x0, x1) rotated by theta with k*cos, k*sin pre-scaled.
func jpegBox(x0, x1, kcos, ksin int32) (int32, int32) {
	ksum := kcos * (x0 + x1)
	return ksum + (ksin-kcos)*x1, ksum - (kcos+ksin)*x0
}

// jpegIDCTRows applies the 1-D inverse DCT to the rows of b (Loeffler,
// Ligtenberg and Moshovitz's 11-multiply factorisation run backward).
// Inputs are dequantized coefficients; outputs carry 20 fractional bits.
func jpegIDCTRows(b *[64]int32) {
	for i := 0; i < 8; i++ {
		x := b[8*i:]
		x0, x7, x2, x5 := x[0], x[1], x[2], x[3]
		x1, x6, x3, x4 := x[4], x[5], x[6], x[7]

		x0 <<= 17
		x1 <<= 17
		x0, x1 = x0+x1, x0-x1
		x2, x3 = jpegBox(x2, x3, jpegFix(jpegSqrt2InvCos6, 18), -jpegFix(jpegSqrt2InvSin6, 18))
		x1, x2 = x1+x2, x1-x2
		x0, x3 = x0+x3, x0-x3

		x4 <<= 7
		x7 <<= 7
		x7, x4 = x7+x4, x7-x4
		x6 = x6 * jpegFix(jpegSqrt2Inv, 8)
		x5 = x5 * jpegFix(jpegSqrt2Inv, 8)
		x7, x5 = x7+x5, x7-x5
		x4, x6 = x4+x6, x4-x6
		x4, x7 = jpegBox(x4>>2, x7>>2, jpegFix(jpegCos3, 12), -jpegFix(jpegSin3, 12))
		x5, x6 = jpegBox(x5>>2, x6>>2, jpegFix(jpegCos1, 12), -jpegFix(jpegSin1, 12))

		x0, x7 = x0+x7, x0-x7
		x1, x6 = x1+x6, x1-x6
		x2, x5 = x2+x5, x2-x5
		x3, x4 = x3+x4, x3-x4

		x[0], x[1], x[2], x[3] = x0, x1, x2, x3
		x[4], x[5], x[6], x[7] = x4, x5, x6, x7
	}
}

// jpegIDCTCols applies the 1-D inverse DCT to the columns of b, folding the
// +128 level shift into the DC path and rounding the fraction bits away.
// Outputs are the final signed samples.
func jpegIDCTCols(b *[64]int32) {
	for i := 0; i < 8; i++ {
		x0 := b[0*8+i]
		x7 := b[1*8+i]
		x2 := b[2*8+i]
		x5 := b[3*8+i]
		x1 := b[4*8+i]
		x6 := b[5*8+i]
		x3 := b[6*8+i]
		x4 := b[7*8+i]

		x0 += 1 << 19 // +0.5 in the incoming precision: the final shift rounds

		x0, x1 = (x0+x1)>>2, (x0-x1)>>2
		x2, x3 = jpegBox(x2>>13, x3>>13, jpegFix(jpegSqrt2InvCos6, 12), -jpegFix(jpegSqrt2InvSin6, 12))
		x1, x2 = x1+x2, x1-x2
		x0, x3 = x0+x3, x0-x3

		x7, x4 = x7+x4, x7-x4
		x5 = (x5 >> 13) * jpegFix(jpegSqrt2Inv, 14)
		x6 = (x6 >> 13) * jpegFix(jpegSqrt2Inv, 14)
		x7, x5 = x7+x5, x7-x5
		x4, x6 = x4+x6, x4-x6
		x4, x7 = jpegBox(x4>>14, x7>>14, jpegFix(jpegCos3, 12), -jpegFix(jpegSin3, 12))
		x5, x6 = jpegBox(x5>>14, x6>>14, jpegFix(jpegCos1, 12), -jpegFix(jpegSin1, 12))

		x0, x7 = x0+x7, x0-x7
		x1, x6 = x1+x6, x1-x6
		x2, x5 = x2+x5, x2-x5
		x3, x4 = x3+x4, x3-x4

		b[0*8+i] = x0 >> 18
		b[1*8+i] = x1 >> 18
		b[2*8+i] = x2 >> 18
		b[3*8+i] = x3 >> 18
		b[4*8+i] = x4 >> 18
		b[5*8+i] = x5 >> 18
		b[6*8+i] = x6 >> 18
		b[7*8+i] = x7 >> 18
	}
}

// jpegHuff is one canonical Huffman table (T.81 section C): the codes sorted
// by (length, symbol order), decoded one bit at a time. minc/maxc/valptr are
// the DECODE procedure's per-length bounds.
type jpegHuff struct {
	vals   [256]byte
	minc   [16]int32
	maxc   [16]int32
	valptr [16]int
	ready  bool
}

// build derives the decode bounds from the 16 code-length counts and the
// symbol list, refusing tables that overflow the code space.
func (h *jpegHuff) build(counts *[16]int, vals []byte) error {
	code, k := int32(0), 0
	for l := 0; l < 16; l++ {
		h.maxc[l] = -1
		if counts[l] != 0 {
			h.minc[l], h.valptr[l] = code, k
			k += counts[l]
			code += int32(counts[l])
			if code > 1<<uint(l+1) {
				return errJPEGInvalid // a code length ran out of space
			}
			h.maxc[l] = code - 1
		}
		code <<= 1 // canonical: descend one code level even when it is empty
	}
	if k != len(vals) {
		return errJPEGInvalid
	}
	copy(h.vals[:], vals)
	h.ready = true
	return nil
}

type jpegComp struct {
	id      uint8
	h, v    int // sampling factors
	tq      int // quantization table selector
	dc      int32
	plane   []byte // decoded samples, 8-aligned block grid
	pw      int    // plane stride in samples
	decoded bool
}

type jpegDec struct {
	data []byte
	pos  int

	w, h   int
	ncomp  int
	comp   [4]jpegComp
	maxHV  [2]int // maxH, maxV
	ri     int    // restart interval in MCUs
	sawSOF bool
	sawSOS bool

	jfif    bool
	adobe   bool
	adobeTr byte

	quant [4][64]int32 // zig-zag order
	haveQ [4]bool
	huff  [2][4]jpegHuff

	// Entropy bit reader over the raw byte stream: unread bits are the low
	// nacc bits of acc, MSB first. atMarker latches when a marker boundary
	// (not a 0xFF00 stuffed byte) was met instead of entropy data.
	acc      uint32
	nacc     int
	atMarker bool
}

// decodeJPEG decodes a baseline JPEG from data, honouring the shared image
// caps. It returns the Image or a named refusal; it never returns a partial
// image.
func decodeJPEG(data []byte) (*Image, error) {
	if len(data) > webstyle.MaxImageBytes {
		return nil, errJPEGLimit
	}
	d := &jpegDec{data: data}
	if err := d.run(); err != nil {
		return nil, err
	}
	return d.render()
}

func (d *jpegDec) run() error {
	if len(d.data) < 4 || d.data[0] != 0xff || d.data[1] != jmSOI {
		return errJPEGInvalid
	}
	d.pos = 2
	for {
		m, err := d.nextMarker()
		if err != nil {
			return err
		}
		switch {
		case m == jmEOI:
			if !d.sawSOS {
				return errJPEGInvalid
			}
			for i := 0; i < d.ncomp; i++ {
				if !d.comp[i].decoded {
					return errJPEGInvalid // a component was never scanned
				}
			}
			return nil
		case m == jmTEM || m >= jmRST0 && m <= jmRST7:
			continue // standalone markers carry no length
		}
		seg, err := d.segment()
		if err != nil {
			return err
		}
		switch m {
		case jmDQT:
			err = d.dqt(seg)
		case jmDHT:
			err = d.dht(seg)
		case jmDRI:
			err = d.dri(seg)
		case jmSOF0:
			err = d.sof(seg)
		case jmSOF2:
			err = jpegUnsupported("progressive")
		case 0xc1:
			err = jpegUnsupported("extended")
		case 0xc3:
			err = jpegUnsupported("lossless")
		case 0xc5, 0xc6, 0xc7:
			err = jpegUnsupported("hierarchical")
		case jmDAC, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf:
			err = jpegUnsupported("arithmetic")
		case jmSOS:
			err = d.sos(seg)
		case jmDNL:
			err = jpegUnsupported("dnl")
		case jmAPP0:
			d.app0(seg)
		case jmAPP14:
			d.app14(seg)
		default:
			switch {
			case m >= jmAPP0 && m <= jmAPP15 || m == jmCOM:
				// skippable application/comment segment
			case m < 0xc0:
				err = errJPEGInvalid
			default:
				err = jpegUnsupported("marker")
			}
		}
		if err != nil {
			return err
		}
	}
}

// nextMarker finds the next marker past d.pos. Extraneous non-0xFF bytes are
// skipped the way libjpeg's next_marker tolerates them; a run of 0xFF fill
// bytes collapses to one marker prefix.
func (d *jpegDec) nextMarker() (byte, error) {
	for {
		for d.pos < len(d.data) && d.data[d.pos] != 0xff {
			d.pos++
		}
		for d.pos < len(d.data) && d.data[d.pos] == 0xff {
			d.pos++
		}
		if d.pos >= len(d.data) {
			return 0, errJPEGInvalid
		}
		m := d.data[d.pos]
		d.pos++
		if m != 0x00 {
			return m, nil // 0xFF00 was a stuffed byte, not a marker
		}
	}
}

// segment reads the 16-bit length of the segment that followed a marker and
// returns its body.
func (d *jpegDec) segment() ([]byte, error) {
	if len(d.data)-d.pos < 2 {
		return nil, errJPEGInvalid
	}
	n := int(d.data[d.pos])<<8 | int(d.data[d.pos+1])
	d.pos += 2
	if n < 2 || n-2 > len(d.data)-d.pos {
		return nil, errJPEGInvalid
	}
	body := d.data[d.pos : d.pos+n-2]
	d.pos += n - 2
	return body, nil
}

func (d *jpegDec) app0(seg []byte) {
	if len(seg) >= 5 {
		d.jfif = string(seg[:5]) == "JFIF\x00"
	}
}

func (d *jpegDec) app14(seg []byte) {
	if len(seg) >= 12 && string(seg[:5]) == "Adobe" {
		d.adobe = true
		d.adobeTr = seg[11]
	}
}

func (d *jpegDec) dqt(seg []byte) error {
	for len(seg) > 0 {
		pq, tq := int(seg[0]>>4), int(seg[0]&0x0f)
		seg = seg[1:]
		if tq > 3 {
			return errJPEGInvalid
		}
		n := 64 << uint(pq)
		if pq > 1 || len(seg) < n {
			return errJPEGInvalid
		}
		for i := 0; i < 64; i++ {
			if pq == 0 {
				d.quant[tq][i] = int32(seg[i])
			} else {
				d.quant[tq][i] = int32(seg[2*i])<<8 | int32(seg[2*i+1])
			}
		}
		d.haveQ[tq] = true
		seg = seg[n:]
	}
	return nil
}

func (d *jpegDec) dht(seg []byte) error {
	for len(seg) > 0 {
		if len(seg) < 17 {
			return errJPEGInvalid
		}
		tc, th := int(seg[0]>>4), int(seg[0]&0x0f)
		if tc > 1 || th > 3 {
			return errJPEGInvalid
		}
		var counts [16]int
		total := 0
		for i := 0; i < 16; i++ {
			counts[i] = int(seg[1+i])
			total += counts[i]
		}
		seg = seg[17:]
		if total > 256 || len(seg) < total {
			return errJPEGInvalid
		}
		if err := d.huff[tc][th].build(&counts, seg[:total]); err != nil {
			return err
		}
		seg = seg[total:]
	}
	return nil
}

func (d *jpegDec) dri(seg []byte) error {
	if len(seg) != 2 {
		return errJPEGInvalid
	}
	d.ri = int(seg[0])<<8 | int(seg[1])
	return nil
}

// sof parses the baseline frame header: dimensions, component count and the
// per-component sampling factors, and enforces the shared image caps before
// anything is allocated.
func (d *jpegDec) sof(seg []byte) error {
	if d.sawSOF {
		return errJPEGInvalid
	}
	d.sawSOF = true
	if len(seg) < 6 {
		return errJPEGInvalid
	}
	switch seg[0] {
	case 8:
	case 12:
		return jpegUnsupported("12bit")
	default:
		return jpegUnsupported("precision")
	}
	height := int(seg[1])<<8 | int(seg[2])
	width := int(seg[3])<<8 | int(seg[4])
	if width == 0 || height == 0 {
		return errJPEGInvalid
	}
	if width > webstyle.MaxImageDimension || height > webstyle.MaxImageDimension ||
		width*height > webstyle.MaxImagePixels || width*height*4 > webstyle.MaxDecodedImageBytes {
		return errJPEGLimit
	}
	nf := int(seg[5])
	switch nf {
	case 1, 3:
	case 4:
		return jpegUnsupported("cmyk")
	default:
		return jpegUnsupported("components")
	}
	if len(seg) != 6+3*nf {
		return errJPEGInvalid
	}
	d.w, d.h, d.ncomp = width, height, nf
	maxH, maxV := 1, 1
	for i := 0; i < nf; i++ {
		c := &d.comp[i]
		c.id = seg[6+3*i]
		for j := 0; j < i; j++ {
			if d.comp[j].id == c.id {
				return errJPEGInvalid
			}
		}
		c.h, c.v = int(seg[7+3*i]>>4), int(seg[7+3*i]&0x0f)
		c.tq = int(seg[8+3*i])
		if c.tq > 3 {
			return errJPEGInvalid
		}
		if nf == 1 {
			// A single-component frame is non-interleaved by definition;
			// the declared factors do not change the block grid (A.2).
			c.h, c.v = 1, 1
		}
		if c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4 {
			return errJPEGInvalid
		}
		if c.h == 3 || c.v == 3 {
			return jpegUnsupported("subsampling")
		}
		if c.h > maxH {
			maxH = c.h
		}
		if c.v > maxV {
			maxV = c.v
		}
	}
	d.maxHV = [2]int{maxH, maxV}
	for i := 0; i < nf; i++ {
		if maxH%d.comp[i].h != 0 || maxV%d.comp[i].v != 0 {
			return jpegUnsupported("subsampling")
		}
	}
	return nil
}

// sos parses a scan header then decodes the entropy-coded data that follows
// it in the raw stream.
func (d *jpegDec) sos(seg []byte) error {
	if !d.sawSOF {
		return errJPEGInvalid
	}
	if len(seg) < 1 {
		return errJPEGInvalid
	}
	ns := int(seg[0])
	if len(seg) != 1+2*ns+3 || ns < 1 || ns > 4 {
		return errJPEGInvalid
	}
	var idx [4]int
	var td, ta [4]int
	for i := 0; i < ns; i++ {
		cs := seg[1+2*i]
		idx[i] = -1
		for j := 0; j < d.ncomp; j++ {
			if d.comp[j].id == cs {
				idx[i] = j
			}
		}
		if idx[i] < 0 {
			return errJPEGInvalid
		}
		for j := 0; j < i; j++ {
			if idx[j] == idx[i] {
				return errJPEGInvalid
			}
		}
		td[i], ta[i] = int(seg[2+2*i]>>4), int(seg[2+2*i]&0x0f)
		// Baseline table B.3: at most two tables of each class.
		if td[i] > 1 || ta[i] > 1 {
			return errJPEGInvalid
		}
		if !d.huff[0][td[i]].ready || !d.huff[1][ta[i]].ready || !d.haveQ[d.comp[idx[i]].tq] {
			return errJPEGInvalid
		}
	}
	// A sequential scan codes every coefficient in one pass.
	if seg[1+2*ns] != 0 || seg[2+2*ns] != 63 || seg[3+2*ns] != 0 {
		return jpegUnsupported("progressive")
	}
	d.sawSOS = true
	d.acc, d.nacc, d.atMarker = 0, 0, false
	for i := 0; i < d.ncomp; i++ {
		d.comp[i].dc = 0
	}
	switch {
	case ns == d.ncomp:
		return d.scanInterleaved(ns, &idx, &td, &ta)
	case ns == 1:
		return d.scanSingle(idx[0], td[0], ta[0])
	}
	return jpegUnsupported("scan")
}

// ---------------------------------------------------------------------------
// Entropy-coded data
// ---------------------------------------------------------------------------

// entropyByte pulls one byte of scan data, honouring 0xFF00 byte stuffing.
// Meeting a marker instead leaves d.pos on its 0xFF and latches atMarker.
func (d *jpegDec) entropyByte() (byte, error) {
	if d.atMarker || d.pos >= len(d.data) {
		return 0, errJPEGInvalid
	}
	c := d.data[d.pos]
	if c != 0xff {
		d.pos++
		return c, nil
	}
	if d.pos+1 < len(d.data) && d.data[d.pos+1] == 0x00 {
		d.pos += 2
		return 0xff, nil
	}
	d.atMarker = true
	return 0, errJPEGInvalid
}

// take consumes the next n bits of scan data, MSB first.
func (d *jpegDec) take(n int) (uint32, error) {
	for d.nacc < n {
		b, err := d.entropyByte()
		if err != nil {
			return 0, err
		}
		d.acc = d.acc<<8 | uint32(b)
		d.nacc += 8
	}
	d.nacc -= n
	return d.acc >> uint(d.nacc) & (1<<uint(n) - 1), nil
}

// receiveExtend is RECEIVE+EXTEND (F.2.2.1): t magnitude bits decoded to a
// signed coefficient.
func (d *jpegDec) receiveExtend(t int) (int32, error) {
	if t == 0 {
		return 0, nil
	}
	v, err := d.take(t)
	if err != nil {
		return 0, err
	}
	x := int32(v)
	if x < 1<<uint(t-1) {
		x -= 1<<uint(t) - 1
	}
	return x, nil
}

// huffDecode is the DECODE procedure of section C: walk code lengths until
// the accumulated code falls inside a length's range.
func (d *jpegDec) huffDecode(h *jpegHuff) (byte, error) {
	code := int32(0)
	for l := 0; l < 16; l++ {
		bit, err := d.take(1)
		if err != nil {
			return 0, err
		}
		code = code<<1 | int32(bit)
		if code <= h.maxc[l] {
			return h.vals[h.valptr[l]+int(code-h.minc[l])], nil
		}
	}
	return 0, errJPEGInvalid
}

// block decodes one 8x8 data unit of comp: DC difference, then the AC
// run-length stream, in zig-zag order.
func (d *jpegDec) block(comp *jpegComp, td, ta int, b *[64]int32) error {
	for i := range b {
		b[i] = 0
	}
	dcTab, acTab := &d.huff[0][td], &d.huff[1][ta]
	s, err := d.huffDecode(dcTab)
	if err != nil {
		return err
	}
	if s > 16 {
		return jpegUnsupported("dc-coefficient")
	}
	diff, err := d.receiveExtend(int(s))
	if err != nil {
		return err
	}
	comp.dc += diff
	b[0] = comp.dc
	for k := 1; k < 64; {
		rs, err := d.huffDecode(acTab)
		if err != nil {
			return err
		}
		run, size := int(rs>>4), int(rs&0x0f)
		if size == 0 {
			if run != 15 {
				break // end of block
			}
			k += 16 // ZRL: sixteen zero coefficients
			continue
		}
		k += run
		if k > 63 {
			return errJPEGInvalid
		}
		coef, err := d.receiveExtend(size)
		if err != nil {
			return err
		}
		b[jpegZigZag[k]] = coef
		k++
	}
	return nil
}

// restart consumes the expected RSTm marker at an MCU boundary: the bit
// reader aligns to a byte, the DC predictors reset, and the marker mod 8
// must be the running ordinal n (the first restart is RST0).
func (d *jpegDec) restart(n int) error {
	d.nacc, d.acc = 0, 0
	for d.pos+1 < len(d.data) && d.data[d.pos] == 0xff && d.data[d.pos+1] == 0xff {
		d.pos++ // fill bytes before the marker
	}
	if d.pos+1 >= len(d.data) || d.data[d.pos] != 0xff {
		return errJPEGInvalid
	}
	want := byte(jmRST0 + n%8)
	if d.data[d.pos+1] != want {
		return errJPEGInvalid
	}
	d.pos += 2
	for i := 0; i < d.ncomp; i++ {
		d.comp[i].dc = 0
	}
	return nil
}

// scanInterleaved decodes a scan covering every component at once, MCU by
// MCU over the frame's sampling grid.
func (d *jpegDec) scanInterleaved(ns int, idx, td, ta *[4]int) error {
	maxH, maxV := d.maxHV[0], d.maxHV[1]
	mxx := (d.w + 8*maxH - 1) / (8 * maxH)
	myy := (d.h + 8*maxV - 1) / (8 * maxV)
	for i := 0; i < ns; i++ {
		c := &d.comp[idx[i]]
		if err := d.allocPlane(c, mxx); err != nil {
			return err
		}
	}
	var b [64]int32
	total, mcu := mxx*myy, 0
	for my := 0; my < myy; my++ {
		for mx := 0; mx < mxx; mx++ {
			for i := 0; i < ns; i++ {
				c := &d.comp[idx[i]]
				for j := 0; j < c.h*c.v; j++ {
					bx := c.h*mx + j%c.h
					by := c.v*my + j/c.h
					if err := d.block(c, td[i], ta[i], &b); err != nil {
						return err
					}
					d.storeBlock(c, bx, by, &b)
				}
			}
			mcu++
			if d.ri > 0 && mcu%d.ri == 0 && mcu < total {
				if err := d.restart(mcu/d.ri - 1); err != nil {
					return err
				}
			}
		}
	}
	for i := 0; i < ns; i++ {
		d.comp[idx[i]].decoded = true
	}
	return nil
}

// scanSingle decodes a non-interleaved scan: one component, one 8x8 block
// per MCU, raster over that component's own downsampled grid (A.2.4).
func (d *jpegDec) scanSingle(ci, td, ta int) error {
	c := &d.comp[ci]
	cw := (int64(d.w)*int64(c.h) + int64(d.maxHV[0]) - 1) / int64(d.maxHV[0])
	ch := (int64(d.h)*int64(c.v) + int64(d.maxHV[1]) - 1) / int64(d.maxHV[1])
	bw := (int(cw) + 7) / 8
	bh := (int(ch) + 7) / 8
	mxx := (d.w + 8*d.maxHV[0] - 1) / (8 * d.maxHV[0])
	if err := d.allocPlane(c, mxx); err != nil {
		return err
	}
	var b [64]int32
	total, mcu := bw*bh, 0
	for by := 0; by < bh; by++ {
		for bx := 0; bx < bw; bx++ {
			if err := d.block(c, td, ta, &b); err != nil {
				return err
			}
			d.storeBlock(c, bx, by, &b)
			mcu++
			if d.ri > 0 && mcu%d.ri == 0 && mcu < total {
				if err := d.restart(mcu/d.ri - 1); err != nil {
					return err
				}
			}
		}
	}
	c.decoded = true
	return nil
}

// allocPlane gives a component its padded 8-aligned sample plane once,
// bounded by the SOF-enforced caps.
func (d *jpegDec) allocPlane(c *jpegComp, mxx int) error {
	if c.plane != nil {
		return nil
	}
	myy := (d.h + 8*d.maxHV[1] - 1) / (8 * d.maxHV[1])
	c.pw = mxx * c.h * 8
	c.plane = make([]byte, c.pw*myy*c.v*8)
	return nil
}

// storeBlock dequantizes b against the component's table, runs the integer
// IDCT, level-shifts and writes the 8x8 samples into the plane.
func (d *jpegDec) storeBlock(c *jpegComp, bx, by int, b *[64]int32) {
	q := &d.quant[c.tq]
	for z := 0; z < 64; z++ {
		b[jpegZigZag[z]] *= q[z]
	}
	jpegIDCTRows(b)
	jpegIDCTCols(b)
	dst := c.plane[(by*8)*c.pw+bx*8:]
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			s := b[y*8+x] + 128
			if s < 0 {
				s = 0
			} else if s > 255 {
				s = 255
			}
			dst[y*c.pw+x] = byte(s)
		}
	}
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// render converts the decoded planes to the surface's 0xAARRGGBB words.
// Chroma is sampled nearest-neighbour from the subsampled plane, the same
// reading image.YCbCr gives its RGBA.
func (d *jpegDec) render() (*Image, error) {
	out := &Image{Width: d.w, Height: d.h, Pix: make([]uint32, d.w*d.h)}
	y := &d.comp[0]
	if d.ncomp == 1 {
		for p := 0; p < d.h; p++ {
			for x := 0; x < d.w; x++ {
				g := uint32(y.plane[p*y.pw+x])
				out.Pix[p*d.w+x] = 0xff000000 | g<<16 | g<<8 | g
			}
		}
		return out, nil
	}
	cb, cr := &d.comp[1], &d.comp[2]
	rgb := d.isRGB()
	for p := 0; p < d.h; p++ {
		for x := 0; x < d.w; x++ {
			c0 := uint32(y.plane[p*y.pw+x])
			c1 := uint32(cb.plane[(p*cb.v/d.maxHV[1])*cb.pw+x*cb.h/d.maxHV[0]])
			c2 := uint32(cr.plane[(p*cr.v/d.maxHV[1])*cr.pw+x*cr.h/d.maxHV[0]])
			var r, g, b uint32
			if rgb {
				r, g, b = c0, c1, c2
			} else {
				r, g, b = jpegYCbCr(c0, c1, c2)
			}
			out.Pix[p*d.w+x] = 0xff000000 | r<<16 | g<<8 | b
		}
	}
	return out, nil
}

// isRGB reports a three-component frame whose channels are already R,G,B:
// an Adobe transform of 0, or the literal component identifiers — never a
// JFIF frame, which is YCbCr by definition.
func (d *jpegDec) isRGB() bool {
	if d.jfif {
		return false
	}
	if d.adobe && d.adobeTr == 0 {
		return true
	}
	return d.comp[0].id == 'R' && d.comp[1].id == 'G' && d.comp[2].id == 'B'
}

// jpegYCbCr is the JFIF YCbCr to RGB conversion in the same fixed-point
// shape the host's color.YCbCr.RGBA uses: 16-bit intermediates, floor on
// the top byte, so decoded channels track the host reference to ±1.
func jpegYCbCr(y, cb, cr uint32) (r, g, b uint32) {
	yy := int32(y) * 0x10101
	cb1 := int32(cb) - 128
	cr1 := int32(cr) - 128
	return clamp16(yy + 91881*cr1), clamp16(yy - 22554*cb1 - 46802*cr1), clamp16(yy + 116130*cb1)
}

func clamp16(v int32) uint32 {
	if v < 0 {
		return 0
	}
	if v > 0xffffff {
		return 0xff
	}
	return uint32(v >> 16)
}
