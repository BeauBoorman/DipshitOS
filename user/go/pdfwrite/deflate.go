package pdfwrite

// Owned RFC 1951 encoder: fixed-Huffman blocks plus a bounded LZ77 hash
// chain, wrapped in the RFC 1950 zlib frame the readers require. There is
// no stored or dynamic-block path and no std compress dependency; every
// stream pdfwrite emits decodes through user/go/flate and the metered
// decoder inside user/go/pdf.

const (
	windowSize = 32768
	maxMatch   = 258
	minMatch   = 3
	maxChain   = 128
	niceMatch  = 96
	hashBits   = 15
	hashSize   = 1 << hashBits
)

var lengthBase = [29]int{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
var lengthExtra = [29]uint{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
var distBase = [30]int{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
var distExtra = [30]uint{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

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
	for i < 28 && lengthBase[i+1] <= length {
		i++
	}
	b.literal(uint32(257 + i))
	b.put(uint64(length-lengthBase[i]), lengthExtra[i])
	j := 0
	for j < 29 && distBase[j+1] <= dist {
		j++
	}
	b.code(uint32(j), 5)
	b.put(uint64(dist-distBase[j]), distExtra[j])
}

func hash3(src []byte, i int) uint32 {
	return (uint32(src[i])*0x1e35a7bd ^ uint32(src[i+1])*0x9e3779b1 ^ uint32(src[i+2])*0x85ebca6b) >> (32 - hashBits)
}

func adler32(src []byte) uint32 {
	s1, s2 := uint32(1), uint32(0)
	for _, b := range src {
		s1 = (s1 + uint32(b)) % 65521
		s2 = (s2 + s1) % 65521
	}
	return s2<<16 | s1
}

// deflateZlib compresses src into a complete zlib stream: the 32K-window
// header, one final fixed-Huffman block, and the big-endian Adler-32.
func deflateZlib(src []byte) []byte {
	b := bitbuf{out: make([]byte, 0, len(src)/2+64)}
	b.out = append(b.out, 0x78, 0x01)
	b.put(1, 1)
	b.put(1, 2)
	head := make([]int32, hashSize)
	var prev [windowSize]int32
	for i := 0; i < len(src); {
		best, dist := 0, 0
		if i+minMatch <= len(src) {
			h := hash3(src, i)
			cand := int(head[h]) - 1
			prev[i&(windowSize-1)] = head[h]
			head[h] = int32(i + 1)
			limit := i - windowSize
			for chain := 0; cand >= 0 && cand > limit && chain < maxChain; chain++ {
				n := 0
				for i+n < len(src) && n < maxMatch && src[cand+n] == src[i+n] {
					n++
				}
				if n > best {
					best, dist = n, i-cand
					if n >= maxMatch || n >= niceMatch {
						break
					}
				}
				cand = int(prev[cand&(windowSize-1)]) - 1
			}
		}
		if best >= minMatch {
			b.match(best, dist)
			for j := i + 1; j < i+best && j+minMatch <= len(src); j++ {
				h := hash3(src, j)
				prev[j&(windowSize-1)] = head[h]
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
