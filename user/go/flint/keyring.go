// Publisher keyring — M101b (#2314): the pinned publisher-key file at
// <root>/TRUSTED.TXT (/host/FLINT/TRUSTED.TXT on the default store root).
// It is the guest's own trust decision: flintd verifies Ed25519 signatures
// but holds no opinion about WHICH publisher key may sign (flint-server
// spec §0 — the server holds no secrets). clone/pull refuse by name before
// materializing anything, and `flint verify --remote` runs the same gate.
//
// The file is schema-v2 style in the M66b posture — refused whole when
// corrupt (a trust file is never half-read):
//
//	#v1
//	key=<64 lowercase hex Ed25519 public key> name=<label>
//	revoked=<64 lowercase hex>
//
// `#v1` is the only accepted header; blank lines and `#` comments are
// skipped; every other row must match the grammar exactly. A `revoked=`
// row invalidates the key for NEW Changes — installed content stays
// (rollback is M101d). Public keys are data, not secrets: the file lives
// on the share, never in the slot-70 lane (contrast `flint-remote`).
package main

import (
	"strings"
)

const (
	keyringFileName = "TRUSTED.TXT"
	keyringHeader   = "#v1"
	// maxKeyringBytes bounds the pinned file: a row is ~110 bytes, so this
	// holds hundreds of publisher keys with room to spare.
	maxKeyringBytes = 64 * 1024
	// keyringMaxLabel bounds the name= label on a key row.
	keyringMaxLabel = 64
)

// Keyring is a decoded TRUSTED.TXT: pinned publisher public keys with
// labels, plus the revoked set. Revocation wins over listing.
type Keyring struct {
	keys    map[[32]byte]string
	revoked map[[32]byte]bool
}

func keyringPath(root string) string { return root + "/" + keyringFileName }

// LoadKeyring reads and parses <root>/TRUSTED.TXT. An absent file refuses
// keyring_missing — v1 is pinned-keys-only with no TOFU fallback, so no
// keyring means no publisher is trusted. A corrupt file refuses
// keyring_malformed whole.
func LoadKeyring(fs FS, root string) (*Keyring, error) {
	p := keyringPath(root)
	if !fs.Exists(p) {
		return nil, refuse("keyring_missing", "")
	}
	b, err := fs.ReadFile(p, maxKeyringBytes)
	if err != nil {
		return nil, err
	}
	return ParseKeyring(b)
}

// ParseKeyring decodes a TRUSTED.TXT body. Any deviation — a missing or
// newer `#v` header, an unknown row, a short/long/non-hex key, a duplicate
// row — refuses the whole file with keyring_malformed.
func ParseKeyring(b []byte) (*Keyring, error) {
	malformed := func(line string) (*Keyring, error) {
		return nil, refuse("keyring_malformed", line)
	}
	lines := strings.Split(string(b), "\n")
	if len(lines) == 0 || strings.TrimSuffix(lines[0], "\r") != keyringHeader {
		return malformed(strings.TrimSuffix(lines[0], "\r"))
	}
	kr := &Keyring{
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

// CheckAuthor is the per-Change trust gate: the author key must be pinned
// and not revoked. Returns nil when trusted, else a named refusal —
// key_revoked when a revoked= row names the key (it may also be listed;
// revocation invalidates it for new Changes either way), key_unknown when
// the key is simply not in the keyring.
func (k *Keyring) CheckAuthor(authorHex string) error {
	pub, ok := parseHex32Lower(authorHex)
	if !ok {
		return refuse("key_unknown", authorHex)
	}
	if k.revoked[pub] {
		if name := k.keys[pub]; name != "" {
			return refuse("key_revoked", name)
		}
		return refuse("key_revoked", authorHex)
	}
	if _, ok := k.keys[pub]; !ok {
		return refuse("key_unknown", authorHex)
	}
	return nil
}
