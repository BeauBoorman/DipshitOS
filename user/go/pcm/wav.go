// wav.go — the M99c (issue #2181) RIFF/WAVE reader, the parse half of the
// pcm package's input side. Nothing here touches a syscall: the parser reads
// through a caller-supplied byte source so the host corpus can drive it with
// slices and the guest with vi.FileRead.
//
// The bounds are the card's: at most maxChunks walked before `data`, the
// `fmt ` body is capped at maxFmt (PCM/float still admit only the three
// real sizes; ADPCM codecs declare extension fields), and every refusal is
// a NAME (WavError.Name) a marker or test can assert verbatim rather than a
// formatted sentence.
package pcm

import "errors"

// WavInfo is a parsed RIFF/WAVE header: the resolved sample format (an
// extensible file reports its SUBformat tag), the geometry, and how much PCM
// the `data` chunk declares. Frames is the whole-frame count — a tail of
// bytes that does not divide the frame size is not sound, it is a declared
// size with a partial frame, and the streamer stops at the whole frames.
type WavInfo struct {
	Tag      uint16 // resolved: FormatPCM, FormatFloat, FormatIMA or FormatMS
	Channels uint16 // 1 or 2
	Rate     uint32 // samples per second, 8000..96000
	Bits     uint16 // per channel: 8/16/24/32 (PCM), 32 (float), 4 (ADPCM)
	DataSize uint64 // declared data-chunk bytes (compressed for ADPCM)
	Frames   uint64 // DataSize / FrameBytes, or decoded samples for ADPCM

	// ADPCM block geometry (FormatIMA/FormatMS only): one block of
	// BlockAlign bytes decodes to SamplesPerBlock frames per channel.
	// Coef is the MS ADPCM coefficient table the fmt chunk carries.
	BlockAlign      uint16
	SamplesPerBlock uint16
	NCoef           int
	Coef            [32][2]int32
}

// FrameBytes is one interleaved input frame.
func (w WavInfo) FrameBytes() int { return int(w.Channels) * int(w.Bits) / 8 }

// RIFF/WAVE format tags this player resolves. WAVE_FORMAT_EXTENSIBLE carries
// its real tag in the sub-format GUID (first two bytes, little-endian).
const (
	FormatPCM        uint16 = 1
	FormatMS         uint16 = 0x0002 // Microsoft ADPCM
	FormatFloat      uint16 = 3
	FormatIMA        uint16 = 0x0011 // IMA/DVI ADPCM
	formatExtensible uint16 = 0xfffe
)

const (
	// maxChunks is the card's header walk bound.
	maxChunks = 32
	// maxFmt bounds the `fmt ` body: ADPCM fmt chunks carry the codec's
	// extension fields (samples-per-block, the MS coefficient table), so
	// they run larger than the three PCM/float sizes.
	maxFmt = 256
	// maxBlockAlign bounds one ADPCM block — the streaming pipe holds
	// exactly one, so this is the decode buffer's ceiling.
	maxBlockAlign = 16384
	// rateMin/rateMax bound the accepted input rates (8 kHz..96 kHz).
	rateMin, rateMax = 8000, 96000
)

// ErrNeedMore says the parse ran out of input before locating the `data`
// chunk header but nothing read so far is REFUSED: the caller should feed
// more bytes, or treat a physical EOF here as a truncated header.
var ErrNeedMore = errors.New("wav: need more header bytes")

// WavError is a named refusal: Name is the stable machine-readable reason
// (the corpus asserts these), Detail carries the offending number when the
// name alone is ambiguous (a format tag, a channel count).
type WavError struct {
	Name   string
	Detail uint64
}

func (e *WavError) Error() string {
	if e.Detail != 0 {
		return "wav: refused " + e.Name + " " + itoa(e.Detail)
	}
	return "wav: refused " + e.Name
}

func refuse(name string) *WavError { return &WavError{Name: name} }
func refuseN(name string, n uint64) *WavError {
	return &WavError{Name: name, Detail: n}
}

// compressedTags names the format tags the refusal reports by name — the
// card's example is 0x0055 mp3-in-wav. Unknown tags still refuse by number.
var compressedTags = map[uint16]string{
	0x0006: "alaw",
	0x0007: "mulaw",
	0x0050: "mpeg",
	0x0055: "mp3-in-wav",
	0x00ff: "aac-in-wav",
	0x0161: "wma",
	0x0162: "wma-pro",
	0x2000: "ac3",
}

// readFull fills buf exactly or fails — a short read at EOF is a truncated
// structure, and a caller error propagates.
func readFull(src Source, buf []byte) error {
	got := 0
	for got < len(buf) {
		n, err := src(buf[got:])
		if err != nil {
			return err
		}
		if n <= 0 {
			return ErrNeedMore
		}
		got += n
	}
	return nil
}

// skip discards n bytes of chunk body through the same bounded scratch; the
// header walk never holds more than this one buffer regardless of how large a
// skipped chunk claims to be.
func skip(src Source, n uint64, scratch []byte) error {
	for n > 0 {
		want := uint64(len(scratch))
		if n < want {
			want = n
		}
		got := 0
		for got < int(want) {
			m, err := src(scratch[got:int(want)])
			if err != nil {
				return err
			}
			if m <= 0 {
				return ErrNeedMore
			}
			got += m
		}
		n -= want
	}
	return nil
}

// ParseWav reads a RIFF/WAVE header from src and returns the negotiated input
// geometry. fileSize is the file's real size (0 = unknown): when known, a
// `data` chunk whose declared body runs past the file's end is refused up
// front as `data beyond eof` rather than discovered mid-play. When unknown,
// the streamer's own byte count still enforces the declared size.
//
// src is left positioned at the first PCM byte: the streamer keeps reading
// from the SAME source, which is what keeps memory constant — no rewind, no
// second open, no buffered header.
func ParseWav(src Source, fileSize uint64) (WavInfo, error) {
	var hdr [12]byte
	if err := readFull(src, hdr[:]); err != nil {
		return WavInfo{}, err
	}
	if string(hdr[0:4]) != "RIFF" || string(hdr[8:12]) != "WAVE" {
		return WavInfo{}, refuse("not a RIFF/WAVE file")
	}
	off := uint64(len(hdr))
	scratch := make([]byte, 4096)
	var info WavInfo
	haveFmt := false
	for chunks := 0; chunks < maxChunks; chunks++ {
		var ch [8]byte
		if err := readFull(src, ch[:]); err != nil {
			return WavInfo{}, err
		}
		size := uint64(le32(ch[4:8]))
		off += 8
		switch string(ch[0:4]) {
		case "fmt ":
			if size < 16 || size > maxFmt {
				return WavInfo{}, refuseN("fmt size", size)
			}
			var body [maxFmt]byte
			if err := readFull(src, body[:size]); err != nil {
				return WavInfo{}, err
			}
			off += size
			if err := parseFmt(&info, body[:size]); err != nil {
				return WavInfo{}, err
			}
			haveFmt = true
		case "data":
			if !haveFmt {
				return WavInfo{}, refuse("data before fmt")
			}
			if fileSize != 0 && off+size > fileSize {
				return WavInfo{}, refuse("data beyond eof")
			}
			info.DataSize = size
			info.Frames = info.framesOf(size)
			return info, nil
		default:
			if err := skip(src, size, scratch); err != nil {
				return WavInfo{}, err
			}
			off += size
		}
		// Odd-size chunks carry one pad byte (the size field never counts it).
		if size&1 != 0 {
			if err := readFull(src, scratch[:1]); err != nil {
				return WavInfo{}, err
			}
			off++
		}
	}
	return WavInfo{}, refuseN("chunks", maxChunks)
}

// framesOf is the whole-frame count a declared data size holds: PCM/float
// divide by frame bytes; ADPCM counts whole blocks times samplesPerBlock
// plus whatever a trailing partial block decodes to.
func (w WavInfo) framesOf(size uint64) uint64 {
	if w.Tag == FormatIMA || w.Tag == FormatMS {
		ba := uint64(w.BlockAlign)
		if ba == 0 {
			return 0
		}
		return size/ba*uint64(w.SamplesPerBlock) + w.partialFrames(size%ba)
	}
	return size / uint64(w.FrameBytes())
}

// partialFrames is the sample count a short tail block (rem < BlockAlign
// bytes) decodes to — the same count the decoder produces, so the stream
// byte accounting stays exact on unaligned files.
func (w WavInfo) partialFrames(rem uint64) uint64 {
	ch := uint64(w.Channels)
	var n uint64
	switch w.Tag {
	case FormatIMA:
		// 4-byte per-channel preamble, then 4-byte-per-channel groups of
		// 8 samples.
		if rem < 4*ch {
			return 0
		}
		n = 1 + (rem-4*ch)/(4*ch)*8
	case FormatMS:
		// 7-byte per-channel header, then nibble pairs (mono: 2 samples
		// a byte; stereo: one per channel a byte).
		if rem < 7*ch {
			return 0
		}
		n = 2 + (rem-7*ch)*2/ch
	}
	if n > uint64(w.SamplesPerBlock) {
		n = uint64(w.SamplesPerBlock)
	}
	return n
}

// parseFmt decodes one `fmt ` body into info. PCM, IEEE float and the two
// ADPCM codecs are playable here — and an extensible wrapper only when its
// sub-format GUID is one of the uncompressed two. Everything else refuses
// by name.
func parseFmt(info *WavInfo, b []byte) error {
	tag := le16(b[0:2])
	if tag == formatExtensible {
		// A 40-byte body: cbSize(22) at 16, validBits at 18, channelMask at
		// 20, then the 16-byte sub-format GUID at 24. The PCM/float GUIDs
		// share the fixed tail 0000-0010-8000-00aa00389b71, so the check is
		// the two-byte tag plus that tail.
		if len(b) < 40 {
			return refuseN("fmt size", uint64(len(b)))
		}
		tag = le16(b[24:26])
		if !guidTail(b[26:40]) {
			return refuse("extensible subformat")
		}
		if tag != FormatPCM && tag != FormatFloat {
			return refuseN("extensible tag", uint64(tag))
		}
	}
	switch tag {
	case FormatPCM, FormatFloat:
		if len(b) != 16 && len(b) != 18 && len(b) != 40 {
			return refuseN("fmt size", uint64(len(b)))
		}
	case FormatIMA, FormatMS:
		// ADPCM fmt chunks append cbSize + codec fields after the base 16;
		// both codecs declare at least through wSamplesPerBlock (byte 20).
		if len(b) < 20 {
			return refuseN("fmt size", uint64(len(b)))
		}
	default:
		if name, ok := compressedTags[tag]; ok {
			return refuse("fmt tag 0x" + hex4(tag) + " " + name)
		}
		return refuseN("fmt tag", uint64(tag))
	}
	info.Tag = tag
	info.Channels = le16(b[2:4])
	info.Rate = le32(b[4:8])
	info.Bits = le16(b[14:16])
	if info.Channels < 1 || info.Channels > 2 {
		return refuseN("channels", uint64(info.Channels))
	}
	if info.Rate < rateMin || info.Rate > rateMax {
		return refuseN("rate", uint64(info.Rate))
	}
	if tag == FormatIMA || tag == FormatMS {
		return parseADPCMFmt(info, b)
	}
	switch {
	case tag == FormatPCM && (info.Bits == 8 || info.Bits == 16 ||
		info.Bits == 24 || info.Bits == 32):
	case tag == FormatFloat && info.Bits == 32:
	default:
		return refuseN("bits", uint64(info.Bits))
	}
	// The declared block align must agree with the geometry, or the frame
	// arithmetic the streamer does would silently read the wrong boundaries.
	if block := le16(b[12:14]); block != uint16(info.FrameBytes()) {
		return refuseN("block align", uint64(block))
	}
	return nil
}

// parseADPCMFmt validates the codec extension fields both ADPCM flavors
// share: bitsPerSample is always 4, the block align must hold at least one
// block header and stay inside the decode buffer bound, and samplesPerBlock
// may not exceed what a block can encode. The MS flavor then reads its
// coefficient table out of the fmt body itself.
func parseADPCMFmt(info *WavInfo, b []byte) error {
	if info.Bits != 4 {
		return refuseN("bits", uint64(info.Bits))
	}
	ch := int(info.Channels)
	ba := int(le16(b[12:14]))
	spb := int(le16(b[18:20]))
	if info.Tag == FormatIMA {
		// 4-byte preamble per channel, then whole 4-byte-per-channel
		// nibble groups.
		if ba < 4*ch || ba > maxBlockAlign || (ba-4*ch)%(4*ch) != 0 {
			return refuseN("block align", uint64(ba))
		}
		if spb < 1 || spb > 1+(ba-4*ch)/(4*ch)*8 {
			return refuseN("samples per block", uint64(spb))
		}
	} else {
		// 7-byte header per channel; every later byte is nibble pairs.
		if ba < 7*ch || ba > maxBlockAlign {
			return refuseN("block align", uint64(ba))
		}
		if spb < 2 || spb > 2+(ba-7*ch)*2/ch {
			return refuseN("samples per block", uint64(spb))
		}
		if len(b) < 22 {
			return refuseN("fmt size", uint64(len(b)))
		}
		nc := int(le16(b[20:22]))
		if nc < 1 || nc > len(info.Coef) {
			return refuseN("adpcm coefs", uint64(nc))
		}
		if len(b) < 22+4*nc {
			return refuseN("fmt size", uint64(len(b)))
		}
		for i := 0; i < nc; i++ {
			info.Coef[i][0] = int32(int16(le16(b[22+4*i:])))
			info.Coef[i][1] = int32(int16(le16(b[24+4*i:])))
		}
		info.NCoef = nc
	}
	info.BlockAlign = uint16(ba)
	info.SamplesPerBlock = uint16(spb)
	return nil
}

// guidTail is the fixed 14-byte tail of the WAVE sub-format GUIDs
// (…-0000-0010-8000-00aa00389b71). The first two bytes are the tag itself,
// checked by the caller.
func guidTail(b []byte) bool {
	tail := [14]byte{0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
		0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}
	for i := range tail {
		if b[i] != tail[i] {
			return false
		}
	}
	return true
}

// Container names the file's container for the refusal marker — the card's
// contract is `gosound: mp3: no decoder`, naming what the BYTES are (sniffed),
// not the mime type. Magic first, the extension as the fallback the mime
// table itself uses.
func Container(name string, head []byte) string {
	if len(head) >= 12 && string(head[0:4]) == "RIFF" {
		if string(head[8:12]) == "WAVE" {
			return "wav"
		}
		return "riff" // a RIFF that is not WAVE (WEBP, AVI, …)
	}
	if len(head) >= 4 {
		switch string(head[0:4]) {
		case "OggS":
			return "ogg"
		case "fLaC":
			return "flac"
		}
	}
	if len(head) >= 3 && string(head[0:3]) == "ID3" {
		return "mp3"
	}
	// Raw MPEG frames have no ID3: the sync word is 0xFF Ex.
	if len(head) >= 2 && head[0] == 0xff && head[1]&0xe0 == 0xe0 {
		return "mp3"
	}
	if i := lastByte(name, '.'); i >= 0 {
		switch lower(name[i+1:]) {
		case "wav":
			return "wav"
		case "mp3":
			return "mp3"
		case "ogg":
			return "ogg"
		case "flac":
			return "flac"
		}
	}
	return "unknown"
}

// TagName is the input format's display name ("pcm16", "float32",
// "ima-adpcm", "ms-adpcm") — the name the `fmt=` marker reports.
func (w WavInfo) TagName() string {
	switch w.Tag {
	case FormatFloat:
		return "float" + itoa(uint64(w.Bits))
	case FormatIMA:
		return "ima-adpcm"
	case FormatMS:
		return "ms-adpcm"
	}
	return "pcm" + itoa(uint64(w.Bits))
}
