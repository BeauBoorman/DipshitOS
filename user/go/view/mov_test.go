package main

// mov_test.go is the demux's class-A evidence: the committed fixture
// parses, its ten samples decode through our own JPEG decoder to pinned
// sums, the duration arithmetic is pinned, and every bound and lie the
// walker must refuse is refused BY NAME.
//
// The fixture itself is generated, never downloaded: GOVIEW_WRITE_FIXTURE=1
// runs TestWriteMOVFixture, which encodes ten frames through the host's
// image/jpeg (BSD-3-Clause, encoder only — see testdata/SOURCES.txt) and
// wraps them in the same moov/mdat box structure the demux reads. The
// normal tests read the committed bytes and never regenerate, because
// image/jpeg's output may drift across Go releases.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"image"
	"image/jpeg"
	"os"
	"testing"

	"virelai/webrender"
)

const movFixture = "testdata/clip_160x120.mov"

// movFrameSums pins the FNV-1a-64 of each fixture frame as OUR decoder
// renders it — the same sums the live gate's run 02 asserts in the
// `gview: frame i/10` receipts (host and guest run the same decoder).
var movFrameSums = [10]uint64{
	0x841b31cc2db2c534, 0xf535f76c11a59fbc, 0xef521a8d3b1da9d4, 0x48d4cb3ca3e0ff48, 0xb822f8b9894c4bb5,
	0x1b34553fbeb17b7d, 0x1006bb4d92747eb1, 0x46ea77e6477c25d8, 0x4977773abca0c53c, 0xd86a2ac898451c12,
}

// ---------------------------------------------------------------------------
// Fixture generator (env-gated — see the header note and SOURCES.txt)
// ---------------------------------------------------------------------------

// movPalette is the band's 16 colours: distinct hues so a JPEG-decoded
// band stays a band, and a one-step slide keeps every frame's sum
// distinct — the same "moving band" idea play10_160x120.gif carries.
var movPalette = [16][3]byte{
	{0xd4, 0x20, 0x20}, {0xe0, 0x68, 0x18}, {0xe8, 0xa8, 0x18}, {0xc8, 0xc8, 0x20},
	{0x80, 0xd0, 0x28}, {0x28, 0xc8, 0x40}, {0x18, 0xd0, 0x90}, {0x18, 0xc8, 0xc8},
	{0x20, 0x90, 0xd8}, {0x28, 0x50, 0xe0}, {0x50, 0x30, 0xd8}, {0x90, 0x28, 0xd0},
	{0xd0, 0x28, 0xa0}, {0xd8, 0x28, 0x58}, {0xb0, 0x60, 0x30}, {0xf0, 0xf0, 0xf0},
}

// movGenFrame draws frame i: a diagonal 16-colour band (8 px stripes
// along x+y) slid i steps — the same one-step slide the GIF fixture
// plays, so the MOV leg's moving picture is the familiar shape.
func movGenFrame(i int) *image.RGBA {
	const w, h = 160, 120
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := movPalette[((x+y)/8+i)%16]
			o := img.PixOffset(x, y)
			img.Pix[o+0], img.Pix[o+1], img.Pix[o+2], img.Pix[o+3] = c[0], c[1], c[2], 0xff
		}
	}
	return img
}

// TestWriteMOVFixture regenerates testdata/clip_160x120.mov: ten 160x120
// `jpeg` samples at 100 ms each (media timescale 1000), quality 75, in a
// moov-then-mdat QuickTime file carrying the `qt  ` brand. Skipped
// unless GOVIEW_WRITE_FIXTURE=1 — the gate and the class-A tests consume
// the committed bytes.
func TestWriteMOVFixture(t *testing.T) {
	if os.Getenv("GOVIEW_WRITE_FIXTURE") == "" {
		t.Skip("fixture generation is env-gated (GOVIEW_WRITE_FIXTURE=1)")
	}
	var samples [][]byte
	for i := 0; i < 10; i++ {
		var buf bytes.Buffer
		if err := jpeg.Encode(&buf, movGenFrame(i), &jpeg.Options{Quality: 75}); err != nil {
			t.Fatalf("jpeg encode frame %d: %v", i, err)
		}
		samples = append(samples, buf.Bytes())
	}
	mov := movBuild(samples, 160, 120, 1000, 100, "jpeg")
	if err := os.WriteFile(movFixture, mov, 0o644); err != nil {
		t.Fatal(err)
	}
	// The generator's contract is the demux's: the bytes just written
	// must parse back through the same walker.
	v, err := demuxMOV(mov)
	if err != nil {
		t.Fatalf("generated fixture fails its own demux: %v", err)
	}
	if len(v.samples) != 10 || v.timescale != 1000 || v.codec != "jpeg" {
		t.Fatalf("generated demux = %d samples ts=%d codec=%s", len(v.samples), v.timescale, v.codec)
	}
	t.Logf("wrote %s: %d bytes, %d samples", movFixture, len(mov), len(v.samples))
}

// ---------------------------------------------------------------------------
// Host-side MOV writer — the generator's encoder and the hostile tests'
// honest file to mutate. Emits ftyp + moov + mdat, moov first so the
// header sniff finds tkhd inside readHead's 4 KiB.
// ---------------------------------------------------------------------------

func movBox(typ string, payload []byte) []byte {
	b := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint32(b[0:4], uint32(len(b)))
	copy(b[4:8], typ)
	copy(b[8:], payload)
	return b
}

func movBox64(typ string, payload []byte) []byte {
	b := make([]byte, 16+len(payload))
	binary.BigEndian.PutUint32(b[0:4], 1)
	copy(b[4:8], typ)
	binary.BigEndian.PutUint64(b[8:16], uint64(len(b)))
	copy(b[16:], payload)
	return b
}

func u32f(v uint32) []byte {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	return b[:]
}

func u16f(v uint16) []byte {
	var b [2]byte
	binary.BigEndian.PutUint16(b[:], v)
	return b[:]
}

func movCat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// movVisualEntry builds an 86-byte visual sample entry for the given
// codec fourcc — `jpeg` for the fixture, anything else for the codec
// refusal tests.
func movVisualEntry(codec string, w, h uint32) []byte {
	var e []byte
	e = append(e, make([]byte, 6)...)      // reserved
	e = append(e, u16f(1)...)              // data_reference_index
	e = append(e, make([]byte, 16)...)     // version/revision/vendor/quality
	e = append(e, u16f(uint16(w))...)      // width
	e = append(e, u16f(uint16(h))...)      // height
	e = append(e, u32f(0x00480000)...)     // hres 72dpi
	e = append(e, u32f(0x00480000)...)     // vres
	e = append(e, u32f(0)...)              // reserved
	e = append(e, u16f(1)...)              // frame_count
	e = append(e, make([]byte, 32)...)     // compressorname (pascal, empty)
	e = append(e, u16f(24)...)             // depth
	e = append(e, u16f(0xffff)...)         // pre_defined
	if len(e) != 78 {
		panic("visual entry size drift")
	}
	return movBox(codec, e)
}

// movBuild renders a complete MOV: ftyp (qt brand), moov (mvhd + one
// vide trak), mdat holding the samples back to back. timescale/dur are
// the mdhd timescale and each sample's stts delta. Extra traks may be
// appended through extra (already-boxed), e.g. a soun track.
func movBuild(samples [][]byte, w, h, timescale, dur uint32, codec string, extra ...[]byte) []byte {
	ftyp := movBox("ftyp", append(append([]byte("qt  "), u32f(0x200)...), []byte("qt  ")...))

	mvhd := movBox("mvhd", func() []byte {
		var b []byte
		b = append(b, u32f(0)...) // version+flags
		b = append(b, movCat(u32f(0), u32f(0))...) // creation/modification
		b = append(b, u32f(timescale)...)
		b = append(b, u32f(uint32(len(samples))*dur)...)
		b = append(b, u32f(0x00010000)...) // rate 1.0
		b = append(b, u16f(0x0100)...)     // volume 1.0
		b = append(b, make([]byte, 10)...)
		b = append(b, movUnityMatrix()...)
		b = append(b, make([]byte, 24)...)
		b = append(b, u32f(2)...) // next_track_id
		return b
	}())

	tkhd := movBox("tkhd", func() []byte {
		var b []byte
		b = append(b, u32f(0x000007)...) // enabled | in_movie | in_preview
		b = append(b, movCat(u32f(0), u32f(0))...) // creation/modification
		b = append(b, u32f(1)...) // track_id
		b = append(b, u32f(0)...)
		b = append(b, u32f(uint32(len(samples))*dur)...)
		b = append(b, make([]byte, 8)...)
		b = append(b, movCat(u16f(0), u16f(0), u16f(0), u16f(0))...) // layer/alt/volume/reserved
		b = append(b, movUnityMatrix()...)
		b = append(b, u32f(w<<16)...)
		b = append(b, u32f(h<<16)...)
		return b
	}())

	mdhd := movBox("mdhd", func() []byte {
		var b []byte
		b = append(b, u32f(0)...)
		b = append(b, movCat(u32f(0), u32f(0))...)
		b = append(b, u32f(timescale)...)
		b = append(b, u32f(uint32(len(samples))*dur)...)
		b = append(b, u16f(0x55c4)...) // und language
		b = append(b, u16f(0)...)
		return b
	}())

	hdlr := movBox("hdlr", func() []byte {
		var b []byte
		b = append(b, u32f(0)...)   // version+flags
		b = append(b, u32f(0)...)   // pre_defined
		b = append(b, "vide"...)    // handler_type
		b = append(b, make([]byte, 12)...)
		return b
	}())

	vmhd := movBox("vmhd", movCat(u32f(0x000001), u16f(0), u16f(0), u16f(0), u16f(0)))
	dref := movBox("dref", movCat(u32f(0), u32f(1), movBox("url ", u32f(0x000001))))
	dinf := movBox("dinf", dref)

	stsd := movBox("stsd", movCat(u32f(0), u32f(1), movVisualEntry(codec, w, h)))

	stts := movBox("stts", movCat(u32f(0), u32f(1),
		u32f(uint32(len(samples))), u32f(dur)))

	stsc := movBox("stsc", movCat(u32f(0), u32f(1),
		u32f(1), u32f(uint32(len(samples))), u32f(1)))

	var stszBody []byte
	stszBody = append(stszBody, movCat(u32f(0), u32f(0), u32f(uint32(len(samples))))...)
	for _, s := range samples {
		stszBody = append(stszBody, u32f(uint32(len(s)))...)
	}
	stsz := movBox("stsz", stszBody)

	// stco is patched after moov is laid out: the samples live in mdat,
	// which follows moov, and moov's size does not depend on the value.
	stco := movBox("stco", movCat(u32f(0), u32f(1), u32f(0)))

	stbl := movBox("stbl", bytes.Join([][]byte{stsd, stts, stsc, stsz, stco}, nil))
	minf := movBox("minf", bytes.Join([][]byte{vmhd, dinf, stbl}, nil))
	mdia := movBox("mdia", bytes.Join([][]byte{mdhd, hdlr, minf}, nil))
	trak := movBox("trak", bytes.Join([][]byte{tkhd, mdia}, nil))

	moovChildren := [][]byte{mvhd, trak}
	moovChildren = append(moovChildren, extra...)
	moov := movBox("moov", bytes.Join(moovChildren, nil))

	// Patch the single stco entry: mdat's samples start right after its
	// 8-byte header, at len(ftyp)+len(moov)+8.
	mdatOff := uint32(len(ftyp) + len(moov) + 8)
	i := bytes.Index(moov, []byte("stco"))
	binary.BigEndian.PutUint32(moov[i+12:i+16], mdatOff)

	var mdat []byte
	for _, s := range samples {
		mdat = append(mdat, s...)
	}
	return bytes.Join([][]byte{ftyp, moov, movBox("mdat", mdat)}, nil)
}

func movUnityMatrix() []byte {
	return movCat(u32f(0x00010000), u32f(0), u32f(0),
		u32f(0), u32f(0x00010000), u32f(0),
		u32f(0), u32f(0), u32f(0x40000000))
}

// ---------------------------------------------------------------------------
// The committed fixture
// ---------------------------------------------------------------------------

// TestDemuxParsesTheFixture is the walker's happy path: ten `jpeg`
// samples at 100 ms on a 1000 Hz timescale, one vide track, qt brand.
func TestDemuxParsesTheFixture(t *testing.T) {
	data := readFixture(t, movFixture)
	if formatOfHeader(data) != fmtMOV {
		t.Fatal("fixture did not sniff as fmtMOV")
	}
	v, err := demuxMOV(data)
	if err != nil {
		t.Fatalf("demuxMOV: %v", err)
	}
	if len(v.samples) != 10 || v.timescale != 1000 || v.codec != "jpeg" {
		t.Fatalf("demux = %d samples ts=%d codec=%s, want 10/1000/jpeg",
			len(v.samples), v.timescale, v.codec)
	}
	if v.brand != "qt  " || v.w != 160 || v.h != 120 {
		t.Fatalf("demux = brand %q %dx%d, want qt/160x120", v.brand, v.w, v.h)
	}
	for i, s := range v.samples {
		if s.dur != 100 {
			t.Fatalf("sample %d dur = %d, want 100 (100ms)", i, s.dur)
		}
		if s.size > movSampleBytes || s.off+uint64(s.size) > uint64(len(data)) {
			t.Fatalf("sample %d escapes the file", i)
		}
	}
}

// TestMOVFixturePinsFrameSums decodes every sample through our own
// decoder and pins the FNV-1a of each frame — the numbers the live
// gate's run 02 asserts in the stepper receipts. decodeForView routes
// the file through the demux and the frame source lazily decodes.
func TestMOVFixturePinsFrameSums(t *testing.T) {
	data := readFixture(t, movFixture)
	im, src, err := decodeForView(data)
	if err != nil {
		t.Fatalf("decodeForView: %v", err)
	}
	if src == nil || len(src.frames) != 10 || src.video == nil {
		t.Fatalf("src = %v, want a 10-frame video source", src)
	}
	if im.Width != 160 || im.Height != 120 || im.Frames != 10 {
		t.Fatalf("shown = %dx%d frames=%d, want 160x120 x10", im.Width, im.Height, im.Frames)
	}
	sums := map[uint64]int{}
	for i := range src.frames {
		if src.frames[i].delayNs != 100_000_000 || src.frames[i].delayMs != 100 {
			t.Fatalf("frame %d dwell = %d ns/%d ms, want 100ms", i+1, src.frames[i].delayNs, src.frames[i].delayMs)
		}
		got := frameSum(src.pix(i))
		sums[got] = i
		if got != movFrameSums[i] {
			t.Fatalf("frame %d sum = %016x, want pinned %016x", i+1, got, movFrameSums[i])
		}
	}
	if len(sums) != 10 {
		t.Fatal("clip_160x120 must decode to ten distinct frames")
	}
}

// ---------------------------------------------------------------------------
// The named refusals
// ---------------------------------------------------------------------------

// TestDemuxRefusalsByName walks the card's hostile list: each corruption
// of an honest file — or a hostile table — must be refused by its
// refusal's NAME, never by panic, partial parse or silent clamp.
func TestDemuxRefusalsByName(t *testing.T) {
	good := movBuild([][]byte{[]byte("frame-one"), []byte("frame-two")}, 160, 120, 1000, 100, "jpeg")

	// deep nests moov inside moov so the innermost leaf sits at depth.
	deep := []byte("leaf")
	for i := 0; i < 9; i++ {
		deep = movBox("moov", deep)
	}

	// many tops the file up past the 1024-box budget with zero-payload
	// `free` boxes before the moov — the walk refuses the 1025th read.
	var many []byte
	for i := 0; i < 1025; i++ {
		many = append(many, movBox("free", nil)...)
	}
	many = append(many, movBox("ftyp", append(append([]byte("qt  "), u32f(0x200)...), []byte("qt  ")...))...)
	many = append(many, movBox("moov", nil)...)

	// patch rewrites the first size field of the box whose fourcc sits
	// at pos (the box starts at pos-4).
	patch := func(b []byte, pos int, size uint32) []byte {
		c := append([]byte(nil), b...)
		binary.BigEndian.PutUint32(c[pos-4:], size)
		return c
	}
	stsdAt := bytes.Index(good, []byte("stsd"))
	if stsdAt < 0 {
		t.Fatal("baseline fixture lost its stsd")
	}

	cases := []struct {
		name string
		data []byte
		want error
	}{
		{"truncated header", good[:5], errMOVInvalid},
		{"truncated box", patch(good, 4, uint32(len(good)+64)), errMOVInvalid},
		{"size overflow", patch(good, 4, 0x7fffffff), errMOVInvalid},
		{"depth 9", append(movBox("ftyp", append(append([]byte("qt  "), u32f(0x200)...), []byte("qt  ")...)), deep...), errMOVLimit},
		{"1025 boxes", many, errMOVLimit},
		{"moof", append(append([]byte(nil), movBox("ftyp", append(append([]byte("qt  "), u32f(0x200)...), []byte("qt  ")...))...), movBox("moof", nil)...), errMOVFragmented},
		{"nested size-0", movBox("moov", append(movBox("trak", nil), func() []byte {
			b := movBox("mdia", nil)
			binary.BigEndian.PutUint32(b[:4], 0)
			return b
		}()...)), errMOVInvalid},
	}
	for _, c := range cases {
		if _, err := demuxMOV(c.data); err != c.want {
			t.Errorf("%s: demuxMOV = %v, want %v", c.name, err, c.want)
		}
	}
}

// TestDemuxTableRefusals mutates the sample tables: the bounds and
// count-mismatch refusals live in resolve(), past the box walk.
func TestDemuxTableRefusals(t *testing.T) {
	mk := func(samples [][]byte) []byte {
		return movBuild(samples, 160, 120, 1000, 100, "jpeg")
	}
	good := mk([][]byte{[]byte("s1"), []byte("s2")})

	setU32 := func(b []byte, at int, v uint32) []byte {
		c := append([]byte(nil), b...)
		binary.BigEndian.PutUint32(c[at:], v)
		return c
	}
	at := func(b []byte, fourcc string) int {
		i := bytes.Index(b, []byte(fourcc))
		if i < 0 {
			t.Fatalf("baseline lost %s", fourcc)
		}
		return i
	}

	// stsz declares 601 samples — the cap fires while the table parses.
	many := setU32(good, at(good, "stsz")+12, 601)

	// stsz count 1 vs stts sum 2 → the count mismatch refusal.
	mism := setU32(good, at(good, "stsz")+12, 1)

	// The single chunk's offset beyond the file end.
	far := setU32(good, at(good, "stco")+12, uint32(len(good)+4096))

	// Sample 2's size swells past the file end.
	big := setU32(good, at(good, "stsz")+16, uint32(len(good)))

	// mdhd timescale zeroed.
	zero := setU32(good, at(good, "mdhd")+16, 0)

	cases := []struct {
		name string
		data []byte
		want error
	}{
		{"601 samples", many, errMOVLimit},
		{"stsz/stts mismatch", mism, errMOVInvalid},
		{"chunk past EOF", far, errMOVLimit},
		{"sample past EOF", big, errMOVLimit},
		{"zero timescale", zero, errMOVInvalid},
	}
	for _, c := range cases {
		if _, err := demuxMOV(c.data); err != c.want {
			t.Errorf("%s: demuxMOV = %v, want %v", c.name, err, c.want)
		}
	}
}

// TestDemuxCodecRefusalNamesTheFourcc: a structurally honest file whose
// sample entry is not `jpeg` is refused AFTER the demux read it — the
// refusal carries the fourcc and rides ErrImageUnsupported, and the tag
// follows the container brand (MP4 for isom/mp4x, MOV otherwise).
func TestDemuxCodecRefusalNamesTheFourcc(t *testing.T) {
	data := movBuild([][]byte{[]byte("not-a-jpeg")}, 160, 120, 1000, 100, "avc1")
	_, err := demuxMOV(data)
	var mce movCodecError
	if !errors.As(err, &mce) {
		t.Fatalf("avc1 demux = %v, want a movCodecError", err)
	}
	if mce.fourcc != "avc1" || mce.tag != "MOV" {
		t.Fatalf("codec refusal = tag=%s fourcc=%s, want MOV/avc1", mce.tag, mce.fourcc)
	}
	if !errors.Is(err, webrender.ErrImageUnsupported) {
		t.Fatal("the codec refusal must satisfy errors.Is(ErrImageUnsupported)")
	}
	if err.Error() != "mov-unsupported-codec-avc1" {
		t.Fatalf("refusal named itself %q", err)
	}

	// An isom brand re-tags the same refusal MP4.
	isom := append([]byte(nil), data...)
	i := bytes.Index(isom, []byte("ftyp"))
	copy(isom[i+4:i+8], "isom")
	_, err = demuxMOV(isom)
	if mce2, ok := err.(movCodecError); !ok || mce2.tag != "MP4" {
		t.Fatalf("isom brand refusal = %v, want MP4 tag", err)
	}
}

// TestDemuxAudioTrackIsSkippedAndNamed: a soun track does not stop the
// vide track — the demux skips it and the load receipt names it
// audio=skipped through the frame source.
func TestDemuxAudioTrackIsSkippedAndNamed(t *testing.T) {
	soun := movBox("trak", movBox("mdia", bytes.Join([][]byte{
		movBox("hdlr", func() []byte {
			var b []byte
			b = append(b, u32f(0)...)
			b = append(b, u32f(0)...)
			b = append(b, "soun"...)
			b = append(b, make([]byte, 12)...)
			return b
		}()),
	}, nil)))
	v, err := demuxMOV(movBuild([][]byte{[]byte("s1")}, 160, 120, 1000, 100, "jpeg", soun))
	if err != nil {
		t.Fatalf("demuxMOV with a sound track: %v", err)
	}
	if !v.audioSkip {
		t.Fatal("the soun track was not recorded as skipped")
	}
	src := movSource(v)
	if !src.audioSkip {
		t.Fatal("the frame source must carry audio=skipped to the load receipt")
	}
}

// ---------------------------------------------------------------------------
// Durations and playback
// ---------------------------------------------------------------------------

// TestMovDelayNs pins duration × 10⁹ / timescale with its 1 ms floor:
// the fixture's 100/1000 → 100 ms, a sub-millisecond sample clamps up,
// and a zero-duration sample still lands a TIMER event.
func TestMovDelayNs(t *testing.T) {
	for _, c := range []struct {
		dur       uint64
		timescale uint32
		want      uint64
	}{
		{100, 1000, 100_000_000},
		{1, 1000, 1_000_000},
		{33, 1000, 33_000_000},
		{0, 1000, 1_000_000},
		{1, 1_000_000, 1_000_000},
		{100, 0, 1_000_000}, // unreachable — mdhd refuses a zero timescale — but the floor holds anyway
		{1500, 600, 2_500_000_000},
	} {
		if got := movDelayNs(c.dur, c.timescale); got != c.want {
			t.Errorf("movDelayNs(%d,%d) = %d, want %d", c.dur, c.timescale, got, c.want)
		}
	}
}

// TestMOVPlaybackTicksDriveTheSchedule is the frame-source playback
// check on the real fixture: the M170e machinery advances one sample per
// TIMER event, arms each sample's own duration, closes the loop on wrap
// and records the slowest sample decode on the injected clock — the same
// shape TestPlayTicksDriveTheDelaySchedule pins for GIF.
func TestMOVPlaybackTicksDriveTheSchedule(t *testing.T) {
	_, src, err := decodeForView(readFixture(t, movFixture))
	if err != nil {
		t.Fatal(err)
	}

	var arms []uint64
	var clock int64
	oldArm, oldCancel, oldNow := playArm, playCancel, playNow
	playArm = func(ns uint64) int64 { arms = append(arms, ns); return 0 }
	playCancel = func() int64 { return 1 }
	// Each playNow call adds 2 µs of fake wall time, so the lazy sample
	// decodes report a nonzero decode_us_max deterministically.
	playNow = func() int64 { clock += 2_000; return clock }
	defer func() { playArm, playCancel, playNow = oldArm, oldCancel, oldNow }()

	fire := func() { clock += int64(arms[len(arms)-1]) }

	a := &app{anim: src}
	if !a.togglePlay() || !a.playing {
		t.Fatal("togglePlay must start playback on the video source")
	}
	if len(arms) != 1 || arms[0] != 100_000_000 {
		t.Fatalf("first arm = %v, want [100ms]", arms)
	}
	// Nine TIMER events mid-loop: nine decodes each measured 2 µs on the
	// fake clock, so the loop's decode_us_max is already recorded.
	for i := 0; i < 9; i++ {
		fire()
		if !a.playTick() {
			t.Fatalf("tick %d did not advance", i+1)
		}
	}
	if a.anim.decMaxUs != 2 {
		t.Fatalf("decode_us_max = %d µs mid-loop, want 2 (the 2 µs fake-clock decode)", a.anim.decMaxUs)
	}
	// The tenth tick wraps the loop: the receipt prints decode_us_max
	// and the counter resets for the next loop.
	fire()
	if !a.playTick() || a.frame != 0 {
		t.Fatalf("tick 10 did not wrap: frame=%d", a.frame)
	}
	if a.anim.decMaxUs != 0 {
		t.Fatalf("decode_us_max = %d after the loop receipt, want reset", a.anim.decMaxUs)
	}
	if len(arms) != 11 {
		t.Fatalf("arms = %v, want one per frame plus the re-arm", arms)
	}
	for i, d := range arms {
		if d != 100_000_000 {
			t.Fatalf("arm %d = %d ns, want 100ms per sample", i, d)
		}
	}
	if a.playLastElapsed < 1_000_000_000 {
		t.Fatalf("loop elapsed = %d ns, want ≥1s of playing time", a.playLastElapsed)
	}
	// The stepper decodes on demand through the same path: stepping to
	// frame 2 shows sample 2's decode, pinned by the sum table.
	if !a.stepFrame(1) || a.frame != 1 {
		t.Fatal("stepping the video source did not land on frame 2")
	}
	if got := frameSum(a.img.Pix); got != movFrameSums[1] {
		t.Fatalf("frame 2 sum = %016x, want pinned %016x", got, movFrameSums[1])
	}
}

// TestMOVHeaderDimsFromFixture: the window sizing sniff finds the
// fixture's tkhd inside the 4 KiB head — a moov-first file sizes its own
// window at 160x120.
func TestMOVHeaderDimsFromFixture(t *testing.T) {
	data := readFixture(t, movFixture)
	if len(data) > headMax {
		data = data[:headMax]
	}
	iw, ih, ok := headerDims(data)
	if !ok || iw != 160 || ih != 120 {
		t.Fatalf("headerDims = %dx%d %v, want 160x120", iw, ih, ok)
	}
	if got := headerSize(data); got != (winSize{328, 264}) {
		t.Fatalf("headerSize = %+v, want 328x264", got)
	}
	// A head that ends before the moov yields no dims, not garbage.
	if _, _, ok := headerDims(data[:16]); ok {
		t.Fatal("a 16-byte head must not size the window")
	}
}
