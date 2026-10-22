package main

// ADR 0052 D4 / M109c: the agent-activity tab's decode, MAC verdicts,
// ordering, and marker text against a staged lane.

import (
	"strings"
	"testing"

	"virelai/shlib"
	"virelai/vi"
)

// agentTestKey is the lane key the fixtures are signed with.
var agentTestKey = []byte("a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5")

// rcptBody renders a staged receipt file: line 1 verbatim plus the MAC the
// writer would have emitted under key (or a forged one when forge=true).
func rcptBody(key []byte, line1 string, forge bool) []byte {
	mac := shlib.HMACSHA256(key, []byte(line1))
	digits := "0123456789abcdef"
	var b [64]byte
	for i := 0; i < 32; i++ {
		b[2*i] = digits[mac[i]>>4]
		b[2*i+1] = digits[mac[i]&0xf]
	}
	if forge {
		b[0] = '0'
		if mac[0]>>4 == 0 {
			b[0] = '1'
		}
	}
	return []byte(line1 + "\n" + string(b[:]) + "\n")
}

// fakeAgentLane installs the view's seams over an in-memory share: files
// maps "/host/AGENT/AUDIT/<name>" to bodies; listed=false makes the
// directory read fail like a missing lane.
func fakeAgentLane(t *testing.T, files map[string][]byte, key []byte, listed bool) {
	t.Helper()
	prevL, prevR, prevK, prevD := agentListFn, agentReadFn, agentKeyFn, agentDenialsFn
	agentListFn = func(dir string) ([]vi.DirItem, error) {
		if dir != agentCanon {
			t.Fatalf("ListDirAt(%q)", dir)
		}
		if !listed {
			return nil, vi.ErrPeerGone
		}
		var items []vi.DirItem
		for p := range files {
			if strings.HasPrefix(p, agentHostDir) {
				items = append(items, vi.DirItem{Name: p[len(agentHostDir):]})
			}
		}
		return items, nil
	}
	agentReadFn = func(path string, max int) ([]byte, int64) {
		b, ok := files[path]
		if !ok || b == nil {
			return nil, -vi.ErrENOENT
		}
		if len(b) > max {
			b = b[:max]
		}
		return append([]byte(nil), b...), int64(len(b))
	}
	agentKeyFn = func(name string, out []byte) int {
		if name != agentSecret || key == nil {
			return -1
		}
		return copy(out, key)
	}
	// The ring defaults to the unprivileged answer: slot 89's gate is the
	// seat / CAP_PROC_ADMIN, so a plain GOTOP reads -EACCES. Tests that
	// need receipts install their own drain via fakeAgentRing.
	agentDenialsFn = func(c uint64) ([]string, uint64, uint64, int64) {
		return nil, c, 0, -vi.ErrEACCES
	}
	t.Cleanup(func() {
		agentListFn, agentReadFn, agentKeyFn, agentDenialsFn = prevL, prevR, prevK, prevD
	})
}

// fakeAgentRing stages the slot-89 op-2 drain: the verbatim receipt
// lines, the dropped count, and the return code.
func fakeAgentRing(t *testing.T, lines []string, dropped uint64, rc int64) {
	t.Helper()
	prev := agentDenialsFn
	agentDenialsFn = func(c uint64) ([]string, uint64, uint64, int64) {
		return lines, c + uint64(len(lines)), dropped, rc
	}
	t.Cleanup(func() { agentDenialsFn = prev })
}

func rcptLine(seq, agent, verb, args, result string) string {
	return `{"seq":` + seq + `,"epoch":"01020304","agent":"` + agent +
		`","verb":"` + verb + `","args":` + args +
		`,"ts":1761234567,"mono":42,"result":"` + result + `"}`
}

func TestAgentViewRendersReceipts(t *testing.T) {
	files := map[string][]byte{
		agentHostDir + "RCPT-01020304-00000001": rcptBody(agentTestKey,
			rcptLine("1", "-", "session", `{"event":"open"}`, "ok"), false),
		agentHostDir + "RCPT-01020304-00000002": rcptBody(agentTestKey,
			rcptLine("2", "devin", "fs.write", `{"path":"HELLO.TXT","size":27,"sha256_8":"01234567"}`, "ok"), false),
		agentHostDir + "RCPT-01020304-00000003": rcptBody(agentTestKey,
			rcptLine("3", "viewer", "fs.read", `{"path":"SEED.TXT"}`, "cap_required:file"), false),
		agentHostDir + "RCPT-01020304-00000004": rcptBody(agentTestKey,
			rcptLine("4", "mallory", "gosh.run", `{"cmd":"rm -rf /"}`, "ok"), true), // forged
		agentHostDir + "RCPT-01020304-00000005": []byte("not json\n" + strings.Repeat("0", 64) + "\n"),
		agentHostDir + "RCPT-01020304-0000000~": rcptBody(agentTestKey, "{}", false),
		agentHostDir + "OTHER.TXT":              rcptBody(agentTestKey, "{}", false),
	}
	fakeAgentLane(t, files, agentTestKey, true)
	v := NewAgentView()
	v.Refresh()
	if len(v.rows) != 5 {
		t.Fatalf("rows = %d (temps/foreign files must be skipped)", len(v.rows))
	}
	// Newest first, and the marks land: 3 verified, 1 forged, 1 malformed.
	if v.rows[0].mark != markMalformed {
		t.Fatalf("row0 = %+v", v.rows[0])
	}
	if v.rows[1].agent != "mallory" || v.rows[1].mark != markForged {
		t.Fatalf("row1 = %+v", v.rows[1])
	}
	if v.nVerif != 3 || v.nBad != 2 {
		t.Fatalf("verdicts = %d verified %d bad", v.nVerif, v.nBad)
	}
	m := v.Marker()
	if !strings.Contains(m, "top: agent n=5 verified=3 bad=2 key=yes") {
		t.Fatalf("marker = %q", m)
	}
	rm, ok := v.RowMarker(2)
	if !ok || rm != "top: agent rcpt agent=viewer verb=fs.read result=cap_required:file mark=v" {
		t.Fatalf("row marker = %q ok=%v", rm, ok)
	}
	text := strings.Join(v.Lines(), "\n")
	for _, want := range []string{
		"devin    agent     fs.write      HELLO.TXT", "cap_required:file",
		"mallory  agent     gosh.run",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("lines missing %q:\n%s", want, text)
		}
	}
	if !strings.Contains(text, "rm -rf /") {
		t.Fatalf("cmd arg summary missing:\n%s", text)
	}
}

func TestAgentViewNoKeyMarksUnknown(t *testing.T) {
	files := map[string][]byte{
		agentHostDir + "RCPT-01020304-00000001": rcptBody(agentTestKey,
			rcptLine("1", "devin", "proc.list", `{}`, "ok"), false),
	}
	fakeAgentLane(t, files, nil, true) // the row is not served to GOTOP
	v := NewAgentView()
	v.Refresh()
	if len(v.rows) != 1 || v.rows[0].mark != markUnknownKey {
		t.Fatalf("rows = %+v", v.rows)
	}
	if v.nVerif != 0 || v.nBad != 0 {
		t.Fatalf("verdicts = %d/%d", v.nVerif, v.nBad)
	}
	if !strings.Contains(v.Marker(), "key=no") {
		t.Fatalf("marker = %q", v.Marker())
	}
}

// A name the listing carries but the share no longer holds (dropped
// between the list and the read — the writer's 64-bound rotation races
// the view) renders as "missing", not as a silently dropped row.
func TestAgentViewMissingNamed(t *testing.T) {
	files := map[string][]byte{
		agentHostDir + "RCPT-01020304-00000001": rcptBody(agentTestKey,
			rcptLine("1", "devin", "proc.list", `{}`, "ok"), false),
		agentHostDir + "RCPT-01020304-0000000f": nil, // listed, read fails
	}
	fakeAgentLane(t, files, agentTestKey, true)
	v := NewAgentView()
	v.Refresh()
	if len(v.rows) != 2 {
		t.Fatalf("rows = %d", len(v.rows))
	}
	if v.rows[0].result != "missing" || v.rows[0].mark != markMalformed {
		t.Fatalf("missing row = %+v", v.rows[0])
	}
	if v.nBad != 1 {
		t.Fatalf("bad = %d", v.nBad)
	}
}

func TestAgentViewNoLane(t *testing.T) {
	fakeAgentLane(t, nil, agentTestKey, false)
	v := NewAgentView()
	v.Refresh()
	if v.listed {
		t.Fatal("a missing lane must not list")
	}
	lines := v.Lines()
	if len(lines) == 0 || !strings.Contains(lines[0], "no audit lane") {
		t.Fatalf("lines = %v", lines)
	}
	// The kernel section still renders — the ring answers independently
	// of the lane (here: refused, the unprivileged GOTOP answer).
	if !strings.Contains(strings.Join(lines, "\n"), "kernel receipts") {
		t.Fatalf("kernel section missing:\n%v", lines)
	}
}

func TestReceiptNameFilter(t *testing.T) {
	for _, good := range []string{"RCPT-00000001-00000001", "RCPT-abcdef01-ABCDEF01"} {
		if !receiptNameOK(good) {
			t.Fatalf("receiptNameOK(%q) = false", good)
		}
	}
	for _, bad := range []string{
		"RCPT-00000001-00000001~", "RCPT-00000001-0000000", "RCPT-00000001-000000001",
		"RCPT-0000000g-00000001", "RCPT_00000001-00000001", "rcpt-00000001-00000001",
	} {
		if receiptNameOK(bad) {
			t.Fatalf("receiptNameOK(%q) = true", bad)
		}
	}
}

// The scanner refuses the shapes a planted file would carry (trailing
// junk, a broken string, an unclosed object) — never a half-read receipt.
func TestScanFlatRefusesDirty(t *testing.T) {
	if _, ok := scanFlat([]byte(`{"a":1,"b":"x"}`)); !ok {
		t.Fatal("a clean flat object refused")
	}
	f, ok := scanFlat([]byte(`{"a":{},"b":1}`))
	if !ok || len(f["a"]) != 2 {
		t.Fatalf("nested object scan = %v %v", f, ok)
	}
	for _, bad := range []string{
		`{"a":1}x`, `{"a":`, `{"a":"x`, `[1]`, `{"a":1,"a":2`, `nope`,
	} {
		if _, ok := scanFlat([]byte(bad)); ok {
			t.Fatalf("scanFlat(%q) accepted", bad)
		}
	}
}

// --- M173c (#3044): kernel receipts + the principal filter ---------------------

// agentTestRing is the staged drain the kernel would answer on this boot:
// one user denial, one agent denial, a system receipt, a pre-`uid=` line
// (decodes "?"), and a non-receipt line the parser must skip.
var agentTestRing = []string{
	"RCPT stage=exec sha256=aa verdict=audit:net_denied name=CONFINE.BIN word=net uid=1000",
	"RCPT stage=exec sha256=bb verdict=refused:debug_denied name=AGENTD.ELF word=debug uid=2000",
	"RCPT stage=kernel sha256=cc verdict=measured uid=0",
	"RCPT stage=exec sha256=dd verdict=audit:file_denied name=OLD.BIN word=file",
	"not a receipt",
}

func TestAgentViewKernelReceipts(t *testing.T) {
	files := map[string][]byte{
		agentHostDir + "RCPT-01020304-00000001": rcptBody(agentTestKey,
			rcptLine("1", "devin", "proc.list", `{}`, "ok"), false),
	}
	fakeAgentLane(t, files, agentTestKey, true)
	fakeAgentRing(t, agentTestRing, 4, 0)
	v := NewAgentView()
	v.Refresh()
	if len(v.krows) != 4 {
		t.Fatalf("krows = %d (the non-receipt line must be skipped)", len(v.krows))
	}
	want := []string{"user", "agent", "system", "?"}
	for i, c := range want {
		if v.krows[i].class != c {
			t.Fatalf("krows[%d].class = %q want %q", i, v.krows[i].class, c)
		}
	}
	if !strings.Contains(v.Marker(), "krcpts=4") || !strings.Contains(v.Marker(), "filter=all") {
		t.Fatalf("marker = %q", v.Marker())
	}
	text := strings.Join(v.Lines(), "\n")
	for _, want := range []string{
		"kernel receipts", "audit:net_denied", "CONFINE.BIN", "user",
		"refused:debug_denied", "AGENTD.ELF",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("lines missing %q:\n%s", want, text)
		}
	}
	// The kernel rows follow the lane rows in the marker dump.
	rm, ok := v.RowMarker(1)
	if !ok || rm != "top: agent krcpt uid=1000 class=user verdict=audit:net_denied name=CONFINE.BIN word=net" {
		t.Fatalf("kernel row marker = %q ok=%v", rm, ok)
	}
	rm, ok = v.RowMarker(3)
	if !ok || !strings.Contains(rm, "uid=0 class=system") {
		t.Fatalf("system row marker = %q ok=%v", rm, ok)
	}
	// The pre-uid receipt reports honestly: no uid field, class "?".
	rm, ok = v.RowMarker(4)
	if !ok || !strings.Contains(rm, "uid=- class=?") {
		t.Fatalf("legacy row marker = %q ok=%v", rm, ok)
	}
}

func TestAgentViewPrincipalFilter(t *testing.T) {
	files := map[string][]byte{
		agentHostDir + "RCPT-01020304-00000001": rcptBody(agentTestKey,
			rcptLine("1", "devin", "fs.write", `{"path":"A.TXT"}`, "ok"), false),
	}
	fakeAgentLane(t, files, agentTestKey, true)
	fakeAgentRing(t, agentTestRing, 0, 0)
	v := NewAgentView()
	v.Refresh()

	if got := v.CycleFilter(); got != "user" {
		t.Fatalf("filter = %q want user", got)
	}
	// user: the lane (all agent-class) hides; only the uid=1000 receipt stays.
	if m, ok := v.RowMarker(0); !ok || !strings.Contains(m, "uid=1000") {
		t.Fatalf("user row0 = %q ok=%v", m, ok)
	}
	if _, ok := v.RowMarker(1); ok {
		t.Fatal("user filter must leave exactly one visible row")
	}
	text := strings.Join(v.Lines(), "\n")
	if strings.Contains(text, "devin") || strings.Contains(text, "AGENTD.ELF") {
		t.Fatalf("user filter leaked agent rows:\n%s", text)
	}
	if !strings.Contains(v.Marker(), "filter=user") {
		t.Fatalf("marker = %q", v.Marker())
	}

	if got := v.CycleFilter(); got != "agent" {
		t.Fatalf("filter = %q want agent", got)
	}
	// agent: the lane row plus the uid=2000 receipt; uid=1000/system hide.
	rm, ok := v.RowMarker(0)
	if !ok || !strings.Contains(rm, "agent=devin") {
		t.Fatalf("agent row0 = %q ok=%v", rm, ok)
	}
	rm, ok = v.RowMarker(1)
	if !ok || !strings.Contains(rm, "uid=2000 class=agent") {
		t.Fatalf("agent row1 = %q ok=%v", rm, ok)
	}
	if _, ok = v.RowMarker(2); ok {
		t.Fatal("agent filter must leave exactly two visible rows")
	}

	if got := v.CycleFilter(); got != "all" {
		t.Fatalf("filter = %q want all", got)
	}
	if _, ok := v.RowMarker(4); !ok {
		t.Fatal("all must restore every visible row")
	}
}

func TestAgentViewRingRefused(t *testing.T) {
	files := map[string][]byte{
		agentHostDir + "RCPT-01020304-00000001": rcptBody(agentTestKey,
			rcptLine("1", "devin", "proc.list", `{}`, "ok"), false),
	}
	fakeAgentLane(t, files, agentTestKey, true)
	// The default seam already answers -EACCES (the unprivileged GOTOP
	// posture); an explicit install pins the intent.
	fakeAgentRing(t, nil, 0, -vi.ErrEACCES)
	v := NewAgentView()
	v.Refresh()
	if v.denialsErr == 0 || len(v.krows) != 0 {
		t.Fatalf("refused ring: err=%d rows=%d", v.denialsErr, len(v.krows))
	}
	if !strings.Contains(v.Marker(), "krcpts=?") {
		t.Fatalf("marker = %q", v.Marker())
	}
	if !strings.Contains(strings.Join(v.Lines(), "\n"), "refused: EACCES") {
		t.Fatalf("a refused ring must say so:\n%s", v.Lines())
	}
}
