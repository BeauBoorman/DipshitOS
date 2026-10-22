// M149a (issue #2806): the spacebar QuickLook pane. Space on a selected
// entry takes over the frame with a mime-sniffed preview: a decoded image
// painted through the terminal's sixel image layer (webrender.DecodeImage
// + the M85a primary protocol, the same encoder imgcat proved), the first
// qlTextLines of a text file, or a type/size/mtime card for everything
// else (mtime by the M134a slot-79 stat — meta_guest.go/meta_host.go own
// the platform half). Space or Esc hands the frame back to the list; j/k
// scroll a text arm taller than the pane.
//
// The model stays pure: openQuickLook decides and marks, render.go owns
// the frame (the sixel is bytes appended after a CUP — image cells
// replace the blank body rows the frame painted), and every syscall is
// behind the same host-stubbed seams the rest of the app uses.
package main

import (
	"bytes"
	"errors"
	"strings"

	"virelai/clockfmt"
	"virelai/mime"
	"virelai/rss/keys"
	"virelai/vi"
	"virelai/webrender"
)

const (
	// qlTextLines is the card's text bound: the pane holds the FIRST 40
	// lines of a text file — a longer file scrolls inside that window,
	// never silently reads past it.
	qlTextLines = 40
	// The kernel image bank's per-image bound (term_image max_w/max_h):
	// the thumbnail is scaled inside it, never emitted past it.
	qlImageMaxW = 96
	qlImageMaxH = 64
	// One read serves the sniff head AND the arm's body (the decode
	// buffer for an image, the line source for text).
	maxQuickBytes = vi.MaxFileBytes
)

// qlKind is the arm the sniff chose for the pane.
type qlKind uint8

const (
	qlCard qlKind = iota // the type/size/mtime card — also the fallback
	qlImage
	qlText
)

// quickLook is the open pane's whole state. name/path identify the entry;
// kind picks the arm; the rest are per-arm payloads (lines for text,
// sixel + tile geometry for image, the facts block for card).
type quickLook struct {
	name     string
	path     string
	kind     qlKind
	typeName string // the card's type word (mime id, "directory", "volume")
	size     uint64
	mtOK     bool
	mtSec    int64
	vol      string // volume rows: the mount's state words ("mounted rw")

	lines  []string // qlText: the first qlTextLines sanitized lines
	scroll int      // qlText: first visible line

	imgW, imgH int    // decoded dims (the marker's evidence)
	thW, thH   int    // thumbnail dims (<= qlImageMaxW/H)
	sixel      []byte // encoded once at open; re-placed by every frame
	cellW      uint32 // the grid rung at open (tile geometry)
	cellH      uint32
}

// decodeImage is the decode seam — webrender.DecodeImage in both builds —
// a var so the host tests can pin the refusal arm without a real raster.
var decodeImage = webrender.DecodeImage

// statMtime is the mtime seam (M134a #2759): the slot-79 stat op on the
// guest (meta_guest.go), os.Stat in host builds (meta_host.go). A var so
// the card arm is pinnable without either.
var statMtime = fileMtime

// termCell is the grid rung seam — vi.TerminalCell in both builds.
var termCell = vi.TerminalCell

// openQuickLook is the space chord: sniff the selection and open the arm
// it earns — image bytes that decode paint as sixel, text shows its first
// qlTextLines, and anything else (directories and mount-table rows
// included) is the type/size/mtime card. No selection is a status line,
// like every other nothing-selected op.
func (m *model) openQuickLook() {
	e, ok := m.selEntry()
	if !ok {
		m.status = "quicklook: nothing selected"
		return
	}
	ql := quickLook{
		name: e.NameString(),
		size: uint64(e.Size),
	}
	switch {
	case m.path == volsPath:
		// A mount-table row: the reserved bytes already carry the kernel's
		// own state/kind words (M134b) — the card names them, no stat.
		mt := vi.MountFromEntry(e)
		ql.kind = qlCard
		ql.typeName = "volume"
		ql.vol = mt.KindName() + " " + mt.StateName()
		if mt.Mounted() {
			ql.vol += " " + mt.AccessName()
		}
		m.openQL(ql)
		return
	case m.path == favsView:
		// M167b: a pin row's card names the pin's real path — a gone pin
		// says missing rather than claiming a directory.
		ql.kind = qlCard
		ql.typeName = "pin"
		if m.sel < len(m.favs) {
			ql.path = m.favs[m.sel]
		}
		if m.favMissing(e) {
			ql.typeName = "pin · missing"
		}
		m.openQL(ql)
		return
	case m.tar != nil:
		// M167c: the member's own bytes and header mtime arm the same
		// panes — the pane never learns the path was virtual.
		m.qlTar(&ql, e)
		m.openQL(ql)
		return
	case e.Dir():
		ql.kind = qlCard
		ql.typeName = "directory"
		ql.path = m.qlDirPath(ql.name)
	default:
		p, ok := joinPath(m.path, ql.name)
		if !ok {
			m.status = "quicklook: path too long"
			return
		}
		ql.path = p
		data, rc := readHead(p, maxQuickBytes)
		var head []byte
		if rc >= 0 {
			head = data
		}
		id := mime.Sniff(ql.name, head)
		ql.typeName = id.String()
		switch {
		case rc < 0:
			ql.kind = qlCard
		case id == mime.Image && ql.armImage(data):
			// armImage set kind/dims/sixel on success.
		case id == mime.Text:
			ql.kind = qlText
			ql.lines = quickLines(data)
		default:
			ql.kind = qlCard
		}
	}
	// mtime from the M134a stat — a /host path only; absent reads as "—"
	// on the card, never a fabricated stamp.
	if ql.path != "" {
		if ns, ok := statMtime(ql.path); ok {
			ql.mtOK = true
			ql.mtSec = ns / 1e9
		}
	}
	m.openQL(ql)
}

// qlDirPath resolves a directory row's own path for the stat half of its
// card — the dir itself, not a child.
func (m *model) qlDirPath(name string) string {
	p, ok := joinPath(m.path, name)
	if !ok {
		return ""
	}
	return p
}

// openQL latches the armed pane, emits the DECISION marker, and takes the
// frame. kind=image carries the decoded dims and the thumb's, kind=text
// the line count, kind=card the type word — the serial line states which
// arm the sniff chose, never just "opened".
func (m *model) openQL(ql quickLook) {
	m.ql = ql
	m.mode = modeQuickLook
	switch ql.kind {
	case qlImage:
		m.emit(markerQuick + ql.name + " kind=image " +
			vi.Itoa64(int64(ql.imgW)) + "x" + vi.Itoa64(int64(ql.imgH)) +
			" thumb=" + vi.Itoa64(int64(ql.thW)) + "x" + vi.Itoa64(int64(ql.thH)))
	case qlText:
		m.emit(markerQuick + ql.name + " kind=text lines=" +
			vi.Itoa64(int64(len(ql.lines))))
	default:
		m.emit(markerQuick + ql.name + " kind=card type=" + ql.typeName)
	}
	m.status = "quicklook " + ql.name
}

// closeQuickLook dismisses the pane — space, Esc, or a pointer press —
// restoring the list frame underneath (the listing/preview were never
// touched). The close marker rides pending like the open's.
func (m *model) closeQuickLook() {
	if m.mode != modeQuickLook {
		return
	}
	m.mode = modeNormal
	m.ql = quickLook{}
	m.emit(markerQuickClose)
	m.status = "listed"
}

// qlKey is the modeQuickLook keyboard contract: space/Esc/backspace close,
// the nav keys scroll a text arm inside its 40-line window, Ctrl-C quits.
// Every other key is swallowed — the pane owns the keyboard while it
// stands, like every other modal surface in this app.
func (m *model) qlKey(ev keys.Event) {
	switch ev.Key {
	case keys.KeyEsc, keys.KeyBackspace:
		m.closeQuickLook()
	case keys.KeyDown:
		m.qlScroll(1)
	case keys.KeyUp:
		m.qlScroll(-1)
	case keys.KeyPageDown:
		m.qlScroll(m.bodyRows())
	case keys.KeyPageUp:
		m.qlScroll(-m.bodyRows())
	case keys.KeyHome:
		m.ql.scroll = 0
	case keys.KeyEnd:
		m.ql.scroll = m.qlMaxScroll()
	case keys.KeyCtrlC:
		m.quit = true
	case keys.KeyRune:
		switch ev.Rune {
		case ' ':
			m.closeQuickLook()
		case 'j':
			m.qlScroll(1)
		case 'k':
			m.qlScroll(-1)
		}
	}
}

// qlMaxScroll is the deepest first-line the text arm can show.
func (m *model) qlMaxScroll() int {
	v := len(m.ql.lines) - m.bodyRows()
	if v < 0 {
		return 0
	}
	return v
}

// qlScroll moves the text arm's window by delta, clamped. The image and
// card arms have nothing to scroll — scroll stays put, honestly.
func (m *model) qlScroll(delta int) {
	if m.ql.kind != qlText {
		return
	}
	m.ql.scroll += delta
	if m.ql.scroll < 0 {
		m.ql.scroll = 0
	}
	if max := m.qlMaxScroll(); m.ql.scroll > max {
		m.ql.scroll = max
	}
}

// armImage is the image arm's load: decode, scale inside the bank bound,
// encode once. ok=false leaves kind at qlCard — an image that will not
// decode or encode is still named type=image on the card, never painted
// as text.
func (ql *quickLook) armImage(data []byte) bool {
	im, err := decodeImage(data)
	if err != nil || im == nil || im.Width < 1 || im.Height < 1 ||
		len(im.Pix) != im.Width*im.Height {
		return false
	}
	th := thumbnail(im, qlImageMaxW, qlImageMaxH)
	seq, err := sixelEncode(th)
	if err != nil {
		return false
	}
	ql.kind = qlImage
	ql.imgW, ql.imgH = im.Width, im.Height
	ql.thW, ql.thH = th.Width, th.Height
	ql.sixel = seq
	ql.cellW, ql.cellH = termCell()
	return true
}

// qlTiles is the thumbnail's footprint in cells on the rung it was armed
// under (ceil — a partial tile still covers a whole cell).
func (ql quickLook) qlTiles() (cols, rows int) {
	cw, ch := int(ql.cellW), int(ql.cellH)
	if cw < 1 {
		cw = 8
	}
	if ch < 1 {
		ch = 16
	}
	return (ql.thW + cw - 1) / cw, (ql.thH + ch - 1) / ch
}

// qlOrigin is the cell the sixel's top-left tile lands on: centred in the
// body band, clamped so the placement's IND steps can never reach the
// scroll bottom (an image that scrolls the region would take the frame's
// text with it).
func (m model) qlOrigin() (row, col int) {
	tw, th := m.ql.qlTiles()
	row = 2 + (m.bodyRows()-th)/2
	if row < 2 {
		row = 2
	}
	if row+th > m.rows-2 {
		row = m.rows - 2 - th
		if row < 2 {
			row = 2
		}
	}
	col = (m.cols - tw) / 2
	if col < 0 {
		col = 0
	}
	return row, col
}

// qlSubtitle is the pane's facts row — the type word plus the arm's own
// dims/count so the header says WHAT is being shown.
func (m model) qlSubtitle() string {
	switch m.ql.kind {
	case qlImage:
		return "image " + vi.Itoa64(int64(m.ql.imgW)) + "x" +
			vi.Itoa64(int64(m.ql.imgH))
	case qlText:
		return "text · " + vi.Itoa64(int64(len(m.ql.lines))) + " lines"
	default:
		return "card · " + m.ql.typeName
	}
}

// qlCardRows is the card arm's body: name, type, size, mtime — and for a
// mount-table row the kernel's own state words instead of a stat it
// cannot serve.
func (m model) qlCardRows() []string {
	out := []string{"  " + m.ql.name}
	if m.ql.vol != "" {
		out = append(out,
			"  type      volume",
			"  volume    "+m.ql.vol)
		return out
	}
	out = append(out,
		"  type      "+m.ql.typeName,
		"  size      "+vi.Itoa64(int64(m.ql.size))+" B")
	mod := "—"
	if m.ql.mtOK {
		mod = clockfmt.Format(m.ql.mtSec, clockfmt.UTC)
	}
	out = append(out, "  modified  "+mod)
	return out
}

// quickLines is the text arm's source: the sanitizer's safe printables,
// cut to the card's 40-line bound.
func quickLines(data []byte) []string {
	lines := strings.Split(sanitizePreview(data), "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1] // a trailing newline is not a line
	}
	if len(lines) > qlTextLines {
		lines = lines[:qlTextLines]
	}
	return lines
}

// thumbnail scales im to the largest whole-pixel fit inside maxW x maxH,
// nearest-neighbour both ways (a small image reads as a clean zoom, never
// a smear). An image already inside the bounds passes through.
func thumbnail(im *webrender.Image, maxW, maxH int) *webrender.Image {
	if im == nil || im.Width < 1 || im.Height < 1 {
		return im
	}
	s := float64(maxW) / float64(im.Width)
	if t := float64(maxH) / float64(im.Height); t < s {
		s = t
	}
	outW := int(float64(im.Width) * s)
	outH := int(float64(im.Height) * s)
	if outW < 1 {
		outW = 1
	}
	if outH < 1 {
		outH = 1
	}
	if outW > maxW {
		outW = maxW
	}
	if outH > maxH {
		outH = maxH
	}
	if outW == im.Width && outH == im.Height {
		return im
	}
	out := &webrender.Image{Width: outW, Height: outH, Pix: make([]uint32, outW*outH)}
	for y := 0; y < outH; y++ {
		sy := y * im.Height / outH
		for x := 0; x < outW; x++ {
			out.Pix[y*outW+x] = im.Pix[sy*im.Width+x*im.Width/outW]
		}
	}
	return out
}

var errSixelPalette = errors.New("quicklook: image exceeds 256 sixel colours")
var errSixelBounds = errors.New("quicklook: image exceeds the 96x64 bank bound")

// sixelEncode is the M85a primary protocol for one bounded raster — the
// same encoder imgcat proved (user/go/imgcat/sixel.go), plus "!n" RLE so
// a flat thumbnail does not cost a payload byte per column. Registers are
// RGB percentages, six rows a band, transparent pixels unset; the raster
// declaration fixes the extent at the edges. A raster over the kernel's
// 96x64 or 256-register bound refuses BEFORE the DCS opens — a bad image
// can never leave a partial graphic on the bound terminal.
func sixelEncode(im *webrender.Image) ([]byte, error) {
	if im == nil || im.Width < 1 || im.Height < 1 ||
		im.Width > qlImageMaxW || im.Height > qlImageMaxH ||
		len(im.Pix) != im.Width*im.Height {
		return nil, errSixelBounds
	}
	var colours []uint32
	indices := make([]int16, len(im.Pix))
	seen := make(map[uint32]int16)
	for i, px := range im.Pix {
		if px>>24 < 128 {
			indices[i] = -1
			continue
		}
		rgb := sixelQuantize(px)
		id, ok := seen[rgb]
		if !ok {
			if len(colours) == 256 {
				return nil, errSixelPalette
			}
			id = int16(len(colours))
			colours = append(colours, rgb)
			seen[rgb] = id
		}
		indices[i] = id
	}
	var out bytes.Buffer
	out.WriteString("\x1bPq\"1;1;")
	sixelNumber(&out, im.Width)
	out.WriteByte(';')
	sixelNumber(&out, im.Height)
	for y := 0; y < im.Height; y += 6 {
		if y > 0 {
			out.WriteByte('-')
		}
		for id, rgb := range colours {
			if id > 0 {
				out.WriteByte('$')
			}
			out.WriteByte('#')
			sixelNumber(&out, id)
			out.WriteString(";2;")
			sixelNumber(&out, int(rgb>>16&0xff))
			out.WriteByte(';')
			sixelNumber(&out, int(rgb>>8&0xff))
			out.WriteByte(';')
			sixelNumber(&out, int(rgb&0xff))
			// One sixel byte per column, RLE-compressed at runs of 4+.
			run := 0
			var runB byte
			flush := func() {
				if run == 0 {
					return
				}
				if run >= 4 {
					out.WriteByte('!')
					sixelNumber(&out, run)
					out.WriteByte(runB)
				} else {
					for i := 0; i < run; i++ {
						out.WriteByte(runB)
					}
				}
				run = 0
			}
			for x := 0; x < im.Width; x++ {
				var bits byte
				for bit := 0; bit < 6 && y+bit < im.Height; bit++ {
					if indices[(y+bit)*im.Width+x] == int16(id) {
						bits |= 1 << bit
					}
				}
				c := '?' + bits
				if run > 0 && c == runB {
					run++
					continue
				}
				flush()
				run, runB = 1, c
			}
			flush()
		}
	}
	out.WriteString("\x1b\\")
	return out.Bytes(), nil
}

// sixelQuantize maps one 0xAARRGGBB pixel to the percent-encoded RGB a
// colour register takes (imgcat's quantize, verbatim: the kernel decodes
// both encoders through the same percent path).
func sixelQuantize(px uint32) uint32 {
	channel := func(v uint32) uint32 { return (v*100 + 127) / 255 }
	return channel(px>>16&0xff)<<16 | channel(px>>8&0xff)<<8 | channel(px&0xff)
}

func sixelNumber(b *bytes.Buffer, n int) {
	var digits [10]byte
	i := len(digits)
	for {
		i--
		digits[i] = '0' + byte(n%10)
		n /= 10
		if n == 0 {
			break
		}
	}
	b.Write(digits[i:])
}
