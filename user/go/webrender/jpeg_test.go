package webrender

import (
	"bytes"
	"encoding/binary"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"virelai/webstyle"
)

// The corpus inputs below are original, generated from specified pixel
// vectors by the encoder in this file, not downloaded JPEGs or external
// decoder code. The Go standard library image/jpeg is the BSD-3-Clause
// host-only test reference (and encoded viewer_160x120.jpg); the fixture's
// license is recorded in testdata/jpeg/SOURCES.txt.
//
// The encoder writes REAL baseline JPEGs: SOF0, 8-bit, the Annex K
// quantization and Huffman tables, an O(n^4) float DCT (host-only, so math
// is fine), optional DRI restart markers and optional non-interleaved
// scans. That is what lets the corpus cover the 4:4:4/4:2:2/4:4:0/grayscale
// shapes image/jpeg's encoder never emits — it always writes 4:2:0 or gray.

var jpegLumaQuant = [64]int{
	16, 11, 10, 16, 24, 40, 51, 61,
	12, 12, 14, 19, 26, 58, 60, 55,
	14, 13, 16, 24, 40, 57, 69, 56,
	14, 17, 22, 29, 51, 87, 80, 62,
	18, 22, 37, 56, 68, 109, 103, 77,
	24, 35, 55, 64, 81, 104, 113, 92,
	49, 64, 78, 87, 103, 121, 120, 101,
	72, 92, 95, 98, 112, 100, 103, 99,
}

var jpegChromaQuant = [64]int{
	17, 18, 24, 47, 99, 99, 99, 99,
	18, 21, 26, 66, 99, 99, 99, 99,
	24, 26, 56, 99, 99, 99, 99, 99,
	47, 66, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99,
}

type jpegTable struct {
	bits [16]int
	vals []byte
}

// Annex K.3 Huffman tables.
var jpegDCLuma = jpegTable{
	[16]int{0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0},
	[]byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
}

var jpegDCChroma = jpegTable{
	[16]int{0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0},
	[]byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
}

var jpegACLuma = jpegTable{
	[16]int{0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d},
	[]byte{
		0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
		0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
		0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
		0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
		0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
		0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
		0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
		0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
		0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
		0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
		0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
		0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
		0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
		0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
		0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
		0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
		0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
		0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
		0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
		0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
		0xf9, 0xfa,
	},
}

var jpegACChroma = jpegTable{
	[16]int{0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77},
	[]byte{
		0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
		0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
		0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
		0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
		0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
		0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
		0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
		0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
		0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
		0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
		0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
		0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
		0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
		0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
		0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
		0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
		0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
		0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
		0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
		0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
		0xf9, 0xfa,
	},
}

// huffEnc is the encoder-side map of a table: symbol -> (code, length).
type huffEnc struct {
	code [256]uint16
	size [256]int
}

func makeHuffEnc(t jpegTable) huffEnc {
	var e huffEnc
	code, k := 0, 0
	for l := 0; l < 16; l++ {
		for i := 0; i < t.bits[l]; i++ {
			e.code[t.vals[k]] = uint16(code)
			e.size[t.vals[k]] = l + 1
			code++
			k++
		}
		code <<= 1
	}
	return e
}

// jpegBitWriter accumulates entropy bits MSB-first and stuffs 0x00 after
// every 0xFF data byte, per F.1.2.3.
type jpegBitWriter struct {
	out  []byte
	acc  uint32
	nacc int
}

func (w *jpegBitWriter) write(code uint32, n int) {
	w.acc = w.acc<<uint(n) | code&(1<<uint(n)-1)
	w.nacc += n
	for w.nacc >= 8 {
		b := byte(w.acc >> uint(w.nacc-8))
		w.out = append(w.out, b)
		if b == 0xff {
			w.out = append(w.out, 0)
		}
		w.nacc -= 8
	}
	w.acc &= 1<<uint(w.nacc) - 1
}

// pad finishes the scan with 1-bits (F.1.2.3's fill pattern).
func (w *jpegBitWriter) pad() {
	if w.nacc > 0 {
		w.write(1<<uint(8-w.nacc)-1, 8-w.nacc)
	}
}

type jpegEncComp struct {
	id   byte
	h, v int
	tq   byte
	tab  jpegTableDCT
	// samples of this component's downsampled plane, padded to the block grid
	pix    []byte
	pw, ph int
	dc     int32
	enc    huffEnc
	encAC  huffEnc
}

type jpegTableDCT struct {
	quant *[64]int
	dc    jpegTable
	ac    jpegTable
}

var (
	jpegTabLuma   = jpegTableDCT{&jpegLumaQuant, jpegDCLuma, jpegACLuma}
	jpegTabChroma = jpegTableDCT{&jpegChromaQuant, jpegDCChroma, jpegACChroma}
)

// jpegEncode writes a real baseline JPEG of a w*h image described by fn
// (pixel -> r,g,b). sampling is the luma component's (h, v) — chroma is
// always 1x1 — so 4:4:4 is {1,1}, 4:2:2 {2,1}, 4:2:0 {2,2}, 4:4:0 {1,2}.
// gray emits a single-component frame. restart emits a DRI segment and RST
// markers every N MCUs. multiScan splits the frame into one scan per
// component (still sequential — the non-interleaved path).
func jpegEncode(w, h int, fn func(x, y int) (uint8, uint8, uint8), sampling [2]int,
	gray, multiScan bool, restart int) []byte {
	var out bytes.Buffer
	emit := func(b ...byte) { out.Write(b) }
	seg := func(m byte, body []byte) {
		emit(0xff, m, byte((len(body)+2)>>8), byte(len(body)+2))
		out.Write(body)
	}
	emit(0xff, 0xd8) // SOI
	seg(0xe0, []byte("JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"))
	qt := func(tq byte, tab *[64]int) {
		body := make([]byte, 65)
		body[0] = tq
		for i := 0; i < 64; i++ {
			body[1+i] = byte(tab[jpegZigZag[i]])
		}
		seg(0xdb, body)
	}
	qt(0, &jpegLumaQuant)
	if !gray {
		qt(1, &jpegChromaQuant)
	}

	ncomp := 3
	if gray {
		ncomp = 1
	}
	maxH, maxV := sampling[0], sampling[1]
	if gray {
		maxH, maxV = 1, 1
	}
	sof := []byte{8, byte(h >> 8), byte(h), byte(w >> 8), byte(w), byte(ncomp)}
	comps := make([]jpegEncComp, ncomp)
	for i := range comps {
		c := &comps[i]
		c.id = byte(i + 1)
		c.h, c.v = 1, 1
		c.tab = jpegTabChroma
		if i == 0 {
			c.h, c.v = maxH, maxV
			c.tab = jpegTabLuma
		}
		c.tq = byte(min(i, 1))
		sof = append(sof, c.id, byte(c.h<<4|c.v), c.tq)
		c.enc = makeHuffEnc(c.tab.dc)
		c.encAC = makeHuffEnc(c.tab.ac)
	}
	seg(0xc0, sof)
	if restart > 0 {
		seg(0xdd, []byte{byte(restart >> 8), byte(restart)})
	}
	dht := func(tcth byte, tab jpegTable) {
		body := make([]byte, 17+len(tab.vals))
		body[0] = tcth
		for i := 0; i < 16; i++ {
			body[1+i] = byte(tab.bits[i])
		}
		copy(body[17:], tab.vals)
		seg(0xc4, body)
	}
	dht(0x00, jpegDCLuma)
	dht(0x10, jpegACLuma)
	if !gray {
		dht(0x01, jpegDCChroma)
		dht(0x11, jpegACChroma)
	}

	// Fill the component planes at their downsampled sizes, padded out to
	// the MCU traversal grid (which can exceed the sampled area on edges)
	// by edge replication.
	mxx0 := (w + 8*maxH - 1) / (8 * maxH)
	myy0 := (h + 8*maxV - 1) / (8 * maxV)
	for i := range comps {
		c := &comps[i]
		cw := (w*c.h + maxH - 1) / maxH
		ch := (h*c.v + maxV - 1) / maxV
		bw, bh := mxx0*c.h*8, myy0*c.v*8
		c.pw, c.ph = bw, bh
		c.pix = make([]byte, bw*bh)
		for y := 0; y < ch; y++ {
			for x := 0; x < cw; x++ {
				var acc, n int
				for dy := 0; dy < maxV/c.v; dy++ {
					for dx := 0; dx < maxH/c.h; dx++ {
						fx := min(x*maxH/c.h+dx, w-1)
						fy := min(y*maxV/c.v+dy, h-1)
						r, g, b := fn(fx, fy)
						var v int
						switch i {
						case 0:
							v = int(0.299*float64(r) + 0.587*float64(g) + 0.114*float64(b) + 0.5)
						case 1:
							v = int(128 - 0.168736*float64(r) - 0.331264*float64(g) + 0.5*float64(b) + 0.5)
						case 2:
							v = int(128 + 0.5*float64(r) - 0.418688*float64(g) - 0.081312*float64(b) + 0.5)
						}
						acc += v
						n++
					}
				}
				c.pix[y*bw+x] = byte(clampEnc(acc / n))
			}
		}
		for y := 0; y < bh; y++ {
			for x := cw; x < bw; x++ {
				c.pix[y*bw+x] = c.pix[y*bw+cw-1]
			}
		}
		for y := ch; y < bh; y++ {
			copy(c.pix[y*bw:], c.pix[(ch-1)*bw:(ch-1)*bw+bw])
		}
	}

	// scan writes one SOS + the entropy-coded MCUs for the listed comps,
	// sharing a single encoder-side DC predictor per component.
	rstN := 0
	mcu := 0
	restartMark := func(bw *jpegBitWriter) {
		if restart <= 0 || mcu == 0 || mcu%restart != 0 {
			return
		}
		bw.pad()
		out.Write(bw.out)
		bw.out = nil
		emit(0xff, byte(0xd0+rstN%8))
		rstN++
		for i := range comps {
			comps[i].dc = 0
		}
	}
	scan := func(which []int) {
		body := []byte{byte(len(which))}
		for _, i := range which {
			c := &comps[i]
			tdta := byte(0x00)
			if i > 0 {
				tdta = 0x11
			}
			body = append(body, c.id, tdta)
		}
		seg(0xda, append(body, 0, 63, 0))
		bw := jpegBitWriter{}
		if len(which) == 1 {
			// Non-interleaved scan: raster over the component's own
			// downsampled block grid (A.2.4), one block per MCU.
			c := &comps[which[0]]
			cw := (w*c.h + maxH - 1) / maxH
			ch := (h*c.v + maxV - 1) / maxV
			for by := 0; by < (ch+7)/8; by++ {
				for bx := 0; bx < (cw+7)/8; bx++ {
					restartMark(&bw)
					jpegEncodeBlock(&bw, c, bx, by)
					mcu++
				}
			}
		} else {
			mxx := (w + 8*maxH - 1) / (8 * maxH)
			myy := (h + 8*maxV - 1) / (8 * maxV)
			for my := 0; my < myy; my++ {
				for mx := 0; mx < mxx; mx++ {
					restartMark(&bw)
					for _, i := range which {
						c := &comps[i]
						for j := 0; j < c.h*c.v; j++ {
							bx, by := c.h*mx+j%c.h, c.v*my+j/c.h
							jpegEncodeBlock(&bw, c, bx, by)
						}
					}
					mcu++
				}
			}
		}
		bw.pad()
		out.Write(bw.out)
	}
	if multiScan {
		for i := 0; i < ncomp; i++ {
			scan([]int{i})
		}
	} else {
		all := make([]int, ncomp)
		for i := range all {
			all[i] = i
		}
		scan(all)
	}
	emit(0xff, 0xd9) // EOI
	return out.Bytes()
}

// jpegEncodeBlock runs the float DCT + quantization on one 8x8 unit of the
// component plane and emits its Huffman stream.
func jpegEncodeBlock(bw *jpegBitWriter, c *jpegEncComp, bx, by int) {
	var f [64]float64
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			f[y*8+x] = float64(c.pix[(by*8+y)*c.pw+bx*8+x]) - 128
		}
	}
	var coef [64]int
	for v := 0; v < 8; v++ {
		for u := 0; u < 8; u++ {
			var acc float64
			for y := 0; y < 8; y++ {
				for x := 0; x < 8; x++ {
					acc += f[y*8+x] * math.Cos(float64(2*x+1)*float64(u)*math.Pi/16) *
						math.Cos(float64(2*y+1)*float64(v)*math.Pi/16)
				}
			}
			cu, cv := 1.0, 1.0
			if u == 0 {
				cu = math.Sqrt(0.5)
			}
			if v == 0 {
				cv = math.Sqrt(0.5)
			}
			coef[jpegZigZag[v*8+u]] = int(math.Round(0.25 * cu * cv * acc / float64(c.tab.quant[v*8+u])))
		}
	}
	// DC difference.
	diff := int32(coef[0]) - c.dc
	c.dc = int32(coef[0])
	size := jpegBitLen(diff)
	bw.write(uint32(c.enc.code[size]), c.enc.size[size])
	if size > 0 {
		bw.write(uint32(jpegExtendBits(diff, size)), size)
	}
	// AC run/size.
	run := 0
	for k := 1; k < 64; k++ {
		coefK := int32(coef[k])
		if coefK == 0 {
			run++
			continue
		}
		for run >= 16 {
			bw.write(uint32(c.encAC.code[0xf0]), c.encAC.size[0xf0])
			run -= 16
		}
		s := jpegBitLen(coefK)
		sym := byte(run<<4 | s)
		bw.write(uint32(c.encAC.code[sym]), c.encAC.size[sym])
		bw.write(uint32(jpegExtendBits(coefK, s)), s)
		run = 0
	}
	if run > 0 {
		bw.write(uint32(c.encAC.code[0x00]), c.encAC.size[0x00])
	}
}

func jpegBitLen(v int32) int {
	if v < 0 {
		v = -v
	}
	n := 0
	for v != 0 {
		n++
		v >>= 1
	}
	return n
}

func jpegExtendBits(v int32, n int) int32 {
	if v >= 0 {
		return v
	}
	return v + (1 << uint(n)) - 1
}

func clampEnc(v int) int {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return v
}

// jpegPattern is the deterministic pixel source every vector shares: four
// saturated quadrants (to stress chroma subsampling) over a gradient, with
// a high-frequency checker patch in the middle for AC energy.
func jpegPattern(w, h int) func(x, y int) (uint8, uint8, uint8) {
	return func(x, y int) (uint8, uint8, uint8) {
		if x >= w*3/8 && x < w*5/8 && y >= h*3/8 && y < h*5/8 {
			v := uint8(255 * ((x + y) % 2))
			return v, 255 - v, 128
		}
		switch (x*2/w)*2 + y*2/h {
		case 0:
			return 0xd8, 0x20, 0x18
		case 1:
			return 0xd8, 0x20, 0x18
		case 2:
			return 0x20, 0xc0, 0x30
		default:
			return 0x20, 0x40, 0xd0
		}
	}
}

func jpegGradient(w, h int) func(x, y int) (uint8, uint8, uint8) {
	return func(x, y int) (uint8, uint8, uint8) {
		return uint8(x * 255 / w), uint8(y * 255 / h), uint8((x + y) * 255 / (w + h))
	}
}

// jpegVectors are the shapes the card requires plus the edges a bounded
// decoder must meet: every supported sampling, a restart stream, a
// multi-scan (non-interleaved) sequential file, and odd dimensions that
// force partial edge blocks.
type jpegVector struct {
	name     string
	w, h     int
	fn       func(x, y int) (uint8, uint8, uint8)
	sampling [2]int
	gray     bool
	multi    bool
	restart  int
	stdlib   bool // encode with the host image/jpeg reference instead
}

var jpegVectors = []jpegVector{
	{"pattern-444", 64, 48, jpegPattern(64, 48), [2]int{1, 1}, false, false, 0, false},
	{"pattern-422", 64, 48, jpegPattern(64, 48), [2]int{2, 1}, false, false, 0, false},
	{"pattern-420", 64, 48, jpegPattern(64, 48), [2]int{2, 2}, false, false, 0, false},
	{"pattern-440", 64, 48, jpegPattern(64, 48), [2]int{1, 2}, false, false, 0, false},
	{"gradient-411", 64, 48, jpegGradient(64, 48), [2]int{4, 1}, false, false, 0, false},
	{"gray-32", 32, 32, nil, [2]int{1, 1}, true, false, 0, false},
	{"odd-420", 37, 29, jpegPattern(37, 29), [2]int{2, 2}, false, false, 0, false},
	{"restart-420", 64, 48, jpegPattern(64, 48), [2]int{2, 2}, false, false, 3, false},
	{"scans-420", 64, 48, jpegPattern(64, 48), [2]int{2, 2}, false, true, 0, false},
	{"viewer_160x120", 160, 120, jpegPattern(160, 120), [2]int{2, 2}, false, false, 0, true},
}

// jpegVectorBytes produces a vector's bytes. viewer_160x120 goes through the
// host stdlib encoder (jpeg.Encode, BSD-3-Clause) so the GOVIEW fixture is a
// real-encoder JPEG, not only the corpus generator's output.
func jpegVectorBytes(v jpegVector) []byte {
	fn := v.fn
	if v.gray {
		fn = func(x, y int) (uint8, uint8, uint8) {
			g := uint8((x*4 + y*7) % 256)
			return g, g, g
		}
	}
	if v.stdlib {
		im := image.NewNRGBA(image.Rect(0, 0, v.w, v.h))
		for y := 0; y < v.h; y++ {
			for x := 0; x < v.w; x++ {
				r, g, b := fn(x, y)
				im.Pix[(y*v.w+x)*4], im.Pix[(y*v.w+x)*4+1], im.Pix[(y*v.w+x)*4+2], im.Pix[(y*v.w+x)*4+3] = r, g, b, 255
			}
		}
		var out bytes.Buffer
		if err := jpeg.Encode(&out, im, &jpeg.Options{Quality: 85}); err != nil {
			panic(err)
		}
		return out.Bytes()
	}
	return jpegEncode(v.w, v.h, fn, v.sampling, v.gray, v.multi, v.restart)
}

// checkJPEGParity decodes data with the in-tree decoder and with host
// image/jpeg and requires every channel of every pixel within ±2.
func checkJPEGParity(t testing.TB, data []byte) {
	t.Helper()
	got, err := decodeJPEG(data)
	if err != nil {
		t.Fatalf("decodeJPEG: %v", err)
	}
	want, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("host image/jpeg refused a corpus file: %v", err)
	}
	b := want.Bounds()
	if got.Width != b.Dx() || got.Height != b.Dy() {
		t.Fatalf("dimensions=%dx%d, stdlib=%v", got.Width, got.Height, b)
	}
	var worst int
	for y := 0; y < got.Height; y++ {
		for x := 0; x < got.Width; x++ {
			c := color.NRGBAModel.Convert(want.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA)
			p := got.At(x, y)
			for i, wv := range []uint32{uint32(c.R), uint32(c.G), uint32(c.B)} {
				gv := (p >> uint(16-8*i)) & 0xff
				d := int(gv) - int(wv)
				if d < 0 {
					d = -d
				}
				if d > worst {
					worst = d
				}
				if d > 2 {
					t.Fatalf("pixel (%d,%d) channel %d: got %d want %d (±2)", x, y, i, gv, wv)
				}
			}
			if p>>24 != 0xff {
				t.Fatalf("pixel (%d,%d) not opaque: %#08x", x, y, p)
			}
		}
	}
	t.Logf("parity within ±%d of host image/jpeg on %dx%d", worst, got.Width, got.Height)
}

func TestJPEGParityVectors(t *testing.T) {
	for _, v := range jpegVectors {
		t.Run(v.name, func(t *testing.T) {
			data := jpegVectorBytes(v)
			// The corpus encoder must emit files the host reference accepts.
			if _, err := jpeg.DecodeConfig(bytes.NewReader(data)); err != nil {
				t.Fatalf("generated vector is not a decodable JPEG: %v", err)
			}
			checkJPEGParity(t, data)
		})
	}
}

func TestJPEGCommittedCorpus(t *testing.T) {
	n := 0
	for _, v := range jpegVectors {
		path := filepath.Join("testdata", "jpeg", v.name+".jpg")
		data := jpegVectorBytes(v)
		if os.Getenv("WEBRENDER_CREATE_JPEG_CORPUS") == "1" {
			if _, err := os.Stat(path); os.IsNotExist(err) {
				if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, data, 0o644); err != nil {
					t.Fatal(err)
				}
			}
		}
		pinned, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("committed corpus fixture missing: %s (run with WEBRENDER_CREATE_JPEG_CORPUS=1)", path)
		}
		if !bytes.Equal(pinned, data) {
			t.Fatalf("owned corpus vector drift: %s", path)
		}
		checkJPEGParity(t, pinned)
		n++
	}
	if n == 0 {
		t.Fatal("JPEG corpus is missing")
	}
}

// jpegMarkerOffset finds the position of marker m's code byte (the byte
// after its 0xFF prefix) while walking segments from the SOI.
func jpegMarkerOffset(t testing.TB, data []byte, want byte) int {
	t.Helper()
	if len(data) < 4 || data[0] != 0xff || data[1] != 0xd8 {
		t.Fatal("corpus file lost its SOI")
	}
	pos := 2
	for pos+1 < len(data) {
		if data[pos] != 0xff {
			t.Fatalf("corpus marker walk hit stray byte at %d", pos)
		}
		m := data[pos+1]
		if m == want {
			return pos + 1
		}
		if m == 0xda {
			t.Fatal("marker walk ran into entropy data")
		}
		n := int(data[pos+2])<<8 | int(data[pos+3])
		pos += 2 + n
	}
	t.Fatalf("marker %#x not found", want)
	return -1
}

func TestJPEGUnsupportedByName(t *testing.T) {
	base := jpegVectorBytes(jpegVectors[2]) // pattern-420
	sof := jpegMarkerOffset(t, base, 0xc0)
	// SOF body at sof+3: prec(1) h(2) w(2) nf(1) then per-component (id,hv,tq).
	mutate := func(fn func([]byte)) []byte {
		data := append([]byte(nil), base...)
		fn(data)
		return data
	}
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{"progressive", mutate(func(d []byte) { d[sof] = 0xc2 }), "image-jpeg-unsupported-progressive"},
		{"extended", mutate(func(d []byte) { d[sof] = 0xc1 }), "image-jpeg-unsupported-extended"},
		{"lossless", mutate(func(d []byte) { d[sof] = 0xc3 }), "image-jpeg-unsupported-lossless"},
		{"hierarchical", mutate(func(d []byte) { d[sof] = 0xc5 }), "image-jpeg-unsupported-hierarchical"},
		{"arithmetic-sof", mutate(func(d []byte) { d[sof] = 0xc9 }), "image-jpeg-unsupported-arithmetic"},
		{"arithmetic-dac", mutate(func(d []byte) { d[sof] = 0xcc }), "image-jpeg-unsupported-arithmetic"},
		{"12bit", mutate(func(d []byte) { d[sof+3] = 12 }), "image-jpeg-unsupported-12bit"},
		{"precision", mutate(func(d []byte) { d[sof+3] = 4 }), "image-jpeg-unsupported-precision"},
		{"cmyk", mutate(func(d []byte) { d[sof+8] = 4 }), "image-jpeg-unsupported-cmyk"},
		{"components", mutate(func(d []byte) { d[sof+8] = 2 }), "image-jpeg-unsupported-components"},
		{"subsampling", mutate(func(d []byte) { d[sof+10] = 0x31 }), "image-jpeg-unsupported-subsampling"},
		{"marker", mutate(func(d []byte) { d[sof] = 0xcf }), "image-jpeg-unsupported-arithmetic"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			im, err := decodeJPEG(tc.data)
			if err == nil || err.Error() != tc.want || im != nil {
				t.Fatalf("refusal=%v image=%v, want %s", err, im, tc.want)
			}
			if !errors.Is(err, ErrImageUnsupported) {
				t.Fatalf("%v must match ErrImageUnsupported", err)
			}
		})
	}
}

func TestJPEGMalformedByName(t *testing.T) {
	base := jpegVectorBytes(jpegVectors[2])
	sof := jpegMarkerOffset(t, base, 0xc0)
	for i := 0; i < len(base); i++ {
		if im, err := decodeJPEG(base[:i]); err == nil || im != nil {
			t.Fatalf("truncation at %d decoded %v", i, im)
		}
	}
	cases := map[string][]byte{
		"not-jpeg":   []byte("this is not a jpeg at all, it just is not"),
		"soi-only":   {0xff, 0xd8},
		"bad-magic":  {0xff, 0xd9, 0xff, 0xd8},
		"huge-dims":  mutateJPEG(base, sof+4, func(d []byte, i int) { d[i], d[i+1] = 0xff, 0xff }),
		"no-eoi":     base[:len(base)-2],
		"bad-marker": mutateJPEG(base, sof, func(d []byte, i int) { d[i] = 0x02 }),
		"bad-scan":   mutateJPEG(base, sof, func(d []byte, i int) { d[i] = 0xc8 }),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			im, err := decodeJPEG(data)
			if err == nil || im != nil {
				t.Fatal("malformed input accepted")
			}
			if name == "huge-dims" {
				if err != errJPEGLimit {
					t.Fatalf("oversized dims: %v, want image-limit", err)
				}
				return
			}
			if !strings.HasPrefix(err.Error(), "image-") {
				t.Fatalf("unnamed refusal: %v", err)
			}
		})
	}
}

func mutateJPEG(data []byte, off int, fn func([]byte, int)) []byte {
	out := append([]byte(nil), data...)
	fn(out, off)
	return out
}

func TestJPEGCaps(t *testing.T) {
	base := jpegVectorBytes(jpegVectors[2])
	sof := jpegMarkerOffset(t, base, 0xc0)
	for _, pair := range [][2]uint32{{1025, 1}, {1, 1025}, {513, 512}, {1024, 1024}, {0xffff, 0xffff}} {
		data := mutateJPEG(base, sof+4, func(d []byte, i int) {
			binary.BigEndian.PutUint16(d[i:], uint16(pair[0]))
			binary.BigEndian.PutUint16(d[i+2:], uint16(pair[1]))
		})
		im, err := decodeJPEG(data)
		if pair[0]*pair[1] > webstyle.MaxImagePixels || pair[0] > webstyle.MaxImageDimension || pair[1] > webstyle.MaxImageDimension {
			if err != errJPEGLimit || im != nil {
				t.Fatalf("dimensions %v: image=%v err=%v", pair, im, err)
			}
		}
	}
	if _, err := decodeJPEG(make([]byte, webstyle.MaxImageBytes+1)); err != errJPEGLimit {
		t.Fatal("source cap not honored")
	}
	// A header that never reaches a scan.
	if _, err := decodeJPEG(base[:len(base)-2]); err == nil {
		t.Fatal("missing EOI accepted")
	}
}

func TestJPEGDecodeImageDispatch(t *testing.T) {
	data := jpegVectorBytes(jpegVectors[2])
	im, err := DecodeImage(data)
	if err != nil {
		t.Fatalf("DecodeImage: %v", err)
	}
	if im.Width != 64 || im.Height != 48 {
		t.Fatalf("decoded %dx%d", im.Width, im.Height)
	}
	// A progressive file must surface through the same entry point as a
	// named unsupported, not a generic failure.
	sof := jpegMarkerOffset(t, data, 0xc0)
	data[sof] = 0xc2
	if _, err := DecodeImage(data); !errors.Is(err, ErrImageUnsupported) || err.Error() != "image-jpeg-unsupported-progressive" {
		t.Fatalf("progressive dispatch: %v", err)
	}
}

func FuzzJPEG(f *testing.F) {
	for _, v := range jpegVectors[:4] {
		f.Add(jpegVectorBytes(v))
	}
	f.Add([]byte{})
	f.Add([]byte("not jpeg"))
	f.Fuzz(func(t *testing.T, data []byte) {
		im, err := decodeJPEG(data)
		if err != nil {
			if im != nil {
				t.Fatal("partial successful-looking image on error")
			}
			return
		}
		if im.Width <= 0 || im.Height <= 0 || im.Width > webstyle.MaxImageDimension ||
			im.Height > webstyle.MaxImageDimension || len(im.Pix) != im.Width*im.Height ||
			len(im.Pix) > webstyle.MaxImagePixels || len(data) > webstyle.MaxImageBytes {
			t.Fatal("decoder cap violated")
		}
	})
}

// TestJPEGHeaderSniff keeps GOVIEW's marker walk honest: the same segment
// chain the view package scans must reach SOF0 inside a bounded head.
func TestJPEGHeaderSniff(t *testing.T) {
	data := jpegVectorBytes(jpegVectors[9])
	off := jpegMarkerOffset(t, data, 0xc0)
	w := int(data[off+6])<<8 | int(data[off+7])
	h := int(data[off+4])<<8 | int(data[off+5])
	if w != 160 || h != 120 {
		t.Fatalf("sniff dims = %dx%d, want 160x120", w, h)
	}
	if off > 2048 {
		t.Fatalf("SOF0 at offset %d, past the viewer's header read bound", off)
	}
}
