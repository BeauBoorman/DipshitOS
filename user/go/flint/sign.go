package main

import (
	"virelai/shlib"
	"virelai/sshlib"
	"virelai/vi"
)

const secretAgentSign = "agent-sign"

// storeGetFn is the slot-70 secret lookup seam; tests replace it without
// touching the kernel store.
var storeGetFn = shlib.StoreGet

// loadSeed reads the 64-hex-character (32-byte) Ed25519 seed from the
// app-bound `agent-sign` secret entry (slot 70). The raw buffer is wiped
// before returning, and the seed is never logged.
func loadSeed() ([32]byte, error) {
	var seed [32]byte
	var raw [vi.SecretValMax]byte
	defer sshlib.Wipe(raw[:])

	n := storeGetFn(secretAgentSign, raw[:])
	if n < 0 {
		return seed, refuse("secret_not_found", "")
	}
	if n != 64 {
		return seed, refuse("secret_malformed", "")
	}
	for i := 0; i < 32; i++ {
		hi, ok1 := lowerNibble(raw[2*i])
		lo, ok2 := lowerNibble(raw[2*i+1])
		if !ok1 || !ok2 {
			sshlib.Wipe(seed[:])
			return [32]byte{}, refuse("secret_malformed", "")
		}
		seed[i] = (hi << 4) | lo
	}
	return seed, nil
}

func lowerNibble(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	default:
		return 0, false
	}
}

// signChangeWithSeed sets c.Author from EdDerivePublic(seed), computes sig_msg,
// sets c.Sig from EdSign(sig_msg, seed), and wipes the caller's seed slice.
func signChangeWithSeed(c *Change, seed []byte) error {
	var seedArr [32]byte
	copy(seedArr[:], seed)
	defer func() {
		sshlib.Wipe(seedArr[:])
		sshlib.Wipe(seed)
	}()

	pub := sshlib.EdDerivePublic(seedArr)
	c.Author = sshlib.EncodeHex(pub[:])

	sorted := make([]Op, len(c.Ops))
	copy(sorted, c.Ops)
	sortOps(sorted)
	c.Ops = sorted

	msg, err := sigMsg(c)
	if err != nil {
		return err
	}
	sig := sshlib.EdSign(msg, seedArr)
	c.Sig = sshlib.EncodeHex(sig[:])
	return nil
}
