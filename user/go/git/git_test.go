package main

import (
	"bytes"
	"testing"

	"virelai/git/gitread"
)

func TestPktLineRoundTrip(t *testing.T) {
	raw := pktEncodeString("want abc\n")
	p, rest, err := pktRead(raw)
	if err != nil || len(rest) != 0 || p.Flush {
		t.Fatalf("pktRead = %+v rest=%q err=%v", p, rest, err)
	}
	if string(p.Data) != "want abc\n" {
		t.Fatalf("data = %q", p.Data)
	}
	fl, rest, err := pktRead(pktFlush())
	if err != nil || !fl.Flush || len(rest) != 0 {
		t.Fatalf("flush = %+v rest=%q err=%v", fl, rest, err)
	}
}

func TestPktLineSplitStopsAtPackTail(t *testing.T) {
	var buf []byte
	buf = append(buf, pktEncodeString("NAK\n")...)
	buf = append(buf, []byte("PACK")...)
	pkts, leftover, err := pktSplit(buf)
	if err != nil {
		t.Fatal(err)
	}
	if len(pkts) != 1 || string(pkts[0].Data) != "NAK\n" {
		t.Fatalf("pkts = %+v", pkts)
	}
	if string(leftover) != "PACK" {
		t.Fatalf("leftover = %q", leftover)
	}
}

func TestInfoRefsAndWant(t *testing.T) {
	sha := gitread.HashObject(gitread.ObjCommit, []byte("x"))
	hex := gitread.HexEncode(sha[:])
	var body []byte
	body = append(body, pktEncodeString("# service=git-upload-pack\n")...)
	body = append(body, pktFlush()...)
	first := hex + " HEAD\x00multi_ack thin-pack\n"
	body = append(body, pktEncodeString(first)...)
	body = append(body, pktEncodeString(hex+" refs/heads/main\n")...)
	body = append(body, pktFlush()...)
	refs, err := parseInfoRefs(body)
	if err != nil {
		t.Fatal(err)
	}
	if len(refs) != 2 {
		t.Fatalf("refs = %d", len(refs))
	}
	want, ok := pickWant(refs)
	if !ok || want.Name != "refs/heads/main" {
		t.Fatalf("pick = %+v", want)
	}
	wb := wantBody(want.SHA)
	if !bytes.Contains(wb, []byte("want "+hex)) || !bytes.Contains(wb, []byte("done\n")) {
		t.Fatalf("want body = %q", wb)
	}
}

func TestSplitHTTPAndExtractPack(t *testing.T) {
	pack := gitread.PackObjects([]gitread.GitObj{{Type: gitread.ObjCommit, Data: []byte("a"), ID: gitread.HashObject(gitread.ObjCommit, []byte("a"))}}, nil, nil)
	resp := append([]byte("HTTP/1.0 200 OK\r\nContent-Type: application/x-git-upload-pack-result\r\n\r\n"), pktEncodeString("NAK\n")...)
	resp = append(resp, pack...)
	st, body, err := splitHTTP(resp)
	if err != nil || st != 200 {
		t.Fatalf("http st=%d err=%v", st, err)
	}
	got, err := extractPack(body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, pack) {
		t.Fatalf("pack mismatch %d vs %d", len(got), len(pack))
	}
	raw := append(pktEncodeString("# service=git-upload-pack\n"), pktFlush()...)
	st, body, err = splitHTTP(raw)
	if err != nil || st != 200 || !bytes.Equal(body, raw) {
		t.Fatalf("pkt-line fallback st=%d err=%v", st, err)
	}
}

func TestSidebandExtractPack(t *testing.T) {
	pack := gitread.PackObjects([]gitread.GitObj{{Type: gitread.ObjCommit, Data: []byte("a"), ID: gitread.HashObject(gitread.ObjCommit, []byte("a"))}}, nil, nil)
	var body []byte
	body = append(body, pktEncodeString("NAK\n")...)
	chunk := append([]byte{1}, pack...)
	body = append(body, pktEncode(chunk)...)
	body = append(body, pktFlush()...)
	got, err := extractPack(body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, pack) {
		t.Fatalf("sideband pack mismatch")
	}
}

func TestHTTPSNeverCleartext(t *testing.T) {
	https := classify("https://10.0.0.2:24541/g.git")
	if https.Kind != kindHTTPS || https.Path != "/g.git" {
		t.Fatalf("classify = %+v", https)
	}
	if wouldSendCleartext(https) {
		t.Fatal("https flagged cleartext")
	}
	if https.SNI != defaultSNI || https.Port != 24541 {
		t.Fatalf("dial fields = %+v", https)
	}
	http := classify("http://10.0.0.2/g.git")
	if !wouldSendCleartext(http) {
		t.Fatal("http must be cleartext")
	}
	if http.Kind == kindHTTPS {
		t.Fatal("http must not classify as https")
	}
}

// --- #2203 fetch/pull host tests -----------------------------------------
// The wire half (httpsRequest/extractPack over tls.Dial) is class-B only;
// everything past the pack — want/have body shape, thin-pack resolution,
// the pull plan, dirty refusal, ref ordering — runs here over a map FS.

type memErr string

func (e memErr) Error() string { return string(e) }

var errMemFS = memErr("memfs: no such file")

// memFS is a map-backed gitread.FS; ReadDir derives directory rows from
// key prefixes (an absent dir is an error, like the guest channel).
type memFS struct {
	files map[string][]byte
}

func (m *memFS) ReadFile(path string) ([]byte, error) {
	b, ok := m.files[path]
	if !ok {
		return nil, errMemFS
	}
	return b, nil
}

func (m *memFS) ReadDir(path string) ([]gitread.DirInfo, error) {
	pref := path + "/"
	seen := map[string]bool{}
	var out []gitread.DirInfo
	for p := range m.files {
		if len(p) <= len(pref) || p[:len(pref)] != pref {
			continue
		}
		rest := p[len(pref):]
		i := -1
		for j := 0; j < len(rest); j++ {
			if rest[j] == '/' {
				i = j
				break
			}
		}
		name := rest
		isDir := false
		if i >= 0 {
			name = rest[:i]
			isDir = true
		}
		if !seen[name] {
			seen[name] = true
			out = append(out, gitread.DirInfo{Name: name, IsDir: isDir})
		}
	}
	if len(out) == 0 {
		return nil, errMemFS
	}
	return out, nil
}

func memIO(m *memFS) workIO {
	return workIO{
		write: func(p string, b []byte) bool {
			m.files[p] = append([]byte{}, b...)
			return true
		},
		del: func(p string) bool {
			delete(m.files, p)
			return true
		},
		mkdir: func(p string) bool { return true },
	}
}

func mkBlob(s string) gitread.GitObj {
	o := gitread.GitObj{Type: gitread.ObjBlob, Data: []byte(s)}
	o.ID = gitread.HashObject(gitread.ObjBlob, o.Data)
	return o
}

func mkTree(ents ...gitread.TreeEnt) gitread.GitObj {
	var b []byte
	for _, e := range ents {
		b = append(b, []byte(e.Mode)...)
		b = append(b, ' ')
		b = append(b, []byte(e.Name)...)
		b = append(b, 0)
		b = append(b, e.ID[:]...)
	}
	o := gitread.GitObj{Type: gitread.ObjTree, Data: b}
	o.ID = gitread.HashObject(gitread.ObjTree, o.Data)
	return o
}

func mkCommit(tree gitread.GitObj, parent *gitread.GitObj, subject string) gitread.GitObj {
	s := "tree " + gitread.HexEncode(tree.ID[:]) + "\n"
	if parent != nil {
		s += "parent " + gitread.HexEncode(parent.ID[:]) + "\n"
	}
	s += "author g <g@g> 1000000000 +0000\ncommitter g <g@g> 1000000000 +0000\n\n" + subject + "\n"
	o := gitread.GitObj{Type: gitread.ObjCommit, Data: []byte(s)}
	o.ID = gitread.HashObject(gitread.ObjCommit, o.Data)
	return o
}

// pullFixture is the card's acceptance shape: c1 has HELLO, c2 (child of
// c1) punches HELLO and adds NEWS. seedClone lays out the c1 clone — all
// objects loose (the state fetch leaves the store in), HEAD on main at c1.
type pullFixture struct {
	b1, b2, b3 gitread.GitObj
	c1, c2     gitread.GitObj
	objs       []gitread.GitObj
}

func fxPull() pullFixture {
	b1 := mkBlob("hello one\n")
	b2 := mkBlob("hello two\n")
	b3 := mkBlob("news\n")
	t1 := mkTree(gitread.TreeEnt{Mode: "100644", Name: "HELLO", ID: b1.ID})
	t2 := mkTree(
		gitread.TreeEnt{Mode: "100644", Name: "HELLO", ID: b2.ID},
		gitread.TreeEnt{Mode: "100644", Name: "NEWS", ID: b3.ID},
	)
	c1 := mkCommit(t1, nil, "first")
	c2 := mkCommit(t2, &c1, "second")
	return pullFixture{b1, b2, b3, c1, c2, []gitread.GitObj{b1, b2, b3, t1, t2, c1, c2}}
}

func (f pullFixture) seedClone(m *memFS, root string, dirty map[string]string) {
	for _, o := range f.objs {
		hx := gitread.HexEncode(o.ID[:])
		m.files[root+"/.git/objects/"+hx[:2]+"/"+hx[2:]] = gitread.LooseBytes(o)
	}
	m.files[root+"/.git/HEAD"] = []byte("ref: refs/heads/main\n")
	m.files[root+"/.git/refs/heads/main"] = []byte(gitread.HexEncode(f.c1.ID[:]) + "\n")
	files := map[string]string{"HELLO": "hello one\n"}
	for p, c := range dirty {
		files[p] = c
	}
	for p, c := range files {
		m.files[root+"/"+p] = []byte(c)
	}
}

func TestFetchBodyShape(t *testing.T) {
	want := gitread.HashObject(gitread.ObjCommit, []byte("c2"))
	have := gitread.HashObject(gitread.ObjCommit, []byte("c1"))
	body := fetchBody(want, have)
	// want<caps> / flush / have / done — the stateless-rpc single round.
	var pkts []pkt
	b := body
	for len(b) > 0 {
		p, r, err := pktRead(b)
		if err != nil {
			t.Fatalf("pktRead at %q: %v", b, err)
		}
		pkts = append(pkts, p)
		b = r
	}
	if len(pkts) != 4 || !pkts[1].Flush {
		t.Fatalf("pkts = %+v", pkts)
	}
	wantLine := "want " + gitread.HexEncode(want[:]) + fetchCaps + "\n"
	if string(pkts[0].Data) != wantLine {
		t.Fatalf("want = %q want %q", pkts[0].Data, wantLine)
	}
	if string(pkts[2].Data) != "have "+gitread.HexEncode(have[:])+"\n" {
		t.Fatalf("have = %q", pkts[2].Data)
	}
	if string(pkts[3].Data) != "done\n" {
		t.Fatalf("done = %q", pkts[3].Data)
	}
}

func TestPlanPullClean(t *testing.T) {
	f := fxPull()
	m := &memFS{files: map[string][]byte{}}
	f.seedClone(m, "/host/G", nil)
	oldFiles := map[string][20]byte{"HELLO": f.b1.ID}
	newFiles := map[string][20]byte{"HELLO": f.b2.ID, "NEWS": f.b3.ID}
	writes, dels, dirty := planPull(m, "/host/G", oldFiles, newFiles)
	if dirty != "" {
		t.Fatalf("dirty = %q on a clean tree", dirty)
	}
	if len(writes) != 2 || writes[0] != "HELLO" || writes[1] != "NEWS" || len(dels) != 0 {
		t.Fatalf("plan = %v %v", writes, dels)
	}
}

func TestPlanPullDirtyRefuses(t *testing.T) {
	f := fxPull()
	m := &memFS{files: map[string][]byte{}}
	f.seedClone(m, "/host/G", map[string]string{"HELLO": "local edit\n"})
	oldFiles := map[string][20]byte{"HELLO": f.b1.ID}
	newFiles := map[string][20]byte{"HELLO": f.b2.ID, "NEWS": f.b3.ID}
	_, _, dirty := planPull(m, "/host/G", oldFiles, newFiles)
	if dirty != "HELLO" {
		t.Fatalf("dirty = %q want HELLO", dirty)
	}
}

func TestPlanPullUntrackedCollisionRefuses(t *testing.T) {
	f := fxPull()
	m := &memFS{files: map[string][]byte{}}
	// NEWS exists locally but was never tracked — pull must not clobber it.
	f.seedClone(m, "/host/G", map[string]string{"NEWS": "mine\n"})
	oldFiles := map[string][20]byte{"HELLO": f.b1.ID}
	newFiles := map[string][20]byte{"HELLO": f.b2.ID, "NEWS": f.b3.ID}
	_, _, dirty := planPull(m, "/host/G", oldFiles, newFiles)
	if dirty != "NEWS" {
		t.Fatalf("dirty = %q want NEWS", dirty)
	}
}

func TestPlanPullDelete(t *testing.T) {
	f := fxPull()
	m := &memFS{files: map[string][]byte{}}
	f.seedClone(m, "/host/G", nil)
	// Remote dropped HELLO entirely.
	oldFiles := map[string][20]byte{"HELLO": f.b1.ID}
	newFiles := map[string][20]byte{}
	writes, dels, dirty := planPull(m, "/host/G", oldFiles, newFiles)
	if dirty != "" || len(writes) != 0 || len(dels) != 1 || dels[0] != "HELLO" {
		t.Fatalf("plan = %v %v dirty=%q", writes, dels, dirty)
	}
	// A dirty file the remote deleted is still a refusal.
	m.files["/host/G/HELLO"] = []byte("dirty\n")
	_, _, dirty = planPull(m, "/host/G", oldFiles, newFiles)
	if dirty != "HELLO" {
		t.Fatalf("dirty delete = %q", dirty)
	}
	// And a file already gone locally deletes silently.
	delete(m.files, "/host/G/HELLO")
	_, dels, dirty = planPull(m, "/host/G", oldFiles, newFiles)
	if dirty != "" || len(dels) != 0 {
		t.Fatalf("missing-file delete: dels=%v dirty=%q", dels, dirty)
	}
}

// TestPullApplyAdvance is the card's pull-after-advance at host scale:
// the store holds both commits (as fetch leaves it), the worktree is the
// c1 clone, and pullApply must write c2's files and advance the branch
// ref — skip either and this fails.
func TestPullApplyAdvance(t *testing.T) {
	f := fxPull()
	m := &memFS{files: map[string][]byte{}}
	f.seedClone(m, "/host/G", nil)
	repo, err := gitread.Open(m, "/host/G")
	if err != nil {
		t.Fatal(err)
	}
	detail, ok := pullApply(repo, "/host/G", "/host/G/.git", "refs/heads/main",
		f.c1.ID, f.c2.ID, memIO(m))
	if !ok {
		t.Fatalf("pullApply = %q", detail)
	}
	if string(m.files["/host/G/HELLO"]) != "hello two\n" {
		t.Fatalf("HELLO = %q", m.files["/host/G/HELLO"])
	}
	if string(m.files["/host/G/NEWS"]) != "news\n" {
		t.Fatalf("NEWS = %q", m.files["/host/G/NEWS"])
	}
	wantRef := gitread.HexEncode(f.c2.ID[:]) + "\n"
	if string(m.files["/host/G/.git/refs/heads/main"]) != wantRef {
		t.Fatalf("ref = %q want %q", m.files["/host/G/.git/refs/heads/main"], wantRef)
	}
}

func TestPullApplyDirtyRefusesUntouched(t *testing.T) {
	f := fxPull()
	m := &memFS{files: map[string][]byte{}}
	f.seedClone(m, "/host/G", map[string]string{"HELLO": "local edit\n"})
	repo, err := gitread.Open(m, "/host/G")
	if err != nil {
		t.Fatal(err)
	}
	detail, ok := pullApply(repo, "/host/G", "/host/G/.git", "refs/heads/main",
		f.c1.ID, f.c2.ID, memIO(m))
	if ok || detail != "dirty HELLO" {
		t.Fatalf("pullApply = ok=%v detail=%q", ok, detail)
	}
	// Nothing moved: worktree and ref exactly as the refusal found them.
	if string(m.files["/host/G/HELLO"]) != "local edit\n" {
		t.Fatalf("dirty HELLO was touched: %q", m.files["/host/G/HELLO"])
	}
	if _, exists := m.files["/host/G/NEWS"]; exists {
		t.Fatal("refusing pull still wrote NEWS")
	}
	wantRef := gitread.HexEncode(f.c1.ID[:]) + "\n"
	if string(m.files["/host/G/.git/refs/heads/main"]) != wantRef {
		t.Fatal("refusing pull advanced the ref")
	}
}

func TestPullApplyNonFFRefuses(t *testing.T) {
	f := fxPull()
	m := &memFS{files: map[string][]byte{}}
	f.seedClone(m, "/host/G", nil)
	repo, err := gitread.Open(m, "/host/G")
	if err != nil {
		t.Fatal(err)
	}
	// A remote commit that does NOT descend from c1 — parallel history.
	bx := mkBlob("other\n")
	tx := mkTree(gitread.TreeEnt{Mode: "100644", Name: "OTHER", ID: bx.ID})
	cx := mkCommit(tx, nil, "unrelated")
	hx := gitread.HexEncode(cx.ID[:])
	m.files["/host/G/.git/objects/"+hx[:2]+"/"+hx[2:]] = gitread.LooseBytes(cx)
	hx = gitread.HexEncode(tx.ID[:])
	m.files["/host/G/.git/objects/"+hx[:2]+"/"+hx[2:]] = gitread.LooseBytes(tx)
	hx = gitread.HexEncode(bx.ID[:])
	m.files["/host/G/.git/objects/"+hx[:2]+"/"+hx[2:]] = gitread.LooseBytes(bx)
	detail, ok := pullApply(repo, "/host/G", "/host/G/.git", "refs/heads/main",
		f.c1.ID, cx.ID, memIO(m))
	if ok || detail != "non-ff" {
		t.Fatalf("pullApply = ok=%v detail=%q", ok, detail)
	}
	wantRef := gitread.HexEncode(f.c1.ID[:]) + "\n"
	if string(m.files["/host/G/.git/refs/heads/main"]) != wantRef {
		t.Fatal("non-ff pull advanced the ref")
	}
}

func TestReaches(t *testing.T) {
	f := fxPull()
	m := &memFS{files: map[string][]byte{}}
	f.seedClone(m, "/host/G", nil)
	repo, err := gitread.Open(m, "/host/G")
	if err != nil {
		t.Fatal(err)
	}
	if !reaches(repo, f.c1.ID, f.c2.ID) {
		t.Fatal("c1 not seen as c2 ancestor")
	}
	if reaches(repo, f.c2.ID, f.c1.ID) {
		t.Fatal("c2 seen as c1 ancestor")
	}
	if !reaches(repo, f.c1.ID, f.c1.ID) {
		t.Fatal("self not reached")
	}
}

func TestMarkers(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerStart, "gotgit: start"},
		{markerOK, "gotgit OK"},
		{markerBlob, "gotgit: blob "},
		{markerTree, "gotgit: tree "},
		{markerCommit, "gotgit: commit "},
		{markerDelta, "gotgit: delta"},
		{markerDial, "gotgit: dial "},
		{markerHS, "gotgit: handshake ok"},
		{markerFetch, "gotgit: fetch "},
		{markerHave, "gotgit: have "},
		{markerUpToDate, "gotgit: up-to-date"},
		{markerPull, "gotgit: pull "},
		{markerRm, "gotgit: rm "},
		{defaultSNI, "leaf.example.com"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}
