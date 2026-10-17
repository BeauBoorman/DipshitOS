package store

import (
	"encoding/hex"
	"strings"
)

// STORE's read of the publisher keyring at <root>/TRUSTED.TXT — a
// duplicated-by-necessity port of user/go/flint/keyring.go (flint is a
// main package; the grammars must stay in lockstep). FLINT.ELF owns the
// enforcement half — the M101b CheckAuthor gate runs inside it at
// materialization. STORE reads the same file only to LABEL a derived
// publisher fingerprint (ADR 0055 D5): the catalog reports which key
// signed the head Change and whether the keyring pins, revokes, or does
// not know it. A missing or corrupt keyring is not a refusal here — the
// catalog marks every publisher "unverified" instead of inventing trust.
//
// File grammar (schema-v2 posture — refused whole when corrupt):
//
//	#v1
//	key=<64 lowercase hex Ed25519 public key> name=<label>
//	revoked=<64 lowercase hex>
const (
	keyringFileName = "TRUSTED.TXT"
	keyringHeader   = "#v1"
	// maxKeyringBytes bounds the pinned file: a row is ~110 bytes, so this
	// holds hundreds of publisher keys with room to spare.
	maxKeyringBytes = 64 * 1024
	// keyringMaxLabel bounds the name= label on a key row.
	keyringMaxLabel = 64
)

// keyring is a decoded TRUSTED.TXT: pinned publisher public keys with
// labels, plus the revoked set.
type keyring struct {
	keys    map[[32]byte]string
	revoked map[[32]byte]bool
}

func keyringPath(root string) string { return root + "/" + keyringFileName }

// loadKeyring reads and parses <root>/TRUSTED.TXT, refusing
// keyring_missing when absent and keyring_malformed when corrupt.
func loadKeyring(fs FS, root string) (*keyring, error) {
	p := keyringPath(root)
	if !fs.Exists(p) {
		return nil, refuse("keyring_missing", "")
	}
	b, err := fs.ReadFile(p, maxKeyringBytes)
	if err != nil {
		return nil, err
	}
	return parseKeyring(b)
}

// parseKeyring decodes a TRUSTED.TXT body; any deviation refuses the
// whole file with keyring_malformed.
func parseKeyring(b []byte) (*keyring, error) {
	malformed := func(line string) (*keyring, error) {
		return nil, refuse("keyring_malformed", line)
	}
	lines := strings.Split(string(b), "\n")
	if len(lines) == 0 || strings.TrimSuffix(lines[0], "\r") != keyringHeader {
		return malformed(strings.TrimSuffix(lines[0], "\r"))
	}
	kr := &keyring{
		keys:    map[[32]byte]string{},
		revoked: map[[32]byte]bool{},
	}
	for _, raw := range lines[1:] {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		switch {
		case strings.HasPrefix(fields[0], "key="):
			if len(fields) != 2 || !strings.HasPrefix(fields[1], "name=") {
				return malformed(line)
			}
			name := fields[1][len("name="):]
			pub, ok := parseHex32Lower(fields[0][len("key="):])
			if !ok || name == "" || len(name) > keyringMaxLabel {
				return malformed(line)
			}
			if _, dup := kr.keys[pub]; dup {
				return malformed(line)
			}
			kr.keys[pub] = name
		case strings.HasPrefix(fields[0], "revoked="):
			if len(fields) != 1 {
				return malformed(line)
			}
			pub, ok := parseHex32Lower(fields[0][len("revoked="):])
			if !ok {
				return malformed(line)
			}
			if kr.revoked[pub] {
				return malformed(line)
			}
			kr.revoked[pub] = true
		default:
			return malformed(line)
		}
	}
	return kr, nil
}

// publisherState classifies a head-Change author key against the
// keyring (ADR 0055 D5): "trusted" with the name= label when pinned,
// "revoked" when a revoked= row names it, "unknown" otherwise. The label
// is the only trusted display name a publisher has.
func (k *keyring) publisherState(authorHex string) (state, label string) {
	pub, ok := parseHex32Lower(authorHex)
	if !ok {
		return "unknown", ""
	}
	if k.revoked[pub] {
		return "revoked", ""
	}
	if name, ok := k.keys[pub]; ok {
		return "trusted", name
	}
	return "unknown", ""
}

// parseHex32Lower decodes 64 lowercase hex chars into a key.
func parseHex32Lower(s string) ([32]byte, bool) {
	var out [32]byte
	if !isLowerHexN(s, 64) {
		return out, false
	}
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != 32 {
		return out, false
	}
	copy(out[:], b)
	return out, true
}
