// Small shared helpers for the leaf: hex decode and buffer wipe. Private
// on purpose — callers that need hex text use their own package's codec
// (sshlib/hex.go, flint's parseHex32Lower, agentd's keyring parser), the
// same split the rest of the Go tree already keeps.
package ed25519

// parseHex decodes lowercase-or-uppercase hex text into bytes, strict.
func parseHex(s string) ([]byte, bool) {
	if len(s)%2 != 0 {
		return nil, false
	}
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		hi, ok := nibble(s[2*i])
		if !ok {
			return nil, false
		}
		lo, ok := nibble(s[2*i+1])
		if !ok {
			return nil, false
		}
		out[i] = hi<<4 | lo
	}
	return out, true
}

func nibble(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// wipe zeroes a sensitive buffer after its verdict is in.
func wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
