package pdf

import (
	"math"
	"unsafe"
	"virelai/vector"
)

// ADR 0040 A4: a lone /DCTDecode filter on an image XObject is admitted only
// through an adapter-installed decoder hook. The engine owns no image codec;
// with no hook installed the closed-subset refusal stands. The compressed
// stream is staged into the decode partition's unallocated staging span and
// the decoded raster is charged to the arena's A4-assigned margin, so no
// hook byte lives outside an admitted partition.
var imageDecoder func(data []byte) (w, h int, pix []uint32, err error)

// SetImageDecoder installs the adapter's DCTDecode hook (ADR 0040 A4). A nil
// hook restores the UnsupportedFilter refusal.
func SetImageDecoder(d func(data []byte) (w, h int, pix []uint32, err error)) {
	imageDecoder = d
}

// The compressed stream stages past the two decoder frames inside the decode
// partition; the decoded raster charges the margin partition after stateEnd.
// The margin's last 65,536 B stay adapter scratch (pdfproof's plan, receipt
// and native I/O borrow them) — the engine stages only below that line.
const (
	dctStageOff = documentEnd + 2*unsafe.Sizeof(decoder{})
	dctStageCap = decodeEnd - 3072 - dctStageOff
	dctPixEnd   = ArenaBytes - 65_536
	dctMaxPixel = (dctPixEnd - stateEnd) / 4
)

func (e *engine) dctImage(n int, v value, start, length, w, h, channels int, m vector.Affine, x0, x1, y0, y1 int) {
	if imageDecoder == nil {
		e.set(UnsupportedFilter)
		return
	}
	// A4 admits a lone DCTDecode only with no DecodeParms other than the
	// default: absent, null or a one-element array wrapping null.
	par := e.get(v, "DecodeParms")
	if par.k == kArray {
		if par.count != 1 {
			e.set(UnsupportedFilter)
			return
		}
		it := e.iter(par)
		par = it.next().val
	}
	if par.k != kBad && par.k != kNull {
		e.set(UnsupportedFilter)
		return
	}
	if length < 0 || length > int(dctStageCap) {
		e.set(MemoryLimit)
		return
	}
	stage := e.arena[int(dctStageOff) : int(dctStageOff)+length]
	got, c := e.src.ReadAt(stage, int64(start), e.l)
	e.set(c)
	if got != length {
		e.set(ReadFailed)
	}
	if e.f.Code != OK {
		return
	}
	dw, dh, pix, err := imageDecoder(stage)
	if err != nil {
		e.set(UnsupportedFilter)
		return
	}
	if dw != w || dh != h || len(pix) < w*h {
		e.set(MalformedStream)
		return
	}
	if w*h > dctMaxPixel {
		e.set(MemoryLimit)
		return
	}
	// The decoded raster's w*h*4 bytes are charged to the arena margin; the
	// hook's slice is borrowed for this call only and never retained.
	if !e.charge(Copy, uint64(w*h)) {
		return
	}
	out := pod[uint32](e.arena[stateEnd:dctPixEnd])[:w*h]
	copy(out, pix[:w*h])
	// Decoded samples count as expanded stream bytes, like every other
	// codec's output.
	exp := uint64(w * h * channels)
	if e.l.Expanded >= MaxExpansion || exp > MaxExpansion-e.l.Expanded {
		e.set(ExpansionLimit)
		return
	}
	if !e.charge(DecodeByte, exp) {
		return
	}
	e.l.Expanded += exp
	// Source row zero is local y=1, the same nearest-neighbor placement as
	// the streaming path: pixel-center ties go to the higher index.
	for y := y0; y < y1 && e.f.Code == OK; y++ {
		e.charge(Sample, 1)
		sy := int(math.Floor((1 - (float64(y)+0.5-m.F)/m.D) * float64(h)))
		sy = max(0, min(h-1, sy))
		for x := x0; x < x1 && e.f.Code == OK; x++ {
			e.charge(Sample, 1)
			sx := int(math.Floor((float64(x)+0.5-m.E)/m.A*float64(w)))
			sx = max(0, min(w-1, sx))
			e.charge(Examine, 4)
			if e.charge(Pixel, 1) {
				e.pix[y*int(e.state.page.width)+x] = out[sy*w+sx] | 0xff000000
			}
		}
	}
}
