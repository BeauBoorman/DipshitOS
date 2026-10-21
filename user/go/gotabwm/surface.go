// The seat's compose-N half (issue #2236, live-path defect #13). Under the
// registered seat the kernel skips blitting migrated (surface-backed) user
// windows — their bytes reach the scanout only through the WM's compose-N
// stores (kernel/src/driving_award.zig paint_scene, wm_owns_user_layer).
// The kernel already mirrors every bound surface read-only into the seat's
// root at bind time (bind_window_surface); what it never had was a way for
// the seat to learn which handle belongs to which window. Kind 18
// SHARE_SURFACE is that handoff: the owner resolves its own shared-region
// handle (attach-by-handle probes return the owner's va) and sends it over
// the authenticated seam — Title[0:4] the handle, Title[4:8] the row
// stride in pixels, Title[8:12] the rows — so only a proven window owner
// can register a surface, and the binding's lifetime owns the record.
//
// Each composite tick blits every live record into the scanout at the
// window's mirrored rect, under the seat's own chrome — the same bytes the
// kernel's unmigrated blit would have written.
package main

import "virelai/vi"

const (
	// surfaceMaxRecs bounds live handoffs: one bound surface per user
	// window is the kernel's rule and eight is the user-window table.
	surfaceMaxRecs = 8
	// surfaceMaxBytes bounds the view a reported extent may name — the
	// full scanout is the largest honest window surface.
	surfaceMaxBytes = vi.ScanoutWidth * vi.ScanoutHeight * 4
)

// surfaceXY tracks each user window's live x|y<<16 — the same kind-20
// mirror arg gpu3dRects reads w|h<<16 from.
var surfaceXY [256]uint32

type surfaceRec struct {
	live   bool
	win    uint32
	w, h   uint32 // reported row stride / rows in pixels
	pixels []byte // the seat's RO mirror, w*h*4 bytes
	missed bool   // first mirror-rect miss logged
}

var surfaceRecs [surfaceMaxRecs]surfaceRec

// The kernel seams, injectable for host tests (the gpu3dBroker pattern).
var (
	surfaceAttach = vi.MmapPeerSurface
	surfaceName   = vi.WmctlWindowName
)

func surfaceU32LE(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

// serveSurfaceShare applies one authenticated kind-18 request — gateRPC
// has already proved the sender owns req.ID, so the handoff is the owner
// naming its own surface. A zero handle drops the window's record. The
// byte extent is bounded before attach; the region itself is kernel-owned,
// so the owner's reported geometry is trusted to bound the RO view the
// same way it bounded the surface at bind time.
func serveSurfaceShare(req vi.WmRpc) bool {
	handle := surfaceU32LE(req.Title[0:])
	stride := surfaceU32LE(req.Title[4:])
	rows := surfaceU32LE(req.Title[8:])
	id := uint32(req.ID)
	if handle == 0 {
		surfaceDropWindow(id)
		return true
	}
	if stride == 0 || rows == 0 ||
		uint64(stride)*uint64(rows)*4 > surfaceMaxBytes {
		return false
	}
	bytes := int(stride) * int(rows) * 4
	pix, err := surfaceAttach(handle, bytes)
	if err != nil || len(pix) < bytes {
		vi.ConsoleLine("gotabwm: surf attach refused id=" + vi.Itoa64(int64(id)))
		return false
	}
	for i := range surfaceRecs {
		if surfaceRecs[i].live && surfaceRecs[i].win == id {
			surfaceRecs[i] = surfaceRec{}
		}
	}
	for i := range surfaceRecs {
		if !surfaceRecs[i].live {
			surfaceRecs[i] = surfaceRec{
				live: true, win: id, w: stride, h: rows, pixels: pix[:bytes],
			}
			vi.ConsoleLine("gotabwm: surf live id=" + vi.Itoa64(int64(id)) +
				" " + vi.Itoa64(int64(stride)) + "x" + vi.Itoa64(int64(rows)))
			return true
		}
	}
	return false
}

// surfaceDropWindow forgets a window's handoff: the mirror dies with the
// window, so the record rides the same binding funnel as the session token
// and the gpu3d context (dropRpcBinding). A reused id must never blit a
// dead window's pages.
func surfaceDropWindow(id uint32) {
	if id > 255 {
		return
	}
	surfaceXY[id] = 0
	for i := range surfaceRecs {
		if surfaceRecs[i].live && surfaceRecs[i].win == id {
			surfaceRecs[i] = surfaceRec{}
		}
	}
}

// surfaceNoteMirror tracks the kind-20 x|y<<16 arg beside gpu3dRects' w|h
// — a release mirror clears the position the same way.
func surfaceNoteMirror(e vi.Event) {
	if e.Kind != vi.EvWmWindow {
		return
	}
	id := uint32(e.Flags & 0xff)
	if e.Flags&(1<<13) != 0 {
		// #2870: same staleness guard as the binding drop — a reused
		// id's mirrored position belongs to the live successor.
		if !deathMirrorStale(id) {
			surfaceXY[id] = 0
		}
		return
	}
	surfaceXY[id] = e.Arg0
}

// surfaceAlive probes window liveness through the seat-only name read
// (slot-65 cmd 14): a released window answers EINVAL before its mirror
// drains — exactly the window in which the peer pages may already be
// unmapped. The name buffer must live in a mapped page, like the chrome
// descriptor (the kernel copies through uaccess). scratchVA page 3 is
// free; pages 0-2 are the chrome descriptor and gpu3d descriptor bands.
var surfaceNameBuf []byte

func surfaceAlive(id uint32) bool {
	if surfaceNameBuf == nil {
		b, err := vi.MmapHint(scratchVA+3*vi.PageSize, vi.PageSize,
			vi.ProtRead|vi.ProtWrite, vi.MapAnonymous)
		if err != nil {
			return false
		}
		surfaceNameBuf = b[:64]
	}
	_, r := surfaceName(id, surfaceNameBuf)
	return r >= 0
}

// composeSurfaces blits every live handoff into the scanout at the
// window's mirrored rect — the compose-N stores the kernel's migrated-skip
// expects. The blit clips to the mirror's live extent and the scanout
// edges, so a layout change shrinks instead of smearing. A window with no
// mirror rect yet (gpu3dRects 0) is skipped until one lands.
func composeSurfaces(scan []byte) {
	stride := vi.ScanoutWidth * 4
	for i := range surfaceRecs {
		r := &surfaceRecs[i]
		if !r.live {
			continue
		}
		if !surfaceAlive(r.win) {
			vi.ConsoleLine("gotabwm: surf dead id=" + vi.Itoa64(int64(r.win)))
			*r = surfaceRec{}
			continue
		}
		xy := surfaceXY[r.win]
		wh := gpu3dRects[r.win]
		mw, mh := int(wh&0xffff), int(wh>>16)
		if mw == 0 || mh == 0 {
			if !r.missed {
				r.missed = true
				vi.ConsoleLine("gotabwm: surf nomirror id=" + vi.Itoa64(int64(r.win)))
			}
			continue
		}
		x, y := int(xy&0xffff), int(xy>>16)
		w, h := int(r.w), int(r.h)
		if w > mw {
			w = mw
		}
		if h > mh {
			h = mh
		}
		if x+w > vi.ScanoutWidth {
			w = vi.ScanoutWidth - x
		}
		if y+h > vi.ScanoutHeight {
			h = vi.ScanoutHeight - y
		}
		if w <= 0 || h <= 0 {
			continue
		}
		for row := 0; row < h; row++ {
			dst := (y+row)*stride + x*4
			src := row * int(r.w) * 4
			copy(scan[dst:dst+w*4], r.pixels[src:src+w*4])
		}
	}
}
