package main

// volumes_test.go — M134b (#2760): the volumes root reads the kernel's
// mount table. Host tests stub the mountRows seam with wire-shaped rows
// and pin the listing markers, the live state names, the named enter
// refusal, and the mutating-op guards; the real /disk listings are the
// live-vlfs-dataroot class-B's job.

import (
	"strings"
	"testing"

	"virelai/vi"
)

// stubMounts pins the kernel mount-table listing for one test and
// restores it: the share, the (optionally mounted) data volume, the raw
// block device, and one FAT32 slot — the rows the kernel enumerates at "/".
func stubMounts(t *testing.T, diskMounted bool) {
	t.Helper()
	saved := mountRows
	diskState := uint8(vi.MountNotMounted)
	if diskMounted {
		diskState = vi.MountMounted
	}
	mountRows = func() ([]vi.Mount, int64) {
		return []vi.Mount{
			{Name: volHost, Dir: true, State: vi.MountMounted, Kind: vi.MountKindShare},
			{Name: volDisk, Dir: true, State: diskState, Kind: vi.MountKindVLFS},
			{Name: "usb", Dir: false, State: vi.MountNotMounted, Kind: vi.MountKindBlock, ReadOnly: true},
			{Name: "usb1", Dir: true, State: vi.MountNotMounted, Kind: vi.MountKindFAT32, ReadOnly: true},
		}, 0
	}
	t.Cleanup(func() { mountRows = saved })
}

func TestVolumesRootListsKernelRowsAndNamesMountState(t *testing.T) {
	stubMounts(t, false)
	m := testModel()
	m.path = "/host"
	m.goUp()
	if m.path != volsPath {
		t.Fatalf("up from /host = %q, want the volumes root", m.path)
	}
	got := pendingJoined(&m)
	for _, want := range []string{
		markerCd + "/",
		markerList + "/ n=4",
		markerEntry + "host dir",
		markerEntry + "disk dir",
		markerEntry + "usb1 dir",
		markerVol + "host mounted rw",
		markerVol + "usb not_mounted",
		markerVolDiskAbsent,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("volumes listing missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, markerVolDiskMounted) {
		t.Fatal("an absent disk reported mounted")
	}
	// The kernel rows are the listing, in the table's order; the block
	// device row is not a directory, so its label carries no slash.
	labs := labelsOf(m.entries[:], m.n)
	want := []string{"host/", "disk/", "usb", "usb1/"}
	if len(labs) != len(want) {
		t.Fatalf("volume rows = %#v, want %#v", labs, want)
	}
	for i := range want {
		if labs[i] != want[i] {
			t.Fatalf("volume rows = %#v, want %#v", labs, want)
		}
	}
}

func TestVolumesEnterDiskRefusesByNameWhenUnmounted(t *testing.T) {
	stubMounts(t, false)
	m := testModel()
	m.showVolumes()
	m.sel = 1 // disk row
	m.openSel()
	if m.path != volsPath {
		t.Fatalf("entering an absent /disk moved to %q", m.path)
	}
	if m.status != "disk: not mounted" {
		t.Fatalf("status = %q", m.status)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerVolRefused+"disk not_mounted") {
		t.Fatalf("refusal marker missing: %q", got)
	}
}

func TestVolumesEnterDiskMountedAndBack(t *testing.T) {
	stubMounts(t, true)
	m := testModel()
	m.showVolumes()
	if got := pendingJoined(&m); !strings.Contains(got, markerVolDiskMounted) {
		t.Fatalf("mounted marker missing: %q", got)
	}
	m.sel = 1
	m.openSel()
	if m.path != diskRoot {
		t.Fatalf("enter disk = %q, want /disk", m.path)
	}
	got := pendingJoined(&m)
	if !strings.Contains(got, markerCd+"/disk") {
		t.Fatalf("cd marker missing: %q", got)
	}
	// The host DirList stub is ENOSYS, so the listing is the honest error
	// shape — the gate's mounted volume answers a real listing on VZ.
	m.goUp()
	if m.path != volsPath {
		t.Fatalf("up from /disk = %q, want the volumes root", m.path)
	}
}

func TestVolumesEnterUsbBlockRefusesByName(t *testing.T) {
	stubMounts(t, false)
	m := testModel()
	m.showVolumes()
	m.sel = 2 // the raw block row — not_mounted refuses by name
	m.openSel()
	if m.path != volsPath {
		t.Fatalf("entering an absent /usb moved to %q", m.path)
	}
	if got := pendingJoined(&m); !strings.Contains(got, markerVolRefused+"usb not_mounted") {
		t.Fatalf("block-row refusal marker missing: %q", got)
	}
}

func TestVolumesRootRefusesTheMutatingOps(t *testing.T) {
	stubMounts(t, false)
	m := testModel()
	m.showVolumes()
	m.drain()
	m.startRename()
	if m.mode == modeRename || m.status != "volumes: browse only" {
		t.Fatalf("rename on volumes = mode %v status %q", m.mode, m.status)
	}
	m.startDelete()
	if m.mode == modeConfirmDelete {
		t.Fatal("delete armed on a volume row")
	}
	m.yankClip(false)
	if len(m.clipSet) != 0 {
		t.Fatalf("a volume row was clipped: %v", m.clipSet)
	}
	m.clipSet = []string{"/host/FM/X.TXT"}
	m.pasteClip()
	if m.status != "volumes: browse only" {
		t.Fatalf("paste into volumes status = %q", m.status)
	}
	m.goUp()
	if m.path != volsPath || m.status != "at volumes root" {
		t.Fatalf("up at volumes = %q %q", m.path, m.status)
	}
}

func TestCrossVolumeMoveRefusedByName(t *testing.T) {
	m := testModel(entry("KNOWN.TXT", false))
	m.path = "/host/FM"
	m.clipSet = []string{"/disk/SEL/PHOTO.TXT"}
	m.clipCut = true
	m.pasteClip()
	if got := pendingJoined(&m); !strings.Contains(got, markerPasteNo+"PHOTO.TXT cross-volume") {
		t.Fatalf("cross-volume move refusal missing: %q", got)
	}
	if len(m.clipSet) == 0 {
		t.Fatal("a refused move dropped the held clip")
	}
}
