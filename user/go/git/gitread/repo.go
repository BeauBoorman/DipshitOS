package gitread

// Repo is an opened worktree repository: .git under root, HEAD resolved,
// objects reachable from loose files and packfiles. Read-only — the writer
// side (clone) lives in GOTGIT, and M74c owns the index writer.

import (
	"sort"
	"strings"
	"virelai/flate"
)

// Repo is one opened repository.
type Repo struct {
	FS     FS
	Root   string
	GitDir string

	head   [20]byte
	headOK bool
	packs  map[[20]byte]GitObj
	packed map[string][20]byte // ref name -> sha from packed-refs
}

// Open validates the repository shape (HEAD must resolve) and indexes the
// object store: *.pack parsed eagerly (linear ParsePack, no .idx — fine
// within the 256 KiB guest read cap; named as a gap for the clone
// integration), loose objects listed lazily by path.
func Open(f FS, root string) (*Repo, error) {
	if root == "" {
		return nil, fsErr("empty root")
	}
	// Plain join, not JoinPath: the 64-byte cap is the guest kernel's
	// object-path bound (file_table.max_path_len), enforced where object
	// paths are built; the repo prefix itself is host-length-agnostic.
	gitDir := root
	for len(gitDir) > 1 && gitDir[len(gitDir)-1] == '/' {
		gitDir = gitDir[:len(gitDir)-1]
	}
	gitDir += "/.git"
	r := &Repo{
		FS:     f,
		Root:   root,
		GitDir: gitDir,
		packs:  map[[20]byte]GitObj{},
		packed: map[string][20]byte{},
	}
	if _, err := f.ReadFile(gitDir + "/HEAD"); err != nil {
		return nil, err
	}
	if err := r.indexPacks(); err != nil {
		return nil, err
	}
	if _, err := r.Head(); err != nil {
		return nil, err
	}
	return r, nil
}

// indexPacks parses every .git/objects/pack/*.pack into the id map.
//
// Guest bounds (measured, deliverable 4 #1645): a pack FILENAME is 50
// bytes — longer than vi.DirEntry.Name[32], so the guest DirList truncates
// it and the suffix filter below never matches — and its full path needs
// 76 bytes against file_table.max_path_len (64). In-guest this is therefore
// a quiet no-op and packs resolve through nothing (Get misses honestly,
// as on a GOTGIT clone whose objects are loose); on the host osFS the pack
// path works and is what the host tests exercise.
func (r *Repo) indexPacks() error {
	ents, err := r.FS.ReadDir(r.GitDir + "/objects/pack")
	if err != nil {
		return nil // no pack dir: a loose-only repository
	}
	names := make([]string, 0, len(ents))
	for _, e := range ents {
		if !e.IsDir && strings.HasSuffix(e.Name, ".pack") {
			names = append(names, e.Name)
		}
	}
	sort.Strings(names)
	for _, n := range names {
		raw, err := r.FS.ReadFile(r.GitDir + "/objects/pack/" + n)
		if err != nil {
			return err
		}
		objs, _, err := ParsePack(raw)
		if err != nil {
			return fsErr("pack " + n + ": " + err.Error())
		}
		for _, o := range objs {
			r.packs[o.ID] = o
		}
	}
	return nil
}

// Get resolves an object id: pack map first, then loose.
//
// The loose path is CONSTRUCTED from the sha, never enumerated: object
// filenames are 38 hex bytes — longer than vi.DirEntry.Name[32] — so a
// guest DirList cannot return them whole (one code path serves the guest
// share and the host osFS). No client-side length check: the id is always
// 40 hex, and in-guest the KERNEL is the bound (file_table.max_path_len
// 64; /host/R/.git/objects/ab/<38> = 62, store.go's designed fit) — an
// over-long root fails FileOpen honestly instead of truncating.
func (r *Repo) Get(id [20]byte) (GitObj, bool) {
	if o, ok := r.packs[id]; ok {
		return o, true
	}
	hx := HexEncode(id[:])
	p := r.GitDir + "/objects/" + hx[:2] + "/" + hx[2:]
	raw, err := r.FS.ReadFile(p)
	if err != nil {
		return GitObj{}, false
	}
	return parseLoose(raw, id)
}

// parseLoose inflates a loose object file ("<type> <size>\0<data>") and
// verifies it hashes back to id. The out buffer grows 4K -> 64K -> 256K:
// flate.InflateZlib cannot silently truncate (the Adler-32 check fails on a
// short buffer), so a size-class retry is safe.
func parseLoose(raw []byte, id [20]byte) (GitObj, bool) {
	var out []byte
	var n, consumed int
	var err error
	for _, size := range []int{4096, 64 * 1024, 256 * 1024} {
		buf := make([]byte, size)
		n, consumed, err = flate.InflateZlib(buf, raw)
		if err == nil {
			out = buf[:n]
			break
		}
	}
	if err != nil || consumed <= 0 {
		return GitObj{}, false
	}
	sp := 0
	for sp < len(out) && out[sp] != ' ' {
		sp++
	}
	nul := sp + 1
	for nul < len(out) && out[nul] != 0 {
		nul++
	}
	if sp >= len(out) || nul >= len(out) {
		return GitObj{}, false
	}
	var t int
	switch string(out[:sp]) {
	case "commit":
		t = ObjCommit
	case "tree":
		t = ObjTree
	case "blob":
		t = ObjBlob
	case "tag":
		t = ObjTag
	default:
		return GitObj{}, false
	}
	o := GitObj{Type: t, Data: out[nul+1:], ID: id}
	if HashObject(t, o.Data) != id {
		return GitObj{}, false
	}
	return o, true
}

// Head returns the commit HEAD resolves to (loose ref, then packed-refs,
// then a direct 40-hex HEAD).
func (r *Repo) Head() ([20]byte, error) {
	if r.headOK {
		return r.head, nil
	}
	b, err := r.FS.ReadFile(r.GitDir + "/HEAD")
	if err != nil {
		return [20]byte{}, err
	}
	line := strings.TrimRight(string(b), "\r\n")
	if strings.HasPrefix(line, "ref: ") {
		id, err := r.resolveRef(strings.TrimPrefix(line, "ref: "))
		if err != nil {
			return [20]byte{}, err
		}
		r.head, r.headOK = id, true
		return r.head, nil
	}
	id, ok := HexDecode(line)
	if !ok {
		return [20]byte{}, fsErr("bad HEAD")
	}
	r.head, r.headOK = id, true
	return r.head, nil
}

// HeadRef returns the ref name HEAD points at ("ref: <name>"), or false
// when HEAD is detached (a direct 40-hex) — a pull needs the name to know
// which branch ref to advance.
func (r *Repo) HeadRef() (string, bool) {
	b, err := r.FS.ReadFile(r.GitDir + "/HEAD")
	if err != nil {
		return "", false
	}
	line := strings.TrimRight(string(b), "\r\n")
	if !strings.HasPrefix(line, "ref: ") {
		return "", false
	}
	name := strings.TrimPrefix(line, "ref: ")
	if name == "" || name == "ref:" {
		return "", false
	}
	return name, true
}

// ResolveRef resolves any ref name (loose file first, then packed-refs) —
// the public half of resolveRef for fetch's remote-tracking refs.
func (r *Repo) ResolveRef(name string) ([20]byte, error) {
	return r.resolveRef(name)
}

// resolveRef reads refs/<name> loose-first, then packed-refs.
func (r *Repo) resolveRef(name string) ([20]byte, error) {
	b, err := r.FS.ReadFile(r.GitDir + "/" + name)
	if err == nil {
		id, ok := HexDecode(strings.TrimRight(string(b), "\r\n"))
		if !ok {
			return [20]byte{}, fsErr("bad ref " + name)
		}
		return id, nil
	}
	if len(r.packed) == 0 {
		raw, perr := r.FS.ReadFile(r.GitDir + "/packed-refs")
		if perr == nil {
			for _, ln := range strings.Split(string(raw), "\n") {
				ln = strings.TrimRight(ln, "\r")
				if len(ln) < 42 || ln[40] != ' ' || ln[0] == '#' || ln[0] == '^' {
					continue
				}
				if id, ok := HexDecode(ln[:40]); ok {
					r.packed[ln[41:]] = id
				}
			}
		}
	}
	if id, ok := r.packed[name]; ok {
		return id, nil
	}
	return [20]byte{}, fsErr("no ref " + name)
}
