package main

import (
	"strings"

	"virelai/vi"
)

func validWorkspaceName(name string) bool {
	if len(name) == 0 || len(name) > 32 {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
			return false
		}
	}
	return true
}

// ApplyOpsToAtomMap applies a Change's Ops to an Atom table indexed by AtomID.
// When markMergeOrigin is true, added/modified/moved/renamed Atoms are marked
// with `Origin: "merge"` (ADR 0049 §2).
func ApplyOpsToAtomMap(atomsByID map[string]StoredAtom, ops []Op, markMergeOrigin bool) {
	sorted := make([]Op, len(ops))
	copy(sorted, ops)
	sortOps(sorted)

	for _, op := range sorted {
		switch op.Type {
		case "add":
			var sp Span
			if op.NewSpan != nil {
				sp = *op.NewSpan
			}
			a := StoredAtom{
				ID:      op.AtomID,
				Kind:    op.Kind,
				Name:    op.NewName,
				Hash:    op.NewHash,
				SigHash: op.NewSigHash,
				Span:    sp,
			}
			if markMergeOrigin {
				a.Origin = "merge"
			}
			atomsByID[op.AtomID] = a
		case "modify":
			a := atomsByID[op.AtomID]
			a.ID = op.AtomID
			a.Hash = op.NewHash
			if op.NewSigHash != "" {
				a.SigHash = op.NewSigHash
			}
			if op.NewSpan != nil {
				a.Span = *op.NewSpan
			}
			if markMergeOrigin {
				a.Origin = "merge"
			}
			atomsByID[op.AtomID] = a
		case "delete":
			delete(atomsByID, op.AtomID)
		case "move":
			a := atomsByID[op.AtomID]
			a.ID = op.AtomID
			if op.NewSpan != nil {
				a.Span = *op.NewSpan
			}
			if markMergeOrigin {
				a.Origin = "merge"
			}
			atomsByID[op.AtomID] = a
		case "rename":
			a := atomsByID[op.AtomID]
			a.ID = op.AtomID
			a.Name = op.NewName
			if markMergeOrigin {
				a.Origin = "merge"
			}
			atomsByID[op.AtomID] = a
		}
	}
}

// ReplayStreamAtoms materializes the Atom table at `headID` by replaying Ops
// along the parent chain, root -> head (ADR 0049 / M103d).
func ReplayStreamAtoms(headID *string, allChanges []Change) ([]StoredAtom, int, error) {
	if headID == nil || *headID == "" {
		return nil, 0, nil
	}
	changesByID := make(map[string]Change, len(allChanges))
	for _, c := range allChanges {
		changesByID[c.ID] = c
	}

	var chain []Change
	seen := make(map[string]bool)
	cur := *headID
	for cur != "" {
		if seen[cur] {
			return nil, 0, refuse("change_malformed", cur)
		}
		seen[cur] = true
		c, ok := changesByID[cur]
		if !ok {
			return nil, 0, refuse("change_missing", cur)
		}
		chain = append(chain, c)
		if c.Parent == nil {
			break
		}
		cur = *c.Parent
	}

	for i, j := 0, len(chain)-1; i < j; i, j = i+1, j-1 {
		chain[i], chain[j] = chain[j], chain[i]
	}

	atomsByID := make(map[string]StoredAtom)
	for _, c := range chain {
		ApplyOpsToAtomMap(atomsByID, c.Ops, false)
	}

	out := make([]StoredAtom, 0, len(atomsByID))
	for _, a := range atomsByID {
		out = append(out, a)
	}
	sortStoredAtoms(out)
	return out, len(chain), nil
}

// cmdInit implements `flint init --name=<ws> --src=<dir> [--stream=<name>]`.
func cmdInit(fs FS, root string, uuidGen *UUIDGen, args []string) error {
	var wsName, srcDir, streamFlag string
	hasStreamFlag := false
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--name="):
			wsName = a[len("--name="):]
		case strings.HasPrefix(a, "--src="):
			srcDir = cleanMemPath(a[len("--src="):])
		case strings.HasPrefix(a, "--stream="):
			streamFlag = a[len("--stream="):]
			hasStreamFlag = true
		default:
			return refuse("usage", "")
		}
	}
	if !validWorkspaceName(wsName) || srcDir == "" || (hasStreamFlag && streamFlag == "") {
		return refuse("usage", "")
	}
	if !strings.HasPrefix(srcDir, "/host/") || !fs.Exists(srcDir) {
		return refuse("src_missing", "")
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	if _, exists := idx.Workspaces[wsName]; exists || fs.Exists(workspaceConfigPath(root, wsName)) {
		return refuse("ws_exists", "")
	}

	createdMs, err := uuidGen.NowMs()
	if err != nil {
		return err
	}

	if hasStreamFlag {
		st, ok := idx.StreamsByName[streamFlag]
		if !ok {
			return refuse("stream_missing", streamFlag)
		}
		allChanges, err := LoadAllStreamChanges(fs, root, idx)
		if err != nil {
			return err
		}
		st = idx.StreamsByID[st.ID]
		atoms, replayed, err := ReplayStreamAtoms(st.Head, allChanges)
		if err != nil {
			return err
		}
		if len(atoms) > MaxAtoms {
			return refuse("store_too_large", "atoms")
		}
		if err := ensureDirAll(fs, workspaceDir(root, wsName)); err != nil {
			return err
		}
		ws := Workspace{
			Name:    wsName,
			Src:     srcDir,
			Stream:  st.ID,
			Created: createdMs,
		}
		if err := WriteJSONSafe(fs, workspaceConfigPath(root, wsName), ws); err != nil {
			return err
		}
		if err := WriteWorkspaceAtoms(fs, root, wsName, atoms); err != nil {
			return err
		}
		consoleFn("flint: init ok ws=" + wsName +
			" stream=" + st.Name +
			" atoms=" + vi.Itoa64(int64(len(atoms))) +
			" replayed=" + vi.Itoa64(int64(replayed)))
		return nil
	}

	if _, exists := idx.StreamsByName["main"]; exists {
		return refuse("stream_exists", "main")
	}
	streamID, err := uuidGen.New()
	if err != nil {
		return err
	}

	if err := ensureDirAll(fs, streamsDir(root)); err != nil {
		return err
	}
	if err := ensureDirAll(fs, workspaceDir(root, wsName)); err != nil {
		return err
	}

	st := Stream{
		ID:         streamID,
		Name:       "main",
		Head:       nil,
		Created:    createdMs,
		ForkedFrom: nil,
	}
	if err := WriteJSONSafe(fs, streamRecordPath(root, streamID), st); err != nil {
		return err
	}

	ws := Workspace{
		Name:    wsName,
		Src:     srcDir,
		Stream:  streamID,
		Created: createdMs,
	}
	if err := WriteJSONSafe(fs, workspaceConfigPath(root, wsName), ws); err != nil {
		return err
	}
	if err := fs.WriteFileSafe(workspaceAtomsPath(root, wsName), []byte{}); err != nil {
		return err
	}

	consoleFn("flint: init ok ws=" + wsName + " stream=main")
	return nil
}

// resolveWorkspace selects the workspace for commands (`add`, `status`, etc.).
func resolveWorkspace(fs FS, idx *StoreIndex, wsFlag string, pathArgs []string) (*Workspace, error) {
	if wsFlag != "" {
		ws, ok := idx.Workspaces[wsFlag]
		if !ok {
			return nil, refuse("ws_missing", wsFlag)
		}
		return ws, nil
	}
	if len(idx.Workspaces) == 1 {
		for _, ws := range idx.Workspaces {
			return ws, nil
		}
	}
	if len(pathArgs) > 0 {
		var matched *Workspace
		for _, ws := range idx.Workspaces {
			allUnder := true
			for _, p := range pathArgs {
				cp := cleanMemPath(p)
				if cp != ws.Src && !strings.HasPrefix(cp, ws.Src+"/") {
					allUnder = false
					break
				}
			}
			if allUnder {
				if matched != nil {
					matched = nil
					break
				}
				matched = ws
			}
		}
		if matched != nil {
			return matched, nil
		}
	}
	if len(idx.Workspaces) == 0 {
		return nil, refuse("ws_missing", "")
	}
	// If multiple workspaces exist and no path matched, check if exactly one has a stage.
	var withStage *Workspace
	count := 0
	for _, ws := range idx.Workspaces {
		if fs.Exists(workspaceStagePath(idx.Root, ws.Name)) {
			withStage = ws
			count++
		}
	}
	if count == 1 {
		return withStage, nil
	}
	return nil, refuse("ws_ambiguous", "")
}
