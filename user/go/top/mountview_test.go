package main

// mountview_test.go — M134b (#2760): the mounts tab's kernel-row evidence.
// Host tests stub the mountRows seam; the live enumeration is the
// go-fileman/live-vlfs-dataroot class-B's job.

import (
	"strings"
	"testing"

	"virelai/vi"
)

// stubMountRows pins the kernel mount-table listing for one test.
func stubMountRows(t *testing.T, rows []vi.Mount, rc int64) {
	t.Helper()
	saved := mountRows
	mountRows = func() ([]vi.Mount, int64) { return rows, rc }
	t.Cleanup(func() { mountRows = saved })
}

func testMounts(diskMounted bool) []vi.Mount {
	diskState := uint8(vi.MountNotMounted)
	if diskMounted {
		diskState = vi.MountMounted
	}
	return []vi.Mount{
		{Name: "host", Dir: true, State: vi.MountMounted, Kind: vi.MountKindShare},
		{Name: "disk", Dir: true, State: diskState, Kind: vi.MountKindVLFS},
		{Name: "usb", Dir: false, State: vi.MountNotMounted, Kind: vi.MountKindBlock, ReadOnly: true},
		{Name: "usb1", Dir: true, State: vi.MountNotMounted, Kind: vi.MountKindFAT32, ReadOnly: true},
	}
}

func TestMountViewNotSampledAndRefused(t *testing.T) {
	v := NewMountView()
	if lines := v.Lines(); len(lines) != 1 || lines[0] != "mounts: not sampled" {
		t.Fatalf("unsampled lines = %#v", lines)
	}
	stubMountRows(t, nil, -vi.ErrENOSYS)
	v.Refresh()
	if v.OK {
		t.Fatal("a refused enumeration is not ok")
	}
	if got := v.Marker(); got != "top: mounts err=ENOSYS" {
		t.Fatalf("marker = %q", got)
	}
	if lines := v.Lines(); len(lines) != 1 || !strings.Contains(lines[0], "ENOSYS") {
		t.Fatalf("refused lines = %#v", lines)
	}
}

func TestMountViewRowsNameStateKindAndFlags(t *testing.T) {
	stubMountRows(t, testMounts(false), 0)
	v := NewMountView()
	v.Refresh()
	if !v.OK {
		t.Fatal("a served enumeration must be ok")
	}
	if got := v.Marker(); got != "top: mounts n=4" {
		t.Fatalf("marker = %q", got)
	}
	// The disk row names not_mounted verbatim; usb is ro + block.
	if line, ok := v.RowMarker(1); !ok || !strings.Contains(line, "disk state=not_mounted kind=vlfs flags=rw") {
		t.Fatalf("disk row marker = %q ok=%v", line, ok)
	}
	if line, ok := v.RowMarker(2); !ok || !strings.Contains(line, "usb state=not_mounted kind=block flags=ro") {
		t.Fatalf("usb row marker = %q ok=%v", line, ok)
	}
	if _, ok := v.RowMarker(4); ok {
		t.Fatal("row markers must stop at the table's edge")
	}
	lines := v.Lines()
	var diskLine, usbLine string
	for _, ln := range lines {
		if strings.HasPrefix(ln, "disk ") {
			diskLine = ln
		}
		if strings.HasPrefix(ln, "usb ") {
			usbLine = ln
		}
	}
	if !strings.Contains(diskLine, "not_mounted") {
		t.Fatalf("the disk row must show not_mounted: %q", diskLine)
	}
	if !strings.Contains(usbLine, "block device") {
		t.Fatalf("the block row must say so: %q", usbLine)
	}
}

func TestMountViewDiskMountedReadsRw(t *testing.T) {
	stubMountRows(t, testMounts(true), 0)
	v := NewMountView()
	v.Refresh()
	if line, ok := v.RowMarker(1); !ok || !strings.Contains(line, "disk state=mounted kind=vlfs flags=rw") {
		t.Fatalf("mounted disk row = %q ok=%v", line, ok)
	}
}
