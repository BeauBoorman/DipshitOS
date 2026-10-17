package main

import (
	"strings"

	"virelai/sshlib"
	"virelai/vi"
)

// execFn is the exec+wait seam; tests replace it. It spawns name with
// args and returns the child's exit status. STORE calls FLINT.ELF
// DIRECTLY — never through `GOSH.ELF -c ... > file`: outer-GOSH + STORE +
// inner-GOSH + FLINT is four Go runtimes at once, and four runtimes blow
// the kernel's 13-user-slot task pool (observed `newosproc: sys_thread
// create failed` when a 3-deep chain spawned a fourth). Direct exec is
// three runtimes at worst, and the child's `flint:` lines still reach the
// console for evidence — the named refusal prints, STORE just cannot
// re-read it, so a nonzero exit maps to sync_failed.
// execWaitNs bounds one child wait. The default Wait budget is 120 s —
// far longer than a foreground FLINT verb ever runs — and a spawned pid
// that the reclamation race loses ("wait failed" — the pid never enters
// the registry) would burn the entire budget into ErrWaitGone; two of
// those outrun a 180 s gate run before a refusal can print. Fifteen
// seconds is generous for the verbs store spawns.
const execWaitNs = int64(15) * int64(1e9)

var execFn = func(name string, args ...string) (int64, error) {
	pid, err := vi.Exec(name, args...)
	if err != nil {
		return -1, err
	}
	return vi.WaitBudget(pid, execWaitNs)
}

var sleepFn = vi.Sleep

// execPaceTicks is the yield before and after each nested socket-exec.
// Scheduler ticks are 1 Hz — values here are SECONDS, so keep them small.
// The kernel's file channel races the task reaper for several commands
// after a socket session — a `sleep 1` in run 14's script (a full
// second) still lost `FLINT.ELF commit` to `not found` — so STORE paces
// every transition in and out of a flint exec instead of trusting one
// gap. A second per side is cheap inside a 180 s run budget.
const execPaceTicks = 2

// flint runs one FLINT.ELF verb and reports success. The child's console
// output (including `flint: refuse <name>` on failure) flows to the
// serial log directly. A nonzero exit is sync_failed — the named refusal
// already printed. Any failure gets ONE retry after a re-arm: the
// task-slot/file-channel reclamation race can refuse the spawn itself
// right after a socket session (observed `gosh: FLINT.ELF: not found`),
// and a `newosproc` abort surfaces only as a nonzero status — both are
// transient and every verb used here is idempotent, so a real refusal
// just refuses twice.
// flintRetryTicks re-arms the task pool before a retry (seconds-scale —
// ticks are 1 Hz): a child that
// died inside its own runtime (`newosproc`) leaves slots the reaper
// reclaims on a timeslice, so the second attempt waits longer than the
// normal pace.
const flintRetryTicks = 3

// flintAttempts bounds retries. The post-socket task/file-channel
// reclamation race can lose an exec spawn OR its registry entry several
// seconds running (`gosh: wait failed` + silent child, observed twice
// on run 15); the window is longer than one pace, so the seam retries
// twice — every verb used here is idempotent and a real refusal just
// refuses again.
const flintAttempts = 3

func flint(args ...string) error {
	var status int64
	var err error
	for i := 0; i < flintAttempts; i++ {
		sleepFn(execPaceTicks)
		status, err = execFn("FLINT.ELF", args...)
		if err == nil && status == 0 {
			sleepFn(execPaceTicks)
			return nil
		}
		if i+1 < flintAttempts {
			sleepFn(flintRetryTicks)
		}
	}
	if err != nil {
		return refuse("sync_failed", "exec")
	}
	return refuse("sync_failed", "")
}

// resolveRemote picks the flintd address: --remote wins, then the
// REMOTE.json binding clone/pull/push left.
func resolveRemote(fs FS, root, remoteFlag string) (string, error) {
	if remoteFlag != "" {
		return remoteFlag, nil
	}
	rc, err := loadRemoteConfig(fs, root)
	if err != nil {
		return "", err
	}
	if rc != nil && rc.Remote != "" {
		return rc.Remote, nil
	}
	return "", refuse("remote_missing", "")
}

// syncStream ensures the named stream's local replica is current: clone
// when absent, pull when present. Either way every Change that lands has
// already passed the M101b keyring gate inside FLINT.ELF.
func syncStream(fs FS, remote, stream string, byName map[string]*Stream) error {
	if _, ok := byName[stream]; ok {
		return flint("pull", "--remote="+remote, "--stream="+stream)
	}
	return flint("clone", remote, stream)
}

// streamID resolves a stream selector (name preferred, then id) in the
// local index after a sync.
func streamID(byName, byID map[string]*Stream, sel string) (string, error) {
	if st, ok := byName[sel]; ok {
		return st.ID, nil
	}
	if st, ok := byID[sel]; ok {
		return st.ID, nil
	}
	return "", refuse("stream_missing", sel)
}

// headReleaseOps folds the signed release.go atom set from verified log
// bytes — at install/update these are the same bytes the --expect bind
// pinned, so nothing swapped after the gate ran can reach the fold —
// but only through the record head: a pull torn between its log append
// and its record roll leaves the log ahead of the record, and the
// un-committed tail must not materialize ahead of the head STORE
// records. A nil head folds nothing (nothing is committed); a head
// absent from the log is stream_malformed — record and log disagree.
// The second return is the head Change's author — the derived publisher
// fingerprint of ADR 0055 D5 ("" when the stream is headless).
func headReleaseOps(logBytes []byte, head *string) (map[atomKey]string, string, error) {
	changes, err := parseStreamChanges(logBytes)
	if err != nil {
		return nil, "", err
	}
	if head == nil {
		return foldReleaseOps(nil), "", nil
	}
	end := -1
	for i, c := range changes {
		if c.ID == *head {
			end = i
			break
		}
	}
	if end < 0 {
		return nil, "", refuse("stream_malformed", "head not in log")
	}
	return foldReleaseOps(changes[:end+1]), changes[end].Author, nil
}

// verifyStore runs the materialization gate inside FLINT.ELF: the
// publisher keyring + Ed25519 check (`verify --all --trusted`) over
// every stream log in the local replica — including anything a share
// writer appended after the pull — plus a hash bind on the one log
// STORE is about to fold. A nil logBytes (a headless replica) carries
// no bind: the fold yields no release atoms and release_missing refuses
// downstream.
func verifyStore(logID string, logBytes []byte) error {
	args := []string{"verify", "--all", "--trusted"}
	if logBytes != nil {
		sum := sshlib.SHA256Sum(logBytes)
		args = append(args, "--expect="+logID+":"+sshlib.EncodeHex(sum[:]))
	}
	return flint(args...)
}

// remoteStreamsFn is the wire-enumeration seam; tests substitute a fake.
// The pacing wrapper matters as much as the exec one: a just-closed
// guest socket returns its task/channel slots on the reaper's schedule,
// not Close()s — a fresh dial inside that window parks the caller with
// no error and no output (the run-15 silent stall, observed), so the
// seam sleeps around the whole session.
var remoteStreamsFn = func(remote string) ([]Stream, error) {
	sleepFn(execPaceTicks)
	streams, err := remoteStreams(remote)
	sleepFn(execPaceTicks)
	return streams, err
}

// syncIfMoved refreshes st's local replica when it is absent or behind
// the remote head; a current replica needs no pull at all — the wire
// `read` behind clone/pull cannot carry a release-sized Change anyway
// (the relay drop is documented on remoteStreams), so the catalog is
// expected to see replicas the share already materialized, exactly like
// install.
func syncIfMoved(fs FS, root, remote string, st Stream, byName map[string]*Stream) error {
	rec, found := byName[st.Name]
	localHead := (*string)(nil)
	if found {
		localHead = rec.Head
	}
	if !found || (st.Head != nil && (localHead == nil || *localHead != *st.Head)) {
		return syncStream(fs, remote, st.Name, byName)
	}
	return nil
}

// syncRemoteStreams refreshes every remote stream's local replica via
// syncIfMoved, tolerating per-stream refusals — an untrusted publisher's
// clone is refused inside FLINT.ELF and reports sync-failed rather than
// failing the enumeration. It returns the local records keyed by name.
func syncRemoteStreams(fs FS, root, remote string, streams []Stream) (map[string]*Stream, error) {
	for _, st := range streams {
		byName, _, err := listStreamRecords(fs, root)
		if err != nil {
			return nil, err
		}
		if err := syncIfMoved(fs, root, remote, st, byName); err != nil {
			consoleFn("store: stream " + st.Name + " sync-failed")
		}
	}
	byName, _, err := listStreamRecords(fs, root)
	return byName, err
}

// cmdLs implements `store ls [--remote=<r>] [--channel=<c>]
// [--search=<s>] [--category=<c>]`: enumerate the remote's streams over
// the wire, refresh the local replica when the remote head moved, and
// fold each stream's head into its ADR 0055 catalog entry — the release
// manifest consts read out of the signed atoms plus the derived
// publisher fingerprint. A current replica needs no pull at all — the
// wire `read` behind clone/pull cannot carry a release-sized Change
// anyway (the relay drop is documented on remoteStreams), so ls is
// expected to see replicas the share already materialized, exactly like
// install. A stream whose channel release.go is missing, tampered, or
// malformed is marked catalog-invalid with the refusal name rather than
// silently rendered.
func cmdLs(fs FS, root string, remoteFlag, channelArg, search, category string) int {
	consoleFn("store: ls")
	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	consoleFn("store: remote " + remote)
	ch, err := openChannel(fs, channelArg)
	if err != nil {
		return runErr(err)
	}
	streams, err := remoteStreamsFn(remote)
	if err != nil {
		return runErr(err)
	}
	kr, _ := loadKeyring(fs, root) // absent/corrupt -> publisher unverified
	byName, err := syncRemoteStreams(fs, root, remote, streams)
	if err != nil {
		return runErr(err)
	}
	entries := 0
	for _, st := range streams {
		rec, ok := byName[st.Name]
		if !ok {
			continue // sync-failed already reported
		}
		e, err := loadCatalogEntry(fs, root, ch, rec, kr)
		if err != nil {
			consoleFn("store: stream " + st.Name + " catalog-invalid " + refuseCodeOf(err))
			continue
		}
		if e == nil {
			consoleFn("store: stream " + st.Name + " no-release")
			continue
		}
		if !e.matches(search, category) {
			continue
		}
		entries++
		consoleFn("store: stream " + st.Name + " release " + e.line())
	}
	consoleFn("store: ls ok entries=" + vi.Itoa64(int64(entries)))
	return 0
}

// cmdInfo implements `store info <name> [--remote=<r>] [--channel=<c>]`:
// the single-stream detail view of the same catalog fold. The selector
// resolves a remote stream by name or id first, then by ReleaseName —
// `store info GOHELLO` and `store info rel` name the same card.
func cmdInfo(fs FS, root, sel, remoteFlag, channelArg string) int {
	consoleFn("store: info " + sel)
	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	consoleFn("store: remote " + remote)
	ch, err := openChannel(fs, channelArg)
	if err != nil {
		return runErr(err)
	}
	streams, err := remoteStreamsFn(remote)
	if err != nil {
		return runErr(err)
	}
	kr, _ := loadKeyring(fs, root)
	var target *Stream
	for i := range streams {
		if streams[i].Name == sel || streams[i].ID == sel {
			target = &streams[i]
			break
		}
	}
	byName, _, err := listStreamRecords(fs, root)
	if err != nil {
		return runErr(err)
	}
	var entry *catalogEntry
	if target != nil {
		// The named stream: sync just it — an enumeration-wide sync would
		// re-pay every per-stream refusal for one card.
		if err := syncIfMoved(fs, root, remote, *target, byName); err != nil {
			return runErr(refuse("sync_failed", target.Name))
		}
		byName, _, err = listStreamRecords(fs, root)
		if err != nil {
			return runErr(err)
		}
		rec, ok := byName[target.Name]
		if !ok {
			return runErr(refuse("stream_missing", target.Name))
		}
		entry, err = loadCatalogEntry(fs, root, ch, rec, kr)
		if err != nil {
			return runErr(err)
		}
	} else {
		// ReleaseName fallback (`store info GOHELLO`): scan each remote
		// stream's catalog entry for a name match, tolerating per-stream
		// refusals the same way ls does.
		want := strings.ToUpper(sel)
		for i := range streams {
			if serr := syncIfMoved(fs, root, remote, streams[i], byName); serr != nil {
				continue
			}
			byName, _, err = listStreamRecords(fs, root)
			if err != nil {
				return runErr(err)
			}
			rec, ok := byName[streams[i].Name]
			if !ok {
				continue
			}
			e, cerr := loadCatalogEntry(fs, root, ch, rec, kr)
			if cerr != nil || e == nil {
				continue
			}
			if e.Rel.Name == want {
				entry = e
				target = &streams[i]
				break
			}
		}
	}
	if target == nil {
		return runErr(refuse("stream_missing", sel))
	}
	if entry == nil {
		return runErr(refuse("release_missing", target.Name))
	}
	consoleFn("store: stream " + entry.Stream)
	consoleFn("store: name " + entry.Rel.Name)
	consoleFn("store: version " + entry.Rel.Version)
	consoleFn("store: category " + orDash(entry.Rel.Category))
	consoleFn("store: summary " + orDash(entry.Rel.Summary))
	consoleFn("store: sha256 " + entry.Rel.ELFSHA256)
	consoleFn("store: icon_sha256 " + orDash(entry.Rel.IconSHA256))
	consoleFn("store: publisher " + entry.Publisher +
		" publisher_name=" + orDash(entry.PubLabel) +
		" publisher_state=" + entry.PubState)
	consoleFn("store: head " + entry.Head)
	installed := "no"
	if lines, lerr := loadManifest(fs); lerr != nil {
		return runErr(lerr)
	} else if manifestHasBin(lines, entry.Rel.Name+".ELF") {
		installed = "yes"
	}
	consoleFn("store: installed " + installed)
	consoleFn("store: row " + entry.Rel.ManifestRow)
	if entry.Rel.Description == "" {
		consoleFn("store: description -")
	} else {
		consoleFn("store: description")
		for _, line := range strings.Split(entry.Rel.Description, "\n") {
			consoleFn("store:   " + line)
		}
	}
	consoleFn("store: info ok")
	return 0
}

// cmdInstall implements `store install <stream> [--remote=<r>]
// [--channel=<c>]` — the full verify-then-install pipeline.
func cmdInstall(fs FS, root, stream, remoteFlag, channelArg string) int {
	consoleFn("store: install " + stream)
	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	consoleFn("store: remote " + remote)
	ch, err := openChannel(fs, channelArg)
	if err != nil {
		return runErr(err)
	}

	// 1. Sync + verify: `pull` inside the FLINT.ELF child does its own
	// remote heads-check (`pull up to date` costs one `heads` round —
	// the wire session lives INSIDE the child, whose socket+exec coexist
	// under its own task slots; a store-side session raced the kernel's
	// reclamation for ~2 min observed). Then the local keyring + Ed25519
	// gate over the replica.
	byName, _, err := listStreamRecords(fs, root)
	if err != nil {
		return runErr(err)
	}
	if err := syncStream(fs, remote, stream, byName); err != nil {
		return runErr(err)
	}
	byName, byID, err := listStreamRecords(fs, root)
	if err != nil {
		return runErr(err)
	}
	id, err := streamID(byName, byID, stream)
	if err != nil {
		return runErr(err)
	}
	st := byID[id]
	// M101b's gate, local edition: `verify --all --trusted` runs the
	// publisher keyring + Ed25519 check over the whole replica — a share
	// writer's appended Change is refused key_unknown/key_revoked, not
	// folded — and --expect binds the exact log bytes STORE folds, so a
	// write landing between this read and the child's trips log_changed
	// rather than sneaking unverified ops through. `verify --remote`
	// would re-fetch the same Changes off the wire — and a release-sized
	// Change is exactly what the relay cannot carry back (remoteStreams
	// documents the ~1460 B fill boundary), so the remote read stalls
	// where the local fold does not.
	consoleFn("store: verify " + stream)
	logBytes, err := streamLogBytes(fs, root, id)
	if err != nil {
		return runErr(err)
	}
	if err := verifyStore(id, logBytes); err != nil {
		return runErr(err)
	}
	consoleFn("store: verified " + stream)

	// 2. Signed release manifest atoms at head — folded from the bound
	// bytes, up to the record head.
	signed, _, err := headReleaseOps(logBytes, st.Head)
	if err != nil {
		return runErr(err)
	}
	if len(signed) == 0 {
		return runErr(refuse("release_missing", stream))
	}

	// 3. Fetch + verify release.go over the untrusted channel.
	src, err := ch.fetch(stream+"/"+releaseFile, MaxReleaseBytes)
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
	bin := rel.Name + ".ELF"

	// 4. Fetch + hash the ELF.
	elf, err := ch.fetch(stream+"/"+bin, MaxELFBytes)
	if err != nil {
		return runErr(err)
	}
	sum := sshlib.SHA256Sum(elf)
	if sshlib.EncodeHex(sum[:]) != rel.ELFSHA256 {
		return runErr(refuse("elf_mismatch", bin))
	}

	// 5. Install checks against current state.
	lines, err := loadManifest(fs)
	if err != nil {
		return runErr(err)
	}
	if manifestHasBin(lines, bin) {
		// Idempotent re-install: the signed manifest covers the same ELF,
		// and a gate/shell retry after a raced exec must not read as a
		// refusal. Verify the on-disk bytes still match the signed hash —
		// a tampered install is not skipped silently.
		have, rerr := fs.ReadFile("/host/"+bin, MaxELFBytes)
		haveSum := sshlib.SHA256Sum(have)
		if rerr != nil || sshlib.EncodeHex(haveSum[:]) != rel.ELFSHA256 {
			return runErr(refuse("already_installed", bin))
		}
		// Converge to a tracked install: a crash between the APPS.TXT
		// write and the state write left a live app STORE.TXT does not
		// know (update/rollback then refuse not_installed), so the
		// already-installed path reconciles the row to the signed one
		// and writes the state entry.
		if cur, _ := manifestRowFor(lines, bin); cur != rel.ManifestRow {
			manifest, merr := manifestWithBinRow(lines, bin, rel.ManifestRow)
			if merr != nil {
				return runErr(merr)
			}
			if err := fs.WriteFileSafe(appsPath, manifest); err != nil {
				return runErr(err)
			}
		}
		if st.Head != nil {
			if err := writeStateEntry(fs, &storeEntry{
				Name: bin, Stream: st.Name, Head: *st.Head, SHA256: rel.ELFSHA256,
			}); err != nil {
				return runErr(err)
			}
		}
		consoleFn("store: already installed " + bin + " version=" + rel.Version)
		return 0
	}
	elfPath := "/host/" + bin
	elfOrphan := false
	if fs.Exists(elfPath) {
		// An orphan ELF — a manifest-row write that never landed, or a
		// manual drop — must not block the name forever: adopt it when
		// its bytes are exactly what the signed release pins (writing
		// them again is a no-op), and keep refusing elf_exists on
		// anything else, which is a file STORE cannot account for.
		have, rerr := fs.ReadFile(elfPath, MaxELFBytes)
		sum := sshlib.SHA256Sum(have)
		if rerr != nil || sshlib.EncodeHex(sum[:]) != rel.ELFSHA256 {
			return runErr(refuse("elf_exists", bin))
		}
		elfOrphan = true
	}
	manifest, err := manifestWithRow(lines, rel.ManifestRow)
	if err != nil {
		return runErr(err)
	}

	// 6. Publish: ELF first (orphan = harmless), then the row, then the
	// STORE.TXT entry — a failed later write reverts the earlier ones so
	// no partial state survives. The entry records the resolved stream
	// NAME (not the selector: `update` pulls it by name) and head id;
	// prev_* stay empty until the first update retains a rollback target.
	if !elfOrphan {
		if err := fs.WriteFileSafe(elfPath, elf); err != nil {
			return runErr(err)
		}
	}
	if err := fs.WriteFileSafe(appsPath, manifest); err != nil {
		if !elfOrphan {
			_ = fs.Remove(elfPath)
		}
		return runErr(err)
	}
	// st.Head is non-nil in practice — a headless stream has no changes,
	// so release_missing refused earlier — but never write a state line
	// the parser would refuse back (an empty head self-corrupts
	// STORE.TXT): an untracked install beats a malformed state file.
	if st.Head != nil {
		if err := writeStateEntry(fs, &storeEntry{
			Name: bin, Stream: st.Name, Head: *st.Head, SHA256: rel.ELFSHA256,
		}); err != nil {
			_ = fs.WriteFileSafe(appsPath, renderManifest(lines))
			if !elfOrphan {
				_ = fs.Remove(elfPath)
			}
			return runErr(err)
		}
	}
	consoleFn("store: install ok " + bin + " version=" + rel.Version)
	return 0
}

// cmdRemove implements `store remove <name>` — the symmetric case: the
// manifest row goes first (a crash leaves an orphan file, never a
// dangling row), then the ELF.
func cmdRemove(fs FS, arg string) int {
	consoleFn("store: remove " + arg)
	bin, ok := normalizeBin(arg)
	if !ok {
		return runErr(refuse("name_invalid", arg))
	}
	// The state row goes first: a torn remove leaves an untracked-but-
	// present app rather than a phantom STORE.TXT entry pointing at an
	// ELF that is gone.
	state, err := loadState(fs)
	if err != nil {
		return runErr(err)
	}
	if _, ok := state[bin]; ok {
		delete(state, bin)
		if err := fs.WriteFileSafe(statePath, renderState(state)); err != nil {
			return runErr(err)
		}
	}
	lines, err := loadManifest(fs)
	if err != nil {
		return runErr(err)
	}
	kept, found := manifestWithoutBin(lines, bin)
	elfPath := "/host/" + bin
	// An ELF (or retained bytes) present without a manifest row is the
	// orphan a torn install left — the name is only BLOCKED, not
	// tracked, so remove cleans it up rather than refusing
	// not_installed until someone deletes the file by hand.
	orphan := fs.Exists(elfPath) || fs.Exists(prevPath(bin)) || fs.Exists(prevStagePath(bin))
	if !found && !orphan {
		return runErr(refuse("not_installed", bin))
	}
	if found {
		if err := fs.WriteFileSafe(appsPath, renderManifest(kept)); err != nil {
			return runErr(err)
		}
	}
	if fs.Exists(elfPath) {
		if err := fs.Remove(elfPath); err != nil {
			return runErr(err)
		}
	}
	if fs.Exists(prevPath(bin)) {
		if err := fs.Remove(prevPath(bin)); err != nil {
			return runErr(err)
		}
	}
	if fs.Exists(prevStagePath(bin)) {
		if err := fs.Remove(prevStagePath(bin)); err != nil {
			return runErr(err)
		}
	}
	consoleFn("store: remove ok " + bin)
	return 0
}

// writeStateEntry upserts e in STORE.TXT through WriteFileSafe. The
// load-write pair is one WriteFileSafe — the atomic point is the file
// itself, so a crash can only lose the newest entry, never tear a line.
func writeStateEntry(fs FS, e *storeEntry) error {
	state, err := loadState(fs)
	if err != nil {
		return err
	}
	state[e.Name] = e
	return fs.WriteFileSafe(statePath, renderState(state))
}
