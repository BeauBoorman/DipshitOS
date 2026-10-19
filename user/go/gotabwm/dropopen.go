// GOTABWM.ELF — M127b (issue #2600, ADR 0051 V2-D4): the drop toast's
// open-drop action. v1's drop toast was dismiss-only (sender 0, nothing to
// focus); v2 binds the sanitized name the VERIFIED DROP record carried to
// the toast and its center row at push time, so a click — or the row's
// activation — dispatches /host/INBOX/<name> through mime.Open, the M81b
// decision GOSH `open` and GOFILES already share. The `opens=` registry
// names the app (GOVIEW/GOEDIT/GOSOUND by sniff) and the path rides
// argv[1]; a type with no handler falls back to GOFILES on /host/INBOX —
// the reveal gesture is the file manager open at your drop.
//
// Dispatch never execs the payload and never resolves outside INBOX: the
// name was sanitized at ingest and is re-validated here (name_rejected is
// the belt for a seat-internal bug — a verified name cannot legitimately
// fail it). Refusals ride the shared `refuse lane=drop reason=<code>`
// shape: a vanished file is gone, an exec refusal keeps its serial marker
// and earns the M123a errno toast beside it.
package main

import (
	"errors"

	"virelai/hostint"
	"virelai/mime"
	"virelai/vi"
)

// MarkerDropOpen is the dispatch receipt — the announced name and the
// binary the mime table chose (GOFILES.ELF on the no-handler fallback).
const MarkerDropOpen = "gotabwm: hostint drop-open "

// gofilesBin is the no-handler fallback: the file manager at INBOX is
// "open at your drop", always available.
const gofilesBin = "GOFILES.ELF"

// dropReadFile is the head-read seam for the mime sniff — the execApp /
// openFile pattern: vi.ReadFileAll in the guest, swapped by the host
// tests so the routing is pinned without a share.
var dropReadFile = vi.ReadFileAll

var errDropUnreadable = errors.New("drop-open: head unreadable")

// dropOpen runs the open-drop action against the announced name. It is
// the click arm and the center row's arm — one binding, one dispatch.
func dropOpen(name string) {
	if !dropNameOK(name) {
		hostintLog(hostintMarkerPrefix + " refuse lane=drop reason=" +
			hostint.RefuseNameRejected)
		return
	}
	path := "/host/INBOX/" + name
	req, err := mime.Open(path, "/", func(p string, max int) ([]byte, error) {
		b, rc := dropReadFile(p, max)
		if rc < 0 {
			return nil, errDropUnreadable
		}
		return b, nil
	})
	if err != nil {
		var oerr *mime.OpenError
		if errors.As(err, &oerr) {
			switch oerr.Kind {
			case mime.OpenNoHandler:
				dropOpenFallback(name)
				return
			case mime.OpenInvalidTarget:
				// A name dropNameOK passed can never make sharePath
				// refuse (the join stays under the 64-byte path bound);
				// reaching here is the belt firing on a seat bug.
				hostintLog(hostintMarkerPrefix + " refuse lane=drop reason=" +
					hostint.RefuseNameRejected)
				return
			}
		}
		// OpenUnreadable and anything unexpected: the file the record
		// announced is not there to open.
		hostintLog(hostintMarkerPrefix + " refuse lane=drop reason=" +
			hostint.RefuseGone)
		return
	}
	if _, e := execApp(req.Handler.Bin, req.Target); e != nil {
		seatRefusalErr(e, "exec "+req.Handler.Bin, req.Handler.Bin)
		return
	}
	hostintLog(MarkerDropOpen + "name=" + name + " app=" + req.Handler.Bin)
}

// dropOpenFallback is the OpenNoHandler arm: nothing registers the type
// (an archive, a binary, an unknown), so GOFILES opens INBOX itself —
// the reveal gesture.
func dropOpenFallback(name string) {
	if _, e := execApp(gofilesBin, "/host/INBOX"); e != nil {
		seatRefusalErr(e, "exec "+gofilesBin, gofilesBin)
		return
	}
	hostintLog(MarkerDropOpen + "name=" + name + " app=" + gofilesBin)
}

// dropNameOK is the dispatch-side re-validation: the D4 name rule the
// runner sanitized by — ≤ 48 bytes of [A-Za-z0-9._-], leading
// alphanumeric. The leading-alnum half is what rejects "." and "..":
// a name that passes here is always a single honest INBOX basename.
func dropNameOK(name string) bool {
	if name == "" || len(name) > 48 {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		ok := c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' ||
			c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	c := name[0]
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9'
}
