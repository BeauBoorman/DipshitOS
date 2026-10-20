package webrender

import (
	"bytes"
	"errors"
	"virelai/svg"
	"virelai/vector"
	"virelai/webrender/qoi"
	"virelai/webstyle"
)

// In-guest image decoding: bounded, owned PNG/QOI/baseline-JPEG/first-frame
// GIF and ADR 0041 SVG. There are no external decoder dependencies or
// filesystem/network calls.

// Image is a decoded raster in the same 32-bpp word layout the surfaces use:
// one 0xAARRGGBB word per pixel, row-major.
type Image struct {
	Width  int
	Height int
	Pix    []uint32
	// Frames is the container's image count when the format carries one —
	// a GIF reports every frame while still rendering only the first. Zero
	// on single-frame formats.
	Frames int
	png    bool // preserves premultiplied RGB on the legacy Fill-only PNG path
}

// At returns the pixel at (x, y), or 0 outside the image.
func (im *Image) At(x, y int) uint32 {
	if im == nil || x < 0 || y < 0 || x >= im.Width || y >= im.Height {
		return 0
	}
	return im.Pix[y*im.Width+x]
}

// ImageResolver supplies the bytes behind an <img src>. Layout never touches
// the filesystem or the network itself (ADR 0028 D1/D3): the app hands in a
// resolver, and a nil resolver means every image renders as its alt-text box.
type ImageResolver func(src string) ([]byte, bool)

// Image caps. A page cannot make the renderer allocate an unbounded raster.
const (
	maxImagePixels = webstyle.MaxImagePixels
	maxImageBytes  = webstyle.MaxImageBytes
)

// ErrImageUnsupported is returned for a format this decoder does not handle.
var ErrImageUnsupported = errors.New("image-unsupported")

// DecodeImage decodes a PNG, QOI, baseline JPEG, first-frame GIF or ADR 0041
// SVG. Any other format, a truncated file, or an image past the caps returns
// an error — the caller then falls back to the placeholder box rather than
// rendering nothing.
func DecodeImage(data []byte) (*Image, error) {
	if len(data) > maxImageBytes {
		return nil, imageError("image-limit: source bytes")
	}
	xml := bytes.TrimSpace(data)
	if bytes.HasPrefix(xml, []byte{0xef, 0xbb, 0xbf}) {
		xml = xml[3:]
	}
	switch {
	case len(data) >= 8 && bytes.Equal(data[:8], pngMagic):
		return decodePNG(data)
	case len(data) >= 2 && data[0] == 0xff && data[1] == 0xd8:
		return decodeJPEG(data)
	case len(data) >= 6 && (string(data[:6]) == "GIF87a" || string(data[:6]) == "GIF89a"):
		return decodeGIF(data)
	case len(data) >= 4 && string(data[:4]) == "qoif":
		return decodeQOI(data)
	case len(xml) > 0 && xml[0] == '<':
		return decodeSVG(data)
	}
	return nil, ErrImageUnsupported
}

func decodeSVG(data []byte) (*Image, error) {
	budget := vector.Budget{Max: vector.MaxWork}
	scene, canvas, failure := svg.Parse(data, vector.Storage{
		Commands: make([]vector.Command, vector.MaxCommands),
		Paints:   make([]vector.Paint, vector.MaxPaints),
	}, &budget)
	if failure.Code != vector.OK {
		return nil, svgImageError(failure.Code)
	}
	if canvas.Width <= 0 || canvas.Height <= 0 || canvas.Width > webstyle.MaxImageDimension ||
		canvas.Height > webstyle.MaxImageDimension || canvas.Width*canvas.Height > maxImagePixels {
		return nil, imageError("image-limit: svg raster")
	}
	out := &Image{Width: canvas.Width, Height: canvas.Height, Pix: make([]uint32, canvas.Width*canvas.Height)}
	_, failure = vector.Rasterize(scene, vector.Target{
		Pix: out.Pix, Width: out.Width, Height: out.Height, Stride: out.Width,
	}, vector.Workspace{Bytes: make([]byte, vector.WorkspaceSize)}, &budget)
	if failure.Code != vector.OK {
		return nil, svgImageError(failure.Code)
	}
	return out, nil
}

func svgImageError(code vector.Code) error {
	kinds := [...]string{"ok", "malformed", "unsupported-feature", "unsupported-text", "external-resource", "unsupported-xml",
		"source-limit", "depth-limit", "node-limit", "attribute-limit", "token-limit", "command-limit", "contour-limit",
		"segment-limit", "curve-limit", "coordinate-limit", "canvas-limit", "scene-limit", "scratch-limit", "work-limit",
		"memory-limit", "time-limit", "invalid-buffer"}
	if int(code) >= len(kinds) {
		return imageError("image-svg-invalid-buffer")
	}
	return imageError("image-svg-" + kinds[code])
}

var pngMagic = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

// QOI: "Quite OK Image". Header is 14 bytes (magic, width, height, channels,
// colorspace), then a byte stream that ends with a 7-zero + 0x01 marker.
// The decode itself is the virelai/webrender/qoi leaf: the same code, lifted
// so guests outside the renderer can read the format (#2054).
func decodeQOI(data []byte) (*Image, error) {
	w, h, pix, err := qoi.Decode(data, webstyle.MaxImageDimension, maxImagePixels)
	if err != nil {
		return nil, err
	}
	return &Image{Width: w, Height: h, Pix: pix}, nil
}

func be32b(b []byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}
