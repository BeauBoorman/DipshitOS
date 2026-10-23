// GOTABWM.ELF — M184b (#3175): the drag-out handoff, seat half. A drag
// armed by a guest app whose held pointer reaches the scanout edge is a
// file being pulled off the glass: the seat stages the envelope's
// payload into /host/OUTBOX/ under a minted D4 name, signs one DRAGOUT
// record (the DROP shape, reversed — sender_id is the source window),
// and ends the guest gesture with the delivered receipt. The runner's
// shared poll consumes the record and the staged file becomes the host
// drag's source.
//
// Transport, decided: the record lane, not vsock. The ctl channel is a
// control wire — 1024-byte lines, ≤31-byte words — that cannot carry
// bulk, and sys_vsock_ctl is callable by any EL0 process, so a dragout
// verb there is unattributed intent; the seat-signed record is the
// provenance OUTBOX is built on. The payload rides the share either
// way — the record names the file, never carries it.
//
// Bounds: the payload is the armed envelope's blob — vi.DragMax (64
// KiB) was the cap at arm, far under the lane's 64 MiB file bound and
// the record's 512-byte payload (the record is name+size only). The
// envelope carries no filename (v1 grammar), so the staged name is
// minted from the mime — GuestDrag.<ext>; a follow-up envelope field
// can carry the real basename. A failed handoff deletes the staged
// payload before the abort — no partial file on either side.
package main

import (
	"virelai/hostint"
	"virelai/outbox"
	"virelai/vi"
)

// MarkerHostintDragOut is the seat's emit receipt — the runner's
// `host-dragout: staged` marker answers it on the far side.
const MarkerHostintDragOut = "gotabwm: hostint dragout "

// The seams, like dragFileWrite's: the production values wire vi, host
// tests drive the gesture in memory.
var (
	dragOutWrite  = vi.WriteFileSafe
	dragOutDelete = vi.FileDelete
	// dragOutExists is the collision probe for the staged name — a
	// 1-byte read answers presence without growing a dir-list seam.
	dragOutExists = func(path string) bool {
		_, rc := vi.ReadFileAll(path, 1)
		return rc >= 0
	}
)

// dragOutAtEdge reports whether a held-drag sample sits on the scanout
// boundary — the only "past the window edge" signal the guest ever sees
// (VZ pins the pointer at the edge once it leaves the view).
func dragOutAtEdge(px, py uint32) bool {
	return px == 0 || py == 0 ||
		px >= vi.ScanoutWidth-1 || py >= vi.ScanoutHeight-1
}

// dragOutHandoff moves the armed drag's payload through the outbox
// lane: stage the blob at /host/OUTBOX/<name> (temp+rename, the share's
// WriteFileSafe rule), then emit the signed DRAGOUT record naming it —
// the host trusts the signature, so the emit is the attestation and a
// refused emit deletes the staging before the abort. On success the
// source gets the Seq=1 receipt with applied=0 (the host is no guest
// window) and the session clears.
func dragOutHandoff() {
	src, mime := drag.src, drag.mime
	_, blob, ok := vi.DecodeDrag(drag.staged)
	if !ok {
		// The arm validated this envelope — a decode failure here is a
		// seat bug, refused under the lane's own name.
		if eng := hostintEngine; eng != nil {
			eng.RefuseLane(hostint.TagDragOut, hostint.RefuseBadRecord)
		}
		dragAbort("edge")
		return
	}
	name := dragOutName(mime)
	if eng := hostintEngine; eng != nil && eng.Armed() {
		name = dragOutUnique(name)
		path := outbox.Dir + "/" + name
		if dragOutWrite(path, blob) != 0 {
			eng.RefuseLane(hostint.TagDragOut, hostint.RefuseIO)
			dragAbort("edge")
			return
		}
		p := make([]byte, 0, 1+len(name)+8)
		p = append(p, byte(len(name)))
		p = append(p, name...)
		size := uint64(len(blob))
		for i := 0; i < 8; i++ {
			p = append(p, byte(size>>(8*i)))
		}
		seq, refusal := eng.EmitSender(hostint.TagDragOut, 0, uint16(src), p)
		if refusal != "" {
			_ = dragOutDelete(path)
			eng.RefuseLane(hostint.TagDragOut, refusal)
			dragAbort("edge")
			return
		}
		hostintLog(MarkerHostintDragOut + "seq=" + vi.Itoa64(int64(seq)) +
			" name=" + name + " size=" + vi.Itoa64(int64(len(blob))))
		dragNotice(src, vi.WmRpcKindDragDrop, 1, 0, mime)
		drag = dragSession{}
		return
	}
	// No engine (flags-off, no credential) or no adopted mask: the lane
	// is byte-silent and the gesture ends as a named undelivered edge —
	// nothing was staged, nothing was emitted.
	dragAbort("edge")
}

// dragOutName mints the staged name from the drag's mime — the v1
// envelope carries no basename, so the subtype names the extension and
// GuestDrag the stem. The result always satisfies the lane's D4 rule.
func dragOutName(mime string) string {
	sub := mime
	for i := 0; i < len(mime); i++ {
		if mime[i] == '/' {
			sub = mime[i+1:]
			break
		}
	}
	ext := "bin"
	switch sub {
	case "plain":
		ext = "txt"
	case "markdown":
		ext = "md"
	case "png", "qoi", "gif", "bmp":
		ext = sub
	case "jpeg":
		ext = "jpg"
	}
	name, ok := outbox.Name("GuestDrag." + ext)
	if !ok {
		return "GuestDrag.bin"
	}
	return name
}

// dragOutUnique keeps the staged name clear of a payload already
// sitting in OUTBOX/ (an in-flight REQ export): the host landing rule
// mirrored — base-2.ext … base-9.ext, cut to the 48-byte bound, the
// minted name returned on a full ring.
func dragOutUnique(name string) string {
	if !dragOutExists(outbox.Dir + "/" + name) {
		return name
	}
	stem, ext := name, ""
	for i := len(name) - 1; i > 0; i-- {
		if name[i] == '.' {
			stem, ext = name[:i], name[i:]
			break
		}
	}
	for n := 2; n <= 9; n++ {
		suf := "-" + vi.Itoa64(int64(n))
		cand := stem
		if len(cand)+len(suf)+len(ext) > outbox.NameMax {
			cand = cand[:outbox.NameMax-len(suf)-len(ext)]
		}
		cand += suf + ext
		if !dragOutExists(outbox.Dir + "/" + cand) {
			return cand
		}
	}
	return name
}
