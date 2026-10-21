package main

// M113e (#2421): the trust tab's joins, verdicts, markers, and the
// failure shapes — a refused slot-89 read must render as unknown, a
// hash pin must compare honestly, and the publisher fingerprint must be
// derived off the replica, never a manifest field.

import (
	"strings"
	"testing"

	"virelai/vi"
)

// fakeTrustShare installs the view's seams over an in-memory share: files
// maps "/host/<path>" bodies, meas maps image name -> measured digest,
// listed controls the streams-dir listing, rows/rc feed slot 89.
func fakeTrustShare(t *testing.T, files map[string][]byte, meas map[string]string,
	rows []vi.GrantRow, rowsErr int64) {
	t.Helper()
	pR, pL, pM, pE, pRows := trustReadFn, trustListFn, trustMeasFn, trustExistsFn, trustRowsFn
	trustReadFn = func(path string, max int) ([]byte, int64) {
		b, ok := files[path]
		if !ok || b == nil {
			return nil, -vi.ErrENOENT
		}
		if len(b) > max {
			b = b[:max]
		}
		return append([]byte(nil), b...), int64(len(b))
	}
	trustListFn = func(canon string) ([]vi.DirItem, error) {
		if canon != trustStreamCanon {
			t.Fatalf("ListDirAt(%q)", canon)
		}
		var items []vi.DirItem
		for p := range files {
			if strings.HasPrefix(p, trustStreamHost) {
				items = append(items, vi.DirItem{Name: p[len(trustStreamHost):]})
			}
		}
		return items, nil
	}
	trustMeasFn = func(name string) string {
		if d, ok := meas[name]; ok {
			return d
		}
		return "-"
	}
	trustExistsFn = func(path string) bool {
		_, ok := files[path]
		return ok
	}
	trustRowsFn = func() ([]vi.GrantRow, int64) { return rows, rowsErr }
	pD := trustDenialsFn
	trustDenialsFn = func(uint64) ([]string, uint64, uint64, int64) { return nil, 0, 0, 0 }
	t.Cleanup(func() {
		trustReadFn, trustListFn, trustMeasFn, trustExistsFn, trustRowsFn, trustDenialsFn =
			pR, pL, pM, pE, pRows, pD
	})
}

// fakeTrustDenials stages the op-2 ring drain for one test: the verbatim
// receipt lines, the evicted-before-oldest gap, or the refusal errno.
func fakeTrustDenials(lines []string, dropped uint64, err int64) {
	trustDenialsFn = func(uint64) ([]string, uint64, uint64, int64) {
		return lines, 0, dropped, err
	}
}

const (
	trustShaGrantd  = "aaaabbbbccccddddeeeeffff000011112222333344445555666677778888"
	trustShaConfine = "9999888877776666555544443333222211110000ffffeeeeddddcccc"
	trustPublisher  = "0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd"
	trustStreamID   = "0199de2d-dc00-7000-8000-00000000f020"
	trustHeadID     = "0199de2d-dc00-7000-8000-00000000f021"
)

// trustFixtureShare is the staged share both posture legs share: a
// hash-bound granted row (GRANTD.BIN), a confined wildcard row
// (CONFINE.BIN), the declared ReleaseCaps and stream replica the
// publisher derivation walks, and the kernel's receipt file.
func trustFixtureShare() map[string][]byte {
	return map[string][]byte{
		"/host/OWNERS.TXT": []byte("#v1\nGOTOP.ELF\t644\t0\t-\nGRANTD.BIN\t644\t0\t-\n"),
		"/host/APPS.TXT":   []byte("# v2\nGOTOP.ELF | Go Top | g | dock=false | v=2 | caps=file,net\n"),
		"/host/STORE.TXT": []byte("#v1\nname=GRANTD.BIN stream=trustrel head=" + trustHeadID +
			" sha256=" + trustShaGrantd +
			" caps=file,net prev_head=- prev_sha256=- prev_caps=- prev_row=-\n"),
		"/host/RCPT.TXT": []byte(
			"RCPT stage=loader sha256=1111111111111111111111111111111111111111111111111111111111111111 verdict=measured\n" +
				"RCPT stage=kernel sha256=2222222222222222222222222222222222222222222222222222222222222222 verdict=measured\n" +
				"RCPT stage=exec sha256=" + trustShaConfine + " verdict=audit:net_denied name=CONFINE.BIN word=net\n"),
		"/host/FLINT/streams/" + trustStreamID + ".json": []byte(
			`{"id":"` + trustStreamID + `","name":"trustrel","head":"` + trustHeadID +
				`","created":1760000000000,"forked_from":null}` + "\n"),
		"/host/FLINT/streams/" + trustStreamID + ".jsonl": []byte(
			`{"id":"` + trustHeadID + `","parent":null,"stream":"` + trustStreamID +
				`","ts":1760000000000,"author":"` + trustPublisher +
				`","message":"release","ops":[],"merged":null,"sig":"00"}` + "\n"),
		// The images exist on the share (the measurement path reaches them).
		"/host/GOTOP.ELF":   []byte("x"),
		"/host/TABWM.BIN":   []byte("x"),
		"/host/GRANTD.BIN":  []byte("x"),
		"/host/CONFINE.BIN": []byte("x"),
	}
}

// TestTrustGrantedAndConfinedPosture is the card's core: a hash-bound
// granted app and a confined app must both render their real posture —
// uid off the owner table, the declared-vs-granted word split, the
// measured digest against the pin, and the derived publisher.
func TestTrustGrantedAndConfinedPosture(t *testing.T) {
	files := trustFixtureShare()
	fakeTrustShare(t, files,
		map[string]string{"GRANTD.BIN": trustShaGrantd, "CONFINE.BIN": trustShaConfine,
			"GOTOP.ELF": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},
		[]vi.GrantRow{
			{Name: "CONFINE.BIN", SHA: "*", Words: "file"},
			{Name: "GRANTD.BIN", SHA: trustShaGrantd, Words: "file,net"},
		}, 0)
	v := NewTrustView()
	v.Refresh([]string{"TABWM.BIN", "GOTOP.ELF", "GRANTD.BIN", "CONFINE.BIN"})
	if len(v.apps) != 4 {
		t.Fatalf("apps = %d", len(v.apps))
	}
	if v.tableErr != 0 {
		t.Fatalf("tableErr = %d", v.tableErr)
	}
	byName := map[string]trustApp{}
	for _, a := range v.apps {
		byName[a.Name] = a
	}
	gr := byName["GRANTD.BIN"]
	if gr.UID != "0" || gr.Declared != "file,net" || gr.Granted != "file,net" ||
		gr.State != "granted" || gr.Verdict != "match" || gr.SHA != trustShaGrantd {
		t.Fatalf("granted posture = %+v", gr)
	}
	if gr.Publisher != trustPublisher || gr.Stream != "trustrel" {
		t.Fatalf("publisher = %q stream %q", gr.Publisher, gr.Stream)
	}
	co := byName["CONFINE.BIN"]
	if co.UID != "1000" || co.Granted != "file" || co.Verdict != "wild" {
		t.Fatalf("confined posture = %+v", co)
	}
	// The denied set is baseline-minus-granted: net must be in it — the
	// word the kernel actually receipts audit:net_denied for.
	if !strings.Contains(","+co.Denied+",", ",net,") || !strings.Contains(","+co.Denied+",", ",debug,") {
		t.Fatalf("denied = %q", co.Denied)
	}
	if co.State != "granted" || co.Declared != "-" {
		t.Fatalf("confined state = %+v", co)
	}
	gt := byName["GOTOP.ELF"]
	// APPS.TXT declares file,net and no grant row consents it: pending is
	// the honest state — a declared ask without a covering row.
	if gt.UID != "0" || gt.Granted != "baseline" || gt.State != "pending" ||
		gt.Declared != "file,net" {
		t.Fatalf("pending posture = %+v", gt)
	}
	se := byName["TABWM.BIN"]
	if se.UID != "1000" || se.State != "baseline" || se.Granted != "baseline" {
		t.Fatalf("unstaged app = %+v", se)
	}
	// Markers: the summary and both apps' posture lines.
	if !strings.Contains(v.Marker(), "top: trust n=4 table=ok rcpts=3") {
		t.Fatalf("marker = %q", v.Marker())
	}
	found := map[string]bool{}
	for i := 0; i < 8; i++ {
		m, ok := v.AppMarker(i)
		if !ok {
			break
		}
		if strings.Contains(m, "name=CONFINE.BIN") {
			found["confine"] = true
			if !strings.Contains(m, "granted=file ") || !strings.Contains(m, "uid=1000") {
				t.Fatalf("confine marker = %q", m)
			}
		}
		if strings.Contains(m, "name=GRANTD.BIN") {
			found["grantd"] = true
			if !strings.Contains(m, "declared=file,net") || !strings.Contains(m, "granted=file,net") {
				t.Fatalf("grantd marker = %q", m)
			}
		}
	}
	if !found["confine"] || !found["grantd"] {
		t.Fatalf("app markers missing: %v", found)
	}
	// The sha marker carries the pin comparison for the hash-bound app.
	found = map[string]bool{}
	for i := 0; i < 8; i++ {
		m, ok := v.ShaMarker(i)
		if !ok {
			break
		}
		if strings.Contains(m, "name=GRANTD.BIN") {
			found["sha"] = true
			if !strings.Contains(m, "verdict=match") || !strings.Contains(m, "measured="+trustShaGrantd) {
				t.Fatalf("sha marker = %q", m)
			}
		}
	}
	if !found["sha"] {
		t.Fatal("GRANTD.BIN sha marker missing")
	}
	// The receipt tail renders RCPT.TXT verbatim, exec lines included.
	if len(v.rcpts) != 3 {
		t.Fatalf("rcpts = %d", len(v.rcpts))
	}
	rc, ok := v.RcptMarker(2)
	if !ok || !strings.Contains(rc, "audit:net_denied") || !strings.Contains(rc, "name=CONFINE.BIN") {
		t.Fatalf("rcpt marker = %q ok=%v", rc, ok)
	}
	if n := len(v.rcptsFor("CONFINE.BIN")); n != 1 {
		t.Fatalf("per-app rcpts = %d", n)
	}
}

// TestTrustUnreadableTable pins the honest failure: slot 89 refuses a
// caller outside the seat/admin gate, and the tab must say so — "?"
// marks, not a silent baseline.
func TestTrustUnreadableTable(t *testing.T) {
	fakeTrustShare(t, trustFixtureShare(), map[string]string{},
		nil, -vi.ErrEACCES)
	v := NewTrustView()
	v.Refresh([]string{"GRANTD.BIN"})
	if v.tableErr == 0 {
		t.Fatal("tableErr must carry the refusal")
	}
	a := v.apps[0]
	if a.Granted != "?" || a.State != "unreadable" {
		t.Fatalf("unreadable posture = %+v", a)
	}
	if !strings.Contains(v.Marker(), "table=err=EACCES") {
		t.Fatalf("marker = %q", v.Marker())
	}
	m, _ := v.AppMarker(0)
	if !strings.Contains(m, "granted=?") {
		t.Fatalf("app marker = %q", m)
	}
}

// TestTrustStalePin: a hash-bound row whose pin no longer matches the
// measured bytes is drift evidence — the state reads stale, never match.
func TestTrustStalePin(t *testing.T) {
	fakeTrustShare(t, trustFixtureShare(),
		map[string]string{"GRANTD.BIN": trustShaConfine}, // file drifted
		[]vi.GrantRow{{Name: "GRANTD.BIN", SHA: trustShaGrantd, Words: "file,net"}}, 0)
	v := NewTrustView()
	v.Refresh([]string{"GRANTD.BIN"})
	a := v.apps[0]
	if a.Verdict != "stale" || a.State != "stale" {
		t.Fatalf("stale posture = %+v", a)
	}
}

// TestTrustPendingAndWidening covers the declared-but-ungranted and
// ask-exceeds-consent states (the GOSET vocabulary this tab shares).
func TestTrustPendingAndWidening(t *testing.T) {
	fakeTrustShare(t, trustFixtureShare(), map[string]string{},
		[]vi.GrantRow{{Name: "GOTOP.ELF", SHA: "*", Words: "file"}}, 0)
	v := NewTrustView()
	v.Refresh([]string{"GRANTD.BIN", "GOTOP.ELF"})
	byName := map[string]trustApp{}
	for _, a := range v.apps {
		byName[a.Name] = a
	}
	// GRANTD declares file,net on STORE.TXT but carries no row -> pending.
	if byName["GRANTD.BIN"].State != "pending" {
		t.Fatalf("pending = %+v", byName["GRANTD.BIN"])
	}
	// GOTOP declares file,net on APPS.TXT but the row grants file only.
	if byName["GOTOP.ELF"].State != "widening" {
		t.Fatalf("widening = %+v", byName["GOTOP.ELF"])
	}
}

// TestTrustUntrackedPublisher: an app with no store entry shows no
// publisher — derivation is replica-driven, never guessed.
func TestTrustUntrackedPublisher(t *testing.T) {
	fakeTrustShare(t, trustFixtureShare(), map[string]string{}, nil, 0)
	v := NewTrustView()
	v.Refresh([]string{"CONFINE.BIN"})
	if v.apps[0].Publisher != "-" || v.apps[0].Stream != "" {
		t.Fatalf("untracked pub = %+v", v.apps[0])
	}
}

// TestTrustMissingSurfaces: nothing staged — the tab degrades to baseline
// postures with no publishers and no receipts, not a parse of garbage.
func TestTrustMissingSurfaces(t *testing.T) {
	fakeTrustShare(t, map[string][]byte{"/host/COUNTER.BIN": []byte("x")}, nil, nil, 0)
	v := NewTrustView()
	v.Refresh([]string{"COUNTER.BIN"})
	if len(v.apps) != 1 || v.apps[0].State != "baseline" || v.apps[0].UID != "1000" {
		t.Fatalf("empty posture = %+v", v.apps)
	}
	if len(v.rcpts) != 0 {
		t.Fatalf("rcpts = %d", len(v.rcpts))
	}
}

// TestTrustNotSampled: before the first refresh the tab must not paint
// an empty set as if it were real.
func TestTrustNotSampled(t *testing.T) {
	v := NewTrustView()
	lines := v.Lines()
	if len(lines) != 1 || !strings.Contains(lines[0], "not sampled") {
		t.Fatalf("lines = %v", lines)
	}
}

// TestTrustTruncatedNameJoin: the proc registry truncates names at 16;
// a longer share-path row key still joins on the kernel's prefix rule.
func TestTrustTruncatedNameJoin(t *testing.T) {
	if !procKey("APPS/VERYLONGNAME.ELF", "APPS/VERYLONGNAM") {
		t.Fatal("16-char truncated join refused")
	}
	if procKey("OTHER.ELF", "APPS/VERYLONGNAM") {
		t.Fatal("foreign name joined")
	}
}

// TestTrustReceiptGrammar pins the RCPT line decode — the full D4 fields
// and the refusal of half-lines.
func TestTrustReceiptGrammar(t *testing.T) {
	rcpts := parseReceipts([]byte(
		"RCPT stage=exec sha256=ab verdict=refused:grant_stale name=TCP.BIN\n" +
			"RCPT stage=exec sha256=cd verdict=audit:debug_denied name=X.ELF word=debug\n" +
			"not a receipt\n" +
			"RCPT stage=exec\n"))
	if len(rcpts) != 2 {
		t.Fatalf("rcpts = %d", len(rcpts))
	}
	if rcpts[0].Verdict != "refused:grant_stale" || rcpts[0].Name != "TCP.BIN" {
		t.Fatalf("rcpt0 = %+v", rcpts[0])
	}
	if rcpts[1].Word != "debug" {
		t.Fatalf("rcpt1 = %+v", rcpts[1])
	}
}

// TestTrustObservedDenials is the M161a (#2982) core: the ring's drained
// receipts render per app as (verdict, word, count) beside the computed
// would_deny set, and the serial markers pair each rendered entry with
// the kernel's own receipt — a receipt for a process no longer listed
// still earns a marker, never silently dropped.
func TestTrustObservedDenials(t *testing.T) {
	fakeTrustShare(t, trustFixtureShare(), map[string]string{}, nil, 0)
	fakeTrustDenials([]string{
		"RCPT stage=exec sha256=99 verdict=audit:net_denied name=CONFINE.BIN word=net",
		"RCPT stage=exec sha256=99 verdict=audit:net_denied name=CONFINE.BIN word=net",
		"RCPT stage=exec sha256=aa verdict=refused:debug_denied name=GRANTD.BIN word=debug",
		"RCPT stage=exec sha256=bb verdict=audit:fs_path_denied name=GONE.BIN word=file",
		"RCPT stage=exec sha256=cc verdict=measured name=CONFINE.BIN", // not a denial — skipped
	}, 7, 0)
	v := NewTrustView()
	v.Refresh([]string{"CONFINE.BIN", "GRANTD.BIN"})
	byName := map[string]trustApp{}
	for _, a := range v.apps {
		byName[a.Name] = a
	}
	if byName["CONFINE.BIN"].Denials != "audit:net x2" {
		t.Fatalf("confine denials = %q", byName["CONFINE.BIN"].Denials)
	}
	if byName["GRANTD.BIN"].Denials != "refused:debug x1" {
		t.Fatalf("grantd denials = %q", byName["GRANTD.BIN"].Denials)
	}
	if !strings.Contains(v.DenialsMarker(), "top: trust denials n=4 dropped=7") {
		t.Fatalf("denials marker = %q", v.DenialsMarker())
	}
	// Four drained denials -> three groups (CONFINE.BIN's pair counts
	// once); GONE.BIN is unlisted yet still marked.
	var marks []string
	for i := 0; ; i++ {
		m, ok := v.DenialMarker(i)
		if !ok {
			break
		}
		marks = append(marks, m)
	}
	if len(marks) != 3 {
		t.Fatalf("denial markers %v", marks)
	}
	if marks[0] != "top: trust denial app=CONFINE.BIN verdict=audit word=net" ||
		marks[1] != "top: trust denial app=GRANTD.BIN verdict=refused word=debug" ||
		marks[2] != "top: trust denial app=GONE.BIN verdict=audit word=fs_path" {
		t.Fatalf("denial markers %v", marks)
	}
}

// TestTrustDenialsUnreadable pins the honesty rule for the ring: a
// refused op-2 read renders denials=? per app and an err= marker — never
// an empty list dressed as "no denials".
func TestTrustDenialsUnreadable(t *testing.T) {
	fakeTrustShare(t, trustFixtureShare(), map[string]string{}, nil, 0)
	fakeTrustDenials(nil, 0, -vi.ErrEACCES)
	v := NewTrustView()
	v.Refresh([]string{"CONFINE.BIN"})
	if v.apps[0].Denials != "?" {
		t.Fatalf("denials = %q, want ?", v.apps[0].Denials)
	}
	if !strings.Contains(v.DenialsMarker(), "top: trust denials err=EACCES") {
		t.Fatalf("denials marker = %q", v.DenialsMarker())
	}
	if _, ok := v.DenialMarker(0); ok {
		t.Fatal("denial marker served on a refused read")
	}
	lines := v.Lines()
	found := false
	for _, l := range lines {
		if strings.Contains(l, "denials=?") {
			found = true
		}
	}
	if !found {
		t.Fatalf("no denials=? line in %v", lines)
	}
}
