// Host tests for the slot-79 paged directory snapshot (M98a): a fake
// kernel behind the six-argument hook serves open/page/close, and the
// four-arg hook covers the USB legacy fallback.
package vi

import (
	"errors"
	"testing"
	"unsafe"
)

// fakeMetaKernel serves the slot-79 directory ops from a canned listing.
// Every protocol detail the wrapper checks is under the test's control,
// so malformed pages and mid-read failures are one flag away.
type fakeMetaKernel struct {
	entries   []DirItem
	openRc    int64 // when < 0, open fails with this result
	root      string
	opened    int
	pageCalls int
	closed    bool
	// pageErrAt >= 0: that page call (0-based) returns pageErrRc instead.
	pageErrAt int
	pageErrRc int64
	// mutate runs on each filled page before it is handed back and its
	// return value becomes the page call's result (malformed protocol
	// cases); nil is the well-formed path.
	mutate func(p *dirPageWire, n int64) int64
}

func (k *fakeMetaKernel) hook(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
	if num != SlotFsMetadata {
		return -ErrENOSYS
	}
	switch a0 {
	case metaDirOpenOp:
		k.root = unsafe.String((*byte)(unsafe.Pointer(a1)), int(a2))
		if k.openRc < 0 {
			return k.openRc
		}
		k.opened++
		return 7 // tokens start at 1 in the kernel
	case metaDirPageOp:
		if a1 != 7 {
			return -ErrEBADF
		}
		if a5 != 0 {
			return -ErrEINVAL
		}
		call := k.pageCalls
		k.pageCalls++
		if k.pageErrAt >= 0 && call == k.pageErrAt {
			return k.pageErrRc
		}
		return k.fillPage(a4, uint64(a2), uint64(a3))
	case metaDirCloseOp:
		k.closed = true
		return 0
	}
	return -ErrEINVAL
}

func (k *fakeMetaKernel) fillPage(out uintptr, offset, limit uint64) int64 {
	if offset > uint64(len(k.entries)) {
		return -1
	}
	n := uint64(len(k.entries)) - offset
	if n > limit {
		n = limit
	}
	p := (*dirPageWire)(unsafe.Pointer(out))
	p.count = uint32(n)
	p.next = offset + n
	p.end = 0
	if p.next == uint64(len(k.entries)) {
		p.end = 1
	}
	for i := uint64(0); i < n; i++ {
		it := k.entries[offset+i]
		e := &p.entries[i]
		for j := range e.name {
			e.name[j] = 0
		}
		copy(e.name[:], it.Name)
		e.nameLen = uint16(len(it.Name))
		if it.IsDir {
			putU32(e.meta[metaKindOff:], metaKindDir)
		}
		putU64le(e.meta[metaSizeOff:], it.Size)
	}
	if k.mutate != nil {
		return k.mutate(p, int64(n))
	}
	return int64(n)
}

func putU64le(b []byte, v uint64) {
	putU32(b, uint32(v))
	putU32(b[4:], uint32(v>>32))
}

func installMetaKernel(k *fakeMetaKernel) func() {
	prev := SetSyscallHook6ForTest(k.hook)
	return func() { SetSyscallHook6ForTest(prev) }
}

func names(items []DirItem) []string {
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.Name
	}
	return out
}

func TestDirSnapshotMultiPage(t *testing.T) {
	k := &fakeMetaKernel{pageErrAt: -1}
	for i := 0; i < 33; i++ {
		k.entries = append(k.entries, DirItem{Name: "F" + Itoa64(int64(i)) + ".TXT"})
	}
	k.entries[0].IsDir = true
	k.entries[1].Size = 4096
	defer installMetaKernel(k)()

	items, rc := dirSnapshot("/data/docs")
	if rc != 0 || len(items) != 33 {
		t.Fatalf("DirSnapshot = %d items, rc %d; want 33, 0", len(items), rc)
	}
	if k.root != "/host/data/docs" {
		t.Fatalf("root = %q, want /host/data/docs", k.root)
	}
	if k.pageCalls != 3 || !k.closed {
		t.Fatalf("pages=%d closed=%v, want 3 true", k.pageCalls, k.closed)
	}
	if !items[0].IsDir || items[2].IsDir || items[1].Size != 4096 {
		t.Fatalf("flags/size = %+v", items[:3])
	}
}

func TestDirSnapshotRootConversion(t *testing.T) {
	k := &fakeMetaKernel{pageErrAt: -1}
	defer installMetaKernel(k)()
	if _, rc := dirSnapshot("/"); rc != 0 {
		t.Fatalf("dirSnapshot(/) rc = %d", rc)
	}
	if k.root != "/host" {
		t.Fatalf("root = %q, want /host", k.root)
	}
}

func TestDirSnapshotCeiling(t *testing.T) {
	k := &fakeMetaKernel{pageErrAt: -1}
	for i := 0; i < dirEntryMax; i++ {
		k.entries = append(k.entries, DirItem{Name: "N" + Itoa64(int64(i))})
	}
	defer installMetaKernel(k)()
	items, rc := dirSnapshot("/big")
	if rc != 0 || len(items) != dirEntryMax {
		t.Fatalf("ceiling listing = %d items, rc %d", len(items), rc)
	}
	if k.pageCalls != dirEntryMax/dirPageMax {
		t.Fatalf("page calls = %d, want %d", k.pageCalls, dirEntryMax/dirPageMax)
	}
}

func TestDirSnapshotTreeLimit(t *testing.T) {
	k := &fakeMetaKernel{pageErrAt: -1, openRc: -ErrENOSPC}
	defer installMetaKernel(k)()
	items, err := ListDirAt("/huge")
	if items != nil || !errors.Is(err, ErrTreeLimit) {
		t.Fatalf("ListDirAt treelimit = %v, %v", items, err)
	}
	if k.opened != 0 {
		t.Fatalf("open reported success on TreeLimit")
	}
}

func TestDirSnapshotPageErrorCloses(t *testing.T) {
	k := &fakeMetaKernel{pageErrAt: 1, pageErrRc: -ErrEFAULT}
	for i := 0; i < 30; i++ {
		k.entries = append(k.entries, DirItem{Name: "X"})
	}
	defer installMetaKernel(k)()
	items, err := ListDirAt("/d")
	if items != nil || err == nil {
		t.Fatalf("mid-page error = %v, %v; want nil, error", items, err)
	}
	if !k.closed {
		t.Fatalf("snapshot left open after a page error")
	}
}

func TestDirSnapshotMalformedPages(t *testing.T) {
	cases := map[string]func(p *dirPageWire, n int64) int64{
		"count mismatch":     func(p *dirPageWire, n int64) int64 { p.count = uint32(n) + 1; return n },
		"next does not move": func(p *dirPageWire, n int64) int64 { p.next = 0; return n },
		"end out of range":   func(p *dirPageWire, n int64) int64 { p.end = 2; return n },
		"empty non-final": func(p *dirPageWire, n int64) int64 {
			p.count, p.next, p.end = 0, 0, 0
			return 0
		},
		"name too long": func(p *dirPageWire, n int64) int64 { p.entries[0].nameLen = 0; return n },
	}
	for name, mutate := range cases {
		k := &fakeMetaKernel{pageErrAt: -1, mutate: mutate}
		k.entries = []DirItem{{Name: "A"}, {Name: "B"}}
		restore := installMetaKernel(k)
		items, err := ListDirAt("/d")
		restore()
		if items != nil || err == nil {
			t.Fatalf("%s: got %v, %v; want nil, error", name, items, err)
		}
		if !k.closed {
			t.Fatalf("%s: snapshot left open", name)
		}
	}
}

func TestListDirAtUsbFallback(t *testing.T) {
	var gotPath string
	var rows [MaxDirEntries]DirEntry
	copy(rows[0].Name[:], "README")
	rows[0].IsDir = 0
	rows[0].Size = 42
	copy(rows[1].Name[:], "SYS")
	rows[1].IsDir = 1
	prev := SetSyscallHookForTest(func(num, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotDirList {
			return -ErrENOSYS
		}
		gotPath = unsafe.String((*byte)(unsafe.Pointer(a0)), int(a1))
		out := (*[MaxDirEntries]DirEntry)(unsafe.Pointer(a2))
		out[0], out[1] = rows[0], rows[1]
		return 2
	})
	defer SetSyscallHookForTest(prev)

	items, err := ListDirAt("/usb1/DOCS")
	if err != nil || len(items) != 2 {
		t.Fatalf("usb listing = %v, %v", items, err)
	}
	if gotPath != "usb1/DOCS" {
		t.Fatalf("usb kernel path = %q, want usb1/DOCS", gotPath)
	}
	if items[0].Name != "README" || items[0].Size != 42 || items[0].IsDir ||
		items[1].Name != "SYS" || !items[1].IsDir {
		t.Fatalf("usb rows = %+v", items)
	}
}

func TestListDirAtUsbFullWindow(t *testing.T) {
	prev := SetSyscallHookForTest(func(num, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotDirList {
			return -ErrENOSYS
		}
		return MaxDirEntries // a full window cannot prove the directory ends
	})
	defer SetSyscallHookForTest(prev)
	items, err := ListDirAt("/usb2")
	if items != nil || !errors.Is(err, ErrTreeLimit) {
		t.Fatalf("full usb window = %v, %v; want nil, ErrTreeLimit", items, err)
	}
}
