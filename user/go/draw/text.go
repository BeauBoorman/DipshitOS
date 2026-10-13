package draw

import (
	"errors"

	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

var errFontFile = errors.New("draw: font file unavailable or too large")

// readShare reads up to maxBytes of a guest share file. The second return is
// false when the file is absent, unreadable, or over the cap — an over-cap
// file returns nil rather than a silently truncated prefix.
func readShare(path string, maxBytes int) ([]byte, bool) {
	if maxBytes <= 0 || maxBytes > 1024*1024 {
		return nil, false
	}
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc < 0 {
		return nil, false
	}
	defer vi.FileClose(uint32(h))
	out := make([]byte, 0, min(8192, maxBytes))
	buf := make([]byte, 4096)
	for {
		n, rr := vi.FileRead(uint32(h), buf)
		if rr < 0 || len(out)+n > maxBytes {
			return nil, false
		}
		if n == 0 {
			break
		}
		out = append(out, buf[:n]...)
	}
	return out, true
}

// ReadFont parses a guest share font for chrome labels or glyphs. Unlike
// vi.ReadFileAll it can read the 411 KiB Inter UI face (that helper caps at
// 256 KiB). The explicit bound also refuses a truncated font before Parse.
func ReadFont(path string, maxBytes int) (*ttf.Face, error) {
	data, ok := readShare(path, maxBytes)
	if !ok {
		return nil, errFontFile
	}
	return ttf.Parse(data)
}

// FontManifestPath is where tools/session.sh stages image/fonts/fonts.txt —
// the M99l font registry's only input. The 8.3 name shares the frozen M69d
// staging convention.
const FontManifestPath = "/host/FONTS.TXT"

// maxManifestBytes bounds the manifest read. apps.txt's readers buffer 4096
// (sexiburger.manifest_buf_max); the font manifest is the same shape and
// stays under the same bound.
const maxManifestBytes = 4096

// LoadRegistry reads the staged font manifest and returns the lazy registry
// over it, plus the marker payload the caller publishes on its `fonts:` line:
// "manifest=ok faces=N", "manifest=missing", or "manifest=malformed <err>".
// A nil registry means the caller keeps its hard-coded faces — the marker
// says why.
func LoadRegistry() (*ttf.Registry, string) {
	data, ok := readShare(FontManifestPath, maxManifestBytes)
	if !ok {
		// Absent and unreadable share the no-manifest path; the one case
		// that is NOT a missing manifest is a file too large to be a
		// manifest — that is a malformed one.
		if _, openErr := vi.FileOpen(FontManifestPath, vi.ModeRead); openErr >= 0 {
			vi.FileClose(uint32(openErr))
			return nil, "manifest=malformed over " + itoa(maxManifestBytes) + " bytes"
		}
		return nil, "manifest=missing"
	}
	specs, err := ttf.ParseManifest(data)
	if err != nil {
		return nil, "manifest=malformed " + err.Error()
	}
	reg := ttf.NewRegistry(specs, func(file string) (*ttf.Face, error) {
		return ReadFont("/host/"+file, 512*1024)
	})
	// The card's `fonts: notdef=N` marker: every rune that exhausted its
	// chain is counted on the serial line, same as the browser's wiring.
	reg.OnNotdef = func(n int) {
		vi.ConsoleLine("fonts: notdef=" + itoa(n))
	}
	return reg, "manifest=ok faces=" + itoa(len(specs))
}

// itoa formats a small non-negative integer; draw stays off strconv for the
// same footprint reason as virelai/ttf.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// TextChain draws a clipped TrueType run resolving each rune through ch's
// cascade: the first covering face paints it, on the primary face's baseline
// (the caller passes y already at baseline). A chain whose primary never
// loaded paints nothing — the caller's own no-face fallback handles that.
func TextChain(c widgets.Canvas, ch *ttf.Chain, clip widgets.Rect, x, y, size int, text string, rgb uint32) {
	if c == nil || ch == nil || clip.Empty() {
		return
	}
	for _, p := range ch.Split(text) {
		face := p.Face
		if face == nil {
			return // the chain had no loadable primary at all
		}
		for _, ch2 := range p.Text {
			g, adv, err := face.Glyph(face.GlyphIndex(ch2), size)
			if err == nil && !g.Empty() {
				blitMask(c, g, clip, x+g.BearingX, y-g.BearingY, rgb)
			}
			x += adv
			if x >= clip.Right() {
				return
			}
		}
	}
}

// Text draws a clipped TrueType run through Canvas's tinted-mask path. The
// caller supplies a parsed face, so host tests and guest apps use the same
// rasterizer. The pen is at x and the baseline at y.
func Text(c widgets.Canvas, face *ttf.Face, clip widgets.Rect, x, y, size int, text string, rgb uint32) {
	if c == nil || face == nil || clip.Empty() {
		return
	}
	for _, ch := range text {
		g, adv, err := face.Glyph(face.GlyphIndex(ch), size)
		if err == nil && !g.Empty() {
			blitMask(c, g, clip, x+g.BearingX, y-g.BearingY, rgb)
		}
		x += adv
		if x >= clip.Right() {
			break
		}
	}
}

// Glyph draws one PUA chrome icon with the same mask/AA compositing as Text.
func Glyph(c widgets.Canvas, face *ttf.Face, clip widgets.Rect, x, baseline, size int, cp rune, rgb uint32) {
	if c == nil || face == nil || clip.Empty() {
		return
	}
	g, _, err := face.Glyph(face.GlyphIndex(cp), size)
	if err == nil && !g.Empty() {
		blitMask(c, g, clip, x+g.BearingX, baseline-g.BearingY, rgb)
	}
}

func blitMask(c widgets.Canvas, mask *ttf.Mask, clip widgets.Rect, x, y int, rgb uint32) {
	// Only visible mask bytes become pixels. The allocation is bounded by
	// one glyph bitmap; shape hot paths in draw.go remain allocation-free.
	x0, x1 := max(x, clip.X), min(x+mask.Width, clip.Right())
	y0, y1 := max(y, clip.Y), min(y+mask.Height, clip.Bottom())
	if x0 >= x1 || y0 >= y1 {
		return
	}
	w, h := x1-x0, y1-y0
	pix := make([]uint32, w*h)
	for row := 0; row < h; row++ {
		for col := 0; col < w; col++ {
			pix[row*w+col] = uint32(mask.Alpha[(y0-y+row)*mask.Width+x0-x+col]) << 24
		}
	}
	c.BlitTinted(pix, w, h, x0, y0, rgb)
}
