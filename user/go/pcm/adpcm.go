// adpcm.go — M162d (issue #2980): the IMA and Microsoft ADPCM block
// decoders. Both codecs carry all decode state inside each block's header
// (the predictor/index preamble), so a block decodes with no memory of the
// block before it — which is what lets the pipe stream one block at a
// time with the same bounded footprint PCM has.
//
// Layouts (RIFF/WAVE conventions, shared by every DVI/MS encoder):
//
//	IMA mono:   [4 B preamble][4 B groups of 8 nibbles lo-first]
//	IMA stereo: [2×4 B preambles][8 B groups: 4 B ch0 then 4 B ch1]
//	MS mono:    [7 B header][bytes = 2 samples each, hi nibble first]
//	MS stereo:  [2×7 B header, field-interleaved][bytes: hi=ch0, lo=ch1]
//
// The MS header's own quirk is worth pinning: the file stores iSamp1 then
// iSamp2 per channel, but the OUTPUT order is iSamp2, iSamp1 — the
// predictor treats samp1 as the most recent sample.
package pcm

// imaStep is the IMA/DVI step table (89 entries); imaIndex is the
// nibble-indexed step-index delta.
var imaStep = [89]int32{
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
	19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
	50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
	130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
	337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
	876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
	2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
	5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
	15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
}

var imaIndex = [16]int32{-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8}

// msAdapt is the MS ADPCM delta multiplier table (indexed by nibble).
var msAdapt = [16]int32{
	230, 230, 230, 230, 307, 409, 512, 614,
	768, 614, 512, 409, 307, 230, 230, 230,
}

func clipS16(v int32) int32 {
	if v > 32767 {
		return 32767
	}
	if v < -32768 {
		return -32768
	}
	return v
}

// imaExpand decodes one IMA nibble into the channel's predictor and index.
func imaExpand(pred, idx *int32, nib byte) int16 {
	step := imaStep[*idx]
	diff := step >> 3
	if nib&4 != 0 {
		diff += step
	}
	if nib&2 != 0 {
		diff += step >> 1
	}
	if nib&1 != 0 {
		diff += step >> 2
	}
	if nib&8 != 0 {
		*pred -= diff
	} else {
		*pred += diff
	}
	*pred = clipS16(*pred)
	*idx += imaIndex[nib&15]
	if *idx < 0 {
		*idx = 0
	} else if *idx > 88 {
		*idx = 88
	}
	return int16(*pred)
}

// decodeIMA decodes one IMA ADPCM block into out (len(out) >=
// SamplesPerBlock stereo pairs) and returns the decoded frame count. A
// short tail block yields a partial count matching WavInfo.partialFrames.
// Out-of-range preamble indices clamp, the DVI convention — a corrupt
// index degrades to wrong samples, not a stuck decoder.
func (p *Pipe) decodeIMA(blk []byte, out [][2]float32) int {
	ch := int(p.info.Channels)
	if len(blk) < 4*ch {
		return 0
	}
	var pred, idx [2]int32
	for c := 0; c < ch; c++ {
		pred[c] = int32(int16(le16(blk[4*c:])))
		ix := int32(blk[4*c+2])
		if ix > 88 {
			ix = 88
		}
		idx[c] = ix
		out[0][c] = float32(pred[c]) / 32768
	}
	if ch == 1 {
		out[0][1] = out[0][0]
	}
	n := 1
	spb := int(p.info.SamplesPerBlock)
	groups := (len(blk) - 4*ch) / (4 * ch)
	for g := 0; g < groups && n < spb; g++ {
		for c := 0; c < ch; c++ {
			off := 4*ch + g*4*ch + c*4
			for k := 0; k < 8; k++ {
				by := blk[off+k/2]
				nib := by >> 4
				if k&1 == 0 {
					nib = by & 0xf
				}
				s := imaExpand(&pred[c], &idx[c], nib)
				if i := n + k; i < spb {
					out[i][c] = float32(s) / 32768
					if ch == 1 {
						out[i][1] = out[i][0]
					}
				}
			}
		}
		n += 8
	}
	if n > spb {
		n = spb
	}
	return n
}

// decodeMS decodes one MS ADPCM block into out and returns the decoded
// frame count. A predictor byte outside the fmt chunk's coefficient table
// is the one decode-time refusal: the block is corrupt, not merely lossy.
func (p *Pipe) decodeMS(blk []byte, out [][2]float32) (int, error) {
	ch := int(p.info.Channels)
	if len(blk) < 7*ch {
		return 0, nil
	}
	var coef1, coef2 [2]int32
	var delta, s1, s2 [2]int32
	for c := 0; c < ch; c++ {
		pr := int(blk[c])
		if pr >= p.info.NCoef {
			return 0, refuseN("adpcm predictor", uint64(pr))
		}
		coef1[c] = p.info.Coef[pr][0]
		coef2[c] = p.info.Coef[pr][1]
	}
	for c := 0; c < ch; c++ {
		delta[c] = int32(int16(le16(blk[ch+2*c:])))
	}
	for c := 0; c < ch; c++ {
		s1[c] = int32(int16(le16(blk[3*ch+2*c:])))
	}
	for c := 0; c < ch; c++ {
		s2[c] = int32(int16(le16(blk[5*ch+2*c:])))
	}
	// The MS quirk: iSamp2 is output first, iSamp1 second.
	for c := 0; c < ch; c++ {
		out[0][c] = float32(s2[c]) / 32768
		out[1][c] = float32(s1[c]) / 32768
	}
	if ch == 1 {
		out[0][1], out[1][1] = out[0][0], out[1][0]
	}
	n := 2
	spb := int(p.info.SamplesPerBlock)
	expand := func(c int, nib byte) int16 {
		nibS := int32(nib)
		if nib&8 != 0 {
			nibS -= 16
		}
		v := (s1[c]*coef1[c]+s2[c]*coef2[c])>>8 + nibS*delta[c]
		v = clipS16(v)
		s2[c] = s1[c]
		s1[c] = v
		delta[c] = msAdapt[nib&15] * delta[c] >> 8
		if delta[c] < 16 {
			delta[c] = 16
		}
		return int16(v)
	}
	data := blk[7*ch:]
	for i := 0; i < len(data) && n < spb; i++ {
		if ch == 1 {
			out[n][0] = float32(expand(0, data[i]>>4)) / 32768
			out[n][1] = out[n][0]
			n++
			if n < spb {
				out[n][0] = float32(expand(0, data[i]&0xf)) / 32768
				out[n][1] = out[n][0]
				n++
			}
		} else {
			out[n][0] = float32(expand(0, data[i]>>4)) / 32768
			out[n][1] = float32(expand(1, data[i]&0xf)) / 32768
			n++
		}
	}
	if n > spb {
		n = spb
	}
	return n, nil
}
