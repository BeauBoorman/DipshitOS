// The HMAC-SHA256 handshake (ADR 0044 D2): 32 fresh challenge bytes per
// connection, MAC over the agent-domain message, constant-time compare,
// and every sensitive buffer wiped after the verdict. The primitive is
// shlib.HMACSHA256 — the same code the net front-end verifies with, on a
// different domain so a captured GOSH MAC can never answer this server.
package main

import (
	"virelai/shlib"
	"virelai/vi"
)

// agentDomain separates this channel's MACs from VIRELAIOS-AUTH/1 (D2):
// a net-hmac transcript has no value here, and vice versa.
const agentDomain = "VIRELAI-AGENT/1 hmac-sha256"

// challengeBytes is the per-connection nonce width.
const challengeBytes = 32

// agentChallenge draws 32 fresh bytes (slot 72). A short or failed draw is
// an error: greeting with a weak challenge is worse than refusing to.
func agentChallenge() ([32]byte, bool) {
	var c [challengeBytes]byte
	n, err := randomFn(c[:])
	return c, err == nil && n == challengeBytes
}

// agentMAC computes HMAC-SHA256(key, domain || 0x00 || challenge).
func agentMAC(key []byte, challenge *[challengeBytes]byte) [32]byte {
	var msg [len(agentDomain) + 1 + challengeBytes]byte
	copy(msg[:], agentDomain)
	copy(msg[len(agentDomain)+1:], challenge[:])
	return shlib.HMACSHA256(key, msg[:])
}

func hexEnc(dst, src []byte) {
	for i, b := range src {
		dst[i*2] = hexDigits[b>>4]
		dst[i*2+1] = hexDigits[b&0xf]
	}
}

func hexString(src []byte) string {
	b := make([]byte, len(src)*2)
	hexEnc(b, src)
	return string(b)
}

// ctEqStr is the constant-time compare the verdict runs on the two
// lowercase-hex MACs (the same shape shlib's ctEq uses internally).
func ctEqStr(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := 0; i < len(a); i++ {
		v |= a[i] ^ b[i]
	}
	return v == 0
}

// wipeBytes zeroes a sensitive buffer after its verdict is in.
func wipeBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

// loadKey reads the app-bound agent-hmac secret (slot 70). The kernel only
// serves the row to the image OWNERS.TXT binds it to, so a missing or
// mis-bound credential is indistinguishable here — both are no-credential
// (run 07). The value is used byte-for-byte as stored, and the caller
// wipes it after the verdict (D2).
func loadKey() ([]byte, bool) {
	key := make([]byte, vi.SecretValMax)
	n := secretGetFn(secretName, key)
	if n <= 0 {
		wipeBytes(key)
		return nil, false
	}
	return key[:n], true
}

// hasCredential is the startup presence probe (posture check 2): it reads
// only whether the row is served, never the value.
func hasCredential() bool {
	var probe [1]byte
	return secretGetFn(secretName, probe[:]) >= 0
}
