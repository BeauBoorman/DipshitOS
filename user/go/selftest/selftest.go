// Command selftest is GOSELF.ELF (M61b/M61c, issues #1382/#1383): the first
// guest-owned pass/fail evidence in the fleet.
//
// The contract is ADR 0031 (docs/decisions/0031-guest-selftest.md):
//
//	/host/SELFTEST/REPORT.txt  `case <id> pass|fail <detail>` lines in list
//	                           order, then `summary cases=<n> failed=<k>`
//	/host/SELFTEST/OUT/        one small receipt per case (the proof the host
//	                           reads back on macOS)
//	serial                     `selftest: case <id> pass|fail`, then
//	                           `selftest: FAIL n=<k>` and `selftest OK` (k==0)
//
// Serial is the heartbeat; the files are the proof. The report is written and
// closed BEFORE any summary line is printed, so the host can never read a
// summary while the report is missing or stale, and every marker is printed
// only AFTER its syscall returned (the GOEDIT/GOCALC discipline). The report
// bytes are deterministic — no timestamps, no pointers — which is what makes a
// `share-equals` fixture legal in M61f.
//
// The cases drive a `syscalls` struct rather than calling `vi` directly, so
// the case logic is host-testable: `go test ./selftest` injects fakes and the
// guest build uses guestSyscalls.
package main

import (
	"bytes"
	"errors"
	"strconv"
	"strings"

	"virelai/mime"
	"virelai/snapshot"
	"virelai/vi"
)

// Host-share paths (ADR 0031 D2). IN/ belongs to the host (M61c seeds it);
// this app owns REPORT.txt and OUT/.
const (
	selftestDir = "/host/SELFTEST"
	outDir      = selftestDir + "/OUT"
	inDir       = selftestDir + "/IN"
	reportPath  = selftestDir + "/REPORT.txt"
	summaryPath = outDir + "/summary.txt"
	helloPath   = outDir + "/hello.txt"

	// M61c intake (issue #1383). The host seeds two fixtures; the cases prove
	// they were READ from the share, not carried in the binary, by copying the
	// bytes they read into OUT/ — where the spec byte-compares the copy
	// against the file it seeded on macOS.
	intakePath  = inDir + "/fixture.txt"
	alteredPath = inDir + "/altered.txt"

	intakeCopy     = outDir + "/fixture.copy"
	alteredCopy    = outDir + "/altered.copy"
	intakeReceipt  = outDir + "/intake.txt"
	alteredReceipt = outDir + "/intake-altered.txt"
)

// The intake fixture bodies. intakeFixture is seeded at IN/fixture.txt and is
// what the `intake` case requires the share to return; intakeAltered is seeded
// at IN/altered.txt — the same bytes with one character changed — and is what
// the `intake-altered` case requires the share to return INSTEAD (see
// fixtureCheck: a case that must NOT find the canonical bytes is what proves
// the comparison reads the share rather than a constant).
const (
	intakeFixture = "goself intake fixture v1\n"
	intakeAltered = "goself intake fixture v2\n"

	// M81g (#1767): the four bodies the snapshot case carries, seeded by the
	// host under IN/ and READ back by the guest — so the bundle is made of
	// bytes that came off the share. snapshotSessionBody is deliberately
	// BINARY (NULs, a newline, high bytes) and exactly 12 bytes long: the
	// real SESSION.TABS is a binary strip, and a container that could only
	// carry text could not carry the state this card is about. One
	// expression reconstructs each body on the host side too.
	snapshotSettingsBody = "#v2\ntheme=amber\nwm=gotabwm\n"
	snapshotSessionBody  = "\x54\x41\x42\x53\x00\x02\x00\x0a\xff\xfe\x10\x20"
	snapshotNoteBody     = "goself snapshot note\n"
	snapshotSecondBody   = "goself snapshot second document\n"
)

// helloPayload is the file-write case's known bytes: short, fixed, and
// compared on the host side (the go-selftest spec reads OUT/hello.txt on
// macOS and requires these exact bytes).
const helloPayload = "goself smoke\n"

// M61d file-ABI scratch (issue #1384). Every case owns its own paths under
// OUT/, so an earlier case's leftovers can never make a later one pass; every
// case leaves a receipt (OUT/file-<case>.ok) and — where there are bytes to
// compare — a copy of the bytes it READ (OUT/*.copy). The host byte-compares
// both, so nothing here passes by printing.
const (
	writeOk = outDir + "/file-write.ok"

	roundtripPath = outDir + "/roundtrip.txt"
	roundtripCopy = outDir + "/roundtrip.copy"
	roundtripOk   = outDir + "/file-roundtrip.ok"

	truncatePath  = outDir + "/truncate.txt"
	truncatedCopy = outDir + "/truncated.copy"
	truncateOk    = outDir + "/file-truncate.ok"

	deletePath = outDir + "/deleted.txt"
	deleteOk   = outDir + "/file-delete.ok"

	listDir    = outDir + "/LIST"
	listedPath = listDir + "/listed.txt"
	listOk     = outDir + "/file-list.ok"

	// M66a hardening pack (#1443). Same discipline: per-case paths, one
	// receipt each, and a .copy wherever bytes came back.
	appendPath = outDir + "/append.txt"
	appendCopy = outDir + "/append.copy"
	appendOk   = outDir + "/file-append.ok"

	bigwritePath = outDir + "/bigwrite.txt"
	bigwriteCopy = outDir + "/bigwrite.copy"
	bigwriteOk   = outDir + "/file-bigwrite.ok"

	clampPath = outDir + "/clamp.txt"
	clampCopy = outDir + "/clamp.copy"
	clampOk   = outDir + "/file-clamp.ok"

	fsyncPath = outDir + "/fsync.txt"
	fsyncOk   = outDir + "/file-fsync.ok"

	errMissing = outDir + "/errors-absent.txt"
	errDir     = outDir + "/ERR"
	errOk      = outDir + "/file-errors.ok"

	// M81e (#1765): the publish primitive. The temp is the one path allowed
	// to exist mid-publish; the case proves it does not SURVIVE one, and
	// that replacing a long body with a short one leaves no tail.
	writeSafePath = outDir + "/write-safe.txt"
	writeSafeTmp  = writeSafePath + "~"
	writeSafeCopy = outDir + "/write-safe.copy"
	writeSafeOk   = outDir + "/file-write-safe.ok"

	// M81a (#1761): trash, restore, recent and expiry.
	trashSourcePath  = outDir + "/trash-source.txt"
	trashCopyPath    = outDir + "/trash.copy"
	trashReceiptPath = outDir + "/trash.ok"
	expirySourcePath = outDir + "/expiry-source.txt"

	// M61e window receipt (issue #1385), in the card's shape: the id the
	// kernel assigned, the geometry the KERNEL reports for that window, and
	// the present verdict.
	windowReceipt = outDir + "/window.txt"

	// M100f (#2311, ADR 0050): the disk leg's paths. Everything the case
	// mutates lives under /disk/SELFTEST; the receipts stay on /host like
	// every other case — the host byte-compares them even though the bytes
	// under test never touch the share.
	diskDir  = "/disk/SELFTEST"
	diskPath = diskDir + "/DISK.TXT"
	diskOk   = outDir + "/file-disk.ok"
	diskCopy = outDir + "/disk.copy"

	// M81e2 (#1787): the publish seam the shell hook stands on. The file
	// is named for what it models — GOSH's history save — because that IS
	// the caller: the ring-replace save and the one-line append.
	publishPath = outDir + "/publish.txt"
	publishTmp  = publishPath + "~"
	publishCopy = outDir + "/publish.copy"
	publishOk   = outDir + "/file-write-publish.ok"

	// M81g (#1767): the snapshot bundle drill. The four INPUTS are host
	// fixtures under IN/ (the host owns that directory, ADR 0031 D2), so
	// every body in the bundle is bytes that came off the share rather than
	// a constant compiled into this binary — the same anti-embedding
	// property the intake cases exist for. The session fixture is BINARY:
	// the real SESSION.TABS is a binary strip, and a container that could
	// only carry text could not carry the state the card is about.
	snapshotInSettings = inDir + "/snapshot-settings.txt"
	snapshotInSession  = inDir + "/snapshot-session.tabs"
	snapshotInDocs     = inDir + "/snapshot-docs"
	snapshotInNote     = snapshotInDocs + "/NOTE.TXT"
	snapshotInSecond   = snapshotInDocs + "/SECOND.TXT"

	// What the case publishes, and what it rehydrates FROM. RESTORED/ is the
	// drill's own output: the bundle is parsed back and each entry published
	// again, so a host that byte-compares RESTORED/ against IN/ is looking at
	// a real round trip through the container, not at a copy.
	snapshotBundle     = outDir + "/snapshot.bundle"
	snapshotBundleTmp  = snapshotBundle + "~"
	snapshotBundleCopy = outDir + "/snapshot.copy"
	snapshotOk         = outDir + "/file-snapshot.ok"

	restoredDir       = outDir + "/RESTORED"
	restoredSettings  = restoredDir + "/settings.txt"
	restoredSession   = restoredDir + "/session.tabs"
	restoredDocsDir   = restoredDir + "/docs"
	restoredNote      = restoredDocsDir + "/NOTE.TXT"
	restoredSecond    = restoredDocsDir + "/SECOND.TXT"
	snapshotEntryDocs = 2
)

// fileUnit is the payload unit of the round-trip and truncate cases: the same
// 21-byte line, repeated. One expression reconstructs each body on the host
// (`b"goself file abi line\n" * n`), which is what makes the .copy files
// byte-comparable without a fixture file. The counts differ per case so the
// two copies are distinguishable: roundtrip 25 units in and out; truncate 40
// units in, 5 kept.
const (
	fileUnit       = "goself file abi line\n"
	roundtripUnits = 25
	truncateUnits  = 40
	truncateKeeps  = 5

	listMarkerBody = "goself list marker\n"
	deleteBody     = "goself delete me\n"

	// M66a (#1443): the hardening pack's bodies, same one-expression rule.
	// bigwrite is far beyond one sys_file_write call (the kernel's stage cap
	// is 2048 B per call — fileWriteMax), so its write only lands through the
	// confirmed-count chunk loop.
	appendBaseUnits = 3
	appendMoreUnits = 2
	bigwriteUnits   = 3500 // 73,500 B → 36 sys_file_write calls at the cap
	clampUnits      = 40
	clampKeptUnits  = 5
	clampExtraUnits = 3
	fsyncUnits      = 7
	diskUnits       = 21 // M100f: the disk leg's body, same one-expression rule

	// fileWriteMax mirrors the kernel's sys_file_write stage cap
	// (handle_file_write refuses count > 2048 with -ENOSPC).
	fileWriteMax = 2048

	// M81g (#1767): the bundle read caps. The container's own caps do the
	// bounding; these are the read windows the case uses, one byte past
	// each so an oversize file is DETECTED rather than silently truncated
	// into something that would still parse.
	snapshotReadSettings = 8 * 1024
	snapshotReadBody     = 64 * 1024
	snapshotReadBundle   = snapshot.MaxBundle + 1
)

const epochReceipt = outDir + "/clock-epoch.ok"

// M83b (#1775): the clock-set case. The kernel's accepted range is
// 2025-01-01..2100-01-01 UTC (timer.wall_epoch_min/max); the step is far
// enough to be unmistakable next to the 1 Hz tick and small enough to stay
// inside the range from any plausible boot clock.
const (
	clockSetReceipt = outDir + "/clock-set.ok"
	clockSetMin     = 1_735_689_600
	clockSetMax     = 4_102_444_800
	clockSetStep    = 100
	// clockSetSlack bounds how far a read may sit past the value just set:
	// the tick's phase plus the scheduling between two syscalls.
	clockSetSlack = 3
)

// roundtripPayload / truncatePayload / truncateKept are the byte bodies above
// as the cases write them, shrink to and read back.
func roundtripPayload() []byte { return []byte(strings.Repeat(fileUnit, roundtripUnits)) }
func truncatePayload() []byte  { return []byte(strings.Repeat(fileUnit, truncateUnits)) }
func truncateKept() []byte     { return []byte(strings.Repeat(fileUnit, truncateKeeps)) }

// The M66a bodies: base+more for the append case, the 73,500-byte big-write
// body, full/kept/extra for the clamp case, and the fsync case's body.
func appendBasePayload() []byte { return []byte(strings.Repeat(fileUnit, appendBaseUnits)) }
func appendMorePayload() []byte { return []byte(strings.Repeat(fileUnit, appendMoreUnits)) }
func bigwritePayload() []byte   { return []byte(strings.Repeat(fileUnit, bigwriteUnits)) }
func clampFull() []byte         { return []byte(strings.Repeat(fileUnit, clampUnits)) }
func clampKept() []byte         { return []byte(strings.Repeat(fileUnit, clampKeptUnits)) }
func clampExtra() []byte        { return []byte(strings.Repeat(fileUnit, clampExtraUnits)) }
func fsyncPayload() []byte      { return []byte(strings.Repeat(fileUnit, fsyncUnits)) }
func diskPayload() []byte       { return []byte(strings.Repeat(fileUnit, diskUnits)) }

// The M81e publish bodies: a long body replaced by a short one, so the case
// can prove the publish is whole-file. An in-place writer would leave the
// long body's tail behind — trimming that tail is exactly what the old
// FileTruncate(len) calls were doing by hand.
func writeSafeLong() []byte  { return []byte(strings.Repeat(fileUnit, 40)) }
func writeSafeShort() []byte { return []byte(strings.Repeat(fileUnit, 5)) }

// syscalls is the slice of the ADR 0010 file ABI (plus the clock) the cases
// use, as function fields so tests can fake every one of them. M61d added the
// mutating/enumeration rows (`truncate`, `remove`, `list`): the file-ABI pack
// is only as strong as the fake's model of them, so the fake checks the same
// invariants the kernel does (a truncate through a read-only handle, a delete
// of a missing path, a listing's direct children).
type syscalls struct {
	now      func() int64
	epoch    func() int64
	setEpoch func(epoch int64) int64 // M83b: slot 78, 0 or a negative errno
	sleep    func(ticks uint64)
	mkdir    func(path string) int64
	open     func(path string, flags uint32) (int64, int64)
	read     func(h uint32, buf []byte) (int, int64)
	write    func(h uint32, b []byte) (int, int64)
	truncate func(h uint32, size uint32) int64
	sync     func(h uint32) int64
	remove   func(path string) int64
	list     func(path string, buf []vi.DirEntry) (int, int64)
	close    func(h uint32)

	// M81e (#1765): the publish primitive — vi.WriteFileSafe's temp +
	// fsync + delete-then-rename, the one write path the app writers now
	// stand on. It is a function, not a composition of the rows above,
	// because the ORDER is the property under test.
	writeSafe func(path string, b []byte) int64

	// M81e2 (#1787): the two-contract policy seam. `publish` is
	// vi.WriteFilePublish — replace (appendMode false) takes the safe
	// publish, append (appendMode true) stays an in-place append. It is a
	// function row for the same reason writeSafe is: WHICH contract
	// applies is the property under test, and composing it from the rows
	// above would re-implement the very thing being pinned.
	publish func(path string, b []byte, appendMode bool) int64

	// M81d (#1764): the advisory write lease, as function rows like
	// writeSafe/publish — the case drives the helper end to end (acquire,
	// refuse, take over, release), and WHICH state the standing record is
	// in is the property under test.
	leaseAcquire func(path, selfName string) (*vi.FileLease, int64)
	leaseCheck   func(path string) int64
	leaseRelease func(l *vi.FileLease) int64

	// M81a (#1761): shared trash/recent operations.
	readAll      func(path string, max int) ([]byte, int64)
	trashDelete  func(path string) (string, int64)
	trashRead    func(id string) (path string, body []byte, timestamp int64, rc int64)
	trashRestore func() (path, id string, rc int64)
	trashExpire  func(now int64) (int, int64)
	logWrite     func(app, line string) int64
	logRead      func(app string) ([]byte, int64)
	crashReceipt func(app, outcome string) int64

	// M61e (#1385): the window surface. Separate from the file rows above
	// because id/reqW/reqH are STATE the shell copied out of tabapp.Init, not
	// syscall bindings — the three function rows are the ADR 0007 window rows
	// the case drives.
	win windowSeam
}

// windowSeam is the app's own tabapp window plus the window rows the window
// case drives. id is -1 until the shell binds it (main.go), so a case that
// runs without a window FAILS rather than querying window 0.
type windowSeam struct {
	id      int    // the id the kernel assigned; -1 when open failed
	reqW    uint32 // the geometry the app asked for at open
	reqH    uint32
	query   func(id int) ([8]uint32, int64)
	fill    func(id int, x, y, w, h uint32, rgb uint32) int64
	present func(id int) int64
}

// guestSyscalls is the real EL0 surface (vi over ADR 0007).
func guestSyscalls() syscalls {
	return syscalls{
		now:      vi.Nanos,
		epoch:    vi.Now,
		setEpoch: vi.TimeSet,
		sleep:    vi.Sleep,
		// MODE_DIR creates the directory, but the kernel's open validation
		// requires it together with MODE_WRITE|MODE_CREATE (file_table.open:
		// `(flags & (MODE_CREATE|MODE_WRITE)) != (MODE_CREATE|MODE_WRITE)` is
		// EINVAL) — the same triple user/go/git's mkdir uses. "already
		// exists" (-9 EEXIST) is not an error here — a pre-created
		// SELFTEST/OUT must not fail a run (ADR 0031 D2).
		mkdir: func(path string) int64 {
			h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
			if rc >= 0 {
				vi.FileClose(uint32(h))
			}
			return rc
		},
		open:      vi.FileOpen,
		read:      vi.FileRead,
		write:     vi.FileWrite,
		truncate:  vi.FileTruncate,
		sync:      vi.FileSync,
		remove:    vi.FileDelete,
		list:      vi.DirList,
		close:     vi.FileClose,
		writeSafe: vi.WriteFileSafe,
		// M81e2 (#1787): the two-contract policy seam — replace publishes
		// crash-safe, append stays an append.
		publish: vi.WriteFilePublish,
		readAll: vi.ReadFileAll,
		// M81d (#1764): the real lease helpers — the case proves them on
		// the live share, not against a re-implementation.
		leaseAcquire: vi.AcquireFileLease,
		leaseCheck:   vi.CheckFileLease,
		leaseRelease: func(l *vi.FileLease) int64 { return l.Release() },
		trashDelete:  vi.TrashDelete,
		trashRead:    vi.TrashRead,
		trashRestore: vi.TrashRestoreLatest,
		trashExpire:  vi.TrashExpire,
		logWrite:     vi.Log,
		logRead:      vi.ReadLog,
		crashReceipt: vi.WriteCrashReceipt,
		// M61e: the real window rows. id/reqW/reqH stay -1/0 here — the shell
		// binds them from tabapp.Init, so this function never claims a window
		// the app did not get.
		win: windowSeam{
			id:      -1,
			query:   vi.WinQuery,
			fill:    vi.WinFill,
			present: vi.WinPresent,
		},
	}
}

// result is one case verdict. id is the report key; detail is a one-line
// human reason, printed only when the case failed.
type result struct {
	id     string
	ok     bool
	detail string
}

// testCase is one built-in case. The ids are part of the report contract (ADR
// 0031): renaming one is a report-format change, not a refactor.
type testCase struct {
	id  string
	run func(s *syscalls) error
}

// cases is the built-in list, in report order. M61c/d/e append here.
// The two intake cases come first: they are the ones that read what the host
// seeded, and their verdicts are what makes the rest of the run meaningful.
func cases() []testCase {
	return []testCase{
		{id: intakeCase.id, run: intakeCase.run},
		{id: alteredCase.id, run: alteredCase.run},
		{id: "clock-monotonic", run: caseClockMonotonic},
		{id: "file-write", run: caseFileWrite},
		// M61d (#1384): the file-ABI pack on the host share, in ABI order —
		// create/write/close/reopen/read-back, shrink, delete, enumerate.
		{id: "file-roundtrip", run: caseFileRoundtrip},
		{id: "file-truncate", run: caseFileTruncate},
		{id: "file-delete", run: caseFileDelete},
		{id: "file-list", run: caseFileList},
		// M66a (#1443): the hardening pack — append-at-EOF, a write far
		// beyond one syscall, the truncate clamp, the durability verb, and
		// the honest error rows — inserted before the window case so the
		// M61d report prefix stays untouched.
		{id: "file-append", run: caseFileAppend},
		{id: "file-bigwrite", run: caseFileBigwrite},
		{id: "file-clamp", run: caseFileClamp},
		{id: "file-fsync", run: caseFileFsync},
		{id: "file-errors", run: caseFileErrors},
		// M81e (#1765): the publish primitive itself — replace a long body
		// with a short one, prove the read-back is exactly the short body
		// (no tail), and that the sacrificial temp did not survive. Inserted
		// before the window case so the M61d report prefix stays untouched.
		{id: "file-write-safe", run: caseFileWriteSafe},
		// M81a (#1761): the destructive path is reversible, records both
		// actions in RECENT, and expires an old item without touching a new one.
		{id: "trash", run: caseTrash},
		// M81e2 (#1787): the PUBLISH seam the shell hook now stands on —
		// both halves. The replace half is the history ring save and `>
		// file`; the append half is the history one-line append and `>>`.
		// Both are pinned here because this is the only place that drives
		// the primitive end to end on the share and hands the host bytes to
		// byte-compare.
		{id: "file-write-publish", run: caseFileWritePublish},
		// M81b (#1762): the MIME table itself, exercised through the file
		// ABI — every fixture is WRITTEN to the share and READ BACK before it
		// is sniffed, so the verdict is about the bytes that came back over
		// the share, not about a constant compiled into this binary. Also
		// inserted before the window case so the M61d report prefix stays
		// untouched.
		{id: "mime", run: caseMime},
		// M81g (#1767): the snapshot bundle DRILL, both halves on the share
		// — carry settings + a BINARY session strip + a documents selection
		// into one crash-safe bundle, read it back, parse it, and rehydrate
		// every entry byte-exact; then refuse a truncated one. Inserted
		// before the window case so the M61d report prefix stays untouched.
		{id: "file-snapshot", run: caseFileSnapshot},
		// M82e (#1772): app log rings and crash receipts. The host compares
		// both the retained ring tail and the GOSELF-style failure receipt.
		{id: "app-logs", run: caseAppLogs},
		// M81d (#1764): the advisory write lease drill — acquire, the
		// foreign refusal, the stale and dead-holder takeovers, the
		// release rules. Inserted before the window case so the M61d
		// report prefix stays untouched.
		{id: "file-lease", run: caseFileLease},
		// M61e (#1385): the window receipt.
		{id: "window", run: caseWindow},
		// M100f (#2311): the VLFS data-disk leg — write, fsync, readback on
		// /disk with the receipts on /host; mounted=no skip on the default
		// no-disk fleet. Before the clock cases so their wall-time reads
		// stay the tail.
		{id: "disk", run: caseDisk},
		// M83a (#1774): add the epoch receipt at the tail so existing
		// report rows keep their order and their host-test indexes.
		{id: "clock-epoch", run: caseClockEpoch},
		// M83b (#1775): the clock setter (slot 78). LAST, after every case
		// that stamps or expires by wall time, and after clock-epoch so that
		// receipt is the untouched boot value.
		{id: "clock-set", run: caseClockSet},
	}
}

const (
	// #2085: the label must bind to this process's own image name — the
	// kernel refuses foreign APPLOG/CRASH labels for uid_user actors.
	appLogFixture = "GOSELF.ELF"
	appLogCopy    = outDir + "/app-log.copy"
	appLogReceipt = "/host/CRASH/GOSELF.ELF.TXT"
)

// M81d (#1764): the lease drill's paths and the foreign holder's identity.
// The forgeries carry a token that is NOT this process's on purpose — the
// drills prove the rules a record a FOREIGN writer produced is honored by.
const (
	leaseDir    = "/host/SELFTEST/LEASE"
	leaseTarget = leaseDir + "/TARGET.TXT"
	leaseOther  = leaseDir + "/UNLEASED.TXT"
	leaseOk     = outDir + "/file-lease.ok"
	leaseCopy   = outDir + "/file-lease.copy"

	leaseForeignToken = "0123456789abcdef"
	leaseDeadPid      = uint32(424242)
)

// leaseRecord hand-renders one VLEASE1 record for the drills: the format is
// the on-share convention (vi/lease.go), so the case writes it directly the
// way a foreign writer would, instead of through the holder's own helpers.
// A negative stamp renders as 0 — the no-clock record the classify rules
// read as "pid liveness only".
func leaseRecord(pid uint32, ts int64, tokenHex, path string) []byte {
	if ts < 0 {
		ts = 0
	}
	var b strings.Builder
	b.WriteString("VLEASE1\n")
	b.WriteString("pid=" + strconv.FormatUint(uint64(pid), 10) + "\n")
	b.WriteString("ts=" + strconv.FormatInt(ts, 10) + "\n")
	b.WriteString("token=" + tokenHex + "\n")
	b.WriteString("path=" + path + "\n")
	return []byte(b.String())
}

func caseFileLease(s *syscalls) error {
	if rc := s.mkdir(leaseDir); rc < 0 && rc != -9 {
		return errors.New("mkdir rc=" + strconv.FormatInt(rc, 10))
	}
	if rc := s.writeSafe(leaseTarget, []byte("lease target body\n")); rc < 0 {
		return errors.New("seed rc=" + strconv.FormatInt(rc, 10))
	}
	if rc := s.writeSafe(leaseOther, []byte("unleased\n")); rc < 0 {
		return errors.New("seed other rc=" + strconv.FormatInt(rc, 10))
	}
	now := s.now()
	l1, rc := s.leaseAcquire(leaseTarget, appName)
	if rc < 0 || l1 == nil {
		return errors.New("acquire rc=" + strconv.FormatInt(rc, 10))
	}
	// A second writer under a live lease is refused with the convention's
	// one EAGAIN row, and the read-only check agrees.
	if _, rc := s.leaseAcquire(leaseTarget, "OTHER.ELF"); rc != -vi.ErrEAGAIN {
		return errors.New("foreign acquire rc=" + strconv.FormatInt(rc, 10) + " want -11")
	}
	if rc := s.leaseCheck(leaseTarget); rc != -vi.ErrEAGAIN {
		return errors.New("check rc=" + strconv.FormatInt(rc, 10) + " want -11")
	}
	if rc := s.leaseCheck(leaseOther); rc != 0 {
		return errors.New("free check rc=" + strconv.FormatInt(rc, 10) + " want 0")
	}
	// Stale takeover: a foreign record stamped past the expiry is taken
	// over at the next acquire. The stale .copy is the takeover's evidence
	// — the record as the foreign writer left it.
	staleStamp := now - vi.LeaseExpirySeconds - 5
	if rc := s.writeSafe(l1.LeasePath, leaseRecord(leaseDeadPid, staleStamp, leaseForeignToken, leaseTarget)); rc < 0 {
		return errors.New("forge stale rc=" + strconv.FormatInt(rc, 10))
	}
	l2, rc := s.leaseAcquire(leaseTarget, appName)
	if rc < 0 || l2 == nil || l2.LeasePath != l1.LeasePath {
		return errors.New("stale takeover rc=" + strconv.FormatInt(rc, 10))
	}
	if cerr := copyBytes(s, leaseCopy, leaseRecord(leaseDeadPid, staleStamp, leaseForeignToken, leaseTarget)); cerr != nil {
		return cerr
	}
	// Dead-holder recovery: a FRESH stamp whose pid is not running is the
	// crash shape, recovered immediately instead of at expiry. (In a
	// no-epoch boot both forgeries carry ts=0 and this rule is the only
	// takeover path — the same drill proves the rule either way.)
	if rc := s.writeSafe(l2.LeasePath, leaseRecord(leaseDeadPid, now, leaseForeignToken, leaseTarget)); rc < 0 {
		return errors.New("forge dead rc=" + strconv.FormatInt(rc, 10))
	}
	l3, rc := s.leaseAcquire(leaseTarget, appName)
	if rc < 0 || l3 == nil {
		return errors.New("dead-holder takeover rc=" + strconv.FormatInt(rc, 10))
	}
	// A live foreign record is never deleted by a release that does not
	// own it: the token, not the staleness rules, gate the delete.
	if rc := s.writeSafe(l3.LeasePath, leaseRecord(0, now, leaseForeignToken, leaseTarget)); rc < 0 {
		return errors.New("forge foreign rc=" + strconv.FormatInt(rc, 10))
	}
	if rc := s.leaseRelease(l3); rc != -vi.ErrEAGAIN {
		return errors.New("foreign release rc=" + strconv.FormatInt(rc, 10) + " want -11")
	}
	// With the record gone (the foreign holder released it) our own
	// release is a no-op, and the path reads free again.
	if rc := s.remove(l3.LeasePath); rc < 0 {
		return errors.New("clear rc=" + strconv.FormatInt(rc, 10))
	}
	if rc := s.leaseRelease(l3); rc != 0 {
		return errors.New("release rc=" + strconv.FormatInt(rc, 10) + " want 0")
	}
	if rc := s.leaseCheck(leaseTarget); rc != 0 {
		return errors.New("final check rc=" + strconv.FormatInt(rc, 10) + " want 0")
	}
	line := "case file-lease dir=LEASES clock=" + yesNo(now > 0) +
		" foreign-refused=-11 stale-takeover=ok dead-holder=ok foreign-release=-11 release=ok free=0"
	return writeReceipt(s, leaseOk, line)
}

func caseAppLogs(s *syscalls) error {
	s.mkdir(outDir)
	var want strings.Builder
	for i := 1; i <= vi.AppLogMaxLines+3; i++ {
		line := "line-" + twoDigits(i)
		if rc := s.logWrite(appLogFixture, line); rc < 0 {
			return errors.New("log write rc=" + strconv.FormatInt(rc, 10))
		}
		if i > 3 {
			want.WriteString(line + "\n")
		}
	}
	got, rc := s.logRead(appLogFixture)
	if rc < 0 || string(got) != want.String() {
		return errors.New("ring tail mismatch rc=" + strconv.FormatInt(rc, 10))
	}
	if _, err := writeFile(s, appLogCopy, got); err != nil {
		return err
	}
	outcome := "panic: fixture failure"
	if rc := writePanicReceipt(s, appLogFixture); rc < 0 {
		return errors.New("receipt write rc=" + strconv.FormatInt(rc, 10))
	}
	receipt, rr := s.readAll(appLogReceipt, 1024)
	if rr < 0 {
		return errors.New("receipt read rc=" + strconv.FormatInt(rr, 10))
	}
	var wantReceipt strings.Builder
	wantReceipt.WriteString("app=" + appLogFixture + "\noutcome=" + outcome + "\nlast-log:\n")
	for i := vi.AppLogMaxLines - 4; i <= vi.AppLogMaxLines+3; i++ {
		wantReceipt.WriteString("line-" + twoDigits(i) + "\n")
	}
	if string(receipt) != wantReceipt.String() {
		return errors.New("receipt bytes mismatch")
	}
	return writeReceipt(s, outDir+"/app-log.ok", "ring="+strconv.Itoa(vi.AppLogMaxLines)+" outcome=panic")
}

func writePanicReceipt(s *syscalls, app string) (rc int64) {
	defer func() {
		if recover() != nil {
			rc = s.crashReceipt(app, "panic: fixture failure")
		}
	}()
	panic("fixture failure")
}

func twoDigits(n int) string {
	if n < 10 {
		return "0" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

// The two intake cases, as fixtureCheck values.
var (
	intakeCase = fixtureCheck{
		id:      "intake",
		path:    intakePath,
		want:    intakeFixture,
		mustEqu: true,
		copy:    intakeCopy,
		receipt: intakeReceipt,
	}
	alteredCase = fixtureCheck{
		id:      "intake-altered",
		path:    alteredPath,
		want:    intakeFixture,
		mustEqu: false,
		copy:    alteredCopy,
		receipt: alteredReceipt,
	}
)

// fixtureCheck is the intake case (ADR 0031 D2, M61c #1383): read a share
// fixture the HOST seeded, compare it with a known body, and copy the bytes
// that were actually READ into OUT/.
//
// The copy is the load-bearing part. A binary that answered from an embedded
// constant would pass a self-comparison and still write the constant's bytes,
// so the spec byte-compares OUT/*.copy against the file it seeded on macOS —
// bytes only the share can supply. `mustEqu=false` is the same check pointed
// the other way (the altered fixture must NOT be the canonical bytes), which
// is what makes a mutated seed a FAILED case rather than a silent pass.
type fixtureCheck struct {
	id      string
	path    string // the fixture's path on the share (/host/SELFTEST/IN/...)
	want    string // the known body the case compares against
	mustEqu bool   // true: the fixture must equal want; false: must differ
	copy    string // OUT/ copy of the bytes read
	receipt string // OUT/ receipt for this case
}

func (c fixtureCheck) run(s *syscalls) error {
	// The READ comes first, before anything else in this run touches the
	// share: intake is "what the host seeded", and the app reads it before it
	// writes anything of its own.
	//
	// This read is also the fleet's regression test for issue #1391 (the
	// first kernel->user copy into a page EL0 has never written was silently
	// lost — the syscall returned the right LENGTH and the app read zeros).
	// M61c's first diagnosis blamed the ORDER of share operations; the probe
	// evidence recorded on #1391 blamed the DESTINATION PAGE, and the fix is
	// kernel-side (the copy path resolves the page in the process's own root
	// before it stores). That test only stays meaningful while the read lands
	// in an untouched buffer, so nothing here retries, warms up or reuses one;
	// the case FAILS, naming #1391, on a zeros read.
	//
	// One byte over the expectation: a longer fixture is a mismatch, and the
	// bound keeps a hostile file from being read into memory unboundedly.
	got, err := readFile(s, c.path, len(c.want)+1)
	if err != nil {
		c.writeReceipt(s, 0, false, err.Error())
		return err
	}
	equal := string(got) == c.want

	// The app owns OUT/ and ensures it (EEXIST tolerated) before its first
	// write, so the case does not depend on the spec or on case order.
	s.mkdir(outDir)

	// Copied from `got`, never from `want`.
	if _, werr := writeFile(s, c.copy, got); werr != nil {
		c.writeReceipt(s, len(got), equal, werr.Error())
		return werr
	}
	if werr := c.writeReceipt(s, len(got), equal, ""); werr != nil {
		return werr
	}

	switch {
	case c.mustEqu && !equal:
		// A read that returns the right LENGTH of zeros is issue #1391's
		// shape — a kernel->user copy that never reached the page the app
		// reads. Name it: the detail is the only place a human sees it, and a
		// zeros read is worth distinguishing from a genuine byte mismatch.
		if isAllZero(got) {
			return errors.New("read returned " + strconv.Itoa(len(got)) + "B of zeros (issue #1391)")
		}
		return errors.New("fixture mismatch: got=" + strconv.Itoa(len(got)) +
			" want=" + strconv.Itoa(len(c.want)))
	case c.mustEqu:
		return nil
	case equal:
		return errors.New("altered fixture matched the expectation: " +
			strconv.Itoa(len(got)) + "B")
	}
	// The negative check needs the read to be a BODY, not just different from
	// the canonical bytes: an empty, short or all-zero read differs for the
	// wrong reason. Observed on VZ while #1391 was live — this case PASSED on
	// 25 bytes of zeros, a wrong answer reported as a verdict, so the shape
	// is checked here as well as byte-compared on the host.
	if isAllZero(got) || len(got) != len(c.want) {
		return errors.New("altered fixture read is not a body: " + readShape(got))
	}
	return nil
}

// readShape names what a wrong read returned: its length, and whether every
// byte was zero (issue #1391's shape). Used by the negative check's detail.
func readShape(b []byte) string {
	shape := strconv.Itoa(len(b)) + "B"
	if isAllZero(b) {
		shape += " of zeros"
	}
	return shape
}

// writeReceipt writes the case's OUT/<id>.* receipt: the fixture it read, the
// length it got, and what the comparison said. Deterministic (no clocks, no
// pointers), so the spec can require these exact bytes. A receipt that cannot
// be written fails the case — the file is the evidence, not the serial line.
func (c fixtureCheck) writeReceipt(s *syscalls, n int, equal bool, errText string) error {
	// The receipt names the share-relative path (the form the host cats):
	// /host/SELFTEST/IN/fixture.txt -> IN/fixture.txt.
	rel := strings.TrimPrefix(c.path, selftestDir+"/")
	line := "case " + c.id + " path=" + rel + " bytes=" + strconv.Itoa(n)
	if errText != "" {
		line += " err=" + oneLine(errText)
	} else if c.mustEqu {
		line += " match=" + yesNo(equal)
	} else {
		line += " differs=" + yesNo(!equal)
	}
	_, err := writeFile(s, c.receipt, []byte(line+"\n"))
	return err
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// isAllZero reports whether b is non-empty and every byte is zero — the shape
// of issue #1391's wrong answer (a correct LENGTH of zeros).
func isAllZero(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	for _, v := range b {
		if v != 0 {
			return false
		}
	}
	return true
}

// caseClockMonotonic: the kernel clock advances across a sleep. A clock that
// stands still — or a SlotTime that is not wired — fails honestly; there is
// nothing here a stub can print its way past, because t0 and t1 are reads.
func caseClockMonotonic(s *syscalls) error {
	t0 := s.now()
	for i := 0; i < 8; i++ {
		s.sleep(1)
	}
	t1 := s.now()
	if t1 <= t0 {
		return errors.New("clock did not advance: " + strconv.FormatInt(t0, 10) +
			" -> " + strconv.FormatInt(t1, 10))
	}
	return nil
}

// caseClockEpoch records the actual slot-66 result for the host to compare
// against its own wall clock. The receipt is dynamic, never a golden epoch.
// No usable EFI epoch remains named as such, not forged from monotonic time.
func caseClockEpoch(s *syscalls) error {
	epoch := s.epoch()
	if epoch == -vi.ErrENOSYS {
		return writeReceipt(s, epochReceipt, "case clock-epoch unavailable fallback=monotonic")
	}
	if epoch < 0 {
		return errors.New("epoch rc=" + strconv.FormatInt(epoch, 10))
	}
	return writeReceipt(s, epochReceipt, "case clock-epoch epoch="+strconv.FormatInt(epoch, 10)+" source=firmware")
}

// caseClockSet drives the slot-78 setter (M83b, #1775) end to end. The
// refusals come first, on a clock that must not move: every epoch outside the
// kernel's range has to answer -EINVAL, and a set that was wrongly accepted
// would show as a jump. Then, when the boot has a clock, a real step: forward
// by clockSetStep, read it back, and step back, so the rest of the run — and
// the host's bound on the clock-epoch receipt — still sees the boot clock.
// A boot with no firmware epoch keeps the refusals and skips the step, since
// there is no clock to hand back.
func caseClockSet(s *syscalls) error {
	before := s.epoch()
	hasClock := before != -vi.ErrENOSYS
	if hasClock && before < 0 {
		return errors.New("epoch rc=" + strconv.FormatInt(before, 10))
	}
	for _, bad := range []int64{0, -1, clockSetMin - 1, clockSetMax + 1} {
		if rc := s.setEpoch(bad); rc != -vi.ErrEINVAL {
			return errors.New("set " + strconv.FormatInt(bad, 10) + " rc=" +
				strconv.FormatInt(rc, 10) + ", want " + strconv.FormatInt(-vi.ErrEINVAL, 10))
		}
	}
	if !hasClock {
		if now := s.epoch(); now != -vi.ErrENOSYS {
			return errors.New("a refused set gave the clock an epoch: " + strconv.FormatInt(now, 10))
		}
		return writeReceipt(s, clockSetReceipt, "case clock-set refused=4 step=skipped reason=no-epoch")
	}
	if now := s.epoch(); now < before || now > before+clockSetSlack {
		return errors.New("a refused set moved the clock: " +
			strconv.FormatInt(before, 10) + " -> " + strconv.FormatInt(now, 10))
	}

	target := before + clockSetStep
	if rc := s.setEpoch(target); rc != 0 {
		return errors.New("set " + strconv.FormatInt(target, 10) + " rc=" + strconv.FormatInt(rc, 10))
	}
	stepped := s.epoch()
	var failure error
	back := before
	if stepped < target || stepped > target+clockSetSlack {
		failure = errors.New("read-back after set " + strconv.FormatInt(target, 10) +
			" was " + strconv.FormatInt(stepped, 10))
	} else {
		// The exact inverse of the step: whatever the clock ran during the
		// case is kept, so the restore lands on the true boot clock.
		back = stepped - clockSetStep
	}
	// Restore even when the read-back was wrong, so a failing case cannot
	// leave the rest of the run on a clock 100 s fast.
	if rc := s.setEpoch(back); rc != 0 && failure == nil {
		failure = errors.New("restore to " + strconv.FormatInt(back, 10) + " rc=" + strconv.FormatInt(rc, 10))
	}
	if failure != nil {
		return failure
	}
	if final := s.epoch(); final < before || final > before+clockSetSlack {
		return errors.New("restore left the clock at " + strconv.FormatInt(final, 10) +
			", boot reading was " + strconv.FormatInt(before, 10))
	}
	return writeReceipt(s, clockSetReceipt, "case clock-set refused=4 stepped=+"+
		strconv.Itoa(clockSetStep)+" restored=yes")
}

// caseFileWrite: create the OUT directory (EEXIST tolerated), write a known
// payload to the share, and close it. The guest's claim is the syscall result
// (every byte was accepted); the BYTES are the host's claim — the go-selftest
// spec reads OUT/hello.txt on macOS and compares it byte-exactly, so a write
// that reported success without landing cannot pass the gate.
//
// The read-back half deliberately stays out of M61b: it lands with the
// file-ABI case pack (M61d, #1384) — the first-read behaviour filed as #1391
// is fixed kernel-side, so a read-back into a fresh buffer is now expected to
// work rather than to be worked around.
func caseFileWrite(s *syscalls) error {
	s.mkdir(outDir)
	payload := []byte(helloPayload)
	n, err := writeFile(s, helloPath, payload)
	if err != nil {
		return err
	}
	if n != len(payload) {
		return errors.New("wrote " + strconv.Itoa(n) + "B of " + strconv.Itoa(len(payload)) + "B")
	}
	// The receipt is M61d's addition: every case names what it wrote, so the
	// host has one file per case to read rather than a novel to grep.
	if werr := writeReceipt(s, writeOk, "case file-write path=OUT/hello.txt bytes="+strconv.Itoa(n)); werr != nil {
		return werr
	}
	return nil
}

// ---------------------------------------------------------------------------
// M61d (#1384): the file-ABI pack
// ---------------------------------------------------------------------------
//
// Each case's receipt is one deterministic line naming what it concluded, and
// each case that reads bytes back copies those bytes beside it. The guest's
// claim is the syscall result; the host's claim is the bytes on macOS —
// REPORT.txt, the .ok receipts and the .copy files.

// caseFileRoundtrip: create, write, close, REOPEN and read the exact bytes
// back. The read-back runs through readFile, i.e. into a freshly allocated
// buffer, so this case is also the file path's witness for issue #1391 (the
// first kernel->user copy into a page EL0 has never written; ADR 0032), on top
// of the intake case's share read. OUT/roundtrip.copy holds the bytes READ,
// never the bytes written, so neither a write that reported success without
// landing nor a read that invented bytes can pass the host's comparison.
func caseFileRoundtrip(s *syscalls) error {
	s.mkdir(outDir)
	want := roundtripPayload()
	n, err := writeFile(s, roundtripPath, want)
	if err != nil {
		return err
	}
	if n != len(want) {
		return errors.New("wrote " + strconv.Itoa(n) + "B of " + strconv.Itoa(len(want)) + "B")
	}
	got, err := readFile(s, roundtripPath, len(want)+1)
	if err != nil {
		return err
	}
	match := bytes.Equal(got, want)
	if werr := copyBytes(s, roundtripCopy, got); werr != nil {
		return werr
	}
	line := "case file-roundtrip path=OUT/roundtrip.txt bytes=" + strconv.Itoa(len(got)) +
		" match=" + yesNo(match)
	if werr := writeReceipt(s, roundtripOk, line); werr != nil {
		return werr
	}
	switch {
	case len(got) != len(want):
		return errors.New("read back " + strconv.Itoa(len(got)) + "B of " + strconv.Itoa(len(want)) + "B")
	case !match:
		// The right length of zeros is issue #1391's shape (a kernel->user
		// copy that never reached the page the app reads); anything else is a
		// genuine byte mismatch. Name them differently — the detail is the
		// only place a human sees either.
		if isAllZero(got) {
			return errors.New("read returned " + strconv.Itoa(len(got)) + "B of zeros (issue #1391)")
		}
		return errors.New("read back differs from the bytes written: " + strconv.Itoa(len(got)) + "B")
	}
	return nil
}

// caseFileTruncate: create, write, SHRINK through the same write handle, then
// reopen and read the prefix back. The shrink deliberately does not reopen
// first: per ADR 0010 a write-open without MODE_APPEND replaces the file
// (truncates to zero), which would prove the replace semantics instead of
// truncate's — and the kernel's truncate requires a write handle anyway
// (file_table.truncate: EACCES without MODE_WRITE). OUT/truncated.copy holds
// the bytes read after the shrink.
func caseFileTruncate(s *syscalls) error {
	s.mkdir(outDir)
	full := truncatePayload()
	kept := truncateKept()
	h, rc := s.open(truncatePath, vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		return errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	werr := writeAll(s, uint32(h), full)
	trc := int64(0)
	if werr == nil {
		trc = s.truncate(uint32(h), uint32(len(kept)))
	}
	s.close(uint32(h))
	if werr != nil {
		return werr
	}
	if trc < 0 {
		return errors.New("truncate rc=" + strconv.FormatInt(trc, 10))
	}
	got, err := readFile(s, truncatePath, len(full)+1)
	if err != nil {
		return err
	}
	match := bytes.Equal(got, kept)
	if cerr := copyBytes(s, truncatedCopy, got); cerr != nil {
		return cerr
	}
	line := "case file-truncate path=OUT/truncate.txt wrote=" + strconv.Itoa(len(full)) +
		" kept=" + strconv.Itoa(len(kept)) + " bytes=" + strconv.Itoa(len(got)) +
		" match=" + yesNo(match)
	if rerr := writeReceipt(s, truncateOk, line); rerr != nil {
		return rerr
	}
	switch {
	case len(got) != len(kept):
		return errors.New("after truncate read " + strconv.Itoa(len(got)) + "B of " +
			strconv.Itoa(len(kept)) + "B")
	case !match:
		return errors.New("truncate kept the wrong bytes: " + strconv.Itoa(len(got)) + "B")
	}
	return nil
}

// caseFileDelete: delete a file the case just created, then prove the path is
// gone — a read-only open without MODE_CREATE must fail (the receipt records
// the exact codes, and the host requires them byte-exactly). Nothing recreates
// the path in between, so the delete is the only thing that can make the open
// fail.
func caseFileDelete(s *syscalls) error {
	s.mkdir(outDir)
	if _, err := writeFile(s, deletePath, []byte(deleteBody)); err != nil {
		return err
	}
	drc := s.remove(deletePath)
	h, orc := s.open(deletePath, vi.ModeRead)
	if h >= 0 {
		s.close(uint32(h))
	}
	line := "case file-delete path=OUT/deleted.txt delete=" + strconv.FormatInt(drc, 10) +
		" reopen=" + strconv.FormatInt(orc, 10)
	if werr := writeReceipt(s, deleteOk, line); werr != nil {
		return werr
	}
	switch {
	case drc < 0:
		return errors.New("delete rc=" + strconv.FormatInt(drc, 10))
	case orc >= 0:
		return errors.New("open after delete succeeded: h=" + strconv.FormatInt(h, 10))
	}
	return nil
}

// caseFileList: enumerate a directory that shows a file the case just created
// and does not show it once deleted. The listing runs in the case's OWN
// subdirectory (OUT/LIST): sys_dir_list clamps to 16 rows and mirrors the
// host's sorted direct children, while OUT/ already holds far more than 16
// entries by the time this case runs — listing OUT/ would make the verdict
// depend on the alphabet. The subdirectory also exercises MODE_DIR creation
// for real (the mkdir row needs MODE_WRITE|MODE_CREATE|MODE_DIR together).
func caseFileList(s *syscalls) error {
	s.mkdir(outDir)
	if rc := s.mkdir(listDir); rc != 0 && rc != -9 { // -9 EEXIST is fine
		return errors.New("mkdir OUT/LIST rc=" + strconv.FormatInt(rc, 10))
	}
	if _, err := writeFile(s, listedPath, []byte(listMarkerBody)); err != nil {
		return err
	}
	var buf [vi.MaxDirEntries]vi.DirEntry
	n1, r1 := s.list(listDir, buf[:])
	if r1 < 0 {
		return errors.New("list rc=" + strconv.FormatInt(r1, 10))
	}
	// The marker must appear as a FILE row: a directory row with that name
	// would mean the listing resolved something else entirely.
	seen := false
	for _, e := range buf[:n1] {
		if e.NameString() == "listed.txt" {
			seen = !e.Dir()
		}
	}
	drc := s.remove(listedPath)
	if drc < 0 {
		return errors.New("delete rc=" + strconv.FormatInt(drc, 10))
	}
	n2, r2 := s.list(listDir, buf[:])
	if r2 < 0 {
		return errors.New("list after delete rc=" + strconv.FormatInt(r2, 10))
	}
	gone := true
	for _, e := range buf[:n2] {
		if e.NameString() == "listed.txt" {
			gone = false
		}
	}
	line := "case file-list dir=OUT/LIST file=listed.txt first=" + seenWord(seen) +
		" second=" + seenWord(!gone)
	if werr := writeReceipt(s, listOk, line); werr != nil {
		return werr
	}
	switch {
	case !seen:
		return errors.New("listing missed listed.txt (entries=" + strconv.Itoa(n1) + ")")
	case !gone:
		return errors.New("listing still shows listed.txt (entries=" + strconv.Itoa(n2) + ")")
	}
	return nil
}

// ---------------------------------------------------------------------------
// M66a (#1443): the file-semantics hardening pack
// ---------------------------------------------------------------------------
//
// The card's semantics, each proven the ADR 0031 way — the guest writes its
// receipts and the bytes it READ, the host byte-compares them on macOS:
// append-at-EOF, a write far beyond one syscall (chunked by confirmed
// counts), the truncate clamp, the fsync durability verb, and the honest
// error rows.

// caseFileAppend: write a base body with the replace semantics, then REOPEN
// with ModeAppend — no create — and write more. The append write must land
// AFTER the base: the host's append cursor is EOF. A dropped append flag
// anywhere below the ABI would replace the file instead, and the read-back
// would be the delta alone.
func caseFileAppend(s *syscalls) error {
	s.mkdir(outDir)
	base, more := appendBasePayload(), appendMorePayload()
	if _, err := writeFile(s, appendPath, base); err != nil {
		return err
	}
	h, rc := s.open(appendPath, vi.ModeWrite|vi.ModeAppend)
	if rc < 0 {
		return errors.New("append open rc=" + strconv.FormatInt(rc, 10))
	}
	werr := writeAll(s, uint32(h), more)
	s.close(uint32(h))
	if werr != nil {
		return werr
	}
	want := append(append([]byte{}, base...), more...)
	got, err := readFile(s, appendPath, len(want)+1)
	if err != nil {
		return err
	}
	match := bytes.Equal(got, want)
	if cerr := copyBytes(s, appendCopy, got); cerr != nil {
		return cerr
	}
	line := "case file-append path=OUT/append.txt base=" + strconv.Itoa(len(base)) +
		" more=" + strconv.Itoa(len(more)) + " bytes=" + strconv.Itoa(len(got)) +
		" match=" + yesNo(match)
	if rerr := writeReceipt(s, appendOk, line); rerr != nil {
		return rerr
	}
	if !match {
		return errors.New("append read back " + strconv.Itoa(len(got)) + "B, want " +
			strconv.Itoa(len(want)) + "B")
	}
	return nil
}

// caseFileBigwrite: a body far beyond one sys_file_write call — the kernel
// refuses count > 2048 (-ENOSPC), so this write only lands through the
// confirmed-count chunk loop (writeAll). The read-back and the .copy must
// equal the payload byte-for-byte: a chunk that resumed at the wrong offset,
// or a confirmed count that lied, shows up as a mismatch the host sees.
func caseFileBigwrite(s *syscalls) error {
	s.mkdir(outDir)
	want := bigwritePayload()
	if _, err := writeFile(s, bigwritePath, want); err != nil {
		return err
	}
	got, err := readFile(s, bigwritePath, len(want)+1)
	if err != nil {
		return err
	}
	match := bytes.Equal(got, want)
	if cerr := copyBytes(s, bigwriteCopy, got); cerr != nil {
		return cerr
	}
	calls := (len(want) + fileWriteMax - 1) / fileWriteMax
	line := "case file-bigwrite path=OUT/bigwrite.txt bytes=" + strconv.Itoa(len(want)) +
		" calls=" + strconv.Itoa(calls) + " match=" + yesNo(match)
	if rerr := writeReceipt(s, bigwriteOk, line); rerr != nil {
		return rerr
	}
	switch {
	case len(got) != len(want):
		return errors.New("read back " + strconv.Itoa(len(got)) + "B of " + strconv.Itoa(len(want)) + "B")
	case !match:
		return errors.New("bigwrite read back differs at " + strconv.Itoa(firstDiff(got, want)))
	}
	return nil
}

// firstDiff is the offset of the first differing byte (the payload length
// when equal), so a chunk-boundary bug names where the stream went wrong.
func firstDiff(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

// caseFileClamp: the truncate clamp. Write 40 units, shrink the SAME handle
// to 5 units, then write 3 more through the still-open handle: the host
// clamps its cursor to the new size, so the extra bytes land at the clamp
// point and the file is kept+extra (8 units). Without the clamp the write
// would resume at the old cursor — a hole past EOF — and the read-back would
// be neither the length nor the bytes expected.
func caseFileClamp(s *syscalls) error {
	s.mkdir(outDir)
	full, kept, extra := clampFull(), clampKept(), clampExtra()
	h, rc := s.open(clampPath, vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		return errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	werr := writeAll(s, uint32(h), full)
	trc := int64(0)
	if werr == nil {
		trc = s.truncate(uint32(h), uint32(len(kept)))
	}
	var xerr error
	if werr == nil && trc == 0 {
		xerr = writeAll(s, uint32(h), extra)
	}
	s.close(uint32(h))
	if werr != nil {
		return werr
	}
	if trc < 0 {
		return errors.New("truncate rc=" + strconv.FormatInt(trc, 10))
	}
	if xerr != nil {
		return xerr
	}
	want := append(append([]byte{}, kept...), extra...)
	got, err := readFile(s, clampPath, len(want)+1)
	if err != nil {
		return err
	}
	match := bytes.Equal(got, want)
	if cerr := copyBytes(s, clampCopy, got); cerr != nil {
		return cerr
	}
	line := "case file-clamp path=OUT/clamp.txt wrote=" + strconv.Itoa(len(full)) +
		" kept=" + strconv.Itoa(len(kept)) + " extra=" + strconv.Itoa(len(extra)) +
		" bytes=" + strconv.Itoa(len(got)) + " match=" + yesNo(match)
	if rerr := writeReceipt(s, clampOk, line); rerr != nil {
		return rerr
	}
	switch {
	case len(got) != len(want):
		return errors.New("after clamp read " + strconv.Itoa(len(got)) + "B, want " +
			strconv.Itoa(len(want)) + "B")
	case !match:
		return errors.New("clamp kept the wrong bytes")
	}
	return nil
}

// caseFileFsync: the durability verb. Write a body, FSYNC the open handle
// (0 = the host pushed its live fd), close, then fsync the CLOSED fd — the
// honest EBADF, proving the verb is checked and not a stub. The host
// byte-compares fsync.txt, so a success code without the bytes cannot pass.
func caseFileFsync(s *syscalls) error {
	s.mkdir(outDir)
	want := fsyncPayload()
	h, rc := s.open(fsyncPath, vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		return errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	werr := writeAll(s, uint32(h), want)
	frc := int64(0)
	if werr == nil {
		frc = s.sync(uint32(h))
	}
	s.close(uint32(h))
	if werr != nil {
		return werr
	}
	if frc < 0 {
		return errors.New("fsync rc=" + strconv.FormatInt(frc, 10))
	}
	// No open has happened since the close, so the slot is still free and
	// the kernel must refuse the verb with EBADF.
	crc := s.sync(uint32(h))
	line := "case file-fsync path=OUT/fsync.txt bytes=" + strconv.Itoa(len(want)) +
		" fsync=" + strconv.FormatInt(frc, 10) + " closed=" + strconv.FormatInt(crc, 10)
	if rerr := writeReceipt(s, fsyncOk, line); rerr != nil {
		return rerr
	}
	if crc != -2 {
		return errors.New("fsync on a closed fd rc=" + strconv.FormatInt(crc, 10))
	}
	return nil
}

// caseFileErrors: the honest error rows, each observed through the ABI on a
// path this case owns: a missing open is ENOENT (-6), a second create of the
// same directory is the file-domain EEXIST (-9), a WRITE open of that
// directory is is-dir EINVAL (-1), and the 9th concurrent open — the
// caller's 8-handle table being full — is ENOSPC (-5). The receipt records
// all four codes; the kernel's hf_open_errno pins the same rows host-side.
func caseFileErrors(s *syscalls) error {
	s.mkdir(outDir)
	_, mrc := s.open(errMissing, vi.ModeRead)
	if rc := s.mkdir(errDir); rc != 0 {
		return errors.New("mkdir ERR rc=" + strconv.FormatInt(rc, 10))
	}
	_, erc := s.open(errDir, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	_, drc := s.open(errDir, vi.ModeWrite)
	// Hold the caller's 8 handles; the 9th open has no slot. Each open here
	// is also a host write handle, so the loop is the honest way to reach
	// the table cap from EL0.
	hs := make([]int64, 0, 9)
	fullRC := int64(0)
	for i := 0; i < 9; i++ {
		h, rc := s.open(errDir+"/h"+strconv.Itoa(i), vi.ModeWrite|vi.ModeCreate)
		if rc < 0 {
			fullRC = rc
			break
		}
		hs = append(hs, h)
	}
	for i, h := range hs {
		s.close(uint32(h))
		// Keep the share tidy: the probe files have no evidence value.
		s.remove(errDir + "/h" + strconv.Itoa(i))
	}
	line := "case file-errors missing=" + strconv.FormatInt(mrc, 10) +
		" exists=" + strconv.FormatInt(erc, 10) + " isdir=" + strconv.FormatInt(drc, 10) +
		" ninth=" + strconv.FormatInt(fullRC, 10)
	if werr := writeReceipt(s, errOk, line); werr != nil {
		return werr
	}
	switch {
	case mrc != vi.ErrFileNotFound:
		return errors.New("missing open rc=" + strconv.FormatInt(mrc, 10) + ", want -6")
	case erc != vi.ErrFileExists:
		return errors.New("double mkdir rc=" + strconv.FormatInt(erc, 10) + ", want -9")
	case drc != vi.ErrFileIsDir:
		return errors.New("dir write-open rc=" + strconv.FormatInt(drc, 10) + ", want -1")
	case fullRC != vi.ErrFileHandleFull:
		return errors.New("ninth open rc=" + strconv.FormatInt(fullRC, 10) + ", want -5")
	}
	return nil
}

// ---------------------------------------------------------------------------
// M61e (#1385): the window receipt
// ---------------------------------------------------------------------------

// colWindowProbe is the window case's one fill rectangle. It exists so a human
// looking at the captured frame can see the case ran. It is never compared to
// anything and never part of a verdict — the card's non-goal is pixel
// comparison, and this case reads no pixels at all.
const colWindowProbe = uint32(0x2d6a4f)

// caseWindow: fill + present the app's own tabapp window, then write the one
// line the card asks for — the id the kernel assigned, the geometry the KERNEL
// reports for that window, and the present verdict.
//
// The geometry is a READ-BACK, not a restatement of the app's request: it
// comes from sys_win_query, which copies the kernel's window record into a
// fresh user buffer through the same kernel->user path issue #1391 broke and
// ADR 0032 fixed. That distinction is what makes the receipt worth reading —
// the host can hold `win=<id>` to the window the KERNEL's own serial log says
// it created (`open: id=<N> owner=<pid> rect=…`) and to the id TABWM reports
// (`tabwm: tab-switch … id=<N>`), two reporters that are not this process.
// See the spec, which does exactly that before it byte-compares the line.
//
// This is deliberately NOT a framebuffer golden: no pixels are read, no PNG
// is produced, and nothing here knows what the window looks like.
func caseWindow(s *syscalls) error {
	s.mkdir(outDir)
	w := s.win
	if w.id < 0 {
		return errors.New("no window: tabapp open failed")
	}
	// Fill, then present — the card's sequence. Both returns are checked: a
	// window that cannot take a rect or flush a frame is a failed case, not a
	// warning.
	if frc := w.fill(w.id, 0, 0, 8, 8, colWindowProbe); frc < 0 {
		return errors.New("fill rc=" + strconv.FormatInt(frc, 10))
	}
	if prc := w.present(w.id); prc < 0 {
		return errors.New("present rc=" + strconv.FormatInt(prc, 10))
	}
	q, qrc := w.query(w.id)
	if qrc < 0 {
		return errors.New("query rc=" + strconv.FormatInt(qrc, 10))
	}
	// q is (x, y, w, h, z, focused, visible, dirty) — the kernel's view.
	gotW, gotH := q[2], q[3]

	// The receipt is written BEFORE the verdict (the file is the evidence), so
	// a failing run still leaves the host the numbers that failed it.
	line := "case window win=" + strconv.Itoa(w.id) +
		" w=" + strconv.FormatUint(uint64(gotW), 10) +
		" h=" + strconv.FormatUint(uint64(gotH), 10) +
		" present=ok"
	if werr := writeReceipt(s, windowReceipt, line); werr != nil {
		return werr
	}
	if gotW == 0 || gotH == 0 {
		// A window the kernel reports as empty is a broken window: the fill and
		// the present both claimed success, so this is the read-back catching
		// what the two writes could not.
		return errors.New("query reports an empty window: " +
			strconv.FormatUint(uint64(gotW), 10) + "x" + strconv.FormatUint(uint64(gotH), 10))
	}
	return nil
}

// caseDisk is the M100f (#2311, ADR 0050) VLFS leg: write → fsync → close →
// reopen → read-back on the guest's own journaled volume, with the receipts
// on /host so the host byte-compares the evidence even while the disk is the
// thing under test (the fsync is a real VIRTIO_BLK_T_FLUSH barrier — D4's
// commit ordering means the write was already durable; the call is still the
// ABI's own verb, exercised end to end).
//
// The probe is one dirlist of the volume root: no data disk attached (or a
// refused mount) is the kernel's named `not_mounted`, surfaced through the
// file ABI as ENOENT — the case records `mounted=no` and PASSES, because the
// default fleet boots no disk and ADR 0050 makes a disk an enhancement,
// never a requirement. A mounted volume that cannot complete the drill is a
// FAIL, not a skip — the opt-in run is where this case earns its keep.
func caseDisk(s *syscalls) error {
	s.mkdir(outDir)
	var probe [1]vi.DirEntry
	if _, rc := s.list("/disk", probe[:]); rc < 0 {
		return writeReceipt(s, diskOk, "case disk mounted=no skipped")
	}
	if rc := s.mkdir(diskDir); rc < 0 && rc != -9 { // -9 EEXIST: re-run is fine
		return errors.New("mkdir disk rc=" + strconv.FormatInt(rc, 10))
	}
	want := diskPayload()
	h, rc := s.open(diskPath, vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		return errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	werr := writeAll(s, uint32(h), want)
	frc := int64(0)
	if werr == nil {
		frc = s.sync(uint32(h))
	}
	s.close(uint32(h))
	if werr != nil {
		return werr
	}
	if frc < 0 {
		return errors.New("fsync rc=" + strconv.FormatInt(frc, 10))
	}
	got, err := readFile(s, diskPath, len(want)+1)
	if err != nil {
		return err
	}
	match := bytes.Equal(got, want)
	// The receipts are written BEFORE the verdict (the files are the
	// evidence): disk.copy carries the bytes READ BACK off the volume, not
	// the intended body — a lying disk fails the host's byte-compare.
	if cerr := copyBytes(s, diskCopy, got); cerr != nil {
		return cerr
	}
	line := "case disk mounted=yes path=SELFTEST/DISK.TXT wrote=" +
		strconv.Itoa(len(want)) + " fsync=" + strconv.FormatInt(frc, 10) +
		" read=" + strconv.Itoa(len(got)) + " match=" + yesNo(match)
	if rerr := writeReceipt(s, diskOk, line); rerr != nil {
		return rerr
	}
	if !match || len(got) != len(want) {
		return errors.New("read-back is not the written body")
	}
	return nil
}

// seenWord renders a listing verdict for a receipt: "seen" / "absent".
func seenWord(seen bool) string {
	if seen {
		return "seen"
	}
	return "absent"
}

// copyBytes writes b to path, replacing it — the .copy half of a case's
// evidence: the bytes the case READ, for the host to compare.
func copyBytes(s *syscalls, path string, b []byte) error {
	_, err := writeFile(s, path, b)
	return err
}

// writeReceipt writes one receipt line (plus its newline) to path.
func writeReceipt(s *syscalls, path string, line string) error {
	_, err := writeFile(s, path, []byte(line+"\n"))
	return err
}

// writeAll writes b through an OPEN handle, chunked to the kernel's
// 2048-byte sys_file_write stage cap (a larger count is refused -ENOSPC)
// and advancing only by the CONFIRMED count each call reports — FileWrite
// may accept fewer bytes than offered, and the next chunk resumes exactly
// where the kernel confirmed (M66a: a partial write never corrupts the
// stream).
func writeAll(s *syscalls, h uint32, b []byte) error {
	written := 0
	for written < len(b) {
		take := len(b) - written
		if take > fileWriteMax {
			take = fileWriteMax
		}
		n, rc := s.write(h, b[written:written+take])
		if rc < 0 || n <= 0 {
			return errors.New("write rc=" + strconv.FormatInt(rc, 10))
		}
		written += n
	}
	return nil
}

// runCases executes the list in order and returns one result per case. A case
// fails by returning an error — never by panicking — so the report is always
// written and the summary always printed.
func runCases(s *syscalls) []result {
	list := cases()
	rs := make([]result, 0, len(list))
	for _, c := range list {
		r := result{id: c.id, ok: true}
		if err := c.run(s); err != nil {
			r.ok = false
			r.detail = oneLine(err.Error())
		}
		rs = append(rs, r)
	}
	return rs
}

// writeFile replaces path with b and closes it. MODE_WRITE|MODE_CREATE is the
// ADR 0010 replace semantics (a write-open without MODE_APPEND truncates to
// zero), so the file always holds exactly b. FileWrite is one kernel call and
// may accept fewer bytes than offered, so it loops.
func writeFile(s *syscalls, path string, b []byte) (int, error) {
	h, rc := s.open(path, vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		return 0, errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	if err := writeAll(s, uint32(h), b); err != nil {
		s.close(uint32(h))
		return 0, err
	}
	s.close(uint32(h))
	return len(b), nil
}

// readFile reads a whole file up to max bytes. It is the substrate for the
// intake (M61c) and read-back (M61d) cases, unit-tested through the fake share
// in selftest_test.go.
//
// The buffer is deliberately a FRESH allocation the case then reads into.
// That is the regression test for issue #1391: the first kernel->user copy
// into a page EL0 has never written used to be silently lost (the syscall
// returned the right byte count and the app read the page's zeros — observed
// the same way for APPS.TXT (852 B) and for a file the guest had just written
// (13 B). It was never the file channel — the runner's own stdout shows the
// bytes served — nor the guest's write path, whose pages are dirty before the
// syscall; the cause was the destination page resolving for EL1 through the
// kernel's identity overlay, and it is fixed in the kernel's copy path (every
// destination page is resolved in the reading process's own root before the
// store). fixtureCheck still names the zeros shape in the case detail, so a
// regression is never a bare "mismatch" — and nothing here retries, warms up
// or reuses a buffer as a substitute for that fix.
func readFile(s *syscalls, path string, max int) ([]byte, error) {
	h, rc := s.open(path, vi.ModeRead)
	if rc < 0 {
		return nil, errors.New("open rc=" + strconv.FormatInt(rc, 10))
	}
	defer s.close(uint32(h))
	var out []byte
	buf := make([]byte, 4096)
	for len(out) < max {
		n, rrc := s.read(uint32(h), buf)
		if rrc < 0 {
			return out, errors.New("read rc=" + strconv.FormatInt(rrc, 10))
		}
		if n == 0 {
			break
		}
		out = append(out, buf[:n]...)
	}
	return out, nil
}

// renderReport is the report grammar of ADR 0031: one
// `case <id> pass|fail <detail>` line per case in list order, then the
// `summary cases=<n> failed=<k>` line. Deterministic on purpose.
func renderReport(rs []result) []byte {
	var b strings.Builder
	for _, r := range rs {
		b.WriteString("case " + r.id + " ")
		if r.ok {
			b.WriteString("pass\n")
			continue
		}
		b.WriteString("fail")
		if r.detail != "" {
			b.WriteString(" " + r.detail)
		}
		b.WriteString("\n")
	}
	b.WriteString(summaryLine(rs) + "\n")
	return []byte(b.String())
}

// renderSummary is the OUT/summary.txt body: the same counts as the report's
// summary line, so the two files can never disagree.
func renderSummary(rs []result) []byte {
	return []byte(summaryLine(rs) + "\n")
}

// summaryLine is the one count line shared by REPORT.txt and summary.txt.
func summaryLine(rs []result) string {
	return "summary cases=" + strconv.Itoa(len(rs)) + " failed=" + strconv.Itoa(failed(rs))
}

// failed counts the failed cases.
func failed(rs []result) int {
	n := 0
	for _, r := range rs {
		if !r.ok {
			n++
		}
	}
	return n
}

// caseLine is the per-case serial heartbeat line (ADR 0031: these are welcome
// before the summary, and are never the proof).
func caseLine(r result) string {
	if r.ok {
		return "selftest: case " + r.id + " pass"
	}
	line := "selftest: case " + r.id + " fail"
	if r.detail != "" {
		line += " " + r.detail
	}
	return line
}

// serialSummary is the serial contract, in order: the FAIL line carrying the
// count, then `selftest OK` when nothing failed. The spec stops the VM on
// `selftest: FAIL n=` (any N) and asserts n=0.
func serialSummary(nFailed int) []string {
	lines := []string{"selftest: FAIL n=" + strconv.Itoa(nFailed)}
	if nFailed == 0 {
		lines = append(lines, "selftest OK")
	}
	return lines
}

// oneLine keeps a failure detail on one line and bounds its length, so the
// report stays a fixed-shape text file and the paint stays inside the frame.
func oneLine(s string) string {
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return ' '
		}
		return r
	}, s)
	const maxDetail = 48
	if len(s) > maxDetail {
		s = s[:maxDetail]
	}
	return s
}

// caseFileWriteSafe: the publish primitive the M81e (#1765) app conversions
// stand on — vi.WriteFileSafe's temp + fsync + delete-then-rename. Two
// properties, both invisible to the syscall rows above because the ORDER is
// the contract:
//
//   - replacing a LONG body with a SHORT one leaves exactly the short body.
//     An in-place writer that never truncates to size would leave a tail; the
//     publish is whole-file by construction, so write-safe.txt is 105 B.
//   - the sacrificial temp does not SURVIVE a completed publish. The temp is
//     the one path allowed to exist mid-publish (it is what makes the live
//     file never truncated), and an orphan would otherwise sit on the share
//     forever — the publish replaces it on the next write, nothing removes it
//     at boot.
//
// OUT/write-safe.copy holds the bytes read back after the second publish, so
// the host byte-compares the file, not just the receipt.
func caseFileWriteSafe(s *syscalls) error {
	s.mkdir(outDir)
	long := writeSafeLong()
	short := writeSafeShort()
	if rc := s.writeSafe(writeSafePath, long); rc < 0 {
		return errors.New("first publish rc=" + strconv.FormatInt(rc, 10))
	}
	if rc := s.writeSafe(writeSafePath, short); rc < 0 {
		return errors.New("second publish rc=" + strconv.FormatInt(rc, 10))
	}
	got, err := readFile(s, writeSafePath, len(long)+1)
	if err != nil {
		return err
	}
	tail := "none"
	if len(got) > len(short) {
		tail = strconv.Itoa(len(got)-len(short)) + "B"
	}
	match := bytes.Equal(got, short)
	orphan := "none"
	if h, rc := s.open(writeSafeTmp, vi.ModeRead); rc >= 0 {
		s.close(uint32(h))
		orphan = "survived"
	}
	if cerr := copyBytes(s, writeSafeCopy, got); cerr != nil {
		return cerr
	}
	line := "case file-write-safe path=OUT/write-safe.txt long=" + strconv.Itoa(len(long)) +
		" short=" + strconv.Itoa(len(short)) + " bytes=" + strconv.Itoa(len(got)) +
		" tail=" + tail + " orphan=" + orphan + " match=" + yesNo(match)
	if rerr := writeReceipt(s, writeSafeOk, line); rerr != nil {
		return rerr
	}
	switch {
	case !match || len(got) != len(short):
		return errors.New("after the shorter publish the file read " +
			strconv.Itoa(len(got)) + "B, want the " + strconv.Itoa(len(short)) +
			"B body with no tail")
	case orphan != "none":
		return errors.New("the sacrificial temp " + writeSafeTmp + " survived the publish")
	}
	return nil
}

// caseTrash proves the app-facing undo contract on bytes read from the share:
// delete into TRASH, copy the trashed bytes into OUT/, restore to the original
// path and read them back, then expire a second old item. RECENT must contain
// all three actions in order.
func caseTrash(s *syscalls) error {
	s.mkdir(outDir)
	want := []byte("M81a trash fixture\n")
	if _, err := writeFile(s, trashSourcePath, want); err != nil {
		return err
	}
	id, drc := s.trashDelete(trashSourcePath)
	if drc < 0 {
		return errors.New("trash delete rc=" + strconv.FormatInt(drc, 10))
	}
	original, body, _, trc := s.trashRead(id)
	if trc < 0 {
		return errors.New("trash read rc=" + strconv.FormatInt(trc, 10))
	}
	match := original == trashSourcePath && bytes.Equal(body, want)
	if err := copyBytes(s, trashCopyPath, body); err != nil {
		return err
	}
	restoredPath, restoredID, rrc := s.trashRestore()
	if rrc < 0 || restoredPath != trashSourcePath || restoredID != id {
		return errors.New("restore path/id mismatch: " + restoredPath + "/" + restoredID +
			" rc=" + strconv.FormatInt(rrc, 10))
	}
	restored, readRC := s.readAll(trashSourcePath, len(want)+1)
	if readRC < 0 || !bytes.Equal(restored, want) {
		return errors.New("restored bytes mismatch rc=" + strconv.FormatInt(readRC, 10))
	}
	if _, err := writeFile(s, expirySourcePath, []byte("expire me\n")); err != nil {
		return err
	}
	expiryID, erc := s.trashDelete(expirySourcePath)
	if erc < 0 {
		return errors.New("expiry trash rc=" + strconv.FormatInt(erc, 10))
	}
	_, _, created, readTrashRC := s.trashRead(expiryID)
	if readTrashRC < 0 {
		return errors.New("expiry item read rc=" + strconv.FormatInt(readTrashRC, 10))
	}
	expired, xrc := s.trashExpire(created + vi.TrashRetentionSeconds)
	if xrc < 0 || expired != 1 {
		return errors.New("expiry count=" + strconv.Itoa(expired) +
			" rc=" + strconv.FormatInt(xrc, 10))
	}
	_, _, _, missingRC := s.trashRead(expiryID)
	if missingRC != vi.ErrFileNotFound {
		return errors.New("expired receipt still readable rc=" + strconv.FormatInt(missingRC, 10))
	}
	recent, recentRC := s.readAll(vi.RecentLogPath, 8192)
	if recentRC < 0 || !strings.Contains(string(recent), "|delete|"+id+"|") ||
		!strings.Contains(string(recent), "|restore|"+id+"|") ||
		!strings.Contains(string(recent), "|delete|"+expiryID+"|") {
		return errors.New("recent log missing trash actions rc=" + strconv.FormatInt(recentRC, 10))
	}
	line := "case trash path=OUT/trash-source.txt bytes=" + strconv.Itoa(len(body)) +
		" match=" + yesNo(match) + " restored=yes expiry=" + strconv.Itoa(expired) +
		" recent=delete,restore,delete"
	if err := writeReceipt(s, trashReceiptPath, line); err != nil {
		return err
	}
	if !match {
		return errors.New("trash bytes differ from original")
	}
	return nil
}

// M81e2 (#1787): caseFileWritePublish pins the seam BOTH shell hooks now
// call — the history ring-replace save and the history append, which is to
// say the whole of what vi.WriteFilePublish decides. Three facts, in order:
//
//  1. a REPLACE (appendMode false) over a LONGER existing body leaves
//     exactly the new body and no tail — the history ring trimming itself
//     back to historyMax must not leave the oldest line's bytes behind;
//  2. that same replace leaves no sacrificial temp, so the share holds one
//     history file and no orphan;
//  3. an APPEND (appendMode true) ADDS to what is there and truncates
//     nothing — the one-line history append and `>>`. This is the half
//     that must NOT be routed through the safe publish, and the half that
//     would be silently wrong if it were: a rewrite-per-line history would
//     still pass a "the line is in the file" check while getting the
//     durability and the cost entirely wrong.
//
// The receipt is host-byte-compared (go-selftest.spec), so the verdict is
// about bytes that came back over the share, not a constant in this binary.
func caseFileWritePublish(s *syscalls) error {
	s.mkdir(outDir)
	// A long body first, so the replace is a SHRINK — the case that catches
	// a publish that appends instead of replacing, and the case a bare
	// "the new bytes are present" check would pass.
	long := writeSafeLong()
	short := writeSafeShort()
	line1 := []byte("gosh-history-one\n")
	line2 := []byte("gosh-history-two\n")

	if rc := s.publish(publishPath, long, false); rc < 0 {
		return errors.New("initial publish rc=" + strconv.FormatInt(rc, 10))
	}
	if rc := s.publish(publishPath, short, false); rc < 0 {
		return errors.New("replace publish rc=" + strconv.FormatInt(rc, 10))
	}
	got, err := readFile(s, publishPath, len(long)+1)
	if err != nil {
		return err
	}
	replaced := bytes.Equal(got, short)
	tail := "none"
	if len(got) > len(short) {
		tail = strconv.Itoa(len(got)-len(short)) + "B"
	}
	orphan := "none"
	if h, rc := s.open(publishTmp, vi.ModeRead); rc >= 0 {
		s.close(uint32(h))
		orphan = "survived"
	}

	// Now the append half, against the file the replace just left.
	if rc := s.publish(publishPath, line1, true); rc < 0 {
		return errors.New("append publish rc=" + strconv.FormatInt(rc, 10))
	}
	if rc := s.publish(publishPath, line2, true); rc < 0 {
		return errors.New("second append publish rc=" + strconv.FormatInt(rc, 10))
	}
	after, err := readFile(s, publishPath, len(long)+len(line1)+len(line2)+1)
	if err != nil {
		return err
	}
	want := append(append([]byte{}, short...), append(line1, line2...)...)
	appended := bytes.Equal(after, want)

	if cerr := copyBytes(s, publishCopy, after); cerr != nil {
		return cerr
	}
	rec := "case file-write-publish path=OUT/publish.txt base=" +
		strconv.Itoa(len(short)) + " after=" + strconv.Itoa(len(after)) +
		" want=" + strconv.Itoa(len(want)) + " tail=" + tail +
		" orphan=" + orphan + " replaced=" + yesNo(replaced) +
		" appended=" + yesNo(appended)
	if rerr := writeReceipt(s, publishOk, rec); rerr != nil {
		return rerr
	}
	switch {
	case !replaced || len(got) != len(short):
		return errors.New("after the replace the file read " +
			strconv.Itoa(len(got)) + "B, want the " + strconv.Itoa(len(short)) +
			"B body with no tail of the " + strconv.Itoa(len(long)) + "B it replaced")
	case orphan != "none":
		return errors.New("the sacrificial temp " + publishTmp +
			" survived the publish — the share would hold an orphan")
	case !appended:
		return errors.New("after two appends the file read " +
			strconv.Itoa(len(after)) + "B, want the " + strconv.Itoa(len(want)) +
			"B base-plus-lines body — an append must add, never truncate")
	}
	return nil
}

// M81g (#1767): caseFileSnapshot is the restore DRILL, both halves, on the
// share. The seat (GOTABWM.ELF) is what actually snapshots and restores in
// the product; this case exists because a drill nobody can read back is a
// drill nobody can believe, and the receipt idiom (ADR 0031/0032) already
// proves `/host` state by host-side byte comparison.
//
// What it pins, in order:
//
//  1. CARRY. Four host-seeded fixtures under IN/ — a settings table, a BINARY
//     session strip, and two documents — go into one bundle. The bodies are
//     READ from the share, never compiled in, so a case that answered from a
//     constant could not match what the host seeded.
//  2. PUBLISH. The bundle is published through the crash-safe write, and the
//     bytes are read BACK and compared to what was built. The sacrificial
//     temp must not survive, exactly as the file-write-safe case pins.
//  3. REHYDRATE. The bundle is parsed back out of the file and every entry is
//     published again under RESTORED/. The host byte-compares RESTORED/
//     against IN/, so what it is looking at is a round trip through the
//     container — the card's "byte-exact" claim, checked from outside.
//  4. REFUSE. One byte is taken off the end and the result must be refused
//     whole. The receipt's `corrupt=` field is that verdict; a codec that
//     tolerated a truncated tail would restore a session strip that was never
//     whole, which is the exact failure M62e/M66b refuse to allow.
func caseFileSnapshot(s *syscalls) error {
	s.mkdir(outDir)
	s.mkdir(snapshotInDocs)
	s.mkdir(restoredDir)
	s.mkdir(restoredDocsDir)

	// 1. CARRY — the bodies come off the share.
	bodies := make([][]byte, 0, 4)
	for _, in := range []struct {
		path string
		max  int
	}{
		{snapshotInSettings, snapshotReadSettings},
		{snapshotInSession, snapshotReadBody},
		{snapshotInNote, snapshotReadBody},
		{snapshotInSecond, snapshotReadBody},
	} {
		b, err := readFile(s, in.path, in.max)
		if err != nil {
			return err
		}
		bodies = append(bodies, b)
	}
	settingsBody, sessionBody := bodies[0], bodies[1]
	// The documents go in NAME order (NOTE.TXT before SECOND.TXT), which is
	// the order the seat's capture sorts them into. Keeping the two captures
	// identical in shape is what makes one container serve both apps.
	entries := []snapshot.Entry{
		{Name: snapshot.EntrySettings, Body: settingsBody},
		{Name: snapshot.EntrySession, Body: sessionBody},
		{Name: snapshot.DocsPrefix + "NOTE.TXT", Body: bodies[2]},
		{Name: snapshot.DocsPrefix + "SECOND.TXT", Body: bodies[3]},
	}
	raw, ok := snapshot.Build(entries)
	if !ok {
		return errors.New("snapshot.Build refused the four seeded entries")
	}

	// 2. PUBLISH crash-safe, then read the bundle back off the share.
	if rc := s.writeSafe(snapshotBundle, raw); rc < 0 {
		return errors.New("bundle publish rc=" + strconv.FormatInt(rc, 10))
	}
	got, err := readFile(s, snapshotBundle, snapshotReadBundle)
	if err != nil {
		return err
	}
	if !bytes.Equal(got, raw) {
		return errors.New("the published bundle read back " + strconv.Itoa(len(got)) +
			"B, want the " + strconv.Itoa(len(raw)) + "B body that was published")
	}
	orphan := "none"
	if h, rc := s.open(snapshotBundleTmp, vi.ModeRead); rc >= 0 {
		s.close(uint32(h))
		orphan = "survived"
	}
	if cerr := copyBytes(s, snapshotBundleCopy, got); cerr != nil {
		return cerr
	}

	// 3. REHYDRATE — parse the bytes that came back, and republish each entry.
	b, ok, reason := snapshot.Parse(got)
	if !ok {
		return errors.New("Parse refused the bundle this case published: " + reason)
	}
	out := []struct {
		entry string
		path  string
	}{
		{snapshot.EntrySettings, restoredSettings},
		{snapshot.EntrySession, restoredSession},
		{snapshot.DocsPrefix + "NOTE.TXT", restoredNote},
		{snapshot.DocsPrefix + "SECOND.TXT", restoredSecond},
	}
	for _, o := range out {
		body, found := b.Get(o.entry)
		if !found {
			return errors.New("the parsed bundle is missing " + o.entry)
		}
		if rc := s.writeSafe(o.path, body); rc < 0 {
			return errors.New("rehydrate " + o.entry + " rc=" + strconv.FormatInt(rc, 10))
		}
		// Read it back: a publish that landed a different length would
		// decode the same on a later boot and still be a failed restore.
		back, rerr := readFile(s, o.path, snapshotReadBody)
		if rerr != nil {
			return rerr
		}
		if !bytes.Equal(back, body) {
			return errors.New("rehydrated " + o.entry + " read " +
				strconv.Itoa(len(back)) + "B, want " + strconv.Itoa(len(body)) + "B byte-exact")
		}
	}

	// 4. REFUSE — one byte off the end is not a bundle any more.
	_, truncatedOK, _ := snapshot.Parse(got[:len(got)-1])
	corrupt := "refused"
	if truncatedOK {
		corrupt = "accepted"
	}

	line := "case file-snapshot path=OUT/snapshot.bundle entries=" +
		strconv.Itoa(len(b.Entries)) +
		" docs=" + strconv.Itoa(snapshotEntryDocs) +
		" bytes=" + strconv.Itoa(len(got)) +
		" settings=" + strconv.Itoa(len(settingsBody)) +
		" session=" + strconv.Itoa(len(sessionBody)) +
		" match=" + yesNo(bytes.Equal(got, raw)) +
		" orphan=" + orphan + " corrupt=" + corrupt
	if rerr := writeReceipt(s, snapshotOk, line); rerr != nil {
		return rerr
	}
	switch {
	case orphan != "none":
		return errors.New("the sacrificial temp " + snapshotBundleTmp + " survived the publish")
	case corrupt != "refused":
		return errors.New("a bundle one byte short parsed clean — a truncated " +
			"container must be refused whole")
	case len(b.Entries) != 4 || b.DocsCount() != snapshotEntryDocs:
		return errors.New("the parsed bundle carried " + strconv.Itoa(len(b.Entries)) +
			" entries and " + strconv.Itoa(b.DocsCount()) + " documents, want 4 and " +
			strconv.Itoa(snapshotEntryDocs))
	}
	return nil
}

// M81b (#1762): the paths and fixtures of the `mime` case. MIME/ holds the
// fixture bytes this case wrote; mime.txt is the receipt the host byte-
// compares, one `sniff <name> <type> bytes=<n>` line per fixture in table
// order. The bytes are deliberately small and fixed so the receipt is
// deterministic (ADR 0031's no-timestamps rule).
const (
	mimeDir     = outDir + "/MIME"
	mimeReceipt = outDir + "/mime.txt"
	mimeOk      = outDir + "/mime.ok"
	mimeReadCap = mime.HeadBytes
)

// mimeFixture is one row: the name the file is given (which is what the
// extension stage sees), the bytes written to it, and the type the sniff must
// return for those bytes.
type mimeFixture struct {
	name string
	body []byte
	want string
}

var mimeFixtures = []mimeFixture{
	// Magic decides: PNG bytes under a .TXT name are an image. This row is
	// the case's whole reason for existing.
	{"README.TXT", []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"), "image"},
	{"PIC.QOI", []byte("qoif\x00\x00\x00\x10\x00\x00\x00\x10\x03\xff\xff\xff"), "image"},
	// The extension decides when the bytes have no magic: text.
	{"NOTES.TXT", []byte("goself mime case: one line of text\n"), "text"},
	// Magic-only types.
	{"SONG.OGG", []byte("OggS\x00\x02\x00\x00\x00\x00\x00\x00"), "audio"},
	{"BUNDLE.ZIP", []byte("PK\x03\x04\x14\x00\x00\x00\x08\x00"), "archive"},
	{"GUEST.ELF", []byte("\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00"), "binary"},
	// No magic, no known extension, control noise: unknown — and unknown has
	// no handler, which is the refusal GOFILES shows the user.
	{"MYSTERY.PS", []byte{0x00, 0x01, 'P', 'S', 0x1a, 0x00}, "unknown"},
}

// caseMime writes each fixture to the share, reads it back through the file
// ABI, sniffs the bytes that came back, and leaves the receipt. A fixture
// whose sniff disagrees with the table FAILS the case naming both values, so
// a wrong answer is never a quiet pass.
func caseMime(s *syscalls) error {
	s.mkdir(outDir)
	s.mkdir(mimeDir)
	var body strings.Builder
	for _, f := range mimeFixtures {
		path := mimeDir + "/" + f.name
		if _, err := writeFile(s, path, f.body); err != nil {
			return err
		}
		got, err := readBack(s, path, mimeReadCap)
		if err != nil {
			return err
		}
		id := mime.Sniff(f.name, got)
		body.WriteString("sniff " + f.name + " " + id.String() +
			" bytes=" + strconv.Itoa(len(got)) + "\n")
		if id.String() != f.want {
			return errors.New("sniff " + f.name + " = " + id.String() +
				", want " + f.want)
		}
	}
	if _, err := writeFile(s, mimeReceipt, []byte(body.String())); err != nil {
		return err
	}
	return writeReceipt(s, mimeOk,
		"case mime fixtures="+strconv.Itoa(len(mimeFixtures))+
			" default-image="+defaultBin(mime.Image)+
			" default-text="+defaultBin(mime.Text))
}

// defaultBin names a type's default handler for the one-line receipt, or
// "none" — the refusal the receipt should be able to show.
func defaultBin(id mime.ID) string {
	if h, ok := mime.Default(id); ok {
		return h.Bin
	}
	return "none"
}

// readBack opens path, reads up to cap bytes and closes it — the same
// open/read/close the file-ABI cases drive, used here so the sniffed bytes
// are the ones the share returned.
func readBack(s *syscalls, path string, cap int) ([]byte, error) {
	h, rc := s.open(path, vi.ModeRead)
	if rc < 0 {
		return nil, errors.New("open " + path + " rc=" + strconv.FormatInt(rc, 10))
	}
	defer s.close(uint32(h))
	buf := make([]byte, cap)
	n, rrc := s.read(uint32(h), buf)
	if rrc < 0 {
		return nil, errors.New("read " + path + " rc=" + strconv.FormatInt(rrc, 10))
	}
	return buf[:n], nil
}
