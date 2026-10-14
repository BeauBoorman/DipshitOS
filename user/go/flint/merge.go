package main

import (
	"sort"
	"strings"

	"virelai/sshlib"
	"virelai/vi"
)

// AtomEffect is the folded net effect on a single Atom across a sequence of
// Changes from the common ancestor (exclusive) to a Stream head (ADR 0049 §2 step 2).
type AtomEffect struct {
	AtomID   string
	Added    bool
	Deleted  bool
	Modified bool
	Renamed  bool
	Moved    bool
	Kind     string
	Name     string
	Span     *Span
	Hash     string
	SigHash  string
	OldHash  string
}

// AddKey keys added Atoms across sides by (kind, name) per ADR 0049 §2 step 3.
type AddKey struct {
	Kind string
	Name string
}

// MergeResult holds the outcome of a semantic three-way merge on Ops.
type MergeResult struct {
	Clean     bool
	Ops       []Op
	Conflicts []MergeConflict
}

func copySpan(sp *Span) *Span {
	if sp == nil {
		return nil
	}
	c := *sp
	return &c
}

func spansEqual(a, b *Span) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return a.File == b.File && a.Start == b.Start && a.End == b.End
}

// FoldSideEffects folds a chronological sequence of Change op-lists into one
// net AtomEffect per Atom per ADR 0049 §2 step 2:
//   - add then modify -> add with the newest hash (and sig_hash / span)
//   - add then rename -> add with the newest name
//   - add then move   -> add with the newest span
//   - add then delete -> no effect (vanishes)
//   - modify then modify -> modify(first old_hash -> last new_hash)
//   - repeated renames or moves -> keep the last value
//   - anything then delete -> delete
func FoldSideEffects(baseByID map[string]StoredAtom, changes [][]Op) map[string]*AtomEffect {
	effects := make(map[string]*AtomEffect)

	for _, ops := range changes {
		sorted := make([]Op, len(ops))
		copy(sorted, ops)
		sortOps(sorted)

		for _, op := range sorted {
			eff, exists := effects[op.AtomID]
			if !exists {
				eff = &AtomEffect{AtomID: op.AtomID}
				if base, ok := baseByID[op.AtomID]; ok {
					eff.OldHash = base.Hash
				} else if op.OldHash != "" {
					eff.OldHash = op.OldHash
				}
				effects[op.AtomID] = eff
			}

			if eff.Added {
				switch op.Type {
				case "modify":
					eff.Hash = op.NewHash
					if op.NewSigHash != "" {
						eff.SigHash = op.NewSigHash
					}
					if op.NewSpan != nil {
						eff.Span = copySpan(op.NewSpan)
					}
				case "rename":
					eff.Name = op.NewName
				case "move":
					eff.Span = copySpan(op.NewSpan)
				case "delete":
					delete(effects, op.AtomID)
				}
				continue
			}

			switch op.Type {
			case "add":
				eff.Added = true
				eff.Deleted = false
				eff.Modified = false
				eff.Renamed = false
				eff.Moved = false
				eff.Kind = op.Kind
				eff.Name = op.NewName
				eff.Span = copySpan(op.NewSpan)
				eff.Hash = op.NewHash
				eff.SigHash = op.NewSigHash
			case "modify":
				if eff.OldHash == "" && op.OldHash != "" {
					eff.OldHash = op.OldHash
				}
				eff.Modified = true
				eff.Hash = op.NewHash
				eff.SigHash = op.NewSigHash
			case "rename":
				if eff.OldHash == "" && op.OldHash != "" {
					eff.OldHash = op.OldHash
				}
				eff.Renamed = true
				eff.Name = op.NewName
			case "move":
				if eff.OldHash == "" && op.OldHash != "" {
					eff.OldHash = op.OldHash
				}
				eff.Moved = true
				eff.Span = copySpan(op.NewSpan)
			case "delete":
				if eff.OldHash == "" && op.OldHash != "" {
					eff.OldHash = op.OldHash
				}
				eff.Deleted = true
				eff.Modified = false
				eff.Renamed = false
				eff.Moved = false
				eff.Hash = ""
				eff.SigHash = ""
				eff.Name = ""
				eff.Span = nil
			}
		}
	}

	return effects
}

func activeEffectKinds(eff *AtomEffect) []string {
	if eff == nil || eff.Added {
		return nil
	}
	if eff.Deleted {
		return []string{"delete"}
	}
	var kinds []string
	if eff.Modified {
		kinds = append(kinds, "modify")
	}
	if eff.Moved {
		kinds = append(kinds, "move")
	}
	if eff.Renamed {
		kinds = append(kinds, "rename")
	}
	return kinds
}

// MergeOps runs the ADR 0049 §2 step 2 & 3 semantic merge on Ops given the
// ancestor Atom table and each side's Change op-lists since the ancestor.
func MergeOps(baseAtoms []StoredAtom, intoChanges, fromChanges [][]Op) MergeResult {
	baseByID := make(map[string]StoredAtom, len(baseAtoms))
	for _, a := range baseAtoms {
		baseByID[a.ID] = a
	}

	intoEffs := FoldSideEffects(baseByID, intoChanges)
	fromEffs := FoldSideEffects(baseByID, fromChanges)

	intoAdds := make(map[AddKey]*AtomEffect)
	for _, eff := range intoEffs {
		if eff.Added {
			intoAdds[AddKey{Kind: eff.Kind, Name: eff.Name}] = eff
		}
	}
	fromAdds := make(map[AddKey]*AtomEffect)
	for _, eff := range fromEffs {
		if eff.Added {
			fromAdds[AddKey{Kind: eff.Kind, Name: eff.Name}] = eff
		}
	}

	var conflicts []MergeConflict
	var mergeOps []Op

	// 1. Handle added Atoms (keyed by (kind, name)).
	for key, fEff := range fromAdds {
		iEff, existsOnInto := intoAdds[key]
		if !existsOnInto {
			mergeOps = append(mergeOps, Op{
				Type:       "add",
				AtomID:     fEff.AtomID,
				Kind:       fEff.Kind,
				NewName:    fEff.Name,
				NewSpan:    copySpan(fEff.Span),
				NewHash:    fEff.Hash,
				NewSigHash: fEff.SigHash,
			})
			continue
		}
		if iEff.Hash == fEff.Hash {
			// Equal hash -> clean, keeps `into`'s id, nothing emitted.
			continue
		}
		conflicts = append(conflicts, MergeConflict{
			AtomID: iEff.AtomID,
			Name:   fEff.Name,
			Type:   ConflictConcurrentAdd,
		})
	}

	// 2. Handle existing Atoms (keyed by AtomID).
	seenAtomIDs := make(map[string]bool, len(intoEffs)+len(fromEffs))
	for id, eff := range intoEffs {
		if !eff.Added {
			seenAtomIDs[id] = true
		}
	}
	for id, eff := range fromEffs {
		if !eff.Added {
			seenAtomIDs[id] = true
		}
	}

	atomIDs := make([]string, 0, len(seenAtomIDs))
	for id := range seenAtomIDs {
		atomIDs = append(atomIDs, id)
	}
	sort.Strings(atomIDs)

	for _, id := range atomIDs {
		iEff := intoEffs[id]
		fEff := fromEffs[id]
		iKinds := activeEffectKinds(iEff)
		fKinds := activeEffectKinds(fEff)

		// Untouched on `from` -> clean, nothing to apply on `into`.
		if len(fKinds) == 0 {
			continue
		}

		base := baseByID[id]
		atomName := base.Name
		if atomName == "" {
			if iEff != nil && iEff.Name != "" {
				atomName = iEff.Name
			} else if fEff != nil && fEff.Name != "" {
				atomName = fEff.Name
			} else {
				atomName = id
			}
		}

		intoPreHash := base.Hash
		if intoPreHash == "" {
			if iEff != nil && iEff.OldHash != "" {
				intoPreHash = iEff.OldHash
			} else if fEff != nil && fEff.OldHash != "" {
				intoPreHash = fEff.OldHash
			}
		}
		if iEff != nil && iEff.Modified {
			intoPreHash = iEff.Hash
		}

		// Untouched on `into` -> clean (including multi-field refactor on `from`).
		if len(iKinds) == 0 {
			mergeOps = append(mergeOps, emitFromEffectOps(id, intoPreHash, nil, fEff)...)
			continue
		}

		// Both sides touched this Atom: evaluate pairwise table across active fields.
		var candConflicts []string
		for _, ik := range iKinds {
			for _, fk := range fKinds {
				switch {
				case ik == "delete" && fk == "delete":
					// delete vs delete -> clean
				case ik == "delete" && fk == "modify", ik == "modify" && fk == "delete":
					candConflicts = append(candConflicts, ConflictDeleteVsModify)
				case ik == "delete" && fk == "move", ik == "move" && fk == "delete":
					candConflicts = append(candConflicts, ConflictDeleteVsMove)
				case ik == "delete" && fk == "rename", ik == "rename" && fk == "delete":
					candConflicts = append(candConflicts, ConflictDeleteVsRename)
				case ik == "modify" && fk == "modify":
					if iEff.Hash != fEff.Hash {
						candConflicts = append(candConflicts, ConflictConcurrentModify)
					}
				case ik == "move" && fk == "move":
					if !spansEqual(iEff.Span, fEff.Span) {
						candConflicts = append(candConflicts, ConflictConcurrentMove)
					}
				case ik == "rename" && fk == "rename":
					if iEff.Name != fEff.Name {
						candConflicts = append(candConflicts, ConflictConcurrentRename)
					}
				default:
					candConflicts = append(candConflicts, crossFieldConflict(ik, fk))
				}
			}
		}

		if len(candConflicts) > 0 {
			conflicts = append(conflicts, MergeConflict{
				AtomID: id,
				Name:   atomName,
				Type:   pickHighestPriorityConflict(candConflicts),
			})
			continue
		}

		// Clean when both sides touched the Atom (e.g. equal modify/move/rename/delete).
		mergeOps = append(mergeOps, emitFromEffectOps(id, intoPreHash, iEff, fEff)...)
	}

	if len(conflicts) > 0 {
		sortMergeConflicts(conflicts)
		return MergeResult{
			Clean:     false,
			Ops:       nil,
			Conflicts: conflicts,
		}
	}

	sortOps(mergeOps)
	return MergeResult{
		Clean:     true,
		Ops:       mergeOps,
		Conflicts: nil,
	}
}

// emitFromEffectOps re-expresses `from`'s AtomEffect as Ops on `into`, dropping
// effects already equal on both sides (ADR 0049 §2 step 4).
func emitFromEffectOps(atomID, intoPreHash string, iEff, fEff *AtomEffect) []Op {
	if fEff == nil {
		return nil
	}
	if fEff.Deleted {
		if iEff != nil && iEff.Deleted {
			return nil
		}
		return []Op{{
			Type:    "delete",
			AtomID:  atomID,
			OldHash: intoPreHash,
		}}
	}
	var out []Op
	if fEff.Modified {
		if !(iEff != nil && iEff.Modified && iEff.Hash == fEff.Hash) {
			out = append(out, Op{
				Type:       "modify",
				AtomID:     atomID,
				NewHash:    fEff.Hash,
				NewSigHash: fEff.SigHash,
				OldHash:    intoPreHash,
			})
		}
	}
	if fEff.Moved {
		if !(iEff != nil && iEff.Moved && spansEqual(iEff.Span, fEff.Span)) {
			out = append(out, Op{
				Type:    "move",
				AtomID:  atomID,
				NewSpan: copySpan(fEff.Span),
				OldHash: intoPreHash,
			})
		}
	}
	if fEff.Renamed {
		if !(iEff != nil && iEff.Renamed && iEff.Name == fEff.Name) {
			out = append(out, Op{
				Type:    "rename",
				AtomID:  atomID,
				NewName: fEff.Name,
				OldHash: intoPreHash,
			})
		}
	}
	return out
}

// AncestorSet returns X plus everything reachable from X through `parent` and
// `merged` links (ADR 0049 §2 step 1).
func AncestorSet(headID *string, changesByID map[string]Change) map[string]bool {
	anc := make(map[string]bool)
	if headID == nil || *headID == "" {
		return anc
	}
	queue := []string{*headID}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		if cur == "" || anc[cur] {
			continue
		}
		anc[cur] = true
		c, ok := changesByID[cur]
		if !ok {
			continue
		}
		if c.Parent != nil && *c.Parent != "" && !anc[*c.Parent] {
			queue = append(queue, *c.Parent)
		}
		if c.Merged != nil && *c.Merged != "" && !anc[*c.Merged] {
			queue = append(queue, *c.Merged)
		}
	}
	return anc
}

// FindCommonAncestor finds the first Change on `fromHead`'s parent chain that
// is in `anc(intoHead)`. It returns `upToDate = true` if `fromHead` itself is
// already in `anc(intoHead)`.
func FindCommonAncestor(intoHead, fromHead *string, changesByID map[string]Change) (ancestorID string, upToDate bool, err error) {
	if fromHead == nil || *fromHead == "" {
		return "", true, nil
	}
	intoAnc := AncestorSet(intoHead, changesByID)
	if intoAnc[*fromHead] {
		return *fromHead, true, nil
	}
	seen := make(map[string]bool)
	cur := *fromHead
	for cur != "" {
		if seen[cur] {
			return "", false, refuse("change_malformed", cur)
		}
		seen[cur] = true
		if intoAnc[cur] {
			return cur, false, nil
		}
		c, ok := changesByID[cur]
		if !ok {
			return "", false, refuse("change_missing", cur)
		}
		if c.Parent == nil {
			break
		}
		cur = *c.Parent
	}
	return "", false, refuse("change_missing", "")
}

// ChangesSinceAncestor collects the chronological sequence of Changes (`[][]Op`)
// along `head`'s parent chain from `ancestorID` (exclusive) to `head` (inclusive).
func ChangesSinceAncestor(headID string, ancestorID string, changesByID map[string]Change) ([][]Op, error) {
	var rev [][]Op
	seen := make(map[string]bool)
	cur := headID
	for cur != "" && cur != ancestorID {
		if seen[cur] {
			return nil, refuse("change_malformed", cur)
		}
		seen[cur] = true
		c, ok := changesByID[cur]
		if !ok {
			return nil, refuse("change_missing", cur)
		}
		rev = append(rev, c.Ops)
		if c.Parent == nil {
			return nil, refuse("change_missing", ancestorID)
		}
		cur = *c.Parent
	}
	for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
		rev[i], rev[j] = rev[j], rev[i]
	}
	return rev, nil
}

// resolveMergeWorkspace selects the `into` workspace for `flint merge`. When
// multiple workspaces exist and `--ws=` is omitted, a single workspace whose
// Stream is not `fromStreamID` is chosen unambiguously.
func resolveMergeWorkspace(fs FS, idx *StoreIndex, wsFlag, fromName, fromStreamID string) (*Workspace, error) {
	if wsFlag != "" || len(idx.Workspaces) <= 1 {
		return resolveWorkspace(fs, idx, wsFlag, nil)
	}
	if fromStreamID != "" {
		var candidates []*Workspace
		for _, ws := range idx.Workspaces {
			if ws.Stream != fromStreamID {
				candidates = append(candidates, ws)
			}
		}
		if len(candidates) == 1 {
			return candidates[0], nil
		}
	}
	ws, err := resolveWorkspace(fs, idx, wsFlag, nil)
	if err == nil {
		return ws, nil
	}
	if fromStreamID == "" {
		return nil, refuse("stream_missing", fromName)
	}
	return nil, err
}

// cmdMerge implements `flint merge [--ws=<name>] <from>`.
func cmdMerge(fs FS, root string, uuidGen *UUIDGen, args []string) int {
	var wsFlag, fromName string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--ws="):
			wsFlag = a[len("--ws="):]
		case strings.HasPrefix(a, "-"):
			return runErr(refuse("usage", ""))
		default:
			if fromName != "" {
				return runErr(refuse("usage", ""))
			}
			fromName = a
		}
	}
	if fromName == "" {
		return runErr(refuse("usage", ""))
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return runErr(err)
	}

	fromSt, hasFrom := idx.StreamsByName[fromName]
	fromStreamID := ""
	if hasFrom {
		fromStreamID = fromSt.ID
	}

	ws, err := resolveMergeWorkspace(fs, idx, wsFlag, fromName, fromStreamID)
	if err != nil {
		return runErr(err)
	}

	stage, err := LoadWorkspaceStage(fs, root, ws.Name)
	if err != nil {
		return runErr(err)
	}
	if len(stage) > 0 {
		return runErr(refuse("stage_dirty", ""))
	}

	if !hasFrom {
		return runErr(refuse("stream_missing", fromName))
	}

	allChanges, err := LoadAllStreamChanges(fs, root, idx)
	if err != nil {
		return runErr(err)
	}
	changesByID := make(map[string]Change, len(allChanges))
	for _, c := range allChanges {
		changesByID[c.ID] = c
	}

	intoSt, _, err := LoadStream(fs, root, ws.Stream)
	if err != nil {
		return runErr(err)
	}
	fromSt, _, err = LoadStream(fs, root, fromSt.ID)
	if err != nil {
		return runErr(err)
	}

	ancestorID, upToDate, err := FindCommonAncestor(intoSt.Head, fromSt.Head, changesByID)
	if err != nil {
		return runErr(err)
	}
	if upToDate {
		consoleFn("flint: merge up to date")
		return 0
	}

	ancPtr := &ancestorID
	baseAtoms, _, err := ReplayStreamAtoms(ancPtr, allChanges)
	if err != nil {
		return runErr(err)
	}

	intoOps, err := ChangesSinceAncestor(*intoSt.Head, ancestorID, changesByID)
	if err != nil {
		return runErr(err)
	}
	fromOps, err := ChangesSinceAncestor(*fromSt.Head, ancestorID, changesByID)
	if err != nil {
		return runErr(err)
	}

	res := MergeOps(baseAtoms, intoOps, fromOps)
	if !res.Clean {
		report := MergeReport{
			Into:      *intoSt.Head,
			From:      *fromSt.Head,
			Ancestor:  ancestorID,
			Conflicts: res.Conflicts,
		}
		if err := WriteJSONSafe(fs, workspaceMergePath(root, ws.Name), report); err != nil {
			return runErr(err)
		}
		for _, c := range res.Conflicts {
			consoleFn("flint: merge conflict atom=" + c.Name + " type=" + c.Type)
		}
		consoleFn("flint: merge conflicts=" + vi.Itoa64(int64(len(res.Conflicts))))
		return 2
	}

	if idx.ChangeCount+1 > MaxChanges {
		return runErr(refuse("store_too_large", "changes"))
	}

	// Clean merge: load signing seed BEFORE writing any file.
	seed, err := loadSeed()
	if err != nil {
		return runErr(err)
	}
	defer sshlib.Wipe(seed[:])

	expectedHead := copyStrPtr(intoSt.Head)
	mergedHead := copyStrPtr(fromSt.Head)

	ts, err := uuidGen.NowMs()
	if err != nil {
		return runErr(err)
	}
	changeID, err := uuidGen.New()
	if err != nil {
		return runErr(err)
	}

	c := Change{
		ID:      changeID,
		Parent:  copyStrPtr(expectedHead),
		Stream:  intoSt.ID,
		TS:      ts,
		Message: "merge " + fromSt.Name,
		Ops:     res.Ops,
		Merged:  mergedHead,
	}
	if err := signChangeWithSeed(&c, seed[:]); err != nil {
		return runErr(err)
	}

	existingAtoms, err := LoadWorkspaceAtoms(fs, root, ws.Name)
	if err != nil {
		return runErr(err)
	}
	atomsByID := make(map[string]StoredAtom, len(existingAtoms))
	for _, a := range existingAtoms {
		atomsByID[a.ID] = a
	}

	// Count distinct files affected by the merged Ops before/after applying them.
	unmaterializedFiles := make(map[string]bool)
	for _, op := range c.Ops {
		if a, ok := atomsByID[op.AtomID]; ok && a.Span.File != "" {
			unmaterializedFiles[a.Span.File] = true
		}
		if op.NewSpan != nil && op.NewSpan.File != "" {
			unmaterializedFiles[op.NewSpan.File] = true
		}
	}

	ApplyOpsToAtomMap(atomsByID, c.Ops, true)
	updatedAtoms := make([]StoredAtom, 0, len(atomsByID))
	for _, a := range atomsByID {
		updatedAtoms = append(updatedAtoms, a)
	}
	if len(updatedAtoms) > MaxAtoms {
		return runErr(refuse("store_too_large", "atoms"))
	}

	if _, err := AppendStreamChange(fs, root, intoSt.ID, expectedHead, c); err != nil {
		return runErr(err)
	}
	if err := WriteWorkspaceAtoms(fs, root, ws.Name, updatedAtoms); err != nil {
		return runErr(err)
	}
	if fs.Exists(workspaceMergePath(root, ws.Name)) {
		_ = fs.Remove(workspaceMergePath(root, ws.Name))
	}

	consoleFn("flint: merge ok conflicts=0 ops=" + vi.Itoa64(int64(len(c.Ops))) + " id=" + c.ID)
	consoleFn("flint: merge src not materialized files=" + vi.Itoa64(int64(len(unmaterializedFiles))))
	return 0
}
