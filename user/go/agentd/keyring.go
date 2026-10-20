// The agent keyring (ADR 0052 D1): /host/AGENTS.TXT holds one
// `agent=<id> key=<64 lowercase hex Ed25519 public key> caps=<csv>` row
// per agent plus `revoked=<64 hex>` rows, in the TRUSTED.TXT shape
// (user/go/flint/keyring.go). The file is host-provisioned, uid_system
// owned and world-readable — public keys are data, not secrets; the
// private halves never enter the guest. Grammar is fail-closed
// whole-file: a trust file is never half-read.
package main

import (
	"strings"

	"virelai/vi"
)

const (
	keyringPath   = "/host/AGENTS.TXT"
	keyringHeader = "#v1"
	// keyringMax bounds the file: a row is ~150 bytes, so 64 KiB holds
	// far more than the row bounds below allow.
	keyringMax  = 64 * 1024
	keyringRows = 64 // ≤ 64 agent= rows and ≤ 64 revoked= rows (D1)
	agentIDMax  = 32 // the agent id is a NAME (D1)
)

// capVocabulary is the apps.txt/WASM Cap word set (ADR 0052 D3). An
// unknown word makes the whole file malformed — a caps row is never
// half-granted.
var capVocabulary = map[string]bool{
	"file": true, "window": true, "audio": true, "timer": true,
	"memory": true, "process": true, "debug": true, "net": true,
	"term": true, "input": true, // M139b: input drives the focused pane
}

// agentRow is one listed credential: the claimed id, the Ed25519 public
// key the handshake verifies against, and the declared caps the session
// resolves onto its verb set.
type agentRow struct {
	id   string
	pub  [32]byte
	caps map[string]bool
	list []string // caps in declared order, for the ready line
}

// agents is a decoded AGENTS.TXT: agent rows by id plus the revoked set.
// Revocation wins over listing — a listed-and-revoked key is revoked.
type agents struct {
	byID    map[string]*agentRow
	revoked map[[32]byte]bool
}

// lookup returns the row an id claims, or nil — the agent_unknown case.
func (a *agents) lookup(id string) *agentRow {
	return a.byID[id]
}

// keyringParse decodes an AGENTS.TXT body: ok=false means the file is
// malformed and must be refused whole. Blank lines and `#` comments are
// skipped; every other row must match the grammar exactly.
func keyringParse(b []byte) (*agents, bool) {
	lines := strings.Split(string(b), "\n")
	if len(lines) == 0 || strings.TrimSuffix(lines[0], "\r") != keyringHeader {
		return nil, false
	}
	kr := &agents{
		byID:    map[string]*agentRow{},
		revoked: map[[32]byte]bool{},
	}
	byPub := map[[32]byte]bool{}
	nAgent, nRevoked := 0, 0
	for _, raw := range lines[1:] {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		switch {
		case strings.HasPrefix(fields[0], "agent="):
			if len(fields) < 2 || len(fields) > 3 || !strings.HasPrefix(fields[1], "key=") {
				return nil, false
			}
			id := fields[0][len("agent="):]
			if !validAgentID(id) {
				return nil, false
			}
			pub, ok := parseHex32Lower(fields[1][len("key="):])
			if !ok {
				return nil, false
			}
			row := &agentRow{id: id, pub: pub, caps: map[string]bool{}}
			if len(fields) == 3 {
				if !strings.HasPrefix(fields[2], "caps=") {
					return nil, false
				}
				list, ok := parseCaps(fields[2][len("caps="):])
				if !ok {
					return nil, false
				}
				row.list = list
				for _, c := range list {
					row.caps[c] = true
				}
			}
			if kr.byID[id] != nil || byPub[pub] {
				return nil, false // a duplicate id or key fails the file
			}
			if nAgent++; nAgent > keyringRows {
				return nil, false
			}
			kr.byID[id] = row
			byPub[pub] = true
		case strings.HasPrefix(fields[0], "revoked="):
			if len(fields) != 1 {
				return nil, false
			}
			pub, ok := parseHex32Lower(fields[0][len("revoked="):])
			if !ok {
				return nil, false
			}
			if kr.revoked[pub] {
				return nil, false
			}
			if nRevoked++; nRevoked > keyringRows {
				return nil, false
			}
			kr.revoked[pub] = true
		default:
			return nil, false
		}
	}
	return kr, true
}

// validAgentID is the D1 id shape: 1-32 NAME bytes.
func validAgentID(s string) bool {
	return len(s) > 0 && len(s) <= agentIDMax && validName(s)
}

// parseCaps decodes a caps= csv. Absent ("") is an empty, valid set; a
// word outside the vocabulary or a duplicate fails the row.
func parseCaps(csv string) ([]string, bool) {
	if csv == "" {
		return nil, true
	}
	var out []string
	seen := map[string]bool{}
	for _, w := range strings.Split(csv, ",") {
		if !capVocabulary[w] || seen[w] {
			return nil, false
		}
		seen[w] = true
		out = append(out, w)
	}
	return out, true
}

// parseHex32Lower decodes exactly 32 bytes of lowercase hex.
func parseHex32Lower(s string) ([32]byte, bool) {
	var out [32]byte
	if len(s) != 64 {
		return out, false
	}
	for i := 0; i < 32; i++ {
		hi, ok1 := hexValLower(s[2*i])
		lo, ok2 := hexValLower(s[2*i+1])
		if !ok1 || !ok2 {
			return out, false
		}
		out[i] = hi<<4 | lo
	}
	return out, true
}

func hexValLower(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	}
	return 0, false
}

// keyringLoad reads and parses the keyring at session scope (the D6
// per-session resolution): code "" with a parsed table, "missing" when
// the file is absent, "malformed" when it fails to read or parse whole.
func keyringLoad() (*agents, string) {
	b, r := readFileFn(keyringPath, keyringMax+1)
	if r < 0 {
		if vi.ErrnoName(r) == "ENOENT" {
			return nil, "missing"
		}
		return nil, "malformed"
	}
	if len(b) > keyringMax {
		return nil, "malformed"
	}
	kr, ok := keyringParse(b)
	if !ok {
		return nil, "malformed"
	}
	return kr, ""
}
