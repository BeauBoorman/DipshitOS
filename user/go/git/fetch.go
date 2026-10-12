package main

import (
	"sort"

	"virelai/git/gitread"
	"virelai/vi"
)

// Fetch/pull on an existing clone (#2203): the same wire surface clone
// exercises, run a second time. Fetch negotiates want/have with thin-pack
// advertised — ref-delta bases the sender omits resolve through
// ParsePackThin against the object store already on disk — then writes the
// new objects and advances refs/remotes/origin/<branch> + FETCH_HEAD,
// never the worktree or the checked-out branch. Pull = fetch + a
// fast-forward-only worktree update; a non-FF remote or a dirty tree
// refuses with an honest error, never a silent overwrite. No push, no
// merge machinery, no shallow.

const (
	markerFetch    = "gotgit: fetch "
	markerHave     = "gotgit: have "
	markerUpToDate = "gotgit: up-to-date"
	markerPull     = "gotgit: pull "
	markerRm       = "gotgit: rm "
)

// fetchCaps is what clone's want line does not negotiate: thin-pack lets
// the sender emit ref-deltas against objects the client already holds,
// ofs-delta is the in-pack kind clone already resolves.
const fetchCaps = " thin-pack ofs-delta"

// fetchBody is the fetch POST body — the stateless-rpc single round git
// itself sends over smart HTTP: the want line carries the capabilities, a
// flush ends the want block, the have line names the one ref we track,
// then done closes the negotiation.
func fetchBody(want, have [20]byte) []byte {
	out := pktEncodeString("want " + gitread.HexEncode(want[:]) + fetchCaps + "\n")
	out = append(out, pktFlush()...)
	out = append(out, pktEncodeString("have "+gitread.HexEncode(have[:])+"\n")...)
	out = append(out, pktEncodeString("done\n")...)
	return out
}

// openExisting opens a clone's store + HEAD. fetch/pull never invent the
// checkout clone makes: a dest that is not already a repository is
// refused, not created.
func openExisting(dest string) (*gitread.Repo, string, [20]byte, bool) {
	repo, err := gitread.Open(gitread.VirelaiFS{}, dest)
	if err != nil {
		return nil, "", [20]byte{}, false
	}
	refName, ok := repo.HeadRef()
	if !ok {
		return nil, "", [20]byte{}, false
	}
	head, err := repo.Head()
	if err != nil {
		return nil, "", [20]byte{}, false
	}
	return repo, refName, head, true
}

func findRef(refs []gitRef, name string) ([20]byte, bool) {
	for _, r := range refs {
		if r.Name == name {
			return r.SHA, true
		}
	}
	return [20]byte{}, false
}

// fetchRemote is the wire half shared by fetch and pull: advertise,
// compare against our head, negotiate want/have, parse the (possibly thin)
// pack against the store, write objects + the remote-tracking ref +
// FETCH_HEAD. changed=false is the clean no-op — the remote still sits at
// our head and the POST never happened.
func fetchRemote(tgt target, gitDir string, repo *gitread.Repo, refName string, local [20]byte) (remote [20]byte, changed bool, ok bool) {
	rp := repoPath(tgt)
	sni := tgt.SNI
	if sni == "" {
		sni = defaultSNI
	}

	vi.ConsoleLine(markerDial + tgt.Host + " " + portString(tgt.Port) + " " + sni + " GET")
	resp, err := httpsRequest(tgt, "GET", infoRefsPath(rp), nil)
	if err != nil {
		return remote, false, fail("https GET " + err.Error())
	}
	vi.ConsoleLine(markerHS)
	_, body, err := splitHTTP(resp)
	if err != nil {
		return remote, false, fail("http refs")
	}
	refs, err := parseInfoRefs(body)
	if err != nil {
		return remote, false, fail("parse refs")
	}
	vi.ConsoleLine(markerRefs + gitread.Uitoa(uint64(len(refs))))
	remote, ok = findRef(refs, refName)
	if !ok {
		return remote, false, fail("remote ref gone")
	}
	if remote == local {
		vi.ConsoleLine(markerUpToDate)
		return remote, false, true
	}
	vi.ConsoleLine(markerWant + refName + " " + gitread.HexEncode(remote[:]))
	vi.ConsoleLine(markerHave + gitread.HexEncode(local[:]))

	vi.ConsoleLine(markerDial + tgt.Host + " " + portString(tgt.Port) + " " + sni + " POST")
	resp, err = httpsRequest(tgt, "POST", uploadPackPath(rp), fetchBody(remote, local))
	if err != nil {
		return remote, false, fail("https POST " + err.Error())
	}
	vi.ConsoleLine(markerHS)
	_, body, err = splitHTTP(resp)
	if err != nil {
		return remote, false, fail("http pack")
	}
	pack, err := extractPack(body)
	if err != nil {
		return remote, false, fail("extract pack")
	}
	objs, nDelta, err := gitread.ParsePackThin(pack, repo.Get)
	if err != nil {
		return remote, false, fail("parse pack")
	}
	vi.ConsoleLine(markerPack + gitread.Uitoa(uint64(len(objs))))
	if nDelta > 0 {
		vi.ConsoleLine(markerDelta)
	}
	if len(objs) == 0 {
		return remote, false, fail("empty pack")
	}
	noteFetched(objs)
	if !writeObjects(gitDir, objs) {
		return remote, false, fail("store")
	}
	if !writeRemoteRefs(gitDir, refName, remote, guestIO) {
		return remote, false, fail("remote ref")
	}
	vi.ConsoleLine(markerFetch + gitread.HexEncode(remote[:]))
	return remote, true, true
}

// noteFetched logs the objects a fetch landed. Unlike clone's
// noteObjects there is no all-three-types floor: a fetch that only
// deletes files legitimately carries no new blob.
func noteFetched(objs []gitread.GitObj) {
	for _, o := range objs {
		switch o.Type {
		case gitread.ObjBlob:
			vi.ConsoleLine(markerBlob + gitread.HexEncode(o.ID[:]))
		case gitread.ObjTree:
			vi.ConsoleLine(markerTree + gitread.HexEncode(o.ID[:]))
		case gitread.ObjCommit:
			vi.ConsoleLine(markerCommit + gitread.HexEncode(o.ID[:]))
		}
	}
}

// writeObjects lands fetched objects loose — clone's writeStore stays
// untouched (it also owns HEAD and the branch ref, which fetch must not
// move), so the object loop is its own function. Re-writing an object we
// already hold publishes identical bytes; no dedup check earns its keep at
// this scale.
func writeObjects(gitDir string, objs []gitread.GitObj) bool {
	objDir, ok := gitread.JoinPath(gitDir, "objects")
	if !ok || !mkdir(objDir) {
		return false
	}
	for _, o := range objs {
		p, ok := gitread.ObjectPath(gitDir, o.ID)
		if !ok {
			return false
		}
		slash := lastSlash(p)
		if slash <= 0 || !mkdir(p[:slash]) {
			return false
		}
		if !writeFile(p, gitread.LooseBytes(o)) {
			return false
		}
	}
	return true
}

// writeRemoteRefs advances the remote-tracking ref and FETCH_HEAD.
// GOTGIT keeps no remote config — origin is the only remote, so the
// tracking ref is refs/remotes/origin/<leaf>. Every ref write here goes
// through WriteFileSafe (temp + fsync + delete-then-rename): the HF rename
// refuses an existing target, so "atomic" is really crash-safe publish —
// a failed write leaves the ref absent-or-old, never torn.
func writeRemoteRefs(gitDir, refName string, sha [20]byte, io workIO) bool {
	refs, ok := gitread.JoinPath(gitDir, "refs")
	if !ok || !io.mkdir(refs) {
		return false
	}
	remotes, ok := gitread.JoinPath(refs, "remotes")
	if !ok || !io.mkdir(remotes) {
		return false
	}
	origin, ok := gitread.JoinPath(remotes, "origin")
	if !ok || !io.mkdir(origin) {
		return false
	}
	leaf := refName
	if i := lastSlash(refName); i >= 0 {
		leaf = refName[i+1:]
	}
	track, ok := gitread.JoinPath(origin, leaf)
	if !ok {
		return false
	}
	if !io.write(track, []byte(gitread.HexEncode(sha[:])+"\n")) {
		return false
	}
	fh, ok := gitread.JoinPath(gitDir, "FETCH_HEAD")
	if !ok {
		return false
	}
	return io.write(fh, []byte(gitread.HexEncode(sha[:])+"\t\t"+refName+"\n"))
}

// writeLocalRef advances the checked-out branch — pull's LAST step, after
// the checkout, so a crash leaves the ref at the old commit rather than a
// ref ahead of the files on disk (git's own ordering).
func writeLocalRef(gitDir, refName string, sha [20]byte, io workIO) bool {
	refs, ok := gitread.JoinPath(gitDir, "refs")
	if !ok || !io.mkdir(refs) {
		return false
	}
	heads, ok := gitread.JoinPath(refs, "heads")
	if !ok || !io.mkdir(heads) {
		return false
	}
	leaf := refName
	if i := lastSlash(refName); i >= 0 {
		leaf = refName[i+1:]
	}
	p, ok := gitread.JoinPath(heads, leaf)
	if !ok {
		return false
	}
	return io.write(p, []byte(gitread.HexEncode(sha[:])+"\n"))
}

// reaches is the fast-forward test: walk desc's ancestry (all parents, so
// a merge in the remote history still counts) until anc turns up. Bounded
// at 512 commits so a cyclic or corrupt store refuses instead of spinning.
func reaches(repo *gitread.Repo, anc, desc [20]byte) bool {
	seen := map[[20]byte]bool{}
	queue := [][20]byte{desc}
	for len(queue) > 0 && len(seen) < 512 {
		cur := queue[0]
		queue = queue[1:]
		if seen[cur] {
			continue
		}
		seen[cur] = true
		if cur == anc {
			return true
		}
		o, ok := repo.Get(cur)
		if !ok || o.Type != gitread.ObjCommit {
			continue
		}
		if parents, ok := gitread.CommitParents(o.Data); ok {
			queue = append(queue, parents...)
		}
	}
	return false
}

// workPath builds a worktree path without JoinPath's single-component
// rule — tree paths carry their own slashes, the same convention
// status.go's worktree scan uses.
func workPath(root, rel string) string { return root + "/" + rel }

// workIO is the file-channel seam pull applies through — vi syscalls on
// the guest, a map in host tests — so the refuse/apply ordering is
// exercised off the VM.
type workIO struct {
	write func(path string, b []byte) bool
	del   func(path string) bool
	mkdir func(path string) bool
}

var guestIO = workIO{
	write: writeFile,
	del: func(p string) bool {
		rc := vi.FileDelete(p)
		return rc == 0 || rc == vi.ErrFileNotFound
	},
	mkdir: mkdirAll,
}

// planPull diffs the old and new head trees against the actual worktree
// and either returns the writes/deletes a fast-forward checkout needs or
// names the dirty path it refuses to clobber. A file the pull would change
// must still match the OLD head blob; a file the pull would add must not
// already exist. Losing a file the local tree already lost is a no-op.
func planPull(fs gitread.FS, root string, oldFiles, newFiles map[string][20]byte) (writes, deletes []string, dirty string) {
	for path, newID := range newFiles {
		oldID, had := oldFiles[path]
		if had && oldID == newID {
			continue
		}
		cur, err := fs.ReadFile(workPath(root, path))
		if !had {
			if err == nil {
				return nil, nil, path // would clobber an untracked file
			}
			writes = append(writes, path)
			continue
		}
		if err != nil || gitread.HashObject(gitread.ObjBlob, cur) != oldID {
			return nil, nil, path
		}
		writes = append(writes, path)
	}
	for path, oldID := range oldFiles {
		if _, still := newFiles[path]; still {
			continue
		}
		cur, err := fs.ReadFile(workPath(root, path))
		if err != nil {
			continue // already gone locally
		}
		if gitread.HashObject(gitread.ObjBlob, cur) != oldID {
			return nil, nil, path
		}
		deletes = append(deletes, path)
	}
	sort.Strings(writes)
	sort.Strings(deletes)
	return writes, deletes, ""
}

// applyPull executes a clean pull plan: blob contents come from the store
// (fetched objects are already loose), directories are created on the way,
// deletions go through the same channel.
func applyPull(repo *gitread.Repo, root string, newFiles map[string][20]byte, writes, deletes []string, io workIO) bool {
	for _, path := range writes {
		o, ok := repo.Get(newFiles[path])
		if !ok || o.Type != gitread.ObjBlob {
			return false
		}
		full := workPath(root, path)
		if i := lastSlash(full); i > 0 && !io.mkdir(full[:i]) {
			return false
		}
		if !io.write(full, o.Data) {
			return false
		}
		vi.ConsoleLine(markerCheck + path)
	}
	for _, path := range deletes {
		if !io.del(workPath(root, path)) {
			return false
		}
		vi.ConsoleLine(markerRm + path)
	}
	return true
}

// pullApply is the post-fetch half of pull, transport-free so host tests
// drive it over a map-backed FS: refuse a non-FF, refuse a dirty tree
// BEFORE a byte moves, check out, then advance the branch ref LAST.
func pullApply(repo *gitread.Repo, root, gitDir, refName string, local, remote [20]byte, io workIO) (string, bool) {
	if !reaches(repo, local, remote) {
		return "non-ff", false
	}
	oldFiles, err := repo.TreeFiles(local)
	if err != nil {
		return "old tree", false
	}
	newFiles, err := repo.TreeFiles(remote)
	if err != nil {
		return "new tree", false
	}
	writes, deletes, dirty := planPull(repo.FS, root, oldFiles, newFiles)
	if dirty != "" {
		return "dirty " + dirty, false
	}
	if !applyPull(repo, root, newFiles, writes, deletes, io) {
		return "checkout", false
	}
	if !writeLocalRef(gitDir, refName, remote, io) {
		return "ref update", false
	}
	return "", true
}

// doFetch is the whole `GOTGIT.ELF fetch`: open the clone, negotiate,
// store objects, advance the remote-tracking ref. Worktree untouched.
func doFetch(tgt target, dest, gitDir string) bool {
	repo, refName, local, ok := openExisting(dest)
	if !ok {
		return fail("open repo")
	}
	_, _, ok = fetchRemote(tgt, gitDir, repo, refName, local)
	return ok
}

// doPull is fetch + the merge half git's pull name promises, narrowed to
// fast-forward only: a remote that did not descend from our head refuses,
// and a worktree the update would clobber refuses BEFORE a byte moves.
// The fetch half (objects + tracking ref) already landed when the refusal
// fires — that is exactly where a real `git pull` leaves a dirty tree.
func doPull(tgt target, dest, gitDir string) bool {
	repo, refName, local, ok := openExisting(dest)
	if !ok {
		return fail("open repo")
	}
	remote, changed, ok := fetchRemote(tgt, gitDir, repo, refName, local)
	if !ok {
		return false
	}
	if !changed {
		return true // fetch already printed up-to-date
	}
	detail, ok := pullApply(repo, dest, gitDir, refName, local, remote, guestIO)
	if !ok {
		return fail(detail)
	}
	vi.ConsoleLine(markerPull + gitread.HexEncode(remote[:]))
	return true
}
