// "Open this" — the M81b (issue #1762) dispatch. GOFILES stops deciding what
// a file is from its own name rules: the pure table in virelai/mime sniffs
// the bytes (magic first, extension second) and the registry names the app
// that opens that type. Two entry points, one decision:
//
//	openSel on a file      dispatch to the DEFAULT handler (double-click,
//	                       Enter, `l`)
//	`o` (Open with…)       list the candidates, 1..9 picks one
//
// The model stays pure — it decides and marks; main.go owns the ONE exec
// seam (drainLaunch), because vi.Exec is the guest syscall and the host
// tests must not need a guest to pin the decision.
package main

import (
	"errors"

	"virelai/mime"
	"virelai/vi"
)

// launchReq is the exec main.go owes the frame: which binary, on which
// path. Args is the manifest row's argv= tail (M124d) — fixed arguments
// ahead of the file path; nil for the registry dispatches, which carry no
// fixed argv. Empty Bin means "nothing to launch".
type launchReq struct {
	bin  string
	path string
	args []string
}

// maxCandidates bounds the Open-with list to the digits that exist.
const maxCandidates = 9

// readHead is the read seam (M81b #1762): the guest's vi.ReadFileAll, swapped
// by the host tests so the DECISION can be pinned without a guest. Nothing
// else in the model reads a file for this purpose.
var readHead = func(path string, cap int) ([]byte, int64) { return readCapped(path, cap) }

var errHeadUnreadable = errors.New("file head is unreadable")

// resolveFile uses the same Open contract as GOSH. The file manager supplies
// its syscall-backed head reader; classification, path normalization, and
// handler selection all stay in virelai/mime.
func resolveFile(path string) (mime.OpenRequest, *mime.OpenError) {
	req, err := mime.Open(path, "/", func(path string, max int) ([]byte, error) {
		head, rc := readHead(path, max)
		if rc < 0 {
			return nil, errHeadUnreadable
		}
		return head, nil
	})
	if err == nil {
		return req, nil
	}
	var openErr *mime.OpenError
	if errors.As(err, &openErr) {
		return mime.OpenRequest{}, openErr
	}
	return mime.OpenRequest{}, &mime.OpenError{Kind: mime.OpenInvalidTarget}
}

// refuseUnreadable is the shared wording for "the share would not give us the
// bytes" — the same `(reason)` shape the delete refusal uses for a directory.
func (m *model) refuseUnreadable(name string) {
	m.emit(markerOpenNo + name + " (unreadable)")
	m.status = name + ": unreadable"
}

func (m *model) refuseOpen(name string, err *mime.OpenError) {
	if err == nil {
		return
	}
	switch err.Kind {
	case mime.OpenUnreadable:
		m.refuseUnreadable(name)
	case mime.OpenNoHandler:
		m.emit(markerOpenNo + name + " type=" + err.Type.String())
		m.status = "no handler for " + err.Type.String()
	default:
		m.status = "open: invalid path"
	}
}

// openSelPath resolves the selected entry to an absolute share path.
func (m *model) openSelPath() (string, string, bool) {
	e, ok := m.selEntry()
	if !ok {
		return "", "", false
	}
	name := e.NameString()
	if m.path == favsView {
		// M167b: a pin row's path is the pin itself — the mime/open
		// contract then answers on the real directory (or refuses it
		// by name) instead of a pseudo path that cannot resolve.
		if m.sel < len(m.favs) {
			return name, m.favs[m.sel], true
		}
		return name, "", false
	}
	p, ok := joinPath(m.path, name)
	if !ok {
		return name, "", false
	}
	return name, p, true
}

// openFile dispatches the selection to its type's default handler. The
// decision marker rides `pending` (post-paint, like every other marker), and
// the launch itself is queued for main.
func (m *model) openFile() {
	name, path, ok := m.openSelPath()
	if !ok || path == "" {
		m.status = "open: path too long"
		return
	}
	req, openErr := resolveFile(path)
	if openErr != nil {
		m.refuseOpen(name, openErr)
		return
	}
	m.emit(markerOpenFile + name + " type=" + req.Type.String() + " handler=" + req.Handler.Bin)
	m.launch = launchReq{bin: req.Handler.Bin, path: req.Target}
	m.status = "opening " + baseName(req.Handler.Bin)
}

// startOpenWith arms the candidate list for the selection. Zero candidates is
// the same refusal openFile gives, said once and in the same words.
func (m *model) startOpenWith() {
	name, path, ok := m.openSelPath()
	if !ok || path == "" {
		m.status = "open with: path too long"
		return
	}
	req, openErr := resolveFile(path)
	if openErr != nil {
		m.refuseOpen(name, openErr)
		return
	}
	cands := mime.Handlers(req.Type)
	if len(cands) == 0 {
		m.emit(markerOpenNo + name + " type=" + req.Type.String())
		m.status = "no handler for " + req.Type.String()
		return
	}
	if len(cands) > maxCandidates {
		cands = cands[:maxCandidates]
	}
	m.mode = modeOpenWith
	m.openName, m.openPath, m.openID = name, req.Target, req.Type
	m.openCands = cands
	m.emit(markerOpenWith + name + " type=" + req.Type.String() +
		" candidates=" + vi.Itoa64(int64(len(cands))))
	m.status = "open with: 1-" + vi.Itoa64(int64(len(cands)))
}

// chooseOpen takes the nth candidate (1-based, the digit the user pressed).
func (m *model) chooseOpen(n int) {
	if n < 1 || n > len(m.openCands) {
		m.status = "open with: no such candidate"
		return
	}
	h := m.openCands[n-1]
	m.emit(markerOpenChose + m.openName + " type=" + m.openID.String() + " handler=" + h.Bin)
	m.launch = launchReq{bin: h.Bin, path: m.openPath}
	m.clearOpenWith()
	m.status = "opening " + baseName(h.Bin)
}

// cancelOpenWith leaves the list without launching anything.
func (m *model) cancelOpenWith() {
	name := m.openName
	m.clearOpenWith()
	m.emit(markerOpenCancel + name)
	m.status = "open with: cancelled"
}

func (m *model) clearOpenWith() {
	m.mode = modeNormal
	m.openName, m.openPath = "", ""
	m.openID = mime.Unknown
	m.openCands = nil
}

// takeLaunch hands main the queued exec request, if any, and clears it.
func (m *model) takeLaunch() (launchReq, bool) {
	r := m.launch
	m.launch = launchReq{}
	return r, r.bin != ""
}
