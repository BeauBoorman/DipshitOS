package vi

// mounts_test.go — M134b (#2760): the mount-table decode and the named
// `not_mounted` refusal. Host-side: MountFromEntry is pure wire decode;
// Mounts itself is a syscall, stubbed through the DirList path only on
// the guest (the enumeration legs are the class-B gates' job).

import (
	"errors"
	"testing"
)

func TestMountFromEntryDecodesTheReservedTriple(t *testing.T) {
	var e DirEntry
	copy(e.Name[:], "usb1")
	e.IsDir = 1
	e.Reserved[0] = MountNotMounted
	e.Reserved[1] = MountKindFAT32
	e.Reserved[2] = MountFlagReadOnly
	m := MountFromEntry(e)
	if m.Name != "usb1" || !m.Dir || m.Mounted() || m.Kind != MountKindFAT32 || !m.ReadOnly {
		t.Fatalf("decoded mount = %#v", m)
	}
	if m.StateName() != "not_mounted" || m.KindName() != "fat32" || m.AccessName() != "ro" {
		t.Fatalf("names = %q %q %q", m.StateName(), m.KindName(), m.AccessName())
	}
}

func TestMountFromEntryMountedRwShare(t *testing.T) {
	var e DirEntry
	copy(e.Name[:], "host")
	e.IsDir = 1
	e.Reserved[0] = MountMounted
	e.Reserved[1] = MountKindShare
	m := MountFromEntry(e)
	if !m.Mounted() || m.StateName() != "mounted" || m.AccessName() != "rw" {
		t.Fatalf("mounted share = %#v", m)
	}
}

func TestMountErrNamesNotMounted(t *testing.T) {
	if err := MountErr(-ErrENXIO); !errors.Is(err, ErrNotMounted) {
		t.Fatalf("MountErr(-ENXIO) = %v, want not_mounted", err)
	}
	if MountErr(-ErrENXIO).Error() != "not_mounted" {
		t.Fatalf("the refusal's name is %q", MountErr(-ErrENXIO))
	}
	if err := MountErr(-ErrENOENT); !errors.Is(err, errno(ErrENOENT)) {
		t.Fatalf("MountErr(-ENOENT) = %v, want ENOENT", err)
	}
	if MountErr(0) != nil || MountErr(3) != nil {
		t.Fatal("a non-negative result is not an error")
	}
	if !IsNotMounted(ErrNotMounted) || !IsNotMounted(errno(ErrENXIO)) {
		t.Fatal("IsNotMounted must read both spellings")
	}
	if IsNotMounted(errno(ErrENOENT)) {
		t.Fatal("ENOENT is not not_mounted")
	}
}

func TestMountKindNameUnknown(t *testing.T) {
	m := Mount{Kind: 99}
	if m.KindName() != "?" {
		t.Fatalf("unknown kind = %q", m.KindName())
	}
}
