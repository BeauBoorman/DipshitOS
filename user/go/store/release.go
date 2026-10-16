package main

import (
	"encoding/hex"
	"go/ast"
	goparser "go/parser"
	"go/token"
	"strconv"
	"strings"

	"virelai/flint/parser"
)

// releaseFile is the conventional file a release stream tracks.
const releaseFile = "release.go"

// atomKey matches a signed Op to a parsed atom: FLINT names atoms
// <package>.<decl>, and one (kind, qname) pair identifies a declaration
// inside one file.
type atomKey struct {
	kind string
	name string
}

// isReleasePath reports whether file names the release manifest: exactly
// release.go at the src root, or under one directory level (a producer
// may track release/release.go).
func isReleasePath(file string) bool {
	return file == releaseFile || strings.HasSuffix(file, "/"+releaseFile)
}

// foldReleaseOps walks the verified Change log in order and returns the
// signed atom set for release.go at head: (kind, qname) -> canonical
// hash. Add/modify/move/rename ops set the atom's latest signed hash;
// delete removes it. A stream whose head never touched release.go
// (or whose last touch deleted it) yields an empty set.
func foldReleaseOps(changes []Change) map[atomKey]string {
	state := map[string]struct {
		key  atomKey
		file string
		hash string
	}{}
	for _, c := range changes {
		for _, op := range c.Ops {
			switch op.Type {
			case "add", "modify", "move", "rename":
				file := ""
				if op.NewSpan != nil {
					file = op.NewSpan.File
				}
				state[op.AtomID] = struct {
					key  atomKey
					file string
					hash string
				}{atomKey{op.Kind, op.NewName}, file, op.NewHash}
			case "delete":
				delete(state, op.AtomID)
			}
		}
	}
	out := map[atomKey]string{}
	for _, a := range state {
		if isReleasePath(a.file) && a.key.kind != "" && a.key.name != "" && a.hash != "" {
			out[a.key] = a.hash
		}
	}
	return out
}

// release holds the four authenticated consts of a verified release.go.
type release struct {
	Name        string
	Version     string
	ELFSHA256   string
	ManifestRow string
}

// requiredConsts are the four const declarations a release.go must carry
// (flint-client#48). Names match on the unqualified tail so the
// producer's package clause is free.
var requiredConsts = []string{
	"ReleaseName",
	"ReleaseVersion",
	"ReleaseELFSHA256",
	"ReleaseManifestRow",
}

// verifyRelease parses the fetched release.go into FLINT atoms and
// requires its (kind, qname, hash) set to equal the signed folded set
// exactly: every signed atom must parse back with the same hash, and the
// fetched file may carry NO atom the signature does not cover — an extra
// unsigned declaration is a mismatch, not extra information.
func verifyRelease(src []byte, signed map[atomKey]string) error {
	if len(signed) == 0 {
		return refuse("release_missing", "")
	}
	p, ok := parser.ForPath(releaseFile)
	if !ok {
		return refuse("release_malformed", "")
	}
	atoms, err := p.Parse(releaseFile, src)
	if err != nil {
		return refuse("release_malformed", "")
	}
	seen := map[atomKey]string{}
	for _, a := range atoms {
		key := atomKey{a.Kind, a.Name}
		if _, dup := seen[key]; dup {
			return refuse("release_malformed", a.Name)
		}
		seen[key] = hex.EncodeToString(a.Hash[:])
	}
	for key, hash := range seen {
		want, ok := signed[key]
		if !ok || want != hash {
			return refuse("release_mismatch", key.name)
		}
	}
	for key := range signed {
		if _, ok := seen[key]; !ok {
			return refuse("release_mismatch", key.name)
		}
	}
	return nil
}

// unqualified returns the declaration tail of a qualified atom name
// ("release.ReleaseName" -> "ReleaseName").
func unqualified(qname string) string {
	if i := strings.LastIndexByte(qname, '.'); i >= 0 {
		return qname[i+1:]
	}
	return qname
}

// parseRelease extracts and validates the four consts from an
// already-hash-verified release.go. Values are read with go/parser on the
// same verified bytes — the atom hashes authenticate the text, so the
// literals are trusted at exactly the strength of the stream signature.
func parseRelease(src []byte) (*release, error) {
	fset := token.NewFileSet()
	f, err := goparser.ParseFile(fset, releaseFile, src, goparser.SkipObjectResolution)
	if err != nil {
		return nil, refuse("release_malformed", "")
	}
	vals := map[string]string{}
	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.CONST {
			continue
		}
		for _, spec := range gd.Specs {
			vs, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			for i, n := range vs.Names {
				if i >= len(vs.Values) || len(vs.Names) != len(vs.Values) {
					continue
				}
				lit, ok := vs.Values[i].(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					continue
				}
				for _, want := range requiredConsts {
					if n.Name == want {
						v, err := strconv.Unquote(lit.Value)
						if err != nil {
							return nil, refuse("release_malformed", n.Name)
						}
						vals[want] = v
					}
				}
			}
		}
	}
	for _, want := range requiredConsts {
		if _, ok := vals[want]; !ok {
			return nil, refuse("release_malformed", want)
		}
	}
	r := &release{
		Name:        vals["ReleaseName"],
		Version:     vals["ReleaseVersion"],
		ELFSHA256:   vals["ReleaseELFSHA256"],
		ManifestRow: vals["ReleaseManifestRow"],
	}
	if err := r.validate(); err != nil {
		return nil, err
	}
	return r, nil
}

// validate enforces the per-const grammar: the name is a bounded ELF
// stem (share names are 32-byte DirEntry fields and <NAME>.ELF must fit),
// the version is a bounded printable token, the hash is 64 lowercase
// hex, and the manifest row's bin field must be exactly <NAME>.ELF — a
// row naming anything else is refused row_mismatch rather than
// installed.
func (r *release) validate() error {
	if !validStem(r.Name) {
		return refuse("name_invalid", r.Name)
	}
	if !validVersion(r.Version) {
		return refuse("release_malformed", "ReleaseVersion")
	}
	if len(r.ELFSHA256) != 64 {
		return refuse("hash_invalid", "ReleaseELFSHA256")
	}
	for i := 0; i < len(r.ELFSHA256); i++ {
		c := r.ELFSHA256[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return refuse("hash_invalid", "ReleaseELFSHA256")
		}
	}
	row := r.ManifestRow
	if row == "" || len(row) > 512 || strings.ContainsAny(row, "\r\n") {
		return refuse("row_mismatch", "")
	}
	fields := strings.Split(row, "|")
	if len(fields) < 2 || strings.TrimSpace(fields[0]) != r.Name+".ELF" ||
		strings.TrimSpace(fields[1]) == "" {
		return refuse("row_mismatch", "")
	}
	return nil
}

// validStem enforces the ELF-stem grammar: 1-28 chars of [A-Z0-9_-]
// starting alphanumeric, so <NAME>.ELF stays inside the 32-byte share
// name and 64-byte path bounds.
func validStem(s string) bool {
	if len(s) == 0 || len(s) > 28 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case (c == '_' || c == '-') && i > 0:
		default:
			return false
		}
	}
	return true
}

func validVersion(s string) bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '.' || c == '_' || c == '-' || c == '+':
		default:
			return false
		}
	}
	return true
}
