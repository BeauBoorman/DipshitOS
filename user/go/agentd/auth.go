// The Ed25519 handshake (ADR 0052 D2): 32 fresh challenge bytes per
// connection, a signature over the agent-domain message that binds the
// claimed id, and every sensitive buffer wiped after the verdict. The
// primitive is the virelai/ed25519 leaf — the same code sshlib and flint
// verify with, on a different domain so a captured SSH or FLINT
// signature can never answer this server.
package main

import "virelai/ed25519"

// agentDomain separates this channel's signatures from every other
// Ed25519 use (D2): a signed transcript from another service has no
// value here, and vice versa.
const agentDomain = "VIRELAI-AGENT/1 ed25519"

// challengeBytes is the per-connection nonce width.
const challengeBytes = 32

// agentChallenge draws 32 fresh bytes (slot 72). A short or failed draw is
// an error: greeting with a weak challenge is worse than refusing to.
func agentChallenge() ([challengeBytes]byte, bool) {
	var c [challengeBytes]byte
	n, err := randomFn(c[:])
	return c, err == nil && n == challengeBytes
}

// agentSignMsg builds the signed transcript:
// domain || 0x00 || challenge[32] || 0x00 || agent_id — the id is inside
// the signed message, so it cannot be swapped under a captured signature.
func agentSignMsg(challenge *[challengeBytes]byte, agentID string) []byte {
	msg := make([]byte, 0, len(agentDomain)+1+challengeBytes+1+len(agentID))
	msg = append(msg, agentDomain...)
	msg = append(msg, 0)
	msg = append(msg, challenge[:]...)
	msg = append(msg, 0)
	msg = append(msg, agentID...)
	return msg
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

// hexDecode is the strict decoder for the reply's signature field: 64
// bytes or nothing (the lowercase form the wire pins, uppercase accepted
// for parity with the keyring's strict rows).
func hexDecode(s string) ([]byte, bool) {
	if len(s)%2 != 0 {
		return nil, false
	}
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		hi, ok := hexVal(s[2*i])
		if !ok {
			return nil, false
		}
		lo, ok := hexVal(s[2*i+1])
		if !ok {
			return nil, false
		}
		out[i] = byte(hi)<<4 | byte(lo)
	}
	return out, true
}

// agentVerify runs the auth verdict: the signature must be Ed25519-valid
// over the domain message under the row's listed public key.
func agentVerify(sigHex string, challenge *[challengeBytes]byte, row *agentRow) bool {
	sig, ok := hexDecode(sigHex)
	if !ok || len(sig) != 64 {
		return false
	}
	var sigArr [64]byte
	copy(sigArr[:], sig)
	return ed25519.EdVerify(sigArr, agentSignMsg(challenge, row.id), row.pub)
}

// wipeBytes zeroes a sensitive buffer after its verdict is in.
func wipeBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

// hasCredential is the startup presence probe (posture check 2): the
// agent-hmac row stays — re-scoped from door key to the receipt key
// (ADR 0052 D4) — and a missing or mis-bound row is no-credential. The
// probe reads only whether the row is served, never the value.
func hasCredential() bool {
	var probe [1]byte
	return secretGetFn(secretName, probe[:]) >= 0
}
