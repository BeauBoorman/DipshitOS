package store

import (
	"bytes"
	"encoding/json"
	"strings"
)

// STORE is the M101c (#2315) install seam: a pulled release stream becomes
// a running app. The release-stream convention (owner-decided option C,
// flint-client#48) is specified by ADR 0055 (docs/decisions/0055-*.md),
// which is the authority when this comment and the code disagree:
//
//   - A "release stream" is a FLINT stream whose folded head state covers
//     a file `release.go` declaring four consts: ReleaseName (the
//     installed ELF stem), ReleaseVersion, ReleaseELFSHA256 (SHA-256 of
//     the delivered ELF), and ReleaseManifestRow (the schema-v2 APPS.TXT
//     row the installer writes). ADR 0055 D3 adds the optional signed
//     catalog consts ReleaseSummary/ReleaseDescription/ReleaseCategory/
//     ReleaseIconSHA256, D5 derives the publisher fingerprint from the
//     head Change's author key — never from a manifest const, D8 adds
//     ReleaseDepends (the releases install resolves first), and D9's
//     per-head member <stream>/<head-change-hex>/ carries the bytes a
//     `store pin` to a prior signed head verifies against.
//   - A release is a signed Change touching release.go. The Change
//     signature plus each Op's new_hash authenticates the atom text, so
//     the manifest consts are authenticated end to end by the M101b
//     keyring path.
//   - release.go and the ELF travel an UNTRUSTED channel — a share drop
//     dir or a cleartext HTTP relay — never the FLINT wire (FLINT stores
//     structure, not bytes; blob transport is FLINT M1, out of scope).
//     STORE re-parses release.go, matches every parsed atom to the signed
//     folded ops, fetches the ELF, matches sha256(ELF) to the signed
//     ReleaseELFSHA256, and ONLY then publishes the ELF and the manifest
//     row through WriteFileSafe.
//
// FLINT.ELF owns the sync + keyring + signature gate (M101a/b): STORE
// execs it directly (`vi.Exec`/`vi.Wait`), and the child's console lines
// reach serial verbatim — a refused verb's `flint: refuse <name>` prints
// before STORE's own `store: refuse sync_failed`. Nesting through
// `GOSH.ELF -c` was abandoned: four concurrent Go runtimes overflow the
// kernel's task pool (see execFn). `store ls` still needs remote
// enumeration, so wire.go carries a minimal hello/auth/list client —
// the smallest wire surface that keeps STORE under a shell.
//
// These types mirror the JSON shapes user/go/flint writes into
// /host/FLINT/ (the byte-portable store contract — flintd and FLINT.ELF
// read the same files). Duplicated by necessity: flint is a main package.

const (
	// DefaultStoreRoot is the FLINT store root FLINT.ELF uses.
	DefaultStoreRoot = "/host/FLINT"
	// DefaultChannel is the share-drop directory a publisher fills with
	// <stream>/release.go and <stream>/<NAME>.ELF.
	DefaultChannel = "/host/DROP"
	// MaxFileReadBytes bounds manifest/keyring-class reads.
	MaxFileReadBytes = 4 * 1024 * 1024
	// MaxReleaseBytes bounds the fetched release.go: four const decls are
	// a few hundred bytes; 64 KiB is far past honest and keeps a hostile
	// channel from staging a memory soak.
	MaxReleaseBytes = 64 * 1024
	// MaxELFBytes is the kernel's exec_image_max: an ELF larger than this
	// could never launch, so refuse before writing it.
	MaxELFBytes = 32 * 1024 * 1024
	// MaxStreamLogBytes bounds streams/<id>.jsonl reads.
	MaxStreamLogBytes = MaxFileReadBytes
	// MaxChanges mirrors flint's change bound.
	MaxChanges = 4096
)

// Stream is the JSON record at <root>/streams/<id>.json.
type Stream struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	Head       *string `json:"head"`
	Created    int64   `json:"created"`
	ForkedFrom *struct {
		Stream string `json:"stream"`
		Change string `json:"change"`
	} `json:"forked_from"`
}

// Span locates an atom inside a source file relative to the src root.
type Span struct {
	File  string `json:"file"`
	Start uint32 `json:"start"`
	End   uint32 `json:"end"`
}

// Op is one operation inside a signed Change.
type Op struct {
	Type       string `json:"type"`
	AtomID     string `json:"atom_id"`
	Kind       string `json:"kind,omitempty"`
	NewName    string `json:"new_name,omitempty"`
	NewSpan    *Span  `json:"new_span,omitempty"`
	NewHash    string `json:"new_hash,omitempty"`
	NewSigHash string `json:"new_sig_hash,omitempty"`
	OldHash    string `json:"old_hash,omitempty"`
}

// Change is one signed JSONL line in streams/<id>.jsonl.
type Change struct {
	ID      string  `json:"id"`
	Parent  *string `json:"parent"`
	Stream  string  `json:"stream"`
	TS      int64   `json:"ts"`
	Author  string  `json:"author"`
	Message string  `json:"message"`
	Ops     []Op    `json:"ops"`
	Merged  *string `json:"merged"`
	Sig     string  `json:"sig"`
}

// RemoteConfig is the <root>/REMOTE.json binding clone/pull/push write.
type RemoteConfig struct {
	Remote string `json:"remote"`
	Stream string `json:"stream"`
}

func streamRecordPath(root, id string) string { return root + "/streams/" + id + ".json" }
func streamLogPath(root, id string) string    { return root + "/streams/" + id + ".jsonl" }
func remoteConfigPath(root string) string     { return root + "/REMOTE.json" }

// readJSONLLines splits a JSONL payload and enforces the ADR 0049
// torn-append rule: a non-empty payload whose last byte is not '\n' is
// refused stream_torn.
func readJSONLLines(data []byte) ([][]byte, error) {
	if len(data) == 0 {
		return nil, nil
	}
	if data[len(data)-1] != '\n' {
		return nil, refuse("stream_torn", "")
	}
	trimmed := data[:len(data)-1]
	lines := bytes.Split(trimmed, []byte{'\n'})
	for _, line := range lines {
		if len(line) == 0 {
			return nil, refuse("change_malformed", "")
		}
	}
	return lines, nil
}

// loadRemoteConfig reads <root>/REMOTE.json when present (nil when absent),
// refusing remote_malformed on a corrupt body.
func loadRemoteConfig(fs FS, root string) (*RemoteConfig, error) {
	p := remoteConfigPath(root)
	if !fs.Exists(p) {
		return nil, nil
	}
	b, err := fs.ReadFile(p, MaxFileReadBytes)
	if err != nil {
		return nil, err
	}
	var rc RemoteConfig
	if err := json.Unmarshal(b, &rc); err != nil || rc.Remote == "" {
		return nil, refuse("remote_malformed", "")
	}
	return &rc, nil
}

// listStreamRecords scans <root>/streams for *.json records, refusing
// stream_malformed on any corrupt one — the store is never half-read.
// Returns (byName, byID).
func listStreamRecords(fs FS, root string) (map[string]*Stream, map[string]*Stream, error) {
	byID := map[string]*Stream{}
	byName := map[string]*Stream{}
	sDir := root + "/streams"
	if !fs.Exists(sDir) {
		return byName, byID, nil
	}
	entries, err := fs.List(sDir)
	if err != nil {
		return nil, nil, err
	}
	for _, e := range entries {
		if e.IsDir || !strings.HasSuffix(e.Name, ".json") {
			continue
		}
		b, err := fs.ReadFile(sDir+"/"+e.Name, MaxFileReadBytes)
		if err != nil {
			return nil, nil, err
		}
		var st Stream
		if err := json.Unmarshal(b, &st); err != nil || st.ID == "" || st.Name == "" {
			return nil, nil, refuse("stream_malformed", e.Name)
		}
		byID[st.ID] = &st
		byName[st.Name] = &st
	}
	return byName, byID, nil
}

// streamLogBytes returns the raw streams/<id>.jsonl payload — nil when
// the log does not exist.
func streamLogBytes(fs FS, root, streamID string) ([]byte, error) {
	p := streamLogPath(root, streamID)
	if !fs.Exists(p) {
		return nil, nil
	}
	return fs.ReadFile(p, MaxStreamLogBytes)
}

// parseStreamChanges parses a raw JSONL payload into Changes (JSON only
// — the caller binds these bytes into `verify --all --trusted
// --expect`, whose publisher-keyring + Ed25519 gate runs in FLINT.ELF
// before they are folded).
func parseStreamChanges(b []byte) ([]Change, error) {
	lines, err := readJSONLLines(b)
	if err != nil {
		return nil, err
	}
	if len(lines) > MaxChanges {
		return nil, refuse("store_too_large", "changes")
	}
	changes := make([]Change, 0, len(lines))
	for _, line := range lines {
		var c Change
		if err := json.Unmarshal(line, &c); err != nil || c.ID == "" || c.Stream == "" || c.Ops == nil {
			return nil, refuse("change_malformed", "")
		}
		changes = append(changes, c)
	}
	return changes, nil
}
