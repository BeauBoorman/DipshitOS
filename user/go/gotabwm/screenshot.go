// GOTABWM.ELF — M190b (#3237): the guest photographs itself.
//
// Two seat chords write what the person sees to the share as a PNG:
// ctrl+shift+3 publishes the whole composed scanout, ctrl+shift+4 the
// focused window's rect of it — the macOS shot pair, spelt in this
// table's modifier block (ctrl+digit alone is focus-index; the shifted
// spellings are free at every scope). No host recorder is involved: the
// seat owns the only pixel-complete view of the guest (M33 seam B), so
// the guest is the camera.
//
// The read is vi.ScanoutRead — slot 88's bounded READ copy of the
// framebuffer — looped in bands under ScanoutReadMax, the agentd
// verbUIScreenshotFull pattern: 12 rows of 1280*4 = 61,440 bytes fit
// the 64 KiB call bound and 720 is a multiple of it (a window rect
// bands on its own row width). The encode is webrender.EncodePNG's
// owned writer over 0xFFRRGGBB words — the ~3.6 MB frame buffer a full
// scanout needs is the card's named memory bound — and the publish is
// vi.WriteFileSafe to /host/SHOTS/SHOT-<unix>.png, the same crash-safe
// write every seat share file goes through.
//
// A refusal names itself twice — the serial marker AND a toast, so it
// is never a silent drop:
//
//	no_host    the /host mount row is not mounted this boot
//	no_window  the window chord decoded on an unfocused strip
//	no_clock   vi.Now carried no epoch this boot
//	bad_rect   a rect the scanout cannot frame
//	io_<errno> a read or publish call's own named failure
//
// Markers print only after the call that made them true (the M57a
// discipline): `saved` after the publish returned, `refused` after the
// check that named it.
package main

import (
	"strings"

	"virelai/vi"
	"virelai/webrender"
)

const (
	// shotDir is the share directory every shot publishes under — a
	// top-level /host sibling of DOCS and SNAPSHOTS, so a person finds
	// the photographs where the seat's other output already lives.
	shotDir = "/host/SHOTS"

	// The marker pair the class-B gate greps.
	MarkerShotSaved   = "gotabwm: shot saved "
	MarkerShotRefused = "gotabwm: shot refused "

	// shotTextMax bounds the toast line — the refusal lane's 24-cell
	// panel width (refusal.go's refusalTextMax).
	shotTextMax = 24
)

// The seams, vars for the reason snapshot.go's snap* set are vars:
// vi.* degrades to -ENOSYS off the guest, which would leave the capture,
// probe and publish paths unobservable to a host test.
var (
	shotRead  = vi.ScanoutRead
	shotList  = vi.DirList
	shotWrite = vi.WriteFileSafe
	shotNow   = vi.Now
	shotLog   = vi.ConsoleLine
	shotMkdir = func(path string) int64 {
		// The snapMkdir triple: MODE_DIR wants WRITE|CREATE beside it,
		// and "already exists" (-9) is the normal case, not a failure.
		h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
		if rc >= 0 {
			vi.FileClose(uint32(h))
		}
		return rc
	}
)

// shotChord is both registry rows' arm. window=false photographs the
// whole composed scanout; window=true the focused tab's rect of it —
// the same rect agentd's win_geometry query reports (the pane's own
// rect, or the full-viewport stack while unplaced or zoomed).
func shotChord(window bool) {
	// The probe runs first and cheap: a boot with no share refuses the
	// chord before the 3.6 MB capture it could never publish.
	if !shotHostMounted() {
		shotRefuse("no_host")
		return
	}
	mode, r := "full", FullRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if window {
		mode = "win"
		id, ok := tabs.Focused()
		if !ok {
			shotRefuse("no_window")
			return
		}
		var found bool
		_, r, _, _, found = agentGeomLookup(id)
		if !found {
			shotRefuse("no_window")
			return
		}
	}
	pix, why := shotCapture(r.X, r.Y, r.W, r.H)
	if why == "" {
		png := webrender.EncodePNG(pix, int(r.W), int(r.H))
		ts := shotNow()
		switch {
		case png == nil:
			why = "bad_rect"
		case ts < 0:
			why = "no_clock"
		default:
			name := "SHOT-" + vi.Itoa64(ts) + ".png"
			path := shotDir + "/" + name
			if m := shotMkdir(shotDir); m < 0 && m != vi.ErrFileExists {
				why = shotErr(m)
			} else if wrc := shotWrite(path, png); wrc != 0 {
				why = shotErr(wrc)
			} else {
				shotSaved(mode, path, name, r.W, r.H, len(png))
				return
			}
		}
	}
	shotRefuse(why)
}

// shotHostMounted is the share probe — the settings.DiskMounted idiom:
// one dirlist of the mount root answers whether /host resolved this
// boot (a not-mounted row answers ENXIO).
func shotHostMounted() bool {
	var scratch [1]vi.DirEntry
	_, rc := shotList("/host", scratch[:])
	return rc >= 0
}

// shotBandRows is the largest band one ScanoutRead call serves for a
// rect w pixels wide — ScanoutReadMax bytes per call; 12 rows at the
// full 1280, matching verbUIScreenshotFull's arithmetic.
func shotBandRows(w uint32) uint32 {
	if w == 0 {
		return 0
	}
	return vi.ScanoutReadMax / (w * 4)
}

// shotErr names a kernel result the way the refusals spell it — the
// errno name, lowercased, under io_ — so a refused read or publish
// reports WHICH call failed, not just that one did.
func shotErr(rc int64) string {
	return "io_" + strings.ToLower(vi.ErrnoName(rc))
}

// shotCapture reads the (x, y, w, h) rect of the scanout as 0xFFRRGGBB
// words — EncodePNG's word layout — in shotBandRows-tall bands. The
// alpha is forced opaque: the framebuffer's X byte is the hardware
// placeholder the seat keeps at 0xff, a photograph has no alpha to
// keep, and the pin keeps the PNG colour type at 2 — the RGB the
// gate's decoder and the spec's raw-snapshot compare both read.
func shotCapture(x, y, w, h uint32) ([]uint32, string) {
	if w == 0 || h == 0 || x+w > vi.ScanoutWidth || y+h > vi.ScanoutHeight {
		return nil, "bad_rect"
	}
	rows := shotBandRows(w)
	if rows == 0 {
		return nil, "bad_rect"
	}
	pix := make([]uint32, int(w)*int(h))
	band := make([]byte, vi.ScanoutReadMax)
	for yy := uint32(0); yy < h; yy += rows {
		hh := rows
		if h-yy < hh {
			hh = h - yy
		}
		n := int(w) * int(hh)
		if r := shotRead(x, y+yy, w, hh, band[:n*4]); r < 0 {
			return nil, shotErr(r)
		}
		dst := pix[int(yy)*int(w) : int(yy+hh)*int(w)]
		for i := 0; i < n; i++ {
			o := i * 4
			dst[i] = 0xff000000 |
				uint32(band[o+2])<<16 | uint32(band[o+1])<<8 | uint32(band[o])
		}
	}
	return pix, ""
}

// shotSaved reports one published photograph: the serial marker carries
// the full path and the frame's shape; the toast names the file the
// share now holds (the basename — the 24-cell panel cannot carry
// "/host/SHOTS/" too, and the directory is fixed).
func shotSaved(mode, path, name string, w, h uint32, bytes int) {
	shotLog(MarkerShotSaved + path +
		" mode=" + mode +
		" w=" + vi.Itoa64(int64(w)) +
		" h=" + vi.Itoa64(int64(h)) +
		" bytes=" + vi.Itoa64(int64(bytes)))
	shotToast("shot " + name)
}

// shotRefuse is the named-refusal half: the marker names the cause and
// the toast carries the same words — never a silent drop.
func shotRefuse(name string) {
	shotLog(MarkerShotRefused + name)
	shotToast("shot refused " + name)
}

// shotToast queues a seat toast and prints the queue/held receipt — the
// kind-12 discipline (interop.go): the marker only after the push, the
// held spelling under do-not-disturb, the drop counter first when the
// queue had to lose one.
func shotToast(text string) {
	if len(text) > shotTextMax {
		text = text[:shotTextMax]
	}
	_, _, dropped := notifyPush(0, text, compositeClock)
	if notifyDND {
		shotLog(MarkerNotifyHeld + "0 " + text)
		return
	}
	if dropped {
		shotLog(MarkerNotifyDrop + vi.Itoa64(int64(notifyDropped)))
	}
	shotLog(MarkerNotify + "0 " + text)
}
