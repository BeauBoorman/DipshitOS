// The six D3 verbs and the dispatch that maps each D4 refusal onto its
// code. Every validation step runs before any syscall: a refused request
// has no side effect (D4's "refuse before touching anything").
package main

import (
	"strings"

	"virelai/shlib"
	"virelai/vi"
)

// Syscall seams: production wires the real vi/shlib calls; host tests
// substitute fakes (the same seam discipline gotabwm and vi's own tests
// use). They are package vars so a test can swap one without touching the
// others.
var (
	procsFn         = func(dst []vi.ProcRow) (int, int64) { return vi.Procs(dst) }
	readFileFn      = vi.ReadFileAll
	writeFileFn     = vi.WriteFileSafe
	deleteFileFn    = vi.FileDelete
	dirListFn       = vi.DirList
	execFn          = vi.Exec
	waitFn          = vi.WaitBudget
	killFn          = vi.Kill
	probeFn         = vi.Probe
	seatPidFn       = vi.WmctlSeatPid
	winOpenFn       = vi.WinOpen
	winHideFn       = vi.WinSetVisible
	wmWindowsFn     = vi.WmWindows
	scanoutFn       = vi.ScanoutRead
	agentInputKeyFn = vi.WmAgentInputKey
	agentInputPtrFn = vi.WmAgentInputPtr
	agentGeomFn     = vi.WmAgentGeometry
	secretGetFn     = shlib.StoreGet
	principalFn     = vi.Principal
	randomFn        = vi.Random
	argsFn          = vi.Args
	listenFn        = vi.Listen
	consoleFn       = vi.ConsoleLine
	sleepFn         = vi.Sleep
	exitFn          = vi.Exit
)

const (
	// agentPort is the fixed v1 listener (D1).
	agentPort = 4747
	// appName is this image's proc-table name — also the self name the
	// WM_RPC peer scan resolves.
	appName = "AGENTD.ELF"
	// secretName is the app-bound HMAC key row (D2).
	secretName = "agent-hmac"
	// sandboxDir is the host-share root fs.* may reach (D3), and
	// sandboxPrefix is how it spells at the file ABI. auditDir is the
	// receipt lane staged beside it (ADR 0052 D1 posture check 5) —
	// unreachable through fs.* (the AUDIT name is reserved, paths.go).
	sandboxDir    = "/host/AGENT"
	sandboxPrefix = "/host/AGENT/"
	auditDir      = "/host/AGENT/AUDIT"
	// outPath holds one gosh.run's captured stdout, off the fs.* surface on
	// purpose (D3): it lives inside the audit lane, the sandbox's reserved
	// first segment — agent-writable (M173d: the daemon and its children are
	// uid_agent, and only the agent-owned roots take a write) yet never
	// reachable through fs.*.
	outPath      = "/host/AGENT/AUDIT/AGENTD.OUT"
	goshBin      = "GOSH.ELF"
	goshRedirect = " > /host/AGENT/AUDIT/AGENTD.OUT"
)

// Bound constants from D3/D4.
const (
	readMax = 4096  // fs.read / fs.write body ceiling
	outMax  = 16384 // gosh.run captured-stdout ceiling (streamed)
	// streamChunk bounds one streamed response line's payload: b64 is
	// 4/3 plus the envelope, so 4608 raw bytes stay well inside the
	// 8192-byte session line bound.
	streamChunk    = 4608
	cmdMax         = 192 // gosh.run cmd byte ceiling
	timeoutMaxMs   = 30000
	timeoutDefMs   = 10000
	maxProcRows    = 64 // D3: at most 64 rows, kernel order
	authBudgetNs   = int64(10) * 1e9
	idleBudgetNs   = int64(60) * 1e9
	dampingTicks   = 1 // 1 s brute-force damping after an auth failure (D2)
	reapProbeTries = 8 // probe polls after Kill on a timed-out child
	// spawnRetryNs bounds the ENOSPC yield loop in gosh.run — comfortably
	// past an idle-reaper pass over one child's task slots.
	spawnRetryNs = int64(2) * 1e9
)

// sessionCtx is what one authenticated connection resolved: the claimed
// agent id, the caps its keyring row declared (ADR 0052 D3 — resolved
// once at auth, never re-read mid-session), the daemon's --allow-exec
// kill switch, the stream writer bounded-output verbs emit chunk lines
// through, and the next instant a full-resolution ui.screenshot may run
// (the per-session rate bound, D3 amendment).
type sessionCtx struct {
	agentID        string
	caps           map[string]bool
	allowExec      bool
	emit           func(chunk []byte)
	nextFullShotNs int64
}

// verbCap is the fixed verb->cap table (ADR 0052 D3): proc verbs take
// `process`, fs takes `file`, ui.windows/ui.screenshot take `window`,
// ui.input takes `input` — a DISTINCT grant, because an observer that
// may only read the desktop must not get to drive it (M139b) — and
// gosh.run takes `term` (AND-ed with --allow-exec inside the verb — the
// daemon flag is the operator's kill switch, the cap is the per-agent
// grant). ui.geometry (card #2985) splits the same rule BY OP: the verb
// gate is `window` so a read-only observer can query, and the verb
// itself refuses move/sash cap_required:input before touching the seat —
// they drive the desktop, so they take the drive grant.
var verbCap = map[string]string{
	"proc.list":     "process",
	"proc.get":      "process",
	"fs.read":       "file",
	"fs.write":      "file",
	"ui.windows":    "window",
	"ui.screenshot": "window",
	"ui.input":      "input",
	"ui.geometry":   "window",
	"gosh.run":      "term",
}

// allVerbs is the D3 verb set in declaration order, for the ready line.
var allVerbs = []string{
	"proc.list", "proc.get", "fs.read", "fs.write",
	"ui.windows", "ui.screenshot", "ui.input", "ui.geometry", "gosh.run",
}

// advertisedVerbs is the session's resolved grant set: a verb appears
// iff its cap is on the row (D2), and gosh.run also only when the
// daemon's exec flag is on.
func advertisedVerbs(sess *sessionCtx) []string {
	var out []string
	for _, v := range allVerbs {
		if !sess.caps[verbCap[v]] {
			continue
		}
		if v == "gosh.run" && !sess.allowExec {
			continue
		}
		out = append(out, v)
	}
	return out
}

// dispatch validates a request's argument set against its verb and runs
// it. The cap gate runs before any argument check: a missing cap is the
// named refusal cap_required:<cap> — refuse before touching anything,
// and nothing under the cap runs for an agent that was never granted it
// (D3). It returns (resultJSON, "") on success or ("", code) on refusal;
// the caller owns the response envelope and the req/refuse markers.
func dispatch(req *request, sess *sessionCtx) (string, string) {
	cap, known := verbCap[req.verb]
	if !known {
		return "", "unknown_verb"
	}
	if !sess.caps[cap] {
		return "", "cap_required:" + cap
	}
	switch req.verb {
	case "proc.list":
		if !req.hasArgs() {
			return "", "bad_request"
		}
		return verbProcList()
	case "proc.get":
		if !req.hasArgs("pid") {
			return "", "bad_request"
		}
		return verbProcGet(req)
	case "fs.read":
		if !req.hasArgs("path") {
			return "", "bad_request"
		}
		return verbFSRead(req)
	case "fs.write":
		if !req.hasArgs("path", "data_b64") {
			return "", "bad_request"
		}
		return verbFSWrite(req)
	case "ui.windows":
		if !req.hasArgs() {
			return "", "bad_request"
		}
		return verbUIWindows()
	case "ui.screenshot":
		if !req.hasArgs("scale") {
			return "", "bad_request"
		}
		return verbUIScreenshot(req, sess)
	case "ui.input":
		if !req.hasArgs("win", "events") {
			return "", "bad_request"
		}
		return verbUIInput(req)
	case "ui.geometry":
		if !req.hasArgs("win", "op", "space", "percent") {
			return "", "bad_request"
		}
		return verbUIGeometry(req, sess)
	case "gosh.run":
		if !req.hasArgs("cmd", "timeout_ms") {
			return "", "bad_request"
		}
		return verbGoshRun(req, sess)
	}
	return "", "unknown_verb"
}

// --- shared helpers -----------------------------------------------------------

// ioErr is D4's catch-all: any other negative kernel result is io_error and
// the message carries vi.ErrnoName so the client sees which errno it was.
func ioErr(r int64) (string, string) {
	name := vi.ErrnoName(r)
	if name == "" {
		name = "EIO"
	}
	return "", "io_error:" + name
}

// fileErr maps a file-ABI result onto the D4 code table. EINVAL on a
// read-only open is how a directory answers, so it is disambiguated with a
// directory scan before it degrades to io_error.
func fileErr(r int64, name string) (string, string) {
	switch vi.ErrnoName(r) {
	case "ENOENT":
		return "", "not_found"
	case "EACCES":
		return "", "access_denied"
	case "EINVAL":
		if isDir(name) {
			return "", "not_a_file"
		}
	}
	return ioErr(r)
}

// isDir reports whether a sandbox path resolves to a directory: the
// parent is listed and the last segment matched. The kernel matches
// names case-insensitively (ADR 0024 D4); so does this.
func isDir(path string) bool {
	parent, last := parentOf(path)
	dir := sandboxDir
	if parent != "" {
		dir = sandboxPrefix + parent
	}
	var ents [vi.MaxDirEntries]vi.DirEntry
	n, r := dirListFn(dir, ents[:])
	if r < 0 {
		return false
	}
	for i := 0; i < n; i++ {
		if ents[i].Dir() && foldEq(ents[i].NameString(), last) {
			return true
		}
	}
	return false
}

// dirExists is the startup /host/AGENT probe (posture check 3).
func dirExists(path string) bool {
	var ents [vi.MaxDirEntries]vi.DirEntry
	_, r := dirListFn(path, ents[:])
	return r >= 0
}

// foldEq is ASCII case-insensitive equality — NAME matching follows the
// kernel's case-insensitive rule.
func foldEq(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if ca >= 'a' && ca <= 'z' {
			ca -= 32
		}
		if cb >= 'a' && cb <= 'z' {
			cb -= 32
		}
		if ca != cb {
			return false
		}
	}
	return true
}

// --- proc verbs ---------------------------------------------------------------

// stateName maps a ProcRow state onto the D3 enum. The kernel only emits
// 1/2/3; anything else cannot be represented and is reported as an
// io_error by the caller rather than silently mislabelled.
func stateName(s uint64) (string, bool) {
	switch s {
	case vi.ProcCreated:
		return "created", true
	case vi.ProcRunning:
		return "running", true
	case vi.ProcExited:
		return "exited", true
	}
	return "", false
}

// procRowJSON appends one row in the shared proc.list/proc.get shape:
// exit_status is null unless the state is exited.
func procRowJSON(sb *strings.Builder, r *vi.ProcRow) string {
	state, ok := stateName(r.State)
	if !ok {
		return "io_error"
	}
	sb.WriteString(`{"pid":`)
	sb.WriteString(vi.Itoa64(int64(r.PID)))
	sb.WriteString(`,"name":`)
	jwriteStr(sb, r.Name())
	sb.WriteString(`,"state":`)
	jwriteStr(sb, state)
	sb.WriteString(`,"exit_status":`)
	if r.State == vi.ProcExited {
		sb.WriteString(vi.Itoa64(int64(r.ExitStatus)))
	} else {
		sb.WriteString("null")
	}
	sb.WriteByte('}')
	return ""
}

func verbProcList() (string, string) {
	rows := make([]vi.ProcRow, maxProcRows)
	n, r := procsFn(rows)
	if r < 0 {
		return ioErr(r)
	}
	var sb strings.Builder
	sb.WriteString(`{"procs":[`)
	for i := 0; i < n; i++ {
		if i > 0 {
			sb.WriteByte(',')
		}
		if code := procRowJSON(&sb, &rows[i]); code != "" {
			return "", code
		}
	}
	sb.WriteString(`]}`)
	return sb.String(), ""
}

func verbProcGet(req *request) (string, string) {
	pid, present, ok := req.argInt("pid", 1, intMax)
	if !present || !ok {
		return "", "bad_request"
	}
	rows := make([]vi.ProcRow, maxProcRows)
	n, r := procsFn(rows)
	if r < 0 {
		return ioErr(r)
	}
	for i := 0; i < n; i++ {
		if int64(rows[i].PID) == pid {
			var sb strings.Builder
			if code := procRowJSON(&sb, &rows[i]); code != "" {
				return "", code
			}
			return sb.String(), ""
		}
	}
	return "", "not_found"
}

// --- fs verbs -----------------------------------------------------------------

func verbFSRead(req *request) (string, string) {
	path, present, ok := req.argStr("path")
	if !present || !ok {
		return "", "bad_request"
	}
	if !validPath(path) {
		return "", "path_rejected"
	}
	b, r := readFileFn(sandboxPrefix+path, readMax+1)
	if r < 0 {
		return fileErr(r, path)
	}
	if len(b) > readMax {
		return "", "too_large"
	}
	var sb strings.Builder
	sb.WriteString(`{"path":`)
	jwriteStr(&sb, path)
	sb.WriteString(`,"size":`)
	sb.WriteString(vi.Itoa64(int64(len(b))))
	sb.WriteString(`,"data_b64":`)
	jwriteStr(&sb, b64Encode(b))
	sb.WriteByte('}')
	return sb.String(), ""
}

func verbFSWrite(req *request) (string, string) {
	path, present, ok := req.argStr("path")
	if !present || !ok {
		return "", "bad_request"
	}
	body, present, ok := req.argStr("data_b64")
	if !present || !ok {
		return "", "bad_request"
	}
	if !validPath(path) {
		return "", "path_rejected"
	}
	data, ok := b64Decode(body)
	if !ok {
		return "", "bad_request"
	}
	if len(data) > readMax {
		return "", "too_large"
	}
	if isDir(path) {
		return "", "not_a_file"
	}
	if r := writeFileFn(sandboxPrefix+path, data); r < 0 {
		return fileErr(r, path)
	}
	var sb strings.Builder
	sb.WriteString(`{"path":`)
	jwriteStr(&sb, path)
	sb.WriteString(`,"size":`)
	sb.WriteString(vi.Itoa64(int64(len(data))))
	sb.WriteByte('}')
	return sb.String(), ""
}

// --- ui.windows -----------------------------------------------------------------

// agentWindow is the daemon's own kernel window, opened lazily on the
// first ui.windows call. M97g-F2 binds kind-16 requests by window id, so
// an authenticated query requires a window the daemon provably owns —
// the ownership challenge echoes through its title. The window is never
// declared to the seat, so it stays off the strip it reads (D5); it is
// opened at the kernel's resize floor and hidden at once — an undersized
// window is outside the compositor's tested geometry (observed: a 1x1
// open faulted the kernel's paint path), and the daemon's plumbing has
// no pixels to show.
var agentWindow = -1

func verbUIWindows() (string, string) {
	if seatPidFn() <= 0 {
		return `{"seat":"none","focused":null,"windows":[]}`, ""
	}
	if agentWindow < 0 {
		id, raw := winOpenFn(0, 0, 128, 64)
		if id < 0 || raw < 0 {
			return "", "seat_unsupported"
		}
		_ = winHideFn(id, false)
		agentWindow = id
	}
	rows, err := wmWindowsFn(uint32(agentWindow), appName)
	if err != nil {
		if err == vi.ErrSeatUnsupported {
			return "", "seat_unsupported"
		}
		return "", "seat_timeout"
	}
	var sb strings.Builder
	sb.WriteString(`{"seat":"gotabwm","focused":`)
	focused := -1
	for i := range rows {
		if rows[i].Focused {
			focused = rows[i].Index
		}
	}
	if focused >= 0 {
		sb.WriteString(vi.Itoa64(int64(focused)))
	} else {
		sb.WriteString("null")
	}
	sb.WriteString(`,"windows":[`)
	for i := range rows {
		if i > 0 {
			sb.WriteByte(',')
		}
		w := &rows[i]
		sb.WriteString(`{"index":`)
		sb.WriteString(vi.Itoa64(int64(w.Index)))
		sb.WriteString(`,"id":`)
		sb.WriteString(vi.Itoa64(int64(w.ID)))
		sb.WriteString(`,"title":`)
		jwriteStr(&sb, w.Title)
		sb.WriteString(`,"focused":`)
		sb.WriteString(jbool(w.Focused))
		sb.WriteString(`,"pinned":`)
		sb.WriteString(jbool(w.Pinned))
		sb.WriteString(`,"frozen":`)
		sb.WriteString(jbool(w.Frozen))
		sb.WriteByte('}')
	}
	sb.WriteString(`]}`)
	return sb.String(), ""
}

func jbool(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// --- ui.screenshot ---------------------------------------------------------

// The screenshot is a bounded RGB565 little-endian read of the scanout
// through slot 88 (vi.ScanoutRead — the kernel's bounded read-only copy
// of the framebuffer; the writable bind stays seat-only). The default
// scale 8 is the thumbW x thumbH thumbnail: it keeps the 1280x720
// frame's exact 16:9 at an 8:1 stride, so one sampled row band per
// output row suffices and the payload is fixed at thumbW*thumbH*2 =
// 28,800 bytes before chunking.
//
// Card #2977 (ADR 0044 D3 amendment): an optional `scale` argument —
// 8 is the thumbnail, 1 is the full 1280x720 frame. scale=1 reads the
// scanout in fullShotRows-row bands (the largest band one slot-88 call
// serves inside ScanoutReadMax, and 720 is a multiple of it), converts
// each band and streams it through the same emit path — 60 bands,
// 1,843,200 bytes. A full-resolution read is rate-bound to one per
// fullShotMinNs per session; a second request inside the bound answers
// rate_limited. Any other scale value is bad_request.
const (
	thumbW = 160
	thumbH = 90
	// fullShotRows is the scale=1 band height: 12 rows of 1280*4 =
	// 61,440 bytes fit ScanoutReadMax (64 KiB); 13 rows would not.
	fullShotRows = 12
	// fullShotMinNs is the per-session bound on scale=1 captures: one
	// full-resolution read per 2 s.
	fullShotMinNs = int64(2) * 1e9
)

// verbUIScreenshot answers ui.screenshot. The seat is the semantic
// anchor: "screenshot" means the desktop the human sees, so a daemon
// with no registered seat refuses seat_absent by name before touching
// the scanout (the card's named-refusal bar). Pixels arrive as stream
// chunks through sess.emit; the result carries only the shape.
func verbUIScreenshot(req *request, sess *sessionCtx) (string, string) {
	scale, present, ok := req.argInt("scale", 1, intMax)
	if present && (!ok || (scale != 1 && scale != 8)) {
		return "", "bad_request"
	}
	if !present {
		scale = 8
	}
	if scale == 1 && nanosFn() < sess.nextFullShotNs {
		// The bound refuses before the seat query — a rate-limited
		// request pays no syscall and consumes no further budget.
		return "", "rate_limited"
	}
	if seatPidFn() <= 0 {
		return "", "seat_absent"
	}
	if scale == 1 {
		return verbUIScreenshotFull(sess)
	}
	var row [vi.ScanoutWidth * vi.ScanoutBPP]byte
	out := make([]byte, 0, thumbW*thumbH*2)
	stride := vi.ScanoutWidth / thumbW // 8 — the geometry is fixed 16:9
	for ty := 0; ty < thumbH; ty++ {
		sy := uint32(ty * (vi.ScanoutHeight / thumbH))
		r := scanoutFn(0, sy, uint32(vi.ScanoutWidth), 1, row[:])
		if r < 0 {
			return shotErr(r)
		}
		for tx := 0; tx < thumbW; tx++ {
			px := row[tx*stride*vi.ScanoutBPP:]
			out = append565(out, px)
		}
	}
	emitChunks(sess, out)
	return shotResult(thumbW, thumbH), ""
}

// verbUIScreenshotFull is the scale=1 path: the whole frame in
// fullShotRows-row bands, each converted to RGB565 and streamed as it
// lands — the running payload stays at one band, never the full 1.8 MB.
// The first landed band arms the session's rate bound: a request refused
// on the read itself consumed no budget, so ENXIO still answers
// seat_absent without rate-limiting the retry.
func verbUIScreenshotFull(sess *sessionCtx) (string, string) {
	var band [fullShotRows * vi.ScanoutWidth * vi.ScanoutBPP]byte
	out := make([]byte, 0, fullShotRows*vi.ScanoutWidth*2)
	armed := false
	for y := uint32(0); y < vi.ScanoutHeight; y += fullShotRows {
		r := scanoutFn(0, y, uint32(vi.ScanoutWidth), fullShotRows, band[:])
		if r < 0 {
			return shotErr(r)
		}
		if !armed {
			sess.nextFullShotNs = nanosFn() + fullShotMinNs
			armed = true
		}
		for px := 0; px < fullShotRows*vi.ScanoutWidth; px++ {
			out = append565(out, band[px*vi.ScanoutBPP:])
		}
		emitChunks(sess, out)
		out = out[:0]
	}
	return shotResult(vi.ScanoutWidth, vi.ScanoutHeight), ""
}

// append565 converts one B8G8R8X8 little-endian pixel to RGB565
// little-endian — the single conversion both scales share.
func append565(out []byte, px []byte) []byte {
	v := uint16(px[2]>>3)<<11 | uint16(px[1]>>2)<<5 | uint16(px[0]>>3)
	return append(out, byte(v), byte(v>>8))
}

// shotErr maps a scanout_read result onto the verb's named refusals: an
// unarmed framebuffer reads the same as no seat (nothing to see).
func shotErr(r int64) (string, string) {
	switch vi.ErrnoName(r) {
	case "ENXIO":
		return "", "seat_absent"
	case "ENOSYS":
		return "", "seat_unsupported"
	}
	return ioErr(r)
}

// emitChunks streams out through sess.emit in streamChunk pieces — the
// shared tail of every bounded-output verb.
func emitChunks(sess *sessionCtx, out []byte) {
	for len(out) > 0 {
		n := streamChunk
		if len(out) < n {
			n = len(out)
		}
		if sess.emit != nil {
			sess.emit(out[:n])
		}
		out = out[n:]
	}
}

// shotResult renders the ui.screenshot result object: the frame's shape
// and its RGB565 little-endian byte count.
func shotResult(w, h int) string {
	var sb strings.Builder
	sb.WriteString(`{"w":`)
	sb.WriteString(vi.Itoa64(int64(w)))
	sb.WriteString(`,"h":`)
	sb.WriteString(vi.Itoa64(int64(h)))
	sb.WriteString(`,"format":"rgb565le","bytes":`)
	sb.WriteString(vi.Itoa64(int64(w * h * 2)))
	sb.WriteByte('}')
	return sb.String()
}

// --- ui.input -------------------------------------------------------------------

// M139b (#2780): ui.input {win, events} injects input into the focused
// pane over WM_RPC kind 29 (ADR 0007 R2). The daemon's parts:
//
//   - `win` is the strip index the request believes is focused — the same
//     integer ui.windows reports as `focused`. The verb re-queries the
//     strip and refuses agent_input_no_focus when it doesn't match; the
//     seat re-checks focus at dispatch anyway, so a race between the two
//     still lands the seat's own no_focus refusal verbatim.
//   - `events` is a bounded batch (<= inputEventsMax) of flat objects:
//     {"type":"key","usage":N,"mods":N?} for a key press, or
//     {"type":"ptr","x":N,"y":N,"buttons":N?} for an absolute pointer
//     sample. mods/buttons default to 0.
//   - One event rides one kind-29 request — the R2 frame carries a
//     single packed title — so the batch is sent sequentially and the
//     first refusal stops it.
//   - The seat's refusal name is the verdict: agent_input_denied and
//     agent_input_no_focus surface verbatim; a bare applied=0 (a legacy
//     seat with no kind-29 handler) is seat_unsupported.
//
// Refuse before touching: the whole batch validates BEFORE the first
// kind-29 frame goes out — a malformed event N never causes events
// 1..N-1 to fire.

const inputEventsMax = 64 // D3: at most 64 events per call

// inputEvent is one validated batch element.
type inputEvent struct {
	ptr   bool   // false = key press; true = absolute pointer sample
	bits  uint8  // mods (key) / buttons (ptr)
	usage uint8  // key: HID usage
	x, y  uint16 // ptr: framebuffer coordinates
}

// parseInputEvent validates one events[] element against its per-type
// field set; every value must be a flat integer (or "type", a string).
// Member order carries no meaning — "type" is resolved before the rest.
func parseInputEvent(v jval) (ev inputEvent, ok bool) {
	if v.kind != jObj {
		return ev, false
	}
	seen := map[string]bool{}
	typeFound := false
	for _, m := range v.membs {
		if seen[m.key] {
			return ev, false // a duplicated member is malformed
		}
		seen[m.key] = true
		if m.key == "type" {
			if m.val.kind != jStr {
				return ev, false
			}
			switch m.val.str {
			case "key":
				ev.ptr = false
			case "ptr":
				ev.ptr = true
			default:
				return ev, false
			}
			typeFound = true
		}
	}
	if !typeFound {
		return ev, false
	}
	for _, m := range v.membs {
		if m.key == "type" {
			continue
		}
		if m.val.kind != jNum {
			return ev, false
		}
		n, ok2 := flatInt(m.val.str)
		if !ok2 {
			return ev, false
		}
		switch m.key {
		case "usage":
			if ev.ptr || n > 0xff {
				return ev, false
			}
			ev.usage = uint8(n)
		case "mods":
			if ev.ptr || n > 0xff {
				return ev, false
			}
			ev.bits = uint8(n)
		case "buttons":
			if !ev.ptr || n > 0xff {
				return ev, false
			}
			ev.bits = uint8(n)
		case "x":
			if !ev.ptr || n > 0xffff {
				return ev, false
			}
			ev.x = uint16(n)
		case "y":
			if !ev.ptr || n > 0xffff {
				return ev, false
			}
			ev.y = uint16(n)
		default:
			return ev, false // an unknown member is malformed
		}
	}
	if !ev.ptr {
		return ev, seen["usage"]
	}
	return ev, seen["x"] && seen["y"]
}

// verbUIInput answers ui.input. Seat absence is the named refusal first
// (same anchor as ui.screenshot), then the strip's focus answers `win`,
// then each event rides its own bound kind-29 frame in order.
func verbUIInput(req *request) (string, string) {
	win, present, ok := req.argInt("win", 0, intMax)
	if !present || !ok {
		return "", "bad_request"
	}
	elems, present, ok := req.argArray("events")
	if !present || !ok {
		return "", "bad_request"
	}
	if len(elems) > inputEventsMax {
		return "", "too_large"
	}
	evs := make([]inputEvent, len(elems))
	for i, e := range elems {
		if evs[i], ok = parseInputEvent(e); !ok {
			return "", "bad_request"
		}
	}
	if seatPidFn() <= 0 {
		return "", "seat_absent"
	}
	if agentWindow < 0 {
		id, raw := winOpenFn(0, 0, 128, 64)
		if id < 0 || raw < 0 {
			return "", "seat_unsupported"
		}
		_ = winHideFn(id, false)
		agentWindow = id
	}
	rows, err := wmWindowsFn(uint32(agentWindow), appName)
	if err != nil {
		if err == vi.ErrSeatUnsupported {
			return "", "seat_unsupported"
		}
		return "", "seat_timeout"
	}
	focused := -1
	for i := range rows {
		if rows[i].Focused {
			focused = rows[i].Index
		}
	}
	if focused < 0 || int64(focused) != win {
		return "", vi.AgentInputNoFocus
	}
	sent := 0
	for _, e := range evs {
		var rep vi.WmRpc
		var answered bool
		if e.ptr {
			rep, answered = agentInputPtrFn(uint32(agentWindow), e.bits, e.x, e.y, appName)
		} else {
			rep, answered = agentInputKeyFn(uint32(agentWindow), e.bits, e.usage, appName)
		}
		if !answered {
			return "", "seat_timeout"
		}
		if rep.Applied == 0 {
			switch rep.TitleString() {
			case vi.AgentInputDenied, vi.AgentInputNoFocus:
				return "", rep.TitleString()
			}
			return "", "seat_unsupported"
		}
		sent++
	}
	return `{"sent":` + vi.Itoa64(int64(sent)) + `}`, ""
}

// --- ui.geometry ----------------------------------------------------------------

// Card #2985 (ADR 0044 D5c): ui.geometry {win, op, space?|percent?}
// arranges the desktop the way the seat arranges it, over WM_RPC kind
// 30. `win` is the strip index ui.windows reports; the verb resolves it
// to the kernel window id through the same kind-16 query ui.input uses
// for its focus check. `op` is one of:
//
//   - "query" — where the window is: `{"space":N,"pane":N|null,
//     "split":"none"|"h"|"v","rect":{"x":N,"y":N,"w":N,"h":N}}`. The
//     `window` cap serves it — same grant as ui.windows.
//   - "move" — `space`: space index; the tab joins that space's strip
//     (creating it at the seat's own cap). `{"space":N}`.
//   - "sash" — `percent`: the window's parent split's divider at 10-90 %
//     of its rect. `{"percent":N}`.
//
// move and sash take the `input` cap — they drive the desktop, so the
// M139b rule applies; the refusal names cap_required:input before the
// verb touches the seat. The seat's own refusal names surface verbatim
// (win_geometry_denied / win_geometry_no_window / win_geometry_bad_op);
// a bare applied=0 is seat_unsupported, silence is seat_timeout, and an
// index no strip row holds is win_geometry_no_window resolved here.
func verbUIGeometry(req *request, sess *sessionCtx) (string, string) {
	win, present, ok := req.argInt("win", 0, intMax)
	if !present || !ok {
		return "", "bad_request"
	}
	op, present, ok := req.argStr("op")
	if !present || !ok {
		return "", "bad_request"
	}
	var opCode uint8
	switch op {
	case "query":
		opCode = vi.WmGeomOpQuery
	case "move":
		opCode = vi.WmGeomOpMove
	case "sash":
		opCode = vi.WmGeomOpSash
	default:
		return "", "bad_request"
	}
	// The cap gate runs before the op's own args are weighed, the same
	// order dispatch uses — a session without the drive grant learns
	// cap_required:input, not which field was malformed.
	if opCode != vi.WmGeomOpQuery && !sess.caps["input"] {
		return "", "cap_required:input"
	}
	space, spPresent, spOK := req.argInt("space", 0, 255)
	pct, pcPresent, pcOK := req.argInt("percent", 0, 255)
	if !spOK || !pcOK {
		return "", "bad_request"
	}
	var arg uint8
	switch opCode {
	case vi.WmGeomOpQuery:
		if spPresent || pcPresent {
			return "", "bad_request"
		}
	case vi.WmGeomOpMove:
		if !spPresent || pcPresent {
			return "", "bad_request"
		}
		arg = uint8(space)
	case vi.WmGeomOpSash:
		if !pcPresent || spPresent {
			return "", "bad_request"
		}
		arg = uint8(pct)
	}
	if seatPidFn() <= 0 {
		return "", "seat_absent"
	}
	if agentWindow < 0 {
		id, raw := winOpenFn(0, 0, 128, 64)
		if id < 0 || raw < 0 {
			return "", "seat_unsupported"
		}
		_ = winHideFn(id, false)
		agentWindow = id
	}
	rows, err := wmWindowsFn(uint32(agentWindow), appName)
	if err != nil {
		if err == vi.ErrSeatUnsupported {
			return "", "seat_unsupported"
		}
		return "", "seat_timeout"
	}
	var target uint32
	found := false
	for i := range rows {
		if int64(rows[i].Index) == win {
			target = rows[i].ID
			found = true
			break
		}
	}
	if !found {
		return "", vi.AgentGeomNoWindow
	}
	rep, answered := agentGeomFn(uint32(agentWindow), opCode, target, arg, appName)
	if !answered {
		return "", "seat_timeout"
	}
	if rep.Applied == 0 {
		switch rep.TitleString() {
		case vi.AgentGeomDenied, vi.AgentGeomNoWindow, vi.AgentGeomBadOp:
			return "", rep.TitleString()
		}
		return "", "seat_unsupported"
	}
	switch opCode {
	case vi.WmGeomOpMove:
		return `{"space":` + vi.Itoa64(int64(arg)) + `}`, ""
	case vi.WmGeomOpSash:
		return `{"percent":` + vi.Itoa64(int64(arg)) + `}`, ""
	}
	v, ok := vi.WmGeomDecode(rep)
	if !ok {
		return "", "seat_unsupported"
	}
	var sb strings.Builder
	sb.WriteString(`{"space":`)
	sb.WriteString(vi.Itoa64(int64(v.Space)))
	sb.WriteString(`,"pane":`)
	if v.Pane == vi.WmGeomUnplaced {
		sb.WriteString("null")
	} else {
		sb.WriteString(vi.Itoa64(int64(v.Pane)))
	}
	sb.WriteString(`,"split":`)
	switch v.Split {
	case 1:
		jwriteStr(&sb, "h")
	case 2:
		jwriteStr(&sb, "v")
	default:
		jwriteStr(&sb, "none")
	}
	sb.WriteString(`,"rect":{"x":`)
	sb.WriteString(vi.Itoa64(int64(v.X)))
	sb.WriteString(`,"y":`)
	sb.WriteString(vi.Itoa64(int64(v.Y)))
	sb.WriteString(`,"w":`)
	sb.WriteString(vi.Itoa64(int64(v.W)))
	sb.WriteString(`,"h":`)
	sb.WriteString(vi.Itoa64(int64(v.H)))
	sb.WriteString(`}}`)
	return sb.String(), ""
}

// --- gosh.run -------------------------------------------------------------------

func verbGoshRun(req *request, sess *sessionCtx) (string, string) {
	if !sess.allowExec {
		return "", "verb_disabled"
	}
	cmd, present, ok := req.argStr("cmd")
	if !present || !ok {
		return "", "bad_request"
	}
	if len(cmd) == 0 || len(cmd) > cmdMax {
		return "", "too_large"
	}
	for i := 0; i < len(cmd); i++ {
		if cmd[i] < 0x20 || cmd[i] > 0x7e {
			return "", "cmd_rejected"
		}
	}
	if !shlib.CheckAgentLine(cmd) {
		return "", "cmd_rejected"
	}
	ms, present, ok := req.argInt("timeout_ms", 1, timeoutMaxMs)
	if present && !ok {
		return "", "bad_request"
	}
	if !present {
		ms = timeoutDefMs
	}
	_ = deleteFileFn(outPath)
	// D4 residual (a): the attempt is on record BEFORE the child starts —
	// a term-capped agent can reach AUDIT/ through a shell line, so this
	// intent receipt is the untouchable-in-order part of the trail. The
	// post-dispatch receipt still carries the real result (ok/timed_out/
	// spawn_failed); the pair is one dispatch's record, not a double count.
	lane.emit(sess.agentID, "gosh.run", auditArgs(req, "", "intent"), "ok")
	// The task pool is bounded; a just-exited child's slots stay zombies
	// until the idle task reaps them, so a back-to-back spawn can land
	// ENOSPC. That refusal is transient — yield and retry a bounded window
	// before reporting spawn_failed (real refusals fail on the first try).
	pid, err := execFn(goshBin, "-c", cmd+goshRedirect)
	for spinNs := nanosFn(); err != nil && err.Error() == "ENOSPC"; {
		if nanosFn()-spinNs >= spawnRetryNs {
			break
		}
		yieldFn()
		pid, err = execFn(goshBin, "-c", cmd+goshRedirect)
	}
	if err != nil {
		return "", "spawn_failed"
	}
	consoleFn(markerSpawn + vi.Itoa64(pid))
	st, werr := waitFn(pid, ms*int64(1e6))
	if werr != nil {
		_ = killFn(uint64(pid))
		st = reapConfirm(pid)
		consoleFn(markerReap + vi.Itoa64(pid) + " status=" + vi.Itoa64(st))
		_ = deleteFileFn(outPath) // the capture file is per-run; a killed child still leaves one
		return "", "timed_out"
	}
	consoleFn(markerReap + vi.Itoa64(pid) + " status=" + vi.Itoa64(st))
	// The child's task slots free only when the idle task reaps them —
	// Probe going Absent (descriptor recycled) is the observable edge of
	// that. Settling here keeps the NEXT back-to-back gosh.run from
	// tripping a full pool mid-start.
	settleChild(pid)
	out, r := readFileFn(outPath, outMax+1)
	if r < 0 {
		out = nil // no capture file: the command printed nothing
	}
	truncated := len(out) > outMax
	if truncated {
		out = out[:outMax]
	}
	_ = deleteFileFn(outPath)
	// Bounded streaming (M109b): the captured bytes ride stream chunk
	// lines ahead of the result — the line bound never moves and the
	// client reassembles seq order. GOSH's > redirect materializes the
	// file only when the child exits, so chunking-after-reap is the
	// honest streaming shape this pipe can offer.
	streamed := len(out)
	emitChunks(sess, out)
	var sb strings.Builder
	sb.WriteString(`{"exit_status":`)
	sb.WriteString(vi.Itoa64(st))
	sb.WriteString(`,"stdout_bytes":`)
	sb.WriteString(vi.Itoa64(int64(streamed)))
	sb.WriteString(`,"truncated":`)
	sb.WriteString(jbool(truncated))
	sb.WriteByte('}')
	return sb.String(), ""
}

// settleChild yield-polls Probe until the child's descriptor recycles
// (ProbeAbsent) or the bound lapses — best-effort, never fatal.
func settleChild(pid int64) {
	for start := nanosFn(); nanosFn()-start < spawnRetryNs; {
		if _, state := probeFn(pid); state == vi.ProbeAbsent {
			return
		}
		yieldFn()
	}
}

// reapConfirm polls Probe after a Kill until the child leaves the running
// state, returning the last observed status (-1 when it simply vanished —
// the reaped-and-recycled case).
func reapConfirm(pid int64) int64 {
	st := int64(-1)
	for i := 0; i < reapProbeTries; i++ {
		s, state := probeFn(pid)
		switch state {
		case vi.ProbeExited:
			return s
		case vi.ProbeAbsent:
			return st // reaped and recycled: -1 is the honest answer
		default:
			st = s
			sleepFn(1)
		}
	}
	return st
}

// --- base64 (RFC 4648, standard alphabet, strict decode) --------------------------

const b64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

var b64RevTab = func() [256]int8 {
	var t [256]int8
	for i := range t {
		t[i] = -1
	}
	for i := 0; i < len(b64Alphabet); i++ {
		t[b64Alphabet[i]] = int8(i)
	}
	return t
}()

func b64Encode(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	var sb strings.Builder
	sb.Grow((len(b) + 2) / 3 * 4)
	for i := 0; i+3 <= len(b); i += 3 {
		n := uint32(b[i])<<16 | uint32(b[i+1])<<8 | uint32(b[i+2])
		sb.WriteByte(b64Alphabet[n>>18])
		sb.WriteByte(b64Alphabet[(n>>12)&63])
		sb.WriteByte(b64Alphabet[(n>>6)&63])
		sb.WriteByte(b64Alphabet[n&63])
	}
	switch rem := len(b) % 3; rem {
	case 1:
		n := uint32(b[len(b)-1]) << 16
		sb.WriteByte(b64Alphabet[n>>18])
		sb.WriteByte(b64Alphabet[(n>>12)&63])
		sb.WriteString("==")
	case 2:
		n := uint32(b[len(b)-2])<<16 | uint32(b[len(b)-1])<<8
		sb.WriteByte(b64Alphabet[n>>18])
		sb.WriteByte(b64Alphabet[(n>>12)&63])
		sb.WriteByte(b64Alphabet[(n>>6)&63])
		sb.WriteByte('=')
	}
	return sb.String()
}

// b64Decode is the strict D3 decoder: padding required, only at the tail,
// at most two '=' bytes, standard alphabet, no whitespace.
func b64Decode(s string) ([]byte, bool) {
	if len(s) == 0 {
		return nil, true
	}
	if len(s)%4 != 0 {
		return nil, false
	}
	pad := 0
	for pad < 2 && s[len(s)-1-pad] == '=' {
		pad++
	}
	body := s[:len(s)-pad]
	for i := 0; i < len(body); i++ {
		if b64RevTab[body[i]] < 0 {
			return nil, false
		}
	}
	out := make([]byte, 0, len(s)/4*3)
	for i := 0; i+4 <= len(body); i += 4 {
		n := uint32(b64RevTab[body[i]])<<18 | uint32(b64RevTab[body[i+1]])<<12 |
			uint32(b64RevTab[body[i+2]])<<6 | uint32(b64RevTab[body[i+3]])
		out = append(out, byte(n>>16), byte(n>>8), byte(n))
	}
	switch pad {
	case 0:
		if rem := len(body) % 4; rem != 0 {
			return nil, false
		}
	case 1:
		n := uint32(b64RevTab[body[len(body)-3]])<<18 |
			uint32(b64RevTab[body[len(body)-2]])<<12 |
			uint32(b64RevTab[body[len(body)-1]])<<6
		out = append(out, byte(n>>16), byte(n>>8))
	case 2:
		n := uint32(b64RevTab[body[len(body)-2]])<<18 |
			uint32(b64RevTab[body[len(body)-1]])<<12
		out = append(out, byte(n>>16))
	}
	return out, true
}
