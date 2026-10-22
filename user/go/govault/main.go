// Command govault is GOVAULT.ELF — M148a (issue #2804), receipts M148b
// (#2805), M156c (#2933): the secrets store gets a face, a bundle format and
// a state hook. One unlock-gated vault file (GVLT framing, PBKDF2-HMAC-SHA256
// -> AES-256-GCM, written through vi.WriteFileSafe so a crash keeps the old
// file), a masked passphrase field, a per-entry reveal, a copy that expires,
// an idle lock, and a plaintext receipts file with its own read-only face.
// M156c adds: GVLX export/import bundles (same frame, distinct magic, their
// own passphrase) through the shared picker, a merge that never overwrites,
// the M125a save_state blob (the vault's path — nothing secret), and a TOTP
// column for entries carrying an otpauth seed behind the hmac/sha1 + clock
// probe. The codec lives in vault.go, the receipt row codec in receipts.go,
// the TOTP math and seed intake in totp.go, the state blob codec in
// state.go, the pure session model in model.go; this file owns the seat,
// the drawing, the timers and the serial markers.
//
// The clipboard, precisely: the KERNEL buffer (slots 38/39) admits only the
// seat and CAP_CLIPBOARD — no EL0 grant path exists (ADR 0054, `caps` are
// spawn-time kernel properties). The buffer an app can reach is the seat's
// primary selection (M124e): copy is a kind-27 publish, the "still holds it"
// check is a kind-28 pull, and clearing is a second publish of a cleared
// sentinel — the selection has no empty publish (kind-27 refuses len 0), so
// expiry overwrites. The manifest opt-in is `selection=primary`; under a seat
// that refuses (no opt-in, no seat) the copy reports its named refusal and
// nothing is armed.
//
// Secrets discipline: entry fields stay in []byte end to end so lock() can
// zero them; the passphrase buffer is zeroed on every outcome; the clipboard
// compare runs against a sha256 tag, never a kept plaintext; and no serial
// marker ever carries a name, a secret, a note or a passphrase — the
// marker vocabulary below is the whole observable surface.
//
// Every marker is printed only AFTER the call it names returned, so a gate
// asserting one can only pass when the work actually ran.
package main

import (
	"strings"
	"unicode/utf8"

	"virelai/appkit"
	"virelai/clockfmt"
	"virelai/draw"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
	"virelai/webrender/font"
	"virelai/widgets"
)

const (
	appName  = "GOVAULT.ELF"
	appTitle = "Vault"
	natW     = 512
	natH     = 384
	natX     = 32
	natY     = 32

	// vaultPath is the app-owned file on the share — the /host/<APP> dir the
	// other file-cap apps use. It is deliberately NOT a secret-class path
	// (ADR 0024 D8): the body is sealed, so WriteFileSafe's path~ temp
	// window exposes ciphertext, never plaintext.
	vaultPath = "/host/GOVAULT/VAULT.BIN"

	// receiptPath is the vault's own receipts file (M148b): plaintext rows
	// of time, action and entry name — never secret material, and never
	// inside the seal (a failed unlock holds no key to write with).
	receiptPath = "/host/GOVAULT/RECEIPTS.TXT"

	// maxReceipts bounds the view's read. Rows are ~30–60 bytes, so the cap
	// is a thousand-odd receipts — a file past it shows its oldest rows,
	// which is the honest end of a log that outgrew its window.
	maxReceipts = 64 << 10

	// clearBytes is the expiry overwrite. kind-27 refuses an empty publish,
	// so "cleared" is a bounded, non-secret sentinel the user can see.
	clearBytes = "[cleared]"
)

// Marker vocabulary. n= and rc= are the only payloads — counts and kernel
// codes, never secret material.
const (
	markerOpen       = "govault: open id="
	markerDeclare    = "govault: declare accepted"
	markerDeclRef    = "govault: declare refused"
	markerPresent    = "govault: present"
	markerNew        = "govault: new vault"
	markerLocked     = "govault: locked"
	markerBad        = "govault: bad file"
	markerLoadErr    = "govault: load error rc="
	markerIters      = "govault: iterations "
	markerUnlocked   = "govault: unlocked n="
	markerUnlockBad  = "govault: unlock failed"
	markerMismatch   = "govault: passphrase mismatch"
	markerAdded      = "govault: added"
	markerRefused    = "govault: refused "
	markerSaved      = "govault: saved"
	markerSaveErr    = "govault: save refused rc="
	markerRevealed   = "govault: revealed"
	markerHidden     = "govault: hidden"
	markerCopied     = "govault: copied"
	markerCopyErr    = "govault: copy refused"
	markerExpired    = "govault: clip expired"
	markerKept       = "govault: clip kept"
	markerClipRef    = "govault: clip expire refused"
	markerIdle       = "govault: locked idle"
	markerRcpts      = "govault: receipts n="
	markerRcpt       = "govault: rcpt i="
	markerRcptsEnd   = "govault: receipts end"
	markerRcptRef    = "govault: receipt refused rc="
	markerPickOpen   = "govault: pick open "
	markerPickSave   = "govault: pick save "
	markerPickCancel = "govault: pick cancel"
	markerExport     = "govault: export n="
	markerExportErr  = "govault: export refused rc="
	markerImport     = "govault: import "
	markerImportBad  = "govault: import bad file"
	markerImportErr  = "govault: import refused rc="
	markerClock      = "govault: clock epoch="
	markerStateSave  = "govault: state saved"
	markerStateRest  = "govault: state restored"
	markerClose      = "govault: close"
	markerOK         = "govault OK"
	markerExiting    = "govault: exiting "
)

// The TOTP clock marker is the card's probe leg: the guest wall clock the
// codes are computed against, printed at the moments a code could be on
// screen (unlock, import, reveal) so the host can read skew off the last
// line. Epoch seconds are not secret material.
func (a *app) clockMarker() {
	vi.ConsoleLine(markerClock + vi.Itoa64(timeFn()))
}

// Seams — the vi/vsys calls that cross the raw syscall gateway degrade to
// -ENOSYS off the guest, so host tests drive these (the vi.SelPublish seam is
// the same discipline as wmsel's selFileWrite vars).
var (
	nowFn       = vsys.Nanotime
	timerSetFn  = vsys.TimerSet
	timerCancel = vsys.TimerCancel
	randFill    = func(b []byte) bool {
		n, err := vi.Random(b)
		return err == nil && n == len(b)
	}
	selPublish = vi.SelPublish
	selPull    = vi.RequestSelPaste
	readAll    = vi.ReadFileAll
	writeSafe  = vi.WriteFileSafe
	timeFn     = vi.Time
	rcptAppend = func(path string, b []byte) int64 {
		return vi.WriteFilePublish(path, b, true)
	}
	fileOpen  = vi.FileOpen
	fileClose = func(h int64) { vi.FileClose(uint32(h)) }
	// M173d (ADR 0052 amendment, index D16): the vault is 0600 — the agent
	// principal must not even read the ciphertext. fileMode is the
	// owner-only slot-69 chmod; the daemon owns the file it publishes.
	fileMode = vi.FileMode
	notifyFn  = func(ta *tabapp.TabApp, text string) bool { return ta.Notify(text) }
)

// field is one input row. buf holds UTF-8; masked fields paint one '*' per
// rune. Kept as bytes so clear() can zero secret input — a string field
// could never be wiped.
type field struct {
	label  string
	buf    []byte
	max    int
	masked bool
}

func newField(label string, max int, masked bool) field {
	return field{label: label, max: max, masked: masked}
}

// insert appends one rune whole; the bound refuses rather than truncating
// mid-encoding.
func (f *field) insert(r rune) bool {
	var enc [utf8.UTFMax]byte
	n := utf8.EncodeRune(enc[:], r)
	if len(f.buf)+n > f.max {
		return false
	}
	f.buf = append(f.buf, enc[:n]...)
	return true
}

// backspace removes the last rune whole and zeroes its bytes.
func (f *field) backspace() bool {
	if len(f.buf) == 0 {
		return false
	}
	_, n := utf8.DecodeLastRune(f.buf)
	zero(f.buf[len(f.buf)-n:])
	f.buf = f.buf[:len(f.buf)-n]
	return true
}

// clear zeroes and empties the buffer.
func (f *field) clear() {
	zero(f.buf)
	f.buf = f.buf[:0]
}

// shown is what the field paints: the text, or one bullet per rune.
func (f *field) shown() string {
	if !f.masked {
		return string(f.buf)
	}
	n := utf8.RuneCount(f.buf)
	out := make([]byte, n)
	for i := range out {
		out[i] = '*'
	}
	return string(out)
}

// app is the session: the seat client, the model, the loaded file, the field
// buffers per face, the open picker (modal over the list face), and the last
// status line (never secret material).
type app struct {
	ta *tabapp.TabApp
	m  model

	path string
	file []byte

	pass  field // masked passphrase (locked + new + export + import)
	conf  field // masked confirm (new + export)
	focus int   // field index inside the current face
	add   [4]field

	pick     appkit.FilePicker
	picking  bool   // the picker plate owns input while open
	pickPath string // the path the picker resolved — export target or import source

	status string
	quit   bool
}

// marker keys, not the HIDs (the kernel decodes arg1 to the codepoint; arg0
// is the usage for arrows and escape).
const (
	modCtrl = uint16(0x0002)

	hidEsc  = 0x29
	hidUp   = 0x52
	hidDown = 0x51
	hidTab  = 0x2b

	codeBackspace = 0x08
	codeDelete    = 0x7f
	codeReturn    = 0x0d
	codeNewline   = 0x0a
	codeTab       = 0x09
	keyCtrlL      = 0x0c // ctrl-l arrives as the control code
	keyL          = 0x6c
)

func loadGuestTheme() {
	b, r := readAll("/host/SETTINGS.TXT", 2048)
	if r < 0 || b == nil {
		return
	}
	_ = theme.ApplySettings(b)
}

func main() {
	loadGuestTheme()
	a := &app{
		path: vaultPath,
		pass: newField("passphrase", 64, true),
		conf: newField("confirm", 64, true),
	}
	a.add[0] = newField("name", maxName, false)
	a.add[1] = newField("secret", maxSecret, true)
	a.add[2] = newField("note", maxNote, false)
	a.add[3] = newField("totp", maxTotp, true)

	ta := tabapp.Init(tabapp.Config{
		Name:         appName,
		Title:        appTitle,
		X:            natX,
		Y:            natY,
		W:            natW,
		H:            natH,
		SaveState:    a.saveBlob,
		RestoreState: a.applyState,
		StateVersion: stateVersion,
	})
	if ta == nil {
		vi.ConsoleLine(markerOpen + "-1")
		vi.Exit(1)
	}
	a.ta = ta
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))
	if ta.TabAware {
		vi.ConsoleLine(markerDeclare)
	} else {
		vi.ConsoleLine(markerDeclRef)
	}
	// A restored blob is the seat handing back the vault's path — the
	// session itself still starts locked; the marker is the proof the
	// handoff happened at all.
	if ta.Restored {
		vi.ConsoleLine(markerStateRest)
	}

	a.load()

	loop := appkit.NewLoop(a.ta, a.draw, a.handle)
	loop.ShouldQuit = func() (int, bool) { return 0, a.quit }
	loop.OnInitialPresent = func() {
		vi.ConsoleLine(markerPresent)
	}
	loop.OnExit = func(status int) {
		a.m.lock()
		a.pass.clear()
		a.conf.clear()
		vi.ConsoleLine(markerClose)
		vi.ConsoleLine(markerOK)
		vi.ConsoleLine(markerExiting + vi.Itoa64(int64(status)))
		a.ta.CloseAndExit(status)
	}
	// The seat's save_state ask is mailbox traffic, not an input event:
	// answer it once per pass before polling, the same discipline the
	// other hooked apps keep.
	loop.RunWith(func() (vi.Event, int64, bool) {
		if a.ta.PollStateAsk() {
			vi.ConsoleLine(markerStateSave)
			// The clock probe reads its LAST marker: the state ask lands
			// moments before the seat's snapshot write and teardown, so
			// this is the marker closest to the host's verdict time.
			a.clockMarker()
		}
		return vi.PollEventRaw()
	}, vi.Sleep)
}

// load reads the vault file once and picks the opening face. The bytes stay
// for the unlock attempts — an unlock needs them anyway, so there is no
// re-read between faces (and a file changed under the app is the next
// process's problem, not this boot's).
func (a *app) load() {
	data, rc := readAll(a.path, maxFile+1)
	if rc < 0 {
		if rc == -int64(vi.ErrENOENT) {
			a.m.scr = scrNew
			vi.ConsoleLine(markerNew)
			return
		}
		a.m.scr = scrBadFile
		vi.ConsoleLine(markerLoadErr + vi.Itoa64(rc))
		return
	}
	if _, _, _, _, _, err := parseHeader(data, fileMagic); err != nil {
		a.m.scr = scrBadFile
		vi.ConsoleLine(markerBad)
		return
	}
	a.file = data
	a.m.scr = scrLocked
	vi.ConsoleLine(markerLocked)
	// D16: a vault written before the 0600 posture stays 0644 on disk —
	// tighten it on open so the agent's other-triplet read closes. A
	// refusal means the file is not ours; the bytes already parsed, so the
	// errno is noise the face does not need.
	_ = fileMode(a.path, 0o600)
}

// rearm drives the one app timer from the model's deadline triple. Called
// after every event that can change a deadline, so the physical timer always
// counts toward the earliest live one. The TOTP repaint tick arms here too:
// live while the list face shows a seeded row, disarmed the moment lock or
// a face change takes it off screen.
func (a *app) rearm() {
	now := nowFn()
	if a.m.scr == scrList && a.m.hasTotp() {
		a.m.dl.armTick(now)
	} else {
		a.m.dl.stopTick()
	}
	d := a.m.dl.nextDelay(now)
	if d == 0 {
		if a.m.armed != 0 {
			a.m.armed = 0
			timerCancel()
		}
		return
	}
	a.m.armed = d
	timerSetFn(d)
}

// handle routes one event. Timer events are the deadline driver; every
// other event is activity while the vault is unlocked.
func (a *app) handle(ev vi.Event) bool {
	if ev.Kind == vi.EvTimer {
		return a.onTimer()
	}
	if a.m.scr == scrList || a.m.scr == scrAdd || a.m.scr == scrReceipts ||
		a.m.scr == scrExport || a.m.scr == scrImport {
		a.m.dl.activity(nowFn())
		defer a.rearm()
	}
	if ev.Kind != vi.EvKeyDown {
		return false
	}
	// The picker is a modal over the unlocked list: it owns every key while
	// open, and its Result lands the export/import passphrase faces.
	if a.picking {
		return a.pickerKey(ev)
	}
	switch a.m.scr {
	case scrNew:
		return a.keyNew(ev)
	case scrLocked:
		return a.keyLocked(ev)
	case scrBadFile:
		if ev.Arg0 == hidEsc {
			a.quit = true
		}
		return false
	case scrList:
		return a.keyList(ev)
	case scrAdd:
		return a.keyAdd(ev)
	case scrReceipts:
		return a.keyReceipts(ev)
	case scrExport:
		return a.keyExport(ev)
	case scrImport:
		return a.keyImport(ev)
	}
	return false
}

// onTimer runs whichever deadlines fired. Order is clip-then-idle so an
// expiry that lands on the same tick as the lock still clears the shared
// buffer before the session material is wiped.
func (a *app) onTimer() bool {
	now := nowFn()
	idle, clip, tick := a.m.dl.expired(now)
	changed := false
	if clip {
		a.expireClip()
		changed = true
	}
	if idle {
		a.lockSession(true)
		changed = true
	}
	if tick {
		// The countdown's periodic repaint: re-arm happens in rearm below
		// — the tick stays live only while a totp row is on the list face.
		changed = true
	}
	a.rearm()
	return changed
}

// expireClip is the 30-second lease end: pull the buffer, apply the
// compare-before-clear rule, and say exactly what happened. A failed pull
// still clears — the alternative is a secret stranded in a buffer we could
// not read, and clobbering a stranger's one stale copy is the smaller harm.
func (a *app) expireClip() {
	a.m.dl.stopClip()
	buf, ok := a.pullSel()
	kept := ok && !a.m.ctag.holds(buf)
	zero(buf)
	a.m.ctag.wipe()
	if kept {
		vi.ConsoleLine(markerKept)
		a.status = "clipboard changed hands — kept"
		return
	}
	if a.publishSel([]byte(clearBytes)) {
		vi.ConsoleLine(markerExpired)
		a.status = "clipboard cleared"
		notifyFn(a.ta, "clipboard cleared")
		return
	}
	vi.ConsoleLine(markerClipRef)
	a.status = "clipboard clear refused"
}

// publishSel is SelPublish with one restage-and-repost. A bound request
// whose ack never lands (#2260's documented lost-ack/full-ring hazard —
// observed on leg 02: the seat stored len=6, the ack never matched, the
// challenge-resend then met a staging file the first serve had already
// consumed and refused `missing`) is retried through the same call —
// which restages the envelope — so the re-sent request has its payload
// back. A stored-then-retried publish is an idempotent overwrite of the
// same buffer with the same bytes.
func (a *app) publishSel(text []byte) bool {
	if selPublish(uint32(a.ta.Win), text, appName) {
		return true
	}
	return selPublish(uint32(a.ta.Win), text, appName)
}

// pullSel is RequestSelPaste with one retry — the pull's ack rides the same
// lossy ring, and a false here feeds the compare-before-clear rule's
// clear-anyway arm, so one retry buys back the honest read.
func (a *app) pullSel() ([]byte, bool) {
	if buf, ok := selPull(uint32(a.ta.Win), appName); ok {
		return buf, true
	}
	return selPull(uint32(a.ta.Win), appName)
}

// lockSession wipes the session and returns to the locked face. The clip
// deadline is deliberately untouched — the shared buffer still holds the
// plaintext we put there and the lease still runs.
func (a *app) lockSession(idle bool) {
	a.m.lock()
	a.pass.clear()
	a.conf.clear()
	a.focus = 0
	a.add[0].clear()
	a.add[1].clear()
	a.add[2].clear()
	a.add[3].clear()
	a.picking = false // a lock closes the picker with the faces under it
	a.pick.Open = false
	if idle {
		vi.ConsoleLine(markerIdle)
		a.status = "locked after 5 idle minutes"
		notifyFn(a.ta, "vault locked")
	} else {
		vi.ConsoleLine(markerLocked)
		a.status = "locked"
	}
}

// save reseals the session under the SAME salt and iteration count the
// unlock proved, with a fresh nonce per publish, through WriteFileSafe — a
// crash keeps the old file, never a half-written one.
func (a *app) save() bool {
	nonce := make([]byte, nonceLen)
	if !randFill(nonce) {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrENOSYS)))
		return false
	}
	file, err := sealWithKey(fileMagic, fileVersion, a.m.key, a.m.salt, nonce, a.m.iters, a.m.entries)
	if err != nil {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return false
	}
	defer zero(file)
	if rc := writeSafe(a.path, file); rc < 0 {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(rc))
		return false
	}
	// D16: the vault is private to its owner — a fresh publish lands the
	// guest default 0644, so pull it to 0600 (the agent's other-triplet
	// read must never reach the ciphertext). The chmod is owner-only;
	// this process wrote the file, so the refusal cannot fire honestly —
	// report the kernel's errno if it does.
	if rc := fileMode(a.path, 0o600); rc < 0 {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(rc))
	}
	// The published frame is also the bytes a same-session unlock opens:
	// on the create path nothing ever read the file off disk, so without
	// this a lock->unlock pair meets parseHeader(nil) -> bad file. It is
	// the sealed text — ciphertext is not secret material to shed.
	a.file = append(a.file[:0], file...)
	vi.ConsoleLine(markerSaved)
	return true
}

// --- the faces -------------------------------------------------------------

func (a *app) fields() []*field {
	if a.m.scr == scrNew || a.m.scr == scrExport {
		return []*field{&a.pass, &a.conf}
	}
	return []*field{&a.pass}
}

// keyField feeds one key to the field list of a passphrase face: printable
// text inserts, backspace/delete erase, tab/return either advance the focus
// or run submit (the last field). Escape is the caller's business.
func (a *app) keyField(ev vi.Event, submit func()) bool {
	fs := a.fields()
	f := fs[a.focus]
	switch ev.Arg0 {
	case hidUp:
		if a.focus > 0 {
			a.focus--
			return true
		}
	case hidDown, hidTab:
		if a.focus < len(fs)-1 {
			a.focus++
			return true
		}
	}
	if ev.Arg1 == codeTab {
		if a.focus < len(fs)-1 {
			a.focus++
			return true
		}
	}
	if ev.Arg1 == codeBackspace || ev.Arg1 == codeDelete {
		return f.backspace()
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		if a.focus < len(fs)-1 {
			a.focus++
			return true
		}
		submit()
		return true
	}
	if r, ok := printable(ev); ok {
		return f.insert(r)
	}
	return false
}

func (a *app) keyNew(ev vi.Event) bool {
	if ev.Arg0 == hidEsc {
		a.quit = true
		return false
	}
	return a.keyField(ev, a.create)
}

func (a *app) keyLocked(ev vi.Event) bool {
	if ev.Arg0 == hidEsc {
		a.quit = true
		return false
	}
	return a.keyField(ev, a.unlock)
}

// unlock is the locked face's submit: open the stored file under the typed
// passphrase. The refusal is exactly one line — wrong passphrase and a
// tampered seal are the same answer by design.
func (a *app) unlock() {
	pass := append([]byte(nil), a.pass.buf...)
	defer zero(pass)
	entries, key, salt, iters, err := open(pass, a.file)
	a.pass.clear()
	if err == errBadFile {
		a.m.scr = scrBadFile
		vi.ConsoleLine(markerBad)
		return
	}
	if err != nil {
		a.receipt(actUnlockFail, nil)
		vi.ConsoleLine(markerUnlockBad)
		a.status = "unlock failed"
		return
	}
	a.m.unlocked(entries, key, salt, iters, nowFn())
	a.receipt(actUnlock, nil)
	a.rearm()
	a.status = ""
	vi.ConsoleLine(markerUnlocked + vi.Itoa64(int64(len(entries))))
	if a.m.hasTotp() {
		a.clockMarker()
	}
}

// create is the new-vault submit: a matching pair, the measured iteration
// count (~1 s of PBKDF2 on this VM, recorded in the header), CSPRNG salt and
// nonce, sealed and published.
func (a *app) create() {
	if !equalBytes(a.pass.buf, a.conf.buf) || len(a.pass.buf) == 0 {
		a.pass.clear()
		a.conf.clear()
		a.focus = 0
		vi.ConsoleLine(markerMismatch)
		a.status = "passphrases do not match"
		return
	}
	pass := append([]byte(nil), a.pass.buf...)
	defer zero(pass)
	a.pass.clear()
	a.conf.clear()

	salt := make([]byte, saltLen)
	nonce := make([]byte, nonceLen)
	if !randFill(salt) || !randFill(nonce) {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrENOSYS)))
		return
	}
	// The measurement is one calibration derive; calibrateIterations scales
	// it to about a second and clamps it honest.
	start := nowFn()
	probe, err := deriveKey(pass, salt, calibrateIters)
	iters := calibrateIterations(nowFn() - start)
	zero(probe)
	if err != nil {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	key, err := deriveKey(pass, salt, iters)
	if err != nil {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	if !ensureDirs(a.path) {
		// ensureDirs already printed the refusal with its rc.
		zero(key)
		return
	}
	a.m.unlocked(nil, key, salt, iters, nowFn())
	vi.ConsoleLine(markerIters + vi.Itoa64(int64(iters)))
	if !a.save() {
		// The session exists but the file did not publish: the honest face
		// is still the unlocked list — the save marker says the disk side.
		a.rearm()
		vi.ConsoleLine(markerUnlocked + vi.Itoa64(0))
		return
	}
	a.rearm()
	vi.ConsoleLine(markerUnlocked + vi.Itoa64(0))
}

// ensureDirs creates the /host/<APP> directory chain — the same EEXIST-is-a-
// pass triple the recorder uses, and the same mount-root skip: segs[1] is
// the mount itself ("/host"), which answers the mkdir triple with EINVAL,
// not EEXIST — it is never "created". The file-cap app's WriteFileSafe
// reports the open error on the write either way; this only makes the
// common case land.
func ensureDirs(filePath string) bool {
	segs := strings.Split(filePath, "/")
	dir := ""
	for i := 1; i < len(segs)-1; i++ {
		dir += "/" + segs[i]
		if i == 1 {
			continue
		}
		h, rc := fileOpen(dir, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
		if rc >= 0 {
			fileClose(h)
		} else if rc != int64(vi.ErrFileExists) {
			vi.ConsoleLine(markerSaveErr + vi.Itoa64(rc) + " " + dir)
			return false
		}
	}
	return true
}

func (a *app) keyList(ev vi.Event) bool {
	if ev.Flags&modCtrl != 0 && (ev.Arg1 == keyCtrlL || ev.Arg1 == keyL) {
		a.lockSession(false)
		a.rearm()
		return true
	}
	switch ev.Arg0 {
	case hidEsc:
		// Escape on the unlocked face LOCKS — the safe direction. Quit lives
		// one screen deeper, on the locked face.
		a.lockSession(false)
		a.rearm()
		return true
	case hidUp:
		return a.m.move(-1)
	case hidDown:
		return a.m.move(1)
	}
	switch ev.Arg1 {
	case 'r', codeReturn, codeNewline:
		if a.m.toggleReveal() {
			if a.m.revealed(a.m.sel) {
				a.receipt(actReveal, a.m.entries[a.m.sel].name)
				vi.ConsoleLine(markerRevealed)
				a.clockMarker()
			} else {
				vi.ConsoleLine(markerHidden)
			}
			return true
		}
	case 'c':
		a.copy()
		return true
	case 'v':
		a.openReceipts()
		return true
	case 'a':
		a.m.scr = scrAdd
		a.focus = 0
		a.status = ""
		return true
	case 'e':
		a.openPick(appkit.PickSave)
		return true
	case 'i':
		a.openPick(appkit.PickOpen)
		return true
	}
	return false
}

// openPick raises the shared file picker over the list face — save mode for
// the GVLX export, open mode for the bundle import. The start directory is
// the vault's own /host/GOVAULT dir.
func (a *app) openPick(kind appkit.PickerKind) {
	dir := dirOf(a.path)
	if dir == "" {
		dir = "/host"
	}
	a.pick = appkit.NewFilePicker(kind, dir)
	a.picking = true
	a.status = ""
}

// pickerKey routes one key to the open picker and lands its Result: a save
// pick moves to the export passphrase face, an open pick to the import one,
// and a cancel hands the keyboard back to the list. The picked path is a
// marker receipt like GOEDIT's — a path is not secret material.
func (a *app) pickerKey(ev vi.Event) bool {
	if _, done := a.pick.HandleKey(ev); !done {
		return true
	}
	res := a.pick.Result
	a.picking = false
	if res == "cancel" {
		vi.ConsoleLine(markerPickCancel)
		return true
	}
	a.pickPath = res
	a.pass.clear()
	a.conf.clear()
	a.focus = 0
	if a.pick.Kind == appkit.PickSave {
		vi.ConsoleLine(markerPickSave + res)
		a.m.scr = scrExport
	} else {
		vi.ConsoleLine(markerPickOpen + res)
		a.m.scr = scrImport
	}
	return true
}

// dirOf strips a path's last segment; the share root is the floor (the same
// rule the picker keeps internally).
func dirOf(path string) string {
	i := strings.LastIndexByte(path, '/')
	if i <= len("/host") {
		return "/host"
	}
	return path[:i]
}

// --- the bundle faces (M156c) -------------------------------------------------

func (a *app) keyExport(ev vi.Event) bool {
	if ev.Arg0 == hidEsc {
		a.pass.clear()
		a.conf.clear()
		a.m.scr = scrList
		a.status = "export cancelled"
		return true
	}
	return a.keyField(ev, a.exportBundle)
}

func (a *app) keyImport(ev vi.Event) bool {
	if ev.Arg0 == hidEsc {
		a.pass.clear()
		a.m.scr = scrList
		a.status = "import cancelled"
		return true
	}
	return a.keyField(ev, a.importBundle)
}

// exportBundle seals the session under the bundle passphrase — its own salt,
// nonce and calibrated iteration count, never the vault's key — and writes
// the GVLX frame through WriteFileSafe at the picked path. Marker per the
// card: 'govault: export n=<entries> bytes=<n>'.
func (a *app) exportBundle() {
	if !equalBytes(a.pass.buf, a.conf.buf) || len(a.pass.buf) == 0 {
		a.pass.clear()
		a.conf.clear()
		a.focus = 0
		vi.ConsoleLine(markerMismatch)
		a.status = "passphrases do not match"
		return
	}
	pass := append([]byte(nil), a.pass.buf...)
	a.pass.clear()
	a.conf.clear()
	defer zero(pass)

	salt := make([]byte, saltLen)
	nonce := make([]byte, nonceLen)
	if !randFill(salt) || !randFill(nonce) {
		vi.ConsoleLine(markerExportErr + vi.Itoa64(-int64(vi.ErrENOSYS)))
		return
	}
	start := nowFn()
	probe, err := deriveKey(pass, salt, calibrateIters)
	iters := calibrateIterations(nowFn() - start)
	zero(probe)
	if err != nil {
		vi.ConsoleLine(markerExportErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	key, err := deriveKey(pass, salt, iters)
	if err != nil {
		vi.ConsoleLine(markerExportErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	bundle, err := sealWithKey(exportMagic, fileVersion, key, salt, nonce, iters, a.m.entries)
	zero(key)
	if err != nil {
		vi.ConsoleLine(markerExportErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	if rc := writeSafe(a.pickPath, bundle); rc < 0 {
		zero(bundle)
		vi.ConsoleLine(markerExportErr + vi.Itoa64(rc))
		a.status = "export refused"
		return
	}
	a.receipt(actExport, nil)
	vi.ConsoleLine(markerExport + vi.Itoa64(int64(len(a.m.entries))) +
		" bytes=" + vi.Itoa64(int64(len(bundle))))
	zero(bundle)
	a.m.scr = scrList
	a.status = "exported " + vi.Itoa64(int64(len(a.m.entries))) + " entries"
}

// importBundle opens the picked GVLX under its own passphrase and merges it
// into the session: new names append, a name the vault already holds keeps
// the vault's copy and counts skipped — nothing is silently overwritten. The
// bundle's derived key is used for the open and then dropped: the vault's
// own key stays the session's.
func (a *app) importBundle() {
	pass := append([]byte(nil), a.pass.buf...)
	a.pass.clear()
	defer zero(pass)

	data, rc := readAll(a.pickPath, maxFile+1)
	if rc < 0 {
		vi.ConsoleLine(markerImportErr + vi.Itoa64(rc))
		a.status = "import refused"
		return
	}
	entries, key, _, _, err := openExport(pass, data)
	zero(key)
	if err == errBadFile {
		vi.ConsoleLine(markerImportBad)
		a.status = "import: not a GVLX bundle"
		return
	}
	if err != nil {
		vi.ConsoleLine(markerImportErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		a.status = "import: unlock failed"
		return
	}
	added, skipped := a.m.mergeEntries(entries)
	zeroEntries(entries)
	a.receipt(actImport, []byte("added="+vi.Itoa64(int64(added))+" skipped="+vi.Itoa64(int64(skipped))))
	a.save()
	vi.ConsoleLine(markerImport + "added=" + vi.Itoa64(int64(added)) +
		" skipped=" + vi.Itoa64(int64(skipped)))
	if a.m.hasTotp() {
		a.clockMarker()
	}
	a.m.scr = scrList
	a.status = "imported " + vi.Itoa64(int64(added)) + ", skipped " +
		vi.Itoa64(int64(skipped))
}

// copy publishes the selected secret to the seat's primary selection and
// arms the 30-second lease. The refusal is the seat's answer — a missing
// selection=primary opt-in or no seat — named, never assumed.
func (a *app) copy() {
	if a.m.sel < 0 || a.m.sel >= len(a.m.entries) {
		return
	}
	secret := a.m.entries[a.m.sel].secret
	if !a.publishSel(secret) {
		vi.ConsoleLine(markerCopyErr)
		a.status = "copy refused"
		return
	}
	a.m.ctag = setClipTag(secret)
	a.m.dl.armClip(nowFn())
	a.rearm()
	a.receipt(actCopy, a.m.entries[a.m.sel].name)
	vi.ConsoleLine(markerCopied)
	a.status = "copied — clears in 30 s"
	notifyFn(a.ta, "copied; clears 30s")
}

func (a *app) keyAdd(ev vi.Event) bool {
	fs := []*field{&a.add[0], &a.add[1], &a.add[2], &a.add[3]}
	f := fs[a.focus]
	switch ev.Arg0 {
	case hidEsc:
		a.add[0].clear()
		a.add[1].clear()
		a.add[2].clear()
		a.add[3].clear()
		a.m.scr = scrList
		a.status = "add cancelled"
		return true
	case hidUp:
		if a.focus > 0 {
			a.focus--
			return true
		}
	case hidDown, hidTab:
		if a.focus < len(fs)-1 {
			a.focus++
			return true
		}
	}
	if ev.Arg1 == codeTab {
		if a.focus < len(fs)-1 {
			a.focus++
			return true
		}
	}
	if ev.Arg1 == codeBackspace || ev.Arg1 == codeDelete {
		return f.backspace()
	}
	if ev.Arg1 == codeReturn || ev.Arg1 == codeNewline {
		if a.focus < len(fs)-1 {
			a.focus++
			return true
		}
		a.commitAdd()
		return true
	}
	if r, ok := printable(ev); ok {
		return f.insert(r)
	}
	return false
}

// commitAdd stores the four fields as an entry and publishes the vault. The
// field buffers are cleared (zeroed) either way — the session copy is the
// entry's own clone. A non-empty totp field must parse: the refusal names
// itself and keeps the entry unstored, so a mistyped seed never lands half
// in the vault.
func (a *app) commitAdd() {
	var totp []byte
	if len(a.add[3].buf) > 0 {
		t, ok := parseOTPSecret(a.add[3].buf)
		if !ok {
			a.add[0].clear()
			a.add[1].clear()
			a.add[2].clear()
			a.add[3].clear()
			a.focus = 0
			vi.ConsoleLine(markerRefused + "bad totp")
			a.status = "totp: not a base32 seed"
			a.m.scr = scrList
			return
		}
		totp = t
	}
	ok := a.m.addEntry(a.add[0].buf, a.add[1].buf, a.add[2].buf, totp)
	zero(totp)
	a.add[0].clear()
	a.add[1].clear()
	a.add[2].clear()
	a.add[3].clear()
	a.focus = 0
	if !ok {
		vi.ConsoleLine(markerRefused + "empty name")
		a.status = "name required"
		return
	}
	vi.ConsoleLine(markerAdded)
	a.save()
	a.m.scr = scrList
	a.status = ""
}

// receipt appends one row to the vault's own receipts file: time, action,
// entry name — never secret material (M148b). The write is a real append,
// not a rewrite — the file is a log, and WriteFilePublish's append arm never
// truncates it. The /host/GOVAULT directory already exists at every receipt
// site (a vault file lives there, or create() just made it), so no mkdir
// pass runs here — a refused append names itself by kernel code, and the
// action it records still stands: the audit trail is a witness, not a gate.
func (a *app) receipt(action string, name []byte) {
	line := receiptLine(timeFn(), action, string(name))
	if rc := rcptAppend(receiptPath, line); rc < 0 {
		vi.ConsoleLine(markerRcptRef + vi.Itoa64(rc))
		a.status = "receipt refused"
	}
}

// openReceipts loads the receipts file and moves to the Receipts face. An
// absent file is an empty view, not an error — a vault that was never
// unlocked has honestly earned no receipts. The serial listing mirrors what
// the face draws (index + action per row, never a name); `receipts end`
// prints LAST so a gate that ends the run on it still sees every row.
func (a *app) openReceipts() {
	data, rc := readAll(receiptPath, maxReceipts)
	if rc < 0 && rc != -int64(vi.ErrENOENT) {
		vi.ConsoleLine(markerRcptRef + vi.Itoa64(rc))
		a.status = "receipts refused"
		return
	}
	rows := parseReceipts(data)
	a.m.rcpts = rows
	a.m.scr = scrReceipts
	a.status = ""
	vi.ConsoleLine(markerRcpts + vi.Itoa64(int64(len(rows))))
	for i := range rows {
		vi.ConsoleLine(markerRcpt + vi.Itoa64(int64(i)) + " " + rows[i].action)
	}
	vi.ConsoleLine(markerRcptsEnd)
}

func (a *app) keyReceipts(ev vi.Event) bool {
	if ev.Flags&modCtrl != 0 && (ev.Arg1 == keyCtrlL || ev.Arg1 == keyL) {
		a.lockSession(false)
		a.rearm()
		return true
	}
	switch ev.Arg0 {
	case hidEsc:
		a.m.scr = scrList
		return true
	}
	if ev.Arg1 == 'v' {
		a.m.scr = scrList
		return true
	}
	return false
}

// --- save_state (M125a, hooked M156c) -----------------------------------------

// saveBlob is the Config.SaveState hook: the open vault's path and nothing
// else. Never a passphrase, key, entry or revealed secret — the blob is a
// convenience pointer, and a restored vault starts locked because the path
// is all it learned.
func (a *app) saveBlob() []byte {
	return encodeState(a.path)
}

// applyState is the Config.RestoreState hook: the seat hands back the stored
// path; a sane share path becomes the vault this boot opens. load() runs
// after Init, so the restored path feeds the same face selection a fresh
// boot gets — locked when the file exists.
func (a *app) applyState(blob []byte) {
	if path, ok := decodeState(blob); ok {
		a.path = path
	}
}

// printable maps a key event to its text rune — the same arg1 contract the
// notepad documents (Unicode codepoint, ASCII printable + Latin-1 up).
func printable(ev vi.Event) (rune, bool) {
	if ev.Kind != vi.EvKeyDown || ev.Flags&modCtrl != 0 {
		return 0, false
	}
	if (ev.Arg1 >= 0x20 && ev.Arg1 < 0x7f || ev.Arg1 >= 0xa0) &&
		ev.Arg1 <= utf8.MaxRune &&
		(ev.Arg1 < 0xd800 || ev.Arg1 > 0xdfff) {
		return rune(ev.Arg1), true
	}
	return 0, false
}

// --- drawing ---------------------------------------------------------------

const (
	chromeH = 24
	fieldH  = 18
	rowH    = 14
	pad     = 12
)

func (a *app) fill(cv widgets.Canvas, x, y, w, h int, rgb uint32) {
	if cv == nil || w <= 0 || h <= 0 {
		return
	}
	cv.FillRect(widgets.Rect{X: x, Y: y, W: w, H: h}, draw.Opaque(rgb))
}

// text paints a string in the 8x8 face, one lit run per glyph row — NOTE's
// raster discipline (the webrender font package without its layout weight).
func (a *app) text(cv widgets.Canvas, x, y int, s string, rgb uint32) {
	cx := x
	for _, ch := range s {
		g := font.Glyph8(ch)
		for row := 0; row < 8; row++ {
			bits := g[row]
			col := 0
			for col < 8 {
				if bits&(1<<uint(col)) == 0 {
					col++
					continue
				}
				run := 1
				for col+run < 8 && bits&(1<<uint(col+run)) != 0 {
					run++
				}
				a.fill(cv, cx+col, y+row, run, 1, rgb)
				col += run
			}
		}
		cx += font.Advance(1)
	}
}

func (a *app) draw() {
	cv := a.ta.Canvas()
	if cv == nil {
		return
	}
	tok := theme.Current
	w, h := int(a.ta.W), int(a.ta.H)
	if w <= 0 || h <= 0 {
		w, h = natW, natH
	}
	a.fill(cv, 0, 0, w, chromeH, tok.Surface)
	a.fill(cv, 0, chromeH, w, h-chromeH, tok.Bg)

	state := "LOCKED"
	if a.m.scr == scrList || a.m.scr == scrAdd || a.m.scr == scrReceipts {
		state = "OPEN"
	}
	a.text(cv, pad, 8, appTitle+"   "+state, tok.Ink)
	a.fill(cv, 0, chromeH-1, w, 1, tok.Rule)

	switch a.m.scr {
	case scrNew:
		a.drawNew(cv, w, h)
	case scrLocked:
		a.drawLocked(cv, w, h)
	case scrBadFile:
		a.drawBadFile(cv, w, h)
	case scrList:
		a.drawList(cv, w, h)
	case scrAdd:
		a.drawAdd(cv, w, h)
	case scrReceipts:
		a.drawReceipts(cv, w, h)
	case scrExport:
		a.drawExport(cv, w, h)
	case scrImport:
		a.drawImport(cv, w, h)
	}

	// The picker is a modal plate over the list face — painted last, the
	// same overlay rule GOEDIT keeps.
	if a.picking {
		a.pick.Draw(cv)
	}

	if a.status != "" {
		a.text(cv, pad, h-16, a.status, tok.InkMuted)
	}
}

// fieldRow paints one labeled input row: label, a plated line of the
// shown() text, and a caret tick on the focused field.
func (a *app) fieldRow(cv widgets.Canvas, y int, f *field, focused bool) {
	tok := theme.Current
	a.text(cv, pad, y+5, f.label, tok.Muted)
	fx := pad + 96
	fw := int(a.ta.W) - fx - pad
	if fw < 40 {
		fw = 40
	}
	face := tok.Surface
	if focused {
		face = tok.BtnIdle
	}
	a.fill(cv, fx, y, fw, fieldH, face)
	a.fill(cv, fx, y+fieldH-1, fw, 1, tok.Border)
	a.text(cv, fx+4, y+5, f.shown(), tok.Ink)
	if focused {
		caretX := fx + 4 + font.Advance(1)*utf8.RuneCount(f.buf)
		a.fill(cv, caretX, y+4, 2, fieldH-8, tok.Accent)
	}
}

func (a *app) drawNew(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "No vault yet — choose a passphrase", tok.Text)
	a.fieldRow(cv, chromeH+44, &a.pass, a.focus == 0)
	a.fieldRow(cv, chromeH+44+fieldH+10, &a.conf, a.focus == 1)
	a.text(cv, pad, h-32, "tab next · ⏎ create · esc quit", tok.Muted)
}

func (a *app) drawLocked(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "Vault is locked", tok.Text)
	a.fieldRow(cv, chromeH+44, &a.pass, true)
	a.text(cv, pad, h-32, "⏎ unlock · esc quit", tok.Muted)
}

func (a *app) drawBadFile(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "vault: bad file", tok.Text)
	a.text(cv, pad, chromeH+36, "the file is not a GVLT vault", tok.Muted)
	a.text(cv, pad, h-32, "esc quit", tok.Muted)
}

// drawList paints the entry rows. A hidden secret is a FIXED bullet width —
// the length of a secret is information too — and only the revealed row's
// own bytes are painted.
func (a *app) drawList(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	if len(a.m.entries) == 0 {
		a.text(cv, pad, chromeH+16, "Vault is empty", tok.Muted)
	}
	y := chromeH + 8
	for i := range a.m.entries {
		if y+rowH > h-40 {
			break
		}
		if i == a.m.sel {
			a.fill(cv, 0, y, w, rowH, tok.Surface)
			a.fill(cv, 0, y, 3, rowH, tok.Accent)
		}
		e := &a.m.entries[i]
		name := string(e.name)
		if len(name) > 20 {
			name = name[:20]
		}
		a.text(cv, pad, y+3, name, tok.Text)
		secret := "********"
		if a.m.revealed(i) {
			secret = string(e.secret)
		}
		a.text(cv, pad+176, y+3, secret, tok.Muted)
		// M156c: a seeded entry shows its live six-digit code and the
		// seconds left in the step — the code is a render of the seed, not
		// the stored text, so a stale frame can never show a dead code.
		if len(e.totp) > 0 {
			code := "------ --s"
			if key, ok := decodeSeed(e.totp); ok {
				if v, ok := totpAt(key, timeFn(), 6); ok {
					code = sixDigits(v) + " " + vi.Itoa64(int64(totpLeft(timeFn()))) + "s"
				}
				zero(key)
			}
			a.text(cv, pad+288, y+3, code, tok.Accent)
		}
		note := string(e.note)
		if len(note) > 14 {
			note = note[:14]
		}
		a.text(cv, pad+376, y+3, note, tok.InkMuted)
		y += rowH
	}
	a.text(cv, pad, h-32, "a add · r reveal · c copy · e export · i import · v receipts · ctrl-l lock", tok.Muted)
}

// sixDigits renders a TOTP value as its zero-padded six-digit string.
func sixDigits(v uint32) string {
	var b [6]byte
	for i := 5; i >= 0; i-- {
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[:])
}

// drawReceipts lists the loaded receipts — the newest rows at the bottom,
// tail-windowed to fit the face (a log's freshest rows are the ones a
// reviewer is reaching for). A corrupt row is shown verbatim: hiding it
// would pretend the file never carried it.
func (a *app) drawReceipts(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "Receipts", tok.Text)
	rows := a.m.rcpts
	if len(rows) == 0 {
		a.text(cv, pad, chromeH+36, "no receipts yet", tok.Muted)
	}
	fit := (h - 40 - (chromeH + 8)) / rowH
	start := 0
	if fit > 0 && len(rows) > fit {
		start = len(rows) - fit
	}
	y := chromeH + 8
	for i := start; i < len(rows); i++ {
		r := &rows[i]
		if !r.ok {
			a.text(cv, pad, y+3, r.raw, tok.Muted)
			y += rowH
			continue
		}
		a.text(cv, pad, y+3, clockfmt.Format(r.epoch, clockfmt.UTC), tok.Muted)
		a.text(cv, pad+204, y+3, r.action, tok.Text)
		name := r.name
		if len(name) > 24 {
			name = name[:24]
		}
		a.text(cv, pad+292, y+3, name, tok.InkMuted)
		y += rowH
	}
	a.text(cv, pad, h-32, "v back · ctrl-l lock · esc back", tok.Muted)
}

func (a *app) drawAdd(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "New entry", tok.Text)
	a.fieldRow(cv, chromeH+44, &a.add[0], a.focus == 0)
	a.fieldRow(cv, chromeH+44+fieldH+10, &a.add[1], a.focus == 1)
	a.fieldRow(cv, chromeH+44+2*(fieldH+10), &a.add[2], a.focus == 2)
	a.fieldRow(cv, chromeH+44+3*(fieldH+10), &a.add[3], a.focus == 3)
	a.text(cv, pad, chromeH+44+3*(fieldH+10)+fieldH+8, "totp: base32 seed or otpauth:// URI (optional)", tok.Muted)
	a.text(cv, pad, h-32, "tab next · ⏎ store · esc cancel", tok.Muted)
}

// drawExport is the bundle-passphrase face after a save pick: two masked
// fields guard the GVLX write, same shape as the create pair.
func (a *app) drawExport(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "Export vault to "+a.pickPath, tok.Text)
	a.text(cv, pad, chromeH+36, "bundle passphrase (separate from the vault's)", tok.Muted)
	a.fieldRow(cv, chromeH+64, &a.pass, a.focus == 0)
	a.fieldRow(cv, chromeH+64+fieldH+10, &a.conf, a.focus == 1)
	a.text(cv, pad, h-32, "tab next · ⏎ export · esc cancel", tok.Muted)
}

// drawImport is the bundle-passphrase face after an open pick: one masked
// field, then the merge.
func (a *app) drawImport(cv widgets.Canvas, w, h int) {
	tok := theme.Current
	a.text(cv, pad, chromeH+16, "Import bundle "+a.pickPath, tok.Text)
	a.fieldRow(cv, chromeH+64, &a.pass, true)
	a.text(cv, pad, h-32, "⏎ import · esc cancel", tok.Muted)
}
