// Package main — GOTOP's mounts tab (M134b, issue #2760): the kernel's one
// mount table. sys_dir_list("/") enumerates the rows — name, kind, live
// state, read-only flag — the same enumeration GOFILES' volumes root
// reads, so the monitor and the file manager never disagree about what is
// attached. An absent volume's row says `not_mounted` by name; the raw
// /usb block row is not a directory, and the tab says so too.
package main

import "virelai/vi"

// MountView is the mounts-tab state — the kernel mount table sampled via
// vi.Mounts (slot 27's "/" enumeration; no new syscall).
type MountView struct {
	Rows      []vi.Mount
	OK        bool
	refreshed bool
	rc        int64
}

// mountRows is the deliberate injection seam — vi.Mounts on the guest, a
// stub in host tests (the same discipline gpuSampleStats keeps).
var mountRows = vi.Mounts

// NewMountView builds an empty view (safe defaults: no sample yet).
func NewMountView() *MountView { return &MountView{} }

// Refresh re-enumerates the mount table. A refusal keeps the errno — the
// tab says why rather than painting an empty table as if it were real.
func (v *MountView) Refresh() {
	v.refreshed = true
	rows, rc := mountRows()
	if rc < 0 {
		v.Rows = nil
		v.OK = false
		v.rc = rc
		return
	}
	v.Rows = rows
	v.OK = true
	v.rc = 0
}

// mountErrText names a listing refusal for the error row/marker.
func mountErrText(rc int64) string {
	if err := vi.MountErr(rc); err != nil {
		return err.Error()
	}
	return "?"
}

// mountRowText is one table line — the name, kind, state, and flags the
// kernel put on the wire.
func mountRowText(m vi.Mount) string {
	line := m.Name
	for len(line) < 7 {
		line += " "
	}
	line += " " + m.KindName()
	for len(line) < 15 {
		line += " "
	}
	line += " " + m.StateName()
	for len(line) < 27 {
		line += " "
	}
	line += " " + m.AccessName()
	if m.Kind == vi.MountKindBlock {
		line += " (block device)"
	}
	return line
}

// Lines is the tab's text, one entry per row.
func (v *MountView) Lines() []string {
	if !v.refreshed {
		return []string{"mounts: not sampled"}
	}
	if !v.OK {
		return []string{"mounts: list refused (" + mountErrText(v.rc) + ")"}
	}
	out := []string{"mount table   sys_dir_list(\"/\")", "",
		"name    kind    state        flags"}
	for _, m := range v.Rows {
		out = append(out, mountRowText(m))
	}
	return out
}

// Marker is the serial line the gate asserts: the row count after the
// enumeration returned, or the named refusal.
func (v *MountView) Marker() string {
	if !v.OK {
		return "top: mounts err=" + mountErrText(v.rc)
	}
	return "top: mounts n=" + vi.Itoa64(int64(len(v.Rows)))
}

// RowMarker is the bounded per-row serial dump — the same evidence shape
// printRows emits for the procs tab.
func (v *MountView) RowMarker(i int) (string, bool) {
	if i < 0 || i >= len(v.Rows) {
		return "", false
	}
	m := v.Rows[i]
	return "top: mount " + m.Name + " state=" + m.StateName() +
		" kind=" + m.KindName() + " flags=" + m.AccessName(), true
}
