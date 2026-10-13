package vi

import (
	"encoding/binary"
	"testing"
	"unsafe"
)

// M102 defect #13 (#2236): the kind-18 handoff finds the window surface's
// table handle and carries {handle, stride, rows} to the seat under the
// bound session — the seat's half of the compose-N protocol.
func TestWmSurfaceShareCarriesHandleAndGeometry(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const token = uint64(0x0123456789abcdef)
	setWmToken(7, token)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Pad: WmRpcPadBound, Applied: 1}
		SetWmAuth(&rep, token)
		return rep.Encode()
	}
	surf := make([]byte, 64)
	base := uintptr(unsafe.Pointer(&surf[0]))
	var probed []uintptr
	prev := SetSyscallHookForTest(func(num, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotMmap {
			probed = append(probed, a0)
			if a0 == 3 {
				return int64(base)
			}
			return -ErrEFAULT
		}
		return f.hook(num, a0, a1, a2, a3)
	})
	defer SetSyscallHookForTest(prev)

	if !WmSurfaceShare(7, surf, 4, 4, "Tri", "NOTE.ELF") {
		t.Fatal("share refused")
	}
	if len(probed) == 0 || probed[len(probed)-1] != 3 {
		t.Fatalf("probe = %v want it to end on handle 3", probed)
	}
	if len(f.sent) != 1 {
		t.Fatalf("sent %d frames want 1", len(f.sent))
	}
	s := f.sent[0]
	if s.Kind != WmRpcKindShareSurface || s.Pad != WmRpcPadBound || WmAuth(s) != token {
		t.Fatalf("frame = %+v", s)
	}
	if binary.LittleEndian.Uint32(s.Title[0:]) != 3 || binary.LittleEndian.Uint32(s.Title[4:]) != 4 || binary.LittleEndian.Uint32(s.Title[8:]) != 4 {
		t.Fatalf("payload = %x want {3,4,4}", s.Title[:12])
	}
}

// A window with no bound surface has nothing to hand over — the probe
// finds no matching VA and the share refuses before a frame is sent.
func TestWmSurfaceShareNoSurfaceRefuses(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	prev := SetSyscallHookForTest(func(num, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotMmap {
			return -ErrEFAULT
		}
		return f.hook(num, a0, a1, a2, a3)
	})
	defer SetSyscallHookForTest(prev)
	if WmSurfaceShare(7, make([]byte, 64), 4, 4, "Tri", "NOTE.ELF") {
		t.Fatal("share applied with no surface")
	}
	if len(f.sent) != 0 {
		t.Fatalf("sent %d frames want 0", len(f.sent))
	}
}

// The released window is dropped the same way: handle 0, and the seat
// clears its record.
func TestWmSurfaceShareDrop(t *testing.T) {
	f := startWmMailFake(t)
	f.wmName = "GOTABWM.ELF"
	const token = uint64(0x9)
	setWmToken(3, token)
	f.replyFn = func(req WmRpc) []byte {
		rep := WmRpc{Kind: req.Kind | WmRpcReplyFlag, ID: req.ID, Seq: req.Seq,
			ReplyTo: req.ReplyTo, Pad: WmRpcPadBound, Applied: 1}
		SetWmAuth(&rep, token)
		return rep.Encode()
	}
	WmSurfaceShareDrop(3, "NOTE.ELF")
	if len(f.sent) != 1 {
		t.Fatalf("sent %d frames want 1", len(f.sent))
	}
	s := f.sent[0]
	if s.Kind != WmRpcKindShareSurface || binary.LittleEndian.Uint32(s.Title[0:]) != 0 ||
		binary.LittleEndian.Uint32(s.Title[4:]) != 0 || binary.LittleEndian.Uint32(s.Title[8:]) != 0 {
		t.Fatalf("drop frame = %+v payload %x", s, s.Title[:12])
	}
}
