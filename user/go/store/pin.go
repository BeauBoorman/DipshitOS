package store

import (
	"strings"

	"virelai/sshlib"
)

// M188c (#3188): `store pin` — signed-head rollback. A release stream is
// a signed append-only fold, so installing a PRIOR signed head is a
// verify operation, not a rewrite: the replica's committed prefix
// already carries every older release's signed atom set, and the
// publisher's per-head member (<stream>/<head-change-hex>/, ADR 0055
// D9) carries the bytes those atoms authenticate. Pin selects the head,
// verifies the fetched release.go atom-for-atom against the fold AT
// that change, sha-checks the pinned ELF, resolves its deps, and
// publishes through the same staged contract update runs — the replaced
// install becomes the new .prev, so a pin is itself one step undoable.
//
// Selectors: `store pin <name>` picks the prior release head — the
// nearest release-touching change before the installed (or record) head
// whose fold still carries release atoms. `store pin <name> <head>`
// takes an explicit change id (dashed uuid or its 32-hex form). Named
// refusals: unsigned_history (the selector — or the recorded installed
// head — is not in the verified committed prefix), head_already (the
// selector IS the current head), no_such_release (the selection's fold
// carries no release atoms, or no prior release head exists).

// changeIDHex renders a change id in its dashed-free lowercase-hex form
// — the pinned member's directory name and the selector's match form.
func changeIDHex(id string) string {
	return strings.ToLower(strings.ReplaceAll(id, "-", ""))
}

// normChangeID validates a `pin` head selector: dashes tolerated, case
// folded, must decode to 32 hex chars — anything else is a usage
// refusal, not a lookup miss.
func normChangeID(sel string) (string, error) {
	h := changeIDHex(strings.TrimSpace(sel))
	if !isLowerHexN(h, 32) {
		return "", refuse("usage", sel)
	}
	return h, nil
}

// releaseAtomIDs collects the atom ids that ever carried a release.go
// span in the verified prefix — a delete op drops its span, so "this
// change touched the manifest" is decided by id membership, not by the
// op's own span.
func releaseAtomIDs(changes []Change) map[string]bool {
	out := map[string]bool{}
	for _, c := range changes {
		for _, op := range c.Ops {
			if op.NewSpan != nil && isReleasePath(op.NewSpan.File) {
				out[op.AtomID] = true
			}
		}
	}
	return out
}

// touchesRelease reports whether c carried an op on the manifest: a
// release.go-spanning op directly, or an op on an atom known to be a
// release atom (the delete case, whose op has no span).
func touchesRelease(c Change, relIDs map[string]bool) bool {
	for _, op := range c.Ops {
		if op.NewSpan != nil && isReleasePath(op.NewSpan.File) {
			return true
		}
		if relIDs[op.AtomID] {
			return true
		}
	}
	return false
}

// priorReleaseHead walks back from base and returns the index of the
// prior release head: the nearest earlier change that touched the
// manifest AND still folds to a nonempty release atom set — a
// manifest-deleting change is release-touching but pins nothing, so it
// is skipped, and a gap of unrelated changes is skipped with it.
func priorReleaseHead(changes []Change, base int) int {
	relIDs := releaseAtomIDs(changes[:base+1])
	for i := base - 1; i >= 0; i-- {
		if !touchesRelease(changes[i], relIDs) {
			continue
		}
		if len(foldReleaseOps(changes[:i+1])) > 0 {
			return i
		}
	}
	return -1
}

// Pin implements `store pin <name|stream> [<head>] [--remote=<r>]
// [--channel=<c>]`. A STORE.TXT-tracked name pins its own stream
// through the full state fences; anything else names a release stream
// directly and pinning it is install-at-that-head.
func Pin(fs FS, root, arg, sel, remoteFlag, channelArg string) int {
	ConsoleFn("store: pin " + arg)

	// The tracked-app branch runs loadTrackedApp's fences (installed ELF
	// still hashes to state, APPS.TXT still carries the row) before any
	// history work — pin never rolls over bytes it cannot account for.
	bin, normOK := normalizeBin(arg)
	var ent *storeEntry
	if normOK {
		state, err := loadState(fs)
		if err != nil {
			return runErr(err)
		}
		ent = state[bin]
	}
	var lines []string
	var curELF []byte
	var curRow string
	if ent != nil {
		var err error
		bin, ent, lines, curELF, curRow, err = loadTrackedApp(fs, arg)
		if err != nil {
			return runErr(err)
		}
	}
	streamName := arg
	if ent != nil {
		streamName = ent.Stream
	}

	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	ConsoleFn("store: remote " + remote)
	ch, err := openChannel(fs, channelArg)
	if err != nil {
		return runErr(err)
	}

	// Sync + verify: the same M101b gate install/update run — pull moves
	// the replica forward, `verify --all --trusted` binds the exact log
	// bytes this fold reads. History a share writer appended unsigned
	// dies inside the gate, before it can pose as a pin target.
	byName, _, err := listStreamRecords(fs, root)
	if err != nil {
		return runErr(err)
	}
	emitLeg("sync")
	if err := syncStream(fs, remote, streamName, byName); err != nil {
		return runErr(err)
	}
	byName, _, err = listStreamRecords(fs, root)
	if err != nil {
		return runErr(err)
	}
	rec, ok := byName[streamName]
	if !ok || rec.Head == nil {
		return runErr(refuse("stream_missing", streamName))
	}
	emitLeg("verify")
	ConsoleFn("store: verify " + streamName)
	logBytes, err := streamLogBytes(fs, root, rec.ID)
	if err != nil {
		return runErr(err)
	}
	if err := verifyStore(rec.ID, logBytes); err != nil {
		return runErr(err)
	}
	ConsoleFn("store: verified " + streamName)

	// Select the head. Only the committed prefix folds: a pull torn
	// between log append and record roll is verified-but-uncommitted —
	// headReleaseOps's posture, applied to selection.
	changes, err := parseStreamChanges(logBytes)
	if err != nil {
		return runErr(err)
	}
	headIdx := -1
	for i, c := range changes {
		if c.ID == *rec.Head {
			headIdx = i
			break
		}
	}
	if headIdx < 0 {
		return runErr(refuse("stream_malformed", "head not in log"))
	}
	baseline := *rec.Head
	if ent != nil {
		baseline = ent.Head
	}
	var target int
	if sel == "" {
		baseIdx := -1
		for i := 0; i <= headIdx; i++ {
			if changes[i].ID == baseline {
				baseIdx = i
				break
			}
		}
		if baseIdx < 0 {
			// The state file names a head the signed log does not —
			// the install's own history is unsigned from here.
			return runErr(refuse("unsigned_history", baseline))
		}
		target = priorReleaseHead(changes, baseIdx)
		if target < 0 {
			return runErr(refuse("no_such_release", arg))
		}
	} else {
		id, nerr := normChangeID(sel)
		if nerr != nil {
			return runErr(nerr)
		}
		target = -1
		for i := 0; i <= headIdx; i++ {
			if changeIDHex(changes[i].ID) == id {
				target = i
				break
			}
		}
		if target < 0 {
			return runErr(refuse("unsigned_history", sel))
		}
		if changes[target].ID == baseline {
			return runErr(refuse("head_already", sel))
		}
	}
	targetID := changes[target].ID

	// Fold the selected head's signed manifest atoms, then re-run the
	// whole materialization gate on the pinned member: atom-for-atom
	// manifest verify, dep resolution, ELF sha — history may be signed
	// and still fetch nothing (the member is the publisher's to keep;
	// its absence is channel_missing, its tamper is release_mismatch).
	signed := foldReleaseOps(changes[:target+1])
	if len(signed) == 0 {
		return runErr(refuse("no_such_release", arg))
	}
	member := streamName + "/" + changeIDHex(targetID)
	emitLeg("fetch")
	src, err := ch.fetch(member+"/"+releaseFile, MaxReleaseBytes)
	if err != nil {
		return runErr(err)
	}
	if err := verifyRelease(src, signed); err != nil {
		return runErr(err)
	}
	rel, err := parseRelease(src)
	if err != nil {
		return runErr(err)
	}
	if ent != nil && rel.Name+".ELF" != bin {
		return runErr(refuse("name_mismatch", bin))
	}
	emitLeg("deps")
	if err := resolveDeps(fs, root, rel, remoteFlag, channelArg, []string{rel.Name}); err != nil {
		return runErr(err)
	}
	pinBin := rel.Name + ".ELF"
	elf, err := ch.fetch(member+"/"+pinBin, MaxELFBytes)
	if err != nil {
		return runErr(err)
	}
	emitLeg("sha")
	sum := sshlib.SHA256Sum(elf)
	if sshlib.EncodeHex(sum[:]) != rel.ELFSHA256 {
		return runErr(refuse("elf_mismatch", pinBin))
	}

	emitLeg("publish")
	if ent != nil {
		// Installed: the replaced bytes become the new rollback target
		// through the same staged->commit->rotate contract update runs.
		manifest, err := manifestWithBinRow(lines, bin, rel.ManifestRow)
		if err != nil {
			return runErr(err)
		}
		if err := swapPublish(fs, bin, curELF, elf, manifest, &storeEntry{
			Name: bin, Stream: streamName, Head: targetID, SHA256: rel.ELFSHA256,
			Caps:     strings.Join(rel.Caps, ","),
			PrevHead: ent.Head, PrevSHA: ent.SHA256, PrevCaps: ent.Caps, PrevRow: curRow,
		}); err != nil {
			return runErr(err)
		}
	} else {
		// Untracked stream: pin is install-at-head — the same publish
		// tail install runs, state head pinned to the selection.
		mLines, err := loadManifest(fs)
		if err != nil {
			return runErr(err)
		}
		done, err := materializeRelease(fs, rel, elf, pinBin, streamName, targetID, mLines)
		if err != nil {
			return runErr(err)
		}
		if done {
			return 0
		}
	}
	ConsoleFn("store: pin ok " + pinBin + " head=" + targetID + " version=" + rel.Version)
	grantSync(pinBin, rel.ELFSHA256, rel.Caps)
	return 0
}
