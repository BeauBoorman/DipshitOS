package main

import (
	"sort"
	"strings"

	"virelai/vi"
)

// graphCap bounds the nodes `log --graph` renders (same depth as `log`).
const graphCap = 64

// logGraph draws the Change DAG reachable from `seeds` through `parent`
// and `merged` edges as ASCII lanes (M138c #2777):
//
//	flint: graph * <id8> <author8> <msg>   one row per Change, newest first
//	flint: graph |\                        a merge opens a lane for `merged`
//	flint: graph |/                        lanes expecting the same Change fold
//
// Each lane column tracks the Change id expected next down that edge; a
// node emitted in multiple lanes means fork-side and main-side history
// converge on it (the `|/` fold). Tag rows append ` (tag: name[, ...])`.
func logGraph(fs FS, root string, idx *StoreIndex, seeds []string) error {
	allChanges, err := LoadAllStreamChanges(fs, root, idx)
	if err != nil {
		return err
	}
	byID := make(map[string]Change, len(allChanges))
	for _, c := range allChanges {
		byID[c.ID] = c
	}

	reach := make(map[string]bool)
	for _, s := range seeds {
		for id := range AncestorSet(&s, byID) {
			reach[id] = true
		}
	}
	nodes := make([]Change, 0, len(reach))
	for id := range reach {
		nodes = append(nodes, byID[id])
	}
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].TS != nodes[j].TS {
			return nodes[i].TS > nodes[j].TS
		}
		return nodes[i].ID > nodes[j].ID
	})

	tagsByChange := map[string][]string{}
	if tags, err := LoadTags(fs, root); err == nil {
		for _, t := range tags {
			tagsByChange[t.Change] = append(tagsByChange[t.Change], t.Name)
		}
	}

	var lanes []string
	total := 0
	emit := func(cells, info string) {
		consoleFn("flint: graph " + cells + info)
	}
	for _, n := range nodes {
		if total >= graphCap {
			break
		}
		col := -1
		var extras map[int]bool
		for i, id := range lanes {
			if id == n.ID {
				if col < 0 {
					col = i
				} else {
					if extras == nil {
						extras = map[int]bool{}
					}
					extras[i] = true
				}
			}
		}
		if col < 0 {
			lanes = append(lanes, n.ID)
			col = len(lanes) - 1
		}
		if len(extras) > 0 {
			// Convergence: every lane expecting n folds into col.
			var b strings.Builder
			for i := range lanes {
				if extras[i] {
					b.WriteByte('/')
				} else {
					b.WriteByte('|')
				}
			}
			emit(b.String(), "")
			var kept []string
			for i, id := range lanes {
				if !extras[i] {
					kept = append(kept, id)
				}
			}
			lanes = kept
			col = -1
			for i, id := range lanes {
				if id == n.ID {
					col = i
					break
				}
			}
		}

		var b strings.Builder
		for i := range lanes {
			if i == col {
				b.WriteByte('*')
			} else {
				b.WriteByte('|')
			}
		}
		info := " " + n.ID[:8] + " " + authorPrefix8(n.Author) + " " + firstMessageLine(n.Message)
		if tn := tagsByChange[n.ID]; len(tn) > 0 {
			sort.Strings(tn)
			info += " (tag: " + strings.Join(tn, ", ") + ")"
		}
		emit(b.String(), info)
		total++

		parent := ""
		if n.Parent != nil {
			parent = *n.Parent
		}
		merged := ""
		if n.Merged != nil {
			merged = *n.Merged
		}
		lanes[col] = parent
		mergedNew := merged != "" && !laneHas(lanes, merged)
		if mergedNew {
			lanes = append(lanes, "")
			copy(lanes[col+2:], lanes[col+1:])
			lanes[col+1] = merged
			var cb strings.Builder
			for i := range lanes {
				if i == col+1 {
					cb.WriteByte('\\')
				} else {
					cb.WriteByte('|')
				}
			}
			emit(cb.String(), "")
		}
		kept := lanes[:0]
		for _, id := range lanes {
			if id != "" {
				kept = append(kept, id)
			}
		}
		lanes = kept
	}
	if len(nodes) > total {
		emit("", " … +"+vi.Itoa64(int64(len(nodes)-total)))
	}
	return nil
}

func laneHas(lanes []string, id string) bool {
	for _, l := range lanes {
		if l == id {
			return true
		}
	}
	return false
}

func authorPrefix8(author string) string {
	if len(author) > 8 {
		return author[:8]
	}
	return author
}
