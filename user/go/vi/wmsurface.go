// The surface handoff (issue #2236, live-path defect #13). Under the
// registered Go seat the kernel skips compositing migrated (surface-backed)
// user windows — the WM's compose-N stores carry their pixels instead
// (kernel/src/driving_award.zig paint_scene, wm_owns_user_layer). The
// kernel mirrors every bound surface read-only into the seat's root at
// bind time (bind_window_surface's auto-mirror), and the SB3/SB5 proof
// pattern is the owner telling the seat its shared-region handle over the
// mailbox. Kind 18 is that handoff on the authenticated WM_RPC seam:
//
//	Title[0:4]  shared-region handle (0 = drop the window's handoff)
//	Title[4:8]  surface row stride, pixels
//	Title[8:12] surface rows
//
// It rides the same challenge/token flow as every other bound kind, so the
// seat only ever attaches what a proven window owner named. There is no
// legacy-seat path — kind 18 exists only on the authenticated protocol,
// exactly like kind 17.
package vi

import "unsafe"

// WmRpcKindShareSurface is the additive WM_RPC kind for the surface
// handoff (ADR 0009 numbering continues past kind 17).
const WmRpcKindShareSurface uint8 = 18

// maxSharedRegions mirrors shared_region.max_shared_regions (kernel): the
// peer-attach probe walks region handles, which allocate dense from 1.
const maxSharedRegions = 8

// WindowSurfaceHandle resolves the shared-region handle that owns surf's
// base. An owner attaching by handle gets its own va back before any size
// or peer check (syscall.zig handle_mmap_shared), so probing handles
// 1..maxSharedRegions costs one mmap each and names the surface without a
// new syscall. Regions the caller neither owns nor peers refuse EFAULT or
// EACCES and are skipped.
func WindowSurfaceHandle(surf []byte) (uint32, bool) {
	if len(surf) == 0 {
		return 0, false
	}
	base := uintptr(unsafe.Pointer(&surf[0]))
	for h := uint32(1); h <= maxSharedRegions; h++ {
		r := svc4(SlotMmap, uintptr(h), uintptr(PageSize),
			uintptr(ProtRead|ProtWrite), uintptr(MapAnonymous|M33MapShared))
		if r > 0 && uintptr(r) == base {
			return h, true
		}
	}
	return 0, false
}

// MmapPeerSurface attaches the REGISTERED WM's read view of shared-region
// handle — the peer-attach half of seam B (mmap addr < 0x1000 names a
// handle). The kernel returns the seat's mirrored va: the auto-mirror va
// installed at bind time, or a fresh RO mapping when the surface predates
// registration (a fresh attach refuses anything but the whole region, so
// size must be the region's byte length). Off-guest: -ENOSYS.
func MmapPeerSurface(handle uint32, size int) ([]byte, error) {
	if handle == 0 || handle >= 0x1000 || size <= 0 ||
		size > int(^uint(0)>>1)-(PageSize-1) {
		return nil, errno(ErrEINVAL)
	}
	n := (size + PageSize - 1) &^ (PageSize - 1)
	r := svc4(SlotMmap, uintptr(handle), uintptr(n),
		uintptr(ProtRead), uintptr(MapAnonymous|M33MapShared))
	if r < 0 {
		return nil, errno(-r)
	}
	return mmapSlice(uintptr(r), size), nil
}

// WmSurfaceShare hands this window's bound surface to the Go seat: it
// resolves the region handle by probing attach-by-handle, then sends the
// authenticated kind-18 request — Title[0:4] the handle, Title[4:8] the
// row stride in pixels, Title[8:12] the rows. title is the window's
// intended kernel title, restored after any bind proof. Returns false
// when the surface has no resolvable handle, the geometry is empty, the
// window id does not fit the wire, there is no Go seat, or the bounded
// wait expires without an applied ack.
func WmSurfaceShare(winID uint32, surf []byte, stride, rows int, title, selfName string) bool {
	if !fitsWire8(winID) || stride <= 0 || rows <= 0 {
		return false
	}
	handle, ok := WindowSurfaceHandle(surf)
	if !ok {
		return false
	}
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 || !fitsWire8(peers.Self) || !peers.Go {
		return false
	}
	var t [WmRpcTitleMax]byte
	putU32(t[0:], handle)
	putU32(t[4:], uint32(stride))
	putU32(t[8:], uint32(rows))
	rep, ok := wmRequestGoTitle(WmRpcKindShareSurface, uint8(winID), t, title, peers)
	return ok && rep.Applied != 0
}

// WmSurfaceShareDrop retires winID's handoff — handle 0 — for the owner
// that knows its surface is about to die with the window. The seat drops
// on the released mirror regardless; this only closes the gap where the
// owner tears down before that mirror lands.
func WmSurfaceShareDrop(winID uint32, selfName string) {
	if !fitsWire8(winID) {
		return
	}
	peers := WmPeers(selfName)
	if peers.WM == 0 || peers.Self == 0 || !fitsWire8(peers.Self) || !peers.Go {
		return
	}
	var t [WmRpcTitleMax]byte
	_, _ = wmRequestGoTitle(WmRpcKindShareSurface, uint8(winID), t, "", peers)
}
