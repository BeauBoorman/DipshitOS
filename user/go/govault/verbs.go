// verbs.go — the verb loop: handle() routes one event to the face that owns
// it, the key* handlers are the faces' input contracts, and the verbs they
// invoke (unlock, create, copy, commitAdd, exportBundle, importBundle,
// receipt, openReceipts) carry the card's marker vocabulary to the serial
// line. Session mechanics — save, rearm, lock, the clipboard lease — live
// in session.go; this file calls them, never reimplements them.
package main

import (
	"strings"
	"unicode/utf8"

	"virelai/appkit"
	"virelai/vaultlib"
	"virelai/vi"
)

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
	defer vaultlib.Zero(pass)
	entries, key, salt, iters, err := vaultlib.Open(pass, a.file)
	a.pass.clear()
	if err == vaultlib.ErrBadFile {
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
	if !vaultlib.EqualBytes(a.pass.buf, a.conf.buf) || len(a.pass.buf) == 0 {
		a.pass.clear()
		a.conf.clear()
		a.focus = 0
		vi.ConsoleLine(markerMismatch)
		a.status = "passphrases do not match"
		return
	}
	pass := append([]byte(nil), a.pass.buf...)
	defer vaultlib.Zero(pass)
	a.pass.clear()
	a.conf.clear()

	salt := make([]byte, vaultlib.SaltLen)
	nonce := make([]byte, vaultlib.NonceLen)
	if !randFill(salt) || !randFill(nonce) {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrENOSYS)))
		return
	}
	// The measurement is one calibration derive; vaultlib.CalibrateIterations scales
	// it to about a second and clamps it honest.
	start := nowFn()
	probe, err := vaultlib.DeriveKey(pass, salt, vaultlib.CalibrateIters)
	iters := vaultlib.CalibrateIterations(nowFn() - start)
	vaultlib.Zero(probe)
	if err != nil {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	key, err := vaultlib.DeriveKey(pass, salt, iters)
	if err != nil {
		vi.ConsoleLine(markerSaveErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	if !ensureDirs(a.path) {
		// ensureDirs already printed the refusal with its rc.
		vaultlib.Zero(key)
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
				a.receipt(actReveal, a.m.entries[a.m.sel].Name)
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
	if !vaultlib.EqualBytes(a.pass.buf, a.conf.buf) || len(a.pass.buf) == 0 {
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
	defer vaultlib.Zero(pass)

	salt := make([]byte, vaultlib.SaltLen)
	nonce := make([]byte, vaultlib.NonceLen)
	if !randFill(salt) || !randFill(nonce) {
		vi.ConsoleLine(markerExportErr + vi.Itoa64(-int64(vi.ErrENOSYS)))
		return
	}
	start := nowFn()
	probe, err := vaultlib.DeriveKey(pass, salt, vaultlib.CalibrateIters)
	iters := vaultlib.CalibrateIterations(nowFn() - start)
	vaultlib.Zero(probe)
	if err != nil {
		vi.ConsoleLine(markerExportErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	key, err := vaultlib.DeriveKey(pass, salt, iters)
	if err != nil {
		vi.ConsoleLine(markerExportErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	bundle, err := vaultlib.SealWithKey(vaultlib.ExportMagic, vaultlib.FileVersion, key, salt, nonce, iters, a.m.entries)
	vaultlib.Zero(key)
	if err != nil {
		vi.ConsoleLine(markerExportErr + vi.Itoa64(-int64(vi.ErrEINVAL)))
		return
	}
	if rc := writeSafe(a.pickPath, bundle); rc < 0 {
		vaultlib.Zero(bundle)
		vi.ConsoleLine(markerExportErr + vi.Itoa64(rc))
		a.status = "export refused"
		return
	}
	a.receipt(actExport, nil)
	vi.ConsoleLine(markerExport + vi.Itoa64(int64(len(a.m.entries))) +
		" bytes=" + vi.Itoa64(int64(len(bundle))))
	vaultlib.Zero(bundle)
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
	defer vaultlib.Zero(pass)

	data, rc := readAll(a.pickPath, vaultlib.MaxFile+1)
	if rc < 0 {
		vi.ConsoleLine(markerImportErr + vi.Itoa64(rc))
		a.status = "import refused"
		return
	}
	entries, key, _, _, err := vaultlib.OpenExport(pass, data)
	vaultlib.Zero(key)
	if err == vaultlib.ErrBadFile {
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
	vaultlib.ZeroEntries(entries)
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
	secret := a.m.entries[a.m.sel].Secret
	if !a.publishSel(secret) {
		vi.ConsoleLine(markerCopyErr)
		a.status = "copy refused"
		return
	}
	a.m.ctag = setClipTag(secret)
	a.m.dl.armClip(nowFn())
	a.rearm()
	a.receipt(actCopy, a.m.entries[a.m.sel].Name)
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

// commitAdd stores the four fields as an vaultlib.Entry and publishes the vault. The
// field buffers are cleared (zeroed) either way — the session copy is the
// vaultlib.Entry's own clone. A non-empty totp field must parse: the refusal names
// itself and keeps the vaultlib.Entry unstored, so a mistyped seed never lands half
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
	vaultlib.Zero(totp)
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
// vaultlib.Entry name — never secret material (M148b). The write is a real append,
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
