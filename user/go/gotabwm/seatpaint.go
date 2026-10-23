// GOTABWM.ELF — M104e (#2272): the seat's shared paint layer. Every seat
// painter composes the scanout through draw.BytesCanvas — borrowed, never
// copied — and the contract's §3 primitives (FillRect, FillRoundedRect,
// FillShadow, BlitScaled, Text/Glyph), where the old code aliased the
// scanout to []uint32 and wrote it through hand-rolled fillRect,
// blitImage and drawText8.
//
// Text follows §3.4 one way everywhere: the resolved ui face paints a
// 13px run vertically centred on the label's band, and a missing face
// repaints the identical run through the engine's bitmap degrade (the
// Canvas.Text nil-face path) — so a boot without /host/FONTS.TXT keeps
// byte-identical chrome instead of a blank default seat. The one-shot
// `gotabwm: fonts` marker names which role resolved and which degraded.
package main

import (
	"virelai/draw"
	"virelai/icons"
	"virelai/theme"
	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

const (
	// §2.2: chrome labels ride the ui face at 13px; secondary lines
	// (reasons, hints, the status tail) take the smaller measure so two
	// lines still fit the bands the 8px face used.
	seatTextPx  = 13
	seatSmallPx = 11

	// §2.2 corner radii: radiusWindow for panels and floating popovers,
	// radiusControl for buttons, inputs and list rows. The engine clamps
	// to min(w,h)/2.
	radiusWindow  = 8
	radiusControl = 4

	// §2.3.6: the selected cell/row carries a 3px Accent left-edge marker
	// (the Zig tab chrome's 3x22 bar). seatRuleW is the seat's 2px
	// identity rule on a plate's left edge (notifyRuleW's twin).
	seatMarkerW = 3
	seatRuleW   = 2
)

// MarkerFonts is the seat's one-shot font report, printed at the first
// paint: the M99l manifest payload plus which role resolved to a TrueType
// face and which degraded to the 8x8 bitmap face — contract deliverable
// 3's named marker for the never-blank rule.
const MarkerFonts = "gotabwm: fonts "

// loadSeatRegistry is the M99l registry entry point, a var so host tests
// can stub the share's manifest away.
var loadSeatRegistry = draw.LoadRegistry

// seatFonts caches the two faces the seat paints with, resolved once per
// boot: ui for labels (Inter) and glyph for the VirelaiChrome PUA icons.
var seatFonts struct {
	tried bool
	ui    *ttf.Face
	glyph *ttf.Face
}

// seatFontResolve reads the staged manifest once and reports the outcome.
// A nil registry or an unresolvable role degrades that role to the bitmap
// path — the seat still paints, and the marker says which leg degraded.
func seatFontResolve() {
	if seatFonts.tried {
		return
	}
	seatFonts.tried = true
	reg, marker := loadSeatRegistry()
	if reg != nil {
		seatFonts.ui = reg.Primary(ttf.Query{Role: "ui"})
		seatFonts.glyph = reg.Primary(ttf.Query{Role: "symbol"})
	}
	face := func(f *ttf.Face) string {
		if f == nil {
			return "bitmap"
		}
		return "ttf"
	}
	vi.ConsoleLine(MarkerFonts + marker +
		" ui=" + face(seatFonts.ui) +
		" chrome=" + face(seatFonts.glyph))
}

func seatFaceUI() *ttf.Face    { seatFontResolve(); return seatFonts.ui }
func seatFaceGlyph() *ttf.Face { seatFontResolve(); return seatFonts.glyph }

// seatCanvas aliases the caller's scanout bytes as a draw.BufferCanvas —
// the borrow BytesCanvas makes, height clamped to the buffer's real row
// count exactly like the old pixN/width maxH. nil on degenerate geometry,
// the painters' old bail.
func seatCanvas(scan []byte, width, height int) *draw.BufferCanvas {
	if width <= 0 || height <= 0 || len(scan) < 4 {
		return nil
	}
	h := len(scan) / 4 / width
	if h > height {
		h = height
	}
	c, err := draw.BytesCanvas(scan, width, h)
	if err != nil {
		return nil
	}
	return c
}

// seatArea reports the clipped bounding-box area of one rect — the
// painters' written-pixel count. It is exact for square fills and the
// closest honest count for a rounded plate.
func seatArea(c *draw.BufferCanvas, r widgets.Rect) int {
	x0, y0 := max(r.X, 0), max(r.Y, 0)
	x1, y1 := min(r.X+r.W, c.W), min(r.Y+r.H, c.H)
	if x1 <= x0 || y1 <= y0 {
		return 0
	}
	return (x1 - x0) * (y1 - y0)
}

// seatFill paints an opaque theme-token rect and reports its clipped
// area. draw.Opaque keeps the scanout's X byte 0xff — the M71c invariant
// the old fillRect enforced by hand.
func seatFill(c *draw.BufferCanvas, r widgets.Rect, rgb uint32) int {
	draw.FillRect(c, r, draw.Opaque(rgb))
	return seatArea(c, r)
}

// seatPlate paints a rounded panel carrying the seat identity: a 2px
// accent rule on its left edge. The rule is the EXPOSED outer fill —
// painting the rule colour under the silhouette and covering x+2 onward
// keeps the rule following the rounded corner instead of poking a square
// nub past it, which is what a straight edge rect does on a curved plate.
func seatPlate(c *draw.BufferCanvas, r widgets.Rect, radius int, rule, fill uint32) int {
	draw.FillRoundedRect(c, r, radius, draw.Opaque(rule))
	inner := r
	inner.X += seatRuleW
	inner.W -= seatRuleW
	draw.FillRoundedRect(c, inner, radius, draw.Opaque(fill))
	return seatArea(c, r)
}

// seatShadow is the §2.5 shared drop shadow for the seat's floating
// plates: dy=4 straight down, blur=16, Shadow ink at 25% peak.
func seatShadow(c *draw.BufferCanvas, r widgets.Rect, radius int) {
	draw.FillShadow(c, r, radius, theme.Current.PadLG, theme.Current.PadSM,
		0x40000000|theme.Current.Shadow)
}

// seatText paints one label so its 8px bitmap band lands at the legacy
// origin (x, y): the resolved ui face draws a px-size run through
// draw.Text vertically centred on that band and clipped to the caller's
// plate (§3.4, and §2.5's "chrome never overlaps a plate edge"); a
// missing face repaints the identical run through the engine's bitmap
// degrade — Canvas.Text's nil-face path — byte-identical to the old
// drawText8. The default boot degrades, never blanks.
func seatText(c *draw.BufferCanvas, clip widgets.Rect, x, y, px int, s string, rgb uint32) {
	plate := widgets.Rect{X: x - 2, Y: y - 2, W: clip.Right() - x + 2, H: 12}
	if f := seatFaceUI(); f != nil {
		asc, desc, _ := f.LineMetrics(px)
		base := y + (8-asc-desc)/2 + asc
		draw.Text(c, f, clip, x, base, px, s, draw.Opaque(rgb))
		return
	}
	c.Text(nil, plate, 0, 0, 0, s, draw.Opaque(rgb))
}

// seatGlyph centres one VirelaiChrome PUA icon in zone at icons.SmallPx
// through the resolved symbol face; a missing face (or one without the
// codepoint) repaints fb — the bitmap stand-in at its legacy origin — so
// the close-x is an 'x' again exactly where the old paint put it.
func seatGlyph(c *draw.BufferCanvas, zone widgets.Rect, cp rune, rgb uint32, fb string, fbX, fbY int) {
	if f := seatFaceGlyph(); f != nil {
		if m, _, err := f.Glyph(f.GlyphIndex(cp), icons.SmallPx); err == nil && !m.Empty() {
			x := zone.X + (zone.W-m.Width)/2 - m.BearingX
			base := zone.Y + (zone.H-m.Height)/2 + m.BearingY
			draw.Glyph(c, f, zone, x, base, icons.SmallPx, cp, draw.Opaque(rgb))
			return
		}
	}
	seatText(c, zone, fbX, fbY, seatTextPx, fb, rgb)
}

// emblemCanvas wraps the decoded mascot raster as a draw surface for
// BlitScaled — the engine's bilinear path the contract names for the
// seat's emblem, replacing the old premultiplied box filter.
func emblemCanvas() *draw.BufferCanvas {
	if src := launcherEmblem(); src != nil {
		return &draw.BufferCanvas{Pix: src, W: launch.emblem.w, H: launch.emblem.h}
	}
	return nil
}

// seatTextWidth is the pen advance for one label — the resolved face's
// measure, or the bitmap face's 8px cell when the degrade path painted it.
func seatTextWidth(s string, px int) int {
	if f := seatFaceUI(); f != nil {
		return f.Measure(s, px)
	}
	return len(s) * 8 // the 8x8 face at 1x: an 8px advance per cell
}

// seatFitText truncates s so it measures inside maxW at px, ending the
// cut with an ellipsis when anything was dropped. The measure is
// seatTextWidth's, so the fit tracks the resolved face's advance on
// either render path.
func seatFitText(s string, maxW, px int) string {
	if maxW <= 0 || s == "" {
		return ""
	}
	if seatTextWidth(s, px) <= maxW {
		return s
	}
	const ell = "…"
	budget := maxW - seatTextWidth(ell, px)
	if budget <= 0 {
		return ell
	}
	// Walk runes, not bytes — a label may carry UTF-8, and a cut inside
	// a rune paints the replacement glyph.
	cut := 0
	used := 0
	for i, r := range s {
		w := seatTextWidth(string(r), px)
		if used+w > budget {
			break
		}
		used += w
		cut = i + len(string(r))
	}
	if cut == 0 {
		return ell
	}
	return s[:cut] + ell
}
