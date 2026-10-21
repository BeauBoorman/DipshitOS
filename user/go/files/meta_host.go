//go:build !virelai

package main

import "os"

// fileMtime off the guest is the host's real mtime, so tests exercise the
// QuickLook card arm against temp files exactly as the guest does against
// the slot-79 stat wire.
func fileMtime(path string) (int64, bool) {
	st, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	return st.ModTime().UnixNano(), true
}
