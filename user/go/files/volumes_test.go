package main

// volumes_test.go — M100f (#2311): the synthetic volumes root. Host tests
// pin the listing markers, the mount probe's both legs, the named enter
// refusal, and the mutating-op guards; the real /disk listings are the
// live-vlfs-dataroot class-B's job.

import (
	"strings"
	"testing"
)

// stubMounted pins the /disk probe for one test and restores it.
func stubMounted(t *testing.T, mounted bool) {
	t.Helper()
	saved := diskMounted
	diskMounted = func() bool { return mounted }
	t.Cleanup(func() { diskMounted = saved })
}

func TestVolumesRootListsBothVolumesAndNamesMountState(t *testing.T) {
	stubMounted(t, false)
	m := testModel()
	m.path = "/host"
	m.goUp()
	if m.path != volsPath {
		t.Fatalf("up from /host = %q, want the volumes root", m.path)
	}
	got := pendingJoined(&m)
	for _, want := range []string{
		markerCd + "/",
		markerList + "/ n=2",
		markerEntry + "host dir",
		markerEntry + "disk dir",
		markerVolDiskAbsent,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("volumes listing missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, markerVolDiskMounted) {
		t.Fatal("an absent disk reported mounted")
	}
	// The mount names are the rows, and they are directories.
	labs := labelsOf(m.entries[:], m.n)
	if len(labs) != 2 || labs[0] != "host/" || labs[1] != "disk/" {
		t.Fatalf("volume rows = %#v", labs)
	}
}

func TestVolumesEnterDiskRefusesByNameWhenUnmounted(t *testing.T) {
	stubMounted(t, false)
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
	stubMounted(t, true)
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

func TestVolumesRootRefusesTheMutatingOps(t *testing.T) {
	stubMounted(t, false)
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
	if m.clip != "" {
		t.Fatalf("a volume row was clipped: %q", m.clip)
	}
	m.clip = "/host/FM/X.TXT"
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
	m.clip = "/disk/SEL/PHOTO.TXT"
	m.clipCut = true
	m.pasteClip()
	if got := pendingJoined(&m); !strings.Contains(got, markerPasteNo+"PHOTO.TXT cross-volume") {
		t.Fatalf("cross-volume move refusal missing: %q", got)
	}
	if m.clip == "" {
		t.Fatal("a refused move dropped the held clip")
	}
}
