package main

import (
	"virelai/git/gitread"
	"virelai/vi"
)

// GOTGIT.ELF — git-over-https clone (issue #1337 / M67b #1447 / ADR 0029),
// fetch/pull second pass (#2203). HTTPS is in-process tls.Dial over vi.Dial.
// FETCHS.BIN is not referenced. Never a cleartext GET. No push.

const (
	appName = "GOTGIT.ELF"

	markerStart  = "gotgit: start"
	markerURL    = "gotgit: url "
	markerDial   = "gotgit: dial "
	markerHS     = "gotgit: handshake ok"
	markerRefs   = "gotgit: refs "
	markerWant   = "gotgit: want "
	markerPack   = "gotgit: pack objects="
	markerBlob   = "gotgit: blob "
	markerTree   = "gotgit: tree "
	markerCommit = "gotgit: commit "
	markerDelta  = "gotgit: delta"
	markerCheck  = "gotgit: checkout "
	markerOK     = "gotgit OK"
	markerErr    = "gotgit: error "

	// file_table MODE_DIR create returns -9 (EEXIST). ADR 0007 maps
	// magnitude 9 to ENXIO; vi has no ErrEXIST.
	errExist = int64(-9)
)

// argvPad keeps the Go sbrk heap from overlapping the kernel's argv+envp
// block (same GOFETCH.ELF fix). GOTGIT's data/BSS last-page tail was 0x330
// with a 2 KiB pad — still short of the 2304-byte argv+envp packing — so
// this is 4 KiB.
var argvPad [4096]byte

func main() {
	argvPad[0] = 1
	vi.ConsoleLine(markerStart)

	cmd, url, dest := startArgs()
	vi.ConsoleLine(markerURL + url)
	tgt := classify(url)
	if wouldSendCleartext(tgt) {
		fail("cleartext refused")
		return
	}
	if tgt.Kind != kindHTTPS {
		fail(tgt.Kind)
		return
	}

	gitDir, ok := gitread.JoinPath(dest, ".git")
	if !ok {
		fail("git dir")
		return
	}
	switch cmd {
	case "fetch":
		if !doFetch(tgt, dest, gitDir) {
			return
		}
	case "pull":
		if !doPull(tgt, dest, gitDir) {
			return
		}
	default: // clone
		if !mkdirAll(dest) {
			fail("mkdir dest")
			return
		}
		if !mkdirAll(gitDir) {
			fail("mkdir git")
			return
		}
		if !clone(tgt, dest, gitDir) {
			return
		}
	}
	vi.ConsoleLine(markerOK)
	vi.Exit(0)
}

func startArgs() (cmd, url, dest string) {
	args := vi.Args()
	cmd = "clone"
	url = "https://10.0.0.2:24541/g.git"
	dest = "/host/G"
	if len(args) > 1 && (args[1] == "clone" || args[1] == "fetch" || args[1] == "pull") {
		cmd = args[1]
		if len(args) > 2 && args[2] != "" {
			url = args[2]
		}
		if len(args) > 3 && args[3] != "" {
			dest = args[3]
		}
		return cmd, url, dest
	}
	// The pre-#2203 shape "GOTGIT <url> <dest>" stays a clone.
	if len(args) > 1 && args[1] != "" {
		url = args[1]
	}
	if len(args) > 2 && args[2] != "" {
		dest = args[2]
	}
	return cmd, url, dest
}

func clone(tgt target, dest, gitDir string) bool {
	repo := repoPath(tgt)
	sni := tgt.SNI
	if sni == "" {
		sni = defaultSNI
	}

	vi.ConsoleLine(markerDial + tgt.Host + " " + portString(tgt.Port) + " " + sni + " GET")
	resp, err := httpsRequest(tgt, "GET", infoRefsPath(repo), nil)
	if err != nil {
		return fail("https GET " + err.Error())
	}
	vi.ConsoleLine(markerHS)
	_, body, err := splitHTTP(resp)
	if err != nil {
		return fail("http refs")
	}
	refs, err := parseInfoRefs(body)
	if err != nil {
		return fail("parse refs")
	}
	vi.ConsoleLine(markerRefs + gitread.Uitoa(uint64(len(refs))))
	want, ok := pickWant(refs)
	if !ok {
		return fail("no want")
	}
	vi.ConsoleLine(markerWant + want.Name + " " + gitread.HexEncode(want.SHA[:]))

	vi.ConsoleLine(markerDial + tgt.Host + " " + portString(tgt.Port) + " " + sni + " POST")
	resp, err = httpsRequest(tgt, "POST", uploadPackPath(repo), wantBody(want.SHA))
	if err != nil {
		return fail("https POST " + err.Error())
	}
	vi.ConsoleLine(markerHS)
	_, body, err = splitHTTP(resp)
	if err != nil {
		return fail("http pack")
	}
	pack, err := extractPack(body)
	if err != nil {
		return fail("extract pack")
	}
	objs, nDelta, err := gitread.ParsePack(pack)
	if err != nil {
		return fail("parse pack")
	}
	vi.ConsoleLine(markerPack + gitread.Uitoa(uint64(len(objs))))
	if nDelta > 0 {
		vi.ConsoleLine(markerDelta)
	}
	if !noteObjects(objs) {
		return fail("empty pack")
	}
	if !writeStore(gitDir, objs, want) {
		return fail("store")
	}
	if !checkout(dest, objs, want.SHA) {
		return fail("checkout")
	}
	return true
}

func noteObjects(objs []gitread.GitObj) bool {
	var blobs, trees, commits int
	for _, o := range objs {
		switch o.Type {
		case gitread.ObjBlob:
			blobs++
			vi.ConsoleLine(markerBlob + gitread.HexEncode(o.ID[:]))
		case gitread.ObjTree:
			trees++
			vi.ConsoleLine(markerTree + gitread.HexEncode(o.ID[:]))
		case gitread.ObjCommit:
			commits++
			vi.ConsoleLine(markerCommit + gitread.HexEncode(o.ID[:]))
		}
	}
	return blobs > 0 && trees > 0 && commits > 0
}

func writeStore(gitDir string, objs []gitread.GitObj, want gitRef) bool {
	objDir, ok := gitread.JoinPath(gitDir, "objects")
	if !ok || !mkdir(objDir) {
		return false
	}
	refs, ok := gitread.JoinPath(gitDir, "refs")
	if !ok || !mkdir(refs) {
		return false
	}
	heads, ok := gitread.JoinPath(refs, "heads")
	if !ok || !mkdir(heads) {
		return false
	}
	for _, o := range objs {
		p, ok := gitread.ObjectPath(gitDir, o.ID)
		if !ok {
			return false
		}
		slash := lastSlash(p)
		if slash <= 0 {
			return false
		}
		if !mkdir(p[:slash]) {
			return false
		}
		if !writeFile(p, gitread.LooseBytes(o)) {
			return false
		}
	}
	headPath, ok := gitread.JoinPath(gitDir, "HEAD")
	if !ok {
		return false
	}
	refName := want.Name
	if refName == "HEAD" {
		refName = "refs/heads/main"
	}
	if !writeFile(headPath, []byte("ref: "+refName+"\n")) {
		return false
	}
	// refs/heads/main — last component only under heads/
	leaf := refName
	if i := lastSlash(refName); i >= 0 {
		leaf = refName[i+1:]
	}
	refPath, ok := gitread.JoinPath(heads, leaf)
	if !ok {
		return false
	}
	return writeFile(refPath, []byte(gitread.HexEncode(want.SHA[:])+"\n"))
}

func checkout(dest string, objs []gitread.GitObj, commitID [20]byte) bool {
	c, ok := gitread.FindObj(objs, commitID)
	if !ok || c.Type != gitread.ObjCommit {
		for _, o := range objs {
			if o.Type == gitread.ObjCommit {
				c = o
				ok = true
			}
		}
		if !ok {
			return false
		}
	}
	tid, ok := gitread.CommitTree(c.Data)
	if !ok {
		return false
	}
	tree, ok := gitread.FindObj(objs, tid)
	if !ok || tree.Type != gitread.ObjTree {
		return false
	}
	ents := gitread.ParseTree(tree.Data)
	wrote := false
	for _, e := range ents {
		if !gitread.IsBlobMode(e.Mode) {
			continue
		}
		blob, ok := gitread.FindObj(objs, e.ID)
		if !ok || blob.Type != gitread.ObjBlob {
			continue
		}
		p, ok := gitread.JoinPath(dest, e.Name)
		if !ok {
			continue
		}
		if !writeFile(p, blob.Data) {
			return false
		}
		vi.ConsoleLine(markerCheck + e.Name)
		wrote = true
	}
	return wrote
}

func lastSlash(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '/' {
			return i
		}
	}
	return -1
}

func mkdir(path string) bool {
	h, r := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if r >= 0 {
		vi.FileClose(uint32(h))
		return true
	}
	return r == errExist
}

func mkdirAll(path string) bool {
	if path == "" {
		return false
	}
	// one component at a time; parents must exist.
	start := 1
	if len(path) > 0 && path[0] != '/' {
		start = 0
	}
	for i := start; i <= len(path); i++ {
		if i < len(path) && path[i] != '/' {
			continue
		}
		if i == 0 {
			continue
		}
		comp := path[:i]
		if comp == "" || comp == "/" || comp == "/host" {
			if i == len(path) {
				break
			}
			continue
		}
		if !mkdir(comp) {
			return false
		}
		if i == len(path) {
			break
		}
	}
	return true
}

// writeFile publishes data to path crash-safe (M81e #1765): the sacrificial
// temp is written, fsync'd, and published (delete-then-rename) by
// vi.WriteFileSafe, so the live path is never truncated in place. A checkout
// is a tree of small files; before this, a crash mid-write left a truncated
// blob or ref where a valid one had been — a worktree the reader cannot trust.
func writeFile(path string, data []byte) bool {
	return vi.WriteFileSafe(path, data) >= 0
}

func readFile(path string) ([]byte, bool) {
	b, r := vi.ReadFileAll(path, vi.MaxFileBytes)
	if r < 0 || b == nil {
		return nil, false
	}
	return b, true
}

func fail(detail string) bool {
	vi.ConsoleLine(markerErr + detail)
	vi.Exit(1)
	return false
}
