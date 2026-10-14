package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"

	"virelai/flint/parser"
)

const (
	DefaultStoreRoot = "/host/FLINT"
	MaxFileReadBytes = 4 * 1024 * 1024
	MaxAtoms         = 4096
	MaxChanges       = 4096
)

var storeRoot = DefaultStoreRoot

// Span locates an Atom within a source file relative to the workspace src root.
type Span struct {
	File  string `json:"file"`
	Start uint32 `json:"start"`
	End   uint32 `json:"end"`
}

// StoredAtom is the JSON representation of an Atom in ATOMS.jsonl.
type StoredAtom struct {
	ID       string            `json:"id"`
	Kind     string            `json:"kind"`
	Name     string            `json:"name"`
	Hash     string            `json:"hash"`
	SigHash  string            `json:"sig_hash"`
	Span     Span              `json:"span"`
	Metadata map[string]string `json:"metadata,omitempty"`
	Origin   string            `json:"origin,omitempty"`
}

// Op is a staged or committed operation on an Atom (STAGE.jsonl / Change.ops).
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

// ForkOrigin records the Stream and Change a forked Stream started from.
type ForkOrigin struct {
	Stream string `json:"stream"`
	Change string `json:"change"`
}

// Stream is the JSON record stored at /host/FLINT/streams/<id>.json.
type Stream struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Head       *string     `json:"head"`
	Created    int64       `json:"created"`
	ForkedFrom *ForkOrigin `json:"forked_from"`
}

// Workspace is the JSON record stored at /host/FLINT/ws/<name>/WORKSPACE.json.
type Workspace struct {
	Name    string `json:"name"`
	Src     string `json:"src"`
	Stream  string `json:"stream"`
	Created int64  `json:"created"`
}

// AtomKey uniquely identifies a declaration in a working tree by (file, kind, name).
type AtomKey struct {
	File string
	Kind string
	Name string
}

func streamsDir(root string) string { return root + "/streams" }
func streamRecordPath(root, id string) string {
	return root + "/streams/" + id + ".json"
}
func streamLogPath(root, id string) string {
	return root + "/streams/" + id + ".jsonl"
}
func workspacesDir(root string) string { return root + "/ws" }
func workspaceDir(root, ws string) string {
	return root + "/ws/" + ws
}
func workspaceConfigPath(root, ws string) string {
	return root + "/ws/" + ws + "/WORKSPACE.json"
}
func workspaceAtomsPath(root, ws string) string {
	return root + "/ws/" + ws + "/ATOMS.jsonl"
}
func workspaceStagePath(root, ws string) string {
	return root + "/ws/" + ws + "/STAGE.jsonl"
}
func workspaceMergePath(root, ws string) string {
	return root + "/ws/" + ws + "/MERGE.json"
}

// ReadJSONLLines splits a JSONL payload into lines and enforces the ADR 0049
// torn-append rule: any non-empty payload whose final byte is not '\n' is
// refused with `stream_torn`.
func ReadJSONLLines(data []byte) ([][]byte, error) {
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

// StoreIndex holds the in-memory index built on each invocation from flat files.
type StoreIndex struct {
	Root          string
	StreamsByID   map[string]*Stream
	StreamsByName map[string]*Stream
	Workspaces    map[string]*Workspace
	ChangeCount   int
}

// LoadStoreIndex scans /host/FLINT/streams and /host/FLINT/ws into memory.
func LoadStoreIndex(fs FS, root string) (*StoreIndex, error) {
	idx := &StoreIndex{
		Root:          root,
		StreamsByID:   map[string]*Stream{},
		StreamsByName: map[string]*Stream{},
		Workspaces:    map[string]*Workspace{},
	}

	sDir := streamsDir(root)
	if fs.Exists(sDir) {
		entries, err := fs.List(sDir)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if e.IsDir {
				continue
			}
			switch {
			case strings.HasSuffix(e.Name, ".json"):
				b, err := fs.ReadFile(sDir+"/"+e.Name, MaxFileReadBytes)
				if err != nil {
					return nil, err
				}
				var st Stream
				if err := json.Unmarshal(b, &st); err != nil || st.ID == "" || st.Name == "" {
					return nil, refuse("stream_malformed", e.Name)
				}
				idx.StreamsByID[st.ID] = &st
				idx.StreamsByName[st.Name] = &st
			case strings.HasSuffix(e.Name, ".jsonl"):
				b, err := fs.ReadFile(sDir+"/"+e.Name, MaxFileReadBytes)
				if err != nil {
					return nil, err
				}
				lines, err := ReadJSONLLines(b)
				if err != nil {
					return nil, err
				}
				idx.ChangeCount += len(lines)
				if idx.ChangeCount > MaxChanges {
					return nil, refuse("store_too_large", "changes")
				}
			}
		}
	}

	wDir := workspacesDir(root)
	if fs.Exists(wDir) {
		entries, err := fs.List(wDir)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if !e.IsDir {
				continue
			}
			cfgPath := workspaceConfigPath(root, e.Name)
			if !fs.Exists(cfgPath) {
				continue
			}
			b, err := fs.ReadFile(cfgPath, MaxFileReadBytes)
			if err != nil {
				return nil, err
			}
			var ws Workspace
			if err := json.Unmarshal(b, &ws); err != nil || ws.Name == "" {
				return nil, refuse("ws_malformed", e.Name)
			}
			idx.Workspaces[ws.Name] = &ws
		}
	}

	return idx, nil
}

// StoredAtomFromParser converts a parsed Atom plus a UUIDv7 id into a StoredAtom.
func StoredAtomFromParser(id string, a parser.Atom) StoredAtom {
	var meta map[string]string
	if len(a.Meta) > 0 {
		meta = make(map[string]string, len(a.Meta))
		for k, v := range a.Meta {
			meta[k] = v
		}
	}
	return StoredAtom{
		ID:      id,
		Kind:    a.Kind,
		Name:    a.Name,
		Hash:    hex.EncodeToString(a.Hash[:]),
		SigHash: hex.EncodeToString(a.SigHash[:]),
		Span: Span{
			File:  a.File,
			Start: a.Start,
			End:   a.End,
		},
		Metadata: meta,
	}
}

// LoadWorkspaceAtoms reads ws/<name>/ATOMS.jsonl and enforces the 4096-Atom bound.
func LoadWorkspaceAtoms(fs FS, root, ws string) ([]StoredAtom, error) {
	p := workspaceAtomsPath(root, ws)
	if !fs.Exists(p) {
		return nil, nil
	}
	b, err := fs.ReadFile(p, MaxFileReadBytes)
	if err != nil {
		return nil, err
	}
	lines, err := ReadJSONLLines(b)
	if err != nil {
		return nil, err
	}
	if len(lines) > MaxAtoms {
		return nil, refuse("store_too_large", "atoms")
	}
	atoms := make([]StoredAtom, 0, len(lines))
	for _, line := range lines {
		var a StoredAtom
		if err := json.Unmarshal(line, &a); err != nil || a.ID == "" || a.Kind == "" || a.Name == "" {
			return nil, refuse("atom_malformed", "")
		}
		atoms = append(atoms, a)
	}
	return atoms, nil
}

func sortStoredAtoms(atoms []StoredAtom) {
	sort.Slice(atoms, func(i, j int) bool {
		if atoms[i].Span.File != atoms[j].Span.File {
			return atoms[i].Span.File < atoms[j].Span.File
		}
		if atoms[i].Span.Start != atoms[j].Span.Start {
			return atoms[i].Span.Start < atoms[j].Span.Start
		}
		if atoms[i].Kind != atoms[j].Kind {
			return atoms[i].Kind < atoms[j].Kind
		}
		if atoms[i].Name != atoms[j].Name {
			return atoms[i].Name < atoms[j].Name
		}
		return atoms[i].ID < atoms[j].ID
	})
}

// WriteWorkspaceAtoms writes ws/<name>/ATOMS.jsonl deterministically via WriteFileSafe.
func WriteWorkspaceAtoms(fs FS, root, ws string, atoms []StoredAtom) error {
	if len(atoms) > MaxAtoms {
		return refuse("store_too_large", "atoms")
	}
	sorted := make([]StoredAtom, len(atoms))
	copy(sorted, atoms)
	sortStoredAtoms(sorted)
	var buf bytes.Buffer
	for _, a := range sorted {
		line, err := json.Marshal(a)
		if err != nil {
			return err
		}
		buf.Write(line)
		buf.WriteByte('\n')
	}
	return fs.WriteFileSafe(workspaceAtomsPath(root, ws), buf.Bytes())
}

// LoadWorkspaceStage reads ws/<name>/STAGE.jsonl if present.
func LoadWorkspaceStage(fs FS, root, ws string) ([]Op, error) {
	p := workspaceStagePath(root, ws)
	if !fs.Exists(p) {
		return nil, nil
	}
	b, err := fs.ReadFile(p, MaxFileReadBytes)
	if err != nil {
		return nil, err
	}
	lines, err := ReadJSONLLines(b)
	if err != nil {
		return nil, err
	}
	if len(lines) > MaxAtoms {
		return nil, refuse("store_too_large", "atoms")
	}
	ops := make([]Op, 0, len(lines))
	for _, line := range lines {
		var op Op
		if err := json.Unmarshal(line, &op); err != nil || op.Type == "" || op.AtomID == "" {
			return nil, refuse("stage_malformed", "")
		}
		ops = append(ops, op)
	}
	return ops, nil
}

func opTypeCode(t string) uint8 {
	switch t {
	case "add":
		return 1
	case "modify":
		return 2
	case "delete":
		return 3
	case "move":
		return 4
	case "rename":
		return 5
	default:
		return 0
	}
}

func sortOps(ops []Op) {
	sort.Slice(ops, func(i, j int) bool {
		ui, oki := ParseUUID(ops[i].AtomID)
		uj, okj := ParseUUID(ops[j].AtomID)
		if oki && okj {
			if cmp := bytes.Compare(ui[:], uj[:]); cmp != 0 {
				return cmp < 0
			}
		} else if ops[i].AtomID != ops[j].AtomID {
			return ops[i].AtomID < ops[j].AtomID
		}
		return opTypeCode(ops[i].Type) < opTypeCode(ops[j].Type)
	})
}

// WriteWorkspaceStage writes ws/<name>/STAGE.jsonl deterministically via WriteFileSafe.
func WriteWorkspaceStage(fs FS, root, ws string, ops []Op) error {
	if len(ops) > MaxAtoms {
		return refuse("store_too_large", "atoms")
	}
	sorted := make([]Op, len(ops))
	copy(sorted, ops)
	sortOps(sorted)
	var buf bytes.Buffer
	for _, op := range sorted {
		line, err := json.Marshal(op)
		if err != nil {
			return err
		}
		buf.Write(line)
		buf.WriteByte('\n')
	}
	return fs.WriteFileSafe(workspaceStagePath(root, ws), buf.Bytes())
}

// WriteJSONSafe marshals v to JSON with a trailing newline and writes it via WriteFileSafe.
func WriteJSONSafe(fs FS, path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	return fs.WriteFileSafe(path, b)
}
