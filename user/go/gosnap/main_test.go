package main

import (
	"errors"
	"strings"
	"testing"

	"virelai/vi"
)

// The fakes: each seam is a var so the whole verb matrix runs on the
// host — same arrangement gotabwm's snapshot tests use.
type fakeEnv struct {
	logs     []string
	items    []vi.DirItem
	listErr  error
	exists   map[string]bool
	deleted  []string
	deleteRC int64
	// ctl records every issued session and answers with the queued
	// verdicts (0 = ok, >0 = code bytes written into the buf the kernel
	// would fill, <0 = errno like a host build's -ENOSYS).
	ctlCalls []string
	ctlRC    int64
	ctlCode  string
}

func (f *fakeEnv) install(t *testing.T) {
	t.Helper()
	oldCtl, oldList, oldEx, oldDel, oldLog := ctl, listDir, fileExists, fileDelete, logLine
	ctl = func(verb, name string, code []byte) int64 {
		f.ctlCalls = append(f.ctlCalls, verb+"/"+name)
		if f.ctlRC > 0 {
			n := int64(len(f.ctlCode))
			if n > int64(len(code)) {
				n = int64(len(code))
			}
			copy(code, f.ctlCode)
			return n
		}
		return f.ctlRC
	}
	listDir = func(string) ([]vi.DirItem, error) { return f.items, f.listErr }
	fileExists = func(p string) bool { return f.exists[p] }
	fileDelete = func(p string) int64 {
		f.deleted = append(f.deleted, p)
		return f.deleteRC
	}
	logLine = func(s string) { f.logs = append(f.logs, s) }
	t.Cleanup(func() {
		ctl, listDir, fileExists, fileDelete, logLine = oldCtl, oldList, oldEx, oldDel, oldLog
	})
}

func (f *fakeEnv) has(sub string) bool {
	for _, l := range f.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

func dirItem(name string, size uint64) vi.DirItem {
	var it vi.DirItem
	it.Name = name
	it.Size = size
	return it
}

func TestLsEmptyWhenDirMissing(t *testing.T) {
	f := &fakeEnv{listErr: errors.New("ENOENT")}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "ls"}); rc != 0 {
		t.Fatalf("ls rc=%d", rc)
	}
	if !f.has("gosnap: ls n=0") {
		t.Fatalf("missing empty marker: %v", f.logs)
	}
}

func TestLsListsSnapshotsSortedAndSkipsStrays(t *testing.T) {
	f := &fakeEnv{items: []vi.DirItem{
		dirItem("SECOND.vzsave", 64),
		dirItem("FIRST.vzsave", 32),
		dirItem("FIRST.vzsave.part", 8), // an in-flight save is not a snapshot
		dirItem("README.TXT", 4),
	}}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "ls"}); rc != 0 {
		t.Fatalf("ls rc=%d", rc)
	}
	want := []string{
		"gosnap: snap name=FIRST bytes=32",
		"gosnap: snap name=SECOND bytes=64",
		"gosnap: ls n=2",
	}
	if len(f.logs) != len(want) {
		t.Fatalf("logs = %v, want %v", f.logs, want)
	}
	for i := range want {
		if f.logs[i] != want[i] {
			t.Fatalf("line %d = %q, want %q", i, f.logs[i], want[i])
		}
	}
}

func TestSaveRelaysTheCtlVerdict(t *testing.T) {
	f := &fakeEnv{}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "save", "BASE"}); rc != 0 {
		t.Fatalf("save rc=%d", rc)
	}
	if len(f.ctlCalls) != 1 || f.ctlCalls[0] != "snapshot/BASE" {
		t.Fatalf("ctl calls = %v", f.ctlCalls)
	}
	if !f.has("gosnap: save BASE ok") {
		t.Fatalf("missing ok marker: %v", f.logs)
	}
}

func TestSaveRelaysARefusalByName(t *testing.T) {
	f := &fakeEnv{ctlCode: "exists"}
	f.ctlRC = 1 // >0: code bytes returned
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "save", "BASE"}); rc != exitRefused {
		t.Fatalf("save rc=%d", rc)
	}
	if !f.has("gosnap: save BASE refused exists") {
		t.Fatalf("missing refused marker: %v", f.logs)
	}
}

func TestSaveRejectsABadNameLocally(t *testing.T) {
	f := &fakeEnv{}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "save", ".."}); rc != exitRefused {
		t.Fatalf("save rc=%d", rc)
	}
	if len(f.ctlCalls) != 0 {
		t.Fatalf("a bad name must never reach the wire: %v", f.ctlCalls)
	}
	if !f.has("gosnap: save .. refused name_rejected") {
		t.Fatalf("missing name_rejected: %v", f.logs)
	}
}

func TestRmWithoutConfirmIsTheConsentAsk(t *testing.T) {
	f := &fakeEnv{exists: map[string]bool{"/host/SNAPSHOTS/BASE.vzsave": true}}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "rm", "BASE"}); rc != exitRefused {
		t.Fatalf("rm rc=%d", rc)
	}
	if len(f.deleted) != 0 {
		t.Fatalf("rm deleted without consent: %v", f.deleted)
	}
	if !f.has("gosnap: consent rm BASE") || !f.has("gosnap: rm BASE refused consent_required") {
		t.Fatalf("missing consent markers: %v", f.logs)
	}
}

func TestRmWithConfirmDeletesTheShareFile(t *testing.T) {
	f := &fakeEnv{exists: map[string]bool{"/host/SNAPSHOTS/BASE.vzsave": true}}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "rm", "BASE", "confirm"}); rc != 0 {
		t.Fatalf("rm rc=%d", rc)
	}
	if len(f.deleted) != 1 || f.deleted[0] != "/host/SNAPSHOTS/BASE.vzsave" {
		t.Fatalf("deleted = %v", f.deleted)
	}
	if !f.has("gosnap: rm BASE ok") {
		t.Fatalf("missing ok marker: %v", f.logs)
	}
}

func TestRmMissingIsNotFound(t *testing.T) {
	f := &fakeEnv{exists: map[string]bool{}}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "rm", "GONE", "confirm"}); rc != exitRefused {
		t.Fatalf("rm rc=%d", rc)
	}
	if len(f.deleted) != 0 {
		t.Fatalf("rm issued a delete for an absent file: %v", f.deleted)
	}
	if !f.has("gosnap: rm GONE refused not_found") {
		t.Fatalf("missing not_found: %v", f.logs)
	}
}

func TestRmCannotEscapeTheSnapshotsDir(t *testing.T) {
	f := &fakeEnv{exists: map[string]bool{"/host/SNAPSHOTS/../SETTINGS.TXT.vzsave": true}}
	f.install(t)
	// The name grammar refuses '/', so a traversal attempt never becomes
	// a path — the verb is refused before any file op.
	if rc := run([]string{"GOSNAP.ELF", "rm", "../SETTINGS.TXT", "confirm"}); rc != exitRefused {
		t.Fatalf("rm traversal rc=%d", rc)
	}
	if len(f.deleted) != 0 {
		t.Fatalf("rm deleted through a traversal name: %v", f.deleted)
	}
}

func TestRestoreWithoutConfirmWritesNothing(t *testing.T) {
	f := &fakeEnv{}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "restore", "BASE"}); rc != exitRefused {
		t.Fatalf("restore rc=%d", rc)
	}
	if len(f.ctlCalls) != 0 {
		t.Fatalf("restore staged without consent: %v", f.ctlCalls)
	}
	if !f.has("gosnap: consent restore BASE") || !f.has("gosnap: restore BASE refused consent_required") {
		t.Fatalf("missing consent markers: %v", f.logs)
	}
}

func TestRestoreWithConfirmStagesThroughCtl(t *testing.T) {
	f := &fakeEnv{}
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "restore", "BASE", "confirm"}); rc != 0 {
		t.Fatalf("restore rc=%d", rc)
	}
	if len(f.ctlCalls) != 1 || f.ctlCalls[0] != "restore/BASE" {
		t.Fatalf("ctl calls = %v", f.ctlCalls)
	}
	if !f.has("gosnap: restore BASE staged") {
		t.Fatalf("missing staged marker: %v", f.logs)
	}
}

func TestRestoreRelaysNotFound(t *testing.T) {
	f := &fakeEnv{ctlCode: "not_found"}
	f.ctlRC = 1
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "restore", "GONE", "confirm"}); rc != exitRefused {
		t.Fatalf("restore rc=%d", rc)
	}
	if !f.has("gosnap: restore GONE refused not_found") {
		t.Fatalf("missing not_found: %v", f.logs)
	}
}

func TestCtlNegativeReturnIsAnErrnoName(t *testing.T) {
	f := &fakeEnv{ctlRC: -4} // -ENOSYS, the host-build seam answer
	f.install(t)
	if rc := run([]string{"GOSNAP.ELF", "save", "BASE"}); rc != exitRefused {
		t.Fatalf("save rc=%d", rc)
	}
	if !f.has("gosnap: save BASE refused ENOSYS") {
		t.Fatalf("missing errno refusal: %v", f.logs)
	}
}

func TestUsageAndNoArgs(t *testing.T) {
	f := &fakeEnv{}
	f.install(t)
	// M120d: bare is the windowed face — on the host the win_open seam
	// is -ENOSYS, so the run refuses with the open error and still
	// prints the verbs (a serial-only caller learns the command line).
	if rc := run([]string{"GOSNAP.ELF"}); rc != exitRefused {
		t.Fatalf("bare rc=%d", rc)
	}
	if !f.has("gosnap: error open -1") {
		t.Fatalf("missing open refusal: %v", f.logs)
	}
	if rc := run([]string{"GOSNAP.ELF", "frobnicate"}); rc != exitUsage {
		t.Fatalf("bad verb rc=%d", rc)
	}
	if rc := run([]string{"GOSNAP.ELF", "ls", "extra"}); rc != exitUsage {
		t.Fatalf("ls extra rc=%d", rc)
	}
}
