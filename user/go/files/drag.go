// M124a-2 (#2677): the GOFILES drag source. A held move off a pressed row
// arms the seat-mediated drag through tabapp.BeginDrag → vi.DragBegin
// (kind-24): the seat stages the payload under /host/DRAG.<win-id>, draws
// the ghost, and delivers to whichever opens=-accepting client the release
// lands on. The offer is the file's own bytes under its sniffed mime — the
// frame title can only claim what the envelope actually carries, so a
// refusal names what it refused by.
package main

import (
	"strings"

	"virelai/mime"
	"virelai/vi"
)

// dragOffer is the tabapp DragSource hook: produce the pressed row's bytes
// and declared mime, or refuse by name. The seat only calls it once per
// BeginDrag; the refusal markers ride pending and flush with the frame.
func (m *model) dragOffer() (mt string, blob []byte, ok bool) {
	m.dragName = ""
	m.dragMT = ""
	m.dragLen = 0
	if m.pressRow < 0 || m.pressRow >= m.n {
		m.emit(markerDragNo + "none")
		return "", nil, false
	}
	e := m.entries[m.pressRow]
	name := e.NameString()
	m.dragName = name
	switch {
	case m.tar != nil:
		m.emit(markerDragNo + name + " tar")
		m.status = "drag: archive rows do not carry"
	case m.path == volsPath:
		m.emit(markerDragNo + name + " volume")
		m.status = "drag: volume rows do not carry"
	case e.Dir():
		m.emit(markerDragNo + name + " dir")
		m.status = "drag: directories do not carry"
	case e.Size > vi.DragMax:
		m.emit(markerDragNo + name + " too-large")
		m.status = "drag: over the " + vi.Itoa64(vi.DragMax) + "-byte cap"
	default:
		p, ok := joinPath(m.path, name)
		if !ok {
			m.emit(markerDragNo + name + " path")
			m.status = "drag: path too long"
			return "", nil, false
		}
		data, rc := readCapped(p, vi.DragMax)
		if rc < 0 {
			m.emit(markerDragNo + name + " rc=" + vi.Itoa64(rc))
			m.status = refusalStatus("drag", rc)
			return "", nil, false
		}
		m.dragMT = fileMime(name, data)
		m.dragLen = len(data)
		return m.dragMT, data, true
	}
	return "", nil, false
}

// fileMime names a file for the opens= vocabulary: the sniffed family
// refined to a subtype for the formats the in-tree decoders actually read
// (PNG for GOVIEW, text for GOEDIT). The drag offer (M124a-2) declares it
// to the seat's admission, and the M124d context menu matches manifest
// opens= rows against the same spelling. A bare family word is still a
// legal mime on this wire — opensAccepts family-matches it — and
// "application/octet-stream" is the honest name for unknown bytes.
func fileMime(name string, head []byte) string {
	switch mime.Sniff(name, head) {
	case mime.Text:
		// M187d (#3185): the two text subtypes the opens= vocabulary
		// routes by name — a calendar feeds GOCLOCK's import, a
		// contact card opens in this app. Both are extension-named
		// (the formats carry no magic bytes), exactly like the exts
		// table's own fallback.
		switch extOf(name) {
		case "ics":
			return "text/calendar"
		case "vcf":
			return "text/vcard"
		}
		return "text/plain"
	case mime.Image:
		switch {
		case len(head) >= 8 && string(head[:8]) == "\x89PNG\r\n\x1a\n":
			return "image/png"
		case len(head) >= 4 && string(head[:4]) == "qoif":
			return "image/qoi"
		case len(head) >= 6 && (string(head[:6]) == "GIF87a" || string(head[:6]) == "GIF89a"):
			return "image/gif"
		case len(head) >= 3 && head[0] == 0xff && head[1] == 0xd8 && head[2] == 0xff:
			return "image/jpeg"
		}
		return "image"
	case mime.Audio:
		return "audio"
	case mime.Archive:
		return "archive"
	case mime.Binary:
		return "binary"
	}
	return "application/octet-stream"
}

// extOf is the lower-case extension a subtype spelling routes on — the
// same rule mime's own byExt applies (no dot, or a leading dot only, is
// no extension).
func extOf(name string) string {
	i := strings.LastIndexByte(name, '.')
	if i <= 0 || i == len(name)-1 {
		return ""
	}
	return strings.ToLower(name[i+1:])
}
