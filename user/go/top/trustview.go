// Package main — GOTOP's trust tab (M113e, issue #2421, ADR 0054 Part II):
// one posture screen per running app. Every field is sourced from a surface
// the guest can actually read, and each names its provenance on screen:
//
//   - uid        — the image's OWNERS.TXT owner (the provisioning uid; a
//     process's own uid is deliberately absent from sys_procs,
//     so the file's recorded owner is the per-app identity a
//     viewer can honestly show).
//   - declared   — the signed ReleaseCaps carried on STORE.TXT's caps= for
//     a store install, else the APPS.TXT v2 caps= field (both
//     declarative by design — a request, never power).
//   - granted    — the GRANTS.TXT row's words, read through slot 89
//     (sys_grant_admin op 0 — the seat or CAP_PROC_ADMIN; an
//     unprivileged GOTOP renders "granted=?", never an empty
//     table dressed as baseline). No row = the ambient
//     baseline, shown as such.
//   - measured   — the viewer's own SHA-256 over the share image, the same
//     raw-file convention the kernel's exec measurement uses;
//     compared against the row's pin (match / stale / wild).
//   - publisher  — derived per ADR 0055 D5: STORE.TXT's stream= resolves
//     through /host/FLINT/streams/<id>.json to its head, and
//     the head Change's author key is the fingerprint. Never
//     declared by a manifest — read off the replica.
//   - receipts   — the kernel's published receipt surface, /host/RCPT.TXT,
//     rendered verbatim (the chain lines today; the parser
//     carries the full stage=exec grammar so refused:/audit:
//     verdicts render the day exec receipts persist there).
//   - denials    — the kernel's denial-receipt ring, read through
//     slot 89 op 2 (#2982): every audit:/refused: receipt emit_denial
//     published this boot, verbatim. Per app, denials= groups them by
//     (verdict, word) with a count; would_deny=<csv> stays the
//     COMPUTED set — baseline words the grant does not cover — and
//     denials= is what the kernel actually receipted. A refused read
//     renders denials=?, never an empty list.
//
// The marker vocabulary is TOP's own (`top: trust ...`) for the same
// reason every other tab's is: the gate asserts the serial lines, and a
// marker only prints after the read it names answered.
package main

import (
	"strings"

	"virelai/shlib"
	"virelai/vi"
)

const (
	trustOwnersPath = "/host/OWNERS.TXT"
	trustAppsPath   = "/host/APPS.TXT"
	trustStatePath  = "/host/STORE.TXT"
	trustRcptPath   = "/host/RCPT.TXT"
	// trustStreamCanon is the ListDirAt canonical root; trustStreamHost is
	// the same directory in file-ABI form.
	trustStreamCanon = "/FLINT/streams"
	trustStreamHost  = "/host/FLINT/streams/"
	// trustTextMax bounds the small text files (the biggest honest one is
	// APPS.TXT at a few KiB; the bound exists so a foreign file cannot
	// stretch the read).
	trustTextMax = 256 * 1024
	// trustImageMax is exec_image_max: a larger file could never have
	// exec'd, so measuring past it is pointless.
	trustImageMax = 32 * 1024 * 1024
	// trustRcptMax bounds the receipt lines rendered per refresh.
	trustRcptMax = 8
	// trustStreamLogMax bounds one streams/<id>.jsonl read.
	trustStreamLogMax = 4 * 1024 * 1024
)

// trustSeams: the syscall-adjacent reads as package vars so host tests
// stage a share without the kernel (the discipline every other tab keeps).
var (
	trustRowsFn    = func() ([]vi.GrantRow, int64) { return vi.GrantRows() }
	trustDenialsFn = func(c uint64) ([]string, uint64, uint64, int64) { return vi.GrantDenials(c) }
	trustReadFn    = vi.ReadFileAll
	trustListFn    = vi.ListDirAt
	trustMeasFn    = measureShareFile
	trustExistsFn  = vi.FileExists
)

// trustApp is one process's rendered posture.
type trustApp struct {
	Name      string
	UID       string // OWNERS.TXT owner, "1000" default, "-" when no image
	Declared  string // canonical csv, "-" when nothing declared
	Granted   string // row words, "baseline", or "?" when the table refused
	Denied    string // baseline words the grant does not cover, "-"
	Denials   string // observed ring receipts: "audit:net x2", "-", or "?"
	SHA       string // measured raw-file sha256 hex, "-" when unmeasured
	Pin       string // the row's sha256 pin, "*" wildcard, "-" no row
	Verdict   string // match|stale|wild|none — measured vs pin
	Publisher string // derived head-author fingerprint, "-" when untracked
	Stream    string // STORE.TXT stream name, "" when untracked
	State     string // baseline|pending|granted|widening|stale|unreadable
}

// trustRcpt is one parsed RCPT line (the D4 grammar).
type trustRcpt struct {
	Stage   string
	Verdict string
	Name    string // "" on chain lines
	Word    string
	Line    string // verbatim text, for display
}

// TrustView is the trust tab's state.
type TrustView struct {
	apps          []trustApp
	rcpts         []trustRcpt
	denials       []trustRcpt // the op-2 ring's receipts this refresh
	denialDropped uint64      // receipts the ring evicted unread
	denialsErr    int64       // the op-2 errno, 0 when the ring was served
	tableErr      int64       // the slot-89 errno, 0 when the rows were served
	refreshed     bool
}

// NewTrustView builds an empty view.
func NewTrustView() *TrustView { return &TrustView{} }

// Refresh resamples every posture source: OWNERS.TXT, APPS.TXT, STORE.TXT,
// the slot-89 grant walk, the per-image measurement, the stream replica,
// and the receipt file. A refused grant read is kept as tableErr — the tab
// says the table is unreadable rather than painting baseline over it.
func (v *TrustView) Refresh(names []string) {
	v.refreshed = true
	v.tableErr = 0
	owners := parseOwnersFile(readTrust(trustOwnersPath))
	appsCaps := parseAppsCaps(readTrust(trustAppsPath))
	store := parseStoreEntries(readTrust(trustStatePath))
	rows, rc := trustRowsFn()
	if rc < 0 {
		v.tableErr = rc
	}
	v.rcpts = parseReceipts(readTrust(trustRcptPath))

	// The observed-denial drain: cursor 0 each refresh re-reads the whole
	// 32-entry ring ("recent denials" is the ring's bound, not a growing
	// ledger), so `dropped` is the count evicted before the oldest
	// surviving receipt. A refused read is kept as denialsErr — the tab
	// says the surface is unreadable rather than painting an empty ring.
	v.denials = v.denials[:0]
	v.denialsErr = 0
	v.denialDropped = 0
	if dlines, _, dropped, drc := trustDenialsFn(0); drc < 0 {
		v.denialsErr = drc
	} else {
		v.denialDropped = dropped
		v.denials = parseReceipts([]byte(strings.Join(dlines, "\n")))
	}

	// Publisher fingerprints resolve once per refresh and only for streams
	// STORE.TXT actually names — a replica is scanned lazily, on demand.
	pub := publisherResolver{}

	v.apps = v.apps[:0]
	for _, name := range names {
		a := trustApp{Name: name, UID: "1000", Declared: "-", Granted: "baseline",
			Denied: "-", SHA: "-", Pin: "-", Verdict: "none", Publisher: "-",
			State: "baseline"}
		uid, ok := ownerUID(owners, name)
		if !imageOnShare(name) {
			a.UID = "-"
		} else if ok {
			a.UID = uid
		}
		if e, ok := storeEntryFor(store, name); ok {
			if e.caps != "" {
				a.Declared = vi.GrantWordsCanonical(splitWords(e.caps))
			}
			a.Stream = e.stream
			a.Publisher = pub.forStream(e.stream)
		} else if caps, ok := appsCaps[foldKey(name)]; ok && caps != "" {
			a.Declared = vi.GrantWordsCanonical(splitWords(caps))
		}
		if rc == 0 {
			if row := grantRowFor(rows, name); row != nil {
				a.Granted = vi.GrantWordsCanonical(splitWords(row.Words))
				a.Pin = row.SHA
			}
		} else {
			a.Granted = "?"
		}
		if denied := deniedWords(a.Granted); denied != "" {
			a.Denied = denied
		}
		a.Denials = v.denialsText(name)
		if imageOnShare(name) {
			a.SHA = trustMeasFn(name)
		}
		a.Verdict = pinVerdict(a.Pin, a.SHA)
		a.State = trustState(a, rc)
		v.apps = append(v.apps, a)
	}
}

// readTrust reads one small text surface; nil on any refusal — a missing
// file is "no data", never a parse of nothing.
func readTrust(path string) []byte {
	b, rc := trustReadFn(path, trustTextMax)
	if rc < 0 {
		return nil
	}
	return b
}

// measureShareFile hashes /host/<name> in bounded chunks — the kernel's
// own convention (raw-file SHA-256, measure.zig). "-" when the file is
// absent, unreadable, or past the exec bound.
func measureShareFile(name string) string {
	b := readWholeShare("/host/"+name, trustImageMax)
	if b == nil {
		return "-"
	}
	sum := shlib.SHA256Sum(b)
	const digits = "0123456789abcdef"
	var out [64]byte
	for i := 0; i < 32; i++ {
		out[2*i] = digits[sum[i]>>4]
		out[2*i+1] = digits[sum[i]&0xf]
	}
	return string(out[:])
}

// readWholeShare drains a file through the raw handle API: ReadFileAll's
// 256 KiB page cap is a browser bound, not a kernel one, and an image the
// viewer measures can exceed it. max+1 refuses honestly rather than hash
// a truncated prefix.
func readWholeShare(path string, max int) []byte {
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc < 0 {
		return nil
	}
	defer vi.FileClose(uint32(h))
	var out []byte
	var buf [16384]byte
	for len(out) <= max {
		n, rr := vi.FileRead(uint32(h), buf[:])
		if rr < 0 {
			return nil
		}
		if n == 0 {
			break
		}
		out = append(out, buf[:n]...)
	}
	if len(out) > max {
		return nil
	}
	return out
}

// imageOnShare reports whether the process name resolves to a share file —
// the split between an exec'd image and the boot payload/kernel spawns.
func imageOnShare(name string) bool {
	return trustExistsFn("/host/" + name)
}

// --- joins ---------------------------------------------------------------

// foldKey is the case-insensitive key every name-keyed table shares (the
// APFS-canonicalization rule OWNERS.TXT and the grant table both apply).
func foldKey(name string) string { return strings.ToUpper(name) }

// procKey matches a registry name (≤ name_max=16, possibly truncated) to a
// stored key the same way the kernel's grant_row_names_caller does: equal
// fold, or the stored key's first 16 chars when the proc name hit the bound.
func procKey(stored, proc string) bool {
	if strings.EqualFold(stored, proc) {
		return true
	}
	return len(proc) >= 16 && len(stored) > 16 && strings.EqualFold(stored[:16], proc[:16])
}

func grantRowFor(rows []vi.GrantRow, name string) *vi.GrantRow {
	for i := range rows {
		if procKey(rows[i].Name, name) {
			return &rows[i]
		}
	}
	return nil
}

type storeEntry struct {
	caps, sha, stream string
}

func storeEntryFor(entries map[string]storeEntry, name string) (storeEntry, bool) {
	for k, e := range entries {
		if procKey(k, name) {
			return e, true
		}
	}
	return storeEntry{}, false
}

// --- file parsers ---------------------------------------------------------

// parseOwnersFile decodes OWNERS.TXT `#v1` lines (`path<TAB>mode<TAB>uid
// <TAB>flags`) into folded-name → uid text. Malformed lines are skipped —
// the kernel fails closed on them, and a viewer must not invent an owner.
func parseOwnersFile(body []byte) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 3 || f[0] == "" {
			continue
		}
		out[foldKey(f[0])] = f[2]
	}
	return out
}

func ownerUID(owners map[string]string, name string) (string, bool) {
	for k, uid := range owners {
		if procKey(k, name) {
			return uid, true
		}
	}
	return "", false
}

// parseAppsCaps decodes the APPS.TXT manifest: pipe-separated fields, the
// v=2 tail carrying `caps=` (declarative only — image/apps.txt's own header
// says nothing grants power from it).
func parseAppsCaps(body []byte) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "|")
		name := strings.TrimSpace(fields[0])
		if name == "" {
			continue
		}
		for _, f := range fields[1:] {
			k, v, ok := strings.Cut(strings.TrimSpace(f), "=")
			if ok && k == "caps" && v != "" && v != "-" {
				out[foldKey(name)] = v
			}
		}
	}
	return out
}

// parseStoreEntries decodes STORE.TXT's name=/caps=/sha256=/stream= fields
// (grammar documented in user/go/store/state.go). prev_row is the verbatim
// tail, so field scraping stops there like the pane's own reader does.
func parseStoreEntries(body []byte) map[string]storeEntry {
	out := map[string]storeEntry{}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.Index(line, " prev_row="); i >= 0 {
			line = line[:i]
		}
		var e storeEntry
		name := ""
		for _, f := range strings.Fields(line) {
			k, v, ok := strings.Cut(f, "=")
			if !ok {
				continue
			}
			switch k {
			case "name":
				name = v
			case "caps":
				if v != "-" {
					e.caps = v
				}
			case "sha256":
				e.sha = v
			case "stream":
				e.stream = v
			}
		}
		if name != "" {
			out[foldKey(name)] = e
		}
	}
	return out
}

// --- publisher derivation (ADR 0055 D5) ------------------------------------
//
// The fingerprint is the head Change's author key on the app's release
// stream — derived from the signature chain's own record, never a manifest
// const. The replica lives at /host/FLINT/streams/<id>.json(record) +
// .jsonl(changes); STORE.TXT's stream= is the stream's NAME, resolved
// against the records.

type publisherResolver struct {
	records []streamRecord // nil until the streams dir is listed once
	listed  bool
}

type streamRecord struct {
	id, name, head string
}

func (r *publisherResolver) list() {
	if r.listed {
		return
	}
	r.listed = true
	items, err := trustListFn(trustStreamCanon)
	if err != nil {
		return
	}
	for _, it := range items {
		if it.IsDir || !strings.HasSuffix(it.Name, ".json") {
			continue
		}
		fields, ok := scanFlat(readTrust(trustStreamHost + it.Name))
		if !ok {
			continue
		}
		r.records = append(r.records, streamRecord{
			id:   fieldStr(fields, "id", ""),
			name: fieldStr(fields, "name", ""),
			head: fieldStr(fields, "head", ""),
		})
	}
}

// forStream returns the head change's author for the named stream, or "-".
func (r *publisherResolver) forStream(stream string) string {
	if stream == "" {
		return "-"
	}
	r.list()
	for _, rec := range r.records {
		if rec.name != stream || rec.head == "" {
			continue
		}
		body := readTrust(trustStreamHost + rec.id + ".jsonl")
		if len(body) == 0 || len(body) > trustStreamLogMax {
			continue
		}
		for _, line := range strings.Split(string(body), "\n") {
			if line == "" {
				continue
			}
			fields, ok := scanFlat([]byte(line))
			if !ok {
				continue
			}
			if fieldStr(fields, "id", "") == rec.head {
				if author := fieldStr(fields, "author", ""); author != "" {
					return author
				}
			}
		}
	}
	return "-"
}

// --- word sets ------------------------------------------------------------

// splitWords decodes a words field: "-"/"" is the empty set.
func splitWords(s string) []string {
	if s == "" || s == "-" {
		return nil
	}
	return strings.Split(s, ",")
}

// deniedWords is the baseline-minus-granted set: the word calls that would
// emit audit:<word>_denied (or refuse outright under enforce). "?" means
// the table was unreadable — unknown, not full.
func deniedWords(granted string) string {
	if granted == "?" || granted == "baseline" {
		return ""
	}
	have := splitWords(granted)
	var missing []string
	for _, w := range vi.GrantWordVocab {
		found := false
		for _, g := range have {
			if g == w {
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, w)
		}
	}
	return vi.GrantWordsCanonical(missing)
}

// pinVerdict compares the measured digest to the row's pin.
func pinVerdict(pin, sha string) string {
	switch {
	case pin == "" || pin == "-":
		return "none"
	case pin == "*":
		return "wild"
	case sha == "-" || sha == "":
		return "none"
	case strings.EqualFold(pin, sha):
		return "match"
	default:
		return "stale"
	}
}

// trustState is the pane's one-word verdict — the same vocabulary GOSET's
// grants pane uses (baseline/pending/stale/widening/granted), plus
// unreadable for a refused table read.
func trustState(a trustApp, readErr int64) string {
	if readErr != 0 {
		return "unreadable"
	}
	if a.Pin == "-" {
		if a.Declared != "-" {
			return "pending"
		}
		return "baseline"
	}
	if a.Verdict == "stale" {
		return "stale"
	}
	if a.Declared != "-" && !vi.GrantWordsSubset(splitWords(a.Declared), splitWords(a.Granted)) {
		return "widening"
	}
	return "granted"
}

// --- receipts --------------------------------------------------------------

// parseReceipts decodes RCPT.TXT's `RCPT stage=<s> sha256=<h> verdict=<v>
// [name=<n>] [word=<w>]` lines — the kernel's published receipt surface.
// The grammar is the full D4 shape so exec-stage refusals render when they
// persist here; malformed lines are skipped, never half-shown.
func parseReceipts(body []byte) []trustRcpt {
	var out []trustRcpt
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "RCPT ") {
			continue
		}
		r := trustRcpt{Line: line}
		for _, f := range strings.Fields(line[5:]) {
			k, v, ok := strings.Cut(f, "=")
			if !ok {
				continue
			}
			switch k {
			case "stage":
				r.Stage = v
			case "verdict":
				r.Verdict = v
			case "name":
				r.Name = v
			case "word":
				r.Word = v
			}
		}
		if r.Stage == "" || r.Verdict == "" {
			continue
		}
		out = append(out, r)
	}
	return out
}

// rcptsFor returns the receipt lines naming name (the exec-stage rows).
func (v *TrustView) rcptsFor(name string) []trustRcpt {
	var out []trustRcpt
	for _, r := range v.rcpts {
		if r.Name != "" && procKey(r.Name, name) {
			out = append(out, r)
		}
	}
	return out
}

// --- observed denials (slot 89 op 2) ---------------------------------------

// trustDenial is one aggregated observed-denial entry: the verdict
// prefix (audit|refused) and the denied word — for a scope denial the
// qualifier the verdict itself carries (`audit:fs_path_denied` counts
// as word fs_path, word=file) — plus how many of this refresh's drained
// receipts grouped into it.
type trustDenial struct {
	Verdict string
	Word    string
	Count   int
}

// denialOf decodes a receipt's `<audit|refused>:<w>_denied` verdict into
// the (verdict, word) pair — the marker's two fields — so each rendered
// entry pairs back to the serial line `<v>:<w>_denied name=<app>`.
// Anything else in the stream (a `measured` receipt is never in the
// ring, but the decode stays fail-closed) is skipped, not half-shown.
func denialOf(r trustRcpt) (string, string, bool) {
	p, w, ok := strings.Cut(r.Verdict, ":")
	if !ok || (p != "audit" && p != "refused") {
		return "", "", false
	}
	if !strings.HasSuffix(w, "_denied") {
		return "", "", false
	}
	return p, strings.TrimSuffix(w, "_denied"), true
}

// denialGroups aggregates the drained receipts by their name= field in
// receipt order — every drained receipt is represented even when the
// process is no longer listed.
func (v *TrustView) denialGroups() []struct {
	name string
	d    trustDenial
} {
	type key struct{ name, verdict, word string }
	var order []key
	agg := map[key]*trustDenial{}
	for _, r := range v.denials {
		pv, w, ok := denialOf(r)
		if !ok || r.Name == "" {
			continue
		}
		k := key{r.Name, pv, w}
		if e, ok := agg[k]; ok {
			e.Count++
			continue
		}
		agg[k] = &trustDenial{Verdict: pv, Word: w, Count: 1}
		order = append(order, k)
	}
	var out []struct {
		name string
		d    trustDenial
	}
	for _, k := range order {
		out = append(out, struct {
			name string
			d    trustDenial
		}{k.name, *agg[k]})
	}
	return out
}

// denialsFor aggregates the drained receipts naming name.
func (v *TrustView) denialsFor(name string) []trustDenial {
	var out []trustDenial
	for _, g := range v.denialGroups() {
		if procKey(g.name, name) {
			out = append(out, g.d)
		}
	}
	return out
}

// denialsText is the app's denials= cell: "?" when the ring read was
// refused (unknown, never an empty list), "-" when the kernel receipted
// nothing for this app, else the grouped `audit:word xN` list.
func (v *TrustView) denialsText(name string) string {
	if v.denialsErr != 0 {
		return "?"
	}
	var parts []string
	for _, d := range v.denialsFor(name) {
		parts = append(parts, d.Verdict+":"+d.Word+" x"+vi.Itoa64(int64(d.Count)))
	}
	if len(parts) == 0 {
		return "-"
	}
	return strings.Join(parts, ", ")
}

// --- render + markers -------------------------------------------------------

// Lines is the tab's text: a summary line, one posture block per app, then
// the receipt tail. Widths stay inside the 500-px list (~80 glyphs).
func (v *TrustView) Lines() []string {
	if !v.refreshed {
		return []string{"trust: not sampled"}
	}
	table := "ok"
	if v.tableErr != 0 {
		table = vi.ErrnoName(v.tableErr)
	}
	out := []string{
		"trust  apps=" + vi.Itoa64(int64(len(v.apps))) +
			"  grants=" + table + "  rcpts=" + vi.Itoa64(int64(len(v.rcpts))),
		"",
	}
	for _, a := range v.apps {
		out = append(out,
			"== "+padRight(clip(a.Name, 16), 16)+" uid="+padRight(a.UID, 4)+" "+a.State,
			"   declared="+padRight(clip(a.Declared, 20), 20)+
				" granted="+clip(a.Granted, 28),
			"   would_deny="+padRight(clip(a.Denied, 20), 20)+
				" pin="+clip(a.Pin, 12),
			"   denials="+clip(a.Denials, 60),
			"   sha256="+a.SHA,
			"   publisher="+a.Publisher+"  stream="+orDashT(a.Stream),
		)
		if n := len(v.rcptsFor(a.Name)); n > 0 {
			out = append(out, "   receipts="+vi.Itoa64(int64(n))+
				" (exec-stage RCPT lines below)")
		}
	}
	if len(v.rcpts) > 0 {
		out = append(out, "", "receipts (RCPT.TXT):")
		n := len(v.rcpts)
		if n > trustRcptMax {
			n = trustRcptMax
		}
		for _, r := range v.rcpts[:n] {
			out = append(out, clip(r.Line, 80))
		}
	}
	return out
}

func orDashT(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// Marker is the summary serial line: the app count, whether the grant
// table was served, and the receipt count — printed only after every read
// it names has answered.
func (v *TrustView) Marker() string {
	table := "ok"
	if v.tableErr != 0 {
		table = "err=" + vi.ErrnoName(v.tableErr)
	}
	return "top: trust n=" + vi.Itoa64(int64(len(v.apps))) +
		" table=" + table +
		" rcpts=" + vi.Itoa64(int64(len(v.rcpts)))
}

// AppMarker is one app's posture line — the fields the gate asserts.
func (v *TrustView) AppMarker(i int) (string, bool) {
	if i < 0 || i >= len(v.apps) {
		return "", false
	}
	a := v.apps[i]
	return "top: trust app name=" + a.Name +
		" uid=" + a.UID +
		" declared=" + a.Declared +
		" granted=" + a.Granted +
		" denied=" + a.Denied +
		" state=" + a.State, true
}

// ShaMarker is one app's measurement evidence: the digest, the row's pin,
// and the verdict between them.
func (v *TrustView) ShaMarker(i int) (string, bool) {
	if i < 0 || i >= len(v.apps) {
		return "", false
	}
	a := v.apps[i]
	return "top: trust sha name=" + a.Name +
		" measured=" + a.SHA +
		" pin=" + a.Pin +
		" verdict=" + a.Verdict, true
}

// PubMarker is one app's publisher evidence (stream + derived fingerprint).
func (v *TrustView) PubMarker(i int) (string, bool) {
	if i < 0 || i >= len(v.apps) {
		return "", false
	}
	a := v.apps[i]
	return "top: trust pub name=" + a.Name +
		" stream=" + orDashT(a.Stream) +
		" publisher=" + a.Publisher, true
}

// RcptMarker is one receipt line verbatim — the kernel's published record,
// carried unmangled so the gate can diff field-for-field.
func (v *TrustView) RcptMarker(i int) (string, bool) {
	if i < 0 || i >= len(v.rcpts) {
		return "", false
	}
	return "top: trust rcpt " + v.rcpts[i].Line, true
}

// DenialsMarker is the observed-denial summary — how many receipts the
// op-2 drain carried that decode as denials, and how many the ring
// evicted before them. err= names the refusal rather than claiming an
// empty ring.
func (v *TrustView) DenialsMarker() string {
	if v.denialsErr != 0 {
		return "top: trust denials err=" + vi.ErrnoName(v.denialsErr)
	}
	var n int
	for _, g := range v.denialGroups() {
		n += g.d.Count
	}
	return "top: trust denials n=" + vi.Itoa64(int64(n)) +
		" dropped=" + vi.Itoa64(int64(v.denialDropped))
}

// DenialMarker is one aggregated observed-denial entry — the gate pairs
// it with the kernel's own `<verdict>:<word>_denied name=<app>` serial
// receipt.
func (v *TrustView) DenialMarker(i int) (string, bool) {
	groups := v.denialGroups()
	if i < 0 || i >= len(groups) {
		return "", false
	}
	g := groups[i]
	return "top: trust denial app=" + g.name +
		" verdict=" + g.d.Verdict +
		" word=" + g.d.Word, true
}
