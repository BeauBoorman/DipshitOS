// Command gosnap — M115e (issue #2464, ADR 0056): the named-snapshot
// manager for the running machine.
//
// A named snapshot is the machine state the ctl `snapshot <name>` verb
// parks on the armed share as `SNAPSHOTS/<name>.vzsave` (pause →
// saveMachineStateTo → reply → resume — the guest keeps running). The
// share location is the point of the design: the guest can list and
// delete its own snapshots with plain /host file ops, and the consent
// surface stays in the guest where the person is.
//
// Verbs — or, invoked bare, the M120d windowed face (view.go): the same
// list in a tab window with Save/Restore/Delete controls and the same
// two-step consent, now a click-twice arm instead of a typed `confirm`.
//
//	gosnap                           — the Snapshots window
//	gosnap ls                        — the stored snapshots, name + bytes
//	gosnap save <name>             — ctl `snapshot <name>` (idempotent by
//	                                 refusal: an existing name answers
//	                                 `exists`; `rm` is the replace path)
//	gosnap restore <name>          — consent ask; nothing is staged
//	gosnap restore <name> confirm  — ctl `restore <name>`: the host copies
//	                                 the named file over the profile's
//	                                 saved-state/state.vzsave, so the next
//	                                 `--resume` boots the snapshot. The
//	                                 running machine is untouched — the
//	                                 rewind lands on the next boot. A
//	                                 later `suspend` supersedes the stage.
//	gosnap rm <name>               — consent ask; nothing is deleted
//	gosnap rm <name> confirm       — delete the named snapshot file
//
// # Consent
//
// `restore` and `rm` are the destructive verbs — one replaces the
// machine's state on the next resume, the other destroys a snapshot —
// so both go through a seat gesture, never silently: without the
// trailing `confirm` token the app prints the ask (`gosnap: consent
// <verb> <name>`), refuses `consent_required`, and writes nothing. The
// gesture is the typed second issuance — the console-app analogue of
// GOSTORE's [g]rant modal (M116c) and the same "the person names the
// thing twice" shape a confirm prompt has.
//
// # Markers
//
// Every verdict is one `gosnap:` serial line AFTER the call that made it
// true (the M57a discipline): a refusal is a named code — the ADR 0056
// D4 vocabulary for the ctl verbs (`unimplemented`, `exists`,
// `not_found`, `no_state`, `unsupported`, `no_device`, `no_credential`,
// `busy`, ...), a kernel errno name for the file ops, or the local
// `name_rejected`/`consent_required`.
package main

import (
	"virelai/snapshot"
	"virelai/vi"
)

const (
	// snapsCanon is the canonical listing path (vi.ListDirAt roots it at
	// /host itself); snapsDir is the file-ops path of the same directory.
	snapsCanon = "/SNAPSHOTS"
	snapsDir   = "/host/SNAPSHOTS"
	// snapSuffix is the one name shape the host's snapshot driver writes;
	// `ls` shows only these.
	snapSuffix = ".vzsave"
	// nameMax is the ctl wire's NAME bound (ADR 0056 D3: 1–31 bytes) —
	// one byte tighter than the codec's MaxNameLen, so the check the app
	// does locally is exactly the one the wire applies.
	nameMax = 31

	// confirmToken is the consent gesture's literal trailing argument.
	confirmToken = "confirm"

	exitOK       = 0
	exitRefused  = 1
	exitUsage    = 2
	markerPrefix = "gosnap: "
)

// The seams — vars for the reason every other caller in the tree makes
// them vars: vi.* calls degrade to -ENOSYS off the guest, so host tests
// drive run() against fakes and the guest path is unchanged.
var (
	ctl        = vi.VsockCtl
	listDir    = vi.ListDirAt
	fileExists = vi.FileExists
	fileDelete = vi.FileDelete
	logLine    = vi.ConsoleLine
	exitFn     = vi.Exit
)

// nameOK is the wire's NAME grammar applied locally — a bad name is a
// named refusal here, before any verb leaves for the host, and `rm`
// (which never reaches the wire) joins a path only after the same gate.
func nameOK(name string) bool {
	return len(name) <= nameMax && snapshot.ValidName(name)
}

// snapPath maps a snapshot name onto its share path — only ever called
// with a name that passed nameOK, so the path cannot leave snapsDir.
func snapPath(name string) string { return snapsDir + "/" + name + snapSuffix }

// ctlVerdict runs one ctl session and returns the verdict word the
// caller prints: "" on ok, the refusal code otherwise (the reply's D4
// name, or the kernel errno name when the seam itself failed).
func ctlVerdict(verb, name string) (ok bool, code string) {
	var buf [40]byte
	r := ctl(verb, name, buf[:])
	if r == 0 {
		return true, ""
	}
	if r > 0 {
		if r > int64(len(buf)) {
			r = int64(len(buf))
		}
		return false, string(buf[:r])
	}
	return false, vi.ErrnoName(r)
}

// snapRow is one stored snapshot: the name minus its .vzsave suffix and
// the file's byte count.
type snapRow struct {
	name  string
	bytes uint64
}

// snapRows is the listing both faces share — cmdLS prints it, the M120d
// window paints it. One row per `<name>.vzsave`, sorted by name so the
// same share reports the same order twice (the host's readdir order is
// not a contract). The error is listDir's verbatim, ENOENT included.
func snapRows() ([]snapRow, error) {
	items, err := listDir(snapsCanon)
	if err != nil {
		return nil, err
	}
	var rows []snapRow
	for _, it := range items {
		if it.IsDir {
			continue
		}
		n := it.Name
		m := len(n)
		if m <= len(snapSuffix) || n[m-len(snapSuffix):] != snapSuffix {
			continue // not a snapshot file (a stray .part, a marker)
		}
		rows = append(rows, snapRow{name: n[:m-len(snapSuffix)], bytes: it.Size})
	}
	// Insertion sort — the listing is bounded (the dir protocol's own
	// bound), and the guest keeps no general sort in this app.
	for i := 1; i < len(rows); i++ {
		for j := i; j > 0 && rows[j-1].name > rows[j].name; j-- {
			rows[j-1], rows[j] = rows[j], rows[j-1]
		}
	}
	return rows, nil
}

// logSnapRows prints the listing's marker vocabulary — one `snap name=`
// line per row then the `ls n=` count — shared by the argv `ls` verb and
// the window's refresh so a gate reads one shape for both faces.
func logSnapRows(rows []snapRow) {
	for _, r := range rows {
		logLine(markerPrefix + "snap name=" + r.name + " bytes=" + vi.Itoa64(int64(r.bytes)))
	}
	logLine(markerPrefix + "ls n=" + vi.Itoa64(int64(len(rows))))
}

// cmdLS lists the stored snapshots. An absent SNAPSHOTS dir is an empty
// list — a share that has never snapshot honestly has none — not an
// error.
func cmdLS() int {
	rows, err := snapRows()
	if err != nil {
		if err.Error() == "ENOENT" {
			logLine(markerPrefix + "ls n=0")
			return exitOK
		}
		logLine(markerPrefix + "ls refused " + err.Error())
		return exitRefused
	}
	logSnapRows(rows)
	return exitOK
}

// cmdSave runs ctl `snapshot <name>`: the host pauses the machine, parks
// `<name>.vzsave` on the share, answers while the guest is still frozen,
// then resumes it — so `gosnap: save <name> ok` may print on the far
// side of a save/restore boundary.
func cmdSave(name string) int {
	if !nameOK(name) {
		logLine(markerPrefix + "save " + name + " refused name_rejected")
		return exitRefused
	}
	ok, code := ctlVerdict("snapshot", name)
	if !ok {
		logLine(markerPrefix + "save " + name + " refused " + code)
		return exitRefused
	}
	logLine(markerPrefix + "save " + name + " ok")
	return exitOK
}

// consentOK gates the destructive verbs. Without the trailing `confirm`
// the ask is printed and nothing is staged or deleted — the refusal is
// named so a gate can tell "the app asked" from "the app failed".
func consentOK(verb, name string, args []string) bool {
	if len(args) == 1 && args[0] == confirmToken {
		return true
	}
	logLine(markerPrefix + "consent " + verb + " " + name)
	logLine(markerPrefix + "to proceed: gosnap " + verb + " " + name + " " + confirmToken)
	logLine(markerPrefix + verb + " " + name + " refused consent_required")
	return false
}

// cmdRestore stages <name> as the next `--resume` target through the ctl
// `restore` verb: a host-side copy over the profile's saved-state file.
// Consent first — the stage means the next resume REPLACES guest state.
func cmdRestore(name string, rest []string) int {
	if !nameOK(name) {
		logLine(markerPrefix + "restore " + name + " refused name_rejected")
		return exitRefused
	}
	if len(rest) > 1 {
		return usage()
	}
	if !consentOK("restore", name, rest) {
		return exitRefused
	}
	ok, code := ctlVerdict("restore", name)
	if !ok {
		logLine(markerPrefix + "restore " + name + " refused " + code)
		return exitRefused
	}
	logLine(markerPrefix + "restore " + name + " staged")
	logLine(markerPrefix + "next --resume boots " + name + " — a suspend before then supersedes it")
	return exitOK
}

// cmdRm deletes the named snapshot file off the share — a guest file op,
// consent-gated like restore: the file is the whole snapshot.
func cmdRm(name string, rest []string) int {
	if !nameOK(name) {
		logLine(markerPrefix + "rm " + name + " refused name_rejected")
		return exitRefused
	}
	if len(rest) > 1 {
		return usage()
	}
	if !consentOK("rm", name, rest) {
		return exitRefused
	}
	path := snapPath(name)
	if !fileExists(path) {
		logLine(markerPrefix + "rm " + name + " refused not_found")
		return exitRefused
	}
	if rc := fileDelete(path); rc != 0 {
		logLine(markerPrefix + "rm " + name + " refused " + vi.ErrnoName(rc))
		return exitRefused
	}
	logLine(markerPrefix + "rm " + name + " ok")
	return exitOK
}

func usage() int {
	logLine("gosnap: snapshot manager — verbs:")
	logLine("  ls                          list stored snapshots")
	logLine("  save <name>                 snapshot the running machine onto the share")
	logLine("  restore <name> confirm      stage <name> as the next --resume")
	logLine("  rm <name> confirm           delete <name>")
	logLine("  (bare)                      the Snapshots window")
	return exitUsage
}

func run(args []string) int {
	// argv[0] is the image name; the verb is argv[1]. Bare is the windowed
	// face (M120d): a launcher's exec opens the tab window rather than
	// dying on this usage line.
	if len(args) < 2 {
		return runWindowed()
	}
	switch args[1] {
	case "ls":
		if len(args) != 2 {
			return usage()
		}
		return cmdLS()
	case "save":
		if len(args) != 3 {
			return usage()
		}
		return cmdSave(args[2])
	case "restore":
		if len(args) < 3 {
			return usage()
		}
		return cmdRestore(args[2], args[3:])
	case "rm":
		if len(args) < 3 {
			return usage()
		}
		return cmdRm(args[2], args[3:])
	}
	return usage()
}

func main() {
	exitFn(run(vi.Args()))
}
