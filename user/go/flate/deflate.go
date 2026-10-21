package flate

// deflate.go is the package's write half: the owned RFC 1951 encoder —
// fixed-Huffman blocks plus a bounded LZ77 hash chain — wrapped in the
// RFC 1950 zlib frame the readers require. Written for user/go/pdfwrite
// (M153a) and promoted here (issue #2976) so pdfwrite and webrender's PNG
// writer share one compressor; the promotion moved the algorithm
// unchanged (private names gained a deflate- prefix to read clearly next
// to the reader's), so pdfwrite's output stays byte-identical. There is
// no stored or dynamic-block path and no std compress dependency; every
// stream it emits decodes through InflateZlib and the metered decoder
// inside user/go/pdf. The length/distance tables and adler32 are the
// reader's own in flate.go.

const (
	deflateWindowSize = 32768
	deflateMaxMatch   = 258
	deflateMinMatch   = 3
	deflateMaxChain   = 128
	deflateNiceMatch  = 96
	deflateHashBits   = 15
	deflateHashSize   = 1 << deflateHashBits
)

type bitbuf struct {
	out   []byte
	acc   uint64
	nbits uint
}

func (b *bitbuf) put(v uint64, n uint) {
	b.acc |= v << b.nbits
	b.nbits += n
	for b.nbits >= 8 {
		b.out = append(b.out, byte(b.acc))
		b.acc >>= 8
		b.nbits -= 8
	}
}

// code emits an n-bit Huffman code, which DEFLATE stores most-significant
// bit first inside the least-significant-bit-first byte stream.
func (b *bitbuf) code(v uint32, n uint) {
	var r uint64
	for i := uint(0); i < n; i++ {
		r = r<<1 | uint64(v>>i&1)
	}
	b.put(r, n)
}

func (b *bitbuf) align() {
	if b.nbits > 0 {
		b.out = append(b.out, byte(b.acc))
		b.acc, b.nbits = 0, 0
	}
}

func (b *bitbuf) literal(sym uint32) {
	switch {
	case sym < 144:
		b.code(0x30+sym, 8)
	case sym < 256:
		b.code(0x190+sym-144, 9)
	case sym < 280:
		b.code(sym-256, 7)
	default:
		b.code(0xC0+sym-280, 8)
	}
}

func (b *bitbuf) match(length, dist int) {
	i := 0
	for i < 28 && int(lengthBase[i+1]) <= length {
		i++
	}
	b.literal(uint32(257 + i))
	b.put(uint64(length-int(lengthBase[i])), uint(lengthExtra[i]))
	j := 0
	for j < 29 && int(distBase[j+1]) <= dist {
		j++
	}
	b.code(uint32(j), 5)
	b.put(uint64(dist-int(distBase[j])), uint(distExtra[j]))
}

func deflateHash3(src []byte, i int) uint32 {
	return (uint32(src[i])*0x1e35a7bd ^ uint32(src[i+1])*0x9e3779b1 ^ uint32(src[i+2])*0x85ebca6b) >> (32 - deflateHashBits)
}

// CompressZlib compresses src into a complete zlib stream: the 32K-window
// header, one final fixed-Huffman block, and the big-endian Adler-32.
func CompressZlib(src []byte) []byte {
	b := bitbuf{out: make([]byte, 0, len(src)/2+64)}
	b.out = append(b.out, 0x78, 0x01)
	b.put(1, 1)
	b.put(1, 2)
	head := make([]int32, deflateHashSize)
	var prev [deflateWindowSize]int32
	for i := 0; i < len(src); {
		best, dist := 0, 0
		if i+deflateMinMatch <= len(src) {
			h := deflateHash3(src, i)
			cand := int(head[h]) - 1
			prev[i&(deflateWindowSize-1)] = head[h]
			head[h] = int32(i + 1)
			limit := i - deflateWindowSize
			for chain := 0; cand >= 0 && cand > limit && chain < deflateMaxChain; chain++ {
				n := 0
				for i+n < len(src) && n < deflateMaxMatch && src[cand+n] == src[i+n] {
					n++
				}
				if n > best {
					best, dist = n, i-cand
					if n >= deflateMaxMatch || n >= deflateNiceMatch {
						break
					}
				}
				cand = int(prev[cand&(deflateWindowSize-1)]) - 1
			}
		}
		if best >= deflateMinMatch {
			b.match(best, dist)
			for j := i + 1; j < i+best && j+deflateMinMatch <= len(src); j++ {
				h := deflateHash3(src, j)
				prev[j&(deflateWindowSize-1)] = head[h]
				head[h] = int32(j + 1)
			}
			i += best
		} else {
			b.literal(uint32(src[i]))
			i++
		}
	}
	b.code(0, 7)
	b.align()
	sum := adler32(src)
	return append(b.out, byte(sum>>24), byte(sum>>16), byte(sum>>8), byte(sum))
}
