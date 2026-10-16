package main

import (
	"virelai/sshlib"
)

// M101d (#2316): update and rollback.
//
// `store update <name>` is the same verify-before-materialize pipeline
// as install, pointed at a store-tracked app: pull moves the local
// replica forward (the staged half), the M101b keyring + Ed25519 gate
// re-runs, the fetched release.go is re-authenticated atom-for-atom
// against the new head's signed ops, and the ELF is sha-checked — all
// BEFORE any live path is touched. Publish is four WriteFileSafes:
// <BIN>.prev (the retained prior ELF — a FLINT head is only hashes, so
// rollback needs the bytes, never a re-fetch), <BIN>, APPS.TXT's row
// (replaced in place), STORE.TXT's {head, sha256, prev_*} line last —
// the state write is what commits the update; a kill anywhere earlier
// leaves the old install byte-identical.
//
// `store rollback <name>` re-materializes the retained head: the .prev
// bytes are sha-checked against STORE.TXT's prev_sha256, published over
// <BIN>, the prior manifest row is restored verbatim, .prev rotates to
// the ELF just replaced, and the state pair swaps — a second rollback
// walks back forward.
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

// cmdUpdate implements `store update <name> [--remote=<r>]
// [--channel=<c>]`.
func cmdUpdate(fs FS, root, arg, remoteFlag, channelArg string) int {
	consoleFn("store: update " + arg)
	bin, ent, lines, curELF, curRow, err := loadTrackedApp(fs, arg)
	if err != nil {
		return runErr(err)
	}
	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	consoleFn("store: remote " + remote)
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
		consoleFn("store: update " + bin + " up to date")
		return 0
	}

	// The head moved: re-run the whole M101b/c gate over the new head —
	// keyring + Ed25519 (in the FLINT.ELF child), signed release.go atom
	// match, ELF sha256.
	consoleFn("store: verify " + ent.Stream)
	if err := flint("verify", "--all"); err != nil {
		return runErr(err)
	}
	consoleFn("store: verified " + ent.Stream)
	signed, err := headReleaseOps(fs, root, rec.ID)
	if err != nil {
		return runErr(err)
	}
	if len(signed) == 0 {
		return runErr(refuse("release_missing", ent.Stream))
	}
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
	elf, err := ch.fetch(ent.Stream+"/"+bin, MaxELFBytes)
	if err != nil {
		return runErr(err)
	}
	sum := sshlib.SHA256Sum(elf)
	if sshlib.EncodeHex(sum[:]) != rel.ELFSHA256 {
		return runErr(refuse("elf_mismatch", bin))
	}
	manifest, err := manifestWithBinRow(lines, bin, rel.ManifestRow)
	if err != nil {
		return runErr(err)
	}

	// Publish. Order is the crash contract: .prev FIRST (the retained
	// bytes must exist before the live ELF moves), the ELF itself is
	// the atomic point (old install live until it lands), the row
	// follows the bytes it launches, the STORE.TXT swap commits last.
	if err := fs.WriteFileSafe(prevPath(bin), curELF); err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe("/host/"+bin, elf); err != nil {
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
		Name: bin, Stream: ent.Stream, Head: newHead, SHA256: rel.ELFSHA256,
		PrevHead: ent.Head, PrevSHA: ent.SHA256, PrevRow: curRow,
	}
	if err := fs.WriteFileSafe(statePath, renderState(state)); err != nil {
		return runErr(err)
	}
	consoleFn("store: update ok " + bin + " version=" + rel.Version)
	return 0
}

// cmdRollback implements `store rollback <name>`: publish the retained
// .prev bytes (sha-checked against STORE.TXT), restore the prior row,
// rotate .prev to the ELF being replaced, and swap the state pair.
func cmdRollback(fs FS, arg string) int {
	consoleFn("store: rollback " + arg)
	bin, ent, lines, curELF, curRow, err := loadTrackedApp(fs, arg)
	if err != nil {
		return runErr(err)
	}
	if ent.PrevHead == "" {
		return runErr(refuse("no_rollback", bin))
	}
	prevELF, err := fs.ReadFile(prevPath(bin), MaxELFBytes)
	if err != nil {
		return runErr(refuse("prev_missing", bin))
	}
	prevSum := sshlib.SHA256Sum(prevELF)
	if sshlib.EncodeHex(prevSum[:]) != ent.PrevSHA {
		return runErr(refuse("prev_mismatch", bin))
	}
	manifest, err := manifestWithBinRow(lines, bin, ent.PrevRow)
	if err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe("/host/"+bin, prevELF); err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe(appsPath, manifest); err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe(prevPath(bin), curELF); err != nil {
		return runErr(err)
	}
	state, err := loadState(fs)
	if err != nil {
		return runErr(err)
	}
	state[bin] = &storeEntry{
		Name: bin, Stream: ent.Stream, Head: ent.PrevHead, SHA256: ent.PrevSHA,
		PrevHead: ent.Head, PrevSHA: ent.SHA256, PrevRow: curRow,
	}
	if err := fs.WriteFileSafe(statePath, renderState(state)); err != nil {
		return runErr(err)
	}
	consoleFn("store: rollback ok " + bin + " head=" + ent.PrevHead)
	return 0
}
