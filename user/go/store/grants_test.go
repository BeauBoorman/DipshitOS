package store

import (
	"fmt"
	"strings"
	"testing"

	"virelai/sshlib"
	"virelai/vi"
)

// M113d (#2420, ADR 0054 Part II D10): ReleaseCaps -> proposed row ->
// consent/keep/widening legs. The grant table itself lives behind
// grantRowsFn/grantWriteFn — stubbed here like execFn.

// releaseGoCaps renders a manifest carrying ReleaseCaps beside the four
// required consts.
func releaseGoCaps(name, version string, elf []byte, row, caps string) []byte {
	sum := sshlib.SHA256Sum(elf)
	return []byte(fmt.Sprintf(`package release

const ReleaseName = %q
const ReleaseVersion = %q
const ReleaseELFSHA256 = %q
const ReleaseManifestRow = %q
const ReleaseCaps = %q
`, name, version, sshlib.EncodeHex(sum[:]), row, caps))
}

// seedGrantStubs installs the slot-89 seams for one test: rows is the
// table the admin read would hand back; writes records each op-1 line.
func seedGrantStubs(t *testing.T, rows []vi.GrantRow, rc int64) (writes *[]string, restore func()) {
	t.Helper()
	var w []string
	prevRows, prevWrite := grantRowsFn, grantWriteFn
	grantRowsFn = func() ([]vi.GrantRow, int64) { return rows, rc }
	grantWriteFn = func(line string) int64 { w = append(w, line); return 0 }
	return &w, func() { grantRowsFn, grantWriteFn = prevRows, prevWrite }
}

// TestParseReleaseCaps pins the ReleaseCaps grammar: canonical ordering,
// the named refusals, and absent-stays-nil.
func TestParseReleaseCaps(t *testing.T) {
	src := func(caps string) []byte {
		return releaseGoCaps("GOHELLO", "1.0.0", testELF,
			"GOHELLO.ELF | Go Hello | g | dock=false", caps)
	}
	r, err := parseRelease(src("file,net"))
	if err != nil {
		t.Fatalf("file,net refused: %v", err)
	}
	if strings.Join(r.Caps, ",") != "file,net" {
		t.Fatalf("caps %v", r.Caps)
	}
	// Canonical order is vocabulary order, not declaration order.
	r, err = parseRelease(src("net,file"))
	if err != nil || strings.Join(r.Caps, ",") != "file,net" {
		t.Fatalf("canonical %v err %v", r.Caps, err)
	}
	for caps, want := range map[string]string{
		"":                          "caps_invalid", // present but empty
		"file,,net":                 "caps_invalid", // empty element
		"file,file":                 "caps_invalid", // duplicate
		"root":                      "caps_unknown", // outside the vocabulary
		"NET":                       "caps_unknown", // words are lowercase
		"file,net,x":                "caps_unknown",
		"file, net":                 "caps_unknown", // no whitespace inside words
		strings.Repeat("file,", 20): "caps_invalid", // oversize + dup
	} {
		_, err := parseRelease(src(caps))
		if err == nil {
			t.Fatalf("ReleaseCaps %q accepted", caps)
		}
		refuseCode(t, err, want)
	}
	// Absent const is valid and stays nil.
	base := releaseGo("GOHELLO", "1.0.0", testELF, "GOHELLO.ELF | Go Hello | g | dock=false")
	r, err = parseRelease(base)
	if err != nil || r.Caps != nil {
		t.Fatalf("absent caps: %v %v", r.Caps, err)
	}
}

// TestInstallProposesGrant: a caps-bearing release installs and surfaces
// the ask — propose marker after the ok line, caps recorded in
// STORE.TXT, no row written (consent is a separate gesture).
func TestInstallProposesGrant(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	writes, restoreGrants := seedGrantStubs(t, nil, 0)
	defer restoreGrants()

	src := releaseGoCaps("GOHELLO", "1.0.0", testELF,
		"GOHELLO.ELF | Go Hello | g | dock=false", "file,net")
	streamWithRelease(t, fs, "rel2", src)
	fs.dirs["/host/DROP/rel2"] = true
	fs.files["/host/DROP/rel2/release.go"] = src
	fs.files["/host/DROP/rel2/GOHELLO.ELF"] = testELF

	if rc := Install(fs, DefaultStoreRoot, "rel2", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: install ok GOHELLO.ELF version=1.0.0") {
		t.Fatalf("missing ok: %v", *lines)
	}
	if !strings.Contains(joined, "store: grant propose GOHELLO.ELF words=file,net") {
		t.Fatalf("missing propose: %v", *lines)
	}
	if len(*writes) != 0 {
		t.Fatalf("install wrote a grant row: %v", *writes)
	}
	e := stateEntry(t, fs, "GOHELLO.ELF")
	if e.Caps != "file,net" {
		t.Fatalf("state caps %q", e.Caps)
	}
}

// TestInstallNoCapsNoPropose: a release without ReleaseCaps installs
// silently — no ask, no state caps.
func TestInstallNoCapsNoPropose(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	_, restoreGrants := seedGrantStubs(t, nil, 0)
	defer restoreGrants()

	if rc := Install(fs, DefaultStoreRoot, "rel", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d", rc)
	}
	if strings.Contains(strings.Join(*lines, "\n"), "store: grant") {
		t.Fatalf("grant noise on a caps-free release: %v", *lines)
	}
	if e := stateEntry(t, fs, "GOHELLO.ELF"); e.Caps != "" {
		t.Fatalf("caps recorded for a caps-free release: %q", e.Caps)
	}
}

// TestUpdateKeepsGrant: row (bin, sha1, file,net) exists; the v2 release
// declares a subset (file). The keep re-pins the row to the new image
// with the consented words verbatim — one write, no fresh ask.
func TestUpdateKeepsGrant(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	row := vi.GrantRow{Name: "GOHELLO.ELF", SHA: shaHex(testELF), Words: "file,net"}
	writes, restoreGrants := seedGrantStubs(t, []vi.GrantRow{row}, 0)
	defer restoreGrants()

	src := releaseGoCaps("GOHELLO", "1.0.0", testELF,
		"GOHELLO.ELF | Go Hello | g | dock=false", "file,net")
	streamWithRelease(t, fs, "rel2", src)
	fs.dirs["/host/DROP/rel2"] = true
	fs.files["/host/DROP/rel2/release.go"] = src
	fs.files["/host/DROP/rel2/GOHELLO.ELF"] = testELF
	if rc := Install(fs, DefaultStoreRoot, "rel2", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d lines=%v", rc, *lines)
	}
	*writes = nil

	// v2 declares a strict subset of the consented words.
	srcV2 := releaseGoCaps("GOHELLO", "2.0.0", testELFv2, rowV2, "file")
	streamAdvanceRelease(t, fs, srcV2, testChangeV1, testChangeV2)
	fs.files["/host/DROP/rel2/release.go"] = srcV2
	fs.files["/host/DROP/rel2/GOHELLO.ELF"] = testELFv2

	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("update rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: grant keep GOHELLO.ELF words=file,net") {
		t.Fatalf("missing keep: %v", *lines)
	}
	if strings.Contains(joined, "store: grant propose") {
		t.Fatalf("non-widening update re-asked: %v", *lines)
	}
	want := "GOHELLO.ELF\t" + shaHex(testELFv2) + "\tfile,net"
	if len(*writes) != 1 || (*writes)[0] != want {
		t.Fatalf("writes %v, want [%q]", *writes, want)
	}
	e := stateEntry(t, fs, "GOHELLO.ELF")
	if e.Caps != "file" || e.PrevCaps != "file,net" {
		t.Fatalf("state caps %q prev %q", e.Caps, e.PrevCaps)
	}
}

// TestUpdateWideningReasks: the v2 ask is a strict superset of the
// consented words — the row is left stale (unconsented image), the ask
// is re-proposed, and nothing is written.
func TestUpdateWideningReasks(t *testing.T) {
	fs, _, lines, restore := seedConsumer(t)
	defer restore()
	row := vi.GrantRow{Name: "GOHELLO.ELF", SHA: shaHex(testELF), Words: "file,net"}
	writes, restoreGrants := seedGrantStubs(t, []vi.GrantRow{row}, 0)
	defer restoreGrants()

	src := releaseGoCaps("GOHELLO", "1.0.0", testELF,
		"GOHELLO.ELF | Go Hello | g | dock=false", "file,net")
	streamWithRelease(t, fs, "rel2", src)
	fs.dirs["/host/DROP/rel2"] = true
	fs.files["/host/DROP/rel2/release.go"] = src
	fs.files["/host/DROP/rel2/GOHELLO.ELF"] = testELF
	if rc := Install(fs, DefaultStoreRoot, "rel2", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("install rc=%d lines=%v", rc, *lines)
	}
	*writes = nil

	srcV2 := releaseGoCaps("GOHELLO", "2.0.0", testELFv2, rowV2, "file,net,debug")
	streamAdvanceRelease(t, fs, srcV2, testChangeV1, testChangeV2)
	fs.files["/host/DROP/rel2/release.go"] = srcV2
	fs.files["/host/DROP/rel2/GOHELLO.ELF"] = testELFv2

	if rc := Update(fs, DefaultStoreRoot, "gohello", "10.0.0.2:4748", "/host/DROP"); rc != 0 {
		t.Fatalf("update rc=%d lines=%v", rc, *lines)
	}
	joined := strings.Join(*lines, "\n")
	if !strings.Contains(joined, "store: update ok GOHELLO.ELF version=2.0.0") {
		t.Fatalf("update itself failed: %v", *lines)
	}
	if !strings.Contains(joined, "store: grant propose GOHELLO.ELF words=file,debug,net") {
		t.Fatalf("widening update did not re-ask: %v", *lines)
	}
	if len(*writes) != 0 {
		t.Fatalf("widening update wrote without consent: %v", *writes)
	}
	if e := stateEntry(t, fs, "GOHELLO.ELF"); e.Caps != "file,debug,net" {
		t.Fatalf("state caps %q", e.Caps)
	}
}

// TestGrantSyncWithoutAdmin: an unprivileged STORE reads -EACCES off the
// slot — it cannot even see the table, so a declared ask is proposed and
// a caps-free release stays silent.
func TestGrantSyncWithoutAdmin(t *testing.T) {
	_, restoreGrants := seedGrantStubs(t, nil, -vi.ErrEACCES)
	defer restoreGrants()
	lines, restore := collectConsole()
	defer restore()

	grantSync("GOHELLO.ELF", "ab", []string{"file", "net"})
	if got := strings.Join(*lines, "\n"); !strings.Contains(got, "store: grant propose GOHELLO.ELF words=file,net") {
		t.Fatalf("no propose under EACCES: %v", *lines)
	}
	*lines = nil
	grantSync("GOHELLO.ELF", "ab", nil)
	if len(*lines) != 0 {
		t.Fatalf("caps-free release spoke: %v", *lines)
	}
}

// TestGrantSyncKeepWriteFailure: the admin write itself refusing leaves
// the stale row standing and names the rc — never a silent grant.
func TestGrantSyncKeepWriteFailure(t *testing.T) {
	row := vi.GrantRow{Name: "GOHELLO.ELF", SHA: "old", Words: "file"}
	prevRows, prevWrite := grantRowsFn, grantWriteFn
	grantRowsFn = func() ([]vi.GrantRow, int64) { return []vi.GrantRow{row}, 0 }
	grantWriteFn = func(line string) int64 { return -vi.ErrEIO }
	defer func() { grantRowsFn, grantWriteFn = prevRows, prevWrite }()
	lines, restore := collectConsole()
	defer restore()

	grantSync("GOHELLO.ELF", "new", []string{"file"})
	got := strings.Join(*lines, "\n")
	if !strings.Contains(got, "store: grant keep failed GOHELLO.ELF rc=") {
		t.Fatalf("failed keep not named: %v", *lines)
	}
}

// TestStateCapsFields: the caps=/prev_caps= grammar — round-trip, '-'
// empties, and refusal on non-vocabulary words.
func TestStateCapsFields(t *testing.T) {
	fs := newMemFS()
	want := map[string]*storeEntry{
		"GOHELLO.ELF": {Name: "GOHELLO.ELF", Stream: "rel", Head: "h1",
			SHA256: shaHex(testELF), Caps: "file,net",
			PrevHead: "h0", PrevSHA: shaHex(testELFv2), PrevCaps: "file", PrevRow: "row"},
	}
	if err := fs.WriteFileSafe(statePath, renderState(want)); err != nil {
		t.Fatal(err)
	}
	got, err := loadState(fs)
	if err != nil {
		t.Fatalf("loadState: %v", err)
	}
	e := got["GOHELLO.ELF"]
	if e.Caps != "file,net" || e.PrevCaps != "file" {
		t.Fatalf("caps round-trip %+v", e)
	}
	for _, bad := range []string{
		"name=A.ELF stream=s head=h sha256=" + shaHex(testELF) + " caps=root prev_head=- prev_sha256=- prev_caps=- prev_row=-\n",
		"name=A.ELF stream=s head=h sha256=" + shaHex(testELF) + " caps= prev_head=- prev_sha256=- prev_caps=- prev_row=-\n",
		// A caps history with no rollback target is nonsense.
		"name=A.ELF stream=s head=h sha256=" + shaHex(testELF) + " caps=- prev_head=- prev_sha256=- prev_caps=file prev_row=-\n",
	} {
		fs.files[statePath] = []byte(bad)
		if _, err := loadState(fs); err == nil {
			t.Fatalf("accepted corrupt state: %q", bad)
		}
	}
	// A rollback target whose prior declaration was not recorded is
	// legal: prev_caps=- with the three core fields set.
	fs.files[statePath] = []byte("name=A.ELF stream=s head=h sha256=" + shaHex(testELF) +
		" caps=- prev_head=h0 prev_sha256=" + shaHex(testELFv2) + " prev_caps=- prev_row=r\n")
	got2, err := loadState(fs)
	if err != nil || got2["A.ELF"].PrevCaps != "" || got2["A.ELF"].PrevHead != "h0" {
		t.Fatalf("prev_caps=- target: %v %+v", err, got2["A.ELF"])
	}
}

// TestInstalledStateExport: the fields the grants pane reads out of
// STORE.TXT — name, sha256, caps — render parseably from every entry.
func TestInstalledStateExport(t *testing.T) {
	fs := newMemFS()
	want := map[string]*storeEntry{
		"B.ELF": {Name: "B.ELF", Stream: "s", Head: "h", SHA256: shaHex(testELFv2), Caps: "net"},
		"A.ELF": {Name: "A.ELF", Stream: "s", Head: "h", SHA256: shaHex(testELF)},
	}
	if err := fs.WriteFileSafe(statePath, renderState(want)); err != nil {
		t.Fatal(err)
	}
	got, err := loadState(fs)
	if err != nil || len(got) != 2 {
		t.Fatalf("loadState: %v %v", got, err)
	}
	if got["A.ELF"].Caps != "" || got["B.ELF"].Caps != "net" ||
		got["A.ELF"].SHA256 != shaHex(testELF) {
		t.Fatalf("fields: %+v", got)
	}
}
