package store

import (
	"errors"
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
// The wait is TWO bounds, not one, because ErrWaitGone conflates two
// different children (#2522):
//
//   - execAppearNs bounds the spawn race: a pid the task-pool
//     reclamation loses never enters the registry ("wait failed"), and
//     WaitBudget polls it Absent until the deadline — the budget is the
//     only thing keeping two lost spawns from outrunning a 180 s gate
//     run before a refusal can print. A pid that never appears in 15 s
//     is not coming.
//   - execRunNs bounds a child CONFIRMED running in the registry — a
//     real wait on real work. It is derived from the protocol's payload
//     bound, not a wall-clock guess: every verb STORE spawns is
//     history-shaped. clone/pull fetch+verify the stream in
//     ceil(MaxChanges/flintReadPage) wire round-trips with one signature
//     check per Change; `verify --all --trusted` runs the same check
//     locally. execOverheadNs covers runtime spawn + dial + hello/auth
//     + open — the dominant term observed: the #2522 fresh-share clone
//     of a 4-Change stream lands `clone ok` ~21 s after exec on loaded
//     AND quiet hosts (multi-second relay round-trips), while the old
//     15 s bound killed it mid-flight and the orphan's slots starved
//     the retry into newosproc.
const execAppearNs = int64(15) * int64(1e9)

const (
	// flintReadPage mirrors flint's defaultReadLimit (remote.go): wire
	// reads page 256 Changes, so the protocol-bounded history fetch is
	// ceil(4096/256) = 16 round-trips.
	flintReadPage = 256
	// execOverheadNs is the fixed cost — Go runtime spawn, dial, and the
	// hello/auth/open round — at ~1.5x the observed ~21 s quiet-host
	// clone of a 4-Change stream.
	execOverheadNs = int64(30) * int64(1e9)
	// execPerPageNs bounds one `read` page round-trip through the
	// runner's relay (observed stalls run seconds per connection).
	execPerPageNs = int64(5) * int64(1e9)
	// execPerChangeNs bounds one Change's parse + keyring check +
	// Ed25519 verify on the guest.
	execPerChangeNs = int64(5) * int64(1e6)
	// execRunNs = 30 s + 16*5 s + 4096*5 ms = ~130 s: a ceiling, not a
	// prediction, and it stretches as a stream's history grows toward
	// MaxChanges rather than expiring mid-clone.
	execRunNs = execOverheadNs +
		int64((MaxChanges+flintReadPage-1)/flintReadPage)*execPerPageNs +
		int64(MaxChanges)*execPerChangeNs
)

// killDrainTicks bounds the probe drain after a timed-out child is
// killed. sys_kill only ARMS the exit — it fires at the child's next
// ring selection (1 Hz ticks) and the descriptor recycles on the
// reaper's schedule — so "the slot is coming back" is observed by
// polling, bounded, never blocking.
const killDrainTicks = 8

// The inner syscalls are their own seams (the agentd discipline): tests
// that replace execFn wholesale never reach them, but a test CAN
// exercise execFn itself — the kill-on-timeout path — by faking a spawn
// plus a budget expiry.
var (
	execSpawnFn  = vi.Exec
	waitBudgetFn = vi.WaitBudget
	killFn       = vi.Kill
	probeFn      = vi.Probe
)

var execFn = func(name string, args ...string) (int64, error) {
	pid, err := execSpawnFn(name, args...)
	if err != nil {
		return -1, err
	}
	status, err := waitBudgetFn(pid, execAppearNs)
	if err == nil {
		return status, nil
	}
	if errors.Is(err, vi.ErrWaitGone) {
		// Expiry with a live registry row is a slow child doing real
		// work, not the spawn race — concede only after the work-scaled
		// run budget. ProbeExited means the child left between
		// WaitBudget's last poll and now; Absent means the spawn was
		// lost (or a sub-tick vanish — the same kill+drain+retry path).
		st, state := probeFn(pid)
		switch state {
		case vi.ProbeExited:
			return st, nil
		case vi.ProbeRunning:
			status, err = waitBudgetFn(pid, execRunNs)
			if err == nil {
				return status, nil
			}
		}
	}
	// ErrWaitGone with a live child leaves an orphan holding task-pool
	// slots — observed on #2402's ~21 s FLINT clone: the timed-out verb
	// kept its slots and attempt 2's spawn starved into newosproc. Kill
	// the child and give the armed exit a few ticks to take before the
	// caller's retry re-spawns. The never-appeared case drains on the
	// first probe (Absent) and Kill just refuses EINVAL — same code.
	_ = killFn(uint64(pid))
	for i := 0; i < killDrainTicks; i++ {
		if _, state := probeFn(pid); state != vi.ProbeRunning {
			break
		}
		sleepFn(1)
	}
	return -1, err
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
const flintRetryTicks = 8

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
// clone is refused inside FLINT.ELF and lands in the failed set rather
// than failing the enumeration. It returns the local records keyed by
// name. The caller renders each failed stream (`ls`'s sync-failed line
// or a GOSTORE row) — the fold itself stays quiet so in-process callers
// get the data, not a second copy of the output.
func syncRemoteStreams(fs FS, root, remote string, streams []Stream, failed map[string]bool) (map[string]*Stream, error) {
	for _, st := range streams {
		byName, _, err := listStreamRecords(fs, root)
		if err != nil {
			return nil, err
		}
		if err := syncIfMoved(fs, root, remote, st, byName); err != nil {
			failed[st.Name] = true
		}
	}
	byName, _, err := listStreamRecords(fs, root)
	return byName, err
}

// CatalogRow is one remote stream's line in the M110c browse view: the
// ADR 0055 catalog verdict — a folded signed release, a stream carrying
// none, or the per-stream refusal the sync/fold leg reported. Rows keep
// the remote's enumeration order.
type CatalogRow struct {
	Stream string
	// Status is "release", "no-release", "sync-failed", or
	// "catalog-invalid"; Refusal carries the refusal code for the last.
	Status  string
	Refusal string
	// Entry is the authenticated catalog card (nil unless Status is
	// "release"). Installed is whether APPS.TXT already carries the
	// release's bin — display state, never a gate.
	Entry     *CatalogEntry
	Installed bool
}

// LoadCatalog runs the `store ls` fold and returns the per-stream rows —
// the model the GOSTORE browse view renders instead of re-paying the wire
// session STORE's printed lines describe. Read verbs get no LegFn legs:
// the signed-pipeline leg narration belongs to the mutating verbs.
func LoadCatalog(fs FS, root, remoteFlag, channelArg, search, category string) ([]CatalogRow, error) {
	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return nil, err
	}
	ch, err := openChannel(fs, channelArg)
	if err != nil {
		return nil, err
	}
	streams, err := remoteStreamsFn(remote)
	if err != nil {
		return nil, err
	}
	kr, _ := loadKeyring(fs, root) // absent/corrupt -> publisher unverified
	failed := map[string]bool{}
	byName, err := syncRemoteStreams(fs, root, remote, streams, failed)
	if err != nil {
		return nil, err
	}
	lines, lerr := loadManifest(fs)
	rows := make([]CatalogRow, 0, len(streams))
	for _, st := range streams {
		rec, ok := byName[st.Name]
		if failed[st.Name] || !ok {
			rows = append(rows, CatalogRow{Stream: st.Name, Status: "sync-failed"})
			continue
		}
		e, err := loadCatalogEntry(fs, root, ch, rec, kr)
		if err != nil {
			rows = append(rows, CatalogRow{Stream: st.Name, Status: "catalog-invalid", Refusal: refuseCodeOf(err)})
			continue
		}
		if e == nil {
			rows = append(rows, CatalogRow{Stream: st.Name, Status: "no-release"})
			continue
		}
		if !e.matches(search, category) {
			continue
		}
		row := CatalogRow{Stream: st.Name, Status: "release", Entry: e}
		if lerr == nil && manifestHasBin(lines, e.Rel.Name+".ELF") {
			row.Installed = true
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// Ls implements `store ls [--remote=<r>] [--channel=<c>]
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
func Ls(fs FS, root string, remoteFlag, channelArg, search, category string) int {
	ConsoleFn("store: ls")
	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	ConsoleFn("store: remote " + remote)
	rows, err := LoadCatalog(fs, root, remoteFlag, channelArg, search, category)
	if err != nil {
		return runErr(err)
	}
	entries := 0
	for _, r := range rows {
		if r.Status == "release" {
			entries++
			ConsoleFn("store: stream " + r.Stream + " release " + r.Entry.line())
			continue
		}
		line := "store: stream " + r.Stream + " " + r.Status
		if r.Refusal != "" {
			line += " " + r.Refusal
		}
		ConsoleFn(line)
	}
	ConsoleFn("store: ls ok entries=" + vi.Itoa64(int64(entries)))
	return 0
}

// Info implements `store info <name> [--remote=<r>] [--channel=<c>]`:
// the single-stream detail view of the same catalog fold. The selector
// resolves a remote stream by name or id first, then by ReleaseName —
// `store info GOHELLO` and `store info rel` name the same card.
func Info(fs FS, root, sel, remoteFlag, channelArg string) int {
	ConsoleFn("store: info " + sel)
	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	ConsoleFn("store: remote " + remote)
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
	var entry *CatalogEntry
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
	ConsoleFn("store: stream " + entry.Stream)
	ConsoleFn("store: name " + entry.Rel.Name)
	ConsoleFn("store: version " + entry.Rel.Version)
	ConsoleFn("store: category " + orDash(entry.Rel.Category))
	ConsoleFn("store: summary " + orDash(entry.Rel.Summary))
	ConsoleFn("store: sha256 " + entry.Rel.ELFSHA256)
	ConsoleFn("store: icon_sha256 " + orDash(entry.Rel.IconSHA256))
	ConsoleFn("store: publisher " + entry.Publisher +
		" publisher_name=" + orDash(entry.PubLabel) +
		" publisher_state=" + entry.PubState)
	ConsoleFn("store: head " + entry.Head)
	installed := "no"
	if lines, lerr := loadManifest(fs); lerr != nil {
		return runErr(lerr)
	} else if manifestHasBin(lines, entry.Rel.Name+".ELF") {
		installed = "yes"
	}
	ConsoleFn("store: installed " + installed)
	ConsoleFn("store: row " + entry.Rel.ManifestRow)
	if entry.Rel.Description == "" {
		ConsoleFn("store: description -")
	} else {
		ConsoleFn("store: description")
		for _, line := range strings.Split(entry.Rel.Description, "\n") {
			ConsoleFn("store:   " + line)
		}
	}
	ConsoleFn("store: info ok")
	return 0
}

// Install implements `store install <stream> [--remote=<r>]
// [--channel=<c>]` — the full verify-then-install pipeline.
func Install(fs FS, root, stream, remoteFlag, channelArg string) int {
	return install(fs, root, stream, remoteFlag, channelArg, nil)
}

// install is the pipeline body; chain carries the ReleaseNames already
// being resolved above this call (ADR 0055 D8) — an install reached as
// another release's dependency runs the identical legs with the
// ancestor names on the chain so a declared cycle refuses instead of
// recursing forever.
func install(fs FS, root, stream, remoteFlag, channelArg string, chain []string) int {
	ConsoleFn("store: install " + stream)
	remote, err := resolveRemote(fs, root, remoteFlag)
	if err != nil {
		return runErr(err)
	}
	ConsoleFn("store: remote " + remote)
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
	emitLeg("sync")
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
	emitLeg("verify")
	ConsoleFn("store: verify " + stream)
	logBytes, err := streamLogBytes(fs, root, id)
	if err != nil {
		return runErr(err)
	}
	if err := verifyStore(id, logBytes); err != nil {
		return runErr(err)
	}
	ConsoleFn("store: verified " + stream)

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
	emitLeg("fetch")
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

	// The signed dep rows resolve BEFORE this release's own fetch —
	// a release lands after what it needs, and a missing dep refuses
	// the parent by name without touching a byte of state.
	emitLeg("deps")
	if err := resolveDeps(fs, root, rel, remoteFlag, channelArg,
		append(append([]string{}, chain...), rel.Name)); err != nil {
		return runErr(err)
	}

	// 4. Fetch + hash the ELF.
	elf, err := ch.fetch(stream+"/"+bin, MaxELFBytes)
	if err != nil {
		return runErr(err)
	}
	emitLeg("sha")
	sum := sshlib.SHA256Sum(elf)
	if sshlib.EncodeHex(sum[:]) != rel.ELFSHA256 {
		return runErr(refuse("elf_mismatch", bin))
	}

	// 5. Install checks + publish — the tail materializeRelease shares
	// with pin's untracked-stream path.
	lines, err := loadManifest(fs)
	if err != nil {
		return runErr(err)
	}
	emitLeg("publish")
	headID := ""
	if st.Head != nil {
		headID = *st.Head
	}
	done, err := materializeRelease(fs, rel, elf, bin, st.Name, headID, lines)
	if err != nil {
		return runErr(err)
	}
	if done {
		return 0
	}
	ConsoleFn("store: install ok " + bin + " version=" + rel.Version)
	grantSync(bin, rel.ELFSHA256, rel.Caps)
	return 0
}

// materializeRelease publishes a verified release: ELF first (orphan =
// harmless), then the row, then the STORE.TXT entry — a failed later
// write reverts the earlier ones so no partial state survives. headID is
// the stream head the entry records ("" skips the state write — never
// write a line the parser would refuse back: an empty head self-corrupts
// STORE.TXT, and an untracked install beats a malformed state file).
// done=true means the idempotent already-installed path ran (it prints
// its own line and grant-syncs); the caller prints the ok line.
func materializeRelease(fs FS, rel *release, elf []byte, bin, streamName, headID string, lines []string) (bool, error) {
	if manifestHasBin(lines, bin) {
		// Idempotent re-install: the signed manifest covers the same ELF,
		// and a gate/shell retry after a raced exec must not read as a
		// refusal. Verify the on-disk bytes still match the signed hash —
		// a tampered install is not skipped silently.
		have, rerr := fs.ReadFile("/host/"+bin, MaxELFBytes)
		haveSum := sshlib.SHA256Sum(have)
		if rerr != nil || sshlib.EncodeHex(haveSum[:]) != rel.ELFSHA256 {
			return false, refuse("already_installed", bin)
		}
		// Converge to a tracked install: a crash between the APPS.TXT
		// write and the state write left a live app STORE.TXT does not
		// know (update/rollback then refuse not_installed), so the
		// already-installed path reconciles the row to the signed one
		// and writes the state entry.
		if cur, _ := manifestRowFor(lines, bin); cur != rel.ManifestRow {
			manifest, merr := manifestWithBinRow(lines, bin, rel.ManifestRow)
			if merr != nil {
				return false, merr
			}
			if err := fs.WriteFileSafe(appsPath, manifest); err != nil {
				return false, err
			}
		}
		if headID != "" {
			if err := writeStateEntry(fs, &storeEntry{
				Name: bin, Stream: streamName, Head: headID, SHA256: rel.ELFSHA256,
				Caps: strings.Join(rel.Caps, ","),
			}); err != nil {
				return false, err
			}
		}
		ConsoleFn("store: already installed " + bin + " version=" + rel.Version)
		grantSync(bin, rel.ELFSHA256, rel.Caps)
		return true, nil
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
			return false, refuse("elf_exists", bin)
		}
		elfOrphan = true
	}
	manifest, err := manifestWithRow(lines, rel.ManifestRow)
	if err != nil {
		return false, err
	}

	// Publish: ELF first (orphan = harmless), then the row, then the
	// STORE.TXT entry — a failed later write reverts the earlier ones so
	// no partial state survives. The entry records the resolved stream
	// NAME (not the selector: `update` pulls it by name) and head id;
	// prev_* stay empty until the first update retains a rollback target.
	if !elfOrphan {
		if err := fs.WriteFileSafe(elfPath, elf); err != nil {
			return false, err
		}
	}
	if err := fs.WriteFileSafe(appsPath, manifest); err != nil {
		if !elfOrphan {
			_ = fs.Remove(elfPath)
		}
		return false, err
	}
	if headID != "" {
		if err := writeStateEntry(fs, &storeEntry{
			Name: bin, Stream: streamName, Head: headID, SHA256: rel.ELFSHA256,
			Caps: strings.Join(rel.Caps, ","),
		}); err != nil {
			_ = fs.WriteFileSafe(appsPath, renderManifest(lines))
			if !elfOrphan {
				_ = fs.Remove(elfPath)
			}
			return false, err
		}
	}
	return false, nil
}

// maxDepChain bounds the ancestor chain a dep resolution may descend —
// the same bound the manifest grammar puts on one release's dep list.
// A deeper nest is a packaging bug (or a cycle the name check would
// catch one level later); dep_depth names it.
const maxDepChain = 8

// resolveDeps runs ADR 0055 D8 resolution for a verified release's
// declared ReleaseDepends, in declared order: a dep already carrying an
// APPS.TXT row is satisfied in place; otherwise the remote's signed
// catalog fold finds the stream whose head release names it and that
// stream installs first — recursively, with this release's name on the
// chain. chain already includes rel.Name, so a dep naming an in-flight
// ancestor is dep_cycle, a dep no remote stream's head release carries
// is dep_missing, and a dep install that refuses propagates as
// dep_failed naming the leg that could not land.
func resolveDeps(fs FS, root string, rel *release, remoteFlag, channelArg string, chain []string) error {
	if len(rel.Depends) == 0 {
		return nil
	}
	if len(chain) > maxDepChain {
		return refuse("dep_depth", rel.Name)
	}
	lines, err := loadManifest(fs)
	if err != nil {
		return err
	}
	var rows []CatalogRow
	scanned := false
	for _, dep := range rel.Depends {
		for _, c := range chain {
			if c == dep {
				return refuse("dep_cycle", dep)
			}
		}
		bin := dep + ".ELF"
		if manifestHasBin(lines, bin) {
			ConsoleFn("store: dep " + dep + " present")
			continue
		}
		if !scanned {
			// One catalog fold per resolution pass — the dep lookup is
			// the same signed enumeration ls runs; per-stream refusals
			// inside it are tolerated, a stream that cannot fold simply
			// is not a candidate.
			rows, err = LoadCatalog(fs, root, remoteFlag, channelArg, "", "")
			if err != nil {
				return err
			}
			scanned = true
		}
		stream := ""
		for i := range rows {
			if r := &rows[i]; r.Status == "release" && r.Entry != nil &&
				r.Entry.Rel != nil && r.Entry.Rel.Name == dep {
				stream = r.Stream
				break
			}
		}
		if stream == "" {
			return refuse("dep_missing", dep)
		}
		ConsoleFn("store: dep " + dep + " -> " + stream)
		if rc := install(fs, root, stream, remoteFlag, channelArg, chain); rc != 0 {
			return refuse("dep_failed", dep)
		}
		// The dep's row landed — later deps read the manifest fresh.
		if lines, err = loadManifest(fs); err != nil {
			return err
		}
	}
	return nil
}

// Remove implements `store remove <name>` — the symmetric case: the
// manifest row goes first (a crash leaves an orphan file, never a
// dangling row), then the ELF.
func Remove(fs FS, arg string) int {
	ConsoleFn("store: remove " + arg)
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
	emitLeg("publish")
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
	ConsoleFn("store: remove ok " + bin)
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
