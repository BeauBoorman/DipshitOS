package draw

import (
	"errors"
	"unsafe"

	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

// The methods on BufferCanvas publish the raster engine as a widgets.Canvas.
// Colors here are 0xAARRGGBB; use Opaque for the 24-bit theme token table.
var _ widgets.Canvas = (*BufferCanvas)(nil)

func (c *BufferCanvas) FillRect(r widgets.Rect, rgb uint32) {
	FillRect(c, r, rgb)
}

func (c *BufferCanvas) FillRoundedRect(r widgets.Rect, radius int, rgb uint32) {
	FillRoundedRect(c, r, radius, rgb)
}

func (c *BufferCanvas) StrokeRoundedRect(r widgets.Rect, radius, weight int, rgb uint32) {
	StrokeRoundedRect(c, r, radius, weight, rgb)
}

func (c *BufferCanvas) BlitTinted(src []uint32, srcW, srcH, x, y int, rgb uint32) {
	BlitTinted(c, &BufferCanvas{Pix: src, W: srcW, H: srcH}, x, y, rgb)
}

// Text is the §3.2 widget label path: a real face paints through
// draw.Text's linear-light mask composite, and a nil face degrades to the
// 8x8 bitmap face — §3.4's "no face → bitmap" rule, never a blank label.
func (c *BufferCanvas) Text(face *ttf.Face, clip widgets.Rect, x, y, size int, s string, rgb uint32) {
	if face == nil {
		widgets.DrawText(c, clip, s, rgb)
		return
	}
	Text(c, face, clip, x, y, size, s, rgb)
}

// Opaque converts a theme token's 0x00RRGGBB to the raster engine's opaque
// 0xFFRRGGBB. Do not use it on an intentional transparent ARGB color.
func Opaque(rgb uint32) uint32 { return rgb | 0xff000000 }

// FillerCanvas is the compatibility path for existing syscall-fill windows.
// Curves degrade to hard-edged rectangles and masks to their opaque bounding
// boxes: apps needing coverage AA should bind a window buffer instead.
type FillerCanvas struct {
	Filler   *vi.Filler
	WindowID int
}

var _ widgets.Canvas = (*FillerCanvas)(nil)

func (c *FillerCanvas) FillRect(r widgets.Rect, rgb uint32) {
	if c == nil || c.Filler == nil || r.Empty() {
		return
	}
	// vi.Filler takes RGB, not ARGB. Clip negative coordinates before
	// converting to unsigned to avoid wrapping a partially visible rect.
	x0, y0 := max(r.X, 0), max(r.Y, 0)
	x1, y1 := saturatingAdd(r.X, r.W), saturatingAdd(r.Y, r.H)
	if x1 <= x0 || y1 <= y0 {
		return
	}
	c.Filler.Rect(c.WindowID, uint32(x0), uint32(y0), uint32(x1-x0), uint32(y1-y0), rgb)
}

func (c *FillerCanvas) FillRoundedRect(r widgets.Rect, _ int, rgb uint32) {
	if rgb>>24 == 0 {
		return
	}
	c.FillRect(r, rgb)
}

func (c *FillerCanvas) StrokeRoundedRect(r widgets.Rect, _, weight int, rgb uint32) {
	if r.Empty() || weight <= 0 || rgb>>24 == 0 {
		return
	}
	weight = min(weight, min(r.W, r.H))
	c.FillRect(widgets.Rect{X: r.X, Y: r.Y, W: r.W, H: weight}, rgb)
	c.FillRect(widgets.Rect{X: r.X, Y: r.Bottom() - weight, W: r.W, H: weight}, rgb)
	c.FillRect(widgets.Rect{X: r.X, Y: r.Y + weight, W: weight, H: r.H - 2*weight}, rgb)
	c.FillRect(widgets.Rect{X: r.Right() - weight, Y: r.Y + weight, W: weight, H: r.H - 2*weight}, rgb)
}

func (c *FillerCanvas) BlitTinted(src []uint32, srcW, srcH, x, y int, rgb uint32) {
	if srcW <= 0 || srcH <= 0 || srcW > len(src)/srcH || rgb>>24 == 0 {
		return
	}
	minX, minY, maxX, maxY := srcW, srcH, -1, -1
	for sy := 0; sy < srcH; sy++ {
		for sx := 0; sx < srcW; sx++ {
			if src[sy*srcW+sx]>>24 != 0 {
				minX, minY = min(minX, sx), min(minY, sy)
				maxX, maxY = max(maxX, sx), max(maxY, sy)
			}
		}
	}
	if maxX >= minX {
		c.FillRect(widgets.Rect{X: x + minX, Y: y + minY, W: maxX - minX + 1, H: maxY - minY + 1}, rgb)
	}
}

// Text degrades per §3.2: the run repaints through widgets.DrawText with
// clip as the plate — the 8x8 bitmap face — so a filler surface keeps
// legible labels instead of glyph bounding boxes.
func (c *FillerCanvas) Text(_ *ttf.Face, clip widgets.Rect, _, _, _ int, s string, rgb uint32) {
	widgets.DrawText(c, clip, s, rgb)
}

var errBuffer = errors.New("draw: invalid buffer geometry")

// BytesCanvas views a caller-owned BGRA byte buffer as 0xAARRGGBB words.
// It borrows, never copies, and discards any page-rounding tail.
func BytesCanvas(b []byte, w, h int) (*BufferCanvas, error) {
	if w <= 0 || h <= 0 || w > len(b)/4/h {
		return nil, errBuffer
	}
	return &BufferCanvas{
		Pix: unsafe.Slice((*uint32)(unsafe.Pointer(&b[0])), w*h),
		W:   w, H: h,
	}, nil
}

// WindowCanvas binds an owned Seam-B window surface and returns the same
// canvas the seat gets from BytesCanvas(scanout). The owner presents via
// vi.WinPresent after painting; binding is once per open window, not per frame.
func WindowCanvas(id, w, h int) (*BufferCanvas, error) {
	if id <= 0 || id > 255 || w <= 0 || h <= 0 || h > int(^uint(0)>>1)/4/w {
		return nil, errBuffer
	}
	b, err := vi.MmapWindowSurface(id, w*h*4)
	if err != nil {
		return nil, err
	}
	return BytesCanvas(b, w, h)
}
