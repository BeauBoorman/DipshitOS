// Command govault is GOVAULT.ELF — M148a (issue #2804), receipts M148b
// (#2805), M156c (#2933): the secrets store gets a face, a bundle format and
// a state hook. One unlock-gated vault file (GVLT framing, PBKDF2-HMAC-SHA256
// -> AES-256-GCM, written through vi.WriteFileSafe so a crash keeps the old
// file), a masked passphrase field, a per-vaultlib.Entry reveal, a copy that expires,
// an idle lock, and a plaintext receipts file with its own read-only face.
// M156c adds: GVLX export/import bundles (same frame, distinct magic, their
// own passphrase) through the shared picker, a merge that never overwrites,
// the M125a save_state blob (the vault's path — nothing secret), and a TOTP
// column for entries carrying an otpauth seed behind the hmac/sha1 + clock
// probe. The codec lives in vaultlib, the receipt row codec in receipts.go,
// the TOTP math and seed intake in totp.go, the state blob codec in
// state.go, the pure session model in model.go, the vault session in
// session.go, the verb loop in verbs.go and the drawing in ui.go; this
// file owns the constants, the marker vocabulary, the seams and main.
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
// Secrets discipline: vaultlib.Entry fields stay in []byte end to end so lock() can
// zero them; the passphrase buffer is zeroed on every outcome; the clipboard
// compare runs against a sha256 tag, never a kept plaintext; and no serial
// marker ever carries a name, a secret, a note or a passphrase — the
// marker vocabulary below is the whole observable surface.
//
// Every marker is printed only AFTER the call it names returned, so a gate
// asserting one can only pass when the work actually ran.
package main

import (
	"virelai/appkit"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vaultlib"
	"virelai/vi"
	"virelai/vsys"
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
	// of time, action and vaultlib.Entry name — never secret material, and never
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
	notifyFn = func(ta *tabapp.TabApp, text string) bool { return ta.Notify(text) }
)

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
	a.add[0] = newField("name", vaultlib.MaxName, false)
	a.add[1] = newField("secret", vaultlib.MaxSecret, true)
	a.add[2] = newField("note", vaultlib.MaxNote, false)
	a.add[3] = newField("totp", vaultlib.MaxTotp, true)

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
