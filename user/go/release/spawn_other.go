//go:build !virelai

package main

import "errors"

// Host stubs: there is no guest exec off virelai. Tests substitute the
// seams directly; a host run reaching these is reported by name.
func spawnAndWait(image string, args []string, budgetNs int64) (int64, error) {
	return -1, errors.New("release: no guest exec off virelai")
}

func waitChild(pid int64, budgetNs int64) (int64, error) {
	return -1, errors.New("release: no guest wait off virelai")
}
