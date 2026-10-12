package gitread

// git-status over the local checkout: HEAD tree vs index vs worktree, the
// three porcelain sections the TUI renders. All lists are sorted by path so
// serial markers and views are deterministic.

import (
	"sort"
	"strings"
)

// FileEntry is one status row.
type FileEntry struct {
	Code byte // 'A' added, 'M' modified, 'D' deleted, '?' untracked
	Path string
}

// Status holds the three porcelain sections.
type Status struct {
	HaveIndex bool // false: index-less checkout (see Untracked rule below)
	Staged    []FileEntry
	Modified  []FileEntry
	Untracked []FileEntry
}

// headFiles walks HEAD's root tree into path -> blob sha. Gitlinks (160000)
// are skipped; symlinks (120000) count as files.
func (r *Repo) headFiles() (map[string][20]byte, error) {
	head, err := r.Head()
	if err != nil {
		return nil, err
	}
	return r.TreeFiles(head)
}

// TreeFiles walks one commit's tree into rel-path -> blob sha. Gitlinks
// (160000) are skipped; symlinks (120000) count as files. Pull needs the
// map at BOTH endpoints — the checkout plan diffs HEAD's files against the
// fetched commit's (#2203).
func (r *Repo) TreeFiles(commit [20]byte) (map[string][20]byte, error) {
	c, ok := r.Get(commit)
	if !ok || c.Type != ObjCommit {
		return nil, fsErr("commit unreadable")
	}
	tid, ok := CommitTree(c.Data)
	if !ok {
		return nil, fsErr("head tree missing")
	}
	out := map[string][20]byte{}
	var walk func(prefix string, id [20]byte) error
	walk = func(prefix string, id [20]byte) error {
		t, ok := r.Get(id)
		if !ok || t.Type != ObjTree {
			return fsErr("tree unreadable")
		}
		for _, e := range ParseTree(t.Data) {
			switch {
			case e.Mode == "160000":
				continue // gitlink: no submodule support
			case e.Mode == "40000":
				if err := walk(prefix+e.Name+"/", e.ID); err != nil {
					return err
				}
			case IsBlobMode(e.Mode) || e.Mode == "120000":
				out[prefix+e.Name] = e.ID
			}
		}
		return nil
	}
	if err := walk("", tid); err != nil {
		return nil, err
	}
	return out, nil
}

// Status compares HEAD tree, .git/index and the worktree.
//
// Index-less checkouts (a GOTGIT clone writes no index, #1337) report no
// staged/modified sections — there is nothing to split against — and a file
// whose content still equals HEAD is clean rather than untracked, so a
// fresh clone reads as clean.
func (r *Repo) Status() (Status, error) {
	var s Status
	head, err := r.headFiles()
	if err != nil {
		return s, err
	}

	idxRaw, idxErr := r.FS.ReadFile(r.GitDir + "/index")
	index := map[string]IndexEntry{}
	if idxErr == nil {
		ents, err := ParseIndex(idxRaw)
		if err != nil {
			return s, err
		}
		s.HaveIndex = true
		for _, e := range ents {
			if _, dup := index[e.Path]; !dup || e.Stage == 0 {
				index[e.Path] = e
			}
		}
	}

	work := map[string][]byte{} // rel path -> content (nil when unreadable)
	if err := r.scanWorktree("", &work); err != nil {
		return s, err
	}

	if s.HaveIndex {
		// Index vs HEAD: staged.
		for p, e := range index {
			h, inHead := head[p]
			switch {
			case !inHead:
				s.Staged = append(s.Staged, FileEntry{'A', p})
			case h != e.Sha:
				s.Staged = append(s.Staged, FileEntry{'M', p})
			}
		}
		for p := range head {
			if _, inIndex := index[p]; !inIndex {
				s.Staged = append(s.Staged, FileEntry{'D', p})
			}
		}
		// Worktree vs index: modified.
		for p, e := range index {
			content, present := work[p]
			if !present {
				s.Modified = append(s.Modified, FileEntry{'D', p})
				continue
			}
			if HashObject(ObjBlob, content) != e.Sha {
				s.Modified = append(s.Modified, FileEntry{'M', p})
			}
		}
	} else {
		// Index-less (a GOTGIT clone, #1337): the staged section needs an
		// index by definition, and worktree-vs-HEAD is the only honest
		// "modified" a clone can show.
		for p, h := range head {
			content, present := work[p]
			if !present {
				s.Modified = append(s.Modified, FileEntry{'D', p})
				continue
			}
			if HashObject(ObjBlob, content) != h {
				s.Modified = append(s.Modified, FileEntry{'M', p})
			}
		}
	}

	// Worktree files not in the index are untracked.
	for p := range work {
		if _, inIndex := index[p]; inIndex {
			continue
		}
		if !s.HaveIndex {
			// Index-less: a file that still matches HEAD is part of the
			// checkout (it landed in Modified only when it differs); a
			// file HEAD never had is debris.
			if _, inHead := head[p]; inHead {
				continue
			}
		}
		s.Untracked = append(s.Untracked, FileEntry{'?', p})
	}

	sortEntries(s.Staged)
	sortEntries(s.Modified)
	sortEntries(s.Untracked)
	return s, nil
}

// scanWorktree lists every file under root except .git directories.
// Bound: vi.DirList serves at most 16 entries per directory (fs.go), so a
// directory with more files reads truncated — deliverable-4 finding.
func (r *Repo) scanWorktree(prefix string, out *map[string][]byte) error {
	dir := r.Root
	if prefix != "" {
		dir = r.Root + "/" + prefix
	}
	ents, err := r.FS.ReadDir(dir)
	if err != nil {
		return err
	}
	sort.Slice(ents, func(i, j int) bool { return ents[i].Name < ents[j].Name })
	for _, e := range ents {
		if e.Name == "" || e.Name == "." || e.Name == ".." || strings.ContainsRune(e.Name, '/') {
			continue
		}
		if e.IsDir {
			if e.Name == ".git" {
				continue
			}
			if err := r.scanWorktree(prefix+e.Name+"/", out); err != nil {
				return err
			}
		} else {
			p := prefix + e.Name
			b, err := r.FS.ReadFile(r.Root + "/" + p)
			if err != nil {
				continue // vanished between list and read: skip
			}
			(*out)[p] = b
		}
	}
	return nil
}

func sortEntries(es []FileEntry) {
	sort.Slice(es, func(i, j int) bool { return es[i].Path < es[j].Path })
}

// Has reports whether the path is listed in the section (test helper).
func (s Status) Has(section []FileEntry, code byte, path string) bool {
	for _, e := range section {
		if e.Code == code && e.Path == path {
			return true
		}
	}
	return false
}
