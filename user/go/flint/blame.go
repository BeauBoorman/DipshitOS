package main

import (
	"errors"
	"strings"

	"virelai/flint/parser"
)

// blameMaxDepth bounds the backward walk over a stream's Change log: a
// declaration whose last touching Change is older than the window reports
// `-` rather than walking unbounded history (M138c #2777).
const blameMaxDepth = 256

// cmdBlame implements `flint blame [--ws=<name>] FILE` (M138c #2777).
// FLINT stores declaration hashes, not file content, so blame attributes
// each line of the CURRENT working-tree file through the Atom covering it:
// the newest Change on the workspace's stream (bounded walk) whose Ops
// touch that Atom is the line's change. Lines outside every Atom print
// `-` for both fields.
//
//	flint: blame <change-id> <author8> <text>
func cmdBlame(fs FS, root string, args []string) error {
	var wsFlag, fileArg string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--ws="):
			wsFlag = a[len("--ws="):]
		case strings.HasPrefix(a, "-"):
			return refuse("usage", "")
		default:
			if fileArg != "" {
				return refuse("usage", "")
			}
			fileArg = a
		}
	}
	if fileArg == "" {
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
	path := cleanMemPath(fileArg)
	rel, ok := relToSrc(ws.Src, path)
	if !ok {
		return refuse("src_missing", path)
	}
	src, err := fs.ReadFile(path, MaxFileReadBytes)
	if err != nil {
		return refuse("src_missing", rel)
	}
	pr, ok := parser.ForPath(rel)
	if !ok {
		return refuse("parse_unsupported", rel)
	}
	decls, perr := pr.Parse(rel, src)
	if perr != nil {
		var pe *parser.ParseError
		if errors.As(perr, &pe) {
			return refuse(pe.Code, pe.File)
		}
		return refuse("syntax", rel)
	}

	_, changes, err := LoadStream(fs, root, ws.Stream)
	if err != nil {
		return err
	}

	// Atom ids come from the workspace table (committed + staged state):
	// ops carry only ids, so (file, kind, name) -> id is the join key.
	atoms, err := LoadWorkspaceAtoms(fs, root, ws.Name)
	if err != nil {
		return err
	}
	idByKey := make(map[AtomKey]string, len(atoms))
	for _, a := range atoms {
		idByKey[AtomKey{File: a.Span.File, Kind: a.Kind, Name: a.Name}] = a.ID
	}

	// Newest touching Change per wanted AtomID — a backward walk over the
	// stream log's tail window.
	want := make(map[string]bool, len(decls))
	for _, d := range decls {
		if id := idByKey[AtomKey{File: rel, Kind: d.Kind, Name: d.Name}]; id != "" {
			want[id] = true
		}
	}
	touching := make(map[string]Change, len(want))
	depth := 0
	for i := len(changes) - 1; i >= 0 && depth < blameMaxDepth && len(want) > 0; i-- {
		depth++
		c := changes[i]
		for _, op := range c.Ops {
			if want[op.AtomID] {
				if _, have := touching[op.AtomID]; !have {
					touching[op.AtomID] = c
					delete(want, op.AtomID)
				}
			}
		}
	}

	// Attribute each line to the decl covering its first byte.
	type lineRef struct{ id, author string }
	author8 := func(c Change) string {
		if len(c.Author) > 8 {
			return c.Author[:8]
		}
		return c.Author
	}
	emit := func(off int, ref *lineRef) {
		end := off
		for end < len(src) && src[end] != '\n' {
			end++
		}
		text := strings.TrimSuffix(string(src[off:end]), "\r")
		if ref == nil {
			consoleFn("flint: blame - - " + text)
			return
		}
		consoleFn("flint: blame " + ref.id + " " + ref.author + " " + text)
	}

	di := 0 // decls are emitted in source order by both parsers
	off := 0
	for off <= len(src) {
		if off == len(src) {
			break
		}
		var ref *lineRef
		for di < len(decls) && int(decls[di].End) <= off {
			di++
		}
		if di < len(decls) && int(decls[di].Start) <= off && off < int(decls[di].End) {
			d := decls[di]
			if id := idByKey[AtomKey{File: rel, Kind: d.Kind, Name: d.Name}]; id != "" {
				if c, ok := touching[id]; ok {
					ref = &lineRef{id: c.ID, author: author8(c)}
				}
			}
		}
		emit(off, ref)
		for off < len(src) && src[off] != '\n' {
			off++
		}
		if off < len(src) {
			off++ // consume '\n'
		}
	}
	return nil
}
