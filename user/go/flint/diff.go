package main

import (
	"sort"
	"strings"

	"virelai/vi"
)

// cmdDiff implements `flint diff [--ws=<name>]` — the bounded status-depth
// diff (M107d, #2321). FLINT tracks Atom hashes, not source lines, so this
// is not a content diff: it is the staged Op set answered per file, which is
// what a dev reviews between `flint add` and `flint commit` in the guest
// loop. Output:
//
//	flint: diff ws=<n> stream=<s> files=<f> staged=<n> add=<a> modify=<m> delete=<d>
//	flint: diff <type> <file> <qualified-name>   (one per staged Op, cap 64)
//	flint: diff … +<n>                           (overflow)
//
// A delete Op carries only the AtomID, and `add` drops the deleted Atom from
// ATOMS.jsonl, so file/name for deletes of committed Atoms resolve by
// replaying the workspace's stream chain for the introducing add Op.
func cmdDiff(fs FS, root string, args []string) error {
	var wsFlag string
	for _, a := range args {
		if strings.HasPrefix(a, "--ws=") {
			wsFlag = a[len("--ws="):]
			continue
		}
		return refuse("usage", "")
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	ws, err := resolveWorkspace(fs, idx, wsFlag, nil)
	if err != nil {
		return err
	}
	atoms, err := LoadWorkspaceAtoms(fs, root, ws.Name)
	if err != nil {
		return err
	}
	stage, err := LoadWorkspaceStage(fs, root, ws.Name)
	if err != nil {
		return err
	}

	atomsByID := make(map[string]StoredAtom, len(atoms))
	for _, a := range atoms {
		atomsByID[a.ID] = a
	}

	streamName := ws.Stream
	st := idx.StreamsByID[ws.Stream]
	if st != nil {
		streamName = st.Name
	}

	type diffLine struct {
		file, typ, name string
	}
	files := make(map[string]bool, len(stage))
	lines := make([]diffLine, 0, len(stage))
	var countAdd, countMod, countDel int
	var history map[string]StoredAtom
	for _, op := range stage {
		var file, name string
		switch {
		case op.NewSpan != nil:
			file = op.NewSpan.File
			name = op.NewName
		default:
			if a, ok := atomsByID[op.AtomID]; ok {
				file, name = a.Span.File, a.Name
			} else {
				// Committed-then-deleted Atom: resolve from stream history.
				if history == nil {
					history = loadChainAtomNames(fs, root, idx, st)
				}
				if a, ok := history[op.AtomID]; ok {
					file, name = a.Span.File, a.Name
				}
			}
		}
		if file == "" {
			file = "-"
		}
		if name == "" {
			name = op.AtomID
		}
		files[file] = true
		switch op.Type {
		case "add":
			countAdd++
		case "modify":
			countMod++
		case "delete":
			countDel++
		}
		lines = append(lines, diffLine{file: file, typ: op.Type, name: name})
	}
	sort.Slice(lines, func(i, j int) bool {
		if lines[i].file != lines[j].file {
			return lines[i].file < lines[j].file
		}
		if lines[i].name != lines[j].name {
			return lines[i].name < lines[j].name
		}
		return lines[i].typ < lines[j].typ
	})

	consoleFn("flint: diff ws=" + ws.Name +
		" stream=" + streamName +
		" files=" + vi.Itoa64(int64(len(files))) +
		" staged=" + vi.Itoa64(int64(len(stage))) +
		" add=" + vi.Itoa64(int64(countAdd)) +
		" modify=" + vi.Itoa64(int64(countMod)) +
		" delete=" + vi.Itoa64(int64(countDel)))

	const diffCap = 64
	limit := len(lines)
	if limit > diffCap {
		limit = diffCap
	}
	for _, l := range lines[:limit] {
		consoleFn("flint: diff " + l.typ + " " + l.file + " " + l.name)
	}
	if len(lines) > diffCap {
		consoleFn("flint: diff … +" + vi.Itoa64(int64(len(lines)-diffCap)))
	}
	return nil
}

// loadChainAtomNames replays `st` and its forked_from ancestors collecting a
// name/file record per introduced Atom, so ops that carry only an AtomID
// (deletes) still print file + qualified name. Read-only and best-effort: a
// stream that fails to load contributes nothing rather than refusing diff.
func loadChainAtomNames(fs FS, root string, idx *StoreIndex, st *Stream) map[string]StoredAtom {
	out := map[string]StoredAtom{}
	for cur := st; cur != nil; {
		_, changes, err := LoadStream(fs, root, cur.ID)
		if err == nil {
			for _, c := range changes {
				for _, op := range c.Ops {
					if op.NewSpan == nil {
						continue
					}
					rec := StoredAtom{ID: op.AtomID, Kind: op.Kind, Name: op.NewName, Span: *op.NewSpan}
					if prev, ok := out[op.AtomID]; !ok || rec.Name != "" {
						if ok && rec.Name == "" {
							rec.Name = prev.Name
						}
						out[op.AtomID] = rec
					}
				}
			}
		}
		if cur.ForkedFrom == nil {
			break
		}
		cur = idx.StreamsByID[cur.ForkedFrom.Stream]
	}
	return out
}
