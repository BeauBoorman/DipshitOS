package webrender

import (
	"strings"
	"unicode/utf8"
	"virelai/ttf"
	"virelai/webrender/font"
	"virelai/webstyle"
)

// Paint draws a laid-out document into s. The content box starts at (ox, oy)
// and is (vw, vh) pixels; `scroll` shifts the content up by that many pixels.
// Everything is clipped to the content box so page paint can never spill into
// the browser chrome drawn in the same window.
func Paint(l *Layout, s Surface, ox, oy, vw, vh, scroll int) {
	if l == nil || s == nil || vw <= 0 || vh <= 0 {
		return
	}
	clip := Clip{X: ox, Y: oy, W: vw, H: vh}
	events := paintBoxEvents(l)
	for i := 0; i <= len(l.Items); i++ {
		if i < len(events) {
			for _, box := range events[i] {
				paintBox(s, clip, box, ox, oy-scroll)
			}
		}
		if i == len(l.Items) {
			break
		}
		it := l.Items[i]
		y := oy + it.Y - scroll
		inkPadding := 0
		if it.Kind == ItemText && it.FontPx > 0 {
			// CSS allows line-height smaller than glyph ink. Use a
			// conservative two-em extent for the frozen faces; the text
			// engine applies the exact page clip to each glyph mask.
			inkPadding = 2 * it.FontPx
		}
		if y-inkPadding >= clip.Y+clip.H || y+it.H+inkPadding <= clip.Y {
			continue
		}
		switch it.Kind {
		case ItemRect:
			rgb := it.Bg
			if it.Box != nil && it.Box.Node != nil && FormControl(it.Box.Node.Tag) {
				var visible bool
				rgb, visible = paintColor(it.Box.Style.BackgroundColor, it.Box.Style.Color, false)
				if !visible {
					continue
				}
			}
			if it.Box != nil && it.X == it.Box.Border.X && it.Y == it.Box.Border.Y &&
				it.W == it.Box.Border.W && it.H == it.Box.Border.H &&
				it.Box.Style.BackgroundColor.Kind != webstyle.ColorInitial {
				continue // native box background/borders were painted together
			}
			fillClipped(s, clip, ox+it.X, y, it.W, it.H, rgb)
		case ItemRule:
			if transparentText(it.Box) {
				continue
			}
			fillClipped(s, clip, ox+it.X, y, it.W, it.H, it.Color)
		case ItemText:
			if transparentText(it.Box) {
				continue
			}
			// The engine the layout was measured with, so wrap and paint agree.
			engine := l.Text
			if engine == nil {
				engine = Bitmap{}
			}
			engine.Paint(s, ox+it.X, y, it.Text,
				Style{Size: it.Size, FontPx: it.FontPx, LineHeightPx: it.LineHeightPx,
					Mono: it.Mono, Serif: it.Serif, Bold: it.Bold, Italic: it.Italic}, it.Color, clip)
		case ItemImage:
			if it.Img != nil {
				drawImage(s, clip, ox+it.X, y, it)
			} else {
				drawImageBox(s, clip, ox+it.X, y, it, l.Text)
			}
		}
	}
}

// HitTest returns the link target under the content point (content
// coordinates, i.e. viewport point + scroll) — "" when none.
func HitTest(l *Layout, cx, cy int) string {
	if l == nil {
		return ""
	}
	for i := len(l.Links) - 1; i >= 0; i-- {
		k := l.Links[i]
		if cx >= k.X && cx < k.X+k.W && cy >= k.Y && cy < k.Y+k.H {
			return k.Target
		}
	}
	return ""
}

func transparentText(box *Box) bool {
	return box != nil && box.Style.Color.Kind == webstyle.ColorRGBA && box.Style.Color.RGBA>>24 == 0
}

// Block ranges come from layout. Inline ranges are recovered from their
// source items, because M93d retains union rectangles rather than item ranges
// for those boxes. Preorder insertion keeps parent paint before descendants.
func paintBoxEvents(l *Layout) [][]*Box {
	if l.BoxTree == nil || l.BoxTree.compatibility {
		return nil
	}
	first := make(map[*Box]int)
	for i, it := range l.Items {
		for b := it.Box; b != nil && b.inline; b = b.parent {
			if _, ok := first[b]; !ok {
				first[b] = i
			}
		}
	}
	events := make([][]*Box, len(l.Items)+1)
	var walk func(*Box)
	walk = func(b *Box) {
		if b == nil {
			return
		}
		i := b.start
		if b.inline {
			var ok bool
			i, ok = first[b]
			if !ok {
				i = len(l.Items)
			}
		}
		if i >= 0 && i <= len(l.Items) && b.Border.W > 0 && b.Border.H > 0 {
			events[i] = append(events[i], b)
		}
		for _, child := range b.Children {
			walk(child)
		}
	}
	walk(l.BoxTree.Root)
	return events
}

func paintColor(c webstyle.Color, foreground webstyle.Color, border bool) (uint32, bool) {
	if c.Kind == webstyle.ColorCurrent || border && c.Kind == webstyle.ColorInitial {
		c = foreground
		if c.Kind == webstyle.ColorInitial {
			return 0, true
		}
	}
	if c.Kind == webstyle.ColorInitial {
		return 0, border // initial foreground is black; background transparent
	}
	return c.RGBA & 0xffffff, c.RGBA>>24 != 0
}

func paintBox(s Surface, c Clip, b *Box, ox, oy int) {
	r := b.Border
	x, y := ox+r.X, oy+r.Y
	if rgb, visible := paintColor(b.Style.BackgroundColor, b.Style.Color, false); visible {
		fillClipped(s, c, x, y, r.W, r.H, rgb)
	}
	e := borderWidths(b.Style.Border)
	if e == (usedEdges{}) {
		return
	}
	sides := []webstyle.Border{b.Style.Border.Top, b.Style.Border.Right, b.Style.Border.Bottom, b.Style.Border.Left}
	colors, visible := [4]uint32{}, [4]bool{}
	for i, side := range sides {
		colors[i], visible[i] = paintColor(side.Color, b.Style.Color, true)
	}
	// Pixel-center diagonal joins partition the corners, so differently
	// colored sides neither overlap nor leave gaps.
	for row := max(0, c.Y-y); row < min(r.H, c.Y+c.H-y); row++ {
		left, right, middle := e.left, e.right, -1
		if row < e.top {
			left = ((2*row+1)*e.left + e.top) / (2 * e.top)
			right = ((2*row+1)*e.right + e.top) / (2 * e.top)
			middle = 0
		} else if row >= r.H-e.bottom {
			d := r.H - row - 1
			left = ((2*d+1)*e.left + e.bottom) / (2 * e.bottom)
			right = ((2*d+1)*e.right + e.bottom) / (2 * e.bottom)
			middle = 2
		}
		if visible[3] {
			fillClipped(s, c, x, y+row, left, 1, colors[3])
		}
		if middle >= 0 && visible[middle] {
			fillClipped(s, c, x+left, y+row, r.W-left-right, 1, colors[middle])
		}
		if visible[1] {
			fillClipped(s, c, x+r.W-right, y+row, right, 1, colors[1])
		}
	}
}

func fillClipped(s Surface, c Clip, x, y, w, h int, rgb uint32) {
	if w <= 0 || h <= 0 {
		return
	}
	x0, y0, x1, y1 := x, y, x+w, y+h
	if x0 < c.X {
		x0 = c.X
	}
	if y0 < c.Y {
		y0 = c.Y
	}
	if x1 > c.X+c.W {
		x1 = c.X + c.W
	}
	if y1 > c.Y+c.H {
		y1 = c.Y + c.H
	}
	if x1 <= x0 || y1 <= y0 {
		return
	}
	s.Fill(x0, y0, x1-x0, y1-y0, rgb)
}

// drawImage blits a decoded raster into its box, nearest-neighbour scaled, with
// horizontally identical pixels merged into one span (the fill syscall takes a
// rect, so runs are how an image reaches the scanout at all). Anything outside
// the clip is dropped.
func drawImage(s Surface, c Clip, x, y int, it Item) {
	img := it.Img
	if img == nil || it.W <= 0 || it.H <= 0 {
		return
	}
	for row := 0; row < it.H; row++ {
		py := y + row
		if py < c.Y || py >= c.Y+c.H {
			continue
		}
		sy := row * img.Height / it.H
		if sy >= img.Height {
			sy = img.Height - 1
		}
		runStart, runLen := 0, 0
		var runColor uint32
		flush := func(end int) {
			if runLen == 0 {
				return
			}
			px, w := x+runStart, runLen
			if px < c.X {
				w -= c.X - px
				px = c.X
			}
			if px+w > c.X+c.W {
				w = c.X + c.W - px
			}
			if w > 0 {
				alpha := byte(runColor >> 24)
				if ms, ok := s.(MaskSink); ok && alpha < 255 {
					mask := &ttf.Mask{Width: w, Height: 1, Alpha: make([]byte, w)}
					for i := range mask.Alpha {
						mask.Alpha[i] = alpha
					}
					ms.BlitMask(px, py, mask, runColor&0xffffff)
				} else {
					// Preserve the established Fill-only image behavior.
					s.Fill(px, py, w, 1, runColor&0xffffff)
				}
			}
			runLen = 0
			runStart = end
		}
		for col := 0; col < it.W; col++ {
			sx := col * img.Width / it.W
			if sx >= img.Width {
				sx = img.Width - 1
			}
			col8 := img.Pix[sy*img.Width+sx]
			if img.png && it.Box == nil {
				// Compatibility goldens used image/png's premultiplied
				// channels on a Fill-only sink. Decode stays straight RGBA;
				// only this legacy presentation retains those RGB bytes.
				a := col8 >> 24
				r := ((col8 >> 16 & 255) * 257 * a / 255) >> 8
				g := ((col8 >> 8 & 255) * 257 * a / 255) >> 8
				b := ((col8 & 255) * 257 * a / 255) >> 8
				col8 = 0xff000000 | r<<16 | g<<8 | b
			}
			if runLen == 0 {
				runStart, runColor, runLen = col, col8, 1
				continue
			}
			if col8 == runColor {
				runLen++
				continue
			}
			flush(col)
			runStart, runColor, runLen = col, col8, 1
		}
		flush(it.W)
	}
}

func drawImageBox(s Surface, c Clip, x, y int, it Item, engine TextEngine) {
	if it.Box != nil {
		drawCSSImageBox(s, c, x, y, it, engine)
		return
	}
	fillClipped(s, c, x, y, it.W, it.H, ColorSurface)
	fillClipped(s, c, x, y, it.W, 1, ColorRule)
	fillClipped(s, c, x, y+it.H-1, it.W, 1, ColorRule)
	fillClipped(s, c, x, y, 1, it.H, ColorRule)
	fillClipped(s, c, x+it.W-1, y, 1, it.H, ColorRule)
	label := UpperASCII(it.Text)
	cols := (it.W - 8) / font.Advance(1)
	if cols < 1 {
		cols = 1
	}
	if len(label) > cols {
		label = label[:cols]
	}
	DrawText(s, x+4, y+it.H/2-4, label, 1, false, ColorMuted, c)
}

func drawCSSImageBox(s Surface, c Clip, x, y int, it Item, engine TextEngine) {
	c = c.Intersect(Clip{X: x, Y: y, W: it.W, H: it.H})
	fillClipped(s, c, x, y, it.W, 1, 0x808080)
	fillClipped(s, c, x, y+it.H-1, it.W, 1, 0x808080)
	fillClipped(s, c, x, y, 1, it.H, 0x808080)
	fillClipped(s, c, x+it.W-1, y, 1, it.H, 0x808080)
	label := it.Text
	if label == "" {
		label = "[image unavailable]"
	}
	if len(label) > 256 {
		label = label[:256]
		for !utf8.ValidString(label) && len(label) > 0 {
			label = label[:len(label)-1]
		}
	}
	if engine == nil {
		engine = Bitmap{}
	}
	st := textStyle(it.Box.Style)
	if transparentText(it.Box) {
		return
	}
	inner := c.Intersect(Clip{X: x + 4, Y: y + 4, W: max(0, it.W-8), H: max(0, it.H-8)})
	top, line := y+4, ""
	flush := func() {
		engine.Paint(s, x+4, top, strings.TrimRight(line, " \t"), st, st.Color, inner)
		top += engine.LineHeight(st)
		line = ""
	}
	for _, ch := range label {
		if ch == '\n' {
			flush()
			continue
		}
		if top >= inner.Y+inner.H {
			break
		}
		next := line + string(ch)
		if line != "" && engine.Measure(next, st) > inner.W {
			flush()
			if ch == ' ' || ch == '\t' {
				continue
			}
			next = string(ch)
		}
		line = next
	}
	if line != "" && top < inner.Y+inner.H {
		flush()
	}
}

// ChromeHeight is how many pixels the browser chrome occupies above the page
// viewport (title band + URL bar). Exported so the browser and its tests
// agree on the geometry.
const ChromeHeight = 34

// StatusHeight is the status line height at the bottom of the window.
const StatusHeight = 12
