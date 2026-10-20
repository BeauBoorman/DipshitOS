// M126e (#2597): the save-to-share download flow — the piece that makes a
// transfer VISIBLE. 's' saves the current page body; a click on a link
// whose target the sniff table already knows is non-text (an image, an
// archive, a binary — anything WEB cannot render as a page) downloads it
// instead of navigating to noise. Both paths land here.
//
// Shape, and why each bound exists:
//
//   - The write is STAGED: the kernel's file stage accepts 2048 bytes per
//     write (fileWriteChunk in vi), so a download commits a few chunks per
//     event-loop pass instead of blocking in the click handler. Progress
//     is then real and observable — a bar in the status line, and a
//     kind-22 row in the seat's notification center when a Go seat is up
//     (vi.NotifyProgress via appkit.Progress.Report). A seatless boot
//     keeps the in-chrome bar; Report's refusal is printed, not hidden.
//   - Cancel has three doors, all landing on cancelDownload: Escape/x
//     (the load-cancel keys, which own "stop the transfer"), the seat
//     row's Cancel (kind 23, polled once per pass beside pollStateAsk),
//     and the window closing. A cancelled or failed write deletes its
//     partial file — a half-download left on the share would look like a
//     completed one.
//   - Completion lands three ways: the ledger row (the same WEB-DOWNLOADS
//     v1 schema 's' always wrote), a kind-12 seat toast naming the file,
//     and an in-chrome plate with OPEN / FOLDER chips — the seat toast's
//     24-byte title cannot carry buttons, so the actions live on the
//     plate. Open dispatches through virelai/mime exactly like GOFILES's
//     openSel (an image lands in GOVIEW); Folder execs GOFILES.ELF at the
//     share root where every WEB-DL-* lands.
//
// One download at a time: downloadOp names the seat row, so a second
// trigger while a write is in flight is refused with a status line, not
// started on a second op.
package main

import (
	"errors"

	"virelai/appkit"
	"virelai/mime"
	"virelai/vi"
	"virelai/webrender"
	"virelai/widgets"
)

const (
	// downloadOp is the kind-22 op id for THE download — single-flight
	// keeps it unique for the row's life.
	downloadOp = 1
	// dlChunksPerPass bounds the staged writes one event-loop pass
	// commits: 8 KiB per pass at the 1 ms download cadence is fast
	// enough to finish promptly and slow enough for the progress surface
	// to be real.
	dlChunksPerPass = 4
	// dlNameMax bounds the share-side name: the kernel path ceiling is
	// 64 bytes, "/host/WEB-DL-" spends 13 of them, and the safe-publish
	// `~` staging temp spends one more.
	dlNameMax = 64 - len("/host/WEB-DL-") - 1
	// dlCap bounds the bytes one download will stage — the same
	// file-channel ceiling ReadFileAll already enforces.
	dlCap = vi.MaxFileBytes
	// The completion plate: bottom-right, above the status line.
	dlToastW = 232
	dlToastH = 42
	dlBarW   = 210
	dlBarH   = 12
)

// The plate's chips, relative to its top-left. Index 2 is the dismiss X.
var dlChips = []struct {
	label string
	r     widgets.Rect
}{
	{"OPEN", widgets.Rect{X: 8, Y: 24, W: 56, H: 14}},
	{"FOLDER", widgets.Rect{X: 72, Y: 24, W: 80, H: 14}},
	{"X", widgets.Rect{X: dlToastW - 22, Y: 4, W: 14, H: 14}},
}

// download is one in-flight or just-completed save. While active, h is the
// open target handle and written is bytes committed; done latches when the
// last chunk lands, and the entry survives on a.dl until the plate is
// dismissed so its Open/Folder chips keep a target.
type download struct {
	target  string
	name    string // the share-side file name (bounded by dlNameMax)
	path    string // /host/WEB-DL-<name>
	body    []byte
	written int
	h       uint32
	active  bool
	done    bool
	prog    appkit.Progress
	mimeID  mime.ID
	lastRep int // last reported percent; reports cross 10% boundaries
}

var errDlUnreadable = errors.New("download: unreadable")

// dlCanvas adapts the browser's filler to the RectCanvas contract
// appkit.Progress.Draw paints on — a fill-only surface keeps the flat v1
// form, which is all the status-line bar needs.
type dlCanvas struct{ v virender }

func (c dlCanvas) FillRect(r widgets.Rect, rgb uint32) {
	c.v.Fill(r.X, r.Y, r.W, r.H, rgb)
}

// wantsDownload reports whether a resolved link target is a download
// rather than a page. The browser renders HTML only: a target whose
// extension is already a known non-text type (mime's byExt stage — no
// head read needed, and none exists yet at click time) is saved to the
// share instead of navigating to markup noise. Text and unknown targets
// keep the navigation path, so .html/.txt/plain links render as before.
func wantsDownload(resolved string) bool {
	switch mime.Sniff(downloadName(resolved), nil) {
	case mime.Image, mime.Audio, mime.Archive, mime.Binary, mime.Document:
		return true
	}
	return false
}

// startDownload begins a save of target. body != nil means the caller
// already holds the bytes (the 's' save of the loaded page); nil fetches
// through fetchResource so file-channel and http(s) targets share the
// redirect/error ledger every other resource uses.
func (a *app) startDownload(target string, body []byte) {
	if a.dl != nil && a.dl.active {
		a.status = "download already in progress"
		a.dirty = true
		return
	}
	if body == nil {
		data, kind := a.fetchResource(target, dlCap)
		if kind != "" {
			vi.ConsoleLine(markerDlFailed + kind + " " + target)
			a.status = "download failed: " + kind
			// M123d (#2578): the fetch failure stands inline — Retry
			// refetches the same target when the kind is transient.
			if bannerRetryable(kind) {
				a.raiseBanner("download", "download failed: "+kind+" — "+target, target,
					appkit.BannerAction{ID: "retry", Label: "Retry"})
			} else {
				a.raiseBanner("", "download failed: "+kind+" — "+target, "")
			}
			a.dirty = true
			return
		}
		body = data
	}
	if len(body) == 0 || len(body) > dlCap {
		vi.ConsoleLine(markerDlFailed + "empty " + target)
		a.status = "download failed: empty"
		a.raiseBanner("", "download failed: empty — "+target, "")
		a.dirty = true
		return
	}
	name := downloadName(target)
	path := downloadFmt + name
	// WriteFileSafe's contract, staged: chunks land on the `~` sacrificial
	// temp across event-loop passes and the live name appears only at the
	// complete, fsynced rename — a crash leaves `WEB-DL-*~` residue, never
	// a torn file the ledger or a reader could take for the download.
	h, rc := vi.FileOpen(path+"~", vi.ModeWrite|vi.ModeCreate)
	if rc < 0 {
		vi.ConsoleLine(markerDlFailed + "file " + path)
		a.status = "download failed"
		// M123d (#2578): the FS refusal stands inline too.
		a.raiseBanner("", "download failed: file "+path, "")
		a.dirty = true
		return
	}
	head := body
	if len(head) > mime.HeadBytes {
		head = head[:mime.HeadBytes]
	}
	d := &download{target: target, name: name, path: path, body: body,
		h: uint32(h), active: true, mimeID: mime.Sniff(name, head), lastRep: -1}
	d.prog = appkit.NewProgress(widgets.Rect{}, len(body))
	d.prog.Op = downloadOp
	d.prog.Label = name
	d.prog.ShowValue = true
	a.dl = d
	vi.ConsoleLine(markerDlStart + name + " bytes=" + itoa(len(body)))
	a.dlReport(true)
	a.status = "downloading " + name
	a.dirty = true
}

// dlStep is the event-loop half of the write: a bounded burst of staged
// chunks per pass, a seat report when the percent crosses a tenth, and
// completion when the stream ends. FileWrite's confirmed count advances
// the offset — a partial write can never corrupt the stream because the
// next chunk resumes where the kernel confirmed.
func (a *app) dlStep() {
	d := a.dl
	if d == nil || !d.active {
		return
	}
	for i := 0; i < dlChunksPerPass && d.written < len(d.body); i++ {
		take := len(d.body) - d.written
		if take > 2048 {
			take = 2048
		}
		n, rc := vi.FileWrite(d.h, d.body[d.written:d.written+take])
		if rc < 0 || n <= 0 {
			a.failDownload("file")
			return
		}
		d.written += n
	}
	d.prog.Set(d.written)
	a.dlReport(false)
	if d.written >= len(d.body) {
		a.finishDownload()
		return
	}
	a.dirty = true // the bar moved; repaint
}

// dlReport posts the seat row when the reported percent crosses a 10%
// boundary (or on the row-creating first call), so the notify stream is
// bounded at eleven lines per download. The seat's verdict rides every
// line — a seatless boot's refusals are observable, never silent.
func (a *app) dlReport(force bool) {
	d := a.dl
	pct := d.prog.Percent()
	if !force && pct/10 == d.lastRep/10 && pct != 100 {
		return
	}
	d.lastRep = pct
	ok := d.prog.Report(uint32(a.win), appName)
	vi.ConsoleLine(markerDlProgress + itoa(pct) + " seat=" + boolStr(ok))
}

// finishDownload lands a completed write: fsync + close, then the publish
// — delete the live name, rename the temp over it — before the ledger row,
// the seat toast, and the completion plate. The existing `web: download
// <path> <bytes>` line keeps its shape — boot 09's assert reads it.
func (a *app) finishDownload() {
	d := a.dl
	_ = vi.FileSync(d.h)
	vi.FileClose(d.h)
	d.h = 0
	if rc := vi.FileDelete(d.path); rc < 0 && rc != vi.ErrFileNotFound {
		a.failDownload("file")
		return
	}
	if rc := vi.FileRename(d.path+"~", d.path); rc < 0 {
		a.failDownload("file")
		return
	}
	d.active = false
	d.done = true
	ledgerAppend("/host/WEB-DOWNLOADS.TXT",
		"# virelai-web-downloads v1 (unix-seconds<TAB>target<TAB>file<TAB>bytes)",
		itoa64(vi.Time())+"\t"+d.target+"\t"+d.path+"\t"+itoa(len(d.body)))
	vi.ConsoleLine(markerDownload + d.path + " " + itoa(len(d.body)))
	vi.ConsoleLine(markerDlDone + d.name + " type=" + d.mimeID.String())
	toast := "DL " + d.name
	if len(toast) > vi.WmRpcTitleMax {
		toast = toast[:vi.WmRpcTitleMax]
	}
	ok := vi.Notify(uint32(a.win), toast, appName)
	vi.ConsoleLine(markerDlToast + boolStr(ok))
	a.status = "saved " + d.name + " — O open, F folder"
	a.dirty = true
}

// dropDownload closes the handle and removes the partial staging temp —
// the one cleanup cancel and fail share so neither can forget the
// half-written path. The LIVE name is never touched: a previous same-named
// download stays put when this one is cancelled.
func (a *app) dropDownload() {
	d := a.dl
	if d == nil {
		return
	}
	if d.h != 0 {
		vi.FileClose(d.h)
		d.h = 0
	}
	if d.active && !d.done {
		_ = vi.FileDelete(d.path + "~")
	}
	a.dl = nil
}

// cancelDownload is the seat-Cancel/Escape/window-close door: the partial
// file goes away and the seat row's label says cancelled, so a user who
// stopped a transfer sees the row settle instead of freeze mid-bar.
func (a *app) cancelDownload() {
	d := a.dl
	if d == nil || !d.active {
		return
	}
	vi.NotifyProgress(uint32(a.win), downloadOp, d.prog.Percent(),
		"cancelled "+d.name, appName)
	vi.ConsoleLine(markerDlCancel + d.name)
	a.dropDownload()
	a.status = "download cancelled"
	a.dirty = true
}

// failDownload is the write-side abort: same cleanup, different words.
// M123d (#2578): the FS failure stands inline — the staged `~` file is
// already gone, so the banner is Copy Error and dismiss, never a retry
// that would have to refetch the whole body.
func (a *app) failDownload(kind string) {
	d := a.dl
	vi.ConsoleLine(markerDlFailed + kind + " " + d.name)
	target := d.target
	a.dropDownload()
	a.status = "download failed: " + kind
	a.raiseBanner("", "download failed: "+kind+" — "+target, "")
	a.dirty = true
}

// openDownload dispatches the finished file through mime.Open — the same
// contract GOFILES holds (sniffed magic beats the name), so an image lands
// in GOVIEW and text in GOEDIT and a type nothing opens is named, not
// silently dropped.
func (a *app) openDownload() {
	d := a.dl
	if d == nil || !d.done {
		return
	}
	req, oerr := mime.Open(d.path, "/", func(p string, max int) ([]byte, error) {
		b, rc := vi.ReadFileAll(p, max)
		if rc < 0 {
			return nil, errDlUnreadable
		}
		return b, nil
	})
	if oerr != nil {
		vi.ConsoleLine(markerDlOpen + "refused " + d.name)
		a.status = "open: nothing handles " + d.name
		a.dirty = true
		return
	}
	vi.ConsoleLine(markerDlOpen + req.Handler.Bin + " " + req.Target)
	pid, err := vi.Exec(req.Handler.Bin, req.Target)
	if err != nil || pid <= 0 {
		vi.ConsoleLine(markerDlOpen + "exec-failed " + req.Handler.Bin)
		a.status = "open: " + req.Handler.Bin + " refused"
		// M123d (#2578): the exec refusal stands inline with Copy Error.
		etext := "exec refused"
		if err != nil {
			etext = err.Error()
		}
		a.raiseBanner("", "exec "+req.Handler.Bin+" refused: "+etext, "")
		a.dirty = true
		return
	}
	vi.ConsoleLine(markerDlOpen + "launched pid=" + itoa64(pid))
	a.status = "opened " + d.name + " in " + req.Handler.Label
	a.dirty = true
}

// folderDownload is Show in Folder: GOFILES.ELF opens the share root,
// where every WEB-DL-* lands.
func (a *app) folderDownload() {
	d := a.dl
	if d == nil || !d.done {
		return
	}
	vi.ConsoleLine(markerDlFolder + "/host " + d.name)
	pid, err := vi.Exec("GOFILES.ELF", "/host")
	if err != nil || pid <= 0 {
		vi.ConsoleLine(markerDlFolder + "exec-failed")
		a.status = "show in folder: GOFILES refused"
		// M123d (#2578): the exec refusal stands inline with Copy Error.
		etext := "exec refused"
		if err != nil {
			etext = err.Error()
		}
		a.raiseBanner("", "exec GOFILES.ELF refused: "+etext, "")
		a.dirty = true
		return
	}
	vi.ConsoleLine(markerDlFolder + "launched pid=" + itoa64(pid))
	a.status = "showing /host in GOFILES"
	a.dirty = true
}

// dlToastOrigin is the completion plate's top-left: bottom-right of the
// window, one inset above the status line.
func dlToastOrigin(w, h int) (int, int) {
	return w - dlToastW - 8, h - statusH - dlToastH - 8
}

// dlChipHit maps a plate-relative point to a chip index.
func dlChipHit(x, y int) (int, bool) {
	for i, c := range dlChips {
		if c.r.Contains(x, y) {
			return i, true
		}
	}
	return 0, false
}

// dlToastHitTest handles a click while the completion plate is up: chips
// act, the rest of the plate is consumed, clicks outside dismiss nothing
// (the plate stays until a navigation, a new download, or Escape).
// Returns true when the click landed on the plate.
func (a *app) dlToastHitTest(x, y, w, h int) bool {
	d := a.dl
	if d == nil || !d.done {
		return false
	}
	x0, y0 := dlToastOrigin(w, h)
	if !inRect(x, y, x0, y0, dlToastW, dlToastH) {
		return false
	}
	if i, ok := dlChipHit(x-x0, y-y0); ok {
		switch i {
		case 0:
			a.openDownload()
		case 1:
			a.folderDownload()
		default:
			a.dl = nil
			a.dirty = true
		}
	}
	return true
}

// paintDlToast draws the completion plate: the saved name, then the OPEN /
// FOLDER chips and the dismiss X.
func (a *app) paintDlToast(vs virender, w, h int) {
	d := a.dl
	x0, y0 := dlToastOrigin(w, h)
	clip := webrender.Clip{X: x0, Y: y0, W: dlToastW, H: dlToastH}
	vs.Fill(x0, y0, dlToastW, dlToastH, webrender.ColorSurface)
	vs.Fill(x0, y0, dlToastW, 1, webrender.ColorAccent)
	vs.Fill(x0, y0, 1, dlToastH, webrender.ColorRule)
	vs.Fill(x0+dlToastW-1, y0, 1, dlToastH, webrender.ColorRule)
	vs.Fill(x0, y0+dlToastH-1, dlToastW, 1, webrender.ColorRule)
	webrender.DrawText(vs, x0+8, y0+6,
		fit("SAVED "+d.name, (dlToastW-16)/8-3), 1, false, webrender.ColorChromeInk, clip)
	for _, c := range dlChips {
		r := c.r
		vs.Fill(x0+r.X, y0+r.Y, r.W, r.H, webrender.ColorChromeBg)
		vs.Fill(x0+r.X, y0+r.Y, r.W, 1, webrender.ColorRule)
		vs.Fill(x0+r.X, y0+r.Y, 1, r.H, webrender.ColorRule)
		vs.Fill(x0+r.X+r.W-1, y0+r.Y, 1, r.H, webrender.ColorRule)
		vs.Fill(x0+r.X, y0+r.Y+r.H-1, r.W, 1, webrender.ColorRule)
		webrender.DrawText(vs, x0+r.X+4, y0+r.Y+3, c.label, 1, false,
			webrender.ColorAccent, clip)
	}
}

// paintDlBar draws the in-flight progress bar on the status line's right
// edge. The widget's rect is assigned here so a resize needs no
// bookkeeping.
func (a *app) paintDlBar(vs virender, w, h int) {
	d := a.dl
	d.prog.R = widgets.Rect{X: w - dlBarW - 6, Y: h - statusH + 2, W: dlBarW, H: dlBarH}
	d.prog.Draw(dlCanvas{v: vs})
}
