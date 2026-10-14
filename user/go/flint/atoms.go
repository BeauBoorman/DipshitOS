package main

import (
	"encoding/hex"
	"errors"
	"sort"
	"strings"

	"virelai/flint/parser"
	"virelai/vi"
)

type addTarget struct {
	relPrefix string
	isDir     bool
}

// cmdAdd implements `flint add [--ws=<name>] [PATH...]`.
func cmdAdd(fs FS, root string, uuidGen *UUIDGen, args []string) error {
	var wsFlag string
	var paths []string
	for _, a := range args {
		if strings.HasPrefix(a, "--ws=") {
			wsFlag = a[len("--ws="):]
			continue
		}
		paths = append(paths, cleanMemPath(a))
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	ws, err := resolveWorkspace(fs, idx, wsFlag, paths)
	if err != nil {
		return err
	}
	if len(paths) == 0 {
		paths = []string{ws.Src}
	}

	existingAtoms, err := LoadWorkspaceAtoms(fs, root, ws.Name)
	if err != nil {
		return err
	}
	existingStage, err := LoadWorkspaceStage(fs, root, ws.Name)
	if err != nil {
		return err
	}

	atomsByFile := map[string][]StoredAtom{}
	for _, a := range existingAtoms {
		atomsByFile[a.Span.File] = append(atomsByFile[a.Span.File], a)
	}

	var targets []addTarget
	diskFilesMap := map[string]bool{}
	for _, p := range paths {
		rel, ok := relToSrc(ws.Src, p)
		if !ok {
			return refuse("src_missing", p)
		}
		if entries, lerr := fs.List(p); lerr == nil {
			targets = append(targets, addTarget{relPrefix: rel, isDir: true})
			if err := walkSourceFiles(fs, ws.Src, p, entries, diskFilesMap); err != nil {
				return err
			}
			continue
		}
		if _, ok := parser.ForPath(rel); !ok {
			continue
		}
		if fs.Exists(p) {
			targets = append(targets, addTarget{relPrefix: rel, isDir: false})
			diskFilesMap[rel] = true
			continue
		}
		// A disappeared single file that was tracked in ATOMS.jsonl deletes its Atoms.
		if len(atomsByFile[rel]) > 0 {
			targets = append(targets, addTarget{relPrefix: rel, isDir: false})
			continue
		}
		return refuse("src_missing", p)
	}

	diskFiles := make([]string, 0, len(diskFilesMap))
	for rel := range diskFilesMap {
		diskFiles = append(diskFiles, rel)
	}
	sort.Strings(diskFiles)

	// Step 1: Parse every file on disk first (all-or-nothing: any syntax,
	// parse_unsupported, or duplicate_decl error refuses before staging).
	parsedByFile := make(map[string][]parser.Atom, len(diskFiles))
	for _, rel := range diskFiles {
		full := ws.Src + "/" + rel
		src, err := fs.ReadFile(full, MaxFileReadBytes)
		if err != nil {
			return err
		}
		pr, ok := parser.ForPath(rel)
		if !ok {
			continue
		}
		decls, perr := pr.Parse(rel, src)
		if perr != nil {
			var pe *parser.ParseError
			if errors.As(perr, &pe) {
				return refuse(pe.Code, pe.File)
			}
			return refuse("syntax", rel)
		}
		seenInFile := make(map[AtomKey]bool, len(decls))
		for _, d := range decls {
			k := AtomKey{File: rel, Kind: d.Kind, Name: d.Name}
			if seenInFile[k] {
				return refuse("duplicate_decl", rel+" "+d.Kind+" "+d.Name)
			}
			seenInFile[k] = true
		}
		parsedByFile[rel] = decls
	}

	// Collect all affected relative files (files on disk + tracked files under
	// any added target that disappeared from disk).
	affectedMap := make(map[string]bool, len(diskFiles))
	for _, rel := range diskFiles {
		affectedMap[rel] = true
	}
	for rel := range atomsByFile {
		if inTargets(rel, targets) {
			affectedMap[rel] = true
		}
	}
	affectedFiles := make([]string, 0, len(affectedMap))
	for rel := range affectedMap {
		affectedFiles = append(affectedFiles, rel)
	}
	sort.Strings(affectedFiles)

	// Step 1b: Enforce the M103d `src_behind` guard before staging anything:
	// if any Atom marked `origin: merge` in an affected file is missing on disk
	// or has a different hash, refuse `src_behind <file>` and stage nothing.
	for _, rel := range affectedFiles {
		oldList := atomsByFile[rel]
		hasMergeOrigin := false
		for _, old := range oldList {
			if old.Origin == "merge" {
				hasMergeOrigin = true
				break
			}
		}
		if !hasMergeOrigin {
			continue
		}
		decls := parsedByFile[rel]
		declHashByKey := make(map[AtomKey]string, len(decls))
		for _, d := range decls {
			declHashByKey[AtomKey{File: rel, Kind: d.Kind, Name: d.Name}] = hex.EncodeToString(d.Hash[:])
		}
		for _, old := range oldList {
			if old.Origin != "merge" {
				continue
			}
			key := AtomKey{File: rel, Kind: old.Kind, Name: old.Name}
			if diskHash, ok := declHashByKey[key]; !ok || diskHash != old.Hash {
				return refuse("src_behind", rel)
			}
		}
	}

	// Step 2: Diff per file against ATOMS.jsonl (ADR 0049 §1).
	var newAtoms []StoredAtom
	for _, a := range existingAtoms {
		if !affectedMap[a.Span.File] {
			newAtoms = append(newAtoms, a)
		}
	}

	var diffOps []Op
	var countNew, countMod, countDel, countUnchanged int

	for _, rel := range affectedFiles {
		oldList := atomsByFile[rel]
		oldByKey := make(map[AtomKey]StoredAtom, len(oldList))
		for _, old := range oldList {
			oldByKey[AtomKey{File: old.Span.File, Kind: old.Kind, Name: old.Name}] = old
		}
		matchedOld := make(map[string]bool, len(oldList))
		decls := parsedByFile[rel]

		for _, d := range decls {
			key := AtomKey{File: rel, Kind: d.Kind, Name: d.Name}
			newHash := hex.EncodeToString(d.Hash[:])
			newSigHash := hex.EncodeToString(d.SigHash[:])
			if old, exists := oldByKey[key]; exists {
				matchedOld[old.ID] = true
				updated := StoredAtomFromParser(old.ID, d)
				if old.Hash != newHash {
					countMod++
					diffOps = append(diffOps, Op{
						Type:       "modify",
						AtomID:     old.ID,
						NewHash:    newHash,
						NewSigHash: newSigHash,
						OldHash:    old.Hash,
					})
				} else {
					countUnchanged++
				}
				newAtoms = append(newAtoms, updated)
			} else {
				id, err := uuidGen.New()
				if err != nil {
					return err
				}
				added := StoredAtomFromParser(id, d)
				newAtoms = append(newAtoms, added)
				spanCopy := added.Span
				countNew++
				diffOps = append(diffOps, Op{
					Type:       "add",
					AtomID:     id,
					Kind:       added.Kind,
					NewName:    added.Name,
					NewSpan:    &spanCopy,
					NewHash:    added.Hash,
					NewSigHash: added.SigHash,
				})
			}
		}

		for _, old := range oldList {
			if !matchedOld[old.ID] {
				countDel++
				diffOps = append(diffOps, Op{
					Type:    "delete",
					AtomID:  old.ID,
					OldHash: old.Hash,
				})
			}
		}
	}

	if len(newAtoms) > MaxAtoms {
		return refuse("store_too_large", "atoms")
	}

	// Step 3: Fold diffOps into STAGE.jsonl and write both files safely.
	foldedStage := FoldStageOps(existingStage, diffOps, newAtoms)
	if len(foldedStage) > MaxAtoms {
		return refuse("store_too_large", "atoms")
	}
	if err := WriteWorkspaceAtoms(fs, root, ws.Name, newAtoms); err != nil {
		return err
	}
	if err := WriteWorkspaceStage(fs, root, ws.Name, foldedStage); err != nil {
		return err
	}

	consoleFn("flint: add files=" + vi.Itoa64(int64(len(diskFiles))) +
		" new=" + vi.Itoa64(int64(countNew)) +
		" modified=" + vi.Itoa64(int64(countMod)) +
		" deleted=" + vi.Itoa64(int64(countDel)) +
		" unchanged=" + vi.Itoa64(int64(countUnchanged)))
	return nil
}

func relToSrc(srcRoot, p string) (string, bool) {
	srcRoot = cleanMemPath(srcRoot)
	p = cleanMemPath(p)
	if p == srcRoot {
		return "", true
	}
	if strings.HasPrefix(p, srcRoot+"/") {
		return p[len(srcRoot)+1:], true
	}
	return "", false
}

func inTargets(rel string, targets []addTarget) bool {
	for _, t := range targets {
		if !t.isDir {
			if rel == t.relPrefix {
				return true
			}
			continue
		}
		if t.relPrefix == "" || rel == t.relPrefix || strings.HasPrefix(rel, t.relPrefix+"/") {
			return true
		}
	}
	return false
}

func walkSourceFiles(fs FS, srcRoot, dir string, entries []DirEntry, out map[string]bool) error {
	for _, e := range entries {
		child := dir + "/" + e.Name
		if e.IsDir {
			subEntries, err := fs.List(child)
			if err != nil {
				return err
			}
			if err := walkSourceFiles(fs, srcRoot, child, subEntries, out); err != nil {
				return err
			}
			continue
		}
		rel, ok := relToSrc(srcRoot, child)
		if !ok {
			continue
		}
		if _, ok := parser.ForPath(rel); ok {
			out[rel] = true
		}
	}
	return nil
}
