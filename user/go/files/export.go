// "Export to Host" — the M127d (#2602, ADR 0051 V2-D5) OUTBOX gesture.
// The selection's payload is staged to /host/OUTBOX/ with a REQ intent
// marker through the shared virelai/outbox seam; the seat signs the
// notice on its next tick and the runner moves the file to the host's
// download dir. The model decides and marks like every other op — the
// stage itself is one seam call so the host tests pin the refusal
// shapes without a guest.
package main

import "virelai/outbox"

// exportFn is the stage seam — production binds the real share copy.
var exportFn = func(path string) (string, string) {
	return outbox.Guest.Export(path)
}

// exportSel stages the selection for host export: a REQ-marked payload
// the seat's outbox tick signs into an OUTBOX record. Directories and
// volume rows are refused by name; every refusal the stage returns is a
// lane-vocabulary word carried into the marker and the status line.
func (m *model) exportSel() {
	if m.tar != nil {
		// M167c: export is extraction — the card scopes it out.
		m.tarReadOnly("export")
		return
	}
	e, ok := m.selEntry()
	if !ok {
		return
	}
	if m.path == volsPath {
		m.status = "export: pick a file"
		return
	}
	name := e.NameString()
	if e.Dir() {
		m.emit(markerExportNo + name + " " + outbox.RefuseUnsupported)
		m.status = "export refused: " + outbox.RefuseUnsupported
		return
	}
	p, ok := joinPath(m.path, name)
	if !ok {
		m.status = "export: path too long"
		return
	}
	landed, refusal := exportFn(p)
	if refusal != "" {
		m.emit(markerExportNo + name + " " + refusal)
		m.status = "export refused: " + refusal
		return
	}
	m.emit(markerExport + name + " -> OUTBOX/" + landed)
	m.status = "exported " + landed
}
