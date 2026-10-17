//go:build virelai

package main

import (
	"errors"
	"unsafe"
)

// The guest listing must page directories: the legacy sys_dir_list window
// silently truncates at 16 rows (kernel/src/syscall.zig handle_dir_list)
// and the fleet's package dirs routinely exceed that. Slot 79's metadata
// snapshot would also page, but its backend is VirtioFS-only — the gate
// runs on the custom file channel where dir_open answers ENOSYS
// (kernel/src/virtio_file.zig metadata_backend). The versioned dir-v2 ops
// on slot 27 itself (handle_dir_v2: open/page/close with
// directory.version in the fourth arg) page the share snapshot over
// EITHER channel, so this driver speaks it directly via the execsvc6
// linkname — vi has no binding for it yet.
const (
	slotDirList    = 27
	dirVersion     = uintptr(1) << 63
	dirOpenOp      = dirVersion | 1
	dirPageOp      = dirVersion | 2
	dirCloseOp     = dirVersion | 3
	dirPageEntries = 16  // directory.page_max
	dirEntryMax    = 256 // directory.entry_max
)

// dirPage mirrors kernel directory.Page: header {next u64, count u32,
// end u32} then page_max 272-byte entries {name[256], size u64 @256,
// nameLen u16 @264, isDir u8 @266}.
type dirWireEntry struct {
	name    [256]byte
	size    uint64
	nameLen uint16
	isDir   uint8
	_       [5]byte
}

type dirWirePage struct {
	next    uint64
	count   uint32
	end     uint32
	entries [dirPageEntries]dirWireEntry
}

func dirEntries(dir string) ([]dirEnt, error) {
	if len(dir) == 0 {
		return nil, errors.New("empty dir")
	}
	// Kernel path grammar accepts "/host/..." verbatim (parse_path routes
	// the host prefix to the share partition).
	tok := execsvc6(slotDirList, strPtr(dir), uintptr(len(dir)), 0, dirOpenOp, 0, 0)
	if tok < 0 {
		return nil, errors.New("dir_open rc=" + itoa64(tok))
	}
	var out []dirEnt
	var offset uint64
	for {
		var page dirWirePage
		n := execsvc6(slotDirList, uintptr(tok), uintptr(offset),
			uintptr(unsafe.Pointer(&page)), dirPageOp, dirPageEntries, 0)
		if n < 0 {
			_ = execsvc6(slotDirList, uintptr(tok), 0, 0, dirCloseOp, 0, 0)
			return nil, errors.New("dir_page rc=" + itoa64(n))
		}
		if n > dirPageEntries || page.count != uint32(n) || page.end > 1 ||
			page.next != offset+uint64(n) || page.next > dirEntryMax ||
			(n == 0 && page.end != 1) {
			_ = execsvc6(slotDirList, uintptr(tok), 0, 0, dirCloseOp, 0, 0)
			return nil, errors.New("dir page malformed")
		}
		for i := int64(0); i < n; i++ {
			e := &page.entries[i]
			if e.nameLen == 0 || int(e.nameLen) > len(e.name) {
				_ = execsvc6(slotDirList, uintptr(tok), 0, 0, dirCloseOp, 0, 0)
				return nil, errors.New("dir entry malformed")
			}
			out = append(out, dirEnt{name: string(e.name[:e.nameLen]),
				isDir: e.isDir != 0})
		}
		if page.end == 1 {
			break
		}
		offset = page.next
	}
	if rc := execsvc6(slotDirList, uintptr(tok), 0, 0, dirCloseOp, 0, 0); rc != 0 {
		return nil, errors.New("dir_close rc=" + itoa64(rc))
	}
	return out, nil
}
