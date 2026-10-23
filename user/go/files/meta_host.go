//go:build !virelai

package main

import (
	"os"
	"syscall"
)

// fileTimes off the guest is the host's real stat — mtime and ctime for
// temp files exactly as the guest reads them off the slot-79 stat wire,
// so tests exercise the card arms without a kernel. A platform whose
// Stat_t carries no ctime reports the stamp absent, never a copy of the
// mtime.
func fileTimes(path string) (mt, ct int64, mtOK, ctOK bool) {
	st, err := os.Stat(path)
	if err != nil {
		return 0, 0, false, false
	}
	mt = st.ModTime().UnixNano()
	if sb, ok := st.Sys().(*syscall.Stat_t); ok {
		ct = sb.Ctimespec.Sec*1e9 + sb.Ctimespec.Nsec
		ctOK = ct != 0
	}
	return mt, ct, mt != 0, ctOK
}

// fileOwner off the guest is the host's real stat uid — the honest owner
// for the temp fixtures the host tests stat; a failed stat reports absent.
func fileOwner(path string) (uint32, bool) {
	st, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	if sb, ok := st.Sys().(*syscall.Stat_t); ok {
		return sb.Uid, true
	}
	return 0, false
}
