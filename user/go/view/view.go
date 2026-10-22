// Package main is GOVIEW.ELF — the M71h (issue #1567) Go image viewer, the
// successor to Zig VIEW.BIN (M36 IMG5, #826). It paints one share image
// full-viewport inside the tabbed desktop via user/go/tabapp, and it stays
// open (empty state) on a missing or undecodable file instead of panicking —
// VIEW.BIN's own rule.
//
// view.go is the PURE half: the zoom table, the aspect-fitted window size, the
// viewport/dest/pan arithmetic, the format tag and the header sniff. Each of
// these is a straight port of a function in user/src/view.zig, so the contract
// moved by language, not by behaviour — and each is host-tested in
// view_test.go against the same values the Zig gate pins. main.go owns every
// syscall; nothing in this file touches the kernel.
package main

import "strings"

// Zoom table and default (index 4 == 100%), ported from view.zig's
// zoom_table/zoom_default_idx.
var zoomTable = [...]uint32{25, 33, 50, 66, 100, 150, 200, 300, 400, 600, 800}

const zoomDefaultIdx = 4

// HID usages, VIEW.BIN's key map (arrows per the notepad/calc/file_browser
// convention; `=` is 0x2E — the physical `=+` key — 0x2D `-`, 0x27 `0`).
const (
	keyZoomIn  = 0x2E // `=` / `+`
	keyZoomOut = 0x2D // `-`
	keyReset   = 0x27 // `0`
	keyLeft    = 0x50
	keyRight   = 0x4F
	keyUp      = 0x52
	keyDown    = 0x51
	keyQuitQ   = 0x14 // `q`
	keyEscape  = 0x29
	keyCopy    = 0x06 // `c` — M124c typed clipboard
	keySave    = 0x16 // `s` — M162c save-as picker

	// The frame stepper (issue #2975): `.` steps forward, `,` steps back,
	// both wrapping. App-local — neither usage is bound in gotabwm.
	keyFrameNext = 0x37 // `.`
	keyFramePrev = 0x36 // `,`

	// M170e (#3039): space toggles GIF play/pause — the frame-stepper's own
	// play key (mpv lays the same three out: `,`/`.` step, space plays).
	// Plain space is unbound at seat scope (the registry binds only
	// ctrl+space and the ctrl+alt page keys).
	keyPlay = 0x2C
)

// flagPlay is the argv switch that starts playback on load — the live
// gate's trigger, since every scripted input channel on the runner is
// already spent (chords on the stepper presses, the string on save-as,
// the key on JPROG's quit). Interactive play stays on space either way.
const flagPlay = "-play"

// Play pacing (M170e): the arm value for one frame is its GCE delay —
// centiseconds — with the browser convention's 100 ms standing in when the
// file carries a zero delay. ADR 0060's 1 ms granularity needs no clamp
// here: every nonzero delay is already a whole 10 ms step.
const (
	playDelayZeroNs = 100_000_000 // 100 ms — a zero-delay frame's dwell

	// While playing, the empty-queue doze ends at the next frame's
	// deadline instead of the whole 1 s tick (a tick-long park would
	// bury every sub-second delay). The cap keeps a long frame's dwell
	// from starving keys or drag frames; the floor gives a just-past
	// deadline one granule to land its TIMER event rather than spinning.
	playIdleCapNs = 50_000_000 // 50 ms max stall for input during play
	playIdleMinNs = 1_000_000  // 1 ms — the deadline granularity
)

// playDelayNs is the timer arm for one frame: delayCs is the frame's GCE
// delay in centiseconds (GIFFrame.Delay), so a 5 cs fixture arms 50 ms.
func playDelayNs(delayCs int) uint64 {
	if delayCs <= 0 {
		return playDelayZeroNs
	}
	return uint64(delayCs) * 10_000_000
}

// Geometry and caps, ported from view.zig: the window is sized to the image
// (never past 2x, never below the minimum, never past the kernel's cap), the
// viewport sits between the title band and the status bar, and the file cap is
// this viewer's own (vi.MaxFileBytes clamps ReadFileAll to 256 KiB, so the
// read loop below is ours — see readImage).
const (
	winMaxW = 500
	winMaxH = 408
	winMinW = 96
	winMinH = 72

	titleBandH = 16
	statusH    = 12

	windowX = 44
	windowY = 28

	fileMax   = 512 * 1024
	pixelsMax = 131072
)

// format is the display-only tag from the file extension; the decode itself
// sniffs magic (webrender.DecodeImage).
type format int

const (
	fmtUnknown format = iota
	fmtQOI
	fmtPNG
	fmtJPEG
	fmtGIF
)

func (f format) tag() string {
	switch f {
	case fmtQOI:
		return "QOI"
	case fmtPNG:
		return "PNG"
	case fmtJPEG:
		return "JPEG"
	case fmtGIF:
		return "GIF"
	}
	return "???"
}

// formatFromPath is view.zig's format_from_path: the extension, case-insensitive.
func formatFromPath(path string) format {
	i := strings.LastIndexByte(path, '.')
	if i < 0 {
		return fmtUnknown
	}
	switch strings.ToLower(path[i+1:]) {
	case "qoi":
		return fmtQOI
	case "png":
		return fmtPNG
	case "jpg", "jpeg":
		return fmtJPEG
	case "gif":
		return fmtGIF
	}
	return fmtUnknown
}

// saveFormat is the save-as rule (issue #2986): the extension on the chosen
// name picks the encoder — .png or .qoi, case-insensitive like
// formatFromPath; anything else is fmtUnknown and the save is refused by
// name. Kept pure so the refusal table is host-testable.
func saveFormat(path string) format {
	i := strings.LastIndexByte(path, '.')
	if i < 0 {
		return fmtUnknown
	}
	switch strings.ToLower(path[i+1:]) {
	case "png":
		return fmtPNG
	case "qoi":
		return fmtQOI
	}
	return fmtUnknown
}

// dirname is everything before the last '/' — the directory a save-as picker
// opens in. "" when the path has no separator.
func dirname(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[:i]
	}
	return ""
}

// basename is view.zig's basename: everything after the last '/'.
func basename(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}

// winSize is a window extent in pixels.
type winSize struct{ W, H uint32 }

// chooseWindowSize is view.zig's choose_window_size: the content area (window
// minus 8px side padding and 24px of title band + breathing room) preserves the
// image aspect, clamped to [winMin, winMax] and never upscaled past 2x.
func chooseWindowSize(iw, ih uint32) winSize {
	if iw == 0 || ih == 0 {
		return winSize{240, 160}
	}
	const padW, padH uint32 = 8, 24
	capW := uint32(winMaxW) - padW
	capH := uint32(winMaxH) - padH
	cw := capW
	ch := capW * ih / iw
	if ch > capH {
		ch = capH
		cw = capH * iw / ih
	}
	if cw > iw*2 {
		ch = ch * iw * 2 / cw
		cw = iw * 2
	}
	if ch > ih*2 {
		ch = ih * 2
	}
	if cw < uint32(winMinW)-padW {
		cw = uint32(winMinW) - padW
	}
	if ch < uint32(winMinH)-padH {
		ch = uint32(winMinH) - padH
	}
	return winSize{cw + padW, ch + padH}
}

// viewport is the image area inside the window.
type viewport struct{ X, Y, W, H uint32 }

// viewportRect is view.zig's viewport_rect: everything between the title band
// and the status bar.
func viewportRect(winW, winH uint32) viewport {
	if winH <= titleBandH+statusH || winW == 0 {
		return viewport{}
	}
	return viewport{0, titleBandH, winW, winH - titleBandH - statusH}
}

// displayedSize is view.zig's displayed_size: the image scaled by z percent,
// never smaller than one pixel.
func displayedSize(iw, ih, z uint32) winSize {
	return winSize{maxU32(1, iw*z/100), maxU32(1, ih*z/100)}
}

// dest is where the displayed image lands and how much of it is on screen.
type dest struct{ X, Y, W, H uint32 }

// destLayout is view.zig's dest_layout: centered when it fits, top-left
// clipped when it does not.
func destLayout(vp viewport, dw, dh uint32) dest {
	var x, y uint32
	if dw < vp.W {
		x = (vp.W - dw) / 2
	}
	if dh < vp.H {
		y = (vp.H - dh) / 2
	}
	w := minU32(dw, vp.W-minU32(vp.W, x))
	h := minU32(dh, vp.H-minU32(vp.H, y))
	return dest{vp.X + x, vp.Y + y, w, h}
}

// panMax is view.zig's pan_max: the largest legal top-left image pixel. When
// the whole image fits the viewport, only 0 is legal.
func panMax(imgLen, dispLen, vpLen uint32) uint32 {
	if dispLen == 0 || dispLen <= vpLen {
		return 0
	}
	span := maxU32(1, vpLen*imgLen/dispLen)
	return imgLen - minU32(imgLen, span)
}

// applyDelta is view.zig's apply_delta: signed step clamped into [0, max].
func applyDelta(cur uint32, delta int32, max uint32) uint32 {
	next := int64(cur) + int64(delta)
	if next < 0 {
		next = 0
	}
	if next > int64(max) {
		next = int64(max)
	}
	return uint32(next)
}

// clampOrigin is view.zig's clamp_origin: the pan origin re-clamped after a
// zoom change.
func clampOrigin(origin, imgLen, dispLen, vpLen uint32) uint32 {
	if dispLen == 0 || dispLen <= vpLen {
		return 0
	}
	span := maxU32(1, vpLen*imgLen/dispLen)
	return minU32(origin, imgLen-minU32(imgLen, span))
}

// zoomDir is the direction of a zoom-table step.
type zoomDir int

const (
	zoomIn zoomDir = iota
	zoomOut
	zoomReset
)

// stepFrameIdx is the stepper's wrap: one step forward or back through n
// frames, wrapping both ends. dir is ±1.
func stepFrameIdx(cur, dir, n int) int {
	if n < 1 {
		return 0
	}
	return (cur + dir%n + n) % n
}

// frameSum is the FNV-1a-64 over one composited frame's words — the frame
// marker's evidence that a distinct image painted.
func frameSum(pix []uint32) uint64 {
	h := uint64(14695981039346656037)
	for _, p := range pix {
		h ^= uint64(byte(p))
		h *= 1099511628211
		h ^= uint64(byte(p >> 8))
		h *= 1099511628211
		h ^= uint64(byte(p >> 16))
		h *= 1099511628211
		h ^= uint64(p >> 24)
		h *= 1099511628211
	}
	return h
}

// hex64 renders a 64-bit sum as 16 lowercase hex digits — vi has no hex
// printer and this file stays import-free so the host tests run it.
func hex64(v uint64) string {
	const digits = "0123456789abcdef"
	var b [16]byte
	for i := 15; i >= 0; i-- {
		b[i] = digits[v&0xf]
		v >>= 4
	}
	return string(b[:])
}

// stepZoom is view.zig's step_zoom, with the same clamping at both ends of the
// table.
func stepZoom(idx int, dir zoomDir) int {
	switch dir {
	case zoomIn:
		if idx+1 > len(zoomTable)-1 {
			return len(zoomTable) - 1
		}
		return idx + 1
	case zoomOut:
		if idx < 1 {
			return 0
		}
		return idx - 1
	}
	return zoomDefaultIdx
}

// headerDims reads the image geometry out of the head, before any decode.
// QOI carries it at offsets 4/8; PNG's IHDR at 16/20; JPEG carries it in the
// first Start Of Frame segment, found by walking the marker chain inside a
// bounded head (readHead's 4 KiB); GIF's logical screen descriptor sits at
// offsets 6/8, little-endian. This is why a file this viewer cannot decode
// still opens a correctly sized window.
func headerDims(head []byte) (iw, ih uint32, ok bool) {
	if len(head) < 24 {
		return 0, 0, false
	}
	if string(head[0:4]) == "qoif" {
		if w, h := be32(head[4:8]), be32(head[8:12]); w > 0 && h > 0 {
			return w, h, true
		}
	}
	if string(head[0:8]) == "\x89PNG\r\n\x1a\n" && string(head[12:16]) == "IHDR" {
		if w, h := be32(head[16:20]), be32(head[20:24]); w > 0 && h > 0 {
			return w, h, true
		}
	}
	if head[0] == 0xff && head[1] == 0xd8 {
		return jpegHeaderDims(head)
	}
	if v := string(head[0:6]); v == "GIF87a" || v == "GIF89a" {
		if w, h := le16(head[6:]), le16(head[8:]); w > 0 && h > 0 {
			return w, h, true
		}
	}
	return 0, 0, false
}

// jpegHeaderDims walks the JPEG marker chain inside head looking for the
// first Start Of Frame segment, whose body is
// prec(1) height(2) width(2) ncomp(1)…. Every SOF variant shares that
// layout, so a progressive file the decoder will refuse still sizes its
// window. The scan is bounded by len(head) — a deeper SOF simply yields the
// default window.
func jpegHeaderDims(head []byte) (iw, ih uint32, ok bool) {
	pos := 2
	for pos+4 <= len(head) {
		for pos+2 < len(head) && head[pos] == 0xff && head[pos+1] == 0xff {
			pos++ // fill bytes before a marker
		}
		if pos+4 > len(head) || head[pos] != 0xff {
			return 0, 0, false
		}
		m := head[pos+1]
		switch {
		case m == 0x00, m == 0xd9:
			return 0, 0, false // stuffed byte or EOI before a frame
		case m == 0x01, m >= 0xd0 && m <= 0xd8:
			pos += 2 // standalone markers (TEM/RST/SOI) carry no length
			continue
		case m == 0xda:
			return 0, 0, false // SOS: entropy data follows, no frame seen
		}
		n := int(head[pos+2])<<8 | int(head[pos+3])
		if n < 2 {
			return 0, 0, false
		}
		if m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc {
			if n < 8 || pos+4+5 > len(head) {
				return 0, 0, false
			}
			h := uint32(head[pos+5])<<8 | uint32(head[pos+6])
			w := uint32(head[pos+7])<<8 | uint32(head[pos+8])
			if w > 0 && h > 0 {
				return w, h, true
			}
			return 0, 0, false
		}
		pos += 2 + n
	}
	return 0, 0, false
}

// defaultWinSize is view.zig's fallback window when there is no header to read.
var defaultWinSize = winSize{320, 240}

// headerSize is view.zig's header_size_or_default: the window size the header
// asks for, or the default.
func headerSize(head []byte) winSize {
	if iw, ih, ok := headerDims(head); ok {
		return chooseWindowSize(iw, ih)
	}
	return defaultWinSize
}

// composeTitle is view.zig's compose_title: the tab title the WM is handed at
// declare time — the file, its dimensions, its format tag and the zoom. The
// Zig app re-pushed this to the compositor on every zoom; the Go seat's title
// IS the kind-8 declare (see main.go), so this is composed once at open.
func composeTitle(name string, iw, ih uint32, f format, z uint32) string {
	if name == "" {
		return "(no image)"
	}
	return name + " " + u32s(iw) + "x" + u32s(ih) + " " + f.tag() + " " + u32s(z) + "%"
}

// formatOfHeader names the format the header bytes themselves declare. It is
// separate from formatFromPath because a file may lie about its extension, and
// because the "unsupported" message should name what the bytes ARE.
func formatOfHeader(head []byte) format {
	if len(head) >= 4 && string(head[0:4]) == "qoif" {
		return fmtQOI
	}
	if len(head) >= 8 && string(head[0:8]) == "\x89PNG\r\n\x1a\n" {
		return fmtPNG
	}
	if len(head) >= 3 && head[0] == 0xff && head[1] == 0xd8 && head[2] == 0xff {
		return fmtJPEG
	}
	if len(head) >= 6 && (string(head[0:6]) == "GIF87a" || string(head[0:6]) == "GIF89a") {
		return fmtGIF
	}
	return fmtUnknown
}

func be32(b []byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

func le16(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8
}

// u32s formats a dimension for a marker. It is local rather than vi.Itoa64
// because this file is the pure half: the host tests run it with no kernel and
// no vi import at all (vi.Itoa64 drags in the syscall table's package).
func u32s(v uint32) string {
	if v == 0 {
		return "0"
	}
	var buf [10]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

func maxU32(a, b uint32) uint32 {
	if a > b {
		return a
	}
	return b
}

func minU32(a, b uint32) uint32 {
	if a < b {
		return a
	}
	return b
}
