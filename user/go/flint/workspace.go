package main

import (
	"strings"
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

// cmdInit implements `flint init --name=<ws> --src=<dir>`.
func cmdInit(fs FS, root string, uuidGen *UUIDGen, args []string) error {
	var wsName, srcDir string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--name="):
			wsName = a[len("--name="):]
		case strings.HasPrefix(a, "--src="):
			srcDir = cleanMemPath(a[len("--src="):])
		default:
			return refuse("usage", "")
		}
	}
	if !validWorkspaceName(wsName) || srcDir == "" {
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
	if _, exists := idx.StreamsByName["main"]; exists {
		return refuse("stream_exists", "main")
	}

	createdMs, err := uuidGen.NowMs()
	if err != nil {
		return err
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
