//go:build !virelai

package main

import "errors"

// Host stub: there is no guest exec off the guest. Unit tests substitute the
// execAndWait seam; a host Build reaching this is a bug, reported by name.
func execAndWaitGuest(image string, args []string, capturePath string) (status int64, ms int64, captured []byte, err error) {
	return -1, 0, nil, errors.New("gobuild: no guest exec off virelai")
}
