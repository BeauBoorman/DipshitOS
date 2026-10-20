// Paged directory snapshots (M98a, issue #2127): the slot-79 metadata ABI
// (kernel/src/fs_metadata.zig ops 4/5/6, ADR 0007 B5) opens a frozen
// directory snapshot and returns it in 16-entry pages, up to the kernel's
// 256-entry bound. This is the listing surface glob expansion needs: the
// legacy sys_dir_list window (slot 27) silently drops everything past
// row 16, so a glob built on it would miss files it could not see.
package vi

import (
	"encoding/binary"
	"errors"
	"strings"
	"unsafe"
)

// syscallHook6 is the six-argument twin of syscallHook (vi.go): every
// slot-79 call carries five or six registers, more than the original
// four-argument seam can hold. Same contract — nil in a guest build's
// steady state, installed by host tests only.
var syscallHook6 func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64

// SetSyscallHook6ForTest installs fn as the six-argument gateway (nil
// restores the raw one) and returns the previous hook. Host-test seam only.
func SetSyscallHook6ForTest(
	fn func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64,
) func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
	prev := syscallHook6
	syscallHook6 = fn
	return prev
}

func svc6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
	if syscallHook6 != nil {
		return syscallHook6(num, a0, a1, a2, a3, a4, a5)
	}
	return syscall6(num, a0, a1, a2, a3, a4, a5)
}

// Slot-79 directory-snapshot operations and the wire bounds they carry
// (kernel/src/fs_metadata.zig dir_*_op, kernel/src/directory.zig).
const (
	metaDirOpenOp  uintptr = 4
	metaDirPageOp  uintptr = 5
	metaDirCloseOp uintptr = 6
	dirPageMax             = 16  // directory.page_max: entries per page
	dirEntryMax            = 256 // directory.entry_max: snapshot bound
	dirNameMax             = 255 // directory.name_max
	metaKindDir            = 1   // fs_metadata.Kind.directory
)

// dirEntryWire is one metadata.Entry row: 256-byte name, u16 length,
// 6 reserved bytes, then the 96-byte metadata.Wire (fs_metadata.zig).
type dirEntryWire struct {
	name    [256]byte
	nameLen uint16
	_       [6]byte
	meta    [96]byte
}

// dirPageWire is metadata.Page on the wire: the 16-byte directory.Header
// (next/count/end) followed by page_max rows — 5776 bytes total.
type dirPageWire struct {
	next    uint64
	count   uint32
	end     uint32
	entries [dirPageMax]dirEntryWire
}

// The 96-byte metadata.Wire offsets the listing needs (fs_metadata.zig's
// field order: version u32, kind u32, identity[16], size u64, ...).
const (
	metaKindOff = 4
	metaSizeOff = 24
)

// DirItem is one listing row: the name plus the two metadata fields a
// caller needs. The rest of the wire record stays inside the page.
type DirItem struct {
	Name  string
	IsDir bool
	Size  uint64
}

// ErrTreeLimit is the named refusal for a directory too large to list
// whole: the slot-79 snapshot's 256-entry cap (kernel result -5) or a
// full legacy USB window, where a 16th row cannot tell a 16-entry
// directory from a larger one with a dropped tail. Callers refuse loudly
// rather than glob or complete against a partial set.
var ErrTreeLimit = errors.New("directory exceeds the listing bound")

// dirSnapshot lists the canonical directory canon (the shell's /-rooted
// form, where "/" is the share root) through the slot-79 paged snapshot.
// Returns (items, 0) on success, (nil, kernel result) on any failure.
// The snapshot is closed on every path once open — a half-read directory
// must not leak the kernel's snapshot slot.
func dirSnapshot(canon string) ([]DirItem, int64) {
	if !strings.HasPrefix(canon, "/") {
		return nil, -ErrEINVAL
	}
	// The single canonical->root conversion: the shell's /x is the
	// metadata ABI's /host/x, and "/" alone is the /host root (the ABI
	// refuses every root that is not /host or below it).
	root := "/host" + strings.TrimSuffix(canon, "/")
	tok := svc6(SlotFsMetadata, metaDirOpenOp, strPtr(root), uintptr(len(root)), 0, 0, 0)
	if tok <= 0 {
		return nil, tok
	}
	items, rc := dirPages(uint64(tok))
	if cr := svc6(SlotFsMetadata, metaDirCloseOp, uintptr(tok), 0, 0, 0, 0); rc == 0 && cr != 0 {
		rc = cr
	}
	if rc != 0 {
		return nil, rc
	}
	return items, 0
}

// dirPages drains one open snapshot: page at offset until the header
// reports the end, mirroring the protocol checks fs.zig's Page.validate
// makes — a kernel that answers with a malformed page (a count the return
// value does not back, a next that does not advance, a non-final empty
// page) is a protocol violation, not a partial listing.
func dirPages(token uint64) ([]DirItem, int64) {
	var items []DirItem
	var offset uint64
	for {
		var page dirPageWire
		n := svc6(SlotFsMetadata, metaDirPageOp, uintptr(token),
			uintptr(offset), dirPageMax, uintptr(unsafe.Pointer(&page)), 0)
		if n < 0 {
			return nil, n
		}
		if n > dirPageMax || page.count != uint32(n) || page.end > 1 ||
			page.next != offset+uint64(n) || page.next > dirEntryMax ||
			(n == 0 && page.end != 1) {
			return nil, -ErrEINVAL
		}
		for i := int64(0); i < n; i++ {
			e := &page.entries[i]
			if e.nameLen == 0 || e.nameLen > dirNameMax {
				return nil, -ErrEINVAL
			}
			items = append(items, DirItem{
				Name:  string(e.name[:e.nameLen]),
				IsDir: binary.LittleEndian.Uint32(e.meta[metaKindOff:]) == metaKindDir,
				Size:  binary.LittleEndian.Uint64(e.meta[metaSizeOff:]),
			})
		}
		if page.end == 1 {
			return items, 0
		}
		offset = page.next
	}
}

// ListDirAt lists the canonical directory dir: slot-79 paged snapshots for
// host-share paths, the legacy 16-row sys_dir_list window for USB volumes
// (the metadata ABI is host-only — kernel metadata_root refuses every
// other root), and — when the share is the legacy channel and the metadata
// snapshot is unavailable — the slot-27 directory protocol's own paged
// listing. A full legacy window returns ErrTreeLimit, the same named
// refusal the snapshot's own bound produces.
func ListDirAt(dir string) ([]DirItem, error) {
	if usbCanonDir(dir) {
		return usbDirList(dir)
	}
	items, rc := dirSnapshot(dir)
	if rc == -ErrENOSYS {
		// The legacy file channel cannot serve the metadata snapshot
		// (kernel metadata_backend's ops are VirtioFS-only) — but the
		// slot-27 directory protocol IS served there: same snapshot
		// bound, same per-page reauthorization.
		items, rc = dirV2List(dir)
	}
	if rc == 0 {
		return items, nil
	}
	if rc == -ErrENOSPC {
		return nil, ErrTreeLimit
	}
	return nil, errno(-rc)
}

// --- the slot-27 directory protocol (directory.zig's version-bit ops) --------
//
// The v2 wire: one open under the sys_dir_list slot returns a snapshot
// token, pages of directory.Entry rows come back by offset until end=1,
// and the token closes. The kernel implements it for the legacy channel
// through the host's op_dir_open/page/close exchange — the same protocol
// virtio_file.snapshot drives in-kernel — and for VirtioFS natively.
const (
	dirV2Version = 1 << 63 // directory.version
	dirV2OpenOp  = dirV2Version | 1
	dirV2PageOp  = dirV2Version | 2
	dirV2CloseOp = dirV2Version | 3
)

// dirV2Entry is directory.Entry's frozen 272-byte wire row.
type dirV2Entry struct {
	name    [dirNameMax + 1]byte
	size    uint64
	nameLen uint16
	isDir   uint8
	_       [5]byte
}

// dirV2Page is directory.Page: the 16-byte header then page_max rows.
type dirV2Page struct {
	next    uint64
	count   uint32
	end     uint32
	entries [dirPageMax]dirV2Entry
}

// dirV2List lists canonical dir through the slot-27 open/page/close
// protocol. Returns (items, 0) on success, (nil, kernel result) on any
// failure — the snapshot is closed on every path once open.
func dirV2List(canon string) ([]DirItem, int64) {
	if !strings.HasPrefix(canon, "/") {
		return nil, -ErrEINVAL
	}
	root := "/host" + strings.TrimSuffix(canon, "/")
	tok := svc6(SlotDirList, strPtr(root), uintptr(len(root)), 0, dirV2OpenOp, 0, 0)
	if tok <= 0 {
		return nil, tok
	}
	items, rc := dirV2Pages(uint64(tok))
	if cr := svc6(SlotDirList, uintptr(tok), 0, 0, dirV2CloseOp, 0, 0); rc == 0 && cr != 0 {
		rc = cr
	}
	if rc != 0 {
		return nil, rc
	}
	return items, 0
}

// dirV2Pages drains one open snapshot with the same protocol discipline
// dirPages holds: a count the return value does not back, a next that
// does not advance, or a non-final empty page is a protocol violation.
func dirV2Pages(token uint64) ([]DirItem, int64) {
	var items []DirItem
	var offset uint64
	for {
		var page dirV2Page
		n := svc6(SlotDirList, uintptr(token), uintptr(offset),
			uintptr(unsafe.Pointer(&page)), dirV2PageOp, dirPageMax, 0)
		if n < 0 {
			return nil, n
		}
		if n > dirPageMax || page.count != uint32(n) || page.end > 1 ||
			page.next != offset+uint64(n) || page.next > dirEntryMax ||
			(n == 0 && page.end != 1) {
			return nil, -ErrEINVAL
		}
		for i := int64(0); i < n; i++ {
			e := &page.entries[i]
			if e.nameLen == 0 || e.nameLen > dirNameMax {
				return nil, -ErrEINVAL
			}
			items = append(items, DirItem{
				Name:  string(e.name[:e.nameLen]),
				IsDir: e.isDir != 0,
				Size:  e.size,
			})
		}
		if page.end == 1 {
			return items, 0
		}
		offset = page.next
	}
}

// usbCanonDir reports whether the canonical dir names a USB volume root or
// a path below one: /usb or /usbN (N in 1..9) — the same components
// shlib's resolver keeps as volume roots. A host directory named usb9 is
// shadowed by the volume everywhere else too, so the rule is consistent.
func usbCanonDir(dir string) bool {
	comp := strings.TrimPrefix(dir, "/")
	if i := strings.IndexByte(comp, '/'); i >= 0 {
		comp = comp[:i]
	}
	if strings.EqualFold(comp, "usb") {
		return true
	}
	return len(comp) == 4 && strings.EqualFold(comp[:3], "usb") &&
		comp[3] >= '1' && comp[3] <= '9'
}

// usbDirList serves the legacy 16-row window for a USB canonical path
// (canon "/usb1/x" is the kernel's "usb1/x"). A full window is refused:
// 16 rows is a bound the kernel clamps to, not a proof the directory has
// 16 entries. An absent volume names `not_mounted` (M134b) — MountErr
// keeps the kernel's ENXIO under its refused-by-name word.
func usbDirList(dir string) ([]DirItem, error) {
	var entries [MaxDirEntries]DirEntry
	n, rc := DirList(dir[1:], entries[:])
	if rc < 0 {
		return nil, MountErr(rc)
	}
	if n >= MaxDirEntries {
		return nil, ErrTreeLimit
	}
	items := make([]DirItem, 0, n)
	for i := 0; i < n; i++ {
		items = append(items, DirItem{
			Name:  entries[i].NameString(),
			IsDir: entries[i].Dir(),
			Size:  uint64(entries[i].Size),
		})
	}
	return items, nil
}
