package gitread

// The reader's contract, pinned host-side against a synthesized repository
// in both storage shapes: loose objects and a packfile (the shape a real
// `git repack` leaves — the class-B gate seeds exactly that on the share).
// The index byte layout is additionally checked against a real `git add`
// index when the git binary is present.

import (
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var (
	fxHelloV1 = "alpha\ndelta\ngamma\n" // HEAD version of hello.txt
	fxHelloWT = "alpha\nomega\ngamma\n" // worktree edit (unstaged)
	fxNotes1  = "one\ntwo\n"
	fxNotes2  = "one\ntwo\nthree\n" // HEAD version (changed in commit two)
	fxStaged  = "staged line\n"     // added to the index only
	fxLoose   = "untracked\n"       // never added
)

func fxBlob(data string) GitObj {
	b := GitObj{Type: ObjBlob, Data: []byte(data)}
	b.ID = HashObject(ObjBlob, b.Data)
	return b
}

func fxTree(ents []TreeEnt) GitObj {
	t := GitObj{Type: ObjTree, Data: encodeTree(ents)}
	t.ID = HashObject(ObjTree, t.Data)
	return t
}

func fxCommit(tree [20]byte, parent *[20]byte, subject string) GitObj {
	s := "tree " + HexEncode(tree[:]) + "\n"
	if parent != nil {
		s += "parent " + HexEncode(parent[:]) + "\n"
	}
	s += "author g <g@g> 1000000000 +0000\ncommitter g <g@g> 1000000000 +0000\n\n" + subject + "\n"
	c := GitObj{Type: ObjCommit, Data: []byte(s)}
	c.ID = HashObject(ObjCommit, c.Data)
	return c
}

// fxIndex builds a v2 index byte-for-byte at the documented offsets
// (index.go header): 62-byte entry base, name, NUL pad to 8.
func fxIndex(entries []IndexEntry) []byte {
	b := []byte("DIRC")
	var u32 [4]byte
	binary.BigEndian.PutUint32(u32[:], 2)
	b = append(b, u32[:]...)
	binary.BigEndian.PutUint32(u32[:], uint32(len(entries)))
	b = append(b, u32[:]...)
	for _, e := range entries {
		fixed := make([]byte, 62)
		copy(fixed[40:60], e.Sha[:])
		// flags at 60: bits 0-11 name length, bits 12-13 stage.
		binary.BigEndian.PutUint16(fixed[60:], uint16(len(e.Path))|uint16(e.Stage)<<12)
		entry := append(fixed, e.Path...)
		entry = append(entry, 0)
		for len(entry)%8 != 0 {
			entry = append(entry, 0)
		}
		b = append(b, entry...)
	}
	b = append(b, make([]byte, 20)...) // SHA-1 trailer (ignored by the parser)
	return b
}

type fxObjs struct {
	hello, notes1, notes2, staged GitObj
	tree1, tree2                  GitObj
	c1, c2                        GitObj
}

func fxObjects() fxObjs {
	hello := fxBlob(fxHelloV1)
	notes1 := fxBlob(fxNotes1)
	notes2 := fxBlob(fxNotes2)
	staged := fxBlob(fxStaged)
	tree1 := fxTree([]TreeEnt{
		{Mode: "100644", Name: "hello.txt", ID: hello.ID},
		{Mode: "100644", Name: "notes.txt", ID: notes1.ID},
	})
	tree2 := fxTree([]TreeEnt{
		{Mode: "100644", Name: "hello.txt", ID: hello.ID},
		{Mode: "100644", Name: "notes.txt", ID: notes2.ID},
	})
	var noParent *[20]byte
	c1 := fxCommit(tree1.ID, noParent, "seed: first")
	c2 := fxCommit(tree2.ID, &c1.ID, "seed: second")
	return fxObjs{hello, notes1, notes2, staged, tree1, tree2, c1, c2}
}

func fxWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// fxBuild lays out the fixture repository. packed=true stores every object
// in a single packfile with no loose objects (the post-repack shape);
// packed=false keeps loose objects only. withIndex writes .git/index.
func fxBuild(t *testing.T, packed, withIndex bool) (root string, o fxObjs) {
	t.Helper()
	root = t.TempDir()
	gitDir := filepath.Join(root, ".git")
	o = fxObjects()

	objs := []GitObj{o.hello, o.notes1, o.notes2, o.staged, o.tree1, o.tree2, o.c1, o.c2}
	if packed {
		if err := os.MkdirAll(filepath.Join(gitDir, "objects", "pack"), 0o755); err != nil {
			t.Fatal(err)
		}
		pack := PackObjects(objs, nil, nil)
		fxWrite(t, filepath.Join(gitDir, "objects", "pack", "pack-fxtest.pack"), string(pack))
	} else {
		for _, obj := range objs {
			hx := HexEncode(obj.ID[:])
			fxWrite(t, filepath.Join(gitDir, "objects", hx[:2], hx[2:]), string(LooseBytes(obj)))
		}
	}
	fxWrite(t, filepath.Join(gitDir, "HEAD"), "ref: refs/heads/main\n")
	fxWrite(t, filepath.Join(gitDir, "refs", "heads", "main"), HexEncode(o.c2.ID[:])+"\n")
	if withIndex {
		idx := fxIndex([]IndexEntry{
			{Path: "hello.txt", Sha: o.hello.ID},
			{Path: "notes.txt", Sha: o.notes2.ID},
			{Path: "staged.txt", Sha: o.staged.ID},
		})
		fxWrite(t, filepath.Join(gitDir, "index"), string(idx))
	}
	// worktree: hello edited (unstaged), notes clean, staged.txt added,
	// loose.txt untracked.
	fxWrite(t, filepath.Join(root, "hello.txt"), fxHelloWT)
	fxWrite(t, filepath.Join(root, "notes.txt"), fxNotes2)
	fxWrite(t, filepath.Join(root, "staged.txt"), fxStaged)
	fxWrite(t, filepath.Join(root, "loose.txt"), fxLoose)
	return root, o
}

func TestOpenHeadLogBothStores(t *testing.T) {
	for _, packed := range []bool{false, true} {
		name := "loose"
		if packed {
			name = "packed"
		}
		t.Run(name, func(t *testing.T) {
			root, o := fxBuild(t, packed, true)
			r, err := Open(osFS{}, root)
			if err != nil {
				t.Fatal(err)
			}
			head, err := r.Head()
			if err != nil {
				t.Fatal(err)
			}
			if head != o.c2.ID {
				t.Fatalf("head = %x want %x", head, o.c2.ID)
			}
			revs, err := r.Log(50)
			if err != nil {
				t.Fatal(err)
			}
			if len(revs) != 2 {
				t.Fatalf("log len = %d want 2", len(revs))
			}
			if revs[0].Subject != "seed: second" || revs[1].Subject != "seed: first" {
				t.Fatalf("subjects = %q / %q", revs[0].Subject, revs[1].Subject)
			}
			if revs[0].Sha != o.c2.ID || revs[1].Sha != o.c1.ID {
				t.Fatalf("rev shas wrong: %x %x", revs[0].Sha, revs[1].Sha)
			}
		})
	}
}

func TestStatusSectionsBothStores(t *testing.T) {
	for _, packed := range []bool{false, true} {
		name := "loose"
		if packed {
			name = "packed"
		}
		t.Run(name, func(t *testing.T) {
			root, _ := fxBuild(t, packed, true)
			r, err := Open(osFS{}, root)
			if err != nil {
				t.Fatal(err)
			}
			st, err := r.Status()
			if err != nil {
				t.Fatal(err)
			}
			if !st.HaveIndex {
				t.Fatal("index not detected")
			}
			want := []struct {
				sec []FileEntry
				got []FileEntry
			}{
				{[]FileEntry{{'A', "staged.txt"}}, st.Staged},
				{[]FileEntry{{'M', "hello.txt"}}, st.Modified},
				{[]FileEntry{{'?', "loose.txt"}}, st.Untracked},
			}
			for _, w := range want {
				if len(w.got) != len(w.sec) || w.got[0] != w.sec[0] {
					t.Fatalf("section = %+v want %+v", w.got, w.sec)
				}
			}
		})
	}
}

func TestDiffHunks(t *testing.T) {
	root, _ := fxBuild(t, false, true)
	r, err := Open(osFS{}, root)
	if err != nil {
		t.Fatal(err)
	}
	diffs, err := r.Diff()
	if err != nil {
		t.Fatal(err)
	}
	if len(diffs) != 2 {
		t.Fatalf("diff count = %d want 2 (%+v)", len(diffs), diffs)
	}
	// sorted: hello.txt, staged.txt
	h := diffs[0]
	if h.Path != "hello.txt" {
		t.Fatalf("first diff = %s", h.Path)
	}
	if h.Header != "@@ -2,1 +2,1 @@" {
		t.Fatalf("hello header = %q", h.Header)
	}
	if len(h.Lines) != 2 || h.Lines[0] != (DiffLine{'-', "delta"}) || h.Lines[1] != (DiffLine{'+', "omega"}) {
		t.Fatalf("hello lines = %+v", h.Lines)
	}
	s := diffs[1]
	if s.Path != "staged.txt" {
		t.Fatalf("second diff = %s", s.Path)
	}
	if s.Header != "@@ -0,0 +1,1 @@" {
		t.Fatalf("staged header = %q", s.Header)
	}
	if len(s.Lines) != 1 || s.Lines[0] != (DiffLine{'+', "staged line"}) {
		t.Fatalf("staged lines = %+v", s.Lines)
	}
}

func TestStatusIndexlessCloneDegradation(t *testing.T) {
	// A GOTGIT clone (#1337) has no .git/index. A checkout that still
	// matches HEAD must read CLEAN (that is what a fresh clone is), and a
	// changed file degrades to worktree-vs-HEAD "modified".
	root, o := fxBuild(t, false, false)
	r, err := Open(osFS{}, root)
	if err != nil {
		t.Fatal(err)
	}
	st, err := r.Status()
	if err != nil {
		t.Fatal(err)
	}
	if st.HaveIndex {
		t.Fatal("index appeared from nowhere")
	}
	if len(st.Staged) != 0 {
		t.Fatalf("staged = %+v want empty", st.Staged)
	}
	wantMod := []FileEntry{{'M', "hello.txt"}}
	if len(st.Modified) != 1 || st.Modified[0] != wantMod[0] {
		t.Fatalf("modified = %+v want %+v", st.Modified, wantMod)
	}
	wantUn := []FileEntry{{'?', "loose.txt"}, {'?', "staged.txt"}}
	if len(st.Untracked) != 2 || st.Untracked[0] != wantUn[0] || st.Untracked[1] != wantUn[1] {
		t.Fatalf("untracked = %+v want %+v", st.Untracked, wantUn)
	}

	// Now make it a pristine clone: worktree == HEAD, no index, no debris.
	fxWrite(t, filepath.Join(root, "hello.txt"), fxHelloV1)
	if err := os.Remove(filepath.Join(root, "staged.txt")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "loose.txt")); err != nil {
		t.Fatal(err)
	}
	r2, err := Open(osFS{}, root)
	if err != nil {
		t.Fatal(err)
	}
	st2, err := r2.Status()
	if err != nil {
		t.Fatal(err)
	}
	if len(st2.Staged) != 0 || len(st2.Modified) != 0 || len(st2.Untracked) != 0 {
		t.Fatalf("clone not clean: staged=%+v modified=%+v untracked=%+v",
			st2.Staged, st2.Modified, st2.Untracked)
	}
	_ = o
}

// TestHeadRefResolveTreeFilesParents covers the #2203 fetch/pull surface:
// the ref name HEAD carries, arbitrary ref resolution, a tree map at a
// commit that is NOT HEAD, and commit parent links.
func TestHeadRefResolveTreeFilesParents(t *testing.T) {
	root, o := fxBuild(t, false, true)
	r, err := Open(osFS{}, root)
	if err != nil {
		t.Fatal(err)
	}
	name, ok := r.HeadRef()
	if !ok || name != "refs/heads/main" {
		t.Fatalf("HeadRef = %q ok=%v", name, ok)
	}
	id, err := r.ResolveRef("refs/heads/main")
	if err != nil || id != o.c2.ID {
		t.Fatalf("ResolveRef = %x err=%v", id, err)
	}
	if _, err := r.ResolveRef("refs/heads/nonexistent"); err == nil {
		t.Fatal("missing ref resolved")
	}
	// TreeFiles at c1 (NOT head): the c1 map predates the notes.txt change.
	f1, err := r.TreeFiles(o.c1.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(f1) != 2 || f1["notes.txt"] != o.notes1.ID || f1["hello.txt"] != o.hello.ID {
		t.Fatalf("c1 files = %+v", f1)
	}
	f2, err := r.TreeFiles(o.c2.ID)
	if err != nil {
		t.Fatal(err)
	}
	if f2["notes.txt"] != o.notes2.ID {
		t.Fatalf("c2 files = %+v", f2)
	}
	parents, ok := CommitParents(o.c2.Data)
	if !ok || len(parents) != 1 || parents[0] != o.c1.ID {
		t.Fatalf("c2 parents = %v ok=%v", parents, ok)
	}
	parents, ok = CommitParents(o.c1.Data)
	if !ok || len(parents) != 0 {
		t.Fatalf("c1 parents = %v ok=%v", parents, ok)
	}
	// A detached HEAD has no ref name — pull must refuse it.
	fxWrite(t, filepath.Join(root, ".git", "HEAD"), HexEncode(o.c2.ID[:])+"\n")
	if _, ok := r.HeadRef(); ok {
		t.Fatal("detached HEAD reported a ref name")
	}
}

func TestParseIndexLayout(t *testing.T) {
	id := HashObject(ObjBlob, []byte("x"))
	ents := fxIndex([]IndexEntry{{Path: "hello.txt", Sha: id}, {Path: "sub/a", Sha: id}})
	got, err := ParseIndex(ents)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("len = %d", len(got))
	}
	if got[0].Path != "hello.txt" || got[0].Sha != id || got[0].Stage != 0 {
		t.Fatalf("entry0 = %+v", got[0])
	}
	if got[1].Path != "sub/a" || got[1].Sha != id {
		t.Fatalf("entry1 = %+v (8-byte alignment)", got[1])
	}
	// Bad magic and v4 refuse honestly.
	if _, err := ParseIndex([]byte("NOPE")); err == nil {
		t.Fatal("bad magic accepted")
	}
	v4 := make([]byte, 12)
	copy(v4, "DIRC")
	binary.BigEndian.PutUint32(v4[4:], 4)
	if _, err := ParseIndex(v4); err == nil {
		t.Fatal("v4 accepted")
	}
}

// TestParseIndexAgainstGit pins the layout against a real `git add` index
// (skipped when git is absent; the class-B gate re-proves this in-guest).
func TestParseIndexAgainstGit(t *testing.T) {
	git, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not on PATH")
	}
	dir := t.TempDir()
	run := func(args ...string) string {
		t.Helper()
		cmd := exec.Command(git, args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=g", "GIT_AUTHOR_EMAIL=g@g",
			"GIT_COMMITTER_NAME=g", "GIT_COMMITTER_EMAIL=g@g")
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("git %v: %v", args, err)
		}
		return string(out)
	}
	run("init", "-q")
	fxWrite(t, filepath.Join(dir, "hello.txt"), fxHelloV1)
	fxWrite(t, filepath.Join(dir, "notes.txt"), fxNotes2)
	run("add", "hello.txt", "notes.txt")
	raw, err := os.ReadFile(filepath.Join(dir, ".git", "index"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := ParseIndex(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("git index entries = %d want 2", len(got))
	}
	ls := run("ls-files", "--stage")
	byPath := map[string]string{}
	for _, ln := range strings.Split(strings.TrimRight(ls, "\n"), "\n") {
		// "100644 <sha> 0\tpath"
		sp := strings.IndexByte(ln, ' ')
		tab := strings.IndexByte(ln, '\t')
		if sp < 0 || tab < 0 {
			t.Fatalf("ls-files line = %q", ln)
		}
		byPath[ln[tab+1:]] = ln[sp+1 : sp+41]
	}
	for _, e := range got {
		want, ok := byPath[e.Path]
		if !ok {
			t.Fatalf("parsed path %q not in ls-files", e.Path)
		}
		if HexEncode(e.Sha[:]) != want {
			t.Fatalf("%s sha = %s want %s", e.Path, HexEncode(e.Sha[:]), want)
		}
		if e.Stage != 0 {
			t.Fatalf("%s stage = %d", e.Path, e.Stage)
		}
	}
}
