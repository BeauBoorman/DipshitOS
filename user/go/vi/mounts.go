// M134b (issue #2760): the one mount table.
//
// `/host`, `/disk` and `/usbN` are rows in one kernel mount table
// (kernel/src/mount_table.zig), not ad-hoc prefixes. sys_dir_list("/")
// enumerates the table — one 40-byte DirEntry per row, the Reserved triple
// carrying {state, kind, flags} — so userland sees every volume's name,
// live state, and read-only flag without a second call. Resolving a path
// onto a not-mounted row answers ENXIO; here that refusal is named
// `not_mounted` (ErrNotMounted).

package vi

import "errors"

// Mount states, as they ride DirEntry.Reserved[0] on a "/" listing.
const (
	MountNotMounted uint8 = 0
	MountMounted    uint8 = 1
)

// Mount kinds, as they ride DirEntry.Reserved[1].
const (
	MountKindShare uint8 = 1 // /host — the --cvc-file share
	MountKindVLFS  uint8 = 2 // /disk — the opt-in VLFS data volume
	MountKindBlock uint8 = 3 // /usb  — the raw MSC device, a byte stream
	MountKindFAT32 uint8 = 4 // /usbN — MBR partition N's FAT32 volume
)

// MountFlagReadOnly is the DirEntry.Reserved[2] bit naming a volume that
// refuses writes.
const MountFlagReadOnly uint8 = 1

// MountFlagSealed is the DirEntry.Reserved[2] bit (M188b #3187) naming a
// sealed v2 VLFS — mounted-unsealed or refused-locked; the row's state
// says which.
const MountFlagSealed uint8 = 2

// Mount is one kernel mount-table row decoded from the "/" listing.
type Mount struct {
	Name     string
	Dir      bool // the row roots a directory; false for the block device
	State    uint8
	Kind     uint8
	ReadOnly bool
	Sealed   bool // M188b: a sealed v2 VLFS (ADR 0061), mounted or locked
}

// ErrNotMounted is the named refusal for a path resolved onto an absent
// volume — the kernel's ENXIO row, under its `not_mounted` name.
var ErrNotMounted = errors.New("not_mounted")

// MountErr names a file-call result: the mount table's ENXIO row is
// ErrNotMounted; anything else keeps its errno name.
func MountErr(rc int64) error {
	if rc == -ErrENXIO {
		return ErrNotMounted
	}
	if rc < 0 {
		return errno(-rc)
	}
	return nil
}

// IsNotMounted reports whether err is the named not_mounted refusal —
// ErrNotMounted itself or a raw ENXIO errno.
func IsNotMounted(err error) bool {
	return err == ErrNotMounted || err == errno(ErrENXIO)
}

// Mounted reports whether the row's volume is present and servable.
func (m Mount) Mounted() bool { return m.State == MountMounted }

// StateName is the row's state word — "mounted" or the card's
// `not_mounted` name.
func (m Mount) StateName() string {
	if m.Mounted() {
		return "mounted"
	}
	return "not_mounted"
}

// KindName names the volume kind.
func (m Mount) KindName() string {
	switch m.Kind {
	case MountKindShare:
		return "share"
	case MountKindVLFS:
		return "vlfs"
	case MountKindBlock:
		return "block"
	case MountKindFAT32:
		return "fat32"
	}
	return "?"
}

// AccessName names the row's write posture — "ro" or "rw".
func (m Mount) AccessName() string {
	if m.ReadOnly {
		return "ro"
	}
	return "rw"
}

// MountFromEntry decodes one "/" DirEntry row: Reserved[0] is the mount
// state, Reserved[1] the kind, Reserved[2] the flag bits.
func MountFromEntry(e DirEntry) Mount {
	return Mount{
		Name:     e.NameString(),
		Dir:      e.Dir(),
		State:    e.Reserved[0],
		Kind:     e.Reserved[1],
		ReadOnly: e.Reserved[2]&MountFlagReadOnly != 0,
		Sealed:   e.Reserved[2]&MountFlagSealed != 0,
	}
}

// Mounts enumerates the kernel mount table — sys_dir_list("/") itself.
// The table is boot-fixed at seven rows, well inside the 16-entry window.
// Returns (mounts, result); rc < 0 carries the syscall's errno.
func Mounts() ([]Mount, int64) {
	var rows [MaxDirEntries]DirEntry
	n, rc := DirList("/", rows[:])
	if rc < 0 {
		return nil, rc
	}
	mounts := make([]Mount, 0, n)
	for i := 0; i < n; i++ {
		mounts = append(mounts, MountFromEntry(rows[i]))
	}
	return mounts, rc
}

// MountNamed finds one row by name — the row, whether it exists, and the
// listing's result.
func MountNamed(name string) (Mount, bool, int64) {
	mounts, rc := Mounts()
	if rc < 0 {
		return Mount{}, false, rc
	}
	for _, m := range mounts {
		if m.Name == name {
			return m, true, rc
		}
	}
	return Mount{}, false, rc
}
