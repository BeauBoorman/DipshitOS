package webrender_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"virelai/css"
	"virelai/ttf"
	wr "virelai/webrender"
	"virelai/webstyle"
)

// qoiEncode builds a QOI in memory: header, one QOI_OP_RGB per pixel, then the
// 7-zero + 0x01 end marker. It is deliberately the simplest legal encoding, so
// the decoder meets a file it cannot have special-cased.
//
// This exists because the decoder shipped without it and the class-B gate found
// the hole instead: qoiHash dropped the format's `% 64`, so the first swatch
// colour indexed 1043 into a 64-entry table and panicked the guest
// (artifacts/live-web-ttf-serial-03.log: "index out of range [1043] with
// length 64"). The old tests only fed the decoder junk, which cannot catch a
// hash overrun.
func qoiEncode(w, h int, quads [][3]byte) []byte {
	var b bytes.Buffer
	b.WriteString("qoif")
	for _, v := range []int{w, h} {
		b.Write([]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)})
	}
	b.WriteByte(4) // channels
	b.WriteByte(0) // colorspace
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := quads[(y*2/h)*2+(x*2/w)]
			b.Write([]byte{0xfe, c[0], c[1], c[2]})
		}
	}
	b.Write([]byte{0, 0, 0, 0, 0, 0, 0, 1})
	return b.Bytes()
}

// TestDecodeQOIRoundTrip decodes a real QOI and checks exact pixels, so the
// header, the opcode loop, the index table and the end marker are all
// exercised on real data.
func TestDecodeQOIRoundTrip(t *testing.T) {
	quads := [][3]byte{
		{0x11, 0x7f, 0x33}, {0xd0, 0x33, 0x99},
		{0x22, 0x66, 0xdd}, {0xee, 0xcc, 0x00},
	}
	const w, h = 16, 16
	img, err := wr.DecodeImage(qoiEncode(w, h, quads))
	if err != nil {
		t.Fatalf("DecodeImage(qoi): %v", err)
	}
	if img.Width != w || img.Height != h {
		t.Fatalf("decoded %dx%d, want %dx%d", img.Width, img.Height, w, h)
	}
	spots := []struct{ x, y, q int }{{3, 3, 0}, {11, 3, 1}, {3, 11, 2}, {11, 11, 3}}
	for _, s := range spots {
		want := uint32(0xff000000) | uint32(quads[s.q][0])<<16 |
			uint32(quads[s.q][1])<<8 | uint32(quads[s.q][2])
		if got := img.At(s.x, s.y); got != want {
			t.Errorf("pixel (%d,%d) = %#08x, want %#08x", s.x, s.y, got, want)
		}
	}
	t.Logf("qoi round-trip ok: %dx%d, four exact quadrant colours", img.Width, img.Height)
}

// TestQOIOpcodesAgainstAHandBuiltStream covers all four opcode families plus
// the index cache, so a decoder that only ever saw QOI_OP_RGB cannot pass.
func TestQOIOpcodesAgainstAHandBuiltStream(t *testing.T) {
	var b bytes.Buffer
	b.WriteString("qoif")
	b.Write([]byte{0, 0, 0, 4, 0, 0, 0, 1}) // width 4, height 1
	b.WriteByte(4)                          // channels
	b.WriteByte(0)                          // colorspace
	// QOI_OP_RGB: red (255,0,0)
	b.Write([]byte{0xfe, 0xff, 0x00, 0x00})
	// QOI_OP_DIFF from red: dr=-1 dg=+1 db=0 => (254,1,0)
	b.WriteByte(byte(0x40 | (1 << 4) | (3 << 2) | 2))
	// QOI_OP_LUMA: vg=0, dr_dg=+1, db_dg=-1 => (255,1,0)
	b.WriteByte(byte(0x80 | 32))
	b.WriteByte(byte((1+8)<<4 | (-1 + 8)))
	// QOI_OP_INDEX: back to the cached red
	b.WriteByte(61) // (255*3 + 0*5 + 0*7) mod 64, independently derived
	b.Write([]byte{0, 0, 0, 0, 0, 0, 0, 1})

	img, err := wr.DecodeImage(b.Bytes())
	if err != nil {
		t.Fatalf("DecodeImage: %v", err)
	}
	if img.Width != 4 || img.Height != 1 {
		t.Fatalf("decoded %dx%d, want 4x1", img.Width, img.Height)
	}
	t.Logf("opcode stream decoded: %#08x %#08x %#08x %#08x",
		img.At(0, 0), img.At(1, 0), img.At(2, 0), img.At(3, 0))
	for i, want := range []uint32{0xffff0000, 0xfffe0100, 0xffff0100, 0xffff0000} {
		if got := img.At(i, 0); got != want {
			t.Errorf("pixel %d = %#08x, want %#08x", i, got, want)
		}
	}
	if img.At(3, 0) != img.At(0, 0) {
		t.Errorf("QOI_OP_INDEX did not return the cached colour: %#08x vs %#08x",
			img.At(3, 0), img.At(0, 0))
	}
}

// TestDecodeQOIRespectsThePixelCap: a hostile header is refused, not allocated.
func TestDecodeQOIRespectsThePixelCap(t *testing.T) {
	var b bytes.Buffer
	b.WriteString("qoif")
	b.Write([]byte{0, 0, 0x40, 0, 0, 0, 0x40, 0}) // 16384 x 16384
	b.WriteByte(4)
	b.WriteByte(0)
	if img, err := wr.DecodeImage(b.Bytes()); err == nil {
		t.Errorf("a 16384x16384 qoi decoded to %dx%d", img.Width, img.Height)
	}
}

type referenceFrame struct {
	w, h int
	pix  []uint32
}

func frame(w, h int, bg uint32) *referenceFrame {
	f := &referenceFrame{w: w, h: h, pix: make([]uint32, w*h)}
	for i := range f.pix {
		f.pix[i] = bg
	}
	return f
}

func (f *referenceFrame) Fill(x, y, w, h int, rgb uint32) {
	for yy := max(0, y); yy < min(f.h, y+h); yy++ {
		for xx := max(0, x); xx < min(f.w, x+w); xx++ {
			f.pix[yy*f.w+xx] = rgb & 0xffffff
		}
	}
}

func (f *referenceFrame) BlitMask(x, y int, m *ttf.Mask, rgb uint32) {
	// The shared linear-light helper (M99o): the reference renderer blends
	// exactly what the guest blends.
	ttf.Blend(f.pix, f.w, f.w, f.h, x, y, m, rgb)
}

func (f *referenceFrame) rgbHash() string {
	data := make([]byte, len(f.pix)*3)
	for i, p := range f.pix {
		data[i*3], data[i*3+1], data[i*3+2] = byte(p>>16), byte(p>>8), byte(p)
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func sameFrame(a, b *referenceFrame) bool {
	return a.w == b.w && a.h == b.h && a.rgbHash() == b.rgbHash()
}

func (f *referenceFrame) pngBytes(t *testing.T) []byte {
	t.Helper()
	im := image.NewNRGBA(image.Rect(0, 0, f.w, f.h))
	for i, p := range f.pix {
		im.Pix[i*4], im.Pix[i*4+1], im.Pix[i*4+2], im.Pix[i*4+3] = byte(p>>16), byte(p>>8), byte(p), 255
	}
	var out bytes.Buffer
	if err := png.Encode(&out, im); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func sampleFrame(src *referenceFrame, w, h int) *referenceFrame {
	dst := frame(w, h, 0)
	for y := 0; y < h; y++ {
		sy := (2*y + 1) * src.h / (2 * h)
		for x := 0; x < w; x++ {
			sx := (2*x + 1) * src.w / (2 * w)
			dst.pix[y*w+x] = src.pix[sy*src.w+sx]
		}
	}
	return dst
}

func referenceFonts(t *testing.T) (wr.Fonts, map[string]string) {
	t.Helper()
	names := []string{"Inter-Regular.ttf", "Inter-Bold.ttf", "Inter-Italic.ttf", "Inter-BoldItalic.ttf", "FiraCode-Regular.ttf", "NotoSerif-Regular.ttf"}
	data, hashes := make([][]byte, 6), make(map[string]string)
	for i, name := range names {
		b, err := os.ReadFile(filepath.Join("../../../image/fonts", name))
		if err != nil {
			t.Fatal(err)
		}
		data[i] = b
		sum := sha256.Sum256(b)
		hashes[name] = hex.EncodeToString(sum[:])
	}
	fonts := wr.LoadFonts(wr.FontFiles{UI: data[0], Bold: data[1], Italic: data[2], BoldItalic: data[3], Mono: data[4], Serif: data[5]})
	if fonts.UI == nil || fonts.Bold == nil || fonts.Italic == nil || fonts.BoldItalic == nil || fonts.Mono == nil || fonts.Serif == nil {
		t.Fatal("reference font did not load")
	}
	return fonts, hashes
}

func cssLayout(t *testing.T, html []byte, width int, fonts wr.TextEngine, images ...wr.ImageResolver) *wr.Layout {
	t.Helper()
	doc := wr.ParseHTML(html)
	if doc.Truncated {
		t.Fatal("small reference HTML truncated")
	}
	var sheets []*css.Stylesheet
	var collect func(*wr.Node)
	collect = func(n *wr.Node) {
		if n.Tag == "style" {
			var raw strings.Builder
			for _, child := range n.Children {
				if child.Kind == wr.KindText {
					raw.WriteString(child.Text)
				}
			}
			sheet, _ := css.Parse([]byte(raw.String()))
			sheets = append(sheets, sheet)
		}
		for _, child := range n.Children {
			collect(child)
		}
	}
	collect(doc.Root)
	styles, _ := css.Cascade(doc, sheets)
	tree, ds := wr.BuildBoxTree(doc, styles.ForNode)
	if len(ds) != 0 {
		t.Fatal(ds)
	}
	l, ds := wr.LayoutBoxes(tree, webstyle.Viewport{Width: width, Height: 720}, fonts, images...)
	for _, d := range ds {
		if d.Kind == webstyle.DiagnosticLimit || d.Kind == webstyle.DiagnosticInvalid {
			t.Fatal(d)
		}
	}
	return l
}

func TestSVGImagesAndRefusals(t *testing.T) {
	cases := []struct {
		name, source, reason string
	}{
		{"fill", `<svg width="8" height="4"><rect width="8" height="4" fill="#117f33"/></svg>`, ""},
		{"bom", "\xef\xbb\xbf" + `<svg width="8" height="4"><rect width="8" height="4" fill="#117f33"/></svg>`, ""},
		{"text", `<svg width="8" height="4"><text>no</text></svg>`, "image-svg-unsupported-text"},
		{"stroke", `<svg width="8" height="4"><rect width="8" height="4" stroke="red"/></svg>`, "image-svg-unsupported-feature"},
		{"resource", `<svg width="8" height="4"><image href="file.png"/></svg>`, "image-svg-external-resource"},
		{"style", `<svg width="8" height="4" style="fill:red"></svg>`, "image-svg-unsupported-feature"},
		{"jpeg", "\xff\xd8\xff\xe0not decoded", "image-invalid: jpeg"},
		{"gif", "GIF89a\x08\x00\x08\x00\x00\x00\x00not decoded", "image-invalid: gif"},
	}
	fonts, _ := referenceFonts(t)
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			im, err := wr.DecodeImage([]byte(tc.source))
			if tc.reason == "" {
				if err != nil || im == nil || im.At(3, 2) != 0xff117f33 {
					t.Fatalf("SVG fill: image=%v err=%v", im, err)
				}
			} else if err == nil || err.Error() != tc.reason || im != nil {
				t.Fatalf("refusal=%v image=%v, want %s", err, im, tc.reason)
			}
			l := cssLayout(t, []byte(`<img src="image" width="160" height="48" alt="Original alt text wraps inside its content box">`),
				300, fonts, func(string) ([]byte, bool) { return []byte(tc.source), true })
			f := frame(300, 100, wr.ColorPageBg)
			wr.Paint(l, f, 0, 0, 300, 100, 0)
			var item *wr.Item
			for i := range l.Items {
				if l.Items[i].Kind == wr.ItemImage {
					item = &l.Items[i]
				}
			}
			if item == nil || (item.Img == nil) != (tc.reason != "") {
				t.Fatal("image/placeholder layout path not preserved")
			}
			if tc.reason != "" {
				if item.Text != "Original alt text wraps inside its content box" {
					t.Fatal("original alt text lost")
				}
				if f.pix[item.Y*f.w+item.X] != 0x808080 {
					t.Fatal("placeholder outline missing")
				}
				ink := 0
				for y := item.Y + 4; y < min(f.h, item.Y+item.H-4); y++ {
					for x := item.X + 4; x < min(f.w, item.X+item.W-4); x++ {
						if f.pix[y*f.w+x] != wr.ColorPageBg {
							ink++
						}
					}
				}
				if ink < 20 {
					t.Fatal("placeholder alt text painted nothing")
				}
			}
		})
	}
}

func TestWrappedCSSLinkHitsPaintedRuns(t *testing.T) {
	fonts, _ := referenceFonts(t)
	l := cssLayout(t, []byte(`<style>a{color:#aa2200;font-size:21px}</style><p><a href="NEXT.HTML">alpha beta gamma delta epsilon zeta</a></p>`), 130, fonts)
	lines := make(map[int]bool)
	for _, it := range l.Items {
		if it.Kind != wr.ItemText || it.Target == "" {
			continue
		}
		lines[it.Y] = true
		if it.Color != 0xaa2200 || it.FontPx != 21 {
			t.Fatal("cascade link styling lost")
		}
		if wr.HitTest(l, it.X+it.W/2, it.Y+it.H/2) != "NEXT.HTML" {
			t.Fatal("painted wrapped text run has no hit region")
		}
	}
	if len(lines) < 3 || wr.HitTest(l, -1, -1) != "" {
		t.Fatal("wrapped link/hit-test behavior not covered")
	}
}

type referenceHash struct {
	Native, Presentation                             string
	NativeWidth, NativeHeight, Width, Height, Scroll int
}

type referenceManifest struct {
	Version  int
	Fonts    map[string]string
	Images   map[string]referenceHash
	Verdicts map[string]string
}

func TestM93ReferenceRenders(t *testing.T) {
	stage := os.Getenv("WEBRENDER_STAGE_REFERENCES")
	pinnedPath := filepath.Join("testdata", "golden", "m93-reference.json")
	var pinned referenceManifest
	if data, err := os.ReadFile(pinnedPath); err == nil {
		if err := json.Unmarshal(data, &pinned); err != nil {
			t.Fatal(err)
		}
	} else if stage == "" {
		t.Fatal("owner-approved M93 native/presentation manifest is missing")
	}
	fonts, hashes := referenceFonts(t)
	candidate := referenceManifest{Version: 1, Fonts: hashes, Images: make(map[string]referenceHash), Verdicts: make(map[string]string)}
	paths, err := filepath.Glob("../../../tests/fixtures/web/reference/*.html")
	if err != nil || len(paths) != 17 {
		t.Fatalf("reference inventory: %d, error=%v", len(paths), err)
	}
	contact := frame(512*3, (288+24)*((len(paths)+2)/3), 0xffffff)
	for index, path := range paths {
		name := strings.TrimSuffix(filepath.Base(path), ".html")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		start := time.Now()
		l := cssLayout(t, data, 1280, fonts)
		f := frame(1280, 720, wr.ColorPageBg)
		wr.Paint(l, f, 0, 0, 1280, 720, 0)
		elapsed := time.Since(start)
		if elapsed > webstyle.MaxRenderMilliseconds*time.Millisecond {
			t.Fatalf("%s render budget: %v", name, elapsed)
		}
		presentation := sampleFrame(f, 512, 288)
		record := referenceHash{Native: f.rgbHash(), Presentation: presentation.rgbHash(),
			NativeWidth: 1280, NativeHeight: 720, Width: 512, Height: 288, Scroll: 0}
		candidate.Images[name] = record
		t.Logf("%s native=%s presentation=%s render=%v", name, record.Native, record.Presentation, elapsed)
		if stage == "" {
			checkReferencePNG(t, name+"-native", f)
			checkReferencePNG(t, name+"-presentation", presentation)
			if pinned.Version != 1 || pinned.Images[name] != record || pinned.Verdicts[name] == "" {
				t.Fatalf("%s exact reference manifest mismatch or missing owner verdict", name)
			}
			continue
		}
		if err := os.MkdirAll(stage, 0o755); err != nil {
			t.Fatal(err)
		}
		for suffix, raster := range map[string]*referenceFrame{"native": f, "presentation": presentation} {
			pngData := raster.pngBytes(t)
			if len(pngData) > 4_194_304 {
				t.Fatalf("%s %s PNG exceeds artifact cap", name, suffix)
			}
			if err := os.WriteFile(filepath.Join(stage, name+"-"+suffix+".png"), pngData, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		tx, ty := index%3*512, index/3*(288+24)
		for y := 0; y < 288; y++ {
			copy(contact.pix[(ty+24+y)*contact.w+tx:(ty+24+y)*contact.w+tx+512], presentation.pix[y*512:(y+1)*512])
		}
		fonts.Paint(contact, tx+8, ty+2, name, wr.Style{FontPx: 13}, 0x000000, wr.Clip{W: contact.w, H: contact.h})
	}
	if stage == "" {
		for name, hash := range hashes {
			if pinned.Fonts[name] != hash {
				t.Fatalf("font hash mismatch: %s", name)
			}
		}
		return
	}
	manifest, err := json.MarshalIndent(candidate, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "candidate-manifest.json"), manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "contact-sheet.png"), contact.pngBytes(t), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Log("candidate set staged only; no owner verdict or golden approval inferred")
}

func readReferencePNG(t *testing.T, data []byte) *referenceFrame {
	t.Helper()
	im, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	b := im.Bounds()
	f := frame(b.Dx(), b.Dy(), 0)
	for y := 0; y < f.h; y++ {
		for x := 0; x < f.w; x++ {
			r, g, bl, a := im.At(b.Min.X+x, b.Min.Y+y).RGBA()
			if a != 65535 {
				t.Fatal("reference frame PNG must be opaque")
			}
			f.pix[y*f.w+x] = (r>>8)<<16 | (g>>8)<<8 | bl>>8
		}
	}
	return f
}

func checkReferencePNG(t *testing.T, name string, actual *referenceFrame) {
	t.Helper()
	path := filepath.Join("testdata", "golden", "m93-"+name+".png")
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		if len(actual.pngBytes(t)) <= webstyle.MaxCommittedGoldenBytes {
			t.Fatalf("small owner-approved reference PNG is missing: %s", path)
		}
		return // larger-than-64-KiB references pin their RGB manifest hash only
	}
	if err != nil {
		t.Fatal(err)
	}
	if len(data) > webstyle.MaxCommittedGoldenBytes {
		t.Fatal("committed reference PNG exceeds its size cap")
	}
	want := readReferencePNG(t, data)
	if sameFrame(actual, want) {
		return
	}
	dir := "../../../artifacts/m93e/diffs"
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	diff := frame(actual.w, actual.h, 0)
	mismatched := 0
	for y := 0; y < actual.h; y++ {
		for x := 0; x < actual.w; x++ {
			i := y*actual.w + x
			// Mask the alpha byte: the shared blend writes opaque 0xFF
			// words while PNG-decoded goldens decode as 0x00RRGGBB — the
			// comparison (like rgbHash) is on RGB alone.
			if x >= want.w || y >= want.h ||
				actual.pix[i]&0xffffff != want.pix[y*want.w+x]&0xffffff {
				diff.pix[i] = 0xff0000
				mismatched++
			}
		}
	}
	for suffix, f := range map[string]*referenceFrame{"actual": actual, "diff": diff} {
		if err := os.WriteFile(filepath.Join(dir, name+"-"+suffix+".png"), f.pngBytes(t), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Fatalf("%s exact PNG mismatch: dimensions actual=%dx%d wanted=%dx%d, mismatched pixels=%d",
		name, actual.w, actual.h, want.w, want.h, mismatched)
}

func TestReferenceComparatorAndSampler(t *testing.T) {
	f := frame(1280, 720, 0x123456)
	if !sameFrame(sampleFrame(f, 1280, 720), f) {
		t.Fatal("identity sampling changed RGB bytes")
	}
	one := frame(1280, 720, 0x123456)
	one.pix[0] ^= 1
	wrongSize := &referenceFrame{w: 720, h: 1280, pix: f.pix}
	if sameFrame(one, f) || sameFrame(wrongSize, f) {
		t.Fatal("one-pixel or wrong-size comparison is ineffective")
	}
	for x := range f.pix {
		f.pix[x] = uint32(x) & 0xffffff
	}
	shifted := frame(1280, 720, 0)
	for y := 0; y < 720; y++ {
		copy(shifted.pix[y*1280:(y+1)*1280-1], f.pix[y*1280+1:(y+1)*1280])
	}
	if sameFrame(shifted, f) {
		t.Fatal("one-pixel crop shift not detected")
	}
	p := sampleFrame(f, 512, 288)
	for y := 0; y < 288; y++ {
		for x := 0; x < 512; x++ {
			sx, sy := (2*x+1)*1280/1024, (2*y+1)*720/576
			if p.pix[y*512+x] != f.pix[sy*1280+sx] {
				t.Fatal("pixel-center sampler changed")
			}
		}
	}
}
