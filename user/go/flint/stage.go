package main

import (
	"strings"

	"virelai/vi"
)

// FoldStageOps folds newly produced Ops into the existing staged Ops per
// ADR 0049 §1 and §2 step 2:
//   - add + modify -> add (with newest hash, sig_hash, and span)
//   - add + delete -> nothing (removed from stage)
//   - modify + modify -> modify (first old_hash -> last new_hash)
//   - modify + delete -> delete (first old_hash)
func FoldStageOps(existing []Op, incoming []Op, currentAtoms []StoredAtom) []Op {
	byAtom := make(map[string]Op, len(existing)+len(incoming))
	for _, op := range existing {
		byAtom[op.AtomID] = op
	}
	spanByID := make(map[string]Span, len(currentAtoms))
	for _, a := range currentAtoms {
		spanByID[a.ID] = a.Span
	}

	for _, op := range incoming {
		prev, hasPrev := byAtom[op.AtomID]
		if !hasPrev {
			byAtom[op.AtomID] = op
			continue
		}
		switch prev.Type {
		case "add":
			switch op.Type {
			case "modify":
				prev.NewHash = op.NewHash
				prev.NewSigHash = op.NewSigHash
				if sp, ok := spanByID[op.AtomID]; ok {
					spCopy := sp
					prev.NewSpan = &spCopy
				}
				byAtom[op.AtomID] = prev
			case "delete":
				delete(byAtom, op.AtomID)
			}
		case "modify":
			switch op.Type {
			case "modify":
				prev.NewHash = op.NewHash
				prev.NewSigHash = op.NewSigHash
				byAtom[op.AtomID] = prev
			case "delete":
				byAtom[op.AtomID] = Op{
					Type:    "delete",
					AtomID:  op.AtomID,
					OldHash: prev.OldHash,
				}
			}
		default:
			byAtom[op.AtomID] = op
		}
	}

	// Also refresh NewSpan on staged adds whose span shifted on an unchanged re-add.
	for id, op := range byAtom {
		if op.Type == "add" {
			if sp, ok := spanByID[id]; ok {
				spCopy := sp
				op.NewSpan = &spCopy
				byAtom[id] = op
			}
		}
	}

	out := make([]Op, 0, len(byAtom))
	for _, op := range byAtom {
		out = append(out, op)
	}
	sortOps(out)
	return out
}

// cmdStatus implements `flint status [--ws=<name>]`.
func cmdStatus(fs FS, root string, args []string) error {
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
	seenKeys := make(map[AtomKey]bool, len(atoms))
	duplicates := 0
	for _, a := range atoms {
		atomsByID[a.ID] = a
		k := AtomKey{File: a.Span.File, Kind: a.Kind, Name: a.Name}
		if seenKeys[k] {
			duplicates++
		}
		seenKeys[k] = true
	}

	streamName := ws.Stream
	if st, ok := idx.StreamsByID[ws.Stream]; ok {
		streamName = st.Name
	}

	var countAdd, countMod, countDel int
	for _, op := range stage {
		switch op.Type {
		case "add":
			countAdd++
		case "modify":
			countMod++
		case "delete":
			countDel++
		}
	}

	consoleFn("flint: status ws=" + ws.Name +
		" stream=" + streamName +
		" atoms=" + vi.Itoa64(int64(len(atoms))) +
		" staged=" + vi.Itoa64(int64(len(stage))) +
		" add=" + vi.Itoa64(int64(countAdd)) +
		" modify=" + vi.Itoa64(int64(countMod)) +
		" delete=" + vi.Itoa64(int64(countDel)) +
		" duplicates=" + vi.Itoa64(int64(duplicates)))

	sortOps(stage)
	const stageCap = 64
	limit := len(stage)
	if limit > stageCap {
		limit = stageCap
	}
	for _, op := range stage[:limit] {
		name := opQualifiedName(op, atomsByID)
		consoleFn("flint: stage " + op.Type + " " + name)
	}
	if len(stage) > stageCap {
		consoleFn("flint: stage … +" + vi.Itoa64(int64(len(stage)-stageCap)))
	}
	return nil
}

func opQualifiedName(op Op, atomsByID map[string]StoredAtom) string {
	if op.NewName != "" {
		return op.NewName
	}
	if a, ok := atomsByID[op.AtomID]; ok && a.Name != "" {
		return a.Name
	}
	return op.AtomID
}
