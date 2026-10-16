// The M100f (#2311) data-root resolution — the opt-in half of ADR 0050's
// mount model. `data_root=disk` in SETTINGS.TXT moves the movable data set
// (GOSH's history file, the seat's notify history, the fetch download
// default) onto the guest's own VLFS volume — but only when the boot
// actually mounted one. A set-but-absent disk is a named fallback to
// /host, never a boot failure: ADR 0050 D6 makes every /disk surface an
// honest ENOENT when nothing mounted, which is what the probe below reads.
//
// SETTINGS.TXT itself is never movable: it lives on /host because it is
// the pointer this resolution reads.
package settings

import "virelai/vi"

const (
	// DataRootHost / DataRootDisk are the two volume roots a resolved path
	// can live under. The kernel's own mount names them.
	DataRootHost = "/host"
	DataRootDisk = "/disk"
)

// DiskMounted is the mount probe behind ResolveDataRoot: one dirlist of the
// VLFS root answers whether this boot attached AND mounted a named data
// disk (ADR 0050 D1/D6 — the kernel mounts only on GET_ID match plus a
// valid superblock; anything else leaves .disk unmounted and answering
// ENOENT). A var so host tests pin both legs; on a host build the syscall
// is -ENOSYS, which reads as unmounted — the honest default.
var DiskMounted = func() bool {
	var scratch [1]vi.DirEntry
	_, rc := vi.DirList(DataRootDisk, scratch[:])
	return rc >= 0
}

// ResolveDataRoot reports where the movable set lives this boot: "/disk"
// only when the file carries an exact `data_root=disk` AND the mount probe
// found the volume. Any other state — absent row, `host`, a corrupt file,
// a mistyped value — resolves "/host" with fellBack=false, which is the
// compiled default an untouched boot already had.
//
// fellBack is true in exactly one shape: the row opted in and the probe
// refused. The caller owns logging that once (each consumer's own named
// line); this function stays silent so a test never has to stub a console.
func (f File) ResolveDataRoot() (root string, fellBack bool) {
	v, _ := f.Effective(DataRootKey)
	if v != "disk" {
		return DataRootHost, false
	}
	if !DiskMounted() {
		return DataRootHost, true
	}
	return DataRootDisk, false
}
