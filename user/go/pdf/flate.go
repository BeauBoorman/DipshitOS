package pdf

import "unsafe"

// Owned RFC 1950/1951 decoder. No std zlib Reader allocation, decoded cache,
// data-dependent recursion, lazy table growth or uninstrumented backrefs.
type huff struct {
	count  [16]uint16
	symbol [288]uint16
	max    uint8
}
type decoder struct {
	window           [32768]byte
	lit, dist, codes huff
	lengths          [320]uint8
	decodeHeader
}
type decodeHeader struct {
	pos, end                       uint32
	bits                           uint64
	nbits                          uint8
	raw, final, done, started      bool
	stored, copyLeft, copyDistance uint32
	written                        uint64
	a, b                           uint32
	windowMax                      uint32
}

// openDecoder returns (true, false) with a live streaming decoder on slot,
// (false, true) when the stream carries a lone DCTDecode and the caller set
// allowDCT — the image path then routes it to the A4 hook — or (false,
// false) with a failure set.
func (e *engine) openDecoder(slot, n int, allowDCT bool) (bool, bool) {
	if slot < 0 || slot >= 2 || e.l.Decoders >= 2 {
		e.set(DecoderLimit)
		return false, false
	}
	v, start, length, stream := e.objectValue(n)
	if !stream {
		e.set(Malformed)
		return false, false
	}
	filter := e.get(v, "Filter")
	raw := filter.k == kBad
	if filter.k == kArray {
		if filter.count != 1 {
			e.set(UnsupportedFilter)
			return false, false
		}
		i := e.iter(filter)
		filter = i.next().val
	}
	if !raw && !e.named(filter, "FlateDecode") {
		if allowDCT && e.named(filter, "DCTDecode") {
			return false, true
		}
		e.set(UnsupportedFilter)
		return false, false
	}
	par := e.get(v, "DecodeParms")
	if par.k == kArray {
		if par.count != 1 {
			e.set(UnsupportedFilter)
			return false, false
		}
		i := e.iter(par)
		par = i.next().val
	}
	if par.k != kBad && par.k != kNull {
		if par.k != kDict {
			e.set(UnsupportedFilter)
			return false, false
		}
		e.allowed(par, "Predictor", UnsupportedFilter)
		if e.integer(e.get(par, "Predictor")) != 1 {
			e.set(UnsupportedFilter)
		}
	}
	if e.f.Code != OK {
		return false, false
	}
	if !e.charge(Zero, uint64(unsafe.Sizeof(decodeHeader{}))) {
		return false, false
	}
	// History is readable only below written, so previous bytes need no
	// clearing. Tables expose only their freshly built count/symbol prefixes.
	e.dec[slot].decodeHeader = decodeHeader{pos: uint32(start), end: uint32(start + length), raw: raw, a: 1}
	e.l.Decoders++
	if !raw {
		d := &e.dec[slot]
		cmf, flg := e.compressed(d), e.compressed(d)
		d.windowMax = 1 << ((cmf >> 4) + 8)
		if cmf&15 != 8 || cmf>>4 > 7 || (int(cmf)*256+int(flg))%31 != 0 || flg&32 != 0 {
			e.set(MalformedStream)
		}
	}
	if e.f.Code != OK {
		e.closeDecoder(slot)
	}
	return e.f.Code == OK, false
}
func (e *engine) closeDecoder(slot int) {
	if e.l.Decoders > 0 {
		e.l.Decoders--
	}
	e.dec[slot].done = true
}
func (e *engine) compressed(d *decoder) byte {
	if d.pos >= d.end {
		e.set(MalformedStream)
		return 0
	}
	b := e.byteAt(int(d.pos))
	d.pos++
	return b
}
func (e *engine) bits(d *decoder, n uint8) uint32 {
	if !e.charge(InputBit, uint64(n)) {
		return 0
	}
	for d.nbits < n && e.f.Code == OK {
		d.bits |= uint64(e.compressed(d)) << d.nbits
		d.nbits += 8
	}
	v := uint32(d.bits & ((uint64(1) << n) - 1))
	d.bits >>= n
	d.nbits -= n
	return v
}
func (e *engine) table(h *huff, lens []uint8, allowEmpty bool) {
	if !e.charge(Zero, uint64(unsafeHuffBytes)) {
		return
	}
	*h = huff{}
	for i, n := range lens {
		if !e.charge(Huffman, 1) {
			return
		}
		if n > 15 {
			e.set(MalformedStream)
			return
		}
		h.count[n]++
		if n > h.max {
			h.max = n
		}
		_ = i
	}
	if h.max == 0 {
		if !allowEmpty {
			e.set(MalformedStream)
		}
		return
	}
	left := 1
	for i := 1; i <= 15; i++ {
		e.charge(Huffman, 1)
		left = left*2 - int(h.count[i])
		if left < 0 {
			e.set(MalformedStream)
			return
		}
	}
	if left != 0 && !(h.max == 1 && h.count[1] == 1) {
		e.set(MalformedStream)
		return
	}
	var off [16]uint16
	for i := 1; i < 15; i++ {
		e.charge(Huffman, 1)
		off[i+1] = off[i] + h.count[i]
	}
	for i, n := range lens {
		if !e.charge(Huffman, 1) {
			return
		}
		if n != 0 {
			h.symbol[off[n]] = uint16(i)
			off[n]++
		}
	}
}

const unsafeHuffBytes = unsafe.Sizeof(huff{})

func (e *engine) symbol(d *decoder, h *huff) int {
	code, first, index := 0, 0, 0
	for n := 1; n <= int(h.max) && e.f.Code == OK; n++ {
		code |= int(e.bits(d, 1))
		e.charge(Huffman, 1)
		count := int(h.count[n])
		if code < first+count {
			return int(h.symbol[index+code-first])
		}
		index += count
		first = (first + count) << 1
		code <<= 1
	}
	e.set(MalformedStream)
	return 0
}

// RFC order is explicit rather than derived from symbol values.
var dynamicOrder = [19]uint8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
var lengthBase = [29]uint16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
var lengthExtra = [29]uint8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
var distBase = [30]uint16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
var distExtra = [30]uint8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

func (e *engine) block(d *decoder) {
	e.charge(Block, 1)
	d.final = e.bits(d, 1) != 0
	t := e.bits(d, 2)
	d.started = true
	switch t {
	case 0:
		d.bits = 0
		d.nbits = 0
		n := uint32(e.compressed(d))
		n |= uint32(e.compressed(d)) << 8
		inv := uint32(e.compressed(d))
		inv |= uint32(e.compressed(d)) << 8
		if n^inv != 65535 {
			e.set(MalformedStream)
			return
		}
		d.stored = n
		// A zero stored block ends immediately, not a fake literal.
	case 1:
		for i := 0; i < 288; i++ {
			e.charge(Huffman, 1)
			n := uint8(8)
			if i >= 144 && i < 256 {
				n = 9
			}
			if i >= 256 && i < 280 {
				n = 7
			}
			d.lengths[i] = n
		}
		e.table(&d.lit, d.lengths[:288], false)
		for i := 0; i < 32; i++ {
			e.charge(Huffman, 1)
			d.lengths[i] = 5
		}
		e.table(&d.dist, d.lengths[:32], false)
	case 2:
		nlit, ndist, ncode := int(e.bits(d, 5))+257, int(e.bits(d, 5))+1, int(e.bits(d, 4))+4
		if nlit > 286 {
			e.set(MalformedStream)
			return
		}
		for i := 0; i < 19; i++ {
			e.charge(Huffman, 1)
			d.lengths[i] = 0
		}
		for i := 0; i < ncode; i++ {
			e.charge(Huffman, 1)
			d.lengths[dynamicOrder[i]] = uint8(e.bits(d, 3))
		}
		e.table(&d.codes, d.lengths[:19], false)
		if d.codes.max == 1 && d.codes.count[1] == 1 {
			e.set(MalformedStream)
			return
		}
		for i := 0; i < nlit+ndist && e.f.Code == OK; {
			s := e.symbol(d, &d.codes)
			n, v := 1, uint8(s)
			switch s {
			case 16:
				if i == 0 {
					e.set(MalformedStream)
					return
				}
				n = int(e.bits(d, 2)) + 3
				v = d.lengths[i-1]
			case 17:
				n = int(e.bits(d, 3)) + 3
				v = 0
			case 18:
				n = int(e.bits(d, 7)) + 11
				v = 0
			}
			if s > 18 || i+n > nlit+ndist {
				e.set(MalformedStream)
				return
			}
			for j := 0; j < n; j++ {
				e.charge(Huffman, 1)
				d.lengths[i] = v
				i++
			}
		}
		if d.lengths[256] == 0 {
			e.set(MalformedStream)
			return
		}
		e.table(&d.lit, d.lengths[:nlit], false)
		e.table(&d.dist, d.lengths[nlit:nlit+ndist], true)
	default:
		e.set(MalformedStream)
	}
	// kind is retained in an otherwise unused length slot after table build.
	d.lengths[319] = uint8(t)
}
func (e *engine) finish(d *decoder) {
	d.bits = 0
	d.nbits = 0
	var want uint32
	for i := 0; i < 4; i++ {
		e.charge(Checksum, 1)
		want = want<<8 | uint32(e.compressed(d))
	}
	if want != d.b<<16|d.a || d.pos != d.end {
		e.set(MalformedStream)
	}
	d.done = true
}
func (e *engine) decoded(slot int) (byte, bool) {
	d := &e.dec[slot]
	if d.done || e.f.Code != OK {
		return 0, false
	}
	var b byte
	if d.raw {
		if d.pos == d.end {
			d.done = true
			return 0, false
		}
		b = e.compressed(d)
	} else {
		found := false
		for !found && e.f.Code == OK {
			if d.copyLeft > 0 {
				e.charge(Examine, 1)
				b = d.window[(d.written-uint64(d.copyDistance))&32767]
				d.copyLeft--
				found = true
				break
			}
			if !d.started {
				e.block(d)
			}
			if d.lengths[319] == 0 {
				if d.stored > 0 {
					b = e.compressed(d)
					d.stored--
					found = true
					break
				}
			} else {
				s := e.symbol(d, &d.lit)
				if s < 256 {
					b = byte(s)
					found = true
					break
				}
				if s != 256 {
					if s < 257 || s > 285 {
						e.set(MalformedStream)
						break
					}
					i := s - 257
					d.copyLeft = uint32(lengthBase[i]) + e.bits(d, lengthExtra[i])
					j := e.symbol(d, &d.dist)
					if j > 29 {
						e.set(MalformedStream)
						break
					}
					d.copyDistance = uint32(distBase[j]) + e.bits(d, distExtra[j])
					if d.copyDistance > d.windowMax || uint64(d.copyDistance) > d.written {
						e.set(MalformedStream)
						break
					}
					continue
				}
			}
			if d.final {
				e.finish(d)
				return 0, false
			}
			d.started = false
		}
	}
	if e.f.Code != OK {
		return 0, false
	}
	e.set(e.l.expand())
	if e.f.Code != OK {
		return 0, false
	}
	e.charge(Copy, 1)
	d.window[d.written&32767] = b
	d.written++
	e.charge(Checksum, 1)
	d.a = (d.a + uint32(b)) % 65521
	d.b = (d.b + d.a) % 65521
	return b, e.f.Code == OK
}
