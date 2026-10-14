package main

import "sort"

// Symmetric conflict type names per ADR 0049 §2 step 3.
const (
	ConflictDeleteVsModify   = "delete_vs_modify"
	ConflictDeleteVsMove     = "delete_vs_move"
	ConflictDeleteVsRename   = "delete_vs_rename"
	ConflictConcurrentAdd    = "concurrent_add"
	ConflictConcurrentModify = "concurrent_modify"
	ConflictConcurrentMove   = "concurrent_move"
	ConflictConcurrentRename = "concurrent_rename"
	ConflictModifyVsMove     = "modify_vs_move"
	ConflictModifyVsRename   = "modify_vs_rename"
	ConflictMoveVsRename     = "move_vs_rename"
)

// MergeConflict is one conflict entry in MERGE.json and merge output.
type MergeConflict struct {
	AtomID string `json:"atom_id"`
	Name   string `json:"name"`
	Type   string `json:"type"`
}

// MergeReport is the JSON document written to ws/<name>/MERGE.json on conflict.
type MergeReport struct {
	Into      string          `json:"into"`
	From      string          `json:"from"`
	Ancestor  string          `json:"ancestor"`
	Conflicts []MergeConflict `json:"conflicts"`
}

// conflictPriority returns the ADR 0049 §2 step 3 priority rank for a conflict
// type (lower value = higher priority):
//  1. delete_* first (sorted order)
//  2. concurrent_* second (sorted order)
//  3. cross-field last (sorted order)
func conflictPriority(conflictType string) int {
	switch conflictType {
	case ConflictDeleteVsModify:
		return 1
	case ConflictDeleteVsMove:
		return 2
	case ConflictDeleteVsRename:
		return 3
	case ConflictConcurrentAdd:
		return 4
	case ConflictConcurrentModify:
		return 5
	case ConflictConcurrentMove:
		return 6
	case ConflictConcurrentRename:
		return 7
	case ConflictModifyVsMove:
		return 8
	case ConflictModifyVsRename:
		return 9
	case ConflictMoveVsRename:
		return 10
	default:
		return 99
	}
}

// crossFieldConflict returns the sorted cross-field conflict name for two
// distinct non-delete effect kinds ("modify", "move", "rename").
func crossFieldConflict(a, b string) string {
	if a > b {
		a, b = b, a
	}
	return a + "_vs_" + b
}

// pickHighestPriorityConflict selects the winning conflict type when multiple
// pairwise rules apply to a single Atom.
func pickHighestPriorityConflict(candidates []string) string {
	if len(candidates) == 0 {
		return ""
	}
	best := candidates[0]
	for _, c := range candidates[1:] {
		if conflictPriority(c) < conflictPriority(best) {
			best = c
		}
	}
	return best
}

func sortMergeConflicts(conflicts []MergeConflict) {
	sort.Slice(conflicts, func(i, j int) bool {
		if conflicts[i].Name != conflicts[j].Name {
			return conflicts[i].Name < conflicts[j].Name
		}
		if conflicts[i].Type != conflicts[j].Type {
			return conflicts[i].Type < conflicts[j].Type
		}
		return conflicts[i].AtomID < conflicts[j].AtomID
	})
}
