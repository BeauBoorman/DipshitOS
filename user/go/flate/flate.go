// Package flate is the one freestanding RFC 1951 DEFLATE + RFC 1950 zlib
// inflater for the guest userland (M136a). It is the hardened
// webrender/png_inflate.go reader promoted to a shared home — itself an
// attributed copy of user/go/git/gitread/flate.go at source revision
// 27f6acf0e6b93e74124b68c03691af6e5fb45354 (repository LICENSE). Original
// SHA-256: 226a8a7736604deb01c175b16c7e7dbed3f7d9e6146fcece4555f8d8fe4d5a38.
// M93e adds invalid/oversubscribed-tree and missing-end-code checks; the
// original reader is unchanged. No external decoder code is adopted.
//
// compress/zlib pulls fmt/os on this GOOS, so the guest cannot import it.
// The package is a straight port of user/src/lib/flate.zig with no
// dependencies, so host and guest share it.
//
// pdf/flate.go stays separate on purpose: it is a metered, streaming
// decoder embedded in the PDF engine's charge accounting and persistent
// decoder slots, not a copy of this one-shot reader.
package flate

type inflateErr string

func (e inflateErr) Error() string { return string(e) }

var (
	errInvalidBlock   = inflateErr("flate: invalid block type")
	errInvalidHuffman = inflateErr("flate: invalid huffman tree")
	errInvalidDist    = inflateErr("flate: invalid distance")
	errInvalidZlib    = inflateErr("flate: invalid zlib header")
	errAdler          = inflateErr("flate: adler32 mismatch")
	errCorruptFlate   = inflateErr("flate: corrupt stream")
	errBufSmall       = inflateErr("flate: buffer too small")
)

var lengthBase = [...]uint16{
	3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
	35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}

var lengthExtra = [...]uint8{
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
	3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
}

var distBase = [...]uint16{
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
	257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}

var distExtra = [...]uint8{
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
	7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}

var codeLengthOrder = [...]uint8{
	16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
}

type bitReader struct {
	bytes    []byte
	bytePos  int
	bitBuf   uint64
	bitCount uint
}

func (r *bitReader) readBit() (uint32, error) {
	return r.readBits(1)
}

func (r *bitReader) readBits(count uint) (uint32, error) {
	if count == 0 {
		return 0, nil
	}
	for r.bitCount < count {
		if r.bytePos >= len(r.bytes) {
			return 0, errCorruptFlate
		}
		r.bitBuf |= uint64(r.bytes[r.bytePos]) << r.bitCount
		r.bytePos++
		r.bitCount += 8
	}
	mask := uint64(1)<<count - 1
	val := uint32(r.bitBuf & mask)
	r.bitBuf >>= count
	r.bitCount -= count
	return val, nil
}

func (r *bitReader) alignToByte() {
	discard := r.bitCount % 8
	r.bitBuf >>= discard
	r.bitCount -= discard
}

func (r *bitReader) readU16LE() (uint16, error) {
	r.alignToByte()
	low, err := r.readBits(8)
	if err != nil {
		return 0, err
	}
	high, err := r.readBits(8)
	if err != nil {
		return 0, err
	}
	return uint16(low | high<<8), nil
}

type huffmanTree struct {
	blCount   [16]uint16
	firstCode [16]uint16
	startIdx  [16]uint16
	symbols   [288]uint16
}

func (t *huffmanTree) build(lengths []byte) error {
	if len(lengths) > len(t.symbols) {
		return errInvalidHuffman
	}
	for i := range t.blCount {
		t.blCount[i] = 0
	}
	for _, ln := range lengths {
		if ln > 15 {
			return errInvalidHuffman
		}
		if ln > 0 {
			t.blCount[ln]++
		}
	}
	left, maxBits := 1, 0
	for bits := 1; bits <= 15; bits++ {
		left = left*2 - int(t.blCount[bits])
		if left < 0 {
			return errInvalidHuffman
		}
		if t.blCount[bits] != 0 {
			maxBits = bits
		}
	}
	// RFC 1951 permits an empty distance alphabet and a single one-bit
	// code. Other incomplete alphabets cannot decode a valid block.
	if left != 0 && maxBits > 1 {
		return errInvalidHuffman
	}
	var code uint16
	for bits := 1; bits <= 15; bits++ {
		code = (code + t.blCount[bits-1]) << 1
		t.firstCode[bits] = code
	}
	var total uint16
	for bits := 1; bits <= 15; bits++ {
		t.startIdx[bits] = total
		total += t.blCount[bits]
	}
	offsets := t.startIdx
	for sym, ln := range lengths {
		if ln > 0 {
			off := offsets[ln]
			offsets[ln]++
			t.symbols[off] = uint16(sym)
		}
	}
	return nil
}

func (t *huffmanTree) decode(r *bitReader) (uint16, error) {
	var cur uint16
	for ln := 1; ln <= 15; ln++ {
		bit, err := r.readBit()
		if err != nil {
			return 0, err
		}
		cur = cur<<1 | uint16(bit)
		count := t.blCount[ln]
		if count == 0 {
			continue
		}
		first := t.firstCode[ln]
		if cur >= first && cur < first+count {
			idx := t.startIdx[ln] + (cur - first)
			return t.symbols[idx], nil
		}
	}
	return 0, errInvalidHuffman
}

func adler32(data []byte) uint32 {
	s1 := uint32(1)
	s2 := uint32(0)
	for _, b := range data {
		s1 = (s1 + uint32(b)) % 65521
		s2 = (s2 + s1) % 65521
	}
	return s2<<16 | s1
}

// InflateZlib decompresses one RFC 1950 zlib stream at the start of src
// into dst. It returns the decompressed length and how many input bytes
// the stream occupied (header + deflate + Adler-32), so the caller can
// step to the next concatenated object in a packfile.
func InflateZlib(dst, src []byte) (n, consumed int, err error) {
	if len(src) < 6 {
		return 0, 0, errCorruptFlate
	}
	cmf, flg := src[0], src[1]
	if cmf&0x0f != 8 || (cmf>>4) > 7 {
		return 0, 0, errInvalidZlib
	}
	if (uint32(cmf)<<8|uint32(flg))%31 != 0 {
		return 0, 0, errInvalidZlib
	}
	if flg&0x20 != 0 {
		return 0, 0, errInvalidZlib
	}
	r := bitReader{bytes: src[2:]}
	n, err = inflateDeflate(&r, dst)
	if err != nil {
		return 0, 0, err
	}
	r.alignToByte()
	var adler uint32
	for i := 0; i < 4; i++ {
		b, err := r.readBits(8)
		if err != nil {
			return 0, 0, err
		}
		adler = adler<<8 | b
	}
	if adler32(dst[:n]) != adler {
		return 0, 0, errAdler
	}
	return n, 2 + r.bytePos, nil
}

// Inflate decompresses one raw RFC 1951 DEFLATE stream at the start of src
// into dst. consumed is the stream's extent in whole bytes — a trailing
// partial byte counts as consumed — so a caller can step to whatever
// follows the stream (e.g. a gzip member's CRC32+ISIZE trailer).
func Inflate(dst, src []byte) (n, consumed int, err error) {
	r := bitReader{bytes: src}
	n, err = inflateDeflate(&r, dst)
	if err != nil {
		return 0, 0, err
	}
	r.alignToByte()
	return n, r.bytePos, nil
}

func inflateDeflate(r *bitReader, out []byte) (int, error) {
	outPos := 0
	var fixedLit, fixedDist *huffmanTree
	for {
		final, err := r.readBit()
		if err != nil {
			return 0, err
		}
		btype, err := r.readBits(2)
		if err != nil {
			return 0, err
		}
		switch btype {
		case 0:
			r.alignToByte()
			ln, err := r.readU16LE()
			if err != nil {
				return 0, err
			}
			nlen, err := r.readU16LE()
			if err != nil {
				return 0, err
			}
			if ln != (^nlen & 0xffff) {
				return 0, errCorruptFlate
			}
			if outPos+int(ln) > len(out) {
				return 0, errBufSmall
			}
			for i := 0; i < int(ln); i++ {
				b, err := r.readBits(8)
				if err != nil {
					return 0, err
				}
				out[outPos] = byte(b)
				outPos++
			}
		case 1:
			if fixedLit == nil {
				var litLen [288]byte
				for i := 0; i < 144; i++ {
					litLen[i] = 8
				}
				for i := 144; i < 256; i++ {
					litLen[i] = 9
				}
				for i := 256; i < 280; i++ {
					litLen[i] = 7
				}
				for i := 280; i < 288; i++ {
					litLen[i] = 8
				}
				var lt huffmanTree
				if err := lt.build(litLen[:]); err != nil {
					return 0, err
				}
				fixedLit = &lt
				var distLen [32]byte
				for i := range distLen {
					distLen[i] = 5
				}
				var dt huffmanTree
				if err := dt.build(distLen[:]); err != nil {
					return 0, err
				}
				fixedDist = &dt
			}
			if err := decodeBlock(r, fixedLit, fixedDist, out, &outPos); err != nil {
				return 0, err
			}
		case 2:
			hlit, err := r.readBits(5)
			if err != nil {
				return 0, err
			}
			hlit += 257
			if hlit > 286 {
				return 0, errInvalidHuffman
			}
			hdist, err := r.readBits(5)
			if err != nil {
				return 0, err
			}
			hdist++
			if hdist > 30 {
				return 0, errInvalidHuffman // the distance alphabet is 30 codes
			}
			hclen, err := r.readBits(4)
			if err != nil {
				return 0, err
			}
			hclen += 4
			var codeLenLens [19]byte
			for i := 0; i < int(hclen); i++ {
				v, err := r.readBits(3)
				if err != nil {
					return 0, err
				}
				codeLenLens[codeLengthOrder[i]] = byte(v)
			}
			var clTree huffmanTree
			if err := clTree.build(codeLenLens[:]); err != nil {
				return 0, err
			}
			var full [288 + 32]byte
			total := int(hlit + hdist)
			codeIdx := 0
			for codeIdx < total {
				sym, err := clTree.decode(r)
				if err != nil {
					return 0, err
				}
				switch {
				case sym < 16:
					full[codeIdx] = byte(sym)
					codeIdx++
				case sym == 16:
					if codeIdx == 0 {
						return 0, errInvalidHuffman
					}
					prev := full[codeIdx-1]
					rep, err := r.readBits(2)
					if err != nil {
						return 0, err
					}
					rep += 3
					if codeIdx+int(rep) > total {
						return 0, errInvalidHuffman
					}
					for i := 0; i < int(rep); i++ {
						full[codeIdx] = prev
						codeIdx++
					}
				case sym == 17:
					rep, err := r.readBits(3)
					if err != nil {
						return 0, err
					}
					rep += 3
					if codeIdx+int(rep) > total {
						return 0, errInvalidHuffman
					}
					for i := 0; i < int(rep); i++ {
						full[codeIdx] = 0
						codeIdx++
					}
				case sym == 18:
					rep, err := r.readBits(7)
					if err != nil {
						return 0, err
					}
					rep += 11
					if codeIdx+int(rep) > total {
						return 0, errInvalidHuffman
					}
					for i := 0; i < int(rep); i++ {
						full[codeIdx] = 0
						codeIdx++
					}
				default:
					return 0, errInvalidHuffman
				}
			}
			var litTree huffmanTree
			if full[256] == 0 {
				return 0, errInvalidHuffman
			}
			if err := litTree.build(full[:hlit]); err != nil {
				return 0, err
			}
			var distTree huffmanTree
			if err := distTree.build(full[hlit : hlit+hdist]); err != nil {
				return 0, err
			}
			if err := decodeBlock(r, &litTree, &distTree, out, &outPos); err != nil {
				return 0, err
			}
		default:
			return 0, errInvalidBlock
		}
		if final == 1 {
			break
		}
	}
	return outPos, nil
}

func decodeBlock(r *bitReader, lit, dist *huffmanTree, out []byte, outPos *int) error {
	for {
		sym, err := lit.decode(r)
		if err != nil {
			return err
		}
		switch {
		case sym < 256:
			if *outPos >= len(out) {
				return errBufSmall
			}
			out[*outPos] = byte(sym)
			*outPos++
		case sym == 256:
			return nil
		case sym <= 285:
			lenCode := int(sym - 257)
			extra, err := r.readBits(uint(lengthExtra[lenCode]))
			if err != nil {
				return err
			}
			matchLen := int(lengthBase[lenCode]) + int(extra)
			distSym, err := dist.decode(r)
			if err != nil {
				return err
			}
			if distSym >= 30 {
				return errCorruptFlate
			}
			distExtraVal, err := r.readBits(uint(distExtra[distSym]))
			if err != nil {
				return err
			}
			distance := int(distBase[distSym]) + int(distExtraVal)
			if distance > *outPos {
				return errInvalidDist
			}
			if *outPos+matchLen > len(out) {
				return errBufSmall
			}
			src := *outPos - distance
			for i := 0; i < matchLen; i++ {
				out[*outPos] = out[src]
				*outPos++
				src++
			}
		default:
			return errCorruptFlate
		}
	}
}

// ZlibStore wraps data in a valid zlib stream using only uncompressed
// DEFLATE blocks. Git loose objects accept this; it avoids a compressor.
func ZlibStore(data []byte) []byte {
	const maxChunk = 65535
	nchunk := 1
	if len(data) > 0 {
		nchunk = (len(data) + maxChunk - 1) / maxChunk
	}
	if nchunk == 0 {
		nchunk = 1
	}
	out := make([]byte, 0, 2+len(data)+5*nchunk+4)
	out = append(out, 0x78, 0x01)
	off := 0
	if len(data) == 0 {
		out = append(out, 0x01, 0x00, 0x00, 0xff, 0xff)
	} else {
		for off < len(data) {
			n := len(data) - off
			if n > maxChunk {
				n = maxChunk
			}
			final := byte(0x00)
			if off+n == len(data) {
				final = 0x01
			}
			ln := uint16(n)
			out = append(out, final, byte(ln), byte(ln>>8), byte(^ln), byte((^ln)>>8))
			out = append(out, data[off:off+n]...)
			off += n
		}
	}
	sum := adler32(data)
	out = append(out, byte(sum>>24), byte(sum>>16), byte(sum>>8), byte(sum))
	return out
}
