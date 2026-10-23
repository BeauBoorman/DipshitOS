package store

import (
	"strings"

	"virelai/sshlib"
)

// M101d (#2316): update and rollback.
//
// `store update <name>` is the same verify-before-materialize pipeline
// as install, pointed at a store-tracked app: pull moves the local
// replica forward (the staged half), the M101b keyring + Ed25519 gate
// re-runs, the fetched release.go is re-authenticated atom-for-atom
// against the new head's signed ops, and the ELF is sha-checked — all
// BEFORE any live path is touched. Publish is five WriteFileSafes and a
// remove: <BIN>.prev.new (the new rollback bytes STAGED under a second
// name — <BIN>.prev itself is never touched before the commit, so a
// killed publish cannot destroy the target the still-live PrevSHA
// names), <BIN>, APPS.TXT's row (replaced in place), STORE.TXT's
// {head, sha256, prev_*} line — the state write is what commits the
// update — and finally <BIN>.prev rotating to the same bytes. A kill
// before the commit leaves the old install live and the old PrevSHA's
// bytes intact at <BIN>.prev; a kill after it leaves the staged file
// matching the NEW PrevSHA.
//
// `store rollback <name>` re-materializes the retained head: the
// rollback bytes come from whichever of <BIN>.prev (the published
// name) or <BIN>.prev.new (the staged survivor of a killed publish)
// hashes to STORE.TXT's prev_sha256, are published over <BIN>, the
// prior manifest row is restored verbatim, the replaced ELF rotates
// through the same staged->commit->publish order, and the state pair
// swaps — a second rollback walks back forward.
//
// Torn publishes (kill after the ELF write, before the state write)
// diverge the live ELF from state sha256; update and rollback detect
// that and refuse state_mismatch rather than rolling forward on a lie.

// loadTrackedApp resolves `update`/`rollback`'s name argument to a
// STORE.TXT entry and checks the live files still match it: installed
// ELF bytes hash to sha256 (torn-publish detection) and APPS.TXT still
// carries the row. Divergence refuses state_mismatch — STORE never
// rolls forward over installed bytes it cannot account for.
func loadTrackedApp(fs FS, arg string) (bin string, ent *storeEntry, lines []string, curELF []byte, curRow string, err error) {
	bin, ok := normalizeBin(arg)
	if !ok {
		err = refuse("name_invalid", arg)
		return
	}
	var state map[string]*storeEntry
	state, err = loadState(fs)
	if err != nil {
		return
	}
	var found bool
	ent, found = state[bin]
	if !found {
		err = refuse("not_installed", bin)
		return
	}
	curELF, err = fs.ReadFile("/host/"+bin, MaxELFBytes)
	if err != nil {
		err = refuse("state_mismatch", bin)
		return
	}
	curSum := sshlib.SHA256Sum(curELF)
	if sshlib.EncodeHex(curSum[:]) != ent.SHA256 {
		err = refuse("state_mismatch", bin)
		return
	}
	lines, err = loadManifest(fs)
	if err != nil {
		return
	}
	curRow, found = manifestRowFor(lines, bin)
	if !found {
		err = refuse("state_mismatch", bin)
		return
	}
	return
}

// Update implements `store update <name> [--remote=<r>]
// [--channel=<c>]`.
func Update(fs FS, root, arg, remoteFlag, channelArg string) int {
	ConsoleFn("store: update " + arg)
	bin, ent, lines, curELF, curRow, err := loadTrackedApp(fs, arg)
	if err != nil {
		return runErr(err)
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

	// Pull stages the new head into the local replica (clone if the
	// replica was wiped); nothing live has moved yet.
	byName, _, err := listStreamRecords(fs, root)
	if err != nil {
		return runErr(err)
	}
	emitLeg("sync")
	if err := syncStream(fs, remote, ent.Stream, byName); err != nil {
		return runErr(err)
	}
	byName, _, err = listStreamRecords(fs, root)
	if err != nil {
		return runErr(err)
	}
	rec, ok := byName[ent.Stream]
	if !ok || rec.Head == nil {
		return runErr(refuse("stream_missing", ent.Stream))
	}
	newHead := *rec.Head
	if newHead == ent.Head {
		ConsoleFn("store: update " + bin + " up to date")
		return 0
	}

	// The head moved: re-run the whole M101b/c gate over the new head —
	// keyring + Ed25519 (in the FLINT.ELF child, `verify --all --trusted`
	// bound to the exact log bytes below), signed release.go atom match,
	// ELF sha256.
	emitLeg("verify")
	ConsoleFn("store: verify " + ent.Stream)
	logBytes, err := streamLogBytes(fs, root, rec.ID)
	if err != nil {
		return runErr(err)
	}
	if err := verifyStore(rec.ID, logBytes); err != nil {
		return runErr(err)
	}
	ConsoleFn("store: verified " + ent.Stream)
	signed, _, err := headReleaseOps(logBytes, rec.Head)
	if err != nil {
		return runErr(err)
	}
	if len(signed) == 0 {
		return runErr(refuse("release_missing", ent.Stream))
	}
	emitLeg("fetch")
	src, err := ch.fetch(ent.Stream+"/"+releaseFile, MaxReleaseBytes)
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
	if rel.Name+".ELF" != bin {
		return runErr(refuse("name_mismatch", bin))
	}
	// An update's manifest can declare deps the install predates — the
	// same D8 resolution runs before the new bytes land.
	emitLeg("deps")
	if err := resolveDeps(fs, root, rel, remoteFlag, channelArg, []string{rel.Name}); err != nil {
		return runErr(err)
	}
	elf, err := ch.fetch(ent.Stream+"/"+bin, MaxELFBytes)
	if err != nil {
		return runErr(err)
	}
	emitLeg("sha")
	sum := sshlib.SHA256Sum(elf)
	if sshlib.EncodeHex(sum[:]) != rel.ELFSHA256 {
		return runErr(refuse("elf_mismatch", bin))
	}
	manifest, err := manifestWithBinRow(lines, bin, rel.ManifestRow)
	if err != nil {
		return runErr(err)
	}

	// Publish. Order is the crash contract — see swapPublish.
	emitLeg("publish")
	if err := swapPublish(fs, bin, curELF, elf, manifest, &storeEntry{
		Name: bin, Stream: ent.Stream, Head: newHead, SHA256: rel.ELFSHA256,
		Caps:     strings.Join(rel.Caps, ","),
		PrevHead: ent.Head, PrevSHA: ent.SHA256, PrevCaps: ent.Caps, PrevRow: curRow,
	}); err != nil {
		return runErr(err)
	}
	ConsoleFn("store: update ok " + bin + " version=" + rel.Version)
	grantSync(bin, rel.ELFSHA256, rel.Caps)
	return 0
}

// prevStagePath is the staging name an update or rollback writes the new
// rollback bytes to BEFORE the state commit — never <bin>.prev~, which
// is WriteFileSafe's own sacrificial temp for <bin>.prev.
func prevStagePath(bin string) string { return "/host/" + bin + ".prev.new" }

// swapPublish runs the staged-publish contract update and pin's
// installed path share. Order is the crash contract: the new rollback
// bytes are STAGED at <bin>.prev.new first — .prev is never written
// before the commit, so a kill anywhere in the publish cannot destroy
// the target the still-live PrevSHA names — the ELF itself is the
// atomic point (old install live until it lands), the row follows the
// bytes it launches, the STORE.TXT swap commits, and only then does
// .prev rotate to the staged bytes. A kill between the commit and the
// rotation leaves PrevSHA naming <bin>.prev.new instead of <bin>.prev;
// rollback reads whichever matches.
func swapPublish(fs FS, bin string, curELF, newELF, manifest []byte, e *storeEntry) error {
	if err := fs.WriteFileSafe(prevStagePath(bin), curELF); err != nil {
		return err
	}
	if err := fs.WriteFileSafe("/host/"+bin, newELF); err != nil {
		return err
	}
	if err := fs.WriteFileSafe(appsPath, manifest); err != nil {
		return err
	}
	state, err := loadState(fs)
	if err != nil {
		return err
	}
	state[bin] = e
	if err := fs.WriteFileSafe(statePath, renderState(state)); err != nil {
		return err
	}
	emitLeg("prev")
	if err := fs.WriteFileSafe(prevPath(bin), curELF); err != nil {
		// Committed already: the staged file still hashes to the new
		// PrevSHA, so rollback is not lost — but the rotation did not
		// land, so report the publish incomplete.
		return err
	}
	_ = fs.Remove(prevStagePath(bin))
	return nil
}

// readRollbackBytes returns the retained prior ELF: whichever of
// <bin>.prev (the published name) or <bin>.prev.new (the staged survivor
// of a publish killed between the state commit and the .prev rotation)
// hashes to PrevSHA wins. Neither file existing is prev_missing; bytes
// matching on neither is prev_mismatch.
func readRollbackBytes(fs FS, bin string, ent *storeEntry) ([]byte, error) {
	exists := false
	for _, p := range []string{prevPath(bin), prevStagePath(bin)} {
		if !fs.Exists(p) {
			continue
		}
		exists = true
		b, err := fs.ReadFile(p, MaxELFBytes)
		if err != nil {
			continue
		}
		sum := sshlib.SHA256Sum(b)
		if sshlib.EncodeHex(sum[:]) == ent.PrevSHA {
			return b, nil
		}
	}
	if !exists {
		return nil, refuse("prev_missing", bin)
	}
	return nil, refuse("prev_mismatch", bin)
}

// Rollback implements `store rollback <name>`: publish the retained
// bytes (sha-checked against STORE.TXT over both candidate names),
// restore the prior row, rotate .prev to the ELF being replaced through
// the same staged->commit->publish order update uses, and swap the
// state pair.
func Rollback(fs FS, arg string) int {
	ConsoleFn("store: rollback " + arg)
	bin, ent, lines, curELF, curRow, err := loadTrackedApp(fs, arg)
	if err != nil {
		return runErr(err)
	}
	if ent.PrevHead == "" {
		return runErr(refuse("no_rollback", bin))
	}
	emitLeg("prev")
	prevELF, err := readRollbackBytes(fs, bin, ent)
	if err != nil {
		return runErr(err)
	}
	manifest, err := manifestWithBinRow(lines, bin, ent.PrevRow)
	if err != nil {
		return runErr(err)
	}
	emitLeg("publish")
	if err := fs.WriteFileSafe(prevStagePath(bin), curELF); err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe("/host/"+bin, prevELF); err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe(appsPath, manifest); err != nil {
		return runErr(err)
	}
	state, err := loadState(fs)
	if err != nil {
		return runErr(err)
	}
	state[bin] = &storeEntry{
		Name: bin, Stream: ent.Stream, Head: ent.PrevHead, SHA256: ent.PrevSHA,
		Caps:     ent.PrevCaps,
		PrevHead: ent.Head, PrevSHA: ent.SHA256, PrevCaps: ent.Caps, PrevRow: curRow,
	}
	if err := fs.WriteFileSafe(statePath, renderState(state)); err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe(prevPath(bin), curELF); err != nil {
		return runErr(err)
	}
	_ = fs.Remove(prevStagePath(bin))
	ConsoleFn("store: rollback ok " + bin + " head=" + ent.PrevHead)
	// The live sha is back at PrevSHA: re-pin the grant row to the image
	// the user rolled back to — the same non-widening keep update runs.
	grantSync(bin, ent.PrevSHA, splitGrantWords(ent.PrevCaps))
	return 0
}
