// Compat shims (M109b #2398): the Ed25519 primitives moved to the
// virelai/ed25519 leaf (ADR 0052 D8) but the historical sshlib.Ed* names
// stay as thin aliases while straggling callers repoint — user/go/store's
// fixture generator is claimed by another card and must keep compiling
// untouched.
package sshlib

import "virelai/ed25519"

// EdDerivePublic is ed25519.EdDerivePublic.
func EdDerivePublic(seed [32]byte) [32]byte { return ed25519.EdDerivePublic(seed) }

// EdSign is ed25519.EdSign.
func EdSign(msg []byte, seed [32]byte) [64]byte { return ed25519.EdSign(msg, seed) }

// EdVerify is ed25519.EdVerify.
func EdVerify(sig [64]byte, msg []byte, pub [32]byte) bool {
	return ed25519.EdVerify(sig, msg, pub)
}
